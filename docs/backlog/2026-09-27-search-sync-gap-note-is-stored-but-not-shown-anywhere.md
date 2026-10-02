---
type: bug
title: "Search-sync gap note is stored but not shown anywhere"
status: open
priority: low
tags: [slack, sync, desktop, review-2026-09-27]
context: follow-up from fix/backlog-wave2 (gap note now survives the run's ok write)
created: 2026-09-27
---

**Where:** WatchtowerDesktop/Sources/Views/Settings/SlackConnectionDetail.swift:184; cmd/slack.go (slack accounts)
**Confidence:** high

The search catch-up gap note ("gap of N days, messages not fetched") now persists in
`slack_accounts.error` while `status` stays `ok`, but the Desktop shows `account.error` only when
`status != ok` (a tooltip), and `watchtower slack accounts` does not print it. So the owner still never
sees that messages were skipped. Fix: show a non-error warning line in Settings → Slack and in
`slack accounts` when `error` is non-empty on an ok account.

> Original note: «так там два больших фичи влилось. Пройдись еще разок, дополнии беклог и давай его начинать закрывать»

Review note (fix/backlog-wave2): the note survives its own run but is erased by the next gap-free cycle (~15 min), and `TestRun_ClampedGapNoteSurvivesTheRunsOKWrite` pins that clearing — whoever implements this changes that assertion on purpose. Suggested shape: a separate `sync_gap_note` column cleared only when the owner acknowledges it (owner UX call: acknowledge vs keep N days).

**Status (fix/desktop-low-bundle):** shown: Settings → Slack puts an orange note under an ok workspace whose error column is set (`SlackAccount.syncNote`), and `watchtower slack accounts` prints it under the account line. Left: the note still lives only until the next gap-free cycle — keeping it (a separate column, acknowledge vs keep N days) is the owner UX call above.
