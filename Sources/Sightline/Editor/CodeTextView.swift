import AppKit

/// NSTextView with code-aware word selection. AppKit's default treats "." between letters as part of a
/// word (for abbreviations/URLs), so double-clicking `getBatch` in `this.repo.getBatch(` selected the
/// whole chain. Here a word is an identifier: letters, digits, `_` and `$`.
final class CodeTextView: NSTextView {
    /// ⌘-click on an identifier.
    var onCommandClick: ((String) -> Void)?
    /// Line comment token for ⌘/ ("//", "#", "--"), nil when the language has none.
    var lineCommentToken: String?
    /// Vim mode (nil when off). Multiple cursors are off while it's on.
    var vim: VimEngine? { didSet { cursors = []; needsDisplay = true } }

    // MARK: Multiple cursors (CodeTextView+MultiCursor.swift)

    /// Two or more cursors, sorted; empty while there's a single, native selection.
    var cursors: [TextCursor] = []
    var primaryCursor = 0
    /// Set while the cursor code itself changes the selection/text, so that isn't taken as "collapse".
    var applyingCursors = false
    /// ⌘D started from a caret matches whole words only (VS Code).
    var occurrenceWholeWord = false
    /// Injectable so tests don't touch the user's clipboard.
    var cursorPasteboard: NSPasteboard = .general

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        if !applyingCursors {
            occurrenceWholeWord = false
            if !cursors.isEmpty {
                cursors = []
                needsDisplay = true
            }
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
    }

    override func didChangeText() {
        // Text changed by something other than a multi-cursor edit (undo, reload): positions are stale.
        if !applyingCursors, !cursors.isEmpty {
            cursors = []
            needsDisplay = true
        }
        super.didChangeText()
    }

    override func doCommand(by selector: Selector) {
        if isMultiCursor, handleMultiCursorCommand(selector) { return }
        super.doCommand(by: selector)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if isMultiCursor, !hasMarkedText(), replacementRange.location == NSNotFound {
            let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
            return typeAtCursors(text)
        }
        collapseCursors()
        super.insertText(string, replacementRange: replacementRange)
    }

    override func copy(_ sender: Any?) {
        guard isMultiCursor else { return super.copy(sender) }
        cursorPasteboard.clearContents()
        cursorPasteboard.setString(copyCursorText(), forType: .string)
    }

    override func cut(_ sender: Any?) {
        guard isMultiCursor else { return super.cut(sender) }
        copy(sender)
        applyCursorEdits(cursors.map { cursor in
            let range = cursor.isEmpty ? (string as NSString).lineRange(for: NSRange(location: cursor.head, length: 0)) : cursor.range
            return CursorEdit(range: range, text: "", cursor: TextCursor(caret: 0))
        })
    }

    override func paste(_ sender: Any?) {
        guard isMultiCursor, let text = cursorPasteboard.string(forType: .string) else { return super.paste(sender) }
        pasteAtCursors(text)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawCursorSelections(in: rect)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawCursorCarets(in: dirtyRect)
    }

    // MARK: Vim key routing

    /// Control keys (⌃r, ⌃d, ⌃o…) reach Vim before the app's menu shortcuts.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let vim, window?.firstResponder === self, event.modifierFlags.contains(.control),
           !event.modifierFlags.contains(.command), vim.mode != .insert,
           event.keyCode != 48, // ⌃Tab / ⌃⇧Tab switch editor tabs (menu)
           let key = VimKey.from(event, mode: vim.mode), vim.handle(key) {
            return true
        }
        // ⇧⌘L selects all occurrences while the editor has focus (elsewhere it's Repository → Pull).
        if vim == nil, window?.firstResponder === self,
           event.modifierFlags.intersection([.command, .shift, .option, .control]) == [.command, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "l" {
            selectAllOccurrences(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Normal mode draws a block cursor over the character.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        if isMultiCursor { return } // every caret is drawn by drawCursorCarets (no blinking)
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
        if handleOptionClick(event) { return }
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
