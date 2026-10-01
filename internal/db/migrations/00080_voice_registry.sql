-- +goose NO TRANSACTION
-- +goose Up
-- Voice registry (spec docs/superpowers/specs/2026-09-28-voice-registry-design.md).
-- voice_prints becomes a person row; voices live as per-sample rows in
-- voice_samples (nearest-sample matching, owner anchors, self-training,
-- imports). Supersedes 00046's "never exported" note: prints are exported
-- only by an explicit owner action as an encrypted file of embeddings.
-- The model_version literal MUST equal VoiceRegistryPolicy.embeddingModelVersion (Swift).
-- NO TRANSACTION because the table-recreation dance below toggles
-- PRAGMA foreign_keys, which SQLite refuses while a transaction is open.
PRAGMA foreign_keys = OFF;

CREATE TABLE voice_prints_new (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    person_key   TEXT NOT NULL UNIQUE,
    display_name TEXT NOT NULL,
    created_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
INSERT INTO voice_prints_new (id, person_key, display_name, created_at, updated_at)
    SELECT id, person_key, display_name, updated_at, updated_at FROM voice_prints;

CREATE TABLE voice_imports (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    sender_name   TEXT NOT NULL,
    sender_email  TEXT NOT NULL DEFAULT '',
    file_sha256   TEXT NOT NULL UNIQUE,
    people_count  INTEGER NOT NULL,
    sample_count  INTEGER NOT NULL,
    model_version TEXT NOT NULL,
    imported_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE TABLE voice_samples (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    person_id     INTEGER NOT NULL REFERENCES voice_prints_new(id) ON DELETE CASCADE,
    embedding     BLOB NOT NULL,
    model_version TEXT NOT NULL,
    origin        TEXT NOT NULL CHECK (origin IN ('owner', 'auto', 'imported')),
    anchor        INTEGER NOT NULL DEFAULT 0 CHECK (anchor IN (0, 1)),
    status        TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'pending', 'retired')),
    transcript_id INTEGER REFERENCES meeting_transcripts(id) ON DELETE SET NULL,
    cluster_label TEXT,
    channel       TEXT NOT NULL DEFAULT 'unknown' CHECK (channel IN ('room', 'remote', 'unknown')),
    score         REAL,
    speech_sec    REAL NOT NULL DEFAULT 0,
    import_id     INTEGER REFERENCES voice_imports(id) ON DELETE CASCADE,
    created_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    CHECK (anchor = 0 OR origin = 'owner')
);
INSERT INTO voice_samples (person_id, embedding, model_version, origin, anchor, status)
    SELECT id, embedding, 'fluidaudio-wespeaker-v1', 'owner', 1, 'active' FROM voice_prints;

DROP TABLE voice_prints;
ALTER TABLE voice_prints_new RENAME TO voice_prints;
CREATE INDEX idx_voice_samples_person_status ON voice_samples(person_id, status);
CREATE INDEX idx_voice_samples_transcript ON voice_samples(transcript_id);

CREATE TABLE voice_label_queue (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    transcript_id       INTEGER NOT NULL REFERENCES meeting_transcripts(id) ON DELETE CASCADE,
    cluster_label       TEXT NOT NULL,
    reason              TEXT NOT NULL CHECK (reason IN ('unsure', 'unknown', 'import_confirm', 'conflict', 'relabel')),
    suggested_person_id INTEGER REFERENCES voice_prints(id) ON DELETE SET NULL,
    score               REAL,
    status              TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'done', 'skipped')),
    created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    resolved_at         TEXT
);
CREATE UNIQUE INDEX idx_voice_label_queue_open ON voice_label_queue(transcript_id, cluster_label) WHERE status = 'pending';
CREATE INDEX idx_voice_label_queue_status ON voice_label_queue(status, created_at);

ALTER TABLE meeting_transcripts ADD COLUMN speaker_names_changed_at TEXT;
-- When the ad-hoc recap (summary_json) was last generated. updated_at can't
-- serve: a speaker relabel bumps it too (the knowledge-search cursor needs
-- that), so "names changed after the recap" needs the recap's own stamp.
-- NULL for a recap written before this column existed (older than any relabel).
ALTER TABLE meeting_transcripts ADD COLUMN summary_updated_at TEXT;

-- The LLM speaker-name guess is retired with this feature (spec §3.4):
-- deregister its prompt row (the 00010/00012/00070 precedent) so Settings →
-- Prompts shows no orphan, editable-but-inert entry.
DELETE FROM prompts WHERE id = 'meeting.speaker_guess';

PRAGMA foreign_keys = ON;

-- +goose Down
PRAGMA foreign_keys = OFF;
DROP TABLE IF EXISTS voice_label_queue;
CREATE TABLE voice_prints_old (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    person_key   TEXT NOT NULL UNIQUE,
    display_name TEXT NOT NULL,
    embedding    BLOB NOT NULL,
    sample_count INTEGER NOT NULL DEFAULT 1,
    updated_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
INSERT INTO voice_prints_old (id, person_key, display_name, embedding, sample_count, updated_at)
    SELECT p.id, p.person_key, p.display_name,
           (SELECT s.embedding FROM voice_samples s WHERE s.person_id = p.id AND s.anchor = 1 ORDER BY s.id LIMIT 1),
           1, p.updated_at
    FROM voice_prints p
    WHERE EXISTS (SELECT 1 FROM voice_samples s WHERE s.person_id = p.id AND s.anchor = 1);
DROP TABLE voice_samples;
DROP TABLE voice_imports;
DROP TABLE voice_prints;
ALTER TABLE voice_prints_old RENAME TO voice_prints;
ALTER TABLE meeting_transcripts DROP COLUMN summary_updated_at;
ALTER TABLE meeting_transcripts DROP COLUMN speaker_names_changed_at;
PRAGMA foreign_keys = ON;
