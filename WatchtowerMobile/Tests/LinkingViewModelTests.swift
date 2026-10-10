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
            "Your Mac didn't answer — keep Settings → Mobile open on the Mac and scan again"
        )
        XCTAssertGreaterThanOrEqual(clock.slept, 60)
        XCTAssertLessThan(clock.slept, 62, "the wait ends at 60 s")
        XCTAssertNil(model.link)
        XCTAssertTrue(host.links.isEmpty, "never shown as linked")
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
        XCTAssertEqual(host.links.last?.device?.deviceID, identity.deviceID)
        XCTAssertEqual(host.links.last?.writesAllowed, true)
        XCTAssertEqual(LinkStore(defaults: defaults).link?.hubID, "hub-acme", "the link is saved")
    }

    func testScanningTheSameCodeTwiceStaysLinkedWithoutASecondWrite() async throws {
        let payload = code()
        let model = try await linkedModel(payload)

        await model.open(payload.url())

        XCTAssertEqual(model.phase, .linked(macName: "Acme Mac"))
        XCTAssertEqual(model.link?.hubID, "hub-acme")
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
        XCTAssertEqual(pending.deadline, start.addingTimeInterval(60))

        // Relaunch 20 s later: 40 s of the wait are left.
        clock.parked = false
        clock.advance(by: 20)
        let relaunched = makeModel()
        XCTAssertNil(relaunched.link, "a pending link is not a link")

        await relaunched.resumePendingLink()

        XCTAssertEqual(host.prepared.last, .shared(ownerName: owner), "the wait reads the scan's database")
        XCTAssertEqual(relaunched.phase, .failed(.noAnswer))
        XCTAssertGreaterThanOrEqual(clock.slept, 40)
        XCTAssertLessThan(clock.slept, 42, "only the remaining part of the 60 s")
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

        host.parksPrepare = false
        let relaunched = makeModel()
        await relaunched.resumePendingLink()

        XCTAssertEqual(relaunched.phase, .failed(.noAnswer))
        XCTAssertTrue(host.links.isEmpty, "never shown as linked")
        XCTAssertNil(LinkStore(defaults: defaults).pending)
    }

    func testRelaunchAfterTheDeadlineOffersToScanAgainAtOnce() async throws {
        let store = LinkStore(defaults: defaults)
        store.pending = PendingLink(link: linkRecord(), deadline: start.addingTimeInterval(-1), baseline: nil)
        let model = makeModel()

        await model.resumePendingLink()

        XCTAssertEqual(model.phase, .failed(.noAnswer))
        XCTAssertEqual(clock.slept, 0)
        XCTAssertNil(LinkStore(defaults: defaults).pending)
    }

    func testRelaunchedWaitLinksWhenTheGrantArrives() async throws {
        let record = linkRecord()
        LinkStore(defaults: defaults).pending = PendingLink(link: record, deadline: start.addingTimeInterval(30), baseline: nil)
        let answerAt = start.addingTimeInterval(10)
        host.mac = { [grant = grantMaker, clock] _ in
            guard let clock, clock.now() >= answerAt else { return nil }
            return grant("hub-acme", true, nil)
        }
        let model = makeModel()

        await model.resumePendingLink()

        XCTAssertEqual(model.phase, .linked(macName: "Acme Mac"))
        XCTAssertEqual(model.link, record)
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

        XCTAssertEqual(host.wipes, 1, "the replica is wiped")
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
        XCTAssertEqual(host.flushes, 1, "the unlinked record is sent before the stop")
        XCTAssertEqual(host.wipes, 1)
        XCTAssertNil(model.link)
        XCTAssertNil(LinkStore(defaults: defaults).link)
        XCTAssertNil(host.links.last?.device)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.notice, .notSent(3))
        XCTAssertEqual(LinkNotice.notSent(3).message, "Not sent: 3 items were still waiting for your Mac")
        XCTAssertEqual(LinkNotice.notSent(1).message, "Not sent: 1 item was still waiting for your Mac")
        XCTAssertTrue(container.left.isEmpty, "a private link has no shares to leave")
    }

    func testUnlinkInSharedScopeLeavesTheShares() async throws {
        container.userRecordNameValue = "_colleague-a"
        let model = try await linkedModel(code())

        await model.unlink()

        XCTAssertEqual(container.left, [owner])
        let writes = try await host.deviceWrites(in: .shared(ownerName: owner))
        XCTAssertEqual(writes.last?.unlinked, true)
        XCTAssertNil(model.notice, "nothing was waiting")
    }

    // MARK: - Unlinked events

    func testRemovedWhileOfflineShowsRemovedAndWipes() async throws {
        container.userRecordNameValue = "_colleague-a"
        let model = try await linkedModel(code())
        host.notSentCount = 2

        await model.removedByMac()

        XCTAssertEqual(model.notice, .removed)
        XCTAssertEqual(LinkNotice.removed.message, "This Mac removed this phone")
        XCTAssertEqual(host.wipes, 1)
        XCTAssertNil(model.link)
        XCTAssertNil(host.links.last?.device)
        let writes = try await host.deviceWrites()
        XCTAssertNil(writes.last?.unlinked, "the Mac's zones are gone: nothing to write")
    }

    func testHubChangedShowsMovedAndStopsWrites() async throws {
        let model = try await linkedModel(code())

        await model.evaluate(heartbeat: heartbeat(hubID: "hub-studio", macName: "Acme Studio", updatedAt: start))

        XCTAssertEqual(model.notice, .moved(macName: "Acme Studio"))
        XCTAssertEqual(LinkNotice.moved(macName: "Acme Studio").message, "Watchtower moved to Acme Studio — scan the code on that Mac")
        XCTAssertEqual(host.links.last?.writesAllowed, false, "its writes are not sent")
        XCTAssertNotNil(host.links.last?.device, "still linked, so Settings still shows the Mac")
        XCTAssertEqual(host.wipes, 0)
        let callsAfterMove = host.links.count

        // The same heartbeat again changes nothing.
        await model.evaluate(heartbeat: heartbeat(hubID: "hub-studio", macName: "Acme Studio", updatedAt: start))
        XCTAssertEqual(host.links.count, callsAfterMove)

        // The linked hub takes back over: writes flow again.
        await model.evaluate(heartbeat: heartbeat(hubID: "hub-acme", macName: "Acme Mac", updatedAt: start))
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

    // MARK: - Switch Mac

    func testScanningAnotherMacAsksToSwitchAndNoKeepsTheOldLink() async throws {
        let model = try await linkedModel(code())
        let other = code(hubID: "hub-studio", macName: "Acme Studio")
        macLinks(other)

        await model.open(other.url())

        XCTAssertEqual(model.phase, .confirmSwitch(from: "Acme Mac", to: "Acme Studio"))
        XCTAssertEqual(LinkingViewModel.switchPrompt(from: "Acme Mac", to: "Acme Studio"), "Switch from Acme Mac to Acme Studio?")

        await model.confirmSwitch(false)

        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.link?.hubID, "hub-acme")
        let writes = try await host.deviceWrites()
        XCTAssertEqual(writes.count, 1, "nothing written for the other Mac")
        XCTAssertEqual(host.wipes, 0)
    }

    func testSwitchYesUnlinksTheOldMacThenLinksTheNewOne() async throws {
        let model = try await linkedModel(code())
        let other = code(hubID: "hub-studio", macName: "Acme Studio")
        macLinks(other)

        await model.open(other.url())
        await model.confirmSwitch(true)

        let writes = try await host.deviceWrites(in: .private)
        XCTAssertEqual(writes.map(\.unlinked), [nil, true, nil], "link, unlink the old Mac, link the new one")
        XCTAssertEqual(writes.last?.linkNonce, other.nonce)
        XCTAssertEqual(host.wipes, 1)
        XCTAssertEqual(model.phase, .linked(macName: "Acme Studio"))
        XCTAssertEqual(model.link?.hubID, "hub-studio")
    }

    // MARK: - Other payloads

    func testANewerCodeVersionAsksToUpdateTheApp() async throws {
        let model = makeModel()

        await model.open(code(version: 2).url())

        XCTAssertEqual(model.phase, .failed(.updateApp))
        XCTAssertEqual(LinkFailure.updateApp.message, "Update Watchtower on this iPhone")
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

        await model.open(code(hubID: "hub-studio", macName: "Acme Studio").url())

        XCTAssertEqual(model.phase, .waiting(macName: "Acme Mac"))
        flow.cancel()
        await flow.value
        let writes = try await host.deviceWrites()
        XCTAssertEqual(writes.count, 1)
    }
}
