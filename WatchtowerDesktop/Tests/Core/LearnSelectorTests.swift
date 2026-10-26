import XCTest
@testable import WatchtowerCore

/// Design §9.4–§9.7: what Home and See all show.
final class LearnSelectorTests: XCTestCase {
    private func card(
        _ id: String,
        _ area: LearnArea = .assistant,
        level: LearnLevel = .basics,
        since: String = "0.24.0",
        changed: String = "",
        doneWhen: LearnSignal? = nil,
        requires: String = "",
        replaces: [String] = []
    ) -> LearnCard {
        LearnCard(
            id: id, title: id, text: "\(id) text", area: area, level: level, kind: .feature, since: since,
            changed: changed, doneWhen: doneWhen, requires: requires, replaces: replaces)
    }

    private func select(_ cards: [LearnCard], _ edit: (inout LearnSelectorInput) -> Void = { _ in }) -> LearnSelection {
        var input = LearnSelectorInput(catalog: LearnCatalog(cards: cards))
        edit(&input)
        return LearnSelector.select(input)
    }

    private let v024 = LearnVersion(major: 0, minor: 24, patch: 0)

    func testOrderGoalsThenAreasThenLevel() {
        let cards = [
            card("setup-basics", .setup),
            card("meet-power", .meetings, level: .power),
            card("dev-next", .development, level: .next),
            card("dev-basics", .development),
            card("comm-basics", .communication)
        ]
        let none = select(cards).home.map(\.id)
        XCTAssertEqual(none, ["comm-basics", "meet-power", "dev-basics"])
        let dev = select(cards) { $0.goals = [.development] }.home.map(\.id)
        XCTAssertEqual(dev, ["dev-basics", "comm-basics", "meet-power"])
    }

    func testVarietyOnePerArea() {
        let cards = [card("a1"), card("a2"), card("a3"), card("s1", .setup)]
        XCTAssertEqual(select(cards).home.map(\.id), ["a1", "s1"])
    }

    func testOneAreaLeftFillsAllThree() {
        let cards = [card("a1"), card("a2"), card("a3"), card("a4"), card("s1", .setup)]
        let result = select(cards) { $0.seen = ["s1": .gotIt] }
        XCTAssertEqual(result.home.map(\.id), ["a1", "a2", "a3"])
    }

    func testMetRequirementsSortFirst() {
        let cards = [
            card("needs-jira", .tasks, requires: "source:jira"),
            card("free", .tasks),
            card("needs-ideas", .tasks, requires: "feature:ideas")
        ]
        let result = select(cards) { $0.metRequirements = ["feature:ideas"] }
        XCTAssertEqual(result.sections.first?.cards.map(\.id), ["free", "needs-ideas", "needs-jira"])
        // One area left: all three show.
        XCTAssertEqual(result.home.map(\.id), ["free", "needs-ideas", "needs-jira"])
        XCTAssertEqual(result.sections.first?.cards.map(\.requirementMet), [true, true, false])
    }

    func testRequirementDoesNotOutrankLevel() {
        let cards = [card("next-free", level: .next), card("basics-needs", requires: "source:jira")]
        XCTAssertEqual(select(cards).home.map(\.id), ["basics-needs", "next-free"])
    }

    func testNewCardsFirstWithBadge() {
        let cards = [card("old", .communication), card("fresh", .setup, level: .power, since: "0.25.1")]
        let result = select(cards) { $0.newAfter = self.v024 }
        XCTAssertEqual(result.home.map(\.id), ["fresh", "old"])
        XCTAssertEqual(result.home[0].variant, .new(version: "0.25"))
        XCTAssertEqual(result.home[1].variant, .normal)
        // No window, no badge.
        XCTAssertEqual(select(cards).home.map(\.variant), [.normal, .normal])
    }

    func testUpdatedWhenAReplacedCardWasSeen() {
        let cards = [
            card("other", .communication),
            card("dictation-v2", .meetings, level: .power, since: "0.25.0", changed: "Works anywhere now.",
                 doneWhen: .dictationUsed, replaces: ["dictation-v1"])
        ]
        let result = select(cards) {
            $0.seen = ["dictation-v1": .gotIt]
            $0.signals = [.dictationUsed]
        }
        // Shown even while in use; sorted with the new cards; changed text.
        XCTAssertEqual(result.home.map(\.id), ["dictation-v2", "other"])
        XCTAssertEqual(result.home[0].variant, .updated(version: "0.25", text: "Works anywhere now."))
        XCTAssertEqual(result.recordInUse, [])
        // The retired card's row does not count towards seen.
        XCTAssertEqual(result.seenCount, 0)
    }

