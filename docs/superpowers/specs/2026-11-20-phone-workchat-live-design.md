# Phone Workchat: the live line, the turn's steps, live agents — pushed on change

Board: #2112. Decisions: see the Decisions section.

## Decisions

| # | Decision | Source |
|---|---|---|
| D1 | The phone's Workchat gets the Mac's live line above the composer: symbol, current step, timer | conversation 2026-11-20 ("не хватает строки того что делается в чате на мобиле. Как в веркчате") |
| D2 | A tap on the line opens the current turn's steps | ask #1668 |
| D3 | The agents sheet (👥) shows live data: what each working agent does now and for how long | ask #1668 |
| D4 | No timer-driven refresh: the phone gets an update when the transcript changes, over the socket it already has | ask #1668 ("по вебсокету без крона а по тому как прилетают апдейты") |
| D5 | Battery is the hard constraint: no new phone-side timers, wakes or background work | ask #1668 ("очень важно чтоб не садило батарею") |
| D6 | FEED-05 widens to carry one-line tool summaries (the live block), secrets redacted, under the same watch, lifetime and memory-only rules | ask #1675 (spec approved with FEED-05 focus point; rounds #1671, #1673) |
| C1 | The live projection (`SessionFeedLive` + `WorkchatLivePresentation` + `WorkchatActivityPresenter`) moves to `WatchtowerChatText` and is the one source for both apps | author's call: one wording, one set of tests, no Mac/phone drift |
| C2 | The hub reads the transcript on a file-system event (fsnotify), coalesced; the 3 s tick stays only as the fallback when a watch cannot be set | author's call (D4) |
| C3 | One publish per chat per second at most while events keep coming, trailing edge guaranteed | author's call (D5 + relay op budget) |
| C4 | The phone's staleness comes from the tower's freshness (`ReplicaFreshness`) plus a hub read that failed or hung (`live_error`), not from `observed_at` age | author's call: with push, an unchanged snapshot is not an old one; a stuck read is reported by the hub (§2) |
| C5 | Stop and quick reply stay where they are (not in the line); no typing indicator in the feed | ask #1668 (not picked) |
| C6 | The Mac's Workchat also refreshes on a file event instead of its 3 s poll (§8) | review round 1 of ask #1671: the owner asked for responsiveness "в целом" |
| C7 | The live model and its presentation move to `WatchtowerChatText`; the Kit's `WatchtowerKit` target (not `WatchtowerSync`) depends on it | review round 1 of ask #1671 (architecture fixed in the spec) |
| C8 | Summaries pass the shared secret redaction (today's `internal/watchman/redact.go`, moved to `internal/secretredact`) before they enter the payload | review round 1 of ask #1671 |
| C9 | "Loading activity…" shows only while no record from a live-capable hub has arrived since the chat opened | review round 1 of ask #1671 |

## Intent

On the Mac, Workchat shows what the agent is doing right now (`Running tests · go test ./internal/sessionfeed · 0:12`),
the turn's steps on a click and what every subagent is busy with. On the phone the same chat shows only the dialog and
a general state caption ("Working"), so while the agent runs a long step the phone looks frozen. The owner wants the
same line on the phone, the steps and live agents behind it, and the updates arriving as they happen — without
draining the battery.

## Goals

1. The phone's Workchat shows the live line while a turn runs: the step's symbol, its one-line summary and a ticking
   timer; "Working…" with the turn's timer between tools; nothing when no turn runs.
2. A tap on the line opens the turn's steps (the Mac's "This turn · N steps" slot, 6 rows tall, scrolls past that);
   a second tap closes it.
3. The agents sheet's Working rows show the agent's current step and its timer; Done stays as today.
4. A transcript change on the Mac reaches the phone's open chat in about a second, not on a 3 s tick.
5. The phone does no more work than today while the chat is open and none at all when it is not.
6. The Mac's Workchat refreshes on the same file events instead of its 3 s poll (C6).

## Non-goals

- No Stop or reply inside the line, no "agent is typing" bubble (C5).
- No live data outside an open, requested chat: no background publishing, no push notification for steps.
- No token streaming of the agent's text: entries still arrive whole, as the transcript writes them.

## Anti-goals

- A phone timer that polls, a background refresh, or a socket kept open after the app leaves the foreground.
- A second wording of the line on the phone: every string comes from the shared presentation.

## Approaches

