# Feature Manager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Settings screen listing every feature with a description and an on/off switch, where "off" removes the feature's UI and stops its daemon phases (zero AI tokens), per the approved spec `docs/superpowers/specs/2026-08-16-feature-manager-design.md`.

**Architecture:** Static Go registry (`internal/features/`) + config.yaml as the single source of truth + `watchtower features` CLI (cascade + fast-forward live in Go once) + Desktop renders from `features list --json` and applies via CLI calls followed by one daemon restart. `digest.enabled` is demoted from de-facto master switch to the Slack-digests feature key.

**Tech Stack:** Go 1.25 (cobra/viper, modernc SQLite), SwiftUI/GRDB (WatchtowerDesktop), goose migrations NOT needed (no schema change).

## Global Constraints

- Work in worktree `/Users/user/PhpstormProjects/watchtower/.claude/worktrees/feature-manager`, branch `feature/feature-manager`. NEVER touch the main checkout at `/Users/user/PhpstormProjects/watchtower` (another session works there). Every shell command in this plan is run from the worktree root unless stated otherwise.
- Everything committed to the repo is in English (code, comments, docs, commit messages).
- Commit after each task with the message given in the task; end every commit message with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.
- Inner loop: `go test ./internal/<pkg>` / `go test ./cmd`; Swift `cd WatchtowerDesktop && swift test --filter <TestClass>`. No `-count=1`. Never delete `WatchtowerDesktop/.build`.
- Before touching inbox/ideas/dashboard code paths read `docs/inventory/inbox-pulse.md`, `docs/inventory/ideas.md`, `docs/inventory/dashboard.md`. Never weaken a guard test (`Test<Module>NN_` convention and `SidebarSectionTests`).
- All new config keys default to **true** (current behavior preserved at defaults); `memory.enabled` stays false.
- The spec's contracts: FEAT-01 (off = zero new AI calls, no locks/`pipeline_runs` rows), FEAT-02 (off is non-destructive), FEAT-03 (enable = fast-forward, never auto-backfill), FEAT-04 (no silent cascade).

---

## Slice 1 — Go: per-feature gates (behavior-neutral at defaults)

### Task 1: New config keys (`tracks.enabled`, `people.enabled`, `targets.next_step.enabled`)

**Files:**
- Modify: `internal/config/config.go` (structs ~line 105-201, SetDefault block ~line 395/454)
- Modify: `internal/config/defaults.go` (add constants)
- Test: `internal/config/config_test.go` (follow the existing default-assert style in that file)

**Interfaces (Produces):** `cfg.Tracks.Enabled bool`, `cfg.People.Enabled bool` (new struct `PeopleConfig`), `cfg.Targets.NextStep.Enabled bool` (new struct `TargetsNextStepConfig`), all default true.

- [ ] **Step 1: Write the failing test** — in `internal/config/config_test.go` add:

```go
func TestFeatureGateDefaults(t *testing.T) {
	cfg, err := Load(filepath.Join(t.TempDir(), "absent.yaml"))
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if !cfg.Tracks.Enabled {
		t.Error("tracks.enabled should default true")
	}
	if !cfg.People.Enabled {
		t.Error("people.enabled should default true")
	}
	if !cfg.Targets.NextStep.Enabled {
		t.Error("targets.next_step.enabled should default true")
	}
}
```

- [ ] **Step 2: Run it, expect compile failure** — `go test ./internal/config -run TestFeatureGateDefaults` → FAIL (`cfg.People undefined`).
- [ ] **Step 3: Implement** — in `config.go`:
  - `TracksConfig` gains `Enabled bool \`mapstructure:"enabled"\`` (keep `MinMessages`).
  - New `type PeopleConfig struct { Enabled bool \`mapstructure:"enabled"\` }`; add `People PeopleConfig \`mapstructure:"people"\`` to `Config` (next to `Tracks`).
  - New `type TargetsNextStepConfig struct { Enabled bool \`mapstructure:"enabled"\` }`; add `NextStep TargetsNextStepConfig \`mapstructure:"next_step"\`` to `TargetsConfig`.
  - In `Load` defaults block add, next to `tracks.min_messages`:

```go
	v.SetDefault("tracks.enabled", DefaultTracksEnabled)
	v.SetDefault("people.enabled", DefaultPeopleEnabled)
	v.SetDefault("targets.next_step.enabled", DefaultTargetsNextStepEnabled)
```

  - In `defaults.go` add `DefaultTracksEnabled = true`, `DefaultPeopleEnabled = true`, `DefaultTargetsNextStepEnabled = true` (place near `DefaultTracksMinMsgs`).
- [ ] **Step 4: Run** `go test ./internal/config` → PASS.
- [ ] **Step 5: Commit** — `feat(config): add tracks/people/next-step feature gate keys`

### Task 2: Legacy-digest config migration

**Files:**
- Create: `internal/config/feature_migrate.go`
- Test: `internal/config/feature_migrate_test.go`

