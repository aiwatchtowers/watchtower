# Inbox core — one Inbox implementation in Go (`internal/inboxfeed`)

Stage 1 of #1170 (spec `docs/superpowers/specs/2026-11-15-mobile-inbox-design.md` §4). The Inbox's list, counts and card texts are built once, in Go, and both clients draw the result: the Mac over the daemon socket (`<workspace>/tower.sock`), the iPhone through the hub. This note covers the feed (`inbox.feed`, `inbox.watch`) and the writes (`inbox.act`).

## The feed

`inboxfeed.Build(ctx, d, Options{Folder, Limit, Clip, Now})` reads the Inbox in one `BeginTx(ReadOnly: true)` transaction, so every count and every card comes from one snapshot. It writes nothing (`TestBuild_WritesNothing` checks `data_version` on a second handle and `total_changes`).

`api.Feed{v, built_at, folders[], cards[], more}` (`internal/tower/api/inbox.go`, `FeedVersion = 1`):

- **Folders** come in pre-order: the root, then each folder followed by its children, by `position` and then `id`. Each folder carries `{id, kind (root|approvals|owner), slug, title, icon, parent_id, position, hidden, count, waiting}`.
  - `hidden` is the effective value, not the row's own flag: it is set when the folder or one of its ancestors is hidden. Such a folder leaves the menu and the badge, but it is still sent, because the Mac's **Show Hidden Folders** draws it. Which ancestor hid it is found by walking `parent_id`.
  - `count` is the folder's own count, not its children's (`InboxFolderCounts`):
    - an artifact with no row ref counts 1 while it is unread;
    - an artifact with row refs counts its rows whose record waits on the owner, whatever its read state;
    - the legacy terms are added: in Needs approval, the actions that wait on the owner, the due reminders and the failed built-in moves; in the root, the ideas awaiting a verdict, the unread open messages while Messages stands in for Waiting for me, and 1 while the latest briefing is unread.
  - `waiting` is the part of `count` that waits on the owner: the open approvals where Needs approval lists them (the root on a tree without it), plus every artifact's rows whose record waits. An unread plain artifact, an idea to judge, an unread message or briefing and a failed built-in move count but do not wait.
