import Foundation

/// The Workchat pane's own copy (#2201 spec §7): the loading state and the quiet error bar.
package enum SessionChatPresentation {
    package static let loadingText = "Reading the session…"
    package static let retryTitle = "Retry"
    package static let errorTitle = "Couldn’t read the session feed"
    /// The store's message under the title; none when it has nothing to say.
    package static func errorDetail(_ message: String?) -> String? {
        guard let text = message?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
