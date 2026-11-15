import Foundation
import WatchtowerChatText

/// Spec §5 error table → card text + Retry. The table is `ChatErrorText` (WatchtowerChatText), the one copy the
/// Mac and the iPhone share; this is its Mac name.
package enum ChatErrorPresentation {
    package static let detailLimit = ChatErrorText.detailLimit

    /// `provider` is the failed row's provider: only it knows how to sign in.
    package static func message(for code: String?, provider: String? = nil) -> String {
        ChatErrorText.message(for: code, provider: provider)
    }

    /// The session's own error text, trimmed and bounded; nil when there is none to show.
    package static func detail(_ errorMessage: String?) -> String? {
        ChatErrorText.detail(errorMessage)
    }

    package static func isRetryable(_ code: String?) -> Bool {
        ChatErrorText.isRetryable(code)
    }
}
