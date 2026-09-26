# Inbox Demolition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Shrink `internal/inbox` to mechanical detection + auto-resolve (zero AI calls), delete the situations/feed/triage machinery and its dead Desktop surfaces, freeze the `situations` table as history, and update config, Feature Manager, inventory and docs accordingly.

**Architecture:** A demolition, landed as two stacked PRs on `feature/inbox-demolition`: PR 1 = Go + migration + docs (Tasks 1–9), PR 2 = Desktop (Tasks 10–12). Every task is compiler-guided: delete the listed files/symbols, then `go build ./... && go vet ./...` (or `swift build`) names every remaining reference; fix those, never re-add what was deleted. `inbox_items` keeps being written by the detectors and read by Catch-Up/briefing/meeting-prep/custom-tracks unchanged.

**Tech Stack:** Go 1.25, goose SQL migrations (`internal/db/migrations/`), SwiftUI + GRDB (`WatchtowerDesktop/`).

**Spec:** `docs/superpowers/specs/2026-09-14-inbox-demolition-design.md` — read it first; every task below cites its section.

## Global Constraints

- Everything committed to the repo (code, comments, commit messages, docs) is in English.
- Inner loop: `go test ./internal/<pkg>` (no `-count=1`); Swift: `make test-swift FILTER=<TestClass>`; lint: `make lint-diff`. Full `make test`, `make test-swift`, `make lint-all` only at the PR gate.
- Never delete `WatchtowerDesktop/.build`.
- Guard tests of the removed behaviour (`TestInbox01/03/04/06/07_*`, `TestDash01..07_*`) are **deleted with the behaviour**, never relaxed or renamed. Guard tests of surviving behaviour (`TestInbox02_*`, `TestInbox09_*`, `TestMemory05_*`, `TestMemory10_*`) keep their names; only their now-dead setup lines change.
- Stable identifiers keep their old word: feature id `secretary-inbox`, prompt id `inbox.style_sample`, `workspace.secretary_profile`, `SecretaryProfile*` Swift types, sidebar destination `.inbox`.
- Work only inside the worktree `.claude/worktrees/inbox-demolition` on branch `feature/inbox-demolition`; verify `git branch --show-current` before every commit; never `git add -A` — add the files you touched.
- Commit after every task with the message given in the task.

---

## File map (what each task owns)

| Task | Deletes | Modifies | Creates |
|---|---|---|---|
| 1 Feed | `internal/feed/`, `internal/db/feed.go`, `internal/db/feed_test.go`, `cmd/feed.go`, `internal/daemon/daemon_feed_test.go` | `internal/daemon/daemon.go`, `cmd/sync.go`, `cmd/inbox.go`, `internal/db/gmail.go`, `internal/db/slack_purge.go` + their tests | — |
| 2 Inbox AI stages | `internal/inbox/{triage,learner,compose,situation_card,situation_feedback,feedback,brief,user_preferences}.go` + tests | `internal/inbox/pipeline.go`, `pipeline_test.go`, `pipeline_extra_test.go`, `e2e_test.go`, `watchtower_detector.go` + test, `internal/daemon/daemon.go`, `cmd/inbox.go`, `internal/prompts/store.go` (+ defaults), `internal/db/inbox_feedback.go` (deleted), `internal/db/situations.go` (writers) | — |
| 3 style-sample → profile | — | `cmd/profile.go`, `cmd/inbox.go`, `cmd/inbox_test.go` | — |
| 4 Situations readers | `cmd/situations.go` + test, `internal/tools/situations.go` + test, `internal/devpack/skills/watchtower-whats-changed/` | `internal/tools/readtools.go`, `internal/mcp` tests, `internal/devpack` tests | — |
| 5 Memory | `internal/memory/action_ingest.go` + test, `internal/memory/ingest.go` situations-ingest part + tests | `internal/memory/pipeline.go`, `internal/memory/provenance.go`, `internal/db/memory.go`, `internal/inbox/watchtower_detector.go` | — |
| 6 Config + features | — | `internal/config/{config,defaults}.go`, `cmd/config.go`, `cmd/features.go`, `internal/features/{registry,fastforward}.go` + tests | — |
| 7 Migration | — | `internal/db/schema.sql`, `internal/db/db_test.go`, schema golden, `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`, `TestDatabase.swift` | `internal/db/migrations/00070_inbox_demolition.sql` |
| 8 Briefing query fix | — | `internal/db/inbox.go`, `internal/db/inbox_test.go` | — |
| 9 Docs | `docs/inventory/dashboard.md` (tombstoned, not deleted) | `docs/inventory/{inbox-pulse,memory,agent-actions,dev-surface,reaction-commands,catchup,features,README}.md`, `CLAUDE.md`, `docs/app-guide.md` | — |
| 10 Swift dead UI | files listed in Task 10 | `AppState.swift`, `SidebarCountsViewModel.swift`, `TargetPrefillBuilder.swift` | — |
| 11 Swift queries | `FeedItemQueries.swift`, `InboxFeedbackQueries.swift`, models | `SituationQueries.swift`, `InboxQueries.swift`, tests | — |
| 12 Swift gate | — | — | — |

---

## PR 1 — Go + migration + docs

### Task 1: Delete the feed publisher

Spec §3.2, §3.3, §4. `internal/feed` published `feed_items` for the dead Dashboard timeline. Remove it end to end before touching the inbox, so later tasks build on a smaller surface.

**Files:**
- Delete: `internal/feed/` (whole package), `internal/db/feed.go`, `internal/db/feed_test.go`, `cmd/feed.go`, `internal/daemon/daemon_feed_test.go`
- Modify: `internal/daemon/daemon.go` (`feedPipe` field :92, `SetFeedPipeline` :202-205, `phaseFeed` :1194-1215 and its call at :414, the `internal/feed` import), `cmd/sync.go:597` (`d.SetFeedPipeline(...)` + import), `cmd/inbox.go` (the two `feed.New(database, cfg, logger).Publish(time.Now())` calls inside `runInboxGenerate` at ~:519 and ~:542 + import), `internal/db/gmail.go:97,120,144` and `internal/db/slack_purge.go:40` (the `feed_items` purge statements), `internal/db/gmail_test.go` (`feed_items` inserts/asserts at :180,:236,:272,:275,:279), `internal/db/slack_purge_test.go` (same pattern if present)

**Interfaces:**
- Produces: `Daemon` without `feedPipe`; `cmd/sync.go` no longer imports `internal/feed`.

- [ ] **Step 1: Delete the package and the CLI command**

```bash
git rm -r internal/feed internal/db/feed.go internal/db/feed_test.go cmd/feed.go internal/daemon/daemon_feed_test.go
```

- [ ] **Step 2: Build and fix every dangling reference**

Run: `go build ./... 2>&1 | head -40`
Expected: errors in `internal/daemon/daemon.go`, `cmd/sync.go`, `cmd/inbox.go`. Remove the `feedPipe` field, `SetFeedPipeline`, `phaseFeed` (and the comment block above it explaining why `feed.enabled` is deliberately unchecked), the `d.phaseFeed()` call in `runCycle`, the `SetFeedPipeline` call in `cmd/sync.go`, and both `feed.New(...).Publish(...)` blocks in `cmd/inbox.go`. Drop the now-unused imports. Repeat until `go build ./...` is clean.

- [ ] **Step 3: Remove the `feed_items` purge statements**

