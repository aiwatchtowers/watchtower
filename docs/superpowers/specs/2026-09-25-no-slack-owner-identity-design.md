# No-Slack owner identity — design

**Date:** 2026-09-25 · **Status:** approved by the owner (2026-09-24/25) · **Audit:** decision 15, finding M-2 (`docs/audit/2026-09-13-feature-audit/targets-dayplan-briefing.md`), F-05 (`silent-failures.md`)

## Problem

Watchtower's only notion of "the owner" is `db.GetCurrentUserID()`: `SELECT current_user_id FROM slack_accounts WHERE id = 1`. An install without Slack account #1 — Google-only, Jira-only, Google+Jira — has no owner, and everything keyed on the owner silently switches off while its UI stays visible:

- **Day plan and briefing never generate.** The daemon gates skip without a log line; `watchtower day-plan generate` and `briefing generate` print "No current user set" to stdout and **exit 0**, so the Desktop's Generate buttons report success, reload, find nothing, and show a bare empty state. The Desktop never reads that stdout (`BriefingViewModel` sends it to `/dev/null`).
- **The whole inbox pipeline no-ops**, Gmail/Calendar/Jira detectors included, because `inbox.Pipeline.Run` gates on the Slack id even though only its Jira detector used it.
- **The owner's Jira identity is only ever a fuzzy guess** through `jira_user_map` (email/display-name matching against Slack users); nothing asks Jira "who am I".
- The same raw SQL is copied into **six Swift files**, so the Desktop has the same blind spot six times over.

The call-site census behind this design: 23 non-test Go calls of `GetCurrentUserID()` (classified KEY / PROFILE / SLACK / JIRA / DISPLAY / GATE) and 6 Swift duplicates — the full table is reproduced in the implementation plan.

## Decisions (owner, 2026-09-24/25)

1. **One resolver, every call site.** `GetCurrentUserID` is removed; all 23 Go sites and all 6 Swift sites move to the resolver. No second notion of the owner survives.
2. **The ladder is Slack #1 → Google #1 → Jira #1**, including the Jira step (which needs a migration and a `/myself` call).
3. **The profile is a singleton; its key does not matter.** When the owner's id changes (Slack connected after Google), the existing profile is carried over, not orphaned.

## Design

### 1. `db.Owner` and `db.ResolveOwner()` (`internal/db/owner.go`, new)

```go
type OwnerSource string // "slack" | "google" | "jira" | ""

type Owner struct {
    ID            string      // the row key: "1:U123" | "google:me@x.com" | "jira:<accountId>" | ""
    Source        OwnerSource // which rung produced ID
    SlackUserID   string      // namespaced Slack id, "" when Slack #1 has none
    Email         string
    JiraAccountID string      // Atlassian accountId, "" when unknown
    DisplayName   string
}

func (db *DB) ResolveOwner() (Owner, error)
func (o Owner) Known() bool { return o.ID != "" }
```

**ID rung — first match wins:**

1. `slack_accounts` row `id = 1` with non-empty `current_user_id` → `ID = current_user_id` (unchanged for every existing Slack install — no data moves), `Source = slack`.
2. First `google_accounts` row (lowest id) with non-empty `email` → `ID = "google:" + lower(email)`, `Source = google`.
3. First enabled `jira_accounts` row with non-empty `owner_account_id` (lowest id) → `ID = "jira:" + owner_account_id`, `Source = jira`.
4. Otherwise `Owner{}` — unknown.

**Enrichment — every field is filled from every source that has it, independent of which rung produced `ID`:**

- `SlackUserID` = Slack #1's `current_user_id` (may be "").
- `Email` = Slack user row's email (`users` table) → first Google account's email → first Jira account's `owner_email`.
- `JiraAccountID` = first enabled Jira account's `owner_account_id` → else `jira_user_map` lookup by `SlackUserID` (the existing fuzzy bridge, both bare and namespaced forms — today's `atlassianIDsForUser` logic moves here).
- `DisplayName` = Slack user display/real name → Jira `owner_display_name` → email local part.

Removed/`status='removed'` Slack and Jira rows are skipped; a disabled (`enabled=0`) Jira account is skipped for rung 3 and enrichment (disabled = the owner switched it off). A DB error returns `(Owner{}, err)`.

### 2. Profile singleton (`internal/db/profile.go`)

`user_profile` stays keyed by `slack_user_id` (column name kept; it now holds `Owner.ID`, of whatever shape). New:

- `GetOwnerProfile(owner Owner) (*UserProfile, error)` — the row keyed `owner.ID`; if none, the most recently updated row (the single-owner app has at most one real row; legacy/test rows lose to the fresh one). Returns `nil, nil` when the table is empty.
- `UpsertOwnerProfile(owner Owner, p UserProfile) error` — if the fallback row exists under a different key, it is **re-keyed** to `owner.ID` in the same transaction before the upsert, so a Google-then-Slack install keeps its single profile row.

