import Foundation
import OSLog
import WatchtowerCore

private let navigationLog = Logger(subsystem: Constants.bundleID, category: "inbox")

/// Cross-tab links: each switches the sidebar to its destination with the
/// item to select there.
extension AppState {
    func navigateToDigest(_ digestID: Int) {
        pendingDigestID = digestID
        selectedDestination = .digests
    }

    func navigateToDecision(_ ideaID: Int) {
        pendingDecisionID = ideaID
        selectedDestination = .digests
    }

    /// The Inbox on `route`'s folder with its entry open (old screen links,
    /// Home, notifications, a built-in's Show in Inbox, the helpers below). The Inbox has no
    /// feature or source gate (C1), so it always shows. The returned task is
    /// the Inbox's read and selection, for a test to await; nil before the
    /// Inbox's view model exists.
    @discardableResult
    func openInbox(_ route: InboxRoute) -> Task<Void, Never>? {
        // Before the Inbox shows: its arrival yields to the route.
        actionStripViewModel?.beginRoute()
        selectedDestination = .inbox
        guard let inbox = actionStripViewModel else { return nil }
        return Task { await inbox.open(folder: route.folderID, select: route.entry) }
    }

    /// A built-in card's **Show in Inbox**: the folder its artifacts land in
    /// (its route, else its default folder, else the root), resolved on a
    /// fresh read of the menu.
    @discardableResult
    func openBuiltinInInbox(automationID: Int64, defaultFolder: String) -> Task<Void, Never>? {
        actionStripViewModel?.beginRoute()
        selectedDestination = .inbox
        guard let inbox = actionStripViewModel else { return nil }
        return Task {
            await inbox.refresh()
            let folder = inbox.folderMenu.tree.folder(forAutomation: automationID, defaultSlug: defaultFolder)
            await inbox.open(folder: folder.id, select: nil)
        }
    }

    /// The Inbox's Needs approval folder (the root on a tree without it),
    /// resolved on a fresh read of the menu: a proposal push's click.
    @discardableResult
    func openNeedsApproval() -> Task<Void, Never>? {
        actionStripViewModel?.beginRoute()
        selectedDestination = .inbox
        guard let inbox = actionStripViewModel else { return nil }
        return Task {
            await inbox.refresh()
            let tree = inbox.folderMenu.tree
            await inbox.open(folder: (tree.approvals ?? tree.root).id, select: nil)
        }
    }

    /// Today's local day, "YYYY-MM-DD" — the Inbox's own day key.
    nonisolated static func inboxToday(_ now: Date = Date()) -> String {
        HomeFeedBuilder.dayString(now, calendar: .current)
    }

    /// The idea's card in the Inbox's Idea finder list.
    @discardableResult
    func navigateToIdea(_ ideaID: Int) -> Task<Void, Never>? {
        openInbox(.card(.idea(ideaID)))
    }

    func navigateToTarget(_ targetID: Int) {
        pendingTargetID = targetID
        selectedDestination = .targets
    }

    /// The briefing's day card in the Inbox's root (its Morning brief entry): the Inbox shows at
    /// once, the briefing's date is read off the main thread, then its card
    /// opens; a briefing that is gone (or no database) opens today's card.
    @discardableResult
    func navigateToBriefing(_ briefingID: Int) -> Task<Void, Never>? {
        actionStripViewModel?.beginRoute()
        selectedDestination = .inbox
        let pool = databaseManager?.dbPool
        let inbox = actionStripViewModel
        return Task {
            var date: String?
            if let pool {
                do {
                    date = try await pool.read { try BriefingQueries.fetchByID($0, id: briefingID)?.date }
                } catch {
                    // Today's card still opens; the failed read is logged.
                    navigationLog.error(
                        "reading briefing \(briefingID) for its day card: \(error.localizedDescription, privacy: .public)")
                }
            }
            // The route announced above is this `open`'s: no second announce.
            await inbox?.open(folder: nil, select: .card(.day(date ?? Self.inboxToday())))
        }
    }

    func navigateToCalendarEvent(_ eventID: String) {
        pendingCalendarEventID = eventID
        selectedDestination = .calendar
    }

    /// The day card of `date` ("YYYY-MM-DD", today when nil) in the Inbox's root.
    @discardableResult
    func navigateToDayPlan(_ date: String? = nil) -> Task<Void, Never>? {
        openInbox(.card(.day(date ?? Self.inboxToday())))
    }

