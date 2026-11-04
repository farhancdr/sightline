import AppKit

enum TokenKind: Sendable {
    case keyword, string, comment, number, type, function, constant, key, attribute, variable
    case heading, emphasis, link, tag, code
}

struct SyntaxToken: Sendable {
    let range: NSRange
    let kind: TokenKind
}

/// VS Code Dark+/Light+-like colors that follow the current appearance.
enum SyntaxTheme {
    static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return rgb(isDark ? dark : light)
        }
    }

    static func dynamicAlpha(light: UInt32, lightAlpha: CGFloat, dark: UInt32, darkAlpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return rgb(isDark ? dark : light).withAlphaComponent(isDark ? darkAlpha : lightAlpha)
        }
    }

    static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    // GitHub Light Default / Dark Default (github-vscode-theme token colors).
    static let text = dynamic(light: 0x1F2328, dark: 0xE6EDF3)
    static let keyword = dynamic(light: 0xCF222E, dark: 0xFF7B72)
    static let string = dynamic(light: 0x0A3069, dark: 0xA5D6FF)
    static let comment = dynamic(light: 0x59636E, dark: 0x9198A1)
    static let number = dynamic(light: 0x0550AE, dark: 0x79C0FF)
    static let type = dynamic(light: 0x953800, dark: 0xFFA657)
    static let function = dynamic(light: 0x8250DF, dark: 0xD2A8FF)
    static let constant = dynamic(light: 0x0550AE, dark: 0x79C0FF)
    static let key = dynamic(light: 0x0550AE, dark: 0x79C0FF)
    static let attribute = dynamic(light: 0x8250DF, dark: 0xD2A8FF)
    static let variable = dynamic(light: 0x953800, dark: 0xFFA657)
    static let heading = dynamic(light: 0x0550AE, dark: 0x1F6FEB)
    static let link = dynamic(light: 0x0969DA, dark: 0x4493F8)
    static let tag = dynamic(light: 0x116329, dark: 0x7EE787)

    static func color(_ kind: TokenKind) -> NSColor {
        switch kind {
        case .keyword: keyword
        case .string, .code: string
        case .comment: comment
        case .number: number
        case .type: type
        case .function: function
        case .constant: constant
        case .key: key
        case .attribute: attribute
        case .variable: variable
        case .heading, .emphasis: heading
        case .link: link
        case .tag: tag
        }
    }
}

enum SyntaxHighlighter {
    static let maxHighlightLength = 1_000_000

    static func tokens(for text: String, language: Language) -> [SyntaxToken] {
        switch language.mode {
        case .plain: []
        case .code: CodeScanner(text: text, language: language).scan()
        case .markdown: markdownTokens(text)
        case .markup: markupTokens(text)
        }
    }

    /// Applies colors to `storage`. Only attributes change, so undo and selection are untouched.
    static func apply(_ tokens: [SyntaxToken], to storage: NSTextStorage, font: NSFont, boldFont: NSFont) {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.addAttribute(.foregroundColor, value: SyntaxTheme.text, range: full)
        storage.addAttribute(.font, value: font, range: full)
        for token in tokens where NSMaxRange(token.range) <= storage.length {
            storage.addAttribute(.foregroundColor, value: SyntaxTheme.color(token.kind), range: token.range)
            if token.kind == .heading || token.kind == .emphasis {
                storage.addAttribute(.font, value: boldFont, range: token.range)
            }
        }
        storage.endEditing()
    }

    // MARK: Markdown / MDX