**Interfaces (Produces):** `config.MigrateFeatureGates(configPath string) (migrated bool, err error)` — later called from daemon start (Task 4) and the `features` CLI (Task 7).

Behavior (spec "Back-compat migration"): if the yaml **file** contains an explicit `digest.enabled: false` AND no `features.migrated` key, write `false` into every non-core feature key (`inbox.enabled`, `streams.enabled`, `tracks.enabled`, `people.enabled`, `ideas.enabled`, `memory.enabled`, `briefing.enabled`, `day_plan.enabled`, `targets.next_step.enabled` — `digest.enabled` itself is already false) and `features.migrated: 1`, atomically. In every other case (file absent, digest absent or true, marker present) write nothing and return `migrated=false` — the marker is only ever written together with a real migration, so a default install's file stays untouched.

- [ ] **Step 1: Failing tests** — `feature_migrate_test.go` with three cases:

```go
func TestMigrateFeatureGates_LegacyDigestOff(t *testing.T) {
	p := filepath.Join(t.TempDir(), "config.yaml")
	os.WriteFile(p, []byte("digest:\n  enabled: false\n"), 0o600)
	migrated, err := MigrateFeatureGates(p)
	if err != nil || !migrated {
		t.Fatalf("migrated=%v err=%v", migrated, err)
	}
	cfg, _ := Load(p)
	for name, got := range map[string]bool{
		"inbox": cfg.Inbox.Enabled, "streams": cfg.Streams.Enabled,
		"tracks": cfg.Tracks.Enabled, "people": cfg.People.Enabled,
		"ideas": cfg.Ideas.Enabled, "briefing": cfg.Briefing.Enabled,
		"day_plan": cfg.DayPlan.Enabled, "next_step": cfg.Targets.NextStep.Enabled,
	} {
		if got {
			t.Errorf("%s should be false after migration", name)
		}
	}
	// Second run is a no-op (marker present).
	migrated2, err := MigrateFeatureGates(p)
	if err != nil || migrated2 {
		t.Fatalf("second run migrated=%v err=%v", migrated2, err)
	}
}

func TestMigrateFeatureGates_DigestOnUntouched(t *testing.T) {
	p := filepath.Join(t.TempDir(), "config.yaml")
	orig := []byte("digest:\n  enabled: true\n")
	os.WriteFile(p, orig, 0o600)
	if migrated, err := MigrateFeatureGates(p); err != nil || migrated {
		t.Fatalf("migrated=%v err=%v", migrated, err)
	}
	after, _ := os.ReadFile(p)
	if !bytes.Equal(after, orig) {
		t.Error("file must be byte-identical when no migration is needed")
	}
}

func TestMigrateFeatureGates_NoFile(t *testing.T) {
	if migrated, err := MigrateFeatureGates(filepath.Join(t.TempDir(), "absent.yaml")); err != nil || migrated {
		t.Fatalf("migrated=%v err=%v", migrated, err)
	}
}
```

- [ ] **Step 2: Run** `go test ./internal/config -run TestMigrateFeatureGates` → FAIL (undefined).
- [ ] **Step 3: Implement** `feature_migrate.go`: read the file with a fresh `viper.New()` + `v.SetConfigFile(path)` + `ReadInConfig` (return `false, nil` on not-exist); use `v.InConfig("digest.enabled")`-style presence checks via `v.IsSet` on a viper that has NO defaults registered (raw file only) — `if !v.IsSet("digest.enabled") || v.GetBool("digest.enabled") || v.IsSet("features.migrated") { return false, nil }`; then `v.Set` each key false, `v.Set("features.migrated", 1)`, and write atomically. Reuse the atomic-write shape from `cmd/config.go`'s `writeConfigAtomic` — that helper lives in `cmd`, so give `internal/config` its own small `writeConfigAtomic(v *viper.Viper, path string)` copy (unexported; `cmd`'s stays as is).
- [ ] **Step 4: Run** `go test ./internal/config` → PASS.
- [ ] **Step 5: Commit** — `feat(config): one-time migration for legacy digest.enabled=false installs`

### Task 3: Demote `digest.enabled` — unconditional wiring + per-phase gates

**Files:**
- Modify: `cmd/sync.go` (`runSyncDaemon` lines 459-517; the `if cfg.Digest.Enabled {` wrapper at 465 and its closing brace at 495 are removed — the block body stays, unindented; the inner `if cfg.Briefing.Enabled`/`if cfg.Inbox.Enabled`/`if cfg.DayPlan.Enabled`/`if cfg.Feed.Enabled` conditionals are also removed so every pipeline is always constructed)
- Modify: `internal/daemon/daemon.go` phase funcs (anchors below)
- Modify: `cmd/ideas.go` `wireIdeasPipeline` (~line 89): wire unconditionally (drop the `ideas.enabled || streams.enabled` condition)
- Modify: `cmd/sync.go` `wireJiraSyncers`: the `BoardAnalyzer` attach currently sits behind a `cfg.Digest.Enabled` check (~line 630) — attach it whenever Jira is wired (spec behavior note: it serves Boards, not digests)
- Test: `internal/daemon/daemon_gates_test.go` (new)

