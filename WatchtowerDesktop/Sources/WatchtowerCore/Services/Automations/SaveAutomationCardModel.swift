import Foundation

/// A `save_automation` proposal as its action card shows it (spec §11): the
/// trigger, the permissions with the widening ones marked "+", the outputs,
/// the budget, the assistant's dry-run summary (R-P3-4, the model's own
/// words, labelled as such) and, for an edit, the diff against the text the
/// save replaces. Built from the args `Normalize` pinned at propose
/// (`internal/automations/authoring/save.go`), never re-derived.
package struct SaveAutomationCardModel {
    package static let tool = "save_automation"
    package static let dryRunSummaryLabel = "Assistant's dry-run summary"

    package let title: String
    package let lines: [String]
    /// "Assistant's dry-run summary: …"; nil when the model sent none.
    package let dryRunSummary: String?
    /// The saved file → the proposed text; nil for a new recipe.
    package let diff: OwnerAskSnapshotDiff?

    private struct Args: Decodable {
        var name = ""
        var slug = ""
        var triggerKind = ""
        var permissions: [String] = []
        var outputs: [String] = []
        var widening: [String] = []
        var budgetTokens = 0
        var budgetMinutes = 0
        var isNew = false
        var recipeText = ""
        var previousRecipeText = ""
        var dryRunSummary = ""

        enum CodingKeys: String, CodingKey {
            case name, slug, permissions, outputs, widening
            case triggerKind = "trigger_kind", budgetTokens = "budget_tokens", budgetMinutes = "budget_minutes"
            case isNew = "is_new", recipeText = "recipe_text", previousRecipeText = "previous_recipe_text"
            case dryRunSummary = "dry_run_summary"
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
            isNew = try c.decodeIfPresent(Bool.self, forKey: .isNew) ?? false
            recipeText = try c.decodeIfPresent(String.self, forKey: .recipeText) ?? ""
            previousRecipeText = try c.decodeIfPresent(String.self, forKey: .previousRecipeText) ?? ""
            dryRunSummary = try c.decodeIfPresent(String.self, forKey: .dryRunSummary) ?? ""
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
        var lines = ["When: " + AutomationTriggerText.sentence(kind: args.triggerKind, specJSON: specJSON)]
        lines += args.permissions.map { permission in
            let line = "\(permission) — \(AutomationCardPresentation.permissionLine(permission))"
            return widening.contains(permission) ? "+ \(line)" : line
        }
        lines += args.outputs.map { "output: \($0) — \(AutomationCardPresentation.outputLine($0))" }
        lines.append("Budget: \(Self.budget(tokens: args.budgetTokens, minutes: args.budgetMinutes))")
        self.lines = lines
        let summary = args.dryRunSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        dryRunSummary = summary.isEmpty ? nil : "\(Self.dryRunSummaryLabel): \(summary)"
        diff = args.isNew ? nil : OwnerAskSnapshotDiff(previous: args.previousRecipeText, current: args.recipeText)
    }

    /// "40,000 tokens · 5 min".
    package static func budget(tokens: Int, minutes: Int) -> String {
        "\(AutomationCardPresentation.number(Int64(tokens))) tokens · \(minutes) min"
    }
}
