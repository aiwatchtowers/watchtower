import Foundation
import GRDB
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The Voices-window center: card building (audio/clip presence), the
/// confirm/dismiss/relabel transactions, and the "start → close window →
/// reopen" surviving-state contract (the `MeetingRecorderCenter` precedent).
@MainActor
final class VoiceRegistryCenterTests: XCTestCase {
    nonisolated private static let oneUtterance = [
        TranscriptUtterance(idx: 0, startSec: 1, endSec: 6, speaker: "Speaker 1", text: "hi there")
    ]

    nonisolated private func speakersJSON(embedding: String = "[1,0]", clips: String? = #"[{"start":1,"end":6}]"#) -> String {
        let clipsField = clips.map { #","clips":\#($0)"# } ?? ""
        return #"[{"speaker":"Speaker 1","embedding":\#(embedding)\#(clipsField)}]"#
    }

    /// Inserts a one-cluster segmented transcript and returns its id. `db`'s
    /// write closures run off the main actor, so this (and the DB fixtures
    /// it composes) must stay `nonisolated`.
    @discardableResult
    nonisolated private func insertTranscript(
        _ db: Database, title: String = "Rec", audioPath: String?, speakersJSON: String, eventID: String? = nil
    ) throws -> Int64 {
        try TestDatabase.insertMeetingTranscript(
            db, eventID: eventID, title: title, audioPath: audioPath,
            transcriptText: TranscriptSegments.render(Self.oneUtterance),
            segmentsJSON: try XCTUnwrap(TranscriptSegments.encode(Self.oneUtterance)),
            speakersJSON: speakersJSON)
        return db.lastInsertedRowID
    }

    func testRefreshBuildsCardsOnlyForTasksWithAudioAndClips() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let audio = try TestFixtures.tempAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        let (t1, t2) = try await pool.write { db -> (Int64, Int64) in
            let t1 = try self.insertTranscript(db, title: "Weekly", audioPath: audio.path, speakersJSON: self.speakersJSON())
            let t2 = try self.insertTranscript(db, audioPath: "/nonexistent.caf", speakersJSON: self.speakersJSON())
            try VoiceLabelQueueQueries.enqueue(
                db, transcriptID: t1, clusterLabel: "Speaker 1", reason: .unknown, suggestedPersonID: nil, score: nil)
            try VoiceLabelQueueQueries.enqueue(
                db, transcriptID: t2, clusterLabel: "Speaker 1", reason: .unknown, suggestedPersonID: nil, score: nil)
            return (t1, t2)
        }

        let center = VoiceRegistryCenter()
        center.attach(dbPool: pool)
        await center.catchUp() // skips t2's task — its audio file doesn't exist
        await center.open(.queue(transcriptID: nil))

        XCTAssertEqual(center.cards.map(\.transcriptID), [t1])
        XCTAssertEqual(center.pendingCount, 1)
        XCTAssertEqual(center.cards.first?.meetingTitle, "Weekly")
        XCTAssertEqual(center.cards.first?.clipTexts, ["hi there"], "the clip's joined utterance text")
        XCTAssertEqual(center.cards.first?.audioPath, audio.path)
        XCTAssertNil(center.lastError)

        // t2's task really is gone, not merely filtered from this transcript's card set.
        let t2StillPending = try await pool.read { db in try VoiceLabelQueueQueries.pending(db, transcriptID: t2) }
        XCTAssertTrue(t2StillPending.isEmpty)
    }

    func testConfirmRunsRetroForThatPersonAndRemovesCard() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let audio = try TestFixtures.tempAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        // t1: queued for naming, has audio + a clip. t2: the SAME voice
        // ([1,0]), no audio, no queue task — retro must still reach it.
        let t1 = try await pool.write { db -> Int64 in
            let t1 = try self.insertTranscript(db, audioPath: audio.path, speakersJSON: self.speakersJSON())
            try self.insertTranscript(db, audioPath: nil, speakersJSON: self.speakersJSON(clips: nil))
            try VoiceLabelQueueQueries.enqueue(
                db, transcriptID: t1, clusterLabel: "Speaker 1", reason: .unknown, suggestedPersonID: nil, score: nil)
            return t1
        }
        let t2 = try await pool.read { db in
            try XCTUnwrap(Int64.fetchAll(db, sql: "SELECT id FROM meeting_transcripts WHERE id != ?", arguments: [t1]).first)
        }

