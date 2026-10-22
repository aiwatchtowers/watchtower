# Built-in automations — the engine and the Morning brief (C2, 2026-10-22)

Watchtower ships some of its own daemon work as automations: a recipe embedded in the binary, run by the automations executor at a fixed place ("slot") in the daemon's sync cycle, shown in Automations → **Built in**, editable through the panel and resettable to the shipped text. C2 ships the engine and its first built-in, **Morning brief** (`morning-brief`), which makes the daily briefing and then the day plan in one run. C3 moves tracks, ideas, reactions and custom tracks onto the same engine.

Spec `docs/superpowers/specs/2026-10-22-inbox-built-in-automations-design.md` §4, §5.1–§5.4, §8, §9 (owner approved, ask #500; AUTO-06 and FEAT-01..03 amendments). Plan `docs/superpowers/plans/2026-10-22-c2-built-in-engine-and-morning-brief.md` (ask #502). Board #801 (under Automations #405), C2 group #875. The owner-recipe side of automations is `docs/features/automations.md`; contracts AUTO-01..13 are in `docs/inventory/automations.md`.

## Registry and slots

- `internal/automations/builtin/registry.go`: one `Entry` per built-in, in card order (`All()`, `Lookup(id)`, `AtSlot(slot)`; each returns clones). An `Entry` holds `ID` (the `builtin_id` and the recipe's slug), `Name`, `Slot`, `Recipe` (the embedded bytes, `//go:embed recipes/*.md`), `FeatureIDs` (features-registry ids whose config keys are the on/off truth), `Primitives`, `Prompts` (`PromptRef{Name, PromptID}`), `Parameters` (`Parameter{Key, Kind, Label}`, `ParamKind` = `hour` | `clock` | `count`), `Pipelines` (`pipeline_runs` names counted in Costs), `Reads`/`Sends` (card copy), `When(cfg)` (the card's When sentence), `RunNow` and `NoRunNowNote`.
- `Entry.Enabled(cfg)` is true when any of its features is on (`features.ByID(id).Enabled(cfg)`); a nil cfg or an unknown id counts as off. There is no `enabled` of its own: the config keys stay the truth (spec §5.4).
- `Entry.DefaultPrompt(name, role)` is the shipped prompt for the owner's role (`prompts.DefaultForRole`); `DefaultPromptFunc(builtinID, name, role)` is the same over the registry and is what `Backends.DefaultPrompt` holds.
- Slots: `automations.SyncSlots = morning_brief, custom_tracks, tracks, reactions, ideas` (all five reserved in C2); `builtin.Slot` constants exist for the ones a built-in uses (`SlotMorningBrief` in C2).

## The row model

- One `automations` row per built-in (migration 00150): `origin = 'builtin'`, `builtin_id = <id>`, `path = 'builtin:<id>'` (synthetic; no file is written until the owner edits), scope Personal. `overridden = 1` while the row is indexed from the owner's copy; `builtin_base_hash` is the shipped content hash the copy was made from (set on the 0 → 1 transition, kept while overridden). Owner rows are `origin = 'owner'`; `idx_automations_scope_slug` is unique only over owner rows, so a Personal recipe with a built-in's slug is a separate row. `builtin_migrations` records the one-time upgrade step (below).
- The owner's copy is `<workspace>/automations/.builtin/<id>.md` (`builtin.OwnerCopyPath`). The Personal scanner skips the directory and never treats a built-in row as one of its files.
- `builtin.Sync` / `SyncOne` (`sync.go`) bring each row in line with its source: the copy when it is a regular file (lstat first, read through `automations.ReadRecipeFile`, links never followed), else the shipped bytes. A copy that is a symlink, directory or special file is never read (the shipped text runs, `OwnerCopyNote` says why); a copy that exists but cannot be read is an error and the row keeps what it holds. An unchanged built-in writes nothing (`sameRow`), so the Personal scope's generation stays put. `SetBuiltinEnabled` mirrors `Entry.Enabled(cfg)` into the row last.
- `db.Automation` gains `Origin`, `BuiltinID`, `Overridden`, `BuiltinBaseHash` and `Confirmed()`, `IsBuiltin()`, `RunsAtSlot()` (= `IsBuiltin()` in C2); `Runnable()` is `Confirmed() && Enabled`. `automations.ScopeOf(row)` rebuilds the built-in scope (`Scope{Personal, BuiltinID}`, `String()` = `builtin:<id>`); a DB lookup by scope uses the folder scope.
- The card's data is `builtin.Card` (`card.go`): `show --json`'s `builtin` block — `id`, `slot`, `overridden`, `shipped_hash`, `base_hash`, `update_available` (overridden and base ≠ shipped), `shipped_text`, `default_prompts`, `when`, `reads`, `sends`, `parameters[{key,kind,label,value}]`, `feature_ids`, `enabled`, `run_now`, `copy_error` (the row's parse error, or an lstat error other than not-exist), `costs{usd,days:7,reported}` (`db.BuiltinCost`: reported run costs, plus the entry's `pipeline_runs` rows before its first run). Pinned by `internal/automations/builtin/testdata/show_morning_brief.json` (regenerate with `go test ./internal/automations/builtin -run Golden -update`; it embeds the default prompts, so a prompt change regenerates it).

## AUTO-06 as amended (ask #500)

- Shipped bytes run without the owner's confirmation: `Sync` calls `db.ConfirmShippedBuiltin(id, shippedHash, approvalHash, now)` only when the row is unconfirmed, has no parse error and its content hash equals the shipped hash. `ConfirmShippedBuiltin` refuses an owner row (`ErrNotBuiltin`), other bytes and a stale approval hash (`ErrHashMismatch`).
- Everything else holds: the owner's copy is indexed unconfirmed and runs only after the owner confirms it in the panel; a hand edit makes it unconfirmed again (the built-in then stops — it does not fall back to the shipped text); a copy byte-equal to the shipped text is confirmed like the shipped text.
- Only a built-in scope may declare `trigger: {sync: <slot>}` (`syncTriggerAllowed`) or a `builtin:` capability (`capabilitySpec.builtinOnly`); a Personal or workbench recipe doing either is a parse error. The approval hash covers the built-in scope and the slot.
- A dry run of a built-in calls no primitive (AUTO-12): `brief.compose`/`plan.compose` close their steps `dry_run`.
- Guards: AUTO-06 "C2 built-ins" in `docs/inventory/automations.md`, plus the upgrade step's `TestAuto06_UpgradeConfirmsOnlyCarriedPrompt` (Task 8) — the fourth `ConfirmAutomation` caller, confirming only the copy it rendered from a customised prompt-store row that was already running.

## The `sync` trigger and in-cycle runs

- `trigger_kind = 'sync'` and run trigger `'sync'` (`db.TriggerSync`). A built-in's runs execute **inline, at its slot, in the daemon's sync goroutine** on a dedicated slot executor (`automations.NewExecutor` over `slotBackends`, never `Run`): `automationBackends` (so a copy has the read tools) + `Primitives = d.BuiltinPrimitives()` + `DefaultPrompt = builtin.DefaultPromptFunc`. `wireBuiltins` (`cmd/builtins.go`) builds it in `runSyncDaemon` before, and outside, `if automationsOK`, syncs each built-in with `SyncOne`, runs the upgrade step, and hands `d.SetBuiltins(runner, active)`. The daemon never reloads config in process; runner and daemon share one `cfg`.
- The main executor's poll never claims, cancels or resumes a `RunsAtSlot()` run (`poll.consider`/`poll.resume` skip them). `Executor.ExecuteBuiltinInline(ctx, runID)` requires `RunsAtSlot() && Confirmed()` (else it cancels the run `not_runnable`, `ErrNotRunnable`) and claims with the per-automation concurrency (`ErrRunNotClaimed`, run stays queued); `enabled` is not checked there (the runner checks on/off). Slot runs do not count against `MaxConcurrent`.
- `builtin.Runner.RunSlot(ctx, slot)` (`runner.go`), per built-in at the slot, in card order: off → `Skipped = off`, nothing read or written (FEAT-01); the stale-run guard (`db.MarkStaleBuiltinRuns`); unconfirmed → its queued manual runs cancelled `not_runnable`, `Skipped = not_confirmed`; a queued manual run → executed without asking the gate; else the entry's `Gate.Due(ctx, e, now)` decides and only a due built-in gets one `sync` row, executed inline. A sync run that loses its claim is cancelled (the next cycle asks again); a manual one stays queued. A DB failure is `Status = error`, logged.
- **Run Now at the next sync.** `automations run <id>` on a built-in (and the card's **Run Now**) only queues a `manual` row and sends `signalSyncNow`; the slot runs it (`"at_next_sync": true` in `--json`). Refused when `RunNow` is false (`NoRunNowNote`), when the built-in is off, when unconfirmed, and with `--rerun-of`.
- **Run Now inline (CLI generate).** `Runner.RunNow(ctx, id, in)` queues a `manual` run with `event_json = {"builtin": in}` and executes it inline whether or not the built-in is on. A coalesced queued run with other input is refused (`ErrRunNowQueued`, wraps `ErrRunNotClaimed`); a run this call queued that cannot be claimed is cancelled so it never runs later with that input.
- Run ends: `MarkInterruptedAutomationRuns` (the main executor's start sweep) skips built-in runs; `db.MarkInterruptedBuiltinRuns` is the daemon's own sweep (`sweepBuiltinRuns`, at start before `startAutomations`, retried before each slot until it succeeds). `db.MarkStaleBuiltinRuns(now)` (before each slot entry and `RunNow`) ends a `running` built-in run past `started_at` + budget minutes + 1 min that never waited (no `resume_pending`, no pending replay, no ask/session/waiting step, no `{wait}` write) — a SIGKILLed CLI's run. A CLI run killed after a wait is not ended by it and holds the built-in until the daemon's start sweep.

## The primitive contract

- `sdk_builtin.go`: `BuiltinInput{Only, Date, Feedback, Force}` (C3 adds `Since`), `PrimitiveCall{Name, BuiltinID, Prompt, Args, Trigger, Input, Role}`, `PrimitiveUsage{InputTokens, OutputTokens, CostUSD, Reported}`, `PrimitiveResult{Status "done"|"skipped", Fields, Note, Usage}`, `PrimitiveFunc`. `Backends.Primitives` maps primitive names to funcs.
- `BuiltinModule` defines a primitive path (`brief.compose`, `plan.compose`) only when the manifest holds `CapabilityForPrimitive(name)` (default `builtin:<name>`, overridden by `PrimitiveCapability`), and `builtin.defaultPrompt(name)` / `builtin.input` when any `builtin:` entry is present. Outside a built-in scope nothing is defined.
- Each call `x.compose({prompt})` is one `llm` step named after the primitive (step permission `builtin:<name>`): `AllowPrimitive`, argument checks (`ValidationError`), dry run → `dry_run`, else the func under `MeteredModelCall`. The reported usage is debited from the run's meter and recorded on the step and the run (a primitive must report real usage; the pipelines reset theirs at the start of each run). An error → `SDKError{PrimitiveFailed}`; uncaught it ends the run `failed`/`backend`. A status other than done/skipped is `PrimitiveFailed`. `Note` (e.g. the placeholder fallback) is journalled on the step, not shown to the script.
- The owner's role is read once per run (`OwnerRole`). `builtin.defaultPrompt` is a pure read, not journalled. A malformed `{"builtin": …}` input (bad JSON, date not `YYYY-MM-DD`, unknown `only` name) fails the run `backend` before any script code.

## Morning brief

- Recipe `internal/automations/builtin/recipes/morning-brief.md`: `trigger: {sync: morning_brief}`, permissions `builtin:brief.compose`, `builtin:plan.compose`, budget 400 000 tokens / 15 minutes. The script calls `brief.compose` then `plan.compose`, each with `builtin.defaultPrompt(name)`; a failed brief does not stop the plan; the first failure fails the run.
- Entry: features `briefing`, `day-plan` (on while either is on); prompts `brief` → `briefing.daily`, `plan` → `day_plan.generate`; parameters `briefing.hour` (Time), `day_plan.working_hours_start`/`_end`, `day_plan.max_timeblocks`, `day_plan.min_backlog`, `day_plan.max_backlog` (the three counts are card fields; the plan pipeline still does not read them); pipelines `briefing`, `day_plan`; `RunNow: true`.
- `phaseMorningBrief(ctx, now)` (`internal/daemon/morning_brief.go`) replaces `phaseBriefing` + `runDayPlanPhases` in `runSync`. With no runner or the built-in not `active`, it runs those legacy phases unchanged. Otherwise it resolves the cycle owner once (`dayPlanOwner`), runs `RunSlot(SlotMorningBrief)`, then `runDayPlanConflictPhase` — the conflict phase stays Go and runs every cycle.
- Gate `MorningBriefGate`: due when `briefDue(now) || planDue(now)`. `briefDue` = `briefing.enabled` + pipeline + `shouldRunBriefingAt` (one per calendar day after `briefing.hour`, fresh-install bypass `briefingFresh`, 3 attempts a day) + `briefingHasOwner`, and false for an hour after a sync brief that found no data (`briefingNoDataBackoff`). `planDue` = `day_plan.enabled` + `shouldRunDayPlan(now, owner)`, which now uses **`briefing.hour`** (fresh-install bypass `dayPlanFresh`). `day_plan.hour`, `DayPlanConfig.Hour` and `DefaultDayPlanHour` are retired; a leftover key in `config.yaml` is ignored.
- Primitives `builtin.MorningBriefPrimitives(brief, plan, hooks)` (`morningbrief.go`): a call returns `skipped` when `Input.Only` leaves it out or, in a sync run, when its gate says not now. `brief.compose` → `briefing.RunForDateWith(date, {Prompt})` → `briefing_id`; `plan.compose` → `dayplan.Run` with the owner, `Feedback`, `Force` (feedback implies force) → `plan_id`, `items`. Both report usage and `LastPromptNote` (a prompt with the wrong `%s` count falls back to the default, and the note says so).
- Tracking (daemon hooks `trackBrief`/`trackPlan`): the legacy closures — `pipeline_runs` rows named `briefing` and `day_plan`, `last_briefing.txt` (today only), `lastDayPlanDate`, attempt files `briefing_attempts.txt` / `day_plan_attempts.txt`. Only a `sync` run charges an attempt; a sync no-owner brief is the benign once-a-day skip; a manual run surfaces `db.ErrNoOwner` (OWNER-02).
- Prompts: an active built-in uses the recipe's prompt, never the prompt store. `prompts.MovedToBuiltin` lists `briefing.daily` and `day_plan.generate`: `prompts show` prints "Used by the Morning brief built-in — change it in Automations → Built in.", and the tuner skips them.

## CLI paths

- `briefing generate` / `day-plan generate [--date --force --feedback]`: `RequireOwner`, then `runMorningBriefNow` — `SyncOne` with the loaded cfg, both features forced on in a copy of cfg for the pipelines (so the commands work with the features off), `newCLIBuiltinRunner` (own executor over `automationBackends`, no gates, no attempt budget, no `pipeline_runs`), `RunNow` with `Only:[brief.compose]` or `Only:[plan.compose]`. SIGINT/SIGTERM end the run. Pinned refusals: "Morning brief: your edited copy is not confirmed yet — confirm it in Automations → Built in", "Morning brief: your edited copy has an error — fix it in Automations → Built in", "Morning brief is running now — try again in a minute", "Morning brief is already queued for the next sync".
- `automations reset <id> [--json]` (owner only): removes the copy if it is a regular file, `SyncOne`; JSON `{"automation_id","overridden","approval_hash"}`. Refused for an owner automation and when `.builtin` is not a real folder.
- `automations save --path builtin:<id>`: writes the copy atomically (0600, `.builtin/` 0700), `SyncOne`, then `--confirm-hash`; `--expect-content-hash` compares against the copy, else the shipped hash; refused under agent markers before anything is read.
- Refusals with pointers: `enable`/`disable` ("A built-in turns on and off with its features: watchtower features enable|disable briefing day-plan"), `delete` ("built-ins cannot be deleted; turn it off instead"), `auto` ("built-ins get no auto grants (AUTO-03)").
- `show <id|morning-brief> --json` adds `builtin` (`null` for owner rows); `list --json` rows add `origin`, `builtin_id`, `overridden`. `validate --against <builtin id>` parses in the built-in scope.
- Authoring: `draft_automation` takes `builtin_id` (the draft parses in that scope, slug forced, widening against the confirmed text); `save_automation` refuses any `builtin_id` ("a built-in is saved from its panel").
- `automations upgrade-builtins [--json]` re-runs the upgrade step for `failed` entries; JSON `{"results":[{"builtin_id","status","error"}]}`.

## The one-time upgrade step (Task 8)

`upgradeBuiltins(cfg, db, now, logger)` runs in `wireBuiltins` after the sync and before `SetBuiltins`, once per built-in (a `done` row in `builtin_migrations` skips it; idempotent; runs under agent markers too, as it only carries content already running):

1. On/off needs nothing: the config keys are the truth.
2. For each `PromptRef`, the role-resolved prompt-store row (the role variant when it exists, else the base row) is collected when it is `customized`.
3. If any were collected and no copy exists, `RenderOwnerCopy(e, collected)` is written to `.builtin/<id>.md`, `SyncOne` indexes it (`overridden = 1`, `builtin_base_hash` = the current shipped hash) and `ConfirmAutomation` confirms exactly those bytes. An existing copy is never overwritten. `RenderOwnerCopy` inserts `const __builtinPrompts = {…}` (each prompt one JSON string literal) at the top of the script and redirects every `builtin.defaultPrompt(` to it; a prompt not given keeps the shipped default, and the result is re-parsed in the built-in scope.
4. `RecordBuiltinMigration(id, "done")`. Any error records `failed` with the error text, sets `active[id] = false` and logs it: that built-in's **legacy phases keep running** this daemon life.

A `failed` row is an Inbox notice "Couldn't move Morning brief to Automations" with the error and **Retry** (`automations upgrade-builtins --json`; the Desktop restarts the daemon when a result is `done`, since the daemon picks its path at start).

## Go ↔ Swift dual paths

1. `db.Automation` ↔ Swift `Automation` (`origin`, `builtinID`, `overridden`, `builtinBaseHash`, `isBuiltin`; a schema without the columns reads as owner).
2. `db.TriggerSync` ↔ `AutomationRun.trigger` `"sync"`, `AutomationCardPresentation.triggerLabel` "At its slot in the sync cycle", `AutomationFailureWatch.backgroundTriggers`, `AutomationTriggerText` (`{"sync":"morning_brief"}` → "Every morning, at the first sync after its time").
3. `automations.BuiltinPrimitiveNames` ↔ `AutomationCardPresentation.permissionLine` (`builtin:brief.compose` → "Write your daily brief", `builtin:plan.compose` → "Plan your day").
4. `builtin.CardInfo` ↔ `BuiltinAutomationDetail`, decoded from the shared golden `show_morning_brief.json` through `#filePath`; `builtin.ParamKind` ↔ `Parameter.Kind` (`hour`, `clock`, `count`; an unknown kind fails the decode, so C3 adds its kinds in lockstep).
5. The daemon's `shouldRunDayPlan` hour (`briefing.hour`) ↔ `FeatureReadiness` / `EmptyStateCopyTable` / `GettingReadyPolicy` (`dayPlanHour` removed).
6. `Origin = builtin` ↔ `AutomationListSections.make`'s first section "Built in" (never in Personal).
7. CLI verbs ↔ `AutomationsCLI` (`.reset`, `.upgradeBuiltins`, `show`'s optional `builtin`, `save` passing `builtin:<id>` paths).
8. `db.RecordBuiltinMigration` / `builtin_migrations` ↔ `BuiltinUpgradeNotice` (`status = 'failed'` rows; a missing table reads as none); `builtin.Entry.Name` ↔ `BuiltinUpgradeNotice.name(for:)`.
9. `builtin.Entry.RunNow` ↔ `run_now` (the card hides **Run Now** when false).
10. `Entry.Parameters` keys ↔ `ConfigService.saveBuiltinParameters` (`briefing.hour`, `day_plan.working_hours_start|end`, `day_plan.max_timeblocks|min_backlog|max_backlog`; the card is their only writer, `ConfigService.save` no longer writes them) and `Entry.FeatureIDs` ↔ the card's Turn On/Off (`FeatureManagerService.enableNow`/`disableNow` on `feature_ids`).

## Desktop

- Automations: a first **Built in** section; a built-in row opens `BuiltinAutomationCard` (no Delete): **Run Now** (hidden when `run_now` is false, off while the built-in is off, "Runs at the next sync" until the queued run finishes), **Edit in Chat**, **Turn On/Turn Off**, ⋯ **Reset to built-in** when overridden (inline "Reset — your changes are lost" row), the "Built-in version updated" banner with **Show changes**, the unconfirmed-copy and copy-error lines, **When** (the parameters, **Save**/**Cancel** on change), **Reads**, **Sends**, **Costs** ("About $N in the last 7 days" / "No AI cost in the last 7 days" / "Cost not reported"). Card models are kept per automation id (`AutomationsViewModel.builtinCard`).
- The editor on a built-in: footer **Save** (on) / **Save and Turn On** (off) / **Confirm** (unchanged unconfirmed copy), never the CLI enable/disable; the editor chat's context adds the default prompts and the line "To change a prompt, replace builtin.defaultPrompt(\"<name>\") with the text, keeping every %s in order."
- Settings → Features: the Briefing and Day Plan tuning sections and switches are gone; `BuiltinFeaturesPointer` ("These now live in Automations → Built in", **Open Automations**). The empty states' **Change the hour** opens the Morning brief row (`EmptyStateAction.openBuiltin`).
- Inbox: the notice is read inside C1's one read (`InboxFeedQueries.read` → `InboxFeedSnapshot.builtinNotices`), listed first under Needs your decision in the All and Automations filters, with **Retry** in the reading pane (`ActionStripViewModel.retryBuiltinUpgrade`). It counts in the badge as C1 R1 defines (`docs/superpowers/plans/2026-10-22-c1-one-inbox.md`, R1); `SidebarCountsViewModel` observes `builtin_migrations`.

## v1 limits

- The legacy `phaseBriefing` / `runDayPlanPhases` code stays until the release after C3, as the fallback for a failed upgrade step or a failed sync of the row.
- Deleting the copy by hand equals **Reset**: the next sync indexes the shipped text, confirmed.
- A description-only edit of the copy keeps its confirmation (name and description are not hashed, as for owner recipes).
- The daemon's start sweep (`MarkInterruptedBuiltinRuns`) also ends a live CLI generate run if the daemon starts while it runs; the CLI then reports the run as failed.
- A `sync` brief that found no data backs off one hour; before the first digests that still writes a succeeded run every hour.
- The three plan counts are card parameters, but the plan pipeline does not read them yet (known issue in the guide).
- The Desktop prompt editors are not changed; a prompt-store edit of `briefing.daily` or `day_plan.generate` has no effect while the built-in is active.

## How C3 plugs in

In this order (C3 appends its own section below and does not rewrite this one):

1. A `builtin.Entry` in the registry (`All()`), with `RunNow` and, when false, `NoRunNowNote`, and its recipe under `recipes/`.
2. Its `Slot` constant (the slot is already reserved in `automations.SyncSlots`).
3. Its primitive names appended to `automations.BuiltinPrimitiveNames`.
4. A `PrimitiveCapability` entry only when its capability is not `builtin:<name>` (`CapabilityForPrimitive`), and a `syncTriggerAllowed` case only when a non-built-in scope may use the slot (C3: `custom_tracks` for a Personal recipe holding `track:scan`).
5. Its `Gate` (in `wireBuiltins`' gate map).
6. Its `PrimitiveFunc`s added to `Daemon.BuiltinPrimitives()`.
7. Its `PromptRef`s and `Parameter`s (new `ParamKind`s in lockstep with Swift's `Parameter.Kind`).
8. The golden show JSON `testdata/show_<id>.json`, plus a `BuiltinUpgradeNotice.name(for:)` row on the Swift side.
