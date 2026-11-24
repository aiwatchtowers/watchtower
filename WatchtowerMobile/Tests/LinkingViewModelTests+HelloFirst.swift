import Foundation
import WatchtowerE2ETesting
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

private let helloAcme = TestE2E.hubID.uuidString

// MARK: - The hello before any full fetch (#2189)

/// The scan's baseline is one read of the keybox record (`LinkHost.serverKeybox`) and its hello a direct save
/// (`LinkHost.sendDirectly`), so neither waits behind the fresh replica's full download; the Mac's answer to this scan
/// is still told apart from an earlier code's refusal by the baseline, read from one source for the whole wait and
/// across a kill, and a link completes only from the replica.
extension LinkingViewModelTests {
    /// A refusal decided at `decidedAt` on the Mac's clock.
    private func refusal(_ reason: LinkRefusal, decidedAt: Date) -> DeviceGrant {
        DeviceGrant(
            deviceID: TestE2E.deviceID.uuidString, hubID: helloAcme, name: "Colleague A's iPhone", scope: .private,
            linked: false, linkRefused: reason, typingAllowed: false, startSessionsAllowed: true, decidedAt: decidedAt
        )
    }

    /// An earlier code's refusal decided after this code's `iat` (`code()` is issued 10 s before `start`): the Mac
    /// retired that code when it showed this one, then read its late hello. Only the baseline tells it apart.
    private var staleRefusal: DeviceGrant { refusal(.expiredCode, decidedAt: start.addingTimeInterval(-5)) }

    // MARK: The hello

    func testTheHelloIsSavedDirectlyBeforeAnyFullFetch() async throws {
        let payload = code()
        macLinks(payload)
        let model = makeModel()

        await model.open(payload.url())

        XCTAssertEqual(model.phase, .linked(macName: "Acme Mac"))
        XCTAssertEqual(host.keyboxReads.first, .init(kind: .server, writesBefore: 0), "the baseline: one record read")
        XCTAssertEqual(host.directSaves, [helloAcme], "the hello: one direct save")
        let fetchesBeforeTheHello = host.keyboxReads.filter { $0.kind == .fetch && $0.writesBefore == 0 }
        XCTAssertTrue(fetchesBeforeTheHello.isEmpty, "no zone fetch before the hello")
        let writes = try await host.deviceWrites()
        XCTAssertEqual(writes.count, 1, "one hello")
    }

    /// The engine's queue holds its sends behind the fresh replica's launch pull: a hello queued there would reach
    /// the Mac only after the code closed.
    func testTheHelloDoesNotWaitForTheLaunchPull() async throws {
        let payload = code()
        macLinks(payload)
        let engine = host.transport(for: .cloudKit(.private))
        await engine.setHoldsQueue(true)
        let model = makeModel()

        await model.open(payload.url())

        XCTAssertEqual(model.phase, .linked(macName: "Acme Mac"), "the Mac read the hello while the launch pull ran")
        let queued = await engine.queued
        XCTAssertTrue(queued.isEmpty, "nothing waited on the engine")
    }

    func testAFailedDirectSaveQueuesTheHelloOnTheEngine() async throws {
        host.directSaveFails = true
        let payload = code()
        macLinks(payload)
        let model = makeModel()

        await model.open(payload.url())

        XCTAssertEqual(model.phase, .linked(macName: "Acme Mac"))
        XCTAssertTrue(host.directSaves.isEmpty)
        let writes = try await host.deviceWrites()
        XCTAssertEqual(writes.count, 1, "the hello, through the engine's queue")
    }

    // MARK: The baseline

    /// A server read that fails falls back to one fetch, and the whole wait then reads the replica.
    func testAFailedServerReadTakesTheBaselineFromTheFetch() async throws {
        host.serverReadFails = true
        let stale = staleRefusal
        host.mac = { _ in stale }
        let model = makeModel()

        await model.open(code().url())

        XCTAssertEqual(Array(host.keyboxReads.prefix(2)), [.init(kind: .server, writesBefore: 0), .init(kind: .fetch, writesBefore: 0)])
        XCTAssertFalse(host.keyboxReads.dropFirst(2).contains { $0.kind == .server }, "the wait reads the baseline's source")
        XCTAssertEqual(model.phase, .failed(.noAnswer), "the earlier refusal is the baseline, not this scan's answer")
    }

