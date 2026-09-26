---
type: question
title: "Catch-Up has never produced a recap; three rows show \"building\" for 15 days"
status: open
priority: med
tags: [catchup, usage, desktop, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track usage analysis & dead functionality
created: 2026-09-26
---

**Where:** internal/catchup/pipeline.go:30-37,99,170; WatchtowerDesktop/Sources/Views/CatchUp/CatchUpRecapRow.swift:42
**Confidence:** high

`catchup_recaps` holds 3 rows total, all `status='building'` from a single 2026-09-11 session (0 `ready`,
0 acknowledged); the same minute left 7 orphaned `ask` pipeline_runs. `reapStaleRecaps` only runs at the
start of the next `catchup run`, and the Desktop renders `recap.isBuilding` straight from the row, so the
list keeps showing three spinners until the owner tries again. Catch-Up is also the main reader of the
inbox feeder (1945 items/30d) — so today that whole mechanical pipeline feeds nothing actually read
(briefings unread, Catch-Up unused). Suggest: treat `building` older than `staleBuildingAfter` as failed at
read time on the Desktop too (dual-path with the Go constant), and get an owner verdict on whether
Catch-Up is the intended daily surface (see the finding above).

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
