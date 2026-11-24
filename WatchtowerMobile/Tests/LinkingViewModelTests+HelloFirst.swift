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

    /// The fetch fallback counts only when the data zone was polled to its end during it (a throttled or cut pull
    /// returns normally).
    func testALinkFetchCountsOnlyWhenItReadTheDataZone() {
        XCTAssertFalse(HubSession.linkFetchCompleted(refreshed: false, pollsBefore: 1, pollsAfter: 2))
        XCTAssertFalse(HubSession.linkFetchCompleted(refreshed: true, pollsBefore: 3, pollsAfter: 3), "a skipped pull")
        XCTAssertTrue(HubSession.linkFetchCompleted(refreshed: true, pollsBefore: 3, pollsAfter: 4))
        XCTAssertTrue(HubSession.linkFetchCompleted(refreshed: true, pollsBefore: nil, pollsAfter: nil), "off CloudKit")
    }

    // MARK: The session's mapping of a read

    func testAReadsThrowIsUnavailableNeverAnAbsence() async throws {
        let failures: [any Error] = [
            CancellationError(), KeyStoreError.locked, SecureTransportError.keysUnavailable, DirectCallRefusal.unreadableRecord,
            DirectCallRefusal.throttled
        ]
        for failure in failures {
            let read = await HubSession.keyboxRead { throw failure }
            guard case .unavailable = read else { return XCTFail("\(failure) read as \(read)") }
        }
        let absent = await HubSession.keyboxRead { nil }
        XCTAssertEqual(absent, .read(nil))
        let box = Keybox(grant: staleRefusal, keys: nil)
        let present = await HubSession.keyboxRead { box }
        XCTAssertEqual(present, .read(box))
    }
}
