import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

final class VoiceRollbackTests: XCTestCase {
    private func v(_ x: Float, _ y: Float) -> Data { VoicePrintEmbedding.encode([x, y]) }

    /// Inserts a one-speaker segmented transcript whose current cluster label
    /// is "Alice" (matching the `speakersJSON` fixtures below, all of which
    /// describe an already-labeled cluster) and returns its id.
    private func insertTranscript(_ db: Database, speakersJSON: String, audioPath: String? = nil) throws -> Int64 {
        let utterances = [TranscriptUtterance(idx: 0, startSec: 0, endSec: 1, speaker: "Alice", text: "hi")]
        try TestDatabase.insertMeetingTranscript(
            db, audioPath: audioPath,
            transcriptText: TranscriptSegments.render(utterances),
            segmentsJSON: try XCTUnwrap(TranscriptSegments.encode(utterances)),
            speakersJSON: speakersJSON)
        return db.lastInsertedRowID
    }

    func testRejectRetiresMintedSampleAndRevertsDependents() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            let alice = try VoicePrintQueries.findOrCreate(conn, personKey: "alice@example.com", displayName: "Alice")
            let aliceID = try XCTUnwrap(alice.id)

            // Alice's owner anchor A0 — the only sample left once the minted
            // one below is retired.
            var anchor = VoiceSample(personID: aliceID, embedding: self.v(1, 0),
                                     modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                     origin: .owner, anchor: true, status: .active)
            try VoiceSampleQueries.insert(conn, &anchor)
            let anchorID = try XCTUnwrap(anchor.id)

            // A real file on disk so `rejectAutoLabel` sees T1's audio as
            // still present and enqueues a fresh `.relabel` task for it.
            let audioPath = NSTemporaryDirectory() + "voice_rollback_\(UUID().uuidString).caf"
            XCTAssertTrue(FileManager.default.createFile(atPath: audioPath, contents: Data()))
            defer { try? FileManager.default.removeItem(atPath: audioPath) }

