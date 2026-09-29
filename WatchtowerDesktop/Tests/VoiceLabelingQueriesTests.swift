import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

final class VoiceLabelingQueriesTests: XCTestCase {
    private func v(_ x: Float, _ y: Float) -> Data { VoicePrintEmbedding.encode([x, y]) }

    private let twoSpeakerUtterances = [
        TranscriptUtterance(idx: 0, startSec: 0, endSec: 1, speaker: "Speaker 1", text: "привет"),
        TranscriptUtterance(idx: 1, startSec: 1, endSec: 2, speaker: "Speaker 2", text: "ответ")
    ]

    /// Inserts a two-speaker segmented transcript and returns its id.
    private func insertTranscript(_ db: Database, speakersJSON: String? = nil) throws -> Int64 {
        try TestDatabase.insertMeetingTranscript(
            db,
            transcriptText: TranscriptSegments.render(twoSpeakerUtterances),
            segmentsJSON: try XCTUnwrap(TranscriptSegments.encode(twoSpeakerUtterances)),
            speakersJSON: speakersJSON)
        return db.lastInsertedRowID
    }

    func testConfirmRelabelsAddsAnchorAndClosesTask() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            let tid = try self.insertTranscript(
                conn, speakersJSON: #"[{"speaker":"Speaker 1","embedding":[1,0],"channel":"remote","speech_sec":40}]"#)
            try VoiceLabelQueueQueries.enqueue(conn, transcriptID: tid, clusterLabel: "Speaker 1", reason: .unknown,
                                               suggestedPersonID: nil, score: nil)
            let task = try XCTUnwrap(VoiceLabelQueueQueries.pending(conn, transcriptID: tid).first)

            let result = try VoiceLabelingQueries.confirm(
                conn, taskID: task.id, transcriptID: tid, clusterLabel: "Speaker 1",
                personKey: "alice@example.com", displayName: "Alice")
            guard case let .labeled(pid) = result else { return XCTFail("expected .labeled, got \(result)") }

            let anchors = try VoiceSampleQueries.anchors(conn, personID: pid)
            XCTAssertEqual(anchors.count, 1)
            XCTAssertEqual(anchors[0].channel, .remote)
            XCTAssertEqual(anchors[0].transcriptID, tid)
            XCTAssertEqual(try VoiceLabelQueueQueries.pendingCount(conn), 0)

            let speaker = try XCTUnwrap(MeetingTranscriptQueries.fetch(conn, id: tid)?.speakerEmbeddings?.first)
            XCTAssertEqual(speaker.speaker, "Alice")
            XCTAssertEqual(speaker.labelSource, .owner)
            XCTAssertEqual(speaker.personID, pid)
        }
    }

    /// A diarization over-split: two cards of one meeting both confirmed as
    /// Bob. The second must be refused — never two clusters under one label.
    func testConfirmIntoANameAnotherClusterAlreadyCarriesIsRefused() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            let tid = try self.insertTranscript(conn, speakersJSON: #"""
                [{"speaker":"Speaker 1","embedding":[1,0]},{"speaker":"Speaker 2","embedding":[0.9,0.1]}]
                """#)
            for label in ["Speaker 1", "Speaker 2"] {
                try VoiceLabelQueueQueries.enqueue(conn, transcriptID: tid, clusterLabel: label, reason: .unknown,
                                                   suggestedPersonID: nil, score: nil)
            }
            let tasks = try VoiceLabelQueueQueries.pending(conn, transcriptID: tid)
            let first = try XCTUnwrap(tasks.first { $0.clusterLabel == "Speaker 1" })
            let second = try XCTUnwrap(tasks.first { $0.clusterLabel == "Speaker 2" })

            guard case .labeled = try VoiceLabelingQueries.confirm(
                conn, taskID: first.id, transcriptID: tid, clusterLabel: "Speaker 1",
                personKey: "bob@example.com", displayName: "Bob") else { return XCTFail("first confirm must label") }
            let samplesBefore = try VoiceSample.fetchCount(conn)

            let result = try VoiceLabelingQueries.confirm(
                conn, taskID: second.id, transcriptID: tid, clusterLabel: "Speaker 2",
                personKey: "BOB@example.com", displayName: "Robert")
            XCTAssertEqual(result, .nameTaken(name: "Bob"), "the existing person's display name is what would collide")

            let labels = try XCTUnwrap(MeetingTranscriptQueries.fetch(conn, id: tid)?.speakerEmbeddings).map(\.speaker)
            XCTAssertEqual(labels.sorted(), ["Bob", "Speaker 2"], "the second cluster keeps its own label")
            XCTAssertEqual(try VoiceSample.fetchCount(conn), samplesBefore, "no anchor minted")
            XCTAssertEqual(try VoiceLabelQueueQueries.pending(conn).map(\.id), [second.id], "the task stays open")
        }
    }

    func testConfirmOnStaleTaskReportsAlreadyLabeledWithoutWriting() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            let tid = try self.insertTranscript(conn, speakersJSON: #"[{"speaker":"Speaker 1","embedding":[1,0]}]"#)
            try VoiceLabelQueueQueries.enqueue(conn, transcriptID: tid, clusterLabel: "Speaker 1", reason: .unknown,
                                               suggestedPersonID: nil, score: nil)
            // Something else (another task, a concurrent confirm) already relabeled the cluster.
            _ = try MeetingTranscriptQueries.relabelCluster(conn, id: tid, from: "Speaker 1", to: "Bob") { $0.labelSource = .auto }
            let task = try XCTUnwrap(VoiceLabelQueueQueries.pending(conn, transcriptID: tid).first)

            let result = try VoiceLabelingQueries.confirm(
                conn, taskID: task.id, transcriptID: tid, clusterLabel: "Speaker 1",
                personKey: "alice@example.com", displayName: "Alice")
            XCTAssertEqual(result, .alreadyLabeled)
            XCTAssertEqual(try VoicePrint.fetchCount(conn), 0, "no person is minted for a stale confirm")
            XCTAssertEqual(try VoiceLabelQueueQueries.pendingCount(conn), 0, "the stale task still closes")
        }
    }

    func testImportConfirmActivatesPendingSamplesOfThatPerson() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            let alice = try VoicePrintQueries.findOrCreate(conn, personKey: "alice@example.com", displayName: "Alice")
            let aliceID = try XCTUnwrap(alice.id)

            var senderA = VoiceImport(senderName: "Colleague A", fileSHA256: "sha-a", peopleCount: 1, sampleCount: 1,
                                      modelVersion: VoiceRegistryPolicy.embeddingModelVersion)
            var senderB = VoiceImport(senderName: "Colleague B", fileSHA256: "sha-b", peopleCount: 1, sampleCount: 1,
                                      modelVersion: VoiceRegistryPolicy.embeddingModelVersion)
            try senderA.insert(conn)
            try senderB.insert(conn)

            // Sender A's pending sample sits right on the cluster embedding; sender B's is far off.
            var sampleA = VoiceSample(personID: aliceID, embedding: self.v(1, 0),
                                      modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                      origin: .imported, anchor: false, status: .pending, importID: senderA.id)
            var sampleB = VoiceSample(personID: aliceID, embedding: self.v(0, 1),
                                      modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                      origin: .imported, anchor: false, status: .pending, importID: senderB.id)
            try VoiceSampleQueries.insert(conn, &sampleA)
            try VoiceSampleQueries.insert(conn, &sampleB)

            let tid = try self.insertTranscript(conn, speakersJSON: #"[{"speaker":"Speaker 1","embedding":[1,0]}]"#)
            try VoiceLabelQueueQueries.enqueue(conn, transcriptID: tid, clusterLabel: "Speaker 1", reason: .importConfirm,
                                               suggestedPersonID: aliceID, score: 0.8)
            let task = try XCTUnwrap(VoiceLabelQueueQueries.pending(conn, transcriptID: tid).first)

            let result = try VoiceLabelingQueries.confirm(
                conn, taskID: task.id, transcriptID: tid, clusterLabel: "Speaker 1",
                personKey: "alice@example.com", displayName: "Alice")
            XCTAssertEqual(result, .labeled(personID: aliceID))

            let importedSamples = try VoiceSample.filter(Column("import_id") != nil).fetchAll(conn)
            let byImport = Dictionary(uniqueKeysWithValues: importedSamples.map { ($0.importID, $0.status) })
            XCTAssertEqual(byImport[senderA.id], .active, "the nearest sender's pending sample is activated")
            XCTAssertEqual(byImport[senderB.id], .pending, "a different sender's pending sample is untouched")
        }
    }

    private struct ImportConflict {
        let aliceID: Int64
        let bobID: Int64
        /// Alice's owner anchor on the disputed voice.
        let anchorID: Int64
        /// Bob's pending imported sample that claims the voice.
        let claimID: Int64
        let transcriptID: Int64
        let task: VoiceLabelTask
    }

    /// Seeds N3's dispute: Alice holds an active anchor on [1,0], and a
    /// colleague's import claims the same voice (cos ≈ 0.995) is Bob. A
    /// fresh "Speaker 1" cluster on [1,0] carries the `.conflict` task the
    /// save queued for it.
    private func seedImportConflict(_ conn: Database) throws -> ImportConflict {
        let alice = try VoicePrintQueries.findOrCreate(conn, personKey: "alice@example.com", displayName: "Alice")
        let bob = try VoicePrintQueries.findOrCreate(conn, personKey: "bob@example.com", displayName: "Bob")
        let aliceID = try XCTUnwrap(alice.id)
        let bobID = try XCTUnwrap(bob.id)
        var anchor = VoiceSample(personID: aliceID, embedding: self.v(1, 0),
                                 modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                 origin: .owner, anchor: true, status: .active)
        try VoiceSampleQueries.insert(conn, &anchor)
        var sender = VoiceImport(senderName: "Colleague A", fileSHA256: "sha-a", peopleCount: 1, sampleCount: 1,
                                 modelVersion: VoiceRegistryPolicy.embeddingModelVersion)
        try sender.insert(conn)
        var claim = VoiceSample(personID: bobID, embedding: self.v(1, 0.1),
                                modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                origin: .imported, anchor: false, status: .pending, importID: sender.id)
        try VoiceSampleQueries.insert(conn, &claim)

        let tid = try self.insertTranscript(conn, speakersJSON: #"[{"speaker":"Speaker 1","embedding":[1,0],"speech_sec":40}]"#)
        let before = VoiceMatcher.decide(clusters: [.init(label: "Speaker 1", embedding: [1, 0], speechSec: 40)],
                                         samples: try VoiceSampleQueries.fetchUsable(conn), invited: nil, ownerPersonIDs: [])
        XCTAssertEqual(before["Speaker 1"], .unsure(personID: aliceID, score: 1, reason: .conflict), "fixture is a dispute")
        try VoiceLabelQueueQueries.enqueue(conn, transcriptID: tid, clusterLabel: "Speaker 1", reason: .conflict,
                                           suggestedPersonID: aliceID, score: 1)
        let task = try XCTUnwrap(VoiceLabelQueueQueries.pending(conn, transcriptID: tid).first)
        return ImportConflict(aliceID: aliceID, bobID: bobID, anchorID: try XCTUnwrap(anchor.id),
                              claimID: try XCTUnwrap(claim.id),
                              transcriptID: tid, task: task)
    }

    /// N3: confirming the local person on a conflict card retires the import
    /// that claimed the voice for someone else, so the next meeting with that
    /// voice is not re-disputed — it auto-labels confidently again.
    func testConfirmingAConflictRetiresTheContradictingImportSoTheVoiceAutoLabelsAgain() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            let f = try self.seedImportConflict(conn)
            let (aliceID, claimID, tid, task) = (f.aliceID, f.claimID, f.transcriptID, f.task)

            let result = try VoiceLabelingQueries.confirm(
                conn, taskID: task.id, transcriptID: tid, clusterLabel: "Speaker 1",
                personKey: "alice@example.com", displayName: "Alice")
            XCTAssertEqual(result, .labeled(personID: aliceID))
            XCTAssertEqual(try VoiceSample.fetchOne(conn, key: claimID)?.status, .retired,
                           "the owner's choice ends the dispute")

            // The next meeting with the same voice.
            let next = VoiceMatcher.decide(clusters: [.init(label: "Speaker 1", embedding: [1, 0.02], speechSec: 40)],
                                           samples: try VoiceSampleQueries.fetchUsable(conn), invited: nil,
                                           ownerPersonIDs: [])
            guard case let .confident(personID, _, _) = next["Speaker 1"] else {
                return XCTFail("the voice must auto-label again, got \(String(describing: next["Speaker 1"]))")
            }
            XCTAssertEqual(personID, aliceID)
        }
    }

    /// N3, the other side: confirming the IMPORTED person on a conflict card
    /// activates that sender's samples, as an import confirmation does, and
    /// the owner's newest confirm wins for that voice — Alice's anchor on it
    /// retires, so the next meeting is confident for Bob instead of stuck
    /// within the margin between the two.
    func testConfirmingTheImportedPersonOnAConflictMakesTheVoiceTheirs() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            let f = try self.seedImportConflict(conn)

            let result = try VoiceLabelingQueries.confirm(
                conn, taskID: f.task.id, transcriptID: f.transcriptID, clusterLabel: "Speaker 1",
                personKey: "bob@example.com", displayName: "Bob")
            XCTAssertEqual(result, .labeled(personID: f.bobID))
            XCTAssertEqual(try VoiceSample.fetchOne(conn, key: f.claimID)?.status, .active)
            XCTAssertEqual(try VoiceSample.fetchOne(conn, key: f.anchorID)?.status, .retired,
                           "the other person's anchor on this voice retires")
            XCTAssertEqual(try VoiceLabelQueueQueries.pendingCount(conn), 0)

            let next = VoiceMatcher.decide(clusters: [.init(label: "Speaker 1", embedding: [1, 0.02], speechSec: 40)],
                                           samples: try VoiceSampleQueries.fetchUsable(conn), invited: nil,
                                           ownerPersonIDs: [])
            guard case let .confident(personID, _, _) = next["Speaker 1"] else {
                return XCTFail("the next meeting must be confident, got \(String(describing: next["Speaker 1"]))")
            }
            XCTAssertEqual(personID, f.bobID)
        }
    }

    /// Retiring the other person's samples re-matches what depended on them:
    /// an earlier recording auto-labeled Alice off her now-retired anchor
    /// reverts, since the voice now confidently belongs to Bob.
    func testConfirmRematchesAutoLabelsThatDependedOnARetiredContradictingSample() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            let f = try self.seedImportConflict(conn)
            let named = [TranscriptUtterance(idx: 0, startSec: 0, endSec: 1, speaker: "Alice", text: "hi")]
            try TestDatabase.insertMeetingTranscript(
                conn, transcriptText: TranscriptSegments.render(named),
                segmentsJSON: try XCTUnwrap(TranscriptSegments.encode(named)),
                speakersJSON: #"""
                    [{"speaker":"Alice","embedding":[1,0],"original_label":"Speaker 1","person_id":\#(f.aliceID),
                      "label_source":"auto","matched_sample_id":\#(f.anchorID),"score":1}]
                    """#)
            let dependent = conn.lastInsertedRowID

            _ = try VoiceLabelingQueries.confirm(
                conn, taskID: f.task.id, transcriptID: f.transcriptID, clusterLabel: "Speaker 1",
                personKey: "bob@example.com", displayName: "Bob")

            let cluster = try XCTUnwrap(MeetingTranscriptQueries.fetch(conn, id: dependent)?.speakerEmbeddings?.first)
            XCTAssertEqual(cluster.speaker, "Speaker 1", "no label keeps pointing at a retired sample")
            XCTAssertEqual(cluster.labelSource, VoiceLabelSource.none)
            XCTAssertNil(cluster.matchedSampleID)
        }
    }

    /// An import confirmation activates only an import that actually claimed
    /// the voice (≥ `confident`) — a far pending sample of the same person
    /// from an unrelated sender stays pending.
    func testImportConfirmLeavesAFarPendingSampleAlone() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            let alice = try VoicePrintQueries.findOrCreate(conn, personKey: "alice@example.com", displayName: "Alice")
            let aliceID = try XCTUnwrap(alice.id)
            var sender = VoiceImport(senderName: "Colleague A", fileSHA256: "sha-a", peopleCount: 1, sampleCount: 1,
                                     modelVersion: VoiceRegistryPolicy.embeddingModelVersion)
            try sender.insert(conn)
            var far = VoiceSample(personID: aliceID, embedding: self.v(0, 1),
                                  modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                  origin: .imported, anchor: false, status: .pending, importID: sender.id)
            try VoiceSampleQueries.insert(conn, &far)
            let tid = try self.insertTranscript(conn, speakersJSON: #"[{"speaker":"Speaker 1","embedding":[1,0]}]"#)
            try VoiceLabelQueueQueries.enqueue(conn, transcriptID: tid, clusterLabel: "Speaker 1", reason: .importConfirm,
                                               suggestedPersonID: aliceID, score: 0.8)
            let task = try XCTUnwrap(VoiceLabelQueueQueries.pending(conn, transcriptID: tid).first)

            _ = try VoiceLabelingQueries.confirm(
                conn, taskID: task.id, transcriptID: tid, clusterLabel: "Speaker 1",
                personKey: "alice@example.com", displayName: "Alice")
            XCTAssertEqual(try VoiceSample.fetchOne(conn, key: try XCTUnwrap(far.id))?.status, .pending)
        }
    }

    /// The owner's own voice is exempt from "newest confirm wins": naming
    /// colleague Bob on a voice ≥ `importConflict` to the owner's anchor
    /// leaves that anchor active, so the «Я» detection stays armed.
    func testConfirmingAColleagueNeverRetiresTheOwnersAnchor() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            _ = try TestDatabase.insertGoogleAccount(conn, email: "Owner@Example.com")
            let owner = try VoicePrintQueries.findOrCreate(conn, personKey: "owner@example.com", displayName: "Owner")
            let ownerID = try XCTUnwrap(owner.id)
            var ownerAnchor = VoiceSample(personID: ownerID, embedding: self.v(1, 0.1),
                                          modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                          origin: .owner, anchor: true, status: .active)
            try VoiceSampleQueries.insert(conn, &ownerAnchor)
            let tid = try self.insertTranscript(conn, speakersJSON: #"[{"speaker":"Speaker 1","embedding":[1,0]}]"#)

            let result = try VoiceLabelingQueries.confirm(
                conn, taskID: nil, transcriptID: tid, clusterLabel: "Speaker 1",
                personKey: "bob@example.com", displayName: "Bob")
            guard case .labeled = result else { return XCTFail("expected .labeled, got \(result)") }

            XCTAssertEqual(try VoiceSample.fetchOne(conn, key: try XCTUnwrap(ownerAnchor.id))?.status, .active,
                           "the owner's anchor is never retired by a colleague's confirm")
            let snapshot = try AppState.loadVoiceRegistry(conn, eventID: nil)
            XCTAssertEqual(snapshot.ownerPersonIDs, [ownerID])
            XCTAssertTrue(snapshot.samples.contains {
                $0.personID == ownerID && $0.anchor && $0.status == .active
            }, "an active owner anchor keeps the «Я» detection armed")
        }
    }

    func testOwnerCannotBeAssignedAsReservedLabel() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            let tid = try self.insertTranscript(conn, speakersJSON: #"[{"speaker":"Speaker 1","embedding":[1,0]}]"#)
            try VoiceLabelQueueQueries.enqueue(conn, transcriptID: tid, clusterLabel: "Speaker 1", reason: .unknown,
                                               suggestedPersonID: nil, score: nil)
            let task = try XCTUnwrap(VoiceLabelQueueQueries.pending(conn, transcriptID: tid).first)

            let result = try VoiceLabelingQueries.confirm(
                conn, taskID: task.id, transcriptID: tid, clusterLabel: "Speaker 1",
                personKey: "me@example.com", displayName: "Я")
            XCTAssertEqual(result, .stale)
            XCTAssertEqual(try VoicePrint.fetchCount(conn), 0)
            XCTAssertEqual(try VoiceLabelQueueQueries.pendingCount(conn), 1, "nothing is written, the task stays pending")
        }
    }

    func testSeveralPeopleMarksClusterMixedAndNeverLearns() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            let tid = try self.insertTranscript(conn, speakersJSON: #"[{"speaker":"Speaker 1","embedding":[1,0]}]"#)
            try VoiceLabelQueueQueries.enqueue(conn, transcriptID: tid, clusterLabel: "Speaker 1", reason: .conflict,
                                               suggestedPersonID: nil, score: nil)
            let task = try XCTUnwrap(VoiceLabelQueueQueries.pending(conn, transcriptID: tid).first)

            try VoiceLabelingQueries.dismiss(conn, taskID: try XCTUnwrap(task.id), kind: .severalPeople)

            let speaker = try XCTUnwrap(MeetingTranscriptQueries.fetch(conn, id: tid)?.speakerEmbeddings?.first)
            XCTAssertEqual(speaker.speaker, "Speaker 1", "the label is kept, never overwritten")
            XCTAssertEqual(speaker.labelSource, .owner)
            XCTAssertEqual(speaker.mixed, true)
            XCTAssertEqual(try VoiceSample.fetchCount(conn), 0, "a mixed cluster is never learned from")
            let closed = try XCTUnwrap(VoiceLabelTask.fetchOne(conn, key: task.id))
            XCTAssertEqual(closed.status, .done)
        }
    }
}
