import AppKit

/// A key as the Vim engine sees it.
enum VimKey: Equatable {
    case char(Character)
    case ctrl(Character)
    case escape, enter, backspace, tab
    /// Text typed in Insert mode, replayed by `.`.
    case text(String)

    /// nil for anything Vim shouldn't see (⌘ shortcuts go to the app).
    static func from(_ event: NSEvent, mode: VimEngine.Mode) -> VimKey? {
        let flags = event.modifierFlags
        if flags.contains(.command) { return nil }
        switch event.keyCode {
        case 53: return .escape
        case 36, 76: return .enter
        case 51: return .backspace
        case 48: return .tab
        default: break
        }
        if flags.contains(.control), let char = event.charactersIgnoringModifiers?.lowercased().first {
            return char == "[" ? .escape : .ctrl(char)
        }
        if mode != .insert {
            switch event.keyCode { // arrows behave like h j k l outside Insert mode
            case 123: return .char("h")
            case 124: return .char("l")
            case 125: return .char("j")
            case 126: return .char("k")
            default: break
            }
        }
        guard let characters = event.characters, characters.count == 1, let char = characters.first else { return nil }
        return .char(char)
    }
}

/// Modal (Vim) editing on top of `CodeTextView`. Covers the everyday subset: modes, counts, operators with
/// motions and text objects, registers (one unnamed register), dot-repeat, search, and a few Ex commands.
/// Every edit goes through the text view's undoable `replace`, so `u` / `⌃r` use the editor's undo stack.
@MainActor
final class VimEngine {
    enum Mode: Equatable { case normal, insert, visual, visualLine }

    enum Action {
        case save, close, saveAndClose, jumpBack, jumpForward
        case searchWord(String)
    }

    private enum MotionKind { case exclusive, inclusive, linewise }
    private struct Motion { var target: Int; var kind: MotionKind }

    weak var view: CodeTextView?
    private(set) var mode: Mode = .normal { didSet { if mode != oldValue { view?.needsDisplay = true }; notify() } }
    var onStatus: ((String) -> Void)?
    var onAction: ((Action) -> Void)?

    // Pending command state.
    private var countDigits = ""
    private var operatorCount = ""
    private var pendingOperator: String?
    private var prefix = ""
    private var commandLine: String?

    private var desiredColumn: Int?
    private var visualAnchor = 0
    private var visualCursor = 0
    private var register = (text: "", linewise: false)
    private var lastFind: (kind: Character, char: Character)?
    private var lastSearch: (pattern: String, forward: Bool)?

    /// Set while the engine itself is handling a key or moving the selection, so selection-change
    /// notifications from our own edits aren't mistaken for mouse input.
    private var isHandlingKey = false
    private var applyingSelection = false

    // Dot-repeat.
    private var keysOfCurrentCommand: [VimKey] = []
    private var lastChange: [VimKey] = []
    private var recordingChange = false
    private var insertStart: Int?
    private var replaying = false

    init(view: CodeTextView) {
        self.view = view
        notify()
    }

    var usesBlockCursor: Bool { mode == .normal && commandLine == nil }

    var statusText: String {
        let label: String
        switch mode {
        case .normal: label = "NORMAL"
        case .insert: label = "INSERT"
        case .visual: label = "VISUAL"
        case .visualLine: label = "V-LINE"
        }
        if let commandLine { return commandLine }
        let pending = countDigits + (pendingOperator ?? "") + operatorCount + prefix
        return pending.isEmpty ? label : "\(label)  \(pending)"
    }

    private func notify() { onStatus?(statusText) }

    // MARK: Text helpers

    private var text: NSString { (view?.string ?? "") as NSString }
    private var length: Int { text.length }
    private func char(_ index: Int) -> unichar { index >= 0 && index < length ? text.character(at: index) : 10 }
    private func isNewline(_ index: Int) -> Bool { char(index) == 10 }

    private func lineStart(_ index: Int) -> Int {
        text.lineRange(for: NSRange(location: min(max(0, index), length), length: 0)).location
    }

    /// Index of the line's newline (or the end of the text).
    private func lineEnd(_ index: Int) -> Int {
        var end = min(max(0, index), length)
        while end < length, char(end) != 10 { end += 1 }
        return end
    }

    /// Last character of the line (or its start when the line is empty) — where Normal mode's cursor may sit.
    private func lastCharIndex(_ index: Int) -> Int { max(lineStart(index), lineEnd(index) - 1) }

    private func firstNonBlank(_ index: Int) -> Int {
        var position = lineStart(index)
        let end = lineEnd(index)
        while position < end, char(position) == 32 || char(position) == 9 { position += 1 }
        return position
    }

    private func column(_ index: Int) -> Int { index - lineStart(index) }

    private func lineNumber(_ index: Int) -> Int {
        var line = 1
        var position = 0
        let target = min(index, length)
        while position < target {
            if char(position) == 10 { line += 1 }
            position += 1
        }
        return line
    }

    private func startOfLine(number: Int) -> Int {
        var line = 1
        var position = 0
        while line < number, position < length {
            if char(position) == 10 { line += 1 }
            position += 1
        }
        return position
    }

    private var lastLineNumber: Int { lineNumber(length) }

    /// 0 blank, 1 word, 2 punctuation, 3 newline. With `big`, any non-blank is a word.
    private func wordClass(_ index: Int, big: Bool) -> Int {
        let unit = char(index)
        if unit == 32 || unit == 9 { return 0 }
        if unit == 10 || unit == 13 { return 3 }
        if big { return 1 }
        return CodeTextView.isIdentifier(unit) ? 1 : 2
    }

    private func clampNormal(_ index: Int) -> Int {
        let position = min(max(0, index), length)
        let start = lineStart(position)
        let end = lineEnd(position)
        return end > start ? min(position, end - 1) : start
    }

    // MARK: Cursor / selection

    private var cursor: Int { mode == .visual || mode == .visualLine ? visualCursor : (view?.selectedRange().location ?? 0) }

