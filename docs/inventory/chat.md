# Behavior Inventory — Chat (main AI Chat)

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.

The main AI Chat: warm per-conversation `watchtower ai session` processes
speaking protocol v2 (NDJSON events on stdout, JSONL commands on stdin), a
Go-built system prompt, branching history in goose-owned chat tables, visible
tool steps and sources, attachments, artifacts, projects, mentions and
skills. Design: `docs/superpowers/specs/2026-09-26-chat-redesign-design.md`.

**Module:** `internal/chat/`, `cmd/ai_session.go`, `cmd/chat.go`,
`internal/db/chat.go`, `internal/db/chat_migrate.go`,
`internal/db/migrations/00076_chat_core.sql`,
`WatchtowerDesktop/Sources/Services/Chat/`,
`WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/`,
`WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift`,
`WatchtowerDesktop/Sources/Views/Chat/`
**Last full audit:** 2026-09-26

## CHAT-01 — owner text is never lost

**Status:** Enforced

**Observable:** The owner's message is written to `chat_messages` before the
`turn` command is sent to the session process, so a failed spawn, a crashed
session or an app quit mid-turn never loses what was typed — if the write
itself fails (e.g. a DB trigger aborts it), nothing is sent and the text
stays in the composer. Assistant text that already streamed survives Stop, a
session crash and app quit: it is persisted with `status='partial'` (Stop
sends `cancel` and the interrupted turn renders "Stopped" + Continue; a
crashed process's partial text is flushed and the next send respawns the
session with `--resume`, replaying history). Regenerate and Edit insert
their new assistant/user rows under the NEW turn id **before** the turn goes
out, and a failed turn is recorded as an `error` row before the next turn is
accepted — both close the same failure mode: Go's `HistoryBefore` strips
only a *trailing* owner row with no reply, so an owner message can never be
silently dropped from replay.

**Guard:** `testChat01UserMessageIsPersistedBeforeTheTurnIsSent`,
`testChat01NothingIsSentWhenTheMessageCannotBeSaved`,
`testChat01PartialTextSurvivesStop`,
`testChat01PartialTextSurvivesProcessDeathAndTheNextTurnResumes`,
`testChat01RegenerateRowExistsUnderTheNewTurnIDWhenSent`,
`testChat01EditRowsExistUnderTheNewTurnIDWhenSent`,
`testChat01FailedSendKeepsTheOwnerMessageAnswered`,
`testChat01LegacyUnansweredQuestionIsKeptBeforeTheNextTurn`
(`WatchtowerDesktop/Tests/ChatViewModelTests.swift`)

## CHAT-02 — no silent tool activity

**Status:** Enforced

**Observable:** Every tool call in a turn becomes a `tool_start`/`tool_end`
event pair and is persisted as a `chat_turn_steps` row as it happens (not
batched at turn end) — a failed tool is a red step (`ok=false`), not a turn
error. Protocol v2 has no `reset` event: text already streamed before a tool
call is never wiped — the Claude translator turns a mid-turn `tool_use` into
a start/end step pair, never into a clear, and every event type the
translator ever emits for a turn containing a tool call is asserted to
never be `"reset"`. A call the permission gate denies is a red step carrying
the gate's reason; a call waiting for the owner's approval is a visible
waiting step until it is approved, rejected or times out.

**Guard:** `TestChat02_ToolCallNeverWipesText`
(`internal/chat/claude_translate_test.go`);
`testChat02ToolStepsArePersistedImmediately`
(`WatchtowerDesktop/Tests/Core/ChatTurnDriverTests.swift`);
`TestChat02_GateDecisionsAreSteps` (`internal/chat/gate_test.go`);
`testChat02WaitingStepIsVisibleUntilItEnds`
(`WatchtowerDesktop/Tests/Core/ChatTurnDriverTests.swift`)

## CHAT-03 — bounded warm sessions

**Status:** Enforced

