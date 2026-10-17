import Foundation

/// What a Save from the edit form needs from the owner (spec §3.3, §6.4,
/// D26). `validated` is `validate --against` of the exact bytes the save will
/// write; the save confirms that `approvalHash` and nothing else. A changed
/// approval hash pauses the auto grants active under the current one, and
/// none is kept unless the owner checks its box (AUTO-03): `keepAuto` starts
/// empty.
package struct AutomationSavePlan: Equatable, Sendable {
    package let validated: AutomationsCLI.ValidateResult
    package let wasConfirmed: Bool
    /// Tools whose auto grant the save pauses, sorted.
    package let pausedGrants: [String]
    /// The paused grants of External tools when the new text feeds its
    /// sources to `llm()`: the sheet's #559 warning (`AutomationLLMWarning`).
    package let llmWarningTools: [String]
    /// The paused grants the owner chose to keep: `auto … on --hash <new>` after the save.
    package var keepAuto: Set<String> = []
    /// The current approval hash the plan was measured against.
    package let currentApprovalHash: String

    /// Whether the Save sheet is shown; otherwise the Save click saves and
    /// re-confirms in the same gesture. Since D26 a trigger, missed-policy,
    /// budget or concurrency edit changes the hash like a script edit; only
    /// name, description, a button's label and `pause_timeout_hours` keep it.
    package var needsSheet: Bool {
        !validated.widening.isEmpty || !pausedGrants.isEmpty || !wasConfirmed
            || validated.approvalHash != currentApprovalHash
    }

    package static func make(
        validated: AutomationsCLI.ValidateResult, current: AutomationDetail, grants: [AutomationToolGrant]
    ) -> Self {
        let hashChanged = validated.approvalHash != current.approvalHash
        let paused = hashChanged
            ? grants.filter { $0.isActive(approvalHash: current.approvalHash) }.map(\.tool).sorted()
            : []
        let external = Set(current.autoTools.filter(\.external).map(\.tool))
        return Self(
            validated: validated,
            wasConfirmed: !current.confirmedHash.isEmpty && current.confirmedHash == current.approvalHash,
            pausedGrants: paused,
            llmWarningTools: validated.feedsSourcesToLLM ? paused.filter(external.contains) : [],
            currentApprovalHash: current.approvalHash
        )
    }
}

/// The #559 warning: a recipe that feeds its sources to `llm()` with auto
/// on for a tool that writes outside Watchtower can send model text written
/// over other people's messages without a card. Shown by the confirmation
/// sheet (`llm_auto_writes`), the edit form's Auto toggles (External
/// `auto_tools`) and the Save sheet's "Keep auto" boxes; Go's
/// `llmAutoWarning` says the same.
package enum AutomationLLMWarning {
    /// The warning, or nil when the recipe does not feed its sources to
    /// `llm()` or no tool is named.
    package static func line(feedsSourcesToLLM: Bool, tools: [String]) -> String? {
        guard feedsSourcesToLLM, !tools.isEmpty else { return nil }
        return "This recipe passes data from its sources to llm(). With auto on for "
            + tools.joined(separator: ", ")
            + ", text the model writes from other people's messages can be sent without asking you."
    }
}

/// The confirmation sheet's **Changed** block and author line (spec §12.2,
/// D26), from `show --json`'s `changes` (old/new always strings: the trigger
/// as its spec JSON, numbers in decimal, lists as JSON arrays, the script "").
package enum AutomationChangePresentation {
    package static let firstConfirmation = "First confirmation"
    package static let unknownChanges = "What changed is not known — review the whole recipe"

    /// One line per changed field, "<field> <old> → <new>" ("Script changed"
    /// for the script). A never-confirmed recipe has nothing to compare; an
    /// unknown diff says so rather than show an empty block.
    package static func lines(_ changes: [AutomationChange], known: Bool, confirmedBefore: Bool) -> [String] {
        guard confirmedBefore else { return [firstConfirmation] }
        guard known else { return [unknownChanges] }
        return changes.map(line)
    }

    /// "Changed by the assistant in the chat · 10 min ago" when an applied
    /// `save_automation` wrote the current version, else "Changed outside
    /// Watchtower · <age>".
    package static func authorLine(changedBy: String, changedAt: Date?, now: Date) -> String {
        let who = changedBy == "assistant" ? "Changed by the assistant in the chat" : "Changed outside Watchtower"
        guard let changedAt else { return who }
        return "\(who) · \(AutomationCardPresentation.relative(now.timeIntervalSince(changedAt))) ago"
    }

    private static func line(_ change: AutomationChange) -> String {
        switch change.field {
        case "script":
            return "Script changed"
        case "trigger":
            let label = [change.old, change.new].contains { $0.contains(#""schedule""#) } ? "Schedule" : "Runs"
            return "\(label) \(triggerWords(change.old)) → \(triggerWords(change.new))"
        case "missed":
            return "Missed while asleep \(missedWords(change.old)) → \(missedWords(change.new))"
        case "budget_tokens":
            return "Budget per run \(tokens(change.old)) → \(tokens(change.new))"
        case "budget_minutes":
            return "Budget per run \(minutes(change.old)) → \(minutes(change.new))"
        case "concurrency":
            return "Runs at a time \(change.old) → \(change.new)"
        case "outputs":
            return "Outputs \(listWords(change.old)) → \(listWords(change.new))"
        case "permissions":
            return "Permissions \(listWords(change.old)) → \(listWords(change.new))"
        case "scope":
            return "Scope \(change.old) → \(change.new)"
        default:
            return "\(change.field) \(change.old) → \(change.new)"
        }
    }

    /// The hashed trigger (spec JSON without a button's label) in words.
    private static func triggerWords(_ json: String) -> String {
        switch RecipeFrontmatter.trigger(kind: triggerKind(json), specJSON: json) {
        case let .button(_, confirm):
            return confirm ? "Button, asks before running" : "Button"
        case .schedule, .event, .manual:
            return AutomationTriggerText.describe(kind: triggerKind(json), specJSON: json)
        }
    }

    private static func triggerKind(_ json: String) -> String {
        let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        return ["schedule", "button", "event", "manual"].first { object[$0] != nil } ?? ""
    }

    private static func missedWords(_ value: String) -> String {
        value == "skip" ? "skip" : "run once"
    }

    private static func tokens(_ value: String) -> String {
        guard let n = Int64(value) else { return value }
        return AutomationCardPresentation.tokensText(n, estimated: false)
    }

    private static func minutes(_ value: String) -> String {
        value == "1" ? "1 minute" : "\(value) minutes"
    }

    private static func listWords(_ json: String) -> String {
        guard let items = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) else { return json }
        return items.isEmpty ? "none" : items.joined(separator: ", ")
    }
}
