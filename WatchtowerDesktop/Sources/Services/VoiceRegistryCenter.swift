import CryptoKit
import Foundation
import GRDB
import WatchtowerCore

/// Thrown by the Task 15 import/export center methods (design spec §5) —
/// deliberately `throws` rather than routed through `lastError`, so the
/// Export/Import sheets can show the failure inline next to the field that
/// caused it instead of the window-wide error banner.
enum VoiceExportImportError: LocalizedError {
    case databaseUnavailable
    case noPendingImport
    /// `VoiceImportQueries.apply` wrote nothing: the file was imported
    /// meanwhile (a race with another import of the same file) or its voice
    /// model no longer matches.
    case importRefused

    var errorDescription: String? {
        switch self {
        case .databaseUnavailable: return "The voice registry database isn't available."
        case .noPendingImport: return "Preview the file before importing."
        case .importRefused: return "Nothing was imported: this file was already imported or uses a different voice model."
        }
    }
}

/// App-wide, single-slot registry backing the Voices window: the owner's
/// voice-labeling queue (`voice_label_queue`), plus the confirm/dismiss/
/// relabel transactions and the automatic catch-up pass. State lives here
/// (never view-local) so an in-progress queue survives the window being
/// closed and reopened (the `MeetingRecorderCenter`/`TargetExtractCenter`
/// "survives navigation" pattern).
@MainActor
@Observable
final class VoiceRegistryCenter {
    /// Which Voices window screen is showing. `.queue` optionally scopes to
    /// one transcript (opened from a recording's detail); `nil` means the
    /// app-wide queue across every recording.
    enum VoicesWindowMode: Equatable {
        case queue(transcriptID: Int64?)
        case review
        case train
    }

    /// One registry person, or an event attendee not yet in the registry —
    /// the choices offered when naming a card's cluster.
    struct PersonChoice: Hashable {
        let personKey: String
        let displayName: String
        let inRegistry: Bool
    }

    /// One pending labeling task, joined with its transcript and candidates —
    /// everything a Voices queue row needs to render and act, in one shot.
    struct VoiceCard: Identifiable, Equatable {
        /// `voice_label_queue.id`.
        let id: Int64
        let transcriptID: Int64
        let meetingTitle: String
        let date: String
        let clusterLabel: String
        let reason: VoiceLabelReason
        let suggestion: VoicePrint?
        let score: Float?
        let clips: [ClipSpan]
        /// The words spoken inside each clip (same order as `clips`, see
        /// `ClipTranscript`), built from the transcript's own segments —
        /// never a re-transcribe.
        let clipTexts: [String]
        let audioPath: String
        let candidates: [PersonChoice]
    }

    /// One Review-screen spot check (spec §3.2): an `auto`-labeled cluster
    /// offered back to the owner as "still correct?" — the 3 latest per
    /// person, recording still has audio. `id` is `"<transcriptID>:<clusterLabel>"`,
    /// unique because a transcript never carries two clusters with the same
    /// rendered label (`MeetingTranscriptQueries.relabelCluster` refuses one).
    struct VoiceSpotCheck: Identifiable, Equatable {
        let id: String
        let transcriptID: Int64
        let clusterLabel: String
        let personID: Int64
        let clips: [ClipSpan]
        let audioPath: String
        let meetingTitle: String
    }

    /// One Train-screen card (spec §4.2): a cross-meeting voice group,
    /// live-regrouped on every `loadTrain`. `members` is every cluster in the
    /// group, including ones from audio-less recordings (rendered only as a
    /// "+N meetings without audio" line); `audioMembers` is the playable
    /// subset — a group is dropped entirely when this is empty. `suggestion`
    /// is either the nearest registry person (close but not yet confident) or
    /// the most-frequent not-yet-registered attendee across the group's
    /// meetings; `hint` is the matching prose for it, empty when neither
    /// applies.
    struct TrainGroup: Identifiable {
        let id: String
        let members: [GroupableCluster]
        let audioMembers: [GroupableCluster]
        let suggestion: PersonChoice?
        let hint: String
        let speechMin: Double
    }

    /// The Train screen's quality header (spec §4.2): named speech split by
    /// who named it, an accuracy estimate on the owner's own anchors at the
    /// current threshold, and registry size/coverage counts.
    struct TrainQuality: Equatable {
        let namedMinutes: Double
        let ownerMinutes: Double
        let autoMinutes: Double
        let precision: Double
        let recall: Double
        let people: Int
        let singleChannelPeople: Int
    }

