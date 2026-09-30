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
            /// `diffText(before:after:)`, built once with the preview (never
            /// in `body`).
            let diff: AttributedString
        }

        /// The page title, or "Confluence page" when the args carry none.
        let title: String
        /// Nil unless the pinned url is http(s) — never a clickable
        /// `javascript:`/`file:` link.
        let pageURL: URL?
        let baseVersion: String
        let changes: [Change]
        /// Caveats Normalize pinned (`notes`), e.g. user names unavailable.
        let notes: [String]
    }

    /// The pinned edit, or nil for another tool or args without `changes`.
    /// Memoized per row version (`ConfluenceEditMemo`): the card's `body` re-evaluates with
    /// the chat thread (every streamed token), and the args carry the whole
    /// new page storage, so the parse and the word diffs run once per row
    /// version, never per render (the "decode once, never in row builders"
    /// rule).
    static func confluenceEdit(for action: AgentAction) -> ConfluenceEdit? {
        guard action.tool == confluenceEditTool else { return nil }
        return ConfluenceEditMemo.shared.edit(for: action, build: buildConfluenceEdit)
    }

    private static func buildConfluenceEdit(_ action: AgentAction) -> ConfluenceEdit? {
        ConfluenceEditMemo.shared.builds += 1
        guard let rawChanges = action.args["changes"] as? [[String: Any]], !rawChanges.isEmpty else { return nil }
        let pageURL = action.argString("url").flatMap(URL.init(string:)).flatMap { url in
            url.scheme == "https" || url.scheme == "http" ? url : nil
        }
        let title = action.argString("title") ?? ""
        return ConfluenceEdit(
            title: title.isEmpty ? "Confluence page" : title,
            pageURL: pageURL,
            baseVersion: action.argString("base_version") ?? "?",
            changes: rawChanges.map(confluenceChange),
            notes: action.args["notes"] as? [String] ?? []
        )
    }

    /// Approve is offered only for a proposal whose diff the card can show:
    /// approving an unreadable `edit_confluence_page` row would write a page
    /// the owner never saw (F7). Every other tool is approvable as before.
    static func canApprove(_ action: AgentAction) -> Bool {
        action.tool != confluenceEditTool || confluenceEdit(for: action) != nil
    }

    /// The card's text line for the tool; nil for any other tool.
    static func confluenceEditSummaryLines(for action: AgentAction) -> [String]? {
        guard action.tool == confluenceEditTool else { return nil }
        guard let edit = confluenceEdit(for: action) else { return ["Unreadable Confluence edit proposal"] }
        return ["Page: \(edit.title) · edits version \(edit.baseVersion)"]
    }

    /// Why a Retry of this failed tool is or is not safe.
    static func retryNote(for action: AgentAction) -> String {
        guard action.tool == confluenceEditTool else {
            return "Retrying re-sends the request — check Jira for a duplicate first."
        }
        let version = confluenceEdit(for: action)?.baseVersion ?? "?"
        return "Retrying writes only if the page is still at version \(version); if someone edited it since, ask for a new edit."
    }

    private static func confluenceChange(_ raw: [String: Any]) -> ConfluenceEdit.Change {
        let locator = raw["locator"] as? String ?? ""
        let removed = (raw["removed"] as? [String] ?? []).map(markerLabel)
        let before = raw["before"] as? String ?? ""
        let after = raw["after"] as? String ?? ""
        return ConfluenceEdit.Change(
            heading: raw["kind"] as? String == "replace_section" ? "Section: \(locator)" : locator,
            before: before,
            after: after,
            removesLine: removed.isEmpty ? nil : "Removes: " + removed.joined(separator: ", "),
            diff: diffText(before: before, after: after)
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
    /// red, added words underlined in green (colour is never the only cue),
    /// unchanged text plain (a long unchanged stretch shortened around " … "
    /// — changed words are never cut).
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
    let edit: AgentActionCardView.ConfluenceEdit

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(change.heading)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(change.diff)
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

/// The parsed-and-diffed `edit_confluence_page` preview per row version. The
/// args of a row never change after propose (Normalize pins them), so the key
/// is cheap — never a hash of the whole up-to-4-MiB JSON: row id, created_at,
/// status, the args' byte length and their first and last `sampleBytes`
/// bytes. The head carries `base_hash` (the sha256 of the page the preview
/// was computed from — Go writes the keys sorted), so a row of another
/// workspace that happens to share an id and a length never reuses a stale
/// preview. Bounded: past `capacity` entries the memo starts over.
@MainActor
final class ConfluenceEditMemo {
    static let shared = ConfluenceEditMemo()
    static let capacity = 64

    static let sampleBytes = 256

    private struct Key: Hashable {
        let id: Int64
        let createdAt: String
        let status: String
        let argsBytes: Int
        let head: [UInt8]
        let tail: [UInt8]

        init(_ action: AgentAction) {
            let utf8 = action.argsJSON.utf8
            id = action.id
            createdAt = action.createdAt
            status = action.status
            argsBytes = utf8.count
            head = Array(utf8.prefix(ConfluenceEditMemo.sampleBytes))
            tail = Array(utf8.suffix(ConfluenceEditMemo.sampleBytes))
        }
    }

    /// `.some(nil)` memoizes "args unreadable" too.
    private var entries: [Key: AgentActionCardView.ConfluenceEdit?] = [:]
    /// How many previews were actually built (counted by the builder
    /// itself) — the test seam proving a re-render reuses the memo.
    fileprivate(set) var builds = 0

    func edit(
        for action: AgentAction,
        build: (AgentAction) -> AgentActionCardView.ConfluenceEdit?
    ) -> AgentActionCardView.ConfluenceEdit? {
        let key = Key(action)
        if let cached = entries[key] { return cached }
        if entries.count >= Self.capacity { entries.removeAll() }
        let edit = build(action)
        entries[key] = .some(edit)
        return edit
    }
}