    /// A throttled transport: the direct read makes no request (unavailable), and the fetch's pull returns without
    /// reading the data zone (`HubSession.refreshForLink` false, so `fetchKeybox` is unavailable, never an absence).
    func testAThrottledTransportGivesNoBaselineAndNoHello() async throws {
        host.serverReadFails = true
        host.refreshFails = true
        let model = makeModel()

        await model.open(code().url())

        XCTAssertEqual(model.phase, .failed(.iCloud(LinkingViewModel.baselineUnreadableReason)))
        let failure = LinkFailure.iCloud(LinkingViewModel.baselineUnreadableReason)
        XCTAssertEqual(failure.message, "Couldn't reach iCloud — Check the connection and scan again.")
        XCTAssertTrue(failure.offersScan, "scan again")
        let writes = try await host.deviceWrites()
        XCTAssertTrue(writes.isEmpty, "no hello without a baseline")
        XCTAssertNil(LinkStore(defaults: defaults).pending)
    }

    func testAnEarlierCodesRefusalAtTheScanIsNotThisScansRefusal() async throws {
        let stale = staleRefusal
        host.mac = { _ in stale }
        let model = makeModel()

        await model.open(code().url())

        XCTAssertEqual(model.phase, .failed(.noAnswer), "not .refused: the refusal is an earlier code's")
        XCTAssertTrue(host.linkedCalls.isEmpty)
    }

    func testThisScansExpiredCodeRefusalRefusesOverAnEarlierOne() async throws {
        try await assertThisScansRefusal(.expiredCode)
    }

    func testThisScansNotConfirmedRefusalRefusesOverAnEarlierOne() async throws {
        try await assertThisScansRefusal(.notConfirmed)
    }

    private func assertThisScansRefusal(_ reason: LinkRefusal, file: StaticString = #filePath, line: UInt = #line) async throws {
        let payload = code()
        let (stale, answer) = (staleRefusal, refusal(reason, decidedAt: start.addingTimeInterval(1)))
        host.mac = { writes in writes.contains { $0.linkNonce == payload.nonce } ? answer : stale }
        let model = makeModel()

        await model.open(payload.url())

        XCTAssertEqual(model.phase, .failed(.refused), file: file, line: line)
        XCTAssertLessThan(clock.slept, LinkingViewModel.grantPollInterval * 2, "the first read after the hello", file: file, line: line)
    }

    /// A pending link whose baseline came from the replica keeps reading the replica: the server's copy, which differs
    /// from that baseline, is never compared with it.
    func testAResumedWaitReadsTheBaselinesSource() async throws {
        try keyStore.saveHubLink(try ScannedHubKeys(code()).unconfirmedLink)
        let stale = staleRefusal
        LinkStore(defaults: defaults).pending = PendingLink(
            link: linkRecordForResume(), deadline: start.addingTimeInterval(30), baseline: stale, baselineCaptured: true,
            baselineSource: .replica
        )
        let newer = refusal(.notConfirmed, decidedAt: start)
        host.mac = { _ in newer }
        host.replicaMac = { _ in stale }
        let model = makeModel()

        await model.resumePendingLink()

        XCTAssertEqual(model.phase, .failed(.noAnswer), "the replica's copy equals the baseline")
        XCTAssertFalse(host.keyboxReads.contains { $0.kind == .server })
    }

    private func linkRecordForResume() -> LinkRecord {
        LinkRecord(
            hubID: helloAcme, macName: "Acme Mac", scope: .private, ownerName: "_owner-acme", userRecordName: "_owner-acme",
            nonce: "nonce", dataShareURL: nil, relayShareURL: nil, deviceID: TestE2E.deviceID.uuidString
        )
    }

    // MARK: Linked: the replica completes it

    func testALinkedServerReadCompletesOnlyOnceTheReplicaHasIt() async throws {
        let payload = code()
        macLinks(payload)
        let caughtUpAt = start.addingTimeInterval(6)
        let linkedGrant = grantMaker
        host.replicaMac = { [clock] writes in
            guard let clock, clock.now() >= caughtUpAt, writes.contains(where: { $0.linkNonce == payload.nonce }) else { return nil }
            return linkedGrant(helloAcme, true, nil)
        }
        let model = makeModel()

        await model.open(payload.url())

        XCTAssertEqual(model.phase, .linked(macName: "Acme Mac"))
        XCTAssertEqual(host.linkedCalls.count, 1)
        XCTAssertGreaterThanOrEqual(clock.slept, 6, "not before the replica caught up")
    }

    func testALinkedServerReadWithAFailingFetchNeverCompletes() async throws {
        let payload = code()
        macLinks(payload)
        let model = makeModel()
        host.refreshFails = true

        await model.open(payload.url())

        XCTAssertEqual(model.phase, .failed(.noAnswer), "waited to the deadline")
        XCTAssertTrue(host.linkedCalls.isEmpty)
    }

    /// R4 sees the zone only after a fetch: the link completes through it, so a Mac on Relay ends it.
    func testALinkedServerReadOnAMacOnRelayEndsMacOnRelay() async throws {
        let payload = code()
        macLinks(payload)
        host.onRelay = [helloAcme]
        let model = makeModel()

        await model.open(payload.url())

        XCTAssertEqual(model.phase, .failed(.macOnRelay(macName: "Acme Mac")))
        XCTAssertTrue(model.links.isEmpty)
    }

