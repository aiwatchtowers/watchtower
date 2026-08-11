import XCTest
@testable import WatchtowerDesktop

final class DictationCleanServiceTests: XCTestCase {
    func testIdeaModeDecodesTitleAndBody() async throws {
        let runner = FakeCLIRunner(stdout: Data("""
        {"mode":"idea","title":"T","body":"B"}
        """.utf8))
        let service = DictationCleanService(runner: runner)

        let result = try await service.clean(transcript: "some words", mode: .idea)

        XCTAssertEqual(result, DictationCleanResult(title: "T", text: "B"))
    }

    func testNoteModeMapsMarkdownToTextWithNilTitle() async throws {
        let runner = FakeCLIRunner(stdout: Data("""
        {"mode":"note","markdown":"# Heading\\nbody"}
        """.utf8))
        let service = DictationCleanService(runner: runner)

        let result = try await service.clean(transcript: "some words", mode: .note)

        XCTAssertEqual(result, DictationCleanResult(title: nil, text: "# Heading\nbody"))
    }

    func testChatModeMapsTextWithNilTitle() async throws {
        let runner = FakeCLIRunner(stdout: Data("""
        {"mode":"chat","text":"reply text"}
        """.utf8))
        let service = DictationCleanService(runner: runner)

        let result = try await service.clean(transcript: "some words", mode: .chat)

        XCTAssertEqual(result, DictationCleanResult(title: nil, text: "reply text"))
    }

    func testTranscriptTravelsViaTempFileRemovedAfterCall() async throws {
        let runner = TranscriptCapturingRunner(stdout: Data("""
        {"mode":"chat","text":"reply text"}
        """.utf8))
        let service = DictationCleanService(runner: runner)

        _ = try await service.clean(transcript: "captured transcript text", mode: .chat)

        XCTAssertEqual(runner.savedTranscripts, ["captured transcript text"])
        guard let invocation = runner.invocations.first,
              let idx = invocation.firstIndex(of: "--transcript-file"), idx + 1 < invocation.count else {
            XCTFail("expected --transcript-file argument")
            return
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: invocation[idx + 1]),
                        "temp transcript file should be removed after the call")
    }

    func testRunnerThrowPropagates() async {
        struct SomeError: Error, Equatable {}
        let runner = FakeCLIRunner(error: SomeError())
        let service = DictationCleanService(runner: runner)

        do {
            _ = try await service.clean(transcript: "some words", mode: .idea)
            XCTFail("expected clean to throw")
        } catch is SomeError {
            // expected
        } catch {
            XCTFail("expected SomeError, got \(error)")
        }
    }

    func testEnvelopeMissingModeKeyThrowsDescriptiveError() async {
        let runner = FakeCLIRunner(stdout: Data("""
        {"mode":"idea","title":"T"}
        """.utf8))
        let service = DictationCleanService(runner: runner)

        do {
            _ = try await service.clean(transcript: "some words", mode: .idea)
            XCTFail("expected clean to throw")
        } catch let error as DictationCleanError {
            XCTAssertNotNil(error.errorDescription)
        } catch {
            XCTFail("expected DictationCleanError, got \(error)")
        }
    }
}
