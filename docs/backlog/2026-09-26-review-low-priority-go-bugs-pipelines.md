---
type: chore
title: "Low-priority findings bundle — bugs (Go AI pipelines/tools)"
status: open
priority: low
tags: [go-bugs-pipelines, review-2026-09-26, bundle]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go AI pipelines/tools)
created: 2026-09-26
---

17 low-priority findings from the bugs (Go AI pipelines/tools) track, bundled so the backlog
stays readable. Split any item into its own file when it gets picked up.

Still open after fix/go-low-priority-bundle (each item says why): reaction compose retry cap
(REACT-03 owner note), RunWeeklyTrends (wire or delete), the Slack half of the episode-count cap
(MEM-04 owner call), the Gmail stall-retry cursor, the WriteNodes partial-write rollback, shutdown
during an extraction call (step-level rule), retired shipped skills (inventory wording), and the
codex MCP config question (live smoke).

## Reaction compose: every generator error is "transient", with no retry cap

- type: idea · confidence: med · tags: [reactioncmd, budget, retry]
- where: internal/reactioncmd/pipeline.go:385-409 (plus :321-327)

`compose` returns `transient=true` for any `Generate` error, so `dispatchOne` releases the provisional row and retries on the next poll. The feature now polls every cycle. A deterministic generator failure on one message (for example a provider rejecting that input, or a CLI that errors on it every time) therefore costs one AI call every cycle forever. The only visibility is a log line; there is no ledger status or strip card. Suggest a small per-key attempt counter (or an age limit) after which the row is finalized as `failed` with the last error. REACT-03's retry semantics would need an owner note.

Left open (fix/go-low-priority-bundle): still present (`compose` returns `transient=true` for every
`Generate` error). A per-key attempt cap changes REACT-03's retry semantics, which needs the owner's
note first.

## Briefing stores model-emitted track/target/digest ids unvalidated; the Desktop navigates on them (fixed in fix/bl-ai-output-validation)

- type: bug · confidence: high · tags: [briefing, ai-validation]
- where: internal/briefing/pipeline.go:212-222 (plus WatchtowerDesktop/Sources/Views/Briefings/BriefingDetailView.swift:323, 394)

`parseBriefingResult` output is marshalled straight into the briefing columns. `YourDayItem.TrackID/TargetID`, `WhatHappenedItem.DigestID` and `AttentionItem.SourceType/SourceID` are never checked against the ids that `gatherTargets`/`gatherTracks`/`gatherDigests` actually rendered. The Desktop turns them into navigation links, so an invented id either opens nothing or opens an unrelated row. The day plan already does this validation (`validateSource` against `targetsIDSet`/`jiraKeySet`), and so does Catch-Up (CATCHUP-04). Fix: collect the rendered id sets while gathering, and blank unknown ids while keeping the item (the `blankInventedMessageRefs` disposition). Minor, in the same file: `gatherTracks` byte-slices `t.Context[:200]` and `participants[:150]`, which can split a Cyrillic rune in the prompt. This affects the prompt only.

Resolution: `RunForDate` records every target/track/digest/inbox/people-card id its gather functions render (`shownIDs`, internal/briefing/validate.go) and, before storing, blanks any `your_day` track/target id, `what_happened` digest id or `attention` source_id the prompt never showed, keeping the item; a people source_id is resolved to the shown namespaced id when the model echoes a unique raw form. Pinned by `TestRunForDate_BlanksIDsThePromptNeverShowed` and `TestShownIDs_ResolvePerson`. The byte-slice nit (`Context[:200]`) is left to the separate UTF-8 truncation item.

## Day plan: persistence is not atomic and an empty or partial plan sticks for the whole day (fixed in fix/bl-window-timing)

- type: bug · confidence: med · tags: [dayplan, atomicity, stuck-state]
- where: internal/dayplan/pipeline.go:175-196, 59-65

