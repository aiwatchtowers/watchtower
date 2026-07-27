-- +goose Up
-- Secretary memory importance score (Slice A of the memory-importance-score
-- redesign, docs/superpowers/specs/2026-07-18-memory-importance-score-design.md,
-- MEM-16). Persists the merged (owner-override-or-computed) importance value
-- Reconcile/Rebuild refresh per node — a periodic snapshot future retrieval
-- ranking will read, distinct from evict.go's always-live RetentionScore.
-- A simple additive column: unlike 00018's belief-status CHECK-widening
-- dance, this touches no CHECK constraint, so a plain ADD COLUMN suffices
-- (the 00017/00036 ALTER TABLE precedent).
ALTER TABLE memory_nodes ADD COLUMN importance_score REAL NOT NULL DEFAULT 0;

-- +goose Down
ALTER TABLE memory_nodes DROP COLUMN importance_score;
