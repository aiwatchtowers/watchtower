# Go hub — Phase 1b: handlers, slices, publishing on change, session-host v2, Go session start Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete Phase 1 of the Go hub: every Swift hub handler and slice has a Go twin with the same payloads; slices publish on change; phone lines reach a PTY only through a typed-never-submitted `Deliver` inside `session-host` (protocol v2); sessions start and stop in Go through `watchtower workbench session start|stop` — all verified in a separate test workspace beside the Swift hub, with plaintext canaries over everything that leaves the hub.

**Architecture:** On top of Plan 1a's seams (`actions.Dispatcher.Register`, `slices.Source`, `slices.Publisher.PublishSoon`, `hub.Options.Register`/`Sources`/`RecordingsDir`, `identity.Keyring.SealLocal`/`OpenLocal`, sidecar migrations from `00003`). New: `internal/sessionstate` (Go port of `SessionAgentStatus`, dual path), `internal/hub/actions/handlers` (handlers over a `SessionPort` interface, so they are built and reviewed before the PTY side exists), `internal/hub/slices/sources` (DB-backed and runner-fed slices), `internal/hub/slices/change.go` (`PRAGMA data_version` poll + nudge table), `internal/hub/platform` (owner-away and keep-awake: cgo on darwin, stubs on linux), `internal/sessionhost` protocol v2 (non-attaching `InputTo`, `Deliver` with a re-check round trip, prompt-state tracking, `DeliveryEvent` broadcast) plus a Go client, `internal/sessionstart` (port of `TerminalLaunch` and `SessionStartPlacement`, row creation, launch in `session-host`), and the `SessionPort` that joins them.

**Tech Stack:** Go 1.26, cgo on darwin (CoreGraphics `CGSessionCopyCurrentDictionary` / `CGEventSourceSecondsSinceLastEventType`, IOKit `IOPMAssertionCreateWithName`), `github.com/creack/pty` (already used by `session-host`), SQLCipher `database/sql` through `internal/db`; Swift only for dual-path fixture tests (`make test-swift FILTER=…`, `make kit-test FILTER=…`).

**Spec:** `docs/superpowers/specs/2026-10-31-go-hub-design.md` (§8 p. 4, 4a, 4b except the one-time v1 restart step, §9, §10 recordings, §11 except `service install`, §13 canaries and "one test per branch", §14 row 1). Prerequisite: Plan 1a (`docs/superpowers/plans/2026-10-31-go-hub-phase-1.md`) merged. Contracts: `docs/inventory/workbench.md` PROJ-12, PROJ-16, PROJ-18, PROJ-20, PROJ-21; `docs/inventory/session-feed.md` FEED-01..05; `docs/inventory/policy.md` POLICY-03 (`MobileSync`).

## Global Constraints

All of Plan 1a's Global Constraints hold (byte compatibility, zone bytes, E2E red line, phase-1 isolation, FILES-01, hygiene, migrations, inner loop). In addition:

