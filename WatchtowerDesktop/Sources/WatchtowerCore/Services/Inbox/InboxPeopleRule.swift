import Foundation

/// The people / mail split of the open attention items (spec "Waiting for
/// me and Mail waiting"): `email_received` is mail (Mail waiting), every
/// other feed trigger is people (Waiting for me). Go twins in
/// `internal/db/inbox_open.go` (`WaitingKindOf`, `MailSenderKey`,
/// `MuteScopePrefix`, `mutedMailClause`), pinned by `WaitingSplitParityTests`
/// over `internal/inbox/testdata/waiting_split.json`.
package enum InboxPeopleRule {
    package static let mailTrigger = "email_received"

    package static func isPeople(trigger: String) -> Bool { trigger != mailTrigger }

    /// SQL over `inbox_items`, added to `HomeFeedQueries.openMessageClause`.
    package static let peopleClause = "trigger_type != '\(mailTrigger)'"
    package static let mailClause = "trigger_type = '\(mailTrigger)'"

    /// Keeps an item whose sender has no `source_mute` rule on its sender
    /// key (any weight, any pipeline). Applies to mail only.
    package static let mutedMailClause = """
        NOT EXISTS (SELECT 1 FROM inbox_learned_rules r WHERE r.rule_type = 'source_mute'
          AND r.scope_key = '\(mutePrefix)' || lower(trim(inbox_items.sender_user_id)))
        """

    private static let mutePrefix = "email:"

    /// The one spelling of a mail sender: spaces trimmed from both ends and
    /// ASCII letters lowered, other characters unchanged — exactly SQLite's
    /// `lower(trim(x))`.
    package static func senderKey(_ raw: String) -> String {
        let scalars = raw.unicodeScalars
        guard let first = scalars.firstIndex(where: { $0 != " " }),
              let last = scalars.lastIndex(where: { $0 != " " }) else { return "" }
        var out = String.UnicodeScalarView()
        for scalar in scalars[first...last] {
            out.append(("A"..."Z").contains(scalar) ? Unicode.Scalar(scalar.value + 32) ?? scalar : scalar)
        }
        return String(out)
    }

    /// A `source_mute` rule's `scope_key` for a mail sender.
    package static func muteScope(_ address: String) -> String { mutePrefix + senderKey(address) }
}
