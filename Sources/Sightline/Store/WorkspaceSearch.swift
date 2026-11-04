import Foundation

/// VS Code-style "Search" across every repo (⇧⌘F): match case, whole word, regex, include/exclude globs.
/// Uses `git grep` per repo (tracked + untracked, .gitignore respected), repos in parallel.
struct WorkspaceSearchOptions: Equatable, Sendable {
    var matchCase = false
    var wholeWord = false
    var regex = false
    /// Comma-separated globs, e.g. "*.ts, src/**". A glob without "/" matches at any depth; a plain name
    /// ("dist") matches that file or folder at any depth.
    var include = ""
    var exclude = WorkspaceSearchOptions.defaultExclude
    /// Search every repo under the root instead of only the selected one.
    var allRepos = false

    static let defaultExclude = "node_modules, dist"
}

struct SearchMatch: Identifiable, Hashable, Sendable {
    let repoID: String
    let repoRelativePath: String
    let line: Int
    /// 1-based column of the first match.
    let column: Int
    /// The matched line (trimmed for display) and match ranges inside it (UTF-16).
    let text: String
    let ranges: [NSRange]

    var id: String { "\(repoID)/\(repoRelativePath):\(line)" }
    var absolutePath: String { repoID + "/" + repoRelativePath }
}

struct SearchFileResult: Identifiable, Hashable, Sendable {
    let repoID: String
    let repoRelativePath: String
    /// Path relative to the workspace root.
    let displayPath: String
    var matches: [SearchMatch]

    var id: String { repoID + "/" + repoRelativePath }
    var fileName: String { (repoRelativePath as NSString).lastPathComponent }
    var directory: String { (displayPath as NSString).deletingLastPathComponent }
}

struct SearchResults: Sendable {
    var files: [SearchFileResult] = []
    var matchCount = 0
    var truncated = false
    var error: String?
}

enum WorkspaceSearch {
    static let maxMatches = 2000
    static let maxPerFile = 100
    static let maxPreviewLength = 400

    /// The regex used to highlight matches (and validate a regex query before running git).
    static func highlightRegex(_ query: String, options: WorkspaceSearchOptions) throws -> NSRegularExpression {
        var pattern = options.regex ? query : NSRegularExpression.escapedPattern(for: query)
        if options.wholeWord { pattern = "\\b(?:\(pattern))\\b" }
        return try NSRegularExpression(pattern: pattern, options: options.matchCase ? [] : [.caseInsensitive])
    }

    /// `git grep` pathspecs from the include/exclude fields.
    static func pathspecs(_ options: WorkspaceSearchOptions) -> [String] {
        func globs(_ text: String) -> [String] {
            text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                .flatMap { entry -> [String] in
                    if entry.contains("/") { return [entry] }
                    if entry.contains(where: { "*?[".contains($0) }) { return ["**/" + entry] }
                    return ["**/" + entry, "**/" + entry + "/**"] // a file or a folder with that name, any depth
                }
        }
        let include = globs(options.include).map { ":(glob)\($0)" }
        let exclude = globs(options.exclude).map { ":(exclude,glob)\($0)" }
        if include.isEmpty && exclude.isEmpty { return [] }
        return (include.isEmpty ? ["."] : include) + exclude
    }

    /// `untracked: false` searches tracked files only; `true` adds untracked (non-ignored) files. Both are run,
    /// because `--untracked` alone skips tracked files that sit inside gitignored folders.
    static func grepArguments(_ query: String, options: WorkspaceSearchOptions, untracked: Bool = false) -> [String] {
        var args = ["grep", "-z", "-n", "--column", "-I", "--no-color", "-m", "\(maxPerFile)"]
        if untracked { args.insert("--untracked", at: 1) }
        args.append(options.regex ? "-P" : "-F")
        if !options.matchCase { args.append("-i") }
        if options.wholeWord { args.append("-w") }
        args += ["-e", query, "--"] + pathspecs(options)
        return args
    }

