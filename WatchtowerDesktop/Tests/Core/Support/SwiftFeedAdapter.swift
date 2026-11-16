import CryptoKit
import Foundation
import GRDB
import WatchtowerCore
import WatchtowerInterface

/// Test-only: today's Swift Inbox builders (`InboxFolderMenuSnapshot.read`,
/// `InboxFeedQueries.read`, `InboxFolderEntries.build`/`row`,
/// `InboxListBuilder.sections`, `InboxCardTexts`, `InboxCardSubject`,
/// `InboxRefState`, `InboxReplyPolicy`, `InboxCardAction`) mapped to the
/// generated `Feed`, so `InboxFeedParityTests` can compare them with the Go
/// feed over the shared fixture `internal/inboxfeed/testdata/inbox_feed_cases.json`.
///
/// The mapping is the only code here. Two lists name every card or folder
/// field a Swift builder does not hand over as is:
/// - `goOnlyFields`: the Swift side does not compute it; the comparison
///   blanks it on both sides.
/// - `restatedFields`: the adapter derives it from Swift data with the rule a
///   Swift builder applies (which it does not expose); it is compared.
enum SwiftFeedAdapter {
    /// Not computed by Swift, each with why: `blankGoOnly` clears exactly these.
    static let goOnlyFields: [String: String] = [
        "cards[].automation.builtin_id": "AutomationOutputCard does not carry its automation's built-in id",
        "cards[].body_clipped": "Clip is a Go-only option (the Mac never clips); no parity case sets it",
        "cards[].approval (all but target, target_note, target_until, superseded)": "the native card's text "
            + "lives in the app target (AgentActionCardView, SaveAutomationCardDetails): ApprovalTextParityTests "
            + "compares title, summary, edit_on_mac and the recipe disclosure over approval_text_cases.json; "
            + "proposer is checked through the card's source_line; status, error, reason and args_sha256 are "
            + "copied from the row and have no Swift-side check; recipe_clipped is Go-only (Clip)",
        "notice cards' source_line": "the Mac's notice row has no source line",
        "notice cards' preview": "the Mac's notice row has no summary line",
        "notice cards' priority": "a built-in move has no priority; the feed sends medium",
        "notice cards' content_hash": "a built-in move has no content hash; no write is guarded by one"
    ]

    /// Derived here with a Swift builder's own rule, each with where the rule
    /// lives; compared, not blanked.
    static let restatedFields: [String: String] = [
        "folders[].waiting": "InboxFolderEntries' open approvals (openActions ∩ proposals, due reminders) "
            + "plus each artifact's rows that wait (refState.waits)",
        "cards[].pinned": "InboxFolderEntries.build's pin: Waiting for me's card with rows that wait",
        "cards[].stamp": "InboxFolderEntries.row's detail time: written_at on a living card, else created_at; "
            + "a legacy entry's own time",
        "cards[].source_line": "InboxCardTexts.sourceLine without its last ' · <time>' part (the models add it); "
            + "a legacy row's detail",
        "native approvals' and reminders' source_line and stamp": "Go-only mappings the Mac's Needs approval "
            + "row does not show (it draws the title alone): a proposal's actionLabels label or "
            + "\"Assistant proposal\" and its created_at, a reminder's \"Reminder\" and its remind_at; "
            + "restated here so both sides agree",
        "cards[].preview": "a legacy row's summary (InboxFolderEntries.row)",
        "cards[].ref_facts": "InboxRef.refs once each, InboxRefState shown/waits, InboxReplyPolicy.tool(for:) "
            + "and isOpenReply, an item's permalink, a reminder's SlackMessageRef.url",
        "cards[].actions": "InboxCardAction.decode and replyState with InboxCardPress.isDisabled, "
            + "InboxCardButtons.label/caption and InboxCardLinkPolicy (a screen link is the Mac's); "
            + "target buttons decode only through the Kit (app target), so no parity case has one",
        "cards[].legacy": "InboxListBuilder.sections' rows with InboxListRow.content's words, "
            + "a day's DayPlanQueries.fetchItems (start and end) and Briefing.parsedAttention",
        "approval.target/target_note/target_until/superseded": "ActionStripViewModel.targetFacts(for:) and "
            + "isSupersededButtonRow over AgentActionQueries.newestButtonProposals/actionsWithTask; the state is "
            + "TargetButtonStateResolver's rule restated (app target, pinned by target_button_cases.json)",
        "cards[].link": "AutomationOutputCard.link, the common row's Open (InboxCardButtons.commonRow); "
            + "\"\" on every other card",
        "native approvals' content_hash": "SHA-256 of the args the card shows (ApproveSeen)",
        "thread-briefs": "the Mac lists each brief as its own root entry; the feed carries them as one card "
            + "at the newest one's place",
        "notice cards' id": "Swift keys a notice by built-in id; the feed's n<rowid> is read from builtin_migrations"
    ]

