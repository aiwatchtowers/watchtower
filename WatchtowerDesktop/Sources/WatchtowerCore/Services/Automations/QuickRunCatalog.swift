import Foundation

/// One recipe as the "Run Automation…" palette (⌃⌘R) and the tray's "Run
/// automation ▸" list it (spec §12.7).
package struct QuickRunRow: Identifiable, Equatable, Sendable {
    package enum Group: Equatable, Hashable, Sendable {
        case workbench(id: Int64, name: String)
        case personal
    }

    package enum Kind: Equatable, Sendable {
        /// Manual and button recipes, the subject of quick run.
        case manual, button
        /// Listed after them in the group as "(run now)".
        case scheduledOrEvent
    }

    package enum State: Equatable, Sendable {
        /// `Automation.isRunnable` (Go `Runnable()`), with no run active.
        case runnable
        case running(runID: Int64)
        case needsConfirmation, disabled, parseError
    }

    /// The automation id.
    package let id: Int64
    package let name: String
    package let group: Group
    package let kind: Kind
    /// A button recipe with `confirm: true`: it runs only after **Run** in its sheet.
    package let asksFirst: Bool
    package let state: State
    package let lastRun: AutomationRun?
    /// The recipe description's first paragraph, for the "Run “<name>”?" sheet.
    package let descriptionLead: String

    package init(
        id: Int64,
        name: String,
        group: Group,
        kind: Kind,
        asksFirst: Bool,
        state: State,
        lastRun: AutomationRun?,
        descriptionLead: String = ""
    ) {
        self.id = id
        self.name = name
        self.group = group
        self.kind = kind
        self.asksFirst = asksFirst
        self.state = state
        self.lastRun = lastRun
        self.descriptionLead = descriptionLead
    }

    /// Why a dimmed row does not run; nil for a runnable or running row.
    package var reason: String? {
        switch state {
        case .needsConfirmation: "needs your confirmation first"
        case .disabled: "disabled"
        case .parseError: "can't be read"
        case .runnable, .running: nil
        }
    }

    package var hint: String {
        if kind == .scheduledOrEvent { return "(run now)" }
        return asksFirst ? "asks before it runs" : "only when you run it"
    }

    /// "last run 2 days ago, succeeded"; nil before the first run.
    package func lastRunText(now: Date) -> String? {
        guard let run = lastRun else { return nil }
        let status = AutomationCardPresentation.statusText(run.status).lowercased()
        guard let at = run.finishedAt ?? run.startedAt ?? run.queuedAt else { return "last run \(status)" }
        return "last run \(Self.age(of: at, now: now)), \(status)"
    }

    private static let ageFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.unitsStyle = .full
        f.dateTimeStyle = .numeric
        return f
    }()

    private static func age(of date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        return ageFormatter.localizedString(for: date, relativeTo: now)
    }
}

