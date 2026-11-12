import Foundation

/// What the Idea finder row and pane show about today's batch: the ideas of the
/// batch still awaiting a verdict, today's kept ideas and the counts around them.
package struct IdeaBatchState: Equatable, Sendable {
    /// The current batch in hand-out order, as stored (ids of deleted ideas included).
    package var batchIDs: [Int]
    /// Batch ideas still awaiting a verdict, in batch order.
    package var remaining: [Idea]
    /// Ideas handed out today, across every Next, that are now `active`,
    /// newest `updated_at` first (`updated_at` alone is no verdict time: a
    /// new mention bumps it).
    package var keptToday: [Idea]
    /// Ideas awaiting a verdict that are not in `remaining` (old ones included).
    package var backlogCount: Int
    /// Ideas awaiting a verdict created more than 30 days ago.
    package var olderCount: Int
    /// How many ideas a Next would hand out now: min(size, candidates).
    package var nextAvailable: Int
    package var size: Int

    /// Batch ids no longer awaiting a verdict (a deleted idea counts as judged).
    package var judgedCount: Int { batchIDs.count - remaining.count }

    package var pillCount: Int? { remaining.isEmpty ? nil : remaining.count }

    package var isUnread: Bool { !remaining.isEmpty }

    package var rowPreview: String {
        if let top = remaining.first {
            let noun = remaining.count == 1 ? "idea" : "ideas"
            return "Today’s \(remaining.count) \(noun) to judge. Top one: “\(top.title)”."
        }
        if !batchIDs.isEmpty {
            return "Today’s batch done · \(backlogCount) in the backlog"
        }
        return "Nothing to judge from the last 30 days"
    }

    /// The backlog and older parts joined " · "; once the batch is done the
    /// backlog is in the preview, so only the older part remains.
    package var rowMeta: String {
        let batchDone = remaining.isEmpty && !batchIDs.isEmpty
        var parts: [String] = []
        if !batchDone, backlogCount > 0 { parts.append("\(backlogCount) in the backlog") }
        if olderCount > 0 { parts.append("\(olderCount) older than 30 days") }
        return parts.joined(separator: " · ")
    }

    package var paneSubtitle: String {
        "Today’s batch · \(judgedCount) of \(batchIDs.count) judged · \(backlogCount) more in the backlog"
    }

    package var nextTitle: String { "Next \(size)" }
}

