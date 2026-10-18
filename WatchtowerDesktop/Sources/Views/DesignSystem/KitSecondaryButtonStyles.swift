import SwiftUI

/// The kit's soft buttons (style guide #719): `.kitSecondary`, a neutral
/// plate for the action beside the main one (Cancel, Edit), and
/// `.kitQuiet`, an accent label with no plate until the pointer is over it
/// (Show more, Clear). Both draw from the kit's fills instead of the stock
/// bordered bezel, so they read like the Workbench's own controls.
struct KitSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        KitSoftButton(configuration: configuration, restFill: Fill.card, label: .primary)
    }
}

/// See `KitSecondaryButtonStyle`.
struct KitQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        KitSoftButton(configuration: configuration, restFill: .clear, label: .accentColor)
    }
}

extension ButtonStyle where Self == KitSecondaryButtonStyle {
    static var kitSecondary: KitSecondaryButtonStyle { KitSecondaryButtonStyle() }
}

extension ButtonStyle where Self == KitQuietButtonStyle {
    static var kitQuiet: KitQuietButtonStyle { KitQuietButtonStyle() }
}

/// The soft buttons' body: a view, so it can track the pointer.
private struct KitSoftButton: View {
    let configuration: ButtonStyleConfiguration
    let restFill: Color
    let label: Color

    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    /// A font set at the call site wins; the control size's text size is
    /// only the default.
    @Environment(\.font) private var font
    @State private var isHovered = false

    var body: some View {
        let metrics = KitButtonMetrics.metrics(for: controlSize)
        let plate = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        configuration.label
            .font(font ?? .system(size: metrics.fontSize))
            .foregroundStyle(label)
            .padding(.horizontal, metrics.horizontalPadding)
            .frame(minHeight: metrics.height)
            .background(plate.fill(isHovered || configuration.isPressed ? Fill.hover : restFill))
            .contentShape(plate)
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { isHovered = $0 }
            .animation(Motion.toggle, value: isHovered)
            .fixedSize()
    }
}

/// The system bordered button's sizes per control size (a copy of
/// `DestructivePrimaryButtonStyle.metrics(for:)`), so a soft button sits in
/// a row of stock buttons at the same height.
enum KitButtonMetrics {
    struct Metrics: Equatable {
        let fontSize: CGFloat
        let height: CGFloat
        let horizontalPadding: CGFloat
    }

    static func metrics(for size: ControlSize) -> Metrics {
        switch size {
        case .mini: Metrics(fontSize: 9, height: 15, horizontalPadding: 6)
        case .small: Metrics(fontSize: 11, height: 20, horizontalPadding: 8)
        case .large, .extraLarge: Metrics(fontSize: 13, height: 28, horizontalPadding: 12)
        default: Metrics(fontSize: 13, height: 22, horizontalPadding: 10)
        }
    }
}
