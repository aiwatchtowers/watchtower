import AuthenticationServices
import SwiftUI

/// Result of the in-app OAuth flow.
enum OAuthWebResult {
    case success(code: String, state: String)
    case error(String)
    case cancelled
}

/// Custom URL scheme used for the OAuth redirect.
/// Must be registered in the Slack app settings and in the app's Info.plist.
enum OAuthConstants {
    static let callbackScheme = "watchtower-auth"
    static let redirectURI = "watchtower-auth://callback"
}

/// Presentation context provider for ASWebAuthenticationSession.
/// Held as a static to ensure the weak reference from the session stays alive.
final class OAuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = OAuthPresentationContext()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}
