import Foundation
import WatchtowerHostedRelay
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// The link route rule (relay client Phase 3 Task 10, R4), every row: which way a code links, and what it is
/// refused with. Pure: `paying` is a closure that counts its calls.
final class LinkRoutePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let mac = RelayTestMac(seed: 7)
    private let available = RelayAvailability.available(FakeRelayOps.origin)
    private let hub = "C0DE0000-0000-4000-8000-000000000001"

    private func code(_ transport: TransportKind?, cloudKit: Bool = true, identity: Bool = true, macName: String = "Work Mac") -> LinkPayload {
        mac.code(hubID: hub, macName: macName, owner: "_owner-acme", now: now, transport: transport, cloudKit: cloudKit, identity: identity)
    }

    private func decide(
        _ code: LinkPayload, relay: RelayAvailability, paying answer: Result<Bool, HostedRelayPairing.Refusal> = .success(true)
    ) async -> (LinkRoute, asked: Int) {
        var asked = 0
        let route = await LinkRoutePolicy.decide(code, relay: relay) {
            asked += 1
            return answer
        }
        return (route, asked)
    }

    func testACloudKitCodeLinksOverICloud() async {
        // A code that offers Relay asks while the relay is available: a free phone links over iCloud.
        for (transport, relay) in [(nil, available), (TransportKind.cloudKit, available), (nil, .off(.notConfigured))] {
            let (route, asked) = await decide(code(transport), relay: relay, paying: .success(false))
            XCTAssertEqual(route, .cloudKit, "\(String(describing: transport))")
            XCTAssertEqual(asked, relay == available ? 1 : 0, "a hub on iCloud asks the relay only while it is available")
        }
        // A v3 code (no relay fields at all).
        let v3 = LinkPayload(
            hubID: hub, macName: "Work Mac", ownerUser: "_owner-acme", nonce: LinkPayload.makeNonce(), iat: 0, exp: 600,
            hubSigningKey: code(nil).hubSigningKey, hubAgreementKey: code(nil).hubAgreementKey
        )
        let (route, asked) = await decide(v3, relay: available)
        XCTAssertEqual(route, .cloudKit)
        XCTAssertEqual(asked, 0)
    }

    /// `decide` with an entitlement answer: the route, the paying asks and the entitlement reads.
    private func decide(
        _ code: LinkPayload, relay: RelayAvailability, entitled: Bool, paying answer: Result<Bool, HostedRelayPairing.Refusal>
    ) async -> (LinkRoute, asked: Int, entitlementAsked: Int) {
        var asked = 0
        var entitlementAsked = 0
        let route = await LinkRoutePolicy.decide(code, relay: relay, entitled: {
            entitlementAsked += 1
            return entitled
        }, paying: {
            asked += 1
            return answer
        })
        return (route, asked, entitlementAsked)
    }

    func testAPayingPhoneLinksACloudKitMacOverRelay() async {
        for cloudKitCode in [code(.cloudKit), code(nil)] {
            let (route, asked, entitlementAsked) = await decide(cloudKitCode, relay: available, entitled: true, paying: .success(true))
            XCTAssertEqual(route, .relay(mac: mac.deviceID, authPub: mac.authPub), "\(String(describing: cloudKitCode.transport))")
            XCTAssertEqual(asked, 1)
            XCTAssertEqual(entitlementAsked, 0, "a definite yes needs no entitlement read")
        }
    }

    /// A paying phone whose slots all hold other Macs links an iCloud Mac over iCloud, as before #2191; a Mac already
    /// in its slots, or a free slot, still goes over Relay. A hub on Relay is unchanged (the slots screen follows).
    func testAPayingPhoneWithEverySlotTakenLinksAnICloudMacOverICloud() async {
        let others = ["m1", "m2", "m3"]
        for (macs, expected) in [
            (others, LinkRoute.cloudKit),
            (["m1", "m2", mac.deviceID], .relay(mac: mac.deviceID, authPub: mac.authPub)),
            (["m1", "m2"], .relay(mac: mac.deviceID, authPub: mac.authPub))
        ] {
            let route = await LinkRoutePolicy.route(
                code(.cloudKit), relay: available, entitled: { true }, iCloudUsable: { true },
                account: { .success((paying: true, macs: macs)) }
            )
            XCTAssertEqual(route, expected, "\(macs)")
        }
        let onRelay = await LinkRoutePolicy.route(
            code(.relay), relay: available, entitled: { true }, iCloudUsable: { true },
            account: { .success((paying: true, macs: others)) }
        )
        XCTAssertEqual(onRelay, .relay(mac: mac.deviceID, authPub: mac.authPub))
    }

    /// Full slots without a usable iCloud: the relay route, so the slots screen can free a slot (review round 2).
    func testFullSlotsWithoutICloudKeepTheRelayRoute() async {
        var iCloudAsks = 0
        let full = await LinkRoutePolicy.route(
            code(.cloudKit), relay: available, entitled: { true },
            iCloudUsable: {
                iCloudAsks += 1
                return false
            },
            account: { .success((paying: true, macs: ["m1", "m2", "m3"])) }
        )
        XCTAssertEqual(full, .relay(mac: mac.deviceID, authPub: mac.authPub))
        XCTAssertEqual(iCloudAsks, 1)
        let free = await LinkRoutePolicy.route(
            code(.cloudKit), relay: available, entitled: { true },
            iCloudUsable: {
                iCloudAsks += 1
                return false
            },
            account: { .success((paying: true, macs: ["m1"])) }
        )
        XCTAssertEqual(free, .relay(mac: mac.deviceID, authPub: mac.authPub))
        XCTAssertEqual(iCloudAsks, 1, "iCloud is asked only on full slots")
    }

    /// A cancelled caller stops waiting at once and reads "not entitled"; the shared read goes on (review rounds 2, 3).
    func testACancelledEntitlementWaitIsNotEntitled() async {
        let readGate = Gate()
        let shared = SharedEntitlementRead(clock: FakeLinkClock(now: now)) {
            await readGate.wait()
            return true
        }
        let (registered, signal) = AsyncStream<Void>.makeStream()
        let timeoutGate = Gate()
        let waiting = Task {
            await shared {
                signal.yield()
                await timeoutGate.wait()
            }
        }
        var signals = registered.makeAsyncIterator()
        _ = await signals.next()

        waiting.cancel()
        let answer = await waiting.value

        XCTAssertFalse(answer)
        XCTAssertEqual(shared.waiting, 0, "the cancelled caller left")
        XCTAssertEqual(shared.readsStarted, 1)
        readGate.open()
    }

    /// A caller already cancelled starts no read (review round 3).
    func testAnAlreadyCancelledCallerStartsNoRead() async {
        let shared = SharedEntitlementRead(clock: FakeLinkClock(now: now)) { true }
        let answer = await Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            return await shared {}
        }.value
        XCTAssertFalse(answer)
        XCTAssertEqual(shared.readsStarted, 0)
    }

    /// Scans while a read hangs share it: one StoreKit read, however many callers. A caller that times out leaves
    /// (no waiter kept), and its leaving never cancels the shared read (review rounds 2, 3).
    func testScansWhileAReadHangsShareIt() async {
        let readGate = Gate()
        let shared = SharedEntitlementRead(clock: FakeLinkClock(now: now)) {
            await readGate.wait()
            return !Task.isCancelled
        }
        let (registered, signal) = AsyncStream<Void>.makeStream()
        let firstTimeout = Gate()
        let secondTimeout = Gate()
        let first = Task {
            await shared {
                signal.yield()
                await firstTimeout.wait()
            }
        }
        let second = Task {
            await shared {
                signal.yield()
                await secondTimeout.wait()
            }
        }
        var signals = registered.makeAsyncIterator()
        _ = await signals.next()
        _ = await signals.next()
        XCTAssertEqual(shared.readsStarted, 1, "the second scan waits on the read in flight")
        XCTAssertEqual(shared.waiting, 2)

        firstTimeout.open()
        let timedOut = await first.value
        XCTAssertFalse(timedOut, "each caller's own bound applies")
        XCTAssertEqual(shared.waiting, 1, "the timed-out caller left")

        readGate.open()
        let answered = await second.value
        XCTAssertTrue(answered, "no caller cancelled the read")
        XCTAssertEqual(shared.waiting, 0)
        XCTAssertEqual(shared.readsStarted, 1)
    }

    /// A read older than its age limit is abandoned: the next caller starts a new one and gets its answer (review
    /// round 3).
    func testAHungReadPastItsAgeIsReplaced() async {
        let clock = FakeLinkClock(now: now)
        let reads = ReadCount()
        let oldGate = Gate()
        let shared = SharedEntitlementRead(maxAge: 60, clock: clock) {
            guard reads.add() == 1 else { return true }
            await oldGate.wait()
            return false
        }
        let early = await shared {}
        XCTAssertFalse(early)
        clock.advance(by: 30)
        _ = await shared {}
        XCTAssertEqual(shared.readsStarted, 1, "a read younger than its limit is shared")

        clock.advance(by: 31)
        let timeoutGate = Gate()
        let fresh = await shared { await timeoutGate.wait() }

        XCTAssertTrue(fresh, "the new read's answer")
        XCTAssertEqual(shared.readsStarted, 2)
        oldGate.open()
    }

    func testAnUnknownPayingAnswerWithAnEntitlementIsRelayUnreachable() async {
        for answer in [Result<Bool, HostedRelayPairing.Refusal>.failure(.unreachable), .failure(.attestationBackoff(until: now))] {
            let (route, _, entitlementAsked) = await decide(code(.cloudKit), relay: available, entitled: true, paying: answer)
            XCTAssertEqual(route, .refuse(.relayUnreachable), "\(answer)")
            XCTAssertEqual(entitlementAsked, 1)
        }
    }

    func testAnUnknownPayingAnswerWithoutAnEntitlementLinksOverICloud() async {
        for answer in [Result<Bool, HostedRelayPairing.Refusal>.failure(.unreachable), .failure(.attestationBackoff(until: now))] {
            let (route, _, entitlementAsked) = await decide(code(.cloudKit), relay: available, entitled: false, paying: answer)
            XCTAssertEqual(route, .cloudKit, "\(answer)")
            XCTAssertEqual(entitlementAsked, 1)
        }
    }

    func testAFreePhoneLinksACloudKitCodeOverICloud() async {
        for answer in [Result<Bool, HostedRelayPairing.Refusal>.success(false), .failure(.notPaying)] {
            let (route, asked, entitlementAsked) = await decide(code(.cloudKit), relay: available, entitled: true, paying: answer)
            XCTAssertEqual(route, .cloudKit, "\(answer)")
            XCTAssertEqual(asked, 1)
            XCTAssertEqual(entitlementAsked, 0, "a definite answer needs no entitlement read")
        }
    }

    func testRelayOffNeverAsksOnACloudKitCode() async {
        for relay in [RelayAvailability.off(.notConfigured), .off(.unsupportedDevice)] {
            let (route, asked, entitlementAsked) = await decide(code(.cloudKit), relay: relay, entitled: true, paying: .success(true))
            XCTAssertEqual(route, .cloudKit, "\(relay)")
            XCTAssertEqual(asked, 0)
            XCTAssertEqual(entitlementAsked, 0)
        }
    }

    func testACloudKitCodeWithoutRelayNeverAsks() async {
        let iCloudOnly = mac.code(hubID: hub, macName: "Work Mac", owner: "_owner-acme", now: now, transport: .cloudKit, transports: ["cloudkit"])
        let (route, asked, entitlementAsked) = await decide(iCloudOnly, relay: available, entitled: true, paying: .success(true))
        XCTAssertEqual(route, .cloudKit)
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(entitlementAsked, 0)
    }

    func testUpdateRequiredOnACloudKitCodeIsUpdateApp() async {
        let (route, _, _) = await decide(code(.cloudKit), relay: available, entitled: false, paying: .failure(.updateRequired))
        XCTAssertEqual(route, .refuse(.updateApp))
    }

    func testAPayingPhoneLinksAMacOnRelayOverAPairingSlot() async {
        for cloudKit in [true, false] {
            let (route, asked) = await decide(code(.relay, cloudKit: cloudKit), relay: available)
            XCTAssertEqual(route, .relay(mac: mac.deviceID, authPub: mac.authPub))
            XCTAssertEqual(asked, 1)
        }
    }

    func testARelayMacOnAFreePhoneIsRefusedWithNoDeadOption() async {
        for (relay, answer) in [
            (RelayAvailability.off(.notConfigured), Result<Bool, HostedRelayPairing.Refusal>.success(true)),
            (available, .success(false)),
            (available, .failure(.notPaying))
        ] {
            let (route, _) = await decide(code(.relay), relay: relay, paying: answer)
            XCTAssertEqual(route, .refuse(.macOnRelay(macName: "Work Mac")), "\(relay) \(answer)")
        }
    }

    func testARelayOnlyHubOnAFreePhoneNeedsRelay() async {
        for (relay, answer) in [
            (RelayAvailability.off(.notConfigured), Result<Bool, HostedRelayPairing.Refusal>.success(true)),
            (available, .success(false))
        ] {
            let (route, _) = await decide(code(.relay, cloudKit: false, macName: "build-box"), relay: relay, paying: answer)
            XCTAssertEqual(route, .refuse(.needsRelay(macName: "build-box")))
        }
        // A v4 code without `transport` that offers only the relay is the same headless host.
        let (route, _) = await decide(code(nil, cloudKit: false, macName: "build-box"), relay: .off(.notConfigured))
        XCTAssertEqual(route, .refuse(.needsRelay(macName: "build-box")))
    }

    func testUnsupportedDeviceNeverAsksTheRelay() async {
        let (route, asked) = await decide(code(.relay, cloudKit: false, macName: "build-box"), relay: .off(.unsupportedDevice))
        XCTAssertEqual(route, .refuse(.needsRelay(macName: "build-box")))
        XCTAssertEqual(asked, 0)
    }

    func testUpdateRequiredIsUpdateApp() async {
        let (route, _) = await decide(code(.relay), relay: available, paying: .failure(.updateRequired))
        XCTAssertEqual(route, .refuse(.updateApp))
    }

    func testAnUnknownPayingAnswerIsRelayUnreachableNeverICloud() async {
        for answer in [
            Result<Bool, HostedRelayPairing.Refusal>.failure(.unreachable),
            .failure(.attestationBackoff(until: now)),
            .failure(.slotsFull(macs: []))
        ] {
            let (route, _) = await decide(code(.relay), relay: available, paying: answer)
            XCTAssertEqual(route, .refuse(.relayUnreachable), "\(answer)")
        }
    }

    /// Carry-over 5: the copy each malformed or unusable code gets. A code with half a relay identity never parses
    /// (`.refused` by the link flow); a v4 code naming no usable route, or a relay hub without its identity, is
    /// `.refused`; a v5 code asks for an app update before anything else.
    func testWhichCopyEachUnusableCodeGets() async {
        let (none, _) = await decide(code(nil, cloudKit: false, identity: false), relay: available)
        XCTAssertEqual(none, .refuse(.refused), "neither iCloud nor a relay identity")
        let (noIdentity, asked) = await decide(code(.relay, identity: false), relay: available)
        XCTAssertEqual(noIdentity, .refuse(.refused), "a hub on the relay that does not say who it is")
        XCTAssertEqual(asked, 0)
        XCTAssertEqual(LinkPayload.parse(code(.relay).url()).map(\.v), .success(4))
        var components = URLComponents(url: code(.relay).url(), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "d", value: "e30")]
        XCTAssertEqual(LinkPayload.parse(components?.url ?? code(.relay).url()), .failure(.missingField("v")))
    }

    func testNoRelayFailureOffersLinkOverICloud() {
        let failures: [LinkFailure] = [
            .needsRelay(macName: "build-box"), .relayUnreachable, .macOnRelay(macName: "Work Mac"), .macNotOnRelay(macName: "build-box")
        ]
        for failure in failures {
            XCTAssertTrue(failure.offersScan || failure.retryTitle != nil, "\(failure)")
            XCTAssertFalse("\(failure.title) \(failure.hint ?? "")".contains("Link over iCloud"), "\(failure)")
        }
    }

    /// Carry-over 2: an account-state error the pairing does not map is transient, never "not paying".
    func testAnUnmappedAccountStateErrorIsTransient() async {
        let unmapped = await LinkRoutePolicy.paying { throw HostedRelayError.server(code: .forbidden, retryAfter: nil) }
        XCTAssertEqual(unmapped, .failure(.unreachable))
        let other = await LinkRoutePolicy.paying { throw URLError(.timedOut) }
        XCTAssertEqual(other, .failure(.unreachable))
        let update = await LinkRoutePolicy.paying { throw HostedRelayPairing.Refusal.updateRequired }
        XCTAssertEqual(update, .failure(.updateRequired))
        let free = await LinkRoutePolicy.paying { (paying: false, macs: []) }
        XCTAssertEqual(free, .success(false))
    }
}

/// How many entitlement reads started.
private final class ReadCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    /// Counts one read; its number.
    func add() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

/// A gate a fake waits on until the test opens it. Never opened, it waits until its task is cancelled. One waiter.
private final class Gate: Sendable {
    private let pair = AsyncStream<Void>.makeStream()

    func wait() async {
        for await _ in pair.stream {}
    }

    func open() {
        pair.continuation.finish()
    }
}
