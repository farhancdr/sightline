import AppKit

extension NSAttributedString.Key {
    /// Full-width line background, painted by `DiffLayoutManager`.
    static let diffLineBackground = NSAttributedString.Key("SightlineDiffLineBackground")
    /// Hatched filler row (the other side has lines here), painted by `DiffLayoutManager`.
    static let diffFiller = NSAttributedString.Key("SightlineDiffFiller")
}

enum DiffRowKind: Sendable {
    case context, removed, added, filler, separator
}

/// One rendered column of a diff (left/right in side-by-side, or the single inline column).
struct DiffSide: @unchecked Sendable {
    let text: NSAttributedString
    /// Gutter label per row (line number(s), or "" for fillers).
    let labels: [String]
    let kinds: [DiffRowKind]
    /// UTF-16 offset where each row starts in `text`.
    let rowStarts: [Int]
    /// File line number per row for "path:line" references (nil for fillers/separators).
    /// Split: that side's numbers. Inline: new-file number, or old for removed lines.
    let numbers: [Int?]

    static let empty = DiffSide(text: NSAttributedString(), labels: [], kinds: [], rowStarts: [], numbers: [])
}

/// A parsed, rendered diff in both layouts. Built off the main thread.
struct DiffDocument: @unchecked Sendable {
    let id = UUID()
    let left: DiffSide
    let right: DiffSide
    let inline: DiffSide
    /// Rows where a change block starts (side-by-side rows / inline rows).
    let changeRows: [Int]
    let inlineChangeRows: [Int]
    let additions: Int
    let deletions: Int
    let isBinary: Bool
    let isEmpty: Bool
    let isTruncated: Bool
    let message: String?

    /// Whole file added or deleted: one side would be entirely filler.
    var isOneSided: Bool {
        message == nil && (left.kinds.allSatisfy { $0 == .filler } || right.kinds.allSatisfy { $0 == .filler })
    }

    static let defaultRowLimit = 50_000
    /// Context requested from git: effectively "whole file", like VS Code's diff editor.
    static let fullContext = 1_000_000

    static func message(_ text: String) -> DiffDocument {
        DiffDocument(
            left: .empty, right: .empty, inline: .empty, changeRows: [], inlineChangeRows: [],
            additions: 0, deletions: 0, isBinary: false, isEmpty: true, isTruncated: false, message: text
        )
    }

    static func build(from raw: String, path: String, rowLimit: Int?) -> DiffDocument {
        var parser = DiffParser(rowLimit: rowLimit ?? Int.max)
        parser.parse(raw)
        if parser.isBinary { return .message("Binary file changed") }
        if parser.split.isEmpty { return .message("No textual changes") }

        let language = Language.detect(path: path)
        let width = String(max(parser.maxLineNumber, 1)).count

        var leftLines: [RenderLine] = []
        var rightLines: [RenderLine] = []
        for row in parser.split {
            switch row {
            case let .pair(left, right):
                leftLines.append(RenderLine(cell: left, fallback: .filler))
                rightLines.append(RenderLine(cell: right, fallback: .filler))
            case let .separator(text):
                leftLines.append(RenderLine(text: text, kind: .separator, label: "", number: nil))
                rightLines.append(RenderLine(text: text, kind: .separator, label: "", number: nil))
            }
        }
        // Character-level emphasis for removed/added pairs on the same row.
        var leftEmphasis: [Int: NSRange] = [:]
        var rightEmphasis: [Int: NSRange] = [:]
        for (index, row) in parser.split.enumerated() {
            guard case let .pair(left?, right?) = row, left.kind == .removed, right.kind == .added,
                  let (a, b) = changedRanges(left.text, right.text) else { continue }
            leftEmphasis[index] = a
            rightEmphasis[index] = b
        }

        var inlineLines: [RenderLine] = []
        for row in parser.inline {
            switch row {
            case let .line(old, new, text, kind):
                let label = pad(old, width) + " " + pad(new, width)
                inlineLines.append(RenderLine(text: text, kind: kind, label: label, number: new ?? old))
            case let .separator(text):
                inlineLines.append(RenderLine(text: text, kind: .separator, label: "", number: nil))
            }
        }
        var inlineEmphasis: [Int: NSRange] = [:]
        for (removedRow, addedRow) in parser.inlinePairs {
            guard let (a, b) = changedRanges(inlineLines[removedRow].text, inlineLines[addedRow].text) else { continue }
            inlineEmphasis[removedRow] = a
            inlineEmphasis[addedRow] = b
        }

        return DiffDocument(
            left: render(leftLines, language: language, emphasis: leftEmphasis),
            right: render(rightLines, language: language, emphasis: rightEmphasis),
            inline: render(inlineLines, language: language, emphasis: inlineEmphasis),
            changeRows: parser.changeRows,
            inlineChangeRows: parser.inlineChangeRows,
            additions: parser.additions,
            deletions: parser.deletions,
            isBinary: false,
            isEmpty: false,
            isTruncated: parser.truncated,
            message: nil
        )
    }

