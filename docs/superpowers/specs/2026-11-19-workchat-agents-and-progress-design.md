# Workchat: agents out of the dialog, live progress, send while working, inline pastes, faster open

Board: #2065. Decisions: see the Decisions section.

## Decisions

| # | Decision | Source |
|---|---|---|
| D1 | No agent cards in the feed, running or finished | owner, chat 2026-11-19 ("не должны торчать в общем потоке") |
| D2 | Finished agents in a collapsed Done section of the 👥 list | ask #1601 |
| D3 | The phone gets D1 + D2 in the same PR | ask #1601 |
| D4 | Live steps of the current turn, shown on the fly, never in the feed | owner, chat 2026-11-19 ("на лету … не засоряя общение") |
| D5 | Typing while the agent works sends/queues; Stop is not the only button | owner, chat 2026-11-19 |
| D6 | The chat must not lock while background agents run | owner, chat 2026-11-19 |
| D7 | Pastes go inline in the field as tokens, as in Claude Code | owner, chat 2026-11-19 |
| D8 | Workchat opens faster | owner, chat 2026-11-19 |
| C1 | Steps list open by default, the owner's toggle remembered per pane | author's call (D4 "on the fly") |
| C2 | Done opens by itself when nothing works (else collapsed per D2) | author's call; mockups 03/05 showed the extra click |
| C3 | Phone Working rows: type, description, "Running" — no action/timer | author's call; live data on the phone would change FEED-05 (guarded) |
| C4 | Codex Done = what the 256 KiB live window shows | author's call; Codex feeds draw no agent cards today |
| C5 | Speed: both a tail read and a kept-alive store | author's call; the signposts verify the targets |
| C6 | §5/§6 are Workchat-only (config flag); the AI chat is unchanged | author's call |

## Intent

Workchat is the dialog with a session's agent. Today it is also a dump of
every `Agent` call: each subagent is a card in the feed, finished ones stay
forever (a 950-entry session carries 232 cards). The owner wants the dialog to
be the dialog: what they said and what the agent answered. How the work is
going — the tools running right now, the agents working, the ones that
finished — is visible on the fly, next to the dialog, never inside it.
Workchat also opens noticeably slower than the terminal.

## Goals

1. **No agents in the feed.** Neither running nor finished subagent markers
   are drawn in the Workchat feed, on the Mac and on the phone.
2. **Agents live in the 👥 list.** The live line's 👥 button opens a list with
   two parts: **Working** (task, current action, timer) and a collapsed
   **Done · N** (every finished subagent of the tab). A row opens the
   subagent's feed in place, as today.
3. **Live work progress.** While the agent works, the owner can see the
   steps of the current turn as they happen (tool + summary + time), without
   one line of it entering the feed.
4. **Faster open.** Measure click → first painted feed, then cut it.
5. **Send while working, never locked** (§5): with text in the field the
   button is Send in every state; background agents never lock the line.
6. **Inline pastes** (§6): images and long text go into the field as tokens.

## Non-goals

- No change to what the transcript reader extracts for the dialog itself
  (owner/agent text, asks, Watchtower lines, brief, separators).
- No steps history for past turns. When a turn ends, its steps are gone from
  the screen (the transcript and the terminal keep them).
- No live steps on the phone in v1 (the phone has no live line today); the
  phone gets goal 1 and goal 2's list.

## Anti-goals

- Anything that makes the feed jump or grow while the agent works (step by
  step). The steps slot appears once when a turn starts and goes once when it
  ends, at fixed height — both moments already change the feed.
- A second always-open panel that eats feed height.
- Losing the way to a finished agent's report (ask #1601 kept it: Done).

## Approaches

