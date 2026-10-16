import SwiftUI

/// The main action that stops or discards something (the recorder's Stop):
/// a red plate with a white label, drawn here from plain shapes (#397).
/// `.borderedProminent` + `.tint(.red)` leaves the plate and the label to
/// the system, which redraws both from the window's key state, the app's
/// activity and the accent — and in the recording capsule it showed a red
/// plate with no label at all. This style resolves none of those: the
/// label is white on red in every state, and the button keeps its ideal
/// width, so a crowded row can never squeeze the label away.
struct DestructivePrimaryButtonStyle: ButtonStyle {
    static let fill = Color.red
    static let label = Color.white

    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled
    /// A font set at the call site wins; the control size's text size is
    /// only the default.
    @Environment(\.font) private var font

    func makeBody(configuration: Configuration) -> some View {
        let metrics = Self.metrics(for: controlSize)
        let plate = RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
        configuration.label
            .font(font ?? .system(size: metrics.fontSize))
            .foregroundStyle(Self.label)
            .padding(.horizontal, metrics.horizontalPadding)
            .frame(minHeight: metrics.height)
            .background {
                plate.fill(Self.fill)
                if configuration.isPressed { plate.fill(.black.opacity(0.18)) }
            }
            .contentShape(plate)
            .opacity(isEnabled ? 1 : 0.5)
            .fixedSize()
    }

    struct Metrics: Equatable {
        let fontSize: CGFloat
        let height: CGFloat
        let horizontalPadding: CGFloat
        let cornerRadius: CGFloat
    }

    /// The system bordered button's sizes per control size, so the plate
    /// sits in a row of stock buttons without standing out.
    static func metrics(for size: ControlSize) -> Metrics {
        switch size {
        case .mini: Metrics(fontSize: 9, height: 15, horizontalPadding: 6, cornerRadius: 4)
        case .small: Metrics(fontSize: 11, height: 20, horizontalPadding: 8, cornerRadius: 5)
        case .large, .extraLarge: Metrics(fontSize: 13, height: 28, horizontalPadding: 12, cornerRadius: 7)
        default: Metrics(fontSize: 13, height: 22, horizontalPadding: 10, cornerRadius: 6)
        }
    }
}

extension ButtonStyle where Self == DestructivePrimaryButtonStyle {
    static var destructivePrimary: DestructivePrimaryButtonStyle { DestructivePrimaryButtonStyle() }
}
