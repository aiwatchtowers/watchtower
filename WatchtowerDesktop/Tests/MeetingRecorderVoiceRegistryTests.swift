import Foundation
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The post-diarization voice-registry pass at the Center level: naming
/// confident clusters, the «Я» interplay (tie-break / veto / alike), the
/// label queue, self-training and the notification. Runs at a real time
/// scale (two 40 s windows) because the registry ignores clusters with less
/// than `minClusterSpeechSec` of speech.
@MainActor
final class MeetingRecorderVoiceRegistryTests: MeetingRecorderTestCase {

    // MARK: - Harness

    private static let windowSec = 40.0
    private static let totalSec = 80

    private struct Flow {
        let savedText: String
        let speakers: [SpeakerEmbedding]
        let written: VoiceIdentificationOutcome?
        let writtenTranscriptID: Int64?
        let loaderEventIDs: [String?]
        let notifier: FakeNotifier
    }

    /// The loader/writer closures are @Sendable, so their captures go
    /// through an actor.
    private actor Box {
        var eventIDs: [String?] = []
        var written: VoiceIdentificationOutcome?
        var transcriptID: Int64?
        func recordLoad(eventID: String?) { eventIDs.append(eventID) }
        func recordWrite(transcriptID id: Int64, outcome: VoiceIdentificationOutcome) { transcriptID = id; written = outcome }
    }

    private enum Activity {
        case none
        /// Mic-dominant bins before `untilSec`, system-dominant after.
        case micDominantUntil(Double)
        case micDominantEverywhere
    }

    private func writeActivity(_ activity: Activity, for audio: URL) throws {
        let line: (Double) -> String
        switch activity {
        case .none: return
        case .micDominantUntil(let until): line = { $0 < until ? "0.500000 0.010000" : "0.010000 0.500000" }
        case .micDominantEverywhere: line = { _ in "0.500000 0.010000" }
        }
        let bins = (0..<(Self.totalSec * 10)).map { line(Double($0) * MicActivity.binDuration) }
        try (bins.joined(separator: "\n") + "\n")
            .write(to: MicActivity.url(for: audio), atomically: true, encoding: .utf8)
    }

    /// Two windows: "привет" over 0–40 s, "ответ" over 40–80 s.
    private func runFlow(
        diarization: [SpeakerSegment],
        activity: Activity = .none,
        registry: VoiceRegistrySnapshot?,
        loaderFails: Bool = false,
        wireWriter: Bool = true,
        eventID: String? = nil,
        configure: (inout TranscriptionConfig) -> Void = { _ in }
    ) async throws -> Flow {
        let audio = try makeDummyAudioFile()
        defer {
            try? FileManager.default.removeItem(at: audio)
            removeSidecars(audio)
        }
        try writeActivity(activity, for: audio)
        let diarizer = FakeDiarizer()
        diarizer.segments = diarization
        let recorder = FakeRecorder()
        recorder.stopResult = RecordingResult(audioURL: audio, durationSec: Self.totalSec)
        let runner = TranscriptCapturingRunner(stdout: recapOKEnvelope)
        let notifier = FakeNotifier()
        let center = MeetingRecorderCenter(
            recorderFactory: { recorder },
            engineFactory: { _ in TestTranscriber(ScriptedEngine(texts: ["привет", "ответ"])) },
            diarizerFactory: { _ in diarizer },
            decode: stubDecode(sampleCount: Self.totalSec * TranscriptionConfig.sampleRate),
            runnerResolver: { runner },
            notifier: notifier,
            defaults: try isolatedDefaults(),
            recordingsDirectory: recordingsDir
        )
        let box = Box()
        if loaderFails {
            center.registryLoader = { id in
                await box.recordLoad(eventID: id)
                return nil
            }
        } else if let registry {
            center.registryLoader = { id in
                await box.recordLoad(eventID: id)
                return registry
            }
        }
        if wireWriter {
            center.registryWriter = { id, outcome in
                await box.recordWrite(transcriptID: id, outcome: outcome)
                return outcome.tasks.count
            }
        }
        var config = TranscriptionConfig()
        config.forcedLanguage = "en"
        config.windowSec = Self.windowSec
        config.overlapSec = 0
        config.boundarySnapSec = 0
        config.diarization = true
        configure(&config)
        await center.startRecording(eventID: eventID, title: "Sync")
        await center.stopAndProcess(config: config)

        let savedText = try XCTUnwrap(runner.savedTranscripts.first, "the recording must be saved")
        let speakers = runner.savedSpeakers.first.flatMap { $0 }.flatMap(SpeakerEmbeddings.decode) ?? []
        return Flow(savedText: savedText, speakers: speakers, written: await box.written,
                    writtenTranscriptID: await box.transcriptID, loaderEventIDs: await box.eventIDs,
                    notifier: notifier)
    }

