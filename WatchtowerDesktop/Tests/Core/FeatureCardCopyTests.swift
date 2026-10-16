import XCTest
@testable import WatchtowerCore

final class FeatureCardCopyTests: XCTestCase {
    private func card(_ feature: ReadinessFeature, briefingHour: Int = 8, dayPlanHour: Int = 8) -> FeatureCardCopy {
        EmptyStateCopyTable.featureCard(feature, briefingHour: briefingHour, dayPlanHour: dayPlanHour)
    }

    func testEveryFeatureHasCardCopy() {
        for feature in ReadinessFeature.allCases {
            let copy = card(feature)
            XCTAssertFalse(copy.title.isEmpty, "\(feature)")
            XCTAssertTrue(copy.whatItIs.hasSuffix("."), "\(feature): \(copy.whatItIs)")
            XCTAssertFalse(copy.whatItIs.contains("{hour}"), "\(feature): \(copy.whatItIs)")
        }
    }

    func testCardCopyReusesTheTabSentence() throws {
        let tabs: [(ReadinessFeature, String)] = [
            (.digests, "digests"), (.briefing, "briefings"), (.peopleCards, "people"), (.memory, "memory")
        ]
        for (feature, rawValue) in tabs {
            let tab = try XCTUnwrap(EmptyStateCopyTable.copy(for: rawValue, briefingHour: 7, dayPlanHour: 9))
            XCTAssertEqual(card(feature, briefingHour: 7, dayPlanHour: 9).whatItIs, tab.landsHere, "\(feature)")
        }
    }

    func testBriefingCardNamesTheHour() {
        let text = card(.briefing, briefingHour: 7).whatItIs
        XCTAssertTrue(text.contains("07:00"), text)
    }
}
