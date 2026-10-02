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
`internal/devpack/` + `cmd/integrate.go` + `cmd/mcp.go` (`--workbench`, legacy `--project`, DEV-06) +
`internal/tools/{workbenches,workbench_targets,workbench_docs,workbench_images,workbench_scope,workbench_names}.go`
**Last full audit:** 2026-08-09

## DEV-01 — read-only forever

**Status:** Enforced

**Scope (amended 2026-09-29, spec `docs/superpowers/specs/2026-09-29-project-board-poc-design.md` D5; flag renamed 2026-10-02):**
"read-only forever" is a promise about `watchtower mcp` **without**
`--workbench` (or its legacy spelling `--project`) — the server plain
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
- `cmd/mcp_test.go::TestDev06_PlainMCPStaysReadOnly` (the `cmd` wiring: no `--chat`/`--workbench`/`--project` → `query_only` on, no write/workbench tool, no `get_action`)

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

**Test guards:**
- `internal/devpack/install_test.go::TestInstallWritesThePackAndIsIdempotent`
- `internal/devpack/install_test.go::TestInstallNeverClobbersAUserEditedSkill`
- `internal/devpack/install_test.go::TestRemoveDeletesOnlyMarkedFiles`
- `internal/devpack/install_test.go::TestStatusReportsMissingWithoutWriting`

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
installs them (typed by the owner, or run by the Desktop's New Workbench /
Re-run Setup flows the owner starts — a folder set up before the rename keeps
its `project brief --project N` entry until such a resync replaces it in
place); `integrate remove --workbench N` and `watchtower workbench delete N`
remove them, either spelling; plain `integrate claude-code` never installs
one; and they run only when the owner's own Claude Code session starts or
stops in that folder. There is still no
daemon phase for this surface, and the brief only reads the board. (2026-10-01,
board #160: inside a session the Desktop's embedded terminal launched —
`WATCHTOWER_TERMINAL_SESSION_ID` set — it also stores the conversation's
session id on that terminal row after `/clear`, `/compact`, a resume or a fork;
that is bookkeeping for the Desktop's relaunch, never contact with the developer.)

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
eleven workbench tools (`internal/tools/workbenches.go`, `workbench_targets.go`,
`workbench_docs.go`) plus every surface-less read tool and `get_action`; no
other write tool is visible there. The legacy spelling `--project N` (a
folder registered as `watchtower-project` before the 2026-10-02 rename and
not yet resynced) is the same mode with `Binding.LegacyNames` set: the same
eleven tools, the five renamed ones listed under their old names
(`project_info`, `project_board`, `update_project`, `add_project_source`,
`remove_project_source`; `tools.LegacyWorkbenchToolNames`), the audit row
recording the canonical new name, and `Registry.Get` resolving both
spellings. Three rules keep it narrow:

1. **Only workbench N's rows.** Every workbench write resolves what it touches —
   target, parent, source, document, comment — and its `Tool.Scope` refuses
   anything outside `Binding.WorkbenchID` ("… is not in this workbench") before
   any row, data or audit, is written; new rows take `project_id` from the
   binding only (a `project_id` argument is an unknown field and refused).
   `attach_document` accepts only an existing `.md`/`.txt` regular file that
   resolves, after symlinks, inside the workbench's `folder_path`
   (`resolveInsideFolder`: `../`, absolute paths, and symlinked files or
   directories pointing out are refused). Target images (`create_targets`'
   `images`, `update_target`'s `add_images`) attach only to workbench N's
   targets and `remove_image_ids` detaches only the target's own images
   (`scopeImageIDs`); the source file is read, never modified, and its copy
   lands only in workbench N's own `<workspace>/project_files/N/`.
   `list_targets`/`get_target` see only
   workbench N's targets; `get_action` shows only workbench N's rows
   (`actionVisible`).
2. **Applied directly, audited.** Under `DirectApply`, `Registry.Propose`
   inserts the call's `agent_actions` row `approved` with
   `trust_at_create='execute'` and `context_type='project'`/`context_id=N`,
   then applies it inline through the ordinary `Apply` claim (AGENT-05) — for
   that call only: `tool_trust` is neither read nor written. `Apply` rebuilds
   the binding from the row (`bindingOf`) and re-runs `Scope`, so a retried
   row (`watchtower actions apply`) is re-scoped too.
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
- `internal/tools/workbench_docs_test.go::TestDev06_AttachDocumentStaysInsideTheFolder` (`../`, nested `../`, absolute path, symlinked file, symlinked directory, missing file, wrong extension, directory, the folder itself)
- `cmd/mcp_test.go::TestDev06_PlainMCPStaysReadOnly` (the boundary with DEV-01)
- supporting: `TestDirectApply_AppliesInlineWithAuditRow`, `TestDirectApply_RefusesToolNotOnTheSurface`, `TestScope_RunsInProposeAndAgainInApply`, `TestProjectBinding_DeletedProjectAnswersNoLongerExists` (`internal/tools`); `TestProjectMode_DeletedProjectEveryToolAnswersNoLongerExists`, `TestGetAction_ProjectSessionSeesOnlyItsRows` (`internal/mcp`); `TestMCPProjectMode_BindsTheProjectAndAppliesDirectly`, `TestMCPProjectMode_RefusesMissingProjectAndChat`, `TestMCPProjectMode_LegacyFlagServesTheOldToolNames`, and the workbench-surface block of `TestBuildToolRegistry_PinsWriteToolsReadToolsAndSurfaces` (exact tool set; none External except `send_slack_message`, which must be propose-only) (`cmd`); the legacy vocabulary: `TestWorkbenchMode_EachVocabularyListsElevenToolsUnderItsOwnNames`, `TestLegacyMode_WritesRecordTheCanonicalNameAndOldRowsResolve` (`internal/mcp`), `TestLegacyName_WriteRecordsTheCanonicalName`, `TestRegistryGet_ResolvesBothSpellings` (`internal/tools`).

**Locked since:** 2026-09-29

## Changelog

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
