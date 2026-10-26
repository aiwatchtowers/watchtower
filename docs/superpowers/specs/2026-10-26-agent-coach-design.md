# Agent coach — Watchtower learns from reviews and sessions and proposes edits to the owner's setup (design, 2026-10-26)

Board: #1120. Brainstormed with the owner in asks #632, #634, #637, #639, #645, #646, #648.

## 1. Intent

Spec reviews work: the owner likes them. The next step is a loop that learns from them, and from everything else the agents get wrong, and makes the owner's agent setup better over time.

The owner's goal is **a boost in their own agentic performance**. They open session analytics to learn two things: **what to change in their instructions** and **which mistakes the agents keep repeating**. Today the Analytics pane (`docs/features/agent-analytics.md`) shows numbers (context weight, time, cost, waiting) and 15 rule-based hints. The owner's words: the information is partly there, but it is unclear what to do with it, and it looks bad. They also said the statistics give useful information, so they should be redesigned, not dropped.

So the analytics stops being a report and becomes a coach: it watches where the agents stumble, turns the repeats into concrete edits, the owner approves or declines each one, and the coach measures whether an accepted edit helped.

## 2. What success looks like (owner, ask #634)

All four, measured per period (14 days against the previous 14):

1. **The owner corrects the agent less.**
2. **A task is faster and cheaper** (hours and $ per task).
3. **The owner is less in the loop** (the agents work longer on their own and ask only when it matters).
4. **Reviews find less** (spec reviews and code reviews find fewer problems in first drafts).

These four numbers are the headline of the screen and the yardstick for every proposal.

## 3. Goals, non-goals, anti-goals

**Goals**

