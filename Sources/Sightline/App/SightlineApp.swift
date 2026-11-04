import AppKit
import SwiftUI

@main
struct SightlineApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = AppStore.shared

    var body: some Scene {
        Window("Sightline", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 1000, minHeight: 600)
        }
        .defaultSize(width: 1400, height: 880)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Go to File…") { store.showQuickOpen() }
                    .keyboardShortcut("p")
                Divider()
                Button("Open Root Folder…") { store.chooseRoot() }
                    .keyboardShortcut("o")
                Button("Rescan Repos") { Task { await store.rescan() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                // Not disabled when clean: saveEditor() no-ops, and menu enablement may not track isDirty.
                Button("Save") { store.saveEditor() }
                    .keyboardShortcut("s")
                Divider()
                Button("Close File") { store.closeCurrent() }
                    .keyboardShortcut("w")
                Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .textEditing) {
                Button("Find…") { store.performFind(.showFindInterface) }
                    .keyboardShortcut("f")
                Button("Find and Replace…") { store.performFind(.showReplaceInterface) }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                Button("Find Next") { store.performFind(.nextMatch) }
                    .keyboardShortcut("g")
                Button("Find Previous") { store.performFind(.previousMatch) }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Use Selection for Find") { store.performFind(.setSearchString) }
                    .keyboardShortcut("e")
                Divider()
                Button("Go to Line…") { store.promptGoToLine() }
                    .keyboardShortcut("g", modifiers: .control)
                Divider()
                Button("Toggle Line Comment") { store.performEditorCommand(#selector(CodeTextView.toggleLineComment(_:))) }
                    .keyboardShortcut("/")
                Button("Delete Line") { store.performEditorCommand(#selector(CodeTextView.deleteLines(_:))) }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                Button("Indent Line") { store.performEditorCommand(#selector(CodeTextView.indentLines(_:))) }
                    .keyboardShortcut("]")
                Button("Outdent Line") { store.performEditorCommand(#selector(CodeTextView.outdentLines(_:))) }
                    .keyboardShortcut("[")
                Button("Select Line") { store.performEditorCommand(#selector(CodeTextView.selectLineExtending(_:))) }
                    .keyboardShortcut("l")
                // ⌥↑ / ⌥↓ (move) and ⇧⌥↑ / ⇧⌥↓ (copy) are handled by the editor itself, so the terminal
                // keeps those keys.
            }
            CommandGroup(replacing: .printItem) {} // frees ⌘P for Go to File
            CommandGroup(after: .pasteboard) {
                Button("Copy Path:Line Reference") { store.copyReference() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .sidebar) {
                Button(store.sidebarVisible ? "Hide Repo Sidebar" : "Show Repo Sidebar") {
                    store.sidebarVisible.toggle()
                }
                .keyboardShortcut("b")
                Button(store.repoPanelVisible ? "Hide Changes/Files Panel" : "Show Changes/Files Panel") {
                    store.repoPanelVisible.toggle()
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Find Repo…") { store.focusRepoFilter() }
                    .keyboardShortcut("t")
                Toggle("Show Only Changed Repos", isOn: Binding(
                    get: { store.showOnlyChanged }, set: { store.showOnlyChanged = $0 }
                ))
                Button("Toggle Markdown Preview") { store.toggleMarkdownPreview() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                Toggle("Vim Mode", isOn: Binding(get: { store.vimMode }, set: { store.vimMode = $0 }))
                Toggle("Show Line Blame", isOn: Binding(get: { store.showLineBlame }, set: { store.showLineBlame = $0 }))
                Divider()
                Button("Changes") { store.panel = .changes }
                    .keyboardShortcut("1")
                Button("Files") { store.panel = .files }
                    .keyboardShortcut("2")
                Button("History") { store.panel = .history }
                    .keyboardShortcut("3")
                Button("Search All Repos") { store.showSearch() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                Divider()
                Button("Go Back") { store.navigateBack() }
                    .keyboardShortcut("-", modifiers: .option)
                Button("Go Forward") { store.navigateForward() }
                    .keyboardShortcut("=", modifiers: .option)
            }
            CommandMenu("Repository") {
                Button("Fetch") { Task { await store.sync(.fetch) } }
                Button("Pull") { Task { await store.sync(.pull) } }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Push") { Task { await store.sync(.push) } }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                Divider()
                Button("Toggle Reviewed") { store.toggleReviewedForSelected() }
                    .keyboardShortcut("v", modifiers: [.command, .option])
                Divider()
                Button("Open in \(store.preferredEditor?.name ?? "Editor")") { store.openFocusedExternally() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Reveal in Finder") { store.revealFocusedInFinder() }
                    .keyboardShortcut("r", modifiers: [.command, .option])
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh All") { Task { await store.refreshAll() } }
                    .keyboardShortcut("r")
                Divider()
                Button(store.terminalVisible ? "Hide Terminal" : "Show Terminal") { store.terminalVisible.toggle() }
                    .keyboardShortcut("j")
                Button("Relaunch Terminal") { store.relaunchTerminal() }
                    .keyboardShortcut("j", modifiers: .option)
                Button("Focus Terminal") {
                    store.terminalVisible = true
                    DispatchQueue.main.async { TerminalManager.shared.focusVisible() }
                }
                .keyboardShortcut("`", modifiers: .control)
                Divider()
                Picker("Theme", selection: Binding(get: { store.theme }, set: { store.setTheme($0) })) {
                    ForEach(AppStore.Theme.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Button("Toggle Theme") { store.cycleTheme() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Picker("Terminal Colors", selection: Binding(
                    get: { store.terminalColorScheme }, set: { store.terminalColorScheme = $0 }
                )) {
                    ForEach(TerminalManager.ColorScheme.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Toggle("GPU-Accelerated Terminal", isOn: Binding(get: { store.terminalGPU }, set: { store.terminalGPU = $0 }))
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appearanceObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`), harmless inside the .app.
        // Writing to a git process that exited early (e.g. blame of an untracked file, fed via stdin)
        // must fail with EPIPE, not kill the app with SIGPIPE.
        signal(SIGPIPE, SIG_IGN)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        MainActor.assumeIsolated { AppStore.shared.applyTheme() }
        // Terminal colors are static, so re-apply when the effective appearance flips (System theme).
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
            DispatchQueue.main.async { TerminalManager.shared.applyAppearance() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { AppStore.shared.confirmLeavingEditor() } ? .terminateNow : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        TerminalManager.shared.terminateAll()
    }
}
