import GRDB
import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The phone's session detail (spec §4.8, §4.9, §13 B3) over the demo seed:
/// header, its open asks, the report and the timeline, and the throttled
/// `session_report_request` sent on open.
@MainActor
final class SessionDetailWiringTests: XCTestCase {
    private let now = Date()

    /// The demo's session-detail records, decoded as the view model reads
    /// them.
    private func demoRecords() throws -> (reports: [Int64: SessionReport], timelines: [Int64: SessionTimeline]) {
        var reports: [Int64: SessionReport] = [:]
        var timelines: [Int64: SessionTimeline] = [:]
        for (kind, id, json) in DemoSeed.sessionDetailSlices(now: now) {
            switch kind {
            case .sessionReport: reports[id] = try mirror(SessionReport.self, json)
            case .sessionTimeline: timelines[id] = try mirror(SessionTimeline.self, json)
            default: XCTFail("unexpected kind \(kind.rawValue)")
            }
        }
        return (reports, timelines)
    }

    private func model(_ sessionID: Int64) throws -> SessionDetailModel {
        let snapshot = try demoSnapshot(now: now)
        let records = try demoRecords()
        return try XCTUnwrap(SessionDetailModel(
            sessionID: sessionID,
            snapshot: snapshot,
            report: records.reports[sessionID],
            timeline: records.timelines[sessionID],
            now: now
        ))
    }

    // MARK: - Header, asks, report, timeline

    func testTheHeaderShowsTitleTargetBranchAgentAndAge() throws {
        let detail = try model(11)
        XCTAssertEqual(detail.title, "Archive closed targets")
        XCTAssertEqual(detail.target?.id, 415)
        XCTAssertEqual(detail.target?.label, "#415 Archive Closed Targets Now")
        XCTAssertEqual(detail.branch, "feature/archive-now", "the target's branch wins over the workbench's")
        XCTAssertEqual(detail.agentLine, "Claude Code · 1h")
        XCTAssertEqual(detail.state.caption, "Waiting for you · ask #109 · 2 asks")
        XCTAssertNil(detail.approvalNotice)
    }

    func testTheSessionsOpenAsksComeFirst() throws {
        let detail = try model(11)
        XCTAssertEqual(detail.asks.map(\.id), [111, 109], "open asks of this session, newest first")
        XCTAssertEqual(detail.asks.map(\.kindLabel), ["CHECK", "ASK"])
        XCTAssertEqual(detail.asksSince, "since 15m", "the oldest open ask")
    }

    func testTheReportShowsProgressSegmentsAndSummary() throws {
        let report = try XCTUnwrap(try model(11).report)
        XCTAssertEqual(report.progressLabel, "2 / 5 targets")
        XCTAssertEqual(report.segments.map(\.label), ["done", "done", "in progress", "to do", "to do"])
        XCTAssertEqual(report.segments.map(\.tone), [.green, .green, .accent, .secondary, .secondary])
        XCTAssertEqual(report.accessibilityLabel, "2 of 5 targets done, 1 in progress")
        XCTAssertEqual(report.summary, ["Now: Archive Closed Targets Now", "Next: Undo Archive Now"])
        XCTAssertEqual(report.prLines, ["PR #175 open"])
    }

    func testAFinishedSessionsSummaryIsItsFinishSummary() throws {
        let report = try XCTUnwrap(try model(13).report)
        XCTAssertEqual(report.summary, ["Folded done targets per lane."])
    }

    func testAReportOverManyTargetsDrawsOneSegmentPerRun() throws {
        let snapshot = try demoSnapshot(now: now)
        let report = try mirror(SessionReport.self, ["progress": ["done": 30, "total": 40], "now": [
            ["id": 1, "text": "A", "status": "blocked"]
        ]])
        let section = try XCTUnwrap(SessionDetailModel(sessionID: 10, snapshot: snapshot, report: report, timeline: nil, now: now)?.report)
        XCTAssertEqual(section.segments.map(\.label), ["30 done", "1 blocked", "9 to do"])
        XCTAssertEqual(section.segments.map(\.weight), [30, 1, 9])
        XCTAssertEqual(section.segments.map(\.tone), [.green, .red, .secondary])
    }

    func testTheTimelineIsNewestFirstAndLinksTargets() throws {
        let detail = try model(11)
        XCTAssertEqual(detail.timeline.first?.text, "Asked you · ask #111")
        XCTAssertEqual(detail.timeline.map(\.at), detail.timeline.map(\.at).sorted(by: >))
        let linked = try XCTUnwrap(detail.timeline.first { $0.text.hasPrefix("Linked") })
        XCTAssertEqual(linked.targetID, 415, "a target milestone opens the target")
        let asked = try XCTUnwrap(detail.timeline.first)
        XCTAssertNil(asked.targetID, "an ask milestone opens nothing yet")
        XCTAssertEqual(asked.tone, PhoneTone.waitingForYou)
        XCTAssertFalse(asked.accessibilityLabel.isEmpty)
    }

