# Watchtower Mobile — Plan 5: BYOK Agent Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the Mac is unreachable, the phone answers chat turns itself — user's own Anthropic API key (BYOK), streaming over `URLSession`, tool use against the local GRDB replica — with explicit per-conversation opt-in, never a silent switch.

**Architecture:** A `MobileAgentBackend` protocol in WatchtowerKit fronts two turn-senders: `RelayAgentBackend` (today's path — `ChatAssembler.send` into the relay zone) and `DirectAPIAgentBackend` (new: local-only send + an agent loop against `api.anthropic.com`). The direct loop synthesizes `ChatChunkPayload`s and feeds them through the existing public `ChatAssembler.ingest` — the frozen cut-at-done/idempotency machinery, chat persistence, and ValueObservation UI all work unchanged for a local answerer. Tools mirror the MCP server v1 contract (`internal/mcp/`) executed as reads over `ReplicaStore` plus two write tools that enqueue through `ActionOutbox` (they land in the pending overlay like any swipe action). Swift has no official Anthropic SDK — raw HTTP/SSE against `POST /v1/messages` is the sanctioned surface (per the claude-api skill: unsupported language → raw HTTP from the curl reference).

**Tech Stack:** Swift 5.10 / iOS 17+, URLSession (`bytes(for:)` SSE), GRDB (existing replica), Security.framework Keychain, Anthropic Messages API (2023-06-01, streaming + tool use).

## Global Constraints

- All Plan 3 wire contracts and Plan 4 design decisions still bind: single relay consumer (RelayFeed); overlay-not-mutation (no VM/tool writes `slice_records` or chat tables directly — everything через ActionOutbox / ChatAssembler); Kit owns relay writes; flag-driven error styling (never "⚠️ " prefix-sniffing).
- MCP v1 contract binds tool behavior verbatim: **missing data → empty result / null, never an error** (`internal/mcp/*.go` is the contract source; read the Go tool registrations before writing the Swift mirror).
- **No subscription token on the phone, ever** (spec LLM Access Policy). BYOK = user's own `sk-ant-…` API key, Keychain-stored (`kSecAttrAccessibleAfterFirstUnlock`), explicit opt-in per conversation. Never switch backends silently.
- Anthropic API wire rules (claude-api skill, 2026-06 surface): default model `claude-sonnet-5` (spec fixes sonnet as the mobile default; configurable), NO `temperature`/`top_p`/`top_k` (400 on sonnet 5), no `budget_tokens`, omit `thinking` (sonnet 5 runs adaptive by default), streaming always (`"stream": true`), `max_tokens` 8192, tool inputs parsed with JSONDecoder never string-matched, parallel tool results returned in ONE user message, `anthropic-version: 2023-06-01` + `x-api-key` headers.
- API key never reaches os.Logger, error messages shown in UI, or the replica DB. Chat text/PII never reaches os.Logger (existing rule).
- Baselines at plan start: Kit `Executed 151 tests`, desktop 964 XCTest + 92 swift-testing, mobile 26, swiftlint strict 0 on Kit and Desktop, sentrux baseline 39.
- English for all code/comments/GitHub text.

## Design Decisions (fixed — deviations need owner approval)

1. **`ChatAssembler.send` grows a route** (`SendRoute` enum: `.relay` default / `.localOnly`), NOT a second entry point — one code path for session/user/placeholder row creation. `.localOnly` skips `transport.save` entirely. This resolves the Plan-4-notes friction point.
2. **Empty-text guard promoted into the Kit**: `send` throws `ChatSendError.emptyText` on trimmed-empty input (Plan 4 ledger item 7). The UI's `canSend` stays as belt-and-suspenders.
3. **DirectAPIAgent synthesizes chunks and calls `assembler.ingest`** — it does NOT write chat tables. Chunk seq starts at 0, increments per flushed text delta, final chunk `done: true` (isError on failure with a human-readable message). Exactly the desktop producer's shape, so the frozen assembly contract needs zero changes.
4. **Tool execution is sequential in-actor**, results returned in one user message per API iteration. Read tools query `ReplicaStore` (fetchAll + in-memory filtering — replica slices are small by design). Write tools call `ActionOutbox.enqueue` and return `{"status": "queued", "note": "will apply when your Mac processes the queue"}`.
5. **API key storage**: `APIKeyStore` (Security.framework wrapper) lives in the APP target; Kit's `DirectAPIAgentBackend` takes `apiKey: @Sendable () -> String?` — Kit stays keychain-free and testable.
6. **Model choice**: `AgentModel` enum in Kit (`sonnet5` = `claude-sonnet-5` default, `opus48` = `claude-opus-4-8`, `haiku45` = `claude-haiku-4-5`), persisted in UserDefaults (not secret), picker in Settings.
7. **Opt-in UX**: the Chat unreachable-banner button becomes live when a key exists; tapping asks confirmation ("Uses your Anthropic API key. The phone's copy has summaries only — no raw Slack messages."); acceptance flags THAT session `direct_mode = 1` (new chat_sessions column) — subsequent sends in that session go direct until the user turns it off (toolbar toggle). No key → button opens Settings.
8. **History for API calls**: completed non-error turns of the session (user + assistant), oldest first, capped at the last 20 messages. Incomplete/error assistant rows are skipped.
9. **ReplicaStore is split FIRST** (extension files `+Chat` / `+PendingActions`) before any new chat path lands (Plan 4 review directive; claws back god-file drift).
10. **`RelayFeed.isDesktopReachable` stays as-is** — Plan 5 adds at most one more caller (ChatThreadViewModel already reads it); the cached-read refactor stays ledgered for packaging.

---

### Task 1: ReplicaStore split into extension files

**Files:**
- Create: `WatchtowerKit/Sources/WatchtowerKit/Replica/ReplicaStore+Chat.swift`
- Create: `WatchtowerKit/Sources/WatchtowerKit/Replica/ReplicaStore+PendingActions.swift`
- Modify: `WatchtowerKit/Sources/WatchtowerKit/Replica/ReplicaStore.swift` (move code OUT; core = pool/migrations/slice/meta/relay-token/heartbeat)

**Interfaces:** unchanged — this is a pure file move. Every public/internal signature stays byte-identical; `private` helpers used across concerns become `fileprivate`→internal only where the move forces it (document each).

- [ ] Move the chat concern (chat_sessions/chat_messages DDL stays in the migration block in core; `ChatSession`, `ChatMessage`, `chatSessions()`, `chatMessages(inSession:)` + from-db overloads, `insertChatTurn`, `applyChatChunk`, `ChatChunkOutcome`, `chatMessageAwaitingFirstChunk`) to `ReplicaStore+Chat.swift`
- [ ] Move the pending-actions concern (`PendingAction`, `pendingActions()` + overloads, `insertPendingAction`, `removePendingAction`, `markPendingFailed`, sweep helpers) to `ReplicaStore+PendingActions.swift`
- [ ] Gates: Kit `swift test` → `Executed 151 tests, 0 failures` (zero test edits — proves pure move); `git diff --stat` shows only the three files; desktop + mobile untouched; swiftlint strict 0
- [ ] Commit: `refactor(kit): split ReplicaStore chat and pending-actions concerns into extension files`

### Task 2: SendRoute + empty-text guard in ChatAssembler

**Files:**
- Modify: `WatchtowerKit/Sources/WatchtowerKit/Relay/ChatAssembler.swift`
- Test: `WatchtowerKit/Tests/WatchtowerKitTests/ChatAssemblerTests.swift`

**Interfaces:**
- Produces: `public enum SendRoute: Sendable { case relay, localOnly }`; `public enum ChatSendError: Error, Equatable { case emptyText }`; `send(text:sessionID:route:)` — new third parameter `route: SendRoute = .relay` (existing call sites compile unchanged).

- [ ] TDD: `testLocalOnlySendSkipsTransport` (spy transport records zero saves; session + user row + placeholder still created); `testLocalOnlySendSurvivesDeadTransport` (throwing transport, `.localOnly` still succeeds — the whole point: offline turn); `testEmptyTextThrows` + `testWhitespaceOnlyTextThrows` (both routes; nothing persisted, no transport call); existing relay-route tests stay green unchanged
- [ ] Implementation: trim check at the top of `send` (throw before any side effect); `if route == .relay { try await transport.save(...) }`; doc comment updates (the transport-first reasoning applies to `.relay` only; `.localOnly` has no wire leg — local insert is the only failure point and throws atomically)
- [ ] Gates: Kit suite (151 + new), lint 0, desktop/mobile untouched
- [ ] Commit: `feat(kit): ChatAssembler local-only send route + empty-text guard`

### Task 3: AnthropicClient — Messages API over URLSession/SSE

**Files:**
- Create: `WatchtowerKit/Sources/WatchtowerKit/Agent/AnthropicClient.swift`
- Create: `WatchtowerKit/Sources/WatchtowerKit/Agent/AnthropicWire.swift` (request/response Codable types)
- Test: `WatchtowerKit/Tests/WatchtowerKitTests/AnthropicClientTests.swift`

**Interfaces:**
- Produces:
  - `public enum AgentModel: String, CaseIterable, Sendable { case sonnet5 = "claude-sonnet-5", opus48 = "claude-opus-4-8", haiku45 = "claude-haiku-4-5" }` (+ `displayName`)
  - Wire types (in `AnthropicWire.swift`, `.sortedKeys` encoding, fixture-pinned): `APIMessage` (role + content blocks: text / tool_use / tool_result), `APITool` (name, description, input_schema as raw JSON object), request struct (model, max_tokens 8192, system, messages, tools, stream: true).
  - `public struct AnthropicClient: Sendable` — `init(apiKey: String, session: URLSession = .shared)`; `func streamMessage(request:) -> AsyncThrowingStream<AnthropicEvent, Error>` where `AnthropicEvent` = `.textDelta(String)` / `.toolUseStarted(id: String, name: String)` / `.toolInputDelta(String)` / `.toolUseFinished` / `.finished(stopReason: String)`.
  - `public enum AnthropicClientError: Error { case http(status: Int, body: String), overloaded, rateLimited(retryAfter: Int?), invalidKey, cancelled }` — 401→invalidKey, 429→rateLimited, 529→overloaded; error bodies NEVER include the key.
- SSE parsing: `event:`/`data:` line pairs; handle `message_start`, `content_block_start` (text vs tool_use — capture id/name), `content_block_delta` (`text_delta` → textDelta; `input_json_delta.partial_json` → toolInputDelta), `content_block_stop`, `message_delta` (stop_reason), `message_stop`, `ping` (ignore), `error` (throw). Accumulation of tool input JSON happens in the CALLER (Task 5) — the client stays a dumb event mapper.

- [ ] TDD with a `URLProtocol` stub (register on an ephemeral `URLSessionConfiguration`): `testRequestBodyMatchesFrozenFixture` (byte-literal JSON fixture: model/max_tokens/stream/system/messages/tools, sortedKeys — the BYOK wire format freeze); `testHeadersCarryKeyAndVersion` (`x-api-key`, `anthropic-version: 2023-06-01`, `content-type`); `testStreamsTextDeltas` (canned SSE body → ordered textDelta events + finished(end_turn)); `testStreamsToolUseWithInputDeltas` (tool_use block start + 2 partial_json deltas + stop → toolUseStarted/toolInputDelta×2/toolUseFinished + finished(tool_use)); `testHTTPErrorsMapToTypedCases` (401/429+retry-after/529/500 bodies); `test429BodyNeverContainsKey`
- [ ] Implementation: `URLRequest` build + `session.bytes(for:)` + `AsyncLineSequence` SSE state machine; no retries in the client (the agent loop decides)
- [ ] Gates: Kit suite green, lint 0
- [ ] Commit: `feat(kit): AnthropicClient — Messages API streaming over URLSession SSE`

### Task 4: ReplicaToolbox — MCP v1 mirror over the replica

**Files:**
- Create: `WatchtowerKit/Sources/WatchtowerKit/Agent/ReplicaToolbox.swift`
- Test: `WatchtowerKit/Tests/WatchtowerKitTests/ReplicaToolboxTests.swift`

**Interfaces:**
- Consumes: `ReplicaStore.fetchAll(_:kind:sort:)` (Briefing/InboxItem/Target/Track/Digest/DigestTopic/CalendarEvent/PeopleCard ↔ SliceKind cases), `ActionOutbox.enqueue(kind:entityRecordName:params:)` + `ActionOutbox.snoozeParams(until:)`.
- Produces: `public struct ReplicaToolbox: Sendable` — `init(store: ReplicaStore, outbox: ActionOutbox, now: @Sendable () -> Date = Date.init)`; `var tools: [APITool]` (the 12 definitions); `func execute(name: String, inputJSON: Data) async -> String` (returns JSON string; NEVER throws — errors become `{"error": "..."}` strings for the model, matching tool_result is_error semantics handled by the caller).
- The 12 tools — names, filters, and semantics copied from `internal/mcp/targets.go`, `digests.go`, `people.go` (READ THE GO FILES; they are the contract):
  - `list_targets` (status/priority/level/ownership filters), `get_target` (by id)
  - `get_today_briefing` (null if absent — literal JSON `null`), `list_digests` (kind filter, most recent first, limit), `get_digest` (by id)
  - `list_tracks` (active default, priority/ownership filters), `get_track` (by id)
  - `list_people`, `get_person` (by Slack user id or name)
  - `list_upcoming_events` (next N hours, default 48 — compute against injected `now`, local tz)
  - `create_task` (text) → `outbox.enqueue(.taskCreate, entityRecordName: nil, params: ["text": …])`
  - `snooze_item` (entity_type target|inbox_item, id, until ISO8601) → `.targetSnooze`/`.inboxSnooze` with the Plan-4 recordName convention (`target-<id>` / `inbox_item-<id>`); NOTE the desktop granularity traps documented at `SnoozeOption.targetCases` — the tool description must tell the model target snoozes are day-granularity
- MCP contract rule pinned in tests: unknown id → `{}`-empty/`null` result, never an error; empty replica → empty arrays.

- [ ] TDD over a fixture ReplicaStore (seed slice rows via the test helpers already used in `ReplicaTests`): per-tool happy path + empty-replica + unknown-id; filter parity spot-checks against the Go behavior (e.g. list_targets status filter, digests ordering); write tools assert a pending_actions row + relay record with correct kind/params and the queued JSON reply; `list_upcoming_events` window test with frozen `now` (respect the project's near-midnight discipline: inject, never wall-clock)
- [ ] Implementation: schema literals as `[String: Any]`-free Codable JSON (raw `JSONValue` reuse), execution via fetchAll + filter/map to compact JSON dictionaries (id, text/title, status, dates — mirror the Go field selection, don't dump whole rows)
- [ ] Gates: Kit suite green, lint 0
- [ ] Commit: `feat(kit): ReplicaToolbox — MCP v1 tool mirror over the replica`

### Task 5: DirectAPIAgent + MobileAgentBackend protocol

**Files:**
- Create: `WatchtowerKit/Sources/WatchtowerKit/Agent/MobileAgentBackend.swift` (protocol + RelayAgentBackend)
- Create: `WatchtowerKit/Sources/WatchtowerKit/Agent/DirectAPIAgent.swift`
- Create: `WatchtowerKit/Sources/WatchtowerKit/Agent/MobileSystemPrompt.swift`
- Test: `WatchtowerKit/Tests/WatchtowerKitTests/DirectAPIAgentTests.swift`

**Interfaces:**
- Consumes: Task 2 `send(text:sessionID:route:)`, Task 3 `AnthropicClient`/`AnthropicEvent`/`AgentModel`, Task 4 `ReplicaToolbox`, `ChatAssembler.ingest`, `ReplicaStore.chatMessages(inSession:)`.
- Produces:
  - `public protocol MobileAgentBackend: Sendable { func sendTurn(text: String, sessionID: String?) async throws -> (sessionID: String, messageID: String) }`
  - `public struct RelayAgentBackend: MobileAgentBackend` — thin: `assembler.send(text:sessionID:route:.relay)`.
  - `public actor DirectAPIAgent: MobileAgentBackend` — `init(assembler:store:toolbox:apiKey: @Sendable () -> String?, model: @Sendable () -> AgentModel, clientFactory: …)` (client factory injectable for tests). `sendTurn` = `assembler.send(route:.localOnly)` → detached answer task (coalesced per messageID). Answer loop: build history (decision 8) + system prompt + tools → stream; text deltas buffered and flushed as chunks through `assembler.ingest` (seq monotonic, flush every ≥250 ms of accumulated text — same cadence idea as the desktop's chunkInterval); on `stop_reason == "tool_use"` accumulate tool input JSON, execute via toolbox, append assistant blocks + tool_result user message, next API call (max 8 iterations → then a final no-tools call); on completion ingest `done: true`; on ANY failure ingest a final `done: true, isError: true` chunk with a readable message (`invalidKey` → "API key rejected — check Settings"; `rateLimited`/`overloaded` → "Anthropic API is busy — try again"; transport-level → localizedDescription). The error path must NEVER leave the placeholder row incomplete forever.
  - `MobileSystemPrompt.build()` — static adapted prompt: read `WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift` `buildSystemPrompt` for role/tone, then write the Kit version: role (personal Slack/work assistant), replica-slice schema summary (targets, inbox, digests, tracks, people, calendar — summaries only), the honest limitation verbatim requirement: it must state the phone has NO raw Slack messages and that quote-level questions need the desktop, and that write actions queue until the Mac processes them.
- `missingKey` precondition: `sendTurn` throws `DirectAPIAgentError.missingKey` BEFORE creating any rows if `apiKey()` is nil/empty (UI should prevent this, but the Kit guards).

- [ ] TDD with a scripted fake client factory (no network): `testMissingKeyThrowsBeforeAnyRows`; `testHappyPathStreamsChunksIntoThread` (2 text flushes + done → thread text matches, is_complete, not error); `testToolLoopExecutesAndContinues` (scripted: tool_use round with split input_json deltas → toolbox called with assembled JSON → second call carries tool_result → final text; assert the request messages of call 2 via the recording factory); `testWriteToolLandsPendingAction` (create_task through the loop → pending_actions row exists); `testAPIErrorProducesErrorDoneChunk` (thread completes with isError true, message key-free); `testHistoryCapAndSkipsIncomplete` (21 completed turns + 1 incomplete → request carries 20, no incomplete); `testConcurrentSendTurnCoalescesAnswer` (reentrancy: second sendTurn for same session while answering doesn't interleave chunk seqs)
- [ ] Implementation per above; PublicAPISurfaceTests additions (protocol + both backends constructible with plain import)
- [ ] Gates: Kit suite green, lint 0, `make mobile-build` still green
- [ ] Commit: `feat(kit): DirectAPIAgent — BYOK answer loop behind MobileAgentBackend`

### Task 6: APIKeyStore + Settings UI (key entry, model picker)

**Files:**
- Create: `WatchtowerMobile/Sources/App/APIKeyStore.swift`
- Modify: `WatchtowerMobile/Sources/Features/SettingsView.swift`
- Modify: `WatchtowerMobile/Sources/App/AppEnvironment.swift` (construct DirectAPIAgent + backends, expose to VMs)
- Test: `WatchtowerMobile/Tests/AgentSettingsTests.swift`

**Interfaces:**
- Produces: `struct APIKeyStore` — `func read() -> String?`, `func save(_ key: String) throws`, `func remove() throws`; Keychain generic-password item, service `"watchtower.mobile.anthropic-key"`, `kSecAttrAccessibleAfterFirstUnlock`; in DEBUG/simulator tests back with an in-memory fallback ONLY if SecItem fails with `errSecMissingEntitlement` (document; simulator Keychain normally works). `AppEnvironment` gains `let directAgent: DirectAPIAgent`, `let relayBackend: RelayAgentBackend`, `var agentModel: AgentModel` (UserDefaults-persisted), `var hasAPIKey: Bool` (observable, refreshed on save/remove).
- Settings section "Offline agent": SecureField for the key (masked, save on commit, "Remove key" button, never render the stored value back — placeholder "sk-ant-… (saved)" state), model Picker over `AgentModel.allCases` (labels: "Sonnet (recommended)", "Opus (most capable)", "Haiku (fastest)"), footer text: uses YOUR Anthropic API key only when the Mac is unreachable and only after you confirm; key stays in the device Keychain.

- [ ] TDD: key round-trip save/read/remove; hasAPIKey observable flips; model persists across AppEnvironment relaunch (UserDefaults); saved key never appears in any `String(describing:)` of environment state (paranoia pin)
- [ ] Wire into AppEnvironment (`apiKey: { APIKeyStore().read() }`, `model: { self.agentModel }`) — note AppEnvironment is @MainActor: capture via Sendable closures reading UserDefaults/Keychain directly, not self
- [ ] Gates: `make mobile-test` (26 + new), `make mobile-build`, boot-check (`make mobile-run` — Settings renders the new section), lint 0 on Kit/desktop (untouched)
- [ ] Commit: `feat(mobile): API key keychain store + offline-agent settings`

### Task 7: Chat opt-in UX — live fallback path

**Files:**
- Modify: `WatchtowerKit/Sources/WatchtowerKit/Replica/ReplicaStore+Chat.swift` (+ `direct_mode` column via new migration statement; `setDirectMode(sessionID:enabled:)`, `ChatSession.directMode`)
- Modify: `WatchtowerMobile/Sources/Features/ChatView.swift` (banner button, confirm dialog, toolbar state, VM routing)
- Test: `WatchtowerKit/Tests/WatchtowerKitTests/ChatAssemblerTests.swift` (store bits), `WatchtowerMobile/Tests/ChatWiringTests.swift`

**Interfaces:**
- Consumes: Task 5 backends via AppEnvironment, Task 6 `hasAPIKey`.
- Produces: ChatThreadViewModel routes `send()` through `session.directMode ? directAgent : relayBackend` (`MobileAgentBackend` existentials); banner button states: no key → "Set up offline agent…" (opens Settings); key + not direct → "Answer directly" → confirmationDialog (copy from decision 7: uses your API key; summaries only, no raw Slack) → `setDirectMode(true)` and re-send is NOT automatic (user re-taps send; the draft is still in the compose field per the send-throw contract — document); direct ON → toolbar chip "Direct API" with "Back to Mac relay" action → `setDirectMode(false)`.
- New sessions started while a key exists and the desktop is unreachable ask once BEFORE the first send (same dialog); declining sends via relay as today.

- [ ] TDD: store — `direct_mode` round-trip + defaults 0 for existing rows (migration test); VM — routing test with two recording fake backends (direct flag → direct backend called, relay untouched; and vice versa); banner state matrix (no-key/key-not-direct/direct) as pure state-function tests (TimelineView discipline from Task 7 of Plan 4 stays); dialog acceptance flips the flag (env-level)
- [ ] Implementation; keep flag-driven error styling untouched (direct-path errors arrive as isError chunks — same rendering)
- [ ] Gates: mobile suite green (+ new), Kit suite green (+ store tests), boot-check with the demo exchange (relay path visually unchanged), lint 0
- [ ] Commit: `feat(mobile): per-conversation direct-API opt-in — live offline agent`

### Task 8: Full-loop offline tests + docs + guide

**Files:**
- Create: `WatchtowerKit/Tests/WatchtowerKitTests/DirectLoopTests.swift`
- Modify: `docs/app-guide.md` (mobile offline agent paragraph), `docs/superpowers/plans/2026-07-07-mobile-app-plan-5-notes.md` → append "shipped" deltas for the packaging plan
- Test: the new file IS the deliverable

**Interfaces:** consumes everything; no new surface.

- [ ] `DirectLoopTests` — the BYOK analog of Plan 4's FullLoopTests, all over ONE ReplicaStore + InMemoryCloudTransport + URLProtocol-scripted API: (1) offline turn end-to-end: seeded replica → `directAgent.sendTurn` → scripted SSE with a `list_targets` tool round → thread completes with text derived from replica data (assert the tool result JSON actually carried the seeded target); (2) write-tool loop: scripted `create_task` call → pending overlay row + relay record ready for the Mac; (3) error turn: scripted 401 → thread completes isError with the Settings hint; (4) relay-path regression pin: `RelayAgentBackend.sendTurn` still produces the exact Plan-4 wire records (fixture unchanged)
- [ ] Docs: app-guide mobile section (how to set the key, when the offer appears, what the offline agent can/can't see); notes file updated
- [ ] Gates: FULL matrix — Kit suite, desktop 964+92 (untouched), mobile suite, `make mobile-build` + boot-check, swiftlint strict 0 both, `sentrux gate .` (expect drift from new files → baseline bump is the established pre-PR flow, controller-owned)
- [ ] Commit: `test(kit): offline agent full-loop tests; docs for the BYOK fallback`

---

## Self-review notes

- Spec Section 3 coverage: protocol+two backends (T5), URLSession+SSE BYOK (T3), Keychain (T6), tool mirror incl. write tools→ActionRequest (T4), adapted system prompt with the honesty clause (T5), default sonnet configurable (T3/T6), explicit opt-in + 45s/heartbeat offer (T7), spec Security bullets (Keychain accessibility T6, closed kind enum untouched). Notifications remain packaging-plan scope (owner decision, Plan 4).
- Plan-5-notes coverage: friction fix (T2), ReplicaStore split (T1), empty-text promotion (T2), isDesktopReachable left alone (decision 10), packaging items untouched.
- Type consistency: `send(text:sessionID:route:)` used in T5/T7 matches T2; `APITool` defined T3 consumed T4/T5; `AgentModel` T3 consumed T5/T6.
