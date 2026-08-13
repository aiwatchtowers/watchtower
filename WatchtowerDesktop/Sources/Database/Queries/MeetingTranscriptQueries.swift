import Foundation
import GRDB
import WatchtowerCore

/// Failures inside `MeetingTranscriptQueries` writes that must roll the
/// caller's transaction back instead of degrading silently.
enum MeetingTranscriptQueryError: Error {
    /// `speakers_json` could not be re-encoded during a rename — writing the
    /// old JSON would orphan the cluster's embedding under the old label.
    case speakerEncodeFailed
}

enum MeetingTranscriptQueries {
    static func fetch(_ db: Database, id: Int64) throws -> MeetingTranscript? {
        try MeetingTranscript.fetchOne(db, key: id)
    }

    /// Transcripts linked to a calendar event, newest first.
    static func fetchForEvent(_ db: Database, eventID: String) throws -> [MeetingTranscript] {
        try MeetingTranscript
            .filter(Column("event_id") == eventID)
            .order(Column("created_at").desc, Column("id").desc)
            .fetchAll(db)
    }

    /// Ad-hoc transcripts (no calendar event), newest first.
    static func fetchAdHoc(_ db: Database, limit: Int = 50) throws -> [MeetingTranscript] {
        try MeetingTranscript
            .filter(Column("event_id") == nil)
            .order(Column("created_at").desc, Column("id").desc)
            .limit(limit)
            .fetchAll(db)
    }

