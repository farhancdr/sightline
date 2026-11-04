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
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appearanceObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (`swift run`), harmless inside the .app.
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
