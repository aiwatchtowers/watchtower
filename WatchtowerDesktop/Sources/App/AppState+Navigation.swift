import Foundation
import WatchtowerCore

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

    /// Unlike its siblings there is no pending field: `ideasViewModel` is
    /// AppState-owned and exists whenever the DB is open, so the selection is
    /// set on it directly and survives the Ideas view not being mounted yet.
    func navigateToIdea(_ ideaID: Int) {
        ideasViewModel?.reveal(ideaID)
        selectedDestination = .ideas
    }

    func navigateToTarget(_ targetID: Int) {
        pendingTargetID = targetID
        selectedDestination = .targets
    }

    func navigateToBriefing(_ briefingID: Int) {
        pendingBriefingID = briefingID
        selectedDestination = .briefings
    }

    func navigateToCalendarEvent(_ eventID: String) {
        pendingCalendarEventID = eventID
        selectedDestination = .calendar
    }

    func navigateToDayPlan(_ date: String? = nil) {
        pendingDayPlanDate = date
        selectedDestination = .dayPlan
    }

    func navigateToTrack(_ trackID: Int) {
        pendingTrackID = trackID
        selectedDestination = .tracks
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
    /// plan's linked briefing, Boards for Jira, the Linear issue. A focus,
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
            // briefing, or fall back to the briefings list.
            if let plan = dayPlanViewModel?.plan, plan.id == item.dayPlanId, let bid = plan.briefingId {
                navigateToBriefing(Int(bid))
            } else {
                selectedDestination = .briefings
            }
        case .jira:
            selectedDestination = .boards
        case .linear:
            // Linear has no Boards tab: open the issue itself, else Blockers.
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
            if let id { navigateToTrack(id) } else { selectedDestination = .tracks }
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
        let title = TargetComposerLogic.deriveTitle(from: prefill.text)
        // A cut title keeps the item's whole text in the intent.
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

    private static let makeTaskDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
