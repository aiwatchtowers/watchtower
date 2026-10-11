import XCTest
import GRDB
@testable import WatchtowerCore

/// Owner asks without the mouse (board #412, spec 2026-10-10 Part 9.4):
/// each key's action where it is pressed, and nothing while a field, the
/// terminal or an editor has the keyboard.
final class OwnerAskKeyMapTests: XCTestCase {
    private typealias Map = OwnerAskKeyMap
    private typealias Press = OwnerAskKeyMap.Press

    private func char(_ character: Character, shift: Bool = false) -> Press {
        Press(key: .character(character), shift: shift)
    }

    private func action(_ press: Press, _ place: Map.Place) -> Map.Action? {
        Map.action(for: press, at: place)
    }

    // MARK: - Each key

    func testTheStackOpensWithAOnThePage() {
        XCTAssertEqual(action(char("a"), .page), .openStack)
        XCTAssertNil(action(char("j"), .page), "nothing else on the page")
        XCTAssertNil(action(char("1"), .page))
        XCTAssertNil(action(Press(key: .tab), .page), "Tab on the page stays the window's")
    }

    func testDrawerKeys() {
        let drawer = Map.Place.drawer(choices: 3, isReview: false)
        XCTAssertEqual(action(char("j"), drawer), .nextAsk)
        XCTAssertEqual(action(char("k"), drawer), .previousAsk)
        XCTAssertEqual(action(Press(key: .tab), drawer), .nextStop)
        XCTAssertEqual(action(Press(key: .tab, shift: true), drawer), .previousStop)
        XCTAssertEqual(action(Press(key: .returnKey), drawer), .edit)
        XCTAssertEqual(action(char("1"), drawer), .choose(0))
        XCTAssertEqual(action(char("3"), drawer), .choose(2))
        XCTAssertNil(action(char("a"), drawer), "A is the page's")
    }

    func testCommentKeysOnlyOnAReview() {
        let review = Map.Place.drawer(choices: 0, isReview: true)
        XCTAssertEqual(action(char("n"), review), .nextComment)
        XCTAssertEqual(action(char("p"), review), .previousComment)
        XCTAssertNil(action(char("n"), .drawer(choices: 0, isReview: false)))
        XCTAssertNil(action(char("p"), .drawer(choices: 2, isReview: false)))
    }

    func testCardKeys() {
        let card = Map.Place.card(quickChoices: 2)
        XCTAssertEqual(action(char("j"), card), .nextAsk)
        XCTAssertEqual(action(Press(key: .downArrow), card), .nextAsk)
        XCTAssertEqual(action(char("k"), card), .previousAsk)
        XCTAssertEqual(action(Press(key: .upArrow), card), .previousAsk)
        XCTAssertEqual(action(Press(key: .returnKey), card), .open)
        XCTAssertEqual(action(char("2"), card), .choose(1))
        XCTAssertNil(action(Press(key: .tab), card), "Tab moves the focus as everywhere")
    }

    // MARK: - Digits

    func testDigitsBeyondTheOptionCountDoNothing() {
        XCTAssertNil(action(char("4"), .drawer(choices: 3, isReview: false)))
        XCTAssertEqual(action(char("9"), .drawer(choices: 9, isReview: false)), .choose(8))
        XCTAssertNil(action(char("1"), .drawer(choices: 0, isReview: false)), "the note takes no digit")
        XCTAssertNil(action(char("0"), .drawer(choices: 9, isReview: false)), "0 names no option")
        XCTAssertNil(action(char("3"), .card(quickChoices: 2)))
        XCTAssertNil(action(char("1"), .card(quickChoices: 0)), "a Full ask's card answers nothing")
    }

    func testAQuickCardTakesOneToThreeOnly() {
        XCTAssertEqual(action(char("3"), .card(quickChoices: 5)), .choose(2))
        XCTAssertNil(action(char("4"), .card(quickChoices: 5)), "1–3 on a Quick ask")
    }

    // MARK: - Physical keys

    /// The owner types in Russian: J's key types "о", K's "л", A's "ф".
    func testLettersAreReadByTheirKey() {
        func press(_ characters: String, _ keyCode: UInt16) -> Press {
            Press(characters: characters, keyCode: keyCode, shift: false, otherModifiers: false, isRepeat: false)
        }
        XCTAssertEqual(press("о", 0x26).key, .character("j"))
        XCTAssertEqual(press("л", 0x28).key, .character("k"))
        XCTAssertEqual(press("ф", 0x00).key, .character("a"))
        XCTAssertEqual(press("т", 0x2D).key, .character("n"))
        XCTAssertEqual(press("з", 0x23).key, .character("p"))
        XCTAssertEqual(action(press("о", 0x26), .drawer(choices: 0, isReview: false)), .nextAsk)
        XCTAssertEqual(press("1", 0x12).key, .character("1"), "a digit by what it types")
        XCTAssertEqual(press("\t", 0x30).key, .tab)
        XCTAssertEqual(press("о", 0x1F).key, .character("о"), "another key keeps its character, which names nothing")
        XCTAssertNil(action(press("о", 0x1F), .drawer(choices: 3, isReview: true)))
    }

