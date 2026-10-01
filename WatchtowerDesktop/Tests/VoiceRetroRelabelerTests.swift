import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

final class VoiceRetroRelabelerTests: XCTestCase {
    private func v(_ x: Float, _ y: Float) -> [Float] { [x, y] }

    private let threeSpeakerUtterances = [
        TranscriptUtterance(idx: 0, startSec: 0, endSec: 1, speaker: "Speaker 1", text: "привет"),
        TranscriptUtterance(idx: 1, startSec: 1, endSec: 2, speaker: "Bob", text: "hi"),
        TranscriptUtterance(idx: 2, startSec: 2, endSec: 3, speaker: "Я", text: "да")
    ]

    /// Inserts a segmented transcript for the given utterances/speakers_json and returns its id.
    private func insertTranscript(
        _ db: Database, utterances: [TranscriptUtterance], speakersJSON: String, eventID: String? = nil
    ) throws -> Int64 {
        try TestDatabase.insertMeetingTranscript(
            db, eventID: eventID,
            transcriptText: TranscriptSegments.render(utterances),
            segmentsJSON: try XCTUnwrap(TranscriptSegments.encode(utterances)),
            speakersJSON: speakersJSON)
        return db.lastInsertedRowID
    }

    /// The three-speaker fixture: "Speaker 1" matches Alice's active sample
    /// ([1,0]); "Bob" and "Я" are already named and carry an unrelated
    /// embedding ([0,1]) so they can never compete with "Speaker 1" for
    /// Alice's one-cluster-per-recording slot (VoiceMatcher.decide) — the
    /// brief's own literal fixture gives all three clusters the SAME [1,0]
    /// embedding, which collides them onto Alice and (by sorted-label
    /// tie-break) hands the confident slot to "Bob" instead of "Speaker 1",
    /// making the assertion below fail; this fixture keeps the intent (only
    /// the unnamed cluster gets relabeled, named ones are never touched)
    /// without the accidental collision.
    private func threeSpeakerSpeakersJSON() -> String {
        #"""
        [{"speaker":"Speaker 1","embedding":[1,0]},
         {"speaker":"Bob","embedding":[0,1]},
         {"speaker":"Я","embedding":[0,1]}]
        """#
    }

    func testRelabelsOnlyUnnamedClustersIncludingAudioLessRecordings() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            let tid = try self.insertTranscript(conn, utterances: self.threeSpeakerUtterances,
                                                speakersJSON: self.threeSpeakerSpeakersJSON())
            // audioPath was never set (nil) — the recording has no audio, and
            // retro still relabels it from the persisted embedding alone.
            let alice = try VoicePrintQueries.findOrCreate(conn, personKey: "alice@example.com", displayName: "Alice")
            var sample = VoiceSample(personID: try XCTUnwrap(alice.id), embedding: VoicePrintEmbedding.encode(self.v(1, 0)),
                                     modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                     origin: .owner, anchor: true, status: .active)
            try VoiceSampleQueries.insert(conn, &sample)

            XCTAssertEqual(try VoiceRetroRelabeler.run(conn), 1)

            let labels = try XCTUnwrap(MeetingTranscriptQueries.fetch(conn, id: tid)?.speakerEmbeddings).map(\.speaker)
            XCTAssertEqual(Set(labels), ["Alice", "Bob", "Я"], "Bob and «Я» untouched")
            XCTAssertEqual(try VoiceLabelQueueQueries.pendingCount(conn), 0, "retro never enqueues")
            XCTAssertEqual(try VoiceSample.fetchCount(conn), 1, "retro never learns a new sample")
        }
    }

    /// Counts committed transactions that touched `meeting_transcripts`.
    private final class TranscriptCommitCounter: TransactionObserver, @unchecked Sendable {
        private var dirty = false
        private(set) var commits = 0
        func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { eventKind.tableName == "meeting_transcripts" }
        func databaseDidChange(with event: DatabaseEvent) { dirty = true }
        func databaseDidCommit(_ db: Database) {
            if dirty { commits += 1 }
            dirty = false
        }
        func databaseDidRollback(_ db: Database) { dirty = false }
    }

    /// Spec §4.1: the pooled pass (the launch catch-up) writes one
    /// transaction per transcript, never one over the whole history.
    func testPooledRunWritesOneTransactionPerTranscript() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let one = [TranscriptUtterance(idx: 0, startSec: 0, endSec: 1, speaker: "Speaker 1", text: "hi")]
        let ids = try await pool.write { conn -> [Int64] in
            let ids = try (0..<3).map { _ in
                try self.insertTranscript(conn, utterances: one, speakersJSON: #"[{"speaker":"Speaker 1","embedding":[1,0]}]"#)
            }
            let alice = try VoicePrintQueries.findOrCreate(conn, personKey: "alice@example.com", displayName: "Alice")
            var sample = VoiceSample(personID: try XCTUnwrap(alice.id), embedding: VoicePrintEmbedding.encode(self.v(1, 0)),
                                     modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                     origin: .owner, anchor: true, status: .active)
            try VoiceSampleQueries.insert(conn, &sample)
            return ids
        }
        let counter = TranscriptCommitCounter()
        pool.add(transactionObserver: counter, extent: .observerLifetime)

        let changed = try await VoiceRetroRelabeler.run(in: pool)

        XCTAssertEqual(changed, 3)
        XCTAssertEqual(counter.commits, 3, "one write transaction per relabeled transcript")
        let labels = try await pool.read { conn in
            try ids.map { try MeetingTranscriptQueries.fetch(conn, id: $0)?.speakerEmbeddings?.first?.speaker }
        }
        XCTAssertEqual(labels, ["Alice", "Alice", "Alice"])
    }

    func testPendingImportedSamplesNeverDriveRetro() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            let tid = try self.insertTranscript(
                conn, utterances: [TranscriptUtterance(idx: 0, startSec: 0, endSec: 1, speaker: "Speaker 1", text: "hi")],
                speakersJSON: #"[{"speaker":"Speaker 1","embedding":[1,0]}]"#)
            let alice = try VoicePrintQueries.findOrCreate(conn, personKey: "alice@example.com", displayName: "Alice")
            var pending = VoiceSample(personID: try XCTUnwrap(alice.id), embedding: VoicePrintEmbedding.encode(self.v(1, 0)),
                                      modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                      origin: .imported, anchor: false, status: .pending)
            try VoiceSampleQueries.insert(conn, &pending)

            XCTAssertEqual(try VoiceRetroRelabeler.run(conn), 0)
            let speaker = try XCTUnwrap(MeetingTranscriptQueries.fetch(conn, id: tid)?.speakerEmbeddings?.first)
            XCTAssertEqual(speaker.speaker, "Speaker 1", "an only-pending sample never names a cluster")
        }
    }

    /// N2: retro scores the pending imports too, so a voice an import claims
    /// for someone else is never named from the local match alone — whatever
    /// its queue task's state. Once no import disputes it, a stale pending
    /// conflict task no longer holds it back: retro names it and the sweep
    /// closes the task.
    func testDisputedVoiceIsNeverRelabeledAndAStaleConflictTaskDoesNotBlock() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            let tid = try self.insertTranscript(
                conn, utterances: [TranscriptUtterance(idx: 0, startSec: 0, endSec: 1, speaker: "Speaker 1", text: "hi")],
                speakersJSON: #"[{"speaker":"Speaker 1","embedding":[1,0]}]"#)
            let alice = try VoicePrintQueries.findOrCreate(conn, personKey: "alice@example.com", displayName: "Alice")
            let bob = try VoicePrintQueries.findOrCreate(conn, personKey: "bob@example.com", displayName: "Bob")
            var sample = VoiceSample(personID: try XCTUnwrap(alice.id), embedding: VoicePrintEmbedding.encode(self.v(1, 0)),
                                     modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                     origin: .owner, anchor: true, status: .active)
            try VoiceSampleQueries.insert(conn, &sample)
            var claim = VoiceSample(personID: try XCTUnwrap(bob.id), embedding: VoicePrintEmbedding.encode(self.v(1, 0.1)),
                                    modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                    origin: .imported, anchor: false, status: .pending)
            try VoiceSampleQueries.insert(conn, &claim)
            try VoiceLabelQueueQueries.enqueue(conn, transcriptID: tid, clusterLabel: "Speaker 1", reason: .conflict,
                                               suggestedPersonID: alice.id, score: 1)

            XCTAssertEqual(try VoiceRetroRelabeler.run(conn), 0, "the import disputes the voice")
            XCTAssertEqual(try MeetingTranscriptQueries.fetch(conn, id: tid)?.speakerEmbeddings?.first?.speaker, "Speaker 1")

            // The dispute is settled elsewhere (the claim retired) — the
            // leftover task must not block retro forever.
            try VoiceSampleQueries.retire(conn, id: try XCTUnwrap(claim.id))
            XCTAssertEqual(try VoiceRetroRelabeler.run(conn), 1)
            XCTAssertEqual(try MeetingTranscriptQueries.fetch(conn, id: tid)?.speakerEmbeddings?.first?.speaker, "Alice")
            XCTAssertEqual(try VoiceLabelQueueQueries.pendingCount(conn), 0, "the stale task closes")
        }
    }

    func testUninvitedPersonIsNotAppliedRetroactively() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            try TestDatabase.insertCalendarEvent(
                conn, id: "evt_1", organizerEmail: "dave@example.com",
                attendees: #"[{"email":"charlie@example.com","display_name":"Charlie","response_status":"accepted","slack_user_id":""}]"#)
            let tid = try self.insertTranscript(
                conn, utterances: [TranscriptUtterance(idx: 0, startSec: 0, endSec: 1, speaker: "Speaker 1", text: "hi")],
                speakersJSON: #"[{"speaker":"Speaker 1","embedding":[1,0]}]"#, eventID: "evt_1")
            let alice = try VoicePrintQueries.findOrCreate(conn, personKey: "alice@example.com", displayName: "Alice")
            var sample = VoiceSample(personID: try XCTUnwrap(alice.id), embedding: VoicePrintEmbedding.encode(self.v(1, 0)),
                                     modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                     origin: .owner, anchor: true, status: .active)
            try VoiceSampleQueries.insert(conn, &sample)

            XCTAssertEqual(try VoiceRetroRelabeler.run(conn), 0, "Alice wasn't invited to evt_1")
            let speaker = try XCTUnwrap(MeetingTranscriptQueries.fetch(conn, id: tid)?.speakerEmbeddings?.first)
            XCTAssertEqual(speaker.speaker, "Speaker 1")
        }
    }

    func testMixedClusterIsSkipped() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            let tid = try self.insertTranscript(
                conn, utterances: [TranscriptUtterance(idx: 0, startSec: 0, endSec: 1, speaker: "Speaker 1", text: "hi")],
                speakersJSON: #"[{"speaker":"Speaker 1","embedding":[1,0],"mixed":true}]"#)
            let alice = try VoicePrintQueries.findOrCreate(conn, personKey: "alice@example.com", displayName: "Alice")
            var sample = VoiceSample(personID: try XCTUnwrap(alice.id), embedding: VoicePrintEmbedding.encode(self.v(1, 0)),
                                     modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                     origin: .owner, anchor: true, status: .active)
            try VoiceSampleQueries.insert(conn, &sample)

            XCTAssertEqual(try VoiceRetroRelabeler.run(conn), 0, "a mixed cluster is never relabeled again")
            let speaker = try XCTUnwrap(MeetingTranscriptQueries.fetch(conn, id: tid)?.speakerEmbeddings?.first)
            XCTAssertEqual(speaker.speaker, "Speaker 1")
        }
    }

    func testIdempotent() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            _ = try self.insertTranscript(
                conn, utterances: [TranscriptUtterance(idx: 0, startSec: 0, endSec: 1, speaker: "Speaker 1", text: "hi")],
                speakersJSON: #"[{"speaker":"Speaker 1","embedding":[1,0]}]"#)
            let alice = try VoicePrintQueries.findOrCreate(conn, personKey: "alice@example.com", displayName: "Alice")
            var sample = VoiceSample(personID: try XCTUnwrap(alice.id), embedding: VoicePrintEmbedding.encode(self.v(1, 0)),
                                     modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                     origin: .owner, anchor: true, status: .active)
            try VoiceSampleQueries.insert(conn, &sample)

            XCTAssertEqual(try VoiceRetroRelabeler.run(conn), 1)
            XCTAssertEqual(try VoiceRetroRelabeler.run(conn), 0, "already-named cluster is never relabeled twice")
        }
    }
}
