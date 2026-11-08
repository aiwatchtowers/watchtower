import GRDB
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Needs approval drawn from the wired views (B Task 12): each state seeded
/// into a test database — the `needs-approval` built-in and its last run,
/// open actions and due reminders, the recipe's living cards, a built-in
/// notice — and read by `ActionStripActionsView` with Needs approval
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
            DesignShot(name: name, size: NSSize(width: 1180, height: height)) { view(state) }
        }
    }

    /// The Inbox with Needs approval selected over `state`'s database.
    static func view(_ state: State) -> AnyView {
        do {
            let (pool, path) = try TestDatabase.createPool()
            paths.append(path)
            let folder = try pool.write { db in try seed(db, state) }
            let defaults = UserDefaults(suiteName: defaultsSuite) ?? .standard
            defaults.removePersistentDomain(forName: defaultsSuite)
            let clock = now
            // Labeled: a trailing closure would bind to `automationsWake`.
            // swiftlint:disable:next trailing_closure
            let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner(), defaults: defaults, clock: { clock })
            vm.disabledFeatures = state.featureOn ? [] : [ActionStripViewModel.approvalsFeatureID]
            let expected = state.approvals.count + (state.notice ? 1 : 0)
            InboxFolderMenuShotFixtures.spin(until: "the Needs approval read",
                                             vm.folderMenu.selectedFolderID == folder
                                                 && vm.folderEntries.count == expected) {
                await vm.refresh()
                vm.selectFolder(folder)
            }
            if let failure = state.turnOnFailure {
                InboxFolderMenuShotFixtures.spin(until: "the Turn On failure",
                                                 vm.approvalsNoteContent?.failure == failure) {
                    await vm.pressApprovalsNote(turnOn: { failure }, runHistory: { _, _ in })
                }
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

    private static func at(minutesAgo: Int) -> String {
        AutomationDates.format(now.addingTimeInterval(TimeInterval(-60 * minutesAgo)))
    }

    /// The tree with Needs approval, the built-in with its last run, the
    /// approvals and their cards. Returns Needs approval's folder id.
    private static func seed(_ db: Database, _ state: State) throws -> Int64 {
        // The migration's seed rows (the test schema is DDL only); the
        // Desktop itself never writes these tables.
        let root = try folder(db, kind: "root", parent: nil, slug: "inbox", title: "Inbox")
        let approvals = try folder(db, kind: "approvals", parent: root, slug: "needs-approval", title: "Needs approval")
        try db.execute(sql: "INSERT INTO inbox_folder_state (id, revision) VALUES (1, 1)")
        try folder(db, kind: "owner", parent: root, slug: "release", title: "Release acme 2.0", icon: "flag")
        _ = try TestDatabase.insertSlackAccount(db, currentUserID: "1:U001")

        let builtin = try TestDatabase.insertAutomation(db, slug: "needs-approval", name: "Needs approval")
        try db.execute(sql: """
            UPDATE automations SET origin = 'builtin', builtin_id = 'needs-approval', path = 'builtin:needs-approval',
                disabled_reason = ? WHERE id = ?
            """, arguments: [state.stopped ? "the run would not end" : "", builtin])
        let run = try TestDatabase.insertAutomationRun(
            db, automationID: builtin, status: state.runFailed ? "failed" : "succeeded")
        let notes = try TestDatabase.insertAutomation(db, slug: "release-notes", name: "Release notes")
        let notesRun = try TestDatabase.insertAutomationRun(db, automationID: notes)

        for approval in state.approvals {
            let seeded = try insert(db, approval, proposedBy: notesRun)
            if state.recipe.contains(approval) {
                try TestDatabase.insertAutomationOutput(
                    db, automationID: builtin, runID: run, title: seeded.title, body: "",
                    createdAt: at(minutesAgo: 5), blocksJSON: seeded.blocks, outputKey: seeded.key,
                    contentHash: "h-\(seeded.key)", writtenAt: at(minutesAgo: 5), changedAt: at(minutesAgo: 5))
            }
        }
        if state.notice {
            try db.execute(sql: """
                INSERT INTO builtin_migrations (builtin_id, status, error, attempts, updated_at)
                VALUES ('morning-brief', 'failed', ?, 1, ?)
                """, arguments: ["your customised prompt was kept; the move stopped at the confirm step",
                                 at(minutesAgo: 40)])
        }
        return approvals
    }

    /// One approval's row, and the card the recipe draws for it (`needs-approval.md`).
    private static func insert(
        _ db: Database, _ approval: Approval, proposedBy run: Int64
    ) throws -> (key: String, title: String, blocks: String) {
        switch approval {
        case .slackSend:
            let id = try TestDatabase.insertAgentAction(
                db, tool: "send_slack_message", external: true,
                argsJSON: ##"{"text":"Release 2.0 is tagged; checklist in the thread.","target":{"account_id":1,"##
                    + ##""workspace":"acme","channel_id":"C1","label":"#acme-release"}}"##,
                reason: "Release notes run: tell the channel the tag is out", surface: "automation",
                contextType: "automation_run", contextID: "\(run)", turnID: "turn-slack", createdAt: at(minutesAgo: 30))
            return ("action:\(id)", "Send a Slack message",
                    card("Send a Slack message", line: "to #acme-release", kind: "action", id: id))
        case .jiraIssue:
            let id = try TestDatabase.insertAgentAction(
                db, tool: "create_jira_issue", external: true,
                argsJSON: #"{"project_key":"ACME","issue_type":"Bug","summary":"Checklist link broken on the release page"}"#,
                reason: "From your :ticket: reaction", turnID: "turn-jira", createdAt: at(minutesAgo: 30))
            return ("action:\(id)", "Create a Jira issue",
                    card("Create a Jira issue", line: "ACME · “Checklist link broken on the release page”",
                         detail: "from your :ticket: reaction", kind: "action", id: id))
        case .linearFailed:
            let id = try TestDatabase.insertAgentAction(
                db, tool: "create_linear_issue", external: true, argsJSON: #"{"team":"ACME","title":"Rollback plan for 2.0"}"#,
                reason: "From your :ticket: reaction", turnID: "turn-linear", status: "failed",
                error: "the team was archived", createdAt: at(minutesAgo: 50), decidedAt: at(minutesAgo: 45),
                appliedAt: at(minutesAgo: 45))
            return ("action:\(id)", "Create a Linear issue",
                    card("Create a Linear issue", line: "failed: the team was archived", kind: "action", id: id))
        case .reminder:
            try db.execute(sql: """
                INSERT INTO reminders (account_id, message_ref, note, remind_at, status, created_at)
                VALUES (1, '', 'Answer colleague A about the budget', ?, 'pending', ?)
                """, arguments: [at(minutesAgo: 10), at(minutesAgo: 120)])
            let id = db.lastInsertedRowID
            return ("reminder:\(id)", "Reminder",
                    card("Reminder", line: "“Answer colleague A about the budget”", kind: "reminder", id: id))
        }
    }

    /// The recipe's blocks for one approval: a heading and its one ref row.
    private static func card(_ title: String, line: String, detail: String? = nil, kind: String, id: Int64) -> String {
        let subtitle = detail.map { #","subtitle":"\#($0)""# } ?? ""
        return #"{"v":1,"blocks":[{"type":"heading","text":"\#(title)"},"#
            + #"{"type":"list","rows":[{"title":"\#(line)"\#(subtitle),"ref":{"kind":"\#(kind)","id":\#(id)}}]}]}"#
    }

    @discardableResult
    private static func folder(
        _ db: Database, kind: String, parent: Int64?, slug: String, title: String, icon: String = ""
    ) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO inbox_folders (kind, parent_id, slug, title, icon, position) VALUES (?, ?, ?, ?, ?, 0)
            """, arguments: [kind, parent, slug, title, icon])
        return db.lastInsertedRowID
    }
}
