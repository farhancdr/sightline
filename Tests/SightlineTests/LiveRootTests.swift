import XCTest
@testable import Sightline

/// Smoke test against a real workspace: `SIGHTLINE_ROOT=/path/to/root swift test --filter LiveRootTests`
final class LiveRootTests: XCTestCase {
    func testScanAndStatusEveryRepo() async throws {
        guard let root = ProcessInfo.processInfo.environment["SIGHTLINE_ROOT"] else {
            throw XCTSkip("SIGHTLINE_ROOT not set")
        }
        let start = Date()
        let repos = RepoScanner.scan(root: root)
        let scanTime = Date().timeIntervalSince(start)
        XCTAssertFalse(repos.isEmpty)

        var failures: [String] = []
        let statusStart = Date()
        for repo in repos {
            do {
                let status = try await GitCommands.status(repo.path)
                print("REPO \(repo.relativePath.isEmpty ? "." : repo.relativePath) | \(status.headLabel) | +\(status.ahead) -\(status.behind) | \(status.changedCount) changed")
            } catch {
                failures.append("\(repo.relativePath): \(error.localizedDescription)")
            }
        }
        print("SUMMARY repos=\(repos.count) scan=\(String(format: "%.2f", scanTime))s status=\(String(format: "%.2f", Date().timeIntervalSince(statusStart)))s")
        XCTAssertEqual(failures, [])

        // Quick-open index across all repos.
        let indexStart = Date()
        let index = await FileIndex.build(repos: repos)
        let indexTime = Date().timeIntervalSince(indexStart)
        let searchStart = Date()
        let hits = FileIndex.search("readme", in: index)
        print("INDEX files=\(index.count) build=\(String(format: "%.2f", indexTime))s search=\(String(format: "%.3f", Date().timeIntervalSince(searchStart)))s top=\(hits.prefix(3).map(\.displayPath))")
        XCTAssertFalse(index.isEmpty)
        for query in ["re", "readme", "service"] {
            let top = FileIndex.search(query, in: index).prefix(3).map(\.displayPath)
            print("QUERY \(query) -> \(top)")
        }

        // Diff + branches on the root repo.
        let rootRepo = try XCTUnwrap(repos.first)
        let branches = try await GitCommands.branches(rootRepo.path)
        XCTAssertTrue(branches.contains { $0.isCurrent })
        let status = try await GitCommands.status(rootRepo.path)
        for file in status.files.prefix(5) {
            let raw = try await GitCommands.diff(rootRepo.path, file: file)
            let t = Date()
            let doc = DiffDocument.build(from: raw, path: file.path, rowLimit: nil)
            print("DIFF \(file.area.rawValue) \(file.path): rows=\(doc.left.kinds.count) +\(doc.additions) -\(doc.deletions) build=\(String(format: "%.3f", Date().timeIntervalSince(t)))s")
            XCTAssertEqual(doc.left.kinds.count, doc.right.kinds.count)
        }
    }
}
