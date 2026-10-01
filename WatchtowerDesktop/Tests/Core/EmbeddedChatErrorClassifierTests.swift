import XCTest
@testable import WatchtowerCore

final class EmbeddedChatErrorClassifierTests: XCTestCase {
    func testMissingCLIIsProviderUnavailable() {
        let failure = EmbeddedChatErrorClassifier.classify(WatchtowerAIError.cliNotFound)
        XCTAssertEqual(failure.code, .providerUnavailable)
        XCTAssertFalse(failure.message.isEmpty)
    }

    func testAuthTextIsAuthAndKeepsTheRealText() {
        let failure = EmbeddedChatErrorClassifier.classify(
            WatchtowerAIError.exitCode(1, "Invalid API key · Please run /login"))
        XCTAssertEqual(failure.code, .auth)
        XCTAssertEqual(failure.message, "Invalid API key · Please run /login")
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
    }
}