    // MARK: Killed between the hello and the first answer read

    /// Scans, lets the hello go out with an earlier code's refusal on the server, and kills the app at the first
    /// read after it. Returns the payload; the pending link is left for the relaunch.
    private func killedAfterTheHello() async throws -> LinkPayload {
        let payload = code()
        let stale = staleRefusal
        host.mac = { _ in stale }
        host.parksReadsAfterWrite = true
        let first = makeModel()
        let flow = Task { await first.open(payload.url()) }
        try await poll({ self.host.keyboxReads.contains { $0.writesBefore > 0 } }, "the first read after the hello")
        flow.cancel()
        await flow.value
        host.parksReadsAfterWrite = false
        let pending = try XCTUnwrap(LinkStore(defaults: defaults).pending, "a resumable wait")
        XCTAssertTrue(pending.baselineCaptured)
        XCTAssertEqual(pending.baseline, stale, "the baseline read before the hello")
        XCTAssertEqual(pending.baselineSource, .server)
        XCTAssertTrue(pending.helloSent, "marked once the save returned")
        let writes = try await host.deviceWrites()
        XCTAssertEqual(writes.count, 1, "the hello went out")
        return payload
    }

    func testAKillAfterTheHelloNeverTakesTheEarlierRefusalOnRelaunch() async throws {
        _ = try await killedAfterTheHello()
        let readsBefore = host.keyboxReads.count
        let relaunched = makeModel()

        await relaunched.resumePendingLink()

        XCTAssertEqual(relaunched.phase, .failed(.noAnswer), "not .refused: the refusal is an earlier code's")
        XCTAssertTrue(host.linkedCalls.isEmpty)
        XCTAssertTrue(host.keyboxReads.dropFirst(readsBefore).allSatisfy { $0.kind == .server }, "the baseline's source")
    }

    func testAKillAfterTheHelloStillTakesThisScansRefusalOnRelaunch() async throws {
        let payload = try await killedAfterTheHello()
        let answer = refusal(.notConfirmed, decidedAt: start.addingTimeInterval(1))
        host.mac = { writes in writes.contains { $0.linkNonce == payload.nonce } ? answer : nil }
        let relaunched = makeModel()

        await relaunched.resumePendingLink()

        XCTAssertEqual(relaunched.phase, .failed(.refused))
    }

    func testAKillAfterTheHelloStillTakesThisScansLinkOnRelaunch() async throws {
        let payload = try await killedAfterTheHello()
        macLinks(payload)
        let relaunched = makeModel()

        await relaunched.resumePendingLink()

        XCTAssertEqual(relaunched.phase, .linked(macName: "Acme Mac"))
        XCTAssertEqual(relaunched.links.map(\.hubID), [helloAcme])
        XCTAssertNil(LinkStore(defaults: defaults).pending)
        let writes = try await host.deviceWrites()
        XCTAssertEqual(writes.count, 1, "a sent hello is not sent again")
    }

    /// Killed while the direct hello save was in flight (nothing landed): the pending link is captured but not
    /// sent, and the relaunch sends the hello again under the same baseline, then takes this scan's link.
    func testAKillDuringTheHelloSaveSendsItAgainOnRelaunch() async throws {
        let payload = code()
        let stale = staleRefusal
        host.mac = { [grant = grantMaker] writes in
            writes.contains { $0.linkNonce == payload.nonce } ? grant(helloAcme, true, nil) : stale
        }
        host.parksDirectSave = true
        let first = makeModel()
        let flow = Task { await first.open(payload.url()) }
        try await poll({ self.host.directSaveAttempts == 1 }, "the hello's save in flight")
        flow.cancel()
        await flow.value
        host.parksDirectSave = false
        let pending = try XCTUnwrap(LinkStore(defaults: defaults).pending, "a resumable wait")
        XCTAssertTrue(pending.baselineCaptured)
        XCTAssertFalse(pending.helloSent)
        XCTAssertEqual(pending.baseline, stale)
        let before = try await host.deviceWrites()
        XCTAssertTrue(before.isEmpty, "nothing landed, nothing queued")

        let relaunched = makeModel()
        await relaunched.resumePendingLink()

        let after = try await host.deviceWrites()
        XCTAssertEqual(after.map(\.linkNonce), [payload.nonce], "the hello, sent again with the code's nonce")
        XCTAssertEqual(host.directSaves, [helloAcme])
        XCTAssertEqual(relaunched.phase, .linked(macName: "Acme Mac"))
    }

