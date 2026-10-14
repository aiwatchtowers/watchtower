import CloudKit
import CryptoKit
import Foundation
import WatchtowerE2ETesting
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// Hub ids are UUIDs since E2E: the test hub's, and other Macs.
private let acme = TestE2E.hubID.uuidString
private let homeID = "40E00000-0000-4000-8000-000000000004"
private let studio = "5D0D1000-0000-4000-8000-000000000002"
private let otherHub = "07E40000-0000-4000-8000-000000000003"
private let fifth = "F1F70000-0000-4000-8000-000000000005"

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
        XCTAssertEqual(host.preparedHubIDs, [acme], "the scan syncs the code's hub")
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
        XCTAssertTrue(model.links.isEmpty)
        XCTAssertTrue(host.linkedCalls.isEmpty, "never shown as linked")
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
        XCTAssertEqual(host.linkedCalls.last?.device.deviceID, identity.deviceID)
        XCTAssertEqual(host.activeHubID, acme, "the new Mac is on screen")
        XCTAssertEqual(host.rows.map(\.hubID), [acme], "the link is saved")
    }

    func testScanningTheSameCodeTwiceStaysLinkedWithoutASecondWrite() async throws {
        let payload = code()
        let model = try await linkedModel(payload)

        await model.open(payload.url())

        XCTAssertEqual(model.phase, .linked(macName: "Acme Mac"))
        XCTAssertEqual(model.links.map(\.hubID), [acme])
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
        XCTAssertEqual(pending.deadline, start.addingTimeInterval(710), "the code's exp + 120 s")

        // Relaunch 20 s later: 690 s of the wait are left.
        clock.parked = false
        clock.advance(by: 20)
        let relaunched = makeModel()
        XCTAssertTrue(relaunched.links.isEmpty, "a pending link is not a link")

        await relaunched.resumePendingLink()

        XCTAssertEqual(host.prepared.last, .shared(ownerName: owner), "the wait reads the scan's database")
        XCTAssertEqual(host.preparedHubIDs.last, acme, "and the scan's hub")
        XCTAssertEqual(relaunched.phase, .failed(.noAnswer))
        XCTAssertGreaterThanOrEqual(clock.slept, 690)
        XCTAssertLessThan(clock.slept, 692, "only the remaining part of the wait")
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
        XCTAssertEqual(pending.link.hubID, acme, "the relaunch resumes the scan's hub")

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
        XCTAssertEqual(model.links.first?.link, saved, "the pending link, with its grant's linked_at")
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

        XCTAssertEqual(host.removedHubIDs, [acme], "the hub and its replica are removed")
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
        let home = code(hubID: homeID, macName: "Home Mac")
        macLinks(home)
        await model.open(home.url())
        await model.finish()
        XCTAssertEqual(model.links.map(\.hubID), [acme, homeID])
        LinkStore(defaults: defaults).pending = PendingLink(
            link: linkRecord(hubID: studio), deadline: start.addingTimeInterval(600), baseline: nil, baselineCaptured: false
        )
        host.notSentCount = 2

        container.userRecordNameValue = "_colleague-b"
        await model.accountChanged()

        XCTAssertEqual(Set(host.removedHubIDs), [acme, homeID], "every hub goes")
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

        await model.unlink(acme)

        let writes = try await host.deviceWrites(in: .private)
        XCTAssertEqual(writes.last?.unlinked, true)
        XCTAssertEqual(
            Array(log.events.suffix(2)), ["remove \(acme)", "farewell private"],
            "the row goes first, then the farewell through the hub's own transport"
        )
        XCTAssertEqual(host.farewells.map(\.hubID), [acme])
        XCTAssertEqual(host.removedHubIDs, [acme], "one removal, no second wipe")
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

        await model.unlink(acme)

        XCTAssertEqual(model.notice, .recordingKept(macName: "Acme Mac", notSent: 2), "names the Mac whose link ended")
        XCTAssertEqual(
            LinkNotice.recordingKept(macName: "Acme Mac", notSent: 2).message,
            "The link to Acme Mac ended during a recording. It's saved on this iPhone and goes to Acme Mac after you link it again. "
                + "Not sent: 2 items were still waiting for your Mac"
        )
        XCTAssertEqual(
            LinkNotice.recordingKept(macName: nil, notSent: 0).message,
            "The link ended during a recording. It's saved on this iPhone and goes to your Mac after you link it again",
            "several links ended (an account change): no one Mac to name"
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

        await removed.removedByMac(acme)

        XCTAssertEqual(removed.notice, .removed(macName: "Acme Mac"), "nothing was wiped: the hub is frozen, not removed")
        XCTAssertTrue(host.removals.isEmpty)
        host.stopsRecording = false

        let switched = try await linkedModel(code(hubID: homeID, macName: "Home Mac"))
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

        await model.unlink(acme)

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

        await model.unlink(acme)

        XCTAssertEqual(container.left, [owner])
        XCTAssertEqual(container.leftHubIDs, [acme], "the linked hub's shares are left")
        XCTAssertEqual(host.farewells.map(\.hubID), [acme], "unlinked is written to the linked hub's zones")
        XCTAssertEqual(host.removedHubIDs, [acme], "board #70: one removal empties the queue")
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

        await model.unlink(acme)

        XCTAssertEqual(
            Array(log.events.suffix(3)),
            ["remove \(acme)", "farewell shared(\(owner))", "leave \(owner)"],
            "remove, write unlinked in the shared database, leave"
        )
        XCTAssertEqual(host.farewells.first?.scope, .shared(ownerName: owner))
        XCTAssertEqual(host.removals.map(\.keepRecordings), [true], "an unlink holds the hub's recordings")
    }

    // MARK: - Kept farewells (#143)

    /// A kept farewell of `hubID`, made on `account` at `since`.
    private func keptFarewell(
        _ hubID: String = acme, scope: CloudDatabaseScope = .private, account: String = "_colleague-a", since: Date? = nil
    ) -> PendingFarewell {
        PendingFarewell(
            hubID: hubID, scope: scope, userRecordName: account,
            record: CloudRecord(recordName: "wire-\(hubID)", zone: .relay, kind: "wt", modifiedAt: start, payload: Data([1])),
            since: since ?? start
        )
    }

    /// #143: a shared unlink whose farewell did not go out keeps the shares:
    /// the kept record still needs the Mac's zones.
    func testASharedUnlinkWhoseFarewellIsKeptKeepsTheShares() async throws {
        container.userRecordNameValue = "_colleague-a"
        let model = try await linkedModel(code())
        host.keepsFarewell = true

        await model.unlink(acme)

        XCTAssertEqual(host.removedHubIDs, [acme], "the hub goes all the same")
        XCTAssertTrue(container.left.isEmpty, "the shares wait for the kept farewell")
        XCTAssertEqual(model.phase, .idle)
    }

    /// #143: a kept farewell sent again at launch stops being kept, and its
    /// shared link leaves the shares then.
    func testAKeptFarewellSentAgainLeavesTheSharesAndIsNoLongerKept() async throws {
        container.userRecordNameValue = "_colleague-a"
        host.keptFarewells = [keptFarewell(scope: .shared(ownerName: owner))]
        host.resendSucceeds = true
        let model = makeModel()

        await model.retryFarewells()

        XCTAssertEqual(log.events, ["resend \(acme)", "leave \(owner)"])
        XCTAssertEqual(container.leftHubIDs, [acme])
        XCTAssertTrue(host.keptFarewells.isEmpty)
    }

    /// #143: a resend that fails keeps the farewell (and the shares) for the
    /// next launch.
    func testAKeptFarewellThatFailsAgainStaysKept() async throws {
        container.userRecordNameValue = "_colleague-a"
        host.keptFarewells = [keptFarewell(scope: .shared(ownerName: owner))]
        let model = makeModel()

        await model.retryFarewells()

        XCTAssertEqual(log.events, ["resend \(acme)"])
        XCTAssertTrue(container.left.isEmpty)
        XCTAssertEqual(host.keptFarewells.map(\.hubID), [acme])
    }

    /// #143: a farewell past its lifetime is dropped unsent and its shares
    /// are left; one of another iCloud account, or of a hub linked again,
    /// is dropped with its shares untouched.
    func testKeptFarewellsExpireOrAreDroppedForAnotherAccountOrARelink() async throws {
        container.userRecordNameValue = "_colleague-a"
        host.seed(LinkRecord(
            hubID: homeID, macName: "Home Mac", scope: .shared, ownerName: owner, userRecordName: "_colleague-a",
            nonce: "n", dataShareURL: nil, relayShareURL: nil, deviceID: nil, linkedAt: nil
        ))
        let expiredSince = start.addingTimeInterval(-LinkingViewModel.farewellLifetime - 1)
        host.keptFarewells = [
            keptFarewell(acme, scope: .shared(ownerName: owner), since: expiredSince),
            keptFarewell(homeID, scope: .shared(ownerName: owner)),
            keptFarewell(studio, scope: .shared(ownerName: owner), account: "_someone-else")
        ]
        host.resendSucceeds = true
        let model = makeModel()

        await model.retryFarewells()

        XCTAssertEqual(
            log.events,
            ["drop farewell \(acme)", "leave \(owner)", "drop farewell \(homeID)", "drop farewell \(studio)"],
            "nothing is sent again; only the expired one's shares are left"
        )
        XCTAssertEqual(container.leftHubIDs, [acme])
        XCTAssertTrue(host.keptFarewells.isEmpty)
    }

    /// Shares that could not be left: the hub is gone all the same (its
    /// files and its row), and the phone does nothing more for it.
    func testUnlinkInSharedScopeWhoseSharesStayStillRemovesTheHub() async throws {
        container.userRecordNameValue = "_colleague-a"
        let model = try await linkedModel(code())
        container.leaveError = CKError(.networkUnavailable)

        await model.unlink(acme)

        XCTAssertEqual(host.removedHubIDs, [acme])
        XCTAssertEqual(Array(log.events.suffix(2)), ["farewell shared(\(owner))", "leave \(owner)"])
        XCTAssertTrue(model.links.isEmpty)
        XCTAssertEqual(model.phase, .idle)
    }

    /// Leaving the shares makes the Mac's zones vanish: the transport's
    /// `unlinked` arriving meanwhile is the unlink's own, not a removal.
    func testRemovedArrivingDuringAnUnlinkIsIgnored() async throws {
        container.userRecordNameValue = "_colleague-a"
        let model = try await linkedModel(code())
        container.onLeave = { await model.removedByMac(acme) }

        await model.unlink(acme)

        XCTAssertEqual(host.removedHubIDs, [acme], "only the unlink's own removal")
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

        await model.unlink(acme)

        XCTAssertEqual(host.removedHubIDs, [acme], "only the unlink's own removal")
        XCTAssertEqual(host.removals.map(\.keepRecordings), [true], "one teardown")
        XCTAssertEqual(model.phase, .idle)
    }

    /// Forget on a hub the Mac removed: its files and row go, with no
    /// farewell and no share leave (its zones are gone).
    func testForgettingAFrozenHubRemovesItWithoutAFarewell() async throws {
        container.userRecordNameValue = "_colleague-a"
        let model = try await linkedModel(code())
        await model.removedByMac(acme)

        await model.forget(acme)

        XCTAssertEqual(host.removals.map(\.hubID), [acme])
        XCTAssertEqual(host.removals.map(\.keepRecordings), [true])
        XCTAssertTrue(host.farewells.isEmpty)
        XCTAssertTrue(container.left.isEmpty)
        XCTAssertTrue(model.links.isEmpty)
    }

    /// Forget on a long-offline linked hub is an unlink.
    func testForgettingALinkedHubIsAnUnlink() async throws {
        let model = try await linkedModel(code())

        await model.forget(acme)

        XCTAssertEqual(Array(log.events.suffix(2)), ["remove \(acme)", "farewell private"])
        XCTAssertTrue(model.links.isEmpty)
    }

    // MARK: - Several Macs (multi-hub spec §5.7)

    func testLinkingASecondMacAddsItAndMakesItActive() async throws {
        let model = try await linkedModel(code())
        let home = code(hubID: homeID, macName: "Home Mac")
        macLinks(home)

        await model.open(home.url())

        XCTAssertEqual(model.phase, .linked(macName: "Home Mac"), "no switch prompt")
        XCTAssertEqual(model.links.map(\.hubID), [acme, homeID])
        XCTAssertEqual(host.linkedCalls.map(\.record.hubID), [acme, homeID])
        XCTAssertEqual(host.activeHubID, homeID, "the new Mac becomes active")
        XCTAssertTrue(host.removals.isEmpty, "the first Mac stays linked")
        XCTAssertEqual(model.linkedDevice(for: acme)?.deviceID, identity.deviceID)
        XCTAssertEqual(model.linkedDevice(for: homeID)?.deviceID, identity.deviceID)
        XCTAssertNil(model.linkedDevice(for: studio))
    }

    func testAFifthMacIsRefusedBeforeAnyShareIsAccepted() async throws {
        for index in 1...HubRegistry.limit {
            host.seed(linkRecord(hubID: "hub-\(index)", macName: "Mac \(index)"))
        }
        container.userRecordNameValue = "_colleague-a"
        let model = makeModel()

        await model.open(code(hubID: fifth, macName: "Fifth Mac").url())

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
        XCTAssertEqual(host.row(acme)?.link.nonce, payload.nonce, "the row takes the new link")
        // E2E (I-1): a rescan of a linked Mac whose keybox does not say linked is a re-pair: its old link
        // (row, session, keys) ends first, so the slot it frees is the one the new link takes.
        XCTAssertEqual(host.removedHubIDs, [acme])
    }

    func testAFailedFirstLinkRemovesItsCandidate() async throws {
        let model = makeModel()

        await model.open(code().url())

        XCTAssertEqual(model.phase, .failed(.noAnswer))
        XCTAssertEqual(host.removals.map(\.hubID), [acme], "the candidate session and its files go")
        XCTAssertEqual(host.removals.map(\.keepRecordings), [true])
        XCTAssertTrue(host.rows.isEmpty)
    }

    /// E2E (I-1, replaces main's "a failed rescan of a linked Mac keeps it"):
    /// a rescan of a linked Mac whose keybox does not say "linked" is a
    /// re-pair, and the scan replaces that hub's keys, so a failed re-pair
    /// can never leave the old link standing on keys that no longer open
    /// its data: the link ends, its keys with it, and other hubs stay.
    func testAFailedRescanOfALinkedMacEndsOnlyThatLink() async throws {
        let model = try await linkedModel(code())
        let other = code(hubID: homeID, macName: "Home Mac")
        macLinks(other)
        await model.open(other.url())
        await model.finish()
        host.mac = { _ in nil }

        await model.open(code().url())

        XCTAssertEqual(model.phase, .failed(.noAnswer))
        XCTAssertEqual(host.removedHubIDs, [acme, acme], "the old link, then the failed candidate")
        XCTAssertEqual(model.links.map(\.hubID), [homeID], "the other Mac stays linked")
        XCTAssertNil(try keyStore.hubLink(acme))
        XCTAssertNotNil(try keyStore.hubLink(homeID), "the other Mac's keys stay")
    }

    /// A refusal and a failed write drop the candidate as well.
    func testARefusedOrUnwritableFirstLinkRemovesItsCandidate() async throws {
        host.mac = { [grant = grantMaker] writes in writes.isEmpty ? nil : grant(acme, false, .usedCode) }
        let refused = makeModel()
        await refused.open(code().url())
        XCTAssertEqual(refused.phase, .failed(.refused))
        XCTAssertEqual(host.removedHubIDs, [acme])

        host.prepareError = CocoaError(.fileWriteNoPermission)
        let unwritable = makeModel()
        await unwritable.open(code(hubID: homeID, macName: "Home Mac").url())
        XCTAssertEqual(host.removedHubIDs, [acme, homeID])
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

        await model.removedByMac(acme)

        XCTAssertEqual(host.markedRemoved, [acme])
        XCTAssertEqual(host.row(acme)?.state, .unlinkedByMac)
        XCTAssertEqual(model.links.first?.state, .unlinkedByMac)
        XCTAssertTrue(host.removals.isEmpty, "nothing is wiped")
        XCTAssertEqual(model.notice, .removed(macName: "Acme Mac"))
        XCTAssertEqual(LinkNotice.removed(macName: "Acme Mac").message, "Acme Mac removed this phone")
        let writes = try await host.deviceWrites()
        XCTAssertNil(writes.last?.unlinked, "the Mac's zones are gone: nothing to write")

        await model.removedByMac(acme)
        XCTAssertEqual(host.markedRemoved, [acme], "a frozen hub is frozen once")
    }

    func testRemovedWhileOfflineNamesTheMacAndLeavesTheOtherHub() async throws {
        container.userRecordNameValue = "_colleague-a"
        let model = try await linkedModel(code())
        let home = code(hubID: homeID, macName: "Home Mac")
        macLinks(home)
        await model.open(home.url())
        await model.finish()

        await model.removedByMac(acme)

        XCTAssertEqual(model.notice, .removed(macName: "Acme Mac"), "the removed Mac is named")
        XCTAssertEqual(host.row(homeID)?.state, .linked, "the other hub is untouched")
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
        await model.evaluate(hubID: acme, grant: nil, heartbeat: laterHeartbeat)
        XCTAssertEqual(model.links.first?.state, .linked, "one look is not enough")
        clock.advance(by: LinkingViewModel.removalConfirmAfter)
        return model
    }

    private func assertStillLinked(_ model: LinkingViewModel, _ why: String, line: UInt = #line) {
        XCTAssertEqual(host.row(acme)?.state, .linked, why, line: line)
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

        await model.evaluate(hubID: acme, grant: grant(linked: true), heartbeat: laterHeartbeat)
        await model.evaluate(hubID: acme, grant: nil, heartbeat: laterHeartbeat)
        XCTAssertEqual(host.row(acme)?.grantMissingSince, start, "the first look is kept on the hub's row")
        clock.advance(by: LinkingViewModel.removalConfirmAfter - 1)
        await model.evaluate(hubID: acme, grant: nil, heartbeat: laterHeartbeat)
        assertStillLinked(model, "under 30 s since the first look")

        clock.advance(by: 1)
        await model.evaluate(hubID: acme, grant: nil, heartbeat: laterHeartbeat)

        XCTAssertEqual(model.notice, .removed(macName: "Acme Mac"))
        XCTAssertEqual(
            LinkNotice.removed(macName: "Acme Mac", notSent: 2).message,
            "Acme Mac removed this phone — Not sent: 2 items were still waiting for your Mac"
        )
        XCTAssertEqual(host.markedRemoved, [acme])
        XCTAssertEqual(host.row(acme)?.state, .unlinkedByMac)
        XCTAssertTrue(host.removals.isEmpty, "frozen, not wiped")
        let writes = try await host.deviceWrites()
        XCTAssertNil(writes.last?.unlinked, "removed, not unlinking itself: nothing to write")
    }

    func testAnUnlinkedGrantOfTheLinkedHubCountsAsGone() async throws {
        let model = try await modelOneLookFromRemoval()
        await model.evaluate(hubID: acme, grant: grant(linked: false, refused: .usedCode), heartbeat: laterHeartbeat)
        XCTAssertEqual(model.notice, .removed(macName: "Acme Mac"))
    }

    func testTheFirstLookSurvivesARelaunch() async throws {
        _ = try await modelOneLookFromRemoval()
        let relaunched = makeModel()
        await relaunched.evaluate(hubID: acme, grant: nil, heartbeat: laterHeartbeat)
        XCTAssertEqual(relaunched.notice, .removed(macName: "Acme Mac"))
    }

    func testAGrantSeenAgainClearsTheFirstLook() async throws {
        let model = try await modelOneLookFromRemoval()
        await model.evaluate(hubID: acme, grant: grant(linked: true), heartbeat: laterHeartbeat)
        XCTAssertNil(host.row(acme)?.grantMissingSince)
        await model.evaluate(hubID: acme, grant: nil, heartbeat: laterHeartbeat)
        assertStillLinked(model, "a new first look, not the second")
    }

    func testNoRemovalWithoutAHeartbeatNewerThanTheLink() async throws {
        let model = try await modelOneLookFromRemoval()
        await model.evaluate(hubID: acme, grant: nil, heartbeat: nil)
        assertStillLinked(model, "no heartbeat: the replica may not hold the hub's zone")
        await model.evaluate(hubID: acme, grant: nil, heartbeat: heartbeat(updatedAt: start))
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
        XCTAssertNil(host.row(acme)?.grantMissingSince, why, line: line)
        await model.evaluate(hubID: acme, grant: nil, heartbeat: laterHeartbeat)
        assertStillLinked(model, why, line: line)
    }

    func testALinkedGrantWithoutAHeartbeatClearsTheFirstLook() async throws {
        try await assertALinkedGrantClearsTheFirstLook("no heartbeat in that fetch") { model in
            await model.evaluate(hubID: acme, grant: self.grant(linked: true), heartbeat: nil)
        }
    }

    func testALinkedGrantWithAnotherHubsHeartbeatClearsTheFirstLook() async throws {
        try await assertALinkedGrantClearsTheFirstLook("another hub's heartbeat in that fetch") { model in
            let other = self.heartbeat(hubID: studio, macName: "Acme Studio", updatedAt: self.start.addingTimeInterval(60))
            await model.evaluate(hubID: acme, grant: self.grant(linked: true), heartbeat: other)
        }
    }

    func testALinkedGrantWithAnOlderHeartbeatClearsTheFirstLook() async throws {
        try await assertALinkedGrantClearsTheFirstLook("a heartbeat from before the link") { model in
            await model.evaluate(hubID: acme, grant: self.grant(linked: true), heartbeat: self.heartbeat(updatedAt: self.start))
        }
    }

    func testALinkedGrantWhileALinkIsPendingClearsTheFirstLook() async throws {
        try await assertALinkedGrantClearsTheFirstLook("a pending link") { model in
            let store = LinkStore(defaults: self.defaults)
            store.pending = PendingLink(link: self.linkRecord(), deadline: self.start.addingTimeInterval(600), baseline: nil, baselineCaptured: false)
            await model.evaluate(hubID: acme, grant: self.grant(linked: true), heartbeat: self.laterHeartbeat)
            store.pending = nil
        }
    }

    func testALinkedGrantWhileAScanRunsClearsTheFirstLook() async throws {
        try await assertALinkedGrantClearsTheFirstLook("a scan running") { model in
            self.host.mac = { _ in nil }
            self.host.parksFetchGrant = true
            let scan = Task { await model.open(self.code(hubID: homeID, macName: "Home Mac").url()) }
            try await self.poll({ model.isBusy }, "the scan is checking")
            await model.evaluate(hubID: acme, grant: self.grant(linked: true), heartbeat: self.laterHeartbeat)
            scan.cancel()
            self.host.parksFetchGrant = false
            _ = await scan.value
        }
    }

    func testNoRemovalFromAnotherHubsHeartbeatOrGrant() async throws {
        let model = try await modelOneLookFromRemoval()
        await model.evaluate(
            hubID: acme, grant: nil, heartbeat: heartbeat(hubID: studio, macName: "Acme Studio", updatedAt: start.addingTimeInterval(60))
        )
        assertStillLinked(model, "another hub's heartbeat")
        await model.evaluate(hubID: acme, grant: grant(hubID: studio, linked: false), heartbeat: laterHeartbeat)
        assertStillLinked(model, "another hub's grant")
    }

    func testNoRemovalFromAnotherDevicesGrant() async throws {
        let model = try await modelOneLookFromRemoval()
        let other = DeviceGrant(
            deviceID: "device-other", hubID: acme, name: "Other", scope: .private, linked: false,
            typingAllowed: false, startSessionsAllowed: true
        )
        await model.evaluate(hubID: acme, grant: other, heartbeat: laterHeartbeat)
        assertStillLinked(model, "not the grant of the id this phone linked with")
    }

    /// A link saved before the device id and `linked_at` were kept never
    /// reads a removal.
    func testALinkWithoutItsDeviceIDOrLinkTimeNeverReadsARemoval() async throws {
        var old = linkRecord()
        old.linkedAt = start
        host.seed(old)
        let noID = makeModel()
        await noID.evaluate(hubID: acme, grant: nil, heartbeat: laterHeartbeat)
        clock.advance(by: LinkingViewModel.removalConfirmAfter)
        await noID.evaluate(hubID: acme, grant: nil, heartbeat: laterHeartbeat)
        assertStillLinked(noID, "no device id")

        host = FakeLinkHost(log: log)
        old.linkedAt = nil
        old.deviceID = identity.deviceID
        host.seed(old)
        let noTime = makeModel()
        await noTime.evaluate(hubID: acme, grant: nil, heartbeat: laterHeartbeat)
        clock.advance(by: LinkingViewModel.removalConfirmAfter)
        await noTime.evaluate(hubID: acme, grant: nil, heartbeat: laterHeartbeat)
        assertStillLinked(noTime, "no link time")
    }

    func testNoRemovalWhileALinkIsPending() async throws {
        let model = try await modelOneLookFromRemoval()
        LinkStore(defaults: defaults).pending = PendingLink(
            link: linkRecord(), deadline: start.addingTimeInterval(600), baseline: nil, baselineCaptured: false
        )
        await model.evaluate(hubID: acme, grant: nil, heartbeat: laterHeartbeat)
        assertStillLinked(model, "a pending link")
    }

    func testNoRemovalWhileAScanRuns() async throws {
        let model = try await modelOneLookFromRemoval()
        host.mac = { _ in nil }
        host.parksFetchGrant = true
        let scan = Task { await model.open(self.code(hubID: homeID, macName: "Home Mac").url()) }
        try await poll({ model.isBusy }, "the scan is checking")
        await model.evaluate(hubID: acme, grant: nil, heartbeat: laterHeartbeat)
        assertStillLinked(model, "a scan running")
        scan.cancel()
        host.parksFetchGrant = false
        _ = await scan.value
    }

    /// Review Focus 4 at the flow: the removal check of one hub reads that
    /// hub's row and freezes only it.
    func testTheRemovalCheckOfOneHubLeavesTheOtherAlone() async throws {
        let model = try await linkedModel(code())
        let home = code(hubID: homeID, macName: "Home Mac")
        macLinks(home)
        await model.open(home.url())
        await model.finish()
        let homeLater = heartbeat(hubID: homeID, macName: "Home Mac", updatedAt: start.addingTimeInterval(60))

        await model.evaluate(hubID: homeID, grant: nil, heartbeat: homeLater)
        clock.advance(by: LinkingViewModel.removalConfirmAfter)
        await model.evaluate(hubID: acme, grant: nil, heartbeat: laterHeartbeat)
        XCTAssertTrue(host.markedRemoved.isEmpty, "hub-acme's first look is its own")
        await model.evaluate(hubID: homeID, grant: nil, heartbeat: homeLater)

        XCTAssertEqual(host.markedRemoved, [homeID])
        XCTAssertEqual(host.row(acme)?.state, .linked)
        XCTAssertEqual(model.notice, .removed(macName: "Home Mac"))
    }

    func testHeartbeatStaleForADayShowsTheStaleNotice() async throws {
        let model = try await linkedModel(code())

        await model.evaluate(hubID: acme, heartbeat: heartbeat(updatedAt: start.addingTimeInterval(-86_399)), isActive: true)
        XCTAssertNil(model.notice, "under a day is only offline")

        await model.evaluate(hubID: acme, heartbeat: heartbeat(updatedAt: start.addingTimeInterval(-86_400)), isActive: true)
        XCTAssertEqual(model.notice, .stale(macName: "Acme Mac"))
        XCTAssertEqual(
            LinkNotice.stale(macName: "Acme Mac").message,
            "Acme Mac hasn't synced for a day — if it changed iCloud account, link again"
        )
        XCTAssertTrue(host.markedRemoved.isEmpty && host.removals.isEmpty, "a stale Mac keeps its link and its queue")

        await model.evaluate(hubID: acme, heartbeat: heartbeat(updatedAt: start), isActive: true)
        XCTAssertNil(model.notice)
    }

    func testStaleNoticeOnlyForTheActiveHub() async throws {
        let model = try await linkedModel(code())
        let stale = heartbeat(updatedAt: start.addingTimeInterval(-86_400))

        await model.evaluate(hubID: acme, heartbeat: stale, isActive: false)
        XCTAssertNil(model.notice, "an inactive hub's heartbeat says nothing about the hub on screen")

        await model.evaluate(hubID: acme, heartbeat: stale, isActive: true)
        XCTAssertEqual(model.notice, .stale(macName: "Acme Mac"))

        await model.evaluate(hubID: acme, heartbeat: heartbeat(updatedAt: start), isActive: false)
        XCTAssertEqual(model.notice, .stale(macName: "Acme Mac"), "only the active hub's fetch clears it")
    }

    /// A switch re-evaluates the stale notice for the hub it puts on screen,
    /// with no fetch: one Mac's notice never shows over another, a stale
    /// one is named, and a hub with no heartbeat read yet clears it. A
    /// report of what a link lost is left alone.
    func testASwitchReevaluatesTheStaleNoticeForTheNewHub() async throws {
        let model = try await linkedModel(code())
        let home = code(hubID: homeID, macName: "Home Mac")
        macLinks(home)
        await model.open(home.url())
        await model.finish()
        let staleAcme = heartbeat(updatedAt: start.addingTimeInterval(-86_400))
        await model.evaluate(hubID: acme, heartbeat: staleAcme, isActive: true)
        XCTAssertEqual(model.notice, .stale(macName: "Acme Mac"))

        model.activated(hubID: homeID, heartbeat: heartbeat(hubID: homeID, macName: "Home Mac", updatedAt: start))
        XCTAssertNil(model.notice, "the healthy Mac on screen shows no stale notice")

        model.activated(
            hubID: homeID, heartbeat: heartbeat(hubID: homeID, macName: "Home Mac", updatedAt: start.addingTimeInterval(-90_000))
        )
        XCTAssertEqual(model.notice, .stale(macName: "Home Mac"), "named for the Mac on screen")

        model.activated(hubID: acme, heartbeat: nil)
        XCTAssertNil(model.notice, "no heartbeat read yet: nothing to say")

        host.notSentCount = 1
        await model.unlink(homeID)
        XCTAssertEqual(model.notice, .notSent(1))
        model.activated(hubID: acme, heartbeat: staleAcme)
        XCTAssertEqual(model.notice, .notSent(1), "a report of what a link lost stays until read")
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

    // MARK: - E2E pairing (mobile E2E spec §2.3, Task 16)

    /// A v3 scan stores the hub's keys from the code (no meta key, no epochs
    /// yet), writes the hello sealed to the hub on a fresh replica, and shows
    /// the four-digit code: the Mac opens the hello with its key and computes
    /// the same code from it.
    func testAV3ScanWritesASealedHelloAndShowsTheCode() async throws {
        clock.parked = true
        let model = makeModel()
        let payload = code()
        let tag = try TestPhone.linkCodeTag(payload)
        host.mac = { [start] writes in
            guard writes.contains(where: { $0.linkNonce == payload.nonce }) else { return nil }
            return DeviceGrant(
                deviceID: TestE2E.deviceID.uuidString, hubID: acme, name: "iPhone", scope: .private, linked: false,
                typingAllowed: false, startSessionsAllowed: true, decidedAt: start, awaitingConfirmation: true,
                confirmNonce: TestPhone.confirmNonceText, linkCodeTag: tag)
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
        XCTAssertTrue(model.links.isEmpty)
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
        let tag = try TestPhone.linkCodeTag(payload)
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
                decidedAt: start, awaitingConfirmation: fetch >= 7 ? nil : true, confirmNonce: fetch >= 7 ? nil : nonce,
                linkCodeTag: fetch >= 7 ? nil : tag)
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

    /// Re-review: the same QR scanned again re-sends an unchanged hello, so the Mac keeps the request, its nonce
    /// and its code, and the waiting keybox equals the scan's baseline. It names this scan's link code, so the
    /// phone still shows the code the Mac shows.
    func testTheSameQRScannedAgainShowsTheMacsCode() async throws {
        clock.parked = true
        let model = makeModel()
        let payload = code()
        let tag = try TestPhone.linkCodeTag(payload)
        host.mac = { [start] _ in
            DeviceGrant(
                deviceID: TestE2E.deviceID.uuidString, hubID: acme, name: "iPhone", scope: .private, linked: false,
                typingAllowed: false, startSessionsAllowed: true, decidedAt: start, awaitingConfirmation: true,
                confirmNonce: TestPhone.confirmNonceText, linkCodeTag: tag)
        }
        let flow = Task { await model.open(payload.url()) }
        try await poll { model.phase == .waiting(macName: "Acme Mac") && model.linkCode != nil }

        let sealed = await host.transport(for: .private).sealed
        XCTAssertEqual(model.linkCode, try TestPhone.openHello(try XCTUnwrap(sealed.first), code: payload).sas)
        XCTAssertTrue(model.macSeesPhone)
        XCTAssertTrue(model.links.isEmpty)
        flow.cancel()
        await flow.value
    }

    /// Re-review: a waiting keybox of an earlier code (left in the baseline, or changed since) never gives this scan
    /// a code, nor "Mac sees this iPhone".
    func testAWaitingKeyboxOfAnotherCodeShowsNoCode() async throws {
        clock.parked = true
        let model = makeModel()
        let payload = code()
        let older = try TestPhone.linkCodeTag(code())
        let fetches = LinkEventLog()
        host.mac = { [start] writes in
            fetches.append("fetch")
            // Differs from the baseline once the hello is written: a fresh answer, still for the older code.
            return DeviceGrant(
                deviceID: TestE2E.deviceID.uuidString, hubID: acme, name: "iPhone \(writes.count)", scope: .private,
                linked: false, typingAllowed: false, startSessionsAllowed: true, decidedAt: start,
                awaitingConfirmation: true, confirmNonce: TestPhone.confirmNonceText, linkCodeTag: older)
        }
        let flow = Task { await model.open(payload.url()) }
        try await poll { model.phase == .waiting(macName: "Acme Mac") && fetches.events.count >= 2 }
        // The wait's first fetch answered; it is parked on the clock now.
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertNil(model.linkCode)
        XCTAssertFalse(model.macSeesPhone)
        XCTAssertTrue(model.links.isEmpty)
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
        let tag = try TestPhone.linkCodeTag(payload)
        host.mac = { [weak model, start] writes in
            seen.append("\(model?.macSeesPhone ?? false)")
            guard writes.contains(where: { $0.linkNonce == payload.nonce }) else { return nil }
            return DeviceGrant(
                deviceID: deviceID, hubID: acme, name: "Colleague A's iPhone", scope: .private, linked: false,
                typingAllowed: false, startSessionsAllowed: true, decidedAt: start, awaitingConfirmation: true,
                linkCodeTag: tag
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
        XCTAssertTrue(model.links.isEmpty)

        let payload = code()
        macLinks(payload)
        host.keyboxKeys = TestPhone.keyboxKeys(epoch: 1)
        await model.open(payload.url())

        XCTAssertEqual(model.phase, .linked(macName: "Acme Mac"))
        XCTAssertEqual(host.row(acme)?.link.nonce, payload.nonce, "the link is saved")
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
        XCTAssertEqual(host.linkedCalls.last?.device.deviceID, TestE2E.deviceID.uuidString)
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
        XCTAssertTrue(model.links.isEmpty)
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

    /// Unlink deletes the hub's keys, after the `unlinked` record was sealed
    /// with them. The Mac's removal freezes the hub and keeps its keys (its
    /// data stays readable until Forget); Forget deletes them.
    func testUnlinkAndForgetDeleteTheHubsKeysAndARemovalKeepsThem() async throws {
        let unlinked = try await linkedModel(code())
        XCTAssertNotNil(try keyStore.hubLink(acme))

        await unlinked.unlink(acme)

        XCTAssertNil(try keyStore.hubLink(acme), "unlink deletes the hub's keys")
        XCTAssertNil(try keyStore.hubSigningKey(acme))
        let sealed = await host.transport(for: .private).sealed
        XCTAssertEqual(sealed.count, 2, "the hello and the sealed unlinked record")
        XCTAssertEqual(sealed.last?.kind, WireKind.envelope)

        let removed = try await linkedModel(code())
        XCTAssertNotNil(try keyStore.hubLink(acme))
        await removed.removedByMac(acme)
        XCTAssertNotNil(try keyStore.hubLink(acme), "a frozen hub's replica still opens with its keys")
        await removed.forget(acme)
        XCTAssertNil(try keyStore.hubLink(acme), "Forget deletes them")
    }

    /// Multi-hub: each linked Mac keeps its own keys under its hub id;
    /// unlinking one deletes only that Mac's.
    func testEachMacKeepsItsOwnKeys() async throws {
        let model = try await linkedModel(code())
        let other = code(hubID: homeID, macName: "Home Mac")
        macLinks(other)
        await model.open(other.url())
        await model.finish()
        XCTAssertNotNil(try keyStore.hubLink(acme)?.metaKey)
        XCTAssertNotNil(try keyStore.hubLink(homeID)?.metaKey)

        await model.unlink(homeID)

        XCTAssertNil(try keyStore.hubLink(homeID))
        XCTAssertNotNil(try keyStore.hubLink(acme)?.metaKey, "the other Mac's keys stay")
        XCTAssertEqual(model.links.map(\.hubID), [acme])
    }

    /// After the link: a keybox with a new epoch adds its keys (the retired
    /// one kept), and a revoked keybox is that Mac removing this phone: the
    /// hub freezes (multi-hub spec §6.1), its keys kept for its data.
    func testALaterKeyboxAddsItsEpochAndARevokedOneFreezesTheHub() async throws {
        let model = try await linkedModel(code())
        host.keyboxKeys = KeyboxKeys(
            epoch: 2, dataKey: TestPhone.keyboxKeys(epoch: 2).dataKey, alertKey: TestPhone.keyboxKeys(epoch: 2).alertKey,
            metaKey: TestPhone.keyboxKeys().metaKey, previousEpoch: 1,
            previousDataKey: TestPhone.keyboxKeys(epoch: 1).dataKey, previousAlertKey: TestPhone.keyboxKeys(epoch: 1).alertKey
        )

        await model.keyboxChanged(hubID: acme)

        XCTAssertEqual(try keyStore.hubLink(acme)?.epochs.map(\.epoch), [1, 2])
        XCTAssertEqual(host.keyMergeHubIDs, [acme], "the hub's stored rows are indexed after the merge")
        XCTAssertEqual(model.links.first?.state, .linked)

        let deviceID = TestE2E.deviceID.uuidString
        host.mac = { [start] _ in
            DeviceGrant(
                deviceID: deviceID, hubID: acme, name: "Colleague A's iPhone", scope: .private, linked: false,
                typingAllowed: false, startSessionsAllowed: true, decidedAt: start, revoked: true
            )
        }
        await model.keyboxChanged(hubID: acme)

        XCTAssertEqual(host.markedRemoved, [acme], "D9: a revoked keybox freezes the hub")
        XCTAssertEqual(model.links.first?.state, .unlinkedByMac)
        XCTAssertEqual(model.notice, .removed(macName: "Acme Mac"))
        XCTAssertTrue(host.removals.isEmpty, "nothing wiped")
        XCTAssertNotNil(try keyStore.hubLink(acme))
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

        await model.reconcileKeyboxKeys(hubID: acme)
        XCTAssertEqual(host.keyMerges, 1, "nothing missing: nothing written, nothing re-indexed")
    }

    /// A link saved before encryption (an F1 link moved into the registry)
    /// has no hub keys: dropped at launch with the re-scan notice; a link with
    /// keys stays.
    func testALinkWithoutKeysIsDroppedWithTheReScanNotice() async throws {
        host.seed(linkRecord())
        LinkStore(defaults: defaults).pending = PendingLink(
            link: linkRecord(hubID: studio), deadline: start.addingTimeInterval(60), baseline: nil, baselineCaptured: true
        )
        let model = makeModel()

        await model.dropUnencryptedLinks()

        XCTAssertTrue(model.links.isEmpty)
        XCTAssertNil(LinkStore(defaults: defaults).pending, "a pending link without keys goes too")
        XCTAssertEqual(model.notice, .encryptionReScan)
        XCTAssertEqual(LinkNotice.encryptionReScan.message, "Watchtower now encrypts your data. Scan the code on your Mac again.")
        XCTAssertEqual(host.removedHubIDs, [acme], "the old link's hub is removed")
        XCTAssertTrue(host.farewells.isEmpty, "nothing can be sealed for it")

        try keyStore.saveHubLink(try ScannedHubKeys(code()).unconfirmedLink)
        host.seed(linkRecord())
        let keyed = makeModel()
        await keyed.dropUnencryptedLinks()
        XCTAssertEqual(keyed.links.map(\.hubID), [acme], "a link with keys stays")
        XCTAssertEqual(host.removedHubIDs, [acme])
    }

    // MARK: - Fix round 1 (Task 16 review)

    /// I-1: a scan of the linked Mac whose keybox does not say "linked" is a
    /// re-pair: the link ends first (its "Not sent" reported), and a refusal
    /// leaves no link to that Mac and no keys, never a row it cannot sync.
    func testARefusedRescanOfTheLinkedMacEndsTheLink() async throws {
        let model = try await linkedModel(code())
        let again = code()
        host.notSentCount = 2
        host.mac = { [grant = grantMaker] writes in
            writes.last?.linkNonce == again.nonce ? grant(acme, false, .notConfirmed) : nil
        }

        await model.open(again.url())

        XCTAssertEqual(model.phase, .failed(.refused))
        XCTAssertTrue(model.links.isEmpty, "Welcome, not dead tabs")
        XCTAssertNil(try keyStore.hubLink(acme), "the keys go with the link")
        XCTAssertEqual(model.notice, .notSent(2), "what the re-pair's removal lost is reported")
        XCTAssertEqual(host.removedHubIDs, [acme, acme], "the old link, then the refused candidate")
    }

    func testATimedOutRescanOfTheLinkedMacEndsTheLink() async throws {
        let model = try await linkedModel(code())
        host.mac = { _ in nil }

        await model.open(code().url())

        XCTAssertEqual(model.phase, .failed(.noAnswer))
        XCTAssertTrue(model.links.isEmpty)
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
        XCTAssertTrue(model.links.isEmpty)

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
        let ids = CloudKitLinkContainer.shareRecordIDs(ownerName: owner, hubID: acme)

        XCTAssertEqual(ids.map(\.zoneID.zoneName).sorted(), ["DataZone-\(acme)", "RelayZone-\(acme)"])
        XCTAssertEqual(Set(ids.map(\.zoneID.ownerName)), [owner])
        XCTAssertEqual(Set(ids.map(\.recordName)), [CKRecordNameZoneWideShare])
    }

    /// Target 168: only the hub's two zone-wide shares, owned by the code's owner, are accepted.
    func testOnlyTheHubsOwnSharesAreAccepted() {
        let expected = CloudKitLinkContainer.shareRecordIDs(ownerName: owner, hubID: acme)
        func check(_ shares: [(owner: String?, recordID: CKRecord.ID)]) -> Bool {
            (try? CloudKitLinkContainer.checkShares(shares, ownerName: owner, hubID: acme)) != nil
        }
        XCTAssertTrue(check(expected.map { (owner: owner, recordID: $0) }))
        XCTAssertTrue(check(expected.reversed().map { (owner: owner, recordID: $0) }), "order does not matter")

        XCTAssertFalse(check(expected.map { (owner: "_someone-else", recordID: $0) }), "another owner")
        XCTAssertFalse(check(expected.map { (owner: nil, recordID: $0) }), "no owner identity")
        let otherHub = CloudKitLinkContainer.shareRecordIDs(ownerName: owner, hubID: "other-hub")
        XCTAssertFalse(check(otherHub.map { (owner: owner, recordID: $0) }), "another hub's zones")
        let foreignZone = CloudKitLinkContainer.shareRecordIDs(ownerName: "_someone-else", hubID: acme)
        XCTAssertFalse(check(foreignZone.map { (owner: owner, recordID: $0) }), "zones of another owner")
        XCTAssertFalse(check([(owner: owner, recordID: expected[0]), (owner: owner, recordID: expected[0])]), "one zone twice")
        let recordShare = CKRecord.ID(recordName: "some-record", zoneID: expected[0].zoneID)
        XCTAssertFalse(check([(owner: owner, recordID: recordShare), (owner: owner, recordID: expected[1])]), "not zone-wide")
    }
}
