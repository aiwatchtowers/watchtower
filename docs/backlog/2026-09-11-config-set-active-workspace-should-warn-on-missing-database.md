---
type: chore
title: config set active_workspace should warn when the workspace has no database
status: open
priority: med
tags: [config, cli, workspace]
context: PR #150 review — the runSync guard for a typo'd active_workspace was rejected (legacy `workspaces:` block is a migration remnant, see validateSyncConfig's doc comment); the writer is the right place
created: 2026-09-11
---

`cmd/config.go`'s `config set active_workspace <name>` writes the key raw. A
typo makes the next daemon start create a fresh empty workspace under the
misspelled name while the Desktop's `resolveDBPath` first-match fallback keeps
showing the old database — the two halves diverge silently. Warn (not refuse:
a brand-new workspace legitimately has no database yet) when
`~/.local/share/watchtower/<name>/watchtower.db` does not exist, and list the
directories that do hold one.

> Original note: «`config set active_workspace <name>` не предупреждает, если под именем нет БД — writer-side защита от опечатки, правильное место для отклонённого guard'а.»
