import XCTest
@testable import WatchtowerDesktop

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
}

final class TranscriptSaveServiceTests: XCTestCase {

    private let envelopeJSON = """
    {"transcript_id":7,"event_id":"evt-1","title":"Weekly","recap_ok":true,"recap_error":""}
    """

    // MARK: - save: argument construction

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

        guard let args = fake.invocations.first else {
            return XCTFail("no invocation recorded")
        }
        // ["meeting-prep","transcript","save","--transcript-file",<path>,
        //  "--audio","/tmp/a.wav","--duration","1800","--event-id","evt-1",
        //  "--title","Weekly","--lang-stats","{\"ru\":0.8}"]
        XCTAssertEqual(args.count, 15)
        XCTAssertEqual(args[0], "meeting-prep")
        XCTAssertEqual(args[1], "transcript")
        XCTAssertEqual(args[2], "save")
        XCTAssertEqual(args[3], "--transcript-file")
        XCTAssertFalse(args[4].isEmpty)
        XCTAssertEqual(args[5], "--audio")
        XCTAssertEqual(args[6], "/tmp/a.wav")
        XCTAssertEqual(args[7], "--duration")
        XCTAssertEqual(args[8], "1800")
        XCTAssertEqual(args[9], "--event-id")
        XCTAssertEqual(args[10], "evt-1")
        XCTAssertEqual(args[11], "--title")
        XCTAssertEqual(args[12], "Weekly")
        XCTAssertEqual(args[13], "--lang-stats")
        XCTAssertEqual(args[14], "{\"ru\":0.8}")
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

        guard let args = fake.invocations.first else {
            return XCTFail("no invocation recorded")
        }
        XCTAssertFalse(args.contains("--event-id"))
        XCTAssertFalse(args.contains("--title"))
        // ["meeting-prep","transcript","save","--transcript-file",<path>,
        //  "--audio","/tmp/a.wav","--duration","60","--lang-stats","{}"]
        XCTAssertEqual(args.count, 11)
        XCTAssertEqual(args[9], "--lang-stats")
        XCTAssertEqual(args[10], "{}")
    }

    // MARK: - save: segments file

    func test_saveWritesSegmentsFileNextToTranscript() async throws {
        let utterances = [
            TranscriptUtterance(idx: 0, startSec: 0, endSec: 2, speaker: "Я", text: "привет"),
            TranscriptUtterance(idx: 1, startSec: 2, endSec: 5, speaker: "Speaker 1", text: "ответ")
        ]
        let envelope = Data(envelopeJSON.utf8)
        var segmentsContentDuringRun: String?
        var segmentsPathDuringRun: String?
        let runner = ClosureCLIRunner { args in
            guard let idx = args.firstIndex(of: "--segments-file"), args.indices.contains(idx + 1) else {
                XCTFail("--segments-file flag missing")
                return envelope
            }
            let path = args[idx + 1]
            segmentsPathDuringRun = path
            segmentsContentDuringRun = try String(contentsOfFile: path, encoding: .utf8)
            return envelope
        }
        let svc = TranscriptSaveService(runner: runner)

        _ = try await svc.save(
            transcriptText: "[Я] привет\n[Speaker 1] ответ",
            utterances: utterances,
            audioPath: "/tmp/a.wav",
            durationSec: 5,
            eventID: nil,
            title: nil,
            langStatsJSON: "{}"
        )

        let content = try XCTUnwrap(segmentsContentDuringRun)
        XCTAssertEqual(TranscriptSegments.decode(content), utterances,
                       "the segments file must round-trip the utterances")
        let path = try XCTUnwrap(segmentsPathDuringRun)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                       "the temp segments file must be removed after save")
    }

    func test_saveOmitsSegmentsFileWhenUtterancesNil() async throws {
        let fake = FakeCLIRunner(stdout: Data(envelopeJSON.utf8))
        let svc = TranscriptSaveService(runner: fake)

        _ = try await svc.save(
            transcriptText: "plain",
            utterances: nil,
            audioPath: "/tmp/a.wav",
            durationSec: 60,
            eventID: nil,
            title: nil,
            langStatsJSON: "{}"
        )

        let args = try XCTUnwrap(fake.invocations.first)
        XCTAssertFalse(args.contains("--segments-file"))
    }

    func test_saveOmitsSegmentsFileWhenUtterancesEmpty() async throws {
        // Degenerate but valid: an empty utterance array must behave like nil
        // (no --segments-file), never ship an empty JSON array the CLI would
        // reject and warn about.
        let fake = FakeCLIRunner(stdout: Data(envelopeJSON.utf8))
        let svc = TranscriptSaveService(runner: fake)

        _ = try await svc.save(
            transcriptText: "plain",
            utterances: [],
            audioPath: "/tmp/a.wav",
            durationSec: 60,
            eventID: nil,
            title: nil,
            langStatsJSON: "{}"
        )

        let args = try XCTUnwrap(fake.invocations.first)
        XCTAssertFalse(args.contains("--segments-file"))
    }

    // MARK: - save: temp file lifecycle

    func test_saveTranscriptFileExistsDuringRunAndIsRemovedAfter() async throws {
        let envelope = Data(envelopeJSON.utf8)
        var contentDuringRun: String?
        var pathDuringRun: String?
        let runner = ClosureCLIRunner { args in
            guard let idx = args.firstIndex(of: "--transcript-file"),
                  args.indices.contains(idx + 1) else {
                XCTFail("--transcript-file flag missing")
                return envelope
            }
            let path = args[idx + 1]
            pathDuringRun = path
            contentDuringRun = try String(contentsOfFile: path, encoding: .utf8)
            return envelope
        }
        let svc = TranscriptSaveService(runner: runner)

        _ = try await svc.save(
            transcriptText: "the full transcript body",
            audioPath: "/tmp/a.wav",
            durationSec: 5,
            eventID: nil,
            title: nil,
            langStatsJSON: "{}"
        )

        XCTAssertEqual(contentDuringRun, "the full transcript body")
        let path = try XCTUnwrap(pathDuringRun)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: path),
            "temp transcript file must be removed after save"
        )
    }

    func test_saveRemovesTempFileWhenRunnerThrows() async {
        var pathDuringRun: String?
        let runner = ClosureCLIRunner { args in
            if let idx = args.firstIndex(of: "--transcript-file"), args.indices.contains(idx + 1) {
                pathDuringRun = args[idx + 1]
            }
            throw CLIRunnerError.nonZeroExit(code: 1, stderr: "boom")
        }
        let svc = TranscriptSaveService(runner: runner)

        do {
            _ = try await svc.save(
                transcriptText: "x", audioPath: "/tmp/a.wav", durationSec: 1,
                eventID: nil, title: nil, langStatsJSON: "{}"
            )
            XCTFail("expected throw")
        } catch {
            // expected
        }
        if let path = pathDuringRun {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        } else {
            XCTFail("runner never saw --transcript-file")
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
        XCTAssertNil(result.segmentsOK, "an older-CLI envelope without segments fields must still decode")
        XCTAssertNil(result.segmentsError)
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

        XCTAssertEqual(result.segmentsOK, false)
        XCTAssertEqual(result.segmentsError, "segments do not render to the transcript text")
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
}