    private func moveCursor(to index: Int, keepColumn: Bool = false) {
        if !keepColumn { desiredColumn = nil }
        switch mode {
        case .visual, .visualLine:
            visualCursor = min(max(0, index), max(0, length - 1))
            applyVisualSelection()
        default:
            let position = mode == .insert ? min(max(0, index), length) : clampNormal(index)
            setSelection(NSRange(location: position, length: 0))
            view?.scrollRangeToVisible(NSRange(location: position, length: 0))
        }
    }

    private func applyVisualSelection() {
        guard let view else { return }
        let low = min(visualAnchor, visualCursor)
        let high = max(visualAnchor, visualCursor)
        let range = mode == .visualLine
            ? NSRange(location: lineStart(low), length: min(length, lineEnd(high) + 1) - lineStart(low))
            : NSRange(location: low, length: min(length, high + 1) - low)
        setSelection(range)
        view.scrollRangeToVisible(NSRange(location: visualCursor, length: 0))
    }

    private var visualRange: (range: NSRange, linewise: Bool) {
        let low = min(visualAnchor, visualCursor)
        let high = max(visualAnchor, visualCursor)
        if mode == .visualLine {
            return (NSRange(location: lineStart(low), length: lineEnd(high) - lineStart(low)), true)
        }
        return (NSRange(location: low, length: min(length, high + 1) - low), false)
    }

    // MARK: Entry point

    /// Returns true when the key was consumed.
    private func setSelection(_ range: NSRange) {
        applyingSelection = true
        view?.setSelectedRange(range)
        applyingSelection = false
    }

    /// Mouse selection changes: a drag in Normal mode becomes Visual right away; a click past the end of a
    /// line snaps onto its last character (so `x` can't delete the line break); a click in Visual leaves it.
    func syncFromSelectionChange() {
        guard !isHandlingKey, !applyingSelection, commandLine == nil, mode != .insert, let view,
              let event = NSApp.currentEvent,
              [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type) else { return }
        let range = view.selectedRange()
        if range.length > 0 {
            if mode == .normal { mode = .visual }
            visualAnchor = range.location
            visualCursor = max(range.location, NSMaxRange(range) - 1)
            notify()
        } else {
            if mode != .normal { mode = .normal }
            let clamped = clampNormal(range.location)
            if clamped != range.location { setSelection(NSRange(location: clamped, length: 0)) }
        }
    }

    @discardableResult
    func handle(_ key: VimKey) -> Bool {
        guard let view else { return false }
        isHandlingKey = true
        defer { isHandlingKey = false }
        if mode == .insert { return handleInsert(key) }

        // A mouse selection made in Normal mode becomes a Visual selection.
        if mode == .normal, view.selectedRange().length > 0, commandLine == nil {
            let range = view.selectedRange()
            mode = .visual
            visualAnchor = range.location
            visualCursor = max(range.location, NSMaxRange(range) - 1)
        }
        if let line = commandLine { return handleCommandLine(key, line: line) }
        if isIdle, !replaying { keysOfCurrentCommand = [] }
        keysOfCurrentCommand.append(key)
        let consumed = mode == .normal ? handleNormal(key) : handleVisual(key)
        notify()
        return consumed
    }

    private var isIdle: Bool { countDigits.isEmpty && operatorCount.isEmpty && pendingOperator == nil && prefix.isEmpty }

    private func resetPending() {
        countDigits = ""
        operatorCount = ""
        pendingOperator = nil
        prefix = ""
    }

    private var count: Int {
        let first = Int(countDigits) ?? 1
        let second = Int(operatorCount) ?? 1
        return max(1, first * second)
    }

    private var hasExplicitCount: Bool { !countDigits.isEmpty || !operatorCount.isEmpty }

    /// A command finished. Changes are remembered for `.`; changes that entered Insert mode keep recording.
    private func finish(change: Bool) {
        if change, !replaying {
            if mode == .insert { recordingChange = true } else { lastChange = keysOfCurrentCommand }
        }
        resetPending()
    }

    // MARK: Insert mode

    private func handleInsert(_ key: VimKey) -> Bool {
        guard let view else { return false }
        switch key {
        case .escape:
            if recordingChange, !replaying {
                let caret = view.selectedRange().location
                if let start = insertStart, caret >= start {
                    keysOfCurrentCommand.append(.text(text.substring(with: NSRange(location: start, length: caret - start))))
                }
                keysOfCurrentCommand.append(.escape)
                lastChange = keysOfCurrentCommand
            }
            recordingChange = false
            insertStart = nil
            let caret = view.selectedRange().location
            mode = .normal
            moveCursor(to: caret > lineStart(caret) ? caret - 1 : caret)
            return true
        case let .text(typed):
            view.insertText(typed, replacementRange: view.selectedRange())
            return true
        default:
            return false // normal typing
        }
    }

    private func enterInsert(at index: Int) {
        mode = .insert
        moveCursor(to: index)
        insertStart = view?.selectedRange().location
    }

    // MARK: Normal mode

    private func handleNormal(_ key: VimKey) -> Bool {
        if case .escape = key {
            resetPending()
            return true
        }
        // A pending operator owns the following keys (counts, motions, text objects, f/t targets).
        if let op = pendingOperator { return handleOperatorPending(key, op: op) }
        // Second key of a two-key command.
        if !prefix.isEmpty { return handlePrefix(key) }

        switch key {
        case .escape:
            resetPending()
            return true
        case let .ctrl(c):
            return handleControl(c)
        case .enter:
            return applyMotion("j")
        case .backspace:
            return applyMotion("h")
        case .tab:
            onAction?(.jumpForward) // ⌃i
            return true
        case let .char(c):
            if c.isNumber, c != "0" || !countDigits.isEmpty {
                countDigits.append(c)
                return true
            }
            return handleCommand(c)
        case .text:
            return true
        }
    }

