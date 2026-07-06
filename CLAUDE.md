# Watchtower — Developer Notes

**Project:** `watchtower` (Go module: `watchtower`)
**Backend:** Go 1.25, SQLite via `modernc.org/sqlite` (`database/sql`), see `go.mod`
**Desktop:** SwiftUI macOS app (Swift 5.10, macOS 14+), GRDB.swift, see `WatchtowerDesktop/Package.swift`

---

## Feature Notes

### Inbox Secretary + Secretary Dashboard (v73+, replaces Inbox Pulse pinned model; dashboard replaces the two-tier feed)
- `internal/inbox/` — `Pipeline.Run` phases in order: detectors (slack / jira / calendar / watchtower) → full-stream triage (`inbox.triage`, cheap model tier) → implicit learner → auto-resolve → **compose** (`inbox.compose`, `compose.go`/`runCompose`) → **situation cards** (`inbox.situation_card`, `situation_card.go`/`runSituationCards`, strong model tier) → archive → unsnooze. See `pipeline.go`'s `Run` for the authoritative order.
- Triage (`triage.go`) reviews every new trigger item plus a chunked scan of ordinary channel traffic (`cfg.Inbox.MaxTriageMessages` per cycle), assigning tier (action/ambient) and priority. It may only downgrade a trigger item's class, never upgrade one (INBOX-01, reworded for the dashboard in the 2026-07-06 changelog entry). Hard-muted sources are skipped before reaching the AI call.
- Two item classes still exist on signals: `actionable` vs `ambient` (auto-seen, auto-archive after 7 days; actionable stale after 14 days) — but they no longer drive two visual sections. Both feed the composer, which clusters triaged signals plus track/target updates into **situations** (`situations` + `situation_signals` tables, `internal/db/situations.go`): merging into an existing open situation when one already covers the story (DASH-01), never duplicating.
- The old pinned-selection AI call and `inbox_items.pinned` column were **removed** (migration 00010). The **per-item secretary card** stage (`inbox.card`, `card.go`) is now **also retired** — migration 00012 deregisters its prompt row; per-item cards are replaced by situation cards (`inbox.situation_card`) generated once per situation instead of once per inbox item.
- Situation cards (`situation_card.go`, `runSituationCards`) generate why-it-matters / summary / chronology for each situation via a stronger model, capped per cycle. Per-situation failures set `card_status='failed'` and the pipeline continues to the next situation; compose/card AI failures leave existing situations, ranks, and cards untouched and never advance the compose watermark (DASH-02) — the inbox watermark (INBOX-09) is unaffected since compose/cards run after triage has already committed.
- Converting a situation into a Target or Track (Desktop "Target"/"Track" buttons) sets `status='converted'` and stamps `converted_target_id`/`converted_track_id` — a link, not a delete, so the situation's history stays reachable (DASH-03).
- Watermark advance (INBOX-09): a detector error always freezes `inbox_last_processed_ts`; a triage error or cap advances it only to the last fully-triaged message, never past an unprocessed one — see `Run`'s watermark-decision block and `docs/inventory/inbox-pulse.md`.
- `workspace.secretary_profile` — a free-text brief the user writes about themselves, injected into the triage, composer, and situation-card prompts via `buildSecretaryBrief` so AI judgment reflects real context. Edited from the Desktop "Profile" tab (`SecretaryProfileView`).
- `inbox_learned_rules` table (implicit + user_rule sources) — `source='user_rule'` is protected from implicit overwrite. Rules are injected into AI prompts via `buildUserPreferencesBlock`. Mechanics unchanged from the pinned-era design.
- `inbox_feedback` table records raw 👍/👎 + reason; `inbox.SubmitFeedback` in Go maps (rating, reason) → rule upsert or class downgrade.
- Desktop: `InboxFeedView` now hosts the Dashboard tab — a single secretary-ranked situation feed (`DashboardView`/`DashboardViewModel`, `WatchtowerDesktop/Sources/Views/Dashboard/`) with kind badges (Signal/Target/Track/Mixed) and an inline context packet, replacing the old two-tier "Needs action"/"FYI" rows — plus the unchanged "Learned" tab (rules management) and "Profile" tab (secretary brief). Dashboard is the app's start screen (`AppState.selectedDestination` defaults to `.inbox`, labeled "Dashboard").
- Desktop feedback path: Swift `InboxFeedbackQueries.record(...)` mirrors the Go rule derivation logic so UI is immediately consistent.
- See `docs/inventory/dashboard.md` for the DASH-01/02/03 behavioral contracts and `docs/inventory/inbox-pulse.md` for INBOX-01..09.

---

## Database & Migrations

Schema changes use **goose** migrations — numbered SQL files in `internal/db/migrations/` (`0000N_<name>.sql`, each with `-- +goose Up` / `-- +goose Down`), auto-discovered via `//go:embed` and applied on `db.Open`. There is **no** hand-edited "schema version" int and PRAGMA `user_version` is legacy (Swift uses it only as a floor check). `CurrentSchemaFormat` in `internal/db/migrations.go` is the migration-engine version, not your schema version — do not bump it for ordinary changes.

When adding a table/column/CHECK, also mirror it into `internal/db/schema.sql` (embedded and injected into the AI prompt), add new tables to `TestAllTablesExist`, and regenerate the snapshot (`go test ./internal/db/ -run TestSchemaGolden -update`). SQLite has no `ALTER TABLE ... ADD CONSTRAINT`, so expanding an enum CHECK (`feedback.entity_type`, `targets.source_type`, `inbox_items.trigger_type`) requires the table-recreation dance — see `internal/db/migrations/00002`/`00003`.

The repeatable dev flows (migration, new AI prompt, new pipeline end-to-end, new Desktop tab) are documented as project skills in `.claude/skills/` (`add-migration`, `add-ai-prompt`, `add-pipeline`, `add-desktop-feature`). Use them; they encode the load-bearing steps and gotchas.

---

## Behavior Inventory

Behavioral contracts that must not be modified without explicit owner approval are catalogued in `docs/inventory/`. Before touching code in any module covered by inventory, read the corresponding file and treat each entry as load-bearing.

Module → file mapping is in [docs/inventory/README.md](docs/inventory/README.md).

If a proposed change would weaken or break a guard test, **stop and ask the owner** before proceeding. Do not "improve" a guard test by relaxing its assertions, renaming it out of the `Test<Module>NN_` convention, or splitting it into multiple weaker tests.