    /// Playback for one audio `TrainGroup` member, keyed by its
    /// `GroupableCluster.key` — kept off `GroupableCluster` itself (a pure,
    /// test-fixture-shaped type with no file paths) the same way `VoiceCard`
    /// keeps `audioPath` next to, not inside, its clips.
    struct TrainClip: Equatable {
        let audioPath: String
        let clips: [ClipSpan]
        let clipTexts: [String]
    }

    var pendingCount: Int = 0
    var cards: [VoiceCard] = []
    /// Review screen (Task 13) state — populated by `loadReview`.
    var people: [VoicePersonSummary] = []
    var imports: [VoiceImport] = []
    var spotChecks: [VoiceSpotCheck] = []
    /// Train screen (Task 14) state — populated by `loadTrain`.
    var groups: [TrainGroup] = []
    var quality = TrainQuality(namedMinutes: 0, ownerMinutes: 0, autoMinutes: 0, precision: 1, recall: 1, people: 0, singleChannelPeople: 0)
    var trainClips: [String: TrainClip] = [:]
    /// Every registry person as a picker candidate — a Train group's picker
    /// isn't scoped to one meeting's attendees the way a queue card's is, so
    /// it offers the whole registry instead.
    var registryChoices: [PersonChoice] = []
    var mode: VoicesWindowMode = .queue(transcriptID: nil)
    var lastError: String?

    /// The file most recently previewed by `previewImport`, held until
    /// `applyImport()` commits it (or the sheet is dismissed and this is
    /// just dropped) — `apply` needs the decrypted payload again, and
    /// re-deriving it would mean asking for the password a second time.
    private(set) var pendingImport: (payload: VoiceExportPayload, fileSHA256: String)?

    /// Opens the Voices window. Set once the window scene exists (Task 12);
    /// a nil value (window not yet built, or closed) just skips the open —
    /// every other center method still runs and updates state normally, so
    /// state is never lost while the window is closed.
    var openWindow: (() -> Void)?

    private var dbPool: DatabasePool?

