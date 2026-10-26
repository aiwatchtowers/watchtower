# Chats panel — implementation plan

**Spec:** [docs/superpowers/specs/2026-10-26-chats-panel-design.md](../specs/2026-10-26-chats-panel-design.md)
**Board:** #1095
**Branch:** `feature/chats-panel` (task lanes branch off it and merge back)
**Mockups:** [docs/design/mockups/chats-panel/index.html](../../design/mockups/chats-panel/index.html)

Every implementer reads the spec section its task names, `docs/review/review-rules.md` "Swift / Desktop conventions", and `docs/design/desktop-style-guide.md` (Desktop tasks). Task-scope checks only (CLAUDE.md "Agent-driven runs"): `go test ./internal/db` for Go, `make test-swift FILTER=…` + `make lint-swift` for Swift; the full gate runs once at the end (Task 11).

---

## Task 1 — Migration 00160: `chat_conversations.read_at`

**Depends on:** none · **Spec:** §5.2 "Read state"

- `internal/db/migrations/00160_chat_read_at.sql`: `ALTER TABLE chat_conversations ADD COLUMN read_at REAL;` then `UPDATE chat_conversations SET read_at = updated_at;`. Down: drop the column (SQLite ≥ 3.35 `DROP COLUMN`).
- Mirror into `internal/db/schema.sql`; regenerate `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`.
- Test: a migration test that an existing row gets `read_at = updated_at` and a new row has NULL.
- Checks: `go test ./internal/db`.

## Task 2 — Core: panel rows, read mark, three-part grouping

**Depends on:** Task 1 · **Spec:** §5.1, §5.2, §6

- `WatchtowerCore/Models/ChatConversation.swift`: decode `readAt` (optional).
- `WatchtowerCore/Database/Queries/ChatHistoryQueries.swift` (or the existing chat queries file): `panelRows(db, projectID: Int64?) -> [ChatPanelRow]` — one query: conversation columns, the last complete assistant message on the active branch (`created_at`, first 200 chars of `text`), the count of `agent_actions` with this `conversation_id` and `status = 'pending'`, the project name. `projectID == nil` = all chats.
- `ChatConversationQueries.markRead(db, id:, at:)`.
- `ChatPanelRow` (Core model): `conversation`, `lastAnswerAt`, `lastAnswerPreview` (first line, markdown stripped — reuse an existing strip helper if one exists), `pendingApprovals`, `projectName`, computed `isUnread`.
- `ChatPanelRowState` (pure): `answering | waitingForApproval | unread | read` with the spec's precedence, taking `isAnswering` from the caller; `secondLine(now:)` text per §5.1 (age formatter shared with the sessions panel).
- `ChatHistoryGrouping`: replace the six date kinds with `pinned | recent | older` (7-day boundary on `startOfDay`). Update its existing tests.
- Tests in `Tests/Core`: grouping, state precedence, second line, `panelRows` against the generated test schema (unread vs `read_at`, branch-only last answer, pending count, project filter).
- Checks: `make test-swift FILTER='ChatHistoryGrouping|ChatPanelRow|ChatHistoryQueries'`, `make lint-swift`.

## Task 3 — Core: project switcher presentation

**Depends on:** Task 2 · **Spec:** §4

- `ChatProjectSwitcherPresentation` (WatchtowerCore, pure): `Summary` per project (id, name, last activity, unread count, waiting count, answering count), `ordered`, `matching(query:)` (case/diacritic-insensitive name match), `segments(summary:now:)` → the shared segment model (tones: `badge`, `warning`, `secondary`).
- Query `ChatProjectQueries.switcherSummaries(db)` — per project: max chat `updated_at` (fallback project `updated_at`), unread count, pending-approval count. Answering counts come from the pool at render time.
- Tests: order, match, segments (plural forms "1 new answer"/"2 new answers").
- Checks: `make test-swift FILTER=ChatProjectSwitcher`, `make lint-swift`.

## Task 4 — Shared switcher popover pieces

**Depends on:** none · **Spec:** §4 "Implementation note"