**Observable:** At most 3 session processes are alive at once
(`ChatSessionPolicy.maxLive`); a session's own turn is never cut to make
room — a 4th concurrent conversation queues (its turn held) until a slot
frees, and eviction only ever picks an idle session (LRU among the idle
ones). A session idle for 10 minutes (`ChatSessionPolicy.idleTTL`) is closed
within one 30 s poll after crossing the TTL. Quitting the app (Cmd+Q, tray
Quit — `QuitCoordinator`) closes chat sessions **before** stopping the
daemon, so no session's process nor its `watchtower mcp` child is left
running once the daemon (and its exclusive `sync.lock`) is gone: every
session gets the `close` command, then one SIGTERM after a 2 s grace, then
SIGKILL after 3 s more if it is still alive — a busy turn's partial text is
kept (`status='partial'`) rather than discarded. On the Go side, `Session`
reaps the `claude` child and its own children on `Close()`, on stdin EOF,
and when a stuck write blocks a full pipe (the write fails instead of
hanging the turn) — no orphan process survives eviction, quit, or a
misbehaving child.

**Guard:** `testChat03NeverEvictsABusySessionQueuesInstead`,
`testChat03DecisionNeverExceedsTheBound`
(`WatchtowerDesktop/Tests/Core/ChatSessionPolicyTests.swift`);
`testChat03PoolNeverRunsMoreThanThreeSessions`,
`testChat03BusySessionsAreNeverEvictedTheFourthWaits`,
`testChat03RetiringABusySessionNeverLetsTheQueuedFourthOverlap`,
`testChat03IdleSessionIsClosedByTheNextTickAfterTTL`,
`testChat03CloseAllClosesEverySessionAndKeepsPartialText`
(`WatchtowerDesktop/Tests/ChatSessionPoolTests.swift`);
`testChat03QuitClosesChatSessionsBeforeStoppingTheDaemon`
(`WatchtowerDesktop/Tests/QuitCoordinatorTests.swift`);
`TestChat03_CloseReapsStubbornChild`,
`TestChat03_CloseDuringReplayNeverRespawns`,
`TestChat03_ClosedBackendRefusesToSpawn`,
`TestChat03_CloseUnblocksAStuckWrite`
(`internal/chat/claude_backend_test.go`);
`TestChat03_CloseWhileWaitingForApprovalRejectsAndReaps`
(`internal/chat/gate_test.go`)

## CHAT-04 — content stays off argv

**Status:** Enforced