    private func person(_ id: Int64, _ key: String, _ name: String) -> VoicePrint {
        VoicePrint(id: id, personKey: key, displayName: name)
    }

    private func anchor(
        _ id: Int64,
        person: Int64,
        _ vector: [Float],
        model: String = VoiceRegistryPolicy.embeddingModelVersion
    ) -> VoiceSample {
        VoiceSample(id: id, personID: person, embedding: VoicePrintEmbedding.encode(vector), modelVersion: model,
                    origin: .owner, anchor: true, status: .active)
    }

    private let twoClusters = [
        SpeakerSegment(speakerID: "A", startSec: 0, endSec: 40, embedding: [1, 0]),
        SpeakerSegment(speakerID: "B", startSec: 40, endSec: 80, embedding: [0, 1])
    ]

    // MARK: - Naming, queue, self-training, notification

    func testConfidentClusterIsNamedAndUnknownIsQueuedAfterSave() async throws {
        let flow = try await runFlow(
            diarization: twoClusters,
            registry: VoiceRegistrySnapshot(samples: [anchor(10, person: 1, [1, 0])],
                                            people: [1: person(1, "alice@example.com", "Alice")],
                                            invited: [1], ownerPersonIDs: []))

        XCTAssertEqual(flow.savedText, "[Alice] привет\n[Speaker 1] ответ")
        let alice = try XCTUnwrap(flow.speakers.first { $0.speaker == "Alice" })
        XCTAssertEqual(alice.labelSource, .auto)
        XCTAssertEqual(alice.personID, 1)
        XCTAssertEqual(alice.matchedSampleID, 10)
        XCTAssertEqual(alice.score ?? 0, 1, accuracy: 1e-4)
        XCTAssertEqual(alice.modelVersion, VoiceRegistryPolicy.embeddingModelVersion)
        XCTAssertEqual(alice.speechSec ?? 0, 40, accuracy: 1e-6)
        XCTAssertEqual(alice.clips, [ClipSpan(start: 0.3, end: 6.3)], "one segment → one capped clip")
        let unnamed = try XCTUnwrap(flow.speakers.first { $0.speaker == "Speaker 1" })
        XCTAssertEqual(unnamed.labelSource, VoiceLabelSource.none)
        XCTAssertEqual(unnamed.originalLabel, "Speaker 1")
        // The named cluster restores to a "Speaker N" no other cluster of the
        // recording carries — a rollback must never merge it into B.
        XCTAssertEqual(alice.originalLabel, "Speaker 2")

        XCTAssertEqual(flow.writtenTranscriptID, 7, "the writer runs against the saved transcript id")
        let written = try XCTUnwrap(flow.written)
        XCTAssertEqual(written.tasks.map(\.label), ["Speaker 1"])
        XCTAssertEqual(written.tasks.map(\.reason), [.unknown])
        XCTAssertEqual(written.autoSamples.map(\.personID), [1], "a strong long anchored match self-trains")
        XCTAssertEqual(written.autoSamples.first?.origin, .auto)
        XCTAssertEqual(written.autoSamples.first?.anchor, false)
        // The minted sample's cluster_label is the cluster's STABLE
        // originalLabel ("Speaker 2", per the `alice.originalLabel`
        // assertion above), never the rendered display name — the same
        // convention `VoiceLabelingQueries.confirm` uses (`cluster.restoreLabel`)
        // and what rollback's `rejectAutoLabel` looks the sample up by.
        XCTAssertEqual(written.autoSamples.first?.clusterLabel, "Speaker 2")
        XCTAssertEqual(flow.notifier.readyTitles, ["Sync"])
        XCTAssertEqual(flow.notifier.voiceLabelNotifications.count, 1)
        XCTAssertEqual(flow.notifier.voiceLabelNotifications.first?.count, 1)
        XCTAssertEqual(flow.notifier.voiceLabelNotifications.first?.transcriptID, 7)
    }

