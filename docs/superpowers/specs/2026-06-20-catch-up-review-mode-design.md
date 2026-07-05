# Catch-Up v2 — Review Mode with Learning Feedback

**Date:** 2026-06-20
**Status:** Design approved, ready for implementation plan
**Owner:** Vadym
**Supersedes:** `2026-06-15-catch-up-summarizer-design.md` (the bulk-clear rollup)

## Problem

The v1 Catch-Up is a "rollup + bulk clear": one big AI call summarizes all unread
items into thematic stories on a single scrolling page, whose primary action is
*mark read* (per-section or all-at-once). It optimizes for shovelling the backlog
out quickly.

That model has two gaps:

1. **No deliberate review.** Skimming a wall of stories and clearing in bulk means
   genuinely important signal gets cleared blind alongside noise.
2. **No learning.** The system never gets better at what it surfaces, how it
   clusters, or how it phrases things. Every catch-up is as good (or bad) as the
   last.

Catch-Up is the one place where the operator sits and reviews the output of *every*
pipeline (digests, tracks, inbox, briefings) at once. That makes it the natural —
the *quintessential* — point to capture the training signal that improves all of
those systems. v1 throws that signal away.

## Vision

A **pure inbox-zero review experience**: themes are reviewed one at a time on a
rich, focused screen; each theme requires a decision; feedback is woven into the
pass and is the primary learning signal for the whole product.

- **Unit of review = a theme** (cross-source cluster over digest/track/inbox/briefing),
  same conceptual unit as v1's `Story`.
