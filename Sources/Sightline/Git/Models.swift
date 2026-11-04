import Foundation

struct Repo: Identifiable, Hashable, Sendable {
    /// Absolute path to the working tree.
    let path: String
    /// Path relative to the chosen root ("" for the root itself).
    let relativePath: String

    var id: String { path }

    /// Top-level folder under the root (services, serverless, …) used for sidebar sections.
    var group: String {
        let parts = relativePath.split(separator: "/")
        return parts.count > 1 ? String(parts[0]) : ""
    }

    /// Display name: path inside its group, or the folder name.
    var name: String {
        if relativePath.isEmpty { return (path as NSString).lastPathComponent }
        let parts = relativePath.split(separator: "/")
        return parts.count > 1 ? parts.dropFirst().joined(separator: "/") : relativePath
    }
}

enum ChangeArea: String, Sendable, CaseIterable {
    case conflicted, staged, unstaged, untracked

    /// Sections shown in the Changes tab (untracked files are folded into `.unstaged`).
    static let sections: [ChangeArea] = [.conflicted, .staged, .unstaged]

    var title: String {
        switch self {
        case .conflicted: "Conflicts"
        case .staged: "Staged"
        case .unstaged: "Changes"
        case .untracked: "Untracked"
        }
    }
}

struct FileChange: Identifiable, Hashable, Sendable {
    let path: String
    let originalPath: String?
    let area: ChangeArea
    /// Porcelain status letter: M A D R C T U ?
    let code: Character

    var id: String { "\(area.rawValue):\(path)" }
    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir + "/"
    }
}

struct RepoStatus: Sendable, Equatable {
    var branch: String?
    var oid: String?
    var upstream: String?
    var ahead = 0
    var behind = 0
    var files: [FileChange] = []

    var isDetached: Bool { branch == nil }
    var headLabel: String {
        if let branch { return branch }
        if let oid { return "detached @ " + String(oid.prefix(7)) }
        return "no commits"
    }

    /// Distinct paths with any change (a file can be both staged and unstaged).
    var changedCount: Int { Set(files.map(\.path)).count }

    func files(in area: ChangeArea) -> [FileChange] { files.filter { $0.area == area } }

    /// Rows for a Changes-tab section, VS Code style: untracked files sit in "Changes" next to
    /// modified ones (marked U), and each section is sorted by path.
    func sectionFiles(_ section: ChangeArea) -> [FileChange] {
        let members: [FileChange] = section == .unstaged
            ? files.filter { $0.area == .unstaged || $0.area == .untracked }
            : files(in: section)
        return members.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

struct BranchInfo: Identifiable, Hashable, Sendable {
    let name: String
    let isRemote: Bool
    let isCurrent: Bool
    let relativeDate: String

    var id: String { (isRemote ? "r:" : "l:") + name }
}
