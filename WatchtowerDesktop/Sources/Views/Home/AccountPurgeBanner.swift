import SwiftUI
import WatchtowerCore

/// Home's purge banner (board #601), above Getting ready: one red line per
/// account whose data will be deleted, each with **Reconnect**, which opens
/// the account's connection in Settings. No "keep my data" button: the way to
/// keep it is to restore access.
struct AccountPurgeBanner: View {
    let rows: [AccountPurge]
    var zone: TimeZone = .current
    let onReconnect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Tone.error)
                        .accessibilityHidden(true)
                    Text(AccountPurgeNoticePolicy.line(row, zone: zone))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Spacing.regular)
                    if row.state == "scheduled" {
                        Button("Reconnect") { onReconnect(row.source) }
                            .buttonStyle(.kitSecondary)
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(fill: Tone.error.opacity(ChipTint.fillOpacity))
    }
}