- Generalise `WorkbenchSwitcherRow` + `WorkbenchStateSegments` into a shared `SwitcherPopoverRow` (name, isCurrent, tooltip, segments) and `SwitcherStateSegments` over a neutral tone enum; the workbench popover maps its `WorkbenchSwitcherPresentation.Segment` tones onto it. Place them beside the other shared panel pieces (DesignKit if it fits the kit's rules, else `Views/Components`).
- No visible change to the workbench switcher: its existing render tests must pass unchanged.
- Checks: `make test-swift FILTER='WorkbenchSwitcher'`, `make lint-swift`.

## Task 5 — Rename "AI Chat" → "Chats"

**Depends on:** none · **Spec:** §3

- `SidebarDestination.chat.title`, `KeyboardShortcutCatalog` area, every user-visible "AI Chat" string in `WatchtowerDesktop/Sources` (buttons "Open in AI Chat" → "Open in Chats", help, tooltips, empty-state copy). Leave raw values, identifiers, code comments and type names.
- Go: grep `internal/` and `cmd/` for user/model-facing "AI Chat" (prompts, nav rule) and update.
- Guide: text and titles in `docs/guide/**` (paths unchanged); `go test ./docs/guide` (8 KB cap, learn cards).
- Update tests that assert the old strings.
- Checks: `make test-swift FILTER='<touched test classes>'`, `go test ./docs/guide ./internal/<touched>`, `make lint-swift`.

## Task 6 — History view model: levels, rows, read marks

**Depends on:** Task 2 · **Spec:** §4 (levels), §5.2 (read state), §6

- `ChatHistoryViewModel`: `level: ChatPanelLevel` (`.all` / `.project(id)`), persisted per workspace in UserDefaults with fallback to `.all` when the project is gone; `rows` observed through `panelRows(projectID:)`; `sections` = the three groups; `olderExpanded` per level (UserDefaults); `pinnedOlderRow` (the on-screen chat inside a folded group).
- Read marks: `markRead(id)` when a conversation is selected and when `ChatViewModel.onTurnFinished` fires for the shown conversation (wire in `AppState+Chat.swift` / `ChatView`).
- Answering: rows read `ChatSessionPool.runningTurnID(conversationID:)` at render time.
- `ChatViewModel`: `landingProjectID` — the landing (and `+` in a project) creates the conversation with that project; `selectAdjacent` follows the new row order.
- Tests (Desktop): level persistence and fallback, read mark on select and turn finish, landing in a project creates the chat in it.
- Checks: `make test-swift FILTER='ChatHistoryViewModel|ChatViewModelLanding'`, `make lint-swift`.

## Task 7 — Panel header and project switcher

**Depends on:** Tasks 3, 4, 6 · **Spec:** §4

- `ChatSidebarView` header: `All chats ⌄` / `‹ 📁 name ⌄` + `+` (⌘N; in the project when one is selected). `‹` and ⌘[ (Chats tab only, not while a text field has focus — same rule as Workbench) go back to All chats.
- `ChatProjectSwitcherPopover`: Find project, RECENT (`SwitcherPopoverRow`), divider, New Project…, ‹ All Chats.
- Remove the PROJECTS section and the "New chat" row. In a project, the first row is **Project overview** (opens the project page; a tab when the page is on screen).
- Render tests for both levels and the popover.
- Checks: `make test-swift FILTER='ChatSidebarRender|ChatProjectSwitcher'`, `make lint-swift`.

## Task 8 — Rows and groups

**Depends on:** Task 6 · **Spec:** §5.1, §5.2, §6

- `ChatPanelRowView`: dot (pulse while answering, honours Reduce Motion), title (semibold when unread), second line; accessibility label naming the state.
- PINNED / RECENT / "▸ N older" header (`SessionsPanelFinishedHeader` shape — reuse it if it generalises cleanly), pinned on-screen row under a folded header, scroll-follow as today (`PanelSelectionScrollPolicy`).
- Render tests: each state, unread weight, folded/open older, pinned row.
- Checks: `make test-swift FILTER='ChatSidebarRender|ChatPanelRow'`, `make lint-swift`.

## Task 9 — Delete with Undo and the panel keyboard

**Depends on:** Task 8 · **Spec:** §5.3, §5.4

- `PendingChatDeletes` (Core, the `PendingSessionDeletes` twin — or generalise that type if it reads cleanly): hide on ✕, commit after the window, on another delete, on leaving the tab and on quit (hook into the quit path the session deletes use); Undo restores.
- ✕ on hover/cursor only when the row is neither answering nor waiting; the context menu's Delete… keeps the alert.
- Undo bar under the list (`SessionDeleteToast` shape, generalised or a chat twin).
- Keyboard: a `SessionsPanelKeyView`-style key handler — ↑/↓ cursor, Return, ⌘⌫, ⌘Z, ⌘1…⌘9 (registered only while the Chats tab is on screen; check no clash with the Workbench registration). `KeyboardShortcutCatalog` "Chats" entries.
- Tests: pending-delete timing (injected clock), undo, commit on quit, keyboard policy.
- Checks: `make test-swift FILTER='PendingChatDeletes|ChatPanelKeys|ChatSidebarRender'`, `make lint-swift`.

## Task 10 — Project page

**Depends on:** Task 6 · **Spec:** §7

- Rebuild `ProjectDetailView`: header (in-place name, ⋯ Rename / Delete Project…), the landing composer bound to the project (`landingProjectID`; Return sends and selects the new chat), "Chats in this project · N", right column with **Instructions** (preview + Edit in place) and **Knowledge** (files + sources merged, kind badges, remove on hover, + Add → Files… / Source…, drop zone); right column stacks under ~900 pt.
- `ProjectDetailViewModel` unchanged in data; add only what the merged Knowledge list needs.
- Render tests (wide and narrow), Knowledge merge order, Instructions edit/save/cancel.
- `make desktop-shots` of the page for the review.
- Checks: `make test-swift FILTER='ProjectDetail'`, `make lint-swift`.

## Task 11 — Docs and the gate

**Depends on:** Tasks 1–10

- Guide: `docs/guide/features/ai-chat.md` (panel, switcher, states, Undo, keyboard, project page), shortcut reference page; Learn card for the switcher if the section is new (`docs/guide/WRITING.md`).
- `docs/features/chat-redesign.md`: the panel paragraph (UI line) and the read-state column; CLAUDE.md's feature-note line if its summary changes; `docs/inventory/chat.md` title wording only.
- Full gate: `make test`, `make test-swift`, `make lint-all`; `make desktop-shots` of the panel (both levels, popover) and the project page attached to the PR.
