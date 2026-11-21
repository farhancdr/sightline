import AppKit

/// One caret or selection of a multi-cursor edit. `anchor` stays put while `head` moves (⇧-extend).
struct TextCursor: Equatable {
    var anchor: Int
    var head: Int

    init(_ anchor: Int, _ head: Int) {
        self.anchor = anchor
        self.head = head
    }

    init(caret: Int) { self.init(caret, caret) }
    init(range: NSRange) { self.init(range.location, NSMaxRange(range)) }

    var range: NSRange { NSRange(location: min(anchor, head), length: abs(head - anchor)) }
    var isEmpty: Bool { anchor == head }

    /// Sorted, with overlapping cursors (and carets touching a selection) merged, like VS Code.
    /// Returns the index of the cursor that now holds `primary`.
    static func normalized(_ list: [TextCursor], primary: TextCursor?) -> (cursors: [TextCursor], primary: Int) {
        let sorted = list.sorted { ($0.range.location, $0.range.length) < ($1.range.location, $1.range.length) }
        var out: [TextCursor] = []
        for cursor in sorted {
            guard let last = out.last else { out.append(cursor); continue }
            let lr = last.range, cr = cursor.range
            let merges = cr.location < NSMaxRange(lr) || cr.location == lr.location
                || (cr.location == NSMaxRange(lr) && (cr.length == 0 || lr.length == 0))
            guard merges else { out.append(cursor); continue }
            let union = NSUnionRange(lr, cr)
            out[out.count - 1] = last.head < last.anchor
                ? TextCursor(NSMaxRange(union), union.location)
                : TextCursor(union.location, NSMaxRange(union))
        }
        guard let primary else { return (out, max(0, out.count - 1)) }
        let p = primary.range
        let index = out.firstIndex { $0.range == p }
            ?? out.firstIndex { NSIntersectionRange($0.range, p).length > 0 || NSLocationInRange(p.location, $0.range) || $0.range.location == p.location }
            ?? out.count - 1
        return (out, max(0, index))
    }
}

/// VS Code-style multiple cursors for the editor: ⌘D (add next occurrence), ⇧⌘L (all occurrences),
/// ⌥-click (add/remove a caret), ⌥-drag (column selection), ⌥⌘↑/↓ (add caret above/below), Esc (back to one).
///
/// `cursors` is empty while there's a single, native selection. With two or more, the native selection mirrors
/// the primary cursor (for scrolling, find, blame) and this extension draws the others. Every edit goes through
/// `shouldChangeText(inRanges:)` as one undo step; anything else that moves the selection or changes the text
/// (a click, undo, find, line commands, a reload from disk) collapses back to a single cursor.
extension CodeTextView {
    struct CursorEdit {
        var range: NSRange
        var text: String
        /// The resulting cursor, relative to `range.location` in the new text.
        var cursor: TextCursor
    }

    var isMultiCursor: Bool { cursors.count > 1 }

    private var ns: NSString { string as NSString }

    /// The cursors, or the native selection as one cursor.
    var allCursors: [TextCursor] { isMultiCursor ? cursors : [TextCursor(range: selectedRange())] }

    func setCursors(_ list: [TextCursor], primary: TextCursor? = nil) {
        let length = ns.length
        let clamped = list.map { TextCursor(min(max(0, $0.anchor), length), min(max(0, $0.head), length)) }
        let (merged, primaryIndex) = TextCursor.normalized(clamped, primary: primary ?? clamped.last)
        applyingCursors = true
        defer { applyingCursors = false }
        let main = merged.isEmpty ? TextCursor(caret: 0) : merged[primaryIndex]
        if merged.count > 1 {
            cursors = merged
            primaryCursor = primaryIndex
        } else {
            cursors = []
            primaryCursor = 0
        }
        setSelectedRange(main.range)
        scrollRangeToVisible(main.range)
        needsDisplay = true
    }

    func collapseCursors() {
        guard isMultiCursor else { return }
        setCursors([cursors[min(primaryCursor, cursors.count - 1)]])
    }

    // MARK: Adding cursors

