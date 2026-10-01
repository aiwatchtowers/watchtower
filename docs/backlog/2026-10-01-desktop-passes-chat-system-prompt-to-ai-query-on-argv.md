---
type: bug
title: "Desktop passes the chat system prompt to `watchtower ai query` on argv"
status: open
priority: low
tags: [argv, privacy, desktop, chat]
context: split out of docs/backlog/2026-09-26-system-prompts-carrying-bulk-private-data-travel-on-argv-with.md (fix/ai-process-security, 2026-10-01)
created: 2026-10-01
---

**Where:** WatchtowerDesktop/Sources/WatchtowerCore/Services/WatchtowerAIService.swift (`args += ["--system-prompt", systemPrompt]`)

The Go side now keeps a system prompt above `digest.StdinThreshold` off the claude/codex argv, but the Desktop hands the target/idea/onboarding chat system prompt to `watchtower ai query --system-prompt <text>`, so it sits on the Go process's own argv (ARG_MAX, `ps`) before that logic runs. Fix direction: a `--system-prompt-file` / stdin flag on `ai query` (the warm `ai session` already takes its prompt off argv), used by the Desktop for every prompt.
