import XCTest
@testable import WatchtowerCore

final class KeepAwakePolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func hold(enabled: Bool = true, sessions: Int = 1, contactAgo: TimeInterval? = 60) -> Bool {
        KeepAwakePolicy.shouldHold(
            enabled: enabled, liveBoardSessions: sessions,
            lastPhoneContact: contactAgo.map { now.addingTimeInterval(-$0) }, now: now
        )
    }

    func testHoldsWithASessionAndARecentPhone() {
        XCTAssertTrue(hold())
    }

    func testTheToggleOffNeverHolds() {
        XCTAssertFalse(hold(enabled: false))
    }

    func testNoLiveSessionNeverHolds() {
        XCTAssertFalse(hold(sessions: 0))
    }

    func testNoPhoneContactNeverHolds() {
        XCTAssertFalse(hold(contactAgo: nil))
    }

    func testContactExactlyAtTheWindowStillHolds() {
        XCTAssertTrue(hold(contactAgo: 86_400))
    }

    func testContactOneSecondPastTheWindowDoesNotHold() {
        XCTAssertFalse(hold(contactAgo: 86_401))
    }

    func testAContactStampedInTheFutureHolds() {
        XCTAssertTrue(hold(contactAgo: -30))
    }
}
