# Memory Browser — Desktop Tab (design)

**Date:** 2026-07-17 · **Branch:** `feature/memory-desktop-browser` → `feature/memory-phase5` · **Owner ask:** first-class in-app access to the secretary memory vault: browse + search, wiki-link navigation with backlinks, a beliefs dashboard, per-node git history, and in-app editing.

## What exists (read before changing)

- Vault: `<workspace>/memory/` — markdown nodes (`entities|episodes|rollups|beliefs/<id>.md`, plus `map.md`/`index.md`) in a go-git repo. Files + git are the source of truth (MEM-02/03, `docs/inventory/memory.md`).
- SQLite mirror in the shared DB the app already opens: `memory_nodes` (id/type/tier/status/title/path/subject/confidence), `memory_aliases`, `memory_fts` (FTS5 title+body), `memory_node_stats`, `memory_dispute_flags`.
- Cross-process lock: flock on `<workspace>/memory.lock` (`vault.Lock`, Go).
- MEM-03: a dirty vault worktree is committed as `owner-edit` by the next pipeline run; a file damaged by an owner edit is quarantined (skipped + counted, never deleted). This is what makes in-app editing safe without any Go changes.

**No Go/schema changes in this feature.** The Swift side reads the existing index, reads/writes vault files, and shells out to `git` for history — mirroring the Obsidian workflow the vault was designed for.

## UI

New sidebar destination `memory` ("Memory", `archivebox`) in the INSIGHTS section. `MemoryView` is an `HSplitView` master-detail (CatchUp pattern):

- **Master:** search field (FTS, term-quoted like Go `sanitizeFTS5Query`) + type filter chips (All / Entities / Episodes / Rollups / Beliefs) + node list (title, type chip, status, dispute badge). Tombstones hidden. Beliefs filter switches rows to belief form: confidence bar, subject entity, status (active/shaken/retired) and shows a summary header (counts, disputed, avg confidence).
- **Detail:** frontmatter header (type/tier/status chips, belief confidence + subject link, aliases, dispute banner with reason), body rendered by the house `MarkdownText` with `[[id|label]]` pre-converted to `watchtower-memory://<id>` links (tap = navigate, alias-resolved), **Backlinks** section (nodes whose body links here), **History** section (last N vault commits touching the file, `git log --follow` via subprocess), **Edit** button.
- **Editor:** raw whole-file editor (frontmatter + body, Obsidian-equivalent) in a sheet. Save takes the `memory.lock` flock non-blocking — if a memory run holds it, save fails with "memory run in progress"; otherwise atomic write + list/detail refresh. A caption notes that the next memory run commits the edit (MEM-03) and that a file with broken frontmatter is quarantined, not lost.

## Data flow

- **Vault path:** `dirname(dbPool.path) + "/memory"`; lock file `dirname(dbPool.path) + "/memory.lock"`.
- **List/search/beliefs:** GRDB reads of `memory_nodes` (+ LEFT JOIN `memory_dispute_flags`, subject title self-join). `ValueObservation` for same-process edits plus refresh-on-appear (daemon writes cross-process; observation won't fire — known gotcha).
- **Body + links:** read the node file (path column is vault-relative); strip frontmatter; parse `[[...]]` with the same regex as Go (`\[\[([^\[\]|]+)(?:\|([^\[\]|]*))?\]\]`).
- **Backlink graph:** built off-main by scanning vault `*.md` bodies for wiki-links (few hundred small files; re-scanned on tab appear / after save). Link targets resolve through `memory_aliases` when not a raw id.
- **History:** `Process` running `git -C <vault> log --format=<tab-separated> -n 50 [-- <path>]`; stdout/stderr drained concurrently (house CLI-helper pattern). git missing / not a repo → section hidden, no error.

## Files

| Layer | File |
|---|---|
| Model | `Sources/Models/MemoryModels.swift` |
| Queries | `Sources/Database/Queries/MemoryQueries.swift` |
| Utility | `Sources/Utilities/MemoryMarkdown.swift` (frontmatter split, wiki-link parse/convert — pure, unit-tested) |
| ViewModel | `Sources/ViewModels/MemoryViewModel.swift` |
| Views | `Sources/Views/Memory/MemoryView.swift`, `MemoryNodeRow.swift`, `MemoryNodeDetailView.swift`, `MemoryNodeEditorSheet.swift` |
| Nav | `SidebarDestination.swift`, `SidebarSection.swift`, `Navigation.swift`, `AppState.swift` |
| Badge | `SidebarCountsViewModel.swift` + `SidebarView.swift`: disputed-beliefs count |
| Tests | `Tests/MemoryQueriesTests.swift`, `Tests/MemoryMarkdownTests.swift`, `Tests/MemoryViewModelTests.swift` |

## Contracts touched

Read-side only; no guard test changes. MEM-03 is the enabling contract for editing (owner edits are first-class); MEM-02 means everything shown from SQLite is rebuildable. The editor never touches `.git` (no commits from Swift — the pipeline's owner-edit commit stays the single writer), never deletes files, and never writes outside the vault directory.
