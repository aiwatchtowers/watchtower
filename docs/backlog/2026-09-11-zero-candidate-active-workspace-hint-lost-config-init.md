---
type: bug
title: Zero-candidate active_workspace hint lost the config init pointer
status: open
priority: low
tags: [config, cli, ux]
context: PR #150 review (fix/daemon-start-without-workspaces-entry) — judge verify round, internal/config/config.go ValidateWorkspace
created: 2026-09-11
---

`ValidateWorkspace` now tells the user to point `watchtower config set
active_workspace <name>` at "the folder under ~/.local/share/watchtower holding
watchtower.db". On a fresh install no such folder exists yet, so the hint is a
dead end; the pre-PR wording named `config init`. Branch the message: zero
candidates → mention `config init` / `auth login`; several candidates → the
current list of names (already implemented).

> Original note: «Сообщение при нуле кандидатов потеряло подсказку `config init` — на свежей инсталляции советует папку с `watchtower.db`, которой ещё нет.»
