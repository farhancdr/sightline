import XCTest
@testable import Sightline

final class HighlighterTests: XCTestCase {
    private func kinds(_ text: String, _ language: Language) -> [(String, TokenKind)] {
        let ns = text as NSString
        return SyntaxHighlighter.tokens(for: text, language: language).map { (ns.substring(with: $0.range), $0.kind) }
    }

    private func kind(of word: String, in text: String, _ language: Language) -> TokenKind? {
        kinds(text, language).first { $0.0 == word }?.1
    }

    func testTypeScript() {
        let src = """
        import { Foo } from './foo'; // comment
        const url = "https://x.io/a"; /* block */
        export async function run(n: number) { return n + 42; }
        @Injectable() class Bar {}
        """
        let tokens = kinds(src, .typescript)
        XCTAssertTrue(tokens.contains { $0 == ("import", .keyword) })
        XCTAssertTrue(tokens.contains { $0 == ("'./foo'", .string) })
        XCTAssertTrue(tokens.contains { $0 == ("// comment", .comment) })
        XCTAssertTrue(tokens.contains { $0 == ("\"https://x.io/a\"", .string) }, "// inside a string stays a string")
        XCTAssertTrue(tokens.contains { $0 == ("/* block */", .comment) })
        XCTAssertTrue(tokens.contains { $0 == ("run", .function) })
        XCTAssertTrue(tokens.contains { $0 == ("number", .type) })
        XCTAssertTrue(tokens.contains { $0 == ("42", .number) })
        XCTAssertTrue(tokens.contains { $0 == ("@Injectable", .attribute) })
        XCTAssertTrue(tokens.contains { $0 == ("Foo", .type) })
    }

    func testGoRawStringAndBuiltins() {
        let src = "func main() {\n\tx := `multi\nline` // c\n\tvar e error = nil\n}"
        let tokens = kinds(src, .go)
        XCTAssertTrue(tokens.contains { $0 == ("`multi\nline`", .string) })
        XCTAssertEqual(kind(of: "error", in: src, .go), .type)
        XCTAssertEqual(kind(of: "nil", in: src, .go), .constant)
        XCTAssertEqual(kind(of: "main", in: src, .go), .function)
    }

    func testRustLifetimeIsNotAString() {
        let src = "fn f<'a>(s: &'a str) -> char { 'x' }"
        let tokens = kinds(src, .rust)
        XCTAssertTrue(tokens.contains { $0 == ("'x'", .string) })
        XCTAssertFalse(tokens.contains { $0.1 == .string && $0.0.contains("a>") })
    }

    func testPythonTripleQuotesAndHashComment() {
        let src = "def f():\n    \"\"\"doc\n    string\"\"\"\n    return None  # done"
        let tokens = kinds(src, .python)
        XCTAssertTrue(tokens.contains { $0 == ("\"\"\"doc\n    string\"\"\"", .string) })
        XCTAssertTrue(tokens.contains { $0 == ("# done", .comment) })
        XCTAssertEqual(kind(of: "None", in: src, .python), .constant)
    }

