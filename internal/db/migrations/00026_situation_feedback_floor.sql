-- +goose Up
-- M8 (2026-07-18 final validation): the dashboard's situation-level 👍/👎
-- persists to feedback(entity_type='situation') (migration 00025), not to
-- inbox_feedback — so the mechanical interaction ingest (memory.sources.actions)
-- gains a SECOND floor-driven source over that table. This is its floor: the
-- highest feedback.id (entity_type='situation') already folded into episode-
-- mirror annotations + memory_engagement, a sibling of
-- memory_last_interaction_id (the inbox_feedback floor, 00022).
ALTER TABLE workspace ADD COLUMN memory_last_situation_feedback_id INTEGER NOT NULL DEFAULT 0;

-- +goose Down
ALTER TABLE workspace DROP COLUMN memory_last_situation_feedback_id;
