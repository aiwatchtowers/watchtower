import ChatWire
import XCTest
@testable import WatchtowerCore
import WatchtowerChatText

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

    func testOpensOnActiveMentionAndClosesWithoutOne() async {
        let model = makeModel()
        await update(model, "ask @an", 7)
        XCTAssertTrue(model.isOpen)
        XCTAssertEqual(model.items.map(\.title), ["Anna", "PAY-1"])
        XCTAssertEqual(queries, ["an"])
        await update(model, "ask ", 4)
        XCTAssertFalse(model.isOpen)
    }

    func testArrowKeysWrapAndAcceptInsertsMention() async {
        let model = makeModel()
        await update(model, "ask @an", 7)
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

    func testKeysPassThroughWhenClosed() async {
        let model = makeModel()
        XCTAssertEqual(model.handle(.accept, text: "hi", cursor: 2), ComposerKeyResult(consumed: false, edit: nil))
    }

    func testEscapeSuppressesUntilANewMentionStarts() async {
        let model = makeModel()
        await update(model, "@an", 3)
        XCTAssertTrue(model.handle(.dismiss, text: "@an", cursor: 3).consumed)
        await update(model, "@ann", 4)
        XCTAssertFalse(model.isOpen, "same @ stays dismissed while typing on")
        await update(model, "@ann @p", 7)
        XCTAssertTrue(model.isOpen, "a new @ opens again")
    }

    func testAcceptingTheSameMentionTwiceKeepsOneChipAndResetClears() async {
        let model = makeModel()
        await update(model, "@a", 2)
        _ = model.accept(index: 0, text: "@a", cursor: 2)
        await update(model, "@Anna @a", 8)
        _ = model.accept(index: 0, text: "@Anna @a", cursor: 8)
        XCTAssertEqual(model.mentions, [anna])
        model.removeMention(anna)
        XCTAssertTrue(model.mentions.isEmpty)
        await update(model, "@a", 2)
        _ = model.accept(index: 0, text: "@a", cursor: 2)
        model.reset()
        XCTAssertTrue(model.mentions.isEmpty)
        XCTAssertFalse(model.isOpen)
    }

    func testEmptySearchResultKeepsPickerClosed() async {
        let model = ComposerPickerModel { _ in [] }
        await update(model, "@zz", 3)
        XCTAssertFalse(model.isOpen)
        XCTAssertEqual(model.handle(.accept, text: "@zz", cursor: 3).consumed, false,
                       "Enter must still send when nothing matches")
    }

    // MARK: - `/` skill picker (Task 26)

    private func skill(_ name: String) -> ChatSkill {
        ChatSkill(name: name, description: "Does \(name).")
    }

    /// `update`, then the search it started answered (the engine's, asynchronous).
    private func update(_ model: ComposerPickerModel, _ text: String, _ cursor: Int) async {
        model.update(text: text, cursor: cursor)
        await model.searchSettled()
    }

    func testSlashOpensSkillPickerAndAcceptSetsSkillAndClearsQuery() async {
        let model = ComposerPickerModel(
            searchMentions: { _ in [] },
            skills: { [self.skill("break-down"), self.skill("status-update")] }
        )
        await update(model, "/st", 3)
        XCTAssertEqual(model.mode, .skill(query: "st"))
        XCTAssertEqual(model.items.map(\.title), ["status-update"], "prefix filter on the name")
        let result = model.handle(.accept, text: "/st", cursor: 3)
        XCTAssertEqual(result.edit, ComposerEdit(text: "", cursor: 0))
        XCTAssertEqual(model.skill, "status-update")
        model.clearSkill()
        XCTAssertNil(model.skill)
    }

    func testBareSlashListsAllSkillsAndResetClearsSkill() async {
        let model = ComposerPickerModel(searchMentions: { _ in [] }, skills: { [self.skill("a-one"), self.skill("b-two")] })
        await update(model, "/", 1)
        XCTAssertEqual(model.items.map(\.title), ["a-one", "b-two"])
        _ = model.accept(index: 1, text: "/", cursor: 1)
        XCTAssertEqual(model.skill, "b-two")
        model.reset()
        XCTAssertNil(model.skill)
    }
}