**Interfaces (Consumes):** Task 1's `cfg.Tracks.Enabled` / `cfg.People.Enabled` / `cfg.Targets.NextStep.Enabled`.

Gate table to implement — each phase gets an early `if !d.config.<Key> { return }` placed BEFORE any pipe nil-check, lock, throttle, or `trackedPipelineRun` (FEAT-01):

| Phase (anchor) | Gate added |
|---|---|
| `phaseFastInbox` (daemon.go:583) | `d.config.Inbox.Enabled` |
| `phaseChannelDigests` (:595) | `d.config.Digest.Enabled` |
| `phaseCustomTrackScan` (:1026) | `d.config.Tracks.Enabled` |
| `phaseTracksAndRollups` (:729) | tracks half (`d.tracksPipe` block incl. TrackContext injection): `d.config.Tracks.Enabled`; rollups half (`d.digestPipe.RunRollups`): `d.config.Digest.Enabled` |
| `phasePeopleCards` (:770) | `d.config.People.Enabled` |
| `phaseInbox` (:798) | `d.config.Inbox.Enabled` |
| `phaseIdeas` (:842) | `d.config.Ideas.Enabled` — before the throttle/lock, closing the lock-when-disabled quirk |
| `phaseNextStep` (:1009) | `d.config.Targets.NextStep.Enabled` |
| `phaseBriefing` (:1042) | `d.config.Briefing.Enabled` (keep `shouldRunBriefing`) |
| `runDayPlanPhase` (:1269) + `runDayPlanConflictPhase` (:1300) | `d.config.DayPlan.Enabled` |
| `phaseFeed` (:993) | `d.config.Feed.Enabled` |

`phaseStreamDigests` (:910) and `phaseMemory` (:963) already gate on their keys — leave as-is. Sync phases, `phaseUnsnooze`, `autoMarkRead`, `phaseTranscriptAudioCleanup` stay ungated.

