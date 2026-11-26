import Foundation

/// The Slack address a colleague without the company code types under the
/// code field ("No code?"): Watchtower only opens that workspace's app list
/// in the browser and stores nothing. Accepted: `acme`, `acme.slack.com`,
/// `http(s)://acme.slack.com/…` (any path, trailing slash), any case,
/// surrounding spaces. A workspace is one label of `[a-z0-9-]` that neither
/// starts nor ends with `-`; Slack's own hosts (`app`, `api`, `www`,
/// `status`, `slack`) are never a workspace. An Enterprise Grid
/// organization's address (`<sub>.enterprise.slack.com`) is refused with its
/// own caption because `/apps/manage` on it is unverified (spec "Failure
/// paths").
package enum SlackAddress: Equatable {
    case empty
    /// The workspace subdomain, lowercased, e.g. "acme".
    case workspace(String)
    /// `<sub>.enterprise.slack.com`.
    case organization
    case invalid

    private static let slackHome = URL(string: "https://slack.com/")!

    package static func parse(_ input: String) -> Self {
        var host = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.isEmpty { return .empty }
        for scheme in ["https://", "http://"] where host.hasPrefix(scheme) {
            host.removeFirst(scheme.count)
        }
        if let end = host.firstIndex(where: { "/?#".contains($0) }) {
            host = String(host[..<end])
        }
        if host.hasSuffix(".") { host.removeLast() }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let sub = labels.first, isWorkspaceLabel(sub) else { return .invalid }
        switch Array(labels.dropFirst()) {
        case [], ["slack", "com"]:
            return .workspace(sub)
        case ["enterprise", "slack", "com"]:
            return .organization
        default:
            return .invalid
        }
    }

    /// `https://<workspace>.slack.com/apps/manage`, the workspace's app list.
    /// `workspace` is what `parse` returned, so the URL always builds.
    package static func appsURL(workspace: String) -> URL {
        URL(string: "https://\(workspace).slack.com/apps/manage") ?? slackHome
    }

    /// Slack's own hosts, never a workspace's label.
    private static let reservedLabels: Set<String> = ["app", "api", "www", "status", "slack"]

    private static func isWorkspaceLabel(_ label: String) -> Bool {
        guard !label.isEmpty, !reservedLabels.contains(label),
              !label.hasPrefix("-"), !label.hasSuffix("-") else { return false }
        return label.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "-"
        }
    }
}
