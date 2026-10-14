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

    // MARK: - Review round 1: the closed code, the grace sweep and a new code

    /// A sheet close retires its code: a hello under it during the grace is refused `not_confirmed` (the phone reads
    /// it in DataZone, still a participant), never kept waiting for the owner.
    func testALateHelloAfterASheetCloseIsRefusedNotConfirmed() async throws {
        center = try makeCenter(answerGrace: MobileLinkCenter.answerGrace)
        let code = try await center.issueCode()
        shares.join("_colleague-b")
        await center.closeLink(reason: .sheetClosed)

        try await handle(try hello(identityB, nonce: code.nonce, scope: .shared, user: "_colleague-b", creator: "_colleague-b"))

        XCTAssertTrue(center.pendingLinks.isEmpty, "no request waits under a closed code")
        XCTAssertTrue(try sidecar.pendingDevices().isEmpty)
        let keybox = try await openedKeybox(identityB)
        XCTAssertEqual(keybox.grant.linkRefused, .notConfirmed)
        XCTAssertEqual(shares.participantNames(in: .data), ["_colleague-b"], "the grace still runs")
    }

    /// An expiry close (the sheet's own timer may close in the code's last second) retires the code too: the late
    /// hello reads `expired_code`.
    func testALateHelloAfterAnExpiryCloseIsRefusedExpired() async throws {
        center = try makeCenter(answerGrace: MobileLinkCenter.answerGrace)
        let code = try await center.issueCode()
        shares.join("_colleague-b")
        await center.closeLink(reason: .expired)

        try await handle(try hello(identityB, nonce: code.nonce, scope: .shared, user: "_colleague-b", creator: "_colleague-b"))

        XCTAssertTrue(center.pendingLinks.isEmpty)
        XCTAssertTrue(try sidecar.pendingDevices().isEmpty)
        let keybox = try await openedKeybox(identityB)
        XCTAssertEqual(keybox.grant.linkRefused, .expiredCode)
    }

    /// A new code cancels the grace sweep still waiting: the new public link stays open and its phone is kept.
    func testANewCodeCancelsAPendingGraceSweep() async throws {
        center = try makeCenter(answerGrace: MobileLinkCenter.answerGrace)
        _ = try await center.issueCode()
        await center.closeLink(reason: .sheetClosed)
        let grace = try XCTUnwrap(center.sweepRetry, "the grace sweep waits")

        _ = try await center.issueCode()
        shares.join("_colleague-c")
        await grace.value

        XCTAssertTrue(grace.isCancelled)
        XCTAssertTrue(shares.isLinkOpen)
        XCTAssertEqual(shares.participantNames(in: .relay), ["_colleague-c"])
    }

    /// A deferred sweep that fires while a code is being issued (after the new link's mark, before the code is
    /// stored) stands down: it neither closes the new link nor sweeps a phone on it.
    func testAGraceSweepFiringMidIssueStandsDown() async throws {
        let opening = SaveGate()
        _ = try await center.issueCode()
        await center.closeLink(reason: .sheetClosed)
        await settleSweep()
        shares.gate("setPublicLink", on: opening)
        let issue = Task { try await center.issueCode() }
        await fulfillment(of: [opening.arrived], timeout: 5)
        shares.join("_colleague-c")

        // A close lands while the issue opens the link: its (zero) grace sweep fires at once.
        await center.closeLink(reason: .sheetClosed)
        await settleSweep()
        opening.release()
        _ = try await issue.value

        XCTAssertTrue(shares.isLinkOpen)
        XCTAssertEqual(shares.participantNames(in: .relay), ["_colleague-c"], "not swept mid-issue")
        XCTAssertEqual(try sidecar.metaValue(forKey: MobileLinkCenter.sweepPendingKey), "1", "the new code's close sweeps")
    }

    /// A failed public-link close of an answering close is retried on its own short schedule, well within the
    /// grace; the participants stay for the grace.
    func testAFailedLinkCloseIsRetriedBeforeTheGraceEnds() async throws {
        let waits = WaitLog()
        center = try makeCenter(sleep: { duration in
            waits.append(duration)
            // The link close's retries return at once; the grace parks.
            if !MobileLinkCenter.linkCloseRetryDelays.contains(duration) { try? await Task.sleep(for: .seconds(3600)) }
        }, answerGrace: MobileLinkCenter.answerGrace)
        _ = try await center.issueCode()
        shares.join("_colleague-b")
        shares.failNext("setPublicLink", times: 1)

        await center.closeLink(reason: .sheetClosed)
        XCTAssertTrue(shares.isLinkOpen, "the first close failed")
        await center.linkCloseRetry?.value

        XCTAssertFalse(shares.isLinkOpen)
        XCTAssertTrue(waits.all.contains(MobileLinkCenter.linkCloseRetryDelays[0]))
        XCTAssertEqual(shares.participantNames(in: .data), ["_colleague-b"], "the sweep still waits for the grace")
    }
}
