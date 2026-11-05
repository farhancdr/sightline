import AppKit

/// NSTextView with code-aware word selection. AppKit's default treats "." between letters as part of a
/// word (for abbreviations/URLs), so double-clicking `getBatch` in `this.repo.getBatch(` selected the
/// whole chain. Here a word is an identifier: letters, digits, `_` and `$`.
final class CodeTextView: NSTextView {
    /// ⌘-click on an identifier.
    var onCommandClick: ((String) -> Void)?
    /// Line comment token for ⌘/ ("//", "#", "--"), nil when the language has none.
    var lineCommentToken: String?
    /// Vim mode (nil when off).
    var vim: VimEngine? { didSet { needsDisplay = true } }

    // MARK: Vim key routing

    /// Control keys (⌃r, ⌃d, ⌃o…) reach Vim before the app's menu shortcuts.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let vim, window?.firstResponder === self, event.modifierFlags.contains(.control),
           !event.modifierFlags.contains(.command), vim.mode != .insert,
           event.keyCode != 48, // ⌃Tab / ⌃⇧Tab switch editor tabs (menu)
           let key = VimKey.from(event, mode: vim.mode), vim.handle(key) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Normal mode draws a block cursor over the character.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        guard vim?.usesBlockCursor == true else { return super.drawInsertionPoint(in: rect, color: color, turnedOn: flag) }
        var block = rect
        block.size.width = blockCursorWidth
        if flag {
            color.withAlphaComponent(0.45).setFill()
            block.fill()
        } else {
            setNeedsDisplay(block, avoidAdditionalLayout: true)
        }
    }

    override func setNeedsDisplay(_ invalidRect: NSRect, avoidAdditionalLayout flag: Bool) {
        var rect = invalidRect
        if vim?.usesBlockCursor == true { rect.size.width += blockCursorWidth }
        super.setNeedsDisplay(rect, avoidAdditionalLayout: flag)
    }

    private var blockCursorWidth: CGFloat {
        ("m" as NSString).size(withAttributes: [.font: font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]).width
    }

    override func mouseDown(with event: NSEvent) {
        let modifiers = event.modifierFlags
        let isCommandClick = modifiers.contains(.command) && modifiers.isDisjoint(with: [.shift, .option, .control])
        if isCommandClick, event.clickCount == 1, let onCommandClick {
            let point = convert(event.locationInWindow, from: nil)
            let index = characterIndexForInsertion(at: point)
            let text = string as NSString
            // Insertion points sit between characters: try the character at and just before the click.
            if let range = Self.identifierRange(in: text, at: index) ?? Self.identifierRange(in: text, at: index - 1) {
                setSelectedRange(range)
                onCommandClick(text.substring(with: range))
                return
            }
        }
        super.mouseDown(with: event)
    }

    private static let identifier: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "_$")
        return set
    }()

    static func isIdentifier(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false } // surrogate halves
        return identifier.contains(scalar)
    }

    /// Identifier range containing `index`, or nil when the character there isn't part of one.
    static func identifierRange(in text: NSString, at index: Int) -> NSRange? {
        guard index >= 0, index < text.length, isIdentifier(text.character(at: index)) else { return nil }
        var start = index
        var end = index + 1
        while start > 0, isIdentifier(text.character(at: start - 1)) { start -= 1 }
        while end < text.length, isIdentifier(text.character(at: end)) { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    override func selectionRange(forProposedRange proposedCharRange: NSRange, granularity: NSSelectionGranularity) -> NSRange {
        guard granularity == .selectByWord else {
            return super.selectionRange(forProposedRange: proposedCharRange, granularity: granularity)
        }
        let text = string as NSString
        let startWord = Self.identifierRange(in: text, at: proposedCharRange.location)
        // Double-click: zero-length proposal; double-click-drag: extend both ends to identifier bounds.
        let lastIndex = max(proposedCharRange.location, NSMaxRange(proposedCharRange) - 1)
        let endWord = proposedCharRange.length > 0 ? Self.identifierRange(in: text, at: lastIndex) : startWord
        guard startWord != nil || endWord != nil else {
            return super.selectionRange(forProposedRange: proposedCharRange, granularity: granularity)
        }
        let start = startWord?.location ?? proposedCharRange.location
        let end = endWord.map(NSMaxRange) ?? max(NSMaxRange(proposedCharRange), start)
        return NSRange(location: start, length: end - start)
    }
}