The comment says "persist atomically", but `UpsertDayPlan`, `ReplaceAIItems`, `syncCalendarItems` and `IncrementRegenerateCount` are separate writes. If `ReplaceAIItems` or `syncCalendarItems` fails after a first-time upsert, a plan row with no AI items remains. The next daemon cycle hits the `existing != nil && !Force` short-circuit and never regenerates it that day, and the attempt budget is never charged because the next call "succeeds". The same happens when `buildItems` drops every AI item: an empty plan is persisted as `active` with no retry. Fix: do the plan upsert and item replace in one transaction, and treat zero surviving AI items as a failed attempt rather than a finished plan.

Resolution: `Pipeline.Run` now drops a freshly created plan row when its item writes (`ReplaceAIItems`/`syncCalendarItems`) fail, so the next run regenerates instead of short-circuiting on it (an existing plan is never dropped); the row cascade-deletes its items (new `db.DeleteDayPlan`). A compensating delete rather than one transaction, because the item writers each run on the pool. A response whose every item fails validation now returns an error before anything is persisted (a charged, retried attempt) when any drop was a real validation failure (unknown source, bad times — even on a meeting day) or when the day has nothing else to show (no timed meeting, no manual item); a meeting-heavy day whose proposals only restated or collided with the calendar is kept as a calendar-only plan (`buildItems` now reports how many drops were real validation failures); a real validation failure overrides both exemptions, so a model that keeps inventing a key on a meeting day ends the day with no plan after the daemon's 3 attempts (an existing plan is never touched), and a model that proposes nothing is still an honest empty plan. A failed `IncrementRegenerateCount` is logged instead of discarded. Pinned by `TestRun_PartialPersistFailureLeavesNoFreshPlan` (SQLite-trigger failure injection) `TestRun_AllItemsDroppedIsAFailedAttempt` `TestRun_AllItemsDroppedOnMeetingDayKeepsCalendarPlan` and `TestRun_AllItemsInvalidOnMeetingDayIsAFailedAttempt`.

## RunWeeklyTrends is dead code

- type: chore · confidence: high · tags: [digest, dead-code]
- where: internal/digest/pipeline.go:1458-1528 (plus the stale "daily/weekly" comment at :418)

No caller exists in `cmd/` or `internal/`. `RunRollups` runs only the daily rollup, even though its doc says "daily/weekly". Weekly digests are therefore never produced, while the `digest.weekly` prompt, its Settings entry and the weekly type in the Desktop remain. It also has its own date bug: `weekStartNorm` takes a local date's Y/M/D and stamps it UTC. Either wire it into the rollup phase with a once-per-week gate, or delete it along with the prompt row.

Left open (fix/go-low-priority-bundle): still dead (only its own test calls it). Wiring weekly
digests in or deleting them together with the `digest.weekly` prompt, its Settings entry and the
Desktop weekly type is a product decision for the owner.

## Custom-track watermark is taken after the activity read: same-second rows are skipped

- type: bug · confidence: med · tags: [customtracks, watermark, same-second]
- where: internal/customtracks/pipeline.go:152-181 (plus internal/db/track_events.go:220, 243, 266)

`runOne` reads activity with `created_at > since` / `updated_at > since` and then sets `now := time.Now()` as the next watermark. The timestamps have second granularity, so a digest, track update or inbox item written after the read in the same second as `now` falls at `== now`. The next run's strict `>` never returns it. The window is narrow in the daemon, but a Desktop "Refresh" that runs concurrently with the digest phase makes it reachable. Fix: capture the watermark before the read (as `CappedAt` already does for the capped path) and accept the harmless overlap, since summary dedup already absorbs it.

Resolution (fix/go-low-priority-bundle): `GetScanActivity` takes an inclusive upper bound; `runOne`
reads activity up to the last fully elapsed second (now - 1s, taken before the read) and makes that
its watermark, so a row written later in the still-running second is read by the next run rather
than skipped. An upper bound instead of an overlapping re-read, so a row is never fed to the model
twice. Pinned by `TestScanWatermarkDoesNotSkipRowsWrittenInTheReadSecond` and
`TestGetScanActivity_UntilIsInclusive`; `seedActivity` in the budget tests now stamps its row in an
elapsed second. Residual: a row stamped earlier but committed after the read (a writer transaction
held open over a second) can still be missed.

## Link suggestion can make a target its own parent or create a cycle (fixed in fix/bl-ai-output-validation)