    /// Spec §13 B3 (c).
    func testASessionWithNoReportShowsTheHeaderAndTimelineOnly() throws {
        let detail = try model(16)
        XCTAssertEqual(detail.title, "Undo archive")
        XCTAssertNil(detail.report)
        XCTAssertTrue(detail.asks.isEmpty)
        XCTAssertNil(detail.approvalNotice)
        XCTAssertFalse(detail.timeline.isEmpty)
        XCTAssertNil(detail.timelineEmptyText)
    }

    func testASessionWithNothingYetSaysSo() throws {
        let detail = try model(17)
        XCTAssertNil(detail.report)
        XCTAssertTrue(detail.timeline.isEmpty)
        XCTAssertEqual(detail.timelineEmptyText, "No milestones yet")
    }

    func testANeedsApprovalSessionPointsToTheMac() throws {
        let detail = try model(12)
        XCTAssertEqual(detail.approvalNotice, "Needs approval on the Mac")
        XCTAssertTrue(detail.toneUses.contains { $0.element.hasSuffix("approval notice") && $0.isWaitingOrAsk })
        XCTAssertNil(try model(10).approvalNotice)
    }

    func testAnUnknownSessionHasNoDetail() throws {
        XCTAssertNil(SessionDetailModel(sessionID: 999, snapshot: try demoSnapshot(now: now), report: nil, timeline: nil, now: now))
    }

    // MARK: - session_report_request on open

    /// Spec §13 B3 (d), phone side: opening the detail twice within 60 s,
    /// through two view models (the view re-created), queues one request.
    func testOpeningTwiceWithin60sSendsOneRequest() async throws {
        let store = try makePoolStore()
        let outbox = ActionOutbox(transport: InMemoryCloudTransport(), store: store, deviceID: DemoSeed.device.deviceID)
        var clock = now
        let requester = SessionReportRequester.sending(through: outbox) { clock }

        await SessionDetailViewModel(sessionID: 11, store: store, requester: requester).opened()
        clock = now.addingTimeInterval(59)
        await SessionDetailViewModel(sessionID: 11, store: store, requester: requester).opened()

        var actions = try store.pendingActions()
        XCTAssertEqual(actions.count, 1)
        let action = try XCTUnwrap(actions.first)
        XCTAssertEqual(action.action.kind, .sessionReportRequest)
        XCTAssertEqual(action.entityRecordName, "terminal_session-11")
        XCTAssertEqual(action.action.entityID, "11")
        XCTAssertEqual(action.action.params, [:])

        await SessionDetailViewModel(sessionID: 12, store: store, requester: requester).opened()
        clock = now.addingTimeInterval(61)
        await SessionDetailViewModel(sessionID: 11, store: store, requester: requester).opened()
        actions = try store.pendingActions()
        XCTAssertEqual(actions.map(\.entityRecordName), ["terminal_session-11", "terminal_session-12", "terminal_session-11"])
    }

    /// A send that failed does not hold the throttle: the next open retries.
    func testAFailedSendIsRetriedOnTheNextOpen() async throws {
        var calls = 0
        var fail = true
        let requester = SessionReportRequester(now: { Date() }, send: { _ in
            calls += 1
            if fail { throw ActionOutboxError.notLinked }
        })
        let first = await requester.requestReport(sessionID: 11)
        XCTAssertFalse(first)
        fail = false
        let second = await requester.requestReport(sessionID: 11)
        XCTAssertTrue(second)
        let third = await requester.requestReport(sessionID: 11)
        XCTAssertFalse(third)
        XCTAssertEqual(calls, 2)
    }

    /// The view model reads the session's report and timeline from the
    /// replica and follows later writes.
    func testTheViewModelObservesTheSessionsRecords() async throws {
        let store = try makePoolStore()
        let transport = InMemoryCloudTransport()
        try await DemoSeed.load(into: transport, now: now)
        _ = try await ReplicaHydrator(transport: transport, store: store).hydrateOnce()
        let requester = SessionReportRequester(now: { Date() }, send: { _ in })
        let model = SessionDetailViewModel(sessionID: 11, store: store, requester: requester)
        model.start()
        try await poll({ model.report != nil && model.timeline != nil }, "the session's records never arrived")
        XCTAssertEqual(model.report?.progress.total, 5)

        let other = SessionDetailViewModel(sessionID: 17, store: store, requester: requester)
        other.start()
        try await poll({ other.loaded }, "the first read never landed")
        XCTAssertNil(other.report)
        XCTAssertNil(other.timeline)
    }

    // MARK: - I-4: no transcript anywhere

