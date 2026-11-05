import AppKit
import Observation

@MainActor
@Observable
final class AppStore {
    static let shared = AppStore()

    private static let rootKey = "rootPath"
    private static let themeKey = "theme"
    private static let terminalKey = "terminalVisible"
    private static let diffLayoutKey = "diffSideBySide"
    private static let repoSortKey = "repoSort"
    private static let lastOpenedKey = "repoLastOpened"
    private static let openCountsKey = "repoOpenCounts"
    private static let lastRepoKey = "lastRepoPath"
    private static let onlyChangedKey = "showOnlyChangedRepos"
    private static let editorKey = "preferredEditor"
    private static let reviewedKey = "reviewedFiles"
    private static let blameKey = "showLineBlame"
    private static let terminalSchemeKey = "terminalColorScheme"
    private static let markdownPreviewKey = "markdownPreview"
    private static let vimKey = "vimMode"
    private static let terminalGPUKey = "terminalGPU"
    private static let maxParallelGit = 8

    // MARK: Workspace

    private(set) var rootPath: String?
    private(set) var repos: [Repo] = []
    private(set) var statuses: [String: RepoStatus] = [:]
    private(set) var isScanning = false

    enum SyncOperation: String { case fetch = "Fetching", pull = "Pulling", push = "Pushing" }
    /// The fetch/pull/push in flight for the selected repo (one at a time).
    private(set) var syncing: SyncOperation?
    private(set) var selectedRepoID: String?
    var repoFilter = ""

    enum RepoSort: String, CaseIterable { case folder = "By Folder", recent = "Recent", mostOpened = "Most Opened" }
    private(set) var repoSort: RepoSort
    /// When each repo (by path) was last opened from the sidebar / ⌘P, for "Recent".
    private(set) var lastOpened: [String: Double]
    /// How many times each repo was opened from the sidebar / ⌘P, for "Most Opened".
    private(set) var openCounts: [String: Int]
    /// Sidebar shows only repos with uncommitted changes or unpushed commits (plus the selected one).
    var showOnlyChanged: Bool { didSet { UserDefaults.standard.set(showOnlyChanged, forKey: Self.onlyChangedKey) } }

    // Layout toggles (⌘B / ⇧⌘B) and the ⌘T focus request.
    var sidebarVisible = true
    var repoPanelVisible = true
    private(set) var focusRepoFilterRequest = 0

    // MARK: Changes / diff

    var selectedFileID: String?
    /// Commit message drafts per repo, so switching repos keeps what you typed.
    private(set) var commitDrafts: [String: String] = [:]
    private(set) var isCommitting = false
    private(set) var diff: DiffDocument?
    /// The change entry `diff` belongs to.
    private(set) var diffFileID: String?
    private(set) var diffSideBySide: Bool
    private(set) var isLoadingDiff = false
    var errorMessage: String?

    // MARK: Workspace search (⇧⌘F)

    var searchQuery = ""
    var searchOptions = WorkspaceSearchOptions()
    private(set) var searchResults = SearchResults()
    private(set) var isSearching = false
    private(set) var focusSearchRequest = 0
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var searchGeneration = 0

    // MARK: Navigation history (⌥- / ⌥=)

    struct NavLocation: Equatable {
        let path: String
        let line: Int
        let column: Int
    }

    private(set) var backStack: [NavLocation] = []
    private(set) var forwardStack: [NavLocation] = []
    /// Applied when the file being opened finishes loading.
    @ObservationIgnored private var pendingReveal: (path: String, line: Int, column: Int, length: Int)?

    // MARK: History

    private static let historyPage = 100
    private(set) var commits: [CommitInfo] = []
    /// Commits on HEAD not yet on its upstream.
    private(set) var unpushedCommits: Set<String> = []
    private(set) var hasMoreCommits = false
    private(set) var isLoadingHistory = false
    private(set) var selectedCommitID: String?
    /// Repo-relative file or folder the History panel is limited to (nil: whole repo).
    private(set) var historyPath: String?
    private(set) var selectedCommitMessage: String?
    private(set) var commitFiles: [CommitFile] = []
    private(set) var selectedCommitFileID: String?
    private(set) var commitDiff: DiffDocument?
    private(set) var isLoadingCommitDiff = false
    /// A commit opened from blame that isn't in the loaded pages.
    @ObservationIgnored private var extraCommit: CommitInfo?
    /// "repo|HEAD" the loaded history belongs to; a new HEAD (commit/pull/switch) reloads it.
    @ObservationIgnored private var historyKey: String?
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var commitTask: Task<Void, Never>?
    @ObservationIgnored private var commitDiffTask: Task<Void, Never>?

    // MARK: Review marks

    /// repo path → file id → fingerprint recorded when it was marked reviewed.
    private(set) var reviewed: [String: [String: String]]
    /// repo path → file id → current fingerprint, recomputed on every refresh (even when the status
    /// itself didn't change), so an agent editing a reviewed file un-reviews it.
    private(set) var currentFingerprints: [String: [String: String]] = [:]

    // MARK: Files / editor

    enum Panel: String, CaseIterable {
        case changes = "Changes", files = "Files", history = "History", search = "Search"
    }
    var panel: Panel = .changes {
        didSet { if panel == .history { loadHistoryIfNeeded() } }
    }
    private(set) var explorer: ExplorerModel?
    /// Open-file tabs across all repos. The active tab always belongs to the selected repo (or there is none):
    /// activating another repo's tab selects that repo.
    private(set) var tabList = TabList()
    /// Loaded sessions of the open tabs, by path.
    private(set) var tabSessions: [String: EditorSession] = [:]
    /// repo id → the tab last active in it, restored when the repo is selected again.
    @ObservationIgnored private var lastActiveTab: [String: String] = [:]
    @ObservationIgnored private var fileTasks: [String: Task<Void, Never>] = [:]
    /// The active tab's session.
    var editor: EditorSession? { tabList.active.flatMap { tabSessions[$0] } }
    var tabs: [EditorSession] { tabList.paths.compactMap { tabSessions[$0] } }
    /// Every open session in every repo (unsaved-changes checks, settings changes).
    private var allSessions: [EditorSession] { Array(tabSessions.values) }

    /// The innermost repo containing `path`.
    func repo(forPath path: String) -> Repo? { reposByDepth.first { path.hasPrefix($0.path + "/") } }
    /// In the Files panel, show the diff of the open file instead of the editor.
    var showDiffForOpenFile = false
    /// Vim keys in the editor (View → Vim Mode).
    var vimMode: Bool {
        didSet {
            UserDefaults.standard.set(vimMode, forKey: Self.vimKey)
            for session in allSessions { session.controller?.vimEnabled = vimMode }
        }
    }
    /// Rendered markdown in place of the editor for markdown files (⇧⌘V).
    var markdownPreview: Bool { didSet { UserDefaults.standard.set(markdownPreview, forKey: Self.markdownPreviewKey) } }
    var isMarkdownOpen: Bool { editor?.language.mode == .markdown && editor?.controller != nil }
    /// GitLens-style "author, when · subject" after the caret line in the editor.
    var showLineBlame: Bool {
        didSet {
            UserDefaults.standard.set(showLineBlame, forKey: Self.blameKey)
            for session in allSessions { session.controller?.blameEnabled = showLineBlame }
        }
    }
    /// Short confirmation shown in the file header ("Copied path:12-30").
    private(set) var toast: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    // MARK: External editor