- type: bug · confidence: med · tags: [targets, ai-validation, hierarchy]
- where: internal/targets/linker.go:76-87 (plus internal/targets/pipeline.go:145-172, cmd/targets_ai.go:336-345)

`parseLinkResponse` accepts any `parent_id` that is in the active snapshot. That snapshot includes the target itself (only the prompt rendering skips it, and the prompt header still prints `target.ID`) and all of its descendants. A reply echoing the target's own id, or picking one of its children (the link prompt shows no parent info, so the model can't tell), becomes a confirmed self-parent or cycle through `UpdateTarget`. `UpdateTarget` has no cycle check; only `recomputeParentProgressOn` detects cycles, and it just logs. Fix: exclude the target and its descendant set when validating `parent_id` and secondary `target_id`.

Resolution: `LinkExisting` computes `forbiddenParentIDs` (internal/targets/linker.go) — the target plus every snapshot target whose ancestor chain reaches it, walking through ancestors outside the snapshot via the DB, bounded at 20 levels — and `parseLinkResponse` drops a proposed `parent_id` in that set like an unknown id. A secondary link to the target itself is dropped too; a secondary link to a descendant is kept, since links are not hierarchy and cannot form a cycle. Pinned by `TestLinkExisting_RejectsSelfAndDescendantParents` and the `TestForbiddenParentIDs_*` tests (internal/targets/linker_cycle_test.go).

## Inbox item context is byte-truncated before being persisted (fixed in fix/bl-inbox-triggers)

- type: bug · confidence: high · tags: [inbox, utf8, persisted]
- where: internal/inbox/pipeline.go:596-604

`loadContext` cuts each line with `line[:200]` and the whole block with `result[:2000]`. For Cyrillic text this regularly splits a 2-byte rune, and the invalid UTF-8 is written into `inbox_items.context`, which Catch-Up, the briefing and meeting prep all read. The same file already has `truncateRunes` for the snippet. Fix: use it here too.

Resolution: `loadContext` now caps each line and the whole block with `truncateRunes` (200 and 2000 runes) instead of byte slices, so the persisted context is always valid UTF-8. Pinned by `TestLoadContext_TruncatesByRunesNotBytes` (Cyrillic at odd byte offsets), `TestLoadContext_BlockCapCountsRunes` (the 2000-rune block cap crossed with multi-byte text) and `TestLoadContext_ShortLinesUntouched` (within-cap text stays verbatim).

## Episode-count caps silently drop overflow episodes while the batch is marked done

- type: bug · confidence: med · tags: [memory, ai-output-validation, watermark, cap]
- where: internal/memory/pipeline.go:869-872, internal/memory/gmail_extract.go:378-380

Both extractors truncate the model reply before validation. Slack uses `eps[:MaxEpisodesPerWindow*len(idxs)]` and Gmail uses `eps[:len(batch)]`. The batch still succeeds, so every window's messages count as consumed and the watermark advances. Gmail makes this likely: `buildGmailEpisodeNodes` explicitly supports several episodes for one thread (the `threadNodeIdx` union path). But if the model emits two episodes for thread 1 in a 3-thread batch, the last thread's episode is cut and that thread's mail is never extracted. Fix: when the reply exceeds the cap, fail the batch (degenerate reply, the MEM-04 preference). Or, for Gmail, fold same-thread episodes before applying the cap, and cap per thread instead of by list position.

Partly resolved (fix/go-low-priority-bundle): the Gmail half is fixed — the positional
`eps[:len(batch)]` cut is gone; every episode must still ref a thread of the batch and
`buildGmailEpisodeNodes` folds same-thread episodes into one node, so nodes stay bounded by the
batch. Pinned by `TestGmailExtract_ExtraEpisodeForOneThreadKeepsTheOthers`. Left open: the Slack
`MaxEpisodesPerWindow*len(idxs)` cut. Failing the batch on overflow (the MEM-04 preference) would
send a consistently verbose model's windows into the attempt budget and quarantine, so MEM-04's
handling of an over-cap reply needs an owner call.

## Gmail sync's stall-retry re-delivers messages below the memory Gmail watermark, and they are never extracted

