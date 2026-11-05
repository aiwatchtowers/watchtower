import CryptoKit
import Foundation

/// The draft column beside the editor chat and the form (spec A4): what the
/// owner is about to save. Every box comes from `validate` of the exact bytes
/// on screen (`validated`, its `content_hash` matching `text`): It may, Sends
/// and Changed from the manifest keys, When, Each run, Missed and
/// Concurrency and Inbox cards from `fields`. Only then does `showsAllFields` hold, and only
/// then may a save or confirm be offered (AUTO-06). A dry run is shown only
/// when the chat's newest draft is this very text.
package struct AutomationDraftColumnModel: Equatable, Sendable {
    /// What `show --json` says of the saved recipe, passed only when the
    /// column shows its indexed text unchanged (a confirm of the recipe as
    /// it is on disk), so none of it is put beside the owner's own edit.
    package struct Saved: Equatable, Sendable {
        package let changedBy: String
        package let changedAt: Date?
        package let needsConfirmation: Bool
        /// `llm_auto_writes`: External tools with an auto grant, active or
        /// paused, of a recipe that feeds its sources to `llm()` (#559).
        package let llmAutoWrites: [String]

        package init(changedBy: String, changedAt: Date?, needsConfirmation: Bool, llmAutoWrites: [String]) {
            self.changedBy = changedBy
            self.changedAt = changedAt
            self.needsConfirmation = needsConfirmation
            self.llmAutoWrites = llmAutoWrites
        }
    }

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
    /// `fields.artifacts` in words: a new card each run, or one card per
    /// key kept current; nil for a recipe that makes no Inbox card (feed is
    /// then the hash's absent key) and while the boxes show no values.
    package let artifacts: String?
    /// `adds_llm` of these bytes: the footer's AI-step line. False while
    /// the boxes show no values.
    package let addsLLM: Bool
    /// The hashed fields that differ from the confirmed recipe; empty for a
    /// new recipe (no Changed box).
    package let changes: [String]
    /// Who made the changes a confirm approves; nil unless `saved` needs
    /// confirmation and the Changed box lists something.
    package let authorLine: String?
    package let dryRunLines: [String]
    package let dryRunNote: String?
    package let sessions: [AutomationSessionPrompt]
    package let errors: [String]
    package let pausedGrants: [String]
    /// The #559 warning over the plan's paused grants and the saved
    /// recipe's `llmAutoWrites`, when these bytes feed sources to `llm()`.
    package let llmWarning: String?
    /// Board #560: with a `shell:` entry, confirming covers the command text
    /// only (`AutomationCardPresentation.shellWarning`); nil without one or
    /// while the boxes show no values.
    package let shellWarning: String?
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
    /// Every hashed field a press confirms, for the pinned row
    /// (`confirmationRow(on:)`): the changed fields of an edit with a known
    /// diff (`itemsAreChanges`), else each field with its value. Empty while
    /// the boxes show no values (every button is off then).
    package let hashedItems: [AutomationSaveConfirmationRow.Item]
    /// `hashedItems` are the Changed box's lines, shown in full on What it
    /// collects.
    package let itemsAreChanges: Bool

    /// The editor's pinned row on `step` (AUTO-06, ask #486): the hashed
    /// fields a press there confirms that the step does not show; nil when
    /// the step shows them all, or there is nothing to confirm.
    package func confirmationRow(on step: AutomationEditorStep) -> AutomationSaveConfirmationRow? {
        let shown = shownFields(on: step)
        let items = hashedItems.filter { item in item.field.map { !shown.contains($0) } ?? true }
        guard !items.isEmpty else { return nil }
        return AutomationSaveConfirmationRow(
            title: itemsAreChanges ? AutomationSaveConfirmationRow.changedTitle
                : AutomationSaveConfirmationRow.valuesTitle,
            items: items
        )
    }

    /// The hashed fields on screen at a press on `step`: the step's boxes
    /// and its pinned row. AUTO-06 holds when this covers every field a
    /// press confirms.
    package func visibleFields(on step: AutomationEditorStep) -> Set<AutomationHashedField> {
        shownFields(on: step).union((confirmationRow(on: step)?.items ?? []).compactMap(\.field))
    }

    /// What the step's boxes show: What it collects with a Changed box
    /// shows every changed field; the Inbox cards box only when it is drawn.
    private func shownFields(on step: AutomationEditorStep) -> Set<AutomationHashedField> {
        if step == .collects, itemsAreChanges { return Set(AutomationHashedField.allCases) }
        var shown = step.shownFields
        if artifacts == nil { shown.remove(.artifacts) }
        return shown
    }

    package init(
        text: String,
        validated: AutomationsCLI.ValidateResult?,
        isChecking: Bool,
        newestChatEntry: AutomationDraftEntry?,
        confirmedText: String?,
        isNew: Bool,
        plan: AutomationSavePlan?,
        checkFailed: Bool = false,
        saved: Saved? = nil,
        now: Date = Date(),
        workbenchName: (Int64) -> String? = { _ in nil }
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
            artifacts = shown.outputs.contains("inbox") || fields.artifacts == "living"
                ? Self.artifacts(fields) : nil
            addsLLM = shown.addsLLM
            let permissions = shown.permissions
            // The mark is relative to a confirmed text: a recipe never
            // confirmed has none, so no line carries it.
            mayDo = AutomationCardPresentation.permissionLines(
                permissions: permissions, outputs: [], widening: isNew || confirmedText == nil ? [] : shown.widening
            )
            sends = shown.outputs.map(AutomationCardPresentation.outputLine)
            changes = isNew ? [] : AutomationChangePresentation.lines(
                shown.changes, known: shown.changesKnown, confirmedBefore: confirmedText != nil,
                workbenchName: workbenchName
            )
            shellWarning = AutomationCardPresentation.shellWarning(permissions: permissions)
        } else {
            let line = placeholder ?? Self.unreadableLine
            (when, whenDetail) = (line, nil)
            eachRun = line
            missedAndConcurrency = line
            artifacts = nil
            addsLLM = false
            mayDo = []
            sends = []
            changes = []
            shellWarning = nil
        }
        if let shown, let fields = shown.fields {
            itemsAreChanges = !isNew && confirmedText != nil && shown.changesKnown
            hashedItems = itemsAreChanges
                ? shown.changes.map { change in
                    AutomationSaveConfirmationRow.Item(
                        field: AutomationHashedField(changeField: change.field),
                        text: AutomationChangePresentation.line(change, workbenchName: workbenchName)
                    )
                }
                : Self.valueItems(shown, fields: fields, when: when, eachRun: eachRun, mayDo: mayDo, sends: sends,
                                  artifacts: artifacts, workbenchName: workbenchName)
        } else {
            itemsAreChanges = false
            hashedItems = []
        }
        if let saved, saved.needsConfirmation, !changes.isEmpty {
            authorLine = AutomationChangePresentation.authorLine(changedBy: saved.changedBy,
                                                                 changedAt: saved.changedAt, now: now)
        } else {
            authorLine = nil
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
        let llmTools = Set(plan?.llmWarningTools ?? []).union(saved?.llmAutoWrites ?? []).sorted()
        let feeds = shown?.feedsSourcesToLLM ?? plan?.validated.feedsSourcesToLLM ?? false
        llmWarning = AutomationLLMWarning.line(feedsSourcesToLLM: feeds, tools: llmTools)
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

    /// The Inbox cards' lifecycle; an older CLI's "" is feed, the only one
    /// it knows.
    private static func artifacts(_ fields: AutomationsCLI.ValidateResult.Fields) -> String {
        fields.artifacts == "living" ? livingLine : feedLine
    }

    package static let feedLine = "A new card each run"
    package static let livingLine = "One card per key, kept current"

    /// Each hashed field with its value, in the boxes' words, for a recipe
    /// with nothing to compare (new, never confirmed, unknown diff).
    private static func valueItems(
        _ shown: AutomationsCLI.ValidateResult,
        fields: AutomationsCLI.ValidateResult.Fields,
        when: String,
        eachRun: String,
        mayDo: [AutomationCardPresentation.PermissionLine],
        sends: [String],
        artifacts: String?,
        workbenchName: (Int64) -> String?
    ) -> [AutomationSaveConfirmationRow.Item] {
        typealias Item = AutomationSaveConfirmationRow.Item
        let concurrency = Int(fields.concurrency) ?? 1
        var items = [
            Item(field: .scope, text: "Scope: "
                + AutomationChangePresentation.scopeWords(shown.scope, workbenchName: workbenchName)),
            Item(field: .permissions, text: "It may: " + (mayDo.isEmpty ? "Nothing beyond its own state"
                    : mayDo.map(\.text).joined(separator: "; "))),
            Item(field: .outputs, text: "Sends: " + (sends.isEmpty ? "Nothing" : sends.joined(separator: "; "))),
            Item(field: .script, text: scriptLine),
            Item(field: .trigger, text: "When: " + when),
            Item(field: .missed, text: fields.missed == "skip" ? "Missed while asleep: skip"
                : "Missed while asleep: run once"),
            Item(field: .budget, text: "Each run: " + eachRun),
            Item(field: .concurrency, text: concurrency <= 1 ? "One run at a time"
                : "Up to \(concurrency) runs at a time")
        ]
        if let artifacts { items.append(Item(field: .artifacts, text: "Inbox cards: " + artifacts)) }
        return items
    }

    /// The pinned row's script line: the text itself is under What it
    /// collects (**Show recipe**).
    package static let scriptLine = "Script: under What it collects → Show recipe"

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
