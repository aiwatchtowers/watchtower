import Foundation

/// One line of the editor's draft cache: `draft_automation` on the
/// `automation_editor` surface appends `{recipe_text, result, at}` to
/// `<workspace>/automation-drafts/<conversation id>.jsonl` and keeps the last
/// five (`internal/automations/authoring/draftcache.go`). A UI cache of the
/// tool's own result, not a store of record. Go writes every key (no
/// `omitempty`), so the synthesized decoders need no defaults.
package struct AutomationDraftEntry: Decodable, Equatable, Sendable {
    package struct Manifest: Decodable, Equatable, Sendable {
        package var name = ""
        package var slug = ""
        package var triggerKind = ""
        /// Short trigger text: a cron, a button label, an event type or "manual".
        package var trigger = ""
        package var permissions: [String] = []
        package var outputs: [String] = []
        package var budgetTokens = 0
        package var budgetMinutes = 0

        enum CodingKeys: String, CodingKey {
            case name, slug, trigger, permissions, outputs
            case triggerKind = "trigger_kind", budgetTokens = "budget_tokens", budgetMinutes = "budget_minutes"
        }
    }

    package struct Step: Decodable, Equatable, Sendable {
        package var seq = 0
        package var kind = ""
        package var name = ""
        package var status = ""
        package var args = ""
        package var result = ""
        package var permission = ""
        package var error = ""
        package var tokens: Int64 = 0
    }

    package struct DryRun: Decodable, Equatable, Sendable {
        package var steps: [Step] = []
        package var tokens: Int64 = 0
        package var status = ""
        package var error = ""
    }

    package struct Result: Decodable, Equatable, Sendable {
        package var ok = false
        package var errors: [String] = []
        package var manifest = Manifest()
        package var dryRun: DryRun?

        enum CodingKeys: String, CodingKey {
            case ok, errors, manifest, dryRun = "dry_run"
        }
    }

    package let recipeText: String
    package let result: Result

    enum CodingKeys: String, CodingKey {
        case recipeText = "recipe_text", result
    }

    /// `<workspace>/automation-drafts/<conversation id>.jsonl`; the workspace
    /// is the directory holding the database (Go `cfg.WorkspaceDir()`).
    package static func cacheURL(databasePath: String, conversationID: Int64) -> URL {
        URL(fileURLWithPath: databasePath).deletingLastPathComponent()
            .appendingPathComponent("automation-drafts", isDirectory: true)
            .appendingPathComponent("\(conversationID).jsonl")
    }

    /// The newest entry of a cache file's text (its last line that decodes).
    package static func newest(inCache text: String) -> Self? {
        let decoder = JSONDecoder()
        for line in text.split(whereSeparator: \.isNewline).reversed() {
            if let entry = try? decoder.decode(Self.self, from: Data(line.utf8)) { return entry }
        }
        return nil
    }
}

