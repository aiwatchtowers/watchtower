# Inbox Master-Detail (Catch-Up-style Dashboard) — Design

**Date:** 2026-07-07
**Status:** Approved by owner (brainstorm session)
**Builds on:** `docs/superpowers/specs/2026-07-06-secretary-dashboard-design.md` (branch `feature/secretary-dashboard`)

## Problem

The owner likes what the secretary Dashboard *shows* (situations: clustered
signals + target/track updates, ranked by the secretary) but prefers how
Catch-Up *presents* its content: a master-detail split with a compact list on
the left and a rich, spacious review pane on the right. The current Dashboard
is a single scrolling feed where cards expand in place — cramped for the
secretary card (why-it-matters / summary / chronology) plus member signals
plus the action row.

Explicitly chosen from the Catch-Up pattern: the **master-detail split** and
the **rich detail pane**. Explicitly *not* chosen: the review-session
mechanics (progress counter "N of M reviewed", auto-advance-until-zero,
Regenerate). This is a presentation rework, not a merge of the two features.

## Goal

Rebuild the Dashboard feed tab (`InboxFeedView` → `.feed`) as a Catch-Up-style
master-detail screen over the existing `situations` data, and add two content
upgrades the owner asked for:

1. **Comment feedback** — the Catch-Up "comment to teach the system" field
   next to 👍/👎, feeding the learning pipeline.
2. **Source links everywhere** ("links to the original source") — every situation
   must link back to its origins: Slack deep links on every member signal, and
   navigation rows to the linked Target/Track when the situation has one.

## Non-goals

- **Catch-Up is untouched** — its pipeline, tables, CLI, and views stay
  exactly as they are. No merging of themes and situations.
- No changes to the inbox pipeline order or semantics: detect → triage →
  learn → auto-resolve → compose → situation cards → archive/unsnooze stays
  as merged. DASH-01/02/03 and INBOX-01..09 contracts are preserved.
- No review-session mechanics (sessions, reviewed counters, auto-advance to
  zero, per-situation Regenerate).
- No schema changes to `situations` / `situation_signals` / `inbox_feedback`.
  (`inbox_feedback.reason` is a CHECK-constrained enum — free-text comments do
  NOT go there; they go through the learning interpreter, below.)

## Architecture

### 1. Screen structure (Swift, feed tab only)

`DashboardView` becomes an `HSplitView` (same shape as `CatchUpView`):

- **Left column (min 240 / ideal 280 / max 360):** `List` with native
  selection bound to `vm.selectedSituationID`. One row per open situation —
  new `SituationRow` view: kind badge (Signal/Target/Track/Mixed), priority
  dot, title (≤2 lines), trailing relative time. "Load more" button at the
  bottom keeps the existing pagination. The open-count badge stays in the
  `InboxFeedView` toolbar as today.
- **Right pane:** new `SituationReviewPane` (modeled on `CatchUpReviewPane`).
  When nothing is selected → neutral "select a situation" placeholder.
- Existing empty state (no situations at all) with the **Generate** button is
  kept, full-width, replacing the split.
- `SituationCardView` is **deleted** — fully replaced by
  `SituationRow` + `SituationReviewPane` (git history preserves it).
  `InboxCardView` stays as is.

### 2. `SituationReviewPane` layout (top to bottom)

- **Header:** kind + priority capsules (Catch-Up badge style), large bold
  title, last-signal relative time.
- **Sources block (mandatory):** Catch-Up-style tappable rows —
  - `target_id` set → "Target" row → `appState.navigateToTarget(id)`;
  - `track_id` set → "Track" row → `appState.navigateToTrack(id)`;
    (`converted_*` ids never render here — the feed only shows
    `status='open'` situations, and conversion closes them);
  - a header-level "Open in Slack" affordance for the newest member signal
    (kept from the current card).