/// The quick-run rows and their fuzzy ranking. The scoring levels are the
/// Go to… palette's (`GoToRanking`), written out here so that palette stays
/// untouched (owner ruling 2026-10-15, spec §12.7).
package enum QuickRunCatalog {
    package static let exact = 100
    package static let prefix = 80
    package static let wordStart = 60
    package static let substring = 40
    package static let subsequence = 20
    /// A non-empty query lists at most this many rows.
    package static let limit = 50

    /// Removed recipes are left out; workbench groups by name, then
    /// Personal; inside a group manual and button recipes first, then
    /// scheduled and event ones, each by name.
    package static func rows(_ items: [AutomationListItem], workbenchNames: [Int64: String]) -> [QuickRunRow] {
        items
            .filter { $0.automation.removedAt == nil }
            .map { row($0, workbenchNames: workbenchNames) }
            .sorted(by: isOrderedBefore)
    }

    /// An empty query keeps `rows`' order; otherwise rows matching by name,
    /// best score first, ties in `rows`' (group) order, at most `limit`.
    package static func ranked(_ rows: [QuickRunRow], query: String) -> [QuickRunRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return rows }
        var scored: [(index: Int, score: Int)] = []
        for (index, row) in rows.enumerated() {
            let value = score(row.name, query: needle)
            if value > 0 { scored.append((index, value)) }
        }
        scored.sort { lhs, rhs in lhs.score == rhs.score ? lhs.index < rhs.index : lhs.score > rhs.score }
        return scored.prefix(limit).map { rows[$0.index] }
    }

    /// Exact > prefix > word start > substring > subsequence (every query
    /// character in order), case- and diacritic-insensitive; 0 = no match.
    package static func score(_ field: String, query: String) -> Int {
        let text = fold(field)
        let needle = fold(query)
        guard !needle.isEmpty, !text.isEmpty else { return 0 }
        if text == needle { return exact }
        if text.hasPrefix(needle) { return prefix }
        var found = false
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: needle, range: searchRange) {
            found = true
            let before = text[text.index(before: range.lowerBound)]
            if !before.isLetter && !before.isNumber { return wordStart }
            searchRange = text.index(after: range.lowerBound)..<text.endIndex
        }
        if found { return substring }
        return isSubsequence(needle, of: text) ? subsequence : 0
    }

    // MARK: - Rows

    private static func row(_ item: AutomationListItem, workbenchNames: [Int64: String]) -> QuickRunRow {
        let a = item.automation
        let trigger = RecipeFrontmatter.trigger(kind: a.triggerKind, specJSON: a.triggerSpecJSON)
        let kind: QuickRunRow.Kind
        var asksFirst = false
        switch a.triggerKind {
        case "schedule", "event":
            kind = .scheduledOrEvent
        case "button":
            kind = .button
            if case let .button(_, confirm) = trigger { asksFirst = confirm }
        default:
            kind = .manual
        }
        let group: QuickRunRow.Group = if a.scope == .workbench, let projectID = a.projectID {
            .workbench(id: projectID, name: workbenchNames[projectID] ?? "Workbench #\(projectID)")
        } else {
            .personal
        }
        return QuickRunRow(
            id: a.id,
            name: a.name.isEmpty ? a.slug : a.name,
            group: group,
            kind: kind,
            asksFirst: asksFirst,
            state: state(item),
            lastRun: item.lastRun,
            descriptionLead: descriptionLead(a.recipeText)
        )
    }

    /// A parse error first (nothing else is known); an active run opens the
    /// run; then runnable exactly when `isRunnable`; a confirmed but
    /// switched-off recipe is disabled; anything else waits for confirmation.
    private static func state(_ item: AutomationListItem) -> QuickRunRow.State {
        let a = item.automation
        if !a.parseError.isEmpty { return .parseError }
        if let active = item.activeRun { return .running(runID: active.id) }
        if a.isRunnable { return .runnable }
        let confirmed = !a.confirmedHash.isEmpty && a.confirmedHash == a.approvalHash
        return confirmed && !a.enabled ? .disabled : .needsConfirmation
    }

    private static func isOrderedBefore(_ lhs: QuickRunRow, _ rhs: QuickRunRow) -> Bool {
        let lg = groupKey(lhs.group), rg = groupKey(rhs.group)
        if lg != rg { return lg < rg }
        let lk = lhs.kind == .scheduledOrEvent ? 1 : 0, rk = rhs.kind == .scheduledOrEvent ? 1 : 0
        if lk != rk { return lk < rk }
        let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
    }

    /// Workbench groups by folded name (then id), Personal last.
    private static func groupKey(_ group: QuickRunRow.Group) -> GroupKey {
        switch group {
        case let .workbench(id, name): GroupKey(personal: false, name: fold(name), id: id)
        case .personal: GroupKey(personal: true, name: "", id: 0)
        }
    }

    private struct GroupKey: Comparable {
        let personal: Bool
        let name: String
        let id: Int64

        static func < (lhs: Self, rhs: Self) -> Bool {
            if lhs.personal != rhs.personal { return !lhs.personal }
            return lhs.name == rhs.name ? lhs.id < rhs.id : lhs.name < rhs.name
        }
    }

    /// The description's first paragraph: the recipe body after the
    /// frontmatter up to the first blank line or fence, headings skipped.
    package static func descriptionLead(_ recipeText: String) -> String {
        let body = RecipeFrontmatter.block(in: recipeText).map { String(recipeText[$0.endIndex...]) } ?? recipeText
        var paragraph: [String] = []
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("```") || text.hasPrefix("~~~") { break }
            if text.isEmpty || text.hasPrefix("#") {
                if paragraph.isEmpty { continue }
                break
            }
            paragraph.append(text)
        }
        return paragraph.joined(separator: " ")
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func isSubsequence(_ needle: String, of text: String) -> Bool {
        var rest = needle[...]
        for char in text where char == rest.first {
            rest = rest.dropFirst()
            if rest.isEmpty { return true }
        }
        return rest.isEmpty
    }
}