In `internal/db/gmail.go` and `internal/db/slack_purge.go`, delete the statements that `DELETE FROM feed_items …` (three in gmail.go, one in slack_purge.go). Do NOT touch the `inbox_items`, `inbox_feedback` (Task 7 handles that one), `situations` or `situation_signals` statements in the same functions. Then in `internal/db/gmail_test.go` delete the `feed_items` fixture inserts and the `SELECT COUNT(*) FROM feed_items …` assertions — the surrounding test still asserts the inbox/situation purges.

- [ ] **Step 4: Run the affected tests**

Run: `go vet ./... && go test ./internal/db ./internal/daemon ./cmd -run 'Gmail|Slack|Daemon|Inbox' 2>&1 | tail -20`
Expected: `ok` for all three packages. `internal/daemon`'s `TestToolsList`-style enumerations do not cover feed; if a daemon gates test lists `phaseFeed` by name, delete that entry.

- [ ] **Step 5: Commit**

```bash
git add -A internal/feed internal/db cmd/feed.go cmd/sync.go cmd/inbox.go internal/daemon
git commit -m "refactor(feed): delete the dashboard feed publisher

internal/feed mirrored situations/meetings/briefings into feed_items for the
Dashboard timeline, which has had no reachable view since Wave 2. Removes the
package, the daemon phase, the CLI command and the purge statements; the table
itself is dropped by the migration in a later commit."
```

---

### Task 2: Cut the inbox pipeline down to detection + auto-resolve

Spec §3.1, §3.2, §3.3, §3.5, §3.6. This is the core cut. The surviving `Run` is detect → auto-resolve → archive/unsnooze → watermark; the watermark rule keeps INBOX-09's meaning (detector error freezes) and simply loses the triage arms.

**Files:**
- Delete: `internal/inbox/triage.go`, `triage_test.go`, `learner.go`, `learner_test.go`, `compose.go`, `compose_test.go`, `situation_card.go`, `situation_card_test.go`, `situation_feedback.go`, `situation_feedback_test.go`, `feedback.go`, `feedback_test.go`, `brief.go`, `brief_test.go`, `user_preferences.go`, `user_preferences_test.go`, `internal/db/inbox_feedback.go` (+ its test if one exists)
- Modify: `internal/inbox/pipeline.go`, `pipeline_test.go`, `pipeline_extra_test.go`, `e2e_test.go`, `testhelpers_test.go`, `internal/inbox/watchtower_detector.go` + `watchtower_detector_test.go`, `internal/daemon/daemon.go`, `cmd/inbox.go`, `cmd/inbox_test.go`, `internal/prompts/store.go` and wherever the four prompt defaults live (grep `InboxTriage`, `InboxCompose`, `InboxSituationCard`, `"inbox.situation_learn"`), `internal/db/situations.go`, `internal/db/situations_test.go`, `internal/digest/tier_scan_test.go` (`allowedStrongSources` loses `inbox.compose`/`inbox.situation_card` if listed)

**Interfaces:**
- Produces: `(*inbox.Pipeline).Run(ctx) (created, resolved int, err error)` — same signature, no AI; `inbox.New(database, cfg, gen, logger)` keeps its signature (`gen` stays for the style-sample generator until Task 3 moves it; after Task 3 it may still be accepted and ignored — do not change the signature in this task). `AccumulatedUsage()` keeps returning zeros. `RunFastDetection` is gone. `decideWatermark(lastTS float64, detectErr error) (float64, bool)`.

- [ ] **Step 1: Delete the AI-stage files**

```bash
git rm internal/inbox/triage.go internal/inbox/triage_test.go internal/inbox/learner.go internal/inbox/learner_test.go internal/inbox/compose.go internal/inbox/compose_test.go internal/inbox/situation_card.go internal/inbox/situation_card_test.go internal/inbox/situation_feedback.go internal/inbox/situation_feedback_test.go internal/inbox/feedback.go internal/inbox/feedback_test.go internal/inbox/brief.go internal/inbox/brief_test.go internal/inbox/user_preferences.go internal/inbox/user_preferences_test.go internal/db/inbox_feedback.go
```

- [ ] **Step 2: Rewrite `Run`, `decideWatermark`, `runArchiveAndUnsnooze`; delete `RunFastDetection`, `loadUntriaged`, `runTriagePhase`, `runComposePhase`**

Replace the `decideWatermark` function and the `Run` method in `internal/inbox/pipeline.go` with:

```go
// decideWatermark computes the new watermark timestamp per INBOX-09 (see
// docs/inventory/inbox-pulse.md): a detector error freezes the watermark so
// the failed source's window is re-scanned next cycle; a clean pass advances
// it. ok is false when the watermark must stay frozen.
func decideWatermark(detectErr error) (ts float64, ok bool) {
	if detectErr != nil {
		return 0, false
	}
	// Use a 30-minute buffer instead of wall-clock time to account for
	// Slack search API indexing delays — messages may arrive in the DB
	// with ts_unix values behind wall-clock time.
	return float64(time.Now().Add(-30 * time.Minute).Unix()), true
}

// Run executes the inbox pipeline: dedup, detect new items, auto-resolve,
// auto-archive, unsnooze, then advance the watermark. It makes no AI calls —
// the inbox is a mechanical feeder for Catch-Up, the briefing and meeting
// prep (docs/superpowers/specs/2026-09-14-inbox-demolition-design.md).
// Returns (created count, resolved count, error). A detector error is
// logged, freezes the watermark (INBOX-09) and is returned to the caller.
func (p *Pipeline) Run(ctx context.Context) (int, int, error) {
	if p.cfg != nil && !p.cfg.Inbox.Enabled {
		return 0, 0, nil
	}

	currentUserID, err := p.resolveCurrentUserID()
	if err != nil {
		return 0, 0, fmt.Errorf("getting current user: %w", err)
	}
	if currentUserID == "" {
		p.logger.Println("inbox: no current user set, skipping")
		return 0, 0, nil
	}

	lastTS, sinceTime := p.resolveWatermarkWindow("inbox")

	const totalSteps = 4

	// Phase 0: Deduplicate existing thread inbox items (cleanup from before thread-grouping).
	p.dedupThreadItems("inbox")

	// Phase 1: Detection — Slack + external sources (individually non-fatal, but a
	// failure freezes the watermark below so no window is skipped).
	p.progress(1, totalSteps, "detecting")
	stepStart := time.Now()
	createdSlack, createdJira, createdCalendar, createdGmail, createdImap, createdWatchtower, detectErr := p.detectAll(ctx, currentUserID, lastTS, sinceTime)
	created := createdSlack + createdJira + createdCalendar + createdGmail + createdImap + createdWatchtower
	p.LastStepDurationSeconds = time.Since(stepStart).Seconds()

	// Phase 2: Auto-resolve — rule-based resolution for all source types (INBOX-02).
	p.progress(2, totalSteps, "auto-resolving")
	stepStart = time.Now()
	resolved := p.autoResolveByRules(ctx)
	p.LastStepDurationSeconds = time.Since(stepStart).Seconds()

	// Phase 3: Auto-archive expired/stale items and unsnooze expired snoozes.
	p.progress(3, totalSteps, "archiving")
	archived := p.runArchiveAndUnsnooze()

	// Watermark decision — see docs/inventory/inbox-pulse.md INBOX-09.
	if ts, ok := decideWatermark(detectErr); ok {
		p.advanceWatermark(ts, lastTS)
	} else {
		p.logger.Printf("inbox: detector error, leaving watermark unchanged to avoid losing the skipped window: %v", detectErr)
	}

	p.progress(totalSteps, totalSteps, "done")

	p.logger.Printf("inbox: +%d new (S%d J%d C%d G%d M%d T%d), %d auto-resolved, %d auto-archived",
		created, createdSlack, createdJira, createdCalendar, createdGmail, createdImap, createdWatchtower,
		resolved, archived)

	return created, resolved, detectErr
}
```

