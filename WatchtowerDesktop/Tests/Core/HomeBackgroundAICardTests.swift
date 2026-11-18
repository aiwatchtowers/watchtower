import XCTest
@testable import WatchtowerCore

/// Home's one background AI card (#1886, spec §6.3): drawn from the consent
/// state, outside the hideable Getting ready zone.
final class HomeBackgroundAICardTests: XCTestCase {
    private typealias Copy = BackgroundAIConsentCopy

    func testPausedCardSurvivesHidingGettingReady() throws {
        let paused = BackgroundAIConsent.resolve(answer: nil, policy: nil)
        let readiness = Dictionary(uniqueKeysWithValues: ReadinessFeature.allCases.map {
            ($0, $0.usesBackgroundAI ? Readiness.backgroundAIPaused(managed: false) : .preparing(detail: nil))
        })
        let step = GettingReadyPolicy.step(
            readiness: readiness, ownerKnown: true, memory: GettingReadyMemory(hiddenByOwner: true),
            sawUnready: true, now: Date(), briefingHour: 8)
        XCTAssertEqual(step.zone, .hidden)

        let card = try XCTUnwrap(HomeBackgroundAICard.make(paused))
        XCTAssertEqual(card.title, "Background AI is paused")
        XCTAssertEqual(card.body, "Digests, briefings, tracks, people cards, memory and automations wait. "
            + "Slack, mail, calendar and Jira keep syncing.")
        XCTAssertEqual(card.actionTitle, "Allow background AI…")
        XCTAssertFalse(card.managed)
        XCTAssertEqual(HomeBackgroundAICard.make(BackgroundAIConsent.resolve(answer: "paused", policy: true)), card)
    }

    func testOrgCardHasNoAction() throws {
        let card = try XCTUnwrap(HomeBackgroundAICard.make(BackgroundAIConsent.resolve(answer: "allowed", policy: false)))
        XCTAssertEqual(card.title, "Background AI is off")
        XCTAssertEqual(card.body, "Your organization turned it off. Chats, Catch-Up and anything you start yourself still work.")
        XCTAssertNil(card.actionTitle)
        XCTAssertTrue(card.managed)
    }

    func testAllowedHasNoCard() {
        XCTAssertNil(HomeBackgroundAICard.make(.allowedByOwner))
        XCTAssertNil(HomeBackgroundAICard.make(BackgroundAIConsent.resolve(answer: nil, policy: true)))
    }
}
