---
type: bug
title: "Boards → \"Sync Now\" always fails once two or more Jira sites are connected"
status: open
priority: med
tags: [swift, jira, multi-account, cli-args, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Swift Desktop)
created: 2026-09-26
---

**Where:** WatchtowerDesktop/Sources/Views/Settings/JiraSyncInfoView.swift:78-125 (args at :90); cmd/jira.go:341-363,1089
**Confidence:** high

`JiraSyncInfoView` (mounted in `BoardsView.swift:63`) runs `watchtower jira sync` with no `--account`. `runJiraSync` → `resolveJiraAccount` errors with "multiple Jira sites connected — pass --account <id>" whenever more than one account is enabled. With two Atlassian sites the button therefore always shows that error; with one it works. CLAUDE.md says "both boards screens pass `--account` on every CLI action", and this third section of the Boards screen was missed. Fix: loop `jira sync --account <id>` over the enabled accounts (the boards-refresh precedent), or give the section an account picker.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
