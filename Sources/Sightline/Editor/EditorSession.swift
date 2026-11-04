import AppKit
import Observation

/// One open file. Owns its NSTextView so edits survive SwiftUI view rebuilds (switching between
/// Changes and Files, toggling File/Diff, etc.).
@MainActor
@Observable
final class EditorSession {
    let path: String
    let language: Language
    let message: String?
    private(set) var isDirty = false

    @ObservationIgnored let controller: EditorController?
    @ObservationIgnored private var savedText: String

    var isEditable: Bool { controller != nil }

    /// `referencePath`: workspace-root-relative path used for "path:line" references.
    init(content: FileContent, referencePath: String, onReferenceCopied: @escaping (String) -> Void) {
        path = content.path
        language = Language.detect(path: content.path)
        message = content.message
        savedText = content.text ?? ""
        if let text = content.text {
            controller = EditorController(text: text, language: language)
        } else {
            controller = nil
        }
        controller?.referencePath = referencePath
        controller?.onReferenceCopied = onReferenceCopied
        controller?.onTextChange = { [weak self] in self?.updateDirty() }
    }

    private func updateDirty() {
        guard let controller else { return }
        let dirty = controller.text != savedText
        if dirty != isDirty { isDirty = dirty }
    }

    func save() throws {
        guard let controller else { return }
        let text = controller.text
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        savedText = text
        isDirty = false
        controller.scheduleBlame(immediately: true)
    }

    /// Picks up changes made on disk (terminal, another editor) unless there are unsaved edits.
    func reloadFromDiskIfClean() {
        guard !isDirty, let controller else { return }
        let content = FileContent.load(path: path)
        guard let text = content.text, text != savedText else { return }
        savedText = text
        controller.replaceText(text)
    }
}

/// AppKit side of the editor: scroll view, text view, ruler, highlighting, auto-indent.
@MainActor
final class EditorController: NSObject, NSTextViewDelegate {
    let scrollView: NSScrollView
    let textView: NSTextView
    let language: Language
    var onTextChange: (() -> Void)?
    /// Workspace-root-relative path, e.g. services/api/src/routes/users.ts.
    var referencePath = ""
    var onReferenceCopied: ((String) -> Void)?
    /// Injectable so tests don't overwrite the user's clipboard.
    var pasteboard: NSPasteboard = .general
    private var ruler: LineNumberRuler?

    // MARK: Blame state (GitLens-style current-line annotation)

    struct BlameContext {
        let repoPath: String
        /// Path relative to the repo, as git expects.
        let relativePath: String
        /// Opens a commit (sha) in the History panel.
        let openCommit: (String) -> Void
    }

    var blameContext: BlameContext? { didSet { scheduleBlame(immediately: true) } }
    var blameEnabled = true {
        didSet {
            if blameEnabled { scheduleBlame(immediately: true) } else { blameLabel.isHidden = true }
        }
    }
    private var blame: BlameResult?
    private var blameIsStale = true
    private var blameGeneration = 0
    private var blameWork: DispatchWorkItem?
    private var userEmail: String?
    private static let maxBlameLength = 2_000_000
    private lazy var blameLabel: BlameLabel = {
        let label = BlameLabel()
        label.isHidden = true
        label.onClick = { [weak self] sha in self?.blameContext?.openCommit(sha) }
        textView.addSubview(label)
        return label
    }()

