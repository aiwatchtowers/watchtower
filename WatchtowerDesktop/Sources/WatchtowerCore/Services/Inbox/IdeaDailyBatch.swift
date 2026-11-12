import Foundation

/// What the Idea finder row and pane show about today's batch: the ideas of the
/// batch still awaiting a verdict, today's kept ideas and the counts around them.
package struct IdeaBatchState: Equatable, Sendable {
    /// The current batch in hand-out order, as stored (ids of deleted ideas included).
    package var batchIDs: [Int]
    /// Batch ideas still awaiting a verdict, in batch order.
    package var remaining: [Idea]
    /// Ideas kept (`active`, of a kind that awaits a verdict) since local
    /// midnight, newest first — the whole day, across every Next.
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
package struct IdeaDailyBatch {
    package static let sizeKey = "ideas.dailyBatch"
    package static let dateKey = "ideas.batch.date"
    package static let idsKey = "ideas.batch.ids"
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

    package static func state(ideas: [Idea], batchIDs: [Int], now: Date, size: Int, calendar: Calendar) -> IdeaBatchState {
        let byID = Dictionary(ideas.map { ($0.id, $0) }) { first, _ in first }
        let remaining = batchIDs.compactMap { byID[$0] }.filter(\.awaitsVerdict)
        let remainingIDs = Set(remaining.map(\.id))
        let awaiting = ideas.filter(\.awaitsVerdict)
        let midnight = InboxToday.startOfToday(now: now, calendar: calendar)
        let kept = ideas
            .compactMap { idea -> (Idea, Date)? in
                guard idea.status == .active, idea.kind != .decision || idea.chatBorn,
                      let updated = AutomationDates.parse(idea.updatedAt), updated >= midnight else { return nil }
                return (idea, updated)
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.id > $1.0.id }
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
            return Self.state(ideas: ideas, batchIDs: stored, now: now, size: size, calendar: calendar)
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
        defaults.set(day, forKey: Self.dateKey)
        defaults.set(ids, forKey: Self.idsKey)
        return Self.state(ideas: ideas, batchIDs: ids, now: now, size: size, calendar: calendar)
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
}
