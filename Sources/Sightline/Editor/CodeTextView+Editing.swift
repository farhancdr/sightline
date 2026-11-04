import AppKit

/// VS Code-style line editing for the editor: toggle comment (⌘/), move lines (⌥↑/⌥↓), copy lines (⇧⌥↑/⇧⌥↓),
/// delete lines (⇧⌘K), indent/outdent (⌘] / ⌘[, Tab / ⇧Tab on multi-line selections), select line (⌘L).
/// Every edit goes through `shouldChangeText` / `didChangeText`, so it's undoable and re-highlights.
/// Menu items reach these via the responder chain, so they only act when the editor has focus.
extension CodeTextView {
    private var text: NSString { string as NSString }

    /// Full lines touched by the selection. A selection ending right at the start of a line doesn't
    /// include that line (like VS Code).
    func selectedLineBlock() -> NSRange {
        var selection = selectedRange()
        if selection.length > 0, text.character(at: NSMaxRange(selection) - 1) == 10 { selection.length -= 1 }
        return text.lineRange(for: selection)
    }

    @discardableResult
    func replace(_ range: NSRange, with replacement: String, select: NSRange) -> Bool {
        guard isEditable, shouldChangeText(in: range, replacementString: replacement) else { return false }
        textStorage?.replaceCharacters(in: range, with: replacement)
        didChangeText()
        setSelectedRange(select)
        scrollRangeToVisible(select)
        return true
    }

    // MARK: Keys without ⌘ (handled here so the terminal keeps ⌥↑ etc.)

    override func keyDown(with event: NSEvent) {
        if let vim, let key = VimKey.from(event, mode: vim.mode), vim.handle(key) { return }
        let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        if isEditable, flags.contains(.option), !flags.contains(.command), !flags.contains(.control) {
            let shift = flags.contains(.shift)
            switch event.keyCode {
            case 126: shift ? copyLinesUp(nil) : moveLinesUp(nil); return   // ↑
            case 125: shift ? copyLinesDown(nil) : moveLinesDown(nil); return // ↓
            default: break
            }
        }
        super.keyDown(with: event)
    }

    override func insertTab(_ sender: Any?) {
        if isEditable, text.substring(with: selectedRange()).contains("\n") { indentLines(sender) } else { super.insertTab(sender) }
    }

    override func insertBacktab(_ sender: Any?) {
        if isEditable { outdentLines(sender) } else { super.insertBacktab(sender) }
    }

    // MARK: Commands

    @objc func moveLinesUp(_ sender: Any?) {
        let block = selectedLineBlock()
        guard isEditable, block.location > 0 else { return }
        let previous = text.lineRange(for: NSRange(location: block.location - 1, length: 0))
        var blockText = text.substring(with: block)
        var previousText = text.substring(with: previous)
        if !blockText.hasSuffix("\n") { // the block is the last line, without a newline
            blockText += "\n"
            previousText.removeLast()
        }
        let selection = selectedRange()
        replace(NSRange(location: previous.location, length: NSMaxRange(block) - previous.location),
                with: blockText + previousText,
                select: NSRange(location: selection.location - previous.length, length: selection.length))
    }

    @objc func moveLinesDown(_ sender: Any?) {
        let block = selectedLineBlock()
        guard isEditable, NSMaxRange(block) < text.length else { return }
        let next = text.lineRange(for: NSRange(location: NSMaxRange(block), length: 0))
        var blockText = text.substring(with: block)
        var nextText = text.substring(with: next)
        if !nextText.hasSuffix("\n") { // moving below the last line
            nextText += "\n"
            blockText.removeLast()
        }
        let selection = selectedRange()
        replace(NSRange(location: block.location, length: NSMaxRange(next) - block.location),
                with: nextText + blockText,
                select: NSRange(location: selection.location + (nextText as NSString).length, length: selection.length))
    }

    @objc func copyLinesUp(_ sender: Any?) {
        let block = selectedLineBlock()
        guard isEditable else { return }
        var blockText = text.substring(with: block)
        if !blockText.hasSuffix("\n") { blockText += "\n" }
        // Insert above; the caret stays on the upper (new) copy, like VS Code.
        replace(NSRange(location: block.location, length: 0), with: blockText, select: selectedRange())
    }

    @objc func copyLinesDown(_ sender: Any?) {
        let block = selectedLineBlock()
        guard isEditable else { return }
        let blockText = text.substring(with: block)
        let selection = selectedRange()
        if blockText.hasSuffix("\n") {
            replace(NSRange(location: NSMaxRange(block), length: 0), with: blockText,
                    select: NSRange(location: selection.location + block.length, length: selection.length))
        } else {
            replace(NSRange(location: NSMaxRange(block), length: 0), with: "\n" + blockText,
                    select: NSRange(location: selection.location + block.length + 1, length: selection.length))
        }
    }

