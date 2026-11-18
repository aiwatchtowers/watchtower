import Foundation

/// The retired shared app on screen (screens spec §5, plan B Task 15). Go
/// decides which account is on it (`shared_app` in `slack accounts --json`);
/// these strings only follow that flag.
extension SlackModePresentation {
    /// The banner at the top of Connections → Slack. No dismiss: it goes when
    /// the account moves to its workspace's own app (the same row re-bound,
    /// history kept, ask #1425) or when Slack stops the token.
    package struct SharedAppBanner: Equatable, Sendable {
        package let title = "Watchtower's shared Slack app is retiring"
        package let body: String
        /// Opens the company setup (`SlackAppSetupModel.present`).
        package let setUpForCompany = "Set up for my company"
        /// Focuses the connect section's field (`SlackConnectFlowModel.reconnect(.connectSection)`).
        package let pasteLink = "Paste a connect link"

        init(label: String) {
            body = "\(label) still syncs through it until Slack turns it off. Move to Full with your workspace's "
                + "own app, or use Live through your Claude or ChatGPT account."
        }
    }

    /// The outline tag on a shared-app account's row.
    package static let sharedAppTag = "Shared app"

    /// The line under a shared-app account's name; the age only when a sync
    /// time is known.
    package static func sharedAppAccountLine(lastSync: Date?, now: Date) -> String {
        let line = "Syncing through the shared app"
        guard let lastSync else { return line }
        return line + " · last sync " + ago(from: lastSync, now: now)
    }

    /// The account row's sign-in button: **Move to Full** for an account
    /// Go routes `move` (on the retired app, which cannot sign in again;
    /// the press opens the connect section, A7), else Reconnect / Re-login.
    package static func reloginTitle(isOK: Bool, relogin: String?) -> String {
        if relogin == "move" { return "Move to Full" }
        return isOK ? "Reconnect" : "Re-login"
    }

    /// The Connections overview Slack card's status line while an account
    /// syncs through the shared app: not a problem (the card's status stays
    /// the accounts' own, so no badge), only a notice. nil otherwise.
    package static func overviewStatusLine(accounts: [SlackAccount], sharedAppAccountIDs: Set<Int>) -> String? {
        let shared = accounts.contains { $0.enabled && !$0.isGone && $0.isOK && sharedAppAccountIDs.contains($0.id) }
        return shared ? "Shared app retiring" : nil
    }
}
