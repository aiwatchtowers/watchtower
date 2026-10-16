import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore

/// The Changes pane's Plan 3 view logic (board #328): Undo reasons and
/// zones, note zones, the overview line, the walkthrough and the diff
/// page's Undo message check.
@MainActor
final class ReviewPresentationTests: XCTestCase {
    private func note(_ id: Int64, path: String, start: Int, end: Int, kind: String = "note") throws -> ReviewNote {
        let json = """
        {"id":\(id),"kind":"\(kind)","ord":\(id),"path":"\(path)","start_line":\(start),"end_line":\(end),"quote":"q",
         "text":"note \(id)","paths_json":[],"core":false,"why":"","tree_sha":"t"}
        """
        return try JSONDecoder().decode(ReviewNote.self, from: Data(json.utf8))
    }

    private func overview(_ json: String) throws -> ReviewOverview {
        try JSONDecoder().decode(ReviewOverview.self, from: Data(json.utf8))
    }

    func testUndoReasonByState() {
        XCTAssertEqual(ReviewPresentation.undoReason(roundOpen: true, canUndo: true, busy: false), "")
        XCTAssertEqual(ReviewPresentation.undoReason(roundOpen: false, canUndo: false, busy: false), "Round already sent")
        XCTAssertEqual(ReviewPresentation.undoReason(roundOpen: true, canUndo: false, busy: false),
                       "Undo is off while the agent is working")
        XCTAssertEqual(ReviewPresentation.undoReason(roundOpen: true, canUndo: false, busy: true),
                       "Undo is off while another action runs")
    }

    func testHunkZonesCarryTheStateAndReason() throws {
        let json = """
        {"path":"a.go","status":"modified","additions":1,"deletions":1,"binary":false,"new_blob":"b","new_mode":"100644",
         "hunks":[{"hunk_id":"0123456789abcdef","header":"@@ -1 +1 @@","old_start":1,"old_lines":1,"new_start":4,"new_lines":1,"lines":[]}]}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let file = try decoder.decode(ReviewDiffFile.self, from: Data(json.utf8))
        let on = ReviewPresentation.hunks(of: file, roundOpen: true, canUndo: true, busy: false)
        XCTAssertEqual(on, [.init(id: "0123456789abcdef", newStart: 4, canUndo: true, reason: "")])
        let off = ReviewPresentation.hunks(of: file, roundOpen: false, canUndo: false, busy: false)
        XCTAssertEqual(off.first?.canUndo, false)
        XCTAssertEqual(off.first?.reason, "Round already sent")
        XCTAssertEqual(ReviewPresentation.hunks(of: nil, roundOpen: true, canUndo: true, busy: false), [])
    }

    func testNoteZonesOnlyForPlacedNotesOfTheFile() throws {
        let notes = [
            try note(1, path: "a.go", start: 3, end: 4), try note(2, path: "a.go", start: 9, end: 9),
            try note(3, path: "b.go", start: 1, end: 1), try note(4, path: "a.go", start: 1, end: 1, kind: "chapter")
        ]
        let zones = ReviewPresentation.noteZones(notes, path: "a.go", placements: [
            1: .init(startLine: 5, endLine: 6), 3: .init(startLine: 1, endLine: 1)
        ])
        XCTAssertEqual(zones, [.init(startLine: 5, endLine: 6, text: "note 1")], "moved lines; unplaced, other file and chapter rows have no zone")
    }

    func testOverviewLines() throws {
        let ready = try overview("""
        {"summary":"\\n  First line.\\nSecond.","coverage":[],"out_of_scope":[],"chapters":[],
         "risk":[{"path":"a","level":"high","why":""},{"path":"b","level":"medium","why":""},{"path":"c","level":"low","why":""},
                 {"path":"d","level":"high","why":""}]}
        """.replacingOccurrences(of: "out_of_scope", with: "outOfScope"))
        XCTAssertEqual(ReviewPresentation.firstLine(ready.summary), "First line.")
        XCTAssertEqual(ReviewPresentation.riskLine(ready), "2 high · 1 medium risk")
        XCTAssertEqual(ReviewPresentation.sizeLine(changedLines: 120, minutes: 8), "120 changed lines · about 8 min")
        let calm = try overview(#"{"summary":"s"}"#)
        XCTAssertEqual(ReviewPresentation.riskLine(calm), "")
    }

    func testCoveragePathAcceptsPathOrPathWithLines() {
        let files = [ReviewDiffFile(path: "pkg/a.go", additions: 1, deletions: 0)]
        XCTAssertEqual(ReviewPresentation.coveragePath("pkg/a.go", files: files), "pkg/a.go")
        XCTAssertEqual(ReviewPresentation.coveragePath("pkg/a.go:10-12", files: files), "pkg/a.go")
        XCTAssertNil(ReviewPresentation.coveragePath("pkg/gone.go", files: files))
    }

    func testWalkthroughMarksNotesThatLostTheirPlace() throws {
        let files = [ReviewDiffFile(path: "a.go", additions: 1, deletions: 0)]
        let notes = [
            try note(1, path: "a.go", start: 3, end: 3), try note(2, path: "a.go", start: 8, end: 9),
            try note(3, path: "gone.go", start: 1, end: 2), try note(4, path: "a.go", start: 1, end: 1, kind: "chapter")
        ]
        let rows = ReviewPresentation.walkthrough(notes, files: files, selectedPath: "a.go", placements: [1: .init(startLine: 4, endLine: 4)])
        XCTAssertEqual(rows.map(\.place), ["a.go:4", "a.go:8–9", "gone.go:1–2"])
        XCTAssertEqual(rows.map(\.placed), [true, false, false])
    }

    func testChapterSourceCaption() {
        XCTAssertEqual(ReviewPresentation.sourceCaption(.agent), "by the agent")
        XCTAssertEqual(ReviewPresentation.sourceCaption(.ai), "by AI")
        XCTAssertNil(ReviewPresentation.sourceCaption(.mechanical))
    }

    func testUndoMessageIsHonouredOnlyForAShownHunkWithAWellFormedID() {
        let shown: [MonacoDiffView.Payload.Hunk] = [
            .init(id: "0123456789abcdef", newStart: 1, canUndo: true, reason: ""),
            .init(id: "fedcba9876543210", newStart: 5, canUndo: false, reason: "Round already sent")
        ]
        typealias Coordinator = MonacoDiffView.Coordinator
        XCTAssertEqual(Coordinator.undoTarget("0123456789abcdef", shown: shown), "0123456789abcdef")
        XCTAssertNil(Coordinator.undoTarget("fedcba9876543210", shown: shown), "a disabled hunk")
        XCTAssertNil(Coordinator.undoTarget("aaaaaaaaaaaaaaaa", shown: shown), "not in the shown file")
        XCTAssertNil(Coordinator.undoTarget("0123456789ABCDEF", shown: shown), "uppercase is not a hunk id")
        XCTAssertNil(Coordinator.undoTarget("0123456789abcde", shown: shown), "too short")
        XCTAssertNil(Coordinator.undoTarget(["0123456789abcdef"], shown: shown), "not a string")
        XCTAssertNil(Coordinator.undoTarget(nil, shown: shown))
    }
}
