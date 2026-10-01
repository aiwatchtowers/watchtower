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
        XCTAssertTrue(ChatErrorPresentation.message(for: "auth", provider: "claude").contains("claude login"))
        XCTAssertTrue(ChatErrorPresentation.message(for: "rate_limit").contains("rate"))
        XCTAssertFalse(ChatErrorPresentation.message(for: nil).isEmpty)
    }

    /// The sign-in hint follows the row's provider: never "claude login" for
    /// a codex or ollama turn.
    func testAuthHintFollowsTheProvider() {
        let codex = ChatErrorPresentation.message(for: "auth", provider: "codex")
        XCTAssertTrue(codex.contains("codex login"))
        XCTAssertFalse(codex.contains("claude"))
        let ollama = ChatErrorPresentation.message(for: "auth", provider: "ollama")
        XCTAssertFalse(ollama.contains("claude login"))
        XCTAssertTrue(ollama.contains("Settings → AI"))
    }

    func testDetailShowsTheSessionTextBounded() throws {
        XCTAssertNil(ChatErrorPresentation.detail(nil))
        XCTAssertNil(ChatErrorPresentation.detail("  \n "))
        XCTAssertEqual(ChatErrorPresentation.detail(" no Ollama model is configured \n"), "no Ollama model is configured")
        let long = String(repeating: "x", count: ChatErrorPresentation.detailLimit + 50)
        let bounded = try XCTUnwrap(ChatErrorPresentation.detail(long))
        XCTAssertEqual(bounded.count, ChatErrorPresentation.detailLimit + 1)
        XCTAssertTrue(bounded.hasSuffix("…"))
    }
}
