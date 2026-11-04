import AppKit

/// Line numbers for a non-wrapping TextKit 1 NSTextView, with a hover copy button per line.
/// Clicking it copies "path:line", or "path:from-to" when the click is inside a multi-line
/// selection (same result as ⇧⌘C). Selected lines are drawn darker.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    private var lineStarts: [Int] = [0]
    private var needsIndex = true
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private let iconWidth: CGFloat = 16
    private var hoveredLine: Int?
    private var copiedLine: Int?
    private var trackingArea: NSTrackingArea?

    /// Called with a 1-based, inclusive line range.
    var onCopyLines: ((ClosedRange<Int>) -> Void)?

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 56
        clipsToBounds = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(textChanged), name: NSText.didChangeNotification, object: textView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(redraw), name: NSTextView.didChangeSelectionNotification, object: textView
        )
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc func textChanged() {
        needsIndex = true
        needsDisplay = true
    }

    @objc private func redraw() { needsDisplay = true }

    // MARK: Line index

    private func rebuildIndex() {
        guard let string = textView?.string else { return }
        var starts = [0]
        var offset = 0
        for unit in string.utf16 {
            offset += 1
            if unit == 10 { starts.append(offset) }
        }
        lineStarts = starts
        needsIndex = false
        let digits = max(3, String(starts.count).count)
        let width = CGFloat(digits) * 7.5 + 16 + iconWidth
        if abs(width - ruleThickness) > 0.5 { ruleThickness = width }
    }

    /// 0-based index of the line containing `location` (binary search).
    func lineIndex(for location: Int) -> Int {
        if needsIndex { rebuildIndex() }
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// 1-based inclusive line range of the current selection (caret line when nothing is selected).
    func selectedLines() -> ClosedRange<Int> {
        guard let textView else { return 1...1 }
        let range = textView.selectedRange()
        let first = lineIndex(for: range.location)
        // A selection ending right after a newline doesn't include the next line.
        let last = range.length > 0 ? lineIndex(for: NSMaxRange(range) - 1) : first
        return (first + 1)...(max(first, last) + 1)
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let line = line(at: convert(event.locationInWindow, from: nil))
        if line != hoveredLine {
            hoveredLine = line
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredLine = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard let line = line(at: convert(event.locationInWindow, from: nil)) else { return }
        let selection = selectedLines()
        let lines = selection.count > 1 && selection.contains(line + 1) ? selection : (line + 1)...(line + 1)
        onCopyLines?(lines)
        copiedLine = line
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard self?.copiedLine == line else { return }
            self?.copiedLine = nil
            self?.needsDisplay = true
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    /// 0-based line under a point in ruler coordinates.
    private func line(at point: NSPoint) -> Int? {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer
        else { return nil }
        if needsIndex { rebuildIndex() }
        var inText = textView.convert(point, from: self)
        inText.x = 0
        inText.y -= textView.textContainerOrigin.y
        let length = (textView.string as NSString).length
        if length == 0 { return 0 }
        // Below the last line fragment: the empty line after a final newline.
        let extra = layoutManager.extraLineFragmentRect
        if !extra.isEmpty, inText.y >= extra.minY { return lineStarts.count - 1 }
        let glyph = layoutManager.glyphIndex(for: inText, in: container)
        return lineIndex(for: min(layoutManager.characterIndexForGlyph(at: glyph), length))
    }

    // MARK: Drawing

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer, let scrollView else { return }
        Palette.canvas.setFill()
        bounds.fill()
        if needsIndex { rebuildIndex() }

        let length = (textView.string as NSString).length
        let visible = scrollView.contentView.bounds
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let selected = selectedLines()
        let origin = textView.textContainerOrigin

        var index = lineIndex(for: charRange.location)
        while index < lineStarts.count {
            let start = lineStarts[index]
            if start > NSMaxRange(charRange) { break }
            let lineRect: NSRect
            if start >= length {
                lineRect = layoutManager.extraLineFragmentRect
                if lineRect.isEmpty, length > 0 { break }
            } else {
                lineRect = layoutManager.lineFragmentRect(
                    forGlyphAt: layoutManager.glyphIndexForCharacter(at: start), effectiveRange: nil
                )
            }
            let y = convert(NSPoint(x: 0, y: lineRect.minY + origin.y), from: textView).y
            let rowRect = NSRect(x: 0, y: y, width: ruleThickness, height: lineRect.height)
            let isSelected = selected.contains(index + 1)

            let label = "\(index + 1)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: isSelected ? Palette.text : Palette.textMuted.withAlphaComponent(0.75),
            ]
            let size = label.size(withAttributes: attrs)
            label.draw(
                at: NSPoint(x: ruleThickness - size.width - 8, y: y + (lineRect.height - size.height) / 2),
                withAttributes: attrs
            )
            if index == copiedLine {
                drawIcon("checkmark", color: Palette.added, in: rowRect)
            } else if index == hoveredLine {
                // Inside a multi-line selection the button copies the whole range.
                let copiesRange = selected.count > 1 && isSelected
                drawIcon(copiesRange ? "text.line.first.and.arrowtriangle.forward" : "doc.on.doc",
                         color: Palette.accent, in: rowRect)
            }
            index += 1
        }
    }

    private func drawIcon(_ name: String, color: NSColor, in row: NSRect) {
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: "Copy path and line")?
            .withSymbolConfiguration(config) else { return }
        let size = image.size
        image.draw(
            in: NSRect(x: 5, y: row.minY + (row.height - size.height) / 2, width: size.width, height: size.height),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
        )
    }
}