    /// Killed after CloudKit accepted the hello but before it was marked sent; the owner refused while the phone was
    /// off. The resume reads first: the refusal is this scan's answer, and no new request or code is made.
    func testAResumeHonoursARefusalOfAnUnmarkedHello() async throws {
        let payload = try await killedAfterTheHelloLandedUnmarked()
        let refused = refusal(.notConfirmed, decidedAt: start.addingTimeInterval(1))
        host.mac = { writes in writes.contains { $0.linkNonce == payload.nonce } ? refused : nil }
        let relaunched = makeModel()

        await relaunched.resumePendingLink()

        XCTAssertEqual(relaunched.phase, .failed(.refused))
        XCTAssertEqual(host.directSaveAttempts, 1, "no resend")
        let writes = try await host.deviceWrites()
        XCTAssertEqual(writes.count, 1)
    }

    /// The same, the Mac linking this scan meanwhile: that answer completes the link, and nothing is resent.
    func testAResumeOfAnUnmarkedHelloTheMacReadSendsNothing() async throws {
        let payload = try await killedAfterTheHelloLandedUnmarked()
        macLinks(payload)
        let relaunched = makeModel()

        await relaunched.resumePendingLink()

        XCTAssertEqual(relaunched.phase, .linked(macName: "Acme Mac"))
        XCTAssertEqual(host.directSaveAttempts, 1, "no resend")
    }

    /// The same, the Mac waiting on this scan's code: the hello landed, so it is marked sent, nothing is resent, and
    /// the code shows.
    func testAResumeOfAnUnmarkedHelloTheMacWaitsOnIsMarkedSent() async throws {
        let payload = try await killedAfterTheHelloLandedUnmarked()
        let tag = try TestPhone.linkCodeTag(payload)
        let decided = start
        host.mac = { writes in
            guard writes.contains(where: { $0.linkNonce == payload.nonce }) else { return nil }
            return DeviceGrant(
                deviceID: TestE2E.deviceID.uuidString, hubID: helloAcme, name: "iPhone", scope: .private, linked: false,
                typingAllowed: false, startSessionsAllowed: true, decidedAt: decided, awaitingConfirmation: true,
                confirmNonce: TestPhone.confirmNonceText, linkCodeTag: tag)
        }
        clock.parked = true
        let relaunched = makeModel()
        let flow = Task { await relaunched.resumePendingLink() }
        try await poll({ relaunched.linkCode != nil }, "the code shows")

        XCTAssertEqual(LinkStore(defaults: defaults).pending?.helloSent, true)
        XCTAssertEqual(host.directSaveAttempts, 1, "no resend")
        flow.cancel()
        await flow.value
    }

    /// A re-pair whose baseline was the old link; on resume the server shows that link revoked. A changed grant that
    /// answers nothing is no answer to this scan: the hello is sent again, and this scan's link then completes.
    func testARevokedKeyboxOnResumeResendsTheHello() async throws {
        try keyStore.saveHubLink(try ScannedHubKeys(code()).unconfirmedLink)
        let record = linkRecordForResume()
        let oldLink = DeviceGrant(
            deviceID: TestE2E.deviceID.uuidString, hubID: helloAcme, name: "iPhone", scope: .private, linked: true,
            linkedAt: start.addingTimeInterval(-86_400), typingAllowed: false, startSessionsAllowed: true
        )
        LinkStore(defaults: defaults).pending = PendingLink(
            link: record, deadline: start.addingTimeInterval(60), baseline: oldLink, baselineCaptured: true,
            issuedAt: start.addingTimeInterval(-10), baselineSource: .server, helloSent: false
        )
        let revoked = DeviceGrant(
            deviceID: TestE2E.deviceID.uuidString, hubID: helloAcme, name: "iPhone", scope: .private, linked: false,
            typingAllowed: false, startSessionsAllowed: true, decidedAt: start.addingTimeInterval(-5), revoked: true
        )
        let linkedGrant = grantMaker
        host.mac = { writes in
            writes.contains { $0.linkNonce == record.nonce } ? linkedGrant(helloAcme, true, nil) : revoked
        }
        let model = makeModel()

        await model.resumePendingLink()

        XCTAssertEqual(host.directSaves, [helloAcme], "the hello, sent again")
        let writes = try await host.deviceWrites()
        XCTAssertEqual(writes.map(\.linkNonce), [record.nonce])
        XCTAssertEqual(model.phase, .linked(macName: "Acme Mac"))
    }

