import Foundation
import WatchtowerCore

/// `watchtower briefing generate` for the Inbox's day card (**Make today's
/// brief**). AppState-owned, so a run in flight — and its failure — survive
/// leaving the Inbox. The day card reads its briefing through the Inbox's own
/// read (`InboxFeedQueries`), so this view model reads no briefings.
@MainActor
@Observable
final class BriefingViewModel {
    /// True while `briefing generate` CLI process is running.
    var isGenerating = false
    var generateError: String?

    /// nil when the watchtower binary cannot be found.
    private let cli: (any CLIRunnerProtocol)?

    /// `dbManager` is unused since the day card reads through the Inbox; the
    /// label stays so every call site (the OWNER-02 guards among them) keeps
    /// its shape.
    init(dbManager _: DatabaseManager, cliRunner: (any CLIRunnerProtocol)? = ProcessCLIRunner.makeDefault()) {
        self.cli = cliRunner
    }

    // MARK: - Generate

    /// Runs `watchtower briefing generate`. A non-zero exit — e.g. the CLI's
    /// "no owner identity" refusal (OWNER-02) — lands its stderr in
    /// `generateError` (via `CLIRunnerError`) instead of vanishing.
    ///
    /// A no-op while a run is already in flight: this VM lives on AppState
    /// (so the flag survives a tab switch), and a second click must not
    /// start a parallel strong-tier `briefing generate` racing the first.
    func generateBriefing() async {
        guard !isGenerating else { return }
        guard let cli else {
            generateError = "watchtower binary not found"
            return
        }

        isGenerating = true
        generateError = nil
        defer { isGenerating = false }

        do {
            _ = try await cli.run(args: ["briefing", "generate"])
        } catch {
            generateError = error.localizedDescription
        }
    }
}
