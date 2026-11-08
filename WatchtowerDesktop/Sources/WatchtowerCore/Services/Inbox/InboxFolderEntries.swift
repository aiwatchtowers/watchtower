import Foundation

/// One entry of a folder (spec "The Inbox screen" 2, "Moving today's Inbox
/// into folders"): an automation's artifact, a legacy entry over today's
/// panes (ask #445: a Morning brief per date, Track my threads, Idea finder,
/// and Messages while it stands in for Waiting for me), an open approval or
/// a built-in upgrade notice (Needs approval).
package enum InboxFolderEntry: Identifiable, Equatable, Sendable {
    case artifact(AutomationOutputCard)
    case legacyDay(InboxDayCard)
    case legacyTracks
    case legacyIdeas
    case legacyMessages
    case approval(NeedsApprovalItem)
    case builtinNotice(BuiltinUpgradeNotice)

    package var id: String {
        switch self {
        case let .artifact(card): "artifact:\(card.id)"
        case let .legacyDay(card): "day:\(card.date)"
        case .legacyTracks: "tracks"
        case .legacyIdeas: "ideas"
        case .legacyMessages: "messages"
        case let .approval(item): "approval:\(item.key)"
        case let .builtinNotice(notice): "notice:\(notice.builtinID)"
        }
    }

    /// A legacy entry whose pane is today's list (Track my threads, Idea
    /// finder, Messages): the filter that list is.
    package var legacyList: InboxFilter? {
        switch self {
        case .legacyTracks: .tracks
        case .legacyIdeas: .ideas
        case .legacyMessages: .messages
        case .artifact, .legacyDay, .approval, .builtinNotice: nil
        }
    }

    /// The id of the legacy entry whose list is `list`.
    package static func legacyID(_ list: InboxFilter) -> String? {
        switch list {
        case .tracks: Self.legacyTracks.id
        case .ideas: Self.legacyIdeas.id
        case .messages: Self.legacyMessages.id
        case .all, .day, .automations: nil
        }
    }

    /// The entry's own ⋯ (and context menu): only the Idea finder has one
    /// here, **Find Ideas in Past Messages…**, moved from the Ideas filter's
    /// menu. An artifact's ⋯ is its automation's (Task 14).
    package var menuEntries: [InboxMenuEntry] {
        self == .legacyIdeas ? InboxArtifactMenuContent.ideaFinderEntries : []
    }
}

