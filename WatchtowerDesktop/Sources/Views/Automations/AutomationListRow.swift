import SwiftUI
import WatchtowerCore

/// One row of the Automations list (spec A1): the on/off dot, the name and
/// its chips, then the trigger and the state's fact ("Off · …" for an off
/// recipe). A selected row has the kit's selection fill.
struct AutomationListRow: View {
    let item: AutomationListItem
    /// The loaded `show --json` detail's `changes`, if this row's card was opened.
    let changes: [AutomationChange]?
    let isSelected: Bool
    let now: Date
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            AutomationRowContent(
                isOn: AutomationRowPresentation.isOn(item),
                name: item.automation.name.isEmpty ? item.automation.slug : item.automation.name,
                chips: AutomationRowPresentation.chips(item),
                line: AutomationRowPresentation.line(item, changes: changes, now: now)
            )
            .kitRow(isSelected: isSelected)
        }
        .buttonStyle(.plain)
    }
}

/// A New automation chat with a draft on disk: listed at the top of its
/// section with the **Draft** chip; it opens the editor on that chat.
struct AutomationDraftListRow: View {
    let row: AutomationDraftRow
    let isSelected: Bool
    let now: Date
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            AutomationRowContent(
                isOn: false,
                name: row.name,
                chips: [.draft],
                line: "Not saved yet · edited \(AutomationCardPresentation.relative(now.timeIntervalSince(row.updatedAt))) ago"
            )
            .kitRow(isSelected: isSelected)
        }
        .buttonStyle(.plain)
    }
}

/// The two lines both row kinds share.
private struct AutomationRowContent: View {
    let isOn: Bool
    let name: String
    let chips: [AutomationRowChip]
    let line: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Circle()
                .fill(isOn ? Tone.success : Color.secondary)
                .frame(width: IconSize.chevron, height: IconSize.chevron)
                .accessibilityLabel(isOn ? "On" : "Off")
            VStack(alignment: .leading, spacing: Spacing.tight) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                    Text(name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: Spacing.small)
                    ForEach(chips, id: \.self) { chip in
                        Chip(text: chip.title, color: Self.color(chip))
                    }
                }
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .contentShape(Rectangle())
    }

    private static func color(_ chip: AutomationRowChip) -> Color {
        switch chip {
        case .needsConfirmation: Tone.warning
        case .paused: Color.secondary
        case .cantRead: Tone.error
        case .draft: Color.accentColor
        }
    }
}
