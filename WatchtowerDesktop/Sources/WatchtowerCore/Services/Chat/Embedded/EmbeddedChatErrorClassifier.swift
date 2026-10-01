import Foundation

/// Maps an embedded chat's failure (a thrown `ai query` error or the
/// provider's own `error` line) onto the main chat's error codes, so the row
/// renders the same card — a short hint by kind (`ChatErrorPresentation`)
/// over the real text, which is always kept.
package enum EmbeddedChatErrorClassifier {
    package struct Failure: Equatable, Sendable {
        package let code: ChatErrorCode?
        package let message: String

        package init(code: ChatErrorCode?, message: String) {
            self.code = code
            self.message = message
        }
    }

    package static func classify(_ error: Error) -> Failure {
        if let aiError = error as? WatchtowerAIError {
            switch aiError {
            case .cliNotFound:
                return Failure(code: .providerUnavailable, message: aiError.localizedDescription)
            case let .exitCode(_, detail):
                return classify(message: detail.isEmpty ? aiError.localizedDescription : detail)
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
        if authPhrases.contains(where: lowered.contains) {
            code = .auth
        } else if lowered.contains("rate limit") || lowered.contains("rate_limit") || lowered.contains("429") {
            code = .rateLimit
        } else {
            code = nil
        }
        return Failure(code: code, message: message)
    }

    private static let authPhrases = [
        "not logged in", "please log in", "login required", "/login", "401", "unauthorized",
        "invalid api key", "invalid x-api-key", "authentication"
    ]
}
