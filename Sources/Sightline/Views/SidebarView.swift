import SwiftUI

struct SidebarView: View {
    @Bindable var store: AppStore
    @FocusState private var filterFocused: Bool
    @FocusState private var listFocused: Bool

    private var groups: [(name: String, repos: [Repo])] {
        let repos = store.filteredRepos
        switch store.repoSort {
        case .recent: return [("Recent", store.rankedByRecent(repos))]
        case .mostOpened: return [("Most Opened", store.rankedByMostOpened(repos))]
        case .folder: break
        }
        var order: [String] = []
        var map: [String: [Repo]] = [:]
        for repo in repos {
            if map[repo.group] == nil { order.append(repo.group) }
            map[repo.group, default: []].append(repo)
        }
        return order.map { ($0.isEmpty ? "Root" : $0, map[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            List(selection: Binding(get: { store.selectedRepoID }, set: { store.selectRepo($0) })) {
                ForEach(groups, id: \.name) { group in
                    Section(group.name) {
                        ForEach(group.repos) { repo in
                            RepoRow(
                                repo: repo,
                                status: store.statuses[repo.id],
                                showFullPath: store.repoSort != .folder
                            )
                            .rowHighlight(selected: store.selectedRepoID == repo.id, listFocused: listFocused)
                            .tag(repo.id)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .focused($listFocused)
            .overlay {
                if store.isScanning {
                    ProgressView("Scanning…")
                } else if store.repos.isEmpty, store.rootPath != nil {
                    ContentUnavailableView("No repos found", systemImage: "folder.badge.questionmark")
                } else if store.filteredRepos.isEmpty, store.repoFilter.isEmpty, store.showOnlyChanged {
                    ContentUnavailableView("No changes anywhere", systemImage: "checkmark.circle",
                                           description: Text("Every repo is clean and pushed."))
                } else if store.filteredRepos.isEmpty {
                    ContentUnavailableView.search(text: store.repoFilter)
                }
            }
        }
        .background(Color.ghSidebar)
        // Explicit border: the system split divider is invisible on the dark sidebar color.
        .overlay(alignment: .trailing) { VerticalRule() }
        .onChange(of: store.focusRepoFilterRequest) {
            DispatchQueue.main.async { filterFocused = true }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(Color.ghMuted)
                TextField("Filter repos or branches (⌘T)", text: $store.repoFilter)
                    .textFieldStyle(.plain)
                    .focused($filterFocused)
                    .onSubmit(openFirstMatch)
                    .onExitCommand {
                        store.repoFilter = ""
                        filterFocused = false
                    }
                if !store.repoFilter.isEmpty {
                    Button { store.repoFilter = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Color.ghMuted)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(Color.ghCanvas, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(filterFocused ? Color.ghAccent : Color.ghBorder, lineWidth: filterFocused ? 1.5 : 1)
            )

            Button { store.showOnlyChanged.toggle() } label: {
                Image(systemName: store.showOnlyChanged
                      ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .foregroundStyle(store.showOnlyChanged ? Color.ghAccent : Color.ghMuted)
            }
            .buttonStyle(.borderless)
            .help(store.showOnlyChanged
                  ? "Showing \(store.changedRepoCount) repos with changes or unpushed commits. Click to show all."
                  : "Show only repos with changes or unpushed commits")

            Menu {
                Picker("Sort Repos", selection: Binding(get: { store.repoSort }, set: { store.setRepoSort($0) })) {
                    ForEach(AppStore.RepoSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort repos: by folder, most recently opened, or most opened")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// Enter in the filter opens the top match (in the current sort order).
    private func openFirstMatch() {
        guard let first = groups.first(where: { !$0.repos.isEmpty })?.repos.first else { return }
        store.selectRepo(first.id)
        filterFocused = false
    }
}

private struct RepoRow: View {
    @Environment(\.rowHighlight) private var highlight
    let repo: Repo
    let status: RepoStatus?
    var showFullPath = false

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(showFullPath && !repo.relativePath.isEmpty ? repo.relativePath : repo.name)
                    .foregroundStyle(Color.ghText.onSelection(highlight))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let status {
                    Text(status.headLabel)
                        .font(.caption)
                        .foregroundStyle(status.isDetached ? Color.ghConflict.onSelection(highlight, opacity: 0.85) : Color.ghSecondary(highlight))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            if let status {
                if status.behind > 0 { Badge(text: "↓\(status.behind)", color: Color.ghModified.onSelection(highlight)) }
                if status.ahead > 0 { Badge(text: "↑\(status.ahead)", color: Color.ghAccent.onSelection(highlight)) }
                if status.changedCount > 0 { Badge(text: "\(status.changedCount)", color: Color.ghMuted.onSelection(highlight)) }
            }
        }
        .padding(.vertical, 1)
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.monospacedDigit().weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }
}
