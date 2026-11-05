import AppKit
import SwiftUI

/// VS Code-style tabs for open files from any repo. A preview tab (italic) is replaced by the next
/// file you open; editing it or double-clicking its tab keeps it.
struct EditorTabBar: View {
    let store: AppStore

    var body: some View {
        let paths = store.tabList.paths
        let names = paths.map { ($0 as NSString).lastPathComponent }
        let repos = paths.map { store.repo(forPath: $0) }
        // Files from several repos: label each tab with its repo.
        let multiRepo = Set(repos.compactMap { $0?.id }).count > 1
        // The 1pt spacer keeps the ScrollView off the pane's top edge: there SwiftUI stretches it under the
        // toolbar and its clickable content ends up behind the toolbar, above where the tabs are drawn.
        VStack(spacing: 0) {
            Color.clear.frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(paths.enumerated()), id: \.element) { index, path in
                            // Same file name twice: show the parent folder too.
                            let duplicate = names.filter { $0 == names[index] }.count > 1
                            let folder = duplicate ? ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent : nil
                            let repoName = multiRepo ? repos[index]?.name : nil
                            EditorTab(store: store, path: path,
                                      detail: [repoName, folder].compactMap { $0 }.joined(separator: " · ").nilIfEmpty)
                                .id(path)
                        }
                    }
                }
                .onChange(of: store.tabList.active) { _, active in
                    guard let active else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(active) }
                }
            }
        }
        .frame(height: 31)
        .background(Color.ghSidebar)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.ghBorder).frame(height: 1) }
    }
}

private struct EditorTab: View {
    let store: AppStore
    let path: String
    let detail: String?
    @State private var hovering = false

    var body: some View {
        let name = (path as NSString).lastPathComponent
        let isDirty = store.tabSessions[path]?.isDirty ?? false
        let isActive = store.tabList.active == path
        let isPreview = store.tabList.preview == path && !isDirty
        HStack(spacing: 0) {
            // A real Button: `onTapGesture` doesn't receive clicks reliably in this horizontal ScrollView.
            Button {
                // Double-click keeps a preview tab open (the first click already activated it).
                if NSApp.currentEvent?.clickCount ?? 1 >= 2 { store.pinTab(path) } else { store.activateTab(path) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: FileIcon.symbol(for: name))
                        .font(.caption)
                        .foregroundStyle(Color.ghMuted)
                    Text(name)
                        .italic(isPreview)
                        .foregroundStyle(isActive ? Color.ghText : Color.ghMuted)
                        .lineLimit(1)
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(Color.ghMuted).lineLimit(1)
                    }
                }
                .padding(.leading, 10)
                .padding(.trailing, 4)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            closeOrDirty(isDirty: isDirty, isActive: isActive)
                .padding(.trailing, 5)
        }
        .font(.callout)
        .frame(height: 30)
        .background(isActive ? Color.ghCanvas : (hovering ? Color.ghMuted.opacity(0.08) : Color.clear))
        .overlay(alignment: .top) {
            if isActive { Rectangle().fill(Color.ghAccent).frame(height: 2) }
        }
        .overlay(alignment: .trailing) { Rectangle().fill(Color.ghBorder).frame(width: 1) }
        .onHover { hovering = $0 }
        .help(store.workspaceRelative(path) + (isPreview ? "  (preview: double-click to keep open)" : ""))
        .contextMenu {
            Button("Close") { store.closeTabs([path]) }
            Button("Close Others") { store.closeOtherTabs(path) }
            Button("Close to the Right") { store.closeTabsToRight(path) }
            Button("Close All") { store.closeAllTabs() }
            Divider()
            if isPreview { Button("Keep Open") { store.pinTab(path) } }
            Button("Copy Relative Path") {
                let relative = store.workspaceRelative(path)
                store.copyToClipboard(relative, toast: "Copied \(relative)")
            }
            Button("Reveal in Finder") { store.revealInFinder(path) }
        }
    }

    /// Unsaved: a dot that turns into ✕ on hover. Otherwise ✕ on the active / hovered tab.
    @ViewBuilder
    private func closeOrDirty(isDirty: Bool, isActive: Bool) -> some View {
        ZStack {
            if isDirty && !hovering {
                Circle().fill(Color.ghText.opacity(0.75)).frame(width: 7, height: 7)
            } else {
                Button { store.closeTabs([path]) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.ghMuted)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .opacity(hovering || isActive ? 1 : 0)
                .help("Close (⌘W)")
            }
        }
        .frame(width: 16, height: 16)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
