import Foundation

/// The menu's numbers and the sidebar's Inbox badge (spec "Unread counts and
/// the sidebar badge"): one rule the owner can check by adding the menu's
/// numbers. Pure; `ActionStripViewModel.badgeCount` feeds it from one read.
package enum InboxFolderCounts {
    /// Each folder's own count (not its children's), for every folder of
    /// `tree`; a folder with nothing is 0.
    /// - An artifact whose document has no row ref counts 1 while unread.
    /// - An artifact with row refs counts its rows that wait on the owner
    ///   (`refState`), whatever its read state.
    /// - `legacy` adds the counts the folder shows outside artifacts: today's
    ///   terms (ideas to judge, unread messages, the unread briefing in the
    ///   root; proposals, due reminders and notices in Needs approval).
    /// Needs approval counts the approvals it shows, whether a recipe card
    ///   or a native one draws each: only its `legacy` count, never its
    ///   artifacts' rows, which are those same approvals.
    /// `refs` is `refs(of: artifacts)`: each document parsed once.
    package static func counts(
        tree: InboxFolderTree,
        artifacts: [Int64: [AutomationOutputCard]],
        refs: [Int64: [InboxRef]],
        refState: InboxRefState,
        legacy: [Int64: Int]
    ) -> [Int64: Int] {
        var out: [Int64: Int] = [:]
        for folder in tree.folders {
            var count = legacy[folder.id] ?? 0
            if folder.kind != .approvals {
                count += (artifacts[folder.id] ?? []).reduce(0) {
                    $0 + artifactCount($1, refs: refs[$1.id] ?? [], refState: refState)
                }
            }
            out[folder.id] = count
        }
        return out
    }

    /// One artifact's share of its folder's count; `refs` are its rows' refs.
    package static func artifactCount(_ card: AutomationOutputCard, refs: [InboxRef], refState: InboxRefState) -> Int {
        if refs.isEmpty { return card.isUnread ? 1 : 0 }
        return refs.filter(refState.waits).count
    }

    /// Each artifact's row refs (card id → refs), its document parsed once:
    /// what `InboxRefState.read` checks and `counts` counts.
    package static func refs(of artifacts: [Int64: [AutomationOutputCard]]) -> [Int64: [InboxRef]] {
        var out: [Int64: [InboxRef]] = [:]
        for card in artifacts.values.joined() { out[card.id] = InboxRef.refs(blocksJSON: card.blocksJSON) }
        return out
    }

    /// The sidebar badge: the sum over the folders the menu shows (a hidden
    /// folder and everything below it leave the badge).
    package static func badge(counts: [Int64: Int], tree: InboxFolderTree) -> Int {
        tree.folders.filter { tree.isVisible($0.id) }.reduce(0) { $0 + (counts[$1.id] ?? 0) }
    }
}