    private func handleControl(_ c: Character) -> Bool {
        switch c {
        case "r":
            repeatCount { self.view?.undoManager?.redo() }
            settleAfterUndo()
        case "d", "u":
            let lines = max(1, visibleLineCount / 2) * (hasExplicitCount ? count : 1)
            var position = cursor
            for _ in 0..<lines { position = c == "d" ? nextLineStart(position) : previousLineStart(position) }
            moveCursor(to: firstNonBlank(position))
            scrollCursor(to: .center)
        case "f", "b":
            let lines = max(1, visibleLineCount - 2)
            var position = cursor
            for _ in 0..<lines { position = c == "f" ? nextLineStart(position) : previousLineStart(position) }
            moveCursor(to: firstNonBlank(position))
            scrollCursor(to: c == "f" ? .top : .bottom)
        case "o": onAction?(.jumpBack)
        case "i": onAction?(.jumpForward)
        case "v": // no block-visual: treat as characterwise visual
            beginVisual(.visual)
        default:
            resetPending()
            return true
        }
        resetPending()
        return true
    }

    private func handleCommand(_ c: Character) -> Bool {
        switch c {
        case "d", "c", "y", ">", "<":
            pendingOperator = String(c)
        case "g", "z", "f", "F", "t", "T", "r", "Z":
            prefix = String(c)
        case "i": enterInsert(at: cursor); finish(change: true)
        case "a": enterInsert(at: min(lineEnd(cursor), cursor + (lineEnd(cursor) > lineStart(cursor) ? 1 : 0))); finish(change: true)
        case "I": enterInsert(at: firstNonBlank(cursor)); finish(change: true)
        case "A": enterInsert(at: lineEnd(cursor)); finish(change: true)
        case "o", "O": openLine(below: c == "o"); finish(change: true)
        case "x", "X":
            let start = c == "x" ? cursor : max(lineStart(cursor), cursor - count)
            let end = c == "x" ? min(lineEnd(cursor), cursor + count) : cursor
            if end > start { delete(NSRange(location: start, length: end - start), linewise: false, yank: true) }
            finish(change: true)
        case "s":
            let end = min(lineEnd(cursor), cursor + count)
            if end > cursor { delete(NSRange(location: cursor, length: end - cursor), linewise: false, yank: true) }
            enterInsert(at: cursor)
            finish(change: true)
        case "S": changeLines(count: count); finish(change: true)
        case "C":
            let end = lineEnd(cursor)
            delete(NSRange(location: cursor, length: end - cursor), linewise: false, yank: true)
            enterInsert(at: cursor)
            finish(change: true)
        case "D":
            let end = lineEnd(cursor)
            delete(NSRange(location: cursor, length: end - cursor), linewise: false, yank: true)
            moveCursor(to: cursor)
            finish(change: true)
        case "Y": yankLines(count: count); finish(change: false)
        case "p", "P": paste(after: c == "p", times: count); finish(change: true)
        case "J": joinLines(count: max(2, count)); finish(change: true)
        case "~": toggleCaseUnderCursor(count: count); finish(change: true)
        case "u":
            repeatCount { self.view?.undoManager?.undo() }
            settleAfterUndo()
            finish(change: false)
        case ".":
            let times = count
            resetPending()
            replay(times: times)
        case "v": beginVisual(.visual); finish(change: false)
        case "V": beginVisual(.visualLine); finish(change: false)
        case ":", "/", "?":
            resetPending()
            commandLine = String(c)
        case "n", "N": return applyMotion(c)
        case "*", "#":
            if let word = wordUnderCursor() {
                lastSearch = ("\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b", c == "*")
                _ = applyMotion("n")
            }
            finish(change: false)
        default:
            return applyMotion(c)
        }
        return true
    }

    private func handlePrefix(_ key: VimKey) -> Bool {
        guard case let .char(c) = key else {
            resetPending()
            return true
        }
        let first = prefix
        prefix = ""
        switch first {
        case "g":
            switch c {
            case "g": return applyMotion("G", gg: true)
            case "d":
                if let word = wordUnderCursor() { onAction?(.searchWord(word)) }
                finish(change: false)
            case "u", "U", "~":
                pendingOperator = "g" + String(c)
            default:
                finish(change: false)
            }
        case "z":
            switch c {
            case "z": scrollCursor(to: .center)
            case "t": scrollCursor(to: .top)
            case "b": scrollCursor(to: .bottom)
            default: break
            }
            finish(change: false)
        case "Z":
            if c == "Z" { onAction?(.saveAndClose) } else if c == "Q" { onAction?(.close) }
            finish(change: false)
        case "r":
            replaceChars(with: c, count: count)
            finish(change: true)
        case "f", "F", "t", "T":
            lastFind = (Character(first), c)
            return applyMotion(Character(first), findChar: c)
        default:
            finish(change: false)
        }
        return true
    }

    // MARK: Motions

    @discardableResult
    private func applyMotion(_ c: Character, gg: Bool = false, findChar: Character? = nil) -> Bool {
        guard let motion = motion(c, from: cursor, gg: gg, findChar: findChar) else {
            if c.isLetter || "{}%$^0;,".contains(c) { NSSound.beep() }
            finish(change: false)
            return true
        }
        let keepColumn = c == "j" || c == "k"
        if mode == .normal {
            moveCursor(to: motion.target, keepColumn: keepColumn)
        } else {
            moveCursor(to: motion.target, keepColumn: keepColumn)
        }
        finish(change: false)
        return true
    }

