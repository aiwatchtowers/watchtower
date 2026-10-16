import XCTest
import GRDB
@testable import WatchtowerCore
import WatchtowerTestSupport

/// The workbench half of `AutomationQueries` (automations P5): session
/// requests, header buttons and ask labels.
final class AutomationWorkbenchQueriesTests: XCTestCase {
    private func args(prompt: String = "Review PR 7", agent: String = "claude", title: String = "⚙ Review · run #1")
        -> String {
        let data = try? JSONSerialization.data(withJSONObject: ["prompt": prompt, "agent": agent, "title": title],
                                               options: [.sortedKeys])
        return data.flatMap { String(bytes: $0, encoding: .utf8) } ?? ""
    }

    private func session(_ db: Database, projectID: Int64, runID: Int64?) throws -> TerminalSession {
        try TerminalSessionQueries.create(db, .init(
            projectID: projectID, kind: .claude, title: "s", folderPath: "/tmp/acme",
            claudeSessionID: UUID().uuidString.lowercased(), automationRunID: runID
        ))
    }

    func testPendingRequestsOnlyWaitingAppWorkbenchSteps() throws {
        let queue = try TestDatabase.create()
        let (wanted, workbench, automation, run) = try queue.write { db -> (Int64, Int64, Int64, Int64) in
            let p = try TestDatabase.insertWorkbench(db)
            let a = try TestDatabase.insertAutomation(db, slug: "review", name: "Review", workbenchID: p)
            let run = try TestDatabase.insertAutomationRun(db, automationID: a, status: "waiting", waitingReason: "app")
            let wanted = try TestDatabase.insertAutomationStep(
                db, runID: run, seq: 1, kind: "session",
                argsJSON: args(prompt: "-Review PR 7", agent: "codex", title: "⚙ Nightly · run #\(run)"), status: "waiting"
            )
            // Attached already.
            let other = try TestDatabase.insertAutomationRun(db, automationID: a, status: "waiting", waitingReason: "app")
            let attached = try session(db, projectID: p, runID: other)
            try TestDatabase.insertAutomationStep(db, runID: other, seq: 1, kind: "session", argsJSON: args(),
                                                  status: "waiting", sessionID: attached.id)
            // Step no longer waiting.
            let done = try TestDatabase.insertAutomationRun(db, automationID: a, status: "waiting", waitingReason: "app")
            try TestDatabase.insertAutomationStep(db, runID: done, seq: 1, kind: "session", argsJSON: args(), status: "ok")
            // Run waits on the session, not the app.
            let onSession = try TestDatabase.insertAutomationRun(db, automationID: a, status: "waiting",
                                                                 waitingReason: "session")
            try TestDatabase.insertAutomationStep(db, runID: onSession, seq: 1, kind: "session", argsJSON: args(),
                                                  status: "waiting")
            // A personal recipe's run.
            let personal = try TestDatabase.insertAutomation(db, slug: "mine", name: "Mine")
            let pRun = try TestDatabase.insertAutomationRun(db, automationID: personal, status: "waiting",
                                                            waitingReason: "app")
            try TestDatabase.insertAutomationStep(db, runID: pRun, seq: 1, kind: "session", argsJSON: args(),
                                                  status: "waiting")
            // Another kind of waiting step.
            try TestDatabase.insertAutomationStep(db, runID: run, seq: 2, kind: "ask", status: "waiting")
            return (wanted, p, a, run)
        }
        let (requests, unreadable) = try queue.read { try AutomationQueries.fetchPendingSessionRequests($0) }
        XCTAssertEqual(unreadable, [])
        XCTAssertEqual(requests, [PendingSessionRequest(
            stepID: wanted, runID: run, automationID: automation, projectID: workbench, automationName: "Review",
            prompt: "-Review PR 7", title: "⚙ Nightly · run #\(run)", agent: .codex
        )])
    }

    /// A step whose title is empty falls back to the run label; one whose
    /// args cannot be read is left out (Go wrote and validated them).
    func testPendingRequestTitleFallbackAndBrokenArgs() throws {
        let queue = try TestDatabase.create()
        let (run, broken) = try queue.write { db -> (Int64, [Int64]) in
            let p = try TestDatabase.insertWorkbench(db)
            let a = try TestDatabase.insertAutomation(db, slug: "review", name: "", workbenchID: p)
            let run = try TestDatabase.insertAutomationRun(db, automationID: a, status: "waiting", waitingReason: "app")
            try TestDatabase.insertAutomationStep(db, runID: run, seq: 1, kind: "session", argsJSON: args(title: ""),
                                                  status: "waiting")
            let notJSON = try TestDatabase.insertAutomationStep(db, runID: run, seq: 2, kind: "session",
                                                                argsJSON: "not json", status: "waiting")
            let badAgent = try TestDatabase.insertAutomationStep(db, runID: run, seq: 3, kind: "session",
                                                                 argsJSON: args(agent: "vim"), status: "waiting")
            return (run, [notJSON, badAgent])
        }
        let (requests, unreadable) = try queue.read { try AutomationQueries.fetchPendingSessionRequests($0) }
        XCTAssertEqual(unreadable, broken)
        XCTAssertEqual(requests.map(\.title), ["⚙ review · run #\(run)"])
        XCTAssertEqual(requests.map(\.automationName), ["review"])
    }