    /// The entry kinds the Swift builder lists that the adapter does not
    /// map; none since the approvals and legacy entries are mapped.
    static let laterKinds: Set<String> = []

    struct Mapped {
        var feed: Feed
        /// The Swift entry ids left out (each of a `laterKinds` kind).
        var unmapped: [String]
    }

    /// What the mapping reads besides the entries.
    private struct Context {
        let db: Database
        let snapshot: InboxFolderMenuSnapshot
        let feed: InboxFeedSnapshot
        let inputs: InboxFolderEntries.Inputs
        let labels: [Int64: String]
        /// The newest proposal of each Inbox target button and the applied
        /// ones' tasks (ActionStripViewModel's targetProposals/targetTasks).
        let buttons: [String: AgentAction]
        let tasks: [Int64: Int64]
        let now: Date
        let calendar: Calendar
    }

    /// The Swift builders' Inbox at `now` (zone UTC), narrowed to `folder`
    /// as `FeedRequest.folder` narrows it (every folder is still listed).
    /// `disabledFeatures` is the Mac's feature list (ActionStripViewModel's
    /// `disabledFeatures`), passed to every reader as the app passes it.
    static func feed(_ db: Database, now: Date, folder: Int64?, disabledFeatures: Set<String>) throws -> Mapped {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let nowUTC = AutomationDates.format(now)
        let snapshot = try InboxFolderMenuSnapshot.read(db, nowUTC: nowUTC, disabledFeatures: disabledFeatures)
        let feedSnapshot = try InboxFeedQueries.read(
            db, nowUTC: nowUTC, dayLimit: ActionStripViewModel.dayPage, disabledFeatures: disabledFeatures)
        let inputs = InboxFolderEntries.Inputs(
            feed: feedSnapshot, folders: snapshot,
            approvalsOn: !disabledFeatures.contains(ActionStripViewModel.approvalsFeatureID),
            now: now, calendar: calendar)
        let runLabels = try AutomationQueries.runLabels(
            db, runIDs: feedSnapshot.proposals.compactMap(ActionStripViewModel.automationRunID))
        let buttons = try AgentActionQueries.newestButtonProposals(
            db, outputIDs: feedSnapshot.outputs.map(\.id),
            contextIDs: feedSnapshot.proposals.filter { $0.contextType == AgentActionQueries.buttonContextType }
                .map(\.contextID))
        let tasks = try AgentActionQueries.actionsWithTask(
            db, actionIDs: buttons.values.filter { $0.status == "applied" }.map(\.id))
        let context = Context(
            db: db, snapshot: snapshot, feed: feedSnapshot, inputs: inputs,
            labels: ActionStripViewModel.labels(for: feedSnapshot.proposals, runLabels: runLabels),
            buttons: buttons, tasks: tasks, now: now, calendar: calendar)
        let tree = snapshot.tree
        let waiting = waitingCounts(context)
        let folders = tree.folders.map { item in
            Folder(
                id: item.id, kind: FolderKind(rawValue: item.kind.rawValue), slug: item.slug, title: item.title,
                icon: item.icon, parentID: item.parentID, position: item.position,
                hidden: !tree.isVisible(item.id), count: snapshot.counts[item.id] ?? 0, waiting: waiting[item.id] ?? 0)
        }
        var cards: [Card] = []
        for item in tree.folders where folder == nil || folder == item.id {
            var briefs: [(action: AgentAction, row: InboxFolderListRow)] = []
            var briefsAt: Int?
            for entry in InboxFolderEntries.build(folder: item, inputs) {
                let row = InboxFolderEntries.row(entry, inputs)
                switch entry {
                case let .artifact(card):
                    cards.append(try artifact(card, folder: item.id, row: row, context))
                case let .builtinNotice(notice):
                    cards.append(try builtinNotice(db, notice, folder: item.id, row: row))
                case let .approval(approval):
                    cards.append(try self.approval(approval, folder: item.id, row: row, context))
                case let .brief(action):
                    briefsAt = briefsAt ?? cards.count
                    briefs.append((action, row))
                case let .legacyDay(day):
                    cards.append(try self.day(day, folder: item.id, row: row, context))
                case .legacyTracks, .legacyIdeas, .legacyMessages:
                    cards.append(legacyList(entry, folder: item.id, row: row, context))
                }
            }
            if let at = briefsAt {
                cards.insert(threadBriefs(briefs, folder: item.id), at: at)
            }
        }
        return Mapped(feed: Feed(v: 1, builtAt: "", folders: folders, cards: cards), unmapped: [])
    }

