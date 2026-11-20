# Phone Workchat live line — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The phone's Workchat shows the Mac's live line (step, timer), the turn's steps on a tap and live agents, pushed on a transcript change; the Mac's Workchat refreshes on the same file events.

**Architecture:** The Go hub's `session_chat` source reads the feed and `sessionfeed.LiveOf` on fsnotify events (250 ms debounce, ≤ 1 read/s per chat), redacts and caps the live block and publishes it through the existing fast lane and relay socket. The live model and its presentation move to `WatchtowerChatText`, shared by the Mac and the phone. The Mac's Workchat store swaps its 3 s poll for per-file `DispatchSource` watches.

**Tech Stack:** Go 1.26 (`github.com/fsnotify/fsnotify` v1.9.0, already in go.mod as indirect; `testing/synctest`), Swift 5.10 mode (SwiftUI, GRDB), xcodegen for the phone.

**Spec:** `docs/superpowers/specs/2026-11-20-phone-workchat-live-design.md` (approved, ask #1675). Mockups: `docs/design/mockups/phone-workchat-live/`.

## Global Constraints

- Wire keys (the spec's `live` block — the payload already has a `live` bool for the session's liveness, so the block's key is **`activity_live`**): `activity_live` (object, `sessionfeed.Live` JSON shape), `live_version` (int, always `1` from a new hub), `live_error` (string, omitempty). Swift: `SessionChat.activityLive: SessionFeedLive?`, `liveVersion: Int?`, `liveError: String?`.
- Summary cut: 200 characters after redaction; steps ≤ 40 (`maxLiveSteps`), agents ≤ 32 (`maxLiveAgents`); the block is reserved first inside `MaxChatBytes` (600 000).
- Redaction: `secretredact.Text` on every `summary` (steps, current, latest, each agent's action) and every agent `description`, before the cut. Mark `[secret]`.
- Events: debounce 250 ms after the last event, at most one read per second per chat while events keep coming, trailing edge guaranteed. The 3 s tick only for a chat/session whose watch cannot be set.
- Mac per-file sources ≤ 32 per pane (conversation files + running subagents' `.jsonl`).
- No new phone timer, background mode or wake; the elapsed redraw is a `TimelineView(.periodic(by: 1))` inside the visible line only.
- All UI strings come from `WorkchatLivePresentation` (shared) or a phone model, asserted by a test. Colours through `PhoneTone`/`Tone`, no row separators.
- Tests never wait on wall-clock time: `testing/synctest` in Go, injected clocks/fake event sources in Swift.
- Tests that spawn processes reap their process group; packages creating git repos call `gittest.DisableBackgroundGit()` (CLAUDE.md).
- Each task: inner loop only (`go test ./internal/<pkg>`, `make test-swift FILTER=…`, `make chattext-test FILTER=…`, `make kit-test FILTER=…`, `make mobile-test MOBILE_FILTER=… SIM="iPhone 17 Pro" MOBILE_XCB_EXTRA="-derivedDataPath $PWD/build/DerivedData"`), `make lint-diff` for Go, `make lint-swift` (or swiftlint on the touched tree) for Swift. Full gate once, by the controller, before the merge into `umbrella/phone-workchat`.

## Review Focus

1. A Bash summary carrying a secret in a form the patterns miss (e.g. `--password secret` with a space, `curl -u user:pass`) — expect `[secret]`; add both to T1's table.
2. A session switching conversation (`/clear`) while the phone's steps slot is open — expect the slot closes and the new file is watched (T4 rename/create test, T7 conversation-change test).
3. The phone opens a chat whose session is idle — expect no line and no Loading flash (T7 table test, row "not working").
4. A burst of transcript writes for minutes (a long `go test -v`) — expect ≤ 1 publish/s, never a backlog after the burst (T4 burst test).
5. The Mac pane open on a session whose transcript path does not exist yet (just started) — expect the 3 s fallback, then file sources once the path appears (T9 fallback test).

---

### Task 1: `internal/secretredact` — the shared redaction

Depends on: none.

**Files:**
- Create: `internal/secretredact/redact.go`, `internal/secretredact/redact_test.go`
- Modify: `internal/watchman/redact.go` (keep `Clip`, `ItemQuestion`; `Redact` delegates or callers switch), `internal/watchman/source.go:82`
- Move tests: the watchman `Redact` cases into `redact_test.go` (keep a thin watchman test that `clean` still redacts)

**Interfaces:**
- Produces: `func Text(s string) string` in package `secretredact`; `const Mark = "[secret]"`.

- [ ] **Step 1: Failing test** `TestText` table: every existing watchman case, plus `https://user:pa55@host/x` → `https://[secret]@host/x`, `curl -u bob:hunter2 url` → `curl -u [secret] url`, `--password hunter2` → `--password [secret]`, `-H "Authorization: Bearer abcdEFGH12345678"` → bearer token replaced, `PASSWORD=x9y8z7` → `PASSWORD=[secret]`, prose `Bearer authentication` unchanged, `go test ./internal/sessionfeed` unchanged.
- [ ] **Step 2:** `go test ./internal/secretredact` → FAIL (package missing).
- [ ] **Step 3:** Move the patterns; add the URL-userinfo, `-u user:pass` and `--password <value>`/`--token <value>` (space-separated) patterns.
- [ ] **Step 4:** `go test ./internal/secretredact ./internal/watchman` → PASS; `make lint-diff` clean.
- [ ] **Step 5:** Commit `feat(secretredact): shared secret redaction, watchman uses it (#2112)`.

### Task 2: Live model and presentation move to `WatchtowerChatText`

Depends on: none.

**Files:**
- Move: `WatchtowerDesktop/Sources/WatchtowerCore/Models/SessionFeedLive.swift`, the `SessionFeedSubagent`/`SessionFeedActivity` types it and the presenters need from `Models/SessionFeed.swift`, `Services/WorkchatActivityPresenter.swift`, `Services/WorkchatLivePresentation.swift` → `WatchtowerChatText/Sources/WatchtowerChatText/Live/`
- Move tests: `WatchtowerDesktop/Tests/Core/WorkchatLivePresentationTests.swift`, `WorkchatActivityPresenterTests.swift`, `WorkchatStepsPresentationTests.swift`, `WorkchatAgentsListTests.swift` → `WatchtowerChatText/Tests/WatchtowerChatTextTests/` (unchanged assertions)
- Modify: `WatchtowerKit/Package.swift` — target `WatchtowerKit` depends on `WatchtowerChatText` (path package `../WatchtowerChatText`); `WatchtowerSync` untouched. `WatchtowerMobile/project.yml` only if the Kit change needs it (`make mobile-gen`).

**Interfaces:**
- Produces (all `public`, same names as today): `SessionFeedLive`, `SessionLiveAction`, `SessionLiveAgent`, `SessionFeedSubagent`, `SessionFeedActivity`, `WorkchatActivityPresenter`, `WorkchatLivePresentation` (with `Row`, `StepRow`, `StepsSlot`, `AgentRow`, `DoneRow`, `AgentsList`, `row(…)`, `stepsSlot(…)`, `busy(…)`). Public memberwise inits where the phone or tests construct them.

- [ ] **Step 1:** Move the files and tests; `package` → `public`; Desktop files `import WatchtowerChatText` where needed.
- [ ] **Step 2:** `make chattext-test FILTER='WorkchatLivePresentation|WorkchatActivityPresenter|WorkchatSteps|WorkchatAgentsList'` → PASS with the moved, unchanged assertions.
- [ ] **Step 3:** `make test-swift FILTER='SessionChatView|WorkchatLiveLine|DesignShots'` → PASS (Mac still builds and draws the same); `make kit-test FILTER=SessionChat` → PASS; `make lint-swift` clean.
- [ ] **Step 4:** Commit `refactor(chattext): live model and presentation shared by Mac and phone (#2112)`.

### Task 3: Live block in the `session_chat` payload + FEED-05

Depends on: Task 1.

**Files:**
- Modify: `internal/hub/slices/sources/session_chat.go` (`chatPayload`, `encodeChat`, the run that reads), `internal/hub/slices/sources/session_chat_test.go`
- Modify: `WatchtowerKit/Tests/Fixtures/workbench/session_chat.json` (add the three keys), `docs/inventory/session-feed.md` (FEED-05 text from the spec's "FEED-05 change", two new guards, changelog line citing ask #1675)

**Interfaces:**
- Consumes: `secretredact.Text`; `sessionfeed.LiveOf(c Conversation, sidechain bool, now time.Time) (*Live, error)`.
- Produces: `chatPayload` fields `ActivityLive *sessionfeed.Live \`json:"activity_live,omitempty"\``, `LiveVersion int \`json:"live_version"\`` (=1), `LiveError string \`json:"live_error,omitempty"\``; `const maxLiveSummary = 200`; `func phoneLive(l *sessionfeed.Live) *sessionfeed.Live` (redacts, cuts, caps; never mutates its input).

- [ ] **Step 1: Failing tests**
  - `TestFeed05_LiveBlockSummariesOnly`: encoded JSON of `activity_live` has only the `sessionfeed.Live` keys, every `summary` ≤ 200 runes, steps ≤ 40, agents ≤ 32.
  - `TestFeed05_LiveBlockRedactsSecrets`: a step summary `curl -H "Authorization: Bearer abcdEFGH12345678" https://u:p4ss@x` and an agent description with `TOKEN=abc123def` encode with `[secret]` and without the raw values.
  - `TestSessionChat_LiveVersionAlways`, `TestSessionChat_NoLiveWhenFinished`, `TestSessionChat_LiveErrorKeepsLastLive` (fetch of the live block fails → last block + `live_error`, entries still update), `TestSessionChat_HungLiveReadSetsError` (fake read blocks past `Timing.Timeout` under `synctest`), `TestSessionChat_LiveReservedInBudget` (entries trimmed, block kept whole).
  - `TestSessionChat_SubagentRecordUsesSidechainLive`: an agent record (`session_chat-<id>-<agent>`) carries the live block read from that subagent's sidechain (its own current step), not the main conversation's.
  - Existing five `TestFeed05_*` unchanged and green; `TestFeed05_MatchesKitFixtureKeys` with the updated fixture.
- [ ] **Step 2:** `go test ./internal/hub/slices/sources -run 'Feed05|SessionChat'` → FAIL.
- [ ] **Step 3:** Read the live block in the same pass as the feed (the main conversation, or the subagent's sidechain for an agent record). `ChatFetch` changes to `func(ctx context.Context, sessionID int64, toolUseID string) (ChatRead, error)` with `type ChatRead struct { Entries []sessionfeed.Entry; Live *sessionfeed.Live; LiveErr error; Paths []string }` — `Paths` are the files read (Task 4 watches them); the default in-process fetch fills all four; every test fake is updated to the new type.
- [ ] **Step 4:** Tests PASS; `go test ./internal/hub/...` PASS; `make gen-interface-check` clean; `make lint-diff` clean.
- [ ] **Step 5:** Commit `feat(hub): live block in the session chat, redacted (FEED-05 amended, ask #1675) (#2112)`.

### Task 4: Hub reads on file events

Depends on: Task 3.

**Files:**
- Create: `internal/hub/slices/sources/chat_files.go` (watcher seam + fsnotify adapter), `internal/hub/slices/sources/chat_files_test.go`
- Modify: `internal/hub/slices/sources/session_chat.go` (`Run`, `RunDue`, `ChatTiming`), `go.mod` (fsnotify direct)

**Interfaces:**
- Produces: `type FileWatcher interface { Add(path string) error; Remove(path string) error; Events() <-chan string; Errors() <-chan error; Close() error }`; `SessionChatOptions.NewWatcher func() (FileWatcher, error)` (nil = fsnotify); `ChatTiming.Debounce` (250 ms) and `ChatTiming.MinGap` (1 s) added to `StandardChatTiming`; `Every` (3 s) now only the fallback.
- Paths per watch: **files only** — `ChatRead.Paths` (conversation files) plus the `.jsonl` of each subagent the last live block lists as running, ≤ 32; no directory watch (kqueue opens every file of a watched directory). A path that does not exist yet is retried on the next read. A new conversation after `/clear` is caught by the `Wake` loop comparing `sessionfeed.SessionConversations` (DB query + stat, no transcript read) with the watched list.

- [ ] **Step 1: Failing tests** (all under `synctest`, fake watcher):
  - `TestChatFiles_EventReadsAfterDebounce`: one event → one read 250 ms later, none before.
  - `TestChatFiles_BurstCapsReads`: 100 events in 500 ms → 1 read; events every 50 ms for 3 s → 3–4 reads; no read after the burst beyond the trailing one.
  - `TestChatFiles_NoEventNoRead`: a live watched chat with no event for 60 s → only the open read.
  - `TestChatFiles_RenameReresolves`: `Remove`/`Rename` of the watched conversation → re-resolve; the new path is added, read follows.
  - `TestChatFiles_NewConversationOnWake`: the resolved conversation list changes (new agent-session row) → the `Wake` loop swaps the watch to the new file and reads once.
  - `TestChatFiles_SubagentFileAddedAfterAgentStarts`: no subagent file at open; a read whose live block lists a running agent whose `.jsonl` appears later → the file is added on the next read and its writes trigger reads; the agent finishing removes it.
  - `TestChatFiles_HubRestartReadsOnFirstRequest`: a fresh source (no runs) gets a `session_chat_request` → one read at once and the watch armed.
  - `TestChatFiles_RealWatcherOnlyListedFiles` (real fsnotify, temp dir with 200 `.jsonl` files, 1 watched): the process's open descriptor count (`/dev/fd`) grows by ≤ 4 after arming.
  - `TestChatFiles_AddFailsFallsBackToTick`: `Add` error other than "does not exist" → reads every 3 s for that chat, logged once.
  - `TestChatFiles_WatchersClosedOnExpiryAndUnlink`: watch expiry and `dropAll` close the watcher; no read after.
  - `TestChatFiles_ReadInFlightRearms`: an event during a read gives exactly one more read.
- [ ] **Step 2:** `go test ./internal/hub/slices/sources -run ChatFiles` → FAIL.
- [ ] **Step 3:** Implement; the liveness transition stays on the `Wake` loop (reads no file).
- [ ] **Step 4:** PASS; `go test ./internal/hub/...` PASS; `go test -race ./internal/hub/slices/sources` PASS; `make lint-diff` clean.
- [ ] **Step 5:** Commit `feat(hub): session chat reads on file events, 3 s tick only as fallback (#2112)`.

### Task 5: `session-feed` prints the paths it read

Depends on: none.

**Files:**
- Modify: `cmd/workbench_session_feed.go`, `cmd/workbench_session_feed_test.go`, the `sessionfeed` feed/live JSON envelope if the paths come from there

**Interfaces:**
- Produces: JSON key `paths` (`[]string`, absolute: each conversation file read, the session's `subagents/` directory if it exists, and each subagent `.jsonl` read) on `--json` and `--live --json` output.

- [ ] **Step 1: Failing test** `TestSessionFeed_JSONPrintsPaths` (temp projects dir with a conversation and one subagent file) → `paths` holds both files and the directory.
- [ ] **Step 2:** `go test ./cmd -run SessionFeed` → FAIL. **Step 3:** implement. **Step 4:** PASS, `make lint-diff` clean.
- [ ] **Step 5:** Commit `feat(cli): session-feed prints the transcript paths it read (#2112)`.

### Task 6: Kit decodes the live block

Depends on: Task 2, Task 3.

**Files:**
- Modify: `WatchtowerKit/Sources/WatchtowerKit/Models/SessionChat.swift`, its tests (`WorkbenchMirrorFixtureTests` or a `SessionChatLiveTests`)

**Interfaces:**
- Consumes: `SessionFeedLive` (Task 2), fixture keys (Task 3).
- Produces: `SessionChat.activityLive: SessionFeedLive?`, `liveVersion: Int?`, `liveError: String?` (decodeIfPresent; dates in the hub's wire time format).

- [ ] **Step 1: Failing tests:** the updated fixture decodes all three; an old payload (no keys) decodes with all three nil; an unknown future key is ignored.
- [ ] **Step 2–4:** `make kit-test FILTER='SessionChat|WorkbenchMirrorFixture'` FAIL → implement → PASS; `make lint-swift` clean.
- [ ] **Step 5:** Commit `feat(kit): session chat carries the live block (#2112)`.

### Task 7: Phone live line and steps slot

Depends on: Task 6.

**Files:**
- Create: `WatchtowerMobile/Sources/Features/Workbench/WorkchatLiveLine.swift` (model + `WorkchatLiveLineView` + `WorkchatStepsSlotView`), `WatchtowerMobile/Tests/WorkchatLiveLineTests.swift`
- Modify: `WatchtowerMobile/Sources/Features/Workbench/WorkchatView.swift` (draw above the composer; steps toggle state per session in memory; Retry → `env.chatRequests` send now), `SessionChatViewModel.swift` (expose "a record arrived since `appeared()`"), `WatchtowerMobile/Tests/ScreenshotTourTests+WorkchatLive.swift` (real-view captures beside L1–L10)

**Interfaces:**
- Consumes: `SessionChat.activityLive/liveVersion/liveError`, `WorkchatLivePresentation.row(…)`/`stepsSlot(…)`, `ReplicaFreshness`.
- Produces: `enum WorkchatLiveLine { static func row(chat: SessionChat?, arrivedSinceOpen: Bool, working: Bool, stateAt: Date?, freshness: ReplicaFreshness?, heartbeatAt: Date?, cardShown: Bool, stepsOpen: Bool, now: Date) -> WorkchatLivePresentation.Row?; static func steps(…) -> WorkchatLivePresentation.StepsSlot? }`.

- [ ] **Step 1: Failing tests** `WorkchatLiveLineTests`, one per row of the spec §4 table plus: a step `startedAt` 30 s after `now` (clock skew) → elapsed `"0:00"`; Retry calls the injected `requestNow` once, immediately (no outbox-repeat wait); stale freshness → presentation's "Activity out of date · Ns ago", no elapsed, retry; card shown → `activity == false`; steps open → "This turn · N steps"; steps closed by default; steps close on turn end, Stop, card, conversation change; strings asserted literally (`"Loading activity…"`, `"Activity unavailable"`, `"Working…"`).
- [ ] **Step 2:** `make mobile-test MOBILE_FILTER=WorkchatLiveLineTests …` → FAIL. **Step 3:** implement (view per mockups L1–L10; `symbolEffect(.pulse)` off under Reduce Motion; middle truncation; monospaced timer). **Step 4:** PASS; `make mobile-gen` if files were added; swiftlint on `WatchtowerMobile` clean.
- [ ] **Step 5:** `make mobile-shots SHOTS_ONLY=workchat-live SIM="iPhone 17 Pro"` with real captures; compare with the mockups, note differences in the report.
- [ ] **Step 6:** Commit `feat(phone): Workchat live line and the turn's steps (#2112)`.

### Task 8: Phone agents sheet with live rows

Depends on: Task 6. May run in parallel with Task 7 (touches `WorkchatAgents.swift`, `WorkchatAgentsSheet.swift`; in `WorkchatView.swift` only the line building `WorkchatAgents(…)`).

**Files:**
- Modify: `WatchtowerMobile/Sources/Features/Workbench/WorkchatAgents.swift`, `WorkchatAgentsSheet.swift`, `WorkchatView.swift` (pass `chat.activityLive`), tests `WatchtowerMobile/Tests/WorkchatAgentsTests.swift` (or the existing test file for `WorkchatAgents`)

**Interfaces:**
- Produces: `WorkchatAgents.init(entries: [SessionChat.Entry], sessionID: Int64, live: SessionFeedLive?, now: Date)`; `Row.action: String?`, `Row.since: Date?` (from `WorkchatLivePresentation.AgentRow`).

- [ ] **Step 1: Failing tests:** with `live`, a Working row carries the agent's step summary and start; without `live` "Running" as today; an agent finished in `live` but running in the markers is in Done and not counted in the badge; badge counts from `live` when present.
- [ ] **Step 2–4:** FAIL → implement (row layout per mockup L9, `TimelineView` timer only inside visible rows) → PASS; swiftlint clean.
- [ ] **Step 5:** Commit `feat(phone): live agents in the Workchat sheet (#2112)`.

### Task 9: Mac Workchat refreshes on file events

Depends on: Task 5.

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/TranscriptWatch.swift`, `WatchtowerDesktop/Tests/Core/TranscriptWatchTests.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/SessionFeedStore.swift` (`follow(…)` uses the watch; decode `paths`), `SessionFeedPoller.swift` if the entry point moves

**Interfaces:**
- Produces: `protocol FileEventSource { func open(_ path: String, onEvent: @escaping @Sendable () -> Void) throws -> Cancellable }` (live: `DispatchSource.makeFileSystemObjectSource` with `.write, .extend, .rename, .delete`); `final class TranscriptWatch` (`update(paths:running:)`, debounce 250 ms, min gap 1 s, ≤ 32 file sources, dirs for new files, injected clock/scheduler).
- The state change re-runs `follow` (`MainFollowKey` in `SessionChatView`) → one refresh; no liveness timer. Test `SessionFeedStoreTests.testStateChangeRefreshesOnce`: re-entering `follow` with a new state kind performs exactly one refresh with the fake source idle.

- [ ] **Step 1: Failing tests** (fake source, test scheduler): event → one refresh after 250 ms; burst → ≤ 1/s; a running subagent's file gets its own source, a finished one's is closed; > 32 files → capped; `open` throws → 3 s fallback; rename/delete → re-resolve on the next read's `paths`; no source while the pane is off screen.
- [ ] **Step 2–4:** `make test-swift FILTER='TranscriptWatch|SessionFeedStore|SessionChatView'` FAIL → implement → PASS; `make lint-swift` clean.
- [ ] **Step 5:** Commit `feat(desktop): Workchat reads on transcript events, poll only as fallback (#2112)`.

### Task 10: Measure, compare, document

Depends on: Tasks 1–9.

**Files:**
- Modify: `docs/features/session-chat-feed.md` (or `mobile-companion.md`: the live block, events, FEED-05 widening), `docs/features/README.md` summary line, `docs/features/go-hub.md` (session_chat reads on events), the spec's "Promises" latency row (record the number), `docs/guide/` iPhone Workchat page per `docs/guide/WRITING.md`

- [ ] **Step 1:** Latency: on the local relay stand (`docs/features/live-link.md` "Stand numbers"), time from a transcript append to the phone record applied, 10 samples; record median/p90 in the spec.
- [ ] **Step 2:** Energy: Instruments energy log on the simulator or device, chat open 10 min during a busy turn, before (main) vs after; record CPU and wakeups in the spec.
- [ ] **Step 3:** Real views vs mockups L1–L10 side by side; list any difference and fix or justify.
- [ ] **Step 4:** Docs above; `go test ./docs/guide` PASS.
- [ ] **Step 5:** Commit `docs: phone Workchat live line — notes, numbers, guide (#2112)`.

## Parallel lanes

| Wave | Tasks (each in its own worktree off `umbrella/phone-workchat`) |
|---|---|
| 1 | T1, T2, T5 |
| 2 | T3 (after T1), T9 (after T5) |
| 3 | T4 (after T3), T6 (after T2, T3) |
| 4 | T7, T8 (after T6) |
| 5 | T10 |

The controller merges each passed task into the umbrella locally; the full gate (every `.github/workflows/*.yml` job run locally) runs before each merge per the workbench procedure.
