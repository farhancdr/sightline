import AppKit

/// NSTextView with code-aware word selection. AppKit's default treats "." between letters as part of a
/// word (for abbreviations/URLs), so double-clicking `getBatch` in `this.repo.getBatch(` selected the
/// whole chain. Here a word is an identifier: letters, digits, `_` and `$`.
final class CodeTextView: NSTextView {
    /// ⌘-click on an identifier.
    var onCommandClick: ((String) -> Void)?

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
