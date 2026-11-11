# Inbox redesign phase 5 — raw window (Slack) and Slack today — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the umbrella's raw window primitive for Slack (`slack.window`) and on it the new built-in **Slack today**: every hour at most, what happened today in the owner's channels, one light-tier `llm()` step labelling each line, one living Inbox artifact, plus its Desktop row and reading pane.

**Architecture:** A read-only DB query (`db.ReadSlackWindow`) selects in-scope Slack messages past a per-automation cursor (message `rowid`, i.e. arrival order) under the umbrella caps. The SDK exposes it as the built-in read primitive `slack.window`, keeps the cursor under a reserved key of the automation's state and stages the advanced cursor in the run's commit buffer, so it lands only with a `succeeded` run (AUTO-04). The shipped recipe `slack-today.md` merges each run's labelled lines into `state.today` (reset at local midnight) and rewrites one living artifact (key `slack-today`) from that state; the Desktop reads the same state for the row and pane header counts.

**Tech Stack:** Go 1.26 (`internal/db`, `internal/automations`, `internal/automations/builtin`, `internal/daemon`, `internal/prompts`, `internal/features`, `cmd`), goja recipe JS, SwiftUI + GRDB (WatchtowerCore, DesignKit).

**Spec:** `docs/superpowers/specs/2026-11-11-inbox-redesign-design.md` ("Slack today (phase 5)", Decisions, Inventory), umbrella `docs/superpowers/specs/2026-11-02-inbox-builder-design.md` ("Raw window primitive"), mockup `docs/design/mockups/inbox-redesign/inbox-redesign.html` (Slack today row and pane). Engine contract: `docs/features/built-in-automations.md` ("How C3 plugs in", Waiting for me as the closest model).

## Global Constraints

- Raw window caps (umbrella, verbatim): **500 messages and 200 000 characters per run, oldest first**; a cut moves the cursor to the last message included; a backlog older than **7 days** reads the newest 7 days and says "N older messages skipped" with the count; the skip is never silent.
- Cursor: **per automation, kept in its state, advanced only when the run ends `succeeded`**; a recipe that reads the window must have **`concurrency: 1`** (refused otherwise).
- Untrusted input: the window is structured JSON and reaches the model only through `llm()`'s input (`fenceData`), never concatenated into a prompt.
- Scope: a built-in may widen to **every channel the owner is a member of, minus channels muted for AI** (`channel_settings.is_muted_for_llm`); everything else keeps the umbrella's narrow scope (mentions of the owner, DMs, threads the owner wrote in, watched channels). This phase builds only the wide scope, the one Slack today reads; the narrow scope is built by #920 with its first reader (see "Calls", 4).
- "Addressed to the owner personally" is **one rule shared with Waiting for me's detector**: an `<@RAW>` or `<@RAW|…>` mention of the owner, a reply in a thread the owner wrote in, or the owner's own message carrying another person's attention reaction (the predicates of `FindPendingMentions` / `FindThreadRepliesToUser` / `FindReactionRequests`). It is applied **when the window reads the message**, so at that moment nothing shows in both places; a thread the owner joins, or a reaction placed, after the message was read can leave its earlier line in Slack today while the detector also lists it (v1 limit, Task 11).
- Slack today: **runs after a sync, at most once per hour** (except to finish a window the caps cut, "Calls", 2); window = **today since local midnight**, read incrementally, state merged per day and reset at local midnight; **one light-tier `llm()` step**; labels exactly `decided` | `asks you` | `needs someone` | `fyi`; channels with nothing for the owner dropped; lines addressed to the owner personally left out (they live in Waiting for me); **Mark All Seen** marks the artifact read; the living rule makes it unread again when a new line lands.
- Feature id **`slack-today`** (FEAT-01: off reads nothing), config key `slack_today.enabled`, default on; runs only while a Slack account is connected.
- Prompt id **`inbox.slack_today`**, through the `add-ai-prompt` skill, light tier, works on claude and codex.
- Built-in follows "How C3 plugs in" steps 1–8 of `docs/features/built-in-automations.md`, Swift twins included.
- No new migration (state, artifacts and runs use existing tables).
- Desktop: design kit only (tokens, `.kitRow`, no dividers, `Tone` colours), DesignShotCatalog `inbox-r-*` light + dark on `acme`/`example.com` fixtures; UI strings English.
- Public repo hygiene: fixtures use `acme`, `example.com`, `U0OWNER`, "Colleague A"; no live ids or numbers.
- Task-scope checks only (`go test ./internal/<pkg> -run …`, `make test-swift FILTER=…`, `make lint-diff`); the full gate runs once per phase by the controller.
- Board #920 keeps the raw window for the other sources, the owner-recipe capability, and the moves of Morning brief / Track my threads / Idea finder; this phase builds Slack only.

## Review Focus

