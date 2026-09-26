---
type: bug
title: "Calendar invite detection and RSVP auto-resolve read a JSON key production never writes"
status: open
priority: high
tags: [inbox, calendar, INBOX-02, dead-trigger, test-fixture-drift, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go AI pipelines/tools)
created: 2026-09-26
---

**Where:** internal/inbox/calendar_detector.go:13-16 (plus :78-83, internal/inbox/pipeline.go:824-829, internal/calendar/models.go:30-35, internal/caldav/models.go:34-38)
**Confidence:** high

`calAttendee` decodes `json:"rsvp_status"`, but both calendar writers (the Google `calendar.Attendee` and the CalDAV `caldav.Attendee`) store the RSVP as `json:"response_status"`. A repo-wide grep finds `rsvp_status` only in the inbox detector and its test fixtures. So on real data `myRSVP` is always `""`. As a result, (1) `calendar_invite` never fires, because it needs `myRSVP == "needsAction"`. (2) `autoResolveCalendar` (INBOX-02) never resolves a `calendar_invite`/`calendar_time_change` item, because it needs a non-empty RSVP. Every calendar test seeds `rsvp_status`, which is why they all pass. A secondary issue: both sites compare `a.Email == ownerEmail` case-sensitively, and they use only the ladder owner's single email, so an invite to a second Google or CalDAV account is never matched. Fix: decode `response_status` (or share the calendar model type), compare with `strings.EqualFold`, and reseed the fixtures from a real `calendar.Attendee` marshal so the tests exercise the production shape.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
