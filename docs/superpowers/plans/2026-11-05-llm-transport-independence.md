# LLM Transport Independence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every surface behaves the same on every LLM transport: the 20 open parity gaps are closed or disclosed before Send, consumers ask capabilities instead of provider names, Workbench agents have one session adapter, and one contract suite proves every adapter.

**Architecture:** Each transport is an adapter emitting the existing normalized types: `ai.StreamChunk` and protocol v2 `chat.Event`, with `providers.Failure` on error and a `llmusage.Tokens` usage block. A `Capabilities` row on `providers.Provider` is the one source for Go and Swift. `internal/sessionagent` normalizes hook and rollout events into one session-state path. `internal/transporttest` runs one scenario table against every adapter, and LLMTRANSPORT-01 forbids transport names outside adapters.

**Tech Stack:** Go (`internal/ai`, `internal/codex`, `internal/agentloop`, `internal/ollama`, `internal/providers`, `internal/chat`, `internal/sessionfeed`, `internal/sessionhost`, `internal/agentlog`, `internal/automations`, goose SQL migration, cobra `cmd`), SwiftUI Desktop (WatchtowerCore + Views, DesignKit), WatchtowerKit and the iPhone app.

**Spec:** `docs/superpowers/specs/2026-11-05-llm-transport-independence-design.md`, approved by the owner in ask #514. Read it first. It carries the gap list (§2.2), the capability table (§3.3), the turn rule (§3.4), the rollout failure table (§3.5), the mockups (§3.7), the suite (§4) and the contracts (§5). Decisions: A–D (ask #507), #499, #488, N1–N5 signed off in ask #514, and N6 decided in ask #516 (`session({wait})` ends at once with `not_watched` and its reason by default; recipes must handle it).

**Four waves, not the spec's three:** G2, G4 and A3 share `internal/codex`, and A2 and G5 are both Swift-heavy, so keeping lanes file-disjoint with one Swift-heavy lane at a time needs a fourth wave.

## Global Constraints

- **Branches.** Each task runs in its own worktree and branch, cut from `feature/transport-neutral`. After its review it is merged into `feature/transport-neutral`; a lane gets no PR. `feature/transport-neutral` merges back into `feature/codex-parity`, which ships to `main` in PR #686, the only PR, with the owner's approval.
- **No code in this plan.** It lists interfaces, files and test cases only; implementers write the code.
- **Failing first.** Every task's tests are written and seen to fail before the change (Step 1–2), then pass (Step 4).
- **Inner loop only per task:**
  - Go: `go test ./internal/<pkg>`, adding `-run` to narrow; `cmd` tests are always narrowed with `-run`.
  - Swift: `make test-swift FILTER='<Class>|<Class>'`.
  - Kit: `make kit-test FILTER=…`.
  - Phone: `make mobile-test MOBILE_FILTER=…`.
  - Lint: `make lint-diff`.
  - The controller runs the full gate once per wave: `make test`, `make test-swift` (which includes the Kit), `make lint-all`, `go test ./cmd/...`, plus `make kit-test` and `make mobile-test` in every wave whose merged diff touches `WatchtowerKit/` or `WatchtowerMobile/`. By the lane tables that is wave 1 (G7), wave 2 (G5) and wave 4 (A5); wave 3 runs them too if A2 or A3 end up touching either tree.
- **Guards.** New or extended guards keep the house prefix: `TestAuto08_…`, `TestProj11_…`, `TestFeed01_…`, `TestAgentlog04_…`, `TestLLMTRANSPORT01_…`, and `testLLMTRANSPORT01…` in Swift. No existing guard is relaxed. A contract's amendment lands in `docs/inventory/<file>.md` in the same task, with a changelog line citing the ask.
- **Migration.** Only G5 adds one: the next free number (`00173_terminal_session_watch_issue.sql` at writing time), with Up/Down. It is mirrored in `schema.sql`, and the golden and Swift test schema are regenerated with `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`.
- **Fixtures.** Recorded fixtures are scrubbed by `scrub_fixtures.py`: zero UUIDs, `/work`, `example.com`, no account or path. A hand-made line carries `"synthetic": true`, and leak-check must pass. Nothing is ever copied from the owner's `~/.codex` or `~/.claude`; they may be read for structure only.
- **Processes in tests.** Every fake CLI's process group is killed and waited for in `t.Cleanup`, including on the timeout path. A test that creates git repositories calls `gittest.DisableBackgroundGit()` in `TestMain`.
- **No polling turns.** Run long commands to a log file with an explicit `echo "exit=$?"`.
- **Copy.** UI strings are exactly as in the spec's §3.7, and new screens follow `docs/design/desktop-style-guide.md`. A task that adds or changes a state registers it in `DesignShotCatalog` and attaches `make desktop-shots` output to its review.
- **User guide.** A user-visible change updates its `docs/guide/` page in the same task (`go test ./docs/guide`).

## Review Focus

