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

    func testDecodesUpdatePriority() throws {
        let a = try decode(#"{"type":"update_priority","priority":"high","reason":"deadline"}"#)
        XCTAssertEqual(a.type, .updatePriority)
        XCTAssertEqual(a.priority, "high")
        XCTAssertNoThrow(try a.validate())
        XCTAssertTrue(a.cardDescription.contains("high"))
    }

    func testValidateRejectsBadOrMissingPriority() throws {
        let bad = try decode(#"{"type":"update_priority","priority":"urgent","reason":"x"}"#)
        XCTAssertThrowsError(try bad.validate())
        let missing = try decode(#"{"type":"update_priority","reason":"x"}"#)
        XCTAssertThrowsError(try missing.validate())
    }

    func testDecodesUpdateDue() throws {
        let a = try decode(#"{"type":"update_due","text":"2026-09-01","reason":"owner set friday"}"#)
        XCTAssertEqual(a.type, .updateDue)
        XCTAssertNoThrow(try a.validate())
        XCTAssertTrue(a.cardDescription.contains("2026-09-01"))
    }

    func testValidateRejectsBadDueDate() throws {
        // Missing text.
        XCTAssertThrowsError(try decode(#"{"type":"update_due","reason":"x"}"#).validate())
        // Not a date at all.
        XCTAssertThrowsError(try decode(#"{"type":"update_due","text":"next friday","reason":"x"}"#).validate())
        // Right shape, impossible calendar date.
        XCTAssertThrowsError(try decode(#"{"type":"update_due","text":"2026-02-30","reason":"x"}"#).validate())
        // Datetime is not the sub-item due-date convention.
        XCTAssertThrowsError(try decode(#"{"type":"update_due","text":"2026-09-01T12:00","reason":"x"}"#).validate())
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
