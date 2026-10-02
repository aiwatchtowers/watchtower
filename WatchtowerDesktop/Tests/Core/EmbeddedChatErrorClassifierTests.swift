import XCTest
@testable import WatchtowerCore

final class EmbeddedChatErrorClassifierTests: XCTestCase {
    func testMissingCLIIsProviderUnavailable() {
        let failure = EmbeddedChatErrorClassifier.classify(WatchtowerAIError.cliNotFound)
        XCTAssertEqual(failure.code, .providerUnavailable)
        XCTAssertFalse(failure.message.isEmpty)
    }

    func testCLIThatCannotStartIsProviderUnavailable() {
        let failure = EmbeddedChatErrorClassifier.classify(WatchtowerAIError.launchFailed("permission denied"))
        XCTAssertEqual(failure.code, .providerUnavailable)
        XCTAssertTrue(failure.message.contains("permission denied"))
    }

    func testAuthTextIsAuthAndKeepsTheRealText() {
        let failure = EmbeddedChatErrorClassifier.classify(
            WatchtowerAIError.exitCode(1, "Invalid API key · Please run /login"))
        XCTAssertEqual(failure.code, .auth)
        XCTAssertEqual(failure.message, "AI query failed (exit 1): Invalid API key · Please run /login",
                       "the provider's text is kept, with the exit code")
    }

    func testRateLimitText() {
        XCTAssertEqual(EmbeddedChatErrorClassifier.classify(message: "HTTP 429 Too Many Requests").code, .rateLimit)
    }

    func testUnknownTextKeepsNoCodeAndTheText() {
        let failure = EmbeddedChatErrorClassifier.classify(message: "claude exited unexpectedly")
        XCTAssertNil(failure.code)
        XCTAssertEqual(failure.message, "claude exited unexpectedly")
    }

    func testEmptyExitDetailFallsBackToTheDescription() {
        let failure = EmbeddedChatErrorClassifier.classify(WatchtowerAIError.exitCode(2, ""))
        XCTAssertEqual(failure.message, WatchtowerAIError.exitCode(2, "").localizedDescription)
        XCTAssertTrue(failure.retryable)
    }

    func testNumbersInsideLongerOnesAreNotStatusCodes() {
        XCTAssertNil(EmbeddedChatErrorClassifier.classify(message: "context is 14290 tokens over").code)
        XCTAssertNil(EmbeddedChatErrorClassifier.classify(message: "request 40123 failed").code)
        XCTAssertEqual(EmbeddedChatErrorClassifier.classify(message: "status: 401").code, .auth)
    }
}
