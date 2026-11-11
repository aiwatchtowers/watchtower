import Foundation

/// Every string of the closed asks list (#1713 spec, "Model and strings"),
/// pinned by `ClosedAskListCopyTests`.
package enum ClosedAskListCopy {
    package static let title = "Closed asks"
    package static let scopeOutside = "Filed outside the app"
    package static let scopeAutomations = "Automation runs"
    package static let searchPlaceholder = "Search titles, answers, #number"
    package static let loading = "Loading closed asks…"
    package static let empty = "No closed asks here yet."
    package static let emptyHint = "Asks you answer, and asks the agent withdraws, are kept here."
    package static let askGone = "That ask no longer exists. The list was read again."
    package static let retry = "Retry"
    package static let clearSearch = "Clear Search"
    package static let back = "Closed asks"
    package static let backHelp = "Back to the closed asks (Esc)"
    package static let busyHelp = "Refreshing…"
    package static let buttonHelp = "Show the closed asks"
    package static let today = "Today"
    package static let yesterday = "Yesterday"
    package static let unknownDate = "Unknown date"
    package static let approved = "Approved"
    package static let changesRequested = "Changes requested"
    package static let withdrawnByAgent = "withdrawn by the agent"
    package static let replacedByNewer = "replaced by a newer ask"

    /// The session row's and the stack's entry: "▸ 81 closed".
    package static func entryLabel(_ count: Int) -> String { "▸ \(count) closed" }
    package static func scopeSession(_ title: String) -> String { "Session · \(title)" }
    package static func loadFailed(_ reason: String) -> String { "Could not load the closed asks: \(reason)" }
    /// A reload failed with a list on screen; `readAt` is the last good read, "HH:mm".
    package static func refreshFailed(_ reason: String, readAt: String) -> String {
        let reason = reason.hasSuffix(".") ? String(reason.dropLast()) : reason
        return "Could not refresh the list: \(reason). It shows what was read at \(readAt)."
    }
    /// A clicked row's ask could not be read (not the same as gone).
    package static func openFailed(_ reason: String) -> String { "Could not open the ask: \(reason)" }
    package static func noMatch(_ query: String) -> String { "No closed asks match “\(query)”." }
    package static func matches(_ shown: Int, of total: Int) -> String { "\(shown) of \(total)" }
    package static func comments(_ count: Int) -> String { count == 1 ? "1 comment" : "\(count) comments" }
    package static func replacedBy(_ id: Int64) -> String { "replaced by #\(id)" }
}

