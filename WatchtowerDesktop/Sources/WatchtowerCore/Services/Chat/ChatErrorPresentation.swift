import Foundation

/// Spec §5 error table → card text + Retry. Keyed by the persisted
/// `chat_messages.error_code` (the wire message is not stored).
package enum ChatErrorPresentation {
    package static func message(for code: String?) -> String {
        switch code {
        case "auth": "The AI provider isn't signed in. Open Terminal and run: claude login"
        case "rate_limit": "The provider is rate-limiting requests. Try again in a moment."
        case "provider_unavailable": "The AI provider couldn't be started."
        case "session_lost": "The previous session couldn't be resumed."
        case "attachment_unsupported": "An attachment isn't supported by this provider."
        default: "Something went wrong while answering."
        }
    }

    package static func isRetryable(_ code: String?) -> Bool {
        code != "auth" && code != "attachment_unsupported"
    }
}
