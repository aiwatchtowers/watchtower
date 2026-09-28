---
type: bug
title: "calendar_time_change can never fire: synced_at is rewritten on every sync"
status: done
priority: med
tags: [inbox, calendar, dead-trigger, test-fixture-drift, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go AI pipelines/tools)
created: 2026-09-26
---

**Where:** internal/inbox/calendar_detector.go:94,105 (plus internal/db/calendar.go:101,150, internal/calendar/client.go:277)
**Confidence:** high

The detector treats `updated_at > synced_at` as "modified after first sync". But the upsert sets `synced_at=excluded.synced_at` to the current time on every sync, while `updated_at` is Google's `item.Updated`, which always comes before the sync that fetched it. So `updated_at > synced_at` is false on every real row, and a rescheduled meeting never produces an item. For the same reason, `e.syncedAt > sinceISO` is true for every event on every cycle, so the "newly arrived" test for `calendar_invite` is really just "currently needsAction". The only thing stopping repeats is the (event, updated_at) dedup. `TestCalendarDetector_TimeChange` passes only because its fixture freezes `synced_at` at a first-sync time that production never keeps. Fix direction: persist a first-seen timestamp (or compare against the previous `start_time`/`end_time`), and reseed the tests through `UpsertCalendarEvents` twice.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»

Resolution: migration `00079` adds `calendar_events.time_changed_at`, stamped by the shared upsert clause (`calendarEventUpdateSet`, both the single and batch upserts) with the pass's `synced_at` only when `start_time` or `end_time` actually moved; a first insert and a detail-only re-sync leave it alone. `DetectCalendar` fires `calendar_time_change` when that stamp falls inside the window and dedups on it, so a later detail edit is not a second item. `TestCalendarDetector_TimeChange` now seeds through `UpsertCalendarEvent` twice with the start moved (the old fixture froze `synced_at` at a first-sync time production never keeps); its assertion is unchanged. Also pinned by `TestCalendarDetector_ResyncWithoutTimeChange`, `TestCalendarDetector_TimeChangeBeforeWindowIgnored` and `internal/db`'s `TestUpsertCalendarEvent_TimeChangedAt`. **The item is still not visible end to end yet.** `autoResolveCalendar` resolves any pending `calendar_time_change` item whose owner RSVP is not `needsAction`. A still-`needsAction` owner gets a `calendar_invite` instead, because that case comes first. So in practice every minted time-change item is resolved in the same `Pipeline.Run` that created it, and Catch-Up never sees it pending. `TestCalendarTimeChange_ResolvedSameCycleWhenRSVPAnswered` pins this current behaviour until the owner decides on INBOX-02. Known limit: moving a whole recurring series gives each CalDAV-expanded instance a new row id (its UID embeds the occurrence start), so the move shows up as new rows plus stale-cleanup deletions, never a time change. Only a single overridden occurrence (keyed by RECURRENCE-ID) keeps its id. Also unchanged: the `calendar_invite` "newly arrived" test (`synced_at > since`) is in practice "currently needsAction", deduped on `updated_at`.
