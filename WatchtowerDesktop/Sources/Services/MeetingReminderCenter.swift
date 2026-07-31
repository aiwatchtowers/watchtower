import Foundation
import GRDB

/// Native-push seam for meeting reminders, so `MeetingReminderCenter` is
/// unit-testable without `UNUserNotificationCenter` (which has no app-bundle
/// context under `swift test` and crashes if invoked there). Same shape as
/// `MeetingTranscriptNotifying`.
protocol MeetingReminderNotifying {
    func sendMeetingReminderNotification(eventID: String, title: String, body: String, conferenceURL: String, dedupKey: String)
    func sendStopRecordingNotification(eventID: String, title: String, dedupKey: String)
}

extension NotificationService: MeetingReminderNotifying {}

/// Pure decision logic for every reminder surface — given events + now +
/// settings, which reminders fire. No clock reads, no I/O: the Center's poll
/// loop feeds it and owns all side effects, so these functions are directly
/// unit-testable.
enum MeetingReminderLogic {
    /// The in-app banner lingers this long past an event's start.
    static let bannerGraceAfterStart: TimeInterval = 5 * 60
    /// Grace after an event's end before the stop-recording push fires.
    static let stopGrace: TimeInterval = 2 * 60
    /// The stop-recording push re-fires each interval while the condition holds.
    static let stopRepeatInterval: TimeInterval = 10 * 60

    /// Dedup key for the pre-meeting push AND the banner dismissal memory.
    /// Includes the raw start time so a rescheduled event re-notifies (and a
    /// dismissed banner reappears) under a fresh key.
    static func preMeetingDedupKey(_ event: CalendarEvent) -> String {
        "pre|\(event.id)|\(event.startTime)"
    }

    /// Events whose pre-meeting push should fire now: start within
    /// (now, now + N min], not all-day, not already started when first
    /// observed, and not yet delivered. `reminderMinutes <= 0` disables.
    static func preMeetingEvents(
        events: [CalendarEvent],
        now: Date,
        reminderMinutes: Int,
        delivered: Set<String>
    ) -> [CalendarEvent] {
        guard reminderMinutes > 0 else { return [] }
        let window = TimeInterval(reminderMinutes) * 60
        return events.filter { event in
            guard !event.isAllDay else { return false }
            let untilStart = event.startDate.timeIntervalSince(now)
            guard untilStart > 0, untilStart <= window else { return false }
            return !delivered.contains(preMeetingDedupKey(event))
        }
    }

    /// The event the countdown banner should show: the earliest-starting
    /// non-all-day event inside [start − N min, start + 5 min) that the user
    /// has not dismissed. Nil hides the banner.
    static func bannerEvent(
        events: [CalendarEvent],
        now: Date,
        reminderMinutes: Int,
        dismissed: Set<String>
    ) -> CalendarEvent? {
        guard reminderMinutes > 0 else { return nil }
        let window = TimeInterval(reminderMinutes) * 60
        return events
            .filter { event in
                guard !event.isAllDay, !dismissed.contains(preMeetingDedupKey(event)) else { return false }
                let untilStart = event.startDate.timeIntervalSince(now)
                return untilStart <= window && untilStart > -bannerGraceAfterStart
            }
            .min { $0.startDate < $1.startDate }
    }

    /// Dedup key for the stop-recording push, or nil while the condition does
    /// not hold (event not yet past end + grace). The key embeds the 10-minute
    /// repeat-window index, so the push re-fires each window while the
    /// recording keeps running past the event's end.
    static func stopRecordingDedupKey(eventID: String, eventEnd: Date, now: Date) -> String? {
        let overdue = now.timeIntervalSince(eventEnd) - stopGrace
        guard overdue > 0 else { return nil }
        let windowIndex = Int(overdue / stopRepeatInterval)
        return "stop|\(eventID)|\(windowIndex)"
    }
}

/// App-wide meeting-reminder service (DigestWatcher pattern): a 30 s poll
/// loop reads upcoming events and drives all reminder surfaces — the
/// pre-meeting push, the stop-recording push, and the in-app countdown
/// banner (`bannerEvent`, rendered by `UpcomingMeetingBannerView`).
///
/// All state is in-memory. Delivered-reminder dedup is keyed by
/// event id + start time, so a rescheduled event re-notifies; an event
/// deleted or moved between poll ticks simply produces no (or one new)
/// reminder — never a crash. Notifications fire while the app is running
/// (no pre-scheduled triggers, no helper process); when notification
/// permission is denied the pushes silently no-op while the banner — which
/// needs no permission — keeps working.
@MainActor
@Observable
final class MeetingReminderCenter {
    /// `@AppStorage("calendar.reminderMinutes")` in NotificationSettings;
    /// absent = 5, 0 disables all reminder surfaces.
    static let reminderMinutesKey = "calendar.reminderMinutes"
    /// `@AppStorage("notifyMeetingReminders")`; absent = true. Gates the
    /// pushes only — the in-app banner stays on while minutes > 0.
    static let remindersEnabledKey = "notifyMeetingReminders"
    static let defaultReminderMinutes = 5

