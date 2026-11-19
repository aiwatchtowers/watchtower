import WatchtowerInterface
import XCTest

final class InboxApprovalModelTests: XCTestCase {
    private typealias Fix = InboxFixtures
    private let noGrants = Grants(permissions: false, typing: false)

    func testApproveNeedsPermissionsOnThePhone() throws {
        let card = try Fix.approval()
        let granted = InboxApprovalModel(card: card, platform: .phone, grants: .all)
        XCTAssertTrue(granted.canApprove)
        XCTAssertNil(granted.approveNote)
        let without = InboxApprovalModel(card: card, platform: .phone, grants: noGrants)
        XCTAssertFalse(without.canApprove)
        XCTAssertEqual(without.approveNote, "Approve on the Mac")
        XCTAssertTrue(without.canReject)
        XCTAssertTrue(InboxApprovalModel(card: card, platform: .mac, grants: noGrants).canApprove)

        let draft = InboxApprovalModel(card: try Fix.approval { $0.tool = "save_automation" }, platform: .phone, grants: .all)
        XCTAssertFalse(draft.canApprove)
        XCTAssertEqual(draft.approveNote, "Open Draft — on your Mac")
    }

    func testApprovePinsTheShownArgsHash() throws {
        let model = InboxApprovalModel(card: try Fix.approval { $0.argsSHA256 = "beef" }, platform: .phone, grants: .all)
        XCTAssertEqual(model.approve(requestID: "r1"), ActRequest(
            requestID: "r1", target: "a5", verb: .approval, params: ActParams(approvalVerb: .approve, argsSHA256: "beef")
        ))
        XCTAssertEqual(model.request(.reject, requestID: "r2").params.argsSHA256, "beef")
    }

    func testEditIsMacOnly() throws {
        let card = try Fix.approval()
        let mac = InboxApprovalModel(card: card, platform: .mac, grants: .all)
        XCTAssertTrue(mac.canEdit)
        XCTAssertNil(mac.editNote)
        let phone = InboxApprovalModel(card: card, platform: .phone, grants: .all)
        XCTAssertFalse(phone.canEdit)
        XCTAssertEqual(phone.editNote, "Edit on your Mac")
        let plain = InboxApprovalModel(card: try Fix.approval { $0.editOnMac = false }, platform: .phone, grants: .all)
        XCTAssertNil(plain.editNote)
    }

    /// Retry on a failed row, never on a superseded one. Dismiss is the shared card's own rule (`AgentActionCard.settledOffer`,
    /// a session call whose outcome is unknown, mobile Inbox spec §12.2): this model has none.
    func testFailedOffersRetryButNotOnASupersededRow() throws {
        let failed = try Fix.approval {
            $0.status = "failed"
            $0.error = "the team was archived"
        }
        let model = InboxApprovalModel(card: failed, platform: .phone, grants: .all)
        XCTAssertTrue(model.canRetry)
        XCTAssertFalse(model.canApprove)
        XCTAssertFalse(InboxApprovalModel(card: failed, platform: .phone, grants: noGrants).canRetry)
        let superseded = try Fix.approval {
            $0.status = "failed"
            $0.superseded = true
        }
        XCTAssertFalse(InboxApprovalModel(card: superseded, platform: .mac, grants: .all).canRetry)
    }

    func testTargetRowFollowsTheMacMapping() throws {
        let now = try Fix.date("2026-11-16T12:00:00Z")
        func row(_ target: String, status: String = "approved", until: String = "") throws -> InboxApprovalModel.TargetRow {
            let card = try Fix.approval {
                $0.target = target
                $0.status = status
                $0.targetUntil = until
            }
            return InboxApprovalModel(card: card, platform: .mac, grants: .all, now: now).targetRow
        }
        XCTAssertEqual(try row("stuck"), .stuck)
        XCTAssertEqual(try row("failed", status: "applied"), .stuck)
        XCTAssertEqual(try row("failed", status: "failed"), .decision)
        XCTAssertEqual(try row("creating", until: "2026-11-16T12:01:00Z"), .inFlight)
        XCTAssertEqual(try row("creating", until: "2026-11-16T11:59:00Z"), .stuck)
        XCTAssertEqual(try row("waiting", status: "pending"), .decision)
        XCTAssertEqual(try row(""), .decision)
    }
}
