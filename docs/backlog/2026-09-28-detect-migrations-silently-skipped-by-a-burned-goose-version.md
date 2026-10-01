---
type: bug
title: Detect migrations silently skipped by a burned goose version
status: done
priority: med
tags: [db, migrations, goose, schema-drift, dev-db]
context: main (after PR #3, Confluence connector) — `confluence select` failed on the owner's dev DB
created: 2026-09-28
---

goose tracks applied migrations by `version_id` only. When a binary built from a
branch applies a migration under number N, and that migration is later renumbered
before merging, the migration that ends up at N on main is never applied to that
database. Nothing fails at migrate time: the gap shows up much later, as a
`no such table` error the first time a feature touches the missing table.

It has happened twice on the owner's dev database:

- **2026-07-17:** `gmail_messages` was missing. goose v16 had been burned by the
  transcriber branch.
- **2026-09-28:** `external_connections` (migration 00064) was missing. The
  agent-actions branch had burned v64 with its old `00064_reminders`, which was
  renumbered to 00065 in 98afb1f0. It surfaced as
  `watchtower confluence select ATLAS` → `creating ext source: SQL logic error:
  no such table: main.external_connections`, because `ext_sources` has a foreign
  key to it. Quick Connections was broken on that DB for the same reason. Fixed by
  hand: took a backup, then applied the migration's `CREATE TABLE IF NOT EXISTS`.

Released builds are not affected. v0.10.0, the only tag that contains the
colliding commit, already ships `00064_external_connections` +
`00065_reminders`. The risk is dev and branch databases, but the failure mode is
silent and lands far from its cause.

Proposal:

- At `db.Open` (or at least in `watchtower db migrate` and on daemon start),
  compare the tables declared in `internal/db/schema.sql` against `sqlite_master`.
  Columns are optional.
- Report any missing table loudly: a log line, a `watchtower db check` / doctor
  command, and possibly a Desktop banner.
- Optionally, auto-repair when the recorded goose version covers a migration
  whose Up is an idempotent `CREATE TABLE IF NOT EXISTS` and the table is absent.
- Test: a database with the goose row recorded but the table dropped is detected.
  If auto-repair is built, the same database is also repaired.

> Original note: «так а у других кастомеров как?» → «да» (to adding a startup schema-drift check to the backlog)

Resolution: `db.Open` now compares the tables `schema.sql` declares against `sqlite_master` after every migrate (`internal/db/schema_drift.go`). A missing table is re-applied only when its creating migration is made only of `CREATE ... IF NOT EXISTS` statements and no later migration alters, indexes, rebuilds, seeds or drops its tables (the `external_connections` incident qualifies). Every other missing table is logged as an error naming its migration, and `watchtower db migrate` exits non-zero with the same message after seeding prompts. A database migrated past the binary's newest migration is not checked. `TestSchemaDrift_EveryDeclaredTableIsRepairedExactlyOrReported` drops each declared table in turn. No Desktop banner (deferred).
