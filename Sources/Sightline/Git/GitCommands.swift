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

    /// Network commands get no TTY: make SSH fail fast on a passphrase prompt instead of hanging.
    private static var networkEnv: [String: String] {
        ProcessInfo.processInfo.environment["GIT_SSH_COMMAND"] == nil ? ["GIT_SSH_COMMAND": "ssh -o BatchMode=yes"] : [:]
    }

    static func fetch(_ repo: String) async throws {
        _ = try await Git.run(["fetch", "--prune"], in: repo, extraEnv: networkEnv)
    }

    /// Fast-forward only: never creates a merge commit or rebases behind the user's back.
    static func pull(_ repo: String) async throws {
        _ = try await Git.run(["pull", "--ff-only"], in: repo, extraEnv: networkEnv)
    }

    /// Pushes the current branch. Without an upstream it publishes it (`-u <remote> HEAD`), using
    /// `origin` if present, else the first remote. Never forces.
    static func push(_ repo: String, hasUpstream: Bool) async throws {
        if hasUpstream {
            _ = try await Git.run(["push"], in: repo, extraEnv: networkEnv)
            return
        }
        let remotes = try await Git.run(["remote"], in: repo).output
            .split(separator: "\n").map(String.init)
        guard let remote = remotes.first(where: { $0 == "origin" }) ?? remotes.first else {
            throw GitError(command: "push", message: "This repository has no remote to push to.")
        }
        _ = try await Git.run(["push", "-u", remote, "HEAD"], in: repo, extraEnv: networkEnv)
    }

    // MARK: History

    /// `%x1f` between fields, `%x1e` after each record: subjects/names can contain anything else.
    static let logFormat = "%H%x1f%h%x1f%an%x1f%ae%x1f%at%x1f%P%x1f%D%x1f%s%x1e"

    /// `paths`: only commits touching these repo-relative files/folders (no `--follow`: it breaks `--skip` paging;
    /// renames still show in the commit's file list via `-M`).
    static func log(_ repo: String, skip: Int = 0, limit: Int = 100, revision: String? = nil,
                    paths: [String] = []) async throws -> [CommitInfo] {
        var args = ["log", "--format=\(logFormat)", "-n", "\(limit)", "--skip=\(skip)"]
        if let revision { args.append(revision) }
        if !paths.isEmpty { args += ["--"] + paths }
        let result = try await Git.run(args, in: repo)
        return LogParser.parse(result.output)
    }

    static func commit(_ repo: String, sha: String) async throws -> CommitInfo? {
        try await log(repo, limit: 1, revision: sha).first
    }

    /// Full commit message.
    static func message(_ repo: String, sha: String) async throws -> String {
        try await Git.run(["log", "-1", "--format=%B", sha], in: repo).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Commits on HEAD that aren't on its upstream (empty without an upstream).
    static func unpushed(_ repo: String) async -> Set<String> {
        guard let result = try? await Git.run(["rev-list", "@{upstream}..HEAD"], in: repo) else { return [] }
        return Set(result.output.split(separator: "\n").map(String.init))
    }

    /// Files changed by a commit, relative to its first parent (the root commit: everything added).
    static func commitFiles(_ repo: String, commit: CommitInfo) async throws -> [CommitFile] {
        let args = commit.isRoot
            ? ["diff-tree", "--root", "-r", "-M", "--no-commit-id", "--name-status", "-z", commit.sha]
            : ["diff", "-M", "--name-status", "-z", "\(commit.sha)^", commit.sha]
        return LogParser.parseNameStatus(try await Git.run(args, in: repo).output)
    }

    /// Whole-file diff of one file in a commit (first parent for merges).
    static func commitDiff(_ repo: String, commit: CommitInfo, file: CommitFile) async throws -> String {
        let context = "--unified=\(DiffDocument.fullContext)"
        let paths = [file.originalPath, file.path].compactMap { $0 }
        let args = commit.isRoot
            ? ["show", "--root", "--format=", "--no-color", "--no-ext-diff", context, commit.sha, "--"] + paths
            : ["diff", "-M", "--no-color", "--no-ext-diff", context, "\(commit.sha)^", commit.sha, "--"] + paths
        return try await Git.run(args, in: repo).output
    }

    // MARK: Blame

    /// Line-by-line authorship of `path`, computed against `contents` (the editor's current text) so
    /// unsaved edits don't shift lines. Untracked files / repos without commits throw.
    static func blame(_ repo: String, path: String, contents: String) async throws -> BlameResult {
        let result = try await Git.run(
            ["blame", "--porcelain", "--contents", "-", "--", path], in: repo, input: Data(contents.utf8)
        )
        return BlameParser.parse(result.output)
    }

    static func userEmail(_ repo: String) async -> String? {
        let result = try? await Git.run(["config", "user.email"], in: repo, okCodes: [0, 1])
        let email = result?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return email.isEmpty ? nil : email
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
                // 1 XY sub mH mI mW hH hI path
                let parts = entry.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
                if parts.count == 9 {
                    addTracked(xy: parts[1], path: String(parts[8]), original: nil, indexHash: String(parts[7]), to: &status)
                }
            case "2":
                // Rename/copy: the original path is the next NUL-separated field.
                let parts = entry.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
                let original = index < fields.count ? String(fields[index]) : nil
                index += 1
                if parts.count == 10 {
                    addTracked(xy: parts[1], path: String(parts[9]), original: original, indexHash: String(parts[7]), to: &status)
                }
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

    private static func addTracked(
        xy: Substring, path: String, original: String?, indexHash: String, to status: inout RepoStatus
    ) {
        let chars = Array(xy)
        guard chars.count == 2 else { return }
        if chars[0] != "." {
            status.files.append(FileChange(path: path, originalPath: original, area: .staged, code: chars[0],
                                           indexHash: indexHash))
        }
        if chars[1] != "." {
            status.files.append(FileChange(path: path, originalPath: nil, area: .unstaged, code: chars[1],
                                           indexHash: indexHash))
        }
    }
}

/// Parsers for `git log` with record/field separators and `--name-status -z`.
enum LogParser {
    static func parse(_ output: String) -> [CommitInfo] {
        output.split(separator: "\u{1e}").compactMap { record in
            let fields = record.drop { $0.isNewline }.split(separator: "\u{1f}", omittingEmptySubsequences: false)
                .map(String.init)
            guard fields.count >= 8 else { return nil }
            return CommitInfo(
                sha: fields[0],
                shortSha: fields[1],
                author: fields[2],
                email: fields[3],
                date: Date(timeIntervalSince1970: TimeInterval(fields[4]) ?? 0),
                parents: fields[5].split(separator: " ").map(String.init),
                refs: fields[6].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty },
                subject: fields[7...].joined(separator: "\u{1f}")
            )
        }
    }

    /// `M\0path\0` or `R100\0old\0new\0`.
    static func parseNameStatus(_ output: String) -> [CommitFile] {
        let tokens = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var files: [CommitFile] = []
        var index = 0
        while index < tokens.count {
            let status = tokens[index]
            index += 1
            guard let code = status.first else { continue }
            if code == "R" || code == "C" {
                guard index + 1 < tokens.count else { break }
                files.append(CommitFile(path: tokens[index + 1], originalPath: tokens[index], code: code))
                index += 2
            } else {
                guard index < tokens.count else { break }
                files.append(CommitFile(path: tokens[index], originalPath: nil, code: code))
                index += 1
            }
        }
        return files
    }
}

