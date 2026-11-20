# Inbox redesign on the Go feed — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the Inbox redesign (PR #899, `feature/inbox-redesign`, board #1076) on today's main, where the Inbox's list, counts, ref facts and writes are built once in Go (`internal/inboxfeed`, #1170) and drawn by the Mac and the phone.

**Architecture:** Our Go backend (Slack today, `attention.waiting` + Mail waiting, Gmail sent catch-up, tracks news, `inbox resolve` bulk forms) merges in as is. Every Swift rule of ours that decides a list, an order, a count or a ref's state moves into `internal/inboxfeed` behind additive `api.Feed` fields. The redesign's views stay and are re-pointed at the feed. Per-Mac state (the idea batch, the selection, the Today/Earlier day split) stays on the Mac.

**Tech Stack:** Go 1.26 (`internal/inboxfeed`, `internal/tower/api`, `internal/tower/gen`), SwiftUI (WatchtowerDesktop, WatchtowerInterface, WatchtowerMobile), SQLite/goose.

**Spec:** `docs/features/inbox-redesign.md` (on `feature/inbox-redesign`: what the redesign does, phases 1–5); `docs/features/inbox-core.md` + `docs/superpowers/specs/2026-11-15-mobile-inbox-design.md` (main: the feed's rules); `.superpowers/port-outline.md` (the mapping, in this worktree). Owner decision: ask #798 (port, option a); ask #719 (Hide Older; Mail waiting stale line; stale sweep and IMAP chip stay v1 limits).

## Global Constraints

- Branch `feature/inbox-feed-port` from `origin/main` (09dd687ad at planning time). No push, no merge, no PR #899 change without the lead's separate ok.
- Our migration `00189_gmail_sent_catchup` becomes the next free number after main's last (main ends at `00210_company_setup`, so `00211_gmail_sent_catchup`), unless main has moved again by Task 1, in which case it takes the number after main's last. Every mention moves with it: `internal/db/schema.sql`, `internal/db/testdata/schema_v73.golden`, `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (`go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`), `docs/features/inbox-redesign.md`, `docs/features/README.md`.
- Main's feed rules hold. Go decides what a folder lists, its order, its counts and each ref's state. Times and the Today/Earlier split belong to the client's time zone (inbox-core.md "Stamps"). `inboxfeed.Build` writes nothing (`TestBuild_WritesNothing`).
- Every `api` change is additive and optional, and `api.FeedVersion` stays 1. The generated Swift (`make gen-interface`; CI runs `make gen-interface-check`) decodes an unknown enum value as `.unknown(String)`.
- Every table the feed reads joins `changetables.go` (`TestChangeTables_CoverEveryTableBuildReads`).
- UI copy in English, exactly as on `feature/inbox-redesign`. Fix 1 copy: **Show N older** / **Hide Older**. Fix 3 copy: "This list may be out of date — the last run failed." / "This list may be out of date — Mail waiting was stopped after a run that would not end."
- Inventory contracts touched on the branch (STRIP-01/02 amended, INBOX-02/05, APPROVAL-01, IDEA-04, TRACKS-07, AGENT-07) keep their branch wording. Main's inbox-folders/inbox-core notes win where they are newer. A guard that cannot keep both stops the task and goes to the owner.
- `docs/guide/features/inbox.md` ≤ 8192 bytes without learn cards (`TestFeaturePagesUnder8KB`).
- Inner loop only per task (CLAUDE.md "Agent-driven runs"). The full gate runs once per lane end and before the PR.

## Review Focus

1. **An older phone or Mac reading a newer feed.** A build without the new fields must still draw every card (the new ref kinds as plain rows, no crash). Pinned in Task 2 (`TestFeed_OldClientDecodesNewFields` + Kit `TowerTypesForwardCompatTests`).
2. **The badge and the root count disagree.** After the people-only change, the sidebar badge must equal what the root shows. Pinned in Task 4 (`TestCounts_BadgeEqualsRootAfterPeopleOnly`).
3. **Mail waiting after a failed run.** The last list stays, marked stale. A dry run or a run under way never hides or invents a failure. Pinned in Task 5.
4. **A bulk Mark All Done racing a new mail from the same sender.** Only the ids the owner saw close. The new one stays open. Pinned in Task 8 (`TestInboxAct_SenderDoneClosesOnlyPlannedIDs`).
5. **The Mac in another time zone than the daemon.** Today/Earlier and "new today" follow the Mac's zone, not the daemon's. Pinned in Task 9 (`testDatedSectionUsesClientZone`) and Task 4 (`today` counted in the zone `Options.Now` carries).

---

## Lanes

| Lane | Tasks | Starts after |
|---|---|---|
| 0 — base (controller, serial) | 1, 2 | — |
| G — Go feed | 3, 4, 5, 6, 7, 8 | 2 |
| M — Mac | 9, 10, 11, 12, 13, 14 | 2 (each names its Go task) |
| P — phone | 15 | 3, 5 |
| Z — close (controller) | 16 | all |

Lanes G, M and P run in their own worktrees (CLAUDE.md "Parallel lanes"). The controller merges them into `feature/inbox-feed-port`. Within the Mac lane, Tasks 11–13 may run in parallel once their Go task has merged. Task 9 goes first because it rewrites the shared list code.

---

### Task 1: Bring the branch's backend onto main

**Depends on:** none

**Files:**
- Merge: `feature/inbox-redesign` (with `1dcabbccb`, the Hide Older fix, from `feature/inbox-redesign-fu`) into `feature/inbox-feed-port`
- Rename: `internal/db/migrations/00189_gmail_sent_catchup.sql` → `00211_gmail_sent_catchup.sql` (see Global Constraints)
- Create: `.superpowers/port-ledger.md` (local, not committed): each Swift hunk of ours dropped here, with path + branch sha, for lane M

Resolution rules, applied to the 62 conflicts:
- **Go** (`internal/daemon/{builtin_slots,daemon,morning_brief}.go`, `internal/db/{inbox,inbox_open,tracks}.go`, `internal/gmail/{client,sync}.go`, `internal/prompts/*`, `internal/automations/blocks/blocks.go`, `internal/learn/retired.txt`, `internal/digest/models_test.go`, `internal/db/account_purge_steps_test.go`): keep both sides.
- **Schema** (`schema.sql`, golden, `TestDatabase+Schema.swift`): take main's, then re-apply ours via `-update` after the renumber.
- **Swift files main deleted** (`InboxListBuilder`, `InboxFolderEntries`, `InboxFolderCounts`, `InboxRefState` + their tests, `AgentActionCardView+Confluence`, `InboxAllKindsBuilderTests`): stay deleted. Our hunks go to the ledger.
- **Swift files both sides changed:** take main's. Our hunks go to the ledger.
- **Our new Swift files** (`SlackTodayPane`, `IdeaBatchPane`, `InboxTracksNewsPane`, `MuteSendersPopover`, `InboxBulk*`, `InboxRowKeyboard*`, `SlackToday*`, `TrackThreadsSummary`, `IdeaDailyBatch`, `InboxRootSections`, `WaitingQueries`, …): keep the ones that compile against main. A file that does not compile is removed and listed in the ledger, and the Mac lane restores it with `git show feature/inbox-redesign:<path>`.
- **Docs and inventory:** keep both sides' text. `docs/features/README.md` gets our summary line for inbox-redesign.md (main's CLAUDE.md lists notes by name only: add `- Inbox redesign — inbox-redesign.md` if it is missing).

- [ ] **Step 1:** `git merge --no-ff feature/inbox-redesign-fu`, resolve by the rules above, renumber the migration, then `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`.
- [ ] **Step 2:** Run `go build ./... > /tmp/b.log 2>&1; echo "exit=$?"`. Expected `exit=0`.
- [ ] **Step 3:** Run `go test ./internal/db ./internal/daemon ./internal/gmail ./internal/automations/... ./internal/inboxfeed ./internal/prompts ./internal/tracks ./internal/learn ./docs/guide > /tmp/t.log 2>&1; echo "exit=$?"`. Expected `exit=0`.
- [ ] **Step 4:** Run `cd WatchtowerDesktop && swift build > /tmp/s.log 2>&1; echo "exit=$?"`. Expected `exit=0`. Then `make test-swift FILTER='ArtifactListFoldTests|SlackTodayRowTests|InboxPaneHeaderTests'`. Expected PASS (`ArtifactListFoldTests` carries fix 1: `foldLabel(older:open:)` → "Show 2 older" / "Hide Older").
- [ ] **Step 5:** Commit the merge with the message "Merge feature/inbox-redesign onto main's Go feed (backend; Swift Inbox per port ledger)". The body names the renumber 00189 → 00211.

### Task 2: Feed contract additions

**Depends on:** Task 1

**Files:**
- Modify: `internal/tower/api/inbox.go`
- Regenerate: `WatchtowerInterface/Sources/WatchtowerInterface/Generated/TowerTypes.swift`, `internal/tower/interface_version.go` (`make gen-interface`)
- Test: `internal/tower/api/inbox_test.go`, `WatchtowerInterface/Tests/.../TowerTypesForwardCompatTests.swift`

**Interfaces — Produces** (every field `omitempty` or zero-safe):

```go
type CardSection string // root cards only; "" elsewhere
const (
    SectionNeedsYou CardSection = "needs_you" // Waiting for me, Messages stand-in, Mail waiting, thread briefs < 24 h, root approvals/notices on a tree without Needs approval
    SectionToday    CardSection = "today"     // Morning brief day, Slack today: Today whatever their stamp
    SectionRunning  CardSection = "running"   // Track my threads, Idea finder
    SectionDated    CardSection = "dated"     // other artifacts: the client puts them in Today if Stamp is today in its zone, else Running (root) / Earlier (owner folder)
)
// Card gains:
Section    CardSection      `json:"section,omitempty"`
Mail       *MailFacts       `json:"mail,omitempty"`        // the mail-waiting built-in's card
People     *PeopleFacts     `json:"people,omitempty"`      // the waiting-for-me built-in's card and the Messages stand-in
SlackToday *SlackTodayFacts `json:"slack_today,omitempty"` // the slack-today built-in's card

type MailFacts struct {
    Open, Today, Senders, TopTenShare int `json:"open"/"today"/"senders"/"top_ten_share"` // MailWaitingSummary
    Stale MailStale `json:"stale"`
}
type MailStale string // "" | "stopped" | "last_run_failed"   (fix 3)
type PeopleFacts struct{ Today, Older int } // json "today", "older"
type SlackTodayFacts struct {
    Status string `json:"status"` // "none" | "ok" | "unreadable"
    State  string `json:"state"`  // the stored state JSON when ok; the Mac decodes it (SlackTodaySummary)
}
// RefKind gains RefMailSender = "mail_sender", RefWaitingOlder = "waiting_older".
// RefFacts gains Key string `json:"key"` (mail_sender: the address; waiting_older: "people"; "" otherwise).
// LegacyItem gains News, Quiet bool (tracks: internal/tracks.HasNews / IsQuiet) and CreatedAt string (ideas, RFC 3339 UTC).
// Approval gains Group string `json:"group"` ("messages"|"tracks"|"targets"|"confluence_jira"|"reminders"|"other") and Bulk bool `json:"bulk"` (NeedsApprovalGroups.bulkTools).
```

- [ ] **Step 1: Write the failing test** `TestFeed_OldClientDecodesNewFields`: marshal a `Feed` with every new field set and decode it into a struct copy of the pre-change `Card`/`RefFacts`. It must decode without error, and the unknown `ref_facts[].kind` must decode to the generated `.unknown`. Also `TestFeed_NewFieldsOmittedWhenEmpty`: a card without them marshals byte-equal to today's golden in `internal/inboxfeed/testdata/inbox_feed_cases.json`.
- [ ] **Step 2:** Run `go test ./internal/tower/api -run 'TestFeed_'`. Expected FAIL (undefined fields).
- [ ] **Step 3:** Add the types, then run `make gen-interface`.
- [ ] **Step 4:** Run `go test ./internal/tower/... ./internal/inboxfeed`, `make gen-interface-check` and `make interface-test FILTER=TowerTypesForwardCompatTests` (decodes a feed JSON with `"kind":"mail_sender"` → `.unknown("mail_sender")` on a build pinned before regeneration, and the new `.mailSender` after). Expected all exit 0.
- [ ] **Step 5:** Commit "feat(tower): Inbox feed fields for the redesign (sections, mail, people, Slack today, ref keys, approval groups)".

### Task 3: Root order and sections in Go

**Depends on:** Task 2

**Files:** Modify `internal/inboxfeed/build.go`, `cards.go`. Create `internal/inboxfeed/sections.go`. Test `internal/inboxfeed/sections_test.go` + new cases in `testdata/inbox_feed_cases.json`.

**Interfaces:**
- Consumes: `api.CardSection` (Task 2).
- Produces: `func rootSection(c api.Card, s *snapshot) api.CardSection`. Builtin identification is by `builtin_id` (`waiting-for-me`, `mail-waiting`, `slack-today`). `readMailWaiting(ctx, tx, featureOn bool) (mailWaiting, error)` and `readSlackToday(ctx, tx) (slackToday, error)` sit next to `readWaitingForMe`.

The root order (branch `InboxFolderEntries.build` + `InboxRootSections.build`): Waiting for me (pinned while it waits) or Messages, then **Mail waiting right after it**, then thread briefs applied < 24 h (newest first), then the Morning brief and Slack today, then Track my threads and Idea finder, then the other artifacts newest first. Mail waiting is left out while it is turned off (feature `secretary-inbox` off, or `enabled = 0` with no `disabled_reason`). It has no stand-in: no card before its first run's artifact exists.

- [ ] **Step 1: Write failing tests:**
  - `TestRoot_MailWaitingRightAfterWaitingForMe` (cards in order WFM, Mail waiting, brief…, sections needs_you, needs_you);
  - `TestRoot_MailWaitingTurnedOffLeftOut` (feature off, and enabled=0 without a reason; a `disabled_reason` keeps it);
  - `TestRoot_SlackTodayIsTodayWhateverItsStamp`;
  - `TestRoot_ThreadBriefOlderThan24hDropsFromNeedsYou`;
  - `TestRoot_OtherArtifactsAreDated`;
  - `TestOwnerFolder_EveryCardDated`;
  - `TestApprovalsFolder_NoSections`.
- [ ] **Step 2:** Run `go test ./internal/inboxfeed -run 'TestRoot_|TestOwnerFolder_|TestApprovalsFolder_'`. Expected FAIL.
- [ ] **Step 3:** Implement. Add `automation_runs` (if not already listed) to `changetables.go`.
- [ ] **Step 4:** Run `go test ./internal/inboxfeed`. Expected PASS, including `TestBuild_WritesNothing` and `TestChangeTables_CoverEveryTableBuildReads`.
- [ ] **Step 5:** Commit.

### Task 4: People-only counts, Mail waiting never counted, people facts

**Depends on:** Task 3

**Files:** Modify `internal/inboxfeed/counts.go`, `build.go`. Test `counts_test.go`.

Rules (branch "Counts and badge", STRIP badge amendment, ask #634):
- The root's waiting term and the badge count open Waiting for me items **from today, people only** (every trigger but `email_received`).
- "Today" is in `Options.Now`'s location.
- Mail waiting's card never counts.
- `PeopleFacts{Today, Older}` comes from the same read as the branch's `PeopleWaitingCounts`: older = open people items at or before now − 7 × 24 h.

- [ ] **Step 1: Write failing tests:**
  - `TestCounts_PeopleTodayNotMail`: a DM today, a mail today and a mention yesterday give root waiting 1;
  - `TestCounts_MailWaitingNeverCounts`;
  - `TestCounts_BadgeEqualsRootAfterPeopleOnly`;
  - `TestCounts_TodayInTheOwnersZone`: `Now` in UTC+9 vs UTC puts a 23:30 UTC item on different days;
  - `TestPeopleFacts_TodayAndOlder`.
- [ ] **Step 2:** Run them. Expected FAIL.
- [ ] **Step 3:** Implement `func peopleCounts(ctx, tx, now time.Time) (today, older int, err error)` and wire it into `legacyCounts`/`waitingCounts`.
- [ ] **Step 4:** Run `go test ./internal/inboxfeed`. Expected PASS. Update inbox-core.md's `count`/`waiting` bullets in this commit (a contract change: people only).
- [ ] **Step 5:** Commit.

### Task 5: Mail waiting card facts, with the stale state (fix 3)

**Depends on:** Task 3

**Files:** Modify `internal/inboxfeed/build.go`, `cards.go`. Test `mailwaiting_test.go`.

**Interfaces — Produces:**
- `Card.Mail` on the mail-waiting artifact card;
- `func mailStale(ctx, tx, automationID int64, disabledReason string) (api.MailStale, error)`:
  - a `disabled_reason` gives `stopped`;
  - otherwise the latest run with `trigger != 'dry_run'` and status not in queued/running/waiting decides: a status other than `succeeded` gives `last_run_failed`, and no such run gives `""`;
  - turned off gives `""` (no card).

The counts reuse the branch's `MailWaitingSummary` rules (open = open, unmuted `email_received` items; today in the owner's zone; senders; top-ten share in whole percent, rounded half up, 0 with no mail). Port the Swift query `WaitingQueries.mailSummary` to `internal/db` as `db.MailWaitingSummaryTx(ctx, tx, now)`, unless the branch's Go `attention.waiting` already exposes it (check `internal/automations/builtin/waiting.go` `WaitingMail` first and reuse it).

- [ ] **Step 1: Write failing tests:**
  - `TestMailFacts_Counts`;
  - `TestMailStale_FailedRunAfterSuccess` (`last_run_failed`; the card stays);
  - `TestMailStale_DryRunAndRunningHideNothing` (failed, then dry_run succeeded, then running gives `last_run_failed`);
  - `TestMailStale_StopWins`;
  - `TestMailStale_LaterSuccessClears`;
  - `TestMailStale_TurnedOffNoCard`.
- [ ] **Step 2:** Run them. Expected FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `go test ./internal/inboxfeed ./internal/db`. Expected PASS.
- [ ] **Step 5:** Commit "feat(inboxfeed): Mail waiting facts and its stale state (owner, ask #719)".

### Task 6: Ref kinds `mail_sender` and `waiting_older`

**Depends on:** Task 2

**Files:** Modify `internal/inboxfeed/reffacts.go`, `counts.go` (`refsOf`/`rowRef` read the text `id` for these two kinds). Test `reffacts_test.go` + the shared `internal/automations/blocks/testdata/blocks_cases.json` cases already on the branch.

Rules (branch "Ref kinds"):
- A `mail_sender` ref's `id` must pass `blocks.ValidSenderAddress`. It is open while the sender still has open, unmuted mail (matched by sender key), with `Link` = the newest open mail's permalink. `Waits` = false.
- A `waiting_older` ref's `id` must be `"people"`. It is open while people `older` > 0. `Waits` = false.
- Both kinds carry `Key`.

- [ ] **Step 1: Write failing tests:**
  - `TestRefFacts_MailSenderOpenWhileOpenUnmutedMail` (mute closes it; a reply-closed Gmail item closes it);
  - `TestRefFacts_MailSenderNewestLink`;
  - `TestRefFacts_WaitingOlderOpenWhileOlder`;
  - `TestRefFacts_TextKeyKindsNeverWait`;
  - `TestRefsOf_InvalidSenderIgnored`;
  - `TestRefsOf_WaitingDocWithOlderNoteKeepsItemFacts` (the regression the T1 merge exposed: one text ref must not drop the document's other refs).
- [ ] **Step 2:** Run them. Expected FAIL.
- [ ] **Step 3:** Implement. Add `inbox_learned_rules` to `changetables.go` (a mute changes the feed).
- [ ] **Step 4:** Run `go test ./internal/inboxfeed ./internal/automations/blocks`. Expected PASS.
- [ ] **Step 5:** Commit.

### Task 7: Slack today, tracks news, idea fields, approval groups

**Depends on:** Task 3

**Files:** Modify `internal/inboxfeed/build.go`, `legacy.go`, `approvals.go`. Test `slacktoday_test.go`, `legacy_test.go`, `approvals_test.go`.

- **Slack today:**
  - `SlackTodayFacts.State` = the built-in's stored state (the file or row the branch's `internal/automations/builtin` slack-today writes; `SlackTodayQueries` on the branch names the source), with `Status` "ok";
  - absent gives "none", unparsable gives "unreadable".
- **Tracks:** `LegacyItem.News`/`Quiet` from `internal/tracks.HasNews`/`IsQuiet` at `now`. The Swift twin `TrackNewsRule` is deleted in Task 12.
- **Ideas:** `LegacyItem.CreatedAt` on every idea item. The daily batch stays on the Mac (per Mac in UserDefaults, branch v1 limit).
- **Approvals:**
  - `Approval.Group` is set by the branch's `NeedsApprovalGroups` tool table (Messages: `send_slack_message`, `add_jira_comment`, `add_linear_comment`; Tracks to create: `create_track`; Targets: `create_target(s)`, `update_target`; Confluence and Jira: `edit_confluence_page`, `connect_jira_board`, `create/update/transition/assign_jira_issue`; Reminders: a reminder; Other: the rest);
  - `Approval.Bulk` = the tool is in `bulkTools`;
  - Needs approval's cards are ordered group by group, each group by its oldest item, items oldest first, native above recipe within a group (APPROVAL-01).

- [ ] **Step 1: Write failing tests:**
  - `TestSlackToday_Status` (none / ok / unreadable);
  - `TestTracks_NewsAndQuietMatchTracksPackage` (reads `internal/tracks/testdata/track_news*.json`);
  - `TestIdeas_CreatedAt`;
  - `TestApprovals_GroupOrder`;
  - `TestApprovals_BulkOnlyAllowlist` (`send_slack_message` never bulk);
  - `TestApprovals_NativeAboveRecipeInGroup`.
- [ ] **Step 2:** Run them. Expected FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run `go test ./internal/inboxfeed ./internal/tracks`. Expected PASS.
- [ ] **Step 5:** Commit.

### Task 8: Bulk writes as `inbox.act` verbs

**Depends on:** Task 6

**Files:** Modify `internal/inboxfeed/act.go`, `sentences.go`, `testdata/inbox_writes.json`. Test `act_test.go`, `writes_cases_test.go`.

**Interfaces — Produces:**

| Verb | Target | Params | Write |
|---|---|---|---|
| `sender_done` | the mail-waiting card `o…` | `key` (address), `ids` (planned) | `db.ResolveOpenInboxItems(ids)` limited to open `email_received` items whose sender key is `key`; answer `{already, status}` + counts in `ActResult.note` "Closed N of M." |
| `older_done` | the waiting-for-me card | `ids` | the same, people items at or before now − 7 d |
| `sender_mute` | the mail-waiting card | `key` | `source_mute` rule `email:<key>`, weight −1.0 (the Desktop's `InboxLearnedRulesQueries.upsertManual`, ported to `db.UpsertSourceMuteTx`) |
| `plan` | the same cards | `key` or none | read-only: `{ids}` for the confirmation's count (the dry runs of `inbox resolve --sender` / `--older-than 7d --people`) |

- Owner gestures: `sender_done`, `older_done` and `sender_mute` are AGENT-07 owner verbs (their CLI twins refuse under agent markers). They take `Origin.Desktop` with the signed-peer check, like `press`.
- From the hub they are `not_permitted` in v1 (phone parity: Task 15 draws no button).
- `plan` is not idempotent-guarded (read).
- The CLI `watchtower inbox resolve` bulk forms stay as they are (scripts, agents refused).

- [ ] **Step 1: Write failing tests:**
  - `TestInboxAct_SenderDoneClosesOnlyPlannedIDs` (a mail from the same sender inserted after `plan` stays open);
  - `TestInboxAct_OlderDoneSkipsReopened`;
  - `TestInboxAct_SenderMuteHidesSenderOnly` (INBOX-05 amendment: `TestInbox05_MutedSenderLeavesMailWaitingOnly` still passes);
  - `TestInboxAct_BulkVerbsRefusedFromHub`;
  - `TestInboxAct_BulkVerbsNeedSignedDesktop`;
  - new `inbox_writes.json` cases run by `TestInboxWritesCases` and the two-connection race.
- [ ] **Step 2:** Run them. Expected FAIL.
- [ ] **Step 3:** Implement, with sentences "Couldn't close this sender's mail: …", "Couldn't close the older items: …", "Couldn't mute this sender: …" (`TestSentences_EveryVerbHasAPhrase`).
- [ ] **Step 4:** Run `go test ./internal/inboxfeed ./internal/db ./internal/tower/...` and `make gen-interface-check`. Expected PASS.
- [ ] **Step 5:** Commit.

### Task 9: Mac list over the feed — rows, sections, order

**Depends on:** Task 3, Task 4

**Files:**
- Modify: `WatchtowerInterface/Sources/WatchtowerInterface/Inbox/InboxMacFolderRows.swift` (sections), `WatchtowerDesktop/Sources/WatchtowerCore/Services/Inbox/InboxTowerEntries.swift`, `InboxFolderListContent.swift`, `ActionStripViewModel.swift`, `SidebarCountsViewModel.swift`
- Restore from the branch (ledger): `InboxRowContent.swift`, `InboxTile.swift`, `InboxListRow.swift`, `InboxFolderContentList.swift`, `InboxToday.swift`
- Test: `WatchtowerInterface/Tests/.../InboxMacFolderRowsSectionsTests.swift`, `WatchtowerDesktop/Tests/Core/InboxTowerEntriesTests.swift`

**Interfaces:**
- Consumes: `Card.Section`, `Card.Mail`, `Card.People`, `Card.SlackToday` (Task 2).
- Produces:
  - `InboxMacFolderRows.sections(_ cards: [Card], folderKind: FolderKind, now: Date, calendar: Calendar) -> [(InboxListSection, [Card])]`, where `InboxListSection` = `.needsYou, .today, .running, .earlier` (titles "Needs you", "Today", "Running", "Earlier") and `dated` resolves by the client's `calendar`;
  - `InboxRowContent` built from `Card` + facts: `InboxTowerEntries.content(_ card: Card, facts:) -> InboxRowContent`, which replaces the branch's `InboxFolderEntries.content`.
- Row texts stay the branch's (`InboxWaitingTexts`, `SlackTodayRow`, `TrackThreadsSummary`), fed from the facts instead of GRDB.

- [ ] **Step 1: Write failing tests:**
  - `testRootSectionsFollowFeedOrder`;
  - `testDatedSectionUsesClientZone` (one card, two calendars);
  - `testOwnerFolderTodayEarlier`;
  - `testMailWaitingRowTextsFromFacts` (preview "1 new today. Most of it comes from 1 sender: clear a sender in one press.", meta "2 open · 100% from 1 sender", neutral pill 1);
  - `testBadgeIsFeedRootCount`.
- [ ] **Step 2:** Run `make interface-test FILTER=InboxMacFolderRowsSectionsTests` and `make test-swift FILTER=InboxTowerEntriesTests`. Expected FAIL.
- [ ] **Step 3:** Implement. Restore the listed views from the branch and point them at the new content. The Earlier line, search (`InboxListFilter`), selection and `defaultEntry` (brief-first, saved selection) keep the branch's behaviour over the feed's ids.
- [ ] **Step 4:** Run the tests above plus `make test-swift FILTER='InboxRouteTests|SidebarCountsViewModelTests|InboxListFilterTests'`. Expected PASS.
- [ ] **Step 5:** Commit.

### Task 10: Ref hooks, the Older fold and Hide Older (fix 1)

**Depends on:** Task 6, Task 9

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Inbox/Folders/InboxRefHooks.swift` (reads `RefFacts` incl. `key`)
- Keep: `DesignKit/Artifacts/ArtifactView.swift` `foldLabel` (from Task 1)
- Restore: `InboxRowButtons.swift`, `InboxRowActionsView.swift`, `InboxRowKeyboard.swift`, `InboxRowKeyboardHost.swift`
- Test: `ArtifactListFoldTests`, `InboxRowActionsTests`, `ArtifactRowHoverTests`

- [ ] **Step 1: Write failing tests:**
  - `testSenderRowShownByFeedFacts` (a `mail_sender` row hides when its `RefFacts.open` is false);
  - `testOlderNoteFoldsAfter` (the `waiting_older` row folds the rows after it; button "Show 2 older", then "Hide Older");
  - `testUnknownRefKindDrawsPlainRow`.
- [ ] **Step 2:** Run `make test-swift FILTER='InboxRefHooksTests|ArtifactListFoldTests'`. Expected FAIL on the first and third.
- [ ] **Step 3:** Implement. Keys J/K/E/R/S/⏎/⌘K and the sender row keys (⏎ open, E Mark All Done…, M mute) as on the branch.
- [ ] **Step 4:** Run `make test-swift FILTER='InboxRefHooksTests|ArtifactListFoldTests|InboxRowActionsTests|ArtifactRowHoverTests|InboxRowKeyboardTests'`. Expected PASS.
- [ ] **Step 5:** Commit.

### Task 11: Waiting for me and Mail waiting panes, the stale line, bulk presses

**Depends on:** Task 5, Task 8, Task 10

**Files:**
- Restore: `InboxPaneHeader.swift` (with `staleNote` from `inbox-pr-fu-fix3` b47365607), `MuteSendersPopover.swift`, `MuteSendersModel.swift`, `InboxBulkPress.swift`, `InboxBulkPressButton.swift`, `InboxBulkCenter.swift`
- Delete: `InboxBulkCLI.swift` (replaced by `inbox.act`; `TracksBulkCLI` stays)
- Modify: `InboxTowerWrites.swift` (the `plan`/`sender_done`/`older_done`/`sender_mute` calls), `InboxWaitingTexts.swift` (`mailStaleNote(_ stale: MailStale) -> String?`)
- Test: `InboxPaneHeaderTests`, `InboxWaitingPaneTests`, `InboxBulkPressTests`

**Interfaces:**
- Consumes: `MailFacts.Stale`, the Task 8 verbs.
- Produces: `InboxWaitingTexts.mailStaleNote(_:)` with the Global Constraints copy, nil for `""` and `.unknown`.

- [ ] **Step 1: Write failing tests:**
  - `testArtifactHeaderDrawsTheStaleNote` (accessibility id `inbox.artifact.staleNote`);
  - `testMailStaleNoteTexts`;
  - `testMarkAllDoneSendsPlannedIDs`;
  - `testPartialRunShowsClosedNofM` ("Closed N of M. <error>");
  - `testMuteSendersPressesSenderMute`.
- [ ] **Step 2:** Run `make test-swift FILTER='InboxPaneHeaderTests|InboxWaitingPaneTests|InboxBulkPressTests'`. Expected FAIL.
- [ ] **Step 3:** Implement. Subtitles from facts (`peoplePaneSubtitle`, `mailPaneSubtitle`).
- [ ] **Step 4:** Run the same command. Expected PASS.
- [ ] **Step 5:** Commit.

### Task 12: Slack today, Track my threads and Idea finder panes

**Depends on:** Task 7, Task 9

**Files:**
- Restore: `SlackTodayPane.swift`, `SlackTodayRow.swift`, `SlackTodaySummary.swift`, `InboxTracksNewsPane.swift`, `TrackThreadsSummary.swift`, `IdeaBatchPane.swift`, `IdeaDailyBatch.swift`, `ViewModels/IdeasViewModel+Batch.swift`, `InboxBuiltinPane.swift`
- Delete: `SlackTodayQueries.swift` (Slack today's state comes from the feed) and `TrackNewsRule.swift` (Go decides news/quiet)
- Test: `SlackTodayRowTests`, `TrackThreadsSummaryTests`, `IdeaDailyBatchTests`, `IdeaBatchPaneTests`

- [ ] **Step 1: Write failing tests:**
  - `testSlackTodayStateFromFacts` (ok / none / unreadable → "Nothing yet today" / "Today's numbers can't be read"; the stale note "This is yesterday's list. Today's starts after the next sync.");
  - `testTracksNewsFromLegacyItems`;
  - `testIdeaBatchCandidatesFromFeedCreatedAt`.
- [ ] **Step 2:** Run `make test-swift FILTER='SlackTodayRowTests|TrackThreadsSummaryTests|IdeaDailyBatchTests|IdeaBatchPaneTests'`. Expected FAIL.
- [ ] **Step 3:** Implement. Writes: Mark All Seen = `inbox.act read` on the card. Stop Tracking Quiet Ones… and Clear Old Ideas… stay Mac-only (the hub refuses them). They keep their branch paths where main still has them (`TracksBulkCLI`); where main removed the Swift write path (`IdeaQueries.dropMany`), they get a Go writer and a screen command in `internal/inboxfeed/screens.go`, next to main's other ideas writes. Restore the IDEA-04 guard `IdeaQueriesTests::testIdeas04_DropManyClearsNeedsReviewAndTouchesOnlyAwaiting` with the same name and assertions, over the new path. If it would have to move to Go, stop and ask the lead. Idea verdicts go through main's `inbox.act ref idea`.
- [ ] **Step 4:** Run the same command. Expected PASS.
- [ ] **Step 5:** Commit.

### Task 13: Needs approval groups and Approve All

**Depends on:** Task 7, Task 9

**Files:**
- Restore: `NeedsApprovalGroups.swift` (rendering only: the grouping comes from `Approval.Group`/`Bulk`), `Views/Inbox/Folders/NeedsApprovalPane.swift`
- Modify: `ActionStripViewModel` `approveAllModel(_:)` / `approveAll(ids:)` over `inbox.act approval approve` per id, with pinned args
- Test: `NeedsApprovalGroupsTests`, `ApproveAllTests`

- [ ] **Step 1: Write failing tests:**
  - `testGroupsFollowFeedOrder`;
  - `testApproveAllOnlyForBulkGroupsWithTwoRows`;
  - `testApproveAllStopsOnArgsChanged` (refusal `args_changed` → `.partial` "Closed N of M. This proposal changed on the Mac — look again before approving.");
  - `testApprovedTrackNotWatchedLine` ("Approved, but N tracks are not watched yet: <reason>").
- [ ] **Step 2:** Run `make test-swift FILTER='NeedsApprovalGroupsTests|ApproveAllTests'`. Expected FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the same command. Expected PASS.
- [ ] **Step 5:** Commit.

### Task 14: Shell, Morning brief pane, shots, Mac docs

**Depends on:** Task 9, Task 10, Task 11, Task 12, Task 13

**Files:**
- Restore and re-point: `InboxDayPane.swift`, `InboxBriefHistory.swift`, `InboxBriefDays.swift`, `InboxBriefLayout.swift`, `BriefMakeTaskModel.swift`, `PanelToggleCommands.swift`, `PanelToggleTarget.swift`, `ActionStripView.swift`, `InboxSplitView.swift`, the rail
- Modify: `WatchtowerDesktop/Tests/DesignShots/DesignShotCatalog.swift` + the branch's `DesignShotFixtures+InboxRedesign*.swift` over a feed fixture (`InboxFeedLoader.showForShots`), adding `inbox-r-mail-waiting-stale`
- Docs:
  - `docs/features/inbox-redesign.md`: a "Port onto the Go feed (2026-11-20, ask #798)" section mapping each Swift rule to its Go home; the v1-limit sentence about Mail waiting's missing failure line is replaced by "no stand-in" only; the stale sweep and IMAP chip limits stay;
  - `docs/features/inbox-core.md`: the new fields and verbs;
  - `docs/features/README.md` summaries;
  - `docs/guide/features/inbox.md`: "If a run fails, the last list stays, marked out of date." within 8192 bytes;
  - inventory changelogs where a guard moved from Swift to Go.

- [ ] **Step 1:** Run `make desktop-shots DESKTOP_SHOTS=/tmp/shots > /tmp/shots.log 2>&1; echo "exit=$?"`. Expected `exit=0`. Look at `inbox-r-*`, `inbox-r-mail-waiting`, `inbox-r-mail-waiting-stale` and the Older fold shot.
- [ ] **Step 2:** Run `make test-swift FILTER='Inbox|ActionStrip|Artifact|NeedsApproval|SlackToday|Idea|Track'` and `go test ./docs/guide`. Expected PASS.
- [ ] **Step 3:** Commit.

### Task 15: Phone — tolerance and v1 parity

**Depends on:** Task 3, Task 5, Task 6

**Files:**
- Modify: `WatchtowerMobile/Sources/Features/Inbox/InboxFolderView.swift` (section headers from `Card.Section`; `dated` → Today/Earlier by the phone's calendar), `InboxRefRow.swift` (`mail_sender`: title + Open on `Link`; `waiting_older`: a plain note row, no fold), `InboxPhoneText.swift` (Mail waiting / Waiting for me subtitles from facts; the stale line, same copy)
- Modify: `WatchtowerMobile/Sources/App/DemoSeed+Inbox.swift` (a Mail waiting card)
- Test: `WatchtowerMobile/Tests/InboxPhoneTextTests.swift`, `InboxTabWiringTests.swift`

Out of v1 on the phone (Mac only, from Task 8's `not_permitted`): Mark All Done, Mute, Approve All, the idea batch, Stop Tracking Quiet Ones.

- [ ] **Step 1: Write failing tests:**
  - `testSectionsFromFeed`;
  - `testMailSenderRowOpensLink`;
  - `testWaitingOlderPlainRow`;
  - `testMailStaleLine`;
  - `testUnknownRefKindPlainRow`.
- [ ] **Step 2:** Run `make mobile-test MOBILE_FILTER='InboxPhoneTextTests|InboxTabWiringTests' > /tmp/m.log 2>&1; echo "exit=$?"`. Expected FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run the same command. Expected `exit=0`. Then `make mobile-shots` for the Inbox tour.
- [ ] **Step 5:** Commit. Update `docs/features/mobile-companion.md`'s Inbox paragraph.

### Task 16: Close — gate and review

**Depends on:** Task 8, Task 14, Task 15

- [ ] **Step 1:** Run `git fetch && git merge origin/main` (if it moved: re-check the migration number per Global Constraints).
- [ ] **Step 2:** Run the gate, each to a log with `echo "exit=$?"`: `make test`, `make test-swift`, `make lint-all`, `make gen-interface-check`, `make mobile-test`, `go test ./cmd/... -run 'Inbox|Tower'`. Expected every `exit=0`.
- [ ] **Step 2b:** Guard sweep (lead, 2026-11-20): every guard test named in `docs/inventory/*.md` exists in the tree and passes. Grep each named test, then run them (Go `-run`, Swift `FILTER`). Any one that is missing or failing blocks the PR.
- [ ] **Step 3:** Run `local-review`. On the final diff into main it runs `debate-review`; triage and fix until the panel converges.
- [ ] **Step 4:** Hand back to the lead: head sha, gate results, review verdict, the PR plan (new PR from `feature/inbox-feed-port` replacing #899, or #899's branch reset). No push and no PR change without the lead's ok.
