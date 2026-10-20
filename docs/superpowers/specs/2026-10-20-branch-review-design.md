# Branch review — the Changes pane becomes a review of one session's branch (board #712, Linear AI-13)

**Status:** design for owner review. Desktop only; the review engine
(`internal/reviewdiff`, rounds, comments, `get_review`, Undo, the AI
overview — `docs/features/diff-reviewer.md`) is unchanged. Visual design
(ask #446 asked for it first): the claude.ai design canvas "Branch Review
Design" — A branch with changes, B nothing to review, C Deep Meaning,
D the header states; low-fi mockups: `2026-10-20-branch-review-mockups.html`. Calls marked
**(my call)** are the designer's, not the owner's.

## 1. Why

The owner's report (AI-13, screenshot on #712):

1. The Changes page does not say which session it belongs to. The pane
   title is "Changes ▾", the header says "Base: origin/main  Round #2" —
   nothing names the session, its branch or its worktree.
2. It is not a permanent thing — it is needed at a moment (the agent
   handed work back), yet it sits in the header's view capsule next to
   Terminal, Board and Files all the time. Call it **Branch review** and
   redesign the UI/UX: on an arbitrary session it looks bad.

What "looks bad" is, concretely, on the screenshot (a session in the main
folder on `main`, no uncommitted edits):

- the diff is empty, yet the AI overview ran and lists every linked target
  with a red ✕ ("Diff is empty… none of the intent is implemented") — a
  verdict on nothing, which reads as a failure;
- **Working on** lists four targets in full, taking half the column;
- the empty state is split in two: "No changes" in the list and "No
  changes yet" in a big empty diff area;
- eight controls in one header row (Base, Round, Quick/Deep, Inline,
  Refresh, ⋯, Send review), none of them about the session;
- a transient `SQLite error 5: database is locked` banner over everything;
- the column sits on the sidebar material (brown tint in the dark theme),
  unlike the rest of the workbench.

## 2. Goals, non-goals, anti-goals

**Goals**

- One glance tells whose work this is: the session, its agent, its state,
  its branch and worktree, and what it is compared with.
- The review shows up when there is something to review and stays out of
  the way otherwise.
- A session with nothing to review shows one honest empty state and spends
  no model call.
- The screen is built from the design kit (`docs/design/desktop-style-guide.md`):
  one prominent action (Send review), panels not pop-ups, no stock chrome.

**Non-goals**

- No change to what is reviewed (the work tree vs the merge-base with the
  default branch — committed branch work plus uncommitted edits, as today),
  to rounds, comments, carry-over, Viewed, Undo, Deep mode's phases, the
  overview's contract or the inventory entries REVIEW-01..05, PROJ-12.
- No Go change, no migration, no new CLI (my call). Every fact the new
  header shows is already on the Desktop (§4.2).
- No PR source (a GitHub pull request as the thing reviewed) — still a v1 limit.

**Anti-goals** (a failure even if it works)

- A verdict on an empty diff.
- A review that can be confused with another session's (two sessions of
  one workbench open side by side must not look alike).
- A button that is always there but rarely does anything.

## 3. Names

| Today | New |
|---|---|
| Header view button **Changes** | **Review** — contextual, §5 (my call: one word fits the capsule; the pane says "Branch review") |
| Pane title / pane picker item **Changes** | **Branch review** |
| Row menu **Review Changes** | **Review Branch** |
| Guide page "Diff review" | "Branch review" (same file, renamed title; the URL path stays `diff-review.md` so links keep working — my call) |

`WorkspacePane.changes`, `WorkspaceView.changes`, `ReviewChangesModel` and
the persisted layout keys keep their names: renaming them would migrate
the stored `WorkspaceLayout` for no visible gain (my call).

## 4. The pane

### 4.1 Layout (Quick mode, a session with changes)

