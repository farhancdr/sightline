import AppKit
import SwiftUI
import XCTest
@testable import Sightline

/// The file tree must not rubber-band. macOS springs a list back when you push past its end, which
/// in a dense file tree reads as the rows jumping; VS Code's explorer stops dead instead.
///
/// SwiftUI's `ListCoreScrollView` re-enables elasticity on every layout pass, so what matters is
/// that it is off *during a scroll gesture*. The test drives the same live-scroll notifications
/// AppKit posts while scrolling and checks the list clamps itself.
@MainActor
final class ExplorerScrollTests: XCTestCase {
    func testFileTreeDisablesElasticityWhileScrolling() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sightline-elastic-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        let repo = "\(root)/alpha"
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        _ = try await Git.run(["init", "-q"], in: repo)
        // Enough rows that the list actually scrolls.
        for i in 0..<60 {
            try "\(i)\n".write(toFile: "\(repo)/file-\(i).md", atomically: true, encoding: .utf8)
        }

        let store = AppStore.shared
        await store.open(root: root)
        let alpha = try XCTUnwrap(store.repos.first { $0.name == "alpha" })
        store.selectRepo(alpha.id)
        store.panel = .files
        let explorer = try XCTUnwrap(store.explorer)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let host = NSHostingView(rootView: ExplorerView(store: store, explorer: explorer)
            .frame(width: 320, height: 400, alignment: .topLeading))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()

        let scrollView = try XCTUnwrap(Self.scrollViews(in: host).first, "no NSScrollView for the file tree")
        let document = try XCTUnwrap(scrollView.documentView)
        XCTAssertGreaterThan(document.frame.height, scrollView.contentView.bounds.height, "the list does not scroll")

        // AppKit posts this when a scroll gesture begins; elasticity must be off before it moves.
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(scrollView.verticalScrollElasticity, .none, "the file tree rubber-bands vertically")
        XCTAssertEqual(scrollView.horizontalScrollElasticity, .none, "the file tree rubber-bands horizontally")

        // SwiftUI re-enables it mid-gesture when the list lays out again; each scroll step must
        // clamp it back.
        scrollView.verticalScrollElasticity = .allowed
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(scrollView.verticalScrollElasticity, .none, "elasticity came back during the scroll")

        window.orderOut(nil)
        store.closeAllTabs()
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        if let scrollView = view as? NSScrollView { found.append(scrollView) }
        for subview in view.subviews { found += scrollViews(in: subview) }
        return found
    }
}
