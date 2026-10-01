import Foundation
import GRDB
import WatchtowerCore

/// A previewed `.wtvoices` file, before anything is written (design spec §5:
/// "file + password → preview ... → one transaction"). `people`/`samples`
/// count only what would actually be written — a person skipped as the owner
/// or a reserved name never contributes to either.
struct VoiceImportPreview: Equatable {
    let sender: VoiceExportPayload.Sender
    let people: Int
    let samples: Int
    /// Display names of local people the file's people would merge into (by
    /// `person_key`).
    let merges: [String]
    /// Display names of people the file would create as new registry entries.
    let newPeople: [String]
    /// One note per imported person whose voice scores ≥
    /// `VoiceRegistryPolicy.importConflict` against a DIFFERENT local person
    /// (spec §5: "raises a conflict ... the first time that voice appears").
    let conflicts: [String]
    /// Count of the file's people skipped because they matched an owner
    /// email or a reserved label (spec §5, invariant 2).
    let skippedOwner: Int
    let modelMismatch: Bool
    let alreadyImported: Bool
}

/// Imported voice-print files (`voice_imports`).
enum VoiceImportQueries {
    static func fetchAll(_ db: Database) throws -> [VoiceImport] {
        try VoiceImport.order(Column("imported_at").desc, Column("id").desc).fetchAll(db)
    }

    /// Deletes the import; its samples cascade.
    static func delete(_ db: Database, id: Int64) throws {
        _ = try VoiceImport.deleteOne(db, key: id)
    }

    /// Builds an export payload for `personIDs` (design spec §5, invariant
    /// 4): only `active` samples of `owner`/`auto` origin at the current
    /// model version — `imported` and `pending` samples are never
    /// re-shared — at most `VoiceRegistryPolicy.exportPerChannel` per
    /// person+channel, anchors first, then highest `score`. A person with no
    /// exportable samples (everything filtered out) is left out of the file
    /// entirely.
    static func buildExport(_ db: Database, sender: VoiceExportPayload.Sender, personIDs: Set<Int64>) throws -> VoiceExportPayload {
        let people = try VoicePrintQueries.fetchAll(db).filter { $0.id.map(personIDs.contains) ?? false }

        var exportPeople: [VoiceExportPayload.Person] = []
        for person in people {
            guard let personID = person.id else { continue }
            let samples = try VoiceSample
                .filter(Column("person_id") == personID
                    && Column("status") == VoiceSampleStatus.active.rawValue
                    && Column("model_version") == VoiceRegistryPolicy.embeddingModelVersion
                    && [VoiceSampleOrigin.owner.rawValue, VoiceSampleOrigin.auto.rawValue].contains(Column("origin")))
                .fetchAll(db)

            var exportedSamples: [VoiceExportPayload.Sample] = []
            for (channel, channelSamples) in Dictionary(grouping: samples, by: \.channel) {
                let ordered = channelSamples.sorted { a, b in
                    a.anchor != b.anchor ? a.anchor : (a.score ?? 0) > (b.score ?? 0)
                }
                exportedSamples += ordered.prefix(VoiceRegistryPolicy.exportPerChannel).map {
                    VoiceExportPayload.Sample(embedding: $0.vector, channel: channel, speechSec: $0.speechSec)
                }
            }
            guard !exportedSamples.isEmpty else { continue }
            exportPeople.append(VoiceExportPayload.Person(
                personKey: person.personKey, displayName: person.displayName, samples: exportedSamples))
        }

        return VoiceExportPayload(
            formatVersion: 1, modelVersion: VoiceRegistryPolicy.embeddingModelVersion,
            sender: sender, people: exportPeople.sorted { $0.personKey < $1.personKey })
    }

