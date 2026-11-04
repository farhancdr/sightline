import XCTest
@testable import Sightline

final class StatusParserTests: XCTestCase {
    func testBranchHeadersAndEntries() {
        let output = [
            "# branch.oid 1234567890abcdef",
            "# branch.head feature/checkout-redesign",
            "# branch.upstream origin/feature/checkout-redesign",
            "# branch.ab +2 -3",
            "1 M. N... 100644 100644 100644 aaa bbb src/staged file.ts",
            "1 .M N... 100644 100644 100644 aaa bbb src/unstaged.ts",
            "1 MM N... 100644 100644 100644 aaa bbb both.ts",
            "2 R. N... 100644 100644 100644 aaa bbb R100 new name.ts",
            "old name.ts",
            "u UU N... 100644 100644 100644 100644 aaa bbb ccc conflict.ts",
            "? new dir/untracked.txt",
            "",
        ].joined(separator: "\0")

        let status = StatusParser.parse(output)

        XCTAssertEqual(status.branch, "feature/checkout-redesign")
        XCTAssertEqual(status.upstream, "origin/feature/checkout-redesign")
        XCTAssertEqual(status.ahead, 2)
        XCTAssertEqual(status.behind, 3)
        XCTAssertEqual(status.files(in: .staged).map(\.path), ["src/staged file.ts", "both.ts", "new name.ts"])
        XCTAssertEqual(status.files(in: .unstaged).map(\.path), ["src/unstaged.ts", "both.ts"])
        XCTAssertEqual(status.files(in: .staged).last?.originalPath, "old name.ts")
        XCTAssertEqual(status.files(in: .conflicted).map(\.path), ["conflict.ts"])
        XCTAssertEqual(status.files(in: .untracked).map(\.path), ["new dir/untracked.txt"])
        XCTAssertEqual(status.changedCount, 6)
    }

    func testChangesSectionMergesUntrackedSortedByPath() {
        let output = [
            "1 .M N... 100644 100644 100644 a b src/services/OrderService.ts",
            "1 .M N... 100644 100644 100644 a b src/services/PaymentService.ts",
            "1 .M N... 100644 100644 100644 a b test/e2e/refund-order.ts",
            "? src/utils/coupon-utils.ts",
            "",
        ].joined(separator: "\0")
        let status = StatusParser.parse(output)
        XCTAssertEqual(status.sectionFiles(.unstaged).map(\.path), [
            "src/services/OrderService.ts",
            "src/services/PaymentService.ts",
            "src/utils/coupon-utils.ts",
            "test/e2e/refund-order.ts",
        ])
        XCTAssertEqual(status.sectionFiles(.unstaged)[2].code, "?")
        let added = DiffDocument.build(from: "@@ -0,0 +1,1 @@\n+x\n", path: "n.ts", rowLimit: nil)
        XCTAssertTrue(added.isOneSided)
    }

    func testDetachedHead() {
        let status = StatusParser.parse("# branch.oid abcdef1234\0# branch.head (detached)\0")
        XCTAssertNil(status.branch)
        XCTAssertEqual(status.headLabel, "detached @ abcdef1")
    }

    func testWatcherRelevance() {
        XCTAssertTrue(FileWatcher.isRelevant("/r/src/a.ts"))
        XCTAssertTrue(FileWatcher.isRelevant("/r/.git/index"))
        XCTAssertTrue(FileWatcher.isRelevant("/r/.git/HEAD"))
        XCTAssertTrue(FileWatcher.isRelevant("/r/.git/refs/heads/main"))
        XCTAssertFalse(FileWatcher.isRelevant("/r/.git/index.lock"))
        XCTAssertFalse(FileWatcher.isRelevant("/r/.git/objects/ab/cdef"))
        XCTAssertFalse(FileWatcher.isRelevant("/r/node_modules/x/index.js"))
    }

