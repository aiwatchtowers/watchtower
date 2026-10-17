import XCTest
import WatchtowerCore

/// Task 9 (agent instructions): the Settings section reads Go's
/// `instructions show/preview --json`.
final class OwnerInstructionsStateTests: XCTestCase {
    private static let pinned = """
    {"ok":true,"limit":1000,"global":{"session":"Reply in Russian","procedure":""},\
    "workbench":{"id":1,"session":"Use make","procedure":"Run tests"},\
    "suggestions":[{"id":3,"text":"Always run lint","field":"session","workbench_id":null,\
    "session_count":4,"workbench_count":2,"first_seen_at":"2026-10-10T08:00:00Z",\
    "last_seen_at":"2026-10-16T09:30:00.5Z"},\
    {"id":4,"text":"Check the diff","field":"procedure","workbench_id":1,\
    "session_count":3,"workbench_count":1,"first_seen_at":"2026-10-11T08:00:00Z",\
    "last_seen_at":"2026-10-16T09:30:00Z"}]}
    """

    func testDecodesPinnedShowJSON() throws {
        let state = try OwnerInstructionsState.decode(Data(Self.pinned.utf8))
        XCTAssertEqual(state.limit, 1000)
        XCTAssertEqual(state.global.session, "Reply in Russian")
        XCTAssertEqual(state.workbench?.id, 1)
        XCTAssertEqual(state.workbench?.text(.procedure), "Run tests")
        XCTAssertEqual(state.suggestions.count, 2)
        XCTAssertEqual(state.suggestions[0].field, .session)
        XCTAssertNil(state.suggestions[0].workbenchID)
        XCTAssertEqual(state.suggestions[0].sessionCount, 4)
        XCTAssertEqual(state.suggestions[1].workbenchID, 1)
        XCTAssertEqual(state.suggestions(for: .session).map(\.id), [3])
        XCTAssertEqual(state.suggestions(for: .procedure, workbenchID: 1).map(\.id), [4])
    }

    func testWorkbenchNullDecodes() throws {
        let json = #"{"ok":true,"limit":1000,"global":{"session":"","procedure":""},"workbench":null,"suggestions":[]}"#
        let state = try OwnerInstructionsState.decode(Data(json.utf8))
        XCTAssertNil(state.workbench)
        XCTAssertTrue(state.suggestions.isEmpty)
    }

    func testRuneCounterCountsCharacters() {
        XCTAssertEqual(OwnerInstructionsState.runeCount("Привет"), 6)
        XCTAssertEqual("Привет".utf8.count, 12)
        XCTAssertEqual(OwnerInstructionsState.runeCount(""), 0)
    }

    func testRefusalBecomesAThrownMessage() {
        let json = #"{"ok":false,"error":"session instructions: over the 1000 character limit"}"#
        XCTAssertThrowsError(try OwnerInstructionsState.decode(Data(json.utf8))) { error in
            XCTAssertEqual((error as? OwnerInstructionsError)?.message,
                           "session instructions: over the 1000 character limit")
        }
    }

    func testPreviewDecodes() throws {
        let json = #"{"ok":true,"brief_slot":"Owner's instructions","procedure":"Run tests"}"#
        let p = try OwnerInstructionsPreview.decode(Data(json.utf8))
        XCTAssertEqual(p.briefSlot, "Owner's instructions")
        XCTAssertEqual(p.procedure, "Run tests")
    }
}
