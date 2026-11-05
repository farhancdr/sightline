import AppKit
import SwiftUI

/// Paints `.diffLineBackground` across the full document width and hatches `.diffFiller` rows.
/// (Attributed `.backgroundColor` only covers glyphs; it's used for changed-character emphasis.)
final class DiffLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let storage = textStorage {
            enumerateLineFragments(forGlyphRange: glyphsToShow) { rect, usedRect, container, glyphRange, _ in
                let charIndex = self.characterIndexForGlyph(at: glyphRange.location)
                guard charIndex < storage.length else { return }
                var fill = rect.offsetBy(dx: origin.x, dy: origin.y)
                // Document width (longest line), so fills don't end mid-screen when scrolled right.
                fill.size.width = max(container.textView?.bounds.width ?? 0, usedRect.maxX) + 16
                if let color = storage.attribute(.diffLineBackground, at: charIndex, effectiveRange: nil) as? NSColor {
                    color.setFill()
                    fill.fill()
                } else if storage.attribute(.diffFiller, at: charIndex, effectiveRange: nil) != nil {
                    Self.hatch(fill)
                }
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    /// Diagonal stripes anchored to absolute y, so stacked filler rows form one continuous pattern.
    static func hatch(_ rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        DiffStyle.hatch.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        let spacing: CGFloat = 7
        var x = rect.minX - rect.height - (rect.minY.truncatingRemainder(dividingBy: spacing))
        while x < rect.maxX {
            path.move(to: NSPoint(x: x, y: rect.maxY))
            path.line(to: NSPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Gutter for a diff column: per-row line numbers, −/+ markers, change tint, and a hover copy
/// button (copies "path:line", or the selected range when clicked inside a multi-line selection).
final class DiffGutterRuler: NSRulerView {
    private weak var textView: NSTextView?
    private var side: DiffSide = .empty
    private let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private let markerWidth: CGFloat = 14
    private let iconWidth: CGFloat = 16
    private var hoveredRow: Int?
    private var copiedRow: Int?
    private var trackingArea: NSTrackingArea?

    /// Row index the copy button was clicked on.
    var onCopyRow: ((Int) -> Void)?
    /// Whether a row is inside a multi-row selection (the button then copies the range).
    var isInMultiRowSelection: ((Int) -> Bool)?

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        clipsToBounds = true
        ruleThickness = 64
        NotificationCenter.default.addObserver(
            self, selector: #selector(redraw), name: NSTextView.didChangeSelectionNotification, object: textView
        )
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func redraw() { needsDisplay = true }

    func update(_ side: DiffSide) {
        self.side = side
        hoveredRow = nil
        copiedRow = nil
        let widest = side.labels.max { $0.count < $1.count } ?? "000"
        let labelWidth = (String(repeating: "0", count: max(3, widest.count)) as NSString)
            .size(withAttributes: [.font: font]).width
        ruleThickness = ceil(iconWidth + labelWidth + markerWidth + 10)
        needsDisplay = true
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
        let row = copyableRow(at: convert(event.locationInWindow, from: nil))
        if row != hoveredRow {
            hoveredRow = row
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredRow = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard let row = copyableRow(at: convert(event.locationInWindow, from: nil)) else { return }
        onCopyRow?(row)
        copiedRow = row
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard self?.copiedRow == row else { return }
            self?.copiedRow = nil
            self?.needsDisplay = true
        }
    }

    /// Row under the point, if it has a line number (fillers/separators aren't copyable).
    private func copyableRow(at point: NSPoint) -> Int? {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer,
              !side.rowStarts.isEmpty else { return nil }
        var inText = textView.convert(point, from: self)
        inText.x = 0
        inText.y -= textView.textContainerOrigin.y
        let glyph = layoutManager.glyphIndex(for: inText, in: container)
        let row = DiffRows.row(containing: layoutManager.characterIndexForGlyph(at: glyph), in: side.rowStarts)
        return side.numbers.indices.contains(row) && side.numbers[row] != nil ? row : nil
    }

    // MARK: Drawing

    override func drawHashMarksAndLabels(in rect: NSRect) {
        Palette.canvas.setFill()
        bounds.fill()
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer,
              let scrollView, !side.rowStarts.isEmpty else { return }

        let visible = scrollView.contentView.bounds
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let origin = textView.textContainerOrigin
        let length = textView.textStorage?.length ?? 0

        var row = DiffRows.row(containing: charRange.location, in: side.rowStarts)
        while row < side.rowStarts.count, side.rowStarts[row] <= NSMaxRange(charRange), side.rowStarts[row] < length {
            let glyph = layoutManager.glyphIndexForCharacter(at: side.rowStarts[row])
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let y = convert(NSPoint(x: 0, y: lineRect.minY + origin.y), from: textView).y
            draw(row: row, in: NSRect(x: 0, y: y, width: ruleThickness, height: lineRect.height))
            row += 1
        }
    }

    private func draw(row: Int, in rect: NSRect) {
        var marker: String?
        var markerColor = Palette.textMuted
        switch side.kinds[row] {
        case .removed:
            DiffStyle.removedGutter.setFill()
            rect.fill()
            marker = "−"
            markerColor = Palette.deleted
        case .added:
            DiffStyle.addedGutter.setFill()
            rect.fill()
            marker = "+"
            markerColor = Palette.added
        case .filler:
            DiffLayoutManager.hatch(rect)
        case .separator:
            DiffStyle.separatorLine.setFill()
            rect.fill()
        case .context:
            break
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Palette.textMuted]
        let label = side.labels[row] as NSString
        let size = label.size(withAttributes: attrs)
        let textY = rect.minY + (rect.height - size.height) / 2
        label.draw(at: NSPoint(x: rect.maxX - markerWidth - 4 - size.width, y: textY), withAttributes: attrs)
        if let marker {
            (marker as NSString).draw(
                at: NSPoint(x: rect.maxX - markerWidth, y: textY),
                withAttributes: [.font: font, .foregroundColor: markerColor]
            )
        }
        if row == copiedRow {
            drawIcon("checkmark", color: Palette.added, in: rect)
        } else if row == hoveredRow {
            let range = isInMultiRowSelection?(row) ?? false
            drawIcon(range ? "text.line.first.and.arrowtriangle.forward" : "doc.on.doc", color: Palette.accent, in: rect)
        }
    }

    private func drawIcon(_ name: String, color: NSColor, in row: NSRect) {
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: "Copy path and line")?
            .withSymbolConfiguration(config) else { return }
        let size = image.size
        image.draw(
            in: NSRect(x: 4, y: row.minY + (row.height - size.height) / 2, width: size.width, height: size.height),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil
        )
    }
}

enum DiffRows {
    /// Binary search: row whose start offset is <= location.
    static func row(containing location: Int, in starts: [Int]) -> Int {
        guard !starts.isEmpty else { return 0 }
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= location { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// The line number at `row`, else the closest row below, else above (fillers have none).
    static func nearestNumber(to row: Int, in numbers: [Int?]) -> Int? {
        guard !numbers.isEmpty else { return nil }
        let start = min(max(0, row), numbers.count - 1)
        if let below = numbers[start...].lazy.compactMap({ $0 }).first { return below }
        return numbers[..<start].reversed().lazy.compactMap { $0 }.first
    }

    /// File-line range covered by rows `first...last` (skipping fillers/separators).
    static func lineRange(rows: ClosedRange<Int>, numbers: [Int?]) -> ClosedRange<Int>? {
        let lines = rows.compactMap { numbers.indices.contains($0) ? numbers[$0] : nil }
        guard let low = lines.min(), let high = lines.max() else { return nil }
        return low...high
    }
}

/// One read-only, non-wrapping diff column with its gutter.
final class DiffColumn {
    let scrollView = NSScrollView()
    let textView: NSTextView
    let ruler: DiffGutterRuler
    private(set) var side: DiffSide = .empty
    /// Called with a 1-based line range when the gutter copy button is clicked.
    var onCopyLines: ((ClosedRange<Int>) -> Void)?

    init() {
        let storage = NSTextStorage()
        let layoutManager = DiffLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 1e7, height: 1e7))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 8
        layoutManager.addTextContainer(container)

        textView = CodeTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.drawsBackground = true
        textView.backgroundColor = Palette.canvas
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: 1e7, height: 1e7)

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Palette.canvas
        scrollView.hasVerticalRuler = true
        ruler = DiffGutterRuler(textView: textView, scrollView: scrollView)
        scrollView.verticalRulerView = ruler
        scrollView.rulersVisible = true
        scrollView.contentView.postsBoundsChangedNotifications = true

        ruler.onCopyRow = { [weak self] row in self?.copyFromGutter(row: row) }
        ruler.isInMultiRowSelection = { [weak self] row in
            guard let rows = self?.selectedRows(), rows.count > 1 else { return false }
            return rows.contains(row)
        }
    }

    func show(_ side: DiffSide) {
        self.side = side
        textView.textStorage?.setAttributedString(side.text)
        ruler.update(side)
    }

    // MARK: References

    /// Rows touched by the selection (a selection ending right after a newline excludes the next row).
    func selectedRows() -> ClosedRange<Int>? {
        guard !side.rowStarts.isEmpty else { return nil }
        let range = textView.selectedRange()
        let first = DiffRows.row(containing: range.location, in: side.rowStarts)
        let last = range.length > 0 ? DiffRows.row(containing: NSMaxRange(range) - 1, in: side.rowStarts) : first
        return first...max(first, last)
    }

    /// File lines for the caret / selection in this column.
    func selectedLineRange() -> ClosedRange<Int>? {
        selectedRows().flatMap { DiffRows.lineRange(rows: $0, numbers: side.numbers) }
    }

    private func copyFromGutter(row: Int) {
        if let rows = selectedRows(), rows.count > 1, rows.contains(row),
           let lines = DiffRows.lineRange(rows: rows, numbers: side.numbers) {
            onCopyLines?(lines)
        } else if let number = side.numbers[row] {
            onCopyLines?(number...number)
        }
    }

    // MARK: Scrolling

    var topRow: Int {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return 0 }
        var point = scrollView.contentView.bounds.origin
        point.y -= textView.textContainerOrigin.y
        let glyph = layoutManager.glyphIndex(for: NSPoint(x: 0, y: max(0, point.y) + 1), in: container)
        return DiffRows.row(containing: layoutManager.characterIndexForGlyph(at: glyph), in: side.rowStarts)
    }

    /// Scrolls so `row` sits a few lines below the top.
    func scroll(toRow row: Int) {
        guard side.rowStarts.indices.contains(row), let layoutManager = textView.layoutManager else { return }
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: side.rowStarts[row] + 1))
        let glyph = layoutManager.glyphIndexForCharacter(at: side.rowStarts[row])
        let rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let y = max(0, rect.minY + textView.textContainerOrigin.y - rect.height * 4)
        scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Scrolls so the fraction `f` (0…1) of the document is centered.
    func scroll(toFraction f: CGFloat) {
        let docHeight = textView.frame.height
        let viewHeight = scrollView.contentView.bounds.height
        let y = min(max(0, f * docHeight - viewHeight / 2), max(0, docHeight - viewHeight))
        scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Visible part of the document as fractions (0…1).
    var visibleFraction: (start: CGFloat, end: CGFloat) {
        let docHeight = max(1, textView.frame.height)
        let bounds = scrollView.contentView.bounds
        return (bounds.minY / docHeight, min(1, bounds.maxY / docHeight))
    }
}

/// VS Code-style overview ruler: where the changes are in the whole file, the visible region,
/// and click / drag to jump.
final class DiffOverviewRuler: NSView {
    struct Mark {
        let start: Int
        let end: Int
        let color: NSColor
        /// 0 = full width, 1 = left half, 2 = right half.
        let lane: Int
    }

    private var marks: [Mark] = []
    private var rowCount = 1
    private var visible: (start: CGFloat, end: CGFloat) = (0, 0)
    var onJump: ((CGFloat) -> Void)?

    override var isFlipped: Bool { true }

    /// Side-by-side: removed on the left lane, added on the right lane.
    func update(left: [DiffRowKind], right: [DiffRowKind]) {
        rowCount = max(1, left.count)
        marks = Self.runs(left, kind: .removed, color: Palette.deleted, lane: 1)
            + Self.runs(right, kind: .added, color: Palette.added, lane: 2)
        needsDisplay = true
    }

    /// Inline: one lane.
    func update(inline kinds: [DiffRowKind]) {
        rowCount = max(1, kinds.count)
        marks = Self.runs(kinds, kind: .removed, color: Palette.deleted, lane: 0)
            + Self.runs(kinds, kind: .added, color: Palette.added, lane: 0)
        needsDisplay = true
    }

    func updateVisible(_ fraction: (start: CGFloat, end: CGFloat)) {
        guard fraction != visible else { return }
        visible = fraction
        needsDisplay = true
    }

    /// Contiguous runs of `kind` as [start, end) row ranges.
    static func runs(_ kinds: [DiffRowKind], kind: DiffRowKind, color: NSColor, lane: Int) -> [Mark] {
        var result: [Mark] = []
        var start: Int?
        for (index, k) in kinds.enumerated() {
            if k == kind {
                if start == nil { start = index }
            } else if let s = start {
                result.append(Mark(start: s, end: index, color: color, lane: lane))
                start = nil
            }
        }
        if let s = start { result.append(Mark(start: s, end: kinds.count, color: color, lane: lane)) }
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        Palette.canvas.setFill()
        bounds.fill()
        Palette.border.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()

        let height = bounds.height
        let inner = NSRect(x: 2, y: 0, width: bounds.width - 3, height: height)
        // Visible region box.
        Palette.textMuted.withAlphaComponent(0.14).setFill()
        NSRect(x: 1, y: visible.start * height, width: bounds.width - 1,
               height: max(4, (visible.end - visible.start) * height)).fill()
        for mark in marks {
            let y = CGFloat(mark.start) / CGFloat(rowCount) * height
            let h = max(2, CGFloat(mark.end - mark.start) / CGFloat(rowCount) * height)
            var rect = NSRect(x: inner.minX, y: y, width: inner.width, height: h)
            if mark.lane == 1 { rect.size.width = inner.width / 2 }
            if mark.lane == 2 {
                rect.origin.x = inner.midX
                rect.size.width = inner.width / 2
            }
            mark.color.setFill()
            rect.fill()
        }
    }

    override func mouseDown(with event: NSEvent) { jump(event) }
    override func mouseDragged(with event: NSEvent) { jump(event) }

    private func jump(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onJump?(min(1, max(0, point.y / max(1, bounds.height))))
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// Common interface for the two diff layouts.
protocol DiffHostView: NSView {
    var referencePath: String { get set }
    var onReferenceCopied: ((String) -> Void)? { get set }
    func show(_ document: DiffDocument, resetScroll: Bool)
    func navigate(_ direction: Int)
    /// ⇧⌘C: copy "path:line(s)" for the caret / selection of the focused column.
    func copyReference()
    /// Line in the current (new) file at the caret, for "Open in Editor".
    func caretLine() -> Int?
    /// ⌘-click on an identifier in either column.
    var onCommandClick: ((String) -> Void)? { get set }
}

extension DiffHostView {
    func copy(lines: ClosedRange<Int>?) {
        guard let lines else {
            NSSound.beep()
            return
        }
        let reference = EditorController.reference(path: referencePath, lines: lines)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reference, forType: .string)
        onReferenceCopied?(reference)
    }
}

/// The diff view currently on screen, for the ⇧⌘C menu command.
@MainActor
enum DiffReference {
    static weak var activeHost: (any DiffHostView)?
}

/// VS Code-style side-by-side diff: old on the left, new on the right, scrolled together.
/// The line between the two diff columns: drag to resize, double-click to split evenly.
final class SplitDividerHandle: NSView {
    static let grabWidth: CGFloat = 7
    var onDrag: ((CGFloat) -> Void)?
    var onReset: (() -> Void)?
    private var hovering = false { didSet { needsDisplay = true } }
    private var dragging = false { didSet { needsDisplay = true } }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onReset?()
            return
        }
        dragging = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let superview else { return }
        onDrag?(superview.convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) { dragging = false }

    override func draw(_ dirtyRect: NSRect) {
        let active = hovering || dragging
        (active ? Palette.accent : Palette.border).setFill()
        let width: CGFloat = active ? 3 : 1
        NSRect(x: (bounds.width - width) / 2, y: 0, width: width, height: bounds.height).fill()
    }
}

final class SplitDiffView: NSView, DiffHostView {
    private let left = DiffColumn()
    private let right = DiffColumn()
    private let divider = SplitDividerHandle()
    private let overview = DiffOverviewRuler()
    private let overviewWidth: CGFloat = 14
    private var changeRows: [Int] = []
    private var syncing = false
    /// First-change jump waits until the view has a real size.
    private var pendingScrollRow: Int?
    var referencePath = ""
    var onReferenceCopied: ((String) -> Void)?
    var onCommandClick: ((String) -> Void)? {
        didSet {
            (left.textView as? CodeTextView)?.onCommandClick = onCommandClick
            (right.textView as? CodeTextView)?.onCommandClick = onCommandClick
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for view in [left.scrollView, right.scrollView, overview, divider] { addSubview(view) }
        divider.onDrag = { [weak self] x in self?.dragDivider(to: x) }
        divider.onReset = { [weak self] in self?.setFraction(0.5) }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(leftScrolled), name: NSView.boundsDidChangeNotification,
                           object: left.scrollView.contentView)
        center.addObserver(self, selector: #selector(rightScrolled), name: NSView.boundsDidChangeNotification,
                           object: right.scrollView.contentView)
        left.onCopyLines = { [weak self] in self?.copy(lines: $0) }
        right.onCopyLines = { [weak self] in self?.copy(lines: $0) }
        overview.onJump = { [weak self] in self?.left.scroll(toFraction: $0) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func layout() {
        super.layout()
        let content = bounds.width - overviewWidth
        let half = floor(content * Self.fraction)
        left.scrollView.frame = NSRect(x: 0, y: 0, width: half, height: bounds.height)
        // The handle is wider than the 1pt line it draws, so it's easy to grab.
        divider.frame = NSRect(x: half - SplitDividerHandle.grabWidth / 2 + 0.5, y: 0,
                               width: SplitDividerHandle.grabWidth, height: bounds.height)
        right.scrollView.frame = NSRect(x: half + 1, y: 0, width: content - half - 1, height: bounds.height)
        overview.frame = NSRect(x: content, y: 0, width: overviewWidth, height: bounds.height)
        overview.updateVisible(left.visibleFraction)
        flushPendingScroll()
    }

    private func flushPendingScroll() {
        guard let row = pendingScrollRow, bounds.height > 0 else { return }
        pendingScrollRow = nil
        DispatchQueue.main.async { [weak self] in self?.left.scroll(toRow: row) }
    }

    // MARK: Resizable split

    private static let fractionKey = "diffSplitFraction"
    /// Left column's share of the width; shared by every split diff and remembered across launches.
    private(set) static var fraction: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: fractionKey)
        return saved > 0 ? clampFraction(saved) : 0.5
    }()

    static func clampFraction(_ value: CGFloat) -> CGFloat { min(max(value, 0.15), 0.85) }

    private func dragDivider(to x: CGFloat) {
        let content = bounds.width - overviewWidth
        guard content > 0 else { return }
        setFraction(x / content)
    }

    private func setFraction(_ value: CGFloat) {
        Self.fraction = Self.clampFraction(value)
        UserDefaults.standard.set(Double(Self.fraction), forKey: Self.fractionKey)
        needsLayout = true
    }

    func show(_ document: DiffDocument, resetScroll: Bool) {
        let keep = left.scrollView.contentView.bounds.origin
        changeRows = document.changeRows
        left.show(document.left)
        right.show(document.right)
        overview.update(left: document.left.kinds, right: document.right.kinds)
        if resetScroll, let first = changeRows.first {
            pendingScrollRow = first
            flushPendingScroll()
        } else if !resetScroll {
            left.scrollView.contentView.scroll(to: keep)
            left.scrollView.reflectScrolledClipView(left.scrollView.contentView)
        }
    }

    func navigate(_ direction: Int) {
        guard let target = DiffNavigation.target(from: left.topRow + 4, rows: changeRows, direction: direction) else {
            NSSound.beep()
            return
        }
        left.scroll(toRow: target)
    }

    func copyReference() {
        // The column with keyboard focus; otherwise the new (right) side.
        let column = window?.firstResponder === left.textView ? left : right
        copy(lines: column.selectedLineRange())
    }

    /// The new-file line on the caret's row (or the nearest row that has one), whichever side has focus.
    func caretLine() -> Int? {
        let column = window?.firstResponder === left.textView ? left : right
        guard let row = column.selectedRows()?.lowerBound else { return nil }
        return DiffRows.nearestNumber(to: row, in: right.side.numbers)
    }

    @objc private func leftScrolled() { sync(from: left, to: right) }
    @objc private func rightScrolled() { sync(from: right, to: left) }

    /// Vertical scroll stays locked; horizontal is per side.
    private func sync(from source: DiffColumn, to target: DiffColumn) {
        overview.updateVisible(source.visibleFraction)
        guard !syncing else { return }
        syncing = true
        let y = source.scrollView.contentView.bounds.origin.y
        let x = target.scrollView.contentView.bounds.origin.x
        target.scrollView.contentView.scroll(to: NSPoint(x: x, y: y))
        target.scrollView.reflectScrolledClipView(target.scrollView.contentView)
        target.ruler.needsDisplay = true
        syncing = false
    }
}

/// Single-column unified diff with old/new line numbers.
final class InlineDiffView: NSView, DiffHostView {
    private let column = DiffColumn()
    private let overview = DiffOverviewRuler()
    private let overviewWidth: CGFloat = 14
    private var changeRows: [Int] = []
    private var pendingScrollRow: Int?
    var referencePath = ""
    var onReferenceCopied: ((String) -> Void)?
    var onCommandClick: ((String) -> Void)? {
        didSet { (column.textView as? CodeTextView)?.onCommandClick = onCommandClick }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(column.scrollView)
        addSubview(overview)
        column.onCopyLines = { [weak self] in self?.copy(lines: $0) }
        overview.onJump = { [weak self] in self?.column.scroll(toFraction: $0) }
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
            object: column.scrollView.contentView
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func scrolled() { overview.updateVisible(column.visibleFraction) }

    override func layout() {
        super.layout()
        column.scrollView.frame = NSRect(x: 0, y: 0, width: bounds.width - overviewWidth, height: bounds.height)
        overview.frame = NSRect(x: bounds.width - overviewWidth, y: 0, width: overviewWidth, height: bounds.height)
        overview.updateVisible(column.visibleFraction)
        flushPendingScroll()
    }

    private func flushPendingScroll() {
        guard let row = pendingScrollRow, bounds.height > 0 else { return }
        pendingScrollRow = nil
        DispatchQueue.main.async { [weak self] in self?.column.scroll(toRow: row) }
    }

    func show(_ document: DiffDocument, resetScroll: Bool) {
        let keep = column.scrollView.contentView.bounds.origin
        changeRows = document.inlineChangeRows
        column.show(document.inline)
        overview.update(inline: document.inline.kinds)
        if resetScroll, let first = changeRows.first {
            pendingScrollRow = first
            flushPendingScroll()
        } else if !resetScroll {
            column.scrollView.contentView.scroll(to: keep)
            column.scrollView.reflectScrolledClipView(column.scrollView.contentView)
        }
    }

    func navigate(_ direction: Int) {
        guard let target = DiffNavigation.target(from: column.topRow + 4, rows: changeRows, direction: direction) else {
            NSSound.beep()
            return
        }
        column.scroll(toRow: target)
    }

    func copyReference() { copy(lines: column.selectedLineRange()) }

    func caretLine() -> Int? {
        guard let row = column.selectedRows()?.lowerBound else { return nil }
        return DiffRows.nearestNumber(to: row, in: column.side.numbers)
    }
}

enum DiffNavigation {
    /// Next/previous change-block start relative to `row` (the row near the top of the view).
    static func target(from row: Int, rows: [Int], direction: Int) -> Int? {
        direction > 0 ? rows.first { $0 > row } : rows.last { $0 < row }
    }
}

struct DiffNavRequest: Equatable {
    var id = 0
    var direction = 0
}

/// SwiftUI wrapper. `fileID` decides whether a new document resets scroll (new file → jump to the
/// first change) or keeps it (same file reloaded after an edit).
struct DiffContentView: NSViewRepresentable {
    let document: DiffDocument
    let fileID: String
    let sideBySide: Bool
    let nav: DiffNavRequest
    /// Workspace-root-relative path for "path:line" references.
    let referencePath: String
    let onReferenceCopied: (String) -> Void
    var onCommandClick: ((String) -> Void)?

    func makeNSView(context: Context) -> NSView {
        sideBySide ? SplitDiffView(frame: .zero) : InlineDiffView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard let host = view as? DiffHostView else { return }
        host.referencePath = referencePath
        host.onReferenceCopied = onReferenceCopied
        host.onCommandClick = onCommandClick
        DiffReference.activeHost = host
        let coordinator = context.coordinator
        if coordinator.documentID != document.id {
            host.show(document, resetScroll: coordinator.fileID != fileID)
            coordinator.documentID = document.id
            coordinator.fileID = fileID
        }
        if coordinator.navID != nav.id {
            coordinator.navID = nav.id
            host.navigate(nav.direction)
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        if DiffReference.activeHost === view { DiffReference.activeHost = nil }
    }

    func makeCoordinator() -> Coordinator { Coordinator(navID: nav.id) }

    final class Coordinator {
        var documentID: UUID?
        var fileID: String?
        var navID: Int

        init(navID: Int) { self.navID = navID }
    }
}
