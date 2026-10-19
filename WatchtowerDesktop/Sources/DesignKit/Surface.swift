import AppKit
import SwiftUI

extension NSColor {
    /// The detail backdrop `MainNavigationView` puts behind every tab — what
    /// the AI Chat conversation sits on, beside its lighter history panel.
    /// The Workbench workspace (page header, terminal, Board, Files) and
    /// the selected row of a tabbed panel (`PanelTab`) paint it too, so they
    /// read as AI Chat does and can never drift from it.
    ///
    /// In Dark it is the panel colour (`windowBackgroundColor`) 40% toward
    /// black, not `controlBackgroundColor`: macOS 15 draws those two 50 and
    /// 30 (the blend gives the same 30), but macOS 26 draws both 30, which
    /// left the content and the selected tab in the panel's colour.
    public static var detailBackground: NSColor {
        NSColor(name: nil) { appearance in
            guard appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua else {
                return .controlBackgroundColor
            }
            var color = Self.controlBackgroundColor
            appearance.performAsCurrentDrawingAppearance {
                if let panel = Self.windowBackgroundColor.usingColorSpace(.sRGB),
                   let darker = panel.blended(withFraction: 0.4, of: .black) {
                    color = darker
                }
            }
            return color
        }
    }
}

/// The app's background colours by role.
public enum Surface {
    public static var detail: Color { Color(nsColor: .detailBackground) }
    public static var window: Color { Color(nsColor: .windowBackgroundColor) }
    public static var text: Color { Color(nsColor: .textBackgroundColor) }
    public static var control: Color { Color(nsColor: .controlBackgroundColor) }
}

extension View {
    /// The side panels' background: the app sidebar's colour.
    public func panelBackground() -> some View {
        background(Color(nsColor: .windowBackgroundColor))
    }

    /// The darker surface a tab's content sits on (`NSColor.detailBackground`).
    public func detailBackground() -> some View {
        background(Color(nsColor: .detailBackground))
    }
}
