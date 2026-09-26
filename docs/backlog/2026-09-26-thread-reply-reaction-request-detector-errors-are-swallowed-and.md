---
type: bug
title: "Thread-reply / reaction-request detector errors are swallowed and the watermark still advances"
status: open
priority: med
tags: [inbox, watermark, INBOX-09, swallowed-error, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go AI pipelines/tools)
created: 2026-09-26
---

**Where:** internal/inbox/pipeline.go:429-437 (plus internal/inbox/jira_detector.go:183-186,95,124)
**Confidence:** high

In `detectSlackTriggers`, a failure of `FindMentions` or `FindDMs` is returned. A failure of `FindThreadRepliesToUser` or `FindReactionRequests` (for example SQLITE_BUSY) is only logged, and the function returns `nil`. `detectAll` therefore sees a clean pass, `decideWatermark` advances, and thread replies to the owner in that window are lost for good. INBOX-09 states that "any detector pass fails" freezes the cursor. `collectJiraCommentCandidates` also turns a query error into "no candidates", and the Jira `CreateInboxItem` errors are dropped. Fix: return (or join) these errors so the watermark gate sees them.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
