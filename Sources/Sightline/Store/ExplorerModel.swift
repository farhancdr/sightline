import Foundation
import Observation

struct FileNode: Hashable, Sendable {
    let name: String
    let path: String
    /// Path relative to the repo root.
    let relativePath: String
    let isDirectory: Bool
}

struct ExplorerRow: Identifiable {
    let node: FileNode
    let depth: Int
    let isExpanded: Bool
    let isIgnored: Bool

    var id: String { node.path }
}

/// Lazy, VS Code-style file tree for one repo. Directories are listed only when expanded;
/// expansion state survives switching repos (one model per repo, cached by the store).
@MainActor
@Observable
final class ExplorerModel {
    let repo: Repo

    private(set) var expanded: Set<String> = []
    private(set) var children: [String: [FileNode]] = [:]
    /// Repo-relative ignored paths from git; directories end with "/".
    private(set) var ignored: Set<String> = []
    var selectedPath: String?

    nonisolated static let hiddenNames: Set<String> = [".git", ".DS_Store"]

    init(repo: Repo) {
        self.repo = repo
        children[repo.path] = Self.list(repo.path, repoPath: repo.path)
        Task { await loadIgnored() }
    }

    /// Visible rows in display order (DFS over expanded directories).
    var rows: [ExplorerRow] {
        var result: [ExplorerRow] = []
        func visit(_ dir: String, depth: Int, parentIgnored: Bool) {
            for node in children[dir] ?? [] {
                let isIgnored = parentIgnored || isIgnoredPath(node)
                let isOpen = node.isDirectory && expanded.contains(node.path)
                result.append(ExplorerRow(node: node, depth: depth, isExpanded: isOpen, isIgnored: isIgnored))
                if isOpen { visit(node.path, depth: depth + 1, parentIgnored: isIgnored) }
            }
        }
        visit(repo.path, depth: 0, parentIgnored: false)
        return result
    }

    func toggle(_ node: FileNode) {
        guard node.isDirectory else { return }
        if expanded.contains(node.path) {
            expanded.remove(node.path)
        } else {
            if children[node.path] == nil { children[node.path] = Self.list(node.path, repoPath: repo.path) }
            expanded.insert(node.path)
        }
    }

    func collapseAll() { expanded.removeAll() }

    /// Expands every ancestor of a repo-relative path and selects it.
    func reveal(relativePath: String) {
        var dir = repo.path
        for component in relativePath.split(separator: "/").dropLast() {
            dir += "/" + component
            if children[dir] == nil { children[dir] = Self.list(dir, repoPath: repo.path) }
            expanded.insert(dir)
        }
        selectedPath = repo.path + "/" + relativePath
    }

    /// Re-lists the root and every loaded directory (called after file-system events).
    func reload() {
        for dir in Array(children.keys) {
            if dir == repo.path || expanded.contains(dir) {
                let fresh = Self.list(dir, repoPath: repo.path)
                if children[dir] != fresh { children[dir] = fresh }
            } else {
                children.removeValue(forKey: dir) // reload lazily on next expand
            }
        }
        expanded = expanded.filter { FileManager.default.fileExists(atPath: $0) }
        Task { await loadIgnored() }
    }

    private func isIgnoredPath(_ node: FileNode) -> Bool {
        ignored.contains(node.isDirectory ? node.relativePath + "/" : node.relativePath)
    }

    private func loadIgnored() async {
        let args = ["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"]
        guard let result = try? await Git.run(args, in: repo.path) else { return }
        let set = Set(result.output.split(separator: "\0").map(String.init))
        if set != ignored { ignored = set }
    }

    nonisolated static func list(_ dir: String, repoPath: String) -> [FileNode] {
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: []
        ) else { return [] }
        let prefix = dir == repoPath ? "" : String(dir.dropFirst(repoPath.count + 1)) + "/"
        return urls.compactMap { child -> FileNode? in
            let name = child.lastPathComponent
            guard !hiddenNames.contains(name) else { return nil }
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return FileNode(name: name, path: dir + "/" + name, relativePath: prefix + name, isDirectory: isDir)
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
