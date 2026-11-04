import Foundation

/// Finds every git working tree under a root folder (including the root itself).
enum RepoScanner {
    static let skippedDirectories: Set<String> = [
        "node_modules", "vendor", "dist", "build", "coverage", "Pods", "DerivedData",
        "__pycache__", "venv", "target",
    ]

    /// Resolved so paths match what FSEvents reports (e.g. /var → /private/var).
    static func resolvedRoot(_ root: String) -> String {
        URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
    }

    static func scan(root: String, maxDepth: Int = 6) -> [Repo] {
        var repos: [Repo] = []
        walk(path: resolvedRoot(root), relative: "", depth: 0, maxDepth: maxDepth, into: &repos)
        return repos.sorted { lhs, rhs in
            if lhs.relativePath.isEmpty { return true }
            if rhs.relativePath.isEmpty { return false }
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
    }

    private static func walk(path: String, relative: String, depth: Int, maxDepth: Int, into repos: inout [Repo]) {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path, isDirectory: true)
        // `.git` is a directory normally, a file for worktrees/submodules.
        if fm.fileExists(atPath: path + "/.git") {
            repos.append(Repo(path: path, relativePath: relative))
        }
        guard depth < maxDepth else { return }

        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let children = try? fm.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return }

        for child in children {
            let name = child.lastPathComponent
            guard let values = try? child.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  !skippedDirectories.contains(name),
                  child.pathExtension != "app"
            else { continue }
            walk(
                path: path + "/" + name,
                relative: relative.isEmpty ? name : relative + "/" + name,
                depth: depth + 1, maxDepth: maxDepth, into: &repos
            )
        }
    }
}