    func testVoiceNotificationsOffStillQueuesSilently() async throws {
        let flow = try await runFlow(diarization: twoClusters, registry: .empty) { $0.voiceNotifications = false }
        XCTAssertEqual(flow.written?.tasks.count, 2, "an empty registry queues every long cluster as unknown")
        XCTAssertTrue(flow.notifier.voiceLabelNotifications.isEmpty)
    }

    func testUnwiredWriterNeverNotifies() async throws {
        let flow = try await runFlow(diarization: twoClusters, registry: .empty, wireWriter: false)
        XCTAssertTrue(flow.notifier.voiceLabelNotifications.isEmpty, "nothing was queued")
    }

    func testShortClusterIsNeitherNamedNorQueued() async throws {
        let flow = try await runFlow(
            diarization: [SpeakerSegment(speakerID: "A", startSec: 0, endSec: 15, embedding: [1, 0]),
                          SpeakerSegment(speakerID: "B", startSec: 15, endSec: 80, embedding: [0, 1])],
            registry: VoiceRegistrySnapshot(samples: [anchor(10, person: 1, [1, 0])],
                                            people: [1: person(1, "alice@example.com", "Alice")],
                                            invited: [1], ownerPersonIDs: []))
        XCTAssertFalse(flow.savedText.contains("Alice"), "15 s of speech is below the match floor")
        XCTAssertEqual(flow.written?.tasks.count, 1, "only the long unknown cluster is queued")
    }

    func testOwnerClusterIsNeverRenamedByTheRegistry() async throws {
        // Mic-dominant cluster A → «Я» by RoleAssigner; the registry matches
        // A to Alice confidently, but Alice is not the owner.
        let flow = try await runFlow(
            diarization: [SpeakerSegment(speakerID: "A", startSec: 0, endSec: 80, embedding: [1, 0])],
            activity: .micDominantEverywhere,
            registry: VoiceRegistrySnapshot(samples: [anchor(10, person: 1, [1, 0])],
                                            people: [1: person(1, "alice@example.com", "Alice")],
                                            invited: [1], ownerPersonIDs: []))
        XCTAssertTrue(flow.savedText.contains("Я"))
        XCTAssertFalse(flow.savedText.contains("Alice"))
        XCTAssertEqual(flow.speakers.first?.labelSource, .owner, "«Я» is the role pass's label")
        XCTAssertEqual(flow.written?.tasks.count ?? 0, 0, "«Я» is never queued")
        XCTAssertEqual(flow.written?.autoSamples.count ?? 0, 0, "Alice must not learn from the owner's cluster")
    }

    func testRegistryFailureStillSavesPlainLabels() async throws {
        let flow = try await runFlow(
            diarization: [SpeakerSegment(speakerID: "A", startSec: 0, endSec: 80, embedding: [1, 0])],
            registry: nil) // unwired loader = registry off
        XCTAssertTrue(flow.savedText.contains("Speaker 1"))
        XCTAssertNil(flow.written, "registry off → nothing to persist")
    }