    // MARK: Rendering

    private struct RenderLine {
        let text: String
        let kind: DiffRowKind
        let label: String
        let number: Int?

        init(text: String, kind: DiffRowKind, label: String, number: Int?) {
            self.text = text
            self.kind = kind
            self.label = label
            self.number = number
        }

        init(cell: DiffParser.Cell?, fallback: DiffRowKind) {
            if let cell {
                self.init(text: cell.text, kind: cell.kind, label: String(cell.number), number: cell.number)
            } else {
                self.init(text: "", kind: fallback, label: "", number: nil)
            }
        }
    }

    private static func render(_ lines: [RenderLine], language: Language, emphasis: [Int: NSRange]) -> DiffSide {
        var string = ""
        var starts: [Int] = []
        starts.reserveCapacity(lines.count)
        var offset = 0
        for line in lines {
            starts.append(offset)
            string += line.text
            string += "\n"
            offset += line.text.utf16.count + 1
        }

        let storage = NSTextStorage(string: string)
        let full = NSRange(location: 0, length: storage.length)
        storage.addAttributes([.font: DiffStyle.font, .foregroundColor: SyntaxTheme.text], range: full)
        if storage.length <= SyntaxHighlighter.maxHighlightLength {
            let tokens = SyntaxHighlighter.tokens(for: string, language: language)
            SyntaxHighlighter.apply(tokens, to: storage, font: DiffStyle.font, boldFont: DiffStyle.boldFont)
        }

        for (row, line) in lines.enumerated() {
            let range = NSRange(location: starts[row], length: line.text.utf16.count + 1)
            switch line.kind {
            case .removed:
                storage.addAttribute(.diffLineBackground, value: DiffStyle.removedLine, range: range)
            case .added:
                storage.addAttribute(.diffLineBackground, value: DiffStyle.addedLine, range: range)
            case .filler:
                storage.addAttribute(.diffFiller, value: true, range: range)
            case .separator:
                storage.addAttributes([
                    .diffLineBackground: DiffStyle.separatorLine,
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .font: DiffStyle.font,
                ], range: range)
            case .context:
                break
            }
            if let word = emphasis[row], word.length > 0 {
                let color = line.kind == .removed ? DiffStyle.removedWord : DiffStyle.addedWord
                storage.addAttribute(
                    .backgroundColor, value: color,
                    range: NSRange(location: starts[row] + word.location, length: word.length)
                )
            }
        }
        return DiffSide(
            text: storage, labels: lines.map(\.label), kinds: lines.map(\.kind), rowStarts: starts,
            numbers: lines.map(\.number)
        )
    }

    /// Common prefix/suffix trim → the changed middle of each line (UTF-16 ranges).
    static func changedRanges(_ a: String, _ b: String) -> (NSRange, NSRange)? {
        let x = Array(a.utf16)
        let y = Array(b.utf16)
        let shortest = min(x.count, y.count)
        var prefix = 0
        while prefix < shortest, x[prefix] == y[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < shortest - prefix, x[x.count - 1 - suffix] == y[y.count - 1 - suffix] { suffix += 1 }
        guard prefix + suffix > 0 else { return nil } // whole line differs: line color is enough
        return (
            NSRange(location: prefix, length: x.count - prefix - suffix),
            NSRange(location: prefix, length: y.count - prefix - suffix)
        )
    }

    private static func pad(_ number: Int?, _ width: Int) -> String {
        guard let number else { return String(repeating: " ", count: width) }
        let text = String(number)
        return String(repeating: " ", count: max(0, width - text.count)) + text
    }
}

enum DiffStyle {
    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    // GitHub diff colors (Primer diffBlob.*): line / changed-word / gutter, light and dark.
    static let removedLine = Palette.color(0xFFEBE9, 0xF85149, darkAlpha: 0.10)
    static let addedLine = Palette.color(0xDAFBE1, 0x2EA043, darkAlpha: 0.15)
    static let removedWord = Palette.color(0xFF8182, 0xF85149, lightAlpha: 0.40, darkAlpha: 0.40)
    static let addedWord = Palette.color(0xACEEBB, 0x2EA043, darkAlpha: 0.40)
    static let separatorLine = Palette.color(0xDDF4FF, 0x388BFD, darkAlpha: 0.10)
    static let removedGutter = Palette.color(0xFFCECB, 0xF85149, darkAlpha: 0.30)
    static let addedGutter = Palette.color(0xACEEBB, 0x3FB950, darkAlpha: 0.30)
    static let hatch = Palette.color(0x000000, 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.08)
}

/// Unified diff → aligned side-by-side rows + inline rows.
struct DiffParser {
    struct Cell {
        let number: Int
        let text: String
        let kind: DiffRowKind
    }

