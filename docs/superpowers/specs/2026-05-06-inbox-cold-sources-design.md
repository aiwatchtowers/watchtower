# Inbox — Cold Sources & Stale Archive Fix

**Date:** 2026-05-06
**Status:** Design approved, ready for implementation plan
**Owner:** Vadym

## Problem

User report: "падают только брифинги в инбокс". Diagnosis against the live `whitebit` workspace DB (689 MB) revealed three independent causes, all of which stop legitimate signals from reaching the UI.

### Diagnostic facts (DB snapshot 2026-05-06)

| Source | Data in DB | Inbox items (30d) | Pending unread shown in UI | Status |
|---|---|---|---|---|
| Slack `dm` | — | 247 (227 resolved, 18 pending, 2 dismissed) | **0** | Auto-archived as `stale` |
| Slack `thread_reply` | — | 59 (48 resolved, 11 pending) | **0** | Auto-archived as `stale` |
| Slack `mention` | — | 11 | 0 visible | Read or archived |
| `briefing_ready` | 23 briefings | 7 | **1** | Only signal user sees |
| `jira_assigned` | 1165 issues, 77 distinct assignees | **0** | — | Slack ID ≠ Atlassian ID; no mapping for current user |
| `calendar_invite/time_change/cancelled` | 54 events, current user in attendees ≥5 | **0** | — | JSON field name mismatch (`response_status` vs `rsvp_status`) |
| `decision_made` | 1472 digests, 7 `type="decision"` situations + ~40 decision-adjacent types | **0** | — | Detector requires `importance="high"`; AI never sets it |
| `reaction` | — | 1 all-time | — | Out of scope (user chose to leave as-is) |
| `target_due` | 11 targets | 0 | — | All targets have empty `due_date` (no bug) |

### Root causes

1. **Stale archive too aggressive.** `pipeline.go:310` runs `ArchiveStaleActionable(14 days)` every cycle. Of the 18 unread pending Slack items currently in the DB, **17 are archived** with `archive_reason='stale'` and `item_class='actionable'`. UI filter `archived_at IS NULL` hides them. Only the latest `briefing_ready` (within 14d window) survives.
2. **Calendar field-name mismatch.** Real attendee JSON: `{"email":"...","response_status":"needsAction","slack_user_id":"..."}`. `calendar_detector.go:13 calAttendee.RSVPStatus` reads `json:"rsvp_status"` — always empty — switch never picks `calendar_invite`.
3. **Jira identity gap.** `workspace.current_user_id = U0118BRJH54` (Slack `@whitebit.com`); `jira_user_map` keys by Atlassian account_id, joined by email; the user's Atlassian email is `@ec319.com`. There is no mapping row for `U0118BRJH54`. `DetectJira` is passed Slack ID and matches against `jira_issues.assignee_account_id` — never matches.
4. **`decision_made` detector and AI prompt out of sync.** AI generates `decision_making`, `decision_needed`, `architecture_decision`, `product_decision`, `decision_deadlock`, etc. (40+ decision-adjacent ситуаций). Detector matches only `type=="decision" AND importance=="high"`. All 7 raw `decision` rows have empty `importance`.

## Goals

- All `actionable` items remain visible in the live Inbox until the user explicitly resolves/dismisses/snoozes them. Only `ambient` items are auto-archived by TTL.
- Calendar invites/changes/cancellations create inbox items when the current user is an attendee.
- Jira issues newly assigned to the current user create inbox items, with a config escape hatch for users whose Slack/Jira emails don't match.
- Important "decision made" digest situations create inbox items via a semantic whitelist.

## Non-goals

- Jira `comment_mention`, `status_change`, `priority_change`, `comment_watching` detectors (require schema extension; separate spec).
- Reaction-request detector (left as-is per scope decision).
- New trigger types (`slack_no_reply`, `target_overdue`, `track_stalled` — separate specs).
- Digest prompt changes to enforce `importance` on decision situations.

---

## Section 1 — Stale archive policy

