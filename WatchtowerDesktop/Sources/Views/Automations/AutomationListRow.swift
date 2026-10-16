import SwiftUI
import WatchtowerCore

/// One two-line row of the Automations list (spec §12.1): the name with its
/// badges or last status on the right, then the trigger and the state's fact.
struct AutomationListRow: View {
    let item: AutomationListItem
    /// The loaded `show --json` detail's `changes`, if this row's card was opened.
    let changes: [AutomationChange]?
    let isSelected: Bool
    let now: Date
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.automation.name.isEmpty ? item.automation.slug : item.automation.name)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    trailing
                }
                Text(AutomationCardPresentation.rowDetailLine(item, changes: changes, now: now))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
            .overlay(alignment: .leading) {
                if isSelected {
                    Rectangle().fill(Color.accentColor).frame(width: 3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var trailing: some View {
        if item.badges.isEmpty {
            if let pill = AutomationCardPresentation.statusPill(item) {
                AutomationStatusPill(pill: pill)
            }
        } else {
            HStack(spacing: 4) {
                ForEach(item.badges, id: \.self) { AutomationRowBadgeView(badge: $0) }
            }
        }
    }
}
