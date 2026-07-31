import Foundation
import GRDB

enum VoicePrintQueries {
    /// Every known voice print (the whole database is small — one row per
    /// person the owner ever named).
    static func fetchAll(_ db: Database) throws -> [VoicePrint] {
        try VoicePrint.order(Column("person_key")).fetchAll(db)
    }

    static func fetch(_ db: Database, personKey: String) throws -> VoicePrint? {
        try VoicePrint.filter(Column("person_key") == personKey).fetchOne(db)
    }

    /// Learns a confirmed cluster embedding for a person (the rename flow's
    /// write). New person → insert with the embedding as the initial centroid
    /// (normalized defensively). Existing person → incremental centroid
    /// `normalize(centroid·n + embedding)` and `sample_count += 1`.
    /// No-ops (keeping any existing row intact) when the embedding is
    /// degenerate — zero vector, or a dimension mismatch with the stored
    /// centroid — because corrupt data must never poison a learned voice.
    static func upsert(_ db: Database, personKey: String, displayName: String, embedding: [Float]) throws {
        guard let normalized = VoicePrintMatcher.normalize(embedding) else { return }
        if let existing = try fetch(db, personKey: personKey) {
            guard let centroid = VoicePrintMatcher.updatedCentroid(
                centroid: existing.embeddingVector,
                sampleCount: existing.sampleCount,
                embedding: normalized
            ) else { return }
            try db.execute(
                sql: """
                    UPDATE voice_prints
                    SET display_name = ?, embedding = ?, sample_count = sample_count + 1,
                        updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                    WHERE person_key = ?
                    """,
                arguments: [displayName, VoicePrintEmbedding.encode(centroid), personKey])
        } else {
            try db.execute(
                sql: """
                    INSERT INTO voice_prints (person_key, display_name, embedding, sample_count, updated_at)
                    VALUES (?, ?, ?, 1, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
                    """,
                arguments: [personKey, displayName, VoicePrintEmbedding.encode(normalized)])
        }
    }
}
