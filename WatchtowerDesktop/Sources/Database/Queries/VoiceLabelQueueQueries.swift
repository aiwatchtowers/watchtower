import Foundation
import GRDB
import WatchtowerCore

/// The owner's voice-labeling queue (`voice_label_queue`).
enum VoiceLabelQueueQueries {
    /// Adds a task; a no-op while a pending task for the same
    /// transcript+cluster exists (partial unique index, INSERT OR IGNORE).
    static func enqueue(
        _ db: Database,
        transcriptID: Int64,
        clusterLabel: String,
        reason: VoiceLabelReason,
        suggestedPersonID: Int64?,
        score: Float?
    ) throws {
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO voice_label_queue (transcript_id, cluster_label, reason, suggested_person_id, score)
                VALUES (?, ?, ?, ?, ?)
                """,
            arguments: [transcriptID, clusterLabel, reason.rawValue, suggestedPersonID, score])
    }

    /// Pending tasks, newest first — all of them or one transcript's.
    static func pending(_ db: Database, transcriptID: Int64? = nil) throws -> [VoiceLabelTask] {
        var request = VoiceLabelTask.filter(Column("status") == VoiceLabelTaskStatus.pending.rawValue)
        if let transcriptID { request = request.filter(Column("transcript_id") == transcriptID) }
        return try request.order(Column("created_at").desc, Column("id")).fetchAll(db)
    }

    static func pendingCount(_ db: Database) throws -> Int {
        try VoiceLabelTask.filter(Column("status") == VoiceLabelTaskStatus.pending.rawValue).fetchCount(db)
    }

    static func close(_ db: Database, id: Int64, status: VoiceLabelTaskStatus) throws {
        try db.execute(
            sql: """
                UPDATE voice_label_queue
                SET status = ?, resolved_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
                WHERE id = ?
                """,
            arguments: [status.rawValue, id])
    }

    /// Spec §3.1 "voice recognized meanwhile ⇒ task auto-closes": closes
    /// every pending task whose cluster no longer needs the owner — named
    /// since it was queued (retro relabel, a Train confirm, another card) —
    /// so the tray counter drains with it. A cluster still unnamed
    /// (`label_source: none`) keeps its task; a `.relabel` task targets a
    /// NAMED cluster by design, so only its cluster vanishing closes it. A
    /// cluster renamed away from the task's label (found by `original_label`)
    /// closes `done`; one that is gone altogether closes `skipped`. Returns
    /// how many tasks were closed.
    @discardableResult
    static func closeResolvedTasks(_ db: Database) throws -> Int {
        var speakersByTranscript: [Int64: [SpeakerEmbedding]] = [:]
        var closed = 0
        for task in try pending(db) {
            guard let taskID = task.id else { continue }
            if speakersByTranscript[task.transcriptID] == nil {
                speakersByTranscript[task.transcriptID] =
                    try MeetingTranscriptQueries.fetch(db, id: task.transcriptID)?.speakerEmbeddings ?? []
            }
            let speakers = speakersByTranscript[task.transcriptID] ?? []
            if let cluster = speakers.first(where: { $0.speaker == task.clusterLabel }) {
                guard task.reason != .relabel, cluster.effectiveLabelSource != .none else { continue }
                try close(db, id: taskID, status: .done)
            } else {
                let renamed = speakers.contains { $0.originalLabel == task.clusterLabel }
                try close(db, id: taskID, status: renamed ? .done : .skipped)
            }
            closed += 1
        }
        return closed
    }

    /// Spec §3.1: tasks whose recording lost its audio become `skipped` —
    /// never an audio-less card. Returns how many were skipped.
    @discardableResult
    static func skipTasksWithoutAudio(
        _ db: Database,
        audioExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) throws -> Int {
        let rows = try Row.fetchAll(db, sql: """
            SELECT q.id, t.audio_path FROM voice_label_queue q
            JOIN meeting_transcripts t ON t.id = q.transcript_id
            WHERE q.status = 'pending'
            """)
        var skipped = 0
        for row in rows {
            let path: String? = row["audio_path"]
            if let path, !path.isEmpty, audioExists(path) { continue }
            try close(db, id: row["id"], status: .skipped)
            skipped += 1
        }
        return skipped
    }
}
