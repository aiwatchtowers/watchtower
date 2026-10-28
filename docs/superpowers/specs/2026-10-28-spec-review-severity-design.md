# Spec review screen — colour is severity, readable cards, comments everywhere, verdicts in the footer

**Board:** #1184 (group #1046). **Builds on:** `2026-10-25-spec-review-design.md`, `2026-10-26-spec-review-author-loop-design.md`.

## Why

The owner opened a finished author loop (v0.26.1) and hit four problems:

1. **Everything is blue.** On **Decide** every card of "Not answered by the author" wears a blue "New in round N" chip, and the picked state "Fix — the author fixes it" is blue too. The chip says where the finding stands in the loop, not how much it matters. The reviewer gives no severity at all, so nothing on the screen can say which finding is serious.
2. **The text reads badly.** Quotes from the document are italic and keep their raw Markdown (`` `exec.Command` ``, `**active**`); labels and Notes are small grey captions; "Changes since #N" is one long paragraph of `;`-joined items.
3. **No way to comment.** In a loop the chapter findings carry no controls at all (`if !model.isLoop`), and on **Decide** a finding marked **Fix** has no place for a comment.
4. **No Request changes.** The footer shows only Dismiss. The loop's only verdict, **Approve**, sits at the very bottom of the scroll, and the answer is always `approved` — an owner who marked five findings **Fix** has to press "Approve" to send them back.

## Decisions

