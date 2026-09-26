# Fix checklist for the 2026-07-05 audit (High-severity)

A consolidated actionable list from six audit reports (`docs/review/2026-07-05-audit-*.md`).
All 23 items are severity **high**, each ✅ confirmed by an independent verifier (Opus 4.8).
No criticals. Medium/Low are listed at the end as links to the detailed reports.

Grouped by **root cause**, not by area — this makes them easier to fix in batches.
Batch order = recommended work order (top to bottom: cheap+unblocking → expensive).

### Recommended model routing

The criterion isn't "complexity" but **cost of error / reversibility**. Pattern: implementation on a cheap model, verification of everything critical on Opus (via the `local-review` / `debate-review` skill).

| Batch | Topic | Executing model |
|---|---|---|
| 1 | `tasks`→`targets` rename | **Sonnet 5** — mechanical, caught by tests |
| 5 | filters/dedup | **Sonnet 5** — local, covered by tests |
| 3 | day-plan timezones | **Sonnet 5** + verify on **Opus** — TZ is easily "almost correct" |
| 8 | daemon resilience | **Sonnet 5** + verify on **Opus** |
| 2 | watermark (5 spots) | **Opus** — silent data loss, needs an invariant |
| 4 | data/config destruction | **Opus** — 4.1 requires a compensating migration, irreversible |
| 6 | UI cross-process | **Opus** designs the refresh mechanism → **Sonnet** wires it across 3 VMs |
| 7 | security | first an owner decision on the threat model, then anyone |

Do not put Fable in as the lead executor for a long checklist — it hit the limit in this session.
Start with Batch 1 first (item 1.4 → unblocks tests for the rest).

---

## Batch 1 — Incomplete `tasks` → `targets` rename (4 items)

> The `tasks` table was renamed to `targets`, but some of the Swift code and the test schema weren't migrated.
> A mechanical fix that resolves 3 Highs and unblocks tests that are currently passing blind.
> **Start here** — item 1.4 needs to be done first, otherwise the other three aren't caught by tests.

> ✅ **BATCH COMPLETED (2026-07-05, Sonnet 5).** Production fix + migration of test fixtures to `targets`. `swift build` OK, `swift test` 1006/1006 (independently re-verified, exit 0). Open question on `wipeLLMData` (see 1.3). Not committed.

- [x] **1.1 — Channels screen is completely broken**
  `WatchtowerDesktop/Sources/Database/Queries/ChannelStatsQueries.swift:190`
  `fetchValueSignals` (both the primary and fallback SQL) references the removed `tasks` table → the screen fails to load.
  *Fix:* replace `tasks` → `targets` in both queries, cross-check column names against the `targets` schema.

- [x] **1.2 — Marking task items done/pending in Day Plan always fails**
  `WatchtowerDesktop/Sources/Database/Queries/DayPlanQueries.swift:182`
  The cascade writes to the removed `tasks` table → exception, status doesn't change.
  *Fix:* rewrite the cascade to use `targets`.

- [x] **1.3 — "Wipe LLM data" is completely non-functional**
  `WatchtowerDesktop/Sources/Database/DatabaseManager.swift:116`
  `DELETE FROM tasks` rolls back the entire transaction → nothing gets cleared.
  *Fix:* `tasks` → `targets`; verify the list of tables to delete matches the current schema.

- [x] **1.4 — Test schema has diverged from the real one (DO THIS FIRST)**
  `WatchtowerDesktop/Tests/Helpers/TestDatabase.swift:469`
  The hand-written schema in tests still contains `tasks` → tests pass blind on SQL against tables that don't exist in production. This is exactly why 1.1–1.3 weren't caught.
  *Fix:* replace the hardcoded schema with a load of the real `internal/db/schema.sql` (or generate it from the migrations), then run `swift test` — it should go red on 1.1–1.3 until they're fixed.

**Batch check:** `cd WatchtowerDesktop && swift test` — after 1.4 it fails on 1.1–1.3, after fixing those it's green. Also `grep -rn '\btasks\b' WatchtowerDesktop/Sources` should return no references to the table.

---

## Batch 2 — Watermark moves independently of whether data was actually fetched (5 items)

> A cross-cutting antipattern: the "processed up to here" pointer advances based on time/call success,
> rather than on the fact that data was actually fetched. Always silent. The most dangerous group — silent data loss.

> ✅ **BATCH COMPLETED (2026-07-05, Opus, TDD).** All 5 items fixed with a failing-test-first approach. `go test ./internal/sync/... ./internal/inbox/... ./internal/jira/...` — pass, gofmt/vet clean (independently re-verified in an isolated worktree). For 2.3, formalized a new contract **INBOX-09** ("Detection failure never advances the watermark") in `docs/inventory/inbox-pulse.md` + guard test `TestInbox09_WatermarkFrozenOnDetectorError` (contract change authorized by the owner). Note on 2.4: the fix moved to a TZ-independent relative window `updated >= -Nm` + a 2-minute overlap — if an absolute variant with conversion to the instance's TZ is needed, it will require an additional `/myself` request. Not committed.

