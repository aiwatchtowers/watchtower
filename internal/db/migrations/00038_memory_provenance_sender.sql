-- +goose Up
-- Secretary memory retrieval (Slice B of the memory-retrieval redesign,
-- docs/superpowers/specs/2026-07-20-memory-slice-b-unified-retrieval-design.md).
-- Persists the per-message sender for a provenance ref so RetrieveBySubject's
-- short-term half (ListShortTierEpisodesForAliases) can find "what recently
-- happened involving this person/channel" without a runtime join back to
-- messages/gmail_messages at query time. Populated only for schemes with a
-- genuine per-message sender: Slack (messages.user_id) and Gmail
-- (gmail_messages.from_email); left '' for cal:/chat:/act: schemes (weaker
-- or always-owner-authored — no discriminating value there). No
-- migration-time backfill — memory_provenance is fully vault-derived and
-- converges via Reconcile/`watchtower memory reindex` (the importance_score
-- 00037 precedent). Additive, no CHECK constraint — a plain ADD COLUMN
-- suffices (the 00017/00036/00037 ALTER TABLE precedent).
ALTER TABLE memory_provenance ADD COLUMN sender_id TEXT NOT NULL DEFAULT '';
CREATE INDEX idx_memory_provenance_sender ON memory_provenance(sender_id);

-- +goose Down
DROP INDEX idx_memory_provenance_sender;
ALTER TABLE memory_provenance DROP COLUMN sender_id;
