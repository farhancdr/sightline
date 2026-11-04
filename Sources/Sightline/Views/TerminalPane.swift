import AppKit
import SwiftUI

/// Hosts the shared terminal container and shows the selected repo's shell.
struct TerminalPane: NSViewRepresentable {
    let repo: Repo

    func makeNSView(context: Context) -> TerminalHostView {
        let host = TerminalHostView()
        let container = TerminalManager.shared.container
        container.removeFromSuperview()
        host.addSubview(container)
        return host
    }

    func updateNSView(_ host: TerminalHostView, context: Context) {
        if TerminalManager.shared.container.superview !== host {
            host.addSubview(TerminalManager.shared.container)
        }
        host.needsLayout = true
        TerminalManager.shared.show(repo)
    }
}
