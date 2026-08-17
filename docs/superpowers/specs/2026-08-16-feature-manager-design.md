# Feature Manager — Design

**Date:** 2026-08-16
**Status:** Approved by owner (this session), pending implementation plan
**Owner request:** a Settings screen listing every feature with a description and an on/off switch, where "off" removes the feature from the UI and stops it consuming resources and AI tokens. Deferred from PR #101 (recorded when the owner declined a one-off Settings toggle for `streams.enabled` in favor of a general manager).

## Problem

Watchtower has grown ~20 daemon phases and a dozen user-facing surfaces, but there is no single place that answers "what does this app do, and what of it do I actually want running?" Concretely:

- Several AI pipelines have **no switch at all** — tracks, rollups, custom tracks, people cards, next-step suggestions burn tokens whenever `digest.enabled` is true.
- `digest.enabled` is a **de-facto master switch**: `cmd/sync.go` wraps the entire pipeline wiring block in one `if`, so per-feature keys only matter inside an enabled digest. Nobody chose this as a product behavior; it fell out of wiring history.
- The daemon reads config **once per process** and the Settings save bar does not restart it, so existing toggles appear dead until a manual restart.
- Feature toggles that do exist are scattered across three stores (config.yaml, per-account DB flags, Swift UserDefaults) with three different write paths (ConfigService/Yams, CLI, @AppStorage).

## Owner decisions (2026-08-16)

1. **Granularity:** product pillars + their existing sub-toggles. Integrations (Slack/Google/Jira/email accounts) stay in Connections and are out of scope.
2. **Dependencies:** cascade dialog. Disabling a feeder feature offers to also disable its dependents ("this affects X, Y"); no hard blocks, no silent cascades.
3. **Re-enable:** from-now. Watermarks fast-forward to the present; missed history is never auto-processed (catch-up only via existing manual backfills such as Ideas "Find Ideas").
4. **Core is not removable:** the Dashboard screen, Targets, and the secretary chat stay always-on (chat spends tokens only on demand). The feed index rides along as Dashboard infrastructure. Core entries appear in the list with a "Core" badge and no toggle.
5. **Meetings and Dictation are not managed features.** Their tabs, toggles, and flows stay exactly where they are. The manager only gets a RAM knob: a "keep ML engines in memory" toggle covering the meeting prewarm slot and the dictation sticky engine.
6. **Architecture:** approach A — static Go registry, config.yaml stays the single source of truth, apply = daemon restart.

## Feature registry

New package `internal/features/` — the generalization of the `JiraFeatureToggles` shape (struct + ordered names + resolver + CLI).

```go
type Feature struct {
    ID          string   // kebab-case, stable: "secretary-inbox"
    Title       string   // "Secretary Inbox"
    Description string   // one paragraph, user-facing
    ConfigKey   string   // "" for core entries
    Core        bool     // no toggle, always on
    Cost        Cost     // heavy | medium | light | none
    FeedsInto   []string // dependency edges for the cascade dialog
    SubToggles  []SubToggle // existing config keys surfaced under the pillar
    FastForward func(context.Context, *db.DB) error // nil when backlog is naturally bounded
}
```

The registry is static Go code — no DB table, no yaml section describing features. `features list --json` is the only export; Desktop renders from it and never duplicates titles/descriptions.

### Entries

| ID | Config key | Default | Cost | Feeds into |
|---|---|---|---|---|
| `dashboard` (Core) | — | on | none | — |
| `targets` (Core) | — | on | none | — |
| `chat` (Core) | — | on | none (spends only on demand) | — |
| `feed` (Core, infra) | `feed.enabled` (stays config-only) | on | none | — |
| `secretary-inbox` | `inbox.enabled` | on | heavy | memory, briefing |
| `slack-digests` | `digest.enabled` | on | heavy | secretary-inbox, tracks, people-cards, ideas, briefing |
| `stream-digests` | `streams.enabled` | on | medium | ideas, secretary-inbox |
| `tracks` | `tracks.enabled` **(new)** | on | heavy | briefing, memory |
| `people-cards` | `people.enabled` **(new)** | on | medium | — |
| `ideas` | `ideas.enabled` | on | medium | — |
| `memory` | `memory.enabled` | off | medium | briefing, day-plan |
| `briefing` | `briefing.enabled` | on | light | — |
| `day-plan` | `day_plan.enabled` | on | light | — |
| `next-step` | `targets.next_step.enabled` **(new)** | on | medium | — |

