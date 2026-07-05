---
name: add-migration
description: Use when adding or changing a SQLite table, column, index, or CHECK constraint in the Watchtower Go backend — schema migrations, goose files, expanding entity_type/source_type/trigger_type enums, or keeping schema.sql in sync for the AI prompt.
---

# Add a DB Migration (Watchtower)

Watchtower uses **goose** migrations (numbered `.sql` files), NOT PRAGMA `user_version` or a hand-edited version int. CLAUDE.md's "schema version N" notes are historical — ignore them; follow the goose flow below.

## Steps

1. **Create the migration file** `internal/db/migrations/0000N_<name>.sql` (next number after the highest existing — currently `00003`). It is auto-discovered via `//go:embed`; no registration code. Every file needs both blocks:
   ```sql
   -- +goose Up
   ALTER TABLE targets ADD COLUMN notified_at TEXT NOT NULL DEFAULT '';

   -- +goose Down
   ALTER TABLE targets DROP COLUMN notified_at;
   ```

2. **Changing a CHECK constraint?** SQLite has no `ALTER TABLE ... ADD CONSTRAINT`. You must recreate the table (see `00002_target_due_inbox.sql` / `00003_catchup_review.sql` for the exact dance):
   - `PRAGMA defer_foreign_keys = ON;` if the table has inbound FKs.
   - `CREATE TABLE x_new (...)` with the expanded CHECK → `INSERT INTO x_new SELECT ... FROM x` (filter legacy rows in the Down) → `DROP TABLE x` → `ALTER TABLE x_new RENAME TO x` → recreate ALL indexes (`CREATE INDEX IF NOT EXISTS ...`).
   - The three enums that recur: `feedback.entity_type`, `targets.source_type`, `inbox_items.trigger_type`.

3. **Mirror the change in `internal/db/schema.sql`** — this file is embedded (`schema_embed.go`) and injected verbatim into the AI system prompt so the model can query via MCP. A new table/column the AI should see MUST land here too.

4. **New table → add it to `TestAllTablesExist`** in `internal/db/db_test.go` (hardcoded list; the test fails otherwise — this is the intended guard).

5. **Regenerate the schema snapshot** and commit it:
   ```bash
   go test ./internal/db/ -run TestSchemaGolden -update
   ```
   Commit the migration AND the updated `internal/db/testdata/*.golden`.

6. **Verify:** `go test ./internal/db/ -run 'TestMigrationIdempotent|TestAllTablesExist|TestSchemaGolden'`.

## Gotchas

- **Don't bump `CurrentSchemaFormat`** (`internal/db/migrations.go`). It's the migration-*engine* version (=2, goose), not your schema version. Goose tracks applied versions in `goose_db_version` automatically.
- **`SetMaxOpenConns(1)`** is already set in `db.go:44` — never remove it. `:memory:` gives each connection a *separate* DB, and per-connection pragmas wouldn't apply to a pool. Any new `db.Open`/`sql.Open` you add keeps this.
- **Down must be real.** Tests replay migrations; a stub Down that loses data fails idempotence.
- **Recreate every index** after a table-recreation, or queries silently lose their index.
- **Generated columns** (e.g. `messages.ts_unix GENERATED ALWAYS AS ...`) must be reproduced in the new table def; never INSERT into them.
- **Contract change?** If the table is covered by `docs/inventory/`, update/add a guard test in `internal/db/schema_contracts_test.go` — and if a guard would weaken, **stop and ask the owner** (per CLAUDE.md).

## Reference files
- Engine: `internal/db/migrations.go` · existing migrations: `internal/db/migrations/00001_init.sql`, `00002_target_due_inbox.sql`, `00003_catchup_review.sql`
- AI schema: `internal/db/schema.sql` (+ `schema_embed.go`) · pragmas: `internal/db/db.go`
- Tests/guards: `internal/db/db_test.go`, `schema_contracts_test.go`, `schema_snapshot_test.go`

When done, run `local-review` before opening a PR.
