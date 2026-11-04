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
                                    if store.panel == .files {
                                        FilePane(store: store)
                                    } else {
                                        DiffPane(store: store)
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
            if let diff = store.diff, diff.message == nil {
                if diff.isTruncated {
                    Button("Show full diff") { store.showFullDiff() }.controlSize(.small)
                }
                HStack(spacing: 6) {
                    Text("+\(diff.additions)").foregroundStyle(Color.ghAdded)
                    Text("−\(diff.deletions)").foregroundStyle(Color.ghDeleted)
                }
                .font(.caption.monospacedDigit().weight(.semibold))
                HStack(spacing: 0) {
                    ActionButton(symbol: "arrow.up", help: "Previous Change") { navigate(-1) }
                    ActionButton(symbol: "arrow.down", help: "Next Change") { navigate(1) }
                }
            }
            Picker("", selection: Binding(get: { store.diffSideBySide }, set: { store.setDiffSideBySide($0) })) {
                Image(systemName: "rectangle.split.2x1").help("Side by Side").tag(true)
                Image(systemName: "rectangle").help("Inline").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func navigate(_ direction: Int) {
        nav = DiffNavRequest(id: nav.id + 1, direction: direction)
    }

    @ViewBuilder
    private var content: some View {
        if let diff = store.diff {
            if let message = diff.message {
                ContentUnavailableView(message, systemImage: "doc")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // New or deleted files have nothing to compare against: show one column, like VS Code.
                let sideBySide = store.diffSideBySide && !diff.isOneSided
                DiffContentView(
                    document: diff,
                    fileID: store.diffFileID ?? "",
                    sideBySide: sideBySide,
                    nav: nav,
                    referencePath: store.diffReferencePath,
                    onReferenceCopied: { store.showToast("Copied \($0)") }
                )
                .id(sideBySide) // different NSView per layout
            }
        } else if store.isLoadingDiff {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.clear
        }
    }
}
