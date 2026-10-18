import Foundation

/// The add-site sheet's Confluence half (#573): with "Also connect
/// Confluence" checked the connect's consent also grants Confluence, and the
/// board step selects the spaces the owner wrote in or viewed lately
/// (`confluence --account N select --recent`) — no extra step, no second
/// sign-in. Pure: which sites, which call, and the one line the step shows.
package enum ConfluenceConnectStep {
    /// The enabled sites the connect added (not in `before`). None when the
    /// before-read failed: unlike the board list there is no "every site"
    /// fallback, so an existing site never gets spaces it did not ask for.
    package static func addedSites(_ accounts: [JiraAccount], before: Set<Int>?) -> [JiraAccount] {
        guard let before else { return [] }
        return accounts.filter { $0.enabled && !before.contains($0.id) }
    }

    /// `confluence --account <id> select --recent`.
    package static func selectArgs(accountID: Int) -> [String] {
        ["confluence", "--account", String(accountID), "select", "--recent"]
    }

    /// The step's Confluence line: the spaces now synced, that none was
    /// found, or why the selection failed — each pointing at Settings, where
    /// the spaces can be changed. `siteFound` false (no added site to
    /// select on) only points at Settings.
    package static func summary(siteFound: Bool = true, spaceNames: [String], failures: [String]) -> String {
        let settings = "Settings → Connections → Jira"
        if !siteFound {
            return "Confluence: choose spaces in \(settings)."
        }
        if !failures.isEmpty {
            return "Confluence: couldn't choose spaces (\(failures.joined(separator: "; "))). "
                + "Choose them in \(settings)."
        }
        if spaceNames.isEmpty {
            return "Confluence: no space you wrote in or viewed lately. Choose spaces in \(settings)."
        }
        return "Confluence: syncing the spaces you work in — \(spaceNames.joined(separator: ", ")). "
            + "Change them in \(settings)."
    }
}
