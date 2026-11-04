import AppKit
import SwiftUI

/// Draggable divider that resizes the column to its left. It takes real layout width (8 pt), so the
/// neighbouring editor/terminal views can't sit on top of it and swallow the mouse. A grip is always
/// visible; it highlights on hover and while dragging, like VS Code's sash.
struct ResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    @State private var startWidth: Double?
    @State private var hovering = false

    private var isActive: Bool { hovering || startWidth != nil }

    var body: some View {
        ZStack {
            Color.ghSidebar
            Rectangle()
                .fill(isActive ? Color.ghAccent : Color.ghBorder)
                .frame(width: isActive ? 2 : 1)
            Capsule()
                .fill(isActive ? Color.ghAccent : Color.ghMuted.opacity(0.5))
                .frame(width: 4, height: 32)
        }
        .frame(width: 8)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let start = startWidth ?? width
                    startWidth = start
                    width = min(range.upperBound, max(range.lowerBound, start + value.translation.width))
                }
                .onEnded { _ in startWidth = nil }
        )
        .help("Drag to resize")
        .animation(.easeOut(duration: 0.12), value: isActive)
    }
}
