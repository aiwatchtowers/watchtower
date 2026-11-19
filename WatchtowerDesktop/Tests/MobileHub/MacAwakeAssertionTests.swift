import Foundation
import XCTest
@testable import WatchtowerDesktop
import GRDB
import WatchtowerCore
import WatchtowerTestSupport

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

    /// An assertion still held when its owner goes away is released.
    func testDeinitReleasesAHeldAssertion() {
        let power = FakePower()
        var assertion: MacAwakeAssertion? = MacAwakeAssertion(power: power)
        assertion?.update(hold: true)
        XCTAssertTrue(power.released.isEmpty)
        assertion = nil
        XCTAssertEqual(power.released, [1])
    }
}