    func testJsonYamlKeys() {
        XCTAssertTrue(kinds(#"{"name": "x", "n": 1, "ok": true}"#, .json).contains { $0 == ("\"name\"", .key) })
        XCTAssertTrue(kinds(#"{"name": "x"}"#, .json).contains { $0 == ("\"x\"", .string) })
        let yaml = "services:\n  - name: api\n    port: 8080 # p\n"
        let tokens = kinds(yaml, .yaml)
        XCTAssertTrue(tokens.contains { $0 == ("services", .key) })
        XCTAssertTrue(tokens.contains { $0 == ("name", .key) })
        XCTAssertTrue(tokens.contains { $0 == ("8080", .number) })
        XCTAssertTrue(tokens.contains { $0 == ("# p", .comment) })
    }

    func testShellVariablesAndDollarHashIsNotComment() {
        let src = "echo \"$HOME\" ${FOO} $# # real comment"
        let tokens = kinds(src, .shell)
        XCTAssertTrue(tokens.contains { $0 == ("${FOO}", .variable) })
        XCTAssertTrue(tokens.contains { $0 == ("# real comment", .comment) })
        XCTAssertFalse(tokens.contains { $0.1 == .comment && $0.0.hasPrefix("# #") })
    }

    func testMarkdown() {
        let src = "# Title\n\nSome `code` and **bold** [link](x.md)\n\n```ts\nconst a = 1\n```\n- item"
        let tokens = kinds(src, .markdown)
        XCTAssertTrue(tokens.contains { $0 == ("# Title", .heading) })
        XCTAssertTrue(tokens.contains { $0 == ("`code`", .code) })
        XCTAssertTrue(tokens.contains { $0 == ("**bold**", .emphasis) })
        XCTAssertTrue(tokens.contains { $0 == ("[link](x.md)", .link) })
        XCTAssertTrue(tokens.contains { $0.1 == .code && $0.0.hasPrefix("```ts") })
    }

    func testLanguageDetection() {
        XCTAssertEqual(Language.detect(path: "/a/b.tsx").name, "TypeScript")
        XCTAssertEqual(Language.detect(path: "/a/main.go").name, "Go")
        XCTAssertEqual(Language.detect(path: "/a/README.mdx").name, "Markdown")
        XCTAssertEqual(Language.detect(path: "/a/Dockerfile").name, "Dockerfile")
        XCTAssertEqual(Language.detect(path: "/a/.env.local").name, "Config")
        XCTAssertEqual(Language.detect(path: "/a/x.unknown").name, "Plain Text")
    }

    func testLargeFilePerformance() {
        let line = "export const value = compute(\"string // not comment\", 123) // trailing comment\n"
        let src = String(repeating: line, count: 10_000) // ~800 KB
        measure { _ = SyntaxHighlighter.tokens(for: src, language: .typescript) }
    }
}

final class QuickOpenTests: XCTestCase {
    private let repo = Repo(path: "/w/services/user-service", relativePath: "services/user-service")
    private let root = Repo(path: "/w", relativePath: "")

    func testRanking() {
        let entries = [
            QuickOpenEntry(repo: repo, repoRelativePath: "src/users/UserService.ts"),
            QuickOpenEntry(repo: repo, repoRelativePath: "src/users/dto/CreateUserDto.ts"),
            QuickOpenEntry(repo: repo, repoRelativePath: "test/unit/UserServiceTest.ts"),
            QuickOpenEntry(repo: root, repoRelativePath: "docs/user-service.md"),
        ]
        let results = FileIndex.search("userservice", in: entries)
        XCTAssertEqual(results.first?.displayPath, "services/user-service/src/users/UserService.ts")
        XCTAssertEqual(FileIndex.search("cud", in: entries).first?.fileName, "CreateUserDto.ts")
        XCTAssertTrue(FileIndex.search("zzz", in: entries).isEmpty)
        XCTAssertEqual(entries[3].displayPath, "docs/user-service.md")
        XCTAssertEqual(entries[0].absolutePath, "/w/services/user-service/src/users/UserService.ts")
    }
}

final class RepoSortTests: XCTestCase {
    func testRecentRanking() {
        let a = Repo(path: "/w/services/a", relativePath: "services/a")
        let b = Repo(path: "/w/services/b", relativePath: "services/b")
        let c = Repo(path: "/w/apps/c", relativePath: "apps/c")
        let d = Repo(path: "/w/apps/d", relativePath: "apps/d")
        let ranked = AppStore.rankByRecent([a, b, c, d], lastOpened: [b.id: 50, c.id: 100, d.id: 200])
        // Most recently opened first; never-opened last, A–Z.
        XCTAssertEqual(ranked.map(\.relativePath), ["apps/d", "apps/c", "services/b", "services/a"])
    }
}

final class StagingTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("fg-git-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "t"]] {
            _ = try await Git.run(args, in: dir.path)
        }
        try "one\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        _ = try await Git.run(["add", "."], in: dir.path)
        _ = try await Git.run(["commit", "-q", "-m", "init"], in: dir.path)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    func testCommitRunsHooksAndNoVerifySkipsThem() async throws {
        let path = dir.path
        let hook = dir.appendingPathComponent(".git/hooks/pre-commit")
        try "#!/bin/sh\necho 'lint failed: hook blocked'\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try "two\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try await GitCommands.stage(path, paths: ["a.txt"])

        do {
            try await GitCommands.commit(path, message: "blocked", noVerify: false)
            XCTFail("pre-commit hook should block the commit")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("hook blocked"), error.localizedDescription)
        }
        try await GitCommands.commit(path, message: "chore: skip hooks\n\nbody line", noVerify: true)
        let log = try await Git.run(["log", "-1", "--format=%B"], in: path).output
        XCTAssertEqual(log.trimmingCharacters(in: .whitespacesAndNewlines), "chore: skip hooks\n\nbody line")
        let status = try await GitCommands.status(path)
        XCTAssertTrue(status.files(in: .staged).isEmpty)
    }

    func testLoginShellPathResolves() {
        let path = Git.loginShellPath
        XCTAssertNotNil(path)
        XCTAssertTrue(path?.contains("/usr/bin") ?? false)
    }

    func testStageUnstageDiscard() async throws {
        let path = dir.path
        try "two\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "new\n".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)

        var status = try await GitCommands.status(path)
        XCTAssertEqual(status.files(in: .unstaged).map(\.path), ["a.txt"])
        XCTAssertEqual(status.files(in: .untracked).map(\.path), ["b.txt"])

        try await GitCommands.stage(path, paths: ["a.txt", "b.txt"])
        status = try await GitCommands.status(path)
        XCTAssertEqual(Set(status.files(in: .staged).map(\.path)), ["a.txt", "b.txt"])

        try await GitCommands.unstage(path, files: status.files(in: .staged))
        status = try await GitCommands.status(path)
        XCTAssertTrue(status.files(in: .staged).isEmpty)

        try await GitCommands.discard(path, paths: ["a.txt"])
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("a.txt"), encoding: .utf8), "one\n")

        // Real git output with full-file context → aligned side-by-side rows.
        try "keep\nold line\nkeep2\n".write(to: dir.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        try await GitCommands.stage(path, paths: ["c.txt"])
        _ = try await Git.run(["commit", "-q", "-m", "c"], in: path)
        try "keep\nnew line\nkeep2\n".write(to: dir.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        let change = FileChange(path: "c.txt", originalPath: nil, area: .unstaged, code: "M")
        let raw = try await GitCommands.diff(path, file: change)
        let doc = DiffDocument.build(from: raw, path: "c.txt", rowLimit: nil)
        XCTAssertEqual(doc.left.kinds, [.context, .removed, .context])
        XCTAssertEqual(doc.right.kinds, [.context, .added, .context])
        XCTAssertEqual(doc.left.text.string, "keep\nold line\nkeep2\n")

        let files = try await GitCommands.listFiles(path)
        XCTAssertEqual(Set(files), ["a.txt", "b.txt", "c.txt"])
    }
}

final class LineReferenceTests: XCTestCase {
    @MainActor
    func testReferenceFromSelectionAndCaret() throws {
        let controller = EditorController(text: "one\ntwo\nthree\nfour\n", language: .plain)
        controller.referencePath = "services/api/src/a.ts"
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("sightline-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        controller.pasteboard = pasteboard
        var copied: String?
        controller.onReferenceCopied = { copied = $0 }

        // "two\nthree\n": ends right after a newline, so line 4 is not included.
        controller.textView.setSelectedRange(NSRange(location: 4, length: 10))
        controller.copyReference()
        XCTAssertEqual(copied, "services/api/src/a.ts:2-3")
        XCTAssertEqual(pasteboard.string(forType: .string), "services/api/src/a.ts:2-3")

        // Partial selection inside line 3 → single line.
        controller.textView.setSelectedRange(NSRange(location: 9, length: 2))
        controller.copyReference()
        XCTAssertEqual(copied, "services/api/src/a.ts:3")

        // Caret on line 4, and an explicit range from the gutter.
        controller.textView.setSelectedRange(NSRange(location: 15, length: 0))
        controller.copyReference()
        XCTAssertEqual(copied, "services/api/src/a.ts:4")
        controller.copyReference(7...12)
        XCTAssertEqual(copied, "services/api/src/a.ts:7-12")
    }
}

final class DiffReferenceTests: XCTestCase {
    private let raw = """
    @@ -1,6 +1,5 @@
     const a = 1;
    -const fontFamily = x || y;
    -theme.style = fontFamily;
    -return codes;
    +return apply(codes, x);
     }
    """

    @MainActor
    func testSelectionMapsToFileLinesPerSide() {
        let doc = DiffDocument.build(from: raw, path: "a.ts", rowLimit: nil)
        // Rows: 0 ctx(1|1) 1 rem(2)|add(2) 2 rem(3)|filler 3 rem(4)|filler 4 ctx(5|3)
        let right = DiffColumn()
        right.show(doc.right)
        let rightText = doc.right.text.string as NSString
        // Caret on row 4 → new-file line 3.
        right.textView.setSelectedRange(NSRange(location: doc.right.rowStarts[4], length: 0))
        XCTAssertEqual(right.selectedLineRange(), 3...3)
        // Rows 1-4 selected: fillers skipped → lines 2-3.
        right.textView.setSelectedRange(NSRange(location: doc.right.rowStarts[1], length: rightText.length - doc.right.rowStarts[1] - 1))
        XCTAssertEqual(right.selectedLineRange(), 2...3)
        // Caret on a filler row → nothing to copy.
        right.textView.setSelectedRange(NSRange(location: doc.right.rowStarts[2], length: 0))
        XCTAssertNil(right.selectedLineRange())

        let left = DiffColumn()
        left.show(doc.left)
        // Rows 1-3 on the old side (ends right after the newline of row 3) → old lines 2-4.
        left.textView.setSelectedRange(NSRange(location: doc.left.rowStarts[1], length: doc.left.rowStarts[4] - doc.left.rowStarts[1]))
        XCTAssertEqual(left.selectedLineRange(), 2...4)

        // Inline uses new-file numbers (old for removed lines).
        XCTAssertEqual(doc.inline.numbers, [1, 2, 3, 4, 2, 3])
        XCTAssertEqual(EditorController.reference(path: "services/x/a.ts", lines: 2...3), "services/x/a.ts:2-3")
    }

    func testOverviewRuns() {
        let kinds: [DiffRowKind] = [.context, .removed, .removed, .context, .removed, .added]
        let runs = DiffOverviewRuler.runs(kinds, kind: .removed, color: .red, lane: 1)
        XCTAssertEqual(runs.map { [$0.start, $0.end] }, [[1, 3], [4, 5]])
    }
}

final class SyncTests: XCTestCase {
    private var base: URL!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("sightline-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: base) }

    private func makeClone(_ name: String, remote: URL) async throws -> String {
        let path = base.appendingPathComponent(name).path
        _ = try await Git.run(["clone", "-q", remote.path, path], in: base.path)
        _ = try await Git.run(["config", "user.email", "t@t"], in: path)
        _ = try await Git.run(["config", "user.name", "t"], in: path)
        return path
    }

    private func commitFile(_ repo: String, _ name: String, _ text: String) async throws {
        try text.write(toFile: repo + "/" + name, atomically: true, encoding: .utf8)
        try await GitCommands.stage(repo, paths: [name])
        try await GitCommands.commit(repo, message: "add \(name)", noVerify: true)
    }

    func testPublishPushPullAndDivergence() async throws {
        let remote = base.appendingPathComponent("remote.git")
        _ = try await Git.run(["init", "-q", "--bare", "-b", "main", remote.path], in: base.path)

        // A: new local repo with a remote but no upstream yet → publish with -u.
        let a = base.appendingPathComponent("a").path
        _ = try await Git.run(["init", "-q", "-b", "main", a], in: base.path)
        _ = try await Git.run(["config", "user.email", "t@t"], in: a)
        _ = try await Git.run(["config", "user.name", "t"], in: a)
        _ = try await Git.run(["remote", "add", "origin", remote.path], in: a)
        try await commitFile(a, "one.txt", "1\n")
        var status = try await GitCommands.status(a)
        XCTAssertNil(status.upstream)
        try await GitCommands.push(a, hasUpstream: false)
        status = try await GitCommands.status(a)
        XCTAssertEqual(status.upstream, "origin/main")

        // B clones, A pushes again, B pulls (fast-forward).
        let b = try await makeClone("b", remote: remote)
        try await commitFile(a, "two.txt", "2\n")
        try await GitCommands.push(a, hasUpstream: true)
        try await GitCommands.pull(b)
        XCTAssertTrue(FileManager.default.fileExists(atPath: b + "/two.txt"))

        // Diverge: both commit; B's pull --ff-only must fail with git's message, not merge.
        try await commitFile(a, "three.txt", "3\n")
        try await GitCommands.push(a, hasUpstream: true)
        try await commitFile(b, "four.txt", "4\n")
        do {
            try await GitCommands.pull(b)
            XCTFail("diverged pull should fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.lowercased().contains("fast-forward"), error.localizedDescription)
        }
        let parents = try await Git.run(["log", "-1", "--format=%P"], in: b).output.split(separator: " ")
        XCTAssertEqual(parents.count, 1, "no merge commit was created")
    }

    func testStdinInputIsPassedToGit() async throws {
        let repo = base.appendingPathComponent("r").path
        _ = try await Git.run(["init", "-q", repo], in: base.path)
        let big = String(repeating: "line of text\n", count: 20_000) // > pipe buffer
        let hash = try await Git.run(["hash-object", "--stdin"], in: repo, input: Data(big.utf8)).output
        XCTAssertEqual(hash.trimmingCharacters(in: .whitespacesAndNewlines).count, 40)
    }
}

final class ReviewStateTests: XCTestCase {
    func testIndexHashParsed() {
        let status = StatusParser.parse("1 MM N... 100644 100644 100644 aaa bbb src/a.ts\0")
        XCTAssertEqual(status.files.map(\.indexHash), ["bbb", "bbb"])
    }

    func testFingerprintChangesWhenAgentEditsAgain() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sightline-review-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let repo = dir.path
        for args in [["init", "-q"], ["config", "user.email", "t@t"], ["config", "user.name", "t"]] {
            _ = try await Git.run(args, in: repo)
        }
        let file = dir.appendingPathComponent("a.txt")
        try "v1\n".write(to: file, atomically: true, encoding: .utf8)
        try await GitCommands.stage(repo, paths: ["a.txt"])
        try await GitCommands.commit(repo, message: "init", noVerify: true)

        // Agent edit #1 → reviewed fingerprint.
        try "v2\n".write(to: file, atomically: true, encoding: .utf8)
        let first = try await GitCommands.status(repo)
        let change = try XCTUnwrap(first.files.first)
        let marked = ReviewState.fingerprint(change, repoPath: repo)

        // Agent edit #2: git status is identical ("M a.txt") but the fingerprint must differ.
        try await Task.sleep(for: .milliseconds(20))
        try "v3 longer\n".write(to: file, atomically: true, encoding: .utf8)
        let second = try await GitCommands.status(repo)
        XCTAssertEqual(first, second, "porcelain status alone can't see the second edit")
        XCTAssertNotEqual(ReviewState.fingerprint(try XCTUnwrap(second.files.first), repoPath: repo), marked)

        // Staged entries fingerprint by index blob: restaging new content changes it.
        try await GitCommands.stage(repo, paths: ["a.txt"])
        let afterStage = try await GitCommands.status(repo)
        let staged = try XCTUnwrap(afterStage.files.first { $0.area == .staged })
        let stagedPrint = ReviewState.fingerprint(staged, repoPath: repo)
        try "v4\n".write(to: file, atomically: true, encoding: .utf8)
        try await GitCommands.stage(repo, paths: ["a.txt"])
        let afterRestage = try await GitCommands.status(repo)
        let restaged = try XCTUnwrap(afterRestage.files.first { $0.area == .staged })
        XCTAssertNotEqual(ReviewState.fingerprint(restaged, repoPath: repo), stagedPrint)
    }

    func testEditorURLs() {
        XCTAssertEqual(
            ExternalEditor.fileURL(scheme: "vscode", path: "/Users/me/my repo/a.ts", line: 42)?.absoluteString,
            "vscode://file/Users/me/my%20repo/a.ts:42"
        )
        XCTAssertEqual(ExternalEditor.fileURL(scheme: "cursor", path: "/x/b.go", line: nil)?.absoluteString, "cursor://file/x/b.go")
        XCTAssertEqual(DiffRows.nearestNumber(to: 1, in: [10, nil, nil, 11]), 11)
        XCTAssertEqual(DiffRows.nearestNumber(to: 3, in: [10, nil, nil, nil]), 10)
    }
}

final class HistoryTests: XCTestCase {
    func testParsers() {
        let record = ["abc123", "abc", "Jane Doe", "j@x.io", "1700000000", "p1 p2", "HEAD -> main, tag: v1",
                      "feat: weird | subject\twith tab"].joined(separator: "\u{1f}") + "\u{1e}\n"
        let commits = LogParser.parse(record + record.replacingOccurrences(of: "abc123", with: "def456"))
        XCTAssertEqual(commits.map(\.sha), ["abc123", "def456"])
        XCTAssertEqual(commits[0].subject, "feat: weird | subject\twith tab")
        XCTAssertEqual(commits[0].parents, ["p1", "p2"])
        XCTAssertTrue(commits[0].isMerge)
        XCTAssertEqual(commits[0].refs, ["HEAD -> main", "tag: v1"])

        let files = LogParser.parseNameStatus("M\0src/a.ts\0R087\0old/b.ts\0new/b.ts\0D\0gone.txt\0")
        XCTAssertEqual(files.map(\.path), ["src/a.ts", "new/b.ts", "gone.txt"])
        XCTAssertEqual(files[1].originalPath, "old/b.ts")
        XCTAssertEqual(files.map(\.code), ["M", "R", "D"])
    }

    func testRealRepoHistoryFilesAndDiffs() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sightline-history-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let repo = dir.path
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "Tess"]] {
            _ = try await Git.run(args, in: repo)
        }
        func write(_ name: String, _ text: String) throws {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("a.txt", "one\ntwo\nthree\n")
        try write("old/name.txt", "same content for rename detection\nline 2\nline 3\n")
        _ = try await Git.run(["add", "-A"], in: repo)
        try await GitCommands.commit(repo, message: "root commit", noVerify: true)
        try write("a.txt", "one\nTWO\nthree\n")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("new"), withIntermediateDirectories: true)
        _ = try await Git.run(["mv", "old/name.txt", "new/name.txt"], in: repo)
        _ = try await Git.run(["add", "-A"], in: repo)
        try await GitCommands.commit(repo, message: "edit | rename\n\nbody text", noVerify: true)

        let log = try await GitCommands.log(repo)
        XCTAssertEqual(log.map(\.subject), ["edit | rename", "root commit"])
        XCTAssertTrue(log[1].isRoot)
        XCTAssertEqual(log[0].author, "Tess")
        let message = try await GitCommands.message(repo, sha: log[0].sha)
        XCTAssertEqual(message, "edit | rename\n\nbody text")
        let unpushed = await GitCommands.unpushed(repo)
        XCTAssertTrue(unpushed.isEmpty, "no upstream → nothing reported")

        let files = try await GitCommands.commitFiles(repo, commit: log[0])
        XCTAssertEqual(Set(files.map(\.path)), ["a.txt", "new/name.txt"])
        XCTAssertEqual(files.first { $0.path == "new/name.txt" }?.originalPath, "old/name.txt")
        let a = try XCTUnwrap(files.first { $0.path == "a.txt" })
        let doc = DiffDocument.build(from: try await GitCommands.commitDiff(repo, commit: log[0], file: a), path: "a.txt", rowLimit: nil)
        XCTAssertEqual(doc.left.kinds, [.context, .removed, .context])
        XCTAssertEqual(doc.right.kinds, [.context, .added, .context])

        let rootFiles = try await GitCommands.commitFiles(repo, commit: log[1])
        XCTAssertEqual(Set(rootFiles.map(\.path)), ["a.txt", "old/name.txt"])
        let rootA = try XCTUnwrap(rootFiles.first { $0.path == "a.txt" })
        let rootDoc = DiffDocument.build(
            from: try await GitCommands.commitDiff(repo, commit: log[1], file: rootA), path: "a.txt", rowLimit: nil
        )
        XCTAssertEqual(rootDoc.additions, 3)
        XCTAssertTrue(rootDoc.isOneSided)
    }
}

final class BlameTests: XCTestCase {
    private let a = String(repeating: "a", count: 40)
    private let zero = String(repeating: "0", count: 40)

