# Inbox redesign, phase 2 — Waiting for me (people) and Mail waiting: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the Inbox's waiting list into **Waiting for me** (people only, Today / This week / Older with one bulk press) and a new built-in **Mail waiting** (one row per sender, Mark All Done… and Mute), with the bulk CLI, muted senders, keyboard and hover actions, and narrow phase 1's interim counts to people.

**Architecture:** One read primitive (`attention.waiting`) returns people and mail with separate caps, a `kind` and a `section` per row, people counts and a per-sender mail view with muted senders left out; two built-ins at the same slot draw it (`waiting-for-me`, `mail-waiting`). Bulk closes are the owner's two-step CLI press (`inbox resolve --dry-run` → `--ids`), drawn by phase 1's `InboxBulkPressButton`; a mute is a `source_mute` learned rule written by the Desktop's existing rules writer. New row-ref kinds with a text id (`mail_sender`, `waiting_older`) carry the native actions; every Go↔Swift rule (kind, today, sections, mute, sender aggregate) is pinned by a shared fixture.

**Tech Stack:** Go 1.26 (`internal/db`, `internal/automations/blocks`, `internal/automations/builtin`, `internal/daemon`, `cmd`), goja recipes, SwiftUI + GRDB (`WatchtowerCore`, `DesignKit`, `WatchtowerDesktop`), the Kit's `WatchtowerDesign`.