**Agents.** (a) Done section in the 👥 list — **picked** (ask #1601).
(b) Drop finished agents entirely — loses the reports. (c) One collapsed
"N agents finished ›" line in the feed — still a trace in the dialog.

**Live progress.** (a) **Picked:** the live line becomes a disclosure. Closed,
it is today's one line (current tool, `· N more`, timer). Open (the default),
it shows the current turn's steps in a fixed-height, scrolling list above the
live line, newest at the bottom, pinned to the end. The slot goes away when
the turn ends and comes back, open or closed as the owner last left it, with
the next turn. (b) A steps block inside the feed like the AI chat's
"Working… · 4 steps" — that is exactly the clutter the owner rejected.
(c) A side inspector panel — eats width, a second thing to manage.

**Open speed.** Both ship (C5); the measurement (Task 1) gives the before/after numbers:
(a) a tail read — the first read returns only the last 60 entries plus a
`before` cursor, earlier ones load on scroll-to-top (the window already grows
there); (b) keep each session's feed store alive for the app's lifetime so
reopening reads only the tail after the cursor. (a) helps the first open,
(b) every reopen. Removing subagent rows (goal 1) shrinks the
work for both.

## Design

### 1. Feed without agents

- Go keeps emitting `subagent` entries and the `subagents` list (the CLI's
  pinned JSON keys do not change; FEED contracts hold). The feed reader is
  not touched.
- `WorkchatFeedAdapter` drops `kind == "subagent"` (it maps to no message).
  Nested subagents inside a subagent's own feed are dropped the same way and
  listed in that screen's 👥 list.
- The phone: the chat screen drops `.subagent` entries from the drawn feed
  and builds its agents list from them. The hub's `session_chat` slice keeps
  carrying the markers unchanged — they are the phone's only agent data, and
  FEED-05 (`TestFeed05_OnlyFeedKindsPublished`, the Kit fixture keys) stays
  untouched. An older phone build keeps reaching subagent chats through the
  markers, so there is no hub/phone version skew.

### 2. The 👥 list

```
 ⌘ Reading feed.go · 2 more                        👥 2   1:12
 ┌──────────────────────────────────────────────┐
 │ Agents                                       │
 │ WORKING                                      │
 │ Explore — Recon DB layer         Grep…  0:48 ›│
 │ codex-wrapper — Codex review     Bash…  0:21 ›│
 │ ▸ Done · 9                                   │
 └──────────────────────────────────────────────┘
```

- **Where it lives when nothing works.** Today `WorkchatLivePresentation.row`
  returns nil unless `working`, so the 👥 button exists only during a turn,
  and an ended session draws no live line at all. New rule: the live line's
  row (already a fixed-height slot) keeps the 👥 button whenever the tab has
  at least one subagent — idle, working or ended; the ended state draws the
  same caption row under its "ended" line (the ended line's padding moves
  from `Spacing.cozy` to `Spacing.large` so the two align). Only the activity text, timer and
  steps chevron depend on `working`. The agents popover no longer closes
  when work stops (the steps list still does). The subagent screen follows
  the same rule for its nested agents.
- **Badge:** the number of working agents. With none working and at least
  one done: a dimmed `✓ N` on a faint capsule (`Fill.rest`) so it still
  reads as a button in light mode (still opens the list). None at all: no button.
  Agent status unknown: `?`, and the list still opens with Done (today it is
  disabled — the Done part is readable even when live status is not).
- **Working** rows come from `live.agents` (non-finished), as today.
- **Done** rows come from the feed's `subagents` list with status
  `finished` (sidecar `meta.json`, every conversation of the tab), title =
  type, subtitle = description. Order: `started_at` newest first (the
  additive key from §4, so the order is the same for a full or tail read);
  ties and zero times keep the CLI's order. Done is collapsed while something
  works (D2) and opens by itself when Working is empty or unknown (C2); a
  toggle by the owner is remembered per pane while the app runs and wins
  over the default. At most 5 rows show, the rest scroll. Codex: the list
  holds what the 256 KiB live window shows (C4; Codex feeds draw no agent
  cards today either, so nothing is lost).
- An agent that finishes moves from Working to Done on the next poll (3 s).
- Clicking a row closes the popover and opens the subagent in place.
- Phone: the same two sections on a sheet from an agents button in the chat
  screen's toolbar, both built from the slice's marker entries: Working =
  status `running` (type, description, "Running" — no action or timer, the
  phone has no live snapshot), Done = `finished`. No new slice data.

### 3. Live steps

- `sessionfeed.Live` gains `steps []LiveAction` (the current turn's tool
  actions in order, completed ones with `completed_at`, the open one last)
  and `steps_more int` (how many older steps of the turn were cut). Cap: the
  last 40 steps. Read from the same 256 KiB tail `LiveOf` already scans; a
  turn longer than the tail shows what the tail holds and counts nothing
  for the part it never saw (stated as a v1 limit). Additive key only.
- The live line gets a chevron when `steps` is non-empty. The list is
  **open by default** (C1); a click on the line (or ⌥↓ with the composer
  focused) toggles it, and that choice is remembered per pane while the app
  runs (in memory). Each row: tool symbol, summary
  (one line, middle truncation), duration (`0:04`) or a running timer.
  Height: **fixed at 6 rows** from the moment the slot appears (fewer steps
  sit bottom-aligned), then it scrolls; pinned to the newest unless the
  owner scrolled up. A new step never changes the slot's height.
- Placement: the list opens **above** the live line, as an inset that takes
  its fixed height from the feed once per turn; the line the owner clicked does not move and the newest step
  sits right next to it. The chevron points up when closed, down when open.
- While the list is open the live line shows the turn's summary
  ("This turn · 8 steps", timer) instead of repeating the newest step.
- The slot is hidden when the turn ends, the session stops working, the
  permission card shows, or the conversation changes; it comes back with the
  next turn in the remembered open/closed state.
- Subagent screen: the same disclosure over that subagent's own steps.

### 4. Measurement and speed

- Task 1 adds `os_signpost` intervals: pane appear → CLI spawn → CLI exit →
  decode → adapter → first feed paint, for open and reopen, and records the
  numbers for three sessions (small, ~300, ~950 entries) in this doc.
- Measured so far (CLI only, installed build, 2026-11-19): 0.2–0.3 s warm
  for a tiny session, ~0.9–1.0 s for 300–950 entries.
- Speed work (C5): (a) the first read is a tail read — `session-feed
  --tail 60` returns the last 60 entries, the cursor and a `before` cursor;
  scroll-to-top asks `--before C --tail 60` for the previous page (additive
  CLI flags; `--after` reads are unchanged). `--tail` parses exactly what a
  full read parses and only trims the `entries` it prints; the `subagents`
  list is the full list a full read prints (every conversation, meta.json),
  never trimmed. Each `subagents` item gains an additive `started_at`: the
  Agent call's time when the transcript part was parsed, else the
  `meta.json` file's mtime (FEED-03 additive key; zero only when neither
  exists). Go paths changing together: `internal/sessionfeed` (`Build`,
  `subagent.go` refs), `cmd/workbench_session_feed.go` (flags, JSON);
  Swift: `SessionFeedStore` (tail/before paging, Done from `subagents`),
  `SessionFeedSubagent` decoding `started_at`, the CLI lookup's arguments.
  The Kit/phone slice is not touched (it keeps `ChatFetch` entries). (b) `WorkbenchesViewModel` keeps
  each session's `SessionFeedStore` for the app's lifetime (it already keeps
  `WorkchatModel` per session), so reopening paints the kept entries at once
  and reads only after the cursor.
