import Foundation

/// Home's one card while background AI is paused or turned off by the
/// organization (#1886, spec §6.3). Drawn by `HomeContent` from
/// `AppState.backgroundAI` at the top of the page, outside the hideable
/// Getting ready zone, so its Hide never removes it; it speaks for the AI
/// features whose cards the zone leaves out.
package struct HomeBackgroundAICard: Equatable, Sendable {
    package let title: String
    package let body: String
    /// "Allow background AI…" (opens the consent screen); nil while the
    /// organization decided.
    package let actionTitle: String?
    /// The organization turned it off: the Managed badge, no action.
    package let managed: Bool

    /// nil while background AI is allowed.
    package static func make(_ state: BackgroundAIConsent.State) -> Self? {
        guard !state.isAllowed else { return nil }
        typealias Copy = BackgroundAIConsentCopy
        if state.reason == .organization {
            return Self(title: Copy.homeOrgTitle, body: Copy.homeOrgBody, actionTitle: nil, managed: true)
        }
        return Self(title: Copy.homeTitle, body: Copy.homeBody, actionTitle: Copy.allowAction, managed: false)
    }
}
