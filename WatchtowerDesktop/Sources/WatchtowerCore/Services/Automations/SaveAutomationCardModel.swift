import Foundation

/// A `save_automation` proposal as its action card shows it (spec §11): the
/// file it writes, the trigger, the permissions with the widening ones marked
/// "+", the outputs, the budget, the missed-run policy and the concurrency
/// (every hashed field, D26), the assistant's dry-run summary (R-P3-4, the
/// model's own words, labelled as such) and the code the owner confirms: the
/// whole recipe for a new one, the diff against the saved file for an edit.
/// Built from the args `Normalize` pinned at propose
/// (`internal/automations/authoring/save.go`), never re-derived.
package struct SaveAutomationCardModel {
    package static let tool = "save_automation"
    package static let dryRunSummaryLabel = "Assistant's dry-run summary"
    /// Shown on a pending card of the editor chat whose text is not the
    /// newest draft the Draft panel shows (a display check only).
    package static let draftMismatchWarning = "This differs from the last draft shown. "
        + "Review the recipe below before you approve."

    package let title: String
    package let lines: [String]
    /// "Assistant's dry-run summary: …"; nil when the model sent none.
    package let dryRunSummary: String?
    /// The saved file → the proposed text; nil for a new recipe.
    package let diff: OwnerAskSnapshotDiff?
    /// The whole recipe text the save writes and confirms.
    package let recipeText: String
    /// The recipe disclosed in full on the card: the text for a new recipe
    /// (nothing to diff against), nil for an edit (the diff shows it).
    package let newRecipeText: String?
    /// What the editor says once this save is applied. Approving the card is
    /// the confirmation (`Execute` writes, indexes and confirms — spec §11);
    /// it never enables: a new recipe is indexed off, an edit keeps its state.
    package let appliedNote: String

    /// The editor chat has a draft, but none of its cached dry runs has this
    /// card's exact text.
    package static let unmatchedSessionsLine = "No dry run of this exact text — the sessions are not shown."

    /// Under a matched block whose dry run ended before the script did.
    package static let stoppedEarlyLine = "The dry run stopped early — later sessions are not listed."

    /// What the card says about the sessions the recipe starts.
    package enum DraftSessions: Equatable, Sendable {
        /// The main chat (no Draft panel), or a decided card with no match.
        case hidden
        /// A pending card: the editor has a draft, but no dry run of this text.
        case unmatched
        /// The dry run of this exact text (no sessions: it starts none).
        case shown(AutomationDryRunSessions)
    }

    /// The workbench the recipe is saved into; nil for a personal one.
    package let workbenchID: Int64?

    package static let appliedNewNote = "Saved and confirmed. It's off until you turn it on in Automations."
    package static let appliedEditNote = "Saved and confirmed. Whether it runs is still set by its switch in Automations."

    private struct Args: Decodable {
        var name = ""
        var slug = ""
        var triggerKind = ""
        var permissions: [String] = []
        var outputs: [String] = []
        var widening: [String] = []
        var budgetTokens = 0
        var budgetMinutes = 0
        var missed = ""
        var concurrency = 0
        var path = ""
        var isNew = false
        var recipeText = ""
        var previousRecipeText = ""
        var dryRunSummary = ""
        var workbenchID: Int64?

        enum CodingKeys: String, CodingKey {
            case name, slug, permissions, outputs, widening, missed, concurrency, path
            case triggerKind = "trigger_kind", budgetTokens = "budget_tokens", budgetMinutes = "budget_minutes"
            case isNew = "is_new", recipeText = "recipe_text", previousRecipeText = "previous_recipe_text"
            case dryRunSummary = "dry_run_summary", workbenchID = "workbench_id"
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
            triggerKind = try c.decodeIfPresent(String.self, forKey: .triggerKind) ?? ""
            permissions = try c.decodeIfPresent([String].self, forKey: .permissions) ?? []
            outputs = try c.decodeIfPresent([String].self, forKey: .outputs) ?? []
            widening = try c.decodeIfPresent([String].self, forKey: .widening) ?? []
            budgetTokens = try c.decodeIfPresent(Int.self, forKey: .budgetTokens) ?? 0
            budgetMinutes = try c.decodeIfPresent(Int.self, forKey: .budgetMinutes) ?? 0
            missed = try c.decodeIfPresent(String.self, forKey: .missed) ?? ""
            concurrency = try c.decodeIfPresent(Int.self, forKey: .concurrency) ?? 0
            path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
            isNew = try c.decodeIfPresent(Bool.self, forKey: .isNew) ?? false
            recipeText = try c.decodeIfPresent(String.self, forKey: .recipeText) ?? ""
            previousRecipeText = try c.decodeIfPresent(String.self, forKey: .previousRecipeText) ?? ""
            dryRunSummary = try c.decodeIfPresent(String.self, forKey: .dryRunSummary) ?? ""
            workbenchID = try c.decodeIfPresent(Int64.self, forKey: .workbenchID)
        }
    }

    package init(action: AgentAction) {
        let data = Data(action.argsJSON.utf8)
        let args = (try? JSONDecoder().decode(Args.self, from: data)) ?? Args()
        // trigger_spec is a JSON object in the args; the trigger text reads it as JSON text.
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let specJSON = object?["trigger_spec"]
            .flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        title = "Save automation \(args.name.isEmpty ? args.slug : args.name)"
        let widening = Set(args.widening)
        var lines: [String] = []
        let file = args.path.isEmpty ? "\(args.slug).md" : URL(fileURLWithPath: args.path).lastPathComponent
        lines.append("File: \(file)" + (args.isNew ? " (new)" : " (replaces the saved one)"))
        lines.append("When: " + AutomationTriggerText.sentence(kind: args.triggerKind, specJSON: specJSON))
        lines += args.permissions.map { permission in
            let line = "\(permission) — \(AutomationCardPresentation.permissionLine(permission))"
            return widening.contains(permission) ? "+ \(line)" : line
        }
        lines += args.outputs.map { "output: \($0) — \(AutomationCardPresentation.outputLine($0))" }
        lines.append("Budget: \(Self.budget(tokens: args.budgetTokens, minutes: args.budgetMinutes))")
        if !args.missed.isEmpty {
            lines.append("Missed: " + (args.missed == "skip" ? "skip a time the Mac was asleep"
                                                             : "run once when the Mac wakes"))
        }
        if args.concurrency > 0 {
            lines.append("Concurrency: " + (args.concurrency == 1 ? "one run at a time"
                                                                  : "up to \(args.concurrency) runs at a time"))
        }
        self.lines = lines
        let summary = args.dryRunSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        dryRunSummary = summary.isEmpty ? nil : "\(Self.dryRunSummaryLabel): \(summary)"
        diff = args.isNew ? nil : OwnerAskSnapshotDiff(previous: args.previousRecipeText, current: args.recipeText)
        recipeText = args.recipeText
        newRecipeText = args.isNew ? args.recipeText : nil
        appliedNote = args.isNew ? Self.appliedNewNote : Self.appliedEditNote
        workbenchID = args.workbenchID
    }

    /// "For: Personal" / "For: workbench <name>" (`#<id>` when the name is
    /// not known).
    package func scopeLine(workbenchName: (Int64) -> String?) -> String {
        guard let workbenchID else { return "For: Personal" }
        return "For: workbench \(workbenchName(workbenchID) ?? "#\(workbenchID)")"
    }

    /// The sessions block of the card: from the cached dry run whose recipe
    /// text equals this card's (`AutomationDraftPanelModel.dryRunSessions`),
    /// shown only where a Draft panel exists (`latestDraftText` non-nil);
    /// the unmatched line only on a pending card, like the mismatch warning.
    package func draftSessions(
        latestDraftText: String?,
        isPending: Bool,
        dryRunSessions: [String: AutomationDryRunSessions]
    ) -> DraftSessions {
        guard latestDraftText != nil else { return .hidden }
        if let matched = dryRunSessions[recipeText] { return .shown(matched) }
        return isPending ? .unmatched : .hidden
    }

    /// Whether the text this card confirms differs from `latestDraftText`, the
    /// newest draft the editor chat's Draft panel shows (nil: no draft there,
    /// as on the main chat — nothing to compare).
    package func differsFromDraft(_ latestDraftText: String?) -> Bool {
        guard let latestDraftText else { return false }
        return latestDraftText != recipeText
    }

    /// "Show the whole recipe (12 lines)".
    package static func recipeDisclosureTitle(_ text: String) -> String {
        let count = text.split(separator: "\n", omittingEmptySubsequences: false).count - (text.hasSuffix("\n") ? 1 : 0)
        return "Show the whole recipe (\(count) \(count == 1 ? "line" : "lines"))"
    }

    /// "40,000 tokens · 5 min".
    package static func budget(tokens: Int, minutes: Int) -> String {
        "\(AutomationCardPresentation.number(Int64(tokens))) tokens · \(minutes) min"
    }
}