            // T1 cluster X: "Speaker 1" auto-labeled "Alice", matched on the anchor A0.
            let t1 = try self.insertTranscript(
                conn, speakersJSON: #"""
                    [{"speaker":"Alice","embedding":[1,0],"original_label":"Speaker 1",
                      "person_id":\#(aliceID),"label_source":"auto","matched_sample_id":\#(anchorID),"score":0.9}]
                    """#,
                audioPath: audioPath)

            // The auto sample self-training minted from X's confident match.
            var mintedSample = VoiceSample(personID: aliceID, embedding: self.v(1, 0),
                                           modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                           origin: .auto, anchor: false, status: .active,
                                           transcriptID: t1, clusterLabel: "Speaker 1")
            try VoiceSampleQueries.insert(conn, &mintedSample)
            let mintedID = try XCTUnwrap(mintedSample.id)

            // T2 cluster Y: "Speaker 1" auto-labeled "Alice", matched ONLY on
            // the minted sample S1 — its embedding is orthogonal to the
            // anchor A0, so once S1 is retired Y no longer matches anyone.
            let t2 = try self.insertTranscript(
                conn, speakersJSON: #"""
                    [{"speaker":"Alice","embedding":[0,1],"original_label":"Speaker 1",
                      "person_id":\#(aliceID),"label_source":"auto","matched_sample_id":\#(mintedID),"score":0.95}]
                    """#)

            let reverted = try VoiceLabelingQueries.rejectAutoLabel(conn, transcriptID: t1, clusterLabel: "Alice")
            XCTAssertEqual(reverted, 2, "T1's own cluster plus T2's orphaned dependent")

            XCTAssertEqual(try VoiceSample.fetchOne(conn, key: mintedID)?.status, .retired, "the minted sample is retired")

            let x = try XCTUnwrap(MeetingTranscriptQueries.fetch(conn, id: t1)?.speakerEmbeddings?.first)
            XCTAssertEqual(x.speaker, "Speaker 1")
            XCTAssertEqual(x.labelSource, VoiceLabelSource.none)
            XCTAssertNil(x.personID)
            XCTAssertNil(x.matchedSampleID)
            XCTAssertNil(x.score)

            let y = try XCTUnwrap(MeetingTranscriptQueries.fetch(conn, id: t2)?.speakerEmbeddings?.first)
            XCTAssertEqual(y.speaker, "Speaker 1", "Y reverts too — it depended only on the now-retired S1")
            XCTAssertEqual(y.labelSource, VoiceLabelSource.none)
            XCTAssertNil(y.personID)
            XCTAssertNil(y.matchedSampleID)
            XCTAssertNil(y.score)

            let pending = try VoiceLabelQueueQueries.pending(conn)
            XCTAssertEqual(pending.count, 1, "only X (the transcript reject was called on) is re-enqueued")
            XCTAssertEqual(pending.first?.transcriptID, t1)
            XCTAssertEqual(pending.first?.clusterLabel, "Speaker 1")
            XCTAssertEqual(pending.first?.reason, .relabel)
        }
    }

    /// The owner's "Wrong" sticks: a launch retro must not re-apply the
    /// rejected person from their other samples (which still match), so the
    /// `.relabel` task stays open — until the owner names that same person
    /// by hand, which lifts the rejection.
    func testRejectedPersonIsNeverReappliedByRetroUntilConfirmedByHand() throws {
        let db = try TestDatabase.create()
        let audio = try TestFixtures.tempAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }
        try db.write { conn in
            let alice = try VoicePrintQueries.findOrCreate(conn, personKey: "alice@example.com", displayName: "Alice")
            let aliceID = try XCTUnwrap(alice.id)
            // An anchor from ANOTHER recording — it still matches after the reject.
            var anchor = VoiceSample(personID: aliceID, embedding: self.v(1, 0),
                                     modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                     origin: .owner, anchor: true, status: .active)
            try VoiceSampleQueries.insert(conn, &anchor)
            let t1 = try self.insertTranscript(
                conn, speakersJSON: #"""
                    [{"speaker":"Alice","embedding":[1,0],"original_label":"Speaker 1","speech_sec":40,
                      "person_id":\#(aliceID),"label_source":"auto","matched_sample_id":\#(try XCTUnwrap(anchor.id)),"score":1}]
                    """#,
                audioPath: audio.path)

            XCTAssertEqual(try VoiceLabelingQueries.rejectAutoLabel(conn, transcriptID: t1, clusterLabel: "Alice"), 1)
            let rejected = try XCTUnwrap(MeetingTranscriptQueries.fetch(conn, id: t1)?.speakerEmbeddings?.first)
            XCTAssertEqual(rejected.rejectedPersonIDs, [aliceID])

            XCTAssertEqual(try VoiceRetroRelabeler.run(conn), 0, "retro never re-applies the rejected person")
            let after = try XCTUnwrap(MeetingTranscriptQueries.fetch(conn, id: t1)?.speakerEmbeddings?.first)
            XCTAssertEqual(after.speaker, "Speaker 1")
            XCTAssertEqual(after.labelSource, VoiceLabelSource.none)
            let task = try XCTUnwrap(VoiceLabelQueueQueries.pending(conn, transcriptID: t1).first)
            XCTAssertEqual(task.reason, .relabel, "the owner's relabel task stays open")

            // The owner changes their mind and names it Alice by hand.
            let result = try VoiceLabelingQueries.confirm(
                conn, taskID: task.id, transcriptID: t1, clusterLabel: "Speaker 1",
                personKey: "alice@example.com", displayName: "Alice")
            XCTAssertEqual(result, .labeled(personID: aliceID))
            let named = try XCTUnwrap(MeetingTranscriptQueries.fetch(conn, id: t1)?.speakerEmbeddings?.first)
            XCTAssertEqual(named.speaker, "Alice")
            XCTAssertNil(named.rejectedPersonIDs, "a hand confirm of the same person lifts the rejection")
        }
    }

    /// The other half of `revertOrphanedAutoLabels`'s branch: a dependent
    /// cluster whose matched sample is removed but that STILL confidently
    /// matches another remaining active sample of the same person is
    /// re-pointed at it (`matchedSampleID`/`score` updated) rather than
    /// reverted — the label, `labelSource` and `personID` are untouched.
    func testRejectRepointsDependentThatStillMatchesAnotherActiveSample() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            let alice = try VoicePrintQueries.findOrCreate(conn, personKey: "alice@example.com", displayName: "Alice")
            let aliceID = try XCTUnwrap(alice.id)

            // Alice's anchor A0, plus a second active sample A1 that survives
            // the reject — the dependent below still matches Alice through
            // A1 once the minted sample S1 is retired.
            var anchor = VoiceSample(personID: aliceID, embedding: self.v(1, 0),
                                     modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                     origin: .owner, anchor: true, status: .active)
            try VoiceSampleQueries.insert(conn, &anchor)
            let anchorID = try XCTUnwrap(anchor.id)

            var other = VoiceSample(personID: aliceID, embedding: self.v(0.8, 0.6),
                                    modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                    origin: .auto, anchor: false, status: .active)
            try VoiceSampleQueries.insert(conn, &other)
            let otherID = try XCTUnwrap(other.id)

            // T1 cluster X: "Speaker 1" auto-labeled "Alice", matched on the anchor A0.
            let t1 = try self.insertTranscript(
                conn, speakersJSON: #"""
                    [{"speaker":"Alice","embedding":[1,0],"original_label":"Speaker 1",
                      "person_id":\#(aliceID),"label_source":"auto","matched_sample_id":\#(anchorID),"score":0.9}]
                    """#)

            // The auto sample self-training minted from X's confident match.
            var mintedSample = VoiceSample(personID: aliceID, embedding: self.v(1, 0),
                                           modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                           origin: .auto, anchor: false, status: .active,
                                           transcriptID: t1, clusterLabel: "Speaker 1")
            try VoiceSampleQueries.insert(conn, &mintedSample)
            let mintedID = try XCTUnwrap(mintedSample.id)

            // T2 cluster Y: "Speaker 1" auto-labeled "Alice", matched on the
            // soon-to-be-retired S1 — but its embedding ALSO confidently
            // matches A1 (cosine 0.96, well over the 0.70 floor; Alice is the
            // only candidate person here so the margin check is trivially
            // cleared too), so once S1 is gone it re-points to A1 instead of
            // reverting.
            let t2 = try self.insertTranscript(
                conn, speakersJSON: #"""
                    [{"speaker":"Alice","embedding":[0.6,0.8],"original_label":"Speaker 1",
                      "person_id":\#(aliceID),"label_source":"auto","matched_sample_id":\#(mintedID),"score":0.95}]
                    """#)

            let reverted = try VoiceLabelingQueries.rejectAutoLabel(conn, transcriptID: t1, clusterLabel: "Alice")
            XCTAssertEqual(reverted, 1, "only X reverts — Y is re-pointed, not reverted")

            XCTAssertEqual(try VoiceSample.fetchOne(conn, key: mintedID)?.status, .retired)
            XCTAssertEqual(try VoiceSample.fetchOne(conn, key: anchorID)?.status, .active, "untouched")
            XCTAssertEqual(try VoiceSample.fetchOne(conn, key: otherID)?.status, .active, "untouched")

            let x = try XCTUnwrap(MeetingTranscriptQueries.fetch(conn, id: t1)?.speakerEmbeddings?.first)
            XCTAssertEqual(x.speaker, "Speaker 1")
            XCTAssertEqual(x.labelSource, VoiceLabelSource.none)

            let y = try XCTUnwrap(MeetingTranscriptQueries.fetch(conn, id: t2)?.speakerEmbeddings?.first)
            XCTAssertEqual(y.speaker, "Alice", "the label itself is untouched — only the match is re-pointed")
            XCTAssertEqual(y.labelSource, VoiceLabelSource.auto)
            XCTAssertEqual(y.personID, aliceID)
            XCTAssertEqual(y.matchedSampleID, otherID, "re-pointed to the remaining sample it still confidently matches")
            XCTAssertEqual(y.score ?? 0, 0.96, accuracy: 1e-4)
        }
    }

    func testDeletePersonKeepsOwnerSetNamesAsText() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            let alice = try VoicePrintQueries.findOrCreate(conn, personKey: "alice@example.com", displayName: "Alice")
            let aliceID = try XCTUnwrap(alice.id)

            var anchor = VoiceSample(personID: aliceID, embedding: self.v(1, 0),
                                     modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                     origin: .owner, anchor: true, status: .active)
            try VoiceSampleQueries.insert(conn, &anchor)
            let anchorID = try XCTUnwrap(anchor.id)

            // T1: the owner named this cluster by hand — deleting the person
            // must keep "Alice" as plain text and only drop the person link.
            let t1 = try self.insertTranscript(
                conn, speakersJSON: #"""
                    [{"speaker":"Alice","embedding":[1,0],"original_label":"Speaker 1",
                      "person_id":\#(aliceID),"label_source":"owner"}]
                    """#)

            // T2: auto-labeled off the anchor — deleting the person reverts it.
            let t2 = try self.insertTranscript(
                conn, speakersJSON: #"""
                    [{"speaker":"Alice","embedding":[1,0],"original_label":"Speaker 1",
                      "person_id":\#(aliceID),"label_source":"auto","matched_sample_id":\#(anchorID),"score":0.9}]
                    """#)

            let reverted = try VoiceLabelingQueries.deletePerson(conn, personID: aliceID)
            XCTAssertEqual(reverted, 1, "only T2's auto cluster counts as reverted")

            let owner = try XCTUnwrap(MeetingTranscriptQueries.fetch(conn, id: t1)?.speakerEmbeddings?.first)
            XCTAssertEqual(owner.speaker, "Alice", "the owner's name stays as text")
            XCTAssertEqual(owner.labelSource, VoiceLabelSource.owner, "label source is untouched")
            XCTAssertNil(owner.personID, "only the person link is dropped")

            let auto = try XCTUnwrap(MeetingTranscriptQueries.fetch(conn, id: t2)?.speakerEmbeddings?.first)
            XCTAssertEqual(auto.speaker, "Speaker 1")
            XCTAssertEqual(auto.labelSource, VoiceLabelSource.none)
            XCTAssertNil(auto.personID)
            XCTAssertNil(auto.matchedSampleID)
            XCTAssertNil(auto.score)

            XCTAssertNil(try VoicePrintQueries.fetch(conn, id: aliceID), "the person is deleted")
            XCTAssertEqual(try VoiceSample.fetchCount(conn), 0, "the anchor cascades away with the person")
        }
    }

    func testDeleteImportRevertsLabelsThatDependedOnlyOnIt() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            let alice = try VoicePrintQueries.findOrCreate(conn, personKey: "alice@example.com", displayName: "Alice")
            let aliceID = try XCTUnwrap(alice.id)

            var sender = VoiceImport(senderName: "Colleague A", fileSHA256: "sha-a", peopleCount: 1, sampleCount: 1,
                                     modelVersion: VoiceRegistryPolicy.embeddingModelVersion)
            try sender.insert(conn)
            let importID = try XCTUnwrap(sender.id)

            // The owner already confirmed this imported sample (status active).
            var imported = VoiceSample(personID: aliceID, embedding: self.v(1, 0),
                                       modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                       origin: .imported, anchor: false, status: .active, importID: importID)
            try VoiceSampleQueries.insert(conn, &imported)
            let importedID = try XCTUnwrap(imported.id)

            // Auto-labeled off that activated imported sample; Alice has no other sample.
            let t1 = try self.insertTranscript(
                conn, speakersJSON: #"""
                    [{"speaker":"Alice","embedding":[1,0],"original_label":"Speaker 1",
                      "person_id":\#(aliceID),"label_source":"auto","matched_sample_id":\#(importedID),"score":0.9}]
                    """#)

            let reverted = try VoiceLabelingQueries.deleteImport(conn, importID: importID)
            XCTAssertEqual(reverted, 1)

            let cluster = try XCTUnwrap(MeetingTranscriptQueries.fetch(conn, id: t1)?.speakerEmbeddings?.first)
            XCTAssertEqual(cluster.speaker, "Speaker 1")
            XCTAssertEqual(cluster.labelSource, VoiceLabelSource.none)
            XCTAssertNil(cluster.personID)
            XCTAssertNil(cluster.matchedSampleID)
            XCTAssertNil(cluster.score)

            XCTAssertNil(try VoiceImport.fetchOne(conn, key: importID), "the import is deleted")
            XCTAssertEqual(try VoiceSample.fetchCount(conn), 0, "the imported sample cascades away with the import")
        }
    }

    // MARK: - Relabel of a named voice ("Listen to samples", spec §4.3)

    /// Builds the shared relabel fixture: T1's cluster "Speaker 1" is named
    /// Alice (`source`), with the sample it minted under Alice (an `auto`
    /// sample for an auto label, an owner anchor for an owner label), plus a
    /// T2 cluster auto-labeled Alice that matched ONLY on that minted sample,
    /// and a pending `.relabel` task on T1's "Alice".
    private struct RelabelFixture {
        let aliceID: Int64
        let mintedID: Int64
        let t1: Int64
        let t2: Int64
        let taskID: Int64
    }

    private func relabelFixture(_ conn: Database, source: VoiceLabelSource) throws -> RelabelFixture {
        let alice = try VoicePrintQueries.findOrCreate(conn, personKey: "alice@example.com", displayName: "Alice")
        let aliceID = try XCTUnwrap(alice.id)
        let t1 = try insertTranscript(conn, speakersJSON: #"""
            [{"speaker":"Alice","embedding":[1,0],"original_label":"Speaker 1",
              "person_id":\#(aliceID),"label_source":"\#(source.rawValue)"}]
            """#)
        var minted = VoiceSample(personID: aliceID, embedding: v(1, 0),
                                 modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                 origin: source == .owner ? .owner : .auto, anchor: source == .owner, status: .active,
                                 transcriptID: t1, clusterLabel: "Speaker 1")
        try VoiceSampleQueries.insert(conn, &minted)
        let mintedID = try XCTUnwrap(minted.id)
        let t2 = try insertTranscript(conn, speakersJSON: #"""
            [{"speaker":"Alice","embedding":[0,1],"original_label":"Speaker 1",
              "person_id":\#(aliceID),"label_source":"auto","matched_sample_id":\#(mintedID),"score":0.9}]
            """#)
        try VoiceLabelQueueQueries.enqueue(conn, transcriptID: t1, clusterLabel: "Alice", reason: .relabel,
                                           suggestedPersonID: nil, score: nil)
        let taskID = try XCTUnwrap(try VoiceLabelQueueQueries.pending(conn, transcriptID: t1).first?.id)
        return RelabelFixture(aliceID: aliceID, mintedID: mintedID, t1: t1, t2: t2, taskID: taskID)
    }

    private func assertDependentReverted(_ conn: Database, _ f: RelabelFixture, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try VoiceSample.fetchOne(conn, key: f.mintedID)?.status, .retired,
                       "the sample minted under the wrong person retires", file: file, line: line)
        let y = try XCTUnwrap(MeetingTranscriptQueries.fetch(conn, id: f.t2)?.speakerEmbeddings?.first)
        XCTAssertEqual(y.speaker, "Speaker 1", "the dependent matched only on it — reverted", file: file, line: line)
        XCTAssertEqual(y.labelSource, VoiceLabelSource.none, file: file, line: line)
        XCTAssertEqual(try VoiceLabelQueueQueries.pendingCount(conn), 0, file: file, line: line)
    }

    func testRelabelConfirmToAnotherPersonRetiresMintedSampleAndRematches() throws {
        for source in [VoiceLabelSource.auto, .owner] {
            let db = try TestDatabase.create()
            try db.write { conn in
                let f = try self.relabelFixture(conn, source: source)
                let result = try VoiceLabelingQueries.confirm(
                    conn, taskID: f.taskID, transcriptID: f.t1, clusterLabel: "Alice",
                    personKey: "bob@example.com", displayName: "Bob")
                guard case let .labeled(bobID) = result else { return XCTFail("\(source): expected .labeled, got \(result)") }

                let x = try XCTUnwrap(MeetingTranscriptQueries.fetch(conn, id: f.t1)?.speakerEmbeddings?.first)
                XCTAssertEqual(x.speaker, "Bob")
                XCTAssertEqual(x.personID, bobID)
                XCTAssertEqual(x.labelSource, .owner)
                XCTAssertEqual(x.rejectedPersonIDs, [f.aliceID], "relabeling away from Alice rejects her")
                XCTAssertEqual(try VoiceSampleQueries.anchors(conn, personID: bobID).count, 1, "Bob gets the anchor")
                let aliceActive = try VoiceSample.filter(Column("person_id") == f.aliceID && Column("status") == "active").fetchCount(conn)
                XCTAssertEqual(aliceActive, 0, "\(source): Alice keeps nothing of Bob's voice")
                try self.assertDependentReverted(conn, f)
            }
        }
    }

    func testRelabelDontKnowAndSeveralPeopleRevertTheWrongName() throws {
        for (source, kind) in [(VoiceLabelSource.auto, DismissKind.dontKnow), (.owner, .dontKnow),
                               (.auto, .severalPeople), (.owner, .severalPeople)] {
            let db = try TestDatabase.create()
            try db.write { conn in
                let f = try self.relabelFixture(conn, source: source)
                try VoiceLabelingQueries.dismiss(conn, taskID: f.taskID, kind: kind)

                let x = try XCTUnwrap(MeetingTranscriptQueries.fetch(conn, id: f.t1)?.speakerEmbeddings?.first)
                XCTAssertEqual(x.speaker, "Speaker 1", "\(source)/\(kind): the wrong name is taken off, not frozen")
                XCTAssertEqual(x.labelSource, .owner, "the owner's verdict keeps retro away from it")
                XCTAssertNil(x.personID)
                XCTAssertEqual(x.rejectedPersonIDs, [f.aliceID], "\(source)/\(kind): the wrong person is remembered")
                XCTAssertEqual(x.mixed == true, kind == .severalPeople)
                let text = try XCTUnwrap(MeetingTranscriptQueries.fetch(conn, id: f.t1)?.transcriptText)
                XCTAssertFalse(text.contains("Alice"), "the transcript text drops the wrong name too")
                try self.assertDependentReverted(conn, f)
            }
        }
    }

    /// A legacy named cluster never recorded its "Speaker N": "Don't know"
    /// gives it the first free one instead of keeping the wrong name.
    func testRelabelDontKnowOnLegacyNamedClusterPicksAFreeSpeakerLabel() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            let t1 = try self.insertTranscript(conn, speakersJSON: #"[{"speaker":"Alice","embedding":[1,0]}]"#)
            try VoiceLabelQueueQueries.enqueue(conn, transcriptID: t1, clusterLabel: "Alice", reason: .relabel,
                                               suggestedPersonID: nil, score: nil)
            let taskID = try XCTUnwrap(try VoiceLabelQueueQueries.pending(conn).first?.id)
            try VoiceLabelingQueries.dismiss(conn, taskID: taskID, kind: .dontKnow)
            let x = try XCTUnwrap(MeetingTranscriptQueries.fetch(conn, id: t1)?.speakerEmbeddings?.first)
            XCTAssertEqual(x.speaker, "Speaker 1")
            XCTAssertEqual(x.labelSource, .owner)
        }
    }

    /// A relabel that cannot land (a legacy row without segments) must not
    /// retire the previous person's samples on its way out.
    func testRelabelConfirmThatCannotLandRetiresNothing() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            let alice = try VoicePrintQueries.findOrCreate(conn, personKey: "alice@example.com", displayName: "Alice")
            let aliceID = try XCTUnwrap(alice.id)
            try TestDatabase.insertMeetingTranscript(conn, transcriptText: "[Alice] hi", speakersJSON: #"""
                [{"speaker":"Alice","embedding":[1,0],"original_label":"Speaker 1","person_id":\#(aliceID),"label_source":"owner"}]
                """#)
            let t1 = conn.lastInsertedRowID
            var anchor = VoiceSample(personID: aliceID, embedding: self.v(1, 0),
                                     modelVersion: VoiceRegistryPolicy.embeddingModelVersion, origin: .owner, anchor: true,
                                     status: .active, transcriptID: t1, clusterLabel: "Speaker 1")
            try VoiceSampleQueries.insert(conn, &anchor)

            let result = try VoiceLabelingQueries.confirm(
                conn, taskID: nil, transcriptID: t1, clusterLabel: "Alice", personKey: "bob@example.com", displayName: "Bob")
            XCTAssertEqual(result, .stale)
            XCTAssertEqual(try VoiceSample.fetchOne(conn, key: try XCTUnwrap(anchor.id))?.status, .active)
        }
    }
}
