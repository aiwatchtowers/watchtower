---
type: chore
title: "Daemon account wiring (status writers, per-account isolation, Outlook token rotation) is 0% covered"
status: open
priority: med
tags: [test-coverage, auth, multi-account, daemon, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track test coverage (Go)
created: 2026-09-26
---

**Where:** cmd/sync.go:842 (wireJiraSyncers 0%), cmd/sync.go:924 (wireGoogleSyncers 0%), cmd/sync.go:976 (recordGoogleWireError 0%), cmd/sync.go:991 (wireImapSyncers 0%), cmd/sync.go:1038 (wireCalDAVSyncers 0%), cmd/sync.go:1067 (outlookAuthenticator 0%), cmd/sync.go:327 (runSyncNow 0%)
**Confidence:** high

CLAUDE.md specifies several contracts here: `wireJiraSyncers` is one of the three split Jira status writers (it writes `"error"` for a missing token or cloud_id, and only flips a currently-`ok` row), one Google account's auth failure must never block the others, and Outlook's `RefreshFunc` must re-persist a rotated refresh token. Only `wireSlackSyncers` has tests (52%). Nothing would catch any of these regressions: the Jira wiring churning the status every cycle, the only-flip-ok guard being lost, a Google wire error aborting the loop, or a rotated Microsoft refresh token no longer being saved (the account would break once the old token expires). `sync --now` (SIGUSR1 to the pidfile) is also untested at the cmd level. Suggested fix: the `TestWireSlackSyncers_*` shape for the other four wirers, plus a unit test of `outlookAuthenticator`'s RefreshFunc against a stub token endpoint that asserts the store holds the new refresh token.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
