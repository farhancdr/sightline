import AppKit
import SwiftUI

/// Stops AppKit's rubber-band overscroll on the scroll view that encloses it, so a list ends where
/// its content ends (VS Code's file tree behaviour) instead of springing back.
///
/// SwiftUI has no modifier for this: `scrollBounceBehavior` only governs content *smaller* than the
/// scroll view. Setting `NSScrollView.verticalScrollElasticity` does work, but SwiftUI's private
/// `ListCoreScrollView` puts it back to `.allowed` on every layout pass, so a one-shot assignment
/// loses the race. The reliable moment is the gesture itself: AppKit reads elasticity while it
/// scrolls, and `willStartLiveScroll` / `didLiveScroll` bracket exactly that window.
///
/// Put it in the background of a *row*, not of the `List`: a List's background is applied outside
/// the scroll view, where `enclosingScrollView` is nil.
extension View {
    /// Stops the enclosing list or scroll view from rubber-banding past its content.
    ///
    /// Apply it to a **row**, not to the `List` itself: a List's own `.background` is placed
    /// outside the scroll view, where there is nothing to find.
    func noScrollBounce() -> some View { background(NoScrollElasticity()) }
}

struct NoScrollElasticity: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ElasticityDisablingView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ElasticityDisablingView)?.attach()
    }
}

private final class ElasticityDisablingView: NSView {
    private weak var observed: NSScrollView?
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attach()
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Subscribes to the enclosing scroll view's live-scroll notifications once, then clamps
    /// elasticity on every one of them.
    func attach() {
        guard let scrollView = enclosingScrollView else { return }
        guard scrollView !== observed else {
            disable(scrollView)
            return
        }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = [
            NSScrollView.willStartLiveScrollNotification,
            NSScrollView.didLiveScrollNotification,
            NSScrollView.didEndLiveScrollNotification,
        ].map { name in
            NotificationCenter.default.addObserver(forName: name, object: scrollView, queue: .main) { note in
                guard let scrollView = note.object as? NSScrollView else { return }
                scrollView.verticalScrollElasticity = .none
                scrollView.horizontalScrollElasticity = .none
            }
        }
        observed = scrollView
        disable(scrollView)
    }

    private func disable(_ scrollView: NSScrollView) {
        if scrollView.verticalScrollElasticity != .none { scrollView.verticalScrollElasticity = .none }
        if scrollView.horizontalScrollElasticity != .none { scrollView.horizontalScrollElasticity = .none }
    }
}
