// WatchtowerDesktop/Sources/Models/TargetPrefill.swift
import Foundation

/// Pre-filled values flowing into `CreateTargetSheet` (and `PromoteSubItemSheet`)
/// from an in-app source — briefing item, digest, track, inbox item, or a parent
/// target's sub-item being promoted.
///
/// Built synchronously (or via a single short DB read) by `TargetPrefillBuilder`.
/// Nothing here calls the LLM; this is content lifted from existing DB rows.
struct TargetPrefill: Equatable {
    var text: String
    var intent: String
    /// One of the values allowed by the production `targets.source_type` CHECK:
    /// `extract | track | digest | briefing | manual | chat | inbox | jira |
    /// slack | promoted_subitem`.
    var sourceType: String
    var sourceID: String
    var secondaryLinks: [TargetPrefillLink] = []
    /// Promote-subitem only — wires up `targets.parent_id`. Other sources leave nil.
    var parentID: Int? = nil
}

/// One link to be written into `target_links` alongside the new target.
struct TargetPrefillLink: Equatable {
    /// Must satisfy the Go-side allow-list `IsValidExternalRef`:
    /// starts with `"jira:"` or `"slack:"`. Anything else is dropped before insert.
    var externalRef: String
    /// One of the values in the `target_links.relation` CHECK:
    /// `contributes_to | blocks | related | duplicates`.
    var relation: String
}
