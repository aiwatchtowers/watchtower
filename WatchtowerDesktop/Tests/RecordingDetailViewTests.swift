import XCTest
@testable import WatchtowerDesktop

final class RecordingDetailViewTests: XCTestCase {
    func test_tabEnumHasFourCasesInOrder() {
        XCTAssertEqual(
            RecordingDetailTab.allCases.map(\.rawValue),
            ["recap", "notes", "transcript", "chat"])
    }

    func test_tabTitles() {
        XCTAssertEqual(RecordingDetailTab.recap.title, "Recap")
        XCTAssertEqual(RecordingDetailTab.notes.title, "Notes")
        XCTAssertEqual(RecordingDetailTab.transcript.title, "Transcript")
        XCTAssertEqual(RecordingDetailTab.chat.title, "Chat")
    }
}