    /// The mirrors the screen draws have exactly these fields: a new one
    /// (say a transcript) fails here until it is reviewed against I-4.
    func testTheSessionMirrorsHaveNoTranscriptField() throws {
        let records = try demoRecords()
        let report = try XCTUnwrap(records.reports[11])
        let timeline = try XCTUnwrap(records.timelines[11])
        let session = try XCTUnwrap(try demoSnapshot(now: now).session(11))

        XCTAssertEqual(fieldNames(report), [
            "session", "progress", "onYou", "onYouMore", "now", "nowMore", "next", "nextMore",
            "phases", "phasesMore", "phasesClipped", "prs", "prsMore", "prNote"
        ])
        XCTAssertEqual(fieldNames(report.session), [
            "id", "title", "targetID", "kind", "createdAt", "lastActiveAt", "agentState", "agentStateAt",
            "finishedAt", "finishSummary"
        ])
        XCTAssertEqual(fieldNames(timeline), ["sessionID", "milestones", "milestonesMore"])
        XCTAssertEqual(fieldNames(try XCTUnwrap(timeline.milestones.first)), ["at", "kind", "text", "textClipped", "ref"])
        XCTAssertEqual(fieldNames(session), [
            "id", "workbenchID", "title", "titleClipped", "targetID", "agent", "createdAt", "lastActiveAt", "stateAt",
            "live", "stateKind", "stateCaption", "stateCaptionClipped", "stateTone", "stateGlyph", "isRing", "openAsks",
            "oldestAskID", "closedAsks", "finishSummary", "finishSummaryClipped", "agentError", "agentErrorClipped",
            "reportTargetID", "reportDone", "reportTotal", "reportPRLine", "reportPRLineClipped"
        ])
    }

    /// The view model and the screen model hold exactly these fields.
    func testTheDetailModelsHaveNoTranscriptField() throws {
        let store = try ReplicaStore.inMemory()
        let viewModel = SessionDetailViewModel(sessionID: 11, store: store, requester: SessionReportRequester(now: { Date() }, send: { _ in }))
        XCTAssertEqual(fieldNames(viewModel), ["sessionID", "report", "timeline", "loaded", "store", "requester", "cancellable"])
        XCTAssertEqual(fieldNames(try model(11)), [
            "id", "title", "state", "target", "branch", "agentLine", "approvalNotice", "asks", "asksSince", "report",
            "timeline", "timelineEmptyText", "timelineMoreText"
        ])
    }

    /// The rendered-text snapshot: a payload carrying transcript text under
    /// keys the mirrors do not know draws none of it, while the screen still
    /// draws the session.
    func testTranscriptTextInAPayloadIsNeverDrawn() throws {
        let secret = "TRANSCRIPT-SENTINEL"
        var sessionJSON = DemoSeed.JSON.session(40, workbench: DemoSeed.acmeID, ["title": "Plain title"])
        sessionJSON["transcript"] = secret
        sessionJSON["terminal_text"] = secret
        var snapshot = try demoSnapshot(now: now)
        snapshot.sessions.append(try mirror(TerminalSessionState.self, sessionJSON))
        let report = try mirror(SessionReport.self, [
            "session": ["id": 40, "title": "Plain title", "transcript": secret],
            "progress": ["done": 1, "total": 2],
            "transcript": secret,
            "output": secret
        ])
        let timeline = try mirror(SessionTimeline.self, [
            "session_id": 40,
            "milestones": [["at": DemoSeed.JSON.stamp(now), "kind": "state", "text": "Working", "transcript": secret]],
            "transcript": secret
        ])

        let detail = try XCTUnwrap(SessionDetailModel(sessionID: 40, snapshot: snapshot, report: report, timeline: timeline, now: now))
        let drawn = renderedStrings(detail)
        XCTAssertTrue(drawn.contains("Plain title"))
        XCTAssertTrue(drawn.contains("Working"))
        XCTAssertFalse(drawn.contains { $0.contains(secret) }, "transcript text reached the screen")
    }

    // MARK: - The Tell bar waits for B-T18

    func testTheTellBarIsHidden() {
        XCTAssertFalse(SessionDetailView.showsTellBar)
    }

    // MARK: - Helpers

    private func fieldNames(_ value: Any) -> [String] {
        Mirror(reflecting: value).children.compactMap(\.label).compactMap { label in
            // @Observable keeps each stored property as `_name` beside its
            // registrar.
            label == "_$observationRegistrar" ? nil : (label.hasPrefix("_") ? String(label.dropFirst()) : label)
        }
    }

    /// Every String reachable from `value`: what the screen can draw.
    private func renderedStrings(_ value: Any) -> [String] {
        if let string = value as? String {
            return [string]
        }
        return Mirror(reflecting: value).children.flatMap { renderedStrings($0.value) }
    }
}
