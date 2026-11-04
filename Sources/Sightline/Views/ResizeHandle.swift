import AppKit
import SwiftUI

/// 1 pt divider with a wider drag area that resizes the column to its left.
struct ResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    @State private var startWidth: Double?

    var body: some View {
        Rectangle()
            .fill(Color.ghBorder)
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .onHover { inside in
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
            }
    }
}