1. **Event-driven hub read + live block in the existing slice (chosen).** The hub watches the transcript files of the
   watched chats; a change reads the feed and the live snapshot, the payload changes, the existing `OnChange` nudge
   publishes it over the live link's socket, the phone applies the inline record. The phone already receives records
   over the socket while in the foreground (live link R3), so it gains nothing to run.
2. **Keep the 3 s tick, add the live block.** Simplest, but every step change waits up to 3 s plus the hop, and the hub
   reads every watched transcript every 3 s whether it changed or not — the owner asked for event-driven (D4).
3. **Ephemeral frames over the relay socket** (no record, no zone write). Lowest latency, but the live link left
   ephemeral frames out of scope and the relay has no such frame today; a relay change for this alone is not worth it.

## Design

### 1. The live block in the `session_chat` payload (Go hub, Kit)

- Wire key: the payload already has a `live` bool (the session is live), so the block travels as `activity_live`;
  "the live block" / `live` below means that key (plan, Global Constraints).
- `SessionChatSource` reads `sessionfeed.LiveOf` for the watched conversation (or the subagent's sidechain) in the same
  pass as the feed and stores it as `live` beside `entries` — the shape `workbench session-feed --live` prints today
  (`observed_at`, `turn_at`, `turn_active`, `current`, `latest`, `agents`, `agents_state`, `agents_more`, `steps`,
  `steps_more`).
- Every `summary` (steps, current, latest, agents' actions) and every agent description passes
  `secretredact.Text` before it is cut (C8): private keys, Slack/GitHub/OpenAI/AWS tokens, JWTs, `…key=`/`…token=`/
  `…secret=`/`…password=` values, `Bearer <token>` and `user:pass@` in URLs become `[secret]`. The watchman's twin
  (`internal/watchman/redact.go`) moves into that package and keeps its tests; watchman calls the shared one.
- Bounds on the phone payload: `summary` cut to 200 characters, at most 40 steps (as today) and 32 agents (as today).
  The live block is counted inside the existing 600 000-byte budget; it is reserved first and the entries are cut
  around it (the block is at most ~25 KB).
- Every payload from a new hub carries `live_version: 1`. A finished session (not live) carries no `live`; a failed or
  hung live read (the existing 30 s read timeout) keeps the last `live` with the error in `live_error` (one line), so
  the phone shows "Activity unavailable" + Retry while the dialog still updates — a stuck read never looks current.
- The Kit's `SessionChat` gains an optional `live: SessionFeedLive?` and `liveError: String?`. An old phone ignores the
  keys (Decodable skips them); a new phone with an old hub sees `live == nil` and draws today's screen.

### 2. Reading on change, not on a tick (Go hub)

- Per watched chat the source keeps an fsnotify watch on **files only**: the files `sessionfeed.SessionConversations`
  resolves (the conversation `.jsonl` or Codex rollout) and the `.jsonl` of each subagent the last live snapshot lists
  as running (≤ 32). No directory is watched: on macOS fsnotify's kqueue backend opens a descriptor for every file in
  a watched directory, and a Claude projects directory holds hundreds. A new subagent shows up in the main
  conversation first (its Agent call), so the read that follows adds its file; a file not created yet is retried on
  the next read; a conversation file that does not exist yet (a session just started) is stat-checked on the `Wake`
  loop until it appears, then watched and read. macOS gets kqueue, Linux inotify — the hub runs on both.
- A new conversation after `/clear` changes the session's agent-session rows in the database (the existing
  `terminal_session_agent_sessions` triggers); the source's existing `Wake` loop compares the resolved conversation
  list (a database query and a stat, no transcript read) and re-arms the watch when it changed.
- An event marks the chat dirty; a dirty chat is read 250 ms after the last event (trailing debounce), and at most once
  per second while events keep coming (C3). A read whose payload equals the stored one publishes nothing (as today).
- Re-resolve on `Remove`/`Rename` of a watched file and on a changed conversation list: the watch set follows the conversation.
- The watch's other moments stay as they are: one read when the watch opens, one when the session stops being live
  (the liveness change already reaches the source on its `Wake` loop, which reads no file), drop on expiry or unlink.
- Fallback: if a watcher cannot be added (descriptor limit, missing directory), that chat goes back to the 3 s tick,
  logged once per chat. Nothing else polls.
- The watchers exist only while a phone watches the chat (≤ 5 min after its last request) — at most a handful.

### 3. Getting it to the phone (unchanged path)

- A stored payload that differs calls `OnChange` → the publisher's fast lane → a save over the open relay socket →
  `ZoneChanged` with the inline record → the phone applies it (live link R1–R3). No new transport.
- Coalescing (C3) keeps a busy turn to ≤ 1 save per second per chat, inside the relay's 50 ops/s per phone.

### 4. The phone's live line

- `WorkchatView` draws `WorkchatLiveLineView` between the feed and the composer, from
  `WorkchatLivePresentation.row(…)` (shared, C1) fed with the chat's `live`, the session's working state and
  `stateAt`. Same parts as the Mac: symbol (pulse unless Reduce Motion), text one line with a middle cut, timer
  `m:ss` on the right in monospaced digits, chevron when the steps slot exists.
- The phone has no 👥 inside the line: the agents button stays in the toolbar (#2065), now fed with the live count.
- Timer: a `TimelineView(.periodic(by: 1))` inside the line only — it redraws one `Text` while the screen is visible
  and stops with it; the timer counts from the step's `started_at`, clamped at 0:00 for clock skew.
- Staleness (C4): while `ReplicaFreshness` is nil the snapshot counts as current (the presentation is given
  `observedAt = now`); when the tower is stale/offline it is given the heartbeat's time, so the line shows the
  presentation's own stale wording ("Activity out of date · 42s ago") in the warning tone with Retry, without timer or
  pulse — the freshness line under the header says why. Retry sends `session_chat_request` at once.
- The line hides (presentation `activityHidden`) while a permission card or an inline ask stands above the composer,
  as on the Mac.
- Which state shows (C9), decided by the phone model from the chat record and the session's working state:

  | Record since the chat opened | `live_version` | `live` | `live_error` | Session working | Line |
  |---|---|---|---|---|---|
  | none yet | — | — | — | yes | "Loading activity…" with the state timer (L4) |
  | arrived | absent (old hub) | — | — | any | no line — today's screen |
  | arrived | 1 | set | — | yes | the presentation's working row (L1, L3) |
  | arrived | 1 | any | set | yes | "Activity unavailable" + Retry (L5) |
  | arrived | 1 | nil | — | yes | "Working…" with the state timer (hub saw no turn yet) |
  | any | any | any | any | no | no line (L10) |

  Loading cannot stick: the first record after the open request ends it either way, and a request the tower never
  answers turns `ReplicaFreshness` stale → L6.
- No turn running: no line and no reserved height (the phone's composer sits on the feed; the Mac's reserved row is a
  desktop layout rule).

### 5. The turn's steps

- A tap on the line (or VoiceOver's activate, hint from `stepsToggleHint`) toggles the steps slot above the line:
  `stepsSlot(…)` rows — symbol, summary, duration or running timer — 6 rows tall from the moment it opens, scrolls past
  that; the line then reads "This turn · N steps" with the turn's timer (shared presentation).
- Closed by default on the phone (screen height), the owner's toggle kept per session in memory while the app runs.
  It closes by itself at turn end, Stop, a permission card or a new conversation (as on the Mac).

### 6. Live agents in the sheet

- `WorkchatAgents` takes the chat's `live.agents` beside the markers: a Working row becomes type · description, and
  under it the agent's current step and a timer (`AgentRow.subtitle`/`elapsed` of the shared presentation). Without
  `live` (old hub, unavailable) the row stays "Running" as today.
- The toolbar badge counts working agents from `live` when present (an agent finished in `live` but still "running"
  in the markers counts as done), else from the markers as today.

### 7. One projection for both apps (C1)

- `SessionFeedLive`, `SessionLiveAction`, `SessionLiveAgent`, the subagent ref they use, `WorkchatActivityPresenter`
  and `WorkchatLivePresentation` move from `WatchtowerCore` to `WatchtowerChatText` (Foundation only, already linked
  by both apps), `package` → `public`. The Mac's behaviour and its tests stay as they are (moved with the code).
- The Kit's `SessionChat.live` decodes into the moved `SessionFeedLive` (C7): the Kit's `WatchtowerKit` target gains
  the `WatchtowerChatText` dependency (Foundation + swift-markdown, no UI); `WatchtowerSync` stays without it. The
  phone already links `WatchtowerChatText`; the Mac already links it from `WatchtowerCore`.

### 8. The Mac's Workchat on events too (C6)

- `workbench session-feed --json` (and `--live`) prints the resolved transcript paths it read (`paths`: the
  conversation files and each subagent's `.jsonl` under `subagents/`). The Desktop's Workchat store opens one
  `DispatchSource.makeFileSystemObjectSource` (`.write`, `.extend`, `.rename`, `.delete`) **per file** — a vnode
  source on a directory reports only entries added or removed, never writes into a file — and one on the conversation
  directory and on `subagents/` for new files; a new file gets its own source on the next read. Per-file sources are
  kept for the conversation files and the subagents the live snapshot lists as running, at most 32; a finished agent's
  source is closed. Debounced 250 ms, at most one refresh per second while events keep coming — the hub's bounds.
- The end of a session is a state change, not a file event: the Desktop already observes `terminal_sessions` (the
  session's state row); its change triggers one refresh at once, so the pane sees the end no later than today. No
  liveness timer.
- The 3 s timer stays only as the fallback for a session whose sources cannot be opened (descriptor limit, missing
  path), as on the hub.
- The watch exists only while the Workchat pane is on screen (as the poll today); rename/delete re-resolves the paths.

### 9. Battery (D5)

| Where | Today | After |
|---|---|---|
| Phone, chat open | socket open (foreground), `session_chat_request` every 60 s | same + one `Text` redraw per second inside the line, only while visible |
| Phone, chat closed / app in background | nothing for the chat | nothing |
| Phone radio | a record per changed 3 s read | a record per change, ≤ 1/s per chat — the same records, sooner; fewer when nothing changes |
| Mac/hub | reads every watched live transcript every 3 s | reads on change only, kqueue/inotify wakes |
| Mac Workchat pane | CLI read every 3 s while on screen | CLI read on change or on the session's state change; no tick |

No new background modes, push types or wakes. Measured in the plan: phone CPU and wakeups with the chat open for 10
minutes of a busy turn (Instruments energy log), before/after.

## FEED-05 change (D6 — approved, ask #1675)

Today FEED-05 says the record "holds FEED-02 entries only (no tool call, tool output, thinking or hook text)". The live
block carries the **one-line summary of tool calls** (a command line, a file path, a search pattern — what the Mac's
line shows) and agent types/descriptions. It still carries no tool output, no thinking, no hook text, no file content.

Proposed text: "…It holds FEED-02 entries and, while the session is live, the live block: the current turn's tool
steps as one-line summaries with secrets redacted (≤ 200 characters each, ≤ 40), the session's subagents (type,
description, current step) — never tool output, thinking or hook text…". Watch, 5-minute lifetime, linked-phone gate, memory-only and the zone
delete are unchanged. New guards: `TestFeed05_LiveBlockSummariesOnly` (no output/thinking field, summary cut, steps and
agents caps) and `TestFeed05_LiveBlockRedactsSecrets` (a Bash summary with a token, a `-H "Authorization: Bearer …"`,
a `PASSWORD=` env and a `user:pass@` URL reaches the payload as `[secret]`); the five existing guards stay as they are. The inventory changelog records this review's ask.

## Failure and races

- **Writers.** The transcript has one writer (Claude Code or Codex); the hub only reads. The `session_chat` record has
  one writer, the hub's source (its `runs` map under `mu`, `generation` on drop); the phone only reads it. Two reads of
  one chat never overlap: the dirty mark is per chat and a read in flight re-arms the debounce instead of starting a
  second read. A read that began under an older generation stores nothing (as today).
- **Hub stops mid-turn / Mac sleeps.** No more events; the phone's `ReplicaFreshness` turns stale → the line shows the
  stale wording without timer. Test: presentation with stale freshness → no timer, no pulse.
- **Hub restarts.** Watches are memory-only and gone; the phone's next `session_chat_request` (≤ 60 s) opens a watch,
  which reads once and arms the watchers. Until then the phone keeps the last record. Test: source after restart reads
  on the first request.
- **Event burst (a long Bash writing many lines).** Debounce + 1 s cap → ≤ 1 read and ≤ 1 publish per second. Test:
  100 events in 500 ms → 1 read; events for 3 s → 3–4 reads.
- **Watcher fails to add / directory removed.** Fallback to the 3 s tick for that chat. Test: fake watcher refusing
  `Add` → the tick reads.
- **File replaced (new conversation after `/clear`).** The conversation list changes on the `Wake` loop → re-resolve → the new file is watched; the
  live block's `conversation` changes and the steps slot closes. Test: rename/create sequence.
- **Live read fails, feed read succeeds.** Entries update; `live` keeps the last value, `live_error` set → line "Activity
  unavailable" + Retry (Retry sends `session_chat_request`, which re-reads at once). Test per path.
- **Socket drops on the phone.** Live link's existing behaviour: the wake read fetches `changes`; the line then catches
  up. Nothing new.
- **Phone in background.** The socket closes (live link), the `TimelineView` stops, the request loop stops with the
  screen; the hub's watch expires after 5 min and its watchers go with it.
- **Mac Workchat: a file source cannot be opened / the file is replaced.** The pane falls back to the 3 s timer
  for that session; rename/delete re-resolves the paths from the next CLI read. Test: fake source refusing open → timer.
- **Mac Workchat: two refreshes at once.** The store already serialises reads per session (one in flight, the next
  coalesced); the event path goes through the same entry point, so an event during a read marks one more read, never two.
- **Clock skew Mac ↔ phone.** Elapsed clamped at 0:00; a step started "in the future" shows 0:00.
- **Old phone / new hub, new phone / old hub.** Covered in §1; tests decode both fixtures.

## Promises → tasks and tests

| Promise | Test |
|---|---|
| `live` in the payload, caps, summary cut, reserved inside the byte budget | Go `session_chat_test` |
| FEED-05: summaries only, no output/thinking | `TestFeed05_LiveBlockSummariesOnly` (new guard) |
| Secrets redacted in every summary and description | `TestFeed05_LiveBlockRedactsSecrets` (new guard) + `secretredact` tests (moved watchman cases + `user:pass@`) |
| `live_version` on every new payload; hung read → `live_error` | Go `session_chat_test` with a fake fetch that blocks past the timeout |
| Loading only until the first record; old hub → no line; table of §4 | phone model test, one case per table row |
| Mac Workchat refreshes on a file event (per-file sources incl. each running subagent file), 250 ms / ≤ 1 s, fallback timer, re-resolve on rename; state change → one refresh | Desktop store test with a fake file-event source (no wall time) |
| CLI prints `paths` | Go `cmd` test on `session-feed --json` |
| Finished session: no `live`; failed live read: last `live` + `live_error` | Go `session_chat_test` |
| Read on file event, 250 ms debounce, ≤ 1/s | Go test with a fake watcher and the test clock (no wall time) |
| Re-resolve on rename/create | Go test |
| Fallback to the tick when `Add` fails | Go test |
| No read without a watch; watchers dropped on expiry/unlink | Go test (extends FEED-05 twins, none relaxed) |
| Kit decodes `live`; old payload decodes with `live == nil` | Kit test on both fixtures (`TestFeed05_MatchesKitFixtureKeys` fixture updated) |
| Moved presentation behaves the same | the Mac's existing `WorkchatLivePresentation` tests, moved, unchanged |
| Phone line states (loading, working, thinking, steps open, stale, unavailable, hidden by a card, none) | phone presentation-input test per state |
| All line/step/agent strings from the shared presentation | phone test asserts the strings |
| Steps toggle, closed by default, closes at turn end/Stop/card/new conversation | phone model test |
| Sheet Working rows with step + timer; without `live` "Running" | `WorkchatAgents` test |
| Badge from `live`, finished-in-live counts as done | `WorkchatAgents` test |
| No new phone timer outside the visible line | review check + energy log in the plan |
| Event-to-phone latency ~1 s | measured on the local relay stand, number recorded here |

## Mockups

Phone mockups (`WatchtowerMobile/Tests/Support/WorkchatLiveMockups.swift`, rendered by
`make mobile-shots SHOTS_ONLY=workchat-live`, `ScreenshotTourTests/testTheWorkchatLiveShots`), copied to
[`docs/design/mockups/phone-workchat-live/`](../../design/mockups/phone-workchat-live/). Built from the phone's design
pieces; colours through `PhoneTone`/`Tone`, no row separators.

| Frame | State |
|---|---|
| L1 | Working on a step: line with symbol, summary, timer; toolbar 👥 2 |
| L2 | Steps open: 6-row slot, line "This turn · 9 steps" with the turn timer |
| L3 | Thinking between tools: "Working…" with the turn timer |
| L4 | Loading: chat open, no record since — "Loading activity…" (§4 table, row 1) |
| L5 | Error: "Activity unavailable" + Retry |
| L6 | Tower not sending updates: stale wording, no timer, freshness line under the header |
| L7 | Busy behind a card: permission card above the composer, line hidden |
| L8 | Narrow scope: a subagent's chat, the line shows that agent's step |
| L9 | Agents sheet with live Working rows (step + timer) and Done collapsed |
| L10 | Empty: no turn running, no line |

After the build the real views are captured beside these frames and compared.

## Left to the builder

Debounce constants within the stated bounds, the fsnotify wrapper's shape, the exact module home of the moved model
(§7), signpost names for the latency measurement.
