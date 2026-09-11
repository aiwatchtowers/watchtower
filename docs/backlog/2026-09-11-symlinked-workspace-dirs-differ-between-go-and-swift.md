---
type: bug
title: Symlinked workspace directories are candidates for Swift but not for Go
status: open
priority: low
tags: [config, desktop, dual-path, workspace]
context: PR #150 review — config.workspaceDirsWithDatabase vs Constants.singleWorkspaceWithDatabase
created: 2026-09-11
---

`workspaceDirsWithDatabase` (Go) uses `DirEntry.IsDir()`, which is false for a
symlink to a directory; `Constants.singleWorkspaceWithDatabase` (Swift) uses
`fileExists`, which follows symlinks. A symlinked workspace directory is thus
a Desktop candidate but not a CLI one — a residual dual-path mismatch. Either
resolve symlinks on the Go side (`os.Stat` instead of the entry type) or
document the difference next to the existing name-validator caveat.

> Original note: «Симлинк на директорию workspace: Go `IsDir()` его не считает, Swift `fileExists` следует — кандидат только для Desktop. Экзотика.»
