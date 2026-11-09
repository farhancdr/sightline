import XCTest
@testable import Sightline

/// `FileWatcher.isRelevant` matches raw UTF-8 instead of Foundation's locale-aware `contains` /
/// `range(of:)` because it runs over whole FSEvents batches on the main queue. These tests pin the
/// behaviour to the Foundation version it replaced, so the speed-up cannot quietly change which
/// paths trigger a refresh.
final class FileWatcherRelevanceTests: XCTestCase {
    /// The implementation this replaced, kept as the oracle.
    private static func reference(_ path: String) -> Bool {
        if path.contains("/node_modules/") || path.contains("/.build/") || path.contains("/.swiftpm/")
            || path.hasSuffix("/.DS_Store") { return false }
        guard let gitRange = path.range(of: "/.git/") else {
            return !path.hasSuffix("/.git")
        }
        let inside = path[gitRange.upperBound...]
        if inside.hasSuffix(".lock") { return false }
        let first = inside.split(separator: "/").first.map(String.init) ?? ""
        return ["HEAD", "index", "refs", "packed-refs", "MERGE_HEAD", "REBASE_HEAD", "CHERRY_PICK_HEAD"]
            .contains(first)
    }

    func testMatchesTheReferenceImplementation() {
        for path in Self.corpus {
            XCTAssertEqual(
                FileWatcher.isRelevant(path), Self.reference(path),
                "disagreed on \(path.isEmpty ? "<empty>" : path)"
            )
        }
    }

    func testKnownCases() {
        for path in ["/r/src/a.ts", "/r/.git/index", "/r/.git/HEAD", "/r/.git/refs/heads/main",
                     "/r/.git/packed-refs", "/r/.git/MERGE_HEAD", "/r/.git/REBASE_HEAD",
                     "/r/.git/CHERRY_PICK_HEAD", "/r/a/.gitignore", "/r/build/out.o"] {
            XCTAssertTrue(FileWatcher.isRelevant(path), "should trigger a refresh: \(path)")
        }
        for path in ["/r/.git/index.lock", "/r/.git/objects/ab/cdef", "/r/.git/logs/HEAD",
                     "/r/node_modules/x/index.js", "/r/.build/debug/app", "/r/.swiftpm/x",
                     "/r/src/.DS_Store", "/r/.git", "/r/.git/", "/r/.git/HEADS"] {
            XCTAssertFalse(FileWatcher.isRelevant(path), "should be ignored: \(path)")
        }
    }

    /// Non-ASCII paths are legal and must not confuse byte-wise matching.
    func testUnicodePaths() {
        XCTAssertTrue(FileWatcher.isRelevant("/répertoire/日本語/ファイル.swift"))
        XCTAssertTrue(FileWatcher.isRelevant("/répertoire/🙂/.git/HEAD"))
        XCTAssertFalse(FileWatcher.isRelevant("/répertoire/node_modules/日本語/a.js"))
        for path in ["/répertoire/日本語/ファイル.swift", "/répertoire/🙂/.git/HEAD",
                     "/répertoire/node_modules/日本語/a.js", "/🙂/.git/refs/heads/branché"] {
            XCTAssertEqual(FileWatcher.isRelevant(path), Self.reference(path), "disagreed on \(path)")
        }
    }

    func testEdgeCases() {
        for path in ["", "/", ".git", "/.git", "/.git/", "/.git/HEAD", "//.git//HEAD",
                     "/a/.git/.git/HEAD", "/node_modules/a.js", "/a/node_modules", "/.DS_Store"] {
            XCTAssertEqual(
                FileWatcher.isRelevant(path), Self.reference(path),
                "disagreed on \(path.isEmpty ? "<empty>" : path)"
            )
        }
    }

    /// Every shape the watcher actually sees, crossed with the prefixes and suffixes that decide it.
    private static let corpus: [String] = {
        let roots = ["/w/repo", "/w/nested/deep/repo", "/w/repo/node_modules/pkg", "/w/repo/.build",
                     "/w/repo/.swiftpm/xcode", "/w/répertoire"]
        let tails = ["src/main.swift", "a.ts", ".DS_Store", ".gitignore", "dist/bundle.js.map",
                     ".git/index", ".git/index.lock", ".git/HEAD", ".git/HEADS", ".git/refs/heads/main",
                     ".git/refs/remotes/origin/main.lock", ".git/packed-refs", ".git/MERGE_HEAD",
                     ".git/REBASE_HEAD", ".git/CHERRY_PICK_HEAD", ".git/objects/ab/cdef",
                     ".git/logs/HEAD", ".git/config", ".git", ".git/", "", "node_modules/x/y.js"]
        var paths: [String] = []
        for root in roots {
            for tail in tails { paths.append(tail.isEmpty ? root : "\(root)/\(tail)") }
        }
        return paths
    }()
}
