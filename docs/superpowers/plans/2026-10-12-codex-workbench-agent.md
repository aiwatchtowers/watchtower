# Codex as a Workbench agent (board #399) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Workbench session can run Codex CLI with the same features as Claude Code: brief, skill, MCP, drift check,
ask guard, state dot, titles, report, resume, Work on It, ask and comment delivery, and the phone. Claude Code
sessions do not change.

**Architecture:** `terminal_sessions.kind` gains `codex` (table rebuild; the id may be NULL until the first
SessionStart). A small agent seam in Go (`internal/agentkind`, per-agent hook set, transcript reader, input dialect)
has a twin in Swift (`AgentKind`, `TerminalLaunch.Mode`, `AgentInputProfile`). For codex, MCP and hooks travel as
launch flags built by one Go command (`workbench launch-args`). Hook trust is recorded once through codex's own
app-server API. The skill goes into `.agents/skills/`. Hook commands are workbench-agnostic and find their row through
`WATCHTOWER_TERMINAL_SESSION_ID`.

**Tech Stack:** Go 1.25 (`cmd/`, `internal/*`), SQLite + goose, SwiftUI/GRDB (WatchtowerCore + app target),
WatchtowerKit.

**Spec:** `docs/superpowers/specs/2026-10-12-codex-workbench-agent-design.md` (the source of truth; §2 lists the codex
facts) and `…-business.md` (owner decisions D1–D7). Every executor reads both before starting a task. Spike evidence is
in the session scratchpad `codex-399-spike.md`. Fixtures come from Task 0, never from the spike's raw logs.

**Plan style (owner preference):** no code bodies. Each task gives the goal, files, interfaces (signatures only),
test cases (name + what it asserts), dependencies, lane and size. Task-scope checks only. The full gate runs once, in
Task 14.

## Global Constraints

- Feature branch `feat/399-codex-agent`. Each lane works in its own worktree off it, and the controller merges.
  Before every git command, check `git branch --show-current`.
- Claude Code behaviour is byte-identical (spec I1): every existing `TestProj*` / `testProj*` guard runs unchanged
  and green. No guard is weakened, renamed or split.
- Never pass `--dangerously-bypass-hook-trust`. Never write `projects.*` into `~/.codex/config.toml`. Write there only
  `hooks.state` keys of our own commands, through `config/batchWrite` (spec I4).
- Hashed hook strings and launched hook strings come from one function, `devpack.CodexHookSet` (spec I5).
- Tests never run a real `codex` and never touch the real `~/.codex`. The app-server is faked by a stdio test double,
  and `CODEX_HOME` points at `t.TempDir()`.
- Public repo: fixtures carry no real session ids, paths or user names. Use placeholder UUIDs and `/Users/example`.
  `bash scripts/leak-check.sh` runs before every commit.
- Inner loop only: `go test ./internal/<pkg>`, `go test ./cmd -run '<regex>'`, `make test-swift FILTER=<Class>`,
  `make lint-diff`. No `-count=1`. Logs go to a file with an explicit exit code (`cmd > log 2>&1; echo "exit=$?"`),
  never piped through `tail`.
- **One Swift build lane at a time**: Tasks 2 → 12 → 10 → 9 → 11, strictly in sequence. Swift CI is 6.3, locally 6.4:
  no local `let` in a view that shadows a property, and no 6.4-only API.
- The sentrux complexity gate counts tests too. Split a big table-driven test into helpers rather than one huge
  function. Keep a new function's CC well under 13.
- UI strings are English only. `docs/app-guide.md` is updated in the same task as any UI change.
- Commits are in English and end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Implementers do not
  push.

## Review Focus

1. **NULL-id codex rows.** Every hook write except SessionStart must ignore a codex row whose id is NULL (I6), and the
   Claude CHECK must still reject a NULL Claude id (Task 1, Task 6).
2. **Workbench-agnostic hooks.** A codex hook whose env names a row of another kind, a deleted row or no row writes
   nothing and exits 0 (Task 5).
3. **Trust writes.** Only `sessionFlags` entries with our commands are upserted. A foreign `hooks.state` key or any
   other config key survives byte for byte (Task 4).
4. **Launch strings = trusted strings.** A golden test compares `launch-args` output with the strings the trust step
   hashes (Task 3, Task 4).
5. **Claude argv and installer output are unchanged** (Task 3, Task 9 goldens).

---

## Task list

| # | Title | Lane | Depends on | Size |
|---|---|---|---|---|
| 0 | Capture redacted codex hook and rollout fixtures | Go (testdata) | none | S |
| 1 | Migration: rebuild `terminal_sessions` for codex, `internal/agentkind`, DB guards | Go | none | M |
| 2 | Swift Core: `.codex` kind, `AgentKind`, optional id, queries, test schema | Swift | 1 | M |
| 3 | Codex hook set and `workbench launch-args` | Go | 1 | M |
| 4 | Codex installer: app-server trust client, `integrate codex`, status, remove, dedupe | Go | 3 | L |
| 5 | Hook row resolver and payload normalization (`--agent codex`) | Go | 1 | M |
| 6 | Codex hook handling: brief/re-key, state, background, Stop check, ask guard, probe | Go | 0, 5 | L |
| 7 | Transcript reader for codex rollouts and `terminal title` | Go | 0, 1 | M |
| 8 | Agent labels, skill and prompt text, docs listing, report, `workbench.default_agent` | Go | 1 | S |
| 9 | Swift launch builder, resume decision, rollout locator | Swift | 2, 3, 12 | M |
| 10 | Swift input profile for ask/comment delivery | Swift | 0, 2, 12 | S |
| 11 | Swift UI: agent choice, Settings default, install status/Repair, strings, app-guide | Swift | 4, 8, 9, 10 | L |
| 12 | Mobile Hub and WatchtowerKit agent field | Swift | 2 | S |
| 13 | Inventory amendments and feature docs | Docs | 6, 7, 11 | S |
| 14 | Final gate | all | 0–13 | M |
| 15 | Owner manual check | Owner | 14 | — |

