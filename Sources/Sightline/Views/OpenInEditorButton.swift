import SwiftUI

/// "Open in <editor>" (⇧⌘E) with a menu to pick another installed editor, plus Reveal in Finder.
struct OpenInEditorButtons: View {
    let store: AppStore
    /// Resolved at click time so the caret line is current.
    let location: () -> (path: String, line: Int?)?

    var body: some View {
        HStack(spacing: 0) {
            if let preferred = store.preferredEditor {
                Menu {
                    ForEach(store.installedEditors) { editor in
                        Button(editor.id == preferred.id ? "\(editor.name) ✓" : editor.name) { open(with: editor) }
                    }
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                } primaryAction: {
                    open(with: nil)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Open this repo in \(preferred.name), at this file and line (⇧⌘E). Click the arrow to choose an editor.")
            }
            ActionButton(symbol: "folder", help: "Reveal in Finder (⌥⌘R)") {
                if let path = location()?.path { store.revealInFinder(path) }
            }
        }
    }

    private func open(with editor: ExternalEditor?) {
        guard let location = location() else { return }
        store.openExternally(path: location.path, line: location.line, editor: editor)
    }
}
