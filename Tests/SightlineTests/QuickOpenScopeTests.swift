import XCTest
@testable import Sightline

final class QuickOpenScopeTests: XCTestCase {
    func testScopedLimitsSearchToOneRepo() {
        let api = Repo(path: "/w/services/api", relativePath: "services/api")
        let web = Repo(path: "/w/apps/web", relativePath: "apps/web")
        let entries = [
            QuickOpenEntry(repo: api, repoRelativePath: "src/user.ts"),
            QuickOpenEntry(repo: web, repoRelativePath: "src/user.tsx"),
            QuickOpenEntry(repo: api, repoRelativePath: "README.md"),
        ]
        XCTAssertEqual(FileIndex.scoped(entries, repoID: nil).count, 3, "all repos")
        let apiOnly = FileIndex.scoped(entries, repoID: api.id)
        XCTAssertEqual(apiOnly.map(\.repoRelativePath), ["src/user.ts", "README.md"])
        XCTAssertEqual(FileIndex.search("user", in: apiOnly).map(\.displayPath), ["services/api/src/user.ts"])
        XCTAssertEqual(FileIndex.search("user", in: entries).count, 2)
    }
}
