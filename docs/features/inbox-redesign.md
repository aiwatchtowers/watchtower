# Inbox redesign

Board #1076 under the inbox builder umbrella #917. Spec `docs/superpowers/specs/2026-11-11-inbox-redesign-design.md` (owner-approved, ask #638; inventory amendments in ask #634), mockup `docs/design/mockups/inbox-redesign/inbox-redesign.html` (sample data), native shots `inbox-r-*` in the DesignShotCatalog. Phase 1 plan `docs/superpowers/plans/2026-11-11-inbox-redesign-phase-1-shell.md`. Builds on [inbox-folders.md](inbox-folders.md) (sub-project B) and [inbox-card-blocks.md](inbox-card-blocks.md) (A). User guide: `docs/guide/features/inbox.md`, `docs/guide/features/briefings.md`, `docs/guide/features/day-plan.md`.

## Phase 1 — the shell (Desktop)

Swift only: no migration, no Go source change, no prompt, no phone change. One shared JSON fixture (`internal/inbox/testdata/from_today.json`) waits for phase 2's Go twin. Pure rules live in WatchtowerCore, state stays on `ActionStripViewModel` (AppState-owned, survives navigation), the views in `Sources/Views/Inbox/` only render. `InboxFolderEntries` stays the single source of entries; sections, rows and groups are built over its output.

### Sidebar

`SidebarDestination.rootItems == [.home, .inbox, .workbench, .automations, .calendar]`: the Inbox takes Targets' place at the root, and Targets moves into FOCUS (`SidebarSection.today.items == [.catchUp, .targets]`) with its own badge (overdue in red, else active).

### Layout

- Three columns in `ActionStripActionsView` for the root, owner folders and Needs approval: the rail (the folder menu), the list (`PaneWidth.inboxListMin` 320 / `inboxListIdeal` 372 / `inboxListMax` 460, Kit `Tokens.swift`) and the reading pane (`PaneWidth.detailMin`, centred at `ReadableColumn.maxLineWidth`, 760). `InboxSplitView` (the legacy lists) uses the same list frame. The error banner stays above all three.
- Rail collapse: View → **Hide Inbox Folders** / **Show Inbox Folders**, ⌥⌘S, remembered in `UserDefaults` `inbox.railHidden` (default shown). The rail shows "Folders" above the owner folders only when one is drawn (`InboxFolderMenuContent.showsFoldersHeading`); its bottom row is **New Artifact…** plus a `folder.badge.plus` icon (**New Folder**).
- ⌥⌘S is one View-menu item (`PanelToggleCommands`, `CommandGroup(after: .sidebar)`) titled by `PanelToggleTarget.resolve`: the workbench's sessions panel when a workbench page has the keys, else the Inbox rail while the Inbox is on screen, else disabled. The Workbench menu keeps **Show Sessions Panel / Hide Sessions Panel** without the key equivalent, so no two menu items share it. `KeyboardShortcutCatalog`'s Inbox area lists it.
- One title: the header row ("Inbox" + `?`) is gone; the window keeps `.navigationTitle("Inbox")` and `.searchable(…, placement: .toolbar, prompt: "Search the Inbox")`. The `?` (reaction cheat sheet, `actionStrip.cheatSheetButton`) sits at the trailing end of every pane header and of Needs approval's header; the empty root keeps its inline cheat sheet.
- `InboxPaneHeader(tile:title:subtitle:actions:)`: the tile at `IconSize.listTile` (30), title `.title3.weight(.semibold)`, a wrapping `.callout` subtitle, trailing actions that never wrap. An artifact's pane: its tile, title, the card's provenance line, **Run Now** (only when its ⋯ offers it), its ⋯ and `?`, over the card drawn with `showsTitleRow: false`. A thread brief: `?` only.

### The list

