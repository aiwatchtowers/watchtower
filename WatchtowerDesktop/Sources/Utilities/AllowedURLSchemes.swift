import Foundation
import SwiftUI
import WatchtowerCore

/// The single allowlist of URL schemes the app is willing to open.
///
/// The app ships unsandboxed (`scripts/Watchtower.entitlements`) and renders
/// attacker-controlled text — Slack messages, calendar invite descriptions,
/// e-mail bodies, LLM output — as clickable links. Foundation's markdown parser
/// does not filter schemes, so without this gate a `smb://` or `afp://` link
/// produces an outbound authenticated connection, `file:///….app` launches a
/// local bundle, and `x-apple.systempreferences:` opens an arbitrary settings
/// pane. Every link surface consults this one list so a future surface cannot
/// pick a different one.
enum AllowedURLSchemes {

    /// Schemes a rendered link may open.
    ///
    /// `slack` is the deep-link scheme the app builds itself for channel and
    /// message permalinks; `watchtower-memory` carries vault wiki-link taps
    /// (`MemoryMarkdown.linkScheme`). `watchtower-auth` is deliberately absent:
    /// it is an inbound OAuth callback the app receives via `onOpenURL`, never
    /// a URL the app opens.
    static let schemes: Set<String> = [
        "https",
        "http",
        "mailto",
        "slack",
        MemoryMarkdown.linkScheme
    ]

    /// Whether `url` may be handed to the system. A URL with no scheme
    /// (relative, or a bare path) is rejected.
    ///
    /// The `lowercased()` is load-bearing, not defensive: `URL.scheme` returns
    /// the scheme with the author's casing intact, so `SMB://` would otherwise
    /// walk straight past the set (pinned by `testURLSchemeKeepsAuthorCase`).
    static func permits(_ url: URL) -> Bool {
        guard let scheme = url.scheme else { return false }
        return schemes.contains(scheme.lowercased())
    }

    /// The app-wide `OpenURLAction`: an allowed scheme goes to the system
    /// handler, anything else is discarded rather than opened.
    static var openURLAction: OpenURLAction {
        OpenURLAction { url in permits(url) ? .systemAction : .discarded }
    }

    /// Defence in depth for rendered markdown: removes the `.link` attribute
    /// from every run pointing at a disallowed scheme, so the link text stays
    /// visible but is not clickable at all. Only the attribute goes — the
    /// characters are untouched, which is why the collected ranges stay valid
    /// across the mutation.
    static func strippingDisallowedLinks(_ attributed: AttributedString) -> AttributedString {
        var result = attributed
        let disallowed = result.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let link = run.link, !permits(link) else { return nil }
            return run.range
        }
        for range in disallowed {
            result[range].link = nil
        }
        return result
    }
}
