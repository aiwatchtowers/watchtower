# Workchat: agents out of the dialog, live steps, send while working, inline pastes, faster open — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Workchat shows only the dialog; agents live in the 👥 list (Working + Done), the current turn's steps show live above the live line, the button is Send whenever the field has text, pastes go inline as tokens, and the pane opens faster — on the Mac, with the agents part on the phone too.

**Architecture:** Go's `internal/sessionfeed` keeps emitting subagent markers and gains additive keys (`live.steps`, `live.steps_more`, `subagents[].subagent.started_at`) plus `session-feed --tail/--before` paging. The Desktop stops drawing `subagent` entries (`WorkchatFeedAdapter`), builds the 👥 list in the pure `WorkchatLivePresentation` from `SessionFeedStore.subagents` and `live.agents`, draws the steps disclosure from `live.steps`, and keeps one `SessionFeedStore` per session in `WorkbenchesViewModel`. The composer changes ride two `ChatComposerFieldConfig` flags that only Workchat turns on. The phone filters `.subagent` entries out of its drawn feed and builds a sheet from them; the hub slice is untouched.

**Tech Stack:** Go 1.26 (`internal/sessionfeed`, cobra `cmd/`), SwiftUI macOS 14 (`WatchtowerDesktop`, `WatchtowerCore`), shared `WatchtowerChat` (ChatUI) and `WatchtowerChatText`, iOS 17 `WatchtowerMobile`, `os_signpost`.

**Spec:** `docs/superpowers/specs/2026-11-19-workchat-agents-and-progress-design.md`

## Global Constraints