Note the behaviour change stated in the spec and pinned by the existing guard: the old `Run` returned `nil` on a pure detector error (only triage errors were surfaced). Check `TestInbox09_WatermarkFrozenOnDetectorError` in `pipeline_test.go` — it asserts the watermark, not the returned error. Keep returning `detectErr` so the daemon's `trackedPipelineRun` records a real error row (the wave-2 "partial failure ≠ success" rule); update the guard's error expectation if it asserts `nil`, keeping its name and its watermark assertion untouched.

`runArchiveAndUnsnooze` loses the "Dashboard situation lifecycle" block (`UnsnoozeExpiredSituations` + `MarkStaleSituations`) and its comment. `detectAll` loses the `includeWatchtower` parameter (always include) and the `detectMemoryDisputes` block (Task 5 deletes the function; here just remove the call and the `disputesEnabled` line). Delete `RunFastDetection`, `loadUntriaged`, `runTriagePhase`, `runComposePhase`, and the token-accumulation fields/methods that no longer have a writer (`accumulateUsage`, `totalInputTokens` etc.) — keep `AccumulatedUsage()` returning `0, 0, 0, 0` because `cmd/inbox.go` and the daemon call it (simplify their call sites only if trivial). Keep `SetPromptStore` and `getPrompt` only if `backfill.go` or the detectors use them; otherwise delete.

- [ ] **Step 3: Delete the `decision_made` branch of the watchtower detector**

In `internal/inbox/watchtower_detector.go` remove the digest-decisions loop that mints `decision_made` items (the block around :100-135), the doc line "decision_made — digest situations …", `detectMemoryDisputes`, `mintDisputeItem` and their helpers; keep `wtExistsInboxItem` and the `briefing_ready` loop. In `watchtower_detector_test.go` delete the decision_made / dispute tests and keep the briefing_ready ones. In `internal/inbox/classifier.go` keep the `"decision_made"` map entry (the CHECK constraint still allows the value and historical rows carry it).

- [ ] **Step 4: Daemon and CLI**

`internal/daemon/daemon.go`: delete `phaseFastInbox` (:720-735) and its call (:376); in `phaseInbox` (:957-980) keep the gate, the `trackedPipelineRun("inbox", …)` wrap and the `Run` call; the `AccumulatedUsage` plumbing may stay (it returns zeros). Update the `phaseInbox` doc comment: "runs the inbox detection pipeline (mechanical, no AI): Slack/Jira/Calendar/Gmail/IMAP triggers, briefing_ready, auto-resolve, archive."

`cmd/inbox.go`: remove `inboxFeedbackCmd` and `runInboxFeedback` (:589-628) and the command from the `AddCommand` list at :119; in `runInboxGenerate` remove any remaining triage/compose progress labels. Leave `inboxStyleSampleCmd` for Task 3.

`internal/prompts/store.go`: delete the `InboxTriage`, `InboxCompose`, `InboxSituationCard` constants and their default prompt texts/versions (grep the package for each constant and for the literal `"inbox.situation_learn"`; delete every default registration). Keep `InboxStyleSample`.

`internal/db/situations.go`: delete the writer functions that now have no caller — `CreateSituation`, `CreateSituationTx`, `AddSituationSignals`, `AddSituationSignalsTx`, `ListUncomposedSignals`, `MarkSignalsComposed`, `MarkSignalsComposedTx`, `ListTrackEventsSince`, `ListTargetsUpdatedSince`, `UpdateSituationRank`, `UpdateSituationRankTx`, `SetSituationCard`, `MarkSituationCardFailed`, `ResetSituationCard`, `ResetSituationCardTx`, `ListSituationsNeedingCards`, `SetSituationStatus`, `SnoozeSituation`, `UnsnoozeExpiredSituations`, `MarkStaleSituations`, `AutoCloseResolvedSituations`, `MarkSituationConverted`, `SetSuggestedResolutionTx`, `ClearSuggestedResolution`, `ClearSuggestedResolutionTx`, `ListOpenSituations`. Before deleting each, `grep -rn "<Name>(" internal cmd --include=*.go | grep -v _test` — if a non-test caller outside `internal/inbox` remains (Task 4/5 readers: `GetSituation`, `ListSituations`, `ListSituationSignals` stay), keep it. Delete the matching tests in `situations_test.go`.

- [ ] **Step 5: Build, vet, fix tests**

Run: `go build ./... && go vet ./... 2>&1 | head -40`
Then: `go test ./internal/inbox ./internal/db ./internal/daemon ./internal/prompts ./internal/digest ./cmd -run 'Inbox|Situation|Prompt|Tier|Daemon' 2>&1 | tail -30`

Test files to reconcile (delete the tests of deleted behaviour, keep the rest): `internal/inbox/pipeline_test.go` (`TestInbox01_*`, `TestInbox03_*`, `TestInbox07_*` go; `TestInbox02_*`, `TestInbox09_*` stay), `pipeline_extra_test.go`, `e2e_test.go` (any triage/compose stage assertions), `testhelpers_test.go` (fake generator helpers that only triage used), `internal/daemon/daemon_gates_test.go` and `daemon_test.go` (fast-inbox cases), `cmd/inbox_test.go` (feedback subcommand), `internal/digest/tier_scan_test.go` (`allowedStrongSources` entries for removed sources — the scan asserts a **floor** of 30 tagged calls; confirm it still passes and adjust the floor only if the removed calls drop it below, stating the new count in the commit message).

Expected: all `ok`.

- [ ] **Step 6: Commit**

```bash
git add -A internal/inbox internal/db internal/daemon internal/prompts internal/digest cmd/inbox.go cmd/inbox_test.go
git commit -m "refactor(inbox): cut the pipeline down to detection + auto-resolve

Removes triage, the implicit learner, compose, situation cards, situation
feedback, per-item feedback and the prompt-building helpers — the inbox makes
no AI call any more and is a mechanical feeder for Catch-Up, the briefing and
meeting prep. Run is detect -> auto-resolve -> archive/unsnooze -> watermark;
decideWatermark keeps INBOX-09 (detector error freezes) and drops its triage
arms. phaseFastInbox and RunFastDetection go (they existed to surface DMs in a
UI that no longer exists). Situations lose every writer and are frozen as
history; the decision_made watchtower trigger is retired.

Spec: docs/superpowers/specs/2026-09-14-inbox-demolition-design.md"
```

---

### Task 3: Move `style-sample` under `watchtower profile`

Spec §3.2. `workspace.style_profile` is read by `internal/meeting/followup.go`, so the generator survives; it just stops living under `inbox`.

**Files:**
- Modify: `cmd/profile.go`, `cmd/inbox.go` (`inboxStyleSampleCmd` :104-110, `runInboxStyleSample` :629-706, the `AddCommand` list), `cmd/inbox_test.go` / `cmd/profile_test.go` (whichever holds the style-sample test)

