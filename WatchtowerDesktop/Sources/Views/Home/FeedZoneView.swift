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
    let onExpand: (Bool) -> Void
    /// The clock row stamps are labelled against.
    var now = Date()
    /// The builder's calendar: its zone formats every time, so rows and
    /// events agree with the NOW label and the chips.
    var calendar: Calendar = .current

    /// The sources of the rows above NOW, in the order their failure lines show.
    private static let waitingSources: [FeedSource] = [.inbox, .proposals, .reminders, .targets]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            waitingPart
            FeedNowLine(label: feed.nowLabel)
                .padding(.vertical, 6)
            laterPart
            if let day = feed.nextDay {
                Divider().padding(.top, 8)
                Text(day.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                ForEach(day.events) { event in
                    FeedEventRow(event: event, muted: true, calendar: calendar, onLink: onLink)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(HomeCardBackground())
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(Self.title(count: feed.waiting.count + feed.hiddenWaiting))
                .font(.caption.weight(.bold))
                .kerning(0.6)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Catch-Up →") { onLink(.catchUp) }
                .buttonStyle(.link)
                .font(.callout)
        }
        .padding(.bottom, 4)
    }

    /// "WAITING ON YOU · N", no count at zero.
    static func title(count: Int) -> String {
        count > 0 ? "WAITING ON YOU · \(count)" : "WAITING ON YOU"
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
        if feed.hiddenWaiting > 0 {
            moreButton("\(feed.hiddenWaiting) more") { onExpand(true) }
        } else if feed.waiting.count > HomeFeedBuilder.waitingLimit {
            moreButton("Show less") { onExpand(false) }
        }
    }

    private func moreButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.link)
            .font(.callout)
            .padding(.leading, FeedRowMetrics.textInset)
            .padding(.top, 2)
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
    static let spacing: CGFloat = 10
    /// Where a row's text starts: past the time column.
    static let textInset: CGFloat = time + spacing
}

/// One row above NOW: time · chip · who / where over the text, with Open /
/// Done / Hide on hover. Focusable: Return opens, ⌘Return is Done, Delete is
/// Hide — Done and Hide only when the row offers them.
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
            FeedChip(text: row.chip, tint: Self.tint(row))
                .frame(width: FeedRowMetrics.chip, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                whoLine
                Text(row.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(row.read ? .tertiary : .secondary)
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering || focused ? Color.primary.opacity(0.05) : .clear))
        .padding(.horizontal, -8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
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
    }

    private var whoLine: some View {
        HStack(spacing: 4) {
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
        HStack(spacing: 4) {
            Button("Open") { onLink(row.link) }
            if row.actions.contains(.done) {
                Button("Done") { _ = act(.done) }
            }
            if row.actions.contains(.hide) {
                Button("Hide") { _ = act(.hide) }
            }
        }
        .controlSize(.small)
        .opacity(hovering || focused ? 1 : 0)
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

    static func tint(_ row: FeedRow) -> Color {
        switch row.kind {
        case .slack: .purple
        case .jira: .blue
        case .proposal: .yellow
        case .reminder: .secondary
        case .target: .red
        case .email: .teal
        }
    }
}

/// One row below NOW: time · chip · title, "Prep ready" when the meeting has
/// a prep. The next one is bold; one in progress sits on the NOW line.
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
                    .foregroundStyle(.secondary)
                    .frame(width: FeedRowMetrics.time, alignment: .leading)
                FeedChip(text: event.chip, tint: Self.tint(event))
                    .frame(width: FeedRowMetrics.chip, alignment: .leading)
                HStack(spacing: 4) {
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
                    Text("Prep ready")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.green.opacity(0.45)))
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, event.isOngoing ? 8 : 0)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(event.isOngoing ? Color.orange.opacity(0.1) : .clear))
            .padding(.horizontal, event.isOngoing ? -8 : 0)
            .contentShape(Rectangle())
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

    private static func tint(_ event: FeedEvent) -> Color {
        switch event.id {
        case .event: .green
        case .target: .red
        default: .secondary
        }
    }
}

/// Formats a feed time in the given calendar's zone — never a formatter
/// without one, which would follow the process zone instead of the builder's.
private enum FeedTime {
    static func string(_ date: Date, _ pattern: String, _ calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

/// The NOW line: the current time and a 1.5 pt orange rule with a dot.
struct FeedNowLine: View {
    let label: String

    var body: some View {
        HStack(spacing: FeedRowMetrics.spacing) {
            Text(label)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.orange)
                .frame(width: FeedRowMetrics.time, alignment: .leading)
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.orange)
                    .frame(height: 1.5)
                Circle()
                    .fill(.orange)
                    .frame(width: 8, height: 8)
                    .offset(x: -4)
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Now, \(label)")
    }
}

/// A kind chip: the text on a tinted capsule.
private struct FeedChip: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(tint.opacity(0.16)))
    }
}

/// The feed's one-line states: the all-clear, "Nothing else today." or a
/// failed source.
private struct FeedStatusLine: View {
    enum Icon { case ok, failed }

    let text: String
    let icon: Icon?

    var body: some View {
        HStack(spacing: 8) {
            switch icon {
            case .ok:
                Image(systemName: "checkmark").foregroundStyle(.green).accessibilityHidden(true)
            case .failed:
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityHidden(true)
            case nil:
                EmptyView()
            }
            Text(text)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, FeedRowMetrics.textInset)
        .padding(.vertical, 6)
    }
}
