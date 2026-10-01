import Foundation
import GRDB
import WatchtowerCore

/// Outcome of `VoiceLabelingQueries.confirm`.
enum VoiceLabelingResult: Equatable {
    case labeled(personID: Int64)
    /// The task's cluster was already relabeled by something else (another
    /// task, a concurrent confirm) before this confirm ran — nothing written.
    case alreadyLabeled
    /// The name is reserved, or the transcript/cluster no longer exists — nothing written.
    case stale
    /// Another speaker of this recording already carries `name` — nothing
    /// written, the task stays open (two clusters are never merged under
    /// one label; the owner picks another name).
    case nameTaken(name: String)
}

/// Why a labeling task was dismissed without naming the cluster.
enum DismissKind {
    case dontKnow, severalPeople, skip
}

/// The owner's voice-labeling transactions: confirming a name, or dismissing
/// a task as unresolvable (spec §3.1). `VoiceLabelQueueQueries` owns the raw
/// queue rows; this is the decision layer on top of it plus
/// `MeetingTranscriptQueries.relabelCluster`.
enum VoiceLabelingQueries {
    /// Names a cluster: finds-or-creates the `VoicePrint`, relabels the
    /// cluster to the person's canonical display name, records the
    /// embedding as a new owner anchor sample, and closes the task (if any).
    /// A task whose reason is `.importConfirm` also activates that person's
    /// pending imported samples from the sender whose sample suggested this
    /// voice (the nearest of that person's pending samples, at ≥ `confident`)
    /// — a different sender's pending samples for the same person are
    /// untouched; a `.conflict` task confirmed as the imported person does
    /// the same.
    /// Every confirm retires the samples of OTHER people — pending, auto and
    /// anchors — that sit on this voice (`VoiceMatcher.contradictingSamples`)
    /// and re-matches their dependents: the owner's choice ends the dispute.
    ///
    /// Stale guards: an unknown/reserved name, or a transcript/cluster that
    /// no longer exists, is `.stale` with nothing written. A cluster the
    /// task named has since been relabeled to something else (by another
    /// task or a concurrent confirm) is `.alreadyLabeled` — the task still
    /// closes, but no new person or sample is created.
    static func confirm(
        _ db: Database,
        taskID: Int64?,
        transcriptID: Int64,
        clusterLabel: String,
        personKey: String,
        displayName: String
    ) throws -> VoiceLabelingResult {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !SpeakerNaming.isReserved(name) else { return .stale }

        guard let transcript = try MeetingTranscriptQueries.fetch(db, id: transcriptID),
              let cluster = transcript.speakerEmbeddings?.first(where: {
                  $0.speaker == clusterLabel || $0.originalLabel == clusterLabel
              })
        else {
            if let taskID { try VoiceLabelQueueQueries.resolveTask(db, id: taskID, status: .skipped) }
            return .stale
        }

        // The cluster this task was queued for has already been relabeled
        // (by another task, or a concurrent confirm) — never overwrite it.
        if cluster.speaker != clusterLabel {
            if let taskID { try VoiceLabelQueueQueries.resolveTask(db, id: taskID, status: .done) }
            return .alreadyLabeled
        }

        // The label this confirm would write: an existing person keeps
        // their display name. Checked before ANY write, so a refusal leaves
        // no half-applied retire or new person behind.
        let normalizedKey = personKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let label = try VoicePrintQueries.fetch(db, personKey: normalizedKey)?.displayName ?? name
        if MeetingTranscriptQueries.labelInUse(transcript, label, besides: clusterLabel) {
            return .nameTaken(name: label)
        }

        let person = try VoicePrintQueries.findOrCreate(db, personKey: personKey, displayName: name)
        guard let personID = person.id else { return .stale }

        let relabeled = try MeetingTranscriptQueries.relabelCluster(
            db, id: transcriptID, from: clusterLabel, to: person.displayName
        ) {
            $0.labelSource = .owner
            $0.personID = personID
            $0.matchedSampleID = nil
            $0.score = nil
            // Naming the voice by hand lifts an earlier rejection of this
            // person; relabeling it AWAY from someone rejects them.
            $0.clearRejection(of: personID)
            if let previous = cluster.personID, previous != personID { $0.rejectPerson(previous) }
        }
        guard relabeled else { return .stale }

        // Relabeling a NAMED voice to someone else ("Listen to samples",
        // spec §4.3): the samples this cluster minted under the previous
        // person carry the wrong voice — retire them (only once the relabel
        // landed), then re-match whatever matched on them (below).
        var retired: Set<Int64> = []
        if let previous = cluster.personID, previous != personID {
            retired = try retireSamplesMinted(db, transcriptID: transcriptID, cluster: cluster, personID: previous)
        }

        let alreadyAnchored = try VoiceSample
            .filter(Column("person_id") == personID && Column("transcript_id") == transcriptID
                && Column("cluster_label") == cluster.restoreLabel && Column("anchor") == true
                && Column("status") == VoiceSampleStatus.active.rawValue)
            .fetchCount(db) > 0
        if !alreadyAnchored, let normalized = VoiceMatcher.normalize(cluster.embedding) {
            var sample = VoiceSample(
                personID: personID,
                embedding: VoicePrintEmbedding.encode(normalized),
                modelVersion: cluster.modelVersion ?? VoiceRegistryPolicy.embeddingModelVersion,
                origin: .owner,
                anchor: true,
                status: .active,
                transcriptID: transcriptID,
                clusterLabel: cluster.restoreLabel,
                channel: cluster.channel ?? .unknown,
                speechSec: cluster.speechSec ?? 0)
            try VoiceSampleQueries.insert(db, &sample)
        }

        let task = try taskID.flatMap { try VoiceLabelTask.fetchOne(db, key: $0) }
        retired.formUnion(try settleImports(db, reason: task?.reason, cluster: cluster, personID: personID))
        if let taskID = task?.id { try VoiceLabelQueueQueries.resolveTask(db, id: taskID, status: .done) }

        _ = try revertOrphanedAutoLabels(db, removedSampleIDs: retired)
        return .labeled(personID: personID)
    }

