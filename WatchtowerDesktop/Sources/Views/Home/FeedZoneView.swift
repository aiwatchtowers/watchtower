import SwiftUI
import WatchtowerCore

/// Home's feed zone: what waits on the owner above the NOW line, the rest of
/// today below it, then the next day with meetings. A source whose read
/// failed says so in its part and never reads as the all-clear.
struct FeedZoneView: View {
    let feed: HomeFeed
    /// A Done / Hide that failed, by row.
    let errors: [FeedRef: String]
    let onLink: (HomeLink) -> Void
    /// Runs in an unstructured task: a view going away must not cancel the write.
    let onAct: (FeedAction, FeedRef) async -> Void
    /// true: the next page of rows above NOW; false: back to the first seven.
    let onPage: (Bool) -> Void
    /// The clock row stamps are labelled against.
    var now = Date()
    /// The builder's calendar: its zone formats every time, so rows and
    /// events agree with the NOW label and the chips.
    var calendar: Calendar = .current

    /// The sources of the rows above NOW, in the order their failure lines show.
    private static let waitingSources: [FeedSource] = [.inbox, .proposals, .automations, .reminders, .targets]

    /// The header's count; nothing waiting shows none.
    static func countDetail(_ count: Int) -> String? {
        count > 0 ? "\(count)" : nil
    }