    /// Spec §2.6: a failed registry read switches identification OFF for the
    /// recording — it must never look like an empty registry and queue every
    /// cluster as unknown with a notification.
    func testFailingLoaderQueuesNothingAndNeverNotifies() async throws {
        let flow = try await runFlow(diarization: twoClusters, registry: nil, loaderFails: true)
        XCTAssertEqual(flow.loaderEventIDs.count, 1, "the loader was consulted")
        XCTAssertEqual(flow.savedText, "[Speaker 1] привет\n[Speaker 2] ответ")
        XCTAssertNil(flow.written, "a failed read persists no tasks and no samples")
        XCTAssertTrue(flow.notifier.voiceLabelNotifications.isEmpty)
        XCTAssertTrue(flow.speakers.allSatisfy { $0.labelSource == VoiceLabelSource.none })
    }

    func testVoiceRecognitionOffSkipsRegistry() async throws {
        let flow = try await runFlow(
            diarization: [SpeakerSegment(speakerID: "A", startSec: 0, endSec: 80, embedding: [1, 0])],
            registry: VoiceRegistrySnapshot(samples: [anchor(10, person: 1, [1, 0])],
                                            people: [1: person(1, "alice@example.com", "Alice")],
                                            invited: nil, ownerPersonIDs: [])) { $0.voiceRecognition = false }
        XCTAssertTrue(flow.loaderEventIDs.isEmpty, "the toggle off never reads the registry")
        XCTAssertTrue(flow.savedText.contains("Speaker 1"))
        XCTAssertNil(flow.written)
    }

    func testVoiceRecognitionTogglesReadFromDefaults() throws {
        let defaults = try isolatedDefaults()
        XCTAssertTrue(TranscriptionConfig.fromDefaults(defaults).voiceRecognition, "absent = on")
        XCTAssertTrue(TranscriptionConfig.fromDefaults(defaults).voiceNotifications, "absent = on")
        defaults.set(false, forKey: "transcription.voiceRecognition")
        defaults.set(false, forKey: "transcription.voiceNotifications")
        XCTAssertFalse(TranscriptionConfig.fromDefaults(defaults).voiceRecognition)
        XCTAssertFalse(TranscriptionConfig.fromDefaults(defaults).voiceNotifications)
    }

    // MARK: - «Я» interplay (ported from the single-centroid suite)

    /// «Я» (mic dominance) keeps absolute priority over a voice match when
    /// the owner is not identifiable.
    func testSelfClusterBeatsVoiceMatch() async throws {
        let flow = try await runFlow(
            diarization: twoClusters, activity: .micDominantUntil(40),
            registry: VoiceRegistrySnapshot(
                samples: [anchor(10, person: 1, [1, 0]), anchor(20, person: 2, [0, 1])],
                people: [1: person(1, "duplicate@example.com", "Owner Duplicate"),
                         2: person(2, "sasha@example.com", "Саша")],
                invited: [1, 2], ownerPersonIDs: []))
        XCTAssertEqual(flow.savedText, "[Я] привет\n[Саша] ответ")
    }

    /// Both clusters mic-dominant (meeting room): the owner's anchor matches
    /// the later one — «Я» goes to the owner-matched cluster, not the earliest.
    func testOwnerAnchorWinsSelfTieBreakEndToEnd() async throws {
        let flow = try await runFlow(
            diarization: twoClusters, activity: .micDominantEverywhere,
            registry: VoiceRegistrySnapshot(samples: [anchor(10, person: 1, [0, 1])],
                                            people: [1: person(1, "owner@example.com", "Owner")],
                                            invited: nil, ownerPersonIDs: [1]))
        XCTAssertEqual(flow.savedText, "[Speaker 1] привет\n[Я] ответ")
        XCTAssertEqual(flow.written?.autoSamples.map(\.personID), [1],
                       "an owner match rendered as «Я» still self-trains the owner")
    }

    /// Armed veto: the mic-dominant cluster confidently matches a colleague
    /// and does not resemble the owner → «Я» is withheld; the owner-matched
    /// cluster keeps the owner's display name.
    func testColleagueMatchedMicWinnerIsVetoedEndToEnd() async throws {
        let flow = try await runFlow(
            diarization: twoClusters, activity: .micDominantUntil(40),
            registry: VoiceRegistrySnapshot(
                samples: [anchor(10, person: 1, [1, 0]), anchor(20, person: 2, [0, 1])],
                people: [1: person(1, "colleague@example.com", "Коллега"), 2: person(2, "owner@example.com", "Owner")],
                invited: nil, ownerPersonIDs: [2]))
        XCTAssertEqual(flow.savedText, "[Коллега] привет\n[Owner] ответ")
    }

