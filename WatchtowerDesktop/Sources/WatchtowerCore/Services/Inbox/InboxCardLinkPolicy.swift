import Foundation

/// The press-time check of a card link (`link`, an action's `open`). Go
/// refuses any other link at write time; this is defence in depth against a
/// row written some other way: http(s) to a host, or a `watchtower-nav://`
/// link to a screen the main window shows. Never `file`, `smb`, `mailto`,
/// `slack` or a relative URL.
package enum InboxCardLinkPolicy {
    package static func permits(_ url: URL, navScreens: Set<String>) -> Bool {
        // `URL.scheme` keeps the author's casing.
        switch url.scheme?.lowercased() {
        case "http", "https":
            return !(url.host ?? "").isEmpty
        case NavLink.scheme:
            guard let screen = url.host else { return false }
            return navScreens.contains(screen)
        default:
            return false
        }
    }

    /// Where a permitted link goes.
    package enum Route: Equatable, Sendable {
        /// An app screen, rebuilt as `watchtower-nav://<screen>`: `NavLink`
        /// compares the scheme as written, and an author may write it in caps.
        case screen(URL)
        case web(URL)
    }

    /// What a press opens; nil when `permits` refuses the link.
    package static func route(_ url: URL, navScreens: Set<String>) -> Route? {
        guard permits(url, navScreens: navScreens) else { return nil }
        if url.scheme?.lowercased() == NavLink.scheme, let screen = url.host {
            return .screen(NavLink.url(screen))
        }
        return .web(url)
    }
}
