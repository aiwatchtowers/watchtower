// WatchtowerDesktop/Sources/Models/TargetPrefill.swift
import Foundation

/// Pre-filled values flowing into `CreateTargetSheet` (and `PromoteSubItemSheet`)
/// from an in-app source — briefing item, digest, track, inbox item, or a parent
/// target's sub-item being promoted.
///
/// Built synchronously (or via a single short DB read) by `TargetPrefillBuilder`.
/// Nothing here calls the LLM; this is content lifted from existing DB rows.
package struct TargetPrefill: Equatable {
    package var text: String
    package var intent: String
    /// One of the values allowed by the production `targets.source_type` CHECK:
    /// `extract | track | digest | briefing | manual | chat | inbox | jira |
    /// slack | promoted_subitem`.
    package var sourceType: String
    package var sourceID: String
    package var secondaryLinks: [TargetPrefillLink] = []
    /// Promote-subitem only — wires up `targets.parent_id`. Other sources leave nil.
    package var parentID: Int? = nil

    package init(
        text: String,
        intent: String,
        sourceType: String,
        sourceID: String,
        secondaryLinks: [TargetPrefillLink] = [],
        parentID: Int? = nil
    ) {
        self.text = text
        self.intent = intent
        self.sourceType = sourceType
        self.sourceID = sourceID
        self.secondaryLinks = secondaryLinks
        self.parentID = parentID
    }
}

/// One link to be written into `target_links` alongside the new target.
package struct TargetPrefillLink: Equatable {
    /// Must satisfy the Go-side allow-list `IsValidExternalRef`:
    /// starts with `"jira:"` or `"slack:"`. Anything else is dropped before insert.
    package var externalRef: String
    /// One of the values in the `target_links.relation` CHECK:
    /// `contributes_to | blocks | related | duplicates`.
    package var relation: String

    package init(externalRef: String, relation: String) {
        self.externalRef = externalRef
        self.relation = relation
    }
}