/// Parser for `git blame --porcelain`. Commit details appear only the first time a sha shows up.
enum BlameParser {
    static func parse(_ output: String) -> BlameResult {
        var lineCommits: [String] = []
        var commits: [String: BlameCommit] = [:]
        var current: String?
        var fields: [String: String] = [:]

        func finish() {
            guard let sha = current, commits[sha] == nil else { return }
            let mail = fields["author-mail"] ?? ""
            commits[sha] = BlameCommit(
                sha: sha,
                author: fields["author"] ?? "",
                email: mail.trimmingCharacters(in: CharacterSet(charactersIn: "<>")),
                date: Date(timeIntervalSince1970: TimeInterval(fields["author-time"] ?? "") ?? 0),
                summary: fields["summary"] ?? ""
            )
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("\t") {
                // Content line ends the entry for one final line.
                finish()
                if let sha = current { lineCommits.append(sha) }
                fields = [:]
                continue
            }
            let parts = line.split(separator: " ", maxSplits: 1)
            guard let key = parts.first else { continue }
            if key.count == 40, key.allSatisfy(\.isHexDigit), current == nil || fields.isEmpty {
                current = String(key)
            } else if parts.count == 2 {
                fields[String(key)] = String(parts[1])
            }
        }
        return BlameResult(lineCommits: lineCommits, commits: commits)
    }
}
