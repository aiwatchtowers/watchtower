import ChatWire
import SwiftUI
import WatchtowerDesign

/// The `edit_confluence_page` proposal on the card (spec 2026-09-30 §6): the page, then each pinned change as its
/// locator and a word-level diff of the text before → after, plus the rich elements (mention markers) the change
/// removes. Everything comes from the args Normalize pinned at propose time, which is exactly what Approve writes — the
/// card never recomputes the edit. The diff segments are memoized per row version (`ConfluenceEdit`); a render only
/// styles them.
extension AgentActionCard {
    /// Unchanged text longer than this is shortened to its head and tail.
    static let unchangedRunLimit = 240
    private static let unchangedKeep = 100

    /// Before → after as one styled text: removed words struck through in red, added words underlined in green (colour
    /// is never the only cue), unchanged text plain (a long unchanged stretch shortened around " … " — changed words
    /// are never cut).
    public static func diffText(before: String, after: String) -> AttributedString {
        diffText(WordDiff.diff(before: before, after: after))
    }

    /// The styled text of a change's memoized diff segments.
    static func diffText(_ segments: [WordDiff.Segment]) -> AttributedString {
        var out = AttributedString()
        for segment in segments {
            switch segment.kind {
            case .same:
                out.append(AttributedString(shortened(segment.text)))
            case .removed:
                var part = AttributedString(segment.text)
                part.swiftUI.strikethroughStyle = .single
                part.swiftUI.foregroundColor = .red
                out.append(part)
            case .added:
                var part = AttributedString(segment.text)
                part.swiftUI.underlineStyle = .single
                part.swiftUI.foregroundColor = .green
                out.append(part)
            }
        }
        return out
    }

    private static func shortened(_ text: String) -> String {
        guard text.count > unchangedRunLimit else { return text }
        return String(text.prefix(unchangedKeep)) + " … " + String(text.suffix(unchangedKeep))
    }
}

/// The page link and the per-change diffs under the card's summary line.
struct ConfluenceEditChangesView: View {
    let edit: ConfluenceEdit

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            if let url = edit.pageURL {
                Link("Open “\(edit.title)” in Confluence ↗", destination: url)
                    .font(.callout)
            }
            ForEach(edit.notes, id: \.self) { note in
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ForEach(Array(edit.changes.enumerated()), id: \.offset) { _, change in
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    Text(change.heading)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(AgentActionCard.diffText(change.segments))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if let removes = change.removesLine {
                        Text(removes)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }
}
