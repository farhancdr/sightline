import AppKit
import SwiftUI

struct BranchPicker: View {
    let store: AppStore
    let dismiss: () -> Void

    @State private var branches: [BranchInfo] = []
    @State private var query = ""
    @State private var isLoading = true
    @State private var isSwitching = false

    private var filtered: [BranchInfo] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? branches : branches.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Filter branches", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(10)
                .onSubmit { if let first = filtered.first(where: { !$0.isCurrent }) { select(first) } }
            Divider()
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    section("Local", filtered.filter { !$0.isRemote })
                    section("Remote", filtered.filter(\.isRemote))
                }
                .listStyle(.plain)
                .disabled(isSwitching)
            }
        }
        .frame(width: 380, height: 440)
        .overlay { if isSwitching { ProgressView("Switching…").padding().background(.regularMaterial) } }
        .task {
            branches = await store.branches()
            isLoading = false
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [BranchInfo]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { branch in
                    HStack(spacing: 6) {
                        Button { select(branch) } label: { row(branch) }
                            .buttonStyle(.plain)
                            .disabled(branch.isCurrent)
                        // Outside the switch button, so it also works on the (disabled) current branch.
                        CopyBranchButton(name: branch.name)
                    }
                    .noScrollBounce()
                }
            }
        }
    }

    private func row(_ branch: BranchInfo) -> some View {
        HStack {
            Image(systemName: branch.isCurrent ? "checkmark" : (branch.isRemote ? "cloud" : "arrow.triangle.branch"))
                .frame(width: 16)
                .foregroundStyle(branch.isCurrent ? Color.ghAdded : Color.ghMuted)
            Text(branch.name).lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(branch.relativeDate).font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    private func select(_ branch: BranchInfo) {
        guard !branch.isCurrent else { return }
        isSwitching = true
        Task {
            await store.switchBranch(branch)
            isSwitching = false
            dismiss()
        }
    }
}

/// Copies a branch name; shows a checkmark for a moment.
private struct CopyBranchButton: View {
    let name: String
    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(name, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(copied ? Color.ghAdded : (hovering ? Color.ghText : Color.ghMuted))
                .frame(width: 20, height: 17)
                .background(hovering ? Color.ghMuted.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .onHover { hovering = $0 }
        .help(copied ? "Copied" : "Copy branch name")
    }
}
