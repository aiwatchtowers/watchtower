import XCTest
import AppKit
import SwiftUI
import GRDB
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// What the review body stands on (spec 2026-10-03 Part 8): the snapshot
/// rendered once per ask, its places located once, focus links only for
/// places in the snapshot, the previous round's snapshot for the diff, and
/// the text view's boxes for the margin and the focus bars.
@MainActor
final class OwnerAskReviewBodyTests: XCTestCase {
    private static let snapshot = "# Plan\n\nShip the retry budget first.\n\n## Rollout\n\nCanary for a week."

    private func ask(_ id: Int64, snapshot: String = snapshot, focus: String = "[]") throws -> OwnerAsk {
        try OwnerAsk(row: Row([
            "id": id, "project_id": 1, "kind": "review", "title": "Review", "status": "open",
            "payload": #"{"focus":\#(focus)}"#, "doc_path": "docs/plan.md", "doc_snapshot": snapshot
        ]))
    }

    func testTheSnapshotIsRenderedOnceAndItsPlacesLocated() async throws {
        let documents = OwnerAskReviewDocuments()
        let review = try ask(1)
        XCTAssertNil(documents.range(of: OwnerAskFocus(text: "x", heading: "Rollout"), askID: 1), "nothing before the render")
        await documents.prepare(review)
        let doc = try XCTUnwrap(documents.rendered[1])
        XCTAssertEqual(doc, DocumentRendering.render(Self.snapshot))
        await documents.prepare(review)
        XCTAssertEqual(documents.rendered.count, 1)

        let heading = try XCTUnwrap(documents.range(of: OwnerAskFocus(text: "x", heading: "Rollout"), askID: 1))
        XCTAssertEqual((doc.text as NSString).substring(with: heading), "Rollout")
        XCTAssertNil(documents.range(of: OwnerAskFocus(text: "x", quote: "not there"), askID: 1))
        XCTAssertNil(documents.range(of: OwnerAskFocus(text: "x", quote: "not there"), askID: 1), "a miss is remembered as a miss")

        let selection = (doc.text as NSString).range(of: "retry budget")
        let anchor = try XCTUnwrap(OwnerAskReviewText.anchor(selection: selection, in: doc))
        XCTAssertEqual(documents.range(of: anchor, askID: 1), selection)
    }

    func testOnlyAFewRecentSnapshotsAreKept() async throws {
        let documents = OwnerAskReviewDocuments()
        for id in 1...Int64(OwnerAskReviewDocuments.limit + 1) {
            await documents.prepare(try ask(id))
        }
        XCTAssertEqual(documents.rendered.count, OwnerAskReviewDocuments.limit)
        XCTAssertNil(documents.rendered[1], "the oldest goes")
    }

    func testAFocusOutsideTheSnapshotIsListedWithoutALink() throws {
        let review = try ask(1, focus: #"[{"text":"Order","heading":"Rollout"},{"text":"Wording","quote":"gone"}]"#)
        let doc = DocumentRendering.render(Self.snapshot)
        let card = OwnerAskHeaderCard(ask: review) { focus in
            OwnerAskReviewText.range(of: focus, in: doc) == nil ? nil : {}
        }
        XCTAssertNoThrow(try card.inspect().find(button: "Rollout"), "a place in the snapshot links to it")
        XCTAssertThrowsError(try card.inspect().find(button: "gone"))
        XCTAssertNoThrow(try card.inspect().find(text: "gone"), "listed, without a link")
    }

    func testTheDiffReadsThePreviousRoundsSnapshot() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let (project, previous) = try await pool.write { db in
            let project = try TestDatabase.insertWorkbench(db, folder: "/tmp/acme")
            let previous = try TestDatabase.insertOwnerAsk(db, projectID: project, kind: "review", docPath: "docs/plan.md",
                                                           status: "withdrawn", withdrawnReason: "superseded")
            try db.execute(sql: "UPDATE owner_asks SET doc_snapshot = ? WHERE id = ?", arguments: ["# Old plan", previous])
            return (project, previous)
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "OwnerAskReviewBodyTests-\(UUID().uuidString)"))
        let vm = WorkbenchesViewModel(dbPool: pool, cli: WorkbenchCLI(runner: FakeCLIRunner()), defaults: defaults)
        let snapshot = try await vm.asks.snapshot(askID: previous, projectID: project)
        XCTAssertEqual(snapshot, "# Old plan")
        let missing = try await vm.asks.snapshot(askID: previous + 100, projectID: project)
        XCTAssertNil(missing, "a gone ask has no snapshot")
        let elsewhere = try await vm.asks.snapshot(askID: previous, projectID: project + 1)
        XCTAssertNil(elsewhere, "scoped to the workbench")
    }

    func testTheTextViewReportsEachTrackedRangesBox() throws {
        let scroll = DocumentTextView.makeScrollView(horizontalInset: 20)
        scroll.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let textView = try XCTUnwrap(scroll.documentView as? NSTextView)
        textView.textStorage?.setAttributedString(NSAttributedString(string: "First line\nSecond line\nThird line"))
        let text = textView.string as NSString
        let rects = DocumentTextView.Coordinator.visibleRects(
            of: [text.range(of: "Second"), NSRange(location: NSNotFound, length: 0), NSRange(location: 5, length: 500),
                 text.range(of: "Third")],
            in: textView
        )
        XCTAssertEqual(rects.count, 4)
        let second = try XCTUnwrap(rects[0])
        let third = try XCTUnwrap(rects[3])
        XCTAssertNil(rects[1], "a passage not found has no box")
        XCTAssertNil(rects[2], "a range past the text has no box")
        XCTAssertGreaterThan(third.minY, second.minY, "boxes follow the lines")
        XCTAssertGreaterThanOrEqual(second.minX, 20, "inside the column's inset")
    }
}
