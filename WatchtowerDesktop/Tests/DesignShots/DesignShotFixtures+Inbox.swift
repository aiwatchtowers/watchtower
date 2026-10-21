import GRDB
import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Inbox read like mail (spec B1): a list with all three sections — a
/// proposal, today's cards and an earlier card and reminder — and a selected
/// card with three buttons of its own, a link and a markdown body. Today is
/// fixed (2026-10-21 12:00 UTC), so the sections never move.
@MainActor
enum InboxShotFixtures {
    private static var poolPath: String?

    static func cleanUp() {
        if let poolPath { TestDatabase.cleanup(path: poolPath) }
        poolPath = nil
    }

    private static let now = AutomationDates.parse("2026-10-21T12:00:00Z") ?? Date()

    private static let body = """
        **Verdict:** bug, high priority.

        **Scenario**

        - Import a CSV larger than 10 MB
        - The import fails at step two with "unexpected EOF"

        Similar: ACME-301 (closed in August).
        """

    private static let actions = #"[{"label":"Move to Backlog","kind":"reply","reply":"backlog","primary":true},"#
        + #"{"label":"Not a Bug — Close","kind":"reply","reply":"close"},"#
        + #"{"label":"Ask for Details","kind":"chat","chat":"Draft a comment asking for the file"}]"#

    static func readingPane() -> AnyView {
        do {
            let (pool, path) = try TestDatabase.createPool()
            cleanUp()
            poolPath = path
            let selected = try pool.write { db -> Int64 in
                let triage = try TestDatabase.insertAutomation(db, slug: "issue-triage", name: "Issue triage",
                                                               outputsJSON: #"["inbox"]"#)
                let mail = try TestDatabase.insertAutomation(db, slug: "mail-triage", name: "Morning mail triage",
                                                             outputsJSON: #"["inbox"]"#)
                let run = try TestDatabase.insertAutomationRun(db, automationID: triage)
                let mailRun = try TestDatabase.insertAutomationRun(db, automationID: mail)
                _ = try TestDatabase.insertAgentAction(
                    db, tool: "create_target", argsJSON: #"{"text":"Send the weekly report to acme leads"}"#,
                    reason: "You asked for it every Friday.", createdAt: "2026-10-21T10:12:00Z")
                _ = try TestDatabase.insertAutomationOutput(
                    db, automationID: triage, runID: run, title: "ACME-479: typo in onboarding",
                    body: "Cosmetic · low", priority: "low", createdAt: "2026-10-21T09:00:00Z",
                    readAt: "2026-10-21T09:05:00Z")
                _ = try TestDatabase.insertAutomationOutput(
                    db, automationID: mail, runID: mailRun, title: "3 emails waiting for a reply",
                    body: "From colleague A, colleague B and billing@example.com", createdAt: "2026-10-21T08:30:00Z")
                _ = try TestDatabase.insertAutomationOutput(
                    db, automationID: mail, runID: mailRun, title: "Invoice from acme.example.com",
                    body: "Due on Friday.", createdAt: "2026-10-18T08:30:00Z", readAt: "2026-10-18T09:00:00Z")
                try db.execute(sql: """
                    INSERT INTO reminders (message_ref, note, remind_at, status)
                    VALUES ('', 'Reply to colleague A about the launch', '2026-10-20T14:00:00Z', 'pending')
                    """)
                return try TestDatabase.insertAutomationOutput(
                    db, automationID: triage, runID: run, title: "ACME-482: crash when importing CSV", body: body,
                    priority: "high", createdAt: "2026-10-21T10:00:00Z", readAt: "2026-10-21T10:01:00Z",
                    link: "https://example.com/acme/issue/482", actionsJSON: actions)
            }
            let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())
            refreshed(vm)
            vm.selection = .output(selected)
            return AnyView(InboxSplitView(
                vm: vm, cheatSheetRows: [], onOpenSettings: {},
                proposalCard: { action in
                    AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {})
                },
                onCardAction: { _ in }, onOpenAutomationRun: { _ in }, now: now
            )
            .environment(\.markdownNavScreens, ["home"]))
        } catch {
            XCTFail("inbox shot fixture failed: \(error)")
            return AnyView(Text("fixture failed: \(String(describing: error))").foregroundStyle(.red))
        }
    }

