import XCTest
import WatchtowerCore
import WatchtowerTestSupport
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

    /// Chat fields deliver the raw transcript and never reach this service —
    /// the destination has no cleanup mode at all.
    func testChatDestinationHasNoCleanupMode() {
        XCTAssertNil(DictationMode.chat.cleanupMode)
        XCTAssertEqual(DictationMode.idea.cleanupMode, .idea)
        XCTAssertEqual(DictationMode.note.cleanupMode, .note)
    }

    /// #604 S6: the transcript travels on stdin (`--transcript-file -`).
    func testTranscriptTravelsOnStdin() async throws {
        let runner = FakeCLIRunner(stdout: Data("""
        {"mode":"note","markdown":"reply text"}
        """.utf8))
        let service = DictationCleanService(runner: runner)

        _ = try await service.clean(transcript: "captured transcript text", mode: .note)

        XCTAssertEqual(runner.invocations, [["dictate", "clean", "--mode", "note", "--transcript-file", "-"]])
        XCTAssertEqual(runner.stdinInputs, [Data("captured transcript text".utf8)])
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
