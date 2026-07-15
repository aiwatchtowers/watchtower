# Gmail as a data source — design

**Date:** 2026-07-09
**Branch (proposed):** feature/gmail-source
**Status:** design approved, ready for planning

## Motivation

Watchtower aggregates work signals from several sources (Slack, Jira, Google
Calendar, internal events) into a single inbox and clusters them into "situations".
Email is a major source of work signals that is currently missing. Goal:
connect Gmail as another source, following the pattern of the existing external
sources, so that emails land in the inbox/situations and go through the same
pipeline without reworking it.

## Key decisions (confirmed with the owner)

1. **Provider:** Gmail via the Google API (reuse Calendar's OAuth mechanics).
2. **What counts as a trigger:** everything in the inbox (Gmail Inbox). Importance
   filtering is done by the existing triage (AI), not by the detector.
3. **Permissions:** scope `gmail.modify` (read + ability to write back statuses). The
   scope is requested up front so that a future write-back layer won't require
   re-authorization.
4. **Connection model:** a **separate** Gmail connection (its own token store
   `gmail_token.json`, its own Connect Gmail button), independent of Calendar. Existing
   Calendar users are not affected; sources are enabled independently.

## Boundaries and decomposition

The owner chose scope **C** (see the "Scope: how deeply email enters the pipelines"
section): emails land both in the inbox and — via their own email digests — in tracks
and the daily briefing. Implemented in stages, across **three plans**:

- **Plan 1 — read path into the inbox (this spec, implemented first):** Gmail OAuth,
  sync layer, source table `gmail_messages`, detector, integration into the inbox
  pipeline, CLI, Desktop Connect. Emails land in the inbox and situations. Discuss chat
  can compose a reply draft (as for Slack); sending is manual, in Gmail. Self-contained.
- **Plan 2 — email digests (a layer on top of Plan 1, scope C):** generate digests
  from `gmail_messages` (writing into the `digests` table) so tracks and the daily
  briefing pick up email. See the sketch in the "Plan 2 (sketch): email digests"
  section — the detailed design will be a separate spec.
- **Plan 3 — write-back (independent, later):** sync "read/archived" status back
  from Watchtower to Gmail (`users.messages.modify`, removing the `UNREAD`/`INBOX`
  labels). The `gmail.modify` scope already covers this.

Plans 2 and 3 are independent of each other; both build on top of Plan 1. Rationale
for the split: the read path delivers value on its own; email digests and write-back
add separate axes of complexity (integration into digest/tracks and two-way status
sync, respectively) that are better designed separately.

## Scope: how deeply email enters the pipelines (rationale for choosing C)

The code has **no "data source" abstraction** — all raw data is the Slack table
`messages`, hard-modeled for Slack. An investigation of pipeline coupling showed:

- **Digests** read `messages` directly, organized around "channels".
- **Tracks** read NOT `messages` but `digests` (a second-order consumer).
- **People cards** are a hybrid: partly from `digests`, partly via direct `JOIN`s
  on `messages`/`users`/`channels` (hard-coupled to Slack).

Key takeaway: **the integration point for tracks and (partly) people is `digests`,
not `messages`.** Therefore:

- The option "merge email into `messages`" (first-class) is the most expensive and
  risky: extending the `channels.type` CHECK, synthetic `users`/`channels`,
  synthesizing `ts`, revising Slack-format assumptions (`^\d{10}\.\d{6}$`, `<@id>`
  mentions, `thread_ts`). Rejected — disproportionate to the risk, and distorts the
  "email = channels" semantics.
- The chosen option **C** generates its own **digests** from emails, sidestepping the
  painful `messages` invariants. Tracks pick up email almost for free; the briefing
  includes email. Limitation: tracks will lose precise `source_refs` to emails
  (Slack-format regex) — a degradation of links, not a break; people statistics for
  external contacts won't appear (that comes from direct `JOIN`s on `messages`) — this
  is deliberately out of scope.

## Architecture

Follows the confirmed "external source" pattern (Calendar and Jira are the examples):

```
Gmail OAuth (gmail_token.json)
  → internal/gmail: Syncer.Sync() pulls emails from the Gmail Inbox
     → writes to the gmail_messages table (SQLite)
        → internal/inbox/gmail_detector.go: DetectGmail() reads gmail_messages
           → creates inbox_items (trigger_type email_received / email_cc)
              → existing pipeline: triage → compose → situations (unchanged)
```

The detector does NOT call the Gmail API — it reads the already-synced table, the
same way the Jira and Calendar detectors do.

## Components

### 1. Package `internal/gmail/`

Modeled on `internal/calendar/` — a **self-contained package** (this repo's
established pattern: Jira and Calendar each have their own OAuth code rather than a
shared layer; we repeat that pattern so as not to touch the working Calendar
integration and its ldflags):

- **`auth.go`** — OAuth modeled on `calendar/auth.go`: token endpoint,
  `access_type=offline`, `prompt=consent`, loopback `Login`, `Prepare`/`Complete`.
  Differences from Calendar:
  - scope: `https://www.googleapis.com/auth/gmail.readonly` (originally
    `gmail.modify`; narrowed 2026-07-09 ahead of verification — see the
    revisit in "Open questions" below);
  - its own `TokenStore` → `gmail_token.json` (independent of `google_token.json`);
  - its own `GoogleOAuthConfig` type. The Google client_id/secret are the same as
    Calendar's (one Google Cloud project); they are wired together at the `cmd` level
    (`resolveGoogleOAuthConfig` converts to `gmail.GoogleOAuthConfig`), so no new
    ldflags variables or Makefile changes are needed, and the `gmail` package does not
    import `calendar`.
- **`client.go`** — the Gmail REST client (raw net/http, base
  `https://www.googleapis.com/gmail/v1`): `users.messages.list` (`q=in:inbox`,
  pagination), `users.messages.get` (metadata+body format). Auto-retry on 401 with a
  token refresh (as in `calendar/client.go`). On `invalid_grant` → `ErrAuthRevoked`.
- **`sync.go`** — `Syncer{client, db, cfg, logger}`, `NewSyncer`, `Sync(ctx) (int, error)`:
  - **initial sync:** request `in:inbox newer_than:{InitialHistoryDays}d`;
  - **incremental sync:** watermark on the last processed `internalDate`.
    Unlike Calendar (sliding window + invalidation by `synced_at`), email
    accumulates — a real watermark is needed so the entire Inbox isn't pulled every
    cycle. The watermark is stored in the `workspace` table (new field
    `gmail_last_internal_date`), consistent with the existing
    `inbox_last_processed_ts` and `search_last_date` watermarks;
  - **noise filter before AI:** emails with the `CATEGORY_PROMOTIONS` and
    `CATEGORY_SOCIAL` labels are skipped (analogous to hard-mute), never reaching
    triage;
  - upsert each email into `gmail_messages`;
  - `MaxMessagesPerSync` cap per cycle;
  - writes authorization telemetry to `gmail_auth_state` (`ok`/`error`/`revoked`).
- **`models.go`** — domain types for an email.

*(historyId-based incremental sync — a possible performance improvement, but for
the first version we use `messages.list` + a watermark on `internalDate`.)*

### 2. DB schema (migration `00016`)

New table **`gmail_messages`** (modeled on `calendar_events`):

| column | type | purpose |
|---|---|---|
| `id` | TEXT PK | Gmail message ID |
| `thread_id` | TEXT | Gmail thread — clustering by the composer and thread grouping |
| `from_email` | TEXT | sender (email) |
| `from_name` | TEXT | sender (display name) |
| `to_json` | TEXT | To recipients (JSON array) |
| `cc_json` | TEXT | CC recipients (JSON array) |
| `subject` | TEXT | subject |
| `snippet` | TEXT | Gmail's preview (~200 chars of the body, provided by the API itself) |
| `body_text` | TEXT | full plain-text body of the email (for the strong AI tier) |
| `internal_date` | TEXT | email timestamp (ISO8601) |
| `labels_json` | TEXT | Gmail labels (INBOX, UNREAD, IMPORTANT, CATEGORY_*) |
| `is_unread` | INTEGER | derived, for fast filters |
| `permalink` | TEXT | `https://mail.google.com/mail/u/0/#inbox/{id}` |
| `synced_at` | TEXT | timestamp of the row's last sync (defaults to now) |
| `updated_at` | TEXT | internal bookkeeping |

Table `gmail_auth_state` (singleton `id=1`, modeled on `calendar_auth_state`) for
authorization telemetry and `revoked` detection. Added to `TestAllTablesExist`.

Watermark: new field `gmail_last_internal_date` on the `workspace` table (same
migration; extending an existing table, not an enum — a plain `ALTER TABLE ADD COLUMN`).

The migration also **extends the `inbox_items.trigger_type` CHECK** with two values:
`email_received` and `email_cc` — via the "table-recreation dance" (modeled on
`00002_target_due_inbox.sql`), since SQLite has no `ALTER TABLE ... ADD CONSTRAINT`.

Required companion changes (per CLAUDE.md):
- mirror the new table and the extended CHECK into `internal/db/schema.sql`;
- add `gmail_messages` and `gmail_auth_state` to `TestAllTablesExist`;
- regenerate the golden snapshot: `go test ./internal/db/ -run TestSchemaGolden -update`;
- Go models in `internal/db/` + access layer (`internal/db/gmail.go`): upsert, reads
  for the detector, watermark handling.

### 3. Detector `internal/inbox/gmail_detector.go`

Modeled on `calendar_detector.go`:

- signature: `func DetectGmail(ctx, database *db.DB, myEmail string, sinceTS time.Time) (int, error)`;
- early exit when `myEmail == ""`;
- reads `gmail_messages` with `synced_at > sinceTS`;
- **fully reads rows into a slice before starting inserts** (guard against a deadlock
  in in-memory SQLite with `MaxOpenConns(1)`);
- `trigger_type` determination: `email_received` if `myEmail` is present in To;
  otherwise (CC only) — `email_cc`;
- `inbox_item` creation:
  - `ChannelID = thread_id` (the thread as a "channel" → grouping in inbox/situations),
  - `MessageTS = message_id` (the Gmail message ID is unique → reliable dedup),
  - `SenderUserID = from_email`,
  - `Snippet = subject + " — " + gmail snippet` (the subject alone is too weak for
    triage; see the "AI processing" section),
  - `Permalink = gmail permalink`;
- local helper `gmailInboxExists` for dedup on `(channel_id, message_ts, trigger_type)`.

### 4. Wiring into the pipeline and daemon

- **`internal/inbox/pipeline.go`**: extend `detectAll` with an additional `email`
  counter and a call to `DetectGmail(...)`; update both call sites — `Run` and
  `RunFastDetection` (positional counters).
- **`internal/inbox/classifier.go`**: add to `defaultClasses`:
  `email_received → actionable`, `email_cc → ambient`.
- **`internal/daemon/daemon.go`**: field `gmailSyncer *gmail.Syncer`, setter
  `SetGmailSyncer`, method `phaseGmailSync(ctx)` (no-op guard if nil), called in
  `runCycle` alongside `phaseCalendarSync`.
- **`cmd/sync.go`**: wiring — if `gmail_token.json` is present, create the client and
  call `d.SetGmailSyncer(...)` (modeled on the Calendar block).

### 5. CLI `cmd/gmail.go`

Modeled on `cmd/calendar.go`:
- `watchtower gmail login` — OAuth, saves `gmail_token.json`;
- `watchtower gmail logout` — removes the token (+ optionally clears `gmail_messages`);
- `watchtower gmail sync` — one-off sync;
- `watchtower gmail status` — connected/not, token path, `cfg.Gmail.Enabled`.

### 6. Config

`internal/config/config.go`: section
`GmailConfig{Enabled bool, InitialHistoryDays int, MaxMessagesPerSync int, MaxBodyBytes int}`
on `Config`. Defaults in `internal/config/defaults.go` (`InitialHistoryDays=7`,
`MaxMessagesPerSync=100`, `MaxBodyBytes=51200` — a safeguard truncating the body for
the strong AI tier), `v.SetDefault(...)` registration in `Load` (modeled on the
Calendar/Jira sections).

### 7. Desktop (`WatchtowerDesktop/`)

- **`Sources/Services/GmailAuthService.swift`** — modeled on `GoogleAuthService.swift`,
  but for `gmail_token.json` and the `gmail login/logout/status` commands. Its own
  `isConnected` status (scans for `*/gmail_token.json`).
- **`Sources/Views/Settings/SettingsView.swift`** — a `gmailSettingsSection` section
  (modeled on `calendarSettingsSection`): status, Connect/Disconnect Gmail button, an
  "Enable Gmail sync" toggle (writes `config.gmailEnabled`), cancel/error handling.
- **`Sources/Views/Inbox/InboxCardView.swift`** — `case`s for `email_received` and
  `email_cc` in `triggerLabel` ("Email"), `triggerSymbol` (`envelope`), `triggerColor`.
- Optional: a filter by Email source via the existing `triggerTypeFilter`.

## AI processing of emails

Emails are NOT processed by a separate email-specific AI call. They flow into the
existing inbox AI pipeline via `inbox_items` and go through the same stages as Slack
signals. What the AI sees at each stage:

1. **Triage** (`inbox.triage`, cheap tier) — for every new email item. Assigns a
   tier (action/awareness/ignore) and priority — this is the importance filter. The
   prompt gets one line per candidate, of the form
   `[TRIGGER] key=item:<id> type=email_received from=<sender> channel=<thread> :: <Snippet>`
   (see `triage.go`, `runTriage`). Triage judges **only by `Snippet`**, so for emails
   `Snippet = subject + Gmail preview` (the subject alone is uninformative). The full
   body is NOT fed to the cheap tier. A trigger item can only be downgraded, never
   upgraded (INBOX-01).
2. **Compose** (`inbox.compose`) — clusters triaged emails into **situations** by
   `thread_id` (a conversation = one situation), merging into an open situation when
   the history matches (DASH-01).
3. **Situation cards** (`inbox.situation_card`, **strong** tier) — why-it-matters /
   summary / chronology. Here the situation context is fed the **full `body_text`**
   of emails (analogous to Slack's member-signal messages). The only hard safeguard:
   emails with a body larger than a reasonable limit (on the order of 50 KB) are
   truncated so an extreme email can't blow the context window; typical business
   emails are fed in full.
4. **Discuss chat** — on user request, a reply draft in the owner's style.

Cost: triage runs cheaply over the entire incoming stream (plus the
PROMOTIONS/SOCIAL cutoff before AI and the `MaxTriageMessages` cap); the expensive
strong tier operates at the situation level, not per email.

The `inbox.triage`/`inbox.compose`/`inbox.situation_card` prompts are shared across
all sources; no separate email prompts are created. The AI distinguishes an email by
`trigger_type` (`email_received`/`email_cc`) in the candidate line. If, during
implementation, it turns out the shared prompts lack sufficient email context, the fix
will be limited to adding an explanation of the email types to the existing templates
(rather than a new prompt).

## Data flow (example)

1. daemon `phaseGmailSync` → `Syncer.Sync` pulls new emails from the Inbox → upserts
   into `gmail_messages`, the watermark advances.
2. daemon `phaseFastInbox`/`phaseInbox` → `DetectGmail` reads new `gmail_messages`
   rows → creates `inbox_items` (`email_received`/`email_cc`).
3. Existing pipeline: triage classifies (important/noise), compose clusters emails
   (by `thread_id`) into situations, situation cards generate a summary.
4. The Desktop Dashboard shows situations; an email item gets an envelope icon and
   label.

## Error handling

- The Gmail detector is individually non-fatal within `detectAll` (the error
  accumulates into `errors.Join`); the aggregate detection error freezes the
  inbox watermark (the window is not lost) — existing behavior.
- `phaseGmailSync` logs a sync error and does not abort the daemon cycle (like
  `phaseCalendarSync`).
- `invalid_grant` on refresh → `ErrAuthRevoked`, a `revoked` entry is written to
  `gmail_auth_state`, sync is skipped until re-authorization.

## Testing

- **Go:** unit tests for `DetectGmail` (item creation, received/cc split, dedup,
  degenerate input — empty table, an email with no CC, etc.); a sync test with a
  mock Gmail HTTP API (modeled on the calendar tests with overridable endpoints); a
  test for migration `00016` (up/down) and the golden snapshot.
- **Swift:** a test for `GmailAuthService` (connect/cancel/status), verifying the
  `TestDatabase.swift` extension for the new table and trigger_type (schema.sql ↔
  TestDatabase.swift must not drift apart).
- Check the actual exit code (don't pipe through tail).

## Risks and dependencies

- **Google verification:** `gmail.modify` is a restricted scope. For
  personal/team use via test users it works immediately; broad production use
  requires a Google security assessment. This is an external process, outside the
  code. See `docs/legal/google-verification.md`.
  - **Revisited 2026-07-09:** ahead of the verification submission the scope was
    narrowed to `gmail.readonly` — the code (`internal/gmail/client.go`) only
    performs `messages.list`/`messages.get` (read-only); nothing writes or
    modifies, so `gmail.modify` was broader than actual use. Trade-off: Plan 3
    (write-back) will require widening back to `gmail.modify` and
    re-authorization/re-verification for all connected users — accepted
    deliberately in exchange for a faster, cheaper (no security assessment)
    verification now.
- **Privacy:** email bodies (`body_text`) are stored locally in SQLite — consistent
  with the existing model of storing Slack messages locally. Confirmed with the
  owner.
- **Data volume:** the `MaxMessagesPerSync` cap and the watermark bound the load;
  the noise filter (PROMOTIONS/SOCIAL) reduces the volume of AI processing.

## Plan 2 (sketch): email digests

The detailed design will be a separate spec; only the direction is fixed here, so
that Plan 1 doesn't close off the path to it.

- Source — the same `gmail_messages` table (built by Plan 1); pseudo-`messages`
  are NOT created.
- A new generator (modeled on `internal/digest/`) groups emails (by thread/label/
  sender — TBD) and writes records into the `digests` table. `digests.channel_id` is
  a required key, so an email digest needs a synthetic stable "channel" identifier
  (e.g. `email:<label>` or `email:<thread_id>`); the digest type is TBD (possibly a
  new `digests.type` value).
- Tracks pick up email digests automatically (they read `digests`). Known
  limitation: `key_messages`/`source_refs` in a non-Slack `ts` format are dropped by
  the `reSlackTSExact` regex in tracks — enrichment with links to the source emails
  degrades. Resolved either by relaxing the regex or by a separate email-ref format
  (decision to be made in the Plan 2 spec).
- The daily briefing includes email digests as another input type.
- People statistics for external contacts are NOT part of Plan 2 (requires direct
  `JOIN`s on `messages`, i.e. effectively Option B).

## What's NOT included (explicitly deferred)

- Email digests/tracks/briefing — Plan 2 (see above), not part of Plan 1.
- Write-back of statuses (read/archived) to Gmail — Plan 3.
- Sending emails from Watchtower (`gmail.send`) — not planned for this iteration.
- Merging email into the `messages` table (Option B) — rejected, see the "Scope"
  section.
- People statistics for external email contacts — out of scope (requires Option B).
- IMAP / Outlook / other providers — Gmail only.
- historyId-based incremental sync — a possible improvement later.
- A separate email category in `targets.source_type` / `feedback.entity_type` —
  not needed (an email item is a regular `inbox` source).
