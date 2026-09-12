---
type: chore
title: DatabaseManager.resolveDBPath is the last first-match workspace guess
status: open
priority: med
tags: [desktop, workspace, dual-path]
context: PR #150 review — CLI resolveActiveWorkspace and Constants.activeWorkspaceDir both refuse to guess between several databases; WatchtowerDesktop/Sources/Database/DatabaseManager.swift resolveDBPath still opens the first sorted match
created: 2026-09-11
---

With two or more workspace directories holding a `watchtower.db`, the CLI
(`config.resolveActiveWorkspace`) and `Constants.activeWorkspaceDir()` leave
the workspace unresolved so the daemon refuses to start, but
`DatabaseManager.resolveDBPath`'s fallback loop still opens the first sorted
match. The Desktop can therefore show a database the daemon will never write
to. Align it with the single-candidate rule (or surface a chooser) so the two
halves agree on every config shape, not just the single-database one.

> Original note: «`DatabaseManager.resolveDBPath` при 2+ БД всё ещё угадывает first-match, пока CLI и `activeWorkspaceDir()` отказываются — следующий кандидат на выравнивание половин.»
