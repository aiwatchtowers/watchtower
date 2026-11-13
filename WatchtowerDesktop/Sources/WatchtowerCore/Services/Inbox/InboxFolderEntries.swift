import Foundation

/// One entry of a folder (spec "The Inbox screen" 2, "Moving today's Inbox
/// into folders"): an automation's artifact, a legacy entry over today's
/// panes (ask #445: a Morning brief per date, Track my threads, Idea finder,
/// and Messages while it stands in for Waiting for me), an open approval or
/// a built-in upgrade notice (Needs approval), or a thread brief the
/// `:brief:` reaction made (the root, 24 hours, ask #609).
package enum InboxFolderEntry: Identifiable, Equatable, Sendable {
    case artifact(AutomationOutputCard)
    case brief(AgentAction)
    case legacyDay(InboxDayCard)
    case legacyTracks
    case legacyIdeas
    case legacyMessages
    case approval(NeedsApprovalItem)
    case builtinNotice(BuiltinUpgradeNotice)

    package var id: String {
        switch self {
        case let .artifact(card): "artifact:\(card.id)"
        case let .brief(action): "brief:\(action.id)"
        case let .legacyDay(card): Self.dayID(card.date)
        case .legacyTracks: "tracks"
        case .legacyIdeas: "ideas"
        case .legacyMessages: "messages"
        case let .approval(item): "approval:\(item.key)"
        case let .builtinNotice(notice): "notice:\(notice.builtinID)"
        }
    }

    /// A Morning brief day's entry id (`"day:<yyyy-MM-dd>"`); `dayID("")`
    /// is the prefix every one starts with.
    package static func dayID(_ date: String) -> String { "day:\(date)" }

    /// A legacy entry whose pane is today's list (Track my threads, Idea
    /// finder, Messages): that list.
    package var legacyList: InboxLegacyList? {
        switch self {
        case .legacyTracks: .tracks
        case .legacyIdeas: .ideas
        case .legacyMessages: .messages
        case .artifact, .brief, .legacyDay, .approval, .builtinNotice: nil
        }
    }

    /// The legacy entry whose list is `list`.
    package static func legacy(_ list: InboxLegacyList) -> Self {
        switch list {
        case .tracks: .legacyTracks
        case .ideas: .legacyIdeas
        case .messages: .legacyMessages
        }
    }

    /// The entry's own ⋯ (and context menu): only the Idea finder has one
    /// here, **Find Ideas in Past Messages…**, moved from the old Ideas
    /// filter's menu. An artifact's ⋯ is its automation's (Task 14).
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
        package var now: Date
        package var calendar: Calendar
        /// Today's idea batch (`ActionStripViewModel.ideaBatch`); nil = the
        /// first `IdeaDailyBatch.defaultSize` candidates, nothing stored.
        package var ideaBatch: IdeaBatchState?

        package init(
            feed: InboxFeedSnapshot,
            folders: InboxFolderMenuSnapshot,
            approvalsOn: Bool = true,
            now: Date,
            calendar: Calendar = .current,
            ideaBatch: IdeaBatchState? = nil
        ) {
            self.feed = feed
            self.folders = folders
            self.approvalsOn = approvalsOn
            self.now = now
            self.calendar = calendar
            self.ideaBatch = ideaBatch
        }

        /// `ideaBatch`, or the default batch over the feed's ideas.
        var batch: IdeaBatchState {
            if let ideaBatch { return ideaBatch }
            let size = IdeaDailyBatch.defaultSize
            let ids = IdeaDailyBatch.candidates(feed.ideas, now: now).prefix(size).map(\.id)
            return IdeaDailyBatch.state(ideas: feed.ideas, batchIDs: ids, now: now, size: size, calendar: calendar)
        }
    }

    /// `folder`'s entries in list order.
    /// - Needs approval: the built-in upgrade notices, then every open
    ///   approval — native cards above the recipe's cards (spec "mixed").
    /// - The root: Waiting for me pinned first while it has rows that wait
    ///   on the owner, then Mail waiting's artifact; then, newest first, its
    ///   artifacts and the legacy entries by their own time (ask #445), and
    ///   each thread brief applied
    ///   in the last 24 hours by its applied time (ask #609); the Messages entry only while
    ///   it stands in for Waiting for me (`WaitingForMeState`). On a tree
    ///   without Needs approval (an older database) the root also holds the
    ///   approvals.
    /// - An owner folder: its artifacts, newest change first.
    /// A legacy entry with nothing to show is left out: Track my threads
    /// stays while a track is stopped (its Stopped fold restores it), Idea
    /// finder while its built-in exists (New idea, Find Ideas in Past
    /// Messages…).
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
            var mail: [InboxFolderEntry] = []
            var timed: [(at: Date, entry: InboxFolderEntry)] = []
            for card in artifacts {
                if isWaitingForMe(card, read), waitingCount(card, read) > 0 {
                    pinned.append(.artifact(card))
                } else if isMailWaiting(card, read) {
                    mail.append(.artifact(card))
                } else {
                    timed.append((card.changedAt, .artifact(card)))
                }
            }
            timed += legacy(inputs)
            timed.sort { $0.at > $1.at }
            let rest = read.tree.approvals == nil ? approvals(inputs) : []
            return pinned + mail + timed.map(\.entry) + rest
        }
    }

    /// The entry a folder opens on (spec "Selection"): `saved` (the owner's
    /// last pick there, `ActionStripViewModel.entryKey`) while it is listed
    /// and is not a legacy list — a Needs approval group row
    /// (`NeedsApprovalGroups.rowID`) while it is among `drawnRows`; else,
    /// in the root, today's Morning brief (`"day:<today>"`) while it is
    /// listed; else the first entry that is not a legacy list; else nil. A
    /// legacy list (Track my threads, Idea finder, Messages) is never opened
    /// by default.
    package static func defaultEntry(
        entries: [InboxFolderEntry],
        saved: String?,
        folder: InboxFolderKind,
        today: String,
        drawnRows: [String] = []
    ) -> String? {
        let openable = entries.filter { $0.legacyList == nil }.map(\.id)
        if let saved, openable.contains(saved) { return saved }
        if let saved, NeedsApprovalGroups.isGroupRowID(saved), drawnRows.contains(saved) { return saved }
        let brief = InboxFolderEntry.dayID(today)
        if folder == .root, openable.contains(brief) { return brief }
        return openable.first
    }

    /// Needs approval's entries: notices first, then the native cards, then
    /// the recipe's cards, then the approved rows still in flight. The
    /// approvals open in this read are the strip's actions that wait on the
    /// owner (`openActions`) and its due reminders. An `approved` or
    /// `executing` row is not closed: it stays on its native card (spec A,
    /// "A proposal stuck in approved or executing": a stuck target proposal
    /// shows "Didn't finish" with **Try again** there), and leaves once it
    /// is applied, rejected or failed. Such a row is not an approval waiting
    /// on the owner, so it never counts (the folder's count and the badge
    /// stay `awaitingOwnerCount`). The strip's recently decided tail is
    /// never drawn here.
    private static func approvals(_ inputs: Inputs) -> [InboxFolderEntry] {
        let state = inputs.folders.needsApproval
        let open = inputs.feed.proposals.filter { inputs.folders.openActions.contains($0.id) }
        let items = NeedsApprovalSelection.items(
            proposals: open, reminders: inputs.feed.reminders,
            artifacts: inputs.folders.approvalArtifacts,
            recipeOn: inputs.approvalsOn && !state.stopped, lastRunFailed: state.lastRunFailed)
        let native = items.filter { $0.recipe == nil }
        let recipe = items.filter { $0.recipe != nil }
        let inFlight = inputs.feed.proposals
            .filter { ($0.status == "approved" || $0.isExecuting) && !inputs.folders.openActions.contains($0.id) }
            .map { NeedsApprovalItem(.action($0)) }
        return inputs.feed.builtinNotices.map(InboxFolderEntry.builtinNotice)
            + (native + recipe + inFlight).map(InboxFolderEntry.approval)
    }

    /// The root's legacy entries with their own times.
    private static func legacy(_ inputs: Inputs) -> [(at: Date, entry: InboxFolderEntry)] {
        let feed = inputs.feed
        var out: [(at: Date, entry: InboxFolderEntry)] = days(inputs).map { ($0.stamp, .legacyDay($0)) }
        if let at = tracksUpdatedAt(feed) {
            out.append((at, .legacyTracks))
        }
        if !feed.ideas.isEmpty || inputs.folders.ideaFinderPresent {
            out.append((ideasUpdatedAt(feed) ?? .distantPast, .legacyIdeas))
        }
        if inputs.folders.waitingForMe.messagesStandIn, let at = feed.messages.map(\.stamp).max() {
            out.append((at, .legacyMessages))
        }
        out += feed.briefs.map { (AutomationDates.parse($0.appliedAt) ?? .distantPast, .brief($0)) }
        return out
    }

    /// The root's one day card (`InboxListBuilder.rootDays`): today's.
    private static func days(_ inputs: Inputs) -> [InboxDayCard] {
        let today = HomeFeedBuilder.dayString(inputs.now, calendar: inputs.calendar)
        return InboxListBuilder.rootDays(inputs.feed, today: today, now: inputs.now, calendar: inputs.calendar)
    }

    /// The newest track's time, stopped ones included; nil = no track.
    private static func tracksUpdatedAt(_ feed: InboxFeedSnapshot) -> Date? {
        (feed.tracks + feed.stoppedTracks).map(\.lastEventAt).max()
    }

    private static func ideasUpdatedAt(_ feed: InboxFeedSnapshot) -> Date? {
        feed.ideas.compactMap { AutomationDates.parse($0.updatedAt) }.max()
    }

    private static func isWaitingForMe(_ card: AutomationOutputCard, _ read: InboxFolderMenuSnapshot) -> Bool {
        read.waitingForMe.automationID == card.automationID
    }

    private static func isMailWaiting(_ card: AutomationOutputCard, _ read: InboxFolderMenuSnapshot) -> Bool {
        read.mailWaiting.automationID == card.automationID
    }

    /// `card` is the `slack-today` built-in's: its row draws from the state.
    package static func isSlackToday(_ card: AutomationOutputCard, _ read: InboxFolderMenuSnapshot) -> Bool {
        read.slackToday?.automationID == card.automationID
    }

    /// The rows of `card` that wait on the owner (the render-time check).
    private static func waitingCount(_ card: AutomationOutputCard, _ read: InboxFolderMenuSnapshot) -> Int {
        (read.refs[card.id] ?? []).filter(read.refState.waits).count
    }

    // MARK: - The list rows

    /// `entry`'s row in the folder list, with the entry's own ⋯.
    package static func row(_ entry: InboxFolderEntry, _ inputs: Inputs) -> InboxFolderListRow {
        var isArtifact = false
        if case .artifact = entry { isArtifact = true }
        return InboxFolderListRow(
            id: entry.id, content: content(entry, inputs), menu: entry.menuEntries, isArtifact: isArtifact)
    }

    /// What `entry`'s row shows (spec "The list", phase 1).
    package static func content(_ entry: InboxFolderEntry, _ inputs: Inputs) -> InboxRowContent {
        let feed = inputs.feed
        let now = inputs.now
        switch entry {
        case let .artifact(card) where isWaitingForMe(card, inputs.folders):
            return peopleWaiting(title: card.title.isEmpty ? card.automationName : card.title, inputs)
        case .legacyMessages:
            return peopleWaiting(title: InboxLegacyList.messages.title, inputs)
        case let .artifact(card) where isMailWaiting(card, inputs.folders):
            return mailWaiting(card, inputs)
        case let .artifact(card) where isSlackToday(card, inputs.folders):
            return SlackTodayRow.content(
                state: inputs.folders.slackToday?.state ?? .none, isUnread: card.isUnread, changedAt: card.changedAt,
                now: now, calendar: inputs.calendar)
        case let .artifact(card):
            return artifact(card, inputs)
        case let .legacyDay(card):
            return brief(card, inputs)
        case .legacyTracks:
            // Phase 3: only the threads with news (`TrackThreadsSummary`).
            let summary = TrackThreadsSummary.build(tracks: feed.tracks, now: now)
            let at = tracksUpdatedAt(feed)
            return InboxRowContent(
                kind: .threads, title: InboxLegacyList.tracks.title, preview: summary.rowPreview,
                meta: summary.rowMeta, time: at.map { time($0, inputs) } ?? "",
                pill: summary.pillCount.flatMap { pill($0, .news) }, isUnread: summary.isUnread)
        case .legacyIdeas:
            // Phase 3: today's batch (`IdeaBatchState`).
            let batch = inputs.batch
            let at = ideasUpdatedAt(feed)
            return InboxRowContent(
                kind: .ideas, title: InboxLegacyList.ideas.title, preview: batch.rowPreview, meta: batch.rowMeta,
                time: at.map { time($0, inputs) } ?? "",
                pill: batch.pillCount.flatMap { pill($0, .batch) }, isUnread: batch.isUnread)
        case let .brief(action):
            // A result, not something waiting: never unread, never counted.
            return InboxRowContent(
                kind: .threads, title: action.reason.isEmpty ? "Thread brief" : action.reason,
                meta: "Thread brief", time: AutomationDates.parse(action.appliedAt).map { time($0, inputs) } ?? "")
        case let .approval(item):
            return NeedsApprovalGroups.itemContent(item, now: now, calendar: inputs.calendar)
        case let .builtinNotice(notice):
            return InboxRowContent(kind: .approval, title: notice.title, isUnread: true)
        }
    }

    /// Waiting for me's row (its artifact, or the Messages entry standing in
    /// for it): the newest open people item from today, the Older section's
    /// count (7 × 24 h or more), the people waiting today on the pill. The
    /// counts are the uncapped `PeopleWaitingCounts`: the feed's page is
    /// capped and mail can fill it. Mail is never one of them
    /// (`InboxPeopleRule`), though the stand-in's list still lists it.
    private static func peopleWaiting(title: String, _ inputs: Inputs) -> InboxRowContent {
        let messages = inputs.feed.messages
            .filter { InboxPeopleRule.isPeople(trigger: $0.item.triggerType) }
            .sorted { $0.stamp > $1.stamp }
        let today = messages.filter {
            InboxToday.isFromToday(createdAt: $0.stamp, mentionedAt: nil, now: inputs.now, calendar: inputs.calendar)
        }
        let people = inputs.folders.peopleWaitingToday
        let preview: String
        if let first = today.first {
            let more = max(people, today.count) - 1
            preview = messageLine(first) + (more > 0 ? " · and \(more) more today" : "")
        } else {
            preview = messages.first.map(messageLine) ?? "Nothing waits on you"
        }
        let older = inputs.folders.peopleWaiting.older
        return InboxRowContent(
            kind: .peopleWaiting, title: title, preview: preview, meta: older > 0 ? "\(older) older" : "",
            time: messages.first.map { time($0.stamp, inputs) } ?? "",
            pill: pill(people, .needsYou), isUnread: people > 0)
    }

    /// Mail waiting's row: today's mail and the busiest senders' share
    /// (`InboxWaitingTexts`), today's mail on a neutral pill. Never unread
    /// and never counted, whatever its read state or rows.
    private static func mailWaiting(_ card: AutomationOutputCard, _ inputs: Inputs) -> InboxRowContent {
        let summary = inputs.folders.mailSummary
        return InboxRowContent(
            kind: .mailWaiting, title: card.title.isEmpty ? card.automationName : card.title,
            preview: InboxWaitingTexts.mailPreview(summary), meta: InboxWaitingTexts.mailMeta(summary),
            time: time(card.changedAt, inputs), pill: pill(summary.today, .batch))
    }

    /// "Colleague B in a DM: “Will you approve the budget?”".
    private static func messageLine(_ row: HomeFeedInboxRow) -> String {
        let place: String? = switch row.item.triggerType {
        case "dm": "in a DM"
        default: row.whereText.map { $0.hasPrefix("#") ? "in \($0)" : $0 }
        }
        let who = [row.who, place].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        return "\(who): “\(InboxRowText.preview(row.item.snippet))”"
    }

    /// The Morning brief's row: its lead, the day it is for.
    private static func brief(_ card: InboxDayCard, _ inputs: Inputs) -> InboxRowContent {
        let lead = card.briefing.flatMap(InboxBriefLayout.lead)
        return InboxRowContent(
            kind: .brief, title: "Morning brief", preview: card.isEmpty ? "Not written yet" : lead ?? "",
            meta: dayLabel(card), time: card.isEmpty ? "" : time(card.stamp, inputs), isUnread: card.isUnread)
    }

    /// An owner artifact's row, under its folder's icon.
    private static func artifact(_ card: AutomationOutputCard, _ inputs: Inputs) -> InboxRowContent {
        let read = inputs.folders
        let refs = read.refs[card.id] ?? []
        let waiting = waitingCount(card, read)
        let folderID = read.cards.first { $0.value.contains { $0.id == card.id } }?.key
        let icon = folderID.flatMap { read.tree.folder($0)?.icon } ?? ""
        return InboxRowContent(
            kind: .artifact, title: card.title.isEmpty ? card.automationName : card.title,
            preview: InboxRowText.preview(card.body),
            meta: card.isLiving ? "Your automation · \(updated(card.writtenAt, now: inputs.now))"
                                : "Your automation · run #\(card.runID)",
            time: time(card.changedAt, inputs), pill: refs.isEmpty ? nil : pill(waiting, .needsYou),
            isUnread: refs.isEmpty ? card.isUnread : waiting > 0, symbol: InboxFolderIcons.symbol(for: icon))
    }

    /// A pill for `count`, none at 0.
    private static func pill(_ count: Int, _ tone: InboxRowPill.Tone) -> InboxRowPill? {
        count > 0 ? InboxRowPill(count: count, tone: tone) : nil
    }

    private static func time(_ date: Date, _ inputs: Inputs) -> String {
        InboxRowTime.label(date, now: inputs.now, calendar: inputs.calendar)
    }

    /// "updated 6 min ago", "updated just now".
    private static func updated(_ date: Date, now: Date) -> String {
        "updated \(ago(date, now: now))"
    }

    private static func ago(_ date: Date, now: Date) -> String {
        let age = now.timeIntervalSince(date)
        return age < 60 ? "just now" : "\(AutomationCardPresentation.relative(age)) ago"
    }

    /// "Fri 6 Nov".
    private static func dayLabel(_ card: InboxDayCard) -> String {
        dayParser.date(from: card.date).map(dayFormatter.string(from:)) ?? card.date
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
