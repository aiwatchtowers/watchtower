-- +goose Up
-- One-time cleanup: earlier builds auto-seeded a generic default observer on
-- every active target. That observer's broad instruction flooded the activity
-- timeline with loosely-related events. Auto-seeding has been removed; delete
-- the untouched auto-seeded observers (matched on the exact old default name +
-- instruction) so existing targets stop surfacing noise. Their observer_events
-- cascade-delete via the foreign key. Observers the user edited or created keep
-- a different name/instruction and are left intact.
DELETE FROM observers
WHERE name = 'Activity watcher'
  AND instruction = 'Track anything across all sources that affects the progress, status, blockers, or decisions of this goal. Surface relevant updates and flag when the status or next step should change.';

-- +goose Down
-- Irreversible: deleted rows cannot be resurrected. No-op.
SELECT 1;
