# Behavior Inventory — Inbox folders

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when changing how the Inbox menu's folders are written,
> deleted or routed, or how Needs approval picks and draws its cards, read
> this file first. Any proposed change that would
> break a guard test or remove a contract must be raised as a question
> before touching code.

**Module:** `internal/inboxfolders/`; Needs approval's cards: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Inbox/` (`NeedsApprovalSelection`, `InboxFolderEntries`, `InboxFolderMenuSnapshot`)
**Last full audit:** 2026-11-06

## FOLDER-01 — Deleting a folder never deletes content

**Status:** Enforced

**Observable:** Deleting an Inbox folder removes that folder's row and nothing else, in one compare-and-set write on the tree's revision. Its child folders move to its parent, appended after the parent's children in their own order (their subtrees move with them); the automations routed to it are routed to the parent; the artifacts placed in it explicitly (`automation_outputs.folder_id`) are placed in the parent. No folder below it, automation, route or artifact is deleted, and the write reports how many folders, automations and artifacts it moved. A moved child whose title equals, ignoring case, a title among its new siblings is renamed with " (2)", " (3)"… (cut to fit 60 characters, slug unchanged) and reported; the delete is never refused for it. The root (Inbox) and Needs approval cannot be deleted. A stale revision writes nothing.

**Test guards:**
- Guard: `internal/inboxfolders/folders_test.go::TestFolder01_DeleteMovesContentsUp`
- Supporting: `internal/inboxfolders/folders_test.go::TestDelete_EmptyFolderMovesNothing`, `TestDelete_TitleClashIgnoringCaseRenamesMovedChild`, `TestDelete_TitleClashChainsNumbers`, `TestDelete_TitleClashRenameKeepsTheCap`, `TestDelete_AtMaxDepthChildrenMoveUpOneLevel`, `TestDelete_Refusals`, `TestWrites_StaleRevisionWritesNothing`

**Why locked:** A folder is the owner's arrangement of the Inbox menu, not a store of items (STRIP-02). If deleting a folder took its contents with it, tidying the menu would silently lose artifacts and stop automations from showing anywhere the owner looks; moving everything up one level keeps every item reachable and the delete safe to press.

**Locked since:** 2026-11-06

## APPROVAL-01 — An open approval is always on screen, a closed one never

**Status:** Enforced

**Observable:** Needs approval draws every open approval — an `agent_actions` row that waits on the owner (`AgentActionQueries.awaitingOwnerClause`, the Inbox badge's own predicate) and every due reminder (`status='pending' AND remind_at <= now`) — read in the same one `ActionStripViewModel.refresh()` read as the folder. Each is drawn by the `needs-approval` recipe's card only while all four hold: the `approval-cards` feature is on and the built-in is not stopped (`disabled_reason` empty), its latest finished run succeeded, its living card `action:<id>` / `reminder:<id>` exists, and that card's `written_at` is at or after the approval's last change (an action's latest of `created_at`, `decided_at`, `applied_at`; a reminder's latest of `created_at`, `remind_at` — Go's `OpenApproval.ChangedAt`). Otherwise today's native card draws it (`AgentActionCardView`, `SaveAutomationProposalPane`, the reminder card), so an approval never waits on a run, a failed, stopped, capped (more than 50) or behind run never hides one, and a new one shows at once (native above the recipe's cards). The built-in's cards are drawn only through the open approvals they show: a card whose approval is closed (decided, applied, dismissed, done, gone) is drawn in no folder and counted in none, whatever the run did, even before the run removes it.

**Test guards:**
- Guard: `WatchtowerDesktop/Tests/Core/Approval01Tests.swift::test_APPROVAL_01_native_card_when_recipe_off`
- Guard: `WatchtowerDesktop/Tests/Core/Approval01Tests.swift::test_APPROVAL_01_native_card_when_behind`
- Guard: `WatchtowerDesktop/Tests/Core/Approval01Tests.swift::test_APPROVAL_01_closed_never_drawn`
- Supporting: `WatchtowerDesktop/Tests/Core/NeedsApprovalSelectionTests.swift` (the four conditions, more than 50, mixed order, a closed approval's live artifact), `InboxFolderEntriesTests`, `ActionStripAutomationOutputTests::testRefreshIsAPureRead` (STRIP-02)

**Why locked:** Approvals are the one place the assistant waits on the owner before it acts. If the recipe-drawn view could hide an open approval (off, failed, behind) the action would wait unseen; if it could show a closed one, the owner would approve or dismiss something already decided. Reading the records at render time, in the same read as the folder, and falling back to the native card keeps Needs approval exactly the set of open approvals whatever the built-in did.

**Locked since:** 2026-11-08

## Changelog

- 2026-11-10 (Inbox builder final review, board #919; owner approval in ask #610): APPROVAL-01 amended — below the open approvals, Needs approval also draws the actions the owner already approved that are still `approved` or `executing` (applied in the background, stuck or still running), natively and uncounted: they are not open approvals, so neither the folder count nor the Inbox badge includes them, and they leave the folder once applied, failed or dismissed. Supporting: `InboxFolderEntriesTests::testNeedsApprovalKeepsApprovedAndExecutingRowsUncounted`.

- 2026-11-08 (Inbox builder B Task 12, board #1400; owner approval in ask #451): APPROVAL-01 added — Needs approval's native fallback and render-time check (`NeedsApprovalSelection`, `InboxFolderEntries`, the `needs-approval` cards taken out of every folder's artifact list in `InboxFolderMenuSnapshot.read`). New guards `Approval01Tests` (three), supporting `NeedsApprovalSelectionTests`, `InboxFolderEntriesTests`.

- 2026-11-06: file created with FOLDER-01, introduced by the Inbox builder's folders (sub-project B, board #1400; owner approval in ask #451).