    /// A first read that is unavailable never resends; a later read that proves no answer does.
    func testAnUnavailableReadNeverResends() async throws {
        let payload = code()
        let stale = staleRefusal
        host.mac = { [grant = grantMaker] writes in
            writes.contains { $0.linkNonce == payload.nonce } ? grant(helloAcme, true, nil) : stale
        }
        host.parksDirectSave = true
        let first = makeModel()
        let flow = Task { await first.open(payload.url()) }
        try await poll({ self.host.directSaveAttempts == 1 }, "the hello's save in flight")
        flow.cancel()
        await flow.value
        host.parksDirectSave = false
        host.failingServerReads = 1
        let relaunched = makeModel()

        await relaunched.resumePendingLink()

        XCTAssertEqual(relaunched.phase, .linked(macName: "Acme Mac"))
        XCTAssertEqual(host.directSaveAttempts, 2, "one resend, after the read that proved no answer")
        XCTAssertGreaterThanOrEqual(clock.slept, LinkingViewModel.grantPollInterval, "not on the unavailable read")
    }

    /// The hello reached the server, then the app was killed before the flow marked it sent.
    private func killedAfterTheHelloLandedUnmarked() async throws -> LinkPayload {
        let payload = code()
        let stale = staleRefusal
        host.mac = { _ in stale }
        host.parksAfterDirectSave = true
        let first = makeModel()
        let flow = Task { await first.open(payload.url()) }
        try await poll({ self.host.directSaves.count == 1 }, "the hello landed")
        flow.cancel()
        await flow.value
        host.parksAfterDirectSave = false
        let pending = try XCTUnwrap(LinkStore(defaults: defaults).pending)
        XCTAssertFalse(pending.helloSent)
        let writes = try await host.deviceWrites()
        XCTAssertEqual(writes.count, 1, "on the server")
        return payload
    }

    /// A linked keybox without keys on the direct read never starts a replica fetch: it keeps waiting.
    func testALinkedServerReadWithoutKeysFetchesNothing() async throws {
        host.keyboxKeys = nil
        let payload = code()
        macLinks(payload)
        let model = makeModel()

        await model.open(payload.url())

        XCTAssertEqual(model.phase, .failed(.noAnswer))
        XCTAssertFalse(host.keyboxReads.contains { $0.kind == .fetch }, "no fetch per poll")
    }

    /// A `baselineSource` this build cannot decode fails closed: not captured, so the relaunch offers a new scan.
    func testAnUnknownBaselineSourceReadsAsNotCaptured() async throws {
        let saved = PendingLink(
            link: linkRecordForResume(), deadline: start.addingTimeInterval(60), baseline: nil, baselineCaptured: true,
            baselineSource: .server
        )
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        object["baselineSource"] = "future"
        object.removeValue(forKey: "helloSent")
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: "link.pending")

        let pending = try XCTUnwrap(LinkStore(defaults: defaults).pending)
        XCTAssertFalse(pending.baselineCaptured, "never read as the replica")
        XCTAssertNil(pending.baselineSource)
        XCTAssertTrue(pending.helloSent, "an older build's value: its hello followed the baseline")

