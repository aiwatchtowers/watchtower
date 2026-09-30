import SwiftUI
import WatchtowerCore

/// The `edit_confluence_page` proposal on the agent-action card (spec
/// 2026-09-30 §6): the page, then each pinned change as its locator and a
/// word-level diff of the text before → after, plus the rich elements (mention
/// markers) the change removes. Everything comes from the args Normalize
/// pinned at propose time (`internal/tools/confluence_page_edit.go`), which is
/// exactly what Approve writes — the card never recomputes the edit.
extension AgentActionCardView {
    static let confluenceEditTool = "edit_confluence_page"

    struct ConfluenceEdit: Equatable {
        struct Change: Equatable {
            /// "text in <section>" for a text replacement, "Section: <heading>"
            /// for a section rewrite.
            let heading: String
            let before: String
            let after: String
            /// "Removes: <labels>", nil when the change keeps every marker.
            let removesLine: String?
        }

        let title: String
        /// Nil unless the pinned url is http(s) — never a clickable
        /// `javascript:`/`file:` link.
        let pageURL: URL?
        let baseVersion: String
        let changes: [Change]
    }

    /// The pinned edit, or nil for another tool or args without `changes`.
    static func confluenceEdit(for action: AgentAction) -> ConfluenceEdit? {
        guard action.tool == confluenceEditTool,
              let rawChanges = action.args["changes"] as? [[String: Any]], !rawChanges.isEmpty else { return nil }
        let pageURL = action.argString("url").flatMap(URL.init(string:)).flatMap { url in
            url.scheme == "https" || url.scheme == "http" ? url : nil
        }
        return ConfluenceEdit(
            title: action.argString("title") ?? "",
            pageURL: pageURL,
            baseVersion: action.argString("base_version") ?? "?",
            changes: rawChanges.map(confluenceChange)
        )
    }

    /// The card's text line for the tool; nil for any other tool.
    static func confluenceEditSummaryLines(for action: AgentAction) -> [String]? {
        guard action.tool == confluenceEditTool else { return nil }
        guard let edit = confluenceEdit(for: action) else { return [action.argsJSON] }
        return ["Page: \(edit.title) · edits version \(edit.baseVersion)"]
    }

    /// Why a Retry of this failed tool is or is not safe.
    static func retryNote(for action: AgentAction) -> String {
        guard action.tool == confluenceEditTool else {
            return "Retrying re-sends the request — check Jira for a duplicate first."
        }
        let version = action.argString("base_version") ?? "?"
        return "Retrying writes only if the page is still at version \(version); if someone edited it since, ask for a new edit."
    }

    private static func confluenceChange(_ raw: [String: Any]) -> ConfluenceEdit.Change {
        let locator = raw["locator"] as? String ?? ""
        let removed = (raw["removed"] as? [String] ?? []).map(markerLabel)
        return ConfluenceEdit.Change(
            heading: raw["kind"] as? String == "replace_section" ? "Section: \(locator)" : locator,
            before: raw["before"] as? String ?? "",
            after: raw["after"] as? String ?? "",
            removesLine: removed.isEmpty ? nil : "Removes: " + removed.joined(separator: ", ")
        )
    }

    /// `⟦k:label⟧` → `label` (the marker syntax of the editable text); any
    /// other shape is shown as is.
    private static func markerLabel(_ token: String) -> String {
        guard token.hasPrefix("⟦"), token.hasSuffix("⟧"), let colon = token.firstIndex(of: ":") else { return token }
        return String(token[token.index(after: colon)..<token.index(before: token.endIndex)])
    }

    // MARK: - Diff rendering

    /// Unchanged text longer than this is shortened to its head and tail.
    static let unchangedRunLimit = 240
    private static let unchangedKeep = 100

    /// Before → after as one styled text: removed words struck through in
    /// red, added words in green, unchanged text plain (a long unchanged
    /// stretch shortened around " … " — changed words are never cut).
    static func diffText(before: String, after: String) -> AttributedString {
        var out = AttributedString()
        for segment in WordDiff.diff(before: before, after: after) {
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
    let edit: AgentActionCardView.ConfluenceEdit

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let url = edit.pageURL {
                Link("Open “\(edit.title)” in Confluence ↗", destination: url)
                    .font(.callout)
            }
            ForEach(Array(edit.changes.enumerated()), id: \.offset) { _, change in
                VStack(alignment: .leading, spacing: 2) {
                    Text(change.heading)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(AgentActionCardView.diffText(before: change.before, after: change.after))
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
