import GRDB
import XCTest
import WatchtowerKit
@testable import WatchtowerMobile

/// Wiring + projection tests for the Recordings screen (item 2b): the view
/// model's observation and ordering over the `meeting_transcript` slice, and
/// the two pure projections the views render — `RecordingRow` (the cheap list
/// row) and `RecordingDetail` (decoded once per version).
///
/// The degenerate states get as much weight as the happy path, because every
/// one of them is reachable on a real phone: no recordings at all, a recording
/// with no recap/notes/chapters, an undiarized one with an empty roster, and an
/// ad-hoc one with no linked event.
@MainActor
final class RecordingsWiringTests: XCTestCase {

    // MARK: - Helpers

    /// Pool-backed store on a throwaway path — the production mechanism the
    /// observation runs against (`ReplicaWiringTests.makePoolStore` twin).
    private func makePoolStore() throws -> ReplicaStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-recordings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return try ReplicaStore(path: dir.appendingPathComponent("replica.sqlite").path)
    }

    private func seed(into store: ReplicaStore) async throws {
        let transport = InMemoryCloudTransport()
        try await DemoSeed.load(into: transport)
        let hydrator = ReplicaHydrator(transport: transport, store: store)
        _ = try await hydrator.hydrateOnce()
    }

    private func poll(
        timeout: TimeInterval = 5,
        _ condition: () -> Bool,
        _ message: @autoclosure () -> String = "condition not met in time",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), message(), file: file, line: line)
    }

    /// A slice row exactly as the publisher's projection delivers it — the
    /// decode path `ReplicaStore.fetchAll` feeds the view model.
    private func transcript(
        id: Int = 1,
        eventID: String? = nil,
        eventTitle: String? = nil,
        title: String = "Weekly sync",
        durationSec: Int = 600,
        notesMD: String = "",
        chaptersJSON: String = "",
        recapJSON: String = "",
        speakers: String = "[]",
        snippet: String = "",
        createdAt: String = "2026-08-01T09:00:00Z",
        updatedAt: String = "2026-08-01T09:00:00Z"
    ) -> MeetingTranscript {
        MeetingTranscript(row: Row([
            "id": id,
            "event_id": eventID,
            "event_title": eventTitle,
            "title": title,
            "duration_sec": durationSec,
            "lang_stats": "",
            "notes_md": notesMD,
            "chapters_json": chaptersJSON,
            "recap_json": recapJSON,
            "speakers": speakers,
            "snippet": snippet,
            "created_at": createdAt,
            "updated_at": updatedAt,
        ]))
    }

    // MARK: - View model over the slice

    /// The demo seed's two recordings surface newest-first (the publisher's
    /// `created_at DESC, id DESC` order), and the badges come from the cheap
    /// booleans — the processed recording has both, the raw one neither.
    func testViewModelListsSeededRecordingsNewestFirst() async throws {
        let store = try makePoolStore()
        try await seed(into: store)

        let model = RecordingsViewModel()
        model.start(store: store)
        try await poll { model.rows.count == 2 }

        XCTAssertEqual(model.rows.map(\.id), [1, 2], "newest recording must lead the list")

        let processed = try XCTUnwrap(model.rows.first)
        XCTAssertEqual(processed.title, "Mobile app design review")
        XCTAssertFalse(processed.isAdHoc, "recording 1 is linked to evt-2")
        XCTAssertTrue(processed.hasRecap)
        XCTAssertTrue(processed.hasNotes)
        XCTAssertEqual(processed.durationLabel, "45m 32s")

        let raw = try XCTUnwrap(model.rows.last)
        XCTAssertEqual(raw.title, "Untitled recording")
        XCTAssertTrue(raw.isAdHoc)
        XCTAssertFalse(raw.hasRecap)
        XCTAssertFalse(raw.hasNotes)
    }

    /// The live record behind an open detail screen, and its absence — a
    /// desktop-side delete drops the row from the slice, and the detail then
    /// renders "Recording unavailable" instead of stale content.
    func testTranscriptLookupFollowsTheSlice() async throws {
        let store = try makePoolStore()
        try await seed(into: store)

        let model = RecordingsViewModel()
        model.start(store: store)
        try await poll { model.rows.count == 2 }

        XCTAssertNotNil(model.transcript(id: 1))
        XCTAssertNil(model.transcript(id: 99), "an unknown id must not resolve")
    }

    /// Degenerate state 1 — no recordings at all. Reached for real by a fresh
    /// install and by deleting every recording on the Mac; the list must empty
    /// out (which is what drives the `ContentUnavailableView`), not keep the
    /// last snapshot.
    func testListEmptiesWhenEveryRecordingLeavesTheSlice() async throws {
        let store = try makePoolStore()
        try await seed(into: store)

        let model = RecordingsViewModel()
        model.start(store: store)
        try await poll { model.rows.count == 2 }

        try store.apply(CloudChangeBatch(
            changed: [],
            deletedRecordNames: [
                SliceKind.meetingTranscript.recordName(id: "1"),
                SliceKind.meetingTranscript.recordName(id: "2"),
            ],
            newToken: CloudChangeToken(value: 99)
        ))

        try await poll { model.rows.isEmpty }
        XCTAssertNil(model.transcript(id: 1), "the open detail must lose its record too")
    }

    // MARK: - Row projection

    /// The recording's own title wins; the linked event's title is the
    /// fallback, and it is not repeated as a subtitle when it IS the title.
    func testRowFallsBackToEventTitleWhenRecordingTitleIsEmpty() {
        let withOwnTitle = RecordingRow(transcript(
            eventID: "evt-1", eventTitle: "Weekly sync (calendar)", title: "Weekly sync"
        ))
        XCTAssertEqual(withOwnTitle.title, "Weekly sync")
        XCTAssertEqual(withOwnTitle.eventTitle, "Weekly sync (calendar)")

        let borrowed = RecordingRow(transcript(eventID: "evt-1", eventTitle: "Weekly sync", title: ""))
        XCTAssertEqual(borrowed.title, "Weekly sync", "empty own title must borrow the event's")
        XCTAssertNil(borrowed.eventTitle, "the borrowed title must not repeat as a subtitle")
        XCTAssertFalse(borrowed.isAdHoc)
    }

    /// Degenerate state 4 — an ad-hoc recording: `event_id` nil, so no event
    /// title exists to borrow and the row needs a placeholder of its own.
    func testAdHocRecordingWithoutTitleGetsAPlaceholder() {
        let row = RecordingRow(transcript(eventID: nil, eventTitle: nil, title: "   "))
        XCTAssertEqual(row.title, "Untitled recording")
        XCTAssertNil(row.eventTitle)
        XCTAssertTrue(row.isAdHoc)
    }

    /// An unparseable or empty `created_at` must not produce a stray
    /// separator; the raw value is shown rather than swallowed.
    func testMetaLabelDropsUnusableHalves() {
        XCTAssertEqual(RecordingRow(transcript(durationSec: 95, createdAt: "")).metaLabel, "1m 35s")
        XCTAssertEqual(RecordingFormatting.date("garbage"), "garbage")
        XCTAssertEqual(RecordingFormatting.duration(42), "42s")
        XCTAssertEqual(RecordingFormatting.timecode(3723), "1:02:03")
        XCTAssertEqual(RecordingFormatting.timecode(62), "1:02")
    }

    // MARK: - Detail projection

    /// Degenerate state 2 — nothing generated: no recap, no notes, no
    /// chapters. Every section is empty and the screen says so explicitly.
    func testDetailOfUnprocessedRecordingIsMarkedEmpty() {
        let detail = RecordingDetail(transcript(notesMD: "", chaptersJSON: "", recapJSON: ""))
        XCTAssertEqual(detail.recap, .absent)
        XCTAssertTrue(detail.chapters.isEmpty)
        XCTAssertTrue(detail.notes.isEmpty)
        XCTAssertTrue(detail.hasNoGeneratedContent)
    }

    /// A recap that decodes to nothing (`{}` — a partial AI payload) counts as
    /// "nothing generated" too: rendering an empty Recap section with a badge
    /// promising one would be a lie.
    func testBlankPresentRecapStillCountsAsNothingGenerated() {
        let detail = RecordingDetail(transcript(recapJSON: "{}"))
        guard case .present(let recap) = detail.recap else {
            return XCTFail("valid-but-empty JSON decodes — it is present, not unreadable")
        }
        XCTAssertTrue(recap.summary.isEmpty)
        XCTAssertTrue(detail.hasNoGeneratedContent)
    }

    /// A non-empty but unreadable `recap_json`: the list badge already promised
    /// a recap, so the detail reports the failure instead of looking empty.
    func testUnreadableRecapIsReportedNotSilentlyEmpty() {
        let detail = RecordingDetail(transcript(recapJSON: "not json"))
        XCTAssertEqual(detail.recap, .unreadable)
        XCTAssertFalse(detail.hasNoGeneratedContent, "the warning IS content — the hint must not also show")
    }

    /// The happy path: a full recap decodes into its four groups exactly once.
    func testDetailDecodesFullRecap() throws {
        let json = """
            {"summary":"Shipped the read-only screen.",
             "key_decisions":["No seventh tab"],
             "action_items":["Wire the list"],
             "open_questions":["Rich markdown later?"]}
            """
        let detail = RecordingDetail(transcript(recapJSON: json))
        guard case .present(let recap) = detail.recap else {
            return XCTFail("a valid recap must decode to .present")
        }
        XCTAssertEqual(recap.summary, "Shipped the read-only screen.")
        XCTAssertEqual(recap.keyDecisions, ["No seventh tab"])
        XCTAssertEqual(recap.actionItems, ["Wire the list"])
        XCTAssertEqual(recap.openQuestions, ["Rich markdown later?"])
        XCTAssertFalse(detail.hasNoGeneratedContent)
    }

    /// Degenerate state 3 — an undiarized recording: the roster is `[]` (or
    /// absent), so the Speakers section simply does not render.
    func testEmptySpeakerRosterYieldsNoSpeakers() {
        XCTAssertTrue(RecordingDetail(transcript(speakers: "[]")).speakers.isEmpty)
        XCTAssertTrue(RecordingDetail(transcript(speakers: "")).speakers.isEmpty)
        XCTAssertEqual(
            RecordingDetail(transcript(speakers: #"["Я","Speaker 2"]"#)).speakers,
            ["Я", "Speaker 2"]
        )
    }

    /// Chapters decode tolerantly: a chapter missing every optional key still
    /// renders with a positional title and a zero span, and malformed JSON
    /// yields no chapters rather than hiding the recording.
    func testChaptersDecodeTolerantly() {
        let partial = RecordingChapter.decode(#"{"chapters":[{},{"title":"Rollout","start_sec":540,"end_sec":600}]}"#)
        XCTAssertEqual(partial.map(\.title), ["Chapter 1", "Rollout"])
        XCTAssertEqual(partial.first?.timeRange, "0:00 – 0:00")
        XCTAssertEqual(partial.last?.timeRange, "9:00 – 10:00")

        XCTAssertTrue(RecordingChapter.decode("not json").isEmpty)
        XCTAssertTrue(RecordingChapter.decode("").isEmpty)
        XCTAssertTrue(RecordingChapter.decode(#"{"overall_summary":"s"}"#).isEmpty)
    }

    /// The notes are trimmed, so a whitespace-only `notes_md` neither shows a
    /// badge in the list nor an empty section in the detail.
    func testWhitespaceOnlyNotesCountAsNoNotes() {
        XCTAssertFalse(RecordingRow(transcript(notesMD: "\n \n")).hasNotes)
        XCTAssertTrue(RecordingDetail(transcript(notesMD: "\n \n")).notes.isEmpty)
        XCTAssertEqual(RecordingDetail(transcript(notesMD: "# Notes\n\n- one")).notes, "# Notes\n\n- one")
    }
}
