import Foundation
import GRDB
import WatchtowerCore

/// One registry person's Review-screen summary (spec §3.2): sample counts by
/// origin, the distinct channels their voice was captured through, and when
/// they were last recognized in a recording.
struct VoicePersonSummary: Identifiable, Equatable {
    let id: Int64
    let displayName: String
    let personKey: String
    let counts: [VoiceSampleOrigin: Int]
    let channels: Set<VoiceChannel>
    let lastRecognized: String?
}

/// Per-sample voice embeddings (`voice_samples`).
enum VoiceSampleQueries {
    /// Samples the matcher may consult: active (name) and pending imported
    /// (suggest only), current embedding model only.
    static func fetchUsable(_ db: Database) throws -> [VoiceSample] {
        try VoiceSample
            .filter([VoiceSampleStatus.active.rawValue, VoiceSampleStatus.pending.rawValue].contains(Column("status"))
                && Column("model_version") == VoiceRegistryPolicy.embeddingModelVersion)
            .fetchAll(db)
    }

    /// A person's active owner anchors — the samples self-training must stay close to.
    static func anchors(_ db: Database, personID: Int64) throws -> [VoiceSample] {
        try VoiceSample
            .filter(Column("person_id") == personID && Column("anchor") == true
                && Column("status") == VoiceSampleStatus.active.rawValue)
            .fetchAll(db)
    }

    static func insert(_ db: Database, _ sample: inout VoiceSample) throws {
        try sample.insert(db)
    }

    /// Inserts a self-trained sample, then retires the oldest active auto
    /// samples of the same person+channel beyond `autoCapPerChannel`, so
    /// auto samples can never crowd out a person's voice. Anchors and
    /// imported samples are never retired here.
    @discardableResult
    static func insertAuto(_ db: Database, _ sample: VoiceSample) throws -> Int64 {
        precondition(sample.origin == .auto && !sample.anchor, "insertAuto takes non-anchor auto samples only")
        var inserted = sample
        try inserted.insert(db)
        try db.execute(
            sql: """
                UPDATE voice_samples SET status = 'retired'
                WHERE id IN (
                  SELECT id FROM voice_samples
                  WHERE person_id = ? AND channel = ? AND origin = 'auto' AND status = 'active'
                  ORDER BY created_at DESC, id DESC LIMIT -1 OFFSET ?)
                """,
            arguments: [inserted.personID, inserted.channel.rawValue, VoiceRegistryPolicy.autoCapPerChannel])
        guard let id = inserted.id else { throw DatabaseError(message: "voice sample insert returned no id") }
        return id
    }

    static func retire(_ db: Database, id: Int64) throws {
        try db.execute(sql: "UPDATE voice_samples SET status = 'retired' WHERE id = ?", arguments: [id])
    }

    /// Activates a person's pending imported samples — all of them, or only
    /// those of one import when `importID` is given.
    static func activatePending(_ db: Database, personID: Int64, importID: Int64?) throws {
        try db.execute(
            sql: """
                UPDATE voice_samples SET status = 'active'
                WHERE person_id = ? AND status = 'pending' AND origin = 'imported'
                  AND (? IS NULL OR import_id = ?)
                """,
            arguments: [personID, importID, importID])
    }

    /// Every sample (any status/model) grouped by person.
    static func fetchByPerson(_ db: Database) throws -> [Int64: [VoiceSample]] {
        Dictionary(grouping: try VoiceSample.order(Column("id")).fetchAll(db), by: \.personID)
    }

    /// Review-screen registry list (spec §3.2): per person, `active`-sample
    /// counts by origin, the distinct channels those samples came through,
    /// and the most recent time they were recognized in a recording
    /// (`created_at` of an active sample tied to a transcript — imported
    /// samples never carry one, so an import-only person has no
    /// `lastRecognized`). A person with zero active samples (e.g. every
    /// sample retired by a rollback) is omitted — there is nothing to
    /// review. Ordered by `person_key` (`VoicePrintQueries.fetchAll`).
    static func personSummaries(_ db: Database) throws -> [VoicePersonSummary] {
        let countRows = try Row.fetchAll(
            db,
            sql: """
                SELECT person_id, origin, channel, count(*) AS cnt
                FROM voice_samples
                WHERE status = ?
                GROUP BY person_id, origin, channel
                """,
            arguments: [VoiceSampleStatus.active.rawValue])

        var counts: [Int64: [VoiceSampleOrigin: Int]] = [:]
        var channels: [Int64: Set<VoiceChannel>] = [:]
        for row in countRows {
            guard let origin = VoiceSampleOrigin(rawValue: row["origin"]),
                  let channel = VoiceChannel(rawValue: row["channel"]) else { continue }
            let personID: Int64 = row["person_id"]
            let count: Int = row["cnt"]
            counts[personID, default: [:]][origin, default: 0] += count
            channels[personID, default: []].insert(channel)
        }

        let lastRows = try Row.fetchAll(
            db,
            sql: """
                SELECT person_id, max(created_at) AS last_at
                FROM voice_samples
                WHERE status = ? AND transcript_id IS NOT NULL
                GROUP BY person_id
                """,
            arguments: [VoiceSampleStatus.active.rawValue])
        var lastRecognized: [Int64: String] = [:]
        for row in lastRows {
            let personID: Int64 = row["person_id"]
            lastRecognized[personID] = row["last_at"]
        }

        return try VoicePrintQueries.fetchAll(db).compactMap { person in
            guard let id = person.id, let personCounts = counts[id] else { return nil }
            return VoicePersonSummary(
                id: id, displayName: person.displayName, personKey: person.personKey,
                counts: personCounts, channels: channels[id] ?? [], lastRecognized: lastRecognized[id])
        }
    }
}
