/// Fans an account-scoped `watchtower jira …` subcommand out over every
/// enabled Jira site. The CLI's per-account commands (`boards`, `sync`, …)
/// resolve a default account only while exactly one is enabled — with two or
/// more they fail with "multiple Jira sites connected — pass --account <id>" —
/// so a screen-wide action runs once per enabled account instead.
package enum JiraAccountFanOut {
    /// One invocation per enabled account, `jira --account <id>` + `subcommand`,
    /// in the order given (`JiraAccountQueries.fetchAll` is oldest first and
    /// already drops removed rows).
    package static func invocations(
        for accounts: [JiraAccount],
        subcommand: [String]
    ) -> [(account: JiraAccount, arguments: [String])] {
        accounts.filter(\.enabled).map { account in
            (account, ["jira", "--account", String(account.id)] + subcommand)
        }
    }

    /// The per-site failures joined into one capped UI line, or nil when every
    /// site succeeded.
    package static func failureMessage(_ failures: [String]) -> String? {
        failures.isEmpty ? nil : String(failures.joined(separator: "; ").prefix(200))
    }
}
