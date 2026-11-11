# Agent coach — Behavior Inventory

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `internal/coach/`, `internal/db/coach.go`,
> `internal/db/skill_pack_overlays.go`, `internal/prompts/additions.go`,
> `internal/daemon/coach.go`, `internal/tuning/`, `cmd/coach.go` or
> `cmd/tuning_deps.go`, read this file first. Any proposed change that would break a guard test or
> remove a contract must be raised as a question before touching code.

**Module:** `internal/coach/` + `internal/db/coach.go` + `internal/db/coach_signals.go` + `internal/db/coach_remeasure.go` + `internal/db/skill_pack_overlays.go` + `internal/prompts/additions.go` + `internal/daemon/coach.go` + `cmd/coach.go`; since the tuning chat (board #1517) also `internal/tuning/` (`propose_tuning_edit`, the chat's way in), `cmd/tuning_deps.go` and the read-only git helpers `PathStatus`/`ReadStatus`/`FileAtHead` in `internal/workbenchgit/status.go`
**Last full audit:** 2026-10-26 (created)
**Owner approval:** spec `docs/superpowers/specs/2026-10-26-agent-coach-design.md` (D3 asks #637, D6 #648); feature note `docs/features/agent-coach.md`.

---

## COACH-01 — nothing is applied without the owner's Accept, and a repository file only on the owner's Accept

**Status:** Enforced (Go).

**Observable:** The weekly pass and `coach run` only store proposals (`coach_proposals`, status `open`); every destination — the owner's session, procedure and chat texts, a prompt's additions, `~/.claude/settings.json`, `~/.claude/CLAUDE.md` — is unchanged until `Applier.Accept` (the owner's `coach accept`) writes that one proposal. `coach accept`, `decline`, `rollback` and `run` are refused under an AI agent's environment markers and otherwise need the owner's confirmation in the running Desktop (AGENT-07, ask #659). The weekly pass's destination set is the owner's own setup: a repository file (the repo `CLAUDE.md`, `.watchtower/*`, `.claude/skills/`, a project `.claude/settings.json`) is never one of its destinations, and the two files under the home folder are `<home>/.claude/settings.json` and `<home>/.claude/CLAUDE.md`. A model-proposed destination outside the set is dropped by `Validate`. (Chat proposals, below, add destinations; the weekly set is unchanged.) CLI additions that relax nothing: `coach status --days N` (1..90, default 14), `coach run` fails with code `busy` while another pass holds `<workspace>/coach.lock` (the daemon's weekly pass skips then), and with `--json` every failure object is also written as one JSON line on stderr (Execute() adds a prose line after it; a reader takes the last line that decodes as an object).

**Chat proposals (board #1517, tuning chat; spec `docs/superpowers/specs/2026-11-03-tuning-chat-design.md`, approved in ask #1112, COACH-01 amendments in asks #1018 and #1165):** the tuning chat files a proposal with `propose_tuning_edit` (`origin = 'chat'`, `conversation_id`); `coach.ValidateChatProposal` checks it and `db.InsertChatCoachProposal` stores it `open`, like any other proposal — nothing is written until the owner's Accept on the card, and the chat itself never writes a destination. A chat proposal may also name five global destinations under the owner's home folders, none per-workbench: `claude_skill_user` (`~/.claude/skills/<name>/SKILL.md`), `codex_skill_user` (the one of `~/.agents/skills/<name>/SKILL.md` and `<CODEX_HOME>/skills/<name>/SKILL.md` that holds the skill; a skill in both is refused, D71), `pack_overlay` (`skill_pack_overlays` lines rendered into Watchtower's pack skills, DEV-04), `codex_agents_md_user` (`<CODEX_HOME>/AGENTS.md`, the one file Accept may create there) and `codex_rules_allow` (`<CODEX_HOME>/rules/default.rules`, append-only through the same safe-rule table as Claude's allow list). The home folders may be symlinks to a real directory; nothing below them may (D71). Chat proposals take no weekly slot and pass no weekly floor or cap (D10), but one open proposal per destination text holds for both origins (`ErrCoachTextBusy`, `already proposed as #N`). The weekly pass never proposes a chat-only destination.

**Workbench repository files (owner, ask #1165, D66):** A chat proposal may edit five files of a workbench's own folder — `CLAUDE.md`, `AGENTS.md`, `.claude/skills/<name>/SKILL.md`, `.agents/skills/<name>/SKILL.md`, `.watchtower/workflow.md` — and no other repository file; the weekly pass never proposes one. Accept writes the file only when `git status` lists no change for it and the folder is a git work tree; Watchtower never runs a git command that writes, and the owner commits the change.

As shipped (asks #1169, #1173, #1229; D67, D68, D72): one destination per file kind (`repo_claude_md`, `repo_agents_md`, `repo_claude_skill`, `repo_codex_skill`, `repo_workflow`), the path derived from the workbench's own folder (never a session worktree, never through a symlinked folder) and the skill name, so no stored row names a path. `coach accept` refuses with code `dirty` (the path has uncommitted changes) or `not_git` (the folder is not a git work tree), and reports `written_path` (relative) on success; the git state reaches `internal/coach` only through the `RepoState`/`RepoBranch` seams, filled by `cmd`, the daemon and `internal/tuning` with the read-only helpers `PathStatus`, `ReadStatus` and `FileAtHead` (git `status`, `rev-parse`, `show` only). Only `CLAUDE.md` and `AGENTS.md` may be created; skills and `workflow.md` must exist. An Accept killed after the write and before its status write leaves the file uncommitted, so the next Accept is refused as `dirty` and the card stays open; once the owner commits the edit, Accept finds the file already holding the edit and records the proposal as accepted. Rollback runs no git check; it deletes `CLAUDE.md`/`AGENTS.md` whose `before_text` is empty (created, or empty before) only while the file still holds Accept's text — a changed file is kept even under force — and gives any other file its before-text back. The card names the branch the edit lands on (`written_branch`), and the 14-day verdict window starts at the first daily check that sees the edit at the folder's HEAD (`measure_from`); 30 days without the commit give `too_little_data`. No judge's cut is ever filed for these five.

**Judge's cut (asks #1018, #1169; D35, D67):** `writeCut` files no cut for `claude_settings_allow`, `codex_rules_allow` (grow-only: Accept would refuse a cut) or a workbench repository file, and counts only weekly proposals against the three open slots, so open chat proposals never stop a cut; a cut of a chat edit is an ordinary weekly proposal (D64).

**Per-agent measurement (board #1517, ask #1018, ask #1196):** A proposal is measured, baseline and verdict, on the agent its destination serves: Codex destinations on Codex rows, `pack_overlay`, `session` and `procedure` on both agents, every other destination on Claude rows. The workbench repository files follow the same rule: `repo_agents_md` and `repo_codex_skill` on Codex rows, `repo_workflow` on both, `repo_claude_md` and `repo_claude_skill` on Claude rows (`AgentFor`). A baseline taken on mixed rows before this rule is measured again once, at daemon start, for accepted proposals with no verdict or a `too_little_data` verdict.

**Why locked:** The coach turns an agent-visible signal into edits of the text every agent reads next. An edit applied on its own, or into a file a team shares, is a prompt injection path and a surprise for the owner (spec D3, D6).

**Test guards:**
- `internal/coach/coach01_test.go::TestCOACH01_NothingAppliedWithoutAccept` (a validated proposal stored by `Proposer.Run` leaves the three texts, the additions and both home files byte-identical; Accept changes only its own destination)
- `internal/coach/coach01_test.go::TestCOACH01_DestinationsAreNeverRepoFiles` (the destination set is pinned; repo-file destinations are dropped)
- `cmd/coach_test.go::TestCoachAccept_RefusedUnderAgent` (accept, decline, rollback and run refuse under a marker, the proposal stays open)
- `cmd/coach_test.go::TestCoachOwnerVerbs_NeedTheDesktopsConfirmation` (without a marker they run only after the Desktop confirms; no Desktop or a denial writes nothing)
- `internal/coach/judge_test.go::TestJudge_ClaudeDestinationIgnoresCodexRows` (a Claude destination's verdict ignores Codex rows)
- `internal/coach/remeasure_test.go::TestRemeasureMixedBaselines` (the one-time baseline re-measure on the destination's agent)
- `internal/coach/coach01_test.go::TestCOACH01_HomeDestinationsStayUnderHome` (the chat's destination set is pinned: the six weekly ones plus the five global ones, every path under the home folders)
- `internal/coach/coach01_test.go::TestCOACH01_RepoFilesOnlyInTheWorkbenchFolder` (the five repository destinations, their paths inside the workbench's own folder, a symlinked folder refused, never from the weekly pass)
- `internal/coach/coach01_test.go::TestCOACH01_NoGitWrites` (`internal/coach` imports no `workbenchgit` and starts no process; the coach and tuning paths in `cmd/coach*.go`, `cmd/tuning*.go`, `internal/daemon/coach*.go` and every file of `internal/tuning` call no `workbenchgit` helper but `PathStatus`, `ReadStatus` and `FileAtHead`; those run only `status`, `rev-parse` and `show`, pinned by `internal/workbenchgit/status_test.go::TestPathStatus_RunsOnlyStatus`, `TestReadStatus_RunsOnlyReadVerbs`, `TestFileAtHead`), with `TestCOACH01_NoGitWrites_ScansTheTuningPackage` (a planted write in `internal/tuning` is caught)
- `internal/coach/repofile_test.go::TestAccept_RepoFileDirtyRefused`, `TestAccept_RepoFolderNotGitRefused`, `TestAccept_RepoKilledBeforeStatusCAS_NextAccept`, `TestAccept_RepoClaudeMDCreatedAndRollbackDeletes`, `TestRollback_RepoCreatedFileForcedKeepsOwnerText`; `cmd/coach_test.go::TestCoachAccept_RepoCodes` (`dirty`, `not_git`, `written_path`)
- `internal/coach/propose_test.go::TestValidate_ChatProposalTakesNoWeeklySlot`, `TestProposer_ChatProposalsDoNotFillSlots`; `internal/coach/judge_test.go::TestJudge_NoCutForCodexRulesAllow`, `TestJudge_NoCutForRepoFile`, `TestJudge_CutWrittenWhileThreeChatProposalsOpen`, `TestJudge_RepoWindowStartsAtMeasureFrom`; `internal/coach/metrics_test.go::TestAgentFor`
- `internal/tuning/tools_propose_test.go::TestProposeTuningEdit_FilesChatProposal` (the chat's proposal is an `open` coach proposal, nothing written)

**Locked since:** 2026-10-26

---

## Changelog

- 2026-10-26 (agent coach Plan 1, board #1120): file created with COACH-01. Related amendments: SPECREVIEW (`not_useful` mark, `findings`) in `spec-review.md`, AGENT-07 in `agent-actions.md`, PROJ-22 in `workbench.md` (ask #659).
- 2026-10-28 (Plan 2): `--days`, `busy`, stderr echo; nothing relaxed.
- 2026-10-28 (Plan 2, ask #722): the one-time suggestion fold (`coach.ImportSuggestions`) only stores open proposals, like the weekly pass; COACH-01 unchanged. PROJ-22 amended in `workbench.md`.
- 2026-11-10 (board #1517, ask #1018, ask #1196): per-agent measurement; `session` and `procedure` on both agents, the one-time re-measure also covers `too_little_data` rows. COACH-01 otherwise unchanged; nothing relaxed.
- 2026-11-11 (board #1517, tuning chat; asks #1018, #1165, #1169, #1173, #1229): **COACH-01 amended by the owner (ask #1165):** the title "…and never a repository file" becomes "…and a repository file only on the owner's Accept"; chat proposals (`origin = 'chat'`) with five global destinations and no weekly gates (D10); the five workbench repository files in the owner's words, plus the as-shipped lines (D67, D68, D72); `writeCut` skips `codex_rules_allow` and the repository files and does not count chat proposals (D35, D67); `AgentFor` for the repository files. `TestCOACH01_NothingAppliedWithoutAccept` and `TestCOACH01_DestinationsAreNeverRepoFiles` unchanged in what they assert (the weekly set is still pinned and still drops repository files); new guards `TestCOACH01_HomeDestinationsStayUnderHome`, `TestCOACH01_RepoFilesOnlyInTheWorkbenchFolder`, `TestCOACH01_NoGitWrites` (+ `_ScansTheTuningPackage`). Nothing else relaxed.