    enum SplitRow {
        case pair(Cell?, Cell?)
        case separator(String)
    }

    enum InlineRow {
        case line(old: Int?, new: Int?, text: String, kind: DiffRowKind)
        case separator(String)
    }

    let rowLimit: Int
    private(set) var split: [SplitRow] = []
    private(set) var inline: [InlineRow] = []
    private(set) var inlinePairs: [(Int, Int)] = []
    private(set) var changeRows: [Int] = []
    private(set) var inlineChangeRows: [Int] = []
    private(set) var additions = 0
    private(set) var deletions = 0
    private(set) var maxLineNumber = 0
    private(set) var isBinary = false
    private(set) var truncated = false

    private var oldLine = 0
    private var newLine = 0
    private var removed: [Cell] = []
    private var added: [Cell] = []

    init(rowLimit: Int) { self.rowLimit = rowLimit }

    mutating func parse(_ raw: String) {
        var inHunk = false
        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            // CRLF files: drop the CR so it neither renders nor makes every line "differ".
            let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine
            if split.count >= rowLimit {
                truncated = true
                break
            }
            if line.hasPrefix("@@") {
                flush()
                let (oldStart, newStart) = Self.hunkStarts(line)
                let hidden = oldStart - max(oldLine, 1)
                if hidden > 0 || (!split.isEmpty && hidden >= 0) {
                    let text = hidden > 0 ? "⋯ \(hidden) unchanged line\(hidden == 1 ? "" : "s")" : "⋯"
                    split.append(.separator(text))
                    inline.append(.separator(text))
                }
                oldLine = oldStart
                newLine = newStart
                inHunk = true
                continue
            }
            if line.hasPrefix("diff ") {
                flush()
                inHunk = false
                continue
            }
            guard inHunk else {
                if line.hasPrefix("Binary files ") { isBinary = true }
                continue
            }
            switch line.first {
            case "+":
                added.append(Cell(number: newLine, text: String(line.dropFirst()), kind: .added))
                newLine += 1
                additions += 1
            case "-":
                removed.append(Cell(number: oldLine, text: String(line.dropFirst()), kind: .removed))
                oldLine += 1
                deletions += 1
            case "\\":
                continue // "\ No newline at end of file"
            case nil:
                continue // trailing empty split element
            default:
                flush()
                let text = String(line.dropFirst())
                split.append(.pair(Cell(number: oldLine, text: text, kind: .context),
                                   Cell(number: newLine, text: text, kind: .context)))
                inline.append(.line(old: oldLine, new: newLine, text: text, kind: .context))
                oldLine += 1
                newLine += 1
            }
            maxLineNumber = max(maxLineNumber, oldLine, newLine)
        }
        flush()
    }

    /// Emits a pending block of removed/added lines, pairing them row by row.
    private mutating func flush() {
        guard !removed.isEmpty || !added.isEmpty else { return }
        changeRows.append(split.count)
        inlineChangeRows.append(inline.count)
        for index in 0..<max(removed.count, added.count) {
            split.append(.pair(index < removed.count ? removed[index] : nil, index < added.count ? added[index] : nil))
        }
        let removedStart = inline.count
        for cell in removed { inline.append(.line(old: cell.number, new: nil, text: cell.text, kind: .removed)) }
        let addedStart = inline.count
        for cell in added { inline.append(.line(old: nil, new: cell.number, text: cell.text, kind: .added)) }
        for index in 0..<min(removed.count, added.count) {
            inlinePairs.append((removedStart + index, addedStart + index))
        }
        removed.removeAll()
        added.removeAll()
    }

    /// "@@ -12,7 +12,9 @@" → (12, 12)
    static func hunkStarts(_ line: Substring) -> (Int, Int) {
        let parts = line.split(separator: " ")
        func start(_ index: Int) -> Int {
            guard parts.count > index else { return 0 }
            let digits = parts[index].dropFirst().split(separator: ",").first ?? ""
            return Int(digits) ?? 0
        }
        return (start(1), start(2))
    }
}
