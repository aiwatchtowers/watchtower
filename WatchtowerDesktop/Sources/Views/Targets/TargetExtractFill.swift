import Foundation
import WatchtowerCore

/// The subset of `CreateTargetSheet`'s form state that an extraction may fill.
/// Kept as a plain value so the fill rules stay pure and unit-testable — the
/// sheet copies its `@State` in, applies the result, and copies it back out.
struct TargetDraft: Equatable {
    var text: String
    var intent: String
    var level: String
    var priority: String
    /// YYYY-MM-DD. Empty means "the sheet has no explicit period yet".
    var periodStart: String
    var periodEnd: String
    /// True once a period is meant to be persisted verbatim — either the user
    /// picked the "Custom" level or the extractor proposed a concrete window.
    /// Without it a non-custom level falls back to today/today on save, which
    /// would silently drop an AI-proposed window.
    var hasExplicitPeriod: Bool
    var subItems: [TargetSubItem]
    var parentID: Int?
}

/// What an extraction result should do to the open New Target form.
enum TargetExtractOutcome: Equatable {
    /// Exactly one proposal — merged into the form the user is already looking at.
    case filled(TargetDraft)
    /// Several proposals — the existing multi-select `ExtractPreviewSheet` handles it.
    case needsPreview
    /// The model found no targets in the text.
    case nothing
}

/// Merge rules for "Extract with AI" results, plus the request text the button
/// sends. Pure by construction: no view state, no I/O.
enum TargetExtractFill {
    /// Decides how `proposals` land on `draft`. A single proposal fills the
    /// form in place; anything the user already typed wins over the model's
    /// version of the same field, so pressing the button can never quietly
    /// discard hand-written input.
    static func apply(_ proposals: [ProposedTarget], to draft: TargetDraft) -> TargetExtractOutcome {
        guard let proposal = proposals.first else { return .nothing }
        guard proposals.count == 1 else { return .needsPreview }

        var filled = draft
        filled.text = preferring(proposal.text, over: draft.text)
        // The user's own "why" is the more valuable of the two — the model only
        // fills the gap when the field is still empty.
        filled.intent = preferring(draft.intent, over: proposal.intent)
        filled.level = preferring(proposal.level, over: draft.level)
        filled.priority = preferring(proposal.priority, over: draft.priority)

        let start = proposal.periodStart.trimmed
        let end = proposal.periodEnd.trimmed
        if !start.isEmpty && !end.isEmpty {
            filled.periodStart = start
            filled.periodEnd = end
            filled.hasExplicitPeriod = true
        }

        filled.subItems = draft.subItems + proposal.subItems
        filled.parentID = draft.parentID ?? proposal.parentId
        return .filled(filled)
    }

    /// The text handed to `targets extract`. The sheet's "Add context" field is
    /// appended rather than dropped — before this it never reached the model at
    /// all, so context the user typed had no effect on the proposal.
    static func composeInput(text: String, context: String) -> String {
        let goal = text.trimmed
        let why = context.trimmed
        guard !why.isEmpty else { return goal }
        return "\(goal)\n\nWhy this matters: \(why)"
    }

    private static func preferring(_ first: String, over second: String) -> String {
        first.trimmed.isEmpty ? second : first
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