- Target: first paint ≤ 300 ms on the 950-entry session on reopen, ≤ 500 ms
  on first open; the before/after numbers go into this doc.

### 5. Type while the agent works (owner, 2026-11-19)

Today `ChatComposerField` turns the round button into Stop whenever
`isStreaming`, and Workchat passes `working` — which includes the
`background` state (`SessionControl.isWorking`: `.working, .background`). So
while a background agent runs, the only button is Stop and the chat reads as
locked; Return does call `onSend` (`submit` checks only `canSend`), but
nothing on screen says so.

- The round button is **Send** whenever the field has text or attachments,
  in every state; it is **Stop** only with an empty field while the agent
  works (Claude Code's own behaviour). Esc in the empty field stays Stop.
- A line sent while the agent works goes as today (`workchatLineCheck`,
  the "Queued · the agent reads it at its next step" caption until its echo).
- `background` (agents running, the main turn over) is not a busy turn for
  the line: Claude Code is at its prompt, so the line goes at once.
  Task: reproduce the "locked" report against the real state machine
  (`workchatLineCheck` with `.background`, `justSubmitted`,
  `promptHoldsText`), fix what holds the line, test each state → `.go` /
  `.hold(reason)` with the caption shown.
- Codex and other kinds that hold until idle keep their hold, but the button
  is still Send and the line shows "Queued · sends when the agent stops ·"
  with Cancel (existing strings).
- The change is a `ChatComposerFieldConfig` flag (`sendWhileStreaming`), on
  for Workchat only; the AI chat keeps its Stop-while-streaming button.

### 6. Pastes inline, as in Claude Code (owner, 2026-11-19)

Today a long text paste raises a bar offering to attach it as a file
(`LongPasteOffer`), and a pasted image becomes a chip above the field.

- A pasted image goes into the text at the cursor as a token
  `[Image #1]`; a text paste over the long-paste threshold goes in as
  `[Pasted text #2 +42 lines]`. Tokens are atomic: one Backspace removes the
  whole token and its payload; numbering counts up per draft.
- Short pastes go in as plain text (as now).
- On send, a text token expands to its full text in place; an image token
  becomes the saved file's path (the existing `workchat-attachments` save),
  so the agent sees exactly what Claude Code would get. The bracketed paste
  to the terminal is unchanged.
- Files dropped or picked with the paperclip stay chips (no change).
- Draft persistence: tokens and their payloads live in `WorkchatModel` with
  the draft (in memory, survive pane switches); a payload whose token was
  deleted is dropped; an image file whose token was deleted is swept by the
  existing attachment sweep.
- The image is saved at paste time (today's `attach(data:name:)` path). A
  save that fails inserts no token and shows today's `attachmentError`.
  An image file gone by send time (swept, deleted) refuses the send with
  "Pasted image #N is gone — paste it again", the draft kept as is.
- An outgoing line keeps both forms: `typedText` = the draft **with tokens**
  plus the token payloads, and the expanded text that goes to the terminal.
  A `notSent` line or a Cancel of a queued line restores the tokenized draft
  with its payloads (only into an empty field, as today). The echo is
  matched on the **expanded** text (what the transcript records), with
  today's collapsed-whitespace rule.
- Same config gate as §5: Workchat on, AI chat unchanged.

## Failure and races

- **CLI read fails mid-open:** the feed keeps the last good entries (or the
  empty state with Retry); the 👥 list shows Done from the last good read.
  Test: store keeps entries when a later read fails.
- **Host or session closes while the steps list is open:** `working` turns
  false → the list closes. Test: presentation closes on `working == false`.
- **App restart:** nothing is persisted; the first read rebuilds the list
  and Done. The remembered Done-expanded state is in-memory only.
- **Writers:** the feed and the live snapshot have one writer (the CLI
  reading transcripts, read-only); `meta.json` is written by Claude Code.
  A marker whose `meta.json` is not yet written is missing from Done until
  it appears (existing v1 limit). Working and Done can disagree for one poll
  (live says finished, the list not re-read yet): Done wins on the next read;
  an agent is never shown in both — Working filters out ids present in Done.
- **Paste tokens on a failed or cancelled line:** the tokenized draft and
  its payloads come back (§6); test per path (`notSent`, Cancel, image gone).
- **Tail read:** an entry before the window is loaded only on
  scroll-to-top; an entry that grows inside the window upserts by id as now.

## Promises → tasks and tests

| Promise | Test |
|---|---|
| No subagent row in the Mac feed | adapter test: `subagent` entry → no message |
| No subagent row on the phone | Kit/phone test on the chat entries filter |
| Badge states (N / ✓N / ? / none) | `WorkchatLivePresentation` test per state |
| Done list content, order, dedupe with Working | presentation test |
| `steps` / `steps_more` in `live` | Go `live_test` incl. cap and open step |
| Steps list closes on turn end / stop / card | presentation test |
| All UI strings in the model | presentation tests assert the strings |
| Open-speed target | signpost numbers recorded in this doc |
| Send button with text while working; Stop only when empty | composer button-state test |
| Background state lets a line go | `workchatLineCheck` test per state |
| Paste tokens: insert, atomic delete, numbering | composer token model test |
| Tokens expand on send (text inline, image → path) | `WorkchatModel.send` test |
| Dropped token drops its payload | model test |
| 👥 shown idle and ended, hidden with no subagents | presentation test per state |
| Done auto-opens when Working is empty/unknown; owner toggle wins | presentation test |
| Steps open by default, toggle (click, ⌥↓) remembered per pane | presentation + key-handler test |
| Steps slot height fixed; hidden on turn end / stop / card / new conversation | presentation test |
| `sendWhileStreaming` off: AI chat keeps Stop while streaming | composer button-state test |
| Codex hold: Send button + "Queued · sends when the agent stops ·" + Cancel | `WorkchatModel` test |
| `notSent` / Cancel restore the tokenized draft with payloads | `WorkchatModel` test |
| Echo matched on the expanded text | `WorkchatModel` echo test |
| Image gone at send refuses with the message, draft kept | `WorkchatModel` test |
| `--tail` / `--before` pages, cursor kept | Go `feed_test` + `cmd` test |
| `--tail` prints the same full `subagents` list as a full read | Go `feed_test` |
| `started_at` from the Agent call, else meta.json mtime | Go `subagent_test` |
| Store kept per session; reopen paints kept entries | store/view-model test |
| Phone: no agent rows in the feed; sheet sections | Kit/phone test |

## Mockups (DesignShotCatalog)

Rendered by `DesignShotsTests/testWorkchatAgentsMockShotsRender`
(`DesignShotFixtures+WorkchatAgentsMock.swift`), 14 states × light/dark:
01 working + Done collapsed, 02 Done expanded, 03 only Done, 04 none,
05 unknown, 06 loading, 07 error + Retry, 08 steps open, 09 steps narrow,
10 feed without cards, 11 idle, 12 ended, 13 send while working,
14 paste tokens. The real views are compared against these after the build.

This Mac list is the one source of truth for the post-build comparison.
Colours through `Tone`, no row separators.

Phone (`WatchtowerMobile/Tests/Support/WorkchatAgentsMockups.swift`,
rendered by `make mobile-shots SHOTS_ONLY=workchat-agents`,
`ScreenshotTourTests/testTheWorkchatAgentsShots`). The sheet closes with an
✕ button, not "Done" (the mock's "Done" clashes with the Done section; fix in
the build). Working rows open the agent's chat (chevron). States: P1 chat without agent cards, toolbar agents button "2";
P2 sheet Working (2) + Done · 9 collapsed; P3 only Done expanded, button
"✓ 9"; P4 no agents, no button.

## Left to the builder

Exact SF Symbols per tool (reuse `WorkchatActivityPresenter.symbol`), the
phone toolbar icon, signpost names.
