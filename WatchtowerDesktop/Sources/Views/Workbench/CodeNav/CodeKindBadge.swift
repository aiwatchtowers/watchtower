import SwiftUI
import WatchtowerCore

/// A symbol kind's badge: an 18 pt rounded square with its letter in
/// monospace, coloured from the editor theme (`wt-light`/`wt-dark`, spec §2
/// decision 2). Shared by Open Quickly, the definition menu, Usages and the
/// jump bar.
struct CodeKindBadge: View {
    let kind: CodeSymbolKind
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let color = CodeThemeColors.color(kind.badgeRole, scheme: colorScheme)
        Text(kind.badgeLetter)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .frame(width: 18, height: 18)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color.opacity(0.35)))
            .accessibilityLabel(kind.rawValue)
    }
}

/// `CodeThemePalette` as SwiftUI colours for the current appearance — the
/// same appearance the editor page follows (`prefers-color-scheme`).
enum CodeThemeColors {
    static func palette(_ scheme: ColorScheme) -> CodeThemePalette {
        scheme == .dark ? .dark : .light
    }

    static func color(_ role: CodeTokenRole, scheme: ColorScheme) -> Color {
        color(rgb: palette(scheme).rgb(role))
    }

    static func color(rgb: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}