**Interfaces:**
- Produces: `watchtower profile style-sample` with the same flags and output as the old `inbox style-sample`; `inbox.GenerateStyleProfile` (in `internal/inbox/style_sample.go`) unchanged.

- [ ] **Step 1: Write the failing test**

In `cmd/profile_test.go` (create if absent, same package `cmd`, reusing the isolated-`HOME` `TestMain`):

```go
func TestProfileStyleSample_Registered(t *testing.T) {
	sub, _, err := rootCmd.Find([]string{"profile", "style-sample"})
	require.NoError(t, err)
	require.Equal(t, "style-sample", sub.Name())

	_, _, err = rootCmd.Find([]string{"inbox", "style-sample"})
	// cobra returns the parent when the child is unknown; assert it is not the child.
	found, _, _ := rootCmd.Find([]string{"inbox", "style-sample"})
	require.NotEqual(t, "style-sample", found.Name(), "inbox style-sample must be gone")
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `go test ./cmd -run TestProfileStyleSample_Registered`
Expected: FAIL (`profile style-sample` not found).

- [ ] **Step 3: Move the command**

Cut `inboxStyleSampleCmd` + `runInboxStyleSample` out of `cmd/inbox.go` into `cmd/profile.go`, rename to `profileStyleSampleCmd` / `runProfileStyleSample`, register with `profileCmd.AddCommand(profileStyleSampleCmd)` in `cmd/profile.go`'s `init`, remove it from `inboxCmd`'s `AddCommand` list. Keep `Use: "style-sample"`, the flags and the "Style profile regenerated." output byte-identical. Move its existing test alongside.

- [ ] **Step 4: Run the tests**

Run: `go test ./cmd -run 'Profile|StyleSample'`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add cmd/profile.go cmd/inbox.go cmd/profile_test.go cmd/inbox_test.go
git commit -m "refactor(cli): move style-sample from inbox to profile

workspace.style_profile outlives the inbox (meeting follow-ups read it), so
its generator now lives with the other owner-profile commands."
```

---

### Task 4: Remove the situations readers (CLI, agent read tools, dev-pack skill)

Spec §5.1. Handing a coding agent a table frozen on 2026-09-06 as "what is going on" is audit L4.

**Files:**
- Delete: `cmd/situations.go`, `cmd/situations_test.go`, `internal/tools/situations.go`, `internal/tools/situations_test.go`, `internal/devpack/skills/watchtower-whats-changed/` (directory)
- Modify: `internal/tools/readtools.go` (drop `NewListSituations()`, `NewGetSituation()`), `internal/tools/registry_test.go` (`TestBuildToolRegistry_PinsWriteToolsReadToolsAndSurfaces` lives in `cmd/actions_registry_test.go` — update its read-tool list), `internal/mcp/server_test.go` (`TestToolsList` expected set), `internal/mcp/actions_test.go`, `internal/agentloop/loop_test.go` (if it names the tools), `internal/devpack/*_test.go` (skill count/names), the other three `SKILL.md` files if they cross-reference `list_situations` (grep)

- [ ] **Step 1: Delete**

```bash
git rm cmd/situations.go cmd/situations_test.go internal/tools/situations.go internal/tools/situations_test.go
git rm -r internal/devpack/skills/watchtower-whats-changed
```

- [ ] **Step 2: Build, then fix the tool lists and tests**

Run: `go build ./... && go vet ./... 2>&1 | head`
Remove the two constructors from `ReadTools()`. Then: `go test ./internal/tools ./internal/mcp ./internal/agentloop ./internal/devpack ./cmd -run 'Tools|Registry|Skill|Pack|Situation' 2>&1 | tail -20` — update every expected-tool-set / expected-skill-set literal to the new reality (remove `list_situations`, `get_situation`, `watchtower-whats-changed`). Do not lower any coverage floor that is not about these tools.

`grep -rn "list_situations\|get_situation\|whats-changed" internal cmd docs --include=*.md --include=*.go` — the remaining SKILL.md files must not mention the removed tools; docs hits are Task 9's.

- [ ] **Step 3: Commit**

```bash
git add -A cmd/situations.go cmd/situations_test.go internal/tools internal/mcp internal/agentloop internal/devpack cmd/actions_registry_test.go
git commit -m "refactor(tools): retire the situations CLI, read tools and the whats-changed skill

Situations stopped being written on 2026-09-06 and are now frozen history;
list_situations/get_situation would hand a coding agent a stale picture as
current (audit L4). The watchtower-whats-changed skill was built entirely on
them and goes with them; a Catch-Up-based replacement needs Catch-Up exposed
as a read tool first (follow-up)."
```

---

### Task 5: Memory — drop the situations ingest, the interaction ingest and the disputes surface

Spec §5.2, §5.3. All three sources of `runInteractionIngest` die in this demolition, so the step goes; the belief-math surface (`owner-action` rank, `act:` scheme, `memory_engagement`, OWNER ACTIONS block) stays and starves.

**Files:**
- Delete: `internal/memory/action_ingest.go`, `action_ingest_test.go`
- Modify: `internal/memory/ingest.go` (delete `IngestSituations`, `ingestNewSituation`, `ingestExistingSituation`, `listIngestSituations`, `situationProvenance`, `situationBody`, `situationOutcome`, `ingestSummary`, the `ingestSituation`/`IngestStats` types if nothing else uses them — keep `jiraProjectKey` if another file calls it), `ingest_test.go` (delete the situations-ingest tests; `TestMemory05_InboxUntouched` stays if it pins a surviving read — if its only subject was the situations ingest, delete it and note that in the commit; `TestMemory05_InteractionIngestInboxUntouched` in `action_ingest_test.go` goes with the file), `internal/memory/pipeline.go` (:331 `IngestSituations` call + its step accounting; :398-409 `Sources.Actions` block; `RunStats.Ingested` if orphaned), `internal/memory/provenance.go` (`actResolver` doc: `inbox_feedback` is no longer a whitelisted table), `internal/db/memory.go` (`InteractionExists` whitelist drops `inbox_feedback`; delete `MemoryInteractionFloor`, `SetMemoryInteractionFloor`, `MemorySituationFeedbackFloor`, `SetMemorySituationFeedbackFloor`, `ListInteractionFeedback`, `ListSituationFeedback`, `ListInteractionSituations`, `BumpEngagement`/`BumpEngagements` **only if** no remaining caller — `grep` first; keep `GetEngagement`, `LinkedEntityEngagement`), `internal/db/memory_test.go`, `internal/memory/reflect_test.go` (`TestMemory10_DisputeFlagsNeverTouchInboxFromMemory` — keep name; it pins that memory writes only `memory_dispute_flags`, which is still true), `internal/memory/config` reads of `cfg.Sources.Actions` / `cfg.Surfaces.Disputes` (compile errors after Task 6 removes the fields — remove the reads now and leave the fields to Task 6, or do Task 6 first; either order compiles as long as both land before the PR)
- Also: `cmd/memory.go` if it exposes an `ingest`/`consolidate` flag naming situations.

- [ ] **Step 1: Delete `action_ingest.go` and the situations-ingest functions**

```bash
git rm internal/memory/action_ingest.go internal/memory/action_ingest_test.go
```
Then edit `ingest.go` as listed above.

- [ ] **Step 2: Build and fix**

