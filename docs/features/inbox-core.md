# Inbox core — one Inbox implementation in Go (`internal/inboxfeed`)

Stage 1 of #1170 (spec `docs/superpowers/specs/2026-11-15-mobile-inbox-design.md` §4). The Inbox's list, counts and card texts are built once, in Go, and both clients draw the result: the Mac over the daemon socket (`<workspace>/tower.sock`), the iPhone through the hub. This note covers the feed (`inbox.feed`, `inbox.watch`). The Needs approval cards, ref facts, button states and legacy sections land in the next part, and the writes (`inbox.act`) after it.

## The feed

`inboxfeed.Build(ctx, d, Options{Folder, Limit, Clip, Now})` reads the Inbox in one `BeginTx(ReadOnly: true)` transaction, so every count and every card comes from one snapshot. It writes nothing (`TestBuild_WritesNothing` checks `data_version` on a second handle and `total_changes`).

`api.Feed{v, built_at, folders[], cards[], more}` (`internal/tower/api/inbox.go`, `FeedVersion = 1`):

- **Folders** come in pre-order: the root, then each folder followed by its children, by `position` and then `id`. Each folder carries `{id, kind (root|approvals|owner), slug, title, icon, parent_id, position, hidden, count, waiting}`.
  - `hidden` is the effective value, not the row's own flag: it is set when the folder or one of its ancestors is hidden. Such a folder leaves the menu and the badge, but it is still sent, because the Mac's **Show Hidden Folders** draws it. Which ancestor hid it is found by walking `parent_id`.
  - `count` is the folder's own count, not its children's (`InboxFolderCounts`):
    - an artifact with no row ref counts 1 while it is unread;
    - an artifact with row refs counts its rows whose record waits on the owner, whatever its read state;
    - the legacy terms are added: in Needs approval, the actions that wait on the owner, the due reminders and the failed built-in moves; in the root, the ideas awaiting a verdict, the unread open messages while Messages stands in for Waiting for me, and 1 while the latest briefing is unread.
  - `waiting` is 0 until the next part ports it.
- **Cards** come in list order: folders in pre-order, and each folder's entries in its own order (`InboxFolderEntries.build`):
  - Needs approval lists the failed built-in moves (`notice` cards); the approvals follow in the next part.
  - The root lists Waiting for me first while it has rows that wait (`pinned`), then its artifacts with the newest change first.
  - An owner folder lists its artifacts with the newest change first.
  - The artifacts of the `needs-approval` built-in are left out of every folder: they are the approvals' cards. Waiting for me's artifacts are left out while the Messages entry stands in for it or while it is turned off.
- **Stamps** are UTC (RFC 3339, whole seconds). A living card's stamp is its last write (`written_at`); any other card's stamp is its creation. `source_line` carries the source only, for example the automation's name. The time ("· 10:00", "· Updated 10 min ago") and the Today/Earlier grouping belong to the screen models, which use the client's own time zone.
- **Card texts** (`texts.go`):
  - `title` is the card's title, or the automation's name when the card has none.
  - `preview` is the body's markdown as plain text on one line, clipped to 140 characters with "…" (`InboxCardTexts.preview`, through goldmark with the GFM extensions). As in cmark-gfm's text nodes, backslash escapes are resolved, and so are entity and numeric references, in one pass. Characters are grapheme clusters (`rivo/uniseg`), as Swift counts them, so an emoji sequence counts once and is never cut.
  - `priority` is high, medium or low; any other value reads as medium.
  - A notice reads "Couldn't move <built-in> to Automations".
  - `unread` is "never opened" for a card without row refs, and "a row waits" for a card with them.
- **Blocks:** `blocks` holds the stored document, or `""` for a markdown card. A document past `MaxBlocksBytes` (128 KB) is sent as a `notice` card whose body and preview are `TooLargeSentence`; it keeps its `content_hash`. The check uses the stored `blocks_json` length, which the writers store canonical. Such a card still counts its waiting rows and shows unread as the artifact would.
- **Actions and ref facts** are sent as empty lists, never `null`, until the next part fills them.

## Card ids

| Kind | Id | Helper |
|---|---|---|
| artifact | `o<automation_outputs.id>` | `OutputCardID` |
| native approval | `a<agent_actions.id>` | `ActionCardID` |
| due reminder | `r<reminders.id>` | `ReminderCardID` |
| failed built-in move | `n<builtin_migrations rowid>` (the upsert keeps the rowid) | `NoticeCardID` |
| Morning brief day | `brief-<yyyy-MM-dd>` | `BriefCardID` |
| legacy lists | `tracks`, `ideas`, `thread-briefs`, `messages` | constants |

`ParseCardID` reads an id back into its kind, its number or its date. It refuses a malformed id, such as `o0`, `o01` or `brief-2026-13-01`.

## Options

- `Folder` narrows the cards to one folder. Every folder and its count are still sent.
- `Limit` (300 on the phone, none on the Mac) keeps Needs approval's cards first, then the pinned cards, then the rest by `stamp`, newest first. On a tree without Needs approval, the approval entries the root lists (`a…`, `r…`, `n…`) come first instead. The kept cards stay in list order. `more` counts the cut cards per folder.
- `Clip` clips each `body` to `ClipBytes` (16 KB) on a rune boundary and sets `body_clipped`.
- `DisabledFeatures` are the feature ids the config has off: the Mac's own feature list (`features list --json` reports them as `disabled`). Here only attention detection (`secretary-inbox`, config key `inbox.enabled`) matters. When it is off, Waiting for me is turned off whatever its row says, as `InboxFolderQueries.waitingForMe(featureOn:)` has it: its artifacts are not shown and nothing counts for it, the Messages stand-in included. The owner's off wins over a stop by the daemon.
- `Now` is the moment the feed is read. Its location is used for one date-only value, an idea's "not now" day, which the owner's zone wrote.

