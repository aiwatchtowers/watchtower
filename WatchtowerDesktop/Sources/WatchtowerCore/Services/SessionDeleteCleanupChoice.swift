import Foundation

/// What the Delete dialog offers from a session's cleanup plan, and what
/// its **Delete and Clean Up** may apply (board #535, spec
/// 2026-10-12-session-cleanup §12, PROJ-18: exactly the planned items
/// shown).
///
/// Only items of a kind this build knows are shown, so only they are ever
/// applied. The dialog plans while the session's own terminal still runs:
/// a worktree Go keeps only for `process_running` may be kept by that very
/// terminal, so it is shown as removed once the terminal closes, with the
/// branch checked out in it (kept `checked_out` for the same cause). Those
/// need a fresh plan after the close; an apply then names the shown keys
/// that plan finds removable, never another.
package struct SessionDeleteCleanupChoice: Equatable, Sendable {
    /// Pending removals of a known kind: removed now.
    package let removable: [SessionCleanupItem]
    /// Kept only while the session's terminal may run in them: removed
    /// after it closes, if nothing else holds them.
    package let afterClose: [SessionCleanupItem]
    /// Every other kept item of a known kind (the dialog's "Kept:" part).
    package let kept: [SessionCleanupItem]

    package init(plan: SessionCleanupPlan) {
        let known = plan.items.filter { $0.kind.isKnown && !$0.key.isEmpty }
        removable = known.filter(\.isPendingRemoval)
        let busy = known.filter { $0.kind == .worktree && Self.isKept($0, for: .processRunning) }
        let busyBranches = Set(busy.map(\.branch).filter { !$0.isEmpty })
        let branches = known.filter {
            $0.kind == .branch && Self.isKept($0, for: .checkedOut) && busyBranches.contains($0.name)
        }
        afterClose = busy + branches
        let later = Set(afterClose.map(\.key))
        kept = known.filter { $0.action == .keep && !later.contains($0.key) }
    }

    /// The keys the dialog shows as removed, now or after the close.
    package var shownKeys: [String] { (removable + afterClose).map(\.key) }

    /// Whether the dialog offers Delete and Clean Up.
    package var offersCleanup: Bool { !shownKeys.isEmpty }

    /// Whether Delete and Clean Up must plan again once the terminal closed.
    package var needsReplan: Bool { !afterClose.isEmpty }

    /// The shown keys `replan` (made after the close) finds removable, in
    /// its order: what the apply names. A key the dialog did not show is
    /// never among them.
    package func keysToApply(after replan: SessionCleanupPlan) -> [String] {
        let shown = Set(shownKeys)
        return replan.removableKeys.filter(shown.contains)
    }

    /// The shown items `final` (the apply's result, or the fresh plan when
    /// nothing was left to apply) kept rather than removed.
    package func keptItems(in final: SessionCleanupPlan) -> [SessionCleanupItem] {
        let shown = Set(shownKeys)
        return final.items.filter { shown.contains($0.key) && $0.action == .keep && !$0.done && $0.error.isEmpty }
    }

    private static func isKept(_ item: SessionCleanupItem, for code: SessionCleanupReason.Code) -> Bool {
        item.action == .keep && item.reason == .known(code)
    }
}

extension SessionCleanupItem.Kind {
    /// A kind this build knows (not `.unknown`).
    package var isKnown: Bool {
        if case .unknown = self { return false }
        return true
    }
}
