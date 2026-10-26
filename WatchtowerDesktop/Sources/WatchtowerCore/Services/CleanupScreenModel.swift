import Foundation

/// A Clean Up screen row's state chip (spec 2026-10-26-worktree-cleanup-screen
/// §4.1). `kept` and `changedSinceCheck` carry the chip's words.
package enum CleanupRowState: Equatable, Sendable {
    case checking, merged, pushed
    case kept(String)
    /// An apply-time keep: moved since the check, git refused, …
    case changedSinceCheck(String)
    case removing
    case failed(String)

    /// Rows in the **Can go** group; the rest are **Kept**.
    var canGo: Bool {
        switch self {
        case .checking, .merged, .pushed, .removing: true
        case .kept, .changedSinceCheck, .failed: false
        }
    }
}

/// One row of the Clean Up screen: a worktree with its branch and its
/// bundles' LaunchServices entries, a branch with no worktree, or a stale
/// LaunchServices entry (§4.2).
package struct CleanupRow: Identifiable, Equatable, Sendable {
    /// The lead item's key (the worktree's, or the branch's).
    package var id: String
    package var kind: SessionCleanupItem.Kind
    package var title: String
    package var subtitle: String
    package var ownerText: String
    /// False when the Owner column has nothing to say ("—").
    package var hasOwner: Bool
    package var origin: SessionCleanupOrigin
    package var sizeText: String
    /// A worktree still being checked or measured: its size is on the way.
    package var sizePending: Bool
    /// Known size of a measured worktree; nil otherwise.
    package var bytes: Int64?
    package var lastCommitAt: Date?
    package var lastCommitText: String
    package var merged: Bool
    package var state: CleanupRowState
    /// "branch kept — checked out elsewhere" when the worktree goes alone.
    package var branchNote: String?
    package var canChoose: Bool
    /// What ticking this row sends with `--item`; empty when it cannot be
    /// chosen.
    package var applyKeys: [String]
}

/// The toolbar's filters (§4.4); nothing saved.
package struct CleanupFilters: Equatable, Sendable {
    package enum Kind: Equatable, Sendable { case all, worktrees, branches }
    package enum Age: Equatable, Sendable {
        case any, days7, days30, days90

        var days: Double? {
            switch self {
            case .any: nil
            case .days7: 7
            case .days30: 30
            case .days90: 90
            }
        }
    }
    package enum Owner: Equatable, Sendable {
        case any, session, subagent, placed, manual

        func matches(_ origin: SessionCleanupOrigin) -> Bool {
            switch self {
            case .any: true
            case .session: origin == .session
            case .subagent: origin == .subagent
            case .placed: origin == .placed
            case .manual: origin == .manual
            }
        }
    }

    package var search = ""
    package var kind: Kind = .all
    package var age: Age = .any
    package var owner: Owner = .any
    package var mergedOnly = false

    package init() {}
}

package enum CleanupSort: Equatable, Sendable { case size, name, lastCommit }

