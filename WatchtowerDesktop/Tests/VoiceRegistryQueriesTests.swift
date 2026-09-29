import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

final class VoiceRegistryQueriesTests: XCTestCase {
    private func v(_ x: Float, _ y: Float) -> Data { VoicePrintEmbedding.encode([x, y]) }

    private let twoSpeakerUtterances = [
        TranscriptUtterance(idx: 0, startSec: 0, endSec: 1, speaker: "Speaker 1", text: "привет"),
        TranscriptUtterance(idx: 1, startSec: 1, endSec: 2, speaker: "Speaker 2", text: "ответ")
    ]

    /// Inserts a two-speaker segmented transcript and returns its id.
    private func insertTranscript(_ db: Database, speakersJSON: String? = nil, audioPath: String? = nil) throws -> Int64 {
        try TestDatabase.insertMeetingTranscript(
            db, audioPath: audioPath,
            transcriptText: TranscriptSegments.render(twoSpeakerUtterances),
            segmentsJSON: try XCTUnwrap(TranscriptSegments.encode(twoSpeakerUtterances)),
            speakersJSON: speakersJSON)
        return db.lastInsertedRowID
    }

    private func autoSample(person: Int64, channel: VoiceChannel, _ y: Float) -> VoiceSample {
        VoiceSample(personID: person, embedding: v(1, y), modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                    origin: .auto, anchor: false, status: .active, channel: channel)
    }

    func testInsertAutoRetiresOldestBeyondCapPerChannel() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            let p = try VoicePrintQueries.findOrCreate(conn, personKey: "alice@example.com", displayName: "Alice")
            let pid = try XCTUnwrap(p.id)
            var firstIDs: [Int64] = []
            for i in 0..<(VoiceRegistryPolicy.autoCapPerChannel + 2) {
                let id = try VoiceSampleQueries.insertAuto(conn, self.autoSample(person: pid, channel: .remote, Float(i)))
                if i < 2 { firstIDs.append(id) }
            }
            // A room-channel sample and an anchor are outside the remote cap.
            _ = try VoiceSampleQueries.insertAuto(conn, self.autoSample(person: pid, channel: .room, 0))
            var anchor = VoiceSample(personID: pid, embedding: self.v(0, 1),
                                     modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                     origin: .owner, anchor: true, status: .active, channel: .remote)
            try VoiceSampleQueries.insert(conn, &anchor)

