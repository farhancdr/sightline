import AppKit
import os
import SwiftTerm

private let log = Logger(subsystem: "io.github.farhancdr.sightline", category: "terminal")

/// Owns one shell per repo. All terminal views live in a single container and are switched with
/// `isHidden` (never removed), so background shells keep their size and running programs.
final class TerminalManager: NSObject, LocalProcessTerminalViewDelegate {
    static let shared = TerminalManager()

    let container: NSView = {
        let view = TerminalContainerView()
        view.wantsLayer = true
        return view
    }()

    private var terminals: [String: LocalProcessTerminalView] = [:]
    private var exitOverlays: [String: NSView] = [:]
    private var repoByTerminal: [ObjectIdentifier: String] = [:]
    private var visibleRepoID: String?

    /// Terminal colors. Dark by default: shell prompts (powerlevel10k, starship…) are usually themed for dark
    /// terminals and become unreadable on a light background (SwiftTerm has no minimum-contrast option).
    enum ColorScheme: String, CaseIterable { case dark = "Dark", light = "Light", matchApp = "Match App Theme" }

    var colorScheme: ColorScheme = .dark { didSet { applyAppearance() } }
    /// GPU (Metal) rendering, like iTerm2's. Falls back to CoreGraphics if Metal can't start.
    var useGPU = true { didSet { for terminal in terminals.values { applyRenderer(terminal) } } }
    static let scrollbackLines = 10_000

    /// A Nerd Font when one is installed (prompt icons), else SF Mono.
    let font: NSFont = TerminalManager.preferredFont(size: 12)

