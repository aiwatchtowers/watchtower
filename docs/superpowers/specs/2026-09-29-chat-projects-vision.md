# Chat Projects — vision map (2026-09-29)

**Status:** vision / discussion draft. Not a design spec — nothing here is approved for implementation. Each building block below becomes its own spec → plan → PR once the owner picks an order.

**Builds on:** Chat Redesign v1 projects (`chat_projects`, `chat_project_sources`, project instructions/files in the prompt — `docs/superpowers/specs/2026-09-26-chat-redesign-design.md` §6.1), knowledge search (`internal/kb`), the Confluence connector (`internal/extsync`), `internal/doclinks`, targets, meeting transcripts, the dev surface (`watchtower integrate claude-code`).

---

## 1. Why

The owner already runs long-lived "work projects" in Claude Code (a company registry, an EU audit workspace, a gap register). A study of those projects (structure, memory, ~20 sessions) shows what a project is for this owner:

- **Canonical artefacts with ids** (`APP-…`, `INFRA-…`, `DOC-NNN`), each with one source of truth (a Drive docx/xlsx, a Confluence page, a local YAML file).
- **Instructions as project skills** (`.claude/skills/*`: document templates, verification steps, interview flows) and a README, rather than a CLAUDE.md.
- **Heavy memory**: a status card per artefact (version, open items, % closed, owner, blockers), owner rules ("docs in English", "threat model always Medium"), who-is-who, where-things-live.
- **Inputs**: regulation PDFs, Drive files, Confluence/Jira links, Slack, screenshots, source code.
- **Outputs**: docx/xlsx built by scripts, trackers, Jira tickets, published pages.
- **Workflows**: gather everything on a topic; draft a document by interview; challenge a table row by row against code/infra; close open items and write a handover brief; roll an owner decision out across every affected document; "just discuss".

Claude Code's power there comes from the filesystem (Bash, Read/Write/Edit) plus MCP. Its weakness is **context that lives outside the folder**: a colleague's DM with feedback on a document, comments on the Drive file, what a meeting agreed and who owns which action. The owner has to carry that in by hand, and when they don't, the model "hits the post".

### What Watchtower adds that Claude Code cannot

Claude Code exists only while a session is open and knows only what is pasted or fetched. Watchtower is a daemon that has already synced Slack (DMs included), Jira, Confluence, Gmail/IMAP, Calendar and meeting transcripts, indexed them (`kb`), and knows people, targets and decisions. So the product line is:

> **A Watchtower project = the Claude Code engine working in the project's folder + the Watchtower world around it.**

We do not rebuild the engine. We build the world: scoped live context, per-artefact dossiers, a work board, and capture into the project — usable both from the Watchtower chat and from terminal Claude Code.

---

## 2. Scenarios

### S1 — Security & Operation Doc (SOD) closure (the anchor scenario)

There are many SODs, one per asset. For `APP-07`:

1. Colleague A sent feedback on the draft in a Slack DM two days ago.
2. The Drive copy of the docx has four open comments.
3. A meeting last week agreed two items as fine, rejected one, and assigned an action to the asset owner.
4. A Jira ticket holds the owner's answers to verification questions.

The owner opens the project and says "apply the feedback to APP-07". The assistant pulls the `APP-07` dossier (1–4 above, each with a link), edits the docx in the folder, resolves or answers what it can, and updates the `APP-07` target: sub-targets for the remaining open items, progress, and a note with what changed and why.

### S2 — Gather everything on a topic

"Find everything on record keeping" — scoped to the project's channels, Jira projects, Confluence space, meetings and folder first, the rest of the world only if that comes up empty (and visibly so).

### S3 — Multi-agent closure run

"Close every SOD that has only formal gaps left." A coordinating agent reads the board (targets under the project), claims one target per worker agent, each worker pulls its artefact's dossier and works in the folder, and reports back on its target. The owner watches the board fill in the Desktop, and approves anything that leaves the machine (a Jira comment, a Slack reply).

### S4 — Code

