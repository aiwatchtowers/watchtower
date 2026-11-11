-- +goose Up
-- When a phone's gap was last asked with resend_from: an ask that old is
-- treated as lost, so the gap is asked again (it would otherwise hold the
-- phone's actions for ever). NULL: not known, the next action ahead of the gap
-- asks. A re-link starts it empty again.
ALTER TABLE devices ADD COLUMN resend_requested_at REAL;

-- +goose Down
ALTER TABLE devices DROP COLUMN resend_requested_at;
