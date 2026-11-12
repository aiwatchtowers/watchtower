# Context actions — the Context block tells you what to cut and cuts it

Date: 2026-11-12. Status: design, waiting for the owner's approval.
Builds on: Agent analytics (`docs/features/agent-analytics.md`, the Context block, hint C1) and the agent coach (`docs/features/agent-coach.md`, proposals, Accept/Rollback, verdicts).

## For the owner (one page)

**Why.** Every Claude Code session and every subagent starts with the same load: CLAUDE.md, memory, tool schemas, the skill and agent lists, hooks. On 2026-11-12 we cut it by hand from 79.6k to 43.3k tokens (−46 %) in one session. The work was: read the Context block, break each bar into its sources, check each source against how often it was actually used, turn off what is unused, slim CLAUDE.md through a PR, measure before and after. The Context block already shows the bars; it should do the rest.

**What you see.** The Analytics → Context block gets a **Do these** list on top. Each row is one change: what it removes, how many tokens a session start saves, the evidence ("0 calls in Watchtower sessions in 30 days"), one button. Below, **What's in it** opens each bar into its sources: weight at start and how often it was used. You act from the top and dig in only when you want to.

**Two kinds of change.**
- *Your settings* — turn off a plugin, an MCP server, the claude.ai connectors in Claude Code, archive stale lines of the agent's memory index. The button applies it at once; **Undo** puts it back. These are global (every project on the Mac, as done by hand today); the card says where else the thing is turned on, and that Watchtower only sees calls in its own workbench sessions.
- *Repository files* — for example, move CLAUDE.md's feature summaries into `docs/features/`. **Accept** starts a workbench session with a ready brief. The agent works in its own worktree, reviews by the project's rules, commits and opens a PR, as we did today. The card follows it: *session working → PR #N ready → merged, measuring*. Watchtower itself still never writes to git.

**How it ends.** After a change applies (settings) or merges (repository), the next session starts are measured and the row says what it actually saved ("−30.2k measured on 12 starts"). Rows that saved nothing say so.

**Memory.** When the agent's memory index grows big, **Accept** starts a session. The agent picks the stale lines and shows you the diff, and changes the index only after you approve.

**Not in this version.** Codex sessions (their start is not measured today); changing what happens *during* a session (Bash output, re-reads — hints C2/C3 stay as they are); reading transcripts of projects that are not workbenches.

---

## Decisions (owner, this conversation)

- D1. Ready actions first; the per-source breakdown is a fold below them.
- D2. Everything is done from the statistics screen. A repository change is done by a workbench session that Accept starts; the session commits and opens a PR. Watchtower's own code keeps COACH-01 (no git writes).
- D3. Personal settings change globally (user scope), not per workbench. The card is honest about the evidence's reach.
- D4. Memory index cleanup is done by an agent session: it picks the stale lines, shows the owner the diff (an `ask_owner` review) and applies only after the owner approves. There is no PR, because the memory is not in a repository.

## Calls made by the author (check these)