    func testPorcelainParserWithRepeatedShaAndUncommittedLine() {
        let output = """
        \(a) 1 1 2
        author Ana
        author-mail <ana@x.io>
        author-time 1700000000
        summary First commit
        filename f.ts
        \tline one
        \(a) 2 2
        \tline two
        \(zero) 3 3 1
        author External file (--contents)
        author-mail <external.file>
        author-time 1700000500
        summary Version of f.ts from f.ts
        filename f.ts
        \tline three edited
        """
        let result = BlameParser.parse(output)
        XCTAssertEqual(result.lineCommits, [a, a, zero])
        XCTAssertEqual(result.commit(forLine: 1)?.author, "Ana")
        XCTAssertEqual(result.commit(forLine: 1)?.email, "ana@x.io")
        XCTAssertTrue(result.commit(forLine: 2)?.isUncommitted ?? false)
        XCTAssertNil(result.commit(forLine: 3))
    }

    func testAnnotationText() {
        let now = Date(timeIntervalSince1970: 1_700_000_000 + 3 * 86_400)
        let commit = BlameCommit(sha: a, author: "Ana", email: "ana@x.io",
                                 date: Date(timeIntervalSince1970: 1_700_000_000), summary: "Fix login redirect")
        XCTAssertEqual(EditorController.annotation(for: commit, userEmail: "someone@else", now: now),
                       "Ana, 3 days ago · Fix login redirect")
        XCTAssertTrue(EditorController.annotation(for: commit, userEmail: "ANA@x.io", now: now).hasPrefix("You, "))
        let uncommitted = BlameCommit(sha: zero, author: "", email: "", date: now, summary: "")
        XCTAssertEqual(EditorController.annotation(for: uncommitted, userEmail: nil), "You · Uncommitted changes")
    }