- Go JSON changes are additive only (FEED-03): `TestSessionFeedJSON_PinnedKeys` keeps its exact assertions — the top-level key list of a full read and the entry `subagent` object's five keys (`agent_id`, `description`, `status`, `tool_use_id`, `type`) do not change. New keys: `live.steps`, `live.steps_more`, `before` (printed only with `--tail`, `omitempty`), and `started_at` inside the `subagent` object of **`subagents` list items only**.
- A Go slice that reaches JSON is initialised (`[]LiveAction{}`), never nil (review-rules "Wire shape").
- No `internal/hub`, Kit `SessionChat` or Kit fixture change; FEED-05 (`TestFeed05_*`) stays untouched (D3, C3).
- No inventory guard test is weakened, renamed or split. `WorkchatLivePresentationTests` (listed as a FEED-03 guard) keeps every existing assertion: new parameters get defaults that reproduce today's results.
- All UI copy lives in presentation/model types (`WorkchatLivePresentation`, `WorkchatComposer`/`WorkchatOutgoing` statics, the phone's `WorkchatAgentsText`) and is asserted by tests. Exact strings: `"Agents"`, `"WORKING"` (section caps), `"No agents working"`, `"Agent status unavailable"`, `"Loading agents…"`, `"Couldn’t read the agents"`, `"Retry"`, `"Done · N"`, `"This turn · N steps"` (`"This turn · 1 step"`), `"Queued · the agent reads it at its next step"`, `"Queued · sends when the agent stops ·"`, `"Pasted image #N is gone — paste it again"`, tokens `"[Image #N]"` and `"[Pasted text #N +L lines]"`, phone `"Working"`, `"Running"`, `"Done · N"`, `"✓ N"`.
- Colours only through `Tone` / `Fill` (the dimmed done badge sits on `Fill.rest`); no row separators; Desktop UI from `Sources/DesignKit/`.
- Numbers pinned by the spec: steps cap 40 (`steps_more` counts the cut), steps list fixed at 6 rows, Done shows at most 5 rows then scrolls, tail page 60 entries, poll 3 s (unchanged), targets first paint ≤ 300 ms on reopen and ≤ 500 ms on first open for the ~950-entry session.
- §5 and §6 are Workchat-only: `ChatComposerFieldConfig.sendWhileStreaming` and `.inlinePastes` default `false`; the AI chat is unchanged.
- In-memory only: steps open/closed and Done expanded state per pane, paste payloads with the draft. Nothing new is persisted.
- Inner loop per task (CLAUDE.md "Agent-driven runs"): only the touched package/test classes, `make lint-diff` for Go, `make lint-swift` for Swift (lint-diff never checks Swift). Full gate once per phase by the controller.
- Repo docs in English; no live-install data (session ids, paths, names) in tests, docs or the spec's numbers table — use "small / ~300 / ~950 entries".

## Review Focus

1. **A subagent marker with status `unknown`** (its `meta.json` not written yet, or a Claude Code build without sidecars) is in neither Working nor Done on the Mac or the phone, now that the feed cards are gone — the spec accepts this as the existing v1 limit; Task 4 and Task 9 each pin it with a test so the behaviour is deliberate, and the feature note states it.
2. **`--after` reads see a marker's `started_at` as the meta.json mtime** (the earlier transcript part is not re-parsed), while a full or tail read sees the Agent call's time. The store must keep the first non-nil `startedAt` per id so Done's order does not jump on the next poll — Task 8's `testStartedAtKeepsFirstValueAcrossReads`.
3. **A `--before` id the CLI no longer finds** (an entry id that changed or a conversation that went) must fail loudly, not return an empty page that silently ends paging — Task 3's `TestTailPage_UnknownBeforeIsAnError` and Task 8's `testEarlierPageFailureKeepsEntriesAndPaging`.
4. **Bracket text the owner typed by hand** (`[Image #1]` with no payload): it is plain text — Backspace deletes one character, and it is sent verbatim. Only a token that has a payload in the draft is atomic — Task 7's `testHandTypedTokenIsPlainText`.
5. **Steps when the live snapshot is stale or failed**: the slot must hide rather than freeze a running timer — Task 5's `testStepsSlotHiddenOnStaleOrError`.

## Where the code differs from the spec's wording

- `LiveOf` scans a **4 MiB** tail (`liveWindow = 4 << 20`); 256 KiB is `ActivityOf`'s window. Steps (§3) and Codex Done (C4) are bounded by 4 MiB.
- `TestSessionFeedJSON_PinnedKeys` pins the exact top-level keys and the entry `subagent` object's keys, so `before` is `omitempty` (tail reads only) and `started_at` goes only into the `subagents` list items' `subagent` object (Task 3).
- `SessionFeedStore` merges the `subagents` list into `entries` today; Task 4 keeps them apart (`store.subagents`), which the tail read needs.
- `workchatLineCheck` already returns `.go` for `.background` (`testWorkchatLineCheckMatchesLineCheckExceptWhileWorking`); the "locked" chat is most likely the Stop-only button. Task 6 reproduces per state before changing anything.
- Cancel of a queued line restores nothing today; §6 makes it restore the tokenized draft (Task 7).
- Mockup 08 shows the newest step on the open line; spec §3 says "This turn · N steps". The plan follows the spec.
- The phone's Done can list only markers inside the slice's 300-entry window (FEED-05 cap; no new slice data per D3). This is no loss against today: the phone's feed already holds only those 300 entries, so a card outside the window was never on the phone either. Widening it means changing FEED-05 (a guarded contract) — out of scope; the feature note records the limit.

---

## File structure

| File | Responsibility | Task |
|---|---|---|
| `WatchtowerDesktop/Sources/WatchtowerCore/Services/WorkchatOpenTrace.swift` (new) | signpost intervals + one log line per open with per-phase ms | 1 |
| `WatchtowerDesktop/Tests/Core/WorkchatOpenBenchmarkTests.swift` (new) | Swift-side measurement harness over a saved feed JSON | 1, 10 |
| `internal/sessionfeed/live.go`, `live_steps_test.go` (new) | `Live.Steps`, `Live.StepsMore` | 2 |
| `internal/sessionfeed/entry.go`, `subagent.go`, `feed.go`, `feed_tail_test.go` (new), `subagent_test.go` | `SubagentRef.StartedAt`, `TailPage` | 3 |
| `cmd/workbench_session_feed.go`, `cmd/workbench_session_feed_test.go` | `--tail`, `--before`, `before`, subagents-item `started_at` | 3 |
| `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/WorkchatFeedAdapter.swift` | `subagent` → no message | 4 |
| `WatchtowerDesktop/Sources/WatchtowerCore/Models/SessionFeed.swift` | `SessionFeedSubagent.startedAt` | 4 |
| `WatchtowerDesktop/Sources/WatchtowerCore/Services/SessionFeedStore.swift` | `subagents`, `feedLoaded` (T4); tail/before paging (T8) | 4, 8 |
| `WatchtowerDesktop/Sources/WatchtowerCore/Services/WorkchatLivePresentation.swift` | badge, agents list, Done; steps slot (T5) | 4, 5 |
| `WatchtowerDesktop/Sources/WatchtowerCore/Services/WorkchatPaneMemory.swift` (new) | per-pane in-memory steps-open / Done-open | 4, 5 |
| `WatchtowerDesktop/Sources/Views/Workbench/WorkchatLiveLine.swift`, `WorkchatStepsList.swift` (new) | the line, popover, steps list | 4, 5 |
| `WatchtowerDesktop/Sources/Views/Workbench/SessionChatView.swift`, `SessionChatSubagentView.swift`, `SessionChatRow.swift` | wiring; drop the subagent card | 1, 4, 5, 8 |
| `WatchtowerChat/Sources/ChatUI/Composer/ChatComposerField.swift`, `ComposerButtonMode.swift` (new), `ComposerPasteRoute.swift` (new), `Platform/macOS/ChatComposerTextInput.swift`, `PastingTextView.swift` | Send-while-streaming, ⌥↓ hook, inline paste route | 5, 6, 7 |
| `WatchtowerChatText/Sources/WatchtowerChatText/PasteTokens.swift` (new) | token labels, atomic delete range, expansion | 7 |
| `WatchtowerDesktop/Sources/ViewModels/WorkchatModel.swift`, `Sources/WatchtowerCore/Services/WorkchatOutgoing.swift`, `Views/Workbench/WorkchatComposer.swift` | send/hold captions, tokens, restore, echo | 6, 7 |
| `WatchtowerDesktop/Sources/ViewModels/WorkbenchesViewModel+Panel.swift`, `WorkbenchesViewModel.swift`, `WorkbenchesViewModel+Sessions.swift` | kept-alive store, pane memory | 4, 8 |
| `WatchtowerMobile/Sources/Features/Workbench/WorkchatAgents.swift` (new), `WorkchatAgentsSheet.swift` (new), `WorkchatModel.swift`, `WorkchatView.swift`, `SessionChatView.swift` | phone filter + sheet | 9 |
| `docs/features/session-chat-feed.md`, `docs/features/README.md`, `docs/inventory/session-feed.md`, `docs/guide/features/workbench/workchat.md`, `docs/guide/features/iphone-workbench.md`, the spec | docs, numbers | 2, 3, 10 |

## Lanes

- **Go lane:** Task 2, Task 3 (independent; may run as two lanes).
- **Mac agents lane:** Task 4 → Task 5.
- **Composer lane:** Task 6 → Task 7.
- **Phone lane:** Task 9.
- **Speed:** Task 1 first (baseline), Task 8 after Tasks 1, 3, 4.
- **Close-out:** Task 10 after all.

Expected merge overlaps (resolve by keeping both): `SessionChatView.swift` (Tasks 1, 4, 5, 8), `ChatComposerField.swift` (Tasks 5, 6, 7), `docs/inventory/session-feed.md` changelog (Tasks 2, 3).

---

### Task 1: Open-time signposts and baseline numbers

**Depends on:** none

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/WorkchatOpenTrace.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/SessionFeedStore.swift` (`refresh()`), `WatchtowerDesktop/Sources/Views/Workbench/SessionChatView.swift` (`.onAppear`, the feed's first non-empty paint)
- Test: `WatchtowerDesktop/Tests/Core/WorkchatOpenTraceTests.swift`, `WatchtowerDesktop/Tests/Core/WorkchatOpenBenchmarkTests.swift` (measurement harness, skipped without `WORKCHAT_BENCH_JSON`)
- Modify: the spec's §4 (a "Measured" table)

**Interfaces:**
- Produces: `package enum WorkchatOpenPhase: String, CaseIterable { case appear, spawn, exit, decode, adapter, paint }`; `@MainActor package final class WorkchatOpenTrace { package init(sessionID: Int64, reopen: Bool, clock: @escaping () -> ContinuousClock.Instant = ContinuousClock.now); package func mark(_ phase: WorkchatOpenPhase); package var report: String? }` — the store holds one as `package var openTrace: WorkchatOpenTrace?` set by the pane on appear; signposter subsystem `"com.watchtower.desktop"`, category `"WorkchatOpen"`, one interval per phase named after the case.

- [ ] **Step 1: Write the failing test**

```swift
final class WorkchatOpenTraceTests: XCTestCase {
    @MainActor func testReportListsPhaseGapsInMs() {
        let start = ContinuousClock.now
        var t = start
        let trace = WorkchatOpenTrace(sessionID: 7, reopen: false, clock: { t })
        for (phase, ms) in [(WorkchatOpenPhase.appear, 0), (.spawn, 10), (.exit, 650), (.decode, 690), (.adapter, 700), (.paint, 812)] {
            t = start.advanced(by: .milliseconds(ms))
            trace.mark(phase)
        }
        XCTAssertEqual(trace.report, "workchat open session=7 first total=812ms spawn=10 cli=640 decode=40 adapter=10 paint=112")
    }
    @MainActor func testReportNilUntilPaint() {
        let trace = WorkchatOpenTrace(sessionID: 7, reopen: true)
        trace.mark(.appear); trace.mark(.spawn)
        XCTAssertNil(trace.report)
    }
    @MainActor func testSecondPaintDoesNotReport() // report is produced once per trace; a later .paint leaves it unchanged
}
```

Each figure is the gap since the previous phase; `reopen: true` prints `reopen` instead of `first`.

- [ ] **Step 2: Run** `make test-swift FILTER=WorkchatOpenTraceTests` — FAIL (type missing).
- [ ] **Step 3: Implement `WorkchatOpenTrace`** with `OSSignposter` intervals per phase and `Logger(subsystem:category:).notice("\(report)")` once at `.paint`. Wire: `SessionChatView.onAppear` creates the trace (`reopen` = the store already has entries — after Task 8 that is a kept store; before it, always `false`) and marks `.appear`; `SessionFeedStore.refresh()` marks `.spawn` before `read`, `.exit` after it returns, `.decode` after `Self.decode`; the pane marks `.adapter` after building `workchatFeed.messages` and `.paint` in the feed's `.onAppear` when messages are non-empty (or the empty state's).
- [ ] **Step 4: Run** `make test-swift FILTER=WorkchatOpenTraceTests` — PASS; `make lint-swift` clean.
- [ ] **Step 5: Measure the baseline — never against the live install.** No repo-built app or CLI touches the live `watchtower.db` (it would migrate it ahead of the installed app). (a) CLI share: the **installed** binary (`~/Library/Application Support/Watchtower/bin/watchtower workbench session-feed --session N --json`, read-only) timed 5× per session, median; its JSON saved to the session scratchpad only (never committed — live data). (b) Swift share: `WorkchatOpenBenchmarkTests` (new, in `Tests/Core`, `XCTSkip` unless `WORKCHAT_BENCH_JSON` names a file) runs decode → `SessionFeedStore` apply → `WorkchatFeedAdapter` → an `NSHostingView` layout of the feed over that JSON and prints per-phase ms through `WorkchatOpenTrace`; first open = cold store, reopen = the kept store's path. The numbers are **composite** (installed-CLI median + harness Swift share), not a real pane open; the table says so, and the dev app's own `WorkchatOpenTrace` log line on a DB copy is recorded beside them when available. Add a "Measured" table to the spec's §4: rows small / ~300 / ~950, columns first-open and reopen totals plus the CLI share, labelled "before (2026-11-xx)". No session ids or paths in the doc.
- [ ] **Step 6: Commit** `feat(workchat): open-time signposts and baseline numbers (#2065)`.

---

### Task 2: Go live steps (`steps`, `steps_more`)

**Depends on:** none

**Files:**
- Modify: `internal/sessionfeed/live.go` (`Live`, `liveReader.start/complete/reset`, end of `LiveOf`)
- Create: `internal/sessionfeed/live_steps_test.go`
- Modify: `docs/inventory/session-feed.md` (FEED-03 Observable: `live` also carries `steps`/`steps_more`; changelog line), `docs/features/session-chat-feed.md` (the live-line bullet: steps, cap, 4 MiB window limit)

**Interfaces:**
- Produces (JSON inside `live`): `"steps": [LiveAction…]` oldest first, the open step last, completed ones with `completed_at`; `"steps_more": int`. Go: `Live.Steps []LiveAction \`json:"steps"\``, `Live.StepsMore int \`json:"steps_more"\``, `const maxLiveSteps = 40`.

- [ ] **Step 1: Write the failing tests** (reuse the fixture writers of `live_test.go`)

```go
func TestLiveStepsCurrentTurnInOrderWithOpenLast(t *testing.T) {
	// owner line, Read(t1) + result, Grep(t2) + result, Bash(t3) open
	live := liveOf(t, transcript)
	require.Len(t, live.Steps, 3)
	assert.Equal(t, []string{"t1", "t2", "t3"}, stepIDs(live.Steps))
	assert.False(t, live.Steps[0].CompletedAt.IsZero())
	assert.True(t, live.Steps[2].CompletedAt.IsZero(), "the open step is last and not completed")
	assert.Equal(t, 0, live.StepsMore)
}
func TestLiveStepsResetOnNewTurn(t *testing.T)        // steps of turn 1, owner line, one step → Steps has only turn 2's step
func TestLiveStepsCapAt40CountsTheCut(t *testing.T)   // 45 completed tool calls in one turn → len 40, StepsMore 5, Steps[0].ID == "t6"
func TestLiveStepsEmptyWhenTurnEnded(t *testing.T)    // end_turn → Steps == []LiveAction{} (not nil), StepsMore 0
func TestLiveStepsCodexCallsAndOutputs(t *testing.T)  // function_call/custom_tool_call + outputs → same order, completed_at set
func TestLiveStepsJSONNeverNull(t *testing.T) {
	b, _ := json.Marshal(liveOf(t, endedTranscript))
	assert.Contains(t, string(b), `"steps":[]`)
	assert.Contains(t, string(b), `"steps_more":0`)
}
func TestLiveStepsSidechainOnlyOwnRecords(t *testing.T) // sidechain=false ignores isSidechain tool_use records
```

- [ ] **Step 2: Run** `go test ./internal/sessionfeed -run TestLiveSteps` — FAIL.
- [ ] **Step 3: Implement.** `liveReader` gains `steps []LiveAction`: `start` appends a new id (or replaces the same id in place), `complete` sets `CompletedAt` on the matching step, `reset` clears it; Codex `task_complete`-family events leave it to the end-of-`LiveOf` rule. At the end of `LiveOf`: `!TurnActive` → `Steps = []LiveAction{}`; else keep the last `maxLiveSteps` and set `StepsMore` to the cut. The `live` struct literal initialises `Steps: []LiveAction{}`.
- [ ] **Step 4: Run** `go test ./internal/sessionfeed` (all FEED-01/02 and `TestLive*` guards) and `go test ./cmd -run 'TestSessionFeed'` — PASS; `make lint-diff` clean.
- [ ] **Step 5: Docs.** FEED-03 text gains "`live` also carries `steps` and `steps_more` (additive, spec 2026-11-19)"; changelog line `2026-11-xx (board #2065, spec approval): FEED-03 additive live.steps/steps_more; no guard changed.` Feature note: steps are the current turn's tool calls from the same 4 MiB `LiveOf` window, cap 40.
- [ ] **Step 6: Commit** `feat(sessionfeed): live steps of the current turn (#2065)`.

---

### Task 3: Go `--tail` / `--before` and `started_at` on subagents

**Depends on:** none

**Files:**
- Modify: `internal/sessionfeed/entry.go` (`SubagentRef.StartedAt`), `internal/sessionfeed/subagent.go` (`marker`, `readMetas` mtime, `metaMarkers`), `internal/sessionfeed/feed.go` (`liveMarkers`, new `TailPage`)
- Create: `internal/sessionfeed/feed_tail_test.go`
- Modify: `internal/sessionfeed/subagent_test.go`
- Modify: `cmd/workbench_session_feed.go`, `cmd/workbench_session_feed_test.go`
- Modify: `docs/inventory/session-feed.md` (FEED-03 Observable + changelog), `docs/features/session-chat-feed.md` (CLI line, cursor section)

**Interfaces:**
- Produces (Go): `SubagentRef.StartedAt time.Time \`json:"-"\`` (never in the entry JSON or the hub's `chatSubagent`); `func TailPage(entries []Entry, before string, n int) (page []Entry, nextBefore string, err error)` — `before == ""` means from the end; `nextBefore` is the id of the page's first entry, `""` when the page starts at entry 0.
- Produces (CLI): `--tail N` (N ≥ 1; excludes `--after` and `--subagent`), `--before ID` (requires `--tail`). Output with `--tail`: `entries` = the page, `cursor` = the same end cursor a full read prints, `before` = `nextBefore` (key omitted when empty), `subagents` = the full list a full read prints. Each `subagents` item's `subagent` object carries `started_at` (RFC 3339; zero time only when neither the call nor `meta.json` is known). Entries' `subagent` objects are unchanged.

- [ ] **Step 1: Write the failing Go tests**

```go
func TestTailPage_LastNAndBeforeCursor(t *testing.T) {
	es := entriesN(150) // ids e0..e149
	page, before, err := TailPage(es, "", 60)
	require.NoError(t, err)
	assert.Equal(t, "e90", page[0].ID); assert.Equal(t, "e149", page[59].ID); assert.Equal(t, "e90", before)
	page, before, _ = TailPage(es, "e90", 60)
	assert.Equal(t, "e30", page[0].ID); assert.Equal(t, "e89", page[59].ID); assert.Equal(t, "e30", before)
	page, before, _ = TailPage(es, "e30", 60)
	assert.Len(t, page, 30); assert.Equal(t, "", before)
}
func TestTailPage_ShortFeedHasNoBefore(t *testing.T)    // 10 entries, n 60 → 10 entries, before ""
func TestTailPage_UnknownBeforeIsAnError(t *testing.T)  // before "nope" → err containing `before "nope"`
func TestBuild_TailKeepsFullSubagentsList(t *testing.T) // a feed whose first marker lies outside the last 60 entries: feed.Subagents unchanged by TailPage, still lists it
func TestSubagent_StartedAtFromAgentCall(t *testing.T)  // parsed marker: Subagent.StartedAt == the tool_use record's timestamp
func TestSubagent_StartedAtFromMetaMtime(t *testing.T)  // metaMarkers: StartedAt == os.Stat(meta).ModTime() (set with os.Chtimes)
func TestSubagent_StartedAtZeroWithoutCallOrMeta(t *testing.T)
```

`cmd` tests:

```go
func TestSessionFeed_TailPagesWithBeforeAndKeepsCursor(t *testing.T) {
	// 70 owner lines; --tail 60 → 60 entries, before == id of entries[0], cursor == full read's cursor
	// --tail 60 --before <that id> → 10 entries, no "before" key
}
func TestSessionFeed_TailSubagentsMatchFullRead(t *testing.T) // subagents of --tail equal subagents of a full read
func TestSessionFeed_SubagentsItemsCarryStartedAt(t *testing.T) {
	got := fx.feedJSON(t)
	sub := got["subagents"].([]any)[0].(map[string]any)["subagent"].(map[string]any)
	assert.Equal(t, "2026-10-01T10:00:06Z", sub["started_at"])
	entry := got["entries"].([]any)[2].(map[string]any)["subagent"].(map[string]any)
	assert.NotContains(t, entry, "started_at", "entries keep the five pinned keys")
}
func TestSessionFeed_TailFlagRules(t *testing.T) // --tail 0 → error; --before without --tail → error; --tail with --after or --subagent → cobra exclusion error
```

`TestSessionFeedJSON_PinnedKeys` is not edited (a full read prints no `before`).

- [ ] **Step 2: Run** `go test ./internal/sessionfeed -run 'TestTailPage|TestBuild_Tail|TestSubagent_StartedAt'` and `go test ./cmd -run 'TestSessionFeed_(Tail|SubagentsItems)'` — FAIL.
- [ ] **Step 3: Implement.** `subagentMeta` gains `modTime time.Time` from the `Lstat` already taken; `marker` sets `StartedAt: at`; `metaMarkers` sets `StartedAt: m.modTime`; `liveMarkers` sets `ref.StartedAt = a.StartedAt`. `TailPage` as specified. `cmd`: flags `workbenchSessionFeedFlagTail int`, `workbenchSessionFeedFlagBefore string`; `MarkFlagsMutuallyExclusive("tail","after")`, `("tail","subagent")`; RunE refuses `--before` without `--tail` and `--tail < 1`. `sessionFeedJSON` gains `Before string \`json:"before,omitempty"\``; `Subagents` becomes `[]sessionFeedSubagentItemJSON` — the entry fields plus `Subagent *sessionFeedSubagentRefJSON` (the five `SubagentRef` keys + `StartedAt time.Time \`json:"started_at"\``), built by `toSessionFeedSubagentItems(es []sessionfeed.Entry)`; the `--subagent` path uses it too. `buildSessionFeedOutput` gains `tail int, before string` and applies `TailPage` to `feed.Entries` after `Build`.
- [ ] **Step 4: Run** `go test ./internal/sessionfeed`, `go test ./cmd -run 'TestSessionFeed'` (incl. `TestSessionFeedJSON_PinnedKeys`, `TestSessionFeed_CodexSessionReturnsEntries`, `TestSessionFeed_AskFromOwnWorkbenchOnly`), `go test ./internal/hub/slices/sources -run TestFeed05` (the hub reads `SubagentRef`; its wire must not gain a key) — PASS; `make lint-diff` clean.
- [ ] **Step 5: Docs.** Inventory FEED-03 Observable: "with `--tail`, `before` (omitted when empty); a `subagents` item's `subagent` object also carries `started_at`" + changelog line. Feature note: CLI usage line gains `[--tail N [--before ID]]`; the cursor section explains `--tail` parses what a full read parses and trims only the printed entries, and that `--after` reads date a marker from `meta.json`'s mtime.
- [ ] **Step 6: Commit** `feat(sessionfeed): tail paging and subagent start times (#2065)`.

---

### Task 4: Mac feed without agents; the 👥 list with Working and Done

**Depends on:** none (consumes Task 3's JSON contract via fixtures)

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/WorkchatFeedAdapter.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Models/SessionFeed.swift` (`SessionFeedSubagent.startedAt`)
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/SessionFeedStore.swift` (`subagents`, `feedLoaded`)
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/WorkchatLivePresentation.swift`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/WorkchatPaneMemory.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/WorkchatLiveLine.swift`, `SessionChatView.swift`, `SessionChatSubagentView.swift`, `SessionChatRow.swift` (remove `subagentCard` and the `"subagent"` case)
- Modify: `WatchtowerDesktop/Sources/ViewModels/WorkbenchesViewModel.swift`, `WorkbenchesViewModel+Panel.swift` (`paneMemory`)
- Test: `Tests/Core/WorkchatFeedAdapterTests.swift`, `Tests/Core/WorkchatLivePresentationTests.swift` (new tests only), `Tests/Core/WorkchatAgentsListTests.swift` (new), `Tests/Core/WorkchatPaneMemoryTests.swift` (new), `Tests/Core/SessionFeedStoreTests.swift`

**Interfaces:**
- Consumes: Task 3's `subagents[].subagent.started_at`.
- Produces:
  - `SessionFeedSubagent.startedAt: Date?` (decoded from `started_at`, nil when absent or zero).
  - `SessionFeedStore.subagents: [SessionFeedEntry]` (`@Published`, upsert by id from `payload.subagents` and from `subagent` entries in `payload.entries`; `entries` no longer receives the `subagents` list), `SessionFeedStore.feedLoaded: Bool` (true after the first good read; never reset by a failure).
  - `WorkchatLivePresentation.Row` gains `activity: Bool` (false = only the 👥 button), `agentsSymbol: String` (`"person.2"` or `"checkmark"`), `agentsDimmed: Bool`.
  - `WorkchatLivePresentation.row(snapshot:error:loaded:working:stateAt:now:done: [SessionFeedSubagent] = [])` — existing behaviour unchanged when `done` is empty.
  - `WorkchatLivePresentation.agentsList(snapshot: SessionFeedLive?, error: String?, feedLoaded: Bool, feedError: String?, done: [SessionFeedSubagent], now: Date) -> AgentsList` with `package struct AgentsList: Equatable { var state: State /* .ready, .loading, .error */; var working: [AgentRow]; var workingNote: String?; var done: [DoneRow]; var doneTitle: String; var doneOpenByDefault: Bool }`, `package struct DoneRow: Equatable, Identifiable { var ref: SessionFeedSubagent; var title: String; var subtitle: String; var id: String }`.
  - `WorkchatLivePresentation.done(from subagents: [SessionFeedEntry]) -> [SessionFeedSubagent]` (status `finished`, ordered).
  - Statics: `listTitle = "Agents"`, `workingTitle = "WORKING"`, `noneWorking = "No agents working"`, `listLoading = "Loading agents…"`, `listError = "Couldn’t read the agents"`, `doneTitle(_ n: Int) -> String` (`"Done · N"`), `maxDoneRows = 5`.
  - `@MainActor @Observable package final class WorkchatPaneMemory { package func doneOpen(_ pane: String, default: Bool) -> Bool; package func setDoneOpen(_ pane: String, _ open: Bool) }` (Task 5 adds the steps half). Pane keys: `"session-<id>"`, `"session-<id>/<toolUseID>"`. `WorkbenchesViewModel.paneMemory` holds one for the app's lifetime.

- [ ] **Step 1: Write the failing tests**

```swift
// WorkchatFeedAdapterTests
func testSubagentEntryMapsToNoMessage() {
    let entries = [entry("o1", kind: "owner"), entry("s1", kind: "subagent"), entry("a1", kind: "agent")]
    XCTAssertEqual(WorkchatFeedAdapter.messages(entries).map(\.id), ["o1", "a1"].map(WorkchatFeedAdapter.messageID))
    XCTAssertNil(WorkchatFeedAdapter.role(for: "subagent"))
}

// WorkchatLivePresentationTests (added; existing tests untouched)
func testBadgeStates() {
    let done = [SessionFeedSubagent(toolUseID: "d1", status: "finished")]
    let working = snapshot(agents: [runningAgent("w1")])
    XCTAssertEqual(row(working, done: done)?.agentsBadge, "1"); XCTAssertEqual(row(working, done: done)?.agentsSymbol, "person.2")
    let onlyDone = try XCTUnwrap(row(snapshot(), done: done))
    XCTAssertEqual(onlyDone.agentsBadge, "1"); XCTAssertEqual(onlyDone.agentsSymbol, "checkmark"); XCTAssertTrue(onlyDone.agentsDimmed)
    XCTAssertEqual(row(snapshot(state: "unknown"), done: done)?.agentsBadge, "?")
    XCTAssertTrue(row(snapshot(state: "unknown"), done: done)!.agentsEnabled, "unknown still opens the list when Done has rows")
    XCTAssertNil(row(snapshot(), done: [])?.agentsBadge)
}
func testButtonShownIdleAndEndedHiddenWithoutSubagents() {
    let done = [SessionFeedSubagent(toolUseID: "d1", status: "finished")]
    let idle = try XCTUnwrap(row(nil, working: false, done: done))
    XCTAssertFalse(idle.activity); XCTAssertNil(idle.elapsed); XCTAssertEqual(idle.agentsBadge, "1")
    XCTAssertNil(row(nil, working: false, done: []))
}

// WorkchatAgentsListTests
func testDoneOrderNewestFirstUndatedLastInCLIOrder()   // started_at 10:02, nil(a), 10:05, nil(b) → [10:05, 10:02, a, b]
func testWorkingExcludesIdsInDone()                    // live says running for "x", Done has "x" → working has no "x"
func testDoneOpensByItselfWhenWorkingEmptyOrUnknown()  // [] → true; unknown → true; one working → false
func testListStrings() {
    let list = WorkchatLivePresentation.agentsList(snapshot: snapshot(), error: nil, feedLoaded: true, feedError: nil, done: nineDone, now: now)
    XCTAssertEqual(list.doneTitle, "Done · 9"); XCTAssertEqual(list.workingNote, "No agents working")
    XCTAssertEqual(WorkchatLivePresentation.listTitle, "Agents"); XCTAssertEqual(WorkchatLivePresentation.workingTitle, "WORKING")
    XCTAssertEqual(WorkchatLivePresentation.maxDoneRows, 5)
}
func testUnknownWorkingNeverSaysNoneWorking()          // agents_state unknown → workingNote "Agent status unavailable"
func testLoadingAndErrorStates()                       // feedLoaded false, no error → .loading ("Loading agents…"); feedError and !feedLoaded → .error ("Couldn’t read the agents"); feedError but feedLoaded → .ready with Done kept
func testUnknownStatusMarkerInNeitherSection()         // marker status "unknown" → not in done, not in working (Review Focus 1)
func testDoneRowTitleTypeSubtitleDescription()         // type "" → "Subagent"

// WorkchatPaneMemoryTests
@MainActor func testDoneDefaultUntilOwnerToggles()     // doneOpen("p", default: true) == true; setDoneOpen("p", false); doneOpen("p", default: true) == false
@MainActor func testPanesAreIndependent()

// SessionFeedStoreTests
func testSubagentsKeptApartFromEntries()               // payload.subagents with one marker → store.subagents has it, store.entries does not
func testStoreKeepsSubagentsWhenALaterReadFails()      // good read, then runner throws → subagents unchanged, feedLoaded true, error set
func testDecodesSubagentStartedAt()                    // "started_at":"2026-10-01T10:00:06Z" → startedAt; "0001-01-01T00:00:00Z" → nil
```

`testSubagentStatusUpdatedFromSubagentsList` (not a guard) is rewritten to assert on `store.subagents`.

- [ ] **Step 2: Run** `make test-swift FILTER='WorkchatFeedAdapterTests|WorkchatLivePresentationTests|WorkchatAgentsListTests|WorkchatPaneMemoryTests|SessionFeedStoreTests'` — FAIL.
- [ ] **Step 3: Implement.**
  - Adapter: `role(for: "subagent")` → nil; the type comment drops "subagent markers".
  - Store: `merge(_:)` for entries skips nothing new; a second `mergeSubagents(_:)` upserts into `subagents` (keeping each id's first position).
  - `row`: when `!working`, return nil if `done` is empty, else a Row with `activity: false`, empty text, `agentsBadge: String(done.count)`, `agentsSymbol: "checkmark"`, `agentsDimmed: true`, `agentsEnabled: true`. When working: today's logic, then if the working count is nil/0 and not unknown and `done` is non-empty, the done badge; `agentsEnabled = badge != nil && (!unknown || !done.isEmpty)` — with `done == []` this equals today's `badge != nil` for known and `false` for every unknown/stale case, so the existing guard assertions hold.
  - `agentsList` as specified; `AgentRow` keeps its fields.
  - `WorkchatLiveLine`: takes `done: [SessionFeedSubagent]`, `paneKey: String`, `memory: WorkchatPaneMemory`, `feedLoaded`, `feedError`, `onRetryList`; draws the row when `row != nil`; the 👥 button uses `agentsSymbol`, `agentsDimmed` (tertiary on a `Fill.rest` capsule, as mockup 03), `.help`/accessibility label `agentsTitle(snapshot:)` while working; the popover no longer closes on `working == false` (it still closes on a warning and on a conversation change). `WorkchatRunningAgentsPicker` becomes `WorkchatAgentsPopover`: `listTitle`, the `workingTitle` caps header with rows (or `workingNote`), a `Done · N` disclosure (`memory.doneOpen(paneKey, default: list.doneOpenByDefault)`), Done rows at most `maxDoneRows` tall then scrolling, `.loading`/`.error` (+ `retryTitle`) states, no separators. A row click closes the popover and calls `onOpenAgent`.
  - `SessionChatView`: passes `store.subagents`-derived `done` and draws the live line also when the session ended — under the ended text, whose padding becomes `Spacing.large`; the composer-less ended branch shows the caption row only when `row != nil`. `activityLine`'s running count and `currentSubagentStatus` read `store.subagents`.
  - `SessionChatSubagentView`: its live line gets `done` = finished nested markers of its `entries`, pane key `"session-<id>/<toolUseID>"`.
  - `SessionChatRow`: remove `subagentCard` and the `"subagent"` branch (no producer left).
- [ ] **Step 4: Run** the Step 2 filter plus `make test-swift FILTER='SessionChatPathTests|SessionFeedSubagentObservationTests|WorkchatActivityPresenterTests|DesignShotsTests/testWorkchatActivityShotsRender'` — PASS; `make lint-swift` clean.
- [ ] **Step 5: Commit** `feat(workchat): agents leave the feed, 👥 list with Working and Done (#2065)`.

---

### Task 5: Live steps disclosure on the Mac

**Depends on:** Task 4 (same presentation and line files; consumes Task 2's JSON via fixtures)

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Models/SessionFeedLive.swift` (`steps`, `stepsMore`)
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/WorkchatLivePresentation.swift`, `WorkchatPaneMemory.swift`
- Create: `WatchtowerDesktop/Sources/Views/Workbench/WorkchatStepsList.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/WorkchatLiveLine.swift`, `SessionChatView.swift`, `SessionChatSubagentView.swift`
- Modify: `WatchtowerChat/Sources/ChatUI/Composer/ChatComposerField.swift`, `Platform/macOS/ChatComposerTextInput.swift`, `PastingTextView.swift` (⌥↓ hook)
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/WorkchatComposer.swift` (passes the hook)
- Test: `Tests/Core/WorkchatStepsPresentationTests.swift` (new), `Tests/Core/WorkchatPaneMemoryTests.swift`, `WatchtowerChat/Tests/ChatUITests/ComposerOptionArrowDownTests.swift` (new)

**Interfaces:**
- Consumes: Task 2's `live.steps`, `live.steps_more`; Task 4's `Row`, `WorkchatPaneMemory`, pane keys.
- Produces:
  - `SessionFeedLive.steps: [SessionLiveAction]` (default `[]`), `.stepsMore: Int` (default 0).
  - `WorkchatLivePresentation.StepRow: Equatable, Identifiable { id: String; symbol: String; summary: String; time: String?; running: Bool }`, `StepsSlot: Equatable { rows: [StepRow]; title: String }`, `static func stepsSlot(snapshot: SessionFeedLive?, error: String?, working: Bool, now: Date) -> StepsSlot?`, `static func turnSummary(_ count: Int) -> String`, `static let stepsVisibleRows = 6`, `static func stepsHeight(rowHeight: CGFloat) -> CGFloat`.
  - `row(...)` gains `stepsOpen: Bool = false`; `Row` gains `chevron: String?` (`"chevron.up"` closed, `"chevron.down"` open, nil without steps). Open: `text = turnSummary(count)`, `elapsed` = the turn timer, no pulse.
  - `WorkchatPaneMemory.stepsOpen(_ pane: String) -> Bool` (default true), `toggleSteps(_ pane: String)`.
  - ChatUI: `ChatComposerField(..., onOptionArrowDown: (() -> Void)? = nil)` forwarded to the macOS text input; nil = the key does what it does today.

- [ ] **Step 1: Write the failing tests**

```swift
final class WorkchatStepsPresentationTests: XCTestCase {
    func testRowsDurationsAndRunningTimer() throws {
        let slot = try XCTUnwrap(WorkchatLivePresentation.stepsSlot(snapshot: live(steps: [
            step("t1", "Read", "live.go", start: now - 30, end: now - 26),
            step("t2", "Bash", "go test ./internal/sessionfeed", start: now - 14, end: nil)]), error: nil, working: true, now: now))
        XCTAssertEqual(slot.rows.map(\.time), ["0:04", "0:14"])
        XCTAssertEqual(slot.rows.map(\.running), [false, true])
        XCTAssertEqual(slot.rows[1].symbol, WorkchatActivityPresenter.symbol(for: "Bash"))
        XCTAssertEqual(slot.title, "This turn · 2 steps")
    }
    func testTitleCountsTheCut()             // 40 steps + stepsMore 5 → "This turn · 45 steps"; 1 step → "This turn · 1 step"
    func testStepsSlotHiddenOnTurnEndStopAndCard() {
        XCTAssertNil(slot(live(steps: two, turnActive: false), working: true))
        XCTAssertNil(slot(live(steps: two), working: false))          // stop / host or session closed
        XCTAssertNil(slot(nil, working: true))                         // the card shows: the pane passes no snapshot
        XCTAssertNil(slot(live(steps: []), working: true))
    }
    func testStepsSlotHiddenOnStaleOrError()  // observed 10 s ago → nil; error "x" → nil (Review Focus 5)
    func testNewConversationShowsOnlyItsSteps() // snapshot of conversation B after A → rows are B's only
    func testSlotHeightIsFixedAtSixRows() {
        XCTAssertEqual(WorkchatLivePresentation.stepsVisibleRows, 6)
        XCTAssertEqual(WorkchatLivePresentation.stepsHeight(rowHeight: 20), 120)
    }
    func testLineChevronAndSummaryWhenOpen() {
        let open = try XCTUnwrap(row(live(steps: eight), stepsOpen: true))
        XCTAssertEqual(open.chevron, "chevron.down"); XCTAssertEqual(open.text, "This turn · 8 steps")
        XCTAssertEqual(try XCTUnwrap(row(live(steps: eight), stepsOpen: false)).chevron, "chevron.up")
        XCTAssertNil(row(live(steps: [])).chevron)
    }
    func testDecodesStepsAndDefaults()        // JSON with "steps":[…],"steps_more":3 decodes; JSON without them → [] / 0
}
// WorkchatPaneMemoryTests
@MainActor func testStepsOpenByDefaultToggleRemembered() // stepsOpen("p") == true; toggleSteps("p"); == false; other pane still true
// ComposerOptionArrowDownTests (ChatUI, macOS)
@MainActor func testOptionDownCallsTheHook()   // a PastingTextView in an off-screen window gets a synthetic ⌥↓ keyDown → hook called once, text unchanged
@MainActor func testPlainDownWithoutHookKeepsDefault() // hook nil → no crash, caret moves as before
```

- [ ] **Step 2: Run** `make test-swift FILTER='WorkchatStepsPresentationTests|WorkchatPaneMemoryTests|WorkchatLivePresentationTests'` and `make chat-test FILTER=ComposerOptionArrowDownTests` — FAIL.
- [ ] **Step 3: Implement.** Decode the two keys. `stepsSlot` returns nil unless working, snapshot fresh (same stale rule as `row`), no error, `turnActive`, steps non-empty. Durations via `elapsed(from:now:)` on `completedAt - startedAt` (completed) or `now` (running); missing times → nil. `WorkchatStepsList`: fixed height `stepsHeight(rowHeight: ListLayout.lineMinHeight)` from the moment it appears, rows bottom-aligned, `.defaultScrollAnchor(.bottom)` and follow the newest unless the owner scrolled up, middle truncation, no separators. Placement: in `SessionChatView` (and the subagent screen) the list sits directly above `WorkchatLiveLine`, shown when `stepsSlot != nil && memory.stepsOpen(paneKey)`; it takes its height from the feed (not overlaying the line). Clicking the line toggles `memory.toggleSteps`. ⌥↓: `PastingTextView`/`ChatComposerTextInput` route the key event for ⌥↓ (checked against the synthetic event in the test, not a guessed selector) to `onOptionArrowDown`; `WorkchatComposer` passes `{ memory.toggleSteps(paneKey) }`.
- [ ] **Step 4: Run** the Step 2 commands plus `make test-swift FILTER='WorkchatLivePresentationTests|DesignShotsTests/testWorkchatActivityShotsRender'` and `make chat-test FILTER='ChatComposer'` — PASS; `make lint-swift` clean.
- [ ] **Step 5: Commit** `feat(workchat): live steps of the current turn above the live line (#2065)`.

---

### Task 6: Send while the agent works; the background "lock"

**Depends on:** none

**Files:**
- Create: `WatchtowerChat/Sources/ChatUI/Composer/ComposerButtonMode.swift`
- Modify: `WatchtowerChat/Sources/ChatUI/Composer/ChatComposerField.swift` (`ChatComposerFieldConfig.sendWhileStreaming`, the button and `submit`)
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/WorkchatComposer.swift` (config on; captions move to `WorkchatOutgoing`)
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/WorkchatOutgoing.swift` (`caption`)
- Modify (only if Step 1 reproduces a hold): `WatchtowerDesktop/Sources/Services/SessionControl.swift`
- Test: `WatchtowerChat/Tests/ChatUITests/ComposerButtonModeTests.swift` (new), `WatchtowerDesktop/Tests/SessionControlTests.swift`, `WatchtowerDesktop/Tests/WorkchatModelTests.swift`, `Tests/Core/WorkchatOutgoingTests.swift`

**Interfaces:**
- Produces: `public enum ComposerButtonMode: Equatable { case send(active: Bool), stop(active: Bool); public static func resolve(isStreaming: Bool, sendWhileStreaming: Bool, canSend: Bool, canStop: Bool) -> Self }`; `ChatComposerFieldConfig.sendWhileStreaming: Bool = false` (init parameter, default false); `WorkchatOutgoing.caption(state: State, working: Bool, holdsUntilIdle: Bool, sentWhileBusy: Bool = false) -> String?` returning today's strings (`"Sending…"`, `"Queued · sends when the agent stops ·"` / `"Queued · sends in a moment ·"`, `"Typed into the terminal, not sent: press Return there ·"`, `"Copied to the clipboard: the terminal does not accept pasted text ·"`, `"Not sent: the session ended"`, `"Queued · the agent reads it at its next step"`; nil where the view shows the time).

- [ ] **Step 1: Reproduce first — per-state line check tests** (`SessionControlTests`)

```swift
func testWorkchatLineCheckPerState() async throws {
    // For each kind in SessionSwitcherPresentation.State.Kind.allCases × live true/false × justSubmitted (submittedAt now, stamp older) × promptHoldsText:
    // expected: !live → .hold(.agentBusy) / .sessionGone (no status); .needsApproval → .hold(.needsApproval);
    // .working/.background and idle kinds → .go, unless justSubmitted → .hold(.agentBusy), unless promptHoldsText → .hold(.promptHasText)
    XCTAssertEqual(control.workchatLineCheck(id), expected, "\(kind) live=\(live) submitted=\(submitted) text=\(text)")
}
func testBackgroundLineGoesAtOnce() async throws // .background, no recent submit, empty prompt → .go
```

Run `make test-swift FILTER=SessionControlTests`. If every case already holds, write down in the commit message that the state machine never held a `.background` line and the "locked" report is the Stop-only button (and a line sent within `submitSettle` reads "Queued · sends in a moment"); no `SessionControl` change. If a case fails, fix `workchatLineCheck` for that state only and keep `testWorkchatLineCheckMatchesLineCheckExceptWhileWorking` green.

- [ ] **Step 2: Write the failing UI-state tests**

```swift
final class ComposerButtonModeTests: XCTestCase {
    func testSendWithTextInEveryStateWhenEnabled() {
        XCTAssertEqual(ComposerButtonMode.resolve(isStreaming: true, sendWhileStreaming: true, canSend: true, canStop: true), .send(active: true))
        XCTAssertEqual(ComposerButtonMode.resolve(isStreaming: true, sendWhileStreaming: true, canSend: false, canStop: true), .stop(active: true))
        XCTAssertEqual(ComposerButtonMode.resolve(isStreaming: false, sendWhileStreaming: true, canSend: false, canStop: true), .send(active: false))
    }
    func testAIChatKeepsStopWhileStreaming() {
        XCTAssertEqual(ComposerButtonMode.resolve(isStreaming: true, sendWhileStreaming: false, canSend: true, canStop: true), .stop(active: true))
        XCTAssertFalse(ChatComposerFieldConfig(placeholder: "").sendWhileStreaming)
    }
}
// WorkchatModelTests
func testCodexHoldShowsQueuedCaptionWithCancel() async throws {
    // Codex kind (holdsUntilIdle), working → send() → outgoing.last.state == .queued
    XCTAssertEqual(WorkchatOutgoing.caption(state: .queued, working: true, holdsUntilIdle: true), "Queued · sends when the agent stops ·")
    model.cancel(id); XCTAssertTrue(model.outgoing.isEmpty)
}
func testBackgroundSendSubmitsAtOnce() async throws // status .background → send() → .sent, sentWhileBusy true, caption "Queued · the agent reads it at its next step"
// WorkchatOutgoingTests
func testCaptionStrings() // every State × working × holdsUntilIdle → today's exact strings
```

- [ ] **Step 3: Run** `make chat-test FILTER=ComposerButtonModeTests` and `make test-swift FILTER='WorkchatModelTests|WorkchatOutgoingTests'` — FAIL.
- [ ] **Step 4: Implement.** `ChatComposerField` uses `ComposerButtonMode.resolve` for the button (`.send` → `style.sendStopButton(isStreaming: false, …)` calling `onSend`; `.stop` → Stop) and keeps `submit` (Return) as is. `WorkchatComposer` sets `sendWhileStreaming: true`; Esc keeps `escape(working:draft:stop:)`. `WorkchatOutgoingBubble` reads its strings from `WorkchatOutgoing.caption`; `queuedCaption(holdsUntilIdle:)` is removed (callers and `testQueuedCaptionFollowsTheAgentKind` move to the new function with the same strings).
- [ ] **Step 5: Run** Step 3 commands plus `make test-swift FILTER='SessionControlTests|WorkchatModelTests|DesignShotsTests/testSessionCapsShotsRender'` and `make chat-test FILTER=ChatComposer` — PASS; `make lint-swift` clean.
- [ ] **Step 6: Commit** `feat(workchat): Send while the agent works; background never locks the line (#2065)`.

---

### Task 7: Inline paste tokens

**Depends on:** Task 6 (same composer files)

**Files:**
- Create: `WatchtowerChatText/Sources/WatchtowerChatText/PasteTokens.swift`, `WatchtowerChatText/Tests/WatchtowerChatTextTests/PasteTokensTests.swift`
- Create: `WatchtowerChat/Sources/ChatUI/Composer/ComposerPasteRoute.swift`, `WatchtowerChat/Tests/ChatUITests/ComposerPasteRouteTests.swift`
- Modify: `WatchtowerChat/Sources/ChatUI/Composer/ChatComposerField.swift` (`ChatComposerFieldConfig.inlinePastes`, `onInlinePaste`), `Platform/macOS/ChatComposerTextInput.swift`, `PastingTextView.swift` (insert the returned label at the paste location; atomic Backspace)
- Modify: `WatchtowerDesktop/Sources/ViewModels/WorkchatModel.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/WorkchatOutgoing.swift` (`matches`), `WatchtowerDesktop/Sources/Views/Workbench/WorkchatComposer.swift`
- Test: `WatchtowerDesktop/Tests/WorkchatModelTests.swift`, `Tests/Core/WorkchatOutgoingTests.swift`

**Interfaces:**
- Produces:
  - `public enum PasteTokens { public static func imageLabel(_ n: Int) -> String /* "[Image #n]" */; public static func textLabel(_ n: Int, lines: Int) -> String /* "[Pasted text #n +lines lines]" */; public static func lineCount(_ text: String) -> Int; public static func deletionRange(backwardFrom utf16Offset: Int, in text: String, live: Set<Int>) -> NSRange? /* only tokens whose number is in `live` (has a payload) */; public static func numbers(in text: String) -> Set<Int>; public static func expand(_ text: String, payloads: [Int: PastePayload], imagePath: (String) -> String) -> String }`, `public enum PastePayload: Equatable, Sendable { case text(String), image(path: String) }`, `public enum InlinePaste: Sendable { case text(String), image(Data, name: String) }` — all in `WatchtowerChatText` so `WorkchatModel` needs no ChatUI import for them.
  - `public enum ComposerPasteRoute: Equatable { case plain, offerAsFile, token, chip; public static func route(isImage: Bool, characterCount: Int, inlinePastes: Bool) -> Self }` (threshold `PasteClassifier.longTextThreshold`).
  - `ChatComposerFieldConfig.inlinePastes: Bool = false`; `ChatComposerField(..., onInlinePaste: ((InlinePaste) async -> String?)? = nil)` — returns the label to insert, nil inserts nothing.
  - `WorkchatModel`: `private(set) var pastes: [Int: PastePayload]`, `func paste(_ item: InlinePaste) async -> String?`, `static func imageGone(_ n: Int) -> String` (`"Pasted image #N is gone — paste it again"`); `send()` refuses with `attachmentError = imageGone(n)` and keeps the draft when an image payload's file is missing.

- [ ] **Step 1: Write the failing tests** (besides the blocks below: `testDroppedImageStaysChip` — with `inlinePastes` on, a dropped/paperclip image becomes a chip, no token; `testPasteNumberSkipsHandTypedNumbers` — draft already holds hand-typed `[Image #1]`, the first paste becomes `[Image #2]` and the hand-typed one stays plain text on send)

```swift
// PasteTokensTests (make chattext-test)
func testLabels() { XCTAssertEqual(PasteTokens.imageLabel(1), "[Image #1]"); XCTAssertEqual(PasteTokens.textLabel(2, lines: 42), "[Pasted text #2 +42 lines]") }
func testBackspaceAtTokenEndDeletesWholeToken() {
    let text = "fix this [Image #1] and"
    XCTAssertEqual(PasteTokens.deletionRange(backwardFrom: 19, in: text, live: [1]), NSRange(location: 9, length: 10))
    XCTAssertNil(PasteTokens.deletionRange(backwardFrom: 19, in: text, live: []))  // hand-typed: plain text
    XCTAssertNil(PasteTokens.deletionRange(backwardFrom: 8, in: text, live: [1]))
}
func testExpandTextInlineImageToPath() {
    let out = PasteTokens.expand("a [Pasted text #2 +2 lines] b [Image #1]", payloads: [2: .text("x\ny"), 1: .image(path: "/tmp/p 1.png")], imagePath: { "\"\($0)\"" })
    XCTAssertEqual(out, "a x\ny b \"/tmp/p 1.png\"")
}
func testUnknownNumberStaysVerbatim()   // "[Image #9]" with no payload 9 → unchanged
// ComposerPasteRouteTests (make chat-test)
func testWorkchatRoutesImagesAndLongTextToTokens() {
    XCTAssertEqual(ComposerPasteRoute.route(isImage: true, characterCount: 0, inlinePastes: true), .token)
    XCTAssertEqual(ComposerPasteRoute.route(isImage: false, characterCount: PasteClassifier.longTextThreshold, inlinePastes: true), .token)
    XCTAssertEqual(ComposerPasteRoute.route(isImage: false, characterCount: 20, inlinePastes: true), .plain)
}
func testAIChatKeepsChipAndOffer() // inlinePastes false: image → .chip, long text → .offerAsFile, short → .plain
// WorkchatModelTests
func testPasteTokensNumberUpPerDraft()          // image → "[Image #1]", text → "[Pasted text #2 +42 lines]"; after send the next paste is #1
func testPasteImageSaveFailureInsertsNoToken()  // store throws → paste returns nil, attachmentError "Could not save the pasted file: …", pastes empty
func testSendExpandsTokens() async throws {
    // draft "fix [Image #1] see [Pasted text #2 +2 lines]" → delivered text "fix <quoted path> see x\ny"; outgoing.typedText == the tokenized draft
}
func testDeletedTokenDropsItsPayload() async throws // remove "[Pasted text #2 …]" from draft, send → pastes has no 2, text not in the line
func testImageGoneRefusesSendKeepsDraft() async throws // delete the saved file → send() delivers nothing, attachmentError "Pasted image #1 is gone — paste it again", draft unchanged
func testNotSentRestoresTokenizedDraftAndPayloads() async throws // noSession → draft == tokenized, pastes restored (only into an empty field)
func testCancelRestoresTokenizedDraftAndPayloads() async throws  // queued line Cancel → same restore; a newer draft is kept
func testHandTypedTokenIsPlainText() async throws // draft "[Image #1]" typed, no paste → deletionRange(live: []) is nil, Backspace deletes one char; line text "[Image #1]"
// WorkchatOutgoingTests
func testEchoMatchesExpandedText() // line text "a x y" (from a text token), typedText "a [Pasted text #1 +2 lines]"; owner entry "a x\ny" → matches; entry "a [Pasted text #1 +2 lines]" → no match
func testEchoWithImageTokenMatchesClaudeImageMarker() // expanded path in text; echo "fix [Image #1]" → matches
```

- [ ] **Step 2: Run** `make chattext-test FILTER=PasteTokensTests`, `make chat-test FILTER=ComposerPasteRouteTests`, `make test-swift FILTER='WorkchatModelTests|WorkchatOutgoingTests'` — FAIL.
- [ ] **Step 3: Implement.** `PasteTokens` as specified (token pattern `\[(?:Image #\d+|Pasted text #\d+ \+\d+ lines)\]`). The text view: on a paste whose `ComposerPasteRoute` is `.token`, call `onInlinePaste` and insert the returned label at the paste selection; `deleteBackward` with an empty selection uses `deletionRange(…, live:)` with the draft's payload numbers. With `inlinePastes` off, today's chip and `LongPasteOffer` paths run unchanged. A **dropped or paperclip-picked** image stays a chip with `inlinePastes` on (only the paste route makes tokens) — test `testDroppedImageStaysChip`. Hand-typed bracket text is plain text (Review Focus 4). `WorkchatModel.paste`: image → existing `attachmentStore.save` (no chip), payload `.image(path:)`; text → payload `.text`; numbering `max(payload numbers ∪ PasteTokens.numbers(in: draft))+1` so a hand-typed number is never reused, reset when a send clears the draft. `send()`: prune payloads whose number is not in `PasteTokens.numbers(in: draft)`; refuse on a missing image file; `text` = expanded draft + chip paths; image token paths join `attachmentPaths`; keep `sentPastes[id]` beside `sentAttachments[id]`. `settle(.notSent)` and `cancel` restore draft, pastes and chips into an empty field. `WorkchatOutgoing.matches` compares against `text` (paths removed, image markers stripped, whitespace collapsed) instead of `typedText`.
- [ ] **Step 4: Run** the Step 2 commands plus `make chat-test FILTER=ChatComposer` and `make test-swift FILTER='WorkchatModelTests|WorkchatAttachmentStoreTests|DesignShotsTests/testSessionCapsShotsRender'` — PASS; `make lint-swift` clean.
- [ ] **Step 5: Commit** `feat(workchat): pasted images and long text go inline as tokens (#2065)`.

---

### Task 8: Kept-alive feed store and tail paging

**Depends on:** Task 1 (baseline recorded, signposts), Task 3 (`--tail/--before`), Task 4 (`SessionFeedStore.subagents`)

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/SessionFeedStore.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Models/SessionFeed.swift` (`SessionFeedPayload.before`)
- Modify: `WatchtowerDesktop/Sources/ViewModels/WorkbenchesViewModel.swift`, `WorkbenchesViewModel+Panel.swift`, `WorkbenchesViewModel+Sessions.swift` (`forgetProcessState`)
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/SessionChatView.swift` (`@ObservedObject` store from the view model; load-earlier asks the store when the window has no more)
- Test: `Tests/Core/SessionFeedStoreTests.swift`, `WatchtowerDesktop/Tests/WorkbenchesFeedStoreTests.swift` (new)

**Interfaces:**
- Consumes: Task 3's CLI flags/keys; Task 4's `subagents`, `feedLoaded`; Task 1's `openTrace`.
- Produces: `SessionFeedStore.tailSize = 60`; `SessionFeedStore.hasEarlierPage: Bool`; `func loadEarlierPage() async`; `SessionFeedPayload.before: String` (`""` when absent); `WorkbenchesViewModel.feedStore(sessionID: Int64) -> SessionFeedStore` (made once per session, dropped in `forgetProcessState`; at most `keptFeedStores = 8` kept, least recently shown dropped first). A kept store whose pane is not on screen runs no CLI: polling stays gated by `follow` (pane shown, window on screen), so keeping it costs memory only — tests `testKeptStoresCappedAtEightLRU`, `testHiddenKeptStoreDoesNotPoll`.

- [ ] **Step 1: Write the failing tests** (besides the block below, in `WorkbenchesViewModelTests`: `testKeptStoresCappedAtEightLRU` — showing 9 sessions keeps 8, the least recently shown is dropped and its next open is a cold tail read; `testHiddenKeptStoreDoesNotPoll` — a kept store whose pane is off screen spawns no CLI over 3 poll ticks of a fake clock)

```swift
// SessionFeedStoreTests (FakeCLIRunner records args)
func testFirstReadIsATailRead() async {
    await store.refresh()
    XCTAssertEqual(runner.calls[0], ["workbench", "session-feed", "--session", "7", "--json", "--tail", "60"])
    XCTAssertTrue(store.hasEarlierPage) // payload before "e90"
}
func testLaterReadsUseAfterCursor() async     // second refresh → "--after", cursor; no "--tail"
func testEarlierPagePrependsAndMovesBefore() async {
    await store.loadEarlierPage()
    XCTAssertEqual(runner.calls.last, ["workbench", "session-feed", "--session", "7", "--json", "--tail", "60", "--before", "e90"])
    XCTAssertEqual(store.entries.first?.id, "e30"); XCTAssertEqual(store.entries.count, 120)
    // a page without "before" → hasEarlierPage false; a third call is not made
}
func testEarlierPageFailureKeepsEntriesAndPaging() async // runner throws → entries unchanged, hasEarlierPage still true, error set
func testGrowingEntryInWindowUpsertsByID() async        // an --after read re-emitting "e149" with new text → updated in place
func testStoreKeepsEntriesWhenALaterReadFails() async   // spec "CLI read fails mid-open"
func testStartedAtKeepsFirstValueAcrossReads() async    // full read startedAt 10:00 → --after read with mtime 10:07 → still 10:00 (Review Focus 2)
// WorkbenchesFeedStoreTests
@MainActor func testFeedStoreKeptPerSession()            // feedStore(sessionID: 1) === feedStore(sessionID: 1); !== feedStore(sessionID: 2)
@MainActor func testReopenPaintsKeptEntriesAndReadsAfter() async // refresh once; the same store's entries are there before the next read; next args carry "--after"
@MainActor func testForgetProcessStateDropsTheStore()
```

- [ ] **Step 2: Run** `make test-swift FILTER='SessionFeedStoreTests|WorkbenchesFeedStoreTests'` — FAIL.
- [ ] **Step 3: Implement.** `refresh()`: empty cursor → `--tail 60`, else `--after cursor` (unchanged). Keep `before` from the first read; `loadEarlierPage()` reads `--tail 60 --before <before>`, prepends unseen entries, rebuilds `index`, updates `before`; through `read(_:)` so it never overlaps a poll. `mergeSubagents` keeps a non-nil `startedAt` already stored. `SessionChatView`: `@ObservedObject var store` = `vm.feedStore(sessionID:)` (the `StateObject` init goes); `context.hasEarlier = window.hasEarlier(total:) || store.hasEarlierPage`; `loadEarlier` grows the window, or awaits `store.loadEarlierPage()` and then grows it. The open trace's `reopen` = the kept store already has entries.
- [ ] **Step 4: Run** the Step 2 filter plus `make test-swift FILTER='SessionFeedWindowTests|SessionFeedPollerTests|SessionFeedSubagentObservationTests|SessionChatPathTests'` — PASS (incl. guard `testLiveEnvelopeFailureKeepsSnapshotButNeverMasqueradesAsFresh`); `make lint-swift` clean.
- [ ] **Step 5: Commit** `perf(workchat): keep each session's feed store; first read is a tail read (#2065)`.

---

### Task 9: Phone — no agent rows in the feed; the agents sheet

**Depends on:** none

**Files:**
- Create: `WatchtowerMobile/Sources/Features/Workbench/WorkchatAgents.swift` (model + `WorkchatAgentsText`), `WatchtowerMobile/Sources/Features/Workbench/WorkchatAgentsSheet.swift` (button + sheet)
- Modify: `WatchtowerMobile/Sources/Features/Workbench/WorkchatModel.swift` (`entries` filtered, `agents`), `WorkchatView.swift` (toolbar button, sheet, drop the `.subagent` row case), `SessionChatView.swift` (same filter and button for a subagent's nested agents)
- Test: `WatchtowerMobile/Tests/WorkchatAgentsTests.swift` (new), `WatchtowerMobile/Tests/WorkchatWiringTests.swift`
- Modify: `WatchtowerMobile/Tests/ScreenshotTourTests.swift` — not in this task (Task 10 adds real-view shots)

**Interfaces:**
- Produces: `struct WorkchatAgents: Equatable { struct Row: Identifiable, Equatable { let id: String; let type: String; let description: String; let route: SessionChatRoute? }; let working: [Row]; let done: [Row]; init(entries: [SessionChat.Entry], sessionID: Int64); static func dialog(_ entries: [SessionChat.Entry]) -> [SessionChat.Entry]; var badge: Badge?; var doneOpenByDefault: Bool }`, `enum Badge: Equatable { case working(Int), done(Int) }`; `enum WorkchatAgentsText { static let title = "Agents"; static let working = "Working"; static let running = "Running"; static func done(_ n: Int) -> String /* "Done · N" */; static func doneBadge(_ n: Int) -> String /* "✓ N" */; static let close = "Close" }`.

- [ ] **Step 1: Write the failing tests**

```swift
final class WorkchatAgentsTests: XCTestCase {
    func testDialogDropsSubagentEntries() {
        XCTAssertEqual(WorkchatAgents.dialog([owner("o1"), marker("s1", .running), agent("a1")]).map(\.id), ["o1", "a1"])
    }
    func testSectionsFromMarkers() {
        let agents = WorkchatAgents(entries: [marker("w1", .running), marker("d1", .finished), marker("d2", .finished)], sessionID: 3)
        XCTAssertEqual(agents.working.map(\.id), ["w1"]); XCTAssertEqual(agents.done.map(\.id), ["d2", "d1"], "newest first")
        XCTAssertEqual(agents.badge, .working(1)); XCTAssertFalse(agents.doneOpenByDefault)
    }
    func testOnlyDoneBadgeAndOpen()          // two finished → badge .done(2), doneOpenByDefault true, WorkchatAgentsText.doneBadge(2) == "✓ 2"
    func testNoAgentsNoButton()              // no markers → badge nil
    func testUnknownStatusInNeitherSection() // Review Focus 1
    func testRowsRouteToTheAgentsChat()      // agentID + toolUseID present → route == SessionChatRoute(sessionID: 3, agentID:, toolUseID:); missing ids → nil
    func testStrings() { XCTAssertEqual(WorkchatAgentsText.done(9), "Done · 9"); XCTAssertEqual(WorkchatAgentsText.running, "Running"); XCTAssertEqual(WorkchatAgentsText.title, "Agents") }
}
// WorkchatWiringTests
func testWorkchatFeedHasNoAgentRows() throws // chat with a .subagent entry → WorkchatModel.entries has none; model.agents.badge == .working(1)
```

- [ ] **Step 2: Run** `make mobile-test MOBILE_FILTER=WorkchatAgentsTests` and `make mobile-test MOBILE_FILTER=WorkchatWiringTests` — FAIL.
- [ ] **Step 3: Implement.** `WorkchatModel.entries = WorkchatAgents.dialog(chat?.entries ?? [])`, `agents = WorkchatAgents(entries: chat?.entries ?? [], sessionID:)`. `WorkchatAgentsSheet`: as `WorkchatAgentsMockups.AgentsSheet` (sections Working with `"Running"` and a chevron, `Done · N` disclosure open by default per `doneOpenByDefault`, the owner's toggle kept while the sheet's screen lives), but closed with an ✕ toolbar button (`WorkchatAgentsText.close` as its accessibility label) — not "Done". The toolbar button sits before the menu (mock `AgentsButton`: `CountBadge` for working, `"✓ N"` on a `Fill.rest` capsule for done). A row tap dismisses the sheet and pushes `SessionChatView` with its route. The subagent screen applies the same filter and button. `WorkchatEntryRow`'s `.subagent` branch is removed.
- [ ] **Step 4: Run** Step 2 commands, `make kit-test FILTER=SessionChat` (Kit untouched), `go test ./internal/hub/slices/sources -run TestFeed05` (hub untouched) — PASS; `make lint-swift` clean.
- [ ] **Step 5: Commit** `feat(iphone): agents leave the session chat, agents sheet with Working and Done (#2065)`.

---

### Task 10: Docs, real-view shots against the mockups, after-numbers

**Depends on:** Tasks 1–9

**Files:**
- Modify: `docs/features/session-chat-feed.md` (Desktop pane paragraph: no subagent cards, the 👥 list, idle/ended button, steps disclosure, kept-alive store, tail paging, Send while working, inline tokens; phone paragraph: agents sheet; v1 limits: unknown-status markers in neither section, phone Done limited to the slice's 300-entry window, Codex Done = the 4 MiB live window), `docs/features/README.md` (its summary line), `docs/guide/features/workbench/workchat.md`, `docs/guide/features/iphone-workbench.md`
- Modify: `WatchtowerDesktop/Tests/DesignShots/DesignShotCatalog.swift` (+ a fixture file `DesignShotFixtures+WorkchatAgents.swift`), `DesignShotsTests.swift` (`testWorkchatAgentsShotsRender`)
- Modify: `WatchtowerMobile/Tests/ScreenshotTourTests.swift` (real-view shots beside the mock ones)
- Modify: the spec §4 "Measured" table (after numbers)

- [ ] **Step 1: Real-view Mac shots.** Add catalog entries `workchat-agents-real-01` … `-14`, one per mockup state, built from the real `WorkchatLiveLine`, `WorkchatAgentsPopover`, `WorkchatStepsList`, `WorkchatComposer` and the ChatUI feed with fixture `SessionFeedLive`/`SessionFeedEntry` data equal to the mock's (same agents, steps, lines, `referenceDate`). `testWorkchatAgentsShotsRender` renders them. Run `make desktop-shots DESKTOP_SHOTS=build/shots-2065` (or `make test-swift FILTER=DesignShotsTests/testWorkchatAgentsShotsRender` plus `testWorkchatAgentsMockShotsRender` with `DESKTOP_SHOTS_DIR`), open each real/mock pair light and dark, and fix any difference in layout, copy, symbol or tone in the owning view. Known intended differences: the open steps line reads "This turn · 8 steps" (spec §3) where mock 08 shows the newest step.
- [ ] **Step 2: Real-view phone shots.** In `testTheWorkchatAgentsShots`, add real `WorkchatView`/`WorkchatAgentsSheet` captures for P1–P4 next to the mockups; run `make mobile-shots SHOTS_ONLY=workchat-agents`; compare and fix. Intended difference: ✕ instead of "Done".
- [ ] **Step 3: After-numbers.** Repeat Task 1 Step 5 with the branch: the CLI's `--tail` read runs the repo-built binary with `--config` pointing at a config whose database is a **copy** of the live file in the scratchpad (never the live path); the Swift share from `WorkchatOpenBenchmarkTests`. Add the "after" columns.
- [ ] **Step 4: Targets are a gate.** If ≤ 300 ms reopen or ≤ 500 ms first open on ~950 entries is missed, the umbrella PR does not open: the controller adds Task 11 aimed at the dominant phase the trace shows (CLI parse → cache the parsed offset per conversation in the CLI; decode/adapter → move off the main actor; paint → lazier first window), runs it like any task, and re-measures. The owner gets the numbers either way.
- [ ] **Step 5: Guide.** `workchat.md`: replace "Read a subagent" with the 👥 list (Working, Done · N, ✓ N, ?), add the steps list (open by default, click or ⌥↓), change the Stop line to "the round button is Stop only with an empty field", replace the paste bullet with tokens; update its learn card text "Click the agent count above the field…". `iphone-workbench.md`: the agents button and sheet. Follow `docs/guide/WRITING.md`; keep each page ≤ 8192 bytes without cards.
- [ ] **Step 6: Run** `go test ./docs/guide`, `make test-swift FILTER='DesignShotsTests/testWorkchatAgents'`, `make lint-swift` — PASS.
- [ ] **Step 7: Commit** `docs(workchat): agents list, live steps, send while working, inline pastes (#2065)`.

---

## Promises → tasks

| Spec promise | Task · test |
|---|---|
| No subagent row in the Mac feed | 4 · `testSubagentEntryMapsToNoMessage` |
| No subagent row on the phone | 9 · `testDialogDropsSubagentEntries`, `testWorkchatFeedHasNoAgentRows` |
| Badge states (N / ✓N / ? / none) | 4 · `testBadgeStates` |
| Done list content, order, dedupe with Working | 4 · `testDoneOrderNewestFirstUndatedLastInCLIOrder`, `testWorkingExcludesIdsInDone`, `testDoneRowTitleTypeSubtitleDescription` |
| `steps` / `steps_more` in `live` | 2 · `TestLiveSteps*` |
| Steps list closes on turn end / stop / card | 5 · `testStepsSlotHiddenOnTurnEndStopAndCard` |
| All UI strings in the model | 4 `testListStrings`, 5 `testTitleCountsTheCut`, 6 `testCaptionStrings`, 7 `testLabels`/`testImageGoneRefusesSendKeepsDraft`, 9 `testStrings` |
| Open-speed target | 1 Step 5, 10 Step 3 |
| Send button with text while working; Stop only when empty | 6 · `testSendWithTextInEveryStateWhenEnabled` |
| Background state lets a line go | 6 · `testWorkchatLineCheckPerState`, `testBackgroundLineGoesAtOnce`, `testBackgroundSendSubmitsAtOnce` |
| Paste tokens: insert, atomic delete, numbering | 7 · `testLabels`, `testBackspaceAtTokenEndDeletesWholeToken`, `testPasteTokensNumberUpPerDraft` |
| Tokens expand on send | 7 · `testExpandTextInlineImageToPath`, `testSendExpandsTokens` |
| Dropped token drops its payload | 7 · `testDeletedTokenDropsItsPayload` |
| 👥 shown idle and ended, hidden with no subagents | 4 · `testButtonShownIdleAndEndedHiddenWithoutSubagents` |
| Done auto-opens; owner toggle wins | 4 · `testDoneOpensByItselfWhenWorkingEmptyOrUnknown`, `testDoneDefaultUntilOwnerToggles` |
| Steps open by default, toggle (click, ⌥↓) remembered per pane | 5 · `testStepsOpenByDefaultToggleRemembered`, `testOptionDownCallsTheHook` |
| Steps slot height fixed; hidden on turn end / stop / card / new conversation | 5 · `testSlotHeightIsFixedAtSixRows`, `testStepsSlotHiddenOnTurnEndStopAndCard`, `testNewConversationShowsOnlyItsSteps` |
| `sendWhileStreaming` off: AI chat keeps Stop | 6 · `testAIChatKeepsStopWhileStreaming` |
| Codex hold: Send + "Queued · sends when the agent stops ·" + Cancel | 6 · `testCodexHoldShowsQueuedCaptionWithCancel` |
| `notSent` / Cancel restore the tokenized draft | 7 · `testNotSentRestoresTokenizedDraftAndPayloads`, `testCancelRestoresTokenizedDraftAndPayloads` |
| Echo matched on the expanded text | 7 · `testEchoMatchesExpandedText` |
| Image gone at send refuses, draft kept | 7 · `testImageGoneRefusesSendKeepsDraft` |
| `--tail` / `--before` pages, cursor kept | 3 · `TestTailPage_LastNAndBeforeCursor`, `TestSessionFeed_TailPagesWithBeforeAndKeepsCursor` |
| `--tail` prints the full `subagents` list | 3 · `TestBuild_TailKeepsFullSubagentsList`, `TestSessionFeed_TailSubagentsMatchFullRead` |
| `started_at` from the Agent call, else meta mtime | 3 · `TestSubagent_StartedAt*` |
| Store kept per session; reopen paints kept entries | 8 · `testFeedStoreKeptPerSession`, `testReopenPaintsKeptEntriesAndReadsAfter` |
| Phone: sheet sections | 9 · `testSectionsFromMarkers`, `testOnlyDoneBadgeAndOpen`, `testNoAgentsNoButton` |
| Failure: CLI read fails mid-open, Done from last good read | 4 `testStoreKeepsSubagentsWhenALaterReadFails`, 8 `testStoreKeepsEntriesWhenALaterReadFails` |
| Failure: host/session closes while steps open | 5 · `testStepsSlotHiddenOnTurnEndStopAndCard` (`working == false`) |
| Failure: Working and Done disagree for a poll | 4 · `testWorkingExcludesIdsInDone` |
| Failure: paste tokens on a failed/cancelled line | 7 · notSent, Cancel, image-gone tests |
| Failure: tail read, entry grows inside the window | 8 · `testGrowingEntryInWindowUpsertsByID` |
| Mockups compared with real views | 10 · Steps 1–2 |
