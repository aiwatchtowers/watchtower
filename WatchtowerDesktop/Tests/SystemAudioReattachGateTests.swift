import XCTest
@testable import WatchtowerDesktop

final class SystemAudioReattachGateTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "SystemAudioReattachGateTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testReattachIsOnWhenNeverSet() {
        XCTAssertTrue(
            SystemAudioRecorder.reattachEnabled(defaults),
            "ships on: without it a device switch loses the call for the rest of the meeting"
        )
    }

    func testReattachFollowsTheToggle() {
        defaults.set(false, forKey: SystemAudioRecorder.reattachKey)
        XCTAssertFalse(SystemAudioRecorder.reattachEnabled(defaults))
        defaults.set(true, forKey: SystemAudioRecorder.reattachKey)
        XCTAssertTrue(SystemAudioRecorder.reattachEnabled(defaults))
    }
}