        let model = makeModel()
        await model.resumePendingLink()
        XCTAssertEqual(model.phase, .failed(.noAnswer))
        XCTAssertTrue(host.keyboxReads.isEmpty, "no wait")
    }

    /// Killed during the baseline read: nothing was written, so the relaunch offers a new scan at once.
    func testAKillDuringTheBaselineReadWritesNoHello() async throws {
        host.mac = { _ in nil }
        host.parksFetchGrant = true
        let first = makeModel()
        let flow = Task { await first.open(code().url()) }
        try await poll({ !self.host.keyboxReads.isEmpty }, "the baseline read")
        flow.cancel()
        await flow.value
        host.parksFetchGrant = false

        let writes = try await host.deviceWrites()
        XCTAssertTrue(writes.isEmpty, "no hello")
        XCTAssertEqual(host.keyboxReads.count, 1, "no fallback fetch after the kill")
        XCTAssertEqual(LinkStore(defaults: defaults).pending?.baselineCaptured, false)
    }

    // MARK: The session's glue

    /// The record the direct read asks for: the name the hub writes and `SecureTransport` maps the grant to, in the
    /// data zone.
    func testTheKeyboxIsReadByItsWireNameInTheDataZone() throws {
        try keyStore.saveHubLink(try ScannedHubKeys(code()).unconfirmedLink)
        let provider = try PhoneKeyProvider(store: keyStore, hubID: helloAcme, seq: SeqAllocator(load: { 1 }, store: { _ in }))
        let secure = SecureTransport(inner: InMemoryCloudTransport(), keys: provider, rollback: InMemoryRollbackGuard())
        let location = HubSession.keyboxLocation(deviceID: TestE2E.deviceID)

        XCTAssertEqual(location.recordName, "keybox-\(TestE2E.deviceID.uuidString)")
        XCTAssertEqual(location.zone, .data)
        let plain = SliceKind.deviceGrant.recordName(id: TestE2E.deviceID.uuidString.lowercased())
        XCTAssertEqual(try secure.wireName(plain: plain, zone: .data), location.recordName, "the name the sealer maps the grant to")
    }

    /// The fetch counts only when it polled the zones it needed to their end (a throttled or cut pull returns
    /// normally): the data zone for a baseline or a poll, and the mailbox too for a completing link.
    func testALinkFetchCoversOnlyTheZonesItPolledToTheirEnd() {
        let before = HubSession.LinkFetchCounts(data: 3, relay: 5)
        let dataOnly = HubSession.LinkFetchCounts(data: 4, relay: 5)
        let both = HubSession.LinkFetchCounts(data: 4, relay: 6)
        typealias Coverage = HubSession.LinkFetchCoverage
        XCTAssertEqual(
            HubSession.linkFetchCoverage(refreshed: true, before: before, after: before), Coverage(data: false, mailbox: false),
            "a skipped pull")
        XCTAssertEqual(
            HubSession.linkFetchCoverage(refreshed: true, before: before, after: dataOnly), Coverage(data: true, mailbox: false),
            "the mailbox not read")
        XCTAssertEqual(
            HubSession.linkFetchCoverage(refreshed: true, before: before, after: both), Coverage(data: true, mailbox: true))
        XCTAssertEqual(
            HubSession.linkFetchCoverage(refreshed: false, before: before, after: both), Coverage(data: false, mailbox: false),
            "a failed fetch")
        XCTAssertEqual(
            Coverage(data: true, mailbox: false).adding(Coverage(data: false, mailbox: true)), Coverage(data: true, mailbox: true))
    }

    /// A fetch that joined a pull already past the zones moves no count: one more fetch is judged, unless the
    /// transport is throttled or unlinked (then the first one stands, unavailable).
    func testALinkFetchThatMovedNoPollTriesOneMorePull() {
        typealias Coverage = HubSession.LinkFetchCoverage
        let none = Coverage(data: false, mailbox: false)
        let dataOnly = Coverage(data: true, mailbox: false)
        XCTAssertTrue(HubSession.linkFetchNeedsSecondPull(covered: none, mailbox: false, unlinked: false, throttled: false))
        XCTAssertFalse(
            HubSession.linkFetchNeedsSecondPull(covered: dataOnly, mailbox: false, unlinked: false, throttled: false), "read it")
        XCTAssertTrue(
            HubSession.linkFetchNeedsSecondPull(covered: dataOnly, mailbox: true, unlinked: false, throttled: false),
            "the mailbox still needed")
        XCTAssertFalse(
            HubSession.linkFetchNeedsSecondPull(covered: none, mailbox: false, unlinked: false, throttled: true), "throttled")
        XCTAssertFalse(
            HubSession.linkFetchNeedsSecondPull(covered: none, mailbox: false, unlinked: true, throttled: false), "unlinked")
    }

    /// An iCloud replica poll whose fetch read the data zone but not the mailbox (a `zoneBusy` on the relay zone) still
    /// shows the Mac's waiting keybox and its code; only completing needs the mailbox.
    func testAReplicaPollWithoutTheMailboxStillShowsTheCode() async throws {
        host.serverReadFails = true
        host.mailboxUncovered = true
        let payload = code()
        let tag = try TestPhone.linkCodeTag(payload)
        let decided = start
        host.mac = { writes in
            guard writes.contains(where: { $0.linkNonce == payload.nonce }) else { return nil }
            return DeviceGrant(
                deviceID: TestE2E.deviceID.uuidString, hubID: helloAcme, name: "iPhone", scope: .private, linked: false,
                typingAllowed: false, startSessionsAllowed: true, decidedAt: decided, awaitingConfirmation: true,
                confirmNonce: TestPhone.confirmNonceText, linkCodeTag: tag)
        }
        clock.parked = true
        let model = makeModel()
        let flow = Task { await model.open(payload.url()) }

        try await poll({ model.linkCode != nil }, "the four-digit code shows")
        XCTAssertTrue(model.macSeesPhone)
        flow.cancel()
        await flow.value
    }

    /// The same poll takes a link only once a fetch read the mailbox too.
    func testAReplicaPollWithoutTheMailboxNeverCompletes() async throws {
        host.serverReadFails = true
        host.mailboxUncovered = true
        let payload = code()
        macLinks(payload)
        let model = makeModel()

        await model.open(payload.url())

        XCTAssertEqual(model.phase, .failed(.noAnswer))
        XCTAssertTrue(host.linkedCalls.isEmpty)
    }

    /// A completing link reads the replica after a fetch that also read the mailbox, whichever source showed it.
    func testALinkCompletesThroughAFetchThatReadTheMailbox() async throws {
        let payload = code()
        macLinks(payload)
        let model = makeModel()

        await model.open(payload.url())

        XCTAssertEqual(model.phase, .linked(macName: "Acme Mac"))
        XCTAssertEqual(host.completionHubIDs, [helloAcme])
    }

    /// An iCloud link on a replica baseline: the poll's fetch read the mailbox, so the link it shows completes from it,
    /// even when any further fetch would fail (a throttle holding it to the deadline).
    func testAReplicaPollThatReadTheMailboxCompletesWithoutASecondFetch() async throws {
        host.serverReadFails = true
        host.failsFetchesAfterLinked = true
        let payload = code()
        macLinks(payload)
        let model = makeModel()

        await model.open(payload.url())

        XCTAssertEqual(model.phase, .linked(macName: "Acme Mac"))
        XCTAssertEqual(host.completionHubIDs, [helloAcme], "the poll's read, and no second one")
    }

    // MARK: A keybox this phone cannot open

    /// A re-pair over an old keybox sealed to a key this phone no longer has: it is the baseline by its fingerprint,
    /// the hello goes out, and the Mac's new keybox completes the link (codex review, #2189).
    func testARePairOverAnUnopenableKeyboxLinks() async throws {
        let payload = code()
        host.macOpaque = { writes in writes.isEmpty ? "old-keybox" : nil }
        macLinks(payload)
        let model = makeModel()

        await model.open(payload.url())

        XCTAssertEqual(model.phase, .linked(macName: "Acme Mac"))
        XCTAssertEqual(host.directSaves, [helloAcme], "the hello went out")
    }

    /// An opaque baseline and a record that still does not open: no answer, never a failure to reach iCloud.
    func testAStillUnopenableKeyboxIsNoAnswer() async throws {
        host.macOpaque = { _ in "old-keybox" }
        let model = makeModel()

        await model.open(code().url())

        XCTAssertEqual(model.phase, .failed(.noAnswer))
        XCTAssertEqual(host.directSaves, [helloAcme])
    }

    /// A resume whose baseline is opaque: the old keybox stays unopenable for a while, then the Mac's answer opens.
    func testAResumeWithAnOpaqueBaselineTakesTheAnswer() async throws {
        try keyStore.saveHubLink(try ScannedHubKeys(code()).unconfirmedLink)
        let record = linkRecordForResume()
        LinkStore(defaults: defaults).pending = PendingLink(
            link: record, deadline: start.addingTimeInterval(60), baseline: nil, baselineCaptured: true,
            issuedAt: start.addingTimeInterval(-10), baselineSource: .server, baselineFingerprint: "old-keybox"
        )
        let answerAt = start.addingTimeInterval(6)
        host.macOpaque = { [clock] _ in
            guard let clock, clock.now() >= answerAt else { return "old-keybox" }
            return nil
        }
        let refused = refusal(.notConfirmed, decidedAt: start.addingTimeInterval(1))
        host.mac = { _ in refused }
        let model = makeModel()

        await model.resumePendingLink()

        XCTAssertEqual(model.phase, .failed(.refused), "any keybox that opens differs from an opaque baseline")
        XCTAssertGreaterThanOrEqual(clock.slept, 6)
    }

    func testABaselineFingerprintSurvivesAndAnOlderValueReadsWithoutOne() throws {
        let opaque = PendingLink(
            link: linkRecordForResume(), deadline: start, baseline: nil, baselineCaptured: true, baselineFingerprint: "fp"
        )
        let decoded = try JSONDecoder().decode(PendingLink.self, from: JSONEncoder().encode(opaque))
        XCTAssertEqual(decoded.keyboxBaseline, .opaque("fp"))

        let stale = staleRefusal
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(PendingLink(
            link: linkRecordForResume(), deadline: start, baseline: stale, baselineCaptured: true
        ))) as? [String: Any])
        object.removeValue(forKey: "baselineFingerprint")
        let older = try JSONDecoder().decode(PendingLink.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(older.keyboxBaseline, .grant(stale))
        XCTAssertTrue(older.differsFromBaseline(refusal(.notConfirmed, decidedAt: start)))
        XCTAssertFalse(older.differsFromBaseline(stale))
        XCTAssertTrue(decoded.differsFromBaseline(stale), "any grant that opens differs from an opaque baseline")
    }

    // MARK: The session's mapping of a read

    func testAReadKeepsAbsentUnopenableAndFailedApart() async throws {
        let sealed = Data("sealed".utf8)
        let failures: [any Error] = [
            CancellationError(), KeyStoreError.locked, SecureTransportError.keysUnavailable, DirectCallRefusal.unreadableRecord,
            DirectCallRefusal.throttled
        ]
        for failure in failures {
            let fetchFailed = await HubSession.keyboxRead { throw failure } open: { _ in nil }
            guard case .unavailable = fetchFailed else { return XCTFail("\(failure) read as \(fetchFailed)") }
        }
        for failure in [KeyStoreError.locked as any Error, SecureTransportError.keysUnavailable] {
            let openFailed = await HubSession.keyboxRead { sealed } open: { _ in throw failure }
            guard case .unavailable = openFailed else { return XCTFail("\(failure) on open read as \(openFailed)") }
        }
        let unopenable = await HubSession.keyboxRead { sealed } open: { _ in throw EnvelopeError.authenticationFailed }
        XCTAssertEqual(unopenable, .opaque(fingerprint: KeyboxRead.fingerprint(sealed)), "a fingerprint, never a grant")
        let absent = await HubSession.keyboxRead { nil } open: { _ in nil }
        XCTAssertEqual(absent, .read(nil))
        let box = Keybox(grant: staleRefusal, keys: nil)
        let present = await HubSession.keyboxRead { sealed } open: { _ in box }
        XCTAssertEqual(present, .read(box))
    }
}