```
┌ ⎇ Branch review ▾ ─────────────────────────────────────────── ⤢ ✕ ┐  pane header (split only)
│ ● Claude · "Fix the record capsule"            Working · 4 min      │  identity bar
│ ⎇ wt/712-capsule  →  main · 8 files +212 −40 · 2 uncommitted · worktree │
│ For #712 Plashka zapisi…  +2 more ▾                                 │
├──────────────────────────────────────────────────────────────────────┤
│ Round 2  [All | Since round 1]   [Quick | Deep]      ⧉ ↻ ⋯  [Send review (3)] │  toolbar
├───────────────────────┬──────────────────────────────────────────────┤
│ Summary card (folded) │ M  Sources/…/RecordCapsule.swift  +40 −12  ☐ Viewed  ‹ › │
│                       │ ┌ Monaco diff ───────────────────────────────┐ │
│ Files  8 · 3 viewed   │ │                                            │ │
│ M RecordCapsule.swift │ │                                            │ │
│ A CapsuleTests.swift  │ └────────────────────────────────────────────┘ │
│ …                     │ Comments on this file (2)                      │
│ Folded (2)            │                                                │
└───────────────────────┴──────────────────────────────────────────────┘
```

### 4.2 Identity bar — whose work this is

Two lines and an optional third, on `Surface.detail`, above the toolbar:

1. **Session line.** The agent's glyph and the session's state dot and
   label exactly as the sessions panel draws them
   (`SessionSwitcherPresentation`, `SessionStatePresentation` — the same
   colours, so Ready to check is purple here too), the session title, and on
   the right how long ago its state changed. A click on the title shows
   the session's terminal (or Workchat, in its recorded mode) beside the
   pane — `vm.showSession`.
2. **Branch line.** `⎇ <branch> → <base label>` (the round's `baseLabel`
   without `origin/`, its sha in the tooltip), then the size from the
   round's diff, `N files · +a −d`, plus `M uncommitted` when the session's
   place is dirty (`WorkbenchGitStatus.changes`). No commit count: nothing
   on the Desktop has it today and the file size says more (my call). Then
   the place:
   `worktree <name>` or `main folder` (`SessionPlacePresentation`, the row's
   label). A detached HEAD shows `detached at <sha>`.
   **On the default branch itself** the line says
   `On main — only uncommitted edits are reviewed`, since the merge-base is
   HEAD and the committed work is already in main.
3. **For line** (only when the session has linked targets):
   `For #712 <title>` and `+N more ▾`; the chevron unfolds the full
   **Working on** cards (text, intent, plan task) in place. Today's
   always-open "Working on" section in the file column goes away.

The pane picker's title in a split becomes `Branch review · <session title>`
(truncated in the middle), so two review panes side by side differ in
their first words.

### 4.3 Toolbar

Left: `Round N` and, from round 2, the **All | Since round N−1** switch; the
**Quick | Deep** switch (`KitSegmentedPicker`). Deep's progress line
(`lines · chapters · active`) moves into Deep's phase strip, where it
belongs (my call). Right: icon buttons (`.kitIcon`) **Inline** (toggled),
**Refresh**, **⋯** (Find Repeats…, Show in Finder, Open in Terminal), then
the one prominent action **Send review (N)** (`.kitPrimary`). The text
labels "Inline" and "Refresh" become tooltips.

### 4.4 File column

On `panelSurface()` with `panelListStyle()` instead of `.sidebar` (fixes the
tint). From the top:

- **Summary card** (`.card()`), only when the round has changes: the
  overview's first line and risk line, folded; unfolds to the full
  overview (coverage, outside the intent, size). In Quick without a cached
  overview the card is one line, `AI summary, intent coverage and risk`
  with **Make overview** (`.kitSecondary`). The reading order stays inside
  the unfolded card.
- **Files** with a `SectionHeader` count (`8 files · 3 viewed`), rows as
  today (`kitRow`), then **Folded (n)**, then **Undone** and **Resolved by
  the agent** as today.

### 4.5 Diff side

A file header row above Monaco: status glyph, path (middle-truncated),
`+a −d`, risk badge, **Viewed** checkbox and **‹ ›** previous / next
unviewed file (also ⌥⌘↑ / ⌥⌘↓, my call). Today the Viewed mark is only in
the list, so reading a file and marking it means going back to the column.
The comment list under the diff is unchanged.

### 4.6 States

