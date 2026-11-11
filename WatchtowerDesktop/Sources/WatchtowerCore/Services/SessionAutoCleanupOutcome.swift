import Foundation

/// Where an item of a background cleanup's result lands (spec
/// 2026-11-10-auto-cleanup-on-session-delete §3).
package enum CleanupItemGroup: Equatable, Sendable {
    /// Removed by the apply.
    case removed
    /// Kept for the owner's work; the row is deleted and the notice names it.
    case keptOnPurpose
    /// Not the session's to remove; not shown.
    case notOurs
    /// Should have gone and did not; the row stays, Not fully cleaned.
    case couldNot
}

/// What the background cleanup after a session delete came to: clean (the
/// row goes, with a notice when anything was removed) or not fully cleaned
/// (the row stays with a warning line). Pure; the strings are spec §3's.
package enum SessionAutoCleanupOutcome: Equatable, Sendable {
    /// Nil notice: nothing was removed, the row simply goes.
    case clean(SessionCleanupNotice?)
    /// The row's warning line.
    case notFullyCleaned(mark: String)

    /// The run error of a cleanup stopped at the 10-minute limit.
    package static let timeoutRunError = "the cleanup took longer than 10 minutes"

    /// An item's group: removed, an error or a removal left pending is
    /// could not, a kept item goes by its reason.
    package static func group(_ item: SessionCleanupItem) -> CleanupItemGroup {
        if item.done { return .removed }
        guard item.error.isEmpty, item.action == .keep, let reason = item.reason else { return .couldNot }
        return group(reason: reason)
    }

    /// A kept item's group by its reason. An unknown code is could not
    /// (fail-safe); Go's codes are listed in
    /// `internal/sessioncleanup/testdata/reason_codes.json`.
    package static func group(reason: SessionCleanupReason) -> CleanupItemGroup {
        guard case let .known(code) = reason else { return .couldNot }
        switch code {
        case .uncommittedChanges, .unpushedCommits, .operationInProgress, .locked, .containsWorktree,
             // Merged into what cannot be told (ask #1240): kept, named in
             // the notice, and it does not keep the row.
             .defaultBranchUnknown:
            return .keptOnPurpose
        case .notThisSession, .existedBeforeSession, .createdUnknown, .mainFolder, .workbenchFolder,
             .claudeHome, .defaultBranch, .checkedOut,
             // Not in spec §3's table: sweep only (session_recent), gone or
             // not one (not_a_*), follows its worktree (worktree_kept), an
             // entry that is no longer stale (bundle_exists).
             .sessionRecent, .notAWorktree, .notABranch, .worktreeKept, .bundleExists:
            return .notOurs
        case .gitRefused, .moved, .processRunning, .processUnknown, .sessionInIt, .checkFailed,
             .bundleUnreadable, .notAttempted,
             // Not in spec §3's table: the background apply names no items
             // and has no caller session, so these mean something is off.
             .youAreInIt, .notSelected, .notInPlan:
            return .couldNot
        }
    }

    /// The outcome of one session's background apply. `result` is the
    /// apply's JSON (nil when none was printed); `runError` says why the run
    /// failed as a whole (a non-zero exit, `timeoutRunError`), nil when it
    /// did not.
    package static func evaluate(
        result: SessionCleanupPlan?,
        title: String,
        runError: String?
    ) -> Self {
        if let result {
            let couldNot = result.items.filter { group($0) == .couldNot }
            if !couldNot.isEmpty { return .notFullyCleaned(mark: itemsMark(couldNot)) }
        }
        if let runError { return .notFullyCleaned(mark: runMark(runError)) }
        guard let result else { return .notFullyCleaned(mark: runMark("it printed no result")) }
        return .clean(SessionCleanupNotice.single(title: title, result: result))
    }

    /// "Not fully cleaned: 1 worktree — a process is running in it."
    private static func itemsMark(_ items: [SessionCleanupItem]) -> String {
        let counts = SessionCleanupPresentation.countText(items)
            ?? (items.count == 1 ? "1 item" : "\(items.count) items")
        var seen: Set<String> = []
        let reasons = items.compactMap { item -> String? in
            let phrase = item.reason.map(SessionCleanupPresentation.reasonText) ?? "could not be removed"
            return seen.insert(phrase).inserted ? phrase : nil
        }
        return "Not fully cleaned: \(counts) — \(reasons.joined(separator: ", "))."
    }

    /// The mark of a row whose cleanup ended clean but whose DELETE then
    /// failed: "Not fully cleaned: the session could not be deleted —
    /// database is locked."
    package static func deleteFailedMark(_ error: String) -> String {
        "Not fully cleaned: the session could not be deleted — \(sentence(error))."
    }

    /// `text` trimmed, without trailing full stops.
    private static func sentence(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// "Not fully cleaned: the cleanup could not run — watchtower exited
    /// with code 1."
    private static func runMark(_ runError: String) -> String {
        if runError == timeoutRunError { return "Not fully cleaned: \(timeoutRunError)." }
        return "Not fully cleaned: the cleanup could not run — \(sentence(runError))."
    }
}

/// The notice on the Undo bar's place after a clean background cleanup:
/// "Cleaned up “T”: removed 3 worktrees and 12 branches (~2.1 GB)." Built
/// in two parts: `lead` ("Cleaned up", or "Cleaned up 4 sessions" when
/// joined) is the view's emphasis, `rest` the remainder.
package struct SessionCleanupNotice: Equatable, Sendable {
    package let lead: String
    package let rest: String

    package var text: String { lead + rest }

    package init(lead: String, rest: String) {
        self.lead = lead
        self.rest = rest
    }

    /// One session's notice; nil when nothing was removed or kept on
    /// purpose.
    package static func single(title: String, result: SessionCleanupPlan) -> Self? {
        make(lead: "Cleaned up", subject: " “\(title)”", results: [result])
    }

    /// Several deletes in a row as one notice: "Cleaned up 4 sessions:
    /// removed …"; one entry reads as `single`. Nil when nothing was removed
    /// or kept on purpose.
    package static func joined(_ notices: [(title: String, result: SessionCleanupPlan)]) -> Self? {
        guard notices.count != 1 else { return single(title: notices[0].title, result: notices[0].result) }
        return make(lead: "Cleaned up \(notices.count) sessions", subject: "", results: notices.map(\.result))
    }

    private static func make(lead: String, subject: String, results: [SessionCleanupPlan]) -> Self? {
        let items = results.flatMap(\.items)
        let removed = items.filter { SessionAutoCleanupOutcome.group($0) == .removed }
        let parts = SessionCleanupPresentation.countParts(removed)
        let kept = items.filter { SessionAutoCleanupOutcome.group($0) == .keptOnPurpose }
        let keptText = SessionCleanupPresentation.keptText(kept)
        guard !parts.isEmpty else {
            // Nothing removed: the notice still names what was kept.
            return keptText.map { Self(lead: lead, rest: "\(subject): kept \($0).") }
        }
        let bytes = results.reduce(Int64(0)) { $0 + $1.removedBytes }
        var rest = "\(subject): removed \(listText(parts))"
        if bytes > 0 { rest += " (~\(SessionCleanupPresentation.byteText(bytes)))" }
        rest += "."
        if let keptText { rest += " Kept \(keptText)." }
        return Self(lead: lead, rest: rest)
    }

    /// "a", "a and b", "a, b and c".
    private static func listText(_ parts: [String]) -> String {
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + (parts.last ?? "")
    }
}