    /// What a confirm of `cluster` as `personID` means for the rest of the
    /// registry. An `.importConfirm` or `.conflict` task activates that
    /// person's samples from the sender whose import claimed this voice (the
    /// nearest of theirs at ≥ `confident`, `VoiceMatcher.claimingPending`) —
    /// the owner sided with the import. Then the owner's newest explicit confirm wins for this
    /// voice (spec §5): every sample of SOMEONE ELSE at ≥ `importConflict` —
    /// pending imports, auto samples and owner anchors alike, but never the
    /// owner's own person (identified by their Google emails) — retires, so
    /// the voice is neither re-disputed nor stuck inside the margin in later
    /// meetings. Returns the retired ids, for the caller to re-match their
    /// dependents (`revertOrphanedAutoLabels`).
    private static func settleImports(
        _ db: Database,
        reason: VoiceLabelReason?,
        cluster: SpeakerEmbedding,
        personID: Int64
    ) throws -> Set<Int64> {
        let own = try VoiceSample
            .filter(Column("person_id") == personID && Column("status") == VoiceSampleStatus.pending.rawValue)
            .fetchAll(db)
        let activating: VoiceSample? = switch reason {
        case .importConfirm, .conflict:
            VoiceMatcher.claimingPending(embedding: cluster.embedding, samples: own, personID: personID)
        case .unsure, .unknown, .relabel, nil: nil
        }
        if let activating {
            try VoiceSampleQueries.activatePending(db, personID: personID, importID: activating.importID)
        }
        let ownerEmails = Set(try GoogleAccountQueries.fetchAll(db).map { $0.email.lowercased() }.filter { !$0.isEmpty })
        let owners = Set(try VoicePrintQueries.fetchAll(db)
            .filter { VoicePrintQueries.isOwner($0, ownerEmails: ownerEmails) }
            .compactMap(\.id))
        let contradicting = VoiceMatcher.contradictingSamples(
            embedding: cluster.embedding, samples: try VoiceSampleQueries.fetchUsable(db),
            confirmedPersonID: personID, exemptPersonIDs: owners)
        let ids = contradicting.compactMap(\.id)
        for id in ids { try VoiceSampleQueries.retire(db, id: id) }
        return Set(ids)
    }