    /// ⌘D: select the word at the caret, then add the next occurrence of the selection as another cursor.
    @objc func addNextOccurrence(_ sender: Any?) {
        guard vim == nil else { return }
        var list = allCursors
        let primaryIndex = isMultiCursor ? min(primaryCursor, list.count - 1) : 0
        // Empty carets: first select the word under each (VS Code), matching whole words from then on.
        if list[primaryIndex].isEmpty {
            list = list.map { cursor in
                guard cursor.isEmpty, let word = wordRange(at: cursor.head) else { return cursor }
                return TextCursor(range: word)
            }
            occurrenceWholeWord = true
            let primary = list[primaryIndex]
            setCursors(list, primary: primary)
            occurrenceWholeWord = true // setCursors' selection change resets it
            return
        }
        let primary = list[primaryIndex]
        let needle = ns.substring(with: primary.range)
        let taken = Set(list.map(\.range.location))
        var from = NSMaxRange(primary.range)
        var wrapped = false
        while true {
            let window = wrapped ? NSRange(location: from, length: max(0, primary.range.location - from))
                                 : NSRange(location: from, length: ns.length - from)
            let found = ns.range(of: needle, options: .literal, range: window)
            guard found.location != NSNotFound else {
                if wrapped { return }
                wrapped = true
                from = 0
                continue
            }
            if !taken.contains(found.location), !occurrenceWholeWord || isWholeWord(found) {
                let added = TextCursor(range: found)
                let whole = occurrenceWholeWord
                setCursors(list + [added], primary: added)
                occurrenceWholeWord = whole
                return
            }
            from = NSMaxRange(found)
        }
    }

    /// ⇧⌘L: a cursor on every occurrence of the selection (or of the word at the caret).
    @objc func selectAllOccurrences(_ sender: Any?) {
        guard vim == nil else { return }
        let current = allCursors[isMultiCursor ? min(primaryCursor, cursors.count - 1) : 0]
        var wholeWord = occurrenceWholeWord
        var target = current.range
        if target.length == 0 {
            guard let word = wordRange(at: current.head) else { return }
            target = word
            wholeWord = true
        }
        let matches = Self.occurrences(of: ns.substring(with: target), in: ns, wholeWord: wholeWord)
        guard !matches.isEmpty else { return }
        setCursors(matches.map(TextCursor.init(range:)), primary: TextCursor(range: target))
        occurrenceWholeWord = wholeWord
    }

    /// ⌥⌘↑ / ⌥⌘↓: a caret on the line above the topmost / below the bottommost cursor, same column.
    @objc func addCursorAbove(_ sender: Any?) { addCursorVertically(up: true) }
    @objc func addCursorBelow(_ sender: Any?) { addCursorVertically(up: false) }

    private func addCursorVertically(up: Bool) {
        guard vim == nil else { return }
        let list = allCursors
        guard let edge = up ? list.min(by: { $0.head < $1.head }) : list.max(by: { $0.head < $1.head }) else { return }
        let target = verticalMove(from: edge.head, up: up)
        guard lineStart(target) != lineStart(edge.head) else { return } // already on the first/last line
        let added = TextCursor(caret: target)
        setCursors(list + [added], primary: added)
    }

    /// ⌥-click adds a caret (or removes one that's already there); ⌥-drag is AppKit's column selection,
    /// turned into one cursor per line. Returns false when the event isn't an ⌥-click.
    func handleOptionClick(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        guard vim == nil, isEditable, flags == .option, event.clickCount == 1 else { return false }
        let before = allCursors
        super.mouseDown(with: event) // tracks until mouse-up (column selection while dragging)
        let ranges = selectedRanges.map(\.rangeValue)
        if ranges.count > 1 {
            setCursors(ranges.map(TextCursor.init(range:)))
            return true
        }
        let click = ranges.first ?? NSRange(location: 0, length: 0)
        if click.length == 0, before.count > 1,
           let existing = before.firstIndex(where: { $0.isEmpty && $0.head == click.location }) {
            var remaining = before
            remaining.remove(at: existing)
            setCursors(remaining)
        } else {
            let added = TextCursor(range: click)
            setCursors(before + [added], primary: added)
        }
        return true
    }

    // MARK: Editing at every cursor

    /// Applies one edit per cursor as a single undoable change, then places the resulting cursors.
    func applyCursorEdits(_ edits: [CursorEdit]) {
        guard isEditable, let storage = textStorage else { return }
        var kept: [CursorEdit] = []
        for edit in edits.sorted(by: { $0.range.location < $1.range.location }) {
            if let last = kept.last, edit.range.location < NSMaxRange(last.range) { continue }
            kept.append(edit)
        }
        guard !kept.isEmpty,
              shouldChangeText(inRanges: kept.map { NSValue(range: $0.range) }, replacementStrings: kept.map(\.text))
        else { return }
        let primaryIndex = min(primaryCursor, kept.count - 1)
        applyingCursors = true
        storage.beginEditing()
        for edit in kept.reversed() { storage.replaceCharacters(in: edit.range, with: edit.text) }
        storage.endEditing()
        didChangeText()
        applyingCursors = false
        var delta = 0
        var result: [TextCursor] = []
        for edit in kept {
            let base = edit.range.location + delta
            result.append(TextCursor(base + edit.cursor.anchor, base + edit.cursor.head))
            delta += (edit.text as NSString).length - edit.range.length
        }
        setCursors(result, primary: result[primaryIndex])
    }

