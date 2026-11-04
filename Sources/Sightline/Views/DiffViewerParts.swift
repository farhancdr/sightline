import SwiftUI

/// +/− counts, previous/next change and the side-by-side / inline toggle, shared by the
/// working-tree diff and commit diffs.
struct DiffControls: View {
    let store: AppStore
    let document: DiffDocument?
    @Binding var nav: DiffNavRequest
    var onShowFull: (() -> Void)?

    var body: some View {
        if let diff = document, diff.message == nil {
            if diff.isTruncated, let onShowFull {
                Button("Show full diff", action: onShowFull).controlSize(.small)
            }
            HStack(spacing: 6) {
                Text("+\(diff.additions)").foregroundStyle(Color.ghAdded)
                Text("−\(diff.deletions)").foregroundStyle(Color.ghDeleted)
            }
            .font(.caption.monospacedDigit().weight(.semibold))
            HStack(spacing: 0) {
                ActionButton(symbol: "arrow.up", help: "Previous Change") { move(-1) }
                ActionButton(symbol: "arrow.down", help: "Next Change") { move(1) }
            }
        }
        Picker("", selection: Binding(get: { store.diffSideBySide }, set: { store.setDiffSideBySide($0) })) {
            Image(systemName: "rectangle.split.2x1").help("Side by Side").tag(true)
            Image(systemName: "rectangle").help("Inline").tag(false)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private func move(_ direction: Int) {
        nav = DiffNavRequest(id: nav.id + 1, direction: direction)
    }
}

/// The diff itself (or a message / spinner).
struct DiffBody: View {
    let store: AppStore
    let document: DiffDocument?
    let isLoading: Bool
    /// Identity of the shown file: a new id resets scroll to the first change, the same id keeps it.
    let fileID: String
    let referencePath: String
    let nav: DiffNavRequest

    var body: some View {
        if let diff = document {
            if let message = diff.message {
                ContentUnavailableView(message, systemImage: "doc")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // New or deleted files have nothing to compare against: show one column, like VS Code.
                let sideBySide = store.diffSideBySide && !diff.isOneSided
                DiffContentView(
                    document: diff,
                    fileID: fileID,
                    sideBySide: sideBySide,
                    nav: nav,
                    referencePath: referencePath,
                    onReferenceCopied: { store.showToast("Copied \($0)") }
                )
                .id(sideBySide) // different NSView per layout
            }
        } else if isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Color.clear
        }
    }
}
