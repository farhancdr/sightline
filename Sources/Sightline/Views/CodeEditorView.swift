import AppKit
import SwiftUI

/// Hosts an `EditorSession`'s own scroll view, so the text (and undo stack) outlives this view.
struct CodeEditorView: NSViewRepresentable {
    let controller: EditorController

    func makeNSView(context: Context) -> NSView {
        let host = TerminalHostView() // pins its single subview to bounds
        attach(to: host)
        return host
    }

    func updateNSView(_ host: NSView, context: Context) {
        if controller.scrollView.superview !== host {
            host.subviews.forEach { $0.removeFromSuperview() }
            attach(to: host)
        }
    }

    private func attach(to host: NSView) {
        controller.scrollView.removeFromSuperview()
        controller.scrollView.frame = host.bounds
        controller.scrollView.autoresizingMask = [.width, .height]
        host.addSubview(controller.scrollView)
        // No auto-focus: keeps arrow keys in the explorer while browsing files.
    }
}