    private func motion(_ c: Character, from position: Int, gg: Bool = false, findChar: Character? = nil,
                        forOperator: Bool = false) -> Motion? {
        let n = count
        switch c {
        case "h":
            return Motion(target: max(lineStart(position), position - n), kind: .exclusive)
        case "l", " ":
            let limit = forOperator ? lineEnd(position) : lastCharIndex(position)
            return Motion(target: min(limit, position + n), kind: .exclusive)
        case "j", "k":
            let column = desiredColumn ?? column(position)
            var line = lineStart(position)
            for _ in 0..<n {
                let next = c == "j" ? nextLineStart(line) : previousLineStart(line)
                if next == line { break }
                line = next
            }
            if line == lineStart(position) { return forOperator ? Motion(target: position, kind: .linewise) : nil }
            desiredColumn = column
            let target = column == .max ? lastCharIndex(line) : min(line + column, lastCharIndex(line))
            return Motion(target: target, kind: .linewise)
        case "w", "W":
            var target = position
            for _ in 0..<n { target = nextWordStart(target, big: c == "W") }
            if forOperator, lineStart(target) != lineStart(position), target > lineEnd(position) {
                // "dw" on a line's last word stops at the end of the line.
                let end = lineEnd(position)
                if end > position { target = end }
            }
            return Motion(target: target, kind: .exclusive)
        case "b", "B":
            var target = position
            for _ in 0..<n { target = previousWordStart(target, big: c == "B") }
            return Motion(target: target, kind: .exclusive)
        case "e", "E":
            var target = position
            for _ in 0..<n { target = wordEnd(target, big: c == "E") }
            return Motion(target: target, kind: .inclusive)
        case "0":
            return Motion(target: lineStart(position), kind: .exclusive)
        case "^", "_":
            return Motion(target: firstNonBlank(position), kind: .exclusive)
        case "$":
            var line = lineStart(position)
            for _ in 1..<max(1, n) { line = nextLineStart(line) }
            desiredColumn = .max
            return Motion(target: forOperator ? max(line, lineEnd(line) - 1) : lastCharIndex(line), kind: .inclusive)
        case "G":
            let number = hasExplicitCount ? n : (gg ? 1 : lastLineNumber)
            return Motion(target: firstNonBlank(startOfLine(number: min(number, lastLineNumber))), kind: .linewise)
        case "}", "{":
            var target = position
            for _ in 0..<n { target = c == "}" ? nextParagraph(target) : previousParagraph(target) }
            return Motion(target: target, kind: .exclusive)
        case "%":
            return matchingBracket(from: position).map { Motion(target: $0, kind: .inclusive) }
        case "f", "F", "t", "T":
            guard let findChar else { return nil }
            return find(c, findChar, from: position, times: n)
        case ";", ",":
            guard let last = lastFind else { return nil }
            var kind = last.kind
            if c == "," { kind = Character(String(kind).uppercased() == String(kind) ? String(kind).lowercased() : String(kind).uppercased()) }
            return find(kind, last.char, from: position, times: n, repeating: true)
        case "n", "N":
            guard let search = lastSearch else { return nil }
            var target = position
            for _ in 0..<n {
                guard let found = searchPattern(search.pattern, from: target, forward: c == "n" ? search.forward : !search.forward)
                else { return nil }
                target = found
            }
            return Motion(target: target, kind: .exclusive)
        case "H", "L", "M":
            return nil
        default:
            return nil
        }
    }

    private func nextLineStart(_ position: Int) -> Int {
        let end = lineEnd(position)
        return end < length ? end + 1 : lineStart(position)
    }

    private func previousLineStart(_ position: Int) -> Int {
        let start = lineStart(position)
        return start > 0 ? lineStart(start - 1) : start
    }

    private func nextWordStart(_ position: Int, big: Bool) -> Int {
        var index = position
        guard index < length else { return length }
        let start = wordClass(index, big: big)
        if start == 1 || start == 2 { while index < length, wordClass(index, big: big) == start { index += 1 } }
        while index < length {
            let kind = wordClass(index, big: big)
            if kind == 0 { index += 1; continue }
            if kind == 3 {
                index += 1
                if index < length, wordClass(index, big: big) == 3 { return index } // empty line stops
                continue
            }
            break
        }
        return index
    }

    private func previousWordStart(_ position: Int, big: Bool) -> Int {
        var index = position - 1
        guard index > 0 else { return 0 }
        while index > 0 {
            let kind = wordClass(index, big: big)
            if kind == 0 { index -= 1; continue }
            if kind == 3 {
                if wordClass(index - 1, big: big) == 3 { return index }
                index -= 1
                continue
            }
            break
        }
        let kind = wordClass(index, big: big)
        while index > 0, wordClass(index - 1, big: big) == kind { index -= 1 }
        return index
    }

    private func wordEnd(_ position: Int, big: Bool) -> Int {
        var index = position + 1
        while index < length, [0, 3].contains(wordClass(index, big: big)) { index += 1 }
        guard index < length else { return max(0, length - 1) }
        let kind = wordClass(index, big: big)
        while index + 1 < length, wordClass(index + 1, big: big) == kind { index += 1 }
        return index
    }

    private func isBlankLine(_ position: Int) -> Bool { lineStart(position) == lineEnd(position) }

    private func nextParagraph(_ position: Int) -> Int {
        var line = lineStart(position)
        while isBlankLine(line), nextLineStart(line) != line { line = nextLineStart(line) }
        while !isBlankLine(line) {
            let next = nextLineStart(line)
            if next == line { return lastCharIndex(line) }
            line = next
        }
        return line
    }

    private func previousParagraph(_ position: Int) -> Int {
        var line = lineStart(position)
        while isBlankLine(line), previousLineStart(line) != line { line = previousLineStart(line) }
        while !isBlankLine(line) {
            let previous = previousLineStart(line)
            if previous == line { return line }
            line = previous
        }
        return line
    }

    private func find(_ kind: Character, _ target: Character, from position: Int, times: Int,
                      repeating: Bool = false) -> Motion? {
        guard let unit = String(target).utf16.first else { return nil }
        let start = lineStart(position)
        let end = lineEnd(position)
        var index = position
        for iteration in 0..<times {
            switch kind {
            case "f", "t":
                var probe = index + 1
                if kind == "t", repeating || iteration > 0 { probe += 1 }
                while probe < end, char(probe) != unit { probe += 1 }
                guard probe < end else { return nil }
                index = kind == "t" ? probe - 1 : probe
            default:
                var probe = index - 1
                if kind == "T", repeating || iteration > 0 { probe -= 1 }
                while probe >= start, char(probe) != unit { probe -= 1 }
                guard probe >= start else { return nil }
                index = kind == "T" ? probe + 1 : probe
            }
        }
        return Motion(target: index, kind: kind == "f" || kind == "t" ? .inclusive : .exclusive)
    }