    func testModifiedAndRepeatedKeysDoNothing() {
        let drawer = Map.Place.drawer(choices: 3, isReview: true)
        XCTAssertNil(action(Press(key: .character("j"), otherModifiers: true), drawer), "⌘J, ⌥J, ⌃J are not J")
        XCTAssertNil(action(Press(key: .character("1"), otherModifiers: true), .card(quickChoices: 2)), "⌘1 switches sessions")
        XCTAssertNil(action(Press(key: .returnKey, otherModifiers: true), drawer), "⌘↩ is the answer key's")
        XCTAssertNil(action(char("j", shift: true), drawer), "Shift only with Tab")
        XCTAssertNil(action(Press(key: .character("1"), isRepeat: true), drawer), "a held digit picks once")
        XCTAssertNil(action(Press(key: .tab, shift: true), .card(quickChoices: 2)))
    }

    func testPressFromCharacters() {
        XCTAssertEqual(Press(characters: "J", shift: false, otherModifiers: false, isRepeat: false).key, .character("j"),
                       "Caps Lock still means J")
        XCTAssertEqual(Press(characters: "\t", shift: false, otherModifiers: false, isRepeat: false).key, .tab)
        XCTAssertEqual(Press(characters: "\u{19}", shift: true, otherModifiers: false, isRepeat: false).key, .tab)
        XCTAssertEqual(Press(characters: "\r", shift: false, otherModifiers: false, isRepeat: false).key, .returnKey)
        XCTAssertEqual(Press(characters: "\u{3}", shift: false, otherModifiers: false, isRepeat: false).key, .returnKey)
        XCTAssertEqual(Press(characters: "\u{F700}", shift: false, otherModifiers: false, isRepeat: false).key, .upArrow)
        XCTAssertEqual(Press(characters: "\u{F701}", shift: false, otherModifiers: false, isRepeat: false).key, .downArrow)
        XCTAssertEqual(Press(characters: "", shift: false, otherModifiers: false, isRepeat: false).key, .other)
        XCTAssertEqual(Press(characters: "ab", shift: false, otherModifiers: false, isRepeat: false).key, .other)
    }

    // MARK: - The drawer's cursor

    private func ask(kind: String, payload: String, status: String = "open") throws -> OwnerAsk {
        try OwnerAsk(row: Row([
            "id": 4, "project_id": 1, "level": "full", "origin": "agent", "kind": kind, "title": "t",
            "payload": payload, "status": status
        ]))
    }

    func testStopsAreQuestionsThenStepsThenTheNote() throws {
        let check = try ask(kind: "check", payload: #"""
        {"questions":[{"id":"q","question":"Which?","options":[{"label":"A"},{"label":"B"}]}],
         "checklist":[{"id":"1","text":"Launch"},{"id":"2","text":"Quit"}]}
        """#)
        let stops = OwnerAskKeyStop.stops(for: check, editable: true)
        XCTAssertEqual(stops, [.question("q"), .step("1"), .step("2"), .note])
        XCTAssertEqual(stops.map { $0.choices(in: check) }, [2, 3, 3, 0])
        XCTAssertEqual(OwnerAskKeyStop.stops(for: check, editable: false), [], "a closed ask or one being answered takes no keys")

        let review = try ask(kind: "review", payload: "{}")
        XCTAssertEqual(OwnerAskKeyStop.stops(for: review, editable: true), [.note])
    }

    func testTheCursorWraps() {
        XCTAssertEqual(OwnerAskKeyStop.moved(from: nil, forward: true, count: 3), 0)
        XCTAssertEqual(OwnerAskKeyStop.moved(from: nil, forward: false, count: 3), 2)
        XCTAssertEqual(OwnerAskKeyStop.moved(from: 2, forward: true, count: 3), 0)
        XCTAssertEqual(OwnerAskKeyStop.moved(from: 0, forward: false, count: 3), 2)
        XCTAssertEqual(OwnerAskKeyStop.moved(from: 1, forward: true, count: 3), 2)
        XCTAssertEqual(OwnerAskKeyStop.moved(from: 7, forward: true, count: 3), 0, "a cursor past a shorter ask starts over")
        XCTAssertNil(OwnerAskKeyStop.moved(from: nil, forward: true, count: 0))
    }

    func testCommentsGoInDocumentOrderSkippingTheUnplaced() {
        let locations: [Int?] = [40, nil, 10, 25]
        XCTAssertEqual(OwnerAskKeyStop.movedComment(from: nil, forward: true, locations: locations), 2)
        XCTAssertEqual(OwnerAskKeyStop.movedComment(from: nil, forward: false, locations: locations), 0)
        XCTAssertEqual(OwnerAskKeyStop.movedComment(from: 2, forward: true, locations: locations), 3)
        XCTAssertEqual(OwnerAskKeyStop.movedComment(from: 0, forward: true, locations: locations), 2, "past the last it wraps")
        XCTAssertEqual(OwnerAskKeyStop.movedComment(from: 2, forward: false, locations: locations), 0)
        XCTAssertEqual(OwnerAskKeyStop.movedComment(from: 1, forward: true, locations: locations), 2, "from one not placed, the first")
        XCTAssertNil(OwnerAskKeyStop.movedComment(from: nil, forward: true, locations: [nil]))
    }

    func testPickingToggles() {
        let single = ChatQuestionAnswer.Entry(labels: ["A"], other: "mine")
        XCTAssertEqual(single.toggling("B", multi: false), .init(labels: ["B"], other: nil), "one answer per single-choice question")
        let multi = ChatQuestionAnswer.Entry(labels: ["A"], other: "mine")
        XCTAssertEqual(multi.toggling("B", multi: true), .init(labels: ["A", "B"], other: "mine"))
        XCTAssertEqual(multi.toggling("A", multi: true), .init(labels: [], other: "mine"))
    }
}
