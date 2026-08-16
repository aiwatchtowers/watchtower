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

**Observable:** When a daemon phase is gated by a disabled feature flag, the phase's early return (checked BEFORE any nil-check on the pipeline, before acquiring any lock, before calling `trackedPipelineRun`) leaves the database untouched: no new `pipeline_runs` rows are written, no `.lock` files are created for background orchestrators (e.g., the `ideas_backfill.lock` for the ideas consolidator). The phase is simply skipped, and its pipeline — if constructed at daemon start — is never invoked.

This applies to all gated phases: `phaseFastInbox`, `phaseChannelDigests`, `phaseCustomTrackScan`, `phaseTracksAndRollups` (tracks arm), `phasePeopleCards`, `phaseInbox`, `phaseIdeas`, `phaseNextStep`, `phaseBriefing`, `runDayPlanPhase`, `runDayPlanConflictPhase`, `phaseFeed`. The gate check must come first, before any pipeline-related logic.

**Why locked:** Disabling a feature must stop all its data generation in progress; if a gated phase could still write lock files or pipeline run records, the owner couldn't trust that the feature is truly off. The earliest gate position is necessary to prevent leaks from slow initialization paths.

**Test guards:**
- `internal/daemon/daemon_gates_test.go::TestFeatureGates_DisabledPhaseWritesNoPipelineRun` (table-driven over digests, inbox, tracks, people, ideas, next_step, briefing, day_plan, feed; asserts no `pipeline_runs` rows and no `ideas_backfill.lock` for ideas)
- `internal/daemon/daemon_gates_test.go::TestFeatureGates_DisabledInboxHasNoTriage` (inbox.enabled=false ⇒ no triage pipeline run)
- `internal/daemon/daemon_gates_test.go::TestFeatureGates_DisabledTracksWritesNoCustomTrackScan` (tracks.enabled=false ⇒ no custom track scan pipeline run)
- `internal/daemon/daemon_gates_test.go::TestFeatureGates_DisabledPeopleWritesNoPeopleCardPass` (people.enabled=false ⇒ no people card pass)
- `internal/daemon/daemon_gates_test.go::TestFeatureGates_DisabledIdeasWritesNoLockFile` (ideas.enabled=false ⇒ no ideas_backfill.lock created)

**Locked since:** 2026-08-16

## FEAT-02 — Off is non-destructive

**Status:** Enforced

**Observable:** Disabling a feature flag stops all new data generation for that feature (FEAT-01) and removes all of its UI from the Desktop app, but never deletes any existing data. Historical rows, digests, ideas, situations, memories, targets, tracks, and all user-created content remain queryable and unmodified. Re-enabling the feature re-enables its UI and daemon phases; it does not re-generate any of the historical data that may have accumulated while it was off.

There is no cascading deletion logic triggered by a feature disable. The only deletions in the codebase related to features are user-initiated (e.g., an owner manually deletes a target or idea).

**Why locked:** A feature flag is a control lever for the owner's experiment or cost management, not a data-loss mechanism. If disabling it destroyed months of accumulated work, the owner would have to weigh the cost of keeping unwanted data against the risk of losing it — a false dilemma that defeats the point of a toggle.

**Test guards:**
- `internal/daemon/daemon_gates_test.go::TestFeatureGates_DisabledPhaseWritesNoPipelineRun` (verifies no deletes, by asserting database state is unchanged in all disabled phases)
- `cmd/features_test.go::TestFeaturesDisable_WritesOnlyNamedKey` (disable writes only that feature's flag to false; other data untouched)

**Locked since:** 2026-08-16

## FEAT-03 — Enable resumes from now

**Status:** Enforced

**Observable:** When a feature is re-enabled via `watchtower features enable <id>`, the CLI immediately runs the feature's fast-forward hook (if it has one) before returning. Fast-forward hooks reset the feature's processing watermarks — digests to the current top of the digest table, ideas to the top of its source tables, memory to now, etc. — so the feature resumes processing from the present moment forward, never auto-backfilling historical material.

The consequence is that material accumulated while the feature was off is not automatically re-processed. If the owner wants to backfill historical windows for ideas, they must explicitly run `watchtower ideas mine --from <date>` afterwards.

Fast-forward hooks are run exactly once per enable, inside the same transaction that writes the feature key true to the config file. If the hook fails, no config change is written (rollback).

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

**Observable:** When disabling a feature that others depend on, the disable operation does not silently cascade to its dependents. Instead, `watchtower features disable <id>` computes the transitive set of dependents via `features.Dependents()` and requires an explicit `--with-dependents` flag to disable them together.

Without the flag, disabling a feature that has enabled dependents is an error with a message naming each dependent. This forces the owner to make a conscious decision about cascading consequences.

The `--dry-run` flag prints the would-be cascade without writing anything, allowing the owner to preview the consequences.

**Why locked:** A dependent feature left enabled but starved of upstream data (e.g., Briefing enabled but Inbox disabled) could enter a degraded state or produce confusing empty outputs. A silent cascade would hide this state change from the owner and could lead to confusion about what is actually running.

**Test guards:**
- `cmd/features_test.go::TestFeaturesDisable_WithDependents` (without flag, returns error naming dependents)
- `cmd/features_test.go::TestFeaturesDisable_WithDependentsFlag` (with flag, disables target + all enabled transitive dependents)
- `cmd/features_test.go::TestFeaturesDisable_DryRunWritesNothing` (--dry-run prints but doesn't write)
- `cmd/features_test.go::TestFeaturesDisable_CoreCannotBeDisabled` (disable on core feature returns error)

**Locked since:** 2026-08-16

## Changelog

- 2026-08-16: file created with 4 contracts (FEAT-01..04), all Enforced. Introduced by the Feature Manager feature (spec `docs/superpowers/specs/2026-08-16-feature-manager-design.md`), a Settings screen listing every feature with an on/off switch and a registry-based CLI for enable/disable with fast-forward hooks and cascade safety.
