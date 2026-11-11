# Tuning chat — tune prompts, skills and agent instructions from Analytics (2026-11-11, board #1517)

Spec: `docs/superpowers/specs/2026-11-03-tuning-chat-design.md` (approved in ask #1112; scope cut in ask #1164; workbench repository files in ask #1165). Plan: `docs/superpowers/plans/2026-11-08-tuning-chat.md`. Builds on the agent coach (`docs/features/agent-coach.md`, COACH-01), agent analytics (`docs/features/agent-analytics.md`, AGENTLOG-01..07), the LLM usage ledger (`docs/features/llm-usage-ledger.md`) and the embedded chat (`docs/features/embedded-chat.md`). `Dnn` tags name the spec's decision list (§8).

## What it is

**Discuss in Chat** on a workbench's Analytics pane became **Tune** (icon `slider.horizontal.3`). It toggles a right side panel (`PanelSplit`, 460 pt by default, 360–720, remembered as `analytics.tuningPanelWidth`; Esc closes it; **Tune** has the selected look while it is open). The panel holds a chat that reads the owner's LLM setup — the workbench's agent report and sessions (Claude Code and Codex), the LLM ledger, Watchtower's prompts with their additions, global and pack skills, the instruction files and allow rules, and the workbench folder's own instruction files — and proposes edits.

**The chat never writes a destination.** An edit lands as an ordinary coach proposal (`coach_proposals`, `origin = 'chat'`) shown as the coach's card in the feed (**Decline**, **Edit…**, **Accept**; the panel shows Accept as a secondary button) and in the pane's **Proposed edits**. Accept does what the coach does today: compare-and-set, **Roll Back**, the 14-day verdict. A workbench repository file is written by Accept and committed by the owner; Watchtower never runs a git write.

Empty state: one figures line and up to four starters built from the report (`TuningChatTexts.figures`, `TuningChatTexts.starters`). Tool calls show as quiet lines (`TuningChatTexts.toolLine`). Conversations are chat rows with `context_type = 'analytics_tuning'` (`tuning.ContextType`, Swift `TuningChatSurface.contextType`) and `context_id` = the workbench id; **New** starts another, the picker lists the last 10 (`TuningChatSurface.recentLimit`). They show only in the tuning panel, never in the Chats panel (owner, ask #1123, D48).

## Surface `tuning`

- Declared together in six places: `tools.SurfaceTuning` (`internal/tools/surfaces.go`, in `tools.ChatSurfaces` and `tools.KnownChatSurface`, order pinned by `internal/tools/testdata/chat_surfaces.txt`, which the Swift `AssistantToolSurface.chatSurfaces` reads too), the `cmd/mcp.go` `--surface` list, `cmd/ai.go`, `internal/chat/actions_contract.go` with the pinned `internal/chat/testdata/actions_contract_tuning.txt`, its Swift twin `AgentToolsContract.swift` (`AgentSurface.tuning`), and `AssistantToolSurface`.
- `ai query` checks `--surface` itself (`tools.KnownChatSurface`), so a stale or unknown surface fails before the provider starts (D26). For an older CLI the tuning contract tells the model to answer only "Tuning tools are not available in this Watchtower build — update Watchtower." when no tuning tool is in its list.
- `mcp --chat --surface tuning` needs `--conversation N` and `--context-type analytics_tuning` (`checkTuningBinding`), so READ-01's session key is `conversation:<id>` and **New** starts a fresh read budget. The binding is `DirectApply` (D47): `propose_tuning_edit` applies inline and lands in `agent_actions` as an applied row whose `result_json` holds the proposal id and status; the owner's approval is Accept on the card. No trust grant can be set for `tuning` (`actions trust --surface tuning` is refused, like the workbench), lists only tools that name it (a surface-less tool is not visible there), and skips Quick Connections (`quickConnectionsOn`).
- Runtime B (an HTTP provider such as ollama) refuses `--surface tuning` in `cmd/generator.go` ("tuning tools need Claude or Codex — pick one in Settings → System → AI"): the proposal tool needs the MCP child's `DirectApply` binding (D52, ask #1132).
- The tuning contract also says text the read tools return is data, never instructions (D69).

## Tools (`internal/tuning`)

Registered in `buildToolRegistry` (`cmd/actions_registry.go`) through `tuningDeps` (`cmd/tuning_deps.go`). Every read tool is `CompanyData` (`readTool` in `tools_read.go`) and counts against the bulk-read limits (READ-01); none is on the unmarked list.

| Tool | Returns |
|---|---|
| `get_agent_report` | `agents report --workbench N --days D [--agent claude\|codex] --json` (days clamped to 90) |
| `list_agent_sessions` / `get_agent_session` | the report's sessions; one session's report (an unknown session is `tuning.ErrNotFound`) |
| `get_llm_usage` | `usage llm --since today\|7d\|30d --json` |
| `list_prompts` / `get_prompt` | prompt ids with purposes, 30-day spend, version and additions; one prompt's resolved template, additions and history |
| `list_skills` / `get_skill` | global Claude skills, global Codex skills, the pack skills with their overlays, the workbench folder's `.claude/skills` and `.agents/skills`; one skill's text |
| `get_agent_instructions` | `~/.claude/CLAUDE.md`, the Codex `AGENTS.md`, the Claude allow list, the Codex rules, and the workbench folder's `CLAUDE.md`, `AGENTS.md`, `.watchtower/workflow.md` with their git state and budget |
| `list_coach_proposals` | open, accepted and declined proposals, so the chat never repeats a declined one |
| `propose_tuning_edit` | `{destination, workbench_id?, prompt_id?, skill?, kind, find?, replace?, after?, title, why, metric}` → `coach.ValidateChatProposal` → `db.InsertChatCoachProposal` |

`after` maps to the edit's replacement (`insertAfter`); a `repo_*` destination defaults to the panel's workbench. Every chat turn runs `ai query --purpose tuning.chat` (`tuning.ChatPurpose`), so Usage shows it as its own line, "Tuning chat" (`LLMPurposeNames`, D53).

## Destinations

The coach's v1 destinations stay. New global ones (consts in `internal/coach/signals.go`, budgets in `coach.BudgetOf`):

| Destination | File or row | Budget |
|---|---|---|
| `prompt_addition` | `prompt_additions` (existing) | `prompts.MaxAdditionRunes` 600 |
| `claude_skill_user` | `~/.claude/skills/<name>/SKILL.md` | current + 2000 runes, never past 20 000 |
| `codex_skill_user` | `~/.agents/skills/<name>/SKILL.md` or `<codexHome>/skills/<name>/SKILL.md` (`coach.CodexSkillPath`) | the same |
| `pack_overlay` | `skill_pack_overlays` rows | 1000 runes per skill |
| `codex_agents_md_user` | `<codexHome>/AGENTS.md` (created when absent) | current + 400, never past 4000 |
| `codex_rules_allow` | `<codexHome>/rules/default.rules` | grow only, safe table lines |

- **File rules** are `writeClaudeMD`'s: a regular UTF-8 file of at most 256 KB, an atomic write with a re-read just before the rename, Accept against `before_text`, Rollback restoring it or `ErrChangedSince` with the diff. No symlink below the home folder; the home folders themselves (`~/.claude`, `~/.agents`, the Codex home) may be symlinks (dotfiles, D71). A skill must already exist: the chat never creates one (D14); only the Codex `AGENTS.md` may be created, and its rollback leaves an empty file.
- **Codex skills.** A name in both `~/.agents/skills` and the Codex home's `skills` is refused at propose, Accept and Rollback with "Codex sees this skill in two folders … — remove one copy first." (`CodexSkillPath` returns `ok = false`); `list_skills` shows both copies with that note (ask #1202).
- **Pack overlays.** A pack skill installs as the shipped bytes plus, when the owner has overlay lines, a `devpack.OverlayHeading` block (`## Owner additions (approved by the owner)`) right after the frontmatter. `installSkill` digests the rendered bytes, so an overlay is not drift (DEV-04, D15) and a pack upgrade carries the overlay. Accept and Rollback re-render the copies in every owner workbench folder at once (`Applier.rerenderPack`, `devpack.RerenderSkill`/`RerenderFolderSkill`) and report the updated and hand-edited counts; `integrate` and every `workbenchSetupOptions` path (`withInstallOverlays`) render them too. A hand-edited copy stays drifted and the overlay does not reach it. There is no daemon drift pass.
- **Codex rules.** `coach.CodexSafeAllowRule` is `SafeAllowRule`'s table in Codex form (`coach.CodexRuleLine`, `prefix_rule(pattern=[…], decision="allow")`), kept equal by a test (D16). The file is append-only for us; Rollback removes only the lines its proposal added.

## Workbench repository files (§4.3a, D66/D67/D68/D72)

Five chat-only destinations inside the workbench's own folder (`projects.folder_path`, never a session worktree); the path is derived from the destination, folder and skill (`coach.RepoRelPath`), so no row or model names another file:

| Destination | File | Missing file | Measured on |
|---|---|---|---|
| `repo_claude_md` | `CLAUDE.md` | created | Claude |
| `repo_agents_md` | `AGENTS.md` | created | Codex |
| `repo_claude_skill` | `.claude/skills/<name>/SKILL.md` | refused | Claude |
| `repo_codex_skill` | `.agents/skills/<name>/SKILL.md` | refused | Codex |
| `repo_workflow` | `.watchtower/workflow.md` | refused | both |

- The weekly proposer never proposes one (they are not in `textDestinations`), and the judge's cut is never filed for one (D67). A pack copy is refused ("propose a pack_overlay"). Budget: the skill rule for all five.
- **Git is read only**, through `workbenchgit.PathStatus` (`git status --porcelain=v1 -z -- <rel>`), `workbenchgit.ReadStatus` (the branch) and `workbenchgit.FileAtHead` (`git show HEAD:./<rel>`), called from `cmd` (`coachRepoState`, `coachRepoBranch`), the daemon and `internal/tuning`. `internal/coach` gets git state only through the seams `Applier.RepoState`, `Applier.RepoBranch` and `Env.RepoState`, which have no default there.
- **Refusals.** A listed path (modified, staged, untracked, conflicted) refuses Accept with "<path> has uncommitted changes — commit or discard them, then press Accept again." (`coach.ErrRepoDirty`, CLI code `dirty`); an ignored path is clean. A folder that is not a git work tree, or no git, refuses at propose and at Accept (`coach.ErrRepoNotGit`, code `not_git`). Other refusals are `coach.ErrRefused` (code `refused`).
- **Accept** runs the dirty check, reads the file, compares with `before_text`, writes atomically, then moves the status by compare-and-set and stores `written_branch`; `coach accept --json` gains `written_path` (relative) and `written_branch`. The open card names the branch from `coach proposals --json` `folder_branch`. Accept killed before its status write leaves the next Accept refused as dirty until the owner commits, then records the proposal as accepted (D72).
- **Roll Back** runs no dirty check and restores `before_text` while the file still equals `after_text`; a `CLAUDE.md`/`AGENTS.md` whose `before_text` was empty is deleted (only while unchanged). The owner commits the revert.
- **Measurement starts at the commit** (D68): the daemon's coach phase runs `coachCommitCheck` once a day over `db.ListRepoProposalsAwaitingCommit` and, the first time the file at HEAD equals `after_text`, sets `measure_from` (`db.SetCoachMeasureFrom`, compare-and-set on `measure_from IS NULL`). The judge's window starts there; 30 days after Accept without it (`repoCommitWait`) the verdict is `too_little_data`.

## Chat proposals

- Migration `00187_tuning_chat.sql` rebuilds `coach_proposals` (wider `destination` CHECK; new `origin` `weekly|chat`, `skill`, `conversation_id` → `chat_conversations` ON DELETE SET NULL, `written_branch`, `measure_from`) and adds `skill_pack_overlays(id, skill, text, proposal_id, created_at)`.
- `coach.ValidateChatProposal(ctx, d, e ChatEdit, env Env)` is `Validate` minus the two weekly gates (no 3-source floor, no 3-open cap, D10). Everything else stays: allowed destination, `find` once in whole lines, budget, `SafeAllowRule` and its Codex twin, fingerprint uniqueness ("already proposed as #N (<status>)"), one open proposal per destination text. Refusals wrap `coach.ErrRefused` and go back to the chat as tool errors.
- A `prompt_addition` is refused for a prompt `prompts.TakesAdditions` rejects: a `MovedToBuiltin` prompt ("<prompt> belongs to a built-in automation") or a custom-track prompt `TrackRun`/`TrackShortlist`/`TrackCompose` ("<prompt> does not take additions"). One function, `coach.PromptAdditionRefusal`, is called by `ValidateChatProposal` and by `ValidateAfter`, so Accept checks it too.
- `db.InsertChatCoachProposal(p, convID, now)` is one short write transaction: a fingerprint conflict returns `0, nil`; another open proposal on the same text is `db.ErrCoachTextBusy`; a deleted conversation is `db.ErrConversationRemoved`.
- `keyOf(dest, wb, prompt, skill)` keeps `skill` for the per-skill destinations, so two skills are two texts.
- `writeCut` (the judge's cut of a `no_effect` edit) counts only weekly proposals against the 3-open cap (`weeklyOpen`), skips `claude_settings_allow`, `codex_rules_allow` and the five `repo_*` destinations, and files a cut of a chat edit as a weekly proposal with no conversation and the original's destination and skill (D64).
- Each proposal is measured on the agent its destination serves (`coach.AgentFor`); baselines taken on mixed rows were re-measured once at daemon start (`db_maintenance` key `coach_baselines_per_agent`). Details in `agent-coach.md`.
- A chat proposal whose conversation was deleted stays in **Proposed edits** with **Decline**, so it never blocks its text for good.

## Desktop

- `TuningChatSurface` (`Services/ChatSurfaces`): `.actions(surface: "tuning")`, database persistence, owner instructions on, the tuning rules + actions contract + chat questions contract, the period and workbench in every turn, purpose `tuning.chat`. Tools only on a provider `AIModelCatalog.isKnownCLI` knows; ollama, an unknown id or an unread catalog is `.draftOnly` (D52) — decided through the catalog's kind, never a provider name (LLMTRANSPORT-01).
- `TuningChat` (`@MainActor @Observable`, the `AutomationEditorChat` shape): the engine from `EmbeddedChatCenter`, the recent conversations and the cards; re-decides tool access before each owner turn; Accept / Decline / Roll Back go through `CoachCenter` and stay enabled with no tools.
- `TuningFeedCards` (WatchtowerCore) places proposal cards in the feed from the `propose_tuning_edit` actions' `proposal_id`; `TuningChatTexts` (WatchtowerCore) holds every visible string, the repository lines included (`acceptedRepoFile`, `committedRepoFile`, `awaitingCommit`, `notCommitted`, `rolledBackRepoFile`, `repoDirty`, `repoNotGit`, `noTools` = "Tuning tools need Claude or Codex — pick one in Settings → System → AI").
- Views: `TuningPanelHost`, `TuningPanelView` (`Views/Workbench/Analytics`), opened from `AgentAnalyticsPaneView` (`tuningWidth`).
- Agent filter: **All / Claude Code / Codex** in `AgentAnalyticsHeaderView`, shown only with both agents in the period or a non-All choice, help `AgentAnalyticsFormat.agentHelp` (D57); main's **Not measured for Codex sessions.** caption stays (D51).

## Codex analytics

Codex prices and repricing, the cache-write mapping and `codex_usage_mismatch`, sub-agents through the parent's spawn link, the report's `--agent` filter and the daemon's login-shell `CODEX_HOME` are described in `agent-analytics.md`.

## Writers and races

| Data | Writers | Who wins |
|---|---|---|
| `coach_proposals` | weekly proposer and judge (daemon), `coach run`, `propose_tuning_edit` (MCP child), Accept/Decline/Rollback (CLI) | fingerprint UNIQUE and one open per destination text; status changes by compare-and-set |
| home destination files | Accept/Rollback, the owner, Claude Code or Codex | re-read before rename; `before_text` mismatch → stale |
| workbench repository files | Accept/Rollback, the owner, any session in the folder, the owner's git | dirty check, then re-read before rename; no git write |
| `skill_pack_overlays` + pack copies | Accept/Rollback, `integrate`, workbench setup | the overlay row is the truth; a re-render is idempotent; a hand-edited copy is left alone |
| `measure_from` | the daemon only | compare-and-set on `measure_from IS NULL` |

## v1 limits

- No A/B replay of prompt additions and no prompt-input capture (a later plan, D61); every edit is judged only by the 14-day verdict.
- No tuning tool reads company source text (D62), so no removal machinery exists for tuning conversations or chat proposals. Tuning conversations stay out of ideas mining, the `chat_artifact` source and the memory chat readers (D63).
- No new skill is created; only `AGENTS.md`/`CLAUDE.md` may be (D14, D67). No prompt template edit, no model or tier choice per purpose.
- No repository file outside the five, no file outside the workbench folder, no git write.
- Codex sessions count only when started from a Watchtower workbench terminal (D49); a plain shell or `codex exec` run is never read.
- Codex input above 272K tokens is priced at the standard rate, not OpenAI's long-context rate, so very long Codex sessions are under-priced.
- In a CRLF repository the HEAD text `FileAtHead` returns (git's stored blob) can differ from the working-tree `after_text`, so the commit is not seen and the edit ends `too_little_data`.
- `FileAtHead` reads the file at HEAD with no size cap.
- The "Not committed in 30 days — not measured" line also covers a folder git could not read for 30 days (gone, no longer a work tree, git failing): the daily check skips such a row and the 30-day rule ends it.
- Sessions in worktrees created before the commit, or on a branch without it, still run without the edit; the verdict mixes them.

## Tests

- Migration: `TestMigration00187_CoachRebuildKeepsRows`, `_DestinationCheck`, `_FailureLeavesNothing`, `_DanglingLinkAborts`, `_DownUp`.
- Coach: `TestValidateChatProposal_*` (`_Refusals`, `_NoSourceFloorNoCap`, `_SkillsAreSeparateTexts`, `_AfterAcceptRevalidates`, `_DeletedConversationProposalCanBeDeclined`, `_RepoArgs`), `TestInsertChatCoachProposal_*`, `TestTakesAdditions`, `TestCodexSkillPath_OneCopyOnly`, `TestCodexSkill_TwoCopiesRefused`, `TestCodexRules_*`, `TestWriteCut_*`, `TestAgentFor`, `TestJudge_ClaudeDestinationIgnoresCodexRows`, `TestAccept_PackOverlayRendersEveryCopy`, `TestRollback_PackOverlayRemovesItsLinesAndRerenders`, `TestInstall_OverlayIsNotDrift`, `TestInstall_UpgradeCarriesOverlay`.
- Repository files: `TestAccept_Repo*` (`_FileWritesAndRunsNoGitWrite`, `_FileDirtyRefused`, `_FileIgnoredIsClean`, `_FolderNotGitRefused`, `_ClaudeMDCreatedAndRollbackDeletes`, `_SymlinkedFolderRefused`, `_AgentWritesBetweenCheckAndRename_IsStale`, `_KilledBeforeStatusCAS_NextAccept`, `_RecordsBranch`), `TestRollback_RepoAfterOwnerCommit`, `TestRollback_RepoChangedSince`, `TestPathStatus_*`, `TestFileAtHead*`, `TestRepoMeasureFrom_*` (daemon).
- Guards: `TestCOACH01_HomeDestinationsStayUnderHome`, `TestCOACH01_RepoFilesOnlyInTheWorkbenchFolder`, `TestCOACH01_NoGitWrites` (+ `_ScansTheTuningPackage`), `TestCodeQuestionGuard_NoGoToolReadsChatHistory`, `TestListChatTurnsForIdeas_SkipsTuningChats`, `TestChatArtifactSource_SkipsTuningChats`.
- Surface and tools: `TestMCP_SurfaceFlagRejectsUnknown`, `TestActionsContract_TuningPinnedLines`, `TestProposeTuningEdit_*` (`_FilesChatProposal`, `_Refusals`, `_FingerprintRaceIsAlreadyProposed`, `_ConversationRemoved`), `TestTuningSurface_*` (`_OnlyWriteToolIsTheProposal`, `_ChildKilledAfterProposalCommit`, `_ReadLimitResetsOnNewConversation`, `_AcceptRacingNewProposal`, `_NoTrustPlace`, `_MainChatRowsUntouched`, `_ChatPurposeAccepted`), `TestCoachProposals_JSONKeysPinned`, `TestCoachAccept_JSONKeysPinned`.
- Desktop: `TuningChatTextsTests`, `TuningFeedCardsTests` (Tests/Core), `TuningChatSurfaceTests`, `TuningChatTests`, `TuningPanelViewTests`, and the tuning DesignShots on the real views.
