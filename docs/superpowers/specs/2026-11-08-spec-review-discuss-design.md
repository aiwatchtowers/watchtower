# Spec review — a loop that runs while the author accepts fixes, a thread on every finding, and a short summary first (design)

Builds on `docs/superpowers/specs/2026-10-25-spec-review-design.md` (reviewer, result, findings screen), `docs/superpowers/specs/2026-10-26-spec-review-author-loop-design.md` (the hidden author loop), `docs/superpowers/specs/2026-10-28-spec-review-severity-design.md` (severity, footer verdicts) and `docs/features/spec-review.md` (what shipped). Contracts SPECREVIEW-01..05 in `docs/inventory/spec-review.md` hold unless this document amends them by name. Board #1036.

## Why

Three things get in the owner's way today:

1. **The loop stops at 3 rounds even when it is still useful.** `MaxLoopRounds` is 3; whatever is open then reaches the owner as "Not settled in 3 rounds", even when the author was still accepting the reviewer's fixes and one more round would have closed it.
2. **A finding the owner does not understand is a dead end.** A card says, for example, "a chapter that fails again and again blocks the summary forever". The owner does not see why a chapter could fail at all, and the only answers are **Fix** and **Skip**. There is nowhere to ask "why?", and nobody to ask: the reviewer is a one-shot run that has ended, and the author would defend its own text.
3. **The owner has no short version of the document.** Specs are long. The owner wants the document as a handful of theses first, each one open to questions, and to go deeper only where they want to.

Also, the buttons on a card do not depend on what the card is: an **As agreed** card ("the document matches what you said") offers **Fix**, which makes no sense — there is nothing to fix, at most something to talk about.

## Decisions