    /// Dismisses a task without naming its cluster. `dontKnow`/`severalPeople`
    /// close the task `done` and mark the cluster `labelSource = .owner`
    /// (an unnamed "Speaker N" keeps its label — retro and future queues
    /// leave it alone); `severalPeople` additionally flags the cluster
    /// `mixed` so it is never learned from or relabeled. A NAMED cluster
    /// (a "Listen to samples" relabel card on "Alice") is the owner saying
    /// that name is wrong: it reverts to its pre-registry "Speaker N" (or a
    /// free one, for a legacy row that never recorded it), the samples it
    /// minted under that person retire, and their dependents re-match
    /// (spec §4.3) — the wrong name is never frozen as owner-set. `skip`
    /// leaves the task pending and writes nothing — the UI simply moves on
    /// to the next card.
    static func dismiss(_ db: Database, taskID: Int64, kind: DismissKind) throws {
        let mixed: Bool
        switch kind {
        case .skip: return
        case .dontKnow: mixed = false
        case .severalPeople: mixed = true
        }
        guard let task = try VoiceLabelTask.fetchOne(db, key: taskID) else { return }
        let markDismissed: (inout SpeakerEmbedding) -> Void = {
            $0.labelSource = .owner
            if mixed { $0.mixed = true }
        }
        if let transcript = try MeetingTranscriptQueries.fetch(db, id: task.transcriptID),
           let cluster = transcript.speakerEmbeddings?.first(where: { $0.speaker == task.clusterLabel }),
           !SpeakerNaming.isReserved(cluster.speaker) {
            try unname(db, transcript: transcript, cluster: cluster, patch: markDismissed)
        } else {
            try patchCluster(db, transcriptID: task.transcriptID, label: task.clusterLabel, markDismissed)
        }
        try VoiceLabelQueueQueries.resolveTask(db, id: taskID, status: .done)
    }

    /// Takes a wrong name off a named cluster: retires the samples it
    /// minted under its person, relabels it back to `restoreLabel` (or the
    /// first free "Speaker N" when that is not an unnamed label — a legacy
    /// row with no `original_label`), clears the registry link, applies
    /// `patch`, and re-matches every cluster that matched on a retired sample.
    private static func unname(
        _ db: Database,
        transcript: MeetingTranscript,
        cluster: SpeakerEmbedding,
        patch: (inout SpeakerEmbedding) -> Void
    ) throws {
        guard let transcriptID = transcript.id else { return }
        let unlink: (inout SpeakerEmbedding) -> Void = {
            $0.labelSource = VoiceLabelSource.none
            $0.personID = nil
            $0.matchedSampleID = nil
            $0.score = nil
            if let wrong = cluster.personID { $0.rejectPerson(wrong) }
            patch(&$0)
        }
        let free = freeUnnamedLabel(in: transcript)
        let target = SpeakerNaming.isUnnamed(cluster.restoreLabel) ? cluster.restoreLabel : free
        var relabeled = try MeetingTranscriptQueries.relabelCluster(
            db, id: transcriptID, from: cluster.speaker, to: target, patch: unlink)
        if !relabeled, target != free {
            // The original "Speaker N" is taken by another cluster — any free one will do.
            relabeled = try MeetingTranscriptQueries.relabelCluster(
                db, id: transcriptID, from: cluster.speaker, to: free, patch: unlink)
        }
        // A transcript that cannot be relabeled (no segments) keeps its text
        // and samples; the verdict still lands on the cluster so it is never
        // asked about again.
        guard relabeled else {
            try patchCluster(db, transcriptID: transcriptID, label: cluster.speaker, patch)
            return
        }
        var retired: Set<Int64> = []
        if let personID = cluster.personID {
            retired = try retireSamplesMinted(db, transcriptID: transcriptID, cluster: cluster, personID: personID)
        }
        _ = try revertOrphanedAutoLabels(db, removedSampleIDs: retired)
    }

    /// Retires the active `owner`/`auto` samples one cluster minted under
    /// `personID` (matched by the cluster's stable original label, the key
    /// every sample writer stamps). Returns their ids.
    private static func retireSamplesMinted(
        _ db: Database, transcriptID: Int64, cluster: SpeakerEmbedding, personID: Int64
    ) throws -> Set<Int64> {
        let ids = try Int64.fetchAll(
            db,
            sql: """
                SELECT id FROM voice_samples
                WHERE transcript_id = ? AND cluster_label = ? AND person_id = ?
                  AND origin IN ('owner', 'auto') AND status = 'active'
                """,
            arguments: [transcriptID, cluster.restoreLabel, personID])
        for id in ids { try VoiceSampleQueries.retire(db, id: id) }
        return Set(ids)
    }

    /// The lowest "Speaker N" no utterance or cluster of `transcript` uses.
    private static func freeUnnamedLabel(in transcript: MeetingTranscript) -> String {
        let used = Set((transcript.utterances ?? []).map(\.speaker) + (transcript.speakerEmbeddings ?? []).map(\.speaker))
        var n = 1
        while used.contains("Speaker \(n)") { n += 1 }
        return "Speaker \(n)"
    }

    /// Train-screen dismiss (spec §4.2): the same `dismiss(dontKnow:)`/
    /// `dismiss(severalPeople:)` write, but over a whole cross-meeting group
    /// at once and without a queue task (Train has none to close).
    static func dismissClusters(_ db: Database, members: [(transcriptID: Int64, clusterLabel: String)], severalPeople: Bool) throws {
        for member in members {
            try patchCluster(db, transcriptID: member.transcriptID, label: member.clusterLabel) {
                $0.labelSource = .owner
                if severalPeople { $0.mixed = true }
            }
        }
    }

