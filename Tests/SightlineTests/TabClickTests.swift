import SwiftUI
import XCTest
@testable import Sightline

@MainActor
/// Real mouse events on the tab bar (sent to an in-process window): clicking another repo's tab switches to it.
final class TabClickTests: XCTestCase {
    func testClickingOtherRepoTab() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sightline-tabclick-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        for name in ["alpha", "beta"] {
            try FileManager.default.createDirectory(atPath: "\(root)/\(name)", withIntermediateDirectories: true)
            _ = try await Git.run(["init", "-q"], in: "\(root)/\(name)")
            try "\(name)\n".write(toFile: "\(root)/\(name)/file.md", atomically: true, encoding: .utf8)
        }
        let store = AppStore.shared
        await store.open(root: root)
        let alpha = try XCTUnwrap(store.repos.first { $0.name == "alpha" })
        let beta = try XCTUnwrap(store.repos.first { $0.name == "beta" })
        store.selectRepo(beta.id)
        store.openInEditor(repoRelativePath: "file.md", preview: false)
        for _ in 0..<100 where store.editor == nil { try? await Task.sleep(for: .milliseconds(20)) }
        store.selectRepo(alpha.id)
        store.openInEditor(repoRelativePath: "file.md", preview: false)
        for _ in 0..<100 where store.editor?.path != alpha.path + "/file.md" { try? await Task.sleep(for: .milliseconds(20)) }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: EditorTabBar(store: store).frame(width: 700, height: 30, alignment: .topLeading))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))
        func click(_ x: CGFloat, count: Int = 1) async {
            let point = NSPoint(x: x, y: host.bounds.height - 15)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
                window.sendEvent(event)
            }
            try? await Task.sleep(for: .milliseconds(600))
        }
        func state() -> String { "selected=\(store.selectedRepo?.name ?? "-") active=\(store.tabList.active.map { ($0 as NSString).pathComponents.suffix(2).joined(separator: "/") } ?? "-")" }
        XCTAssertEqual(state(), "selected=alpha active=alpha/file.md")
        await click(40)  // first tab (beta)
        XCTAssertEqual(state(), "selected=beta active=beta/file.md")
        await click(180) // second tab (alpha)
        XCTAssertEqual(state(), "selected=alpha active=alpha/file.md")
        window.orderOut(nil)
        store.closeAllTabs()
    }
}


/// Same, inside the full window layout (sidebar, panels, editor, terminal): the tab bar's scroll view must not
/// be stretched under the toolbar, or its clickable content sits above where the tabs are drawn.
@MainActor
final class TabClickInWindowTests: XCTestCase {
    func testClickingTabsInFullLayout() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sightline-tabwin-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        for name in ["alpha", "beta"] {
            try FileManager.default.createDirectory(atPath: "\(root)/\(name)", withIntermediateDirectories: true)
            _ = try await Git.run(["init", "-q"], in: "\(root)/\(name)")
            try "\(name)\n".write(toFile: "\(root)/\(name)/file.go", atomically: true, encoding: .utf8)
        }
        let store = AppStore.shared
        await store.open(root: root)
        let alpha = try XCTUnwrap(store.repos.first { $0.name == "alpha" })
        let beta = try XCTUnwrap(store.repos.first { $0.name == "beta" })
        store.selectRepo(beta.id)
        store.openInEditor(repoRelativePath: "file.go", preview: false)
        for _ in 0..<100 where store.editor == nil { try? await Task.sleep(for: .milliseconds(20)) }
        store.selectRepo(alpha.id)
        store.openInEditor(repoRelativePath: "file.go", preview: false)
        for _ in 0..<100 where store.editor?.path != alpha.path + "/file.go" { try? await Task.sleep(for: .milliseconds(20)) }
        store.panel = .files

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 880),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: ContentView(store: store))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(800))
        defer { window.orderOut(nil); store.closeAllTabs() }

        func tabBar(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, scroll.hasHorizontalScroller == false,
               let doc = scroll.documentView, abs(doc.frame.height - 30) < 1 { return scroll }
            return view.subviews.lazy.compactMap(tabBar).first
        }
        let bar = try XCTUnwrap(tabBar(host))
        let frame = bar.convert(bar.bounds, to: nil)
        XCTAssertEqual(frame.height, 30, accuracy: 1, "tab bar scroll view stretched under the toolbar")
        let doc = try XCTUnwrap(bar.documentView).convert(bar.documentView!.bounds, to: nil)
        XCTAssertEqual(doc.minY, frame.minY, accuracy: 1)

        func click(x: CGFloat) async {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                window.sendEvent(NSEvent.mouseEvent(with: type, location: NSPoint(x: frame.minX + x, y: frame.midY), modifierFlags: [],
                                                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
        await click(x: 40) // beta's tab (opened first)
        XCTAssertEqual(store.selectedRepoID, beta.id)
        XCTAssertEqual(store.editor?.path, beta.path + "/file.go")
        await click(x: 180) // alpha's tab
        XCTAssertEqual(store.selectedRepoID, alpha.id)
        XCTAssertEqual(store.editor?.path, alpha.path + "/file.go")
    }
}