    /// Editors found on this Mac (checked once at launch).
    @ObservationIgnored let installedEditors = ExternalEditor.installed
    private(set) var preferredEditorID: String?
    var preferredEditor: ExternalEditor? {
        installedEditors.first { $0.id == preferredEditorID } ?? installedEditors.first
    }

    // MARK: Chrome

    enum Theme: String, CaseIterable { case system = "System", light = "Light", dark = "Dark" }
    private(set) var theme: Theme
    var terminalVisible: Bool { didSet { UserDefaults.standard.set(terminalVisible, forKey: Self.terminalKey) } }
    var terminalColorScheme: TerminalManager.ColorScheme {
        didSet {
            UserDefaults.standard.set(terminalColorScheme.rawValue, forKey: Self.terminalSchemeKey)
            TerminalManager.shared.colorScheme = terminalColorScheme
        }
    }
    var terminalGPU: Bool {
        didSet {
            UserDefaults.standard.set(terminalGPU, forKey: Self.terminalGPUKey)
            TerminalManager.shared.useGPU = terminalGPU
        }
    }

    // MARK: Quick open

    var quickOpenVisible = false
    private(set) var recentFiles: [QuickOpenEntry] = []
    /// Bumped whenever `fileIndex` is replaced, so the palette can re-run its query.
    private(set) var indexVersion = 0
    @ObservationIgnored private(set) var fileIndex: [QuickOpenEntry] = []
    @ObservationIgnored private var indexBuiltAt: Date?
    @ObservationIgnored private var indexTask: Task<Void, Never>?

    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var refreshing: Set<String> = []
    @ObservationIgnored private var refreshAgain: Set<String> = []
    @ObservationIgnored private var pendingWatchRepos: Set<String> = []
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var diffTask: Task<Void, Never>?
    @ObservationIgnored private var diffLineLimit: Int? = DiffDocument.defaultRowLimit
    @ObservationIgnored private var explorers: [String: ExplorerModel] = [:]
    /// Repos sorted longest path first, for mapping a changed file to its innermost repo.
    @ObservationIgnored private var reposByDepth: [Repo] = []

    private init() {
        theme = Theme(rawValue: UserDefaults.standard.string(forKey: Self.themeKey) ?? "") ?? .system
        terminalVisible = UserDefaults.standard.object(forKey: Self.terminalKey) as? Bool ?? true
        diffSideBySide = UserDefaults.standard.object(forKey: Self.diffLayoutKey) as? Bool ?? true
        repoSort = RepoSort(rawValue: UserDefaults.standard.string(forKey: Self.repoSortKey) ?? "") ?? .folder
        lastOpened = UserDefaults.standard.dictionary(forKey: Self.lastOpenedKey) as? [String: Double] ?? [:]
        openCounts = UserDefaults.standard.dictionary(forKey: Self.openCountsKey) as? [String: Int] ?? [:]
        showOnlyChanged = UserDefaults.standard.bool(forKey: Self.onlyChangedKey)
        preferredEditorID = UserDefaults.standard.string(forKey: Self.editorKey)
        reviewed = UserDefaults.standard.dictionary(forKey: Self.reviewedKey) as? [String: [String: String]] ?? [:]
        showLineBlame = UserDefaults.standard.object(forKey: Self.blameKey) as? Bool ?? true
        markdownPreview = UserDefaults.standard.bool(forKey: Self.markdownPreviewKey)
        vimMode = UserDefaults.standard.bool(forKey: Self.vimKey)
        terminalColorScheme = TerminalManager.ColorScheme(
            rawValue: UserDefaults.standard.string(forKey: Self.terminalSchemeKey) ?? ""
        ) ?? .dark
        terminalGPU = UserDefaults.standard.object(forKey: Self.terminalGPUKey) as? Bool ?? true
        TerminalManager.shared.colorScheme = terminalColorScheme
        TerminalManager.shared.useGPU = terminalGPU
        if let saved = UserDefaults.standard.string(forKey: Self.rootKey),
           FileManager.default.fileExists(atPath: saved) {
            Task { await open(root: saved) }
        }
    }

    // MARK: Derived

    var selectedRepo: Repo? { repos.first { $0.id == selectedRepoID } }
    var selectedStatus: RepoStatus? { selectedRepoID.flatMap { statuses[$0] } }
    var selectedFile: FileChange? { selectedStatus?.files.first { $0.id == selectedFileID } }

