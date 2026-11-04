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
