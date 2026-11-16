import Foundation

/// Every user-facing string of the tower client and the screens that share
/// it (mockup §6 phone, §7 Mac Inbox states, §8 tray and other screens).
/// `TowerTextTests` pins each one.
public enum TowerText {
    /// Shown once the tower has been down for `TowerTiming.reconnectingLineAfter`.
    public static let reconnecting = "Reconnecting to Watchtower…"
    /// `failed(.down)`: the tower stayed down for `TowerTiming.failAfter`.
    public static let daemonDown = "Watchtower's background service isn't running"
    /// `failed(.version)`: `tower.hello` answered another interface version.
    public static let differentVersion = "Watchtower's background service is a different version."
    public static let retry = "Retry"
    public static let restart = "Restart"
    /// An action answered `unknown`, on the Mac (mockup §8): the screen re-reads.
    public static let didntConfirmMac = "Didn't confirm — checking again…"
    /// An action answered `unknown`, on the phone (mockup §6).
    public static let didntConfirmPhone = "Didn't confirm — check on the Mac."
    public static let refresh = "Refresh"
    /// The tray's status line while the owner's pause holds.
    public static let syncPaused = "Sync paused"
    public static let pauseSync = "Pause Sync"
    public static let resumeSync = "Resume Sync"
    /// An `ok` answer whose result does not decode (a client and daemon out of step).
    public static let unreadableAnswer = "Watchtower sent an answer this app can't read."
    /// A request whose params did not encode.
    public static let couldNotSend = "This request couldn't be sent to Watchtower."
}

// MARK: - Inbox (mobile Inbox mockups §1–§7)

/// The Inbox screens' strings, shared by the Mac and the phone. Times are
/// formatted by `InboxTime` in the zone the caller passes (the client's own,
/// never the Mac's). `TowerTextInboxTests` pins each one.
public extension TowerText {
    // §6 and §7: the tab's states.
    static func loadingInbox(hub: String) -> String { "Getting your Inbox from \(hub)…" }
    /// The Mac's first load (mockup §7).
    static let loadingInboxMac = "Loading the Inbox…"
    static let emptyTitle = "Nothing waits for you"
    static func emptyBody(hub: String) -> String { "New cards arrive after the next sync on \(hub)." }
    static func emptyFolderTitle(_ folder: String) -> String { "No cards in \(folder)" }
    static let emptyFolderBody = "Automations routed here write their cards into this folder. Routes are set on your Mac."
    static func tooOldTitle(hub: String) -> String { "Update Watchtower on \(hub)" }
    static func tooOldBody(hub: String) -> String { "Watchtower on \(hub) is too old to send its Inbox to the phone." }
    static let policyTitle = "The Inbox stays on your Mac"
    static let policyBody = "Your organization lets this phone see only Workbench."
    static func olderCards(_ n: Int) -> String { "\(n) older cards are on your Mac." }
    /// A failed read that keeps the last list (mockup §7): the time the list
    /// is from, in `timeZone` ("09:14"); a list from another day than `now`
    /// adds its day ("Nov 16, 09:14").
    static func refreshFailed(reason: String, shownAt: Date, timeZone: TimeZone, now: Date = Date()) -> String {
        "Couldn't refresh the Inbox: \(reason). Showing the list from \(InboxTime.dayAndClock(shownAt, now: now, timeZone: timeZone))."
    }
    /// A card whose blocks this app cannot draw (mockup §4).
    static let unsupportedCard = "This card needs a newer Watchtower on this iPhone. Showing its text."
    /// A Mac-only action drawn disabled on the phone.
    static let onYourMac = "On your Mac"
    /// An approval on the phone without the `permissions` grant.
    static let approveOnTheMac = "Approve on the Mac"

    // §1: the root and a folder.
    static let inThisFolder = "In this folder"
    static let needsYourDecision = "Needs your decision"
    static let today = "Today"
    static let earlier = "Earlier"
    static func waitingSubtitle(_ n: Int, updated: Date, now: Date) -> String {
        "\(n) waiting · updated \(InboxTime.ago(updated, now: now))"
    }
    /// A living card's time (`InboxCardTexts.updated`): "Updated just now",
    /// "Updated 10 min ago".
    static func updatedAgo(_ updated: Date, now: Date) -> String { "Updated \(InboxTime.ago(updated, now: now))" }
    static let living = "living"
    static func runLine(run: Int, at: Date, now: Date) -> String { "ϟ run #\(run) · \(InboxTime.ago(at, now: now))" }
    static let legacyBriefTitle = "Morning brief · today"
    static func withNews(_ n: Int) -> String { "\(n) with news" }
    static func toJudge(_ n: Int) -> String { "\(n) to judge" }
    static let justNow = "just now"
    static func secondsSpan(_ n: Int) -> String { "\(n) s" }
    static func minutesSpan(_ n: Int) -> String { "\(n) min" }
    static func hoursSpan(_ n: Int) -> String { "\(n) h" }
    static func daysSpan(_ n: Int) -> String { "\(n) d" }
    static func ago(_ span: String) -> String { "\(span) ago" }

