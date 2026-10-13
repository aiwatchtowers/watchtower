import CloudKit
import CryptoKit
import Foundation
import WatchtowerE2ETesting
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// Hub ids are UUIDs since E2E: the test hub's, and two other Macs.
private let acme = TestE2E.hubID.uuidString
private let studio = "5D0D1000-0000-4000-8000-000000000002"
private let otherHub = "07E40000-0000-4000-8000-000000000003"

/// The phone's link flow (mobile POC spec §2.3 steps 1–6, §9): a fake
/// container (iCloud identity, share accept), a fake host (transports per
/// database, a scripted Mac, the wipe), a fake clock and the real LinkStore.
@MainActor
final class LinkingViewModelTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    /// The test pairing's phone: the hello and the keyboxes name its key-derived id (D7).
    private let identity = DeviceIdentity(
        deviceID: TestE2E.deviceID.uuidString, name: "Colleague A's iPhone", model: "iPhone", appVersion: "1.0"
    )
    private let owner = "_owner-acme"
    private let dataShare = "https://www.icloud.com/share/acme-data"
    private let relayShare = "https://www.icloud.com/share/acme-relay"

    private var log: LinkEventLog!
    private var container: FakeLinkContainer!
    private var host: FakeLinkHost!
    private var clock: FakeLinkClock!
    private var defaults: UserDefaults!
    /// The phone's Keychain stand-in: the test pairing's identity, no hub linked yet.
    private var keyStore: InMemoryPhoneKeyStore!

    override func setUp() async throws {
        keyStore = try InMemoryPhoneKeyStore(identity: TestE2E.deviceIdentity)
        log = LinkEventLog()
        container = FakeLinkContainer(log: log)
        container.userRecordNameValue = owner
        host = FakeLinkHost(log: log)
        host.keys = keyStore
        clock = FakeLinkClock(now: start)
        defaults = try makeDefaults()
    }

    private func makeModel() -> LinkingViewModel {
        let model = LinkingViewModel(
            container: container, store: LinkStore(defaults: defaults), identity: identity, keys: keyStore, clock: clock
        )
        model.host = host
        return model
    }

    /// A code issued `issuedAgo` seconds before the fake clock's now, with the test hub's keys.
    private func code(
        hubID: String = acme,
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
            relayShare: shares ? relayShare : nil,
            hubSigningKey: WireBytes.base64URL(TestE2E.hubSigningKey.publicKey.rawRepresentation),
            hubAgreementKey: WireBytes.base64URL(TestE2E.hubAgreementKey.publicKey.rawRepresentation)
        )
    }

    private func grant(hubID: String = acme, linked: Bool, refused: LinkRefusal? = nil) -> DeviceGrant {
        grantMaker(hubID, linked, refused)
    }

    /// `grant` as a value, for the scripted Mac's closures.
    private var grantMaker: (_ hubID: String, _ linked: Bool, _ refused: LinkRefusal?) -> DeviceGrant {
        let identity = identity
        let start = start
        let clock = clock
        return { hubID, linked, refused in
            DeviceGrant(
                deviceID: identity.deviceID ?? "",
                hubID: hubID,
                name: identity.name,
                scope: .private,
                linked: linked,
                linkRefused: refused,
                // The Mac links at the owner's click: now, after the code's iat (review M-3).
                linkedAt: linked ? clock?.now() : nil,
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
        XCTAssertNotNil(model.link)
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
        XCTAssertEqual(host.preparedHubIDs, [acme], "the scan syncs the code's hub")
        let writes = try await host.deviceWrites(in: .private)
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.linkNonce, payload.nonce)
        XCTAssertEqual(writes.first?.scope, .private)
        XCTAssertEqual(writes.first?.userRecordName, owner)
        XCTAssertEqual(model.phase, .linked(macName: "Acme Mac"))
        XCTAssertEqual(model.link?.databaseScope, .private)
        XCTAssertEqual(host.links.last?.device?.scope, .private)
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
        XCTAssertEqual(model.link?.databaseScope, .shared(ownerName: owner))
        XCTAssertEqual(model.link?.dataShareURL, dataShare)
        XCTAssertEqual(model.link?.relayShareURL, relayShare)
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
            hubID: acme, macName: "Acme Mac", ownerUser: owner, nonce: LinkPayload.makeNonce(),
            iat: iat, exp: iat + LinkPayload.lifetime,
            hubSigningKey: WireBytes.base64URL(TestE2E.hubSigningKey.publicKey.rawRepresentation),
            hubAgreementKey: WireBytes.base64URL(TestE2E.hubAgreementKey.publicKey.rawRepresentation)
        )
        // The Mac checks expiry on its own clock: still valid there.
        host.mac = { [grant = grantMaker] writes in
            guard writes.contains(where: { $0.linkNonce == payload.nonce }) else { return nil }
            let valid = payload.exp >= Int64(macNow.timeIntervalSince1970)
            return valid ? grant(acme, true, nil) : grant(acme, false, .expiredCode)
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

    /// The wait lasts until the code's expiry plus the clock grace, not a
    /// fixed minute: the owner needs time to compare the code.
    func testNoKeyboxBeforeTheCodeExpiresShowsDidNotAnswer() async throws {
        let model = makeModel()

        await model.open(code().url())

        XCTAssertEqual(model.phase, .failed(.noAnswer))
        XCTAssertEqual(
            LinkFailure.noAnswer.message,
            "Your Mac didn't answer — Keep Settings → Mobile open on the Mac and scan again",
            "title — hint (design pass O3)"
        )
        // Issued 10 s ago: exp is 590 s ahead, plus the 120 s grace.
        XCTAssertGreaterThanOrEqual(clock.slept, 710)
        XCTAssertLessThan(clock.slept, 712, "the wait ends at exp + 120 s")
        XCTAssertNil(model.link)
        XCTAssertTrue(host.links.isEmpty, "never shown as linked")
        XCTAssertNil(LinkStore(defaults: defaults).pending, "a finished wait leaves nothing to resume")
        XCTAssertNil(try keyStore.hubLink(acme), "the scan's keys go with the wait")
        XCTAssertNil(model.linkCode)
    }

    func testRefusedUsedCodeShowsCannotBeUsed() async throws {
        let payload = code()
        host.mac = { [grant = grantMaker] writes in
            writes.isEmpty ? nil : grant(acme, false, .usedCode)
        }
        let model = makeModel()

        await model.open(payload.url())

        XCTAssertEqual(model.phase, .failed(.refused))
        XCTAssertEqual(LinkFailure.refused.message, "This code can't be used — Show a new code on the Mac")
        XCTAssertNil(model.link)
        XCTAssertTrue(host.links.isEmpty)
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
                return grant(acme, false, .expiredCode)
            }
            return grant(acme, true, nil)
        }
        let model = makeModel()

        await model.open(payload.url())

        XCTAssertEqual(model.phase, .linked(macName: "Acme Mac"))
        XCTAssertGreaterThanOrEqual(clock.slept, 4, "it waited for the new answer")
    }

    func testAGrantForAnotherHubIsNotTheAnswer() async throws {
        let payload = code()
        host.mac = { [grant = grantMaker] writes in
            writes.isEmpty ? nil : grant(otherHub, true, nil)
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
        XCTAssertEqual(host.links.last?.device?.deviceID, identity.deviceID)
        XCTAssertEqual(host.links.last?.writesAllowed, true)
        XCTAssertEqual(LinkStore(defaults: defaults).link?.hubID, acme, "the link is saved")
    }

    func testScanningTheSameCodeTwiceStaysLinkedWithoutASecondWrite() async throws {
        let payload = code()
        let model = try await linkedModel(payload)

        await model.open(payload.url())

        XCTAssertEqual(model.phase, .linked(macName: "Acme Mac"))
        XCTAssertEqual(model.link?.hubID, acme)
        let writes = try await host.deviceWrites()
        XCTAssertEqual(writes.count, 1, "no second device-record write")
        XCTAssertEqual(host.wipes, 0)
        XCTAssertTrue(host.links.allSatisfy { $0.device != nil }, "never unlinked meanwhile")
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
        XCTAssertEqual(pending.deadline, start.addingTimeInterval(710), "the code's exp + 120 s")

        // Relaunch 20 s later: 690 s of the wait are left.
        clock.parked = false
        clock.advance(by: 20)
        let relaunched = makeModel()
        XCTAssertNil(relaunched.link, "a pending link is not a link")

        await relaunched.resumePendingLink()

        XCTAssertEqual(host.prepared.last, .shared(ownerName: owner), "the wait reads the scan's database")
        XCTAssertEqual(host.preparedHubIDs.last, acme, "and the scan's hub")
        XCTAssertEqual(relaunched.phase, .failed(.noAnswer))
        XCTAssertGreaterThanOrEqual(clock.slept, 690)
        XCTAssertLessThan(clock.slept, 692, "only the remaining part of the wait")
        XCTAssertTrue(host.links.isEmpty, "never shown as linked")
        XCTAssertNil(relaunched.link)
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
        XCTAssertEqual(LinkStore(defaults: defaults).bootScope, .shared(ownerName: owner), "the relaunch boots the scan's database")
        XCTAssertEqual(LinkStore(defaults: defaults).bootHubID, acme, "and the scan's hub")

        XCTAssertFalse(pending.baselineCaptured, "nothing is written before the baseline")

        host.parksPrepare = false
        let preparedBefore = host.prepared.count
        let relaunched = makeModel()
        await relaunched.resumePendingLink()

        XCTAssertEqual(relaunched.phase, .failed(.noAnswer), "nothing reached the Mac: scan again at once")
        XCTAssertEqual(host.prepared.count, preparedBefore, "no wait to resume")
        XCTAssertEqual(clock.slept, 0)
        XCTAssertTrue(host.links.isEmpty, "never shown as linked")
        XCTAssertNil(LinkStore(defaults: defaults).pending)
    }

    /// Board #70: killed before the baseline was saved, a relaunch must not
    /// take a refusal of an earlier code, still in the replica, as this
    /// scan's answer.
    func testAResumeWithoutACapturedBaselineIgnoresAnEarlierRefusal() async throws {
        LinkStore(defaults: defaults).pending = PendingLink(
            link: linkRecord(), deadline: start.addingTimeInterval(50), baseline: nil, baselineCaptured: false
        )
        host.mac = { [grant = grantMaker] _ in grant(acme, false, .expiredCode) }
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
        try keyStore.saveHubLink(try ScannedHubKeys(code()).unconfirmedLink)
        LinkStore(defaults: defaults).pending = PendingLink(
            link: record, deadline: start.addingTimeInterval(30), baseline: nil, baselineCaptured: true
        )
        let answerAt = start.addingTimeInterval(10)
        host.mac = { [grant = grantMaker, clock] _ in
            guard let clock, clock.now() >= answerAt else { return nil }
            return grant(acme, true, nil)
        }
        let model = makeModel()

        await model.resumePendingLink()

        XCTAssertEqual(model.phase, .linked(macName: "Acme Mac"))
        var saved = record
        // E2E (M-3): the scripted Mac links at the owner's click, after the code's iat.
        saved.linkedAt = answerAt
        XCTAssertEqual(model.link, saved, "the pending link, with its grant's linked_at")
        XCTAssertNil(LinkStore(defaults: defaults).pending)
    }

    private func linkRecord(hubID: String = acme, macName: String = "Acme Mac", scope: DeviceScope = .private) -> LinkRecord {
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

        XCTAssertEqual(host.wipes, 1, "the replica is wiped")
        XCTAssertEqual(host.wipesKeptRecordings, [false], "review F6: nothing is carried to another account")
        XCTAssertNil(model.link, "Welcome is shown")
        XCTAssertNil(LinkStore(defaults: defaults).link)
        XCTAssertNil(host.links.last?.device)
        XCTAssertEqual(model.phase, .idle)
    }

    func testTheSameICloudAccountReturningKeepsTheLink() async throws {
        let model = try await linkedModel(code())

        await model.accountChanged()

        XCTAssertEqual(host.wipes, 0)
        XCTAssertNotNil(model.link)
    }

    func testSignedOutOfICloudKeepsTheReplica() async throws {
        let model = try await linkedModel(code())

        container.status = .noAccount
        await model.accountChanged()

        XCTAssertEqual(host.wipes, 0, "kept until the same account returns or another one signs in")
        XCTAssertNotNil(model.link)
    }

    // MARK: - Unlink

    func testUnlinkWritesUnlinkedWipesAndReportsNotSent() async throws {
        let model = try await linkedModel(code())
        host.notSentCount = 3

        await model.unlink()

        let writes = try await host.deviceWrites(in: .private)
        XCTAssertEqual(writes.last?.unlinked, true)
        XCTAssertEqual(
            Array(log.events.suffix(3)), ["wipe private", "prepare private", "wipe private"],
            "the queue is wiped first, so the flush sends only the unlinked record; then the phone restarts unlinked"
        )
        XCTAssertEqual(host.flushes, 1)
        XCTAssertEqual(host.wipes, 2)
        XCTAssertEqual(
            host.wipedHubIDs, [acme, AppEnvironment.unlinkedHubID],
            "final review m3: a private unlink ends on the unlinked hub id too"
        )
        XCTAssertNil(model.link)
        XCTAssertNil(LinkStore(defaults: defaults).link)
        XCTAssertNil(host.links.last?.device)
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

        await model.unlink()

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

    func testRemovedOrAnAccountSwitchDuringACaptureSaysTheRecordingWasKept() async throws {
        container.userRecordNameValue = "_colleague-a"
        let removed = try await linkedModel(code())
        host.stopsRecording = true

        await removed.removedByMac()

        XCTAssertEqual(removed.notice, .recordingKept(notSent: 0), "the kept recording also says the link ended")

        let switched = try await linkedModel(code())
        host.stopsRecording = true
        host.notSentCount = 1
        container.userRecordNameValue = "_colleague-b"

        await switched.accountChanged()

        XCTAssertNil(switched.link)
        XCTAssertEqual(switched.notice, .notSent(1), "another account: the stopped capture is not kept, it is counted")
    }

    /// Review F3/F8: a recording problem of the wipe wins over every other
    /// notice, with the Not sent count.
    func testARecordingProblemOfTheWipeIsTheNotice() async throws {
        let model = try await linkedModel(code())
        host.recordingProblem = "Some recordings couldn't be read (disk full)"
        host.notSentCount = 2

        await model.unlink()

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

        await model.unlink()

        XCTAssertEqual(container.left, [owner])
        XCTAssertEqual(container.leftHubIDs, [acme], "the linked hub's shares are left")
        XCTAssertEqual(host.preparedHubIDs.last, acme, "unlinked is written to the linked hub's zones")
        XCTAssertEqual(host.wipedHubIDs, [acme], "board #70: one restart, on the linked hub, empties the queue")
        let writes = try await host.deviceWrites(in: .shared(ownerName: owner))
        XCTAssertEqual(writes.last?.unlinked, true)
        XCTAssertEqual(
            Array(log.events.suffix(4)),
            ["wipe shared(\(owner))", "prepare shared(\(owner))", "leave \(owner)", "retire"],
            "wipe the queue in the shared database, write unlinked there, leave; the left shares sync nothing, so no second restart"
        )
        XCTAssertEqual(host.flushes, 1)
        XCTAssertEqual(host.retirements, 1, "the next link restarts even on the same database")
        XCTAssertNil(model.notice, "nothing was waiting")
    }

    /// Shares that could not be left still reach the Mac's zones: the
    /// phone restarts on its own database, unlinked, as a private link does.
    func testUnlinkInSharedScopeWhoseSharesStayRestartsPrivate() async throws {
        container.userRecordNameValue = "_colleague-a"
        let model = try await linkedModel(code())
        container.leaveError = CKError(.networkUnavailable)

        await model.unlink()

        XCTAssertEqual(host.wipedHubIDs, [acme, AppEnvironment.unlinkedHubID])
        XCTAssertEqual(Array(log.events.suffix(2)), ["leave \(owner)", "wipe private"])
        XCTAssertEqual(host.retirements, 0)
        XCTAssertNil(model.link)
        XCTAssertEqual(model.phase, .idle)
    }

    /// Leaving the shares makes the Mac's zones vanish: the transport's
    /// `unlinked` arriving meanwhile is the unlink's own, not a removal.
    func testRemovedArrivingDuringAnUnlinkIsIgnored() async throws {
        container.userRecordNameValue = "_colleague-a"
        let model = try await linkedModel(code())
        container.onLeave = { await model.removedByMac() }

        await model.unlink()

        XCTAssertEqual(host.wipes, 1, "only the unlink's own wipe")
        XCTAssertEqual(host.links.filter { $0.device == nil }.count, 1, "one teardown")
        XCTAssertNil(model.notice, "the owner unlinked; the Mac did not remove the phone")
        XCTAssertNil(model.link)
        XCTAssertEqual(model.phase, .idle)
    }

    func testAnAccountChangeArrivingDuringAnUnlinkIsIgnored() async throws {
        container.userRecordNameValue = "_colleague-a"
        let model = try await linkedModel(code())
        container.onLeave = { [container] in
            container?.userRecordNameValue = "_colleague-b"
            await model.accountChanged()
        }

        await model.unlink()

        XCTAssertEqual(host.wipes, 1, "only the unlink's own wipe")
        XCTAssertEqual(host.links.filter { $0.device == nil }.count, 1, "one teardown")
        XCTAssertEqual(model.phase, .idle)
    }

    // MARK: - Unlinked events

    func testRemovedWhileOfflineShowsRemovedAndWipes() async throws {
        container.userRecordNameValue = "_colleague-a"
        let model = try await linkedModel(code())
        host.notSentCount = 2

        await model.removedByMac()

        XCTAssertEqual(model.notice, .removed(notSent: 2), "what the wipe dropped is reported")
        XCTAssertEqual(LinkNotice.removed().message, "This Mac removed this phone")
        XCTAssertEqual(host.wipes, 1)
        XCTAssertNil(model.link)
        XCTAssertNil(host.links.last?.device)
        let writes = try await host.deviceWrites()
        XCTAssertNil(writes.last?.unlinked, "the Mac's zones are gone: nothing to write")
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
        await model.evaluate(grant: nil, heartbeat: laterHeartbeat)
        XCTAssertNotNil(model.link, "one look is not enough")
        clock.advance(by: LinkingViewModel.removalConfirmAfter)
        return model
    }

    private func assertStillLinked(_ model: LinkingViewModel, _ why: String, line: UInt = #line) {
        XCTAssertNotNil(model.link, why, line: line)
        XCTAssertEqual(host.wipes, 0, why, line: line)
        XCTAssertNil(model.notice, why, line: line)
    }

    /// #64: a same-Apple-ID phone gets no `unlinked` event (its zones are the
    /// Mac's own and never vanish); the Mac's Remove deletes its grant. Two
    /// looks 30 s apart at the linked hub without it read as the same
    /// removal, and what the wipe dropped is reported.
    func testAGrantGoneOnTwoLooksThirtySecondsApartIsTheMacsRemove() async throws {
        let model = try await linkedModel(code())
        XCTAssertEqual(model.link?.deviceID, identity.deviceID, "the link keeps the id it linked with")
        XCTAssertEqual(model.link?.linkedAt, start, "and the grant's linked_at")
        host.notSentCount = 2

        await model.evaluate(grant: grant(linked: true), heartbeat: laterHeartbeat)
        await model.evaluate(grant: nil, heartbeat: laterHeartbeat)
        XCTAssertNotNil(LinkStore(defaults: defaults).grantMissingSince)
        clock.advance(by: LinkingViewModel.removalConfirmAfter - 1)
        await model.evaluate(grant: nil, heartbeat: laterHeartbeat)
        assertStillLinked(model, "under 30 s since the first look")

        clock.advance(by: 1)
        await model.evaluate(grant: nil, heartbeat: laterHeartbeat)

        XCTAssertEqual(model.notice, .removed(notSent: 2))
        XCTAssertEqual(
            LinkNotice.removed(notSent: 2).message,
            "This Mac removed this phone — Not sent: 2 items were still waiting for your Mac"
        )
        XCTAssertNil(model.link)
        XCTAssertEqual(host.wipes, 1)
        XCTAssertNil(LinkStore(defaults: defaults).grantMissingSince)
        let writes = try await host.deviceWrites()
        XCTAssertNil(writes.last?.unlinked, "removed, not unlinking itself: nothing to write")
    }

    func testAnUnlinkedGrantOfTheLinkedHubCountsAsGone() async throws {
        let model = try await modelOneLookFromRemoval()
        await model.evaluate(grant: grant(linked: false, refused: .usedCode), heartbeat: laterHeartbeat)
        XCTAssertEqual(model.notice, .removed())
    }

    func testTheFirstLookSurvivesARelaunch() async throws {
        _ = try await modelOneLookFromRemoval()
        let relaunched = makeModel()
        await relaunched.evaluate(grant: nil, heartbeat: laterHeartbeat)
        XCTAssertEqual(relaunched.notice, .removed())
    }

    func testAGrantSeenAgainClearsTheFirstLook() async throws {
        let model = try await modelOneLookFromRemoval()
        await model.evaluate(grant: grant(linked: true), heartbeat: laterHeartbeat)
        XCTAssertNil(LinkStore(defaults: defaults).grantMissingSince)
        await model.evaluate(grant: nil, heartbeat: laterHeartbeat)
        assertStillLinked(model, "a new first look, not the second")
    }

    func testNoRemovalWithoutAHeartbeatNewerThanTheLink() async throws {
        let model = try await modelOneLookFromRemoval()
        await model.evaluate(grant: nil, heartbeat: nil)
        assertStillLinked(model, "no heartbeat: the replica may not hold the hub's zone")
        await model.evaluate(grant: nil, heartbeat: heartbeat(updatedAt: start))
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
        XCTAssertNil(LinkStore(defaults: defaults).grantMissingSince, why, line: line)
        await model.evaluate(grant: nil, heartbeat: laterHeartbeat)
        assertStillLinked(model, why, line: line)
    }

    func testALinkedGrantWithoutAHeartbeatClearsTheFirstLook() async throws {
        try await assertALinkedGrantClearsTheFirstLook("no heartbeat in that fetch") { model in
            await model.evaluate(grant: self.grant(linked: true), heartbeat: nil)
        }
    }

    func testALinkedGrantWithAnotherHubsHeartbeatClearsTheFirstLook() async throws {
        try await assertALinkedGrantClearsTheFirstLook("another hub's heartbeat in that fetch") { model in
            let other = self.heartbeat(hubID: "hub-studio", macName: "Acme Studio", updatedAt: self.start.addingTimeInterval(60))
            await model.evaluate(grant: self.grant(linked: true), heartbeat: other)
        }
    }

    func testALinkedGrantWithAnOlderHeartbeatClearsTheFirstLook() async throws {
        try await assertALinkedGrantClearsTheFirstLook("a heartbeat from before the link") { model in
            await model.evaluate(grant: self.grant(linked: true), heartbeat: self.heartbeat(updatedAt: self.start))
        }
    }

    func testALinkedGrantWhileALinkIsPendingClearsTheFirstLook() async throws {
        try await assertALinkedGrantClearsTheFirstLook("a pending link") { model in
            let store = LinkStore(defaults: self.defaults)
            store.pending = PendingLink(link: self.linkRecord(), deadline: self.start.addingTimeInterval(600), baseline: nil, baselineCaptured: false)
            await model.evaluate(grant: self.grant(linked: true), heartbeat: self.laterHeartbeat)
            store.pending = nil
        }
    }

    func testALinkedGrantWhileAScanRunsClearsTheFirstLook() async throws {
        try await assertALinkedGrantClearsTheFirstLook("a scan running") { model in
            // E2E (I-1): the Mac keeps answering linked, so this re-scan of the linked hub ends as "Linked"
            // with nothing written; one without a linked keybox would be a re-pair that ends the link.
            self.host.parksFetchGrant = true
            let scan = Task { await model.open(self.code().url()) }
            try await self.poll({ model.isBusy }, "the scan is checking")
            await model.evaluate(grant: self.grant(linked: true), heartbeat: self.laterHeartbeat)
            scan.cancel()
            self.host.parksFetchGrant = false
            _ = await scan.value
        }
    }

    func testNoRemovalFromAnotherHubsHeartbeatOrGrant() async throws {
        let model = try await modelOneLookFromRemoval()
        await model.evaluate(grant: nil, heartbeat: heartbeat(hubID: "hub-studio", macName: "Acme Studio", updatedAt: start.addingTimeInterval(60)))
        assertStillLinked(model, "another hub's heartbeat")
        await model.evaluate(grant: grant(hubID: "hub-studio", linked: false), heartbeat: laterHeartbeat)
        assertStillLinked(model, "another hub's grant")
    }

    func testNoRemovalFromAnotherDevicesGrant() async throws {
        let model = try await modelOneLookFromRemoval()
        let other = DeviceGrant(
            deviceID: "device-other", hubID: "hub-acme", name: "Other", scope: .private, linked: false,
            typingAllowed: false, startSessionsAllowed: true
        )
        await model.evaluate(grant: other, heartbeat: laterHeartbeat)
        assertStillLinked(model, "not the grant of the id this phone linked with")
    }

    /// A link saved before the device id and `linked_at` were kept never
    /// reads a removal.
    func testALinkWithoutItsDeviceIDOrLinkTimeNeverReadsARemoval() async throws {
        var old = linkRecord()
        old.linkedAt = start
        LinkStore(defaults: defaults).link = old
        let noID = makeModel()
        await noID.evaluate(grant: nil, heartbeat: laterHeartbeat)
        clock.advance(by: LinkingViewModel.removalConfirmAfter)
        await noID.evaluate(grant: nil, heartbeat: laterHeartbeat)
        assertStillLinked(noID, "no device id")

        old.linkedAt = nil
        old.deviceID = identity.deviceID
        LinkStore(defaults: defaults).link = old
        let noTime = makeModel()
        await noTime.evaluate(grant: nil, heartbeat: laterHeartbeat)
        clock.advance(by: LinkingViewModel.removalConfirmAfter)
        await noTime.evaluate(grant: nil, heartbeat: laterHeartbeat)
        assertStillLinked(noTime, "no link time")
    }

    func testNoRemovalWhileALinkIsPending() async throws {
        let model = try await modelOneLookFromRemoval()
        LinkStore(defaults: defaults).pending = PendingLink(
            link: linkRecord(), deadline: start.addingTimeInterval(600), baseline: nil, baselineCaptured: false
        )
        await model.evaluate(grant: nil, heartbeat: laterHeartbeat)
        assertStillLinked(model, "a pending link")
    }

    func testNoRemovalWhileAScanRuns() async throws {
        let model = try await modelOneLookFromRemoval()
        host.mac = { _ in nil }
        host.parksFetchGrant = true
        let scan = Task { await model.open(self.code().url()) }
        try await poll({ model.isBusy }, "the scan is checking")
        await model.evaluate(grant: nil, heartbeat: laterHeartbeat)
        assertStillLinked(model, "a scan running")
        scan.cancel()
        host.parksFetchGrant = false
        _ = await scan.value
    }

    func testHubChangedShowsMovedAndStopsWrites() async throws {
        let model = try await linkedModel(code())

        await model.evaluate(heartbeat: heartbeat(hubID: studio, macName: "Acme Studio", updatedAt: start))

        XCTAssertEqual(model.notice, .moved(macName: "Acme Studio"))
        XCTAssertEqual(LinkNotice.moved(macName: "Acme Studio").message, "Watchtower moved to Acme Studio — scan the code on that Mac")
        XCTAssertEqual(host.links.last?.writesAllowed, false, "its writes are not sent")
        XCTAssertNotNil(host.links.last?.device, "still linked, so Settings still shows the Mac")
        XCTAssertEqual(host.wipes, 0)
        let callsAfterMove = host.links.count

        // The same heartbeat again changes nothing.
        await model.evaluate(heartbeat: heartbeat(hubID: studio, macName: "Acme Studio", updatedAt: start))
        XCTAssertEqual(host.links.count, callsAfterMove)

        // The linked hub takes back over: writes flow again.
        await model.evaluate(heartbeat: heartbeat(hubID: acme, macName: "Acme Mac", updatedAt: start))
        XCTAssertNil(model.notice)
        XCTAssertEqual(host.links.last?.writesAllowed, true)
    }

    func testHeartbeatStaleForADayShowsTheStaleNotice() async throws {
        let model = try await linkedModel(code())

        await model.evaluate(heartbeat: heartbeat(updatedAt: start.addingTimeInterval(-86_399)))
        XCTAssertNil(model.notice, "under a day is only offline")

        await model.evaluate(heartbeat: heartbeat(updatedAt: start.addingTimeInterval(-86_400)))
        XCTAssertEqual(model.notice, .stale)
        XCTAssertEqual(LinkNotice.stale.message, "Your Mac hasn't synced for a day — if it changed iCloud account, link again")
        XCTAssertEqual(host.links.last?.writesAllowed, true, "a stale Mac still gets the queue")

        await model.evaluate(heartbeat: heartbeat(updatedAt: start))
        XCTAssertNil(model.notice)
    }

    private func heartbeat(hubID: String = acme, macName: String = "Acme Mac", updatedAt: Date) -> HeartbeatPayload {
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

    // MARK: - Switch Mac

    func testScanningAnotherMacAsksToSwitchAndNoKeepsTheOldLink() async throws {
        let model = try await linkedModel(code())
        let other = code(hubID: studio, macName: "Acme Studio")
        macLinks(other)

        await model.open(other.url())

        XCTAssertEqual(model.phase, .confirmSwitch(from: "Acme Mac", to: "Acme Studio"))
        XCTAssertEqual(LinkingViewModel.switchPrompt(from: "Acme Mac", to: "Acme Studio"), "Switch from Acme Mac to Acme Studio?")

        await model.confirmSwitch(false)

        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.link?.hubID, acme)
        let writes = try await host.deviceWrites()
        XCTAssertEqual(writes.count, 1, "nothing written for the other Mac")
        XCTAssertEqual(host.wipes, 0)
    }

    func testSwitchYesUnlinksTheOldMacThenLinksTheNewOne() async throws {
        let model = try await linkedModel(code())
        let other = code(hubID: studio, macName: "Acme Studio")
        macLinks(other)

        await model.open(other.url())
        await model.confirmSwitch(true)

        let writes = try await host.deviceWrites(in: .private)
        XCTAssertEqual(writes.map(\.unlinked), [nil, true, nil], "link, unlink the old Mac, link the new one")
        XCTAssertEqual(writes.last?.linkNonce, other.nonce)
        XCTAssertEqual(host.wipes, 2, "the unlink wipes the old Mac's queue, then restarts unlinked")
        XCTAssertEqual(model.phase, .linked(macName: "Acme Studio"))
        XCTAssertEqual(model.link?.hubID, studio)
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
        XCTAssertEqual(openedModel.link?.hubID, scannedModel.link?.hubID)
    }

    /// A second code arriving while a link is running is ignored.
    func testACodeArrivingMidLinkIsIgnored() async throws {
        clock.parked = true
        let model = makeModel()
        let flow = Task { await model.open(code().url()) }
        try await poll { model.phase == .waiting(macName: "Acme Mac") }

        await model.open(code(hubID: studio, macName: "Acme Studio").url())

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
            (.local("disk I/O error"), "Couldn't set up sync on this iPhone", "disk I/O error")
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

    // MARK: - E2E pairing (mobile E2E spec §2.3, Task 16)

    /// A v3 scan stores the hub's keys from the code (no meta key, no epochs
    /// yet), writes the hello sealed to the hub on a fresh replica, and shows
    /// the four-digit code: the Mac opens the hello with its key and computes
    /// the same code from it.
    func testAV3ScanWritesASealedHelloAndShowsTheCode() async throws {
        clock.parked = true
        let model = makeModel()
        let payload = code()
        host.mac = { [start] writes in
            guard writes.contains(where: { $0.linkNonce == payload.nonce }) else { return nil }
            return DeviceGrant(
                deviceID: TestE2E.deviceID.uuidString, hubID: acme, name: "iPhone", scope: .private, linked: false,
                typingAllowed: false, startSessionsAllowed: true, decidedAt: start, awaitingConfirmation: true,
                confirmNonce: TestPhone.confirmNonceText)
        }
        let flow = Task { await model.open(payload.url()) }
        try await poll { model.phase == .waiting(macName: "Acme Mac") && model.linkCode != nil }

        let sealed = await host.transport(for: .private).sealed
        XCTAssertEqual(sealed.map(\.recordName), ["hello-\(TestE2E.deviceID.uuidString)"], "D7: named by the key-derived id")
        XCTAssertEqual(sealed.first?.kind, WireKind.envelope, "sealed, the kind inside")
        let opened = try TestPhone.openHello(try XCTUnwrap(sealed.first), code: payload)
        XCTAssertEqual(opened.hello.device.linkNonce, payload.nonce)
        XCTAssertEqual(opened.hello.device.deviceID, TestE2E.deviceID.uuidString)
        XCTAssertEqual(model.linkCode, opened.sas, "the phone shows the code the Mac computes")
        let steps = LinkStepsModel(waitingFor: "Acme Mac", code: model.linkCode, waited: 0)
        XCTAssertEqual(steps.codeInstruction, "Check that your Mac shows **\(opened.sas)**, then click Link on the Mac.")

        let stored = try XCTUnwrap(try keyStore.hubLink(acme))
        XCTAssertEqual(stored.hubSigningKey, TestE2E.hubSigningKey.publicKey.rawRepresentation)
        XCTAssertEqual(stored.hubAgreementKey, TestE2E.hubAgreementKey.publicKey.rawRepresentation)
        XCTAssertEqual(stored.linkNonce, WireBytes.fromBase64URL(payload.nonce), "the nonce bytes the hub decodes")
        XCTAssertNil(stored.metaKey, "no keys before the keybox")
        XCTAssertEqual(stored.epochs, [])
        XCTAssertEqual(host.preparedFresh, [true], "a new pairing starts on an empty replica")
        XCTAssertNil(model.link)
        flow.cancel()
        await flow.value
    }

    /// Pairing code v2: the code hashes the hub's confirm nonce, which the Mac draws after it accepted the hello and
    /// sends in the waiting keybox. Before it arrives the phone shows no code (a waiting keybox without one says the
    /// Mac sees this iPhone, still no code); a new nonce (the request replaced) changes the code.
    func testThePhoneShowsNoCodeBeforeTheHubsNonceArrives() async throws {
        let model = makeModel()
        let payload = code()
        let seen = LinkEventLog()
        let other = WireBytes.base64URL(Data(repeating: 0x33, count: KeyDerivation.confirmNonceLength))
        host.mac = { [weak model, start] writes in
            guard writes.contains(where: { $0.linkNonce == payload.nonce }) else { return nil }
            seen.append(model?.linkCode ?? "-")
            let fetch = seen.events.count
            // Fetches 1–2: waiting, no nonce yet; 3–4: the nonce; 5: a malformed one (no code); 6: a new nonce
            // (the request replaced); 7: refused.
            let nonce: String? = switch fetch {
            case 1 ... 2: nil
            case 3 ... 4: TestPhone.confirmNonceText
            case 5: "not-a-nonce"
            default: other
            }
            return DeviceGrant(
                deviceID: TestE2E.deviceID.uuidString, hubID: acme, name: "iPhone", scope: .private, linked: false,
                linkRefused: fetch >= 7 ? .notConfirmed : nil, typingAllowed: false, startSessionsAllowed: true,
                decidedAt: start, awaitingConfirmation: fetch >= 7 ? nil : true, confirmNonce: fetch >= 7 ? nil : nonce)
        }

        await model.open(payload.url())

        let sealed = await host.transport(for: .private).sealed
        let hello = try XCTUnwrap(sealed.first)
        let first = try TestPhone.openHello(hello, code: payload).sas
        let second = try TestPhone.openHello(
            hello, code: payload, confirmNonce: try XCTUnwrap(WireBytes.fromBase64URL(other))).sas
        // What the phone showed when each fetch ran (the previous fetch's answer).
        XCTAssertEqual(seen.events, ["-", "-", "-", first, first, "-", second])
        XCTAssertEqual(model.phase, .failed(.refused))
        XCTAssertNil(model.linkCode)
        XCTAssertNil(ScannedHubKeys.confirmNonce(from: "not-a-nonce"))
        XCTAssertNil(ScannedHubKeys.confirmNonce(from: WireBytes.base64URL(Data(count: 16))), "32 bytes only")
    }

    /// The same code scanned again: the hello is unchanged, so the Mac keeps the request and its nonce, and the
    /// waiting keybox equals the scan's baseline. It still gives the code (never a refusal or a link, though).
    func testAWaitingKeyboxAlreadyInTheBaselineStillGivesTheCode() async throws {
        clock.parked = true
        let model = makeModel()
        let payload = code()
        host.mac = { [start] _ in
            DeviceGrant(
                deviceID: TestE2E.deviceID.uuidString, hubID: acme, name: "iPhone", scope: .private, linked: false,
                typingAllowed: false, startSessionsAllowed: true, decidedAt: start, awaitingConfirmation: true,
                confirmNonce: TestPhone.confirmNonceText)
        }
        let flow = Task { await model.open(payload.url()) }
        try await poll { model.phase == .waiting(macName: "Acme Mac") && model.linkCode != nil }

        let sealed = await host.transport(for: .private).sealed
        let hello = try XCTUnwrap(sealed.first)
        XCTAssertEqual(model.linkCode, try TestPhone.openHello(hello, code: payload).sas)
        XCTAssertNil(model.link)
        flow.cancel()
        await flow.value
    }

    /// The wait lasts until the code's exp + 120 s, polling every 2 s; once
    /// the keybox says the Mac waits for the owner, the phone says so.
    func testTheWaitLastsUntilTheCodeExpiresAndShowsMacSeesThisIPhone() async throws {
        let payload = code()
        let model = makeModel()
        let seen = LinkEventLog()
        let deviceID = TestE2E.deviceID.uuidString
        host.mac = { [weak model, start] writes in
            seen.append("\(model?.macSeesPhone ?? false)")
            guard writes.contains(where: { $0.linkNonce == payload.nonce }) else { return nil }
            return DeviceGrant(
                deviceID: deviceID, hubID: acme, name: "Colleague A's iPhone", scope: .private, linked: false,
                typingAllowed: false, startSessionsAllowed: true, decidedAt: start, awaitingConfirmation: true
            )
        }

        await model.open(payload.url())

        XCTAssertTrue(seen.events.contains("true"), "the waiting screen said the Mac sees this iPhone")
        XCTAssertEqual(model.phase, .failed(.noAnswer))
        XCTAssertGreaterThanOrEqual(clock.slept, 710, "exp (590 s ahead) + 120 s, not 60 s")
        XCTAssertLessThan(clock.slept, 712)
        XCTAssertEqual(LinkingViewModel.grantPollInterval, 2)
        XCTAssertGreaterThan(seen.events.count, 300, "a keybox fetch every 2 s")
        let steps = LinkStepsModel(waitingFor: "Acme Mac", code: "7342", macSeesPhone: true, waited: 0)
        XCTAssertEqual(steps.steps.map(\.text), ["Code read", "Your Mac sees this iPhone", "Linked"])
        XCTAssertEqual(steps.steps.map(\.state), [.done, .current, .todo])
    }

    /// The owner's Link: the keybox carries the epoch keys, stored with the
    /// code's hub keys; then the link is saved. A linked keybox without keys
    /// is not an answer yet.
    func testAConfirmedKeyboxStoresKeysAndLinks() async throws {
        let withoutKeys = code()
        macLinks(withoutKeys)
        host.keyboxKeys = nil
        let model = makeModel()
        await model.open(withoutKeys.url())
        XCTAssertEqual(model.phase, .failed(.noAnswer), "linked without keys: nothing to link with")
        XCTAssertNil(model.link)

        let payload = code()
        macLinks(payload)
        host.keyboxKeys = TestPhone.keyboxKeys(epoch: 1)
        await model.open(payload.url())

        XCTAssertEqual(model.phase, .linked(macName: "Acme Mac"))
        XCTAssertEqual(LinkStore(defaults: defaults).link?.hubID, acme, "the link is saved")
        let stored = try XCTUnwrap(try keyStore.hubLink(acme))
        XCTAssertEqual(stored.metaKey, TestE2E.metaKey.withUnsafeBytes { Data($0) })
        XCTAssertEqual(stored.epochs, [EpochKeys(
            epoch: 1,
            dataKey: TestE2E.dataKey(epoch: 1).withUnsafeBytes { Data($0) },
            alertKey: TestE2E.alertKey(epoch: 1).withUnsafeBytes { Data($0) }
        )])
        XCTAssertEqual(stored.hubSigningKey, TestE2E.hubSigningKey.publicKey.rawRepresentation, "the code's hub keys stay")
        XCTAssertEqual(stored.linkNonce, WireBytes.fromBase64URL(payload.nonce), "this scan's nonce")
        XCTAssertNil(model.linkCode)
        XCTAssertEqual(host.links.last?.device?.deviceID, TestE2E.deviceID.uuidString)
    }

    /// The owner refused (or closed the sheet): `not_confirmed` is a refusal
    /// like any other, and the scan's keys go.
    func testANotConfirmedRefusalShowsTheRefusal() async throws {
        let payload = code()
        host.mac = { [grant = grantMaker] writes in
            writes.contains { $0.linkNonce == payload.nonce } ? grant(acme, false, .notConfirmed) : nil
        }
        let model = makeModel()

        await model.open(payload.url())

        XCTAssertEqual(model.phase, .failed(.refused))
        XCTAssertNil(model.link)
        XCTAssertNil(try keyStore.hubLink(acme))
        XCTAssertNil(LinkStore(defaults: defaults).pending)
    }

    /// A v2 code comes from a Mac without encryption.
    func testAV2CodeReadsUpdateTheMac() async throws {
        let model = makeModel()

        await model.open(code(version: 2).url())

        XCTAssertEqual(model.phase, .failed(.updateMac))
        XCTAssertTrue(host.prepared.isEmpty)
        XCTAssertNil(try keyStore.hubLink(acme), "nothing stored for an old code")
    }

    /// A code whose hub id is not a UUID cannot be sealed to: refused before anything is written.
    func testACodeWithAHubIDThatIsNotAUUIDIsRefused() async throws {
        let model = makeModel()

        await model.open(code(hubID: "hub-acme").url())

        XCTAssertEqual(model.phase, .failed(.refused))
        XCTAssertTrue(host.prepared.isEmpty)
    }

    /// Cross-check with the hub: the phone maps the code to `KeyDerivation.sas` exactly as the hub does. The
    /// Kit's frozen vector (`WatchtowerKit/Tests/Fixtures/e2e/kdf.json`, "sas") is the value the hub computes for
    /// these synthetic keys (`MobileLinkCenter.handleHello`'s argument order).
    func testThePhonesCodeMatchesTheFrozenHubValue() throws {
        func sequence(_ from: UInt8, _ through: UInt8) -> Data { Data((Int(from)...Int(through)).map { UInt8($0) }) }
        let hubAgreement = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: sequence(0x01, 0x20))
        let deviceAgreement = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: sequence(0x21, 0x40))
        let hubSigning = try Curve25519.Signing.PrivateKey(rawRepresentation: sequence(0x41, 0x60))
        let deviceSigning = try Curve25519.Signing.PrivateKey(rawRepresentation: sequence(0x61, 0x80))
        let payload = LinkPayload(
            hubID: "00112233-4455-6677-8899-AABBCCDDEEFF", macName: "Acme Mac", ownerUser: owner,
            nonce: WireBytes.base64URL(sequence(0xA0, 0xBF)), iat: 0, exp: LinkPayload.lifetime,
            hubSigningKey: WireBytes.base64URL(hubSigning.publicKey.rawRepresentation),
            hubAgreementKey: WireBytes.base64URL(hubAgreement.publicKey.rawRepresentation)
        )

        let code = try ScannedHubKeys(payload).code(
            for: DeviceIdentityKeys(signing: deviceSigning, agreement: deviceAgreement), confirmNonce: sequence(0xE0, 0xFF))

        XCTAssertEqual(code, "3378")
    }

    /// Unlink and removal delete the hub's keys; the `unlinked` record was
    /// sealed with them first.
    func testUnlinkAndRemovalDeleteTheHubsKeys() async throws {
        let unlinked = try await linkedModel(code())
        XCTAssertNotNil(try keyStore.hubLink(acme))

        await unlinked.unlink()

        XCTAssertNil(try keyStore.hubLink(acme), "unlink deletes the hub's keys")
        XCTAssertNil(try keyStore.hubSigningKey(acme))
        let sealed = await host.transport(for: .private).sealed
        XCTAssertEqual(sealed.count, 2, "the hello and the sealed unlinked record")
        XCTAssertEqual(sealed.last?.kind, WireKind.envelope)

        let removed = try await linkedModel(code())
        XCTAssertNotNil(try keyStore.hubLink(acme))
        await removed.removedByMac()
        XCTAssertNil(try keyStore.hubLink(acme), "removal deletes them too")
    }

    /// After the link: a keybox with a new epoch adds its keys (the retired
    /// one kept), and a revoked keybox is the Mac removing this phone.
    func testALaterKeyboxAddsItsEpochAndARevokedOneRemovesThePhone() async throws {
        let model = try await linkedModel(code())
        host.keyboxKeys = KeyboxKeys(
            epoch: 2, dataKey: TestPhone.keyboxKeys(epoch: 2).dataKey, alertKey: TestPhone.keyboxKeys(epoch: 2).alertKey,
            metaKey: TestPhone.keyboxKeys().metaKey, previousEpoch: 1,
            previousDataKey: TestPhone.keyboxKeys(epoch: 1).dataKey, previousAlertKey: TestPhone.keyboxKeys(epoch: 1).alertKey
        )

        await model.keyboxChanged()

        XCTAssertEqual(try keyStore.hubLink(acme)?.epochs.map(\.epoch), [1, 2])
        XCTAssertNotNil(model.link)

        let deviceID = TestE2E.deviceID.uuidString
        host.mac = { [start] _ in
            DeviceGrant(
                deviceID: deviceID, hubID: acme, name: "Colleague A's iPhone", scope: .private, linked: false,
                typingAllowed: false, startSessionsAllowed: true, decidedAt: start, revoked: true
            )
        }
        await model.keyboxChanged()

        XCTAssertNil(model.link, "D9: a revoked keybox ends the link")
        XCTAssertEqual(model.notice, .removed())
        XCTAssertEqual(host.wipes, 1)
        XCTAssertNil(try keyStore.hubLink(acme))
    }

    /// Final review Phone I-1: the owner's natural recovery, scanning the Mac's code again while linked, merges
    /// the stored keybox's epoch keys the Keychain lacks (the signal that should have done it was lost) and has
    /// the stored rows indexed. The reconcile is idempotent: nothing missing, nothing written.
    func testAnAlreadyLinkedScanMergesKeyboxKeysTheKeychainLacks() async throws {
        let model = try await linkedModel(code())
        XCTAssertEqual(try keyStore.hubLink(acme)?.epochs.map(\.epoch), [1])
        host.keyboxKeys = KeyboxKeys(
            epoch: 2, dataKey: TestPhone.keyboxKeys(epoch: 2).dataKey, alertKey: TestPhone.keyboxKeys(epoch: 2).alertKey,
            metaKey: TestPhone.keyboxKeys().metaKey, previousEpoch: 1,
            previousDataKey: TestPhone.keyboxKeys(epoch: 1).dataKey, previousAlertKey: TestPhone.keyboxKeys(epoch: 1).alertKey
        )

        await model.open(code().url())

        XCTAssertEqual(model.phase, .linked(macName: "Acme Mac"))
        XCTAssertEqual(try keyStore.hubLink(acme)?.epochs.map(\.epoch), [1, 2])
        XCTAssertEqual(host.keyMerges, 1, "the stored rows are indexed after the merge")

        await model.reconcileKeyboxKeys()
        XCTAssertEqual(host.keyMerges, 1, "nothing missing: nothing written, nothing re-indexed")
    }

    /// A link saved before encryption has no hub keys: dropped at launch,
    /// with the re-scan notice; a link with keys stays.
    func testAV2LinkWithoutKeysIsDroppedWithTheReScanNotice() async throws {
        LinkStore(defaults: defaults).link = linkRecord()
        LinkStore(defaults: defaults).pending = PendingLink(
            link: linkRecord(hubID: studio), deadline: start.addingTimeInterval(60), baseline: nil, baselineCaptured: true
        )
        let model = makeModel()

        await model.dropUnencryptedLink()

        XCTAssertNil(model.link)
        XCTAssertNil(LinkStore(defaults: defaults).link)
        XCTAssertNil(LinkStore(defaults: defaults).pending, "a pending link without keys goes too")
        XCTAssertEqual(model.notice, .encryptionReScan)
        XCTAssertEqual(LinkNotice.encryptionReScan.message, "Watchtower now encrypts your data. Scan the code on your Mac again.")
        XCTAssertEqual(host.wipes, 1, "the old link's replica is wiped")

        try keyStore.saveHubLink(try ScannedHubKeys(code()).unconfirmedLink)
        LinkStore(defaults: defaults).link = linkRecord()
        let keyed = makeModel()
        await keyed.dropUnencryptedLink()
        XCTAssertNotNil(keyed.link, "a link with keys stays")
        XCTAssertEqual(host.wipes, 1)
    }

    // MARK: - Fix round 1 (Task 16 review)

    /// I-1: a scan of the linked Mac whose keybox does not say "linked" is a
    /// re-pair: the link ends first (its "Not sent" reported), and a refusal
    /// leaves the phone unlinked with no keys, never on tabs it cannot sync.
    func testARefusedRescanOfTheLinkedMacEndsTheLink() async throws {
        let model = try await linkedModel(code())
        let again = code()
        host.notSentCount = 2
        host.mac = { [grant = grantMaker] writes in
            writes.last?.linkNonce == again.nonce ? grant(acme, false, .notConfirmed) : nil
        }

        await model.open(again.url())

        XCTAssertEqual(model.phase, .failed(.refused))
        XCTAssertNil(model.link, "Welcome, not dead tabs")
        XCTAssertNil(LinkStore(defaults: defaults).link)
        XCTAssertNil(try keyStore.hubLink(acme), "the keys go with the link")
        XCTAssertEqual(model.notice, .notSent(2), "what the re-pair's wipe lost is reported")
        XCTAssertNil(host.links.last?.device)
    }

    func testATimedOutRescanOfTheLinkedMacEndsTheLink() async throws {
        let model = try await linkedModel(code())
        host.mac = { _ in nil }

        await model.open(code().url())

        XCTAssertEqual(model.phase, .failed(.noAnswer))
        XCTAssertNil(model.link)
        XCTAssertNil(LinkStore(defaults: defaults).link)
        XCTAssertNil(try keyStore.hubLink(acme))
        XCTAssertNil(try keyStore.hubSigningKey(acme))
    }

    /// M-3: a `linked` keybox decided before this code was issued (a stale
    /// link on the Mac's clock) is not this scan's confirmation: the Mac
    /// links at the owner's click, after the code's `iat`.
    func testAStaleLinkedKeyboxIsNotThisScansConfirmation() async throws {
        let payload = code()
        let deviceID = TestE2E.deviceID.uuidString
        let linkedAt = LinkEventLog()
        linkedAt.append("stale")
        host.mac = { [start] writes in
            guard writes.contains(where: { $0.linkNonce == payload.nonce }) else { return nil }
            let at = linkedAt.events.last == "stale" ? start.addingTimeInterval(-3_600) : start
            return DeviceGrant(
                deviceID: deviceID, hubID: acme, name: "Colleague A's iPhone", scope: .private, linked: true,
                linkedAt: at, typingAllowed: false, startSessionsAllowed: true, decidedAt: at
            )
        }
        let model = makeModel()

        await model.open(payload.url())

        XCTAssertEqual(model.phase, .failed(.noAnswer), "an older link is not the owner's Link on this code")
        XCTAssertNil(model.link)

        linkedAt.append("fresh")
        let fresh = code()
        let clickedAt = clock.now()
        host.mac = { writes in
            guard writes.contains(where: { $0.linkNonce == fresh.nonce }) else { return nil }
            return DeviceGrant(
                deviceID: deviceID, hubID: acme, name: "Colleague A's iPhone", scope: .private, linked: true,
                linkedAt: clickedAt, typingAllowed: false, startSessionsAllowed: true, decidedAt: clickedAt
            )
        }
        await model.open(fresh.url())
        XCTAssertEqual(model.phase, .linked(macName: "Acme Mac"))
    }

    /// M-2 (F14): a resumed wait never creates the device identity; without
    /// one it ends.
    func testAResumeWithoutTheDeviceIdentityEndsWithoutCreatingOne() async throws {
        keyStore = InMemoryPhoneKeyStore()
        host.keys = keyStore
        try keyStore.saveHubLink(try ScannedHubKeys(code()).unconfirmedLink)
        LinkStore(defaults: defaults).pending = PendingLink(
            link: linkRecord(), deadline: start.addingTimeInterval(300), baseline: nil, baselineCaptured: true
        )
        let model = makeModel()

        await model.resumePendingLink()

        XCTAssertEqual(model.phase, .failed(.noAnswer))
        XCTAssertNil(try keyStore.deviceID(), "no identity was created")
        XCTAssertNil(LinkStore(defaults: defaults).pending)
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
