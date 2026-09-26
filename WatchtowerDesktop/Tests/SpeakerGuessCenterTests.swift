import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The navigation-surviving speaker-guess center (the TranscriptNotesCenter
/// sibling): in-flight dedupe, error/empty-result outcomes, and suggestion
/// chip consumption.
@MainActor
final class SpeakerGuessCenterTests: XCTestCase {

    private let suggestionEnvelope = Data("""
        {"transcript_id": 5, "suggestions": [
            {"speaker": "Speaker 1", "candidate": "Саша", "confidence": 0.9, "evidence": "introduces himself"},
            {"speaker": "Speaker 2", "candidate": "Оля", "confidence": 0.8, "evidence": "addressed by name"}
        ]}
        """.utf8)

    private let emptyEnvelope = Data(
        "{\"transcript_id\": 5, \"suggestions\": []}".utf8)

    func test_suggestSetsInFlightFlagAndStoresSuggestions() async throws {
        let center = SpeakerGuessCenter()
        let service = TranscriptSaveService(runner: FakeCLIRunner(stdout: suggestionEnvelope))

        let done = expectation(description: "finished")
        center.suggest(transcriptID: 5, service: service) { done.fulfill() }
        XCTAssertTrue(center.generating.contains(5),
                      "in-flight flag must be set synchronously — it survives navigation on AppState")

        await fulfillment(of: [done], timeout: 5)
        XCTAssertFalse(center.generating.contains(5))
        XCTAssertNil(center.lastError[5])
        XCTAssertNil(center.lastNotice[5])
        XCTAssertEqual(center.suggestions[5]?.map(\.candidate), ["Саша", "Оля"])
    }

    func test_suggestFailureRecordsErrorAndResetsGenerating() async throws {
        let center = SpeakerGuessCenter()
        let service = TranscriptSaveService(
            runner: FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "boom")))

        let done = expectation(description: "finished")
        center.suggest(transcriptID: 5, service: service) { done.fulfill() }
        await fulfillment(of: [done], timeout: 5)

        XCTAssertFalse(center.generating.contains(5),
                       "a stuck generating flag would permanently disable the button")
        XCTAssertNotNil(center.lastError[5])
        XCTAssertNil(center.suggestions[5])

        // A retry after the failure must start (the flag was reset).
        let retryRunner = FakeCLIRunner(stdout: suggestionEnvelope)
        let retried = expectation(description: "retried")
        center.suggest(transcriptID: 5, service: TranscriptSaveService(runner: retryRunner)) {
            retried.fulfill()
        }
        await fulfillment(of: [retried], timeout: 5)
        XCTAssertEqual(retryRunner.invocations.count, 1)
        XCTAssertNil(center.lastError[5], "a new run must clear the previous error")
    }

    func test_emptyResultIsNoticeNotError() async throws {
        let center = SpeakerGuessCenter()
        let service = TranscriptSaveService(runner: FakeCLIRunner(stdout: emptyEnvelope))

        let done = expectation(description: "finished")
        center.suggest(transcriptID: 5, service: service) { done.fulfill() }
        await fulfillment(of: [done], timeout: 5)

        XCTAssertFalse(center.generating.contains(5))
        XCTAssertNil(center.lastError[5],
                     "a successful run with zero suggestions is not a failure")
        XCTAssertEqual(center.lastNotice[5], "No confident name suggestions for this recording")

        center.clearError(transcriptID: 5)
        XCTAssertNil(center.lastNotice[5])
    }

    func test_suggestIgnoresDuplicateStartForSameTranscript() async throws {
        let center = SpeakerGuessCenter()
        let runner = FakeCLIRunner(stdout: suggestionEnvelope)
        let service = TranscriptSaveService(runner: runner)

        let done = expectation(description: "first finished")
        center.suggest(transcriptID: 5, service: service) { done.fulfill() }
        center.suggest(transcriptID: 5, service: service) {
            XCTFail("second start for the same transcript must be a no-op")
        }
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(runner.invocations.count, 1, "the CLI must run exactly once")
    }

    func test_consumeSuggestionRemovesChipAndClearsEmptyKey() async throws {
        let center = SpeakerGuessCenter()
        let service = TranscriptSaveService(runner: FakeCLIRunner(stdout: suggestionEnvelope))

        let done = expectation(description: "finished")
        center.suggest(transcriptID: 5, service: service) { done.fulfill() }
        await fulfillment(of: [done], timeout: 5)

        center.consumeSuggestion(transcriptID: 5, speaker: "Speaker 1")
        XCTAssertEqual(center.suggestions[5]?.map(\.speaker), ["Speaker 2"],
                       "only the confirmed/dismissed speaker's chip is dropped")

        // Consuming an unknown speaker is a no-op (degenerate but valid).
        center.consumeSuggestion(transcriptID: 5, speaker: "Speaker 9")
        XCTAssertEqual(center.suggestions[5]?.count, 1)

        center.consumeSuggestion(transcriptID: 5, speaker: "Speaker 2")
        XCTAssertNil(center.suggestions[5], "an emptied suggestion list clears the key")

        // Consuming for a transcript that never ran is a no-op too.
        center.consumeSuggestion(transcriptID: 77, speaker: "Speaker 1")
        XCTAssertNil(center.suggestions[77])
    }
}
