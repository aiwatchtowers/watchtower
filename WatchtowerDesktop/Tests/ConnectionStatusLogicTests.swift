import XCTest
@testable import WatchtowerDesktop

final class ConnectionStatusLogicTests: XCTestCase {
    func testNoAccountsIsNotConfigured() {
        XCTAssertEqual(ConnectionStatusLogic.derive(okCount: 0, problemCount: 0), .notConfigured)
    }

    func testAnyProblemIsError() {
        XCTAssertEqual(ConnectionStatusLogic.derive(okCount: 2, problemCount: 1), .error)
        XCTAssertEqual(ConnectionStatusLogic.derive(okCount: 0, problemCount: 1), .error)
    }

    func testAllOKIsConnected() {
        XCTAssertEqual(ConnectionStatusLogic.derive(okCount: 1, problemCount: 0), .connected)
    }
}