    var filteredRepos: [Repo] {
        var result = repos
        if showOnlyChanged {
            // Keep the selected repo, or committing its last change would yank the row away.
            result = result.filter { $0.id == selectedRepoID || (statuses[$0.id]?.needsAttention ?? false) }
        }
        let query = repoFilter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return result }
        return result.filter {
            $0.relativePath.localizedCaseInsensitiveContains(query)
                || (statuses[$0.id]?.branch?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var changedRepoCount: Int { repos.filter { statuses[$0.id]?.needsAttention ?? false }.count }

    /// Path relative to the workspace root (what "Copy Relative Path" puts on the clipboard).
    func rootRelativePath(repo: Repo, repoRelativePath: String) -> String {
        repo.relativePath.isEmpty ? repoRelativePath : repo.relativePath + "/" + repoRelativePath
    }

    // MARK: Root

    func chooseRoot() {
        guard confirmLeavingEditor() else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Root"
        panel.message = "Choose the folder that contains your git repos"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await open(root: url.path) }
    }

    func open(root: String) async {
        UserDefaults.standard.set(root, forKey: Self.rootKey)
        rootPath = RepoScanner.resolvedRoot(root)
        explorers.removeAll()
        fileTasks.values.forEach { $0.cancel() }
        fileTasks.removeAll()
        lastActiveTab.removeAll()
        tabList = TabList()
        tabSessions = [:]
        recentFiles.removeAll()
        await rescan()
    }

    func rescan() async {
        guard let rootPath else { return }
        isScanning = true
        let found = await Task.detached(priority: .userInitiated) { RepoScanner.scan(root: rootPath) }.value
        repos = found
        reposByDepth = found.sorted { $0.path.count > $1.path.count }
        statuses = statuses.filter { key, _ in found.contains { $0.id == key } }
        for path in tabList.paths where repo(forPath: path) == nil { // repo gone
            tabList.close(path)
            tabSessions[path] = nil
        }
        isScanning = false
        if selectedRepoID == nil || !found.contains(where: { $0.id == selectedRepoID }) {
            selectedRepoID = nil
            let last = UserDefaults.standard.string(forKey: Self.lastRepoKey)
            let restore = found.first { $0.id == last } ?? found.first
            selectRepo(restore?.id, recordOpen: false)
        }
        startWatching(rootPath)
        rebuildIndex()
        await refreshAll()
    }

    // MARK: Repo selection

    /// `recordOpen`: counts toward "Most Opened" (user picks, not the automatic launch selection).
    func selectRepo(_ id: String?, recordOpen: Bool = true) {
        guard id != selectedRepoID else { return }
        fileTasks.values.forEach { $0.cancel() }
        fileTasks.removeAll()
        // Every repo's tabs stay in the bar; show the file last active in the new repo (if any).
        if let id, tabList.active.flatMap({ repo(forPath: $0)?.id }) != id {
            let remembered = lastActiveTab[id].flatMap { tabList.contains($0) ? $0 : nil }
            tabList.setActive(remembered ?? tabList.paths.last { repo(forPath: $0)?.id == id })
        } else if id == nil {
            tabList.setActive(nil)
        }
        selectedRepoID = id
        if let id {
            UserDefaults.standard.set(id, forKey: Self.lastRepoKey)
            if recordOpen { noteRepoOpened(id) }
        }
        selectedFileID = nil
        diff = nil
        diffTask?.cancel()
        showDiffForOpenFile = false
        resetHistory()
        guard let repo = selectedRepo else {
            explorer = nil
            return
        }
        let model = explorers[repo.id] ?? ExplorerModel(repo: repo)
        explorers[repo.id] = model
        explorer = model
        if panel == .history { loadHistoryIfNeeded() }
        if panel == .search, !searchOptions.allRepos, !searchQuery.isEmpty { scheduleSearch(immediately: true) }
        if let active = tabList.active {
            model.reveal(relativePath: String(active.dropFirst(repo.path.count + 1)))
        } else if let path = model.selectedPath, FileManager.default.fileExists(atPath: path),
           !((try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? true) {
            openFile(path)
        }
        Task { await refresh(repo.id) }
    }

    // MARK: Repo list ordering

    private func noteRepoOpened(_ id: String) {
        lastOpened[id] = Date().timeIntervalSince1970
        UserDefaults.standard.set(lastOpened, forKey: Self.lastOpenedKey)
        openCounts[id, default: 0] += 1
        UserDefaults.standard.set(openCounts, forKey: Self.openCountsKey)
    }

    func setRepoSort(_ sort: RepoSort) {
        repoSort = sort
        UserDefaults.standard.set(sort.rawValue, forKey: Self.repoSortKey)
    }

    /// Most recently opened first, then never-opened repos A–Z.
    func rankedByRecent(_ repos: [Repo]) -> [Repo] {
        Self.rankByRecent(repos, lastOpened: lastOpened)
    }

    nonisolated static func rankByRecent(_ repos: [Repo], lastOpened: [String: Double]) -> [Repo] {
        repos.sorted { lhs, rhs in
            let (ta, tb) = (lastOpened[lhs.id] ?? 0, lastOpened[rhs.id] ?? 0)
            if ta != tb { return ta > tb }
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
    }

    /// Most opened first (ties: most recently opened), then never-opened repos A–Z.
    func rankedByMostOpened(_ repos: [Repo]) -> [Repo] {
        Self.rankByMostOpened(repos, counts: openCounts, lastOpened: lastOpened)
    }

    nonisolated static func rankByMostOpened(_ repos: [Repo], counts: [String: Int], lastOpened: [String: Double]) -> [Repo] {
        repos.sorted { lhs, rhs in
            let (ca, cb) = (counts[lhs.id] ?? 0, counts[rhs.id] ?? 0)
            if ca != cb { return ca > cb }
            let (ta, tb) = (lastOpened[lhs.id] ?? 0, lastOpened[rhs.id] ?? 0)
            if ta != tb { return ta > tb }
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
    }

    func focusRepoFilter() {
        sidebarVisible = true
        focusRepoFilterRequest += 1
    }

    // MARK: Status

    func refreshAll() async {
        let ids = repos.map(\.id)
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func addNext() {
                guard next < ids.count else { return }
                let id = ids[next]
                next += 1
                group.addTask { await self.refresh(id) }
            }
            for _ in 0..<min(Self.maxParallelGit, ids.count) { addNext() }
            while await group.next() != nil { addNext() }
        }
    }

    /// Coalesces overlapping refreshes of the same repo into one trailing run.
    func refresh(_ repoID: String) async {
        if refreshing.contains(repoID) {
            refreshAgain.insert(repoID)
            return
        }
        refreshing.insert(repoID)
        defer { refreshing.remove(repoID) }
        repeat {
            refreshAgain.remove(repoID)
            if let status = try? await GitCommands.status(repoID), statuses[repoID] != status {
                statuses[repoID] = status
            }
        } while refreshAgain.contains(repoID)

        if let status = statuses[repoID] {
            let fingerprints = await Task.detached(priority: .utility) {
                ReviewState.fingerprints(status, repoPath: repoID)
            }.value
            if currentFingerprints[repoID] != fingerprints { currentFingerprints[repoID] = fingerprints }
            pruneReviewed(repoID: repoID, keeping: Set(status.files.map(\.id)))
        }
        if repoID == selectedRepoID {
            reconcileSelectedFile()
            if panel == .history { loadHistoryIfNeeded() }
        }
    }

    // MARK: History

    var selectedCommit: CommitInfo? {
        commits.first { $0.sha == selectedCommitID } ?? (extraCommit?.sha == selectedCommitID ? extraCommit : nil)
    }

    var selectedCommitFile: CommitFile? { commitFiles.first { $0.id == selectedCommitFileID } }

    /// Changes when HEAD moves (commit/pull/switch) and when the unpushed set changes (push/fetch).
    private var currentHistoryKey: String? {
        selectedRepo.map {
            "\($0.id)|\(selectedStatus?.oid ?? "")|\(selectedStatus?.upstream ?? "")|\(selectedStatus?.ahead ?? 0)|\(historyPath ?? "")"
        }
    }

    func loadHistoryIfNeeded() {
        guard let key = currentHistoryKey, key != historyKey else { return }
        loadHistory(reset: true)
    }

    func loadMoreHistory() {
        guard hasMoreCommits, !isLoadingHistory else { return }
        loadHistory(reset: false)
    }

    private func loadHistory(reset: Bool) {
        guard let repo = selectedRepo else { return }
        let key = currentHistoryKey
        let skip = reset ? 0 : commits.count
        let paths = historyPath.map { [$0] } ?? []
        isLoadingHistory = true
        historyTask?.cancel()
        historyTask = Task {
            let page: [CommitInfo]
            do {
                page = try await GitCommands.log(repo.path, skip: skip, limit: Self.historyPage, paths: paths)
            } catch {
                page = [] // no commits yet, or not a repo anymore
            }
            let unpushed = await GitCommands.unpushed(repo.path)
            guard !Task.isCancelled, selectedRepoID == repo.id else { return }
            commits = reset ? page : commits + page
            hasMoreCommits = page.count == Self.historyPage
            unpushedCommits = unpushed
            historyKey = key
            isLoadingHistory = false
            if reset, selectedCommit == nil || !commits.contains(where: { $0.sha == selectedCommitID }) {
                if extraCommit?.sha != selectedCommitID || selectedCommitID == nil { selectCommit(commits.first?.sha) }
            }
        }
    }

    private func resetHistory() {
        historyTask?.cancel()
        commitTask?.cancel()
        commitDiffTask?.cancel()
        commits = []
        unpushedCommits = []
        hasMoreCommits = false
        isLoadingHistory = false
        historyKey = nil
        historyPath = nil
        extraCommit = nil
        selectedCommitID = nil
        selectedCommitMessage = nil
        commitFiles = []
        selectedCommitFileID = nil
        commitDiff = nil
    }

    func selectCommit(_ sha: String?) {
        guard sha != selectedCommitID || commitFiles.isEmpty else { return }
        selectedCommitID = sha
        selectedCommitMessage = nil
        commitFiles = []
        selectedCommitFileID = nil
        commitDiff = nil
        commitTask?.cancel()
        guard let repo = selectedRepo, let commit = selectedCommit else { return }
        commitTask = Task {
            let files = (try? await GitCommands.commitFiles(repo.path, commit: commit)) ?? []
            let message = try? await GitCommands.message(repo.path, sha: commit.sha)
            guard !Task.isCancelled, selectedCommitID == commit.sha else { return }
            commitFiles = files
            selectedCommitMessage = message
            // Filtered history: open the file (or the first file in the folder) being looked at.
            let focus = historyPath.flatMap { path in
                files.first { $0.path == path } ?? files.first { $0.path.hasPrefix(path + "/") }
            }
            selectCommitFile((focus ?? files.first)?.id)
        }
    }

    func selectCommitFile(_ id: String?) {
        if id != selectedCommitFileID { commitDiff = nil }
        selectedCommitFileID = id
        commitDiffTask?.cancel()
        guard let repo = selectedRepo, let commit = selectedCommit, let file = selectedCommitFile else {
            commitDiff = nil
            return
        }
        isLoadingCommitDiff = commitDiff == nil
        commitDiffTask = Task {
            defer { if !Task.isCancelled { isLoadingCommitDiff = false } }
            let document: DiffDocument
            do {
                let raw = try await GitCommands.commitDiff(repo.path, commit: commit, file: file)
                document = await Task.detached {
                    DiffDocument.build(from: raw, path: file.path, rowLimit: DiffDocument.defaultRowLimit)
                }.value
            } catch {
                document = .message(error.localizedDescription)
            }
            guard !Task.isCancelled, selectedCommitID == commit.sha, selectedCommitFileID == file.id else { return }
            commitDiff = document
        }
    }

    /// History of one file or folder (repo-relative); nil shows the whole repo again.
    func showHistory(forPath path: String?) {
        let path = path.flatMap { $0.isEmpty ? nil : $0 }
        repoPanelVisible = true
        if historyPath != path {
            historyPath = path
            historyTask?.cancel()
            commits = []
            hasMoreCommits = false
            extraCommit = nil
            selectedCommitID = nil
            historyKey = nil
        }
        // Path first: `panel`'s didSet loads with the current key.
        if panel == .history { loadHistoryIfNeeded() } else { panel = .history }
    }

    /// Opens a commit in the History panel (e.g. from a blame annotation), loading it if needed.
    func showCommit(_ sha: String) {
        repoPanelVisible = true
        panel = .history
        if commits.contains(where: { $0.sha == sha }) {
            selectCommit(sha)
            return
        }
        guard let repo = selectedRepo else { return }
        Task {
            guard let commit = try? await GitCommands.commit(repo.path, sha: sha), selectedRepoID == repo.id else { return }
            extraCommit = commit
            selectedCommitID = nil
            selectCommit(commit.sha)
        }
    }

    func copyToClipboard(_ text: String, toast: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showToast(toast)
    }

    // MARK: Search

    func showSearch() {
        repoPanelVisible = true
        panel = .search
        focusSearchRequest += 1
    }

    /// Live search: debounced, and results from an older query are dropped.
    func scheduleSearch(immediately: Bool = false) {
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        let query = searchQuery
        let options = searchOptions
        guard !query.isEmpty, let rootPath else {
            searchResults = SearchResults()
            isSearching = false
            return
        }
        // This repo (default) or every repo under the root.
        let repos = options.allRepos ? repos : selectedRepo.map { [$0] } ?? []
        isSearching = true
        searchTask = Task {
            if !immediately { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled, generation == searchGeneration else { return }
            let results = await WorkspaceSearch.search(query, options: options, repos: repos, root: rootPath)
            guard generation == searchGeneration else { return }
            searchResults = results
            isSearching = false
        }
    }

    func openSearchMatch(_ match: SearchMatch) {
        open(path: match.absolutePath, line: match.line, column: match.column,
             length: match.ranges.first?.length ?? 0, record: true)
    }

    // MARK: Open at a location

    /// Opens `path` (any repo) and reveals line/column, selecting `length` characters.
    func open(path: String, line: Int, column: Int = 1, length: Int = 0, record: Bool) {
        guard let repo = reposByDepth.first(where: { path.hasPrefix($0.path + "/") }) else { return }
        if record { recordJump() }
        if let controller = editor?.controller, editor?.path == path {
            controller.reveal(line: line, column: column, length: length)
            if panel != .search { panel = .files }
            return
        }
        if repo.id != selectedRepoID {
            selectRepo(repo.id)
            guard selectedRepoID == repo.id else { return }
        }
        pendingReveal = (path, line, column, length)
        openInEditor(repoRelativePath: String(path.dropFirst(repo.path.count + 1)))
    }

    // MARK: Vim actions

    private func handleVimAction(_ action: VimEngine.Action, path: String) {
        switch action {
        case .save: saveEditor()
        case .close: closeCurrent()
        case .saveAndClose:
            saveEditor()
            closeCurrent()
        case .jumpBack: navigateBack()
        case .jumpForward: navigateForward()
        case let .searchWord(word): searchSymbol(word, fromFile: path)
        }
    }

    // MARK: Close / go to line

    /// ⌘W: closes what the detail area shows (open file, selected diff, commit file). Never the window.
    func closeCurrent() {
        switch panel {
        case .files, .search:
            guard let active = tabList.active else { return NSSound.beep() }
            closeTabs([active])
        case .changes:
            guard selectedFileID != nil else { return NSSound.beep() }
            selectedFileID = nil
        case .history:
            guard selectedCommitFileID != nil else { return NSSound.beep() }
            selectCommitFile(nil)
        }
    }

    /// ⌃G: "line" or "line:column".
    func promptGoToLine() {
        guard let controller = editor?.controller, panel == .files || panel == .search else { return NSSound.beep() }
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        let lines = controller.text.reduce(into: 1) { count, character in if character == "\n" { count += 1 } }
        alert.informativeText = "Line (1–\(lines)), optionally :column"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = "e.g. 120 or 120:5"
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let parts = field.stringValue.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard let line = parts.first, line > 0 else { return }
        recordJump()
        controller.reveal(line: min(line, lines), column: parts.count > 1 ? max(1, parts[1]) : 1)
    }

    /// Find-bar actions (⌘F, ⌘G, ⇧⌘G, ⌥⌘F, ⌘E) for whichever text view has focus.
    func performFind(_ action: NSTextFinder.Action) {
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: sender)
    }

    /// Editing commands go to the focused editor through the responder chain (no-op elsewhere).
    func performEditorCommand(_ selector: Selector) {
        NSApp.sendAction(selector, to: nil, from: nil)
    }

    // MARK: Navigation history

    private var currentLocation: NavLocation? {
        guard let editor, let controller = editor.controller else { return nil }
        return NavLocation(path: editor.path, line: controller.caretLine() ?? 1, column: controller.caretColumn())
    }

    /// Remembers where the caret is before a jump (search result, ⌘P, explorer…).
    func recordJump() {
        guard let location = currentLocation else { return }
        if backStack.last != location { backStack.append(location) }
        if backStack.count > 100 { backStack.removeFirst(backStack.count - 100) }
        forwardStack.removeAll()
    }

    /// ⌥-
    func navigateBack() {
        guard let target = backStack.popLast() else { return NSSound.beep() }
        if let location = currentLocation { forwardStack.append(location) }
        open(path: target.path, line: target.line, column: target.column, record: false)
    }

    /// ⌥=
    func navigateForward() {
        guard let target = forwardStack.popLast() else { return NSSound.beep() }
        if let location = currentLocation { backStack.append(location) }
        open(path: target.path, line: target.line, column: target.column, record: false)
    }

    // MARK: Review marks

    func isReviewed(_ file: FileChange) -> Bool {
        guard let repoID = selectedRepoID, let marked = reviewed[repoID]?[file.id] else { return false }
        return marked == currentFingerprints[repoID]?[file.id]
    }

    func reviewedCount(_ files: [FileChange]) -> Int { files.filter(isReviewed).count }

    /// Marks / unmarks a file. Marking the selected file moves on to the next unreviewed one.
    func toggleReviewed(_ file: FileChange) {
        guard let repo = selectedRepo else { return }
        if isReviewed(file) {
            reviewed[repo.id]?[file.id] = nil
        } else {
            let fingerprint = currentFingerprints[repo.id]?[file.id] ?? ReviewState.fingerprint(file, repoPath: repo.id)
            reviewed[repo.id, default: [:]][file.id] = fingerprint
            if currentFingerprints[repo.id]?[file.id] == nil { currentFingerprints[repo.id, default: [:]][file.id] = fingerprint }
            // Only in Changes: in the Files panel's Diff view the editor header would show another file.
            if panel == .changes, file.id == selectedFileID, let next = nextUnreviewed(after: file) {
                selectedFileID = next.id
            }
        }
        saveReviewed()
    }

    /// ⌥⌘V
    func toggleReviewedForSelected() {
        if let file = selectedFile { toggleReviewed(file) }
    }

    private func nextUnreviewed(after file: FileChange) -> FileChange? {
        guard let status = selectedStatus else { return nil }
        let ordered = ChangeArea.sections.flatMap { status.sectionFiles($0) }
        guard let index = ordered.firstIndex(of: file) else { return nil }
        return (ordered[(index + 1)...] + ordered[..<index]).first { !isReviewed($0) }
    }

    private func pruneReviewed(repoID: String, keeping ids: Set<String>) {
        guard let marks = reviewed[repoID] else { return }
        let kept = marks.filter { ids.contains($0.key) }
        guard kept.count != marks.count else { return }
        reviewed[repoID] = kept.isEmpty ? nil : kept
        saveReviewed()
    }

    private func saveReviewed() {
        UserDefaults.standard.set(reviewed, forKey: Self.reviewedKey)
    }

    private func reconcileSelectedFile() {
        guard let status = selectedStatus else { return }
        if let id = selectedFileID, !status.files.contains(where: { $0.id == id }) {
            selectedFileID = nil
            diff = nil
        } else if selectedFileID != nil {
            loadDiff(resetLimit: false) // file may have changed on disk
        }
    }

    // MARK: Watching

    private func startWatching(_ root: String) {
        watcher?.stop()
        watcher = FileWatcher(path: root) { [weak self] paths in
            MainActor.assumeIsolated { self?.handleFileEvents(paths) }
        }
    }

    private func handleFileEvents(_ paths: [String]) {
        for path in paths where FileWatcher.isRelevant(path) {
            if let repo = reposByDepth.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }) {
                pendingWatchRepos.insert(repo.id)
            }
        }
        guard !pendingWatchRepos.isEmpty else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            let ids = self.pendingWatchRepos
            self.pendingWatchRepos.removeAll()
            for id in ids {
                Task { await self.refresh(id) }
                self.explorers[id]?.reload()
            }
            for id in ids { self.reloadTabs(repoID: id) }
        }
    }