    var body: some View {
        HomeZone(title: "Waiting on you", detail: Self.countDetail(feed.waiting.count + feed.hiddenWaiting)) {
            Button("Catch-Up →") { onLink(.catchUp) }
        } content: {
            waitingPart
            FeedNowLine(label: feed.nowLabel)
                .padding(.vertical, Spacing.compact)
            laterPart
            if let day = feed.nextDay {
                // Space, not a divider, sets the next day apart.
                Text(day.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .homeZoneInset()
                    .padding(.top, Spacing.medium)
                    .padding(.bottom, Spacing.tight)
                ForEach(day.events) { event in
                    FeedEventRow(event: event, muted: true, calendar: calendar, onLink: onLink)
                }
            }
        }
    }

    @ViewBuilder private var waitingPart: some View {
        ForEach(Self.waitingSources.filter(feed.failed.contains), id: \.self) { source in
            FeedStatusLine(text: Self.failureLine(source), icon: .failed)
        }
        if feed.waiting.isEmpty {
            if Self.waitingSources.allSatisfy({ !feed.failed.contains($0) }) {
                FeedStatusLine(text: "Nothing is waiting for you.", icon: .ok)
            }
        } else {
            ForEach(feed.waiting) { row in
                FeedRowView(row: row, error: errors[row.id], now: now, calendar: calendar, onLink: onLink, onAct: onAct)
            }
        }
        let expanded = feed.waiting.count > HomeFeedBuilder.waitingLimit
        if feed.hiddenWaiting > 0 || expanded {
            moreButtons {
                if feed.hiddenWaiting > 0 {
                    Button(Self.moreTitle(feed, expanded: expanded)) { onPage(true) }
                }
                if expanded {
                    Button("Show less") { onPage(false) }
                }
            }
        }
    }

    /// "N more" collapsed, "Show N more" once expanded: N is what the next
    /// page really adds, never every row left.
    static func moreTitle(_ feed: HomeFeed, expanded: Bool) -> String {
        let count = HomeFeedBuilder.nextPageCount(feed)
        return expanded ? "Show \(count) more" : "\(count) more"
    }

    private func moreButtons(@ViewBuilder _ buttons: () -> some View) -> some View {
        HStack(spacing: Spacing.small) {
            buttons()
        }
        .buttonStyle(.kitQuiet)
        .controlSize(.small)
        .padding(.leading, FeedRowMetrics.textInset - Spacing.regular)
    }

    @ViewBuilder private var laterPart: some View {
        if let ongoing = feed.ongoing {
            FeedEventRow(event: ongoing, muted: false, calendar: calendar, onLink: onLink)
        }
        if feed.failed.contains(.calendar) {
            FeedStatusLine(text: Self.failureLine(.calendar), icon: .failed)
        }
        if feed.laterToday.isEmpty {
            // A failed source of later items is never "nothing else".
            if feed.failed.isDisjoint(with: [.calendar, .reminders, .targets]) {
                FeedStatusLine(text: "Nothing else today.", icon: nil)
            }
        } else {
            ForEach(feed.laterToday) { event in
                FeedEventRow(event: event, muted: false, calendar: calendar, onLink: onLink)
            }
        }
    }

    /// "Couldn't read <source> — see the log."
    static func failureLine(_ source: FeedSource) -> String {
        let name = switch source {
        case .inbox: "Slack and mail"
        case .reminders: "reminders"
        case .proposals: "proposals"
        case .automations: "automation notes"
        case .targets: "targets"
        case .calendar: "the calendar"
        }
        return "Couldn't read \(name) — see the log."
    }
}

/// The feed's column widths, shared by rows, events and the lines under them.
private enum FeedRowMetrics {
    static let time: CGFloat = 44
    static let chip: CGFloat = 72
    static let spacing = Spacing.cozy
    /// Where a row's text starts: past the row plate's inset and the time column.
    static let textInset: CGFloat = Spacing.regular + time + spacing
}

/// One row above NOW: time · chip · who / where over the text, on a kit row
/// with Open / Done / Hide on hover. Focusable: Return opens, ⌘Return is
/// Done, Delete is Hide — Done and Hide only when the row offers them. The
/// hover buttons are hidden from accessibility while invisible; the row
/// offers Open, and Done / Hide when it has them, as named accessibility
/// actions instead.
struct FeedRowView: View {
    let row: FeedRow
    let error: String?
    let now: Date
    let calendar: Calendar
    let onLink: (HomeLink) -> Void
    let onAct: (FeedAction, FeedRef) async -> Void
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: FeedRowMetrics.spacing) {
            Text(Self.stampLabel(row.stamp, now: now, calendar: calendar))
                .font(.caption.monospacedDigit())
                .foregroundStyle(row.read ? .tertiary : .secondary)
                .frame(width: FeedRowMetrics.time, alignment: .leading)
            Chip(text: row.chip, color: Tone.feedKind(row.kind))
                .lineLimit(1)
                .frame(width: FeedRowMetrics.chip, alignment: .leading)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                whoLine
                Text(row.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(row.read ? .tertiary : .secondary)
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Tone.error)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .onHover { hovering = $0 }
        .kitRow(isSelected: focused)
        .onTapGesture { onLink(row.link) }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.return, phases: .down) { press in
            if press.modifiers.contains(.command) {
                return act(.done) ? .handled : .ignored
            }
            onLink(row.link)
            return .handled
        }
        .onKeyPress(.delete) { act(.hide) ? .handled : .ignored }
        .accessibilityElement(children: .contain)
        // Only the actions the row offers, so VoiceOver never lists one that
        // would do nothing.
        .accessibilityActions {
            Button("Open") { onLink(row.link) }
            if row.actions.contains(.done) {
                Button("Done") { _ = act(.done) }
            }
            if row.actions.contains(.hide) {
                Button("Hide") { _ = act(.hide) }
            }
        }
    }

    private var whoLine: some View {
        HStack(spacing: Spacing.small) {
            Text(row.who)
                .fontWeight(row.read ? .regular : .semibold)
                .foregroundStyle(row.read ? .tertiary : .primary)
            if let whereText = row.whereText {
                Text("· \(whereText)")
                    .foregroundStyle(.tertiary)
            }
        }
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private var actions: some View {
        HStack(spacing: Spacing.small) {
            hoverButton("Open") { onLink(row.link) }
            if row.actions.contains(.done) {
                hoverButton("Done") { _ = act(.done) }
            }
            if row.actions.contains(.hide) {
                hoverButton("Hide") { _ = act(.hide) }
            }
        }
        .buttonStyle(.kitQuiet)
        .controlSize(.small)
    }

    /// The hover buttons show under the pointer or with focus.
    private var showsActions: Bool { hovering || focused }

    /// A hover button: invisible, and hidden from accessibility, until the
    /// row is hovered or focused.
    private func hoverButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .opacity(showsActions ? 1 : 0)
            .accessibilityHidden(!showsActions)
    }

    /// Done / Hide when the row offers it, in an unstructured task so the
    /// write outlives the row (which leaves the feed at once). False when the
    /// row does not offer it.
    private func act(_ action: FeedAction) -> Bool {
        guard row.actions.contains(action) else { return false }
        let ref = row.id
        Task { await onAct(action, ref) }
        return true
    }

    /// "HH:mm" today, the weekday within the last week, else "Oct 16".
    static func stampLabel(_ stamp: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(stamp, inSameDayAs: now) {
            return FeedTime.string(stamp, "HH:mm", calendar)
        }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)),
           stamp >= weekAgo, stamp <= now {
            return FeedTime.string(stamp, "EEE", calendar)
        }
        return FeedTime.string(stamp, "MMM d", calendar)
    }
}