| State | What shows |
|---|---|
| Opening the round | the identity bar (it needs no round) and a spinner below |
| **Nothing to review** (empty diff, round open) | identity bar, then one `ContentAwareEmptyState` across the whole body: "Nothing to review on this branch" / "No commits past main and no uncommitted edits." with **Refresh**; on the default branch: "No uncommitted edits in the main folder." No file column, no summary card, no Send. |
| Changes, no file picked | the file column and, on the right, "Pick a file" — never "No changes yet" while files exist |
| Round failed to open | identity bar, then the reason and **Retry** (as today) |
| Sent round | toolbar shows `Round N · sent`, Send becomes **Start next round** (today's Refresh-after-send, now named) |

**No model call on an empty diff.** The Desktop does not run
`review overview` (Deep's automatic call or Quick's cached read) while the
round's diff has no files, and drops an overview already on screen when a
refresh empties the diff (my call: a Desktop guard in `ReviewChangesModel`;
the Go command stays as is, so the CLI can still be asked by hand).

**Transient write errors.** A `SQLITE_BUSY`/"database is locked" from a
review write (Viewed, mode, phase, pace) is retried once after 300 ms
before it is shown; when it still fails it shows in the kit's
`WriteErrorBanner` under the toolbar, not above the identity bar (my
call). Pace and phase writes, which the owner did not ask for, never show
a banner: they are logged and retried on the next flush.

## 5. When the review shows up

The header capsule today: `Terminal|Workchat ▾ · Session · Board · Files ·
Analytics · Changes · Chat`. **Changes** leaves the capsule. Instead:

- **Review** button — a separate `.kitSecondary` button right of the
  capsule, shown only while the session the header targets
  (`sessionViewTarget`) has something to review: its place is dirty
  (`WorkbenchGitStatus.dirty`), or it is on a branch other than the
  default one, or its Branch review pane is on screen (then it is lit and
  closes it). It is never shown for a plain terminal session. Hidden, not
  disabled (anti-goal: a button that is always there).
- **Ready to check** — a session in that state shows **Review Branch** as a
  hover action on its row in the sessions panel and on the session report
  (`WorkbenchSessionReportView`) beside its other actions.
- **Row menu** — **Review Branch** stays for every agent session, so the
  owner can always open it by hand.
- **Pane picker** — **Branch review** stays in the split panes' picker.

Closing the pane closes it; nothing reopens it by itself (my call). An
open round, its drafts and Viewed marks stay in the database, so reopening
lands where the owner left.

## 6. Deep mode

Unchanged in behaviour. Visible changes only: the phase strip
(Meaning · Chapters · Wrap-up) uses `KitSegmentedPicker` and carries the
progress line on its right; the identity bar stays above it in all three
phases; Meaning's intent card is the identity bar's **For** list unfolded,
not a second copy.

## 7. What changes in code (for the plan)

- `ReviewChangesPaneView` — new body: identity bar, toolbar, states table.
- New `ReviewIdentityBar` (view) + `ReviewIdentityPresentation` in
  WatchtowerCore (pure: session, place, git status, round → the two lines;
  unit-tested, including default branch, detached, worktree, unknown place).
- `ReviewChangesHeader` → `ReviewToolbar` on the kit; banners move below it.
- `ReviewFileListView` — panel surface, Summary card, no Working on section.
- File header row above `MonacoDiffView`; next/previous unviewed in the model.
- `ReviewChangesModel` — empty-diff overview guard; one retry on a busy write.
- `WorkbenchHeaderControls` — `.changes` out of the capsule, contextual
  **Review** button; `WorkspaceView.title` "Branch review".
- `TerminalSessionRow`, sessions panel, session report — **Review Branch**.
- `DesignShotCatalog` — Branch review shots: changes, empty branch, default
  branch, Deep Meaning; light and dark.
- Docs: `docs/guide/features/workbench/diff-review.md` (title, steps, the
  empty and button sections), `keyboard-shortcuts.md` (pane name, ⌥⌘↑/↓),
  `docs/features/diff-reviewer.md` (a "Branch review UI" section).

## 8. Owner decisions (ask #447, 2026-10-20)

1. **The header button:** the contextual **Review** button next to the
   capsule (§5).
2. **What the review compares:** the whole branch against `main` — the work
   tree vs the merge-base with the default branch, as today; no
   "only uncommitted" switch.
3. **Name in the header:** "Review"; the pane is "Branch review".