- [x] **2.1 — `search_last_date` advances on early pagination interruption**
  `internal/sync/search_sync.go:181`
  The watermark is set to "today" even when search pagination stopped early (error/limit) → un-fetched messages are permanently skipped.
  *Fix:* only advance the watermark to the oldest successfully fetched ts, or don't advance it at all when pagination is incomplete.

- [x] **2.2 — A token without the `search:read` scope silently syncs zero messages**
  `internal/sync/orchestrator.go:167`
  After the first sync, every incremental sync on such a token fetches zero messages but reports success.
  *Fix:* detect the missing scope/`search.messages` error and return an explicit error (or fall back to the full-sync path), rather than "success, 0 messages".

- [x] **2.3 — Inbox watermark shifts by wall-clock time on sync failure**
  `internal/inbox/pipeline.go:329`
  `inbox_last_processed_ts` advances based on time even when the Slack sync or detectors fail → mentions/DMs in the missed window are permanently lost.
  *Fix:* only advance the watermark after a successful detector pass; leave it unchanged on error.

- [x] **2.4 — Jira: UTC timestamp compared against JQL in the user's timezone**
  `internal/jira/sync.go:107`
  The incremental sync compares a UTC watermark against JQL, which is interpreted in the user's TZ → for users west of UTC, issues updated after the watermark are skipped.
  *Fix:* convert the watermark to the Jira instance's TZ (or build the JQL explicitly in UTC).

- [x] **2.5 — Jira `SyncBoard` doesn't backfill closed issues**
  `internal/jira/sync.go:190`
  The project watermark advances after syncing only non-terminal issues → closed ones are never backfilled, contrary to its own documented logic.
  *Fix:* only advance the watermark after a full pass (including terminal statuses), or maintain a separate watermark for terminal ones.

**Batch check:** unit tests for each watermark with a "partial/failed pass doesn't advance the pointer" case (see memory: [Test degenerate clean-exit branches]).

---

## Batch 3 — Timezones in Day Plan break all non-UTC users (2 items)