    /// Dual-path write (documented pattern, cf. `CatchUpQueries.acknowledge`):
    /// links the transcript to the event; if the event has no `meeting_recaps`
    /// row and the transcript carries a summary, copies it into
    /// `meeting_recaps` (`source_text` = transcript text) so the recap shows up
    /// in the existing recap UI immediately.
    static func linkToEvent(_ db: Database, id: Int64, eventID: String) throws {
        guard let transcript = try fetch(db, id: id) else { return }
        try db.execute(
            sql: """
                UPDATE meeting_transcripts
                SET event_id = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [eventID, id])
        guard let summaryJSON = transcript.summaryJSON, !summaryJSON.isEmpty else { return }
        guard try MeetingRecapQueries.fetch(db, eventID: eventID) == nil else { return }
        try db.execute(
            sql: """
                INSERT INTO meeting_recaps (event_id, source_text, recap_json, created_at, updated_at)
                VALUES (?, ?, ?, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'), strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
                """,
            arguments: [eventID, transcript.transcriptText, summaryJSON])
    }

    /// Recordings master list (ad-hoc + event-linked), newest first. A recap
    /// "exists" when the row has summary_json OR its event has a
    /// meeting_recaps row (the recap collision guard can put it in either).
    /// Perf guard: the heavy blobs — transcript_text, summary_json,
    /// segments_json, speakers_json and chapters_json — are NEVER selected
    /// here, only a 200-char snippet plus booleans; the calendar_events
    /// LEFT JOIN pulls the linked event's title ONLY, no heavy event columns.
    static func fetchRecordingList(_ db: Database, limit: Int = 200) throws -> [RecordingListItem] {
        try RecordingListItem.fetchAll(
            db,
            sql: """
                SELECT t.id, t.event_id, e.title AS event_title,
                       t.title, t.duration_sec, t.lang_stats, t.created_at,
                       (t.summary_json IS NOT NULL
                        OR EXISTS (SELECT 1 FROM meeting_recaps r WHERE r.event_id = t.event_id)) AS has_recap,
                       (t.notes_md IS NOT NULL) AS has_notes,
                       substr(t.transcript_text, 1, 200) AS snippet
                FROM meeting_transcripts t
                LEFT JOIN calendar_events e ON e.id = t.event_id
                ORDER BY t.created_at DESC, t.id DESC
                LIMIT ?
                """,
            arguments: [limit])
    }

    /// Direct notes write from the editor (GRDB, no CLI round-trip — same
    /// local-write precedent as `linkToEvent`).
    static func saveNotes(_ db: Database, id: Int64, markdown: String) throws {
        try db.execute(
            sql: """
                UPDATE meeting_transcripts
                SET notes_md = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [markdown, id])
    }

    /// Soft-deletes (or restores, `deleted: false` — the undo toast) one
    /// utterance: flips its `deleted` flag and rewrites `segments_json`
    /// together with the rebuilt `transcript_text` in the caller's write
    /// transaction (the `saveNotes` direct-GRDB-write precedent), preserving
    /// the invariant transcript_text = render(segments where !deleted).
    /// `TranscriptSegments.render` is the canonical renderer for UI edits;
    /// its CLI-write twin is Go's `internal/meeting.RenderTranscriptSegments`
    /// (deliberate dual-path). No-op when the row is missing, has no
    /// segments, or the idx is unknown. Deleting every utterance is valid and
    /// yields an empty transcript_text (no hard deletion ever).
    static func setUtteranceDeleted(_ db: Database, id: Int64, idx: Int, deleted: Bool) throws {
        guard let transcript = try fetch(db, id: id),
              let segmentsJSON = transcript.segmentsJSON,
              var utterances = TranscriptSegments.decode(segmentsJSON),
              let position = utterances.firstIndex(where: { $0.idx == idx }) else { return }
        utterances[position].deleted = deleted
        guard let updatedJSON = TranscriptSegments.encode(utterances) else { return }
        try db.execute(
            sql: """
                UPDATE meeting_transcripts
                SET segments_json = ?, transcript_text = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [updatedJSON, TranscriptSegments.render(utterances), id])
    }

    /// Renames a speaker cluster (manual confirm/rename — the voice-print
    /// learning loop, or a confirmed LLM suggestion): every utterance labeled
    /// `from` (deleted ones included — they stay in the array) gets the new
    /// display name, `segments_json` is rewritten together with the rebuilt
    /// `transcript_text` in the caller's write transaction (the D1
    /// `setUtteranceDeleted` transactional write), and the cluster's entry in
    /// `speakers_json` is re-keyed to the new label so later renames still
    /// resolve it. When the cluster carries a voice embedding, it is folded
    /// into `voice_prints` (insert or incremental centroid — see
    /// `VoicePrintQueries.upsert`); recordings without embeddings
    /// (legacy/non-FluidAudio) update the transcript only. Returns `false`
    /// without writing (so callers can surface a stale-state rename instead
    /// of silently consuming a suggestion chip) when the row is missing, has
    /// no segments, no utterance carries `from`, or the new name is
    /// empty/unchanged/reserved («Я» or "Speaker N" —
    /// `SpeakerNaming.isReserved`: renaming a stranger's cluster to a
    /// reserved label would corrupt the owner's voice identity).
    @discardableResult
    static func renameSpeaker(_ db: Database,
                              id: Int64,
                              from: String,
                              to displayName: String,
                              personKey: String) throws -> Bool {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName != from,
              !SpeakerNaming.isReserved(trimmedName),
              let transcript = try fetch(db, id: id),
              let segmentsJSON = transcript.segmentsJSON,
              var utterances = TranscriptSegments.decode(segmentsJSON),
              utterances.contains(where: { $0.speaker == from }) else { return false }

        for index in utterances.indices where utterances[index].speaker == from {
            let u = utterances[index]
            utterances[index] = TranscriptUtterance(
                idx: u.idx, startSec: u.startSec, endSec: u.endSec,
                speaker: trimmedName, text: u.text, deleted: u.deleted)
        }
        guard let updatedJSON = TranscriptSegments.encode(utterances) else { return false }

        // Re-key the cluster's persisted embedding to the new label (and keep
        // it for the voice-print upsert below). An encode failure aborts the
        // whole rename (throw → transaction rollback) — falling back to the
        // old JSON would keep the embedding under the old label, permanently
        // orphaning it from the renamed cluster.
        var clusterEmbedding: [Float]?
        var speakersJSON: String? = transcript.speakersJSON
        if let json = transcript.speakersJSON, var speakers = SpeakerEmbeddings.decode(json) {
            for index in speakers.indices where speakers[index].speaker == from {
                clusterEmbedding = speakers[index].embedding
                speakers[index].speaker = trimmedName
            }
            guard let reencoded = SpeakerEmbeddings.encode(speakers) else {
                throw MeetingTranscriptQueryError.speakerEncodeFailed
            }
            speakersJSON = reencoded
        }

        try db.execute(
            sql: """
                UPDATE meeting_transcripts
                SET segments_json = ?, transcript_text = ?, speakers_json = ?,
                    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [updatedJSON, TranscriptSegments.render(utterances), speakersJSON, id])

        if let clusterEmbedding {
            try VoicePrintQueries.upsert(
                db, personKey: personKey, displayName: trimmedName, embedding: clusterEmbedding)
        }
        return true
    }

    /// Thrown by `convertActionItemToTarget`. Every case aborts the caller's
    /// write transaction, so a failed stamp can never leave an orphan Target.
    enum ActionItemConversionError: Error, LocalizedError, Equatable {
        /// Row missing, chapters absent/malformed, or stale UI indices.
        case staleChapters
        /// The item already carries a Target link (double-click / stale UI).
        case alreadyConverted(targetID: Int64)
        /// chapters_json re-encode failed — nothing may be written.
        case encodeFailed

        var errorDescription: String? {
            switch self {
            case .staleChapters:
                return "Chapters changed underneath — reopen the recording and retry"
            case .alreadyConverted(let targetID):
                return "Already converted to Target #\(targetID)"
            case .encodeFailed:
                return "Could not update chapters after creating the Target"
            }
        }
    }

    /// Action item → Target conversion, atomic at the query layer: creates
    /// the Target row AND stamps `converted_target_id` on the chapter action
    /// item inside the caller's single write transaction. Throws instead of
    /// silently no-opping — a stale index, missing chapters, or an encode
    /// failure aborts the whole transaction, so the Target insert rolls back
    /// with the stamp (no duplicate Targets from a dropped stamp).
    /// Idempotent: an already-stamped item throws `.alreadyConverted`, and a
    /// Target already minted for the same source ref with the same text (an
    /// earlier conversion whose stamp was lost) is re-linked instead of
    /// duplicated. The item itself always stays in the chapter — a link, not
    /// a delete (DASH-03 spirit).
    @discardableResult
    static func convertActionItemToTarget(
        _ db: Database, transcriptID: Int64, chapterIdx: Int, itemIdx: Int
    ) throws -> Int64 {
        guard let transcript = try fetch(db, id: transcriptID),
              let chaptersJSON = transcript.chaptersJSON,
              var chapters = MeetingChapters.decode(chaptersJSON),
              chapters.chapters.indices.contains(chapterIdx),
              chapters.chapters[chapterIdx].actionItems.indices.contains(itemIdx) else {
            throw ActionItemConversionError.staleChapters
        }
        let chapter = chapters.chapters[chapterIdx]
        let item = chapter.actionItems[itemIdx]
        if let existing = item.convertedTargetID {
            throw ActionItemConversionError.alreadyConverted(targetID: existing)
        }

        // Target description = chapter context (meeting title + date part of
        // created_at — the raw UTC date, matching Go's followup MeetingDate —
        // + chapter title/summary), the spec'd conversion payload.
        let date = String(transcript.createdAt.prefix(10))
        var context = "From meeting \"\(transcript.title)\" (\(date)), chapter \"\(chapter.title)\""
        if !chapter.summary.isEmpty {
            context += ": \(chapter.summary)"
        }

        // Idempotency repair: a Target already minted for this source ref
        // with the same text (a pre-fix conversion whose stamp was dropped)
        // is re-linked, never duplicated. Text must match — after a chapters
        // regeneration the same indices can point at a different item.
        let sourceID = "meeting_chapter:\(transcriptID):\(chapterIdx):\(itemIdx)"
        let targetID: Int64
        let priorTargets = try TargetQueries.fetchBySourceRef(db, sourceType: "manual", sourceID: sourceID)
        if let existing = priorTargets.first(where: { $0.text == item.text }) {
            targetID = Int64(existing.id)
        } else {
            let today = TargetQueries.todayDateString()
            targetID = Int64(try TargetQueries.create(
                db,
                text: item.text,
                intent: context,
                level: "day",
                periodStart: today,
                periodEnd: today,
                sourceType: "manual",
                sourceID: sourceID))
        }

        chapters.chapters[chapterIdx].actionItems[itemIdx].convertedTargetID = targetID
        guard let updatedJSON = MeetingChapters.encode(chapters) else {
            throw ActionItemConversionError.encodeFailed
        }
        try db.execute(
            sql: """
                UPDATE meeting_transcripts
                SET chapters_json = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [updatedJSON, transcriptID])
        return targetID
    }

    /// Deletes a recording with all its content: the transcript row and its
    /// "meeting" chat conversation (+ messages). The event's `meeting_recaps`
    /// row is deliberately NOT touched — a recap can exist independently of
    /// the recording (safe delete scope). Returns the audio_path (if any) so
    /// the caller can remove the file AFTER the transaction commits;
    /// callers must treat a missing file as success (daemon retention may
    /// have swept it already).
    static func delete(_ db: Database, id: Int64) throws -> String? {
        guard let transcript = try fetch(db, id: id) else { return nil }
        if let conv = try ChatConversationQueries.fetchByContext(db, type: "meeting", id: String(id)) {
            try ChatMessageQueries.deleteByConversation(db, conversationID: conv.id)
            try ChatConversationQueries.delete(db, id: conv.id)
        }
        try db.execute(sql: "DELETE FROM meeting_transcripts WHERE id = ?", arguments: [id])
        return transcript.audioPath
    }
}
