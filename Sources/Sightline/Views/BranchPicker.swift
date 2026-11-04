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
                    Button { select(branch) } label: { row(branch) }
                        .buttonStyle(.plain)
                        .disabled(branch.isCurrent)
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
