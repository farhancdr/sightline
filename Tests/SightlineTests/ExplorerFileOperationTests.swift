import AppKit
import SwiftUI
import XCTest
@testable import Sightline

final class ExplorerTransferTests: XCTestCase {
    private var dir = ""

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("sightline-transfer-\(UUID().uuidString)").path
        for folder in ["src/lib", "docs"] {
            try FileManager.default.createDirectory(atPath: "\(dir)/\(folder)", withIntermediateDirectories: true)
        }
        for file in ["a.txt", "src/b.txt", "src/lib/c.txt", "docs/a.txt"] {
            try file.write(toFile: "\(dir)/\(file)", atomically: true, encoding: .utf8)
        }
    }

    override func tearDown() { try? FileManager.default.removeItem(atPath: dir) }

    func testMovesFilesAndFolders() throws {
        let moved = try ExplorerModel.transfer(["\(dir)/src/b.txt", "\(dir)/src/lib"], into: "\(dir)/docs")
        XCTAssertEqual(moved.map(\.to), ["\(dir)/docs/b.txt", "\(dir)/docs/lib"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(dir)/docs/lib/c.txt"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "\(dir)/src/lib"))
    }

    func testRejectsMovingIntoItselfAndNameClashes() {
        XCTAssertThrowsError(try ExplorerModel.transfer(["\(dir)/src"], into: "\(dir)/src/lib"))
        XCTAssertThrowsError(try ExplorerModel.transfer(["\(dir)/a.txt"], into: "\(dir)/docs"), "docs/a.txt exists")
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(dir)/a.txt"), "nothing moved on error")
    }

    func testSkipsItemsAlreadyThereAndNestedSelections() throws {
        XCTAssertEqual(try ExplorerModel.transfer(["\(dir)/src/b.txt"], into: "\(dir)/src").count, 0)
        XCTAssertEqual(ExplorerModel.topLevel(["\(dir)/src", "\(dir)/src/b.txt", "\(dir)/a.txt"]), ["\(dir)/src", "\(dir)/a.txt"])
    }

    func testCopyLeavesTheOriginal() throws {
        try ExplorerModel.transfer(["\(dir)/src/b.txt"], into: "\(dir)/docs", copy: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(dir)/src/b.txt"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(dir)/docs/b.txt"))
    }
}

/// Click / ⇧-click / ⌘-click selection and ⌘⌫ (a real key event) in the explorer list.
@MainActor
final class ExplorerFileOperationTests: XCTestCase {
    private func makeRepo() async throws -> String {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sightline-explorer-ops-\(UUID().uuidString)").path
        let repo = "\(root)/app"
        try FileManager.default.createDirectory(atPath: "\(repo)/src", withIntermediateDirectories: true)
        _ = try await Git.run(["init", "-q"], in: repo)
        for file in ["a.go", "b.go", "c.go", "d.go", "src/main.go"] {
            try "package x\n".write(toFile: "\(repo)/\(file)", atomically: true, encoding: .utf8)
        }
        return root
    }

    func testShiftClickSelectsRangeAndCommandDeleteTrashesIt() async throws {
        let root = try await makeRepo()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = AppStore.shared
        await store.open(root: root)
        store.selectRepo(try XCTUnwrap(store.repos.first).id)
        store.panel = .files
        let explorer = try XCTUnwrap(store.explorer)
        var trashed: [String] = []
        let originalConfirm = store.confirmTrash, originalTrash = store.trashItem
        store.confirmTrash = { _, _ in true }
        store.trashItem = { url in trashed.append(url.path); try FileManager.default.removeItem(at: url) }
        defer { store.confirmTrash = originalConfirm; store.trashItem = originalTrash; store.closeAllTabs() }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let host = NSHostingView(rootView: ExplorerView(store: store, explorer: explorer))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(500))
        defer { window.orderOut(nil) }

