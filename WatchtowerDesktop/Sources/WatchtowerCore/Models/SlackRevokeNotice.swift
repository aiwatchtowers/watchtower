import Foundation

/// The warning `slack remove` and `auth logout` print when Slack did not
/// confirm the token revoke (#1769, A3). The remove still goes through: the
/// CLI exits 0 and prints the warning on stdout, where the Desktop finds it by
/// this exact text (Go `slackRevokeWarning` in `cmd/slack.go`; both sides are
/// pinned) and shows it as a notice in Connections → Slack.
package enum SlackRevokeNotice {
    package static let cliWarning =
        "Slack did not confirm the token was revoked; it may stay valid until a workspace admin removes the app"

    /// The notice to show for one successful remove's stdout, nil when Slack
    /// confirmed the revoke.
    package static func notice(inCLIOutput stdout: String) -> String? {
        stdout.contains(cliWarning) ? cliWarning : nil
    }
}
