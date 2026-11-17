import Foundation

/// The `edit_confluence_page` proposal on the agent-action card (spec
/// 2026-09-30 §6): the page, then each pinned change as its locator and a
/// word-level diff of the text before → after, plus the rich elements (mention
/// markers) the change removes. Everything comes from the args Normalize
/// pinned at propose time (`internal/tools/confluence_page_edit.go`), which is
/// exactly what Approve writes — the card never recomputes the edit.
public struct ConfluenceEdit: Equatable, Sendable {
    public static let tool = "edit_confluence_page"
    /// The card's line when the args reached this device clipped (`ChatAgentAction.argsClipped`) — nearly every
    /// edit on the phone, as the args carry the whole new page.
    public static let clippedNote = "This page edit is too long to show in full here."
    /// Whether a clipped edit, whose diff this device cannot show, may still be approved (pinned to the args digest,
    /// today's phone behaviour). The owner kept it against rule F7 ("never approve a page the owner never saw"): ask #1420.
    public static let allowsApproveWhenClipped = true

    public struct Change: Equatable, Sendable {
        /// "text in <section>" for a text replacement, "Section: <heading>"
        /// for a section rewrite.
        public let heading: String
        public let before: String
        public let after: String
        /// "Removes: <labels>", nil when the change keeps every marker.
        public let removesLine: String?
        /// `WordDiff.diff(before:after:)`, computed once with the preview
        /// (never in a view's `body`); the card styles it.
        public let segments: [WordDiff.Segment]
    }

    /// The page title, or "Confluence page" when the args carry none.
    public let title: String
    /// Nil unless the pinned url is http(s) — never a clickable
    /// `javascript:`/`file:` link.
    public let pageURL: URL?
    public let baseVersion: String
    public let changes: [Change]
    /// Caveats Normalize pinned (`notes`), e.g. user names unavailable.
    public let notes: [String]

    /// The pinned edit, or nil for another tool or args without `changes`.
    /// Memoized per row version (`ConfluenceEditMemo`): the card's `body` re-evaluates with
    /// the chat thread (every streamed token), and the args carry the whole
    /// new page storage, so the parse and the word diffs run once per row
    /// version, never per render (the "decode once, never in row builders"
    /// rule).
    public static func proposal(for action: ChatAgentAction) -> Self? {
        guard action.tool == tool else { return nil }
        return ConfluenceEditMemo.shared.edit(for: action)
    }

    /// Approve is offered only for a proposal whose diff the card can show:
    /// approving an unreadable `edit_confluence_page` row would write a page
    /// the owner never saw (F7). Every other tool is approvable as before.
    public static func canApprove(_ action: ChatAgentAction) -> Bool {
        guard action.tool == tool else { return true }
        if action.argsClipped { return allowsApproveWhenClipped }
        return proposal(for: action) != nil
    }

    /// Why a Retry of this failed tool is or is not safe.
    public static func retryNote(for action: ChatAgentAction) -> String {
        guard action.tool == tool else {
            return "Retrying re-sends the request — check Jira for a duplicate first."
        }
        let version = proposal(for: action)?.baseVersion ?? "?"
        return "Retrying writes only if the page is still at version \(version); if someone edited it since, ask for a new edit."
    }

    static func build(_ action: ChatAgentAction) -> Self? {
        let args = action.args // one decode of the up-to-4-MiB args per build
        guard let rawChanges = args["changes"] as? [[String: Any]], !rawChanges.isEmpty else { return nil }
        let pageURL = ChatAgentAction.stringValue(args["url"]).flatMap(URL.init(string:)).flatMap { url in
            url.scheme == "https" || url.scheme == "http" ? url : nil
        }
        let title = ChatAgentAction.stringValue(args["title"]) ?? ""
        return Self(
            title: title.isEmpty ? "Confluence page" : title,
            pageURL: pageURL,
            baseVersion: ChatAgentAction.stringValue(args["base_version"]) ?? "?",
            changes: rawChanges.map(change),
            notes: args["notes"] as? [String] ?? []
        )
    }

    private static func change(_ raw: [String: Any]) -> Change {
        let locator = raw["locator"] as? String ?? ""
        let removed = (raw["removed"] as? [String] ?? []).map(markerLabel)
        let before = raw["before"] as? String ?? ""
        let after = raw["after"] as? String ?? ""
        return Change(
            heading: raw["kind"] as? String == "replace_section" ? "Section: \(locator)" : locator,
            before: before,
            after: after,
            removesLine: removed.isEmpty ? nil : "Removes: " + removed.joined(separator: ", "),
            segments: WordDiff.diff(before: before, after: after)
        )
    }

    /// `⟦k:label⟧` → `label` (the marker syntax of the editable text); any
    /// other shape is shown as is.
    private static func markerLabel(_ token: String) -> String {
        guard token.hasPrefix("⟦"), token.hasSuffix("⟧"), let colon = token.firstIndex(of: ":") else { return token }
        return String(token[token.index(after: colon)..<token.index(before: token.endIndex)])
    }
}

/// The parsed-and-diffed `edit_confluence_page` preview per row version. The
/// args of a row never change after propose (Normalize pins them), so the key
/// is cheap — never a hash of the whole up-to-4-MiB JSON: row id, created_at,
/// status, the args' byte length and their first and last `sampleBytes`
/// bytes. The head carries `base_hash` (the sha256 of the page the preview
/// was computed from — Go writes the keys sorted), so a row of another
/// workspace that happens to share an id and a length never reuses a stale
/// preview. Bounded: past `capacity` entries the memo starts over. Locked, so
/// any caller may read it.
public final class ConfluenceEditMemo: @unchecked Sendable {
    public static let shared = ConfluenceEditMemo()
    public static let capacity = 64
    public static let sampleBytes = 256

    private struct Key: Hashable {
        let id: Int64
        let createdAt: String
        let status: String
        let argsBytes: Int
        let head: [UInt8]
        let tail: [UInt8]

        init(_ action: ChatAgentAction) {
            let utf8 = action.argsJSON.utf8
            id = action.id
            createdAt = action.createdAt
            status = action.status
            argsBytes = utf8.count
            head = Array(utf8.prefix(ConfluenceEditMemo.sampleBytes))
            tail = Array(utf8.suffix(ConfluenceEditMemo.sampleBytes))
        }
    }

    private let lock = NSLock()
    /// `.some(nil)` memoizes "args unreadable" too.
    private var entries: [Key: ConfluenceEdit?] = [:]
    private var buildCount = 0

    /// How many previews were actually built — the test seam proving a
    /// re-render reuses the memo.
    public var builds: Int {
        lock.lock()
        defer { lock.unlock() }
        return buildCount
    }

    func edit(for action: ChatAgentAction) -> ConfluenceEdit? {
        let key = Key(action)
        lock.lock()
        defer { lock.unlock() }
        if let cached = entries[key] { return cached }
        if entries.count >= Self.capacity { entries.removeAll() }
        buildCount += 1
        let edit = ConfluenceEdit.build(action)
        entries[key] = .some(edit)
        return edit
    }
}
