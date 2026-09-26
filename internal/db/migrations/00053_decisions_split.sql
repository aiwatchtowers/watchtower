-- +goose Up

-- Decisions Split: decisions stop being an Ideas-registry review queue item
-- and become a settled record — they are born (and, for the pre-existing
-- backlog, migrated) straight into 'active' instead of sitting in
-- 'proposed' waiting for an owner verdict that decisions never actually
-- need. Ideas/notes are unaffected; only kind='decision' rows flip.
UPDATE ideas SET status = 'active', updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
 WHERE kind = 'decision' AND status = 'proposed';

-- Read marker for the decisions ledger (an idea/decision the owner has
-- opened at least once) and for the cross-source stream_digests feed,
-- mirroring the ledger's read/unread model onto stage-1 digests.
ALTER TABLE ideas ADD COLUMN seen_at TEXT;
ALTER TABLE stream_digests ADD COLUMN read_at TEXT;

-- +goose Down
ALTER TABLE ideas DROP COLUMN seen_at;
ALTER TABLE stream_digests DROP COLUMN read_at;
-- The status flip (proposed decisions -> active) is deliberately not
-- reverted: it cannot be undone without knowing which rows it touched.
