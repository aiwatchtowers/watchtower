import XCTest
@testable import WatchtowerChatText

/// The chat error table the Mac and the iPhone share (spec §5).
final class ChatErrorTextTests: XCTestCase {
    func testRetryableCodes() {
        for code in ["auth", "quota_exhausted", "attachment_unsupported", "workdir_unsafe"] {
            XCTAssertFalse(ChatErrorText.isRetryable(code), code)
        }
        for code in ["rate_limit", "provider_unavailable", "session_lost", nil, "unknown"] {
            XCTAssertTrue(ChatErrorText.isRetryable(code), code ?? "nil")
        }
    }

    func testMessagesAndSignInHints() {
        XCTAssertEqual(ChatErrorText.message(for: "auth"), "The AI provider isn't signed in. Open Terminal and run: claude login")
        XCTAssertTrue(ChatErrorText.message(for: "auth", provider: "codex").hasSuffix("codex login"))
        XCTAssertEqual(ChatErrorText.message(for: "quota_exhausted"), "Limit reached after work started")
        XCTAssertEqual(ChatErrorText.message(for: nil), "Something went wrong while answering.")
    }

    func testDetailIsTrimmedAndBounded() {
        XCTAssertNil(ChatErrorText.detail(" \n"))
        XCTAssertEqual(ChatErrorText.detail(" x \n"), "x")
        XCTAssertEqual(ChatErrorText.detail(String(repeating: "y", count: 700))?.count, ChatErrorText.detailLimit + 1)
    }
}
