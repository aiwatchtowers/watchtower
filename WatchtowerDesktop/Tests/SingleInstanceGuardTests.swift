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

    func test_certainlyOlderPeer_returnsItsPID() {
        let current = instance(100, 60)
        let older = instance(4242, 0)
        XCTAssertEqual(SingleInstanceGuard.instanceToDefer(candidates: [older, current], current: current), 4242)
    }

    func test_newerPeer_returnsNil() {
        let current = instance(100, 0)
        let newer = instance(4242, 60)
        XCTAssertNil(SingleInstanceGuard.instanceToDefer(candidates: [newer, current], current: current))
    }

    /// Every certainly-older peer is a valid target, so the choice is pinned by pid,
    /// not by launch date — both sides of a race pick the same one.
    func test_multipleCertainlyOlderPeers_returnsLowestPID() {
        let current = instance(5353, 90)
        let lowPID = instance(100, 30)
        let earliest = instance(4242, 10)
        XCTAssertEqual(
            SingleInstanceGuard.instanceToDefer(candidates: [lowPID, current, earliest], current: current),
            100
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

    /// The same pair of instances, each side seeing what it can actually observe: A sees
    /// B mid-launch (no launch date yet), B sees A fully. The mismatch makes A keep
    /// running and the comparable view makes B defer — one survivor across the pair,
    /// which per-side candidate arrays are what expose (a single shared array would
    /// hide that the two sides disagree about what is observable).
    func test_asymmetricObservation_mismatchedSideKeepsRunning_comparableSideDefers() {
        let aAsSeenByItself = instance(100, 0)
        let bAsSeenByA = instance(200, nil)
        XCTAssertNil(
            SingleInstanceGuard.instanceToDefer(candidates: [bAsSeenByA], current: aAsSeenByItself)
        )

        let bAsSeenByItself = instance(200, 1)
        let aAsSeenByB = instance(100, 0)
        XCTAssertEqual(
            SingleInstanceGuard.instanceToDefer(candidates: [aAsSeenByB], current: bAsSeenByItself),
            100
        )
    }

    /// The mirror mismatch: a dated peer against a launch date we cannot see for
    /// ourselves is equally incomparable, so it is equally not a reason to exit.
    func test_datedPeerAgainstNilDateCurrent_keepsRunning() {
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
