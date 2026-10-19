import SwiftUI

/// A view button inside the header capsule: on = accent tint behind an
/// accent icon, off = secondary with a light highlight under the pointer.
/// Hover comes from the controls so Terminal and its chevron share it.
struct SegmentedToggleStyle: ToggleStyle {
    static let animation: Animation = .snappy(duration: 0.15)

    /// Terminal's: the sessions chevron continues the segment on the right.
    var joinsChevron = false
    /// False for a title-only segment: no icon copy, so no gap before the title.
    var showsIcon = true
    var isHovered: Bool
    var onHover: (Bool) -> Void

    static func fill(isOn: Bool, isHovered: Bool) -> Color {
        if isOn { return Fill.on }
        return isHovered ? Fill.hover : .clear
    }

    func makeBody(configuration: Configuration) -> some View {
        let isOn = configuration.isOn
        let corner: CGFloat = 6
        let trailing = joinsChevron ? 0 : corner
        return Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 6) {
                if showsIcon {
                    configuration.label
                        .labelStyle(.iconOnly)
                        .font(.system(size: 14))
                        .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                        // VoiceOver reads the title once, from the copy below.
                        .accessibilityHidden(true)
                }
                configuration.label
                    .labelStyle(.titleOnly)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isOn || isHovered ? Color.primary : Color.secondary)
            }
            .padding(.leading, 10)
            .padding(.trailing, joinsChevron ? 6 : 10)
            .frame(height: 22)
            .background(
                Self.fill(isOn: isOn, isHovered: isHovered),
                in: UnevenRoundedRectangle(topLeadingRadius: corner, bottomLeadingRadius: corner,
                                           bottomTrailingRadius: trailing, topTrailingRadius: trailing,
                                           style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover(perform: onHover)
        .animation(Self.animation, value: isOn)
        .animation(Self.animation, value: isHovered)
        // The role `.toggleStyle(.button)` gave the view buttons.
        .accessibilityAddTraits(isOn ? [.isToggle, .isSelected] : .isToggle)
    }
}
