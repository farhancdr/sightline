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
    private static let lastRepoKey = "lastRepoPath"
    private static let maxParallelGit = 8

    // MARK: Workspace

    private(set) var rootPath: String?
    private(set) var repos: [Repo] = []
    private(set) var statuses: [String: RepoStatus] = [:]
    private(set) var isScanning = false
    private(set) var isFetching = false
    private(set) var selectedRepoID: String?
    var repoFilter = ""

    enum RepoSort: String, CaseIterable { case folder = "By Folder", recent = "Recent" }
    private(set) var repoSort: RepoSort
    /// When each repo (by path) was last opened from the sidebar / ⌘P, for "Recent".
    private(set) var lastOpened: [String: Double]

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

    // MARK: Files / editor

    enum Panel: String, CaseIterable { case changes = "Changes", files = "Files" }
    var panel: Panel = .changes
    private(set) var explorer: ExplorerModel?
    private(set) var editor: EditorSession?
    /// In the Files panel, show the diff of the open file instead of the editor.
    var showDiffForOpenFile = false
    /// Short confirmation shown in the file header ("Copied path:12-30").
    private(set) var toast: String?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    // MARK: Chrome

    enum Theme: String, CaseIterable { case system = "System", light = "Light", dark = "Dark" }
    private(set) var theme: Theme
    var terminalVisible: Bool { didSet { UserDefaults.standard.set(terminalVisible, forKey: Self.terminalKey) } }

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
    @ObservationIgnored private var fileTask: Task<Void, Never>?
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
        let query = repoFilter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return repos }
        return repos.filter {
            $0.relativePath.localizedCaseInsensitiveContains(query)
                || (statuses[$0.id]?.branch?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

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
        guard id != selectedRepoID, confirmLeavingEditor() else { return }
        selectedRepoID = id
        if let id {
            UserDefaults.standard.set(id, forKey: Self.lastRepoKey)
            if recordOpen { noteRepoOpened(id) }
        }
        selectedFileID = nil
        diff = nil
        diffTask?.cancel()
        fileTask?.cancel()
        editor = nil
        showDiffForOpenFile = false
        guard let repo = selectedRepo else {
            explorer = nil
            return
        }
        let model = explorers[repo.id] ?? ExplorerModel(repo: repo)
        explorers[repo.id] = model
        explorer = model
        if let path = model.selectedPath, FileManager.default.fileExists(atPath: path),
           !((try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? true) {
            openFile(path)
        }
        Task { await refresh(repo.id) }
    }

    // MARK: Repo list ordering

    private func noteRepoOpened(_ id: String) {
        lastOpened[id] = Date().timeIntervalSince1970
        UserDefaults.standard.set(lastOpened, forKey: Self.lastOpenedKey)
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

        if repoID == selectedRepoID { reconcileSelectedFile() }
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
            if let selected = self.selectedRepoID, ids.contains(selected) {
                self.editor?.reloadFromDiskIfClean()
            }
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
        guard confirmLeavingEditor() else { return }
        explorer.selectedPath = path
        showDiffForOpenFile = false
        openFile(path)
    }

    /// Opens a repo-relative file of the selected repo in the Files panel.
    func openInEditor(repoRelativePath: String) {
        guard let explorer, let repo = selectedRepo else { return }
        let path = repo.path + "/" + repoRelativePath
        if path != editor?.path {
            guard confirmLeavingEditor() else { return }
            openFile(path)
        }
        panel = .files
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

    private func openFile(_ path: String) {
        fileTask?.cancel()
        fileTask = Task {
            let content = await Task.detached(priority: .userInitiated) { FileContent.load(path: path) }.value
            guard !Task.isCancelled else { return }
            editor = EditorSession(
                content: content,
                referencePath: workspaceRelative(path),
                onReferenceCopied: { [weak self] in self?.showToast("Copied \($0)") }
            )
            noteRecent(path)
        }
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

    /// Workspace-root-relative path of the change shown in the diff view.
    var diffReferencePath: String {
        guard let repo = selectedRepo, let file = selectedFile else { return "" }
        return workspaceRelative(repo.path + "/" + file.path)
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

    /// Asks to save unsaved edits. Returns false if the user cancelled.
    func confirmLeavingEditor() -> Bool {
        guard let editor, editor.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to \((editor.path as NSString).lastPathComponent)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            do {
                try editor.save()
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
            editor?.reloadFromDiskIfClean()
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
        editor?.reloadFromDiskIfClean()
    }

    func fetchSelected() async {
        guard let repo = selectedRepo, !isFetching else { return }
        isFetching = true
        defer { isFetching = false }
        do {
            try await GitCommands.fetch(repo.path)
        } catch {
            errorMessage = error.localizedDescription
        }
        await refresh(repo.id)
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
        if entry.repoID != selectedRepoID {
            guard confirmLeavingEditor() else { return }
            // Discard check already done; don't ask twice.
            editor = nil
            selectRepo(entry.repoID)
            guard selectedRepoID == entry.repoID else { return }
        }
        openInEditor(repoRelativePath: entry.repoRelativePath)
    }

    private func noteRecent(_ path: String) {
        guard let repo = reposByDepth.first(where: { path.hasPrefix($0.path + "/") }) else { return }
        let entry = QuickOpenEntry(repo: repo, repoRelativePath: String(path.dropFirst(repo.path.count + 1)))
        recentFiles.removeAll { $0.id == entry.id }
        recentFiles.insert(entry, at: 0)
        if recentFiles.count > 15 { recentFiles.removeLast() }
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