- **Secretary card:** "Why it matters" as a highlighted callout (Catch-Up's
  lightbulb-block styling), then "Summary" and "Chronology" paragraphs.
  Existing card states preserved: "Preparing context…" spinner while
  `card_status='none'`, "Context unavailable — will retry" when `'failed'`.
- **Member signals:** the current bubble list (sender · channel · relative
  time, snippet bubble) with a Slack deep-link button **on every bubble**
  (`vm.slackURL(for:)`).
- **Bottom action bar** (below a Divider, fixed):
  - row 1: 👍 / 👎 + `TextField` "Comment to teach the secretary…";
  - row 2: Snooze menu (1h / tomorrow / Monday), Target, Track,
    Dismiss (destructive), Spacer, prominent **Done** with the Return
    keyboard shortcut.
  - The Target/Track conversion flows (prefill sheet, track-id resolution)
    move from `DashboardView` unchanged.

### 3. Selection & ViewModel state

- `selectedSituationID: Int?` lives in `DashboardViewModel` (already owned by
  `AppState`), so selection — like the in-flight Generate run — survives tab
  and sidebar navigation (owner's standing rule: async/UI state that must
  survive navigation lives in the AppState-owned VM).
- The member-signals cache moves from view-local `@State` into the VM; member
  signals load on selection and are cached per situation id.
- Post-action behavior: after Done / Dismiss / conversion removes the selected
  situation from the feed, selection moves to the **next** situation in list
  order (previous when the last one was acted on; nil when the list empties).
  This is a convenience default, not a review session.
- On `load()`, when the previously selected id is no longer in the feed,
  selection falls back to the first situation (or nil when empty).

### 4. Comment feedback (Go + Swift)

Two paths, chosen by whether the comment field is empty:

- **Rating only (comment empty):** unchanged fast path — Swift
  `SituationQueries.recordFeedback` writes directly (👎 → `source_mute`
  user_rule per member-signal channel; 👍 → no-op).
- **Rating + comment:** mirrors Catch-Up's learning flow
  (`internal/catchup/learn.go`):
  - New CLI subcommand: `watchtower inbox feedback --situation <id>
    --rating ±1 [--comment "…"]` (in `cmd/inbox.go`).
  - Go: a learning interpreter for situations in `internal/inbox` — new AI
    prompt `inbox.situation_feedback_learn` (registered via migration, per
    the add-ai-prompt skill; must work on both claude and codex providers)
    that turns the free-text comment + situation context into typed
    `inbox_learned_rules` rows (`source='user_rule'`, protected from implicit
    overwrite per INBOX-05; `pipeline='inbox'`).
  - Comment-less CLI invocations must NOT invoke the interpreter (same
    contract as Catch-Up's `learn_test.go`).
  - Swift: `DashboardViewModel.submitFeedback` gains a `comment` parameter;
    non-empty comment routes through `CLIRunnerProtocol` (same pattern as
    `CatchUpViewModel.submitFeedback`), empty comment keeps the direct write.

### 5. Testing

- **Swift (VM unit tests):** selection falls back to first on reload when the
  selected id disappears; Done/Dismiss selects the next situation; acting on
  the last situation selects the previous; emptying the list clears selection
  (degenerate case, per the owner's clean-exit testing rule); comment-less
  feedback does not touch the CLI runner; comment feedback invokes the mock
  CLI runner with the expected args.
- **Go:** situation feedback CLI — rating-only (no AI call), with comment
  (mock provider, rules land in `inbox_learned_rules` with
  `source='user_rule'`), unknown situation id errors cleanly.
- Existing guard tests (DASH-01/02/03, INBOX-01..09) must stay green and
  unmodified.

### 6. Docs & maintenance

- Update `docs/app-guide.md` (UI change — injected into the chat-bot system
  prompt; owner's standing rule).
- Update `docs/inventory/dashboard.md` if the comment-feedback path adds a
  behavioral contract worth pinning (candidate: "comment-less feedback never
  invokes the AI interpreter").
- `CLAUDE.md` feature notes: one-line update of the Desktop description
  (master-detail instead of in-feed expansion).
