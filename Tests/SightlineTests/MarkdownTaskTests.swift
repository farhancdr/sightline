import AppKit
import WebKit
import XCTest
@testable import Sightline

final class MarkdownTaskEditTests: XCTestCase {
    private let md = """
    # Plan

    - [ ] first
    - [x] second
      1. [X] nested ordered

    > - [ ] quoted

    * plain item
    """

    private func apply(_ line: Int, _ checked: Bool) -> String? {
        guard let edit = MarkdownTasks.edit(in: md, line: line, checked: checked) else { return nil }
        return (md as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    func testTogglesTheTaskOnThatLine() {
        XCTAssertTrue(apply(3, true)?.contains("- [x] first") ?? false)
        XCTAssertTrue(apply(4, false)?.contains("- [ ] second") ?? false)
        XCTAssertTrue(apply(5, false)?.contains("  1. [ ] nested ordered") ?? false)
        XCTAssertTrue(apply(7, true)?.contains("> - [x] quoted") ?? false)
    }

    func testIgnoresNonTasksAndNoOps() {
        XCTAssertNil(apply(1, true), "heading")
        XCTAssertNil(apply(9, true), "plain list item")
        XCTAssertNil(apply(6, true), "blank line")
        XCTAssertNil(apply(3, false), "already unchecked")
        XCTAssertNil(apply(99, true), "past the end")
    }

    func testRenderedLinesMatchTheSource() {
        let html = MarkdownRenderer.body(md)
        // swift-markdown leaves tasks inside a blockquote as plain text, so line 7 has no checkbox.
        for line in [3, 4, 5] {
            XCTAssertTrue(html.contains("data-line=\"\(line)\""), "line \(line) in \(html)")
        }
    }
}

/// The click path end to end: a checkbox click in WebKit (page scripts off) reaches Swift, and the store
/// rewrites the file.
@MainActor
final class MarkdownTaskClickTests: XCTestCase {
    private final class Recorder: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var messages: [[String: Any]] = []
        var loaded: CheckedContinuation<Void, Never>?
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? [String: Any] { messages.append(body) }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded?.resume(); loaded = nil }
    }

    func testClickingACheckboxPostsItsLine() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let recorder = Recorder()
        configuration.userContentController.addUserScript(TaskSupport.userScript)
        configuration.userContentController.add(WeakMessageHandler(recorder), contentWorld: .defaultClient,
                                                name: TaskSupport.handlerName)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), configuration: configuration)
        webView.navigationDelegate = recorder
        await withCheckedContinuation { continuation in
            recorder.loaded = continuation
            webView.loadHTMLString(MarkdownPage.html(body: MarkdownRenderer.body("intro\n\n- [ ] todo\n")), baseURL: nil)
        }
        _ = try await webView.evaluateJavaScript("document.querySelector('input.task-toggle').click(); 0",
                                                 contentWorld: .defaultClient)
        for _ in 0..<50 where recorder.messages.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(recorder.messages.first?["line"] as? Int, 3)
        XCTAssertEqual(recorder.messages.first?["checked"] as? Bool, true)
    }

    func testToggleSavesACleanFileAndLeavesUnsavedEditsUnsaved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sightline-tasks-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repo = "\(root)/app"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        _ = try await Git.run(["init", "-q"], in: repo)
        let file = "\(repo)/PLAN.md"
        try "# Plan\n\n- [ ] one\n- [ ] two\n".write(toFile: file, atomically: true, encoding: .utf8)

        let store = AppStore.shared
        await store.open(root: root)
        store.selectRepo(try XCTUnwrap(store.repos.first).id)
        defer { store.closeAllTabs() }
        store.openInEditor(repoRelativePath: "PLAN.md", preview: false)
        for _ in 0..<100 where store.editor == nil { try await Task.sleep(for: .milliseconds(20)) }
        let editor = try XCTUnwrap(store.editor)

        store.toggleMarkdownTask(in: editor, line: 3, checked: true)
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), "# Plan\n\n- [x] one\n- [ ] two\n")
        XCTAssertFalse(editor.isDirty)

        let textView = try XCTUnwrap(editor.controller?.textView)
        textView.insertText("Draft ", replacementRange: NSRange(location: 2, length: 0))
        store.toggleMarkdownTask(in: editor, line: 4, checked: true)
        XCTAssertEqual(textView.string, "# Draft Plan\n\n- [x] one\n- [x] two\n")
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), "# Plan\n\n- [x] one\n- [ ] two\n",
                       "unsaved edits aren't saved behind the user's back")
        try editor.save() // leave the tab clean so closing it doesn't prompt
    }
}
