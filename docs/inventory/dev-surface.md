# Behavior Inventory — Developer Surface

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `internal/mcp/`, the registry's read tools
> (`internal/tools/taskcontext.go`, `experts.go`), the workbench tools
> (`internal/tools/workbenches.go`, `workbench_targets.go`, `workbench_docs.go`,
> `workbench_scope.go`, `workbench_names.go`) or the registry's `DirectApply` path, `internal/devpack/`,
> `cmd/mcp.go`, or `cmd/integrate.go`, read this file first. Any proposed change
> that would break a guard test or remove a contract must be raised as a
> question before touching code.

The MCP tools, skill pack, and installer that make Watchtower addressable
from a developer's coding agent. Design:
`docs/superpowers/specs/2026-08-09-dev-knowledge-base-design.md`.

**Module:** `internal/mcp/` (`get_task_context`, `find_experts`) +
`internal/devpack/` + `cmd/integrate.go` + `cmd/mcp.go` (`--workbench`, DEV-06) +
`internal/tools/{workbenches,workbench_targets,workbench_docs,workbench_images,workbench_scope,workbench_names}.go`
**Last full audit:** 2026-08-09

## DEV-01 — read-only forever

**Status:** Enforced

**Scope (amended 2026-09-29, spec `docs/superpowers/specs/2026-09-29-project-board-poc-design.md` D5; flag renamed 2026-10-02, legacy spelling removed 2026-10-15):**
"read-only forever" is a promise about `watchtower mcp` **without**
`--workbench` — the server plain
`integrate claude-code` registers for any coding agent. `watchtower mcp
--workbench N` is the one writable mode of this surface and has its own
contract, DEV-06; `--chat` is governed by AGENT-01/02/06
(`agent-actions.md`). Plain `watchtower mcp` still mounts no
workbench tool, no write tool and no `get_action`, and still runs under
`query_only` (`TestDev06_PlainMCPStaysReadOnly`).

**Observable:** Every tool on the plain `watchtower mcp` surface is a read. The real enforcement is
connection-level: `cmd/mcp.go` calls `database.SetReadOnly()` before serving,
which flips the connection to `PRAGMA query_only=ON` (`internal/db/db.go`'s
`SetReadOnly`) — any write a handler attempted would fail at the SQLite
level, not just by convention. The MCP test session helper
(`internal/mcp/server_test.go`'s `newTestSession`) mirrors this exactly,
calling `SetReadOnly()` on the same database before wiring the test server,
so a handler that tried to write fails in tests the same way it would in
production.

Since the read-tool migration (2026-09-06), the pure-`db` read tools no longer
live in per-domain `internal/mcp` handlers: they are `tools.Tool{Access:
AccessRead}` entries in the registry (`internal/tools`, listed by
`tools.ReadTools()`), dispatched through `Registry.CallRead` — which runs the
tool's `Execute` and records **no** `agent_actions` row (a read is not a
proposal). Dev mode builds a read-only registry (`tools.NewReadRegistry`) so
`NewServer` mounts these reads from the one registry both server modes share;
the `query_only=ON` fence above is unchanged and still the real enforcement.

Since slice 2b (2026-09-07) the dependency-carrying read tools moved too:
`memory_map`/`memory_open`/`memory_recall` (`internal/tools/memory.go`) and
`load_skill` (`internal/tools/skills.go`) are now `tools.Tool{Access:
AccessRead}` entries as well, but — because they close over a vault path, a
skills directory and the optional recall-compare shadow handle rather than only
`*db.DB` — they cannot sit in the zero-arg `tools.ReadTools()` list. `NewServer`
builds them from the paths it resolved (`tools.DependentReadTools`) and
registers them onto its registry, so `registerRegistry` mounts them through
`CallRead` like every other read; `internal/mcp` no longer carries any
per-domain handler. The documented telemetry-write exception is unchanged and
still runs through the Execute-supplied connection: `memory_open`'s
`memory_node_stats` bump lands on the writable chat session and fails silently
under `query_only` on the dev session; `memory_recall`'s shadow row writes only
when the separate writable shadow handle is wired
(`memory.retrieve.recall_compare`). (The runtime-B loop builds its registry from
`tools.ReadTools()` alone, so it does not mount these four yet — a follow-up.)
Automations (spec `docs/superpowers/specs/2026-10-14-automations-design.md`
§6.1, §20.1 D23) mount the three memory tools — not `load_skill` — through
`buildAutomationRegistry` (`cmd/automations_registry.go`), with no shadow
handle, so an automation's `memory_recall` writes no shadow row; and
`memory_open` skips its `memory_node_stats` bump when the binding's surface is
`automation`. The telemetry exception is therefore narrower there: an
automation's memory reads write nothing.

`TestAllToolsAreReadOnly` is a **naming-convention lint only** — it checks
that every registered tool name starts with `list_`/`get_` or appears in an
explicit `readVerbs` allow-list (`memory_map`, `memory_open`,
`memory_recall`, `find_experts`). It says nothing about what a handler
actually does to the database.

The behavioral guard is `TestNoToolMutatesDatabase`: it seeds rows, opens a
read-only session, calls a fixed list of tools, and asserts table row counts
are unchanged, on top of asserting a direct write against the same
connection fails. The tools this surface introduced (`get_task_context`,
`find_experts`) are in that explicit call list; the two other tools it shipped,
`list_situations` and `get_situation`, were removed on 2026-09-14 with the
situations pipeline and left the call list with them. `list_transcripts` — a
pre-existing tool this branch extended with
an optional `query` argument (`db.SearchTranscripts`) — is exercised with
both its bare and `query` forms.

