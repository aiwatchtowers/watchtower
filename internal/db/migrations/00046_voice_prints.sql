-- +goose Up
-- Voice prints: one row per known person's voice, learned from manual speaker
-- renames in the Desktop transcript view. person_key is the attendee email
-- (or a normalized display name when no email is known). embedding is the
-- L2-normalized 256-dim float32 centroid (little-endian BLOB) of every
-- confirmed cluster embedding for that person; sample_count tracks how many
-- clusters were folded in (incremental centroid update). Local-only data —
-- never synced or exported.
CREATE TABLE IF NOT EXISTS voice_prints (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    person_key   TEXT NOT NULL UNIQUE,
    display_name TEXT NOT NULL,
    embedding    BLOB NOT NULL,
    sample_count INTEGER NOT NULL DEFAULT 1,
    updated_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

-- Per-cluster voice embeddings for a recording: JSON array of
-- {"speaker": "<final rendered label>", "embedding": [256 floats]} entries,
-- one per diarized cluster that produced an embedding (FluidAudio only).
-- NULL for legacy rows and non-FluidAudio diarizers — a rename then updates
-- the transcript only, never voice_prints. Labels are rewritten on rename so
-- later renames still resolve their cluster. Heavy column: NEVER selected by
-- the Desktop recordings list projection.
ALTER TABLE meeting_transcripts ADD COLUMN speakers_json TEXT;

-- +goose Down
ALTER TABLE meeting_transcripts DROP COLUMN speakers_json;
DROP TABLE IF EXISTS voice_prints;
