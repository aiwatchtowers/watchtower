import XCTest
@testable import WatchtowerCore

final class ProposedActionTests: XCTestCase {
    private func decode(_ json: String) throws -> ProposedAction {
        try JSONDecoder().decode(ProposedAction.self, from: Data(json.utf8))
    }

    func testDecodesUpdateStatus() throws {
        let a = try decode(#"{"type":"update_status","status":"done","reason":"finished"}"#)
        XCTAssertEqual(a.type, .updateStatus)
        XCTAssertEqual(a.status, "done")
        XCTAssertEqual(a.reason, "finished")
        XCTAssertNoThrow(try a.validate())
    }

    func testDecodesCreateChildTarget() throws {
        let a = try decode(#"{"type":"create_child_target","text":"Ping Bob","intent":"unblock","priority":"high","reason":"needed"}"#)
        XCTAssertEqual(a.type, .createChildTarget)
        XCTAssertEqual(a.text, "Ping Bob")
        XCTAssertEqual(a.intent, "unblock")
        XCTAssertEqual(a.priority, "high")
    }

    func testDecodesLinkTarget() throws {
        let a = try decode(#"{"type":"link_target","target_id":42,"relation":"blocks","reason":"x"}"#)
        XCTAssertEqual(a.type, .linkTarget)
        XCTAssertEqual(a.targetId, 42)
        XCTAssertEqual(a.relation, "blocks")
        XCTAssertNoThrow(try a.validate())
    }

    func testValidateRejectsBadRelation() throws {
        let a = try decode(#"{"type":"link_target","target_id":42,"relation":"frobnicate","reason":"x"}"#)
        XCTAssertThrowsError(try a.validate())
    }

    func testValidateRejectsMissingTargetId() throws {
        let a = try decode(#"{"type":"link_target","relation":"blocks","reason":"x"}"#)
        XCTAssertThrowsError(try a.validate())
    }

    func testUnknownTypeFailsDecoding() {
        XCTAssertThrowsError(try decode(#"{"type":"delete_everything","reason":"x"}"#))
    }

    func testValidateRejectsBadStatus() throws {
        let a = try decode(#"{"type":"update_status","status":"frobnicate","reason":"x"}"#)
        XCTAssertThrowsError(try a.validate())
    }

    func testValidateRejectsProgressOutOfRange() throws {
        let a = try decode(#"{"type":"update_progress","progress":150,"reason":"x"}"#)
        XCTAssertThrowsError(try a.validate())
    }

    func testValidateRejectsEmptyNote() throws {
        let a = try decode(#"{"type":"update_notes","note":"   ","reason":"x"}"#)
        XCTAssertThrowsError(try a.validate())
    }

    func testValidateRejectsEmptyReason() throws {
        let a = try decode(#"{"type":"add_sub_item","text":"do it","reason":""}"#)
        XCTAssertThrowsError(try a.validate())
    }

    func testCardDescriptionIncludesReason() throws {
        let a = try decode(#"{"type":"update_status","status":"done","reason":"all merged"}"#)
        XCTAssertTrue(a.cardDescription.contains("done"))
        XCTAssertTrue(a.cardDescription.contains("all merged"))
    }

    // MARK: - Sub-item mutations

    func testDecodesToggleSubItem() throws {
        let a = try decode(#"{"type":"toggle_sub_item","index":2,"match":"ship it","done":true,"reason":"user said done"}"#)
        XCTAssertEqual(a.type, .toggleSubItem)
        XCTAssertEqual(a.index, 2)
        XCTAssertEqual(a.match, "ship it")
        XCTAssertEqual(a.done, true)
        XCTAssertNoThrow(try a.validate())
    }

    /// LLMs emit booleans as quoted strings too — accept both.
    func testToggleSubItemDoneAsStringDecodes() throws {
        let a = try decode(#"{"type":"toggle_sub_item","index":"1","match":"x","done":"true","reason":"r"}"#)
        XCTAssertEqual(a.index, 1)
        XCTAssertEqual(a.done, true)
        XCTAssertNoThrow(try a.validate())
    }

    func testToggleSubItemRequiresDone() throws {
        let a = try decode(#"{"type":"toggle_sub_item","index":0,"match":"x","reason":"r"}"#)
        XCTAssertThrowsError(try a.validate())
    }

    func testDecodesEditSubItem() throws {
        let a = try decode(#"{"type":"edit_sub_item","index":0,"match":"old text","text":"new text","reason":"r"}"#)
        XCTAssertEqual(a.type, .editSubItem)
        XCTAssertEqual(a.text, "new text")
        XCTAssertNoThrow(try a.validate())
    }

    func testEditSubItemRejectsEmptyText() throws {
        let a = try decode(#"{"type":"edit_sub_item","index":0,"match":"old","text":"  ","reason":"r"}"#)
        XCTAssertThrowsError(try a.validate())
    }

    func testDecodesDeleteSubItem() throws {
        let a = try decode(#"{"type":"delete_sub_item","index":1,"match":"obsolete item","reason":"r"}"#)
        XCTAssertEqual(a.type, .deleteSubItem)
        XCTAssertNoThrow(try a.validate())
    }

    func testDeleteSubItemRequiresMatch() throws {
        let a = try decode(#"{"type":"delete_sub_item","index":1,"reason":"r"}"#)
        XCTAssertThrowsError(try a.validate())
    }

    func testDeleteSubItemRequiresIndex() throws {
        let a = try decode(#"{"type":"delete_sub_item","match":"x","reason":"r"}"#)
        XCTAssertThrowsError(try a.validate())
    }

    func testSetSubItemDueAcceptsDateAndDateTime() throws {
        let a = try decode(#"{"type":"set_sub_item_due","index":0,"match":"x","due_date":"2026-09-01","reason":"r"}"#)
        XCTAssertNoThrow(try a.validate())
        let b = try decode(#"{"type":"set_sub_item_due","index":0,"match":"x","due_date":"2026-09-01T15:30","reason":"r"}"#)
        XCTAssertNoThrow(try b.validate())
    }

    func testSetSubItemDueAcceptsEmptyToClear() throws {
        let a = try decode(#"{"type":"set_sub_item_due","index":0,"match":"x","due_date":"","reason":"r"}"#)
        XCTAssertNoThrow(try a.validate())
    }

    func testSetSubItemDueRejectsFreeText() throws {
        let a = try decode(#"{"type":"set_sub_item_due","index":0,"match":"x","due_date":"tomorrow","reason":"r"}"#)
        XCTAssertThrowsError(try a.validate())
    }

    // MARK: - Target field mutations

    func testDecodesUpdateDueDate() throws {
        let a = try decode(#"{"type":"update_due_date","due_date":"2026-08-22","reason":"r"}"#)
        XCTAssertEqual(a.type, .updateDueDate)
        XCTAssertEqual(a.dueDate, "2026-08-22")
        XCTAssertNoThrow(try a.validate())
    }

    func testUpdateDueDateAcceptsEmptyToClear() throws {
        let a = try decode(#"{"type":"update_due_date","due_date":"","reason":"r"}"#)
        XCTAssertNoThrow(try a.validate())
    }

    func testUpdateDueDateRejectsBadFormat() throws {
        let a = try decode(#"{"type":"update_due_date","due_date":"next friday","reason":"r"}"#)
        XCTAssertThrowsError(try a.validate())
    }

    func testUpdateDueDateRequiresField() throws {
        let a = try decode(#"{"type":"update_due_date","reason":"r"}"#)
        XCTAssertThrowsError(try a.validate())
    }

    /// Right shape, impossible calendar date. Shape-only validation would store
    /// it and then `Target.parseDueDate` would read back nil — a due date the UI
    /// never shows and that never goes overdue.
    func testUpdateDueDateRejectsImpossibleCalendarDate() throws {
        XCTAssertThrowsError(try decode(#"{"type":"update_due_date","due_date":"2026-02-30","reason":"r"}"#).validate())
        XCTAssertThrowsError(try decode(#"{"type":"update_due_date","due_date":"2026-13-45","reason":"r"}"#).validate())
        XCTAssertThrowsError(try decode(#"{"type":"update_due_date","due_date":"2026-09-01T25:00","reason":"r"}"#).validate())
        XCTAssertThrowsError(try decode(#"{"type":"set_sub_item_due","index":0,"match":"x","due_date":"2026-02-30","reason":"r"}"#).validate())
        // A real leap day still passes — the check is a calendar parse, not a
        // blanket "29th/30th of February" string rule.
        XCTAssertNoThrow(try decode(#"{"type":"update_due_date","due_date":"2028-02-29","reason":"r"}"#).validate())
    }

    // MARK: - Execute mode is scoped to the chat's own target (TGT-BRIEF-03)

    func testExecuteAutoAppliesOnlyToTheChatsOwnTarget() throws {
        let own = try decode(#"{"type":"update_status","status":"done","mode":"execute","reason":"r"}"#)
        XCTAssertTrue(own.autoApplies(inChatFor: 7))

        let addressedSelf = try decode(#"{"type":"update_status","target_id":7,"status":"done","mode":"execute","reason":"r"}"#)
        XCTAssertTrue(addressedSelf.autoApplies(inChatFor: 7))

        let addressedOther = try decode(#"{"type":"update_status","target_id":9,"status":"done","mode":"execute","reason":"r"}"#)
        XCTAssertFalse(addressedOther.autoApplies(inChatFor: 7))

        // link_target's target_id is the link partner, not a write target: the
        // row it writes belongs to this chat's own target, so it stays eligible.
        let link = try decode(#"{"type":"link_target","target_id":9,"relation":"blocks","mode":"execute","reason":"r"}"#)
        XCTAssertTrue(link.autoApplies(inChatFor: 7))

        // Propose is still propose, addressed or not.
        let proposed = try decode(#"{"type":"update_status","target_id":9,"status":"done","reason":"r"}"#)
        XCTAssertFalse(proposed.autoApplies(inChatFor: 7))
    }

    func testDecodesUpdatePriority() throws {
        let a = try decode(#"{"type":"update_priority","priority":"high","reason":"r"}"#)
        XCTAssertNoThrow(try a.validate())
    }

    func testUpdatePriorityRejectsBadValue() throws {
        let a = try decode(#"{"type":"update_priority","priority":"urgent","reason":"r"}"#)
        XCTAssertThrowsError(try a.validate())
    }

    func testDecodesUpdateBallOn() throws {
        let a = try decode(#"{"type":"update_ball_on","ball_on":"@petya","reason":"r"}"#)
        XCTAssertEqual(a.ballOn, "@petya")
        XCTAssertNoThrow(try a.validate())
    }

    func testUpdateBallOnAcceptsEmptyToClear() throws {
        let a = try decode(#"{"type":"update_ball_on","ball_on":"","reason":"r"}"#)
        XCTAssertNoThrow(try a.validate())
    }

    func testUpdateBallOnRequiresField() throws {
        let a = try decode(#"{"type":"update_ball_on","reason":"r"}"#)
        XCTAssertThrowsError(try a.validate())
    }

    // MARK: - Sub-item addressing (index + match staleness guard)

    private let items = [
        TargetSubItem(text: "write spec", done: false),
        TargetSubItem(text: "review PR", done: true),
        TargetSubItem(text: "ship it", done: false)
    ]

    private func resolver(index: Int, match: String) throws -> ProposedAction {
        try decode(#"{"type":"delete_sub_item","index":\#(index),"match":"\#(match)","reason":"r"}"#)
    }

    func testResolveExactIndexAndMatch() throws {
        let a = try resolver(index: 1, match: "review PR")
        XCTAssertEqual(try a.resolveSubItemIndex(in: items), 1)
    }

    func testResolveStaleIndexFallsBackToUniqueText() throws {
        // The list shifted since the AI saw it: index points elsewhere,
        // but the text still identifies exactly one item.
        let a = try resolver(index: 0, match: "ship it")
        XCTAssertEqual(try a.resolveSubItemIndex(in: items), 2)
    }

    func testResolveToleratesWhitespace() throws {
        let a = try resolver(index: 2, match: " ship it ")
        XCTAssertEqual(try a.resolveSubItemIndex(in: items), 2)
    }

    func testResolveNoMatchThrows() throws {
        let a = try resolver(index: 0, match: "never existed")
        XCTAssertThrowsError(try a.resolveSubItemIndex(in: items))
    }

    func testResolveAmbiguousTextWithStaleIndexThrows() throws {
        let dupes = [
            TargetSubItem(text: "call", done: false),
            TargetSubItem(text: "call", done: false)
        ]
        let a = try resolver(index: 5, match: "call")
        XCTAssertThrowsError(try a.resolveSubItemIndex(in: dupes))
    }

    func testResolveAmbiguousTextWithValidIndexUsesIndex() throws {
        let dupes = [
            TargetSubItem(text: "call", done: false),
            TargetSubItem(text: "call", done: false)
        ]
        let a = try resolver(index: 1, match: "call")
        XCTAssertEqual(try a.resolveSubItemIndex(in: dupes), 1)
    }

    func testResolveOutOfRangeIndexWithUniqueTextResolves() throws {
        let a = try resolver(index: 99, match: "write spec")
        XCTAssertEqual(try a.resolveSubItemIndex(in: items), 0)
    }

    func testUpdatePriorityRequiresField() throws {
        let a = try decode(#"{"type":"update_priority","reason":"x"}"#)
        XCTAssertThrowsError(try a.validate())
    }

    // MARK: - New kinds (target-brief-chat)

    func testDecodesUpdateTitle() throws {
        let a = try decode(#"{"type":"update_title","text":"Ship the registry","reason":"owner asked"}"#)
        XCTAssertEqual(a.type, .updateTitle)
        XCTAssertEqual(a.text, "Ship the registry")
        XCTAssertNoThrow(try a.validate())
        XCTAssertTrue(a.cardDescription.contains("Ship the registry"))
    }

    func testValidateRejectsUpdateTitleWithoutText() throws {
        let a = try decode(#"{"type":"update_title","reason":"x"}"#)
        XCTAssertThrowsError(try a.validate())
        let blank = try decode(#"{"type":"update_title","text":"   ","reason":"x"}"#)
        XCTAssertThrowsError(try blank.validate())
    }

    func testDecodesUpdateIntent() throws {
        let a = try decode(#"{"type":"update_intent","text":"Context: unblock the API team","reason":"directive"}"#)
        XCTAssertEqual(a.type, .updateIntent)
        XCTAssertNoThrow(try a.validate())
    }

    func testValidateRejectsUpdateIntentWithoutText() throws {
        let a = try decode(#"{"type":"update_intent","reason":"x"}"#)
        XCTAssertThrowsError(try a.validate())
    }

    // MARK: - mode field

    func testModeExecuteDecodesAndIsExecute() throws {
        let a = try decode(#"{"type":"update_status","status":"done","reason":"r","mode":"execute"}"#)
        XCTAssertEqual(a.mode, "execute")
        XCTAssertTrue(a.isExecute)
    }

    func testModeAbsentMeansPropose() throws {
        let a = try decode(#"{"type":"update_status","status":"done","reason":"r"}"#)
        XCTAssertNil(a.mode)
        XCTAssertFalse(a.isExecute)
    }

    func testModeJunkValueMeansPropose() throws {
        let a = try decode(#"{"type":"update_status","status":"done","reason":"r","mode":"banana"}"#)
        XCTAssertEqual(a.mode, "banana")
        XCTAssertFalse(a.isExecute)
        XCTAssertNoThrow(try a.validate())
    }

    func testModeNonStringDecodesLeniently() throws {
        // A non-string mode must not fail the whole action — it degrades to propose.
        let a = try decode(#"{"type":"update_status","status":"done","reason":"r","mode":7}"#)
        XCTAssertNil(a.mode)
        XCTAssertFalse(a.isExecute)
    }
}