    static func search(_ query: String, options: WorkspaceSearchOptions, repos: [Repo], root: String) async -> SearchResults {
        guard !query.isEmpty else { return SearchResults() }
        let highlight: NSRegularExpression
        do {
            highlight = try highlightRegex(query, options: options)
        } catch {
            return SearchResults(error: "Invalid regular expression")
        }
        let trackedArgs = grepArguments(query, options: options)
        let untrackedArgs = grepArguments(query, options: options, untracked: true)

        var perRepo: [(Int, [SearchFileResult])] = []
        var firstError: String?
        await withTaskGroup(of: (Int, Result<[SearchFileResult], Error>).self) { group in
            var next = 0
            func addNext() {
                guard next < repos.count else { return }
                let index = next
                let repo = repos[index]
                next += 1
                group.addTask {
                    do {
                        // Exit code 1 = no matches.
                        func grep(_ args: [String]) async throws -> String {
                            do {
                                return try await Git.run(args, in: repo.path, okCodes: [0, 1]).output
                            } catch where options.regex && error.localizedDescription.contains("Perl") {
                                // git built without PCRE: fall back to extended regex.
                                return try await Git.run(args.map { $0 == "-P" ? "-E" : $0 }, in: repo.path,
                                                         okCodes: [0, 1]).output
                            }
                        }
                        var files = parse(try await grep(trackedArgs), repo: repo, highlight: highlight)
                        let seen = Set(files.map(\.repoRelativePath))
                        files += parse(try await grep(untrackedArgs), repo: repo, highlight: highlight)
                            .filter { !seen.contains($0.repoRelativePath) }
                        return (index, .success(files))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            for _ in 0..<min(8, repos.count) { addNext() }
            while let (index, result) = await group.next() {
                switch result {
                case let .success(files): perRepo.append((index, files))
                case let .failure(error): if firstError == nil { firstError = error.localizedDescription }
                }
                addNext()
            }
        }

        var results = SearchResults()
        for (_, files) in perRepo.sorted(by: { $0.0 < $1.0 }) {
            for var file in files {
                let remaining = maxMatches - results.matchCount
                guard remaining > 0 else {
                    results.truncated = true
                    break
                }
                if file.matches.count > remaining {
                    file.matches = Array(file.matches.prefix(remaining))
                    results.truncated = true
                }
                results.matchCount += file.matches.count
                results.files.append(file)
            }
        }
        if results.files.isEmpty, let firstError, !firstError.isEmpty { results.error = firstError }
        return results
    }

    /// `path\0line\0column\0text\n` records.
    static func parse(_ output: String, repo: Repo, highlight: NSRegularExpression) -> [SearchFileResult] {
        var files: [SearchFileResult] = []
        var indexByPath: [String: Int] = [:]
        for record in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = record.split(separator: "\0", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count == 4, let line = Int(parts[1]), let column = Int(parts[2]) else { continue }
            let path = String(parts[0])
            let (text, ranges) = preview(String(parts[3]), highlight: highlight)
            let match = SearchMatch(repoID: repo.id, repoRelativePath: path, line: line, column: column,
                                    text: text, ranges: ranges)
            if let index = indexByPath[path] {
                files[index].matches.append(match)
            } else {
                indexByPath[path] = files.count
                let display = repo.relativePath.isEmpty ? path : repo.relativePath + "/" + path
                files.append(SearchFileResult(repoID: repo.id, repoRelativePath: path, displayPath: display,
                                              matches: [match]))
            }
        }
        return files
    }

    /// Leading whitespace trimmed, long lines cut around the first match; ranges re-based to the preview.
    static func preview(_ line: String, highlight: NSRegularExpression) -> (String, [NSRange]) {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        var text = String(trimmed)
        var ns = text as NSString
        var ranges = highlight.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
            .filter { $0.length > 0 }
        if ns.length > maxPreviewLength {
            let start = max(0, (ranges.first?.location ?? 0) - 40)
            let length = min(maxPreviewLength, ns.length - start)
            text = (start > 0 ? "…" : "") + ns.substring(with: NSRange(location: start, length: length))
            let shift = start - (start > 0 ? 1 : 0)
            ns = text as NSString
            ranges = ranges.map { NSRange(location: $0.location - shift, length: $0.length) }
                .filter { $0.location >= 0 && NSMaxRange($0) <= ns.length }
        }
        return (text, ranges)
    }
}