    /// `feed` with the `goOnlyFields` cleared.
    static func blankGoOnly(_ feed: Feed) -> Feed {
        var out = feed
        out.builtAt = ""
        out.cards = out.cards.map { card in
            var card = card
            card.automation?.builtinID = ""
            card.bodyClipped = false
            if let approval = card.approval {
                card.approval = Approval(
                    tool: "", title: "", summary: "", argsSHA256: "", status: "", error: "", proposer: "", reason: "",
                    editOnMac: false, target: approval.target, targetNote: approval.targetNote,
                    targetUntil: approval.targetUntil, superseded: approval.superseded, disclosure: "",
                    recipeText: "", diff: [], recipeClipped: false)
            }
            if card.cardKind == .notice, card.id.hasPrefix("n") {
                card.sourceLine = ""
                card.preview = ""
                card.priority = ""
                card.contentHash = ""
            }
            return card
        }
        return out
    }

    // MARK: - Folders

    /// Each folder's part of its count that waits on the owner: the open
    /// approvals where Needs approval's entries list them, the artifacts'
    /// rows that wait everywhere else.
    private static func waitingCounts(_ context: Context) -> [Int64: Int] {
        let snapshot = context.snapshot
        var out: [Int64: Int] = [:]
        for folder in snapshot.tree.folders where folder.kind != .approvals {
            out[folder.id] = (snapshot.cards[folder.id] ?? []).map { waitingRows($0, snapshot) }.reduce(0, +)
        }
        let open = context.feed.proposals.filter { snapshot.openActions.contains($0.id) }.count
            + context.feed.reminders.count
        let approvals = snapshot.tree.approvals?.id ?? snapshot.tree.root.id
        out[approvals, default: 0] += open
        return out
    }

    private static func waitingRows(_ card: AutomationOutputCard, _ snapshot: InboxFolderMenuSnapshot) -> Int {
        (snapshot.refs[card.id] ?? []).filter(snapshot.refState.waits).count
    }

    // MARK: - Artifacts

