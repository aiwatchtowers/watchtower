import XCTest
@testable import WatchtowerCore

/// The People screens' copy equals the mockups' string table (#1769; it
/// lives in this test target, so the comparison does too).
final class PeopleCardCopyTests: XCTestCase {
    private typealias Mock = SlackPolicyMockCopy

    func testMatchesMockups() throws {
        XCTAssertEqual(PeopleCardCopy.basisLine(messages: 42, channels: 5), Mock.basisLine)
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertEqual(PeopleCardCopy.period(from: Date(timeIntervalSince1970: 1_793_707_200), // 2026-11-03 12:00Z
                                             to: Date(timeIntervalSince1970: 1_794_830_400), // 2026-11-16 12:00Z
                                             timeZone: utc), Mock.personPeriod)
        XCTAssertEqual(PeopleCardCopy.stopCard, Mock.stopCard)
        XCTAssertEqual(PeopleCardCopy.stopTitle(name: Mock.personName), Mock.stopTitle)
        XCTAssertEqual(PeopleCardCopy.stopBody(name: Mock.personName), Mock.stopBody)
        XCTAssertEqual(PeopleCardCopy.stopConfirm, Mock.stopConfirm)
        XCTAssertEqual(PeopleCardCopy.stoppedLine(name: Mock.personName), Mock.stoppedLine)
        XCTAssertEqual(PeopleCardCopy.makeAgain, Mock.makeAgain)
        XCTAssertEqual(PeopleCardCopy.orgLinksEmpty, Mock.orgLinksEmpty)
        XCTAssertEqual(PeopleCardCopy.orgLinksTitle, Mock.orgLinksTitle)
        XCTAssertEqual(PeopleCardCopy.editConnections, Mock.editConnections)
        XCTAssertEqual(PeopleCardCopy.cancel, Mock.cancel)
        XCTAssertEqual(PeopleCardCopy.decisionRoleTitle, Mock.decisionRoleTitle)
        XCTAssertEqual(PeopleCardCopy.guideTitle, Mock.guideTitle)
        XCTAssertEqual(PeopleCardCopy.tacticsTitle, Mock.tacticsTitle)
        XCTAssertEqual(PeopleCardCopy.teamSummaryTitle, Mock.teamSummaryTitle)
        XCTAssertEqual(PeopleCardCopy.tipsTitle, Mock.tipsTitle)
        XCTAssertEqual(PeopleCardCopy.orgRoleTitle(.manager), Mock.orgLinks[0].role)
        XCTAssertEqual(PeopleCardCopy.orgRoleTitle(.peer), Mock.orgLinks[1].role)
    }

    /// One message or one channel reads in the singular.
    func testBasisLineSingular() {
        XCTAssertEqual(PeopleCardCopy.basisLine(messages: 1, channels: 1),
                       "Based on 1 message in 1 channel you share")
    }
}
