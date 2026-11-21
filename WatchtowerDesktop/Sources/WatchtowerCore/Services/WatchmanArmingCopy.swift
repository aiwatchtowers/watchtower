import Foundation

/// Every string of Watchman's arming controls (spec
/// `docs/superpowers/specs/2026-11-16-watchman-design.md` §2, §5, D21, D47):
/// the session strip, the target panel, the tray items and the arm sheet,
/// with the instruction field of the tuning spec
/// (`docs/superpowers/specs/2026-11-21-watchman-tuning-design.md` §2, D8).
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
            ? "Handed over through #\(target) and directly — Take back here removes the direct hand-over; "
                + "take #\(target) back on its panel"
            : "Handed over through #\(target) — take #\(target) back on its panel"
    }

    /// Take back on a session also covered by its target.
    package static func takeBackDirectHelp(target: Int64) -> String {
        "Takes back only this session's own hand-over; #\(target) still hands it to Watchman"
    }

    /// "since 01:40"; just "on" without a time. No mode word (tuning D8:
    /// "Sleep" meant nothing to the owner).
    package static func since(_ since: Date?, calendar: Calendar = .current) -> String {
        guard let since else { return "on" }
        return "since \(clock(since, calendar))"
    }

    /// The strip's chip: "Watchman · since 01:40", "Watchman · on".
    package static func stripArmed(since: Date?, calendar: Calendar = .current) -> String {
        "Watchman · \(self.since(since, calendar: calendar))"
    }

    /// The target panel's line: "Watchman has this target · since 01:40";
    /// without a time just "Watchman has this target".
    package static func targetArmed(since: Date?, calendar: Calendar = .current) -> String {
        guard let since else { return "Watchman has this target" }
        return "Watchman has this target · \(self.since(since, calendar: calendar))"
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
    /// "Watchman · since 01:40 · 3 sessions", "Watchman · Off".
    package static func trayStatus(_ status: WatchmanStatus?, calendar: Calendar = .current) -> String? {
        guard let status else { return nil }
        guard status.mode != .off else { return "Watchman · Off" }
        if status.daemon == .stopped { return daemonStopped }
        let count = status.armedSessions.count
        let sessions = count == 1 ? "1 session" : "\(count) sessions"
        return "Watchman · \(since(status.modeSince, calendar: calendar)) · \(sessions)"
    }

    // MARK: Instruction (tuning spec §2)

    /// The most the field keeps: Go clips the stored text to as many runes.
    package static let instructionMaxCharacters = 2000
    /// The count shows past this many characters.
    package static let instructionCounterFrom = 1800
    package static let fieldLabel = "Instruction for Watchman (optional)"
    package static let placeholder = "What this session is for, what to prefer, what to leave to you — "
        + "e.g. \"ship task 3 only; ask me before touching the schema\""
    /// The short sheet's and the tray sheet's title and confirm.
    package static let shortTitle = handTo
    package static let handOver = "Hand over"
    package static let cancel = "Cancel"
    /// The edit sheet's title (from Instruction… on the chip or the panel).
    package static let editTitle = "Instruction for Watchman"
    package static let save = "Save"
    package static let instructionButton = "Instruction…"
    /// An SF Symbol name: the Instruction… button.
    package static let instructionIcon = "text.quote"

    package static func saveFailed(_ error: String) -> String {
        "Could not save: \(error)"
    }

    /// "1912 / 2000".
    package static func counter(_ count: Int) -> String {
        "\(count) / \(instructionMaxCharacters)"
    }

    /// The counter under the field: only past `instructionCounterFrom`
    /// characters of the text as Go stores it (trimmed, counted in runes).
    package static func counter(for text: String) -> String? {
        let count = text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count
        return count > instructionCounterFrom ? counter(count) : nil
    }

    /// The text the field keeps: at most `instructionMaxCharacters` runes
    /// counted as the counter and Go count them (after the leading blanks;
    /// the trailing ones go with the cut).
    package static func clipped(_ text: String) -> String {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count > instructionMaxCharacters
        else { return text }
        let lead = text.unicodeScalars.prefix { CharacterSet.whitespacesAndNewlines.contains($0) }.count
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.prefix(lead + instructionMaxCharacters))
        return String(scalars)
    }

    /// Save on an empty field while the stored text could not be read: an
    /// empty file would clear a text the owner never saw.
    package static let instructionUnread = "Watchman's stored instruction could not be read, so an empty one "
        + "would erase it unseen — type the new instruction, or Cancel"
    /// A confirm while the same scope's hand-over or Take back still runs.
    package static let armInProgress = "Watchman is still handing this over or taking it back — try again in a moment"

    /// The chip's tooltip: the instruction's first non-blank line; nil
    /// without one.
    package static func instructionHelp(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    /// The sheet's subject: "#41 Ship task 3 of the billing plan"; a target
    /// or session the app has no title for by its id.
    package static func subject(_ scope: WatchmanArmScope, title: String?) -> String {
        let id: Int64
        switch scope {
        case let .session(sessionID): id = sessionID
        case let .target(targetID): id = targetID
        case .allRunning: return ""
        }
        if let title, !title.isEmpty { return "#\(id) \(title)" }
        if case .target = scope { return "Target #\(id)" }
        return sessionFallback(id)
    }

    // MARK: Arm sheet

    /// D21, verbatim.
    package static let analyticsLine = "Agent analytics turned on — Watchman learns from your sessions"
    /// The first-time sheet's learning line (tuning spec §3): what happens
    /// to questions asked while Watchman learns the workbench.
    package static func learningLine(_ estimate: WatchmanEstimate?) -> String {
        let first = estimate.map {
            "Watchman learns this workbench first (about \(WatchmanSettingsCopy.count($0.decisions)) decisions)."
        } ?? "Watchman learns this workbench first."
        return first + " Questions asked meanwhile wait and are decided once it finishes — or answer them yourself."
    }

    package static let limitsLine = "Merging to main, messages to people and releases stay yours: Watchman parks them."
    /// The accepted residual risks of spec §5 item 4: the spec's two
    /// examples, then a pointer to the guide's full list.
    package static let residualRisk = "Not caught: deleting files outside the worktree from a script, "
        + "or messaging people from a script with its own token; more in Hand a session to Watchman in the guide."
    /// The branch-protection check's line as the CLI prints it (spec §5 item 2).
    package static let protectionWarning = "main is not protected on GitHub — an agent's gh pr merge cannot be stopped here"
    package static let sheetBody = "Watchman answers for you in the sessions you hand it, whether you are here or "
        + "not, until you take them back. Every decision lands in Inbox → Watchman with its reason."

    package static func sheetTitle(workbench: String) -> String {
        "Hand \(workbench) to Watchman?"
    }

    /// The tray found no running agent session.
    package static let nothingToHandOver = "Nothing to hand over: no agent session is running"
    /// The CLI did not list the running sessions, so the set cannot be confirmed.
    package static let updateCLI = "Update Watchtower's command-line tool to hand every running session to Watchman"
    /// `--only` ids that were not armed.
    package static func droppedLine(_ ids: [Int64]) -> String {
        "Not handed over (no longer running): " + ids.map { "#\($0)" }.joined(separator: ", ")
    }

    /// The sheet's list header: "Hands over 2 sessions:".
    package static func sessionsHeader(_ count: Int) -> String {
        count == 1 ? "Hands over 1 session:" : "Hands over \(count) sessions:"
    }

    /// A session the app has no title for.
    package static func sessionFallback(_ id: Int64) -> String { "Session \(id)" }

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

/// What the arm sheet shows: a hand-over after its `watchman arm --check`
/// reply, or the instruction's edit sheet. Every hand-over opens it, so the
/// owner can give the session an instruction (tuning spec §2).
package struct WatchmanArmSheetContent: Equatable, Sendable {
    package enum Mode: Equatable, Sendable {
        /// A first hand-over on a workbench, or one the check warns about:
        /// what turns on, the limits and the warnings, then the field.
        case firstTime
        /// Every later hand-over of a session or a target: its subject and
        /// the field.
        case short
        /// Instruction… on an armed chip or panel: the field and Save.
        case edit
        /// The tray's every running session: the list and the field; an
        /// empty field keeps each session's stored instruction.
        case tray
    }

    package struct Line: Equatable, Hashable, Sendable {
        /// An SF Symbol name.
        package let icon: String
        package let text: String
    }

    package let mode: Mode
    package let title: String
    /// What Watchman does: a first time only.
    package let body: String?
    package let lines: [Line]
    /// Above the body: why the sheet asks again.
    package let notice: String?
    /// The one session or target the short and edit sheets name
    /// ("#41 Ship task 3"); nil on the first-time and tray sheets.
    package let subject: String?
    /// The sessions it hands over, by title ("#12 Fix login"): the
    /// first-time and tray sheets.
    package let sessions: [String]
    /// Branch protection first, then one line per repository the git guard
    /// cannot be installed in.
    package let warnings: [String]
    package let cancel = WatchmanArmingCopy.cancel
    package let fieldLabel = WatchmanArmingCopy.fieldLabel
    package let placeholder = WatchmanArmingCopy.placeholder

    package var confirm: String {
        mode == .edit ? WatchmanArmingCopy.save : WatchmanArmingCopy.handOver
    }

    /// The first-time sheet of a workbench (the check's reply decides the
    /// lines); `title` defaults to the workbench's.
    package init(workbench: String, reply: WatchmanArmReply, sessions: [String] = [], notice: String? = nil) {
        self.init(mode: .firstTime, title: WatchmanArmingCopy.sheetTitle(workbench: workbench), reply: reply,
                  subject: nil, sessions: sessions, notice: notice)
    }

    /// A hand-over's sheet: the tray's for every running session; the
    /// first-time one when the check says a first time or a warning;
    /// otherwise the short one naming `subject`.
    package static func handOver(
        _ scope: WatchmanArmScope,
        workbench: String?,
        reply: WatchmanArmReply,
        subject: String,
        sessions: [String],
        notice: String? = nil
    ) -> Self {
        if scope == .allRunning {
            return Self(mode: .tray, title: WatchmanArmingCopy.shortTitle, reply: reply, subject: nil,
                        sessions: sessions, notice: notice)
        }
        if reply.needsSheet {
            return Self(mode: .firstTime, title: workbench.map(WatchmanArmingCopy.sheetTitle(workbench:))
                ?? WatchmanArmingCopy.shortTitle, reply: reply, subject: nil, sessions: sessions, notice: notice)
        }
        return Self(mode: .short, title: WatchmanArmingCopy.shortTitle, reply: reply, subject: subject,
                    sessions: [], notice: notice)
    }

    /// Instruction… on an armed chip or panel.
    package static func edit(subject: String) -> Self {
        Self(mode: .edit, title: WatchmanArmingCopy.editTitle, reply: WatchmanArmReply(), subject: subject,
             sessions: [], notice: nil)
    }

    private init(
        mode: Mode, title: String, reply: WatchmanArmReply, subject: String?, sessions: [String], notice: String?
    ) {
        typealias Copy = WatchmanArmingCopy
        self.mode = mode
        self.title = title
        self.notice = notice
        self.subject = subject
        self.sessions = sessions
        // The tray's sheet shows what turns on and the warnings only when
        // its check asks for them, as a first time does.
        let full = mode == .firstTime || (mode == .tray && reply.needsSheet)
        body = full ? Copy.sheetBody : nil
        var lines: [Line] = []
        if full {
            if reply.firstTime {
                lines.append(Line(icon: "chart.bar.xaxis", text: Copy.analyticsLine))
                lines.append(Line(icon: "books.vertical", text: Copy.historyLine(reply.estimate)))
                lines.append(Line(icon: WatchmanStyle.icon, text: Copy.learningLine(reply.estimate)))
            }
            lines.append(Line(icon: "hand.raised", text: Copy.limitsLine))
            lines.append(Line(icon: "eye.slash", text: Copy.residualRisk))
        }
        self.lines = lines
        warnings = full ? reply.warnings : []
    }
}
