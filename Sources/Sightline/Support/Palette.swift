import AppKit
import SwiftUI

/// GitHub Light Default / Dark Default colors (Primer), resolved per appearance.
/// One place for UI, git status, syntax, diff and terminal colors.
enum Palette {
    static func color(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return rgb(isDark ? dark : light).withAlphaComponent(isDark ? darkAlpha : lightAlpha)
        }
    }

    static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }

    // MARK: Surfaces & text

    /// Editor / diff / terminal background (canvas.default).
    static let canvas = color(0xFFFFFF, 0x0D1117)
    /// Side panels (VS Code GitHub theme sideBar.background).
    static let sidebar = color(0xF6F8FA, 0x010409)
    static let border = color(0xD1D9E0, 0x3D444D)
    static let text = color(0x1F2328, 0xE6EDF3)
    static let textMuted = color(0x59636E, 0x9198A1)
    static let accent = color(0x0969DA, 0x4493F8)
    static let folder = color(0x54AEFF, 0x54AEFF)

    // MARK: Git status (VS Code GitHub theme gitDecoration.*)

    static let added = color(0x1A7F37, 0x3FB950)
    static let modified = color(0x9A6700, 0xD29922)
    static let deleted = color(0xD1242F, 0xF85149)
    static let conflict = color(0xBC4C00, 0xDB6D28)
    static let renamed = color(0x8250DF, 0xAB7DF8)

    static func status(_ code: Character?) -> NSColor? {
        switch code {
        case "?", "A": added
        case "D": deleted
        case "U": conflict
        case "R", "C": renamed
        case nil: nil
        default: modified
        }
    }
}

/// SwiftUI accessors.
extension Color {
    static let ghCanvas = Color(nsColor: Palette.canvas)
    static let ghSidebar = Color(nsColor: Palette.sidebar)
    static let ghBorder = Color(nsColor: Palette.border)
    static let ghText = Color(nsColor: Palette.text)
    static let ghMuted = Color(nsColor: Palette.textMuted)
    static let ghAccent = Color(nsColor: Palette.accent)
    static let ghFolder = Color(nsColor: Palette.folder)
    static let ghAdded = Color(nsColor: Palette.added)
    static let ghModified = Color(nsColor: Palette.modified)
    static let ghDeleted = Color(nsColor: Palette.deleted)
    static let ghConflict = Color(nsColor: Palette.conflict)

    static func ghStatus(_ code: Character?) -> Color? {
        Palette.status(code).map { Color(nsColor: $0) }
    }
}