The chat-mode server (`watchtower mcp --chat`, launched only by the Desktop's
`ai query --tools chat`) is a separate entry point governed by AGENT-01/02
(`agent-actions.md`); it mounts write tools that record proposals and is never
registered for external clients.

**Known gap (pre-existing, not introduced or closed by this branch):** the
explicit call list in `TestNoToolMutatesDatabase` still omits four tools
added in earlier features — `list_messages`, `get_transcript`, `list_ideas`,
`get_idea` — which are registered and read-only in practice but not
exercised by this test, so a regression in any of them would not be caught
by this guard. (The `memory_map`/`memory_open`/`memory_recall` tools are a
separate case: they have a documented deliberate-write exception and their
own dedicated tests in `internal/mcp/memory_test.go`, so their absence from
this list is by design, not drift.) This branch did not introduce the gap
and does not close it — flagging it here so the next person doesn't assume
every tool is covered.

**Why locked:** This surface exists specifically so a customer's coding
agent can be pointed at Watchtower's data with no write risk. A write path
here — even an accidental one — would turn a knowledge-base integration into
a way for an external agent session to mutate the product's data.

**Test guards:**
- `internal/db/db_test.go::TestSetReadOnlyBlocksWrites`
- `internal/mcp/server_test.go::TestAllToolsAreReadOnly` (naming lint only)
- `internal/mcp/server_test.go::TestNoToolMutatesDatabase` (the real guard)
- `cmd/mcp_test.go::TestDev06_PlainMCPStaysReadOnly` (the `cmd` wiring: no `--chat`/`--workbench` → `query_only` on, no write/workbench tool, no `get_action`)

**Locked since:** 2026-08-09

## DEV-02 — no AI in the data layer

**Status:** Enforced

