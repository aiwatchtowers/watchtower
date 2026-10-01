---
type: idea
title: Main chat reasoning effort picker next to the model picker
status: open
priority: med
tags: [chat, models, providers, effort, desktop]
context: docs/chat-projects-vision — backlog collection session, item 1
created: 2026-09-30
---

The main AI Chat lets the owner pick a model (dynamic picker with an **Auto**
default, fed by `AIModelCatalog`), but not the reasoning effort. Add an effort
selector next to it so a conversation can run e.g. a strong model at low effort
for quick answers, or high effort for hard questions.

Things to settle in the design:

- Where it lives: per conversation (like `chat_conversations.provider`/`model`,
  so it would need a column) or per turn.
- How it reaches the provider: the warm session child
  (`watchtower ai session`, `internal/chat/session.go`) would need an `--effort`
  flag mapped per backend — Claude CLI effort setting, Codex
  `model_reasoning_effort`, Ollama probably none (hide the control or show it
  disabled). Changing effort on a warm Claude session may require a respawn with
  `--resume`, the same way a model switch does.
- Keep the "no model names hardcoded in Swift" rule: the allowed effort levels
  per provider should come from the Go registry (`internal/providers`,
  `watchtower ai models --json`), not from Swift.
- Default = "Auto" (provider default), so existing conversations are unchanged.

> Original note: «В чате хочу еще эфорт выбирать а не тока модель»
