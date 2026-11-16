import Foundation

/// The chat error card's text and Retry, shared by the Mac (`ChatErrorPresentation`) and the iPhone: keyed by the
/// persisted `chat_messages.error_code`; the session's own `error_message` goes under the phrase (`detail`), so a
/// fixable cause is never hidden. Pure.
public enum ChatErrorText {
    /// Bound for the session text on the card (a stderr tail can be long).
    public static let detailLimit = 600
    /// The title of a turn stopped by the provider's quota (the Mac's `ProviderFallbackPreview(.stopped)` title).
    public static let quotaStopped = "Limit reached after work started"

    /// `provider` is the failed row's provider: only it knows how to sign in.
    public static func message(for code: String?, provider: String? = nil) -> String {
        switch code {
        case "auth": "The AI provider isn't signed in. " + signInHint(provider: provider)
        case "quota_exhausted": quotaStopped
        case "rate_limit": "The provider is rate-limiting requests. Try again in a moment."
        case "provider_unavailable": "The AI provider couldn't be started."
        case "session_lost": "The previous session couldn't be resumed."
        case "attachment_unsupported": "An attachment isn't supported by this provider."
        // The session's message names the folder and why; Retry would meet the same folder, so the card asks for
        // the one fix instead.
        case "workdir_unsafe": "Watchtower's chat folder isn't private. Delete it, then send your message again."
        default: "Something went wrong while answering."
        }
    }

    /// The session's own error text, trimmed and bounded; nil when there is none to show.
    public static func detail(_ errorMessage: String?) -> String? {
        guard let text = errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text.count > detailLimit ? String(text.prefix(detailLimit)) + "…" : text
    }

    public static func isRetryable(_ code: String?) -> Bool {
        code != "quota_exhausted" && code != "auth" && code != "attachment_unsupported" && code != "workdir_unsafe"
    }

    private static func signInHint(provider: String?) -> String {
        switch provider {
        case nil, "claude": "Open Terminal and run: claude login"
        case "codex": "Open Terminal and run: codex login"
        default: "Check its settings in Settings → AI."
        }
    }
}