    private let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
    private let boldFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .bold)
    private var highlightGeneration = 0
    private var highlightWork: DispatchWorkItem?

    var text: String { textView.string }

    init(text: String, language: Language) {
        self.language = language

        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 1e7, height: 1e7))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 8
        layoutManager.addTextContainer(container)

        textView = CodeTextView(frame: .zero, textContainer: container)
        scrollView = NSScrollView()
        super.init()

        configureTextView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Palette.canvas
        // hasVerticalRuler first: AppKit can replace a ruler that was assigned before it.
        scrollView.hasVerticalRuler = true
        let ruler = LineNumberRuler(textView: textView, scrollView: scrollView)
        ruler.onCopyLines = { [weak self] lines in self?.copyReference(lines) }
        scrollView.verticalRulerView = ruler
        scrollView.rulersVisible = true
        self.ruler = ruler

        setInitialText(text)
    }

    private func configureTextView() {
        textView.delegate = self
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.drawsBackground = true
        textView.backgroundColor = Palette.canvas
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = NSSize(width: 0, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: 1e7, height: 1e7)

        let paragraph = NSMutableParagraphStyle()
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        paragraph.defaultTabInterval = spaceWidth * 4
        paragraph.tabStops = []
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [.font: font, .foregroundColor: SyntaxTheme.text, .paragraphStyle: paragraph]
    }

    private func setInitialText(_ text: String) {
        textView.string = text
        if let storage = textView.textStorage {
            let full = NSRange(location: 0, length: storage.length)
            storage.addAttributes(textView.typingAttributes, range: full)
        }
        highlightNow()
    }

    /// Replaces the whole text (disk reload) keeping the caret roughly in place.
    func replaceText(_ text: String) {
        let selection = textView.selectedRange()
        let visible = scrollView.contentView.bounds.origin
        setInitialText(text)
        textView.undoManager?.removeAllActions()
        let length = (text as NSString).length
        textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        scrollView.contentView.scroll(to: visible)
        (scrollView.verticalRulerView as? LineNumberRuler)?.textChanged()
        scheduleBlame(immediately: true)
        // Programmatic `string` changes don't post this; the markdown preview listens for it.
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: textView)
    }

    // MARK: Highlighting

    private func highlightNow() {
        guard language.mode != .plain else { return }
        highlightGeneration += 1
        let generation = highlightGeneration
        let snapshot = textView.string
        guard (snapshot as NSString).length <= SyntaxHighlighter.maxHighlightLength else { return }
        let language = language
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let tokens = SyntaxHighlighter.tokens(for: snapshot, language: language)
            DispatchQueue.main.async {
                guard let self, generation == self.highlightGeneration,
                      let storage = self.textView.textStorage, storage.string == snapshot else { return }
                SyntaxHighlighter.apply(tokens, to: storage, font: self.font, boldFont: self.boldFont)
            }
        }
    }

    private func scheduleHighlight() {
        highlightWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.highlightNow() }
        highlightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: Path:line references (for AI agents)

    /// "path:12" or "path:12-30".
    nonisolated static func reference(path: String, lines: ClosedRange<Int>) -> String {
        lines.count > 1 ? "\(path):\(lines.lowerBound)-\(lines.upperBound)" : "\(path):\(lines.lowerBound)"
    }

    /// ⌘-click on an identifier in the editor.
    var onCommandClick: ((String) -> Void)? {
        get { (textView as? CodeTextView)?.onCommandClick }
        set { (textView as? CodeTextView)?.onCommandClick = newValue }
    }

    /// 1-based caret line (first line of the selection).
    func caretLine() -> Int? { ruler?.selectedLines().lowerBound }

    /// 1-based caret column.
    func caretColumn() -> Int {
        let caret = textView.selectedRange().location
        guard let line = caretLine(), let ruler else { return 1 }
        return caret - ruler.offset(ofLine: line) + 1
    }

    /// Moves the caret to `line`/`column` (1-based), selects `length` characters, centers it and flashes it.
    func reveal(line: Int, column: Int = 1, length: Int = 0) {
        guard let ruler, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let total = (textView.string as NSString).length
        let start = min(total, ruler.offset(ofLine: line) + max(0, column - 1))
        let range = NSRange(location: start, length: min(max(0, length), total - start))
        textView.setSelectedRange(range)
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: min(total, start + 1)))
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.y += textView.textContainerOrigin.y
        let visible = scrollView.contentView.bounds
        let target = NSPoint(x: max(0, rect.minX - visible.width / 3), y: max(0, rect.midY - visible.height / 2))
        scrollView.contentView.scroll(to: rect.maxX < visible.width * 0.9 ? NSPoint(x: 0, y: target.y) : target)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        textView.window?.makeFirstResponder(textView)
        if range.length > 0 { textView.showFindIndicator(for: range) }
    }

    /// ⇧⌘C / gutter button: caret or single-line selection → "path:N"; multi-line selection → "path:from-to".
    func copyReference(_ lines: ClosedRange<Int>? = nil) {
        guard let range = lines ?? ruler?.selectedLines() else { return }
        let reference = Self.reference(path: referencePath, lines: range)
        pasteboard.clearContents()
        pasteboard.setString(reference, forType: .string)
        onReferenceCopied?(reference)
    }

    // MARK: Blame

    /// Re-blames after typing settles (or right away). The annotation is hidden while results are stale.
    func scheduleBlame(immediately: Bool = false) {
        blameIsStale = true
        blameLabel.isHidden = true
        blameWork?.cancel()
        guard blameEnabled, blameContext != nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.runBlame() }
        blameWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (immediately ? 0.05 : 0.8), execute: work)
    }

    private func runBlame() {
        guard let context = blameContext else { return }
        let text = textView.string
        guard (text as NSString).length <= Self.maxBlameLength else { return }
        blameGeneration += 1
        let generation = blameGeneration
        Task { @MainActor [weak self] in
            let result = try? await GitCommands.blame(context.repoPath, path: context.relativePath, contents: text)
            let email = self?.userEmail == nil ? await GitCommands.userEmail(context.repoPath) : nil
            guard let self, generation == self.blameGeneration else { return }
            if let email { self.userEmail = email }
            self.blame = result
            self.blameIsStale = false
            self.updateBlameAnnotation()
        }
    }

    private func updateBlameAnnotation() {
        guard blameEnabled, !blameIsStale, let blame, let layoutManager = textView.layoutManager else {
            blameLabel.isHidden = true
            return
        }
        let ns = textView.string as NSString
        let caret = min(textView.selectedRange().location, ns.length)
        let lineRange = ns.lineRange(for: NSRange(location: caret, length: 0))
        let line = ruler?.lineIndex(for: caret) ?? 0
        guard lineRange.location < ns.length, let commit = blame.commit(forLine: line) else {
            blameLabel.isHidden = true
            return
        }
        blameLabel.stringValue = Self.annotation(for: commit, userEmail: userEmail)
        blameLabel.sha = commit.isUncommitted ? nil : commit.sha
        blameLabel.toolTip = commit.isUncommitted
            ? "Not committed yet"
            : "\(commit.author) <\(commit.email)>\n\(RelativeDate.absoluteString(commit.date))\n\n\(commit.summary)\n\n"
                + "\(commit.sha.prefix(10)) · click to open in History"
        blameLabel.sizeToFit()
        let glyph = layoutManager.glyphIndexForCharacter(at: lineRange.location)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let used = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        let origin = textView.textContainerOrigin
        blameLabel.setFrameOrigin(NSPoint(
            x: origin.x + used.maxX + 36,
            y: origin.y + fragment.minY + (fragment.height - blameLabel.frame.height) / 2
        ))
        blameLabel.isHidden = false
    }

    /// "You, 3 days ago · Fix login redirect" / "You · Uncommitted changes"
    nonisolated static func annotation(for commit: BlameCommit, userEmail: String?, now: Date = Date()) -> String {
        if commit.isUncommitted { return "You · Uncommitted changes" }
        let isYou = userEmail.map { $0.caseInsensitiveCompare(commit.email) == .orderedSame } ?? false
        let summary = commit.summary.count > 72 ? commit.summary.prefix(71) + "…" : Substring(commit.summary)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "\(isYou ? "You" : commit.author), \(formatter.localizedString(for: commit.date, relativeTo: now)) · \(summary)"
    }

    // MARK: NSTextViewDelegate

    func textViewDidChangeSelection(_ notification: Notification) {
        updateBlameAnnotation()
    }

    func textDidChange(_ notification: Notification) {
        scheduleBlame()
        onTextChange?()
        scheduleHighlight()
    }

    /// Auto-indent: a new line keeps the previous line's leading whitespace.
    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        let ns = textView.string as NSString
        let caret = textView.selectedRange().location
        let lineStart = ns.lineRange(for: NSRange(location: min(caret, ns.length), length: 0)).location
        var indentEnd = lineStart
        while indentEnd < min(caret, ns.length) {
            let ch = ns.character(at: indentEnd)
            guard ch == 32 || ch == 9 else { break }
            indentEnd += 1
        }
        let indent = ns.substring(with: NSRange(location: lineStart, length: indentEnd - lineStart))
        textView.insertText("\n" + indent, replacementRange: textView.selectedRange())
        return true
    }
}

/// The faint, clickable blame text shown after the caret line.
final class BlameLabel: NSTextField {
    var sha: String?
    var onClick: ((String) -> Void)?

    convenience init() {
        self.init(labelWithString: "")
        let base = NSFont.systemFont(ofSize: 11.5)
        font = NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
        textColor = Palette.textMuted.withAlphaComponent(0.8)
        lineBreakMode = .byClipping
    }

    override func mouseDown(with event: NSEvent) {
        if let sha { onClick?(sha) } else { super.mouseDown(with: event) }
    }

    override func resetCursorRects() {
        if sha != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }
}
