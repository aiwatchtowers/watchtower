import Foundation
import WatchtowerCore
import WatchtowerInterface

/// Canned feed cards for the Inbox's text and button-state tests (Task
/// 11d-b): the facts Go decides — a card's button states, its rows' ref
/// facts, an approval card's words — handed to the Mac as the feed would,
/// so a test checks that the Mac draws them, never how they are decided
/// (Go's, tested in `internal/inboxfeed`).
package extension TestInboxFeeds {
    /// Artifact `o<id>` with `actions` and `refs`.
    static func artifact(_ id: Int64, folder: Int64 = 0, actions: [CardAction] = [], refs: [RefFacts] = []) -> Card {
        Card(id: "o\(id)", folderID: folder, cardKind: .artifact, title: "o\(id)", sourceLine: "", preview: "",
             stamp: "2026-11-16T10:00:00Z", living: false, unread: true, priority: "medium", pinned: false,
             blocks: "", body: "", bodyClipped: false, link: "", contentHash: "", actions: actions, refFacts: refs)
    }

    /// An approval as the feed words it: `title`, `summary` lines, and Go's
    /// target-button state of its row (`target` "" for none).
    static func approval(
        title: String, summary: [String] = [], target: String = "", superseded: Bool = false
    ) -> Approval {
        Approval(tool: "create_target", title: title, summary: summary.joined(separator: "\n"),
                 argsSHA256: "", status: "pending", error: "", proposer: "", reason: "", editOnMac: false,
                 target: target, targetNote: "", targetUntil: "", superseded: superseded, disclosure: "",
                 recipeText: "", diff: [], recipeClipped: false)
    }

    /// A Reply button as Go draws it: `detail` its state, `note` its caption.
    static func reply(
        _ index: Int, label: String, detail: String, note: String = "", state: ActionState = .enabled
    ) -> CardAction {
        CardAction(index: index, kind: "reply", label: label, state: state, detail: detail, note: note, until: "")
    }
}