    /// An artifact's card from its list row and the card texts. Swift's
    /// source line ends in " · <time>" ("· 10:00", "· Updated 10 min ago"),
    /// which the screen models add now; the adapter drops that last part.
    private static func artifact(
        _ card: AutomationOutputCard, folder: Int64, row: InboxFolderListRow, _ context: Context
    ) throws -> Card {
        let snapshot = context.snapshot
        return Card(
            id: "o\(card.id)", folderID: folder, cardKind: .artifact, title: row.title,
            sourceLine: withoutTime(InboxCardTexts.sourceLine(card, now: context.now, calendar: context.calendar)),
            preview: InboxCardTexts.preview(card.body),
            stamp: AutomationDates.format(card.isLiving ? card.writtenAt : card.createdAt),
            living: card.isLiving, unread: row.unread, priority: InboxCardSubject(card).priority,
            // InboxFolderEntries.build's pin: Waiting for me with rows that wait.
            pinned: snapshot.waitingForMe.automationID == card.automationID && waitingRows(card, snapshot) > 0,
            automation: CardAutomation(id: card.automationID, name: card.automationName, builtinID: "", runID: card.runID),
            blocks: card.blocksJSON, body: card.body, bodyClipped: false, link: card.link, contentHash: card.contentHash,
            actions: actions(card), refFacts: try refFacts(InboxRef.refs(blocksJSON: card.blocksJSON), context))
    }

    /// The row refs once each, in document order, as the render-time check
    /// and the row hooks read them.
    private static func refFacts(_ refs: [InboxRef], _ context: Context) throws -> [RefFacts] {
        var seen: Set<InboxRef> = []
        var out: [RefFacts] = []
        for ref in refs where seen.insert(ref).inserted {
            var facts = RefFacts(
                kind: RefKind(rawValue: ref.kind.rawValue), id: ref.id, open: context.snapshot.refState.isShown(ref),
                waits: context.snapshot.refState.waits(ref), reply: false, replyWaiting: false, link: "")
            switch ref.kind {
            case .inboxItem:
                if let item = try InboxQueries.fetchByID(context.db, id: Int(ref.id)) {
                    facts.reply = InboxReplyPolicy.tool(for: item) != nil
                    facts.link = item.permalink
                }
                facts.replyWaiting = context.feed.proposals.contains { InboxReplyPolicy.isOpenReply($0, itemID: Int(ref.id)) }
            case .reminder:
                let message = try String.fetchOne(
                    context.db, sql: "SELECT message_ref FROM reminders WHERE id = ?", arguments: [ref.id]) ?? ""
                facts.link = SlackMessageRef.url(message)?.absoluteString ?? ""
            case .track, .idea, .action:
                break
            }
            out.append(facts)
        }
        return out
    }

    /// The card's own buttons (InboxCardAction.decode) with the state the
    /// Mac draws them in (InboxCardButtons, InboxCardPress.isDisabled).
    private static func actions(_ card: AutomationOutputCard) -> [CardAction] {
        let reply = InboxCardAction.replyState(card)
        return InboxCardAction.decode(card.actionsJSON).compactMap { action in
            switch action.kind {
            case let .link(url):
                let state: ActionState = switch url.scheme?.lowercased() {
                case "http", "https": (url.host ?? "").isEmpty ? .disabled : .enabled
                case "watchtower-nav": .macOnly
                default: .disabled
                }
                return CardAction(index: action.index, kind: "link", label: action.label, state: state, detail: "", note: "", until: "")
            case .chat:
                return CardAction(index: action.index, kind: "chat", label: action.label, state: .macOnly, detail: "", note: "", until: "")
            case .agent:
                return CardAction(index: action.index, kind: "agent", label: action.label, state: .macOnly, detail: "", note: "", until: "")
            case .reply:
                return replyAction(action, reply: reply, card: card)
            case .target:
                return nil
            }
        }
    }

    private static func replyAction(_ action: InboxCardAction, reply: InboxReplyState, card: AutomationOutputCard) -> CardAction {
        var label = action.label
        if case let .sent(runID) = reply, card.pressedAction == action.index {
            label = runID.map { "Sent — run #\($0)" } ?? "Sent"
        }
        let (state, detail, note): (ActionState, String, String) = switch reply {
        case .ready: (.enabled, "ready", "")
        case .sent: (.pressed, "sent", "")
        case .needsConfirmation: (.enabled, "needs_confirmation", "Needs confirmation")
        case .off: (.enabled, "off", "Off")
        case .unreadable: (.enabled, "unreadable", "Recipe can't be read")
        case .removed: (.disabled, "removed", "Recipe removed")
        }
        return CardAction(index: action.index, kind: "reply", label: label, state: state, detail: detail, note: note, until: "")
    }