    func testRealBlameAgainstUnsavedBuffer() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sightline-blame-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let repo = dir.path
        for args in [["init", "-q"], ["config", "user.email", "ana@x.io"], ["config", "user.name", "Ana"]] {
            _ = try await Git.run(args, in: repo)
        }
        try "one\ntwo\nthree\n".write(to: dir.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try await GitCommands.stage(repo, paths: ["f.txt"])
        try await GitCommands.commit(repo, message: "add f", noVerify: true)

        // Unsaved buffer inserts a line at the top: committed lines must shift down, not misalign.
        let buffer = "NEW\none\ntwo\nthree\n"
        let blame = try await GitCommands.blame(repo, path: "f.txt", contents: buffer)
        XCTAssertEqual(blame.lineCommits.count, 4)
        XCTAssertTrue(blame.commit(forLine: 0)?.isUncommitted ?? false)
        XCTAssertEqual(blame.commit(forLine: 1)?.summary, "add f")
        XCTAssertEqual(blame.commit(forLine: 3)?.author, "Ana")
        let email = await GitCommands.userEmail(repo)
        XCTAssertEqual(email, "ana@x.io")
    }
}

final class TerminalSetupTests: XCTestCase {
    @MainActor
    func testFontAndMetalRenderer() throws {
        let font = TerminalManager.preferredFont(size: 12)
        print("TERMINAL_FONT \(font.familyName ?? "?") fixedPitch=\(font.isFixedPitch)")
        let installedNerd = NSFontManager.shared.availableFontFamilies.contains { $0.contains("Nerd Font") }
        if installedNerd { XCTAssertTrue(font.familyName?.contains("Nerd Font") ?? false) }

        let view = SwiftTermProbe.makeView()
        do { try view.setUseMetal(true) } catch { print("TERMINAL_METAL_ERROR \(error)") }
        print("TERMINAL_METAL \(view.isUsingMetalRenderer) status=\(view.metalRendererStatus.state)")
    }
}

import SwiftTerm
enum SwiftTermProbe {
    @MainActor static func makeView() -> TerminalView { TerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 300)) }
}