    // MARK: Diff

    func loadDiff(resetLimit: Bool = true) {
        if resetLimit { diffLineLimit = DiffDocument.defaultRowLimit }
        diffTask?.cancel()
        guard let repo = selectedRepo, let file = selectedFile else {
            diff = nil
            diffFileID = nil
            return
        }
        let limit = diffLineLimit
        let fileID = file.id
        let path = file.path
        isLoadingDiff = diff == nil
        diffTask = Task {
            defer { if !Task.isCancelled { isLoadingDiff = false } }
            let document: DiffDocument
            do {
                let raw = try await GitCommands.diff(repo.path, file: file)
                document = await Task.detached { DiffDocument.build(from: raw, path: path, rowLimit: limit) }.value
            } catch {
                document = .message(error.localizedDescription)
            }
            guard !Task.isCancelled, selectedFileID == fileID else { return }
            diff = document
            diffFileID = fileID // set together, so the view knows a new file vs a reload
        }
    }

    func setDiffSideBySide(_ value: Bool) {
        diffSideBySide = value
        UserDefaults.standard.set(value, forKey: Self.diffLayoutKey)
    }

    func showFullDiff() {
        diffLineLimit = nil
        loadDiff(resetLimit: false)
    }

    // MARK: New file / folder

    struct CreateItemError: LocalizedError {
        let errorDescription: String?
    }

