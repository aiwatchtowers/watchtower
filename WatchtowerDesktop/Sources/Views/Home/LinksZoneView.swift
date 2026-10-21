import SwiftUI
import WatchtowerCore

/// Home's links zone: Briefing, Catch-Up, Day plan and Digests — the ones
/// whose tab is visible — each with a short status on the right ("ready
/// 08:12", "new recap" highlighted, "2 of 6 done"). A failed read says so;
/// the rows still open their tabs.
struct LinksZoneView: View {
    let links: [HomeLinkRow]
    let failed: Bool
    let onLink: (HomeLink) -> Void

    var body: some View {
        HomeZone(title: "Links") {
            if failed {
                HomeZoneErrorLine(zone: "the links")
            }
            ForEach(Array(links.enumerated()), id: \.offset) { _, row in
                linkRow(row)
            }
        }
    }

    private func linkRow(_ row: HomeLinkRow) -> some View {
        Button { onLink(row.link) } label: {
            HStack(spacing: Spacing.regular) {
                Image(systemName: Self.symbol(row.kind))
                    .foregroundStyle(.tertiary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(row.title)
                Spacer(minLength: Spacing.regular)
                if let status = row.status {
                    Text(status)
                        .font(.caption.weight(row.highlighted ? .semibold : .regular))
                        .foregroundStyle(row.highlighted ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                }
            }
            .kitRow(isSelected: false)
        }
        .buttonStyle(.plain)
    }

    static func symbol(_ kind: HomeLinkKind) -> String {
        switch kind {
        case .briefing: "sun.max"
        case .catchUp: "arrow.counterclockwise"
        case .dayPlan: "checklist"
        case .digests: "list.bullet"
        }
    }
}
