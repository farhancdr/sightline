import Foundation

/// "Mark as reviewed" bookkeeping. A file stays reviewed only while its fingerprint matches the one
/// recorded when it was marked, so any new change by an agent un-reviews it.
enum ReviewState {
    /// - staged: the index blob id (exact content of what will be committed)
    /// - working tree / untracked / conflicted: modification time + size of the file on disk
    nonisolated static func fingerprint(_ file: FileChange, repoPath: String) -> String {
        if file.area == .staged { return "staged|\(file.indexHash ?? "-")" }
        let path = repoPath + "/" + file.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
            return "\(file.area.rawValue)|missing|\(file.indexHash ?? "-")"
        }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        return "\(file.area.rawValue)|\(modified)|\(size)|\(file.indexHash ?? "-")"
    }

    nonisolated static func fingerprints(_ status: RepoStatus, repoPath: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: status.files.map { ($0.id, fingerprint($0, repoPath: repoPath)) })
    }
}