- A `ScrollView` of `.kitRow` rows (`InboxFolderContentList`), not a `List`: no system selection highlight, no nil selection written when search hides the selected row. Arrow keys move the selection through the drawn rows; the selected row carries the `.isSelected` accessibility trait.
- `InboxRootSections.build(entries:folder:waitingForMeAutomationID:now:calendar:)`. Root: **Needs you** (Waiting for me's artifact, the Messages stand-in, thread briefs applied in the last 24 hours, newest first — `build` re-checks the 24 h; on a root-only tree the approvals and notices follow), **Today** (the Morning brief entry, then artifacts changed today, newest first), **Running** (Track my threads, Idea finder, the other artifacts, newest first). Owner folder: **Today** and **Earlier**, each in incoming order. An empty section is left out.
- The Earlier line (`InboxRootSections.earlierLine`, root only): "Past briefs are inside Morning brief · N this month, M not opened" (", M not opened" dropped at 0), under an "Earlier" heading when the root has no Earlier section; it opens the brief's History (`openBriefHistory()`). "This month" is the last 30 dates including today, so it counts at most 29 past briefs.
- Rows: `InboxFolderListRow { id, content: InboxRowContent, menu }`, built by `InboxFolderEntries.content(_:_:)`, drawn by `InboxListRow` (tile, unread dot, semibold title, two-line preview, one-line meta, trailing time above the pill; the Idea finder's ⋯ an overlay so the height never changes). `InboxTile` tints: brief `Tone.amber`, people waiting / approvals `Tone.warning`, mail `Tone.success`, threads / Slack / owner artifacts the accent, ideas `Tone.status("purple")`. Pill tones: `needsYou` warning, `news` accent, `batch` neutral. `InboxRowTime.label`: `HH:mm` today, "yesterday", `EEE` for 2–6 days, `d MMM` this year, `d MMM yyyy` before. `InboxRowText.preview` strips markdown markers, caps at 240.

| Entry | kind | preview | meta | pill |
|---|---|---|---|---|
| Waiting for me / Messages stand-in | `peopleWaiting` | newest open item from today, `<who> <where>: “<snippet>”` + " · and N more today"; none today → the newest open one; none → "Nothing waits on you" | "N older" | people waiting today, `needsYou` |
| Morning brief (today) | `brief` | `InboxBriefLayout.lead`; placeholder → "Not written yet" | `EEE d MMM` | none |
| Track my threads | `threads` | the two newest unread tracks' titles | "updated <ago>" | unread tracks, `news` |
| Idea finder | `ideas` | "N ideas to judge. Top one: “…”" | "updated <ago>" | ideas awaiting a verdict, `batch` |
| Thread brief | `threads` | — | "Thread brief" | none, never unread |
| Owner artifact | `artifact` (its folder's icon) | `InboxRowText.preview(body)` | "Your automation · updated <ago>" (living) / "· run #N" | rows waiting, `needsYou` |

- Search: `ActionStripViewModel.listQuery`, one value for every folder, kept across navigation. `InboxListFilter.apply` matches title + preview, case- and diacritic-insensitive; empty sections drop, the Earlier line hides, and with no row left the list says "No matches for “<query>”". Filtering never clears the selection.

### Counts and badge

- "Today" = since local midnight: an item is from today when `MAX(created_at, mentioned_at)` (empty `mentioned_at` = none) is at or after `Calendar.startOfDay(for: now)`. One rule, `InboxToday` (`sinceUTC(now:calendar:)`, `isFromToday`, `nextMidnight(after:calendar:)`), pinned by `internal/inbox/testdata/from_today.json` (midnight edges, mentioned today, DST days, UTC vs local; read by `InboxTodayTests` and the SQL parity test `InboxPeopleTodayTests`).
- Terms on `InboxFolderMenuSnapshot`: `approvalsCount` (Needs approval's open approvals: `awaitingOwnerCount` + due reminders + built-in upgrade notices, as before), `peopleWaitingToday` (`InboxQueries.openMessageCount` since midnight; 0 while Waiting for me is turned off), `badge = approvalsCount + peopleWaitingToday`. `ActionStripViewModel.badgeCount` returns it; `InboxFolderCounts.badge` is gone. Mail (from phase 2), tracks, ideas, briefs, thread briefs and every artifact never enter the badge.
- The root's rail count: people waiting today + 1 while today's brief is unread + the root's other artifacts (`InboxFolderCounts.artifactCount`); Waiting for me's own artifact is `uncounted` (its people are the first term). Owner folders keep their own counts.
- Midnight: "today" changes with no database write, so `SidebarCountsViewModel` recounts at `nextMidnight + 1 s` and on `NSCalendarDayChanged`, `NSSystemTimeZoneDidChange` and `NSWorkspace.didWakeNotification`, with `Calendar.autoupdatingCurrent`; the Inbox view model refreshes on the same three.

### Selection

- `UserDefaults` `inbox.entry.<folderID>` (`entryKey(_:)`), written only by the owner's click (`selectEntry`).
- `InboxFolderEntries.defaultEntry(entries:saved:folder:today:)`: the saved entry when listed and not a legacy list; else in the root today's brief (`day:<today>`); else the first non-legacy entry; else nil. It runs on the first read, on a folder pick, on a route with no entry and when the selected brief's day rolled over. A remembered legacy-list entry (Track my threads, Idea finder, Messages) is not restored: the Inbox opens today's brief, so the pane is never empty.
- Read marks (STRIP-02): a default pick inside `refresh()` writes nothing. The owner's arrival (`ownerArrived()`, from `ActionStripView.onAppear` and `selectFolder`) marks the shown brief or artifact read when unread. A route into the Inbox (Home's link, a notification) writes the read mark of the card it opens, and the arrival yields to an in-flight route. A poll, a refresh and the midnight rollover write nothing.

### Morning brief

- One row: `InboxListBuilder.rootDays` lists today's card only (or today's placeholder while the owner is known). Past days live inside it; a past brief is never listed and nothing marks it read for the owner.
- `InboxBriefDays.history` = the days of the last 30 dates (today included) with a briefing or a plan, newest first; `step(from:_:in:today:)` moves to the next listed date, never past today. The feed's first page (`ActionStripViewModel.dayPage`, 30) holds every card of that window, so History and the Earlier line are complete (`testFirstPageCoversThirtyDays`).
- View model: `briefDate` (nil = today), `briefDay`, `briefHistoryShown`, `showBriefDay(_:)`, `stepBrief(_:)`, `openBriefHistory()`. Stepping or a History pick is the owner's pick: it marks that day's briefing read through `select(.day(date))`. A `.day(date)` route calls `showBriefDay`; a date with no card opens today's brief.
- Pane (`InboxDayPane`): `InboxPaneHeader` "Morning brief", subtitle "<EEEE, d MMMM> · written HH:mm" (local time of the briefing's `created_at`; the day alone with no briefing), actions: the stepper ‹ `EEE d MMM` › (newer disabled on today, older disabled when nothing is older), **History** (a popover over `InboxBriefHistory`, unread days dotted), **Discuss in Chat** (not on the placeholder), `?`. Body in the mockup's order (`InboxBriefLayout`): **Start here** first (attention items 0..<3 with their actions). There is no separate lead paragraph: the lead (`InboxBriefLayout.lead`, the first attention item's text, else the first your-day item's — the briefing has no separate summary sentence) is always an item drawn in Start here or Your day, so it is only the list row's preview. Then **Your day** (`InboxDayPlanBlock` plus the your-day items without their own title; a "N conflicts" `Chip` in `Tone.error` when the plan has conflicts, N = overlapping time-block pairs with a floor of 1, since a clash with a calendar event alone has no pair), **Waiting on you** (the three newest open messages as plain rows with no action, then "All in Waiting for me"), **Moved overnight** (up to three unread tracks, newest event first, then "Track my threads"), then **More for today** (attention items from 3 on), What happened, Team pulse, Coaching. Waiting on you and Moved overnight draw on today's brief only, each left out when empty; a link is hidden when its entry is not listed. `BriefingSectionsView(parts:)` keeps its old order as the default. Make buttons and today's placeholder are unchanged.

### Needs approval

- `NeedsApprovalGroups.build`: groups Messages (`send_slack_message`, `add_jira_comment`, `add_linear_comment`), Tracks to create, Targets, Confluence and Jira, Reminders, Other (connector calls, Linear writes, `save_automation`, any future tool), ordered by their oldest item, items oldest first; native cards stay above the recipe's cards inside each group (APPROVAL-01 Observable). List sections: "Built-in updates" first, one per group (title + count), "Approved, still running" last.
- **Approve All N…** is an allowlist (`NeedsApprovalGroups.bulkTools`: `create_track`, `create_target(s)`, `update_target`, `edit_confluence_page`, `connect_jira_board`, `create/update/transition/assign_jira_issue` — none sends text to a person). `approveAllIDs` is non-nil only for Tracks to create, Targets or Confluence and Jira, one tool from the list, and at least two rows `NeedsApprovalGroups.isBulkApprovable` accepts: pending, not applied by a chat session, and one its own card would approve (`AgentActionApproval.canApproveOnCard`, the one rule the card's `canApprove` calls too — an `edit_confluence_page` whose args hold no readable `changes` list is left out, as its card refuses Approve). Such a group is one list row (id `group:<raw>`: "Create N tracks", "N target changes", "N Confluence and Jira changes"), which scrolls the stack to its header and, picked, is restored as the folder's entry while it is drawn; the button sits on that header in the stack.
- `approveAllModel(_:)` (one `InboxBulkPressModel` per group, kept on the view model so a run survives leaving the Inbox) → `approveAll(ids:)`: the plan reads first and throws ("The Inbox could not be read: …") when no read landed or the read failed, then pins each row's args as the owner saw them (`approveAllPlan`; a run's pins go when it ends); one refresh, then each id through `AgentActionFeed.approve` with those planned args, so a row whose args changed since is refused by Go and stops the run. Skipped (counted, the run goes on): a row closed, failed or changed into one `isBulkApprovable` refuses meanwhile, and an approve whose state moved (exit 3, `AgentActionFeed.stateMovedRows`). An approved `create_track` whose `tracks start` failed (`AgentActionFeed.startVerb`) counts as done; since an applied row leaves Needs approval, the run then puts "Approved, but N tracks are not watched yet: <first reason>" on the Inbox's error line above the columns. The first error stops the run and returns `.partial` ("Closed N of M. <error>"); it selects the failed card only while Needs approval (the root on a tree without it) is the selected folder. The group header keeps the finished press's result line (and **Try Again** after a partial or failed run) while the group is listed, even once it no longer offers the button; a read that lists other approvable ids for the group (any row `isBulkApprovable` accepts, without the two-row rule), or drops it, puts the press back to idle.

### Shared components for phases 2–3

`InboxToday` (+ fixture), `InboxBulkPlan` / `InboxBulkResult` / `InboxBulkPressModel` / `InboxBulkPressButton` (`.kitSecondary`, a confirmation for N > 0 only, `resultLine`, **Try Again** after a partial or failed run; nothing retries by itself), `InboxListRow` / `InboxRowContent` / `InboxTile`, `InboxRootSections`, `InboxPaneHeader`.

### Phase 1 alone (interim)

Waiting for me still holds people and mail, so "people waiting today" — in the badge, the root count and the row's pill — counts every open Waiting for me item from today, mail included; there is no Mail waiting row. The guide says so as it ships ("people and mail waiting on you since midnight"); phase 2 edits it. Track my threads and Idea finder rows show today's numbers (unread tracks, ideas to judge) in the new layout. Phase 2 narrows the people term; phase 3 changes the tracks and ideas rules.

### v1 limits

- Search filters the loaded rows of the folder list only: not the legacy lists (Track my threads, Idea finder, Messages) and not Needs approval's stack.
- A manual wall-clock change (no midnight, wake, day or time-zone signal) is picked up at the next such signal.
- Messages still opens today's legacy list in the list column (Track my threads and Idea finder open their own panes since phase 3).
- ⌥⌘S is one View-menu item shared with the Workbench's sessions panel.
- The reading pane's width is no longer remembered across launches (the old `inbox.readingPaneWidth`); the rail and the list open at their ideal widths.
- Not built from the mockup: the list header's **All / Unread** switch and its "updated N min ago" line (rows do print "updated <ago>"), Needs approval's **By kind / Oldest** switch.

### Inventory

STRIP badge amendment (`docs/inventory/reaction-commands.md` changelog, approved in ask #634): the badge is approvals + people waiting today; the C1 guard is renamed `InboxFeedQueriesTests::testBadgeCountsApprovalsAndPeopleWaitingToday`, the STRIP-02 guard `testOpeningWritesOnlyReadAt` changes only its badge expectation. APPROVAL-01 note (`docs/inventory/inbox-folders.md` changelog): grouped list and Approve All, no semantic change; supporting `NeedsApprovalGroupsTests`, `ActionStripApproveAllTests::testEveryOpenApprovalStaysListed`.

## Phase 3 — Track my threads and Idea finder

Board #1076, spec sections "Track my threads (phase 3)" and "Idea finder (phase 3)" (ask #638). Plan `docs/superpowers/plans/2026-11-11-inbox-redesign-phase-3-tracks-ideas.md`. The root's two entries no longer open legacy lists: `ActionStripActionsView.readingPane` draws `InboxTracksNewsPane` for `.legacyTracks` and `IdeaBatchPane` for `.legacyIdeas` over their producers' own rows. Selecting either entry writes nothing (STRIP-02). No migration.

### The "with news" rule and its twins

A track has news when `has_updates` is set, or when it was never read (`read_at` NULL or "") and its last event — the later of `updated_at` and its newest `track_events.created_at` — is within 72 h of now (inclusive; a future event counts; an unknown last event is never news). Quiet = no news and the last event at or before now − 30 × 24 h. Go `internal/tracks/news.go` (`HasNews`, `IsQuiet`, `QuietTrackIDs`) and Swift `TrackNewsRule` read the same cases from `internal/tracks/testdata/track_news.json` (`TrackNewsRuleTests`). `TrackThreadsSummary` builds the row (pill = news count, preview = the first two news lines, meta "N quiet threads folded") and the pane: news newest first, five shown then "N more with news", the reason chip in precedence order **reply to you** (`ball_on` = the assignee, raw ids compared) > **decision** > **mention** (Slack mention markup of the assignee in the newest source ref) > **attachment** (a `media_items` image on the newest Slack ref, or on the newest mail event), the quiet note.

A row opens the thread in place (`openNewsTrack`) under `InboxTrackBackBar`, over the same `InboxTrackPane`; Done and Stop watching go back to the list once written; a read that no longer lists the track closes it. **All Threads** opens the old list (`openLegacy(.tracks)`), which keeps the Stopped fold and Restore.

### Stop Tracking Quiet Ones…

`quietTracksPress` (`InboxBulkPressModel`, on the view model so a run survives navigation) plans with `watchtower tracks dismiss --quiet-days 30 --dry-run --json` (last stdout line `{"count":N,"ids":[…]}`) and applies with `tracks dismiss --ids ID,… --json` (`{"dismissed":N,"skipped":N,"ids":[…]}`; on a write error exit 1 and `{"dismissed":N,"of":M,"error":"…"}`) through `TracksBulkCLI`. `--quiet-days` requires `--dry-run`; `--ids` writes only `dismissed_at` on each listed track still active and is refused under an agent marker. A failed call re-reads the ids' `dismissed_at` and reports `.partial` when some did stop. TRACKS-07 note in `docs/inventory/tracks.md`.

### The daily idea batch

`IdeaDailyBatch` (WatchtowerCore): candidates are ideas awaiting a verdict created within the last 30 × 24 h, oldest `created_at` first; the batch is the first `ideas.dailyBatch` (default 13; a missing, non-integer or < 1 value is 13) of them, fixed per local day in UserDefaults `ideas.batch.date` + `ideas.batch.ids`. **Next N** (`takeNextIdeaBatch`) replaces it with the first N candidates now. Every id handed out today, across Next, is kept in `ideas.batch.dayIDs` (reset with the date). `IdeaBatchState` gives the row (pill = still to judge, preview, meta "N in the backlog · N older than 30 days"), the pane's progress and "Kept today": the ideas of `ideas.batch.dayIDs` now `active`, newest `updated_at` first (`updated_at` alone is no verdict time: a new mention bumps it).

`IdeaBatchPane` shows one card (chip with kind, source and date, title, essence, the two newest quotes through `IdeaBatchCardFacts.read`), keys K / D / L / T, and writes through `IdeasViewModel.press(_:on:)` under the idea's verdict key (`InboxIdeaPane.writeKey`), so one card takes one verdict: **Keep** → `active`, **Drop** → `rejected`, **Later** → `not_now` with no date, **Make a Target…** → the converted target, which the Inbox opens. Each clears the review flag (IDEA-04). The caller re-reads after every press. **Backlog · N** opens the old ideas list.

### Clear Old Ideas…

On the Backlog's header while `olderCount > 0`: `oldIdeasPress` plans by reading the ideas awaiting a verdict whose `created_at` is older than 30 days, confirms "Clear N Old Ideas" ("Clear 1 Old Idea"), and applies `IdeaQueries.dropMany(ids:)` in one GRDB write: `dropped` with the review flag cleared, only on ids still awaiting a verdict (the rest count as skipped). `dropped` keeps them apart from the owner's **Later**; **Activate** brings one back and a new mention resurfaces it. IDEA-04 note in `docs/inventory/ideas.md`.

### v1 limits

- A bulk-stopped custom track keeps its watch recipe enabled: per the approved TRACKS-07 note the bulk write is `dismissed_at` only. The slot's `Due` gate skips a dismissed track, so the recipe runs no scan and no model call, and Restore resumes it.
- The batch is per Mac in UserDefaults, like `inbox.folder`: each Mac has its own database; the phone is out of scope.
- `ideas.dailyBatch` has no setting in the app.
- The news row's latest line makes user mentions, labelled channel links and links readable; special mentions (`<!here>`, `<!channel>`, user groups `<!subteam^…>`) and a channel link without a label (`<#C…>`) stay as stored.
- Not in the mockup, kept for the owner's look: the back bar over a thread (`inbox-r-threads-detail`), **All Threads** (`inbox-r-threads`), **Clear Old Ideas…** (`inbox-r-ideas-backlog`).

## Phase 4 — mail closes on reply (Gmail)

Board #1076, ask #634 (2026-11-11). A Gmail `email_received` item resolves (`User replied`) once the owner replies in its thread, so mail behaves like Slack, Jira, Linear and calendar items (INBOX-02). Sent mail is ordinary mail: the sync stores it like any other message, and each reader of `gmail_messages` decides whether the owner's own rows count.

### Listing scope

- `internal/gmail/sync.go`: `listScope = "{in:inbox in:sent}"` is the query of both `Sync` (`after:<watermark>`, or `newer_than:<gmail.initial_history_days>d` on a first sync) and `FetchRange` (history backfill, `after:… before:…`). Noise labels (Promotions, Social) are skipped as before; the per-cycle cap, the oldest-first order and the watermark rules are unchanged, so sent rows ride the same watermark as received ones.
- `internal/gmail/client.go` `messagePermalink`: a message labelled `SENT` and not `INBOX` links to `#sent/<id>`, everything else to `#inbox/<id>`.
- The daily deletion diff (`deletions.go`) lists every message after the oldest stored one outside trash and spam, so sent rows are diffed like received ones (SRCDEL-01); the PURGE-02 gmail step deletes by `account_id` and takes them too.

### Sent catch-up

An account that synced before this release has its sent mail only from the release on. Migration 00188 adds `google_accounts.gmail_sent_catchup_at` (`''` = not yet, else RFC 3339 UTC).

- `Syncer.CatchUpSent(ctx, now)` (`internal/gmail/sent_catchup.go`) lists `in:sent after:<now − gmail.initial_history_days>` once per account and stores each message with its own date as `synced_at` (`backfillSyncedAt`), so the inbox detector never sees the rows as new. It writes no watermark and no auth state.
- No-op when the stamp is set, or when the account has not synced yet (watermark 0): a first `Sync` lists sent mail itself and stamps at its listing time.
- `phaseGmailSync` (`internal/daemon/daemon.go`) runs it after a successful `Sync`, outside `observePhase`, so catch-up rows are never `gmail.new_messages` events.
- Failures: a 404 on one message skips it; any other error stops the pass unstamped and the next cycle retries (a failed listing never counts). A transient error (Gmail 429/5xx and rate-limit 403 via `StatusError.Transient`, a network or `*url.Error`, a cancelled or expired context, `io.ErrUnexpectedEOF`, `ErrAuthRevoked`) retries without limit; after 3 passes in one process that failed with a non-transient error (`sentCatchUpMaxAttempts`) the pass stamps anyway and logs that it gave up.

### The owner-sent predicate

`db.GmailOwnSent(labelsJSON, fromEmail, accountEmail)` (`internal/db/gmail_sent.go`): the row's labels hold `"SENT"` (quoted, so a user label containing SENT never counts), or its sender equals the account's own address (trimmed, case-insensitive). A "Send mail as" alias carries `SENT`. `db.GmailOwnSentSQL(msg, acct)` is the SQL twin over a `gmail_messages` alias and its `google_accounts` alias; `TestGmailOwnSentSQL_MatchesGo` pins that both decide every case alike.

### Readers by side

The rule: a reader that treats a row as something that happened to the owner skips the owner's own sent rows; a reader that treats a row as knowledge keeps them. `TestInbox02_EveryGmailReaderHasASide` (`internal/inbox/gmail_readers_test.go`) pins every non-test Go file under `internal` and `cmd` that names `gmail_messages` to a side; a new file fails it until classified.

| Side | File | Readers |
|---|---|---|
| skip | `internal/inbox/gmail_detector.go` | `detectGmailAccount` (via `GmailMessagesSyncedAfter`): no item from the owner's own mail |
| skip | `internal/db/automation_event_sources.go` | `MailNewsFloor`, `CountMailAfter` (`gmail.new_messages`) |
| skip | `internal/memory/seed.go` | `seedGmailSenders` (correspondents) |
| answer | `internal/db/gmail_sent.go` | `GmailItemsAnsweredByOwner` (reads only the owner's sent rows) |
| keep | `internal/kb/source_mail.go` | `gmailSource.Changed/Keys/Build` |
| keep | `internal/kb/media.go` | media parent key lookup |
| keep | `internal/doclinks/linkscan/scan.go` | `gmailScanQuery` |
| keep | `internal/db/memory.go` | `GmailMessageSender`, `GmailMessageExists`, `ListGmailThreadsForExtract` (memory extraction and ideas email digests) |
| keep | `internal/memory/gmail_extract.go`, `internal/memory/provenance.go` | comments over the `internal/db/memory.go` readers |
| keep | `internal/db/emails_read.go` | `ListLocalEmails`, `GetLocalEmail` (`list_emails`/`get_email`, `sent` key) |
| keep | `internal/tools/emails.go` | `list_emails`/`get_email` tool texts naming the table (reads through `internal/db/emails_read.go`) |
| lifecycle | `internal/db/gmail.go` | `upsertGmailMessage` (writer), `GmailMessagesSyncedAfter` (detector feed), `GmailStoredIDs` + `DeleteGmailMessages` (SRCDEL), `ClearGmailData` |
| lifecycle | `internal/db/account_purge_steps.go` | PURGE-02 gmail step (`account_id = ?`) |
| lifecycle | `internal/db/google_accounts.go` | `DeleteGoogleAccount` cascade (comment) |
| lifecycle | `cmd/gmail.go` | clear confirmation row count |
| lifecycle | `cmd/google_legacy.go` | comment only |

`list_emails`/`get_email` mark the owner's own mail with the `sent` key (an IMAP row only when its sender is the mailbox's own address). Readers that reach the rows only through those tools are outside the guard's reach and are checked by hand: the `new-mail-summary` template and the `create-automation` skill's mail examples skip `sent` rows. The Gmail sync's media "owner first" flag uses `db.GmailOwnSent` too. Not readers of `gmail_messages`: track updates, people cards, the Desktop, Kit and phone (no Swift reads the table), the briefing, day plan and Catch-Up (they read `inbox_items` and `stream_digests`).

### The mail branch

`Pipeline.autoResolveGmail` (`internal/inbox/pipeline.go`) is the last check of `autoResolveByRules`, after Slack, Jira, Linear and Calendar. It resolves each id from `db.GmailItemsAnsweredByOwner` with `User replied`; errors are logged and never detector errors, and it never touches the inbox watermark (INBOX-09).

`GmailItemsAnsweredByOwner` reads every pending, unarchived `email_received` item whose `channel_id` parses as a Gmail one (`ParseGmailChannelID`; IMAP items are skipped), then the newest owner-sent `internal_date` in the same thread and account. Date rule: the item resolves when that reply is strictly after the received message's `internal_date` (the item's `message_ts`); when the received row is gone or its date does not parse, the item's `created_at` stands in, and an item with neither date is left alone. Dates are compared in Go as RFC 3339. `email_cc` items are not touched and still archive on their own.

### INBOX-02 amendment

`docs/inventory/inbox-pulse.md` INBOX-02 now covers Gmail mail (approved in ask #634) and names IMAP and Outlook as not covered. Guards: `TestInbox02_AutoResolveGmailOnOwnerReply` and `TestInbox02_EveryGmailReaderHasASide`.

### v1 limits

- IMAP and Outlook mail are not covered: no Sent folder sync and no thread headers, so those items archive on their own as before (14 days To, 7 days Cc).
- For an account connected before this release, sent mail older than the catch-up window (`gmail.initial_history_days`, 7 by default) is not fetched: the history backfill already done does not re-run.
- The ideas and memory floors do not re-mine the catch-up rows: they are dated in the past, below floors that already moved on.
- Any owner message in the thread newer than the received one closes the item: a forward or a note to a colleague in the same thread counts too.
- The sent catch-up is one pass per cycle with no per-pass cap and no resume: a pass cut by a cycle cancel restarts and re-fetches. A one-time cost, like `FetchRange`.
- Sent rows also feed the ideas email pre-digests (`ListGmailThreadsForExtract`), so ideas mining spends more AI on mail (owner decision 8: the owner's words are evidence).
- Installed copies of the "New mail summary" template made before this release still sum up sent mail: they are confirmed by hash (AUTO-06) and are not upgraded. Reinstall from the gallery to get the skip.

## Phase 5 — Slack today

Board #1076, asks #634/#638/#653 (2026-11-11). Plan `docs/superpowers/plans/2026-11-11-inbox-redesign-phase-5-slack-today.md`. The built-in `slack-today` sums up today's Slack messages (member channels, 1:1 DMs and group DMs, except those muted for AI) into one living artifact; the Go side — the raw window `slack.window`, the gate, the recipe, its state v1 and the v1 limits — is in [built-in-automations.md](built-in-automations.md#slack-today-inbox-redesign-phase-5-2026-11-11). The Desktop draws the row and the pane from the built-in's state, never from the card's text, so a quiet message never marks the card unread (call 5 of the plan).

### Row

- `SlackTodayQueries.read` (the built-in's automation id and `SlackTodaySummary` of its state) rides in the Inbox's one read (`InboxFolderMenuSnapshot.slackToday`); `InboxFolderEntries.isSlackToday(card, snapshot)` picks the artifact by its automation id.
- `InboxRootSections.build(…, slackTodayAutomationID:)` puts it in **Today** right after the Morning brief, whatever its `changed_at`. Its unread card counts in the root's rail count as any other artifact; never in the badge.
- `SlackTodayRow.content`: kind `slackToday` (tile `number`, the accent), title "Slack today"; today's state: the top two lines (label rank, then newest) as `#<channel> — <text>`, else "Nothing for you yet today"; meta "Built in · today · N messages"; pill = conversations with news, `batch` tone. Another day's state or none: "Nothing yet today" under "Built in". `#` only for channels (`SlackTodaySummary.heading`, the recipe's `heading` twin).

### Pane

- `SlackTodayPane` (via `InboxReadingPane.slackToday(_:)`): `InboxPaneHeader` with subtitle "Today · N messages in K conversations · M with news for you" (`SlackTodayPaneText.subtitle`; "Nothing yet today" for another day), **Mark All Seen**, **Run Now** (when the ⋯ offers it), the ⋯ and `?`; then the card drawn without its title row.
- Stale note "This is yesterday's list. Today's starts after the next sync." only when the card was written before local midnight **and** the state is not today's: another day's, none or unreadable (`SlackTodayRow.staleNote`, the card's date deciding); a card written today over an older state is today's empty card (a skipped window after midnight writes no state).
- Under the card, from today's state only: the folded line "N conversations with nothing for you · M messages" (`quietLine`, folded ones counted); open, the quiet conversations busiest first as "#name · N messages", then "and N more conversations" for `quiet_rest`.

### Mark All Seen

`ActionStripViewModel.markOutputSeen(id:)` writes `read_at` at the content hash the list drew (`markOutputOpened`), then re-reads; never optimistic, so a card rewritten under the view stays unread and the read shows the new version. The pane's button is enabled while the drawn version is unread; the row's context menu starts with **Mark All Seen** then. Opening the card marks it read as before; the button is for a card that turned unread again while open.

### Shots

`inbox-r-slack-today-row`, `-pane`, `-stale`, `-quiet-open` (`DesignShotFixtures+InboxRedesignSlackToday.swift`).

### v1 limits

- The per-conversation counts, the header numbers and the quiet line come from the state, so the phone (sub-project F) will not show them from the card alone.
- The pane shows no per-channel "N new" in the headings (the mockup does): with that count on the card every quiet message would mark the card unread.
