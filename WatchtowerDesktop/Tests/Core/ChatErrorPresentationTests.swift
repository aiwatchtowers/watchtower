import XCTest
@testable import WatchtowerCore

/// Spec §5's table: which codes offer Retry and what the card says.
final class ChatErrorPresentationTests: XCTestCase {
    func testRetryability() {
        XCTAssertFalse(ChatErrorPresentation.isRetryable("auth"))
        XCTAssertFalse(ChatErrorPresentation.isRetryable("attachment_unsupported"))
        for code in ["rate_limit", "provider_unavailable", "internal", "session_lost", nil, "unknown"] {
            XCTAssertTrue(ChatErrorPresentation.isRetryable(code), "\(code ?? "nil")")
        }
    }

    func testMessages() {
        XCTAssertTrue(ChatErrorPresentation.message(for: "auth").contains("claude login"))
        XCTAssertTrue(ChatErrorPresentation.message(for: "rate_limit").contains("rate"))
        XCTAssertFalse(ChatErrorPresentation.message(for: nil).isEmpty)
    }
}
