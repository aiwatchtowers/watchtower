# Branch review polish — six owner fixes (board #958)

**Date:** 2026-10-24 · **Board:** umbrella #958, leaves #959–#964 · **Decisions:** ask #555, ask #556
**Mockups:** https://claude.ai/artifact/SquJ7UJkZwepDTvTFLgJ3F (private to the owner)
**Builds on:** `docs/features/diff-reviewer.md` (Plans 1–3, Branch review UI #712), `docs/inventory/review.md`

## Why

The owner used Branch review on real branches and hit six problems: the diff shows whole
files; there is no way to move around the code while reviewing; the lens checklist under
the code view means nothing to them; they cannot ask the agent about a piece of code
without leaving the review; Viewed is per file only; and there is no clear end to a
review — only **Send review** → **Start next round**. The goal is a reviewer that feels
like a good PR review: changed hunks first, the tree and navigation of an IDE, a
conversation with the author beside the code, and an explicit verdict.

## Goals

1. Show changed hunks with 3 lines of context; unchanged runs fold and open in pieces; a
   **Full file** switch shows the whole file (#959).
2. A folder tree of the changed files, and go-to-definition / usages / Open Quickly inside
   the diff; a file outside the diff opens as a read-only preview inside the review (#960).
3. Remove the lens checklist; the chapter tab shows the AI overview's risks for that
   chapter instead (#961).
4. A side panel with the session agent's Workchat inside Branch review, and an **Ask
   agent** action on selected lines that quotes them into the composer (#962).
5. **Chapter viewed →** marks every file of the chapter Viewed and moves to the next
   chapter (#963).
6. Two verdict buttons: **Request changes (N)** (today's Send) and **Approve**, which closes
   the review as approved and tells the agent to finish the work its methodology's way —
   PR and merge, targets to done, `finish_session` (#964).

## Non-goals

- No change to how rounds, carry-over, Undo, notes, chapters or the AI overview work,
  beyond what is listed here.
- No navigation on the old (base) side of the diff, and no navigation against the round's
  snapshot tree — navigation reads the files on disk (see v1 limits).
- No full-repository tree in the review (the owner chose the changed-files tree; the
  preview and Open Quickly reach every other file).
- Approve does not merge anything itself; the agent does, following its methodology.

## Anti-goals (fails even if it "works")

- A comment, note or Undo hunk that lands on a folded line and cannot be seen or reached.
- Approve typing a line before the round's outcome is stored, or bypassing PROJ-12's gates
  (REVIEW-04 must hold for the new line exactly as for Send).
- Approve silently dropping an open comment (REVIEW-03): a comment leaves the owner's list
  only by being resolved.
- The chat panel stealing the review's keyboard shortcuts or its selection.

## Design

### 1. Hunks first, full file on request (#959)

- `diff.js` turns on Monaco 0.57's `hideUnchangedRegions` on the diff editor:
  `enabled: !fullFile, contextLineCount: 3, minimumLineCount: 6, revealLineCount: 20`.
  Monaco draws a folded run as a bar with "N hidden lines" and reveal-up / reveal-all /
  reveal-down; that is the "open in pieces" the owner asked for, in both side-by-side and
  inline modes.
- A segmented control in the file header: **Changes | Full file**. It goes to the page as
  a new call `wt.setFullFile(bool)` (`updateOptions({hideUnchangedRegions:{enabled}})`).
  *My call:* it is per file view and resets to **Changes** when another file is selected;
  nothing is persisted.
- Reaching a line jumps into a fold: `wt.focus`, selecting a comment or note in the list,
  and a navigation target reveal the line first (`revealLineInCenter` after the region is
  revealed). Comment, note and Undo zones on a folded line are kept: the fold bar for a
  region that holds one shows a marker so it is not invisible (*my call*: the region is
  revealed automatically when it holds a comment or note).
- `diff.html`'s protocol header and `CodeEditorPageProtocolTests` / the editor-bridge check
  get the new call.

### 2. Changed-files tree and code navigation (#960)

**Tree.** `ReviewFileListView` becomes a tree: a new pure `ReviewFileTree` (WatchtowerCore)
splits `model.files` paths into folders, compacting single-child folder chains
(`Views/Workbench/Review`), sorted folders-first then by name. A folder row shows the count
of unviewed files and comment badges summed from its files; folders start expanded.
File rows keep today's `ReviewFileRow` content (status, risk badge, comments, +/−, Viewed).
The **Folded** group (lockfiles, generated, too large) stays at the bottom as today. The
summary card stays on top. The Files-pane tree (`CodeFileTree`) is disk-based and is not
reused.

**Navigation in the diff.** The modified editor gets the same messages the code viewer's
page already speaks (`editor.js`): ⌘-click posts `definition {req,id,word,line,col,x,y}`,
⌥⌘F7 / the context menu post `usages {id,word,line,col}`; Swift answers with
`definitionDone(req)`. The diff host forwards them to `CodeNavigationCenter` /
`CodeUsagesCenter` for the session's code root (`activeCodeRoot`, the worktree), the same
index the Files pane uses. Back/Forward (⌃- / ⌃⇧-) work through `CodeNavigationCenter`'s
history.

Where a jump lands:
- target file is in the diff → that file is selected in the review (Changes view, the
  region holding the line revealed);
- any other file → a **read-only preview** inside the review's centre area: a plain Monaco
  editor page (the code viewer's page in read-only mode) with a header
  "path · not changed in this branch · ← Back to diff". The preview supports the same
  ⌘-click and usages, so the owner can walk the code and come back.

**Open Quickly** (⇧⌘O, ⇧⇧) works while the review is key and opens its pick the same way
(diff file → select it, other → preview). The usages list opens in the review's existing
usages UI (`CodeUsagesCenter`), each hit opening as above.

**Where results land — the shared centres change (in scope).** Today `CodeNavigationCenter`
(`jump`/`step` → `workbenches.showLocation`), `CodeUsagesCenter.openUsage` and Open Quickly
always open the Files pane, and the Back/Forward origin is read from the Files pane's tab
and cursor. They get a *navigation destination* seam: the Files pane (today's behaviour)
or a Branch review pane, which opens a location as described above and reports its own
current location (file + line, diff or preview) for the history. *My call:* the pane that
was key when the action started receives the result; with Files and Branch review side
by side, ⌘-click / ⇧⌘O / ⌃- act on whichever pane has focus.

**Paths.** Round paths are relative to the repository top; the code index is relative to
the workbench folder (or session worktree). The review maps between them by the folder's
prefix inside the repository. A jump target outside the workbench folder is not in the
index and cannot occur; a diff file outside it (a subfolder workbench whose branch touches
other folders) simply has no navigation.

### 3. Lens checklist out, AI risks in (#961)

- `ReviewChecklistView` is removed from the pane, and the lens picker leaves the comment
  sheet (a new comment has no lens; `review_comments.lens` stays as a column, empty).
- The chapter tab shows **"What to look at in this chapter"**: the AI overview's risks whose
  paths fall in the chapter's files, each with its level and text. A risk is
  `{path, level, why}` with no line, so (*my call*, the overview stays unchanged): the link
  opens the file at its first hunk; **Comment…** opens a design comment pre-filled with
  `path` and the risk; **Ask agent** (§4) quotes the path and the risk text, not code. The
  accessor returns every risk of a file (today `model.risk(for:)` returns the first; the
  file-row badge keeps showing the highest level). With no overview for the current tree
  the section shows one line and **Run AI overview** (the existing `startOverview`).
- *Keeping AI chapters from swapping mid-review:* `offerAIChapters` today holds AI chapters
  back (banner **Use AI chapters**) only when checklist checks exist on the chapters on
  screen. With the checklist gone that test never fires, so it switches to *any file of the
  chapters on screen marked Viewed in this round, or any comment in them*. Same intent —
  don't reshuffle what the owner already started — on the signal that still exists
  (*my call*).
- *My call — UI-only removal:* the Go side stays: `review context` still returns `lenses`,
  the AI overview still receives the lens ids (house rules from `.watchtower/review.md`
  still shape its risks), Find Repeats / Accept still write `.watchtower/review.md`
  (REVIEW-01 untouched), `get_review` still prints a lens tag when a comment has one, and
  Wrap-up's intent marks still use `review_checks`. A later cleanup can drop the dead
  pieces; this change keeps the data path stable.

### 4. Chat with the session agent inside the review (#962)

- A right-hand panel in Branch review hosts the session's Workchat (`SessionChatView` for
  the round's session, through `WorkbenchesViewModel.workchat(sessionID:)`). *My calls:* it
  is open by default at 360 pt, collapsible with a toolbar button and ⌥⌘C (check for a
  clash before picking the final key), its open/closed state and width remembered per
  workbench; with no `WorkchatModel` (no session control, or the session is gone) the panel
  shows one line "The session is not running" and no composer.
- **Ask agent** is a second Monaco action beside `wt.comment` on both editors and in the
  preview: `wt.ask`, context menu + ⇧⌘A, posting `{type:"ask", side, startLine, endLine}`.
  Swift puts a quote at the top of the shared `WorkchatModel.draft`:
  ``Re `path:31–34` (new side):`` followed by the selected lines in a fenced block (cut at
  40 lines with "…"), opens the panel if closed and focuses the composer. The owner types
  the question and sends; the line goes out through `SessionLineDelivery` `.workchat` under
  PROJ-12's gates as any Workchat message — nothing new on the delivery path.
- The Workchat pane and the review panel of one session share one `WorkchatModel` (one
  draft): accepted, it is the same conversation.
- If the agent edits files while answering, the existing tree-moved banner and Refresh
  apply; nothing new.

### 5. Mark a whole chapter viewed (#963)

- `ReviewChangesModel` gets `setViewed(path, on)` (explicit, beside `toggleViewed`) and
  `markChapterViewed(key)`: every file of the chapter that is not Viewed becomes Viewed
  (one write batch), then `selectChapter` goes to the next chapter after it that is not
  done (wrapping); when every chapter is done it moves to the **Wrap-up** phase.
- UI: a footer bar under the diff in the Chapters phase — "Chapter 2 of 5 · 3 of 4 files
  viewed · **Chapter viewed →**" — and the chapter row's checkbox in the chapter list
  (checked = done; clicking a done chapter un-views all its files, clicking an undone one
  marks them, without moving on). Shortcut ⌥⌘↓ for the button (*my call*).
- A file that changes after the mark loses Viewed by the existing content-sha rule, so the
  chapter becomes undone again — correct, no new rule.

### 6. Approve / Request changes (#964)

**Buttons.** The toolbar's one prominent action becomes two: **Request changes (N)** —
today's Send, renamed — and **Approve**. Approve is disabled while the round has draft
comments (help: "Send or delete the N drafts first"). Once the round is closed the toolbar
shows its outcome instead of the buttons and **Start next round** stays in the ⋯ menu /
the session strip's Review.

**Approve confirmation** (a popover, mockup 3): "Approve <branch>?", what happens next
(the agent gets the line and finishes per its methodology), and what is unfinished: chapters
not viewed (count, lines), Wrap-up items marked Partly / Not done, and the open comments
from earlier rounds (`carried` and `outdated` rows of this round — N counts both). Those
must not vanish unseen (REVIEW-03): the popover lists them and the button reads **Resolve N
and approve**. Unviewed chapters only warn. *My call:* the owner resolves them explicitly
by pressing that button; without the resolve, a `carried` row left in an approved round
would never reach the agent and would quietly re-carry into a later round.

**Storage.** Migration `00154_review_round_outcome.sql` adds
`review_rounds.outcome TEXT NOT NULL DEFAULT '' CHECK (outcome IN ('', 'changes', 'approved'))`
(plain `ADD COLUMN`; no table rebuild, every `status IN (...)` query keeps working).
`db.ApproveReviewRound(round, resolveOpen bool)` is one guarded transaction like
`SendReviewRound`, so nothing can fail half-way: the open round of this workbench becomes
`status='sent', outcome='approved'`; with `resolveOpen` its `carried`/`outdated` rows are
resolved in the same transaction; it writes nothing (`ok:false`) when the round is not
open, belongs to another workbench, has draft comments, has open `carried`/`outdated` rows
and `resolveOpen` is false, or has no session (`session_id` NULL — nobody would finish the
work; the Desktop disables Approve with "The session is gone"). The rule lives in Go, not
only in the UI. `SendReviewRound` sets `outcome='changes'`. Mirrored into `schema.sql`,
snapshot and the Swift test schema regenerated.

**CLI.** `watchtower workbench review approve --round R [--resolve-open]` (same envelope
as `send`: `ok`, `sent`, `line`).

**The line.** New pinned line, Go `reviewdiff.ApprovedLine` + Swift twin, fixture in
`internal/reviewdiff/testdata/lines`:
`Review round #<id> approved — the owner approved this branch; finish it the way your methodology says (read get_review <id> using the watchtower-workbench skill).`
It holds only an id. It is typed only after `approve` returned, through
`SessionLineDelivery` with `LineKey.review(roundID)` — REVIEW-04 extended to Approve (an
amendment of a locked entry: approving this spec is the owner's approval of it; the
entry and its guards gain the approve path, no assertion is relaxed).

**Agent side.** `get_review` on an approved round says `Outcome: approved — no changes
requested` first. The brief's waiting line reads `Review round #N approved → get_review N`
for an undelivered approved round. The `watchtower-workbench` skill's "Review rounds"
section (skill pack version bump) adds: an approved round means the owner accepted the
branch — do the methodology's finishing steps (PR / merge, targets `done`, cleanup,
`finish_session`) without asking for another review. `watchtower-flow` gets the same
sentence where it describes the review step.

**After Approve** the pane shows a green banner "Approved HH:MM · round N closed" plus the
delivery result, as Send does today: "the agent got the line · Open Workchat" only when the
line was typed; when it was held or the session is not running, "the agent will see it in
its next brief" (the brief's `Review round #N approved` line). The pane stays read-only. If the agent changes code afterwards,
Review on the session strip opens a new round as today.

## Constraints

- Desktop conventions: `docs/review/review-rules.md` Swift section; new UI from the design
  kit (`docs/design/desktop-style-guide.md`), `make desktop-shots` before review.
- REVIEW-01…05 hold; REVIEW-04 is amended to cover Approve (above).
- Monaco stays at the pinned 0.57; no network in `diff.html` (CSP unchanged).
- User guide: the Branch review page in `docs/guide/` is updated in the same PR.
- `docs/features/diff-reviewer.md` gets a "Polish (#958)" section.

## v1 limits

- Navigation reads the work tree on disk, not the round's snapshot; after the agent edits,
  a jump can land a few lines off. The preview header says "current files".
- No navigation from the old side.
- The lens data path stays in Go unused by the UI until a cleanup.

## Left to the builder

- Exact component split of the tree and the preview host; where the usages list sits.
- Final shortcut keys after a clash check against the app's menus.
- Plan order: suggested independent lanes — (A) #959 fold + #963 chapter viewed, (B) tree +
  navigation + preview, (C) chat panel + Ask agent, (D) checklist → risks, (E) Approve
  (Go migration/CLI/line → Swift). E and C touch the toolbar; B and C touch `diff.js`.