1. A failed tool on any transport has a non-empty reason (CHAT-02); pinned in A1's matrix.
2. Parallel tool calls of one response count as one turn on every transport (N4); pinned in G2 and A1.
3. No row stays silently `working` after the give-up time of §3.5; pinned in G5.
4. `session({wait})` ends at once with `not_watched` and its reason (N6, ask #516), and every shipped template that waits on a session reads it as "outcome unknown", never as success; pinned in G5.
5. Swift decides no capability the Go table does not report (A2's dual-path test, A6's Swift guard).
6. An older phone shows the hub's message for `not_supported`; pinned in G7.

---

## Waves and lanes

**Lanes:**
- A lane is one task, or a chain of tasks that share files.
- Lanes in the same wave touch disjoint files and disjoint database tables (one table = one lane).
- At most one Swift-heavy lane runs at a time.
- The spec's three waves are split into four here, because G2/G4/A3 share `internal/codex` and A2/G5 are both Swift-heavy.

**Wave 1** (all parallel; G7 is the Swift-heavy lane)

| Lane | Tasks | Main files | DB tables | Swift |
|---|---|---|---|---|
| W1-a | G1 | `internal/ai/client.go`, new `internal/streamline` (reader extracted from `internal/codex/stream.go`) | — | — |
| W1-b | G3 | `internal/agentloop`, `internal/ollama`, `internal/providers` (new `ollama_failure.go`, `CodeForFailure` home), `internal/chat/turn_backend.go`, `cmd/ai.go`, `cmd/ai_session.go` (runtime B wiring only, :219-224), `cmd/generator.go` (runtime B branch only, :204-221), Swift `WatchtowerCore/Services/QuickConnectionsProviderNotice.swift` (copy only) | — | light: one-file copy edit, not Swift-heavy |
| W1-c | G6 | `internal/sessionfeed/{codex,live,feed,parse}.go`, `internal/terminal/codex_rollout.go`, new `internal/rollout` (zstd-aware opener), `go.mod` | — | — |
| W1-d | A1 | new `internal/transporttest`, `scripts/record-transport-fixtures.sh`, `internal/chat/testdata/scrub_fixtures.py` | — (temp DBs) | — |
| W1-e | A6 | new `internal/transporttest/guard_test.go` (or `internal/providers`), `WatchtowerDesktop/Tests/Core/LLMTransportGuardTests.swift`, `docs/inventory/llm-transport.md`, `docs/inventory/README.md` | — | light (one Core test) |
| W1-f | G7 | `internal/hub/actions/handlers/{session_input,permission,deps}.go`, Swift `SessionInputHandlers.swift`, `PermissionAnswerHandlers.swift`, `WorkchatModel.swift`, `WorkchatComposer.swift`, `Views/Settings/NotificationSettings.swift` (U7, no-signal branch only), Kit `ActionReason.swift`, phone `SessionInputSender.swift` | `permission_requests` (only if the spike enables codex) | **heavy** |

Swift build order in wave 1: G7 (the Swift-heavy lane) builds first. W1-b's one-file copy edit runs only its own `make test-swift FILTER=QuickConnectionsProviderNoticeTests`, after G7's Swift build, never alongside it. A6's single Core test does the same.

Conflict notes:
- G1 and G2 both touch `internal/codex/stream.go`. G1 only moves the line reader out into `internal/streamline`, and G2 runs in wave 2 on top of it.
- A1 changes no production file. A cell that fails today is recorded as `gap:<id>` in the matrix golden, and each gap task flips its own cells.

**Wave 2** (G5 is the Swift-heavy lane; G8's Swift part waits for wave 3)

| Lane | Tasks | Main files | DB tables | Swift |
|---|---|---|---|---|
| W2-a | G2 → G4 (one lane, both edit `internal/codex/client.go`/`stream.go`; G4 does not wait on G2's N5 outcome) | `internal/codex`, `cmd/automations_backends.go`, `cmd/workbench_spec_review.go`, then `internal/chat/attachments.go`, `cmd/ai_session.go`, `internal/chat/prompt*.go` | — | — |
| W2-b | G5 (after #959 is merged) | `internal/sessionfeed/codex_turn.go`, `cmd/workbench_session_{state,probe}.go`, `internal/sessionhost`, `internal/db` (migration), `internal/automations/sdk_session.go`, hub slice; Swift status, slice, Kit `TerminalSessionState` | `terminal_sessions` (migration) | **heavy** |
| W2-c | G8 Go part | `internal/agentlog/{codex,discover,scan}.go`, `internal/db/workbench_agent_analytics.go` | `agent_log_*` in `agentlog.db` | — |

**Wave 3** (A2 is the Swift-heavy lane)

| Lane | Tasks | Main files | DB tables | Swift |
|---|---|---|---|---|
| W3-a | A2 | `internal/providers`, `cmd/ai.go` (`ai models`), `cmd/ai_session*.go`, `cmd/tool_routing.go`, `cmd/automations_backends.go` (capability table only), `internal/providerrouting/router.go`, `internal/chat/attachments.go`; Swift provider, settings and composer files | — | **heavy** |
| W3-b | A3 | `internal/llmusage`, `internal/ai`, `internal/digest`, `internal/codex` (usage only), `internal/ollama`, `internal/agentloop`, `internal/chat/{claude_translate,turn_backend,events}.go`, `internal/automations/attempt_meter.go`, `cmd/usage_llm.go` | `llm_calls` (read mapping only) | light (`ChatEvent` keys) |
| W3-c | G8 Swift part (U4) | `Views/Workbench/Analytics/*` | — | light |

Conflict notes:
- A2 and A3 both touch `internal/chat`, but A2 only touches `attachments.go` and A3 never does.
- A2 touches `cmd/automations_backends.go`'s capability table only; A3 touches `agentResult` only. If both end up in the same hunk, merge A3 first.

**Wave 4**

| Lane | Tasks | Main files | DB tables | Swift |
|---|---|---|---|---|
| W4-a | A4 | `internal/ai/client.go` (group-only), `cmd/generator.go`, `cmd/ai.go`, `cmd/ai_session.go`, `cmd/workbench_spec_review.go`, `internal/daemon/coach.go`, `cmd/coach.go`, `cmd/automations_backends.go`, new `cmd/transport_wiring.go` | — | — |
| W4-b | A5 (also moves G8's importer onto `Adapter.Transcript`) | new `internal/sessionagent`, `internal/agentlog/{discover,scan}.go` (wiring only), `cmd/workbench_{session_state,hook_input,hook_row,check,brief,askguard*,permission_wait}.go`, `internal/devpack`, `internal/agentkind`, Swift `AgentKind`, Kit capabilities fixture | — | **heavy** |

After each wave, A6's baseline shrinks by the hits that wave removed, as part of the task that removed them.

---

### Task G1: claude one-shot line reader (L1)

**Depends on:** none
**Contracts:** none amended. CHAT-04 is kept: no argv change.
**Risk:** low.

**Files:**
- Create: `internal/streamline/reader.go` and `reader_test.go` (the line reader moved out of `internal/codex/stream.go`).
- Modify: `internal/ai/client.go` (the one-shot `Query` and `QuerySync` readers, currently `scanner.Buffer(…, 1024*1024)` at :768), `internal/codex/stream.go` (uses the shared reader).

**Interfaces:**
- Produces:
  - `streamline.Reader` over an `io.Reader`, with a `MaxLine` of 64 MiB;
  - `Next() (line []byte, err error)`, which skips an oversized line and counts it;
  - `Skipped() int` and `Undecodable` counting hooks;
  - `Drain()`, which reads stdout to EOF before the caller's `Wait`.
- Consumes: nothing new.

- [ ] **Step 1:** Failing tests:
  - `TestStreamline_OversizedLineIsSkippedAndCounted` (a 2 MiB line between two small ones gives the two small ones and `Skipped()==1`);
  - `TestStreamline_LastLineWithoutNewline`;
  - `TestStreamline_DrainUnblocksAWriterBeforeWait` (a fake child writing 4 MiB after the reader stopped exits; no hang, bounded by a 5 s guard);
  - `TestClaudeQuery_TwoMiBToolResultDoesNotFailTheTurn` (`internal/ai`, fake `claude` emitting a 2 MiB stream-json `user` tool_result line followed by `result`; the turn completes with its text);
  - `TestClaudeQuerySync_TwoMiBLine` (same through `QuerySync`).
- [ ] **Step 2:** `go test ./internal/streamline ./internal/ai -run 'Streamline|TwoMiB'` FAILS.
- [ ] **Step 3:** Implement the reader. Switch `ai.Client` and `codex` onto it. The codex behaviour must not change: the existing `internal/codex` stream tests stay green.
- [ ] **Step 4:** `go test ./internal/streamline ./internal/ai ./internal/codex` PASS; `make lint-diff`.
- [ ] **Step 5:** Flip A1's `oversized tool line` cells for claude one-shot if A1 is already merged. Commit `fix(ai): claude one-shot reads lines up to 64 MiB and skips larger ones (L1)`.

### Task G2: codex turn cap in model turns (L3, L4; decision A, N4, N5)

**Depends on:** G1 (shared reader in `internal/codex/stream.go`), N4 (signed off).
**Contracts:** AUTO-08 (amendment text from the spec's §5, changelog citing asks #507 and #514); SPECREVIEW-01 note.
**Risk:** medium. N5 decided in ask #522: the cap counts the rollout's `token_count` events.

**Files:**
- Modify: `internal/codex/stream.go` (`turnCounter`), `internal/codex/client.go` (`SetMaxTurns`, which cancels the group when turn N+1 starts and returns a `budget` failure), `cmd/automations_backends.go` (codex `agent()` gets `SetMaxTurns(automationAgentMaxTurns)`), `cmd/workbench_spec_review.go` (codex reviewer gets `SetMaxTurns(specreview.MaxTurns)`), `docs/inventory/automations.md`, `docs/inventory/spec-review.md` (note), `docs/features/automations.md`.
- Test data: `internal/codex/testdata/turns_*.jsonl` (recorded by the spike, scrubbed).

**Interfaces:**
- Produces:
  - `(*codex.Client).SetMaxTurns(n int)`, where 0 means no cap;
  - a `budget` `*providers.Failure` whose message is "stopped after N model turns", the same category as Claude's `error_max_turns` (`internal/providers/failure.go:91`).
- Consumes: the `streamline` reader from G1.

- [ ] **Step 0 (spike, first):** Record live `codex exec --json` runs with tools on: a prompt that makes the model call two tools in parallel, a prompt that makes it call tools in three consecutive responses, and a text-only answer. Look for one response's calls executed one after another, i.e. item A started and completed before item B of the same response started, cross-checked against the same run's rollout `token_count` count in a throwaway `CODEX_HOME`. Write the scrubbed recordings to `internal/codex/testdata/`. **Already answered:** A1's live recording showed serial execution, and the owner decided in ask #522 (N5) to count `token_count` events in the run's rollout. Re-run the spike only to confirm on the current codex, then build the rollout counter for both `agent()` and the codex spec reviewer: drop `--ephemeral`, private temp `CODEX_HOME` deleted after the run, stream rule as a logged fallback when the rollout is unreadable. Tests: `TestTurnCounter_RolloutTokenCountIsOneTurnPerResponse` (serial calls of one response = 1 turn), `TestCodexAgent_StopsAtCapFromRollout`, `TestCodexSpecReview_StopsAtMaxTurnsFromRollout`, `TestCodexAgent_TempHomeRemovedAfterRun`, `TestTurnCounter_UnreadableRolloutFallsBackToStream`.
- [ ] **Step 1:** Failing tests:
  - `TestTurnCounter_ParallelCallsAreOneTurn`;
  - `TestTurnCounter_ConsecutiveResponsesCount` (three responses, one tool each, gives 3);
  - `TestTurnCounter_TextOnlyIsOneTurn`;
  - `TestTurnCounter_ItemCompletedWithoutStart` (a tool seen only at `item.completed`);
  - `TestTurnCounter_ReasoningOpensTheNextTurn`;
  - `TestCodexClient_StopsWhenTurnNPlus1Starts` (cap 2 on a 3-response fixture; the fake's group is gone; the failure is `budget`; the text of turns 1–2 was delivered);
  - `TestAuto08_CodexAgentStopsAtTheSameCap` (`cmd`, codex agent runner over the fake, cap 12, 13-response fixture);
  - `TestSpecReview_CodexReviewerHasTheTurnCap` (argv/options pin).
- [ ] **Step 2:** `go test ./internal/codex -run 'TurnCounter|StopsWhenTurn'` and `go test ./cmd -run 'TestAuto08_CodexAgent|TestSpecReview_CodexReviewer'` FAIL.
- [ ] **Step 3:** Implement the state machine exactly as in the spec's §3.4.
- [ ] **Step 4:** The same commands PASS; `make lint-diff`.
- [ ] **Step 5:** Amend AUTO-08 and add the SPECREVIEW-01 note in the inventory. Flip A1's `turn cap` cells for codex. Commit `feat(codex): stop agent() and the reviewer at the same model-turn cap as claude (L3, L4)`.

### Task G3: runtime B and ollama stream parity (L7, L8, L9, L10)

**Depends on:** none
**Contracts:** none amended. CHAT-02 is strengthened by A1's rows. QC-01..04 are kept: runtime B mounts Quick Connections only through `externalmcp` with the QC-02 allowed read list, the `AllowedQuickConnections` policy applies, and secrets stay off argv (QC-03).
**Risk:** low (L7, L9, L10); medium (L8, a new tool source in runtime B).

**Files:**
- Create: `internal/providers/ollama_failure.go`, `internal/chat/failure_code.go`, `internal/agentloop/external.go` and its test (Quick Connection read tools as agentloop tools).
- Modify: `internal/agentloop/client.go` (emit `StreamChunk{Usage}` at the end of `Query`; the final answer stays one chunk, as declared by `text_stream=final`), `internal/ollama/client.go` (emit `Usage` from `stream_options.include_usage`; return typed failures), `internal/chat/turn_backend.go:100` (`CodeForFailure` first, then `ClassifyClaudeError` only for an untyped error), `cmd/ai.go` (`--read-folder` on a client without folder reading returns a capability error instead of silently answering; the v2 error path uses `CodeForFailure`), `cmd/ai_session.go:219-224` and `cmd/generator.go:204-221` (runtime B gets the owner's Quick Connections from `loadExternalMCPServersWith`, as claude and codex do; the automation editor surface stays without them, as today for claude and codex), `docs/features/quick-connections.md`, `docs/guide/` Quick Connections page ("works with Claude, Codex and Ollama"), Swift `WatchtowerCore/Services/QuickConnectionsProviderNotice.swift` copy (until A2 replaces the name check).

**Interfaces:**
- Produces:
  - `providers.OllamaFailure(status int, body string, cause error) error`, which maps 401/403 to `auth`, 404 model to `model`, 429 to `rate_limit`, 5xx to `overload`/`transport`, context length to `context`;
  - `chat.CodeForFailure(category providers.Category) (code string, retryable bool)`;
  - `agentloop.WithExternalMCP(servers []externalmcp.Server) Option`, exposing each allowed read tool as an agentloop tool whose call goes through `externalmcp.CallTool` and is a visible step (`tool_start`/`tool_end`).
- Consumes: `providers.Failure` categories; `externalmcp` and the QC-02 allowed list.

- [ ] **Step 1:** Failing tests:
  - `TestAgentloopQuery_EmitsUsage`;
  - `TestOllamaQuery_EmitsUsage`;
  - `TestOllamaFailure_StatusTable` (table over 401, 403, 404, 429, 500, 503 and a context-length body);
  - `TestCodeForFailure_EveryCategory` (every `providers` category maps to one chat code, and a new category without a row fails the test);
  - `TestTurnBackend_TypedFailureWinsOverText` (a codex quota `Failure` whose text says "authentication" still gives `quota_exhausted`'s code);
  - `TestAIQuery_ReadFolderWithoutFileToolsIsRefused` (`cmd`, ollama config, exit non-zero, v2 `error` with reason `required_capability_missing`);
  - `TestAgentloop_QuickConnectionToolIsCalledAndShownAsStep` (fake MCP server over `httptest`; the model's call reaches it; `tool_start`/`tool_end` emitted);
  - `TestAgentloop_QuickConnectionWriteToolNeverMounted` (QC-02: a tool outside the allowed read list is not offered);
  - `TestAgentloop_PolicyDisallowedConnectionNotMounted` (`AllowedQuickConnections`);
  - `TestAISession_RuntimeBMountsQuickConnections` and `TestAIQuery_RuntimeBMountsQuickConnectionsExceptEditor` (`cmd`).
- [ ] **Step 2:** `go test ./internal/agentloop ./internal/ollama ./internal/providers ./internal/chat -run 'EmitsUsage|OllamaFailure|CodeForFailure|TypedFailureWins|QuickConnection|PolicyDisallowed'` and `go test ./cmd -run 'ReadFolderWithoutFileTools|RuntimeBMountsQuickConnections'` FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** PASS; `make lint-diff`.
- [ ] **Step 5:** Flip A1's cells for runtime B and ollama (usage, failed turn, and the new `quick connection tool` scenario from `gap:L8` to `pass`); A1's scenario table gains that row if it is not there yet. Commits `fix(ollama): usage events, typed failures and an honest read-folder refusal (L7, L9, L10)` and `feat(agentloop): Quick Connections in runtime B chat (L8)`.

### Task G4: codex chat images and explicit web search (L5, L6 Go half)

**Depends on:** G1 only. It runs after G2 in the same lane because both edit `internal/codex/client.go`, not because of G2's outcome: if G2 stops for N5, G4 goes ahead.
**Contracts:** CHAT-04 is kept: the image travels by path in a temp file under the existing 0600 rules, never as prompt text on argv.
**Risk:** medium. A live check is needed.

**Files:**
- Modify: `internal/codex/client.go` (image attachments become `--image <path>` on the turn's `exec`; web search set explicitly on or off from the capability), `internal/chat/attachments.go` (refuses by capability, not by name; a PDF stays refused on codex), `cmd/ai_session.go:186` (the `WebSearch` prompt flag matches what codex is given), `internal/chat/prompt_sections.go` (project binaries line by capability), `docs/features/chat-redesign.md`, `docs/guide/` chat page.

**Interfaces:**
- Produces: `(*codex.Client).SetImages(paths []string)` per turn, cleared after it.
- Consumes: G3's `CodeForFailure` for the refusal code.

- [ ] **Step 0 (spike, first):** Live `codex exec --json --image <png>` with the Watchtower MCP mount and tools on: does the model see the image while tools work? Does web search on `exec` need `-c web_search="live"`, and is it reported as a `web_search` item? Record scrubbed fixtures. If `--image` with MCP fails, keep images refused on codex and record the capability as `images: false` with the reason in the matrix.
- [ ] **Step 1:** Failing tests:
  - `TestCodexTurn_ImageAttachmentPassedAsImageFlag` (fake codex asserts the argv carries `--image` and the stdin carries no base64);
  - `TestCodexTurn_PDFStillRefusedBeforeSpawn`;
  - `TestCodexTurn_WebSearchFlagMatchesPrompt` (prompt `WebSearch=true` if and only if argv enables it; one test per value);
  - `TestTurnBackend_CodexImageAttachmentReachesTheModel` (`internal/chat`).
- [ ] **Step 2:** `go test ./internal/codex ./internal/chat -run 'ImageAttachment|PDFStillRefused|WebSearchFlag'` FAILS.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** PASS; `make lint-diff`.
- [ ] **Step 5:** Flip A1's `image` and `web search` cells for codex. Commit `feat(codex): image attachments and an explicit web search in chat (L5, L6)`.

### Task G5: codex session failure, interrupt and the rollout watch (S1, S2, S6; decision C, ask #499, N6)

**Depends on:** **#959 (`fix/codex-tail-sessionwait`, in flight) merged into `feature/codex-parity` and then into `feature/transport-neutral`.** The task builds on its `sessionfeed.CodexLastTurn`, its `Interrupt` hook row and its Desktop poll, and must not start before that merge. It also depends on G6, for the shared zstd-aware opener; the `compressed` case stays reachable until N1's reader is wired.
**Contracts:**
- PROJ-11: the Codex table gains the pull events and the `unwatched` rule; the Codex v1 limits lose "no Error state" and the blind probe.
- AUTO-11: kept.
- `docs/features/automations.md` and `internal/skills/shipped/create-automation.md`: the N6 lines.
**Risk:** medium. It brings a migration, a three-way wire (Go hub, Desktop hub, Kit) and a recipe API change (N6).

**Files:**
- Create:
  - `internal/db/migrations/00173_terminal_session_watch_issue.sql` (`agent_watch_issue TEXT CHECK(agent_watch_issue IN ('missing','permission','compressed','unreadable'))`, `agent_watch_issue_at TEXT`);
  - `internal/sessionhost/codexwatch.go` and its test.
- Modify:
  - Go: `internal/db/schema.sql`, the golden and Swift test schema (regenerated), `internal/db/terminal_sessions.go` (set and clear, only over `working` codex rows), `internal/sessionfeed/codex_turn.go` (a typed reason instead of "not failed"), `cmd/workbench_session_state.go` (any hook event clears the issue), `cmd/workbench_session_probe.go`, `internal/db/automation_session_steps.go:125`, `internal/automations/sdk_session.go`;
  - hub slice: `internal/hub/slices/sources/terminal_session.go` (`resolveState`, the query at :250);
  - Desktop: `Services/SessionBackgroundProber.swift` (runs only for local-PTY-fallback rows), `WatchtowerCore/Models/SessionAgentStatus.swift`, `WatchtowerCore/Models/TerminalSession.swift`, `WatchtowerCore/Database/Queries/TerminalSessionQueries.swift`, `Services/MobileHub/Slices/TerminalSessionSlice.swift`, the session row and strip views (U6);
  - Kit: `WatchtowerKit/Sources/WatchtowerKit/Models/TerminalSessionState.swift` (`watchIssue`), `WatchtowerKit/Tests/Fixtures/workbench/terminal_session.json`;
  - phone: the session row;
  - docs: `docs/inventory/workbench.md`, `docs/features/workbench.md`, `docs/features/automations.md` (the `session()` paragraph lists `not_watched` and says recipes must handle it), `internal/skills/shipped/create-automation.md` (the same rule for authors), the `docs/guide/` workbench sessions page;
  - templates that wait on `session()`: `internal/automations/templates/deploy-test.md`, `deploy-stage.md`, `release.md` (report `check.reason` beside `check.status`, so a `not_watched` report says why) and `pr-review-rounds.md` (treat `not_watched` like `error`: the PR is left for the next round, never marked reviewed).

**Interfaces:**
- Produces:
  - `sessionfeed.CodexLastTurn(path) (LastTurn, error)`, whose error is a typed `WatchIssue` (`missing`/`permission`/`compressed`/`unreadable`) or a rotation signal;
  - `(*DB) SetAgentWatchIssue(rowID int64, issue string, at time.Time) (bool, error)`, which writes only over a `working` codex row, and `ClearAgentWatchIssue(rowID)`;
  - the `sessionhost` watch: one per hosted codex row while `working`, polling `stat` every 2 s and following the spec's §3.5 table;
  - the `session()` end `{session_id, status: "not_watched", summary: "", reason}`, returned by default (N6, ask #516), with the constant `sessionNotWatched`; no new option key; one run-log line with the reason;
  - the slice keys `stateCaption` ("Working · not watched") and optional `watchIssue`.
- Consumes: G6's `internal/rollout` opener.

- [ ] **Step 1:** Failing tests.
  - Go:
    - `TestProj11_CodexRolloutFailureWritesErrorState` (from #959, kept green);
    - `TestProj11_CodexInterruptHookEndsTurnAsWaiting` (from #959);
    - `TestCodexWatch_MissingGivesUpAfter30s` (fake clock; one `LocateCodex` attempt);
    - `TestCodexWatch_PermissionDeniedAtOnce`;
    - `TestCodexWatch_CompressedAtOnceBeforeN1Reader`;
    - `TestCodexWatch_TruncatedLastLineWaits`;
    - `TestCodexWatch_UnreadableAfterThreeTicks`;
    - `TestCodexWatch_RotationReopensAndNeverGivesUp` (inode change, size shrink, a new `agent_transcript_path`);
    - `TestCodexWatch_StopsAtFinishedDeletedOrNotWorking`;
    - `TestProj11_WatchIssueOnlyOverWorkingCodexRow`;
    - `TestProj11_NextHookEventClearsWatchIssue`;
    - `TestProj11_FailureWinsOverWatchIssue`;
    - `TestProj11_WatchIssueLogLineCarriesNoPath` (FILES-01 canary);
    - `TestCodexWatch_HostAdoptionRearms` (PROJ-20 adoption);
    - `TestProj11_HostAndBridgeReportSameFailureOnce` (the session host's watch and the Desktop bridge's probe both report the same rollout failure; exactly one write, through `recordAgentState(…, onlyFrom: working)` with the same `agent_state_at` stamp taken from the rollout line; the second report writes nothing);
    - `TestMigration00173_AddsNullableColumns`.
  - Automations:
    - `TestSessionWait_NotWatchedEndsAtOnceWithReason` (default, no option: `{status:"not_watched", reason}` at the issue's write, journalled, one run-log line with the reason);
    - `TestSessionWait_FailureBeforeWatchIssueEndsWithError`;
    - `TestSessionWait_NoNotWatchedOptionKey` (an unknown `notWatched` key is still refused like any unknown option);
    - `TestTemplates_SessionWaitersHandleNotWatched` (`internal/automations`: each of the four templates, run in a dry run against a fake `session()` returning `not_watched`, reports the reason and, for `pr-review-rounds`, leaves the PR for the next round);
    - `TestTemplates_StillInstallAndValidate` (the existing template install and validate tests stay green with the new bytes).
  - Hub:
    - `TestTerminalSessionMatchesKitFixtureKeys` and `TestEveryStateKindPublishesTheMacsPresentation`, each gaining a not-watched row.
  - Swift:
    - `testPayloadMatchesTheKitFixtureAndHidesTheRawColumns` and `testEveryStateKindPublishesTheMacsPresentation` (not-watched row);
    - `SessionAgentStatusTests.testWorkingNotWatchedCaption`;
    - `SessionBackgroundProberTests.testPollsOnlyLocalFallbackCodexRows`.
  - Kit:
    - `WorkbenchMirrorFixtureTests` decodes `watchIssue`, and an older-shape fixture without the key still decodes.
- [ ] **Step 2:**
  - `go test ./internal/sessionhost ./internal/sessionfeed ./internal/db ./internal/automations ./internal/hub/slices/sources -run 'CodexWatch|Proj11|Migration00173|SessionWait|Templates_|TerminalSession|EveryStateKind'`
  - `go test ./cmd -run 'TestProj11_|SessionProbe'`
  - `make test-swift FILTER='TerminalSessionSliceTests|SessionAgentStatusTests|SessionBackgroundProberTests'`
  - `make kit-test FILTER=WorkbenchMirrorFixtureTests`

  All of these FAIL.
- [ ] **Step 3:** Implement: migration, watch, setters, slice, Swift, Kit, then the `session()` end, the four templates, the automations doc and the skill line.
- [ ] **Step 4:** The same commands PASS; `make lint-diff`; `make mobile-test MOBILE_FILTER=<session row test>`; `make desktop-shots` for U6.
- [ ] **Step 5:** Amend PROJ-11; add the automations and skill lines. Flip A1's session cells. Commits:
  - `feat(sessionhost): watch codex rollouts for failures and interrupts (S1, S2, S6)`;
  - `feat(automations): session() ends with not_watched; templates handle it (N6)`.

### Task G6: zstd rollouts and codex feed parity (S7, S8; N1)

**Depends on:** none (N1 is signed off).
**Contracts:** FEED-01 (a guard that decompresses in memory and leaves the file untouched), FEED-02 (codex dialog-only on a compressed rollout).
**Risk:** low.

**Files:**
- Create: `internal/rollout/open.go` and its test, a reader that detects the zstd magic and decompresses in memory only.
- Modify: `go.mod`/`go.sum` (one pure-Go zstd decoder, decode only), `internal/sessionfeed/codex.go` (:52–57), `internal/sessionfeed/live.go` (:74), `internal/sessionfeed/feed.go` (:89, codex subagents into `Subagents`), `internal/sessionfeed/parse.go` (codex queued owner lines, if codex records them), `internal/terminal/codex_rollout.go` (:83), `docs/inventory/session-feed.md`.

**Interfaces:**
- Produces: `rollout.Open(path) (io.ReadCloser, compressed bool, err error)`, with a decompressed-size cap of 256 MiB that returns an error past it.
- Consumes: nothing.

- [ ] **Step 1:** Failing tests:
  - `TestFeed01_CompressedRolloutReadLeavesFileUntouched` (size and mtime unchanged, no sibling file);
  - `TestParseCodex_CompressedRolloutGivesEntries`;
  - `TestLiveLine_CompressedRollout`;
  - `TestCodexTitle_CompressedRollout`;
  - `TestFeed_CodexSubagentsListed`;
  - `TestRolloutOpen_DecompressedSizeCap`;
  - `TestParseCodex_QueuedOwnerLine`, or, if codex records no queued line, a test pinning that the shape is absent and a note in FEED-02.
  Fixtures are scrubbed rollouts compressed in the test.
- [ ] **Step 2:** `go test ./internal/rollout ./internal/sessionfeed ./internal/terminal -run 'Compressed|CodexSubagents|SizeCap|QueuedOwner'` FAILS.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** PASS; `make lint-diff`.
- [ ] **Step 5:** Amend FEED-01 (decompression in memory only, the new guard `TestFeed01_CompressedRolloutReadLeavesFileUntouched`) and FEED-02 (codex dialog-only on a compressed rollout; the queued-owner-line finding) in `docs/inventory/session-feed.md`, with a changelog line citing asks #507 and #514 (N1). Flip A1's matrix cells for compressed transcripts (feed, live line, title) and codex subagents from `gap:S7`/`gap:S8` to `pass`. Commit `feat(sessionfeed): read compressed codex rollouts and list codex subagents (S7, S8)`.

### Task G7: honest phone and Workchat for codex (S3, S4, S5, S10)

**Depends on:** none.
**Contracts:**
- PROJ-16 and PROJ-21: heading and refusal-reason wording, gated by capability, `not_supported`.
- Release order: the phone build carrying `ActionReason.notSupported` ships first or together with the Mac (ask #232 practice).
**Risk:** medium.

**Files:**
- Modify:
  - Go: `internal/hub/actions/handlers/deps.go` (a `reasonNotSupported` constant), `session_input.go:209`, `permission.go:87,204,252`;
  - Desktop: `Services/MobileHub/Handlers/SessionInputHandlers.swift:524`, `PermissionAnswerHandlers.swift:180`, `ViewModels/WorkchatModel.swift:69` (`holdsUntilIdle` from the session capability; until A5 lands, a local `AgentSessionCaps` table in `WatchtowerCore`, which A5 replaces), `Views/Workbench/WorkchatComposer.swift` (the U2 caption);
  - Kit: `WatchtowerKit/Sources/WatchtowerSync/Relay/ActionReason.swift` (`notSupported`);
  - phone: `WatchtowerMobile/Sources/Features/Workbench/SessionInputSender.swift` (the U5 text through the failed row);
  - docs: `docs/inventory/workbench.md`, `docs/guide/` phone page.

**Interfaces:**
- Produces:
  - the wire reason `not_supported`, always with the message "Codex sessions can't take messages from the phone yet. Type it on the Mac." (permission variant: "…can't answer this permission from the phone yet…");
  - `AgentSessionCaps.midturnInput`, `.permissionWait` and `.phoneInput` (temporary home until A5).
- Consumes: the spikes' results.

- [ ] **Step 0 (spikes, first):**
  - (a) Can a line typed into the codex TUI while it works be queued and taken mid-turn, the way Claude Code queues one?
  - (b) Can codex's `PermissionRequest` hook hold the prompt and return allow or deny from the hook's output?

  - (c) S10: does codex report an idle prompt (waiting for the owner, e.g. through its `notify` program or a hook event) and an MCP elicitation request in a form a hook or the rollout can read?

  Record the hook payloads and outputs into `cmd/testdata/codex_hooks/`. Only what a spike proves is enabled. Anything unproven stays refused with `not_supported` (a, b) or becomes a disclosed limit (c).
- [ ] **Step 1:** Failing tests.
  - Go:
    - `TestProj16_CodexSessionRefusedAsNotSupported` (reason and message, never "no longer exists");
    - `TestProj21_CodexPermissionRefusedAsNotSupported`;
    - `TestProj16_DeletedSessionStillNotFound` (not-found keeps its meaning).
  - Swift:
    - `SessionInputHandlersTests.testCodexRefusedAsNotSupported`;
    - `PermissionAnswerHandlersTests.testCodexRefusedAsNotSupported`;
    - `WorkchatModelTests.testHoldsUntilIdleFollowsCapability`;
    - `WorkchatComposerTests.testCaptionWhenNoMidturnInput` (U2 string exact).
  - Kit:
    - `ActionReasonTests.testNotSupportedDecodes`;
    - `ActionReasonTests.testUnknownReasonDecodesToNilAndKeepsMessage` (the old-phone fallback pinned).
  - Phone:
    - `SessionInputSenderTests.testFailedRowShowsHubMessageForUnknownReason`.
- [ ] **Step 2:**
  - `go test ./internal/hub/actions/handlers -run 'Proj16|Proj21'`
  - `make test-swift FILTER='SessionInputHandlersTests|PermissionAnswerHandlersTests|WorkchatModelTests|WorkchatComposerTests'`
  - `make kit-test FILTER=ActionReasonTests`
  - `make mobile-test MOBILE_FILTER=SessionInputSenderTests`

  All of these FAIL.
- [ ] **Step 2b (S10, its own step, failing first):** the outcome of spike (c) decides which of two test sets is written; S10 never closes silently.
  - If codex can signal it: `TestProj11_CodexIdlePromptIsWaiting` (the idle signal stores `waiting` like Claude's `idle_prompt`), `TestProj11_CodexElicitationIsApproval` (an elicitation stores `approval`), `SessionAgentStateCenterTests.testCodexIdleNoticeFires` (the Desktop idle notice fires for a codex row).
  - If it cannot: the session capability row records `idle_signal: false` and `elicitation: false` for codex (in `AgentSessionCaps`, later A5's fixture), and the UI says so: `SessionNoticePresentationTests.testIdleNoticeDisclosedAsUnavailableForCodex` (Settings → Notifications → Workbench notifications shows the U7 caption "Idle notices are not available for Codex sessions." from the capability, not from the kind; the caption disappears when every kind has `idle_signal: true`), with the row on the kit's `SettingRow(title:caption:)` (`Views/Settings/NotificationSettings.swift`) and `TestProj11_CodexNoIdleSignalIsDisclosedNotSilent` (the capability row and the inventory's Codex v1 limits line agree). The PROJ-11 Codex v1 limits keep "no idle notice" with that pointer.
  - Run with Step 2's commands plus `go test ./cmd -run 'TestProj11_Codex(Idle|Elicitation|NoIdle)'` and `make test-swift FILTER='SessionAgentStateCenterTests|SessionNoticePresentationTests'`.
- [ ] **Step 3:** Implement: the refusals first, then whatever the spikes proved, then Step 2b's branch.
- [ ] **Step 4:** PASS; `make lint-diff`; register U2 and (no-signal branch only) U7 in `DesignShotCatalog` on fixture data and run `make desktop-shots DESKTOP_SHOTS=<dir>`; look at both light and dark PNGs and attach them to the review.
- [ ] **Step 5:** Amend PROJ-16 and PROJ-21, and PROJ-11's Codex v1 limits for S10's outcome. Flip A1's session cells for S3, S4, S5 and S10 to `pass` or `unsupported` (the honest-UI assertion). Commit `fix(hub): codex sessions get an honest not_supported on the phone and in Workchat (S3, S4, S5, S10)`.

### Task G8: codex rollout importer for analytics and the coach (S9; decision D)

**Depends on:**
- G6 (`internal/rollout`).
- The Swift part (U4) runs in wave 3, after G5's Swift lane.
- A5 only for the final wiring through `Adapter.Transcript`; the parser does not wait for it. Until A5, G8 finds and opens rollouts through its own interim wiring in `internal/agentlog/discover.go` (marked as interim in a comment); A5 removes it.

**Contracts:**
- AGENTLOG-04, amended as in the spec's §5 (ask #507).
- AGENTLOG-01, 02, 05 and 06 hold for codex, with new codex guards.
**Risk:** high. This is a new parser over an undocumented format.

**Files:**
- Create: `internal/agentlog/codex.go` and its test.
- Modify:
  - `internal/agentlog/discover.go` (`$CODEX_HOME/sessions`, workbench rows only, no symlinks), `internal/agentlog/scan.go` (`Agent: "codex"`), `internal/db/workbench_agent_analytics.go` (`CodexTerminalSessionIDs`);
  - Swift: `Views/Workbench/Analytics/AgentAnalyticsPaneView.swift` and the blocks (U4: `OutlineTag` agent tag, "no price", "Not measured for Codex sessions");
  - docs: `docs/inventory/agent-analytics.md`, `docs/features/agent-analytics.md`, `docs/guide/` analytics page.

**Interfaces:**
- Produces:
  - `agentlog.ParseCodex(r, offset) (records, newOffset, err)`, which yields token counts from `token_count` events, tool calls, owner turns and times;
  - `(*DB) CodexTerminalSessionIDs(uuids []string) (map[string]int64, error)`.
- Consumes: `rollout.Open`.

- [ ] **Step 1:** Failing tests:
  - `TestAgentlog04_CodexOnlyWorkbenchRolloutsRead` (a rollout of another folder is never opened);
  - `TestAgentlog04_CodexSymlinkSkipped`;
  - `TestAgentlog04_CodexLongestFolderWins`;
  - `TestAgentlog01_CodexNoTranscriptText` (no prompt or answer text in `agentlog.db`);
  - `TestAgentlog02_CodexForkedRolloutCountsOnce` (a forked or resumed copy replays its parent's lines; tokens are counted once);
  - `TestAgentlog05_CodexReadOnly`;
  - `TestAgentlog06_CodexTimeAddsUp`;
  - `TestParseCodex_TokenCountPerResponse`;
  - `TestParseCodex_CompressedRollout`;
  - `TestReport_CodexSessionsIncludedAndUnpriced` (`internal/agentreport`);
  - `TestCoachMetrics_IncludeCodexSessions` (`internal/coach`, read-only);
  - Swift `AgentAnalyticsPaneTests.testCodexRowTagAndNoPrice` and `testNotMeasuredCaptionForCodexBlocks`.
- [ ] **Step 2:** `go test ./internal/agentlog ./internal/agentreport ./internal/coach ./internal/db -run 'Agentlog0|ParseCodex|CodexSessions|IncludeCodex'` and `make test-swift FILTER=AgentAnalyticsPaneTests` FAIL.
- [ ] **Step 3:** Implement the Go part (wave 2), then the Swift part (wave 3).
- [ ] **Step 4:** PASS; `make lint-diff`; `make desktop-shots` for U4.
- [ ] **Step 5:** Amend AGENTLOG-04. Commits:
  - `feat(agentlog): import codex rollouts for analytics and the coach (S9)`;
  - `feat(desktop): codex sessions in the Analytics pane (U4)`.

### Task A1: contract suite harness, fixtures and the matrix golden

**Depends on:** none.
**Contracts:**
- CHAT-02 is strengthened: the suite's rows join its guards.
- CHAT-03's wording "any transport's child group" is applied when the A1 rows land.
**Risk:** low.

**Files:**
- Create:
  - `internal/transporttest/{suite,scenarios,adapters,matrix}_test.go`;
  - `internal/transporttest/fakecli/main.go`, built in `TestMain`;
  - `internal/transporttest/testdata/<transport>/<scenario>.jsonl`;
  - `internal/transporttest/testdata/matrix.golden`;
  - `scripts/record-transport-fixtures.sh`.
- Modify: `internal/chat/testdata/scrub_fixtures.py` (codex ids, rollout paths, cwd), `docs/inventory/chat.md` (guards list, CHAT-03 wording).

**Interfaces:**
- Produces:
  - `transporttest.Scenario{Name, Levels, Requires, Fixture, Assert}`;
  - `transporttest.Adapter{Name, Caps, Batch, Stream, Chat, Session}`;
  - the fake CLI's fixture directives, each a line in the fixture header: `emit`, `sleep`, `stderr`, `exit`, `hang`, `ignore-sigint`, `spawn-grandchild`, `argv-has`, `argv-lacks`, `stdin-has`;
  - the matrix golden, one line per cell: `adapter scenario pass|unsupported|gap:<id>`;
  - `-update` regenerates it.
- Consumes: today's adapters through their public constructors. No production change.

- [ ] **Step 1:** Write the scenario table from the spec's §4.1, and the session rows: prompt, tool, permission, stop, failure, interrupt, subagents, SessionStart sources, foreign id, older event, compressed transcript, unreadable rollout, `session()` not watched. Add:
  - `TestTransportSuite_NoSkip` (an AST check: no `t.Skip` in the package outside the live gate);
  - `TestTransportSuite_EveryCellResolved` (every adapter × scenario pair is in the golden);
  - `TestFakeCLI_GroupReaped` (a grandchild is gone after cancel, checked with `kill(pid, 0)` until ESRCH under a bounded wait).
- [ ] **Step 2:** Record the fixtures: `bash scripts/record-transport-fixtures.sh` with `WATCHTOWER_LIVE_CLAUDE=1`/`WATCHTOWER_LIVE_CODEX=1`/`WATCHTOWER_LIVE_OLLAMA=1` on a development machine, then scrub them and run leak-check. Reuse `internal/codex/testdata/turn_failures.json` and the Claude failure fixtures for 4xx/5xx/429. A hand-made line carries `"synthetic": true`.
- [ ] **Step 3:** `go test ./internal/transporttest -update` writes today's truth. Check every `gap:<id>` against the spec's §2.2: each must name an open gap, and the list must have no extra entries.
- [ ] **Step 4:** `go test ./internal/transporttest` PASS; `make lint-diff`.
- [ ] **Step 5:** Commit `test(transport): contract suite over every adapter with a matrix golden`.

### Task A2: capability rows, one source for Go and Swift

**Depends on:**
- A1 (the matrix reads `Caps`).
- G3 and G4 (their capability values).
- Coordinate with the provider-fallback work (#1480) on `cmd/ai_session_routing.go` and `internal/providerrouting/router.go`.
**Contracts:** POLICY-02 and POLICY-03 are kept: the policy filters before capabilities. A dual-path test is added.
**Risk:** medium.

**Files:**
- Create: `internal/providers/capabilities.go` and its test, plus the Swift `WatchtowerCore/Models/ProviderCapabilities.swift` and `Tests/Core/ProviderCapabilitiesTests.swift`.
- Modify:
  - Go: `internal/providers/registry.go`, `cmd/ai.go` (`ai models --json` gains `capabilities`), `internal/chat/events.go` and the session (`session_ready` gains `capabilities`), `cmd/ai_session.go:186` (`WebSearch`), `cmd/ai_session_routing.go:109`, `cmd/tool_routing.go:94`, `cmd/automations_backends.go:219`, `internal/providerrouting/router.go:298`, `internal/chat/attachments.go`;
  - Swift: `WatchtowerCore/Services/AIModelCatalog.swift`, `WatchtowerCore/Services/Chat/ChatEvent.swift`, `Services/ConfigService.swift:295-341,405-415`, `Views/Settings/ProviderSettings.swift`, `WatchtowerCore/Services/ProviderFallbackPreview.swift`, `WatchtowerCore/Services/ProviderSettingsHealth.swift`, `ViewModels/TargetChatViewModel.swift:182`, `Services/ChatSurfaces/AutomationEditorChatSurface.swift:27`, `Services/ChatSurfaces/CodeQuestionSurface.swift:45,178`, `Services/Chat/ChatSessionPool.swift:175`, `WatchtowerCore/Services/QuickConnectionsProviderNotice.swift:16`, `ViewModels/ChatViewModel.swift:93-103`, `Views/Chat/ChatComposerView.swift`, `Views/Chat/ChatComposerField.swift` (U1, U3);
  - docs: `docs/features/model-provider-registry.md`, `docs/guide/` chat and settings pages.

**Interfaces:**
- Produces:
  - `providers.Capabilities`, with the fields of the spec's §3.3 and JSON keys in snake_case;
  - `providers.CapsFor(id) (Capabilities, bool)`;
  - `Capabilities.Satisfies(profile InvocationProfile) bool`;
  - Swift `ProviderCapabilities` (Decodable, the same keys), read only from `AIModelCatalog` and `session_ready`.
- Consumes: the registry.

- [ ] **Step 1:** Failing tests.
  - Go:
    - `TestCapabilities_TableMatchesSpec` (every row of §3.3);
    - `TestAIModels_JSONCarriesCapabilities` (pinned keys);
    - `TestSessionReady_CarriesActualProvidersCapabilities` (a fallback route carries the actual provider's capabilities);
    - `TestRouting_CheckCapabilityReadsCaps` (no name branch);
    - `TestAttachments_RefusedByCapability`;
    - `TestPolicy_ForbiddenProviderNeverReachableByCapability`.
  - Swift:
    - `ProviderCapabilitiesTests.testDecodesGoFixture` (a Go-written fixture `ai_models_capabilities.json` is shared as the dual path);
    - `ConfigServiceTests.testReservePairComesFromCatalog` (no claude↔codex literal; a catalog without `reserve_peer` hides the reserve);
    - `ChatComposerTests.testAttachDisabledWithReasonWhenNoImages` (U1 string);
    - `ChatViewModelTests.testOllamaProviderLineWithoutRoutingCard` (U3);
    - `TargetChatViewModelTests.testToolsAvailableFromCapabilities`;
    - `CodeQuestionSurfaceTests.testReadsFilesFromCapabilities`.
- [ ] **Step 2:** `go test ./internal/providers ./internal/chat ./internal/providerrouting -run 'Capabilit|CheckCapability|RefusedByCapability|ForbiddenProvider'`, `go test ./cmd -run 'AIModels_JSON|SessionReady_Carries'` and `make test-swift FILTER='ProviderCapabilitiesTests|ConfigServiceTests|ChatComposerTests|ChatViewModelTests|TargetChatViewModelTests|CodeQuestionSurfaceTests'` FAIL.
- [ ] **Step 3:** Implement. Remove the name checks listed in A6's baseline for these files.
- [ ] **Step 4:** PASS; `make lint-diff`; `make desktop-shots` for U1 and U3.
- [ ] **Step 5:** Shrink A6's Go and Swift baselines. Commit `feat(providers): one capability table read by Go and Swift (L6, L11)`.

### Task A3: one usage block and one provider label (N3)

**Depends on:** A1, and G3 (ollama usage).
**Contracts:**
- LLMUSAGE-01: provider values, with the N3 reader mapping.
- AUTO-08: meaning unchanged (ask #488), pinned by the existing `TestAuto08_` usage guards staying green.
**Risk:** medium. Many files change but behaviour does not.

**Files:**
- Modify:
  - `internal/llmusage/llmusage.go` (`Tokens`, embedded in `Call`), `internal/ai/provider.go` (`TurnUsage` embeds `Tokens`; `InputTokens` becomes derived), `internal/ai/client.go` (`ai.Usage`), `internal/digest/pipeline.go` (`digest.Usage`);
  - the leaves: `internal/codex`, `internal/ollama`, `internal/agentloop` (records `ollama`), `internal/chat/claude_translate.go`;
  - `internal/chat/turn_backend.go` and `events.go` (the v2 `usage` keys `fresh_in`/`cache_read`/`cache_write`/`cost_usd`/`estimated`), `internal/automations/attempt_meter.go`, `cmd/usage_llm.go` (a stored `http` is reported as `ollama`);
  - Swift: `WatchtowerCore/Services/Chat/ChatEvent.swift` (tolerant decode);
  - docs: `docs/features/llm-usage-ledger.md`, `docs/inventory/plan-usage.md`.

**Interfaces:**
- Produces:
  - `llmusage.Tokens{Input, CacheRead, CacheWrite5m, CacheWrite1h, Output, ReportedCostUSD, Estimated}`;
  - `(Tokens) AllInput() int64`.
- Consumes: the leaf numbers.

- [ ] **Step 1:** Failing tests:
  - `TestTokens_AllInputIsFreshPlusCache`;
  - `TestTurnUsage_InputTokensStaysAllInput` (CHAT-01 rows keep their meaning);
  - `TestUsageEvent_V2CarriesSplitKeys` (pinned keys);
  - `TestAgentloop_RecordsOllamaLabel`;
  - `TestUsageLLM_HTTPRowReportedAsOllama` (a stored `http` row plus a spool line with `http` both show under `ollama`);
  - `TestAuto08_DebitIsFreshPlusOutputOnEveryProvider` (one table over claude, codex and runtime B);
  - Swift `ChatEventTests.testUsageWithSplitKeysDecodes` and `testUsageWithoutSplitKeysDecodes`.
- [ ] **Step 2:** `go test ./internal/llmusage ./internal/ai ./internal/chat ./internal/agentloop ./internal/automations -run 'Tokens|TurnUsage|UsageEvent|OllamaLabel|TestAuto08_Debit'`, `go test ./cmd -run UsageLLM_HTTP` and `make test-swift FILTER=ChatEventTests` FAIL.
- [ ] **Step 3:** Implement. The old field names stay as derived accessors until every reader has moved, inside this task.
- [ ] **Step 4:** PASS. `go test ./internal/llmusage -run 'TestLLMUSAGE01'` stays green. `make lint-diff`.
- [ ] **Step 5:** Commit `refactor(llmusage): one token block across usage types; runtime B records ollama (N3)`.

### Task A4: one factory with an options struct; group-only runner

**Depends on:** A2 (capabilities decide what a constructor offers) and G1.
**Contracts:**
- CHAT-04 is kept.
- LLMUSAGE-01's `knownNonLLMExec` entries follow the moved functions, in the same commit.
**Risk:** medium. The change is wide but mechanical.

**Files:**
- Create: `cmd/transport_wiring.go` (the only file in `cmd` that imports the adapter packages for construction).
- Modify:
  - `internal/providers/registry.go` (`Transport` constructor slots: `NewGenerator`, `NewQuerier`, `NewChatBackend`, `NewAgentRunner`);
  - `internal/ai/client.go` (`ConfigureChild` group-only; `SetProcessGroup` removed);
  - `internal/codex/client.go` (`SetProcessGroup` removed);
  - the four switches and probe sites: `cmd/generator.go:84,164,225,239`, `cmd/ai.go:380,677-690`, `cmd/ai_session.go:211`, `internal/daemon/coach.go:47,62`, `cmd/coach.go:59` (dead `SetStdinOnly` removed), `cmd/automations_backends.go:141`, `cmd/workbench_spec_review.go`;
  - `internal/llmusage/leaves_test.go` entries.

**Interfaces:**
- Produces:
  - `providers.Transport{ID, Caps, NewGenerator func(Options) digest.Generator, NewQuerier func(Options) ai.Provider, NewChatBackend func(Options, …) chat.Backend, NewAgentRunner func(Options) automations.AgentRunner}`;
  - `providers.Options{Model, Tier, MCPArgs, ExternalMCP, ReadFolder, ToolEvents, IsolatedChild, ChildEnv, MaxTurns, Images}`.
- Consumes: A2's `Caps`.

- [ ] **Step 1:** Failing tests:
  - `TestTransportWiring_EveryRegistryIDHasConstructors` (nil exactly where `Caps` says the transport cannot);
  - `TestConfigureChild_AlwaysGroup` (no non-group branch remains; a SIGINT-ignoring fake's group is reaped);
  - `TestLLMTRANSPORT01_NoTransportNamesOutsideAdapters`, with the baseline entries for these files removed (it fails until they are gone).
- [ ] **Step 2:** `go test ./internal/providers ./internal/ai ./internal/transporttest -run 'TransportWiring|AlwaysGroup|LLMTRANSPORT01'` and `go test ./cmd -run 'TransportWiring'` FAIL.
- [ ] **Step 3:** Implement. Rerun A1's suite unchanged: no matrix cell may change.
- [ ] **Step 4:** PASS; `go test ./internal/transporttest`; `go test ./internal/llmusage`; `make lint-diff`.
- [ ] **Step 5:** Commit `refactor(transport): one factory with options; process groups always on`.

### Task A5: `internal/sessionagent`, the Workbench session adapter

**Depends on:** G5 (the watch and events), G7 (its temporary `AgentSessionCaps`, replaced here), G8 (its interim rollout wiring, replaced here) and A1.
**Contracts:**
- PROJ-11, PROJ-12, PROJ-13 and PROJ-16/21: all their guards stay green with no assertion changed. PROJ-11 gains the single entry point note.
- Session capabilities get a dual-path fixture.
**Risk:** high. It touches every hook path.

**Files:**
- Create:
  - `internal/sessionagent/{adapter,event,claude,codex,caps}.go` and their tests;
  - `internal/sessionagent/agent_capabilities.json` (embedded), copied to `WatchtowerKit/Sources/WatchtowerKit/Resources/agent_capabilities.json`;
  - Swift `WatchtowerKit/Sources/WatchtowerKit/Models/AgentSessionCapabilities.swift` and Kit tests.
- Modify:
  - `cmd/workbench_hook_input.go` (`hookEvent` moves into `sessionagent.Event`), `cmd/workbench_session_state.go` (one entry point), `cmd/workbench_hook_row.go`, `cmd/workbench_check.go`, `cmd/workbench_brief*.go`, `cmd/workbench_askguard*.go`, `cmd/workbench_permission_wait.go`, `cmd/workbench_session_probe.go`;
  - `internal/devpack/{workbench_settings,codex_hooks}.go` (`HookSpecs` come from the adapter), `internal/agentkind` (type alias), `internal/sessionfeed` and `internal/terminal` (`Transcript`);
  - Swift: `WatchtowerCore/Models/AgentKind.swift`, the G7 call sites that move onto the Kit capabilities, `ViewModels/WorkchatModel.swift`.

**Interfaces:**
- Produces:
  - `sessionagent.Adapter` with `Kind()`, `HookSpecs()`, `Normalize(raw) (Event, bool)`, `Transcript(row)`, `Probe(row)`, `Watch(row)` and `Caps()`;
  - `sessionagent.For(kind) (Adapter, bool)`;
  - `sessionagent.Event` (the moved `hookEvent`);
  - `sessionagent.Caps` with the fields of the spec's §3.5;
  - Swift `AgentSessionCapabilities`, decoded from the shared fixture.
- Consumes: G5's watch and G6's reader.

- [ ] **Step 1:** Failing tests:
  - `TestSessionAgent_ClaudeAndCodexNormalizeRecordedPayloads` (every file in `cmd/testdata/codex_hooks/` and `cmd/testdata/*.json` gives the same `Event` as today);
  - `TestSessionAgent_OneStateEntryPoint` (an AST check: `recordAgentState` is called only from the `sessionagent` path);
  - `TestSessionAgent_CapsFixtureMatchesAdapters`;
  - the Kit test `AgentSessionCapabilitiesTests.testDecodesGoFixture`;
  - `TestLLMTRANSPORT01_NoTransportNamesOutsideAdapters` with the `cmd/workbench_*` baseline entries removed;
  - the Swift guard with the `WorkchatModel`/handler entries removed;
  - A1's session rows rerun with no change.
- [ ] **Step 2:** `go test ./internal/sessionagent ./internal/transporttest ./internal/agentlog` and `go test ./cmd -run 'TestProj1[1-6]_|TestProj21_|SessionAgent'`, `make kit-test FILTER=AgentSessionCapabilitiesTests` and `make test-swift FILTER='LLMTransportGuardTests|WorkchatModelTests'` FAIL.
- [ ] **Step 2b (G8 onto the adapter, failing first):** `TestAgentlog_CodexImportGoesThroughAdapterTranscript` (the importer finds and opens codex rollouts only through `sessionagent.For(codex).Transcript(row)`; a fake adapter that returns a fixture path is the only source read) and `TestAgentlog_NoInterimRolloutDiscovery` (an AST check: `internal/agentlog` no longer calls the interim discovery function or `rollout.Open` directly). Run `go test ./internal/agentlog -run 'AdapterTranscript|NoInterimRollout'`: FAIL.
- [ ] **Step 3:** Implement, moving code without changing behaviour. Move G8's importer onto `Adapter.Transcript` and delete the interim wiring in `internal/agentlog/discover.go`; G8's `TestAgentlog0*_Codex…` guards stay green unchanged.
- [ ] **Step 4:** PASS; `make lint-diff`.
- [ ] **Step 5:** Shrink the baselines. Commit `refactor(workbench): one session adapter per agent kind`.

### Task A6: LLMTRANSPORT-01 guard (Go and Swift) with a ratchet baseline

**Depends on:** none. It lands early with the full baseline, and A2, A4, A5 and G7 shrink it.
**Contracts:** the new LLMTRANSPORT-01 in `docs/inventory/llm-transport.md`, listed in `docs/inventory/README.md`. The owner approved the spec, which names the principle; any later baseline growth needs the owner's approval.
**Risk:** low.

**Files:**
- Create:
  - `internal/transporttest/guard_test.go` (the Go AST guard);
  - `internal/transporttest/testdata/llmtransport_allow.txt` (`file:line-free key → reason`, keyed by function rather than line so edits do not churn it);
  - `WatchtowerDesktop/Tests/Core/LLMTransportGuardTests.swift` and its baseline `WatchtowerDesktop/Tests/Core/Fixtures/llmtransport_allow_swift.txt`;
  - `docs/inventory/llm-transport.md`.
- Modify: `docs/inventory/README.md`.

**Interfaces:**
- Produces:
  - `TestLLMTRANSPORT01_NoTransportNamesOutsideAdapters` (Go), which fails on comparisons or `switch` cases against `"claude"`/`"codex"`/`"ollama"`/`"http"` or `agentkind.Claude`/`Codex`, and on type assertions to concrete adapter types, outside the adapter packages and `cmd/transport_wiring.go`;
  - `TestLLMTRANSPORT01_BaselineOnlyShrinks` (an entry that no longer matches must be deleted; a new hit fails);
  - Swift `testLLMTRANSPORT01NoProviderNamesInConsumers` and `testLLMTRANSPORT01BaselineOnlyShrinks`.

- [ ] **Step 1:** Write the guards and their self-tests: `TestLLMTRANSPORT01_CatchesANewNameCheck` (a synthetic source snippet with a name comparison is flagged) and the Swift twin.
- [ ] **Step 2:** Run with an empty baseline. It FAILS and lists today's hits, which must match the spec's §2.1 inventory. Write the baseline with a reason for each hit. Display-name tables, the config migration regexes and path conventions are permanent entries.
- [ ] **Step 3:** `go test ./internal/transporttest -run LLMTRANSPORT01` and `make test-swift FILTER=LLMTransportGuardTests` PASS.
- [ ] **Step 4:** Add the inventory file and the README line. `make lint-diff`.
- [ ] **Step 5:** Commit `test(transport): LLMTRANSPORT-01 guard with a shrinking baseline`.

### Final: gate, review and hand-off

- [ ] After each wave, the controller runs the full gate (`make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`, plus `make kit-test` and `make mobile-test` in every wave whose merged diff touches `WatchtowerKit/` or `WatchtowerMobile/`: waves 1, 2 and 4, and wave 3 if A2 or A3 touched either tree; this matches Global Constraints). Then it runs a `local-review` panel over the wave's merged diff.
- [ ] Check that the matrix golden has no `gap:` cell left, or that each remaining one is a disclosed limit the spec names (claude.ai tools, Claude plan, Ollama vision, codex `agent()` file login).
- [ ] Check that the A6 baselines hold only permanent entries, each with its reason.
- [ ] Manual check (an owner ask, kind check), covering these cases:
  - a Codex chat with an image;
  - an Ollama chat line;
  - a codex session that fails with the app closed (it shows Error on reopening);
  - a compressed rollout showing "Working · not watched";
  - phone typing into a codex session;
  - codex Esc in a session: the row leaves Working (waiting) at once;
  - codex sessions in Analytics show real numbers (time, tokens, hints) after the importer; "Not measured for Codex sessions" appears only in a block the rollout cannot fill, and for a compressed rollout only if G6's reader is not in yet;
  - an automation `agent()` on codex stopping at 12 turns;
  - the spec reviewer on codex stopping at its turn cap (`specreview.MaxTurns`);
  - a shipped template waiting on a session that turns unwatched reports `not_watched` with the reason.
- [ ] Merge `feature/transport-neutral` into `feature/codex-parity` for PR #686, with the owner's approval.
