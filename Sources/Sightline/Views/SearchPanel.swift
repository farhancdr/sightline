import SwiftUI

/// VS Code-style search across every repo: query + match case / whole word / regex toggles,
/// include/exclude globs, results grouped by file with highlighted matches.
struct SearchPanel: View {
    @Bindable var store: AppStore
    @FocusState private var queryFocused: Bool
    @State private var showFilters = false
    @State private var collapsed: Set<String> = []
    @State private var selectedMatchID: String?

    var body: some View {
        VStack(spacing: 8) {
            searchField
            if showFilters { filters }
            status
            results
        }
        .padding(.top, 8)
        .onChange(of: store.searchQuery) { store.scheduleSearch() }
        .onChange(of: store.searchOptions) { store.scheduleSearch() }
        .onChange(of: store.focusSearchRequest) { DispatchQueue.main.async { queryFocused = true } }
        .onAppear { DispatchQueue.main.async { queryFocused = true } }
    }

    // MARK: Query

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(Color.ghMuted)
            TextField("Search all repos (⇧⌘F)", text: $store.searchQuery)
                .textFieldStyle(.plain)
                .focused($queryFocused)
                .onSubmit { store.scheduleSearch(immediately: true) }
            OptionToggle(label: "Aa", help: "Match Case", isOn: $store.searchOptions.matchCase)
            OptionToggle(label: "ab", help: "Match Whole Word", isOn: $store.searchOptions.wholeWord, underline: true)
            OptionToggle(label: ".*", help: "Use Regular Expression", isOn: $store.searchOptions.regex)
            Button { showFilters.toggle() } label: {
                Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hasFilters ? Color.ghAccent : Color.ghMuted)
                    .frame(width: 20, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Files to include / exclude")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(Color.ghCanvas, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(queryFocused ? Color.ghAccent : Color.ghBorder, lineWidth: queryFocused ? 1.5 : 1)
        )
        .padding(.horizontal, 10)
    }

    private var hasFilters: Bool { !store.searchOptions.include.isEmpty || !store.searchOptions.exclude.isEmpty }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 6) {
            FilterField(title: "files to include", placeholder: "e.g. *.ts, services/**", text: $store.searchOptions.include)
            FilterField(title: "files to exclude", placeholder: "e.g. *.spec.ts, dist/**", text: $store.searchOptions.exclude)
        }
        .padding(.horizontal, 10)
    }

    // MARK: Status

    @ViewBuilder
    private var status: some View {
        let results = store.searchResults
        HStack(spacing: 6) {
            if store.isSearching {
                ProgressView().controlSize(.mini)
                Text("Searching…")
            } else if let error = results.error {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.ghDeleted)
                Text(error).lineLimit(2)
            } else if !store.searchQuery.isEmpty {
                Text(results.matchCount == 0
                     ? "No results"
                     : "\(results.matchCount)\(results.truncated ? "+" : "") results in \(results.files.count) files")
                if results.truncated {
                    Text("(showing the first \(WorkspaceSearch.maxMatches))").foregroundStyle(Color.ghModified)
                }
            }
            Spacer()
            if !results.files.isEmpty {
                Button {
                    collapsed = collapsed.isEmpty ? Set(results.files.map(\.id)) : []
                } label: {
                    Image(systemName: collapsed.isEmpty ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                }
                .buttonStyle(.borderless)
                .help(collapsed.isEmpty ? "Collapse all" : "Expand all")
            }
        }
        .font(.caption)
        .foregroundStyle(Color.ghMuted)
        .padding(.horizontal, 12)
    }

    // MARK: Results

    private var results: some View {
        List(selection: Binding(get: { selectedMatchID }, set: select)) {
            ForEach(store.searchResults.files) { file in
                Section {
                    if !collapsed.contains(file.id) {
                        ForEach(file.matches) { match in
                            MatchRow(match: match).tag(match.id)
                        }
                    }
                } header: {
                    FileHeader(file: file, isCollapsed: collapsed.contains(file.id)) {
                        if collapsed.contains(file.id) { collapsed.remove(file.id) } else { collapsed.insert(file.id) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 20)
    }

    private func select(_ id: String?) {
        selectedMatchID = id
        guard let id else { return }
        for file in store.searchResults.files {
            if let match = file.matches.first(where: { $0.id == id }) {
                store.openSearchMatch(match)
                return
            }
        }
    }
}

/// "Aa" / "ab" / ".*" toggle inside the search box.
private struct OptionToggle: View {
    let label: String
    let help: String
    @Binding var isOn: Bool
    var underline = false

    var body: some View {
        Button { isOn.toggle() } label: {
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .underline(underline)
                .foregroundStyle(isOn ? Color.ghAccent : Color.ghMuted)
                .frame(width: 22, height: 18)
                .background(isOn ? Color.ghAccent.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(isOn ? Color.ghAccent.opacity(0.6) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

private struct FilterField: View {
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(Color.ghMuted)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.callout)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.ghCanvas, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.ghBorder))
        }
    }
}

private struct FileHeader: View {
    let file: SearchFileResult
    let isCollapsed: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 5) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 10)
                Image(systemName: FileIcon.symbol(for: file.fileName)).font(.caption)
                Text(file.fileName).font(.callout.weight(.medium)).foregroundStyle(Color.ghText).lineLimit(1)
                Text(file.directory).font(.caption).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 4)
                Text("\(file.matches.count)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 5)
                    .background(Color.ghMuted.opacity(0.18), in: Capsule())
            }
            .foregroundStyle(Color.ghMuted)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(file.displayPath)
    }
}

private struct MatchRow: View {
    let match: SearchMatch

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(match.line)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Color.ghMuted)
                .frame(minWidth: 26, alignment: .trailing)
            Text(highlighted)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.leading, 14)
    }

    private var highlighted: AttributedString {
        var string = AttributedString(match.text)
        string.foregroundColor = .ghText
        let ns = match.text as NSString
        for range in match.ranges where NSMaxRange(range) <= ns.length {
            guard let swiftRange = Range(range, in: match.text),
                  let lower = AttributedString.Index(swiftRange.lowerBound, within: string),
                  let upper = AttributedString.Index(swiftRange.upperBound, within: string) else { continue }
            string[lower..<upper].backgroundColor = Color.ghModified.opacity(0.28)
            string[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return string
    }
}
