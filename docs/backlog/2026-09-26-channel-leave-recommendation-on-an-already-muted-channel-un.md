---
type: bug
title: "Channel \"leave\" recommendation on an already-muted channel un-mutes it when applied"
status: open
priority: med
tags: [test-coverage, statistics, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track test coverage (Swift Desktop)
created: 2026-09-26
---

**Where:** WatchtowerDesktop/Sources/Database/Queries/ChannelStatsQueries.swift:131-152, WatchtowerDesktop/Sources/ViewModels/ChannelStatsViewModel.swift:153-192
**Confidence:** high

The mute branch skips channels that are already muted (`!s.isMutedForLLM`), but the "leave" branch has no muted check. `applyRecommendation` maps both `.mute` and `.leave` to `toggleMute(channelID:)`, which flips the current value. Scenario: a channel is muted for the LLM, not a favorite, not watched, the owner is a member, and the owner has no messages in it. The mute rule is skipped because the channel is already muted, so the leave rule fires. The user clicks Apply and the channel is **un-muted**, so the channel is fed back into AI pipelines. The recommendation apply path and `toggleMute`/`toggleFavorite` have no tests. `ChannelStatsTests` covers only the fetch and the `muteHighBotRatio` rule. Fix: `applyRecommendation` should set an explicit target value (mute = true) instead of toggling. Also skip or reword the leave rule for muted channels. Add a test for this exact case.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