- **Guard tests move one-to-one** (spec §8 p. 4, §13): every Go twin of a PROJ-12/16/21, FEED-05 or POLICY-03 guard keeps the Swift test's meaning and its `TestProj12_`/`TestProj16_`/`TestProj21_`/`TestFeed05_`/`TestPolicy03_` name (Swift `testProj16_AnUnallowedDeviceTypesNothing` → Go `TestProj16_AnUnallowedDeviceTypesNothing`). Swift guards stay in place in phase 1 (the Swift hub still runs); they are removed only in phase 3's deletion PR with the mapping listed. A guard is never relaxed to make a port pass.
- **Typed-never-submitted delivery** (PROJ-12): one bracketed paste `ESC[200~` … `ESC[201~` (bytes `1B 5B 32 30 30 7E` / `1B 5B 32 30 31 7E`) with no control character inside (line breaks kept only when `keep_line_breaks`; format characters only when `keep_format`); then, after the profile's pause, one Return written on its own — only while the prompt held no owner draft and no earlier line waits for its Return, both before and after the pause, the caller's re-check succeeded, and the run is unchanged. Profiles: Claude `submit 0x0D`, no extra newline key, `pasteSettle 150 ms`, `submitSettle 500 ms`; Codex `submit 0x0D`, `newline 0x0A` (Ctrl+J), same pauses. Owner input: a submitting Return = a plain CR not right after ESC whose last printable input before it (escape sequences and paste brackets skipped) is not `\`; anything else leaves a draft; input while a permission dialog shows changes nothing.
- **`Deliver` outcomes:** `submitted | typed | held(reason) | no_session | no_paste_mode`. With `hold_if_prompt_text` (every phone line, PROJ-16) the **host** answers `held(prompt_has_text)` without pasting when the prompt holds the owner's draft, a pending Return or a line left typed; hook-fed holds (`needs_approval`, `agent_busy`, `state_unknown`) are the caller's, decided before the call. Without it (Desktop's composer) a line beside existing text is pasted and left `typed`. `no_paste_mode` (bracketed paste off) becomes `copied` (`pbcopy`) only on a **desktop host** — Desktop's heartbeat (`watchtower hub desktop heartbeat`, every 30 s, fresh for 90 s, written by the hub) is fresh — else `cannot_type` with the message "This session can't take typed text right now" (a CLI-only Mac never has the heartbeat).
- **PROJ-16 values:** phone text 1–4000 characters after `SessionInputText` sanitising (CRLF and every line break or control character → one space, format characters kept, trimmed), else `invalid_params`; finish line exactly "Please wrap up: update the board, then call finish_session with a short summary."; held reasons `agent_busy | needs_approval | prompt_has_text | state_unknown`; held line lifetime 24 h; no second line until a hook reported after the last submit, at most `submitSettle` 30 s.
- **PROJ-21 values:** interrupt max age 120 s; messages "Answered on the Mac", "Too late — answer on the Mac", "This session no longer exists on the Mac", "A permission prompt may be open — answer it on the Mac or with Deny", "This session is not running on the Mac", "The agent is not working right now"; `PermissionAllowBlock` (clipped summary, settings-path edits) = Deny only; permission request expiry 86 400 s.
- **FEED-05:** `session_chat` only for a session (or subagent) the phone asked for in the last 5 minutes and only while a phone is linked; at most 300 entries, 4000 characters per text, 600 000 bytes; payload in memory only (never `watchtower.db`, never the sidecar).
- **Publishing on change (§9):** nudge after every applied action through one table `action kind → slice kinds`; `PRAGMA data_version` on a dedicated read connection every 250 ms while a phone was in touch in the last 10 minutes, else every 1 s; debounce 150 ms trailing; full diff every 60 s; spacing 150 ms on the relay; runner-fed slices call Go functions directly (no CLI spawn).
- **`session-host`:** socket `<tmp>/watchtower-sh-<first 8 hex of SHA-256("com.watchtower.desktop")>.sock`; scope = first 16 hex of SHA-256 of the standardized database path; v2 is additive (hello carries the version; a v2 host accepts v1 and v2 hellos and answers `version: 2`); a newer attach takes a pane over, `InputTo` and `Deliver` never attach. Owner-requested stop = a host `Stop` request (host: SIGHUP to the process group → 3 s → SIGKILL); its `Exit` frame carries `requested: true` (Desktop maps it to `closedByApp` in phase 3: no PROJ-18 cleanup); a natural exit carries no `requested`. **Phase-1 socket override:** `WATCHTOWER_SESSION_HOST_SOCKET` — the test workspace never reaches the real host the Desktop uses.
- **Recordings (§8 p. 4a):** the Desktop heartbeat is also the transcriber signal: fresh → intake; seen once but stale → non-final `held`, no audio written; never seen (headless host, CLI-only Mac) → final `failed(not_supported)`. Files 0600 in `hub.Options.RecordingsDir` = `WATCHTOWER_HUB_DIR/recordings` in the phase-1 test workspace (never `config.AppSupportDir()`; the live folder is phase 3's).
- **New sidecar columns hold no content** (spec §8 p. 4a): ids, counters, timestamps, hashes and error classes only; anything with content (record names with text, error text, milestone text, report caches, alert text) is sealed with `identity.Keyring.SealLocal` (Plan 1a Task 6) or not stored. Go also writes the existing content columns `session_milestones.text` and `session_reports.payload` sealed. The canary's plaintext allowlist stays exactly `held_session_lines.line` and `relay_processed.echo`.
- **A failed `session start` keeps a worktree it created** (spec §11): nothing deleted on failure; `workbench cleanup` lists it.
- **No in-process change hook:** the `data_version` poll (250 ms while a phone was in touch, 1 s otherwise) plus the nudge after apply cover the daemon's own writes (spec §9).
- **Owner-away (darwin):** screen locked, or 3 minutes without input, or no console UI session; linux: always away, no keep-awake.

## Review Focus

1. **A phone line over the owner's typing in another client.** The owner types in Desktop's pane while the hub delivers into the same session: the host must see the draft and leave the line typed. → Task 12 `TestDeliverWhileOwnerTypesInAnotherClientLeavesTyped`.
2. **The re-check never answers.** The hub crashes or stalls between paste and Return: no Return may follow, the pending-Return mark must clear. → Task 13 `TestHoldIfPromptTextHoldsOverAnOwnerDraft` (Desktop client types `abc` as `Input` frames, then `Deliver{HoldIfPromptText}` → `held(prompt_has_text)`, zero bytes written after the draft), `TestHoldIfPromptTextHoldsOverAPendingReturn` (a second `Deliver` during the first one's pause), `TestHoldIfPromptTextHoldsOverALineLeftTyped`, `TestWithoutHoldIfPromptTextALineBesideTheDraftIsTyped` (the composer's behaviour: pasted, `typed`, no CR), `TestDeliverCheckTimeoutLeavesLineTyped`.
3. **The run changes during the pause.** A relaunch of the same row between paste and Return must get no Return. → Task 13 `TestProj12_ARelaunchDuringThePauseGetsNoReturn`.
4. **Plaintext audio without a transcriber.** → Task 5 `TestRecordingHeldWithoutTranscriberWritesNoFile`, `TestRecordingOnAHostThatNeverHadDesktopFailsNotSupported`.
5. **Debounce starvation and half-started sessions.** Continuous writes must still publish within a bound; a session whose launch fails after its row exists must not sit in **Starting…**. → Task 10 `TestContinuousWritesStillPublishWithinOneSecond`; Task 15 `TestSessionStartLaunchFailureMarksTheRow`.

---

### Task 1: `internal/sessionstate` — the session agent status in Go (dual path)

**Files:**
- Create: `internal/sessionstate/status.go`
- Create: `internal/sessionstate/testdata/status_cases.json`
- Test: `internal/sessionstate/status_test.go`
- Create: `WatchtowerDesktop/Tests/Core/SessionAgentStatusFixtureTests.swift`

**Interfaces:**
- Produces:
  ```go
  package sessionstate
  type Row struct{ ID int64; Kind string; AgentState, AgentStateAt, FinishedAt, AgentFailedAt, AgentBackgroundAt, ChatQuestionAt, AgentCwdAt *string; AgentBackground *int; OpenAsks, OpenQuestionAsks, OpenReviewAsks int; RunStartedAt string }
  type State string // stopped, finished, waiting_for_you, ready_to_check, error, working, agents_working, needs_approval, running, marked_idle
  func Resolve(r Row, now time.Time) State
  func HooksReported(r Row) bool          // a state or the run's mark of the current run
  func IsIdle(s State) bool; func IsWorking(s State) bool; func NeedsApproval(s State) bool
  func Load(ctx context.Context, q db.Querier, sessionID int64) (Row, error)
  ```
- **Depends on:** none

- [ ] **Step 1: Fixture** — cases covering every branch of `SessionAgentStatus.swift` (stored states, the run's mark with no turn, an earlier run's state, background agents, `approval` outranking Agents working, failed, finished, unknown stored value).
- [ ] **Step 2: Failing tests:** Go `TestStatusFixtures` (each case → `Resolve`, `HooksReported`, `IsIdle`, `IsWorking`); Swift `testEveryGoFixtureCaseResolvesTheSame` (reads `../../../internal/sessionstate/testdata/status_cases.json` from `Tests/Core`).
- [ ] **Step 3:** `go test ./internal/sessionstate`, `make test-swift FILTER=SessionAgentStatusFixtureTests` → FAIL.
- [ ] **Step 4: Implement.**
- [ ] **Step 5:** → PASS; `make lint-diff`, `make lint-swift`.
- [ ] **Step 6: Commit** `sessionstate: Go twin of SessionAgentStatus pinned by a shared fixture`.

### Task 2: Handlers — ask answers, board, automation runs

**Files:**
- Create: `internal/hub/actions/handlers/{deps.go,port.go,ask.go,board.go,automation.go,nudge.go}`
- Test: `internal/hub/actions/handlers/{ask_test.go,board_test.go,automation_test.go}`

**Interfaces:**
- Consumes: `actions.Dispatcher`, `asks.DeliveryLine`, `db.DB` workbench writes (the same queries the MCP tools use), `sessionstate`.
- Produces:
  ```go
  package handlers
  type DeliverRequest struct{ SessionID int64; Run uint64; Text string; KeepLineBreaks, KeepFormat, HoldIfPromptText bool; Settle time.Duration; Check func(ctx context.Context) CheckAnswer } // every phone line sets HoldIfPromptText
  type CheckAnswer struct{ Fresh, CanSubmit, AnswersDialog bool }
  type DeliverResult struct{ Outcome string /* submitted|typed|held|no_session|no_paste_mode */; Reason string /* prompt_has_text when the host held it */ }
  type LiveRun struct{ SessionID int64; Run uint64; Agent string; Exited bool }
  type StartRequest struct{ Workbench int64; Target *int64; Agent, Place, Brief string }
  type StartResult struct{ SessionID int64; State string }
  type SessionPort interface {
      Live(ctx context.Context, sessionID int64) (LiveRun, bool, error) // from session-host's non-attaching list, this workspace's scope only
      Deliver(ctx context.Context, r DeliverRequest) (DeliverResult, error)
      Interrupt(ctx context.Context, sessionID int64, run uint64) error  // one Esc through InputTo
      Start(ctx context.Context, r StartRequest) (StartResult, error)
      Stop(ctx context.Context, sessionID int64) error // a host Stop request: its Exit carries requested: true
  }
  type Deps struct{ DB *db.DB; Store *state.Store; Sessions SessionPort; DesktopHost func() bool /* Desktop heartbeat fresh (Task 5) */; Clipboard func(string) error /* pbcopy; used only while DesktopHost() */; RecordingsDir string; Clock func() time.Time; Policy func() string }
  func Register(d *actions.Dispatcher, deps Deps) // every kind of this plan; Tasks 3–5 add theirs here
  var NudgeTable = map[string][]slices.Kind{ /* action kind → slice kinds, e.g. "ask_answer": {"owner_ask","ask_alert"}, "board_*": {"workbench","workbench_target","workbench_comment"}, "session_*": {"terminal_session","session_timeline"} … */ }
  ```
  Limits from `BoardHandlers`: body 4000, title 200, intent 4000; handler timeout 30 s with the Swift timeout messages.
- **Depends on:** Task 1

- [ ] **Step 1: Failing tests** — Go twins of every behavioural test in `AskAnswerHandlerTests`, `BoardHandlersTests`, `AutomationRunHandlerTests` (same names in Go casing), plus `TestNoPasteModeIsCopiedOnADesktopHost` (heartbeat fresh: clipboard called, outcome `copied`), `TestNoPasteModeIsCannotTypeOnACLIOnlyMac` (no heartbeat ever: clipboard never called, `cannot_type` with "This session can't take typed text right now"), `TestAskAnswerIsStoredBeforeAnythingIsDelivered` (the guarded `UPDATE … WHERE status='open'` commits before `Deliver` is called; zero rows → `ask_not_open`, nothing delivered) and `TestNudgeTableCoversEveryRegisteredKind`.
- [ ] **Step 2:** `go test ./internal/hub/actions/handlers` → FAIL.
- [ ] **Step 3: Implement** (deliveries go through `SessionPort.Deliver` with `Settle = submitSettle 500 ms`; a `no_paste_mode` answer becomes `copied` only while `DesktopHost()`, else `failed cannot_type` with the pinned message).
- [ ] **Step 4:** → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `hub/handlers: ask answers, board, automation runs`.

### Task 3: Handlers — session input, cancel, finish request, start, stop (PROJ-16)

**Files:**
- Create: `internal/hub/actions/handlers/{session_input.go,held_lines.go,session_start.go}`
- Test: `internal/hub/actions/handlers/{session_input_test.go,session_start_test.go}`

**Interfaces:**
- Consumes: `SessionPort`, `sessionstate`, sidecar `held_session_lines`, `devices` grants.
- Produces: kinds `session_input`, `session_input_cancel`, `session_finish_request`, `session_start`, `session_stop`; `func SanitizeInput(s string) (string, bool)` (Kit `SessionInputText` rule; pinned by Kit `SessionInputTextTests`' cases copied into a Go table).
- **Depends on:** Task 2

- [ ] **Step 1: Failing PROJ-16 guards** (Go twins, same meaning): `TestProj16_AnUnallowedDeviceTypesNothing`, `TestProj16_AWorkingClaudeSessionTakesTheLineButNeverAPrompt` (applied echo `while_busy: true`), `TestProj16_AWorkingCodexSessionStillHoldsTheLine`, `TestProj16_NeedsApprovalNeverGetsAPhoneLine`, `TestProj16_AHeldLineExpiresAfter24h`, `TestProj16_AnEditedBriefFromAnUnallowedDeviceIsIgnored`, `TestProj16_RevokeFailsHeldLines`, `TestProj16_AnUnlinkedDeviceTypesNothing`; and every supporting test listed under PROJ-16 for `SessionInputHandlersTests` and `SessionStartHandlerTests` (held line survives a hub restart and goes once; a line interrupted mid-paste is `outcome_unknown` after restart; cancel only by the sending phone; a second line waits for a hook after the first submit or the 30 s cap; …). "The session is live" and "the same run" read `SessionPort.Live` (ask #807). Every phone line sets `HoldIfPromptText`; a host answer `held(prompt_has_text)` is echoed `held` with that reason and retried like the hook-fed holds (`TestHostHeldPromptTextIsEchoedHeldAndRetried`). `TestProj16_ADraftHoldsTheLineAndNothingIsPasted` is **not** here: it needs a real host with a real owner draft and lives in Task 15.
- [ ] **Step 2:** `go test ./internal/hub/actions/handlers` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `hub/handlers: phone lines and session start/stop under PROJ-16`.

### Task 4: Handlers — permission answers, Interrupt, report and chat requests (PROJ-21)

**Files:**
- Create: `internal/hub/actions/handlers/{permission.go,allowrule.go,report_request.go,chat_request.go}`
- Create: `WatchtowerKit/Tests/Fixtures/permissions/allow_block_cases.json`
- Modify: `WatchtowerKit/Tests/WatchtowerSyncTests/PermissionAllowRuleTests.swift` (read the shared cases too)
- Test: `internal/hub/actions/handlers/{permission_test.go,allowrule_test.go,requests_test.go}`

**Interfaces:**
- Produces: kinds `permission_answer`, `session_interrupt`, `session_report_request`, `session_chat_request`; `func AllowBlock(toolName, summary string, clipped bool) (string, bool)` (Go twin of the Kit's `PermissionAllowBlock`); the chat request opens a 5-minute watch in the in-memory runner registry Task 8 reads (`ChatWatches` interface defined here).
- **Depends on:** Task 2

- [ ] **Step 1: Failing PROJ-21 guards:** `TestProj21_AnUngrantedDeviceCannotAnswer`, `TestProj21_AnAllowDecidesThePendingRowOnce` (CAS; second answer `not_pending`), `TestProj21_RevokeBlocksAnswers`, `TestProj21_AnAnswerTypesNothing` (fake port records zero `Deliver`/`InputTo` calls), `TestProj21_AClippedRequestCannotBeAllowed`, `TestProj21_ASettingsPathEditCannotBeAllowed`; supporting twins of `PermissionAnswerHandlersTests` (interrupt one Esc while working / agents working; refused at needs approval, with a pending request, when idle; stale > 120 s expires; needs the typing grant; Codex sessions `not_found`), `TestAllowBlockSharedCases` (Go and Kit read `allow_block_cases.json`), report/chat request twins.
- [ ] **Step 2:** `go test ./internal/hub/actions/handlers`, `make kit-test FILTER=PermissionAllowRuleTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** → PASS; `make lint-diff`, `make lint-swift`.
- [ ] **Step 5: Commit** `hub/handlers: permission answers and Interrupt under PROJ-21, report/chat requests`.

