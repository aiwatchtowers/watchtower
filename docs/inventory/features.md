# Behavior Inventory — Feature Manager

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `internal/features/` (registry + fast-forward hooks),
> `cmd/features.go` (CLI), `internal/config/feature_migrate.go` (legacy migration),
> `internal/daemon/daemon.go` (phase gates), or Desktop feature settings, read this
> file first. Any proposed change that would break a guard test or remove
> a contract must be raised as a question before touching code.

**Module:** `internal/features/` + `internal/daemon/daemon.go` phase gates + `cmd/features.go` CLI + `internal/config/feature_migrate.go` + Desktop feature settings
**Last full audit:** 2026-08-16

## FEAT-01 — Off = zero new AI calls, no locks or pipeline_runs rows

**Status:** Enforced

**Observable:** When a **daemon** phase is gated by a disabled feature flag, the phase's early return (checked BEFORE any nil-check on the pipeline, before acquiring any lock, before calling `trackedPipelineRun`) leaves the database untouched: no new `pipeline_runs` rows are written, no `.lock` files are created for background orchestrators (e.g., the `ideas_backfill.lock` for the ideas consolidator). The phase is simply skipped, and its pipeline — if constructed at daemon start — is never invoked.

This applies to all gated phases: `phaseFastInbox`, `phaseChannelDigests`, `phaseCustomTrackScan`, `phaseTracksAndRollups` (tracks arm), `phasePeopleCards`, `phaseInbox`, `phaseStreamDigests`, `phaseIdeas`, `phaseMemory`, `phaseNextStep`, `phaseBriefing`, `runDayPlanPhase`, `runDayPlanConflictPhase`, `phaseFeed`. The gate check must come first, before any pipeline-related logic.