        func table(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap(table).first
        }
        let list = try XCTUnwrap(table(host))
        let names = explorer.rows.map(\.node.name)
        XCTAssertEqual(names, ["src", "a.go", "b.go", "c.go", "d.go"])
        // The List hands its binding the new selection set; a test window can't take real clicks on the table
        // (it never becomes key), so drive the binding the way a click / ⇧-click / ⌘-click does.
        func path(_ name: String) -> String { "\(explorer.repo.path)/\(name)" }
        store.explorerSelectionChanged([path("a.go")], modifiers: [])
        XCTAssertEqual(explorer.selection, [path("a.go")])
        for _ in 0..<100 where store.editor == nil { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(store.editor?.path, path("a.go"), "a plain click opens the file")
        store.explorerSelectionChanged([path("a.go"), path("b.go"), path("c.go")], modifiers: .shift)
        XCTAssertEqual(explorer.orderedSelection, [path("a.go"), path("b.go"), path("c.go")])
        store.explorerSelectionChanged([path("a.go"), path("c.go")], modifiers: .command)
        XCTAssertEqual(explorer.orderedSelection, [path("a.go"), path("c.go")], "⌘-click toggles")
        store.explorerSelectionChanged([path("c.go")], modifiers: .command)
        XCTAssertEqual(store.editor?.path, path("a.go"), "⌘-click down to one row only selects, never opens")
        store.explorerSelectionChanged([path("a.go"), path("c.go")], modifiers: .command)

        // A test window never becomes key, so SwiftUI focus doesn't follow; give the table first responder and
        // report it focused, as ExplorerView does in the app.
        window.makeFirstResponder(list)
        store.explorerListFocused = true
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                 timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                 context: nil, characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}",
                                                 isARepeat: false, keyCode: 51))
        NSApp.sendEvent(key) // through the app, where the local key monitor sees it
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(trashed.map { ($0 as NSString).lastPathComponent }, ["a.go", "c.go"])
        XCTAssertEqual(explorer.rows.map(\.node.name), ["src", "b.go", "d.go"])
    }

    func testMovingAnOpenFileReopensItsTab() async throws {
        let root = try await makeRepo()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = AppStore.shared
        await store.open(root: root)
        let repo = try XCTUnwrap(store.repos.first)
        store.selectRepo(repo.id)
        store.panel = .files
        defer { store.closeAllTabs() }
        store.openInEditor(repoRelativePath: "a.go", preview: false)
        for _ in 0..<100 where store.editor == nil { try? await Task.sleep(for: .milliseconds(20)) }

        store.moveExplorerItems(["\(repo.path)/a.go"], into: "\(repo.path)/src")
        for _ in 0..<100 where store.editor?.path != "\(repo.path)/src/a.go" { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(store.editor?.path, "\(repo.path)/src/a.go")
        XCTAssertFalse(store.tabList.contains("\(repo.path)/a.go"))
        XCTAssertEqual(store.explorer?.selection, ["\(repo.path)/src/a.go"])

        // Unsaved edits block the move.
        store.editor?.controller?.textView.insertText("// x", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(store.editor?.isDirty ?? false)
        store.moveExplorerItems(["\(repo.path)/src/a.go"], into: repo.path)
        XCTAssertNotNil(store.errorMessage)
        store.errorMessage = nil
        XCTAssertTrue(FileManager.default.fileExists(atPath: "\(repo.path)/src/a.go"))
        try store.editor?.save() // temp repo; leaves the tab clean so closing it doesn't prompt
    }

    func testDropMovesTheWholeSelectionAndCopiesOutsideFiles() async throws {
        let root = try await makeRepo()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let store = AppStore.shared
        await store.open(root: root)
        let repo = try XCTUnwrap(store.repos.first)
        store.selectRepo(repo.id)
        store.panel = .files
        let explorer = try XCTUnwrap(store.explorer)

        explorer.setSelection(["\(repo.path)/a.go", "\(repo.path)/b.go"])
        store.beginExplorerDrag("\(repo.path)/b.go") // grabbed one row of the selection
        store.dropOnExplorer(urls: [URL(fileURLWithPath: "\(repo.path)/b.go")], into: "\(repo.path)/src")
        XCTAssertNil(store.errorMessage)
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: "\(repo.path)/src/a.go") && fm.fileExists(atPath: "\(repo.path)/src/b.go"))
        XCTAssertFalse(fm.fileExists(atPath: "\(repo.path)/a.go"))
        XCTAssertTrue(explorer.expanded.contains("\(repo.path)/src"), "the target folder opens to show what moved")

        let outside = "\(root)/notes.txt"
        try "hi\n".write(toFile: outside, atomically: true, encoding: .utf8)
        store.dropOnExplorer(urls: [URL(fileURLWithPath: outside)], into: repo.path)
        XCTAssertTrue(fm.fileExists(atPath: outside), "dropped from outside: copied, not moved")
        XCTAssertTrue(fm.fileExists(atPath: "\(repo.path)/notes.txt"))
        store.closeAllTabs()
    }
}
