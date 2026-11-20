import SwiftUI
import WatchtowerSync

/// How old the replica the screen draws is (#1873, spec 2026-11-16-phone-stale-data-line-design):
/// nothing while the tower's data flows, else one line under the tower chip on Now and the
/// Workbench tab, e.g. "Updated 15:20 · Acme Mac is not sending updates".
struct ReplicaFreshness: Equatable {
    enum State: Equatable {
        /// `stuck_since` 10 min old or more: one kind does not reach the phone.
        case stuck
        /// The heartbeat is `RelayFeed.heartbeatStaleAfter` old or more: nothing does.
        case stale
        /// Relay has not answered this iPhone for `RelayBannerModel.unavailableAfter` (60 s, as the Relay banner):
        /// it cannot know what the tower sends.
        case offline
    }

    /// A kind stuck this long shows: a record refused once and taken on the retry does not flash
    /// the line.
    static let stuckAfter: TimeInterval = 10 * 60
    static let tone = PhoneTone.red
    static let glyph = "exclamationmark.arrow.circlepath"

    let state: State
    let text: String
    /// The time the text names: the tower's last publish (stale, offline) or when the kind got stuck.
    let at: Date

    /// When the tower stopped sending, or nil while one kind is stuck alone (#2112 C4): what ages the live line
    /// and the agents sheet.
    var staleSince: Date? { state == .stuck ? nil : at }

    /// nil while fresh, unlinked, or before the first heartbeat (the screen's own empty or loading
    /// state stands). Offline wins over stale, stale over stuck. `relayUnansweredSince` is
    /// `HubSession.relayUnansweredSince`; `showsOffline` is false on Now, whose Relay banner says it.
    init?(
        heartbeat: HeartbeatPayload?,
        linked: Bool,
        relayUnansweredSince: Date?,
        showsOffline: Bool = true,
        now: Date,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) {
        guard linked, let heartbeat else { return nil }
        let name = TowerText.name(heartbeat.macName)
        let published = heartbeat.lastPublishAt ?? heartbeat.updatedAt
        let state: State
        let at: Date
        let unanswered = relayUnansweredSince.map { now.timeIntervalSince($0) >= RelayBannerModel.unavailableAfter } ?? false
        if unanswered, !showsOffline {
            return nil
        } else if unanswered {
            (state, at) = (.offline, published)
        } else if !MacStatus.isOnline(lastHeartbeat: heartbeat.updatedAt, now: now) {
            (state, at) = (.stale, published)
        } else if let stuck = heartbeat.stuckSince, now.timeIntervalSince(stuck) >= Self.stuckAfter {
            (state, at) = (.stuck, stuck)
        } else {
            return nil
        }
        self.state = state
        self.at = at
        let updated = "Updated \(Self.clock(at, now: now, calendar: calendar, locale: locale))"
        text = switch state {
        case .stuck: "\(updated) · \(name) is not sending some updates"
        case .stale: "\(updated) · \(name) is not sending updates"
        case .offline: "\(updated) · this iPhone can't reach Relay"
        }
    }

    var toneUse: ToneUse {
        ToneUse(element: "replica freshness line", tone: Self.tone, role: .status)
    }

    /// "15:20" today, "yesterday 15:20", "14 Nov, 15:20" earlier, in the calendar's time zone and
    /// the locale's clock.
    static func clock(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let time = date.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday \(time)"
        }
        let day = date.formatted(
            Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone).month(.abbreviated).day())
        return "\(day), \(time)"
    }
}

/// What `ReplicaFreshness` reads, kept so a view's own clock re-judges the tower each tick without a redraw from
/// its parent (the workchat's live line, the agents sheet).
struct TowerFreshness: Equatable {
    var heartbeat: HeartbeatPayload?
    var linked = false
    var relayUnansweredSince: Date?

    func freshness(at now: Date) -> ReplicaFreshness? {
        ReplicaFreshness(heartbeat: heartbeat, linked: linked, relayUnansweredSince: relayUnansweredSince, now: now)
    }

    func staleSince(at now: Date) -> Date? { freshness(at: now)?.staleSince }
}

/// The line itself: the glyph and the text in the model's tone, `.caption`. Empty while fresh.
///
/// `inset` is its side padding; nothing is drawn (no padding, no stack spacing) while fresh.
///
///     ReplicaFreshnessLine(now: context.date)
struct ReplicaFreshnessLine: View {
    @Environment(AppEnvironment.self) private var env
    let now: Date
    var inset: CGFloat = 0
    var showsOffline = true

    var body: some View {
        if let model = ReplicaFreshness(
            heartbeat: env.workbenchReplica.snapshot.heartbeat, linked: env.linkedDevice != nil,
            relayUnansweredSince: env.activeSession.relayUnansweredSince, showsOffline: showsOffline, now: now
        ) {
            ReplicaFreshnessText(model: model)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, inset)
        }
    }
}

/// The line's drawing, apart so the screenshot tour can draw a given state.
struct ReplicaFreshnessText: View {
    let model: ReplicaFreshness

    var body: some View {
        Label {
            Text(model.text)
        } icon: {
            Image(systemName: ReplicaFreshness.glyph)
        }
        .font(TypeScale.meta)
        .foregroundStyle(ReplicaFreshness.tone.color)
        .padding(.vertical, Spacing.small)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.text)
    }
}