    /// Where New File / New Folder goes: the given row (its parent for a file), else the explorer
    /// selection, else the repo root.
    func creationDirectory(for node: FileNode?) -> String? {
        guard let repo = selectedRepo else { return nil }
        if let node { return node.isDirectory ? node.path : (node.path as NSString).deletingLastPathComponent }
        if let selected = explorer?.selectedPath, selected.hasPrefix(repo.path + "/") {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: selected, isDirectory: &isDirectory) {
                return isDirectory.boolValue ? selected : (selected as NSString).deletingLastPathComponent
            }
        }
        return repo.path
    }

    /// Asks for a name, creates the file or folder, then opens the file / reveals the folder.
    func promptNewItem(folder: Bool, in node: FileNode? = nil) {
        guard let repo = selectedRepo, let dir = creationDirectory(for: node) else { return NSSound.beep() }
        let alert = NSAlert()
        alert.messageText = folder ? "New Folder" : "New File"
        let location = dir == repo.path ? repo.name : repo.name + "/" + String(dir.dropFirst(repo.path.count + 1))
        alert.informativeText = "In \(location)/\nUse / for nested folders, e.g. utils/format.ts"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = folder ? "folder name" : "file name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let relative = try Self.createItem(named: field.stringValue, folder: folder, in: dir, repoPath: repo.path)
            explorer?.reload()
            if folder {
                panel = .files
                explorer?.reveal(relativePath: relative)
            } else {
                openInEditor(repoRelativePath: relative, preview: false)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Creates `name` (may contain `/`) under `dir`; returns its repo-relative path.
    @discardableResult
    nonisolated static func createItem(named name: String, folder: Bool, in dir: String, repoPath: String) throws -> String {
        var name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasSuffix("/") { name.removeLast() }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard !name.isEmpty, !name.hasPrefix("/"), !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw CreateItemError(errorDescription: "“\(name)” isn't a valid name.")
        }
        let path = dir + "/" + name
        guard path.hasPrefix(repoPath + "/") else { throw CreateItemError(errorDescription: "Can't create outside the repo.") }
        let manager = FileManager.default
        guard !manager.fileExists(atPath: path) else {
            throw CreateItemError(errorDescription: "“\(name)” already exists.")
        }
        if folder {
            try manager.createDirectory(atPath: path, withIntermediateDirectories: true)
        } else {
            try manager.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            guard manager.createFile(atPath: path, contents: Data()) else {
                throw CreateItemError(errorDescription: "Couldn't create “\(name)”.")
            }
        }
        return String(path.dropFirst(repoPath.count + 1))
    }

    // MARK: Explorer / editor

    /// The change entry for a repo-relative path, preferring the working-tree side.
    func change(forRelativePath path: String) -> FileChange? {
        let files = selectedStatus?.files.filter { $0.path == path } ?? []
        return files.first { $0.area != .staged } ?? files.first
    }

    func explorerSelect(_ path: String?) {
        guard let explorer, let path, let row = explorer.rows.first(where: { $0.id == path }) else { return }
        if row.node.isDirectory {
            explorer.selectedPath = path
            explorer.toggle(row.node)
            return
        }
        guard path != editor?.path else {
            explorer.selectedPath = path
            return
        }
        recordJump()
        explorer.selectedPath = path
        openFile(path)
    }

    /// Opens a repo-relative file of the selected repo in the Files panel.
    /// `preview`: VS Code's preview tab (replaced by the next preview open until it's edited or pinned).
    func openInEditor(repoRelativePath: String, preview: Bool = true) {
        guard let explorer, let repo = selectedRepo else { return }
        let path = repo.path + "/" + repoRelativePath
        if path != editor?.path { openFile(path, preview: preview) } else if !preview { tabList.pin(path) }
        if panel != .search { panel = .files } // search results stay visible while browsing matches
        showDiffForOpenFile = false
        explorer.reveal(relativePath: repoRelativePath)
    }

    func setShowDiffForOpenFile(_ show: Bool) {
        showDiffForOpenFile = show
        guard show, let repo = selectedRepo, let editor else { return }
        let relative = String(editor.path.dropFirst(repo.path.count + 1))
        if let change = change(forRelativePath: relative) {
            selectedFileID = change.id // onChange → loadDiff
        }
    }

    private func openFile(_ path: String, preview: Bool = true) {
        showDiffForOpenFile = false
        if let session = tabSessions[path] {
            tabList.open(path, asPreview: preview)
            if let repoID = repo(forPath: path)?.id { lastActiveTab[repoID] = path }
            noteRecent(path)
            applyPendingReveal(path, controller: session.controller)
            return
        }
        guard fileTasks[path] == nil else { return }
        fileTasks[path] = Task {
            defer { fileTasks[path] = nil }
            let content = await Task.detached(priority: .userInitiated) { FileContent.load(path: path) }.value
            // Dropped if the user switched to another repo meanwhile.
            guard !Task.isCancelled, let selected = selectedRepo, path.hasPrefix(selected.path + "/") else { return }
            // The innermost repo: a nested repo's file opened from its parent repo's explorer blames in the nested one.
            let repo = repo(forPath: path) ?? selected
            let session = EditorSession(
                content: content,
                referencePath: workspaceRelative(path),
                onReferenceCopied: { [weak self] in self?.showToast("Copied \($0)") }
            )
            if let controller = session.controller {
                controller.blameEnabled = showLineBlame
                controller.onCommandClick = { [weak self] word in self?.searchSymbol(word, fromFile: path) }
                controller.onVimAction = { [weak self] action in self?.handleVimAction(action, path: path) }
                controller.vimEnabled = vimMode
                controller.blameContext = EditorController.BlameContext(
                    repoPath: repo.path,
                    relativePath: String(path.dropFirst(repo.path.count + 1)),
                    openCommit: { [weak self] sha in self?.showCommit(sha) }
                )
            }
            let previewDirty = tabList.preview.flatMap { tabSessions[$0]?.isDirty } ?? false
            tabSessions[path] = session
            if let replaced = tabList.open(path, asPreview: preview, previewIsDirty: previewDirty) {
                tabSessions[replaced] = nil
            }
            lastActiveTab[repo.id] = path
            noteRecent(path)
            applyPendingReveal(path, controller: session.controller)
        }
    }

    private func applyPendingReveal(_ path: String, controller: EditorController?) {
        guard let reveal = pendingReveal, reveal.path == path, let controller else { return }
        pendingReveal = nil
        DispatchQueue.main.async {
            controller.reveal(line: reveal.line, column: reveal.column, length: reveal.length)
        }
    }

    // MARK: Tabs

    /// Shows a tab; a tab from another repo selects that repo (sidebar, explorer, changes follow).
    func activateTab(_ path: String) {
        guard tabList.contains(path), path != tabList.active else { return }
        recordJump()
        tabList.activate(path)
        showDiffForOpenFile = false
        guard let repo = repo(forPath: path) else { return }
        lastActiveTab[repo.id] = path
        if repo.id != selectedRepoID {
            selectRepo(repo.id, recordOpen: false) // keeps this tab active and reveals it
        } else {
            explorer?.reveal(relativePath: String(path.dropFirst(repo.path.count + 1)))
        }
    }

    /// Keeps a preview tab open (double-click on the tab).
    func pinTab(_ path: String) { tabList.pin(path) }

    /// ⌃Tab / ⌃⇧Tab.
    func cycleTab(_ offset: Int) {
        guard tabList.paths.count > 1, let next = tabList.neighbor(offset) else { return NSSound.beep() }
        activateTab(next)
    }

    func closeOtherTabs(_ path: String) { closeTabs(tabList.others(than: path)) }
    func closeTabsToRight(_ path: String) { closeTabs(tabList.right(of: path)) }
    func closeAllTabs() { closeTabs(tabList.paths) }

    /// Closes tabs after asking about unsaved edits (Cancel keeps all of them open).
    func closeTabs(_ paths: [String]) {
        guard !paths.isEmpty, confirmClosing(paths.compactMap { tabSessions[$0] }) else { return }
        let wasActive = tabList.active
        for path in paths {
            fileTasks[path]?.cancel()
            fileTasks[path] = nil
            // Stay in the selected repo: the nearest tab of it, else none.
            tabList.close(path) { [selectedRepoID] in self.repo(forPath: $0)?.id == selectedRepoID }
            tabSessions[path] = nil
        }
        // A repo left without tabs mustn't reopen the closed file when it's selected again.
        for repoID in Set(paths.compactMap { repo(forPath: $0)?.id })
        where !tabList.paths.contains(where: { repo(forPath: $0)?.id == repoID }) {
            lastActiveTab[repoID] = nil
            explorers[repoID]?.selectedPath = nil
        }
        guard tabList.active != wasActive else { return }
        showDiffForOpenFile = false
        if let active = tabList.active, let repo = selectedRepo, active.hasPrefix(repo.path + "/") {
            lastActiveTab[repo.id] = active
            explorer?.reveal(relativePath: String(active.dropFirst(repo.path.count + 1)))
        } else {
            explorer?.selectedPath = nil // so clicking the same file reopens it
        }
    }

    /// Reloads clean tabs of `repoID` from disk; closes clean tabs whose file is gone.
    private func reloadTabs(repoID: String) {
        var gone: [String] = []
        for session in tabSessions.values where repo(forPath: session.path)?.id == repoID {
            if !session.isDirty, !FileManager.default.fileExists(atPath: session.path) {
                gone.append(session.path)
            } else {
                session.reloadFromDiskIfClean()
            }
        }
        if !gone.isEmpty { closeTabs(gone) } // all clean: no prompt
    }

    /// Path relative to the workspace root (falls back to the absolute path outside it).
    func workspaceRelative(_ path: String) -> String {
        guard let rootPath, path.hasPrefix(rootPath + "/") else { return path }
        return String(path.dropFirst(rootPath.count + 1))
    }

    /// ⇧⌘C: copy "path:line(s)" for the caret/selection in the focused editor or diff view.
    func copyReference() {
        let responder = NSApp.keyWindow?.firstResponder
        if let controller = editor?.controller, responder === controller.textView {
            controller.copyReference()
        } else if let host = DiffReference.activeHost, host.window != nil {
            host.copyReference()
        } else {
            editor?.controller?.copyReference()
        }
    }

    /// Absolute path of the file shown in the diff view (working-tree change, or a commit's file).
    var diffAbsolutePath: String? {
        guard let repo = selectedRepo else { return nil }
        if panel == .history { return selectedCommitFile.map { repo.path + "/" + $0.path } }
        return selectedFile.map { repo.path + "/" + $0.path }
    }

    /// ⇧⌘V: toggles between source and preview (switching to the file view if the diff was showing).
    func toggleMarkdownPreview() {
        guard isMarkdownOpen else { return }
        if showDiffForOpenFile {
            showDiffForOpenFile = false
            markdownPreview = true
        } else {
            markdownPreview.toggle()
        }
    }

    /// A file link clicked in the markdown preview: open it here when it's inside the selected repo.
    func openLocalFile(_ url: URL) -> Bool {
        guard let repo = selectedRepo else { return false }
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(repo.path + "/"), FileManager.default.fileExists(atPath: path) else { return false }
        openInEditor(repoRelativePath: String(path.dropFirst(repo.path.count + 1)))
        return true
    }

    /// Workspace-root-relative path of the change shown in the diff view.
    var diffReferencePath: String {
        diffAbsolutePath.map(workspaceRelative) ?? ""
    }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            toast = nil
        }
    }

    func saveEditor() {
        guard let editor, editor.isDirty else { return }
        do {
            try editor.save()
        } catch {
            errorMessage = "Could not save \(editor.path): \(error.localizedDescription)"
        }
    }

    /// Before quitting or opening another root: asks about unsaved edits in every repo's tabs.
    func confirmLeavingEditor() -> Bool { confirmClosing(allSessions) }

    /// Asks to save unsaved edits among `sessions`. Returns false if the user cancelled.
    func confirmClosing(_ sessions: [EditorSession]) -> Bool {
        let dirty = sessions.filter(\.isDirty)
        guard !dirty.isEmpty else { return true }
        let alert = NSAlert()
        if dirty.count == 1 {
            alert.messageText = "Save changes to \((dirty[0].path as NSString).lastPathComponent)?"
            alert.informativeText = "Your changes will be lost if you don't save them."
            alert.addButton(withTitle: "Save")
        } else {
            alert.messageText = "Save changes to \(dirty.count) files?"
            alert.informativeText = dirty.map { workspaceRelative($0.path) }.joined(separator: "\n")
            alert.addButton(withTitle: "Save All")
        }
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            do {
                for session in dirty { try session.save() }
                return true
            } catch {
                errorMessage = "Could not save: \(error.localizedDescription)"
                return false
            }
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    // MARK: Staging actions

    func stage(_ files: [FileChange]) {
        runGit { repo in try await GitCommands.stage(repo, paths: files.map(\.path)) }
    }

    func unstage(_ files: [FileChange]) {
        runGit { repo in try await GitCommands.unstage(repo, files: files) }
    }

    func discard(_ files: [FileChange]) {
        guard !files.isEmpty else { return }
        let tracked = files.filter { $0.area == .unstaged }
        let untracked = files.filter { $0.area == .untracked }
        let name = files.count == 1 ? "'\(files[0].fileName)'" : "\(files.count) files"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard changes to \(name)?"
        alert.informativeText = untracked.isEmpty
            ? "This can't be undone."
            : "Tracked changes can't be recovered. Untracked files will be moved to the Trash."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        runGit { repo in
            try await GitCommands.discard(repo, paths: tracked.map(\.path))
            try GitCommands.trashUntracked(repo, paths: untracked.map(\.path))
        }
    }

    private func runGit(_ work: @escaping (String) async throws -> Void) {
        guard let repo = selectedRepo else { return }
        Task {
            do {
                try await work(repo.path)
            } catch {
                errorMessage = error.localizedDescription
            }
            await refresh(repo.id)
            reloadTabs(repoID: repo.id)
        }
    }

    // MARK: Commit

    var commitMessage: String {
        get { selectedRepoID.flatMap { commitDrafts[$0] } ?? "" }
        set { if let id = selectedRepoID { commitDrafts[id] = newValue } }
    }

    var canCommit: Bool {
        !isCommitting && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !(selectedStatus?.files.isEmpty ?? true)
    }

    /// Commits staged changes. With nothing staged, offers to stage everything first (VS Code's
    /// "smart commit"). `noVerify` skips pre-commit / commit-msg hooks.
    func commit(noVerify: Bool) {
        guard canCommit, let repo = selectedRepo, let status = selectedStatus else { return }
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        var stageAll = false
        if status.files(in: .staged).isEmpty {
            let alert = NSAlert()
            alert.messageText = "There are no staged changes to commit."
            alert.informativeText = "Stage all \(status.changedCount) changed files and commit them?"
            alert.addButton(withTitle: "Stage All & Commit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            stageAll = true
        }
        isCommitting = true
        Task {
            defer { isCommitting = false }
            do {
                if stageAll { try await GitCommands.stageAll(repo.path) }
                try await GitCommands.commit(repo.path, message: message, noVerify: noVerify)
                commitDrafts[repo.id] = nil
            } catch {
                let detail = error.localizedDescription
                errorMessage = "Commit failed\(noVerify ? "" : " (hooks ran)"):\n" + String(detail.suffix(4000))
            }
            await refresh(repo.id)
        }
    }

    // MARK: Branches

    func branches() async -> [BranchInfo] {
        guard let repo = selectedRepo else { return [] }
        do {
            return try await GitCommands.branches(repo.path)
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    func switchBranch(_ branch: BranchInfo) async {
        guard let repo = selectedRepo else { return }
        do {
            try await GitCommands.switchBranch(repo.path, to: branch)
        } catch {
            errorMessage = error.localizedDescription
        }
        await refresh(repo.id)
        explorers[repo.id]?.reload()
        reloadTabs(repoID: repo.id)
    }

    func fetchSelected() async { await sync(.fetch) }

    func sync(_ operation: SyncOperation) async {
        guard let repo = selectedRepo, syncing == nil else { return }
        let hasUpstream = statuses[repo.id]?.upstream != nil
        syncing = operation
        defer { syncing = nil }
        do {
            switch operation {
            case .fetch: try await GitCommands.fetch(repo.path)
            case .pull: try await GitCommands.pull(repo.path)
            case .push: try await GitCommands.push(repo.path, hasUpstream: hasUpstream)
            }
            if operation != .fetch { showToast(operation == .pull ? "Pulled" : "Pushed") }
        } catch {
            errorMessage = "\(operation == .push ? "Push" : operation == .pull ? "Pull" : "Fetch") failed:\n"
                + String(error.localizedDescription.suffix(4000))
        }
        await refresh(repo.id)
        if operation == .pull {
            explorers[repo.id]?.reload()
            reloadTabs(repoID: repo.id)
        }
    }

    // MARK: Quick open

    func showQuickOpen() {
        quickOpenVisible = true
        if let built = indexBuiltAt, Date().timeIntervalSince(built) < 30 { return }
        rebuildIndex()
    }

    private func rebuildIndex() {
        indexTask?.cancel()
        let repos = repos
        indexTask = Task {
            let entries = await FileIndex.build(repos: repos)
            guard !Task.isCancelled else { return }
            fileIndex = entries
            indexBuiltAt = Date()
            indexVersion += 1
        }
    }

    func openQuickOpenEntry(_ entry: QuickOpenEntry) {
        quickOpenVisible = false
        recordJump()
        if entry.repoID != selectedRepoID {
            selectRepo(entry.repoID)
            guard selectedRepoID == entry.repoID else { return }
        }
        // A deliberate pick: its own tab, never replacing the preview tab.
        openInEditor(repoRelativePath: entry.repoRelativePath, preview: false)
    }

    private func noteRecent(_ path: String) {
        guard let repo = reposByDepth.first(where: { path.hasPrefix($0.path + "/") }) else { return }
        let entry = QuickOpenEntry(repo: repo, repoRelativePath: String(path.dropFirst(repo.path.count + 1)))
        recentFiles.removeAll { $0.id == entry.id }
        recentFiles.insert(entry, at: 0)
        if recentFiles.count > 15 { recentFiles.removeLast() }
    }

    // MARK: Open in editor / Finder

    func setPreferredEditor(_ editor: ExternalEditor) {
        preferredEditorID = editor.id
        UserDefaults.standard.set(editor.id, forKey: Self.editorKey)
    }

    /// Opens the file's git repo as the editor's workspace, with the file at `line`.
    func openExternally(path: String, line: Int? = nil, editor: ExternalEditor? = nil) {
        guard let target = editor ?? preferredEditor else {
            errorMessage = "No supported code editor found (VS Code, Cursor, Windsurf, Zed, Sublime Text, Xcode)."
            return
        }
        if let editor { setPreferredEditor(editor) }
        let repo = reposByDepth.first { path == $0.path || path.hasPrefix($0.path + "/") }?.path
        let isFile = !((try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
        target.open(repo: repo, file: isFile && path != repo ? path : nil, line: line)
    }

    // MARK: ⌘-click → search

    /// ⌘-click on a name: search the file's repo for it (exact case, whole word) in files of the same language.
    func searchSymbol(_ word: String, fromFile path: String?) {
        searchQuery = word
        searchOptions = WorkspaceSearchOptions(
            matchCase: true, wholeWord: true, regex: false,
            include: path.map(Self.languageGlobs) ?? "", exclude: WorkspaceSearchOptions.defaultExclude,
            allRepos: false
        )
        showSearch()
        scheduleSearch(immediately: true)
    }

    /// Globs for the language family of `path` ("a.ts" → "*.ts, *.tsx, *.mts, *.cts").
    nonisolated static func languageGlobs(_ path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        let families: [[String]] = [
            ["ts", "tsx", "mts", "cts"], ["js", "jsx", "mjs", "cjs"], ["py", "pyi"], ["kt", "kts"],
            ["c", "h"], ["cpp", "cc", "cxx", "hpp", "hh", "h"], ["md", "mdx", "markdown"], ["yml", "yaml"],
            ["sh", "bash", "zsh"], ["css", "scss", "sass", "less"], ["html", "htm"],
        ]
        guard !ext.isEmpty else { return "" }
        let family = families.first { $0.contains(ext) } ?? [ext]
        return family.map { "*.\($0)" }.joined(separator: ", ")
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// The file (and caret line) the user is looking at: focused editor, focused diff, then the
    /// open file or selected change.
    func focusedLocation() -> (path: String, line: Int?)? {
        let responder = NSApp.keyWindow?.firstResponder
        if let editor, let controller = editor.controller, responder === controller.textView {
            return (editor.path, controller.caretLine())
        }
        if let host = DiffReference.activeHost, host.window != nil, let path = diffAbsolutePath {
            return (path, host.caretLine())
        }
        if panel == .files, let editor { return (editor.path, editor.controller?.caretLine()) }
        if let path = diffAbsolutePath { return (path, nil) }
        return nil
    }

    /// ⇧⌘E
    func openFocusedExternally() {
        guard let location = focusedLocation() else { return }
        openExternally(path: location.path, line: location.line)
    }

    /// ⌥⌘R
    func revealFocusedInFinder() {
        if let location = focusedLocation() {
            revealInFinder(location.path)
        } else if let repo = selectedRepo {
            revealInFinder(repo.path)
        }
    }

    // MARK: Theme / terminal

    func setTheme(_ theme: Theme) {
        self.theme = theme
        UserDefaults.standard.set(theme.rawValue, forKey: Self.themeKey)
        applyTheme()
    }

    func cycleTheme() {
        let all = Theme.allCases
        setTheme(all[(all.firstIndex(of: theme)! + 1) % all.count])
    }

    func applyTheme() {
        switch theme {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        TerminalManager.shared.applyAppearance()
    }

    func relaunchTerminal() {
        guard let repo = selectedRepo else { return }
        terminalVisible = true
        TerminalManager.shared.relaunch(repo)
    }
}
