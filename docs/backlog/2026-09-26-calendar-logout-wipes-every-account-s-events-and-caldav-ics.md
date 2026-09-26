---
type: bug
title: "calendar logout wipes every account's events and CalDAV/ICS data, and unlinks recordings from their events"
status: open
priority: high
tags: [calendar, multi-account, data-loss, cli, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go sync/daemon/integrations)
created: 2026-09-26
---

**Where:** cmd/calendar.go:174-201, internal/db/calendar.go:263-275, cmd/google.go:498-541
**Confidence:** high

`runCalendarLogout` turns off the calendar service on Google account #1 only (`disconnectGoogleService` takes `accounts[0]`). It then calls `ClearCalendarEvents`, which runs an unscoped `DELETE FROM calendar_events`, `DELETE FROM calendar_calendars` and `DELETE FROM calendar_attendee_map`. That removes the events of every other Google account and every CalDAV/ICS account, plus all calendar selections (`is_selected` is lost, so account N>1 falls back to "primary only" on the next sync). The raw DELETE also skips the recording guard in `DeleteStaleCalendarEvents` (owner decision 14): `meeting_transcripts.event_id` and `meeting_recaps.event_id` are `ON DELETE SET NULL`, so every recording and recap is permanently unlinked from its event. A recap without `transcript_id` becomes unreachable, and re-syncing does not restore the links. Fix: scope the purge to account #1's calendars (the `DeleteGoogleAccount` shape) and keep the transcript/recap `NOT EXISTS` guard, or drop the purge from logout entirely.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