    static func preferredFont(size: CGFloat) -> NSFont {
        let families = NSFontManager.shared.availableFontFamilies
        let pick = families.first { $0.contains("Nerd Font Mono") }
            ?? families.first { $0.contains("Nerd Font") }
            ?? families.first { $0.hasSuffix(" NF") || $0.contains("MesloLGS") }
        if let pick, let font = NSFontManager.shared.font(withFamily: pick, traits: [], weight: 5, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func show(_ repo: Repo) {
        guard visibleRepoID != repo.id || terminals[repo.id] == nil else { return }
        let terminal = terminals[repo.id] ?? makeTerminal(for: repo)
        visibleRepoID = repo.id
        terminal.frame = container.bounds
        for (id, view) in terminals {
            view.isHidden = id != repo.id
            exitOverlays[id]?.isHidden = id != repo.id
        }
        // No makeFirstResponder here: it would steal arrow keys from the sidebar on every
        // repo switch. Click the terminal or press ⌃` to focus it.
    }

    func focusVisible() {
        guard let id = visibleRepoID, let terminal = terminals[id] else { return }
        terminal.window?.makeFirstResponder(terminal)
    }

    func terminateAll() {
        for terminal in terminals.values { kill(terminal) }
    }

    /// Kills the repo's shell (and its jobs) and starts a fresh one in its place.
    func relaunch(_ repo: Repo) {
        if let old = terminals.removeValue(forKey: repo.id) {
            old.processDelegate = nil
            kill(old)
            repoByTerminal.removeValue(forKey: ObjectIdentifier(old))
            old.removeFromSuperview()
        }
        exitOverlays.removeValue(forKey: repo.id)?.removeFromSuperview()
        visibleRepoID = nil
        show(repo)
        focusVisible()
    }

    private func kill(_ terminal: LocalProcessTerminalView) {
        let pid = terminal.process?.shellPid ?? 0
        terminal.terminate() // closes the pty (SIGHUP to the session) + SIGTERM
        if pid > 0 { Darwin.kill(pid, SIGHUP) } // interactive zsh ignores SIGTERM
    }

    // MARK: Appearance

    private var isDark: Bool {
        switch colorScheme {
        case .dark: true
        case .light: false
        case .matchApp: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        }
    }

    private func applyRenderer(_ terminal: LocalProcessTerminalView) {
        guard terminal.isUsingMetalRenderer != useGPU else { return }
        do {
            try terminal.setUseMetal(useGPU)
        } catch {
            // Stays on CoreGraphics.
            log.error("Metal renderer unavailable: \(String(describing: error), privacy: .public)")
        }
        log.notice("terminal renderer: \(terminal.isUsingMetalRenderer ? "metal" : "coregraphics", privacy: .public)")
    }

    func applyAppearance() {
        for terminal in terminals.values { style(terminal) }
    }

    private func style(_ terminal: LocalProcessTerminalView) {
        Self.applyColors(to: terminal, dark: isDark)
        terminal.needsDisplay = true
    }

    static func applyColors(to terminal: TerminalView, dark: Bool) {
        terminal.nativeBackgroundColor = SyntaxTheme.rgb(dark ? 0x0D1117 : 0xFFFFFF)
        terminal.nativeForegroundColor = SyntaxTheme.rgb(dark ? 0xE6EDF3 : 0x1F2328)
        terminal.caretColor = SyntaxTheme.rgb(dark ? 0x4493F8 : 0x0969DA)
        terminal.selectedTextBackgroundColor = SyntaxTheme.rgb(dark ? 0x1F3A5F : 0xB6E3FF)
        // Standard xterm colors for 16–255. SwiftTerm's default derives them from the 16-color palette and
        // the background, which on a light theme turns fixed colors (powerlevel10k's 236 background with
        // 31/76/178 text) into dark-on-dark. Prompts pick those indices for their exact xterm values.
        terminal.getTerminal().ansi256PaletteStrategy = .xterm
        terminal.installColors((dark ? darkPalette : lightPalette).map(color))
    }

    private static func color(_ hex: UInt32) -> SwiftTerm.Color {
        func c(_ v: UInt32) -> UInt16 { UInt16(v & 0xFF) * 257 }
        return SwiftTerm.Color(red: c(hex >> 16), green: c(hex >> 8), blue: c(hex))
    }

    // GitHub Dark Default / Light Default terminal ANSI palettes.
    private static let darkPalette: [UInt32] = [
        0x484F58, 0xFF7B72, 0x3FB950, 0xD29922, 0x58A6FF, 0xBC8CFF, 0x39C5CF, 0xB1BAC4,
        0x6E7681, 0xFFA198, 0x56D364, 0xE3B341, 0x79C0FF, 0xD2A8FF, 0x56D4DD, 0xFFFFFF,
    ]
    private static let lightPalette: [UInt32] = [
        0x24292F, 0xCF222E, 0x116329, 0x4D2D00, 0x0969DA, 0x8250DF, 0x1B7C83, 0x6E7781,
        0x57606A, 0xA40E26, 0x1A7F37, 0x633C01, 0x218BFF, 0xA475F9, 0x3192AA, 0x8C959F,
    ]

    // MARK: Creation

    private func makeTerminal(for repo: Repo) -> LocalProcessTerminalView {
        let terminal = FocusingTerminalView(frame: container.bounds)
        terminal.autoresizingMask = [.width, .height]
        terminal.processDelegate = self
        terminal.font = font
        style(terminal)
        terminal.optionAsMetaKey = true
        terminal.changeScrollback(Self.scrollbackLines)
        container.addSubview(terminal)
        applyRenderer(terminal)
        terminals[repo.id] = terminal
        repoByTerminal[ObjectIdentifier(terminal)] = repo.id
        start(terminal, in: repo.path)
        return terminal
    }

    private func start(_ terminal: LocalProcessTerminalView, in directory: String) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        terminal.startProcess(
            executable: shell,
            args: ["-l"], // login shell so nvm / Homebrew / profile PATH load
            environment: shellEnvironment(),
            execName: nil,
            currentDirectory: directory
        )
    }

    private func shellEnvironment() -> [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Sightline"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        // Don't leak the parent's git env (e.g. when launched via `swift run` from a git hook).
        for key in env.keys where key.hasPrefix("GIT_") { env.removeValue(forKey: key) }
        return env.map { "\($0.key)=\($0.value)" }
    }

    // MARK: Exit / restart

    private func showExitOverlay(for repoID: String) {
        guard exitOverlays[repoID] == nil else { return }
        let button = NSButton(title: "Shell exited. Click to restart.", target: self, action: #selector(restart(_:)))
        button.bezelStyle = .rounded
        button.identifier = NSUserInterfaceItemIdentifier(repoID)
        button.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            button.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])
        button.isHidden = repoID != visibleRepoID
        exitOverlays[repoID] = button
    }

    @objc private func restart(_ sender: NSButton) {
        guard let repoID = sender.identifier?.rawValue else { return }
        let repo = MainActor.assumeIsolated { AppStore.shared.repos.first { $0.id == repoID } }
        if let repo { relaunch(repo) }
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let repoID = self.repoByTerminal[ObjectIdentifier(source)] else { return }
            self.showExitOverlay(for: repoID)
        }
    }
}

/// Keeps every terminal sized to the container, including hidden ones, so background shells
/// see the real size (no SIGWINCH storm when they become visible).
/// SwiftTerm's `mouseDown` only handles selection / mouse reporting and never takes keyboard focus, so a
/// click left focus wherever it was (e.g. the sidebar's repo filter). Take it on any click.
final class FocusingTerminalView: LocalProcessTerminalView {
    private func takeFocus() {
        if let window, window.firstResponder !== self { window.makeFirstResponder(self) }
    }

    override func mouseDown(with event: NSEvent) {
        takeFocus()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        takeFocus()
        super.rightMouseDown(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        takeFocus()
        super.otherMouseDown(with: event)
    }
}

final class TerminalContainerView: NSView {
    override func layout() {
        super.layout()
        for case let terminal as TerminalView in subviews {
            terminal.frame = bounds
        }
    }
}

/// SwiftUI host for the shared container; pins it to the host's bounds.
final class TerminalHostView: NSView {
    override func layout() {
        super.layout()
        for sub in subviews { sub.frame = bounds }
    }
}
