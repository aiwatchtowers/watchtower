import Foundation
import os

/// What the phone's battery diagnostics count, per local day (board #724):
/// the wakes and the network work that cost energy, so a day of real use
/// gives numbers before and after any cadence change.
public enum EnergyEvent: String, CaseIterable, Sendable {
    /// A silent (`content-available`) push reached the app.
    case silentPush
    /// One `AppEnvironment.refresh()`, by what triggered it: the timed loop,
    /// a silent push, pull to refresh, the return to the foreground, the
    /// boot's first fetch, and the link flow's grant reads.
    case fetchLoop
    case fetchPush
    case fetchPull
    case fetchForeground
    case fetchLaunch
    case fetchLink
    /// A manual CKSyncEngine `fetchChanges` the transport asked for.
    case engineFetch
    /// A fetch the engine ran (its `willFetchChanges` event): the manual
    /// ones plus the engine's own, push-driven ones.
    case engineFetchRun
    /// A forced `recordZoneChanges` poll of DataZone or RelayZone (one per
    /// page).
    case dataZonePoll
    case relayZonePoll
    /// A batch of saves and deletes handed to the engine to send.
    case sendBatch
    /// A cold process launch, straight into the background (a push or
    /// background fetch woke it) or into the foreground.
    case coldLaunchBackground
    case coldLaunchForeground
    /// A recording's audio handed to the transport for upload.
    case uploadAttempt
}

/// One local day's counts.
public struct EnergyDayCounts: Equatable, Sendable {
    /// The day's start in the counter's calendar.
    public let day: Date
    public let counts: [EnergyEvent: Int]

    public init(day: Date, counts: [EnergyEvent: Int]) {
        self.day = day
        self.counts = counts
    }

    public subscript(_ event: EnergyEvent) -> Int {
        counts[event] ?? 0
    }
}

/// Per-day counters of `EnergyEvent`s in `UserDefaults` (the app group's on
/// the phone), one integer key per day and event, so a count survives the
/// process being killed at any point and an increment writes one small key.
/// The last `retainedDays` days are kept; a new day prunes older ones.
///
/// Thread-safe and allocation-light: it runs on every CloudKit request, so
/// an increment takes one lock, compares the clock with the cached day's
/// bounds and updates one key; the calendar is consulted only when the day
/// changes.
public final class EnergyCounter: @unchecked Sendable {
    public static let retainedDays = 14

    private struct Day {
        var start: Date
        var end: Date
        var stamp: String
        var keys: [EnergyEvent: String]
        /// False when the day is older than every retained one (a clock set
        /// back past the window): registering it pruned it at once, so a
        /// count written for it would never be pruned again and leak.
        var retained: Bool
    }

    private let defaults: UserDefaults
    private let prefix: String
    private let calendar: Calendar
    private let now: @Sendable () -> Date
    /// The cached current day; nil until the first use. Guarded by `lock`.
    private let lock = OSAllocatedUnfairLock<Day?>(uncheckedState: nil)

    /// `keyPrefix` namespaces the keys in `defaults`; `calendar` decides
    /// where a local day starts (the device's by default, following a time
    /// zone change).
    public init(
        defaults: UserDefaults,
        keyPrefix: String = "energy",
        calendar: Calendar = .autoupdatingCurrent,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.defaults = defaults
        prefix = keyPrefix
        self.calendar = calendar
        self.now = now
    }

    /// Adds one to today's count of `event`.
    public func record(_ event: EnergyEvent) {
        let date = now()
        lock.withLockUnchecked { cached in
            let day = currentDay(cached, at: date)
            cached = day
            guard day.retained else { return }
            // A day built just now has every key; the subscript cannot miss.
            let name = day.keys[event] ?? key(stamp: day.stamp, event: event)
            defaults.set(defaults.integer(forKey: name) + 1, forKey: name)
        }
    }

    /// The counts of the day `daysAgo` days before today (0: today).
    public func counts(daysAgo: Int) -> EnergyDayCounts {
        let date = now()
        let start = calendar.date(byAdding: .day, value: -daysAgo, to: calendar.startOfDay(for: date)) ?? date
        let stamp = Self.stamp(of: start, in: calendar)
        return lock.withLockUnchecked { _ in
            var counts: [EnergyEvent: Int] = [:]
            for event in EnergyEvent.allCases {
                let value = defaults.integer(forKey: key(stamp: stamp, event: event))
                if value != 0 { counts[event] = value }
            }
            return EnergyDayCounts(day: start, counts: counts)
        }
    }

    // MARK: - Days

    /// The cached day while `date` falls inside it; otherwise the day of
    /// `date`, registered in the retained-days list (which prunes the
    /// oldest). A clock moved backwards lands in its own day the same way;
    /// one moved back past the retained window gets a day that is not
    /// retained, and its counts are dropped.
    private func currentDay(_ cached: Day?, at date: Date) -> Day {
        if let cached, date >= cached.start, date < cached.end { return cached }
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let stamp = Self.stamp(of: start, in: calendar)
        var keys: [EnergyEvent: String] = [:]
        for event in EnergyEvent.allCases {
            keys[event] = key(stamp: stamp, event: event)
        }
        let retained = register(stamp)
        return Day(start: start, end: end, stamp: stamp, keys: keys, retained: retained)
    }

    private var daysKey: String { "\(prefix).days" }

    /// Adds `stamp` to the retained days, pruning the oldest past
    /// `retainedDays`; false when `stamp` itself was the one pruned.
    private func register(_ stamp: String) -> Bool {
        var days = defaults.stringArray(forKey: daysKey) ?? []
        guard !days.contains(stamp) else { return true }
        days.append(stamp)
        // `yyyy-MM-dd` sorts chronologically as text.
        days.sort()
        while days.count > Self.retainedDays {
            let dropped = days.removeFirst()
            for event in EnergyEvent.allCases {
                defaults.removeObject(forKey: key(stamp: dropped, event: event))
            }
        }
        defaults.set(days, forKey: daysKey)
        return days.contains(stamp)
    }

    private func key(stamp: String, event: EnergyEvent) -> String {
        "\(prefix).\(stamp).\(event.rawValue)"
    }

    /// `yyyy-MM-dd` of `date` in `calendar`, without a date formatter.
    private static func stamp(of date: Date, in calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