**Observable:** `get_task_context` (`internal/tools/taskcontext.go`) and
`find_experts` (`internal/tools/experts.go`) are mechanical SQL plus plain
Go arithmetic (`find_experts`'s recency-decayed scoring). None calls a
`digest.Generator`, loads a prompt, or shells out to `claude`/`codex`.
Interpretation happens in the consumer's own coding agent, on the consumer's
own tokens — which is also what keeps this surface free at Watchtower's
expense-side. (These read tools moved from `internal/mcp` into the registry in
the 2026-09-06 read-tool migration; `internal/tools` still imports no AI/prompt
package.)

**Why locked:** A tool on this surface that needed a model call would be the
wrong tool for this layer — it would tie a "give me the facts" call to an AI
provider, a cost, and a latency budget the dev-facing use case (fast lookups
inside an agent session) cannot afford.

**Test guards:** no dedicated guard test; enforced by code review — neither
`taskcontext.go` nor `experts.go` imports an AI/prompt package, checkable with
`grep -l "internal/ai\|internal/prompts" internal/tools/{taskcontext,experts}.go`
(expected: no match).

**Locked since:** 2026-08-09

## DEV-03 — evidence, not verdicts

**Status:** Enforced

**Observable:** `find_experts` never asserts that someone is an expert.
Every candidate carries an `Evidence []expertEvidence` list where each entry
has a `kind`, a `count`, and a resolvable `ref` (a Slack `channel|ts` pair, a
Jira key, or an email) — never a bare score with no way to check it. The
response ships `expertWeights` (`internal/tools/experts.go`'s package-level
map: `messages: 1.0`, `thread: 1.5`, `jira: 2.0`, `code: 2.5`) so the caller
can see exactly what produced the ranking, not just trust it. An unmatched
git author passed via the `emails` argument is returned in
`UnmatchedEmails`, never silently dropped from the response.

**Test guards:**
- `internal/tools/experts_test.go::TestFindExperts_RanksByEvidenceAndCitesIt`
- `internal/tools/experts_test.go::TestFindExperts_ReportsUnmatchedEmails`

**Locked since:** 2026-08-09

## DEV-04 — the installer never clobbers

**Status:** Enforced

**Observable:** `devpack.Install` (`internal/devpack/install.go`) writes a
skill file only when `planFor` decides the target is absent
(`StateInstalled`), byte-identical to what we ship (`StateUnchanged`, no
write needed), or still matches the digest recorded the last time we wrote
it (`StateUpdated` — a legitimate pack upgrade). That digest is a sidecar,
`.watchtower-shipped`, written next to each skill's `SKILL.md`
(`writeShippedDigest`/`readShippedDigest`); comparing the file's *current*
hash against that sidecar, not against the newly-shipped content, is what
tells "we changed the pack" apart from "the user edited their copy". A file
that differs from both what we ship and what the sidecar recorded is
`StateDrifted` and left untouched. A file with no
`x-watchtower-pack` frontmatter marker at all (`devpack.HasMarker`,
`pack.go`) is `StateForeign` and never touched by `Install` or `Remove`.
`Remove` deletes only marker-carrying, non-drifted files — a drifted file is
reported and kept, since it is the user's now. The workbench skill
(`watchtower-workbench`, embedded separately from the pack by
`//go:embed workbenchskill/*/SKILL.md` in `internal/devpack/workbench.go`)
follows the same rules, and so does the removal of the pre-rename
`watchtower-project` skill when a workbench folder is resynced
(`removeSkill`: only a marked, un-edited copy is deleted).

Since 2026-10-15 (board #266) the workbench install ships two skills under these rules — the v10 core and the watchtower-flow preset; the upgrade fixtures cover v1..v9 → v10 core + preset (an edited pre-v10 copy is kept as a single file, with no preset).

**Test guards:**
- `internal/devpack/install_test.go::TestInstallWritesThePackAndIsIdempotent`
- `internal/devpack/install_test.go::TestInstallNeverClobbersAUserEditedSkill`
- `internal/devpack/install_test.go::TestRemoveDeletesOnlyMarkedFiles`
- `internal/devpack/install_test.go::TestStatusReportsMissingWithoutWriting`
- supporting (the workbench skill): `internal/devpack/workbench_test.go::TestWorkbenchSkill_UpgradesAnUneditedPreviousVersionAndKeepsAnEditedOne` — each shipped earlier text (`internal/devpack/testdata/watchtower-workbench-v1.md` … `-v5.md`; v4 and v5 added 2026-10-11 with pack v6) is replaced when un-edited and kept byte-identical when edited
- supporting (2026-10-15, v1..v9 → v10 core + preset): `internal/devpack/workbench_test.go::TestWorkbenchSkill_UpgradesAnUneditedPreviousVersionAndKeepsAnEditedOne`

**Why locked:** `watchtower integrate` writes into a directory
(`~/.claude/skills` by default) the user may also hand-edit or fill with
unrelated skills. Clobbering a hand-edited skill, or deleting a foreign file
during `remove`, would make the installer untrustworthy the first time
someone customizes what we shipped.

**Locked since:** 2026-08-09

## DEV-05 — pull only

**Status:** Enforced

**Observable:** Nothing on this surface initiates contact with the
developer. `watchtower integrate claude-code`/`status`/`remove`
(`cmd/integrate.go`) run only when the developer types the command; there is
no daemon phase for this feature (unlike every AI pipeline cataloged
elsewhere in this repo, which run on `internal/daemon`'s phase loop), no
hook, and no notification. The three skills
(`internal/devpack/skills/watchtower-{task-context,who-to-ask,
why-decision}/SKILL.md`) are all invoked *by* the developer's
agent recognizing a trigger in the conversation — the agent asks, the MCP
tools answer; Watchtower never pushes.

**Why locked:** The whole design premise (`docs/superpowers/specs/
2026-08-09-dev-knowledge-base-design.md` §2/§3) is "pull, not push" — a push
mechanic (a hook firing mid-session, an unsolicited context injection) would
interrupt the exact flow this feature exists to protect. Adding one requires
an explicit, CLI-controlled opt-in and an owner decision, not an
implementation detail slipped into a handler.

**Amended 2026-09-29 (spec `docs/superpowers/specs/2026-09-29-project-board-poc-design.md` D5/D6; names updated 2026-10-02):**
the hooks on this surface are the `SessionStart` hook
`watchtower integrate claude-code --workbench N` installs into that workbench
folder's `.claude/settings.local.json`, running
`watchtower workbench brief --workbench N`, and its `Stop` hook
(`workbench check --workbench N --stop-hook`, PROJ-07). They are the
explicit, CLI-controlled opt-in this contract requires: only that command
installs them (typed by the owner, or run by the Desktop's Open Folder /
Re-run Setup flows the owner starts; a folder set up before the rename keeps
its `project brief --project N` entry, which serves no brief since
2026-10-15: since 2026-10-16 (ask #312) it reaches the CLI's hidden `project`
tombstone, which reads no config or database, exits 0 and prints only one
line asking the agent to have the owner run Repair install, until such a
resync — the Desktop's Repair — replaces it in place); `integrate remove --workbench N` and
`watchtower workbench delete N` remove them, our pre-rename entries included;
plain `integrate claude-code` never installs
one; and they run only when the owner's own Claude Code session starts or
stops in that folder. There is still no
daemon phase for this surface, and the brief only reads the board. (2026-10-01,
board #160: inside a session the Desktop's embedded terminal launched —
`WATCHTOWER_TERMINAL_SESSION_ID` set — it also stores the conversation's
session id on that terminal row after `/clear`, `/compact`, a resume or a fork;
that is bookkeeping for the Desktop's relaunch, never contact with the developer.)
(2026-10-12, board #399: a Codex session in a workbench terminal gets the
same hooks, `workbench <verb> --agent codex`, as launch flags the Desktop
passes when the owner starts or resumes that session; nothing is persisted in
the folder. `watchtower integrate codex --workbench N`, run only by the owner
or the Setup / Repair / Set up Codex flows the owner starts, trusts exactly
those hook strings in `~/.codex/config.toml`. They run only inside that
owner-started session, so this contract holds unchanged.)

**Test guards:** no dedicated guard test (the absence of a push mechanism is
not independently unit-testable); enforced by the lack of any
`internal/daemon` phase registration for this feature — checkable with
`grep -n "devpack\|integrate" internal/daemon/daemon.go` (expected: no
match) — and by code review against this contract.

**Locked since:** 2026-08-09

## DEV-06 — the workbench-bound mode writes only its own workbench

**Status:** Enforced

**Observable:** `watchtower mcp --workbench N` (`cmd/mcp.go`'s
`mcpWorkbenchOptions`; registered in the workbench folder as the local
`watchtower-workbench` server by `watchtower integrate claude-code --workbench N`)
is the one writable mode of this surface. It refuses to start when workbench N
does not exist or together with `--chat`, keeps the connection writable, and
mounts the registry (`buildToolRegistry`) on the `project` surface (the
stored surface value keeps its pre-rename spelling) with
`tools.Binding{Surface: "project", WorkbenchID: N, DirectApply: true}`: the
sixteen workbench tools (`internal/tools/workbenches.go`, `workbench_targets.go`,
`workbench_docs.go`, since 2026-10-03 the owner-ask tools `ask_owner`,
`get_ask`, `list_asks` and `withdraw_ask` in `workbench_asks.go`, `finish_session` in `workbench_finish.go`, and since 2026-10-16 `get_review` in
`workbench_review.go`) plus every
surface-less read tool and `get_action`; no other write tool is visible
there. The mode is served only under the Workbench names (since
2026-10-15): no `--project N` flag serves anything and no pre-rename tool name is on
the surface — a call to `project_info`, `project_board`, `update_project`,
`add_project_source` or `remove_project_source` is an unknown tool. The one
remnant is read-only: `tools.CanonicalToolName` maps those five old names to
the current ones, so an `agent_actions` row recorded under an old name before
the rename still resolves through `Registry.Get`, applies on a retry and
reads under the current name in `get_action`. A folder registered as
`watchtower-project` and never resynced has no server that starts until a
resync (the Desktop's Repair) migrates it: its `mcp --project N` reaches a
hidden `--project` flag whose only effect is that `mcp` fails with the
"run Repair install" line (since 2026-10-16, ask #312) — it binds and serves
nothing. Three rules keep it narrow:

1. **Only workbench N's rows.** Every workbench write resolves what it touches —
   target, parent, source, comment, ask (its target, its `previous_ask_id`) —
   and its `Tool.Scope` refuses
   anything outside `Binding.WorkbenchID` ("… is not in this workbench") before
   any row, data or audit, is written; new rows take `project_id` from the
   binding only (a `project_id` argument is an unknown field and refused).
   Target images (`create_targets`'
   `images`, `update_target`'s `add_images`) attach only to workbench N's
   targets and `remove_image_ids` detaches only the target's own images
   (`scopeImageIDs`); the source file is read, never modified, and its copy
   lands only in workbench N's own `<workspace>/project_files/N/`.
   A review ask's `doc_path` resolves only to a regular `.md`/`.markdown`/`.txt`
   file inside workbench N's folder (`tools.ResolveWorkbenchDocumentPath`:
   relative, no `..` out of the folder, symlinks only inside it, then read
   through `os.OpenRoot` on the folder; ≤ 2 MiB, valid UTF-8) and is only
   read, never written (PROJ-03). An ask's session is bound only when
   `WATCHTOWER_TERMINAL_SESSION_ID` names a `terminal_sessions` row of
   workbench N, else it is filed session-less; the same resolution picks the
   session `finish_session` marks (none resolves → refused, nothing written)
   and the session a write tool links its targets to (PROJ-14).
   `get_ask`/`list_asks`/
   `withdraw_ask` see only workbench N's asks (another workbench's reads
   `no ask with id N`).
   `list_targets`/`get_target` see only
   workbench N's targets; `get_action` shows only workbench N's rows
   (`actionVisible`).
2. **Applied directly, audited.** Under `DirectApply`, `Registry.Propose`
   inserts the call's `agent_actions` row `approved` with
   `trust_at_create='execute'` and `context_type='project'`/`context_id=N`,
   then applies it inline through the ordinary `Apply` claim (AGENT-05) — for
   that call only: `tool_trust` is neither read nor written. `Apply` rebuilds
   the binding from the row (`bindingOf`) and re-runs `Scope`, so a retried
   row (`watchtower actions apply`) is re-scoped too. One deliberate
   exception (2026-10-03): `get_ask`, a read tool, moves an `answered` ask to
   `delivered` (`delivered_at`, guarded `WHERE status='answered'`) without an
   audit row — the read is the delivery receipt; it is workbench-surface
   only, so it is outside `readOnlyGuardCalls` (DEV-01, AGENT-06).
3. **Never External inline.** `DirectApply` refuses an `External` tool
   outright (a ValidationError, no row) and any tool whose `Surfaces` does not
   name `project` explicitly — a surface-less tool cannot inherit direct apply
   (`directApplyGate`). The one exception (owner decision 2026-10-02, board
   #166): an External tool that opts in with `Tool.ProposeUnderDirectApply`
   and names `project` — today only `send_slack_message` — is recorded as a
   **pending** proposal bound to workbench N (`trust_at_create='ask'`, never
   applied inline, a stale `execute` trust row ignored) and runs only after the
   owner's Approve in the Desktop's Inbox → Actions strip, through the ordinary
   `Apply` claim (AGENT-05).

Once workbench N is deleted, every tool on a still-connected session — workbench
tool or not, read or write, `get_action` included — answers `workbench N no
longer exists` and writes nothing (`Registry.WorkbenchAlive`, the first check of
every call).

DEV-06's scoping is a guardrail on Watchtower's own tools only: the agent runs
as the owner with a shell, so Claude Code's own permission prompt is the real
boundary. A workbench session also mounts the full read tool set plain
`watchtower mcp` does (`workbench.md`, "v1 limits and notes").
That read set includes the owner's DMs, transcripts, memory and writing
style, and the session's agent also holds Bash and WebFetch, so a prompt
injection in the folder could read them and send them off the machine. This
is an accepted risk (security review board #152, owner decision 2026-10-14,
ask #106 «Оставить как есть»): the reads are not narrowed for the workbench
surface, and the agent's own permission prompts remain the boundary.

Since 2026-10-12 (board #399) the mode also takes `--agent claude|codex`
(only with `--workbench`; any other value is refused). It changes no tool,
scope or apply rule: it only labels the agent's comments (`agent_label`) when
no Desktop terminal row resolves, the row's kind winning when one does. A
Codex session receives the server as launch flags
(`mcp_servers.watchtower-workbench`, `default_tools_approval_mode="approve"`,
owner decision D3, so codex does not ask per call), never through a persisted
registration. Codex's own approval prompt is then not a boundary for
Watchtower's tools; the three rules above are.

**Why locked:** This is the only place an external coding agent writes into
Watchtower without a per-call owner click. It is acceptable because the blast
radius is one workbench the owner created and bound to the very folder the agent
works in. A tool that wrote outside it, a non-workbench write tool visible on
this surface, or an External call would turn a folder-scoped board into an
unreviewed write path into the owner's whole app — or off the machine.

**Test guards:**
- `internal/tools/workbenches_test.go::TestDev06_WriteOutsideTheBoundProjectIsRefused` (every write aimed at another workbench's target/source/comment, a non-workbench target, or smuggling a `project_id` is refused; the other workbench's rows are byte-identical; no audit row)
- `internal/tools/registry_workbench_test.go::TestDev06_ExternalToolRefusedUnderDirectApply`
- `internal/tools/registry_approve_test.go::TestDev06_ProposeOnlyExternalToolLandsPendingUnderDirectApply` (one pending row bound to the workbench, never executed on propose even with a stale execute trust row; runs once after Approve), `TestDirectApply_ProposeOnlyToolStillNeedsTheSurface`; `internal/tools/slack_send_test.go::TestSendSlackMessage_ProjectSessionOnlyProposes`
- `internal/tools/workbench_docs_test.go::TestDev06_DocumentPathStaysInsideTheFolder` (`../`, nested `../`, absolute path, symlinked file, symlinked directory, missing file, wrong extension, directory, the folder itself — the check `ask_owner`'s `doc_path` goes through); supporting: `TestAskOwner_ReviewRefusesAnyFileItMustNotRead`, `TestReadInsideFolder_RefusesASymlinkOutOfTheFolder`, `TestAskOwner_SessionBinding` (`internal/tools`)
- `cmd/mcp_test.go::TestDev06_PlainMCPStaysReadOnly` (the boundary with DEV-01)
- supporting: `TestDirectApply_AppliesInlineWithAuditRow`, `TestDirectApply_RefusesToolNotOnTheSurface`, `TestScope_RunsInProposeAndAgainInApply`, `TestProjectBinding_DeletedProjectAnswersNoLongerExists` (`internal/tools`); `TestProjectMode_DeletedProjectEveryToolAnswersNoLongerExists`, `TestGetAction_ProjectSessionSeesOnlyItsRows` (`internal/mcp`); `TestMCPProjectMode_BindsTheProjectAndAppliesDirectly`, `TestMCPProjectMode_RefusesMissingProjectAndChat`, and the workbench-surface block of `TestBuildToolRegistry_PinsWriteToolsReadToolsAndSurfaces` (exact tool set; none External except `send_slack_message`, which must be propose-only) (`cmd`); the served names and the pre-rename rows: `TestWorkbenchMode_ListsSixteenToolsUnderTheCurrentNames`, `TestWorkbenchMode_ServesTheAskTools`, `TestWorkbenchMode_OldNamesAreUnknownAndOldRowsResolve` (`internal/mcp`), `TestCanonicalToolName_MapsTheRenamedWorkbenchTools`, `TestRegistryGet_ResolvesBothSpellings`, `TestLegacyName_RowStoredUnderAnOldNameStillApplies` (`internal/tools`); the pre-rename `mcp --project N` tombstone: `TestWorkbench_NoPreRenameCommandOrFlag` (`cmd`); the `--agent` flag (2026-10-12): `TestMCPWorkbenchMode_AgentFlagLabelsComments` (`cmd`), `TestAgentLabel_StoredRowApplyFallsBackToClaude` (`internal/tools`).

**Locked since:** 2026-09-29

## Changelog

- 2026-10-16 (board #376, owner decision in ask #312): note only, no contract semantics changed and no guard relaxed. The pre-rename spellings answer through a tombstone: DEV-05's never-resynced `project brief --project N` entry reaches the hidden `project` command, which reads nothing, exits 0 and prints one line asking for Repair install (stderr only for any other `project …`, such as the old Stop hook); DEV-06's `mcp --project N` reaches a hidden `--project` flag that makes `mcp` fail with that line, binding and serving nothing. The aliases stay removed. Guard `cmd/workbench_test.go::TestWorkbench_NoPreRenameCommandOrFlag` is listed under DEV-06; the rebase onto main's sixteenth tool renamed `TestWorkbenchMode_ListsFifteenToolsUnderTheCurrentNames` in place to `…ListsSixteenTools…` (count only, as the earlier Fourteen → Fifteen rename did).
- 2026-10-15 (board #376, spec `docs/superpowers/specs/2026-10-02-workbench-rename-design.md` §10, owner approved in ask #209): the pre-rename aliases are removed. DEV-06 no longer has a legacy vocabulary — no `--project N` flag, no `Binding.LegacyNames`/`Spell`, no old tool names served; only the read-only `tools.CanonicalToolName` map stays, so an `agent_actions` row stored under an old name still resolves, applies and reads under the current name. DEV-01's scope sentence and its guard note drop `--project`; DEV-05's hook amendment says a never-resynced folder's `project brief --project N` entry no longer runs until a resync (the Desktop's Repair) replaces it, and the removal still takes our pre-rename entries. Guards: `TestMCPProjectMode_LegacyFlagServesTheOldToolNames` is removed with the flag it pinned; `TestWorkbenchMode_EachVocabularyListsFifteenToolsUnderItsOwnNames` → `TestWorkbenchMode_ListsFifteenToolsUnderTheCurrentNames`, `TestWorkbenchMode_AskToolsServedUnderTheSameNamesInBothVocabularies` → `TestWorkbenchMode_ServesTheAskTools`, `TestLegacyMode_WritesRecordTheCanonicalNameAndOldRowsResolve` → `TestWorkbenchMode_OldNamesAreUnknownAndOldRowsResolve` (an old name is now an unknown tool; the old-row half is kept), `TestLegacyName_WriteRecordsTheCanonicalName` is removed (no session writes under an old name any more; the existing `TestLegacyName_RowStoredUnderAnOldNameStillApplies` now pins the old-row path), and `TestLegacyWorkbenchToolNames_CoverTheRenamedWorkbenchTools` → `TestCanonicalToolName_MapsTheRenamedWorkbenchTools`, both now listed. The fifteen-tool set, the scoping rules and the other guards are unchanged.
- 2026-10-15 (board #778, owner decision in ask #281): wording only, no contract semantics changed. DEV-05's list of Desktop flows that run `integrate claude-code --workbench N` names **Open Folder** instead of New Workbench — the Desktop's one entry point to a workbench now; the install it runs is the same.
- 2026-10-14 (Automations P1 Task 5b, ask #277): note only — the DEV-01 telemetry-write exception narrows. `memory_open` writes no `memory_node_stats` bump on the `automation` surface, and `buildAutomationRegistry` mounts `memory_map`/`memory_open`/`memory_recall` for automations without the recall-compare shadow handle (no shadow row). The D23 automation reads (`list_inbox`, `list_calendar_events`, …) and `get_writing_style` stay out of `tools.ReadTools()`, so the dev surface is unchanged. No guard changed.
- 2026-10-14 (session cleanup, board #535, spec `docs/superpowers/specs/2026-10-12-session-cleanup-design.md` §11, owner approved 2026-10-12, ask #193): the workbench skill is pack **v8** (`x-watchtower-pack: v8`; `origin/main` already shipped v7 with board #399, so the spec's "v7" became the next free version) — "Finishing a session" gains a cleanup step before `finish_session`: leave any worktree, `git fetch`, run the brief's `Cleanup:` command, then the same command with `--apply` when it lists anything to remove (`--worktree`/`--branch` for what the list misses), never remove a worktree or branch by hand, and carry the command's `summary` line into the finish summary, which keeps the `finish_session` schema's limit (2–3 lines, at most 4) with the cleanup line counted within it; a refused (exit 2) or failed (exit 1) plan is reported, not retried with other flags, and with no `Cleanup:` line in the brief the step is skipped and the summary says cleanup was not available. One text serves both agents, so the Codex copy in `.agents/skills` follows. The shipped v7 text joins the DEV-04 re-install fixtures (`watchtower-workbench-v7.md`), so an un-edited v1–v7 copy is updated by resync/Repair and an edited one is kept. The same install (board #535, PR #251) adds one `permissions.allow` rule to the folder's `.claude/settings.local.json`, `Bash(<bin> workbench cleanup:*)`, so the step runs in auto mode: `<bin>` is the hooks' absolute binary, quoted only when it holds an unsafe character (the same text as the brief's `Cleanup:` command); install, removal and status take no workbench id for it; only a rule whose bin is an absolute path with the basename `watchtower` is ours — a bare or relative form is the owner's and is never rewritten or removed. That rule is a settings entry, not a DEV-04 artifact: its contract is PROJ-04/PROJ-02 in `workbench.md`. No DEV-04 wording change; no guard relaxed.
- 2026-10-14 (security review board #146/#152, owner decision in ask #106): note only, no contract semantics changed. DEV-06 now names the full read set on the workbench surface (DMs, transcripts, memory, writing style next to an agent with Bash/WebFetch) as an accepted risk rather than leaving it implicit.
- 2026-10-12 (board #399, Codex as a Workbench agent, spec `docs/superpowers/specs/2026-10-12-codex-workbench-agent-design.md`, owner approved in ask #189): note only, no contract semantics changed. DEV-05's hook amendment covers a Codex session's hooks, which arrive as launch flags of the owner-started session and are trusted by `integrate codex`. DEV-06 gains the `--agent claude|codex` flag (comment labels only; tools, scope and apply unchanged) and notes that a Codex session approves Watchtower's tools without a per-call prompt (D3). The workbench skill is pack **v7** (names both tool spellings and Codex's `request_user_input`).
- 2026-10-11 (owner asks v2, board #395, spec `docs/superpowers/specs/2026-10-10-owner-asks-v2-design.md` Part 7): the workbench skill is pack **v6** (`x-watchtower-pack: v6`; `origin/main` already shipped v5 with board #499, so the spec's "v5" became the next free version) — "Asking the owner" teaches the Chat / Quick / Full levels, a do-not-ask list, one ask with up to 4 questions, re-filing a withdrawn ask only as a revision with `changes`, and asks raised from chat (`origin: chat`); the `ask_owner` line names `level`. The shipped v4 and v5 texts join the DEV-04 re-install fixtures (`watchtower-workbench-v4.md`, `-v5.md`), so an un-edited v1–v5 copy is updated by resync/Repair and an edited one is kept. No DEV-04 wording change; no guard relaxed. DEV-06's `ask_owner` gains the optional `level` argument and the `level`/`level_note`/`hint` result keys, `get_ask`/`list_asks` add `level`, `origin` and `chat_asked_at`; the tool set is unchanged.
- 2026-10-16 (diff reviewer, board #328, spec review ask #179): DEV-06's workbench tool set grows from fifteen to **sixteen** — `get_review` (`internal/tools/workbench_review.go`, a read of the session workbench's sent rounds whose only write is the unaudited `sent → delivered` mark, like `get_ask`: an AGENT-06 scope exception). The cited guard `TestWorkbenchMode_EachVocabularyListsFifteenToolsUnderItsOwnNames` keeps its historical name; it now asserts sixteen.
- 2026-10-03 (workbench session report, spec `docs/superpowers/specs/2026-10-03-workbench-session-report-design.md`; owner-approved via asks #2 and #4): DEV-06's workbench tool set grows from fourteen to **fifteen** — `finish_session` (a workbench write, applied directly and audited like the others; `summary` 1–600 runes in at most 4 lines, optional `target_id` of workbench N) marks the calling terminal session finished. Rule 1 names its session resolution: only a `terminal_sessions` row of workbench N named by `WATCHTOWER_TERMINAL_SESSION_ID`, else it is refused with `finish_session needs a Watchtower terminal session` before any row or audit row (PROJ-14 in `workbench.md`). `update_target`, `create_targets`, `add_comment` and `ask_owner` now also link their targets to that session, best-effort after their own write (PROJ-14). `TestWorkbenchMode_EachVocabularyListsFourteenToolsUnderItsOwnNames` was renamed in place to `…FifteenTools…` (count only); no guard relaxed.
- 2026-10-03 (workbench owner asks, spec `docs/superpowers/specs/2026-10-03-workbench-owner-asks-design.md`). **Approved by the owner (spec Parts 4 and 9):** DEV-06's workbench tool set changes from eleven to **fourteen** — `attach_document` is removed (documents were replaced by asks; `list_comments`' `document_id` is refused with "documents were replaced by asks — use ask_owner (kind review)") and `ask_owner`, `get_ask`, `list_asks`, `withdraw_ask` are added under the same names in both vocabularies (no legacy spelling). Rule 1 now names asks instead of documents and restates the document-path rule for `ask_owner`'s `doc_path` (the check `TestDev06_AttachDocumentStaysInsideTheFolder` pinned for `attach_document`, now pinned on `ResolveWorkbenchDocumentPath` itself as `TestDev06_DocumentPathStaysInsideTheFolder`, which also accepts `.markdown`; the old guard's "a refused attach writes no audit row" assertion went with the tool, and `TestAskOwner_RefusesBadInputWithoutWriting` pins the same for asks). `TestWorkbenchMode_EachVocabularyListsElevenToolsUnderItsOwnNames` was renamed in place to `…FourteenTools…` (count only). No guard relaxed beyond the removed tool. **Implementation rulings, pending owner confirmation:** rule 2's exception for `get_ask`'s unaudited `delivered` write (with the matching AGENT-06 scope note in `agent-actions.md`), and rule 1's ask session binding (bound only when `WATCHTOWER_TERMINAL_SESSION_ID` names a row of workbench N, else session-less).

- 2026-10-02 (Workbench rename, spec `docs/superpowers/specs/2026-10-02-workbench-rename-design.md`): Projects is renamed **Workbench**. DEV-06 is reworded with the same meaning — `watchtower mcp --workbench N`, registered as `watchtower-workbench`, still exactly eleven tools on the `project` surface under `DirectApply`, scoped to one workbench; the hidden legacy `--project N` serves the same tools with the five renamed ones under their old names and records the canonical name in the audit row (new tests `TestWorkbenchMode_EachVocabularyListsElevenToolsUnderItsOwnNames`, `TestLegacyMode_WritesRecordTheCanonicalNameAndOldRowsResolve`, `TestMCPProjectMode_LegacyFlagServesTheOldToolNames`). DEV-01's scope sentence names `--workbench` and `--project`. DEV-04 now names the workbench skill's embed (`workbenchskill/*/SKILL.md`) and the resync's removal of the legacy skill through the same marker/digest rule. DEV-05's amendment names the renamed hook commands and also lists the `Stop` hook installed since PROJ-07 (2026-10-01), which it had not named; a resync replacing our own legacy hook entry is still the explicit CLI/Desktop opt-in. Guard file paths updated; no guard test renamed or relaxed.
- 2026-10-02 (board #166, Slack send): DEV-06 rule 3 amended by owner decision — an External tool that opts into `ProposeUnderDirectApply` (only `send_slack_message`) is recorded pending in a workbench session and sent after the owner's Approve in the Desktop; it is still never applied inline. `TestDev06_ExternalToolRefusedUnderDirectApply` is unchanged and green; the registry pin's "nothing External on the project surface" assertion now names the one propose-only exception and requires the flag on it. New guards listed above. The project surface also gains the read tool `get_writing_style` (not in `ReadTools()`, so plain `watchtower mcp` is unchanged, DEV-01).

- 2026-10-01 (board target #160): DEV-05's 2026-09-29 amendment no longer says the brief "only reads" without qualification — inside a session the Desktop's embedded terminal launched, the `SessionStart` hook also stores the conversation's session id on that `terminal_sessions` row after `/clear`, `/compact`, a resume or a fork (see `projects.md` changelog); approved by the owner 2026-10-01. Still pull-only: no new hook, no daemon phase, no output change. No guard tests changed.
- 2026-09-30 (fix wave 2 of PR #30): DEV-06's Observable now says `get_action` answers `project N no longer exists` after a delete too (it skipped the liveness check before; `Registry.ProjectAlive` is exported for it), and states that DEV-06 is a guardrail on Watchtower's tools only — Claude Code's permission prompt is the real boundary. `TestGetAction_ProjectSessionSeesOnlyItsRows` now also pins the `context_id` clause with a second project's row. No guard relaxed.
- 2026-09-29: the Projects POC's install lands on the DEV-04 installer rules unchanged — the `watchtower-project` skill carries the `x-watchtower-pack` marker and `.watchtower-shipped` digest and is embedded separately (`//go:embed projectskill/*/SKILL.md`; `workbenchskill/*/SKILL.md` since the 2026-10-02 rename), so plain `integrate claude-code` never installs it; `integrate remove --project N` deletes only marker-carrying files, our own `SessionStart` entry and the exclude lines it added. No DEV-01..05 semantics beyond Task 9's DEV-01/DEV-05 amendments and the new DEV-06 changed.
- 2026-09-29 (Projects POC, spec `docs/superpowers/specs/2026-09-29-project-board-poc-design.md` §4.2/§4.3/§7, owner decision D5): **DEV-06 added** (Enforced) — `watchtower mcp --project N`, this surface's one writable mode: eleven project tools on the `project` registry surface, applied directly under `tools.Binding.DirectApply` with an `agent_actions` audit row, scoped to project N, never an `External` tool. **DEV-01 amended**: "read-only forever" is scoped to `watchtower mcp` without `--project`; no DEV-01 guard changed, and `TestDev06_PlainMCPStaysReadOnly` joins its guard list. **DEV-05 amended**: the `SessionStart` hook installed by `integrate claude-code --project N` is the explicit CLI opt-in the contract requires (the installer itself lands in Phase 3). `Registry.CallRead` now takes the caller's `Binding` (dev mode passes the zero value, so its reads are unchanged), and `get_target` answers "no target with id N" for a project target outside that project's session (PROJ-01, `projects.md`).
- 2026-09-14: **inbox demolition** (spec `docs/superpowers/specs/2026-09-14-inbox-demolition-design.md`) — the pack is now **three skills, not four**. `list_situations`/`get_situation` (`internal/tools/situations.go`) are deleted along with the situations pipeline, and the `watchtower-whats-changed` skill, which was built entirely on those two tools, is removed from `internal/devpack/skills/` rather than left pointing at a table frozen on 2026-09-06 (audit finding L4). DEV-01's `TestNoToolMutatesDatabase` call list and DEV-02's Observable/grep drop the two tools; DEV-05's skill list drops the skill. **No contract semantics changed and no guard relaxed** — the installer needs no special handling for a shipped file that leaves the pack (DEV-04: `integrate status` reports it, `integrate remove` deletes only marker-carrying files), and the pack-install guards in `internal/devpack/install_test.go` are untouched. A "what changed" skill over Catch-Up would need Catch-Up exposed as a read tool first — a follow-up, not this spec.
- 2026-09-07: read-tool migration slice 2b — the dependency-carrying read tools
  (`memory_map`/`memory_open`/`memory_recall`, `load_skill`) moved from the last
  per-domain `internal/mcp` handlers (`memory.go`, `skills.go`, both deleted)
  into `internal/tools` (`memory.go`, `skills.go`), registered via
  `tools.DependentReadTools` in `NewServer` because they carry vault/skills/shadow
  dependencies that keep them out of the zero-arg `tools.ReadTools()` list.
  `internal/mcp` is now a thin lister with no domain handlers. No contract
  semantics, guard tests, or gates changed: `query_only=ON`,
  `TestNoToolMutatesDatabase` (memory/skills deliberately still outside its call
  list), and the memory telemetry-write exception behave exactly as before —
  proven by the unchanged `internal/mcp/{memory,skills,server}_test.go` passing
  through the registry adapter, plus new direct-`CallRead` unit tests in
  `internal/tools/{memory,skills}_test.go` (including the read-only-connection
  graceful-bump path the integration tests never exercised).
- 2026-09-06: read-tool migration — every pure-`db` read tool moved from
  per-domain `internal/mcp` handlers into the `internal/tools` registry
  (`tools.ReadTools()`), dispatched through `Registry.CallRead`; `internal/mcp`
  became a thin lister over it. DEV-01's and DEV-02's Observables were updated to
  point at `internal/tools` and to note that dev-mode reads are now
  registry-sourced. No contract semantics, guard tests, or gates changed — the
  `query_only=ON` fence and `TestNoToolMutatesDatabase` are the same. `memory_*`
  and `load_skill` stay in `internal/mcp` pending a later slice.
- 2026-09-04: DEV-01's Observable gains a paragraph noting the chat-mode MCP
  server (`--chat`) as a separate entry point governed by AGENT-01/02
  (`docs/inventory/agent-actions.md`); no contract semantics, guard tests, or
  gates on this surface changed.
- 2026-08-09: file created with 5 contracts (DEV-01..05), all Enforced.
  Introduced by the Developer Surface feature (spec
  `docs/superpowers/specs/2026-08-09-dev-knowledge-base-design.md`), which
  exposes Watchtower's product data to a developer's coding agent via three
  new MCP tools, a four-skill pack embedded in the binary, and a
  `watchtower integrate` control-layer command.
