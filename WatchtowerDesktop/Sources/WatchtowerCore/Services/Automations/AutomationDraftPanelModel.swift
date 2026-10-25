import Foundation
import GRDB

/// One entry of the editor's draft cache: `draft_automation` on the
/// `automation_editor` surface appends `{recipe_text, result, error?, at}` to
/// `automation_draft_cache` and keeps the last five
/// (`internal/automations/authoring/draftcache.go`, `AutomationDraftCacheQueries`).
/// A UI cache of the tool's own result, not a store of record. A draft whose
/// evaluation failed is an entry with `result: null` and its `error`; every
/// other key is always written.
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
    /// nil when the evaluation failed (`error` says why).
    package let result: Result?
    package let error: String?

    enum CodingKeys: String, CodingKey {
        case recipeText = "recipe_text", result, error
    }

    /// The newest cache entry: none (no entry yet), a decoded entry, or one
    /// that does not decode — never an older entry in its place.
    package enum Newest: Equatable, Sendable {
        case none
        case entry(AutomationDraftEntry)
        case undecodable
    }

    /// The newest of a conversation's cache entries (oldest first), decoded.
    /// A newest entry that does not decode is `.undecodable`, never a silent
    /// fall-back to the one before it.
    package static func newest(in entries: [String]) -> Newest {
        guard let last = entries.last else { return .none }
        return decodeNewest(last)
    }

    /// One entry's JSON as the newest: `.entry`, or `.undecodable`.
    package static func decodeNewest(_ json: String) -> Newest {
        guard let entry = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)) else { return .undecodable }
        return .entry(entry)
    }
}

/// The "New automation" sheet's **Draft** panel (spec §12.2, mockup 2),
/// rendered from the newest draft of the conversation.
package struct AutomationDraftPanelModel: Equatable, Sendable {
    package static let emptyHint = "Describe what it should do — the draft shows up here."
    package static let unreadableHint = "Couldn't read the draft. Ask the assistant to draft it again."
    package static let footer = "Saving asks for your confirmation. It won't run until you confirm."

    /// The newest cached entry this was made from; nil when none decodes.
    package let entry: AutomationDraftEntry?
    /// No draft yet.
    package let isEmpty: Bool
    /// The cache could not be read, or its newest entry does not decode: the
    /// panel says so instead of showing an older draft.
    package let isUnreadable: Bool
    package let name: String
    package let recipeText: String
    /// Parse errors of a draft that did not validate.
    package let errors: [String]
    package let dryRunLines: [String]
    /// Why there are no (more) dry-run lines: the refusal (ask #271), the
    /// draft stop at mcp() (ask #326) or the run's error.
    package let dryRunNote: String?
    /// "Sessions it starts": the newest draft's `session()`/`agent()` calls.
    package let sessions: [AutomationSessionPrompt]
    /// Recipe text → the sessions of the newest cached draft with that text
    /// and a dry run (the save card's block); only `load` fills it.
    package private(set) var dryRunSessions: [String: AutomationDryRunSessions] = [:]

    package static let empty = Self(entry: nil)
    package static let unreadable = Self(entry: nil, unreadable: true)

    /// The text the panel shows as the current draft (its "Show recipe");
    /// nil when it shows none (empty or unreadable).
    package var shownRecipeText: String? { isEmpty || isUnreadable ? nil : recipeText }

    /// Reads the newest entry of the conversation's cache: empty when there
    /// is no entry yet, unreadable when the database cannot be read or the
    /// newest entry does not decode.
    package static func load(_ reader: any DatabaseReader, conversationID: Int64) -> Self {
        let entries: [String]
        do {
            entries = try reader.read { try AutomationDraftCacheQueries.entries($0, conversationID: conversationID) }
        } catch {
            return .unreadable
        }
        var model = Self(newest: AutomationDraftEntry.newest(in: entries))
        model.dryRunSessions = dryRunSessions(in: entries)
        return model
    }

    /// Every decodable cache entry, oldest first, keyed by its recipe text:
    /// the newest entry of a text wins, and one without a dry run (or a
    /// refused one) drops the text — its sessions are not known.
    package static func dryRunSessions(in entries: [String]) -> [String: AutomationDryRunSessions] {
        var byText: [String: AutomationDryRunSessions] = [:]
        for line in entries {
            guard let entry = try? JSONDecoder().decode(AutomationDraftEntry.self, from: Data(line.utf8)) else {
                continue
            }
            byText[entry.recipeText] = sessions(of: entry).map { sessions in
                // Only a run that went to the end lists every session.
                AutomationDryRunSessions(sessions: sessions, stoppedEarly: entry.result?.dryRun?.status != "succeeded")
            }
        }
        return byText
    }

    /// The entry's sessions; nil without a dry run that ran.
    private static func sessions(of entry: AutomationDraftEntry) -> [AutomationSessionPrompt]? {
        guard let dryRun = entry.result?.dryRun, dryRun.status != "refused" else { return nil }
        return AutomationCardPresentation.sessionPrompts(dryRun.steps)
    }

    package init(newest: AutomationDraftEntry.Newest) {
        switch newest {
        case .none: self.init(entry: nil)
        case let .entry(entry): self.init(entry: entry)
        case .undecodable: self.init(entry: nil, unreadable: true)
        }
    }

    package init(entry: AutomationDraftEntry?, unreadable: Bool = false) {
        self.entry = entry
        isUnreadable = entry == nil && unreadable
        guard let entry else {
            isEmpty = !unreadable
            name = ""
            recipeText = ""
            errors = []
            dryRunLines = []
            dryRunNote = nil
            sessions = []
            return
        }
        isEmpty = false
        recipeText = entry.recipeText
        guard let result = entry.result else {
            // The evaluation failed: the text and why, nothing else to show.
            name = "Untitled draft"
            errors = [entry.error.map { "Couldn't check this draft: \($0)" } ?? "Couldn't check this draft."]
            dryRunLines = []
            dryRunNote = nil
            sessions = []
            return
        }
        name = result.manifest.name.isEmpty ? "Untitled draft" : result.manifest.name
        errors = result.errors
        sessions = Self.sessions(of: entry) ?? []
        let dryRun = result.dryRun
        if let dryRun, dryRun.status == "refused" {
            dryRunLines = []
            dryRunNote = dryRun.error
        } else if let dryRun {
            dryRunLines = DryRunPresentation.lines(steps: dryRun.steps.map(Self.runStep))
            dryRunNote = dryRun.error.isEmpty ? nil : dryRun.error
        } else {
            dryRunLines = []
            dryRunNote = nil
        }
    }

    /// A schedule's detail line: local time, and what a time missed while
    /// the Mac slept does (the draft column).
    package static func missedDetail(skips: Bool) -> String {
        skips ? "Your local time · if the Mac was asleep, skips that time"
              : "Your local time · if the Mac was asleep, runs once when it wakes"
    }

    private static func runStep(_ step: AutomationDraftEntry.Step) -> AutomationRunStep {
        AutomationRunStep(seq: step.seq, kind: step.kind, name: step.name, argsJSON: step.args,
                          resultSummary: step.result, status: step.status, permission: step.permission,
                          inputTokens: step.tokens, error: step.error)
    }
}