/// The Clean Up screen's rows, groups, filters, ticking and every text it
/// shows, from a (streamed) plan's items. Pure: `now` is injected.
package struct CleanupScreenModel {
    private typealias Item = SessionCleanupItem
    private typealias Presentation = SessionCleanupPresentation

    private struct Entry {
        var row: CleanupRow
        /// The items ticking the row removes, minus a worktree's bundles:
        /// what the footer counts.
        var counted: [Item]
        var keptReason: SessionCleanupReason?
    }

    private let entries: [Entry]
    private let now: Date

    package init(
        items: [SessionCleanupItem],
        checking: Set<String>,
        sizing: Set<String>,
        removing: Set<String> = [],
        now: Date
    ) {
        self.now = now
        let live = items.filter { !$0.done }
        var claimed: Set<String> = []
        var pairs: [String: (branch: Item?, bundles: [Item])] = [:]
        for wt in live where wt.kind == .worktree {
            let branch = wt.branch.isEmpty ? nil : live.first {
                $0.kind == .branch && $0.name == wt.branch && !claimed.contains($0.key)
            }
            let bundles = live.filter { $0.kind == .lsreg && !$0.worktree.isEmpty && $0.worktree == wt.name }
            branch.map { claimed.insert($0.key) }
            bundles.forEach { claimed.insert($0.key) }
            pairs[wt.key] = (branch, bundles)
        }
        let context = BuildContext(checking: checking, sizing: sizing, removing: removing, now: now)
        entries = live.compactMap { item in
            if item.kind == .worktree {
                let pair = pairs[item.key]
                return context.entry(item, branch: pair?.branch, bundles: pair?.bundles ?? [])
            }
            return claimed.contains(item.key) ? nil : context.entry(item, branch: nil, bundles: [])
        }
    }

    // MARK: Rows

    package func rows(filters: CleanupFilters, sort: CleanupSort, ascending: Bool) -> (canGo: [CleanupRow], kept: [CleanupRow]) {
        let shown = entries.map(\.row).filter { matches($0, filters) }.sorted {
            Self.ordered($0, $1, sort: sort, ascending: ascending)
        }
        return (shown.filter(\.state.canGo), shown.filter { !$0.state.canGo })
    }

    /// The Kept header's counts by reason: "5 unpushed commits · 3 recent
    /// sessions · 1 in use"; "" when nothing is kept.
    package func keptSummary() -> String {
        let kept = entries.filter { !$0.row.state.canGo }
        let groups = Self.grouped(kept.map { Self.summaryGroup($0) })
        return groups.map { "\($0.count) \(Self.summaryPhrase($0.key, count: $0.count))" }.joined(separator: " · ")
    }

    /// The empty screen's kept line (mockup G): "Kept: 1 — unpushed
    /// commits", "Kept: 3 — 2 unpushed commits · 1 recent session"; nil
    /// when nothing is kept.
    package func emptyKeptText() -> String? {
        let kept = entries.filter { !$0.row.state.canGo }
        guard !kept.isEmpty else { return nil }
        let groups = Self.grouped(kept.map { Self.summaryGroup($0) })
        let reasons = groups.count == 1
            ? Self.summaryPhrase(groups[0].key, count: groups[0].count)
            : keptSummary()
        return "Kept: \(kept.count) — \(reasons)"
    }

    /// The empty screen's button that shows the kept rows anyway.
    package static let showKeptTitle = "Show kept"

    /// The session scope's chip (mockup D): "Session: “Login redirect” ✕";
    /// an untitled or unknown session reads "Session N".
    package static func sessionChipText(title: String?, sessionID: Int64) -> String {
        let name = title.flatMap { $0.isEmpty ? nil : $0 } ?? "Session \(sessionID)"
        return "Session: “\(name)” ✕"
    }

    // MARK: Ticking

    /// `ticks` plus every row the filters show that can be chosen.
    package func selectAll(filters: CleanupFilters, into ticks: Set<String>) -> Set<String> {
        ticks.union(entries.map(\.row).filter { $0.canChoose && matches($0, filters) }.map(\.id))
    }

    /// Ticks (or unticks) every row that can be chosen between `from` and
    /// `to` in `rows`, both ends included; only `to` when `from` is not
    /// shown.
    package func tickRange(from: String, to: String, in rows: [CleanupRow], on: Bool, ticks: Set<String>) -> Set<String> {
        guard let end = rows.firstIndex(where: { $0.id == to }) else { return ticks }
        let start = rows.firstIndex { $0.id == from } ?? end
        let ids = rows[min(start, end)...max(start, end)].filter(\.canChoose).map(\.id)
        return on ? ticks.union(ids) : ticks.subtracting(ids)
    }

    /// Drops ticks whose row is gone or now kept; a row being checked
    /// again keeps its tick.
    package func liveTicks(_ ticks: Set<String>) -> Set<String> {
        ticks.intersection(entries.filter(\.row.state.canGo).map(\.row.id))
    }

    /// The keys an apply of `ticks` names, in plan order: the ticked rows
    /// that can be chosen, filters or not (known kinds only).
    package func applyKeys(for ticks: Set<String>) -> [String] {
        chosen(ticks).flatMap(\.row.applyKeys)
    }

    // MARK: Totals

    /// The footer's total: "3 worktrees, 3 branches · ~25 GB",
    /// "Nothing selected".
    package func totalText(for ticks: Set<String>) -> String {
        guard let parts = totalParts(for: ticks) else { return "Nothing selected" }
        return parts.counts + (parts.size.map { " · " + $0 } ?? "")
    }

    /// `totalText`'s two halves — ("3 worktrees, 3 branches", "~25 GB") —
    /// for a footer that sets the counts apart; nil when nothing is chosen.
    package func totalParts(for ticks: Set<String>) -> (counts: String, size: String?)? {
        let chosen = chosen(ticks)
        let counts = Self.countParts(chosen.flatMap(\.counted))
        guard !counts.isEmpty else { return nil }
        return (counts.joined(separator: ", "), Self.sizePart(chosen))
    }

    /// "Remove 3 worktrees and 3 branches (~25 GB)?"
    package func confirmationTitle(for ticks: Set<String>) -> String {
        let chosen = chosen(ticks)
        let counts = Self.countParts(chosen.flatMap(\.counted))
        guard let last = counts.last else { return "Nothing selected" }
        let list = counts.count == 1 ? last : counts.dropLast().joined(separator: ", ") + " and " + last
        return "Remove \(list)" + (Self.sizePart(chosen).map { " (\($0))" } ?? "") + "?"
    }

    private func chosen(_ ticks: Set<String>) -> [Entry] {
        entries.filter { $0.row.canChoose && ticks.contains($0.row.id) }
    }

    // MARK: Result and progress

    /// The result bar after an apply: ("Freed ~15 GB · removed 2 worktrees,
    /// 2 branches", "kept 1 — changed since the check"). Only the keys the
    /// apply named (`sent`) that ended kept count as kept: Go returns the
    /// plan-time keeps (unpushed commits, …) with their own reason too, and
    /// those were never the owner's choice.
    package static func resultText(_ plan: SessionCleanupPlan, sent: Set<String>) -> (freed: String, kept: String?) {
        let counted = plan.items.filter { $0.kind == .worktree || $0.kind == .branch }
        let removed = countParts(counted.filter(\.done)).joined(separator: ", ")
        let freed: String
        if removed.isEmpty {
            freed = "Nothing removed"
        } else if plan.removedBytes > 0 {
            let bound = plan.removedBytesKnown ? "" : "at least "
            freed = "Freed \(bound)~\(Presentation.byteText(plan.removedBytes)) · removed \(removed)"
        } else {
            freed = "Removed \(removed)"
        }
        let kept = counted.filter {
            $0.action == .keep && sent.contains($0.key)
        }
        guard !kept.isEmpty else { return (freed, nil) }
        let groups = grouped(kept.map { words($0.reason) })
        let reasons = groups.count == 1
            ? groups[0].key
            : groups.map { "\($0.count) \($0.key)" }.joined(separator: ", ")
        return (freed, "kept \(kept.count) — \(reasons)")
    }

    /// The progress line under the title. `sessionScope` words the ready
    /// line for one session's scope ("this session left …"). A finished
    /// apply (`.done`) reads as a fresh check: its result is the result
    /// bar's (`resultText`, which needs the keys the apply sent).
    package static func progressText(
        _ stage: CleanupStage,
        worktrees: Int,
        branches: Int,
        sessionScope: Bool,
        now: Date
    ) -> String {
        let counts = [count(worktrees, "worktree", "worktrees"), count(branches, "branch", "branches")]
            .joined(separator: ", ")
        let checked = { (at: Date) in
            "Checked \(ageText(at, now: now)) · " + (sessionScope ? "this session left " : "") + counts
        }
        switch stage {
        case .listing:
            return "Listing worktrees…"
        case let .checking(done, total):
            return "Checking \(done) of \(total) \(total == 1 ? "worktree" : "worktrees")…"
        case let .sizing(done, total):
            return "Measuring sizes \(done) of \(total)…"
        case let .ready(at):
            return checked(at)
        case .applying:
            return "Removing…"
        case .done:
            return checked(now)
        case let .failed(message):
            return "Clean up failed: \(message)"
        }
    }

    /// "just now", "20 min ago", "2 h ago", "9 days ago", "5 weeks ago",
    /// "2 months ago", "1 year ago": the owner and "Checked …" wording.
    package static func ageText(_ date: Date, now: Date) -> String {
        age(date, now: now) { "\($0) h ago" }
    }

    /// The Last commit column: as `ageText`, but hours in full ("1 hour
    /// ago", "3 hours ago").
    package static func lastCommitText(_ date: Date, now: Date) -> String {
        age(date, now: now) { count($0, "hour", "hours") + " ago" }
    }

    private static func age(_ date: Date, now: Date, hours: (Int) -> String) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86400 { return hours(Int(seconds / 3600)) }
        let days = Int(seconds / 86400)
        if days < 14 { return count(days, "day", "days") + " ago" }
        if days < 60 { return "\(days / 7) weeks ago" }
        if days < 365 { return "\(days / 30) months ago" }
        return count(days / 365, "year", "years") + " ago"
    }

    // MARK: Filtering and sorting

    private func matches(_ row: CleanupRow, _ filters: CleanupFilters) -> Bool {
        let query = filters.search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty,
           !row.title.localizedCaseInsensitiveContains(query),
           !row.subtitle.localizedCaseInsensitiveContains(query) {
            return false
        }
        switch filters.kind {
        case .all: break
        case .worktrees: guard row.kind == .worktree else { return false }
        case .branches: guard row.kind == .branch else { return false }
        }
        if let days = filters.age.days {
            guard let at = row.lastCommitAt, now.timeIntervalSince(at) > days * 86400 else { return false }
        }
        return filters.owner.matches(row.origin) && (!filters.mergedOnly || row.merged)
    }

    /// The sorted column first (rows without a value last whatever the
    /// direction), then the name, then the key.
    private static func ordered(_ lhs: CleanupRow, _ rhs: CleanupRow, sort: CleanupSort, ascending: Bool) -> Bool {
        let first: ComparisonResult = switch sort {
        case .size: compare(lhs.bytes, rhs.bytes, ascending: ascending)
        case .lastCommit: compare(lhs.lastCommitAt, rhs.lastCommitAt, ascending: ascending)
        case .name: directed(lhs.title.localizedStandardCompare(rhs.title), ascending: ascending)
        }
        if first != .orderedSame { return first == .orderedAscending }
        let name = lhs.title.localizedStandardCompare(rhs.title)
        return name == .orderedSame ? lhs.id < rhs.id : name == .orderedAscending
    }

    /// `.orderedAscending` when `lhs` goes first; a missing value goes last.
    private static func compare<T: Comparable>(_ lhs: T?, _ rhs: T?, ascending: Bool) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            let natural: ComparisonResult = lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
            return directed(natural, ascending: ascending)
        case (nil, nil): return .orderedSame
        case (nil, _): return .orderedDescending
        case (_, nil): return .orderedAscending
        }
    }

    private static func directed(_ result: ComparisonResult, ascending: Bool) -> ComparisonResult {
        guard !ascending else { return result }
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }

    // MARK: Words

    private static let nouns: [(kind: Item.Kind, one: String, many: String)] = [
        (.worktree, "worktree", "worktrees"),
        (.branch, "branch", "branches"),
        (.process, "process", "processes"),
        (.lsreg, "LaunchServices entry", "LaunchServices entries")
    ]

    private static func countParts(_ items: [Item]) -> [String] {
        nouns.compactMap { noun in
            let number = items.filter { $0.kind == noun.kind }.count
            return number == 0 ? nil : count(number, noun.one, noun.many)
        }
    }

    private static func count(_ number: Int, _ one: String, _ many: String) -> String {
        "\(number) \(number == 1 ? one : many)"
    }

    /// The ticked worktrees' size: "~25 GB", "~12 GB, some sizes unknown",
    /// "size unknown"; nil when no worktree is ticked.
    private static func sizePart(_ chosen: [Entry]) -> String? {
        let worktrees = chosen.filter { $0.row.kind == .worktree }
        guard !worktrees.isEmpty else { return nil }
        let total = worktrees.reduce(Int64(0)) { $0 + ($1.row.bytes ?? 0) }
        let unknown = worktrees.contains { $0.row.bytes == nil }
        switch (unknown, total) {
        case (true, 0): return "size unknown"
        case (true, _): return "~\(Presentation.byteText(total)), some sizes unknown"
        default: return "~\(Presentation.byteText(total))"
        }
    }

    /// A reason in this screen's words: the shared phrase, but a moved tip
    /// reads "changed since the check".
    static func words(_ reason: SessionCleanupReason?) -> String {
        guard let reason else { return "kept" }
        if reason == .known(.moved) { return "changed since the check" }
        let text = Presentation.reasonText(reason)
        return text.isEmpty ? "kept" : text
    }

    private static func summaryGroup(_ entry: Entry) -> String {
        if case .failed = entry.row.state { return "failed" }
        switch entry.keptReason {
        case .known(.sessionRecent): return "recent session"
        case .known(.processRunning), .known(.sessionInIt), .known(.youAreInIt): return "in use"
        default: return words(entry.keptReason)
        }
    }

    private static func summaryPhrase(_ group: String, count: Int) -> String {
        group == "recent session" && count != 1 ? "recent sessions" : group
    }

    /// Counts per key, most first, ties in first-seen order.
    private static func grouped(_ keys: [String]) -> [(key: String, count: Int)] {
        var groups: [(key: String, count: Int)] = []
        var index: [String: Int] = [:]
        for key in keys {
            if let at = index[key] {
                groups[at].count += 1
            } else {
                index[key] = groups.count
                groups.append((key, 1))
            }
        }
        return groups.enumerated()
            .sorted { ($0.element.count, -$0.offset) > ($1.element.count, -$1.offset) }
            .map(\.element)
    }

    // MARK: Building rows

    private struct BuildContext {
        var checking: Set<String>
        var sizing: Set<String>
        var removing: Set<String>
        var now: Date

        private static let applyTimeReasons: Set<SessionCleanupReason.Code> = [
            .moved, .gitRefused, .notInPlan, .notAttempted, .worktreeKept, .bundleExists
        ]

        private static func sendable(_ item: Item) -> Bool { item.isPendingRemoval && item.kind.isKnown }

        func entry(_ lead: Item, branch: Item?, bundles: [Item]) -> Entry {
            let state = state(lead)
            let canChoose = (state == .merged || state == .pushed) && Self.sendable(lead)
            let sentBranch = branch.flatMap { Self.sendable($0) ? $0 : nil }
            let keys = [lead.key] + (sentBranch.map { [$0.key] } ?? []) + bundles.filter(Self.sendable).map(\.key)
            let lastCommitAt = lead.lastCommitAt ?? branch?.lastCommitAt
            let row = CleanupRow(
                id: lead.key,
                kind: lead.kind,
                title: title(lead),
                subtitle: subtitle(lead),
                ownerText: ownerText(lead),
                hasOwner: ownerText(lead) != Self.noOwner,
                origin: lead.origin,
                sizeText: sizeText(lead),
                sizePending: lead.kind == .worktree && (checking.contains(lead.key) || sizing.contains(lead.key)),
                bytes: lead.kind == .worktree && lead.bytesKnown && !checking.contains(lead.key)
                    && !sizing.contains(lead.key) ? lead.bytes : nil,
                lastCommitAt: lastCommitAt,
                lastCommitText: lastCommitAt.map { CleanupScreenModel.lastCommitText($0, now: now) } ?? "—",
                merged: lead.merged,
                state: state,
                branchNote: branchNote(lead, branch),
                canChoose: canChoose,
                applyKeys: canChoose ? keys : []
            )
            let counted = canChoose ? [lead] + (sentBranch.map { [$0] } ?? []) : []
            return Entry(row: row, counted: counted, keptReason: lead.reason)
        }

        private func state(_ item: Item) -> CleanupRowState {
            if removing.contains(item.key) { return .removing }
            if checking.contains(item.key) { return .checking }
            if !item.error.isEmpty { return .failed(item.error) }
            guard item.kind.isKnown else { return .kept("Unknown item") }
            switch item.action {
            case .remove:
                return item.merged ? .merged : .pushed
            case .keep:
                let chip = Self.capitalized(CleanupScreenModel.words(item.reason))
                if case let .known(code)? = item.reason, Self.applyTimeReasons.contains(code) {
                    return .changedSinceCheck(chip)
                }
                return .kept(chip)
            case .unknown:
                return .kept("Unknown item")
            }
        }

        private static func capitalized(_ text: String) -> String {
            text.prefix(1).uppercased() + text.dropFirst()
        }

        private func title(_ item: Item) -> String {
            switch item.kind {
            case .worktree: (item.name as NSString).lastPathComponent
            case .lsreg: "LaunchServices entry"
            default: item.name.isEmpty ? item.key : item.name
            }
        }

        private func subtitle(_ item: Item) -> String {
            switch item.kind {
            case .worktree: item.branch
            case .branch: "branch only"
            case .lsreg: item.name
            case .process: "process"
            case .unknown: ""
            }
        }

        static let noOwner = "—"

        private func ownerText(_ item: Item) -> String {
            guard item.kind == .worktree else { return Self.noOwner }
            if let owner = item.owner, !owner.isUnknown, let id = owner.sessionID {
                guard !owner.title.isEmpty else { return "Session \(id)" }
                let name = "“\(owner.title)”"
                guard let at = TimeFormatting.parseISO(owner.lastActive) else { return name }
                return name + " · active " + CleanupScreenModel.ageText(at, now: now)
            }
            switch item.origin {
            case .subagent: return "Subagent"
            case .placed: return "Session deleted"
            case .manual: return "Made by hand"
            case .session, .none: return Self.noOwner
            }
        }

        private func sizeText(_ item: Item) -> String {
            guard item.kind == .worktree else { return "—" }
            if checking.contains(item.key) { return "checking" }
            if sizing.contains(item.key) { return "measuring" }
            return SessionCleanupPresentation.sizeText(bytes: item.bytes, known: item.bytesKnown)
        }

        private func branchNote(_ lead: Item, _ branch: Item?) -> String? {
            guard lead.action == .remove, let branch, !branch.isPendingRemoval else { return nil }
            let why = branch.reason == .known(.checkedOut) ? "checked out elsewhere" : CleanupScreenModel.words(branch.reason)
            return "branch kept — \(why)"
        }
    }
}
