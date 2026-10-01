import Foundation
import GRDB
import WatchtowerCore

/// Names past unnamed "Speaker N" clusters from the registry's active voice
/// samples (spec §4.1) — including recordings whose audio file is long gone,
/// since matching runs on the persisted `speakers_json` embeddings alone.
/// Runs after a confirm/import so a freshly-learned voice can retroactively
/// light up every earlier recording it appears in, and can also run as a
/// standalone catch-up pass. A voice a pending import disputes is left alone
/// (`decide` sees the pending samples too). Pure application
/// of `VoiceMatcher.decide`: never enqueues a labeling task, never inserts or
/// touches a `voice_samples` row — naming from an existing sample teaches
/// nothing new about that sample.
enum VoiceRetroRelabeler {
    /// The matcher inputs every transcript's pass shares: usable samples
    /// (active + pending imports), people by id, and the owner's people.
    struct Context: Sendable {
        let samples: [VoiceSample]
        let people: [Int64: VoicePrint]
        let owners: Set<Int64>
    }

    /// Relabels every confident unnamed cluster across all recordings (or, with
    /// `onlyPersonID`, only those confidently matching that one person — still
    /// computing every cluster's decision first, so a person still competes for
    /// the one-cluster-per-recording slot against every other candidate), in the
    /// caller's single transaction. Returns how many clusters were relabeled.
    @discardableResult
    static func run(_ db: Database, onlyPersonID: Int64? = nil) throws -> Int {
        guard let context = try loadContext(db) else { return 0 }
        var changed = 0
        for tid in try transcriptIDs(db) {
            changed += try relabel(db, transcriptID: tid, context: context, onlyPersonID: onlyPersonID)
        }
        // A cluster retro just named may have a pending "who is this?"
        // task elsewhere — close it so the queue/tray counter drains.
        if changed > 0 { try VoiceLabelQueueQueries.closeResolvedTasks(db) }
        return changed
    }

    /// The same pass as `run(_:onlyPersonID:)`, but one write transaction
    /// per transcript (spec §4.1) — the launch catch-up walks the whole
    /// history, and holding the SQLite write lock across all of it would
    /// starve the Go daemon's writes (5 s busy timeout). The matcher inputs
    /// are read once up front; an interrupted pass simply resumes on the
    /// next launch (idempotent — a named cluster is never revisited).
    @discardableResult
    static func run(in writer: some DatabaseWriter, onlyPersonID: Int64? = nil) async throws -> Int {
        let loaded = try await writer.read { db in (try loadContext(db), try transcriptIDs(db)) }
        guard let context = loaded.0 else { return 0 }
        var changed = 0
        for tid in loaded.1 {
            changed += try await writer.write { db in
                try relabel(db, transcriptID: tid, context: context, onlyPersonID: onlyPersonID)
            }
        }
        if changed > 0 {
            try await writer.write { db in _ = try VoiceLabelQueueQueries.closeResolvedTasks(db) }
        }
        return changed
    }

    /// nil when there is no active sample to match against. The pending
    /// imported samples ride along: in `decide` they can only demote a match
    /// to a conflict or an import suggestion, never label (invariant 3) — so
    /// a voice an import disputes stays unnamed until the owner settles it,
    /// whatever became of its queue task (an audio sweep skips it).
    private static func loadContext(_ db: Database) throws -> Context? {
        let samples = try VoiceSampleQueries.fetchUsable(db)
        guard samples.contains(where: { $0.status == .active }) else { return nil }
        let people = Dictionary(uniqueKeysWithValues: try VoicePrintQueries.fetchAll(db).compactMap { p in p.id.map { ($0, p) } })
        let ownerEmails = Set(try GoogleAccountQueries.fetchAll(db).map { $0.email.lowercased() }.filter { !$0.isEmpty })
        let owners = Set(people.values.filter { VoicePrintQueries.isOwner($0, ownerEmails: ownerEmails) }.compactMap(\.id))
        return Context(samples: samples, people: people, owners: owners)
    }

    private static func transcriptIDs(_ db: Database) throws -> [Int64] {
        try Int64.fetchAll(db, sql: "SELECT id FROM meeting_transcripts WHERE speakers_json IS NOT NULL ORDER BY id")
    }

    /// One transcript's pass. Returns how many of its clusters were relabeled.
    private static func relabel(_ db: Database, transcriptID tid: Int64, context: Context, onlyPersonID: Int64?) throws -> Int {
        guard let transcript = try MeetingTranscriptQueries.fetch(db, id: tid),
              let speakers = transcript.speakerEmbeddings else { return 0 }
        let candidates = speakers.filter { $0.effectiveLabelSource == .none && $0.mixed != true }
        guard !candidates.isEmpty else { return 0 }

        // Mirrors AppState.loadVoiceRegistry: an event that exists but
        // yields zero attendee identities is treated as ad-hoc
        // (invited = nil) rather than an empty set, which would demote
        // every colleague to unsure under the stricter no-event bar.
        var invited: Set<Int64>?
        if let eventID = transcript.eventID, let event = try CalendarQueries.fetchEvent(db, id: eventID) {
            let identities = event.attendeesIncludingOrganizer
            if !identities.isEmpty {
                invited = try VoicePrintQueries.personIDs(db, matching: identities)
            }
        }

        let clusters = speakers.map {
            VoiceMatcher.Cluster(label: $0.speaker, embedding: $0.embedding,
                                 speechSec: $0.speechSec ?? VoiceRegistryPolicy.minClusterSpeechSec,
                                 rejectedPersonIDs: Set($0.rejectedPersonIDs ?? []))
        }
        let decisions = VoiceMatcher.decide(clusters: clusters, samples: context.samples, invited: invited,
                                            ownerPersonIDs: context.owners)

        var changed = 0
        for candidate in candidates {
            guard case let .confident(personID, sampleID, score) = decisions[candidate.speaker],
                  onlyPersonID == nil || onlyPersonID == personID,
                  let person = context.people[personID] else { continue }
            let relabeled = try MeetingTranscriptQueries.relabelCluster(db, id: tid, from: candidate.speaker, to: person.displayName) {
                $0.labelSource = .auto
                $0.personID = personID
                $0.matchedSampleID = sampleID
                $0.score = score
            }
            if relabeled { changed += 1 }
        }
        return changed
    }
}