final class MarkdownRendererTests: XCTestCase {
    func testRenderingAndEscaping() {
        let md = """
        # Plan & Notes

        Use `Array<string>` when a < b && "c".

        - [x] done
        - [ ] todo

        | Name | Count |
        |:-----|------:|
        | a<b  | 2     |

        ```ts
        const x: Array<string> = []; // note
        ```

        ```diff
        - old line
        + new line
        ```

        <details><summary>More</summary>hidden</details>

        1. one
           - nested
        """
        let html = MarkdownRenderer.body(md)
        XCTAssertTrue(html.contains("<h1 id=\"plan--notes\">Plan &amp; Notes</h1>"), html)
        XCTAssertTrue(html.contains("<code>Array&lt;string&gt;</code>"))
        XCTAssertTrue(html.contains("a &lt; b &amp;&amp; &quot;c&quot;"))
        XCTAssertTrue(html.contains("<ul class=\"tasks\">"))
        XCTAssertTrue(html.contains("<input type=\"checkbox\" disabled checked> "))
        XCTAssertTrue(html.contains("<th align=\"left\">Name</th><th align=\"right\">Count</th>"))
        XCTAssertTrue(html.contains("<td align=\"left\">a&lt;b</td>"))
        XCTAssertTrue(html.contains("<span class=\"tok-keyword\">const</span>"))
        XCTAssertTrue(html.contains("Array&lt;string&gt;"))
        XCTAssertFalse(html.contains("Array<string>"), "code must be escaped")
        XCTAssertTrue(html.contains("<span class=\"tok-comment\">// note</span>"))
        XCTAssertTrue(html.contains("<span class=\"diff-del\">- old line</span><span class=\"diff-add\">+ new line</span>"))
        XCTAssertTrue(html.contains("<details><summary>More</summary>hidden</details>"))
        XCTAssertTrue(html.contains("<ol>") && html.contains("<ul>"), "nested lists")
    }

