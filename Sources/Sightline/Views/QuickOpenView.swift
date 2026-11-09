import SwiftUI

/// ⌘P palette: fuzzy file search across every repo in the workspace.
struct QuickOpenView: View {
    let store: AppStore

    @State private var query = ""
    @State private var selection = 0

    var body: some View {
        // Derived from the query on every render (~3 ms over ~15k files): results can never lag
        // behind what's typed. Reading indexVersion re-renders when the index finishes building.
        let text = query.trimmingCharacters(in: .whitespaces)
        let shown = text.isEmpty || store.indexVersion < 0
            ? store.recentFiles
            : FileIndex.search(text, in: store.fileIndex)
        content(shown)
    }

    private func content(_ shown: [QuickOpenEntry]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                PaletteSearchField(
                    text: $query,
                    placeholder: "Search files by name across all repos",
                    onMove: { move($0, count: shown.count) },
                    onSubmit: { open(shown) },
                    onCancel: { store.quickOpenVisible = false }
                )
                .frame(height: 22)
            }
            .padding(12)

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
