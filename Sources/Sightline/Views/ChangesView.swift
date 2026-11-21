import AppKit
import SwiftUI

/// Middle column: branch controls, then either the change list or the file explorer.
struct RepoPanel: View {
    @Bindable var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            BranchBar(store: store)
            PanelTabs(store: store)
            Divider()
            switch store.panel {
            case .changes:
                ChangesList(store: store)
            case .files:
                if let explorer = store.explorer {
                    ExplorerView(store: store, explorer: explorer)
                }
            case .history:
                HistoryList(store: store)
            case .search:
                SearchPanel(store: store)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Changes / Files / History / Search switcher. A custom strip instead of a segmented Picker: since macOS 26
/// the Liquid Glass segmented control is wider than the column, and an over-wide child pushed the whole
/// panel (branch name included) under the repo sidebar. This one shrinks with the column.
private struct PanelTabs: View {
    let store: AppStore

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppStore.Panel.allCases, id: \.self) { panel in
                PanelTab(
                    panel: panel,
                    count: panel == .changes ? (store.selectedStatus?.changedCount ?? 0) : 0,
                    selected: store.panel == panel
                ) { store.panel = panel }
            }
        }
        .padding(2)
        .background(Color.ghMuted.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
}

private struct PanelTab: View {
    let panel: AppStore.Panel
    let count: Int
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    private var help: String {
        switch panel {
        case .changes: "Changes"
        case .files: "Files"
        case .history: "History"
        case .search: "Search all repos (⇧⌘F)"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if panel == .search {
                    Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold))
                } else {
                    Text(panel.rawValue).lineLimit(1).minimumScaleFactor(0.85)
                }
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background((selected ? Color.ghAccent : Color.ghMuted).opacity(0.2), in: Capsule())
                        .foregroundStyle(selected ? Color.ghAccent : Color.ghMuted)
                }
            }
            .font(.system(size: 12, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? Color.ghText : Color.ghMuted)
            .frame(maxWidth: panel == .search ? 30 : .infinity, minHeight: 22)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(selected ? Color.ghCanvas : (hovering ? Color.ghMuted.opacity(0.12) : .clear))
                    .shadow(color: .black.opacity(selected ? 0.12 : 0), radius: 1, y: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Staged / unstaged / untracked / conflicted file list.
private struct ChangesList: View {
    @Bindable var store: AppStore
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            CommitBox(store: store)
            Divider()
            list
        }
    }

    @ViewBuilder
    private var list: some View {
        if let status = store.selectedStatus {
            if status.files.isEmpty {
                ContentUnavailableView("No local changes", systemImage: "checkmark.circle")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $store.selectedFileID) {
                    ForEach(ChangeArea.sections, id: \.self) { area in
                        let files = status.sectionFiles(area)
                        if !files.isEmpty {
                            Section {
                                ForEach(files) { file in
                                    FileRow(store: store, file: file)
                                        .rowHighlight(selected: store.selectedFileID == file.id, listFocused: listFocused)
                                        .noScrollBounce()
                                        .tag(file.id)
                                }
                            } header: {
                                SectionHeader(store: store, area: area, files: files)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .focused($listFocused)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Section title with VS Code-style bulk actions on hover.
private struct SectionHeader: View {
    let store: AppStore
    let area: ChangeArea
    let files: [FileChange]
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text("\(area.title.uppercased())  \(files.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            let reviewedCount = store.reviewedCount(files)
            if reviewedCount > 0 {
                Text(reviewedCount == files.count ? "all reviewed" : "\(reviewedCount) reviewed")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Color.ghAdded)
            }
            Spacer()
            HStack(spacing: 2) {
                switch area {
                case .staged:
                    ActionButton(symbol: "minus", help: "Unstage All Changes") { store.unstage(files) }
                case .unstaged, .untracked:
                    ActionButton(symbol: "arrow.uturn.backward", help: "Discard All Changes") { store.discard(files) }
                    ActionButton(symbol: "plus", help: "Stage All Changes") { store.stage(files) }
                case .conflicted:
                    ActionButton(symbol: "plus", help: "Mark All Resolved (stage)") { store.stage(files) }
                }
            }
            .opacity(hovering ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct FileRow: View {
    @Environment(\.rowHighlight) private var highlight
    let store: AppStore
    let file: FileChange
    @State private var hovering = false

    private var color: Color { Color.ghStatus(file.code) ?? .ghModified }

    var body: some View {
        let isReviewed = store.isReviewed(file)
        HStack(spacing: 6) {
            Button { store.toggleReviewed(file) } label: {
                Image(systemName: isReviewed ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundStyle((isReviewed ? Color.ghAdded : Color.ghMuted.opacity(0.7)).onSelection(highlight))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(isReviewed ? "Reviewed. Click to unmark (⌥⌘V)." : "Mark as reviewed (⌥⌘V). Resets if the file changes again.")
            Image(systemName: FileIcon.symbol(for: file.fileName))
                .font(.caption)
                .foregroundStyle(Color.ghSecondary(highlight, opacity: 0.9))
                .frame(width: 14)
            Text(file.fileName)
                .lineLimit(1)
                .strikethrough(file.code == "D")
                .foregroundStyle((isReviewed ? Color.ghMuted : Color.ghText).onSelection(highlight))
                .layoutPriority(1)
            Text(file.originalPath.map { "← \($0)" } ?? file.directory)
                .font(.caption)
                .foregroundStyle(Color.ghSecondary(highlight, opacity: 0.85))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            if hovering { actions.foregroundStyle(Color.ghAccent.onSelection(highlight)) }
            Text(String(file.code == "?" ? "U" : file.code))
                .font(.caption.monospaced().weight(.bold))
                .foregroundStyle(color.onSelection(highlight))
                .frame(width: 12)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(file.path)
        .contextMenu {
            if file.code != "D" {
                Button("Open File") { store.openInEditor(repoRelativePath: file.path) }
                if let editor = store.preferredEditor {
                    Button("Open in \(editor.name)") { store.openExternally(path: absolutePath) }
                }
                Button("Reveal in Finder") { store.revealInFinder(absolutePath) }
            }
            Button("Copy Relative Path") { copyRelativePath() }
            if file.area != .untracked {
                Button("Show File History") { store.showHistory(forPath: file.path) }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 2) {
            if file.code != "D" {
                ActionButton(symbol: "doc.on.doc", help: "Open File") { store.openInEditor(repoRelativePath: file.path) }
            }
            switch file.area {
            case .staged:
                ActionButton(symbol: "minus", help: "Unstage Changes") { store.unstage([file]) }
            case .unstaged, .untracked:
                ActionButton(symbol: "arrow.uturn.backward", help: "Discard Changes") { store.discard([file]) }
                ActionButton(symbol: "plus", help: "Stage Changes") { store.stage([file]) }
            case .conflicted:
                ActionButton(symbol: "plus", help: "Mark Resolved (stage)") { store.stage([file]) }
            }
        }
    }

    private var absolutePath: String { (store.selectedRepo?.path ?? "") + "/" + file.path }

    private func copyRelativePath() {
        guard let repo = store.selectedRepo else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(store.rootRelativePath(repo: repo, repoRelativePath: file.path), forType: .string)
    }
}

/// Small borderless icon button used for hover actions.
struct ActionButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

private struct BranchBar: View {
    let store: AppStore
    @State private var showingPicker = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                showingPicker = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                    Text(store.selectedStatus?.headLabel ?? "…").lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showingPicker, arrowEdge: .bottom) {
                BranchPicker(store: store) { showingPicker = false }
            }

            SyncButtons(store: store)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

/// Fetch / Pull / Push with ahead-behind counts. Only one runs at a time.
private struct SyncButtons: View {
    let store: AppStore

    var body: some View {
        let status = store.selectedStatus
        let hasUpstream = status?.upstream != nil
        HStack(spacing: 2) {
            syncButton(.fetch, symbol: "arrow.triangle.2.circlepath", count: nil,
                       help: "Fetch (git fetch --prune)")
            if hasUpstream {
                syncButton(.pull, symbol: "arrow.down", count: status?.behind,
                           help: "Pull (fast-forward only) from \(status?.upstream ?? "upstream")")
            }
            syncButton(.push, symbol: hasUpstream ? "arrow.up" : "icloud.and.arrow.up", count: hasUpstream ? status?.ahead : nil,
                       help: hasUpstream ? "Push to \(status?.upstream ?? "upstream")" : "Publish branch (git push -u)")
        }
    }

    private func syncButton(_ operation: AppStore.SyncOperation, symbol: String, count: Int?, help: String) -> some View {
        Button {
            Task { await store.sync(operation) }
        } label: {
            HStack(spacing: 2) {
                if store.syncing == operation {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                }
                if let count, count > 0 {
                    Text("\(count)").font(.caption.monospacedDigit().weight(.semibold))
                }
            }
            .foregroundStyle((count ?? 0) > 0 ? Color.ghAccent : Color.ghMuted)
            .padding(.horizontal, 4)
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(store.syncing != nil)
        .help(help)
    }
}
