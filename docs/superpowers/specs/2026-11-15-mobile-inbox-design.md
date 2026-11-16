# Phone Inbox — one Inbox and one chat writer on the tower, drawn by the Mac and the iPhone (design)

Target #1170. This is sub-project F ("Phone renders blocks") of the Inbox builder umbrella, `docs/superpowers/specs/2026-11-02-inbox-builder-design.md`, and builds on A (`docs/features/inbox-card-blocks.md`) and B (`docs/features/inbox-folders.md`). The hub side is the Go hub (`docs/features/go-hub.md`). The phone is `WatchtowerMobile/` (`docs/features/mobile-companion.md`).

Mockups: `docs/design/mockups/mobile-inbox/index.html`, with every state in dark and light. Sections 1–6 are the phone, and section 7 is the Mac's three new states. After the build, each phone frame becomes a `ScreenshotTourTests` shot named `inbox-…`. Each Mac frame becomes a `DesignShotCatalog` shot named `inbox-feed-…`. The shots are compared with the mockup before review (§10).

## Intent

The owner wants to clear the Inbox on the go: open the phone, act on what waits (approve, reject, mark done, snooze, hide, reply) and put it away (ask #1326). The phone shows an adapted copy of the Mac's Inbox, with every section, in its own tab (ask #1326).

The Inbox must work the same on the Mac and on the phone (ask #1348). Today the Inbox list is built only in Swift and most of its writes are Swift only, so the phone would need either a second implementation or the Mac. This design moves the line instead. All Inbox logic and every Inbox write live in Go on the **tower** (the daemon, the CLI and the hub), which also runs without the Desktop. The Desktop and the phone are two equal thin clients that draw what the tower builds and send commands back (ask #1356). The same line applies to chat: the tower already runs and saves a chat turn (#1791), and the Desktop's own Swift turn writer moves onto it here, with no loss of chat UX (ask #1361).

## Goals

- **One Inbox core in Go** (`internal/inboxfeed`). It builds the root, the folders, their order and counts, Needs approval, Waiting for me, card texts, ref facts and the legacy root entries. It also applies every Inbox action. The CLI, the hub and nothing else call it.
- **The Desktop switches to it with no visible change** to the Inbox, except the three new states in mockup §7. It reads the list through `watchtower inbox feed --json` (ask #1356) and acts through `watchtower inbox act`. The Swift builders and Swift writers it replaces are deleted.
- **An Inbox tab on the iPhone**, placed second (ask #1349). It shows the same list from the same Go code through the hub: the root, Needs approval and the owner's folders up to three levels deep, each with the Mac's count.
- Every artifact is drawn from the same block JSON (Kit `ArtifactDocument` on the phone, the Desktop's renderer on the Mac). A markdown card draws as text. An unsupported or unreadable card shows its plain text with the Mac's line.
- On every row with a `ref`, the phone offers the same native actions the Mac offers for that kind (umbrella "Acting on one row of a list"). This includes the plan-item check (ask #1348). A failed write keeps the row with its error and **Retry**.
- Needs approval shows the native card or the recipe card, as APPROVAL-01 decides. Approve pins the arguments the owner saw and needs the `permissions` grant (ask #1349).
- **The Desktop's chat writes go through Go** (stage 3, ask #1361). The Swift `ChatTurnStore`, `ChatTurnDriver` writes and every other Swift writer of the `chat_*` tables are deleted. The Mac's chat keeps the same live stream, Stop, warm sessions and speed (§8).
- Honest states on both clients: loading, empty, an empty folder, a failed load with **Retry**, a failed action with **Retry**, the Mac away (phone actions queue), not delivered (**Retry**), a Mac too old, and organization policy.

## Non-goals

- Managing the Inbox from the phone stays on the Mac (ask #1349). This covers creating, renaming, moving, hiding or deleting folders, routes, editing a recipe or its look, turning automations on or off, and Delete. The phone says "on your Mac" where the Mac has a menu. Folder management is already in Go (`inbox folders …`), so it is outside this work.
- On the phone, Discuss in Chat, Hand to Agent, the card actions `chat` and `agent`, Open Draft (`save_automation`) and Edit… on a proposal are drawn disabled with "On your Mac" (ask #1349).
- No push notifications for new Inbox cards in v1 (ask #1349).
- Learned Rules, Assistant Profile and the reaction cheat sheet (**?**) are not on the phone.
- No phone renderer for block types beyond A's v1 set.
- Chat on the phone is done (#1791). Chat on a headless tower already works through the hub. Stage 3 changes only who writes the Desktop's chat rows; it adds no chat feature.
- Sub-project C (built-ins producing their own artifacts) is not part of this work. The legacy entries stay until C (§2.4).

## Anti-goals

- Two implementations of one Inbox rule. After stage 1 no Swift code decides which rows are open, what a folder counts, which card Needs approval shows, what a card says, or what an action writes.
- A row that looks done while its write failed, or a closed row that comes back from a stale publish or a stale feed.
- An approval that goes through for arguments the owner did not see.
- The phone holding more of the owner's data than the Inbox shows: no raw message tables and no history beyond what is drawn.
- A Mac Inbox that changes look or behaviour in stage 1, other than the states in mockup §7.
- A Mac chat that gets slower or loses anything in stage 3: first text later than today, a Stop that takes longer, a cold process where a warm one was, or a send that can be lost (CHAT-01) (ask #1361: "only the user's UX must not get worse").

## Constraints

- **Wire is additive** (protocol spec §8). New slice kinds and action kinds get new names. `inbox_item` and `inbox_resolve`/`inbox_dismiss`/`inbox_snooze` are legacy names and stay unused. `slices.AllKinds`, `secure.dataKinds` and the Kit `SliceKind` change together. `handlers.NudgeTable` is pinned to `hub_contract_cases.json`.
- An envelope is at most 900 KB. A block document is at most 128 KB canonical (A), so one card is one record.
- The read, done and dismiss marks are guarded by `content_hash` (A). The Go writers keep exactly the guards the Swift ones have today.
- MDM `MobileSync = workbench_only` publishes no Inbox kinds. POLICY-03 applies: tightening deletes the published records and nothing else.
- Write transactions are `BEGIN IMMEDIATE` and short: no rendering inside one (CLAUDE.md).
- The Desktop and the CLI ship in one bundle, so the feed's JSON has a version (`v: 1`) but no compatibility window between them.
- Phone design rules (mobile design pass spec): flat rows, cards only for waiting items and detail blocks, orange only for waiting-for-you, no row separators outside a card, and every string in a model with a test. Desktop rules: `docs/design/desktop-style-guide.md`, colours only through Tone.

## Approaches

**Where the Inbox logic lives:**
- **One core in Go, both clients thin (chosen, asks #1348 and #1356).** The Swift Inbox core moves into Go once, and both clients read its output. This costs a port of the Swift builders and writers (about 4 400 lines under `WatchtowerCore/Services/Inbox` plus the list and counts part of `Services/Actions/ActionStripViewModel.swift`, and the write queries in `WatchtowerCore/Database/Queries`; the builders and writers move and the view models stay) and a CLI round trip on every Desktop refresh. It is the only option that also works on a headless tower.
- **A Go twin of the Swift core, kept equal by fixtures.** The phone would get the Go copy and the Mac would keep Swift. This means two implementations forever, and the owner asked for the same behaviour on both. Rejected (ask #1348).
- **The hub sends raw rows and the phone builds cards.** This would mean ten raw kinds and the Mac's rules copied into the Kit. Rejected (ask #1332, approach B).

**How the Desktop's chat turn reaches Go (stage 3):**
- **The Desktop's own `ai session` process writes the turn (chosen).** The Desktop keeps its warm session pool and draws the live text from the process's stdout, as it does today. The process saves the turn through `chatstore`, the same code the hub's runner uses. Streaming speed, Stop and warm sessions do not change.
- **The Desktop asks the daemon's hub runner to run the turn.** The Mac would see the text through database re-reads (about once a second, as a Mac turn reaches the phone today). Chat would stop when the daemon is down, and the hub's pool of 2 would serve both the phone and the Mac. Rejected because it makes the UX worse (ask #1361's condition).

**How the Desktop reads the feed:**
- **`watchtower inbox feed --json` on a database change (chosen, ask #1356).** There is one builder and one writer of the data, and the result is never stale.
- **A table materialised by the daemon.** Reads would be cheaper, but the table adds a writer and can lag. Rejected (ask #1356).

## Design

### 1. Stages

1. **Inbox core in Go, Desktop on it.** Add `internal/inboxfeed` (§2), the CLI verbs `inbox feed` and `inbox act` (§3), and the Go writers (§2.3). Then switch the Desktop to them and delete the Swift builders and writers (§4). The Mac's Inbox shots before and after are compared frame by frame.
2. **The phone.** Add the hub sources and actions over the same core (§5) and the phone tab (§6), following mockup §§1–6.
3. **The Desktop's chat writes in Go** (§8). This stage is independent of stages 1–2 and may run in a parallel lane.

Stage 2 depends on stage 1. Inside each stage the plan may run independent tasks in parallel lanes.

### 2. The Go core: `internal/inboxfeed`

#### 2.1 What moves from Swift

| Swift today (`WatchtowerCore/Services/Inbox/…`) | Go after stage 1 |
|---|---|
| `InboxFolderEntries.build`, `InboxListBuilder` (which rows sit in which folder, in what order) | `inboxfeed.Build` |
| `InboxFolderCounts` with `legacyCounts` | `inboxfeed` counts |
| `NeedsApprovalSelection` (APPROVAL-01: native or recipe card) | `inboxfeed` approvals; a new all-automations reader next to `db.ReadApprovalsView`, which reads one automation's approvals |
| `InboxCardTexts`, `InboxCardSubject`, `InboxCardNotice`, `SaveAutomationProposalSummary` (header, source line, preview, notice texts) | `inboxfeed` texts |
| `InboxRefState`, track and idea parts, `InboxReplyPolicy` | `inboxfeed` ref facts; it reuses `db.OpenInboxItems` and the open-approvals reader already in Go |
| `InboxTargetButtonFacts`, `InboxCardAction` button states | `inboxfeed` action states |
| Legacy root entries: Morning brief per date, Track my threads, Idea finder, Thread briefs, the Messages stand-in | `inboxfeed` legacy sections (§2.4) |

The view-only types stay in Swift and read the feed instead of the database: `InboxFolderMenuModel`, `InboxFolderListContent`, `NeedsApprovalNoteContent`, `InboxArtifactMenuModel`, `InboxFolderIcons`, `WatchTrackControls`, `RecipeCustomTrackControls` and `InboxAgentHandoff`. Handoff to chat and to the agent stays on the Mac.

The builder writes no rows and opens no write transaction. It runs inside one read-only transaction (`BeginTx` with `ReadOnly: true`), so the counts and the rows come from one snapshot.

#### 2.2 The feed

`inboxfeed.Build(ctx, db, now, opts) (Feed, error)`. The CLI prints it and the hub publishes it.

- `Feed{v: 1, built_at, folders[], cards[], more}`.
- A **folder** has `id`, `kind` (`root`, `approvals` or `owner`), `slug`, `title`, `icon`, `parent_id`, `position`, `count` and `waiting`. `waiting` is the part of `count` that waits on the owner: open approvals, and open rows with a `ref` that wait.
- A **card** has a typed `id` so that ids never collide across sources: `o<output id>`, `a<action id>`, `r<reminder id>`, `n<builtin migration id>`, `brief-<date>`, `tracks`, `ideas`, `thread-briefs`, `messages`.
  - `folder_id` and `card_kind`: `artifact`, `approval_native`, `reminder`, `notice` or `legacy`.
  - `title`, `source_line`, `preview`, `stamp`, `living`, `unread`, `priority`, `pinned`.
  - `automation`: `{id, name, builtin_id, run_id}`, or null.
  - `blocks`: the stored `blocks_json` bytes unchanged, or `""` for a markdown card.
  - `body`: plain text. The phone gets it clipped to 16 KB on a grapheme boundary with `body_clipped`; the CLI does not clip it.
  - `content_hash`: the output's hash. A native approval card carries its args SHA-256 instead.
  - `actions[]`: `{index, kind, label, state}`, the flattened press address from A. `state` is the Mac's button state: `ready`, `needs_confirmation`, `off`, `waiting_approval`, `task_created` and so on.
  - `ref_facts`: per `ref`, `{open, waits, reply` (`slack`, `jira`, `linear` or `none`)`, reply_waiting, link}`.
  - `approval`: native cards only, `{tool, title, summary, args_sha256, status, error, proposer, reason, edit_on_mac}`.
  - `legacy`: legacy cards only (§2.4).
- Rows whose ref is closed stay in the document. Each client hides them by `ref_facts.open`, so both clients draw the same open rows.
- `opts.Folder` narrows the cards to one folder. `opts.Limit` (the hub's 300) keeps Needs approval and Waiting for me first, then the rest newest first, and counts the remainder in `more`. The Desktop passes no limit.

#### 2.3 Actions

`inboxfeed.Apply(ctx, db, Action) (Result, error)` is the only Inbox writer. Every action is one short `BEGIN IMMEDIATE` transaction. Any rendering, LLM call or network call happens before the transaction or after it.

| Action | Target | Params | What it writes (the guard the Swift writer has today is kept) |
|---|---|---|---|
| `read` | `o…`, `brief-…`, `r…`, `n…` | `content_hash` | Output `read_at` guarded by the hash; briefing `read_at`; `inbox_items.read_at` |
| `done`, `dismiss` | `o…` | `content_hash` | Output `done_at` / `dismissed_at`, guarded by the hash, open rows only |
| `press` | `o…` | `index`, `content_hash`, `text` | `reply`: the `automations reply` path (`ErrOutputChanged` → `changed`). `target`: the `create_target` propose path, never approved here |
| `run_now` | `o…` | none | `automations run`, only where `Entry.RunNow` |
| `ref` | any card | `ref_kind`, `ref_id`, `verb`, `until` | `inbox_item`: resolve, dismiss, snooze (Go today). `track`: done with its read cascade, stop, restore. `idea`: approve, reject, not now. `reminder`: done, snooze (the reminder approval hook included). `plan_item`: check, uncheck (`day_plan_items.status`) |
| `reply_propose` | any card | `ref_id`, `text` | `InsertInboxReplyProposal` (`ErrReplyAlreadyWaiting` → `reply_waiting`) |
| `approval` | `a…` | `verb` (`approve`, `reject`, `retry` or `dismiss`), `args_sha256` | `Registry` approve, reject, apply or dismiss, pinned to the SHA. A mismatch → `args_changed` |

- **Result.** `applied` (with `already: true` when the row was already closed: a guarded no-op), or a refusal with a code and a sentence. The codes are `not_found`, `changed`, `args_changed`, `reply_waiting`, `not_permitted` and `unsupported`. The sentence is written in Go, and both clients show it as is.
- **Writes that are Swift-only today** get a Go writer for the same columns and cascades: output read, done and dismiss; briefing read; `inbox_items` read; track done, stop and restore with `track_events`; ideas; reminders; plan items. Each writer is ported from its Swift code and keeps its guard. The shared fixture `inbox_writes.json` pins every case. During the port, a WatchtowerCore test runs the fixture through the Swift writer and a Go test runs it through the Go writer. The Swift side of the test is deleted together with the Swift writer at the switch (§4).
- **Two writers moved, not added.** After the switch the Desktop has no GRDB writer to these columns. The Swift writers live in `WatchtowerCore/Database/Queries` (`AutomationQueries.markOutputDone`/`dismissOutput`, `TrackQueries.markRead`/`restore`, `DayPlanQueries.cascadeTaskStatus`, `ReminderQueries`, `InboxQueries`, `BriefingQueries`). A Core guard test lists the moved tables and columns and fails on any Swift `INSERT`/`UPDATE`/`DELETE` to them anywhere under `WatchtowerDesktop/Sources`. Which other screens call these writers is open in ask #1362.

#### 2.4 Legacy root entries (ask #1348)

Until sub-project C, the root keeps Morning brief (one per date, under the Mac's unread rule), Track my threads, Idea finder, Thread briefs and the Messages stand-in.

- The feed carries each of them as a typed `legacy` section: `{kind, items[]}` with the fields the Mac's views read today. The Desktop keeps drawing them with its own views, so the Mac does not change.
- For the phone, the hub turns the same sections into block documents with `ref` rows (`inboxlegacy`, §5). The phone therefore has one renderer.
- Plan items get the ref kind `plan_item`, and its check is the `ref` action above (ask #1348: "the check from the phone").
- C replaces each section with the built-in's own artifact and deletes both the section and its projection in its PR.

### 3. CLI

- `watchtower inbox feed --json [--folder <id>] [--limit <n>]` prints `Feed`. Exit codes: 0 on success, 1 on an error, with one line on stderr. The command opens the database read-only and never migrates (a `query_only` handle).
- `watchtower inbox act --json` reads one `Action` from stdin and prints one `Result`. A refusal is exit 0 with `status: "refused"`. Only an unreadable request or an unopenable database is exit 1.
- The existing `inbox resolve/dismiss/snooze`, `actions approve/reject/apply/dismiss` and `automations reply` verbs keep working and call the same `Apply` paths.

### 4. Desktop after stage 1

- `InboxFeedClient` (Core) runs `inbox feed --json` through the existing CLI runner. It refreshes on the database change signal the Inbox already observes, on folder navigation, and on a 60 s backstop. It keeps at most one run in flight: a change during a run marks the client dirty, and the client runs once more when the run ends.
- `InboxActionClient` (Core) runs `inbox act --json`. It keeps a pressed row busy until the result arrives, and the follow-up feed shows the outcome. It never marks success on its own.
- **New states (mockup §7):**
  - First load: a spinner, no rows.
  - A load that fails keeps the last list and shows the reason line with **Retry**. With no last list, it shows the line alone.
  - A failed action keeps the row with the sentence and **Retry**.
  - Every string is in `InboxFeedStateModel` with a test.
- **Speed budget.** On a fixture database with 2 000 outputs, 200 approvals, 500 open items and 30 folders, `inbox feed --json` runs within 150 ms median on the dev Mac (the plan's benchmark task, `BenchmarkInboxFeedBuild`, relative to the Swift build on the same fixture). If it exceeds the budget, the plan adds `--folder` reads for the open folder plus a counts-only mode before the switch, never a cache table.
- **The Swift builders and writers listed in §2.1 and §2.3 are deleted in the switch PR,** together with their tests. Their behaviour stays pinned by the Go tests and the shared fixtures. Before the switch, a parity task runs Swift `InboxListBuilder` and Go `Build` over the same fixture databases and compares their output (`inbox_feed_cases.json`). That fixture stays as the Go golden.
- Inventory: contracts under `docs/inventory/` that name a Swift Inbox type (APPROVAL-01 among them) are re-pointed to the Go code in the same PR. Their guard tests move to Go with the same `Test<Module>NN_` names, and their assertions are not weakened.

### 5. Hub (stage 2)

- **`inbox_folder-<id>`**: one record per visible folder, from `Feed.folders`.
- **`inbox_card-<id>`**: one record per card, from `Feed.cards` built with `Limit: 300`. A legacy card carries `blocks` from `inboxlegacy`, checked by `blocks.Validate` with a hub-only option that admits `plan_item`.
- `ChangeTables`: `automation_outputs`, `inbox_folders`, `inbox_folder_routes`, `inbox_items`, `agent_actions`, `reminders`, `tracks`, `track_events`, `ideas`, `briefings`, `day_plans`, `day_plan_items`, `builtin_migrations`.
- **Capability.** The heartbeat's `capabilities` gains `inbox: "on" | "policy_off"`. A missing key means a Mac too old, and the tab shows "Update Watchtower on <Mac>".
- **Action kinds** map one to one onto `Apply`: `inbox_card_read`, `inbox_card_done`, `inbox_card_dismiss`, `inbox_card_press`, `inbox_card_run_now`, `inbox_ref_action`, `inbox_reply_propose`, `approval_decide`.
  - Grants (ask #1349): `permissions` for `approval_decide` approve and retry; `typing` for `inbox_reply_propose` and for a `reply` press with text. Every other kind needs none, as board writes need none.
  - `approval_decide` (approve and retry) and `inbox_card_press` are in `NonIdempotentKinds`. Each is claimed `begun` before the handler runs, and a repeat after a crash answers `outcome_unknown`. Every other kind is a guarded write.
  - Each handler nudges `inbox_card` and `inbox_folder`.
- The hub builds the feed outside any write transaction and publishes after `PublishSoon`. A build that fails keeps the last published records and logs its error class.

### 6. Phone (stage 2)

- **Tab.** **Inbox** (`tray`), placed second: Now, Inbox, Workbench, Calendar (ask #1349). `RootTabView.Tab.inbox`. The badge is the sum of the folders' `waiting`, in orange (ask #1349). Unread artifacts show as dots and are not counted in the badge.
- **Models.** Every string lives in a model, and each model has a test:
  - `InboxRootModel`: pinned Needs approval, folders and root entries, in the feed's order.
  - `InboxFolderModel`.
  - `InboxCardModel`: header line, document state, action states, bottom bar.
  - `InboxRefRowModel`: native actions per kind, busy, error, **Retry**.
  - `InboxApprovalModel`: without `permissions` it shows "Approve on the Mac".
  - `InboxTabState`: `loading`, `empty`, `content`, `macTooOld`, `policyOff`.
- **Renderer.** `PhoneArtifactView` in `WatchtowerMobile/Sources/DesignSystem/Artifacts/`, over the Kit `ArtifactDocument`, built from phone parts:
  - heading and text (markdown);
  - metrics (2- or 3-up);
  - list (FlatRow, tone pill, ref actions);
  - table (sideways scroll inside a card);
  - person (avatar from initials, no network);
  - link (`openURL`);
  - actions.
  - Tones map only through `PhoneTone.artifact(_:)`, which matches Kit `Tone.artifact`.
- **Gestures.**
  - Ref rows: swipe left for Done and Snooze, swipe right for Hide. Per kind, a track gets Done and Stop, and a reminder gets Done and Snooze 1h.
  - The context menu carries the full verb set and is also the accessibility path.
  - Tapping a row pushes its detail.
  - Reply… opens a sheet with "Propose", and its line says the reply goes to Needs approval.
- **Optimistic hide, never optimistic success.** A pressed row shows busy. On `applied` it hides locally until a publish either leaves it out or reopens it, for at most 2 publishes. After that the hub's state wins. On a refusal the row comes back with the Go sentence and **Retry**. An action queued while the Mac is away shows in the existing outbox lines ("Waiting to send", "Not delivered").

### 7. Failure modes

- **`inbox feed` fails or hangs on the Desktop.** The client passes a 10 s timeout to `CLIRunner` (it has no default) and the runner kills the process at the limit. The Desktop keeps the last list and shows the §7 line with **Retry**. Test: `InboxFeedClientTests` with a failing and a hanging stub CLI, which reaps its process group.
- **`inbox act` fails on the Desktop.** The row keeps the sentence and **Retry**, and nothing is marked done. Test: `InboxActionClientTests` with a refusal and with a non-zero exit.
- **The process dies mid-write** (CLI killed, daemon stopped, Mac restarted). Each `Apply` is one transaction, so nothing is half written, and the next feed shows the true state. Test: a fault seam in every Go writer test, plus a kill-between-statements case per writer with a cascade (track done, reminder approval hook).
- **The hub stops mid-action.** A non-idempotent kind left `begun` answers `outcome_unknown`. The phone shows "Didn't confirm — check on the Mac" on that card and never re-sends it. Guarded kinds re-apply safely. Test: hub order tests with a crash between begun and done.
- **The Mac restarts with phone actions queued.** The outbox re-sends, and `relay_processed` keeps them exactly once. Test: the replay suite gains the new kinds.
- **The phone is killed with queued actions.** The outbox is persistent. Test: an outbox wiring test with an Inbox kind.
- **Stale card.** A different `content_hash` answers `changed`. Both clients show "This card changed — look again" and redraw. Test: a stale-hash case per hash-guarded action in `inbox_writes.json`.
- **Approval arguments changed.** `args_changed` comes back, and the card is redrawn with its line. Test: an `Apply` test.
- **Writers of the same rows and who wins.** After stage 1 every writer is Go code through `Apply` or the daemon:
  - the Desktop (via the CLI);
  - the hub (phone actions);
  - the daemon (living rewrites, automation runs, approval apply);
  - the existing CLI verbs.

  Whoever commits first wins. A later guarded write is a no-op that answers `already`. A living rewrite with a new hash clears read, done and dismiss (A's rule), so a Done on the old hash answers `changed`. Test: a race test per action that runs two `Apply` calls from two connections on one database file and checks that one is `applied` and the other `already` or `changed`.
- **Policy tightened while cards are on the phone.** The hub deletes the published Inbox records (POLICY-03), and the tab shows "The Inbox stays on your Mac". Test: a policy test in `sources`.
- **The feed is too big for the CLI pipe.** Output is streamed JSON with no size limit, and the Desktop reads it to the end. Test: a fixture with a 128 KB block card for each of 300 cards.

### 8. Stage 3: the Desktop's chat writes in Go

**Today.** The Desktop spawns `ai session --conversation N …` per conversation (`ChatSessionPool`, three warm processes) and reads its events from stdout (`ChatSessionClient`). Swift writes every chat row:
- the turn start: `ChatViewModel.persistTurnStart` (lease, owner row, attachment links, prefix title, routing, empty `partial` assistant row);
- the turn's progress and end: `ChatTurnDriver` through `ChatTurnStore` (text flushes, steps, status, artifacts, session id, lease heartbeat and release);
- the rest: conversations, branches, read marks, projects and their sources, artifact comments, queued drafts, knowledge artifacts.

`internal/chatstore` already has the Go twin of the turn writes and of the conversation writes, kept equal by `chat_turn_cases.json` and the other #1791 fixtures.

**After stage 3.**
- **`ai session --persist`.** The same process the Desktop already keeps warm saves the turn itself through `chatstore`: `Start`, `Turn.Apply/Flush/Finalize`, the lease heartbeat and release. The Desktop's stdin `turn` request gains the start fields `persistTurnStart` writes today: the text, the attachment ids, the parent or edit target, the mode and the quote batch. The process answers with a `started {conversation_id, owner_message_id, assistant_message_id, turn_id}` event before its first delta. A lease the hub holds answers `refused {reason: "conversation_busy", holder}`, and the composer shows the holder's line and gives the draft back, as it does today.
- **The live view is unchanged.** The Desktop keeps drawing the answer from the stdout events as they arrive, as today, and reloads the rows from the database at `started` and at the end. The owner's bubble shows at once from the draft, as it does now, and is replaced by the saved row at `started`. Stop is the existing stdin `cancel`. Remote Stop through `cancel_requested_at_ms` is read by the process itself, so the Desktop's 1 s lease poll goes away.
- **Other chat writes** go through the CLI: `watchtower chat new|pin|rename|delete|branch|read|project …|comment …|draft …` over `chatstore` and new Go writers where `chatstore` has none yet (projects and their sources, artifact comments, queued drafts, knowledge artifacts). Each new Go writer is ported from its Swift query and pinned by a case in a shared fixture until the Swift writer is deleted.
- **Attachments** are saved by `chatstore.SaveAttachment` through `watchtower chat attach` before the send, with the Mac's validator.
- **Deleted in Swift:** `ChatTurnStore`, the write half of `ChatTurnDriver`, `persistTurnStart`, `releaseEarlierLaunchesChatLeases` (the CLI's start-up sweep takes it over), and every `INSERT`/`UPDATE`/`DELETE` on a `chat_*` table. A Core guard test fails on any such statement left under `WatchtowerDesktop/Sources`. The embedded chats (target brief, Discuss, tuning, the automation editor) run the same `--persist` path with their `--surface`.
- **Contracts.** CHAT-01, CHAT-02, CHAT-03, CHAT-05 and LIVE-01 (`docs/inventory/chat.md`) keep their meaning. Their guard tests move to Go with the same names where their subject moves, and are not weakened.

**UX kept, and how it is checked** (ask #1361):

| What the owner feels | Today | Rule after stage 3 | Check |
|---|---|---|---|
| Time from Send to the owner's bubble | at once (draft) | at once (draft), unchanged | `ChatViewModel` test: the bubble is shown before `started` |
| Time from Send to the first answer text | process stdout | the same stdout; `chatstore.Start` runs before the provider call, as `persistTurnStart` did | `BenchmarkPersistStart` ≤ the Swift start on the same fixture; a scripted stub-provider timing test, Desktop before and after, median not worse by more than 20 ms |
| Live text cadence | every stdout delta | every stdout delta, unchanged | the event path is unchanged; the stream test from `ChatSessionClient` stays |
| Stop | stdin `cancel` | the same | the existing Stop tests |
| Warm sessions | pool of 3 | pool of 3, unchanged | the existing pool tests |
| Pin, rename, delete, branch, read | a GRDB write, about 1 ms | a CLI call; the row changes at once in the view, and a refusal brings it back with its sentence | `BenchmarkChatCLIVerb` median ≤ 120 ms; a refusal test per verb |
| A send survives a crash (CHAT-01) | the owner row commits before the provider runs | the same order inside the process; the Desktop keeps the draft until `started` | the CHAT-01 guard test, moved, plus a kill-before-`started` test |

If the timing check fails for a path, that path does not switch until it passes. Owner-facing speed is a gate, not a goal.

**Failure modes (stage 3).**
- **The session process dies mid-turn.** Today the Desktop marks the row. After stage 3 the Desktop runs `watchtower chat recover --conversation N --turn T`, which marks the row `session_lost` and releases the lease, the same as the hub's `Sweep`. When the CLI call also fails, the next app launch's sweep does it. Test: kill the stub process after `started`; the row ends `session_lost` and the lease is free.
- **The process dies before `started`.** Nothing was written, the Desktop still has the draft, and it shows the existing "The chat session ended unexpectedly" card with the draft back in the composer. Test: kill before `started`.
- **The app quits with turns running.** The processes are in the app's process group, as today. The CLI's start-up sweep releases the leases they held. Test: the sweep releases a lease whose owner process is gone.
- **The hub and the Desktop race for one conversation.** The lease decides, as today (first commit wins). Now both writers are `chatstore`. Test: `chat_lease_cases.json` plus a two-process start race.
- **An old `ai session` without `--persist`.** It cannot happen within one bundle. A test still asserts that the Desktop refuses to start a turn when the process does not answer `started` within 10 s, and shows the session-ended card with the draft kept.

### 9. Docs

- `docs/features/inbox-folders.md` and `inbox-card-blocks.md`: the builder and the writers are in Go.
- A new `docs/features/inbox-core.md`: `inboxfeed`, the feed, `Apply`, the CLI. It gets a CLAUDE.md line and a README summary.
- `docs/features/mobile-companion.md` gains an Inbox section, and `docs/features/go-hub.md` the new kinds and actions.
- The protocol spec tables (§6.2, §7.2, §9).
- `docs/inventory/` entries re-pointed (§4).
- `docs/guide`: the iPhone page gains the Inbox.
- `docs/features/chat-redesign.md` (its **Writers** line), `embedded-chat.md` and `iphone-chat.md`: the Desktop's chat writes are in Go; `docs/inventory/chat.md` guard tests re-pointed.

### 10. Shots

- Stage 1: the Mac's Inbox `DesignShotCatalog` shots, taken before and after the switch, match. The three `inbox-feed-*` states match mockup §7.
- Stage 2: `ScreenshotTourTests` `inbox-*` match mockup §§1–6. `DemoSeed` gains the sample Inbox the shots need.

## Promises → tasks → tests

| Promise | Stage / task | Test |
|---|---|---|
| Go builds the Mac's list exactly | 1 / core builder + parity | `inbox_feed_cases.json` (Swift and Go during the port, Go golden after) |
| Counts as the Mac's | 1 / core builder | `inbox_counts` cases in the same fixture |
| Needs approval picks the Mac's card | 1 / core builder | APPROVAL-01 guard tests moved to Go |
| Every Inbox write is one Go function with Swift's guards | 1 / Go writers | `inbox_writes.json` (Swift and Go during the port), fault seams |
| No Swift Inbox writer left | 1 / Desktop switch | Core guard test over `Services/Inbox` and `Views/Inbox` |
| The Mac Inbox looks the same | 1 / Desktop switch | DesignShot before and after |
| Mac load and action failures are honest | 1 / Desktop switch | `InboxFeedClientTests`, `InboxActionClientTests`, `InboxFeedStateModelTests` |
| Feed is fast enough | 1 / benchmark | `BenchmarkInboxFeedBuild` against the budget |
| Race between writers | 1 / Go writers | two-connection race test per action |
| Phone sees the same folders and rows | 2 / hub sources | sources tests over the Go golden; Kit mirror tests |
| Same blocks drawn | 2 / phone renderer | Kit `ArtifactBlocksTests` fixture through `PhoneArtifactView` snapshots |
| Native actions per ref kind | 2 / hub actions + phone | handler tests per kind; `InboxRefRowModelTests` |
| Approve pins args, needs `permissions` | 2 / hub actions | `approval_decide` mismatch and no-grant tests |
| A failed write keeps the row | 2 / phone | `InboxRefRowModelTests` refusal case |
| Exactly once | 2 / hub actions | order and replay tests with the new kinds |
| Phone states and copy | 2 / phone | `InboxTabStateTests`, every string in a model |
| Policy off | 2 / hub sources | policy test |
| No Swift chat writer left | 3 / Desktop chat switch | Core guard test over every `chat_*` write |
| Chat UX not worse | 3 / benchmarks | `BenchmarkPersistStart`, `BenchmarkChatCLIVerb`, stub-provider timing before and after |
| A send survives a crash | 3 / `--persist` | CHAT-01 guard moved, kill-before-`started` test |
| A dead session is cleaned up | 3 / `chat recover` | kill-after-`started` test, start-up sweep test |
| Chat contracts kept | 3 / Desktop chat switch | CHAT-01/02/03/05 and LIVE-01 guards, moved with their names |
| Shots match the mockup | 1 and 2 | DesignShot `inbox-feed-*`; `ScreenshotTourTests` `inbox-*` |

## Decisions

- The Inbox on the phone is for clearing it on the go — ask #1326.
- Every section, as an adapted copy of the Mac's Inbox — ask #1326.
- A separate tab — ask #1326.
- The hub builds ready cards (approach A) — ask #1332.
- Only the Go hub — ask #1332.
- The Inbox works the same on the Mac and the phone; all logic and writes live on the tower — ask #1348, with the perimeter agreed in ask #1356.
- Legacy entries stay until C, and plan items can be checked from the phone — ask #1348.
- Stages: Go core with the Desktop on it, then the phone — ask #1356.
- The Desktop reads the feed through `inbox feed --json` — ask #1356.
- The tab is second, after Now — ask #1349.
- The badge counts only what waits on the owner — ask #1349.
- Approve and Retry from the phone need the `permissions` grant — ask #1349.
- Management, chat and agent stay on the Mac; no push in v1 — ask #1349.
- The Desktop's chat writes move to Go in this work, with the condition that the user's UX must not get worse — ask #1361.
- The Desktop's warm `ai session` process saves the turn (`--persist`), and the daemon's hub runner does not run Mac turns — decided by the agent, under ask #1361's condition.
- Speed is a gate: a path whose timing check is worse does not switch — decided by the agent.
- Reply needs `typing`; every other Inbox action needs no grant — decided by the agent, as for board writes.
- Legacy entries are typed sections for the Desktop and block projections for the phone, so the Mac does not change — decided by the agent.
- Each client hides closed ref rows itself from `ref_facts`; the feed carries `blocks` unchanged — decided by the agent.
- 300-card cap on the phone, with Needs approval and Waiting for me first — decided by the agent.
- One `ref` action with a `verb`, instead of one kind per verb — decided by the agent.
- `inbox act` reads its request as JSON on stdin, and a refusal exits 0 — decided by the agent.
- Feed speed budget of 150 ms median on the fixture; over budget means a per-folder read, never a cache table — decided by the agent.

## Left to the builder

- The file split inside `internal/inboxfeed` and under `sources`.
- The order of the plan's tasks inside each stage.
- The phone file layout inside `Features/Inbox/`.
- Fixture file locations: next to their Go owners, as `open_items.json` is.
- The exact refresh trigger the Desktop already uses for the Inbox. The new client hooks into it and adds no new observer.