Parallel lanes: Task 0 runs alongside Task 1. After Task 1, the Go lanes {3 → 4}, {5 → 6}, {7} and {8} run in parallel,
each in its own worktree (6 and 7 also wait for Task 0). The Swift lane runs 2 → 12 → 10 → 9 → 11 strictly in sequence.
Within each lane, only the files listed for a task change. Overlaps the controller watches when merging: Tasks 3/4
both touch `internal/devpack`; Tasks 5/6 both touch `cmd/workbench_*`; Task 8 touches `workbenchskill/SKILL.md` only.

---

### Task 0: Capture redacted codex hook and rollout fixtures

**Goal:** pin the payloads the parsers read, and settle the facts that spec §2 lists as unverified.
**Lane:** Go, testdata only, no product code. **Size:** S. **Depends on:** none.

**Files:**
- Create: `cmd/testdata/codex_hooks/*.json` (one per event: session_start_{startup,resume,clear}, user_prompt_submit,
  pre_tool_use_{bash,mcp,request_user_input}, permission_request, post_tool_use, stop, stop_hook_active,
  subagent_start, subagent_stop, session_end)
- Create: `internal/terminal/testdata/codex/{paginated,legacy,meta_only,truncated_tail,zstd_header,images_only}.jsonl`
- Create: `docs/superpowers/specs/2026-10-12-codex-workbench-agent-capture.md` (a short findings note, no secrets)

**Steps:**
- Use a scratch folder (outside the repo) and a throwaway `CODEX_HOME` copy holding only `auth.json`. Launch with the
  Task 3 hook set shape, using a logger command. Trust is written by hand through the app-server (spec C5).
- Capture: a subagent run (does the parent session get `SubagentStart`/`SubagentStop` with `agent_id`?), an interactive
  approval (`PermissionRequest` → grant → `PostToolUse`), `/compact` (`source` value), two Stop handlers both blocking,
  the composer's newline and Esc keys, a prompt argument starting with `-`.
- Redact: placeholder UUIDs, `/Users/example`, no prompt text beyond "example".

**Test cases:** none (consumed by Tasks 6, 7 and 10). Verification: `bash scripts/leak-check.sh` is clean, and every
fixture parses with `jq`.

---

### Task 1: Migration: rebuild `terminal_sessions` for codex, `internal/agentkind`, DB guards

**Goal:** allow `kind = 'codex'` with a NULL id, add `agent_transcript_path`, and make every agent-row guard accept
both kinds.
**Lane:** Go. **Size:** M. **Depends on:** none.

**Files:**
- Create: `internal/db/migrations/<next>_terminal_sessions_codex.sql` (check the next free number against
  `origin/main` at start and again in Task 14)
- Modify: `internal/db/schema.sql`. Regenerate `internal/db/testdata/schema_v*.golden` and
  `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`
- Create: `internal/agentkind/kind.go`, `internal/agentkind/kind_test.go`
- Modify: `internal/db/terminal_sessions.go`, `internal/db/terminal_agent_turns.go`, `internal/db/session_report.go`,
  `internal/db/owner_asks.go` (only where they filter `kind = 'claude'`)
- Create: `internal/db/terminal_sessions_codex_migration_test.go`, `internal/db/terminal_sessions_codex_test.go`

**Interfaces:**
- `package agentkind`: `type Kind string`; `const Claude, Codex Kind`; `func Parse(string) (Kind, bool)`;
  `func IsAgent(string) bool`; `func (Kind) Label() string`; `func (Kind) DisplayName() string`;
  `func SQLKinds() string`
- `db.TerminalSession.TranscriptPath sql.NullString`
- `func (db *DB) SetTerminalAgentSessionID(id, workbenchID int64, sessionID, transcriptPath string) (bool, error)`.
  NULL → id only, for `kind = 'codex'`. It clears the agent state columns like `SetTerminalClaudeSessionID`.
- `func (db *DB) SetTerminalTranscriptPath(id, workbenchID int64, sessionID, path string) (bool, error)`
- `func (db *DB) ResetTerminalAgentSession(id, workbenchID int64) error`. Codex only: id and path to NULL, state
  cleared (Start fresh). Swift has a twin write in Task 9; see the dual-path note there.

**Test cases:**
- `TestMigrationCodex_KindCheckAcceptsCodexWithNullID`: a codex row with a NULL id inserts.
- `TestMigrationCodex_ClaudeStillNeedsAnID`: a claude row with a NULL id fails the CHECK.
- `TestMigrationCodex_RebuildKeepsRowsAndChildren`: seed claude and shell rows, `owner_asks`,
  `terminal_session_targets` and `owner_presence` that point at them. After Up, every row and child is identical and
  presence still points at its session.
