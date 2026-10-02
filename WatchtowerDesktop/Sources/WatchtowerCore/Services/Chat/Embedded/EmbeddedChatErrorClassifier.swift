import Foundation

/// Maps an embedded chat's failure (a thrown `ai query` error or the
/// provider's own `error` line) onto the main chat's error codes, so the row
/// renders the same card — a short hint by kind (`ChatErrorPresentation`)
/// over the real text, which is always kept.
package enum EmbeddedChatErrorClassifier {
    package struct Failure: Equatable, Sendable {
        package let code: ChatErrorCode?
        package let message: String
        /// Whether rerunning the turn can help — false for a local storage
        /// failure, where Retry would only repeat a costly AI turn.
        package let retryable: Bool

        package init(code: ChatErrorCode?, message: String, retryable: Bool = true) {
            self.code = code
            self.message = message
            self.retryable = retryable
        }
    }

    package static func classify(_ error: Error) -> Failure {
        if let aiError = error as? WatchtowerAIError {
            switch aiError {
            case .cliNotFound:
                return Failure(code: .providerUnavailable, message: aiError.localizedDescription)
            case let .exitCode(_, detail):
                // The description keeps the exit code next to the provider's text.
                return Failure(code: classify(message: detail).code, message: aiError.localizedDescription)
            case .badResponse, .testFailed:
                return classify(message: aiError.localizedDescription)
            }
        }
        return classify(message: error.localizedDescription)
    }

    /// The provider's own text (an `error` line, a stderr tail).
    package static func classify(message: String) -> Failure {
        let lowered = message.lowercased()
        let code: ChatErrorCode?
        if authPhrases.contains(where: lowered.contains) || containsWord("401", in: lowered) {
            code = .auth
        } else if lowered.contains("rate limit") || lowered.contains("rate_limit") || containsWord("429", in: lowered) {
            code = .rateLimit
        } else {
            code = nil
        }
        return Failure(code: code, message: message)
    }

    private static let authPhrases = [
        "not logged in", "please log in", "login required", "/login", "unauthorized",
        "invalid api key", "invalid x-api-key", "authentication failed", "authentication_error"
    ]

    /// `code` as a standalone number ("HTTP 429", "status: 401"), never as
    /// part of a longer one ("14290 tokens").
    private static func containsWord(_ code: String, in text: String) -> Bool {
        text.range(of: "(^|[^0-9])\(code)([^0-9]|$)", options: .regularExpression) != nil
    }
}