The same mechanism with a repository as the folder: the project's scope is its Jira project, channels and people; targets are the work breakdown; worker agents code. The owner can drive it from the Watchtower chat, or from terminal Claude Code with Watchtower connected over MCP — Watchtower holds context and the board, Claude Code executes.

### S5 — Discuss an auditor comment

No writing — the assistant answers with the dossier and the relevant meeting fragments at hand.

---

## 3. Concept model

```
Project
├── folder            local path (a repo, a plain folder, a Drive-for-Desktop folder)
│                     — its .claude/ (skills, settings, .mcp.json) and Claude Code's
│                       auto-memory for that path are used as-is, shared with terminal CC
├── scope             pinned sources: Slack channels/DMs, Jira projects, Confluence spaces,
│                     people, calendar series, mail rules, links, files
├── artefacts         id patterns (e.g. APP-\d+) + the files/pages that carry them
│   └── dossier       everything Watchtower linked to an artefact id, with provenance
├── board             targets linked to the project (and optionally to an artefact),
│                     with sub-targets, status, progress, per-target notes
└── chats             Watchtower chats on the CC engine in the folder
```

**Memory is split by owner, not duplicated:** Claude Code's own auto-memory (in `~/.claude/projects/<path>/memory`) stays the assistant's working memory and is shared with terminal CC. Watchtower's contribution is data it derives mechanically (dossiers, board state), not a second memory the model writes.

---

## 4. Building blocks

### A. Project core — folder + CC engine + project-aware MCP

- A project gains an optional `folder` path. A project chat runs `claude` with that folder as cwd and `--setting-sources project,local` (today every chat runs in the empty `chat.NeutralWorkDir` precisely so no project config leaks in — project chats deliberately invert that, plain chats keep it).
- Claude Code built-ins (Read/Write/Edit/Glob/Grep/Bash) are available in project chats. **Permission modes and rules are Claude Code's own** (default / acceptEdits / plan; `settings*.json` allow/deny) — an owner who already allowed `python3` in the folder sees the same behaviour in Watchtower.
- Unresolved permission checks arrive over the existing stream-json control channel (`--permission-prompt-tool stdio` → `can_use_tool` control request, the same channel `interrupt` already uses) and become a new protocol v2 event `permission_request` → an approval card in the chat (Allow once / Always in this project → writes the rule to `.claude/settings.local.json`, like CC / Deny) → a `permission` command back. *To verify in a spike.*
- `watchtower mcp --project <id>`: the Watchtower MCP server scoped to one project (§B tools + board tools), so terminal Claude Code in the same folder gets the same world. `watchtower integrate claude-code --project <id>` writes it into the folder's `.mcp.json`.

**Contracts touched:** CHAT redesign's "neutral cwd" rule (inverted for project chats only); `WebFetch` hidden everywhere (Bash can reach the network anyway — see §5); DEV-01 "dev MCP is read-only forever" (a project MCP with board writes is a new surface — §5).

### B. Scope + artefact dossiers

- **Soft scope** (owner decision): Watchtower tools search inside the project's sources first and boost them; the model may explicitly widen to everything, and that shows as a visible step.
- New source kinds beyond today's five (`jira_project`, `slack_channel`, `target`, `track`, `person`): Confluence space/page tree, calendar series, a Slack DM/person, a mail rule (sender/domain/label), a link.
- **Artefact id patterns** per project (regex, e.g. `APP-\d+`). A mechanical linker — the `internal/doclinks` shape that already links Jira keys and Confluence URLs — scans synced Slack messages (DMs included), meeting transcripts and recaps, Jira issues/comments, Confluence pages, mail and (after C) Drive comments for those ids, and writes links `(artefact id → source ref)`.
- Name-based matching is fuzzier ("the AML doc"): v1 matches ids only; people/topic matching falls back to scoped `search_knowledge`.
- Tool `get_artefact_context(id)` — the `get_task_context` shape: the artefact's file(s), linked DMs/threads resolved to full conversations, meeting fragments with decisions/actions, Jira, Confluence, Drive comments, and its board target — each section capped, each item with a link.
- **Smart files:** the folder's docx/xlsx/pptx/pdf are extracted with the existing `internal/extract` library into the `kb` index as a project-scoped source, so "which SODs still mention X" is a search, not a Bash crawl.

