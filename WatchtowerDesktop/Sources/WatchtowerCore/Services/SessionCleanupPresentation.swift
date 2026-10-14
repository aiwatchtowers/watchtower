import Foundation

/// The English strings of session cleanup (spec 2026-10-12-session-cleanup
/// §12): the Delete dialog's offer line, the sheet's reasons, sizes and
/// owner column, and the session report's line. Reason phrases and sizes
/// mirror Go's `sessioncleanup.ReasonPhrase` and `SizeText`, so the app and
/// the CLI's summary say the same thing; `SessionCleanupPresentationTests`
/// holds the two in step.
package enum SessionCleanupPresentation {
    package typealias Item = SessionCleanupItem
    package typealias Reason = SessionCleanupReason

    /// Go's `reasonPhrases`, word for word; a code Go has no phrase for
    /// reads as the code with spaces, as Go's fallback does.
    private static let phrases: [Reason.Code: String] = [
        .mainFolder: "the main folder",
        .workbenchFolder: "a workbench folder",
        .locked: "locked",
        .uncommittedChanges: "uncommitted changes",
        .processRunning: "a process is running in it",
        .processUnknown: "a process could not be checked",
        .sessionInIt: "another session works in it",
        .youAreInIt: "you are in it",
        .unpushedCommits: "unpushed commits",
        .operationInProgress: "an operation in progress",
        .defaultBranch: "the default branch",
        .defaultBranchUnknown: "default branch unknown",
        .checkedOut: "checked out",
        .claudeHome: "under ~/.claude",
        .notAWorktree: "not a worktree",
        .notABranch: "not a branch",
        .sessionRecent: "its session was active recently",
        .checkFailed: "could not be checked",
        .containsWorktree: "another worktree is inside",
        .notThisSession: "not this session's",
        .existedBeforeSession: "existed before the session",
        .createdUnknown: "creation time unknown",
        .gitRefused: "git refused",
        .moved: "moved since the check",
        .notSelected: "not selected",
        .notInPlan: "not in the plan",
        .notAttempted: "not attempted after a failure",
        .bundleUnreadable: "its bundle could not be checked"
    ]

    /// A reason in words: "uncommitted changes".
    package static func reasonText(_ reason: Reason) -> String {
        if case let .known(code) = reason, let phrase = phrases[code] { return phrase }
        return reason.code.replacingOccurrences(of: "_", with: " ")
    }

    // MARK: Sizes

    /// Bytes in decimal units, as Finder shows them: "12 GB", "1.5 GB",
    /// "512 B" (Go's `SizeText`).
    package static func byteText(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1000, index < units.count - 1 {
            value /= 1000
            index += 1
        }
        let format = index == 0 || value >= 10 ? "%.0f %@" : "%.1f %@"
        return String(format: format, value, units[index])
    }

    /// One item's size: "~12 GB" ("~": APFS clones share blocks, so less
    /// may be freed), or "size unknown".
    package static func sizeText(bytes: Int64, known: Bool) -> String {
        known ? "~" + byteText(bytes) : "size unknown"
    }

    // MARK: Counts

    private static let nouns: [(kind: Item.Kind, one: String, many: String)] = [
        (.worktree, "worktree", "worktrees"),
        (.branch, "branch", "branches"),
        (.process, "process", "processes"),
        (.lsreg, "LaunchServices entry", "LaunchServices entries")
    ]

    /// "2 worktrees, 3 branches (~12 GB)" over `items` (the sheet's ticked
    /// items, or a plan's pending removals); nil when none is of a known
    /// kind. Sizes are the worktrees' only, as Go's summary counts them.
    package static func totalText(_ items: [Item]) -> String? {
        guard let counts = countText(items) else { return nil }
        return counts + sizeSuffix(items)
    }

    private static func countText(_ items: [Item]) -> String? {
        let parts = nouns.compactMap { noun -> String? in
            let count = items.filter { $0.kind == noun.kind }.count
            guard count > 0 else { return nil }
            return count == 1 ? "1 \(noun.one)" : "\(count) \(noun.many)"
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// " (~12 GB)", " (size unknown)", " (~12 GB, some sizes unknown)", or
    /// "" when the worktrees hold no known bytes and none is unknown (Go's
    /// `sizePart`).
    private static func sizeSuffix(_ items: [Item]) -> String {
        let worktrees = items.filter { $0.kind == .worktree }
        let total = worktrees.reduce(Int64(0)) { $0 + $1.bytes }
        let unknown = worktrees.contains { !$0.bytesKnown }
        switch (unknown, total) {
        case (true, 0): return " (size unknown)"
        case (true, _): return " (~\(byteText(total)), some sizes unknown)"
        case (false, 0): return ""
        default: return " (~\(byteText(total)))"
        }
    }

    // MARK: Delete dialog

    /// The Delete dialog's line: "Also clean up: 2 worktrees, 3 branches
    /// (~12 GB). After the terminal closes: 1 worktree, 1 branch, if
    /// nothing else runs there. Kept: 1 worktree — uncommitted changes."
    /// Nil when the dialog shows nothing to remove (it is then as before).
    package static func offerLine(_ plan: SessionCleanupPlan) -> String? {
        offerLine(SessionDeleteCleanupChoice(plan: plan))
    }

    package static func offerLine(_ choice: SessionDeleteCleanupChoice) -> String? {
        var parts: [String] = []
        if let now = totalText(choice.removable) { parts.append("Also clean up: \(now).") }
        if let later = countText(choice.afterClose) {
            parts.append("After the terminal closes: \(later), if nothing else runs there.")
        }
        guard !parts.isEmpty else { return nil }
        if let kept = keptText(choice.kept) { parts.append("Kept: \(kept).") }
        return parts.joined(separator: " ")
    }

    /// The page's notice after Delete and Clean Up when Go kept shown items
    /// at apply time: "“Fix the form” deleted; 1 item was kept: feat/x —
    /// unpushed commits". Nil when nothing shown was kept.
    package static func keptAfterDeleteNotice(title: String, kept: [Item]) -> String? {
        guard !kept.isEmpty else { return nil }
        let list = kept.map { item in
            "\(item.name.isEmpty ? item.key : item.name) — \(reasonText(item.reason ?? .unknown("")))"
        }
        let count = kept.count == 1 ? "1 item was kept" : "\(kept.count) items were kept"
        return "“\(title)” deleted; \(count): \(list.joined(separator: "; "))"
    }

    /// "1 worktree, 2 branches — uncommitted changes, checked out": the
    /// kept worktrees and branches with their reasons in first-seen order
    /// (Go's `keptPart`); nil when none is kept.
    package static func keptText(_ items: [Item]) -> String? {
        let kept = items.filter { $0.action == .keep && ($0.kind == .worktree || $0.kind == .branch) }
        guard let counts = countText(kept) else { return nil }
        var seen: Set<String> = []
        let reasons = kept.compactMap { item -> String? in
            let reason = item.reason ?? .unknown("")
            guard seen.insert(reason.code).inserted else { return nil }
            return reasonText(reason)
        }
        return counts + " — " + reasons.joined(separator: ", ")
    }

    // MARK: Sweep owner

    /// The sweep sheet's owner column: "Fix the login form · active 2d ago",
    /// "Session 12" without a title or a readable stamp, "Owner unknown"
    /// for a pre-feature or deleted session.
    package static func ownerText(_ owner: SessionCleanupOwner, now: Date = Date()) -> String {
        guard !owner.isUnknown, let id = owner.sessionID else { return "Owner unknown" }
        let name = owner.title.isEmpty ? "Session \(id)" : owner.title
        guard let age = TimeFormatting.shortAge(from: owner.lastActive, now: now) else { return name }
        return name + " · active " + (age == "just now" ? age : age + " ago")
    }

    // MARK: Sweep hint

    /// Above this many removable bytes a sweep plan raises the one-time
    /// hint (1 GB, decimal as `byteText`).
    package static let sweepHintThresholdBytes: Int64 = 1_000_000_000

    /// The known sizes of the worktrees a sweep plan could remove — pending
    /// removals only: a kept worktree (a recent session's, uncommitted
    /// work) is not space the owner can free here.
    package static func sweepRemovableBytes(_ plan: SessionCleanupPlan) -> Int64 {
        plan.items
            .filter { $0.kind == .worktree && $0.isPendingRemoval && $0.bytesKnown }
            .reduce(Int64(0)) { $0 + $1.bytes }
    }

    /// True when every worktree a sweep plan could remove was measured: a
    /// plan with an unmeasured one (over Go's size budget, a read error)
    /// cannot tell that the workbench holds 1 GB or less.
    package static func sweepSizesKnown(_ plan: SessionCleanupPlan) -> Bool {
        !plan.items.contains { $0.kind == .worktree && $0.isPendingRemoval && !$0.bytesKnown }
    }

    /// The workbench's one-time hint: "Old worktrees use ~38 GB." Nil when
    /// the plan's removable worktrees hold no more than 1 GB.
    package static func sweepHint(_ plan: SessionCleanupPlan) -> String? {
        let bytes = sweepRemovableBytes(plan)
        guard bytes > sweepHintThresholdBytes else { return nil }
        return "Old worktrees use ~\(byteText(bytes))."
    }

    // MARK: Session report

    /// The session report's "Cleanup" line: Go's stored summary; a neutral
    /// line when a result is stored but does not decode (a cleanup ran — it
    /// must not read as never cleaned up); nil when the decoded result has
    /// no summary.
    package static func reportLine(_ record: SessionCleanupRecord) -> String? {
        guard let result = record.result else { return "Cleanup ran — result unreadable" }
        return result.summary.isEmpty ? nil : result.summary
    }
}