    /// The event the global countdown banner shows, or nil to hide it.
    private(set) var bannerEvent: CalendarEvent?

    private var deliveredPre: Set<String> = []
    private var deliveredStop: Set<String> = []
    private var dismissedBanners: Set<String> = []
    private var pollTask: Task<Void, Never>?

    private let dbPool: DatabasePool
    private let recorderCenter: MeetingRecorderCenter
    private let notifier: MeetingReminderNotifying
    private let defaults: UserDefaults
    /// Injectable clock so tests drive the decision boundaries deterministically.
    private let now: () -> Date

    init(
        dbPool: DatabasePool,
        recorderCenter: MeetingRecorderCenter,
        notifier: MeetingReminderNotifying = NotificationService.shared,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.dbPool = dbPool
        self.recorderCenter = recorderCenter
        self.notifier = notifier
        self.defaults = defaults
        self.now = now
    }

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                self.poll()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Hides the banner for this event (remembered per event + start time, so
    /// it stays hidden until the event is rescheduled).
    func dismissBanner(_ event: CalendarEvent) {
        dismissedBanners.insert(MeetingReminderLogic.preMeetingDedupKey(event))
        if bannerEvent?.id == event.id {
            bannerEvent = nil
        }
    }

    var reminderMinutes: Int {
        defaults.object(forKey: Self.reminderMinutesKey) as? Int ?? Self.defaultReminderMinutes
    }

    /// Pushes respect the "Meeting reminders" toggle (absent = enabled, the
    /// DigestWatcher convention) and the existing quiet-hours setting. The
    /// in-app banner is exempt from both.
    private var pushesEnabled: Bool {
        let enabled = defaults.object(forKey: Self.remindersEnabledKey) == nil
            || defaults.bool(forKey: Self.remindersEnabledKey)
        return enabled && !defaults.bool(forKey: "quietHoursEnabled")
    }

    /// One decision tick — called every 30 s and directly from tests.
    func poll() {
        let now = self.now()
        let minutes = reminderMinutes

        // Candidate events overlapping the near window. fetchEvents matches
        // start_time <= to AND end_time >= from; the extra lookback covers the
        // banner's linger past start. The pure logic filters by start time.
        let horizon = TimeInterval(max(minutes, 1)) * 60
        let events = (try? dbPool.read { db in
            try CalendarQueries.fetchEvents(
                db,
                from: now.addingTimeInterval(-MeetingReminderLogic.bannerGraceAfterStart),
                to: now.addingTimeInterval(horizon)
            )
        }) ?? []

        bannerEvent = MeetingReminderLogic.bannerEvent(
            events: events, now: now, reminderMinutes: minutes, dismissed: dismissedBanners
        )

        guard pushesEnabled else { return }

        for event in MeetingReminderLogic.preMeetingEvents(
            events: events, now: now, reminderMinutes: minutes, delivered: deliveredPre
        ) {
            let key = MeetingReminderLogic.preMeetingDedupKey(event)
            deliveredPre.insert(key)
            let minutesLeft = max(1, Int((event.startDate.timeIntervalSince(now) / 60).rounded(.up)))
            notifier.sendMeetingReminderNotification(
                eventID: event.id,
                title: event.title,
                body: "Starts in \(minutesLeft) min · \(event.formattedTimeRange)",
                conferenceURL: event.conferenceLink?.absoluteString ?? "",
                dedupKey: key
            )
        }

        pollStopReminder(now: now)
    }

    /// Stop-recording push: only for an event-linked recording still running
    /// past its event's end + grace. Ad-hoc recordings (no event) are exempt.
    private func pollStopReminder(now: Date) {
        guard case .recording = recorderCenter.phase,
              let eventID = recorderCenter.currentEventID else { return }
        guard let event = try? dbPool.read({ db in
            try CalendarQueries.fetchEvent(db, id: eventID)
        }) else { return }
        guard let key = MeetingReminderLogic.stopRecordingDedupKey(
            eventID: eventID, eventEnd: event.endDate, now: now
        ), !deliveredStop.contains(key) else { return }
        deliveredStop.insert(key)
        notifier.sendStopRecordingNotification(eventID: eventID, title: event.title, dedupKey: key)
    }
}
