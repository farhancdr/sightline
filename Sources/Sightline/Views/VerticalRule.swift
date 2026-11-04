import SwiftUI

/// 1 pt vertical line in the theme's border color (visible in dark mode, unlike the system divider).
struct VerticalRule: View {
    var body: some View {
        Rectangle().fill(Color.ghBorder).frame(width: 1)
    }
}
