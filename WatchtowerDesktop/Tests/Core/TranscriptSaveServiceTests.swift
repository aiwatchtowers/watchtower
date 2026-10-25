import XCTest
@testable import WatchtowerCore
import WatchtowerTestSupport

/// Closure-driven `CLIRunnerProtocol` double: lets a test inspect the world
/// (e.g. read the temp transcript file) at the moment `run` executes.
private final class ClosureCLIRunner: CLIRunnerProtocol {
    private let onRun: ([String]) async throws -> Data
    private(set) var invocations: [[String]] = []

    init(onRun: @escaping ([String]) async throws -> Data) {
        self.onRun = onRun
    }

    func run(args: [String]) async throws -> Data {
        invocations.append(args)
        return try await onRun(args)
    }

    func run(args: [String], stdin: Data) async throws -> Data {
        stdinInputs.append(stdin)
        return try await run(args: args)
    }

    private(set) var stdinInputs: [Data] = []
}

final class TranscriptSaveServiceTests: XCTestCase {

    private let envelopeJSON = """
    {"transcript_id":7,"event_id":"evt-1","title":"Weekly","recap_ok":true,"recap_error":""}
    """

    // MARK: - save: argument construction

    /// The `--stdin` object the save sent, decoded.
    private func payload(_ fake: FakeCLIRunner) throws -> [String: Any] {
        let data = try XCTUnwrap(fake.stdinInputs.first, "save sends its object on stdin")
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The JSON text of one payload key; nil for null.
    private func json(_ value: Any?) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        return String(bytes: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)
    }

    func test_saveArgOrderWithAllFlags() async throws {
        let fake = FakeCLIRunner(stdout: Data(envelopeJSON.utf8))
        let svc = TranscriptSaveService(runner: fake)

        _ = try await svc.save(
            transcriptText: "hello transcript",
            audioPath: "/tmp/a.wav",
            durationSec: 1800,
            eventID: "evt-1",
            title: "Weekly",
            langStatsJSON: "{\"ru\":0.8}"
        )

        // #604 S7: the transcript rides stdin (`--stdin`), never a temp file.
        XCTAssertEqual(fake.invocations.first, [
            "meeting-prep", "transcript", "save", "--stdin",
            "--audio", "/tmp/a.wav", "--duration", "1800", "--event-id", "evt-1",
            "--title", "Weekly", "--lang-stats", "{\"ru\":0.8}"
        ])
        let sent = try payload(fake)
        XCTAssertEqual(sent["transcript"] as? String, "hello transcript")
        XCTAssertNil(try json(sent["segments"]))
        XCTAssertNil(try json(sent["speakers"]))
    }

    func test_saveOmitsOptionalFlagsWhenNil() async throws {
        let fake = FakeCLIRunner(stdout: Data(envelopeJSON.utf8))
        let svc = TranscriptSaveService(runner: fake)

        _ = try await svc.save(
            transcriptText: "hello",
            audioPath: "/tmp/a.wav",
            durationSec: 60,
            eventID: nil,
            title: nil,
            langStatsJSON: "{}"
        )

        XCTAssertEqual(fake.invocations.first, [
            "meeting-prep", "transcript", "save", "--stdin",
            "--audio", "/tmp/a.wav", "--duration", "60", "--lang-stats", "{}"
        ])
    }

    // MARK: - save: segments

    func test_saveSendsSegmentsInThePayload() async throws {
        let utterances = [
            TranscriptUtterance(idx: 0, startSec: 0, endSec: 2, speaker: "Я", text: "привет"),
            TranscriptUtterance(idx: 1, startSec: 2, endSec: 5, speaker: "Speaker 1", text: "ответ")
        ]
        let fake = FakeCLIRunner(stdout: Data(envelopeJSON.utf8))
        let svc = TranscriptSaveService(runner: fake)

        _ = try await svc.save(
            transcriptText: "[Я] привет\n[Speaker 1] ответ",
            utterances: utterances,
            audioPath: "/tmp/a.wav",
            durationSec: 5,
            eventID: nil,
            title: nil,
            langStatsJSON: "{}"
        )

        let segments = try XCTUnwrap(try json(try payload(fake)["segments"]))
        XCTAssertEqual(TranscriptSegments.decode(segments), utterances, "the segments round-trip the utterances")
    }