    func attach(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    /// Refreshes the pending-count badge from the DB and drops every shown
    /// card whose task is no longer pending (auto-closed by
    /// `closeResolvedTasks` after a retro pass named its voice elsewhere).
    /// Cheap — ids only, no card join.
    func refresh() async {
        guard let dbPool else { return }
        do {
            let pendingIDs = try await dbPool.read { db in
                Set(try VoiceLabelQueueQueries.pending(db).compactMap(\.id))
            }
            pendingCount = pendingIDs.count
            cards.removeAll { !pendingIDs.contains($0.id) }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Switches to `mode`; for `.queue` this also (re)loads `cards`, and for
    /// `.review` `people`/`imports`/`spotChecks`, fresh from the DB, so
    /// reopening the window after a close never serves a stale snapshot.
    /// Then opens the window.
    func open(_ mode: VoicesWindowMode) async {
        self.mode = mode
        switch mode {
        case let .queue(transcriptID):
            await loadQueueCards(transcriptID: transcriptID)
        case .review:
            await loadReview()
        case .train:
            await loadTrain()
        }
        openWindow?()
    }

    // MARK: - Review (spec §3.2)

    /// Loads the Review screen's three lists fresh from the DB.
    func loadReview() async {
        guard let dbPool else { return }
        do {
            (people, imports, spotChecks) = try await dbPool.read { db in
                (try VoiceSampleQueries.personSummaries(db),
                 try VoiceImportQueries.fetchAll(db),
                 try Self.buildSpotChecks(db))
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The owner's verdict on one spot check. `correct` writes nothing — a
    /// spot check has no "verified" flag to persist (spec §3.2: review is
    /// on demand only, never scheduled or remembered); it just drops the
    /// item from this screen's list for now. `false` rolls the label back
    /// (`VoiceLabelingQueries.rejectAutoLabel`, which also enqueues a fresh
    /// `.relabel` task when the recording's audio still exists) and then
    /// reloads the whole Review screen, since a rollback can revert OTHER
    /// clusters/people too (`revertOrphanedAutoLabels`).
    func spotCheck(_ check: VoiceSpotCheck, correct: Bool) async {
        guard let dbPool else { return }
        guard !correct else {
            spotChecks.removeAll { $0.id == check.id }
            return
        }
        do {
            _ = try await dbPool.write { db in
                try VoiceLabelingQueries.rejectAutoLabel(db, transcriptID: check.transcriptID, clusterLabel: check.clusterLabel)
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            return
        }
        await loadReview()
    }

    /// Deletes a registry person (spec §4.3: their samples go, auto labels
    /// revert, owner-set names stay as text) and reloads the Review screen.
    func deletePerson(_ id: Int64) async {
        guard let dbPool else { return }
        do {
            _ = try await dbPool.write { db in try VoiceLabelingQueries.deletePerson(db, personID: id) }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            return
        }
        await loadReview()
    }

    /// Deletes an import and everything it brought (spec §4.3) and reloads
    /// the Review screen.
    func deleteImport(_ id: Int64) async {
        guard let dbPool else { return }
        do {
            _ = try await dbPool.write { db in try VoiceLabelingQueries.deleteImport(db, importID: id) }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            return
        }
        await loadReview()
    }

    /// Names the card's cluster. `.labeled` also runs the retro relabeler for
    /// just that person, so every earlier recording of theirs lights up in
    /// the same stroke. `.alreadyLabeled`/`.stale` mean nothing was written —
    /// the card is stale (relabeled elsewhere, or the transcript/cluster is
    /// gone) and is simply dropped from the queue.
    func confirm(_ card: VoiceCard, person: PersonChoice) async {
        guard let dbPool else { return }
        do {
            let result = try await dbPool.write { db in
                try VoiceLabelingQueries.confirm(
                    db, taskID: card.id, transcriptID: card.transcriptID, clusterLabel: card.clusterLabel,
                    personKey: person.personKey, displayName: person.displayName)
            }
            switch result {
            case let .labeled(personID):
                _ = try await dbPool.write { db in
                    try VoiceRetroRelabeler.run(db, onlyPersonID: personID)
                }
                removeCard(card)
                lastError = nil
            case .alreadyLabeled, .stale:
                removeCard(card)
                lastError = "This voice was already labeled"
            case let .nameTaken(name):
                lastError = "\(name) is already a speaker in this recording — choose another name"
            }
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
    }

    /// Dismisses the card without naming its cluster. `.skip` writes nothing
    /// and just moves the card to the end of the queue — the UI simply comes
    /// back to it later; the other kinds close the task and drop the card.
    func dismiss(_ card: VoiceCard, _ kind: DismissKind) async {
        guard let dbPool else { return }
        do {
            try await dbPool.write { db in
                try VoiceLabelingQueries.dismiss(db, taskID: card.id, kind: kind)
            }
            if kind == .skip {
                moveToEnd(card)
            } else {
                removeCard(card)
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
    }

    /// Re-queues a cluster for naming (the rename-picker "not right, relabel"
    /// path) and reopens the queue scoped to that transcript so the fresh
    /// card is immediately visible.
    func relabel(transcriptID: Int64, clusterLabel: String) async {
        guard let dbPool else { return }
        do {
            try await dbPool.write { db in
                try VoiceLabelQueueQueries.enqueue(
                    db, transcriptID: transcriptID, clusterLabel: clusterLabel, reason: .relabel,
                    suggestedPersonID: nil, score: nil)
            }
        } catch {
            lastError = error.localizedDescription
            return
        }
        await open(.queue(transcriptID: transcriptID))
    }

    /// Launch catch-up (spec §4.1): skips every queued task whose recording
    /// lost its audio, then runs a FULL retro relabel pass over the whole
    /// registry. Retro's three triggers are deliberately narrow — an owner
    /// confirmation (`confirm`, person-scoped), an import person activated,
    /// and app launch (this) — a new meeting's freshly-minted auto samples
    /// do NOT trigger it (`refreshAfterSave` below is what a save runs
    /// instead). Runs once per DB open (`AppState`). With "Voice
    /// recognition" off (`voiceRecognition: false`, spec §6) the retro half
    /// is skipped — no identification — while the queue housekeeping still
    /// runs. The retro pass writes one transaction per transcript
    /// (`VoiceRetroRelabeler.run(in:)`), never one over the whole history.
    func catchUp(voiceRecognition: Bool = true) async {
        guard let dbPool else { return }
        do {
            try await dbPool.write { db in try VoiceLabelQueueQueries.skipTasksWithoutAudio(db) }
            if voiceRecognition {
                try await VoiceRetroRelabeler.run(in: dbPool)
            }
            try await dbPool.write { db in try VoiceLabelQueueQueries.closeResolvedTasks(db) }
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
    }

    /// What runs after a meeting-recorder save lands (spec §4.1):
    /// housekeeping only, deliberately no retro pass. A save mints fresh
    /// auto samples/queue tasks, but minting one is not itself a retro
    /// trigger — relabeling other recordings off an unconfirmed sample here
    /// would retroactively name them from something the owner never vetted.
    func refreshAfterSave() async {
        guard let dbPool else { return }
        do {
            try await dbPool.write { db in
                try VoiceLabelQueueQueries.skipTasksWithoutAudio(db)
                try VoiceLabelQueueQueries.closeResolvedTasks(db)
            }
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
    }

    // MARK: - Train (spec §4.2)

    /// Loads the Train screen fresh from the DB: every unnamed cluster,
    /// cross-meeting grouped (`VoiceGrouping.group`), with a suggestion and
    /// the quality header. Called after every confirm/dismiss too (live
    /// regrouping) — a labeled cluster drops out of the candidate pool and a
    /// resolved group simply stops being returned.
    func loadTrain() async {
        guard let dbPool else { return }
        do {
            (groups, quality, trainClips, registryChoices) = try await dbPool.read { db in try Self.buildTrain(db) }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Names every cluster of the group as `person` in one transaction: each
    /// audio member goes through `VoiceLabelingQueries.confirm` (mints an
    /// owner anchor from its own embedding, same as a queue confirm), each
    /// audio-less member is relabeled directly (no anchor — there is no clip
    /// to have vouched for it). Then runs the retro relabeler scoped to this
    /// person, so every other recording of theirs lights up too, and reloads
    /// (live regrouping).
    ///
    /// Every member's write is checked — the queue's `confirm` precedent. A
    /// member whose cluster was relabeled by something else in the meantime
    /// (`.alreadyLabeled`/`.stale`, or a `relabelCluster` that returns
    /// `false`) still lets the rest of the group commit, but is counted and
    /// surfaced as a partial-failure `lastError` rather than silently
    /// swallowed. The count/error are applied AFTER `loadTrain()` — a bare
    /// `lastError = …` before it would just be overwritten by `loadTrain`'s
    /// own (successful) `lastError = nil`.
    func confirmGroup(_ group: TrainGroup, person: PersonChoice) async {
        guard let dbPool else { return }
        let name = person.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !SpeakerNaming.isReserved(name) else {
            lastError = "Choose a valid name"
            return
        }
        var failed = 0
        var writeError: Error?
        do {
            failed = try await dbPool.write { db -> Int in
                // `findOrCreate` is idempotent on `personKey` — this never
                // renames an existing person, it just resolves the id every
                // member below labels against.
                let resolved = try VoicePrintQueries.findOrCreate(db, personKey: person.personKey, displayName: name)
                guard let personID = resolved.id else { return group.members.count }

                var failed = 0
                for member in group.audioMembers {
                    let result = try VoiceLabelingQueries.confirm(
                        db, taskID: nil, transcriptID: member.transcriptID, clusterLabel: member.label,
                        personKey: person.personKey, displayName: resolved.displayName)
                    switch result {
                    case .labeled: break
                    case .alreadyLabeled, .stale, .nameTaken: failed += 1
                    }
                }
                for member in group.members where !member.hasAudio {
                    let relabeled = try MeetingTranscriptQueries.relabelCluster(
                        db, id: member.transcriptID, from: member.label, to: resolved.displayName
                    ) {
                        $0.labelSource = .owner
                        $0.personID = personID
                        $0.matchedSampleID = nil
                        $0.score = nil
                        $0.clearRejection(of: personID)
                    }
                    if !relabeled { failed += 1 }
                }
                try VoiceRetroRelabeler.run(db, onlyPersonID: personID)
                // A member named here may have had its own queue task.
                try VoiceLabelQueueQueries.closeResolvedTasks(db)
                return failed
            }
        } catch {
            writeError = error
        }
        await loadTrain()
        await refresh()
        if let writeError {
            lastError = writeError.localizedDescription
        } else if failed > 0 {
            lastError = "\(failed) of \(group.members.count) voices were already labeled"
        }
    }

    /// Dismisses a group without naming it. `severalPeople` flags every
    /// member `mixed` (never learned from or relabeled again — spec §4.2's
    /// "a 'Several people' group is dissolved and its clusters are regrouped
    /// more strictly next time," which just falls out of the candidate filter
    /// excluding `mixed` clusters on the next `loadTrain`); otherwise every
    /// member is marked owner-dismissed (keeps its "Speaker N" label, stops
    /// resurfacing here). Reloads either way; a write error is applied AFTER
    /// `loadTrain()` for the same reason as `confirmGroup`'s.
    func dismissGroup(_ group: TrainGroup, severalPeople: Bool) async {
        guard let dbPool else { return }
        var writeError: Error?
        do {
            try await dbPool.write { db in
                try VoiceLabelingQueries.dismissClusters(
                    db, members: group.members.map { ($0.transcriptID, $0.label) }, severalPeople: severalPeople)
            }
        } catch {
            writeError = error
        }
        await loadTrain()
        if let writeError {
            lastError = writeError.localizedDescription
        }
    }

    // MARK: - Import / export (spec §5)

    /// Encrypts `personIDs`' exportable samples (invariant 4: `owner`/`auto`,
    /// `active`, current model version only) to `url`, sealed with
    /// `password`. Sender identity is this machine's own owner (`OwnerQueries`),
    /// so a recipient can tell whose file they're looking at. Written to a
    /// temp file next to `url` then atomically moved into place — `url`
    /// never observes a partial write.
    func export(to url: URL, password: String, personIDs: Set<Int64>) async throws {
        guard let dbPool else { throw VoiceExportImportError.databaseUnavailable }
        let payload = try await dbPool.read { db -> VoiceExportPayload in
            let owner = try OwnerQueries.resolve(db)
            let sender = VoiceExportPayload.Sender(name: owner.displayName, email: owner.email)
            return try VoiceImportQueries.buildExport(db, sender: sender, personIDs: personIDs)
        }
        // PBKDF2 (200k rounds) + AES-GCM + the file write run off the main
        // actor — they take long enough to stall the UI.
        try await Task.detached(priority: .userInitiated) {
            let sealed = try VoiceExportCodec.seal(payload, password: password)
            let tempURL = url.appendingPathExtension("tmp")
            try sealed.write(to: tempURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        }.value
    }

    /// Decrypts `url` with `password` and reports what importing it would do
    /// (design spec §5), without writing anything. Holds the decrypted
    /// payload for a follow-up `applyImport()` — the owner shouldn't have to
    /// re-type the password to commit what they just previewed.
    func previewImport(url: URL, password: String) async throws -> VoiceImportPreview {
        // A new preview always starts clean: a failed one must never leave
        // an earlier file's decrypted payload armed for `applyImport`.
        pendingImport = nil
        guard let dbPool else { throw VoiceExportImportError.databaseUnavailable }
        // File read, SHA-256 and PBKDF2/AES-GCM open run off the main actor.
        let (payload, fileSHA256) = try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: url)
            let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            return (try VoiceExportCodec.open(data, password: password), sha)
        }.value
        let preview = try await dbPool.read { db in
            try VoiceImportQueries.preview(db, payload: payload, fileSHA256: fileSHA256, ownerEmails: try Self.ownerEmails(db))
        }
        pendingImport = (payload, fileSHA256)
        return preview
    }

    /// Commits the file most recently reported by `previewImport` (design
    /// spec §5: preview → one transaction) and reloads the Review screen so
    /// the new import shows up immediately. Throws `noPendingImport` if
    /// called without a preview first — the Import sheet never allows that
    /// (its Import button stays disabled until a preview lands).
    func applyImport() async throws {
        guard let dbPool else { throw VoiceExportImportError.databaseUnavailable }
        guard let pending = pendingImport else { throw VoiceExportImportError.noPendingImport }
        let importID = try await dbPool.write { db in
            try VoiceImportQueries.apply(db, payload: pending.payload, fileSHA256: pending.fileSHA256, ownerEmails: try Self.ownerEmails(db))
        }
        pendingImport = nil
        guard importID != nil else { throw VoiceExportImportError.importRefused }
        await loadReview()
    }

    /// Drops the decrypted payload `previewImport` holds — the Import sheet
    /// calls this when it closes (Cancel, or dismissed any other way) or a
    /// different file is chosen, so decrypted embeddings never outlive the
    /// sheet that asked for them.
    func discardPendingImport() {
        pendingImport = nil
    }

    /// The owner's connected Google emails — the set import/export use to
    /// recognize (and skip, on import) the owner's own identity (invariant 2).
    nonisolated private static func ownerEmails(_ db: Database) throws -> Set<String> {
        Set(try GoogleAccountQueries.fetchAll(db).map { $0.email.lowercased() }.filter { !$0.isEmpty })
    }

    // MARK: - Queue loading

    private func loadQueueCards(transcriptID: Int64?) async {
        guard let dbPool else { return }
        do {
            cards = try await dbPool.read { db in try Self.buildCards(db, transcriptID: transcriptID) }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
    }

    /// One card per pending task whose recording still has clean-speech clips
    /// AND a still-present audio file — an audio-less task is caught by
    /// `catchUp`'s `skipTasksWithoutAudio` sweep already, but a card is never
    /// built for one regardless (defense in depth: nothing to play back).
    nonisolated private static func buildCards(_ db: Database, transcriptID: Int64?) throws -> [VoiceCard] {
        let tasks = try VoiceLabelQueueQueries.pending(db, transcriptID: transcriptID)
        guard !tasks.isEmpty else { return [] }
        let people = try VoicePrintQueries.fetchAll(db)

        var cards: [VoiceCard] = []
        for task in tasks {
            guard let taskID = task.id else { continue }
            guard let transcript = try MeetingTranscriptQueries.fetch(db, id: task.transcriptID) else { continue }
            guard let audioPath = transcript.audioPath, !audioPath.isEmpty,
                  FileManager.default.fileExists(atPath: audioPath) else { continue }
            guard let cluster = transcript.speakerEmbeddings?.first(where: { $0.speaker == task.clusterLabel }) else { continue }
            guard let clips = cluster.clips, !clips.isEmpty else { continue }

            let utterances = transcript.utterances ?? []
            let clipTexts = clips.map { ClipTranscript.text(for: $0, speaker: task.clusterLabel, utterances: utterances) }

            var suggestion: VoicePrint?
            if let suggestedID = task.suggestedPersonID {
                suggestion = try VoicePrintQueries.fetch(db, id: suggestedID)
            }

            var attendees: [EventAttendee] = []
            if let eventID = transcript.eventID, let event = try CalendarQueries.fetchEvent(db, id: eventID) {
                attendees = event.attendeesIncludingOrganizer
            }

            cards.append(VoiceCard(
                id: taskID,
                transcriptID: task.transcriptID,
                meetingTitle: transcript.title,
                date: transcript.createdAt,
                clusterLabel: task.clusterLabel,
                reason: task.reason,
                suggestion: suggestion,
                score: task.score,
                clips: clips,
                clipTexts: clipTexts,
                audioPath: audioPath,
                candidates: candidateChoices(attendees: attendees, people: people)))
        }
        return cards
    }

    /// The Review screen's spot checks (spec §3.2): per person, the 3 latest
    /// `auto`-labeled clusters — recording still has audio AND clips, an
    /// owner-set (`label_source: owner`/`none`) cluster never qualifies.
    /// Scans every transcript with `speakers_json`, the `VoiceLabelingQueries`
    /// full-scan precedent (there is no index over `label_source`).
    nonisolated private static func buildSpotChecks(_ db: Database) throws -> [VoiceSpotCheck] {
        struct Candidate {
            let transcriptID: Int64
            let meetingTitle: String
            let audioPath: String
            let createdAt: String
            let cluster: SpeakerEmbedding
        }

        let rows = try Row.fetchAll(db, sql: "SELECT id, audio_path FROM meeting_transcripts WHERE speakers_json IS NOT NULL")
        var byPerson: [Int64: [Candidate]] = [:]
        for row in rows {
            let audioPath: String? = row["audio_path"]
            guard let audioPath, !audioPath.isEmpty, FileManager.default.fileExists(atPath: audioPath) else { continue }
            let transcriptID: Int64 = row["id"]
            guard let transcript = try MeetingTranscriptQueries.fetch(db, id: transcriptID) else { continue }
            for cluster in transcript.speakerEmbeddings ?? [] {
                guard cluster.labelSource == .auto, let personID = cluster.personID,
                      let clips = cluster.clips, !clips.isEmpty else { continue }
                byPerson[personID, default: []].append(Candidate(
                    transcriptID: transcriptID, meetingTitle: transcript.title, audioPath: audioPath,
                    createdAt: transcript.createdAt, cluster: cluster))
            }
        }

        var checks: [VoiceSpotCheck] = []
        for personID in byPerson.keys.sorted() {
            let latest = byPerson[personID, default: []].sorted { $0.createdAt > $1.createdAt }.prefix(3)
            for candidate in latest {
                checks.append(VoiceSpotCheck(
                    id: "\(candidate.transcriptID):\(candidate.cluster.speaker)",
                    transcriptID: candidate.transcriptID,
                    clusterLabel: candidate.cluster.speaker,
                    personID: personID,
                    clips: candidate.cluster.clips ?? [],
                    audioPath: candidate.audioPath,
                    meetingTitle: candidate.meetingTitle))
            }
        }
        return checks
    }

    /// The Train screen (spec §4.2): every unrecognized, un-mixed, long-enough
    /// cluster across every transcript (audio or not — an audio-less one only
    /// ever surfaces as a "+N" tally on whichever group it joins), grouped
    /// cross-meeting, each group given a suggestion, plus the quality header
    /// tallied over every cluster (not just the candidates).
    nonisolated private static func buildTrain(_ db: Database) throws -> ([TrainGroup], TrainQuality, [String: TrainClip], [PersonChoice]) {
        let people = try VoicePrintQueries.fetchAll(db)
        let peopleByID = Dictionary(uniqueKeysWithValues: people.compactMap { p in p.id.map { ($0, p) } })
        let registeredKeys = Set(people.map { normalizedKey($0.personKey) })
        let activeSamples = try VoiceSampleQueries.fetchUsable(db).filter { $0.status == .active }

        let scan = try scanTrainCandidates(db)
        let trainGroups = buildTrainGroups(
            clusters: scan.clusters, attendeeNames: scan.attendeeNames,
            peopleByID: peopleByID, registeredKeys: registeredKeys, activeSamples: activeSamples)

        let ownerMinutes = (scan.speechByLabelSource[.owner] ?? 0) / 60
        let autoMinutes = (scan.speechByLabelSource[.auto] ?? 0) / 60
        let accuracy = VoiceGrouping.estimateAccuracy(anchors: activeSamples.filter { $0.origin == .owner && $0.anchor })
        let singleChannelPeople = try VoiceSampleQueries.personSummaries(db)
            .filter { $0.channels.count == 1 && $0.channels.first != .unknown }.count

        let quality = TrainQuality(
            namedMinutes: ownerMinutes + autoMinutes, ownerMinutes: ownerMinutes, autoMinutes: autoMinutes,
            precision: accuracy.precision, recall: accuracy.recall, people: people.count, singleChannelPeople: singleChannelPeople)
        let registryChoices = people
            .map { PersonChoice(personKey: $0.personKey, displayName: $0.displayName, inRegistry: true) }
            .sorted(by: byDisplayName)
        return (trainGroups, quality, scan.clipsByKey, registryChoices)
    }

    /// Every transcript's unrecognized clusters as `GroupableCluster`s (spec
    /// §4.2 step 1) plus the raw material the quality header and clip
    /// playback are built from: total speech per `label_source` (tallied
    /// over EVERY cluster, not just the candidates) and, for a candidate that
    /// still has audio, its playable clips.
    nonisolated private static func scanTrainCandidates(_ db: Database) throws -> (
        clusters: [GroupableCluster], attendeeNames: [String: String],
        speechByLabelSource: [VoiceLabelSource: Double], clipsByKey: [String: TrainClip]
    ) {
        // Newest first, so the candidate cap keeps the most recent voices.
        let rows = try Row.fetchAll(db, sql: "SELECT id FROM meeting_transcripts WHERE speakers_json IS NOT NULL ORDER BY id DESC")
        var clusters: [GroupableCluster] = []
        var attendeeNames: [String: String] = [:]
        var speechByLabelSource: [VoiceLabelSource: Double] = [:]
        var clipsByKey: [String: TrainClip] = [:]

        for row in rows {
            let transcriptID: Int64 = row["id"]
            guard let transcript = try MeetingTranscriptQueries.fetch(db, id: transcriptID),
                  let speakers = transcript.speakerEmbeddings else { continue }

            let hasAudio = transcript.audioPath.map { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) } ?? false

            var attendeeKeys: Set<String> = []
            if let eventID = transcript.eventID, let event = try CalendarQueries.fetchEvent(db, id: eventID) {
                for attendee in event.attendeesIncludingOrganizer {
                    let name = attendee.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let email = attendee.email.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty || !email.isEmpty else { continue }
                    let key = normalizedKey(email.isEmpty ? name : email)
                    attendeeKeys.insert(key)
                    if attendeeNames[key] == nil { attendeeNames[key] = name.isEmpty ? email : name }
                }
            }

            let utterances = transcript.utterances ?? []
            for speaker in speakers {
                let speechSec = speaker.speechSec ?? VoiceRegistryPolicy.minClusterSpeechSec
                speechByLabelSource[speaker.effectiveLabelSource, default: 0] += speechSec

                guard speaker.effectiveLabelSource == .none, speaker.mixed != true,
                      speaker.speechSec.map({ $0 >= VoiceRegistryPolicy.minClusterSpeechSec }) ?? true,
                      clusters.count < VoiceRegistryPolicy.trainCandidateCap
                else { continue }

                let key = "\(transcriptID):\(speaker.speaker)"
                clusters.append(GroupableCluster(
                    key: key, transcriptID: transcriptID, label: speaker.speaker,
                    embedding: speaker.embedding, speechSec: speechSec, hasAudio: hasAudio, attendees: attendeeKeys))

                if hasAudio, let audioPath = transcript.audioPath, !audioPath.isEmpty,
                   let clips = speaker.clips, !clips.isEmpty {
                    let clipTexts = clips.map { ClipTranscript.text(for: $0, speaker: speaker.speaker, utterances: utterances) }
                    clipsByKey[key] = TrainClip(audioPath: audioPath, clips: clips, clipTexts: clipTexts)
                }
            }
        }
        return (clusters, attendeeNames, speechByLabelSource, clipsByKey)
    }

    /// Cross-meeting groups, dropped when they have no audio member, each
    /// with a suggestion (spec §4.2 steps 2-3).
    nonisolated private static func buildTrainGroups(
        clusters: [GroupableCluster],
        attendeeNames: [String: String],
        peopleByID: [Int64: VoicePrint],
        registeredKeys: Set<String>,
        activeSamples: [VoiceSample]
    ) -> [TrainGroup] {
        var trainGroups: [TrainGroup] = []
        for members in VoiceGrouping.group(clusters) {
            let audioMembers = members.filter(\.hasAudio)
            guard !audioMembers.isEmpty else { continue }

            // Spec §4.2 step 3: "the nearest registry person if CLOSE BUT
            // BELOW CONFIDENT" — a match that already clears `confident`
            // would have been auto-labeled by retro already (this cluster
            // wouldn't be a Train candidate at all), so the upper bound is
            // defense in depth, not just cosmetic: without it a stale-race
            // cluster sitting between retro passes could suggest a "match"
            // the owner should really just be seeing confirmed already.
            var suggestion: PersonChoice?
            var hint = ""
            if let match = nearestRegistryMatch(members, samples: activeSamples),
               match.score >= VoiceRegistryPolicy.unsureFloor, match.score < VoiceRegistryPolicy.confident,
               let person = peopleByID[match.personID] {
                hint = "Looks like \(person.displayName), \(String(format: "%.2f", match.score))"
                suggestion = PersonChoice(personKey: person.personKey, displayName: person.displayName, inRegistry: true)
            } else if let attendee = VoiceGrouping.suggestion(for: members, registeredKeys: registeredKeys) {
                hint = "Was at \(attendee.meetings) of \(attendee.of) meetings"
                suggestion = PersonChoice(
                    personKey: attendee.personKey, displayName: attendeeNames[attendee.personKey] ?? attendee.personKey, inRegistry: false)
            }

            trainGroups.append(TrainGroup(
                id: members.map(\.key).sorted().joined(separator: "|"),
                members: members,
                audioMembers: audioMembers,
                suggestion: suggestion,
                hint: hint,
                speechMin: members.reduce(0) { $0 + $1.speechSec } / 60))
        }
        return trainGroups
    }

    /// The best-scoring registry person across every member of a group — a
    /// group votes for whichever single cluster within it matches a person
    /// most confidently, not an average (the `VoiceMatcher` nearest-sample
    /// rationale: several channel variants must not get blended into a
    /// centroid that matches neither).
    nonisolated private static func nearestRegistryMatch(_ group: [GroupableCluster], samples: [VoiceSample]) -> (personID: Int64, score: Float)? {
        var best: (personID: Int64, score: Float)?
        for member in group {
            guard let top = VoiceMatcher.nearest(embedding: member.embedding, samples: samples).first else { continue }
            if let current = best, current.score >= top.score { continue }
            best = (top.personID, top.score)
        }
        return best
    }

    /// Spec §3.1 candidate order: this meeting's invited attendees the
    /// registry doesn't already know FIRST (matched by email or display
    /// name, case/whitespace insensitive), then registry people — each
    /// group sorted by display name on its own, never merged into one
    /// alphabetical list, so a just-met attendee always outranks an
    /// unrelated but alphabetically-earlier registry person. (The picker's
    /// trailing "new person…" affordance is UI-only, not represented here.)
    nonisolated private static func candidateChoices(attendees: [EventAttendee], people: [VoicePrint]) -> [PersonChoice] {
        let registryKeys = Set(people.flatMap { [normalizedKey($0.personKey), normalizedKey($0.displayName)] })
        var seen = Set<String>()
        var invitedNotInRegistry: [PersonChoice] = []
        for attendee in attendees {
            let name = attendee.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let email = attendee.email.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty || !email.isEmpty else { continue }
            let key = normalizedKey(email.isEmpty ? name : email)
            guard !registryKeys.contains(key), name.isEmpty || !registryKeys.contains(normalizedKey(name)) else { continue }
            guard seen.insert(key).inserted else { continue }
            invitedNotInRegistry.append(PersonChoice(personKey: key, displayName: name.isEmpty ? email : name, inRegistry: false))
        }
        invitedNotInRegistry.sort(by: byDisplayName)

        let registryChoices = people
            .map { PersonChoice(personKey: $0.personKey, displayName: $0.displayName, inRegistry: true) }
            .sorted(by: byDisplayName)

        return invitedNotInRegistry + registryChoices
    }

    nonisolated private static func byDisplayName(_ a: PersonChoice, _ b: PersonChoice) -> Bool {
        a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
    }

    nonisolated private static func normalizedKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func removeCard(_ card: VoiceCard) {
        cards.removeAll { $0.id == card.id }
    }

    private func moveToEnd(_ card: VoiceCard) {
        guard let index = cards.firstIndex(where: { $0.id == card.id }) else { return }
        cards.append(cards.remove(at: index))
    }
}
