-- +goose Up
-- Meet Join button (docs/superpowers/specs/2026-07-31-meet-join-autorecord-design.md):
-- the event's conference link (Google Meet / Zoom / Teams / Webex), resolved at
-- sync time from hangoutLink → conferenceData video entry point → regex over
-- location+description (Google), or the regex fallback alone (CalDAV/ICS).
-- Additive, no CHECK change — the 00033/00037 ALTER TABLE precedent.
ALTER TABLE calendar_events ADD COLUMN conference_url TEXT NOT NULL DEFAULT '';

-- +goose Down
ALTER TABLE calendar_events DROP COLUMN conference_url;