    func testSideBySideAlignment() {
        let raw = """
        diff --git a/a.ts b/a.ts
        --- a/a.ts
        +++ b/a.ts
        @@ -1,6 +1,5 @@
         const a = 1;
        -const fontFamily = x || y;
        -theme.style = fontFamily;
        -return codes;
        +return apply(codes, x);
         }
        @@ -20,2 +19,3 @@
         tail();
        +added();
         end();
        """
        let doc = DiffDocument.build(from: raw, path: "a.ts", rowLimit: nil)
        XCTAssertNil(doc.message)
        XCTAssertEqual(doc.additions, 2)
        XCTAssertEqual(doc.deletions, 3)
        // Both columns always have the same number of rows.
        XCTAssertEqual(doc.left.kinds.count, doc.right.kinds.count)
        XCTAssertEqual(doc.left.kinds, [.context, .removed, .removed, .removed, .context, .separator, .context, .filler, .context])
        XCTAssertEqual(doc.right.kinds, [.context, .added, .filler, .filler, .context, .separator, .context, .added, .context])
        XCTAssertEqual(doc.left.labels, ["1", "2", "3", "4", "5", "", "20", "", "21"])
        XCTAssertEqual(doc.right.labels, ["1", "2", "", "", "3", "", "19", "20", "21"])
        XCTAssertEqual(doc.changeRows, [1, 7])
        XCTAssertTrue(doc.left.text.string.contains("⋯ 14 unchanged lines"))
        // Inline: removed block then added block, old/new numbers in the gutter.
        XCTAssertEqual(doc.inline.kinds.prefix(6), [.context, .removed, .removed, .removed, .added, .context])
        XCTAssertEqual(doc.inline.labels[1].trimmingCharacters(in: .whitespaces), "2")
    }

    func testChangedCharacterRange() {
        let pair = DiffDocument.changedRanges("const x = foo(a);", "const x = bar(a);")
        XCTAssertEqual(pair?.0, NSRange(location: 10, length: 3))
        XCTAssertEqual(pair?.1, NSRange(location: 10, length: 3))
        XCTAssertNil(DiffDocument.changedRanges("abc", "xyz"))
    }

    func testNewFileAndBinary() {
        let added = DiffDocument.build(from: "@@ -0,0 +1,2 @@\n+one\n+two\n", path: "n.txt", rowLimit: nil)
        XCTAssertEqual(added.left.kinds, [.filler, .filler])
        XCTAssertEqual(added.right.kinds, [.added, .added])
        let binary = DiffDocument.build(from: "diff --git a/x b/x\nBinary files a/x and b/x differ\n", path: "x", rowLimit: nil)
        XCTAssertEqual(binary.message, "Binary file changed")
    }

    func testExplorerListsDirsFirstAndHidesGit() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sightline-ex-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        for dir in [".git", "src", "Zeta"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        for file in ["b.txt", "a.txt", ".env", "src/x.ts"] {
            fm.createFile(atPath: root.appendingPathComponent(file).path, contents: Data("x".utf8))
        }
        let nodes = ExplorerModel.list(root.path, repoPath: root.path)
        XCTAssertEqual(nodes.map(\.name), ["src", "Zeta", ".env", "a.txt", "b.txt"])
        let src = ExplorerModel.list(root.path + "/src", repoPath: root.path)
        XCTAssertEqual(src.map(\.relativePath), ["src/x.ts"])
    }

    func testFileDocumentGutterAndBinary() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
        let text = dir.appendingPathComponent("fg-\(UUID().uuidString).txt")
        let binary = dir.appendingPathComponent("fg-\(UUID().uuidString).bin")
        defer { try? fm.removeItem(at: text); try? fm.removeItem(at: binary) }
        try Data("one\ntwo\n".utf8).write(to: text)
        try Data([0x89, 0x50, 0x00, 0x01]).write(to: binary)

        XCTAssertEqual(FileContent.load(path: text.path).text, "one\ntwo\n")
        XCTAssertEqual(FileContent.load(path: binary.path).message, "Binary file")
    }

    func testScannerFindsNestedRepos() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sightline-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        for dir in [".git", "services/a/.git", "apps/ws/@studio/b/.git", "node_modules/c/.git"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        let repos = RepoScanner.scan(root: root.path)
        XCTAssertEqual(repos.map(\.relativePath), ["", "apps/ws/@studio/b", "services/a"])
        XCTAssertEqual(repos[1].group, "apps")
        XCTAssertEqual(repos[1].name, "ws/@studio/b")
    }
}
