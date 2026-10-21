import Foundation

/// The draft column beside the editor chat and the form (spec A4): what the
/// owner is about to save. It may / Sends / Changed come from `validate` of
/// the exact bytes in the editor (`validated`), so what the column lists is
/// what the save confirms (AUTO-06); When, Each run and Missed and
/// Concurrency read the same text's frontmatter. A dry run is shown only when
/// the chat's newest draft is this very text.
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
    /// When the frontmatter cannot be read (the errors say why).
    package static let unreadableWhen = "Can't read the trigger"

    package let when: String
    package let whenDetail: String?
    /// The permissions, each marked new when the confirmation does not cover it.
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

    package init(
        text: String,
        validated: AutomationsCLI.ValidateResult?,
        isChecking: Bool,
        newestChatEntry: AutomationDraftEntry?,
        confirmedText: String?,
        isNew: Bool,
        plan: AutomationSavePlan?
    ) {
        recipeText = text
        self.isNew = isNew
        status = if isChecking || validated == nil { .checking } else if validated?.ok == true { .ready } else {
            .invalid
        }
        errors = validated.map { $0.ok ? [] : $0.errors } ?? []

        let frontmatter = RecipeFrontmatter.read(text)
        (when, whenDetail) = Self.when(frontmatter)
        eachRun = frontmatter.map {
            SaveAutomationCardModel.budget(tokens: $0.budgetTokens, minutes: $0.budgetMinutes)
        } ?? ""
        missedAndConcurrency = frontmatter.map(Self.missedAndConcurrency) ?? ""

        let permissions = validated?.permissions ?? []
        mayDo = AutomationCardPresentation.permissionLines(
            permissions: permissions, outputs: [], widening: isNew ? permissions : validated?.widening ?? []
        )
        sends = (validated?.outputs ?? []).map(AutomationCardPresentation.outputLine)
        changes = isNew ? [] : validated.map {
            AutomationChangePresentation.lines($0.changes, known: $0.changesKnown, confirmedBefore: confirmedText != nil)
        } ?? []
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

    /// The Draft panel's wording: the trigger as a sentence, and for a
    /// schedule what a missed time does.
    private static func when(_ f: RecipeFrontmatter?) -> (String, String?) {
        guard let f else { return (unreadableWhen, nil) }
        let (kind, spec): (String, [String: Any]) = switch f.trigger {
        case let .schedule(expr): ("schedule", ["schedule": expr])
        case let .button(label, _): ("button", ["button": ["label": label]])
        case let .event(type, filter): ("event", ["event": ["type": type, "where": filter]])
        case .manual: ("manual", ["manual": true])
        }
        let json = (try? JSONSerialization.data(withJSONObject: spec, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let sentence = AutomationTriggerText.sentence(kind: kind, specJSON: json)
        guard kind == "schedule" else { return (sentence, nil) }
        return (sentence, f.missed == "skip" ? "Your local time · if the Mac was asleep, skips that time"
                                             : "Your local time · if the Mac was asleep, runs once when it wakes")
    }

    private static func missedAndConcurrency(_ f: RecipeFrontmatter) -> String {
        let runs = f.concurrency <= 1 ? "One run at a time" : "Up to \(f.concurrency) runs at a time"
        guard case .schedule = f.trigger else { return runs }
        let missed = f.missed == "skip" ? "Missed while asleep: skip" : "Missed while asleep: run once"
        return "\(missed) · \(runs)"
    }
}
