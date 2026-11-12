import Foundation

/// A section of a folder's list (spec "The list"): what waits on the owner,
/// what came today, the automations that keep running, and the rest.
package enum InboxRootSection: String, CaseIterable, Sendable {
    case needsYou, today, running, earlier

    package var title: String {
        switch self {
        case .needsYou: "Needs you"
        case .today: "Today"
        case .running: "Running"
        case .earlier: "Earlier"
        }
    }
}

/// The root's line under its sections: past briefs live inside the
/// Morning brief now, one row (spec "One brief row").
package struct InboxEarlierLine: Equatable, Sendable {
    /// Past days with a brief or a plan in the last 30 days, today left out.
    package let pastThisMonth: Int
    /// Those whose briefing was never opened.
    package let notOpened: Int

    package init(pastThisMonth: Int, notOpened: Int) {
        self.pastThisMonth = pastThisMonth
        self.notOpened = notOpened
    }

    /// "Past briefs are inside Morning brief · 5 this month, 2 not opened".
    package var text: String { "\(title) · \(counts)" }

    /// The line's first part, drawn on its own line in the list.
    package var title: String { "Past briefs are inside Morning brief" }

    /// "5 this month, 2 not opened" (", N not opened" only when N > 0).
    package var counts: String {
        let head = "\(pastThisMonth) this month"
        return notOpened > 0 ? "\(head), \(notOpened) not opened" : head
    }
}

/// Splits a folder's entries (`InboxFolderEntries.build`) into the list's
/// sections. Pure.
package enum InboxRootSections {
    /// How long a thread brief stays in Needs you (ask #609).
    package static let briefWindow: TimeInterval = 24 * 3600

    /// `folder`'s sections in order; a section with no entries is left out.
    /// - Root: **Needs you** — Waiting for me's artifact, the Messages
    ///   stand-in, Mail waiting's artifact, the thread briefs applied in the last 24 hours (newest
    ///   first; an older one is dropped), then, on a tree without Needs
    ///   approval, the approvals and notices. **Today** — the Morning
    ///   brief, then the artifacts changed today (`InboxToday`), newest
    ///   first. **Running** — Track my threads, Idea finder, then the other
    ///   artifacts, newest first. Earlier is never a root section (the
    ///   Earlier line stands for it).
    /// - An owner folder: **Today** (changed today) and **Earlier**, each
    ///   in the incoming order.
    /// - Needs approval: none (its groups are its own).
    package static func build(
        entries: [InboxFolderEntry],
        folder: InboxFolderKind,
        waitingForMeAutomationID: Int64?,
        mailWaitingAutomationID: Int64? = nil,
        now: Date,
        calendar: Calendar
    ) -> [(InboxRootSection, [InboxFolderEntry])] {
        func isToday(_ date: Date) -> Bool {
            InboxToday.isFromToday(createdAt: date, mentionedAt: nil, now: now, calendar: calendar)
        }
        switch folder {
        case .approvals:
            return []
        case .owner:
            func changedToday(_ entry: InboxFolderEntry) -> Bool {
                if case let .artifact(card) = entry { return isToday(card.changedAt) }
                return false
            }
            return listed([(.today, entries.filter(changedToday)), (.earlier, entries.filter { !changedToday($0) })])
        case .root:
            var waiting: [InboxFolderEntry] = []
            var standIn: [InboxFolderEntry] = []
            var mail: [InboxFolderEntry] = []
            var briefs: [(at: Date, entry: InboxFolderEntry)] = []
            var approvals: [InboxFolderEntry] = []
            var day: [InboxFolderEntry] = []
            var today: [(at: Date, entry: InboxFolderEntry)] = []
            var tracks: [InboxFolderEntry] = []
            var ideas: [InboxFolderEntry] = []
            var running: [(at: Date, entry: InboxFolderEntry)] = []
            for entry in entries {
                switch entry {
                case let .artifact(card):
                    if waitingForMeAutomationID == card.automationID {
                        waiting.append(entry)
                    } else if mailWaitingAutomationID == card.automationID {
                        mail.append(entry)
                    } else if isToday(card.changedAt) {
                        today.append((card.changedAt, entry))
                    } else {
                        running.append((card.changedAt, entry))
                    }
                case .legacyMessages:
                    standIn.append(entry)
                case let .brief(action):
                    // Re-checked here: Needs you never grows with old briefs.
                    if let at = AutomationDates.parse(action.appliedAt), now.timeIntervalSince(at) <= briefWindow {
                        briefs.append((at, entry))
                    }
                case .approval, .builtinNotice:
                    approvals.append(entry)
                case .legacyDay:
                    day.append(entry)
                case .legacyTracks:
                    tracks.append(entry)
                case .legacyIdeas:
                    ideas.append(entry)
                }
            }
            return listed([
                (.needsYou, waiting + standIn + mail + newestFirst(briefs) + approvals),
                (.today, day + newestFirst(today)),
                (.running, tracks + ideas + newestFirst(running))
            ])
        }
    }

    /// The root's Earlier line from the read's day cards, or nil when no
    /// past day of the Morning brief's History (`InboxBriefDays.history`:
    /// the last 30 dates, today included) has a brief or a plan. `today`
    /// is the "yyyy-MM-dd" of `now`.
    package static func earlierLine(
        days: [InboxDayCard],
        today: String,
        now: Date,
        calendar: Calendar
    ) -> InboxEarlierLine? {
        let past = InboxBriefDays.history(days, today: today, now: now, calendar: calendar)
            .filter { $0.date < today }
        guard !past.isEmpty else { return nil }
        return InboxEarlierLine(pastThisMonth: past.count, notOpened: past.filter(\.isUnread).count)
    }

    private static func newestFirst(_ timed: [(at: Date, entry: InboxFolderEntry)]) -> [InboxFolderEntry] {
        timed.enumerated()
            .sorted { $0.element.at != $1.element.at ? $0.element.at > $1.element.at : $0.offset < $1.offset }
            .map(\.element.entry)
    }

    private static func listed(
        _ sections: [(InboxRootSection, [InboxFolderEntry])]
    ) -> [(InboxRootSection, [InboxFolderEntry])] {
        sections.filter { !$0.1.isEmpty }
    }
}