    private func matchingBracket(from position: Int) -> Int? {
        let pairs: [unichar: (unichar, Bool)] = [40: (41, true), 91: (93, true), 123: (125, true),
                                                 41: (40, false), 93: (91, false), 125: (123, false)]
        var index = position
        let end = lineEnd(position)
        while index < end, pairs[char(index)] == nil { index += 1 }
        guard index < end, let (match, forward) = pairs[char(index)] else { return nil }
        let open = char(index)
        var depth = 0
        var probe = index
        while probe >= 0, probe < length {
            if char(probe) == open { depth += 1 } else if char(probe) == match { depth -= 1 }
            if depth == 0 { return probe }
            probe += forward ? 1 : -1
        }
        return nil
    }

    private func searchPattern(_ pattern: String, from position: Int, forward: Bool) -> Int? {
        let smartCase = pattern == pattern.lowercased()
        guard let regex = try? NSRegularExpression(pattern: pattern, options: smartCase ? [.caseInsensitive] : []) else {
            return nil
        }
        let string = view?.string ?? ""
        let matches = regex.matches(in: string, range: NSRange(location: 0, length: length)).map(\.range.location)
        guard !matches.isEmpty else { return nil }
        if forward { return matches.first { $0 > position } ?? matches.first } // wraps around
        return matches.last { $0 < position } ?? matches.last
    }

    private func wordUnderCursor() -> String? {
        CodeTextView.identifierRange(in: text, at: cursor).map { text.substring(with: $0) }
    }

    // MARK: Operators

    private func handleOperatorPending(_ key: VimKey, op: String) -> Bool {
        guard case let .char(c) = key else {
            resetPending()
            return true
        }
        if !prefix.isEmpty {
            let first = prefix
            prefix = ""
            switch first {
            case "i", "a":
                if let object = textObject(c, around: first == "a", at: cursor) {
                    applyOperator(op, range: object.range, linewise: object.linewise)
                } else {
                    resetPending()
                }
            case "f", "F", "t", "T":
                lastFind = (Character(first), c)
                return applyOperatorMotion(op, motionKey: Character(first), findChar: c)
            case "g":
                if c == "g" { return applyOperatorMotion(op, motionKey: "G", gg: true) }
                if op.hasPrefix("g"), String(c) == String(op.dropFirst()) { return applyLinewiseOperator(op) } // gugu
                resetPending()
            default:
                resetPending()
            }
            return true
        }
        if c.isNumber, c != "0" || !operatorCount.isEmpty {
            operatorCount.append(c)
            return true
        }
        // Doubled operator: dd, cc, yy, >>, <<, guu, gUU, g~~.
        if String(c) == op || (op.hasPrefix("g") && String(c) == String(op.dropFirst())) {
            return applyLinewiseOperator(op)
        }
        if ["i", "a", "f", "F", "t", "T", "g"].contains(c) {
            prefix = String(c)
            return true
        }
        return applyOperatorMotion(op, motionKey: c)
    }

    /// `count` whole lines from the cursor's line.
    private func applyLinewiseOperator(_ op: String) -> Bool {
        let start = lineStart(cursor)
        var last = start
        for _ in 1..<max(1, count) {
            let next = nextLineStart(last)
            if next == last { break }
            last = next
        }
        applyOperator(op, range: NSRange(location: start, length: lineEnd(last) - start), linewise: true)
        return true
    }

    private func applyOperatorMotion(_ op: String, motionKey c: Character, findChar: Character? = nil, gg: Bool = false) -> Bool {
        // "cw" behaves like "ce" on a word.
        let key: Character = op == "c" && (c == "w" || c == "W") && wordClass(cursor, big: c == "W") != 0
            ? (c == "w" ? "e" : "E") : c
        guard let motion = motion(key, from: cursor, gg: gg, findChar: findChar, forOperator: true) else {
            resetPending()
            return true
        }
        let start = min(cursor, motion.target)
        let end = max(cursor, motion.target)
        switch motion.kind {
        case .linewise:
            applyOperator(op, range: NSRange(location: lineStart(start), length: lineEnd(end) - lineStart(start)), linewise: true)
        case .inclusive:
            applyOperator(op, range: NSRange(location: start, length: min(length, end + 1) - start), linewise: false)
        case .exclusive:
            applyOperator(op, range: NSRange(location: start, length: end - start), linewise: false)
        }
        return true
    }

    /// `range` is the operated text; for linewise operations it spans whole lines without the final newline.
    private func applyOperator(_ op: String, range: NSRange, linewise: Bool) {
        guard let view else { return }
        switch op {
        case "y":
            register = (text.substring(with: range) + (linewise ? "\n" : ""), linewise)
            let wasVisual = mode != .normal
            if wasVisual { mode = .normal }
            // Yanking with a motion (or in Visual) moves to the start; "yy" leaves the cursor alone.
            if !linewise || wasVisual { moveCursor(to: range.location) } else { moveCursor(to: cursor) }
            finish(change: false)
            return
        case "d":
            delete(range, linewise: linewise, yank: true)
            if mode != .normal { mode = .normal }
            moveCursor(to: linewise ? firstNonBlank(min(range.location, max(0, length - 1))) : range.location)
        case "c":
            if mode != .normal { mode = .normal }
            if linewise {
                let indent = text.substring(with: NSRange(location: range.location,
                                                          length: firstNonBlank(range.location) - range.location))
                register = (text.substring(with: range) + "\n", true)
                view.replace(range, with: indent, select: NSRange(location: range.location + (indent as NSString).length, length: 0))
                enterInsert(at: range.location + (indent as NSString).length)
            } else {
                delete(range, linewise: false, yank: true)
                enterInsert(at: range.location)
            }
        case ">", "<":
            let lines = NSRange(location: lineStart(range.location), length: lineEnd(NSMaxRange(range)) - lineStart(range.location))
            let block = text.substring(with: lines)
            let unit = view.indentUnit()
            let result = op == ">" ? CodeTextView.indented(block, unit: unit) : CodeTextView.outdented(block, unit: unit)
            view.replace(lines, with: result, select: NSRange(location: lines.location, length: 0))
            if mode != .normal { mode = .normal }
            moveCursor(to: firstNonBlank(lines.location))
        case "gu", "gU", "g~":
            let original = text.substring(with: range)
            let changed: String
            switch op {
            case "gu": changed = original.lowercased()
            case "gU": changed = original.uppercased()
            default: changed = String(original.map { $0.isUppercase ? Character($0.lowercased()) : Character($0.uppercased()) })
            }
            view.replace(range, with: changed, select: NSRange(location: range.location, length: 0))
            if mode != .normal { mode = .normal }
            moveCursor(to: range.location)
        default:
            break
        }
        finish(change: true)
    }