    func typeAtCursors(_ text: String) {
        let length = (text as NSString).length
        applyCursorEdits(cursors.map { CursorEdit(range: $0.range, text: text, cursor: TextCursor(caret: length)) })
    }

    /// Deletes each selection, or (for carets) the range `extent` returns for the caret position.
    private func deleteAtCursors(_ extent: (Int) -> NSRange) {
        applyCursorEdits(cursors.map { cursor in
            let range = cursor.isEmpty ? extent(cursor.head) : cursor.range
            return CursorEdit(range: range, text: "", cursor: TextCursor(caret: 0))
        })
    }

    private func moveCursors(extend: Bool, collapseTo: ((NSRange) -> Int)? = nil, _ target: (Int) -> Int) {
        let moved = cursors.map { cursor in
            if extend { return TextCursor(cursor.anchor, target(cursor.head)) }
            if let collapseTo, !cursor.isEmpty { return TextCursor(caret: collapseTo(cursor.range)) }
            return TextCursor(caret: target(cursor.head))
        }
        setCursors(moved, primary: moved[min(primaryCursor, moved.count - 1)])
    }

    /// Key-binding commands while several cursors are active. Unknown commands collapse to the primary cursor
    /// and fall through to AppKit (returns false).
    func handleMultiCursorCommand(_ selector: Selector) -> Bool {
        guard cursors.allSatisfy({ NSMaxRange($0.range) <= ns.length }) else {
            cursors = []
            return false
        }
        switch selector {
        case #selector(insertNewline(_:)), #selector(insertNewlineIgnoringFieldEditor(_:)):
            applyCursorEdits(cursors.map { cursor in
                let text = "\n" + leadingIndent(before: cursor.range.location)
                return CursorEdit(range: cursor.range, text: text, cursor: TextCursor(caret: (text as NSString).length))
            })
        case #selector(insertTab(_:)):
            typeAtCursors(indentUnit())
        case #selector(insertBacktab(_:)):
            break
        case #selector(deleteBackward(_:)), #selector(deleteBackwardByDecomposingPreviousCharacter(_:)):
            deleteAtCursors { $0 > 0 ? self.ns.rangeOfComposedCharacterSequence(at: $0 - 1) : NSRange(location: 0, length: 0) }
        case #selector(deleteForward(_:)):
            deleteAtCursors { $0 < self.ns.length ? self.ns.rangeOfComposedCharacterSequence(at: $0) : NSRange(location: $0, length: 0) }
        case #selector(deleteWordBackward(_:)):
            deleteAtCursors { NSRange(location: self.wordLeft(from: $0), length: $0 - self.wordLeft(from: $0)) }
        case #selector(deleteWordForward(_:)):
            deleteAtCursors { NSRange(location: $0, length: self.wordRight(from: $0) - $0) }
        case #selector(deleteToBeginningOfLine(_:)):
            deleteAtCursors { caret in
                let start = self.lineStart(caret)
                return start == caret ? (caret > 0 ? NSRange(location: caret - 1, length: 1) : NSRange(location: 0, length: 0))
                                      : NSRange(location: start, length: caret - start)
            }
        case #selector(deleteToEndOfLine(_:)):
            deleteAtCursors { NSRange(location: $0, length: self.lineContentsEnd($0) - $0) }

        case #selector(moveLeft(_:)), #selector(moveBackward(_:)):
            moveCursors(extend: false, collapseTo: { $0.location }) { self.characterLeft(from: $0) }
        case #selector(moveRight(_:)), #selector(moveForward(_:)):
            moveCursors(extend: false, collapseTo: { NSMaxRange($0) }) { self.characterRight(from: $0) }
        case #selector(moveLeftAndModifySelection(_:)), #selector(moveBackwardAndModifySelection(_:)):
            moveCursors(extend: true) { self.characterLeft(from: $0) }
        case #selector(moveRightAndModifySelection(_:)), #selector(moveForwardAndModifySelection(_:)):
            moveCursors(extend: true) { self.characterRight(from: $0) }
        case #selector(moveUp(_:)):
            moveCursors(extend: false) { self.verticalMove(from: $0, up: true) }
        case #selector(moveDown(_:)):
            moveCursors(extend: false) { self.verticalMove(from: $0, up: false) }
        case #selector(moveUpAndModifySelection(_:)):
            moveCursors(extend: true) { self.verticalMove(from: $0, up: true) }
        case #selector(moveDownAndModifySelection(_:)):
            moveCursors(extend: true) { self.verticalMove(from: $0, up: false) }
        case #selector(moveWordLeft(_:)), #selector(moveWordBackward(_:)):
            moveCursors(extend: false) { self.wordLeft(from: $0) }
        case #selector(moveWordRight(_:)), #selector(moveWordForward(_:)):
            moveCursors(extend: false) { self.wordRight(from: $0) }
        case #selector(moveWordLeftAndModifySelection(_:)), #selector(moveWordBackwardAndModifySelection(_:)):
            moveCursors(extend: true) { self.wordLeft(from: $0) }
        case #selector(moveWordRightAndModifySelection(_:)), #selector(moveWordForwardAndModifySelection(_:)):
            moveCursors(extend: true) { self.wordRight(from: $0) }
        case #selector(moveToBeginningOfLine(_:)), #selector(moveToLeftEndOfLine(_:)):
            moveCursors(extend: false) { self.smartLineStart($0) }
        case #selector(moveToEndOfLine(_:)), #selector(moveToRightEndOfLine(_:)):
            moveCursors(extend: false) { self.lineContentsEnd($0) }
        case #selector(moveToBeginningOfLineAndModifySelection(_:)), #selector(moveToLeftEndOfLineAndModifySelection(_:)):
            moveCursors(extend: true) { self.smartLineStart($0) }
        case #selector(moveToEndOfLineAndModifySelection(_:)), #selector(moveToRightEndOfLineAndModifySelection(_:)):
            moveCursors(extend: true) { self.lineContentsEnd($0) }

        case #selector(cancelOperation(_:)):
            collapseCursors()
        default:
            collapseCursors()
            return false
        }
        return true
    }

