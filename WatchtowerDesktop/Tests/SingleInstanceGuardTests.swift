import XCTest
@testable import WatchtowerDesktop

final class SingleInstanceGuardTests: XCTestCase {
    private typealias Instance = SingleInstanceGuard.InstanceInfo

    private static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func instance(_ pid: pid_t, _ offset: TimeInterval?, terminated: Bool = false) -> Instance {
        Instance(
            pid: pid,
            launchDate: offset.map { Self.epoch.addingTimeInterval($0) },
            isTerminated: terminated
        )
    }

    func test_onlySelfInCandidates_returnsNil() {
        let current = instance(100, 0)
        XCTAssertNil(SingleInstanceGuard.instanceToDefer(candidates: [current], current: current))
    }

    func test_noCandidates_returnsNil() {
        XCTAssertNil(SingleInstanceGuard.instanceToDefer(candidates: [], current: instance(100, 0)))
    }

    func test_olderPeer_returnsItsPID() {
        let current = instance(100, 60)
        let older = instance(4242, 0)
        XCTAssertEqual(SingleInstanceGuard.instanceToDefer(candidates: [older, current], current: current), 4242)
    }

    func test_newerPeer_returnsNil() {
        let current = instance(100, 0)
        let newer = instance(4242, 60)
        XCTAssertNil(SingleInstanceGuard.instanceToDefer(candidates: [newer, current], current: current))
    }

    func test_multipleOlderPeers_returnsOldest() {
        let current = instance(100, 90)
        let older = instance(4242, 30)
        let oldest = instance(5353, 10)
        XCTAssertEqual(
            SingleInstanceGuard.instanceToDefer(candidates: [older, current, oldest], current: current),
            5353
        )
    }

    /// Two instances launched in the same instant must not both defer (nor both
    /// survive): the pid tie-break has to give exactly one survivor, whichever
    /// side asks.
    func test_equalLaunchDates_exactlyOneSurvivor() {
        let low = instance(100, 0)
        let high = instance(4242, 0)
        let candidates = [low, high]

        XCTAssertNil(SingleInstanceGuard.instanceToDefer(candidates: candidates, current: low))
        XCTAssertEqual(SingleInstanceGuard.instanceToDefer(candidates: candidates, current: high), 100)
    }

    func test_bothLaunchDatesNil_exactlyOneSurvivor() {
        let low = instance(100, nil)
        let high = instance(4242, nil)
        let candidates = [low, high]

        XCTAssertNil(SingleInstanceGuard.instanceToDefer(candidates: candidates, current: low))
        XCTAssertEqual(SingleInstanceGuard.instanceToDefer(candidates: candidates, current: high), 100)
    }

    /// An unobservable launch date means the peer started before we could see it.
    func test_nilDatePeerAgainstDatedCurrent_peerWins() {
        let current = instance(100, 0)
        let peer = instance(4242, nil)
        XCTAssertEqual(SingleInstanceGuard.instanceToDefer(candidates: [peer, current], current: current), 4242)
    }

    func test_datedPeerAgainstNilDateCurrent_returnsNil() {
        let current = instance(100, nil)
        let peer = instance(4242, 0)
        XCTAssertNil(SingleInstanceGuard.instanceToDefer(candidates: [peer, current], current: current))
    }

    /// A dying peer is not a survivor to defer to, however old it is.
    func test_terminatedOlderPeer_isIgnored() {
        let current = instance(100, 60)
        let dying = instance(4242, 0, terminated: true)
        XCTAssertNil(SingleInstanceGuard.instanceToDefer(candidates: [dying, current], current: current))
    }

    func test_terminatedOlderPeer_doesNotMaskLiveOlderPeer() {
        let current = instance(100, 90)
        let dying = instance(4242, 0, terminated: true)
        let live = instance(5353, 30)
        XCTAssertEqual(
            SingleInstanceGuard.instanceToDefer(candidates: [dying, live, current], current: current),
            5353
        )
    }
}
