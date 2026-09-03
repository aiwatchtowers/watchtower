# Catch-Up as an absence recap — design

**Date:** 2026-09-04
**Status:** approved in conversation (owner), pending spec review
**Supersedes:** `2026-06-20-catch-up-review-mode-design.md`, `2026-06-25-catchup-iterative-peel-design.md` (the review-session model)

## 1. Why

The owner's actual use of Catch-Up: *"I was away today. I want a recap of what
the company was doing while I was gone."* The shipped Catch-Up answers a
different question — *"what is still unread in Watchtower's own surfaces"* — and
makes the operator work through it one theme at a time with a Done button.

The two differ on every axis:

| | Today (review mode) | Wanted (absence recap) |
|---|---|---|
| Selector | read-state (`read_at IS NULL`) across 4 internal surfaces | a **time window** (the absence) |
| Material | digests, tracks, inbox, briefings — Watchtower's own outputs | what the company did: Slack, Jira, Gmail, meetings, decisions — plus what waits for the owner |
| Output | N themes reviewed one at a time, progress "3 of 12" | one document read top to bottom, topics expandable into their sources |
| Read-state | per-theme Done cascades mark-read over the theme's refs | one **"I'm caught up"** action marks the whole window read |
| History | one active session, replaced on every run | every recap kept; "caught up until T" drives the next auto-window |

This spec replaces the review-session model with an absence recap. The sidebar
tab keeps its name and place.

## 2. Goals / non-goals

**Goals**

- One CLI run produces a persisted, structured recap of a time window from
  material Watchtower already summarises (channel digests, Gmail/Jira stream
  digests, meeting recaps, the decisions ledger) plus the owner-facing items in
  that window (inbox triggers, track updates, target deadlines).
- Freshness without a second extractor: a run first *tops up* the existing
  digest pipelines over the uncovered tail of the window.
- A single "I'm caught up" action marks everything in the window read on the
  surfaces that carry `read_at`, on both the Go and Swift write paths.
- The recap document is the Desktop surface: TL;DR, topics with inline source
  cards, decisions, meetings, "for you", one action bar.
- Feedback on a topic still derives learned rules for the source pipelines.

**Non-goals (v1)**

- Reading raw Slack messages / Jira issues / emails directly (approach 2 in the
  brainstorm — rejected: a second extractor next to the digest pipeline).
- A daemon phase that builds recaps automatically on return. On-demand only.
- Per-topic regeneration. Regen rebuilds the whole recap for the same window.
- Migrating old review sessions. They hold review state, not history.
- Cross-account disambiguation beyond what the source pipelines already do.

## 3. Window semantics

All timestamps below are Unix seconds (REAL) in Go; local time is used only to
compute preset boundaries and to render labels.

- **Auto** (no flags, the Desktop default): `from` = `period_to` of the most
  recent recap with `acknowledged_at IS NOT NULL`; if none exists, `now − 24h`.
  `to` = `now`. This is exactly what "I'm caught up" means: *up to date until T*.
- **Presets** (`--preset today|yesterday|3d|week`), local time:
  `today` = today 00:00 → now; `yesterday` = yesterday 00:00 → today 00:00;
  `3d` = now − 3×24h → now; `week` = now − 7×24h → now.
- **Custom** (`--from`, `--to`): `YYYY-MM-DD` (local midnight) or RFC 3339.
  `--to` defaults to `now`.
- Validation: `from < to`; a window longer than `maxWindowDays` (31, a code
  constant — not config) is rejected. Presets and custom are mutually
  exclusive with each other; `--regen` implies the source recap's window.
- Every run creates a **new** `catchup_recaps` row. Building the same window
  twice is allowed and produces two rows.

The Desktop shows the resolved auto boundary before the run ("since Thu 18:40")
by reading the same rule from the DB (`CatchUpQueries.autoWindowStart`). That
is a deliberate read-only mirror of the Go rule, not a write dual-path: Go stays
authoritative at run time and the CLI never receives the Swift-computed value in
auto mode.

## 4. Data model

Migration `00061_catchup_recaps.sql`:

```sql
-- +goose Up
DROP TABLE IF EXISTS catchup_themes;
DROP TABLE IF EXISTS catchup_sessions;

CREATE TABLE catchup_recaps (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    period_from     REAL NOT NULL,
    period_to       REAL NOT NULL,
    status          TEXT NOT NULL CHECK(status IN ('building','ready','failed')),
    tldr            TEXT NOT NULL DEFAULT '',
    body_json       TEXT NOT NULL DEFAULT '{}',
    coverage_json   TEXT NOT NULL DEFAULT '{}',
    error           TEXT NOT NULL DEFAULT '',
    regen_of_id     INTEGER REFERENCES catchup_recaps(id) ON DELETE SET NULL,
    acknowledged_at TEXT,
    model           TEXT NOT NULL DEFAULT '',
    input_tokens    INTEGER NOT NULL DEFAULT 0,
    output_tokens   INTEGER NOT NULL DEFAULT 0,
    cost_usd        REAL NOT NULL DEFAULT 0,
    created_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);
CREATE INDEX idx_catchup_recaps_ack ON catchup_recaps(acknowledged_at, period_to DESC);

-- +goose Down
DROP TABLE IF EXISTS catchup_recaps;
-- recreate catchup_sessions / catchup_themes exactly as 00003 defined them (empty)
```

`schema.sql` mirrors the new table and drops the two old ones;
`TestAllTablesExist` and the schema golden are updated.

**`body_json`** — the validated compose output:

```json
{
  "topics":    [{"title": "", "narrative": "", "priority": "high|medium|low",
                 "refs": [{"area": "", "id": 0, "label": ""}]}],
  "decisions": [{"text": "", "refs": [...]}],
  "meetings":  [{"title": "", "summary": "", "refs": [...]}],
  "needs_you": [{"text": "", "kind": "mention|dm|email|track|target_due",
                 "refs": [...]}]
}
```

`area` ∈ `digests | streams | recaps | transcripts | decisions | inbox | tracks | targets`
— one table per area (`digests`, `stream_digests`, `meeting_recaps`,
`meeting_transcripts`, `ideas`, `inbox_items`, `tracks`, `targets`) so the
Desktop can resolve any ref to a row and render it inline. `CatchupRef`
(`{area,id,label}`) is kept as the ref shape on both sides.

**`coverage_json`** — what the recap was actually built from:

```json
{"slack_to": 0, "streams_to": 0, "meetings": 0,
 "topup": "ok|skipped|failed", "topup_error": ""}
```

`slack_to` / `streams_to` are the latest `period_to` of a channel / stream
digest inside the window (0 when none); `meetings` is the count of meeting
items gathered. The Desktop renders this as the header coverage line.

## 5. Pipeline — `catchup run`

`internal/catchup/` keeps its name; peel/expand and the session store go away.

```
resolveWindow → insert(building) → topUp → gather → compose → validate → persist(ready|failed)
```

### 5.1 Top-up

Runs only when the window touches "now" (`to ≥ now − 5 min`). It calls the
same entry points the daemon uses, with the same feature gates:

- `digest.Pipeline.RunChannelDigestsOnly` when `digest.enabled`;
- `ideas.Pipeline.RunStreamDigests` when `streams.enabled`.

A gated-off pipeline is skipped silently; `coverage.topup = "skipped"` records
that no top-up ran at all (window in the past, or both gates off). Any error is
logged and recorded (`topup = "failed"`, `topup_error`) and
the run continues on whatever coverage exists — **a top-up failure never fails
the recap** (CATCHUP-03). No new locks: concurrent daemon runs are already
guarded by `UNIQUE(channel_id, type, period_from, period_to)` and the digest
cooldown; a collision just means one side finds nothing new to do.

### 5.2 Gather

Eight window queries in `internal/db/catchup.go` (rewritten), each capped by
`catchup.caps.*` and returning display-ready rows the prompt builder renders:

| area | query | window predicate |
|---|---|---|
| `digests` | channel digests + their `digest_topics` (title, summary), channel name | `type='channel' AND period_to > from AND period_from < to`, newest first |
| `streams` | `stream_digests` (source, account label, scope, `topics_json`) | overlap on `period_from`/`period_to` (ISO) |
| `recaps` | `meeting_recaps` (+ event title/time when the `calendar_events` row still exists, else the linked transcript's title) | `created_at` in window |
| `transcripts` | ad-hoc `meeting_transcripts` (`event_id IS NULL`, `summary_json IS NOT NULL`) | `created_at` in window |
| `decisions` | `ideas WHERE kind='decision'` with a mention whose `said_at` (or `created_at` when empty) is in window; latest quote + source | mention in window |
| `inbox` | `inbox_items`: `item_class='actionable'`, `status IN ('pending','snoozed')`, with sender / channel names and permalink | `created_at` in window |
| `tracks` | non-dismissed tracks (text, context snippet, priority, ownership) | `updated_at` in window |
| `targets` | open targets (`status NOT IN ('done','dismissed')`) | `due_date` in window, or `due_date < to` (overdue) |

Meetings are keyed on the recap's `created_at`, not the calendar event's time,
because the calendar sync retains only ~24 h of past events while
`meeting_recaps` / `meeting_transcripts` survive (`ON DELETE SET NULL`). The
recap is generated right after the meeting, so the approximation is good enough
and documented. DM channels never reach channel digests, so nothing private
enters the recap that was not already in Digests.

An empty gather (all eight lists empty) persists `status='ready'` with an empty
body and makes **no AI call**; the Desktop renders "Quiet — nothing happened in
this window."

### 5.3 Compose

One strong-tier call, source tag `catchup.compose`, prompt id
`prompts.CatchupCompose = "catchup.compose"` registered in the prompt store
(`Defaults` / `AllIDs` / `DefaultVersions`, per the `add-ai-prompt` skill) so
the template is tunable. The system prompt always carries
`prompts.Directive(cfg.Digest.Language)` (CATCHUP-02).

User message, in order:

1. Window header (local, human-readable) and the owner profile
   (`workspace.secretary_profile`, the `buildSecretaryBrief` precedent).
2. Learned preferences for pipeline `catchup` (`LearnedPreferencesBlock`).
3. The optional **OPERATOR CORRECTION** block (regen only, authoritative).
4. Sections, each row tagged `[area#id]`: `SLACK DIGESTS`, `EMAIL / JIRA
   STREAMS`, `MEETINGS`, `DECISIONS`, `FOR YOU — INBOX`, `TRACKS UPDATED`,
   `TARGETS DUE`.

Per-item text is trimmed (digest summary 400 chars + up to 5 topic lines,
stream topic 200 chars, recap summary 600 chars + decisions/action items,
decision essence 300 chars, inbox snippet 280 chars). The whole message is
bounded by `catchup.max_prompt_chars`; when over budget, trailing items are
dropped list by list in the fixed order **streams → tracks → decisions →
digests** until it fits. Inbox, targets and meetings are never trimmed. The
generator already streams messages > 32 KB via stdin.

The prompt asks for the `body_json` shape plus `tldr` (3–5 sentences). Rules
stated to the model: only facts present in the input; every topic, decision,
meeting and needs-you item cites the `[area#id]` tags it was built from; an item
addressed to the owner personally goes to `needs_you`, not `topics`; priority
reflects consequence for the owner, not volume.

### 5.4 Validate (CATCHUP-04)

Go disposes what the model proposes:

- A ref whose `(area,id)` was not in the gathered set is dropped and counted
  (`refs_rejected` in the CLI envelope); a missing label is filled from the
  gathered row.
- A topic / decision / meeting / needs-you item left with **zero valid refs is
  dropped** — no provenance, no claim (the IDEA-02 rule).
- `priority` and `kind` are normalised to their CHECK vocabularies with a
  `medium` / `mention` fallback.

The validated body is what gets persisted. An invented reference never reaches
`body_json`.

### 5.5 Persist

Success: `status='ready'`, `tldr`, `body_json`, `coverage_json`, model / tokens
/ cost. AI or parse error: `status='failed'`, `error`, everything else left as
written by the earlier steps. A failed recap is retried by running again (a new
row); nothing is edited in place.

### 5.6 Regen

`catchup run --regen <id> [--comment "..."]` rebuilds the **same window** as a
new row with `regen_of_id = <id>`, the comment rendered as the OPERATOR
CORRECTION block. The original stays in history; the Desktop labels the new row
"regenerated". No top-up on regen (the window is in the past by definition, and
the point is the correction, not fresh coverage).

## 6. "I'm caught up" — acknowledge (CATCHUP-01)

`Acknowledge(recapID)` stamps `acknowledged_at` and marks read **everything in
the window** on the five surfaces that carry `read_at`:

| surface | predicate | write |
|---|---|---|
| `digests` | `period_to > from AND period_to <= to AND read_at IS NULL` | `read_at = now` |
| `stream_digests` | same on ISO `period_to` | `read_at = now` |
| `tracks` | `updated_at` in window `AND dismissed_at = ''` | `read_at = now, has_updates = 0` |
| `inbox_items` | `created_at` in window `AND read_at IS NULL` | `read_at = now` |
| `briefings` | `date` between the window's local dates | `read_at = now` |

Set-based updates, one transaction, idempotent (`read_at IS NULL` /
`has_updates` predicates; a second ack changes nothing). By **window**, not by
cited refs — predictable, and it matches the meaning "up to date until T".

The vestigial Go-only cascade `MarkDigestRead → decision_reads` is not carried
over: decisions live in the ideas ledger (`seen_at`) since 2026-08-12 and nothing
reads `decision_reads`. `MarkDigestRead` itself is untouched (other callers).

**Two implementations, one behaviour** — as today: Go
(`Pipeline.Acknowledge`, CLI `catchup ack <id>`) and Swift
(`CatchUpQueries.acknowledge(recap:)`, the Desktop button writing the shared DB
directly). The guard tests stay paired.

## 7. Feedback and learned rules

`catchup feedback <recap-id> --topic <idx> --rating up|down [--comment]`:

- Always records a `feedback` row: `entity_type = 'catchup_theme'` (kept — a
  topic *is* the renamed theme, and expanding the CHECK would need the
  table-recreation dance for no gain), `entity_id = "<recap_id>:<topic_idx>"`
  (the documented `"digest_id:decision_idx"` convention).
- A bare rating makes no AI call (unchanged).
- With a comment, `learn.go` runs as today with the topic's title, narrative
  and refs; `FetchItemScopeHints` learns the new areas (`digests` → channel,
  `inbox` → channel + sender, everything else → no hints). The interpreter's
  `regenerate` flag now triggers a whole-recap regen (§5.6) with the comment.

Rules land in `inbox_learned_rules` addressed to `digest` / `tracks` / `inbox` /
`briefing` / `catchup` exactly as before.

## 8. CLI

```
watchtower catchup run [--preset today|yesterday|3d|week | --from X [--to Y]]
                       [--regen <id> [--comment "..."]] [--json]
watchtower catchup ack <recap-id>
watchtower catchup feedback <recap-id> --topic <idx> --rating up|down [--comment "..."]
watchtower catchup list [--json]        # recent recaps: id, window, status, acknowledged
watchtower catchup show <recap-id>      # the document as text
```

`run` prints the document as text, or with `--json` an envelope
`{recap_id, status, period_from, period_to, coverage, refs_rejected, error}`
plus the body. Exit code is non-zero only when no recap row could be created
(config / DB errors); a `failed` recap exits 0 with `status: "failed"` so the
Desktop reads the outcome from the row, not the exit code. `regen` is folded
into `run`; the old `regen <theme-id>` subcommand goes away.

## 9. Config

```yaml
catchup:
  caps:
    digests: 150
    streams: 40
    meetings: 20
    decisions: 40
    inbox: 120
    tracks: 80
    targets: 40
  max_prompt_chars: 120000
```

Removed: `catchup.max_age_days` (the window replaces it), `catchup.caps.briefings`
(briefings are not a source; they are derived from the same material). Unknown
legacy keys in an existing `config.yaml` are ignored by viper — no migration.

Model routing: `catchup.compose` → strong tier; `catchup.learn` stays light.
`catchup.peel` / `catchup.expand` are removed from `digest.TierForSource` and
the codex table.

No feature-registry entry: Catch-Up stays a reader gated in the sidebar by
`slack-digests`, as today.

## 10. Desktop

Sidebar tab unchanged (`.catchUp`, "Catch Up", feature gate `slack-digests`).
Layout follows the Recordings master-detail.

**Left column**

- Window bar: segmented Auto ("since Thu 18:40") | Today | Yesterday | 3 days |
  Week | Range (two `DatePicker`s, the `CustomTrackTimelineView` precedent) and
  a Build button. Auto passes no window flags (Go resolves it); presets pass
  `--preset`; Range passes explicit `--from/--to` RFC 3339. Disabled while a
  build runs.
- Recap list: one row per recap — window label ("Sat 4 Sep, 09:00 → 18:30",
  "31 Aug – 2 Sep"), a "caught up" check for acknowledged rows, spinner for
  `building`, red mark for `failed`, "regenerated" tag when `regen_of_id` is
  set. Newest first.

**Right pane — the document**

- Header: window, coverage line from `coverage_json` ("Slack to 17:40 · Jira to
  14:00 · 3 meetings"; "coverage top-up failed" when applicable).
- TL;DR.
- **What happened** — topic cards: title, priority chip, narrative. Expanding a
  card lists its refs; each ref renders inline via the area's compact view.
- **Decisions**, **Meetings**, **For you** — lists; every item's refs open the
  same inline views, and inbox / track / target items also link to their own
  surface (`AppState` navigation, as the current `openSource`).
- Action bar: **I'm caught up** (direct DB write; becomes a label once
  acknowledged), **Regenerate** with a comment field (CLI `run --regen`), and
  on each topic card 👍/👎 + comment (CLI `feedback`).
- Empty body → "Quiet — nothing happened in this window." Failed → the error
  with a Retry (a new run, same window).

**Inline source views** (`CatchUpSourceInline.swift`, read-only, no view
models — the current principle): `DigestInlineDetail` and `TrackInlineDetail`
are reused; new compact views `StreamDigestInline` (topics from `topics_json`),
`MeetingRecapInline` (summary, key decisions, action items — reads
`meeting_recaps.recap_json` or the transcript's `summary_json`),
`DecisionInline` (title, essence, latest mention quote), `InboxItemInline`
(snippet, sender, permalink), `TargetInline` (text, due, status). Split into a
second file if the first passes ~350 lines.

**View model** (`CatchUpViewModel`, rewritten): observes `catchup_recaps` via
GRDB `ValueObservation`; while a build runs, polls once a second because the
CLI writes from another process (the existing pattern); runs the CLI on a
detached task; holds `recaps`, `selected`, `isBuilding`, `error`, the window
choice, and the acknowledged / feedback in-flight flags. Survives navigation on
`AppState` as today.

**Core** (`WatchtowerCore`, tests in `Tests/Core`): `CatchUpModels.swift` —
`CatchUpRecap` (row), `CatchUpRecapBody` / `CatchUpTopic` / `CatchUpNeedsYou`
(Codable, tolerant decoding), `CatchUpCoverage`, `CatchUpRef` (kept);
`CatchUpQueries.swift` — `fetchRecaps`, `fetchRecap`, `observeRecaps`,
`autoWindowStart`, `acknowledge(recap:)`, `hasUnacknowledgedReady`.

**Sidebar badge**: `1` when a `ready` recap exists with `acknowledged_at IS
NULL`, else nothing. `SidebarCountsViewModel` already observes `catchup_*`
tables; only the query changes (table name + predicate).

**Deleted**: `CatchUpThemeRow.swift`, `CatchUpReviewPane.swift`, the theme /
session models and queries, `CatchUpViewModelTests` for sessions.

## 11. What is retired

- Go: `peel`, `expandOne`, `RegenTheme`, per-theme `Acknowledge`,
  `markLeftoverRead`, `GetUnread*`, `FetchItemSnippet`, the session / theme store
  (`internal/db/catchup_store.go`), `catchup.peel` / `catchup.expand` prompts
  and tier tags, `catchup regen` subcommand, `catchup.max_age_days`,
  `catchup.caps.briefings`.
- Schema: `catchup_sessions`, `catchup_themes`.
- Desktop: theme row, review pane, session VM and their tests.
- Docs: the two superseded specs stay in place with a "superseded by" line at
  the top; `docs/inventory/catchup.md` is rewritten (§12); the CLAUDE.md mention
  of "Catch-Up-style master-detail" in the dashboard section is left as is (it
  describes a layout, still true).

## 12. Inventory contracts (owner-approved in this conversation)

`docs/inventory/catchup.md` is rewritten. Guard tests keep the
`TestCatchupNN_` convention and the Go/Swift pairing.

- **CATCHUP-01 — Caught up once here, read everywhere.** Acknowledging a recap
  marks read everything inside its window on the five `read_at` surfaces
  (digests, stream digests, tracks, inbox, briefings), idempotently, on both
  the Go and Swift paths. Items outside the window are untouched.
  Guards: `TestCatchup01_AcknowledgeMarksWindowRead`,
  `TestCatchup01_AcknowledgeIsIdempotent` (Go);
  `testAcknowledgeMarksWindowReadOnFiveSurfaces`,
  `testAcknowledgeLeavesItemsOutsideWindowUnread`,
  `testAcknowledgeIsIdempotent` (Swift, `Tests/Core`).
- **CATCHUP-02 — Catch-Up speaks my configured language.** The compose system
  prompt always carries `prompts.Directive(digest.language)`.
  Guard: `TestCatchup02_ComposePromptCarriesLanguageDirective`.
- **CATCHUP-03 — Coverage top-up never sinks the recap.** A failing or disabled
  top-up is recorded in `coverage_json` and the recap still reaches `ready`
  from existing coverage. Guard: `TestCatchup03_TopUpFailureStillProducesRecap`.
- **CATCHUP-04 — An invented reference never persists.** A ref not in the
  gathered set is dropped and counted; an item with no valid refs is dropped.
  Guard: `TestCatchup04_InventedRefsAreDroppedNotPersisted`.

The old CATCHUP-03 ("one bad theme never sinks the run") has no counterpart —
there are no per-theme calls any more.

## 13. Testing

**Go** (`internal/catchup`, `internal/db`, `cmd`), mock generator per the
`add-ai-prompt` skill:

- window resolution: auto from the last acknowledged recap, the 24 h fallback,
  presets against a fixed local clock, custom parsing, `from < to`, the 31-day
  cap;
- the eight gather queries (in-window vs outside, caps, the meeting title
  fallback when the calendar row is gone, decision mention `said_at` fallback);
- empty gather → `ready`, empty body, zero generator calls;
- compose: prompt sections present, budget trimming order, `refs_rejected`,
  zero-ref items dropped, priority / kind normalisation;
- top-up: skipped when the window is in the past, skipped when gates are off,
  failure recorded and non-fatal;
- persist: failed status on AI / parse error, regen row carries `regen_of_id`
  and the correction block;
- acknowledge: five surfaces, window edges, idempotency;
- feedback: bare rating makes no AI call, comment derives rules, `regenerate`
  triggers a regen row;
- `TestSchemaGolden -update`, `TestAllTablesExist`, migration up/down.

**Swift** (`Tests/Core` where possible): `CatchUpQueries` fetch / observe /
`autoWindowStart` / acknowledge guards; `CatchUpRecapBody` tolerant decoding
(missing fields, unknown areas); `CatchUpViewModel` build → poll → ready
transition and the acknowledged label flip.

Inner loop per CLAUDE.md (`go test ./internal/catchup`, `make test-swift
FILTER=CatchUp…`); gate before the PR: `make test`, `make test-swift`,
`make lint-all`, then `local-review`.

## 14. Known limitations (v1, documented)

- Channels below `digest.min_messages` in the window never reach a channel
  digest and therefore never reach the recap. Known cost of approach 1.
- Meeting placement in the window uses the recap's `created_at`, not the event
  time (calendar retention).
- Top-up cost: a run may trigger a burst of digest generation the daemon would
  otherwise have done on its next tick — work moved earlier, not added.
- A recap built for a window in the past is not topped up; it reflects the
  digests that existed when it ran.