`GetUserProfile(slackUserID)` stays for its non-owner callers, if any remain after the migration; the starred-channel/person helpers take `owner.ID`.

### 3. Call-site policy (Go)

| Class | Sites | New behaviour |
|---|---|---|
| KEY (day_plans, briefings, tracks, MCP `get_today_briefing`) | `cmd/day_plan.go` ×5, `cmd/briefing.go` ×2, `cmd/tracks.go:766`, `internal/briefing`, `internal/tools/digests.go`, `internal/tracks`, daemon day-plan phases ×2 | use `Owner.ID`; unknown owner → see §5 |
| PROFILE | `cmd/jira.go` ×2, `cmd/profile.go`, `internal/guide`, `internal/digest`, `internal/meeting`, `internal/dayplan`, `internal/briefing` | `GetOwnerProfile(owner)` |
| SLACK | `internal/inbox/style_sample.go` | `Owner.SlackUserID`; empty → the existing explicit error, reworded "style sample needs a connected Slack account" |
| JIRA | inbox Jira detector + `autoResolveJira`, briefing `gatherJiraContext` | `Owner.JiraAccountID` first (query `jira_issues.assignee_account_id`), falling back to today's Slack-id path |
| DISPLAY | `internal/meeting` (name), daemon `applyInboxCurrentUser` (email) | `Owner.DisplayName` / `Owner.Email`; `applyInboxCurrentUser`'s ad-hoc Slack→Google email fallback is deleted — it *is* the resolver now |

`cmd/tracks.go:766` today writes `AssigneeUserID: ""` silently when there is no owner; it now errors with the §5 message instead.

### 4. Inbox gate

`inbox.Pipeline.Run` stops gating the whole run on the Slack id. It runs when `Owner.Known()`; each detector takes what it needs and skips individually: Slack detectors already use each account's own `current_user_id`; Calendar needs `Owner.Email`; Jira comment-mention needs `Owner.JiraAccountID`; Gmail/IMAP need their account emails. INBOX-09's watermark rule is unchanged: a detector that skips for lack of identity is not a detector *error* and does not freeze the watermark (it is exactly today's behaviour for an account with no `current_user_id`).

### 5. No silent skip (the Generate bug)

- **User-triggered commands** (`day-plan generate|show|list|reset|check-conflicts`, `briefing generate|show|list`, `tracks create`, `profile`, MCP `get_today_briefing`) with an unknown owner **exit non-zero** with one shared message: `no owner identity: connect Slack, Google or Jira first` (exported as `db.ErrNoOwner`, wrapped by callers).
- **`briefing.RunForDate`** returns `db.ErrNoOwner` instead of `(0, nil)`, so "no owner" is no longer conflated with "nothing to summarize". The daemon treats `ErrNoOwner` as a **benign skip** (no attempt-budget charge, one log line per day, not per cycle) — the wave-4 `…BenignNoUserSkipDoesNotConsumeBudget` tests keep their meaning with the new error.
- **Desktop:** Day Plan and Briefings show an explicit empty state — "Connect Slack, Google or Jira so Watchtower knows who you are" with a link to Settings → Connections — whenever the owner is unknown, and hide/disable Generate. The Briefing Generate path stops discarding the CLI's output: a non-zero exit surfaces `stderr` in the existing `generateError` banner (Day Plan's `generationError` already does via `CLIRunner`).

### 6. Jira `/myself` (migration 00071)

- `jira_accounts` gains `owner_account_id`, `owner_email`, `owner_display_name` (TEXT NOT NULL DEFAULT ''). Mirrored in `schema.sql`, golden regenerated.
- `jira.Client.GetMyself(ctx) (Myself, error)` — `GET /rest/api/3/myself` via the existing `c.get` helper (`GetProjectVersions` shape). Scope `read:jira-user` is already granted; no re-consent.
- Filled **at connect** (`connectJiraAccount`, after the site is chosen) — best effort: a failure logs and does not fail the connect.
- Filled **lazily** in `wireJiraSyncers` for an enabled account whose `owner_account_id` is empty — one call per account per daemon start until it succeeds; a revoked account simply stays empty until re-login.
- `db.SetJiraAccountOwner(accountID, accountId, email, displayName)`.

### 7. Swift twin (`WatchtowerCore`)

`OwnerQueries.resolve(_ db: Database) throws -> Owner` implements the same ladder and enrichment; its doc comment names `internal/db/owner.go` as the Go side of a declared dual path (the `SlackAccountID.swift` ↔ `namespace.go` precedent). Shared fixture: the same four ladder cases asserted on both sides. All six raw `current_user_id` reads move to it:

| Site | Uses |
|---|---|
| `ProfileQueries.fetchCurrentProfile` | `Owner` + profile-singleton read (Swift mirror of §2) |
| `TrackQueries.fetchCurrentUserID` | `Owner.ID` |
| `ChannelStatsQueries.fetchCurrentUserID` | `Owner.SlackUserID` (it matches `messages.user_id`) |
| `ProjectMapViewModel.load` | profile singleton |
| `ProfileSettings.getCurrentUserID` | `Owner.ID` + re-keying upsert (Swift mirror) |
| `OnboardingChatViewModel.getCurrentUserID` | `Owner.ID`; the silent `return` on empty in `saveProfileWithContext` becomes a visible error |

`AppState` exposes the resolved owner for the Day Plan / Briefings empty state.

### 8. Documentation and contracts

- New inventory file `docs/inventory/owner-identity.md` with two contracts, added to the README map:
  - **OWNER-01 (one owner, one ladder):** every owner-identity read in Go and Swift goes through `ResolveOwner` / `OwnerQueries.resolve`; the ladder is Slack #1 → Google #1 → Jira #1; an existing Slack install's owner id never changes. Guard: a property scan (Go `go/parser` over `internal/` + `cmd/`, Swift text scan over `WatchtowerDesktop/Sources`) fails on any `current_user_id FROM slack_accounts` / `GetCurrentUserID` outside the resolver; ladder fixture tests on both sides.
  - **OWNER-02 (no silent skip):** a user-triggered command that needs the owner and has none exits non-zero with `ErrNoOwner`; the daemon's skip is benign and logged once per day. Guard: CLI tests asserting the exit error for each §5 command.
- `CLAUDE.md`: the Slack multi-account "Documented v1 identity-scoping decisions" item (1) is rewritten to point at the resolver; the stale reference to `db.ListOwnerSlackUserIDs()` / `ListStreamCandidatesSince` (removed with the stream triage) is corrected; a short "Owner identity" feature note is added.

## Behaviour changes worth naming

- An existing Slack install: owner id, profile, day plans, briefings — all unchanged.
- A Slack install that later disconnects Slack #1 falls to the Google/Jira rung; its day plan/briefing history stays readable in the Desktop (read by date) and new rows are keyed by the new id. Today's day plan may be generated once more on the day of the switch.
- `tracks create` / `profile` / `briefing *` / `day-plan *` without any connected account now exit non-zero instead of printing and exiting 0 — a CLI contract change for scripts, intended.
- A rung switch also re-runs tracks extraction: `HasTracksForUser` is keyed by the owner id, so the first cycle under the new id sees no tracks and treats itself as a first run over the `sync.initial_history_days` window. Tracks already extracted under the old id are not re-keyed, so that window can produce duplicates of them.
- `jira_assigned` is live for the first time: it used to compare the owner's Slack id against `jira_issues.assignee_account_id` (an Atlassian id) and never fired. It now matches the owner's Atlassian id, and it mints at most one **pending** item per assigned issue — later updates of the same issue add nothing while that item is pending; a resolved or dismissed item does not block a later update from surfacing a new one (`docs/inventory/inbox-pulse.md`, 2026-09-25 entry).

## Out of scope

Multiple owners; choosing the owner by hand; re-keying historical `day_plans`/`briefings`/`tracks` rows to a new id; per-account owner identities for Google/Jira beyond #1; changing how Slack ingestion itself identifies the owner per account.

## Testing

- Go ladder table test (`TestOwner01_…`): Slack-only, Google-only, Jira-only, Google+Jira, none, removed-Slack, disabled-Jira; enrichment fields asserted by value per case.
- Profile singleton: Google-then-Slack re-key keeps one row with the old content; a stale second row loses to the owner-keyed row.
- OWNER-02 CLI tests per command; `RunForDate` returns `ErrNoOwner`; daemon budget tests still pass with the benign skip.
- Inbox: Google-only install runs Calendar/Gmail detection (today: whole Run skipped); Jira mention detection works from `JiraAccountID` with an empty `jira_user_map`.
- `/myself`: `httptest` server; connect stores the owner; a 401/404 does not fail the connect; lazy fill in `wireJiraSyncers`.
- Swift: the same ladder fixture on `OwnerQueries.resolve`; each migrated site with a Google-only fixture; Day Plan/Briefings empty state renders when the owner is unknown.
- Every guard mutation-checked (a plausible wrong implementation — Slack-only ladder, enrichment only from the winning rung, profile read by exact key — must fail it).