    // MARK: Clipboard

    /// Copy joins the selections with newlines (carets copy their whole line, like VS Code).
    func copyCursorText() -> String {
        cursors.map { cursor in
            cursor.isEmpty ? ns.substring(with: ns.lineRange(for: NSRange(location: cursor.head, length: 0)))
                           : ns.substring(with: cursor.range)
        }
        .map { $0.hasSuffix("\n") ? String($0.dropLast()) : $0 }
        .joined(separator: "\n")
    }

    /// Pasting as many lines as there are cursors puts one line at each; otherwise the whole text at each.
    func pasteAtCursors(_ text: String) {
        var lines = text.components(separatedBy: "\n")
        if lines.count == cursors.count + 1, lines.last == "" { lines.removeLast() }
        guard lines.count == cursors.count else { return typeAtCursors(text) }
        applyCursorEdits(zip(cursors, lines).map { cursor, line in
            CursorEdit(range: cursor.range, text: line, cursor: TextCursor(caret: (line as NSString).length))
        })
    }

    // MARK: Drawing

    func drawCursorSelections(in rect: NSRect) {
        guard isMultiCursor, let layoutManager, let textContainer else { return }
        let color = (selectedTextAttributes[.backgroundColor] as? NSColor) ?? .selectedTextBackgroundColor
        color.setFill()
        let origin = textContainerOrigin
        for (index, cursor) in cursors.enumerated() where index != primaryCursor && !cursor.isEmpty
            && NSMaxRange(cursor.range) <= ns.length {
            let glyphs = layoutManager.glyphRange(forCharacterRange: cursor.range, actualCharacterRange: nil)
            layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs,
                                                  withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                                  in: textContainer) { box, _ in
                let box = box.offsetBy(dx: origin.x, dy: origin.y)
                if box.intersects(rect) { box.fill() }
            }
        }
    }

    func drawCursorCarets(in rect: NSRect) {
        guard isMultiCursor else { return }
        insertionPointColor.setFill()
        for cursor in cursors where cursor.head <= ns.length {
            let caret = caretRect(at: cursor.head)
            if caret.intersects(rect) { caret.fill() }
        }
    }

    func caretRect(at index: Int) -> NSRect {
        guard let layoutManager, let textContainer else { return .zero }
        let length = ns.length
        let origin = textContainerOrigin
        var rect: NSRect
        if index >= length, length == 0 || ns.character(at: length - 1) == 10 {
            rect = layoutManager.extraLineFragmentRect
            if rect.isEmpty, length > 0 { // no extra fragment yet: just below the last line
                let last = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: length - 1), effectiveRange: nil)
                rect = NSRect(x: 0, y: last.maxY, width: 0, height: last.height)
            }
            rect.origin.x = textContainer.lineFragmentPadding
        } else {
            let glyph = layoutManager.glyphIndexForCharacter(at: min(index, length - 1))
            let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            var x = line.minX + layoutManager.location(forGlyphAt: glyph).x
            if index >= length {
                x = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).maxX
            }
            rect = NSRect(x: x, y: line.minY, width: 0, height: line.height)
        }
        return NSRect(x: rect.minX + origin.x, y: rect.minY + origin.y, width: 1.5, height: rect.height)
    }

    // MARK: Text geometry

    private func lineStart(_ index: Int) -> Int {
        ns.lineRange(for: NSRange(location: min(index, ns.length), length: 0)).location
    }

    private func lineContentsEnd(_ index: Int) -> Int {
        var contentsEnd = 0
        ns.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: min(index, ns.length), length: 0))
        return contentsEnd
    }

    /// First non-blank character of the line; from there (or inside the indentation), the line start.
    private func smartLineStart(_ index: Int) -> Int {
        let start = lineStart(index)
        let end = lineContentsEnd(index)
        var firstText = start
        while firstText < end, [32, 9].contains(ns.character(at: firstText)) { firstText += 1 }
        return index == firstText ? start : firstText
    }

    private func leadingIndent(before index: Int) -> String {
        let start = lineStart(index)
        var end = start
        while end < index, [32, 9].contains(ns.character(at: end)) { end += 1 }
        return ns.substring(with: NSRange(location: start, length: end - start))
    }

    private func characterLeft(from index: Int) -> Int {
        index > 0 ? ns.rangeOfComposedCharacterSequence(at: index - 1).location : 0
    }

    private func characterRight(from index: Int) -> Int {
        index < ns.length ? NSMaxRange(ns.rangeOfComposedCharacterSequence(at: index)) : ns.length
    }

    /// Same column on the previous/next line (clamped to its length); past the first/last line: document edge.
    func verticalMove(from index: Int, up: Bool) -> Int {
        let start = lineStart(index)
        let column = index - start
        if up {
            guard start > 0 else { return 0 }
            let previousStart = lineStart(start - 1)
            return min(previousStart + column, lineContentsEnd(previousStart))
        }
        let end = NSMaxRange(ns.lineRange(for: NSRange(location: min(index, ns.length), length: 0)))
        let contentsEnd = lineContentsEnd(index)
        guard end > contentsEnd else { return ns.length } // last line (no newline after it)
        return min(end + column, lineContentsEnd(end))
    }

    private func wordRight(from index: Int) -> Int {
        var i = index
        while i < ns.length, !Self.isIdentifier(ns.character(at: i)) {
            if ns.character(at: i) == 10, i > index { return i }
            i += 1
        }
        while i < ns.length, Self.isIdentifier(ns.character(at: i)) { i += 1 }
        return i
    }

    private func wordLeft(from index: Int) -> Int {
        var i = index
        while i > 0, !Self.isIdentifier(ns.character(at: i - 1)) {
            if ns.character(at: i - 1) == 10, i < index { return i }
            i -= 1
        }
        while i > 0, Self.isIdentifier(ns.character(at: i - 1)) { i -= 1 }
        return i
    }

    private func wordRange(at index: Int) -> NSRange? {
        Self.identifierRange(in: ns, at: index) ?? Self.identifierRange(in: ns, at: index - 1)
    }

    private func isWholeWord(_ range: NSRange) -> Bool {
        Self.isWholeWord(range, in: ns)
    }

    static func isWholeWord(_ range: NSRange, in text: NSString) -> Bool {
        let before = range.location == 0 || !isIdentifier(text.character(at: range.location - 1))
        let after = NSMaxRange(range) >= text.length || !isIdentifier(text.character(at: NSMaxRange(range)))
        return before && after
    }

    /// Every non-overlapping, case-sensitive occurrence of `needle`.
    static func occurrences(of needle: String, in text: NSString, wholeWord: Bool) -> [NSRange] {
        guard !needle.isEmpty else { return [] }
        var result: [NSRange] = []
        var from = 0
        while from < text.length {
            let found = text.range(of: needle, options: .literal, range: NSRange(location: from, length: text.length - from))
            guard found.location != NSNotFound else { break }
            if !wholeWord || isWholeWord(found, in: text) { result.append(found) }
            from = NSMaxRange(found)
        }
        return result
    }
}