**Observable:** The system prompt, the owner's text and attachment paths
never appear on any process's argv: the prompt travels in a 0600 temp file
(`--system-prompt-file`, deleted when the session exits), the turn's text
and attachment paths travel in the `turn` command on stdin (an accepted
attachment's file content is base64-encoded into the stdin content block —
its path is never written to stdin either), and any MCP config carrying
connection secrets travels as a 0600 temp-file path (`--mcp-config`), also
deleted on exit. This holds across providers: the Claude backend's argv is
ids/flags only (`--resume`, `--model`, etc.), and the codex-backed turn
hands codex the system prompt as a 0600 `model_instructions_file` (only
its path on argv) and the replay + user text on stdin (`codex exec -`),
never as `-c developer_instructions=...` or a positional prompt.
`ai session`'s own argv (the Swift session-launch side) carries only
ids and names (`--conversation`, `--provider`, `--model`, `--surface`,
`--project-id`, `--resume`, `--db-path`) — the turn's text and attachments
exist only in the stdin JSONL command. A resumed session (`--resume`) never
re-sends `--system-prompt-file` either — it reuses the prompt already
recorded in its resumed history rather than passing it (or anything else)
again on argv. The one-shot `watchtower chat title` call is covered too:
its user message (the owner's first exchange) always travels on the
claude/codex child's stdin, whatever its size, and so is `watchtower
terminal title`, whose user message is the owner's typed messages from an
embedded Claude Code session's transcript. Since board #566 the same holds
for every one-shot claude/codex call — the `digest`/`codex` generators
behind the daemon pipelines and `ai.Client`/`codex.Client` behind
`ai query` and automations: the user message always goes on stdin, the
system prompt in a 0600 file (`--system-prompt-file` for claude,
`model_instructions_file` for codex) removed after the call, whatever the
size. The Desktop's `ai query` chats (Discuss, code questions, help) pass
`--prompt-stdin`, so the owner's message and the system prompt sit in one
JSON object on the CLI's stdin, not on its argv either (the positional
prompt stays for CLI users). Out of scope: the interactive Claude Code /
Codex sessions in the workbench terminal, whose first prompt is a
positional argument of the agent CLI (a fixed template, or the text of a
code-question hand-off the owner sends).
Extends QC-03's "secrets never on argv" to all chat content.

**Guard:** `TestChat04_ClaudeArgvCarriesNoContent`,
`TestChat04_ClaudeSendsRealAttachmentAsContentBlock`,
`TestChat04_ClaudeArgsOnResume`
(`internal/chat/claude_backend_test.go`);
`TestChat04_CodexSessionArgvCarriesNoContent`
(`internal/codex/client_test.go`);
`TestChat04_ChatTitleArgvCarriesNoContent` (`cmd/chat_test.go`);
`TestChat04_TerminalTitleArgvCarriesNoContent` (`cmd/terminal_test.go`);
`testChat04SessionArgvNeverCarriesContent`,
`testChat04TurnContentTravelsOnlyOnStdin`
(`WatchtowerDesktop/Tests/ChatSessionClientTests.swift`)

## CHAT-05 — artifacts never send

**Status:** Enforced

**Observable:** Artifact actions only open or copy: an `email` artifact
opens a Gmail compose URL (or a `mailto:` fallback), a `slack` artifact
copies its body and opens the channel/thread deep link, an `event` artifact
opens a Google Calendar template URL, `document`/`table`/`code`/`html` artifacts
copy or export (.md/.csv/.txt/.html) locally — every action any artifact kind can
produce is a `copy`, an `open` of a compose/deep-link URL, or a
`copyThenOpen`, never a value that could perform a network or CLI write.
Nothing is sent, posted or created in an external system from an artifact.
The artifact-side source files (`ArtifactParser`, `ArtifactActions`,
`ArtifactPanelModel`, the panel/card views) contain no reference to
`Process(`, `CLIRunner`, `URLSession`, `findCLIPath`, `WatchtowerAIService`
or `ChatSessionPool` — a source scan, not just a behavioral test. Every
external write anywhere in the chat instead goes through the tool
registry's Propose → Approve path (AGENT-01..07) — the one
stated exception, publishing to the owner's own claude.ai account, is below.

The same scan covers the artifact-comment files (`ArtifactCommentsModel`,
`ArtifactCommentMessage`, `ArtifactCommentReanchor`, `ArtifactCommentText`,
`ArtifactCommentQueries`, `ArtifactCommentsView`, the shared `CommentBatchComposer`), and no scanned file may
reference `.send(`, `sendDraft` or `startTurn`: an artifact comment reaches
the assistant only inside the owner's own chat message, sent by the chat
(`ChatViewModel.sendArtifactComments`) when the owner presses
**Send N comments**.

The in-app artifact panel is unchanged: every artifact action is a copy, an open or
a `copyThenOpen`, and the artifact-side files never reference a process, network or
session entry point. On the Claude provider the assistant itself may publish to the
owner's own claude.ai account without a per-call approval — `Artifact` `publish`
of a file inside the session's publish dir, `list`/`open`/`quickstart`, and Claude
Docs create/update/batch of the owner's own private doc — always as a visible step
with the resulting link. Every other write through a claude.ai connector, sharing or
deleting a published page or doc included, goes through the session's permission
gate: one `agent_actions` row, executed by the session only after the owner's
Approve and at most once (AGENT-05), denied on Reject, Stop, timeout or a dead
session. Owner approved 2026-10-13, ask #236.
The gate never allows a call it cannot classify: an unknown tool of a listed
connector, a tool without annotations, unparseable input, or a call whose
proposal cannot be recorded is denied or waits for Approve — never run
silently — and a refused or failed publish is a red step. `Write`, `Artifact`'s
sources (relative ones joined with `root`) and `read`'s `out_dir` (and the final
path the read saves to) are confined to the conversation's publish dir;
`Artifact` `pin`/`unpin`/`delete`, a publish to a URL this session did not
publish, and a Claude Docs call that shares, deletes, mentions someone other
than the owner, answers a comment thread, or comments on or otherwise touches
anything outside a doc this session created — one such member makes a whole `batch` wait — go to Approve.
No tool call of the claude.ai-mode child touches a TCC-guarded location in its
standard place (Desktop, Documents, Downloads, Pictures/Photos, Movies, Music,
iCloud Drive, cloud storage, other apps' containers and data, removable and network
volumes under `/Volumes`, `/Network`, `/home`, `/net`): the CLI inspects a
model-chosen path before it asks the gate, so the child always runs under a macOS
sandbox profile (`ChildSandbox`) that denies every file access there — read, write,
stat and existence test — and a sandbox denial never reaches TCC, so no privacy
prompt appears in Watchtower's name. Without the sandbox the claude.ai tools are off; a claude.ai-mode
child is never started without it.

**Guard:** `testChat05ArtifactActionsOnlyOpenOrCopy`
(`WatchtowerDesktop/Tests/Core/ArtifactActionsTests.swift`);
`testChat05ArtifactSurfacesNeverWrite`
(`WatchtowerDesktop/Tests/Core/ArtifactChat05ScanTests.swift`);
`TestChat05_ContractSaysArtifactsNeverSend`
(`internal/chat/artifacts_contract_test.go`);
`testArtifactCommentsReachTheAssistantOnlyAsTheOwnersMessage`
(`WatchtowerDesktop/Tests/ChatViewModelTests.swift`);
`TestChat05_ConnectorWriteWaitsForApproval`,
`TestChat05_PublishOnlyFromThePublishDir`,
`TestChat05_DeadSessionNeverRunsAnApprovedCall`
(`internal/chat/gate_test.go`);
`TestChat05_ClaudeAIChildNeverTouchesTCCGuardedFolders`
(`internal/chat/sandbox_test.go`; its real-sandbox halves run on macOS only);
`testChat05PublishedLinkCardOnlyOpensOrCopies`
(`WatchtowerDesktop/Tests/Core/ArtifactChat05ScanTests.swift`)

## Changelog

- 2026-10-18 (board #737, owner decision ask #342 "guard before the CLI"): **CHAT-05** strengthened, no guard relaxed. The PR #379 review found that the CLI resolves, lists or hashes a model-chosen `Write` target or `Artifact` source before it sends `can_use_tool`, so the gate's lexical publish-dir check could not keep a path in `~/Documents` untouched. The Observable gains the TCC rule: the claude.ai-mode child runs under a macOS sandbox profile denying file reads and writes in the TCC-guarded folders (`internal/chat/sandbox.go`), the tools are off without it, and a claude.ai-mode child never starts without it. New guard `TestChat05_ClaudeAIChildNeverTouchesTCCGuardedFolders`; the live evidence is in `internal/chat/testdata/claude_ai_probe.md` ("Sandbox").
- 2026-10-18 (fix after #670 phase 2b-2): note only — **no contract or assertion changed**. `testChat01PartialTextSurvivesProcessDeathAndTheNextTurnResumes` waits for `!vm.isBusy` (the turn ended and its terminal write landed) instead of `!vm.isStreaming` before its next send: since 2b-2 a turn stops running before its final write lands, and the send is refused until it does, so the old wait raced the write on CI. `isBusy` includes `isStreaming`, so the wait is strictly stronger; the assertions are unchanged.
- 2026-10-18 (board #670 phase 2b-2): note only — **no contract or assertion changed**. `ChatTurnStore` and `EmbeddedChatStore` write off the main thread: `ChatTurnDriver` queues every write in order as its event arrives, so a tool step is still written as it happens (CHAT-02), and an ended turn's final write lands before `onTurnFinished`; `ChatSessionClient.close` (quit) waits for it (CHAT-01 partial text survives quit). The guards gained awaits only: `testChat02ToolStepsArePersistedImmediately` awaits `driver.writesSettled()` before each read (and its reads await the pool), and `testChat01PartialTextSurvivesStop` awaits `vm.writesSettled()` after the turn stopped streaming, before the row is read; `testArtifactCommentsReachTheAssistantOnlyAsTheOwnersMessage`'s helper awaits the now-`async` comment add. The assertions are unchanged.
- 2026-10-18 (board #670 phase 2b-1, PR #398): note only — **no contract or assertion changed**. `ChatViewModel`'s writes are `async`, so the CHAT-01 guards and `testArtifactCommentsReachTheAssistantOnlyAsTheOwnersMessage` gained `async`/`await` only: a call inside an `XCTAssert…`/`XCTUnwrap` is hoisted into an awaited `let` (XCTest autoclosures cannot await) and the same assertion runs on it. CHAT-01's order (owner row on disk before the turn is sent, nothing sent when it cannot be saved) is unchanged; the composer now clears at send and gets the text back on a failed save.
- 2026-10-17 (board #737, Task 16): the #737 guards landed and lost their `(planned, #737)` marks, each verified by `grep` (`TestChat02_GateDecisionsAreSteps`, `testChat02WaitingStepIsVisibleUntilItEnds`, `TestChat03_CloseWhileWaitingForApprovalRejectsAndReaps`, `TestChat05_ConnectorWriteWaitsForApproval`, `TestChat05_PublishOnlyFromThePublishDir`, `TestChat05_DeadSessionNeverRunsAnApprovedCall`, `testChat05PublishedLinkCardOnlyOpensOrCopies`). **CHAT-05** strengthened, no exception widened: its Observable now states the gate's fail-closed rules (an unclassifiable or unrecorded call is denied or asks, never silently allowed; a failed publish is a red step), the publish-dir confinement of `Write`, `Artifact` sources and `read`'s `out_dir`, and which `Artifact` and Claude Docs calls always go to Approve — all as already implemented and covered by `internal/chat/connectorpolicy/policy_test.go` and `internal/chat/gate_test.go`. Feature note: `docs/features/chat-claude-ai-tools.md`.
- 2026-10-17 (board #737): amended per spec 2026-10-16-chat-claude-ai-tools-design §4, owner approved 2026-10-13, ask #236 (scope and the CHAT-05 amendment; spec approved ask #325, decisions Q1–Q4 ask #326, plan approved ask #332); strengthening + one stated exception, no guard relaxed. **CHAT-05** gains the one private exception — on the Claude provider the assistant may publish to the owner's own claude.ai account (`Artifact` `publish` from the session's publish dir, `list`/`open`/`quickstart`, the owner's own private Claude Docs doc) as a visible step with its link — while every other claude.ai connector write goes through the session's permission gate as one `agent_actions` row the session alone executes after the owner's Approve (AGENT-05); the in-app artifact panel and its source scan are unchanged. **CHAT-02** gains gate decisions as steps (a denied call is a red step with the gate's reason, a waiting call a visible waiting step). **CHAT-03** gains a guard for `Close` during an approval wait. New guards are marked `(planned, #737)` until they land. The TCC guard stays: user settings are never loaded (`--setting-sources project,local`, private neutral cwd). DEV-06: no change — the workbench terminal is plain Claude Code and already has these tools under the owner's own settings.
- 2026-10-17 (board #566, owner decision in ask #305): prompts never ride a claude/codex child's argv, whatever their size or caller. `digest.ClaudeGenerator` and `ai.Client` pass the user message on stdin (bare `-p`) and a non-empty system prompt as a 0600 `--system-prompt-file` (an empty one stays `--system-prompt ""`); `codex.CodexGenerator` and `codex.Client` pass a non-empty system prompt as a 0600 `-c model_instructions_file="<path>"` (codex-cli 0.145; it replaces codex's built-in base instructions, MCP tool use verified unchanged) and the user message on stdin (`codex exec -`), never `-c developer_instructions=...` or a positional prompt. A codex older than 0.145 (or whose `--version` cannot be read; probed once per binary and logged) keeps the former delimited one-stdin-payload layout instead, still off argv. The temp files are removed after the call, and the daemon sweeps `wt-system-prompt-*` leftovers older than 10 minutes at startup. `ai query --prompt-stdin` (JSON `{"prompt", "system_prompt"}` on stdin) is what the Desktop now uses, so the owner's message is off the CLI's argv too. `digest.StdinThreshold` and the opt-in `SetStdinOnly` modes are gone. **CHAT-04** strengthened; one guard assertion changed shape: `TestChat04_CodexSessionArgvCarriesNoContent` no longer calls `SetStdinOnly`, asserts that the system prompt arrives in the 0600 `model_instructions_file` (it used to assert that it arrived on stdin, ahead of the user message), and its "a plain client keeps developer_instructions on argv" half now asserts the opposite (a read-folder client keeps the same layout). Its "nothing on argv" assertions are unchanged.
- 2026-10-17 (board #563): **CHAT-05** strengthened, not changed. `SandboxedHTMLView` now turns WebRTC off in the web view's preferences (`lockDown`: `_setPeerConnectionEnabled:` read back; on a WebKit without it the reason is logged and the document-start script, which stays, removes WebRTC; DNS prefetch off best effort), so a fresh iframe of a chat html artifact cannot get WebRTC back. The workbench preview's https loads narrow to a CDN allowlist, its folder is served by a read-only scheme handler (`SandboxedHTMLSchemeHandler.swift`, no hidden files or links into them), and the loopback server streams files; none of it touches the artifact side. `testChat05ArtifactSurfacesNeverWrite` also scans `SandboxedHTMLSchemeHandler.swift`; both scan tests otherwise pass unchanged.
- 2026-10-17 (board #535): artifact kind `html` (migration `00129`). An html artifact renders in `SandboxedHTMLView` (no network of any scheme, no bridge, no windows or media capture, WebRTC removed, links open nothing), and its new controls are view-only: **Reload**, **Open in Window** and **Present**. Nothing hands artifact content to a browser or any other networked app; `kindActions` has no `html` case (`testHTMLArtifactHasOnlyCopyExportAndView`), so its actions stay Copy and Export…, and `testChat05ArtifactActionsOnlyOpenOrCopy` covers it unchanged. **CHAT-05** strengthened, not changed: `ArtifactChat05ScanTests` also scans `SandboxedHTMLView.swift` and `HTMLPreviewPolicy.swift` and forbids `LocalPreviewServer`, `HTMLBrowserOpener`, `NWConnection` and `NWListener` on every artifact-side file. The loopback server behind the workbench code viewer's Open in Browser (`LocalPreviewServer.swift`, workbench files only) gets its own scan, `testChat05LoopbackServerNeverConnectsOut` (no `URLSession`, `NWConnection(`, `Process(`, `CLIRunner`).
- 2026-10-17 (board #536): the chat quote batch is now fed by selecting a passage in the feed (**Ask about this**, `ChatSelectionQuoteTracker`) instead of the removed **Quote in reply** sheet. The batch, its send rule (`ChatQuoteReply.compose`, one owner turn) and CHAT-05's "nothing sent per quote" are unchanged; `ChatQuoteReplyScanTests` is renamed `ChatSelectionQuoteScanTests`, now scans `ChatSelectionQuote.swift` (no send entry point) and adds `ChatFeedView.swift` to the files that host no text view. No CHAT-01..05 guard changed.
- 2026-10-01 (board items #178–#181): the artifact panel reads and comments on one rendering of the latest version (`ArtifactCommentsView` over `DocumentTextView`; a `table` artifact now anchors on its cells rather than raw CSV), and comment fields share `Views/Comments/CommentTextEditor.swift`; `DocumentAttributedString` moved to its own file. **CHAT-05** strengthened, not changed: `ArtifactChat05ScanTests` also scans `DocumentAttributedString.swift` and `CommentTextEditor.swift`. Adding a comment still sends nothing.
- 2026-10-01 (board item #84): the artifact panel's header Comment button is replaced by the selection-comment affordance it now shares with project documents (`Views/Comments/CommentableDocumentText.swift` over `DocumentTextView.swift`: a floating Comment button at the selection, "Comment…" in the context menu). **CHAT-05** strengthened, not changed: `ArtifactChat05ScanTests` also scans those two files. Adding a comment still sends nothing.
- 2026-09-29 (Projects POC Phase 6, spec `docs/superpowers/specs/2026-09-29-project-board-poc-design.md` §6.3): **CHAT-05**'s Observable extends to owner comments on chat artifacts (`chat_artifact_comments`, migration `00082`, Swift-only writer — Go neither reads nor writes it) and to the chat quote-reply batch. Both stay private/pending state until the owner's own send: **Send N comments** composes the unsent artifact comments into one ordinary owner message (`ArtifactCommentMessage`, built on the shared `CommentBatchComposer` batch rule — comments never reach the assistant one by one), and **Quote in reply** accumulates quoted passages into a per-conversation batch that rides along with the owner's own next turn (`ChatQuoteReply`, the same composer). The source scan (`ArtifactChat05ScanTests`) is extended to these new files and now also forbids any `.send(`/`sendDraft`/`startTurn` reference on the artifact side. `ArtifactsContract` gains one line asking the assistant to answer comments with a new version of the same artifact key. No CHAT-01..04 guard changed.
- 2026-09-26: initial contracts CHAT-01..05 (spec `docs/superpowers/specs/2026-09-26-chat-redesign-design.md` §9).
- 2026-09-30: CHAT-05 extended to artifact comments (projects POC phase 6, migration 00082): the source scan covers the comment files and forbids send entry points on the artifact side; comments leave the machine only as the owner's own message. Strengthening only — no guard relaxed.