    func testPageWrapsBody() {
        let page = MarkdownPage.html(body: "<p>x</p>")
        XCTAssertTrue(page.contains("<article id=\"content\" class=\"markdown-body\"><p>x</p></article>"))
        XCTAssertTrue(page.contains("prefers-color-scheme: dark"))
    }
}

import WebKit

final class MermaidPreviewTests: XCTestCase {
    private final class LoadWaiter: NSObject, WKNavigationDelegate {
        var continuation: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume()
            continuation = nil
        }
    }

    @MainActor
    func testMermaidRendersInIsolatedWorldAndPageScriptsDoNot() async throws {
        let vendored = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Vendor/mermaid.min.js")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: vendored.path), "mermaid.min.js not vendored")
        MermaidSupport.sourceURLOverride = vendored
        defer { MermaidSupport.sourceURLOverride = nil }

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        MermaidSupport.userScripts().forEach(configuration.userContentController.addUserScript)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 700), configuration: configuration)
        let waiter = LoadWaiter()
        webView.navigationDelegate = waiter

        let markdown = """
        # Flow

        ```mermaid
        graph TD
          A[Agent edits] --> B{Reviewed?}
          B -->|yes| C[Commit]
        ```

        <script>document.documentElement.setAttribute('data-evil', '1')</script>
        """
        await withCheckedContinuation { continuation in
            waiter.continuation = continuation
            webView.loadHTMLString(MarkdownPage.html(body: MarkdownRenderer.body(markdown)), baseURL: nil)
        }

        var rendered = false
        for _ in 0..<100 {
            let result = try await webView.evaluateJavaScript(
                "document.querySelector('.mermaid-svg svg') !== null", contentWorld: .defaultClient
            )
            if (result as? Bool) == true { rendered = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(rendered, "mermaid diagram should be rendered to SVG")
        let evil = try await webView.evaluateJavaScript(
            "document.documentElement.getAttribute('data-evil')", contentWorld: .defaultClient
        )
        XCTAssertTrue(evil == nil || evil is NSNull, "page <script> must not run")
    }
}