// MARK: - The field timeline of #2190

/// v0.29.2 read every answer of the wait from the replica (`fetchKeybox`: one fetch, then the replica's copy), so a
/// refusal the Mac published two seconds after the hello showed only once a fetch had polled the data zone to its end
/// and the replica had applied it; on the owner's phone neither the late hello's refusal nor the rescan's ever did.
/// Since #2189 a scan whose baseline is the server's copy reads every answer from the server, so the Mac's refusal
/// shows within one poll whatever the replica holds. `replicaMac` here is a replica that never catches up.
extension LinkingViewModelTests {
    /// The Mac's code closed before the hello arrived: it refused the hello at once (`expired_code`).
    func testALateHellosRefusalShowsWhileTheReplicaNeverCatchesUp() async throws {
        let payload = code()
        let answer = refusal(.expiredCode, decidedAt: start.addingTimeInterval(1))
        host.mac = { writes in writes.contains { $0.linkNonce == payload.nonce } ? answer : nil }
        host.replicaMac = { _ in nil }
        let model = makeModel()

        await model.open(payload.url())

        XCTAssertEqual(model.phase, .failed(.refused))
        XCTAssertLessThan(clock.slept, LinkingViewModel.grantPollInterval * 2, "the first read after the hello")
        XCTAssertTrue(host.keyboxReads.allSatisfy { $0.kind == .server }, "never the lagging replica")
    }