    @objc func deleteLines(_ sender: Any?) {
        var block = selectedLineBlock()
        guard isEditable else { return }
        // Last line without a newline: take the newline before it instead.
        if NSMaxRange(block) == text.length, block.location > 0, !text.substring(with: block).hasSuffix("\n") {
            block = NSRange(location: block.location - 1, length: block.length + 1)
        }
        replace(block, with: "", select: NSRange(location: min(block.location, text.length - block.length), length: 0))
    }

    @objc func selectLineExtending(_ sender: Any?) {
        let selection = selectedRange()
        let block = text.lineRange(for: selection)
        // Already whole lines selected: extend by the next line.
        if selection.length > 0, selection == block, NSMaxRange(block) < text.length {
            let next = text.lineRange(for: NSRange(location: NSMaxRange(block), length: 0))
            setSelectedRange(NSRange(location: block.location, length: NSMaxRange(next) - block.location))
        } else {
            setSelectedRange(block)
        }
        scrollRangeToVisible(selectedRange())
    }

    @objc func toggleLineComment(_ sender: Any?) {
        guard isEditable, let token = lineCommentToken else { NSSound.beep(); return }
        let block = selectedLineBlock()
        let original = text.substring(with: block)
        guard let result = Self.toggledComment(original, token: token) else { return }
        replace(block, with: result, select: NSRange(location: block.location,
                                                     length: (result as NSString).length - (result.hasSuffix("\n") ? 1 : 0)))
    }

    @objc func indentLines(_ sender: Any?) {
        guard isEditable else { return }
        let block = selectedLineBlock()
        let result = Self.indented(text.substring(with: block), unit: indentUnit())
        replace(block, with: result, select: NSRange(location: block.location,
                                                     length: (result as NSString).length - (result.hasSuffix("\n") ? 1 : 0)))
    }

    @objc func outdentLines(_ sender: Any?) {
        guard isEditable else { return }
        let block = selectedLineBlock()
        let result = Self.outdented(text.substring(with: block), unit: indentUnit())
        replace(block, with: result, select: NSRange(location: block.location,
                                                     length: (result as NSString).length - (result.hasSuffix("\n") ? 1 : 0)))
    }

    // MARK: Pure helpers (unit-tested)

    /// Comments every non-blank line at the block's smallest indentation, or uncomments if they all are.
    static func toggledComment(_ block: String, token: String) -> String? {
        let trailingNewline = block.hasSuffix("\n")
        var lines = block.components(separatedBy: "\n")
        if trailingNewline { lines.removeLast() }
        func indent(_ line: String) -> Int { line.prefix { $0 == " " || $0 == "\t" }.count }
        let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !content.isEmpty else { return nil }
        let allCommented = content.allSatisfy { $0.dropFirst(indent($0)).hasPrefix(token) }
        if allCommented {
            lines = lines.map { line in
                let lead = indent(line)
                var rest = line.dropFirst(lead)
                guard rest.hasPrefix(token) else { return line }
                rest = rest.dropFirst(token.count)
                if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                return String(line.prefix(lead)) + rest
            }
        } else {
            let column = content.map(indent).min() ?? 0
            lines = lines.map { line in
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
                return String(line.prefix(column)) + token + " " + line.dropFirst(column)
            }
        }
        return lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
    }

    static func indented(_ block: String, unit: String) -> String {
        mapLines(block) { $0.isEmpty ? $0 : unit + $0 }
    }

    static func outdented(_ block: String, unit: String) -> String {
        mapLines(block) { line in
            if line.hasPrefix("\t") { return String(line.dropFirst()) }
            let spaces = min(line.prefix { $0 == " " }.count, unit == "\t" ? 4 : unit.count)
            return String(line.dropFirst(spaces))
        }
    }

    private static func mapLines(_ block: String, _ transform: (String) -> String) -> String {
        let trailingNewline = block.hasSuffix("\n")
        var lines = block.components(separatedBy: "\n")
        if trailingNewline { lines.removeLast() }
        return lines.map(transform).joined(separator: "\n") + (trailingNewline ? "\n" : "")
    }

    /// Tabs if the file indents with tabs, else 2 or 4 spaces (smallest indentation seen).
    func indentUnit() -> String { Self.detectIndentUnit(string) }

    static func detectIndentUnit(_ text: String) -> String {
        var tabs = 0
        var smallest = Int.max
        for line in text.split(separator: "\n", omittingEmptySubsequences: true).prefix(500) {
            if line.hasPrefix("\t") { tabs += 1; continue }
            let spaces = line.prefix { $0 == " " }.count
            if spaces > 0, spaces < line.count { smallest = min(smallest, spaces) }
        }
        if tabs > 0, smallest == Int.max || tabs > 10 { return "\t" }
        return String(repeating: " ", count: smallest == Int.max ? 2 : (smallest >= 4 ? 4 : 2))
    }
}