- type: bug · confidence: med · tags: [memory, gmail, watermark, late-arrival]
- where: internal/gmail/sync.go:100-150, internal/memory/gmail_extract.go (runGmailExtractAccount), internal/db/memory.go:1498-1516

Gmail sync processes oldest-first. When one message fails to fetch or upsert (`stalled = true`), sync still stores the newer messages but keeps its own watermark behind the gap, and retries the gap next cycle. The memory Gmail watermark is based on `internal_date`. If a memory run falls between the two sync cycles, it extracts the newer messages and moves `memory_gmail_last_extracted_ts` past the gap. The retried message then lands with an older `internal_date` and fails the strict `> wm` filter forever. This is a concrete, guaranteed-by-design instance of audit M4 (which named only Slack `ts_unix`), in a source that deliberately re-delivers old rows. Fix: key the memory Gmail cursor on `synced_at`/rowid, or re-scan a bounded lookback the way the calendar builder does.

Left open (fix/go-low-priority-bundle): needs a cursor design (a `synced_at`/rowid cursor or a
bounded lookback with alias idempotency) inside MEM-04 — larger than a low-priority patch.

## A failed WriteNodes leaves a partial multi-node write that the next run commits as an owner edit (tombstones without their rollup)

- type: bug · confidence: med · tags: [memory, vault, git-consistency, MEM-03, MEM-07]
- where: internal/memory/vault.go:530-560, internal/memory/vault.go:593-613, internal/memory/evict.go:176-185, internal/memory/merge.go:62-67

`WriteNodes` writes and stages files one at a time and commits only at the end. On an **error return** (ENOSPC, a staging failure, a commit failure), it leaves the files written so far dirty in the worktree, not just after a kill. The next run's `CommitOwnerEdits` sweeps them into `memory(owner-edit)`. The inventory already records this kill-window mislabel (line ~305). What it misses is that the partial state is also *inconsistent*. `EvictEpisodes` writes all tombstones before the rollups, so a failure partway through commits tombstones that redirect to a rollup that does not exist: the episode bodies and gists are lost from the live vault (MEM-07). The same happens with `Merge` (stub written, winner not), which drops the loser's aliases. The owner-touch bonus then also protects this debris from eviction. Fix: on a WriteNodes error, restore the paths it touched (`git checkout`/reset of exactly those paths) before returning. Also consider writing rollups/winners before tombstones.

Left open (fix/go-low-priority-bundle): rolling back a partial write means restoring both the
worktree files and go-git's index entries for exactly the touched paths (MEM-03's "touch only what
you wrote"), plus reordering the evict/merge writes — a vault-layer design change, not a small fix.

## Calendar builder can wedge if more than max_chunk_messages events end inside its 2-day lookback

- type: bug · confidence: med · tags: [memory, calendar, watermark, cap]
- where: internal/db/memory.go:1264-1280, internal/memory/calendar_ingest.go:86-115

`ListCalendarEventsForExtract` loads events with `end > wm - 2d`, oldest first, `LIMIT max_chunk_messages` (a Slack-message knob reused here). Suppose at least that many events end in `[wm-2d, wm]`, for example because an owner lowered `max_chunk_messages` to throttle extraction, or on shared or resource calendars. Then every run loads the same already-processed events, `maxEnd <= wm`, and the watermark never advances. Newer events are never built, and the ~24 h sync retention deletes them first. Fix: start the LIMITed scan at `wm` and run the lookback refresh as a separate, bounded query, or use a dedicated cap.

Resolution (fix/go-low-priority-bundle): `ListCalendarEventsForExtract` now caps the lookback slice
(end in (wm - lookback, wm]) and the past-watermark slice (end in (wm, now)) separately, so a full
lookback can no longer crowd out the new events and wedge the watermark. A full lookback keeps the
events nearest the watermark (likeliest to get a late recap), and a full past-watermark slice drains
every event tied at its last end second, since the watermark moves to that second. The inventory's
bounded lookback re-scan is unchanged. Pinned by
`TestListCalendarEventsForExtract_FullLookbackDoesNotWedge` and
`TestListCalendarEventsForExtract_FullNewSliceDrainsBoundaryTies`.