    /// A pending `save_automation` proposal selected: its summary, Open Draft
    /// and Reject in the reading pane.
    static func proposalPane() -> AnyView {
        do {
            let (pool, path) = try TestDatabase.createPool()
            cleanUp()
            poolPath = path
            let args = #"{"path":"/acme/automations/mail-digest.md","name":"Morning mail digest","#
                + #""slug":"mail-digest","is_new":true,"trigger_kind":"schedule","#
                + #""trigger_spec":{"schedule":"0 9 * * 1-5"},"#
                + #""permissions":["gmail:read@work","llm:light","slack:read@acme","inbox:reply"],"#
                + #""outputs":["inbox"],"recipe_text":"---\nname: Morning mail digest\n---\n"}"#
            let selected = try pool.write { db -> Int64 in
                let mail = try TestDatabase.insertAutomation(db, slug: "mail-triage", name: "Morning mail triage",
                                                             outputsJSON: #"["inbox"]"#)
                let run = try TestDatabase.insertAutomationRun(db, automationID: mail)
                _ = try TestDatabase.insertAutomationOutput(
                    db, automationID: mail, runID: run, title: "3 emails waiting for a reply",
                    body: "From colleague A, colleague B and billing@example.com", createdAt: "2026-10-21T08:30:00Z")
                return try TestDatabase.insertAgentAction(
                    db, tool: "save_automation", argsJSON: args,
                    reason: "Every weekday morning, the mail that needs your reply, newsletters skipped.",
                    createdAt: "2026-10-21T10:12:00Z")
            }
            let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner())
            refreshed(vm)
            vm.selection = .proposal(selected)
            return AnyView(InboxSplitView(
                vm: vm, cheatSheetRows: [], onOpenSettings: {},
                proposalCard: { action in
                    AgentActionCardView(action: action, inFlight: false, onApprove: {}, onReject: {}, onRetry: {})
                },
                saveProposal: { action in
                    SaveAutomationProposalPane(action: action, workbenchName: { _ in nil },
                                               onOpenDraft: { _ in }, onReject: {})
                },
                onCardAction: { _ in }, onOpenAutomationRun: { _ in }, now: now
            ))
        } catch {
            XCTFail("inbox proposal shot fixture failed: \(error)")
            return AnyView(Text("fixture failed: \(String(describing: error))").foregroundStyle(.red))
        }
    }

    /// The pane at its narrowest (420 pt) with four 40-character labels:
    /// both button rows wrap, Done and Dismiss stay trailing.
    static func narrowPane() -> AnyView {
        let label = { (word: String) in word + String(repeating: " and then some more", count: 2).prefix(40 - word.count) }
        let actions = #"[{"label":"\#(label("Move"))","kind":"reply","reply":"backlog","primary":true},"#
            + #"{"label":"\#(label("Close"))","kind":"reply","reply":"close"},"#
            + #"{"label":"\#(label("Ask"))","kind":"chat","chat":"Draft a comment"},"#
            + #"{"label":"\#(label("Open"))","kind":"link","open":"https://example.com/acme/482"}]"#
        let card = AutomationOutputCard(
            id: 1, automationID: 1, automationName: "Issue triage", runID: 212,
            title: "ACME-482: crash when importing CSV", body: body, priority: "high", createdAt: now,
            link: "https://example.com/acme/issue/482", actionsJSON: actions, recipeState: .needsConfirmation)
        return AnyView(InboxReadingPane(item: .output(card), navScreens: ["home"], now: now) { _ in }
            .frame(width: 420)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .detailBackground())
    }

    /// The shot renders at once, so the strip's async read is waited for
    /// here by running the main run loop (the test-side `spin` precedent).
    private static func refreshed(_ vm: ActionStripViewModel) {
        final class Flag { var done = false }
        let flag = Flag()
        Task { @MainActor in
            await vm.refresh()
            flag.done = true
        }
        let deadline = Date().addingTimeInterval(5)
        while !flag.done, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }
}
