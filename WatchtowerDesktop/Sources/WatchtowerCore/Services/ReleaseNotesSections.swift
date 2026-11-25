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
/// notes — and the window then shows the text as it is.
package struct ReleaseNotesSections: Equatable, Sendable {
    package struct Section: Equatable, Sendable {
        package let category: ReleaseNotesCategory
        /// The section's Markdown, heading excluded; empty for a heading with
        /// no lines under it.
        package let body: String
    }

    /// Markdown before the first category heading, minus the `## What's New` title.
    package let leading: String
    package let sections: [Section]
    /// Markdown after the last section's list — the `**Full Changelog**` line.
    package let trailing: String

    package static func parse(_ notes: String) -> Self? {
        var leading: [Substring] = []
        var sections: [(ReleaseNotesCategory, [Substring])] = []
        for line in notes.split(separator: "\n", omittingEmptySubsequences: false) {
            if let category = ReleaseNotesCategory(heading: line) {
                sections.append((category, []))
            } else if sections.isEmpty {
                if !isNotesTitle(line) { leading.append(line) }
            } else {
                sections[sections.count - 1].1.append(line)
            }
        }
        guard let last = sections.last else { return nil }

        // The last section ends at its last list line; what follows is trailing.
        let cut = (last.1.lastIndex(where: isListLine) ?? -1) + 1
        sections[sections.count - 1].1 = Array(last.1[..<cut])
        return Self(
            leading: joined(leading),
            sections: sections.map { Section(category: $0.0, body: joined($0.1)) },
            trailing: joined(last.1[cut...])
        )
    }

    private static func isNotesTitle(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed == "## What's New" || trimmed == "## What\u{2019}s New"
    }

    /// A list item, or an indented continuation of one.
    private static func isListLine(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return ["- ", "* ", "+ "].contains { trimmed.hasPrefix($0) } || line.first == " " || line.first == "\t"
    }

    private static func joined(_ lines: some Sequence<Substring>) -> String {
        lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