    /// Deletes `range` (linewise ranges also remove their line break) and fills the register.
    private func delete(_ range: NSRange, linewise: Bool, yank: Bool) {
        guard let view else { return }
        var target = range
        if linewise {
            if NSMaxRange(target) < length {
                target.length += 1 // the newline after the block
            } else if target.location > 0 {
                target = NSRange(location: target.location - 1, length: target.length + 1) // last line: the one before
            }
        }
        if yank { register = (text.substring(with: range) + (linewise ? "\n" : ""), linewise) }
        view.replace(target, with: "", select: NSRange(location: min(target.location, length - target.length), length: 0))
    }

    // MARK: Text objects

    private func textObject(_ c: Character, around: Bool, at position: Int) -> (range: NSRange, linewise: Bool)? {
        switch c {
        case "w", "W":
            let big = c == "W"
            let kind = wordClass(position, big: big)
            guard kind != 3 else { return nil }
            var start = position
            var end = position + 1
            while start > lineStart(position), wordClass(start - 1, big: big) == kind { start -= 1 }
            while end < lineEnd(position), wordClass(end, big: big) == kind { end += 1 }
            if around {
                let trailingStart = end
                while end < lineEnd(position), wordClass(end, big: big) == 0 { end += 1 }
                if end == trailingStart { while start > lineStart(position), wordClass(start - 1, big: big) == 0 { start -= 1 } }
            }
            return (NSRange(location: start, length: end - start), false)
        case "\"", "'", "`":
            guard let unit = String(c).utf16.first else { return nil }
            let start = lineStart(position)
            let end = lineEnd(position)
            var quotes: [Int] = []
            var index = start
            while index < end {
                if char(index) == unit, index == start || char(index - 1) != 92 { quotes.append(index) }
                index += 1
            }
            var pairs: [(Int, Int)] = []
            var i = 0
            while i + 1 < quotes.count { pairs.append((quotes[i], quotes[i + 1])); i += 2 }
            guard let pair = pairs.first(where: { $0.0 <= position && position <= $0.1 }) ?? pairs.first(where: { $0.0 > position })
            else { return nil }
            return around
                ? (NSRange(location: pair.0, length: pair.1 - pair.0 + 1), false)
                : (NSRange(location: pair.0 + 1, length: pair.1 - pair.0 - 1), false)
        case "(", ")", "b", "[", "]", "{", "}", "B", "<", ">":
            let (open, close): (unichar, unichar) = {
                switch c {
                case "[", "]": return (91, 93)
                case "{", "}", "B": return (123, 125)
                case "<", ">": return (60, 62)
                default: return (40, 41)
                }
            }()
            var depth = 0
            var start = position
            if char(start) == close { start -= 1 }
            while start >= 0 {
                if char(start) == close, start != position { depth += 1 }
                if char(start) == open { if depth == 0 { break }; depth -= 1 }
                start -= 1
            }
            guard start >= 0 else { return nil }
            depth = 0
            var end = start + 1
            while end < length {
                if char(end) == open { depth += 1 }
                if char(end) == close { if depth == 0 { break }; depth -= 1 }
                end += 1
            }
            guard end < length else { return nil }
            return around
                ? (NSRange(location: start, length: end - start + 1), false)
                : (NSRange(location: start + 1, length: end - start - 1), false)
        case "p":
            var first = lineStart(position)
            var last = first
            while previousLineStart(first) != first, !isBlankLine(previousLineStart(first)) { first = previousLineStart(first) }
            while nextLineStart(last) != last, !isBlankLine(nextLineStart(last)) { last = nextLineStart(last) }
            if around { while nextLineStart(last) != last, isBlankLine(nextLineStart(last)) { last = nextLineStart(last) } }
            return (NSRange(location: first, length: lineEnd(last) - first), true)
        default:
            return nil
        }
    }

    // MARK: Simple changes

    private func openLine(below: Bool) {
        guard let view else { return }
        let indent = text.substring(with: NSRange(location: lineStart(cursor), length: firstNonBlank(cursor) - lineStart(cursor)))
        if below {
            let end = lineEnd(cursor)
            view.replace(NSRange(location: end, length: 0), with: "\n" + indent,
                         select: NSRange(location: end + 1 + (indent as NSString).length, length: 0))
            mode = .insert
            insertStart = end + 1 + (indent as NSString).length
        } else {
            let start = lineStart(cursor)
            view.replace(NSRange(location: start, length: 0), with: indent + "\n",
                         select: NSRange(location: start + (indent as NSString).length, length: 0))
            mode = .insert
            insertStart = start + (indent as NSString).length
        }
    }

    private func changeLines(count: Int) {
        let start = lineStart(cursor)
        var last = start
        for _ in 1..<max(1, count) { last = nextLineStart(last) }
        if mode == .normal { applyOperatorRangeChange(NSRange(location: start, length: lineEnd(last) - start)) }
    }

    private func applyOperatorRangeChange(_ range: NSRange) {
        guard let view else { return }
        let indent = text.substring(with: NSRange(location: range.location, length: firstNonBlank(range.location) - range.location))
        register = (text.substring(with: range) + "\n", true)
        view.replace(range, with: indent, select: NSRange(location: range.location + (indent as NSString).length, length: 0))
        enterInsert(at: range.location + (indent as NSString).length)
    }

