-- +goose Up
-- Next-step generation (internal/targets/nextstep.go) has no attempt budget:
-- GetTargetsNeedingNextStep only tracks whether a suggestion was ever
-- generated (next_step_at), not whether an attempt was made and failed, so a
-- target whose AI reply never parses is retried on every daemon cycle
-- forever. This is per-TARGET state (not a global daemon counter): a global
-- budget would let one perpetually-failing target silence next-step
-- generation for every other target that day, since a batch can contain up
-- to Resolver.ActiveSnapshotLimit (100 by default) distinct targets.
--
-- next_step_attempts / next_step_attempted_at record the outcome of the most
-- recent attempt (success or failure) so GetTargetsNeedingNextStep can cap
-- retries at 3/day per target while still giving a target edited since its
-- last failed attempt a fresh budget immediately (a new problem, not a retry).
--
-- UTC ISO8601, matching every other timestamp already on this row
-- (updated_at, next_step_at) — a local-time day boundary would disagree with
-- the updated_at comparison across UTC midnight.
ALTER TABLE targets ADD COLUMN next_step_attempts INTEGER NOT NULL DEFAULT 0;
ALTER TABLE targets ADD COLUMN next_step_attempted_at TEXT NOT NULL DEFAULT '';

-- +goose Down
ALTER TABLE targets DROP COLUMN next_step_attempts;
ALTER TABLE targets DROP COLUMN next_step_attempted_at;
