import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerSync
import WatchtowerTestSupport

/// `MobileSync = workbench_only` (#608, Q4): a kind outside the workbench
/// kinds is published empty, so the phone deletes its records — never just
/// skipped.
final class SlicePublisherPolicyTests: XCTestCase {
    private var dbPath: String!
    private var dbPool: DatabasePool!
    private var state: HubSyncState!
    private var transport: StubHubTransport!

    override func setUpWithError() throws {
        (dbPool, dbPath) = try TestDatabase.createPool()
        state = try HubSyncState.inMemory()
        transport = StubHubTransport()
    }

    override func tearDownWithError() throws {
        transport = nil
        state = nil
        dbPool = nil
        TestDatabase.cleanup(path: dbPath)
    }

    func testWorkbenchOnlyEmptiesOtherKinds() async throws {
        let briefing = StubSliceSource(kind: .briefing)
        briefing.setPayload(Data(#"{"summary":"acme"}"#.utf8))
        let workbench = StubSliceSource(kind: .workbench)
        workbench.setPayload(Data(#"{"name":"acme"}"#.utf8))
        let policy = MobileSyncPolicyBox()
        let publisher = SlicePublisher(
            dbPool: dbPool, state: state, transport: transport.sealing(names: state), sources: [briefing, workbench],
            allowedKinds: { policy.allowedKinds } // swiftlint:disable:this trailing_closure
        )
        let first = try await publisher.publishOnce()
        XCTAssertEqual(first.pushed, 2)

        policy.store("workbench_only")
        let readsBefore = briefing.reads
        let second = try await publisher.publishOnce()
        XCTAssertEqual(second.deleted, 1, "the briefing record is deleted from the phone")
        XCTAssertTrue(try state.hashes(forKind: .briefing).isEmpty)
        XCTAssertEqual(try state.hashes(forKind: .workbench).count, 1, "the workbench record stays")
        XCTAssertEqual(briefing.reads, readsBefore, "a kind outside the mode is not even read")

        policy.store("allowed")
        let third = try await publisher.publishOnce()
        XCTAssertEqual(third.pushed, 1, "allowed again: the briefing comes back")
    }

    func testWorkbenchOnlyKeepsTheWorkbenchKindsAndNoPersonalData() {
        XCTAssertTrue(SliceKind.workbenchOnly.isSuperset(of: [.workbench, .ownerAsk, .sessionChat, .permissionRequest, .deviceGrant]))
        let personal: Set<SliceKind> = [
            .briefing, .inboxItem, .digest, .personCard, .calendarEvent, .meetingTranscript, .dayPlan, .target, .track, .recordingJob
        ]
        XCTAssertTrue(SliceKind.workbenchOnly.isDisjoint(with: personal))
    }

    func testRecordingCommandRefusedUnderWorkbenchOnly() {
        let policy = MobileSyncPolicyBox()
        XCTAssertNoThrow(try policy.checkRecordingAllowed())
        policy.store("workbench_only")
        XCTAssertThrowsError(try policy.checkRecordingAllowed()) { error in
            XCTAssertTrue(error.localizedDescription.hasPrefix("blocked by your organization's policy"))
        }
        XCTAssertNil(MobileSyncPolicyBox().allowedKinds)
    }
}
