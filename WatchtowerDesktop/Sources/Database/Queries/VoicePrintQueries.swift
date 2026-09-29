import Foundation
import GRDB
import WatchtowerCore

/// Registry people (`voice_prints`). A person's voice lives in
/// `voice_samples` (`VoiceSampleQueries`); this table is identity only.
enum VoicePrintQueries {
    /// Every known person (the table is small — one row per person the owner
    /// ever named or imported).
    static func fetchAll(_ db: Database) throws -> [VoicePrint] {
        try VoicePrint.order(Column("person_key")).fetchAll(db)
    }

    static func fetch(_ db: Database, personKey: String) throws -> VoicePrint? {
        try VoicePrint.filter(Column("person_key") == personKey).fetchOne(db)
    }

    static func fetch(_ db: Database, id: Int64) throws -> VoicePrint? {
        try VoicePrint.fetchOne(db, key: id)
    }

    /// The person for `personKey` (trimmed + lowercased), created when
    /// missing. Never renames an existing person — an import or a second
    /// confirmation must not overwrite the owner's chosen display name.
    static func findOrCreate(_ db: Database, personKey: String, displayName: String) throws -> VoicePrint {
        let key = normalizedKey(personKey)
        if let existing = try fetch(db, personKey: key) { return existing }
        var person = VoicePrint(personKey: key,
                                displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines))
        try person.insert(db)
        return person
    }

    /// Deletes the person; their samples cascade, queue suggestions are NULLed.
    static func delete(_ db: Database, id: Int64) throws {
        _ = try VoicePrint.deleteOne(db, key: id)
    }

    /// True when the person is the machine's owner: their `personKey` is one
    /// of the owner's email identities. Both sides are normalized here — no
    /// caller-side lowercasing contract to silently break. A name-keyed
    /// person is never recognizable as the owner.
    static func isOwner(_ print: VoicePrint, ownerEmails: Set<String>) -> Bool {
        let key = normalizedKey(print.personKey)
        return ownerEmails.contains { normalizedKey($0) == key }
    }

    /// Registry people matching an event's attendees by email or display name
    /// (case-insensitive, trimmed; empty attendee fields never match — a
    /// room resource row can carry an empty email).
    static func personIDs(_ db: Database, matching attendees: [EventAttendee]) throws -> Set<Int64> {
        let keys = Set(attendees.flatMap { [$0.email, $0.displayName] }.map(normalizedKey).filter { !$0.isEmpty })
        guard !keys.isEmpty else { return [] }
        return Set(try fetchAll(db)
            .filter { keys.contains(normalizedKey($0.personKey)) || keys.contains(normalizedKey($0.displayName)) }
            .compactMap(\.id))
    }

    /// Trim + case-fold, the `SpeakerNaming.personKey` normalization.
    private static func normalizedKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