### Behavior change

`actionable` items are no longer eligible for time-based archival. They leave the live Inbox only via `resolve` / `dismiss` / `snooze` (user action, AI auto-resolve, or rule-based auto-resolve). `ambient` items continue to be archived after 7 days as today.

### Code changes

**`internal/inbox/pipeline.go:303-314`** — replace the two-call archive block with a single call:

```go
// Phase 5: Auto-archive expired ambient items (actionable items are never
// auto-archived — they only leave the inbox via resolve/dismiss/snooze).
if n, err := p.db.ArchiveExpiredAmbient(7 * 24 * time.Hour); err != nil {
    p.logger.Printf("inbox: archive ambient error: %v", err)
} else {
    archived = n
}
```

Remove the call to `ArchiveStaleActionable`.

**`internal/db/inbox.go`** — `ArchiveStaleActionable` is removed (deleted, not commented out — there are no other callers per grep).

### One-time migration: rescue archived actionable items

A new schema migration unarchives existing actionable items that were archived as `stale`:

```sql
UPDATE inbox_items
SET archived_at = NULL,
    archive_reason = NULL,
    updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')
WHERE archive_reason = 'stale'
  AND item_class = 'actionable'
  AND status = 'pending';
```

In the user's DB this restores the 17 missing DM/thread_reply items immediately on first run after the upgrade. Migration file: `internal/db/migrations/00003_unarchive_stale_actionable.sql` (goose; current latest is `00002_target_due_inbox.sql`).

### Edge cases

- **Inbox grows unbounded if user never reviews.** This is the intended behavior — the count itself becomes a signal. A future spec can add escalation (`pinned + priority='high'` after N days), but that's deliberate user pressure, not silent deletion.
- **AI reclassifies `actionable` → `ambient`** via `ApplyAIOverride`. Item then becomes eligible for ambient TTL. This is correct: once AI says "this is background noise," it can expire.

### Tests

- `pipeline_test.go`: guard test that 30-day-old `actionable` pending item is **not** archived after `Run`.
- New DB-level test for the migration: row with `archive_reason='stale' AND item_class='actionable' AND status='pending'` becomes unarchived.
- Remove the `ArchiveStaleActionable` test in `internal/db/inbox_extra_test.go:72` (function deleted; only caller besides pipeline).

### Behavior Inventory

`docs/inventory/inbox-pulse.md` — add:

```markdown
## INBOX-08 — Actionable items are never auto-archived by TTL
**Guard test:** TestPipelineRun_ActionableNotArchivedAfter30Days
**Why load-bearing:** Actionable items represent open loops awaiting user action. Auto-archiving them silently violates the inbox metaphor — open items must remain visible until the user (or AI auto-resolve from explicit reply) closes them.
```

---

## Section 2 — Identity for Jira and Calendar

### 2a. Calendar — fix JSON field tag

**`internal/inbox/calendar_detector.go:13`** — change:

```go
type calAttendee struct {
    Email      string `json:"email"`
    RSVPStatus string `json:"response_status"`  // was: rsvp_status
}
```

**`internal/inbox/pipeline.go` (autoResolveCalendar, ~line 947)** — uses the same `calAttendee` struct via `calAttendee` import; fix is automatic because the struct is shared.

**Cross-check:** grep for any other consumer of `calendar_events.attendees` JSON with the wrong tag. Targets: `internal/calendar/`, `internal/briefing/`, `internal/meeting/`, `WatchtowerDesktop/Sources/`. Fix any that still expect `rsvp_status` to align with the producer (Go calendar sync writer in `internal/calendar/`).

**Tests:** `calendar_detector_test.go` — replace fixtures using `rsvp_status` with `response_status`. Add a regression test: detector creates `calendar_invite` when input JSON uses the production-shape `{"email":"...","response_status":"needsAction"}`.

### 2b. Jira — current-user → Atlassian account_id resolver

**Resolution chain (in `applyInboxCurrentUser`):**