## Shutdown during an extraction AI call is recorded as a failed batch

- type: bug · confidence: high · tags: [memory, ctx-cancellation, observability]
- where: internal/memory/pipeline.go:600-620, internal/memory/gmail_extract.go (runGmailExtractAccount batch loop)

`runExtract` checks `ctx.Err()` only between batches. If SIGTERM arrives while `Generate` is running, `werr` is the killed subprocess, so the batch gets a `pipeline_steps` row with status `error`, `WindowsFailed += len(idxs)`, and an "extract batch … signal: killed" log line. That contradicts the house rule "a cancelled ctx is never recorded as an error", which `rewrite`/`reflect` honour via `cancelledCall`. Harmless to data (the watermark correctly holds), but it produces false error rows in Pipeline Progress on every daemon stop. Fix: when `werr != nil && ctx.Err() != nil`, record `skipped`/interrupted and break.

Left open (fix/go-low-priority-bundle): still present. The house precedent at step level is
mixed: `TestPipeline_CancelledCtxSkipsPostBeliefSteps` pins the interrupted rewrite step's row as
`error` ("the interrupted step reports the cancellation"), while the run-level rule keeps a
cancellation out of `pipeline_runs`. Making extraction alone record `skipped` would split the two
steps; pick one step-level rule for both first.

## Retired shipped skills are orphaned: never reported, never removed, still served

- type: bug · confidence: high · tags: [devpack, skills, dev-surface, dev-04, docs-drift]
- where: internal/devpack/install.go:140-159, internal/devpack/install.go:171-214, internal/skills/deploy.go:50-102, docs/inventory/dev-surface.md:219

`Status` and `Remove` iterate only the current embedded `Skills()`, so a skill that has left the pack is invisible to both. The inventory entry for the 2026-09-14 removal of `watchtower-whats-changed` says "`integrate status` reports it, `integrate remove` deletes only marker-carrying files". That is false: an install from before 2026-09-14 keeps `watchtower-whats-changed/SKILL.md` (with the marker) forever. It tells the developer's agent to call `list_situations`/`get_situation`, which no longer exist, and `integrate remove` leaves it behind. `internal/skills.Deploy` has the same shape for the workspace skills directory: a shipped skill later dropped from `shipped/` stays deployed, and the catalog lists it on every chat surface. Fix: keep a small list of retired names, or scan skill dirs for the marker plus a digest recorded in the sidecar, then report them as `retired` and delete them on `remove`/`install` when they are unmodified. Also correct the inventory sentence.

Left open (fix/go-low-priority-bundle): still present (`Status`/`Remove` iterate only `Skills()`).
The fix has to correct the inventory sentence in `docs/inventory/dev-surface.md` as well, which this
bundle does not touch without the owner.

## Name lookups use unescaped LIKE, so _/% in the query act as wildcards

- type: bug · confidence: high · tags: [tools, sql-like, people]
- where: internal/tools/messages.go:99, internal/tools/people_read.go:84, internal/tools/ideas.go:56 (backed by internal/db/users.go:81, internal/db/ideas.go:232)

`list_messages.person`, `get_person` and `list_ideas.query` feed model or user text into `"%" + q + "%"` with no `ESCAPE`. Slack usernames commonly contain `_` (`john_s`), which matches any single character, so `john_s` also matches `johnas`. `list_messages` then silently widens the author set, and `get_person` reports a spurious "ambiguous" error. A query of `%` matches every user (up to the limit of 10). Fix: escape `\ % _` and add `ESCAPE '\'` in the db helpers these tools call.

Resolution (fix/go-low-priority-bundle): `SearchUsersByName` and `ListIdeas`' query now escape the
input through the existing `escapeLike` and add `ESCAPE '\'` on every LIKE, like the targets search.
Pinned by `TestSearchUsersByName_WildcardsMatchLiterally` and
`TestIdeas_ListIdeasQueryWildcardsMatchLiterally`.

## internal/digest compiled prompt fallbacks still diverge from the registered defaults

- type: chore · confidence: high · tags: [prompts, drift, digest]
- where: internal/digest/prompt.go:3,69,127,161,192; internal/digest/pipeline.go:232-255 (getPrompt fallback); internal/prompts/defaults.go