- D1 (conversation): the loop runs as long as the author keeps accepting the reviewer's fixes, not a fixed 3 rounds; it must not drift into made-up problems.
- D2 (ask #571, "all fine, go"): the guards against drift are: a new finding only on changed text (or a blocker, as today); from round 3 a new finding must be major or blocker; a finding that was closed (fixed, skipped by the owner, lost in a dispute) never comes back; every finding quotes its source; and an emergency ceiling as a fuse, shown to the owner when it trips.
- D3 (asks #566, #568): a finding card gets a thread — **Discuss** — with an agent that has the reviewer's context and reads the code; the owner asked "who helps more?", and the answer agreed is a third agent, not the one-shot reviewer and not the author.
- D4 (conversation): that thread agent can ask the author in the session itself to clarify, without the owner relaying.
- D5 (conversation): the card's buttons depend on its kind; **As agreed** has nothing to fix — it gets **Discuss** and **Not useful** only. The per-kind table of §2 (including **Comment** folding into **Discuss**) was shown in the conversation and answered "fits".
- D6 (conversation): new findings can come up while the owner talks with the agent in a thread; the agents can add them as new items. *(My call on top: the agent proposes, and the item is added by the owner's one press, so a thread cannot fill the list on its own — §3.)*
- D7 (ask #579): a short summary is the first screen of the review: 3–5 lines of what is built and why, then 5–10 theses, each tied to its section of the document and open to **Discuss** with the same agent; it lives inside the review, not as a separate document.
- D8 (asks #582, #586): after the owner answers with changes, the author's next round goes through the hidden reviewer ↔ author loop again, and the owner sees the document after it, with only what is disputed.

## Goals

- The author loop ends when it stops being productive, not at a fixed count, and still always ends.
- A late round can only add something serious about text that changed; nothing closed resurfaces.
- The owner can question any finding or thesis in place, get an answer grounded in the document and the code, and turn the conclusion into a fix, a skip, or a new finding in one press.
- The owner can read a spec or a plan as a one-screen summary before the findings.

## Non-goals

- The phone: no thread, no summary screen (v1 limit of the spec review stays: a one-line status).
- Discussing the whole document in free form outside a finding or a thesis — the main AI Chat already does that.
- Changing what the reviewer itself is allowed to do (SPECREVIEW-01: it never edits the document and writes only its own row).
- `doc_type: other` reviews: unchanged.

## Anti-goals (failure even if it technically works)

- **Made-up problems.** Rounds that go on because the reviewer invents new issues each time and the author politely "fixes" them.
- **A loop that never reaches the owner.** Whatever happens, the ask arrives.
- **A thread agent that edits things.** It reads, asks, explains and proposes; the document and the code stay untouched, and a new finding exists only after the owner presses for it.
- **A thread that interrupts the author's work.** A question to the author must not break a turn in progress or eat the owner's typed text in the terminal.
- **A summary that says what the document does not.** Every thesis points at real text; a thesis that cannot is dropped.

## How it works

### 1. The loop runs while the author accepts fixes

**Continue rule.** After round R, the next round runs when round R's verdicts confirmed at least one finding the author answered with an explicit `fixed` reply (resolved after it) **and** something is still open. A missing reply still counts as `fixed` for the ledger (SPECREVIEW-05 unchanged), but it does not keep the loop going *(my call: otherwise a silent author whose text drifts would run the loop to the fuse)*. Otherwise the loop ends:

- nothing open → `loop_end = settled` (as today);
- items open, but round R confirmed no fix (the author only disputed, or its fixes did not hold) → new `loop_end = stalled`; the open items reach the owner like today's unsettled ones (Disputed / Not answered by the author).

**Emergency ceiling.** `MaxLoopRounds` becomes a fuse, 8 *(my call: high enough never to be the normal exit, low enough to bound cost; the builder may tune it in code, not per owner)*. Reaching it ends with the existing `loop_end = cap` (SPECREVIEW-04's "cap, 3 rounds" text is rewritten), and the owner's screen says so in its own line ("The reviewer and the author were still going after 8 rounds"), separate from a normal end.

The per-round `AuthorTimeout` (30 min) and every other exit (`reviewer_failed`, `session_gone`, `timeout`, Show Now) stay as they are.

**Guards against drift** (all in Go, on top of the prompt; a prompt rule alone is not enough):

1. *Changed text only:* from round 2 a new finding must have its where-quote inside text changed since the previous round's document snapshot, or be a blocker. Today this is a prompt rule only (`review.spec`); this spec moves it into `Parse`: diff the previous round's `DocSnapshot` against this one and drop a non-blocker new finding whose where-quote lies wholly in unchanged text (counted as "on unchanged text"). A new finding with no where-quote (a missing agreement, a blind spot) passes from round 2 only when it quotes a source that is new since the previous round (an owner answer, a thread line, a new ask) or is a blocker *(my call: an old source that produced no finding before is not news)*.
2. *Rising floor:* from round 3 a new finding below `major` — including one with no severity *(my call: empty counts as minor)* — is dropped by `Parse` and counted in `dropped` with the reason "minor finding after round 2". Carried items keep the severity they were raised with.
3. *Closed stays closed:* the loop keeps a closed list — keys resolved after `fixed`, keys the owner skipped (§2), keys the owner settled for the author in a dispute, and keys dismissed in a thread. The reviewer's prompt carries it as "already decided, do not raise", and `Parse` drops a new finding whose key is on the list, or whose where-quote and kind match a closed item's (a reworded repeat), counted as "already decided".
4. *Quotes* (exists, SPECREVIEW-03): a finding whose quote is not in its source is dropped.

The rising floor and the fuse count the rounds of one loop: a new loop after the owner's answer (below) starts again at round 1, so text the author rewrites for the owner can draw minor findings in its first two rounds. What carries along the whole review chain of one document (the asks linked by `previous_ask_id`) is the closed list and the changed-text baseline (the previous round's snapshot) *(my calls)*.

**A new loop after the owner's answer (D8).** Today, once the owner has the review (`loop = 'owner'`), the author's re-round is a classic visible review. Instead, when the owner answers **Request changes** (`changes`), the author's next round (`previous_ask_id` = the answered ask) starts a new hidden loop:

- its round 1 opens with the owner's items as open items for the author: every comment mark (Fix, with or without a comment, and margin comments) and every finding the owner added from a thread (§3). The reviewer checks them like any open item, so a fix the owner asked for is verified before the owner sees the document again;
- everything the owner closed (Skip / Checked, Author is right) is on the closed list from the start;
- the loop ends by the same rules (§1), and the owner gets one ask again, with what is disputed and what was fixed — including whether each of their own items was fixed.

The same conditions as today decide whether a loop can start at all (a spec or plan, a Watchtower session, a reviewer on the surface); when one fails, the re-round is a visible review as today. **Approve** with fixes (`approved` with comment marks) keeps today's behaviour: the author applies them and carries on, no new review. SPECREVIEW-04's "the owner gets one ask per loop" stays true per loop; what changes is that a loop can follow the owner's answer, and that text is amended.

`get_spec_review` keeps `max_rounds` (now the fuse); its `hint` stops saying "last round" on round 3. Every "round R of 3" on the Desktop (the session line in `SpecReviewLoopCenter`, the stack's **Reviewer and author** row) becomes "round R". The `review.spec` prompt version goes up.

### 2. The card's buttons depend on what it is

| Card | Buttons |
|---|---|
| **As agreed** agreement | **Discuss**, **Not useful** |
| **Differs** / **Missing** agreement, **Decided alone**, **Blind spot**, **Check** with a concern | **Fix**, **Skip**, **Discuss**, **Not useful** |
| **Check** without a concern (something to verify) | **Discuss**, **Checked** |
| **Thesis** of the summary (§4) | **Discuss** |
| Loop cards (Disputed: **Reviewer is right** / **Author is right**; Fixed by the author: **Reopen**) | as today, + **Discuss** |

- **Comment** as a separate button goes away where **Discuss** appears: a comment for the author is what a thread's **Fix** sends (§3). A picked Fix keeps **Add Comment** for a one-line note without a thread.
- **Skip** is today's **Fine as is** under one name everywhere: the same `ok` mark, sent to the author as today ("keep as is"), no new mark state and no table rebuild *(my call)*. An `ok` mark — old or new — puts the key on the closed list.
- **Checked** is the same `ok` mark under a label that fits a check.

### 3. Discuss — a thread on a finding or a thesis

**What the owner sees.** **Discuss** opens a thread inside the card (the drawer's width; an open thread pushes the cards below it down). The composer is focused. The thread survives closing the drawer and reopening the ask; a card with a thread shows a small "thread · N" line when folded.

**Who answers.** An embedded chat (`EmbeddedChatEngine`, a new `ChatSurfaceSpec`), persisted in the database, one conversation per (ask, item key). The agent is the configured provider at the strong tier with `--read-folder` on the same folder the reviewer read (the session's worktree when recorded, else the workbench folder). Its context on the first turn: the document snapshot the reviewer saw, the finding or thesis with its quotes, the reviewer's whole result (so it knows the neighbouring findings), the conversation and answered asks the reviewer was given, the loop ledger and replies so far. It is told: it did not write the finding; its job is to explain it, check it against the document and the code, and say plainly when the finding does not hold. It has no write tools. On ollama there is no `--read-folder`; the thread works from the data alone and says so once.

**Asking the author.** The agent may ask the author a question when only the author can answer (what was meant, what is planned). It does that by ending a reply with a structured block (same mechanism as the question cards, a new fenced type) holding one question. The Desktop:

- delivers it to the author's session as a typed line, through the same delivery path and rules as the findings line of the loop (held while the hosted sessions reattach, never mid-turn, never over text the owner typed), e.g. `Owner's thread on spec review ask #N asks you: <question> — answer with answer_review_question <id>.`;
- shows "Asked the author…" in the thread;
- when the author answers, appends the answer as a row in the thread and starts the agent's next turn on it automatically, so the agent can finish its explanation.

The author answers with a new workbench MCP tool, `answer_review_question` (`question_id`, `answer` ≤ 2000 runes), on the workbench surface only. It writes the answer row; it is refused for a question that is not open or not of this session. If the session is gone or the author does not answer within 30 minutes *(my call, the same as `AuthorTimeout`)*, the thread gets a line "The author did not answer" and the agent continues without it. At most one open question per thread at a time *(my call: keeps the terminal quiet)*.

Questions are stored in a new table (ask, item key, question, answer, state `open|answered|expired|gone`, times) with **Go as its only writer** *(my call)*: the Desktop files a question through a CLI verb (`watchtower workbench spec-review question --ask N --item K` with the text on stdin; prints the id), the tool writes the answer, the daemon sweep writes `expired`/`gone`. Every state change is a conditional update from `open` (`WHERE state = 'open'`), so an answer and an expiry cannot both land; the loser gets "the question is closed". The Desktop only reads the table (poll while a thread has an open question). The delivered line and the tool are added to the skill pack (the author must know the tool) and to DEV-06's tool list.

**Proposing a new finding.** When the conversation surfaces something the review missed, the agent may end a reply with a second structured block: kind (`differs` / `missing` / `decided_alone` / `blind_spot`), severity, a one-line title, the text, and a quote — from the document or from the owner's own words in this thread — plus the where-quote in the document when it has one. The block shows as a card in the thread with **Add to review**; nothing is added without that press. The press calls a Go CLI verb (`watchtower workbench spec-review add-finding --ask N --thread …` with the block on stdin) that validates the quotes with `Parse`'s own code (whitespace-normalised substring of the document snapshot or of the owner's rows of that thread, read from the database; the owner's thread words are `owner` speaker) and writes the row, or refuses with "not added: quote not found", shown on the card. One implementation of quote checking, in Go *(my call)*. An added finding:

- appears in its chapter (or Other) with the chip **From discussion**, with the usual buttons;
- is stored by Go (the verb above) in a new table beside `spec_review_marks` (ask, key with a distinct prefix, the finding JSON, the thread it came from) so a reviewer re-run cannot erase it; Go is its only writer, the Desktop reads it;
- goes to the author like any reviewer finding: in the owner's answer when marked Fix, and into the next round's open items when the loop runs again (Go reads the table when it builds the next round).

**Ending a thread.** The thread does not need an ending; the card's buttons do the deciding:

- **Fix** on a card with a thread offers the comment field pre-filled with the agent's conclusion *(my call: the agent is asked for a one-paragraph conclusion as a hidden turn when Fix is pressed; the owner edits or clears it)*; the comment goes out as today's comment mark. The Fix mark is written at once and the comment field opens empty; the conclusion fills it when it arrives, unless the owner has typed meanwhile. If that turn fails or waits behind the 3-turn gate for more than 30 s, the field stays as it is with a small "Couldn't draft a conclusion" line; nothing blocks Fix.
- **Skip** on a card with a thread asks for nothing extra; the key goes on the closed list.
- When the agent concludes the finding does not hold, it says so; the owner presses **Skip** or **Not useful**. The agent never sets a mark itself.

**Thread across rounds.** A thread is keyed by the item key along the review chain (§1), not by one ask: a re-round's card with the same key shows the earlier thread and continues it *(my call)*. A thread is deleted when no ask of its chain is left (asks are deleted with their workbench).

**Who runs what.** The daemon's spec-review sweep expires open author questions (30 min → `expired`, session gone → `gone`), so it happens with the Desktop closed. The agent's follow-up turn on an answer needs the Desktop: a running Desktop starts it when the answer lands; otherwise it starts when the thread is next opened *(my call)*.

**Failures.** A thread turn that fails shows the embedded chat's error card with Retry (as every embedded chat); a turn waiting for the gate shows as queued. A question to the author that cannot be delivered (no session) is `gone` at once and the thread says so.

**Limits.** Thread turns count against the embedded-chat gate (3 at once). Each turn is recorded in the LLM usage ledger under a new purpose, `spec_review.discuss`. A thread is available once the owner sees the review (a visible ask, including one opened early with **Show Now**); during a hidden loop the owner sees no findings, so there is nothing to open. A thread on an orphaned finding (gone after a re-run) stays readable under "from the previous run" but takes no new turns.

### 4. The summary — the first screen

The reviewer's result gains a `brief` (3–5 lines: what is built, for whom, and why) and `theses` (5–10). A thesis has: `kind` (`goal`, `decision`, `owner_change` — what changes for the owner —, `non_goal`, `risk`), a one-line text, and a where-quote from the document (validated like any quote; a thesis whose quote is not found is dropped and counted). Its chapter comes from its quote, as for findings. A plan's theses describe the plan (what lands in which order, what is risky, what is left out) *(my call: same shape for plans)*. The existing `summary` and `idea` stay.

The Meaning step opens with the summary: the brief, then the theses grouped by kind, each one line with a disclosure that shows the quoted passage and a link to its place in **Read the spec**, and **Discuss** (§3, same agent, keyed by the thesis key). Below it, the existing Meaning content (idea and verdict, Decisions list, counts). The summary is regenerated with every reviewer run; a thesis key is derived from its kind and normalised text, so a thread survives a re-run when the thesis does.

Theses are not findings: they carry no severity, no marks besides the thread, and never go to the author unless a thread turns into a new finding (§3).

### 5. Mobile

Unchanged: the phone's one-line status. The line's "round R of 3" wording, if any, follows §1.

## Compatibility

- Rows and asks created before this ships keep their behaviour (a loop already running finishes under the old cap of 3) *(my call: no backfill, as with the author loop)*.
- An older Desktop reading a newer result ignores `brief`/`theses`, and threads' findings in the new table (it does not read it). It does not know `loop_end = stalled`: it shows the review as ended early, without an end line — acceptable for the release window.
- The new Desktop gains an end line for `stalled` ("The reviewer and the author stopped making progress: these are still open") and the `cap` line drops its hard-coded "3 rounds" for the real count. The phone's line carries counts only and needs no change.
- New tables and columns follow `CLAUDE.md`'s migration rules (schema.sql, `TestAllTablesExist`, the Swift test schema).

## Contract changes the builder must take to the owner

- SPECREVIEW-04/-05 (the loop) are amended by §1: the cap becomes a fuse of 8, the new `stalled` end, the explicit-`fixed` continue rule, the closed list, and a new hidden loop after the owner's **Request changes** (D8). The amendment is written in `docs/inventory/spec-review.md` in the same PR, citing this spec; no guard test is weakened.
- DEV-06 gains `answer_review_question` (twentieth workbench tool); the skill pack version goes up.
- AGENT-04: the new chat surface's `toolAccess` is explicit and has no write tools.

## Left to the builder

- Exact layout of the thread inside a card, the folded-card line, the proposed-finding card and the summary; build from the design kit and the style guide. No mockups were made in the brainstorm, so the plan's first Desktop task is **screens first**: every new state (summary, open thread, question to the author pending/answered/expired, proposed finding valid/refused, the `stalled` and `cap` lines, the per-kind buttons) rendered on fixtures with `make desktop-shots` and sent to the owner as a review ask before the logic is wired *(my call)*.
- The fenced block names and JSON shapes for "ask the author" and "propose a finding", and their prompt text (shared fixture between Go and Swift if Go reads them).
- How the Desktop stores the thread (existing `chat_messages` via the database store, or its own key scheme) as long as it survives restarts and follows the deletion rule of §3.
- Prompt wording for the reviewer's rising floor, closed list and summary.
- Exact tuning of the fuse (around 8).