- **Cards** come in list order: folders in pre-order, and each folder's entries in its own order (`InboxFolderEntries.build`):
  - Needs approval lists the failed built-in moves (`notice` cards), then every open approval (native cards above the recipe's), then the settled rows (see below).
  - The root lists Waiting for me first while it has rows that wait (`pinned`), then, newest first, its artifacts and the legacy entries by their own time (see below).
  - An owner folder lists its artifacts with the newest change first.
  - The artifacts of the `needs-approval` built-in are left out of every folder: they are the approvals' cards. Waiting for me's artifacts are left out while the Messages entry stands in for it or while it is turned off.
- **Link.** An artifact card's `link` is its own link (`automation_outputs.link`), the Mac's common-row Open; `""` on every other card.
- **Stamps** are UTC (RFC 3339, whole seconds). A living card's stamp is its last write (`written_at`); any other card's stamp is its creation. `source_line` carries the source only, for example the automation's name. The time ("· 10:00", "· Updated 10 min ago") and the Today/Earlier grouping belong to the screen models, which use the client's own time zone.
- **Card texts** (`texts.go`):
  - `title` is the card's title, or the automation's name when the card has none.
  - `preview` is the body's markdown as plain text on one line, clipped to 140 characters with "…" (`InboxCardTexts.preview`, through goldmark with the GFM extensions). As in cmark-gfm's text nodes, backslash escapes are resolved, and so are entity and numeric references, in one pass. Characters are grapheme clusters (`rivo/uniseg`), as Swift counts them, so an emoji sequence counts once and is never cut.
  - `priority` is high, medium or low; any other value reads as medium.
  - A notice reads "Couldn't move <built-in> to Automations".
  - `unread` is "never opened" for a card without row refs, and "a row waits" for a card with them.
- **Blocks:** `blocks` holds the stored document, or `""` for a markdown card. A document past `MaxBlocksBytes` (128 KB) is sent as a `notice` card whose body and preview are `TooLargeSentence`; it keeps its `content_hash`. The check uses the stored `blocks_json` length, which the writers store canonical. Such a card still counts its waiting rows and shows unread as the artifact would.
- **Ref facts** (`ref_facts`, `reffacts.go`, the port of `InboxRefState` and `InboxReplyPolicy`): each row ref of the document once, in document order, closed ones included (the screen models hide those rows by `open`). `open` is the row shown, `waits` the row counted; they differ only for an idea (shown while not merged, superseded or snoozed; waits while shown and awaiting a verdict). An `action` uses `db.AwaitingOwnerClause`, an `inbox_item` `db.OpenInboxClause`. An inbox item also carries `reply` (`InboxReplyPolicy.tool(for:)`), `reply_waiting` (a Reply proposal pending, approved or executing) and its permalink as `link`; a reminder its Slack message as `link`. The Mac's row buttons read a few more facts: an inbox item's `trigger_type`, a track's `custom` (origin) and `linked_target_id`, an idea's `idea_kind` and `idea_status` (empty or zero on the other kinds).
- **Actions** (`actions.go`, the button half of `InboxCardButtons`, `InboxCardPress.isDisabled`, `InboxCardAction.replyState` and `TargetButtonStateResolver`): the card's buttons in press order (`blocks.FlattenActions`), an action the Mac cannot draw left out with the others keeping their `index`. `state`: a web link `enabled` (no host: `disabled`), a screen link (`watchtower-nav://`) `mac_only`, chat and agent `mac_only` (handoff stays on the Mac); a Reply `pressed` once pressed (the pressed one labelled "Sent — run #N"), `disabled` once its recipe is removed, else `enabled`; a target button `pressed` while waiting, creating or created, else `enabled`. `detail` carries the Mac's own state (a Reply's `ready`, `sent`, `needs_confirmation`, `off`, `unreadable`, `removed`; a target's `idle`, `waiting`, `creating`, `stuck`, `failed`, `created`) and `note` its line (a Reply's caption, a failed target's message). A target is creating for two minutes after its decision (`targetStuckAfter`), then stuck: that state moves with time, not with a write, so `inbox.watch` does not wake for it. So a creating target carries `until` (its decision + 120 s, UTC): the screen models draw it as stuck once the client's own clock passes `until`. The Mac's own in-flight processes and press errors stay client state.

## Writes (`inbox.act`)

`inboxfeed.RegisterAct(r, ActDeps)` registers `inbox.act` (`api.ActRequest{request_id, target, verb, params}` → `api.ActResult{already, status, error, run_id}`) with `Spec{ChangeTables, IdempotentFor: ActIdempotent, GrantFor: ActGrant}` in `commands.RegisterAll`, from `commands.Deps.Act`. `ActDeps{Registry, RunNow, Wake, Background, Clock, StartWatch}`: the daemon (`cmd/sync.go` `towerActDeps`) fills the tools registry `watchtower actions` uses, Run Now as `automations run` queues it (`queueRun`; a refusal is an `inboxfeed.CannotRunError`), the in-process executor wake (`Daemon.WakeAutomations`) and `tracks start` (`towerStartWatch`); the hub sets `Background`. A missing dependency answers `unsupported` for the verbs that need it, before anything is written; a zero `ActDeps` is valid (the generator, tests).

| Verb | Target | Write |
|---|---|---|
| `read` | `o…` (hash-guarded `read_at`), `brief-<date>` (its unread briefings), `r…`/`n…` (nothing: `already`), any card with `ref_kind: inbox_item` (the message's `read_at`) | `MarkOutputReadTx`, `MarkBriefingReadTx`, `MarkInboxItemReadTx` |
| `done`, `dismiss` | `o…` | `MarkOutputDoneTx`, `DismissOutputTx`: open rows at `content_hash` only |
| `press` | `o…` + `index` + `content_hash` | a Reply queues the automation's reply run (`PressInboxOutputActionTx`, after `automations.RequireInboxReply`; then `Wake`); a target proposes its `create_target` row in the button's context (`InboxTargetPress`). A press with `text` is refused: a reply run carries no typed text |
| `run_now` | `o…` | `ActDeps.RunNow` on the card's automation |
| `ref` | any card | `inbox_item` resolve ("Manually resolved"), dismiss, snooze (`until`); `track` done (`MarkTrackDoneTx`: the track read with its digests and decisions, TRACKS-04, and its events), stop and restore (`StopTrackTx`/`RestoreTrackTx`; a custom track's collection goes off before its stop and on after its restore in the same transaction — its watch recipe's `enabled` when one is bound, `SetAutomationEnabledTx`, mirrored by `trg_automations_enabled_watch_track`, else `SetTrackEnabledTx` — as `CustomTrackControlling`/`RecipeCustomTrackControls` do), and `make_task` (`ref_id` is the track, as for every track verb, and `event_id` the event whose change it applies — the id `TrackActionPress` sends; an event of another track is `not_found`: `apply_track_action` proposed, approved and applied in one press; a change already applied is `already`, and a racing loser's failed audit row is one no approval list shows); `idea` approve/reject/not now (`SetIdeaVerdictTx`, `SnoozeIdeaTx`, IDEA-04's review flag cleared); `reminder` done/snooze; `plan_item` check/uncheck (`SetPlanItemStatusTx`, cascading to a task that still exists as the owner, INBOX-02 included) |
| `reply_propose` | any card, `ref_kind: inbox_item` + `text` | the item's reply tool proposed in `inbox_item:<id>` (`InboxReplyPolicy`'s args; reason "Reply from <the card's title>" or "Reply from Messages") |
| `approval` | `a…` | `approve` (`ApproveSeen` pinned to `args_sha256`; `patch` only over the socket), `reject`, `retry` (`Apply`; a stuck target row's `executing` claim is reclaimed first; an older row of a button with a newer open proposal is refused), `dismiss` (`DismissSessionCall`) |

- **Writers.** `internal/db/inbox_writes.go`: each one short write in the caller's transaction, ported from its Swift query with its guard (`MarkOutput*Tx` = `AutomationQueries.stampOnce`, `MarkTrackReadTx` = `TrackQueries.markRead`, `StopTrackTx`/`RestoreTrackTx`, `SetIdeaVerdictTx`/`SnoozeIdeaTx`, `SetPlanItemStatusTx` = `DayPlanQueries.markItem*` with `cascadeTaskStatus`, …). The older non-Tx forms (`MarkTrackRead`, `DismissTrack`, `RestoreTrack`, `ResolveInboxItem`, `DismissInboxItem`, `SnoozeInboxItem`, `MarkBriefingRead`, `UpdateItemStatus`, `PressInboxOutputAction`) wrap them, so each write has one implementation; a wrapper that never refused a missing row still does not. The reminder writes keep no Tx form: their approval hook must run after their own commit (`TestApprovalHook_EveryWriterNotifies`), so `inbox.act` calls `MarkReminderDone`/`SnoozeReminder` and, on a handle without a hook, `builtin.Fire` itself. Their ledger row therefore commits after their write, not with it; a resend after a crash between the two is still safe: Done is guarded by its own `UPDATE … status != 'done'` (answers `already`), and a Snooze to the same time is read as `already` before it writes.
- **Transactions.** Every guarded write is one `Ctx.Write` (`BEGIN IMMEDIATE`): it reads the row, decides, writes, and its ledger row commits with it. Registry calls (approve, reject, proposals) write through the registry's own short transactions, never inside `Ctx.Write` (the daemon's pool has one connection).
- **Owner gestures (AGENT-07).** The verbs whose CLI twins are owner gestures — `approval` approve/retry/dismiss, `press`, `reply_propose`, `ref make_task` and `ref restore` of a recipe-bound track — run over the socket only for the signed Watchtower Desktop: `Origin.Desktop`, the connection's peer pid read again on every gesture (macOS reports the last process that used the socket, so an inherited descriptor is seen) and checked with `ownerconfirm.VerifyDesktop` once per pid, a check cut short by its context never kept (the daemon's `tower.Options.VerifyDesktop`; owner-confirm.sock's requirement and dev-build rule). Any other peer is refused `not_permitted` ("…: the owner decides in Watchtower Desktop."). The other verbs stay open to any owner-uid peer, as their CLI twins do. From the hub (the linked phone, under its grants), Stop and Restore of a recipe-bound track are `not_permitted` ("…: this is done on the Mac."), and an approved `create_track` applies without starting its watch, its answer's `note` reading "Start watching it from your Mac." (ask #1349).
- **Idempotency** (`ActIdempotent`): every verb is guarded except `run_now`, every `press` (the params cannot tell a Reply from a target; a target press stays safe through its one open proposal) and `approval` approve/retry. **Grants** (`ActGrant`, ask #1349): every owner gesture from the hub needs one — `permissions` for approve, retry and dismiss of an approval, `make_task` and a target press; `typing` for a Reply press and `reply_propose`. A press names its button's kind (`action_kind`, the drawn `CardAction.Kind`), from which the grant is decided; a press without it takes `permissions`, and one whose button is another kind is refused `changed`.
- **Answers.** A guarded no-op answers `ok` with `already: true` (marked already, the state already set, a pressed Reply with its `run_id`). Refusals: a `content_hash` that is not the row's → `changed`; a closed row → `changed` ("the item was already closed on the Mac"); a merged or superseded idea → `changed`; `*ErrReplyAlreadyWaiting` → `reply_waiting`; `tools.ErrArgsChanged` → `args_changed`; a missing row → `not_found`; `patch` from the hub → `not_permitted`; a pair outside the table → `unsupported`.
- **Approve and retry** decide in a short write of their own, then run the tool outside any transaction (`context.WithoutCancel`, `Apply`'s claim keeps it to one run). Over the socket the call waits up to `ApproveWaitCap` (120 s) and answers `status: applied|failed` (with `error`), or `applying` on expiry — the outcome then lands on the row (the next feed's approval card shows a failure with its error) and is logged with the action id; a watch that did not start leaves its track unwatched, which the Mac's track card shows with Start Watching; over the hub `Background` runs it and the call answers `applying` after the decision. A session-applied tool stops at approved (its chat claims it). An applied `create_track` then starts its track's watch (`ActDeps.StartWatch`, the Mac's `startWatchingIfTrack`), outside any transaction; a watch that does not start is the result's `error` ("Approved, but the track is not watched yet: …"), the approve standing.
- **Sentences** (`sentences.go`): "Couldn't <verb phrase>: <reason>", the phrases one per verb (`TestSentences_EveryVerbHasAPhrase`), the reasons one per code; `args_changed` reads "This proposal changed on the Mac — look again before approving." A fault (not a refusal) is worded by `FaultSentence`, the daemon's `tower.Options.Sentence`: "Couldn't mark it done: the database is busy." on `SQLITE_BUSY`, else "…: something went wrong on the Mac — try again."; the error itself goes to the daemon log.
- **The shared fixture.** `testdata/inbox_writes.json`: `{name, seed, now, call, swift, expect{status, code, sentence, already, run_id, rows}}`, where `rows` lists every row of a table in id order on the columns given (`"*"` any non-empty value). Go runs every case through `tower.Call` (`TestInboxWritesCases`) and races each writing case from two `db.Open` handles (`TestInboxAct_TwoConnectionsRace`: one writes, the other answers `already` or `changed`; a reminder Snooze, unguarded as its Swift twin, is left out). The Mac runs each case with a `swift` writer in `Tests/Core/InboxWritesFixtureTests.swift`. `internal/db/inbox_writes_test.go` fails every writer between statements through the `faultAfter` seam and checks the rollback.

## Needs approval (APPROVAL-01)

`approvals.go` ports `NeedsApprovalSelection` over `db.ReadNeedsApprovalTx` (`internal/db/approvals_all.go`), read in the feed's transaction: the open approvals (`db.AwaitingOwnerClause` and the due reminders, oldest created first, actions before reminders on a tie), every automation's open `action:<id>`/`reminder:<id>` artifacts, the `needs-approval` built-in's state and the settled rows.

- **The pick.** The recipe's card draws an approval only when all four hold: `approval-cards` is on and the built-in not stopped, its latest finished run did not fail, its artifact for the approval exists (the built-in's own; another automation's never draws one), and the artifact was written at or after the approval's last change. Otherwise the native card. A built-in artifact whose approval is not open is drawn in no folder and counted in none.
- **Order.** Notices, the native cards, the recipe's cards, then the settled rows (approved or executing, newest created first): drawn natively, never counted.
- **Cards.** Every approval card is unread and titled as its folder row: an action's reason (else its tool), a reminder's note (else "Reminder"). A native proposal is `a<id>` (`approval_native`), its `source_line` the run label "⚙ <automation> · run #<n>" (else "Assistant proposal"), its `content_hash` the args' SHA-256. A native reminder is `r<id>` (`reminder`), its stamp the due time, its reminder ref fact carrying the Slack link. A recipe's card is the artifact `o<id>`.
- **`approval`** (`approvaltext.go`, the Mac's native card): `title` and `summary` (body lines joined by `\n`) as the reading pane draws the proposal: a pending save_automation as `SaveAutomationProposalPane` ("Save automation <name>", For / When / It may), any other save_automation as `SaveAutomationCardDetails` (its scope line, file, when, permissions with the widening ones marked "+ ", outputs, budget, missed runs, concurrency and dry-run summary; the recipe text and diff stay behind the Mac's disclosures), a claude.ai connector call as its connector, tool and indented input, a Slack send as its recipient and text, any other tool as `AgentActionCardView.summaryLines`. `edit_on_mac` is set on a pending Slack send, connector call or save_automation. `proposer` is the run label; `status`, `error`, `reason` as stored.
  - A save_automation past pending also carries its recipe disclosure: `disclosure` ("Show the whole recipe (N lines)" with `recipe_text` for a new recipe; "Show changes" with `diff` lines, or "No change to the recipe text", for an edit). `diff` is `OwnerAskSnapshotDiff`'s lines; `recipediff.go` ports Swift's `difference(from:)` (Myers) so the same lines are marked. With `Clip`, `recipe_text` is clipped to 16 KB on a rune boundary and `diff` to the lines whose texts fit in 16 KB, and `recipe_clipped` is set.
  - An Inbox target button's rows (`automation_output` context): the newest proposal of a create_target button carries `target`, `target_note` and `target_until` (the button state, as `actions[]`'s detail, note and until; the Mac draws stuck, or failed on a row not itself failed, as "Didn't finish" with Try again, and creating as progress — `AgentActionCardView.targetRow`); an older proposal is `superseded` and offers no Retry (`isSupersededButtonRow`). The newest proposals are read for the open artifacts' buttons and for every button a pending, failed, approved or executing row proposed for. A save_automation's workbench name comes from `projects`: the Mac's list is `WorkbenchesViewModel.summaries` (`WorkbenchQueries.summaries`, the `projects` rows).

## Legacy root entries (spec §4.4)

`legacy.go` carries each legacy entry as a `legacy` card whose `legacy` section lists its rows with the words of the Mac's list row (`InboxListRow.content`: `title`, `subtitle` = the source without its time, `preview`, `stamp`, `unread`, `high`):

- **Morning brief**, one card per date (`brief-<date>`, `InboxListBuilder.rootDays`): today's and every unread day of the first 30 dates, plus today's placeholder while the owner is known, today has neither briefing nor plan, and the briefing or day-plan feature is on. Title "Morning brief", source "Your day · Mon 16 Nov", preview "today" on today's. Items are the day plan's items (`plan_item` refs, time blocks first, `done`, `high`, `stamp`/`end` = a block's start and end, which the Mac draws as a range); `attention` is the briefing's attention list.
- **Track my threads** (`tracks`) while a track exists, stopped ones included: "N unread" over the active tracks, the active tracks newest first, then the stopped ones with `stopped`.
- **Idea finder** (`ideas`) while an idea exists or the `idea-finder` built-in is indexed: "N to judge", the ideas to judge first, then the rest newest first.
- **Messages** (`messages`) while it stands in for Waiting for me and has a message: "N waiting", "Mentions, DMs and replies", the open messages newest first.
- **Thread briefs** (`thread-briefs`) while a `brief_context` was applied in the last 24 hours: one item per brief (`action` ref, its reason, its summary), never unread. The Mac lists each brief as its own root entry; the feed carries them as one card at the newest one's place.

Each card's own time places it among the root's artifacts. The Mac keeps drawing the panes with its own views.

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
- `DisabledFeatures` are the feature ids the config has off: the Mac's own feature list (`features list --json` reports them as `disabled`). Four matter: attention detection (`secretary-inbox`, config key `inbox.enabled`), `approval-cards` (off, every approval draws natively), and `briefing` with `day-plan` (both off, no placeholder day). When it is off, Waiting for me is turned off whatever its row says, as `InboxFolderQueries.waitingForMe(featureOn:)` has it: its artifacts are not shown and nothing counts for it, the Messages stand-in included. The owner's off wins over a stop by the daemon.
- `Now` is the moment the feed is read. Its location is used for one date-only value, an idea's "not now" day, which the owner's zone wrote.

## Commands

`inboxfeed.Register(r, disabledFeatures)` registers two commands in `commands.RegisterAll`. `disabledFeatures` is `commands.Deps.DisabledFeatures`, which the daemon fills (`cmd/sync.go` `towerDisabledFeatures`). It re-reads `config.yaml` (`config.Load(flagConfig)` → `features.DisabledIDs`) at each `inbox.feed` call, because the owner flips features while the daemon runs (`watchtower features enable|disable`, or the Desktop's Feature Manager through that CLI). A config that cannot be read is logged, and the daemon's start config answers instead. A zero `Deps` (the generator, tests) means nothing is off. The commands:

- `inbox.feed`: `Spec{Read: true, ChangeTables}`; `api.FeedRequest` → `api.Feed`.
- `inbox.watch`: `Spec{Watch: true, ChangeTables}`; `api.WatchRequest` → `api.WatchResponse`. It answers ok, then the socket streams `ChangedEvent` frames.
- `inbox.act` (`RegisterAct`, Writes above): `Spec{ChangeTables, IdempotentFor, GrantFor}`; `api.ActRequest` → `api.ActResult`.

`ChangeTables` lists every table the feed reads, `jira_issues` included (`db.OpenInboxClause` drops an open Jira item whose issue was deleted), and the tables of the `db` readers it calls: `users` and `channels` (a message's words), `projects`, `targets`, and the account tables `db.OwnerKnownTx` reads (today's placeholder day). `TestChangeTables_CoverEveryTableBuildReads` checks it against the package's SQL. `internal/tower/api/inbox.go` also holds the act types (`ActRequest`, `ActParams`, `ActResult` and their enums) of `inbox.act` (Writes, above).

## What moved from Swift

| Swift today | Go |
|---|---|
| `InboxFolderEntries.build`/`row`, `InboxListBuilder`, the list and counts part of `ActionStripViewModel` (`legacyCounts`) | `Build`, `cards.go`, `counts.go` |
| `InboxFolderCounts` (`counts`, `artifactCount`) | `counts.go`. `badge` becomes the screen models' sum of the visible folders' `count` (not `waiting`: the badge also counts unread plain artifacts, ideas to judge, an unread briefing and notices) |
| `InboxFolderQueries.tree`/`artifactsByFolder`/`waitingForMe`, `InboxRef.refs`, the waits half of `InboxRefState.read` | `folders.go`, `counts.go` |
| `InboxCardTexts` (`preview`; `sourceLine`'s source part), `InboxCardSubject` (title, priority), `BuiltinUpgradeNotice` (title) | `texts.go` |
| `SaveAutomationProposalSummary` with `AutomationTriggerText`/`CronText` and `AutomationCardPresentation.permissionLine` | `SummarizeSaveAutomation`, `PermissionLine` (`savesummary.go`) |
| `NeedsApprovalSelection` (APPROVAL-01), `InboxFolderMenuSnapshot.approvalArtifacts`/`openActions` | `approvals.go` over `db.ReadNeedsApprovalTx` |
| `AgentActionCardView.title`/`summaryLines`/`targetRow`, `SlackSendProposal.recipientLine`, `ConnectorCallProposal`, `RawJSON`, `SaveAutomationCardModel` (lines, disclosure), `OwnerAskSnapshotDiff.lines` | `approvaltext.go` (`ApprovalTextOf`), `recipediff.go` |
| `InboxRefState` (shown and waits), `InboxReplyPolicy` (`tool(for:)`, `isOpenReply`) | `reffacts.go` |
| `InboxCardAction.replyState`, `InboxCardPress.isDisabled`, `InboxCardButtons.label`/`caption`, `TargetButtonStateResolver`, `AgentActionQueries.newestButtonProposals`/`actionsWithTask` | `actions.go` |
| `InboxListBuilder.sections`/`rootDays`, `InboxFeedQueries` legacy reads, `InboxListRow.content` | `legacy.go` |

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
  - Every entry is mapped, the approvals and legacy entries included; the native approval's text is compared by the app target's `ApprovalTextParityTests` over `testdata/approval_text_cases.json`, and the target button states over `testdata/target_button_cases.json` (Go: `TestApprovalText_SharedCases`, `TestTargetState_SharedCases`).
  - A limited case checks that the Go cards are the Swift cards in order with the cut ones out, and that `more` counts the cut.

`testdata/save_automation_summary_cases.json` is run the same way, by `TestSaveAutomationSummary_SharedCases` and `testSaveAutomationSummaryMatchesGo`.

## Speed

`BenchmarkInboxFeedBuild` runs over the gate fixture, `feedtest.SeedGate`: 2 000 outputs, 200 approvals, 500 open items and 30 folders. It measured about 32 ms/op on an M3 Max. The gate (≤ 100 ms median) is checked over the socket.
