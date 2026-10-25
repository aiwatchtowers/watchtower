# Spec review — a reviewer agent checks a spec or plan against what was agreed (design)

Board target #1046. Brainstorm: owner asks #582–#588 (2026-10-25).

## Why

The owner does not read specs. They are too long, so the owner reads the summary at the top and approves. What the owner actually wants to know before approving is:

1. their idea is the one being built;
2. every point agreed in the discussion is in the document as agreed;
3. there are no blind spots;
4. where the task has screens, the work follows the design.

None of these needs reading the spec end to end. They need a **comparison of the spec with the discussion**, done by someone other than the author. The owner expects other users have the same problem.

## What it is

When an agent files a review ask for a spec or a plan, Watchtower immediately starts an **independent reviewer agent**. The reviewer is not the author, sees the code read-only, and compares the document with the agreements. When the owner opens the ask, they get a screen shaped like the Deep diff review (**Meaning → Chapters → Wrap-up**) built from the reviewer's findings, instead of today's document-with-margin-comments view. The owner marks findings, comments where needed and sends a round to the author or approves. A **Read the spec** button always opens the full text.

## Decisions (owner's)

- D1 (#583, #586): the reviewer is a real agent run, modelled on the diff review, not a summary of the spec.
- D2 (#583): the reviewer reports four things: agreements → how each is written in the spec; what the author decided alone; blind spots; checks by task type. Design is one of those checks, active only when the task has screens ("design is a particular case, tasks differ").
- D3 (#584): agreements come from all four sources: the session conversation, the owner's answers to asks, the target with its comments, and an explicit decisions list kept by the author.
- D4 (#586, #587): the screen looks and works like the existing Deep code review, block by block. The summary (mockup A) lives in Meaning and Wrap-up, the per-finding cards (mockup C) in Chapters. A chapter is a block of the spec, not a file.
- D5 (#587): it opens in place of the current review ask view, with a **Read the spec** button.
- D6 (#588): the reviewer starts as soon as the ask is filed, so the result is ready when the owner opens it.
- D7 (#588): specs and plans both get it. For a plan, the agreements are the spec's requirements and the check is "every point of the spec is covered by a task".
- D8 (#588): the reviewer may read the repository, read only.

- D9 (#589): the design lens compares the document with the mockups agreed in the brainstorm and with the style guide. The author commits the agreed mockups next to the spec, in `docs/design/mockups/<feature>/`, and the spec links to them.

Mockup: `docs/design/mockups/spec-review/flow.html` (the agreed screen; its example findings are invented).

## Goals

- The owner can approve a spec with confidence without reading it, in a few minutes.
- Every agreement from the discussion is shown with its status: **as agreed**, **differs**, **missing**.
- Everything the author added without discussion is listed as **decided alone**.
- Blind spots are named, including ones only visible in the code (e.g. "the spec covers Go logs, but Swift code also writes message text to a log").
- The owner's verdict and comments reach the author through the existing ask answer, so the author's loop does not change.

## Non-goals

- No reviewer for other documents (guide pages, notes). Their review ask stays as today.
- The phone keeps today's review screen in v1 and gets only the reviewer's one-line summary (see Mobile).
- The reviewer does not edit the spec and does not message the author. Only what the owner sends reaches the author.
- No automatic approval, ever.

## Anti-goals (failure even if it technically works)

- **Another wall of text.** If the reviewer's output takes as long to read as the spec, the feature has failed. Every finding is one or two lines plus quotes.
- **Invented quotes.** A finding that cites words the owner never said, or a spec line that does not exist, destroys trust. Quotes are verified mechanically (see Validation).
- **`ask_owner` gets slower or can fail because of the reviewer.** Filing the ask stays instant and independent of the reviewer.
- **A broken reviewer blocks the review.** If the reviewer fails, the owner still reviews the document the old way.

## How it works

### 1. Which asks get a reviewer

`ask_owner` gets an optional `doc_type`: `spec` | `plan` | `other`. The skill pack tells the agent to set it. If it is missing, Watchtower infers it from the path: `/specs/` or a `-design.md` name → `spec`, `/plans/` → `plan`, anything else → `other`. Only `spec` and `plan` start a reviewer. *(My call: an explicit field with path inference as the fallback, so older agents and other folder layouts still work.)*

### 2. Starting the reviewer

Filing the ask records a queued spec review for it and starts the reviewer as a detached `watchtower` process in its own process group, so it outlives the MCP server. `ask_owner` returns at once and its result gains `spec_review: "queued"` (or `"skipped: <reason>"`). The daemon sweeps for queued reviews that never started and for running ones whose process is gone, so a lost start is picked up within a cycle. The exact launch mechanism is left to the builder. The requirements are: it starts within seconds, it never blocks or fails `ask_owner`, and it survives the session ending.

If the Claude plan is near its limit (`planusage.NearLimit`), the review is skipped with that reason, and the screen offers **Run reviewer**. The same button retries after a failure.

### 3. The reviewer run

- **Agent.** The app's AI provider (`ai.provider`, the one `reviewai` uses), not the author session's agent kind. Independence comes from a fresh context that never saw the author's reasoning, not from a different model. *(My call.)* The `planusage.NearLimit` skip applies only when that provider is claude. Strong tier, through the existing read-folder mode (`ai.Client.SetReadFolder`: Read/Grep/Glob/LS only, no shell, no writes, no folder hooks; codex `--sandbox read-only`). Its cwd is the session's folder (its worktree if it has one). A time budget of 10 minutes and a turn cap. *(My call, exact numbers tunable.)*
- **Prompt.** A new prompt `workbench.spec_review` in the prompt store (editable in Settings → Prompts), working on both providers.
- **Inputs**, assembled in Go and passed as data, not instructions:
  - the document snapshot from the ask (`doc_snapshot`);
  - the session conversation from `internal/sessionfeed` (owner lines, agent text, ask answers; no tool output), for the session that filed the ask;
  - the owner's answers to every ask of that session and of the ask's target;
  - the target (text, intent) and its comments, plus the parent group's intent;
  - the document's **Decisions** section (see 6);
  - the mockups the document links under `docs/design/mockups/` (HTML read as text; the reviewer may also open them itself with Read), and `docs/design/desktop-style-guide.md` when the design lens is active. A screen named in the conversation as chosen but with no committed mockup is a blind spot finding;
  - for a plan: the spec it implements (the path named in the plan header or on the target), read from the folder;
  - for a re-round (`previous_ask_id`): the previous round's document, findings and the owner's comments, so the reviewer can say which comments are resolved.
  
  Long inputs are capped (keep the newest conversation, never cut the document). Caps are the builder's call. A capped input is noted in the result ("the conversation was trimmed to the last N entries").
- **Output** (JSON, validated in Go):
  - `idea`: the owner's idea in their own words (a quote), the document's goal (a quote), and a verdict `matches` | `narrowed` | `differs` with a one-line note;
  - `agreements[]`: `{text, status: as_agreed|differs|missing, source: {kind: conversation|ask|target|comment|decisions|spec, ref, quote}, where: {heading, quote}?, note}`;
  - `decided_alone[]`: `{text, where: {heading, quote}, note}`;
  - `blind_spots[]`: `{text, where?: {heading, quote}, evidence?: {path, line}, why}`;
  - `checks[]`: per chapter, the lens questions that apply and the reviewer's answer `ok|concern|n/a` with a note. Built-in spec lenses (every promise has a task or acceptance criterion, touched inventory contracts are named, migrations and dual paths are named, failure paths are covered) plus the **design** lens, active only when the document or the target involves a screen, plus the folder's own lenses from `.watchtower/review.md` that apply to documents;
  - `resolved[]` on a re-round: the previous comments with `resolved|open`;
  - `summary`: one or two sentences.

### 4. Validation (no invented quotes)

Go checks every quote before it stores the result:

- a `where.quote` must occur in the document snapshot under the named heading;
- a `source.quote` must occur in the input it names (the conversation entry, the ask answer, the comment);
- an `evidence.path` must exist in the folder.

Exact substring after whitespace normalisation. *(My call. If that proves too strict for the models, the builder may allow a fuzzy match, but never a quote that is not there.)* A finding that fails is dropped and counted ("2 findings were dropped: quote not found"). If the JSON is bad or the summary is empty, the run fails with a reason. Caps on counts and lengths follow `reviewai`'s style.

### 5. Storage

New migration:

- `spec_reviews`: one row per ask (`ask_id` primary key): status `queued|running|done|failed|skipped`, reason, the validated result JSON, model, provider, doc sha, started/finished timestamps, dropped count.
- `spec_review_marks`: the owner's progress, `(ask_id, item_key)` → state `ok|comment|viewed` plus the comment body, so closing the drawer keeps progress (like `review_checks`).

Item keys are derived from content (the finding kind plus a hash of its normalised `text` and anchor), not from the position in the list. A re-run (**Re-run reviewer** or **Run reviewer**) replaces the result, and marks whose key reappears carry over. Marks whose finding is gone are shown once in Wrap-up under "from the previous run", together with any comment the owner wrote, so a half-finished pass is never lost silently. *(My call, same idea as the diff review's carry-over.)*

Both are mirrored into `schema.sql`, the test schema and `TestAllTablesExist`, the usual way. A deleted ask deletes its rows.

### 6. The Decisions section (the explicit list)

The author keeps a `## Decisions` section in the spec: one line per decision, with its source (`ask #N`, or "conversation"). This is the "explicit decisions list" of D3. It lives in the document, so the owner sees and corrects it in the same review, and no new file or screen is needed. *(My call, chosen as the simplest form.)* The reviewer checks it both ways: a decision in the list with no trace in the sources, or an agreement in the sources missing from the list, is a finding. A spec without the section is still reviewed; the missing list is itself a blind spot finding.

### 7. The screen (Desktop)

It replaces the review layout of `OwnerAskDrawer` for asks whose spec review exists. It reuses the Deep review components (`ReviewPhaseStrip`, the chapter list, the checklist view), not their Changes-pane data model.

- **Header:** the ask title, the reviewer's state, **Read the spec** (opens today's `OwnerAskReviewBody` with margin comments, so commenting on raw text still works) and **Re-run reviewer**.
- **Meaning:** the owner's idea next to the document's goal with the verdict, the Decisions list, the counts (agreements by status, decided alone, blind spots), and the summary. On a re-round: what changed and which of the owner's comments are resolved.
- **Chapters:** the document's `##` sections (deeper levels fold into their `##`; a plan's tasks are its chapters). Each chapter shows its findings as cards: what you said / what the document says / the reviewer's note, with **Fine as is** and **Comment**. Under them sits the chapter's checklist, then **Viewed**. Chapters without findings are listed with a ✓ and can be marked viewed in one click. The excerpt of the section is shown collapsed above the cards.
- **Wrap-up:** every agreement, decision-alone and blind spot with the owner's mark, each unmarked item flagged. Then **Send round to the author** (verdict `changes`) and **Approve** (verdict `approved`). Approve with unmarked items asks once to confirm.

States: while the reviewer runs, the screen shows the progress line and **Read the spec**, so the owner can still review the old way. If it fails or was skipped, the screen shows the reason with **Run reviewer** and today's view below.

### 8. The answer to the author

The owner's marks become the existing answer JSON, so `get_ask`, `answer_text` and the author's loop stay as they are:

- each **Comment** on a finding becomes a `comments[]` entry anchored to the finding's `where` (heading + quote), with the finding's one-line text prefixed to the owner's body;
- a **Comment** on a finding without a spec anchor (a missing agreement, a blind spot) is anchored to the chapter heading;
- items marked **Fine as is** are not sent;
- the note field stays.

The author never sees the reviewer's findings the owner did not comment on. *(My call: the owner is the filter.)*

### 9. Plans

The same flow with `doc_type: plan`. The plan's spec takes the place of the discussion as the main source. `agreements` are the spec's requirements, and their status says whether a task covers each one (`as_agreed` = covered as specified). Chapters are the plan's tasks. The conversation and asks remain sources for anything agreed after the spec.

### 10. Mobile

In v1 the phone keeps `ReviewAskView`. The ask slice gains the reviewer's one-line summary and counts, shown above the document. The full screen is a later step.

### 11. Skill pack and guide

- `watchtower-flow` and `watchtower-workbench` (pack version bump, fixtures updated): set `doc_type` on review asks, keep a `## Decisions` section in every spec with sources, commit the mockups agreed in a brainstorm to `docs/design/mockups/<feature>/` and link them from the spec, and expect the round's comments to come from the owner's pass over the reviewer's findings.
- The guide page for owner asks and reviews describes the new screen.

## Contracts

- New inventory entries (SPECREVIEW-01..): the reviewer never writes the folder or the database outside its own rows; `ask_owner` never waits on or fails because of the reviewer; every stored quote is found in its source; a failed reviewer always leaves the classic review usable.
- PROJ-03 is unaffected (the reviewer only reads) but the guard test should cover the reviewer path too.
- The answer JSON contract (`internal/asks/answer.go`) is unchanged.

## Left to the builder

The launch mechanism of the detached run and the daemon sweep; input caps and the turn cap; how sessionfeed output is serialised for the prompt; the exact built-in lens questions; the fuzzy-match fallback, if needed; the split into plan phases (Go core + CLI, Desktop screen, skill pack + guide, phone line).
