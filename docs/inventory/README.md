# Behavior Inventory

This directory catalogs the **behavioral contracts** of each business module — the user-observable invariants that must not change without explicit owner approval.

Each entry is a guard against silent regression. Modifying any contract or its guard test requires explicit approval from @Vadym.

## Module → file mapping

| Module | Inventory file | Code paths |
|---|---|---|
| Inbox Pulse (attention detection) | [inbox-pulse.md](inbox-pulse.md) | `internal/inbox/`, `WatchtowerDesktop/Sources/Views/Inbox/` |
| Dashboard — **RETIRED 2026-09-14** | [dashboard.md](dashboard.md) | *(tombstone — no live code path; `situations`/`situation_signals` survive as read-only history behind two remaining readers, `ListSituationSignals` in `internal/db/situations.go` and `ConvertedSituationIDs` in `internal/db/memory.go`)* |
| Tracks | [tracks.md](tracks.md) | `internal/tracks/`, `internal/db/tracks.go`, `WatchtowerDesktop/Sources/Views/Tracks/`, `WatchtowerDesktop/Sources/ViewModels/TracksViewModel.swift` |
| Targets (brief chat + creation) | [targets.md](targets.md) | `WatchtowerDesktop/Sources/Views/Targets/`, `WatchtowerDesktop/Sources/ViewModels/TargetChatViewModel.swift`, `WatchtowerDesktop/Sources/Services/TargetActionExecutor.swift`, `WatchtowerDesktop/Sources/Services/TargetBriefCenter.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/` (ProposedAction, TargetActionParser, TargetComposerLogic, TargetQueries), `internal/prompts/defaults.go` (`defaultTrackRun` grammar) |
| Catch-up | [catchup.md](catchup.md) | `internal/catchup/`, `internal/db/catchup.go`, `internal/db/catchup_store.go`, `WatchtowerDesktop/Sources/{Views,ViewModels}/CatchUp*`, `WatchtowerDesktop/Sources/WatchtowerCore/{Models/CatchUpModels.swift,Database/Queries/CatchUpQueries.swift}` |
| Feature Manager | [features.md](features.md) | `internal/features/`, `internal/daemon/daemon.go` (phase gates), `cmd/features.go`, `internal/config/feature_migrate.go`, `WatchtowerDesktop/Sources/Services/FeatureManagerService.swift`, `WatchtowerDesktop/Sources/Views/Settings/` |
| Memory | [memory.md](memory.md) | `internal/memory/`, `internal/db/memory.go`, `internal/daemon/daemon.go` (`phaseMemory`), `internal/mcp/memory.go`, `cmd/memory.go` |
| Ideas & Decisions Registry | [ideas.md](ideas.md) | `internal/ideas/`, `internal/db/ideas.go`, `internal/jira/sync.go` (bounded comment sync), `internal/daemon/daemon.go` (`phaseIdeas`), `internal/tools/ideas.go`, `cmd/ideas.go`, `WatchtowerDesktop/Sources/Views/Ideas/`, `WatchtowerDesktop/Sources/Database/Queries/IdeaQueries.swift` |
| Developer Surface | [dev-surface.md](dev-surface.md) | `internal/mcp/`, `internal/tools/` (`taskcontext.go`, `experts.go`), `internal/devpack/`, `cmd/integrate.go` |
| Agent actions | [agent-actions.md](agent-actions.md) | `internal/tools/`, `internal/db/agent_actions.go`, `internal/mcp/actions.go`, `cmd/actions.go`, `cmd/mcp.go` (`--chat`), `WatchtowerDesktop/Sources/WatchtowerCore/Services/Actions/`, `WatchtowerDesktop/Sources/Views/Chat/AgentActionCardView.swift` |
| Quick Connections | [quick-connections.md](quick-connections.md) | `internal/db/external_connections.go`, `internal/externalmcp/`, `internal/mcpoauth/`, `internal/ai/client.go` (config merge + allowlist), `cmd/connections.go`, `cmd/generator.go` (`loadExternalMCPServers`), `WatchtowerDesktop/Sources/ViewModels/ExternalConnectionsViewModel.swift`, `WatchtowerDesktop/Sources/Views/Settings/{ConnectionsSettings,QuickConnectionsDetail,AddExternalConnectionView}.swift` |
| Reaction Commands + Inbox Action Strip | [reaction-commands.md](reaction-commands.md) | `internal/reactioncmd/`, `internal/db/reaction_commands.go`, `internal/db/reminders.go`, `cmd/reaction_commands.go`, `WatchtowerDesktop/Sources/Views/Inbox/ActionStripView.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/Actions/ActionStripViewModel.swift` |
| Owner identity | [owner-identity.md](owner-identity.md) | `internal/db/owner.go`, `internal/daemon/owner.go`, `internal/inbox/pipeline.go`, `internal/inbox/jira_detector.go`, `internal/inbox/style_sample.go`, `internal/jira/client.go` (`GetMyself`), `cmd/jira_owner.go`, `cmd/day_plan.go`, `cmd/briefing.go`, `cmd/tracks.go`, `cmd/profile.go`, `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/OwnerQueries.swift`, `WatchtowerDesktop/Sources/Views/Components/NoOwnerEmptyState.swift` |
| Knowledge Search | [knowledge-search.md](knowledge-search.md) | `internal/kb/`, `internal/tools/knowledge.go`, `internal/daemon/daemon.go` (`phaseKnowledgeIndex`), `cmd/kb.go` |

(Other modules will be added as their inventories are written.)

## Protocol

1. Before changing code under any listed path, **read the corresponding inventory file**.
2. Identify whether the change touches any `<MODULE>-NN` contract.
3. If yes, **stop and ask the owner** before proceeding. Quote the affected ID.
4. If approved, change code + guard test + inventory entry + changelog **in one atomic commit**.

There are no pre-commit hooks, CI gates, or codeowner enforcement. Protection rests on four soft layers:

- Guard tests fail at `make test`.
- Test name prefix (`TestInbox01_…`, `TestDigest03_…`) is greppable.
- `// BEHAVIOR …` comment markers show up in diff.
- AI assistant reads inventory before touching covered code.