    /// The rescan: the server still holds the earlier code's refusal (the baseline), and the Mac refuses the rescan's
    /// hello too (`not_confirmed`, its code closed); the replica still shows the earlier refusal.
    func testARescansRefusalShowsOverTheEarlierOneWhileTheReplicaNeverCatchesUp() async throws {
        let payload = code()
        let (stale, answer) = (staleRefusal, refusal(.notConfirmed, decidedAt: start.addingTimeInterval(1)))
        host.mac = { writes in writes.contains { $0.linkNonce == payload.nonce } ? answer : stale }
        host.replicaMac = { _ in stale }
        let model = makeModel()

        await model.open(payload.url())

        XCTAssertEqual(model.phase, .failed(.refused))
        XCTAssertNil(LinkStore(defaults: defaults).pending, "the refused scan leaves no pending link")
        XCTAssertTrue(host.keyboxReads.allSatisfy { $0.kind == .server }, "never the lagging replica")
    }

    /// The relaunch: killed after the hello, the refusal published meanwhile, the replica still on the earlier one.
    func testARelaunchTakesThisScansRefusalWhileTheReplicaNeverCatchesUp() async throws {
        let payload = try await killedAfterTheHello()
        let (stale, answer) = (staleRefusal, refusal(.notConfirmed, decidedAt: start.addingTimeInterval(1)))
        host.mac = { writes in writes.contains { $0.linkNonce == payload.nonce } ? answer : stale }
        host.replicaMac = { _ in stale }
        let relaunched = makeModel()

        await relaunched.resumePendingLink()

        XCTAssertEqual(relaunched.phase, .failed(.refused))
    }

    /// The v0.29.2 path, still taken when the server read fails at the scan: the baseline comes from the replica and
    /// so does every read of the wait, so a replica that never catches up ends the wait unanswered (known limit: the
    /// server's copy is never compared with a replica baseline, which may lag it).
    func testAReplicaBaselineStillWaitsOnTheReplica() async throws {
        let payload = code()
        let answer = refusal(.expiredCode, decidedAt: start.addingTimeInterval(1))
        host.mac = { writes in writes.contains { $0.linkNonce == payload.nonce } ? answer : nil }
        host.replicaMac = { _ in nil }
        host.failingServerReads = 1
        let model = makeModel()

        await model.open(payload.url())

        XCTAssertEqual(model.phase, .failed(.noAnswer))
        XCTAssertEqual(host.keyboxReads.filter { $0.kind == .server }.count, 1, "only the failed baseline read")
    }
}
