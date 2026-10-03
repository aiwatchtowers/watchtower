import Foundation

/// One row of the ⌘K palette: a session (with its workbench, for the
/// `<workbench> › <session>` label) or a workbench.
package enum GoToItem: Identifiable, Equatable, Sendable {
    case session(TerminalSession, workbench: Workbench)
    case workbench(WorkbenchSwitcherSummary)

    package var id: String {
        switch self {
        case let .session(session, _): "session-\(session.id)"
        case let .workbench(row): "workbench-\(row.id)"
        }
    }

    fileprivate var workbenchID: Int64 {
        switch self {
        case let .session(_, workbench): workbench.id
        case let .workbench(row): row.id
        }
    }

    fileprivate var title: String {
        switch self {
        case let .session(session, _): session.title
        case let .workbench(row): row.project.name
        }
    }

    fileprivate var lastActiveAt: String {
        switch self {
        case let .session(session, _): session.lastActiveAt
        case let .workbench(row): row.lastSessionActivity
        }
    }
}

/// A palette section; the order of sections is fixed, ranking is within one.
package struct GoToSection: Identifiable, Equatable, Sendable {
    package enum Kind: Equatable, Sendable {
        /// "SESSIONS · <current workbench>".
        case currentSessions
        /// "OTHER WORKBENCHES": workbench rows and their sessions.
        case otherWorkbenches
    }

    package let kind: Kind
    package let items: [GoToItem]

    package var id: Kind { kind }
}

/// The ⌘K palette's search (board #252). Pure: the sessions come from
/// `TerminalSessionQueries.fetchAllWorkbenchSessions`, the workbenches from
/// `WorkbenchQueries.switcherSummaries`, the current workbench's panel order
/// from the view model.
package enum GoToRanking {
    package static let exact = 100
    package static let prefix = 80
    package static let wordStart = 60
    package static let substring = 40
    package static let subsequence = 20
    package static let currentBonus = 10
    /// A non-empty query lists at most this many items, sections together.
    package static let limit = 50
    /// An empty query lists this many of each other workbench's sessions.
    package static let sessionsPerWorkbench = 2

    /// The current workbench and its sessions in the panel's order.
    package struct Current: Equatable, Sendable {
        package let workbenchID: Int64
        package let orderedSessions: [TerminalSession]

        package init(workbenchID: Int64, orderedSessions: [TerminalSession]) {
            self.workbenchID = workbenchID
            self.orderedSessions = orderedSessions
        }
    }

    /// `current` nil (a standalone terminal, the empty state) → no first
    /// section. Empty sections are left out.
    package static func results(
        query: String,
        current: Current?,
        sessions: [TerminalSession],
        workbenches: [WorkbenchSwitcherSummary]
    ) -> [GoToSection] {
        let byID = Dictionary(workbenches.map { ($0.id, $0.project) }) { first, _ in first }
        let currentItems: [GoToItem] = current.map { current in
            guard let workbench = byID[current.workbenchID] else { return [] }
            return current.orderedSessions.map { .session($0, workbench: workbench) }
        } ?? []
        let others = WorkbenchSwitcherPresentation.ordered(workbenches.filter { $0.id != current?.workbenchID })
        let sessionsByWorkbench = Dictionary(grouping: sessions.filter { $0.projectID != current?.workbenchID }) {
            $0.projectID ?? 0
        }.mapValues { $0.sorted(by: isMoreRecent) }

        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            let otherItems = others.flatMap { row -> [GoToItem] in
                let recent = (sessionsByWorkbench[row.id] ?? []).prefix(sessionsPerWorkbench)
                return [.workbench(row)] + recent.map { .session($0, workbench: row.project) }
            }
            return sections(current: currentItems, other: otherItems)
        }

        let otherItems = others.flatMap { row -> [GoToItem] in
            [.workbench(row)] + (sessionsByWorkbench[row.id] ?? []).map { .session($0, workbench: row.project) }
        }
        let currentRanked = ranked(currentItems, query: needle, currentID: current?.workbenchID)
        let otherRanked = ranked(otherItems, query: needle, currentID: current?.workbenchID)
        let currentCapped = Array(currentRanked.prefix(limit))
        let otherCapped = Array(otherRanked.prefix(limit - currentCapped.count))
        return sections(current: currentCapped, other: otherCapped)
    }

    /// The item's best field score, plus the current-workbench bonus; 0 when
    /// no field matches. While the sections split by workbench — the current
    /// one's sessions apart from every other workbench's items — the bonus
    /// never changes an order: it is kept because the ranking pins it.
    package static func score(_ item: GoToItem, query: String, currentID: Int64?) -> Int {
        let best: Int = switch item {
        case let .session(session, workbench):
            [
                fieldScore(session.title, query: query),
                targetScore(session.targetID, query: query),
                fieldScore(workbench.name, query: query)
            ].max() ?? 0
        case let .workbench(row):
            fieldScore(row.project.name, query: query)
        }
        guard best > 0 else { return 0 }
        return best + (item.workbenchID == currentID ? currentBonus : 0)
    }

    /// Exact > prefix > word start > substring > subsequence (every query
    /// character in order), case- and diacritic-insensitive; 0 = no match.
    package static func fieldScore(_ field: String, query: String) -> Int {
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

    /// `#163` or `163` naming the target exactly scores as exact; anything
    /// else is scored against the `#163` text like any field.
    private static func targetScore(_ targetID: Int64?, query: String) -> Int {
        guard let targetID else { return 0 }
        let digits = query.hasPrefix("#") ? String(query.dropFirst()) : query
        if digits == String(targetID) { return exact }
        return fieldScore("#\(targetID)", query: query)
    }

    private static func ranked(_ items: [GoToItem], query: String, currentID: Int64?) -> [GoToItem] {
        items
            .map { (item: $0, score: score($0, query: query, currentID: currentID)) }
            .filter { $0.score > 0 }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.item.lastActiveAt != rhs.item.lastActiveAt { return lhs.item.lastActiveAt > rhs.item.lastActiveAt }
                let order = lhs.item.title.localizedCaseInsensitiveCompare(rhs.item.title)
                return order == .orderedSame ? lhs.item.id < rhs.item.id : order == .orderedAscending
            }
            .map(\.item)
    }

    private static func sections(current: [GoToItem], other: [GoToItem]) -> [GoToSection] {
        [GoToSection(kind: .currentSessions, items: current), GoToSection(kind: .otherWorkbenches, items: other)]
            .filter { !$0.items.isEmpty }
    }

    private static func isMoreRecent(_ lhs: TerminalSession, _ rhs: TerminalSession) -> Bool {
        lhs.lastActiveAt == rhs.lastActiveAt ? lhs.id > rhs.id : lhs.lastActiveAt > rhs.lastActiveAt
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
