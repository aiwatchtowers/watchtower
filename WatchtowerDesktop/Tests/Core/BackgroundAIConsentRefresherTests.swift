import Foundation
import XCTest
@testable import WatchtowerCore

/// An answer given outside the Desktop (a terminal, a profile change) is
/// re-read when the app becomes active (plan Decision 12).
@MainActor
final class BackgroundAIConsentRefresherTests: XCTestCase {
    private let activation = Notification.Name("BackgroundAIConsentRefresherTests.activation")

    func testActivationRereadsAnswer() {
        let center = NotificationCenter()
        var reloads = 0
        let refresher = BackgroundAIConsentRefresher(center: center, activation: activation) { reloads += 1 }

        center.post(name: activation, object: nil)
        XCTAssertEqual(reloads, 0, "not started: nothing observes")

        refresher.start()
        XCTAssertEqual(reloads, 0, "start only observes")
        center.post(name: activation, object: nil)
        XCTAssertEqual(reloads, 1)

        refresher.start() // a second start does not observe twice
        center.post(name: activation, object: nil)
        XCTAssertEqual(reloads, 2)

        refresher.stop()
        center.post(name: activation, object: nil)
        XCTAssertEqual(reloads, 2, "stopped: activation no longer re-reads")
    }

    func testOtherNotificationsAreIgnored() {
        let center = NotificationCenter()
        var reloads = 0
        let refresher = BackgroundAIConsentRefresher(center: center, activation: activation) { reloads += 1 }
        refresher.start()
        center.post(name: Notification.Name("BackgroundAIConsentRefresherTests.other"), object: nil)
        XCTAssertEqual(reloads, 0)
        refresher.stop()
    }
}
