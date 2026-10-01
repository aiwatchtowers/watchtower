import Foundation

/// Pure composition for chat source chips (spec §3.2.3/§3.4, preflight
/// ruling A12): an explicit `url` always wins; otherwise a `jira:<KEY>`
/// ref resolves to its site's browse URL; every other url-less source
/// stays unresolved (`ChatSourcesPanelView`'s documented v1 limit).
///
/// The browse-URL formula duplicates `JiraHelpers.browseURL` (app target,
/// `Sources/Utilities/JiraHelpers.swift`) rather than sharing it: `WatchtowerCore`
/// cannot depend on the app target, so this is a small, deliberate two-copy
/// pin — `JiraHelpersTests` covers one side, `SourceLinkResolverTests` the other.
package enum SourceLinkResolver {
    package static func url(for source: ChatSource, jiraSiteURL: String?) -> URL? {
        if let raw = source.url, let parsed = URL(string: raw) { return parsed }
        guard source.kind == "jira", let key = issueKey(source.ref) else { return nil }
        return browseURL(siteURL: jiraSiteURL, issueKey: key)
    }

    private static func issueKey(_ ref: String) -> String? {
        guard ref.hasPrefix("jira:") else { return nil }
        let key = String(ref.dropFirst("jira:".count))
        return key.isEmpty ? nil : key
    }

    private static func browseURL(siteURL: String?, issueKey: String) -> URL? {
        guard let site = siteURL, !site.isEmpty else { return nil }
        let base = site.hasSuffix("/") ? String(site.dropLast()) : site
        return URL(string: "\(base)/browse/\(issueKey)")
    }
}
