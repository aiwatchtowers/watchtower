# Phone Inbox on one tower interface: the Inbox and its writes in Go, drawn by the Mac and the iPhone (design)

Target #1170. This is sub-project F ("Phone renders blocks") of the Inbox builder umbrella (`docs/superpowers/specs/2026-11-02-inbox-builder-design.md`). It builds on sub-project A (`docs/features/inbox-card-blocks.md`) and sub-project B (`docs/features/inbox-folders.md`). The parts it touches are documented here:
- The hub is the Go hub (`docs/features/go-hub.md`).
- The phone is `WatchtowerMobile/` (`docs/features/mobile-companion.md`).
- Chat on the tower is #1791 (`docs/features/iphone-chat.md`).

Mockups are in `docs/design/mockups/mobile-inbox/index.html`, with every state in dark and light. Sections 1–6 cover the phone, and section 7 covers the Mac's new states. After the build, each phone frame becomes a `ScreenshotTourTests` shot named `inbox-…`, and each Mac frame becomes a `DesignShotCatalog` shot named `inbox-feed-…`. Both are compared with the mockup before review (§11).

## Intent

The owner wants to clear the Inbox on the go: open the phone, act on what waits (approve, reject, mark done, snooze, hide, reply) and put it away. The phone shows an adapted copy of the Mac's Inbox, with every section, in its own tab (ask #1326).