    // MARK: - Needs approval

    /// An approval as Needs approval lists it: the recipe's card, or the
    /// native proposal or reminder; titled and unread as its row.
    private static func approval(
        _ item: NeedsApprovalItem, folder: Int64, row: InboxFolderListRow, _ context: Context
    ) throws -> Card {
        if let recipe = item.recipe {
            var card = try artifact(recipe, folder: folder, row: row, context)
            card.title = row.title
            card.unread = true
            if case let .action(action) = item.record { card.approval = targetApproval(action, context) }
            return card
        }
        switch item.record {
        case let .action(action):
            let digest = SHA256.hash(data: Data(action.argsJSON.utf8)).map { String(format: "%02x", $0) }.joined()
            return Card(
                id: "a\(action.id)", folderID: folder, cardKind: .approvalNative, title: row.title,
                sourceLine: context.labels[action.id] ?? "Assistant proposal", preview: "",
                stamp: AutomationDates.parse(action.createdAt).map(AutomationDates.format) ?? "",
                living: false, unread: row.unread, priority: "medium", pinned: false, blocks: "", body: "",
                bodyClipped: false, link: "", contentHash: digest, actions: [], refFacts: [],
                approval: targetApproval(action, context))
        case let .reminder(reminder):
            return Card(
                id: "r\(reminder.id)", folderID: folder, cardKind: .reminder, title: row.title, sourceLine: "Reminder",
                preview: "", stamp: AutomationDates.parse(reminder.remindAt).map(AutomationDates.format) ?? "",
                living: false, unread: row.unread, priority: "medium", pinned: false, blocks: "", body: "",
                bodyClipped: false, link: "", contentHash: "", actions: [],
                refFacts: [RefFacts(kind: .reminder, id: reminder.id, open: true, waits: true, reply: false,
                                    replyWaiting: false, link: SlackMessageRef.url(reminder.messageRef)?.absoluteString ?? "")])
        }
    }

    /// The approval block's target button part, as the Mac's card gets it:
    /// the button's state on its newest proposal (`targetFacts(for:)`), the
    /// superseded flag on an older one (`isSupersededButtonRow`). The other
    /// fields are blanked by `blankGoOnly`.
    private static func targetApproval(_ action: AgentAction, _ context: Context) -> Approval {
        var target = ("", "", "")
        var superseded = false
        if action.contextType == AgentActionQueries.buttonContextType, let newest = context.buttons[action.contextID] {
            if newest.id != action.id {
                superseded = true
            } else if action.tool == "create_target" {
                target = targetState(newest, taskExists: context.tasks[newest.id] != nil, now: context.now)
            }
        }
        return Approval(
            tool: "", title: "", summary: "", argsSHA256: "", status: "", error: "", proposer: "", reason: "",
            editOnMac: false, target: target.0, targetNote: target.1, targetUntil: target.2, superseded: superseded,
            disclosure: "", recipeText: "", diff: [], recipeClipped: false)
    }

    /// TargetButtonStateResolver.state over the row alone (no press or apply
    /// of this Mac's own), as the feed's detail, note and until.
    private static func targetState(_ row: AgentAction, taskExists: Bool, now: Date) -> (String, String, String) {
        let decided = InboxTargetButtonFacts.Proposal(row).decidedDate
        switch row.status {
        case "pending": return ("waiting", "", "")
        case "approved", "executing":
            if let decided, now.timeIntervalSince(decided) < 120 {
                return ("creating", "", AutomationDates.format(decided.addingTimeInterval(120)))
            }
            return ("stuck", "", "")
        case "applied": return (taskExists ? "created" : "idle", "", "")
        case "failed":
            guard row.dismissedAt.isEmpty else { return ("idle", "", "") }
            return ("failed", row.error.isEmpty ? "The task was not created." : row.error, "")
        default: return ("idle", "", "")
        }
    }

