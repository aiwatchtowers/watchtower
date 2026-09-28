import XCTest
@testable import WatchtowerCore

@MainActor
final class ComposerPickerModelTests: XCTestCase {
    private let anna = MentionCandidate(kind: .person, ref: "1:U1", label: "Anna", detail: "@anna")
    private let pay = MentionCandidate(kind: .jira, ref: "PAY-1", label: "PAY-1", detail: "Refund")
    private var queries: [String] = []

    private func makeModel() -> ComposerPickerModel {
        ComposerPickerModel { [weak self] query in
            guard let self else { return [] }
            self.queries.append(query)
            return [self.anna, self.pay]
        }
    }

    func testOpensOnActiveMentionAndClosesWithoutOne() {
        let model = makeModel()
        model.update(text: "ask @an", cursor: 7)
        XCTAssertTrue(model.isOpen)
        XCTAssertEqual(model.items.map(\.title), ["Anna", "PAY-1"])
        XCTAssertEqual(queries, ["an"])
        model.update(text: "ask ", cursor: 4)
        XCTAssertFalse(model.isOpen)
    }

    func testArrowKeysWrapAndAcceptInsertsMention() {
        let model = makeModel()
        model.update(text: "ask @an", cursor: 7)
        XCTAssertEqual(model.handle(.down, text: "ask @an", cursor: 7), ComposerKeyResult(consumed: true, edit: nil))
        XCTAssertEqual(model.selectedIndex, 1)
        _ = model.handle(.down, text: "ask @an", cursor: 7)
        XCTAssertEqual(model.selectedIndex, 0, "wraps")
        _ = model.handle(.up, text: "ask @an", cursor: 7)
        XCTAssertEqual(model.selectedIndex, 1)

        let result = model.handle(.accept, text: "ask @an", cursor: 7)
        XCTAssertEqual(result.edit, ComposerEdit(text: "ask @PAY-1 ", cursor: 11))
        XCTAssertEqual(model.mentions, [pay])
        XCTAssertFalse(model.isOpen)
    }

    func testKeysPassThroughWhenClosed() {
        let model = makeModel()
        XCTAssertEqual(model.handle(.accept, text: "hi", cursor: 2), ComposerKeyResult(consumed: false, edit: nil))
    }

    func testEscapeSuppressesUntilANewMentionStarts() {
        let model = makeModel()
        model.update(text: "@an", cursor: 3)
        XCTAssertTrue(model.handle(.dismiss, text: "@an", cursor: 3).consumed)
        model.update(text: "@ann", cursor: 4)
        XCTAssertFalse(model.isOpen, "same @ stays dismissed while typing on")
        model.update(text: "@ann @p", cursor: 7)
        XCTAssertTrue(model.isOpen, "a new @ opens again")
    }

    func testAcceptingTheSameMentionTwiceKeepsOneChipAndResetClears() {
        let model = makeModel()
        model.update(text: "@a", cursor: 2)
        _ = model.accept(index: 0, text: "@a", cursor: 2)
        model.update(text: "@Anna @a", cursor: 8)
        _ = model.accept(index: 0, text: "@Anna @a", cursor: 8)
        XCTAssertEqual(model.mentions, [anna])
        model.removeMention(anna)
        XCTAssertTrue(model.mentions.isEmpty)
        model.update(text: "@a", cursor: 2)
        _ = model.accept(index: 0, text: "@a", cursor: 2)
        model.reset()
        XCTAssertTrue(model.mentions.isEmpty)
        XCTAssertFalse(model.isOpen)
    }

    func testEmptySearchResultKeepsPickerClosed() {
        let model = ComposerPickerModel { _ in [] }
        model.update(text: "@zz", cursor: 3)
        XCTAssertFalse(model.isOpen)
        XCTAssertEqual(model.handle(.accept, text: "@zz", cursor: 3).consumed, false,
                       "Enter must still send when nothing matches")
    }

    // MARK: - `/` skill picker (Task 26)

    private func skill(_ name: String) -> SkillSummary {
        SkillSummary(name: name, description: "Does \(name).", enabled: true)
    }

    func testSlashOpensSkillPickerAndAcceptSetsSkillAndClearsQuery() {
        let model = ComposerPickerModel(
            searchMentions: { _ in [] },
            skills: { [self.skill("break-down"), self.skill("status-update")] }
        )
        model.update(text: "/st", cursor: 3)
        XCTAssertEqual(model.mode, .skill(query: "st"))
        XCTAssertEqual(model.items.map(\.title), ["status-update"], "prefix filter on the name")
        let result = model.handle(.accept, text: "/st", cursor: 3)
        XCTAssertEqual(result.edit, ComposerEdit(text: "", cursor: 0))
        XCTAssertEqual(model.skill, "status-update")
        model.clearSkill()
        XCTAssertNil(model.skill)
    }

    func testBareSlashListsAllSkillsAndResetClearsSkill() {
        let model = ComposerPickerModel(searchMentions: { _ in [] }, skills: { [self.skill("a-one"), self.skill("b-two")] })
        model.update(text: "/", cursor: 1)
        XCTAssertEqual(model.items.map(\.title), ["a-one", "b-two"])
        _ = model.accept(index: 1, text: "/", cursor: 1)
        XCTAssertEqual(model.skill, "b-two")
        model.reset()
        XCTAssertNil(model.skill)
    }
}
