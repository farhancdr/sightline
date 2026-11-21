import AppKit
import XCTest
@testable import Sightline

@MainActor
final class MultiCursorTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        super.tearDown()
    }

    private func makeView(_ text: String) -> CodeTextView {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 300), styleMask: [.titled],
                              backing: .buffered, defer: false)
        windows.append(window)
        let view = CodeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 300))
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.allowsUndo = true
        view.isRichText = false
        view.string = text
        view.cursorPasteboard = NSPasteboard(name: NSPasteboard.Name("sightline-test-\(UUID().uuidString)"))
        window.contentView?.addSubview(view)
        window.makeFirstResponder(view)
        return view
    }

    private func type(_ text: String, in view: CodeTextView) {
        view.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func heads(_ view: CodeTextView) -> [Int] { view.allCursors.map(\.head) }

    func testNormalizedMergesOverlapsAndKeepsPrimary() {
        let (merged, primary) = TextCursor.normalized(
            [TextCursor(caret: 10), TextCursor(2, 6), TextCursor(caret: 6), TextCursor(4, 8), TextCursor(caret: 10)],
            primary: TextCursor(caret: 10))
        XCTAssertEqual(merged, [TextCursor(2, 8), TextCursor(caret: 10)])
        XCTAssertEqual(primary, 1)
    }

    func testCommandDSelectsWordThenWholeWordOccurrencesAndTypesAtAll() throws {
        let view = makeView("foo bar foo foobar foo")
        view.setSelectedRange(NSRange(location: 1, length: 0))
        view.addNextOccurrence(nil)
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 3), "first ⌘D selects the word")
        XCTAssertFalse(view.isMultiCursor)
        view.addNextOccurrence(nil)
        view.addNextOccurrence(nil) // skips the "foo" inside "foobar" (whole word, started from a caret)
        XCTAssertEqual(view.cursors.map(\.range.location), [0, 8, 19])
        XCTAssertEqual(view.selectedRange(), NSRange(location: 19, length: 3), "native selection follows the newest")

        type("x", in: view)
        XCTAssertEqual(view.string, "x bar x foobar x")
        XCTAssertEqual(heads(view), [1, 7, 16])
        type("y", in: view)
        XCTAssertEqual(view.string, "xy bar xy foobar xy")

        let undo = try XCTUnwrap(view.undoManager)
        while undo.canUndo { undo.undo() }
        XCTAssertEqual(view.string, "foo bar foo foobar foo")
        XCTAssertFalse(view.isMultiCursor, "undo collapses to one cursor")
    }

    func testCommandDFromSelectionMatchesInsideWords() {
        let view = makeView("foo foobar")
        view.setSelectedRange(NSRange(location: 0, length: 3))
        view.addNextOccurrence(nil)
        XCTAssertEqual(view.cursors.map(\.range), [NSRange(location: 0, length: 3), NSRange(location: 4, length: 3)])
        view.addNextOccurrence(nil) // wraps around, nothing new
        XCTAssertEqual(view.cursors.count, 2)
    }

    func testSelectAllOccurrences() {
        let view = makeView("let a = item; item.id; items")
        view.setSelectedRange(NSRange(location: 10, length: 0)) // inside "item"
        view.selectAllOccurrences(nil)
        XCTAssertEqual(view.cursors.map(\.range.location), [8, 14], "whole word: not 'items'")
        type("row", in: view)
        XCTAssertEqual(view.string, "let a = row; row.id; items")
    }

    func testAddCursorBelowAndDeleteBackward() {
        let view = makeView("abc\nde\nfghij")
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.addCursorBelow(nil)
        view.addCursorBelow(nil)
        XCTAssertEqual(heads(view), [2, 6, 9], "same column, clamped to the short line")
        view.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(view.string, "ac\nd\nfhij")
        view.addCursorAbove(nil) // the topmost cursor is on the first line: nothing above it
        XCTAssertEqual(view.cursors.count, 3)
    }

    func testNewlineKeepsIndentAtEveryCursor() {
        let view = makeView("  a\n    b")
        view.setCursors([TextCursor(caret: 3), TextCursor(caret: 9)])
        view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertEqual(view.string, "  a\n  \n    b\n    ")
        XCTAssertEqual(heads(view), [6, 17])
    }

    func testMovesAndShiftExtend() {
        let view = makeView("alpha beta\ngamma delta")
        view.setCursors([TextCursor(caret: 0), TextCursor(caret: 11)])
        view.doCommand(by: #selector(NSResponder.moveWordRightAndModifySelection(_:)))
        XCTAssertEqual(view.cursors.map(\.range), [NSRange(location: 0, length: 5), NSRange(location: 11, length: 5)])
        type("X", in: view)
        XCTAssertEqual(view.string, "X beta\nX delta")
        view.doCommand(by: #selector(NSResponder.moveToEndOfLine(_:)))
        XCTAssertEqual(heads(view), [6, 14])
        view.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertFalse(view.isMultiCursor, "Esc collapses")
    }

    func testCopyAndPasteOneLinePerCursor() {
        let view = makeView("a1 b2 c3")
        view.setCursors([TextCursor(0, 2), TextCursor(3, 5), TextCursor(6, 8)])
        view.copy(nil)
        XCTAssertEqual(view.cursorPasteboard.string(forType: .string), "a1\nb2\nc3")
        view.cursorPasteboard.clearContents()
        view.cursorPasteboard.setString("x\ny\nz", forType: .string)
        view.paste(nil)
        XCTAssertEqual(view.string, "x y z")
    }

    func testClickingElsewhereCollapses() {
        let view = makeView("one two")
        view.setCursors([TextCursor(caret: 0), TextCursor(caret: 4)])
        XCTAssertTrue(view.isMultiCursor)
        view.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertFalse(view.isMultiCursor)
    }

    /// The cursor logic after AppKit's ⌥-click tracking. The tracking loop itself isn't driven here: it blocks
    /// waiting for a mouse-up, and a CI runner never delivers a synthetic one (the Release job hung on it).
    func testOptionClickAddsAndRemovesCarets() {
        let view = makeView("first line\nsecond line")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.finishOptionClick(before: view.allCursors, ranges: [NSRange(location: 13, length: 0)])
        XCTAssertEqual(heads(view), [0, 13])
        view.finishOptionClick(before: view.allCursors, ranges: [NSRange(location: 13, length: 0)])
        XCTAssertFalse(view.isMultiCursor, "⌥-clicking an existing caret removes it")
        XCTAssertEqual(view.selectedRange().location, 0)
        // ⌥-drag: AppKit's column selection (one range per line) becomes one cursor per line.
        view.finishOptionClick(before: view.allCursors, ranges: [NSRange(location: 0, length: 3), NSRange(location: 11, length: 3)])
        XCTAssertEqual(view.cursors.map(\.range), [NSRange(location: 0, length: 3), NSRange(location: 11, length: 3)])
    }
}
