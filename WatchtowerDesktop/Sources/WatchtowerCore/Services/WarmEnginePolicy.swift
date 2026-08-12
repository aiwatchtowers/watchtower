import Foundation
import WatchtowerCore

/// What the warm-engine policy needs to know about the calendar: whether a
/// non-all-day meeting is ongoing right now, and when the next one starts
/// (nil = none inside the lookahead the provider was asked for). Produced by
/// the injectable `meetingsProvider` closure `MeetingRecorderCenter` polls,
/// so tests script the calendar without a database.
package struct WarmMeetingWindow: Equatable {
    package var hasOngoingMeeting: Bool
    package var nextStart: Date?

    package init(hasOngoingMeeting: Bool, nextStart: Date?) {
        self.hasOngoingMeeting = hasOngoingMeeting
        self.nextStart = nextStart
    }

    /// The degenerate window — also what the default provider stub and a
    /// failed DB read resolve to, so the policy simply sees "no meetings".
    package static let noMeetings = Self(hasOngoingMeeting: false, nextStart: nil)
}

/// Pure decision logic for the warm transcription-engine slot — given the
/// Center's engine state + the meeting window + now, whether to pre-load the
/// engine, unload the parked one, or do nothing. No clock reads, no I/O (the
/// `MeetingReminderLogic` precedent): `MeetingRecorderCenter`'s poll loop
/// feeds it and owns all side effects, so these functions are directly
/// unit-testable.
package enum WarmEnginePolicy {
    /// How far ahead of a meeting's start the engine is pre-loaded, and how
    /// long a parked engine is held for an upcoming meeting.
    package static let prewarmLead: TimeInterval = 5 * 60

    package enum Decision: Equatable {
        /// Load the engine now so Record starts instantly.
        case prewarm
        /// Drop the parked engine — nothing holds or expects it.
        case unload
        case none
    }

    /// One poll tick's verdict. Semantics (the design contract):
    /// - `.prewarm` — engine free, warm slot empty, no prewarm in flight,
    ///   toggle ON, and (a meeting is ongoing OR one starts in ≤ `prewarmLead`);
    /// - `.unload` — warm present but NOTHING holds it: no capture, no job, no
    ///   ongoing meeting, no meeting starting in ≤ `prewarmLead` (or toggle
    ///   OFF, or key mismatch);
    /// - engine busy → never prewarm, never unload the busy engine (the warm
    ///   slot is empty while busy anyway; the guard is defensive).
    package static func decide(
        toggleEnabled: Bool,
        engineBusy: Bool,
        warmPresent: Bool,
        prewarmInFlight: Bool,
        keyMatches: Bool,
        window: WarmMeetingWindow,
        now: Date
    ) -> Decision {
        guard !engineBusy else { return .none }
        let soon = meetingSoon(window: window, now: now)
        if warmPresent {
            // A stale key (Settings changed provider/model) or a switched-off
            // toggle releases the engine even mid-meeting: what is parked is
            // no longer what a recording would use.
            return (toggleEnabled && keyMatches && soon) ? .none : .unload
        }
        if toggleEnabled, !prewarmInFlight, soon {
            return .prewarm
        }
        return .none
    }

    /// Whether a meeting justifies holding (or loading) a warm engine: one is
    /// ongoing, or the next one starts within `prewarmLead`. A `nextStart` in
    /// the past does not count — "already started" is the ongoing flag's job,
    /// so a stale provider value cannot pin the engine forever.
    package static func meetingSoon(window: WarmMeetingWindow, now: Date) -> Bool {
        if window.hasOngoingMeeting { return true }
        guard let next = window.nextStart else { return false }
        let untilStart = next.timeIntervalSince(now)
        return untilStart > 0 && untilStart <= prewarmLead
    }

    /// Folds fetched events into the policy's meeting window. All-day events
    /// never hold an engine; ongoing = startDate ≤ now < endDate; next = the
    /// earliest start inside (now, now + `prewarmLead`].
    package static func window(events: [CalendarEvent], now: Date) -> WarmMeetingWindow {
        let timed = events.filter { !$0.isAllDay }
        let ongoing = timed.contains { $0.startDate <= now && now < $0.endDate }
        let next = timed
            .map(\.startDate)
            .filter { $0 > now && $0.timeIntervalSince(now) <= prewarmLead }
            .min()
        return WarmMeetingWindow(hasOngoingMeeting: ongoing, nextStart: next)
    }
}
