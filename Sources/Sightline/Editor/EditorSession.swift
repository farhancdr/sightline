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

        textView = NSTextView(frame: .zero, textContainer: container)
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

    /// ⇧⌘C / gutter button: caret or single-line selection → "path:N"; multi-line selection → "path:from-to".
    func copyReference(_ lines: ClosedRange<Int>? = nil) {
        guard let range = lines ?? ruler?.selectedLines() else { return }
        let reference = Self.reference(path: referencePath, lines: range)
        pasteboard.clearContents()
        pasteboard.setString(reference, forType: .string)
        onReferenceCopied?(reference)
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
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
