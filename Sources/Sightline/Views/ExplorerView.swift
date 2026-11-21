import AppKit
import SwiftUI

/// VS Code-style lazy file tree for the selected repo.
struct ExplorerView: View {
    let store: AppStore
    let explorer: ExplorerModel
    @FocusState private var listFocused: Bool
    @State private var headerDropTarget = false

    var body: some View {
        let decorations = Decorations(status: store.selectedStatus)
        VStack(spacing: 0) {
            // A real header above the list (not an overlay), so rows don't scroll underneath it.
            HStack {
                Text(store.selectedRepo?.name.uppercased() ?? "")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.ghMuted)
                    .lineLimit(1)
                Spacer()
                Button { store.promptNewItem(folder: false) } label: { Image(systemName: "doc.badge.plus") }
                    .buttonStyle(.borderless)
                    .help("New File… (⌘N)")
                Button { store.promptNewItem(folder: true) } label: { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(.borderless)
                    .help("New Folder… (⌥⌘N)")
                Button { explorer.collapseAll() } label: { Image(systemName: "rectangle.compress.vertical") }
                    .buttonStyle(.borderless)
                    .help("Collapse all folders")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(headerDropTarget ? Color.ghAccent.opacity(0.18) : .clear)
            // Dropping on the header moves to the repo root.
            .onDrop(of: [.fileURL], isTargeted: $headerDropTarget) { handleDrop($0, into: explorer.repo.path) }
            .help("Drop here to move into the repo root")
            Rectangle().fill(Color.ghBorder).frame(height: 1)
            ScrollViewReader { proxy in
                // A Set selection gives ⇧-click ranges and ⌘-click toggles for free.
                List(selection: Binding(get: { explorer.selection }, set: { store.explorerSelectionChanged($0) })) {
                    ForEach(explorer.rows) { row in
                        ExplorerRowView(
                            row: row,
                            decoration: decorations.code(for: row.node),
                            toggle: { explorer.toggle(row.node) },
                            copyPath: { copy(rootRelative(row.node)) },
                            drop: { providers in
                                // A folder takes the drop; a file drops next to itself.
                                let dir = row.node.isDirectory ? row.node.path : (row.node.path as NSString).deletingLastPathComponent
                                return handleDrop(providers, into: dir)
                            }
                        )
                        // List-native dragging (the table view's own drag): `.onDrag` adds a gesture to every row
                        // that delays each click's selection while it waits to see whether it's a drag.
                        .itemProvider {
                            store.beginExplorerDrag(row.id)
                            return NSItemProvider(object: URL(fileURLWithPath: row.node.path) as NSURL)
                        }
                        .rowHighlight(selected: explorer.selection.contains(row.id), listFocused: listFocused)
                        .tag(row.id)
                        .id(row.id)
                        .contextMenu {
                            Button("New File…") { store.promptNewItem(folder: false, in: row.node) }
                            Button("New Folder…") { store.promptNewItem(folder: true, in: row.node) }
                            Divider()
                            Button(row.node.isDirectory ? "Show Folder History" : "Show File History") {
                                store.showHistory(forPath: row.node.relativePath)
                            }
                            Divider()
                            if !row.node.isDirectory, let editor = store.preferredEditor {
                                Button("Open in \(editor.name)") { store.openExternally(path: row.node.path) }
                            }
                            Button("Copy Relative Path") { copy(rootRelative(row.node)) }
                            Button("Copy Path") { copy(row.node.path) }
                            Button("Reveal in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.node.path)])
                            }
                            Divider()
                            let targets = store.explorerTargets(for: row.id)
                            Button(targets.count > 1 ? "Move \(targets.count) Items to Trash" : "Move to Trash") {
                                store.trashExplorerItems(targets)
                            }
                            .keyboardShortcut(.delete, modifiers: .command) // shown as a hint; ⌘⌫ is handled below
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .focused($listFocused)
                .environment(\.defaultMinListRowHeight, 22)
                // ⌘⌫ goes through a key monitor gated on this focus, not a menu shortcut (which would steal ⌘⌫
                // from the editor, terminal and text fields) nor .onKeyPress (the table view swallows the key).
                .onChange(of: listFocused, initial: true) { _, focused in store.explorerListFocused = focused }
                .onDisappear { store.explorerListFocused = false }
                .onAppear { store.installExplorerKeyMonitor() }
                .onChange(of: explorer.selectedPath) { _, path in
                    guard let path else { return }
                    withAnimation(nil) { proxy.scrollTo(path) }
                }
                .onAppear {
                    // Revealed from Changes / ⌘P before this view existed: onChange won't fire.
                    guard let path = explorer.selectedPath else { return }
                    DispatchQueue.main.async { proxy.scrollTo(path, anchor: .center) }
                }
            }
        }
    }

    /// Loads the dropped file URLs, then moves (from the explorer) or copies (from Finder) them into `dir`.
    private func handleDrop(_ providers: [NSItemProvider], into dir: String) -> Bool {
        let providers = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !providers.isEmpty else { return false }
        let group = DispatchGroup()
        var urls: [URL] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                DispatchQueue.main.async {
                    if let url { urls.append(url) }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { store.dropOnExplorer(urls: urls, into: dir) }
        return true
    }

    private func rootRelative(_ node: FileNode) -> String {
        store.rootRelativePath(repo: explorer.repo, repoRelativePath: node.relativePath)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Git status colors for files and the folders that contain them.
private struct Decorations {
    var files: [String: Character] = [:]
    var dirs: Set<String> = []

    init(status: RepoStatus?) {
        for change in status?.files ?? [] {
            // Working-tree state wins over staged, like VS Code.
            if change.area != .staged || files[change.path] == nil { files[change.path] = change.code }
            var dir = (change.path as NSString).deletingLastPathComponent
            while !dir.isEmpty, dirs.insert(dir).inserted {
                dir = (dir as NSString).deletingLastPathComponent
            }
        }
    }

    func code(for node: FileNode) -> Character? {
        if node.isDirectory { return dirs.contains(node.relativePath) ? "•" : nil }
        return files[node.relativePath]
    }
}

private struct ExplorerRowView: View {
    @Environment(\.rowHighlight) private var highlight
    let row: ExplorerRow
    let decoration: Character?
    let toggle: () -> Void
    let copyPath: () -> Void
    let drop: ([NSItemProvider]) -> Bool
    @State private var hovering = false
    @State private var dropTarget = false
    @State private var copied = false

    private var color: Color? { Color.ghStatus(decoration == "•" ? "M" : decoration) }

    var body: some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: CGFloat(row.depth) * 12, height: 1)
            if row.node.isDirectory {
                Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.ghSecondary(highlight, opacity: 0.9))
                    .frame(width: 12)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: toggle)
                Image(systemName: row.isExpanded ? "folder.fill" : "folder")
                    .foregroundStyle(Color.ghFolder.onSelection(highlight))
            } else {
                Color.clear.frame(width: 12, height: 1)
                Image(systemName: FileIcon.symbol(for: row.node.name))
                    .foregroundStyle(Color.ghSecondary(highlight, opacity: 0.9))
            }
            Text(row.node.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle((color ?? .ghText).onSelection(highlight))
            Spacer(minLength: 4)
            if hovering || copied {
                Button {
                    copyPath()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    // A solid chip so the icon reads on the gray and accent selection fills alike.
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(copied ? Color.ghAdded : Color.ghText)
                        .frame(width: 20, height: 17)
                        .background(Color.ghCanvas, in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.ghBorder))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help("Copy relative path (from workspace root)")
            }
            if let decoration, !row.node.isDirectory {
                Text(String(decoration == "?" ? "U" : decoration))
                    .font(.caption.monospaced().weight(.bold))
                    .foregroundStyle((color ?? .ghMuted).onSelection(highlight))
            } else if decoration != nil {
                Circle().fill((color ?? .ghModified).onSelection(highlight)).frame(width: 6, height: 6)
            }
        }
        .opacity(row.isIgnored ? 0.45 : 1)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(dropTarget ? Color.ghAccent.opacity(0.18) : .clear)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(dropTarget ? Color.ghAccent : .clear))
                .padding(.horizontal, -4)
        )
        .onDrop(of: [.fileURL], isTargeted: $dropTarget, perform: drop)
        .contentShape(Rectangle())
        .noScrollBounce()
        .onHover { hovering = $0 }
        .help(row.node.relativePath)
    }
}

enum FileIcon {
    static func symbol(for name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "swift", "ts", "tsx", "js", "jsx", "mjs", "cjs", "go", "py", "rs", "java", "kt", "c", "h", "cpp", "m",
             "rb", "php", "cs", "lua":
            "chevron.left.forwardslash.chevron.right"
        case "json", "yml", "yaml", "toml", "plist", "xml", "env", "ini":
            "curlybraces"
        case "md", "mdx", "txt", "rst":
            "doc.text"
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "ico":
            "photo"
        case "sh", "zsh", "bash":
            "terminal"
        case "sql":
            "cylinder"
        case "css", "scss", "less", "html":
            "paintbrush"
        default:
            "doc"
        }
    }
}
