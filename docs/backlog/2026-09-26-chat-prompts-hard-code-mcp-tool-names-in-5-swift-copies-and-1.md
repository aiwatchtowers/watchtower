---
type: chore
title: "Chat prompts hard-code MCP tool names in 5 Swift copies and 1 Go copy, with no check against the registry"
status: done
priority: med
tags: [prompts, swift, mcp, dual-path, review-2026-09-26]
context: main-branch backlog review 2026-09-26 at 8cf68dcf — track architecture
created: 2026-09-26
---

**Where:** ViewModels/IdeaChatViewModel.swift:308, MeetingChatViewModel.swift:338, TargetChatViewModel.swift:1105, ChatViewModel.swift:453, Views/Tracks/TrackChatView.swift:381, internal/ai/prompt.go:20; internal/tools/readtools.go:13
**Confidence:** high

Each Discuss prompt lists tool names inline as prose (`search_knowledge`, `list_messages`, `get_person`, `list_tracks`, `get_target`…; 16 more tool-name mentions besides `search_knowledge`). `tools.ReadTools()` is now the single registry that the MCP server and runtime B mount. Nothing fails if a tool is renamed or removed: the Swift tests assert that the prompt contains the text, not that the tool exists. The knowledge-search rollout had to edit all six copies by hand. Direction: expose the tool catalogue (`watchtower mcp tools --json`, or a generated `ToolCatalog.swift` checked in and verified by a Go test), then render the TOOLS block from it. The minimum step is a Go test that greps the Swift sources for `snake_case` tool tokens inside the TOOLS blocks and asserts each one is in `ReadTools()`.

> Original note: «а давай проведем ревью нашего репоза на ветке мейн с целью наполнения беклога. Наши треки - покрытие тестами, баги существующие и потенциальные, архитектурные проблемы, анализ использования и бессмысленный функционал»

**Resolution (2026-10-02, branch `fix/prompt-helpers-and-tool-names`):** the read-tool registry (`tools.ReadTools()` + `tools.DependentReadTools()`, what the MCP server mounts) is the one source of truth, and `internal/tools/prompt_mentions_test.go::TestPromptToolMentionsAreRegistered` pins every prompt copy to it: Go's `blocks.ToolsList`/`Workflow`/`LinkingRules` (the main AI Chat and CLI ask prompt — the old `internal/ai/prompt.go` copy moved there) and every `=== TOOLS` block under `WatchtowerDesktop/Sources` (today the meeting, idea, track and target Discuss surfaces; `ChatViewModel`'s copy left with the chat redesign) plus `ChatPromptRules.swift`. A tool mention is a snake_case token starting with a registered tool's verb, so field names (`channel_id`) and action kinds (`link_target`) are not mistaken for tools; a coverage floor fails if fewer than four tool-naming Swift blocks are found. Mutation-checked: renaming a tool in a Swift block or in `blocks.ToolsList` fails the test. Rendering the Swift TOOLS blocks from a generated catalogue was not done: the blocks carry per-surface wording, and a Go-side scan pins them without a Swift literal copy of the list or an ML-stack test link.
