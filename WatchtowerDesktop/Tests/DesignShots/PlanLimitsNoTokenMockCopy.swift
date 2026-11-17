import Foundation

/// Design-only string table of the plan limits without a token spec
/// (`docs/superpowers/specs/2026-11-17-plan-limits-without-token-design.md`,
/// target #1885). The implementation moves these strings into
/// `PlansPresentation.errorText` (per provider) and pins them in
/// `PlansPresentationTests`; `PlanLimitsNoTokenMockCopyTests` pins this table
/// so the mockups and the spec cannot drift apart.
enum PlanLimitsNoTokenMockCopy {
    /// `cli_missing` for Claude: the `claude` command was not found.
    static let cliMissing = "Install Claude Code, then retry."
    /// `unsupported_cli` for Claude: the installed Claude Code does not answer
    /// the usage request.
    static let cliOutdated = "Update Claude Code to read plan limits, then retry."
    /// `no_credentials` for Claude: Claude Code is signed out, or signed in with
    /// an API key (no plan limits apply).
    static let notSignedIn = "Sign in to Claude Code with your Claude plan, then retry."
}