- [ ] **Step 1: Failing tests** — `internal/daemon/daemon_gates_test.go`. Pattern: a Daemon with an in-memory DB and a **constructed** pipeline, feature flag off ⇒ calling the phase directly leaves `pipeline_runs` empty (FEAT-01's observable). Check how existing daemon tests construct a Daemon + DB first (`ls internal/daemon/*_test.go`, reuse their helpers). Cover at minimum:

```go
func TestFeatureGates_DisabledPhaseWritesNoPipelineRun(t *testing.T) {
	// table-driven over: digests, inbox, tracks(+custom), people, ideas,
	// next_step, briefing, day_plan, feed — for each: cfg flag false,
	// pipeline constructed (cheap struct via its New), phase invoked,
	// assert COUNT(*) FROM pipeline_runs == 0 and (ideas only) that no
	// ideas_backfill.lock file appeared in the workspace dir.
}
```

  For `phaseIdeas` the lock assertion is the load-bearing one (the quirk being fixed): flag off ⇒ `ideas.AcquireBackfillLock` is never called ⇒ no `ideas_backfill.lock` in `cfg.WorkspaceDir()`.
- [ ] **Step 2: Run** `go test ./internal/daemon -run TestFeatureGates` → FAIL (ideas lock file appears; other subtests may pass only where a nil pipe already returns — construct pipes so the gate is what's tested).
- [ ] **Step 3: Implement** the gate table + the three wiring changes (`cmd/sync.go` wrapper removal, `wireIdeasPipeline` unconditional, BoardAnalyzer attach). Keep construction order and `defer cleanupPool()` exactly as today.
- [ ] **Step 4: Run** `go test ./internal/daemon ./cmd ./internal/config` → PASS. Then `go build ./...`.
- [ ] **Step 5: Commit** — `feat(daemon): per-feature phase gates; demote digest.enabled from master switch`

### Task 4: Call the migration from daemon start + extend `knownConfigKeys`

**Files:**
- Modify: `cmd/sync.go` `runSyncDaemon` (top, before wiring): call `config.MigrateFeatureGates(flagConfig)`; on `migrated==true` log it and **re-load** the config into `cfg` so this very process runs with the migrated values (`config.Load(flagConfig)`).
- Modify: `cmd/config.go` `knownConfigKeys`: add `"tracks.enabled"`, `"people.enabled"`, `"targets.next_step.enabled"`, `"inbox.enabled"`, `"ideas.enabled"`, `"ideas.mine_interval_hours"`, `"streams.enabled"`, `"streams.interval_hours"`, `"briefing.enabled"`, `"briefing.hour"`, `"day_plan.enabled"`, `"feed.enabled"`, `"calendar.enabled"`, `"gmail.enabled"`, `"jira.enabled"`, `"transcripts.audio_retention_days"`, `"features.migrated"`.
- Test: extend `cmd`'s config tests (`go test ./cmd -run TestConfig`) with one case asserting `watchtower config set tracks.enabled false` prints no "not a recognized" warning (see existing `runConfigSet` test style in `cmd/config_test.go`; if none exists, add a direct unit test on the `knownConfigKeys` map listing the new keys).

- [ ] **Step 1: Failing test** (map-membership test is fine and honest).
- [ ] **Step 2-4:** implement, `go test ./cmd ./internal/config`, `go build ./...` → PASS.
- [ ] **Step 5: Commit** — `feat(cmd): run feature-gate migration at daemon start; recognize feature keys in config set`

---

## Slice 2 — Go: registry + `features` CLI

### Task 5: `internal/features` registry

**Files:**
- Create: `internal/features/registry.go`
- Test: `internal/features/registry_test.go`

**Interfaces (Produces):**

```go
package features

type Cost string // "heavy" | "medium" | "light" | "none"

type Feature struct {
	ID          string
	Title       string
	Description string // one user-facing paragraph, English
	ConfigKey   string // "" for core entries
	Parent      string // presentation nesting ("" = top-level); stream-digests → slack-digests
	Core        bool
	Cost        Cost
	FeedsInto   []string
	SubToggles  []SubToggle
	Enabled     func(*config.Config) bool // nil for core entries without a key
}

type SubToggle struct {
	Key         string // full config key, e.g. "memory.semantic.enabled"
	Title       string
	Description string
}

func All() []Feature                  // stable order: core first, then the table order from the spec
func ByID(id string) (Feature, bool)
func Dependents(id string, cfg *config.Config) []Feature // transitive, enabled-only, stable order
```

Entries: exactly the spec table — core `dashboard`/`targets`/`chat`/`feed`, then `secretary-inbox` (inbox.enabled, heavy, feeds memory+briefing), `slack-digests` (digest.enabled, heavy, feeds secretary-inbox+tracks+people-cards+ideas+briefing), `stream-digests` (streams.enabled, medium, Parent slack-digests, feeds ideas+secretary-inbox), `tracks` (tracks.enabled, heavy, feeds briefing+memory), `people-cards` (people.enabled, medium), `ideas` (ideas.enabled, medium), `memory` (memory.enabled, medium, feeds briefing+day-plan, SubToggles = memory.semantic.enabled + the six memory.sources.* + the six memory.surfaces.* keys with one-line titles/descriptions), `briefing` (briefing.enabled, light), `day-plan` (day_plan.enabled, light), `next-step` (targets.next_step.enabled, medium). `feed` carries ConfigKey "feed.enabled" + Core:true (config-only, no toggle). Descriptions: write them now, one paragraph each, plain user language naming what it does, what it costs, and who it feeds (e.g. secretary-inbox: "Triages every new mention, DM and thread reply, clusters them into situations on the Dashboard and writes a secretary card per situation. Heavy AI use each cycle. Feeds Memory and the daily Briefing.").

- [ ] **Step 1: Failing tests:**

```go
func TestRegistry_Valid(t *testing.T) {
	// ids unique and kebab-case; every non-core entry has ConfigKey,
	// Enabled != nil, non-empty Title/Description; every FeedsInto and
	// Parent resolves via ByID; core entries have no Enabled requirement.
}

func TestRegistry_EnabledReadsConfig(t *testing.T) {
	// cfg with Inbox.Enabled=false ⇒ ByID("secretary-inbox").Enabled(cfg)==false;
	// defaults ⇒ every non-core Enabled(cfg) matches the spec defaults
	// (memory false, everything else true).
}

func TestRegistry_DependentsTransitive(t *testing.T) {
	// Dependents("slack-digests", defaults) contains secretary-inbox, tracks,
	// people-cards, ideas, briefing AND (transitively via secretary-inbox)
	// memory only when memory is enabled; with cfg.Memory.Enabled=false it
	// must NOT contain memory. Dependents("briefing", cfg) is empty.
}
```

- [ ] **Step 2:** `go test ./internal/features` → FAIL. **Step 3:** implement (Dependents = BFS over FeedsInto edges, dedupe, filter `f.Enabled(cfg)`, exclude the start node). **Step 4:** PASS. **Step 5: Commit** — `feat(features): static feature registry with dependency edges`

### Task 6: Fast-forward hooks

**Files:**
- Create: `internal/features/fastforward.go`
- Test: `internal/features/fastforward_test.go`

**Interfaces (Produces):** `func FastForward(id string, database *db.DB, now time.Time) error` — dispatch on id; no-op (nil) for features without a hook.

Hooks (spec "Re-enable semantics"):
- `secretary-inbox`: `database.SetInboxLastProcessedTS(float64(now.Unix()))` and set `workspace.compose_last_run_ts` the same way. Discovery step: `grep -rn "compose_last_run_ts" internal/db/*.go | grep -v _test` — a setter exists next to the compose watermark reader in `internal/db` (used by `internal/inbox/compose.go`); reuse it, do NOT write raw SQL in the features package.
- `ideas`: floors to current table tops, exactly the migration-00050 seeding semantics: `SELECT COALESCE(MAX(id),0) FROM digests` → digest floor, same for `stream_digests` → stream floor and `meeting_transcripts` → transcript floor, applied via `database.SetIdeasFloors(digest, stream, transcript)` (internal/db/ideas.go:397). Per-account floors: grep `ideas_email_floor`/`ideas_jira_floor` setters in `internal/db/google_accounts.go` / `internal/db/jira_accounts.go` and set each connected account's floor to the same source-table top the stage-1 pass uses (mirror what `internal/ideas`'s stage-1 self-init does — read that code first, `internal/ideas/*.go`, grep `ideas_email_floor`).
- `stream-digests`: the per-account floors part of the above only.
- `memory`: `database.SetMemoryWatermark(float64(now.Unix()))` (internal/db/memory.go:720) + per-account `memory_gmail_last_extracted_ts` / `memory_jira_last_extracted_ts` and workspace `memory_calendar_last_extracted_ts` via their existing setters (grep each name in `internal/db`; every one has a setter used by the extractors).
- Everything else → nil (digests/tracks/people are cap-bounded per spec).

- [ ] **Step 1: Failing tests** — in-memory DB via the `internal/db` test helper (see `internal/db/ideas_test.go` setup), seed a workspace row + a few `digests`/`stream_digests` rows with known ids, then:

```go
func TestFastForward_Inbox(t *testing.T)  // watermark + compose ts == now.Unix()
func TestFastForward_Ideas(t *testing.T)  // floors == MAX(id) of each table
func TestFastForward_Memory(t *testing.T) // watermark == now.Unix()
func TestFastForward_NoHookIsNil(t *testing.T) // FastForward("briefing", db, now) == nil, no writes
```

- [ ] **Step 2-4:** red → implement → `go test ./internal/features` PASS.
- [ ] **Step 5: Commit** — `feat(features): fast-forward hooks so re-enable resumes from now (FEAT-03)`

### Task 7: `watchtower features` CLI

**Files:**
- Create: `cmd/features.go`
- Test: `cmd/features_test.go`

**Interfaces (Produces):** the JSON contract Desktop consumes (Task 9):

```json
{"features":[{"id":"secretary-inbox","title":"Secretary Inbox","description":"…","state":"enabled","core":false,"parent":"","config_key":"inbox.enabled","cost":"heavy","feeds_into":["memory","briefing"],"sub_toggles":[{"key":"memory.semantic.enabled","title":"…","description":"…","enabled":false}]}]}
```

`state` ∈ `enabled|disabled|core`. `disable --dry-run --json` prints `{"feature":"slack-digests","dependents":[{"id":"ideas","title":"Ideas"},…]}` and writes nothing.

Commands (register in `init()` on `rootCmd`, the `cmd/jira.go` `features` sub-command shape at cmd/jira.go:1123+ is the precedent for table output):
- `features list [--json]` — loads config (`config.Load(flagConfig)`), renders registry + per-entry state; sub-toggle `enabled` read via `viper` on the loaded file (a fresh viper with the same defaults — just call `config.Load` and read struct fields; map each SubToggle key to its struct field through a small `subToggleEnabled(cfg, key)` switch in `cmd/features.go`).
- `features enable <id>` — validate id (not core, exists — error text lists valid ids); write `ConfigKey: true` via the `runConfigSet` machinery (factor the typed-write core of `runConfigSet` into `setConfigKey(configPath, key string, value any) error` and call it from both); then open the DB (`openDatabase` helper used by other cmd files — grep `db.Open(` in `cmd/*.go` for the standard open call) and run `features.FastForward(id, database, time.Now())`; print what was fast-forwarded.
- `features disable <id> [--dry-run] [--with-dependents] [--json]` — compute `features.Dependents(id, cfg)`; `--dry-run` prints and exits 0; plain run writes only `<id>`'s key false; `--with-dependents` also writes each dependent's key false. Never writes a dependent without the flag (FEAT-04).
- `PersistentPreRunE` on the `features` parent command: `config.MigrateFeatureGates(flagConfig)` (ignore `migrated` result beyond logging).

- [ ] **Step 1: Failing tests** — `cmd/features_test.go`, the cobra-execute style used by `cmd/slack_test.go` (temp config path via `flagConfig`, `ExecuteContext`, capture stdout):

```go
func TestFeaturesList_JSONShape(t *testing.T)        // parses, contains secretary-inbox with state enabled
func TestFeaturesDisable_DryRunWritesNothing(t *testing.T) // config file byte-identical after
func TestFeaturesDisable_WritesOnlyNamedKey(t *testing.T)  // inbox.enabled false; ideas.enabled still absent/true
func TestFeaturesDisable_WithDependents(t *testing.T)      // slack-digests + all enabled dependents false
func TestFeaturesEnable_RunsFastForward(t *testing.T)      // uses a temp DB; inbox watermark == now after enable
func TestFeatures_CoreRejected(t *testing.T)               // enable/disable "targets" → error mentioning core
```

- [ ] **Step 2-4:** red → implement → `go test ./cmd -run TestFeatures` PASS; `go build ./...`.
- [ ] **Step 5: Commit** — `feat(cmd): watchtower features list/enable/disable with cascade dry-run and fast-forward`

### Task 8: Inventory doc

**Files:**
- Create: `docs/inventory/features.md` (FEAT-01..04 exactly as the Global Constraints state them, each with a "guarded by" line naming the tests from Tasks 3/6/7)
- Modify: `docs/inventory/README.md` (add the module → file row)
- Modify: `CLAUDE.md` — add a short "Feature Manager" bullet block to Feature Notes (registry location, CLI, demotion of digest.enabled, the migration marker)

- [ ] **Step 1:** write docs. **Step 2:** `go test ./internal/features ./internal/daemon ./cmd ./internal/config` all green. **Step 3: Commit** — `docs: feature-manager inventory contracts FEAT-01..04`

---

## Slice 3 — Desktop: manager list in Settings

### Task 9: `FeatureManagerService` (CLI-backed, testable)

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/FeatureManagerService.swift`
- Test: `WatchtowerDesktop/Tests/FeatureManagerServiceTests.swift`

**Interfaces (Produces):**

```swift
struct FeatureInfo: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let description: String
    let state: String        // enabled | disabled | core
    let core: Bool
    let parent: String
    let configKey: String
    let cost: String
    let feedsInto: [String]
    let subToggles: [FeatureSubToggle]
    enum CodingKeys: String, CodingKey {
        case id, title, description, state, core, parent
        case configKey = "config_key", cost
        case feedsInto = "feeds_into", subToggles = "sub_toggles"
    }
}