**Scope — the daemon only.** The one-shot `watchtower sync` path (`cmd/sync.go`'s `runPostSyncPipelines`) still rides `digest.enabled` alone as its single pre-feature-manager master switch: it runs digests *and* people cards behind that one check, consulting neither `people.enabled` nor `tracks.enabled`. So a manual `watchtower sync` can still generate people cards for an owner who disabled People Cards, and stops generating them for one who disabled only Slack Digests. This is a **known deferral**, not part of the contract — lifting it is tracked as a follow-up; until then, the contract above is about the daemon, which is how the feature is actually operated.

**One write from a read command.** `watchtower features list` (and every other `features` subcommand) may write exactly one thing to the config file: the one-time `features.migrated` marker, stamped on first contact by `config.MigrateFeatureGates` via `featuresCmd`'s `PersistentPreRunE`. It is idempotent and never touches a feature key on a non-legacy install — see the FEAT-01 note in the changelog below.

**Why locked:** Disabling a feature must stop all its data generation in progress; if a gated phase could still write lock files or pipeline run records, the owner couldn't trust that the feature is truly off. The earliest gate position is necessary to prevent leaks from slow initialization paths.

**Test guards:**
- `internal/daemon/daemon_gates_test.go::TestFeatureGates_DisabledPhaseWritesNoPipelineRun` (table-driven over digests, inbox, tracks, people, ideas, next_step, briefing, day_plan, feed; asserts no `pipeline_runs` rows and no `ideas_backfill.lock` for ideas; each phase gate tested with its feature flag disabled)

**Locked since:** 2026-08-16

## FEAT-02 — Off is non-destructive

**Status:** Enforced

**Observable:** Disabling a feature flag stops all new data generation for that feature (FEAT-01) and removes all of its UI from the Desktop app, but never deletes any existing data. Historical rows, digests, ideas, situations, memories, targets, tracks, and all user-created content remain queryable and unmodified. Re-enabling the feature re-enables its UI and daemon phases; it does not re-generate any of the historical data that may have accumulated while it was off.

There is no cascading deletion logic triggered by a feature disable. The only deletions in the codebase related to features are user-initiated (e.g., an owner manually deletes a target or idea).

**Why locked:** A feature flag is a control lever for the owner's experiment or cost management, not a data-loss mechanism. If disabling it destroyed months of accumulated work, the owner would have to weigh the cost of keeping unwanted data against the risk of losing it — a false dilemma that defeats the point of a toggle.

**How it is enforced:** structurally, not by a deletion-detecting test. A feature gate is an early `return` at the top of a daemon phase; there is no delete/truncate code path anywhere behind a feature flag for such a test to catch. `TestFeatureGates_DisabledPhaseWritesNoPipelineRun` observes that a gated phase writes nothing (zero `pipeline_runs` rows, no backfill lock) — it does **not** diff whole-database state, and must not be cited as if it did.

**Test guards:**
- `internal/daemon/daemon_gates_test.go::TestFeatureGates_DisabledPhaseWritesNoPipelineRun` (a disabled phase produces no new rows/locks — the "stops generating" half; see the note above for what it does not assert)
- `cmd/features_test.go::TestFeaturesDisable_WritesOnlyNamedKey` (disable writes only that feature's flag to false; an unrelated feature's key stays untouched)

**Locked since:** 2026-08-16

## FEAT-03 — Enable resumes from now

**Status:** Enforced

**Observable:** When a feature is re-enabled via `watchtower features enable <id>`, the CLI runs the feature's fast-forward hook (if it has one) first, writing watermarks and other state to the database. Only if the hook succeeds does the CLI write the feature's config key true to the yaml file; if the hook fails, no config change is written and the feature remains off.

Fast-forward hooks reset the feature's processing watermarks — digests to the current top of the digest table, ideas to the top of its source tables, memory to now, etc. — so the feature resumes processing from the present moment forward, never auto-backfilling historical material. The consequence is that material accumulated while the feature was off is not automatically re-processed. If the owner wants to backfill historical windows for ideas, they must explicitly run `watchtower ideas mine --from <date>` afterwards.

The enable flow is sequential (fast-forward DB writes first, config key write second), not transactional — it involves two independent stores (database and yaml file) with different consistency semantics.

**Why locked:** An unexpected backfill of months of data when flipping a feature back on would violate the owner's expectations and could incur unbounded AI costs. The explicit backfill command makes the owner's intent clear.

**Test guards:**
- `internal/features/fastforward_test.go::TestFastForward_Inbox` (watermark + compose ts == now.Unix() after enable)
- `internal/features/fastforward_test.go::TestFastForward_Ideas` (floors == MAX(id) of each source table)
- `internal/features/fastforward_test.go::TestFastForward_Memory` (watermark == now.Unix())
- `internal/features/fastforward_test.go::TestFastForward_NoHookIsNil` (briefing, day_plan, people have no hook)
- `cmd/features_test.go::TestFeaturesEnable_RunsFastForward` (enable writes config and runs fast-forward; watermark advances)
- `cmd/features_test.go::TestFeaturesEnable_FailedFastForwardLeavesKeyUnwritten` (fast-forward error ⇒ config key not written)

**Locked since:** 2026-08-16

## FEAT-04 — No silent cascade

**Status:** Enforced

**Observable:** Disabling a feature never turns off another feature the owner did not name. `watchtower features disable <id>` succeeds writing **only that feature's own config key**; its transitive dependents (computed by `features.Dependents()`) stay enabled, running degraded on whatever upstream data they still have. Turning them off too requires the explicit `--with-dependents` flag, which disables each currently-enabled dependent alongside the named feature.

The dependent list is surfaced, not enforced. `--dry-run` prints the transitive set (and, with `--json`, feeds it to the Desktop) without writing anything; the Desktop Feature Manager renders that list in a cascade-confirmation dialog and passes `--with-dependents` only for the ids the owner confirmed. So the owner is always shown the consequences and always decides — but a plain CLI disable is not an error.

**Why locked:** A dependent feature left enabled but starved of upstream data (e.g., Briefing enabled but Inbox disabled) enters a degraded state. A silent cascade would hide that state change from the owner; forcing an error on every plain disable would instead make the CLI unusable for the common single-feature case. Showing the list and requiring an explicit flag to act on it keeps the decision with the owner either way.

**Test guards:**
- `cmd/features_test.go::TestFeaturesDisable_WritesOnlyNamedKey` (a plain disable succeeds and writes only the named feature's key)
- `cmd/features_test.go::TestFeaturesDisable_WithDependents` (`--with-dependents` disables the target plus every enabled transitive dependent)
- `cmd/features_test.go::TestFeaturesDisable_DryRunWritesNothing` (`--dry-run` prints the cascade but writes nothing)
- `cmd/features_test.go::TestFeaturesDisable_DryRunJSONWireShape` (the dry-run JSON keys the Desktop cascade dialog decodes)
- `cmd/features_test.go::TestFeatures_CoreRejected` (enable/disable on a core feature returns an error and writes nothing)

**Locked since:** 2026-08-16

## Documented limitations (v1)

Deliberate, owner-approved gaps — not contract violations, and not oversights:

- **Integrations are outside the registry.** The manager toggles *features* (what Watchtower does with data), never *integrations* (where data comes from): `slack`/`jira`/`calendar`/`gmail` keep their own connection settings. The one AI call this leaves outside the manager is the Jira `BoardAnalyzer` inside `phaseJiraSync`, which rides `jira.enabled` alone because it serves the Boards screens rather than digests. Consequence, per the spec's Behavior note: an owner who used to silence it with `digest.enabled=false`, and whose install is then migrated to all-features-off, gets that one call back if they have Jira connected and enabled.
- **The one-shot `watchtower sync` path is not feature-gated** — see FEAT-01's Scope note.
- **`features.migrated` is stamped by read commands** — see FEAT-01's one-write note. The stamp is what makes the legacy detection unambiguous; without it an ordinary `features disable slack-digests` is byte-identical to a pre-feature-manager install.

## Changelog

- 2026-08-16: file created with 4 contracts (FEAT-01..04), all Enforced. Introduced by the Feature Manager feature (spec `docs/superpowers/specs/2026-08-16-feature-manager-design.md`), a Settings screen listing every feature with an on/off switch and a registry-based CLI for enable/disable with fast-forward hooks and cascade safety.
- 2026-08-16 (same branch, post-review): contract text corrected against the shipped behavior — FEAT-04 described an error-on-enabled-dependents CLI that was never built (a plain `disable` succeeds and writes one key; the dependent list is *surfaced* by `--dry-run` and the Desktop dialog), FEAT-02 credited the gate test with a whole-database-state assertion it does not make, and FEAT-01 was silently daemon-only. Added the Documented limitations section. No behavior changed with these edits; the migration marker's first-contact stamp (same branch) is behavioral and is described in FEAT-01.