- **Bulk clear is removed.** The only way to clear the backlog is to go through
  themes one by one (acknowledge cascades mark-read to the theme's source items).
- **Feedback is an interactive correction loop**, not a passive like-for-later:
  a comment triggers (1) an immediate regeneration of *this* theme and (2) a
  persisted lesson that improves future generations.
- **Catch-Up is the central learning hub.** Feedback on a theme is routed to
  targeted learned-rules for whichever underlying pipeline(s) produced its sources.

## Goals

- Two-panel review UX: a streaming list of themes (left) + a rich single-theme
  review screen (right), with per-theme decisions and auto-advance.
- Themes **stream in one at a time** (outline first, rich narrative per theme),
  so review of the first theme begins while the rest are still assembling.
- Per-theme **feedback (👍/👎 + free-text comment)** as the primary learning signal.
- A **comment-driven correction loop**: regenerate the theme now + derive a
  persisted learned-rule for the right pipeline.
- Persist the session, its themes, review state, and feedback in the DB so a
  restart never loses review progress or captured feedback.
- Graceful behavior on AI failure (per-phase, per-theme) and zero unread.

## Non-goals

- **No bulk "mark everything read."** Removed deliberately (replaced by per-theme
  acknowledge). This is a behavioral reversal of v1 — intentional.
- **No daemon auto-generation.** Generation is on-demand (triggered on opening the
  view); the daemon does not pre-build catch-up.
- **No full regeneration of underlying pipelines from a theme.** Regen rebuilds
  only the catch-up layer (cluster/narrative/priority) over the same source data;
  the underlying digest/track improves on its *next* scheduled run via learned-rules.
- **No automatic editing of prompt-template files in MVP.** Persisted learning is
  data-only (learned-rules). Template-edit-as-diff is a later evolution (see §8).
- **No read-tracking for targets/calendar/people.** Targets appear only as a
  read-only context line, as in v1.

## Resolved decisions (from brainstorm)

1. **Bulk clear** → removed; pure inbox-zero, per-theme acknowledge.
2. **Review unit** → theme/story (cross-source cluster).
3. **Learning target** → train *all* pipelines; Catch-Up is the central capture point.
4. **Persisted learning** → learned-rules now (data, safe, reversible); proposing
   prompt-template diffs for manual approval is a later phase.
5. **Regen scope** → catch-up layer of the one theme only (cheap); underlying
   pipelines improve via rules on their next run.
6. **Storage** → persist session + themes in the DB; stream writes, UI reads via
   GRDB `ValueObservation`.
7. **Per-theme actions** → acknowledge (cascade mark-read), 👍/👎 + comment,
   create task, snooze.
8. **Generation trigger** → on-demand background stream on open; pipeline A
   (outline → per-theme fan-out).
9. **Bare dislike (no comment)** → stored as a low-confidence signal only; no rule
   is derived. A rule is derived only when a comment is present.

---

## Section 1 — Data model (new tables)

**`catchup_sessions`** — one review run:

| column | type | notes |
|---|---|---|
| `id` | INTEGER PK | |
| `created_at` | TEXT | |
| `status` | TEXT | `building` \| `active` \| `done` \| `failed` |
| `oldest_unread` | TEXT | window start, for display |
| `total_themes` | INTEGER | filled after outline |
| `reviewed_count` | INTEGER | progress |

**`catchup_themes`** — one theme, persisted incrementally as fan-out completes:

| column | type | notes |
|---|---|---|
| `id` | INTEGER PK | |
| `session_id` | INTEGER FK | |
| `order_idx` | INTEGER | display order (priority → recency) |
| `title` | TEXT | |
| `narrative` | TEXT | filled at expand |
| `priority` | TEXT | `high` \| `medium` \| `low` |
| `needs_you` | INTEGER | bool |
| `suggested_action` | TEXT | nullable |
| `refs` | TEXT (JSON) | `[{area,id,label}]` — snapshot IDs driving the cascade |
| `gen_state` | TEXT | `skeleton` \| `expanding` \| `ready` \| `failed` |
| `review_state` | TEXT | `pending` \| `reviewed` \| `snoozed` |
| `snooze_until` | TEXT | nullable |
| `task_id` | INTEGER | nullable, link to created target |
| `created_at` / `updated_at` | TEXT | |

**Feedback / learning — reuse existing infrastructure, do not fork:**

- `feedback` (shared table) gains `entity_type='catchup_theme'`: stores rating
  (👍/👎) + reason (free text) + a snapshot of the theme for grounding.
- Generalize `inbox_learned_rules` → **`learned_rules`** by adding a `pipeline`
  column (`catchup` \| `digest` \| `tracks` \| `inbox` \| `briefing`) so derived
  rules are addressed to the right system. `buildUserPreferencesBlock` (today an
  inbox concept) is generalized to inject the rules for a given pipeline into that
  pipeline's prompt. Existing inbox rows migrate with `pipeline='inbox'`.
  - Source values keep the existing semantics (`implicit` / `explicit_feedback` /
    `user_rule`), with `user_rule` still protected from implicit overwrite.

> **DB migration**: bump schema version; create the two catch-up tables; add the
> `pipeline` column to the rules table with a backfill default of `inbox`; expand
> the `feedback` CHECK to allow `catchup_theme`.

## Section 2 — Backend pipeline (`internal/catchup`, rewritten)

Reuses the `digest.Generator` interface (mockable), like people/tracks/briefing.

`Pipeline.Run(ctx) (sessionID, error)` runs an asynchronous pass:

1. **`gather()`** — pull compact unread records per area (id + title + short
   snippet), apply per-area caps, rank priority → recency, capture the snapshot
   ID lists, build a targets context line. (Largely reused from v1.)
2. **`outline()`** — one cheap AI call → theme skeletons (title + refs +
   rough priority + order). Create the session (`status=building`) and insert
   `catchup_themes` rows with `gen_state=skeleton`. The side list appears almost
   immediately.
3. **`expand()`** — worker pool (default ~10, mirroring `internal/guide`): one AI
   call per theme → narrative, `needs_you`, `suggested_action`; set
   `gen_state=ready`. Each row is written independently so the UI picks it up via
   observation — themes "drive up" one by one. When all complete, session
   `status=active`.
4. **Rule injection** — both the outline and expand prompts include the relevant
   pipelines' `learned_rules` via the generalized `buildUserPreferencesBlock`.

**`RegenTheme(ctx, themeID, comment)`** — re-runs *only* expand for that one theme
with the user's comment appended to the prompt; overwrites the row in place.

**`internal/catchup/prompt.go`** — three prompts:
- `catchup.outline` — cluster compact records into non-overlapping themes; only
  reference provided IDs; rank by importance.
- `catchup.expand` — write the narrative/priority/needs_you/suggested_action for
  one theme from its source records (+ optional correction comment for regen).
- `catchup.learn` — the learning interpreter (Section 3).

**DB queries (`internal/db/catchup.go`, rewritten):** session + theme CRUD,
incremental theme upsert, `GetActiveSession`, observation-friendly fetches, plus
reused gather queries (`GetUnread*`) and the bulk mark-read-by-ID functions for
the acknowledge cascade.

## Section 3 — Learning loop (the core)

On feedback for a theme:

- **Like/dislike with no comment** → write a row to `feedback` (low-confidence
  signal). **No rule derived.**
- **Like/dislike with a comment** → invoke the agentic **learning interpreter**
  (one `catchup.learn` AI call):
  1. From the theme's `refs`, determine which pipeline(s) and entities (channels /
     people / item types) are implicated.
  2. Derive targeted `learned_rules` rows for the right `pipeline` (e.g. "channel
     #random → ambient/mute" under `digest`/`inbox`; "don't split clustering on
     X" under `catchup`).
  3. If the comment is a presentation correction, also trigger **RegenTheme now**
     (Section 2) so the operator sees the fixed theme.
- **Accumulation (post-MVP)** — when enough homogeneous rules pile up for one
  pipeline, a separate step proposes a prompt-template edit **as a diff for manual,
  git-gated approval**. MVP ships only the counter/hook, not the auto-edit.

This realizes "train all systems": Catch-Up is the single capture point from which
feedback flows, addressed, into each pipeline's learned-rules.

## Section 4 — Desktop UX (`CatchUpView`, rewritten)

**Two-panel master-detail** (mail-client shape):

- **Left — streaming theme list** (narrow column): `CatchUpThemeRow` in `order_idx`
  order, each showing title, priority dot, badges (`needs you` / `reviewed` /
  spinner while `gen_state != ready`). A progress header: "5 of 12 reviewed".
  Skeletons appear at once and fill in as expand completes.
- **Right — rich single-theme review screen**: large title, priority/needs_you,
  narrative, a **Sources** block (refs navigating to the digest/track/inbox/
  briefing), suggested_action. Bottom **action bar**: 👍/👎, a comment field,
  **Regenerate**, **Create task**, **Snooze**, **Done** (acknowledge → cascade
  mark-read → advance to next pending theme).
- **Flow:** open → stream fills the list → pick the first → review → Done/action →
  auto-advance to the next `pending`. The rest assemble while you review.

**`CatchUpViewModel`** (`@MainActor @Observable`):
- `startSession()` — invokes `watchtower catchup run` (background) which writes to
  the DB.
- GRDB `ValueObservation` on `catchup_themes` for the active session → list and
  detail update live (the stream).
- `submitFeedback(theme, rating, comment)`, `regenerate(theme)`,
  `acknowledge(theme)` (cascade mark-read via existing bulk queries over `refs`),
  `createTask(theme)`, `snooze(theme, until)`.
- Sidebar badge = count of `pending` themes in the active session (fallback: sum
  of unread counts when no session exists).

**Swift queries:** new `CatchUpQueries` (fetch session/themes, observation); reuse
existing `DigestQueries.markRead(ids:)` / `TrackQueries` / `InboxQueries` /
`BriefingQueries` for the acknowledge cascade.

## Section 5 — CLI (`cmd/catchup.go`, rewritten)

- `watchtower catchup run [--json]` — start a pass (gather → outline → fan-out),
  writing to the DB incrementally. Without `--json`: progress; with `--json`: the
  final result.
- `watchtower catchup regen <theme-id> --comment "..."` — targeted regen.
- `watchtower catchup feedback <theme-id> --rating up|down [--comment "..."]` —
  feedback + learning interpreter.
- `watchtower catchup ack <theme-id>` — acknowledge + cascade mark-read.
- Provider via the existing `cliGenerator()`.

## Section 6 — Edge cases

- **Snapshot by ID** — acknowledge cascades mark-read only over the `refs`
  captured at gather time; items arriving later stay unread.
- **Zero unread** — no session created; empty state.
- **Outline failure** — session `failed`, show error + retry. No raw-section
  fallback (unlike v1; there are no bulk sections anymore).
- **Single-theme expand failure** — `gen_state=failed` on that row, others fine;
  per-theme retry.
- **Concurrent sessions** — one active session at a time; a new run closes the
  prior (`status=done`) or offers to resume an unfinished one.
- **Snoozed theme** — leaves the current pass, returns on the next run or when
  `snooze_until` elapses.
- **Idempotent mark-read** — already-read / newly-arrived IDs are safely skipped.

## Section 7 — Testing

**Go (`internal/catchup`, `internal/db`):**
- `mockGenerator` for outline and expand separately → pipeline persists skeletons
  then fills them.
- `gather()` respects caps + ranking; correct `total` vs `included`.
- `RegenTheme` overwrites exactly one row, leaving others untouched.
- Learning interpreter derives a rule under the correct `pipeline`; bare dislike
  derives no rule.
- `acknowledge` cascades mark-read only over a theme's `refs`; idempotent.
- Zero-unread short-circuit (no Generator call); outline-failure → session failed.

**Swift (`WatchtowerDesktop`):**
- `CatchUpViewModel` parses session/themes from a fixture.
- Observation picks up an appended theme (the stream).
- `acknowledge` calls the right bulk queries over `refs`; `submitFeedback` /
  `regenerate` invoke the CLI.
- Auto-advance to the next pending theme; empty state.

## Section 8 — Future evolution (out of MVP scope)

- **Prompt-template diffs**: once accumulated rules for a pipeline cross a
  threshold, generate a proposed edit to that pipeline's prompt template and
  surface it as a git-gated diff for manual approval.
- **Bare-dislike rules**: revisit whether a comment-less dislike should derive a
  low-confidence rule once we see real usage.

## Section 9 — Inventory / guard tests

Catch-up is **not** currently in `docs/inventory/`. This redesign reverses two v1
behaviors deliberately — **bulk mark-read removal** and **ephemeral → persisted**.
If implementation surfaces any guard test asserting the old behavior, **stop and
ask the owner** before relaxing it, per `CLAUDE.md`.