    /// A failed move's card. Swift keys it by built-in id; the feed's id is
    /// the row's rowid (`n<rowid>`), read here for the mapping only.
    private static func builtinNotice(
        _ db: Database,
        _ notice: BuiltinUpgradeNotice,
        folder: Int64,
        row: InboxFolderListRow
    ) throws -> Card {
        let rowid = try Int64.fetchOne(
            db, sql: "SELECT rowid FROM builtin_migrations WHERE builtin_id = ?", arguments: [notice.builtinID]) ?? 0
        return Card(
            id: "n\(rowid)", folderID: folder, cardKind: .notice, title: row.title, sourceLine: "", preview: "",
            stamp: AutomationDates.format(notice.updatedAt), living: false, unread: row.unread, priority: "medium",
            pinned: false, blocks: "", body: notice.error, bodyClipped: false, link: "", contentHash: "", actions: [],
            refFacts: [])
    }

    // MARK: - Legacy entries

    private static func legacyCard(
        id: String, folder: Int64, row: InboxFolderListRow, sourceLine: String, stamp: Date, section: LegacySection
    ) -> Card {
        Card(
            id: id, folderID: folder, cardKind: .legacy, title: row.title, sourceLine: sourceLine, preview: row.summary,
            stamp: AutomationDates.format(stamp), living: false, unread: row.unread, priority: "medium", pinned: false,
            blocks: "", body: "", bodyClipped: false, link: "", contentHash: "", actions: [], refFacts: [], legacy: section)
    }

    /// A Morning brief day: its plan's items and its briefing's attention.
    private static func day(_ day: InboxDayCard, folder: Int64, row: InboxFolderListRow, _ context: Context) throws -> Card {
        let items = try day.plan.map { try DayPlanQueries.fetchItems(context.db, planId: $0.id) } ?? []
        let section = LegacySection(
            kind: .morningBrief,
            items: items.map { item in
                LegacyItem(
                    refKind: .planItem, id: item.id, title: item.title, subtitle: "", preview: "",
                    stamp: item.startTime.map(AutomationDates.format) ?? "",
                    end: item.endTime.map(AutomationDates.format) ?? "", unread: false,
                    high: item.priority == "high", stopped: false, done: item.isDone, date: day.date)
            },
            attention: (day.briefing?.parsedAttention ?? []).map { item in
                LegacyAttention(text: item.text, reason: item.reason ?? "", priority: item.priority ?? "",
                                sourceType: item.sourceType ?? "", sourceID: item.sourceID ?? "")
            })
        return legacyCard(id: "brief-\(day.date)", folder: folder, row: row, sourceLine: row.detail,
                          stamp: day.stamp, section: section)
    }

    /// Track my threads, Idea finder or Messages: its list's rows
    /// (InboxListBuilder.sections, the Stopped fold open) with each row's
    /// words (InboxListRow.content).
    private static func legacyList(
        _ entry: InboxFolderEntry, folder: Int64, row: InboxFolderListRow, _ context: Context
    ) -> Card {
        let feed = context.feed
        guard let list = entry.legacyList else { preconditionFailure("not a legacy list") }
        let sections = InboxListBuilder.sections(
            feed, list: list, now: context.now, calendar: context.calendar, showsStopped: true)
        var items: [LegacyItem] = []
        for section in sections {
            for item in section.items {
                if let mapped = legacyItem(item, stopped: section.foldable) { items.append(mapped) }
            }
        }
        switch list {
        case .tracks:
            let stamp = (feed.tracks + feed.stoppedTracks).map(\.lastEventAt).max() ?? .distantPast
            return legacyCard(id: "tracks", folder: folder, row: row, sourceLine: "", stamp: stamp,
                              section: LegacySection(kind: .tracks, items: items, attention: []))
        case .ideas:
            let stamp = feed.ideas.compactMap { AutomationDates.parse($0.updatedAt) }.max() ?? .distantPast
            return legacyCard(id: "ideas", folder: folder, row: row, sourceLine: "", stamp: stamp,
                              section: LegacySection(kind: .ideas, items: items, attention: []))
        case .messages:
            let stamp = feed.messages.map(\.stamp).max() ?? .distantPast
            return legacyCard(id: "messages", folder: folder, row: row, sourceLine: row.detail, stamp: stamp,
                              section: LegacySection(kind: .messages, items: items, attention: []))
        }
    }

