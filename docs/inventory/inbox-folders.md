# Behavior Inventory — Inbox folders

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when changing how the Inbox menu's folders are written,
> deleted or routed, read this file first. Any proposed change that would
> break a guard test or remove a contract must be raised as a question
> before touching code.

**Module:** `internal/inboxfolders/`
**Last full audit:** 2026-11-06

## FOLDER-01 — Deleting a folder never deletes content

**Status:** Enforced

**Observable:** Deleting an Inbox folder removes that folder's row and nothing else, in one compare-and-set write on the tree's revision. Its child folders move to its parent, appended after the parent's children in their own order (their subtrees move with them); the automations routed to it are routed to the parent; the artifacts placed in it explicitly (`automation_outputs.folder_id`) are placed in the parent. No folder below it, automation, route or artifact is deleted, and the write reports how many folders, automations and artifacts it moved. The root (Inbox) and Needs approval cannot be deleted. A stale revision writes nothing.

**Test guards:**
- Guard: `internal/inboxfolders/folders_test.go::TestFolder01_DeleteMovesContentsUp`
- Supporting: `internal/inboxfolders/folders_test.go::TestDelete_EmptyFolderMovesNothing`, `TestDelete_AtMaxDepthChildrenMoveUpOneLevel`, `TestDelete_Refusals`, `TestWrites_StaleRevisionWritesNothing`

**Why locked:** A folder is the owner's arrangement of the Inbox menu, not a store of items (STRIP-02). If deleting a folder took its contents with it, tidying the menu would silently lose artifacts and stop automations from showing anywhere the owner looks; moving everything up one level keeps every item reachable and the delete safe to press.

**Locked since:** 2026-11-06

## Changelog

- 2026-11-06: file created with FOLDER-01, introduced by the Inbox builder's folders (sub-project B, board #1400; owner approval in ask #451).
