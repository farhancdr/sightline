import Foundation

struct QuickOpenEntry: Identifiable, Hashable, Sendable {
    let repoID: String
    /// Path relative to its repo.
    let repoRelativePath: String
    /// Path relative to the workspace root (what's shown and matched).
    let displayPath: String
    let absolutePath: String
    let lowercased: [UInt8]
    /// Byte offset of the file name inside `lowercased`.
    let nameStart: Int

    var id: String { absolutePath }
    var fileName: String { (displayPath as NSString).lastPathComponent }
    var directory: String { (displayPath as NSString).deletingLastPathComponent }

    init(repo: Repo, repoRelativePath: String) {
        repoID = repo.id
        self.repoRelativePath = repoRelativePath
        displayPath = repo.relativePath.isEmpty ? repoRelativePath : repo.relativePath + "/" + repoRelativePath
        absolutePath = repo.path + "/" + repoRelativePath
        lowercased = Array(displayPath.lowercased().utf8)
        nameStart = (lowercased.lastIndex(of: UInt8(ascii: "/")).map { $0 + 1 }) ?? 0
    }
}

/// Workspace-wide file list for ⌘P, from `git ls-files` (respects .gitignore, very fast).
enum FileIndex {
    static func build(repos: [Repo]) async -> [QuickOpenEntry] {
        await withTaskGroup(of: [QuickOpenEntry].self) { group in
            var next = 0
            func addNext() {
                guard next < repos.count else { return }
                let repo = repos[next]
                next += 1
                group.addTask {
                    let files = (try? await GitCommands.listFiles(repo.path)) ?? []
                    return files.map { QuickOpenEntry(repo: repo, repoRelativePath: $0) }
                }
            }
            for _ in 0..<min(8, repos.count) { addNext() }
            var all: [QuickOpenEntry] = []
            while let batch = await group.next() {
                all += batch
                addNext()
            }
            return all
        }
    }

    /// VS Code-ish fuzzy ranking: file-name substring first, then path substring, then a scored
    /// subsequence match (consecutive runs and segment starts score higher).
    static func search(_ query: String, in entries: [QuickOpenEntry], limit: Int = 60) -> [QuickOpenEntry] {
        let q = Array(query.lowercased().replacingOccurrences(of: " ", with: "").utf8)
        guard !q.isEmpty else { return [] }
        var scored: [(Int, QuickOpenEntry)] = []
        scored.reserveCapacity(256)
        for entry in entries {
            if Task.isCancelled { return [] }
            if let score = score(q, entry) { scored.append((score, entry)) }
        }
        scored.sort { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1.displayPath.count < $1.1.displayPath.count }
        return scored.prefix(limit).map(\.1)
    }

    private static let separators: Set<UInt8> = Set("/._- ".utf8)

    static func score(_ q: [UInt8], _ entry: QuickOpenEntry) -> Int? {
        let t = entry.lowercased
        let nameLength = t.count - entry.nameStart
        if let at = find(q, in: t, from: entry.nameStart) {
            let exactName = at == entry.nameStart ? 2000 : 0
            return 100_000 + exactName - nameLength * 4 - (at - entry.nameStart) * 2 - t.count
        }
        if let at = find(q, in: t, from: 0) {
            return 50_000 - at - t.count
        }
        var qi = 0
        var score = 0
        var previous = -2
        var ti = 0
        while ti < t.count, qi < q.count {
            if t[ti] == q[qi] {
                var s = 1
                if ti == previous + 1 { s += 6 }
                if ti == 0 || separators.contains(t[ti - 1]) { s += 8 }
                if ti >= entry.nameStart { s += 3 }
                score += s
                previous = ti
                qi += 1
            }
            ti += 1
        }
        guard qi == q.count else { return nil }
        return score * 20 - t.count
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        guard needle.count <= haystack.count - start, start >= 0 else { return nil }
        var i = start
        let last = haystack.count - needle.count
        outer: while i <= last {
            if haystack[i] == needle[0] {
                for k in 1..<needle.count where haystack[i + k] != needle[k] {
                    i += 1
                    continue outer
                }
                return i
            }
            i += 1
        }
        return nil
    }
}