    // §2: Waiting for me rows, their detail and the Reply… sheet.
    static let done = "Done"
    static let notDone = "Not done"
    static let snooze = "Snooze"
    static let snoozeOneHour = "Snooze 1h"
    static let hide = "Hide"
    static let stopWatching = "Stop watching"
    static let makeATask = "Make a Task"
    static let reply = "Reply…"
    static let propose = "Propose"
    static let snoozeMenu = "Snooze ▸"
    static let snoozeOneDay = "1 day"
    static let snoozeThreeDays = "3 days"
    static let snoozeOneWeek = "1 week"
    static let snoozePicker = "Snooze ▾"
    static func openIn(_ app: String) -> String { "Open in \(app)" }
    /// The row detail's link.
    static func openInDetail(_ app: String) -> String { "Open in \(app) ↗" }
    static let markingDone = "Marking done…"
    static let snoozing = "Snoozing…"
    static let hiding = "Hiding…"
    static func ageBadge(hours: Int) -> String { "\(hours) h" }
    static let whyItMatters = "Why it matters"
    static let thread = "Thread"
    static let cancel = "Cancel"
    static func replyIn(_ place: String) -> String { "Reply in \(place)" }
    static let replyNote = "The reply goes to Needs approval. Nothing is sent until you approve it there, on this phone or on the Mac."

    // §3: Needs approval.
    static let approve = "Approve"
    static let reject = "Reject"
    static let dismiss = "Dismiss"
    static let approving = "Approving…"
    static let rejecting = "Rejecting…"
    static func recipeOff(hub: String) -> String {
        "Showing approvals in the standard card — Needs approval is off on \(hub)."
    }
    static let editOnYourMac = "Edit on your Mac"
    static let openDraftOnYourMac = "Open Draft — on your Mac"
    static func failedPrefix(_ error: String) -> String { "Failed: \(error)" }
    static func reminderLine(at: Date, timeZone: TimeZone = .current) -> String {
        "Reminder · \(InboxTime.clock(at, timeZone: timeZone))"
    }
    static func assistantProposal(at: Date, timeZone: TimeZone = .current) -> String {
        "Assistant proposal · \(InboxTime.clock(at, timeZone: timeZone))"
    }
    /// `device` is "this iPhone" on the phone (`thisIPhone`).
    static func replyFromWaiting(device: String, at: Date, timeZone: TimeZone = .current) -> String {
        "Reply from Waiting for me · \(device) · \(InboxTime.clock(at, timeZone: timeZone))"
    }
    static let thisIPhone = "this iPhone"
    /// A target button whose proposal stopped in flight (the Mac's
    /// `ArtifactTargetStuckLine`), offering `tryAgain`.
    static let didntFinish = "Didn't finish"
    static let tryAgain = "Try again"

    // §4: an artifact card.
    static let chatOnYourMac = "Chat — on your Mac"
    static let scrolls = "scrolls ›"
    static let runNow = "Run Now"
    static let runningNow = "Running…"
    static let macOnlyMenuNote = "Edit, Move to Folder, Turn Off and Delete are on your Mac"

    // §5: the legacy entries.
    static func stopped(_ n: Int) -> String { "Stopped · \(n)" }
    static let show = "Show"
    static func toJudgeHeader(_ n: Int) -> String { "To judge · \(n)" }
    static let notNow = "Not now"
    static let recent = "Recent"
    static let trackHint = "Swipe: Done · Stop watching · long press: Make a Task"

    // The Mac's row buttons (`InboxRowActionsView`), shared with the phone's menu.
    static let discussInChat = "Discuss in Chat"
    static let handToAgent = "Hand to Agent…"
    static let goToTarget = "Go to Target"
    static let deleteTrack = "Delete…"
    static let activate = "Activate"
    static let drop = "Drop"
    /// An inbox item's Open button by its trigger (`InboxMessagePane.openLabel`).
    static func openLabel(trigger: String) -> String {
        if trigger.hasPrefix("jira_") { return openIn("Jira") }
        if trigger.hasPrefix("linear_") { return openIn("Linear") }
        if trigger == "email_received" { return openIn("Mail") }
        return openIn("Slack")
    }

    /// The line a row or button shows while `request` runs (mockup §2, §3,
    /// §4); nil for a request drawn with a spinner alone.
    static func busyLabel(for request: ActRequest) -> String? {
        switch request.verb {
        case .done: return markingDone
        case .runNow: return runningNow
        case .ref:
            switch request.params.refVerb {
            case .resolve?, .done?, .check?: return markingDone
            case .snooze?: return snoozing
            case .dismiss?: return hiding
            case .approve?: return approving
            case .reject?: return rejecting
            default: return nil
            }
        case .approval:
            switch request.params.approvalVerb {
            case .approve?, .retry?: return approving
            case .reject?: return rejecting
            default: return nil
            }
        default: return nil
        }
    }
}