### C. Google Drive connector

- Drive file metadata + **comments and replies** for files in the project's folder(s), as a new `extsync` provider (the engine is source-agnostic by design; `ext_sources.provider` CHECK widens).
- Files themselves need no download when the folder is Drive-for-Desktop — the bytes are local; the connector maps local paths ↔ Drive file ids.
- **Risk — OAuth scope.** Reading comments on files the app did not create needs `drive.readonly` (a restricted scope → CASA security assessment for the public app). The corporate internal-app flavor avoids verification; the public flavors may have to ship without C or with per-file `drive.file` picking. Owner call.
- Writing back (answering/resolving a comment) conflicts with EXT-01 (read-only forever) — any write would go through the agent-actions registry as an `External` tool, never through the sync engine.

### D. Board — targets as the agents' work tracker

- A target gains `project_id` (and optionally an artefact id). The project page shows its board: target tree, status, progress, per-target notes.
- New registry tools for agents: `update_target` (status/progress/sub-items), `add_target_note`, `claim_target` / `release_target` (a CAS claim like `agent_actions`' `approved → executing`, so two workers never take the same target; a claim expires so a dead worker does not strand it).
- Trust: board writes are local, non-`External` — candidates for `execute` trust inside a project, so a multi-agent run is not one approval card per status change. Anything leaving the machine stays `External` and behind Approve.

### E. Multi-agent runs

- Orchestration itself is Claude Code's (subagents / the Agent tool, or several sessions). Watchtower provides the shared state: the board, claims, notes, and the dossier tool every worker calls.
- Desktop: a run view over the board (who holds what, what changed), approval cards for external writes.
- S4 (code) is A + D + E with a repository as the folder — no code-specific work beyond that.

---

## 5. Cross-cutting risks and owner calls

1. **Prompt injection with a shell.** Project chats combine synced third-party text (DMs, mail, Confluence, web) with Bash and file writes. Claude Code's permission model is the owner's choice (decision above), but "Always allow `Bash(curl:*)`" plus an injected instruction is an exfiltration path. Candidate guard: once a turn has read third-party content, network-capable commands always go to a card regardless of allow rules. Needs an owner call — it is exactly the "not like CC" deviation the owner was unsure about.
2. **DEV-01.** The dev MCP is read-only forever. Board writes from terminal CC are a new, writable surface: either a separate `--project` mode with its own contract, or board writes stay Watchtower-chat-only.
3. **Shared `.claude/` and memory.** Watchtower must never rewrite the folder's skills/settings beyond appending permission rules the owner granted; it does not own CC's auto-memory, only reads it for display.
4. **Drive scope** (C above).
5. **Provider.** Project chats are Claude-only (the CC engine). Codex/Ollama keep the v1 project behaviour.
6. **Public repo hygiene.** Real artefact ids, colleague names and folder paths from the owner's projects never land in fixtures or docs — placeholders only.

---

## 6. Open questions

- Is "project" one object with an optional folder (v1 projects keep working without one), or does a folder-less project stay a separate lighter kind?
- Does the dossier replace the owner re-pasting context, or should the assistant also *propose* links it is unsure of (a name match) for the owner to confirm?
- Where does the owner want to see "what changed since you were last here" — project page on open, the daily briefing, Catch-Up, or all three? (Deferred in the first round — revisit once B exists, since it is the dossier diffed over time.)
- Capture into a project (a reaction command, auto-attach a recording of a meeting in the project's calendar series, mail rules) — which first?
- Board granularity: one target per artefact with sub-targets per open item, or free-form?

---

## 7. Possible sequencing (for discussion)

| Order | Why |
|---|---|
| A → B → D → C → E | Context first: B attacks "hits the post" with data we already sync; Drive comments (C) complete it later. |
| A → D → E → B → C | Organisation first: the board and multi-agent runs (and code) early, context after. |
| B (as MCP only) → A → … | Cheapest test: ship dossiers + scope in `watchtower mcp --project` and use them from terminal CC for a week before building the chat engine change. |
