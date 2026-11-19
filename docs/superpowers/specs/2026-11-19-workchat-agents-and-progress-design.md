# Workchat: agents out of the dialog, live work progress, faster open

Board: #2065. Decisions: ask #1601 (2026-11-19).

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

## Non-goals

- No change to what the transcript reader extracts for the dialog itself
  (owner/agent text, asks, Watchtower lines, brief, separators).
- No steps history for past turns. When a turn ends, its steps are gone from
  the screen (the transcript and the terminal keep them).
- No live steps on the phone in v1 (the phone has no live line today); the
  phone gets goal 1 and goal 2's list.

## Anti-goals

- Anything that makes the feed jump or grow while the agent works.
- A second always-open panel that eats feed height.
- Losing the way to a finished agent's report (ask #1601 kept it: Done).

## Approaches

**Agents.** (a) Done section in the 👥 list — **picked** (ask #1601).
(b) Drop finished agents entirely — loses the reports. (c) One collapsed
"N agents finished ›" line in the feed — still a trace in the dialog.

**Live progress.** (a) **Picked:** the live line becomes a disclosure. Closed,
it is today's one line (current tool, `· N more`, timer). Open, it shows the
current turn's steps in a fixed-height, scrolling list just above the
composer, newest at the bottom, pinned to the end. It closes by itself when
the turn ends. (b) A steps block inside the feed like the AI chat's
"Working… · 4 steps" — that is exactly the clutter the owner rejected.
(c) A side inspector panel — eats width, a second thing to manage.

**Open speed.** Decided after the measurement (Task 1), from two candidates:
(a) a tail read — the first read returns only the last 60 entries plus a
`before` cursor, earlier ones load on scroll-to-top (the window already grows
there); (b) keep each session's feed store alive for the app's lifetime so
reopening reads only the tail after the cursor. Both may ship; (a) helps the
first open, (b) every reopen. Removing subagent rows (goal 1) shrinks the
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
  type, subtitle = description. Order (builder call): markers with an `at`
  newest first, then meta-only markers (zero `at`) in the store's
  first-seen order; no new Go field. Done opens expanded by itself when
  Working is empty or unknown; at most 5 rows show, the rest scroll. Codex: the list holds what the
  256 KiB live window shows (existing v1 limit; Codex feeds draw no agent
  cards today either, so nothing is lost). Collapsed by default; the
  open/closed state is remembered per pane while the app runs.
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
- The live line gets a chevron when `steps` is non-empty. Click (or ⌥↓ with
  the composer focused) toggles the list. Each row: tool symbol, summary
  (one line, middle truncation), duration (`0:04`) or a running timer.
  Height: up to 6 rows, then it scrolls; pinned to the newest unless the
  owner scrolled up.
- Placement: the list opens **above** the live line, as an inset that pushes
  the feed up; the line the owner clicked does not move and the newest step
  sits right next to it. The chevron points up when closed, down when open.
- While the list is open the live line shows the turn's summary
  ("This turn · 8 steps", timer) instead of repeating the newest step.
- It closes when the turn ends, the session stops working, the permission
  card shows, or the conversation changes — the same rules that close the
  agents popover today.
- Subagent screen: the same disclosure over that subagent's own steps.

### 4. Measurement and speed

- Task 1 adds `os_signpost` intervals: pane appear → CLI spawn → CLI exit →
  decode → adapter → first feed paint, for open and reopen, and records the
  numbers for three sessions (small, ~300, ~950 entries) in this doc.
- Measured so far (CLI only, installed build, 2026-11-19): 0.2–0.3 s warm
  for a tiny session, ~0.9–1.0 s for 300–950 entries.
- Target: first paint ≤ 300 ms on the 950-entry session on reopen, ≤ 500 ms
  on first open. The task picks (a), (b) or both by what the signposts show.

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
- **Tail read (if chosen):** an entry before the window is loaded only on
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

## Mockups (DesignShotCatalog)

Rendered by `DesignShotsTests/testWorkchatAgentsMockShotsRender`
(`DesignShotFixtures+WorkchatAgentsMock.swift`), 14 states × light/dark:
01 working + Done collapsed, 02 Done expanded, 03 only Done, 04 none,
05 unknown, 06 loading, 07 error + Retry, 08 steps open, 09 steps narrow,
10 feed without cards, 11 idle, 12 ended, 13 send while working,
14 paste tokens. The real views are compared against these after the build.

Registered in `DesignShotFixtures+WorkchatActivity.swift`: list with Working +
Done collapsed; Done expanded; only Done (✓N badge); none (no button);
unknown status (`?`, Done still listed); loading; error with Retry; steps
open (busy, 6+ rows scrolling); steps open in a narrow pane; feed without
cards next to the live line. Colours through `Tone`, no row separators.

## Left to the builder

Exact SF Symbols per tool (reuse `WorkchatActivityPresenter.symbol`), the
phone toolbar icon, signpost names.
