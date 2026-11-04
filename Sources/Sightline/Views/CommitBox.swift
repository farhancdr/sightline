import SwiftUI

/// VS Code-style commit message box with Commit / Commit (No Verify).
struct CommitBox: View {
    let store: AppStore
    @FocusState private var focused: Bool

    private var message: Binding<String> {
        Binding(get: { store.commitMessage }, set: { store.commitMessage = $0 })
    }

    /// Grows with the message: 2–8 lines.
    private var editorHeight: CGFloat {
        let lines = store.commitMessage.split(separator: "\n", omittingEmptySubsequences: false).count
        return CGFloat(min(8, max(2, lines))) * 16 + 10
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: message)
                    .font(.system(size: 12.5))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 4)
                if store.commitMessage.isEmpty {
                    Text("Message (⌘⏎ to commit on \(store.selectedStatus?.headLabel ?? "HEAD"))")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.ghMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: editorHeight)
            .background(Color.ghCanvas, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(focused ? Color.ghAccent : Color.ghBorder, lineWidth: focused ? 1.5 : 1)
            )

            Button { store.commit(noVerify: false) } label: {
                HStack(spacing: 5) {
                    if store.isCommitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "checkmark")
                    }
                    Text("Commit")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!store.canCommit)
            .help(stagedHelp)

            Button { store.commit(noVerify: true) } label: {
                Text("Commit (No Verify)").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!store.canCommit)
            .help("git commit --no-verify: skips pre-commit and commit-msg hooks")
        }
        .padding(10)
    }

    private var stagedHelp: String {
        let staged = store.selectedStatus?.files(in: .staged).count ?? 0
        return staged > 0 ? "Commit \(staged) staged file\(staged == 1 ? "" : "s") (⌘⏎)" : "Nothing staged: you'll be asked to stage all"
    }
}