### Task 5: Recording intake, the job queue and `hub recording …`

**Files:**
- Create: `internal/hub/state/migrations/00003_recording_jobs.sql`
- Create: `internal/hub/actions/handlers/recording.go`, `internal/hub/state/recordings.go`
- Create: `cmd/hub_recording.go`
- Test: `internal/hub/actions/handlers/recording_test.go`, `cmd/hub_recording_test.go`

**Interfaces:**
- Produces:
  - `00003`: `recording_jobs(upload_id TEXT PRIMARY KEY, device_id TEXT NOT NULL, status TEXT NOT NULL CHECK (status IN ('queued','claimed','done','failed')), transcript_id INTEGER, error_class TEXT, created_at REAL NOT NULL, claimed_at REAL, finished_at REAL)` — no record name, path or error text (the audio path is derived: `<RecordingsDir>/<upload_id>.<ext>`); `hub_meta.desktop_at` (last heartbeat) and `hub_meta.desktop_seen` (`1` once any heartbeat arrived).
  - `func (s *Store) DesktopHost(now time.Time) (fresh, everSeen bool, err error)` (fresh = ≤ 90 s) — the single signal for "desktop host" (`Deps.DesktopHost`) and "transcriber present".
  - `recording_upload` intake: fresh → download the attachment, `secure.DecryptAsset` streaming into `<RecordingsDir>/<upload_id>.<ext>` 0600, echo `received`, queue `queued`; seen once but stale → echo `held`, write nothing, retry each pass; never seen → final `failed` reason `not_supported`, nothing written.
  - CLI (pinned keys): `hub desktop heartbeat [--json]` → `{"desktop_at"}` (Desktop calls it every 30 s in phase 3; refused under an agent marker — Desktop never runs under one, so an agent cannot fake a desktop host; test `TestDesktopHeartbeatRefusedUnderAnAgentMarker`; named in the PR's security review); `hub recording claim --upload <id> --json` → `{"upload_id","audio_path","status"}`; `hub recording finish --upload <id> [--transcript <id>] [--error <class>] --json` → `{"upload_id","status","transcript_id"}`. The Desktop reads the queue read-only and never writes the sidecar.
- **Depends on:** Task 2

- [ ] **Step 1: Failing tests:** `TestRecordingHeldWithoutTranscriberWritesNoFile` (Review Focus 4: heartbeat seen once, now stale → no file under the recordings dir, echo `held`, phone keeps its audio), `TestRecordingOnAHostThatNeverHadDesktopFailsNotSupported` (final `failed(not_supported)`, no file), `TestDesktopHeartbeatFreshFor90s` (89 s fresh, 91 s stale, `everSeen` stays true), `TestRecordingsGoUnderTheHubDirInPhase1` (`hub.FromEnv` sets `RecordingsDir = WATCHTOWER_HUB_DIR/recordings`; nothing is created under `config.AppSupportDir()`), `TestRecordingJobsHoldNoContent` (an error with text is stored as its class only), `TestRecordingReceivedWhenTranscriberFresh` (file 0600, decrypted bytes equal, digest checked), Go twins of `RelayProcessorRecordingUploadTests` behaviours (missing audio message, too large), `TestRecordingClaimFinishJSONKeys`, `TestDesktopHeartbeatJSONKeys`, `TestFILES01_RecordingLogsNoNames` (`logcanary`).
- [ ] **Step 2:** `go test ./internal/hub/actions/handlers ./internal/hub/state`, `go test ./cmd -run TestHubRecording` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `hub: Desktop heartbeat, recording intake (held / not_supported), hub recording claim|finish`.

### Task 6: Slices A — workbench, targets, comments, terminal sessions, session timeline

**Files:**
- Create: `internal/hub/slices/sources/{workbench.go,target.go,comment.go,terminal_session.go,timeline.go,clip.go}`
- Test: `internal/hub/slices/sources/{workbench_test.go,target_test.go,terminal_session_test.go,timeline_test.go}`

**Interfaces:**
- Produces: `func Workbench(db *db.DB) slices.Source` and siblings, each a capped projection (never `SELECT *`) equal to the Swift slice; `session_milestones` written by the timeline source into the sidecar with `text` sealed by `Keyring.SealLocal` (label `session_milestones.text`); test `TestMilestoneTextIsSealedInTheSidecar`.
- **Depends on:** Task 1

- [ ] **Step 1: Failing tests:** for each kind, `Test<Kind>MatchesKitFixtureKeys` (payload keys equal `WatchtowerKit/Tests/Fixtures/workbench/<kind>.json`'s), plus Go twins of each behavioural test in `WorkbenchSliceTests`, `WorkbenchTargetSliceTests`, `TerminalSessionSliceTests`, `SessionTimelineSliceTests` (same assertions; the terminal session state through `sessionstate.Resolve`).
- [ ] **Step 2:** `go test ./internal/hub/slices/sources` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `hub/slices: workbench family, terminal sessions, timeline`.

### Task 7: Slices B — asks, permission requests, work alerts; owner-away and keep-awake

**Files:**
- Create: `internal/hub/slices/sources/{owner_ask.go,permission_request.go,work_alert.go}`
- Create: `internal/hub/platform/{away_darwin.go,away_linux.go,awake_darwin.go,awake_linux.go,platform.go}`
- Test: `internal/hub/slices/sources/{owner_ask_test.go,permission_request_test.go,work_alert_test.go}`, `internal/hub/platform/platform_test.go`

**Interfaces:**
- Produces:
  ```go
  package platform
  type Away interface{ Away() (bool, error) } // darwin: locked || idle ≥ 3 min || no console session; linux: always true
  func NewAway() Away
  type Awake interface{ Hold(reason string) (release func(), err error) } // darwin: IOPMAssertionCreateWithName; linux: no-op
  func NewAwake() Awake
  ```
  `work_alert`/`ask_alert` per `WorkAlertSlice` (lifetime 7 days, workbench name ≤ 60, session title ≤ 60, body ≤ 120, the `work_alerts` ledger in the sidecar holds keys like `ask-<id>`/`perm-<id>` and timestamps only — no alert text; the record itself is sealed with the alert key through `Sealer.Alert`; test `TestWorkAlertLedgerHoldsNoText`); permission requests published only while pending on a live board session, expiring older than 86 400 s on the pass.
- **Depends on:** Task 1

- [ ] **Step 1: Failing tests:** `TestProj21_GoClippedFlagReachesTheWire`, twins of `OwnerAskSliceTests`, `PermissionRequestSliceTests` (only pending rows of live board sessions; old/orphan rows expire on the pass; expiry age = the hook timeout), `WorkAlertSliceTests`; `TestAwayLinuxIsAlways`, `TestAwakeLinuxIsNoop`; darwin-only `TestAwayDarwinReadsIdle` behind a seam (no real lock in CI).
- [ ] **Step 2:** `go test ./internal/hub/slices/sources ./internal/hub/platform` → FAIL.
- [ ] **Step 3: Implement**; `GOOS=linux GOARCH=arm64 go build ./internal/hub/...` must pass (no cgo on linux paths).
- [ ] **Step 4:** → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `hub/slices: asks, permission requests, work alerts; owner-away and keep-awake`.

### Task 8: Slices C — runner-fed session chat, session report, git refresher (FEED-05)

**Files:**
- Create: `internal/hub/slices/sources/{session_chat.go,session_report.go,git_refresher.go}`
- Test: `internal/hub/slices/sources/{session_chat_test.go,session_report_test.go,git_refresher_test.go}`

**Interfaces:**
- Consumes: `internal/sessionfeed` reader (the one `workbench session-feed --json` uses), `internal/sessionreport`, `internal/workbenchgit` — called in-process, never by spawning the CLI; `handlers.ChatWatches`.
- Produces: `func SessionChat(w handlers.ChatWatches, db *db.DB) slices.Source` (in-memory payloads, caps 300 / 4000 / 600 000, record `session_chat-<session>` or `session_chat-<session>-<agent>`), `SessionReport` (`session_reports.payload` cache sealed with `Keyring.SealLocal`, label `session_reports.payload`; test `TestSessionReportCacheIsSealed`), `GitRefresher` (every 120 s, min spacing 30 s, timeout 20 s, idle 15 s).
- **Depends on:** Task 4

- [ ] **Step 1: Failing FEED-05 guards:** `TestFeed05_NoWatchPublishesNothing`, `TestFeed05_ExpiredWatchLeavesWindow` (record deleted after 5 min), `TestFeed05_UnlinkedPhoneDropsPayloadsForGood`, `TestFeed05_MatchesKitFixtureKeys`, `TestFeed05_OnlyFeedKindsPublished`; `TestSessionChatCaps` (301 entries → 300; 4001-char text → 4000; payload ≤ 600 000 bytes); `TestSessionChatNeverWritesTheSidecarOrDB`; twins of `SessionReportSliceTests` and the git refresher's timing tests.
- [ ] **Step 2:** `go test ./internal/hub/slices/sources` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `hub/slices: session chat, report and git refresher in-process (FEED-05)`.

### Task 9: Slices D — calendar, meeting transcripts, recording jobs; `MobileSync` scopes

**Files:**
- Create: `internal/hub/slices/sources/{calendar.go,meeting_transcript.go,recording_job.go,registry.go}`
- Test: `internal/hub/slices/sources/{calendar_test.go,meeting_transcript_test.go,recording_job_test.go,registry_test.go}`

**Interfaces:**
- Produces: the three sources (same windows, caps and recap rules as the Swift slices) and `func All(db *db.DB, st *state.Store, w handlers.ChatWatches, mode string) []slices.Source` — `workbench_only` keeps the workbench family, terminal sessions, timeline, asks, permission requests, alerts, chat, report; `allowed` adds calendar, transcripts, recording jobs; `device_grant`/`heartbeat` always. This is what `hub.Options.Sources` returns.
- **Depends on:** Task 5, Task 6, Task 7, Task 8

- [ ] **Step 1: Failing tests:** twins of `CalendarEventSliceTests`, `MeetingTranscriptSliceTests`, `RecordingJobSliceTests`; `TestWorkbenchOnlyPublishesNoCalendarOrTranscripts`; `TestPolicyOffToWorkbenchOnlyStartsRestricted` (twin of `testOffToWorkbenchOnlyStartsTheHubRestricted`).
- [ ] **Step 2:** `go test ./internal/hub/slices/sources` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `hub/slices: calendar, transcripts, recording jobs; MobileSync scopes`.

### Task 10: Publishing on change — `data_version` poll, nudges, debounce, spacing

**Files:**
- Create: `internal/hub/slices/change.go`
- Modify: `internal/hub/slices/publisher.go`, `internal/hub/hub.go` (wire the poll, the nudge table and the sources)
- Test: `internal/hub/slices/change_test.go`

**Interfaces:**
- Produces:
  ```go
  type ChangeWatch struct{…}
  func NewChangeWatch(conn *sql.Conn, tables map[string][]Kind, touched func() time.Time, clock func() time.Time) *ChangeWatch // dedicated read connection
  func (w *ChangeWatch) Run(ctx context.Context, dirty func(kinds ...Kind)) error // 250 ms while touched() within 10 min, else 1 s; on a data_version change marks every DB-backed kind dirty
  const ActivePoll = 250 * time.Millisecond; const IdlePoll = time.Second; const ActiveWindow = 10 * time.Minute // MaxDebounceWait (1 s) is Plan 1a Task 13's publisher constant
  ```
  In-process writes need no hook: the daemon's other pool connections bump `data_version` too (spec §9 allows "where cheap"); the nudge after apply covers the hub's own handlers immediately.
- **Depends on:** Task 9

- [ ] **Step 1: Failing tests:** `TestAWriteByAnotherConnectionPublishesWithinOnePoll`, `TestPollIs250msWhileAPhoneWasInTouchElse1s`, `TestNudgeAfterApplyPublishesTheMappedKinds`, `TestFullDiffEvery60sCatchesClockValues`, `TestContinuousWritesStillPublishWithinOneSecond` (Review Focus 5: a write every 100 ms for 3 s still yields a cycle at least every `slices.MaxDebounceWait`, the 1a constant, now with the real DB sources), `TestAKindIsSavedAtMostOncePerSpacing` (relay 150 ms, with the real sources).
- [ ] **Step 2:** `go test ./internal/hub/slices` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** → PASS; measure the idle poll cost once (CPU of an idle daemon with a linked memfake phone, 5 min, `ps -o %cpu`) and write the number into the commit message (the spec's "measured before the phase ends").
- [ ] **Step 5: Commit** `hub/slices: publish on change via data_version poll and nudges`.

### Task 11: `session-host` protocol v2 frames and the Go client

**Files:**
- Modify: `internal/sessionhost/frame.go`, `internal/sessionhost/server.go`, `internal/sessionhost/session.go`
- Create: `internal/sessionhost/client.go`, `internal/sessionhost/paths.go`, `internal/sessionhost/ensure.go`, `internal/sessionhost/testdata/paths.json`
- Modify: `cmd/session_host.go` (default socket from `WATCHTOWER_SESSION_HOST_SOCKET` when `--socket` is absent)
- Test: `internal/sessionhost/{v2_test.go,client_test.go,paths_test.go}`
- Create: `WatchtowerDesktop/Tests/Core/SessionHostPathsFixtureTests.swift`

**Interfaces:**
- Produces:
  ```go
  const ProtocolVersion = 2
  const ( InputTo FrameType = 0x08; Deliver FrameType = 0x09; Delivered FrameType = 0x89
          DeliverCheck FrameType = 0x8A; DeliverCheckReply FrameType = 0x0A; PromptHint FrameType = 0x0B; DeliveryEvent FrameType = 0x8B
          Stop FrameType = 0x0C; Stopping FrameType = 0x8C )
  type StopReq struct{ Row int64 `json:"row"`; Run string `json:"run"`; Launch uint64 `json:"launch"` } // host: SIGHUP to the group → 3 s → SIGKILL; marks the run requested
  type ExitMsg struct{ Code *int `json:"code"`; Requested bool `json:"requested,omitempty"` }   // v1 field kept; requested only after a Stop request
  type LaunchReq struct{ /* v1 fields */ Agent string `json:"agent,omitempty"`; Detach bool `json:"detach,omitempty"` } // agent "claude" | "codex" | "" (shell); detach: launch without binding this connection (the hub never attaches)
  type SessionInfo struct{ /* v1 fields */ Launch uint64 `json:"launch,omitempty"`; Agent string `json:"agent,omitempty"` } // launch = per-row counter kept by the host
  type InputToReq struct{ Row int64 `json:"row"`; Run string `json:"run"`; Launch uint64 `json:"launch"`; Data []byte `json:"data"` } // never binds the connection
  type PromptHintMsg struct{ Row int64; Run string; Dialog bool } // a client that reads hook state tells the host a permission dialog is up
  const BundleID = "com.watchtower.desktop"
  func SocketPath(bundleID, tempDir string) string; func Scope(dbPath string) string
  func DefaultSocket() string // WATCHTOWER_SESSION_HOST_SOCKET, else SocketPath(BundleID, os.TempDir())
  type Client struct{…}
  func Dial(ctx context.Context, socket string) (*Client, error) // hello v2; refuses a host answering version 1 (ErrHostV1)
  func (c *Client) List(ctx context.Context) ([]SessionInfo, error)
  func (c *Client) Launch(ctx context.Context, r LaunchReq) (SessionInfo, error) // the hub always sets Detach
  func (c *Client) InputTo(ctx context.Context, r InputToReq) error
  func (c *Client) PromptHint(ctx context.Context, m PromptHintMsg) error
  func (c *Client) Forget(ctx context.Context, row int64, run string) error
  func (c *Client) Stop(ctx context.Context, r StopReq) error // returns once Stopping is answered; the Exit follows on the attached clients and in List
  func Ensure(ctx context.Context, socket, exe string) error // spawn detached `session-host --socket` when nothing answers; never replaces a v1 host
  var ErrHostV1 = errors.New("sessionhost: a v1 host is running")
  ```
  `Deliver` frames are declared here and implemented in Task 13. The v1 `Input` path (an attached client's keystrokes) is unchanged and now also feeds the prompt state (Task 12).
- **Depends on:** none

- [ ] **Step 1: Failing tests:** `TestHelloAcceptsV1AndV2AnswersV2`, `TestInputToNeverAttaches` (an attached client keeps its binding and receives the echoed output; a second client's `InputTo` does not take it over), `TestInputToWrongRunOrLaunchIsRefused`, `TestListIsNonAttaching`, `TestSessionHost20_SessionSurvivesClientDisconnect` (unchanged, still passes), `TestLaunchCounterSurvivesClientReconnect`, `TestClientRefusesV1Host`, `TestRequestedStopExitCarriesRequested` (a `Stop` → `Exit{requested:true}` to the attached client and `Exited` in List; a stub ignoring SIGHUP is killed after 3 s, group reaped in `t.Cleanup`), `TestNaturalExitHasNoRequested`, `TestEnsureNeverReplacesAV1Host`, `TestPathsFixture` (Go) + Swift `testGoAndSwiftAgreeOnSocketAndScope` over `internal/sessionhost/testdata/paths.json`.
- [ ] **Step 2:** `go test ./internal/sessionhost`, `make test-swift FILTER=SessionHostPathsFixtureTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** → PASS; `make lint-diff`, `make lint-swift`.
- [ ] **Step 5: Commit** `sessionhost: protocol v2 (non-attaching InputTo, launch counter) and a Go client`.

### Task 12: Prompt state in `session-host` — owner drafts, pending Returns, paste mode

**Files:**
- Create: `internal/sessionhost/prompt.go`, `internal/sessionhost/profile.go`, `internal/sessionhost/paste.go`, `internal/sessionhost/testdata/paste_cases.json`
- Modify: `internal/sessionhost/session.go` (feed every client `Input` and every `InputTo` into the prompt state; read bracketed-paste mode from the existing `ModeTracker` (2004))
- Test: `internal/sessionhost/{prompt_test.go,paste_test.go}`
- Create: `WatchtowerDesktop/Tests/Core/TerminalPasteFixtureTests.swift`

**Interfaces:**
- Produces:
  ```go
  type Profile struct{ Submit, Newline []byte; PasteSettle, SubmitSettle time.Duration }
  func ProfileFor(agent string) Profile // claude: {0x0D}, nil, 150 ms, 500 ms; codex: {0x0D}, {0x0A}, 150 ms, 500 ms
  func IsSubmit(b []byte, backslashBefore bool, p Profile) bool
  func EndsAfterBackslash(b []byte, backslashBefore bool) bool
  func PasteText(line string, keepLineBreaks, keepFormat bool) string // WorkbenchCommentPrompt.terminalPayload's cleaning
  func PastePayload(text string) []byte                               // ESC[200~ text ESC[201~
  type promptState struct{ draft, pendingReturn, leftTyped, dialog, backslash, ownerReturnInPause bool } // per session
  ```
- **Depends on:** Task 11

- [ ] **Step 1: Failing tests** (Go twins of the owner-input PROJ-12 guards, same meaning): `TestClaudeCodeLineBreakKeysLeaveTheDraft` (`\` then Return, ESC CR, LF, Shift+Return escape), `TestTheOwnersReturnDuringThePauseSkipsOurs`, `TestADialogKeyIsNoDraft` (with `PromptHint{Dialog:true}`), `TestCodexDraftTrackingUsesCodexNewline`, `TestClaudeProfileBytesUnchanged`, `TestCodexProfileIsCRSubmitWithCtrlJNewline`, `TestDeliverWhileOwnerTypesInAnotherClientLeavesTyped` (Review Focus 1: client A attached and typing `abc`, then `Deliver` via client B → draft seen, Task 13 outcome `typed`; this task asserts the draft bit), `TestPasteFixture` (Go) + Swift `testTerminalPayloadMatchesGoFixtures` over `paste_cases.json`.
- [ ] **Step 2:** `go test ./internal/sessionhost`, `make test-swift FILTER=TerminalPasteFixtureTests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** → PASS; `make lint-diff`, `make lint-swift`.
- [ ] **Step 5: Commit** `sessionhost: owner-draft and paste-mode tracking for typed-never-submitted delivery`.

### Task 13: `Deliver` — paste, pause, re-check, Return or leave typed (PROJ-12)

**Files:**
- Create: `internal/sessionhost/deliver.go`
- Modify: `internal/sessionhost/server.go`, `internal/sessionhost/client.go`
- Test: `internal/sessionhost/deliver_test.go`

**Interfaces:**
- Produces:
  ```go
  type DeliverReq struct{ ID string; Row int64; Run string; Launch uint64; Text string; KeepLineBreaks, KeepFormat bool; SettleMs int; SubmitIf bool /* the caller's pre-check */; HoldIfPromptText bool `json:"hold_if_prompt_text"` }
  type DeliverCheckMsg struct{ ID string }                                  // host → the requesting connection, after the pause
  type DeliverCheckReplyMsg struct{ ID string; Fresh, CanSubmit, AnswersDialog bool }
  type DeliveredMsg struct{ ID, Outcome, Reason string }                    // submitted | typed | held (reason prompt_has_text, host-decided) | no_session | no_paste_mode
  type DeliveryEventMsg struct{ Row int64; Run string; Kind string }        // pasted | left_typed | submitted, broadcast to attached clients
  const CheckTimeout = 5 * time.Second
  func (c *Client) Deliver(ctx context.Context, r DeliverReq, check func(context.Context) DeliverCheckReplyMsg) (DeliveredMsg, error)
  ```
  **Algorithm:** session gone or launch differs → `no_session`; paste mode off → `no_paste_mode` (nothing written); prompt not empty (draft, pending Return, left typed) → with `HoldIfPromptText`: nothing written, `held` reason `prompt_has_text`; without it: paste only, `typed` (reason logged); `!SubmitIf` → paste only, `typed`; else paste, set pending Return, sleep `SettleMs`, send `DeliverCheck`, wait ≤ `CheckTimeout` (no reply ⇒ `Fresh=false`); run/launch changed ⇒ `no_session`; owner Return during the pause ⇒ `submitted` unless the reply is not fresh or `AnswersDialog` ⇒ `typed`; `!Fresh || !CanSubmit || draft` ⇒ `typed`; else write `Profile.Submit` alone ⇒ `submitted`. Clear pending Return on every exit path. Hook-fed holds (`needs_approval`, `agent_busy`, `state_unknown`) are the caller's, decided before calling and passed through by the port; the host decides only `held(prompt_has_text)`, and only under `HoldIfPromptText`. Every test in this task runs against a real `Server` with real PTYs (a stub agent printing `ESC[?2004h`) and owner input sent as `Input` frames from a second, attached "Desktop" client — no fake of the prompt state.
- **Depends on:** Task 12

- [ ] **Step 1: Failing PROJ-12 twins** (same meaning as the listed Swift guards): `TestProj12_AnAnswerLineIsPastedAsOneLineThenSubmittedWithItsOwnReturn` (Return strictly after the pause, as a separate write), `TestProj12_OverTheOwnersDraftSubmitPromptOnlyPastes`, `TestProj12_TheOwnerTypingDuringThePauseStopsTheReturn`, `TestProj12_ALineLeftWithoutItsReturnKeepsTheNextFromSubmittingIt`, `TestProj12_AFailedRefreshAfterThePauseStopsTheReturn`, `TestProj12_WithoutBracketedPasteTheLineIsNotTyped` (`no_paste_mode`, zero bytes written), `TestProj12_ARelaunchDuringThePauseGetsNoReturn` (Review Focus 3), `TestProj12_TheOwnersReturnDuringThePauseOverADialogOrAFailedReadLeavesTheLineTyped`, `TestProj12_CodexSubmitIsBracketedPasteThenCR`, `TestProj12_CodexMultilineAnswerOnePrompt`; `TestHoldIfPromptTextHoldsOverAnOwnerDraft` (Desktop client types `abc` as `Input` frames, then `Deliver{HoldIfPromptText}` → `held(prompt_has_text)`, zero bytes written after the draft), `TestHoldIfPromptTextHoldsOverAPendingReturn` (a second `Deliver` during the first one's pause), `TestHoldIfPromptTextHoldsOverALineLeftTyped`, `TestWithoutHoldIfPromptTextALineBesideTheDraftIsTyped` (the composer's behaviour: pasted, `typed`, no CR), `TestDeliverCheckTimeoutLeavesLineTyped` (Review Focus 2: the requesting client never replies → `typed`, no CR written, pending Return cleared, next `Deliver` sees `leftTyped`); `TestDeliveryEventsReachAttachedClients`; `TestDeliverNeverAttaches`.
- [ ] **Step 2:** `go test ./internal/sessionhost` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `sessionhost: Deliver — typed-never-submitted delivery inside the host`.

### Task 14: `internal/sessionstart` — launch argv and placement in Go (dual path)

**Files:**
- Create: `internal/sessionstart/{launch.go,placement.go}`, `internal/sessionstart/testdata/{launch_cases.json,placement_cases.json}`
- Test: `internal/sessionstart/{launch_test.go,placement_test.go}`
- Create: `WatchtowerDesktop/Tests/Core/TerminalLaunchFixtureTests.swift`, `WatchtowerDesktop/Tests/Core/SessionStartPlacementFixtureTests.swift`

**Interfaces:**
- Consumes: `devpack.CodexLaunchArgs`, `workbenchgit` (worktree create/ensure, `.worktreeinclude` clone — `clone_darwin.go` / plain copy on linux).
- Produces:
  ```go
  package sessionstart
  type Mode struct{ Agent string; SessionID string; Prompt *string; Resume bool } // newAgent / resumeAgent / shell
  type Spec struct{ Executable string; Args []string; Dir string; Env []string; Row int64 }
  func Launch(m Mode, row int64, dir, cliPath string, codex *devpack.LaunchArgs, setup string) (Spec, error) // TerminalLaunch.make twin: WATCHTOWER_TERMINAL_SESSION_ID, WATCHTOWER_FIRST_PROMPT, WATCHTOWER_WORKTREE_SETUP, WATCHTOWER_CODEX_COMMAND, the "/bin/sh -c '" setup prefix, firstRunPrompt, positional prompt quoting
  func IsValidSessionID(id string) bool
  type Choice string; const ( ChoiceAuto Choice = "auto"; ChoiceFolder Choice = "folder"; ChoiceWorktree Choice = "worktree" )
  func Place(liveAgentInFolder bool, c Choice, isGitRepo bool) Placement // SessionStartPlacement twin
  ```
- **Depends on:** none

- [ ] **Step 1: Fixtures** — launch cases (new Claude with/without prompt, resume Claude, new/resume Codex, shell, setup command present) and placement cases, generated from the Swift types by the two Swift tests under `WT_E2E_REGENERATE=1`, then read by both sides.
- [ ] **Step 2: Failing tests:** `TestLaunchFixtures`, `TestPlacementFixtures`, `TestPlacementNeverForcesOrDiscards` (twin of `TestProj18_PlacementNeverForcesOrDiscards`' intent at this layer: no `--force`, no discard), Swift `testEveryGoLaunchCase`/`testEveryGoPlacementCase`.
- [ ] **Step 3:** `go test ./internal/sessionstart`, `make test-swift FILTER='TerminalLaunchFixtureTests|SessionStartPlacementFixtureTests'` → FAIL.
- [ ] **Step 4: Implement.**
- [ ] **Step 5:** → PASS; `make lint-diff`, `make lint-swift`.
- [ ] **Step 6: Commit** `sessionstart: Go twins of TerminalLaunch and SessionStartPlacement`.

### Task 15: `watchtower workbench session start|stop` and the hub's `SessionPort`

**Files:**
- Create: `internal/sessionstart/start.go`, `internal/sessionstart/stop.go`, `internal/sessionstart/port.go` (implements `handlers.SessionPort`)
- Modify: `internal/db/terminal_sessions.go` (`CreateTerminalSession`, `PlaceTerminalSession`, `SetTerminalSessionLaunchError` — same SQL as `TerminalSessionQueries.create`/`place`)
- Create: `cmd/workbench_session.go`
- Modify: `internal/hub/hub.go` (`Register` wires `handlers.Register` with the real port; `Ensure` the host on start when none answers)
- Test: `internal/sessionstart/{start_test.go,port_test.go}`, `internal/db/terminal_sessions_test.go`, `cmd/workbench_session_test.go`

**Interfaces:**
- Produces:
  ```go
  func Start(ctx context.Context, d Deps, r handlers.StartRequest) (handlers.StartResult, error)
  // 1 row first (state Starting…, folder = the workbench folder), 2 place: own worktree when a live agent already works there (or as chosen), .worktreeinclude, setup command, `claude mcp add` per new worktree, 3 launch-args / Launch, 4 sessionhost Launch with scope + agent, 5 return the id at once (instant start #942: the move into the worktree may finish after the return)
  func Stop(ctx context.Context, d Deps, sessionID int64) error // host Stop request (Exit carries requested: true), then Forget after the exit is reported
  type Deps struct{ DB *db.DB; Socket, CLIPath, DBPath string; Clock func() time.Time }
  func NewPort(d Deps, client *sessionhost.Client) handlers.SessionPort
  ```
  CLI (pinned keys): `workbench session start --workbench N [--target T] [--agent claude|codex] [--place folder|worktree|auto] --json` → `{"session_id","state","folder_path","worktree_branch"}`; `workbench session stop --session S --json` → `{"session_id","stopped"}`. Refused under an agent marker for another workbench's session (as `workbench cleanup`'s caller rules). The Desktop's **New Session** moves onto this command in phase 3.
- **Depends on:** Task 3, Task 5, Task 13, Task 14

- [ ] **Step 1: Failing tests:** `TestSessionStartReturnsTheRowAtOnceInStarting`, `TestSessionStartOwnWorktreeWhenAnAgentWorksInTheFolder`, `TestSessionStartLaunchFailureMarksTheRow` (Review Focus 5: host refuses the launch → row leaves **Starting…** with the reason in `agent_error`, no orphan worktree removal, PROJ-18 cleanup not triggered), `TestSessionStartUsesTheOverrideSocket` (with `WATCHTOWER_SESSION_HOST_SOCKET`, never the default path), `TestSessionStopIsAHostStopRequest` (the port sends `Stop`, never signals itself; the exit it sees carries `requested: true`), `TestFailedStartKeepsItsWorktree` (the worktree created before the failed launch is still on disk and listed by `workbench cleanup`), `TestProj16_ADraftHoldsTheLineAndNothingIsPasted` (real `session-host`, real stub session, a "Desktop" client attached sending the owner's draft as `Input` frames; a phone `session_input` through the real port → echo `held` reason `prompt_has_text`, the PTY receives no byte from the hub; after the owner's Return the held line goes on the next state read), `TestPortLiveSeesOnlyThisScope`, `TestPortDeliverPassesHeldThrough`, `TestWorkbenchSessionStartJSONKeys`, `TestCreateTerminalSessionMatchesDesktopColumns`; and a smoke `TestHubTypesAPhoneLineIntoAStubSession` (memfake phone → `session_input` → stub agent with bracketed paste on reads `ESC[200~hello ESC[201~` then a lone CR; echo `applied`).
- [ ] **Step 2:** `go test ./internal/sessionstart ./internal/db -run 'TerminalSession'`, `go test ./cmd -run TestWorkbenchSession` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `workbench: session start|stop in Go, the hub's session port`.

### Task 16: Plaintext canaries over everything that leaves the hub

**Files:**
- Create: `internal/hub/canary_test.go`, `internal/hub/state/columns_test.go`

**Interfaces:**
- Consumes: `logcanary.Text`/`Capture`, `memfake.Frames()`, the sidecar file bytes, the full `hub.Run` with every source and handler.
- **Depends on:** Task 10, Task 15

- [ ] **Step 1: Failing test** `TestCanary_NoPlaintextLeavesTheHub`: seed one marker (`logcanary.Text("<field>")`) into every slice source's rows (workbench name, target title, comment body, ask question and answer, permission summary, session title, chat text via a fake transcript, report text, calendar title, transcript text, recording audio bytes) and into every action payload a `hubtest.Phone` sends (session line, ask answer, comment, brief); run the hub through a full cycle and a mailbox pass; assert no marker in (a) any `memfake.Frames()` envelope (and every frame parses as an envelope with the padded flag), (b) the log sink, (c) `control_queue.envelope`, `slice_assets`, `held_actions.envelope`; and that the stored plaintext columns that hold text today (`held_session_lines.line`, `relay_processed.echo`) are the only sidecar places a marker appears (spec §8 p. 4a: the allowlist stays exactly these two).
- [ ] **Step 1b: Failing test** `TestSidecarHasNoNewUnsealedContentColumns` (`internal/hub/state`): migrate a fresh sidecar, enumerate every column via `pragma_table_info` for every table, and compare with an explicit allowlist mapping each TEXT/BLOB column to one class — `id`, `timestamp`, `hash`, `error_class`, `enum`, `public_key`, `sealed` (envelope or `SealLocal`), or `plaintext_today` — where `plaintext_today` is exactly `held_session_lines.line` and `relay_processed.echo`. A column missing from the allowlist fails the test, so a new content column cannot land unsealed by accident. The canary in Step 1 also seeds markers into session report text and milestone text and asserts they are absent from the sidecar file.
- [ ] **Step 2:** `go test ./internal/hub -run TestCanary`, `go test ./internal/hub/state -run TestSidecarHasNoNewUnsealedContentColumns` → FAIL until every path is covered; fix leaks at the source.
- [ ] **Step 3:** → PASS; `make lint-diff`.
- [ ] **Step 4: Commit** `hub: plaintext canaries over frames, logs and sealed sidecar blobs; sidecar column allowlist`.

### Task 17: Phase 1 gate and docs

**Files:**
- Create: `docs/features/go-hub.md`
- Modify: `CLAUDE.md` (one feature-list line linking `docs/features/go-hub.md`)
- Modify: `docs/features/mobile-companion.md` (a pointer: "Go hub (phase 1, dev flag) — see go-hub.md"; cadence lines untouched until phase 3 makes it the live hub)
- Modify: `docs/inventory/workbench.md` (PROJ-12, PROJ-16, PROJ-20, PROJ-21: add the Go guard tests beside the Swift ones; PROJ-20 amended for protocol v2 — non-attaching `InputTo`, `Deliver`, the launch counter — with ask #807; PROJ-12 notes the `session-host` `Deliver` implementation, ask #812; the local-PTY fallback removal is board #1281 / ask #811's own change, referenced not repeated); `docs/inventory/session-feed.md` (FEED-05 Go guards); `docs/inventory/policy.md` (POLICY-03 Go guards); each with a changelog line
- Modify: `Makefile` (CI-free `GOARCH=arm64 GOOS=linux go build ./...` check in `lint-all`'s Go step, or a `build-linux` target the gate runs)

**Interfaces:** none new.
- **Depends on:** Task 16

- [ ] **Step 1: `docs/features/go-hub.md`:** architecture (packages, seams), the dev flag (`WATCHTOWER_HUB_DIR`, `WATCHTOWER_RELAY_ORIGIN`, `WATCHTOWER_SESSION_HOST_SOCKET`) and how to run the test workspace, `hub …` and `workbench session …` CLI with pinned keys, sidecar ownership and migrations, `session-host` v2, v1 limits (relay only, no CloudKit/adoption/pushes/terminal pairing UI until phases 2–4), the measured poll cost from Task 10.
- [ ] **Step 2: Gate:** `make test`, `make test-swift`, `make lint-all`, `make relay-interop RELAY=../relay`, `GOOS=linux GOARCH=arm64 go build ./...` → all PASS; one manual run in the test workspace: link a Go phone emulator over the local stand, start a session with a stub agent, type a line, answer a permission request, read the session chat.
- [ ] **Step 3: Commit** `docs: Go hub phase 1 note, inventory Go guards (asks #807, #811, #812)`.

---

## Self-review (done while writing)

- Spec coverage for 1b: §8 p. 4 handlers (2–5), p. 4a (5), p. 4b `Deliver`, prompt state, events, `.copied`/`cannot_type`, no fallback (11–13, 2), §9 (6–10), §10 recordings CLI (5), §11 (14–15; `service install` is phase 2), §13 canaries (16), one test per new branch in scope (`Deliver` outcomes incl. owner draft and pending Return: 12–13; never-started exit: 15; recordings held without Desktop and `not_supported` on a host that never had one: 5; desktop host vs CLI-only Mac for `no_paste_mode`: 2; requested vs natural exit: 11; host-held `prompt_has_text`: 13, 15; fixture cases: 1a Task 1; canaries: 16). Out of phase 1: the one-time v1-host restart step, vouching end to end, CloudKit bridge, adoption, Desktop rewiring, pushes.
- Types across tasks: `handlers.SessionPort`/`DeliverRequest`/`StartRequest` (2 → 3, 4, 15), `handlers.ChatWatches` (4 → 8, 9), `sessionstate.Resolve` (1 → 3, 6, 7), `sessionhost.Client`/`DeliverReq`/`ProfileFor` (11–13 → 15), `sources.All` (9 → 10), `sessionstart.Launch`/`Place` (14 → 15).
