# Phone Inbox — the Mac's Inbox as a fourth tab on the iPhone (design)

Target #1170. This is sub-project F ("Phone renders blocks") of the Inbox builder umbrella, `docs/superpowers/specs/2026-11-02-inbox-builder-design.md`, and builds on A (`docs/features/inbox-card-blocks.md`) and B (`docs/features/inbox-folders.md`). The hub side is the Go hub (`docs/features/go-hub.md`) and the phone is `WatchtowerMobile/` (`docs/features/mobile-companion.md`).

Mockups: `docs/design/mockups/mobile-inbox/index.html`, with every state in dark and light. After the build, each frame becomes a `ScreenshotTourTests` shot named `inbox-…`, and the shots are compared with the mockup before review (§10).

## Intent

The owner wants to clear the Inbox on the go: open the phone, act on what waits (approve, reject, mark done, snooze, hide, reply) and put it away (ask #1326). The phone shows an adapted copy of the Mac's Inbox, with every section (ask #1326), in its own tab (ask #1326). The Go hub builds ready-to-draw cards and the phone only draws them (ask #1332, approach A). Only the Go hub publishes them (ask #1332), and it is now the only hub, so nothing waits on a second implementation.

## Goals

- An **Inbox** tab that shows the Mac's Inbox menu: the root, Needs approval and the owner's folders, nested up to three levels deep, each with the Mac's count.
- Every artifact drawn from the same block JSON the Mac draws (Kit `ArtifactDocument`), using phone parts. A markdown card draws as text, and an unsupported or unreadable card shows its plain text with the Mac's line.
- On every row with a `ref`, the same native actions the Mac offers for that kind (umbrella "Acting on one row of a list"). They run through the hub on the Mac's own write paths. A failed write keeps the row with its error and **Retry**.
- Needs approval with the Mac's native or recipe card, as APPROVAL-01 decides. Approve pins the arguments the owner saw.
- The card actions that make sense on a phone (`reply`, `target`, `open`), plus **Done** and **Dismiss** on a card. Read marks are sent on open. Each of these marks only the version that was drawn (`content_hash`).
- Honest states for the whole tab: loading, empty, an empty folder, the Mac away (actions queue), not delivered (**Retry**), a Mac too old, and organization policy.

## Non-goals

- Managing the Inbox from the phone: creating, renaming, moving, hiding or deleting folders; routes; editing a recipe or its look; turning automations on or off; Delete. These stay on the Mac. The phone says "on your Mac" where the Mac has a menu.
- Discuss in Chat, Hand to Agent, the `chat` and `agent` card actions, Open Draft (`save_automation`) and Edit… on a proposal. These are drawn disabled with "On your Mac".
- Push notifications for new Inbox cards. The tab badge updates on every fetch, and a separate target can add alerts later.
- Learned Rules, Assistant Profile and the reaction cheat sheet (**?**).
- A phone renderer for any block type beyond the v1 set of A.

## Anti-goals

- The phone works out something the Mac decides differently. Counts, which rows are open, which card Needs approval shows, and which actions a ref kind has all come from the hub, computed by the code the Mac's rules already use or by a Go twin that a shared fixture keeps equal.
- A row looks done while its write failed, or a closed row comes back from a stale publish.
- An approval goes through for arguments the owner did not see.
- The phone holds more of the owner's data than the Inbox shows: no raw message tables, no history beyond what is drawn.

## Constraints

- Wire format is additive only (protocol spec §8). New slice kinds and action kinds get new names. `inbox_item` and `inbox_resolve`/`inbox_dismiss`/`inbox_snooze` are legacy names and stay unused.
- `slices.AllKinds`, `secure.dataKinds` and the Kit `SliceKind` change together. `handlers.NudgeTable` is pinned to `hub_contract_cases.json`.
- An envelope is at most 900 KB. A block document is at most 128 KB canonical (A), so one card is one record.
- The Desktop's read-state writers are guarded by `content_hash`. The hub's writers use the same guards.
- MDM `MobileSync = workbench_only` publishes no Inbox kinds (POLICY-03: tightening deletes the published records and nothing else).
- Phone design rules (mobile design pass spec): flat rows, cards only for waiting items and detail blocks, orange only for waiting-for-you, no row separators outside a card, and every string in a model with a test.

## Approaches

- **A. The hub builds ready cards (chosen, ask #1332).** New slice kinds carry the folder tree and one record per card: block JSON, ref facts, actions and counts. The phone draws them and sends actions back through the outbox. Logic stays on the Mac, the phone stays thin, and the phone holds only what it shows.
- **B. Raw rows, cards built on the phone.** The card builders would move into WatchtowerKit and about ten raw kinds would be published. This sends more data to the device, duplicates Mac rules on the phone, and needs more work. Rejected (ask #1332).
- **C. Swift hub first, Go later.** Moot: the Go hub is the only hub (ask #1332: "only the Go hub").

## Design

### 1. Wire: two slice kinds

**`inbox_folder-<id>`**, one record per visible folder (root, Needs approval and owner folders; hidden ones are left out):

| Key | Meaning |
|---|---|
| `id`, `kind` (`root`/`approvals`/`owner`), `slug`, `title`, `icon`, `parent_id`, `position` | Same as `inbox folders list --json` |
| `count` | The Mac's `InboxFolderCounts` for the folder |
| `waiting` | The part of `count` that waits on the owner: open approvals, and open rows with a `ref` that wait |

**`inbox_card-<id>`**, one record per item the Mac's Inbox draws. `id` is typed so that ids never collide: `o<output id>`, `a<action id>`, `r<reminder id>`, `n<builtin migration id>`, and for the legacy entries `brief-<date>`, `tracks`, `ideas` (§4).

| Key | Meaning |
|---|---|
| `folder_id`, `card_kind` | `card_kind` is `artifact`, `approval_native`, `reminder`, `notice` or `legacy` |
| `title`, `source_line`, `preview` | Texts built by the hub, the Go twin of `InboxCardTexts` |
| `stamp`, `living`, `unread`, `priority`, `pinned` | `pinned` is Waiting for me while a row waits, as on the Mac |
| `automation` | `{id, name, builtin_id, run_id}` or null |
| `blocks` | Stored `blocks_json` bytes as the Mac reads them, `""` for a markdown card |
| `body` | Plain text, clipped to 16 KB on a grapheme boundary, with `body_clipped` |
| `content_hash` | The output's hash. A native approval card carries its args SHA-256 instead |
| `actions` | The flattened action list (A's press address): `{index, kind, label, state}`. `state` is the Mac's button state (`ready`, `needs_confirmation`, `off`, `waiting_approval`, `task_created`, …) |
| `ref_facts` | Per `ref` in the document: `{open, waits, reply` (`slack`/`jira`/`linear`/`none`)`, reply_waiting, link}`, from `InboxRefState` and its Go twins in the primitives |
| `approval` | Native approval cards only: `{tool, title, summary, args_sha256, status, error, proposer, reason, edit_on_mac}` |

The hub publishes a card's `blocks` unchanged. Rows whose ref is closed stay in the document and are hidden by the phone from `ref_facts.open`, so the Mac and the phone draw the same open rows from the same facts. Every write in §3 nudges `inbox_card` and `inbox_folder`.

**Capability.** The heartbeat's `capabilities` gains `inbox: "on" | "policy_off"`. A missing key means a Mac too old, and the tab shows "Update Watchtower on <Mac>".

**Windows and caps.** Unread Morning briefs follow the Mac's rule (today's plus every unread one). There are at most 300 `inbox_card` records. Needs approval and Waiting for me are published first, then the rest newest first, then a `more` count on the folder.

### 2. Hub sources

- `internal/hub/slices/sources/inbox.go` reads the Mac's own queries in Go. They are listed below, each with its shared fixture.
  - Folders and counts come from the `inbox_artifact_folders` view and `db` folder reads, with the count rule pinned by a new `inbox_counts.json` fixture shared with `InboxFolderCounts`.
  - Ref facts use the existing parity fixtures `open_items.json` and `open_approvals.json`, plus a new `ref_facts.json` for `reply` and `reply_waiting` (Swift `InboxReplyPolicy`).
  - The Needs approval choice follows APPROVAL-01 (`NeedsApprovalSelection`), with a new `needs_approval_selection.json` fixture.
  - Texts are the Go twin of `InboxCardTexts` and `AgentActionCardView.title`, with a new `inbox_card_texts.json` fixture.
- `ChangeTables` adds `automation_outputs`, `inbox_folders`, `inbox_folder_routes`, `inbox_items`, `agent_actions`, `reminders`, `tracks`, `track_events`, `ideas`, `briefings`, `day_plans`, `day_plan_items` and `builtin_migrations`.

### 3. Actions (phone → hub)

| Kind | Entity | Params | Grant | Write path on the hub |
|---|---|---|---|---|
| `inbox_card_read` | `inbox_card-o…` / `brief-…` | `content_hash` | none | Output `read_at` guarded by hash; briefing `read_at` |
| `inbox_card_done`, `inbox_card_dismiss` | `inbox_card-o…` | `content_hash` | none | Output `done_at` / `dismissed_at` guarded by hash, open rows only |
| `inbox_card_press` | `inbox_card-o…` | `index`, `content_hash` | `typing` for `reply` with text | `reply`: the `automations reply` path (`ErrOutputChanged` → `changed`). `target`: the `create_target` propose path, never approved here |
| `inbox_card_run_now` | `inbox_card-o…` | none | none | `automations run` at the next sync, only where `Entry.RunNow` |
| `inbox_ref_action` | the card | `ref_kind`, `ref_id`, `verb`, `until` | none | Per kind, as on the Mac. `inbox_item`: Go's resolve, dismiss, snooze. `track`: done with its read cascade, stop, restore. `idea`: approve, reject, not now. `reminder`: `MarkReminderDone`, `SnoozeReminder` (approval hook included). `plan_item`: check and uncheck (§4) |
| `inbox_reply_propose` | the card | `ref_id`, `text` | `typing` | `InsertInboxReplyProposal` (`ErrReplyAlreadyWaiting` → `reply_waiting`) |
| `approval_decide` | `inbox_card-a…` | `verb` (`approve`/`reject`/`retry`/`dismiss`), `args_sha256` | `permissions` for `approve` and `retry` | `Registry` approve, reject, apply or dismiss with the pinned SHA. A mismatch → `args_changed` |

- `approval_decide` (approve and retry) and `inbox_card_press` are in `NonIdempotentKinds`. They are claimed `begun` before the handler, and a repeat after a crash answers `outcome_unknown`.
- Every other kind is a guarded write. A row that is already closed answers `applied` with `already: true`, so the phone hides it with no error.
- Refusals are `not_found`, `changed` (stale `content_hash`), `args_changed`, `not_permitted` (grant) and `unsupported_on_phone`, each with a sentence written in the hub's handler.

Where the Mac writes in Swift today (tracks, ideas, outputs, reminders, plan items), the hub gets a Go writer for the same columns and cascades. Each Swift and Go pair is pinned by one shared fixture (`inbox_writes.json`), whose cases are applied to a fixture database by both the Go test and a WatchtowerCore test.

### 4. The root's legacy entries (pending ask #1348)

Recommended answer: until sub-project C, the hub turns Morning brief (per date), Track my threads and Idea finder into block documents with `ref` rows, so the phone has one renderer.
- These documents are built by Go code under `internal/hub/slices/sources/inboxlegacy`, never by a recipe.
- They are checked by `blocks.Validate` with a hub-only option that admits the ref kind `plan_item`.
- Tracks use the `track` ref kind and ideas the `idea` ref kind.
- C replaces each projection with the built-in's own artifact, and the projection is deleted in C's PR.

The alternatives are waiting for C, or a v1 without these entries. If the owner picks either, §4 and the `plan_item` verbs are cut.

### 5. Phone

- **Tab.** Fourth tab **Inbox** (`tray`), placed second: Now, Inbox, Workbench, Calendar. `RootTabView.Tab.inbox`. The badge is the sum of the folders' `waiting` (orange, a waiting-for-you count). Unread artifacts show as dots, not in the badge.
- **Models** (all strings in the model, each with a test):
  - `InboxRootModel`: pinned Needs approval, folders, root entries in the Mac's order.
  - `InboxFolderModel`.
  - `InboxCardModel`: header line, document state, action states, bottom bar.
  - `InboxRefRowModel`: native actions per kind, busy, error, **Retry**.
  - `InboxApprovalModel`.
  - `InboxTabState`: `loading`, `empty`, `content`, `macTooOld`, `policyOff`.
- **Renderer.** `PhoneArtifactView` in `WatchtowerMobile/Sources/DesignSystem/Artifacts/` over the Kit `ArtifactDocument`, built from phone parts:
  - heading and text (markdown);
  - metrics (2- or 3-up);
  - list (FlatRow, tone pill, ref actions);
  - table (sideways scroll inside a card);
  - person (avatar from initials, no network);
  - link (`openURL`);
  - actions.
  - Tones map only through `PhoneTone` (a new `PhoneTone.artifact(_:)` matching Kit `Tone.artifact`).
- **Gestures.** Ref rows: swipe left for Done and Snooze, swipe right for Hide (per kind: track Done and Stop; reminder Done and Snooze 1h). The context menu carries the full verb set and is also the accessibility path. A row detail is pushed on tap. Reply… is a sheet with "Propose", and the line says it goes to Needs approval.
- **Optimistic hide, never optimistic success.** A pressed row shows busy. On `applied` it hides locally until a publish leaves it out or reopens it, at most 2 publishes. After that the hub's state wins. On a refusal the row returns with the hub's sentence and **Retry**. An action queued while the Mac is away shows in the existing outbox lines (Waiting to send / Not delivered).

### 6. Failure modes

- **The hub stops mid-action.** A non-idempotent kind left `begun` answers `outcome_unknown`. The phone shows "Didn't confirm — check on the Mac" on that card and never re-sends it. Guarded kinds are re-applied safely. Test: hub order tests with a crash between begun and done.
- **A failure part-way through a Go write.** Each write is one transaction, and a failure rolls back. Test: a fault seam in each Go writer test.
- **The Mac restarts.** The outbox re-sends. Exactly-once comes from `relay_processed`. Test: the existing replay suite gets the new kinds.
- **The phone is killed with queued actions.** The outbox is persistent. Test: an outbox wiring test with an inbox kind.
- **Stale card.** A different `content_hash` gets `changed`, and the phone shows "This card changed — look again" and redraws. Test: a handler test with a stale hash.
- **Approval arguments changed.** `args_changed` returns the card redrawn with its line. Test: a handler test.
- **Writers of the same rows** are the Desktop (GRDB) and the hub (Go, through the same guarded statements), plus the daemon for living rewrites and approvals. Whoever commits first wins, and the later guarded write is a no-op that reports `already`. A living rewrite with a new hash clears read, done and dismiss (A's rule), so a phone Done on the old hash answers `changed`. Test: a race test per kind that interleaves a Desktop write and a hub write on one database.
- **Policy tightened while cards are on the phone.** The hub deletes the published inbox records (POLICY-03) and the tab shows "The Inbox stays on your Mac". Test: a policy test in `sources`.

### 7. Docs

`docs/features/mobile-companion.md` (Inbox section), `docs/features/go-hub.md` (kinds and actions), the protocol spec tables (§6.2, §7.2, §9), `docs/guide` (the iPhone page gains the Inbox), and the CLAUDE.md/README feature line.

## Promises → tasks → tests

| Promise | Task | Test |
|---|---|---|
| Folder tree and counts as on the Mac | Hub sources | `inbox_counts.json` parity (Go + Core) |
| Open ref rows equal the Mac's | Hub sources | `open_items.json`, `open_approvals.json`, `ref_facts.json` |
| Needs approval picks the Mac's card | Hub sources | `needs_approval_selection.json` |
| Same blocks drawn | Phone renderer | Kit `ArtifactBlocksTests` fixture through `PhoneArtifactView` snapshots |
| Native actions per ref kind | Hub actions + phone | `inbox_writes.json` parity; `InboxRefRowModelTests` |
| Approve pins args | Hub actions | `approval_decide` args mismatch test |
| Hash-guarded Done/Dismiss/read | Hub actions | Stale-hash handler tests |
| A failed write keeps the row | Phone | `InboxRefRowModelTests` refusal case |
| States and copy | Phone | `InboxTabStateTests`, every string in the model |
| Exactly-once | Hub actions | Order and replay tests with the new kinds |
| Policy off | Hub sources | Policy test |
| Shots match the mockup | Phone | `ScreenshotTourTests` `inbox-*` |

## Decisions

- The Inbox on the phone is for clearing it on the go — ask #1326.
- Every section, as an adapted copy of the Mac's Inbox — ask #1326 (rebased on the current Inbox of folders in ask #1348).
- A separate tab — ask #1326.
- The hub builds ready cards (approach A) — ask #1332.
- Only the Go hub — ask #1332.
- Legacy entries projected into blocks by the hub; plan items checkable from the phone — pending ask #1348.
- Tab placed second, after Now — decided by the agent.
- Badge = items waiting on the owner (orange); unread artifacts as dots only — decided by the agent.
- Approve and Retry need the `permissions` grant; Reply needs `typing`; every other inbox action needs no grant, as board writes do — decided by the agent.
- Management, chat, agent, Open Draft and Edit… stay on the Mac, shown as "On your Mac" — decided by the agent.
- The phone hides closed ref rows itself from `ref_facts`, and the hub publishes `blocks` unchanged — decided by the agent.
- No push notifications for Inbox in v1 — decided by the agent.
- 300-card cap, with Needs approval and Waiting for me first — decided by the agent.
- One action kind `inbox_ref_action` with a `verb`, instead of one kind per verb — decided by the agent.

## Left to the builder

The exact Go package split under `sources`, the order of the plan's tasks, the phone file layout inside `Features/Inbox/`, and the fixture file locations (next to their Go owners, as `open_items.json` is).