struct FeatureSubToggle: Codable, Equatable { let key, title, description: String; let enabled: Bool }

struct FeatureDependents: Codable, Equatable {
    let feature: String
    let dependents: [Dependent]
    struct Dependent: Codable, Equatable { let id, title: String }
}

/// Seam for tests — live impl shells the CLI (Constants.findCLIPath()).
protocol FeatureCLIRunning {
    func run(_ args: [String]) async throws -> Data
}

@MainActor @Observable
final class FeatureManagerService {
    var features: [FeatureInfo] = []
    var pending: [String: Bool] = [:]   // feature id → desired enabled
    var loadError: String?
    var isApplying = false
    var disabledFeatureIDs: Set<String> { /* current state ⊕ pending */ }
    func load() async                    // features list --json
    func dependents(of id: String) async -> [FeatureDependents.Dependent] // disable <id> --dry-run --json
    func setPending(_ id: String, enabled: Bool)
    func apply(restart: @MainActor () async -> Void) async // sequential enable/disable calls, then restart(), then load()
}
```

Live runner: `Process` with `Constants.findCLIPath()`, capture stdout, non-zero exit → throw with stderr text (copy the run shape from `JiraFeaturesSettingsView.swift`'s CLI calls — read that file first). `apply` keeps optimistic pending state and rolls back on a failed call (the Jira screen's rollback precedent); `--with-dependents` is passed when the caller marked the dependents-approved variant (an `applyWithDependents: Set<String>` piece of state set by the cascade dialog).

- [ ] **Step 1: Failing tests** — fake `FeatureCLIRunning` returning canned JSON; assert `load()` decodes, `setPending`+`apply` issues the right arg arrays in order (`["features","disable","ideas"]` etc.), rollback restores `pending` on a thrown call, `disabledFeatureIDs` reflects pending-over-current. Register the test class in the non-ML `Tests/` target next to `ConfigServiceTests` if possible (pure Foundation — no GRDB needed).
- [ ] **Step 2:** `cd WatchtowerDesktop && swift test --filter FeatureManagerServiceTests` → FAIL, then implement → PASS.
- [ ] **Step 3: Commit** — `feat(desktop): FeatureManagerService over the features CLI`

### Task 10: Manager UI in the Features tab + apply/restart

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Settings/FeaturesSettings.swift`
- Create: `WatchtowerDesktop/Sources/Views/Settings/FeatureManagerSection.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Settings/ConfigSaveBar.swift` (optional async `extraSave` hook)
- Modify: `WatchtowerDesktop/Sources/App/AppState.swift` (hold `let featureManager = FeatureManagerService()`; grep `AppState` init for where sibling services are created)

