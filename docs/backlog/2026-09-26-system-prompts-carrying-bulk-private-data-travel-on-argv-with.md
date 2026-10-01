---
type: bug
title: "System prompts carrying bulk/private data travel on argv with no size guard (both CLI providers)"
status: done
priority: med
tags: [argv, arg-max, codex, claude, privacy, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go AI pipelines/tools)
created: 2026-09-26
---

**Where:** internal/codex/generator.go:104-106, internal/codex/client.go:74-76, internal/ai/client.go:229, internal/digest/generator.go:108-110; callers internal/briefing/pipeline.go:185-208, internal/targets/pipeline.go:116-120, cmd/targets_ai.go:538-549
**Confidence:** med

`digest.StdinThreshold` protects only the user message. Several pipelines put the whole data payload into the system prompt and a fixed one-liner into the user message: `briefing.daily` (all targets unbounded, inbox unbounded, up to 50 channel digests with topics, people cards, Jira, memory revisions), `targets.extract` (arbitrary pasted/inbox raw text + a 100-target snapshot + resolved Slack/Jira enrichments, and a retry that re-sends it), `tasks.update`. That system prompt goes to argv as `--system-prompt <text>` (claude) or `-c developer_instructions=<text>` (codex). Scenario: a large paste into target Extract, or a busy install's briefing, exceeds macOS ARG_MAX (1 MiB incl. environment) -> exec fails with "argument list too long"; for the briefing this burns the 3/day attempt budget and no briefing is produced. Independently of size, the payload is readable via `ps` for the process lifetime. This is a different consequence from the known P-1 (untrusted content in system prompt, security-audit) and X-1 (codex -c parsing). Fix direction: when the system prompt exceeds a threshold, move it into the stdin user message (or, for claude, `--system-prompt-file`/`--append-system-prompt-file` if the CLI supports it; for codex a temp config/instructions file), and add a size test alongside the existing stdin tests.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»

Resolved 2026-10-01 (fix/ai-process-security): a system prompt above `digest.StdinThreshold` (32 KiB) now leaves argv on all four Go sites — claude (`digest.ClaudeGenerator`, `ai.Client`) passes it as a 0600 `--system-prompt-file` removed after the call; codex (generator and client) moves the whole turn to stdin in the CHAT-04 `codexStdinContent` layout, since codex has no file form of `developer_instructions`. Smaller prompts keep their argv layout byte-for-byte (so a small private prompt is still visible to same-user `ps`). A failed temp-file write fails the call rather than falling back to argv. Not covered: the Desktop passes its chat system prompt to `watchtower ai query --system-prompt` on argv — split out to `docs/backlog/2026-10-01-desktop-passes-chat-system-prompt-to-ai-query-on-argv.md`. Pinned by `TestBuildArgs_LargeSystemPromptGoesToFile`, `TestQuerySync_LargeSystemPromptReachesCLIAndFileIsRemoved`, `TestClaudeGeneratorLargeSystemPromptViaFile`, `TestCodexArgs_LargeSystemPromptMovesTurnToStdin`.
