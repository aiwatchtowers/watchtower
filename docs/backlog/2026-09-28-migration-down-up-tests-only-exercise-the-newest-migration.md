---
type: chore
title: Migration down/up tests only exercise the newest migration
status: open
priority: low
tags: [db, migrations, goose, test-coverage]
context: review of PR #14 (fix/bl-partial-failure-sweep), which had to switch TestMigration00076_DownUpKeepsMessages to goose.DownTo(75)
created: 2026-09-28
---

Several `Test*MigrationDownUpCycle`-style tests in `internal/db/db_test.go`
(four `TestMemory*MigrationDownUpCycle` tests, per the PR #14 reviewer) call a
plain `goose.Down`, which rolls back only the newest migration. They were
written when their migration was the newest one; as soon as a later migration
lands they silently test that later migration's Down instead of their own, and
can also start failing for unrelated reasons (PR #14 hit exactly that with
00076).

Fix: pin each test to its own version with `goose.DownTo(<N-1>)` followed by
`goose.UpTo(<N>)` (or `goose.Up`), and consider a helper that takes the
migration number so new migrations follow the right pattern by default.

> Original note: surfaced by the PR #14 code review (not an owner note).
