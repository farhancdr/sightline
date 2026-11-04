import Foundation

/// Repo-level git operations used by the UI.
enum GitCommands {
    static func status(_ repo: String) async throws -> RepoStatus {
        let result = try await Git.run(
            ["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"],
            in: repo
        )
        return StatusParser.parse(result.output)
    }

    static func branches(_ repo: String) async throws -> [BranchInfo] {
        let format = "%(refname)%00%(refname:short)%00%(HEAD)%00%(committerdate:relative)"
        let result = try await Git.run(
            ["for-each-ref", "--sort=-committerdate", "--format=\(format)", "refs/heads", "refs/remotes"],
            in: repo
        )
        var local: [BranchInfo] = []
        var remote: [BranchInfo] = []
        for line in result.output.split(separator: "\n") {
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4 else { continue }
            let (ref, short, head, date) = (fields[0], fields[1], fields[2], fields[3])
            if ref.hasPrefix("refs/remotes/") {
                guard !ref.hasSuffix("/HEAD") else { continue }
                remote.append(BranchInfo(name: short, isRemote: true, isCurrent: false, relativeDate: date))
            } else {
                local.append(BranchInfo(name: short, isRemote: false, isCurrent: head == "*", relativeDate: date))
            }
        }
        // Hide remote branches that already have a local branch of the same name.
        let localNames = Set(local.map(\.name))
        let remoteOnly = remote.filter { branch in
            guard let slash = branch.name.firstIndex(of: "/") else { return true }
            return !localNames.contains(String(branch.name[branch.name.index(after: slash)...]))
        }
        return local + remoteOnly
    }

    static func switchBranch(_ repo: String, to branch: BranchInfo) async throws {
        let args = branch.isRemote ? ["switch", "--track", branch.name] : ["switch", branch.name]
        _ = try await Git.run(args, in: repo)
    }

    static func fetch(_ repo: String) async throws {
        var env: [String: String] = [:]
        // No TTY for passphrase prompts: fail fast instead of hanging.
        if ProcessInfo.processInfo.environment["GIT_SSH_COMMAND"] == nil {
            env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
        }
        _ = try await Git.run(["fetch", "--prune"], in: repo, extraEnv: env)
    }

    // MARK: Commit

    static func commit(_ repo: String, message: String, noVerify: Bool) async throws {
        var args = ["commit", "-m", message]
        if noVerify { args.append("--no-verify") }
        _ = try await Git.run(args, in: repo)
    }

    static func stageAll(_ repo: String) async throws {
        _ = try await Git.run(["add", "-A"], in: repo)
    }

    // MARK: Staging (VS Code-style row and section actions)

    static func stage(_ repo: String, paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await Git.run(["add", "-A", "--"] + paths, in: repo)
    }

    static func unstage(_ repo: String, files: [FileChange]) async throws {
        let paths = files.flatMap { [$0.originalPath, $0.path].compactMap { $0 } }
        guard !paths.isEmpty else { return }
        do {
            _ = try await Git.run(["restore", "--staged", "--"] + paths, in: repo)
        } catch {
            // No HEAD yet (initial commit): restore --staged has nothing to restore from.
            _ = try await Git.run(["rm", "--cached", "-r", "-q", "--"] + paths, in: repo)
        }
    }

    /// Reverts tracked working-tree changes to the index version.
    static func discard(_ repo: String, paths: [String]) async throws {
        guard !paths.isEmpty else { return }
        _ = try await Git.run(["restore", "--"] + paths, in: repo)
    }

