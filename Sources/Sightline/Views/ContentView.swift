import SwiftUI

struct ContentView: View {
    @Bindable var store: AppStore
    @AppStorage("repoPanelWidth") private var panelWidth: Double = 300

    var body: some View {
        Group {
            if store.rootPath == nil {
                welcome
            } else {
                // Two columns so ⌘B (repo sidebar) and ⇧⌘B (Changes/Files column) toggle independently;
                // a three-column NavigationSplitView can't hide only the middle column.
                NavigationSplitView(columnVisibility: Binding(
                    get: { store.sidebarVisible ? .all : .detailOnly },
                    set: { store.sidebarVisible = $0 != .detailOnly }
                )) {
                    SidebarView(store: store)
                        .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 400)
                } detail: {
                    if let repo = store.selectedRepo {
                        HStack(spacing: 0) {
                            if store.repoPanelVisible {
                                RepoPanel(store: store)
                                    .frame(width: panelWidth)
                                    .background(Color.ghSidebar)
                                ResizeHandle(width: $panelWidth, range: 220...560)
                            }
                            VSplitView {
                                Group {
                                    switch store.panel {
                                    case .files, .search: FilePane(store: store)
                                    case .changes: DiffPane(store: store)
                                    case .history: CommitPane(store: store)
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: 120, idealHeight: 460, maxHeight: .infinity)
                                if store.terminalVisible {
                                    TerminalPane(repo: repo)
                                        .frame(maxWidth: .infinity, minHeight: 100, idealHeight: 280, maxHeight: .infinity)
                                }
                            }
                            .background(Color.ghCanvas)
                        }
                    } else {
                        Text("Select a repo").foregroundStyle(Color.ghMuted)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.ghCanvas)
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            if store.quickOpenVisible {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.08)
                        .ignoresSafeArea()
                        .onTapGesture { store.quickOpenVisible = false }
                    QuickOpenView(store: store).padding(.top, 8)
                }
            }
        }
        .navigationTitle(store.selectedRepo.map { $0.relativePath.isEmpty ? $0.name : $0.relativePath } ?? "Sightline")
        .navigationSubtitle(store.selectedStatus?.headLabel ?? "")
        .toolbar {
            ToolbarItemGroup {
                Button { store.showQuickOpen() } label: { Image(systemName: "magnifyingglass") }
                    .help("Go to File… (⌘P)")
                Button { store.vimMode.toggle() } label: {
                    Text("VIM")
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .foregroundStyle(store.vimMode ? Color.white : Color.ghMuted)
                        .background(store.vimMode ? Color.ghAdded : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(store.vimMode ? Color.clear : Color.ghMuted, lineWidth: 1))
                }
                .help(store.vimMode ? "Vim mode is on. Click to turn it off." : "Turn on Vim mode in the editor")
                Button { store.terminalVisible.toggle() } label: {
                    Image(systemName: store.terminalVisible ? "terminal.fill" : "terminal")
                }
                .help("Toggle Terminal (⌘J)")
                Menu {
                    Picker("Theme", selection: Binding(get: { store.theme }, set: { store.setTheme($0) })) {
                        ForEach(AppStore.Theme.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: themeSymbol)
                }
                .help("Theme")
                Button { Task { await store.refreshAll() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh all repos (⌘R)")
                Button { store.chooseRoot() } label: { Image(systemName: "folder") }
                    .help("Choose root folder")
            }
        }
        .onChange(of: store.selectedFileID) { store.loadDiff() }
        .alert(
            "Git error",
            isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private var themeSymbol: String {
        switch store.theme {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    private var welcome: some View {
        VStack(spacing: 14) {
            WelcomeArt()
            Text("Open a root folder").font(.title2).foregroundStyle(Color.ghText)
            Text("Sightline scans it for nested git repos.").foregroundStyle(Color.ghMuted)
            Button("Choose Folder…") { store.chooseRoot() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.ghCanvas)
    }
}

/// Welcome illustration (SVG shipped in the .app's Resources, light/dark). Under `swift run`
/// there's no bundle, so it falls back to an SF Symbol.
private struct WelcomeArt: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let name = scheme == .dark ? "welcome-dark" : "welcome-light"
        if let url = Bundle.main.url(forResource: name, withExtension: "svg"), let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 320, height: 200)
        } else {
            Image(systemName: "folder.badge.gearshape").font(.system(size: 44)).foregroundStyle(Color.ghMuted)
        }
    }
}

/// Files panel detail: the open file's contents, or its diff when it has changes.
private struct FilePane: View {
    let store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            if let editor = store.editor, let repo = store.selectedRepo, editor.path.hasPrefix(repo.path + "/") {
                let relative = String(editor.path.dropFirst(repo.path.count + 1))
                let change = store.change(forRelativePath: relative)
                header(relative: relative, change: change, editor: editor)
                Divider()
                if store.showDiffForOpenFile, change != nil {
                    DiffPane(store: store, showsHeader: false)
                } else if let controller = editor.controller, store.markdownPreview, store.isMarkdownOpen {
                    // The preview replaces the editor (eye button / ⇧⌘V toggles back).
                    MarkdownPreview(
                        controller: controller,
                        baseURL: URL(fileURLWithPath: (editor.path as NSString).deletingLastPathComponent, isDirectory: true),
                        openLocalFile: { store.openLocalFile($0) }
                    )
                } else if let controller = editor.controller {
                    CodeEditorView(controller: controller)
                } else {
                    ContentUnavailableView(editor.message ?? "Can't open file", systemImage: "doc")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView(
                    "No file open", systemImage: "folder",
                    description: Text("Pick a file in the tree, or press ⌘P to search all repos.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func header(relative: String, change: FileChange?, editor: EditorSession) -> some View {
        HStack(spacing: 8) {
            if editor.isDirty {
                Circle().fill(.primary).frame(width: 7, height: 7).help("Unsaved changes")
            }
            Text(relative).font(.callout.monospaced()).lineLimit(1).truncationMode(.head)
            Text(editor.language.name).font(.caption).foregroundStyle(.secondary)
            if let vimStatus = editor.vimStatus, !(store.markdownPreview && store.isMarkdownOpen) {
                VimBadge(status: vimStatus)
            }
            Spacer()
            if let toast = store.toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.ghAdded)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .transition(.opacity)
            }
            if editor.isDirty {
                Button("Save") { store.saveEditor() }
                    .controlSize(.small)
                    .help("Save (⌘S)")
            }
            if store.isMarkdownOpen {
                Button { store.toggleMarkdownPreview() } label: {
                    Image(systemName: store.markdownPreview && !store.showDiffForOpenFile ? "eye.fill" : "eye")
                        .foregroundStyle(store.markdownPreview && !store.showDiffForOpenFile ? Color.ghAccent : Color.ghMuted)
                }
                .buttonStyle(.borderless)
                .help(store.markdownPreview && !store.showDiffForOpenFile ? "Show Source (⇧⌘V)" : "Open Preview (⇧⌘V)")
            }
            Button { store.showHistory(forPath: relative) } label: {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(Color.ghMuted)
            }
            .buttonStyle(.borderless)
            .help("Show File History")
            OpenInEditorButtons(store: store) { (editor.path, editor.controller?.caretLine()) }
            if change != nil {
                Picker("", selection: Binding(
                    get: { store.showDiffForOpenFile },
                    set: { store.setShowDiffForOpenFile($0) }
                )) {
                    Text("File").tag(false)
                    Text("Diff").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

private struct DiffPane: View {
    let store: AppStore
    var showsHeader = true
    @State private var nav = DiffNavRequest()

    var body: some View {
        VStack(spacing: 0) {
            if let file = store.selectedFile {
                header(file)
                Divider()
                content
            } else {
                ContentUnavailableView("No file selected", systemImage: "doc.text.magnifyingglass")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func header(_ file: FileChange) -> some View {
        HStack(spacing: 10) {
            if showsHeader {
                Image(systemName: FileIcon.symbol(for: file.fileName)).foregroundStyle(.secondary)
                Text(file.fileName).font(.callout.weight(.medium)).lineLimit(1)
                Text(file.directory).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                Text(file.area.title)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            Spacer(minLength: 8)
            if showsHeader, let toast = store.toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.ghAdded)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if showsHeader {
                let isReviewed = store.isReviewed(file)
                Button { store.toggleReviewed(file) } label: {
                    Label(isReviewed ? "Reviewed" : "Mark Reviewed",
                          systemImage: isReviewed ? "checkmark.square.fill" : "square")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(isReviewed ? Color.ghAdded : Color.ghMuted)
                }
                .buttonStyle(.borderless)
                .help("Toggle reviewed (⌥⌘V). Marking moves to the next unreviewed file.")
            }
            if showsHeader {
                OpenInEditorButtons(store: store) {
                    store.diffAbsolutePath.map { ($0, DiffReference.activeHost?.caretLine()) }
                }
            }
            DiffControls(store: store, document: store.diff, nav: $nav, onShowFull: store.showFullDiff)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var content: some View {
        DiffBody(
            store: store,
            document: store.diff,
            isLoading: store.isLoadingDiff,
            fileID: store.diffFileID ?? "",
            referencePath: store.diffReferencePath,
            nav: nav
        )
    }
}

/// Vim mode indicator / command line, e.g. "NORMAL", "INSERT", "VISUAL  d2", ":%s/foo/bar/g".
private struct VimBadge: View {
    let status: String

    private var color: Color {
        if status.hasPrefix("INSERT") { return .ghAdded }
        if status.hasPrefix("VISUAL") || status.hasPrefix("V-LINE") { return .ghModified }
        if status.hasPrefix(":") || status.hasPrefix("/") || status.hasPrefix("?") { return .ghText }
        return .ghAccent
    }

    var body: some View {
        Text(status)
            .font(.caption.monospaced().weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(color)
            .help("Vim mode (View → Vim Mode)")
    }
}