    private func yankLines(count: Int) {
        let start = lineStart(cursor)
        var last = start
        for _ in 1..<max(1, count) { last = nextLineStart(last) }
        register = (text.substring(with: NSRange(location: start, length: lineEnd(last) - start)) + "\n", true)
    }

    private func paste(after: Bool, times: Int) {
        guard let view, !register.text.isEmpty else { return }
        let content = String(repeating: register.text, count: times)
        if register.linewise {
            if after {
                let end = lineEnd(cursor)
                if end < length {
                    view.replace(NSRange(location: end + 1, length: 0), with: content, select: NSRange(location: end + 1, length: 0))
                    moveCursor(to: firstNonBlank(end + 1))
                } else { // last line without a trailing newline
                    let body = String(content.dropLast())
                    view.replace(NSRange(location: end, length: 0), with: "\n" + body, select: NSRange(location: end + 1, length: 0))
                    moveCursor(to: firstNonBlank(end + 1))
                }
            } else {
                let start = lineStart(cursor)
                view.replace(NSRange(location: start, length: 0), with: content, select: NSRange(location: start, length: 0))
                moveCursor(to: firstNonBlank(start))
            }
        } else {
            let at = after && lineEnd(cursor) > lineStart(cursor) ? min(length, cursor + 1) : cursor
            view.replace(NSRange(location: at, length: 0), with: content, select: NSRange(location: at, length: 0))
            moveCursor(to: at + (content as NSString).length - 1)
        }
    }

    private func joinLines(count: Int) {
        guard let view else { return }
        for _ in 1..<count {
            let end = lineEnd(cursor)
            guard end < length else { break }
            var next = end + 1
            while next < length, char(next) == 32 || char(next) == 9 { next += 1 }
            let separator = next < length && char(next) != 10 && char(next) != 41 && end > lineStart(cursor) ? " " : ""
            view.replace(NSRange(location: end, length: next - end), with: separator, select: NSRange(location: end, length: 0))
            moveCursor(to: end)
        }
    }

    private func replaceChars(with c: Character, count: Int) {
        guard let view else { return }
        let end = lineEnd(cursor)
        guard cursor + count <= end else { return }
        view.replace(NSRange(location: cursor, length: count), with: String(repeating: String(c), count: count),
                     select: NSRange(location: cursor + count - 1, length: 0))
        moveCursor(to: cursor)
    }

    private func toggleCaseUnderCursor(count: Int) {
        guard let view else { return }
        let end = min(lineEnd(cursor), cursor + count)
        guard end > cursor else { return }
        let range = NSRange(location: cursor, length: end - cursor)
        let original = text.substring(with: range)
        let changed = String(original.map { $0.isUppercase ? Character($0.lowercased()) : Character($0.uppercased()) })
        view.replace(range, with: changed, select: NSRange(location: end, length: 0))
        moveCursor(to: end)
    }

    private func repeatCount(_ action: () -> Void) {
        for _ in 0..<count { action() }
    }

    /// After undo/redo the text view selects the changed text; Normal mode wants a plain cursor.
    private func settleAfterUndo() {
        guard let view else { return }
        moveCursor(to: view.selectedRange().location)
    }

    private func replay(times: Int) {
        guard !lastChange.isEmpty else { return }
        replaying = true
        defer { replaying = false }
        for _ in 0..<times {
            for key in lastChange { handle(key) }
            if mode == .insert { _ = handleInsert(.escape) }
        }
    }

    // MARK: Visual mode

    private func beginVisual(_ kind: Mode) {
        let position = cursor
        mode = kind
        visualAnchor = position
        visualCursor = position
        applyVisualSelection()
    }

    private func endVisual(at position: Int? = nil) {
        let target = position ?? visualCursor
        mode = .normal
        moveCursor(to: target)
    }

    private func handleVisual(_ key: VimKey) -> Bool {
        if !prefix.isEmpty {
            if prefix == "i" || prefix == "a" {
                let around = prefix == "a"
                prefix = ""
                if case let .char(c) = key, let object = textObject(c, around: around, at: visualCursor) {
                    visualAnchor = object.range.location
                    visualCursor = max(object.range.location, NSMaxRange(object.range) - 1)
                    applyVisualSelection()
                }
                return true
            }
            if prefix == "g", case let .char(c) = key {
                prefix = ""
                if c == "g" { return applyMotion("G", gg: true) }
                if c == "u" || c == "U" || c == "~" { visualOperator("g" + String(c)); return true }
                return true
            }
            return handleNormalPrefixInVisual(key)
        }
        switch key {
        case .escape:
            endVisual()
            resetPending()
        case let .ctrl(c):
            return handleControl(c)
        case let .char(c):
            if c.isNumber, c != "0" || !countDigits.isEmpty {
                countDigits.append(c)
                return true
            }
            switch c {
            case "v": mode == .visual ? endVisual() : beginVisualSwitch(.visual)
            case "V": mode == .visualLine ? endVisual() : beginVisualSwitch(.visualLine)
            case "o":
                swap(&visualAnchor, &visualCursor)
                applyVisualSelection()
            // "dl" = delete whole lines (X / D in Visual, or any delete in Visual-line).
            case "d", "x", "X", "D": visualOperator(mode == .visualLine || c == "X" || c == "D" ? "dl" : "d")
            case "y", "Y": visualOperator("y")
            case "c", "s": visualOperator("c")
            case ">", "<": visualOperator(String(c))
            case "~": visualOperator("g~")
            case "u": visualOperator("gu")
            case "U": visualOperator("gU")
            case "J":
                let (range, _) = visualRange
                let lines = max(2, lineNumber(NSMaxRange(range)) - lineNumber(range.location) + 1)
                endVisual(at: range.location)
                joinLines(count: lines)
                finish(change: true)
            case "p", "P":
                let (range, linewise) = visualRange
                let saved = register
                delete(range, linewise: linewise, yank: false)
                mode = .normal
                moveCursor(to: range.location)
                register = saved
                paste(after: false, times: 1)
                finish(change: true)
            case "i", "a", "g", "f", "F", "t", "T":
                prefix = String(c)
            case ":", "/", "?":
                endVisual()
                commandLine = String(c)
            default:
                return applyMotion(c)
            }
        default:
            return true
        }
        return true
    }

