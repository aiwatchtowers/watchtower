-- +goose Up
-- "Digested through" and "considered through" are not the same thing. A
-- channel's digest window advances off MAX(digests.period_to), but the batch
-- digest prompt is told to SKIP channels where nothing noteworthy happened —
-- such a channel produces no digests row, so its watermark never moves. With a
-- per-channel window (00066's sibling change) it is then re-offered every cycle
-- with an ever-widening window, and once that backlog exceeds the per-channel
-- message cap part of it can never fit into a prompt again: the channel stalls.
--
-- digest_considered_ts records the newest message that was actually rendered
-- into an AI call which returned successfully, whether or not the model chose
-- to write a digest for that channel. The window start is max(period_to,
-- digest_considered_ts, the FEAT-03 fast-forward floor, the first-run lookback).
--
-- INTEGER, unix seconds: messages.ts_unix is a generated column that keeps only
-- the whole-second part of the Slack ts, so a second-resolution stamp compares
-- exactly against it and can never truncate below a message it covers.
-- NULL = never considered (distinct from "considered at epoch 0").
ALTER TABLE channels ADD COLUMN digest_considered_ts INTEGER;

-- +goose Down
ALTER TABLE channels DROP COLUMN digest_considered_ts;
