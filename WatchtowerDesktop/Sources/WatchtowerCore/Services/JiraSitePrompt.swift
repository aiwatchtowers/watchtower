import Foundation

/// One Atlassian site the Jira connect sheet offers when a grant reaches
/// several (#574).
package struct JiraSiteChoice: Decodable, Equatable, Identifiable, Sendable {
    package let url: String
    package let name: String
    package var id: String { url }

    package init(url: String, name: String) {
        self.url = url
        self.name = name
    }
}

/// The site question `jira add --app-site-picker` asks (#574, dual path: Go
/// `jiraSitesMarker` in `cmd/jira.go`). With several sites in a grant the CLI
/// prints one stdout line — `[jira-sites] {"sites":[{"url","name"}]}` — and
/// waits for the chosen site's URL on stdin, so the owner picks from a list
/// instead of typing a site up front.
package enum JiraSitePrompt {
    package static let marker = "[jira-sites]"

    /// The sites of the first complete marker line in `output` (the connect's
    /// stdout so far); nil until that line has fully arrived or when it does
    /// not decode.
    package static func sites(in output: String) -> [JiraSiteChoice]? {
        for line in output.split(separator: "\n", omittingEmptySubsequences: false).dropLast() {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.hasPrefix(marker + " ") else { continue }
            let json = Data(text.dropFirst(marker.count + 1).utf8)
            guard let payload = try? JSONDecoder().decode(Payload.self, from: json),
                  !payload.sites.isEmpty else { return nil }
            return payload.sites
        }
        return nil
    }

    /// What the sheet writes back on the CLI's stdin for `site`.
    package static func answer(_ site: JiraSiteChoice) -> Data {
        Data((site.url + "\n").utf8)
    }

    private struct Payload: Decodable {
        let sites: [JiraSiteChoice]
    }
}
