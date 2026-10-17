# Workbench Session Host Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Workbench terminal sessions run in a detached `watchtower session-host` process, so a Watchtower update or crash leaves agents, subagents and background processes running and the app reattaches to them on launch.

**Architecture:** A Go host (`internal/sessionhost`, `watchtower session-host --socket P`) owns one PTY per session and speaks a small framed protocol over a unix socket — one control connection for `list`/`forget`, one connection per session for `launch`/`attach`, output, input, resize and exit. The Desktop gets `HostedTerminalSession`, a second `TerminalSessionProcess` that feeds SwiftTerm from the socket instead of a local PTY; `TerminalCenter` launches through it, adopts listed sessions at launch, and on an update (or a "Keep Sessions" quit) detaches instead of killing.

**Tech Stack:** Go 1.26, `github.com/creack/pty` (new dependency), cobra; Swift 5.10, SwiftTerm (`TerminalView.feed(byteArray:)`), Network.framework (`NWEndpoint.unix(path:)`).

**Spec:** `docs/superpowers/specs/2026-10-17-workbench-sessions-survive-restart-design.md`

## Global Constraints

- Ring buffer per session: 2 MiB (`2 << 20` bytes).
- Host idle exit: no sessions held and no client connected for 60 s.
- Stop semantics unchanged: SIGHUP to the session's process group, SIGKILL after `TerminalCenter.killGrace` (3 s) — the app keeps signalling the group itself (`ProcessGroupSignaller`); the host reports the child pid, which leads its own session and process group.
- One host per app bundle id: socket `NSTemporaryDirectory() + "watchtower-sh-" + <first 8 hex of SHA-256(bundle id)> + ".sock"` (short, per-user, gone at reboot — unix socket paths are limited to 104 bytes).
- Protocol version 1; it only ever grows additively (spec §4.2).
- An update never prompts about sessions; a normal quit with ≥ 1 live hosted session prompts **Keep Sessions and Quit** / **Stop Sessions and Quit** / **Cancel**; logout, restart and shutdown never prompt (spec §4.4, ask #247).
- Tests never start a real host from Swift; Go tests run the server in-process and reap every child process group in `t.Cleanup` (CLAUDE.md).
- Inner loop only per task (`go test ./internal/sessionhost`, `make test-swift FILTER=…`, `make lint-diff`, `make lint-swift` for Swift); the full gate runs once at the end.

## Review Focus

1. **Bracketed paste after reattach** — Claude Code enabled DECSET 2004 long before the last 2 MiB; after reattach `bracketedPasteMode` must still be true, or ask answers arrive as keystrokes. Pinned in Task 1 (`TestModeTracker_ReplayPrefixRestoresBracketedPaste`) and Task 4 (`testReattachedSessionReportsBracketedPaste`).
2. **A session the owner deleted while the app was closed** — must be stopped at launch, not adopted. Task 5 `testReattachStopsSessionWhoseRowIsGone`.
3. **Exit while away** — reported once through `onSessionExit` with `closedByApp: false`, then forgotten; never reported again on the next launch. Task 5 `testReattachReportsExitOnceAndForgets`.
4. **Host unreachable** — launch falls back to today's local PTY and the pane says the session is not protected; nothing hangs. Task 4 `testLaunchFallsBackToLocalWhenHostUnavailable`.
5. **Replay cut inside an escape sequence** — the trimmed ring never starts mid-sequence. Task 1 `TestRing_TrimStartsAtSafePoint`.

---

### Task 1: Go — frame codec, ring buffer, mode tracker

**Depends on:** none

**Files:**
- Create: `internal/sessionhost/frame.go`, `internal/sessionhost/ring.go`, `internal/sessionhost/modes.go`
- Test: `internal/sessionhost/frame_test.go`, `internal/sessionhost/ring_test.go`, `internal/sessionhost/modes_test.go`

**Interfaces — Produces:**
- Frame: `type(1 byte) | length (uint32 big-endian) | payload`. Max payload 1 MiB (`MaxPayload = 1 << 20`).
- `type FrameType byte` with constants (client → host / host → client):
  `Hello 0x01 / HelloOK 0x81` (JSON `{"version":1}` / `{"version":1,"pid":N}`),
  `Launch 0x02 / Launched 0x82`, `Attach 0x03 / Attached 0x83`, `Input 0x04` (raw bytes), `Resize 0x05` (JSON `{"cols","rows"}`), `Output 0x84` (raw bytes), `Exit 0x85` (JSON `{"code":N|null}`), `List 0x06 / Listed 0x86`, `Forget 0x07 / Forgot 0x87`, `Error 0x8F` (JSON `{"message"}`).
- `func WriteFrame(w io.Writer, t FrameType, payload []byte) error`, `func ReadFrame(r io.Reader) (FrameType, []byte, error)` (`ErrFrameTooLarge` over `MaxPayload`).
- JSON structs: `LaunchReq{Row int64; Run string; Executable string; Args []string; Env []string; Cwd string; Cols, Rows uint16}` (json `row,run,executable,args,env,cwd,cols,rows`), `AttachReq{Row int64; Run string}`, `SessionInfo{Row int64; Run string; Pid int; StartedAtMs int64; Exited bool; Code *int}` (json `row,run,pid,started_at_ms,exited,code`), `ListResp{Sessions []SessionInfo}`, `ResizeReq{Cols, Rows uint16}`, `ExitMsg{Code *int}`.
- `type Ring struct` — `NewRing(capacity int) *Ring`, `(r *Ring) Write(p []byte)`, `(r *Ring) Snapshot() []byte`.
- `type ModeTracker struct` — `(m *ModeTracker) Observe(p []byte)`, `(m *ModeTracker) ReplayPrefix() []byte`.

- [ ] **Step 1: Write the failing tests**
  - `TestFrame_RoundTrip`: `WriteFrame(buf, Output, []byte("hi"))` gives bytes `84 00 00 00 02 68 69`; `ReadFrame` returns `(Output, "hi", nil)`.
  - `TestFrame_RejectsOversize`: a header with length `MaxPayload+1` → `ErrFrameTooLarge`.
  - `TestRing_KeepsTail`: capacity 8, write `"abcdefghij"` (no ESC/LF) → `Snapshot() == "cdefghij"`.
  - `TestRing_TrimStartsAtSafePoint`: capacity 16; write `"\x1b[31mAAAA\n\x1b[0mBBBBBBBB"` then enough bytes that the trim point lands inside `\x1b[31m` → the snapshot starts at the first `\x1b` or the byte after the first `\n` after the trim point (look-ahead window 4096 bytes; if neither is found, the raw tail).
  - `TestModeTracker_ReplayPrefixRestoresBracketedPaste`: `Observe("\x1b[?2004h")` then 3 MiB of plain text → `ReplayPrefix()` contains `"\x1b[?2004h"`.
  - `TestModeTracker_SplitSequence`: `Observe("\x1b[?10")`, `Observe("49h")` → prefix contains `"\x1b[?1049h"`.
  - `TestModeTracker_DefaultsEmitNothing`: no input → empty prefix; `"\x1b[?25l"` → prefix `"\x1b[?25l"`; then `"\x1b[?25h"` → empty.
- [ ] **Step 2: Run `go test ./internal/sessionhost` — expect FAIL (undefined).**
- [ ] **Step 3: Implement.** Tracked DEC private modes: `1, 25, 47, 1000, 1002, 1003, 1004, 1006, 1047, 1049, 2004`; defaults: 25 on, the rest off. `CSI ? Pm h|l` may list several modes (`?1049;2004h`). The tracker keeps at most 32 bytes of an unfinished sequence between `Observe` calls. `ReplayPrefix` emits alt-screen modes (47/1047/1049) first, then the rest, each only when it differs from its default.
- [ ] **Step 4: Run `go test ./internal/sessionhost` — expect PASS.**
- [ ] **Step 5: Commit** `feat(sessionhost): frame codec, ring buffer and mode tracker (#496)`

### Task 2: Go — host server and `watchtower session-host`

**Depends on:** Task 1

**Files:**
- Create: `internal/sessionhost/server.go`, `internal/sessionhost/session.go`, `cmd/session_host.go`
- Modify: `go.mod`/`go.sum` (`github.com/creack/pty`), `cmd/root.go` (register the command)
- Test: `internal/sessionhost/server_test.go`, `cmd/session_host_test.go`

**Interfaces:**
- Consumes: Task 1.
- Produces: `type Server struct`; `func NewServer(opts Options) *Server` with `Options{IdleExit time.Duration; RingSize int; Now func() time.Time}`; `func (s *Server) Serve(ctx context.Context, l net.Listener) error` (returns when ctx ends or the idle exit fires); `func Listen(socketPath string) (net.Listener, error)` (a live host on the path → `ErrHostRunning`; a stale socket file is removed and re-bound; file mode 0600); CLI `watchtower session-host --socket PATH` (calls `unix.Setsid()` first, `Listen`, `Serve` with `IdleExit: 60s`, `RingSize: 2<<20`; `ErrHostRunning` → exit 0).

Behaviour the tests pin:
- Every connection starts with `Hello`; a version other than 1 gets `Error` and is closed.
- `Launch` starts `Executable Args` with exactly `Env` (no inherited env) in `Cwd` under `pty.StartWithAttrs` (`Setsid`, `Setctty`), size `Cols×Rows`, replies `Launched` (`SessionInfo`) and binds the connection to that session: output streams as `Output` frames, `Input` writes to the PTY, `Resize` sets the size and sends `SIGWINCH` to the group even when the size did not change.
- `Attach` binds to an existing `(Row, Run)`: replies `Attached`, then one `Output` with `ModeTracker.ReplayPrefix() + Ring.Snapshot()`, then live output. A newer attach to the same session takes it over (the old connection is closed). Unknown `(Row, Run)` → `Error`. An exited session replies `Attached` with `exited: true` and its code, then `Exit`.
- On child exit: `Exit` to the bound connection (code = exit status, `null` when killed by a signal); the record stays until `Forget` while no connection was bound, and is dropped at once when one was.
- A dropped connection never signals the child.
- `List` → `Listed` with every record; `Forget` of a running session → `Error`.
- Idle exit as in Global Constraints.

- [ ] **Step 1: Write the failing tests** (in-process `Server` on a temp-dir socket; children are `/bin/sh -c …`; `t.Cleanup` kills each child's process group and waits):
  - `TestSessionHost20_SessionSurvivesClientDisconnect`: launch `sh -c 'while :; do echo tick; sleep 0.1; done'`, close the connection, wait 300 ms, `List` shows it running, `kill(pid, 0) == nil`; `Attach` replays at least one `tick`.
  - `TestServer_LaunchUsesOnlyGivenEnv`: `Env: ["FOO=bar"]`, `sh -c 'echo "$FOO-$HOME-"'` → output `bar--`.
  - `TestServer_ExitWhileDetachedIsKeptUntilForget`: launch `sh -c 'sleep 0.2; exit 7'`, disconnect, after 500 ms `List` has `exited: true, code: 7`; `Forget` → gone.
  - `TestServer_ExitWhileAttachedDropsRecord`: attached through `exit 3` → `Exit{code:3}`, `List` empty.
  - `TestServer_ResizeSendsSigwinch`: child `sh -c 'trap "echo W" WINCH; while :; do sleep 0.05; done'`, `Resize` with the same size twice → output contains `W` twice.
  - `TestServer_AttachTakesOver`: second attach → first connection reads EOF.
  - `TestServer_IdleExit`: `IdleExit: 200ms`, no sessions, no clients → `Serve` returns within 1 s.
  - `TestListen_StaleSocketIsReplaced` and `TestListen_LiveHostReturnsErrHostRunning`.
  - `cmd/session_host_test.go` `TestSessionHostCmd_RequiresSocket`: no `--socket` → error.
- [ ] **Step 2: Run `go test ./internal/sessionhost ./cmd -run 'SessionHost|Server|Listen'` — expect FAIL.**
- [ ] **Step 3: Implement** `server.go` (accept loop, per-connection goroutine, idle timer) and `session.go` (PTY reader goroutine → ring + tracker + bound connection; `cmd.Wait` → exit record). A slow client must not block the PTY reader: buffer outgoing output per connection (a channel, 256 frames), and close the connection when it overflows.
- [ ] **Step 4: Run the same command — expect PASS; then `go test -race ./internal/sessionhost` once.**
- [ ] **Step 5: Commit** `feat(sessionhost): session host server and watchtower session-host (#496)`

### Task 3: Swift Core — frame codec, messages and socket path

**Depends on:** Task 1 (wire format)

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/SessionHost/SessionHostFrame.swift`, `…/SessionHostMessages.swift`, `…/SessionHostPaths.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/TerminalLaunch.swift` (store `package let rowID: Int64?`, set by `make`)
- Test: `WatchtowerDesktop/Tests/Core/SessionHostFrameTests.swift`

**Interfaces — Produces:**
- `package enum SessionHostFrameType: UInt8` (same values as Task 1).
- `package struct SessionHostFrame { type; payload: [UInt8]; func encoded() -> [UInt8] }`.
- `package struct SessionHostFrameDecoder { mutating func append(_ bytes: [UInt8]) throws -> [SessionHostFrame] }` (throws `.tooLarge` past 1 MiB).
- Codable mirrors with the Go JSON keys: `SessionHostLaunchRequest`, `SessionHostAttachRequest`, `SessionHostSessionInfo` (`row, run, pid, startedAtMs` ↔ `started_at_ms`, `exited, code`), `SessionHostListResponse`, `SessionHostResize`, `SessionHostExit`.
- `package enum SessionHostPaths { static func socketPath(bundleID: String, tempDir: String) -> String }`.

- [ ] **Step 1: Write the failing tests**: `testOutputFrameBytes` (`Output "hi"` → `[0x84,0,0,0,2,0x68,0x69]`, the Go vector), `testDecoderSplitsAcrossChunks` (two frames fed one byte at a time), `testDecoderRejectsOversize`, `testSessionInfoDecodesGoJSON` (`{"row":5,"run":"r","pid":42,"started_at_ms":1700000000000,"exited":true,"code":null}`), `testSocketPathIsShortAndStable` (same input → same path, `≤ 103` bytes for a 60-char temp dir, differs per bundle id).
- [ ] **Step 2: `make test-swift FILTER=SessionHostFrameTests` — expect FAIL.**
- [ ] **Step 3: Implement.** SHA-256 via CryptoKit.
- [ ] **Step 4: Same command — expect PASS; `make lint-swift`.**
- [ ] **Step 5: Commit** `feat(desktop): session host wire format in WatchtowerCore (#496)`

### Task 4: Desktop — host client, `HostedTerminalSession`, launch through the host

**Depends on:** Tasks 2, 3

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/SessionHost/SessionHostClient.swift`, `…/HostedTerminalSession.swift`
- Modify: `WatchtowerDesktop/Sources/Services/TerminalCenter.swift` (`PalettedTerminalView` host routing; `makeProcess` default; `unprotected` set), `WatchtowerDesktop/Sources/App/AppState.swift` (start the host client at init), the session pane view that shows terminal notices (`WatchtowerDesktop/Sources/Views/Workbench/WorkbenchSessionView.swift`)
- Test: `WatchtowerDesktop/Tests/HostedTerminalSessionTests.swift`, `WatchtowerDesktop/Tests/TerminalCenterTests.swift`

**Interfaces:**
- Consumes: Task 3 types.
- Produces:
  - `@MainActor protocol SessionHostTransport: AnyObject` — `func open(onFrame: @escaping (SessionHostFrame) -> Void, onClose: @escaping () -> Void) async throws`, `func send(_ frame: SessionHostFrame)`, `func close()`. Live: `UnixSocketTransport(path:)` over `NWConnection(to: .unix(path:), using: .tcp)`.
  - `@MainActor final class SessionHostClient` — `init(socketPath: String, cliPath: @escaping () -> String?, makeTransport: @escaping (String) -> any SessionHostTransport = { UnixSocketTransport(path: $0) })`; `func ensureRunning() async -> Bool` (connect + Hello; on failure spawn `<cli> session-host --socket <path>` with stdio to `~/Library/Application Support/Watchtower/session-host.log`, retry every 100 ms for up to 3 s); `func list() async throws -> [SessionHostSessionInfo]`; `func forget(row: Int64, run: String) async`; `func makeSessionTransport() -> any SessionHostTransport`.
  - `@MainActor final class HostedTerminalSession: TerminalSessionProcess` — `init(client: SessionHostClient)`; `start(_:)` sends `Launch` with a fresh `run` UUID and the same environment `SwiftTermSession.start` builds today; `func attach(_ info: SessionHostSessionInfo)` (Task 5 uses it); `pid` from `Launched`/`Attached`; `Output` → `terminal.feed(byteArray:)`; `Exit` → `onExit(code)` then `client.forget`; transport closed without `Exit` → `onExit(nil)`; `func detachFromHost()` closes the transport without signalling and clears `onExit`.
  - `PalettedTerminalView.hostInput: (([UInt8]) -> Void)?` and `hostResize: ((Int, Int) -> Void)?` — when `hostInput` is set, `send(source: TerminalView, data:)` (after the `onOwnerInput` check) goes to it instead of the local process. SwiftTerm's `sizeChanged(source:newCols:newRows:)` is `public`, not `open`, so it cannot be overridden: override `setFrameSize(_:)` instead, and after `super` call `hostResize` when `getTerminal().cols/rows` changed since the last call (and once on attach).
  - `TerminalCenter.sessionHost: SessionHostClient?` (nil = host unavailable) and `private(set) var unprotected: Set<Int64>` (sessions started on the local fallback). `makeProcess` default: `sessionHost.map { HostedTerminalSession(client: $0) } ?? SwiftTermSession()`.

- [ ] **Step 1: Write the failing tests** (a `FakeTransport` records sent frames and lets the test push frames):
  - `testStartSendsLaunchWithRowEnvAndSize`: `Launch` JSON has `row` = launch.rowID, `executable`/`args`/`cwd` from the launch, `env` contains `TERM=xterm-256color` and `SHELL=…`.
  - `testOutputIsFedAndOwnerInputGoesToHost`: pushed `Output "x"` shows in the terminal buffer; `sendInput([0x61])` sends `Input [0x61]` and does not call `onOwnerInput`; a keystroke path (`send(source:data:)`) does.
  - `testExitFrameReportsCodeAndForgets`, `testTransportCloseReportsNilExit`.
  - `testReattachedSessionReportsBracketedPaste`: `attach` then pushed `Output "\u{1b}[?2004h"` → `bracketedPasteMode == true`.
  - `testDetachFromHostNeverReportsExit`.
  - In `TerminalCenterTests`: `testLaunchFallsBackToLocalWhenHostUnavailable` (`sessionHost == nil` → the default factory yields a `SwiftTermSession`-like fake and `unprotected` contains the id) — inject via the factory seam, never a real host.
- [ ] **Step 2: `make test-swift FILTER='HostedTerminalSessionTests|TerminalCenterTests'` — expect FAIL.**
- [ ] **Step 3: Implement.** AppState: after the workspace opens, `terminalCenter.sessionHost = await client.ensureRunning() ? client : nil` (socket from `SessionHostPaths.socketPath(bundleID: Constants.bundleID, tempDir: NSTemporaryDirectory())`, CLI from `Constants.findCLIPath`). The pane shows one line for an `unprotected` session: "This session stops when Watchtower quits."
- [ ] **Step 4: Same command — expect PASS; `make lint-swift`.**
- [ ] **Step 5: Commit** `feat(desktop): workbench terminals run in the session host (#496)`

### Task 5: Desktop — reattach at launch

**Depends on:** Task 4

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/TerminalCenter.swift` (extract the wiring in `run(_:mode:codex:setup:)` into `private func wire(_ process:, session:)`; add `adopt`), `WatchtowerDesktop/Sources/ViewModels/WorkbenchesViewModel+Sessions.swift` (`reattachHostedSessions`), `WatchtowerDesktop/Sources/App/AppState.swift` (call it at the end of `initWorkbenches`, before `initMobileHub`)
- Test: `WatchtowerDesktop/Tests/TerminalCenterReattachTests.swift`

**Interfaces:**
- Consumes: Task 4 (`SessionHostClient.list/forget`, `HostedTerminalSession.attach`).
- Produces: `TerminalCenter.adopt(_ session: TerminalSession, info: SessionHostSessionInfo)` — registers a `HostedTerminalSession`, wires it like `run`, sets `states[id] = .running` and `startedAt[id] = Date(ms: info.startedAtMs)`, then `attach(info)`; never builds a `TerminalLaunch`, never touches `resumeStarts`. `WorkbenchesViewModel.reattachHostedSessions() async`.

- [ ] **Step 1: Write the failing tests** (fake client returning a fixed `list`):
  - `testProj20_ReattachAdoptsRunningSessionWithoutRelaunch`: a listed running session of an existing row → `states == .running`, `startedAt` from the host, the factory's `start` never called, an `Attach` frame sent.
  - `testReattachStopsSessionWhoseRowIsGone`: listed row id with no row → the signaller gets `SIGHUP` for its pid (then `SIGKILL` if alive after the grace), then `forget`.
  - `testReattachReportsExitOnceAndForgets`: listed `exited: true, code: 0` → `onSessionExit(id, 0, false)` once, `forget` sent; a second `reattachHostedSessions` with an empty list reports nothing.
  - `testReattachIgnoresListFailure`: `list` throws → nothing adopted, no crash, rows read as stopped.
- [ ] **Step 2: `make test-swift FILTER=TerminalCenterReattachTests` — expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Same command, then `FILTER='TerminalCenter|WorkbenchesViewModel'` — expect PASS; `make lint-swift`.**
- [ ] **Step 5: Commit** `feat(desktop): reattach to live sessions at launch (#496)`

### Task 6: Desktop — quit and update keep sessions

**Depends on:** Task 5

**Files:**
- Modify: `WatchtowerDesktop/Sources/App/QuitCoordinator.swift`, `WatchtowerDesktop/Sources/App/TrayAppDelegate.swift` (`quitPrompt`, `confirmQuit`, `applicationShouldTerminate`, `requestQuit(forUpdate:)`), `WatchtowerDesktop/Sources/Services/UpdateService.swift` (`RelaunchSteps.live.requestQuit` → `TrayAppDelegate.requestQuit(forUpdate: true)`), `WatchtowerDesktop/Sources/Services/TerminalCenter.swift` (`detachAll()`, `liveHostedCount`)
- Test: `WatchtowerDesktop/Tests/QuitCoordinatorTests.swift`, `WatchtowerDesktop/Tests/TrayAppDelegateTests.swift`, `WatchtowerDesktop/Tests/TerminalCenterTests.swift`

**Interfaces — Produces:**
- `enum QuitChoice { case cancel, quitKeepingSessions, quitStoppingSessions }`.
- `QuitCoordinator.shouldTerminate(hasBlockingWork:confirmQuit: () -> QuitChoice, closeChatSessions:, closeTerminals:, detachTerminals:, stopDaemon:, reply:)` — `.quitKeepingSessions` runs `detachTerminals`, `.quitStoppingSessions` runs `closeTerminals`; chat sessions still close first and the daemon still stops last (chat.md inventory order unchanged).
- `TrayAppDelegate.quitPrompt(recording: Bool, askDrafts: Int, liveSessions: Int) -> QuitPrompt?` — `QuitPrompt` gains `keepSessionsTitle: String?` ("Keep Sessions and Quit"); with `liveSessions > 0` the quit button reads "Stop Sessions and Quit"; message for sessions only: "N workbench sessions are running" / informative "Keep them running and Watchtower reattaches when you open it again, or stop them now."; recording and drafts text stays and is combined into the one alert.
- `TrayAppDelegate.requestQuit(forUpdate: Bool = false)`; an update quit and a logout/restart/shutdown quit (the current Apple event's `kAEQuitReason` is `kAELogOut`, `kAEReallyLogOut`, `kAEShowRestartDialog`, `kAERestart`, `kAEShowShutdownDialog` or `kAEShutDown`) pass `liveSessions: 0` and detach.
- `TerminalCenter.detachAll()` — hosted processes `detachFromHost()`; local fallback processes close as today. `TerminalCenter.liveHostedCount: Int`.

- [ ] **Step 1: Write the failing tests:**
  - `testProj20_UpdateQuitDetachesHostedSessions`: update quit with live sessions → no prompt, `detachTerminals` runs, `closeTerminals` does not.
  - `testKeepSessionsChoiceDetaches`, `testStopSessionsChoiceCloses`, `testCancelChoiceCancels`, `testNoLiveSessionsQuitsWithoutSessionPrompt`.
  - `testQuitPromptCombinesRecordingAndSessions` (both texts, three buttons).
  - `testSystemLogoutNeverPrompts` (inject the quit reason).
  - `testDetachAllNeverSignals` (signaller records no signal for hosted sessions; the local fallback session gets SIGHUP).
  - Existing `QuitCoordinatorTests` chat-before-daemon ordering stays green unchanged in its assertions.
- [ ] **Step 2: `make test-swift FILTER='QuitCoordinatorTests|TrayAppDelegateTests|TerminalCenterTests'` — expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Same command — expect PASS; `make lint-swift`.**
- [ ] **Step 5: Commit** `feat(desktop): an update or Keep Sessions quit leaves sessions running (#496)`

### Task 7: Docs, contract and gate

**Depends on:** Tasks 1–6

**Files:**
- Modify: `docs/features/workbench.md` (the terminal paragraph: host, reattach, quit prompt, fallback, known limits — no reboot survival, phone/notices quiet while the app is closed), `docs/inventory/workbench.md` (new **PROJ-20** — a hosted session survives an update and is adopted without a relaunch; guard tests `TestSessionHost20_SessionSurvivesClientDisconnect`, `testProj20_ReattachAdoptsRunningSessionWithoutRelaunch`, `testProj20_UpdateQuitDetachesHostedSessions`; a dated changelog entry), `docs/guide/features/workbench/sessions.md` (what happens on update and on Quit, per `docs/guide/WRITING.md`), `CLAUDE.md` (append the session host to the Workbench feature line)

- [ ] **Step 1: Write the docs.**
- [ ] **Step 2: Gate:** `make test`, `make test-swift`, `make lint-all` — all pass (`bash scripts/dev-health.sh` first).
- [ ] **Step 3: Manual check by the owner (ask):** start two sessions with a running subagent and a `sleep 600` in background, install an update (or quit with Keep Sessions), reopen — both sessions are on screen, the agent kept working, the background job is alive, typing and an ask answer work.
- [ ] **Step 4: Commit** `docs: session host — workbench guide, PROJ-20 (#496)`