    /// Rolls back a wrong auto label: reverts the cluster to its
    /// pre-registry "Speaker N" label, retires the auto sample that
    /// labeling it minted (so it can never be matched again), and — since
    /// that sample may have been the reason some OTHER cluster elsewhere
    /// auto-labeled the same person — re-matches every cluster that
    /// depended on it (`revertOrphanedAutoLabels`). The cluster remembers the
    /// rejected person (`rejectedPersonIDs`) so no retro pass re-applies them
    /// from their other samples. A rejected cluster whose
    /// transcript still has its audio file is enqueued as a fresh `.relabel`
    /// task so the owner gets another chance to name it. Returns how many
    /// clusters (this one plus any orphaned dependents) were reverted.
    /// No-op (returns 0) when the transcript/cluster is missing or the
    /// cluster wasn't auto-labeled.
    @discardableResult
    static func rejectAutoLabel(_ db: Database, transcriptID: Int64, clusterLabel: String) throws -> Int {
        guard let t = try MeetingTranscriptQueries.fetch(db, id: transcriptID),
              let c = t.speakerEmbeddings?.first(where: { $0.speaker == clusterLabel }), c.labelSource == .auto
        else { return 0 }

        let minted = try Int64.fetchAll(
            db,
            sql: """
                SELECT id FROM voice_samples
                WHERE transcript_id = ? AND cluster_label = ? AND origin = 'auto' AND status = 'active'
                """,
            arguments: [transcriptID, c.restoreLabel])
        for id in minted { try VoiceSampleQueries.retire(db, id: id) }

        // The owner's "Wrong" is remembered on the cluster, so a later retro
        // pass can never re-apply the same person from their other samples.
        let reverted = try revert(db, transcriptID: transcriptID, cluster: c) {
            if let wrong = c.personID { $0.rejectPerson(wrong) }
        }
        var n = reverted ? 1 : 0
        if FileManager.default.fileExists(atPath: t.audioPath ?? "") {
            try VoiceLabelQueueQueries.enqueue(
                db, transcriptID: transcriptID, clusterLabel: c.restoreLabel, reason: .relabel,
                suggestedPersonID: nil, score: nil)
        }
        n += try revertOrphanedAutoLabels(db, removedSampleIDs: Set(minted))
        return n
    }

    /// Deletes a registry person: every cluster the person was matched to
    /// loses that link — an auto-labeled cluster reverts to "Speaker N"
    /// (the label was the registry's own claim, which is now gone), while an
    /// owner-set cluster keeps its name as plain text (the owner typed it;
    /// deleting the person record must not un-name what they said) and only
    /// sheds its `personID`. Then deletes the person (their samples cascade)
    /// and re-matches every cluster elsewhere that depended on one of those
    /// samples. Returns how many clusters were reverted.
    @discardableResult
    static func deletePerson(_ db: Database, personID: Int64) throws -> Int {
        let sampleIDs = Set(try Int64.fetchAll(db, sql: "SELECT id FROM voice_samples WHERE person_id = ?", arguments: [personID]))
        var n = 0
        for (transcriptID, c) in try clusters(db, where: { $0.personID == personID }) {
            if c.labelSource == .auto {
                n += try revert(db, transcriptID: transcriptID, cluster: c) ? 1 : 0
            } else {
                try patchCluster(db, transcriptID: transcriptID, label: c.speaker) { $0.personID = nil }
            }
        }
        try VoicePrintQueries.delete(db, id: personID)
        return n + (try revertOrphanedAutoLabels(db, removedSampleIDs: sampleIDs))
    }

    /// Deletes an imported voice-print file: its samples cascade with it, and
    /// every cluster anywhere that was auto-labeled off one of them is
    /// re-matched against what remains. Returns how many clusters were
    /// reverted.
    @discardableResult
    static func deleteImport(_ db: Database, importID: Int64) throws -> Int {
        let sampleIDs = Set(try Int64.fetchAll(db, sql: "SELECT id FROM voice_samples WHERE import_id = ?", arguments: [importID]))
        try VoiceImportQueries.delete(db, id: importID)
        return try revertOrphanedAutoLabels(db, removedSampleIDs: sampleIDs)
    }