    /// Read-only dry run of `apply` (design spec §5): reports what importing
    /// `payload` would do without writing anything. A model mismatch or an
    /// already-imported file (`fileSHA256` already logged) short-circuits to
    /// an empty summary with the matching flag set — `apply` will refuse the
    /// same way.
    static func preview(_ db: Database, payload: VoiceExportPayload, fileSHA256: String, ownerEmails: Set<String>) throws -> VoiceImportPreview {
        let modelMismatch = payload.modelVersion != VoiceRegistryPolicy.embeddingModelVersion
        let alreadyImported = try VoiceImport.filter(Column("file_sha256") == fileSHA256).fetchCount(db) > 0
        guard !modelMismatch, !alreadyImported else {
            return VoiceImportPreview(
                sender: payload.sender, people: 0, samples: 0, merges: [], newPeople: [], conflicts: [],
                skippedOwner: 0, modelMismatch: modelMismatch, alreadyImported: alreadyImported)
        }

        let localPeople = try VoicePrintQueries.fetchAll(db)
        let localByKey = Dictionary(uniqueKeysWithValues: localPeople.map { (normalizedKey($0.personKey), $0) })
        let localByID = Dictionary(uniqueKeysWithValues: localPeople.compactMap { p in p.id.map { ($0, p) } })
        let usable = try VoiceSampleQueries.fetchUsable(db)

        var merges: [String] = []
        var newPeople: [String] = []
        var conflicts: [String] = []
        var skippedOwner = 0
        var peopleCount = 0
        var sampleCount = 0

        for person in payload.people {
            let key = normalizedKey(person.personKey)
            guard !ownerEmails.contains(where: { normalizedKey($0) == key }), !SpeakerNaming.isReserved(person.displayName) else {
                skippedOwner += 1
                continue
            }
            guard !person.samples.isEmpty else { continue }
            peopleCount += 1
            sampleCount += person.samples.count

            if let existing = localByKey[key] {
                merges.append(existing.displayName)
            } else {
                newPeople.append(person.displayName)
            }

            for sample in person.samples {
                guard let top = VoiceMatcher.nearest(embedding: sample.embedding, samples: usable).first,
                      top.score >= VoiceRegistryPolicy.importConflict,
                      localByKey[key]?.id != top.personID,
                      let conflictPerson = localByID[top.personID]
                else { continue }
                let note = "\(person.displayName) may be the same voice as \(conflictPerson.displayName)"
                if !conflicts.contains(note) { conflicts.append(note) }
                break
            }
        }

        return VoiceImportPreview(
            sender: payload.sender, people: peopleCount, samples: sampleCount, merges: merges,
            newPeople: newPeople, conflicts: conflicts, skippedOwner: skippedOwner,
            modelMismatch: false, alreadyImported: false)
    }

    /// Imports `payload` in one transaction (the caller's `dbPool.write`
    /// closure — GRDB rolls the whole thing back on any thrown error): a
    /// `voice_imports` row plus `origin=imported`/`status=pending` samples,
    /// merged by `person_key` (`VoicePrintQueries.findOrCreate` never renames
    /// an existing person). Returns nil — writing nothing — when the model
    /// version doesn't match or `fileSHA256` was already imported (same file
    /// twice is a no-op). The owner's emails and reserved labels are skipped
    /// silently (invariant 2). A newer file from the same sender replaces
    /// that sender's previous PENDING samples (already-`active` — confirmed —
    /// samples are untouched) before the new ones are inserted; a sender
    /// with no email is never "the same sender" as anyone.
    static func apply(_ db: Database, payload: VoiceExportPayload, fileSHA256: String, ownerEmails: Set<String>) throws -> Int64? {
        guard payload.modelVersion == VoiceRegistryPolicy.embeddingModelVersion else { return nil }
        guard try VoiceImport.filter(Column("file_sha256") == fileSHA256).fetchCount(db) == 0 else { return nil }

        let senderEmail = payload.sender.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // An empty email identifies nobody: two different senders without one
        // (e.g. Jira-only owners) must never replace each other's samples.
        if !senderEmail.isEmpty {
            try db.execute(
                sql: """
                    DELETE FROM voice_samples WHERE origin = 'imported' AND status = 'pending'
                      AND import_id IN (SELECT id FROM voice_imports WHERE sender_email = ?)
                    """,
                arguments: [senderEmail])
        }

        var importRow = VoiceImport(
            senderName: payload.sender.name, senderEmail: senderEmail, fileSHA256: fileSHA256,
            peopleCount: 0, sampleCount: 0, modelVersion: payload.modelVersion)
        try importRow.insert(db)
        guard let importID = importRow.id else { throw DatabaseError(message: "voice import insert returned no id") }

        var peopleCount = 0
        var sampleCount = 0
        for person in payload.people {
            let key = normalizedKey(person.personKey)
            guard !ownerEmails.contains(where: { normalizedKey($0) == key }), !SpeakerNaming.isReserved(person.displayName) else { continue }
            guard !person.samples.isEmpty else { continue }

            let local = try VoicePrintQueries.findOrCreate(db, personKey: key, displayName: person.displayName)
            guard let personID = local.id else { continue }
            var insertedAny = false
            for sample in person.samples {
                guard let normalized = VoiceMatcher.normalize(sample.embedding) else { continue }
                var row = VoiceSample(
                    personID: personID, embedding: VoicePrintEmbedding.encode(normalized),
                    modelVersion: payload.modelVersion, origin: .imported, anchor: false, status: .pending,
                    channel: sample.channel, speechSec: sample.speechSec, importID: importID)
                try VoiceSampleQueries.insert(db, &row)
                sampleCount += 1
                insertedAny = true
            }
            if insertedAny { peopleCount += 1 }
        }

        try db.execute(
            sql: "UPDATE voice_imports SET people_count = ?, sample_count = ? WHERE id = ?",
            arguments: [peopleCount, sampleCount, importID])
        return importID
    }

    /// Trim + case-fold, the `VoicePrintQueries.normalizedKey` normalization.
    private static func normalizedKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