final class WorkspaceSearchTests: XCTestCase {
    func testArgumentsAndGlobs() {
        var options = WorkspaceSearchOptions(exclude: "")
        let plain = WorkspaceSearch.grepArguments("foo", options: options)
        XCTAssertTrue(plain.contains("-F") && plain.contains("-i") && !plain.contains("-w"))
        XCTAssertEqual(Array(plain.suffix(3)), ["-e", "foo", "--"])
        options.matchCase = true
        options.wholeWord = true
        options.regex = true
        options.include = "*.ts, src/**"
        options.exclude = "*.spec.ts"
        let args = WorkspaceSearch.grepArguments("a\\d+", options: options)
        XCTAssertTrue(args.contains("-P") && args.contains("-w") && !args.contains("-i"))
        XCTAssertEqual(WorkspaceSearch.pathspecs(options), [":(glob)**/*.ts", ":(glob)src/**", ":(exclude,glob)**/*.spec.ts"])
        XCTAssertEqual(WorkspaceSearch.pathspecs(WorkspaceSearchOptions(exclude: "dist/**")), [".", ":(exclude,glob)dist/**"])
        XCTAssertEqual(WorkspaceSearch.pathspecs(WorkspaceSearchOptions()), [
            ".", ":(exclude,glob)**/node_modules", ":(exclude,glob)**/node_modules/**",
            ":(exclude,glob)**/dist", ":(exclude,glob)**/dist/**",
        ], "node_modules and dist are excluded by default, at any depth")
        XCTAssertFalse(WorkspaceSearchOptions().allRepos, "searches the selected repo by default")
    }

    func testPreviewTrimsAndRebasesRanges() throws {
        let regex = try WorkspaceSearch.highlightRegex("needle", options: WorkspaceSearchOptions())
        let (text, ranges) = WorkspaceSearch.preview("\t\t  let x = NEEDLE + needle", highlight: regex)
        XCTAssertEqual(text, "let x = NEEDLE + needle")
        XCTAssertEqual(ranges.map(\.location), [8, 17])
        let long = String(repeating: "x", count: 1000) + "needle" + String(repeating: "y", count: 1000)
        let (cut, cutRanges) = WorkspaceSearch.preview(long, highlight: regex)
        XCTAssertTrue(cut.hasPrefix("…"))
        XCTAssertEqual((cut as NSString).substring(with: try XCTUnwrap(cutRanges.first)), "needle")
    }

