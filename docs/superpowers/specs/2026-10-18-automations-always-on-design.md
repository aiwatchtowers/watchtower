# Automations always on — design

Board #671 (under #405). Owner decisions: ask #366 note ("automations are not a feature to switch off: a recipe-less install spends no tokens") and ask #372 (remove the switch completely; pause such recipes once on upgrade; amend FEAT-03 and AUTO-10).

## Intent

Automations cost nothing until the owner confirms a recipe, so the feature switch only hides a tab and adds dead ends (a hidden Reactions dictionary, "Turn On Automations" buttons, refusals in the CLI and the editor chat). Remove it.

## Goals

- No `automations` feature: gone from `internal/features` (Settings → Features, `features list/enable/disable`), from onboarding's unmanaged set, and from `config` (`AutomationsConfig`, `automations.enabled`, `DefaultAutomationsEnabled`). A leftover `automations.enabled` key in `config.yaml` is ignored after the upgrade step below.
- Every gate on it goes: the daemon always wires the scheduler, executor and event bus; `automations run/cancel/wake` never refuse for the feature; `draft_automation`/`save_automation` never refuse for it (`authoring.Deps.Enabled` removed); the Desktop tab, ⌃⌘R, the tray submenu, the workbench header buttons and the session center are always available (the `featureVisibility.isLoaded` gate for the session center and rescans, R-P5-8, stays).
- Settings → Slack's reaction dictionary pointer is just **Open** (no Turn On Automations).
- The FEAT-03 `automations` fast-forward hook and `db.FastForwardAutomations` go (its job moves to the upgrade step).

## The one-time upgrade step (ask #372)

An install whose automations were off must not start spending tokens on the update. On daemon start, before automations are wired:

- **Legacy off** = `config.yaml` has `automations.enabled: false`, or this start's `MigrateFeatureGates` reported a legacy `digest.enabled=false` install (the "all AI off" mapping used to switch automations off too).
- If legacy off: in **every** workspace database (`config.WorkspaceDirsWithDatabase`), in one transaction each: set every `enabled` automation to disabled with `disabled_reason` = `Paused by the update: Automations was turned off. Turn it on to run it again.` and `disabled_at` = now (the existing `AutomationFailureWatch` notice tells the owner), and cancel queued non-dry-run runs (what the FEAT-03 hook did on enable). Then remove the `automations.enabled` key from `config.yaml` (YAML node edit like `patchConfigYAML`, comments kept). Done once: with the key gone the step is a no-op.
- If any database or the config write fails: log it, do not remove the key (the next start retries), and **fail closed** for this process — do not wire automations this run.
- The owner re-enables a recipe as today (`SetAutomationEnabled` clears the reason and restarts the schedule from now: no catch-up).

## Inventory amendments (approved, ask #372)

- FEAT-03 (`docs/inventory/features.md`): the `automations` hook and its guards (`TestFastForward_Automations`, `TestFastForwardAutomations_PrimesSchedulesAndCancelsQueued`) are removed; dated changelog line.
- AUTO-10 (`docs/inventory/automations.md`): drop "and enabling the `automations` feature"; drop the guard `TestFastForward_Automations`; changelog line. No guard is weakened otherwise; the upgrade step gets its own tests.

## Non-goals

- `reaction-commands` stays a feature with its own switch (reaction events still need it).
- No new card UI for `disabled_reason` (the notification is the surface).
- Historical specs and plans are not edited.

## Docs

`docs/features/automations.md`, `feature-manager.md`, `onboarding-v2.md`, `tray-daemon-lifecycle.md`, the guide pages that mention turning Automations on/off (`features/automations.md`, `start/first-week.md`, `features/workbench/README.md`, `reference/settings.md`, `concepts/features-on-and-off.md`, `features/menu-bar-and-updates.md`), CLAUDE.md's Automations line ("feature on" in the no-catch-up list). Fix the stale "there is no `disabled_reason` column" line in `docs/features/automations.md` while there.
