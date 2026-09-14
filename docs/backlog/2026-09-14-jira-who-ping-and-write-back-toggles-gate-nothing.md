---
type: chore
title: Jira who_ping and write_back toggles gate nothing
status: open
priority: med
tags: [jira, feature-flags, dead-code, audit-2026-09-13]
context: audit decision D4 — surfaced by the 2026-09-13 feature audit, still open after fix waves 3 and 4
created: 2026-09-14
---

The Jira feature toggles `who_ping` and `write_back` are wired everywhere except the
place that would make them mean something. Both appear in `internal/config/config.go`
(`WhoPing`, `WriteBackSuggestions`), in `internal/jira/features.go`'s label map and id
list, and in `cmd/jira.go`'s toggle setter — but the only consumer that would read them,
`jira.BuildFeatureContext`, has **no non-test callers**. Fix wave 3 turned `who_ping` on
by default and nothing observable changed, which is the clearest evidence the toggles are
inert.

Two ways out:

1. **Wire it.** Feed `BuildFeatureContext` into whichever prompts should respect the
   toggles. This is designing the feature, not adding a call — someone has to decide
   which prompts (briefing? day plan? meeting prep?) and what the toggles actually
   suppress.
2. **Delete it.** Remove both toggles and `BuildFeatureContext`, and stop shipping
   Settings switches that do nothing.

Recommendation: **delete**. Both original intents have since been realised by other
means — "Who to Ping" is served by the `find_experts` MCP tool in the developer surface,
and Jira write-back now goes through the agent-actions registry (`create_jira_issue`).
The toggles are a remnant of an earlier design.

Deleting also means removing the corresponding config keys, so check whether a config
migration is warranted (the `MigrateFeatureGates` / `MigrateJiraFeatureKeys` precedent)
or whether leaving stale keys inert in existing `config.yaml` files is acceptable.

> Original note: «D4 это давай обсудим» … «давай в беклог»