- `TestMigrationCodex_IndexesRecreated`: the index list equals the pre-migration list.
- `TestMigrationCodex_DownDropsCodexRowsAndColumn`: Down succeeds with codex rows present; claude/shell rows survive;
  `agent_transcript_path` is gone; re-Up works.
- `TestProj11_CodexNullIDIgnoresStateWrites`: with a NULL id, `SetTerminalAgentState`, `MarkTerminalAgentRun`,
  `LowerTerminalBackground` and the `agent_turns` writes all return false and leave the row byte-identical.
- `TestSetTerminalAgentSessionID_OnlyFromNull`: the first call sets the id; a second call with another id returns
  false; a claude row returns false.
- `TestAgentGuardsAcceptCodex`: every guarded write succeeds on a codex row with a matching id and fails with another
  id or workbench.
- `TestAgentKind_*`: Parse/IsAgent/Label/DisplayName; an unknown kind and `shell` are not agents.
- Every existing `TestProj11_*` stays green unchanged.

**Verification:** `go test ./internal/db ./internal/agentkind`, `go test ./internal/db -run 'TestSchemaGolden|TestDesktopTestSchema'`,
and `make lint-diff`.

---

### Task 2: Swift Core: `.codex` kind, `AgentKind`, optional id, queries, test schema