    /// Re-matches every `auto` cluster (in any transcript) whose
    /// `matchedSampleID` is one of `removedSampleIDs` — the sample it was
    /// matched to no longer exists (retired or deleted), so the match may no
    /// longer hold. A cluster that still confidently matches the SAME person
    /// on a remaining active sample just gets re-pointed at that sample
    /// (`matchedSampleID`/`score` updated, nothing else changes); anything
    /// less than that — a different person, or no confident match at all —
    /// reverts to "Speaker N". Never enqueues a labeling task: only the
    /// cluster `rejectAutoLabel` was called for gets that (its transcript is
    /// definitely open in the UI right now); an orphaned dependent elsewhere
    /// would surface as an unexplained new card. Returns how many clusters
    /// were reverted (a re-pointed cluster doesn't count — nothing there was
    /// undone).
    private static func revertOrphanedAutoLabels(_ db: Database, removedSampleIDs: Set<Int64>) throws -> Int {
        guard !removedSampleIDs.isEmpty else { return 0 }
        let active = try VoiceSampleQueries.fetchUsable(db).filter { $0.status == .active }
        var n = 0
        for (transcriptID, c) in try clusters(db, where: {
            $0.labelSource == .auto && removedSampleIDs.contains($0.matchedSampleID ?? -1)
        }) {
            let ranked = VoiceMatcher.nearest(embedding: c.embedding, samples: active)
            let top = ranked.first
            let stillSure = top.map {
                $0.personID == c.personID && $0.score >= VoiceRegistryPolicy.confident
                    && $0.score - (ranked.dropFirst().first?.score ?? -1) >= VoiceRegistryPolicy.margin
            } ?? false
            if stillSure, let top {
                try patchCluster(db, transcriptID: transcriptID, label: c.speaker) {
                    $0.matchedSampleID = top.sampleID
                    $0.score = top.score
                }
            } else if try revert(db, transcriptID: transcriptID, cluster: c) {
                n += 1
            }
        }
        return n
    }

    /// Reverts one cluster to its pre-registry label and clears the
    /// registry fields a label carries, via `relabelCluster` (so the
    /// transcript text/segments stay in sync too, the D1 invariant).
    /// `also` applies extra fields in the same write.
    private static func revert(
        _ db: Database,
        transcriptID: Int64,
        cluster c: SpeakerEmbedding,
        also: (inout SpeakerEmbedding) -> Void = { _ in }
    ) throws -> Bool {
        try MeetingTranscriptQueries.relabelCluster(db, id: transcriptID, from: c.speaker, to: c.restoreLabel) {
            // `VoiceLabelSource.none`, not `Optional.none` — the "no label
            // source" case, spelled out to avoid the ambiguity `.none` would
            // have against `VoiceLabelSource?`.
            $0.labelSource = VoiceLabelSource.none
            $0.personID = nil
            $0.matchedSampleID = nil
            $0.score = nil
            also(&$0)
        }
    }

    /// Every `(transcriptID, cluster)` pair across all transcripts matching
    /// `match`, read fresh from the DB — never a caller-held snapshot, since
    /// an earlier rollback step in the same call may have already changed a
    /// cluster a later step needs to see.
    private static func clusters(
        _ db: Database, where match: (SpeakerEmbedding) -> Bool
    ) throws -> [(Int64, SpeakerEmbedding)] {
        let sql = "SELECT id FROM meeting_transcripts WHERE speakers_json IS NOT NULL"
        return try Row.fetchAll(db, sql: sql).flatMap { row -> [(Int64, SpeakerEmbedding)] in
            let transcriptID: Int64 = row["id"]
            let clusters = try MeetingTranscriptQueries.fetch(db, id: transcriptID)?.speakerEmbeddings ?? []
            return clusters.filter(match).map { (transcriptID, $0) }
        }
    }

    /// Patches one or more `SpeakerEmbedding` fields on the cluster labeled
    /// `label`, rewriting only `speakers_json` — no segments/transcript_text
    /// touch, since the label text itself isn't changing here (that's
    /// `relabelCluster`'s job). No-op when the transcript, its
    /// `speakers_json`, or the label is missing.
    private static func patchCluster(_ db: Database, transcriptID: Int64, label: String, _ patch: (inout SpeakerEmbedding) -> Void) throws {
        guard let transcript = try MeetingTranscriptQueries.fetch(db, id: transcriptID),
              let json = transcript.speakersJSON,
              var speakers = SpeakerEmbeddings.decode(json)
        else { return }
        for index in speakers.indices where speakers[index].speaker == label { patch(&speakers[index]) }
        guard let reencoded = SpeakerEmbeddings.encode(speakers) else {
            throw MeetingTranscriptQueryError.speakerEncodeFailed
        }
        try db.execute(sql: "UPDATE meeting_transcripts SET speakers_json = ? WHERE id = ?",
                       arguments: [reencoded, transcriptID])
    }
}