        let center = VoiceRegistryCenter()
        center.attach(dbPool: pool)
        await center.open(.queue(transcriptID: nil))
        let card = try XCTUnwrap(center.cards.first)
        XCTAssertEqual(card.transcriptID, t1)

        await center.confirm(card, person: VoiceRegistryCenter.PersonChoice(
            personKey: "alice@example.com", displayName: "Alice", inRegistry: false))

        XCTAssertTrue(center.cards.isEmpty)
        XCTAssertEqual(center.pendingCount, 0)
        XCTAssertNil(center.lastError)

        let (t1Speaker, t2Speaker) = try await pool.read { db in
            (try MeetingTranscriptQueries.fetch(db, id: t1)?.speakerEmbeddings?.first?.speaker,
             try MeetingTranscriptQueries.fetch(db, id: t2)?.speakerEmbeddings?.first?.speaker)
        }
        XCTAssertEqual(t1Speaker, "Alice")
        XCTAssertEqual(t2Speaker, "Alice", "retro must name the audio-less duplicate too")
    }

    /// Spec §3.1: confirming a voice in one meeting lets retro name it in
    /// another — that meeting's own pending task must close with it, or the
    /// tray keeps counting a card the window can no longer show.
    func testConfirmClosesOtherMeetingsTaskForTheSameVoice() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let audio = try TestFixtures.tempAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        let (t1, t2) = try await pool.write { db -> (Int64, Int64) in
            let t1 = try self.insertTranscript(db, audioPath: audio.path, speakersJSON: self.speakersJSON())
            let t2 = try self.insertTranscript(db, audioPath: audio.path, speakersJSON: self.speakersJSON())
            for tid in [t1, t2] {
                try VoiceLabelQueueQueries.enqueue(
                    db, transcriptID: tid, clusterLabel: "Speaker 1", reason: .unknown, suggestedPersonID: nil, score: nil)
            }
            return (t1, t2)
        }

        let center = VoiceRegistryCenter()
        center.attach(dbPool: pool)
        await center.open(.queue(transcriptID: nil))
        XCTAssertEqual(center.pendingCount, 2)
        let card = try XCTUnwrap(center.cards.first { $0.transcriptID == t1 })

        await center.confirm(card, person: VoiceRegistryCenter.PersonChoice(
            personKey: "alice@example.com", displayName: "Alice", inRegistry: false))

        XCTAssertNil(center.lastError)
        XCTAssertEqual(center.pendingCount, 0, "t2's task auto-closed once retro named its cluster")
        XCTAssertTrue(center.cards.isEmpty, "the stale t2 card leaves the window too")
        let (t2Speaker, t2Status) = try await pool.read { db in
            (try MeetingTranscriptQueries.fetch(db, id: t2)?.speakerEmbeddings?.first?.speaker,
             try String.fetchOne(db, sql: "SELECT status FROM voice_label_queue WHERE transcript_id = ?", arguments: [t2]))
        }
        XCTAssertEqual(t2Speaker, "Alice")
        XCTAssertEqual(t2Status, "done")
    }

    /// Spec §6: "Voice recognition" off = no identification — the launch
    /// catch-up must not retro-relabel history, though the queue
    /// housekeeping still runs.
    func testCatchUpWithVoiceRecognitionOffSkipsRetro() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let tid = try await pool.write { db -> Int64 in
            let tid = try self.insertTranscript(db, audioPath: nil, speakersJSON: self.speakersJSON(clips: nil))
            let alice = try VoicePrintQueries.findOrCreate(db, personKey: "alice@example.com", displayName: "Alice")
            var sample = VoiceSample(personID: try XCTUnwrap(alice.id), embedding: VoicePrintEmbedding.encode([1, 0]),
                                     modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                     origin: .owner, anchor: true, status: .active)
            try VoiceSampleQueries.insert(db, &sample)
            try VoiceLabelQueueQueries.enqueue(
                db, transcriptID: tid, clusterLabel: "Speaker 1", reason: .unknown, suggestedPersonID: nil, score: nil)
            return tid
        }
        let center = VoiceRegistryCenter()
        center.attach(dbPool: pool)

        await center.catchUp(voiceRecognition: false)
        let off = try await pool.read { db in try MeetingTranscriptQueries.fetch(db, id: tid)?.speakerEmbeddings?.first?.speaker }
        XCTAssertEqual(off, "Speaker 1", "no retro with recognition off")
        XCTAssertEqual(center.pendingCount, 0, "housekeeping still skips the audio-less task")

        await center.catchUp(voiceRecognition: true)
        let on = try await pool.read { db in try MeetingTranscriptQueries.fetch(db, id: tid)?.speakerEmbeddings?.first?.speaker }
        XCTAssertEqual(on, "Alice")
    }

    /// Seeds N2's dispute in `db`: Alice's active anchor on [1,0], and a
    /// pending import claiming that voice (cos ≈ 0.995) is Bob.
    nonisolated private func seedImportDispute(_ db: Database) throws -> (alice: Int64, claim: Int64) {
        let alice = try VoicePrintQueries.findOrCreate(db, personKey: "alice@example.com", displayName: "Alice")
        let bob = try VoicePrintQueries.findOrCreate(db, personKey: "bob@example.com", displayName: "Bob")
        var anchor = VoiceSample(personID: try XCTUnwrap(alice.id), embedding: VoicePrintEmbedding.encode([1, 0]),
                                 modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                 origin: .owner, anchor: true, status: .active)
        try VoiceSampleQueries.insert(db, &anchor)
        var claim = VoiceSample(personID: try XCTUnwrap(bob.id), embedding: VoicePrintEmbedding.encode([1, 0.1]),
                                modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                origin: .imported, anchor: false, status: .pending)
        try VoiceSampleQueries.insert(db, &claim)
        return (try XCTUnwrap(alice.id), try XCTUnwrap(claim.id))
    }

    /// N2: the launch catch-up must not silently resolve a conflict the
    /// save queued — the cluster stays unnamed and its task pending.
    func testCatchUpLeavesAQueuedConflictForTheOwner() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let audio = try TestFixtures.tempAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }
        let tid = try await pool.write { db -> Int64 in
            let tid = try self.insertTranscript(db, audioPath: audio.path, speakersJSON: self.speakersJSON())
            let (alice, _) = try self.seedImportDispute(db)
            try VoiceLabelQueueQueries.enqueue(
                db, transcriptID: tid, clusterLabel: "Speaker 1", reason: .conflict, suggestedPersonID: alice, score: 1)
            return tid
        }
        let center = VoiceRegistryCenter()
        center.attach(dbPool: pool)

        await center.catchUp()

        let (speaker, reasons) = try await pool.read { db in
            (try MeetingTranscriptQueries.fetch(db, id: tid)?.speakerEmbeddings?.first?.speaker,
             try VoiceLabelQueueQueries.pending(db, transcriptID: tid).map(\.reason))
        }
        XCTAssertEqual(speaker, "Speaker 1", "retro left the disputed voice unnamed")
        XCTAssertEqual(reasons, [.conflict], "the conflict task is still open")
        XCTAssertEqual(center.pendingCount, 1)
    }

    /// N2 through the audio sweep: a conflict task whose recording lost its
    /// audio is skipped before retro runs, yet retro still leaves the
    /// disputed voice unnamed (the dispute lives in the data, not the task
    /// row). Once the owner settles it on one recording, the next catch-up
    /// names the same voice in another recording.
    func testAudioSweptConflictStaysUnnamedUntilTheOwnerSettlesIt() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let (t1, t2, alice) = try await pool.write { db -> (Int64, Int64, Int64) in
            let t1 = try self.insertTranscript(db, audioPath: nil, speakersJSON: self.speakersJSON(clips: nil))
            let t2 = try self.insertTranscript(db, audioPath: nil, speakersJSON: self.speakersJSON(clips: nil))
            let (alice, _) = try self.seedImportDispute(db)
            try VoiceLabelQueueQueries.enqueue(
                db, transcriptID: t1, clusterLabel: "Speaker 1", reason: .conflict, suggestedPersonID: alice, score: 1)
            return (t1, t2, alice)
        }
        let center = VoiceRegistryCenter()
        center.attach(dbPool: pool)

        await center.catchUp()
        let (swept, status) = try await pool.read { db in
            (try MeetingTranscriptQueries.fetch(db, id: t1)?.speakerEmbeddings?.first?.speaker,
             try String.fetchOne(db, sql: "SELECT status FROM voice_label_queue WHERE transcript_id = ?", arguments: [t1]))
        }
        XCTAssertEqual(status, "skipped", "the sweep skipped the audio-less task")
        XCTAssertEqual(swept, "Speaker 1", "retro still does not pick a side")

        // The owner settles the dispute on t1 (e.g. from Train).
        let result = try await pool.write { db in
            try VoiceLabelingQueries.confirm(db, taskID: nil, transcriptID: t1, clusterLabel: "Speaker 1",
                                             personKey: "alice@example.com", displayName: "Alice")
        }
        XCTAssertEqual(result, .labeled(personID: alice))
        await center.catchUp()
        let other = try await pool.read { db in try MeetingTranscriptQueries.fetch(db, id: t2)?.speakerEmbeddings?.first?.speaker }
        XCTAssertEqual(other, "Alice", "the settled voice is named in the other recording")
    }

    // MARK: - Import / export through the center

    /// Seeds one exportable person (an owner anchor) in `pool`.
    nonisolated private func seedExportablePerson(_ pool: DatabasePool) async throws -> Int64 {
        try await pool.write { db in
            let alice = try VoicePrintQueries.findOrCreate(db, personKey: "alice@example.com", displayName: "Alice")
            let id = try XCTUnwrap(alice.id)
            var sample = VoiceSample(personID: id, embedding: VoicePrintEmbedding.encode([0.6, 0.8]),
                                     modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                     origin: .owner, anchor: true, status: .active, channel: .remote, speechSec: 40)
            try VoiceSampleQueries.insert(db, &sample)
            return id
        }
    }

    /// Export → preview → import across two databases, end to end through
    /// the center; the decrypted payload is dropped once it is used.
    func testExportThenImportRoundTripsThroughTheCenter() async throws {
        let (source, sourcePath) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: sourcePath) }
        let (target, targetPath) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: targetPath) }
        let aliceID = try await seedExportablePerson(source)
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voices_\(UUID().uuidString).wtvoices")
        defer { try? FileManager.default.removeItem(at: file) }

        let exporter = VoiceRegistryCenter()
        exporter.attach(dbPool: source)
        try await exporter.export(to: file, password: "pw", personIDs: [aliceID])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path + ".tmp"), "no temp file left behind")

        let importer = VoiceRegistryCenter()
        importer.attach(dbPool: target)
        let preview = try await importer.previewImport(url: file, password: "pw")
        XCTAssertEqual(preview.newPeople, ["Alice"])
        XCTAssertNotNil(importer.pendingImport)

        try await importer.applyImport()
        XCTAssertNil(importer.pendingImport, "the decrypted payload is dropped after the commit")
        XCTAssertEqual(importer.imports.count, 1)
        let pending = try await target.read { db in
            try VoiceSample.filter(Column("status") == VoiceSampleStatus.pending.rawValue).fetchCount(db)
        }
        XCTAssertEqual(pending, 1)
    }

    /// `apply` writing nothing (the same file landed meanwhile) must surface
    /// as an error, never as a successful import.
    func testApplyImportThatWritesNothingThrows() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let payload = VoiceExportPayload(
            formatVersion: 1, modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
            sender: .init(name: "Colleague A", email: "a@example.com"),
            people: [.init(personKey: "bob@example.com", displayName: "Bob",
                           samples: [.init(embedding: [1, 0], channel: .remote, speechSec: 40)])])
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voices_\(UUID().uuidString).wtvoices")
        defer { try? FileManager.default.removeItem(at: file) }
        try VoiceExportCodec.seal(payload, password: "pw").write(to: file)

        let center = VoiceRegistryCenter()
        center.attach(dbPool: pool)
        _ = try await center.previewImport(url: file, password: "pw")
        let sha = try XCTUnwrap(center.pendingImport?.fileSHA256)
        // The same file is imported by another path between preview and apply.
        _ = try await pool.write { db in try VoiceImportQueries.apply(db, payload: payload, fileSHA256: sha, ownerEmails: []) }

        do {
            try await center.applyImport()
            XCTFail("an import that wrote nothing must throw")
        } catch {
            XCTAssertEqual(error as? VoiceExportImportError, .importRefused)
        }
        XCTAssertNil(center.pendingImport)
    }

    /// A failed preview never leaves an earlier file's payload armed, and
    /// closing the sheet drops it too.
    func testPendingImportIsDiscardedOnFailedPreviewAndOnClose() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("voices_\(UUID().uuidString).wtvoices")
        defer { try? FileManager.default.removeItem(at: file) }
        let payload = VoiceExportPayload(formatVersion: 1, modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                         sender: .init(name: "A", email: "a@example.com"), people: [])
        try VoiceExportCodec.seal(payload, password: "pw").write(to: file)

        let center = VoiceRegistryCenter()
        center.attach(dbPool: pool)
        _ = try await center.previewImport(url: file, password: "pw")
        XCTAssertNotNil(center.pendingImport)
        do {
            _ = try await center.previewImport(url: file, password: "wrong")
            XCTFail("wrong password must throw")
        } catch {}
        XCTAssertNil(center.pendingImport, "the failed preview disarmed the earlier one")

        _ = try await center.previewImport(url: file, password: "pw")
        center.discardPendingImport()
        XCTAssertNil(center.pendingImport)
    }

    func testStateSurvivesWindowCloseAndReopen() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let audio = try TestFixtures.tempAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        let t1 = try await pool.write { db -> Int64 in
            let t1 = try self.insertTranscript(db, audioPath: audio.path, speakersJSON: self.speakersJSON())
            try VoiceLabelQueueQueries.enqueue(
                db, transcriptID: t1, clusterLabel: "Speaker 1", reason: .unknown, suggestedPersonID: nil, score: nil)
            return t1
        }

        let center = VoiceRegistryCenter()
        center.attach(dbPool: pool)
        var opened = 0
        center.openWindow = { opened += 1 }

        await center.open(.queue(transcriptID: nil))
        XCTAssertEqual(center.cards.map(\.transcriptID), [t1])
        XCTAssertEqual(opened, 1)

        await center.open(.review)
        XCTAssertEqual(center.mode, .review)

        // Simulate the Voices window closing: the scene-provided opener goes away.
        center.openWindow = nil

        await center.open(.queue(transcriptID: nil))
        XCTAssertEqual(center.mode, .queue(transcriptID: nil))
        XCTAssertEqual(center.cards.map(\.transcriptID), [t1], "reloaded from the DB, not lost across the mode switch")
    }

    // MARK: - dismiss

    func testDismissSkipMovesCardToEndWithoutClosingTheTask() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let audioA = try TestFixtures.tempAudioFile()
        let audioB = try TestFixtures.tempAudioFile()
        defer {
            try? FileManager.default.removeItem(at: audioA)
            try? FileManager.default.removeItem(at: audioB)
        }

        try await pool.write { db in
            let ta = try self.insertTranscript(db, title: "A", audioPath: audioA.path, speakersJSON: self.speakersJSON())
            let tb = try self.insertTranscript(db, title: "B", audioPath: audioB.path, speakersJSON: self.speakersJSON())
            try VoiceLabelQueueQueries.enqueue(
                db, transcriptID: ta, clusterLabel: "Speaker 1", reason: .unknown, suggestedPersonID: nil, score: nil)
            try VoiceLabelQueueQueries.enqueue(
                db, transcriptID: tb, clusterLabel: "Speaker 1", reason: .unknown, suggestedPersonID: nil, score: nil)
        }

        let center = VoiceRegistryCenter()
        center.attach(dbPool: pool)
        await center.open(.queue(transcriptID: nil))
        XCTAssertEqual(center.cards.map(\.meetingTitle), ["A", "B"])

        let first = try XCTUnwrap(center.cards.first)
        await center.dismiss(first, .skip)

        XCTAssertEqual(center.cards.map(\.meetingTitle), ["B", "A"], "skip moves the card to the end, not away")
        XCTAssertEqual(center.pendingCount, 2, "skip writes nothing — both tasks stay pending")
    }

    func testDismissDontKnowRemovesCardAndClosesTheTask() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let audio = try TestFixtures.tempAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        let t1 = try await pool.write { db -> Int64 in
            let t1 = try self.insertTranscript(db, audioPath: audio.path, speakersJSON: self.speakersJSON())
            try VoiceLabelQueueQueries.enqueue(
                db, transcriptID: t1, clusterLabel: "Speaker 1", reason: .unknown, suggestedPersonID: nil, score: nil)
            return t1
        }

        let center = VoiceRegistryCenter()
        center.attach(dbPool: pool)
        await center.open(.queue(transcriptID: nil))
        let card = try XCTUnwrap(center.cards.first)

        await center.dismiss(card, .dontKnow)

        XCTAssertTrue(center.cards.isEmpty)
        XCTAssertEqual(center.pendingCount, 0)
        _ = t1
    }

    // MARK: - relabel

    func testRelabelEnqueuesAndReopensTheQueueForThatTranscript() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let audio = try TestFixtures.tempAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        // A cluster with an owner label — no pre-existing queue task —
        // matching the "not right, relabel it" rename-picker path.
        let t1 = try await pool.write { db -> Int64 in
            try self.insertTranscript(
                db, audioPath: audio.path,
                speakersJSON: #"[{"speaker":"Bob","embedding":[1,0],"label_source":"owner","clips":[{"start":1,"end":6}]}]"#)
        }

        let center = VoiceRegistryCenter()
        center.attach(dbPool: pool)
        XCTAssertTrue(center.cards.isEmpty)

        await center.relabel(transcriptID: t1, clusterLabel: "Bob")

        XCTAssertEqual(center.mode, .queue(transcriptID: t1))
        XCTAssertEqual(center.cards.map(\.transcriptID), [t1])
        XCTAssertEqual(center.cards.first?.reason, .relabel)
    }

    // MARK: - catch-up vs save (spec §4.1 retro scope)

    /// `refreshAfterSave` (the savedTick path) must skip audio-less tasks
    /// like `catchUp` does, but never run the retro relabeler — a save is
    /// not one of retro's three triggers (owner confirmation, an import
    /// person activated, app launch). `catchUp` (launch only) does run it.
    func testRefreshAfterSaveSkipsAudiolessTasksButNeverRetroRelabels() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }

        // t1: an unnamed cluster an active sample would confidently match —
        // no queue task, so only retro (not the skip sweep) could touch it.
        // t2: a queued task whose audio is gone — the skip sweep must still
        // run under `refreshAfterSave`.
        let (t1, t2) = try await pool.write { db -> (Int64, Int64) in
            let t1 = try self.insertTranscript(db, audioPath: nil, speakersJSON: self.speakersJSON(clips: nil))
            let t2 = try self.insertTranscript(db, audioPath: "/nonexistent.caf", speakersJSON: self.speakersJSON())
            try VoiceLabelQueueQueries.enqueue(
                db, transcriptID: t2, clusterLabel: "Speaker 1", reason: .unknown, suggestedPersonID: nil, score: nil)
            let alice = try XCTUnwrap(VoicePrintQueries.findOrCreate(db, personKey: "alice@example.com", displayName: "Alice").id)
            var sample = VoiceSample(personID: alice, embedding: VoicePrintEmbedding.encode([1, 0]),
                                     modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                     origin: .owner, anchor: true, status: .active)
            try VoiceSampleQueries.insert(db, &sample)
            return (t1, t2)
        }

        let center = VoiceRegistryCenter()
        center.attach(dbPool: pool)

        await center.refreshAfterSave()

        let (t1SpeakerAfterSave, t2PendingAfterSave) = try await pool.read { db in
            (try MeetingTranscriptQueries.fetch(db, id: t1)?.speakerEmbeddings?.first?.speaker,
             try VoiceLabelQueueQueries.pending(db, transcriptID: t2))
        }
        XCTAssertEqual(t1SpeakerAfterSave, "Speaker 1", "a save tick must never relabel")
        XCTAssertTrue(t2PendingAfterSave.isEmpty, "the audio-less-task skip sweep still runs on a save tick")

        await center.catchUp()

        let t1SpeakerAfterCatchUp = try await pool.read { db in
            try MeetingTranscriptQueries.fetch(db, id: t1)?.speakerEmbeddings?.first?.speaker
        }
        XCTAssertEqual(t1SpeakerAfterCatchUp, "Alice", "launch catch-up is the one that runs the full retro pass")
    }

    // MARK: - candidates (spec §3.1 ordering)

    /// Invited attendees the registry doesn't already know come first (their
    /// own group, sorted by name), then registry people (their own group,
    /// sorted by name) — never merged into one alphabetical list, so a
    /// just-met attendee always outranks an alphabetically-earlier but
    /// unrelated registry person.
    func testCandidatesOrderInvitedNotInRegistryBeforeRegistryPeopleEachSorted() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let audio = try TestFixtures.tempAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        _ = try await pool.write { db -> Int64 in
            let attendeesJSON = #"[{"email":"zoe@example.com","display_name":"Zoe","response_status":"accepted","slack_user_id":""},"# +
                #"{"email":"bob@example.com","display_name":"Bob","response_status":"accepted","slack_user_id":""}]"#
            try TestDatabase.insertCalendarEvent(
                db, id: "evt-1", organizerEmail: "bob@example.com", attendees: attendeesJSON)
            _ = try VoicePrintQueries.findOrCreate(db, personKey: "carol@example.com", displayName: "Carol")
            _ = try VoicePrintQueries.findOrCreate(db, personKey: "aaron@example.com", displayName: "Aaron")
            let t1 = try self.insertTranscript(db, audioPath: audio.path, speakersJSON: self.speakersJSON(), eventID: "evt-1")
            try VoiceLabelQueueQueries.enqueue(
                db, transcriptID: t1, clusterLabel: "Speaker 1", reason: .unknown, suggestedPersonID: nil, score: nil)
            return t1
        }

        let center = VoiceRegistryCenter()
        center.attach(dbPool: pool)
        await center.open(.queue(transcriptID: nil))

        let card = try XCTUnwrap(center.cards.first)
        XCTAssertEqual(card.candidates.map(\.displayName), ["Bob", "Zoe", "Aaron", "Carol"],
                       "invited-not-registered (sorted) first, then registry people (sorted) — groups never merged")
        XCTAssertEqual(card.candidates.map(\.inRegistry), [false, false, true, true])
    }

    /// The picker never offers a name without a reason: the owner ("Me")
    /// and this meeting's people first, then registry voices that actually
    /// sound like this cluster (ACTIVE samples only — a pending import
    /// does not count), then everyone else under their own heading.
    func testCandidatesGroupOwnerMeetingSimilarAndOtherVoices() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let audio = try TestFixtures.tempAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        try await pool.write { db in
            _ = try TestDatabase.insertGoogleAccount(db, email: "me@example.com")
            let attendeesJSON = #"[{"email":"zoe@example.com","display_name":"Zoe","response_status":"accepted","slack_user_id":""},"# +
                #"{"email":"dan@example.com","display_name":"Dan","response_status":"accepted","slack_user_id":""}]"#
            try TestDatabase.insertCalendarEvent(db, id: "evt-1", organizerEmail: "me@example.com", attendees: attendeesJSON)
            func person(_ key: String, _ name: String, _ vector: [Float]?, status: VoiceSampleStatus = .active) throws {
                let p = try VoicePrintQueries.findOrCreate(db, personKey: key, displayName: name)
                guard let vector else { return }
                var sample = VoiceSample(
                    personID: try XCTUnwrap(p.id), embedding: VoicePrintEmbedding.encode(vector),
                    modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                    origin: status == .active ? .owner : .imported, anchor: status == .active, status: status)
                try VoiceSampleQueries.insert(db, &sample)
            }
            try person("me@example.com", "Owner", [0, 1])
            try person("dan@example.com", "Dan", nil)
            try person("close@example.com", "Close", [1, 0.2])
            try person("closer@example.com", "Closer", [1, 0.05])
            try person("far@example.com", "Far", [-1, 0])
            try person("pending@example.com", "Pending", [1, 0], status: .pending)
            let tid = try self.insertTranscript(db, audioPath: audio.path, speakersJSON: self.speakersJSON(), eventID: "evt-1")
            try VoiceLabelQueueQueries.enqueue(
                db, transcriptID: tid, clusterLabel: "Speaker 1", reason: .unknown, suggestedPersonID: nil, score: nil)
        }

        let center = VoiceRegistryCenter()
        center.attach(dbPool: pool)
        await center.open(.queue(transcriptID: nil))

        let card = try XCTUnwrap(center.cards.first)
        XCTAssertEqual(card.candidateGroups.map(\.title), ["In this meeting", "Similar voices", "Other known voices"])
        XCTAssertEqual(card.candidateGroups.map { $0.choices.map(\.displayName) },
                       [["Owner", "Zoe", "Dan"], ["Closer", "Close"], ["Far", "Pending"]])
        XCTAssertEqual(card.candidates.first?.isOwner, true)
        XCTAssertEqual(card.candidates.filter(\.isOwner).count, 1)
    }

    /// Degenerate: an owner the registry doesn't know yet is still offered
    /// (from the invite list) — as "Me", first — never dropped.
    func testUnregisteredOwnerAttendeeIsOfferedFirstAsMe() async throws {
        let (pool, path) = try TestDatabase.createPool()
        defer { TestDatabase.cleanup(path: path) }
        let audio = try TestFixtures.tempAudioFile()
        defer { try? FileManager.default.removeItem(at: audio) }

        try await pool.write { db in
            _ = try TestDatabase.insertGoogleAccount(db, email: "me@example.com")
            let attendeesJSON = #"[{"email":"amy@example.com","display_name":"Amy","response_status":"accepted","slack_user_id":""}]"#
            try TestDatabase.insertCalendarEvent(db, id: "evt-1", organizerEmail: "me@example.com", attendees: attendeesJSON)
            let tid = try self.insertTranscript(db, audioPath: audio.path, speakersJSON: self.speakersJSON(), eventID: "evt-1")
            try VoiceLabelQueueQueries.enqueue(
                db, transcriptID: tid, clusterLabel: "Speaker 1", reason: .unknown, suggestedPersonID: nil, score: nil)
        }

        let center = VoiceRegistryCenter()
        center.attach(dbPool: pool)
        await center.open(.queue(transcriptID: nil))

        let card = try XCTUnwrap(center.cards.first)
        XCTAssertEqual(card.candidates.map(\.personKey), ["me@example.com", "amy@example.com"])
        XCTAssertEqual(card.candidates.map(\.isOwner), [true, false])
    }

    // MARK: - degenerate

    // A center that was never attach()ed must no-op cleanly, not crash —
    // e.g. AppState constructs it before the DB pool exists.
    func testMethodsBeforeAttachAreNoops() async throws {
        let center = VoiceRegistryCenter()

        await center.refresh()
        await center.catchUp()
        await center.refreshAfterSave()
        await center.open(.queue(transcriptID: nil))

        XCTAssertEqual(center.pendingCount, 0)
        XCTAssertTrue(center.cards.isEmpty)
        XCTAssertNil(center.lastError)
    }
}