**Goal:** the Desktop model reads and writes codex rows, and every "agent session" check covers both kinds.
**Lane:** Swift. **Size:** M. **Depends on:** Task 1 (schema).

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Models/AgentKind.swift`
- Modify: `WatchtowerCore/Models/TerminalSession.swift`, `WatchtowerCore/Database/Queries/TerminalSessionQueries.swift`,
  `WatchtowerCore/Services/TerminalSessionPolicy.swift`, `WorkbenchesViewModel+Report.swift`, `+Panel.swift`,
  `Services/TerminalCenter.swift` (only `liveClaudeIDs` → `liveAgentIDs`, `hasLiveClaudeSession` →
  `hasLiveAgentSession`), `Services/SessionAgentStateCenter.swift`, `Services/CodeHandoffCenter.swift` (filter only)
- Tests: `WatchtowerDesktop/Tests/…/TerminalSessionQueriesTests.swift`, `TerminalSessionPolicyTests.swift`

**Interfaces:**
- `enum AgentKind: String, CaseIterable, Sendable { case claude, codex }` with `displayName`, `label`
- `TerminalSession.Kind`: `case claude, codex, shell`; `var isAgent: Bool`; `var agent: AgentKind?`;
  `var transcriptPath: String?`
- `NewSession.claudeSessionID: String?` (must be non-nil for `.claude`; the precondition is enforced in the insert
  helper and tested)
- `TerminalSessionQueries.resetAgentSession(_ db:, id:)` (Start fresh for codex)

**Test cases:**
- `testCodexRowWithNullIDDecodes`
- `testFetchAgentStatesIncludesCodexRows`
- `testPolicyPicksLiveCodexSessionAsActive`
- `testShellIsNeverAnAgent`
- `testInsertClaudeWithoutIDIsRejected`
- `testResetAgentSessionNullsIDAndPathForCodexOnly`
- Existing `testProj11_*` stay green.

**Verification:** `make test-swift FILTER=TerminalSession` and `FILTER=TerminalSessionPolicy`, then `make lint-diff`.

---

### Task 3: Codex hook set and `workbench launch-args`

**Goal:** one Go source for the codex launch flags (MCP + hooks + `--no-daemon`) and the binary path.
**Lane:** Go. **Size:** M. **Depends on:** Task 1 (`agentkind`).

**Files:**
- Create: `internal/devpack/codex_hooks.go`, `internal/devpack/codex_hooks_test.go`
- Create: `cmd/workbench_launch_args.go`, `cmd/workbench_launch_args_test.go`
- Modify: `internal/codex/mcp.go` (reuse the override builder; add the approval-mode key)
- Golden: `internal/devpack/testdata/codex_launch_args.golden`

**Interfaces:**
- `type CodexHook struct { Event, Matcher, Command string; TimeoutSec, Group int }`
- `func CodexHookSet(bin string) []CodexHook`, in the fixed order of spec §4.3
- `func CodexHookOverrides(hooks []CodexHook) []string`: the `-c hooks.<Event>=[…]` TOML inline values
- `func CodexMCPOverrides(bin string, workbenchID int64) []string`
- `type LaunchArgs struct { Binary, PathPrepend string; Args []string }`
- `func CodexLaunchArgs(cfg *config.Config, bin string, workbenchID int64, find func() (string, error)) (LaunchArgs, error)`
- CLI: `watchtower workbench launch-args --agent codex --workbench N --json`. Exit 3 with `{"error":"codex_not_found"}`.

**Test cases:**
- `TestCodexHookSet_GoldenOrderAndTimeouts`
- `TestCodexHookSet_CommandsAreWorkbenchAgnostic`: no `--workbench` in any hook command.
- `TestCodexHookSet_BinWithSpacesIsQuoted`: an "Application Support" path.
- `TestCodexHookOverrides_ParseAsTOML`: each value round-trips through the TOML decoder into
  `[{matcher?, hooks=[{type="command", command, timeout}]}]`.
- `TestCodexMCPOverrides_IncludeApproveAndAgentFlag`
- `TestLaunchArgs_CodexPathConfigWins`, `TestLaunchArgs_FallsBackToFindBinary`
- `TestLaunchArgs_MissingCodexExits3WithJSON`: the degenerate case of a missing codex binary.
- `TestLaunchArgs_PathPrependIsBinaryDir`
- `TestLaunchArgs_UnknownAgentIsUsageError`
- `TestLaunchArgs_ClaudeAgentNotSupported`: v1 is codex only; Claude keeps its Swift argv.

**Verification:** `go test ./internal/devpack ./internal/codex` and `go test ./cmd -run 'TestLaunchArgs'`, then
`make lint-diff`.

---

### Task 4: Codex installer: app-server trust client, `integrate codex`, status, remove, dedupe

**Goal:** `watchtower integrate codex --workbench N` installs the skill and trusts our hooks. `integrate status` reports
codex. `--remove` undoes it. Imported Claude duplicates are cleaned.
**Lane:** Go. **Size:** L. **Depends on:** Task 3.

**Files:**
- Create: `internal/codex/appserver.go`, `internal/codex/appserver_test.go` (stdio JSON-RPC client with a fake server
  binary built in the test, the `TestHelperProcess` pattern)
- Create: `internal/devpack/codex_install.go`, `internal/devpack/codex_install_test.go`
- Modify: `internal/devpack/workbench.go` (exclude lines, `WorkbenchStatus.Codex`), `cmd/integrate.go` (subcommand
  `codex`), `cmd/integrate_workbench.go` (status JSON `codex` object, messages)
- Modify: `cmd/integrate_workbench_test.go`, `cmd/integrate_test.go`

**Interfaces:**
- `type AppServer interface { ListHooks(ctx, cwd string) ([]HookEntry, error); TrustHooks(ctx, []HookEntry) error; Close() error }`
- `type HookEntry struct { Key, Command, CurrentHash, TrustStatus, Source, Event string }`
- `func StartAppServer(ctx context.Context, bin string, extraArgs []string, env []string) (AppServer, error)` (10 s budget;
  the process group is killed on timeout)
- `var ErrCodexTrustUnavailable`
- `type CodexStatus struct { Found, Skill bool; HooksTrusted *bool; ImportedDuplicates bool }`
- `func InstallCodex(ctx, opts WorkbenchInstallOptions, srv func() (AppServer, error)) (CodexStatus, error)`
- `func RemoveCodex(ctx, opts, srv) error`
- `func StatusCodex(ctx, opts, srv) (CodexStatus, error)`
- `func dedupeImportedHooks(folder string, workbenchID int64) (changed bool, err error)` (`.codex/hooks.json` and the
  `[hooks]` of `.codex/config.toml`)

**Test cases:**
- `TestAppServer_ListAndTrustRoundTrip`: the fake receives `initialize`, `hooks/list` with the folder as cwd, and one
  `config/batchWrite` holding only the untrusted keys.
- `TestAppServer_TrustSkipsForeignAndAlreadyTrusted`: a `project` source entry, a foreign `sessionFlags` command and a
  trusted entry are not written.
- `TestAppServer_TimeoutKillsAndReturnsUnavailable`
- `TestAppServer_UnknownMethodErrorIsUnavailable`: the protocol changed.
- `TestInstallCodex_Idempotent`: run twice; one skill copy, one exclude line, zero batch writes on the second run.
- `TestInstallCodex_SkillBytesEqualClaudeCopy` (I7)
- `TestInstallCodex_MissingCodexStillInstallsSkillAndReportsNotFound`
- `TestProj04_CodexTrustNeverTouchesOtherConfigKeys`: the fake asserts the batch edits only `hooks.state` entries
  with our keys.
- `TestProj04_DedupeKeepsForeignHooks`: our Claude-suffix entries are removed, foreign entries and keys are kept, an
  emptied file that was ours alone is deleted.
- `TestProj04_MalformedImportedHooksNeverWritten`: returns `ErrMalformedSettings`, and the status reports the
  duplicates.
- `TestRemoveCodex_RemovesSkillExcludeAndOurTrustOnly`: an empty `.agents/` is removed, a non-empty one is kept.
- `TestStatusCodex_NullTrustWhenAppServerUnavailable`
- `TestIntegrateStatusJSON_HasCodexObjectAndKeepsClaudeKeys`: a golden of the full JSON.
- `TestIntegrateCodex_FolderGoneIsCleanError`: the degenerate case of a deleted folder.

**Verification:** `go test ./internal/codex ./internal/devpack` and `go test ./cmd -run 'TestIntegrate'`, then
`make lint-diff`.

---

### Task 5: Hook row resolver and payload normalization (`--agent codex`)

**Goal:** every workbench hook command accepts `--agent codex` without `--workbench`, resolves its row from
`WATCHTOWER_TERMINAL_SESSION_ID`, and decodes Claude and codex payloads into one struct. For Claude this is a pure
refactor.
**Lane:** Go. **Size:** M. **Depends on:** Task 1.

**Files:**
- Create: `cmd/workbench_hook_row.go`, `cmd/workbench_hook_input.go` and their `_test.go` files
- Modify: `cmd/workbench_brief.go`, `cmd/workbench_brief_session.go`, `cmd/workbench_session_state.go`,
  `cmd/workbench_check.go`, `cmd/workbench_askguard.go`, `cmd/workbench_askguard_stop.go` (flag parsing and input
  decode only; behaviour moves in Task 6)

**Interfaces:**
- `func resolveHookRow(d *db.DB, agent agentkind.Kind, flagWorkbench int64, env func(string) string) (db.TerminalSession, bool, error)`
- `type hookEvent struct { … }` (spec §6.2)
- `func parseHookEvent(agent agentkind.Kind, raw []byte) (hookEvent, error)`
- Flag rule: exactly one of `--workbench N` or `--agent codex`; both, or neither → usage error (exit 0 with a stderr
  line when invoked as a hook).

**Test cases:**
- `TestResolveHookRow_CodexFromEnv`
- `TestResolveHookRow_NoEnvIsSilentNoop`
- `TestResolveHookRow_RowOfAnotherKindIsNoop`
- `TestResolveHookRow_DeletedRowIsNoop`
- `TestResolveHookRow_ClaudePathUnchanged`
- `TestParseHookEvent_ClaudeFixturesUnchanged`: every existing Claude fixture decodes to the same fields as before.
- `TestParseHookEvent_CodexFixtures`: per Task 0 file.
- `TestParseHookEvent_EmptyStdinIsCleanExit`
- `TestParseHookEvent_MissingSessionIDIsNoWrite`: the degenerate case of a hook payload without `session_id`.
- `TestParseHookEvent_UnknownEventIsNoop`
- `TestParseHookEvent_NonJSONIsNoop`
- Every existing `cmd` workbench hook test stays green unchanged.

**Verification:** `go test ./cmd -run 'TestResolveHookRow|TestParseHookEvent|TestProj11_|TestProj13_|TestWorkbench'`,
then `make lint-diff`.

---

### Task 6: Codex hook handling: brief/re-key, state, background, Stop check, ask guard, probe

**Goal:** codex events drive the same columns as Claude's, following the mapping in spec §5 and §6.3–6.4.
**Lane:** Go. **Size:** L. **Depends on:** Task 0, Task 5.

**Files:**
- Modify: `cmd/workbench_brief_session.go`, `cmd/workbench_session_state.go`, `cmd/workbench_check.go`,
  `cmd/workbench_askguard.go`, `cmd/workbench_askguard_stop.go`, `cmd/workbench_session_probe.go`
- Tests: `cmd/workbench_codex_hooks_test.go` (new; split per event group to stay under the complexity gate)

**Interfaces:**
- `func planCodexSessionStart(stored sql.NullString, ev hookEvent) sessionStartPlan` (`set`, `mark`, `move`, `none`)
- `agentStateFor` gains `PermissionRequest` → `approval`
- `func codexBackgroundCount(turns db.AgentTurns) int64`: open turns at Stop
- `session-probe` on a codex row → `probeUnknown`

**Test cases:**
- `TestCodexSessionStart_StartupSetsNullID`: and stores the transcript path.
- `TestCodexSessionStart_StartupWithOtherStoredIDWritesNothing`
- `TestCodexSessionStart_ResumeMarksRun`, `TestCodexSessionStart_ClearMovesIDAndClearsState`
- `TestCodexSessionStart_UnknownSourceActsAsStartup`
- `TestCodexSessionStart_MissingSessionIDPrintsBriefOnly`
- `TestCodexSessionStart_RelativeTranscriptPathNotStored`
- `TestCodexBrief_NoClaudeCodeStringAndWithinBudget`
- `TestProj11_CodexPermissionRequestIsApproval`, `TestProj11_CodexPostToolUseClearsApproval`
- `TestProj11_CodexStopWritesWaitingAndOpenTurnCount`
- `TestProj11_CodexSubagentStopLowersCount`
- `TestProj11_CodexForeignSessionIDIgnored`
- `TestProj11_CodexRowNeverGetsFailure`
- `TestProj11_CodexStopGateTrueWithoutSettingsFile`
- `TestProj07_CodexStopBlockShape`: block JSON identical; `stop_hook_active` honoured.
- `TestProj13_CodexAskGuardStopUsesLastAssistantMessage`
- `TestProj13_CodexPreToolUseDeniesRequestUserInput`: present and away reasons.
- `TestProj13_CodexAskGuardEmptyMessageNoModelCall`
- `TestSessionProbe_CodexRowIsUnknownWithoutClaudeDir`
- Every existing Claude guard stays green unchanged.

**Verification:** `go test ./cmd -run 'TestCodex|TestProj07_|TestProj11_|TestProj13_|TestSessionProbe'`, then
`make lint-diff`.

---

### Task 7: Transcript reader for codex rollouts and `terminal title`

**Goal:** AI titles work for codex sessions. The reader tolerates both dialects and any degenerate file.
**Lane:** Go. **Size:** M. **Depends on:** Task 0, Task 1.

**Files:**
- Create: `internal/terminal/codex_rollout.go`, `internal/terminal/codex_rollout_test.go`
- Modify: `internal/terminal/transcript.go` (the `Transcript` interface plus `OpenTranscript`; the Claude code moves
  behind it unchanged), `cmd/terminal.go` (the `kind` gate becomes `IsAgent`; the agent home is `CODEX_HOME` or
  `~/.codex`)
- Modify: `cmd/terminal_test.go`

**Interfaces:**
- `type Transcript interface { OwnerLines(max int) ([]string, error) }`
- `func OpenTranscript(kind agentkind.Kind, sessionID, storedPath, agentHome string) (Transcript, error)`
- `var ErrUnsupportedTranscript`; `ErrNoTranscript` stays

**Test cases:**
- `TestCodexRollout_PaginatedOwnerLines`: injected-context `response_item` lines are skipped.
- `TestCodexRollout_LegacyOwnerLines`
- `TestCodexRollout_MixedDialectsInOneFile`
- `TestCodexRollout_EmptyFileNoLines`: the degenerate case of an empty rollout.
- `TestCodexRollout_MetaOnlyNoLines`
- `TestCodexRollout_TruncatedLastLineIgnored`
- `TestCodexRollout_ZstdIsUnsupported`: the degenerate case of a compressed rollout.
- `TestCodexRollout_UnknownFormatIsUnsupported`: the degenerate case of an unknown format.
- `TestCodexRollout_ImagesOnlyMessageSkipped`
- `TestCodexRollout_LocateByStoredPathThenGlob`
- `TestCodexRollout_MissingIsErrNoTranscript`
- `TestCodexRollout_NonUUIDRejected`
- `TestTerminalTitle_CodexRowUsesRollout`
- `TestTerminalTitle_CodexUnsupportedLeavesTitle`
- Existing Claude transcript tests stay green unchanged.

**Verification:** `go test ./internal/terminal` and `go test ./cmd -run 'TestTerminalTitle'`, then `make lint-diff`.

---

### Task 8: Agent labels, skill and prompt text, docs listing, report, `workbench.default_agent`

**Goal:** the small neutral-text and label changes plus the config key, kept out of the bigger lanes.
**Lane:** Go. **Size:** S. **Depends on:** Task 1.

**Files:**
- Modify: `internal/tools/workbench_docs.go` (the label comes from the row kind, then the `--agent` flag, then
  `claude-code`), `cmd/mcp.go` (the `--agent` flag), `internal/devpack/workbenchskill/watchtower-workbench/SKILL.md`,
  `internal/prompts/defaults.go` (TerminalTitle text; follow the prompt-version rules of `add-ai-prompt`),
  `internal/workbenchdocs/list.go`, `internal/sessionreport/summary.go`, `cmd/workbench_session_report.go`,
  `internal/config/config.go` (`Workbench.DefaultAgent`), `cmd/workbench_git.go` and
  `internal/workbenchgit/switch.go` (doc strings only)
- Tests next to each file

**Interfaces:**
- `func agentLabelFor(row *db.TerminalSession, flag agentkind.Kind) string`
- `config.WorkbenchConfig{DefaultAgent string}`; `func (c WorkbenchConfig) Agent() agentkind.Kind` (an unknown value
  reads `Claude`)

**Test cases:**
- `TestAgentLabel_CodexRowIsCodexCLI`, `TestAgentLabel_NoRowUsesFlagThenDefault`
- `TestSkillText_NamesBothToolSpellings`: the skill golden is updated.
- `TestWorkbenchDocs_HidesCodexAndAgentsSkill`
- `TestSessionReport_IncludesCodexSessions`
- `TestConfig_DefaultAgentUnknownReadsClaude`
- `TestPrompts_TerminalTitleIsAgentNeutral`

**Verification:** `go test ./internal/tools ./internal/devpack ./internal/prompts ./internal/workbenchdocs ./internal/sessionreport ./internal/config`,
then `make lint-diff`.

---

### Task 9: Swift launch builder, resume decision, rollout locator

**Goal:** the Desktop launches and resumes Codex sessions. The Claude argv is unchanged.
**Lane:** Swift. **Size:** M. **Depends on:** Task 2, Task 3, Task 12 (Swift lane order).

**Files:**
- Modify: `WatchtowerCore/Services/TerminalLaunch.swift`, `Services/TerminalCenter.swift` (start/resume decision,
  resume-failure tracking keyed by mode), `ViewModels/WorkbenchesViewModel+Sessions.swift` (new-session and Start
  fresh paths), `Services/WorkbenchCLI.swift` (`launchArgs(agent:workbench:)`)
- Create: `WatchtowerCore/Services/CodexRollout.swift` (`exists(sessionID:storedPath:codexHome:)`)
- Tests: `TerminalLaunchTests`, `CodexRolloutTests`, `TerminalCenterStartDecisionTests`

**Interfaces:**
- `TerminalLaunch.Mode`: `.newAgent(AgentKind, sessionID: String?, prompt: String?)`,
  `.resumeAgent(AgentKind, sessionID: String)`, `.shell`
- `struct CodexLaunchArgs: Decodable { binary, pathPrepend: String; args: [String] }`
- `WorkbenchCLI.launchArgs(agent: AgentKind, workbenchID: Int64) async throws -> CodexLaunchArgs` (throws
  `.agentNotFound(.codex)` on exit 3)
- `enum CodexRollout { static func exists(sessionID: String, storedPath: String?, codexHome: URL) -> Bool }`
- Dual path: `resetAgentSession` (Swift, Start fresh) and Go `ResetTerminalAgentSession` write the same columns.
  A shared fixture test pins both (review-rules "Go ↔ Swift dual-path contracts").

**Test cases:**
- `testClaudeArgvGoldenUnchanged`: every Claude mode is byte-identical to the pre-change golden.
- `testCodexNewArgvQuotesEveryArg`, `testCodexResumeArgv`
- `testCodexPromptViaEnvNotArgv`, `testCodexLeadingDashPromptGuarded`
- `testCodexPathPrependedBeforePATH`
- `testUUIDv7Accepted`, `testUppercaseOrNonUUIDRejected`
- `testCodexNotFoundShowsNoticeWithoutProcess`: the degenerate case of a missing codex binary.
- `testCodexNullIDAlwaysNew`
- `testCodexStoredIDWithRolloutResumes`, `testCodexMissingRolloutStartsFreshAndNullsID`
- `testCodexRolloutGlobFindsDateDir`
- `testResumeFailureTrackingCoversCodex`
- `testStartedSessionStateSurvivesNavigation`: start a codex session, leave the workbench, come back; the state is
  kept.

**Verification:** `make test-swift FILTER=TerminalLaunch`, then `FILTER=CodexRollout` and
`FILTER=TerminalCenterStartDecision`, then `make lint-diff`.

---

### Task 10: Swift input profile for ask/comment delivery

**Goal:** answers, comments and hand-offs type correctly into a Codex TUI. Claude bytes are unchanged.
**Lane:** Swift. **Size:** S. **Depends on:** Task 0 (newline/cancel keys), Task 2, Task 12 (Swift lane order).

**Files:**
- Create: `WatchtowerCore/Services/AgentInputProfile.swift`
- Modify: `Services/TerminalCenter.swift` (`submitPrompt`, owner-draft tracking), `ViewModels/OwnerAsksViewModel.swift`
  (strings use the agent's display name)
- Tests: `AgentInputProfileTests`, `TerminalCenterSubmitTests`

**Interfaces:**
- `struct AgentInputProfile: Sendable { submit, newline: [UInt8]?; pasteSettle, submitSettle: Duration; static let claude, codex; static func `for`(_ kind: AgentKind) -> Self }`

**Test cases:**
- `testClaudeProfileBytesUnchanged`
- `testCodexSubmitIsBracketedPasteThenCR`
- `testCodexMultilineAnswerOnePrompt`
- `testProj12_CodexAnswerHeldWhileApproval`
- `testProj12_CodexAnswerNotSubmittedBeforeHooksReported`
- `testCodexDraftTrackingUsesCodexNewline`
- `testAnswerSentStringNamesCodex`

**Verification:** `make test-swift FILTER=AgentInputProfile`, then `FILTER=TerminalCenterSubmit` and `make lint-diff`.

---

### Task 11: Swift UI: agent choice, Settings default, install status/Repair, strings, app-guide

**Goal:** the owner can pick the agent per launch, set a default, see codex install state, and repair it.
**Lane:** Swift. **Size:** L. **Depends on:** Task 4 (status JSON), Task 8 (config key), Task 9, Task 10.

**Files:**
- Modify:
  - Header, pane and sessions-panel controls: `Views/Workbench/WorkbenchHeaderControls.swift`,
    `WorkspacePaneView.swift`, `WorkbenchSessionsPanel.swift`
  - Switcher and Work on It: `SessionSwitcherPopover.swift`, `WorkOnTargetButton.swift`
  - Panels and strings: `TerminalsSection.swift`, `WorkbenchPageView.swift`, `WorkbenchesView.swift`,
    `WorkbenchBoardView.swift`, `TargetExtractErrorMapping.swift`, `WorkbenchDeleteSummary.swift`
  - Code-nav hand-off: `CodeNav/HandToClaudeSheet.swift` (rename to `HandToSessionSheet.swift`),
    `CodeQuestionPopover.swift`, `QuestionsView.swift`, `OpenQuicklyCenter.swift`, `CodeHandoffCenter.swift`
  - View models: `WorkbenchesViewModel.swift` (Setup and Repair for both agents),
    `WorkbenchesViewModel+Sessions.swift` (`newStandalone(kind:)`, `workOn(agent:)`)
  - Settings and CLI: `Views/Settings/SystemSettings.swift` (Workbench → Default agent), `Services/ConfigService.swift`,
    `Services/WorkbenchCLI.swift` (`WorkbenchInstallStatus.codex`, `needsRepair`, the codex install call)
  - Docs: `docs/app-guide.md`
- Tests: presentation and view-model tests next to each changed type

**Interfaces:**
- `WorkbenchInstallStatus.Codex: Decodable { found, skill: Bool; hooksTrusted: Bool?; importedDuplicates: Bool }`
  (optional on the parent)
- `WorkbenchesViewModel.newSession(agent: AgentKind)`, `workOn(target:, agent: AgentKind?)` (nil = default)
- `ConfigService.workbenchDefaultAgent: AgentKind`

**Test cases:**
- `testNewSessionMenuListsBothAgentsDisablesMissing`
- `testWorkOnUsesDefaultAgentAndMenuOffersOther`
- `testDefaultAgentSettingRoundTripsConfig`
- `testInstallStatusDecodesWithoutCodexKey`: back-compat with an older CLI.
- `testNeedsRepairWhenCodexUntrustedOrSkillMissing`
- `testNoRepairWhenTrustUnknown`
- `testSetupRunsCodexInstallOnlyWhenFound`
- `testCodexTagShownOnCodexRows`
- `testHandToSessionListsBothAgents`
- `testNoClaudeCodeStringOnCodexPaths`: strings per agent.
- `testShellSessionsUnaffected`

**Verification:** `make test-swift FILTER=<each class>` and `make lint-diff`. Search the views for a remaining
hardcoded "Claude Code" on any agent-generic path.

---

### Task 12: Mobile Hub and WatchtowerKit agent field

**Goal:** the phone sees codex sessions with the right agent, and a start from the phone uses the default agent.
**Lane:** Swift. **Size:** S. **Depends on:** Task 2.

**Files:**
- Modify: `WatchtowerKit/Sources/WatchtowerKit/Models/TerminalSessionState.swift`,
  `WatchtowerKit/Sources/WatchtowerSync/Relay/ActionReason.swift`,
  `WatchtowerDesktop/Sources/Services/MobileHub/Slices/TerminalSessionSlice.swift`, `Slices/WorkbenchTargetSlice.swift`,
  `Handlers/SessionStartStopHandlers.swift`, and the `SessionReport*` hub files (filters only)
- Tests: `Tests/MobileHub/TerminalSessionSliceTests.swift`, WatchtowerKit model tests

**Interfaces:**
- `TerminalSessionState.Agent.codexCLI = "codex_cli"` (in `knownValues`)
- `ActionReason.codexNotFound = "codex_not_found"`

**Test cases:**
- `testSliceAgentPerKind`
- `testCodexRowsIncludedInSlices`
- `testUnknownAgentDecodesAsOpenValue`
- `testPhoneStartUsesDefaultAgent`
- `testPhoneStartCodexMissingReturnsCodexNotFound`
- The existing `agent == "claude_code"` assertion stays for Claude rows.

**Verification:** `make test-swift FILTER=TerminalSessionSlice` (and the Kit test target), then `make lint-diff`.

---

### Task 13: Inventory amendments and feature docs

**Goal:** the contracts and feature notes match what shipped.
**Lane:** Docs. **Size:** S. **Depends on:** Task 6, Task 7, Task 11.

**Files:**
- Modify: `docs/inventory/workbench.md` (PROJ-04, 11, 12, 13 and 14 amendments, spec §13, with a dated changelog
  entry; no new PROJ number, since no new principle), `docs/features/workbench.md` (the v1 limits paragraph),
  `docs/mcp-server.md` (the Codex section points to Workbench), `CLAUDE.md` / `AGENTS.md` only if they describe the
  workbench install layout

**Verification:** every guard name the amendments cite exists (`grep`); the docs pass `make lint-diff`.

---

### Task 14: Final gate

**Files:** none expected (fixes only, one commit each).

- [ ] `bash scripts/dev-health.sh > health.log 2>&1; echo "exit=$?"`. If it reports `HEALTH: overloaded`, stop and
  report.
- [ ] `make test > gate-go.log 2>&1; echo "exit=$?"` → `exit=0`.
- [ ] `make test-swift > gate-swift.log 2>&1; echo "exit=$?"` → `exit=0`. Grep the log for XCTest failures, not only
  the swift-testing tail.
- [ ] `make lint-all > gate-lint.log 2>&1; echo "exit=$?"` → `exit=0`. The sentrux gate is green.
- [ ] Check that the migration number is still free on `origin/main`. If it is not, renumber (rename + golden + Swift
  schema regen) in its own commit.
- [ ] Self-check against the spec: every row of §4.3, §5 and §6.3 has a test; every invariant I1–I7 has a guard;
  `bash scripts/leak-check.sh` is clean over the branch.
- [ ] Hand back for `local-review`, then `debate-review` on the PR into `main`.

---

### Task 15: Owner manual check (after the build, on the dev app)

Checklist (the result goes in an owner ask, one line each: ok / not ok / skipped):

1. Settings → Workbench → Default agent shows Claude Code. Switch it to Codex and back.
2. Re-run Setup on a real workbench folder with Codex installed: `.agents/skills/watchtower-workbench/` appears, `git
   status` stays clean, the header shows no Repair.
3. New session → New Codex session: Codex starts in the folder. The first message gets the brief (ask Codex "what
   workbench is this?").
4. In that session, ask Codex to list the board: it calls the Watchtower tool **without** an approval prompt.
5. State dot: Working while it runs, Needs approval on a shell command that needs approval, Stopped when the turn ends.
6. Work on It with Codex on a target: the target goes to In progress, and Codex starts on it.
7. Codex files an ask (`ask_owner`). Answer it in Watchtower: the answer is typed and submitted in the Codex session.
8. Leave a board comment for the session: it is delivered the same way.
9. Make the board drift (an In progress target with no work): the Stop check nudges Codex.
10. Ask Codex to ask you something in plain text while you are away from the session: the ask guard sends it back to
    `ask_owner`.
11. The session gets an AI title after a few messages.
12. Quit Watchtower with the Codex session open, then reopen: the session resumes the same conversation. No `codex`
    process is left after quit (`pgrep -fl codex`).
13. Start fresh on that session: a new conversation starts.
14. `/clear` inside Codex, then quit and reopen: it resumes the post-clear conversation.
15. Finish the session (`finish_session`): Finished shows, and the session report lists the work.
16. Hand to session from code navigation lists the Codex session and delivers the text.
17. Phone: the Codex session shows with the Codex agent, and its state matches.
18. Uninstall Codex or rename its binary: New Codex session is disabled with a hint, and Claude Code sessions are
    unaffected.
19. No macOS permission dialog appears anywhere above (TCC), and `log show --last 10m --predicate 'process == "tccd"'`
    shows no Watchtower prompt.
20. Claude Code sessions: one quick round of steps 3, 5, 7 and 12 behaves exactly as before.
