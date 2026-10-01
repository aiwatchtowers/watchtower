import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Voices window's Review screen (spec §3.2): `VoiceSampleQueries.personSummaries`
/// (registry-list counts/channels/last-recognized), `VoiceRegistryCenter`'s
/// `loadReview`/`spotCheck`/`deletePerson`/`deleteImport`. `@MainActor`
/// throughout for the center tests; the plain-query tests below don't need
/// it but stay in the same class (the one-class-per-file convention).
@MainActor
final class VoiceReviewTests: XCTestCase {
    nonisolated private func v(_ x: Float, _ y: Float) -> Data { VoicePrintEmbedding.encode([x, y]) }

    nonisolated private func sample(
        person: Int64,
        origin: VoiceSampleOrigin,
        status: VoiceSampleStatus = .active,
        anchor: Bool = false,
        channel: VoiceChannel = .unknown,
        transcriptID: Int64? = nil,
        importID: Int64? = nil
    ) -> VoiceSample {
        VoiceSample(personID: person, embedding: v(1, 0), modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                    origin: origin, anchor: anchor, status: status, transcriptID: transcriptID,
                    channel: channel, importID: importID)
    }

    func testPersonSummariesGroupsCountsByOriginAndChannelAndOmitsPeopleWithNoActiveSamples() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            let alice = try XCTUnwrap(VoicePrintQueries.findOrCreate(conn, personKey: "alice@example.com", displayName: "Alice").id)
            let bob = try XCTUnwrap(VoicePrintQueries.findOrCreate(conn, personKey: "bob@example.com", displayName: "Bob").id)

            try TestDatabase.insertMeetingTranscript(conn, title: "Weekly")
            let transcriptID = conn.lastInsertedRowID

            var anchor = self.sample(person: alice, origin: .owner, anchor: true, channel: .room)
            try VoiceSampleQueries.insert(conn, &anchor)
            var autoRoomA = self.sample(person: alice, origin: .auto, channel: .room)
            try VoiceSampleQueries.insert(conn, &autoRoomA)
            var autoRoomB = self.sample(person: alice, origin: .auto, channel: .room, transcriptID: transcriptID)
            try VoiceSampleQueries.insert(conn, &autoRoomB)
            var autoRemote = self.sample(person: alice, origin: .auto, channel: .remote)
            try VoiceSampleQueries.insert(conn, &autoRemote)
            var importedActive = self.sample(person: alice, origin: .imported, channel: .unknown)
            try VoiceSampleQueries.insert(conn, &importedActive)
            // A pending import never counts — it hasn't been confirmed yet.
            var importedPending = self.sample(person: alice, origin: .imported, status: .pending, channel: .unknown)
            try VoiceSampleQueries.insert(conn, &importedPending)

            // Bob's only sample is retired (e.g. by a rollback) — he has
            // nothing left to review and must be omitted entirely.
            var retired = self.sample(person: bob, origin: .auto, status: .retired)
            try VoiceSampleQueries.insert(conn, &retired)

            let summaries = try VoiceSampleQueries.personSummaries(conn)
            XCTAssertEqual(summaries.map(\.displayName), ["Alice"], "Bob has zero active samples")

