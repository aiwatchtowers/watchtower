/// The Desktop's launches of the `watchtower` binary that bypass `CLIRunner`
/// (their own `Process`), each with what it runs and why (#1886 Task 18, the
/// scan net of Decision 11). `DesktopModelLaunchSitesTests` finds every file
/// under `Sources/` that references `Constants.findCLIPath()` and builds a
/// `Process`, and fails on one missing here or listed here no longer.
enum DesktopProcessLaunchSites {
    /// Whether a site's launches call a model, and who starts them.
    enum Launch {
        /// No model command (account flows, `sync` control, `db` upkeep).
        case noModel
        /// Model commands, each after the owner's gesture: the file builds the
        /// child's environment through `CLIOrigin.owner.environment`.
        case owner
        /// Model commands started by a timer, a sync cycle or an event: the
        /// file builds the environment through `CLIOrigin.background.environment`,
        /// which sets `WATCHTOWER_AI_ORIGIN`.
        case background
    }

    struct Site {
        let launch: Launch
        let reason: String
    }

    /// Keyed by the path below `WatchtowerDesktop/Sources/`.
    static let sites: [String: Site] = [
        "WatchtowerCore/Services/CLIRunner.swift": Site(
            launch: .noModel, reason: "ProcessCLIRunner itself: the guarded runner (runModel carries the origin)"),
        "WatchtowerCore/Utilities/Constants.swift": Site(
            launch: .noModel, reason: "defines findCLIPath; its Process is the login-shell PATH probe"),
        "WatchtowerCore/Services/DaemonManager.swift": Site(
            launch: .noModel, reason: "sync control (sync --daemon/--now/stop, chat shutdown); no model"),
        "WatchtowerCore/Services/PeopleRosterLoad.swift": Site(
            launch: .noModel, reason: "sync --users-only: the roster fetch, no model"),
        "WatchtowerCore/Services/ProcessCompactionCLI.swift": Site(
            launch: .noModel, reason: "db compact --check/--if-due at launch"),
        "WatchtowerCore/Services/AIModelCatalog.swift": Site(
            launch: .noModel, reason: "ai models --json: the model list, no model call"),
        "WatchtowerCore/Services/JiraBoardSyncManager.swift": Site(
            launch: .noModel, reason: "jira sync --board: the owner's board sync, no model"),
        "WatchtowerCore/Services/SlackAuthService.swift": Site(
            launch: .noModel, reason: "auth login/logout"),
        "WatchtowerCore/Services/WatchtowerAIService.swift": Site(
            launch: .owner,
            reason: "ai query: the owner's chat turns; ai test: the owner's connection test (Settings, onboarding)"),
        "Database/DatabaseManager.swift": Site(launch: .noModel, reason: "db migrate"),
        "ViewModels/CatchUpViewModel.swift": Site(
            launch: .owner, reason: "CLIRun: catchup run/feedback after the owner's Run, Regenerate or rating"),
        "ViewModels/LinearAccountsViewModel.swift": Site(launch: .noModel, reason: "linear account flows"),
        "ViewModels/EmailAccountsViewModel.swift": Site(launch: .noModel, reason: "imap/outlook account flows"),
        "ViewModels/SlackAccountsViewModel.swift": Site(launch: .noModel, reason: "slack account flows"),
        "ViewModels/GoogleAccountsViewModel.swift": Site(launch: .noModel, reason: "google account flows"),
        "ViewModels/ExternalConnectionsViewModel.swift": Site(launch: .noModel, reason: "connections add/oauth/remove"),
        "ViewModels/JiraAccountsViewModel.swift": Site(launch: .noModel, reason: "jira account flows"),
        "ViewModels/CalendarAccountsViewModel.swift": Site(launch: .noModel, reason: "caldav account flows"),
        "Views/Settings/JiraFeaturesSettingsView.swift": Site(launch: .noModel, reason: "jira features toggles"),
        "Views/Settings/SlackConnectionDetail.swift": Site(launch: .noModel, reason: "auth login and account calls"),
        "Views/Settings/JiraBoardsSettingsView.swift": Site(launch: .noModel, reason: "jira boards select/deselect"),
        "Views/Settings/JiraUserMappingSettingsView.swift": Site(launch: .noModel, reason: "jira users map/resolve"),
        "Services/GoogleAuthService.swift": Site(launch: .noModel, reason: "google/calendar login"),
        "Services/GoogleConnectFlow.swift": Site(launch: .noModel, reason: "google login"),
        "Services/CodeSearchRun.swift": Site(launch: .noModel, reason: "code search over the code index (CodeCLIProcess)"),
        "Services/CodeIndexCenter.swift": Site(launch: .noModel, reason: "code index builds (CodeCLIProcess)")
    ]

    /// Scopes (`<path>#<func or var name>`) holding a model-path literal with
    /// no origin in the same body, each with why that is safe
    /// (`testLiteralModelArgsUseRunModel`). A path alone exempts the whole file.
    static let literalExemptions: [String: String] = [
        "WatchtowerCore/Services/ModelCommands.swift": "the model-command list itself",
        "Views/Workbench/Asks/SpecReview/SpecReviewView.swift#refLabel":
            "[\"ask\", \"target\", \"comment\"]: anchor kinds, not an argv",
        "WatchtowerCore/Services/Automations/AutomationsCLI.swift#args":
            "the argv builder of every op; dryRun and preview launch it through runModel",
        "Services/WorkbenchCLI.swift#review":
            "the generic review prefix: its runner refuses a model subcommand; overview and lessons propose use "
            + "reviewModel (WorkbenchCLIReviewTests.testEveryModelArgvOfTheReviewFamilyGoesThroughRunModel)",
        "Services/WorkbenchCLI.swift#args": "SessionStartRequest.args: sessionStart launches it through runModel"
    ]
}