    func testUpdatedWithoutChangedShowsText() {
        let cards = [card("b", since: "0.25.0", replaces: ["a"])]
        let result = select(cards) { $0.seen = ["a": .inUse] }
        XCTAssertEqual(result.home.first?.variant, .updated(version: "0.25", text: "b text"))
    }

    func testReplacingCardIsOrdinaryWhenNothingReplacedWasSeen() {
        let cards = [card("comm", .communication), card("b", .setup, since: "0.24.0", doneWhen: .chatUsed, replaces: ["a"])]
        let shown = select(cards)
        XCTAssertEqual(shown.home.map(\.id), ["comm", "b"])
        XCTAssertEqual(shown.home[1].variant, .normal)
        // In use and nothing replaced seen: recorded, never shown.
        let used = select(cards) { $0.signals = [.chatUsed] }
        XCTAssertEqual(used.recordInUse, ["b"])
        XCTAssertEqual(used.home.map(\.id), ["comm"])
    }

    /// B replaced A and C replaced B; B is gone, and Go hands C's chain as
    /// `replaces: [b, a]`: seeing A makes C an updated card.
    func testReplaceChain() {
        let cards = [card("c", since: "0.25.0", replaces: ["b", "a"])]
        let result = select(cards) { $0.seen = ["a": .gotIt] }
        XCTAssertEqual(result.home.first?.variant, .updated(version: "0.25", text: "c text"))
    }

    func testInUseRecordedAndCounted() {
        let cards = [
            card("chat", doneWhen: .chatUsed),
            card("meet", .meetings, doneWhen: .meetingRecorded),
            card("seen", .setup, doneWhen: .chatUsed)
        ]
        let result = select(cards) {
            $0.signals = [.chatUsed]
            $0.seen = ["seen": .gotIt, "gone-from-guide": .action]
        }
        XCTAssertEqual(result.recordInUse, ["chat"])
        XCTAssertEqual(result.home.map(\.id), ["meet"])
        XCTAssertEqual(result.seenCount, 2)
        XCTAssertEqual(result.total, 3)
    }

    func testAllSeen() {
        let cards = [card("a"), card("b", .setup)]
        let result = select(cards) { $0.seen = ["a": .gotIt, "b": .action] }
        XCTAssertTrue(result.home.isEmpty)
        XCTAssertEqual(result.seenCount, 2)
        XCTAssertEqual(result.total, 2)
        XCTAssertTrue(result.sections.allSatisfy { $0.cards.allSatisfy(\.seen) })
    }

    func testSeeAllSections() {
        let cards = [
            card("setup-1", .setup),
            card("comm-power", .communication, level: .power),
            card("comm-basics", .communication),
            card("new-1", .setup, since: "0.25.0")
        ]
        let result = select(cards) {
            $0.newAfter = self.v024
            $0.seen = ["comm-basics": .gotIt, "new-1": .gotIt]
            $0.goals = [.development]
        }
        XCTAssertEqual(result.sections.map(\.kind), [.new(version: "0.25"), .area(.communication), .area(.setup)])
        XCTAssertEqual(result.sections[0].cards.map(\.id), ["new-1"])
        XCTAssertEqual(result.sections[1].cards.map(\.id), ["comm-basics", "comm-power"])
        XCTAssertEqual(result.sections[1].seenCount, 1)
        XCTAssertEqual(result.sections[1].total, 2)
        XCTAssertEqual(result.sections[2].cards.map(\.id), ["setup-1", "new-1"])
        // A seen new card keeps its variant in See all but leaves Home.
        XCTAssertEqual(result.sections[0].cards[0].variant, .new(version: "0.25"))
        XCTAssertFalse(result.home.contains { $0.id == "new-1" })
    }

    func testEmptyCatalog() {
        let result = select([])
        XCTAssertTrue(result.home.isEmpty)
        XCTAssertEqual(result.total, 0)
        XCTAssertTrue(result.sections.isEmpty)
    }
}
