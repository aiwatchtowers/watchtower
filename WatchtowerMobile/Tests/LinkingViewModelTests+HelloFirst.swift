import Foundation
import WatchtowerE2ETesting
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

private let helloAcme = TestE2E.hubID.uuidString

// MARK: - The hello before any full fetch (#2189)

/// The scan's baseline is one read of the keybox record (`LinkHost.serverKeybox`), never the fresh replica's full
/// download, so the hello reaches the Mac while its code is open; the Mac's answer to this scan is still told apart
/// from an earlier code's refusal by the baseline, across a kill too.
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

    func testTheHelloIsWrittenBeforeAnyFullFetch() async throws {
        let payload = code()
        macLinks(payload)
        let model = makeModel()

        await model.open(payload.url())

        XCTAssertEqual(model.phase, .linked(macName: "Acme Mac"))
        XCTAssertEqual(host.keyboxReads.first, .init(kind: .server, writesBefore: 0), "the baseline: one record read")
        XCTAssertFalse(host.keyboxReads.contains { $0.kind == .fetch }, "no zone fetch, before the hello or after it")
        let writes = try await host.deviceWrites()
        XCTAssertEqual(writes.count, 1, "one hello")
    }

    /// A server read that fails falls back to the zone fetch: slower, never a baseline guessed as empty.
    func testAFailedServerReadTakesTheBaselineFromTheFetch() async throws {
        host.serverReadFails = true
        let payload = code()
        let stale = staleRefusal
        host.mac = { writes in writes.isEmpty ? stale : nil }
        let model = makeModel()

        await model.open(payload.url())

        XCTAssertEqual(Array(host.keyboxReads.prefix(2)), [.init(kind: .server, writesBefore: 0), .init(kind: .fetch, writesBefore: 0)])
        XCTAssertEqual(model.phase, .failed(.noAnswer), "the earlier refusal is the baseline, not this scan's answer")
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
        let writes = try await host.deviceWrites()
        XCTAssertEqual(writes.count, 1, "the hello went out")
        return payload
    }

    func testAKillAfterTheHelloNeverTakesTheEarlierRefusalOnRelaunch() async throws {
        _ = try await killedAfterTheHello()
        let relaunched = makeModel()

        await relaunched.resumePendingLink()

        XCTAssertEqual(relaunched.phase, .failed(.noAnswer), "not .refused: the refusal is an earlier code's")
        XCTAssertTrue(host.linkedCalls.isEmpty)
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
        XCTAssertEqual(writes.count, 0, "no hello")
        XCTAssertEqual(host.keyboxReads.count, 1, "no fallback fetch after the kill")
        XCTAssertEqual(LinkStore(defaults: defaults).pending?.baselineCaptured, false)
    }
}