> ✅ **BATCH COMPLETED (2026-07-05, Sonnet, TDD; verified on Opus).** `go test ./internal/dayplan/...` exit 0, gofmt/vet clean (in an isolated worktree). 3.1 — `shortTime` `t.UTC()`→`t.Local()`. 3.2 — `if ev.IsAllDay { continue }` in `aiToTimeblock`, following the pattern in `meeting/pipeline.go:115`.
> ⚠️ **Audit undercounted:** the same all-day bug was found in 2 more places not flagged by the audit — `conflicts.go` (`DetectConflicts` marked every block as conflicting) and `calendar_sync.go` (inserted all-day events as a 1440-minute timeblock). Both confirmed by reading the code and fixed with the same pattern (TDD). UX question: whether to show all-day events in the day timeline as a separate banner — deferred as a follow-up (currently they simply don't create a timeblock).

- [x] **3.1 — Calendar events are rendered in UTC in the prompt**
  `internal/dayplan/prompt.go:213`
  The prompt prints events in UTC, while validation and "now" are in local time → AI timeblocks that visually overlap with events get discarded for any non-UTC user.
  *Fix:* render events in the same local TZ used for validation and `now`.

- [x] **3.2 — All-day events aren't excluded from overlap checking**
  `internal/dayplan/merge.go:69`
  A single "all day" event covers 00:00–24:00 → all AI timeblocks get flagged as conflicting and are cut.
  *Fix:* exclude all-day events from overlap validation (or treat them as background, non-blocking).

**Batch check:** a day-plan merge test with TZ = `America/Los_Angeles` + one all-day event → timeblocks are preserved.

---

## Batch 4 — Destruction of user data/config (2 items)

- [x] **4.1 — Migration 00002 wipes all of `inbox_feedback`**
  `internal/db/migrations/00002_target_due_inbox.sql:48`
  The `DROP TABLE` cascade (table-recreation dance) wipes out `inbox_feedback` → the user's learned rules are lost.
  *Fix:* preserve/restore `inbox_feedback` inside the migration, or don't touch it as part of this migration. **Caution:** the migration may have already been applied for users — a compensating migration is needed, not an edit to the old one.

- [x] **4.2 — `ConfigService.save()` overwrites config from CLI logins**
  `WatchtowerDesktop/Sources/Services/ConfigService.swift:122`
  Writes a stale in-memory YAML snapshot → sections written by the CLI login flow (e.g., Jira) get erased.
  *Fix:* re-read config.yaml immediately before writing and merge, instead of writing the stored snapshot. Cross-check against the memory on [CLAUDE_CONFIG_DIR breaks keychain auth] and dual-path writes.

---

## Batch 5 — Filter/deduplication logic (2 items)

- [x] **5.1 — Inbox dedup merges unrelated items of different trigger types**
  `internal/db/inbox.go:328`
  Deduplication collapses items across the trigger_type boundary → a pending mention and a DM get silently resolved as a "duplicate".
  *Fix:* include `trigger_type` (and/or `thread_ts`) in the dedup key.

- [x] **5.2 — `targets --status done/dismissed` always returns empty**
  `cmd/targets.go:342`
  The done/dismissed exclusion is ANDed together with the user-provided status filter → a mutually exclusive condition.
  *Fix:* apply the default done/dismissed exclusion only when `--status` isn't explicitly set.

---

## Batch 6 — UI: state isn't reflected in the interface (4 items)

> Common root cause for 6.1–6.2: the CLI writes to the DB from another process, while `ValueObservation`
> only reacts to writes from its own process. It's worth building a single push-update mechanism
> after a CLI scan (file trigger / notification / poll-refresh).

- [x] **6.1 — Watch tab scan results don't show up in the feed**
  `WatchtowerDesktop/Sources/ViewModels/TargetWatchesViewModel.swift:96`
  The scan runs as a CLI subprocess → the DB write is invisible to `ValueObservation` → the feed doesn't update.
  *Fix:* force a reload of the query after the CLI scan completes (or a shared cross-process refresh, see the note above).

- [x] **6.2 — Custom track timeline doesn't show results found by a manual scan**
  `WatchtowerDesktop/Sources/ViewModels/CustomTrackTimelineViewModel.swift:101`
  Same cross-process root cause. Plus a comment in the code claims ValueObservation catches this — it's wrong.
  *Fix:* same as 6.1; also fix/remove the misleading comment.

- [x] **6.3 — Provider switcher in chat doesn't change the provider**
  `WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift:109`
  The picker sends the selected provider's model, but to the actually configured (different) provider → incompatible model.
  *Fix:* switch both the provider and the model consistently; validate that the model belongs to the active provider.

- [x] **6.4 — Stopping streaming duplicates the assistant's response**
  `WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift` (Stop button, see the ui-bugs report)
  The partial response gets saved twice → duplicate message in the DB and UI.
  *Fix:* make saving the partial response idempotent (a single write path on stop).

---

## Batch 7 — Security (4 items)

> Requires an explicit owner decision on the threat model — not mechanical fixes.

- [x] **7.1 — Prompt injection → arbitrary command execution**
  `internal/ai/client.go:103`
  The AI chat is given an unsandboxed `Bash(sqlite3*)`. Malicious Slack/Jira content that ends up in the prompt could make the AI execute a command.
  *Fix:* remove raw `Bash` from the chat's allowed tools; access to data only via a restricted read-only MCP.

- [x] **7.2 — The AI chat has read/write SQLite access via `mcp__sqlite__*`**
  `internal/ai/client.go:132`
  Full write access bypasses the claimed read-only MCP contract.
  *Fix:* switch the MCP to strictly read-only (query whitelisting / a separate connection in query-only mode).

- [x] **7.3 — Slack OAuth installs a trusted CA root for 10 years**
  `internal/auth/cert.go:176`
  Login installs a 10-year CA certificate as a trusted SSL root, with the private key stored on disk (Superfish-class).
  *Fix:* reconsider whether TLS interception is needed; if a local redirect is required — don't install a system-trusted CA, use loopback without MITM. Cross-check against the memory on the TCC responsibility chain.

- [x] **7.4 — Auto-update signature check accepts ad-hoc signatures**
  `WatchtowerDesktop/Sources/Services/UpdateService.swift:219`
  Accepts ad-hoc signatures (without a Team ID / designated requirement) and then removes quarantine → no guarantee of authenticity.
  *Fix:* require a specific Team ID + designated requirement before removing quarantine.

---

## Batch 8 — Daemon resilience (1 item)

- [x] **8.1 — A digests failure permanently blocks the daemon from starting for the session**
  `WatchtowerDesktop/Sources/Services/BackgroundTaskManager.swift:207`
  A digests pipeline error leaves tracks/people in "Waiting…" and prevents the daemon from starting until the app is restarted.
  *Fix:* isolate a single phase's failure without blocking daemon startup or subsequent phases; reset/flag stuck statuses.
  *Related (functional report):* the daemon only wires up inbox/briefing/day-plan/custom-track inside `if cfg.Digest.Enabled` — disabling digests silently kills off four independent features (`cmd/sync.go`, see functional).

---

## Medium / Low

Not included in this checklist, but documented with `file:line`, evidence, and recommendations in the reports:

| Area | Medium | Low | File |
|---|---|---|---|
| Go bugs | 23 | 23 | `2026-07-05-audit-go-bugs.md` |
| Swift bugs | 9 | 9 | `2026-07-05-audit-swift-bugs.md` |
| UI bugs | 12 | 6 | `2026-07-05-audit-ui-bugs.md` |
| Functional | 7 | 5 | `2026-07-05-audit-functional.md` |
| Architecture | 6 | 7 | `2026-07-05-audit-architecture.md` |
| Security | 1 | 3 | `2026-07-05-audit-security.md` |

Notable medium-priority topics worth raising while working on the High items: prompt customization is a no-op for 6 pipelines (`cmd/sync.go`); `digest.model` is written by Desktop but not read by Go; the "track read" cascade diverges between Go and Swift (Go leaves decisions unread); `FindTracksByFingerprint` doesn't exclude dismissed tracks (violation of TRACKS-07); changing a target's status from Desktop doesn't recalculate progress.