    private func handleNormalPrefixInVisual(_ key: VimKey) -> Bool {
        guard case let .char(c) = key else { prefix = ""; return true }
        let first = prefix
        prefix = ""
        if ["f", "F", "t", "T"].contains(first) {
            lastFind = (Character(first), c)
            return applyMotion(Character(first), findChar: c)
        }
        return true
    }

    private func beginVisualSwitch(_ kind: Mode) {
        mode = kind
        applyVisualSelection()
    }

    private func visualOperator(_ op: String) {
        let (range, linewise) = visualRange
        let realOp = op == "dl" ? "d" : op
        let isLinewise = linewise || op == "dl"
        let operated = isLinewise && !linewise
            ? NSRange(location: lineStart(range.location), length: lineEnd(NSMaxRange(range)) - lineStart(range.location))
            : range
        mode = .normal
        setSelection(NSRange(location: operated.location, length: 0))
        applyOperator(realOp, range: operated, linewise: isLinewise)
    }

    // MARK: Command line (: / ?)

    private func handleCommandLine(_ key: VimKey, line: String) -> Bool {
        switch key {
        case .escape:
            commandLine = nil
        case .backspace:
            commandLine = line.count > 1 ? String(line.dropLast()) : nil
        case .enter:
            commandLine = nil
            execute(line)
        case let .char(c):
            commandLine = line + String(c)
        default:
            break
        }
        notify()
        return true
    }

    private func execute(_ line: String) {
        let body = String(line.dropFirst())
        switch line.first {
        case "/", "?":
            let forward = line.first == "/"
            let pattern = body.isEmpty ? (lastSearch?.pattern ?? "") : body
            guard !pattern.isEmpty else { return }
            lastSearch = (pattern, forward)
            if let found = searchPattern(pattern, from: cursor, forward: forward) { moveCursor(to: found) } else { NSSound.beep() }
        default:
            executeEx(body.trimmingCharacters(in: .whitespaces))
        }
    }

    private func executeEx(_ command: String) {
        switch command {
        case "w": onAction?(.save)
        case "q", "q!": onAction?(.close)
        case "wq", "x", "wq!": onAction?(.saveAndClose)
        case "noh", "nohlsearch": break
        default:
            if let number = Int(command) {
                moveCursor(to: firstNonBlank(startOfLine(number: min(max(1, number), lastLineNumber))))
            } else if command.hasPrefix("s/") || command.hasPrefix("%s/") {
                substitute(command)
            } else {
                NSSound.beep()
            }
        }
    }

    /// `:s/pattern/replacement/[gi]` on the current line, or `:%s/…` on the whole file.
    private func substitute(_ command: String) {
        guard let view else { return }
        let whole = command.hasPrefix("%")
        let spec = String(command.dropFirst(whole ? 3 : 2))
        var parts: [String] = []
        var current = ""
        var escaped = false
        for character in spec {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" { current.append(character); escaped = true; continue }
            if character == "/" { parts.append(current); current = ""; continue }
            current.append(character)
        }
        parts.append(current)
        guard parts.count >= 2, !parts[0].isEmpty else { return NSSound.beep() }
        let flags = parts.count > 2 ? parts[2] : ""
        guard let regex = try? NSRegularExpression(pattern: parts[0], options: flags.contains("i") ? [.caseInsensitive] : [])
        else { return NSSound.beep() }
        let template = parts[1].replacingOccurrences(of: "\\&", with: "$0").replacingOccurrences(of: "&", with: "$0")
        let scope = whole ? NSRange(location: 0, length: length) : NSRange(location: lineStart(cursor), length: lineEnd(cursor) - lineStart(cursor))
        let source = text.substring(with: scope)
        let sourceRange = NSRange(location: 0, length: (source as NSString).length)
        let result: String
        if flags.contains("g") {
            result = regex.stringByReplacingMatches(in: source, range: sourceRange, withTemplate: template)
        } else {
            // First match per line.
            result = source.components(separatedBy: "\n").map { line in
                let range = NSRange(location: 0, length: (line as NSString).length)
                guard let match = regex.firstMatch(in: line, range: range) else { return line }
                let replacement = regex.replacementString(for: match, in: line, offset: 0, template: template)
                return (line as NSString).replacingCharacters(in: match.range, with: replacement)
            }.joined(separator: "\n")
        }
        guard result != source else { return NSSound.beep() }
        let position = cursor
        view.replace(scope, with: result, select: NSRange(location: 0, length: 0))
        moveCursor(to: firstNonBlank(min(position, length)))
    }

    // MARK: Scrolling

    private enum ScrollPosition { case top, center, bottom }

    private var visibleLineCount: Int {
        guard let view, let font = view.font, let scroll = view.enclosingScrollView else { return 20 }
        let lineHeight = view.layoutManager?.defaultLineHeight(for: font) ?? 16
        return max(1, Int(scroll.contentView.bounds.height / lineHeight))
    }

    private func scrollCursor(to position: ScrollPosition) {
        guard let view, let layoutManager = view.layoutManager, let container = view.textContainer,
              let scroll = view.enclosingScrollView else { return }
        let glyph = layoutManager.glyphIndexForCharacter(at: min(cursor, max(0, length - 1)))
        let rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        _ = container
        let visible = scroll.contentView.bounds
        let y: CGFloat
        switch position {
        case .top: y = rect.minY
        case .center: y = rect.midY - visible.height / 2
        case .bottom: y = rect.maxY - visible.height
        }
        scroll.contentView.scroll(to: NSPoint(x: visible.minX, y: max(0, y + view.textContainerOrigin.y)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    // MARK: Testing / external

    /// Feeds a string of plain keys (tests).
    func feed(_ keys: String) {
        for character in keys {
            switch character {
            case "\u{1B}": handle(.escape)
            case "\n": handle(mode == .insert ? .text("\n") : .enter)
            default: handle(mode == .insert ? .text(String(character)) : .char(character))
            }
        }
    }
}