Behavior:
- `FeatureManagerSection(service:)` renders one `Section("Features")` at the TOP of the Features form: rows for top-level entries (Parent == ""), each with title, description (`.font(.caption)` secondary), cost badge (Text in a capsule; "core" badge instead of a toggle for core rows), `Toggle` bound to `service` pending state; children (stream-digests) indented under their parent row; `memory` row gets a `DisclosureGroup("Advanced")` listing sub-toggles (each writes through `config set` on apply — service `pendingSubToggles: [String: Bool]` applied via `["config","set",key,"true|false"]`).
- Toggling OFF a feature with `dependents(of:)` non-empty presents `.confirmationDialog` listing dependent titles with three buttons: "Disable only X", "Disable X and N dependents", "Cancel" (FEAT-04).
- `ConfigSaveBar` gains `var extraSave: (() async throws -> Void)? = nil`; `save()` becomes: `config.save()` then `await extraSave?()`. Only `FeaturesSettings` passes it: `{ await service.apply(restart: { await DaemonManager restart — use the same call the account view-models make; grep "DaemonManager" in Sources/ViewModels/*Accounts*.swift and call it identically }) }`. One Save = yaml tuning save + feature CLI applies + ONE daemon restart + reload.
- Tuning section gating: `digestSection` shown only when `service` says `slack-digests` effective-enabled; `briefingSection` ↔ `briefing`; `dayPlanSection` ↔ `day-plan`; `ideasSection` ↔ `ideas`. `NotificationSettings()` always.

