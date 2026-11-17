import ChatWire
import XCTest
@testable import ChatUI
import WatchtowerChatText

@MainActor
final class ComposerPickerModelTests: XCTestCase {
    private let annaHit = ChatEntityHit(kind: "person", id: "1:U1", label: "Anna", detail: "@anna")
    private let payHit = ChatEntityHit(kind: "jira", id: "PAY-1", label: "PAY-1", detail: "Refund")
    private let anna = ChatCompose.Mention(kind: "person", id: "1:U1", label: "Anna")
    private let pay = ChatCompose.Mention(kind: "jira", id: "PAY-1", label: "PAY-1")
    private var queries: [String] = []

    private func makeModel() -> ComposerPickerModel {
        ComposerPickerModel { [weak self] query in
            guard let self else { return [] }
            self.queries.append(query)
            return [self.annaHit, self.payHit]
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
            searchEntities: { _ in [] },
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
        let model = ComposerPickerModel(searchEntities: { _ in [] }, skills: { [self.skill("a-one"), self.skill("b-two")] })
        await update(model, "/", 1)
        XCTAssertEqual(model.items.map(\.title), ["a-one", "b-two"])
        _ = model.accept(index: 1, text: "/", cursor: 1)
        XCTAssertEqual(model.skill, "b-two")
        model.reset()
        XCTAssertNil(model.skill)
    }

    /// A search that answers after the text moved on is dropped: the list is the newer search's.
    func testStaleSearchResultIsDropped() async {
        var answers: [String: CheckedContinuation<[ChatEntityHit], Never>] = [:]
        var asked: [String] = []
        let model = ComposerPickerModel { query in
            asked.append(query)
            return await withCheckedContinuation { answers[query] = $0 }
        }
        model.update(text: "@a", cursor: 2)
        await waitUntil { asked == ["a"] }
        model.update(text: "@p", cursor: 2)
        await waitUntil { asked == ["a", "p"] }
        answers["p"]?.resume(returning: [payHit])
        await model.searchSettled()
        answers["a"]?.resume(returning: [annaHit])
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(model.items.map(\.title), ["PAY-1"])
        XCTAssertEqual(model.mode, .mention(query: "p"))
    }

    /// Yields until `condition` holds (no clock: the search tasks run on the main actor).
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1_000 where !condition() { await Task.yield() }
        XCTAssertTrue(condition())
    }

    // MARK: - Mentions from `entity_search` (moved from Core's MentionTokenizerTests with MentionCandidate)

    func testLiveMentionsKeepsOnlyThoseStillInTextDeduped() {
        XCTAssertEqual(
            ComposerPickerModel.liveMentions(text: "ping @Anna about it", mentions: [anna, pay, anna]),
            [anna]
        )
    }

    func testReferenceTokensAndInsertionText() async {
        let everyKind = [
            ChatEntityHit(kind: "person", id: "1:U1", label: "Anna"), ChatEntityHit(kind: "channel", id: "1:C1", label: "#pay"),
            ChatEntityHit(kind: "jira", id: "PAY-1", label: "PAY-1"), ChatEntityHit(kind: "linear", id: "ENG-1", label: "ENG-1"),
            ChatEntityHit(kind: "target", id: "5", label: "Ship"), ChatEntityHit(kind: "track", id: "9", label: "Rev")
        ]
        let all = ComposerPickerModel { _ in everyKind }
        await update(all, "@x", 2)
        XCTAssertEqual(all.items.map(\.id),
                       ["person:1:U1", "channel:1:C1", "jira:PAY-1", "linear:ENG-1", "target:5", "track:9"])
        let model = ComposerPickerModel { _ in [ChatEntityHit(kind: "channel", id: "1:C1", label: "#pay")] }
        await update(model, "@p", 2)
        XCTAssertEqual(model.items.map(\.id), ["channel:1:C1"])
        XCTAssertEqual(model.accept(index: 0, text: "@p", cursor: 2)?.text, "@#pay ")
    }

    /// `entity_search`'s hits: a project or space is pinned, not mentioned; an unknown kind is skipped; the
    /// mention travels in `compose` with its kind and id.
    func testCandidateFromHitSkipsJiraProjects() {
        XCTAssertNil(ComposerPickerModel.mention(for: ChatEntityHit(kind: "board", id: "1", label: "x")))
        XCTAssertNil(ComposerPickerModel.mention(for: ChatEntityHit(kind: "jira_project", id: "PAY", label: "PAY")))
        XCTAssertNil(ComposerPickerModel.mention(for: ChatEntityHit(kind: "confluence_space", id: "ENG", label: "ENG")))
        XCTAssertEqual(ComposerPickerModel.mention(for: ChatEntityHit(kind: "jira", id: "PAY-1", label: "PAY-1", detail: "x")),
                       ChatCompose.Mention(kind: "jira", id: "PAY-1", label: "PAY-1"))
        XCTAssertEqual(ComposerPickerModel.mention(for: ChatEntityHit(kind: "linear", id: "ENG-1", label: "ENG-1"))?.kind,
                       "linear")
    }

    /// A raw newline in a label would break the single-line REFERENCED format and the `@Label` insertion text
    /// (review Minor a): collapsed to a space.
    func testMentionCandidateCollapsesNewlinesInLabel() {
        let hit = ChatEntityHit(kind: "person", id: "1:U1", label: "Anna\r\nIvanova\nJane")
        XCTAssertEqual(ComposerPickerModel.mention(for: hit)?.label, "Anna Ivanova Jane")
        XCTAssertEqual(ComposerPickerModel.mention(for: ChatEntityHit(kind: "target", id: "5", label: "Ship\nit"))?.label,
                       "Ship it")
    }
}