1. **Config override:** `cfg.Identity.JiraAccountID` non-empty → use directly.
2. **Slack-ID lookup:** `db.GetJiraUserMapBySlackID(currentUserID)` — if a row exists, take `jira_account_id`.
3. **Email lookup:** `db.GetJiraUserMapByEmail(users[currentUserID].email)` — same map, alternate index.
4. **Empty:** detector logs once per cycle `inbox: jira detector skipped — no Atlassian account_id resolved for current user; set identity.jira_account_id in config to force.` Detector returns 0 without erroring.

### 2c. Identity struct in pipeline

Replace the two scalar fields with a struct so future identity-bound detectors don't multiply method signatures:

```go
// internal/inbox/pipeline.go
type CurrentUser struct {
    SlackID       string
    Email         string
    JiraAccountID string
}

func (p *Pipeline) SetCurrentUser(u CurrentUser) {
    p.currentUser = u
}
```

Update callers:
- `daemon.go:524 applyInboxCurrentUser` — populate all three fields per the resolution chain above.
- `cmd/inbox.go` (one-shot CLI run) — same logic via a shared helper, e.g. `inbox.ResolveCurrentUser(db, cfg) CurrentUser`.
- All test callsites: `cmd/*_test.go`, `internal/inbox/pipeline_test.go` — use `SetCurrentUser(CurrentUser{SlackID:..., Email:..., JiraAccountID:...})`.

`DetectJira` signature changes to `DetectJira(ctx, db, jiraAccountID, sinceTS)` — no Slack-ID anywhere. Empty `jiraAccountID` → no-op early return.

### Code locations summary

| File | Change |
|---|---|
| `internal/config/config.go` | Add `Identity{JiraAccountID, Email}` (both optional) under config root. |
| `internal/db/jira.go` | New `GetJiraUserMapBySlackID(slackID) (*JiraUserMap, error)`; existing `GetJiraUserMapByAccountID` and the WHERE-by-email scan reused. New `GetJiraUserMapByEmail(email)`. |
| `internal/inbox/pipeline.go` | `CurrentUser` struct; `SetCurrentUser(CurrentUser)`; `currentUser CurrentUser` field. |
| `internal/inbox/jira_detector.go` | Signature: `DetectJira(ctx, db, jiraAccountID, sinceTS)`. Early return on empty. |
| `internal/inbox/calendar_detector.go` | Field tag fix (`response_status`). |
| `internal/daemon/daemon.go applyInboxCurrentUser` | Resolution chain (config → slack_id → email → empty). |
| `cmd/inbox.go` | Mirror the same resolution. Extract to shared helper if needed. |

### Tests

- DB: `TestGetJiraUserMapBySlackID_Found/NotFound`, `TestGetJiraUserMapByEmail_Found/NotFound`.
- Pipeline: `TestDetectJira_UsesAccountIDDirectly` (passes `jiraAccountID="X"`, expects matches against `assignee_account_id="X"`).
- Pipeline: `TestDetectJira_EmptyAccountID_NoOp`.
- Daemon (or shared resolver): `TestResolveCurrentUser_Priority` — config override beats slack_id mapping; slack_id beats email; all empty → empty `JiraAccountID`.
- Calendar: `TestDetectCalendar_ResponseStatusFieldName` — input with `"response_status":"needsAction"` produces `calendar_invite`.

### Behavior Inventory

```markdown
## INBOX-09 — Jira identity uses jira_user_map with config override
**Guard test:** TestResolveCurrentUser_Priority + TestDetectJira_UsesAccountIDDirectly
**Why load-bearing:** Slack workspace email and Jira email are not always identical (multi-domain orgs, multiple Slack workspaces). The config override (`identity.jira_account_id`) is the authoritative escape hatch. Resolution chain order — config → slack_id → email — must not be reordered without explicit owner approval.
```

---

## Section 3 — `decision_made` detector breadth

### Code change

**`internal/inbox/watchtower_detector.go`** — add a helper near top of the file:

```go
var decisionTypes = map[string]bool{
    "decision":                true,
    "decision_made":           true,
    "decision_needed":         true,
    "architecture_decision":   true,
    "product_decision":        true,
    "process_decision":        true,
    "strategic_decision":      true,
    "technical_decision":      true,
    "design_decision":         true,
    "hiring_decision":         true,
    "access_control_decision": true,
}

func isDecisionSituation(t, importance string) bool {
    if !decisionTypes[t] {
        return false
    }
    // Empty importance = treat as medium (AI prompt currently doesn't always set it).
    // Drop only explicit 'low'.
    if importance == "low" {
        return false
    }
    return true
}
```

Replace the inner check in `DetectWatchtowerInternal` (line ~77):

```go
for idx, s := range list {
    if isDecisionSituation(s.Type, s.Importance) {
        decisions = append(decisions, pendingDecision{...})
    }
}
```

### Explicitly NOT in whitelist

- `decision_discussion`, `decision-discussion`, `decision_making`, `decision-making` — process/discussion, not outcome
- `decision_deadlock`, `decision_conflict`, `decision_escalation` — captured elsewhere as `escalation`/`misalignment`
- `decision_alignment`, `decision_clarification`, `decision_correction` — coordination, not new direction
- `decision_request`, `decision_gate`, `decision_point`, `decision_process`, `decision_ownership`, `decision_without_cto_involvement` — too vague; would create high noise

### Edge case — out-of-whitelist decision-like types

Add a one-time-per-cycle log: when scanning situations, if `strings.Contains(t, "decision")` but not in whitelist, increment a counter; log at end of detector if counter > 0:

```go
p.logger.Printf("watchtower detector: %d situations had decision-like types not in whitelist (sample: %s) — review and possibly extend decisionTypes",
    skippedCount, sampleType)
```

This gives feedback when AI introduces a new type without forcing manual code review of every prompt change.

### Tests

`watchtower_detector_test.go`:

- `TestIsDecisionSituation` — table-driven over types/importance combinations.
- `TestDetectWatchtowerInternal_DecisionWhitelist` — fixture digest with `[{"type":"product_decision","topic":"X","importance":""}, {"type":"decision_discussion","topic":"Y"}, {"type":"decision","importance":"low","topic":"Z"}]` produces exactly 1 inbox item with `topic=X`.

### Behavior Inventory

```markdown
## INBOX-10 — decision_made uses semantic whitelist + medium-default importance
**Guard test:** TestIsDecisionSituation + TestDetectWatchtowerInternal_DecisionWhitelist
**Why load-bearing:** AI is non-deterministic about situation typing and importance assignment. The whitelist enumerates intentional decision-result types; relaxing to `type LIKE '%decision%'` would flood inbox with discussions and process talk. Empty importance defaults to medium (not high) — this catches the common case where AI omits the field; explicit `low` is honored.
```

---

## Implementation order

1. **Section 1** (stale archive) — independent, smallest blast radius. Run migration first to restore archived items so user sees real inbox before further changes land.
2. **Section 2a** (calendar field tag) — one-line fix + test. Independent.
3. **Section 3** (decision detector) — independent.
4. **Section 2b/2c** (Jira identity + struct refactor) — touches more files; ship last.

Each section is a separate commit; sections 2b/2c may be one commit since the struct refactor is what enables the Jira lookup.

## Migration & schema bump

- DB schema migration: bump version, add migration that runs the unarchive UPDATE described in Section 1.
- No new tables, no new columns. `users.email`, `jira_user_map`, and existing inbox columns are sufficient.

## Open questions to revisit later (NOT in this spec)

- Escalation policy when `actionable` items pile up (e.g., auto-pin + bump priority after N days idle).
- Digest prompt instruction to set `importance` consistently on `decision*` types.
- Whether to extend `decision_made` whitelist via config rather than hardcode.
- Jira `comment_mention`/`status_change` detectors (need schema additions).