    /// No owner person in the registry (a name-keyed own entry) → owner
    /// identity alone must not arm the veto; «Я» keeps its legacy priority.
    func testUnidentifiedOwnerDoesNotArmVetoAndSelfSurvives() async throws {
        let flow = try await runFlow(
            diarization: twoClusters, activity: .micDominantUntil(40),
            registry: VoiceRegistrySnapshot(samples: [anchor(10, person: 1, [1, 0])],
                                            people: [1: person(1, "owner", "owner")],
                                            invited: nil, ownerPersonIDs: []))
        XCTAssertEqual(flow.savedText, "[Я] привет\n[Speaker 1] ответ")
    }

    /// Mixed identity: another person wins the global match for the owner's
    /// cluster, but an owner anchor also matches it ≥ confident → the
    /// cluster is veto-exempt and «Я» survives (the conservative owner rule).
    func testOwnerVoiceAlikeClusterIsNotVetoed() async throws {
        let flow = try await runFlow(
            diarization: twoClusters, activity: .micDominantUntil(40),
            registry: VoiceRegistrySnapshot(
                samples: [anchor(10, person: 1, [1, 0]), anchor(20, person: 2, [0.85, 0.53])],
                people: [1: person(1, "owner", "owner"), 2: person(2, "owner@example.com", "Owner")],
                invited: nil, ownerPersonIDs: [2]))
        XCTAssertEqual(flow.savedText, "[Я] привет\n[Speaker 1] ответ")
    }

    /// An owner anchor from another embedding model (or of another
    /// dimension) is unusable this run and must not arm the veto.
    func testUnusableOwnerAnchorDoesNotArmVeto() async throws {
        for ownerAnchor in [anchor(20, person: 2, [0, 1], model: "older-model"), anchor(20, person: 2, [0, 1, 0])] {
            let flow = try await runFlow(
                diarization: twoClusters, activity: .micDominantUntil(40),
                registry: VoiceRegistrySnapshot(
                    samples: [anchor(10, person: 1, [1, 0]), ownerAnchor],
                    people: [1: person(1, "colleague@example.com", "Коллега"),
                             2: person(2, "owner@example.com", "Owner")],
                    invited: nil, ownerPersonIDs: [2]))
            XCTAssertEqual(flow.savedText, "[Я] привет\n[Speaker 1] ответ")
        }
    }

    /// Event-linked: the eventID reaches the loader, a non-invited
    /// stranger's strong match is only a suggestion (queued, not named), and
    /// the owner is always invited.
    func testEventInvitedSetDemotesStrangerButKeepsOwner() async throws {
        let flow = try await runFlow(
            diarization: twoClusters, activity: .micDominantEverywhere,
            registry: VoiceRegistrySnapshot(
                samples: [anchor(10, person: 1, [1, 0]), anchor(20, person: 2, [0, 1])],
                people: [1: person(1, "stranger@example.com", "Чужой"), 2: person(2, "owner@example.com", "Owner")],
                invited: [9], ownerPersonIDs: [2]),
            eventID: "evt-1")
        XCTAssertEqual(flow.savedText, "[Speaker 1] привет\n[Я] ответ")
        XCTAssertEqual(flow.loaderEventIDs, ["evt-1"], "the job's eventID must reach the registry loader")
        let task = try XCTUnwrap(flow.written?.tasks.first)
        XCTAssertEqual(task.label, "Speaker 1")
        XCTAssertEqual(task.reason, .unsure)
        XCTAssertEqual(task.personID, 1)
    }

