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
}