## Commands

`inboxfeed.Register(r, disabledFeatures)` registers two commands in `commands.RegisterAll`. `disabledFeatures` is `commands.Deps.DisabledFeatures`, which the daemon fills (`cmd/sync.go` `towerDisabledFeatures`). It re-reads `config.yaml` (`config.Load(flagConfig)` → `features.DisabledIDs`) at each `inbox.feed` call, because the owner flips features while the daemon runs (`watchtower features enable|disable`, or the Desktop's Feature Manager through that CLI). A config that cannot be read is logged, and the daemon's start config answers instead. A zero `Deps` (the generator, tests) means nothing is off. The commands:

- `inbox.feed`: `Spec{Read: true, ChangeTables}`; `api.FeedRequest` → `api.Feed`.
- `inbox.watch`: `Spec{Watch: true, ChangeTables}`; `api.WatchRequest` → `api.WatchResponse`. It answers ok, then the socket streams `ChangedEvent` frames.

`ChangeTables` lists every table the feed reads, `jira_issues` included (`db.OpenInboxClause` drops an open Jira item whose issue was deleted). `TestChangeTables_CoverEveryTableBuildReads` checks it against the package's SQL. `internal/tower/api/inbox.go` also holds the act types (`ActRequest`, `ActParams`, `ActResult` and their enums), which the writes part registers.

## What moved from Swift

| Swift today | Go |
|---|---|
| `InboxFolderEntries.build`/`row`, `InboxListBuilder`, the list and counts part of `ActionStripViewModel` (`legacyCounts`) | `Build`, `cards.go`, `counts.go` |
| `InboxFolderCounts` (`counts`, `artifactCount`) | `counts.go`. `badge` becomes the screen models' sum of `waiting` |
| `InboxFolderQueries.tree`/`artifactsByFolder`/`waitingForMe`, `InboxRef.refs`, the waits half of `InboxRefState.read` | `folders.go`, `counts.go` |
| `InboxCardTexts` (`preview`; `sourceLine`'s source part), `InboxCardSubject` (title, priority), `BuiltinUpgradeNotice` (title) | `texts.go` |
| `SaveAutomationProposalSummary` with `AutomationTriggerText`/`CronText` and `AutomationCardPresentation.permissionLine` | `SummarizeSaveAutomation`, `PermissionLine` (`savesummary.go`); the approval cards use them in the next part |

These stay on the Mac:

- `InboxCardTexts.preview`, which `ChatPanelRow` uses, and `targetTitleLimit`;
- the handoff texts (`discussMessage`, `handToAgentTask`, `agentActionTask`, `agentActionHelp`, `attachmentMarkdown`, `notice`, `readingSourceLine`);
- the time part of `sourceLine`, `stamped` and `updated`, which belong to the screen models.

`InboxCardNotice` is not ported: no notice is posted on either side today.

The switch the Mac reads (its feature list) and the one Go reads (`config.yaml` through `features.DisabledIDs`) are the same config keys. The Mac also folds in a toggle it has staged but not yet written; Go sees the toggle once the CLI writes it.

## The parity fixture

`internal/inboxfeed/testdata/inbox_feed_cases.json` is a list of cases. Each case has `{name, now, seed: [SQL], opts: FeedRequest, expect: Feed}` with `built_at` blank, and its seed runs on a fresh migrated file. Two tests run it:

- Go runs it in `TestInboxFeedCases`; `go test ./internal/inboxfeed/ -run TestInboxFeedCases -update` rewrites the expects.
- The Mac runs it in `WatchtowerDesktop/Tests/Core/InboxFeedParityTests.swift`. That test seeds a `TestDatabase` with the migration's root and Needs approval rows, runs today's Swift builders at `now` in UTC, maps them through `Tests/Core/Support/SwiftFeedAdapter.swift` and compares the result with `expect`:
  - The fields Swift does not compute are listed in `SwiftFeedAdapter.goOnlyFields`, each with a reason, and blanked on both sides.
  - The fields the adapter derives from Swift data with a Swift builder's own rule (pin, stamp, the source line without its time, a notice's id) are listed in `restatedFields` and compared.
  - A case's `disabled_features` reach the Go `Options` and the Swift readers alike.
  - The entries the next part ports (approvals, thread briefs, legacy lists) are reported in `unmapped`.
  - A limited case checks that the Go cards are the Swift cards in order with the cut ones out, and that `more` counts the cut.

`testdata/save_automation_summary_cases.json` is run the same way, by `TestSaveAutomationSummary_SharedCases` and `testSaveAutomationSummaryMatchesGo`.

## Speed

`BenchmarkInboxFeedBuild` runs over the gate fixture, `feedtest.SeedGate`: 2 000 outputs, 200 approvals, 500 open items and 30 folders. It measured about 32 ms/op on an M3 Max. The gate (≤ 100 ms median) is checked over the socket.
