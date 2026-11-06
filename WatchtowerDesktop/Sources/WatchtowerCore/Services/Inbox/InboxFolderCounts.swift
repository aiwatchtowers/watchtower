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
    package static func counts(
        tree: InboxFolderTree,
        artifacts: [Int64: [AutomationOutputCard]],
        refState: InboxRefState,
        legacy: [Int64: Int]
    ) -> [Int64: Int] {
        var out: [Int64: Int] = [:]
        for folder in tree.folders {
            var count = legacy[folder.id] ?? 0
            if folder.kind != .approvals {
                count += (artifacts[folder.id] ?? []).reduce(0) { $0 + artifactCount($1, refState: refState) }
            }
            out[folder.id] = count
        }
        return out
    }

    /// One artifact's share of its folder's count.
    package static func artifactCount(_ card: AutomationOutputCard, refState: InboxRefState) -> Int {
        let refs = InboxRef.refs(blocksJSON: card.blocksJSON)
        if refs.isEmpty { return card.isUnread ? 1 : 0 }
        return refs.filter(refState.waits).count
    }

    /// Every row ref of `artifacts`: what `InboxRefState.read` checks.
    package static func refs(of artifacts: [Int64: [AutomationOutputCard]]) -> [InboxRef] {
        artifacts.values.flatMap { $0.flatMap { InboxRef.refs(blocksJSON: $0.blocksJSON) } }
    }

    /// The sidebar badge: the sum over the folders the menu shows (a hidden
    /// folder and everything below it leave the badge).
    package static func badge(counts: [Int64: Int], tree: InboxFolderTree) -> Int {
        tree.folders.filter { tree.isVisible($0.id) }.reduce(0) { $0 + (counts[$1.id] ?? 0) }
    }
}
