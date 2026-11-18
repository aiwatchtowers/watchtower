import SwiftUI
import WatchtowerCore
import DesignKit

/// The non-blocking notice of a Slack remove or Disconnect whose token revoke
/// Slack did not confirm (#1769, `SlackRevokeNotice`): the remove went
/// through, the sign-in may stay valid until a workspace admin removes the app.
struct SlackRevokeNoticeLine: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.regular) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
        }
    }
}