/// One row below NOW: time · chip · title on a kit row, "Prep ready" when the
/// meeting has a prep. The next one is bold; one in progress sits on the NOW
/// line on a soft `Tone.now` tint.
struct FeedEventRow: View {
    let event: FeedEvent
    /// The next day's rows: secondary, never bold.
    let muted: Bool
    let calendar: Calendar
    let onLink: (HomeLink) -> Void

    var body: some View {
        Button { onLink(event.link) } label: {
            HStack(alignment: .center, spacing: FeedRowMetrics.spacing) {
                Text(event.isOngoing ? "now" : FeedTime.string(event.start, "HH:mm", calendar))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(event.isOngoing ? AnyShapeStyle(Tone.now) : AnyShapeStyle(.secondary))
                    .frame(width: FeedRowMetrics.time, alignment: .leading)
                Chip(text: event.chip, color: event.isOngoing ? Tone.now : Tone.feedEvent(event.id))
                    .lineLimit(1)
                    .frame(width: FeedRowMetrics.chip, alignment: .leading)
                HStack(spacing: Spacing.small) {
                    Text(event.title)
                        .fontWeight(event.isNext && !muted ? .semibold : .regular)
                        .foregroundStyle(muted ? .secondary : .primary)
                    if let duration = Self.duration(event) {
                        Text("· \(duration)")
                            .foregroundStyle(.tertiary)
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                if event.prepReady {
                    Chip(text: "Prep ready", color: Tone.success)
                }
            }
            .kitRow(isSelected: false)
            .background(
                event.isOngoing ? Tone.now.opacity(ChipTint.fillOpacity) : .clear,
                in: RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// "30 min", "1 h", "1 h 30 min" for a meeting; nil for a point in time.
    static func duration(_ event: FeedEvent) -> String? {
        guard case .event = event.id, !event.isOngoing else { return nil }
        let minutes = Int(event.end.timeIntervalSince(event.start) / 60)
        guard minutes > 0 else { return nil }
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}

/// Formats a feed time in the given calendar's zone — never a formatter
/// without one, which would follow the process zone instead of the builder's.
/// Every row formats on every layout pass, so the formatters are made once
/// per pattern and calendar (the calendar carries the zone) and reused;
/// views only, hence main-actor.
@MainActor
enum FeedTime {
    private struct Key: Hashable {
        let pattern: String
        let calendar: Calendar
    }

    /// A few patterns times the builder's calendar; the bound only guards a
    /// caller cycling calendars.
    private static let cacheLimit = 32
    private static var formatters: [Key: DateFormatter] = [:]

    static func string(_ date: Date, _ pattern: String, _ calendar: Calendar) -> String {
        formatter(pattern, calendar).string(from: date)
    }

    static func formatter(_ pattern: String, _ calendar: Calendar) -> DateFormatter {
        let key = Key(pattern: pattern, calendar: calendar)
        if let cached = formatters[key] { return cached }
        if formatters.count >= cacheLimit { formatters.removeAll() }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        formatters[key] = formatter
        return formatter
    }
}

/// The NOW line: the current time and a `Stroke.selection` rule with a dot,
/// in `Tone.now`.
struct FeedNowLine: View {
    let label: String

    var body: some View {
        HStack(spacing: FeedRowMetrics.spacing) {
            Text(label)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(Tone.now)
                .frame(width: FeedRowMetrics.time, alignment: .leading)
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Tone.now)
                    .frame(height: Stroke.selection)
                Circle()
                    .fill(Tone.now)
                    .frame(width: Spacing.regular, height: Spacing.regular)
                    .offset(x: -Spacing.small)
            }
            .accessibilityHidden(true)
        }
        .homeZoneInset()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Now, \(label)")
    }
}

/// The feed's one-line states: the all-clear, "Nothing else today." or a
/// failed source.
private struct FeedStatusLine: View {
    enum Icon { case ok, failed }

    let text: String
    let icon: Icon?

    var body: some View {
        HStack(spacing: Spacing.regular) {
            switch icon {
            case .ok:
                Image(systemName: "checkmark").foregroundStyle(Tone.success).accessibilityHidden(true)
            case .failed:
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Tone.warning).accessibilityHidden(true)
            case nil:
                EmptyView()
            }
            Text(text)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, FeedRowMetrics.textInset)
        .padding(.vertical, Spacing.compact)
    }
}
