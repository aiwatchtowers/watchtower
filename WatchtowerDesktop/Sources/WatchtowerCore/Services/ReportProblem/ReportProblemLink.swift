import Foundation

/// Builds the prefilled GitHub bug-form link
/// (`issues/new?template=bug_report.yml&<form id>=<value>`). The keys other
/// than `template` and `title` are field ids of
/// `.github/ISSUE_TEMPLATE/bug_report.yml` (`testLinkKeysMatchForm`).
///
/// Budget, by encoded length: the whole URL stays within `maxURLLength`.
/// Steps, stopping at the first that fits: 1. the full link; 2. `logs`
/// replaced by a paste placeholder; 3. `actual` also cut at a character
/// boundary, ending with a "full text in the pasted report" marker.
package enum ReportProblemLink {
    package static let maxURLLength = 6_000
    /// The "What happened?" field's cap, in characters.
    package static let maxTextLength = 2_000
    static let maxTitleLength = 80

    /// `shortened` is true from step 2 on: the sheet then offers Copy Report.
    /// `answer == nil` (collection failed) carries only the app's `version`
    /// and `macOS`; chip and provider are left for the user.
    package static func make(
        userText: String,
        answer: DiagnosticsAnswer?,
        appVersion: String,
        macOS: String,
        repository: URL = ReleaseLinks.repository
    ) -> (url: URL, shortened: Bool) {
        let text = String(userText.prefix(maxTextLength))
        var head: [(String, String)] = [("template", "bug_report.yml")]
        let title = firstLine(text)
        if !title.isEmpty { head.append(("title", title)) }
        if let answer {
            head.append(("version", answer.version))
            head.append(("macos", answer.macos))
            if !answer.chip.isEmpty { head.append(("chip", answer.chip)) }
            if !answer.provider.isEmpty { head.append(("provider", answer.provider)) }
        } else {
            head.append(("version", appVersion))
            head.append(("macos", macOS))
        }

        let base = repository.appendingPathComponent("issues/new").absoluteString + "?"
        func build(actual: String, logs: String?) -> String {
            var fields = head
            fields.append(("actual", actual))
            if let logs { fields.append(("logs", logs)) }
            return base + fields.map { "\($0.0)=\(encode($0.1))" }.joined(separator: "&")
        }

        // Step 1: the full link (no `logs` when there is no answer).
        let full = build(actual: text, logs: answer?.text)
        if full.count <= maxURLLength { return (url(full), false) }

        // Step 2: the report is pasted by hand.
        let placeholder = ReportProblemCopy.logsPlaceholder
        let withoutLogs = build(actual: text, logs: placeholder)
        if withoutLogs.count <= maxURLLength { return (url(withoutLogs), true) }

        // Step 3: cut the user text, whole characters only, so neither a
        // character nor its percent escape is ever split.
        let suffix = ReportProblemCopy.truncatedSuffix
        var budget = maxURLLength - build(actual: suffix, logs: placeholder).count
        var kept = ""
        for character in text {
            let cost = encode(String(character)).count
            guard cost <= budget else { break }
            budget -= cost
            kept.append(character)
        }
        return (url(build(actual: kept + suffix, logs: placeholder)), true)
    }

    /// The first non-blank line of the text, trimmed, at most 80 characters.
    private static func firstLine(_ text: String) -> String {
        let line = text
            .split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        return String(line.prefix(maxTitleLength))
    }

    /// RFC 3986 unreserved characters stay; everything else is escaped,
    /// `+` and `&` included (GitHub reads a bare `+` as a space).
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    private static func encode(_ value: String) -> String {
        // Never nil for a Swift String: it is valid Unicode.
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static func url(_ string: String) -> URL {
        // Only unreserved characters and percent escapes follow the base.
        URL(string: string) ?? ReleaseLinks.repository
    }
}
