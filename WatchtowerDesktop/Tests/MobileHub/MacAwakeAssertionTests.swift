import Foundation
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

@MainActor
final class MacAwakeAssertionTests: XCTestCase {
    private final class FakePower: PowerAsserting {
        private(set) var created: [String] = []
        private(set) var released: [UInt32] = []
        var failNext = false
        func create(reason: String) -> UInt32? {
            if failNext { failNext = false; return nil }
            created.append(reason)
            return UInt32(created.count)
        }
        func release(_ id: UInt32) { released.append(id) }
    }

    func testHoldingCreatesOneAssertionNoMatterHowOftenItIsAsked() {
        let power = FakePower()
        let assertion = MacAwakeAssertion(power: power)
        assertion.update(hold: true)
        assertion.update(hold: true)
        XCTAssertEqual(power.created, ["Watchtower: a session is running and your iPhone is connected"])
        XCTAssertTrue(assertion.isHolding)
    }

    func testReleasingOnceAndNotAgain() {
        let power = FakePower()
        let assertion = MacAwakeAssertion(power: power)
        assertion.update(hold: true)
        assertion.update(hold: false)
        assertion.update(hold: false)
        XCTAssertEqual(power.released, [1])
        XCTAssertFalse(assertion.isHolding)
    }

    func testItIsCreatedAgainAfterARelease() {
        let power = FakePower()
        let assertion = MacAwakeAssertion(power: power)
        assertion.update(hold: true)
        assertion.update(hold: false)
        assertion.update(hold: true)
        XCTAssertEqual(power.created.count, 2)
        XCTAssertEqual(power.released, [1])
    }

    func testAFailedCreateIsRetriedOnTheNextUpdate() {
        let power = FakePower()
        power.failNext = true
        let assertion = MacAwakeAssertion(power: power)
        assertion.update(hold: true)
        XCTAssertFalse(assertion.isHolding)
        assertion.update(hold: true)
        XCTAssertTrue(assertion.isHolding)
    }

    func testTheCompanionHoldsOnASessionAndRecentContactAndReleasesOnStop() async throws {
        let power = FakePower()
        let assertion = MacAwakeAssertion(power: power)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let companion = KeepAwakeCompanion(
            assertion: assertion, enabled: { true }, liveBoardSessions: { 2 },
            lastPhoneContact: { now.addingTimeInterval(-10) }, now: { now }
        )
        await companion.evaluate()
        XCTAssertTrue(assertion.isHolding)
        companion.stop()
        XCTAssertFalse(assertion.isHolding)
        XCTAssertEqual(power.released, [1])
    }
}
