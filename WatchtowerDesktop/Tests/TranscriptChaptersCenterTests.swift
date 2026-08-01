import XCTest
@testable import WatchtowerDesktop

@MainActor
final class TranscriptChaptersCenterTests: XCTestCase {

    private let chaptersEnvelope =
        "{\"transcript_id\": 5, \"chapters_json\": \"{\\\"overall_summary\\\":\\\"s\\\",\\\"chapters\\\":[]}\"}"

    func test_generateSetsInFlightFlagAndClearsOnSuccess() async throws {
        let center = TranscriptChaptersCenter()
        let fake = FakeCLIRunner(stdout: Data(chaptersEnvelope.utf8))
        let service = TranscriptSaveService(runner: fake)

        let done = expectation(description: "finished")
        center.generate(transcriptID: 5, service: service) { done.fulfill() }
        XCTAssertTrue(center.generating.contains(5),
                      "in-flight flag must be set synchronously — it survives navigation on AppState")

        await fulfillment(of: [done], timeout: 5)
        XCTAssertFalse(center.generating.contains(5))
        XCTAssertNil(center.lastError[5])
    }

    func test_generateFailureRecordsErrorAndClearsFlag() async throws {
        let center = TranscriptChaptersCenter()
        let fake = FakeCLIRunner(error: CLIRunnerError.nonZeroExit(code: 1, stderr: "boom"))
        let service = TranscriptSaveService(runner: fake)

        let done = expectation(description: "finished")
        center.generate(transcriptID: 5, service: service) { done.fulfill() }
        await fulfillment(of: [done], timeout: 5)

        XCTAssertFalse(center.generating.contains(5))
        XCTAssertNotNil(center.lastError[5])

        center.clearError(transcriptID: 5)
        XCTAssertNil(center.lastError[5])
    }

    func test_generateIgnoresDuplicateStartForSameTranscript() async throws {
        let center = TranscriptChaptersCenter()
        let fake = FakeCLIRunner(stdout: Data(chaptersEnvelope.utf8))
        let service = TranscriptSaveService(runner: fake)

        let done = expectation(description: "first finished")
        center.generate(transcriptID: 5, service: service) { done.fulfill() }
        center.generate(transcriptID: 5, service: service) {
            XCTFail("second start for the same transcript must be a no-op")
        }
        await fulfillment(of: [done], timeout: 5)
    }
}
