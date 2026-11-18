import Foundation

/// Every string of Watchman's arming controls (spec
/// `docs/superpowers/specs/2026-11-16-watchman-design.md` §2, §5, D21, D47):
/// the session strip, the target panel, the tray items and the arm sheet.
/// The spec's verbatim copy is pinned by `WatchmanArmingCopyTests`.
package enum WatchmanArmingCopy {
    // MARK: Controls

    package static let handTo = "Hand to Watchman"
    package static let takeBack = "Take back"
    package static let handHelp = "Watchman answers for this session until you take it back; "
        + "every decision lands in Inbox → Watchman"
    package static let takeBackHelp = "Take this session back from Watchman"
    /// A session under an armed target, maybe also handed over itself: every
    /// source that keeps it Watchman's, and where each is taken back.
    package static func viaTargetHelp(target: Int64, direct: Bool) -> String {
        direct
            ? "Handed over through #\(target) and directly — take #\(target) back on its panel, then this session here"
            : "Handed over through #\(target) — take #\(target) back on its panel"
    }

    /// "Sleep since 01:40"; just "Sleep" without a time.
    package static func sleepSince(_ since: Date?, calendar: Calendar = .current) -> String {
        guard let since else { return "Sleep" }
        return "Sleep since \(clock(since, calendar))"
    }

    /// The strip's chip: "Watchman · Sleep since 01:40".
    package static func stripArmed(since: Date?, calendar: Calendar = .current) -> String {
        "Watchman · \(sleepSince(since, calendar: calendar))"
    }

    /// The target panel's line: "Watchman has this target · Sleep since 01:40".
    package static func targetArmed(since: Date?, calendar: Calendar = .current) -> String {
        "Watchman has this target · \(sleepSince(since, calendar: calendar))"
    }

    package static func targetArmedCaption(target: Int64) -> String {
        "Answers for you in every session under #\(target): the running ones and the ones started under it."
    }

    package static func targetUnarmedCaption(target: Int64) -> String {
        "Watchman answers for you in every session under #\(target) until you take it back."
    }

    package static func armFailed(_ message: String) -> String {
        "Couldn't hand it to Watchman: \(message)"
    }

    package static func takeBackFailed(_ message: String) -> String {
        "Couldn't take it back: \(message)"
    }

    /// `sidecar_error`: the arming is written; the guard's fallback file
    /// follows at the daemon's next cycle.
    package static let sidecarNote = "Handed to Watchman; its guard file is rewritten at the daemon's next cycle"
    /// `disarm`'s `sidecar_error`.
    package static let takeBackSidecarNote = "Taken back; its guard file is rewritten at the daemon's next cycle"
    /// A verb's stdout that is not its JSON reply.
    package static let replyUnreadable = "the reply could not be read"
    /// `arm` exited 0 but its reply could not be read: the status says.
    package static let rereading = "Watchman's reply could not be read; rereading its state"
    package static let retry = "Retry"

    /// The controls could not read `watchman status`.
    package static func statusReadFailed(_ message: String) -> String {
        "Couldn't read Watchman's state: \(message)"
    }

    /// What stays under a control after a successful arm: the D21 line when
    /// analytics was turned on, the warnings, the sidecar note.
    package static func armedNotice(_ reply: WatchmanArmReply) -> String? {
        var lines: [String] = []
        if reply.analyticsTurnedOn { lines.append(analyticsLine) }
        lines += reply.warnings
        if !reply.sidecarError.isEmpty { lines.append(sidecarNote) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: Menu bar

    package static let trayHandAll = "Hand all running sessions to Watchman"
    /// Shown while the daemon is stopped (the journal's line).
    package static let daemonStopped = "Watchman is not running — the daemon is stopped"

    /// The tray's Watchman status line; nil before a status was read.
    /// "Watchman · Sleep since 01:40 · 3 sessions", "Watchman · Off".
    package static func trayStatus(_ status: WatchmanStatus?, calendar: Calendar = .current) -> String? {
        guard let status else { return nil }
        guard status.mode != .off else { return "Watchman · Off" }
        if status.daemon == .stopped { return daemonStopped }
        let count = status.armedSessions.count
        let sessions = count == 1 ? "1 session" : "\(count) sessions"
        return "Watchman · \(sleepSince(status.modeSince, calendar: calendar)) · \(sessions)"
    }

    // MARK: Arm sheet

    /// D21, verbatim.
    package static let analyticsLine = "Agent analytics turned on — Watchman learns from your sessions"
    package static let learningNote = "Until learning finishes, Watchman parks everything for you"
    package static let limitsLine = "Merging to main, messages to people and releases stay yours: Watchman parks them."
    /// The accepted residual risk of spec §5 item 4.
    package static let residualRisk = "Not caught: deleting files outside the worktree from a script, "
        + "or messaging people from a script with its own token."
    /// The branch-protection check's line as the CLI prints it (spec §5 item 2).
    package static let protectionWarning = "main is not protected on GitHub — an agent's gh pr merge cannot be stopped here"
    package static let notNow = "Not now"
    package static let sheetBody = "Watchman answers for you in the sessions you hand it, whether you are here or "
        + "not, until you take them back. Every decision lands in Inbox → Watchman with its reason."

    package static func sheetTitle(workbench: String) -> String {
        "Hand \(workbench) to Watchman?"
    }

    /// The tray's sheet: every running session, maybe on several workbenches.
    package static let sheetTitleAllRunning = "Hand all running sessions to Watchman?"
    /// The tray's sheet after the running set changed while it was open.
    package static let sessionsChanged = "The running sessions changed since this opened — this is the new set."

    /// "Learning from your history: ~1 850 decisions, est. 1.6 M tokens".
    package static func historyLine(_ estimate: WatchmanEstimate?) -> String {
        guard let estimate else { return "Learning from your history first" }
        return "Learning from your history: ~\(WatchmanSettingsCopy.count(estimate.decisions)) decisions, "
            + "est. \(WatchmanSettingsCopy.tokens(estimate.tokens)) tokens"
    }

    private static func clock(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}

/// What the arm sheet shows for one `watchman arm --check` reply.
package struct WatchmanArmSheetContent: Equatable, Sendable {
    package struct Line: Equatable, Hashable, Sendable {
        /// An SF Symbol name.
        package let icon: String
        package let text: String
    }

    package let title: String
    package let body: String
    package let lines: [Line]
    /// Above the body: why the sheet asks again.
    package let notice: String?
    /// Branch protection first, then one line per repository the git guard
    /// cannot be installed in.
    package let warnings: [String]
    package let confirm = WatchmanArmingCopy.handTo
    package let cancel = WatchmanArmingCopy.notNow

    package init(workbench: String, reply: WatchmanArmReply) {
        self.init(title: WatchmanArmingCopy.sheetTitle(workbench: workbench), reply: reply)
    }

    package init(title: String, reply: WatchmanArmReply, notice: String? = nil) {
        typealias Copy = WatchmanArmingCopy
        self.title = title
        self.notice = notice
        body = Copy.sheetBody
        var lines: [Line] = []
        if reply.firstTime {
            lines.append(Line(icon: "chart.bar.xaxis", text: Copy.analyticsLine))
            lines.append(Line(icon: "books.vertical", text: Copy.historyLine(reply.estimate)))
            lines.append(Line(icon: "hourglass", text: Copy.learningNote))
        }
        lines.append(Line(icon: "hand.raised", text: Copy.limitsLine))
        lines.append(Line(icon: "eye.slash", text: Copy.residualRisk))
        self.lines = lines
        warnings = reply.warnings
    }
}