/// The closed asks list (#1713 spec): day groups, rows, chips, detail lines
/// and search, from the asks `OwnerAskQueries.closedAsks` read.
package enum ClosedAskListModel {
    /// The search field shows from this many asks on.
    package static let searchThreshold = 10

    /// What became of an ask, as a short chip word and its `Tone.status` name.
    package enum Chip: Equatable, Sendable {
        case answered, delivered, withdrawn, replaced, dismissed

        package var text: String {
            switch self {
            case .answered: "Answered"
            case .delivered: "Delivered"
            case .withdrawn: "Withdrawn"
            case .replaced: "Replaced"
            case .dismissed: "Dismissed"
            }
        }

        /// Only an answer the agent has not read yet is blue.
        package var toneName: String {
            switch self {
            case .answered: "blue"
            case .delivered: "green"
            case .withdrawn, .replaced, .dismissed: "gray"
            }
        }
    }

    package struct Row: Identifiable, Equatable, Sendable {
        package let id: Int64
        package let kind: OwnerAskKind
        package let title: String
        package let chip: Chip
        /// "#id · detail", or "#id" alone.
        package let caption: String
        /// The local time filed, "HH:mm"; empty for a date that does not parse.
        package let time: String
    }

    package struct Section: Identifiable, Equatable, Sendable {
        package let title: String
        package let rows: [Row]
        package var id: String { title }
    }

    package static func showsSearch(total: Int) -> Bool { total >= searchThreshold }

    /// What a key does in the list with nothing focused (the drawer's key
    /// catcher, as in the ask drawer): ↑/↓ move, Return opens, Esc clears
    /// the search or closes, ⌘F finds. A held Esc's repeat does nothing.
    package enum KeyAction: Equatable, Sendable {
        case up, down, open, escape, search
    }

    package static func keyAction(for press: OwnerAskKeyMap.Press) -> KeyAction? {
        switch press.key {
        case .upArrow where !press.otherModifiers: .up
        case .downArrow where !press.otherModifiers: .down
        case .returnKey where !press.otherModifiers: .open
        case .escape where !press.otherModifiers && !press.isRepeat: .escape
        case .character("f") where press.otherModifiers: .search
        default: nil
        }
    }

    /// The header's count: "84", or "4 of 84" while searching.
    package static func countText(shown: Int, total: Int, searching: Bool) -> String {
        searching ? ClosedAskListCopy.matches(shown, of: total) : "\(total)"
    }

    package static func isSearching(_ query: String) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    package static func chip(for ask: OwnerAsk) -> Chip {
        if ask.answer?.dismissed == true { return .dismissed }
        switch ask.status {
        case .open, .answered: return .answered
        case .delivered: return .delivered
        case .withdrawn: return ask.withdrawnReason == "superseded" ? .replaced : .withdrawn
        }
    }

    /// The line after "#id · ": an automation's label first, then what
    /// became of the ask or what the owner answered.
    package static func detail(for ask: OwnerAsk, replacedBy: Int64?, automationLabel: String?) -> String {
        let outcome = outcome(of: ask, replacedBy: replacedBy)
        return [automationLabel, outcome].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }

    private static func outcome(of ask: OwnerAsk, replacedBy: Int64?) -> String {
        typealias Copy = ClosedAskListCopy
        switch chip(for: ask) {
        case .replaced: return replacedBy.map(Copy.replacedBy) ?? Copy.replacedByNewer
        case .withdrawn: return Copy.withdrawnByAgent
        case .dismissed: return ask.answer?.note.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        case .answered, .delivered: break
        }
        guard let answer = ask.answer else { return "" }
        switch ask.kind {
        case .review:
            var parts: [String] = []
            switch answer.verdict {
            case .approved: parts.append(Copy.approved)
            case .changes: parts.append(Copy.changesRequested)
            case nil: break
            }
            if !answer.comments.isEmpty { parts.append(Copy.comments(answer.comments.count)) }
            let note = oneLine(answer.note)
            if !note.isEmpty { parts.append("“\(note)”") }
            return parts.joined(separator: " · ")
        case .question:
            let order = ask.payload.questions.map(\.id)
            let sorted = answer.answers.sorted { lhs, rhs in
                (order.firstIndex(of: lhs.id) ?? Int.max) < (order.firstIndex(of: rhs.id) ?? Int.max)
            }
            let picks = sorted.flatMap { $0.labels + [oneLine($0.other)] }.filter { !$0.isEmpty }
            return picks.joined(separator: "; ")
        case .check:
            let marks = Dictionary(answer.checklist.map { ($0.id, $0.state) }) { _, last in last }
            return OwnerAskPresentation.checkSummary(ask.payload.checklist, marks: marks)
        }
    }

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// The list's groups, newest first, filtered by `query` (title, #id,
    /// chip word, detail; case- and diacritic-insensitive). An ask whose
    /// `created_at` does not parse goes to a last "Unknown date" group.
    package static func sections(
        asks: [OwnerAsk],
        replacements: [Int64: Int64],
        labels: [Int64: String],
        query: String,
        now: Date,
        calendar: Calendar
    ) -> [Section] {
        let needle = fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        // One formatter per call for every row and group, not one each.
        let times = formatter("HH:mm", calendar: calendar)
        let days = formatter("EEEE, d MMMM", calendar: calendar)
        let otherYears = formatter("EEEE, d MMMM yyyy", calendar: calendar)
        var dated: [(day: Date, rows: [Row])] = []
        var undated: [Row] = []
        for ask in asks {
            let created = TimeFormatting.parseISO(ask.createdAt)
            let chip = chip(for: ask)
            let detail = detail(for: ask, replacedBy: replacements[ask.id], automationLabel: labels[ask.id])
            let row = Row(
                id: ask.id, kind: ask.kind, title: ask.title, chip: chip,
                caption: detail.isEmpty ? "#\(ask.id)" : "#\(ask.id) · \(detail)",
                time: created.map(times.string(from:)) ?? ""
            )
            if !needle.isEmpty, !fold([row.title, row.caption, chip.text].joined(separator: "\n")).contains(needle) {
                continue
            }
            guard let created else {
                undated.append(row)
                continue
            }
            let day = calendar.startOfDay(for: created)
            if let index = dated.firstIndex(where: { $0.day == day }) {
                dated[index].rows.append(row)
            } else {
                dated.append((day, [row]))
            }
        }
        var out = dated.sorted { $0.day > $1.day }.map {
            Section(title: dayTitle($0.day, now: now, calendar: calendar, days: days, otherYears: otherYears), rows: $0.rows)
        }
        if !undated.isEmpty { out.append(Section(title: ClosedAskListCopy.unknownDate, rows: undated)) }
        return out
    }

    /// "Today", "Yesterday", "Saturday, 7 November", with the year when it is not this one.
    private static func dayTitle(
        _ day: Date,
        now: Date,
        calendar: Calendar,
        days: DateFormatter,
        otherYears: DateFormatter
    ) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return ClosedAskListCopy.today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return ClosedAskListCopy.yesterday
        }
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
        return (sameYear ? days : otherYears).string(from: day)
    }

    private static func formatter(_ format: String, calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
