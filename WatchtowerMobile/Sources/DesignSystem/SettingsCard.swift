import SwiftUI

/// A titled group of settings, the Desktop's `SettingsSection` at phone
/// size (mockup 16): the caps header, the rows on one soft `Fill.card`
/// card (`Radius.container`) with a `CardRowDivider` between each two, and
/// an optional footer note under it. For a `ScrollView` page padded 16 on
/// the sides.
///
///     SettingsCard(title: "Workbench") {
///         SettingsRow(title: "Type into sessions") { Toggle("", isOn: $typing).toggleStyle(SmallSwitchStyle()) }
///         CardRowDivider()
///         SettingsRow(title: "Start sessions") { Toggle("", isOn: $start).toggleStyle(SmallSwitchStyle()) }
///     }
struct SettingsCard<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title)
                .padding(.horizontal, -Spacing.large)
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, Spacing.medium)
                .padding(.vertical, Spacing.tight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Fill.card, in: RoundedRectangle(cornerRadius: Radius.container, style: .continuous))
            if let footer {
                Text(footer)
                    .font(TypeScale.meta)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.small)
                    .padding(.top, Spacing.compact)
            }
        }
    }
}

/// One setting row: the title and an optional caption on the left, the
/// control or value trailing, at least 44 pt tall. One accessibility
/// element labelled by the title (the caption is its hint).
struct SettingsRow<Trailing: View>: View {
    let title: String
    var caption: String?
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: Spacing.medium) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(title).font(TypeScale.rowTitle)
                if let caption {
                    Text(caption).font(TypeScale.meta).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Spacing.medium)
            trailing
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: PhoneMetrics.minTouch)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityHint(caption ?? "")
    }
}

/// Mockup 16's small switch (42 × 25): green when on (`Tone.success`), the
/// card fill under a hairline when off, a white knob with the floating
/// shadow; the whole 44 pt row height is the hit area. VoiceOver hears a
/// switch named by its `SettingsRow` (the toggle's own label stays unused).
struct SmallSwitchStyle: ToggleStyle {
    static func trackFill(isOn: Bool) -> Color {
        isOn ? PhoneTone.green.color : Fill.card
    }

    func makeBody(configuration: Configuration) -> some View {
        let size = PhoneMetrics.switchSize
        let knob = size.height - 2 * Spacing.tight
        Button {
            withAnimation(Motion.toggle) { configuration.isOn.toggle() }
        } label: {
            Capsule()
                .fill(Self.trackFill(isOn: configuration.isOn))
                .overlay {
                    if !configuration.isOn {
                        Capsule().strokeBorder(Stroke.hairlineColor, lineWidth: Stroke.hairline)
                    }
                }
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .frame(width: knob, height: knob)
                        .shadow(color: FloatingShadow.color, radius: FloatingShadow.radius, y: FloatingShadow.y)
                        .padding(Spacing.tight)
                }
                .frame(width: size.width, height: size.height)
                .frame(minHeight: PhoneMetrics.minTouch)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}
