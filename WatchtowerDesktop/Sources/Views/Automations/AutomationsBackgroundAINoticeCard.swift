import SwiftUI
import WatchtowerCore

/// The card above the Automations list while background AI is paused and a
/// recipe waits for it (#1886, spec §6.4). The button sits under the text:
/// the list column is narrow.
struct AutomationsBackgroundAINoticeCard: View {
    let notice: AutomationsBackgroundAINotice
    let onAllow: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Image(systemName: notice.isOrganization ? "lock.fill" : "pause.circle")
                .foregroundStyle(notice.isOrganization ? Color.secondary : Tone.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Spacing.regular) {
                Text(notice.text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let title = notice.actionTitle {
                    Button(title, action: onAllow)
                        .buttonStyle(.kitSecondary)
                        .controlSize(.small)
                }
            }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