Checked via an overlay test: all five digest consts differ from `prompts.Defaults` — `digest.channel` (4824 vs 5819 bytes, default v5), `digest.channel_batch` (3747 vs 4793, v5), `digest.daily`, `digest.weekly`, `digest.period` (v1 each). Wave 5 wired `SetPromptStore`, so production normally reads the DB row, but `getPrompt` still falls back to these stale consts whenever the store is nil or `GetForRole` returns an error (DB read error, a future constructor that forgets the wiring). That fallback silently drops the `ideas` array (Slack idea mining) and other newer instructions, and every digest unit test that runs without a store exercises the stale template. Targets got the fix-plus-pin treatment (`internal/targets/prompt_store_test.go`); digest did not. Fix: make the fallback `prompts.Defaults[id]` (as tracks/briefing/memory/catchup do) and delete the consts, or pin equality in a test.

Resolution: already fixed in 910bab14 (PR #116, "one prompts.Resolve lookup") — digest's `getPrompt`
resolves through `prompts.Resolve` (store row, else `prompts.Defaults[id]`), `internal/digest/prompt.go`
is gone and `TestDigestPromptFormatVerbs` counts the defaults' verbs.

## Codex chat MCP config relies on a project-local .codex/config.toml in an untrusted temp dir

- type: question · confidence: low · tags: [codex, mcp, chat]
- where: internal/codex/mcp.go:20-47, internal/codex/client.go:96-104

The codex chat client wires the watchtower MCP server by writing `<tmp>/.codex/config.toml` and passing `--cd <tmp>`. Recent codex CLI versions load project-scoped `.codex/config.toml` only for trusted projects (the user-level config lives under `$CODEX_HOME`), and a freshly created temp dir is never trusted. If that holds for the installed codex, the codex chat silently runs with no watchtower tools (and no chat-mode proposal tools) while the prompt advertises them. Could not verify against the codex source from this repo. Suggest a smoke check (`codex exec --json` in such a dir, look for an `mcp_tool_call`), and if confirmed, pass the server via `-c mcp_servers.watchtower.command=…`/`args=…` overrides instead. Minor related nit: `strconv.Quote` emits Go escapes (`\x..`) that are not valid TOML basic-string escapes for control characters in a path.

Left open (fix/go-low-priority-bundle): still a question — answering it needs a live `codex exec`
smoke against the installed CLI, which this bundle did not run.

## Prompt-side byte truncation splits Cyrillic runes across many pipelines

- type: chore · confidence: high · tags: [utf8, prompts, digest, tracks, guide, briefing]
- where: internal/digest/pipeline.go:2109-2110, internal/briefing/pipeline.go:351-359, internal/tracks/pipeline.go:1169,1227, internal/guide/pipeline.go:860, internal/inbox/style_sample.go:114, internal/meeting/pipeline.go:508-512

Many prompt builders cut text with `s[:n]` after a `len(s) > n` check. `config.DefaultMessageTruncateLen` says "(chars)", but the digest `formatMessages` cut is in bytes, so a Cyrillic message is trimmed to about 250 characters and usually ends in half a rune. The same shape appears in `truncate()` in meeting, the tracks/guide/briefing context snippets, and the style-sample lines. These values only go into prompts. The model tolerates U+FFFD, and the persisted case (`inbox_items.context`) is filed separately above. Still, the effective budget for Cyrillic text is half of what was intended. Fix: route these through one shared rune-safe helper (for example `truncateRunes` in the inbox pipeline, or `capBytes` with its rune back-off).

Resolution (fix/go-low-priority-bundle): a shared `internal/textutil.Truncate` (rune-boundary cut,
suffix only when it cut) now backs the digest `formatMessages` cut, the briefing context/participants
snippets, the guide message snippet, the inbox style sample and meeting's `truncate`; the tracks
snippets use that package's existing rune-safe `truncate`. Pinned by `TestTruncate` and
`TestFormatMessages_TruncatesByRunes`. The other per-package rune helpers (`truncateRunes` in
inbox/chat/catchup/…) were already correct and are left as they are.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
