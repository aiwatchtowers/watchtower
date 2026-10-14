import Foundation
@testable import WatchtowerDesktop
import WatchtowerSync
import XCTest

/// Shared-scope link tails (#69): a phone that joined the shares but was late with its hello reads its refusal
/// before the sweep removes it, and a hello another participant wrote into a phone's record is not trusted.
extension MobileLinkCenterTests {
    /// The second phone accepted the public link, but its hello arrives after the first phone linked: the public
    /// link is closed at once, the second phone stays a participant through the grace, reads `used_code`, and is
    /// swept when the grace ends; the linked phone stays.
    func testALatePhoneReadsUsedCodeBeforeTheSweepRemovesIt() async throws {
        let grace = SaveGate()
        // A fresh sidecar: the setUp center's keyring sealed this one's epoch key.
        sidecar = try HubSyncState.inMemory()
        center = try makeCenter(sleep: { duration in
            if duration == MobileLinkCenter.answerGrace { return await grace.park() }
            try? await Task.sleep(for: .seconds(3600))
        }, answerGrace: MobileLinkCenter.answerGrace)
        let code = try await center.issueCode()
        shares.join("_colleague-a")
        shares.join("_colleague-b")
        try await link(try hello(identityA, nonce: code.nonce, scope: .shared, user: "_colleague-a", creator: "_colleague-a"))
        await fulfillment(of: [grace.arrived], timeout: 5)

        XCTAssertFalse(shares.isLinkOpen, "no one new joins after the use")
        XCTAssertEqual(shares.participantNames(in: .data), ["_colleague-a", "_colleague-b"], "the late phone can still read")
        XCTAssertTrue(center.relayIsUrgent, "the late hello is read at the active cadence")

        try await handle(try hello(identityB, nonce: code.nonce, scope: .shared, user: "_colleague-b", creator: "_colleague-b"))
        let keybox = try await openedKeybox(identityB)
        XCTAssertEqual(keybox.grant.linkRefused, .usedCode)
        XCTAssertNil(keybox.keys)

        grace.release()
        await settleSweep()
        for zone in [CloudZoneID.data, .relay] {
            XCTAssertEqual(shares.participantNames(in: zone), ["_colleague-a"], zone.rawValue)
        }
        XCTAssertEqual(try sidecar.metaValue(forKey: MobileLinkCenter.sweepPendingKey), "0")
        clock.advance(TimeInterval(MobileLinkCenter.answerGrace.components.seconds))
        XCTAssertFalse(center.relayIsUrgent, "the grace is over")
    }

    /// A close that answers no phone (an earlier run's link) sweeps at once, with no grace.
    func testARestartCloseSweepsWithoutTheGrace() async throws {
        center = try makeCenter(answerGrace: MobileLinkCenter.answerGrace)
        _ = try await center.issueCode()
        shares.join("_stranger")
        let next = try makeCenter(answerGrace: MobileLinkCenter.answerGrace)

        await next.closeLink(reason: .restart)

        XCTAssertFalse(shares.isLinkOpen)
        XCTAssertTrue(shares.participantNames(in: .relay).isEmpty)
        XCTAssertNil(next.sweepRetry)
        XCTAssertFalse(next.relayIsUrgent)
    }

    /// A participant cannot pass its own hello off as another phone's by writing into that phone's record (the
    /// record keeps its first creator): the record name must be the hash of the hello's signing key (D7), so phone
    /// B's keys under phone A's record name, with A's user as creator and in the payload, are dropped unanswered.
    func testAHelloAnotherParticipantWroteIntoAPhonesRecordIsDropped() async throws {
        let code = try await center.issueCode()
        shares.join("_colleague-a")
        shares.join("_colleague-b")
        nudges = []

        try await handle(try hello(
            identityB, nonce: code.nonce, scope: .shared, user: "_colleague-a", creator: "_colleague-a", deviceID: phoneA))

        XCTAssertTrue(center.pendingLinks.isEmpty)
        XCTAssertTrue(try grants().isEmpty, "no grant, not even a refusal")
        XCTAssertTrue(nudges.isEmpty)
    }
}