    private static let mdHeading = regex(#"^#{1,6}\s.*$"#)
    private static let mdQuote = regex(#"^\s*>.*$"#)
    private static let mdList = regex(#"^\s*(?:[-*+]|\d+\.)\s"#)
    private static let mdInlineCode = regex(#"`[^`\n]+`"#)
    private static let mdBold = regex(#"(\*\*|__)[^\n]+?\1"#)
    private static let mdLink = regex(#"!?\[[^\]\n]*\]\([^)\n]*\)"#)
    private static let mdHTML = regex(#"</?[A-Za-z][^>\n]*>"#)
    private static let mdModule = regex(#"^(?:import|export)\s.*$"#)
    private static let mdRule = regex(#"^\s*(?:---+|\*\*\*+)\s*$"#)

    private static func markdownTokens(_ text: String) -> [SyntaxToken] {
        let ns = text as NSString
        var tokens: [SyntaxToken] = []
        var fenced: [NSRange] = []

        // Fenced code blocks first; everything inside is one "code" token.
        var location = 0
        var fenceStart: Int?
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            let content = ns.substring(with: line).trimmingCharacters(in: .whitespaces)
            if content.hasPrefix("```") || content.hasPrefix("~~~") {
                if let start = fenceStart {
                    fenced.append(NSRange(location: start, length: NSMaxRange(line) - start))
                    fenceStart = nil
                } else {
                    fenceStart = line.location
                }
            }
            location = NSMaxRange(line)
        }
        if let start = fenceStart { fenced.append(NSRange(location: start, length: ns.length - start)) }

        let full = NSRange(location: 0, length: ns.length)
        let rules: [(NSRegularExpression, TokenKind)] = [
            (mdModule, .keyword), (mdHTML, .tag), (mdList, .keyword), (mdQuote, .comment),
            (mdLink, .link), (mdBold, .emphasis), (mdInlineCode, .code), (mdRule, .comment), (mdHeading, .heading),
        ]
        for (pattern, kind) in rules {
            for match in pattern.matches(in: text, range: full)
            where !fenced.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                tokens.append(SyntaxToken(range: match.range, kind: kind))
            }
        }
        tokens += fenced.map { SyntaxToken(range: $0, kind: .code) }
        return tokens
    }

    // MARK: HTML / XML

    private static let mlTag = regex(#"<[^<>]*>"#)
    private static let mlTagName = regex(#"^</?[\w:.\-!?]+"#)
    private static let mlAttribute = regex(#"\s([\w:.\-@]+)(?==)"#)
    private static let mlString = regex(#""[^"]*"|'[^']*'"#)
    private static let mlComment = regex(#"<!--[\s\S]*?-->"#)
    private static let mlEntity = regex(#"&[#\w]+;"#)

    private static func markupTokens(_ text: String) -> [SyntaxToken] {
        let ns = text as NSString
        var tokens: [SyntaxToken] = []
        let full = NSRange(location: 0, length: ns.length)
        for tag in mlTag.matches(in: text, range: full) {
            let tagText = ns.substring(with: tag.range)
            let local = NSRange(location: 0, length: (tagText as NSString).length)
            func shifted(_ range: NSRange) -> NSRange { NSRange(location: range.location + tag.range.location, length: range.length) }
            tokens.append(SyntaxToken(range: tag.range, kind: .tag))
            for m in mlTagName.matches(in: tagText, range: local) { tokens.append(SyntaxToken(range: shifted(m.range), kind: .tag)) }
            for m in mlAttribute.matches(in: tagText, range: local) {
                tokens.append(SyntaxToken(range: shifted(m.range(at: 1)), kind: .key))
            }
            for m in mlString.matches(in: tagText, range: local) { tokens.append(SyntaxToken(range: shifted(m.range), kind: .string)) }
        }
        for m in mlEntity.matches(in: text, range: full) { tokens.append(SyntaxToken(range: m.range, kind: .constant)) }
        for m in mlComment.matches(in: text, range: full) { tokens.append(SyntaxToken(range: m.range, kind: .comment)) }
        return tokens
    }

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are compile-time constants.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }
}

/// Single-pass scanner over UTF-16 code units, so comments and strings win correctly
/// (a `//` inside a string stays a string).
private struct CodeScanner {
    let s: [UInt16]
    let language: Language
    let lineComments: [[UInt16]]
    let blockOpen: [UInt16]?
    let blockClose: [UInt16]?
    let quotes: Set<UInt16>
    let multiline: Set<UInt16>
    let extras: Set<UInt16>
    let keySeparator: UInt16?
    let decorator: UInt16?

    init(text: String, language: Language) {
        s = Array(text.utf16)
        self.language = language
        lineComments = language.lineComments.map { Array($0.utf16) }
        blockOpen = language.blockComment.map { Array($0.open.utf16) }
        blockClose = language.blockComment.map { Array($0.close.utf16) }
        quotes = Set(language.quotes.compactMap { $0.utf16.first })
        multiline = Set(language.multilineQuotes.compactMap { $0.utf16.first })
        extras = Set(language.identifierExtras.compactMap { $0.utf16.first })
        keySeparator = language.keySeparator?.utf16.first
        decorator = language.decoratorPrefix?.utf16.first
    }

    private static let newline: UInt16 = 10
    private static let space: UInt16 = 32
    private static let tab: UInt16 = 9
    private static let backslash: UInt16 = 92
    private static let hash: UInt16 = 35
    private static let dollar: UInt16 = 36
    private static let dash: UInt16 = 45
    private static let dot: UInt16 = 46
    private static let quote: UInt16 = 39
    private static let openParen: UInt16 = 40
    private static let openBrace: UInt16 = 123
    private static let closeBrace: UInt16 = 125
    private static let openBracket: UInt16 = 91
    private static let closeBracket: UInt16 = 93

    func scan() -> [SyntaxToken] {
        var tokens: [SyntaxToken] = []
        let n = s.count
        var i = 0
        var atLineStart = true

        func emit(_ start: Int, _ end: Int, _ kind: TokenKind) {
            if end > start { tokens.append(SyntaxToken(range: NSRange(location: start, length: end - start), kind: kind)) }
        }

        while i < n {
            let c = s[i]
            if c == Self.newline { atLineStart = true; i += 1; continue }
            if c == Self.space || c == Self.tab || c == 13 { i += 1; continue }
            // YAML / markdown-ish list marker keeps "line start" so `- key:` is still a key.
            if c == Self.dash, atLineStart, i + 1 < n, s[i + 1] == Self.space { i += 1; continue }

            if let open = blockOpen, let close = blockClose, matches(open, at: i) {
                let end = find(close, from: i + open.count).map { $0 + close.count } ?? n
                emit(i, end, .comment)
                i = end; atLineStart = false; continue
            }
            if let marker = lineComments.first(where: { matches($0, at: i) }),
               marker != [Self.hash] || i == 0 || isSpace(s[i - 1]) {
                let end = lineEnd(from: i)
                emit(i, end, .comment)
                i = end; continue
            }
            if quotes.contains(c) {
                if let end = scanString(at: i) {
                    let kind: TokenKind = isKey(after: end) ? .key : .string
                    emit(i, end, kind)
                    i = end; atLineStart = false; continue
                }
                i += 1; atLineStart = false; continue
            }
            if language.dollarVariables, c == Self.dollar, i + 1 < n {
                var j = i + 1
                if s[j] == Self.openBrace {
                    while j < n, s[j] != Self.closeBrace, s[j] != Self.newline { j += 1 }
                    j = min(n, j + 1)
                } else if isIdentStart(s[j]) {
                    while j < n, isIdentChar(s[j]), s[j] != Self.dash { j += 1 }
                } else {
                    j += 1 // $1, $@, $?
                }
                emit(i, j, .variable)
                i = j; atLineStart = false; continue
            }
            if let decorator, c == decorator, i + 1 < n, isIdentStart(s[i + 1]) || s[i + 1] == Self.openBracket {
                var j = i + 1
                if s[j] == Self.openBracket {
                    while j < n, s[j] != Self.closeBracket, s[j] != Self.newline { j += 1 }
                    j = min(n, j + 1)
                } else {
                    while j < n, isIdentChar(s[j]) || s[j] == Self.dot { j += 1 }
                }
                emit(i, j, .attribute)
                i = j; atLineStart = false; continue
            }
            if isDigit(c) || (c == Self.dot && i + 1 < n && isDigit(s[i + 1])) {
                var j = i + 1
                while j < n, isIdentChar(s[j]) || s[j] == Self.dot { j += 1 }
                emit(i, j, .number)
                i = j; atLineStart = false; continue
            }
            if isIdentStart(c) {
                var j = i + 1
                while j < n, isIdentChar(s[j]) { j += 1 }
                if let kind = classify(i, j, atLineStart: atLineStart) { emit(i, j, kind) }
                i = j; atLineStart = false; continue
            }
            i += 1
            atLineStart = false
        }
        return tokens
    }

    private func classify(_ start: Int, _ end: Int, atLineStart: Bool) -> TokenKind? {
        let word = String(utf16CodeUnits: Array(s[start..<end]), count: end - start)
        let lookup = language.caseInsensitiveKeywords ? word.lowercased() : word
        if language.keywords.contains(lookup) { return .keyword }
        if language.constants.contains(lookup) { return .constant }
        if language.builtinTypes.contains(word) { return .type }
        if atLineStart, isKey(after: end) { return .key }
        if language.capitalizedIsType, let first = word.unicodeScalars.first,
           CharacterSet.uppercaseLetters.contains(first) { return .type }
        if language.highlightCalls, nextNonSpace(from: end) == Self.openParen { return .function }
        return nil
    }

    private func isKey(after end: Int) -> Bool {
        guard let keySeparator else { return false }
        return nextNonSpace(from: end) == keySeparator
    }

    /// Returns the index just past the closing quote, or nil if this quote should not start a string.
    private func scanString(at start: Int) -> Int? {
        let n = s.count
        let q = s[start]
        if language.strictCharLiterals, q == Self.quote {
            let isChar = (start + 2 < n && s[start + 2] == Self.quote) || (start + 1 < n && s[start + 1] == Self.backslash)
            if !isChar { return nil }
        }
        if language.tripleQuotes, start + 2 < n, s[start + 1] == q, s[start + 2] == q {
            let close = [q, q, q]
            return find(close, from: start + 3).map { $0 + 3 } ?? n
        }
        var j = start + 1
        while j < n {
            let c = s[j]
            if c == Self.backslash { j += 2; continue }
            if c == q { return j + 1 }
            if c == Self.newline, !multiline.contains(q) { return j }
            j += 1
        }
        return n
    }

    private func matches(_ pattern: [UInt16], at index: Int) -> Bool {
        guard index + pattern.count <= s.count else { return false }
        for k in 0..<pattern.count where s[index + k] != pattern[k] { return false }
        return true
    }

    private func find(_ pattern: [UInt16], from index: Int) -> Int? {
        guard !pattern.isEmpty else { return nil }
        var i = index
        while i + pattern.count <= s.count {
            if s[i] == pattern[0], matches(pattern, at: i) { return i }
            i += 1
        }
        return nil
    }

    private func lineEnd(from index: Int) -> Int {
        var i = index
        while i < s.count, s[i] != Self.newline { i += 1 }
        return i
    }

    private func nextNonSpace(from index: Int) -> UInt16? {
        var i = index
        while i < s.count, s[i] == Self.space || s[i] == Self.tab { i += 1 }
        return i < s.count ? s[i] : nil
    }

    private func isSpace(_ c: UInt16) -> Bool { c == Self.space || c == Self.tab || c == Self.newline }
    private func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }
    private func isIdentStart(_ c: UInt16) -> Bool {
        (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c >= 128
            || (extras.contains(c) && c != Self.dash && c != Self.dot && c != 47)
    }
    private func isIdentChar(_ c: UInt16) -> Bool { isIdentStart(c) || isDigit(c) || extras.contains(c) }
}