1. **A channel synced late** (its messages carry a timestamp older than the cursor's newest message) — the owner expects those messages to still reach Slack today. The cursor is the message `rowid` (arrival order), not the Slack timestamp: Task 1 `TestSlackWindow_LateSyncedChannelIsNotMissed`.
2. **The run fails after the window was read** (model error, state too large) — the next run must read the same messages again, never skip them. Task 2 `TestAuto04_RawWindowCursorOnlyOnSuccess`, Task 6 `TestSlackToday_FailedLLMKeepsCursorAndArtifact`.
3. **Non-Latin text near the caps** — 200 000 characters of Cyrillic is ~400 KB, more than `llm()` accepts (200 KB). The window also stops at a byte budget so the run never fails on size. Task 1 `TestSlackWindow_ByteBudgetCutsBeforeLLMLimit`, Task 6 `TestSlackToday_FullWindowFitsLLMInput`.
4. **Just after midnight** — yesterday's lines must not show under "Today", and messages from 23:50 that sync at 00:10 must not land in today. Task 6 `TestSlackToday_DayChangeResetsState`, Task 1 `TestSlackWindow_FloorTodayExcludesEarlierMessages`, Task 7 `TestSlackTodayGate_DayChangeIsDueWithoutMaterial`, Task 9 `testStaleDayShowsYesterdayNote`.
5. **A model reply naming message ids it was not given** (prompt injection or a hallucination) — such a line is dropped, never drawn with a borrowed link. Task 6 `TestSlackToday_UnknownIDsDropped`.
6. **A busy day that the caps cut** — the owner expects the list to catch up within minutes, not an hour later, and a tail still unread at midnight to be named, not lost silently. Task 7 `TestSlackTodayGate_TruncatedWindowIsDueAtOnce`, Task 1 `TestSlackWindow_BelowFloorPastCursorCounted`, Task 6 `TestSlackToday_MissedTailNamedAfterMidnight`.
7. **A mention written `<@U…|name>`, a reply in the owner's own thread, or the owner's message someone marked :eyes:** — it is in Waiting for me, so it must not also be a Slack today line. Task 1 `TestSlackWindow_ToOwnerMatchesDetectorFixture`.

---

## File map

| File | Responsibility |
|---|---|
| `internal/db/slack_window.go` (new) | `ReadSlackWindow`, `SlackWindowHasMaterial`, `LastAutomationRunCreatedAt`; scopes, caps, cursor |
| `internal/automations/manifest.go` | `PrimitiveSlackWindow`, `WindowPrimitiveNames`, `BuiltinPrimitiveNames` |
| `internal/automations/sdk_builtin.go`, `sdk_window.go` (new) | `callWindow`: argument, reserved state key, staged cursor |
| `internal/automations/sdk_state.go` | reserved-key refusal |
| `internal/automations/recipe.go` | `serialRunReasons` raw-window reason |
| `internal/automations/builtin/slack_window.go` (new) | `SlackWindowPrimitives`, row → JSON |
| `internal/automations/builtin/recipes/slack-today.md` (new), `registry.go`, `slacktoday.go` (new) | the built-in |
| `internal/prompts/store.go`, `defaults.go`, `resolve.go` | `inbox.slack_today` |
| `internal/features/registry.go`, `internal/config/config.go`, `defaults.go` | `slack-today`, `slack_today.enabled` |
| `internal/daemon/builtin_slots.go`, `daemon.go`, `morning_brief.go`; `cmd/builtins.go`, `cmd/automations_backends.go`, `internal/automations/authoring/draft.go` | slot, gate, wiring |
| WatchtowerCore `SlackTodayQueries.swift`, `SlackTodaySummary.swift`, `SlackTodayRow.swift`; Views `Inbox/SlackTodayPane.swift` | Desktop |
| Docs: inventory `automations.md`, `features.md`; umbrella spec; `docs/features/built-in-automations.md`, `docs/features/inbox-redesign.md`; guide `docs/guide/features/automations-built-in.md`, `inbox.md` | contracts and docs |

---

### Task 1: The Slack window query (`internal/db`)

**Depends on:** none

**Files:**
- Create: `internal/db/slack_window.go`, `internal/db/owner_addressed.go` (the shared "addressed to the owner" SQL predicates), `internal/inbox/testdata/addressed_to_owner.json` (shared fixture)
- Modify: `internal/db/inbox.go` (`FindPendingMentions`, `FindThreadRepliesToUser` and `FindReactionRequests` build their WHERE from the shared predicates; behaviour unchanged)
- Test: `internal/db/slack_window_test.go`, `internal/db/owner_addressed_test.go`

**Interfaces:**
- Produces:
  - `type WindowScope string` with `WindowScopeMemberChannels = "member_channels"` (the only scope of this phase; #920 adds `WindowScopeNarrow` with its first reader).
  - `type SlackWindowQuery struct { Scope WindowScope; AfterRowID int64 /* 0 = no cursor */; Floor time.Time /* zero = none */; Now time.Time }`
  - `type SlackWindowMessage struct { RowID int64; ChannelID, ChannelName, ChannelType, TS, ThreadTS, UserID, Author, Text, Permalink string; At time.Time; ByOwner, ToOwner, Bot bool }`
  - `type SlackWindow struct { Messages []SlackWindowMessage; NextRowID int64; Truncated bool; SkippedOlder int; BelowFloor int }`
  - `func ownerMentionSQL(textCol string) string`, `func ownerThreadReplySQL(alias string) string` and `func ownerReactionRequestSQL(alias string) string` in `owner_addressed.go`, with their bind order documented, plus `var AttentionReactionEmoji = []string{"question", "grey_question", "eyes", "bangbang", "exclamation", "heavy_exclamation_mark", "warning", "red_circle", "rotating_light", "sos"}` (moved verbatim from `FindReactionRequests`); `FindPendingMentions`, `FindThreadRepliesToUser`, `FindReactionRequests` and the window's `ToOwner` all use them.
  - `func (db *DB) ReadSlackWindow(ctx context.Context, q SlackWindowQuery) (SlackWindow, error)` — one read-only transaction (`BeginTx(ctx, &sql.TxOptions{ReadOnly: true})`).
  - `func (db *DB) SlackWindowHasMaterial(ctx context.Context, q SlackWindowQuery) (bool, error)` — any in-scope message past the cursor at or after the floor; no row bodies read.
  - `func (db *DB) LastAutomationRunCreatedAt(ctx context.Context, automationID int64, trigger string, statuses ...string) (time.Time, bool, error)` — no statuses = any status.
  - Constants: `SlackWindowMaxMessages = 500`, `SlackWindowMaxTextChars = 200_000`, `SlackWindowMaxBytes = 180 << 10` (sum of each row's string fields in bytes; below `automations.MaxLLMInputBytes`, 200 KiB, with room for the prompt and schema), `SlackWindowMaxAge = 7 * 24 * time.Hour`, `SlackWindowTextRunes = 4000` (per message; longer text cut with "…").

Rules the tests pin:
- **Order and cursor.** Rows with `rowid > AfterRowID`, ascending `rowid` (arrival order). Without a cap cut, `NextRowID` = the largest `messages.rowid` in the transaction's snapshot (out-of-scope rows are passed too); with a cut, `NextRowID` = the rowid of the last included message and `Truncated = true`. `AfterRowID = 0` (no cursor) reads only messages with `At ≥ Now − 7d` and counts nothing as skipped.
- **Floor and the 7-day rule.** Effective lower bound = `max(Floor, Now − 7d)`. With a cursor, in-scope rows past it with `At < Now − 7d` are passed and counted in `SkippedOlder`. With a cursor and a `Floor` newer than `Now − 7d`, in-scope rows past the cursor with `Now − 7d ≤ At < Floor` are passed and counted in `BelowFloor` (a tail the caller never read — e.g. yesterday's last messages when a cut window had not caught up by midnight); the caller names them, so no message is passed silently.
- **Filters:** the channel's account (the `<acct>:` prefix) is enabled and not `removed`/`purged`; `is_deleted = 0`; `text != ''`; author not `users.is_muted_for_llm = 1`; channel not muted (`channel_settings.is_muted_for_llm = 1`); subtypes `channel_join`, `channel_leave`, `channel_topic`, `channel_purpose`, `channel_name`, `channel_archive`, `channel_unarchive` left out.
- **`WindowScopeMemberChannels`:** `channels.type IN ('public','private') AND is_member = 1 AND is_archived = 0`. DMs and group DMs are not in it *(plan's call, flagged for the owner in "Calls", 3: everything in a DM is addressed to the owner and lives in Waiting for me)*.
- **Flags:** `ByOwner` = author is the account's `current_user_id`; `ToOwner` = (not by the owner and (the text holds `<@RAW>` or `<@RAW|` where RAW is the raw part of that account's `current_user_id`, **or** the message is a reply — `thread_ts != ''` and `thread_ts != ts` — in a thread where the owner has a message)) **or** (by the owner and another person placed one of `AttentionReactionEmoji` on it) — exactly the detector's mention, thread-reply and reaction-request predicates, evaluated at read time; `Bot` = `users.is_bot = 1` or `is_bot_override = 1`. `Author` = `display_name`, else `real_name`, else `name`, else "Someone".

- [ ] **Step 1: Write the failing tests** (seed with the package's existing test DB helpers; ids `1:C0ACME`, `1:U0OWNER`, names `acme-release`, `acme-infra`)

```go
func TestSlackWindow_MemberChannelsScope(t *testing.T)            // public+private member channels in; DM, non-member, archived, muted channel, muted author, deleted, empty, channel_join out
func TestSlackWindow_ToOwnerMatchesDetectorFixture(t *testing.T)  // addressed_to_owner.json (<@U0OWNER>, <@U0OWNER|owner>, reply in the owner's thread, the owner's own reply, the owner's message with another's :eyes:, the owner's message with only the owner's own :eyes:, the owner's message with :thumbsup:, a plain line, another user's mention): the window's ToOwner ids == the ids FindPendingMentions ∪ FindThreadRepliesToUser ∪ FindReactionRequests return over the same fixture, == the fixture's expected list
func TestOwnerAddressed_DetectorQueriesUnchanged(t *testing.T)    // the three detector functions return what they returned before the predicates moved (the package's existing mention/thread/reaction tests still pass unchanged)
func TestSlackWindow_BelowFloorPastCursorCounted(t *testing.T)    // cursor before yesterday 23:40; Floor = today 00:00 → yesterday's 3 unread rows not returned, BelowFloor == 3; no cursor → BelowFloor == 0
func TestSlackWindow_CursorIsArrivalOrder(t *testing.T)           // rows returned rowid ascending; NextRowID = max rowid incl. an out-of-scope newer row
func TestSlackWindow_LateSyncedChannelIsNotMissed(t *testing.T)   // run 1 reads A@10:00; B@09:30 inserted after → run 2 (AfterRowID = run 1's NextRowID) returns B@09:30
func TestSlackWindow_CapAt500MovesCursorToLastIncluded(t *testing.T) // 650 rows → 500, Truncated, NextRowID == Messages[499].RowID; next read returns the other 150
func TestSlackWindow_CharCapCuts(t *testing.T)                    // texts summing past 200 000 runes stop before the row that would cross it
func TestSlackWindow_ByteBudgetCutsBeforeLLMLimit(t *testing.T)   // 500 Cyrillic rows of 2 000 runes: total string bytes ≤ SlackWindowMaxBytes, Truncated
func TestSlackWindow_SevenDaySkipCounted(t *testing.T)            // cursor set, 3 rows 9 days old + 2 fresh → 2 returned, SkippedOlder == 3, NextRowID past all
func TestSlackWindow_NoCursorStartsSevenDaysBackSilently(t *testing.T) // AfterRowID 0: 9-day-old rows not returned, SkippedOlder == 0
func TestSlackWindow_FloorTodayExcludesEarlierMessages(t *testing.T)  // Floor = local midnight: 23:50 yesterday row inserted after the cursor is not returned (it is counted in BelowFloor, never in SkippedOlder)
func TestSlackWindow_TextCutAt4000Runes(t *testing.T)
func TestSlackWindow_FlagsAndAuthor(t *testing.T)                 // ByOwner, Bot, Author fallbacks
func TestSlackWindow_RemovedAccountReadsNothing(t *testing.T)
func TestSlackWindow_HasMaterialMatchesRead(t *testing.T)         // true iff ReadSlackWindow returns ≥ 1 message, for the cases above
func TestLastAutomationRunCreatedAt(t *testing.T)                 // newest run of the trigger; other triggers ignored; status filter (succeeded only / failed only); none → ok=false
```

- [ ] **Step 2: Run them, expect FAIL** — `cd <repo> && go test ./internal/db -run 'TestSlackWindow|TestLastAutomationRunCreatedAt|TestOwnerAddressed'` → undefined `ReadSlackWindow`.
- [ ] **Step 3: Implement** the signatures above. First move the detector's two predicates into `owner_addressed.go` and rewire `FindPendingMentions` / `FindThreadRepliesToUser` (run `go test ./internal/db ./internal/inbox` — green before going on); then the window query, rows streamed and cut in Go (caps checked before appending a row). Also run `go test ./internal/inbox` at the end (the detector's users).
- [ ] **Step 4: Run the tests, expect PASS.** Also `make lint-diff`.
- [ ] **Step 5: Commit** — `git commit -m "feat(db): Slack raw window query with arrival-order cursor (#1076)"`

---

### Task 2: The window primitive in the SDK (cursor, argument, concurrency)

**Depends on:** none (tests use a fake `PrimitiveFunc`)

**Files:**
- Modify: `internal/automations/manifest.go`, `internal/automations/sdk_builtin.go`, `internal/automations/sdk_state.go`, `internal/automations/recipe.go`
- Create: `internal/automations/sdk_window.go`
- Test: `internal/automations/sdk_window_test.go`, `internal/automations/recipe_test.go`

**Interfaces:**
- Produces:
  - `const PrimitiveSlackWindow = "slack.window"`; appended to `BuiltinPrimitiveNames` (so `builtin:slack.window` is a built-in-only capability, AUTO-01); `var WindowPrimitiveNames = []string{PrimitiveSlackWindow}` (not in `ReadPrimitiveNames`).
  - `PrimitiveCall` gains `Cursor int64` and `Floor string` (`""` | `"today"`); `PrimitiveResult` gains `NextCursor int64` and `Behind bool` (the window was cut by a cap; window primitives only; ignored for every other primitive).
  - `const WindowStateKeyPrefix = "__window:"`; the slack cursor's key is `"__window:slack"`, value `{"v":1,"after_rowid":N,"behind":bool}`; `func WindowCursorOf(state json.RawMessage, key string) (afterRowID int64, behind bool, err error)` for the daemon gate (a missing key = `0, false, nil`).
  - `func serialRunReasons(r *Recipe, m *Manifest) []string` — adds `"the raw window"` when `m` holds `CapabilityForPrimitive(PrimitiveSlackWindow)`; `applyArtifacts` passes `m`.

Rules the tests pin:
- `slack.window()` / `slack.window({})` / `slack.window({floor: "today"})`; any other argument → `ValidationError` `slack.window({floor}): floor must be "today"` or `slack.window() takes only {floor}`.
- Journalled as one `tool` step named `slack.window`, permission `builtin:slack.window`, outside the meter (as `callRead`); runs in a dry run too (reads), but a dry run never commits.
- Before the call, the SDK reads the cursor from `env.Buffer` (committed state + this run's sets) and passes it as `Cursor`; on `done` it `env.Buffer.Set("__window:slack", {"v":1,"after_rowid":NextCursor,"behind":Behind})` — committed only with a `succeeded` run (AUTO-04). A second call in the same run reads past the first call's cursor.
- `state.set` with a key starting `__window:` → `ValidationError` `state.set("__window:slack"): keys starting with "__window:" belong to the raw window`.
- A recipe holding `builtin:slack.window` with `concurrency` other than 1 → `ParseError` `concurrency: an automation with the raw window runs one at a time; set concurrency: 1`.
- An error or a status other than done/skipped → `PrimitiveFailed` (cursor not staged).

- [ ] **Step 1: Write the failing tests**

```go
func TestAuto01_RawWindowBuiltinOnly(t *testing.T)               // Personal recipe naming builtin:slack.window → ParseError (builtinOnly); built-in scope parses
func TestAuto04_RawWindowCursorOnlyOnSuccess(t *testing.T)       // fake returns NextCursor 42, Behind true: succeeded run → state "__window:slack" == {v:1, after_rowid:42, behind:true}; run failed after the call → state unchanged, next run's Cursor == previous value
func TestWindowCursorOf(t *testing.T)                            // missing key → 0,false,nil; v ≠ 1 or bad JSON → error
func TestAuto05_RawWindowNeedsConcurrencyOne(t *testing.T)       // concurrency: 2 + builtin:slack.window → exact ParseError above; concurrency 1 ok
func TestSlackWindowCall_PassesCursorAndFloor(t *testing.T)      // committed state after_rowid 7 → PrimitiveCall.Cursor 7, Floor "today"
func TestSlackWindowCall_SecondCallReadsPastFirst(t *testing.T)
func TestSlackWindowCall_BadArgument(t *testing.T)               // {floor:"week"}, {x:1}, "a" → exact ValidationError texts
func TestSlackWindowCall_ToolStepOutsideMeter(t *testing.T)      // step kind tool, permission builtin:slack.window, meter unchanged
func TestSlackWindowCall_DryRunReadsButNeverCommits(t *testing.T)
func TestStateSet_ReservedWindowKeyRefused(t *testing.T)
```

- [ ] **Step 2: Run, expect FAIL** — `go test ./internal/automations -run 'TestAuto0[145]_RawWindow|TestSlackWindowCall|TestStateSet_Reserved|TestWindowCursorOf'`.
- [ ] **Step 3: Implement** `callWindow(env *Env, name string, raw any, argErr error) (any, error)` in `sdk_window.go`, dispatched from `builtinSDK.call` before the `ReadPrimitiveNames` branch; the reserved-key check in `stateSet`; `serialRunReasons(r, m)`.
- [ ] **Step 4: Run, expect PASS**; also `go test ./internal/automations` (the whole package: the signature change of `serialRunReasons`) and `make lint-diff`.
- [ ] **Step 5: Commit** — `feat(automations): slack.window primitive with its cursor in state (#1076)`

---

### Task 3: `SlackWindowPrimitives` over the database

**Depends on:** Task 1, Task 2

**Files:**
- Create: `internal/automations/builtin/slack_window.go`
- Modify: `internal/automations/builtin/registry.go` (field only), `internal/automations/builtin/waiting.go` (`ReadPrimitives` adds it)
- Test: `internal/automations/builtin/slack_window_test.go`

**Interfaces:**
- Consumes: `db.ReadSlackWindow`, `db.WindowScope*` (Task 1); `PrimitiveCall.Cursor/Floor`, `PrimitiveResult.NextCursor` (Task 2).
- Produces:
  - `Entry.WindowScope db.WindowScope`; `TestRegistry_WindowReadersDeclareScope` pins that every entry listing `slack.window` sets it (empty is refused until #920 adds the narrow scope).
  - `func SlackWindowPrimitives(d *db.DB, now func() time.Time) map[string]automations.PrimitiveFunc` — scope = `Lookup(call.BuiltinID).WindowScope`; an unknown built-in id or an empty scope → error (`PrimitiveFailed`), never a guessed scope. `Floor "today"` → local midnight of `now()` (`time.Local`).
  - Result `Fields`: `day` ("YYYY-MM-DD", local, of `now()`), `owner` (`{name}` from `ResolveOwner().DisplayName`, "" when unknown), `messages` (array of `{id: "<channel_id>/<ts>", channel_id, channel: "#<name>", author, at (RFC 3339 UTC), time ("HH:MM" local), text, thread_id ("<channel_id>/<thread_ts>" for a reply, else ""), permalink (http(s) only, else ""), by_owner, to_owner, bot}`), `count`, `truncated`, `skipped_older`, `below_floor`. `NextCursor` = `NextRowID`, `Behind` = `Truncated`.
  - `policy.SourceAllowed("slack")` false → `{status: "skipped", reason: "source_off", messages: []}`, `NextCursor` = the call's `Cursor` (nothing read).

- [ ] **Step 1: Failing tests** — `TestSlackWindowPrimitive_FieldsShape` (every key above, `id`/`thread_id` format), `TestSlackWindowPrimitive_ScopeFromEntry` (the entry's `WindowScopeMemberChannels` is used; an unknown built-in id fails the call), `TestSlackWindowPrimitive_FloorTodayIsLocalMidnight` (TZ set via `time.Local` swap in the test), `TestSlackWindowPrimitive_PolicyOffSkipsAndKeepsCursor` (`policy.SetReaderForTesting`), `TestReadPrimitives_IncludesSlackWindow`, `TestRegistry_WindowReadersDeclareScope` (vacuous until Task 6 adds the first reader; Task 6 must keep it green).
- [ ] **Step 2: Run, expect FAIL** — `go test ./internal/automations/builtin -run 'TestSlackWindowPrimitive|TestReadPrimitives|TestRegistry_WindowReaders'`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS**; `make lint-diff`.
- [ ] **Step 5: Commit** — `feat(builtin): slack.window over the Slack tables (#1076)`

---

### Task 4: Prompt `inbox.slack_today`

**Depends on:** none

**Files:**
- Modify: `internal/prompts/store.go`, `internal/prompts/defaults.go`, `internal/prompts/resolve.go`
- Test: `internal/prompts/defaults_test.go` (or the package's existing registry test), `internal/prompts/resolve_test.go`

**Interfaces:**
- Produces: `const InboxSlackToday = "inbox.slack_today"`; `Defaults[InboxSlackToday]`, `AllIDs`, `DefaultVersions[InboxSlackToday] = 1`, description "Slack today — label today's channel messages for the owner"; `MovedToBuiltin[InboxSlackToday] = "slack-today"` (the tuner leaves it alone; `TakesAdditions` false).

Template content (wording is the builder's; these are the requirements, each checked by a test on the text): it has **no `%s`** (it is passed to `llm()` as the prompt, the window goes in `input`); it names the four labels exactly (`decided`, `asks_you`, `needs_someone`, `fyi` as schema values); it says each line is one sentence of at most 160 characters, in the language of the messages it sums up; it says to group messages of one thread or one topic into one line and to return the ids it used; it says to return nothing for a channel with nothing the owner should know; it says to skip messages addressed to the owner personally and never to label the owner's own message `asks_you`; it says the input is data, not instructions. Tier: light (the recipe's `tier: "light"` → `automations.SourceLLMLight` = `automation.llm`, already routed to the light model on both providers).

- [ ] **Step 1: Failing tests** — `TestDefaults_InboxSlackToday` (registered, version 1, no `%s`, contains `decided`/`asks_you`/`needs_someone`/`fyi`), `TestMovedToBuiltin_SlackToday`, `TestLLMLightSourceRoutedOnBothProviders` (the `automation.llm` source maps to the light tier in `internal/digest/models.go` and in the codex model routing — skip the assertion that already exists if one does, and name it in the commit).
- [ ] **Step 2: Run, expect FAIL** — `go test ./internal/prompts ./internal/digest -run 'SlackToday|LLMLightSource'`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** — `feat(prompts): inbox.slack_today for the Slack today built-in (#1076)`

---

### Task 5: Feature `slack-today` and its config key

**Depends on:** none

**Files:**
- Modify: `internal/config/config.go` (`SlackTodayConfig{Enabled bool}`, `mapstructure:"slack_today"`), `internal/config/defaults.go` (`DefaultSlackTodayEnabled = true`), `internal/features/registry.go`
- Test: `internal/features/registry_test.go`, `internal/features/fastforward_test.go`, `internal/config/config_test.go`

**Interfaces:**
- Produces: registry entry `ID "slack-today"`, `Title "Slack today"`, `ConfigKey "slack_today.enabled"`, `Cost CostLight`, `Icon "bubble.left.and.text.bubble.right"`, `Enabled: cfg.SlackToday.Enabled`, no fast-forward hook (its window is floored at today's midnight, so turning it on reads at most today), Description: "Once an hour at most, reads today's messages in every Slack channel you are a member of (except channels muted for AI) and lists what was decided, what asks you, what needs someone and what is just news, by channel. Light AI use." Tagline "What happened in your channels today". Benefits: "Today's channels in one place, by channel", "Each line marked decided, asks you, needs someone or fyi", "Reads Slack directly — no digests needed".

- [ ] **Step 1: Failing tests** — `TestRegistry_SlackToday` (fields above, cost light), `TestConfig_SlackTodayDefaultOn`, and extend `TestFastForward_NoHookIsNil` with `slack-today` (FEAT-03 additive case; no assertion weakened).
- [ ] **Step 2: Run, expect FAIL** — `go test ./internal/features ./internal/config -run 'SlackToday|NoHookIsNil'`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS**; `go test ./internal/features ./internal/config`.
- [ ] **Step 5: Commit** — `feat(features): slack-today feature, on by default (#1076)`

---

### Task 6: The `slack-today` built-in (recipe, entry, golden)

**Depends on:** Task 2, Task 3, Task 4, Task 5

**Files:**
- Create: `internal/automations/builtin/recipes/slack-today.md`, `internal/automations/builtin/slacktoday.go` (`SlotSlackToday`, `SlackTodayID`), `internal/automations/builtin/testdata/show_slack_today.json`, `internal/automations/builtin/testdata/slack_today_window.json` (input fixture), `internal/automations/builtin/testdata/slack_today_state.json` (golden, Go writes, Swift reads)
- Modify: `internal/automations/builtin/registry.go`, `internal/automations/recipe.go` (`SyncSlots` + `"slack_today"`)
- Test: `internal/automations/builtin/slacktoday_test.go`, `internal/automations/builtin/registry_test.go`

**Interfaces:**
- Consumes: `slack.window` (Tasks 2–3), `prompts.InboxSlackToday` (Task 4), feature `slack-today` (Task 5).
- Produces:
  - `const SlotSlackToday Slot = "slack_today"`, `const SlackTodayID = "slack-today"`, living key `"slack-today"`, artifact title "Slack today".
  - Registry entry (after `waiting-for-me`): `Name "Slack today"`, `Slot SlotSlackToday`, `FeatureIDs ["slack-today"]`, `Primitives [automations.PrimitiveSlackWindow]`, `Prompts [{Name: "label", PromptID: prompts.InboxSlackToday}]`, no parameters, no pipelines, `WindowScope db.WindowScopeMemberChannels`, `DefaultFolder RootFolder`, `RunNow true`, `Reads ["Today's messages in the Slack channels you are a member of, except channels muted for AI"]`, `Does ["Reads the new messages in your channels since its last run, today only", "Marks each line decided, asks you, needs someone or fyi, and leaves out what is addressed to you personally", "Keeps one Slack today list in your Inbox, updated at most once an hour"]`, `Sends ["One Slack today list in your Inbox"]`, `When` → "After a sync, at most once an hour".
  - State key `today`, shape v1 (pinned by `slack_today_state.json`): `{"v":1,"day":"YYYY-MM-DD","messages":N,"missed_yesterday":N,"channels":{"<channel_id>":{"name":"acme-release","n":N,"more":N,"lines":[{"label":"decided|asks_you|needs_someone|fyi","text":"…","at":"RFC 3339","link":"…"}]}}}`; `messages` and each `n` count every window message of the day (to-owner ones included); `more` counts the channel's lines the caps took out of the state; `missed_yesterday` is the window's `below_floor` on the day's first run (0 otherwise); a channel with `lines: []` and `more: 0` is a channel with nothing for the owner.

Recipe frontmatter: `trigger: {sync: slack_today}`, `artifacts: living`, `concurrency: 1`, `permissions: [builtin:slack.window, llm:light]`, `outputs: [inbox]`, `budget: {tokens: 150000, minutes: 5}`.

Script behaviour (each line pinned by a test below):
1. `slack.window({floor: "today"})`; start from `state.get("today")` when its `v` is 1 and its `day` equals the window's `day`, else a fresh day with `missed_yesterday` = the window's `below_floor` (on later runs of the day `below_floor` is added to it too).
2. Count every message into `messages` and its channel's `n` (name from `channel` without `#`).
3. Model input = the messages with `to_owner` false, slimmed to `{id, channel, author, time, text, thread_id, by_owner, bot}`, plus `owner`; no `llm()` call when that list is empty.
4. One `llm(builtin.defaultPrompt("label"), {input, schema, tier: "light"})`; schema `{lines: [{ids: [string, 1..20], label: enum[decided, asks_you, needs_someone, fyi], text: string}]}`.
5. A line is kept only when every id is one of the input ids; its channel = the first id's channel, `link` = that message's permalink, `at` = the newest of its messages; text cut to 160 characters.
6. Merge: per channel at most **6** lines, globally at most **90**; when over, take out by label rank (`fyi` < `decided` < `needs_someone` < `asks_you`) then oldest first, and add each one taken out to its channel's `more`. These caps exist because the state is capped at 64 KB (`MaxStateBytes`) and the card at 40 blocks; they never hide silently (step 8). *(Plan's call; numbers sized by `TestSlackToday_HeavyDayStateUnderLimit`.)*
7. `state.set("today", s)`.
8. Blocks (only line data, so the content hash changes only when a line changes — quiet messages never mark it unread): channels with lines ordered by (has `asks_you`, has `needs_someone`, line count desc, name), at most **18** shown; each shown channel = a `list` block (title `#<name>`, rows `{title: text, badge: {text: "asks you"|"needs someone"|"decided"|"fyi", tone: warning|info|success|neutral}, link}` sorted by label rank desc then newest, plus, when `more > 0`, a last row `"N more lines — open the channel to read them"` with the channel's newest link) followed by a `link` block "Open in Slack" to the channel's newest line link (omitted when it has none); then, if more channels have lines, one `text` block "N more channels with news: #a, #b, …" (at most 10 names); when `missed_yesterday > 0`, a `text` block "N messages from late yesterday were not read." (written on the day's first run, so the hash changes once); with no lines at all, one `list` block with no rows and `empty: "Nothing for you in your channels yet today"`. Total ≤ 39 blocks. The per-channel message counts and the "N channels with nothing for you" line are drawn by the Desktop pane from the state (Task 9), not by the card — see "Calls", 5.
9. `output.inbox({key: "slack-today", title: "Slack today", blocks})`.

- [ ] **Step 1: Failing tests** (run the shipped recipe through the executor with `automationstest.FakeGenerator` and a fake `slack.window` reading `slack_today_window.json`):

```go
func TestSlackToday_ShippedRecipeShape(t *testing.T)            // trigger sync slack_today, living, concurrency 1, permissions exactly [builtin:slack.window, llm:light], one llm( call site, tier light
func TestSlackToday_GroupsLinesByChannel(t *testing.T)          // fixture reply → blocks: list "#acme-release" rows with badges/tones as pinned, link block "Open in Slack"
func TestSlackToday_StateGolden(t *testing.T)                   // state "today" == testdata/slack_today_state.json (-update rewrites)
func TestSlackToday_ToOwnerNeverSentToModel(t *testing.T)       // FakeGenerator input holds no to_owner id; counted in messages
func TestSlackToday_NoModelCallWithoutInput(t *testing.T)        // only to_owner messages → 0 generator calls, artifact still written
func TestSlackToday_UnknownIDsDropped(t *testing.T)             // reply line with an id not in input → not in state or blocks
func TestSlackToday_SecondRunMerges(t *testing.T)               // run 2 adds lines to run 1's state; earlier lines kept; generator saw only run 2's messages
func TestSlackToday_DayChangeResetsState(t *testing.T)          // committed state day = yesterday, window day = today → yesterday's lines gone
func TestSlackToday_QuietMessagesKeepContentHash(t *testing.T)  // run 2 with messages but no lines → same content_hash, read_at kept
func TestSlackToday_LineCaps(t *testing.T)                      // 10 lines in one channel → 6 by label rank, more == 4, last row "4 more lines — open the channel to read them"; 200 lines → 90 kept, sum of more == 110; 25 channels → 18 shown + "7 more channels with news: …"
func TestSlackToday_MissedTailNamedAfterMidnight(t *testing.T)  // window below_floor 12 on the day's first run → state missed_yesterday 12, text block "12 messages from late yesterday were not read."; the next run keeps the same hash
func TestSlackToday_EmptyDay(t *testing.T)                      // no messages → empty list with the pinned empty text
func TestSlackToday_HeavyDayStateUnderLimit(t *testing.T)       // 400 channels, 90 lines of 160 Cyrillic chars → len(state) ≤ automations.MaxStateBytes
func TestSlackToday_FullWindowFitsLLMInput(t *testing.T)        // a 500-message, byte-capped window → llm step not refused for size
func TestSlackToday_FailedLLMKeepsCursorAndArtifact(t *testing.T) // generator error → run failed, "__window:slack" and "today" unchanged, earlier artifact unchanged
func TestSlackToday_SkippedPrimitiveWritesNothingNew(t *testing.T) // window skipped (policy) → no llm call; artifact rewritten from the existing state only
func TestRegistry_SlackTodayEntry(t *testing.T)                 // fields above; card order after waiting-for-me
func TestCardGolden_SlackToday(t *testing.T)                    // show --json builtin block == testdata/show_slack_today.json
```

- [ ] **Step 2: Run, expect FAIL** — `go test ./internal/automations/builtin -run 'SlackToday'`.
- [ ] **Step 3: Implement** the recipe, the entry and the constants; regenerate goldens with `go test ./internal/automations/builtin -run 'Golden|StateGolden' -update`.
- [ ] **Step 4: Run, expect PASS**; `go test ./internal/automations ./internal/automations/builtin` (SyncSlots and registry are shared); `make lint-diff`.
- [ ] **Step 5: Commit** — `feat(builtin): Slack today built-in (#1076)`

---

### Task 7: Daemon slot, gate and wiring

**Depends on:** Task 6

**Files:**
- Modify: `internal/daemon/builtin_slots.go` (`slackTodayID`, `SlackTodayPrimitives`, `SlackTodayGate`, `phaseSlackToday`), `internal/daemon/daemon.go` (`runSync`: `d.phaseSlackToday(ctx)` right after `d.phaseWaitingForMe(ctx)`), `internal/daemon/morning_brief.go` (`BuiltinPrimitives` adds `SlackTodayPrimitives()`), `cmd/builtins.go` (gate map `"slack-today": d.SlackTodayGate()`, `cliBuiltinBackends` adds `builtin.SlackWindowPrimitives`)
- Test: `internal/daemon/builtin_slots_test.go`, `internal/daemon/daemon_gates_test.go`, the existing static run-order test, `cmd/builtins_test.go`

**Interfaces:**
- Consumes: `db.SlackWindowHasMaterial`, `db.LastAutomationRunCreatedAt` (Task 1), `builtin.SlackWindowPrimitives` (Task 3), `builtin.SlotSlackToday`/`SlackTodayID` (Task 6).
- Produces: `func (d *Daemon) SlackTodayGate() builtin.Gate`, `func (d *Daemon) phaseSlackToday(ctx context.Context)`.

Gate `Due(ctx, e, now)` (each branch a test): not due when no Slack account is enabled and not `removed`/`purged` (`ListSlackAccounts`), or `policy.SourceAllowed("slack")` is false; **due** when the committed `today.day` (from `GetAutomationState`) differs from today's local date (resets the artifact after midnight, even with no new messages); **due** when the committed cursor says `behind` (the last succeeded run's window was cut by a cap: the next cycle continues at once, so a busy day catches up in minutes and rarely carries a tail past midnight); otherwise due only when **both** the last `succeeded` sync run was created ≥ **60 minutes** ago (none = due) **and** the last failed sync run, if newer than it, was created ≥ **15 minutes** ago (a failure is retried after 15 minutes, not every cycle and not an hour later), **and** `SlackWindowHasMaterial` (member-channel scope, the state's cursor via `automations.WindowCursorOf`, floor = local midnight). Both run times come from `db.LastAutomationRunCreatedAt` with a status filter (Task 1). A failed read logs (`slack-today: …`, ids only) and counts as due. A queued Run Now runs without the gate (Runner rule). Off → `phaseSlackToday` cancels queued runs and returns before any read (FEAT-01); no legacy phase, so until active its queued Run Now is cancelled (as Waiting for me).

- [ ] **Step 1: Failing tests** — `TestSlackTodayGate_NoSlackAccountNotDue`, `TestSlackTodayGate_PolicyOffNotDue`, `TestSlackTodayGate_DayChangeIsDueWithoutMaterial`, `TestSlackTodayGate_WithinTheHourNotDue` (last succeeded run 59 min ago + material → false; 60 min → true), `TestSlackTodayGate_TruncatedWindowIsDueAtOnce` (cursor `behind: true`, last run 2 min ago → due), `TestSlackTodayGate_FailedRunRetriedAfter15Minutes` (succeeded 30 min ago, failed 14 min ago → not due; failed 15 min ago → due), `TestSlackTodayGate_NoMaterialNotDue`, `TestSlackTodayGate_ReadErrorIsDue`, `TestPhaseSlackToday_RunsAfterWaitingForMe` (static order test gains the line), new case `slack_today` in `TestFeatureGates_DisabledPhaseWritesNoPipelineRun` (off → zero `automation_runs` rows, zero generator calls; additive case, no assertion changed), `TestCLIBuiltinBackends_HaveSlackWindow`.
- [ ] **Step 2: Run, expect FAIL** — `go test ./internal/daemon -run 'SlackToday|FeatureGates|RunOrder'` and `go test ./cmd -run 'TestCLIBuiltinBackends_HaveSlackWindow'`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS**; `go test ./internal/daemon` and `go test ./internal/automations/authoring` (draft dry runs carry `ReadPrimitives`); `make lint-diff`.
- [ ] **Step 5: Commit** — `feat(daemon): Slack today slot after Waiting for me, hourly gate (#1076)`

---

### Task 8: Swift twins of the new built-in

**Depends on:** Task 6

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Automations/AutomationTriggerText.swift` (`"slack_today": "After a sync, at most once an hour"`), `AutomationCardPresentation.swift` (`"slack.window": "Read today's messages in your Slack channels"`), `BuiltinUpgradeNotice.swift` (`name(for: "slack-today")` = "Slack today"), `WatchtowerDesktop/Sources/Views/Settings/FeatureManagerSection.swift` (`movedToBuiltins` + `"slack-today"`, doc comment names Slack today), `WatchtowerDesktop/Sources/WatchtowerCore/Services/OnboardingFeaturePlan.swift` (`unmanagedFeatureIDs` + `"slack-today"`: onboarding leaves it at its default, on, whatever goals are picked — the spec says "default on when Slack is connected" and names no goal; it only runs once Slack is connected), the Settings pointer text listing the built-ins ("Briefing, Day Plan, Tracks, Ideas, Reaction commands and Slack today")
- Test: `Tests/Core/BuiltinAutomationDetailDecodingTests.swift` (decode `show_slack_today.json`: id, slot `slack_today`, featureIDs `["slack-today"]`, parameters `[]`, defaultFolder `inbox`, runNow true), `Tests/Core/AutomationTriggerTextTests.swift`, the existing `AutomationCardPresentation` permission-line test, `OnboardingFeaturePlanTests` (registry classification), the `FeatureManagerSection.listed` test

- [ ] **Step 1: Failing tests** — add the assertions above (`testSlackTodayGoldenDecodes`, `testSlackTodaySlotText`, `testSlackWindowPermissionLine`, `testSlackTodayNotListedInFeatures`, `testSlackTodayIsUnmanagedByOnboarding` — the existing every-registry-id-classified check stays green).
- [ ] **Step 2: Run, expect FAIL** — `make test-swift FILTER='BuiltinAutomationDetailDecodingTests|AutomationTriggerTextTests|AutomationCardPresentationTests|OnboardingFeaturePlanTests|FeatureManagerSectionTests'`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS**; `make lint-diff`.
- [ ] **Step 5: Commit** — `feat(desktop): Slack today built-in twins (#1076)`

---

### Task 9: Slack today row and reading pane (Desktop)

**Depends on:** Task 6 (state golden), phase 1 (row, sections, pane header)

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/SlackTodayQueries.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/Inbox/SlackTodaySummary.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/Inbox/SlackTodayRow.swift`, `WatchtowerDesktop/Sources/Views/Inbox/SlackTodayPane.swift`, `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+InboxRedesignSlackToday.swift`
- Modify: the phase 1 row-content mapping for root entries (`.slackToday` for the artifact whose automation `builtinID == "slack-today"`), `InboxReadingPane` (draws `SlackTodayPane` for that entry), `InboxFolderQueries` (reads the summary in its one read), `ActionStripViewModel` (`markOutputSeen`), `DesignShotCatalog.swift`
- Test: `Tests/Core/SlackTodaySummaryTests.swift`, `Tests/Core/SlackTodayRowTests.swift`, `Tests/SlackTodayPaneTests.swift`

**Interfaces:**
- Consumes (phase 1): `InboxRowContent`, `InboxRowKind.slackToday`, `InboxRowPill`, `InboxRootSections.build` (places `.slackToday` in `.today`), `InboxPaneHeader(tile:title:subtitle:actions:)`, `InboxToday.startOfToday(now:calendar:)`.
- Produces:
  - `package struct SlackTodaySummary: Equatable { let day: String; let messages: Int; let channels: Int /* channels with any message */; let newsChannels: Int /* channels with ≥ 1 line or more > 0 */; let topLines: [Line] /* ≤ 2, label rank desc then newest */; let quiet: [QuietChannel] /* channels with nothing for the owner, busiest first */; struct Line: Equatable { let channel: String; let text: String }; struct QuietChannel: Equatable { let name: String; let messages: Int } ; static func decode(stateJSON: String) -> SlackTodaySummary? /* nil: no "today", v ≠ 1, undecodable */ ; func isToday(now: Date, calendar: Calendar) -> Bool }`
  - `package enum SlackTodayQueries { static let builtinID = "slack-today"; static func summary(_ db: Database) throws -> SlackTodaySummary? }` — `automation_state.state_json` of the built-in's row; a database without the row reads nil.
  - `package enum SlackTodayRow { static func content(summary: SlackTodaySummary?, isUnread: Bool, changedAt: Date, now: Date, calendar: Calendar) -> InboxRowContent }`: title "Slack today"; today → preview = the top lines as `#<channel> — <text>`, one per line (≤ 2), meta "Built in · today · N messages", pill = `newsChannels` neutral (none at 0); summary nil or not today → preview "Nothing yet today", meta "Built in", no pill.
  - `package func ActionStripViewModel.markOutputSeen(id: Int64) async` — `AutomationQueries.markOutputOpened` for the drawn `contentHash`, then re-read; never optimistic.
  - `struct SlackTodayPane: View` — `InboxPaneHeader(tile: .slackToday, title: "Slack today", subtitle: <"Today · N messages in K channels · M with news for you" | "Nothing yet today">, actions: [Mark All Seen (enabled while the drawn version is unread), Run Now, ⋯])`, then a note "This is yesterday's list. Today's starts after the next sync." when the summary is not today, then `ArtifactView` of the artifact, then — while today's summary has quiet channels — the folded line **"N channels with nothing for you · M messages"** (the mockup's line; a kit disclosure row, folded by default, opening a list "#name · N messages" busiest first). The pane draws this line from the state, not the card, so quiet messages never mark the card unread (see "Calls", 5). Row context menu gets **Mark All Seen** too. Singular forms: "1 message", "1 channel".

- [ ] **Step 1: Failing tests**

```swift
func testDecodesGoldenState()            // internal/automations/builtin/testdata/slack_today_state.json via #filePath → messages, channels, newsChannels, topLines as pinned
func testUnknownVersionIsNil()           // v: 2, missing "today", bad JSON → nil
func testRowToday()                      // preview two lines "#acme-release — …", meta "Built in · today · 900 messages", pill 4 neutral
func testRowNoNewsHasNoPill()
func testStaleDayShowsYesterdayNote()    // summary.day = yesterday → row "Nothing yet today", pane note text exact
func testHeaderSubtitleSingulars()       // 1 message in 1 channel · 1 with news for you
func testQuietChannelsFold()             // golden: quiet == channels with lines [] and more 0, busiest first; line "42 channels with nothing for you · 820 messages"; no line when none; a channel with only `more` counts as news, not quiet
func testSlackTodayEntryIsInTodaySection() // InboxRootSections.build with the built-in's artifact → .today, kind .slackToday
func testMarkAllSeenWritesDrawnHashOnly() // version changed under the pane → markOutputOpened returns false, stays unread, re-read
```

- [ ] **Step 2: Run, expect FAIL** — `make test-swift FILTER='SlackTodaySummaryTests|SlackTodayRowTests|SlackTodayPaneTests'`.
- [ ] **Step 3: Implement**, kit components only; add catalog entries `inbox-r-slack-today-row`, `inbox-r-slack-today-pane`, `inbox-r-slack-today-stale` (light + dark) on `acme` fixtures matching the mockup.
- [ ] **Step 4: Run, expect PASS**; `make test-swift FILTER='DesignShotsTests'`, look at the shots (`make desktop-shots DESKTOP_SHOTS=<dir>`); `make lint-diff`.
- [ ] **Step 5: Commit** — `feat(inbox): Slack today row and pane (#1076)`

---

### Task 10: Inventory amendments and the umbrella amendment

**Depends on:** Task 2, Task 5, Task 7 (guard test names)

**Files:**
- Modify: `docs/inventory/automations.md`, `docs/inventory/features.md`, `docs/superpowers/specs/2026-11-02-inbox-builder-design.md`

Approved text (spec "Inventory", owner approval asks #634 and #638), added as amendments — no existing sentence or guard weakened:
- **AUTO-01:** "The raw window primitive `slack.window` is admitted only by `builtin:slack.window`, a built-in-only capability; a Personal or workbench recipe naming it is a parse error. Its cursor key `__window:slack` in the automation's state is written only by the SDK; `state.set` of a `__window:` key is refused." Guard: `TestAuto01_RawWindowBuiltinOnly`, `TestStateSet_ReservedWindowKeyRefused`.
- **AUTO-04:** "The raw window's cursor lives in the automation's state and is staged by the SDK after a `done` window read; it is committed only with a `succeeded` run, so a failed, cancelled or interrupted run leaves it and the next run reads the same messages." Guard: `TestAuto04_RawWindowCursorOnlyOnSuccess`.
- **AUTO-05:** "A recipe that reads the raw window runs with `concurrency: 1` (`serialRunReasons`: 'the raw window')." Guard: `TestAuto05_RawWindowNeedsConcurrencyOne`.
- Module list gains `internal/db/slack_window.go`, `internal/automations/sdk_window.go`, `internal/automations/builtin/slack_window.go`, `internal/automations/builtin/recipes/slack-today.md`; a changelog line (date, #1076, asks #634/#638).
- **features.md changelog:** new id `slack-today` (config `slack_today.enabled`, default on, `CostLight`, no fast-forward hook — FEAT-03's no-hook path, its window floored at today's midnight); FEAT-01 holds through the new `slack_today` case of `TestFeatureGates_DisabledPhaseWritesNoPipelineRun` (now 14 cases) and `TestFastForward_NoHookIsNil` gains `slack-today`.
- **Umbrella** "Raw window primitive", new bullets: (1) *Scope for built-ins (amended 2026-11-11, ask #634):* a built-in may widen the scope to every public or private channel the owner is a member of, minus channels muted for AI; DMs stay with the narrow scope's readers; owner recipes keep the narrow scope (in this phase they cannot call the window at all; the narrow scope and the owner-recipe capability are built by #920 with their first reader). "Addressed to the owner" in the window is the attention detector's own rule (mentions in both Slack forms, replies in the owner's threads). (2) *Implementation (2026-11-11):* the cursor is the message's arrival order (`rowid`), so a channel synced late is not missed; the window also stops at a byte budget (`SlackWindowMaxBytes`, 180 KiB) so it always fits `llm()`'s input, and a cut window makes the next cycle run at once; a caller may floor the window at local midnight (`{floor: "today"}`), and unread messages the floor passes are counted (`below_floor`) and named by the caller, never passed silently.

- [ ] **Step 1:** Edit the three files with the text above.
- [ ] **Step 2:** Check every cited test name exists: `grep -rn 'TestAuto01_RawWindowBuiltinOnly\|TestAuto04_RawWindowCursorOnlyOnSuccess\|TestAuto05_RawWindowNeedsConcurrencyOne\|TestStateSet_ReservedWindowKeyRefused' internal` → 4 hits.
- [ ] **Step 3: Commit** — `docs(inventory): raw window and slack-today amendments (#1076)`

---

### Task 11: Feature notes, guide, CLAUDE.md line

**Depends on:** Task 7, Task 9

**Files:**
- Modify: `docs/features/built-in-automations.md` (new section "Slack today (Inbox redesign phase 5, 2026-11-11)": entry, `slack.window` read and cursor, gate, recipe, state v1 and the Swift reader, dual paths — `slack_today_state.json`, `show_slack_today.json`, `AutomationTriggerText`, `AutomationCardPresentation`, `BuiltinUpgradeNotice`, `movedToBuiltins`; v1 limits below), `docs/features/inbox-redesign.md` (phase 5 section: row, pane, Mark All Seen, shots), `docs/guide/features/automations-built-in.md` (Slack today: what it reads, when, the four labels, how to turn it off, channels muted for AI are skipped), `docs/guide/features/inbox.md` (the Slack today row and pane, Mark All Seen), `CLAUDE.md` (the Built-in automations Feature Notes line gains "Slack today (`slack-today`, raw window `slack.window`, 2026-11-11)")
- v1 limits to state: edits to a message after it was read are not re-read; "addressed to you" is decided when a message is read, so a thread you join or an attention reaction placed on your message later can leave the earlier line in Slack today while Waiting for me also lists it (until the day resets); a physically deleted newest message can let one new message reuse its `rowid` and be missed (purge only); a failed run is retried after 15 minutes (nothing is lost: the cursor did not move); the per-channel message counts and the "channels with nothing for you" line are drawn by the Desktop pane from the state, so the phone (sub-project F) will not show them from the card alone; the narrow scope, the owner-recipe window and the other sources are #920.

- [ ] **Step 1:** Write the sections following `docs/guide/WRITING.md`.
- [ ] **Step 2:** `make lint-diff` (markdown lint, if any); `scripts/leak-check.sh` over the branch's commits.
- [ ] **Step 3: Commit** — `docs(inbox): Slack today notes and guide (#1076)`

---

## Dependency graph

1, 2, 4, 5 independent → 3 (1, 2) → 6 (2, 3, 4, 5) → 7 (6), 8 (6), 9 (6 + phase 1) → 10 (2, 5, 7) → 11 (7, 9).

## Calls this plan makes (the owner may overturn)

Items 3 and 5 differ from the owner's words or the mockup and are **for the owner to confirm** at the plan's review.

1. The cursor is the message's arrival order (`rowid`), not its Slack time: a late-synced channel is not missed; "oldest first" means oldest arrival.
2. A byte budget (180 KiB) joins the umbrella's 500 / 200 000 caps, so the window always fits `llm()`; a cut window makes the next cycle run at once — the one exception to "at most once an hour", which costs nothing extra since each catch-up run reads only messages no run has read.
3. **To confirm:** "every channel you are a member of" is read as public and private member channels; DMs and group DMs are left out, because everything in them is addressed to you and Waiting for me already lists it. Including them would only add lines the recipe then drops (and model spend).
4. Only built-ins call the window in this phase (`builtin:slack.window`), and only the wide scope is built; the narrow scope, the owner-recipe capability and per-automation added channels come with #920's first reader of them.
5. **To confirm:** the card holds only labelled lines, so it turns unread only when a line changes (the spec's living rule); a channel's "N new" and the "N channels with nothing for you · M messages" line move off the card: the totals into the pane header and the row, the quiet-channel line into a folded line the pane draws under the card, both from the built-in's state. The mockup draws "#name · N new" in each channel heading; with that count on the card, every quiet message in a busy channel would mark the whole card unread again.
6. Per-channel 6 / per-day 90 lines and 18 channels on the card, forced by the 64 KB state cap and the 40-block card cap; whatever the caps take out is shown as "N more lines" and "N more channels with news", never silently.
7. A failed run is retried after 15 minutes; a succeeded run waits an hour unless its window was cut.
8. `slack-today` is left out of onboarding's goals (default on; it runs only once Slack is connected).
