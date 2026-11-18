import Foundation

/// Design-only string table of the plan limits without a token spec
/// (`docs/superpowers/specs/2026-11-17-plan-limits-without-token-design.md`,
/// target #1885), kept as the spec's pinned table. Production words these
/// codes from `SubscriptionUsagePolicy.messages` (pinned in
/// `PlansPresentationTests`); `PlanLimitsNoTokenMockCopyTests` pins this table
/// and cross-checks it against production, so the mockups, the spec and the
/// app cannot drift apart.
enum PlanLimitsNoTokenMockCopy {
    /// `cli_missing` for Claude: the `claude` command was not found.
    static let cliMissing = "Install Claude Code, then retry."
    /// `unsupported_cli` for Claude: the installed Claude Code does not answer
    /// the usage request.
    static let cliOutdated = "Update Claude Code to read plan limits, then retry."
    /// `no_credentials` for Claude: Claude Code is signed out.
    static let notSignedIn = "Sign in to Claude Code with your Claude plan, then retry."
    /// `unsupported_auth` for Claude: the child's environment carries an API
    /// key, so plan limits do not apply.
    static let apiKey = "Claude Code is using an API key here, so plan limits don't apply."
    /// `cloud_bedrock` / `cloud_vertex` / `cloud_foundry` for Claude: a copy
    /// variant of `apiKey` (same layout and tone; compared with its mockup).
    static func cloudProvider(_ name: String) -> String {
        "Claude Code is using \(name) here, so plan limits don't apply."
    }
    static let cloudProviders = ["cloud_bedrock": "Bedrock", "cloud_vertex": "Vertex", "cloud_foundry": "Foundry"]
}
