# Inbox builder B — folders and the Inbox menu: implementation plan

**Spec:** [2026-11-03-inbox-builder-b-folders-menu-design.md](../specs/2026-11-03-inbox-builder-b-folders-menu-design.md)
**Umbrella:** [2026-11-02-inbox-builder-design.md](../specs/2026-11-02-inbox-builder-design.md) (board #1400). **Sibling plan:** `2026-11-03-inbox-builder-a-blocks-look.md` (sub-project A; "A Task N" below refers to it).
**Status:** for owner review together with the spec (author loop, ask #448). Q1 and Q2 answered in ask #445: Reply on a row is Task 18; legacy entries in the root (Tasks 12 and 16). Ask #451 approved every inventory amendment B relies on, so no task is gated on it any more; the spec's refusal table and Reply matrix are historical.

## Execution rules

- Each task runs in its own worktree and branch, merged by the controller into `feature/inbox-builder-b`; never two implementers in one tree. Tasks whose `Depends on` are all merged may run in parallel lanes: the **Go lane** (Tasks 2–9, 15's Go half, 18's Go half) and the **Swift lane** (Tasks 1, 10–14, 15's Swift half, 16, 18's Swift half) meet at Task 10 (schema) and Task 13 (A's renderer).
- **Owner checkpoint after Task 1:** the controller files an ask with the Task 1 shots. Swift Tasks 11–16 and Task 18's Swift half start only after the owner's answer; Go Tasks 2–9 and Task 18's Go half do not wait.
- **Integration between A and B:** when a B task depends on an A task, the controller first merges `feature/inbox-builder-a` into `feature/inbox-builder-b` at a commit where that A task is reviewed and merged, and only then branches the dependent task's worktree from `feature/inbox-builder-b`. The rule applies to Tasks 6, 7, 8, 9, 13 and 14 (each says so). Plan A carries the mirror rule for its tasks that depend on B (A Task 15 → B's STRIP-01 edit, here Tasks 8 and 9).
- **Sub-project A gates:** Tasks 6, 8, 9, 13 and 18's Swift half start only after the named A tasks are merged into the shared base the controller uses for B (A Task 3 migration and living upsert, A Task 4 `artifacts:` key, A Task 5 SDK and field hook, A Task 1 renderer and hooks, A Task 10 cards with blocks). Everything else does not wait on A.
- Inner loop only (CLAUDE.md): `go test ./internal/<pkg>` for the touched packages, `go test ./cmd -run '<Name>'` for cmd tests, `make test-swift FILTER=<Class>`, `make lint-diff`. The full gate (`make test`, `make test-swift`, `make lint-all`) runs once after Task 9 (Go phase), once after Task 16 (Swift phase), and before the PR — by the controller.
- Each implementer self-reviews against `docs/review/review-rules.md` (Go sections and, for Swift, "Swift / Desktop conventions") and `docs/design/desktop-style-guide.md` before hand-back; the independent review uses the same checklist. Every task's brief carries the spec's invariants verbatim: CAS never retried by the Desktop; the Desktop writes no folder table; an open approval always on screen, a closed one never; native row actions only call today's functions; no `llm()` in the two built-ins.
- Migration: one task (Task 2), the `add-migration` skill, number = next free at implementation (in-flight branches may hold 00172+; A's migration is separate). No table rebuild.
- Inventory: a task that changes a contract edits its `docs/inventory/*.md` entry (Observable, guards, Changelog) in the same commit as the code, only as the spec lists (all approved in asks #961, #952, #451). Where each lands: STRIP-02 → Task 2; FOLDER-01 → Task 3; AUTO-* → Tasks 5–7; STRIP-01 built-in wording → Task 8 (`needs-approval`) and Task 9 (`waiting-for-me`), INBOX-02/09 note → Task 9; APPROVAL-01 → Task 12 (the native fallback and render-time check are its code); STRIP-03 → Task 13; AGENT-04 note → Task 15; STRIP-01's filter wording and INBOX-05 → Task 16 (the filter bar and strip ⋯ go there); AGENT-03/AGENT-07 and the STRIP-01 Reply narrowing → Task 18. No guard test is weakened or renamed.
- Sample data: `acme`, `example.com`, "colleague A". No live data, no local paths.
- No code bodies here; signatures are the contract, names may be refined in review if the spec's semantics stay.

## Task 1 — Shots first: every state on fixtures

**Depends on:** none. **Lane:** Swift.

Files:
- new `WatchtowerDesktop/Sources/Views/Inbox/Folders/InboxFolderMenu.swift` — the menu over a plain value `InboxFolderMenuContent` (`rows: [InboxFolderRow]` with `id`, `kind`, `title`, `icon`, `depth`, `count`, `hidden`, `isExpanded`; `selection`; `note: InboxFolderMenuNote?` = `.menuChanged | .cliUnavailable`; `dropIndicator: InboxFolderDrop?`; `deleteConfirmation: InboxFolderDeleteSummary?`; `newFolderDraft: String?`). No model, no CLI.
- new `WatchtowerDesktop/Sources/Views/Inbox/Folders/InboxFolderContentList.swift` — the artifact list over `[InboxFolderEntry]` (artifact, legacy entry, native approval) with unread dots, "updated …" lines and the empty states.
- new `WatchtowerDesktop/Sources/Views/Inbox/Folders/NeedsApprovalNote.swift` — the off / last-run-failed note.
- new `WatchtowerDesktop/Sources/Views/Inbox/Folders/InboxRowActionsView.swift` — the per-kind native action rows over `InboxRowActionsContent` (`kind`, `state: .idle | .busy | .failed(message:)`, the kind's buttons), no wiring.
- new `WatchtowerDesktop/Sources/Views/Inbox/Folders/InboxArtifactMenus.swift` — the artifact ⋯, folder ⋯, root ⋯ and Needs approval ⋯ menus as `Menu` content over a plain `InboxArtifactMenuContent` (which entries exist: built-in, Run Now offered, movable).
- new `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+InboxBuilderB.swift`; register in `DesignShotCatalog.swift`: `inbox-b-menu-root`, `inbox-b-menu-hidden-shown`, `inbox-b-menu-new-folder`, `inbox-b-menu-drag`, `inbox-b-menu-changed`, `inbox-b-menu-cli-unavailable`, `inbox-b-folder-delete-confirm`, `inbox-b-root-empty`, `inbox-b-folder-empty`, `inbox-b-approvals-empty`, `inbox-b-approvals-native`, `inbox-b-approvals-mixed`, `inbox-b-approvals-off`, `inbox-b-approvals-run-failed`, `inbox-b-approvals-failed-action`, `inbox-b-approvals-reminder`, `inbox-b-rows-inbox-item`, `inbox-b-rows-track`, `inbox-b-rows-idea`, `inbox-b-rows-reminder`, `inbox-b-rows-action`, `inbox-b-row-busy`, `inbox-b-row-failed`, `inbox-b-row-reply-composer`, `inbox-b-row-reply-refused`, `inbox-b-row-reply-pending`, `inbox-b-waiting-not-run` (the Messages stand-in card with **Reply…**), `inbox-b-menus` (all four menus opened side by side), `inbox-b-idea-finder-menu` (the Idea finder entry's ⋯ with Find Ideas in Past Messages…), `inbox-b-move-to-folder`.

Steps: build each view from DesignKit parts only (`.kitRow`, `Chip`, `.kitSecondary`, `Tone`, `Spacing`; no hex, no `Divider()` between rows); fixtures from the spec's mockups; rows with a `ref` are drawn as `InboxRowActionsView` beside a plain row stand-in (the `ArtifactView` version is Task 13); `make desktop-shots DESKTOP_SHOTS=<dir>` and attach the PNGs to the hand-back.

Tests: `DesignShotsTests` renders every new shot (names unique); a content value with zero rows, with one row at depth 3, with 100 rows renders without layout warnings.

Checks: `make test-swift FILTER=DesignShotsTests`, `make lint-diff`.

## Task 2 — Migration and the db layer

**Depends on:** none (STRIP-02 approved in ask #451: the folder tables). **Lane:** Go.

Files: new `internal/db/migrations/00NNN_inbox_folders.sql` (spec "Data model and migration", seeds included); `internal/db/schema.sql`; `internal/db/db_test.go` (`TestAllTablesExist` gains `inbox_folders`, `inbox_folder_state`, `inbox_folder_routes`); schema golden and `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` regenerated (`go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`); new `internal/db/inbox_folders.go`:
- `type InboxFolder struct { ID int64; Kind, Slug, Title, Icon string; ParentID *int64; Position int; Hidden bool }`
- `func (db *DB) InboxFolderTree(ctx context.Context) (revision int64, folders []InboxFolder, routes map[int64]int64, err error)` — one read-only transaction.
- `func (db *DB) WithInboxFolderRevision(ctx context.Context, expect int64, fn func(tx *sql.Tx) error) (newRevision int64, err error)` — `BEGIN IMMEDIATE`, compare, `fn`, bump; mismatch → `ErrInboxRevisionConflict{Now, Given}` without calling `fn`.
- `func (db *DB) InboxArtifactFolder(ctx context.Context, outputID int64) (int64, error)` — reads the view.
- `db.AutomationOutput` gains `FolderID *int64`; `commitRunTx` writes it on insert (the living upsert's write is Task 6, after A Task 3).

Inventory: `docs/inventory/reaction-commands.md` STRIP-02 ("the folder tables hold the menu's arrangement only, never an item"), Observable + Changelog (ask #451).

Tests: migration up on an empty DB (root + Needs approval + revision 1); up on a DB with inbox and report outputs (only `kind='inbox'` in the view, all in the root); down then up; the root CHECK (a root with a parent, an owner folder without one → refused); the one-root / one-approvals unique index; route `ON DELETE CASCADE` with its automation; `folder_id` `ON DELETE SET NULL`; the view's precedence (explicit > route > root); `WithInboxFolderRevision` happy path, stale revision (nothing written, `fn` not called), `fn` error (rolled back, revision unchanged), two concurrent callers on one file (exactly one succeeds).

Checks: `go test ./internal/db`, `make lint-diff`.

## Task 3 — `internal/inboxfolders`: rules, slugs, icons, the five writes

**Depends on:** Task 2. **Lane:** Go.

Files: new `internal/inboxfolders/` — `folders.go` (`Store` over `*db.DB`), `validate.go`, `slug.go`, `icons.go` + `testdata/icons.json` (the allowlist, read by Swift in Task 10), `errors.go`.
- `func (s *Store) List(ctx) (Tree, error)`; `type Tree struct { Revision int64; Folders []Folder }` in pre-order; `Folder` adds `AutomationIDs []int64`.
- `Create(ctx, CreateRequest{Title, Icon string; ParentID *int64; Position *int; ExpectRevision int64}) (Tree, Folder, error)`
- `Update(ctx, id int64, UpdateRequest{Title, Icon *string; Hidden *bool; ExpectRevision int64}) (Tree, Folder, error)`
- `Move(ctx, id int64, parentID int64, position int, expect int64) (Tree, Folder, error)`
- `Delete(ctx, id int64, expect int64) (Tree, Moved, error)`; `type Moved struct { Folders, Automations, Artifacts int }`
- `Route(ctx, automationID int64, RouteRequest{FolderID *int64; NewTitle, NewIcon string; ParentID *int64; ExpectRevision int64}) (Tree, Folder, created bool, error)`
- sentinels: `ErrRevisionConflict` (wraps the db one, message per spec), `ErrRootFixed`, `ErrApprovalsFixed`, `ErrApprovalsRouteFixed`, `ErrDuplicateTitle`, `ErrTooDeep`, `ErrTooMany`, `ErrUnknownIcon`, `ErrNoFolder`, `ErrNoAutomation`, `ErrCycle`, `ErrBadTitle`.
- constants `MaxDepth = 3`, `MaxOwnerFolders = 100`, `MaxTitleRunes = 60`.

Steps: every write is one `WithInboxFolderRevision`; positions rewritten densely in the touched sibling lists; delete moves children (order kept, appended), routes and explicit artifacts to the parent and returns the counts; slug derived once, suffix on a clash.

Tests (spec "Test strategy" Go list for this package, every line): including degenerate titles (empty, spaces only, 60/61 runes, a newline, an emoji at the boundary), position −1 / past the end, moving under a descendant, a route of an owner automation to Needs approval (refused: it holds only its built-in), a route of `needs-approval` elsewhere (refused), a route with both `FolderID` and `NewTitle` (refused), delete of an empty folder (zero counts), delete of a folder holding another folder at max depth (children move up one level and stay within the limit).

Checks: `go test ./internal/inboxfolders ./internal/db`, `make lint-diff`.

## Task 4 — CLI `watchtower inbox folders …`

**Depends on:** Task 3. **Lane:** Go.

Files: new `cmd/inbox_folders.go`, `cmd/inbox_folders_test.go`; `cmd/inbox.go` (register the `folders` group). Verbs, flags, pinned keys and error texts exactly as the spec's CLI section. Writes call `refuseUnderAgent(<verb>)` (`cmd/actions.go`) before opening the database and require `--expect-revision` (refused before any read).

Inventory: new entry FOLDER-01 ("Deleting a folder never deletes content") in a new `docs/inventory/inbox-folders.md` with its row in `docs/inventory/README.md` (module `internal/inboxfolders/`, `cmd/inbox_folders.go`); guard `TestFolder01_DeleteMovesContentsUp` (ask #451).

Tests: `TestInboxFoldersCLI_ListJSONKeys`, `…_CreateJSONKeys`, `…_UpdateJSONKeys`, `…_MoveJSONKeys`, `…_DeleteJSONKeys`, `…_RouteJSONKeys` (the `automationJSONKeys` helper pattern); conflict exit and message; missing `--expect-revision`; agent marker refusal on every write and none on `list`; `--hidden=false` unhides; `route` with neither `--folder` nor `--new-title`; a non-numeric id; JSON is the last stdout line.

Checks: `go test ./cmd -run 'TestInboxFoldersCLI'`, `make lint-diff`.

## Task 5 — Built-in registry: default folder, route seeding, `RunsAtSlot`

**Depends on:** Task 2. **Lane:** Go.

Files: `internal/automations/builtin/registry.go` (`Entry.DefaultFolder string` = folder slug; `Sends` copy reworded to folders), `internal/automations/builtin/card.go` (card JSON gains `default_folder`; `result_filter` stays until Task 16, which removes it with its one Swift reader — `AutomationsCLI.swift` `resultFilter` and `BuiltinAutomationCard.swift`'s Open in Inbox — and the `testdata/show_*.json` fixtures in one commit), the built-in indexer (seed a route when `DefaultFolder != "inbox"` and none exists), `internal/db/automations.go` (`RunsAtSlot`: `TriggerKind == TriggerKindSync`), `internal/db/automation_runs.go` (`slotAutomationSQL`, `slotRunSQL` to match), `docs/inventory/automations.md` changelog line, `docs/features/built-in-automations.md` sentence on slot-only runs.

Tests: `TestAutomation_RunsAtSlotMatchesSlotSQL` over a built-in with a sync trigger, a built-in with an event trigger, a Personal watch recipe, an owner event recipe; the poll executor claims an event-triggered built-in's queued run and still skips a sync built-in's; route seeded once and kept after the owner moves it; card JSON keys.

Checks: `go test ./internal/automations/builtin ./internal/db ./internal/automations`, `go test ./cmd -run 'Builtin'`, `make lint-diff`.

## Task 6 — `folder` on `output.inbox`

**Depends on:** Task 3, A Task 3, A Task 5. Integration rule (A merged first). **Lane:** Go.

Files: new `internal/automations/inbox_folder_field.go` (registered through A's `(*OutputMod).RegisterInboxField("folder", …)` where the runtime wires modules), `internal/db/automation_runs.go` (`commitRunTx`: `folder_id` on insert and on the living upsert), the dry-run `DraftOutput` (`folder` slug + resolved title), `docs/inventory/automations.md` changelog.
- `func inboxFolderField(env *Env, fn string, v any, o *db.AutomationOutput) error` — checks the shape only and buffers `o.FolderSlug`; not a string or empty → `output.inbox(): folder must be a folder name`.
- `db.AutomationOutput` gains `FolderSlug string`; `commitRunTx` resolves it to `folder_id` inside the run's commit transaction (`SELECT id FROM inbox_folders WHERE slug = ?` on the tx); a miss → NULL plus the journal line `folder "<slug>" not found — shown in <route title>` written in the same transaction. The folder is never looked up at the call (spec: the race with a folder delete).

Tests: existing slug; unknown slug (run succeeds, line journaled, artifact in the route folder); the race — the folder deleted through `inboxfolders.Store.Delete` after `output.inbox` and before the commit → the run `succeeded`, no foreign-key error, artifact in the route folder, line journaled; a folder with that slug created between call and commit → used; `folder: ""`, `folder: 3`, `folder: null`; a living upsert moving an artifact to another folder; a dry run writes nothing and returns the slug; a failed run writes no `folder_id` (AUTO-04).

Checks: `go test ./internal/automations ./internal/db`, `make lint-diff`.

## Task 7 — The `approval` trigger: hook, fire, wake, sweep

**Depends on:** Task 5, A Task 3 (the sweep compares with `written_at`) — integration rule. **Lane:** Go.

Files:
- `internal/db/agent_actions.go`, `internal/db/reminders.go` — each of the seven writers calls `db.approvalChanged(ref)` after a statement that changed a row; new `func (db *DB) SetApprovalHook(fn func(ref string))`.
- Step: `MarkReminderDone(id int64) error` → `MarkReminderDone(id int64) (changed bool, err error)` with `WHERE id = ? AND status != 'done'`, and `SnoozeReminder(id int64, until string) error` → `(changed bool, err error)` from `RowsAffected`. Callers (all of them today, checked with `grep -rn 'MarkReminderDone\|SnoozeReminder(' internal cmd`): `internal/db/reminders_test.go` only (REMIND-01's `TestReminders_InsertListDueSnoozeDone` — adapt to the new return, keep every assertion, add the `changed` checks). The implementer re-runs the grep and lists the callers in the hand-back.
- new `internal/automations/builtin/approvals.go` — `func Fire(d *db.DB, ref string, wake func()) error` (spec: enqueue / merge ≤ 100 + `truncated`, then wake; not runnable → nil).
- `internal/automations/recipe.go` / `events.go` — `"approval"` in `EventTypes`, `EventFields["approval"] = {}`, `approvalTriggerAllowed(scope)` beside `syncTriggerAllowed`.
- cmd wiring: every place a cmd process opens the database for work that can change approvals (`openDBFromConfig` in `cmd/watch.go` and the other openers — the implementer lists them with `grep -n 'db.Open(' cmd/*.go` in the hand-back) sets the hook to `Fire(…, func(){ wakeAutomations(cfg) })`; the daemon sets it to its in-process executor wake (`internal/daemon/automation_wake.go`).
- new hidden `cmd/inbox_approvals.go`: `inbox approvals changed --ref <kind>:<id>`.
- new `internal/daemon/approval_sweep.go`: `phaseApprovalSweep` after `phaseUnsnooze` in `runSync` (`internal/daemon/daemon.go`).
- `docs/inventory/automations.md` changelog (AUTO-09: the fire only queues).

Tests: `MarkReminderDone` on a pending reminder → true, again → false, unknown id → false; `SnoozeReminder` on a known id → true, unknown → false; the hook fires exactly on the `true` cases; the guard `TestApprovalHook_EveryWriterNotifies` (each writer, plus a source scan of `internal/db` for `agent_actions` / `reminders` writes that do not call the hook); no call on a no-op update (`ok=false`); `Fire` one run, merge, 101 refs, built-in off, unconfirmed, enqueue error logged and swallowed; `approval` refused for Personal and workbench recipes and with a `where`; the CLI with `action:7`, `reminder:7`, `x:7`, `action:`, `action:-1`; the sweep's four cases (newly due reminder, open approval without a current artifact, artifact of a closed record, everything matching → no fire); the sweep never writes `reminders` or `agent_actions` (row snapshots equal before and after). Spawned helper processes in cmd tests reaped in `t.Cleanup`.

Checks: `go test ./internal/db ./internal/automations ./internal/automations/builtin ./internal/daemon`, `go test ./cmd -run 'InboxApprovals|Actions'`, `make lint-diff`.

## Task 8 — Built-in `needs-approval`

**Depends on:** Task 7, A Task 3, A Task 4, A Task 5. Integration rule (A merged first). **Lane:** Go.

Files: new `internal/automations/builtin/recipes/needs-approval.md`; `registry.go` entry (`ID: "needs-approval"`, `Slot: ""`, `FeatureIDs: ["approval-cards"]`, `Primitives: ["approvals.list"]`, `DefaultFolder: "needs-approval"`, `RunNow: true`, card copy); new `internal/automations/builtin/testdata/open_approvals.json` — the shared fixture for actions and reminders (rows at a fixed now: pending, approved, executing, applied, rejected, failed, failed+dismissed, a settled session call, an unknown-outcome session call; reminders pending past, pending future, done, dismissed; the expected open refs), read by this task's Go test and by Swift `InboxRefStateTests` (Task 10), so Go's `approvals.list` and Swift's `InboxRefState` agree; new `internal/automations/builtin/approvals_primitive.go` (`ApprovalsPrimitives(d *db.DB) map[string]automations.PrimitiveFunc`, the read of spec "The recipe"); `internal/features/registry.go` (`approval-cards`, default on, no fast-forward hook); the daemon's primitive map; card fixtures; `docs/inventory/automations.md` changelog.

Inventory: STRIP-01 — the `needs-approval` half of the built-in wording (its artifacts are views of gesture-gated approvals; only built-ins may write `action`/`reminder` refs), Observable + Changelog (ask #451).

Tests: parses as a built-in; `LLMCallSites` empty (A Task 8's counter); on a fixture with two pending actions, one failed-after-approval, one settled session call, one rejected, two due reminders and one future reminder → exactly the open five keys written with a `ref` row each; a second run after one is approved → that key removed, others byte-identical (no `changed_at` move); 51 open → 50 oldest written; zero open → every earlier key removed, no output; an action with unparsable `args_json` → drawn with its tool name, not dropped; `features disable approval-cards` → `Fire` queues nothing.

Checks: `go test ./internal/automations/builtin ./internal/features ./internal/daemon`, `make lint-diff`.

## Task 9 — Built-in `waiting-for-me`

**Depends on:** Task 5, A Task 3, A Task 4, A Task 5. Integration rule (A merged first). **Lane:** Go.

Files: new `recipes/waiting-for-me.md`; `registry.go` entry (`Slot: SlotWaitingForMe`, `FeatureIDs: ["secretary-inbox"]`, `Primitives: ["attention.waiting"]`, `DefaultFolder: "inbox"`, `RunNow: true`); `automations.SyncSlots` + `builtin.Slot` gain `waiting_for_me`; new `internal/automations/builtin/waiting.go` (`WaitingPrimitives(d *db.DB, now func() time.Time)`); new `internal/db/inbox_open.go` (`func (db *DB) OpenInboxItems(ctx, now time.Time, limit int) ([]InboxItem, error)` — the Go twin of `HomeFeedQueries.openMessageClause`); new `internal/inbox/testdata/open_items.json` (the shared fixture, also read by Task 10); new `phaseWaitingForMe` in `internal/daemon/builtin_slots.go`, called right after `phaseInbox` in `runSync`; `docs/inventory/inbox-pulse.md` INBOX-02/09 changelog note (ask #952).

Inventory: STRIP-01 — the `waiting-for-me` half of the built-in wording (its artifact is a view of `inbox_items`, its rows act only on those records) (ask #451); INBOX-02/09 changelog note (ask #952).

Tests: `OpenInboxItems` against the fixture (pending, snoozed past and future, resolved, dismissed, ambient, archived, a deleted Jira issue, a non-feed trigger); 0, 200 and 201 items (cap); an item with empty text; a channel-folded item is one row with its count; the recipe writes one artifact `waiting` with one `ref` row per item and the `empty` text at zero; no `llm()`; `phaseWaitingForMe` order in `runSync`; detector off → the slot skips (`SkippedDisabled`).

Checks: `go test ./internal/db ./internal/automations/builtin ./internal/daemon ./internal/inbox`, `make lint-diff`.

## Task 10 — Desktop Core: folder queries, CLI wrapper, ref state, counts, badge

**Depends on:** Task 2, Task 4 (contract only; tests use a fake runner). **Lane:** Swift.

Files (all `WatchtowerDesktop/Sources/WatchtowerCore/`):
- new `Database/Queries/InboxFolderQueries.swift` — `static func tree(_ db: Database) throws -> InboxFolderTree` (revision, folders pre-order, routes), `static func artifacts(_ db: Database, folderID: Int64) throws -> [AutomationOutputCard]` (through `inbox_artifact_folders`, order by A's `changed_at` once present, else `created_at`).
- new `Services/Inbox/InboxRefState.swift` — `struct InboxRefState { func isShown(_ ref: InboxRef) -> Bool; func waits(_ ref: InboxRef) -> Bool }`, `static func read(_ db: Database, refs: [InboxRef], nowUTC: String) throws -> InboxRefState` (one query per kind, `IN (…)` over the ids, reusing `HomeFeedQueries.openMessageClause`, `ReminderQueries` due predicate, `AgentActionQueries.awaitingOwnerCount`'s predicate, `Idea.awaitsVerdict`). `InboxRef` mirrors A's `ArtifactRef` (kind + id) so Core stays Kit-free; the app maps between them.
- new `Services/Inbox/InboxFolderCounts.swift` — `static func counts(tree:artifacts:refState:legacy:) -> [Int64: Int]` and `badge(counts:tree:) -> Int` (visible folders only).
- new `Services/Inbox/InboxFoldersCLI.swift` — one method per verb over `CLIRunnerProtocol`, decoding the pinned keys; `enum InboxFoldersCLIError { case menuChanged, refused(String) }` mapped from the spec's phrase.
- new `Services/Inbox/InboxFolderIcons.swift` — the allowlist, tested against `internal/inboxfolders/testdata/icons.json`.
- `Services/Actions/ActionStripViewModel.swift` — `badgeCount` replaced by the folder sum (the old terms survive inside it as Needs approval's and the legacy entries' counts); `Sources/ViewModels/SidebarCountsViewModel.swift` reads it.

Tests: `InboxFolderQueriesTests`, `InboxRefStateTests` (incl. the shared `internal/inbox/testdata/open_items.json` and `internal/automations/builtin/testdata/open_approvals.json` — same open ids/refs as Go; Task 10 creates the approvals fixture if it lands before Task 8, one owner per merge), `InboxFolderCountsTests`, `InboxFoldersCLITests`, `InboxFolderIconsTests` — every case in the spec's Swift list for these types; a tree read on a schema without the tables (an older database) → root-only tree, never a crash (`isMissingTable` rule); the existing `ActionStripViewModelTests` STRIP guards green.

Checks: `make test-swift FILTER='InboxFolderQueriesTests|InboxRefStateTests|InboxFolderCountsTests|InboxFoldersCLITests|InboxFolderIconsTests|ActionStripViewModelTests'`, `make lint-diff`.

## Task 11 — The folder menu

**Depends on:** Task 1, Task 10. **Lane:** Swift.

Files: new `WatchtowerCore/Services/Inbox/InboxFolderMenuModel.swift` (`@MainActor @Observable`, owned by `ActionStripViewModel` or a sibling on `AppState` so it survives navigation): `func reload() async`, `func create(title:parent:) async`, `rename`, `setIcon`, `setHidden`, `move(_:toParent:position:) async`, `delete(_:) async`, `var note: InboxFolderMenuNote?`, `var isBusy`, `canDrop(_:onto:) -> Bool`; Task 1's `InboxFolderMenu` fed by it; `Views/Inbox/InboxSplitView.swift` gains the first column; root ⋯ entries open `InboxAuxPane.learnedRules` / `.profile` in the reading pane; the header keeps the **?** (`InboxAuxPane.reactionCommands`).

Tests (`InboxFolderMenuModelTests`): each write sends the spec's arguments with the current revision; a conflict → one `reload()`, the note set, no second write; CLI missing → edits disabled, reading works; drag onto a depth-3 folder refused locally (no CLI call); drag of root or Needs approval refused; delete summary counts from the tree; the selected folder deleted → selection moves to the parent; hidden folders absent until Show Hidden Folders; state survives the Inbox leaving the screen and coming back (house rule: async state outlives navigation).

Checks: `make test-swift FILTER='InboxFolderMenuModelTests|DesignShotsTests'`, `make lint-diff`.

## Task 12 — Folder contents, legacy entries, Needs approval

**Depends on:** Task 10, Task 11. Recipe cards drawn after Task 8 and A Task 10 are merged (before that the selection rule always picks native, which is correct). **Lane:** Swift.

Files: new `WatchtowerCore/Services/Inbox/InboxFolderEntries.swift` — `enum InboxFolderEntry { case artifact(AutomationOutputCard), legacyDay(InboxDayCard), legacyTracks, legacyIdeas, legacyMessages, approval(NeedsApprovalItem), builtinNotice(BuiltinUpgradeNotice) }` and `static func build(folder:snapshot:artifacts:refState:waitingForMe:) -> [InboxFolderEntry]` (root: legacy entries (ask #445), Waiting for me pinned first while it has waiting rows, the Messages legacy entry while Waiting for me has never succeeded or last failed); new `NeedsApprovalSelection.swift` — `static func pick(approval:artifact:recipeOn:lastRunFailed:) -> .recipe | .native` (spec's four conditions); `ActionStripViewModel` keeps feeding `InboxFeedQueries.read` and adds the folder read in the same `dbPool.read`; `InboxReadingPane` hosts the legacy panes and the native cards unchanged; `EmptyStateCopy.swift` keys `inbox` (reworded), `inboxFolder`, `inboxApprovals`.

Inventory: new entry APPROVAL-01 ("An open approval is always on screen, a closed one never") in `docs/inventory/inbox-folders.md`, guards `test_APPROVAL_01_native_card_when_recipe_off`, `test_APPROVAL_01_native_card_when_behind`, `test_APPROVAL_01_closed_never_drawn` (ask #451). It lands here, not with Tasks 7/8: the guarantee is the Desktop's native fallback and render-time check, which this task builds.

Also in this task:
- **Find Ideas in Past Messages…** moves into the ⋯ of the Idea finder legacy entry (the spec's Root ⋯ bullet and Decisions: agent's call); the action is today's (`InboxFilterBar`'s `onFindIdeas`). Test `InboxLegacyEntryMenuTests.testFindIdeasInPastMessagesInIdeaFinderMenu` (present there, absent from the root ⋯ and from every other entry); shot `inbox-b-idea-finder-menu` (Task 1).
- The Needs approval note's buttons: **Turn On** (recipe off) enables the `approval-cards` feature through the existing Feature Manager path (`FeatureManagerService.enableNow`, as the reaction cheat sheet's Turn On does), **Run History** (last run failed) opens the built-in's runs (`AutomationsViewModel.open(automationID:runID:)` with the latest failed run, then the Automations tab). Tests `NeedsApprovalNoteTests.testTurnOnEnablesApprovalCardsFeature`, `testTurnOnFailureShowsMessage`, `testRunHistoryOpensLatestFailedRun`.

Tests: `InboxFolderEntriesTests` (root composition on fixtures, a folder with artifacts of two automations, the Messages fallback's three conditions); `NeedsApprovalSelectionTests` (every spec case incl. artifact older than the approval, more than 50, recipe off, last run failed, a closed approval with a live artifact → nothing drawn); `refresh()` is still one pure read (`testRefreshIsAPureRead` green, STRIP-02).

Checks: `make test-swift FILTER='InboxFolderEntriesTests|NeedsApprovalSelectionTests|ActionStripAutomationOutputTests|ActionStripViewModelTests'`, `make lint-diff`.

## Task 13 — Native row actions for a `ref`

**Depends on:** Task 10, Task 12, A Task 1, A Task 10. Integration rule (A merged first). **Lane:** Swift.

Files: new `WatchtowerDesktop/Sources/Views/Inbox/Folders/InboxRefHooks.swift` — builds A's `ArtifactRefHooks` from `InboxRefState` (`isOpen` = shown), `InboxRowActionsView` (`nativeActions`, disabled in `.preview`) and `nativeKinds` (open, chat, agent for `inbox_item`; open for `reminder`); `ActionStripViewModel` gains `rowErrors: [InboxSelection: RowFailure]`, `func retryRow(_:) async`, and its `messageDone`/`hideMessage`/`snoozeMessage`/`markTrackDone`/`stopWatching`/`markReminderDone`/`snoozeReminder`/`approve`/`reject`/`retry`/`dismiss` record a failure on the row instead of only `lastError`; reminder Done / Snooze run `inbox approvals changed --ref reminder:<id>` after success (failure ignored, spec); `InboxRef` ↔ `InboxSelection` mapping; an `idea` row press opens `InboxIdeaPane`; Task 1's ref-row shots re-rendered through `ArtifactView`.

Tests (`InboxRowActionsTests`): per kind, the drawn action set equals today's card's set (one test per kind, the expected list taken from `InboxMessagePane`, `TrackCardActions`, `IdeaDetailPane`, the reminder card, `AgentActionCardView`); busy disables only that row; a failed write keeps the row with its message and Retry repeats exactly the same press; success removes the row and its count; duplicates suppressed; `.preview` draws disabled; a ref to a deleted record is not drawn; the reminder fire is called once after success and not after failure. STRIP-03 guards green (`testApproveDelegatesToTheComposedAgentActionFeed`, `testDismissDelegatesToTheComposedAgentActionFeed`).

Checks: `make test-swift FILTER='InboxRowActionsTests|ActionStripViewModelTests|TrackActionPressTests|DesignShotsTests'`, `make lint-diff`.

## Task 14 — The ⋯ menus, Move to folder, + New Artifact

**Depends on:** Task 4, Task 11, Task 12. Uses A Task 12's `AppState.openAutomationEditor(_:step:)` when merged; otherwise `AutomationsViewModel.showEditor` without a step (spec contract item 6). Integration rule (A merged first). **Lane:** Swift.

Files: Task 1's `InboxArtifactMenus` wired: Run Now → `AutomationsViewModel.runNow` (built-ins: `AutomationsCLI.run`), edit entries → the editor, Move to Folder ▸ → `InboxFoldersCLI.route`, Turn Off → `setEnabled` / `features disable <ids>` for a built-in, Run History → `AutomationsViewModel.open(automationID:runID:)` + switch to the Automations tab, Delete… → `AutomationsViewModel.delete` behind today's confirmation; + New Artifact… → `AutomationsViewModel.showNew` with the current folder carried as the route to set after save; the per-entry rules (no Delete for built-ins, no Move for `needs-approval`, no Run Now where `RunNow` is false).

Tests (`InboxArtifactMenuTests`): entries per automation kind (owner, built-in, needs-approval, built-in without Run Now); each entry calls the right verb with the right id; Move to Folder sends `route` with the current revision and handles a conflict like the menu; Turn Off of a built-in names its feature ids; a failure shows the CLI's text on the artifact header, never silently. + New Artifact…: `testNewArtifactRoutesSavedAutomationToCurrentFolder` (after the save, exactly one `inbox folders route <new id> --folder <current>` with the current revision), `testNewArtifactFromRootSendsNoRoute` (root = default, no call), `testNewArtifactCancelledSendsNoRoute`, `testNewArtifactRouteConflictShowsTryAgain` (the recipe stays saved, the line and Try Again as in the spec).

Checks: `make test-swift FILTER='InboxArtifactMenuTests|AutomationsViewModelTests'`, `make lint-diff`.

## Task 15 — A folder from the editor

**Depends on:** Task 4, Task 14. **Lane:** Go half then Swift half (one branch).

Files: Go — new read tool `list_inbox_folders` in `internal/tools/` (title, slug, parent slug; `CompanyData: false`), registered on the `automation_editor` surface in `buildToolRegistry` (`cmd/actions_registry.go`), pinned in `cmd/actions_registry_test.go`; the editor's draft cache gains a `folder` suggestion `{title, parent_slug}` (`internal/automations/authoring/`, `automation_draft_cache`); the `create-automation` skill text says how to suggest a folder; `docs/inventory/agent-actions.md` AGENT-04 note (one more read tool on `automation_editor`). Swift — the save sheet line "New folder: <title>, in <parent>"; after a successful save the `route --new-title` call; failure → "Saved. The folder was not created: <reason>" with **Try Again**.

Inventory: STRIP-03 — native row actions call today's functions; the Desktop's reminder writes also run `inbox approvals changed`, which only queues (ask #451).

Tests: Go — the tool returns the tree without hidden folders' children marked; it is not visible on any other surface; the draft cache round-trips the suggestion and drops it when the recipe text is discarded. Swift (`AutomationSaveFolderTests`) — save without a suggestion makes no folder call; with one, exactly one `route` after the save; save refused (CAS on the recipe) → no folder call; route conflict → the Try Again line, recipe stays saved; Try Again re-reads the revision first.

Checks: `go test ./internal/tools ./internal/automations/authoring`, `go test ./cmd -run 'ActionsRegistry'`, `make test-swift FILTER='AutomationSaveFolderTests'`, `make lint-diff`.

## Task 16 — The filters go

**Depends on:** Task 12, Task 13, Task 9 (or the Messages legacy entry in Task 12 stands in); the STRIP-01/02/03 and INBOX-05 edits are as approved in ask #451. **Lane:** Swift.

Files: delete `InboxFilter` (`WatchtowerCore/Services/Inbox/InboxCards.swift`), `Views/Inbox/InboxFilterBar.swift` (its **?** and ⋯ already moved in Task 11), the filter branches of `InboxListBuilder`; `ActionStripViewModel` drops `filter`, `filterKey` (`inbox.filter`) and `open(_ filter:select:)` in favour of `open(folder:select:)` and `inbox.folder`; `InboxRoute` becomes `{folderID, selection}` with `aliasHosts` and `forFeature` pointing at the root and the legacy entries; `ResultFilter`, card JSON `result_filter` and its Swift reader (Open in Inbox now opens the built-in's default folder); `EmptyStateCopy.swift` drops `briefings`, `inboxMessages`, `tracks`, `ideas`, `inboxAutomations` keys where only the Inbox used them (check every reader); Home's links into the Inbox; `docs/inventory/reaction-commands.md` (only STRIP-01's filter wording — "Automations filter", "All mix" — which this task's code removes), `docs/inventory/inbox-pulse.md` (INBOX-05: Learned Rules reached from the root's ⋯ now that the strip's ⋯ goes) — both approved in ask #451; the other inventory edits landed with their own tasks.

Tests: `InboxRouteTests` (every alias host and feature lands on the right folder and entry; an old `inbox.filter` value opens the root); `InboxListBuilderTests` reduced to what remains, none of its guard names removed without their behaviour going too; Home link tests; the full Inbox suite.

Checks: `make test-swift FILTER='Inbox|ActionStrip|Home'`, `make lint-diff`.

## Task 18 — Reply from a row (ask #445)

**Depends on:** Task 13 and the Task 1 owner checkpoint (Swift half, Swift lane); Go half: none (AGENT-03/AGENT-07 and the STRIP-01 Reply narrowing approved in ask #451). Includes the Waiting for me fixtures and shots. **Lane:** Go half then Swift half (one branch).

Files: Go — `internal/tools/slack_send.go`, `internal/tools/jira_write.go`, `internal/tools/linear_write.go` (`tools.InboxSurface` added to each tool's `Surfaces`); `cmd/actions_propose.go` (`--context <type>:<id>` stored as `context_type`/`context_id`, validated `inbox_item:<positive int>`; `--approve` refused for the tools of a new `tools.InboxReplyTools` list — the three above only — with "a reply is approved in Needs approval"; `apply_track_action --approve` unchanged); `cmd/actions_registry_test.go` (surface pins); `docs/inventory/agent-actions.md` (AGENT-03, AGENT-07 and the C1 note) and `docs/inventory/reaction-commands.md` (STRIP-01 narrowing), as ask #451 approved them. Swift — `WatchtowerCore/Database/Queries/AgentActionQueries.swift` (`fetchStrip` / `awaitingOwnerCount` leave out only `surface='inbox' AND tool='apply_track_action'`); new `WatchtowerCore/Services/Inbox/InboxReplyPolicy.swift` (`static func tool(for item: InboxItem) -> InboxReplyTool?` by trigger type, nil for mail, a missing permalink or key; `static func args(for:text:) -> String`); new `Views/Inbox/Folders/InboxReplyComposer.swift`; `InboxRowActionsView` gains **Reply…** and the "Reply waiting for approval" caption; `Views/Inbox/InboxMessagePane.swift` gains the same **Reply…**, composer and caption while the Messages legacy entry stands in for Waiting for me; the proposal's `reason` is "Reply from <host title>" (the artifact's title, or "Messages"); `ActionStripViewModel.proposeReply(_ itemID: Int, text: String) async` over `CLIRunnerProtocol`, recording a row failure on refusal; `InboxRefHooks.nativeKinds` adds `reply` for items with a Reply tool; the Task 1 shots `inbox-b-row-reply-composer`, `inbox-b-row-reply-refused` and `inbox-b-row-reply-pending` re-rendered from the live views.

Tests: Go — `TestActionsPropose_ReplyRecordsOnePendingRow` (each of the three tools: one pending row, `surface='inbox'`, context `inbox_item:<id>`, nothing applied, no Slack/Jira/Linear client called), `TestActionsPropose_RefusesApproveForReplyTools` (and `apply_track_action --approve` still works), refusal under every agent marker, `--context` malformed (`inbox_item:`, `x:1`, `inbox_item:-1`), a Slack permalink that does not resolve → refused with no row, a reply-in-thread link pins `thread_ts`; `apply_track_action` with `--approve` unchanged. Swift — `InboxReplyTests` (spec list, plus: the Messages stand-in card shows Reply before Waiting for me's first run and after a failed run; the reason names the host — "Reply from Waiting for me", "Reply from Messages", an owner artifact's title), `AgentActionQueriesTests.testStripShowsInboxReplyProposals`, `testStripAndBadgeLeaveOutInboxPressRows` still green.

Checks: `go test ./internal/tools`, `go test ./cmd -run 'ActionsPropose|ActionsRegistry'`, `make test-swift FILTER='InboxReplyTests|AgentActionQueriesTests|InboxRowActionsTests'`, `make lint-diff`.

## Task 17 — Guide, feature note, CLAUDE.md

**Depends on:** Tasks 1–16 and 18. **Lane:** docs.

Files: `docs/guide/features/inbox.md` rewritten per `docs/guide/WRITING.md` (folders, the root, Needs approval, Waiting for me, row buttons incl. Reply… and where the reply waits, the ⋯ menus, Learned Rules and Assistant Profile in the root's ⋯), its Learn cards: `inbox-filters` replaced through a §9.7 replace chain by `inbox-folders`, a card for Needs approval and one for Waiting for me, `since: next`; `docs/guide/features/automations-built-in.md` (the two built-ins, Sends lines); `docs/guide/features/automations.md` (`folder` on `output.inbox`, Move to folder); new `docs/features/inbox-folders.md` (architecture, contracts, the dual paths, v1 limits from the spec's non-goals); one CLAUDE.md "Feature Notes" line pointing at it; `docs/features/automations.md` and `docs/features/built-in-automations.md` cross-references.

Tests: `go test ./docs/guide` (`TestGuideCardsValid`, guide parse), `go test ./internal/learn`.

Checks: as above, `make lint-diff`.