The Inbox must work the same on the Mac and on the phone (ask #1348). Today the Inbox list is built only in Swift, and most of its writes are Swift-only.

This design moves the line:
- **Logic and writes live in Go on the tower.** The tower is the daemon, the CLI and the hub, and it also runs with no Desktop (ask #1356).
- **One interface on top serves both clients.** It is one contract generated from Go, one Swift client and one set of screen models. Only the SwiftUI views differ between the Mac and the iPhone (ask #1362).
- **How each client reaches the tower.** The Mac reaches it over a local socket of an always-on daemon (ask #1362), and the phone reaches it through the hub.
- **Chat follows the same line.** The Desktop's Swift chat writer moves onto the Go one #1791 built, and the owner's chat UX must not get worse (ask #1361).

## Goals

- **The tower interface.** Commands whose request and response types are defined once in Go. A generator writes the Swift types, and CI fails when the generated Swift and the Go types differ. Every write carries an idempotency key, and the same Go code gives both transports exactly-once delivery.
- **`WatchtowerInterface`.** A Foundation-only Swift package that both apps use. It holds:
  - the generated types;
  - `TowerClient`, with one state machine for loading, stale, refused, unknown outcome and offline;
  - the screen models, with every user-facing string and their tests.
- **An always-on daemon.** While the app runs, the daemon serves the tower socket. Stopping sync from the tray pauses sync and leaves the daemon running. The few restarts that remain (a new binary, an exclusive database step) show "Reconnecting…", not an error.
- **The Inbox core in Go** (`internal/inboxfeed`). It builds the root, the folders, their order and counts, Needs approval, Waiting for me, card texts, ref facts and the legacy root entries. It also applies every Inbox action.
- **The Desktop on the interface.** The Inbox looks the same, except for the states in mockup §7. Every other Mac screen that writes the same rows also writes through the interface: Home, Ideas, Digests, Tracks, CatchUp, Day plan, Quick capture and Decisions (ask #1362). The Swift builders and writers these replace are deleted.
- **An Inbox tab on the iPhone**, placed second (ask #1349). It shows the same feed through the hub:
  - the root, Needs approval and the owner's folders, up to three levels deep, each with the Mac's count;
  - every artifact drawn from the same block JSON;
  - on each `ref` row, the native actions of its kind, plan-item checks included (ask #1348);
  - Needs approval following APPROVAL-01, where Approve pins the arguments the owner saw and needs the `permissions` grant (ask #1349).
- **The Desktop's chat writes in Go.** The live stream, Stop, warm sessions and speed stay the same (ask #1361).
- **Honest states on both clients:**
  - loading;
  - empty, and an empty folder;
  - a failed load and a failed action, each with **Retry**;
  - "Didn't confirm";
  - reconnecting (Mac);
  - the Mac away, and not delivered (phone);
  - a tower too old;
  - organization policy.

## Non-goals

- **Managing the Inbox from the phone.** Folders, routes, recipe editing, turning automations on or off, and Delete stay on the Mac (ask #1349). Folder management is already in Go (`inbox folders …`) and is outside this work.
- **Mac-only actions on the phone.** Discuss in Chat, Hand to Agent, the `chat`/`agent` card actions, Open Draft (`save_automation`) and Edit… on a proposal are drawn disabled with "On your Mac" (ask #1349).
- Push notifications for new Inbox cards are not in v1 (ask #1349).
- Learned Rules, Assistant Profile and the reaction cheat sheet are not on the phone.
- The phone gets no renderers for block types beyond A's v1 set.
- **The read side of screens other than the Inbox** (Home's own open-row query, for example). Those screens switch their writes only (ask #1362). Their reads are a follow-up target.
- **New chat features.** Stage 3 changes only who writes the Mac's chat rows.
- **Sub-project C.** The legacy root entries stay until C (§4.4).
- **Shared SwiftUI views.** Each platform keeps its own views (ask #1362).

## Anti-goals

- Two implementations of one rule or one write. After this work, no Swift code decides an Inbox rule (which rows are open, what a folder counts, which card Needs approval shows, what a card says), and no Swift code writes a moved table.
- A row that looks done while its write failed, or a closed row that comes back from a stale publish or a stale feed.
- An approval that goes through for arguments the owner did not see.
- A Mac that silently changes. The Inbox look and behaviour stay as they are, apart from mockup §7. Chat must not get slower or lose anything: no later first text, no slower Stop, no cold process where a warm one was, and no send that can be lost (CHAT-01) (ask #1361).
- A phone holding more of the owner's data than the Inbox shows.
- A dev build that talks to a daemon of another interface version.

## Constraints

- **Wire.** The wire is additive (protocol spec §8). `slices.AllKinds`, `secure.dataKinds` and the Kit `SliceKind` change together. `handlers.NudgeTable` is pinned to `hub_contract_cases.json`. The legacy names `inbox_item` and `inbox_resolve`/`inbox_dismiss`/`inbox_snooze` stay unused.
- **Size.** An envelope is at most 900 KB. A block document is at most 128 KB canonical, so one card is one record.
- **Guards.** The read, done and dismiss marks stay guarded by `content_hash` (A). Every Go writer keeps its Swift writer's guard.
- **Policy.** Under MDM `MobileSync = workbench_only`, the hub publishes no Inbox kinds (POLICY-03).
- **Write transactions.** They are `BEGIN IMMEDIATE` and short. No rendering, LLM call or network call runs inside one. A new migration follows the `add-migration` skill.
- **Dependencies.** `WatchtowerCore` stays Kit-free (`PublicAPISurfaceTests`). It may import `WatchtowerInterface`, which, like `WatchtowerChatText`, depends on Foundation only.
- **Design rules.**
  - Phone: flat rows, cards only for waiting items and detail blocks, orange only for waiting-for-you, and no row separators outside a card.
  - Desktop: `docs/design/desktop-style-guide.md`.
  - Both: colours only through Tone, and every string in a model with a test.

## Approaches

**Where the logic lives:**
- **One core in Go, with both clients thin (chosen, asks #1348 and #1356).**
- A Go twin kept equal to Swift by fixtures. That means two implementations forever. Rejected (ask #1348).
- Raw rows sent to the phone, with cards built there. Rejected (ask #1332).

**How much the clients share (ask #1362):**
- **The contract, the client and the screen models (chosen).** The SwiftUI views stay per platform, because the Mac and phone layouts differ (see the mockups).
- The views as well, as one adaptive renderer. Less code, but the Mac and the phone would converge in look.
- The contract only. Each client would keep its own screen models, and texts and states would drift.

**How the contract is kept in step (ask #1362):**
- **A generator writes Swift types from Go types (chosen).** CI fails on a difference.
- Hand-written types pinned by shared JSON fixtures (today's way).
- A separate schema file (protobuf or JSON Schema).

**How the Mac reaches the core (asks #1356 and #1362):**
- **A local socket on an always-on daemon (chosen, ask #1362).** There is no process spawn per call, and the daemon can push change events. The cost is that the daemon must be up, so stopping it becomes pausing sync (§3).
- A CLI process per call (ask #1356's first answer, replaced by ask #1362). It works without the daemon, but every refresh and every action pays for a process start.

**How the Mac's chat turn reaches Go (ask #1361):**
- **The Desktop's own warm `ai session` process saves the turn (chosen).** The live stream comes from stdout, as today.
- The daemon's hub runner runs Mac turns. The Mac would see about one database re-read per second, and it would share the hub's pool of 2 with the phone. Rejected because the UX would be worse.

## Design

### 1. Stages

0. **The interface and the always-on daemon** (§2, §3). This stage adds the command layer, the request ledger, the generator, `WatchtowerInterface`, the socket, and pause instead of stop. No screen changes. A `tower.ping` command proves the path end to end.
1. **The Inbox core, with the Mac on it** (§4, §5). This stage adds `inboxfeed` and the Go writers. It moves the Desktop Inbox and the other screens' writes onto `TowerClient`, then deletes the Swift builders and writers.
2. **The phone** (§6, §7). This stage adds hub sources and actions over the same commands, and the phone tab following mockup §§1–6.
3. **The Desktop's chat writes in Go** (§8).

Stages 1 and 3 depend on stage 0, and stage 2 depends on stage 1. Stage 3 may run in a parallel lane alongside stages 1–2.

### 2. The tower interface

#### 2.1 Commands (Go, `internal/tower`)

- **Registration.** A command is a name (`domain.verb`) with a request type and a response type in `internal/tower/api`. Each is registered in one table: `tower.Register(name, handler, Spec{Idempotent bool, Grant string, ChangeTables []string})`.
- **Commands by stage:**
  - Stage 0: `tower.hello` (the interface version and the build) and `tower.ping`.
  - Stage 1: `inbox.feed`, `inbox.watch` (a stream of `changed` events), `inbox.act`, and the write commands the other screens need: `tracks.*`, `ideas.*`, `reminders.*`, `briefing.read`, `dayplan.*`, `outputs.*` and `inbox_items.*`. Each write command is a thin entry over the same Go writer the Inbox uses (§4.3). The plan names each one from the list of Swift call sites (§5.2).
  - Stage 3: `chat.*` for the conversation-level writes (§8).
- **Envelope.** A request is `{v, id, command, params}`. A response is `{id, status: "ok" | "refused" | "unknown", result | refusal{code, sentence}}`. The `sentence` is written in Go, and both clients show it as is.
- **Exactly once, with one mechanism for both transports.** Every write command carries `request_id`, a UUID the client makes and keeps across retries. `tower.Call` records it in the new table `tower_requests` (`request_id` PK, `command`, `state` `begun`|`done`, `result_json`, `at`), added by migration `NNNNN_tower_requests` and pruned after 24 h.
  - A guarded command writes its result row in the same transaction as its writes, so `done` exists exactly when the write committed.
  - A non-idempotent command commits `begun` in its own short transaction before it acts. The non-idempotent commands are approve, retry, Run Now and the `reply` press.
  - A repeat of a `done` id returns the stored result.
  - A repeat of a `begun` id answers `unknown` for a non-idempotent command and re-runs a guarded one.
  - The hub's `relay_processed` still guards envelopes. This ledger guards the command below them.
- **Long work leaves the call.**
  - Approve and retry mark the row and return. The tool runs in the daemon, as the hub's background apply does today, and its outcome shows in the next feed as the card's status.
  - The `reply` press stores the reply proposal and returns.
  - No command holds a socket call or a write transaction across network or LLM work.

#### 2.2 The generator

- **What it writes.** `go run ./internal/tower/gen` (`make gen-interface`) reads the registered request, response and model types by reflection. It writes Swift `Codable` structs into `WatchtowerInterface/Sources/WatchtowerInterface/Generated/`:
  - Field names come from the JSON tags.
  - Optional fields come from `omitempty` and pointers.
  - String enums get an `unknown(String)` case, so an older client still decodes a newer value.
  - Every file starts with a `// Code generated … DO NOT EDIT.` header.
- **The CI check.** `make gen-interface-check` regenerates into a temporary folder and diffs. It runs in CI's Go job and in `make lint-all`.
- **Golden files.** Golden JSON for every type lives in `internal/tower/api/testdata/*.json`. The generator also writes a Swift test that decodes and re-encodes each golden file, so one fixture set proves both sides.
- **The interface version.** `tower.InterfaceVersion` is a hash of the generated output. `tower.hello` returns it, and the generated Swift carries it as a constant.

#### 2.3 `WatchtowerInterface` (Swift package, Foundation only, macOS 14 / iOS 17)

- **Generated types.**
- **`TowerClient`.** An actor over a `TowerTransport` protocol (`call`, `watch`), with one state machine for every screen: `idle`, `loading`, `ready(stale: Date?)`, `reconnecting`, `failed(sentence)`.
  - Each action has the states `busy`, `refused(sentence)` and `unknown`.
  - In the `unknown` state the client shows "Didn't confirm — check again". It refreshes and never re-sends a non-idempotent call.
  - The client makes the `request_id` for each press and keeps it until a final answer arrives.
- **Screen models.** `InboxRootModel`, `InboxFolderModel`, `InboxCardModel`, `InboxRefRowModel`, `InboxApprovalModel`, `InboxTabState` and `TowerText` (every string), each with tests.
  - The Mac and the phone both bind to them.
  - Platform differences are inputs to the models (`Platform.mac`/`.phone`, the grants), never forks in the views.
- **Transports.** `SocketTransport` lives in WatchtowerCore (§3). `HubTransport` lives in the phone app (§7), because it needs the Kit.

### 3. The always-on daemon and the socket

- **The socket.** The daemon (`watchtower sync --daemon`) serves `<workspace>/tower.sock`. The socket has mode 0600 inside a 0700 directory, and the daemon checks the peer's uid, as the hub's control socket does. Frames are newline-delimited JSON (§2.1). The same process runs the hub, so the Mac and the phone reach one `tower.Call`.
- **The handshake.** The client sends `tower.hello`. When the interface version differs:
  - A Desktop that started the daemon from its own CLI (`DaemonManager`, the CLI store) restarts it from that CLI. A dev build therefore always gets a daemon of its own version, the way `ensureDaemonRunning` already replaces a stale daemon.
  - When the client cannot restart the daemon, it shows "Watchtower's background service is a different version" with **Restart**.
- **Pause, not stop.** The tray's stop, and every in-app stop whose purpose is "no sync running", become `sync.pause` and `sync.resume` over the socket. The process, the socket, the hub and the Inbox keep running.
  - These stops become pauses:
    - Slack disconnect (`SlackConnectionDetail`);
    - the onboarding finish (`OnboardingFinishPlan`);
    - the data reset (`stopWipeRestart`), which pauses, wipes and resumes. Its wipe waits for the running cycle to end, as today it waits for the process.
  - The daemon still stops or restarts in these cases:
    - a new binary (`CLIBinaryStore`, an app update);
    - the launch compaction (`db compact`, which needs the file alone; the app's window is not up yet);
    - quit;
    - a crash, after which the app's existing start queue restarts it.
- **Reconnecting.** While the socket is down, `TowerClient` is `reconnecting`. It retries after 0.2 s, doubling the wait up to 2 s.
  - After 15 s it moves to `failed` with "Watchtower's background service isn't running" and **Retry**. Retry also asks the start queue to start the daemon.
  - A pressed action waits in `busy` during reconnecting and is sent with its `request_id` when the socket is back. After 15 s it fails with **Retry**.
- **Change events.** `inbox.watch` pushes `changed` when a table in the Inbox's `ChangeTables` changes. It uses the daemon's existing `data_version` watch, the one the hub's publisher uses. The Desktop Inbox stops observing the database itself.

### 4. The Inbox core: `internal/inboxfeed`

#### 4.1 What moves from Swift

| Swift today | Go after stage 1 |
|---|---|
| `InboxFolderEntries.build`, `InboxListBuilder`, and the list and counts part of `ActionStripViewModel` | `inboxfeed.Build` |
| `InboxFolderCounts` with `legacyCounts` | `inboxfeed` counts |
| `NeedsApprovalSelection` (APPROVAL-01) | `inboxfeed` approvals, with a new reader across all automations next to `db.ReadApprovalsView`, which reads one automation |
| `InboxCardTexts`, `InboxCardSubject`, `InboxCardNotice`, `SaveAutomationProposalSummary` | `inboxfeed` texts. `InboxCardTexts.preview` (used by `ChatPanelRow`) and `targetTitleLimit` (used by `WorkbenchNewTargetSheet`) stay as a small Swift remainder outside the Inbox |
| `InboxRefState` (its track and idea parts), `InboxReplyPolicy` | `inboxfeed` ref facts, reusing `db.OpenInboxItems` and the open-approvals reader |
| `InboxTargetButtonFacts`, the `InboxCardAction` button states | `inboxfeed` action states |
| The legacy root entries | `inboxfeed` legacy sections (§4.4) |

These stay as Mac views over the screen models: `InboxFolderMenuModel`, `InboxFolderListContent`, `NeedsApprovalNoteContent`, `InboxArtifactMenuModel`, `InboxFolderIcons`, `WatchTrackControls`, `RecipeCustomTrackControls` and `InboxAgentHandoff`. Handoff to chat and to the agent stays on the Mac.

`Build` runs in one read-only transaction, so every count and row comes from one snapshot. It writes nothing.

#### 4.2 The feed (`inbox.feed`)

- **The feed:** `Feed{v, built_at, folders[], cards[], more}`.
- **A folder:** `{id, kind (root|approvals|owner), slug, title, icon, parent_id, position, count, waiting}`. `waiting` is the part of `count` that waits on the owner: open approvals, plus open rows with a `ref` that wait.
- **Card ids** are typed so that they never collide: `o<output>`, `a<action>`, `r<reminder>`, `n<builtin migration>`, `brief-<date>`, `tracks`, `ideas`, `thread-briefs`, `messages`.
- **A card** has these fields:
  - `folder_id` and `card_kind` (`artifact`, `approval_native`, `reminder`, `notice` or `legacy`);
  - `title`, `source_line`, `preview`, `stamp`, `living`, `unread`, `priority`, `pinned`;
  - `automation` `{id, name, builtin_id, run_id}`;
  - `blocks`: the stored bytes, or `""` for a markdown card;
  - `body`: clipped to 16 KB, with `body_clipped`, when `opts.Clip` is set (the phone sets it);
  - `content_hash`: on a native approval, its args SHA-256;
  - `actions[] {index, kind, label, state}`;
  - `ref_facts {open, waits, reply, reply_waiting, link}` for each ref;
  - `approval {tool, title, summary, args_sha256, status, error, proposer, reason, edit_on_mac}`, on approvals only;
  - `legacy`, on legacy cards only.
- **Closed refs.** Rows whose ref is closed stay in the document, and the screen models hide them by `ref_facts.open`.
- **Options.**
  - `opts.Folder` narrows the feed to one folder.
  - `opts.Limit` (300 on the phone, none on the Mac) keeps Needs approval and Waiting for me first, then the rest newest first, and counts what is left out in `more`.

#### 4.3 Writes (`inbox.act` and the screens' write commands)

`inbox.act` takes `{request_id, target, verb, params}`:

| Verb | Target | Params | Write (the Swift guard is kept) |
|---|---|---|---|
| `read` | `o…`, `brief-…`, `r…`, `n…` | `content_hash` | Output `read_at`, guarded by hash; briefing `read_at`; `inbox_items.read_at` |
| `done`, `dismiss` | `o…` | `content_hash` | Output `done_at`/`dismissed_at`, guarded by hash, open rows only |
| `press` | `o…` | `index`, `content_hash`, `text` | `reply`: stores the reply proposal (`ErrOutputChanged` → `changed`). `target`: the `create_target` propose path |
| `run_now` | `o…` | none | The function behind the `automation_run` action kind, where `Entry.RunNow`. Non-idempotent |
| `ref` | any card | `ref_kind`, `ref_id`, `ref_verb`, `until` | See the list below |
| `reply_propose` | any card | `ref_id`, `text` | `InsertInboxReplyProposal` (`ErrReplyAlreadyWaiting` → `reply_waiting`) |
| `approval` | `a…` | `approval_verb` (`approve`/`reject`/`retry`/`dismiss`), `args_sha256` | `Registry`, pinned to the SHA (a mismatch → `args_changed`). Approve and retry are non-idempotent and run the tool afterwards in the daemon (§2.1) |

The `ref` verb writes by ref kind:
- `inbox_item`: resolve, dismiss, snooze.
- `track`: done (with its read cascade), stop, restore, and `make_task` (the `apply_track_action` propose path, as `TrackActionPress` does).
- `idea`: approve, reject, not now.
- `reminder`: done, snooze (with the approval hook).
- `plan_item`: check, uncheck (`day_plan_items.status`, with `DayPlanQueries.cascadeTaskStatus`'s cascade).

- **Answers.** The refusal codes are `not_found`, `changed`, `args_changed`, `reply_waiting`, `not_permitted` and `unsupported`. A guarded no-op answers `ok` with `already: true`.
- **Go writers.** Each one is ported from its query in `WatchtowerCore/Database/Queries`:
  - `AutomationQueries.markOutputDone`/`dismissOutput` and the output read mark;
  - `TrackQueries.markRead`/`restore` and track stop;
  - `DayPlanQueries`, `ReminderQueries`, `InboxQueries` and `BriefingQueries`;
  - the idea writers in `IdeaQueries`.
- **Shared fixture.** While both exist, `inbox_writes.json` runs every case through the Swift writer (a Core test) and the Go writer (a Go test). The Swift side is deleted with the Swift writer, and the fixture stays as the Go golden.
- **One writer.** A Core guard test lists the moved tables and columns. It fails on any Swift `INSERT`, `UPDATE` or `DELETE` to them anywhere under `WatchtowerDesktop/Sources`.

#### 4.4 Legacy root entries (ask #1348)

Until sub-project C, the feed carries each legacy entry as a typed `legacy` section `{kind, items[]}`:
- Morning brief, per date, under the Mac's unread rule;
- Track my threads, with stopped tracks flagged `stopped` inside the one card;
- Idea finder;
- Thread briefs;
- the Messages stand-in.

How each client draws them:
- **The Mac** draws them with its current views, so the Mac does not change.
- **The phone** gets them from the hub as block documents with `ref` rows (`inboxlegacy`, §6):
  - Morning brief, Track my threads and Idea finder look as in mockup §5.
  - Thread briefs become a list of thread rows that carry the `track` ref.
  - Messages becomes a notice card with its Mac text and "On your Mac".
- Plan items use the ref kind `plan_item`.
- C's PR deletes each section and its projection.

### 5. The Mac after stage 1

#### 5.1 Inbox

- **Binding.** The Inbox binds to the screen models over `TowerClient` with `SocketTransport`. It reads `inbox.feed` on open, on every `changed` event and on folder navigation. A change during a read marks the screen dirty, so at most one read runs at a time, with one more after it.
- **New states** (all strings from `TowerText`; mockup §7):
  - First load: a spinner.
  - A failed read keeps the last list and shows the reason with **Retry**. With no last list, it shows the line alone.
  - A failed action keeps its row with the sentence and **Retry**.
  - Reconnecting: the line "Reconnecting to Watchtower…" above the last list.
- **Speed budget.** On a fixture with 2 000 outputs, 200 approvals, 500 open items and 30 folders:
  - `inbox.feed` over the socket takes at most 100 ms median, and a write command at most 15 ms median (`BenchmarkInboxFeedBuild` and a socket round-trip benchmark).
  - Over budget, the first fixes are `--folder` reads and a counts-only mode. A cache table is never the fix.
- **Parity before the switch.** Swift `InboxListBuilder` and Go `Build` run over the same fixture databases, and their outputs are compared (`inbox_feed_cases.json`). The fixture then stays as the Go golden.
- **Shots.** The Mac Inbox's `DesignShotCatalog` shots, taken before and after the switch, match.

#### 5.2 The other screens' writes

These callers of the moved Swift writers call `TowerClient` write commands instead: `IdeasViewModel`, `DigestViewModel`, `TracksViewModel`, `DayPlanViewModel`, `HomeFeedActions`, `CatchUpViewModel`, `QuickCaptureView`, `IdeaDetailPane`, `DecisionsListView`, `ActionStripViewModel`, `Reminder` and `HomeLinksQueries`.
- The plan lists every call site from a grep of the moved writers' names. The guard test in §4.3 proves none is left.
- Their reads stay on GRDB, as today.
- Each screen shows busy, refused and reconnecting through `TowerClient`'s action states, with sentences from `TowerText`.
- A screen that refreshes after its GRDB write today refreshes after the command's `ok`.

#### 5.3 Inventory

Contracts in `docs/inventory/` that name a moved Swift type are re-pointed to the Go code in the PR that moves it. APPROVAL-01 is one of them. Their guard tests move to Go with the same `Test<Module>NN_` names, and no assertion is weakened.

### 6. Hub (stage 2)

- **Slices.**
  - `inbox_folder-<id>`: one record per visible folder.
  - `inbox_card-<id>`: one record per card, from `inbox.feed` with `Limit: 300, Clip: true`. A legacy card carries `blocks` from `inboxlegacy`, checked by `blocks.Validate` with a hub-only option that admits `plan_item`.
  - `ChangeTables` comes from the `inbox.feed` registration (§2.1).
- **Capability.** `wire.HeartbeatCapabilities` gains `inbox: "on" | "policy_off"`, with the reason `policy` under `workbench_only`. A missing key means an older hub, as it does for `chat`. The tab's copy names the hub ("Update Watchtower on <hub name>") through `TowerText`, so the copy is right on a server hub too.
- **One action kind, `inbox_act`.** Its params are the generated `inbox.act` request, and its handler calls `tower.Call`.
  - The dispatcher asks the registration whether a call is idempotent, by verb. That table is pinned in `hub_contract_cases.json`.
  - Grants (ask #1349): `permissions` for approve and retry; `typing` for `reply_propose` and for a `reply` press with text; none for everything else.
  - The handler nudges `inbox_card` and `inbox_folder`.
- **Building the feed.** The hub builds the feed outside any write transaction. A failed build keeps the last records and logs its error class.

### 7. Phone (stage 2)

- **The tab.** **Inbox** (`tray`), second: Now, Inbox, Workbench, Calendar (ask #1349).
  - The badge is the sum of the folders' `waiting`, in orange (ask #1349).
  - Unread artifacts show as dots only.
- **`HubTransport`.**
  - It answers `inbox.feed` from the slice store, putting the records together into the generated `Feed`.
  - It sends `inbox.act` through the outbox as `inbox_act`.
  - It maps the outbox's queued, not delivered, applied and refused states onto `TowerClient`'s.
- **What is shared and what is phone-only.** The screen models come from `WatchtowerInterface`. Phone-only are the views and `PhoneArtifactView` (in `WatchtowerMobile/Sources/DesignSystem/Artifacts/`, over the Kit `ArtifactDocument`). `PhoneArtifactView` draws:
  - heading and text;
  - metrics;
  - lists;
  - tables, with sideways scroll inside a card;
  - people, as initials;
  - links;
  - actions.

  Tones go only through `PhoneTone.artifact(_:)`.
- **Gestures.**
  - Ref rows: swipe left for Done and Snooze, swipe right for Hide. A track gets Done and Stop, and a reminder gets Done and Snooze 1h.
  - The context menu holds the full verb set, Make a Task included, and is also the accessibility path.
  - A tap on a row pushes its detail.
  - Reply… opens a sheet with "Propose".
- **Optimistic hide, never optimistic success.**
  - A pressed row shows busy.
  - On `ok`, the row hides until a publish leaves it out or reopens it, for at most 2 publishes.
  - On a refusal, the row comes back with the sentence and **Retry**.
  - Queued actions show in the existing outbox lines.

### 8. Stage 3: the Desktop's chat writes in Go

**Today.** The Desktop spawns warm `ai session --conversation N …` processes (`ChatSessionPool`, 3) and reads their events from stdout (`ChatSessionClient`). Swift writes every `chat_*` row:
- the turn start (`ChatViewModel.persistTurnStart`);
- the turn's progress and end (`ChatTurnDriver` through `ChatTurnStore`);
- conversations, branches, read marks, projects and their sources, artifact comments, queued drafts and knowledge artifacts.

`internal/chatstore` already has the Go twin of the turn and conversation writes.

**After stage 3.**
- **`ai session --persist`.** The warm process saves its own turn through `chatstore`: `Start`, `Turn.Apply/Flush/Finalize`, and the lease heartbeat and release.
  - The stdin `turn` request carries what `persistTurnStart` writes today: the text, the attachment ids, the parent or edit target, the mode and the quote batch.
  - Before its first delta, the process answers `started {conversation_id, owner_message_id, assistant_message_id, turn_id}`.
  - While the hub holds the lease, the process answers `refused {reason: "conversation_busy", holder}`, and the draft comes back with the holder's line, as today.
  - The process reads remote Stop (`cancel_requested_at_ms`) itself.
- **The live view does not change.**
  - The Desktop draws the answer from the stdout events, as today, and reloads the rows at `started` and at the end.
  - The owner's bubble shows at once from the draft.
  - Stop is the existing stdin `cancel`.
  - Embedded chats (target brief, Discuss, tuning, the automation editor) use the same path with their `--surface`.
- **Every other chat write goes through `TowerClient`.** The commands are `chat.new`, `pin`, `rename`, `delete`, `branch`, `read`, `attach`, `project.*`, `comment.*`, `draft.*` and `recover`. They run on `chatstore`, plus new Go writers ported from `ChatProjectQueries`, `ArtifactCommentQueries`, `QueuedDraftQueries` and the knowledge-artifact writes. Each new writer is pinned by a fixture case until its Swift writer is deleted.
- **Deleted in Swift:**
  - `ChatTurnStore` and the write half of `ChatTurnDriver`;
  - `persistTurnStart`;
  - `releaseEarlierLaunchesChatLeases` (the daemon's start-up sweep takes over);
  - every `chat_*` write. A Core guard test fails if one is left.
- **Contracts.** CHAT-01/02/03/05 and LIVE-01 (`docs/inventory/chat.md`) keep their meaning. Their guards move with their names and are not weakened.

**UX kept, and how it is checked** (ask #1361):

| What the owner feels | Rule after stage 3 | Check |
|---|---|---|
| The owner's bubble after Send | Shows at once, from the draft | A view-model test: the bubble shows before `started` |
| The first answer text | The same stdout stream. `chatstore.Start` runs before the provider call, as `persistTurnStart` did | `BenchmarkPersistStart` is no slower than the Swift start on the same fixture. In a stub-provider timing test before and after, the median is no more than 20 ms worse |
| Live text cadence | Every stdout delta | The existing stream tests |
| Stop | stdin `cancel` | The existing Stop tests |
| Warm sessions | A pool of 3 | The existing pool tests |
| Pin, rename, delete, branch, read | A socket write. The row changes once the answer arrives, and a refusal shows the sentence | The 15 ms socket budget (§5.1) and a refusal test per command |
| A send survives a crash (CHAT-01) | The owner row commits before the provider runs, and the Desktop keeps the draft until `started` | The moved CHAT-01 guard and a kill-before-`started` test |

A path that fails its check does not switch. Speed is a gate.

### 9. Failure modes

- **The daemon is down or restarting.** `TowerClient` goes to `reconnecting`, then to `failed` with **Retry**. A pressed action waits and is sent with the same `request_id` when the socket is back. Test: `TowerClientTests` with a transport that drops and returns, and one that never returns.
- **The daemon dies mid-command.** A guarded command has either committed with its ledger row or not committed at all, so a resend applies it or returns the stored result. A non-idempotent command left `begun` answers `unknown`, and the client shows "Didn't confirm — check again". Test: for both classes, a kill between `begun` and the write, and between the write and the reply.
- **A failure partway through a Go write.** Each write is one transaction, so a failure rolls it back. Test: a fault seam in every writer test, plus a kill-between-statements case for each writer with a cascade (track done, the reminder approval hook, the plan-item cascade).
- **Interface version mismatch** (a dev build against an old daemon). The handshake restarts the daemon from the client's CLI, or shows the different-version state. Test: `TowerClientTests` with a mismatched `hello`.
- **Another user reaches the socket.** The peer-uid check refuses the connection. Test: the same shape as the hub's control-socket test.
- **Sync is paused.** The Inbox and the writes keep working, but the feed's sync-driven content stops changing. Test: a daemon test that serves `inbox.feed` while paused.
- **The hub stops mid-action.** The ledger answers `unknown` for a non-idempotent call. The phone shows "Didn't confirm — check on the Mac" and never re-sends. Test: hub order tests with the new kind.
- **The Mac restarts with phone actions queued.** The outbox re-sends, and `relay_processed` plus `tower_requests` keep each action to exactly once. Test: the replay suite with `inbox_act`.
- **The phone is killed with actions queued.** The outbox is persistent. Test: an outbox wiring test with `inbox_act`.
- **Stale card.** A `content_hash` mismatch answers `changed`, and the client shows "This card changed — look again". Test: a stale-hash case for every hash-guarded verb in `inbox_writes.json`.
- **Approval arguments changed.** The command answers `args_changed`, and the card is redrawn. Test: an `inbox.act` test.
- **Writers of the same rows, and who wins.** After stage 1, every writer is Go code going through `tower.Call` or the daemon's own work:
  - the Mac, over the socket;
  - the hub;
  - the daemon (living rewrites, automation runs, approval apply);
  - the existing CLI verbs.

  The first commit wins, and a later guarded write is an `already` no-op. A living rewrite with a new hash clears the marks (A), so a Done on the old hash answers `changed`. Test: per verb, two calls from two connections on one file; one answers `ok` and the other `already` or `changed`.
- **Policy tightens while cards are on the phone.** POLICY-03 deletes the records, and the tab shows "The Inbox stays on your Mac". Test: a policy test in `sources`.
- **The chat session dies mid-turn (stage 3).**
  - After `started`, the Desktop calls `chat.recover {conversation, turn}`, which marks the row `session_lost` and releases the lease, as the hub's `Sweep` does. If that call fails, the daemon's start-up sweep does it.
  - Before `started`, nothing was written: the draft comes back and the existing "session ended" card shows.
  - With no `started` within 10 s, the Desktop gives up the same way.
  - Tests: a kill before and after `started`, the sweep, and a silent process.
- **The hub and the Mac race for one chat.** The lease decides, and both writers are `chatstore`. Test: `chat_lease_cases.json` and a two-process start race.

### 10. Docs

- New `docs/features/tower-interface.md`: the commands, the ledger, the generator, `WatchtowerInterface`, the socket, and pause instead of stop. It gets a CLAUDE.md line and a README summary.
- New `docs/features/inbox-core.md`.
- Updated feature docs:
  - `inbox-folders.md` and `inbox-card-blocks.md`: the builder and writers are in Go.
  - `tray-daemon-lifecycle.md`: the daemon is always on, and a stop pauses sync.
  - `mobile-companion.md`: a new Inbox section.
  - `go-hub.md`: the new kind and capability.
  - `chat-redesign.md` (its **Writers** line), `embedded-chat.md` and `iphone-chat.md`.
- The protocol spec tables (§6.2, §7.2, §9).
- `docs/inventory/` entries re-pointed to the Go code.
- `docs/guide`: the iPhone page gains the Inbox, and the tray page describes pausing sync.
- CLAUDE.md build notes gain `make gen-interface`.

### 11. Shots

- **Stage 1.** The Mac's Inbox shots before and after the switch match, and the `inbox-feed-*` states match mockup §7.
- **Stage 2.** The `ScreenshotTourTests` `inbox-*` shots match mockup §§1–6, and `DemoSeed` gains the sample Inbox.

## Promises → tasks → tests

| Promise | Stage / task | Test |
|---|---|---|
| One contract for Go and Swift | 0 / generator | `make gen-interface-check` in CI; generated golden decode tests |
| Exactly once on both transports | 0 / ledger | ledger kill tests (§9); hub replay suite |
| The Mac reaches the tower over the socket | 0 / socket | `tower.ping` end to end; peer-uid test; `hello` mismatch test |
| Stopping sync keeps the tower up | 0 / pause | daemon pause test; the tray and the three in-app stop sites call pause |
| Reconnecting is honest | 0 / `TowerClient` | `TowerClientTests` (drop, return, never returns) |
| Go builds the Mac's Inbox list exactly | 1 / core + parity | `inbox_feed_cases.json` |
| Needs approval picks the Mac's card | 1 / core | APPROVAL-01 guards moved to Go |
| One writer for every Inbox row | 1 / Go writers + guard | `inbox_writes.json`; Core guard test over the moved tables |
| Other screens write through the tower | 1 / screens | the same guard test; a per-screen refusal test |
| The Mac Inbox looks the same | 1 / Mac switch | DesignShot before and after |
| The Mac's new states are honest | 1 / Mac switch | screen-model tests; DesignShot `inbox-feed-*` |
| Fast enough | 0 and 1 / benchmarks | socket round trip; `BenchmarkInboxFeedBuild` |
| Races between writers | 1 / Go writers | two-connection race per verb |
| The phone sees the same folders and rows | 2 / hub sources | sources tests over the Go golden; Kit mirror tests |
| Same blocks drawn | 2 / phone renderer | Kit `ArtifactBlocksTests` fixture through `PhoneArtifactView` snapshots |
| Native actions per ref kind | 2 / hub + phone | `inbox_act` handler tests per verb; `InboxRefRowModelTests` |
| Approve pins args and needs `permissions` | 2 / hub | mismatch and no-grant tests |
| Phone states and copy | 2 / phone | `InboxTabStateTests`; `TowerText` tests |
| Policy off | 2 / hub sources | policy test |
| No Swift chat writer left | 3 / chat switch | Core guard test over `chat_*` |
| Chat UX no worse | 3 / benchmarks | `BenchmarkPersistStart`; stub-provider timing |
| A send survives a crash; a dead session is cleaned up | 3 / `--persist`, `chat.recover` | CHAT-01 guard; kill tests; sweep test |
| Chat contracts kept | 3 / chat switch | CHAT-01/02/03/05 and LIVE-01 guards, moved with their names |
| Shots match the mockup | 1 and 2 | DesignShot `inbox-feed-*`; `ScreenshotTourTests` `inbox-*` |

## Decisions

**From the owner:**
- The phone Inbox is for clearing it on the go — ask #1326.
- The phone shows every section, as an adapted copy of the Mac's Inbox — ask #1326.
- The Inbox gets a separate tab — ask #1326.
- The hub builds ready cards (approach A) — ask #1332.
- Only the Go hub publishes them — ask #1332.
- The Inbox works the same on the Mac and the phone, with all logic and writes on the tower — ask #1348, with the perimeter from ask #1356.
- Legacy entries stay until C, and plan items can be checked from the phone — ask #1348.
- The work is staged: the core with the Mac on it, then the phone, then the chat writes — ask #1356. Stage 0 (the interface) follows from ask #1362.
- The tab sits second, after Now — ask #1349.
- The badge counts only what waits on the owner — ask #1349.
- Approve and Retry from the phone need the `permissions` grant — ask #1349.
- Management, chat and agent stay on the Mac, and v1 has no push — ask #1349.
- The Desktop's chat writes move to Go in this work, on condition that the UX gets no worse — ask #1361.
- The clients share the contract, the client and the screen models, and keep their own views — ask #1362.
- A generator writes the Swift types from Go — ask #1362.
- The Mac reaches the core over the daemon's socket. The daemon always runs, and on request only sync stops — ask #1362. This replaces the CLI read from ask #1356.
- The Inbox moves, and so does every screen that writes the same rows; those screens move their writes only — ask #1362.

**Decided by the agent:**
- In-app stops whose purpose is "no sync" become a pause. A new binary, compaction, quit and a crash still restart the daemon. This applies ask #1362.
- On a version mismatch, the Desktop restarts a daemon it started from its own CLI.
- One ledger, `tower_requests`, gives exactly-once delivery for both transports.
- Approve, retry and the `reply` press return at once, and the long work runs in the daemon.
- Run Now reuses the `automation_run` function and is non-idempotent.
- Make a Task on a track is a `ref` verb over the existing propose path, with no grant.
- On the phone, Thread briefs become a list document and Messages a notice card. Stopped tracks stay inside the tracks card.
- `workbench_only` maps to `policy_off`. A missing key means an older hub, and the copy names the hub.
- The Mac's warm `ai session` saves its own turn (`--persist`), and the hub runner does not run Mac turns. This applies ask #1361.
- Speed is a gate: the socket feed takes at most 100 ms median, a write at most 15 ms, and the chat start is no slower.
- Reply needs `typing`, and other Inbox actions need no grant, as for board writes.
- Legacy entries are typed sections for the Mac and block projections for the phone.
- The phone gets at most 300 cards, with Needs approval and Waiting for me first.

## Left to the builder

- The file split inside `internal/tower`, `internal/inboxfeed` and under `sources`.
- The task order within each stage.
- The phone's file layout inside `Features/Inbox/`.
- Fixture locations, next to their Go owners.
- The exact list of write commands for §5.2, taken from the grep of call sites. The guard test proves the list is complete.
- The generator's reflection details, as long as the rules in §2.2 hold.
