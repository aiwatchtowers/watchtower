/// Frozen fixtures for the workbench slice kinds (mobile POC spec §4.2–§4.9)
/// and the workbench action params (§5.2). The fixture files under
/// `WatchtowerKit/Tests/Fixtures/workbench/` are the wire the hub's encoder
/// must produce; the owner-ask answer is pinned against the Go fixtures in
/// `internal/asks/testdata/answers`.
///
/// Plain imports (no @testable): every symbol here is the public surface the
/// phone app builds against.
import WatchtowerKit
import WatchtowerSync
import XCTest

final class WorkbenchMirrorFixtureTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Fixture files

    private static let kitTests = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // WatchtowerKitTests
        .deletingLastPathComponent() // Tests

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Self.kitTests.appendingPathComponent("Fixtures/workbench/\(name).json"))
    }

    private func object(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try fixture(name)) as? [String: Any])
    }

    private func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    // MARK: - Kinds

    func testWorkbenchSliceKindsAreFrozen() {
        XCTAssertEqual(SliceKind.workbench.rawValue, "workbench")
        XCTAssertEqual(SliceKind.workbenchTarget.rawValue, "workbench_target")
        XCTAssertEqual(SliceKind.workbenchComment.rawValue, "workbench_comment")
        XCTAssertEqual(SliceKind.terminalSession.rawValue, "terminal_session")
        XCTAssertEqual(SliceKind.ownerAsk.rawValue, "owner_ask")
        XCTAssertEqual(SliceKind.sessionReport.rawValue, "session_report")
        XCTAssertEqual(SliceKind.sessionTimeline.rawValue, "session_timeline")

        XCTAssertEqual(Workbench.sliceKind, .workbench)
        XCTAssertEqual(WorkbenchTarget.sliceKind, .workbenchTarget)
        XCTAssertEqual(WorkbenchComment.sliceKind, .workbenchComment)
        XCTAssertEqual(TerminalSessionState.sliceKind, .terminalSession)
        XCTAssertEqual(OwnerAsk.sliceKind, .ownerAsk)
        XCTAssertEqual(SessionReport.sliceKind, .sessionReport)
        XCTAssertEqual(SessionTimeline.sliceKind, .sessionTimeline)
    }

    func testWorkbenchActionKindsAreFrozen() {
        XCTAssertEqual(
            ActionKind.allCases.suffix(12).map(\.rawValue),
            [
                "ask_answer", "board_target_status", "board_target_priority", "board_comment_add",
                "board_comment_reply", "board_target_create", "session_start", "session_input",
                "session_input_cancel", "session_finish_request", "session_stop", "session_report_request"
            ]
        )
    }

    func testOpenWireValuesAreFrozen() {
        XCTAssertEqual(
            WorkbenchTargetStatus.knownValues.map(\.rawValue),
            ["todo", "in_progress", "in_review", "blocked", "done", "dismissed", "snoozed"]
        )
        XCTAssertEqual(
            WorkbenchTargetStatus.editable.map(\.rawValue),
            ["todo", "in_progress", "in_review", "blocked", "done", "dismissed"]
        )
        XCTAssertEqual(WorkbenchTargetPriority.knownValues.map(\.rawValue), ["high", "medium", "low"])
        XCTAssertEqual(WorkbenchStatusActor.knownValues.map(\.rawValue), ["agent", "owner", "system"])
        XCTAssertEqual(WorkbenchComment.Author.knownValues.map(\.rawValue), ["owner", "agent"])
        XCTAssertEqual(WorkbenchComment.Status.knownValues.map(\.rawValue), ["open", "resolved", "outdated"])
        XCTAssertEqual(
            TerminalSessionState.Kind.knownValues.map(\.rawValue),
            ["working", "running", "waiting_on_ask", "needs_approval", "finished", "stopped", "failed", "not_started"]
        )
        XCTAssertEqual(
            TerminalSessionState.Tone.knownValues.map(\.rawValue),
            ["green", "orange", "blue", "red", "secondary"]
        )
        XCTAssertEqual(TerminalSessionState.Agent.knownValues.map(\.rawValue), ["claude_code"])
        XCTAssertEqual(OwnerAsk.Kind.knownValues.map(\.rawValue), ["review", "check", "question"])
        XCTAssertEqual(OwnerAsk.Status.knownValues.map(\.rawValue), ["open", "answered", "delivered", "withdrawn"])
        XCTAssertEqual(OwnerAsk.WithdrawnReason.knownValues.map(\.rawValue), ["agent", "superseded"])
        XCTAssertEqual(OwnerAskAnswer.Verdict.knownValues.map(\.rawValue), ["approved", "changes"])
        XCTAssertEqual(OwnerAskAnswer.CheckState.knownValues.map(\.rawValue), ["ok", "broken", "skipped"])
        XCTAssertEqual(
            SessionTimeline.Milestone.Kind.knownValues.map(\.rawValue),
            [
                "state", "ask_opened", "ask_answered", "ask_withdrawn", "target_linked",
                "target_status", "phase", "pr", "finished"
            ]
        )
        XCTAssertEqual(SessionStartParams.Mode.knownValues.map(\.rawValue), ["new", "open_existing"])
    }

    // MARK: - Each kind decodes its frozen fixture

    func testWorkbenchFixture() throws {
        let workbench = try Workbench.decode(payload: try fixture("workbench"))
        XCTAssertEqual(workbench.id, 7)
        XCTAssertEqual(workbench.name, "Acme")
        XCTAssertNil(workbench.nameClipped)
        XCTAssertEqual(workbench.descriptionClipped, true)
        XCTAssertEqual(workbench.folderDisplay, "~/Projects/acme")
        XCTAssertEqual(workbench.branch, "feature/acme-export")
        XCTAssertFalse(workbench.detached)
        XCTAssertEqual(workbench.changes, 3)
        XCTAssertEqual(workbench.openAsks, 2)
        XCTAssertEqual(workbench.openTargets, 9)
        XCTAssertEqual(workbench.inProgressTargets, 2)
        XCTAssertEqual(workbench.blockedTargets, 1)
        XCTAssertEqual(workbench.doneTargets, 5)
        XCTAssertEqual(
            workbench.sessionCounts,
            Workbench.SessionCounts(
                working: 1, waiting: 1, needsApproval: 1, finished: 1, failed: 0, stopped: 2, notRunning: 3
            )
        )
        XCTAssertEqual(workbench.lastSessionActivity, t0)
        XCTAssertEqual(workbench.archiveAfterDays, 14)
        XCTAssertEqual(workbench.targetsMore, 1)
    }

    func testWorkbenchTargetFixture() throws {
        let target = try WorkbenchTarget.decode(payload: try fixture("workbench_target"))
        XCTAssertEqual(target.id, 415)
        XCTAssertEqual(target.workbenchID, 7)
        XCTAssertEqual(target.parentID, 400)
        XCTAssertEqual(target.text, "Archive Closed Targets Now")
        XCTAssertEqual(target.status, .inProgress)
        XCTAssertEqual(target.priority, .high)
        XCTAssertEqual(target.progress, 0.5)
        XCTAssertEqual(target.branch, "feature/acme-export")
        XCTAssertEqual(target.pr, "175")
        XCTAssertFalse(target.archived)
        XCTAssertEqual(target.childrenCount, 0)
        XCTAssertEqual(target.openComments, 2)
        XCTAssertEqual(target.unreadForOwner, 1)
        XCTAssertEqual(target.openAsks, 1)
        XCTAssertEqual(target.sessionIDs, [31, 32])
        XCTAssertNil(target.sessionIDsMore)
        XCTAssertEqual(target.lastStatusAt, t0.addingTimeInterval(-1000))
        XCTAssertEqual(target.lastStatusActor, .agent)
        XCTAssertEqual(target.workOnPrompt, "Work on target #415: Archive Closed Targets Now.")
        XCTAssertEqual(target.createdAt, t0.addingTimeInterval(-10000))
        XCTAssertEqual(target.updatedAt, t0)
        XCTAssertNil(target.textClipped)
    }

    func testWorkbenchCommentFixture() throws {
        let comment = try WorkbenchComment.decode(payload: try fixture("workbench_comment"))
        XCTAssertEqual(comment.id, 88)
        XCTAssertEqual(comment.workbenchID, 7)
        XCTAssertEqual(comment.targetID, 415)
        XCTAssertEqual(comment.parentID, 80)
        XCTAssertEqual(comment.author, .agent)
        XCTAssertEqual(comment.agentLabel, "claude")
        XCTAssertEqual(comment.body, "The plan is on the board. One question on the menu wording.")
        XCTAssertEqual(comment.status, .open)
        XCTAssertEqual(comment.createdAt, t0)
        XCTAssertFalse(comment.read)
    }

    func testTerminalSessionFixture() throws {
        let session = try TerminalSessionState.decode(payload: try fixture("terminal_session"))
        XCTAssertEqual(session.id, 31)
        XCTAssertEqual(session.workbenchID, 7)
        XCTAssertEqual(session.title, "Archive closed targets")
        XCTAssertEqual(session.targetID, 415)
        XCTAssertEqual(session.agent, .claudeCode)
        XCTAssertEqual(session.createdAt, t0.addingTimeInterval(-10000))
        XCTAssertEqual(session.lastActiveAt, t0)
        XCTAssertEqual(session.stateAt, t0.addingTimeInterval(-10))
        XCTAssertTrue(session.live)
        XCTAssertEqual(session.stateKind, .waitingOnAsk)
        XCTAssertEqual(session.stateCaption, "Waiting for you · ask #12")
        XCTAssertEqual(session.stateTone, .orange)
        XCTAssertEqual(session.stateGlyph, "questionmark")
        XCTAssertFalse(session.isRing)
        XCTAssertEqual(session.openAsks, 1)
        XCTAssertEqual(session.oldestAskID, 12)
        XCTAssertEqual(session.closedAsks, 2)
        XCTAssertEqual(session.finishSummary, "")
        XCTAssertEqual(session.agentError, "")
        XCTAssertEqual(session.reportTargetID, 415)
        XCTAssertEqual(session.reportDone, 1)
        XCTAssertEqual(session.reportTotal, 2)
        XCTAssertEqual(session.reportPRLine, "PR #175 open")
    }

    func testOpenQuestionAskFixture() throws {
        let ask = try OwnerAsk.decode(payload: try fixture("owner_ask"))
        XCTAssertEqual(ask.id, 12)
        XCTAssertEqual(ask.workbenchID, 7)
        XCTAssertEqual(ask.workbenchName, "Acme")
        XCTAssertEqual(ask.sessionID, 31)
        XCTAssertEqual(ask.targetID, 415)
        XCTAssertEqual(ask.kind, .question)
        XCTAssertEqual(ask.status, .open)
        XCTAssertNil(ask.withdrawnReason)
        XCTAssertNil(ask.previousAskID)
        XCTAssertEqual(ask.createdAt, t0)
        XCTAssertNil(ask.answeredAt)
        XCTAssertNil(ask.deliveredAt)
        XCTAssertEqual(ask.title, "Which release?")
        XCTAssertEqual(ask.summary, "The summary needs a release to cover.")
        XCTAssertNil(ask.answer)
        XCTAssertNil(ask.docSnapshot)

        let payload = try XCTUnwrap(ask.payload)
        XCTAssertEqual(payload.focus, [OwnerAskPayload.Focus(text: "Both are cheap to build.")])
        XCTAssertEqual(payload.checklist, [])
        let question = try XCTUnwrap(payload.questions.first)
        XCTAssertEqual(question.id, "scope")
        XCTAssertFalse(question.multi)
        XCTAssertEqual(
            question.options,
            [
                .init(label: "v0.11", description: "The release being cut now", recommended: true),
                .init(label: "v0.10", description: "The last shipped release")
            ]
        )

        XCTAssertEqual(
            ask.quick,
            OwnerAsk.Quick(
                questionID: "scope",
                options: [.init(label: "v0.11", recommended: true), .init(label: "v0.10", recommended: false)]
            )
        )
    }

    func testOpenReviewAskFixture() throws {
        let ask = try OwnerAsk.decode(payload: try fixture("owner_ask_review"))
        XCTAssertEqual(ask.kind, .review)
        XCTAssertEqual(ask.previousAskID, 13)
        XCTAssertNil(ask.targetID)
        XCTAssertEqual(ask.changes, "Step 2 now batches the rows.")
        XCTAssertEqual(ask.docPath, "docs/plans/acme-rollout.md")
        XCTAssertEqual(ask.docSnapshot, "# Rollout\n\nStep 1: back up.\n")
        XCTAssertEqual(ask.docClipped, true)
        XCTAssertEqual(ask.docBytes, 2_097_152)
        XCTAssertEqual(
            try XCTUnwrap(ask.payload).focus,
            [.init(text: "Is the rollout order right?", heading: "Rollout", quote: "migrate every row at once")]
        )
        XCTAssertNil(ask.quick)
    }

    func testClosedCheckAskFixture() throws {
        let ask = try OwnerAsk.decode(payload: try fixture("owner_ask_closed"))
        XCTAssertEqual(ask.kind, .check)
        XCTAssertEqual(ask.status, .delivered)
        XCTAssertNil(ask.sessionID)
        XCTAssertEqual(ask.answeredAt, t0.addingTimeInterval(100))
        XCTAssertEqual(ask.deliveredAt, t0.addingTimeInterval(200))
        XCTAssertEqual(ask.titleClipped, true)
        XCTAssertEqual(
            try XCTUnwrap(ask.payload).checklist,
            [
                .init(id: "1", text: "Launch the app"),
                .init(id: "login", text: "Sign in with a second account", hint: "Settings, Accounts")
            ]
        )
        XCTAssertEqual(
            ask.answer,
            OwnerAskAnswer(checklist: [
                .init(id: "1", state: .ok),
                .init(id: "login", state: .broken, note: "The sheet closes on its own.")
            ])
        )
    }

    /// A clipped payload is dropped (spec §4.6): the phone then offers only
    /// "Open the ask on the Mac".
    func testClippedPayloadDecodesWithoutAPayload() throws {
        var json = try object("owner_ask")
        json["payload"] = nil
        json["quick"] = nil
        json["payload_clipped"] = true
        let ask = try OwnerAsk.decode(payload: try data(json))
        XCTAssertNil(ask.payload)
        XCTAssertEqual(ask.payloadClipped, true)
    }

    /// Go omits empty optional fields; ids default to the 1-based position,
    /// as in Core's `OwnerAskPayload` and Go's `asks`.
    func testPayloadOmittedFieldsDecodeAsDefaults() throws {
        let json = #"{"questions":[{"question":"Ship it?","options":[{"label":"Yes"},{"label":"No"}]}],"checklist":[{"text":"Launch"}]}"#
        let payload = try JSONDecoder().decode(OwnerAskPayload.self, from: Data(json.utf8))
        XCTAssertEqual(payload.focus, [])
        XCTAssertEqual(payload.questions.first?.id, "1")
        XCTAssertEqual(payload.questions.first?.multi, false)
        XCTAssertEqual(payload.questions.first?.options.first, .init(label: "Yes"))
        XCTAssertEqual(payload.checklist, [.init(id: "1", text: "Launch")])
    }

    func testSessionReportFixture() throws {
        let report = try SessionReport.decode(payload: try fixture("session_report"))
        XCTAssertEqual(report.session.id, 31)
        XCTAssertEqual(report.session.targetID, 415)
        XCTAssertEqual(report.session.agentState, "stop")
        XCTAssertEqual(report.progress, SessionReport.Progress(done: 1, total: 2))
        XCTAssertEqual(report.onYou.map(\.id), [12])
        XCTAssertEqual(report.onYou.first?.targetID, 415)
        XCTAssertEqual(report.now.first?.branch, "feature/acme-export")
        XCTAssertEqual(report.next.map(\.id), [417])
        XCTAssertEqual(report.nextMore, 3)
        XCTAssertNil(report.onYouMore)
        XCTAssertEqual(report.phases.first?.targetID, 415)
        XCTAssertEqual(report.phases.first?.items.map(\.id), [416, 418])
        XCTAssertEqual(report.phasesClipped, true)
        let pr = try XCTUnwrap(report.prs.first)
        XCTAssertEqual(pr.ref, "pr:175")
        XCTAssertEqual(pr.prNumber, 175)
        XCTAssertEqual(pr.state, "open")
        XCTAssertEqual(pr.additions, 120)
        XCTAssertEqual(pr.targets, [415])
        XCTAssertEqual(report.prNote, "")
    }

    /// Every key of the CLI's report may be absent (an older or newer CLI);
    /// it decodes with defaults, as Core's `SessionReport` does.
    func testEmptySessionReportDecodesWithDefaults() throws {
        let report = try SessionReport.decode(payload: Data("{}".utf8))
        XCTAssertEqual(report.session.id, 0)
        XCTAssertEqual(report.progress, SessionReport.Progress(done: 0, total: 0))
        XCTAssertEqual(report.phases, [])
        XCTAssertNil(report.phasesClipped)
    }

    func testSessionTimelineFixture() throws {
        let timeline = try SessionTimeline.decode(payload: try fixture("session_timeline"))
        XCTAssertEqual(timeline.sessionID, 31)
        XCTAssertEqual(timeline.milestonesMore, 4)
        XCTAssertEqual(
            timeline.milestones,
            [
                .init(at: t0.addingTimeInterval(100), kind: .askOpened, text: "Asked: Which release?", ref: 12),
                .init(at: t0.addingTimeInterval(50), kind: .targetStatus, text: "todo → in_progress (agent)", ref: 415),
                .init(at: t0, kind: .state, text: "Started")
            ]
        )
    }

    // MARK: - Tolerance

    private static let allFixtures = [
        "workbench", "workbench_target", "workbench_comment", "terminal_session",
        "owner_ask", "owner_ask_review", "owner_ask_closed", "session_report", "session_timeline"
    ]

    private func decodeAny(_ name: String, _ payload: Data) throws -> AnyHashable {
        switch name {
        case "workbench": AnyHashable(try Workbench.decode(payload: payload))
        case "workbench_target": AnyHashable(try WorkbenchTarget.decode(payload: payload))
        case "workbench_comment": AnyHashable(try WorkbenchComment.decode(payload: payload))
        case "terminal_session": AnyHashable(try TerminalSessionState.decode(payload: payload))
        case "owner_ask", "owner_ask_review", "owner_ask_closed": AnyHashable(try OwnerAsk.decode(payload: payload))
        case "session_report": AnyHashable(try SessionReport.decode(payload: payload))
        case "session_timeline": AnyHashable(try SessionTimeline.decode(payload: payload))
        default: throw XCTSkip("unknown fixture \(name)")
        }
    }

    func testUnknownExtraKeysAreIgnored() throws {
        for name in Self.allFixtures {
            var json = try object(name)
            json["from_a_newer_mac"] = ["nested": [1, 2, 3]]
            json["another_new_flag"] = true
            XCTAssertEqual(try decodeAny(name, try data(json)), try decodeAny(name, try fixture(name)), name)
        }
    }

    /// A newer Mac may add a state, tone, status or milestone kind: the
    /// record still decodes and keeps the raw string.
    func testFutureEnumValuesStillDecode() throws {
        var session = try object("terminal_session")
        session["state_kind"] = "compacting"
        session["state_tone"] = "purple"
        session["agent"] = "codex"
        let decodedSession = try TerminalSessionState.decode(payload: try data(session))
        XCTAssertEqual(decodedSession.stateKind.rawValue, "compacting")
        XCTAssertFalse(decodedSession.stateKind.isKnown)
        XCTAssertFalse(decodedSession.stateTone.isKnown)
        XCTAssertFalse(decodedSession.agent.isKnown)

        var target = try object("workbench_target")
        target["status"] = "parked"
        target["priority"] = "urgent"
        target["last_status_actor"] = "robot"
        let decodedTarget = try WorkbenchTarget.decode(payload: try data(target))
        XCTAssertEqual(decodedTarget.status.rawValue, "parked")
        XCTAssertFalse(decodedTarget.status.isKnown)
        XCTAssertFalse(decodedTarget.priority.isKnown)
        XCTAssertEqual(decodedTarget.lastStatusActor?.isKnown, false)

        var ask = try object("owner_ask_closed")
        ask["kind"] = "poll"
        ask["status"] = "archived"
        ask["withdrawn_reason"] = "expired"
        var answer = try XCTUnwrap(ask["answer"] as? [String: Any])
        answer["verdict"] = "rejected"
        answer["checklist"] = [["id": "1", "note": "", "state": "maybe"]]
        ask["answer"] = answer
        let decodedAsk = try OwnerAsk.decode(payload: try data(ask))
        XCTAssertFalse(decodedAsk.kind.isKnown)
        XCTAssertFalse(decodedAsk.status.isKnown)
        XCTAssertEqual(decodedAsk.withdrawnReason?.rawValue, "expired")
        XCTAssertEqual(decodedAsk.answer?.verdict?.rawValue, "rejected")
        XCTAssertEqual(decodedAsk.answer?.checklist.first?.state.isKnown, false)

        var timeline = try object("session_timeline")
        timeline["milestones"] = [["at": 1_700_000_000, "kind": "subagent", "text": "Ran a subagent"]]
        let decodedTimeline = try SessionTimeline.decode(payload: try data(timeline))
        XCTAssertEqual(decodedTimeline.milestones.first?.kind.rawValue, "subagent")
    }

    func testMissingOptionalsDecodeAsNil() throws {
        var session = try object("terminal_session")
        for key in ["target_id", "oldest_ask_id", "state_at", "report_target_id", "report_done", "report_total", "report_pr_line"] {
            session[key] = nil
        }
        let decodedSession = try TerminalSessionState.decode(payload: try data(session))
        XCTAssertNil(decodedSession.targetID)
        XCTAssertNil(decodedSession.oldestAskID)
        XCTAssertNil(decodedSession.stateAt)
        XCTAssertNil(decodedSession.reportTargetID)
        XCTAssertNil(decodedSession.reportDone)
        XCTAssertNil(decodedSession.reportTotal)
        XCTAssertNil(decodedSession.reportPRLine)

        var ask = try object("owner_ask")
        ask["target_id"] = nil
        ask["quick"] = nil
        ask["session_id"] = nil
        let decodedAsk = try OwnerAsk.decode(payload: try data(ask))
        XCTAssertNil(decodedAsk.targetID)
        XCTAssertNil(decodedAsk.quick)
        XCTAssertNil(decodedAsk.sessionID)

        var withdrawn = try object("owner_ask_closed")
        withdrawn["withdrawn_reason"] = ""
        XCTAssertNil(try OwnerAsk.decode(payload: try data(withdrawn)).withdrawnReason, "\"\" is no reason")

        var comment = try object("workbench_comment")
        comment["target_id"] = nil
        comment["parent_id"] = nil
        let decodedComment = try WorkbenchComment.decode(payload: try data(comment))
        XCTAssertNil(decodedComment.targetID)
        XCTAssertNil(decodedComment.parentID)

        var target = try object("workbench_target")
        for key in ["parent_id", "last_status_at", "last_status_actor"] {
            target[key] = nil
        }
        let decodedTarget = try WorkbenchTarget.decode(payload: try data(target))
        XCTAssertNil(decodedTarget.parentID)
        XCTAssertNil(decodedTarget.lastStatusAt)
        XCTAssertNil(decodedTarget.lastStatusActor)

        var workbench = try object("workbench")
        workbench["last_session_activity"] = nil
        workbench["targets_more"] = nil
        workbench["description_clipped"] = nil
        let decodedWorkbench = try Workbench.decode(payload: try data(workbench))
        XCTAssertNil(decodedWorkbench.lastSessionActivity)
        XCTAssertNil(decodedWorkbench.targetsMore)
        XCTAssertNil(decodedWorkbench.descriptionClipped)

        var milestone = try object("session_timeline")
        milestone["milestones_more"] = nil
        milestone["session_id"] = nil
        let decodedTimeline = try SessionTimeline.decode(payload: try data(milestone))
        XCTAssertNil(decodedTimeline.milestonesMore)
        XCTAssertNil(decodedTimeline.sessionID)
        XCTAssertNil(decodedTimeline.milestones.last?.ref)
    }

    // MARK: - OwnerAskAnswer against internal/asks/testdata/answers

    private static let goAnswers = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // WatchtowerKitTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // WatchtowerKit
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("internal/asks/testdata/answers")

    /// Every answers fixture: a valid one re-encodes to its `canonical` byte
    /// for byte (what Go's `json.Marshal` of `asks.Answer` gives); an invalid
    /// one (no canonical) re-encodes to its own `answer` in canonical form —
    /// the phone keeps even an answer the Mac would refuse unchanged.
    func testAnswerEncodesByteEqualToEveryGoFixture() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.goAnswers.path)
            .filter { $0.hasSuffix(".json") }
            .sorted()
        XCTAssertGreaterThanOrEqual(names.count, 9)
        for name in names {
            let raw = try Data(contentsOf: Self.goAnswers.appendingPathComponent(name))
            let file = try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any], name)
            let answerObject = try XCTUnwrap(file["answer"], name)
            let answerJSON = try JSONSerialization.data(withJSONObject: answerObject)
            let answer = try JSONDecoder().decode(OwnerAskAnswer.self, from: answerJSON)
            let expected: String
            if let canonical = file["canonical"] as? String {
                expected = canonical
            } else {
                let sorted = try JSONSerialization.data(
                    withJSONObject: answerObject, options: [.sortedKeys, .withoutEscapingSlashes]
                )
                expected = try XCTUnwrap(String(data: sorted, encoding: .utf8))
            }
            XCTAssertEqual(Data(try answer.encoded().utf8), Data(expected.utf8), "\(name): byte for byte")
            XCTAssertEqual(try OwnerAskAnswer.decode(expected), answer, "\(name) round-trips")
        }
    }

    func testAnEmptyAnswerWritesEveryKey() throws {
        XCTAssertEqual(
            try OwnerAskAnswer().encoded(),
            #"{"answers":[],"checklist":[],"comments":[],"note":"","verdict":""}"#
        )
    }

    // MARK: - Action params round-trip

    private func encoded(_ payload: ActionRequestPayload) throws -> String {
        try XCTUnwrap(String(data: try RelayCoder.makeEncoder().encode(payload), encoding: .utf8))
    }

    /// The typed params become the request's `params` object, encode to the
    /// frozen literal, and come back equal from the decoded request.
    private func assertParams<P: ActionParams>(
        _ params: P,
        entityID: String?,
        _ fixture: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let request = ActionRequestPayload(
            id: "A1", kind: P.actionKind, entityID: entityID, params: try params.wireParams(), createdAt: t0, deviceID: "D1"
        )
        XCTAssertEqual(try encoded(request), fixture, file: file, line: line)
        let decoded = try RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: Data(fixture.utf8))
        XCTAssertEqual(decoded, request, file: file, line: line)
        XCTAssertEqual(try P(wireParams: decoded.params), params, file: file, line: line)
    }

    private func wire(_ kind: String, entity: String?, params: String) -> String {
        let entityPart = entity.map { #""entity_id":"\#($0)","# } ?? ""
        return #"{"created_at":1700000000,"device_id":"D1","#
            + entityPart
            + #""id":"A1","kind":"\#(kind)","params":\#(params),"status":"pending"}"#
    }

    func testAskAnswerParamsRoundTrip() throws {
        let answer = OwnerAskAnswer(
            verdict: .changes,
            answers: [.init(id: "1", labels: ["Yes"])],
            comments: [.init(quote: "migrate every row", prefix: "Step 2: ", suffix: ".", heading: "Rollout", body: "Batch it.")],
            note: "One more round."
        )
        try assertParams(
            AskAnswerParams(workbenchID: 7, answer: answer),
            entityID: "14",
            wire(
                "ask_answer",
                entity: "14",
                // swiftlint:disable:next line_length
                params: #"{"answer":{"answers":[{"id":"1","labels":["Yes"],"other":""}],"checklist":[],"comments":[{"body":"Batch it.","heading":"Rollout","prefix":"Step 2: ","quote":"migrate every row","suffix":"."}],"note":"One more round.","verdict":"changes"},"workbench_id":7}"#
            )
        )
    }

    func testBoardParamsRoundTrip() throws {
        try assertParams(
            BoardTargetStatusParams(workbenchID: 7, status: .done, fromStatus: .inProgress),
            entityID: "415",
            wire("board_target_status", entity: "415", params: #"{"from_status":"in_progress","status":"done","workbench_id":7}"#)
        )
        try assertParams(
            BoardTargetPriorityParams(workbenchID: 7, priority: .low, fromPriority: .high),
            entityID: "415",
            wire("board_target_priority", entity: "415", params: #"{"from_priority":"high","priority":"low","workbench_id":7}"#)
        )
        try assertParams(
            BoardCommentAddParams(workbenchID: 7, body: "Looks right."),
            entityID: "415",
            wire("board_comment_add", entity: "415", params: #"{"body":"Looks right.","workbench_id":7}"#)
        )
        try assertParams(
            BoardCommentReplyParams(workbenchID: 7, body: "Yes, the second."),
            entityID: "88",
            wire("board_comment_reply", entity: "88", params: #"{"body":"Yes, the second.","workbench_id":7}"#)
        )
        try assertParams(
            BoardTargetCreateParams(workbenchID: 7, parentID: 400, text: "Undo Archive Now", intent: "", priority: .medium),
            entityID: nil,
            wire(
                "board_target_create",
                entity: nil,
                params: #"{"intent":"","parent_id":400,"priority":"medium","text":"Undo Archive Now","workbench_id":7}"#
            )
        )
        // A top-level target: the absent parent is an absent key.
        try assertParams(
            BoardTargetCreateParams(workbenchID: 7, text: "Export", intent: "CSV first", priority: .high),
            entityID: nil,
            wire(
                "board_target_create",
                entity: nil,
                params: #"{"intent":"CSV first","priority":"high","text":"Export","workbench_id":7}"#
            )
        )
    }

    func testSessionParamsRoundTrip() throws {
        try assertParams(
            SessionStartParams(workbenchID: 7, mode: .openExisting, planFirst: true, bringForward: false),
            entityID: "415",
            wire(
                "session_start",
                entity: "415",
                params: #"{"bring_forward":false,"mode":"open_existing","plan_first":true,"workbench_id":7}"#
            )
        )
        try assertParams(
            SessionStartParams(workbenchID: 7, mode: .new, planFirst: false, bringForward: true, brief: "-Start with the tests"),
            entityID: "415",
            wire(
                "session_start",
                entity: "415",
                params: #"{"brief":"-Start with the tests","bring_forward":true,"mode":"new","plan_first":false,"workbench_id":7}"#
            )
        )
        try assertParams(
            SessionInputParams(text: "Use the second option"),
            entityID: "31",
            wire("session_input", entity: "31", params: #"{"text":"Use the second option"}"#)
        )
        try assertParams(
            SessionInputCancelParams(),
            entityID: "B2",
            wire("session_input_cancel", entity: "B2", params: "{}")
        )
        try assertParams(
            SessionFinishRequestParams(),
            entityID: "31",
            wire("session_finish_request", entity: "31", params: "{}")
        )
        try assertParams(SessionStopParams(), entityID: "31", wire("session_stop", entity: "31", params: "{}"))
        try assertParams(
            SessionReportRequestParams(),
            entityID: "31",
            wire("session_report_request", entity: "31", params: "{}")
        )
    }

    /// Params a hub decodes as plain JSON: a bool stays a bool and an object
    /// stays an object (not a SQLite integer or text).
    func testParamsKeepBoolsAndObjects() throws {
        let params = try SessionStartParams(workbenchID: 7, mode: .new, planFirst: true, bringForward: false).wireParams()
        XCTAssertEqual(params["plan_first"], .bool(true))
        XCTAssertEqual(params["workbench_id"], .integer(7))
        let answer = try AskAnswerParams(workbenchID: 7, answer: OwnerAskAnswer(verdict: .approved)).wireParams()
        guard case .object(let object) = answer["answer"] else {
            return XCTFail("answer is an object, got \(String(describing: answer["answer"]))")
        }
        XCTAssertEqual(object["verdict"], .string("approved"))
        XCTAssertEqual(object["answers"], .array([]))
    }
}
