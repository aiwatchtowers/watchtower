import CryptoKit
import Foundation

/// The draft column beside the editor chat and the form (spec A4): what the
/// owner is about to save. Every box comes from `validate` of the exact bytes
/// on screen (`validated`, its `content_hash` matching `text`): It may, Sends
/// and Changed from the manifest keys, When, Each run and Missed and
/// Concurrency from `fields`. Only then does `showsAllFields` hold, and only
/// then may a save or confirm be offered (AUTO-06). A dry run is shown only
/// when the chat's newest draft is this very text.
package struct AutomationDraftColumnModel: Equatable, Sendable {
    package enum Status: Equatable, Sendable {
        /// Validation is running, or has not run on these bytes yet.
        case checking
        case ready
        case invalid
    }

    /// The mark on a permission the confirmation does not cover yet.
    package static let newMark = "New since you confirmed"
    /// The dry-run box when the chat's newest dry run is of other bytes.
    package static let notDryRunNote = "Not dry-run since the last change."
    /// The boxes while these bytes are being checked.
    package static let checkingLine = "Checking…"
    /// The boxes when the check of these bytes cannot show every field (a
    /// parse error, or a CLI without `fields`).
    package static let unreadableLine = "Can't read this from the recipe"

    package let when: String
    package let whenDetail: String?
    /// The permissions, each marked new when the confirmation does not cover
    /// it; none is marked for a recipe never confirmed (new, or no
    /// `confirmedText`).
    package let mayDo: [AutomationCardPresentation.PermissionLine]
    /// One line per output.
    package let sends: [String]
    package let eachRun: String
    package let missedAndConcurrency: String
    /// The hashed fields that differ from the confirmed recipe; empty for a
    /// new recipe (no Changed box).
    package let changes: [String]
    package let dryRunLines: [String]
    package let dryRunNote: String?
    package let sessions: [AutomationSessionPrompt]
    package let errors: [String]
    package let pausedGrants: [String]
    package let llmWarning: String?
    /// The confirmed text against this one (an edit); nil for a new recipe.
    package let recipeDiff: OwnerAskSnapshotDiff?
    package let recipeText: String
    package let isNew: Bool
    package let status: Status
    /// `validated` is of these bytes, valid, and carries every hashed field:
    /// the boxes show them all, and a save or confirm may be offered.
    package let showsAllFields: Bool
    /// What the boxes say instead of their values when `showsAllFields` is
    /// false (`checkingLine` or `unreadableLine`); nil when they show values.
    package let placeholder: String?

    package init(
        text: String,
        validated: AutomationsCLI.ValidateResult?,
        isChecking: Bool,
        newestChatEntry: AutomationDraftEntry?,
        confirmedText: String?,
        isNew: Bool,
        plan: AutomationSavePlan?,
        checkFailed: Bool = false
    ) {
        recipeText = text
        self.isNew = isNew
        // A result for other bytes says nothing about these.
        let current = validated.flatMap { $0.contentHash == Self.contentHash(text) ? $0 : nil }
        // `checkFailed`: the draft's newest check failed without a result for
        // these bytes (the CLI did not answer) — not "checking": the boxes
        // say they can't read it.
        status = if isChecking || (current == nil && !checkFailed) { .checking } else if current?.ok == true {
            .ready
        } else {
            .invalid
        }
        errors = status == .invalid ? current?.errors ?? [] : []
        let shown = status == .ready ? current.flatMap { $0.showsAllFields ? $0 : nil } : nil
        showsAllFields = shown != nil
        placeholder = shown != nil ? nil : status == .checking ? Self.checkingLine : Self.unreadableLine

        if let shown, let fields = shown.fields, let budget = fields.budget {
            (when, whenDetail) = Self.when(fields)
            eachRun = SaveAutomationCardModel.budget(tokens: budget.tokens, minutes: budget.minutes)
            missedAndConcurrency = Self.missedAndConcurrency(fields)
            let permissions = shown.permissions
            // The mark is relative to a confirmed text: a recipe never
            // confirmed has none, so no line carries it.
            mayDo = AutomationCardPresentation.permissionLines(
                permissions: permissions, outputs: [], widening: isNew || confirmedText == nil ? [] : shown.widening
            )
            sends = shown.outputs.map(AutomationCardPresentation.outputLine)
            changes = isNew ? [] : AutomationChangePresentation.lines(
                shown.changes, known: shown.changesKnown, confirmedBefore: confirmedText != nil
            )
        } else {
            let line = placeholder ?? Self.unreadableLine
            (when, whenDetail) = (line, nil)
            eachRun = line
            missedAndConcurrency = line
            mayDo = []
            sends = []
            changes = []
        }
        recipeDiff = isNew ? nil : confirmedText.map { OwnerAskSnapshotDiff(previous: $0, current: text) }

        if let entry = newestChatEntry, entry.recipeText == text {
            let draft = AutomationDraftPanelModel(entry: entry)
            dryRunLines = draft.dryRunLines
            dryRunNote = draft.dryRunNote
            sessions = draft.sessions
        } else {
            dryRunLines = []
            dryRunNote = Self.notDryRunNote
            sessions = []
        }

        pausedGrants = plan?.pausedGrants ?? []
        llmWarning = plan.flatMap {
            AutomationLLMWarning.line(feedsSourcesToLLM: $0.validated.feedsSourcesToLLM, tools: $0.llmWarningTools)
        }
    }

    /// Go's `ContentHash`: the hex sha256 of the recipe's bytes.
    package static func contentHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// `fields.trigger` in the Draft panel's words; a line of a shape this
    /// does not know is shown as Go wrote it.
    private static func when(_ fields: AutomationsCLI.ValidateResult.Fields) -> (String, String?) {
        let line = fields.trigger
        if let expr = line.dropPrefix("schedule: ") {
            return (CronText.sentence(expr), AutomationDraftPanelModel.missedDetail(skips: fields.missed == "skip"))
        }
        if let event = line.dropPrefix("event: ") {
            let parts = event.components(separatedBy: " where ")
            let type = parts[0]
            let json = (try? JSONSerialization.data(withJSONObject: ["event": ["type": type]], options: [.sortedKeys]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let filter = parts.count > 1 ? "Where " + parts.dropFirst().joined(separator: " where ") : nil
            return (AutomationTriggerText.describe(kind: "event", specJSON: json), filter)
        }
        switch line {
        case "button": return ("Button", nil)
        case "button (asks before running)": return ("Button, asks before running", nil)
        case "manual": return ("Only when you run it", nil)
        default: return (line, nil)
        }
    }

    /// Every run's limits: a missed time, then how many run at once.
    private static func missedAndConcurrency(_ fields: AutomationsCLI.ValidateResult.Fields) -> String {
        let concurrency = Int(fields.concurrency) ?? 1
        let runs = concurrency <= 1 ? "One run at a time" : "Up to \(concurrency) runs at a time"
        let missed = fields.missed == "skip" ? "Missed while asleep: skip" : "Missed while asleep: run once"
        return "\(missed) · \(runs)"
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