    func test_saveSendsNoSegmentsWhenUtterancesNilOrEmpty() async throws {
        // Degenerate but valid: an empty utterance array behaves like nil,
        // never an empty JSON array the CLI would reject and warn about.
        for utterances in [nil, [TranscriptUtterance]()] {
            let fake = FakeCLIRunner(stdout: Data(envelopeJSON.utf8))
            _ = try await TranscriptSaveService(runner: fake).save(
                transcriptText: "plain", utterances: utterances, audioPath: "/tmp/a.wav", durationSec: 60,
                eventID: nil, title: nil, langStatsJSON: "{}")
            XCTAssertNil(try json(try payload(fake)["segments"]))
        }
    }

    // MARK: - save: no temp files

    func test_saveWritesNoTempFile() async throws {
        let tmp = FileManager.default.temporaryDirectory
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: tmp.path))
        var newDuringRun: Set<String> = []
        let runner = ClosureCLIRunner { _ in
            let now = Set(try FileManager.default.contentsOfDirectory(atPath: tmp.path))
            newDuringRun = now.subtracting(before).filter { name in
                StaleTempSweep.prefixes.contains { name.hasPrefix($0) }
            }
            return Data(self.envelopeJSON.utf8)
        }
        _ = try await TranscriptSaveService(runner: runner).save(
            transcriptText: "the full transcript body", audioPath: "/tmp/a.wav", durationSec: 5,
            eventID: nil, title: nil, langStatsJSON: "{}")
        XCTAssertEqual(newDuringRun, [], "nothing of the transcript lands in the temp directory")
        let sent = try XCTUnwrap(runner.stdinInputs.first)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        XCTAssertEqual(object["transcript"] as? String, "the full transcript body")
    }

    func test_saveThrowsWhenRunnerThrows() async {
        let runner = ClosureCLIRunner { _ in throw CLIRunnerError.nonZeroExit(code: 1, stderr: "boom") }
        do {
            _ = try await TranscriptSaveService(runner: runner).save(
                transcriptText: "x", audioPath: "/tmp/a.wav", durationSec: 1,
                eventID: nil, title: nil, langStatsJSON: "{}")
            XCTFail("expected throw")
        } catch {
            // expected
        }
    }

    // MARK: - save: envelope decoding

    func test_saveDecodesFailedRecapEnvelope() async throws {
        let payload = """
        {"transcript_id":7,"event_id":"","title":"Ad hoc","recap_ok":false,"recap_error":"boom"}
        """
        let fake = FakeCLIRunner(stdout: Data(payload.utf8))
        let svc = TranscriptSaveService(runner: fake)

        let result = try await svc.save(
            transcriptText: "t", audioPath: "/tmp/a.wav", durationSec: 10,
            eventID: nil, title: "Ad hoc", langStatsJSON: "{}"
        )

        XCTAssertEqual(result.transcriptID, 7)
        XCTAssertFalse(result.recapOK)
        XCTAssertEqual(result.recapError, "boom")
        XCTAssertTrue(result.segmentsOK, "an older-CLI envelope without segments fields must decode as not-dropped")
        XCTAssertNil(result.segmentsError)
        XCTAssertFalse(result.recapSkipped, "an envelope without recap_skipped must decode as not-skipped")
    }

    func test_saveDecodesRecapSkippedEnvelope() async throws {
        let payload = """
        {"transcript_id":7,"event_id":"","title":"Ad hoc","recap_ok":false,\
        "recap_error":"transcript too short (12 chars): recap skipped","recap_skipped":true}
        """
        let fake = FakeCLIRunner(stdout: Data(payload.utf8))
        let svc = TranscriptSaveService(runner: fake)

        let result = try await svc.save(
            transcriptText: "t", audioPath: "/tmp/a.wav", durationSec: 10,
            eventID: nil, title: "Ad hoc", langStatsJSON: "{}"
        )

        XCTAssertFalse(result.recapOK)
        XCTAssertTrue(result.recapSkipped)
    }

    func test_saveDecodesDroppedSegmentsEnvelope() async throws {
        let payload = """
        {"transcript_id":7,"event_id":"","title":"Ad hoc","recap_ok":true,"recap_error":"",\
        "segments_ok":false,"segments_error":"segments do not render to the transcript text"}
        """
        let fake = FakeCLIRunner(stdout: Data(payload.utf8))
        let svc = TranscriptSaveService(runner: fake)

        let result = try await svc.save(
            transcriptText: "t", audioPath: "/tmp/a.wav", durationSec: 10,
            eventID: nil, title: "Ad hoc", langStatsJSON: "{}"
        )

        XCTAssertFalse(result.segmentsOK)
        XCTAssertEqual(result.segmentsError, "segments do not render to the transcript text")
        XCTAssertEqual(result.chapters, .notAttempted, "no chapters keys → chapters not attempted")
        XCTAssertNil(result.chaptersError)
    }

    func test_saveDecodesFailedChaptersEnvelope() async throws {
        // Auto-chapters failure after save is envelope-only (the spec'd
        // channel) — the decoder must surface it so the notification can.
        let payload = """
        {"transcript_id":7,"event_id":"","title":"Ad hoc","recap_ok":true,"recap_error":"",\
        "segments_ok":true,"segments_error":"","chapters_ok":false,"chapters_error":"AI generation: boom"}
        """
        let fake = FakeCLIRunner(stdout: Data(payload.utf8))
        let svc = TranscriptSaveService(runner: fake)

        let result = try await svc.save(
            transcriptText: "t", audioPath: "/tmp/a.wav", durationSec: 10,
            eventID: nil, title: "Ad hoc", langStatsJSON: "{}"
        )

        XCTAssertTrue(result.recapOK)
        XCTAssertEqual(result.chapters, .failed)
        XCTAssertEqual(result.chaptersError, "AI generation: boom")
    }

    // MARK: - save: error propagation

    func test_savePropagatesRunnerError() async {
        let fake = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "db locked"))
        let svc = TranscriptSaveService(runner: fake)

        do {
            _ = try await svc.save(
                transcriptText: "t", audioPath: "/tmp/a.wav", durationSec: 10,
                eventID: nil, title: nil, langStatsJSON: "{}"
            )
            XCTFail("expected throw")
        } catch CLIRunnerError.nonZeroExit(let code, _) {
            XCTAssertEqual(code, 1)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: - retryRecap

    func test_retryRecapArgsAndDecode() async throws {
        let fake = FakeCLIRunner(stdout: Data(envelopeJSON.utf8))
        let svc = TranscriptSaveService(runner: fake)

        let result = try await svc.retryRecap(transcriptID: 7)

        XCTAssertEqual(fake.invocations.first, ["meeting-prep", "transcript", "recap", "7"])
        XCTAssertEqual(result.transcriptID, 7)
        XCTAssertTrue(result.recapOK)
        XCTAssertEqual(result.recapError, "")
    }

    func test_retryRecapPropagatesRunnerError() async {
        let fake = FakeCLIRunner(error: CLIRunnerError.binaryNotFound)
        let svc = TranscriptSaveService(runner: fake)

        do {
            _ = try await svc.retryRecap(transcriptID: 3)
            XCTFail("expected throw")
        } catch CLIRunnerError.binaryNotFound {
            // expected
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: - generateNotes

    func test_generateNotesInvokesCLIAndDecodesEnvelope() async throws {
        let mock = FakeCLIRunner(stdout: Data("""
            {"transcript_id": 7, "notes_md": "# Sync\\n\\n## Summary\\nShipped."}
            """.utf8))
        let service = TranscriptSaveService(runner: mock)

        let result = try await service.generateNotes(transcriptID: 7)

        XCTAssertEqual(result.transcriptID, 7)
        XCTAssertTrue(result.notesMD.contains("## Summary"))
        XCTAssertEqual(mock.invocations.first, ["meeting-prep", "transcript", "notes", "7"])
    }

    func test_generateNotesPropagatesRunnerError() async {
        let fake = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "boom"))
        let svc = TranscriptSaveService(runner: fake)

        do {
            _ = try await svc.generateNotes(transcriptID: 3)
            XCTFail("expected throw")
        } catch CLIRunnerError.nonZeroExit(let code, _) {
            XCTAssertEqual(code, 1)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: - generateChapters

    func test_generateChaptersInvokesCLIAndDecodesEnvelope() async throws {
        let mock = FakeCLIRunner(stdout: Data("""
            {"transcript_id": 7, "chapters_json": "{\\"overall_summary\\":\\"o\\",\\"chapters\\":[]}"}
            """.utf8))
        let service = TranscriptSaveService(runner: mock)

        let result = try await service.generateChapters(transcriptID: 7)

        XCTAssertEqual(result.transcriptID, 7)
        XCTAssertTrue(result.chaptersJSON.contains("overall_summary"))
        XCTAssertEqual(mock.invocations.first, ["meeting-prep", "transcript", "chapters", "7"])
    }

    func test_generateChaptersPropagatesRunnerError() async {
        let fake = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "no segments"))
        let svc = TranscriptSaveService(runner: fake)

        do {
            _ = try await svc.generateChapters(transcriptID: 3)
            XCTFail("expected throw")
        } catch CLIRunnerError.nonZeroExit(let code, _) {
            XCTAssertEqual(code, 1)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: - generateFollowup

    func test_generateFollowupChapterArgsAndDecode() async throws {
        let mock = FakeCLIRunner(stdout: Data("""
            {"transcript_id": 7, "chapter": 2, "draft": "Team, per the sync…"}
            """.utf8))
        let service = TranscriptSaveService(runner: mock)

        let result = try await service.generateFollowup(transcriptID: 7, chapter: 2)

        XCTAssertEqual(result.transcriptID, 7)
        XCTAssertEqual(result.chapter, 2)
        XCTAssertEqual(result.draft, "Team, per the sync…")
        XCTAssertEqual(mock.invocations.first,
                       ["meeting-prep", "transcript", "followup", "7", "--chapter", "2"])
    }

    func test_generateFollowupWholeMeetingOmitsChapterFlag() async throws {
        let mock = FakeCLIRunner(stdout: Data("""
            {"transcript_id": 7, "chapter": null, "draft": "whole-meeting draft"}
            """.utf8))
        let service = TranscriptSaveService(runner: mock)

        let result = try await service.generateFollowup(transcriptID: 7, chapter: nil)

        XCTAssertNil(result.chapter)
        XCTAssertEqual(result.draft, "whole-meeting draft")
        XCTAssertEqual(mock.invocations.first, ["meeting-prep", "transcript", "followup", "7"])
    }

    func test_generateFollowupPropagatesRunnerError() async {
        let fake = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "no chapters"))
        let svc = TranscriptSaveService(runner: fake)

        do {
            _ = try await svc.generateFollowup(transcriptID: 3, chapter: nil)
            XCTFail("expected throw")
        } catch CLIRunnerError.nonZeroExit(let code, _) {
            XCTAssertEqual(code, 1)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    // MARK: - speakers (voice embeddings)

    func test_saveSendsSpeakersWhenEmbeddingsPresent() async throws {
        let speakers = [
            SpeakerEmbedding(speaker: "Я", embedding: [0, 1]),
            SpeakerEmbedding(speaker: "Speaker 1", embedding: [1, 0])
        ]
        let fake = FakeCLIRunner(stdout: Data(envelopeJSON.utf8))
        _ = try await TranscriptSaveService(runner: fake).save(
            transcriptText: "[Я] привет\n[Speaker 1] ответ",
            utterances: [
                TranscriptUtterance(idx: 0, startSec: 0, endSec: 2, speaker: "Я", text: "привет"),
                TranscriptUtterance(idx: 1, startSec: 2, endSec: 5, speaker: "Speaker 1", text: "ответ")
            ],
            speakers: speakers,
            audioPath: "/tmp/a.wav",
            durationSec: 5,
            eventID: nil,
            title: nil,
            langStatsJSON: "{}"
        )
        let sent = try XCTUnwrap(try json(try payload(fake)["speakers"]))
        XCTAssertEqual(SpeakerEmbeddings.decode(sent), speakers, "the speakers round-trip the embeddings")
    }

    func test_saveSendsNoSpeakersWhenNil() async throws {
        let fake = FakeCLIRunner(stdout: Data(envelopeJSON.utf8))
        _ = try await TranscriptSaveService(runner: fake).save(
            transcriptText: "hello", audioPath: "/tmp/a.wav", durationSec: 1,
            eventID: nil, title: nil, langStatsJSON: "{}")
        XCTAssertNil(try json(try payload(fake)["speakers"]), "nil speakers → null, legacy behavior")
    }
}