Notes:
- `stream-digests` is presented nested under `slack-digests` in the UI (`Parent` field), but is an independent gate — the daemon runs streams regardless of Slack digests. Its edge into `secretary-inbox` is the Jira comment sync feeding the `jira_comment_mention` trigger (INBOX-02).
- `tracks` covers auto tracks (+ TrackContext injection) and custom track scans — both also compound-gated on `digest.enabled` at the phase level, since they mine the digests table and would otherwise leak an empty `pipeline_runs` row every cycle with tracks on and digests off (see the phase table below). Rollups are a separate half of `phaseTracksAndRollups` and ride `digest.enabled` alone, independent of `tracks.enabled`.
- `people-cards` is likewise compound-gated on `digest.enabled` — it mines `people_signals` that only `phaseChannelDigests` produces.
- Sub-toggles v1: `memory` surfaces its existing branch (`memory.semantic.enabled`, `memory.sources.*` ×6, `memory.surfaces.*` ×6) in a collapsed "Advanced" disclosure. Dev/compare flags (`memory.retrieve.*_compare`, `memory.renders.digest_compare`, `memory.focus.enabled`) stay config-only — they are instruments, not options.
- Cost labels are static editorial judgments (heavy = many strong-tier calls per cycle), not live telemetry. Telemetry is a non-goal (v1).
- On-demand AI (chat, target Extract, manual backfills, dictation clean) is not gated by the manager: it spends tokens only on explicit user action and rides its surface's visibility.

## Demoting `digest.enabled` (wiring refactor)

The single `if cfg.Digest.Enabled` around the pipeline wiring block in `cmd/sync.go` is removed. Pipelines are constructed unconditionally (cheap structs); every phase gains its own gate, read from the startup config snapshot:

| Phase | Gate after refactor |
|---|---|
| phaseChannelDigests | `digest.enabled` |
| phaseFastInbox, phaseInbox | `inbox.enabled` (the `&& digest.enabled` coupling is dropped) |
| phaseTracksAndRollups (tracks half), phaseCustomTrackScan | `tracks.enabled && digest.enabled` — a real data dependency, not just a naming split: tracks mine the digests table (custom tracks' scan activity includes digest-derived events too), so `tracks.enabled` alone would still pass the phase gate, insert a `pipeline_runs` row, and have the pipeline return immediately — an empty row leaking every cycle instead of a clean skip |
| phaseTracksAndRollups (rollups half) | `digest.enabled` — independent of `tracks.enabled` |
| phasePeopleCards | `people.enabled && digest.enabled` — same empty-row-leak risk as tracks: people cards mine `people_signals` that only `phaseChannelDigests` produces |
| phaseNextStep | `targets.next_step.enabled` |
| phaseStreamDigests (+ Jira comment sync) | `streams.enabled` |
| phaseIdeas | `ideas.enabled` — moved from inside the pipeline up to the phase, so a disabled consolidator no longer takes the backfill lock or writes empty `pipeline_runs` rows every 6h |
| phaseMemory | `memory.enabled` |
| phaseBriefing | `briefing.enabled` |
| runDayPlanPhase / conflict phase | `day_plan.enabled` |
| phaseFeed | `feed.enabled` (core, config-only) |
| phaseUnsnooze, autoMarkRead, phaseTranscriptAudioCleanup | ungated (mechanical housekeeping, no AI) |
| source syncs (Slack/Calendar/Gmail/Jira/IMAP/CalDAV) | unchanged — integrations, out of scope |

Behavior note: the Jira `BoardAnalyzer` (the one AI call inside `phaseJiraSync`) is re-gated from `digest.enabled` to `jira.enabled` alone — it serves the Boards screens, not digests. Users who previously silenced it via `digest.enabled=false` get it back only if they have Jira connected and enabled.

### Back-compat migration

Legacy semantics: `digest.enabled=false` meant "pure source syncer" — every AI pipeline off regardless of its own key. After the demotion those pipelines would silently turn on. One-time config migration at load: if the file has `digest.enabled: false` and no `features.migrated` marker, write `false` into every non-core registry key, then write `features.migrated: 1`. Installs with digest on (the default) get only the marker. The migration writes the yaml once, atomically, 0600 (the existing `config set` writer).

## CLI

```
watchtower features list [--json]
watchtower features enable <id>
watchtower features disable <id> [--dry-run] [--with-dependents] [--json]
```

- `list` prints id, title, description, state (`enabled`/`disabled`/`core`), config key, cost, feeds-into, sub-toggle states. `--json` is the Desktop contract.
- `disable --dry-run --json` returns the transitive set of currently-enabled dependents — the input for the Desktop cascade dialog. Plain `disable` touches only the named feature; `--with-dependents` disables the computed set too. Nothing is ever cascaded implicitly (FEAT-04).
- `enable` writes the key and then runs the feature's `FastForward` hook (FEAT-03).
- Sub-toggles are plain config keys and go through the existing `watchtower config set` (no cascade/fast-forward semantics needed); the `knownConfigKeys` allowlist is extended to cover every registry key and sub-toggle.
- `jira features` stays a separate, integration-scoped command.

Write-path rule: all Feature Manager writes go through the CLI (`features`, `config set`), where cascade validation, fast-forward, and the allowlist live once. Swift's `ConfigService` keeps serving the tuning sections below the manager (existing behavior); its merge-on-save already tolerates concurrent CLI writes.

## Re-enable semantics (fast-forward)

`FastForward` is implemented where an unbounded backlog would otherwise burn tokens on re-enable:

- `secretary-inbox`: `inbox_last_processed_ts` and the compose watermark → now.
- `ideas`: the three workspace floors + per-account email/jira floors → current table tops (the migration-00050 seeding shape).
- `stream-digests`: per-account stage-1 floors → current tops.
- `memory`: the four extraction watermarks → now.

Digests, tracks, and people cards need no hook — their per-cycle input is already capped (`batch_max_messages`, chunked scans), so a gap is absorbed gradually without a token spike.

Fast-forward is an explicit owner action executed by the CLI outside any pipeline `Run` — the INBOX-09 / IDEA-01 watermark contracts (which constrain how *pipelines* may advance watermarks) are untouched. `docs/inventory/inbox-pulse.md` and `docs/inventory/ideas.md` get a cross-reference note.

## Desktop

**Features tab** (Settings → Features) is rebuilt: the manager list on top, the existing tuning sections below it, `NotificationSettings` unchanged.

- Rows come from `features list --json`, held in a `FeatureManagerViewModel` on `AppState` (async-state house rule). Each row: title, description, cost badge, toggle; Core rows show a badge instead of a toggle. `memory` shows its sub-toggle disclosure.
- Toggling off a feature with enabled dependents (per `disable --dry-run` run at toggle time) shows the cascade dialog: "This also affects: Ideas (less material), Briefing (thinner context)" with *Disable only X* / *Disable X and dependents* / *Cancel*.
- Changes accumulate locally and apply via the existing `ConfigSaveBar` flow: Save → sequential CLI calls → **one** `DaemonManager.restart()` (the account-VM precedent) → re-fetch `list --json`. Optimistic update with rollback on non-zero exit (the Jira features screen pattern).
- A tuning section (Digest, Briefing, Day Plan, Ideas) renders only while its feature is enabled.

**Sidebar.** `AppState` keeps `disabledFeatures: Set<String>` (loaded at launch and after each apply). A static Swift map assigns destinations to features; a destination is hidden iff **all** features mapped to it are disabled (any-of visibility):

- `catchUp` → slack-digests; `digests` → slack-digests, stream-digests, ideas (the Decisions ledger lives there); `ideas` → ideas; `memory` → memory; `briefings` → briefing; `dayPlan` → day-plan; `tracks` → tracks; `people` → people-cards. Everything else (inbox, targets, chat, calendar, statistics, tool items) is always visible.
- Hiding is a render-time filter layered over the existing section partition — `SidebarSectionTests.testEveryDestinationIsPlacedExactlyOnce` stays untouched (placement is not mutated). Root items become filterable too (tracks is a root item today).
- Disabled features' tabs disappear entirely — this is distinct from the cosmetic `sidebar.hiddenItems` mechanism, which remains as-is.
- If `selectedDestination` points at a tab that just disappeared, navigation falls back to `.inbox`.

**Dashboard banner.** With `secretary-inbox` off, the Dashboard (core, start screen) keeps showing existing situations but adds a banner: the secretary is off, no new situations will appear, with a link to Settings → Features (the Decisions empty-state precedent).

**ML engines row.** Swift appends one local row to the manager list (not part of the Go JSON): **"Keep ML engines in memory"**. Off = the meeting warm-engine slot/prewarm is disabled (existing `transcription.preloadBeforeMeetings` key) and `DictationCenter` drops its engine right after a dictation completes instead of the 15-minute idle TTL (new UserDefaults key). Meetings and Dictation features themselves are untouched.

## Contracts — new `docs/inventory/features.md`

- **FEAT-01 (off = silent):** a disabled feature makes zero new AI calls — its phases return before any provider invocation, and no locks/`pipeline_runs` rows are produced on its behalf.
- **FEAT-02 (off is non-destructive):** disabling deletes nothing; existing rows stay queryable and the UI reappears intact on re-enable.
- **FEAT-03 (resume from now):** enabling fast-forwards the feature's watermarks; missed history is processed only via explicit manual backfill.
- **FEAT-04 (no silent cascade):** disabling X never flips another feature's key unless the user confirmed the dependent list (dialog or `--with-dependents`).

## Testing

Go: registry validation (unique ids, every ConfigKey registered in defaults, edges resolve, core entries toggle-free); transitive cascade computation; the legacy-digest migration (digest off → keys written once, marker honored); per-phase gate tests (feature off → phase skipped, no AI runner invocation — FEAT-01); fast-forward tests per feature (watermarks/floors land on "now"/table tops); `features` CLI table tests including `--dry-run` JSON.

Swift: ConfigService round-trip pins for new keys; `FeatureManagerViewModel` against a fake CLI runner (list/apply/rollback, cascade dialog data); sidebar filter tests (destinations of disabled features absent; guard test untouched); `selectedDestination` fallback; Dashboard banner state; tuning-section gating.

## Non-goals (v1)

- Per-feature token/cost telemetry (cost badges are static).
- Hot-reload of config without restart (restart-on-apply is the mechanism; the daemon restart is bounded and cheap).
- Managing integrations (per-account switches stay in Connections; `calendar.enabled`/`gmail.enabled`/`jira.enabled` stay where they are).
- Disabling Meetings/Dictation as features, or any change to their tabs.
- Surfacing memory dev/compare flags.
- Any data deletion on disable.

## Cleanups riding along

- `knownConfigKeys` allowlist extended with all registry keys and surfaced sub-toggles (closes the "unknown key writes anyway with a warning" gap for these keys).
- `analysis.legacy_mode` is declared and never read (Go), and `ConfigService.analysisLegacyMode` + dead `jiraFeatures` state are unread on the Swift side — verify and drop all three.
- `targets.resolver.slack_enabled`/`jira_enabled`: one sweep reported read sites, another reported none — verify during implementation; drop if dead, otherwise leave config-only.

## Implementation slices (each an independent PR)

1. **Wiring refactor** — unconditional pipeline construction, per-phase gates, new keys (`tracks.enabled`, `people.enabled`, `targets.next_step.enabled`, all default on), legacy-digest migration, phaseIdeas gate lift. Behavior-neutral at defaults.
2. **Registry + CLI** — `internal/features/`, `features list/enable/disable`, cascade, fast-forward hooks, `docs/inventory/features.md`, allowlist extension.
3. **Desktop manager list** — Features tab rebuild, apply/restart flow, cascade dialog.
4. **Desktop visibility** — sidebar filtering, navigation fallback, Dashboard banner, tuning-section gating.
5. **ML engines row** — the Swift-local RAM toggle (prewarm + dictation residency).

Slices 1–2 are Go-only and land first; 3–5 are Swift and depend on 2's JSON contract.