            let activeRemoteAuto = try VoiceSample
                .filter(Column("person_id") == pid && Column("status") == "active"
                    && Column("origin") == "auto" && Column("channel") == "remote")
                .fetchCount(conn)
            XCTAssertEqual(activeRemoteAuto, VoiceRegistryPolicy.autoCapPerChannel)
            let retired = try VoiceSample.filter(Column("status") == "retired").fetchAll(conn)
            XCTAssertEqual(Set(retired.compactMap(\.id)), Set(firstIDs), "the oldest two retire")
            XCTAssertEqual(try VoiceSampleQueries.anchors(conn, personID: pid).count, 1)
        }
    }

    func testFindOrCreateNeverRenamesExistingPerson() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            let first = try VoicePrintQueries.findOrCreate(conn, personKey: " Alice@Example.com ", displayName: "Alice")
            XCTAssertEqual(first.personKey, "alice@example.com")
            XCTAssertFalse(try XCTUnwrap(VoicePrintQueries.fetch(conn, id: try XCTUnwrap(first.id))).createdAt.isEmpty,
                           "the column default stamps created_at")
            let again = try VoicePrintQueries.findOrCreate(conn, personKey: "alice@example.com", displayName: "A. Imported")
            XCTAssertEqual(again.displayName, "Alice")
            XCTAssertEqual(again.id, first.id)
            XCTAssertEqual(try VoicePrint.fetchCount(conn), 1)
        }
    }

    func testFetchUsableKeepsActiveAndPendingOfCurrentModel() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            let pid = try XCTUnwrap(VoicePrintQueries.findOrCreate(conn, personKey: "a", displayName: "A").id)
            for (status, model) in [(VoiceSampleStatus.active, VoiceRegistryPolicy.embeddingModelVersion),
                                    (.pending, VoiceRegistryPolicy.embeddingModelVersion),
                                    (.retired, VoiceRegistryPolicy.embeddingModelVersion),
                                    (.active, "older-model")] {
                var s = VoiceSample(personID: pid, embedding: self.v(1, 0), modelVersion: model,
                                    origin: status == .pending ? .imported : .auto, anchor: false, status: status)
                try VoiceSampleQueries.insert(conn, &s)
            }
            let usable = try VoiceSampleQueries.fetchUsable(conn)
            XCTAssertEqual(usable.map(\.status).sorted { $0.rawValue < $1.rawValue }, [.active, .pending])
            XCTAssertTrue(usable.allSatisfy { $0.createdAt?.isEmpty == false })
        }
    }

    func testActivatePendingScopesToImport() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            let pid = try XCTUnwrap(VoicePrintQueries.findOrCreate(conn, personKey: "a", displayName: "A").id)
            var imp1 = VoiceImport(senderName: "Colleague A", fileSHA256: "sha-1", peopleCount: 1, sampleCount: 1,
                                   modelVersion: VoiceRegistryPolicy.embeddingModelVersion)
            var imp2 = VoiceImport(senderName: "Colleague B", fileSHA256: "sha-2", peopleCount: 1, sampleCount: 1,
                                   modelVersion: VoiceRegistryPolicy.embeddingModelVersion)
            try imp1.insert(conn)
            try imp2.insert(conn)
            for imp in [imp1, imp2] {
                var s = VoiceSample(personID: pid, embedding: self.v(1, 0),
                                    modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                    origin: .imported, anchor: false, status: .pending, importID: imp.id)
                try VoiceSampleQueries.insert(conn, &s)
            }
            try VoiceSampleQueries.activatePending(conn, personID: pid, importID: imp1.id)
            let byImport = Dictionary(uniqueKeysWithValues: try VoiceSample.fetchAll(conn).map { ($0.importID, $0.status) })
            XCTAssertEqual(byImport[imp1.id], .active)
            XCTAssertEqual(byImport[imp2.id], .pending)

            XCTAssertEqual(try VoiceImportQueries.fetchAll(conn).count, 2)
            try VoiceImportQueries.delete(conn, id: try XCTUnwrap(imp2.id))
            XCTAssertEqual(try VoiceSample.fetchCount(conn), 1, "an import's samples cascade with it")
            XCTAssertEqual(try VoiceSampleQueries.fetchByPerson(conn)[pid]?.count, 1)
        }
    }

    func testEnqueueIsIdempotentWhileOpen() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            let tid = try self.insertTranscript(conn)
            try VoiceLabelQueueQueries.enqueue(conn, transcriptID: tid, clusterLabel: "Speaker 1", reason: .unknown,
                                               suggestedPersonID: nil, score: nil)
            try VoiceLabelQueueQueries.enqueue(conn, transcriptID: tid, clusterLabel: "Speaker 1", reason: .unsure,
                                               suggestedPersonID: nil, score: 0.6)
            XCTAssertEqual(try VoiceLabelQueueQueries.pendingCount(conn), 1)
            let task = try XCTUnwrap(VoiceLabelQueueQueries.pending(conn, transcriptID: tid).first)
            XCTAssertEqual(task.reason, .unknown, "the open task is kept, the duplicate ignored")

            // Once closed, the same cluster may be queued again.
            try VoiceLabelQueueQueries.close(conn, id: try XCTUnwrap(task.id), status: .done)
            XCTAssertEqual(try VoiceLabelQueueQueries.pendingCount(conn), 0)
            try VoiceLabelQueueQueries.enqueue(conn, transcriptID: tid, clusterLabel: "Speaker 1", reason: .relabel,
                                               suggestedPersonID: nil, score: nil)
            XCTAssertEqual(try VoiceLabelQueueQueries.pending(conn).map(\.reason), [.relabel])
            let closed = try XCTUnwrap(VoiceLabelTask.fetchOne(conn, key: task.id))
            XCTAssertEqual(closed.status, .done)
            XCTAssertNotNil(closed.resolvedAt)
        }
    }

    func testSkipTasksWithoutAudio() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            let withAudio = try self.insertTranscript(conn, audioPath: "/recordings/rec_a.caf")
            let gone = try self.insertTranscript(conn, audioPath: "/recordings/rec_gone.caf")
            let swept = try self.insertTranscript(conn, audioPath: nil)
            for tid in [withAudio, gone, swept] {
                try VoiceLabelQueueQueries.enqueue(conn, transcriptID: tid, clusterLabel: "Speaker 1", reason: .unknown,
                                                   suggestedPersonID: nil, score: nil)
            }
            let skipped = try VoiceLabelQueueQueries.skipTasksWithoutAudio(conn) { $0 == "/recordings/rec_a.caf" }
            XCTAssertEqual(skipped, 2)
            XCTAssertEqual(try VoiceLabelQueueQueries.pending(conn).map(\.transcriptID), [withAudio])
        }
    }

    /// Spec §3.1 "voice recognized meanwhile ⇒ task auto-closes".
    func testCloseResolvedTasksClosesNamedAndVanishedButKeepsUnnamedAndRelabel() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            // Speaker 1: named since it was queued (auto, via retro). Speaker 2: still unnamed.
            let named = try self.insertTranscript(conn, speakersJSON: #"""
                [{"speaker":"Alice","original_label":"Speaker 1","embedding":[1,0],"label_source":"auto"},
                 {"speaker":"Speaker 2","embedding":[0,1]}]
                """#)
            // A relabel task on a named cluster, plus a task whose cluster no longer exists at all.
            let relabel = try self.insertTranscript(conn, speakersJSON: #"""
                [{"speaker":"Bob","embedding":[1,0],"label_source":"owner"}]
                """#)
            for (tid, label, reason) in [(named, "Speaker 1", VoiceLabelReason.unknown), (named, "Speaker 2", .unknown),
                                         (relabel, "Bob", .relabel), (relabel, "Speaker 9", .unsure)] {
                try VoiceLabelQueueQueries.enqueue(conn, transcriptID: tid, clusterLabel: label, reason: reason,
                                                   suggestedPersonID: nil, score: nil)
            }

            XCTAssertEqual(try VoiceLabelQueueQueries.closeResolvedTasks(conn), 2)
            let open = try VoiceLabelQueueQueries.pending(conn).map { "\($0.transcriptID):\($0.clusterLabel)" }
            XCTAssertEqual(Set(open), ["\(named):Speaker 2", "\(relabel):Bob"])
            let statuses = try Row.fetchAll(conn, sql: "SELECT cluster_label, status FROM voice_label_queue")
                .reduce(into: [String: String]()) { $0[$1["cluster_label"]] = $1["status"] }
            XCTAssertEqual(statuses["Speaker 1"], "done", "named meanwhile")
            XCTAssertEqual(statuses["Speaker 9"], "skipped", "cluster gone")
        }
    }

    func testRelabelClusterPatchesSpeakersJSONAndStampsChange() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            let tid = try self.insertTranscript(conn, speakersJSON: #"[{"speaker":"Speaker 1","embedding":[1,0]}]"#)
            XCTAssertTrue(try MeetingTranscriptQueries.relabelCluster(conn, id: tid, from: "Speaker 1", to: "Alice") {
                $0.labelSource = .owner
                $0.personID = 7
                $0.originalLabel = $0.originalLabel ?? "Speaker 1"
            })
            let t = try XCTUnwrap(MeetingTranscriptQueries.fetch(conn, id: tid))
            let s = try XCTUnwrap(t.speakerEmbeddings?.first)
            XCTAssertEqual(s.speaker, "Alice")
            XCTAssertEqual(s.labelSource, .owner)
            XCTAssertEqual(s.personID, 7)
            XCTAssertEqual(s.originalLabel, "Speaker 1")
            XCTAssertNotNil(try String.fetchOne(
                conn, sql: "SELECT speaker_names_changed_at FROM meeting_transcripts WHERE id = ?", arguments: [tid]))
            XCTAssertFalse(t.transcriptText.contains("Speaker 1"))
        }
    }

    func testPersonIDsMatchByEmailOrDisplayName() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            let a = try VoicePrintQueries.findOrCreate(conn, personKey: "alice@example.com", displayName: "Alice")
            let b = try VoicePrintQueries.findOrCreate(conn, personKey: "colleague a", displayName: "Colleague A")
            _ = try VoicePrintQueries.findOrCreate(conn, personKey: "stranger@example.com", displayName: "Stranger")
            let att = [EventAttendee(email: "ALICE@example.com", displayName: "", responseStatus: "accepted", slackUserID: ""),
                       EventAttendee(email: "", displayName: "colleague a", responseStatus: "accepted", slackUserID: "")]
            XCTAssertEqual(try VoicePrintQueries.personIDs(conn, matching: att), [try XCTUnwrap(a.id), try XCTUnwrap(b.id)])
            // A room row with empty fields admits nobody.
            let room = [EventAttendee(email: "", displayName: "", responseStatus: "accepted", slackUserID: "")]
            XCTAssertEqual(try VoicePrintQueries.personIDs(conn, matching: room), [])
        }
    }

    func testIsOwnerNormalizesBothSides() {
        let owner = VoicePrint(personKey: "owner@example.com", displayName: "Owner")
        XCTAssertTrue(VoicePrintQueries.isOwner(owner, ownerEmails: ["Owner@Example.com "]))
        XCTAssertFalse(VoicePrintQueries.isOwner(VoicePrint(personKey: "owner", displayName: "owner"),
                                                 ownerEmails: ["owner@example.com"]),
                       "a name-keyed person is never recognizable as the owner")
        XCTAssertFalse(VoicePrintQueries.isOwner(owner, ownerEmails: []))
    }
}
