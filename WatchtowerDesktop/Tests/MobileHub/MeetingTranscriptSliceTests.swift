import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerSync
import WatchtowerTestSupport

/// The `meeting_transcript` projection (mobile POC spec §4.11): the window,
/// the recap join (transcript first, then event, then `summary_json`), the
/// caps, the `segments.json` asset (deleted segments out, legacy rows as one
/// segment, the 20 MB clip) and the hidden columns.
final class MeetingTranscriptSliceTests: XCTestCase {
    private var dbPath: String!
    private var dbPool: DatabasePool!
    private var assetDir: URL!
    private let day: TimeInterval = 86_400
    /// Whole seconds: the DB stores `…:SSZ`.
    private let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))

    override func setUpWithError() throws {
        (dbPool, dbPath) = try TestDatabase.createPool()
        assetDir = FileManager.default.temporaryDirectory.appendingPathComponent("mt-assets-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        dbPool = nil
        TestDatabase.cleanup(path: dbPath)
        if let assetDir, FileManager.default.fileExists(atPath: assetDir.path) {
            try FileManager.default.removeItem(at: assetDir)
        }
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? calendar.timeZone
        return calendar
    }

    private func slice(phoneRecordingID: @escaping @Sendable (Int64) -> String? = { _ in nil }) -> MeetingTranscriptSlice {
        let stamp = now
        let calendar = utc
        return MeetingTranscriptSlice(now: { stamp }, calendar: { calendar }, phoneRecordingID: phoneRecordingID)
    }

    private func records(_ slice: MeetingTranscriptSlice? = nil) throws -> [AssetSliceRecord] {
        let slice = slice ?? self.slice()
        let records = try dbPool.read { try slice.assetRecords($0) }
        XCTAssertTrue(records.allSatisfy { $0.record.kind == .meetingTranscript })
        XCTAssertTrue(records.allSatisfy { $0.asset?.fileName == "segments.json" })
        return records
    }

    private func ids() throws -> [String] {
        try records().map(\.record.id)
    }

    private func published(_ id: Int64, _ slice: MeetingTranscriptSlice? = nil) throws -> (payload: [String: Any], asset: [[String: Any]]) {
        let record = try XCTUnwrap(try records(slice).first { $0.record.id == String(id) }, "transcript \(id) is not published")
        let asset = try JSONSerialization.jsonObject(with: try XCTUnwrap(record.asset).data)
        return (try SliceJSON.object(record.record.payload), try XCTUnwrap(asset as? [[String: Any]]))
    }

    @discardableResult
    private func insertTranscript(
        eventID: String? = nil,
        title: String = "Acme standup",
        createdAt: Date? = nil,
        transcriptText: String = "[Colleague A] Morning.",
        segmentsJSON: String? = nil,
        summaryJSON: String? = nil,
        chaptersJSON: String? = nil,
        audioPath: String? = nil,
        notesMD: String? = nil,
        speakersJSON: String? = nil
    ) throws -> Int64 {
        try dbPool.write { db in
            try TestDatabase.insertMeetingTranscript(
                db, eventID: eventID, title: title, audioPath: audioPath, durationSec: 754, transcriptText: transcriptText,
                summaryJSON: summaryJSON, notesMD: notesMD, segmentsJSON: segmentsJSON, speakersJSON: speakersJSON,
                chaptersJSON: chaptersJSON, createdAt: dbStamp(createdAt ?? now.addingTimeInterval(-3600))
            )
            let id = db.lastInsertedRowID
            try db.execute(sql: "UPDATE meeting_transcripts SET updated_at = created_at WHERE id = ?", arguments: [id])
            return id
        }
    }

    private func insertEvent(_ id: String, start: Date) throws {
        try dbPool.write { db in
            try TestDatabase.insertCalendarEvent(
                db, id: id, startTime: dbStamp(start), endTime: dbStamp(start.addingTimeInterval(1800))
            )
        }
    }

    private func insertRecap(eventID: String? = nil, transcriptID: Int64? = nil, summary: String, updatedAt: Date? = nil) throws {
        let json = #"{"summary":"\#(summary)","key_decisions":["Ship on Friday"],"action_items":[],"open_questions":[]}"#
        try dbPool.write { db in
            try TestDatabase.insertMeetingRecap(
                db, eventID: eventID, transcriptID: transcriptID, recapJSON: json,
                createdAt: dbStamp(updatedAt ?? now.addingTimeInterval(-60))
            )
        }
    }

    private func segmentsJSON(_ segments: [(speaker: String, text: String, deleted: Bool)]) -> String {
        let utterances = segments.enumerated().map { index, segment in
            TranscriptUtterance(
                idx: index, startSec: Double(index) * 4.5, endSec: Double(index + 1) * 4.5,
                speaker: segment.speaker, text: segment.text, deleted: segment.deleted
            )
        }
        return TranscriptSegments.encode(utterances) ?? "[]"
    }

    private func utf8(_ data: Data) -> String {
        String(bytes: data, encoding: .utf8) ?? ""
    }

    // MARK: - Wire shape

    private let optionalKeys: Set<String> = [
        "event_id", "title_clipped", "phone_recording_id", "speakers_more", "summary", "key_decisions_more",
        "action_items_more", "open_questions_more", "overview", "overview_clipped", "segments_clipped"
    ]

    private let kitTests = "WatchtowerKitTests/CalendarMirrorFixtureTests.swift"

    func testATranscriptAndItsAssetMatchTheKitFixtures() throws {
        try insertEvent("evt-1", start: now.addingTimeInterval(-7200))
        let id = try insertTranscript(
            eventID: "evt-1",
            segmentsJSON: segmentsJSON([("Colleague A", "Morning.", false), ("", "Hi.", false)]),
            chaptersJSON: #"{"overall_summary":"A short standup.","chapters":[]}"#
        )
        try insertRecap(eventID: "evt-1", summary: "Release is on track.")
        let (payload, asset) = try published(id, slice { $0 == id ? "R1" : nil })

        let fixture = try SliceJSON.object(try SliceJSON.kitInlineFixture(kitTests, test: "testMeetingTranscriptFixture"))
        assertWireShape(payload, matches: fixture, optionalKeys: optionalKeys)
        XCTAssertEqual(payload["id"] as? Int64, id)
        XCTAssertEqual(payload["event_id"] as? String, "evt-1")
        XCTAssertEqual(payload["phone_recording_id"] as? String, "R1")
        XCTAssertEqual(payload["duration_sec"] as? Int, 754)
        XCTAssertEqual(payload["speakers"] as? [String], ["Colleague A"], "\"\" is not a speaker")
        XCTAssertEqual(payload["summary"] as? String, "Release is on track.")
        XCTAssertEqual(payload["key_decisions"] as? [String], ["Ship on Friday"])
        XCTAssertEqual(payload["overview"] as? String, "A short standup.")
        XCTAssertEqual(payload["created_at"] as? String, dbStamp(now.addingTimeInterval(-3600)), "the stored string")
        XCTAssertNil(payload["segments_clipped"], "an unclipped asset omits the flag")

        let segmentsFixture = try JSONSerialization.jsonObject(
            with: try SliceJSON.kitInlineFixture(kitTests, test: "testSegmentsAssetFixture")
        )
        let fixtureSegment = try XCTUnwrap((segmentsFixture as? [[String: Any]])?.first)
        XCTAssertEqual(asset.count, 2)
        for segment in asset { assertWireShape(segment, matches: fixtureSegment) }
        XCTAssertEqual(asset.map { $0["speaker"] as? String }, ["Colleague A", ""])
        XCTAssertEqual(asset.map { $0["end_sec"] as? Double }, [4.5, 9])
    }

    func testAnAdHocTranscriptOmitsTheOptionalKeys() throws {
        let id = try insertTranscript(transcriptText: "")
        let (payload, asset) = try published(id)
        for key in optionalKeys { XCTAssertNil(payload[key], key) }
        XCTAssertEqual(payload["speakers"] as? [String], [])
        XCTAssertEqual(payload["action_items"] as? [String], [])
        XCTAssertTrue(asset.isEmpty, "no segments and no text: an empty asset")
    }

    func testNoTranscriptsPublishNothing() throws {
        XCTAssertTrue(try records().isEmpty)
    }

    // MARK: - Recap

    /// The event aged out of the calendar (and the recap lost its event
    /// link): the durable `transcript_id` link still finds it.
    func testARecapLinkedOnlyByTranscriptIDIsFound() throws {
        try insertEvent("evt-old", start: now.addingTimeInterval(-60 * day))
        let id = try insertTranscript(eventID: "evt-old")
        let orphan = try insertTranscript(eventID: nil)
        try insertRecap(transcriptID: id, summary: "Own recap")
        try insertRecap(transcriptID: orphan, summary: "Orphan recap")

        XCTAssertEqual(try published(id).payload["summary"] as? String, "Own recap")
        XCTAssertEqual(try published(orphan).payload["summary"] as? String, "Orphan recap")
    }

    func testARecapLinkedByTheEventIsFoundAndTheTranscriptLinkWins() throws {
        try insertEvent("evt-1", start: now.addingTimeInterval(-7200))
        let byEvent = try insertTranscript(eventID: "evt-1")
        try insertEvent("evt-2", start: now.addingTimeInterval(-7200))
        let both = try insertTranscript(eventID: "evt-2")
        try insertRecap(eventID: "evt-1", summary: "Event recap")
        try insertRecap(eventID: "evt-2", summary: "Pasted recap", updatedAt: now)
        try insertRecap(transcriptID: both, summary: "Own recap", updatedAt: now.addingTimeInterval(-600))

        XCTAssertEqual(try published(byEvent).payload["summary"] as? String, "Event recap")
        XCTAssertEqual(try published(both).payload["summary"] as? String, "Own recap", "the transcript link wins")
    }

    func testAnAdHocRecordingUsesSummaryJSON() throws {
        let id = try insertTranscript(
            summaryJSON: #"{"summary":"Voice note recap","key_decisions":[],"action_items":["Call colleague A"],"open_questions":["When?"]}"#
        )
        let payload = try published(id).payload
        XCTAssertNil(payload["event_id"])
        XCTAssertEqual(payload["summary"] as? String, "Voice note recap")
        XCTAssertEqual(payload["action_items"] as? [String], ["Call colleague A"])
        XCTAssertEqual(payload["open_questions"] as? [String], ["When?"])
    }

    func testAnUnreadableRecapFallsBackToSummaryJSON() throws {
        let id = try insertTranscript(
            summaryJSON: #"{"summary":"Own summary","key_decisions":[],"action_items":[],"open_questions":[]}"#
        )
        try dbPool.write { db in
            try TestDatabase.insertMeetingRecap(db, transcriptID: id, recapJSON: "not json")
        }
        XCTAssertEqual(try published(id).payload["summary"] as? String, "Own summary")
    }

    func testRecapListsAreCappedAt50EntriesOf500() throws {
        let long = String(repeating: "a", count: 600)
        let items = (0..<51).map { _ in "\"\(long)\"" }.joined(separator: ",")
        let id = try insertTranscript(
            summaryJSON: #"{"summary":"s","key_decisions":[],"action_items":[\#(items)],"open_questions":[]}"#
        )
        let payload = try published(id).payload
        let actions = try XCTUnwrap(payload["action_items"] as? [String])
        XCTAssertEqual(actions.count, 50)
        XCTAssertEqual(payload["action_items_more"] as? Int, 1)
        XCTAssertTrue(actions.allSatisfy { $0.count == 500 && $0.hasSuffix("…") })
        XCTAssertNil(payload["key_decisions_more"])
    }

    // MARK: - Fields

    func testTitleSpeakersAndOverviewAreCapped() throws {
        let speakers = (1...21).map { (speaker: "Speaker \($0)", text: "t", deleted: false) }
        let overview = String(repeating: "o", count: 2001)
        let id = try insertTranscript(
            title: String(repeating: "T", count: 301),
            segmentsJSON: segmentsJSON(speakers),
            chaptersJSON: #"{"overall_summary":"\#(overview)","chapters":[{"title":"x","summary":"hidden chapter"}]}"#
        )
        let payload = try published(id).payload
        XCTAssertEqual((payload["title"] as? String)?.count, 300)
        XCTAssertEqual(payload["title_clipped"] as? Bool, true)
        XCTAssertEqual((payload["speakers"] as? [String])?.count, 20)
        XCTAssertEqual(payload["speakers_more"] as? Int, 1)
        XCTAssertEqual((payload["overview"] as? String)?.count, 2000)
        XCTAssertEqual(payload["overview_clipped"] as? Bool, true)
        XCTAssertFalse(utf8(try JSONSerialization.data(withJSONObject: payload)).contains("hidden chapter"))
    }

    // MARK: - Segments asset

    func testALegacyTranscriptIsOneSegmentHoldingTheText() throws {
        let id = try insertTranscript(transcriptText: "[Я] Legacy text.", segmentsJSON: nil)
        let (payload, asset) = try published(id)
        XCTAssertEqual(asset.count, 1)
        XCTAssertEqual(asset.first?["text"] as? String, "[Я] Legacy text.")
        XCTAssertEqual(asset.first?["speaker"] as? String, "")
        XCTAssertEqual(asset.first?["start_sec"] as? Double, 0)
        XCTAssertEqual(asset.first?["end_sec"] as? Double, 754)
        XCTAssertEqual(payload["speakers"] as? [String], [])
    }

    func testUnreadableSegmentsFallBackToTheText() throws {
        let id = try insertTranscript(transcriptText: "Flat text.", segmentsJSON: "{broken")
        XCTAssertEqual(try published(id).asset.map { $0["text"] as? String }, ["Flat text."])
    }

    func testDeletedSegmentsAreNeverInTheAsset() throws {
        let id = try insertTranscript(segmentsJSON: segmentsJSON([
            ("Colleague A", "Kept one.", false),
            ("Speaker 2", "Deleted secret.", true),
            ("Colleague A", "Kept two.", false)
        ]))
        let record = try XCTUnwrap(try records().first { $0.record.id == String(id) })
        let (payload, asset) = try published(id)
        XCTAssertEqual(asset.map { $0["text"] as? String }, ["Kept one.", "Kept two."])
        XCTAssertFalse(utf8(try XCTUnwrap(record.asset).data).contains("Deleted secret."))
        XCTAssertEqual(payload["speakers"] as? [String], ["Colleague A"], "a speaker only in deleted segments is not listed")
    }

    func testAllSegmentsDeletedIsAnEmptyAsset() throws {
        let id = try insertTranscript(transcriptText: "", segmentsJSON: segmentsJSON([("Colleague A", "Gone.", true)]))
        XCTAssertTrue(try published(id).asset.isEmpty)
    }

    func testAnAssetOver20MBIsClippedWithSegmentsClipped() throws {
        let text = String(repeating: "x", count: 1_000_000)
        let id = try insertTranscript(segmentsJSON: segmentsJSON((0..<21).map { _ in ("Colleague A", text, false) }))
        let record = try XCTUnwrap(try records().first { $0.record.id == String(id) })
        let data = try XCTUnwrap(record.asset).data

        XCTAssertEqual(MeetingTranscriptSlice.maxAssetBytes, 20 * 1024 * 1024)
        XCTAssertLessThanOrEqual(data.count, MeetingTranscriptSlice.maxAssetBytes)
        let asset = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(asset.count, 20, "whole segments up to the cap, in order")
        XCTAssertEqual(asset.last?["start_sec"] as? Double, 19 * 4.5)
        XCTAssertEqual(try SliceJSON.object(record.record.payload)["segments_clipped"] as? Bool, true)
    }

    func testTheAssetCapBoundary() throws {
        let encoder = RelayCoder.makeEncoder()
        let segments = [
            MeetingTranscriptSlice.Segment(startSec: 0, endSec: 1, speaker: "", text: "a"),
            MeetingTranscriptSlice.Segment(startSec: 1, endSec: 2, speaker: "", text: "b")
        ]
        let whole = try encoder.encode(segments)
        let exact = try MeetingTranscriptSlice.encodeAsset(segments, encoder: encoder, maxBytes: whole.count)
        XCTAssertEqual(exact.data, whole, "assembled element by element = the array's own encoding")
        XCTAssertNil(exact.clipped, "exactly the cap still fits")

        let over = try MeetingTranscriptSlice.encodeAsset(segments, encoder: encoder, maxBytes: whole.count - 1)
        XCTAssertEqual(over.data, try encoder.encode([segments[0]]))
        XCTAssertEqual(over.clipped, true)

        let none = try MeetingTranscriptSlice.encodeAsset(segments, encoder: encoder, maxBytes: 2)
        XCTAssertEqual(utf8(none.data), "[]")
        XCTAssertEqual(none.clipped, true)
    }

    // MARK: - Hidden columns

    func testHiddenColumnsAreNeverPublished() throws {
        let id = try insertTranscript(
            segmentsJSON: segmentsJSON([("Colleague A", "Hello.", false)]),
            audioPath: "~/Recordings/rec_secret.caf",
            notesMD: "secret notes",
            speakersJSON: #"[{"speaker":"Colleague A","embedding":[0.123456]}]"#
        )
        let record = try XCTUnwrap(try records().first { $0.record.id == String(id) })
        let payload = try SliceJSON.object(record.record.payload)
        let asset = try JSONSerialization.jsonObject(with: try XCTUnwrap(record.asset).data)
        let keys = SliceJSON.allKeys(payload).union(SliceJSON.allKeys(asset))
        for hidden in ["audio_path", "speakers_json", "notes_md", "embedding", "transcript_text", "summary_json", "chapters_json"] {
            XCTAssertFalse(keys.contains(hidden), hidden)
        }
        let bytes = utf8(record.record.payload + (record.asset?.data ?? Data()))
        for value in ["rec_secret", "secret notes", "0.123456"] {
            XCTAssertFalse(bytes.contains(value), value)
        }
    }

    // MARK: - Window

    func testTheWindowKeepsTheNewest200() throws {
        var inserted: [Int64] = []
        for minute in 0..<201 {
            inserted.append(try insertTranscript(createdAt: now.addingTimeInterval(-Double(minute + 1) * 60)))
        }
        let published = try ids()
        XCTAssertEqual(published.count, 200)
        XCTAssertEqual(published, inserted.prefix(200).map(String.init), "newest first")
        XCTAssertFalse(published.contains(String(try XCTUnwrap(inserted.last))), "the oldest is dropped")
    }

    func testAnOldTranscriptIsPublishedOnlyWhenItsEventIsInTheCalendarWindow() throws {
        try insertEvent("evt-soon", start: now.addingTimeInterval(2 * day))
        try insertEvent("evt-old", start: now.addingTimeInterval(-31 * day))
        let recent = try insertTranscript(createdAt: now.addingTimeInterval(-29 * day))
        let oldAdHoc = try insertTranscript(createdAt: now.addingTimeInterval(-31 * day))
        let oldOldEvent = try insertTranscript(eventID: "evt-old", createdAt: now.addingTimeInterval(-31 * day))
        let oldWindowEvent = try insertTranscript(eventID: "evt-soon", createdAt: now.addingTimeInterval(-40 * day))

        let published = Set(try ids())
        XCTAssertTrue(published.contains(String(recent)))
        XCTAssertFalse(published.contains(String(oldAdHoc)), "31 days old, no event in the window")
        XCTAssertFalse(published.contains(String(oldOldEvent)), "31 days old, its event is out of the window")
        XCTAssertTrue(published.contains(String(oldWindowEvent)), "its event is in the calendar window")
    }

    // MARK: - Hash (through the publisher)

    func testASpeakerRenameRepublishesAndAnUnchangedTranscriptDoesNot() async throws {
        let renamed = try insertTranscript(segmentsJSON: segmentsJSON([("Speaker 1", "Morning.", false)]))
        let unchanged = try insertTranscript(segmentsJSON: segmentsJSON([("Speaker 1", "Hi.", false)]))
        let transport = StubHubTransport()
        let store = SliceAssetStore(directory: assetDir)
        let publisher = SlicePublisher(
            dbPool: dbPool, state: try HubSyncState.inMemory(), transport: transport, sources: [slice()], assets: store
        )
        let first = try await publisher.publishOnce()
        XCTAssertEqual(first.pushed, 2)

        let relabelled = segmentsJSON([("Colleague A", "Morning.", false)])
        try await dbPool.write { db in
            try db.execute(sql: "UPDATE meeting_transcripts SET segments_json = ? WHERE id = ?", arguments: [relabelled, renamed])
        }
        let second = try await publisher.publishOnce()

        XCTAssertEqual(second.pushed, 1, "only the renamed transcript is republished")
        let last = try XCTUnwrap(transport.saved.last?.record)
        XCTAssertEqual(last.recordName, "meeting_transcript-\(renamed)")
        let file = try XCTUnwrap(last.assetFileURL)
        XCTAssertEqual(file, store.fileURL(recordName: last.recordName, fileName: "segments.json"))
        XCTAssertTrue(utf8(try Data(contentsOf: file)).contains("Colleague A"))
        XCTAssertFalse(transport.saved.dropFirst(2).contains { $0.record.recordName == "meeting_transcript-\(unchanged)" })
        let third = try await publisher.publishOnce()
        XCTAssertEqual(third.pushed, 0, "nothing changed")
    }
}
