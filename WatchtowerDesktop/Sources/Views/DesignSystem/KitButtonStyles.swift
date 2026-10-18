import SwiftUI

/// The kit's primary action (popovers and forms): prominent while it can
/// run, the plain bordered look while disabled. A disabled `.borderedProminent` button
/// draws its white label at reduced opacity on a pale fill of the accent
/// color, and under the Graphite accent (or any light accent in the light
/// theme) that fill is nearly the label's color — the button reads as a
/// blank gray plate. The bordered style keeps a dimmed but legible label.
struct KitPrimaryButtonStyle: PrimitiveButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        if isEnabled {
            Button(configuration).buttonStyle(.borderedProminent)
        } else {
            Button(configuration).buttonStyle(.bordered)
        }
    }
}

extension PrimitiveButtonStyle where Self == KitPrimaryButtonStyle {
    static var kitPrimary: KitPrimaryButtonStyle { KitPrimaryButtonStyle() }
}

/// The main action that stops or discards something (the recorder's Stop):
/// a red plate with a white label, drawn here from plain shapes (#397).
/// `.borderedProminent` + `.tint(.red)` leaves the plate and the label to
/// the system, which redraws both from the window's key state, the app's
/// activity and the accent — and in the recording capsule it showed a red
/// plate with no label at all. This style resolves none of those: the
/// label is white on red in every state, and the button keeps its ideal
/// width, so a crowded row can never squeeze the label away.
struct KitDestructiveButtonStyle: ButtonStyle {
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

    struct Metrics {
        let fontSize: CGFloat
        let height: CGFloat
        let horizontalPadding: CGFloat
        let cornerRadius: CGFloat
    }

    /// The shared size table (`KitButtonMetrics`) plus this plate's corner
    /// radius per control size, so the plate sits in a row of stock buttons
    /// without standing out.
    static func metrics(for size: ControlSize) -> Metrics {
        let base = KitButtonMetrics.metrics(for: size)
        let cornerRadius: CGFloat = switch size {
        case .mini: 4
        case .small: 5
        case .large, .extraLarge: 7
        default: 6
        }
        return Metrics(fontSize: base.fontSize, height: base.height,
                       horizontalPadding: base.horizontalPadding, cornerRadius: cornerRadius)
    }
}

extension ButtonStyle where Self == KitDestructiveButtonStyle {
    static var kitDestructive: KitDestructiveButtonStyle { KitDestructiveButtonStyle() }
}

/// Split and ⋯ beside the capsule: a 26pt icon square, highlighted under
/// the pointer; `isOn` (split) tints it like an on segment.
struct KitIconButtonStyle: ButtonStyle {
    var isOn: Bool

    /// Off the radius scale on purpose: it matches the header capsule's segments.
    private static let cornerRadius: CGFloat = 7

    func makeBody(configuration: Configuration) -> some View {
        IconSquare(configuration: configuration, isOn: isOn)
    }

    private struct IconSquare: View {
        let configuration: Configuration
        let isOn: Bool
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 14))
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                .frame(width: 26, height: 26)
                .background(
                    SegmentedToggleStyle.fill(isOn: isOn, isHovered: isHovered || configuration.isPressed),
                    in: RoundedRectangle(cornerRadius: KitIconButtonStyle.cornerRadius, style: .continuous)
                )
                .contentShape(Rectangle())
                .onHover { isHovered = $0 }
                .animation(SegmentedToggleStyle.animation, value: isOn)
                .animation(SegmentedToggleStyle.animation, value: isHovered)
        }
    }
}

extension ButtonStyle where Self == KitIconButtonStyle {
    static func kitIcon(isOn: Bool) -> KitIconButtonStyle { KitIconButtonStyle(isOn: isOn) }
}
