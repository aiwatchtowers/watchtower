import SwiftUI
import WatchtowerCore

/// One row of the Automations list (spec 2026-10-24 §1), a tab of the
/// `panelSurface()` list: the on/off dot, the name and its compact state;
/// the one-line summary; the trigger and its fact (the error first, in the
/// warning tone, when the last run failed). The selected row runs on into
/// the detail beside it (`panelTab(isSelected:)`).
struct AutomationListRow: View {
    let item: AutomationListItem
    /// The loaded `show --json` detail's `changes`, if this row's card was opened.
    let changes: [AutomationChange]?
    let isSelected: Bool
    let now: Date
    let onSelect: () -> Void

    var body: some View {
        let state = AutomationRowPresentation.state(item, now: now)
        AutomationRowContent(
            isOn: AutomationRowPresentation.isOn(item),
            isDraft: false,
            name: item.automation.name.isEmpty ? item.automation.slug : item.automation.name,
            state: state,
            summary: AutomationRowPresentation.summary(item),
            line: AutomationRowPresentation.line(item, changes: changes, now: now),
            lineIsWarning: AutomationRowPresentation.isFailed(item)
        )
        .panelTab(isSelected: isSelected)
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onSelect() }
    }
}

/// A New automation chat with a draft on disk: listed at the top of its
/// section with a dashed dot and the **Draft** chip; it opens the editor on
/// that chat.
struct AutomationDraftListRow: View {
    let row: AutomationDraftRow
    let isSelected: Bool
    let now: Date
    let onSelect: () -> Void

    var body: some View {
        AutomationRowContent(
            isOn: false,
            isDraft: true,
            name: row.name,
            state: .chip(.draft),
            summary: row.summary,
            line: "Not saved · edited \(AutomationCardPresentation.relative(now.timeIntervalSince(row.updatedAt))) ago",
            lineIsWarning: false
        )
        .panelTab(isSelected: isSelected)
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onSelect() }
    }
}

/// A group's header (BUILT IN, PERSONAL, a workbench): the chevron, the
/// label, the count and, while folded, what the group still needs from the
/// owner ("1 failed"). A click folds or opens it.
struct AutomationSectionHeader: View {
    let section: AutomationListSection
    let expanded: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: Spacing.small) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
                Text(section.title.uppercased())
                    .sidebarSectionLabel()
                    .lineLimit(1)
                Text("\(section.count)")
                    .sidebarSectionLabel()
                if !expanded, !section.attention.isEmpty {
                    attentionText.font(.caption2).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, Spacing.regular)
        .padding(.bottom, Spacing.tight)
        .listRowInsets(EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .help(expanded ? "Hide this group" : "Show this group")
        .accessibilityLabel("\(section.title), \(section.count), \(expanded ? "expanded" : "collapsed")")
        .accessibilityAddTraits(.isHeader)
    }
}

extension AutomationSectionHeader {
    /// "· 1 failed · 1 draft": warnings in the warning tone, the rest secondary.
    private var attentionText: Text {
        section.attention.enumerated().reduce(Text("")) { text, entry in
            text + Text(entry.offset == 0 ? "· " : " · ").foregroundStyle(.secondary)
                + Text(entry.element.text).foregroundStyle(entry.element.isWarning ? Tone.warning : Color.secondary)
        }
    }
}

/// The three lines both row kinds share.
private struct AutomationRowContent: View {
    let isOn: Bool
    let isDraft: Bool
    let name: String
    let state: AutomationRowState
    let summary: String?
    let line: String
    let lineIsWarning: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            dot
            VStack(alignment: .leading, spacing: Spacing.tight) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                    Text(name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: Spacing.small)
                    stateView
                }
                if let summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(line)
                    .font(.caption)
                    .foregroundStyle(lineIsWarning ? AnyShapeStyle(Tone.warning) : AnyShapeStyle(.tertiary))
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var dot: some View {
        if isDraft {
            Circle()
                .strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
                .frame(width: IconSize.chevron, height: IconSize.chevron)
                .accessibilityLabel("Draft")
        } else {
            Circle()
                .fill(isOn ? Tone.success : Color.secondary)
                .frame(width: IconSize.chevron, height: IconSize.chevron)
                .accessibilityLabel(isOn ? "On" : "Off")
        }
    }

    @ViewBuilder private var stateView: some View {
        switch state {
        case let .chip(chip):
            Chip(text: chip.title, color: Self.color(chip))
        case .failed:
            stateText("failed").foregroundStyle(Tone.warning)
        case .off:
            stateText("off").foregroundStyle(.secondary)
        case let .lastRun(ok, ago):
            stateText((ok ? "ok · " : "failed · ") + ago).foregroundStyle(.secondary)
        case let .next(text):
            stateText(text).foregroundStyle(.secondary)
        case .none:
            EmptyView()
        }
    }

    private func stateText(_ text: String) -> Text {
        Text(text).font(.caption)
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