    /// The track's card in the Inbox's Track my threads list.
    @discardableResult
    func navigateToTrack(_ trackID: Int) -> Task<Void, Never>? {
        openInbox(.card(.track(trackID)))
    }

    func navigateToPerson(_ userID: String) {
        pendingPersonUserID = userID
        selectedDestination = .people
    }

    func navigateToWorkbench(_ route: WorkbenchRoute) {
        pendingWorkbenchRoute = route
        selectedDestination = .workbench
    }

    /// A day plan item's source (moved from `DayPlanView`): its target, the
    /// plan's linked briefing, Connections → Jira for Jira, the Linear issue. A focus,
    /// calendar or manual item has nowhere to go.
    func openDayPlanItemSource(_ item: DayPlanItem) {
        guard let sid = item.sourceId, !sid.isEmpty else { return }
        switch item.sourceType {
        case .task:
            if let id = Int(sid) {
                navigateToTarget(id)
            }
        case .briefingAttention:
            // briefing_attention source_id points at the attention item's inner source
            // (track/digest/people/task), not a briefings.id. Route to the plan's linked
            // briefing, or fall back to the plan's own day card.
            let plan = dayPlanViewModel?.plan.flatMap { $0.id == item.dayPlanId ? $0 : nil }
            if let bid = plan?.briefingId {
                navigateToBriefing(Int(bid))
            } else {
                navigateToDayPlan(plan?.planDate)
            }
        case .jira:
            openConnections(.jira)
        case .linear:
            // Open the Linear issue itself, else Blockers.
            if !openTrackerIssue(tracker: .linear, key: sid) {
                selectedDestination = .blockers
            }
        case .focus, .calendar, .manual:
            break
        }
    }

    /// A briefing item's deep link (`BriefingSectionsView`).
    func openBriefingLink(_ link: BriefingLink) {
        switch link {
        case .track(let id):
            if let id { navigateToTrack(id) } else { openInbox(.legacy(.tracks)) }
        case .digest(let id):
            if let id { navigateToDigest(id) } else { selectedDestination = .digests }
        case .person(let userID):
            if let userID { navigateToPerson(userID) } else { selectedDestination = .people }
        case .workbench(let id):
            if let id {
                navigateToWorkbench(WorkbenchRoute(projectID: id, pane: .board))
            } else {
                selectedDestination = .workbench
            }
        case .target(let id):
            navigateToTarget(id)
        }
    }

    /// A briefing item's **Make a Task** (R9): a target from the item's
    /// prefill (the one the Create Target sheet used), opened in Targets.
    /// Returns the failure to show, or nil.
    func makeTask(from source: BriefingTaskSource, briefing: Briefing) async -> String? {
        guard let db = databaseManager else { return "Database not available" }
        let prefill: TargetPrefill
        switch source {
        case .attention(let item):
            do {
                prefill = try await TargetPrefillBuilder.fromBriefingItem(item, briefing: briefing, db: db)
            } catch {
                return "Couldn't prepare the task: \(error.localizedDescription)"
            }
        case .coaching(let item):
            prefill = TargetPrefill(
                text: item.text,
                intent: "Surfaced in briefing on \(briefing.date).",
                sourceType: "briefing",
                sourceID: String(briefing.id)
            )
        }
        return await createTask(from: prefill)
    }

    /// The one create half of every **Make a Task** (briefing, day and track
    /// cards): a target from `prefill` for today, opened in Targets. A cut
    /// title keeps the whole text in the intent. Returns the failure, or nil.
    func createTask(from prefill: TargetPrefill) async -> String? {
        guard let db = databaseManager else { return "Database not available" }
        let title = TargetComposerLogic.deriveTitle(from: prefill.text)
        let fullText = prefill.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let intent = title == fullText ? prefill.intent : [fullText, prefill.intent]
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        let today = Self.makeTaskDay.string(from: Date())
        do {
            let id = try await db.dbPool.write { dbConn in
                try TargetQueries.create(
                    dbConn,
                    text: title,
                    intent: intent,
                    periodStart: today,
                    periodEnd: today,
                    sourceType: prefill.sourceType,
                    sourceID: prefill.sourceID,
                    secondaryLinks: prefill.secondaryLinks
                )
            }
            navigateToTarget(id)
            return nil
        } catch {
            return "Couldn't make the task: \(error.localizedDescription)"
        }
    }

    /// A made task's day period: the owner's local calendar day.
    private static let makeTaskDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