    func testUnattachedSessionForRun() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let p = try TestDatabase.insertWorkbench(db)
            let a = try TestDatabase.insertAutomation(db, workbenchID: p)
            let run = try TestDatabase.insertAutomationRun(db, automationID: a, status: "waiting", waitingReason: "app")
            XCTAssertNil(try AutomationQueries.unattachedSession(db, runID: run))
            let attached = try session(db, projectID: p, runID: run)
            try TestDatabase.insertAutomationStep(db, runID: run, seq: 1, kind: "session", argsJSON: args(),
                                                  status: "ok", sessionID: attached.id)
            XCTAssertNil(try AutomationQueries.unattachedSession(db, runID: run), "a step names it")
            _ = try session(db, projectID: p, runID: nil)
            let orphan = try session(db, projectID: p, runID: run)
            XCTAssertEqual(try AutomationQueries.unattachedSession(db, runID: run)?.id, orphan.id)
            XCTAssertEqual(try AutomationQueries.unattachedSession(db, runID: run)?.automationRunID, run)
        }
    }

    /// A refused launch's row loses the run marker; an attached session and
    /// another run's keep theirs.
    func testDisownUnattachedSessions() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            let p = try TestDatabase.insertWorkbench(db)
            let a = try TestDatabase.insertAutomation(db, workbenchID: p)
            let run = try TestDatabase.insertAutomationRun(db, automationID: a, status: "waiting", waitingReason: "app")
            let other = try TestDatabase.insertAutomationRun(db, automationID: a, status: "waiting", waitingReason: "app")
            let attached = try session(db, projectID: p, runID: run)
            try TestDatabase.insertAutomationStep(db, runID: run, seq: 1, kind: "session", argsJSON: args(),
                                                  status: "ok", sessionID: attached.id)
            let refused = try session(db, projectID: p, runID: run)
            let others = try session(db, projectID: p, runID: other)

            XCTAssertEqual(try AutomationQueries.disownUnattachedSessions(db, runID: run), [refused.id])

            let marker = { (id: Int64) in
                try Row.fetchOne(db, sql: "SELECT automation_run_id FROM terminal_sessions WHERE id = ?",
                                 arguments: [id])?["automation_run_id"] as Int64?
            }
            XCTAssertNil(try marker(refused.id))
            XCTAssertEqual(try marker(attached.id), run)
            XCTAssertEqual(try marker(others.id), other)
            XCTAssertNil(try AutomationQueries.unattachedSession(db, runID: run))
        }
    }

    func testWaitingSessionSteps() throws {
        let queue = try TestDatabase.create()
        let (step, sessionID) = try queue.write { db -> (Int64, Int64) in
            let p = try TestDatabase.insertWorkbench(db)
            let a = try TestDatabase.insertAutomation(db, workbenchID: p)
            let run = try TestDatabase.insertAutomationRun(db, automationID: a, status: "waiting",
                                                           waitingReason: "session")
            let s = try session(db, projectID: p, runID: run)
            let step = try TestDatabase.insertAutomationStep(db, runID: run, seq: 1, kind: "session", argsJSON: args(),
                                                             status: "waiting", sessionID: s.id)
            // Not attached yet, ended, and a run no longer waiting.
            try TestDatabase.insertAutomationStep(db, runID: run, seq: 2, kind: "session", argsJSON: args(),
                                                  status: "waiting")
            try TestDatabase.insertAutomationStep(db, runID: run, seq: 3, kind: "session", argsJSON: args(),
                                                  status: "ok", sessionID: s.id)
            let gone = try TestDatabase.insertAutomationRun(db, automationID: a, status: "cancelled")
            try TestDatabase.insertAutomationStep(db, runID: gone, seq: 1, kind: "session", argsJSON: args(),
                                                  status: "waiting", sessionID: s.id)
            // Sessions that finished or failed: the run's wait reads those.
            for (seq, column) in [(4, "finished_at"), (5, "agent_failed_at")] {
                let ended = try session(db, projectID: p, runID: run)
                try db.execute(sql: "UPDATE terminal_sessions SET \(column) = '2026-10-01T10:00:00Z' WHERE id = ?",
                               arguments: [ended.id])
                try TestDatabase.insertAutomationStep(db, runID: run, seq: seq, kind: "session", argsJSON: args(),
                                                      status: "waiting", sessionID: ended.id)
            }
            return (step, s.id)
        }
        let steps = try queue.read { try AutomationQueries.waitingSessionSteps($0) }
        XCTAssertEqual(steps.map(\.stepID), [step])
        XCTAssertEqual(steps.map(\.sessionID), [sessionID])
    }

    func testHeaderButtonsStatesAndSlugOrder() throws {
        let queue = try TestDatabase.create()
        let button = { (label: String, confirm: Bool) in
            #"{"button":{"label":"\#(label)","confirm":\#(confirm)}}"#
        }
        let (p, ids, active) = try queue.write { db -> (Int64, [String: Int64], Int64) in
            let p = try TestDatabase.insertWorkbench(db)
            let other = try TestDatabase.insertWorkbench(db, name: "other", folder: "/tmp/other")
            var ids: [String: Int64] = [:]
            ids["release"] = try TestDatabase.insertAutomation(
                db, slug: "release", name: "Release", triggerKind: "button", triggerSpec: button("Release", true),
                workbenchID: p)
            ids["deploy"] = try TestDatabase.insertAutomation(
                db, slug: "deploy", name: "Deploy", triggerKind: "button", triggerSpec: button("Deploy to test", false),
                approvalHash: "h2", confirmedHash: "h1", workbenchID: p)
            ids["lint"] = try TestDatabase.insertAutomation(
                db, slug: "lint", name: "Lint", triggerKind: "button", triggerSpec: button("Lint", false),
                enabled: false, workbenchID: p)
            ids["broken"] = try TestDatabase.insertAutomation(
                db, slug: "broken", name: "Broken", triggerKind: "button", triggerSpec: button("Broken", false),
                parseError: "line 3: bad", workbenchID: p)
            ids["nolabel"] = try TestDatabase.insertAutomation(
                db, slug: "nolabel", name: "No label", triggerKind: "button", triggerSpec: "{}", workbenchID: p)
            try TestDatabase.insertAutomation(
                db, slug: "gone", triggerKind: "button", triggerSpec: button("Gone", false),
                removedAt: "2026-10-10T00:00:00Z", workbenchID: p)
            try TestDatabase.insertAutomation(db, slug: "manual", workbenchID: p)
            try TestDatabase.insertAutomation(
                db, slug: "elsewhere", triggerKind: "button", triggerSpec: button("Elsewhere", false), workbenchID: other)
            try TestDatabase.insertAutomation(db, slug: "personal", triggerKind: "button",
                                              triggerSpec: button("Mine", false))
            let release = try XCTUnwrap(ids["release"])
            try TestDatabase.insertAutomationRun(db, automationID: release, status: "succeeded")
            let active = try TestDatabase.insertAutomationRun(db, automationID: release, status: "running")
            return (p, ids, active)
        }
        let buttons = try queue.read { try AutomationQueries.headerButtons($0, projectID: p) }
        let id = { (slug: String) throws -> Int64 in try XCTUnwrap(ids[slug]) }
        XCTAssertEqual(buttons, try [
            AutomationHeaderButton(automationID: id("broken"), slug: "broken", label: "Broken", confirm: false,
                                   state: .parseError, activeRunID: nil),
            AutomationHeaderButton(automationID: id("deploy"), slug: "deploy", label: "Deploy to test", confirm: false,
                                   state: .needsConfirmation, activeRunID: nil),
            AutomationHeaderButton(automationID: id("lint"), slug: "lint", label: "Lint", confirm: false,
                                   state: .disabled, activeRunID: nil),
            AutomationHeaderButton(automationID: id("nolabel"), slug: "nolabel", label: "No label", confirm: false,
                                   state: .runnable, activeRunID: nil),
            AutomationHeaderButton(automationID: id("release"), slug: "release", label: "Release", confirm: true,
                                   state: .runnable, activeRunID: active)
        ])
    }

    func testAskLabels() throws {
        let queue = try TestDatabase.create()
        let (asks, run) = try queue.write { db -> ([Int64], Int64) in
            let p = try TestDatabase.insertWorkbench(db)
            let a = try TestDatabase.insertAutomation(db, slug: "review", name: "Nightly review", workbenchID: p)
            let run = try TestDatabase.insertAutomationRun(db, automationID: a, status: "waiting", waitingReason: "ask")
            let fromRun = try TestDatabase.insertOwnerAsk(db, projectID: p, automationRunID: run)
            let fromAgent = try TestDatabase.insertOwnerAsk(db, projectID: p)
            return ([fromRun, fromAgent, 999], run)
        }
        XCTAssertEqual(try queue.read { try AutomationQueries.askLabels($0, askIDs: asks) },
                       [asks[0]: "⚙ Nightly review · run #\(run)"])
        XCTAssertEqual(try queue.read { try AutomationQueries.askLabels($0, askIDs: []) }, [:])
    }
}
