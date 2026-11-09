import AppKit
import SwiftUI
import XCTest
@testable import Sightline

/// None of the panel lists may rubber-band. macOS springs a list back when you push past its end,
/// which in a dense list reads as the rows jumping; VS Code's panels stop dead instead.
///
/// SwiftUI's `ListCoreScrollView` re-enables elasticity on every layout pass, so what matters is
/// that it is off *during a scroll gesture*. These tests drive the same live-scroll notifications
/// AppKit posts while scrolling and check each list clamps itself.
@MainActor
final class ExplorerScrollTests: XCTestCase {
    func testFileTreeDoesNotRubberBand() async throws {
        let root = try await Self.makeWorkspace(repos: 1, files: 60)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = AppStore.shared
        await store.open(root: root)
        store.selectRepo(try XCTUnwrap(store.repos.first).id)
        store.panel = .files
        let explorer = try XCTUnwrap(store.explorer)

        try await Self.assertNoBounce(ExplorerView(store: store, explorer: explorer), name: "file tree")
        store.closeAllTabs()
    }

    func testChangesListDoesNotRubberBand() async throws {
        let root = try await Self.makeWorkspace(repos: 1, files: 60)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = AppStore.shared
        await store.open(root: root)
        store.selectRepo(try XCTUnwrap(store.repos.first).id)
        store.panel = .changes
        // The files are untracked, so they all show up as changes — once the status lands.
        for _ in 0..<100 where (store.selectedStatus?.files.count ?? 0) < 20 {
            try? await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertGreaterThan(store.selectedStatus?.files.count ?? 0, 20, "no changes to scroll through")

        try await Self.assertNoBounce(RepoPanel(store: store), name: "changes list")
        store.closeAllTabs()
    }

    func testRepoSidebarDoesNotRubberBand() async throws {
        let root = try await Self.makeWorkspace(repos: 12, files: 1)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = AppStore.shared
        await store.open(root: root)
        XCTAssertGreaterThan(store.repos.count, 8, "not enough repos to scroll")

        try await Self.assertNoBounce(SidebarView(store: store), name: "repo sidebar", height: 220)
        store.closeAllTabs()
    }

    // MARK: Helpers

    /// A workspace of `repos` git repos, each holding `files` untracked files.
    private static func makeWorkspace(repos: Int, files: Int) async throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sightline-bounce-\(UUID().uuidString)").path
        for repo in 0..<repos {
            let path = "\(root)/repo-\(repo)"
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            _ = try await Git.run(["init", "-q"], in: path)
            for file in 0..<files {
                try "\(file)\n".write(toFile: "\(path)/file-\(file).md", atomically: true, encoding: .utf8)
            }
        }
        return root
    }

    /// Hosts `view` in a real window, checks its list is long enough to scroll, then drives the
    /// notifications AppKit posts during a scroll gesture and asserts elasticity stays off —
    /// including after SwiftUI re-enables it mid-gesture, which is what a layout pass does.
    private static func assertNoBounce(
        _ view: some View,
        name: String,
        height: CGFloat = 400,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: height),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        defer { window.orderOut(nil) }
        let host = NSHostingView(rootView: view.frame(width: 320, height: height, alignment: .topLeading))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(500))
        host.layoutSubtreeIfNeeded()

        // A panel can hold more than one scroll view (the commit box is one); the list is the one
        // with the tallest content.
        let scrollView = try XCTUnwrap(
            scrollViews(in: host).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) },
            "\(name): no NSScrollView", file: file, line: line
        )
        let document = try XCTUnwrap(scrollView.documentView, "\(name): no document view", file: file, line: line)
        XCTAssertGreaterThan(
            document.frame.height, scrollView.contentView.bounds.height,
            "\(name): the list does not scroll, so the test proves nothing", file: file, line: line
        )

        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(scrollView.verticalScrollElasticity, .none, "\(name) rubber-bands", file: file, line: line)

        scrollView.verticalScrollElasticity = .allowed
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(
            scrollView.verticalScrollElasticity, .none,
            "\(name): elasticity came back mid-scroll", file: file, line: line
        )
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        if let scrollView = view as? NSScrollView { found.append(scrollView) }
        for subview in view.subviews { found += scrollViews(in: subview) }
        return found
    }
}