- Collect the signals that already exist but go nowhere (section 5) into one place.
- Turn a repeated pattern into a **concrete proposed edit**: the exact text or setting, in the exact place, with the evidence it came from and the metric it should move.
- **The owner approves every edit** (ask #637). Nothing changes without **Accept**.
- Measure each accepted edit's effect and offer a rollback when it did nothing.
- Redesign the Analytics pane around the four metrics, the proposals, the accepted-edit log, and redesigned statistics (section 8).

**Non-goals**

- Editing files committed to a repository: the repo `CLAUDE.md`, `.watchtower/workflow.md`, `.watchtower/review.md`, skills under `.claude/skills/` (ask #648: the owner chose personal texts, agent settings and Watchtower prompts only; repo files are shared with a team). The existing owner-pressed **Find repeats → `.watchtower/review.md`** in the diff reviewer stays as it is.
- Applying anything on its own, even small things (ask #637: the owner rejected "small things by itself" and "edits and verifies by itself").
- Skill evals (#299) and debug mode (#300) stay separate roadmap items.

**Anti-goals (owner, ask #646). The feature fails if it does either of these, even when it technically works:**

- **Instruction bloat.** If the loop only adds rules, it makes agents slower: the current analytics already show `CLAUDE.md` and rules at 29 % of the session's starting context. The coach must also shrink and remove (section 6.3).
- **Noise.** Proposals about one-off cases, a fresh batch every day, the same declined idea coming back (section 6.4).

## 4. Where edits may land (owner, ask #648)

Only these destinations. A proposal names exactly one.

| Destination | Examples |
|---|---|
| **The owner's personal texts** | the global and per-workbench session instructions, target procedure and chat text (`owner_instructions`, `projects.session_instructions` / `target_procedure`, `docs/features/agent-instructions.md`); the personal methodology overrides (migration 00123, `internal/workbenchmethod`); the owner's `~/.claude/CLAUDE.md` |
| **Agent settings** | permission allow rules, hooks, the ask level (Chat / Quick / Full), turning off a skill that is listed but never used |
| **Watchtower's own prompts** | prompt-store overrides (`internal/prompts`, Settings → Prompts), e.g. the spec reviewer's prompt learning from the findings the owner keeps dismissing, so it stops finding what the owner does not care about |

**Agent settings in v1 (my call, from ask #648's "no repo files"):** only places that are not committed to a repository — user-level Claude Code settings (`~/.claude/settings.json`: allow rules, hooks, disabled skills), the ask level, and the personal methodology overrides in Watchtower's own tables. A project-level `.claude/settings.json` is a repo file and is never touched; a project-local, gitignored `settings.local.json` may be, if the builder confirms it is ignored in that folder.

**Watchtower prompts:** the spec reviewer prompt is already in the store (`SpecReview`, `internal/prompts/defaults.go`); edits are prompt-store overrides, the same rows Settings → Prompts edits.

**`~/.claude/CLAUDE.md` (my call):** in scope, but built as the last, separable task of the loop so it can be cut without touching the rest. It is outside the workspace and the owner edits it by hand, so the write is an exact-text edit that is refused when the expected before-text is not found.

If a destination turns out not to be writable safely in v1, leave it out and say so in the feature note, do not substitute a repo file.

## 5. Signals

**My call** (the owner did not choose the list; these are the ones that exist today):

| Signal | Source today | Feeds metric |
|---|---|---|
| Spec review findings and the owner's marks on them | `spec_reviews.result`, `spec_review_marks` (ok / comment / viewed) | Reviews find less; also the spec reviewer's prompt |
| Code review comments | `review_comments`, `review_rounds` (diff reviewer) | Reviews find less |
| The owner correcting the agent | owner turns in the session feed (`internal/sessionfeed`, the same input `phaseInstructionSuggestions` already mines), interrupts and rejections (`agentreport` trouble block) | Corrects less |
| Waiting for the owner, asks | `agentreport` H4, `owner_asks` | Less in the loop |
| Repeated failures, denials, slow repeats, context waste | `agentreport` hints H1–H7, C1–C3, S1, T1–T3 | Faster and cheaper |

**A "not useful" mark on spec review findings (owner, ask #651).** Today `spec_review_marks.state` is only `ok | comment | viewed`, which cannot tell "this finding is noise" from "seen". The owner chose to add one more mark, **Not useful**, a single button on a finding in the findings screen (and the phone's line, if it shows findings). It needs a migration expanding the `state` CHECK (the table-recreation dance), the Desktop writer, an amendment to SPECREVIEW-*, and `SpecReviewAnswer` must not send it to the agent as a comment. Not-useful marks are the signal for spec reviewer prompt edits; a comment mark counts as "a real problem".

Owner text stays on stdin, never argv, and follows FILES-01 (logs carry ids and counts, never text), as the instruction miner does today.

## 6. The proposal engine

### 6.1 Shape of a proposal

- **What:** a short title in the owner's language (`digest.language`, as `agentreport/i18n.go` does).
- **Where:** one destination from section 4.
- **The edit:** the exact before/after text, or the exact setting change. Never a vague direction like "be more careful".
- **Why:** the pattern, how many times, in how many distinct sessions / specs / review rounds, and how the owner reacted (e.g. "accepted 5 of 6 such findings").
- **Evidence:** links to the asks, sessions, review rounds (capped, as hints cap evidence today).
- **Moves:** which of the four metrics it should move, and the narrower measure it will be judged by (e.g. "findings of this kind per spec").
- **Actions:** **Accept**, **Edit then accept**, **Decline**.

### 6.2 Cadence and gates — my calls

- One pass a week, in the daemon (a phase like `phaseInstructionSuggestions`, stamp file, a failed run retried next time, `planusage.NearLimit` skips it, the model call outside any write transaction).
- A pattern becomes a proposal only with **at least 3 occurrences in distinct sessions / specs / review rounds**.
- **At most 3 open proposals at any time**; the weekly pass adds only up to that cap, best first (ranked by the expected effect on the four metrics).
- **A declined proposal never comes back** (fingerprint, plus the prompt sees declined ones, as the instruction miner does).
- Validation in Go, not trusted from the model: the evidence ids must exist, the counts are recomputed, the destination must be an allowed one, the edit must apply to the current text.

### 6.3 Against bloat — my calls

- Every text destination has a **budget** (a size cap, in tokens or runes; `instructions.MaxRunes` = 1000 already caps owner texts). A proposal that would push a text over its budget must come with a cut in the same edit.
- The coach also proposes **removals and merges**: duplicates and near-duplicates across the owner's texts, and its own earlier edits whose effect verdict is "no effect" (section 7).
- Watching whether a pre-existing rule "fires" is not possible in general; v1 proposes removal only for duplicates and for its own no-effect edits.

### 6.4 One stream, not two — my call

The daily instruction miner (`instruction_suggestions`, Home's "You keep saying this" card, Settings → System → Workbench) is the same idea with one signal. Two streams of suggestions would be noise. The coach absorbs it: the miner's owner lines become one of the coach's signals and its suggestions become coach proposals, under the same cap. Existing open `instruction_suggestions` rows are carried over; added and dismissed ones keep blocking their fingerprints. The `remember:` / `запомни:` direct path (`instructions remember`) stays, it is the owner's own action and not a suggestion. The builder decides whether this is a migration of the table or a new table plus an import, following `add-migration`.

## 7. Effect and rollback

- On **Accept** the coach stores the before and after text or setting, and the baseline of the proposal's narrow measure over the previous 14 days.
- After 14 days the edit gets a verdict: **works** (the measure improved past a threshold), **no effect**, or **too little data** (fewer than a minimum number of sessions / specs since; keeps waiting, gives up at some point). Thresholds are the builder's, named constants like the hint thresholds.
- **Roll back** restores the stored before-state when the current text still contains the after-state; when the owner has edited the text since, rollback shows the diff and the owner confirms.
- A "no effect" edit becomes a removal proposal (section 6.3) instead of sitting there.
- Correlation, not causation: the screen says "since this edit" and never "because of this edit".

## 8. The screen (owner, ask #645: the B + A + C mix, plus the statistics)

The workbench's Analytics pane, top to bottom. Mockups shown to the owner: `.superpowers/brainstorm/…/layout.html` and `layout-v2.html` (gitignored, throwaway).

1. **How it's going** — the four metrics (section 2), each with its value and the trend against the previous 14 days. Tapping one shows what drags it down.
2. **Proposed edits** — at most 3 cards (section 6.1). Each says which metric it pulls.
3. **Accepted edits** — the log with each edit's verdict (section 7) and **Roll back**.
4. **Statistics** — today's blocks (time, money, context, trouble), **redesigned, not removed** (the owner said the information is useful). Each block leads with one plain-language sentence of what it means, and the numbers sit under it. Today's "main thing" card and the rule-based hints are no longer a separate headline; a hint either becomes a proposal (when it has an edit in an allowed destination: allow rules → agent settings, never-used skills → agent settings, `CLAUDE.md` weight → a cut proposal for the owner's own texts) or stays as a line in its statistics block.

Built from the design kit (`WatchtowerDesktop/Sources/DesignKit/`, `docs/design/desktop-style-guide.md`), checked with `make desktop-shots` before review. Accept / Decline also reachable from Home's Workbench zone, where the instruction-suggestion row is today (section 6.4).

Scope **(my call)**: the pane is per workbench, as today; proposals for global destinations show in every workbench's pane and on Home.

## 9. Order — my call

This is two pieces of work in one spec, built in this order:

1. **The loop** — metrics for the four numbers, signal collection, the weekly proposal pass with its gates, accept / decline / edit, the effect verdict and rollback, a CLI with pinned `--json` keys (as `instructions` and `agents report` have), the miner folded in.
2. **The screen** — the redesigned Analytics pane over the loop's data, Home's card.

The loop is useful through the CLI before the screen lands; the screen without the loop would be the same numbers in a new layout.

## 10. Left to the builder

- Exact definitions of the four metrics from the data that exists (e.g. what counts as "a correction": interrupts + rejections + owner turns the weekly pass classifies as corrections; what "a task" is: a leaf target, as `agentreport` tasks attribution does). Write the definitions in the feature note.
- **My call on "reviews find less":** count the findings of a spec's **first** review round only (later rounds find less because the owner already fixed things), and code review comments of a session's first review round; keep those counts as numbers at the time of the round, since `spec_reviews.result` is replaced by re-runs.
- **My call on scope of the numbers:** the four metrics on the pane are the workbench's; a global edit's effect is measured over all workbenches, a workbench edit's over its workbench.
- **My call on rollback storage:** the whole before and after text (or setting) is stored, so an empty before-text or a pure deletion rolls back the same way.
- **My call on missed weeks:** the weekly pass runs at the next sync once 7 days have passed since its stamp, like the instruction miner; no catch-up of missed weeks.
- The model tier for the weekly pass (writing the edit text likely needs the strong tier; the miner uses light), and the prompt (`add-ai-prompt`, both providers).
- Storage (`add-migration`), CLI names, the effect thresholds, the budgets' numbers.
- Behaviour inventory: the touched contracts (PROJ-22 for instructions, AGENTLOG-*, SPECREVIEW-*) get amendments; ask the owner before weakening any guard test.
- The user guide page (`docs/guide/`) for the new pane.

## 11. The calls I made (not the owner's)

- The signal list (section 5); the owner added the Not useful mark (ask #651).
- Weekly cadence, the 3-occurrence floor, the 3-open cap (section 6.2).
- Text budgets, removal and merge proposals, removal only for duplicates and the coach's own no-effect edits (section 6.3).
- Folding the daily instruction miner into the coach (section 6.4).
- 14-day effect window, the verdict states, rollback rules (section 7).
- Hints becoming proposals or statistics lines; per-workbench pane with global proposals shown everywhere (section 8).
- Loop first, screen second (section 9).