- D1 (conversation): the colour of a finding's chip is its severity, not its kind or its loop status.
- D2 (conversation): severity comes from the reviewer: each finding gets `blocker`, `major` or `minor` (my proposal, accepted with the whole list).
- D3 (conversation): quotes plain (not italic) with a bar on the left, labels and notes more contrast, "Changes since" as a list.
- D4 (conversation): a comment can be left on every finding in a loop: on the chapters and on a finding marked **Fix**.
- D5 (conversation): **Request changes (N)** next to **Approve**, in the footer beside Dismiss.
- D6 (ask #686): all of it in one branch, the Go and prompt part included.
- D7 (conversation): **Approve** is for "nothing to send back": with a comment mark or a margin comment on the ask it is off, and **Request changes** is the way.

## Goals

- One look at a screen tells blockers from nits.
- Every quote and label reads at a glance in dark mode.
- The owner can comment on any finding, in the loop or not.
- The verdict buttons are always visible, whatever step or scroll position.

## Non-goals

- No new verdict, no change to the answer JSON (`internal/asks/answer.go`) or to `SpecReviewAnswer`.
- No change to how the loop runs, its rounds or its exits (SPECREVIEW-04/05 untouched).
- The phone keeps its one-line reviewer status.
- No severity on the idea verdict or on `as_agreed` agreements; checks get one only on `concern`.

## How it works

### 1. Severity from the reviewer (Go, prompt)

- Prompt `review.spec` v3: every finding the owner or the author must act on carries `"severity"`: an agreement with status `differs` or `missing`, every `decided_alone`, every `blind_spot`, every check answered `concern`. The prompt defines the three levels:
  - `blocker` — building as written ships something wrong: a broken promise to the owner, lost data, a missing contract, a path that fails silently;
  - `major` — a real gap to fix before building: a missing case, an unclear behaviour, a task with no test;
  - `minor` — wording, a nit, a nice-to-have.
- `internal/specreview`: `Severity string \`json:"severity,omitempty"\`` on `Agreement`, `DecidedAlone`, `BlindSpot`, `Check` and `AuthorItem`. `Parse` keeps only the three values (lower-cased, trimmed); anything else, and any severity on an `as_agreed` agreement or a non-`concern` check, becomes empty. `Findings` copies it into the author items, so `get_spec_review` and the ledger carry it. Keys (`ag:` …) do not include it. Severity is set when the finding is raised and kept through the loop: a later round gives the item a verdict, never a new severity (the reviewer never re-raises a carried item, `NextRound` keeps the item as it was).
- `testdata/result_keys.golden` and the `get_spec_review` pinned keys gain `severity`. An owner-customised `review.spec` (prompt store) that never asks for severity yields empty severities — the fallback below covers it.

### 2. Chips (Desktop)

- `SpecReviewPresentation.severityBadge(_:)`: `blocker` → **Blocker**, `Tone.error`; `major` → **Major**, `Tone.warning`; `minor` → **Minor**, grey. Empty (an old review, a customised prompt) → no severity chip.
- A finding card's head is: the severity chip (coloured), then the kind and, in a loop, its loop status as one grey chip — "Differs", "Blind spot · New in round 3", "Missing · Not settled". Only severity is coloured. The `Tint.accent` (blue) chip goes away from the spec review screen.
- Without a severity (an old review, a customised prompt) every chip is grey: colour on this screen means severity and nothing else.
- In every list of findings — a chapter, **Disputed**, **Not answered by the author**, **Fixed by the author** — the cards sort by severity (blocker, major, minor, none), stable within a level.
- The counts line on Meaning leads with severity when any is set: "2 blockers · 3 major · 4 minor — 7 as agreed · 1 differs …".
- Picked states ("Fix — the author fixes it", "Reviewer is right …", "Reopened", "Your comment") lose the accent colour: primary text, the icon in secondary.

### 3. Readability

- `SpecReviewQuote`: the quote is upright `.callout` in primary colour, rendered as inline Markdown (code spans monospaced, emphasis applied, no raw backticks or asterisks), with a 2-pt bar in secondary colour on its left instead of quotation marks; the label is `.caption.weight(.semibold)` in primary at reduced opacity rather than `.secondary`. The same applies to the idea card and the "Your comments from the last round" list.
- Notes on Meaning: `.callout` in secondary, not `.caption`.
- "Changes since #N" (`OwnerAskHeaderCard`): a `changes` text with no line break, longer than 200 characters and with three or more `; `-separated parts is shown as a bullet list, one part per line. Anything else — a short line, prose with one or two semicolons, text with line breaks or a Markdown list — is shown as today.

### 4. Comments everywhere

- Chapters in a finished loop: each finding gets **Comment** (and, once written, the comment with **Edit** / **Remove**). **Fine as is** and **Not useful** stay out of the loop. The mark is the same `comment` mark **Fix** writes, keyed by the finding's key, so a finding shown on both **Decide** and a chapter shows one state in both places.
- **Decide**, a card marked **Fix** or **Reviewer is right**: **Add comment** under the picked line (or the comment with **Edit**) writes the body of that same `comment` mark. **Undo** still clears the mark.
- The comment travels exactly as today: `SpecReviewAnswer` turns each `comment` mark into an anchored comment with the finding's text, the reviewer's position and the owner's words.

### 5. Verdicts in the footer

- While the spec review screen is up (any step: Decide, Meaning, Chapters, Wrap-up), the drawer's answer bar shows **Request changes (N)** and **Approve** beside Dismiss. N counts the `comment` marks (each **Fix**, **Reviewer is right**, **Reopen** and **Comment**) plus the margin comments made under **Read the spec**.
- **Request changes (N)** answers with verdict `changes` (today's `SpecReviewModel.send`), disabled at N = 0 with the help "Mark a finding Fix or comment on one first". In a loop this is new: the author fixes and files a re-round, which is a classic visible review (`specLoopStart` already starts no hidden loop after the owner had the ask), so the reviewer checks the fixes and the owner sees the result, with the "Your comments from the last round" resolved/open list.
- The answer reaches the author like any answered ask: typed into the live session, or — when the session has ended — through the brief fallback of the next session on the target (`owner_asks` delivery, unchanged). Nothing new can be lost here.
- **Approve** answers `approved` as today, with today's confirmations (unmarked findings outside a loop; an unanswered dispute after an early end). It is off while N > 0 (D7), with the help "You have N comments for the author — Request changes, or remove them to approve". This replaces author-loop spec §7's "Approve with Reviewer is right is approved with fixes": a Fix is now always a Request changes.
- The buttons inside the scroll — the loop's **Approve** and Wrap-up's **Send round to the author** / **Approve** — are removed, outside a loop too: one screen keeps its verdicts in one place. Wrap-up keeps its summary and note. The answer blocker line (unanswered questions, a too-long note) moves into the bar beside the buttons.
- Keys: ⌘↩ Approve, ⌘⇧↩ Request changes, as in the code review toolbar and the classic review footer — only while no text field has focus. In a comment editor ⌘↩ saves the comment (today's `CommentTextEditor.onSubmit`) and never answers the ask.

## Screens

No mockup was agreed; the screens follow the design kit. Before review the builder adds the changed states to `DesignShotCatalog` and attaches the shots (`make desktop-shots`): a Decide card with each severity and a comment under **Fix**, a chapter finding with **Comment** in a loop, the footer with **Request changes (N)** on and **Approve** off, the footer at N = 0, and "Changes since" as a list.

## Tests and acceptance

- Go `internal/specreview`: `Parse` keeps `blocker`/`major`/`minor` (any case, trimmed), empties anything else, and empties severity on an `as_agreed` agreement and a non-`concern` check; `Findings` copies severity into author items; a carried item keeps its severity through `NextRound`; `result_keys.golden` and the `get_spec_review` key pin include `severity`. Prompt: version 3 and the three level names in the text (`internal/prompts` tests).
- Swift (`Tests/Core` where pure): severity badge mapping and the grey fallback; the severity sort (stable within a level); the counts line with and without severities; the `changes` split rule (short line, prose with two semicolons, text with a line break stay as they are; a long three-part line splits); N counts Fix, Reviewer is right, Reopen, Comment and margin comments; Request changes off at N = 0, Approve off at N > 0; the decoder accepts a result and a ledger without `severity`.
- Keys and placement: a test over the drawer's key routing (the `OwnerAskDrawerKeys` / answer-key seam) that ⌘↩ and ⌘⇧↩ answer the ask only with no text field focused, and that ⌘↩ inside a comment editor calls its `onSubmit` (the comment is saved, the ask is not answered). The removal of the in-scroll buttons is checked by the desktop shots of Decide and Wrap-up (no Approve or Send round in the body) and by the manual acceptance below.
- Acceptance: on a finished loop with mixed severities the owner sees red/orange/grey chips and no blue; can comment on a chapter finding and under a Fix; sees Request changes and Approve at every step without scrolling and none in the body; presses ⌘↩ while writing a comment and gets the comment saved, not the ask answered; Request changes sends `changes` and the author gets it.

## Contracts

- SPECREVIEW-01..05 unchanged. SPECREVIEW-03 (no invented quotes) is untouched: severity is not a quote.
- The `result_keys.golden` and `get_spec_review` key pins change additively (`severity`); DEV-06's tool count is unchanged.
- Go ↔ Swift dual path: the severity values and the "empty when invalid" rule live in Go `Parse`; Swift decodes the field as optional and treats anything but the three values as none.

## Guide

`docs/guide/features/workbench/spec-review.md`: severity chips, Comment on chapters in a loop, Request changes in the footer.

## Left to the builder

- Exact opacity of the labels and the bar width, within the design kit tokens.
- Whether the severity sort lives in `SpecReviewModel` or `SpecReviewPresentation`.