    func testRealSearchOptions() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sightline-search-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let repoDir = dir.appendingPathComponent("services/api")
        try FileManager.default.createDirectory(at: repoDir.appendingPathComponent("src"), withIntermediateDirectories: true)
        let repoPath = repoDir.path
        for args in [["init", "-q"], ["config", "user.email", "t@t"], ["config", "user.name", "t"]] {
            _ = try await Git.run(args, in: repoPath)
        }
        func write(_ name: String, _ text: String) throws {
            try text.write(to: repoDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try write("src/user.ts", "export function getUser(id: number) {}\nconst userCount = 42;\n// GetUser is here\n")
        try write("src/user.spec.ts", "getUser(1)\n")
        try write("src/odd:name.ts", "getUser in a weird file name\n")
        try write(".gitignore", "dist/\n")
        try FileManager.default.createDirectory(at: repoDir.appendingPathComponent("dist"), withIntermediateDirectories: true)
        try write("dist/bundle.js", "getUser compiled\n")
        _ = try await Git.run(["add", "src/user.ts", ".gitignore"], in: repoPath) // spec + odd file stay untracked

        let repo = Repo(path: repoPath, relativePath: "services/api")
        func run(_ query: String, _ options: WorkspaceSearchOptions = WorkspaceSearchOptions()) async -> SearchResults {
            await WorkspaceSearch.search(query, options: options, repos: [repo], root: dir.path)
        }

        var results = await run("getuser")
        XCTAssertEqual(Set(results.files.map(\.repoRelativePath)), ["src/user.ts", "src/user.spec.ts", "src/odd:name.ts"],
                       "case-insensitive, untracked included, ignored dist/ excluded")
        XCTAssertEqual(results.files.first { $0.repoRelativePath == "src/user.ts" }?.matches.map(\.line), [1, 3])
        XCTAssertEqual(results.files.first?.displayPath.hasPrefix("services/api/"), true)

        results = await run("getUser", WorkspaceSearchOptions(matchCase: true))
        XCTAssertEqual(results.files.first { $0.repoRelativePath == "src/user.ts" }?.matches.map(\.line), [1])

        results = await run("user", WorkspaceSearchOptions(wholeWord: true))
        XCTAssertEqual(results.matchCount, 0, "'user' only appears inside longer words")

        results = await run("Count = \\d+(?=;)", WorkspaceSearchOptions(regex: true))
        let match = try XCTUnwrap(results.files.first?.matches.first)
        XCTAssertEqual(match.line, 2)
        XCTAssertEqual((match.text as NSString).substring(with: try XCTUnwrap(match.ranges.first)), "Count = 42")

        results = await run("getUser", WorkspaceSearchOptions(exclude: "*.spec.ts"))
        XCTAssertFalse(results.files.contains { $0.repoRelativePath.hasSuffix(".spec.ts") })
        results = await run("getUser", WorkspaceSearchOptions(include: "*.spec.ts"))
        XCTAssertEqual(results.files.map(\.repoRelativePath), ["src/user.spec.ts"])

        // Committed (tracked) build output and vendored deps are still skipped by the default excludes.
        try FileManager.default.createDirectory(at: repoDir.appendingPathComponent("packages/ui/dist"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoDir.appendingPathComponent("node_modules/lib"), withIntermediateDirectories: true)
        try write("packages/ui/dist/index.js", "getUser bundled\n")
        try write("node_modules/lib/index.js", "getUser vendored\n")
        _ = try await Git.run(["add", "-f", "packages/ui/dist/index.js", "node_modules/lib/index.js"], in: repoPath)
        results = await run("getUser")
        XCTAssertFalse(results.files.contains { $0.repoRelativePath.contains("dist/") || $0.repoRelativePath.contains("node_modules/") })
        results = await run("getUser", WorkspaceSearchOptions(exclude: ""))
        XCTAssertTrue(results.files.contains { $0.repoRelativePath == "packages/ui/dist/index.js" })

        results = await run("(unclosed", WorkspaceSearchOptions(regex: true))
        XCTAssertEqual(results.error, "Invalid regular expression")
    }
}

final class CodeWordSelectionTests: XCTestCase {
    @MainActor
    func testDoubleClickSelectsIdentifierOnly() {
        let view = CodeTextView(frame: .zero)
        view.string = "x = await this.orderRepository.findOrdersWithItems(id, snake_case, $el);"
        let text = view.string as NSString
        func word(at needle: String, offset: Int = 2) -> String {
            let index = text.range(of: needle).location + offset
            let range = view.selectionRange(forProposedRange: NSRange(location: index, length: 0), granularity: .selectByWord)
            return text.substring(with: range)
        }
        XCTAssertEqual(word(at: "findOrdersWithItems"), "findOrdersWithItems")
        XCTAssertEqual(word(at: "orderRepository"), "orderRepository")
        XCTAssertEqual(word(at: "this"), "this")
        XCTAssertEqual(word(at: "snake_case"), "snake_case")
        XCTAssertEqual(word(at: "$el", offset: 0), "$el")

        // Double-click-drag from "orderRepository…" into "findOrders…" extends to both identifiers' bounds.
        let from = text.range(of: "orderRepository").location + 3
        let to = text.range(of: "findOrdersWithItems").location + 4
        let range = view.selectionRange(forProposedRange: NSRange(location: from, length: to - from), granularity: .selectByWord)
        XCTAssertEqual(text.substring(with: range), "orderRepository.findOrdersWithItems")
    }
}

final class CommandClickAndEditorTests: XCTestCase {
    func testLanguageGlobs() {
        XCTAssertEqual(AppStore.languageGlobs("/r/src/a.ts"), "*.ts, *.tsx, *.mts, *.cts")
        XCTAssertEqual(AppStore.languageGlobs("/r/App.TSX"), "*.ts, *.tsx, *.mts, *.cts")
        XCTAssertEqual(AppStore.languageGlobs("/r/main.go"), "*.go")
        XCTAssertEqual(AppStore.languageGlobs("/r/Makefile"), "")
    }

    func testEditorArguments() {
        XCTAssertEqual(
            ExternalEditor.cliArguments(style: .vscode, repo: "/w/svc", file: "/w/svc/src/a.ts", line: 12),
            ["/w/svc", "-g", "/w/svc/src/a.ts:12"]
        )
        XCTAssertEqual(ExternalEditor.cliArguments(style: .vscode, repo: "/w/svc", file: "/w/svc/a.ts", line: nil),
                       ["/w/svc", "/w/svc/a.ts"])
        XCTAssertEqual(ExternalEditor.cliArguments(style: .vscode, repo: "/w/svc", file: nil, line: nil), ["/w/svc"])
        XCTAssertEqual(ExternalEditor.cliArguments(style: .pathWithLine, repo: "/w/svc", file: "/w/svc/a.go", line: 3),
                       ["/w/svc", "/w/svc/a.go:3"])
    }

    @MainActor
    func testSearchSymbolSetsExactWordSearch() {
        let store = AppStore.shared
        store.searchSymbol("findOrdersWithItems", fromFile: "/w/svc/src/OrderService.ts")
        XCTAssertEqual(store.panel, .search)
        XCTAssertEqual(store.searchQuery, "findOrdersWithItems")
        XCTAssertTrue(store.searchOptions.matchCase && store.searchOptions.wholeWord && !store.searchOptions.regex)
        XCTAssertEqual(store.searchOptions.include, "*.ts, *.tsx, *.mts, *.cts")
        XCTAssertEqual(store.searchOptions.exclude, "node_modules, dist")
        XCTAssertFalse(store.searchOptions.allRepos)
    }

    @MainActor
    func testCommandClickReportsIdentifier() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        let view = CodeTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 200))
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.string = "x = await this.orderRepository.findOrdersWithItems(id);"
        window.contentView?.addSubview(view)
        var clicked: String?
        view.onCommandClick = { clicked = $0 }

        let text = view.string as NSString
        let layoutManager = try XCTUnwrap(view.layoutManager)
        let index = text.range(of: "findOrdersWithItems").location + 5
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        var rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: view.textContainer!)
        rect.origin.x += view.textContainerOrigin.x
        rect.origin.y += view.textContainerOrigin.y
        let pointInWindow = view.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: pointInWindow, modifierFlags: [.command, .capsLock], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        view.mouseDown(with: event)
        XCTAssertEqual(clicked, "findOrdersWithItems")
        XCTAssertEqual(text.substring(with: view.selectedRange()), "findOrdersWithItems")
    }
}
