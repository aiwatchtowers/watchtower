# Phone Permission Answers + Interrupt Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The owner answers a Claude Code permission prompt (Allow once / Deny) and interrupts a working agent (Esc) from the iPhone, without anything being typed into the terminal for the answer.

**Architecture:** A synchronous `PermissionRequest` hook (`watchtower workbench permission-wait`) records a `permission_requests` row and polls it. The Desktop hub publishes pending rows as an urgent slice, and a `permission_answer` relay action decides the row by compare-and-set. Interrupt is a `session_interrupt` action that writes one ESC byte to the session's pty.

**Tech Stack:** Go (cobra, `database/sql` SQLite, goose), Swift (Desktop hub, GRDB), WatchtowerKit (`WatchtowerSync` + `WatchtowerKit`), SwiftUI iPhone app.

**Spec:** `docs/superpowers/specs/2026-10-17-phone-permission-answers-design.md` (owner approved, ask #265; decisions ask #263).

## Global Constraints

- The answer types nothing. Only the hook's JSON decides a prompt; no phone action writes to a terminal at Needs approval (PROJ-16 stays).
- Allow is for one call only. The hook never outputs `updatedInput` or `updatedPermissions`.
- Deny message, verbatim: `Denied from the owner's phone.`, with `interrupt` false.
- `summary` is clipped to 2000 characters. Bash: `command`, plus `\n` + `description` when present. Edit/Write/NotebookEdit: `file_path`. WebFetch: `url`. Otherwise compact JSON of `tool_input`.
- The hook polls every 1 s with reads only. It does two short writes (step 2 of spec §4.2, the final status) under the hooks' 1 s / 500 ms write budget. Every failure exits 0 with no output.
- The hook timeout is 86400 s if Task 1's probe shows it holds, else the observed cap.
- Permission answers need their own grant (`permissions_allowed`), never implied by typing. Interrupt needs `typing_allowed`.
- Interrupt is allowed only while the state is Working, and only if the action is at most 120 s old when the hub handles it (else `expired`). It writes exactly one byte, `0x1B`.
- Claude sessions only. Codex keeps "Needs approval on the Mac".
- Phone copy, verbatim: `Allow once`, `Deny`, `Interrupt`, `Answered on the Mac`, `Allow answering permission prompts on the Mac: Watchtower → Settings → Mobile → Allow…`, toggle `Answer permission prompts from this phone`. Mac confirmation: `Allow "<name>" to approve commands in Claude Code sessions?`
- Repo docs are in English; contracts per CLAUDE.md "Behavior Inventory".
- Deviation from spec §5.2, owner to note: the push alert for a new request is not part of this plan. Phone pushes wait on board #17 (A13, blocked). The request reaches the phone through the urgent slice and shows in Now and the badge.

## Review Focus

1. **The owner answers on the Mac while the phone answers too.** The Mac wins, and the phone's answer comes back `not_pending` with "Answered on the Mac". Task 3 (`TestPermissionWait_MacAnswerWins`) and Task 7 (`testAnAnswerAfterTheMacAnsweredIsNotPending`).
2. **Two prompts in a row in one session.** The first row is closed `answered_on_mac` when the second opens, so a late phone answer to the first can never decide the second. Task 2 (`TestInsertPermissionRequestClosesTheOlderPending`) and Task 7.
3. **A revoked or never-granted phone.** It cannot answer even with a valid request id. Task 7 (`testProjNN_AnUngrantedDeviceCannotAnswer`, `testProjNN_RevokeBlocksAnswers`).
4. **An Esc that arrives late or at a prompt.** It is never sent. Task 7 (`testInterruptAtNeedsApprovalFailsNotWorking`, `testAStaleInterruptExpires`).
5. **The hook runs outside a board session** (a plain terminal, a nested session, a DB that is gone). It exits instantly with no output and adds no delay. Task 3 (`TestPermissionWait_NotABoardSessionExitsSilently`).

---

### Task 1: Probe the hook timeout cap

**Files:**
- Create: `docs/superpowers/specs/2026-10-17-phone-permission-answers-design.md` §9 note (modify)

**Interfaces:** Produces the timeout value used by Task 4.

- [ ] **Step 1:** In a scratch folder outside the repo (the session scratchpad), run an interactive Claude Code session with `--permission-mode default`, `--setting-sources project` and a `PermissionRequest` command hook with `"timeout": 86400` that logs `start`, sleeps 700 s, logs `end` and prints an allow decision. Drive it through a pty: send "Run exactly this bash command: touch probe.txt", accept the trust dialog with Down+Return, and do not answer the prompt.
- [ ] **Step 2:** Pass if `end` is logged and `probe.txt` exists after about 700 s. That means the hook outlived the 600 s default and its decision applied. If it was killed near 600 s, retry with `"timeout": 3600`, then 1800, and record the highest value that held.
- [ ] **Step 3:** Kill the process group, and check with `pgrep -fl probe` that nothing is left behind.
- [ ] **Step 4:** Write the result into spec §9 (one line, with the Claude Code version) and commit.

### Task 2: `permission_requests` table and DB API

**Files:**
- Create: `internal/db/migrations/00129_permission_requests.sql`, `internal/db/permission_requests.go`, `internal/db/permission_requests_test.go`
- Modify: `internal/db/schema.sql`, `internal/db/db_test.go` (`TestAllTablesExist` adds `"permission_requests"`), the golden snapshot and `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (regenerated with `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`)

Use the `add-migration` skill.

**Interfaces:**
- Produces:
  - `type PermissionRequest struct { ID, TerminalSessionID, WorkbenchID int64; ToolName, Summary, Status string; CreatedAt time.Time; DecidedAt sql.NullString; DecidedBy sql.NullString }`
  - Status constants `PermissionPending = "pending"`, `PermissionAllowed = "allowed"`, `PermissionDenied = "denied"`, `PermissionAnsweredOnMac = "answered_on_mac"`, `PermissionExpired = "expired"`.
  - `func (db *DB) OpenPermissionRequest(sessionRowID, workbenchID int64, sessionID string, toolName, summary string, at time.Time, order AgentOrder) (int64, error)`: one transaction. It calls `SetTerminalAgentState(sessionRowID, workbenchID, sessionID, "approval", at, "", nil, false, order)`, marks older `pending` rows of the session `answered_on_mac`, and inserts `pending` with `created_at = AgentStateStamp(at)`.
  - `func (db *DB) GetPermissionRequest(id int64) (*PermissionRequest, error)` (read-only; `ErrPermissionRequestNotFound`).
  - `func (db *DB) ClosePermissionRequest(id int64, status string, at time.Time) (bool, error)`: `UPDATE … WHERE id = ? AND status = 'pending'`.

Schema: as spec §4.1. `terminal_session_id INTEGER NOT NULL REFERENCES terminal_sessions(id) ON DELETE CASCADE`, `workbench_id INTEGER NOT NULL`, `status TEXT NOT NULL CHECK (status IN ('pending','allowed','denied','answered_on_mac','expired'))`, `created_at TEXT NOT NULL`, `decided_at TEXT`, `decided_by TEXT`, and index `(terminal_session_id, status)`.

- [ ] **Step 1: Write the failing tests:**
  - `TestOpenPermissionRequestSetsApprovalAndInserts`: after the call, `GetTerminalSession` has `AgentState` `approval` and `AgentStateAt == at`, and the row is `pending`.
  - `TestInsertPermissionRequestClosesTheOlderPending`: a second open leaves the first `answered_on_mac` and the second `pending`.
  - `TestClosePermissionRequestIsCompareAndSet`: the first close returns true, the second returns false and the status keeps the first.
  - `TestPermissionRequestCheckRejectsUnknownStatus`.
- [ ] **Step 2:** Run `go test ./internal/db -run PermissionRequest`. Expected: FAIL (undefined).
- [ ] **Step 3:** Write the migration and the three functions in `internal/db/permission_requests.go`, in the `owner_asks.go` style.
- [ ] **Step 4:** Regenerate the snapshot and the Swift schema, then run `go test ./internal/db`. Expected: PASS.
- [ ] **Step 5:** Commit: `feat(db): permission_requests for phone answers (#517)`.

### Task 3: `watchtower workbench permission-wait`

**Files:**
- Create: `cmd/workbench_permission_wait.go`, `cmd/workbench_permission_wait_test.go`
- Modify: `cmd/workbench_hook_input.go`: add `ToolInput json.RawMessage` with json tag `tool_input` to `hookEvent`.

**Interfaces:**
- Consumes: Task 2's `OpenPermissionRequest`, `GetPermissionRequest`, `ClosePermissionRequest`. Also `readHookEvent`, `terminalSessionRowID`, `hookSessionRow`, `hookNow`, `openJiraCmdDB`, `addWorkbenchIDFlag`, `checkWorkbenchIDFlags` (all in `cmd/`).
- Produces:
  - `var workbenchPermissionWaitCmd`, with `Use: "permission-wait"` and the same pre-run, args and flag-whitelist shape as `workbenchSessionStateCmd`.
  - `func permissionSummary(toolName string, toolInput json.RawMessage) string`, per the Global Constraints rules.
  - `var permissionPollEvery = time.Second`, so tests can shrink it.
  - Output written to stdout: `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`, or the deny form with `"message":"Denied from the owner's phone."`.

Loop (spec §4.2 step 3): each tick reads the row. `allowed` or `denied` → print and exit. Otherwise `GetTerminalSession`. If the session is gone or finished, or `AgentStateAt` is after the row's `CreatedAt` with a state other than `approval`, close the row `answered_on_mac` and exit silently. A context cancel (SIGTERM) → exit silently.

- [ ] **Step 1: Write the failing tests** (fixture `briefSessionFixture`, `t.Setenv(terminalSessionEnv, …)`, `stepClock`, `permissionPollEvery = 10*time.Millisecond`):
  - `TestPermissionWait_PhoneAllowPrintsAllow`: a goroutine closes the row `allowed`, and stdout equals the allow JSON exactly.
  - `TestPermissionWait_PhoneDenyPrintsDeny`.
  - `TestPermissionWait_MacAnswerWins`: `SetTerminalAgentState` writes `working` at a later time, the output is empty and the row is `answered_on_mac`.
  - `TestPermissionWait_NotABoardSessionExitsSilently`: unset the env, the output is empty, no row is written, and it returns in under 100 ms.
  - `TestPermissionWait_DBFailureExitsSilently` (`brokenConfig`).
  - `TestPermissionSummary`: table cases for Bash with a description, Edit, WebFetch, an MCP tool, and 2001 characters clipped to 2000.
- [ ] **Step 2:** Run `go test ./cmd -run 'PermissionWait|PermissionSummary'`. Expected: FAIL.
- [ ] **Step 3:** Implement. Register with `workbenchCmd.AddCommand`. Always return nil; errors go to stderr.
- [ ] **Step 4:** Run the same tests. Expected: PASS. A test that starts no process needs no reaping.
- [ ] **Step 5:** Commit: `feat(workbench): permission-wait hook (#517)`.

### Task 4: Install the hook for Claude workbenches

**Files:**
- Modify: `internal/devpack/workbench_settings.go`, `internal/devpack/workbench_state_hooks_test.go`

**Interfaces:**
- Consumes: Task 1's timeout and Task 3's subcommand.
- Produces: `permissionWaitSpec = hookSpec{event: "PermissionRequest", subcommand: "workbench permission-wait --workbench", timeoutSec: <Task 1>, matcher: "*"}`, synchronous (no `async`). It is added to `ownedHookSpecs` and installed and removed next to the state hooks (`InstallStateHooks` and its remover). It is Claude only, and `codexHookRows` is untouched.

- [ ] **Step 1:** Write the failing test `TestInstallWorkbenchInstallsThePermissionWaitHook`: the settings JSON has `PermissionRequest` with matcher `*`, the timeout, no `async`, and the command suffix. Extend `TestStatusWorkbench_StateHooksFalseWithOneMissing` if the status counts it. Keep `TestHasStateHooksNeedsAllSixCoreNeedsFour`'s counts honest: the new spec is not a state hook, so it does not change "six/four".
- [ ] **Step 2:** Run `go test ./internal/devpack`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `go test ./internal/devpack ./cmd -run 'Install|Codex|Legacy'`. Expected: PASS. `TestCodexHookSet_GoldenOrderAndTimeouts` is unchanged.
- [ ] **Step 5:** Commit: `feat(devpack): install the permission-wait hook (#517)`.

### Task 5: Kit wire types

**Files:**
- Modify:
  - `WatchtowerKit/Sources/WatchtowerSync/Relay/ActionRequestPayload.swift`: `ActionKind` gains `permissionAnswer = "permission_answer"` and `sessionInterrupt = "session_interrupt"`, appended last.
  - `Relay/ActionReason.swift`: gains `notPending = "not_pending"` and `notWorking = "not_working"`, appended last.
  - `Sync/SliceRecord.swift`: `SliceKind` gains `permissionRequest = "permission_request"`.
  - `Link/DeviceGrant.swift`: gains `permissionsAllowed: Bool`, which decodes absent as false; update CodingKeys and the init.
  - `Relay/DevicePayload.swift`: gains `permissionsRequested: Bool`, which decodes absent as false.
  - `WatchtowerKit/Models/WorkbenchActionParams.swift`: gains `PermissionAnswerParams { requestID: Int64; behavior: Behavior (allow|deny) }` and `SessionInterruptParams {}`.
- Create: `WatchtowerKit/Sources/WatchtowerKit/Models/PermissionRequest.swift` and `WatchtowerKit/Tests/Fixtures/workbench/permission_request.json`.
- Test: `WorkbenchMirrorFixtureTests` (`testWorkbenchActionKindsAreFrozen` suffix grows to 14, plus `testWorkbenchSliceKindsAreFrozen`), and `KitFixtureTests`.

**Interfaces:**
- Produces: `public struct PermissionRequest: SliceMirror, Identifiable { id: Int64; sessionID: Int64; workbenchID: Int64; toolName: String; summary: String; summaryClipped: Bool?; createdAt: Date }` with `sliceKind = .permissionRequest`. Its wire keys are snake_case through `RelayCoder` (`session_id`, `tool_name`, `created_at` as epoch seconds, like `terminal_session.json`).

- [ ] **Step 1:** Write the failing tests: `testPermissionRequestFixture` (decode, then assert every field); the frozen-kind tests listing the new raw values; `DeviceGrant` and `DevicePayload` decoding an older payload without the new keys as false.
- [ ] **Step 2:** Run `make kit-test FILTER='WorkbenchMirrorFixtureTests|KitFixtureTests'`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Rerun. Expected: PASS. Run `cd WatchtowerKit && swiftlint lint --strict`.
- [ ] **Step 5:** Commit: `feat(kit): permission request wire types (#517)`.

### Task 6: Desktop grant, slice and expiry

**Files:**
- Modify:
  - `Services/MobileHub/HubSyncState.swift`: add `permissions_allowed` and `permissions_requested` INTEGER NOT NULL DEFAULT 0 in place, like `typing_requested`.
  - `HubSyncState+Linking.swift`: `LinkedDevice` fields; `DeviceGrantKind.permissions = "permissions_allowed"`; `setPermissionsRequested(_:deviceID:)`.
  - `MobileLinkCenter.swift`: `setPermissionsAllowed(_:deviceID:)`; `applyPermissionsRequest` mirroring `applyTypingRequest`, where on→off revokes.
  - `Slices/DeviceGrantSlice.swift`: `permissionsAllowed`.
  - `SessionStartStopHandlers.DeviceGrant` gains `permissionsAllowed`, and `MobileLinkCenter.sessionGrant` fills it.
  - `ViewModels/MobileSettingsViewModel.swift` and `Views/Settings/MobileSettingsView.swift`: a second Allow…/Revoke pair labelled for permission prompts, with the Global Constraints confirmation.
  - `FastLane.swift`: `observedTables` gains `("permission_requests", [.permissionRequest])`.
  - `SlicePublisher.swift`: `urgentKinds` gains `.permissionRequest`.
- Create: `Slices/PermissionRequestSlice.swift` (`SliceSource`, `kind = .permissionRequest`): the `pending` rows of live board Claude sessions in `WorkbenchSlice.publishedWorkbenchRefs(db)`, with the summary capped at 2000 and `summaryClipped`. On each pass, before reading, it marks `expired` the pending rows older than the hook timeout or whose session is not live (`TerminalCenter.liveIDs` copy through the `SessionLivenessBox` the session slice uses). Wire it where `OwnerAskSlice` is registered.
- Test: `WatchtowerDesktop/Tests/MobileHub/PermissionRequestSliceTests.swift`, and `MobileLinkCenterTests` additions.

**Interfaces:**
- Consumes: Task 2's table and Task 5's types.
- Produces: `MobileLinkCenter.setPermissionsAllowed(_ allowed: Bool, deviceID: String) throws`; `DeviceGrant.permissionsAllowed` on the handler side (Task 7).

- [ ] **Step 1: Write the failing tests:**
  - `testOnlyPendingRowsOfLiveBoardSessionsArePublished`.
  - `testOldOrOrphanPendingRowsExpireOnThePass`.
  - `testAPermissionsRequestIsStoredNotGranted`.
  - `testPermissionsAllowIsSeparateFromTyping`: allowing one leaves the other off.
  - `testThePhonesPermissionsToggleOffRevokes`.
  - `testASidecarWithoutThePermissionColumnsGainsThem`.
- [ ] **Step 2:** Run `make test-swift FILTER='PermissionRequestSliceTests|MobileLinkCenterTests|RelayProcessorTests'`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Rerun. Expected: PASS. Run `make lint-swift`.
- [ ] **Step 5:** Commit: `feat(desktop): permission grant and request slice (#517)`.

### Task 7: Desktop handlers `permission_answer` and `session_interrupt`

**Files:**
- Create: `Services/MobileHub/Handlers/PermissionAnswerHandlers.swift` and `WatchtowerDesktop/Tests/MobileHub/PermissionAnswerHandlersTests.swift`.
- Modify:
  - `Services/TerminalCenter.swift`: `func sendInterrupt(sessionID: Int64) -> Bool` writes `[0x1B]` through `sendAppInput`, and returns false without a live process.
  - `App/AppState+MobileHub.swift`: register the handlers, using the shape of `SessionStartStopHandlers`.

**Interfaces:**
- Consumes: Task 2's `permission_requests` (written with the Desktop's GRDB writer, a short transaction); Task 6's grant; `SessionInputHandlers.Status`-style state lookup; `withHandlerTimeout`.
- Produces: `@MainActor final class PermissionAnswerHandlers` with `static let kinds: [ActionKind] = [.permissionAnswer, .sessionInterrupt]`, `init(dbPool:, terminalCenter:, status:, deviceGrant:, now:)` and `register(on:)`.

Order: answer as spec §5.3, interrupt as spec §6. The CAS is `UPDATE permission_requests SET status = ?, decided_at = ?, decided_by = ? WHERE id = ? AND terminal_session_id = ? AND status = 'pending'`. A row that is not pending fails `.notPending`, and the message is `Answered on the Mac` when its status is `answered_on_mac`. `decided_by` is the device's name.

- [ ] **Step 1: Write the failing tests:**
  - `testProjNN_AnUngrantedDeviceCannotAnswer`: it gets `deviceNotAllowed`, and the row stays pending.
  - `testProjNN_AnAllowDecidesThePendingRowOnce`: a second answer gets `notPending`.
  - `testAnAnswerAfterTheMacAnsweredIsNotPending`: it carries the message "Answered on the Mac".
  - `testProjNN_RevokeBlocksAnswers`.
  - `testAnAnswerForAnotherSessionsRequestIsNotFound`.
  - `testProjNN_AnAnswerTypesNothing`: a fake process records zero bytes.
  - `testInterruptSendsOneEscWhileWorking`: the bytes are `[0x1B]`.
  - `testInterruptAtNeedsApprovalFailsNotWorking`, `testInterruptWhenIdleFailsNotWorking`.
  - `testAStaleInterruptExpires`: the action is 121 s old, it is `expired` and nothing is written.
  - `testInterruptNeedsTheTypingGrant`.
- [ ] **Step 2:** Run `make test-swift FILTER=PermissionAnswerHandlersTests`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Rerun, then rerun `make test-swift FILTER=SessionInputHandlersTests`, where the PROJ-16 guards must stay unchanged and green. Run `make lint-swift`.
- [ ] **Step 5:** Commit: `feat(desktop): answer permission prompts and interrupt from the phone (#517)`.

### Task 8: Phone

**Files:**
- Modify:
  - `Features/Workbench/WorkbenchReplicaModel.swift`: `permissionRequests: [PermissionRequest]`, the `kinds` entry, `decodeAll`, `pendingPermission(for sessionID:) -> PermissionRequest?`, and `openAskCount` now counting pending requests too.
  - `Features/Workbench/SessionDetailModel.swift`: `approvalNotice` stays for Codex or when no request exists; it gains `permission: PermissionCardModel?`.
  - `Features/Workbench/SessionDetailView.swift`: `PermissionCardView` in place of `ApprovalNoticeView` when `permission != nil`.
  - `Features/Workbench/SessionActionsModel.swift`: `canInterrupt` (`live && stateKind == .working && typingAllowed && typingRequested`).
  - `Features/Workbench/SessionStarter.swift`, or a new `PermissionAnswerSender.swift` in the `SessionInputSender` shape: `answer(requestID:behavior:)` and `interrupt(sessionID:)` through the outbox, with one in flight per key.
  - `App/DeviceSettings.swift`: `Setting.permissionsRequested` and `setPermissionsRequested(_:) async`, written into `DevicePayload.permissionsRequested`, with a `permissionsError` like `typingError`.
  - `Features/Settings/SettingsView.swift`: the toggle and its caption (`Allowed` / `Waiting for your Mac to confirm`).
  - `Features/Now/NowModel.swift` and `Features/Workbench/WorkbenchModels.swift`: a `WaitingCardModel` for a pending request (kind label `Needs approval`, title = tool name, subline = first summary line).
- Create: `Features/Workbench/PermissionCardModel.swift` (pure), with `WatchtowerMobile/Tests/PermissionCardTests.swift` and `PermissionAnswerWiringTests.swift`.

**Interfaces:**
- Consumes: Task 5's types.
- Produces: `struct PermissionCardModel: Equatable { tool: String; summary: String; clippedNote: String?; canAnswer: Bool; hint: SessionInputModel.TypingHint-like enum PermissionHint? (turnOn | waitingForMac); confirmsAllow: Bool (tool == "Bash"); row: state of the last answer (sending/received/failed message) }`.

- [ ] **Step 1: Write the failing tests:**
  - `testAPendingRequestReplacesTheApprovalNotice`.
  - `testWithoutTheGrantTheCardIsReadOnlyWithAHint`: `.turnOn`, and `.waitingForMac` once requested.
  - `testBashAllowAsksForConfirmation`.
  - `testAClippedSummarySaysSo`.
  - `testAllowQueuesPermissionAnswer`: params `{request_id, behavior: "allow"}`.
  - `testANotPendingEchoShowsAnsweredOnTheMac`.
  - `testInterruptOnlyWhileWorkingAndAllowedToType`.
  - `testAPendingRequestShowsInNowAndTheBadge`.
  - `testCodexSessionKeepsTheNotice`.
- [ ] **Step 2:** Run `make mobile-test MOBILE_FILTER='PermissionCardTests|PermissionAnswerWiringTests|SessionInputWiringTests|NowWiringTests|SettingsWiringTests'`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Rerun. Expected: PASS. Run `cd WatchtowerMobile && swiftlint lint --strict`.
- [ ] **Step 5:** Commit: `feat(mobile): answer permission prompts and interrupt (#517)`.

### Task 9: Contracts and docs

**Files:**
- Modify: `docs/inventory/workbench.md`. Amend PROJ-16 per spec §7: the heading becomes "…nothing typed from the phone ever answers a permission prompt", and the Observable gains a sentence pointing to PROJ-NN and §6. Add PROJ-NN at the next free id (check `docs/inventory/workbench.md` and open branches; PROJ-19 is the highest on main at writing, and #496 plans one more), with its test guards from Tasks 3 and 7. Also update `docs/features/mobile-companion.md` (the session detail, the slices, the handlers and the grant), `docs/features/workbench.md` (the hooks list), `docs/guide/features/iphone.md` ("Let the phone do more": the third switch, Allow once / Deny, Interrupt), and the CLAUDE.md feature line for the mobile companion (one clause).

- [ ] **Step 1:** Write the docs.
- [ ] **Step 2:** Check that every guard test named in PROJ-NN exists: `grep -rn` each name. Expected: one hit each.
- [ ] **Step 3:** Commit: `docs: PROJ-16 amendment and the phone permission contract (#517)`.

### Gate (controller, once)

`make test`, `make test-swift`, `make lint-all`, `make mobile-test`, then an on-device check ask for the owner: a real prompt answered from the phone, a Mac answer winning, Interrupt.
