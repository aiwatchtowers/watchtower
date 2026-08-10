# Behavior Inventory — Developer Surface

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `internal/mcp/` (specifically
> `taskcontext.go`, `experts.go`, `situations.go`), `internal/devpack/`, or
> `cmd/integrate.go`, read this file first. Any proposed change that would
> break a guard test or remove a contract must be raised as a question
> before touching code.

The MCP tools, skill pack, and installer that make Watchtower addressable
from a developer's coding agent. Design:
`docs/superpowers/specs/2026-08-09-dev-knowledge-base-design.md`.

**Module:** `internal/mcp/` (`get_task_context`, `find_experts`,
`list_situations`/`get_situation`) + `internal/devpack/` + `cmd/integrate.go`
**Last full audit:** 2026-08-09

## DEV-01 — read-only forever

**Status:** Enforced

**Observable:** Every tool on this surface is a read. The real enforcement is
connection-level: `cmd/mcp.go` calls `database.SetReadOnly()` before serving,
which flips the connection to `PRAGMA query_only=ON` (`internal/db/db.go`'s
`SetReadOnly`) — any write a handler attempted would fail at the SQLite
level, not just by convention. The MCP test session helper
(`internal/mcp/server_test.go`'s `newTestSession`) mirrors this exactly,
calling `SetReadOnly()` on the same database before wiring the test server,
so a handler that tried to write fails in tests the same way it would in
production.

`TestAllToolsAreReadOnly` is a **naming-convention lint only** — it checks
that every registered tool name starts with `list_`/`get_` or appears in an
explicit `readVerbs` allow-list (`memory_map`, `memory_open`,
`memory_recall`, `find_experts`). It says nothing about what a handler
actually does to the database.

The behavioral guard is `TestNoToolMutatesDatabase`: it seeds rows, opens a
read-only session, calls a fixed list of tools, and asserts table row counts
are unchanged, on top of asserting a direct write against the same
connection fails. This branch's four new tools (`list_situations`,
`get_situation`, `get_task_context`, `find_experts`) are all in that explicit
call list. `list_transcripts` — a pre-existing tool this branch extended with
an optional `query` argument (`db.SearchTranscripts`) — is exercised with
both its bare and `query` forms.

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

**Locked since:** 2026-08-09

## DEV-02 — no AI in the data layer

**Status:** Enforced

**Observable:** `get_task_context` (`internal/mcp/taskcontext.go`),
`find_experts` (`internal/mcp/experts.go`), and `list_situations`/
`get_situation` (`internal/mcp/situations.go`) are mechanical SQL plus plain
Go arithmetic (`find_experts`'s recency-decayed scoring). None calls a
`digest.Generator`, loads a prompt, or shells out to `claude`/`codex`.
Interpretation happens in the consumer's own coding agent, on the consumer's
own tokens — which is also what keeps this surface free at Watchtower's
expense-side.

**Why locked:** A tool on this surface that needed a model call would be the
wrong tool for this layer — it would tie a "give me the facts" call to an AI
provider, a cost, and a latency budget the dev-facing use case (fast lookups
inside an agent session) cannot afford.

**Test guards:** no dedicated guard test; enforced by code review — none of
`taskcontext.go`, `experts.go`, or `situations.go` imports an AI/prompt
package, checkable with `grep -l "internal/ai\|internal/prompts"
internal/mcp/{taskcontext,experts,situations}.go` (expected: no match).

**Locked since:** 2026-08-09

## DEV-03 — evidence, not verdicts

**Status:** Enforced

**Observable:** `find_experts` never asserts that someone is an expert.
Every candidate carries an `Evidence []expertEvidence` list where each entry
has a `kind`, a `count`, and a resolvable `ref` (a Slack `channel|ts` pair, a
Jira key, or an email) — never a bare score with no way to check it. The
response ships `expertWeights` (`internal/mcp/experts.go`'s package-level
map: `messages: 1.0`, `thread: 1.5`, `jira: 2.0`, `code: 2.5`) so the caller
can see exactly what produced the ranking, not just trust it. An unmatched
git author passed via the `emails` argument is returned in
`UnmatchedEmails`, never silently dropped from the response.

**Test guards:**
- `internal/mcp/experts_test.go::TestFindExpertsRanksByEvidenceAndAlwaysCitesIt`
- `internal/mcp/experts_test.go::TestFindExpertsReportsUnmatchedEmails`

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
reported and kept, since it is the user's now.

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
hook, and no notification. The four skills
(`internal/devpack/skills/watchtower-{task-context,who-to-ask,
whats-changed,why-decision}/SKILL.md`) are all invoked *by* the developer's
agent recognizing a trigger in the conversation — the agent asks, the MCP
tools answer; Watchtower never pushes.

**Why locked:** The whole design premise (`docs/superpowers/specs/
2026-08-09-dev-knowledge-base-design.md` §2/§3) is "pull, not push" — a push
mechanic (a hook firing mid-session, an unsolicited context injection) would
interrupt the exact flow this feature exists to protect. Adding one requires
an explicit, CLI-controlled opt-in and an owner decision, not an
implementation detail slipped into a handler.

**Test guards:** no dedicated guard test (the absence of a push mechanism is
not independently unit-testable); enforced by the lack of any
`internal/daemon` phase registration for this feature — checkable with
`grep -n "devpack\|integrate" internal/daemon/daemon.go` (expected: no
match) — and by code review against this contract.

**Locked since:** 2026-08-09

## Changelog

- 2026-08-09: file created with 5 contracts (DEV-01..05), all Enforced.
  Introduced by the Developer Surface feature (spec
  `docs/superpowers/specs/2026-08-09-dev-knowledge-base-design.md`), which
  exposes Watchtower's product data to a developer's coding agent via three
  new MCP tools, a four-skill pack embedded in the binary, and a
  `watchtower integrate` control-layer command.
