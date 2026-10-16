import Foundation

/// The words of the Automations tab (spec §12.1–12.2, approved mockup 1):
/// list rows, the card's subtitle, **It may**, **Limits per run**, the
/// History lines and which buttons are live. Pure, so the views stay thin.
package enum AutomationCardPresentation {
    package struct Pill: Equatable, Sendable {
        package let text: String
        package let badge: StatusBadge

        package init(text: String, badge: StatusBadge) {
            self.text = text
            self.badge = badge
        }
    }

    package struct PermissionLine: Equatable, Sendable {
        package let text: String
        /// In `show --json`'s `widening`: not covered by the confirmation.
        package let isNew: Bool

        package init(text: String, isNew: Bool) {
            self.text = text
            self.isNew = isNew
        }
    }

    package struct ButtonState: Equatable, Sendable {
        package let enabled: Bool
        /// Why the button is off.
        package let help: String?

        package init(enabled: Bool, help: String?) {
            self.enabled = enabled
            self.help = help
        }
    }

    package struct Buttons: Equatable, Sendable {
        package let runNow: ButtonState
        package let dryRun: ButtonState
        /// The **⋯** menu's Enable/Disable item.
        package let toggleLabel: String
    }

    private static let decimal: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return f
    }()

    // MARK: - Rows

    /// The row's second line: the trigger text, then the one fact that
    /// matters for the state. `changes` is the loaded `show --json` detail's
    /// (nil when no detail is loaded): only a `trigger` entry there says
    /// "schedule changed".
    package static func rowDetailLine(_ item: AutomationListItem, changes: [AutomationChange]?, now: Date) -> String {
        let automation = item.automation
        if !automation.parseError.isEmpty {
            return "can't be read: " + firstLine(automation.parseError)
        }
        var facts: [String] = []
        if automation.needsConfirmation {
            let scheduleChanged = changes?.contains { $0.field == "trigger" } ?? false
            facts.append(scheduleChanged ? "schedule changed, waiting for you" : "waiting for your confirmation")
        } else if automation.triggerKind == "event" {
            // Event triggers arrive in P4.
            facts.append("coming in a later version")
        } else if let active = item.activeRun {
            facts.append(activeFact(active, now: now))
        } else if let last = item.lastRun, [.red, .orange].contains(last.status.badge) {
            let reason = last.error.isEmpty ? statusText(last.status).lowercased() : firstLine(last.error)
            facts.append("last run: " + reason)
        } else {
            if automation.enabled, let next = automation.nextRunAt {
                let seconds = next.timeIntervalSince(now)
                facts.append(seconds > 0 ? "next in " + relative(seconds) : "due now")
            }
            if item.tokens7d > 0 {
                facts.append("\(compactTokens(item.tokens7d)) tokens this week")
            }
            if facts.isEmpty, let last = item.lastRun, let at = last.finishedAt ?? last.startedAt {
                facts.append("last run \(relative(now.timeIntervalSince(at))) ago")
            }
        }
        return ([item.triggerText] + facts).joined(separator: " · ")
    }

    private static func activeFact(_ run: AutomationRun, now: Date) -> String {
        switch run.status {
        case .waiting:
            let caption = waitingCaption(run.waitingReason)
            return caption.prefix(1).lowercased() + caption.dropFirst()
        case .queued:
            return "queued"
        default:
            guard let started = run.startedAt else { return "running" }
            return "started \(relative(now.timeIntervalSince(started))) ago"
        }
    }

    /// The status pill of a row without badges: the active run's, else the last run's.
    package static func statusPill(_ item: AutomationListItem) -> Pill? {
        guard let run = item.activeRun ?? item.lastRun else { return nil }
        return Pill(text: statusText(run.status), badge: run.status.badge)
    }

    package static func statusText(_ status: AutomationRunStatus) -> String {
        switch status {
        case .queued: "Queued"
        case .running: "Running"
        case .waiting: "Waiting"
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        case .budgetExceeded: "Budget exceeded"
        case .timedOut: "Timed out"
        case .cancelled: "Cancelled"
        case .expired: "Expired"
        }
    }

    package static func badgeText(_ badge: AutomationRowBadge) -> String {
        switch badge {
        case .needsConfirmation: "Needs your confirmation"
        case .autoPaused: "Auto paused"
        case .disabled: "Disabled"
        case .parseError: "Parse error"
        }
    }

    // MARK: - Card

    /// "<schedule in words> · <personal | workbench name> · <enabled | disabled>".
    package static func subtitle(_ automation: Automation, workbenchName: String?) -> String {
        let when = AutomationTriggerText.sentence(kind: automation.triggerKind, specJSON: automation.triggerSpecJSON)
        let scope = automation.scope == .personal ? "personal" : (workbenchName ?? "workbench")
        return [when, scope, automation.enabled ? "enabled" : "disabled"].joined(separator: " · ")
    }

    /// **Limits per run**.
    package static func limitsLines(_ automation: Automation) -> [String] {
        let minutes = automation.budgetMinutes == 1 ? "1 minute" : "\(automation.budgetMinutes) minutes"
        var lines = [
            "\(number(Int64(automation.budgetTokens))) tokens · \(minutes)",
            automation.concurrency <= 1 ? "One run at a time" : "Up to \(automation.concurrency) runs at a time"
        ]
        if automation.triggerKind == "schedule" {
            lines.append(automation.missedPolicy == "skip" ? "Missed while asleep: skip"
                                                           : "Missed while asleep: run once")
        }
        return lines
    }

    /// **It may**: each permission, then each output, as a human line.
    package static func permissionLines(permissions: [String], outputs: [String], widening: [String]) -> [PermissionLine] {
        let marked = Set(widening)
        return permissions.map { PermissionLine(text: permissionLine($0), isNew: marked.contains($0)) }
            + outputs.map { PermissionLine(text: outputLine($0), isNew: false) }
    }

    private struct Source {
        let name: String
        let noun: String
        let all: String
        let write: String
    }

    private static let sources: [String: Source] = [
        "gmail": Source(name: "Gmail", noun: "mail", all: "all accounts", write: "Send mail from"),
        "slack": Source(name: "Slack", noun: "messages", all: "all workspaces", write: "Post messages in"),
        "calendar": Source(name: "Calendar", noun: "events", all: "all accounts", write: "Change events in"),
        "jira": Source(name: "Jira", noun: "issues", all: "all projects", write: "Change issues in"),
        "confluence": Source(name: "Confluence", noun: "pages", all: "all spaces", write: "Edit pages in")
    ]

    private static let localNouns: [String: String] = [
        "targets": "your targets", "tracks": "your tracks", "ideas": "your ideas", "digests": "digests",
        "people": "people cards", "transcripts": "meeting transcripts", "meetings": "meeting recaps and notes",
        "dayplan": "your day plan"
    ]

    /// One manifest entry (spec §3.1) in words; an unknown shape stays as written.
    package static func permissionLine(_ permission: String) -> String {
        if let line = prefixedLine(permission) { return line }
        let parts = permission.split(separator: "@", maxSplits: 1).map(String.init)
        let scope = parts.count == 2 ? parts[1] : nil
        let capVerb = (parts.first ?? "").split(separator: ":", maxSplits: 1).map(String.init)
        guard capVerb.count == 2 else { return permission }
        let (cap, verb) = (capVerb[0], capVerb[1])
        return sourceLine(cap: cap, verb: verb, scope: scope)
            ?? localLine(cap: cap, verb: verb, scope: scope)
            ?? runtimeLine(cap: cap, verb: verb, scope: scope)
            ?? permission
    }

    /// `tool:`, `mcp:` and `shell:` entries.
    private static func prefixedLine(_ permission: String) -> String? {
        if permission.hasPrefix("tool:") {
            return "Use the tool " + permission.dropFirst("tool:".count)
        }
        if permission.hasPrefix("mcp:") {
            let rest = permission.dropFirst("mcp:".count)
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            return "Use \(rest[rest.index(after: slash)...]) from \(rest[..<slash]) (Quick Connection)"
        }
        if permission.hasPrefix("shell:") {
            var command = String(permission.dropFirst("shell:".count))
            if command.count >= 2, command.hasPrefix("\""), command.hasSuffix("\"") {
                command = String(command.dropFirst().dropLast())
            }
            return "Run the command " + command
        }
        return nil
    }

    /// A synced source's read or write over one scope ("Read mail in work (Gmail)").
    private static func sourceLine(cap: String, verb: String, scope: String?) -> String? {
        guard let source = sources[cap], let scope else { return nil }
        let place = scope == "*" ? source.all : scope
        switch verb {
        case "read": return "Read \(source.noun) in \(place) (\(source.name))"
        case "write": return "\(source.write) \(place) (\(source.name))"
        default: return nil
        }
    }

    /// A local, unscoped read or write ("Read your targets").
    private static func localLine(cap: String, verb: String, scope: String?) -> String? {
        guard let noun = localNouns[cap], scope == nil else { return nil }
        switch verb {
        case "read": return "Read " + noun
        case "write": return "Change " + noun
        default: return nil
        }
    }

    /// The model, agent, ask and session capabilities.
    private static func runtimeLine(cap: String, verb: String, scope: String?) -> String? {
        switch (cap, verb, scope) {
        case ("llm", "light", nil): "Use the light model"
        case ("llm", "strong", nil): "Use the strong model"
        case ("agent", "run", nil): "Run the assistant as an agent"
        case ("ask", "owner", nil): "Ask you questions"
        case ("session", "start", nil): "Start agent sessions"
        case ("session", "start", "claude"): "Start Claude Code sessions"
        case ("session", "start", "codex"): "Start Codex sessions"
        default: nil
        }
    }

    package static func outputLine(_ output: String) -> String {
        switch output {
        case "inbox": "Put cards in your Inbox"
        case "report": "Add reports to this automation"
        case "briefing": "Add items to your briefing"
        case "target": "Create targets"
        case "slack": "Send Slack messages"
        default: "Write \(output)"
        }
    }

    package static let workbenchChangeInWordsHelp =
        "Workbench automations are changed in words from the workbench (coming in a later update)"

    /// Why **Change in words** is off for `automation`; nil when it is on.
    /// A workbench recipe cannot be saved by the assistant yet
    /// (`save_automation` refuses `workbench_id`, R-P3-5, until P5 part 2), so
    /// its chat would only end in a refusal — gated like the edit form. The
    /// provider's own reason (`providerHelp`, ollama) applies to every recipe.
    package static func changeInWordsHelp(for automation: Automation, providerHelp: String?) -> String? {
        if automation.scope == .workbench { return workbenchChangeInWordsHelp }
        return providerHelp
    }

    /// Run now and Dry run for the card. Run now follows Go's `Runnable()`
    /// (the CLI refuses anything else, `notRunnableReason`); Dry run is the
    /// owner's click and works for an unconfirmed or disabled recipe (ask #271).
    package static func buttons(for automation: Automation) -> Buttons {
        let toggle = automation.enabled ? "Disable" : "Enable"
        let off = { (help: String) in ButtonState(enabled: false, help: help) }
        let on = ButtonState(enabled: true, help: nil)
        if !automation.parseError.isEmpty {
            let help = "The recipe can't be read"
            return Buttons(runNow: off(help), dryRun: off(help), toggleLabel: toggle)
        }
        if automation.removedAt != nil {
            let help = "The recipe file was removed"
            return Buttons(runNow: off(help), dryRun: off(help), toggleLabel: toggle)
        }
        if automation.needsConfirmation {
            return Buttons(runNow: off("Needs your confirmation"), dryRun: on, toggleLabel: toggle)
        }
        if !automation.enabled {
            return Buttons(runNow: off("Disabled — enable it from ⋯"), dryRun: on, toggleLabel: toggle)
        }
        return Buttons(runNow: automation.isRunnable ? on : off("Needs your confirmation"), dryRun: on,
                       toggleLabel: toggle)
    }

    // MARK: - History

    /// A failed run (an interrupted one is `failed` with `error_kind='interrupted'`)
    /// can be repeated with `automations run <id> --rerun-of <run>`; a dry run is not.
    package static func canRerun(_ run: AutomationRun) -> Bool {
        run.status == .failed && !run.isDryRun
    }

    /// What started a run, for its History row.
    package static func triggerLabel(_ run: AutomationRun) -> String {
        if let rerunOf = run.rerunOf { return "Rerun of #\(rerunOf)" }
        switch run.trigger {
        case "schedule": return "Scheduled"
        case "catch_up": return "Caught up after sleep"
        case "button": return "Button"
        case "event": return "Event"
        case "manual": return "Run now"
        case "dry_run": return "Dry run"
        default: return run.trigger
        }
    }

    package static func waitingCaption(_ reason: String) -> String {
        switch reason {
        case "approval": "Waiting for your approval"
        case "ask": "Waiting for your answer"
        case "app": "Waiting for the app"
        case "session": "Waiting for a session"
        default: "Waiting"
        }
    }

    /// "Succeeded · Today 09:00 · 41 s"; a waiting run shows its reason.
    package static func runHeadline(_ run: AutomationRun, now: Date, calendar: Calendar = .current) -> String {
        var parts = [run.status == .waiting ? waitingCaption(run.waitingReason) : statusText(run.status)]
        if let at = run.startedAt ?? run.queuedAt {
            parts.append(dayAndTime(at, now: now, calendar: calendar))
        }
        if let ms = durationMS(run) {
            parts.append(durationText(ms: ms))
        }
        return parts.joined(separator: " · ")
    }

    private static func durationMS(_ run: AutomationRun) -> Int64? {
        if run.activeMS > 0 { return run.activeMS }
        guard !run.status.isActive, let start = run.startedAt, let end = run.finishedAt else { return nil }
        return Int64(end.timeIntervalSince(start) * 1000)
    }

    private static let weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    private static func dayAndTime(_ date: Date, now: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: date)
        let time = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
        let startOfToday = calendar.startOfDay(for: now)
        let startOfDay = calendar.startOfDay(for: date)
        let daysAgo = calendar.dateComponents([.day], from: startOfDay, to: startOfToday).day ?? 0
        let day: String
        switch daysAgo {
        case 0: day = "Today"
        case 1: day = "Yesterday"
        case 2...6: day = weekdayNames[((c.weekday ?? 1) - 1) % 7]
        default: day = "\(monthNames[((c.month ?? 1) - 1) % 12]) \(c.day ?? 1)"
        }
        return "\(day) \(time)"
    }

    /// "✓ list_emails — 23 messages", "✗ get_email — timeout".
    package static func stepLine(_ step: AutomationRunStep) -> String {
        var fact = !step.error.isEmpty ? firstLine(step.error) : step.resultSummary
        if fact.isEmpty, step.status == "denied", !step.permission.isEmpty {
            fact = "needs " + step.permission
        }
        if fact.isEmpty, step.kind == "llm", step.inputTokens + step.outputTokens > 0 {
            fact = tokensText(step.inputTokens + step.outputTokens, estimated: step.tokensEstimated)
        }
        let head = "\(stepIcon(step.status)) \(stepLabel(step))"
        return fact.isEmpty ? head : "\(head) — \(fact)"
    }

    private static func stepIcon(_ status: String) -> String {
        switch status {
        case "ok", "applied": "✓"
        case "error", "failed", "rejected": "✗"
        case "denied": "⊘"
        case "proposed": "→"
        case "waiting": "…"
        default: "○"
        }
    }

    private static func stepLabel(_ step: AutomationRunStep) -> String {
        switch step.kind {
        case "tool", "mcp":
            return step.name.isEmpty ? step.kind : step.name
        case "llm":
            return step.name.isEmpty ? "llm" : "llm (\(step.name))"
        case "output":
            return step.name == "inbox" ? "inbox card" : (step.name.isEmpty ? "output" : step.name)
        default:
            return step.name.isEmpty ? step.kind : "\(step.kind) \(step.name)"
        }
    }

    // MARK: - Numbers

    /// "1,180 tokens"; "≈1,180 tokens" when the count is an estimate.
    package static func tokensText(_ tokens: Int64, estimated: Bool) -> String {
        (estimated ? "≈" : "") + number(tokens) + " tokens"
    }

    /// The backend's reported cost — display only (D4); nil when none was reported.
    package static func reportedCostText(_ usd: Double?) -> String? {
        guard let usd else { return nil }
        return String(format: "$%.2f reported", usd)
    }

    /// "950", "3.2k", "3k", "1.3M".
    package static func compactTokens(_ tokens: Int64) -> String {
        func short(_ value: Double, _ suffix: String) -> String {
            let rounded = (value * 10).rounded() / 10
            return rounded == rounded.rounded() ? "\(Int64(rounded))\(suffix)" : String(format: "%.1f%@", rounded, suffix)
        }
        if tokens < 1000 { return "\(tokens)" }
        if tokens < 1_000_000 { return short(Double(tokens) / 1000, "k") }
        return short(Double(tokens) / 1_000_000, "M")
    }

    /// "41 s", "2 min", "1 h 5 min".
    package static func durationText(ms: Int64) -> String {
        let seconds = max(ms, 0) / 1000
        if seconds < 60 { return "\(seconds) s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) min"
    }

    /// "40 s", "12 min", "14 h", "3 d".
    package static func relative(_ seconds: TimeInterval) -> String {
        let s = max(Int(seconds), 0)
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        if s < 48 * 3600 { return "\(Int((Double(s) / 3600).rounded())) h" }
        return "\(Int((Double(s) / 86400).rounded())) d"
    }

    package static func number(_ value: Int64) -> String {
        decimal.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static func firstLine(_ text: String) -> String {
        String(text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first ?? "")
    }
}
