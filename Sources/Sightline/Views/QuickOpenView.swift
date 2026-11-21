import SwiftUI

/// ⌘P palette: fuzzy file search in the selected repo or across every repo (tabs; Tab key toggles).
struct QuickOpenView: View {
    let store: AppStore

    @State private var query = ""
    @State private var selection = 0

    var body: some View {
        // Derived from the query on every render (~3 ms over ~15k files): results can never lag
        // behind what's typed. Reading indexVersion re-renders when the index finishes building.
        let text = query.trimmingCharacters(in: .whitespaces)
        let repoID = repoOnly ? store.selectedRepoID : nil
        let shown = text.isEmpty || store.indexVersion < 0
            ? FileIndex.scoped(store.recentFiles, repoID: repoID)
            : FileIndex.search(text, in: FileIndex.scoped(store.fileIndex, repoID: repoID))
        content(shown)
    }

    /// Only when a repo is selected; otherwise the palette searches everything.
    private var repoOnly: Bool { store.quickOpenRepoOnly && store.selectedRepo != nil }

    private var repoName: String { store.selectedRepo?.name ?? "This Repo" }

    private func content(_ shown: [QuickOpenEntry]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                PaletteSearchField(
                    text: $query,
                    placeholder: repoOnly ? "Search files by name in \(repoName)" : "Search files by name across all repos",
                    onMove: { move($0, count: shown.count) },
                    onSubmit: { open(shown) },
                    onCancel: { store.quickOpenVisible = false },
                    onTab: toggleScope
                )
                .frame(height: 22)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            scopeTabs
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            if !shown.isEmpty || !query.isEmpty {
                Divider()
                if shown.isEmpty {
                    Text("No matching files").foregroundStyle(.secondary).padding(14)
                } else {
                    resultList(shown)
                        .id(query) // fresh list per query; no stale rows
                }
            }
        }
        .frame(width: 680)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
        .onChange(of: query) { selection = 0 }
        .onChange(of: store.quickOpenRepoOnly) { selection = 0 }
    }

    private var scopeTabs: some View {
        HStack(spacing: 6) {
            ScopeTab(title: repoName, symbol: "folder", selected: repoOnly,
                     disabled: store.selectedRepo == nil) { setScope(repoOnly: true) }
                .help("Search only the selected repo (Tab to switch)")
            ScopeTab(title: "All Repos", symbol: "square.stack.3d.up", selected: !repoOnly,
                     disabled: false) { setScope(repoOnly: false) }
                .help("Search every repo under the root (Tab to switch)")
            Spacer(minLength: 0)
            Text("⇥ to switch")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func toggleScope() {
        setScope(repoOnly: !repoOnly)
    }

    private func setScope(repoOnly: Bool) {
        guard !repoOnly || store.selectedRepo != nil else { return }
        store.quickOpenRepoOnly = repoOnly
    }

    private func resultList(_ shown: [QuickOpenEntry]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if query.isEmpty {
                        Text("RECENTLY OPENED")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                    }
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, entry in
                        row(entry, isSelected: index == selection)
                            .id(index)
                            .noScrollBounce()
                            .onTapGesture {
                                selection = index
                                open(shown)
                            }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: selection) { _, index in proxy.scrollTo(index) }
        }
    }

    private func row(_ entry: QuickOpenEntry, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: FileIcon.symbol(for: entry.fileName))
                .foregroundStyle(isSelected ? .white : .secondary)
                .frame(width: 16)
            Text(entry.fileName)
                .fontWeight(.medium)
                .lineLimit(1)
            Text(entry.directory)
                .font(.caption)
                .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
        }
        .foregroundStyle(isSelected ? .white : .primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(isSelected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        selection = max(0, min(count - 1, selection + delta))
    }

    private func open(_ shown: [QuickOpenEntry]) {
        guard shown.indices.contains(selection) else { return }
        store.openQuickOpenEntry(shown[selection])
    }
}

/// "This repo" / "All repos" pill in the ⌘P palette.
private struct ScopeTab: View {
    let title: String
    let symbol: String
    let selected: Bool
    let disabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(selected ? Color.white : Color.ghMuted)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(selected ? Color.ghAccent : (hovering ? Color.ghMuted.opacity(0.15) : Color.ghMuted.opacity(0.08)))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .onHover { hovering = $0 }
    }
}
