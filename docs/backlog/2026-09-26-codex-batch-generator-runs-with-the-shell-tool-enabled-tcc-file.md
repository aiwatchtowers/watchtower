---
type: bug
title: "Codex batch generator runs with the shell tool enabled (TCC / file-read exposure)"
status: open
priority: med
tags: [codex, security, tcc, generator, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track bugs (Go AI pipelines/tools)
created: 2026-09-26
---

**Where:** internal/codex/generator.go:94-115, internal/codex/client.go:61-80
**Confidence:** med

The claude batch generator disables every tool (`--tools ""`, internal/digest/generator.go:104) and the claude chat client hides Bash/Read/Glob explicitly because folder probes trigger macOS TCC prompts attributed to Watchtower (a project P0) and because synced Slack/Jira text can carry prompt injections. The codex generator has no equivalent: `sandbox_mode=read-only` + `approval_policy=never` still lets the model run shell commands that read anywhere on disk (cwd is only a starting point). Every daemon pipeline on the codex provider (digests over untrusted Slack/Gmail/Jira text, memory, ideas) therefore runs an agent with a read-capable shell; an injected "list ~/Documents" or a curious model triggers a TCC prompt on the app or pulls local file contents into stored digests/Jira drafts. The security audit's X-2 noted "Bash is available on codex" for the chat path only. Fix direction: disable the shell/exec tool for `codex exec` batch calls (codex config feature flag for the shell tool, or an equivalent no-tools profile), and pin it with an args test like the claude side.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»
