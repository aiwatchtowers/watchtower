import Foundation

/// The add-site sheet's Confluence half (#573): with "Also connect
/// Confluence" checked the connect's consent also asks for Confluence, and
/// the board step selects up to five spaces the owner wrote in or viewed
/// lately (`confluence --account N select --recent`) — no extra step, no
/// second sign-in. Pure: which sites, which calls, and the one line the step
/// shows. Driven by `ConfluenceConnectSelection`.
package enum ConfluenceConnectStep {
    /// How the selection ended, in the order the step checks.
    package enum Outcome: Equatable {
        /// "Confluence in search" (`knowledge-connectors`) is off: nothing
        /// selected, like Settings' own Confluence section.
        case featureOff
        /// No site the connect added (the before-read failed, or a
        /// re-consent of a known site).
        case noSite
        /// The grant came back without the Confluence scopes: Atlassian
        /// refused them (the CLI then connected Jira only) or dropped them.
        case notEnabled
        case failed([String])
        /// The spaces now selected (possibly none found).
        case selected([String])
    }

    /// The enabled sites the connect added (not in `before`). None when the
    /// before-read failed: unlike the board list there is no "every site"
    /// fallback, so an existing site never gets spaces it did not ask for.
    package static func addedSites(_ accounts: [JiraAccount], before: Set<Int>?) -> [JiraAccount] {
        guard let before else { return [] }
        return accounts.filter { $0.enabled && !before.contains($0.id) }
    }

    /// `confluence --account <id> access --json` (the stored grant only).
    package static func accessArgs(accountID: Int) -> [String] {
        ["confluence", "--account", String(accountID), "access", "--json"]
    }

    /// `confluence --account <id> select --recent`.
    package static func selectArgs(accountID: Int) -> [String] {
        ["confluence", "--account", String(accountID), "select", "--recent"]
    }

    /// A CLI failure in plain words: a consent-shaped hint (it names a
    /// `jira login … --with-confluence` command) becomes a sentence, never a
    /// command line.
    package static func failureText(_ message: String) -> String {
        message.contains("--with-confluence") ? "Confluence access isn't granted" : message
    }

    private static let settings = "Settings → Connections → Jira"

    /// The step's Confluence line.
    package static func line(_ outcome: Outcome) -> String {
        switch outcome {
        case .featureOff:
            return "Turn on Confluence in search (Settings → Features) to sync your spaces."
        case .noSite:
            return "Confluence: choose spaces in \(settings)."
        case .notEnabled:
            return "Jira connected; Confluence isn't enabled for this Atlassian app."
        case .failed(let failures):
            return "Confluence: couldn't choose spaces (\(failures.joined(separator: "; "))). "
                + "Choose them in \(settings)."
        case .selected(let names) where names.isEmpty:
            return "Confluence: no space you wrote in or viewed in the last 90 days. Choose spaces in \(settings)."
        case .selected(let names):
            let count = names.count == 1 ? "1 space" : "\(names.count) spaces"
            return "Confluence: syncing \(count) you work in — \(names.joined(separator: ", ")). "
                + "Choose more in \(settings)."
        }
    }
}