Run: `go build ./... && go vet ./... 2>&1 | head -40`
Fix `pipeline.go` (remove the two steps; renumber nothing — step rows are appended in order, so later steps simply shift), `provenance.go`, `internal/db/memory.go`. Then `go test ./internal/memory ./internal/db -run 'Memory|Engagement|Interaction|Ingest|Provenance' 2>&1 | tail -30`. `TestMemory02_*` (reindex equivalence) must stay green — it dumps `memory_provenance`, not the deleted tables.

- [ ] **Step 3: Commit**

```bash
git add -A internal/memory internal/db/memory.go internal/db/memory_test.go cmd/memory.go
git commit -m "refactor(memory): drop the situations ingest, the interaction ingest and the disputes reader

The situations source dried up on 2026-09-06 and every source of the
interaction ingest (inbox_feedback, situation thumbs, situation verdicts) is
removed by the inbox demolition. The owner-action rank, the act: scheme and
memory_engagement stay in place and simply receive nothing (MEM-12/15
untouched); re-feeding engagement from Catch-Up thumbs is a recorded owner
call. memory_dispute_flags keeps its writers; its only reader was the retired
decision_made inbox trigger."
```

---

### Task 6: Config keys and the Feature Manager

Spec §6.

**Files:**
- Modify: `internal/config/config.go` (`InboxConfig` loses `MaxTriageMessages`, `MaxAwarenessCards`, `Situations`; delete `InboxSituationsConfig`, `FeedConfig`, `DashboardConfig` and their fields on `Config`; delete the `SetDefault` lines :453-455, :464-467, :519 `memory.surfaces.disputes`, :522 `memory.sources.actions`; delete `Disputes` from `MemorySurfacesConfig` and `Actions` from `MemorySourcesConfig`), `internal/config/defaults.go` (:39-45, :120-122), `internal/config/config_test.go`, `cmd/config.go` (allowlist :244, :247, :268), `cmd/features.go` (:323-326, :337-340 cases), `internal/features/registry.go` (delete the `dashboard` :53-66 and `feed` :95-109 entries; rewrite `secretary-inbox` :111-130; delete the two memory sub-toggles :308-312, :343-347), `internal/features/fastforward.go` (:47-50 drop `SetComposeLastRunTS`), `internal/features/*_test.go`, `internal/db/workspace.go` (`SetComposeLastRunTS`/`GetComposeLastRunTS` deleted if no caller remains)

- [ ] **Step 1: Write the failing registry test**

Append to `internal/features/registry_test.go`:

```go
func TestRegistry_InboxIsAttentionDetection(t *testing.T) {
	f, ok := ByID("secretary-inbox")
	require.True(t, ok)
	require.Equal(t, "Attention detection", f.Title)
	require.Equal(t, CostNone, f.Cost)
	require.Empty(t, f.SubToggles)
	require.Equal(t, []string{"briefing"}, f.FeedsInto)

	_, ok = ByID("dashboard")
	require.False(t, ok, "dashboard feature entry must be gone")
	_, ok = ByID("feed")
	require.False(t, ok, "feed feature entry must be gone")
}
```
(Adjust `ByID`'s return shape to the real signature — check `registry.go`.)

- [ ] **Step 2: Run it to verify it fails**

Run: `go test ./internal/features -run TestRegistry_InboxIsAttentionDetection`
Expected: FAIL.

- [ ] **Step 3: Rewrite the registry entry**

```go
	{
		ID:          "secretary-inbox",
		Title:       "Attention detection",
		Description: "Detects mentions, DMs, thread replies and mail addressed to you and closes them when you answer in the source — no AI. Feeds Catch-Up and the daily Briefing.",
		Tagline:     "Know what was waiting on you",
		Benefits: []string{
			"Mentions, DMs, replies and mail to you collected across every connected account",
			"Closed automatically when you answer in Slack, Jira or mail",
			"Powers Catch-Up's \"needs you\" list and the Briefing — no AI cost",
		},
		Icon:      "tray",
		ConfigKey: "inbox.enabled",
		Cost:      CostNone,
		FeedsInto: []string{"briefing"},
		Enabled:   func(cfg *config.Config) bool { return cfg.Inbox.Enabled },
	},
```
Delete the `dashboard` and `feed` entries, the two memory sub-toggles, and `fastForwardSecretaryInbox`'s `SetComposeLastRunTS` call (update its doc comment: only INBOX-09's watermark now). Then apply the config/cmd deletions listed in **Files**.

- [ ] **Step 4: Build, fix, test**

Run: `go build ./... && go vet ./... && go test ./internal/config ./internal/features ./cmd -run 'Config|Feature|Registry|FastForward' 2>&1 | tail -20`
Expected: all `ok`. Existing registry tests that enumerate ids (e.g. a `Dependents()` closure test naming `feed`/`dashboard`, or a "every feature's FeedsInto targets exist" invariant) are updated to the new set, not weakened.

- [ ] **Step 5: Commit**

```bash
git add internal/config internal/features cmd/config.go cmd/features.go internal/db/workspace.go internal/db/workspace_test.go
git commit -m "refactor(config,features): retire the situations/feed/dashboard keys and re-describe the inbox feature

Removes inbox.max_triage_messages, inbox.max_awareness_cards,
inbox.situations.enabled, dashboard.*, feed.*, memory.surfaces.disputes and
memory.sources.actions (viper ignores stale keys in an existing config.yaml;
config set refuses them). The dashboard and feed feature entries described a
surface that no longer exists; secretary-inbox keeps its id and becomes
\"Attention detection\", CostNone, feeding the briefing only."
```

---

### Task 7: Migration 00070 — freeze situations, drop the dead tables, deregister the prompts

Spec §3.6, §4. Use the `add-migration` skill's checklist.

**Files:**
- Create: `internal/db/migrations/00070_inbox_demolition.sql`
- Modify: `internal/db/schema.sql` (remove `inbox_feedback` :526-…, `feed_items` :1315-…, `feed_state` :1332-… and their indexes; add a comment above `situations` "frozen read-only history since migration 00070 — no writer remains"), `internal/db/db_test.go:178` (`TestAllTablesExist` list), `internal/db/testdata/*.golden` (regenerate), `internal/db/gmail.go` + `slack_purge.go` (delete the `DELETE FROM inbox_feedback` statements; keep `inbox_items`/`situations`/`situation_signals` purges), `internal/db/gmail_test.go` (:155, :229-230), `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (:337-344 `inbox_feedback`, :878-890 `feed_items`, plus `feed_state` if present), `WatchtowerDesktop/Tests/Support/TestDatabase.swift` (:518 `inbox_feedback` insert, :685 `feed_items` insert), `internal/db/migrations_test.go` if it pins the latest version number

- [ ] **Step 1: Write the migration**

```sql
-- +goose Up
-- Inbox demolition (docs/superpowers/specs/2026-09-14-inbox-demolition-design.md):
-- the situations composer, situation cards, per-item feedback and the
-- dashboard feed publisher are removed. Situations are frozen as read-only
-- history; the tables only the dead Dashboard read are dropped; the retired
-- AI prompts are deregistered (the 00012 precedent).

-- No writer remains, so an "open" situation is a lie: freeze them as stale.
UPDATE situations SET status = 'stale', updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE status = 'open';

-- decision_made trigger items were rendered only by the Dashboard.
UPDATE inbox_items SET status = 'resolved', updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
 WHERE trigger_type = 'decision_made' AND status = 'pending';