/// The Idea finder's daily batch: ideas awaiting a verdict from the last 30
/// days, oldest first, `size` per local day. The batch is fixed per day in
/// UserDefaults (`ideas.batch.date` + `ideas.batch.ids`); Next replaces it.
/// Every id handed out today is kept in `ideas.batch.dayIDs` (reset with the
/// date): Kept today is drawn from them.
package struct IdeaDailyBatch {
    package static let sizeKey = "ideas.dailyBatch"
    package static let dateKey = "ideas.batch.date"
    package static let idsKey = "ideas.batch.ids"
    package static let dayIDsKey = "ideas.batch.dayIDs"
    package static let defaultSize = 13
    package static let windowDays = 30

    private let defaults: UserDefaults

    package init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// `ideas.dailyBatch`; a missing, non-integer or < 1 value is 13.
    package var size: Int {
        guard let value = defaults.object(forKey: Self.sizeKey) as? Int, value >= 1 else { return Self.defaultSize }
        return value
    }

    // MARK: - Selection

    private static func cutoff(now: Date) -> Date {
        now.addingTimeInterval(-Double(windowDays) * 24 * 3600)
    }

    /// Ideas awaiting a verdict created within the last 30 × 24 h, oldest
    /// `created_at` first, then id. An unparseable `created_at` is left out.
    package static func candidates(_ ideas: [Idea], now: Date) -> [Idea] {
        let cutoff = cutoff(now: now)
        return ideas
            .compactMap { idea -> (Idea, Date)? in
                guard idea.awaitsVerdict, let created = AutomationDates.parse(idea.createdAt),
                      created >= cutoff else { return nil }
                return (idea, created)
            }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.id < $1.0.id }
            .map(\.0)
    }

    /// Awaits a verdict and was created more than 30 × 24 h ago. An
    /// unparseable `created_at` is not old.
    package static func isOld(_ idea: Idea, now: Date) -> Bool {
        guard idea.awaitsVerdict, let created = AutomationDates.parse(idea.createdAt) else { return false }
        return created < cutoff(now: now)
    }

    /// The batch's state; `dayIDs` are the ids handed out today (nil: the
    /// batch's own).
    package static func state(
        ideas: [Idea], batchIDs: [Int], dayIDs: [Int]? = nil, now: Date, size: Int, calendar: Calendar
    ) -> IdeaBatchState {
        let byID = Dictionary(ideas.map { ($0.id, $0) }) { first, _ in first }
        let remaining = batchIDs.compactMap { byID[$0] }.filter(\.awaitsVerdict)
        let remainingIDs = Set(remaining.map(\.id))
        let awaiting = ideas.filter(\.awaitsVerdict)
        let handedOut: [Idea] = Set(dayIDs ?? batchIDs).compactMap { byID[$0] }
        let kept: [Idea] = handedOut
            .filter { $0.status == .active }
            .map { idea -> (Idea, Date) in (idea, AutomationDates.parse(idea.updatedAt) ?? .distantPast) }
            .sorted { lhs, rhs in lhs.1 != rhs.1 ? lhs.1 > rhs.1 : lhs.0.id > rhs.0.id }
            .map(\.0)
        return IdeaBatchState(
            batchIDs: batchIDs,
            remaining: remaining,
            keptToday: kept,
            backlogCount: awaiting.filter { !remainingIDs.contains($0.id) }.count,
            olderCount: awaiting.filter { isOld($0, now: now) }.count,
            nextAvailable: min(size, candidates(ideas, now: now).count),
            size: size
        )
    }

    // MARK: - Store

    /// Reads today's batch; stores a new one (the first `size` candidates) when
    /// the stored date is not today's local date or the stored ids are
    /// missing, not `[Int]` or empty.
    package func today(ideas: [Idea], now: Date, calendar: Calendar) -> IdeaBatchState {
        let size = size
        let day = Self.localDay(now, calendar: calendar)
        if defaults.string(forKey: Self.dateKey) == day,
           let stored = defaults.array(forKey: Self.idsKey) as? [Int], !stored.isEmpty {
            return Self.state(ideas: ideas, batchIDs: stored, dayIDs: dayIDs(day: day, batchIDs: stored),
                              now: now, size: size, calendar: calendar)
        }
        return pick(ideas: ideas, now: now, size: size, day: day, calendar: calendar)
    }

    /// Replaces the stored batch with the first `size` candidates now (unjudged
    /// leftovers come first again by age) and keeps today's date.
    package func next(ideas: [Idea], now: Date, calendar: Calendar) -> IdeaBatchState {
        pick(ideas: ideas, now: now, size: size, day: Self.localDay(now, calendar: calendar), calendar: calendar)
    }

    private func pick(ideas: [Idea], now: Date, size: Int, day: String, calendar: Calendar) -> IdeaBatchState {
        let ids = Self.candidates(ideas, now: now).prefix(size).map(\.id)
        let earlier = dayIDs(day: day, batchIDs: defaults.array(forKey: Self.idsKey) as? [Int] ?? [])
        let handedOut = earlier + ids.filter { !earlier.contains($0) }
        defaults.set(day, forKey: Self.dateKey)
        defaults.set(ids, forKey: Self.idsKey)
        defaults.set(handedOut, forKey: Self.dayIDsKey)
        return Self.state(ideas: ideas, batchIDs: ids, dayIDs: handedOut, now: now, size: size, calendar: calendar)
    }

    /// The ids handed out on `day` so far: none when the stored date is
    /// another day; the stored list, or `batchIDs` when none was stored (a
    /// batch picked before the list existed).
    private func dayIDs(day: String, batchIDs: [Int]) -> [Int] {
        guard defaults.string(forKey: Self.dateKey) == day else { return [] }
        return defaults.array(forKey: Self.dayIDsKey) as? [Int] ?? batchIDs
    }

    /// Gregorian `yyyy-MM-dd` of `date` in `calendar`'s zone.
    private static func localDay(_ date: Date, calendar: Calendar) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let parts = gregorian.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// The four presses on the Idea finder card, with their keys (either case).
package enum IdeaBatchPress: CaseIterable, Equatable {
    case keep, drop, later, makeTarget

    package init?(key: Character) {
        guard let press = Self.allCases.first(where: { String($0.key) == key.lowercased() }) else { return nil }
        self = press
    }

    package var key: Character {
        switch self {
        case .keep: "k"
        case .drop: "d"
        case .later: "l"
        case .makeTarget: "t"
        }
    }

    package var title: String {
        switch self {
        case .keep: "Keep"
        case .drop: "Drop"
        case .later: "Later"
        case .makeTarget: "Make a Target…"
        }
    }

    /// The key hint's word: "keep", "make a target".
    package var hintLabel: String {
        title.lowercased().replacingOccurrences(of: "…", with: "")
    }
}

/// The Idea finder card's last failed press: its own text, and the press
/// **Try Again** sends again.
package struct IdeaBatchFailure: Equatable {
    package let ideaID: Int
    package let press: IdeaBatchPress
    package let message: String

    package init(ideaID: Int, press: IdeaBatchPress, message: String) {
        self.ideaID = ideaID
        self.press = press
        self.message = message
    }
}