    /// Spec §5 end to end: a colleague's imported sample names cluster A's
    /// voice as someone else — the recording neither labels A silently nor
    /// self-trains from it; it queues a `conflict` card instead.
    func testImportedSampleOfAnotherPersonQueuesConflictInsteadOfLabeling() async throws {
        var imported = anchor(20, person: 2, [1, 0.1])
        imported = VoiceSample(id: imported.id, personID: 2, embedding: imported.embedding,
                               modelVersion: imported.modelVersion, origin: .imported, anchor: false, status: .pending)
        let flow = try await runFlow(
            diarization: twoClusters,
            registry: VoiceRegistrySnapshot(
                samples: [anchor(10, person: 1, [1, 0]), imported],
                people: [1: person(1, "alice@example.com", "Alice"), 2: person(2, "bob@example.com", "Bob")],
                invited: [1, 2], ownerPersonIDs: []))
        XCTAssertEqual(flow.savedText, "[Speaker 1] привет\n[Speaker 2] ответ", "no silent label")
        let written = try XCTUnwrap(flow.written)
        let conflict = try XCTUnwrap(written.tasks.first { $0.reason == .conflict })
        XCTAssertEqual(conflict.personID, 1, "the local match is the suggestion")
        XCTAssertTrue(written.autoSamples.isEmpty, "a disputed voice never self-trains")
    }

    /// N3 end to end: once the owner settles such a conflict on its card, the
    /// next recording of that voice is named and self-trains again — the
    /// dispute is raised the first time the voice appears, not forever.
    func testSettledConflictLetsTheNextRecordingLabelAndSelfTrain() async throws {
        let db = try TestDatabase.create()
        let registry = try await db.write { conn -> VoiceRegistrySnapshot in
            let alice = try VoicePrintQueries.findOrCreate(conn, personKey: "alice@example.com", displayName: "Alice")
            let bob = try VoicePrintQueries.findOrCreate(conn, personKey: "bob@example.com", displayName: "Bob")
            var local = VoiceSample(personID: try XCTUnwrap(alice.id), embedding: VoicePrintEmbedding.encode([1, 0]),
                                    modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                    origin: .owner, anchor: true, status: .active)
            try VoiceSampleQueries.insert(conn, &local)
            var claim = VoiceSample(personID: try XCTUnwrap(bob.id), embedding: VoicePrintEmbedding.encode([1, 0.1]),
                                    modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
                                    origin: .imported, anchor: false, status: .pending)
            try VoiceSampleQueries.insert(conn, &claim)
            let utterances = [TranscriptUtterance(idx: 0, startSec: 0, endSec: 1, speaker: "Speaker 1", text: "hi")]
            try TestDatabase.insertMeetingTranscript(
                conn, transcriptText: TranscriptSegments.render(utterances),
                segmentsJSON: try XCTUnwrap(TranscriptSegments.encode(utterances)),
                speakersJSON: #"[{"speaker":"Speaker 1","embedding":[1,0],"speech_sec":40}]"#)
            let tid = conn.lastInsertedRowID
            try VoiceLabelQueueQueries.enqueue(conn, transcriptID: tid, clusterLabel: "Speaker 1", reason: .conflict,
                                               suggestedPersonID: alice.id, score: 1)
            let task = try XCTUnwrap(VoiceLabelQueueQueries.pending(conn).first)
            _ = try VoiceLabelingQueries.confirm(conn, taskID: task.id, transcriptID: tid, clusterLabel: "Speaker 1",
                                                 personKey: "alice@example.com", displayName: "Alice")
            let people = Dictionary(uniqueKeysWithValues: try VoicePrintQueries.fetchAll(conn).compactMap { p in
                p.id.map { ($0, p) }
            })
            return VoiceRegistrySnapshot(samples: try VoiceSampleQueries.fetchUsable(conn), people: people,
                                         invited: nil, ownerPersonIDs: [])
        }

        let flow = try await runFlow(diarization: twoClusters, registry: registry)
        XCTAssertEqual(flow.savedText, "[Alice] привет\n[Speaker 1] ответ")
        let written = try XCTUnwrap(flow.written)
        XCTAssertFalse(written.tasks.contains { $0.reason == .conflict }, "the settled dispute is not raised again")
        XCTAssertFalse(written.autoSamples.isEmpty, "the voice self-trains again")
    }
}
