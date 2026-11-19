import SwiftUI
import WatchtowerCore

/// Home's Watchman row (spec §10): last night in one line; a click opens
/// the journal in the Inbox.
struct WatchmanHomeRow: View {
    let counts: WatchmanNightCounts
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                Image(systemName: "moon.stars")
                    .foregroundStyle(WatchmanJournalStyle.tone)
                    .accessibilityHidden(true)
                Text(WatchmanJournalCopy.homeRow(counts))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: Spacing.regular)
                Image(systemName: "chevron.right")
                    .font(.system(size: IconSize.chevron, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Spacing.medium)
            .padding(.vertical, Spacing.regular)
            .contentShape(Rectangle())
            .card()
        }
        .buttonStyle(.plain)
    }
}