/// The "New automation" sheet's **Draft** panel (spec §12.2, mockup 2),
/// rendered from the newest draft of the conversation.
package struct AutomationDraftPanelModel: Equatable, Sendable {
    package struct Permission: Equatable, Sendable {
        /// The manifest string ("gmail:read@work", "output: inbox").
        package let manifest: String
        package let plain: String
    }

    package static let emptyHint = "Describe what it should do — the draft shows up here."
    package static let footer = "Saving asks for your confirmation. It won't run until you confirm."

    /// No draft yet.
    package let isEmpty: Bool
    package let name: String
    package let recipeText: String
    /// Parse errors of a draft that did not validate.
    package let errors: [String]
    package let when: String
    package let whenDetail: String?
    package let budget: String
    package let lastDryRunTokens: String?
    package let permissions: [Permission]
    package let cantLine: String?
    package let dryRunLines: [String]
    /// Why there are no dry-run lines: the refusal (ask #271) or the run's error.
    package let dryRunNote: String?

    package static let empty = Self(entry: nil)

    /// Reads the newest entry of the conversation's cache; empty when there is none.
    package static func load(databasePath: String, conversationID: Int64) -> Self {
        let url = AutomationDraftEntry.cacheURL(databasePath: databasePath, conversationID: conversationID)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .empty }
        return Self(entry: AutomationDraftEntry.newest(inCache: text))
    }

    package init(entry: AutomationDraftEntry?) {
        guard let entry else {
            isEmpty = true
            name = ""
            recipeText = ""
            errors = []
            when = ""
            whenDetail = nil
            budget = ""
            lastDryRunTokens = nil
            permissions = []
            cantLine = nil
            dryRunLines = []
            dryRunNote = nil
            return
        }
        let manifest = entry.result.manifest
        isEmpty = false
        name = manifest.name.isEmpty ? "Untitled draft" : manifest.name
        recipeText = entry.recipeText
        errors = entry.result.errors
        when = AutomationTriggerText.sentence(kind: manifest.triggerKind,
                                              specJSON: Self.triggerSpecJSON(kind: manifest.triggerKind,
                                                                             text: manifest.trigger))
        whenDetail = manifest.triggerKind == "schedule" ? Self.missedLine(recipeText: entry.recipeText) : nil
        budget = SaveAutomationCardModel.budget(tokens: manifest.budgetTokens, minutes: manifest.budgetMinutes)
        permissions = manifest.permissions.map {
            Permission(manifest: $0, plain: AutomationCardPresentation.permissionLine($0))
        } + manifest.outputs.map {
            Permission(manifest: "output: \($0)", plain: AutomationCardPresentation.outputLine($0))
        }
        cantLine = entry.result.ok ? Self.cantLine(permissions: manifest.permissions, outputs: manifest.outputs) : nil
        let dryRun = entry.result.dryRun
        if let dryRun, dryRun.status == "refused" {
            dryRunLines = []
            dryRunNote = dryRun.error
            lastDryRunTokens = nil
        } else if let dryRun {
            dryRunLines = DryRunPresentation.lines(steps: dryRun.steps.map(Self.runStep))
            dryRunNote = dryRun.error.isEmpty ? nil : dryRun.error
            lastDryRunTokens = "Last dry run used \(AutomationCardPresentation.number(dryRun.tokens)) tokens"
        } else {
            dryRunLines = []
            dryRunNote = nil
            lastDryRunTokens = nil
        }
    }

    /// The trigger column's JSON for `draft_automation`'s short trigger text.
    package static func triggerSpecJSON(kind: String, text: String) -> String {
        let object: [String: Any] = switch kind {
        case "schedule": ["schedule": text]
        case "button": ["button": ["label": text]]
        case "event": ["event": ["type": text]]
        default: ["manual": true]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// The draft's `missed:` key in words (the manifest does not carry it).
    private static func missedLine(recipeText: String) -> String {
        let block = RecipeFrontmatter.block(in: recipeText) ?? ""
        let skips = block.split(whereSeparator: \.isNewline).contains { line in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "missed" else { return false }
            return parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                == "skip"
        }
        return skips ? "Your local time · if the Mac was asleep, skips that time"
                     : "Your local time · if the Mac was asleep, runs once when it wakes"
    }

    /// "It can't …" over the writes the draft does not declare among mail
    /// send, Slack post and Jira change; nil when it declares all three.
    package static func cantLine(permissions: [String], outputs: [String]) -> String? {
        func declares(_ capability: String) -> Bool {
            permissions.contains { $0 == capability || $0.hasPrefix(capability + "@") }
        }
        var missing: [String] = []
        if !declares("gmail:write") { missing.append("send mail") }
        if !declares("slack:write") && !outputs.contains("slack") { missing.append("post to Slack") }
        if !declares("jira:write") { missing.append("change Jira") }
        guard let last = missing.last else { return nil }
        let head = missing.dropLast().joined(separator: ", ")
        return "It can't " + (head.isEmpty ? last : "\(head) or \(last)") + "."
    }

    private static func runStep(_ step: AutomationDraftEntry.Step) -> AutomationRunStep {
        AutomationRunStep(seq: step.seq, kind: step.kind, name: step.name, argsJSON: step.args,
                          resultSummary: step.result, status: step.status, permission: step.permission,
                          inputTokens: step.tokens, error: step.error)
    }
}
