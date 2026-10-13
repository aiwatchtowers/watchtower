import CloudKit
import Foundation
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The phone's link flow (mobile POC spec §2.3 steps 1–6, §9): a fake
/// container (iCloud identity, share accept), a fake host (transports per
/// database, a scripted Mac, the wipe), a fake clock and the real LinkStore.
@MainActor
final class LinkingViewModelTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let identity = DeviceIdentity(deviceID: "device-acme-1", name: "Colleague A's iPhone", model: "iPhone", appVersion: "1.0")
    private let owner = "_owner-acme"
    private let dataShare = "https://www.icloud.com/share/acme-data"
    private let relayShare = "https://www.icloud.com/share/acme-relay"

    private var log: LinkEventLog!
    private var container: FakeLinkContainer!
    private var host: FakeLinkHost!
    private var clock: FakeLinkClock!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        log = LinkEventLog()
        container = FakeLinkContainer(log: log)
        container.userRecordNameValue = owner
        host = FakeLinkHost(log: log)
        clock = FakeLinkClock(now: start)
        defaults = try makeDefaults()
    }

    private func makeModel() -> LinkingViewModel {
        let model = LinkingViewModel(container: container, store: LinkStore(defaults: defaults), identity: identity, clock: clock)
        model.host = host
        return model
    }

    /// A code issued `issuedAgo` seconds before the fake clock's now.
    private func code(
        hubID: String = "hub-acme",
        macName: String = "Acme Mac",
        issuedAgo: TimeInterval = 10,
        shares: Bool = true,
        version: Int = LinkPayload.currentVersion
    ) -> LinkPayload {
        let iat = Int64(clock.now().timeIntervalSince1970 - issuedAgo)
        return LinkPayload(
            v: version,
            hubID: hubID,
            macName: macName,
            ownerUser: owner,
            nonce: LinkPayload.makeNonce(),
            iat: iat,
            exp: iat + LinkPayload.lifetime,
            dataShare: shares ? dataShare : nil,
            relayShare: shares ? relayShare : nil
        )
    }

    private func grant(hubID: String = "hub-acme", linked: Bool, refused: LinkRefusal? = nil) -> DeviceGrant {
        grantMaker(hubID, linked, refused)
    }

    /// `grant` as a value, for the scripted Mac's closures.
    private var grantMaker: (_ hubID: String, _ linked: Bool, _ refused: LinkRefusal?) -> DeviceGrant {
        let identity = identity
        let start = start
        return { hubID, linked, refused in
            DeviceGrant(
                deviceID: identity.deviceID,
                hubID: hubID,
                name: identity.name,
                scope: .private,
                linked: linked,
                linkRefused: refused,
                linkedAt: linked ? start : nil,
                typingAllowed: false,
                startSessionsAllowed: true,
                decidedAt: start
            )
        }
    }

    /// The Mac links any device record carrying `nonce` (the hub's valid-code
    /// path), for its hub id.
    private func macLinks(_ payload: LinkPayload) {
        let hubID = payload.hubID
        host.mac = { [grant = grantMaker] writes in
            writes.contains { $0.linkNonce == payload.nonce } ? grant(hubID, true, nil) : nil
        }
    }

    private func linkedModel(_ payload: LinkPayload) async throws -> LinkingViewModel {
        macLinks(payload)
        let model = makeModel()
        await model.open(payload.url())
        XCTAssertEqual(model.phase, .linked(macName: payload.macName))
        await model.finish()
        XCTAssertTrue(model.hasLinks)
        return model
    }

    // MARK: - Scope

    /// Same Apple ID: the code's share URLs are ignored, since an owner
    /// cannot accept their own share.
    func testSameAppleIDWithShareURLsLinksPrivateWithoutAccepting() async throws {
        let payload = code(shares: true)
        macLinks(payload)
        let model = makeModel()

        await model.open(payload.url())

        XCTAssertTrue(container.accepted.isEmpty, "an owner's phone never accepts its own share")
        XCTAssertEqual(host.prepared, [.private])
        XCTAssertEqual(host.preparedHubIDs, ["hub-acme"], "the scan syncs the code's hub")
        let writes = try await host.deviceWrites(in: .private)
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.linkNonce, payload.nonce)
        XCTAssertEqual(writes.first?.scope, .private)
        XCTAssertEqual(writes.first?.userRecordName, owner)
        XCTAssertEqual(model.phase, .linked(macName: "Acme Mac"))
        XCTAssertEqual(model.links.first?.link.databaseScope, .private)
        XCTAssertEqual(host.linkedCalls.last?.device.scope, .private)
    }

    /// Another Apple ID: both shares accepted, then the shared database,
    /// then the device record written there.
    func testDifferentAppleIDAcceptsBothSharesThenWritesToSharedDatabase() async throws {
        container.userRecordNameValue = "_colleague-a"
        let payload = code(shares: true)
        macLinks(payload)
        let model = makeModel()

        await model.open(payload.url())

        XCTAssertEqual(container.accepted, [[try XCTUnwrap(URL(string: dataShare)), try XCTUnwrap(URL(string: relayShare))]])
        XCTAssertEqual(log.events, ["accept 2", "prepare shared(\(owner))"])
        XCTAssertEqual(host.prepared, [.shared(ownerName: owner)])
        let shared = try await host.deviceWrites(in: .shared(ownerName: owner))
        XCTAssertEqual(shared.count, 1, "the device record goes to the shared database")
        XCTAssertEqual(shared.first?.scope, .shared)
        XCTAssertEqual(shared.first?.userRecordName, "_colleague-a")
        let privateWrites = try await host.deviceWrites(in: .private)
        XCTAssertTrue(privateWrites.isEmpty)
        XCTAssertEqual(model.links.first?.link.databaseScope, .shared(ownerName: owner))
        XCTAssertEqual(model.links.first?.link.dataShareURL, dataShare)
        XCTAssertEqual(model.links.first?.link.relayShareURL, relayShare)
    }

    func testDifferentAppleIDWithoutShareURLsCannotShare() async throws {
        container.userRecordNameValue = "_colleague-a"
        let model = makeModel()

        await model.open(code(shares: false).url())

        XCTAssertEqual(model.phase, .failed(.cannotShare))
        XCTAssertEqual(
            LinkFailure.cannotShare.message,
            "This Mac can't share with another Apple ID right now — Show a new code on the Mac"
        )
        XCTAssertTrue(container.accepted.isEmpty)
        XCTAssertTrue(host.prepared.isEmpty, "nothing is written")
    }

    func testDifferentAppleIDWithAFailingAcceptCannotShare() async throws {
        container.userRecordNameValue = "_colleague-a"
        container.acceptError = URLError(.badServerResponse)
        let model = makeModel()

        await model.open(code().url())

        XCTAssertEqual(model.phase, .failed(.cannotShare))
        XCTAssertTrue(host.prepared.isEmpty, "nothing is written")
        XCTAssertNil(LinkStore(defaults: defaults).pending)
    }

    // MARK: - Expiry

    /// The local check keeps a 120 s grace for the phone's clock.
    func testCodeExpiredOneSecondAgoStillProceeds() async throws {
        let payload = code(issuedAgo: Double(LinkPayload.lifetime) + 1)
        macLinks(payload)
        let model = makeModel()

        await model.open(payload.url())

        let writes = try await host.deviceWrites()
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(model.phase, .linked(macName: "Acme Mac"))
    }

    func testCodeExpired121SecondsAgoShowsExpiredAndWritesNothing() async throws {
        let model = makeModel()

        await model.open(code(issuedAgo: Double(LinkPayload.lifetime) + 121).url())

        XCTAssertEqual(model.phase, .failed(.expired))
        XCTAssertEqual(LinkFailure.expired.message, "This code expired — Show a new code on the Mac")
        XCTAssertTrue(host.prepared.isEmpty)
        let writes = try await host.deviceWrites()
        XCTAssertTrue(writes.isEmpty)
    }

    /// Review focus 1: the phone's clock runs 5 min ahead and the Mac issued
    /// the code 1 min ago. The phone proceeds and the Mac's grant decides.
    func testPhoneClockFiveMinutesAheadProceedsAndTheMacDecides() async throws {
        let macNow = start
        let iat = Int64(macNow.timeIntervalSince1970 - 60)
        clock = FakeLinkClock(now: macNow.addingTimeInterval(300))
        let payload = LinkPayload(
            hubID: "hub-acme", macName: "Acme Mac", ownerUser: owner, nonce: LinkPayload.makeNonce(),
            iat: iat, exp: iat + LinkPayload.lifetime
        )
        // The Mac checks expiry on its own clock: still valid there.
        host.mac = { [grant = grantMaker] writes in
            guard writes.contains(where: { $0.linkNonce == payload.nonce }) else { return nil }
            let valid = payload.exp >= Int64(macNow.timeIntervalSince1970)
            return valid ? grant("hub-acme", true, nil) : grant("hub-acme", false, .expiredCode)
        }
        let model = makeModel()

        await model.open(payload.url())

        let writes = try await host.deviceWrites()
        XCTAssertEqual(writes.count, 1, "the skewed phone clock must not refuse a valid code")
        XCTAssertEqual(model.phase, .linked(macName: "Acme Mac"))
    }

    // MARK: - iCloud

    func testPhoneNotSignedIntoICloudShowsTheSignInMessage() async throws {
        container.status = .noAccount
        let model = makeModel()

        await model.open(code().url())

        XCTAssertEqual(model.phase, .failed(.signIn))
        XCTAssertEqual(LinkFailure.signIn.message, "Sign in to iCloud on this iPhone to use Watchtower")
        XCTAssertTrue(host.prepared.isEmpty)
    }

    // MARK: - Grant wait

    func testNoGrantWithinSixtySecondsShowsDidNotAnswer() async throws {
        let model = makeModel()

        await model.open(code().url())

        XCTAssertEqual(model.phase, .failed(.noAnswer))
        XCTAssertEqual(
            LinkFailure.noAnswer.message,
            "Your Mac didn't answer — Keep Settings → Mobile open on the Mac and scan again",
            "title — hint (design pass O3)"
        )
        XCTAssertGreaterThanOrEqual(clock.slept, 60)
        XCTAssertLessThan(clock.slept, 62, "the wait ends at 60 s")
        XCTAssertTrue(model.links.isEmpty)
        XCTAssertTrue(host.linkedCalls.isEmpty, "never shown as linked")
        XCTAssertNil(LinkStore(defaults: defaults).pending, "a finished wait leaves nothing to resume")
    }

    func testRefusedUsedCodeShowsCannotBeUsed() async throws {
        let payload = code()
        host.mac = { [grant = grantMaker] writes in
            writes.isEmpty ? nil : grant("hub-acme", false, .usedCode)
        }
        let model = makeModel()

        await model.open(payload.url())

        XCTAssertEqual(model.phase, .failed(.refused))
        XCTAssertEqual(LinkFailure.refused.message, "This code can't be used — Show a new code on the Mac")
        XCTAssertTrue(model.links.isEmpty)
        XCTAssertTrue(host.linkedCalls.isEmpty)
    }

    /// A refusal still in the replica from an earlier scan is not this
    /// scan's answer: the flow waits for the Mac's new one.
    func testAnEarlierRefusalInTheReplicaIsNotThisScansAnswer() async throws {
        let payload = code()
        // The Mac answers 4 s after the write; until then the replica still
        // holds its refusal of an earlier code.
        let answerAt = start.addingTimeInterval(4)
        host.mac = { [grant = grantMaker, clock] writes in
            guard writes.contains(where: { $0.linkNonce == payload.nonce }), let clock, clock.now() >= answerAt else {
                return grant("hub-acme", false, .expiredCode)
            }
            return grant("hub-acme", true, nil)
        }
        let model = makeModel()

        await model.open(payload.url())

        XCTAssertEqual(model.phase, .linked(macName: "Acme Mac"))
        XCTAssertGreaterThanOrEqual(clock.slept, 4, "it waited for the new answer")
    }

    func testAGrantForAnotherHubIsNotTheAnswer() async throws {
        let payload = code()
        host.mac = { [grant = grantMaker] writes in
            writes.isEmpty ? nil : grant("hub-other", true, nil)
        }
        let model = makeModel()

        await model.open(payload.url())

        XCTAssertEqual(model.phase, .failed(.noAnswer))
    }

    // MARK: - Linked

    /// Step 6: "Linked to <Mac name>", then the notification prompt, then Now.
    func testFinishAsksForNotificationsAndOpensNow() async throws {
        let model = try await linkedModel(code())

        XCTAssertEqual(host.permissionRequests, 1)
        XCTAssertEqual(host.openedNow, 1)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(host.linkedCalls.last?.device.deviceID, identity.deviceID)
        XCTAssertEqual(host.activeHubID, "hub-acme", "the new Mac is on screen")
        XCTAssertEqual(host.rows.map(\.hubID), ["hub-acme"], "the link is saved")
    }

    func testScanningTheSameCodeTwiceStaysLinkedWithoutASecondWrite() async throws {
        let payload = code()
        let model = try await linkedModel(payload)

        await model.open(payload.url())

        XCTAssertEqual(model.phase, .linked(macName: "Acme Mac"))
        XCTAssertEqual(model.links.map(\.hubID), ["hub-acme"])
        let writes = try await host.deviceWrites()
        XCTAssertEqual(writes.count, 1, "no second device-record write")
        XCTAssertTrue(host.removals.isEmpty)
        XCTAssertEqual(host.linkedCalls.count, 1, "never unlinked meanwhile, linked once")
    }

    // MARK: - Killed mid-link (review focus 2)

    /// Killed after the accept and before the grant: the relaunch resumes the
    /// wait for what is left of the 60 s, then offers to scan again. Never
    /// shown as linked.
    func testKilledMidLinkResumesTheRemainingWaitThenOffersToScanAgain() async throws {
        container.userRecordNameValue = "_colleague-a"
        clock.parked = true
        let first = makeModel()
        let payload = code()
        let flow = Task { await first.open(payload.url()) }
        try await poll { first.phase == .waiting(macName: "Acme Mac") }
        flow.cancel()
        await flow.value
        XCTAssertEqual(container.accepted.count, 1, "killed after the accept")
        let pending = try XCTUnwrap(LinkStore(defaults: defaults).pending, "the wait survives a kill")
        XCTAssertEqual(pending.deadline, start.addingTimeInterval(60))

        // Relaunch 20 s later: 40 s of the wait are left.
        clock.parked = false
        clock.advance(by: 20)
        let relaunched = makeModel()
        XCTAssertTrue(relaunched.links.isEmpty, "a pending link is not a link")

        await relaunched.resumePendingLink()

        XCTAssertEqual(host.prepared.last, .shared(ownerName: owner), "the wait reads the scan's database")
        XCTAssertEqual(host.preparedHubIDs.last, "hub-acme", "and the scan's hub")
        XCTAssertEqual(relaunched.phase, .failed(.noAnswer))
        XCTAssertGreaterThanOrEqual(clock.slept, 40)
        XCTAssertLessThan(clock.slept, 42, "only the remaining part of the 60 s")
        XCTAssertTrue(host.linkedCalls.isEmpty, "never shown as linked")
        XCTAssertTrue(relaunched.links.isEmpty)
        XCTAssertNil(LinkStore(defaults: defaults).pending)
        XCTAssertEqual(container.accepted.count, 1, "the relaunch does not accept again")
    }

    /// Killed right after the accept, while the sync stack restarts on the
    /// shared database: the relaunch still resumes there, and the wait ends
    /// with a new scan, never linked.
    func testKilledBeforeTheDeviceWriteResumesInTheScansDatabase() async throws {
        container.userRecordNameValue = "_colleague-a"
        host.parksPrepare = true
        let first = makeModel()
        let flow = Task { await first.open(code().url()) }
        try await poll { !host.prepared.isEmpty }
        flow.cancel()
        await flow.value
        XCTAssertEqual(container.accepted.count, 1)
        let pending = try XCTUnwrap(LinkStore(defaults: defaults).pending, "the accept is followed by a resumable wait")
        XCTAssertEqual(pending.link.databaseScope, .shared(ownerName: owner))
        XCTAssertEqual(pending.link.hubID, "hub-acme", "the relaunch resumes the scan's hub")

        XCTAssertFalse(pending.baselineCaptured, "nothing is written before the baseline")

        host.parksPrepare = false
        let preparedBefore = host.prepared.count
        let relaunched = makeModel()
        await relaunched.resumePendingLink()

        XCTAssertEqual(relaunched.phase, .failed(.noAnswer), "nothing reached the Mac: scan again at once")
        XCTAssertEqual(host.prepared.count, preparedBefore, "no wait to resume")
        XCTAssertEqual(clock.slept, 0)
        XCTAssertTrue(host.linkedCalls.isEmpty, "never shown as linked")
        XCTAssertNil(LinkStore(defaults: defaults).pending)
    }

    /// Board #70: killed before the baseline was saved, a relaunch must not
    /// take a refusal of an earlier code, still in the replica, as this
    /// scan's answer.
    func testAResumeWithoutACapturedBaselineIgnoresAnEarlierRefusal() async throws {
        LinkStore(defaults: defaults).pending = PendingLink(
            link: linkRecord(), deadline: start.addingTimeInterval(50), baseline: nil, baselineCaptured: false
        )
        host.mac = { [grant = grantMaker] _ in grant("hub-acme", false, .expiredCode) }
        let model = makeModel()

        await model.resumePendingLink()

        XCTAssertEqual(model.phase, .failed(.noAnswer), "not .refused: the refusal is an earlier scan's")
        XCTAssertNil(LinkStore(defaults: defaults).pending)
    }

    /// Board #70: the sync stack failing to restart is this iPhone's
    /// problem, not iCloud's.
    func testAPrepareFailureIsALocalFailureNotICloud() async throws {
        host.prepareError = CocoaError(.fileWriteNoPermission)
        let model = makeModel()

        await model.open(code().url())

        guard case .failed(.local) = model.phase else {
            return XCTFail("expected a local failure, got \(model.phase)")
        }
        XCTAssertNil(LinkStore(defaults: defaults).pending)
    }

    /// A pending link an older build saved has no `baselineCaptured`: it
    /// reads as not captured, never as unreadable.
    func testAPendingLinkSavedWithoutTheFlagReadsAsNotCaptured() throws {
        let record = linkRecord()
        let legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            PendingLink(link: record, deadline: start, baseline: nil, baselineCaptured: true)
        )) as? [String: Any]
        var object = try XCTUnwrap(legacy)
        object.removeValue(forKey: "baselineCaptured")
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: "link.pending")

        let pending = try XCTUnwrap(LinkStore(defaults: defaults).pending)

        XCTAssertEqual(pending.link, record)
        XCTAssertFalse(pending.baselineCaptured)
    }

    /// Fix round 1, I2: a pending link whose hub id is not a plain name
    /// (an older build saved it unchecked) is dropped at the relaunch:
    /// nothing is prepared or removed (no path is made from it), the code
    /// reads as unusable.
    func testAPendingLinkWithAnUnusableHubIDIsDroppedAtTheRelaunch() async throws {
        LinkStore(defaults: defaults).pending = PendingLink(
            link: linkRecord(hubID: "../hub-acme"), deadline: start.addingTimeInterval(50), baseline: nil, baselineCaptured: true
        )
        let model = makeModel()

        await model.resumePendingLink()

        XCTAssertEqual(model.phase, .failed(.refused))
        XCTAssertNil(LinkStore(defaults: defaults).pending, "the pending link is cleared")
        XCTAssertTrue(host.prepared.isEmpty)
        XCTAssertTrue(host.removals.isEmpty, "no removal of an id that names no directory")
    }

    func testRelaunchAfterTheDeadlineOffersToScanAgainAtOnce() async throws {
        let store = LinkStore(defaults: defaults)
        store.pending = PendingLink(link: linkRecord(), deadline: start.addingTimeInterval(-1), baseline: nil, baselineCaptured: true)
        let model = makeModel()

        await model.resumePendingLink()

        XCTAssertEqual(model.phase, .failed(.noAnswer))
        XCTAssertEqual(clock.slept, 0)
        XCTAssertNil(LinkStore(defaults: defaults).pending)
    }

    func testRelaunchedWaitLinksWhenTheGrantArrives() async throws {
        let record = linkRecord()
        LinkStore(defaults: defaults).pending = PendingLink(
            link: record, deadline: start.addingTimeInterval(30), baseline: nil, baselineCaptured: true
        )
        let answerAt = start.addingTimeInterval(10)
        host.mac = { [grant = grantMaker, clock] _ in
            guard let clock, clock.now() >= answerAt else { return nil }
            return grant("hub-acme", true, nil)
        }
        let model = makeModel()

        await model.resumePendingLink()

        XCTAssertEqual(model.phase, .linked(macName: "Acme Mac"))
        var saved = record
        saved.linkedAt = start
        XCTAssertEqual(model.links.first?.link, saved, "the pending link, with its grant's linked_at")
        XCTAssertNil(LinkStore(defaults: defaults).pending)
    }

    private func linkRecord(hubID: String = "hub-acme", macName: String = "Acme Mac", scope: DeviceScope = .private) -> LinkRecord {
        LinkRecord(
            hubID: hubID,
            macName: macName,
            scope: scope,
            ownerName: owner,
            userRecordName: owner,
            nonce: LinkPayload.makeNonce(),
            dataShareURL: nil,
            relayShareURL: nil
        )
    }

    // MARK: - iCloud account switch (review focus 3)

    func testICloudAccountSwitchWhileLinkedWipesAndShowsWelcome() async throws {
        let model = try await linkedModel(code())

        container.userRecordNameValue = "_colleague-b"
        await model.accountChanged()

        XCTAssertEqual(host.removedHubIDs, ["hub-acme"], "the hub and its replica are removed")
        XCTAssertEqual(host.removals.map(\.keepRecordings), [false], "review F6: nothing is carried to another account")
        XCTAssertTrue(model.links.isEmpty, "Welcome is shown")
        XCTAssertFalse(model.hasLinks)
        XCTAssertTrue(host.rows.isEmpty)
        XCTAssertEqual(model.phase, .idle)
    }

    func testTheSameICloudAccountReturningKeepsTheLink() async throws {
        let model = try await linkedModel(code())

        await model.accountChanged()

        XCTAssertTrue(host.removals.isEmpty)
        XCTAssertTrue(model.hasLinks)
    }

    func testSignedOutOfICloudKeepsTheReplica() async throws {
        let model = try await linkedModel(code())

        container.status = .noAccount
        await model.accountChanged()

        XCTAssertTrue(host.removals.isEmpty, "kept until the same account returns or another one signs in")
        XCTAssertTrue(model.hasLinks)
    }

    /// Multi-hub spec §6.2: another Apple ID wipes every session and the
    /// registry; the recordings were made for the old account's Macs.
    func testAccountChangeRemovesEveryHubWithoutKeepingRecordings() async throws {
        let model = try await linkedModel(code())
        let home = code(hubID: "hub-home", macName: "Home Mac")
        macLinks(home)
        await model.open(home.url())
        await model.finish()
        XCTAssertEqual(model.links.map(\.hubID), ["hub-acme", "hub-home"])
        LinkStore(defaults: defaults).pending = PendingLink(
            link: linkRecord(hubID: "hub-studio"), deadline: start.addingTimeInterval(600), baseline: nil, baselineCaptured: false
        )
        host.notSentCount = 2

        container.userRecordNameValue = "_colleague-b"
        await model.accountChanged()

        XCTAssertEqual(Set(host.removedHubIDs), ["hub-acme", "hub-home"], "every hub goes")
        XCTAssertEqual(host.removals.map(\.keepRecordings), [false, false], "no recording is kept for another account")
        XCTAssertTrue(model.links.isEmpty, "onboarding")
        XCTAssertNil(LinkStore(defaults: defaults).pending, "a pending link of the old account goes too")
        XCTAssertEqual(model.notice, .notSent(2), "what the removals lost, summed")
        XCTAssertTrue(container.left.isEmpty, "no farewell, no share leave: the old account's zones")
        XCTAssertTrue(host.farewells.isEmpty)
    }

    // MARK: - Unlink

    func testUnlinkWritesUnlinkedWipesAndReportsNotSent() async throws {
        let model = try await linkedModel(code())
        host.notSentCount = 3

        await model.unlink("hub-acme")

        let writes = try await host.deviceWrites(in: .private)
        XCTAssertEqual(writes.last?.unlinked, true)
        XCTAssertEqual(
            Array(log.events.suffix(2)), ["remove hub-acme", "farewell private"],
            "the row goes first, then the farewell through the hub's own transport"
        )
        XCTAssertEqual(host.farewells.map(\.hubID), ["hub-acme"])
        XCTAssertEqual(host.removedHubIDs, ["hub-acme"], "one removal, no second wipe")
        XCTAssertTrue(model.links.isEmpty)
        XCTAssertTrue(host.rows.isEmpty)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.notice, .notSent(3))
        XCTAssertEqual(LinkNotice.notSent(3).message, "Not sent: 3 items were still waiting for your Mac")
        XCTAssertEqual(LinkNotice.notSent(1).message, "Not sent: 1 item was still waiting for your Mac")
        XCTAssertTrue(container.left.isEmpty, "a private link has no shares to leave")
    }

    /// Board #63: an unlink during a capture says the recording was kept,
    /// with what else was not sent.
    func testUnlinkDuringACaptureSaysTheRecordingWasKept() async throws {
        let model = try await linkedModel(code())
        host.notSentCount = 2
        host.stopsRecording = true

        await model.unlink("hub-acme")

        XCTAssertEqual(model.notice, .recordingKept(notSent: 2))
        XCTAssertEqual(
            LinkNotice.recordingKept(notSent: 2).message,
            "The link ended during a recording. It's saved on this iPhone and goes to your Mac after you link it again. "
                + "Not sent: 2 items were still waiting for your Mac"
        )
        XCTAssertEqual(
            LinkNotice.recordingKept(notSent: 0).message,
            "The link ended during a recording. It's saved on this iPhone and goes to your Mac after you link it again"
        )
        model.startScan()
        XCTAssertNil(model.notice, "read by the next scan")
    }

    /// Multi-hub spec §6.1: the Mac's removal freezes the hub and wipes
    /// nothing, so a capture is not stopped by it; an account switch removes
    /// the hub, and its stopped capture is counted, not kept.
    func testRemovedOrAnAccountSwitchDuringACaptureSaysTheRecordingWasKept() async throws {
        container.userRecordNameValue = "_colleague-a"
        let removed = try await linkedModel(code())
        host.stopsRecording = true

        await removed.removedByMac("hub-acme")

        XCTAssertEqual(removed.notice, .removed(macName: "Acme Mac"), "nothing was wiped: the hub is frozen, not removed")
        XCTAssertTrue(host.removals.isEmpty)
        host.stopsRecording = false

        let switched = try await linkedModel(code(hubID: "hub-home", macName: "Home Mac"))
        host.stopsRecording = true
        host.notSentCount = 1
        container.userRecordNameValue = "_colleague-b"

        await switched.accountChanged()

        XCTAssertTrue(switched.links.isEmpty)
        XCTAssertEqual(switched.notice, .notSent(1), "another account: the stopped capture is not kept, it is counted")
    }

    /// Review F3/F8: a recording problem of the wipe wins over every other
    /// notice, with the Not sent count.
    func testARecordingProblemOfTheWipeIsTheNotice() async throws {
        let model = try await linkedModel(code())
        host.recordingProblem = "Some recordings couldn't be read (disk full)"
        host.notSentCount = 2

        await model.unlink("hub-acme")

        XCTAssertEqual(model.notice, .recordingsProblem("Some recordings couldn't be read (disk full)", notSent: 2))
        XCTAssertEqual(
            model.notice?.message,
            "Some recordings couldn't be read (disk full). Not sent: 2 items were still waiting for your Mac"
        )
        model.startScan()
        XCTAssertNil(model.notice)
    }

    func testUnlinkInSharedScopeLeavesTheShares() async throws {
        container.userRecordNameValue = "_colleague-a"
        let model = try await linkedModel(code())

        await model.unlink("hub-acme")

        XCTAssertEqual(container.left, [owner])
        XCTAssertEqual(container.leftHubIDs, ["hub-acme"], "the linked hub's shares are left")
        XCTAssertEqual(host.farewells.map(\.hubID), ["hub-acme"], "unlinked is written to the linked hub's zones")
        XCTAssertEqual(host.removedHubIDs, ["hub-acme"], "board #70: one removal empties the queue")
        let writes = try await host.deviceWrites(in: .shared(ownerName: owner))
        XCTAssertEqual(writes.last?.unlinked, true)
        XCTAssertEqual(host.farewells.count, 1)
        XCTAssertNil(model.notice, "nothing was waiting")
    }

    /// Multi-hub F2: the hub's row goes first, then the farewell through
    /// the hub's own transport (inside the removal), then the shares; no
    /// second wipe follows.
    func testUnlinkRemovesFirstThenSendsTheFarewellThenLeavesShares() async throws {
        container.userRecordNameValue = "_colleague-a"
        let model = try await linkedModel(code())

        await model.unlink("hub-acme")

        XCTAssertEqual(
            Array(log.events.suffix(3)),
            ["remove hub-acme", "farewell shared(\(owner))", "leave \(owner)"],
            "remove, write unlinked in the shared database, leave"
        )
        XCTAssertEqual(host.farewells.first?.scope, .shared(ownerName: owner))
        XCTAssertEqual(host.removals.map(\.keepRecordings), [true], "an unlink holds the hub's recordings")
    }

    /// Shares that could not be left: the hub is gone all the same (its
    /// files and its row), and the phone does nothing more for it.
    func testUnlinkInSharedScopeWhoseSharesStayStillRemovesTheHub() async throws {
        container.userRecordNameValue = "_colleague-a"
        let model = try await linkedModel(code())
        container.leaveError = CKError(.networkUnavailable)

        await model.unlink("hub-acme")

        XCTAssertEqual(host.removedHubIDs, ["hub-acme"])
        XCTAssertEqual(Array(log.events.suffix(2)), ["farewell shared(\(owner))", "leave \(owner)"])
        XCTAssertTrue(model.links.isEmpty)
        XCTAssertEqual(model.phase, .idle)
    }

    /// Leaving the shares makes the Mac's zones vanish: the transport's
    /// `unlinked` arriving meanwhile is the unlink's own, not a removal.
    func testRemovedArrivingDuringAnUnlinkIsIgnored() async throws {
        container.userRecordNameValue = "_colleague-a"
        let model = try await linkedModel(code())
        container.onLeave = { await model.removedByMac("hub-acme") }

        await model.unlink("hub-acme")

        XCTAssertEqual(host.removedHubIDs, ["hub-acme"], "only the unlink's own removal")
        XCTAssertTrue(host.markedRemoved.isEmpty, "not frozen: it is gone")
        XCTAssertNil(model.notice, "the owner unlinked; the Mac did not remove the phone")
        XCTAssertTrue(model.links.isEmpty)
        XCTAssertEqual(model.phase, .idle)
    }

    func testAnAccountChangeArrivingDuringAnUnlinkIsIgnored() async throws {
        container.userRecordNameValue = "_colleague-a"
        let model = try await linkedModel(code())
        container.onLeave = { [container] in
            container?.userRecordNameValue = "_colleague-b"
            await model.accountChanged()
        }

        await model.unlink("hub-acme")

        XCTAssertEqual(host.removedHubIDs, ["hub-acme"], "only the unlink's own removal")
        XCTAssertEqual(host.removals.map(\.keepRecordings), [true], "one teardown")
        XCTAssertEqual(model.phase, .idle)
    }

    /// Forget on a hub the Mac removed: its files and row go, with no
    /// farewell and no share leave (its zones are gone).
    func testForgettingAFrozenHubRemovesItWithoutAFarewell() async throws {
        container.userRecordNameValue = "_colleague-a"
        let model = try await linkedModel(code())
        await model.removedByMac("hub-acme")

        await model.forget("hub-acme")

        XCTAssertEqual(host.removals.map(\.hubID), ["hub-acme"])
        XCTAssertEqual(host.removals.map(\.keepRecordings), [true])
        XCTAssertTrue(host.farewells.isEmpty)
        XCTAssertTrue(container.left.isEmpty)
        XCTAssertTrue(model.links.isEmpty)
    }

    /// Forget on a long-offline linked hub is an unlink.
    func testForgettingALinkedHubIsAnUnlink() async throws {
        let model = try await linkedModel(code())

        await model.forget("hub-acme")

        XCTAssertEqual(Array(log.events.suffix(2)), ["remove hub-acme", "farewell private"])
        XCTAssertTrue(model.links.isEmpty)
    }

    // MARK: - Several Macs (multi-hub spec §5.7)

    func testLinkingASecondMacAddsItAndMakesItActive() async throws {
        let model = try await linkedModel(code())
        let home = code(hubID: "hub-home", macName: "Home Mac")
        macLinks(home)

        await model.open(home.url())

        XCTAssertEqual(model.phase, .linked(macName: "Home Mac"), "no switch prompt")
        XCTAssertEqual(model.links.map(\.hubID), ["hub-acme", "hub-home"])
        XCTAssertEqual(host.linkedCalls.map(\.record.hubID), ["hub-acme", "hub-home"])
        XCTAssertEqual(host.activeHubID, "hub-home", "the new Mac becomes active")
        XCTAssertTrue(host.removals.isEmpty, "the first Mac stays linked")
        XCTAssertEqual(model.linkedDevice(for: "hub-acme")?.deviceID, identity.deviceID)
        XCTAssertEqual(model.linkedDevice(for: "hub-home")?.deviceID, identity.deviceID)
        XCTAssertNil(model.linkedDevice(for: "hub-studio"))
    }

    func testAFifthMacIsRefusedBeforeAnyShareIsAccepted() async throws {
        for index in 1...HubRegistry.limit {
            host.seed(linkRecord(hubID: "hub-\(index)", macName: "Mac \(index)"))
        }
        container.userRecordNameValue = "_colleague-a"
        let model = makeModel()

        await model.open(code(hubID: "hub-fifth", macName: "Fifth Mac").url())

        XCTAssertEqual(model.phase, .failed(.tooManyMacs))
        XCTAssertTrue(container.accepted.isEmpty, "no share accepted")
        XCTAssertTrue(host.prepared.isEmpty, "nothing written")
        XCTAssertEqual(host.rows.count, HubRegistry.limit)
        XCTAssertEqual(LinkFailure.tooManyMacs.title, "You can link up to 4 Macs")
        XCTAssertEqual(LinkFailure.tooManyMacs.hint, "Unlink one in Settings → Macs, then scan again")
        XCTAssertFalse(LinkFailure.tooManyMacs.offersScan)
    }

    func testRescanningALinkedMacRelinksWithoutAFifthSlot() async throws {
        for index in 1..<HubRegistry.limit {
            host.seed(linkRecord(hubID: "hub-\(index)", macName: "Mac \(index)"))
        }
        host.seed(linkRecord())
        let payload = code()
        macLinks(payload)
        let model = makeModel()

        await model.open(payload.url())

        XCTAssertEqual(model.phase, .linked(macName: "Acme Mac"))
        XCTAssertEqual(host.rows.count, HubRegistry.limit)
        XCTAssertEqual(host.row("hub-acme")?.link.nonce, payload.nonce, "the row takes the new link")
        XCTAssertTrue(host.removals.isEmpty)
    }

    func testAFailedFirstLinkRemovesItsCandidate() async throws {
        let model = makeModel()

        await model.open(code().url())

        XCTAssertEqual(model.phase, .failed(.noAnswer))
        XCTAssertEqual(host.removals.map(\.hubID), ["hub-acme"], "the candidate session and its files go")
        XCTAssertEqual(host.removals.map(\.keepRecordings), [true])
        XCTAssertTrue(host.rows.isEmpty)
    }

    /// A failed rescan of a linked Mac keeps it.
    func testAFailedRescanOfALinkedMacKeepsIt() async throws {
        let model = try await linkedModel(code())
        host.mac = { _ in nil }

        await model.open(code().url())

        XCTAssertEqual(model.phase, .failed(.noAnswer))
        XCTAssertTrue(host.removals.isEmpty, "a linked hub is never dropped by a failed scan")
        XCTAssertEqual(model.links.map(\.hubID), ["hub-acme"])
    }

    /// A refusal and a failed write drop the candidate as well.
    func testARefusedOrUnwritableFirstLinkRemovesItsCandidate() async throws {
        host.mac = { [grant = grantMaker] writes in writes.isEmpty ? nil : grant("hub-acme", false, .usedCode) }
        let refused = makeModel()
        await refused.open(code().url())
        XCTAssertEqual(refused.phase, .failed(.refused))
        XCTAssertEqual(host.removedHubIDs, ["hub-acme"])

        host.prepareError = CocoaError(.fileWriteNoPermission)
        let unwritable = makeModel()
        await unwritable.open(code(hubID: "hub-home", macName: "Home Mac").url())
        XCTAssertEqual(host.removedHubIDs, ["hub-acme", "hub-home"])
    }

    /// Ruling 1: the hub id becomes a path component of the hub's files
    /// (deleted recursively on removal): one that is not a plain name is
    /// refused before anything touches disk.
    func testAHubIDThatIsNotAPlainNameIsRefused() async throws {
        for hubID in ["", "../hub-acme", "hub/acme", "hub\\acme", ".", "..", ".hidden", "hub\u{0}acme"] {
            let model = makeModel()

            await model.open(code(hubID: hubID).url())

            XCTAssertEqual(model.phase, .failed(.refused), "hub id \(hubID.debugDescription)")
        }
        XCTAssertTrue(host.prepared.isEmpty, "nothing reached the host")
        XCTAssertTrue(container.accepted.isEmpty)
    }

    // MARK: - Unlinked events

    /// Multi-hub spec §6.1: the Mac's removal freezes the hub (no sync, no
    /// writes, its data readable until Forget); nothing is wiped and no
    /// farewell goes out.
    func testRemovedByMacFreezesThatHubAndKeepsItsRow() async throws {
        container.userRecordNameValue = "_colleague-a"
        let model = try await linkedModel(code())
        host.notSentCount = 2

        await model.removedByMac("hub-acme")

        XCTAssertEqual(host.markedRemoved, ["hub-acme"])
        XCTAssertEqual(host.row("hub-acme")?.state, .unlinkedByMac)
        XCTAssertEqual(model.links.first?.state, .unlinkedByMac)
        XCTAssertTrue(host.removals.isEmpty, "nothing is wiped")
        XCTAssertEqual(model.notice, .removed(macName: "Acme Mac"))
        XCTAssertEqual(LinkNotice.removed(macName: "Acme Mac").message, "Acme Mac removed this phone")
        let writes = try await host.deviceWrites()
        XCTAssertNil(writes.last?.unlinked, "the Mac's zones are gone: nothing to write")

        await model.removedByMac("hub-acme")
        XCTAssertEqual(host.markedRemoved, ["hub-acme"], "a frozen hub is frozen once")
    }

    func testRemovedWhileOfflineNamesTheMacAndLeavesTheOtherHub() async throws {
        container.userRecordNameValue = "_colleague-a"
        let model = try await linkedModel(code())
        let home = code(hubID: "hub-home", macName: "Home Mac")
        macLinks(home)
        await model.open(home.url())
        await model.finish()

        await model.removedByMac("hub-acme")

        XCTAssertEqual(model.notice, .removed(macName: "Acme Mac"), "the removed Mac is named")
        XCTAssertEqual(host.row("hub-home")?.state, .linked, "the other hub is untouched")
        XCTAssertTrue(host.removals.isEmpty)
    }

    // MARK: - The Mac's Remove read from the grant (#64)

    /// A heartbeat of the linked hub written after the link (the link's
    /// `linked_at` is `start`).
    private var laterHeartbeat: HeartbeatPayload { heartbeat(updatedAt: start.addingTimeInterval(60)) }

    /// A linked model whose first look already found the grant gone, the
    /// confirmation window then passed: one more look removes it unless a
    /// guard holds.
    private func modelOneLookFromRemoval() async throws -> LinkingViewModel {
        let model = try await linkedModel(code())
        await model.evaluate(hubID: "hub-acme", grant: nil, heartbeat: laterHeartbeat)
        XCTAssertEqual(model.links.first?.state, .linked, "one look is not enough")
        clock.advance(by: LinkingViewModel.removalConfirmAfter)
        return model
    }

    private func assertStillLinked(_ model: LinkingViewModel, _ why: String, line: UInt = #line) {
        XCTAssertEqual(host.row("hub-acme")?.state, .linked, why, line: line)
        XCTAssertTrue(host.markedRemoved.isEmpty, why, line: line)
        XCTAssertTrue(host.removals.isEmpty, why, line: line)
        XCTAssertNil(model.notice, why, line: line)
    }

    /// #64: a same-Apple-ID phone gets no `unlinked` event (its zones are the
    /// Mac's own and never vanish); the Mac's Remove deletes its grant. Two
    /// looks 30 s apart at the linked hub without it read as the same
    /// removal: the hub freezes.
    func testAGrantGoneOnTwoLooksThirtySecondsApartIsTheMacsRemove() async throws {
        let model = try await linkedModel(code())
        XCTAssertEqual(model.links.first?.link.deviceID, identity.deviceID, "the link keeps the id it linked with")
        XCTAssertEqual(model.links.first?.link.linkedAt, start, "and the grant's linked_at")

        await model.evaluate(hubID: "hub-acme", grant: grant(linked: true), heartbeat: laterHeartbeat)
        await model.evaluate(hubID: "hub-acme", grant: nil, heartbeat: laterHeartbeat)
        XCTAssertEqual(host.row("hub-acme")?.grantMissingSince, start, "the first look is kept on the hub's row")
        clock.advance(by: LinkingViewModel.removalConfirmAfter - 1)
        await model.evaluate(hubID: "hub-acme", grant: nil, heartbeat: laterHeartbeat)
        assertStillLinked(model, "under 30 s since the first look")

        clock.advance(by: 1)
        await model.evaluate(hubID: "hub-acme", grant: nil, heartbeat: laterHeartbeat)

        XCTAssertEqual(model.notice, .removed(macName: "Acme Mac"))
        XCTAssertEqual(
            LinkNotice.removed(macName: "Acme Mac", notSent: 2).message,
            "Acme Mac removed this phone — Not sent: 2 items were still waiting for your Mac"
        )
        XCTAssertEqual(host.markedRemoved, ["hub-acme"])
        XCTAssertEqual(host.row("hub-acme")?.state, .unlinkedByMac)
        XCTAssertTrue(host.removals.isEmpty, "frozen, not wiped")
        let writes = try await host.deviceWrites()
        XCTAssertNil(writes.last?.unlinked, "removed, not unlinking itself: nothing to write")
    }

    func testAnUnlinkedGrantOfTheLinkedHubCountsAsGone() async throws {
        let model = try await modelOneLookFromRemoval()
        await model.evaluate(hubID: "hub-acme", grant: grant(linked: false, refused: .usedCode), heartbeat: laterHeartbeat)
        XCTAssertEqual(model.notice, .removed(macName: "Acme Mac"))
    }

    func testTheFirstLookSurvivesARelaunch() async throws {
        _ = try await modelOneLookFromRemoval()
        let relaunched = makeModel()
        await relaunched.evaluate(hubID: "hub-acme", grant: nil, heartbeat: laterHeartbeat)
        XCTAssertEqual(relaunched.notice, .removed(macName: "Acme Mac"))
    }

    func testAGrantSeenAgainClearsTheFirstLook() async throws {
        let model = try await modelOneLookFromRemoval()
        await model.evaluate(hubID: "hub-acme", grant: grant(linked: true), heartbeat: laterHeartbeat)
        XCTAssertNil(host.row("hub-acme")?.grantMissingSince)
        await model.evaluate(hubID: "hub-acme", grant: nil, heartbeat: laterHeartbeat)
        assertStillLinked(model, "a new first look, not the second")
    }

    func testNoRemovalWithoutAHeartbeatNewerThanTheLink() async throws {
        let model = try await modelOneLookFromRemoval()
        await model.evaluate(hubID: "hub-acme", grant: nil, heartbeat: nil)
        assertStillLinked(model, "no heartbeat: the replica may not hold the hub's zone")
        await model.evaluate(hubID: "hub-acme", grant: nil, heartbeat: heartbeat(updatedAt: start))
        assertStillLinked(model, "a heartbeat from before the link")
    }

    /// Review round 2: a linked grant clears the first look whatever else
    /// that fetch held. Each `between` is a fetch that sees the grant linked
    /// but would fail one of the heartbeat or busy conditions; the grant
    /// gone again afterwards is a new first look, not the second.
    private func assertALinkedGrantClearsTheFirstLook(
        _ why: String,
        between: (LinkingViewModel) async throws -> Void,
        line: UInt = #line
    ) async throws {
        let model = try await modelOneLookFromRemoval()
        try await between(model)
        XCTAssertNil(host.row("hub-acme")?.grantMissingSince, why, line: line)
        await model.evaluate(hubID: "hub-acme", grant: nil, heartbeat: laterHeartbeat)
        assertStillLinked(model, why, line: line)
    }

    func testALinkedGrantWithoutAHeartbeatClearsTheFirstLook() async throws {
        try await assertALinkedGrantClearsTheFirstLook("no heartbeat in that fetch") { model in
            await model.evaluate(hubID: "hub-acme", grant: self.grant(linked: true), heartbeat: nil)
        }
    }

    func testALinkedGrantWithAnotherHubsHeartbeatClearsTheFirstLook() async throws {
        try await assertALinkedGrantClearsTheFirstLook("another hub's heartbeat in that fetch") { model in
            let other = self.heartbeat(hubID: "hub-studio", macName: "Acme Studio", updatedAt: self.start.addingTimeInterval(60))
            await model.evaluate(hubID: "hub-acme", grant: self.grant(linked: true), heartbeat: other)
        }
    }

    func testALinkedGrantWithAnOlderHeartbeatClearsTheFirstLook() async throws {
        try await assertALinkedGrantClearsTheFirstLook("a heartbeat from before the link") { model in
            await model.evaluate(hubID: "hub-acme", grant: self.grant(linked: true), heartbeat: self.heartbeat(updatedAt: self.start))
        }
    }

    func testALinkedGrantWhileALinkIsPendingClearsTheFirstLook() async throws {
        try await assertALinkedGrantClearsTheFirstLook("a pending link") { model in
            let store = LinkStore(defaults: self.defaults)
            store.pending = PendingLink(link: self.linkRecord(), deadline: self.start.addingTimeInterval(600), baseline: nil, baselineCaptured: false)
            await model.evaluate(hubID: "hub-acme", grant: self.grant(linked: true), heartbeat: self.laterHeartbeat)
            store.pending = nil
        }
    }

    func testALinkedGrantWhileAScanRunsClearsTheFirstLook() async throws {
        try await assertALinkedGrantClearsTheFirstLook("a scan running") { model in
            self.host.mac = { _ in nil }
            self.host.parksFetchGrant = true
            let scan = Task { await model.open(self.code(hubID: "hub-home", macName: "Home Mac").url()) }
            try await self.poll({ model.isBusy }, "the scan is checking")
            await model.evaluate(hubID: "hub-acme", grant: self.grant(linked: true), heartbeat: self.laterHeartbeat)
            scan.cancel()
            self.host.parksFetchGrant = false
            _ = await scan.value
        }
    }

    func testNoRemovalFromAnotherHubsHeartbeatOrGrant() async throws {
        let model = try await modelOneLookFromRemoval()
        await model.evaluate(
            hubID: "hub-acme", grant: nil, heartbeat: heartbeat(hubID: "hub-studio", macName: "Acme Studio", updatedAt: start.addingTimeInterval(60))
        )
        assertStillLinked(model, "another hub's heartbeat")
        await model.evaluate(hubID: "hub-acme", grant: grant(hubID: "hub-studio", linked: false), heartbeat: laterHeartbeat)
        assertStillLinked(model, "another hub's grant")
    }

    func testNoRemovalFromAnotherDevicesGrant() async throws {
        let model = try await modelOneLookFromRemoval()
        let other = DeviceGrant(
            deviceID: "device-other", hubID: "hub-acme", name: "Other", scope: .private, linked: false,
            typingAllowed: false, startSessionsAllowed: true
        )
        await model.evaluate(hubID: "hub-acme", grant: other, heartbeat: laterHeartbeat)
        assertStillLinked(model, "not the grant of the id this phone linked with")
    }

    /// A link saved before the device id and `linked_at` were kept never
    /// reads a removal.
    func testALinkWithoutItsDeviceIDOrLinkTimeNeverReadsARemoval() async throws {
        var old = linkRecord()
        old.linkedAt = start
        host.seed(old)
        let noID = makeModel()
        await noID.evaluate(hubID: "hub-acme", grant: nil, heartbeat: laterHeartbeat)
        clock.advance(by: LinkingViewModel.removalConfirmAfter)
        await noID.evaluate(hubID: "hub-acme", grant: nil, heartbeat: laterHeartbeat)
        assertStillLinked(noID, "no device id")

        host = FakeLinkHost(log: log)
        old.linkedAt = nil
        old.deviceID = identity.deviceID
        host.seed(old)
        let noTime = makeModel()
        await noTime.evaluate(hubID: "hub-acme", grant: nil, heartbeat: laterHeartbeat)
        clock.advance(by: LinkingViewModel.removalConfirmAfter)
        await noTime.evaluate(hubID: "hub-acme", grant: nil, heartbeat: laterHeartbeat)
        assertStillLinked(noTime, "no link time")
    }

    func testNoRemovalWhileALinkIsPending() async throws {
        let model = try await modelOneLookFromRemoval()
        LinkStore(defaults: defaults).pending = PendingLink(
            link: linkRecord(), deadline: start.addingTimeInterval(600), baseline: nil, baselineCaptured: false
        )
        await model.evaluate(hubID: "hub-acme", grant: nil, heartbeat: laterHeartbeat)
        assertStillLinked(model, "a pending link")
    }

    func testNoRemovalWhileAScanRuns() async throws {
        let model = try await modelOneLookFromRemoval()
        host.mac = { _ in nil }
        host.parksFetchGrant = true
        let scan = Task { await model.open(self.code(hubID: "hub-home", macName: "Home Mac").url()) }
        try await poll({ model.isBusy }, "the scan is checking")
        await model.evaluate(hubID: "hub-acme", grant: nil, heartbeat: laterHeartbeat)
        assertStillLinked(model, "a scan running")
        scan.cancel()
        host.parksFetchGrant = false
        _ = await scan.value
    }

    /// Review Focus 4 at the flow: the removal check of one hub reads that
    /// hub's row and freezes only it.
    func testTheRemovalCheckOfOneHubLeavesTheOtherAlone() async throws {
        let model = try await linkedModel(code())
        let home = code(hubID: "hub-home", macName: "Home Mac")
        macLinks(home)
        await model.open(home.url())
        await model.finish()
        let homeLater = heartbeat(hubID: "hub-home", macName: "Home Mac", updatedAt: start.addingTimeInterval(60))

        await model.evaluate(hubID: "hub-home", grant: nil, heartbeat: homeLater)
        clock.advance(by: LinkingViewModel.removalConfirmAfter)
        await model.evaluate(hubID: "hub-acme", grant: nil, heartbeat: laterHeartbeat)
        XCTAssertTrue(host.markedRemoved.isEmpty, "hub-acme's first look is its own")
        await model.evaluate(hubID: "hub-home", grant: nil, heartbeat: homeLater)

        XCTAssertEqual(host.markedRemoved, ["hub-home"])
        XCTAssertEqual(host.row("hub-acme")?.state, .linked)
        XCTAssertEqual(model.notice, .removed(macName: "Home Mac"))
    }

    func testHeartbeatStaleForADayShowsTheStaleNotice() async throws {
        let model = try await linkedModel(code())

        await model.evaluate(hubID: "hub-acme", heartbeat: heartbeat(updatedAt: start.addingTimeInterval(-86_399)), isActive: true)
        XCTAssertNil(model.notice, "under a day is only offline")

        await model.evaluate(hubID: "hub-acme", heartbeat: heartbeat(updatedAt: start.addingTimeInterval(-86_400)), isActive: true)
        XCTAssertEqual(model.notice, .stale)
        XCTAssertEqual(LinkNotice.stale.message, "Your Mac hasn't synced for a day — if it changed iCloud account, link again")
        XCTAssertTrue(host.markedRemoved.isEmpty && host.removals.isEmpty, "a stale Mac keeps its link and its queue")

        await model.evaluate(hubID: "hub-acme", heartbeat: heartbeat(updatedAt: start), isActive: true)
        XCTAssertNil(model.notice)
    }

    func testStaleNoticeOnlyForTheActiveHub() async throws {
        let model = try await linkedModel(code())
        let stale = heartbeat(updatedAt: start.addingTimeInterval(-86_400))

        await model.evaluate(hubID: "hub-acme", heartbeat: stale, isActive: false)
        XCTAssertNil(model.notice, "an inactive hub's heartbeat says nothing about the hub on screen")

        await model.evaluate(hubID: "hub-acme", heartbeat: stale, isActive: true)
        XCTAssertEqual(model.notice, .stale)

        await model.evaluate(hubID: "hub-acme", heartbeat: heartbeat(updatedAt: start), isActive: false)
        XCTAssertEqual(model.notice, .stale, "only the active hub's fetch clears it")
    }

    private func heartbeat(hubID: String = "hub-acme", macName: String = "Acme Mac", updatedAt: Date) -> HeartbeatPayload {
        HeartbeatPayload(
            updatedAt: updatedAt,
            appVersion: "1.0",
            hubID: hubID,
            macName: macName,
            flavor: .default,
            lastPublishAt: updatedAt,
            lastRelayAt: updatedAt,
            relayBacklog: 0,
            accounts: [],
            enabledAt: updatedAt,
            ownerUser: owner,
            sharing: .available
        )
    }

    // MARK: - Other payloads

    func testANewerCodeVersionAsksToUpdateTheApp() async throws {
        let model = makeModel()

        await model.open(code(version: LinkPayload.currentVersion + 1).url())

        XCTAssertEqual(model.phase, .failed(.updateApp))
        XCTAssertEqual(LinkFailure.updateApp.message, "Update Watchtower on this iPhone")
        XCTAssertTrue(host.prepared.isEmpty)
    }

    /// Multi-hub spec §6.7: a v1 code comes from a single-hub Mac.
    func testAnOlderCodeVersionAsksToUpdateTheMac() async throws {
        let model = makeModel()

        await model.open(code(version: 1).url())

        XCTAssertEqual(model.phase, .failed(.updateMac))
        XCTAssertEqual(LinkFailure.updateMac.message, "Update Watchtower on this Mac")
        XCTAssertTrue(host.prepared.isEmpty)
    }

    func testAnUnreadableCodeCannotBeUsed() async throws {
        let model = makeModel()

        await model.scanned("watchtower://link?d=not-json")

        XCTAssertEqual(model.phase, .failed(.refused))
        XCTAssertTrue(host.prepared.isEmpty)
    }

    /// The system Camera app opens the app with the code's URL: the same flow
    /// as a scan inside the app.
    func testACameraOpenedLinkURLRunsTheSameFlowAsAnInAppScan() async throws {
        let payload = code()
        macLinks(payload)
        let scannedModel = makeModel()
        await scannedModel.scanned(payload.url().absoluteString)
        let scannedWrites = try await host.deviceWrites()

        defaults = try makeDefaults()
        host = FakeLinkHost(log: log)
        macLinks(payload)
        let openedModel = makeModel()
        await openedModel.open(payload.url())
        let openedWrites = try await host.deviceWrites()

        XCTAssertEqual(scannedModel.phase, .linked(macName: "Acme Mac"))
        XCTAssertEqual(openedModel.phase, scannedModel.phase)
        XCTAssertEqual(openedWrites.map(\.linkNonce), scannedWrites.map(\.linkNonce))
        XCTAssertEqual(openedModel.links.map(\.hubID), scannedModel.links.map(\.hubID))
    }

    /// A second code arriving while a link is running is ignored.
    func testACodeArrivingMidLinkIsIgnored() async throws {
        clock.parked = true
        let model = makeModel()
        let flow = Task { await model.open(code().url()) }
        try await poll { model.phase == .waiting(macName: "Acme Mac") }

        await model.open(code(hubID: "hub-studio", macName: "Acme Studio").url())

        XCTAssertEqual(model.phase, .waiting(macName: "Acme Mac"))
        flow.cancel()
        await flow.value
        let writes = try await host.deviceWrites()
        XCTAssertEqual(writes.count, 1)
    }

    /// Design pass O3: every failure is a title over a hint; `message` stays
    /// "title — hint" for every other reader, and signIn, updateApp and
    /// updateMac keep today's exact text. An iCloud failure without a
    /// reason has no hint.
    func testEveryFailureIsATitleOverAHint() {
        let expected: [(LinkFailure, String, String?)] = [
            (.expired, "This code expired", "Show a new code on the Mac"),
            (.signIn, "Sign in to iCloud on this iPhone", "Watchtower uses iCloud to reach your Mac"),
            (.cannotShare, "This Mac can't share with another Apple ID right now", "Show a new code on the Mac"),
            (.noAnswer, "Your Mac didn't answer", "Keep Settings → Mobile open on the Mac and scan again"),
            (.refused, "This code can't be used", "Show a new code on the Mac"),
            (.updateApp, "Update Watchtower on this iPhone", nil),
            (.updateMac, "Update Watchtower on this Mac", nil),
            (.iCloud("The network is offline"), "Couldn't reach iCloud", "The network is offline"),
            (.local("disk I/O error"), "Couldn't set up sync on this iPhone", "disk I/O error"),
            (.tooManyMacs, "You can link up to 4 Macs", "Unlink one in Settings → Macs, then scan again")
        ]
        for (failure, title, hint) in expected {
            XCTAssertEqual(failure.title, title, "\(failure)")
            XCTAssertEqual(failure.hint, hint, "\(failure)")
        }
        XCTAssertEqual(LinkFailure.signIn.message, "Sign in to iCloud on this iPhone to use Watchtower", "today's exact text")
        XCTAssertEqual(LinkFailure.updateApp.message, "Update Watchtower on this iPhone")
        for (failure, title, hint) in expected where ![.signIn, .updateApp, .updateMac].contains(failure) {
            XCTAssertEqual(failure.message, "\(title) — \(hint ?? "")", "\(failure)")
        }
        XCTAssertNil(LinkFailure.iCloud("").hint, "an empty reason is no hint")
        XCTAssertEqual(LinkFailure.iCloud("").message, "Couldn't reach iCloud")
    }

    /// Design pass O2: every phase change stamps when it started, on the
    /// flow's clock; the waiting screen's hint reads it.
    func testEveryPhaseChangeStampsWhenItStarted() async throws {
        let model = makeModel()
        XCTAssertNil(model.phaseStartedAt, "nothing has started yet")
        model.startScan()
        XCTAssertEqual(model.phaseStartedAt, start)
        clock.advance(by: 5)
        model.dismiss()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.phaseStartedAt, start.addingTimeInterval(5))

        clock.parked = true
        let flow = Task { await model.open(code().url()) }
        try await poll { model.phase == .waiting(macName: "Acme Mac") }
        XCTAssertEqual(model.phaseStartedAt, clock.now(), "the wait starts when it is shown")
        flow.cancel()
        await flow.value
    }

    /// A wall-clock jump neither brings the hint forward nor holds it back:
    /// the elapsed time comes from the monotonic source.
    func testTheWaitedTimeIgnoresAWallClockJump() {
        let model = makeModel()
        model.startScan()
        XCTAssertEqual(model.phaseElapsed(), 0)
        clock.advance(by: 5)
        clock.jumpWallClock(by: 3600)
        XCTAssertEqual(model.phaseElapsed(), 5, "an hour forward on the wall clock")
        clock.jumpWallClock(by: -7200)
        XCTAssertEqual(model.phaseElapsed(), 5, "and back")
        XCTAssertNil(LinkStepsModel(waitingFor: "Acme Mac", waited: 19.9).hint)
        XCTAssertNotNil(LinkStepsModel(waitingFor: "Acme Mac", waited: 20).hint)
        XCTAssertNil(LinkStepsModel(waitingFor: "Acme Mac", waited: nil).hint)
    }

    /// VoiceOver reads a step as its text and one of four values.
    func testAStepReadsItsStateAsAWord() {
        let values = [StepRow.State.done, .current, .waiting, .todo, .failed].map(\.accessibilityValue)
        XCTAssertEqual(values, ["Done", "In progress", "In progress", "Not started", "Failed"])
    }

    /// Design pass O2 and review focus 5: checking makes step 1 current;
    /// waiting makes it done and step 2 current; the hint appears after 20 s
    /// of waiting, never before (a start stamped in the future included);
    /// an empty Mac name reads "your Mac".
    func testTheLinkStepsFollowThePhaseAndHintAfterTwentySeconds() {
        let checking = LinkStepsModel(waitingFor: nil, startedAt: start, now: start.addingTimeInterval(60))
        XCTAssertEqual(checking.steps.map(\.state), [.current, .todo, .todo])
        XCTAssertEqual(checking.steps.map(\.text), ["Code read", "Waiting for your Mac to confirm", "Linked"])
        XCTAssertNil(checking.hint, "no hint while checking")

        let waiting = LinkStepsModel(waitingFor: "Acme Mac", startedAt: start, now: start.addingTimeInterval(19))
        XCTAssertEqual(waiting.steps.map(\.state), [.done, .current, .todo])
        XCTAssertEqual(waiting.steps[1].text, "Waiting for Acme Mac to confirm")
        XCTAssertNil(waiting.hint)
        let late = LinkStepsModel(waitingFor: "Acme Mac", startedAt: start, now: start.addingTimeInterval(20))
        XCTAssertEqual(late.hint, "Keep Settings → Mobile open on the Mac.")

        XCTAssertNil(LinkStepsModel(waitingFor: "Acme Mac", startedAt: start.addingTimeInterval(30), now: start).hint, "a future start")
        XCTAssertNil(LinkStepsModel(waitingFor: "Acme Mac", startedAt: nil, now: start).hint)
        XCTAssertEqual(LinkStepsModel(waitingFor: "", startedAt: nil, now: start).steps[1].text, "Waiting for your Mac to confirm")
    }

    // MARK: - Live container

    /// The live container leaves the linked hub's own zones' shares
    /// (`DataZone-<hub_id>`, `RelayZone-<hub_id>`), never the single-hub
    /// build's fixed-name zones.
    func testLeavingSharesTargetsTheLinkedHubsZones() {
        let ids = CloudKitLinkContainer.shareRecordIDs(ownerName: owner, hubID: "hub-acme")

        XCTAssertEqual(ids.map(\.zoneID.zoneName).sorted(), ["DataZone-hub-acme", "RelayZone-hub-acme"])
        XCTAssertEqual(Set(ids.map(\.zoneID.ownerName)), [owner])
        XCTAssertEqual(Set(ids.map(\.recordName)), [CKRecordNameZoneWideShare])
    }
}