/// Composes a folder's entries from the Inbox's one read (the feed and the
/// folder read) and draws their list rows. Pure.
package enum InboxFolderEntries {
    /// What the composition reads besides the folder.
    package struct Inputs {
        package var feed: InboxFeedSnapshot
        package var folders: InboxFolderMenuSnapshot
        /// The `approval-cards` feature is on.
        package var approvalsOn: Bool
        package var dayDone: String?
        package var now: Date
        package var calendar: Calendar

        package init(
            feed: InboxFeedSnapshot,
            folders: InboxFolderMenuSnapshot,
            approvalsOn: Bool = true,
            dayDone: String? = nil,
            now: Date,
            calendar: Calendar = .current
        ) {
            self.feed = feed
            self.folders = folders
            self.approvalsOn = approvalsOn
            self.dayDone = dayDone
            self.now = now
            self.calendar = calendar
        }
    }

    /// `folder`'s entries in list order.
    /// - Needs approval: the built-in upgrade notices, then every open
    ///   approval — native cards above the recipe's cards (spec "mixed").
    /// - The root: Waiting for me pinned first while it has rows that wait
    ///   on the owner; then, newest first, its artifacts and the legacy
    ///   entries by their own time (ask #445); the Messages entry only while
    ///   it stands in for Waiting for me (`WaitingForMeState`). On a tree
    ///   without Needs approval (an older database) the root also holds the
    ///   approvals.
    /// - An owner folder: its artifacts, newest change first.
    /// A legacy entry with nothing to show is left out.
    package static func build(folder: InboxFolder, _ inputs: Inputs) -> [InboxFolderEntry] {
        let read = inputs.folders
        let artifacts = read.cards[folder.id] ?? []
        switch folder.kind {
        case .approvals:
            return approvals(inputs)
        case .owner:
            return artifacts.map(InboxFolderEntry.artifact)
        case .root:
            var pinned: [InboxFolderEntry] = []
            var timed: [(at: Date, entry: InboxFolderEntry)] = []
            for card in artifacts {
                if isWaitingForMe(card, read), waitingCount(card, read) > 0 {
                    pinned.append(.artifact(card))
                } else {
                    timed.append((card.changedAt, .artifact(card)))
                }
            }
            timed += legacy(inputs)
            timed.sort { $0.at > $1.at }
            let rest = read.tree.approvals == nil ? approvals(inputs) : []
            return pinned + timed.map(\.entry) + rest
        }
    }

    /// Needs approval's entries: notices first, then the native cards, then
    /// the recipe's cards. Only approvals open in this read are drawn: the
    /// strip's actions that wait on the owner (`openActions`; the strip also
    /// carries approved, running and recently decided rows) and its due
    /// reminders.
    private static func approvals(_ inputs: Inputs) -> [InboxFolderEntry] {
        let state = inputs.folders.needsApproval
        let open = inputs.feed.proposals.filter { inputs.folders.openActions.contains($0.id) }
        let items = NeedsApprovalSelection.items(
            proposals: open, reminders: inputs.feed.reminders,
            artifacts: inputs.folders.approvalArtifacts,
            recipeOn: inputs.approvalsOn && !state.stopped, lastRunFailed: state.lastRunFailed)
        let native = items.filter { $0.recipe == nil }
        let recipe = items.filter { $0.recipe != nil }
        return inputs.feed.builtinNotices.map(InboxFolderEntry.builtinNotice)
            + (native + recipe).map(InboxFolderEntry.approval)
    }

    /// The root's legacy entries with their own times.
    private static func legacy(_ inputs: Inputs) -> [(at: Date, entry: InboxFolderEntry)] {
        let feed = inputs.feed
        var out: [(at: Date, entry: InboxFolderEntry)] = days(inputs).map { ($0.stamp, .legacyDay($0)) }
        if let at = feed.tracks.map(\.lastEventAt).max() {
            out.append((at, .legacyTracks))
        }
        if !feed.ideas.isEmpty {
            out.append((ideasUpdatedAt(feed) ?? .distantPast, .legacyIdeas))
        }
        if inputs.folders.waitingForMe.messagesStandIn, let at = feed.messages.map(\.stamp).max() {
            out.append((at, .legacyMessages))
        }
        return out
    }

    /// The day cards the All list showed (today's, the unread ones, and
    /// today's placeholder while the owner is known), one entry per date.
    private static func days(_ inputs: Inputs) -> [InboxDayCard] {
        let today = HomeFeedBuilder.dayString(inputs.now, calendar: inputs.calendar)
        let sections = InboxListBuilder.sections(
            inputs.feed, filter: .all, dayDone: inputs.dayDone, today: today, now: inputs.now,
            calendar: inputs.calendar, placeholdsToday: true)
        return sections.flatMap(\.items).compactMap { item in
            if case let .day(card) = item { return card }
            return nil
        }
    }

    private static func ideasUpdatedAt(_ feed: InboxFeedSnapshot) -> Date? {
        feed.ideas.compactMap { AutomationDates.parse($0.updatedAt) }.max()
    }

    private static func isWaitingForMe(_ card: AutomationOutputCard, _ read: InboxFolderMenuSnapshot) -> Bool {
        read.waitingForMe.automationID == card.automationID
    }

    /// The rows of `card` that wait on the owner (the render-time check).
    private static func waitingCount(_ card: AutomationOutputCard, _ read: InboxFolderMenuSnapshot) -> Int {
        (read.refs[card.id] ?? []).filter(read.refState.waits).count
    }

    // MARK: - The list rows

    /// `entry`'s row in the folder list, with the entry's own ⋯.
    package static func row(_ entry: InboxFolderEntry, _ inputs: Inputs) -> InboxFolderListRow {
        var row = plainRow(entry, inputs)
        row.menu = entry.menuEntries
        return row
    }

    private static func plainRow(_ entry: InboxFolderEntry, _ inputs: Inputs) -> InboxFolderListRow {
        let feed = inputs.feed
        let now = inputs.now
        switch entry {
        case let .artifact(card):
            let refs = inputs.folders.refs[card.id] ?? []
            let waiting = waitingCount(card, inputs.folders)
            return InboxFolderListRow(
                id: entry.id, kind: .artifact, title: card.title.isEmpty ? card.automationName : card.title,
                summary: waiting > 0 ? "\(waiting) waiting" : "",
                detail: card.isLiving ? updated(card.writtenAt, now: now)
                                      : "run #\(card.runID) · \(ago(card.createdAt, now: now))",
                unread: refs.isEmpty ? card.isUnread : waiting > 0)
        case let .legacyDay(card):
            let today = HomeFeedBuilder.dayString(now, calendar: inputs.calendar)
            return InboxFolderListRow(
                id: entry.id, kind: .legacy, title: "Morning brief", summary: card.date == today ? "today" : "",
                detail: daySource(card), unread: card.isUnread)
        case .legacyTracks:
            let unread = feed.tracks.filter(\.isUnread).count
            return InboxFolderListRow(
                id: entry.id, kind: .legacy, title: "Track my threads",
                summary: unread > 0 ? "\(unread) unread" : "",
                detail: feed.tracks.map(\.lastEventAt).max().map { updated($0, now: now) } ?? "",
                unread: unread > 0)
        case .legacyIdeas:
            let judge = feed.ideas.filter(\.awaitsVerdict).count
            return InboxFolderListRow(
                id: entry.id, kind: .legacy, title: "Idea finder", summary: judge > 0 ? "\(judge) to judge" : "",
                detail: ideasUpdatedAt(feed).map { updated($0, now: now) } ?? "", unread: judge > 0)
        case .legacyMessages:
            return InboxFolderListRow(
                id: entry.id, kind: .legacy, title: "Messages", summary: "\(feed.messages.count) waiting",
                detail: "Mentions, DMs and replies", unread: feed.messages.contains { $0.item.isUnread })
        case let .approval(item):
            return InboxFolderListRow(id: entry.id, kind: .approval, title: approvalTitle(item), unread: true)
        case let .builtinNotice(notice):
            return InboxFolderListRow(id: entry.id, kind: .approval, title: notice.title, unread: true)
        }
    }

    private static func approvalTitle(_ item: NeedsApprovalItem) -> String {
        switch item.record {
        case let .action(action): action.reason.isEmpty ? action.tool : action.reason
        case let .reminder(reminder): reminder.note.isEmpty ? "Reminder" : reminder.note
        }
    }

    /// "updated 6 min ago", "updated just now".
    private static func updated(_ date: Date, now: Date) -> String {
        "updated \(ago(date, now: now))"
    }

    private static func ago(_ date: Date, now: Date) -> String {
        let age = now.timeIntervalSince(date)
        return age < 60 ? "just now" : "\(AutomationCardPresentation.relative(age)) ago"
    }

    /// "Your day · Fri 6 Nov".
    private static func daySource(_ card: InboxDayCard) -> String {
        guard let date = dayParser.date(from: card.date) else { return "Your day · \(card.date)" }
        return "Your day · \(dayFormatter.string(from: date))"
    }

    nonisolated(unsafe) private static let dayParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    nonisolated(unsafe) private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE d MMM"
        return formatter
    }()
}