DROP TABLE IF EXISTS inbox_feedback;
DROP TABLE IF EXISTS feed_items;
DROP TABLE IF EXISTS feed_state;

DELETE FROM prompts WHERE id IN ('inbox.triage', 'inbox.compose', 'inbox.situation_card', 'inbox.situation_learn');

-- +goose Down
-- Irreversible by design: the dropped tables held derived/empty data and the
-- prompts re-seed from defaults on downgrade builds.
```

Check `situations.updated_at` and `inbox_items.updated_at` exist in `schema.sql` before relying on them (both do as of 00069; if a column is named differently, use the real name).

- [ ] **Step 2: Write the migration test**

In `internal/db/migrations_test.go` (or the file holding the per-migration tests), add:

```go
func TestMigration00070_FreezesSituationsAndDropsDeadTables(t *testing.T) {
	d := openTestDB(t) // the package's standard fixture opener

	for _, tbl := range []string{"inbox_feedback", "feed_items", "feed_state"} {
		var n int
		err := d.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?`, tbl).Scan(&n)
		require.NoError(t, err)
		require.Zero(t, n, "%s must be dropped", tbl)
	}
	var open int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM situations WHERE status='open'`).Scan(&open))
	require.Zero(t, open)
	var prompts int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM prompts WHERE id IN ('inbox.triage','inbox.compose','inbox.situation_card','inbox.situation_learn')`).Scan(&prompts))
	require.Zero(t, prompts)
}
```
(An "open" situation inserted before `db.Open` runs the migrations is the strong form of the first assertion; use the package's pre-migration fixture helper if one exists — the 00068/00069 tests show the pattern.)

- [ ] **Step 3: Run the test to verify it fails, then apply the schema mirrors**

Run: `go test ./internal/db -run TestMigration00070`
Expected: FAIL (tables still exist until the migration file is picked up — if goose already applied it, the failure is in the schema golden instead).

Edit `schema.sql`, `db_test.go`'s table list, the purge statements, then regenerate: `go test ./internal/db/ -run TestSchemaGolden -update`.

- [ ] **Step 4: Mirror into the Swift fixture**

Delete the `inbox_feedback`, `feed_items`, `feed_state` `CREATE TABLE`/`CREATE INDEX` blocks in `TestDatabase+Schema.swift` and the fixture inserts in `TestDatabase.swift`. Do not run the Swift tests yet (Task 12 does); just keep the file syntactically valid.

- [ ] **Step 5: Run the db tests**

Run: `go test ./internal/db 2>&1 | tail -10`
Expected: `ok`, including `TestAllTablesExist`, `TestSchemaGolden`, `TestMigration00070_*`.

- [ ] **Step 6: Commit**

```bash
git add internal/db/migrations/00070_inbox_demolition.sql internal/db/schema.sql internal/db/db_test.go internal/db/testdata internal/db/gmail.go internal/db/gmail_test.go internal/db/slack_purge.go internal/db/slack_purge_test.go internal/db/migrations_test.go WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift WatchtowerDesktop/Tests/Support/TestDatabase.swift
git commit -m "db(00070): freeze situations, drop inbox_feedback/feed_items/feed_state, deregister the retired inbox prompts

Open situations become stale (no writer remains), pending decision_made
items resolve (their only renderer is gone), the three tables only the dead
Dashboard read are dropped, and the inbox.triage/compose/situation_card/
situation_learn prompt rows are removed. The Swift test fixture schema
mirrors the drops."
```

---

### Task 8: Briefing query stops surfacing archived items

Spec §3.4 — the one folded-in bug.

**Files:**
- Modify: `internal/db/inbox.go:314-335` (`GetInboxItemsForBriefing`), `internal/db/inbox_test.go`

- [ ] **Step 1: Write the failing test**

```go
func TestGetInboxItemsForBriefing_ExcludesArchived(t *testing.T) {
	d := openTestDB(t)
	now := time.Now().UTC().Format(time.RFC3339)
	insert := func(snippet string, archivedAt any) {
		_, err := d.Exec(`INSERT INTO inbox_items (channel_id, message_ts, trigger_type, snippet, status, priority, item_class, created_at, updated_at, archived_at)
			VALUES ('1:C1', ?, 'mention', ?, 'pending', 'high', 'actionable', ?, ?, ?)`, snippet, snippet, now, now, archivedAt)
		require.NoError(t, err)
	}
	insert("live", nil)
	insert("archived", now)

	items, err := d.GetInboxItemsForBriefing()
	require.NoError(t, err)
	require.Len(t, items, 1)
	require.Equal(t, "live", items[0].Snippet)
}
```
(Match the real NOT NULL column set of `inbox_items` in `schema.sql`; `message_ts` doubles as a unique key here.)

- [ ] **Step 2: Run it to verify it fails**

Run: `go test ./internal/db -run TestGetInboxItemsForBriefing_ExcludesArchived`
Expected: FAIL — 2 items returned.

- [ ] **Step 3: Add the predicate**

In `GetInboxItemsForBriefing` change `WHERE status = 'pending'` to `WHERE status = 'pending' AND archived_at IS NULL`.

- [ ] **Step 4: Run the tests**

Run: `go test ./internal/db -run 'Briefing|Inbox' && go test ./internal/briefing`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/db/inbox.go internal/db/inbox_test.go
git commit -m "fix(db): briefing inbox section skips archived items

GetInboxItemsForBriefing filtered on status only, so actionable rows that
ArchiveStaleActionable had retired 14+ days ago still made the briefing's
top-20 (wave 2 fixed the same hole in GetInboxItems)."
```

---

### Task 9: Inventory, CLAUDE.md, app guide

Spec §8. Docs only; English; no contract is "relaxed" — retired contracts get a dated changelog entry naming the spec.

**Files:**
- Modify: `docs/inventory/inbox-pulse.md`, `docs/inventory/dashboard.md`, `docs/inventory/memory.md`, `docs/inventory/agent-actions.md`, `docs/inventory/dev-surface.md`, `docs/inventory/reaction-commands.md`, `docs/inventory/catchup.md`, `docs/inventory/features.md`, `docs/inventory/README.md`, `CLAUDE.md`, `docs/app-guide.md`, `docs/audit/2026-09-13-feature-audit/README.md` (decision 3 row → "Decided 2026-09-14, see spec")

- [ ] **Step 1: `inbox-pulse.md`**

Add a `## 2026-09-14 — Inbox demolition` changelog entry at the top of the changelog section linking the spec. Mark INBOX-01, INBOX-03, INBOX-04, INBOX-06, INBOX-07 as **Retired (2026-09-14)** with one line each ("triage removed", "stream surfacing removed", "implicit learner removed", "no implicit writer remains", "no AI stage remains"); do not delete their sections — keep the historical text under a "Retired" heading like INBOX-08's. Reword INBOX-09 to "a detector error never advances `inbox_last_processed_ts`" (drop the triage-progress sentences). Reword INBOX-05 to: the Learned tab on the action strip is the visible, editable store of `inbox_learned_rules`, which the digest, tracks, briefing and catch-up pipelines consume via `ListLearnedRulesByPipeline` and `catchup feedback` writes. INBOX-02 unchanged.

- [ ] **Step 2: `dashboard.md`**

Replace the body with a tombstone: title, one paragraph ("Retired 2026-09-14 by the inbox demolition — the situations composer, situation cards, feed publisher and the Dashboard view were removed; `situations`/`situation_signals` remain as read-only history"), and the DASH-01..07 ids each with a one-line "what it protected" for the historical record. Point at the spec.

- [ ] **Step 3: the others**

- `memory.md`: MEM-05 — memory reads no inbox table any more (situations only through the frozen `ConvertedSituationIDs`/`situationSubjects` readers); MEM-10 — memory sets `memory_dispute_flags`; no surface reads them today. Mark the interaction-ingest / `memory.sources.actions` paragraphs removed with the recorded owner call (re-feed engagement from Catch-Up thumbs, or demolish the rank/scheme/aggregate next). Add `2026-09-14` changelog entry.
- `agent-actions.md`: AGENT-01's tool list drops `list_situations`/`get_situation`.
- `dev-surface.md`: three skills, not four; remove the `whats-changed` rows.
- `reaction-commands.md`: where STRIP-01..03 say the strip "replaced" the situations Dashboard, say the Dashboard was removed on 2026-09-14 (spec link).
- `catchup.md`: note that `needs_you` sees trigger rows only (no triage-minted `stream` rows since 2026-09-14).
- `features.md`: the "disabling never deletes situations" line stays; add that `feed`/`dashboard` entries were removed and `secretary-inbox` is `CostNone`.
- `README.md`: module table — `dashboard.md` row marked retired.
- `docs/audit/2026-09-13-feature-audit/README.md`: decision 3 row → "**Decided 2026-09-14** — inbox becomes Catch-Up's silent feeder; see `docs/superpowers/specs/2026-09-14-inbox-demolition-design.md`."

- [ ] **Step 4: `CLAUDE.md` and `docs/app-guide.md`**

Replace the whole "### Assistant Inbox + Dashboard (v73+ …)" section of `CLAUDE.md` with:

```markdown
### Attention detection — the inbox feeder (2026-09-14, replaces the Assistant Inbox + Dashboard)
- `internal/inbox/` is a **mechanical** pipeline with zero AI calls: `Pipeline.Run` = dedup → detectors (Slack mentions/DMs/thread replies/reaction requests per enabled account, Jira, Calendar, Gmail, IMAP, `briefing_ready`) → rule-based auto-resolve (INBOX-02: answering in the source resolves the item) → archive/unsnooze → watermark (INBOX-09: a detector error freezes `inbox_last_processed_ts`). Daemon phase `phaseInbox`, gated `inbox.enabled` (feature `secretary-inbox`, "Attention detection", `CostNone`).
- `inbox_items` has **no screen of its own**. Its readers are Catch-Up (`needs_you`), the daily briefing, meeting prep (attendee context), custom tracks (scan material) and the Slack reaction sync. The sidebar "Inbox" tab is the action strip (agent proposals + due reminders) with the Learned (cross-pipeline `inbox_learned_rules`) and Profile (`workspace.secretary_profile`) tabs — see Reaction Commands Wave 2.
- Retired on 2026-09-14 (spec `docs/superpowers/specs/2026-09-14-inbox-demolition-design.md`): stream triage, the implicit learner, the situations composer + situation cards, per-item/situation feedback, the feed publisher, `phaseFastInbox`, the Dashboard/`InboxFeedView` Desktop code, `list_situations`/`get_situation` and the `whats-changed` dev-pack skill. `situations`/`situation_signals` are frozen read-only history (migration 00070). `watchtower profile style-sample` (was `inbox style-sample`) still generates `workspace.style_profile` for meeting follow-ups.
- Contracts: `docs/inventory/inbox-pulse.md` (INBOX-02/05/09 live; 01/03/04/06/07 retired), `docs/inventory/dashboard.md` (tombstone).
```

Also in `CLAUDE.md`: in the Reaction Commands Wave 2 bullet, replace the `inbox.situations.enabled` paragraph with "The situations pipeline was removed on 2026-09-14 (see Attention detection)". In the Memory section, delete the `memory.sources.actions` / `memory.surfaces.disputes` sentences and the "situations ingest" step from the `Run` order, replacing them with one sentence pointing at the spec. In `docs/app-guide.md` remove the Dashboard walkthrough and describe the Inbox tab as the action strip.

- [ ] **Step 5: Commit**

```bash
git add docs CLAUDE.md
git commit -m "docs: retire the Inbox/Dashboard contracts and describe the attention-detection feeder

INBOX-01/03/04/06/07 and DASH-01..07 are retired with a dated changelog
entry; INBOX-05 becomes the cross-pipeline learned-rules contract; MEM-05/10
reworded for the removed readers; CLAUDE.md and the app guide describe the
inbox as Catch-Up's mechanical feeder."
```

---

### PR 1 gate (before opening the PR)

- [ ] `make test` (full Go) — green.
- [ ] `make lint-all` — green (the god-files hub guard and the sentrux complexity gate must not regress; deleting code only lowers both).
- [ ] `go test ./internal/digest -run TestTierForSource` — the property scan's floors hold.
- [ ] Open PR 1 `feature/inbox-demolition` → `main`, title "Inbox demolition (1/2): Go pipeline cut, migration 00070, docs", body linking the spec and listing the retired contracts; run `local-review` on it.

---

## PR 2 — Desktop

Branch: `feature/inbox-demolition-desktop` stacked on `feature/inbox-demolition` (or the same branch after PR 1 merges — controller's call at execution time; the task content is identical).

### Task 10: Delete the dead Inbox/Dashboard UI and view models

Spec §7. Everything below is reachable only through `InboxFeedView`, which has zero call sites.

**Files:**
- Delete: `WatchtowerDesktop/Sources/Views/Inbox/InboxFeedView.swift`, `InboxCardView.swift`, `InboxFeedbackSheet.swift`; `WatchtowerDesktop/Sources/Views/Dashboard/` (whole directory: `DashboardView.swift`, `FeedRow.swift`, `FeedFilterBar.swift`, `FeedDetailPanes.swift`, `SituationRow.swift`, `SituationReviewPane.swift`, `SituationDiscussSection.swift`); `WatchtowerDesktop/Sources/ViewModels/InboxViewModel.swift`, `DashboardViewModel.swift`, `FeedViewModel.swift`, `SituationChatViewModel.swift`; `WatchtowerDesktop/Sources/WatchtowerCore/Services/DashboardGenerateService.swift`; tests `Tests/InboxTests.swift`, `InboxViewModelTests.swift`, `DashboardViewModelTests.swift`, `FeedViewModelTests.swift`, `SituationChatPromptTests.swift`, `SituationChatMemoryPromptTests.swift`, `SituationChatViewModelTests.swift` (exact names — `ls WatchtowerDesktop/Tests | grep -i 'inbox\|dashboard\|feed\|situationchat'`)
- Modify: `WatchtowerDesktop/Sources/App/AppState.swift` (:148, :152 stored properties; :672, :675 construction; any `dashboardViewModel`/`feedViewModel` references), `WatchtowerDesktop/Sources/Services/TargetPrefillBuilder.swift` (delete `fromSituation` :122-… and `fromInbox` :166-…; keep `fromTrack`/`fromBriefingItem`/`fromSubItem`), `Tests/TargetPrefillBuilderTests.swift` (delete the two cases)

- [ ] **Step 1: Delete**

```bash
cd WatchtowerDesktop
git rm Sources/Views/Inbox/InboxFeedView.swift Sources/Views/Inbox/InboxCardView.swift Sources/Views/Inbox/InboxFeedbackSheet.swift
git rm -r Sources/Views/Dashboard
git rm Sources/ViewModels/InboxViewModel.swift Sources/ViewModels/DashboardViewModel.swift Sources/ViewModels/FeedViewModel.swift Sources/ViewModels/SituationChatViewModel.swift Sources/WatchtowerCore/Services/DashboardGenerateService.swift
# tests: use the names ls shows
```

- [ ] **Step 2: Build and fix**

Run: `cd WatchtowerDesktop && swift build 2>&1 | grep -E 'error:' | head -30`
Fix `AppState.swift` and `TargetPrefillBuilder.swift`; anything else the compiler names that is *only* reachable from the deleted files is deleted too (e.g. a `SituationDiscussInputBar` helper, `SnoozeDates` stays — `SnoozeDates.swift` is used by the strip's reminders Snooze; verify with grep before touching).

- [ ] **Step 3: Targeted tests**

Run: `make test-swift FILTER=TargetPrefillBuilderTests` and `make test-swift FILTER=AppStateTests` (if such a class exists).
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add -A WatchtowerDesktop/Sources WatchtowerDesktop/Tests
git commit -m "refactor(desktop): delete the Dashboard/InboxFeedView code

InboxFeedView has had no call site since Wave 2 routed .inbox to
ActionStripView; everything only it reached — the situations Dashboard, the
feed timeline, per-item inbox cards and feedback, the situation Discuss chat —
is removed. ActionStripView with its Learned and Profile tabs is untouched."
```

---

### Task 11: Trim the Core queries and sidebar counts

Spec §7.

**Files:**
- Delete: `WatchtowerDesktop/Sources/Database/Queries/FeedItemQueries.swift`, `Sources/Models/FeedItem.swift`, `Sources/WatchtowerCore/Database/Queries/InboxFeedbackQueries.swift`, `Sources/WatchtowerCore/Models/InboxFeedback.swift`, tests `Tests/FeedItemQueriesTests.swift`, `Tests/Core/InboxFeedbackQueriesTests.swift` (if present)
- Modify: `Sources/ViewModels/SidebarCountsViewModel.swift` (delete `inboxPendingCount` :19, `inboxHighPriorityCount` :20, `situationsCount` :22, their loaders at :150-163/:186/:202-218, and `"inbox_items"`, `"situations"` from the observation table list at :82 — keep `inboxStripCount` and its `AgentActionQueries.awaitingOwnerCount` + `ReminderQueries.dueCount` sources), `Sources/Views/Sidebar/SidebarView.swift:64` (the `situationsCount` read), `Sources/WatchtowerCore/Database/Queries/SituationQueries.swift` (keep only what still compiles as used — expected: `fetchByID` if `TargetPrefillBuilder` or a history renderer still needs it, otherwise delete the file and `Models/Situation.swift`; the deciding grep is `grep -rn "SituationQueries\.\|: Situation\b" Sources`), `Sources/WatchtowerCore/Database/Queries/InboxQueries.swift` (delete `resolve`/`dismiss`/`snooze`/`markSeen`/`markRead`/`fetchCounts` if their only caller was `InboxViewModel`; keep `fetchByID` — `CatchUpViewModel.swift:419` uses it), tests `Tests/SidebarCountsViewModelTests.swift`, `Tests/Core/InboxQueriesTests.swift`, `Tests/Core/SituationQueriesTests.swift`, `Tests/Core/SituationTests.swift`, `Tests/Core/InboxItemTests.swift` (keep the model tests)

- [ ] **Step 1: Write the failing sidebar test**

In `Tests/SidebarCountsViewModelTests.swift` add (adapting to the class's fixture helpers):

```swift
func testInboxBadgeCountsStripOnly() throws {
    // one pending agent action + one due reminder + an open situation + a pending inbox item
    try db.write { d in
        try d.execute(sql: "INSERT INTO agent_actions (tool, status, args_json, created_at) VALUES ('create_target','pending','{}', '2026-09-01T00:00:00Z')")
        try d.execute(sql: "INSERT INTO reminders (account_id, message_ref, note, remind_at, status) VALUES (0,'1:C@1','n','2000-01-01T00:00:00Z','pending')")
        try d.execute(sql: "INSERT INTO situations (title, status, created_at, updated_at) VALUES ('s','open','2026-09-01T00:00:00Z','2026-09-01T00:00:00Z')")
    }
    let vm = SidebarCountsViewModel(dbPool: db)
    vm.refresh()
    XCTAssertEqual(vm.inboxStripCount, 2)
}
```
(Match the real NOT NULL columns in `TestDatabase+Schema.swift`; the point is that situations and inbox items contribute nothing.)

- [ ] **Step 2: Run it**

Run: `make test-swift FILTER=SidebarCountsViewModelTests`
Expected: compiles and passes already if `inboxStripCount` is untouched — that is fine; it now pins the badge while the other fields are removed.

- [ ] **Step 3: Delete and trim**

Apply the deletions/edits in **Files**. `swift build` names anything missed.

- [ ] **Step 4: Tests**

Run: `make test-swift FILTER=SidebarCountsViewModelTests`, `make test-swift FILTER=InboxQueriesTests`, `make test-swift FILTER=CatchUpQueriesTests`, `make test-swift FILTER=TrackEventQueriesTests`, `make test-swift FILTER=TargetQueriesStatusCascadeTests`, `make test-swift FILTER=DatabaseManagerTests`.
Expected: PASS. Log each run to a file and check `$?` explicitly (a `tail`-piped run hides XCTest failures).

- [ ] **Step 5: Commit**

```bash
git add -A WatchtowerDesktop/Sources WatchtowerDesktop/Tests
git commit -m "refactor(desktop): drop the feed/feedback queries and the dead sidebar counts

FeedItemQueries and InboxFeedbackQueries read tables migration 00070 drops;
SidebarCountsViewModel keeps only inboxStripCount (proposals + due
reminders), which is the one number the Inbox badge shows."
```

---

### Task 12: Desktop gate

- [ ] `cd WatchtowerDesktop && swift build -c debug` — clean.
- [ ] `make test-swift` (full, this once) — green; record the exit code explicitly.
- [ ] `make lint-all` — green.
- [ ] Launch `make app-dev` once and click through: Inbox tab shows the strip with Actions / Learned / Profile segments; Settings → Features shows "Attention detection" with no cost badge and no sub-toggle, and no Dashboard/Feed rows; Catch-Up tab still opens. (Manual smoke — no XCUITest exists for these.)
- [ ] Open PR 2 "Inbox demolition (2/2): Desktop dead-code removal"; run `local-review`.

---

## Self-review notes (done while writing)

- Spec §3.1–3.6 → Tasks 2, 3; §3.4 bug → Task 8; §4 → Task 7; §5.1 → Task 4; §5.2/5.3 → Task 5; §6 → Task 6; §7 → Tasks 10–11; §8 → Task 9; §9/§10 → gates. No spec section is unowned.
- Type/name consistency: `decideWatermark(detectErr error)` in Task 2 matches its only caller (`Run`), `detectAll` loses `includeWatchtower` in Task 2 and no later task passes it. `inboxStripCount` is the only sidebar field referenced after Task 11.
- Ordering: Tasks 5 and 6 both touch config fields; either order compiles only once both are done — run `go build ./...` after each, expect a transient failure between them only if a `cfg.Memory.Sources.Actions` read is deleted before its field (Task 5 removes the read, Task 6 the field — that order is clean).