    private static func legacyItem(_ item: InboxListItem, stopped: Bool) -> LegacyItem? {
        switch item {
        case let .track(card):
            return LegacyItem(
                refKind: .track, id: Int64(card.track.id), title: card.track.text, subtitle: "Track",
                preview: card.newEventCount > 0 ? "\(card.newEventCount) new" : "",
                stamp: AutomationDates.format(card.lastEventAt), end: "", unread: card.isUnread,
                high: card.track.priority == "high", stopped: stopped, done: false, date: "")
        case let .idea(idea):
            // InboxListRow.ideaSource.
            var source = "\(idea.kind.rawValue.capitalized) · \(idea.statusRaw.replacingOccurrences(of: "_", with: " "))"
            if idea.chatBorn { source += " · Chat" }
            return LegacyItem(
                refKind: .idea, id: Int64(idea.id), title: idea.title, subtitle: source, preview: idea.essence,
                stamp: AutomationDates.parse(idea.updatedAt).map(AutomationDates.format) ?? "0001-01-01T00:00:00Z",
                end: "", unread: idea.awaitsVerdict, high: false, stopped: false, done: false, date: "")
        case let .message(row):
            let prefix = [row.who, row.whereText ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
            return LegacyItem(
                refKind: .inboxItem, id: Int64(row.item.id), title: messageTitle(row),
                subtitle: prefix.isEmpty ? "Message" : prefix, preview: row.item.whyMatters,
                stamp: AutomationDates.format(row.stamp), end: "", unread: row.item.isUnread,
                high: row.item.priority == "high", stopped: false, done: false, date: "")
        case .proposal, .reminder, .output, .day, .builtinNotice:
            return nil
        }
    }

    /// InboxListRow.messageTitle.
    private static func messageTitle(_ row: HomeFeedInboxRow) -> String {
        if row.item.isAccumulated { return row.item.mentionCountTitle }
        var text = row.item.snippet
        if row.item.triggerType == "email_received", let range = text.range(of: " — ") {
            text = String(text[range.upperBound...])
        }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.isEmpty ? "Message" : line
    }

    /// The root's thread briefs as the feed's one card: an item per brief,
    /// each the brief's row words and its card summary.
    private static func threadBriefs(_ briefs: [(action: AgentAction, row: InboxFolderListRow)], folder: Int64) -> Card {
        let items = briefs.map { action, row in
            LegacyItem(
                refKind: .action, id: action.id, title: row.title,
                subtitle: "Thread brief",
                preview: action.resultString("summary") ?? action.argString("summary") ?? action.argsJSON,
                stamp: AutomationDates.parse(action.appliedAt).map(AutomationDates.format) ?? "",
                end: "", unread: false, high: false, stopped: false, done: false, date: "")
        }
        return Card(
            id: "thread-briefs", folderID: folder, cardKind: .legacy, title: "Thread briefs", sourceLine: "Thread brief",
            preview: "", stamp: items.first?.stamp ?? "", living: false, unread: false, priority: "medium",
            pinned: false, blocks: "", body: "", bodyClipped: false, link: "", contentHash: "", actions: [], refFacts: [],
            legacy: LegacySection(kind: .threadBriefs, items: items, attention: []))
    }

    private static func withoutTime(_ line: String) -> String {
        guard let range = line.range(of: " · ", options: .backwards) else { return line }
        return String(line[..<range.lowerBound])
    }
}
