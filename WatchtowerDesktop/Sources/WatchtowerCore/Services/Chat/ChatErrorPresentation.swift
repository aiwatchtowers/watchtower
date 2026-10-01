import Foundation

/// Spec §5 error table → card text + Retry. Keyed by the persisted
/// `chat_messages.error_code`; the session's own `error_message` is shown
/// under that phrase (`detail`), so a fixable cause is never hidden.
package enum ChatErrorPresentation {
    /// Bound for the session text on the card (a stderr tail can be long).
    package static let detailLimit = 600

    /// `provider` is the failed row's provider: only it knows how to sign in.
    package static func message(for code: String?, provider: String? = nil) -> String {
        switch code {
        case "auth": "The AI provider isn't signed in. " + signInHint(provider: provider)
        case "rate_limit": "The provider is rate-limiting requests. Try again in a moment."
        case "provider_unavailable": "The AI provider couldn't be started."
        case "session_lost": "The previous session couldn't be resumed."
        case "attachment_unsupported": "An attachment isn't supported by this provider."
        default: "Something went wrong while answering."
        }
    }

    /// The session's own error text, trimmed and bounded; nil when there is
    /// none to show.
    package static func detail(_ errorMessage: String?) -> String? {
        guard let text = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text.count > detailLimit ? String(text.prefix(detailLimit)) + "…" : text
    }

    package static func isRetryable(_ code: String?) -> Bool {
        code != "auth" && code != "attachment_unsupported"
    }

    private static func signInHint(provider: String?) -> String {
        switch provider {
        case nil, "", "claude": "Open Terminal and run: claude login"
        case "codex": "Open Terminal and run: codex login"
        default: "Check its settings in Settings → AI."
        }
    }
}
