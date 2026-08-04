import XCTest
@testable import WatchtowerDesktop

final class SingleInstanceGuardTests: XCTestCase {
    func test_otherInstanceRunning_returnsItsPID() {
        let pid = SingleInstanceGuard.duplicatePID(
            bundleID: "com.watchtower.desktop",
            runningPIDs: [4242, 100],
            currentPID: 100
        )
        XCTAssertEqual(pid, 4242)
    }

    func test_onlySelfRunning_returnsNil() {
        XCTAssertNil(SingleInstanceGuard.duplicatePID(
            bundleID: "com.watchtower.desktop",
            runningPIDs: [100],
            currentPID: 100
        ))
    }

    func test_noRunningApps_returnsNil() {
        XCTAssertNil(SingleInstanceGuard.duplicatePID(
            bundleID: "com.watchtower.desktop",
            runningPIDs: [],
            currentPID: 100
        ))
    }

    /// A bare `swift run` binary has no bundle identifier: it must never
    /// mistake an unrelated process for a duplicate of itself.
    func test_nilBundleID_returnsNil() {
        XCTAssertNil(SingleInstanceGuard.duplicatePID(
            bundleID: nil,
            runningPIDs: [4242, 100],
            currentPID: 100
        ))
    }

    func test_emptyBundleID_returnsNil() {
        XCTAssertNil(SingleInstanceGuard.duplicatePID(
            bundleID: "",
            runningPIDs: [4242, 100],
            currentPID: 100
        ))
    }

    func test_multipleOthers_returnsFirst() {
        let pid = SingleInstanceGuard.duplicatePID(
            bundleID: "com.watchtower.desktop",
            runningPIDs: [4242, 100, 5353],
            currentPID: 100
        )
        XCTAssertEqual(pid, 4242)
    }
}
