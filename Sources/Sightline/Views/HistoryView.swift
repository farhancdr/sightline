import SwiftUI

enum RelativeDate {
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private static let absolute: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static func string(_ date: Date) -> String { formatter.localizedString(for: date, relativeTo: Date()) }
    static func absoluteString(_ date: Date) -> String { absolute.string(from: date) }
}

/// Middle column in the History panel: the commit list of the selected repo.
struct HistoryList: View {
    let store: AppStore

    var body: some View {
        if store.commits.isEmpty {
            if store.isLoadingHistory {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("No commits yet", systemImage: "clock.arrow.circlepath")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            List(selection: Binding(get: { store.selectedCommitID }, set: { store.selectCommit($0) })) {
                ForEach(store.commits) { commit in
                    CommitRow(commit: commit, isUnpushed: store.unpushedCommits.contains(commit.sha))
                        .tag(commit.sha)
                        .onAppear {
                            if commit.sha == store.commits.last?.sha { store.loadMoreHistory() }
                        }
                        .contextMenu {
                            Button("Copy Commit Hash") { store.copyToClipboard(commit.sha, toast: "Copied \(commit.shortSha)") }
                            Button("Copy Subject") { store.copyToClipboard(commit.subject, toast: "Copied subject") }
                        }
                }
                if store.isLoadingHistory {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }
}

private struct CommitRow: View {
    let commit: CommitInfo
    let isUnpushed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(commit.subject)
                .lineLimit(2)
                .foregroundStyle(Color.ghText)
            HStack(spacing: 5) {
                Text(commit.author).lineLimit(1)
                Text("·")
                Text(RelativeDate.string(commit.date)).lineLimit(1)
                Spacer(minLength: 4)
                if isUnpushed {
                    Text("↑ unpushed")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.ghAccent)
                        .help("Not on the upstream branch yet")
                }
                Text(commit.shortSha).font(.caption.monospaced())
            }
            .font(.caption)
            .foregroundStyle(Color.ghMuted)
            if !commit.refs.isEmpty {
                RefLabels(refs: commit.refs)
            }
        }
        .padding(.vertical, 3)
        .help(RelativeDate.absoluteString(commit.date))
    }
}

/// "HEAD -> main", "origin/main", "tag: v1" as small capsules.
private struct RefLabels: View {
    let refs: [String]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(refs.prefix(4), id: \.self) { ref in
                Text(ref.replacingOccurrences(of: "HEAD -> ", with: "HEAD → "))
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(color(ref).opacity(0.14), in: Capsule())
                    .foregroundStyle(color(ref))
            }
        }
    }

    private func color(_ ref: String) -> Color {
        if ref.hasPrefix("tag:") { return .ghModified }
        if ref.hasPrefix("HEAD") { return .ghAdded }
        return .ghAccent
    }
}

/// Detail area in the History panel: commit header, changed files, and the selected file's diff.
struct CommitPane: View {
    let store: AppStore
    @State private var nav = DiffNavRequest()

    var body: some View {
        if let commit = store.selectedCommit {
            VStack(spacing: 0) {
                CommitHeader(store: store, commit: commit)
                Divider()
                HStack(spacing: 0) {
                    CommitFileList(store: store)
                        .frame(width: 250)
                        .background(Color.ghSidebar)
                    VerticalRule()
                    VStack(spacing: 0) {
                        diffHeader
                        Divider()
                        DiffBody(
                            store: store,
                            document: store.commitDiff,
                            isLoading: store.isLoadingCommitDiff,
                            fileID: "\(commit.sha):\(store.selectedCommitFileID ?? "")",
                            referencePath: store.diffReferencePath,
                            nav: nav
                        )
                    }
                }
            }
        } else {
            ContentUnavailableView("Select a commit", systemImage: "clock.arrow.circlepath")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var diffHeader: some View {
        HStack(spacing: 10) {
            if let file = store.selectedCommitFile {
                Text(file.fileName).font(.callout.weight(.medium)).lineLimit(1)
                Text(file.directory).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 8)
            if let toast = store.toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Color.ghAdded)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if store.selectedCommitFile != nil {
                OpenInEditorButtons(store: store) {
                    store.diffAbsolutePath.map { ($0, DiffReference.activeHost?.caretLine()) }
                }
            }
            DiffControls(store: store, document: store.commitDiff, nav: $nav)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}

private struct CommitHeader: View {
    let store: AppStore
    let commit: CommitInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let message = store.selectedCommitMessage ?? commit.subject
            let lines = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            Text(String(lines.first ?? ""))
                .font(.headline)
                .foregroundStyle(Color.ghText)
                .textSelection(.enabled)
            if lines.count > 1, !lines[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ScrollView {
                    Text(lines[1].trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.callout)
                        .foregroundStyle(Color.ghMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 90)
            }
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle").foregroundStyle(Color.ghMuted)
                Text(commit.author).fontWeight(.medium)
                Text(RelativeDate.string(commit.date))
                    .foregroundStyle(Color.ghMuted)
                    .help(RelativeDate.absoluteString(commit.date))
                if store.unpushedCommits.contains(commit.sha) {
                    Badge(text: "↑ unpushed", color: .ghAccent)
                }
                if commit.isMerge { Badge(text: "merge", color: .ghModified) }
                if commit.isRoot { Badge(text: "root", color: .ghModified) }
                Spacer()
                Text("\(store.commitFiles.count) file\(store.commitFiles.count == 1 ? "" : "s")")
                    .foregroundStyle(Color.ghMuted)
                Button {
                    store.copyToClipboard(commit.sha, toast: "Copied \(commit.shortSha)")
                } label: {
                    Label(commit.shortSha, systemImage: "doc.on.doc").font(.caption.monospaced())
                }
                .buttonStyle(.borderless)
                .help("Copy full commit hash")
            }
            .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CommitFileList: View {
    let store: AppStore

    var body: some View {
        List(selection: Binding(get: { store.selectedCommitFileID }, set: { store.selectCommitFile($0) })) {
            ForEach(store.commitFiles) { file in
                HStack(spacing: 6) {
                    Image(systemName: FileIcon.symbol(for: file.fileName))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(file.fileName).lineLimit(1).strikethrough(file.code == "D")
                        Text(file.originalPath.map { "← \($0)" } ?? file.directory)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 4)
                    Text(String(file.code))
                        .font(.caption.monospaced().weight(.bold))
                        .foregroundStyle(Color.ghStatus(file.code) ?? .ghModified)
                }
                .tag(file.id)
                .help(file.path)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }
}
