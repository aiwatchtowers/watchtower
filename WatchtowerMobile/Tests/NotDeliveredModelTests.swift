import WatchtowerKit
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The Not delivered list (relay client Phase 1, mockup 5a): one row per action that never reached the Mac, oldest
/// first, its one-line summary, its time and why; Retry per row and Dismiss All behind a confirmation.
final class NotDeliveredModelTests: XCTestCase {
    /// Pinned at local noon today: an offset of a few hours never crosses midnight.
    private let now = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date()) ?? Date()

    private func item(
        _ id: String,
        _ kind: ActionKind,
        entity: String?,
        params: [String: JSONValue] = [:],
        seq: UInt64 = 1,
        at: Date? = nil,
        delivery: Delivery = .undelivered,
        reason: UndeliveredReason? = .refused
    ) -> OutboxItem {
        OutboxItem(
            id: id, kind: kind, entityRecordName: entity, params: params, createdAt: at ?? now, seq: seq,
            delivery: delivery, reason: reason)
    }

    private func model(
        _ items: [OutboxItem], retrying: Set<String> = [], errors: [String: String] = [:]
    ) throws -> NotDeliveredModel {
        // As the view builds it: the Not delivered rows, oldest first.
        NotDeliveredModel(
            items: OutboxItem.ordered(items, .undelivered), snapshot: try demoSnapshot(now: now), macName: "Acme Mac", now: now, calendar: .current,
            retrying: retrying, errors: errors)
    }

    // MARK: - Summaries

    func testTheSummaryPerKind() throws {
        let snapshot = try demoSnapshot(now: now)
        let pick = try AskAnswerParams(
            workbenchID: DemoSeed.acmeID, answer: OwnerAskAnswer(answers: [.init(id: "q1", labels: ["Archive Now"])])
        ).wireParams()
        let approve = try AskAnswerParams(workbenchID: DemoSeed.acmeID, answer: OwnerAskAnswer(verdict: .approved)).wireParams()
        let done = try BoardTargetStatusParams(workbenchID: DemoSeed.acmeID, status: .done, fromStatus: .todo).wireParams()
        let comment = try BoardCommentAddParams(workbenchID: DemoSeed.acmeID, body: "Looks good").wireParams()
        let create = try BoardTargetCreateParams(
            workbenchID: DemoSeed.acmeID, parentID: nil, text: "Write the release notes", intent: "", priority: .medium
        ).wireParams()
        let start = try SessionStartParams(workbenchID: DemoSeed.acmeID, mode: .new, planFirst: false, bringForward: false).wireParams()
        let long = String(repeating: "a", count: 58) + " bcdef"
        let input = try SessionInputParams(text: long).wireParams()
        let allow = try PermissionAnswerParams(requestID: 7, behavior: .allow).wireParams()
        let deny = try PermissionAnswerParams(requestID: 7, behavior: .deny).wireParams()
        let run = try AutomationRunParams(workbenchID: DemoSeed.acmeID, confirmed: true).wireParams()
        let cases: [(ActionKind, String?, [String: JSONValue], String)] = [
            (.askAnswer, "owner_ask-109", pick, "Answer “Which menu wording?” — Archive Now"),
            (.askAnswer, "owner_ask-110", approve, "Answer “Review the ask guard plan” — Approved"),
            (.askAnswer, "owner_ask-999", pick, "Answer an ask — Archive Now"),
            (.boardTargetStatus, "workbench_target-416", done, "Move “Undo Archive Now” to Done"),
            (.boardTargetStatus, "workbench_target-999", done, "Move a task to Done"),
            (.boardCommentAdd, "workbench_target-415", comment, "Comment on “Archive Closed Targets Now”"),
            (.boardCommentReply, "workbench_comment-82", comment, "Comment on “Lane totals”"),
            (.boardTargetCreate, nil, create, "New task “Write the release notes”"),
            (.sessionStart, "workbench_target-415", start, "Start a session for “Archive Closed Targets Now”"),
            (.sessionInput, "terminal_session-10", input, "Send “\(String(long.prefix(60)))…”"),
            (.sessionStop, "terminal_session-10", [:], "Stop “Session report”"),
            (.sessionFinishRequest, "terminal_session-10", [:], "Finish “Session report”"),
            (.sessionInterrupt, "terminal_session-10", [:], "Interrupt “Session report”"),
            (.sessionStop, "terminal_session-999", [:], "Stop a session"),
            (.permissionAnswer, "terminal_session-12", allow, "Allow a permission request"),
            (.permissionAnswer, "terminal_session-12", deny, "Deny a permission request"),
            (.automationRun, "automation-71", run, "Run “Release notes”"),
            (.automationRun, "automation-999", run, "Run an automation"),
            (.boardTargetPriority, "workbench_target-415", [:], "An action from this iPhone")
        ]
        for (kind, entity, params, expected) in cases {
            let row = item("a", kind, entity: entity, params: params)
            XCTAssertEqual(ActionSummary.text(for: row, snapshot: snapshot), expected, "\(kind.rawValue) \(entity ?? "-")")
        }
    }

    func testAShortInputIsQuotedWhole() throws {
        let input = try SessionInputParams(text: "Run the tests\nagain").wireParams()
        let row = item("a", .sessionInput, entity: "terminal_session-10", params: input)
        XCTAssertEqual(ActionSummary.text(for: row, snapshot: try demoSnapshot(now: now)), "Send “Run the tests again”")
    }

    // MARK: - The list

    func testTheTitleAndTheFooterNameTheMac() throws {
        XCTAssertEqual(NotDeliveredModel.title, "Not delivered")
        XCTAssertEqual(
            try model([]).footer,
            "These actions never reached Acme Mac. Retry sends them again, after anything you did since.")
    }

    func testRowsAreOldestFirstAndOnlyNotDelivered() throws {
        let model = try model([
            item("c", .sessionStop, entity: "terminal_session-10", seq: 3),
            item("a", .sessionStop, entity: "terminal_session-10", seq: 1),
            item("q", .sessionStop, entity: "terminal_session-10", seq: 4, delivery: .queued, reason: nil),
            item("b", .sessionStop, entity: "terminal_session-10", seq: 2)
        ])
        XCTAssertEqual(model.rows.map(\.id), ["a", "b", "c"])
    }

    func testTheSubLinePerReason() throws {
        let model = try model([
            item("old", .sessionStop, entity: "terminal_session-10", seq: 1, at: now.addingTimeInterval(-26 * 3_600), reason: .noAnswer),
            item("new", .sessionStop, entity: "terminal_session-10", seq: 2, at: now.addingTimeInterval(-2 * 3_600), reason: .refused)
        ])
        let withdrawn = try XCTUnwrap(model.rows.first)
        XCTAssertEqual(withdrawn.detail, "Yesterday 10:00 · No answer from Acme Mac for 24 hours")
        let refused = try XCTUnwrap(model.rows.last)
        XCTAssertEqual(refused.detail, "Today 10:00", "a refused row shows its time only")
    }

    func testTheDismissAllConfirmationCountsTheActions() throws {
        let two = try model([
            item("a", .sessionStop, entity: "terminal_session-10", seq: 1),
            item("b", .sessionStop, entity: "terminal_session-10", seq: 2)
        ])
        XCTAssertEqual(NotDeliveredModel.dismissAllTitle, "Dismiss All")
        XCTAssertEqual(two.confirmTitle, "Dismiss 2 actions? They won't be sent.")
        let one = try model([item("a", .sessionStop, entity: "terminal_session-10")])
        XCTAssertEqual(one.confirmTitle, "Dismiss 1 action? It won't be sent.")
    }

    func testRetryIsDisabledAndItsErrorShownOnItsOwnRowOnly() throws {
        let model = try model(
            [
                item("a", .sessionStop, entity: "terminal_session-10", seq: 1),
                item("b", .sessionStop, entity: "terminal_session-10", seq: 2)
            ],
            retrying: ["a"], errors: ["a": NotDeliveredModel.lockedRetryError])
        XCTAssertEqual(model.rows.map(\.isRetrying), [true, false])
        XCTAssertEqual(model.rows.map(\.error), [NotDeliveredModel.lockedRetryError, nil])
        XCTAssertEqual(NotDeliveredModel.retryTitle, "Retry")
    }

    func testTheRetryErrors() {
        XCTAssertEqual(NotDeliveredModel.retryErrorText(KeyStoreError.locked), "Unlock your iPhone to retry.")
        XCTAssertEqual(NotDeliveredModel.retryErrorText(ActionOutboxError.notRetryable), "Couldn't retry. Try again.")
        XCTAssertEqual(NotDeliveredModel.dismissErrorText, "Couldn't dismiss. Try again.")
    }

    func testTheListIsNeverOrange() throws {
        let model = try model([item("a", .sessionStop, entity: "terminal_session-10")], errors: ["a": "x"])
        XCTAssertFalse(model.toneUses.isEmpty)
        XCTAssertTrue(model.toneUses.allSatisfy { $0.tone != .orange })
        XCTAssertTrue(model.toneUses.contains { $0.element == "dismiss all" && $0.tone == .red && $0.role == .status })
    }
}
