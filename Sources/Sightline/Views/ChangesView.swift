import AppKit
import SwiftUI

/// Middle column: branch controls, then either the change list or the file explorer.
struct RepoPanel: View {
    @Bindable var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            BranchBar(store: store)
            Picker("", selection: $store.panel) {
                ForEach(AppStore.Panel.allCases, id: \.self) { panel in
                    Text(panelTitle(panel)).tag(panel)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            Divider()
            switch store.panel {
            case .changes:
                ChangesList(store: store)
            case .files:
                if let explorer = store.explorer {
                    ExplorerView(store: store, explorer: explorer)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func panelTitle(_ panel: AppStore.Panel) -> String {
        guard panel == .changes, let count = store.selectedStatus?.changedCount, count > 0 else {
            return panel.rawValue
        }
        return "\(panel.rawValue) (\(count))"
    }
}

/// Staged / unstaged / untracked / conflicted file list.
private struct ChangesList: View {
    @Bindable var store: AppStore

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
                                    FileRow(store: store, file: file).tag(file.id)
                                }
                            } header: {
                                SectionHeader(store: store, area: area, files: files)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
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
    let store: AppStore
    let file: FileChange
    @State private var hovering = false

    private var color: Color { Color.ghStatus(file.code) ?? .ghModified }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: FileIcon.symbol(for: file.fileName))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(file.fileName)
                .lineLimit(1)
                .strikethrough(file.code == "D")
                .layoutPriority(1)
            Text(file.originalPath.map { "← \($0)" } ?? file.directory)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            if hovering { actions }
            Text(String(file.code == "?" ? "U" : file.code))
                .font(.caption.monospaced().weight(.bold))
                .foregroundStyle(color)
                .frame(width: 12)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(file.path)
        .contextMenu {
            if file.code != "D" {
                Button("Open File") { store.openInEditor(repoRelativePath: file.path) }
            }
            Button("Copy Relative Path") { copyRelativePath() }
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

            if let status = store.selectedStatus, status.upstream != nil {
                Text("↑\(status.ahead) ↓\(status.behind)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help(status.upstream ?? "")
            }

            Button {
                Task { await store.fetchSelected() }
            } label: {
                if store.isFetching {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.down.circle")
                }
            }
            .buttonStyle(.borderless)
            .disabled(store.isFetching)
            .help("git fetch --prune")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}
