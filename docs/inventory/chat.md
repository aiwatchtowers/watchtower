# Behavior Inventory — Chat (main chat, the Chats tab)

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.

The main chat (the Chats tab): warm per-conversation `watchtower ai session` processes
speaking protocol v2 (NDJSON events on stdout, JSONL commands on stdin), a
Go-built system prompt, branching history in goose-owned chat tables, visible
tool steps and sources, attachments, artifacts, projects, mentions and
skills. Design: `docs/superpowers/specs/2026-09-26-chat-redesign-design.md`.

**Module:** `internal/chat/`, `internal/chatengine/` (the Go chat engine and `chat.sock`, 2026-11-16), `internal/chatstore/`, `cmd/ai_session.go`, `cmd/chat.go`,
`internal/db/chat.go`, `internal/db/chat_migrate.go`,
`internal/db/migrations/00076_chat_core.sql`,
`WatchtowerDesktop/Sources/Services/Chat/`,
`WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/`,
`WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift`,
`WatchtowerDesktop/Sources/Views/Chat/`, `WatchtowerChat/` (`ChatWire`, `ChatUI`), `WatchtowerChatText/`
**Last full audit:** 2026-09-26

## CHAT-01 — owner text is never lost

**Status:** Enforced

**Observable:** The owner's message is written to `chat_messages` (by the Go chat engine, the only writer of the main chat's rows) before the
`turn` command is sent to the session process, so a failed spawn, a crashed
session or an app quit mid-turn never loses what was typed — if the write
itself fails (e.g. a DB trigger aborts it), nothing is sent and the text
stays in the composer. Assistant text that already streamed survives Stop, a
session crash and app quit: it is persisted with `status='partial'` (Stop
sends `cancel` and the interrupted turn renders "Stopped" + Continue; a
crashed process's partial text is flushed and the next send respawns the
session, which replays the history from the database — no session resumes
a stored provider session since #604 G11; the replay waits for the
stopped reply's last save). On the Mac and the phone the composer keeps the typed text until the engine's echo is `applied` (a refused or failed send writes nothing and the text stays; a send repeated with the same `client_key` is answered with the first turn, so it is neither lost nor duplicated). A queued embedded-chat message waiting for its
turn is kept in `chat_queued_drafts` and comes back as a draft after a
relaunch. Regenerate and Edit insert
their new assistant/user rows under the NEW turn id **before** the turn goes
out, and a failed turn is recorded as an `error` row before the next turn is
accepted — both close the same failure mode: Go's `HistoryBefore` strips
only a *trailing* owner row with no reply, so an owner message can never be
silently dropped from replay.

**Amendment (2026-11-15, #1791, owner decision ask #1340):** the turn's rows are written by the turn's **lease holder's** store, Swift (the Desktop's `ChatTurnStore`) or Go (`internal/chatstore`, run by the hub's `chatrun` runner); "the Swift turn store is the writer" no longer holds. One `chat_turn_leases` row per conversation (migration 00189) is claimed inside the owner-row transaction, so the first commit wins and the loser writes nothing (the phone gets `conversation_busy` and its text back; the Mac keeps its draft). The same order and `partial` rules bind the Go store, and no Swift guard changed. The phone never writes chat rows; its typed text survives a kill of the app because each send is kept in `chat_outgoing` (the hub's offline-copy file) until the hub applies or refuses it, and a send the hub never saw comes back as a draft.
Added guards: `TestChat01Go_OwnerRowBeforeTurn`, `TestChatstore_StopKeepsPartial`, `TestChatstore_ProcessDeathFinalizesPartial`, `TestFinalize_RetriesAfterWriteFailure`, `TestChatstore_ConversationDeletedMidTurnStopsCleanly`, `TestChatstore_MatchesSwiftFixture` (`internal/chatstore/store_test.go`, `fixture_test.go`: the Go store's rows equal the Swift store's over `internal/chatstore/testdata/chat_turn_cases.json`, read by `WatchtowerDesktop/Tests/Core/ChatTurnStoreFixtureTests.swift`); the lease: `TestChatLeaseCases`, `TestLease_ConcurrentClaimOneWins` (`internal/db/chat_lease_test.go`), `ChatLeaseQueriesTests` and `ChatTurnLeaseTests` (`testConcurrentClaimOneWins`, `testSendRefusedWhileHubHoldsLeaseKeepsDraft`, `testDriverStopsWhenConversationDeleted`; Swift, same `chat_lease_cases.json`); the phone: `ChatSendTests`, `ChatSendRecoveryTests` (`WatchtowerMobile/Tests/`).

**Amendment (2026-11-16, #1822 unified chat T1, owner approval ask #1371, spec `docs/superpowers/specs/2026-11-16-unified-chat-design.md` §9.2):** the Go chat engine (`internal/chatengine`, which absorbs the hub's `chatrun` runner) writes the owner row before the turn is sent, through the same Go turn store and its same order and `partial` rules; a refused turn (busy, invalid, conversation gone) writes nothing. A `chat_turn` may carry a `client_key`, stored on the row its start transaction inserts (`chat_messages.client_key`, unique per conversation, migration 00194); a repeated key is answered with the turn it already started, also after a daemon restart, so a send whose answer was lost is neither lost nor applied twice. The Go guards move to `chatengine`; the Swift guards stay until the Mac's chat moves onto the engine (plan T8), assertions kept. Added guards (`internal/chatengine/engine_test.go`): `TestChat01_RefusedTurnWritesNothing`, `TestChatengine_SecondTurnBusy`, `TestChatengine_RepeatedClientKeyAppliesOnce`, `TestChatengine_ClientKeySurvivesRestart`, `TestChatengine_SendAfterStopReplaysSavedText`, `TestChatengine_DeleteDuringTurnCancels`; `TestMigration00194_ClientKeyUniquePerConversation` (`internal/db`).

**Amendment (2026-11-16, #1822 unified chat T8, owner approval ask #1371, spec §6.2, §9.2):** the Mac's chat runs on the engine over `chat.sock`: its Swift turn writer, lease and pool are gone, so every main-chat row is the engine's (the Go store's order and `partial` rules above). On the Mac the composer keeps its text until the engine's echo is `applied` (ChatUI's `ChatComposerModel`); a refused or failed send puts nothing on disk and the text stays. The Swift guards moved to Go and ChatUI with their assertions — table in the 2026-11-16 T8 changelog entry.

**Guard:** `TestChat01Go_OwnerRowBeforeTurn`, `TestChat01_RefusedTurnWritesNothing`,
`TestChat01_UnsavableOwnerRowSendsNothing`, `TestChat01_FailedSpawnLeavesOwnerMessageAnswered`,
`TestChat01_RegenerateAndEditRowsBeforeTheTurnIsSent` (`internal/chatengine`);
`TestChatstore_StopKeepsPartial`, `TestChatstore_ProcessDeathFinalizesPartial`,
`TestChatstore_MatchesSwiftFixture` (`internal/chatstore`; its regenerate, edit and legacy-question cases);
`testChat01DraftStaysUntilApplied`, `testRefusedSendRestoresDraft`, `testBusyEchoReturnsTextToComposer`,
`testDroppedEchoResendsWithSameKeyNoDuplicate`
(`WatchtowerChat/Tests/ChatUITests/ChatConversationModelTests.swift`);
`testHostGoneMidSendKeepsDraftQuotesAndChips`, `testLostEchoResendReusesKeyWhileDraftUnchanged`
(`WatchtowerChat/Tests/ChatUITests/ChatComposerModelPickerTests.swift`)

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

**Amendment (2026-11-15, #1791, ask #1340):** the Go turn store writes a tool step at once when it starts (`Apply` on `tool_start`), not at turn end, exactly as the Swift driver does; a failed tool is a red step. New guard `TestChat02Go_StepPersistedOnStart` (`internal/chatstore/store_test.go`). No existing guard changed.

**Guard:** `TestChat02_ToolCallNeverWipesText`
(`internal/chat/claude_translate_test.go`);
`TestChat02Go_StepPersistedOnStart` (`internal/chatstore/store_test.go`);
`TestChat02_GateDecisionsAreSteps` (`internal/chat/gate_test.go`);
`testChat02WaitingStepVisibleUntilEnd`
(`WatchtowerChat/Tests/ChatUITests/ChatConversationModelTests.swift`);
`TestTurnBackend_CodexToolCallsBecomeSteps`
(`internal/chat/turn_backend_codex_test.go`);
the transport contract suite's `two-messages`, `tool-ok` and
`tool-failed` rows on every chat and stream backend (warm claude, codex,
runtime B), resolved in `internal/transporttest/testdata/matrix.golden` and
run by `TestTransportSuite` (`internal/transporttest/matrix_test.go`): a
failed tool has a non-empty reason, text before a call is kept, two messages
keep their separator

## CHAT-03 — bounded warm sessions

**Status:** Enforced

**Observable:** At most 3 session processes are alive at once
(`chatengine.MaxLive`, the one pool of the Mac and the phone together); a session's own turn is never cut to make
room — a 4th concurrent conversation queues (its turn held) until a slot
frees, and eviction only ever picks an idle session (LRU among the idle
ones). A session idle for 10 minutes (`chatengine.IdleTTL`) is closed
by the engine once it crosses the TTL. A turn survives a daemon restart (the session is detached, and a detached session exits 10 minutes after its turn with no engine). Quitting the app (Cmd+Q, tray
Quit — `QuitCoordinator`), the data wipe, a Slack disconnect and the owner's `watchtower sync stop` end the chat (`chat_shutdown`, else `watchtower chat shutdown`) **before** stopping the
daemon, so no session's process nor its `watchtower mcp` child is left
running once the daemon (and its exclusive `sync.lock`) is gone: every
session gets the `close` command, then one SIGTERM after a 2 s grace, then
SIGKILL after 3 s more if it is still alive — a busy turn's partial text is
kept (`status='partial'`) rather than discarded. On the Go side, `Session`
reaps the backend's child process group, any transport, on `Close()`, on stdin EOF,
and when a stuck write blocks a full pipe (the write fails instead of
hanging the turn) — no orphan process survives eviction, quit, or a
misbehaving child.

**Amendment (2026-11-15, #1791, ask #1340):** the daemon (the hub) runs a **second**, separate bounded pool for phone-started turns: at most 2 `ai session` processes (`chatrun.MaxLive`), a turn's own session never cut to make room, a third conversation queues ("Waiting for a free slot"), idle sessions closed after 10 minutes, every session reaped (`close`, SIGTERM after 2 s, SIGKILL after 3 s more, own process group, group file under `<hub dir>/chatrun/`) when the daemon stops, and a start-up sweep kills orphan groups and releases the dead turns' leases. The Desktop's pool of 3 is unchanged, so up to 5 provider processes can run on one Mac. Added guards (`internal/hub/chatrun`): `TestChat03Go_PoolBound`, `TestChatrun_IdleEvictedForNewTurn`, `TestChatrun_DaemonStopLeavesPartialAndSweepReleases`, `TestChatrun_StartupSweepMarksSessionLost`, `TestChatrun_SweepKillsOrphanGroup`, `TestChatrun_RemoteCancelStopsTurn`. The Swift guards are unchanged.

**Amendment (2026-11-16, #1822 unified chat T1, owner approval ask #1371):** one pool of 3 in the chat engine: `chatengine.MaxLive = 3` replaces `chatrun.MaxLive = 2` (same rules: a turn's own session never cut, the 4th conversation queues, idle sessions closed after 10 minutes, every session reaped on close, group files under `<engine dir>/sessions/`, the start-up sweep). The Desktop's own pool of 3 stays until the Mac's chat moves onto the engine (plan T8); once it lands the engine's pool is the only one. The guards move with the code and keep their assertions with the new bound: `TestChat03Go_PoolBound` (now 3 processes, the 4th waits), `TestChatengine_IdleEvictedForNewTurn`, `TestChatengine_DaemonStopLeavesPartialAndSweepReleases`, `TestChatengine_StartupSweepMarksSessionLost`, `TestChatengine_SweepKillsOrphanGroup`, `TestChatengine_RemoteCancelStopsTurn` (`internal/chatengine`, renamed from `TestChatrun_*`). Added: `TestChatengine_ClaimsLegacyLeaseForOneRelease` (the engine still claims `chat_turn_leases` as owner `hub`, id `chatengine`, for one release, spec §9.3).

**Amendment (2026-11-16, #1822 unified chat T10a, owner approval ask #1371, spec §7, §9.2):** a turn outlives a daemon restart (D23). The engine starts each `ai session` detached (its own session, `setsid`) with `--listen <workspace>/chatengine/sessions/<conversation>.sock` (temp fallback by the socket path rule), 0600 in a 0700 folder, peer-checked; the daemon's stop only detaches (`Engine.Detach`: flush, drop the connection, the lease kept) and the next engine reattaches and replays the turn — also a session still binding its socket, which is adopted once it listens and gets the turn resent from its stored rows. A detached session is bounded too: with no engine attached and no turn running it exits after the 10-minute idle TTL (`ListenIdleTTL`), its backend's child process group reaped as before. App quit, the data wipe, a purge and the owner's `watchtower sync stop` end every turn `partial` and reap every session through `chat_shutdown` (cancel, `close`, SIGTERM after 2 s, SIGKILL after 3 s more; the engine keeps taking new turns); with no daemon answering, `watchtower chat shutdown` does the same over the session sockets and group files. Added guards: `TestChat03_DetachedSessionBounded` (`internal/chat/listen_test.go`), `TestChatengine_ShutdownReapsSessions`, `TestChatShutdownCLI_ReapsWithoutEngine`, `TestChatengine_RestartMidTurnReattachesAndFinishes`, `TestChatengine_KilledMidTurnSweepsSessionLost` (`internal/chatengine`). No guard relaxed; `TestChatengine_DaemonStopLeavesPartialAndSweepReleases` keeps its assertions (it pins `Engine.Close`, which tests and the stdio mode still use).

**Amendment (2026-11-16, #1822 unified chat T8):** the Desktop's own pool is gone; the engine's pool of 3 is the only one. Quitting asks the engine to end every chat turn (`chat_shutdown` through `SocketChatClient.shutdown()`) before the daemon stops; T10b adds the CLI fallback.

**Amendment (2026-11-17, #1822 unified chat T10b, spec §7):** the app's stops that must end the chat — quit, the Settings → Data wipe and Slack disconnect — call `AppState.shutdownChat()` before their daemon stop: `SocketChatClient.shutdown()` (it waits 2 s for the engine to greet when not connected, then 11 s — the engine's 10 s budget and a margin — for the answer), and when the engine could not end it `watchtower chat shutdown --socket-timeout 1s` (`DaemonManager.chatShutdownBounded`, 12 s watchdog), whose short socket step leaves its direct reap of the session sockets and groups inside the watchdog. Quit and the wipe hold the chat client first (every operation but `chat_shutdown` refused, no daemon start from a lost connection) and refuse every daemon start (`AppState.stoppingForGood`); a wipe whose daemon did not stop releases both. The launch's compaction runs `watchtower chat shutdown` (`CompactionCLI.chatShutdown()`) before it stops the daemon. Every `sync stop` the app runs passes `--internal` (no stopped marker; sessions left to the shutdown above), pinned by `DaemonManagerArgvScanTests.testEveryAppSyncStopIsInternal`. The quit guard keeps its name and assertion; its closure is renamed `closeChatSessions` → `shutdownChat`. Added: `testQuitFallsBackToCLIShutdown`, `testWipeShutsDownChatFirst`, `testSlackDisconnectShutsDownChatFirst`, `testCompactionStepShutsDownChatSessionsFirst`. An account removal that purges data runs in the daemon (`account_purges`), not through an app stop, so it has no app path here.

**Guard:** `TestChat03Go_PoolBound`, `TestChat03_AdmitNeverExceedsTheBound`,
`TestChat03_RetiringSessionNeverOverlapsTheQueuedFourth`, `TestChat03_RetireOfBusySessionsNeverCutsOrOverlaps`,
`TestChat03_PredecessorAliveHoldsTheReplacement`, `TestChatengine_WarmNeverTakesASlotFromATurn`,
`TestChatengine_IdleEvictedForNewTurn`, `TestChatengine_IdleSessionExpires`,
`TestChatengine_ShutdownReapsSessions`, `TestChatengine_DaemonStopLeavesPartialAndSweepReleases`
(`internal/chatengine`);
`testChat03QuitClosesChatSessionsBeforeStoppingTheDaemon`
(`WatchtowerDesktop/Tests/QuitCoordinatorTests.swift`);
`TestChat03_CloseReapsStubbornChild`,
`TestChat03_CloseDuringReplayNeverRespawns`,
`TestChat03_ClosedBackendRefusesToSpawn`,
`TestChat03_CloseUnblocksAStuckWrite`
(`internal/chat/claude_backend_test.go`);
`TestChat03_CloseWhileWaitingForApprovalRejectsAndReaps`
(`internal/chat/gate_test.go`);
the transport contract suite's `timeout-kill`, `interrupt-text` and
`interrupt-tool` rows (`TestTransportSuite`, `internal/transporttest`; no
pid of a fake CLI's grandchild survives, a warm child survives an
interrupt) and `TestFakeCLI_GroupReaped`

**Amendment (2026-10-25, #608):** the main chat's claude.ai tools (publish and connectors) gain a first off reason, the organization's `AllowClaudeAITools = false` — "claude.ai tools are turned off by your organization's policy." — and a warm `ai session` answers each turn with the policy error when its provider is no longer allowed (`policyCheckedBackend`). Guards: `internal/chat/claudeai_test.go` `TestClaudeAIAvailability_PolicyOff`, `cmd/provider_policy_test.go` `TestProviderPolicy_SessionTurnRefused`.

## CHAT-04 — content stays off argv

**Status:** Enforced

**Observable:** The system prompt, the owner's text and attachment paths
never appear on any process's argv: the prompt travels over an inherited
pipe (`--system-prompt-file /dev/fd/N`, nothing on disk), the turn's text
and attachment paths travel in the `turn` command on stdin (an accepted
attachment's file content is base64-encoded into the stdin content block —
its path is never written to stdin either), and any MCP config carrying
connection secrets travels over an inherited pipe as well
(`--mcp-config /dev/fd/N`). This holds across providers: the Claude
backend's argv is flags and `/dev/fd` paths only (`--model`,
`--no-session-persistence`, etc.; never `--resume`), and the codex-backed
turn hands codex the system prompt as a 0600 `model_instructions_file`
(only its path on argv; codex refuses a pipe there; codex re-reads the file
for every model request, so it is held — under a flock the stale-temp sweep
skips — until codex exits, then removed) and the replay + user text on stdin (`codex exec -`),
never as `-c developer_instructions=...` or a positional prompt.
`ai session`'s own argv (the Swift session-launch side) carries only
ids and names (`--conversation`, `--provider`, `--model`, `--surface`,
`--project-id`, `--db-path`) — the turn's text and attachments exist only
in the stdin JSONL command. No Claude Code session store is written
(`--no-session-persistence`): every new child gets the prompt over its pipe
and the history as a replay. The one-shot `watchtower chat title` call is covered too:
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
`TestChat04_ClaudeArgsNeverResume`
(`internal/chat/claude_backend_test.go`);
`TestChat04_CodexSessionArgvCarriesNoContent`
(`internal/codex/client_test.go`);
`TestChat04_ChatTitleArgvCarriesNoContent` (`cmd/chat_test.go`);
`TestChat04_TerminalTitleArgvCarriesNoContent` (`cmd/terminal_test.go`);
`TestChat04_EngineSessionArgvCarriesNoContent`,
`TestChat04_ListenTurnContentOnlyOnSocket` (`internal/chatengine`)

## CHAT-05 — artifacts never send

**Status:** Enforced

**Observable:** Artifact actions only open or copy: an `email` artifact
opens a Gmail compose URL (or a `mailto:` fallback), a `slack` artifact
copies its body and opens the channel/thread deep link, an `event` artifact
opens a Google Calendar template URL, `document`/`table`/`code`/`html` artifacts
copy or export (.md/.csv/.txt/.html, and .docx for a `document`) locally, and a
`document`/`html` artifact can be printed through the macOS print panel, whose
PDF menu (Save as PDF, Mail, Messages, network printers) acts only on the
owner's own choice there, on a static rendering in the same no-network web view — every action any artifact kind can
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

**Amendment (2026-11-15, #1791, ask #1340):** the iPhone app's artifact sheet only opens or copies, like the Mac's panel: an `email` artifact opens `mailto:`, an `event` a Google Calendar template URL, a `slack` artifact copies its body and opens the Slack link, `html` renders in a sandboxed `WKWebView` (non-persistent store, a content rule blocking every non-local load, no message handlers, navigation pinned to `about:`, WebRTC removed in the page and in script-made iframes), and Copy and Share are on every kind. The links come from the one builder both apps use (`WatchtowerChatText.ArtifactLinks`). A source scan covers the phone's artifact files: no `URLSession`, no `enqueue`, no `send(`, no `ActionOutbox`, no `ChatSender`, no script message handler. Approvals from the phone go through the registry (`chat_action_answer` → `Registry.ApproveSeen` with the shown args hash, or `Registry.Reject`, AGENT-05 unchanged). Added guards: `PhoneArtifactChat05ScanTests`, `ChatArtifactActionsTests`, `ChatApprovalWiringTests` (`WatchtowerMobile/Tests/ChatAttachmentAndCopyTests.swift`, `ChatSendTests.swift`), `PhoneArtifactWebRTCTests` (`ChatArtifactWebRTCTests.swift`, a simulator test), `ArtifactLinksTests` (`WatchtowerChatText/Tests`), and in Go `TestChatActionAnswer_NeedsPermissions`, `TestChatActionAnswer_StaleHashRefused`, `TestChatActionAnswer_DeadSessionRowIsFinal` (`internal/hub/actions/handlers/chat_test.go`), `TestReject_OnlyAPendingRow` (`internal/tools`). The Mac's `ArtifactChat05ScanTests` is unchanged except for the new location of the two moved files.

**Amendment (2026-11-16, unified chat T3, ask #1371):** a message part's fallback (CHAT-06) may only open or copy a link the CHAT-05 rules permit, or send one fixed owner text the owner taps; it never sends or writes anything an artifact could not. `TestChat05_FallbackActionsOnlyOpenCopyOrFixedTurn`.

**Amendment (2026-11-17, #1822 unified chat T11, final text):** every chat surface — the main chat on both devices, the embedded chats, Workchat and the owner-ask drawer — draws artifacts, rows, published-link cards and question cards with `ChatUI`, so one source scan covers them: `ChatUISourceScanTests.testChat05FallbackAndArtifactActionsOnlyOpenOrCopy` scans `Parts/FallbackPartView.swift`, `Parts/ArtifactPartView.swift`, `Parts/PublishedLinkPartView.swift`, `Feed/ChatMessageRow.swift`, `Parts/QuestionPartView.swift`, `Artifacts/ArtifactViewer.swift`, `Parts/SourcesPartView.swift`, `Platform/iOS/ArtifactViewerParts.swift` (since the final review, M2) and the macOS and iOS web-view and print files for `Process(`, `CLIRunner`, `URLSession`, send entry points and the like, and checks the fallback action shapes. `ArtifactChat05ScanTests` scans what is left on the Mac's artifact path (the artifact panel and comment files, `EmbeddedArtifactSheet.swift`, `DesignKitChatStyle.swift`). A fallback's actions are only `chat_turn` with a fixed text, `open_url` under these rules, or `none`.

**Guard:** `testChat05ArtifactActionsOnlyOpenOrCopy`
(`WatchtowerDesktop/Tests/Core/ArtifactActionsTests.swift`);
`testChat05ArtifactSurfacesNeverWrite`
(`WatchtowerDesktop/Tests/Core/ArtifactChat05ScanTests.swift`);
`TestChat05_ContractSaysArtifactsNeverSend`
(`internal/chat/artifacts_contract_test.go`);
`TestChatengine_ArtifactCommentsMarkedSentInStartTx` (`internal/chatengine/ops_mac_test.go`) and
`testArtifactCommentsGoAsTheOwnersTurn` (`WatchtowerChat/Tests/ChatUITests/ChatMacShellModelTests.swift`);
`TestChat05_ConnectorWriteWaitsForApproval`,
`TestChat05_PublishOnlyFromThePublishDir`,
`TestChat05_DeadSessionNeverRunsAnApprovedCall`
(`internal/chat/gate_test.go`);
`TestChat05_ClaudeAIChildNeverTouchesTCCGuardedFolders`
(`internal/chat/sandbox_test.go`; its real-sandbox halves run on macOS only);
`testChat05PublishedLinkCardOnlyOpensOrCopies`
(`WatchtowerDesktop/Tests/Core/ArtifactChat05ScanTests.swift`);
`TestChat05_FallbackActionsOnlyOpenCopyOrFixedTurn`
(`internal/chatengine/parts_test.go`);
`testChat05FallbackAndArtifactActionsOnlyOpenOrCopy`
(`WatchtowerChat/Tests/ChatUITests/ChatUISourceScanTests.swift`, the source scan of
`ChatUI`'s fallback, artifact, published-link and html surfaces and the fallback
action shapes) and `testChat05ComposerOnlyEditsItsBindingAndCallsClosures` (the same scan over
every file under `Composer/` and the platform composer files)

## CHAT-06 — every message part has a fallback

**Locked since:** 2026-11-16 (unified chat, board #1822, owner approval ask #1371)

**Status:** Enforced (Go and Swift guards)

**Observable:** A chat message reaches every client as typed parts
(`text`, `steps`, `sources`, `artifact`, `approval`, `question`, `error`,
`remember_mark`, `knowledge_mark`, `published_link`, `attachment`,
`routing_note`). Every part kind the engine emits has a payload and a
non-empty fallback: a text plus actions that may only open a permitted link
(`open_url`, the CHAT-05 rule: `https://claude.ai/<page>` the turn published),
send one fixed owner text the owner taps (`chat_turn`, from
`FallbackTurnTexts`) or do nothing (`none`). A client that did not list a kind
in `hello.part_kinds` gets the fallback and no payload (D15; the relay path
always sends both, D21), so a kind added later never leaves an older client
with a blank row. Two kinds, `artifact` and `question`, live inside the answer
text: the engine never emits them (D14), every client splits them out of the
`text` part with the one parser in `WatchtowerChatText` (`ChatQuestionParser`,
pinned to its Go twin `chat.ParseQuestionCard` by `question_parse_cases.json`),
and the `text` part's fallback stands in for them. Every kind in
`testdata/parts.json`, the client-derived `artifact` and `question` included,
has a registered `ChatUI` view (`ChatPartRegistry`; a kind it does not know, or
a payload it cannot read, renders `FallbackPartView`: the fallback text and one
button per action). The remember and knowledge marks are not built for a message at or after
the conversation's first Live Slack message (LIVE-01), and a hub record cut that
drops an action drops its approval part with it. The flat message fields
(`text`, `steps`, `attachments`) stay beside `parts` for one release.

**Guard:** `TestCHAT06_EveryPartKindHasFallback`,
`TestParts_FixtureCoversEveryKind` (`internal/chatengine/parts_test.go`, over
`internal/chatengine/testdata/parts.json`);
`TestChat05_FallbackActionsOnlyOpenCopyOrFixedTurn`;
`TestChatengine_UnlistedKindSendsFallbackOnly`;
`TestQuestionParse_SharedCases` (`internal/chat/questions_test.go`) with
`QuestionParseFixtureTests` (`WatchtowerChatText`);
`testChat06EveryFixtureKindIsRegistered`
(`WatchtowerChat/Tests/ChatUITests/ChatPartRegistryTests.swift`, over the same
`parts.json`: every kind, the client-derived ones included, has a registered view
that draws its sample; every emitted kind's fallback is non-empty and
`FallbackPartView` draws one button per action)

## LIVE-01 — Live Slack answers stay out of lasting stores

**Status:** Enforced

**Observable:** A conversation whose turn called the Live Slack connector (Claude's
claude.ai Slack tools, stored as the chat names the step: `claude_ai_Slack:<tool>`, or
Codex's Slack app, stored as `codex_apps:slack.<tool>`) is marked: `chat_conversations.live_slack_since` is the
`chat_messages.id` of that turn's assistant message, set once and never moved. That turn's
answer and every later message of the conversation (even a turn with no Slack step) feed no
store that makes chat text lasting (the owner's prompt of the Live turn precedes the mark and
is the owner's own words, so it stays readable): not ideas (`ListChatTurnsForIdeas`), not memory
(`ListOwnerChatTurns`, `OwnerChatTurnExists`), not the instruction miner or the agent
coach (`ListOwnerChatTurnsSince`), not a target's next step (`ListRecentChatTurns`), not
knowledge (the `chat_artifact` source skips the whole conversation, and Add to Knowledge is
refused with "Built on Live Slack answers, which are not kept"). Turns before the mark stay
readable. In a marked conversation `instructions remember` stores a line only when it
appears verbatim in the owner's own message.

**Mechanism:** the turn's lease holder's store — the Swift turn store on the Mac, or since 2026-11-15 (#1791, ask #1340) the Go turn store `internal/chatstore`, at the same mark points (`markIfSlackStep` when a Slack step starts, `markIfUsed` in finalize) — marks the conversation
when a Slack step starts (`ChatTurnStore.stepStarted`, `LiveSlackMark.markIfSlackStep`: a Live
turn's partial text is saved while it runs and a crash never finalizes) and again in
`finalizeTurn`'s transaction as a backstop (`markIfUsed`); whichever comes first wins. Since the unified chat (T8, D3) the marks are the engine's alone (`internal/chatstore`); the Swift `LiveSlackMark` keeps only the read `isMarked` (the artifact panel's Keep), its former writers removed in the final review. Embedded
chats never carry Slack connectors (main surface only). Go readers apply `db.ChatNotLiveSlack` (`c.live_slack_since IS NULL OR m.id <
c.live_slack_since`); `ChatArtifactQueries.keep` throws `ChatArtifactKeepError.liveSlack`. The iPhone's offline copy of a chat (`chat-copy.sqlite`, the hub's own file) and the hub's feed builder (`chat_list`/`chat_feed`/`chat_page`/`chat_search`) are display copies, like `chat_messages` itself: the feed builder's functions join `displayOnlyReaders`, and the Go store's own new functions are listed there with reasons (`TestLIVE01_ReaderList` unchanged).

**Why locked:** A Live answer is the owner's live Slack data fetched through a third-party
connector; Watchtower's compliance position is that it is shown and never stored or mined.

**Test guards:** `TestLIVE01_MarkedTurnsStayOutOfStores`, `TestLIVE01_LaterTurnsMarked`,
`TestLIVE01_LiveSlackOwnerLineOK`, `TestLIVE01_ReaderList` (`internal/db/live01_test.go`: a
new non-test function in `internal/` that mentions the chat tables must join
`liveCheckedReaders` or `displayOnlyReaders`); `TestLIVE01_KeptArtifactSkipped`
(`internal/kb/source_chat_artifact_test.go`); `LiveSlack01GuardTests`
(`WatchtowerDesktop/Tests/Core/LiveSlack01GuardTests.swift`: the finalize mark for both
providers, `testEveryGoSlackStepNameMarks` over every step name in
`internal/slacklive/testdata/slack_step_names.json` — the names Go's real Claude and Codex
translators give each connector tool, pinned by `TestLIVE01_StepNamesFixture` —, no mark without a Slack step, the first mark kept, keep refused, the panel's
reason, and `testReaderList` over the Swift sources, which is file-level: a Swift file that mentions a chat table must be listed as checked or display-only); since unified chat T8 the turn store's marks are the engine's, guarded by `TestLIVE01_GoStoreStepStartMarksWithoutFinalize`, `TestLIVE01_GoStoreEveryGoSlackStepNameMarks`, `TestLIVE01_GoStoreFinalizeLeavesUnmarkedWithoutSlackStep`, `TestLIVE01_GoStoreFirstMarkIsKept` (`internal/chatstore/live01_test.go`) and keep's refusal by `TestChatengine_ArtifactKeepWritesKnowledgeRow`; `TestInstructionsRemember_LiveSlackRefusesText` (`cmd/instructions_test.go`, the `not_owner_text` refusal).

**Locked since:** 2026-11-14

## Changelog

- 2026-11-17 (unified chat T13, board #1822, owner decision ask #1409): the composer moved into `ChatUI` for every Mac surface and the iPhone (`ChatComposerField`, `ChatComposerBar`, `ChatComposerView`, `QuoteBatchView`, `AttachmentChipsView`, `ComposerPickerList`; the Mac's look comes through `DesignKitChatStyle`'s composer hooks and its dictation through `ChatComposerServices`). **No guard relaxed or renamed.** `ComposerPickerModelTests` moved from `WatchtowerDesktop/Tests/Core` to `WatchtowerChat/Tests/ChatUITests` with its assertions (the picker works on ChatWire's `ChatEntityHit` and `ChatCompose.Mention`; Core's `MentionCandidate` is gone and its four `MentionTokenizerTests` cases moved beside it with the same checks). **CHAT-01** gains `testHostGoneMidSendKeepsDraftQuotesAndChips` and `testLostEchoResendReusesKeyWhileDraftUnchanged`: an unanswered send's `client_key` is reused while the draft, quotes, attachments, mentions and skill are unchanged (final review M1), so a resend after "Couldn't reach Watchtower" is answered with the first turn. **CHAT-05**: the new `ChatUISourceScanTests.testChat05ComposerOnlyEditsItsBindingAndCallsClosures` enumerates `Composer/` and the platform composer files with the same forbidden list (only `ChatComposerView` may call its model's `send()`). `ChatComposerFieldViewTests`, `ChatComposerFieldAttachmentTests`, `QuoteBatchViewTests`, `EmbeddedChatViewTests` and `WorkchatComposerTests` inspect the ChatUI views with their names and assertions unchanged.
- 2026-11-17 (unified chat final review fixes, board #1822): strengthening only, **no guard relaxed or renamed**. **CHAT-05**: `ChatUISourceScanTests.testChat05FallbackAndArtifactActionsOnlyOpenOrCopy` also scans `Platform/iOS/ArtifactViewerParts.swift` and `Parts/SourcesPartView.swift` (same forbidden list, same assertions; both were clean). **LIVE-01**: the dead Swift writers `LiveSlackMark.markIfSlackStep`/`markIfUsed`/`isSlackConnectorStep` are deleted (their guards moved to Go in T8); `LiveSlack01GuardTests` is unchanged and passes, `LiveSlackMark.swift` stays in its `checked` list as the reader of the mark. `ChatConversationQueries.setProject` left Core for the tests' fixture writers (`Tests/Support/ChatFixtureWriters.swift`; the app moves chats through the engine). The relay's `chat_turn` reads its params with the engine's decoder (`chatengine.DecodeTurn`), pinned with the relay op list by `TestChatRelayOps_*` and `RelayChatClientTests.testRelayOpsContract`; see the feature note.

- 2026-11-17 (unified chat T11, board #1822, owner approval ask #1371; spec `docs/superpowers/specs/2026-11-16-unified-chat-design.md` §9.2, feature note `docs/features/unified-chat.md`): final text of the unified-chat amendments, **no guard relaxed or renamed**. **CHAT-01** and **CHAT-03** Observables now name the engine (`chatengine.MaxLive`, `chatengine.IdleTTL`, the composer keeps its text until the echo is `applied`, `client_key`, a turn survives a daemon restart, quit/wipe/Slack disconnect/`sync stop` end the chat before the daemon stops); **CHAT-05** gains one amendment naming ChatUI's single source scan (`ChatUISourceScanTests.testChat05FallbackAndArtifactActionsOnlyOpenOrCopy`, which covers `Feed/ChatMessageRow.swift` and `Parts/QuestionPartView.swift` since T12); **CHAT-06** is unchanged. Guard mapping: every Swift CHAT-01..04 guard the Swift turn path carried has a home in the T8 table below, and every guard named in the four Guard blocks was checked to exist. The engine ops added during the build (`chat_manage` `archive` and `discard`, `chat_warm`, `chat_sessions_retire`, `attach_discard`, the relay `chat_turn` `compose` and `client_key`, `watchtower chat shutdown --socket-timeout`) write no row beyond the engine's own writers and are listed in the feature note. Known v1 limits are recorded there: a same-user process that keeps `chat.sock`'s fd across an exec after the greeting (the `ownerconfirm` threat model), a resent turn after a restart lacking the first send's actions-outcome block and `screen_context`, the quit worst-case bounds, a cancelled quit after a successful wipe keeping daemon starts blocked, and the relay's `unsupported` ops. An account removal that purges data runs in the daemon, so the app has no stop to hook there.
- 2026-11-17 (unified chat T12, board #1822, owner approval ask #1371; spec `docs/superpowers/specs/2026-11-16-unified-chat-design.md` §9.2): the Mac's embedded assistant chats, Workchat and the owner-ask drawer draw through ChatUI (`EmbeddedChatFeedAdapter`, `WorkchatFeedAdapter`, `QuestionPartView`); their engines are unchanged. The app's row, feed, artifact card, steps block, sources row, published-link card and question card are deleted. **CHAT-05**, no guard relaxed (ruling F18): every chat now draws its artifact cards, rows and published-link cards with ChatUI's `ArtifactPartView`, `ChatMessageRow` and `PublishedLinkPartView`, which ChatUI's `testChat05FallbackAndArtifactActionsOnlyOpenOrCopy` scans with the same forbidden list; `ArtifactChat05ScanTests` scans only what is left on the Mac's artifact path — the deleted `ArtifactCardView.swift`, `ChatMessageRow.swift` and `PublishedLinkCardView.swift` left its lists, and it gains the embedded chats' artifact sheet (`EmbeddedArtifactSheet.swift`, ChatUI's viewer) and `DesignKitChatStyle.swift`. A published page's card on a chat whose parts come from flat fields (the embedded chats) is built by ChatWire as Go's `publishedLinkParts` builds it (claude.ai pages only), pinned by `ChatPartsTests.testFlatFieldsBuildPublishedLinksAsGoDoes` and `ChatUIMacRowTests.testPublishedLinkCardOnlyForAClaudeAIPage`. `ChatSelectionQuoteScanTests` reads ChatUI's row, feed and answer text in place of the deleted app files, the same tokens.
- 2026-11-17 (unified chat T10b, board #1822, owner approval ask #1371; spec §7, §9.2): **CHAT-03** amended (see its amendment), no guard relaxed. The quit guard `testChat03QuitClosesChatSessionsBeforeStoppingTheDaemon` keeps its name and assertion; its closure is renamed `closeChatSessions` to `shutdownChat`. Added: `testQuitFallsBackToCLIShutdown`, `testWipeShutsDownChatFirst`, `testSlackDisconnectShutsDownChatFirst`, `testCompactionStepShutsDownChatSessionsFirst`, `DaemonManagerArgvScanTests.testEveryAppSyncStopIsInternal`.
- 2026-11-16 (unified chat T8, board #1822, owner approval ask #1371; spec `docs/superpowers/specs/2026-11-16-unified-chat-design.md` §6.2, §9.2): the Mac's main chat moves onto the engine over `chat.sock` (`SocketChatClient`) and ChatUI's models; the Swift turn writer, its lease, the session pool and the history view model are deleted (D3), and the Mac's chat writes (conversations, projects, artifacts, comments, attachments) are engine operations. **No guard relaxed**: every Swift CHAT guard keeps its assertion in Go or ChatUI (ruling F11; 25 Swift guards named above, mapped below). New Go guards (tests only): `TestChat01_UnsavableOwnerRowSendsNothing`, `TestChat01_FailedSpawnLeavesOwnerMessageAnswered`, `TestChat01_RegenerateAndEditRowsBeforeTheTurnIsSent` (`internal/chatengine/mac_guards_test.go`), the LIVE-01 store guards (`internal/chatstore/live01_test.go`) and PROJ-01's `TestProj01_EntitySearchNeverOffersAProjectTarget` (the `@` picker searches through the engine). `chat_manage` gains `archive` (the Mac's Archive had no engine op). Fix round 1 (review I4/I5): the engine gains `chat_warm` (the Mac's landing makes its chat on the first keystroke and warms its session; it only ever takes a free slot, never evicts, idle TTL as any session), `chat_sessions_retire` (a claude.ai connector switch retires every session; a running turn finishes first and its slot is not counted as freeing), and `chat_manage discard` (deletes a chat only while it has no message and no attachment) — CHAT-03 holds over all three (`TestChat03_AdmitNeverExceedsTheBound` covers a warm request); the list row names its running turn (`turn_id`), so the Mac's Inbox strip keeps a live connector call approvable in any chat. CHAT-05: the artifact panel's writes go through `ChatArtifactWriting` (`ChatArtifactWriter`, `artifact_manage` only); `ArtifactChat05ScanTests` is unchanged and passes. LIVE-01's `testReaderList`: `ChatArtifactQueries.swift` is display-only now (its keep went to the engine), the deleted files left its lists. Merge with T9 (phone): `archive`, `discard`, `chat_warm` and `chat_sessions_retire` are `chat.sock` only — the hub's `chat_manage` refuses `archive` and `discard` (`TestChatManage_RenameSetsUserTitle`) and the phone's relay client answers all four `unsupported` without sending (`RelayChatClientTests.testProjectEditUnsupportedOnPhone`); the Mac's search-hit scroll is ChatUI's one `focusMessageID`/`followFocus` (the Mac's own `scrollTarget` is gone). No guard relaxed.

  | Deleted Swift guard | New home |
  |---|---|
  | `testChat01UserMessageIsPersistedBeforeTheTurnIsSent` | `TestChat01Go_OwnerRowBeforeTurn` + `testChat01DraftStaysUntilApplied` |
  | `testChat01NothingIsSentWhenTheMessageCannotBeSaved` | `TestChat01_UnsavableOwnerRowSendsNothing` + `testRefusedSendRestoresDraft` |
  | `testChat01PartialTextSurvivesStop` | `TestChatstore_StopKeepsPartial` |
  | `testChat01PartialTextSurvivesProcessDeathAndTheNextTurnResumes` | `TestChatstore_ProcessDeathFinalizesPartial` + `TestChatengine_SessionDeathFinalizesLost` (next turn replays on a new process) + `TestChatengine_KilledMidTurnSweepsSessionLost` + `TestChat04_ClaudeArgsNeverResume` |
  | `testSendAfterAStopReplaysTheStoppedReplysSavedText` | `TestChatengine_SendAfterStopReplaysSavedText` |
  | `testChat01RegenerateRowExistsUnderTheNewTurnIDWhenSent` | `TestChat01_RegenerateAndEditRowsBeforeTheTurnIsSent` + `TestChatstore_MatchesSwiftFixture` ("regenerate reuses the owner row…") |
  | `testChat01EditRowsExistUnderTheNewTurnIDWhenSent` | `TestChat01_RegenerateAndEditRowsBeforeTheTurnIsSent` + `TestChatstore_MatchesSwiftFixture` ("edit writes a sibling owner row…") |
  | `testChat01FailedSendKeepsTheOwnerMessageAnswered` | `TestChat01_FailedSpawnLeavesOwnerMessageAnswered` |
  | `testChat01LegacyUnansweredQuestionIsKeptBeforeTheNextTurn` | `TestChatstore_MatchesSwiftFixture` ("a legacy unanswered owner question gets an empty reply first") |
  | `testChat02ToolStepsArePersistedImmediately` | `TestChat02Go_StepPersistedOnStart` |
  | `testChat02WaitingStepIsVisibleUntilItEnds` | `testChat02WaitingStepVisibleUntilEnd` + `TestChatstore_MatchesSwiftFixture` ("a tool_wait with no prior start…") |
  | `testChat03NeverEvictsABusySessionQueuesInstead`, `testChat03PoolNeverRunsMoreThanThreeSessions`, `testChat03BusySessionsAreNeverEvictedTheFourthWaits` | `TestChat03Go_PoolBound` (busy never cut, the 4th waits, the idle one closes first, never more than 3 alive) + `TestChatengine_IdleEvictedForNewTurn` |
  | `testChat03DecisionNeverExceedsTheBound` | `TestChat03_AdmitNeverExceedsTheBound` (the admission decision over every pool shape: 0–3 sessions busy or idle, retiring or not, one or two queued turns, a warm request — never evicts a busy session, never more than 3 processes, launches only into a free slot, blocks only with no idle session to make room, a warm request never evicts) |
  | `testChat03RetiringABusySessionNeverLetsTheQueuedFourthOverlap` | `TestChat03_RetiringSessionNeverOverlapsTheQueuedFourth` (a slow exit holds the queued 4th), `TestChat03_RetireOfBusySessionsNeverCutsOrOverlaps` (a config change on busy sessions: no turn cut, the 4th waits for an exit), `TestChat03_PredecessorAliveHoldsTheReplacement` (a recycled chat's new process waits for its old one) |
  | `testChat03IdleSessionIsClosedByTheNextTickAfterTTL` | `TestChatengine_IdleSessionExpires` |
  | `testChat03CloseAllClosesEverySessionAndKeepsPartialText` | `TestChatengine_ShutdownReapsSessions` + `TestChatengine_DaemonStopLeavesPartialAndSweepReleases` |
  | `testChat03QuitClosesChatSessionsBeforeStoppingTheDaemon` | kept (`QuitCoordinatorTests`, name and assertion unchanged); the closure, renamed `shutdownChat` (T10b), calls `SocketChatClient.shutdown()`, else `watchtower chat shutdown` |
  | `testChat04SessionArgvNeverCarriesContent` | `TestChat04_EngineSessionArgvCarriesNoContent` |
  | `testChat04TurnContentTravelsOnlyOnStdin` | `TestChat04_ListenTurnContentOnlyOnSocket` |
  | `testArtifactCommentsReachTheAssistantOnlyAsTheOwnersMessage` | `TestChatengine_ArtifactCommentsMarkedSentInStartTx` + `testArtifactCommentsGoAsTheOwnersTurn` + `ArtifactChat05ScanTests` (unchanged) |
  | `testSendRefusedWhileHubHoldsLeaseKeepsDraft`, `testConcurrentClaimOneWins` | `TestChatengine_SecondTurnBusy` + `TestLease_ConcurrentClaimOneWins` + `testBusyEchoReturnsTextToComposer` |
  | `testDriverStopsWhenConversationDeleted` | `TestChatengine_DeleteDuringTurnCancels` |
  | LIVE-01 turn-store tests (`testFinalizeMarks…`, `testStepStartMarksWithoutFinalize`, `testEveryGoSlackStepNameMarks`, `testFirstMarkIsKept`, `testKeepRefusedForLiveConversation`) | `TestLIVE01_GoStore*` + `TestChatengine_ArtifactKeepWritesKnowledgeRow`; the panel's two tests stay in `LiveSlack01GuardTests` |
- 2026-11-16 (unified chat T9, board #1822, owner approval ask #1371; spec `docs/superpowers/specs/2026-11-16-unified-chat-design.md` §6.3, §6.4): the iPhone's Chats tab runs on `ChatUI` over `RelayChatClient`. **CHAT-01** (phone half), no guard relaxed: every send, a new chat's first one included, goes through `ChatSendCoordinator` and is kept in `chat_outgoing` from before `chat_new` until its `chat_turn` is applied (a client that `createsConversationOnTurn` sends the chat's first turn as conversation 0); the shared composer keeps the text until then. The relay `chat_turn` now carries `client_key` and `compose` (the hub hands both to the engine), so a turn whose echo is lost and that the outbox took back goes again under the same key (`ChatConnectionError`) and is applied once; one the outbox could not take back waits, "Waiting for your Mac…", with Send held. `ChatSendTests`, `ChatApprovalWiringTests` and `ChatSendRecoveryTests` keep their scenarios and assertions (the new chat kept across a kill with its file, the hub's busy reason, quotes back as quotes, no buttons without the grant, one answer in flight, the settled outcome, the stalled caption) against the shared models; the lost-echo test now also pins the resend under one client key, and its give-up line is the shared composer's. New guard suite `RelayChatClientTests`; Go `TestChatTurn_PassesClientKeyAndCompose`. **CHAT-05**: the phone's artifact sheet is `ChatUI`'s `ArtifactViewer` and `Platform/iOS/SandboxedArtifactWebView`; `PhoneArtifactChat05ScanTests` scans those files in place of the deleted phone copies (same forbidden list), and `PhoneArtifactWebRTCTests` hosts the shared view, assertion unchanged.
- 2026-11-16 (unified chat T7, board #1822, owner approval ask #1371; spec `docs/superpowers/specs/2026-11-16-unified-chat-design.md` §6.1, §9.2, §14): **CHAT-06** gains its Swift guard `testChat06EveryFixtureKindIsRegistered` (`ChatUITests`) and is now Enforced on both sides. **CHAT-05** strengthened, not changed: the shared `ChatUI` package's fallback, artifact, published-link and html surfaces are scanned by `testChat05FallbackAndArtifactActionsOnlyOpenOrCopy` (the same forbidden list as `ArtifactChat05ScanTests`, plus `client.` and `ChatClient`), which also pins the fallback action shapes (only an http(s) `open_url`, a non-empty `chat_turn`, else nothing). `ArtifactChat05ScanTests` and `ChatSelectionQuoteScanTests` read `HTMLPreviewPolicy.swift`, `PublishedLink.swift` (now `WatchtowerChatText`), `MarkdownView.swift` and `ChatSelectionQuote.swift` (now `ChatUI/Platform/macOS`) at their new paths, assertions unchanged. CHAT-01 is held by the new `ChatUI` model tests too (`testChat01DraftStaysUntilApplied`, `testBusyEchoReturnsTextToComposer`, `testRefusedSendRestoresDraft`, `testDroppedEchoResendsWithSameKeyNoDuplicate`), CHAT-02 by `testChat02WaitingStepVisibleUntilEnd`; the Mac's Swift CHAT guards stay until T8 maps them. No guard relaxed. Fix round 1: the artifact action table and the html sandbox rules collapse into one copy each in `WatchtowerChatText` (ruling F20): `ArtifactActions` (moved from Core; the Mac's Gmail button and Slack resolver are parameters, its Core `slackTarget(meta:links:)` an extension) under the new viewer table `ChatArtifactActions` that ChatUI's viewer and the phone's sheet both draw, and the phone's `ArtifactHTMLPolicy` is gone — its page uses `HTMLPreviewPolicy.contentRules(allowFiles: false)`, `allowsNavigation(to:isMainFrame:page:)` and `removeWebRTC`, the rules the Mac's chat artifacts already had (same JSON, same navigation). `ArtifactChat05ScanTests` scans the moved files; `PhoneArtifactChat05ScanTests.testTheHTMLPolicyBlocksEveryRemoteLoad` and `ChatArtifactActionsTests` call the shared types with their assertions unchanged.
- 2026-11-16 (unified chat T10a, board #1822, owner approval ask #1371; spec `docs/superpowers/specs/2026-11-16-unified-chat-design.md` §7, §9.2): **CHAT-03** amended (detached sessions, see its amendment), no guard relaxed. **CHAT-04**: note only, its Observable unchanged — "nothing on argv" holds for the detached session (`ai session --listen`): its argv carries the flags and the socket path only, and the turn's text and attachment paths travel in the `turn` command over the session socket (0600 in a 0700 folder, the peer checked as this team's watchtower CLI by its audit token read at accept, server-greets-first) instead of stdin; protocol v2 is unchanged. New Go guard `TestChat04_ListenTurnContentOnlyOnSocket` (the Go home of `testChat04TurnContentTravelsOnlyOnStdin` for the engine's sessions; the Swift guard stays until T8). The LIVE-01 reader list gains `chatengine/reattach.go:heldTurnOf` (ids only) and LLMUSAGE-01's exec list `chatengine.(*Engine).listenStart`; the LIVE-01 list also gains `chatstore/resend.go:Resend` (the owner's own turn text resent to its session). Off macOS the session socket accepts only this user's process running the session's own executable (`/proc/<pid>/exe`).
- 2026-11-16 (unified chat T3, board #1822, owner approval ask #1371; spec `docs/superpowers/specs/2026-11-16-unified-chat-design.md` §5.3, §9.2): new contract **CHAT-06** (every part kind has a fallback, Go guard `TestCHAT06_EveryPartKindHasFallback`) and a **CHAT-05** amendment (fallback actions only open, copy or send a fixed owner text). The question parser moved from WatchtowerCore to `WatchtowerChatText` with a Go twin and one shared fixture; no guard relaxed.
- 2026-11-16 (unified chat T1, board #1822, owner approval ask #1371; spec `docs/superpowers/specs/2026-11-16-unified-chat-design.md` §9.2): **CHAT-01** and **CHAT-03** amended, no guard relaxed. The hub's chat runner becomes the Go chat engine (`internal/chatengine`): it writes the owner row before the turn (CHAT-01), answers a repeated `client_key` with its first turn (migration 00194), and runs one pool of 3 (`MaxLive`, was 2; CHAT-03). The `TestChatrun_*` guards move to `internal/chatengine` as `TestChatengine_*` with their assertions (the pool bound now 3), `TestFILES01_Chatrun` becomes `TestFILES01_Chatengine`, and the LIVE-01 reader list names the engine's feed and list builders (`chatengine/feed.go`, `chatengine/list.go`) in place of the hub sources'.
- 2026-11-11 (tests without wall clock, board #1730): no Observable changed. The `internal/chat` warm-claude tests run an in-process twin of `testdata/fake_claude.sh` (`fakeCLI`, `fake_claude_test.go`) behind the `ClaudeOptions.start` seam, inside `testing/synctest`: every grace, poll and "nothing happened" check is virtual time, and each test fails if a fake child is still running after its teardown. The process wiring keeps real-process tests that wait on process events only and fail if any stub process outlives the test (one `pgrep` look after teardown): `TestChat03_CloseReapsStubbornChild` (the leader is reaped by `Close`; the grandchild sleeps a day, reports its pid over a FIFO and its exit is awaited by pid (kqueue `NOTE_EXIT`; a pidfd on Linux) — only the group kill can end it; no pid polling), `TestChat03_CloseUnblocksAStuckWrite` (a real full pipe), `TestChat04_ClaudeArgvCarriesNoContent` and `TestClaudeBackend_RespawnReadsPromptPipesAgain` (the prompt and the config read from the inherited pipes, first spawn and respawn) and `TestClaudeBackend_StdinEOFEndsSessionAndSweepsGroup` (the group sweep); the real-sandbox halves of `TestChat05_ClaudeAIChildNeverTouchesTCCGuardedFolders` stay real. Moved to the in-process model: `TestChat03_CloseWhileWaitingForApprovalRejectsAndReaps` now checks that `Close` ended the fake child (the real reaping of a child and its group is `TestChat03_CloseReapsStubbornChild`'s), and `TestChat05_DeadSessionNeverRunsAnApprovedCall` kills the fake child instead of signalling a pid. The stdin write lock is a one-slot channel instead of a `sync.Mutex` (mutual exclusion and lock order unchanged; a zero `claudeProc` needs it made), so a writer queued behind a stuck write is durably blocked.

- 2026-11-05 (LLM transport independence, Task A1; spec approved in ask #514, plan in ask #519): **CHAT-02** strengthened and **CHAT-03** reworded, no guard relaxed. CHAT-02's guards gain the transport contract suite's tool rows on every chat and stream backend (warm claude, codex, runtime B; `internal/transporttest`, `TestTransportSuite` over `testdata/matrix.golden`, where a cell a backend fails today is recorded as its open gap and flips to `pass` with the gap's fix). CHAT-03's "`Session` reaps the `claude` child" becomes "the backend's child process group, any transport" (spec §5); its guards gain the suite's `timeout-kill` and interrupt rows and `TestFakeCLI_GroupReaped`. Spec: `docs/superpowers/specs/2026-11-05-llm-transport-independence-design.md` §4.
- 2026-11-05 (codex parity follow-up, embedded chats on `--events v2`): note only — **no contract wording or guard assertion changed**. The Desktop's embedded chats (target, track, idea, meeting, automation, setup assistants, code questions) now run `ai query --events v2` and, on claude as on codex, get each tool call as a `tool_start`/`tool_end` step (shown live, written to `chat_turn_steps` as it starts and ends for a database chat) and no `reset`: text streamed before a call is kept. Tests: `TestQuery_ChatEventsMakeToolStepsAndUsage` (`internal/ai`), `TestAIQueryV2_ClaudeGetsChatEvents`/`TestAIQueryV2_ClaudeChatEventsThroughTheCLI` (`cmd`), `testToolStepsAndUsageReachTheLiveRowAndTheDatabase` (`WatchtowerDesktop/Tests/Core/EmbeddedChatEngineTests.swift`). Feature note: `docs/features/embedded-chat.md`.
- 2026-11-05 (codex parity, branch `feature/codex-parity`): **CHAT-02** strengthened, no guard relaxed; the Observable's wording is unchanged. Codex main-chat turns (`NewTurnBackend` over `codex.Client` with `EmitToolEvents`) now meet it as the Claude path does: each `mcp_tool_call`/`command_execution` item is one `tool_start`/`tool_end` step, a failed or declined call is a red step with a reason, and a call still open when the stream ends is closed as a red step. New guard `TestTurnBackend_CodexToolCallsBecomeSteps` (`internal/chat/turn_backend_codex_test.go`, codex's JSONL through `codex.Client` and the turn backend); the opt-in live proof against the real codex CLI is `TestCodexLive_ChatToolStepAndUsage` (`internal/codex/live_test.go`, `WATCHTOWER_LIVE_CODEX=1`, never in CI, so not a guard). The existing CHAT-02 guards are unchanged. Feature note: `docs/features/chat-redesign.md`.
- 2026-11-06 (board #969 G4, plan approved ask #519, gap L6): **CHAT-04** kept, no guard relaxed. A codex chat turn's image reaches codex by path only: the checked bytes are copied to a held 0600 temp file passed as `--image=<path>` on that turn's `exec` and removed after it; stdin and argv carry no content (`TestCodexTurn_ImageAttachmentPassedAsImageFlag`). A PDF on codex, and any image or PDF on ollama, is refused before a child starts (`TestCodexTurn_PDFStillRefusedBeforeSpawn`). Web search in the codex chat stays the owner's codex setting (ask #323); the plan's explicit switch waits for the owner.
- 2026-11-06 (board #971 G4 follow-up, owner decision ask #533, gap L5): no contract change, no guard relaxed. The codex chat session searches the web as the Claude session does (cached index, never `live`, which fetches any URL the model names); every other codex run sets web search off explicitly. Guards: `TestCodexTurn_WebSearchFlagMatchesPrompt`, `TestCodexSessionPrompt_HasTheWebSearchRules`, `TestCodexQueryClients_WebSearchOff`, `TestCodexAgentClient_WebSearchOff`, `TestClient_WebSearchOffUnlessSet`, `TestTurnBackend_CodexWebSearchBecomesWebSourceChips`.
- 2026-11-08 (big-branch review, board #1025, owner decision in ask #611, replacing the ask #560 widening): note only — **no CHAT contract or guard changed or relaxed**. `ai query --read-folder` stays as it was (a workbench's own folder only). A sibling flag, `--read-folder-round N`, modelled on `--read-folder-ask N`, runs in the folder diff review round N was taken from: `review_rounds.folder_root` (`db.ReviewRoundByID`; the session's worktree, or for a workbench bound to a repository subfolder that subfolder inside it), symlinks resolved, a directory. Every failure is a usage error (exit 2) naming the flag and the id — not a positive id, no such round, a folder that is gone or not a directory, an unopenable database — and never falls back to the workbench folder; it excludes `--read-folder`, `--read-folder-ask` and `--tools`, and a provider with no file tools is refused as for `--read-folder`. Its only Desktop caller is the Branch review reviewer (`ReviewerSurface`, `ChatRunOptions.readFolderRoundID`). The run itself is unchanged (cwd = the folder, read tools only). Amends the capability rule of spec 2026-10-02 code navigation §9.1; tests `TestAIQueryReadFolderRound_ReadsTheRoundsFolder`, `TestAIQueryReadFolderRound_Refusals`, `TestAIQueryReadFolderRound_WithoutFileToolsIsRefused`.
- 2026-11-05 (board #962, owner decision ask #501): **CHAT-05** extended by owner decision, no guard relaxed. The artifact panel gains **Print…** for `document` and `html` (the macOS print panel; its PDF menu — Save as PDF, Open in Preview, Mail, Messages, network printers — runs only on the owner's choice, like Copy then paste) and **Export as Word…** for `document` (a local `.docx`, like Export…). The page prints from an offscreen web view built by `SandboxedHTMLView.makeWebView` with the same content rules (no network; `testThePrinterRouteLoadsNothingFromTheNetwork`), and a `document` prints as `ArtifactPrint.documentPage`, built from the parsed Markdown with everything escaped and nothing that loads (allow-list test `testNothingInTheDocumentPageLoadsOrRuns`). `ArtifactChat05ScanTests` also scans `ArtifactPrint.swift` and `ArtifactPrinter.swift`; every other scan and guard passes unchanged.

- 2026-11-04 (fix: codex prompt file lifetime, owner approved ask #481): **CHAT-04** Observable amended, no guard relaxed; the "nothing on argv" rule is unchanged. codex re-reads its `model_instructions_file` for every model request of a run, so removing it at codex's first output failed the next request ("failed to load workspace requirements", codex-cli 0.159.2) and every codex-provider call with tools broke. The file now lives until codex exits (`fsutil.HoldTempFile`, a deferred release in `codex.Client.Query`/`QuerySync` and `codex.CodexGenerator.run`); its holder's shared flock keeps `fsutil.SweepStaleTemp` off it. `TestPromptFile_GoneAfterFirstOutput` is replaced by `TestPromptFile_KeptUntilCodexExits` (the fake re-reads the file after its first output; no file left after return); `TestHoldTempFile_SweepSkipsAHeldFile` covers the sweep. Trade-off: a process killed mid-run leaves the 0600 file until the 10-minute sweep. Feature note: `docs/features/files-outside-db.md`.

- 2026-10-26 (Chats panel, spec `docs/superpowers/specs/2026-10-26-chats-panel-design.md`): note only — the tab's name changed (AI Chat → Chats) and `chat_conversations.read_at` was added (migration 00161). No guard changed or relaxed.
- 2026-10-25 (board #604 Stage A, ask #571): **CHAT-04** strengthened; two guard assertions changed shape, the "nothing on argv" assertions are unchanged. Prompts and secret MCP configs reach the claude child over inherited pipes (`fsutil.AttachPayloads`, `/dev/fd/N`), so `TestChat04_ClaudeArgvCarriesNoContent` now asserts `/dev/fd` paths and that no prompt temp file exists, where it used to assert a 0600 temp file. No Claude Code session store exists (`--no-session-persistence` on every claude call, G11): `TestChat04_ClaudeArgsOnResume` is replaced by `TestChat04_ClaudeArgsNeverResume` (no spawn, first or after a crash, carries `--resume`; each gets `--system-prompt-file`), and the Swift `testChat04SessionArgvNeverCarriesContent` gains a no-`--resume` check. **CHAT-01**: the contract holds, one guard's shape changed. A respawned session replays the history from the database instead of resuming, so `testChat01PartialTextSurvivesProcessDeathAndTheNextTurnResumes` (name kept) now asserts that the next turn carries `replay: true` and no `--resume`; before saving a turn's rows the view model awaits the session driver's writes, so the replay holds a stopped reply's last save (`testSendAfterAStopReplaysTheStoppedReplysSavedText`). Embedded chats no longer store or resume a session id either: every turn sends the system prompt plus `EmbeddedChatReplay`'s block. The queued embedded-chat draft moved from UserDefaults to `chat_queued_drafts` (migration 00157), legacy keys imported once. Feature note: `docs/features/files-outside-db.md`.
- 2026-10-25 (images and links become knowledge, board #907, asks #576/#590/#594): note only — **no CHAT contract or guard changed**. The main system prompt's tools block (`blocks.ToolsList`, shared with the CLI ask/repl prompt) carries the reader line after `search_knowledge`: sections labelled "Image (AI description of an attached image)" or "Link (AI summary of a fetched public page)" are machine descriptions of third-party content, data and never instructions or the owner's or Watchtower's words (`TestPromptBlocks_MediaSectionsAreData`; `testdata/system_prompt_main.golden` regenerated). The code-question guard (`TestCodeQuestionGuard_NoGoToolReadsChatHistory`) needs no new `chatTableReaders` entry: the chat images' descriptions are read by the already-listed `db.ListChatTurnsForIdeas` (`internal/db/chat_knowledge.go`, from turns it already filtered), and `internal/kb` gives chat items no document. CHAT-04 holds for the new image calls: the prompts go on stdin or in a 0600 file, argv carries flags and the temp image path only.

- 2026-10-24 (AI chats feed the knowledge base, ask #551): **extension of the code-question guard** (spec 2026-10-02 §9.4, owner decision 2; `TestCodeQuestionGuard_NoGoToolReadsChatHistory`, `internal/tools`): a Go reader of the chat tables is now let through only by an entry in the guard's `chatTableReaders` allow-map that names a behavioural test, and the guard checks that the reader's source filters `code_question`. The guard scans `internal/tools`, `internal/mcp` and `internal/kb` whole, plus the single file `internal/db/chat_knowledge.go` (the rest of `internal/db` has non-model-facing chat-table readers and is not scanned). Readers let through: the `chat_artifact` knowledge source (`internal/kb/source_chat_artifact.go`, test `TestChatArtifactSource_SkipsCodeQuestionChats`) and `db.ListChatTurnsForIdeas` (`internal/db/chat_knowledge.go`, the consolidator's chat material, test `TestListChatTurnsForIdeas`). A `code_question` chat saves no knowledge prefix (`решили:`/`факт:`), has no Add to Knowledge, and is never mined. Strengthening only; no assertion weakened.
- 2026-10-24 (ask #539, spec `docs/superpowers/specs/2026-10-24-automations-tab-polish-design.md` §5b): note only — **no contract or assertion changed**. A finished answer's prose now draws through one native text view per run (`Views/Chat/MarkdownTextRun.swift`, runs from `MarkdownRunBuilder`); streaming replies stay SwiftUI. `ChatSelectionQuoteScanTests` gained the `nativeText` check for the new file. No CHAT guard relaxed.
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
- 2026-10-25 (board #608, approved 2026-10-25, asks #569 and #572): CHAT-02/03 note — the claude.ai tools off reason `policy` and the per-turn provider check; no guard relaxed.
- 2026-11-08 (board #1025 phase 3): strengthening, no guard relaxed. Branch review's reviewer threads (`chat_conversations.context_type = 'review_reviewer'`) quote the folder's code as code questions do, so `db.ListChatTurnsForIdeas` and the `chat_artifact` knowledge source leave them out next to `code_question` (`TestListChatTurnsForIdeas`, `TestChatArtifactSource_SkipsCodeQuestionChats`), and the Desktop saves no knowledge prefix typed there. The surface is draft-only (`ReviewerSurfaceTests`).
- 2026-11-10 (board #1517, tuning chat, spec `docs/superpowers/specs/2026-11-03-tuning-chat-design.md` D63, ask #1164): the code-question guard also requires `analytics_tuning` in both chat-history readers and a third behavioural test (`tuningTest` in `TestCodeQuestionGuard_NoGoToolReadsChatHistory`): `db.ListChatTurnsForIdeas` and the `chat_artifact` knowledge source leave tuning conversations out next to `code_question` (`internal/db/chat_knowledge_test.go::TestListChatTurnsForIdeas_SkipsTuningChats`, `internal/kb/source_chat_artifact_test.go::TestChatArtifactSource_SkipsTuningChats`). No CHAT-01 amendment (the removed-conversation rule of ask #1057 left with D61/D62). Strengthening only, no guard relaxed.
- 2026-11-16 (the chat reads its own history): **extension of the code-question guard**, strengthening only. `internal/tools/chat_history.go` (`get_chat_history`, `list_chat_artifacts`, `get_chat_artifact`) reads the bound conversation only and refuses it when its `context_type` is `code_question`, `spec_review_thread`, `analytics_tuning` or `review_reviewer`; it is a `chatTableReaders` entry with `TestChatHistory_RefusesCodeQuestionChats` (also `review_reviewer`), `TestChatHistory_RefusesSpecReviewThreads` and `TestChatHistory_RefusesTuningChats`. The embedded replay names the reads only on a chat that mounts them (`ToolAccess.readsChatHistory`); a draft-only chat keeps the bare `[N earlier messages omitted]`. No assertion weakened. **LIVE-01**: the reads write no lasting store (they hand a chat its own rows for its next answer, like `ActiveChatPath`), so `boundConversation` is a `displayOnlyReadersAt` entry and `ChatToolCatalog.swift` / `EmbeddedChatReplay.swift` (tool names only) are display-only in `LiveSlack01GuardTests`.
- 2026-11-14 (Slack Live, #1709, board #1764): new contract **LIVE-01**. `chat_conversations.live_slack_since` (migration 00188) marks the first turn that used the Live Slack connector; ideas, memory, the instruction miner, the next step and the knowledge index skip it and every later turn; Add to Knowledge is refused. No existing CHAT guard changed.
- 2026-11-15 (board #1791, owner decision ask #1340; spec `docs/superpowers/specs/2026-11-15-iphone-chat-design.md` §9): amended for the iPhone chat over the relay, no guard relaxed. **CHAT-01**: the writer of a turn's rows is the turn's lease holder's store, Swift or Go (`chat_turn_leases`, migration 00189), same order and `partial` rules, Go guards added. **CHAT-02**: the Go store writes steps at once, new Go guard. **CHAT-03**: a second bounded pool in the daemon (2 processes, reaped on daemon stop), new guards. **CHAT-05**: the phone's artifact sheet only opens or copies, with a source scan. **LIVE-01**: the mechanism gains the Go store at the same mark points; the phone's offline copy and the feed builder are display copies. Hub grant `chat` on by default for linked and new phones (ask #1340), and the explicit-`on` capability rule are in the mobile protocol spec §7.2/§9. Every guard named above was verified by `grep` when written. Feature note: `docs/features/iphone-chat.md`.
