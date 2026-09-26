---
type: bug
title: "Gmail thread reply replaces the episode's Story/Outcome with a summary of only the new message(s)"
status: open
priority: med
tags: [memory, gmail, data-loss, watermark, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go AI pipelines/tools)
created: 2026-09-26
---

**Where:** internal/memory/gmail_extract.go:369, internal/memory/gmail_extract.go:487-495, internal/db/memory.go:1498 (ListGmailThreadsForExtract)
**Confidence:** high

The extractor loads only messages above the Gmail watermark, so a thread that gets a reply in a later run reaches the model as the reply alone. `gmailEpisodeNode` then does `existing.Body = episodeBody(title, ep)` with that delta-only extraction. Provenance is unioned, but Title/Story/Outcome are replaced by a story about the one new message. Scenario: a thread that set up a decision gets a one-line "thanks, done" reply two weeks later. The episode's Story now describes "thanks, done", and the decision narrative survives only in git history. The inventory says Story/Outcome are "refreshed from the new extraction". That wording hides the fact that the refresh never sees the earlier messages. Fix: on the update path, feed the existing Story/Outcome (or the full thread) into the prompt as context, or append rather than replace.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
