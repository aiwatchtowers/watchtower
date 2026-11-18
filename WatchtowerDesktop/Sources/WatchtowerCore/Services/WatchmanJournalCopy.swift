import Foundation

/// Every string of the morning journal, its Inbox entry and the Home row
/// (spec §10; the verbatim lines of the phase-2 plan's Global Constraints).
/// UI text is English only.
package enum WatchmanJournalCopy {
    // MARK: The journal

    package static let title = "Watchman"
    package static let scopeAll = "All workbenches"
    package static let waitingTitle = "WAITING FOR YOU"
    package static let decidedTitle = "Decided"
    package static let checksTitle = "Checks nobody ran"
    package static let tonight = "Tonight"
    package static let unsureBadge = "Unsure"
    package static let choseLabel = "Chose"
    package static let leanedOn = "Leaned on"
    package static let checkLine = "Not run by you — Watchman continued"
    package static let daemonStopped = "Watchman is not running — the daemon is stopped"
    package static let ownerFirst = "the owner answered first"
    /// An ask withdrawn or replaced by the agent after the twin decided it.
    package static let superseded = "The ask was withdrawn before the answer"
    package static let sessionEnded = "session ended"
    package static let stayedAwake = "the Mac stayed awake"

    // MARK: States

    /// The `EmptyStateCopyTable` key of the journal with no night (C1).
    package static let emptyCopyKey = "inboxWatchman"
    package static let emptyHint = "Use Hand to Watchman on a session strip, or Hand all running sessions to Watchman "
        + "in the menu bar."
    package static let loading = "Reading the journal…"
    package static let readFailed = "Couldn't read the journal. The decisions are stored; nothing was lost."
    package static let retry = "Retry"

    package static func deciding(_ question: String) -> String {
        "Deciding: \(oneLine(question))"
    }

    // MARK: Home and the Inbox entry

    package static func homeRow(_ counts: WatchmanNightCounts) -> String {
        "Overnight Watchman decided \(counts.decided) — \(counts.unsure) unsure, \(counts.waiting) waiting for you"
    }

    /// The entry's summary; empty when nothing waits.
    package static func inboxSummary(waiting: Int) -> String {
        waiting > 0 ? "\(waiting) waiting" : ""
    }

    /// "Night of 16 Nov · 14 decided · 2 unsure"; empty before the first night.
    package static func inboxDetail(_ counts: WatchmanNightCounts?, now: Date, calendar: Calendar) -> String {
        guard let counts else { return "" }
        var parts = [nightTitle(counts.start, now: now, calendar: calendar), "\(counts.decided) decided"]
        if counts.unsure > 0 { parts.append("\(counts.unsure) unsure") }
        return parts.joined(separator: " · ")
    }

    // MARK: Nights

    /// "Tonight" for the night now runs in, else "Night of 16 Nov".
    package static func nightTitle(_ start: Date, now: Date, calendar: Calendar) -> String {
        if start == WatchmanNight.start(of: now, calendar: calendar) { return tonight }
        return "Night of \(format(start, "d MMM", calendar))"
    }

    /// The night list's second line.
    package static func nightListLine(_ night: WatchmanNight, live: Bool) -> String {
        let counts = WatchmanNightCounts(night)
        if live { return "In progress · \(counts.decided) decided so far" }
        var parts = ["\(counts.decided) decided"]
        if counts.unsure > 0 {
            parts.append("\(counts.unsure) unsure")
        } else if counts.decided > 0 {
            parts.append("all sure")
        }
        if counts.waiting > 0 { parts.append("\(counts.waiting) waiting") }
        return parts.joined(separator: " · ")
    }

    /// The header's span: "01:40–07:30 · the Mac stayed awake" (no gap),
    /// "Since 01:40 · Watchman is on" (live), "01:40–07:30" otherwise.
    package static func nightSpan(_ night: WatchmanNight, live: Bool, calendar: Calendar) -> String {
        let items = night.items
        guard let first = items.first?.createdAt else { return "" }
        let from = format(first, "HH:mm", calendar)
        if live { return "Since \(from) · Watchman is on" }
        let last = items.map { $0.decidedAt ?? $0.createdAt }.max() ?? first
        let span = "\(from)–\(format(last, "HH:mm", calendar))"
        return night.gaps.isEmpty ? "\(span) · \(stayedAwake)" : span
    }

    package static func gapLine(_ gap: ClosedRange<Date>, calendar: Calendar) -> String {
        "the Mac slept from \(format(gap.lowerBound, "HH:mm", calendar)) to "
            + "\(format(gap.upperBound, "HH:mm", calendar)), nothing ran"
    }

    /// "Cost tonight $3.40" for tonight, else "Cost $3.40".
    package static func cost(_ usd: Double, tonight: Bool) -> String {
        let amount = String(format: "$%.2f", locale: Locale(identifier: "en_US_POSIX"), usd)
        return tonight ? "Cost tonight \(amount)" : "Cost \(amount)"
    }

    /// "2 unsure · 12 sure"; a part with nothing is left out.
    package static func decidedSummary(unsure: Int, sure: Int) -> String {
        var parts: [String] = []
        if unsure > 0 { parts.append("\(unsure) unsure") }
        if sure > 0 { parts.append("\(sure) sure") }
        return parts.joined(separator: " · ")
    }

    // MARK: Cards

    /// "acme-api · session 4 · 05:12".
    package static func place(_ item: WatchmanItem, calendar: Calendar) -> String {
        var parts: [String] = []
        if !item.workbenchName.isEmpty { parts.append(item.workbenchName) }
        if item.sessionID > 0 { parts.append("session \(item.sessionID)") }
        parts.append(format(item.decidedAt ?? item.createdAt, "HH:mm", calendar))
        return parts.joined(separator: " · ")
    }

    /// A waiting card's reason: "Parked: …" or "Handed to you: …".
    package static func waitingReason(_ item: WatchmanItem) -> String {
        if item.outcome == "handed" {
            return "Handed to you: \(oneLine(item.rationale.isEmpty ? item.choice : item.rationale))"
        }
        return item.parkReason.isEmpty ? "Parked" : "Parked: \(oneLine(item.parkReason))"
    }

    /// "confidence low · design"; the parts Watchman left empty are left out.
    package static func meta(_ item: WatchmanItem) -> String {
        var parts: [String] = []
        if !item.confidence.isEmpty { parts.append("confidence \(item.confidence)") }
        parts.append(item.category.isEmpty ? kindName(item.kind) : item.category)
        return parts.joined(separator: " · ")
    }

    /// What became of the decision (phase 2 tracks the decision only, not
    /// a merge: a v1 limit).
    package static func outcome(_ item: WatchmanItem) -> String {
        if item.delivery == "no_session" { return sessionEnded }
        switch item.outcome {
        case "owner_first": return ownerFirst
        case "superseded": return superseded
        case "approved": return "Approved the review round"
        case "changes": return "Asked for changes in the review round"
        case "parked", "handed": return waitingReason(item)
        default: return "Answered in the session"
        }
    }

    package static func kindName(_ kind: String) -> String {
        switch kind {
        case "ask": "ask"
        case "review_doc": "spec review"
        case "review_code": "code review"
        case "permission": "permission"
        case "handover": "handover"
        case "check": "check"
        case "guard": "finish"
        default: kind
        }
    }

    /// The card's question line: its first line, or the kind when Watchman stored none.
    package static func question(_ item: WatchmanItem) -> String {
        let line = oneLine(item.question)
        return line.isEmpty ? kindName(item.kind).capitalizedFirst : line
    }

    // MARK: Feedback (OK, Correct…, Open session, check done)

    package static let ok = "OK"
    package static let correct = "Correct…"
    package static let openSession = "Open session"
    package static let markDone = "Mark done"
    package static let okGiven = "You marked this OK — Watchman learns from it"
    package static let sending = "Sending your correction…"

    /// The card's line once the owner corrected it.
    package static func corrected(_ text: String) -> String {
        "You corrected: \(oneLine(text))"
    }

    /// Where the correction went (`SessionLineDelivery.Delivery`).
    package static func sentToSession(_ sessionID: Int64) -> String {
        "Sent to session \(sessionID)"
    }

    package static func typedIntoSession(_ sessionID: Int64) -> String {
        "Typed into session \(sessionID) — press Return there to send it"
    }

    package static func copiedForSession(_ sessionID: Int64) -> String {
        "On the clipboard — paste it into session \(sessionID)"
    }

    package static func heldForSession(_ sessionID: Int64) -> String {
        "Waiting to go into session \(sessionID) — it is on a permission prompt"
    }

    package static func startedSession(_ sessionID: Int64) -> String {
        "Started session \(sessionID) with your correction"
    }

    /// A stored correction found unsent on a fresh read.
    package static let appQuit = "the app quit before it went"
    /// Correct… lost to another judgement of the same decision.
    package static let alreadyJudged = "This decision was already judged; your text is kept here."

    /// A held correction's session stopped before it went.
    package static let sessionStopped = "the session stopped before it went"

    /// An OK, Mark done or correction the database refused.
    package static func saveFailed(_ reason: String) -> String {
        "Couldn't save: \(reason)"
    }

    /// A correction stored but not delivered; the card offers `retry`.
    package static func notSent(_ reason: String) -> String {
        "Not sent — \(reason)"
    }

    // MARK: The Correct… sheet

    package static let correctTitle = "Correct this decision"
    package static let correctQuestion = "What would you have decided?"
    package static let cancel = "Cancel"
    package static let sendCorrection = "Send Correction"
    package static let teaches = "Your answer also teaches Watchman."

    /// Where the correction goes: the live session, else a new one on the
    /// item's target (or its workbench) — in the owner's name, not armed.
    package static func correctNote(_ item: WatchmanItem, sessionAlive: Bool) -> String {
        if sessionAlive, item.sessionID > 0 {
            return "Your correction goes to session \(item.sessionID) as a typed line. \(teaches)"
        }
        let place = item.targetID > 0 ? "#\(item.targetID)" : (item.workbenchName.isEmpty ? "the workbench" : item.workbenchName)
        let ended = item.sessionID > 0 ? "Session \(item.sessionID) has ended" : "No session is running"
        return "\(ended), so a new session starts on \(place) with your correction. \(teaches)"
    }

    /// The line the session gets: what was decided, then the owner's words
    /// (one line, as every delivered line).
    package static func correctionLine(_ item: WatchmanItem, text: String) -> String {
        let words = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        var context = "Watchman decided \"\(question(item))\""
        if !item.choice.isEmpty { context += " as \"\(oneLine(item.choice))\"" }
        return "\(context) while I was away. My correction: \(words)"
    }

    // MARK: - Private

    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    /// One formatter per pattern, calendar and zone, made once.
    nonisolated(unsafe) private static var formatters: [String: DateFormatter] = [:]
    private static let formattersLock = NSLock()

    private static func format(_ date: Date, _ pattern: String, _ calendar: Calendar) -> String {
        formattersLock.lock()
        defer { formattersLock.unlock() }
        let key = "\(pattern)|\(calendar.identifier)|\(calendar.timeZone.identifier)"
        if let formatter = formatters[key] { return formatter.string(from: date) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        formatters[key] = formatter
        return formatter.string(from: date)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