            let aliceSummary = try XCTUnwrap(summaries.first)
            XCTAssertEqual(aliceSummary.counts[.owner], 1)
            XCTAssertEqual(aliceSummary.counts[.auto], 3)
            XCTAssertEqual(aliceSummary.counts[.imported], 1, "only the active import counts, not the pending one")
            XCTAssertEqual(aliceSummary.channels, [.room, .remote, .unknown])
            XCTAssertNotNil(aliceSummary.lastRecognized, "one active sample (autoRoomB) carries a transcript id")
        }
    }

    func testPersonSummariesLastRecognizedNilWithoutATranscriptLinkedSample() throws {
        let db = try TestDatabase.create()
        try db.write { conn in
            let alice = try XCTUnwrap(VoicePrintQueries.findOrCreate(conn, personKey: "alice@example.com", displayName: "Alice").id)
            var imported = self.sample(person: alice, origin: .imported)
            try VoiceSampleQueries.insert(conn, &imported)

            let summary = try XCTUnwrap(VoiceSampleQueries.personSummaries(conn).first)
            XCTAssertNil(summary.lastRecognized, "an imported sample never carries a transcript id")
        }
    }

    // MARK: - center fixtures

    nonisolated private func utterances(_ speaker: String) -> [TranscriptUtterance] {
        [TranscriptUtterance(idx: 0, startSec: 1, endSec: 6, speaker: speaker, text: "hi there")]
    }

    /// Inserts a one-cluster segmented transcript and returns its id.
    @discardableResult
    nonisolated private func insertTranscript(
        _ db: Database,
        title: String = "Rec",
        audioPath: String?,
        speakersJSON: String,
        speaker: String = "Speaker 1",
        createdAt: String? = nil
    ) throws -> Int64 {
        try TestDatabase.insertMeetingTranscript(
            db, title: title, audioPath: audioPath,
            transcriptText: TranscriptSegments.render(self.utterances(speaker)),
            segmentsJSON: try XCTUnwrap(TranscriptSegments.encode(self.utterances(speaker))),
            speakersJSON: speakersJSON, createdAt: createdAt)
        return db.lastInsertedRowID
    }

    /// An auto-labeled, clip-carrying cluster's `speakers_json`, matched on `matchedSampleID`.
    nonisolated private func autoSpeakersJSON(label: String, personID: Int64, matchedSampleID: Int64, clips: Bool = true) -> String {
        let clipsField = clips ? #","clips":[{"start":1,"end":6}]"# : ""
        return #"[{"speaker":"\#(label)","embedding":[1,0],"original_label":"Speaker 1","#
            + #""person_id":\#(personID),"label_source":"auto","matched_sample_id":\#(matchedSampleID),"#
            + #""score":0.9\#(clipsField)}]"#
    }

    // MARK: - loadReview / buildSpotChecks

    func testLoadReviewExcludesAudiolessRecordingsAndOwnerSetClusters() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let audio = try TestFixtures.tempAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        try await pool.write { db in
            let alice = try XCTUnwrap(VoicePrintQueries.findOrCreate(db, personKey: "alice@example.com", displayName: "Alice").id)
            var anchor = VoiceSample(personID: alice, embedding: VoicePrintEmbedding.encode([1, 0]),
                                     modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                     origin: .owner, anchor: true, status: .active)
            try VoiceSampleQueries.insert(db, &anchor)
            let anchorID = try XCTUnwrap(anchor.id)

            // Included: audio present, auto-labeled, has clips.
            _ = try self.insertTranscript(
                db, title: "Included", audioPath: audio.path,
                speakersJSON: self.autoSpeakersJSON(label: "Alice", personID: alice, matchedSampleID: anchorID))

            // Excluded: no audio file on disk.
            _ = try self.insertTranscript(
                db, title: "No audio", audioPath: "/nonexistent.caf",
                speakersJSON: self.autoSpeakersJSON(label: "Alice", personID: alice, matchedSampleID: anchorID))

            // Excluded: the owner named this cluster by hand.
            _ = try self.insertTranscript(
                db, title: "Owner-set", audioPath: audio.path,
                speakersJSON: #"[{"speaker":"Alice","embedding":[1,0],"person_id":\#(alice),"label_source":"owner","clips":[{"start":1,"end":6}]}]"#)

            // Excluded: auto-labeled but no clips.
            _ = try self.insertTranscript(
                db, title: "No clips", audioPath: audio.path,
                speakersJSON: self.autoSpeakersJSON(label: "Alice", personID: alice, matchedSampleID: anchorID, clips: false))
        }

        let center = VoiceRegistryCenter()
        center.attach(dbPool: pool)
        await center.open(.review)

        XCTAssertEqual(center.spotChecks.map(\.meetingTitle), ["Included"])
        XCTAssertEqual(center.spotChecks.first?.clusterLabel, "Alice")
        XCTAssertNil(center.lastError)
    }

    func testLoadReviewTakesOnlyThreeLatestSpotChecksPerPerson() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let audio = try TestFixtures.tempAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        try await pool.write { db in
            let alice = try XCTUnwrap(VoicePrintQueries.findOrCreate(db, personKey: "alice@example.com", displayName: "Alice").id)
            var anchor = VoiceSample(personID: alice, embedding: VoicePrintEmbedding.encode([1, 0]),
                                     modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                     origin: .owner, anchor: true, status: .active)
            try VoiceSampleQueries.insert(db, &anchor)
            let anchorID = try XCTUnwrap(anchor.id)

            for day in 1...4 {
                _ = try self.insertTranscript(
                    db, title: "Day \(day)", audioPath: audio.path,
                    speakersJSON: self.autoSpeakersJSON(label: "Alice", personID: alice, matchedSampleID: anchorID),
                    createdAt: "2026-09-\(String(format: "%02d", day))T10:00:00Z")
            }
        }

        let center = VoiceRegistryCenter()
        center.attach(dbPool: pool)
        await center.open(.review)

        XCTAssertEqual(center.spotChecks.count, 3, "only the 3 latest")
        XCTAssertEqual(center.spotChecks.map(\.meetingTitle), ["Day 4", "Day 3", "Day 2"], "newest first")
    }

    // MARK: - spotCheck

    func testSpotCheckWrongRevertsLabelEnqueuesRelabelAndRemovesTheCheck() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let audio = try TestFixtures.tempAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        let t1 = try await pool.write { db -> Int64 in
            let alice = try XCTUnwrap(VoicePrintQueries.findOrCreate(db, personKey: "alice@example.com", displayName: "Alice").id)
            var anchor = VoiceSample(personID: alice, embedding: VoicePrintEmbedding.encode([1, 0]),
                                     modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                     origin: .owner, anchor: true, status: .active)
            try VoiceSampleQueries.insert(db, &anchor)
            let anchorID = try XCTUnwrap(anchor.id)
            return try self.insertTranscript(
                db, audioPath: audio.path,
                speakersJSON: self.autoSpeakersJSON(label: "Alice", personID: alice, matchedSampleID: anchorID),
                speaker: "Alice")
        }

        let center = VoiceRegistryCenter()
        center.attach(dbPool: pool)
        await center.open(.review)
        let check = try XCTUnwrap(center.spotChecks.first)

        await center.spotCheck(check, correct: false)

        XCTAssertNil(center.lastError)
        XCTAssertTrue(center.spotChecks.isEmpty, "reloaded and the cluster no longer qualifies")

        let cluster = try await pool.read { db in try MeetingTranscriptQueries.fetch(db, id: t1)?.speakerEmbeddings?.first }
        XCTAssertEqual(cluster?.speaker, "Speaker 1")
        XCTAssertEqual(cluster?.labelSource, VoiceLabelSource.none)
        XCTAssertNil(cluster?.personID)

        let pending = try await pool.read { db in try VoiceLabelQueueQueries.pending(db, transcriptID: t1) }
        XCTAssertEqual(pending.map(\.reason), [.relabel], "the owner gets another chance to name it")
    }

    func testSpotCheckCorrectRemovesTheCheckWithoutWritingAnything() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let audio = try TestFixtures.tempAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        let t1 = try await pool.write { db -> Int64 in
            let alice = try XCTUnwrap(VoicePrintQueries.findOrCreate(db, personKey: "alice@example.com", displayName: "Alice").id)
            var anchor = VoiceSample(personID: alice, embedding: VoicePrintEmbedding.encode([1, 0]),
                                     modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                     origin: .owner, anchor: true, status: .active)
            try VoiceSampleQueries.insert(db, &anchor)
            let anchorID = try XCTUnwrap(anchor.id)
            return try self.insertTranscript(
                db, audioPath: audio.path,
                speakersJSON: self.autoSpeakersJSON(label: "Alice", personID: alice, matchedSampleID: anchorID))
        }

        let center = VoiceRegistryCenter()
        center.attach(dbPool: pool)
        await center.open(.review)
        let check = try XCTUnwrap(center.spotChecks.first)

        await center.spotCheck(check, correct: true)

        XCTAssertNil(center.lastError)
        XCTAssertTrue(center.spotChecks.isEmpty, "dropped from this screen's list")

        let cluster = try await pool.read { db in try MeetingTranscriptQueries.fetch(db, id: t1)?.speakerEmbeddings?.first }
        XCTAssertEqual(cluster?.speaker, "Alice", "correct never touches the label")
        XCTAssertEqual(cluster?.labelSource, VoiceLabelSource.auto)

        let pending = try await pool.read { db in try VoiceLabelQueueQueries.pending(db, transcriptID: t1) }
        XCTAssertTrue(pending.isEmpty, "no relabel task — nothing was rejected")
    }

    // MARK: - deletePerson / deleteImport

    /// Reuses the `VoiceRollbackTests` fixture shape: an owner-set cluster
    /// keeps its name as text, an auto-labeled one reverts.
    func testDeletePersonRemovesFromPeopleAndRevertsAutoLabels() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }

        let (aliceID, t1, t2) = try await pool.write { db -> (Int64, Int64, Int64) in
            let alice = try XCTUnwrap(VoicePrintQueries.findOrCreate(db, personKey: "alice@example.com", displayName: "Alice").id)
            var anchor = VoiceSample(personID: alice, embedding: VoicePrintEmbedding.encode([1, 0]),
                                     modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                     origin: .owner, anchor: true, status: .active)
            try VoiceSampleQueries.insert(db, &anchor)
            let anchorID = try XCTUnwrap(anchor.id)

            let t1 = try self.insertTranscript(
                db, audioPath: nil,
                speakersJSON: #"[{"speaker":"Alice","embedding":[1,0],"person_id":\#(alice),"label_source":"owner"}]"#,
                speaker: "Alice")
            let t2 = try self.insertTranscript(
                db, audioPath: nil,
                speakersJSON: self.autoSpeakersJSON(label: "Alice", personID: alice, matchedSampleID: anchorID),
                speaker: "Alice")
            return (alice, t1, t2)
        }

        let center = VoiceRegistryCenter()
        center.attach(dbPool: pool)
        await center.loadReview()
        XCTAssertEqual(center.people.map(\.displayName), ["Alice"])

        await center.deletePerson(aliceID)

        XCTAssertNil(center.lastError)
        XCTAssertTrue(center.people.isEmpty, "the person is gone")

        let (ownerCluster, autoCluster) = try await pool.read { db in
            (try MeetingTranscriptQueries.fetch(db, id: t1)?.speakerEmbeddings?.first,
             try MeetingTranscriptQueries.fetch(db, id: t2)?.speakerEmbeddings?.first)
        }
        XCTAssertEqual(ownerCluster?.speaker, "Alice", "the owner's name stays as text")
        XCTAssertNil(ownerCluster?.personID)
        XCTAssertEqual(autoCluster?.speaker, "Speaker 1", "the auto label reverts")
        XCTAssertEqual(autoCluster?.labelSource, VoiceLabelSource.none)
    }

    func testDeleteImportRemovesFromImportsAndReloadsReview() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }

        let importID = try await pool.write { db -> Int64 in
            var sender = VoiceImport(senderName: "Colleague A", fileSHA256: "sha-a", peopleCount: 1, sampleCount: 1,
                                     modelVersion: VoiceRegistryPolicy.embeddingModelVersion)
            try sender.insert(db)
            return try XCTUnwrap(sender.id)
        }

        let center = VoiceRegistryCenter()
        center.attach(dbPool: pool)
        await center.loadReview()
        XCTAssertEqual(center.imports.map(\.senderName), ["Colleague A"])

        await center.deleteImport(importID)

        XCTAssertNil(center.lastError)
        XCTAssertTrue(center.imports.isEmpty)
    }

    // MARK: - degenerate

    /// A center that was never attach()ed must no-op cleanly (the
    /// `VoiceRegistryCenterTests.testMethodsBeforeAttachAreNoops` precedent).
    func testReviewMethodsBeforeAttachAreNoops() async throws {
        let center = VoiceRegistryCenter()

        await center.loadReview()
        await center.deletePerson(1)
        await center.deleteImport(1)
        await center.spotCheck(
            VoiceRegistryCenter.VoiceSpotCheck(
                id: "1:Alice", transcriptID: 1, clusterLabel: "Alice", personID: 1,
                clips: [], audioPath: "/tmp/x.caf", meetingTitle: "X"),
            correct: false)

        XCTAssertTrue(center.people.isEmpty)
        XCTAssertTrue(center.imports.isEmpty)
        XCTAssertTrue(center.spotChecks.isEmpty)
        XCTAssertNil(center.lastError)
    }
}
