import Foundation

/// A release-notes category, as `/release` writes it (`.claude/commands/release.md`,
/// Step 2): a `### <emoji> <Title>` heading, in this order. `internal` changes
/// never reach the notes, so it has no case.
package enum ReleaseNotesCategory: String, CaseIterable, Sendable {
    case requirements, new, extended, improved, changed, removed, security, fixed

    package var title: String { rawValue.capitalized }

    package var systemImage: String {
        switch self {
        case .requirements: "exclamationmark.triangle.fill"
        case .new: "sparkles"
        case .extended: "plus.circle.fill"
        case .improved: "wand.and.stars"
        case .changed: "arrow.triangle.swap"
        case .removed: "trash.fill"
        case .security: "lock.fill"
        case .fixed: "ladybug.fill"
        }
    }

    /// A `### ` heading whose words, past any leading emoji, name a category
    /// (case-insensitive).
    init?(heading line: Substring) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("### ") else { return nil }
        let words = trimmed.dropFirst(4).drop { !$0.isLetter }
        self.init(rawValue: words.trimmingCharacters(in: .whitespaces).lowercased())
    }
}

/// Release notes split into their category sections, for the Software Update
/// window's badges (`UpdateAvailableView`). `parse` returns nil for notes with
/// no category heading — releases before the categories, or hand-written
/// notes — or with an unknown `###` among the categories, and the window then
/// shows the text as it is. A `## ` heading or the `**Full Changelog**` line
/// ends the sections.
package struct ReleaseNotesSections: Equatable, Sendable {
    package struct Section: Equatable, Sendable {
        package let category: ReleaseNotesCategory
        /// The section's Markdown, heading excluded; never empty (a heading
        /// with nothing under it is dropped).
        package let body: String
    }

    /// Markdown before the first category heading, minus the `## What's New` title.
    package let leading: String
    package let sections: [Section]
    /// Markdown from the `**Full Changelog**` line on.
    package let trailing: String

    package static func parse(_ notes: String) -> Self? {
        var leading: [Substring] = []
        var sections: [(ReleaseNotesCategory, [Substring])] = []
        var trailing: [Substring] = []
        var inCodeBlock = false
        // GitHub's release editor saves CRLF; "\r\n" is one Character, so split after normalising.
        let lines = notes.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inCodeBlock.toggle() }
            let endsSections = trimmed.hasPrefix("**Full Changelog**") || trimmed.hasPrefix("## ")
            if !trailing.isEmpty || (!inCodeBlock && !sections.isEmpty && endsSections) {
                trailing.append(line)
            } else if !inCodeBlock, let category = ReleaseNotesCategory(heading: line) {
                sections.append((category, []))
            } else if sections.isEmpty {
                if !isNotesTitle(trimmed) { leading.append(line) }
            } else if !inCodeBlock, trimmed.hasPrefix("### ") {
                // An unknown heading among the categories would put its lines under
                // the previous badge; show the notes as plain text instead.
                return nil
            } else {
                sections[sections.count - 1].1.append(line)
            }
        }
        let filled = sections.map { Section(category: $0.0, body: joined($0.1)) }.filter { !$0.body.isEmpty }
        guard !filled.isEmpty else { return nil }
        return Self(leading: joined(leading), sections: filled, trailing: joined(trailing))
    }

    private static func isNotesTitle(_ trimmed: String) -> Bool {
        trimmed == "## What's New" || trimmed == "## What\u{2019}s New"
    }

    private static func joined(_ lines: some Sequence<Substring>) -> String {
        lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
