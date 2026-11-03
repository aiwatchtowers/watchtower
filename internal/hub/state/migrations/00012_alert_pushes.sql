-- +goose Up
-- The alert-push ledger (Go hub plan 4 Task 4): one row per (alert key,
-- phone) a work alert was pushed to over the hosted relay's send_alert. The
-- row is written 'pending' when the push is queued and settled with its
-- outcome class after the request, so a push is sent at most once: a row
-- found 'pending' at hub start (queued or in flight at a crash) is settled
-- 'expired' (reason 'restart') and never resent. Ids, counters, timestamps
-- and classes only: the alert's text lives in memory, never here. Pruned
-- after 7 days with the alert lifetime.
CREATE TABLE alert_pushes (
    alert_key TEXT NOT NULL,
    device_id TEXT NOT NULL,
    outcome TEXT NOT NULL CHECK (outcome IN ('pending', 'accepted', 'no_token', 'not_paying', 'forbidden', 'push_off', 'too_large', 'expired', 'failed')),
    reason TEXT NOT NULL DEFAULT '' CHECK (reason IN ('', 'freshness', 'owner_back', 'restart', 'switched', 'overflow', 'stopped')),
    attempts INTEGER NOT NULL DEFAULT 0,
    first_at REAL NOT NULL,
    settled_at REAL,
    PRIMARY KEY (alert_key, device_id)
);

-- +goose Down
DROP TABLE alert_pushes;