**Spec:** `docs/superpowers/specs/2026-11-11-inbox-redesign-design.md` (owner-approved, ask #638; Decisions binding) — sections "Waiting for me and Mail waiting (phase 2)", "The list (phase 1)" rows for Waiting for me / Mail waiting, "Counts", "Phases" (phase 1 alone), "Inventory" (INBOX-05). Mockup: `docs/design/mockups/inbox-redesign/inbox-redesign.html` (panes `wait`, `mail`).

## Global Constraints

- "Today" = since local midnight; an item is from today when `MAX(created_at, mentioned_at)` is at or after it (spec "Today everywhere on this page"); Go and Swift share `internal/inbox/testdata/from_today.json`.
- People = every feed trigger but `email_received`; mail = `email_received` (spec: "Waiting for me = people (Slack, Jira, Linear)").
- `attention.waiting` caps: up to **200** people items and up to **200** mail items, each newest first, each within its own byte budget.
- Sections: **Today** (from today), **This week** (< 7 days), **Older** (7 × 24 h or more, folded, with a note row carrying **Mark All Done…**). Title stays "Waiting for me".
- Built-in id **`mail-waiting`**, name "Mail waiting", slot `waiting_for_me` right after Waiting for me, `FeatureIDs: [secretary-inbox]`, capability `builtin:attention.waiting`, `DefaultFolder: inbox`, no `llm()`, living artifact key `mail`; one row per sender (`ref {kind: mail_sender, id: <address>}`) busiest first with open count, today's count and newest subject; the top ten senders' share in the header line.
- Bulk CLI (owner verbs, refused under every agent marker): `watchtower inbox resolve --dry-run --json (--sender <addr> --trigger email_received | --older-than 7d --people)` → last stdout line `{"count":N,"ids":["…"]}`; `watchtower inbox resolve --ids a,b,c --json` → `{"resolved":N,"skipped":N,"ids":["…"]}`; on error exit 1 with last stdout line `{"resolved":N,"of":M,"error":"…"}`. Resolve reason **"Marked done in bulk"**. A press never closes more than its dry run named.
- Mute = learned rule `rule_type = 'source_mute'`, `scope_key = 'email:<address>'`, `source = 'user_rule'`, written only by the Desktop's existing writer `InboxLearnedRulesQueries.upsertManual`; it hides the sender from Mail waiting only and never changes an `inbox_items` row (INBOX-05 amendment, approved in ask #634).
- Mail never counts: not in the badge, not in Needs you's counts, never a Waiting for me term. Mail waiting's pill = mail from today, neutral tone. Sidebar badge = Needs approval + people waiting today.
- Mail waiting keys on a focused sender row: ⏎ open, **E** mark all done, **M** mute. Waiting for me: **J/K** move, **E** done, **R** reply (people only), **S** snooze, ⏎ open, **⌘K** hand to agent. Desktop only.
- Row actions appear over the row's trailing edge on hover or focus (opacity), replacing the age chip; the row height never changes.
- Nothing disappears without the owner's press; every bulk press confirms with the count first; a CLI error leaves rows as they were, shows the CLI's text with **Try Again** (re-runs the dry run); a partial write reads "Closed N of M. <error>"; never retried by itself.
- UI strings English; repo English; no live data, ids, names or paths (Public repo hygiene); samples `acme` / `example.com`.
- Desktop code follows `docs/review/review-rules.md` "Swift / Desktop conventions" and `docs/design/desktop-style-guide.md` (tokens only, `.kitRow`, no row dividers, one prominent action per screen); async state that must survive navigation lives on a center owned by `ActionStripViewModel`, not in a view.
- Task-scope checks only (`go test ./internal/<pkg>`, `go test ./cmd -run <Name>`, `make test-swift FILTER=…`, `make kit-test FILTER=…`, `make lint-diff`); the full gate runs once per phase by the controller.

**Phase 1 names consumed (defined there, used as is):** `InboxToday.startOfToday(now:calendar:)`, `InboxToday.isFromToday(createdAt:mentionedAt:now:calendar:)`, the fixture `internal/inbox/testdata/from_today.json`; `InboxBulkPlan`, `InboxBulkResult`, `InboxBulkPressModel` (`begin(plan:)`, `confirm(apply:)`, `cancel()`), `InboxBulkPressButton(title:confirmTitle:model:)`; `InboxListRow`, `InboxRowContent`, `InboxRowKind.peopleWaiting` / `.mailWaiting`, `InboxRootSection.needsYou`, `InboxRootSections.build(entries:…)`; `InboxPaneHeader(tile:title:subtitle:actions:)`. Where a task edits a phase-1 function whose exact name the brief does not fix (the root row-content builder, the badge's people term), it says how to find it.

## Review Focus

1. **One sender, many spellings** — `Bob@Example.com`, ` bob@example.com` and a non-ASCII local part must group, mute and bulk-close as one sender on both sides; SQLite `lower()`/`trim()` are ASCII/space-only, so every key goes through one ASCII-lowercase, space-trim rule (Task 2 fixture cases, Task 7 CLI test, Task 9 parity test).
2. **State moves between the dry run and the write** — an item auto-resolved, snoozed or resolved by hand after the confirmation opened is skipped and reported, never re-closed or re-opened (Task 7 `TestResolveOpenInboxItems_SkipsClosedSnoozedAndUnknown`, Task 10 decoding `skipped`).
3. **Midnight and the 7-day line** — an item at exactly local midnight is Today; one exactly 7 × 24 h old is Older and is in `--older-than 7d`; a zone whose DST starts at midnight still finds the first instant of the day like `Calendar.startOfDay` (Task 1 fixture case, Task 7 boundary test).
4. **A sender address the ref would refuse** — empty, quoted, several `@`, spaces or over 254 bytes (raw `FromEmail`): listed and counted with no ref (no Open/Mark All Done/Mute), the run never fails on it; `--sender ""` is refused (Task 3 `ValidSenderAddress`, Task 4, Task 6, Task 7).
5. **A large backlog** — thousands of old people items: the CLI writes in chunks and reports "Closed N of M" if a chunk fails; the primitive's full result stays under the SDK result cap and each artifact under the block cap with 200 long non-Latin rows (Task 4 worst-case test, Task 7 partial-failure test).

---

### Task 1: Go twin of InboxToday and the section rule

**Depends on:** none (phase 1 merged: the fixture exists)

**Files:**
- Create: `internal/db/inbox_today.go`
- Test: `internal/db/inbox_today_test.go`
- Modify: `internal/inbox/testdata/from_today.json` (one DST-at-midnight case, both sides read it)

**Interfaces:**
- Produces: `func StartOfToday(now time.Time) time.Time` (in `now`'s location: the first instant whose local date is `now`'s date); `func IsFromToday(createdAt, mentionedAt, now time.Time) bool` (`mentionedAt` zero = none; item time = the later of the two); `type WaitingSection string` with `SectionToday = "today"`, `SectionWeek = "week"`, `SectionOlder = "older"`; `const WaitingOlderAfter = 7 * 24 * time.Hour`; `func WaitingSectionOf(at, now time.Time) WaitingSection` (today if `!at.Before(StartOfToday(now))`; else week if `now.Sub(at) < WaitingOlderAfter`; else older; a zero `at` is older, matching the SQL cutoff compare in Task 7).

- [ ] **Step 1: Write the failing tests**

`TestInboxToday_SharedFixture`: reads `../inbox/testdata/from_today.json` with the keys phase 1 wrote (`now`, `tz`, `created_at`, `mentioned_at` nullable, `expected`), loads `tz` with `time.LoadLocation`, asserts `IsFromToday(...) == expected` per case, failing with the case index.
`TestWaitingSectionOf`: at = start of today → today; one second before → week; `now − 7×24h` → older; `now − 7×24h + 1s` → week; zero → older.
Add one fixture case in a zone whose DST starts at 00:00 (pick the transition date from the tz database, e.g. America/Santiago in September): an item at the day's first instant (01:00 local) is today. Phase 1's Swift test must still pass on it.

- [ ] **Step 2: Run** `go test ./internal/db -run 'TestInboxToday_SharedFixture|TestWaitingSectionOf'` — expect FAIL (undefined).
- [ ] **Step 3: Implement** in `internal/db/inbox_today.go`. `StartOfToday` builds `time.Date(y, m, d, 0, 0, 0, 0, loc)` and, when normalization moved it off date `d`, walks forward to the first instant on date `d` (Swift `startOfDay` semantics).
- [ ] **Step 4: Run** the same command plus `make test-swift FILTER=InboxToday` — expect PASS on both sides.
- [ ] **Step 5: Commit** `feat(inbox): Go twin of InboxToday and the waiting sections (#1076)`.

---

### Task 2: People/mail split, muted senders and the sender view in `internal/db`

**Depends on:** Task 1

**Files:**
- Modify: `internal/db/inbox_open.go`
- Modify: `internal/db/testhelpers.go` (seed loader)
- Create: `internal/inbox/testdata/waiting_split.json`
- Test: `internal/db/inbox_open_test.go`

**Interfaces:**
- Produces:
  - `type WaitingKind string`, `WaitingPeople = "people"`, `WaitingMail = "mail"`; `func WaitingKindOf(trigger string) WaitingKind` (`email_received` → mail, every other feed trigger → people).
  - `const MuteScopePrefix = "email:"`; `func MailSenderKey(raw string) string` — ASCII-only lowercase and spaces trimmed (SQLite `lower(trim(x))`'s exact result).
  - SQL fragment `mutedMailClause` (unexported): `NOT EXISTS (SELECT 1 FROM inbox_learned_rules r WHERE r.rule_type = 'source_mute' AND r.scope_key = 'email:' || lower(trim(inbox_items.sender_user_id)))` — any weight, any pipeline.
  - `func (db *DB) OpenInboxItemsOfKind(ctx context.Context, now time.Time, kind WaitingKind, limit int) ([]OpenInboxItem, error)` — `openInboxClause` + the kind; mail also `mutedMailClause`; order as `OpenInboxItems`.
  - `type PeopleWaitingCounts struct{ Open, Today, Week, Older int }`; `func (db *DB) OpenPeopleCounts(ctx context.Context, now time.Time) (PeopleWaitingCounts, error)` — uncapped counts by `WaitingSectionOf`'s rule in SQL (today: stamp ≥ `StartOfToday(now)` in UTC; older: stamp ≤ `now − WaitingOlderAfter`).
  - `type MailSender struct{ Address string; Open, Today int; Subject, At, Permalink string }` (Address = `MailSenderKey`, "" for a mail item with no address; Subject = the newest item's snippet before " — ", as `waitingWhere` cuts it).
  - `type MailWaiting struct{ Open, Today, SenderCount, TopTenShare int; Senders []MailSender }`; `func (db *DB) OpenMailSenders(ctx context.Context, now time.Time, limit int) (MailWaiting, error)` — open, unmuted mail grouped by `lower(trim(sender_user_id))`, ordered open DESC, newest stamp DESC, address ASC; `Senders` capped at `limit`, totals over all; `TopTenShare = (100·Σtop10 + Open/2) / Open` (0 when Open = 0).
  - `func SeedTestWaitingSplitFixture(t *testing.T, d *DB, path string) WaitingSplitFixture` (same shape as `SeedTestOpenItemsFixture`, plus `inbox_learned_rules` rows and `tz`).

- [ ] **Step 1: Write the fixture** `internal/inbox/testdata/waiting_split.json`: `about`, `now`, `tz`, `jira_issues`, `items` (Slack DM/mention/thread reply, Jira, Linear, mail; mail from one sender in three spellings — upper case, leading space, plain; a sender with a non-ASCII local part; a muted sender; a mail item with an empty address; snoozed-past-now, resolved and archived items; one item at exactly local midnight, one exactly 7 × 24 h old), `rules` (one `source_mute` `email:<addr>` user rule, one `source_mute` `sender:<id>` rule that must not mute mail), `expected`: `kinds` (id → kind), `people` {open, today, week, older}, `mail` {open, today, sender_count, top_ten_share}, `senders` [{address, open, today, subject}] in order, `older_people_ids`, `sender_ids` (address → ids, newest first). Sample data only.
- [ ] **Step 2: Write the failing test** `TestWaitingSplit_SharedFixture`: seeds the fixture; asserts `WaitingKindOf` per id, `OpenPeopleCounts`, `OpenMailSenders(…, 200)` field by field and sender order, and that `OpenInboxItemsOfKind(mail)` never returns a muted sender's item. `TestOpenInboxItemsOfKind_CapsEachKindSeparately`: 250 people + 250 mail → 200 of each, newest first. `TestMailSenderKey`: `" Bob@Example.COM"` → `"bob@example.com"`, non-ASCII letters unchanged.
- [ ] **Step 3: Run** `go test ./internal/db -run 'TestWaitingSplit|TestOpenInboxItemsOfKind|TestMailSenderKey'` — FAIL.
- [ ] **Step 4: Implement** the functions above; `OpenInboxItems` keeps its signature and behaviour (Desktop's `fetchOpenMessages` twin, `TestOpenInboxItems_SharedFixture` unchanged).
- [ ] **Step 5: Run** the command again plus `go test ./internal/db -run TestOpenInboxItems_SharedFixture` — PASS.
- [ ] **Step 6: Commit** `feat(inbox): people/mail split, muted senders and the sender view (#1076)`.

---

### Task 3: Row refs with a text id — `mail_sender` and `waiting_older`

**Depends on:** none

**Files:**
- Modify: `internal/automations/blocks/blocks.go`, `internal/automations/blocks/validate.go`
- Modify: `internal/automations/blocks/testdata/blocks_cases.json` (regenerated with `-update`)
- Modify: `WatchtowerKit/Sources/WatchtowerDesign/ArtifactBlocks.swift`
- Test: `internal/automations/blocks/blocks_test.go`, `WatchtowerKit/Tests/…/ArtifactBlocksTests.swift`, `WatchtowerDesktop/Tests/Core/ArtifactFixtureParityTests.swift` (existing readers of the fixture)

**Interfaces:**
- Produces (Go): `RefMailSender = "mail_sender"`, `RefWaitingOlder = "waiting_older"` appended to `refKinds`; `Ref{Kind string; ID int64; Key string}` — JSON `id` is a string for the two text kinds (`Key`) and an integer for the others (custom `MarshalJSON`/canonical form; every existing document's canonical bytes and `ContentHash` unchanged). Both new kinds are built-in only. `func ValidSenderAddress(s string) bool` (exported; the one rule the primitive uses to decide `actionable`): a string of 3–254 bytes with exactly one `@`, none of space, control characters, `"`, `<`, `>`, `,`, and equal to its ASCII lowercase. Validation messages (pinned in the fixture): `%s.id must be a sender address` (mail_sender, `!ValidSenderAddress`); `%s.id must be "people"` (waiting_older); `%s: a mail_sender ref is only for built-in automations` / `%s: a waiting_older ref is only for built-in automations`; an integer kind with a string id keeps `%s.id must be a positive integer`.
- Produces (Kit): `ArtifactRefKind.mailSender = "mail_sender"`, `.waitingOlder = "waiting_older"`, `var hasTextID: Bool`; `ArtifactRef { kind; id: Int64; key: String }` with `init(kind:id:)` (key "") and `init(kind:key:)` (id 0); the decoder reads a string id for text kinds and refuses (unreadable) a text kind with a number id or an integer kind with a string id.

- [ ] **Step 1: Write the failing tests.** Go `TestRef_TextKinds`: a built-in document with `{kind: mail_sender, id: "a@example.com"}` and `{kind: waiting_older, id: "people"}` validates and round-trips; an owner document with either is refused with the pinned message; `"A@example.com"`, `"a example.com"`, `""`, `7` are refused. `TestContentHash_ExistingCasesUnchanged`: every pre-existing valid case keeps its stored `content_hash`. Fixture: add the valid and invalid cases. Kit `testTextRefsDecode` / `testTextKindWithNumberIDIsUnreadable`.
- [ ] **Step 2: Run** `go test ./internal/automations/blocks` and `make kit-test FILTER=ArtifactBlocksTests` — FAIL.
- [ ] **Step 3: Implement**; regenerate the fixture's computed fields with `go test ./internal/automations/blocks -update`.
- [ ] **Step 4: Run** both commands plus `make test-swift FILTER=ArtifactFixtureParityTests` — PASS.
- [ ] **Step 5: Commit** `feat(blocks): mail_sender and waiting_older refs with a text id (#1076)`.

---

### Task 4: `attention.waiting` — kinds, sections, separate caps, people counts and senders

**Depends on:** Task 2

**Files:**
- Modify: `internal/automations/builtin/waiting.go`
- Modify: `internal/daemon/builtin_slots.go` (`waitingForMeGate` calls the people fingerprint)
- Test: `internal/automations/builtin/waiting_test.go`, `internal/daemon/waiting_for_me_test.go`

**Interfaces:**
- Consumes: Task 1 `WaitingSectionOf`; Task 2 `OpenInboxItemsOfKind`, `OpenPeopleCounts`, `OpenMailSenders`.
- Produces: `attention.waiting()` → `{status: "done", items, mail_items, people, mail, senders}`:
  - `items`: the people rows only (≤ `WaitingPeopleLimit` = 200, newest first); `mail_items`: the mail rows (≤ `WaitingMailLimit` = 200, newest first, muted left out). Every row has today's fields plus `kind` (`"people"` in `items`, `"mail"` in `mail_items`) and `section` (`"today"`|`"week"`|`"older"`, `WaitingSectionOf` in the clock's location — the daemon's local zone). Keeping mail out of `items` means an owner's copy of Waiting for me written before phase 2 never gets more than 200 rows or a mail row it did not ask for; its mail is in `mail_items` and Mail waiting (an owner's copy that read mail from `items` now lists people only; the guide and the feature note say so, and the controller lists it in the PR for the owner).
  - `people`: `{open, today, week, older}`; `mail`: `{open, today, senders, top_ten_share}`; `senders`: ≤ `WaitingSendersLimit` = 200 `{address, actionable, open, today, subject, at, permalink}` (`permalink` only when `webLink` admits it; `actionable` = `blocks.ValidSenderAddress(address)` from Task 3 — false for "" and for any raw `FromEmail` the ref would refuse: quotes, several `@`, spaces, over 254 bytes, non-lowercase after the ASCII rule).
  - Byte budgets, each split evenly across its rows as today: `waitingPeopleBudgetBytes = 90 << 10`, `waitingMailBudgetBytes = 40 << 10`, `waitingSendersBudgetBytes = 80 << 10`; a sender's address is never clipped (it is the ref), its subject takes what is left.
  - `func WaitingFingerprint(ctx context.Context, d *db.DB, now time.Time, kind db.WaitingKind) (string, error)` — people: the people rows as shown (today's fields + `section`) and `people`; mail: `senders` and `mail`. `WaitingPrimitives(d, now)` keeps its signature.

- [ ] **Step 1: Write the failing tests.** `TestAttentionWaiting_SplitsKindsWithSeparateCaps` (250 people + 250 mail → 200 in `items`, all `people`, and 200 in `mail_items`, all `mail`); `TestAttentionWaiting_OwnerCopyOfWaitingForMeGetsNoMail` (a pre-phase-2 owner copy — today's shipped recipe text, `overridden` — runs and writes one row per open people item, at most 200, and no mail row); `TestAttentionWaiting_SenderNotActionable` (raw addresses `"Name" <a@example.com>`, `a@@example.com`, `a b@example.com`, a 300-byte address → `actionable` false, still grouped and counted); `TestAttentionWaiting_SectionsInLocalZone` (clock in a non-UTC zone; an item just after local midnight is `today`, a UTC-today but local-yesterday item is `week`); `TestAttentionWaiting_MutedSenderLeftOut` (items and senders); `TestAttentionWaiting_WorstCaseUnderSDKCap` (200 + 200 + 200 rows of long non-Latin text: the marshalled fields ≤ `automations.MaxSDKResultBytes`); `TestWaitingFingerprint_PeopleIgnoresMail` (a new mail item leaves the people fingerprint, changes the mail one); `TestWaitingFingerprint_SectionChangeAtMidnight` (same items, clock moved past midnight → people fingerprint changes). Update `TestWaitingForMe_CapsAt200` to the people cap and `TestWaitingFingerprint` to the `kind` argument.
- [ ] **Step 2: Run** `go test ./internal/automations/builtin -run 'TestAttentionWaiting|TestWaitingFingerprint|TestWaitingForMe_CapsAt200'` — FAIL.
- [ ] **Step 3: Implement**; the daemon's Waiting for me gate passes `db.WaitingPeople`.
- [ ] **Step 4: Run** the command plus `go test ./internal/daemon -run TestPhaseWaitingForMe` — PASS.
- [ ] **Step 5: Commit** `feat(automations): attention.waiting splits people and mail (#1076)`.

---

### Task 5: Waiting for me recipe — people only, Today / This week / Older

**Depends on:** Task 3, Task 4

**Files:**
- Modify: `internal/automations/builtin/recipes/waiting-for-me.md`
- Modify: `internal/automations/builtin/registry.go` (card copy of `waiting-for-me`)
- Modify: `internal/automations/builtin/testdata/show_waiting_for_me.json` (`-update`)
- Test: `internal/automations/builtin/waiting_test.go`

**Interfaces:**
- Consumes: Task 4's `items[].kind/section`, `people`; Task 3's `waiting_older` ref.
- Produces: the artifact `waiting` ("Waiting for me") with up to three list blocks, a list drawn only when its section has rows: title `Today · <people.today>`, `This week · <people.week>`, `Older · <people.older>`. Rows as today (title, subtitle, age badge, `warning` tone past 24 h, link, `ref {kind: inbox_item}`) for the `items` rows (people only since Task 4). The Older list's **first row** is the note row: title `<people.older> items are older than 7 days` (`1 item is older…` for one), subtitle `Nobody has followed up on them.`, `ref {kind: "waiting_older", id: "people"}`, no badge; the older item rows follow it. No people at all: one list with `empty: "Nobody is waiting on you"`. Card copy: Reads "The mentions, messages and tickets attention detection found", Does "Lists the people waiting on your answer in Slack, Jira and Linear: today, this week and older", "Updates the list after every sync; an item leaves when you answer it in the source, mark it done or snooze it", "Mail is in Mail waiting", "Uses no AI".

- [ ] **Step 1: Write the failing tests.** `TestWaitingForMe_WritesOneRowPerOpenItem` keeps its name (STRIP-01 guard) and now asserts one `inbox_item` ref row per open **people** item of `open_items.json` and no mail item row (mail coverage moves to Task 6's `TestMailWaiting_OneRowPerOpenSender`). New: `TestWaitingForMe_Sections` (titles and counts; an empty section draws no list); `TestWaitingForMe_OlderNoteRow` (first row of Older is the `waiting_older` ref with the pinned title/subtitle; singular form for one); `TestWaitingForMe_OnlyMailOpenShowsEmpty`. `TestWaitingForMe_ShippedRecipeHasNoLLM` unchanged and green.
- [ ] **Step 2: Run** `go test ./internal/automations/builtin -run TestWaitingForMe` — FAIL.
- [ ] **Step 3: Implement** the recipe and copy; regenerate the golden with `go test ./internal/automations/builtin -update` (the registry test's `update` flag rewrites `testdata/show_*.json`).
- [ ] **Step 4: Run** `go test ./internal/automations/builtin` and `make test-swift FILTER=BuiltinAutomationDetailDecodingTests` — PASS.
- [ ] **Step 5: Commit** `feat(automations): Waiting for me lists people by section (#1076)`.

---

### Task 6: Built-in `mail-waiting`

**Depends on:** Task 3, Task 4

**Files:**
- Create: `internal/automations/builtin/recipes/mail-waiting.md`
- Create: `internal/automations/builtin/testdata/show_mail_waiting.json` (`-update`)
- Modify: `internal/automations/builtin/registry.go` (entry right after `waiting-for-me`), `internal/automations/builtin/waiting.go` (`MailWaitingID`)
- Modify: `internal/daemon/builtin_slots.go`, `internal/daemon/daemon.go` (fields), `cmd/builtins.go` (gate map)
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Automations/BuiltinUpgradeNotice.swift` (`names`: `"mail-waiting": "Mail waiting"`)
- Test: `internal/automations/builtin/mail_waiting_test.go`, `internal/daemon/waiting_for_me_test.go`, `internal/automations/builtin/registry_test.go`

**Interfaces:**
- Consumes: Task 4's `senders`, `mail`; Task 3's `mail_sender` ref.
- Produces: `const MailWaitingID = "mail-waiting"`; `Entry{ID: "mail-waiting", Name: "Mail waiting", Slot: SlotWaitingForMe, FeatureIDs: ["secretary-inbox"], Primitives: [attention.waiting], DefaultFolder: RootFolder, RunNow: true, Reads: ["The mail attention detection found"], Does: ["Groups the mail that waits on you by sender, the busiest first", "Updates the list after every sync; muted senders are left out", "Uses no AI"], Sends: ["One Mail waiting list in your Inbox"], When: "After every sync, while attention detection is on"}`. Recipe frontmatter as `waiting-for-me.md` (`trigger: {sync: waiting_for_me}`, `artifacts: living`, `builtin:attention.waiting`, `outputs: [inbox]`, same budget). Artifact `mail`, title "Mail waiting": a text block `<top_ten_share>% of this mail comes from <min(10, senders)> senders.` (only when `mail.senders` > 0), one list (`empty: "No mail is waiting on you"`), a row per sender: title = address, or `Unknown sender` when it is ""; `ref {kind: mail_sender, id: address}` only when `actionable` (a sender the ref would refuse is still listed and counted, with no ref, so no Open / Mark All Done / Mute and the run never fails on one bad address), subtitle `<open> open · <today> today · <subject>` (subject part dropped when empty), badge `<open>`, link = permalink; when `mail.senders` > the rows listed, a closing text block `<n> more senders`. Daemon: `func (d *Daemon) MailWaitingGate() builtin.Gate` (the Waiting for me gate's rules with `WaitingFingerprint(…, db.WaitingMail)`, own `mailSeen`/`mailShown`); `phaseWaitingForMe` returns only when neither built-in is active, cancels queued runs of an inactive one, and records seen/shown per `o.BuiltinID`.

- [ ] **Step 1: Write the failing tests.** `TestMailWaiting_ShippedRecipeHasNoLLM`; `TestMailWaiting_OneRowPerOpenSender` (over `waiting_split.json`: one row per expected sender in order, `mail_sender` refs, muted sender absent, the empty-address sender `Unknown sender` with no ref); `TestMailWaiting_UnactionableSenderListedWithoutRef` (the Task 4 raw addresses: the run succeeds, the rows have no ref); `TestMailWaiting_HeaderShare` (pinned sentence; none with no mail); `TestMailWaiting_MoreSendersLine` (210 senders → 200 rows + `10 more senders`); `TestMailWaiting_ByteCapWithLongAddresses` (canonical blocks ≤ `blocks.MaxBlocksBytes`); `TestMailWaiting_SkippedWhenDetectionOff`; `TestRegistry_MailWaitingRunsRightAfterWaitingForMe` (`AtSlot(SlotWaitingForMe)` = `[waiting-for-me, mail-waiting]`). Daemon: `TestPhaseWaitingForMe_MailRunsOnlyWhenSendersChanged`, `TestPhaseWaitingForMe_MailFailedRunRetriedNextCycle`, `TestPhaseWaitingForMe_MuteChangesMailFingerprint`.
- [ ] **Step 2: Run** `go test ./internal/automations/builtin -run 'TestMailWaiting|TestRegistry'` and `go test ./internal/daemon -run TestPhaseWaitingForMe` — FAIL.
- [ ] **Step 3: Implement**; regenerate `show_mail_waiting.json` with `-update`; add the gate in `wireBuiltins`.
- [ ] **Step 4: Run** both commands, `go test ./cmd -run 'TestAutomationsWaiting|TestWireBuiltins'` and `make test-swift FILTER='BuiltinUpgradeNotice|BuiltinAutomationDetailDecodingTests'` — PASS.
- [ ] **Step 5: Commit** `feat(automations): Mail waiting built-in, grouped by sender (#1076)`.

---

### Task 7: Bulk resolve — DB and `watchtower inbox resolve`

**Depends on:** Task 2

**Files:**
- Create: `internal/db/inbox_bulk.go`, `internal/db/inbox_bulk_test.go`
- Modify: `cmd/inbox.go` (`resolve` takes an id **or** bulk flags)
- Create: `cmd/inbox_resolve_test.go`

**Interfaces:**
- Consumes: Task 1 `WaitingOlderAfter`; Task 2 `MailSenderKey`, `openInboxClause`.
- Produces:
  - `const BulkResolveReason = "Marked done in bulk"`; `const bulkResolveChunk = 200`.
  - `func (db *DB) OpenMailItemIDsFrom(ctx context.Context, now time.Time, address string) ([]int64, error)` — open `email_received` items whose `lower(trim(sender_user_id))` = `MailSenderKey(address)`, muted or not, newest first.
  - `func (db *DB) OpenPeopleItemIDsOlderThan(ctx context.Context, now time.Time, age time.Duration) ([]int64, error)` — open people items with stamp ≤ `now − age` (UTC string compare), newest first.
  - `func (db *DB) ResolveOpenInboxItems(ctx context.Context, ids []int64, reason string) (resolved []int64, err error)` — distinct ids, chunks of 200, each chunk one `BEGIN IMMEDIATE` transaction resolving only rows still `status = 'pending'`; on a failed chunk returns the ids resolved so far and the error.
  - CLI flags on `resolve`: `--dry-run`, `--sender <addr>`, `--trigger email_received` (the only value), `--older-than <n>d` (1–365), `--people`, `--ids a,b,c` (positive integers, ≤ 10 000, duplicates dropped), `--json`. Valid forms: `resolve <id>` (unchanged, not refused under an agent); `--dry-run (--sender X --trigger email_received | --older-than Nd --people)`; `--ids …`. Every bulk form is refused under an agent marker (`refuseUnderAgent("resolve inbox items in bulk")`). `--json` output, last stdout line: dry run `{"count":N,"ids":["…"]}`; write `{"resolved":N,"skipped":N,"ids":["…"]}` (ids resolved, as decimal strings); any failure exit 1 with `{"resolved":N,"of":M,"error":"…"}` (0/0 for a refusal or a bad flag; M = distinct ids asked). Without `--json`: `N items match` / `Resolved N, skipped M`.

- [ ] **Step 1: Write the failing tests.** DB: `TestOpenMailItemIDsFrom_MatchesEverySpelling` (fixture `sender_ids`); `TestOpenPeopleItemIDsOlderThan_MatchesTheOlderSection` (fixture `older_people_ids`; an item exactly 7 × 24 h old included, one second younger excluded; mail never included); `TestResolveOpenInboxItems_SkipsClosedSnoozedAndUnknown` (resolved, snoozed, dismissed and missing ids skipped; reason `Marked done in bulk`; no other column changed — full-row compare); `TestResolveOpenInboxItems_ChunksAndReportsPartial` (450 ids, a trigger aborts the third chunk → 400 returned with the error, the rest still pending). CLI: `TestInboxResolve_DryRunSenderJSON`, `TestInboxResolve_DryRunOlderPeopleJSON`, `TestInboxResolve_IdsJSON` (skipped counted), `TestInboxResolve_PartialFailureJSON` (exit 1, pinned keys), `TestInboxResolve_RefusedUnderAgent` (every bulk form, every marker in `agentEnvMarkers`, JSON error object, nothing written), `TestInboxResolve_FlagRules` (`--sender ""`, `--trigger mention`, `--older-than 0d`/`7h`/`400d`, `--people` alone, an id with flags, `--dry-run --ids` — each refused), `TestInboxResolve_SingleIDUnchanged`.
- [ ] **Step 2: Run** `go test ./internal/db -run 'TestOpenMailItemIDsFrom|TestOpenPeopleItemIDsOlderThan|TestResolveOpenInboxItems'` and `go test ./cmd -run TestInboxResolve` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** both commands — PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `feat(inbox): bulk resolve with a dry run (#1076)`.

---

### Task 8: INBOX-05 amendment and its Go guard

**Depends on:** Task 4

**Files:**
- Modify: `docs/inventory/inbox-pulse.md` (INBOX-05 Observable, Test guards, Changelog)
- Test: `internal/automations/builtin/waiting_test.go`

**Interfaces:**
- Consumes: Task 4's primitive.

- [ ] **Step 1: Write the guard** `TestInbox05_MutedSenderLeavesMailWaitingOnly`: seed a mail item and a `source_mute` user rule `email:<addr>`; `attention.waiting` leaves it out of `items` and `senders`; the `inbox_items` row is byte-identical before and after the run (full-row compare); `OpenInboxItems` (the Messages / Catch-Up reader) still returns it; a `source_mute` rule `sender:<id>` mutes nothing here.
- [ ] **Step 2: Run** `go test ./internal/automations/builtin -run TestInbox05` — PASS (Task 4 implemented it; the guard pins it).
- [ ] **Step 3: Edit INBOX-05** with the text approved in ask #634: the store's **readers** add the `attention.waiting` primitive, which leaves out the mail of a sender with a `source_mute` rule scoped `email:<address>` (ASCII-lowercased, spaces trimmed); the **outputs** a rule changes add the Mail waiting artifact, still never an `inbox_items` row; the **writers** stay exactly two — the Desktop's rules writer, now also reached from **Mute** on a Mail waiting row and **Mute Senders…**, and `watchtower catchup feedback`. Status line "(amended 2026-11-11, ask #634)". Add both guards to Test guards: this test and Task 11's `InboxLearnedRulesViewModelTests::test_INBOX_05_mute_sender_writes_one_user_rule`. Changelog line dated with the merge day naming board #1076, ask #634, "no guard relaxed".
- [ ] **Step 4: Commit** `docs(inventory): INBOX-05 — a muted sender leaves Mail waiting (#1076)`.

---

### Task 9: Core — text-id refs, waiting queries and the parity test

**Depends on:** Task 2, Task 3

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Inbox/InboxRefState.swift`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Inbox/InboxPeopleRule.swift`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/WaitingQueries.swift`
- Modify: every exhaustive switch over `InboxRef.Kind` / `ArtifactRefKind` (`InboxRefHooks.swift`, `InboxNativeRowContent.swift`, `DesignKitCatalog/Taxonomy.swift`, `ActionStripView.swift`, `CatchUpSourceCard.swift`) to compile, behaviour in Task 11
- Test: `WatchtowerDesktop/Tests/Core/WaitingSplitParityTests.swift`, `WatchtowerDesktop/Tests/Core/InboxRefStateTests.swift`, `WatchtowerDesktop/Tests/Core/InboxRefParityTests.swift`

**Interfaces:**
- Consumes: Task 3 Kit kinds; fixture `waiting_split.json`; phase 1 `InboxToday.startOfToday`.
- Produces:
  - `InboxRef.Kind` + `.mailSender = "mail_sender"`, `.waitingOlder = "waiting_older"`; `InboxRef.key: String`, `init(kind:key:)`; `refs(blocksJSON:)` reads a string id for text kinds (the Kit's rules, `InboxRefParityTests`); `InboxRefHooks.inboxRef(_:)` maps `key`.
  - `enum InboxPeopleRule { static let mailTrigger = "email_received"; static func isPeople(trigger: String) -> Bool; static let peopleClause: String; static let mailClause: String; static let mutedMailClause: String; static func senderKey(_ raw: String) -> String; static func muteScope(_ address: String) -> String }` — SQL twins of Task 2 (`mutedMailClause` byte-identical in meaning; `senderKey` ASCII-lowercase + space trim).
  - `enum WaitingQueries { static func peopleCounts(_ db: Database, nowUTC: String, startOfTodayUTC: String) throws -> PeopleWaitingCounts; static func mailSenders(_ db: Database, nowUTC: String, startOfTodayUTC: String, limit: Int) throws -> MailWaitingSummary; static func shownSenders(_ db: Database, keys: [String], nowUTC: String) throws -> Set<String>; static func newestPermalink(_ db: Database, sender: String, nowUTC: String) throws -> String? }` with `struct PeopleWaitingCounts: Equatable { open, today, week, older: Int }`, `struct MailSenderRow: Equatable { address: String; open, today: Int; subject: String }`, `struct MailWaitingSummary: Equatable { open, today, senderCount, topTenShare: Int; senders: [MailSenderRow] }` (Task 2's rules, one read each; a missing table reads as zero).
  - `InboxRefState.read`: `.mailSender` shown ⇔ in `shownSenders` (open, unmuted mail from that key), never waits; `.waitingOlder` shown ⇔ `peopleCounts.older > 0`, never waits.

- [ ] **Step 1: Write the failing tests.** `WaitingSplitParityTests`: `testKindsMatchTheGoFixture` (`isPeople` per id), `testPeopleCountsMatchTheGoFixture`, `testMailSendersMatchTheGoFixture` (every field and order), `testSenderKeyMatchesSQLite` (the fixture's spellings and a non-ASCII local part). `InboxRefStateTests`: `testMailSenderShownWhileOpenAndUnmutedNeverWaits`, `testWaitingOlderShownOnlyWithOlderPeople`. `InboxRefParityTests`: `testTextIDRefsReadLikeTheKit`.
- [ ] **Step 2: Run** `make test-swift FILTER='WaitingSplitParityTests|InboxRefStateTests|InboxRefParityTests'` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same filter plus `InboxRefStateParityTests|InboxFolderCountsTests` — PASS.
- [ ] **Step 5: Commit** `feat(desktop): text-id refs and the waiting queries (#1076)`.

---

### Task 10: `InboxBulkCLI`

**Depends on:** none (the CLI contract is pinned above; tests use a fake runner)

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Inbox/InboxBulkCLI.swift`
- Test: `WatchtowerDesktop/Tests/Core/InboxBulkCLITests.swift`

**Interfaces:**
- Consumes: phase 1 `InboxBulkPlan`, `InboxBulkResult`; `CLIRunnerProtocol.capture(args:timeout:)` (stdout kept on exit 1).
- Produces: `package struct InboxBulkCLI { init(runner: (any CLIRunnerProtocol)?); enum Operation: Equatable { case planSender(String), planOlderPeople(days: Int), resolve(ids: [String]) }; static func args(_: Operation) -> [String]; func planSender(_ address: String) async throws -> InboxBulkPlan; func planOlderPeople(days: Int = 7) async throws -> InboxBulkPlan; func resolve(ids: [String]) async -> InboxBulkResult }`; `package enum InboxBulkCLIError: Error, Equatable, LocalizedError { case cliUnavailable, refused(String), unexpectedAnswer }` (texts as `InboxFoldersCLIError`'s). Args: `["inbox", "resolve", "--dry-run", "--json", "--sender", X, "--trigger", "email_received"]`, `["inbox", "resolve", "--dry-run", "--json", "--older-than", "7d", "--people"]`, `["inbox", "resolve", "--ids", "a,b,c", "--json"]`; timeout 120 s. `resolve` maps exit 0 → `.done(count: resolved, skipped:)`; exit 1 with the error object → `.partial(done: resolved, of:, error:)` when `resolved` > 0, else `.failed(error)`; no binary, no JSON or an unknown shape → `.failed(<the LocalizedError text>)`. `resolve(ids: [])` runs nothing and returns `.done(count: 0, skipped: 0)`.

- [ ] **Step 1: Write the failing tests** `testArgsPerOperation`, `testPlanDecodesCountAndIDs`, `testPlanRefusalThrowsTheCLIText` (exit 1 with `{"error":…}` / the error object), `testPlanCountMismatchIsUnexpected` (`count` ≠ `ids.count`), `testResolveDone`, `testResolvePartial`, `testResolveFailedWithNothingWritten`, `testNoBinaryFails`, `testEmptyIDsRunsNothing`.
- [ ] **Step 2: Run** `make test-swift FILTER=InboxBulkCLITests` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** `feat(desktop): InboxBulkCLI over inbox resolve (#1076)`.

---

### Task 11: Native actions for sender and Older rows, Mute, Mark All Done…

**Depends on:** Task 9, Task 10

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Inbox/InboxNativeRowContent.swift` (`InboxRowPress`, `InboxRowActionsContent.Kind`)
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Inbox/InboxBulkCenter.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Actions/ActionStripViewModel.swift` (owns the center; `muteSender(_:)`)
- Modify: `WatchtowerDesktop/Sources/Views/Inbox/Folders/InboxRefHooks.swift`, `InboxRowActionsView.swift`
- Modify: `WatchtowerDesktop/Sources/DesignKit/Artifacts/ArtifactView.swift` (Older fold)
- Test: `WatchtowerDesktop/Tests/Core/InboxBulkCenterTests.swift`, `WatchtowerDesktop/Tests/Core/MailSenderActionsTests.swift`, `WatchtowerDesktop/Tests/InboxLearnedRulesViewModelTests.swift`, `WatchtowerDesktop/Tests/ArtifactListFoldTests.swift`

**Interfaces:**
- Consumes: Task 9 refs/queries; Task 10 `InboxBulkCLI`; phase 1 `InboxBulkPressModel`, `InboxBulkPressButton`; `InboxLearnedRulesQueries.upsertManual(ruleType:scopeKey:weight:)`.
- Produces:
  - `InboxRowPress` + `.markAllDone`, `.mute` (`writes` = true for both).
  - `InboxRowActionsContent.Kind` + `.mailSender(address: String, openEnabled: Bool)` (**Open**, **Mark All Done…**, **Mute**) and `.waitingOlder` (**Mark All Done…**).
  - `enum InboxBulkKey: Hashable { case sender(String), olderPeople }`; `@MainActor package final class InboxBulkCenter: ObservableObject { init(cli: @escaping () -> InboxBulkCLI, onFinished: @escaping () async -> Void); func model(for key: InboxBulkKey) -> InboxBulkPressModel; func begin(_ key: InboxBulkKey) }` — one model per key, kept while the app runs (state survives leaving the pane); `begin` starts the plan (`planSender` / `planOlderPeople(days: 7)`); the model's confirm calls `resolve(ids:)` with exactly the planned ids; `onFinished` (the strip's `refresh()`) runs after every finished result.
  - `ActionStripViewModel.bulk: InboxBulkCenter`; `func muteSender(_ address: String) async` — `upsertManual(ruleType: "source_mute", scopeKey: InboxPeopleRule.muteScope(address), weight: -1.0)`, then `refresh()`; a failure lands in `rowErrors` for that ref with **Retry**.
  - Hooks: `nativeKinds(.mailSender)` = `[.open]`, `(.waitingOlder)` = `[]`; `open` on a sender row opens `WaitingQueries.newestPermalink` through `InboxCardLinkPolicy` (disabled when nil or refused); the Mark All Done… buttons are `InboxBulkPressButton(title: "Mark All Done…", confirmTitle: { "Mark \($0) Done" }, model: center.model(for:))`.
  - DesignKit: in `.inbox` mode a list whose first row's ref is `.waitingOlder` draws that row and a **Show <n> older** / **Hide** toggle (n = the other rows), folded by default, fold state per artifact in the view.

- [ ] **Step 1: Write the failing tests.** `InboxBulkCenterTests`: `testSenderPressPlansThenResolvesExactlyThePlannedIDs`, `testOlderPeoplePlansSevenDays`, `testStateSurvivesAReadOfTheModelAgain` (same instance per key), `testRefreshAfterEveryResult` (done, partial, failed), `testTryAgainRunsTheDryRunAgain`. `MailSenderActionsTests`: `testSenderRowOffersOpenMarkAllDoneMute`, `testOpenDisabledWithoutPermalink`, `testOlderRowOffersMarkAllDoneOnly`. INBOX-05 Swift guard `InboxLearnedRulesViewModelTests::test_INBOX_05_mute_sender_writes_one_user_rule`: `muteSender(" Bob@Example.com")` writes exactly one `inbox_learned_rules` row `source_mute` / `email:bob@example.com` / `user_rule` / `-1.0`, and no `inbox_items` column changes (full-row compare). `ArtifactListFoldTests`: `testOlderListFoldedByDefault`, `testOtherListsNeverFold`.
- [ ] **Step 2: Run** `make test-swift FILTER='InboxBulkCenterTests|MailSenderActionsTests|InboxLearnedRulesViewModelTests|ArtifactListFoldTests'` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the filter plus `InboxReplyPressTests|ActionStripAllKindsTests` — PASS.
- [ ] **Step 5: Commit** `feat(desktop): sender and Older row actions, Mute and Mark All Done (#1076)`.

---

### Task 12: Hover actions that never change row height, and the keyboard

**Depends on:** Task 11

**Files:**
- Modify: `WatchtowerDesktop/Sources/DesignKit/Artifacts/ArtifactView.swift` (`ArtifactListRowView`), `ArtifactEnvironment.swift` (`focusedRef`)
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Inbox/InboxRowKeyboard.swift`
- Modify: the reading pane that hosts the Waiting for me / Mail waiting artifact (`WatchtowerDesktop/Sources/Views/Inbox/InboxReadingPane.swift` or phase 1's pane)
- Test: `WatchtowerDesktop/Tests/Core/InboxRowKeyboardTests.swift`, `WatchtowerDesktop/Tests/ArtifactRowHoverTests.swift`

**Interfaces:**
- Consumes: Task 11 presses; `InboxReplyPolicy` (can reply).
- Produces:
  - `enum InboxKeyCommand: Equatable { case moveDown, moveUp, openSnoozeMenu, press(InboxRowPress) }`; `enum InboxRowKeymap { static func command(key: String, command: Bool, kind: InboxRef.Kind, canReply: Bool) -> InboxKeyCommand? }` — `j`/`k` move; `inboxItem`: `e` → `.done`, `r` → `.reply` only when `canReply`, `s` → `.openSnoozeMenu` (opens the focused row's **Snooze ▾** menu, so the owner picks Tomorrow / In 3 days / Next week as with the mouse — the key never picks a duration), `return` → `.open`, ⌘`k` → `.handToAgent`; `mailSender`: `return` → `.open`, `e` → `.markAllDone`, `m` → `.mute`; anything else nil (no S/R on a sender, no keys on `waitingOlder`).
  - `struct InboxRowFocus: Equatable { init(refs: [InboxRef]); var focused: InboxRef?; mutating func move(_ delta: Int); mutating func reconcile(refs: [InboxRef]) }` — refs are the shown, non-folded rows in document order; move clamps at the ends; reconcile keeps the focused ref while listed, else the row now at its old index, else the last, else nil.
  - `ArtifactEnvironment.focusedRef: ArtifactRef?`; `enum ArtifactRowChrome { static func showsActions(isHovered: Bool, isFocused: Bool, mode: ArtifactRenderMode) -> Bool }` (true in `.inbox` when hovered or focused; other modes keep today's inline layout). In `.inbox`, the badge (age chip) sits at the trailing edge and the native + row actions are an overlay on the trailing edge (opacity 0/1 over a `Fill.card` backing), so they never take layout space; the failure/Reply footer is unchanged.
  - The pane is focusable while it shows one of the two built-ins' artifacts; key presses go through `InboxRowKeymap` to the existing handler (`InboxRowActionHandler.press(_:on:)`), and `E` on a sender calls `InboxBulkCenter.begin(.sender(key))` (the confirmation still asks).

- [ ] **Step 1: Write the failing tests.** `InboxRowKeyboardTests`: one test per mapping above, `testReplyKeyNeedsReply`, `testNoSnoozeOrReplyOnSender`, `testFocusMoveClamps`, `testReconcileAfterRowLeaves` (row closed by E → focus moves to the next row). `ArtifactRowHoverTests`: `testHoverNeverChangesRowHeight` (an `.inbox` row with a badge, a long title and native actions, `NSHostingView` fitting height equal with `showsActions` false and true, at 360 and 640 pt widths), `testActionsHiddenUntilHoverOrFocus`, `testPreviewModeUnchanged`.
- [ ] **Step 2: Run** `make test-swift FILTER='InboxRowKeyboardTests|ArtifactRowHoverTests'` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the filter plus `ArtifactListRowPressTests` — PASS.
- [ ] **Step 5: Commit** `feat(desktop): hover actions without layout jumps, keys on the focused row (#1076)`.

---

### Task 13: The Mail waiting row and the narrowed phase-1 interim counts

**Depends on:** Task 9

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/InboxFolderQueries.swift` (`mailWaitingBuiltinID`, `MailWaitingState`)
- Modify: phase 1's root row-content builder and `InboxRootSections` (find with `grep -rn 'InboxRowContent(' WatchtowerDesktop/Sources/WatchtowerCore`) and the badge's people term in `ActionStripViewModel.legacyCounts` / `InboxFolderCounts` (phase 1's PR lists them under "Left interim")
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Inbox/InboxWaitingTexts.swift`
- Test: `WatchtowerDesktop/Tests/Core/InboxWaitingSplitTests.swift`, `WatchtowerDesktop/Tests/Core/InboxWaitingTextsTests.swift`, `WatchtowerDesktop/Tests/Core/InboxFeedQueriesTests.swift`

**Interfaces:**
- Consumes: Task 9 `WaitingQueries`, `InboxPeopleRule`; phase 1 `InboxRowKind.mailWaiting`, `InboxRootSection.needsYou`, `InboxToday`.
- Produces:
  - `package static let mailWaitingBuiltinID = "mail-waiting"`; `struct MailWaitingState: Equatable { automationID: Int64?; turnedOff: Bool }`, `InboxFolderQueries.mailWaiting(_ db: Database, featureOn: Bool) throws -> MailWaitingState` (turned off as Waiting for me's rule: feature off, or `enabled` 0 with no `disabled_reason`; its cards are then left out). No stand-in: the row exists only once its artifact does (its first successful run).
  - The mail-waiting artifact maps to `InboxRowKind.mailWaiting` in **Needs you**, right after Waiting for me; preview `InboxWaitingTexts.mailPreview`, meta `mailMeta`, pill = `MailWaitingSummary.today` with the neutral tone (none at 0); it is never unread-counted, never in a folder count or the badge, whatever its read state or rows.
  - `enum InboxWaitingTexts { static func mailPreview(_ s: MailWaitingSummary) -> String; static func mailMeta(_ s: MailWaitingSummary) -> String; static func mailPaneSubtitle(_ s: MailWaitingSummary) -> String; static func peoplePaneSubtitle(_ c: PeopleWaitingCounts) -> String }` — pinned: preview `"<today> new today. Most of it comes from <min(10, senderCount)> senders: clear a sender in one press."` — the mockup's sentence, K = the top ten (or fewer) senders whose share the meta line gives, the same number in both lines (`No new mail today.` when today = 0; `1 sender` singular; the second sentence is used only when `topTenShare` > 50, else it reads `It comes from <senderCount> senders: clear a sender in one press.`, and it is dropped when no sender); meta `"<open> open · <topTenShare>% from <min(10, senderCount)> senders"`; mail pane subtitle `"<open> open · <today> new today · grouped by sender, the busiest first"`; people pane subtitle `"People in Slack, Jira and Linear · <today> new today · <older> older · mail is in Mail waiting"`.
  - The people-waiting-today term (badge, Waiting for me pill and preview's "and N more today") counts only `InboxPeopleRule.isPeople` items, in both the artifact path and the Messages stand-in path. The stand-in's list itself still lists every open message (v1 limit, in the feature note).

- [ ] **Step 1: Write the failing tests.** `InboxWaitingSplitTests`: `testBadgeCountsPeopleTodayNotMail` (`ActionStripViewModel.badgeCount`: a Slack DM today + an `email_received` today + a mention yesterday → the waiting term is 1; with Waiting for me's artifact and with the stand-in), `testWaitingForMePillCountsPeopleToday`, `testMailWaitingRowAfterFirstRunOnly`, `testMailWaitingRowSitsRightAfterWaitingForMe`, `testMailWaitingNeverCounts` (unread artifact with and without rows: badge and root count unchanged), `testMailWaitingTurnedOffHidesItsCard`. `InboxWaitingTextsTests`: every pinned string incl. zero and singular forms, and `testMostOfItOnlyAboveHalf` (share 51 → "Most of it comes from 10 senders…"; share 50 and 30 → "It comes from <senderCount> senders…"). `InboxFeedQueriesTests` (the STRIP guard `testBadgeCountsDecisionsUnreadMessagesLatestUnreadDayAndDueReminders` keeps its name; if phase 1 pinned the interim mail term there, its expectation moves to people only — the approved STRIP badge rule, not a relaxation — and its assertions stay otherwise).
- [ ] **Step 2: Run** `make test-swift FILTER='InboxWaitingSplitTests|InboxWaitingTextsTests|InboxFeedQueriesTests'` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the filter plus `InboxFolderCountsTests|InboxFolderEntriesTests|SidebarCountsViewModelTests` — PASS.
- [ ] **Step 5: Commit** `feat(desktop): Mail waiting row; people-only waiting counts (#1076)`.

---

### Task 14: Pane headers and Mute Senders…

**Depends on:** Task 11, Task 13

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Inbox/MuteSendersModel.swift`
- Create: `WatchtowerDesktop/Sources/Views/Inbox/Folders/MuteSendersPopover.swift`
- Modify: the reading pane hosting the two built-ins (`InboxPaneHeader` subtitles; **Mute Senders…** action on Mail waiting)
- Test: `WatchtowerDesktop/Tests/Core/MuteSendersModelTests.swift`

**Interfaces:**
- Consumes: Task 9 `WaitingQueries.mailSenders(…, limit: 10)`; Task 11 `ActionStripViewModel.muteSender`; Task 13 texts; phase 1 `InboxPaneHeader`.
- Produces: `@MainActor package final class MuteSendersModel: ObservableObject { init(load: @escaping () async throws -> [MailSenderRow], mute: @escaping (String) async throws -> Void); private(set) var rows: [MailSenderRow]; var selected: Set<String>; var buttonTitle: String; var canApply: Bool; func load() async; func apply() async -> MuteSendersResult }`, `enum MuteSendersResult: Equatable { case done(Int), partial(done: Int, of: Int, error: String) }` — rows = the ten busiest unmuted senders with an address; none pre-ticked; `buttonTitle` "Mute 1 Sender" / "Mute N Senders" / "Mute Senders" (disabled at 0); apply writes one rule per ticked sender in row order, stops at the first failure ("Muted N of M. <error>" under the button), then the strip refreshes. The popover is anchored to **Mute Senders…**, kit rows with a checkbox `Toggle`, one prominent button. Pane headers: Waiting for me subtitle `peoplePaneSubtitle`, Mail waiting subtitle `mailPaneSubtitle` + the action.

- [ ] **Step 0: Mockup first.** Extend `docs/design/mockups/inbox-redesign/inbox-redesign.html` (sample data only) with three panels: the Mute Senders… popover (ten senders, none ticked, **Mute N Senders**), the Mark All Done… confirmation ("Mark 46 Done", with the count) and the "Closed N of M. <error>" line with **Try Again**. Commit it with `docs(inbox): mockups for Mute Senders and the bulk confirmation (#1076)`; the controller shows it to the owner with the phase's first review ask, before Step 3.
- [ ] **Step 1: Write the failing tests** `testNothingTickedAtStart`, `testTitlesByCount`, `testRowsAreTheTenBusiestUnmuted`, `testApplyMutesEachTickedSenderOnce`, `testApplyStopsAtFirstFailureAndReports`, `testLoadFailureShowsError`.
- [ ] **Step 2: Run** `make test-swift FILTER=MuteSendersModelTests` — FAIL.
- [ ] **Step 3: Implement** the model, popover and header wiring.
- [ ] **Step 4: Run** — PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `feat(desktop): Mute Senders panel and the waiting pane headers (#1076)`.

---

### Task 15: Shots, guide, feature notes and the STRIP changelog

**Depends on:** Task 5, Task 6, Task 7, Task 8, Task 12, Task 13, Task 14

**Files:**
- Create: `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+InboxRedesignWaiting.swift`
- Modify: `WatchtowerDesktop/Tests/DesignShots/DesignShotCatalog.swift`, `DesignShotsTests.swift`
- Modify: `docs/guide/features/inbox.md` (Waiting for me, new Mail waiting section with a `<!-- learn -->` card `inbox-mail-waiting`, `since: next`, keys, What the badge counts), `docs/guide/features/automations-built-in.md` (seven built-ins, Mail waiting line)
- Modify: `docs/features/inbox-redesign.md` (Phase 2 section), `docs/features/built-in-automations.md` (Mail waiting section after Waiting for me's)
- Modify: `docs/inventory/reaction-commands.md` (STRIP-01 amendment + Changelog)

- [ ] **Step 1: Shots.** `InboxRedesignWaitingShotFixtures.shots` seeded through the live stack on `acme` / `example.com` data at one fixed moment, light and dark: `inbox-r-waiting-people` (Today / This week / folded Older with the note row), `inbox-r-waiting-hover` (one row hot, height equal to its neighbours), `inbox-r-list-mail-row` (the list with Waiting for me and Mail waiting in Needs you), `inbox-r-mail-waiting` (pane header, share line, sender rows), `inbox-r-mail-mute-panel`, `inbox-r-mail-bulk-confirm` (Mark 46 Done), `inbox-r-mail-bulk-partial` ("Closed N of M." with Try Again). Add `testInboxRedesignWaitingShotsRender`. Run `make test-swift FILTER=testInboxRedesignWaitingShotsRender` — PASS; look at them with `make desktop-shots DESKTOP_SHOTS=<dir>`.
- [ ] **Step 2: Guide** per `docs/guide/WRITING.md`: Waiting for me = people in Slack, Jira and Linear by Today / This week / Older, **Mark All Done…** on Older (asks first with the count, nothing leaves on its own); Mail waiting by sender with **Open**, **Mark All Done…**, **Mute**, **Mute Senders…**, unmute in **Learned Rules**; the keys; the badge counts people waiting today and never mail.
- [ ] **Step 3: Notes.** `inbox-redesign.md` Phase 2: the primitive contract, the two built-ins, ref kinds, the CLI and its pinned keys, INBOX-05, the fixtures (`from_today.json` Go twin, `waiting_split.json`), and v1 limits — sender rows' numbers refresh at the next sync (a closed sender's row hides at once); the Messages stand-in still lists mail while Waiting for me's run has failed; an owner's copy of Waiting for me written before phase 2 now lists people only (mail moved to `mail_items` and Mail waiting) — pinned by `TestAttentionWaiting_OwnerCopyOfWaitingForMeGetsNoMail`; Older note counts come from the last run. `built-in-automations.md`: the Mail waiting entry, shared slot and gates.
- [ ] **Step 4: STRIP-01 amendment (needs the owner's OK before the phase PR merges).** Add an "Amended <merge day> (Inbox redesign phase 2)" paragraph to STRIP-01 in `docs/inventory/reaction-commands.md`, worded like B's 2026-11-06 Waiting for me amendment: the Mail waiting built-in writes one living `automation_outputs` artifact (`mail`) without an owner gesture, a view of `inbox_items` grouped by sender (one `mail_sender` ref row per sender); its rows act only on those records (Open, Mark All Done… through `inbox resolve`, Mute through the INBOX-05 rules writer); it reads only and calls no model; only built-ins may write `mail_sender` / `waiting_older` refs; the badge's waiting term is people only (the STRIP badge rule approved in ask #634). Guards: `TestMailWaiting_ShippedRecipeHasNoLLM`, `TestMailWaiting_OneRowPerOpenSender` added; `TestWaitingForMe_WritesOneRowPerOpenItem` keeps its name and now pins people rows (mail coverage moved to `TestMailWaiting_OneRowPerOpenSender`), no guard relaxed. Changelog line with board #1076. The controller raises this amendment to the owner in the phase PR's review ask and does not merge without the OK.
- [ ] **Step 5: Commit** `docs(inbox): phase 2 shots, guide and notes (#1076)`.

---

## Notes for the controller

- **Lanes:** Go lane Tasks 1 → 2 → {4 → {5, 6, 8}, 7}; Task 3 and Task 10 start at once; Swift lane 9 → {11 → 12, 13} → 14; Task 15 last. Tasks 2 and 7 both touch `internal/db` (different files); Tasks 11, 12 and 14 touch the reading pane — run 12 and 14 after 11 in one lane.
- **Gate once per phase:** `make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...` targeted per CLAUDE.md.
- **Owner OK needed before merge:** the STRIP-01 amendment for Mail waiting (Task 15 Step 4) and the change to owner copies of Waiting for me (people only, Task 4). The spec does not list either; both go into the phase PR's review ask.
- **Mockup placement kept from the spec, not the mockup:** **Mute Senders…** sits in the pane header (spec: "The pane header has Mute Senders…") rather than on the share line, because the share line is recipe content and cannot hold a native button. The mockup's automated/person label per sender is not in the spec and has no rule to compute it; it is left out.
- **Other agent's calls, overturnable:** ref kinds `mail_sender` and `waiting_older` are built-in only; the Older section is drawn as a list whose first row is the note (folded by the Desktop); the error object of a failed bulk write is the last **stdout** line (read through `capture`); Mute writes weight −1.0. Home's feed is not changed: the Mail waiting card reaches it like any other unread root artifact (as Waiting for me's does today); the spec says nothing about Home, so phase 2 leaves it alone.
