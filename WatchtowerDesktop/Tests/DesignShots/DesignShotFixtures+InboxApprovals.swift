import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Needs approval drawn from the wired views (B Task 12): each state's
/// database is a Go desktop case (`desktop_shot_approvals_*`) — the
/// `needs-approval` built-in and its last run, open actions and due
/// reminders, the recipe's living cards, a built-in notice — listed from
/// its Go feed and read by `ActionStripActionsView` with Needs approval
/// selected, so every card goes through the live stack (`approvalCard`,
/// `filled`). b-02's panels. Sample data only, at one fixed moment.
@MainActor
enum InboxApprovalsShotFixtures {
    private static var paths: [String] = []
    private static let defaultsSuite = "InboxApprovalsShotFixtures"
    nonisolated static let now = AutomationDates.parse("2026-11-06T12:00:00Z") ?? Date()

    static func cleanUp() {
        paths.forEach(TestDatabase.cleanup(path:))
        paths = []
        UserDefaults().removePersistentDomain(forName: defaultsSuite)
    }

    /// One open approval of a state.
    enum Approval: Hashable {
        case slackSend, jiraIssue, linearFailed, reminder
    }

    /// What one shot seeds and presses.
    struct State {
        var approvals: [Approval] = [.slackSend, .jiraIssue]
        /// The approvals with a current recipe card (written after their last change).
        var recipe: Set<Approval> = []
        var featureOn = true
        var stopped = false
        var runFailed = false
        var notice = false
        /// The reason the note's Turn On returned.
        var turnOnFailure: String?
        /// The app-wide daemon banner above the Inbox.
        var banner: String?
    }

    static let restartFailure = "The background sync did not restart: the daemon did not stop in time"

    static var shots: [DesignShot] {
        let states: [(String, CGFloat, State)] = [
            ("inbox-b-approvals-native", 640, State()),
            ("inbox-b-approvals-recipe", 640, State(approvals: [.jiraIssue, .reminder], recipe: [.jiraIssue, .reminder])),
            ("inbox-b-approvals-mixed", 860, State(approvals: [.slackSend, .jiraIssue, .linearFailed, .reminder],
                                                   recipe: [.jiraIssue])),
            ("inbox-b-approvals-notice", 760, State(approvals: [.jiraIssue, .reminder], recipe: [.jiraIssue, .reminder],
                                                    notice: true)),
            ("inbox-b-approvals-off", 640, State(featureOn: false)),
            ("inbox-b-approvals-stopped", 640, State(stopped: true)),
            ("inbox-b-approvals-run-failed", 640, State(runFailed: true)),
            ("inbox-b-approvals-off-turn-on-failed", 640, State(
                featureOn: false, turnOnFailure: "Feature changes are being applied in Settings — try again")),
            ("inbox-b-approvals-stopped-turn-on-failed", 640, State(
                stopped: true, turnOnFailure: "watchtower exited with error: database is locked")),
            ("inbox-b-approvals-restart-failed", 680, State(banner: restartFailure)),
            ("inbox-b-approvals-failed-action", 480, State(approvals: [.linearFailed])),
            ("inbox-b-approvals-reminder", 480, State(approvals: [.reminder])),
            ("inbox-b-approvals-empty", 480, State(approvals: []))
        ]
        return states.map { name, height, state in
            DesignShot(name: name, prepare: { await view(state) }, size: NSSize(width: 1180, height: height))
        }
    }

    /// The Inbox with Needs approval selected over `state`'s database.
    static func view(_ state: State) async -> AnyView {
        do {
            let (pool, path) = try TestDatabase.createPool()
            paths.append(path)
            let tower = try InboxShotFeed.seeded(caseName(state), pool)
            let defaults = UserDefaults(suiteName: defaultsSuite) ?? .standard
            defaults.removePersistentDomain(forName: defaultsSuite)
            let clock = now
            // Labeled: a trailing closure would bind to `automationsWake`.
            // swiftlint:disable:next trailing_closure
            let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner(), defaults: defaults, clock: { clock })
            vm.disabledFeatures = state.featureOn ? [] : [ActionStripViewModel.approvalsFeatureID]
            await InboxShotFeed.listed(vm, tower) { vm.selectFolder(needsApproval) }
            if let failure = state.turnOnFailure {
                await vm.pressApprovalsNote(turnOn: { failure }, runHistory: { _, _ in })
                XCTAssertEqual(vm.approvalsNoteContent?.failure, failure, "the Turn On failure")
            }
            let inbox = ActionStripActionsView(
                vm: vm, cheatSheetRows: [], feature: .on(lastCheck: nil), isEnabling: false, featureError: nil,
                onEnable: {}, onOpenSettings: {}, onOpen: { _ in }, onRetryBuiltin: { _ in }, now: now
            )
            return AnyView(VStack(spacing: 0) {
                if let banner = state.banner {
                    DaemonBannerView(banner: .failed(banner), onStart: {}, onOpenLogs: {}, onDismiss: {})
                }
                inbox
            }
            .environment(AppState())
            .detailBackground())
        } catch {
            return DesignShotFixtures.failure(error)
        }
    }

    /// Needs approval's folder (Go's migration makes it, id 2).
    private static let needsApproval: Int64 = 2

    /// The Go desktop case holding `state`'s database: the tree with Needs
    /// approval and the owner folder `release`, the `needs-approval`
    /// built-in and its last run, the approvals and their recipe cards.
    private static func caseName(_ state: State) -> String {
        "desktop_shot_approvals_" + {
            if !state.featureOn { return "off" }
            if state.stopped { return "stopped" }
            if state.runFailed { return "run_failed" }
            if state.notice { return "notice" }
            if state.approvals.isEmpty { return "empty" }
            if state.approvals == [.linearFailed] { return "failed_action" }
            if state.approvals == [.reminder] { return "reminder" }
            if state.approvals.count == 4 { return "mixed" }
            if !state.recipe.isEmpty { return "recipe" }
            return "native"
        }()
    }
}