- C1. Context actions are coach proposals with new destinations, not a second proposal system. They get Accept / Decline / Rollback, the open-proposal list, the accepted log and the verdict for free. They are made by a new **mechanical** proposer (no model call) from the Context facts, not by the weekly model pass, and do not count against the weekly pass's 3 open slots (like chat proposals).
- C2. Every `repo_*` Accept goes through a session, the existing "write the file, you commit" path included (one behaviour: you always end with a PR, never a dirty tree). This changes shipped behaviour of the coach and the tuning chat; their notes and guide pages are updated.
- C3. The new metric is `start_tokens`: the median main-lane baseline of the sessions after the change against the 14 days before it. Verdict as today (≥ 10 % lower = works; under 5 sessions = too little data). Repository changes measure from the merge, as `repo_*` already measures from the commit.
- C5. **Settings proposals are per key, not per file.** A settings destination's `before_text`/`after_text` hold the one key's value (`enabledPlugins["<plugin>"]`, `env.ENABLE_CLAUDEAI_MCP_SERVERS`, the server's entry), its text key (`keyOf`) includes the source, and Accept compares and sets that key only (re-read the file, check the key still holds `before`, write the whole file atomically with only that key changed). Several settings proposals can be open at once, and Claude Code rewriting other keys of the file does not make them stale.
- C6. **The Desktop starts the session.** A `repo_*` Accept is pressed in the Desktop (Analytics card, Home row or tuning panel). Swift starts the session the way the drift Fix does, then calls `coach accept --session <id>`, which records `accepted` and the session id in one compare-and-set. A failed start leaves the proposal open, with the error on the card. `coach accept` of a `repo_*` proposal without `--session` is refused ("Accept it in Watchtower — it starts a session").
- C7. **The connectors rule:** one proposal when every `claude_ai_*` server had 0 calls in Watchtower sessions in the window. If one connector is used, there is no proposal (the switch is all-or-nothing).
- C8. **Repository measurement starts at the merge.** The session report already caches the session's PR. `measure_from` is set when that PR is seen merged. If the PR is closed unmerged, or nothing merges within 30 days, the verdict is `too_little_data` and the card says "not merged". This replaces the "file at the folder's HEAD" rule for every `repo_*` proposal accepted from now on, because all of them end in a PR. Rows accepted before this change have no session and no PR, so they keep the HEAD rule until they get a verdict.
- C9. **Global changes are decided on global evidence (follows D3).** Plugin, server and connector proposals count calls across every workbench with agent analytics on, are stored without a workbench, exist once per source in the install and show in every workbench's Context block. CLAUDE.md and memory proposals stay per workbench.
- C10. **Memory Rollback needs no backup file.** Accept stores the index as read at Accept; the daemon records the index the session wrote; Rollback writes the stored copy back only if the index still equals what the session wrote. No backup files are written into the memory folder. The session's write is taken when the linked session ends (auto-memory from other sessions also writes MEMORY.md, so a change alone proves nothing); lines other sessions add while the cleanup runs are dropped by a Rollback, and its confirmation says so.
- C11. **The repo diff is shown on the PR, not drawn in the app.** The mockup's in-row diff panel becomes **Show Diff**, which opens the PR's files page; the diff of a session's branch already has a home in the workbench (diff reviewer) and on GitHub, and a third renderer in Analytics would duplicate them. The row keeps the mockup's "before → after" numbers.
- C4. Thresholds for a proposal: a source with 0 calls in the 30-day window and ≥ 500 tokens at start; CLAUDE.md over 20 KB with a section over 8 KB; the memory index over 8 KB (one proposal; the agent decides the lines). Tunable constants, not settings.

## The parts

### 1. Per-source breakdown (read side)

The Context block today knows parts (`instructions`, `tools`, `skills`, `agents`, `mcp`, `deferred_tools`, `hooks`, `system`, `other`) but not which plugin or server a part's bytes belong to.

- Skills: `agent_log_skill_listing` stores names, but its bytes are the listing split equally (`size / len(names)`), which is wrong per plugin. The parser measures each skill's own line of the rendered listing instead (parser bump). Group by the `plugin:` prefix (no prefix = user, project or claude.ai skill). Usage = Skill tool calls by name (already in `agent_log_events`).
- Agents: the agent listing attachment carries names, but the parser stores none today. A new per-session agent listing table (names and per-entry bytes) is needed; group by the `plugin:` prefix. Usage = Agent/Task calls by `subagent_type`.
- Tools and MCP: group tool names by `mcp__<server>__`; the claude.ai connectors are servers whose name starts `claude_ai_`. Usage = calls by server. Today `tools` is one byte count for the whole request shape, and the `mcp` part is server *instructions*, not schemas. Per-server weight needs new storage: per-tool bytes from the shape record (`shape.tools`, the full definitions). Author's call after recon: no "≈" estimate — a transcript without the shape record shows the tools as "not measured", like any session parsed before the bump. The deferred tool names (`deferred_tools_*` attachments) give the per-server names either way.
- CLAUDE.md: sizes per `##` section of the workbench folder's CLAUDE.md (read from disk, not from transcripts). Memory index: the size of the auto-memory `MEMORY.md` of the workbench folder's project (`~/.claude/projects/<slug of the workbench folder>/memory/`; Claude Code maps a worktree's sessions to the main folder's memory). This one is per project, not global.
- Where else a plugin/server is turned on: read `~/.claude/settings.json`, `~/.claude/plugins/installed_plugins.json` (project-scope installs) and `~/.claude.json` (user and per-project servers). Read only; names, never values (secrets live in server configs).
- Built-in tools are listed as "can't change".

The report gains these as new keys (pinned keys only grow). This needs a parser bump and new `agentlog.db` tables (agent listing, per-tool or per-server bytes). Rows parsed earlier stay "not measured" until a reparse, as before.

### 2. Mechanical proposer

Runs after the agent analytics import in the daemon (cheap: it only reads the report) and on **Run Now**. Files at most one open proposal per source; a declined fingerprint never returns. Each proposal's evidence: the source's start tokens, its calls in the window (0), the window, the other places it is turned on.

New destinations (each with a Go writer in `internal/coach`, the `textFile`-style rules: atomic write, re-read before rename, compare-and-set, refusals name the label never a path or value):

| Destination | Writes | Undo / Rollback |
|---|---|---|
| `claude_plugin_off` | `enabledPlugins["<plugin>"] = false` in `~/.claude/settings.json` | restores the previous value (or removes the key) |
| `claude_mcp_server_off` | removes a user-scope server from `~/.claude.json`, keeping its config in the proposal row's private sidecar | puts the saved config back |
| `claude_connectors_off` | `env.ENABLE_CLAUDEAI_MCP_SERVERS = "false"` in `~/.claude/settings.json` | restores the previous value |
| `claude_memory_index` | `kind = restructure`; Accept starts a session as in part 3; the agent picks the stale lines, moves them into an archive memory file behind one pointer line, and asks the owner to review the diff before writing (D4) | the session saves the index before writing; Rollback puts that copy back if the index still holds the session's text |
| `repo_*` (existing) | via a session, part 3 | via a session (revert PR) |

Constraints: never touch `watchtower-workbench` / `watchtower` servers, the Watchtower skill pack, or a plugin a Watchtower feature depends on (a deny list in Go: `superpowers`, `pr-review-toolkit` while the review skills name its agents — the builder confirms the list from `.claude/skills`). The Watchtower chat sets `ENABLE_CLAUDEAI_MCP_SERVERS` itself and loads only project/local settings, so `claude_connectors_off` does not reach it; a guard test keeps that true. A secret-bearing server config saved for Undo is stored 0600 outside the database or encrypted with the rest (builder's call within FILES-01).

### 3. Repository changes through a session

Accept on a `repo_*` proposal (mechanical, weekly or chat):
- starts a workbench session in that workbench (its own worktree, the normal placement), titled from the proposal, with a brief built from the proposal: the change (before/after or, for a structural change such as "move sections to docs/features/README.md", the instruction and the measured numbers), why, the review rule (the project's own pre-PR review), "open a PR, do not merge";
- records the session id on the proposal (new column) and sets status `accepted`; the card follows the session's state and the PR (the session report already caches the PR);
- For `claude_memory_index` there is no PR: `measure_from` = the time the session writes the approved index. For a repository change, `measure_from` = the time the change is seen on the default branch (`FileAtHead` of the default branch equal to the PR's text, or the PR merged); not merged in 30 days = too little data, as today;
- Rollback starts a session that reverts it the same way.

The CLAUDE.md move is not a line edit: the proposal carries an instruction plus the measured section sizes, and the session does the multi-file change. `Validate`'s whole-line find/replace stays for line edits; a structural repo proposal has `kind = 'restructure'` and no `after_text` (builder: migration for the kind and the session id).

### 4. Screen

Analytics → Context:
- **Do these**: open context proposals, largest saving first. A row: saving (`−30.2k`), title, tag (`your settings` / `repo · PR`), one evidence line, button (**Turn Off** / **Archive** / **Accept**). A repo row in progress shows the session state and **Open Session**, then **Open PR**.
- Done rows stay faded with the measured saving and **Undo** (settings) for 14 days, then live in **Accepted edits**.
- **What's in it** (fold): each bar opens into its sources — name, tokens at start, calls in the window, "can't change" for built-ins.
- The headline sentence (`lead`) adds "N changes would cut it to ~X".
- Built from the design kit; the coach card is reused where it fits.

## Failure paths

Each has its exit and a test in the plan.

| Failure | What happens | Test |
|---|---|---|
| Settings file changed between proposal and Accept (Claude Code or the owner wrote it) | Only the proposal's own key is compared. If that key changed, the proposal becomes `superseded` and the card says "changed since"; other keys never matter | settings CAS test with an unrelated key changed (applies) and the own key changed (stale) |
| `settings.json` / `~/.claude.json` unreadable or not JSON | Accept is refused with the file's label and nothing is written; the proposer files nothing for that file | refusal test, proposer test |
| Two Accepts at once (double press, Home + Analytics) | The status is flipped `open → accepted` by compare-and-set; the second gets `state_changed`, and Swift keeps the button disabled while one is pending | db CAS test, CoachCenter pending test |
| A repo/memory session fails to start | No `coach accept` is called; the proposal stays open and the card shows the error and **Accept** again | CoachCenter test with a failing starter |
| The session ends without a PR (repo) or without writing (memory) | The card says "Session ended without a PR" / "without a change" with **Open Session**, **Start Again** and **Decline**; the proposal stays `accepted` with no `measure_from`, and after 30 days it is `too_little_data` | presentation test, daemon window test |
| The PR is closed unmerged | Verdict `too_little_data`, card "not merged" | daemon merge-check test |
| A running Claude Code writes its in-memory `~/.claude.json` / settings back and undoes the change | Accept re-reads after writing; the daemon's check finds the key back at `before` and sets verdict `reverted_outside` (not `no_effect`); the card says "Turned back on outside Watchtower" with **Turn Off Again** | after-write check test, daemon check test, reapply test |
| The session started but `coach accept --session` failed | One retry; `state_changed` = accepted elsewhere. Otherwise the card says "Session is running, but Watchtower could not link it" with **Open Session** / **Retry Link**, and **Accept** is hidden so no second session starts | CoachCenter link-failure test |
| A PR refresh fails (no `gh`, network, auth) | Logged, nothing changes, retried next tick; 30 days without a merge still ends as `too_little_data` | daemon refresh-error test |
| Undo of an MCP server whose saved config is missing | Rollback is refused ("saved settings for this server are gone") and nothing is written | rollback test |
| The proposer would touch a protected source (Watchtower servers, pack, `superpowers`, `pr-review-toolkit`) | It is never filed; Accept of a hand-made row with such a key is refused too | guard test `TestCOACH01_ContextNeverTouchesWatchtower` |
| The daemon and `coach run` propose at the same time | Both hold `coach.lock`; the second logs `busy`. Fingerprints are UNIQUE, so a duplicate insert is a no-op | lock test exists; insert conflict test |

Mockup of the screen: `docs/superpowers/specs/2026-11-12-context-actions-mockup.html`. Shots of the real screen come with the Desktop task (`make desktop-shots`).

## Non-goals and anti-goals

- No change applied without a press. No silent background tuning.
- Never break a workbench: the Watchtower servers, pack and hooks are off limits; a change that would remove a tool a Watchtower skill names is refused.
- No git writes from Watchtower code; the session does them.
- No values from config files (tokens, headers) in logs, the database rows, the screen or the brief.

## Open for the builder

- Exact per-server tool bytes source (transcript vs estimate) and the parser bump.
- The deny list's exact contents and how it is kept in step with the review skills.
- Where Undo's saved MCP config lives.
- Whether the Swift side reads proposals as today (`coach proposals --json`) or needs new keys (`session_id`, `kind = restructure`).

## Schema

`coach_proposals` (one-transaction rebuild, as in `00187`):
- `destination` CHECK gains the four new destinations;
- `kind` gains `restructure`;
- `metric` gains `start_tokens`;
- `origin` gains `context`;
- `verdict` gains `reverted_outside`;
- new columns `session_id` (a repo or memory Accept's session; NULL once the Desktop deletes the session row), `via_session` (the row was accepted through a session — survives that delete), `session_branch` (copied from the session while it exists, to find its PR later) and `source_key`. The PR is not stored: it is read from the session report's cache (`workbench_pr_states`) by the session's branch.

In `agentlog.db`: the agent listing table and per-tool/per-server bytes, through its own goose provider.

## Contracts touched

COACH-01. **Kept:** Watchtower writes no git. **Amended, owner approval needed with this spec:**
- a `repo_*` Accept starts a session instead of writing the file;
- repository measurement starts at the merge, not at the folder's HEAD;
- a third origin `context`, with its own destination set, beside the weekly and chat sets pinned by `TestCOACH01_DestinationsAreNeverRepoFiles` and `TestCOACH01_HomeDestinationsStayUnderHome`. The guards are extended, never relaxed., AGENTLOG-01 (names and counts only), FILES-01, the agent analytics pinned keys (grow only). Guides: `docs/guide` pages for Analytics and the coach.