- [ ] **Step 1:** implement (SwiftUI view layer; logic already tested in Task 9). Build: `cd WatchtowerDesktop && swift build` → success.
- [ ] **Step 2:** run the targeted suites: `swift test --filter FeatureManagerServiceTests` and `swift test --filter ConfigServiceTests` (round-trip pin must stay green untouched).
- [ ] **Step 3: Commit** — `feat(desktop): Feature Manager section in Settings with cascade dialog and one-restart apply`

---

## Slice 4 — Desktop: visibility (sidebar, navigation fallback, dashboard banner)

### Task 11: Feature→destination map + render-time sidebar filter

**Files:**
- Modify: `WatchtowerDesktop/Sources/App/SidebarDestination.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Sidebar/SidebarView.swift`
- Test: `WatchtowerDesktop/Tests/SidebarSectionTests.swift` (ADD tests only — the guard `testEveryDestinationIsPlacedExactlyOnce` is untouched)

**Interfaces (Produces):**

```swift
extension SidebarDestination {
    /// Feature ids that keep this tab visible; visible iff ANY is enabled.
    /// nil = always visible.
    var requiredFeatures: [String]? {
        switch self {
        case .catchUp: ["slack-digests"]
        case .digests: ["slack-digests", "stream-digests", "ideas"]
        case .ideas: ["ideas"]
        case .memory: ["memory"]
        case .briefings: ["briefing"]
        case .dayPlan: ["day-plan"]
        case .tracks: ["tracks"]
        case .people: ["people-cards"]
        default: nil
        }
    }

    func isVisible(disabledFeatures: Set<String>) -> Bool {
        guard let required = requiredFeatures else { return true }
        return required.contains { !disabledFeatures.contains($0) }
    }
}
```

`SidebarView`: filter at render — `rootItems`, each section's `partition(...)` results (both halves), `mainTrailingItems`, `toolItems` all get `.filter { $0.isVisible(disabledFeatures: appState.featureManager.disabledFeatureIDs) }` applied in `body`/`sectionView`, never mutating the declared arrays. `AppState` loads the service once at init (`Task { await featureManager.load() }` — follow the pattern of the other launch loads in `AppState.initialize()`).

- [ ] **Step 1: Failing tests** (pure, no UI):

```swift
func testDisabledFeatureHidesItsTabs()      // disabled ["ideas"] ⇒ .ideas not visible; .digests still visible
func testDigestsAnyOfRule()                 // disabled all three ⇒ .digests hidden; any one enabled ⇒ visible
func testCoreTabsAlwaysVisible()            // .inbox/.targets/.chat/.calendar visible under everything-disabled
func testRootItemTracksFilterable()         // disabled ["tracks"] ⇒ .tracks not visible
```

- [ ] **Step 2:** `swift test --filter SidebarSectionTests` → new red, guard green → implement → all green.
- [ ] **Step 3: Commit** — `feat(desktop): sidebar hides tabs of disabled features (render-time filter)`

### Task 12: Navigation fallback + Dashboard banner

**Files:**
- Modify: `WatchtowerDesktop/Sources/App/Navigation.swift` (or wherever the `selection` binding to `AppState.selectedDestination` lives — grep `selectedDestination` in Sources/App) — add `.onChange(of: appState.featureManager.disabledFeatureIDs)`: if `!selectedDestination.isVisible(disabledFeatures:)` → `selectedDestination = .inbox`. Same check once at appear (launch with a stale persisted selection).
- Modify: `WatchtowerDesktop/Sources/Views/Inbox/InboxFeedView.swift` — when `appState.featureManager.disabledFeatureIDs.contains("secretary-inbox")`, show a top banner (existing situations keep rendering below): icon + "The secretary is off — no new situations will appear." + a "Features Settings" link opening the Settings window (grep how other views open Settings — the Decisions empty state in `DecisionsListView.swift:100-111` is the copy precedent).
- Test: banner condition is a one-liner on state; cover the fallback rule as a pure function test if the navigation code allows extraction (`func fallbackDestination(current:disabled:) -> SidebarDestination?` in SidebarDestination.swift + 2 cases in SidebarSectionTests); UI wiring verified by build.