    /// Untracked files are moved to the Trash (recoverable) rather than deleted.
    static func trashUntracked(_ repo: String, paths: [String]) throws {
        for path in paths {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: repo + "/" + path), resultingItemURL: nil)
        }
    }

    /// Tracked + untracked (non-ignored) files, repo-relative, for quick open.
    static func listFiles(_ repo: String) async throws -> [String] {
        let result = try await Git.run(["ls-files", "-z", "--cached", "--others", "--exclude-standard"], in: repo)
        var seen = Set<String>()
        return result.output.split(separator: "\0").compactMap { entry in
            let path = String(entry)
            // Nested repos show up as "dir/"; their files come from their own listing.
            guard !path.hasSuffix("/"), seen.insert(path).inserted else { return nil }
            return path
        }
    }

    static func diff(_ repo: String, file: FileChange) async throws -> String {
        let base = ["--no-pager", "-c", "core.quotepath=off"]
        let context = "--unified=\(DiffDocument.fullContext)" // whole file, like VS Code
        let args: [String]
        var okCodes: Set<Int32> = [0]
        switch file.area {
        case .staged:
            args = base + ["diff", "--cached", "--no-color", "--no-ext-diff", "-M", context, "--"]
                + [file.originalPath, file.path].compactMap { $0 }
        case .unstaged:
            args = base + ["diff", "--no-color", "--no-ext-diff", context, "--", file.path]
        case .conflicted:
            // Plain 2-way diff vs HEAD (conflict markers show as additions); the default combined
            // diff format ("@@@") doesn't fit side-by-side columns.
            args = base + ["diff", "--no-color", "--no-ext-diff", context, "HEAD", "--", file.path]
        case .untracked:
            args = base + ["diff", "--no-color", "--no-ext-diff", context, "--no-index", "--", "/dev/null", file.path]
            okCodes = [0, 1] // --no-index exits 1 when files differ
        }
        return try await Git.run(args, in: repo, okCodes: okCodes).output
    }
}

/// Parser for `git status --porcelain=v2 --branch -z`.
enum StatusParser {
    static func parse(_ output: String) -> RepoStatus {
        var status = RepoStatus()
        let fields = output.split(separator: "\0", omittingEmptySubsequences: false)
        var index = 0
        while index < fields.count {
            let entry = fields[index]
            index += 1
            guard let kind = entry.first else { continue }
            switch kind {
            case "#":
                parseHeader(entry, into: &status)
            case "1":
                let parts = entry.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                if parts.count == 9 { addTracked(xy: parts[1], path: String(parts[8]), original: nil, to: &status) }
            case "2":
                // Rename/copy: the original path is the next NUL-separated field.
                let parts = entry.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                let original = index < fields.count ? String(fields[index]) : nil
                index += 1
                if parts.count == 10 { addTracked(xy: parts[1], path: String(parts[9]), original: original, to: &status) }
            case "u":
                let parts = entry.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
                if parts.count == 11 {
                    status.files.append(FileChange(path: String(parts[10]), originalPath: nil, area: .conflicted, code: "U"))
                }
            case "?":
                status.files.append(FileChange(path: String(entry.dropFirst(2)), originalPath: nil, area: .untracked, code: "?"))
            default:
                continue
            }
        }
        return status
    }

    private static func parseHeader(_ entry: Substring, into status: inout RepoStatus) {
        let parts = entry.split(separator: " ", maxSplits: 2)
        guard parts.count == 3 else { return }
        let value = String(parts[2])
        switch parts[1] {
        case "branch.oid": status.oid = value == "(initial)" ? nil : value
        case "branch.head": status.branch = value == "(detached)" ? nil : value
        case "branch.upstream": status.upstream = value
        case "branch.ab":
            let counts = value.split(separator: " ")
            if counts.count == 2 {
                status.ahead = Int(counts[0].dropFirst()) ?? 0
                status.behind = Int(counts[1].dropFirst()) ?? 0
            }
        default: break
        }
    }

    private static func addTracked(xy: Substring, path: String, original: String?, to status: inout RepoStatus) {
        let chars = Array(xy)
        guard chars.count == 2 else { return }
        if chars[0] != "." {
            status.files.append(FileChange(path: path, originalPath: original, area: .staged, code: chars[0]))
        }
        if chars[1] != "." {
            status.files.append(FileChange(path: path, originalPath: nil, area: .unstaged, code: chars[1]))
        }
    }
}