- [ ] **Step 1-2:** red (fallback function) → implement → `swift test --filter SidebarSectionTests` green; `swift build` success.
- [ ] **Step 3: Commit** — `feat(desktop): navigation fallback and dashboard banner for disabled secretary`

---

## Slice 5 — ML engines residency row

### Task 13: "Keep ML engines in memory" toggle

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/DictationCenter.swift` (~line 725-735, the `engineIdleTTL` scheduling site)
- Create: nothing new — the row lives in `FeatureManagerSection` (Task 10 file)
- Modify: `WatchtowerDesktop/Sources/Views/Settings/FeatureManagerSection.swift`
- Test: `WatchtowerDesktop/Tests/DictationSessionTests.swift` (ADD a test; note this file is being edited on another branch — keep the addition minimal and append-only to reduce merge conflict surface)

Behavior:
- New UserDefaults key, declared as `static let keepEnginesWarmKey = "ml.keepEnginesWarm"` on `DictationCenter`; **absent = ON** (the `preloadBeforeMeetings` precedent).
- `DictationCenter`: at the idle-unload scheduling site (where `let ttl = engineIdleTTL` is read, line ~730), when `UserDefaults.standard.object(forKey: Self.keepEnginesWarmKey) as? Bool == false`, drop the engine immediately instead of scheduling the TTL (defaults read fresh at that moment, injected `UserDefaults` if the class already takes one — check its init at :127).
- Manager row (Swift-local, appended after the Go-sourced rows, clearly not a Go feature): title "Keep ML engines in memory", description "Keeps the transcription engine warm between recordings and dictations, and preloads it before meetings. Turn off to free RAM — engines then load on demand and unload right after use." One toggle bound to BOTH `ml.keepEnginesWarm` AND `transcription.preloadBeforeMeetings` (`MeetingRecorderCenter.preloadBeforeMeetingsKey` — write the same value to both keys on change; read = `ml.keepEnginesWarm` absent-is-on). No daemon restart needed for this row (UserDefaults, applied live).
- Meetings/Dictation tabs and features stay untouched (owner decision 5).

- [ ] **Step 1: Failing test** — in DictationSessionTests' harness (isolated defaults): set `ml.keepEnginesWarm=false`, run a dictation to delivery, assert the engine is released immediately (the suite already has an engine-release assertion for `meetingCaptureWillStart` — mirror its shape).
- [ ] **Step 2:** `swift test --filter DictationSessionTests` red → implement → green. Also `swift test --filter MeetingRecorderWarmEngineTests` (must stay green — we didn't touch the policy, only the Settings write path).
- [ ] **Step 3: Commit** — `feat(desktop): ML engines residency toggle (prewarm + dictation sticky engine)`

---

## Slice 6 — Gate, review, PR, merge

### Task 14: Full gate

- [ ] `bash scripts/dev-health.sh` (known machine killers before the heavy Swift build).
- [ ] `go test ./...` → PASS (capture real exit code; no piping through tail).
- [ ] `cd WatchtowerDesktop && swift test` (full, one cold build in this worktree is expected) → note XCTest failures are ABOVE the swift-testing tail line.
- [ ] `make lint-all` (and `sentrux gate --save` only if the complexity gate flags the new files).
- [ ] Fix anything red; re-run the failed step until green.
- [ ] **Commit** any fixes — `test: green gate for feature manager`

### Task 15: Review + PR + merge

- [ ] Run the debate-review skill on the full branch diff vs origin/main; triage findings critically (accept/reject with reason), fix accepted ones, verify round.
- [ ] Push branch as the `vadimtrunov` gh account; open ONE PR to main titled "Feature Manager: per-feature toggles, registry, CLI, Settings UI" with a body summarizing the spec + slices; end body with the standard generated-with footer.
- [ ] Watch CI (`gh pr checks --watch`); "skipping" from the dedupe gate is NOT green — if the pull_request webhook is dead, use the workflow_dispatch escape hatch (see memory `project_ci_pipeline_gotchas`).
- [ ] On green: merge (owner pre-approved in this session: "делай зеленым и мержи"). Use a merge commit (repo convention).
- [ ] After merge: verify main CI green.

## Self-review notes (done at write time)

- Spec coverage: registry (T5), demotion+migration (T2/T3/T4), CLI+cascade (T7), fast-forward (T6), Settings UI+apply/restart (T9/T10), sidebar/fallback/banner (T11/T12), ML row (T13), contracts doc (T8), tests throughout. Non-goals honored (no telemetry, no hot-reload, integrations untouched).
- The spec's "verify and drop" cleanups (`analysis.legacy_mode`, `targets.resolver.*`) are deliberately OUT of this plan — separate tiny follow-up, they'd widen the diff for zero user value.
- Sub-toggle apply path (config set per key) matches the spec's write-path rule; `jira features` untouched.
