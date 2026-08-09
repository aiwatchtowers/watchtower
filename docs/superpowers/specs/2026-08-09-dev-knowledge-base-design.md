# Watchtower for Developers — Knowledge Base + Skill Pack — Design

**Date:** 2026-08-09
**Status:** draft (owner walkthrough in progress)
**Owner framing baked in:** Watchtower is *the developer's link to the real world*. The direction is **world → dev**: protect flow, and top up the context a ticket never carries. The interface lives **inside the agent session** (Claude Code), the customer controls it **from the CLI**, and the shape is **pull, not push** — Watchtower is a knowledge base, and skills are the know-how for using it well. A recurring dev pain named explicitly by the owner: *"I don't know who to go to."*

## 1. Problem

A developer — and even more so a vibe-coder driving several agent sessions — lives in a tunnel: editor, terminal, agent. The real world (threads, meetings, changing requirements, the people who actually know things) keeps moving outside that tunnel. Three concrete failures follow:

1. **The ticket is not enough context.** A Jira issue says *what* in three lines. The *why*, the constraints agreed in a thread, the decision made on a call, the caveat someone dropped in a channel — none of it is in the ticket. The dev (or their agent) codes against an impoverished brief.
2. **Cocooning.** Deep in the tunnel, the dev misses that the ground moved: requirements changed, someone else already solved it, the approach was vetoed on a sync two days ago.
3. **"Who do I go to?"** Blocked on an unfamiliar subsystem, the dev doesn't know who knows it, who is allowed to decide, or how to approach that person without burning social capital.

Watchtower already ingests exactly the material that answers all three — Slack across accounts, Jira, Gmail, calendar, meeting transcripts, plus derived layers (situations, people cards, tracks, the ideas/decisions registry, the memory vault). Today that material is reachable only through the Desktop app and a thin, uncomposed MCP surface. The dev's agent — the one tool the dev never leaves — cannot get to it in one move, and nothing teaches the agent *when* and *how* to ask.

## 2. Goals

- **Watchtower as the knowledge base of the real world**, addressable from inside an agent session.
- **Composite reads**: one tool call answers a human-sized question ("give me everything about PROJ-123"), instead of ten schema-aware calls.
- **A skill pack as the know-how layer**: shipped skills teach the dev's agent which tools to combine, in what order, and how to present the result. Tools carry facts; skills carry scenarios.
- **"Who to go to" as a first-class answer** — separating *who knows*, *who decides*, and *how to approach them*, always with evidence.
- **Customer-controlled distribution via the CLI**: one command installs, inspects, and removes the integration. Nothing installs itself.
- **Pull only.** No notifications, no context injection, no interruption of the session. The dev asks; the world answers.

## 3. Non-goals (v1)

- **No push mechanics** — no hooks, no statusline badges, no Stop-hook briefs. Anti-cocooning in v1 is served by a skill the dev invokes ("what changed while I was heads-down"), not by Watchtower speaking unbidden. Push is a possible later slice, and if it lands it lands with the same CLI-controlled opt-in levels.
- **No write path to the world** — no replying to Slack, no commenting on issues from the session. The MCP surface stays read-only (the existing `SetReadOnly` guarantee is preserved verbatim).
- **No AI inside the new tools.** Every new tool is mechanical SQL over existing tables. The reasoning happens in the dev's own agent, on the dev's own tokens.
- **No new ingestion source.** No GitHub/GitLab/CI connector in this slice; the value comes from composing what Watchtower already has.
- **No Desktop change.** This slice is Go-only (CLI + MCP + embedded skill files).
- **No non-Claude-Code target.** `integrate` takes the client as an argument so Codex/Cursor can follow, but v1 implements `claude-code` only.

## 4. Architecture overview

Three layers, deliberately separated:

```
┌─ Data layer (Go, mechanical, read-only) ──────────────────┐
│  new MCP tools: get_task_context, find_experts,           │
│                 list_situations / get_situation           │
│  existing:      list_messages, memory_recall, get_person, │
│                 list_transcripts, list_ideas, ...         │
└───────────────────────────────────────────────────────────┘
                          ▲ MCP (stdio, read-only)
┌─ Know-how layer (markdown, embedded in the binary) ───────┐
│  skill pack: task-context, who-to-ask, whats-changed,     │
│              why-decision                                 │
└───────────────────────────────────────────────────────────┘
                          ▲ installed into ~/.claude/skills
┌─ Control layer (CLI, the customer's hand on the switch) ──┐
│  watchtower integrate claude-code | status | remove       │
└───────────────────────────────────────────────────────────┘
```

The dev's agent is the consumer of all three. Watchtower never initiates.

### 4.1 What already exists (verified)

Nothing here needs new ingestion or new schema — the substrate is in place:

- `internal/mcp/server.go` — the server, its `SetReadOnly` connection, `listLimit` clamping, and the `register<Domain>(s, database)` registration pattern the new tools follow.
- `messages_fts` (FTS5 over Slack messages) with `db.SearchMessages(query string, opts SearchOpts)` — channel/user/time filters and FTS5 query sanitisation already handled.
- `jira_slack_links(issue_key, channel_id, message_ts, track_id, digest_id, link_type)` with an index on `issue_key` — the ticket↔thread bridge.
- `situations` / `situation_signals` — the dashboard's storage, including `status`, `priority`, `rank`, the secretary card fields, and `last_signal_at` (which is what a `since` filter keys on).
- `users.email` populated from Slack — the join that maps a git author to a real person.
- `people_cards.decision_role` / `communication_guide` / `communication_style` / `tactics` / `active_hours_json` — the "who decides" and "how to approach" answers, already computed.
- `//go:embed` precedent (`internal/db/migrations.go`, `internal/db/schema_embed.go`) for shipping the skill pack inside the binary.

## 5. Data layer — new MCP tools

All three follow the existing `internal/mcp` conventions: registered in `NewServer`, mechanical SQL, `listLimit` clamping, JSON results, no AI call, no write.

### 5.1 `get_task_context`

*The dossier a ticket should have carried.*

**Input:** `key` — a Jira issue key (`PROJ-123`). **Output:** a single JSON document assembling everything Watchtower knows about that work item:

- the issue itself (summary, description, status, assignee, reporter, labels, sprint/board) and its comments;
- **linked Slack threads** via `jira_slack_links` — the conversations where this key was discussed, with the messages themselves (capped and recency-ordered), not just links;
- **meeting mentions** — transcripts and recaps whose text contains the issue key (a literal match on the key is precise enough to need no scoring; title-term matching is deliberately excluded as a false-positive generator);
- **registry hits** — ideas and decisions whose mentions reference this issue;
- **memory** — vault nodes provenanced to this key;
- **people** — the humans attached to the above (assignee, reporter, commenters, thread participants), each as a compact reference the agent can expand with `get_person`.

Every section is capped independently, so the dossier stays context-window-sized. Sections with nothing to show are omitted rather than emitted empty.

**Why one tool and not "let the agent compose it":** the composition requires knowing that `jira_slack_links` exists, that situations reference signals, that memory provenance uses `jira:<KEY>`. That is schema knowledge no agent should have to carry, and getting it wrong yields a half-empty dossier that *looks* complete.

### 5.2 `find_experts`

*The mechanical half of "who do I go to".*

**Input (exactly one of):** `topic` (free text), `issue_key`, or `emails` (a list — the caller resolved git authors itself; see the skill in §6.2).

**Output:** ranked candidates, each carrying **evidence, not a verdict**:

```
{ user_id, name, real_name, email,
  evidence: [ {kind, detail, count, last_seen, ref}, ... ],
  decision_role, communication_guide, active_hours, ... }
```

Evidence kinds, all derived mechanically:

| kind | source | reads as |
|---|---|---|
| `messages` | `messages_fts` matches, grouped by author, recency-weighted | "14 messages on this in #payments, last 3 days ago" |
| `thread` | participation in threads linked to the issue (`jira_slack_links`) | "replied in the thread on PROJ-123" |
| `jira` | assignee / reporter / commenter on the issue | "assignee of the parent issue" |
| `meeting` | speaker in a transcript segment mentioning the topic | "spoke about this on the sync, Aug 3" |
| `track` | participant in a track covering the topic | "participant in track 'payments migration'" |
| `code` | supplied `emails` matched to `users.email` | "authored 60% of the file (per git blame)" |

Ranking is a transparent weighted sum over recency-decayed evidence counts, and **the weights ship in the response** so the agent can explain the order. No AI, no opaque score.

Three enrichments come along for free from `people_cards`, and they are what turns a list of names into an actionable answer: `decision_role` (who *decides*, not just who knows), `communication_guide` / `communication_style` / `tactics` (how to approach), and `active_hours_json` (when they are actually online — presented honestly as *observed activity*, never as calendar free/busy, which we do not have for other people).

### 5.3 `list_situations` / `get_situation`

The secretary's dashboard — the product's central artifact — is currently reachable only from the Desktop app. These two tools expose it read-only: `list_situations` (filter by status, `since`, limit) and `get_situation` (the situation with its signals, secretary card, and links to the converted target/track). This is what makes "what changed while I was heads-down" answerable at all.

## 6. Know-how layer — the skill pack

Four skills, shipped as markdown embedded in the Go binary (the `//go:embed` precedent from `internal/db/migrations.go`), installed into the client's skills directory. Each is a scenario: trigger, tool sequence, and presentation rules.

### 6.1 `watchtower-task-context`

**Triggers:** starting work on a ticket, naming a Jira key, "I'm picking up X", or an agent about to plan an implementation for a keyed task.
**Does:** `get_task_context` → present the brief the ticket lacked: what is actually being asked, **what changed since the ticket was written** (later thread/meeting material that contradicts or narrows it), decisions already made, open questions nobody answered, and who owns what.
**Presentation rule:** contradictions between the ticket text and later material are surfaced first, explicitly. That is the highest-value thing in the dossier and the easiest to bury.

### 6.2 `watchtower-who-to-ask`

**Triggers:** the dev is blocked, doesn't know who owns a subsystem, asks "who knows about X", or is about to guess at unfamiliar code.
**Does:** if the question is about code, the agent runs `git log`/`git blame` itself (no tool needed — it already has Bash), maps authors to people via `users.email`, and passes them to `find_experts` as `emails`; if the question is about a topic or ticket, it calls `find_experts` with `topic`/`issue_key`. Then it expands the top candidates with `get_person`.
**Presentation rule — three answers, never one:**
1. **Who knows** — with evidence, and *conversational* signal weighted alongside authorship (the person who wrote the code two years ago may be gone; the person arguing about it last week is in it).
2. **Who decides** — from `decision_role`, issue assignment, and track ownership. Asking the knower when you needed the decider is a common and expensive mistake.
3. **How to approach** — channel vs DM, their observed active hours, and the communication guide from their people card.

### 6.3 `watchtower-whats-changed`

**Triggers:** returning after a break, before continuing long-running work, "did the world move while I was in the tunnel", or the end of a long agent-driven work session.
**Does:** `list_situations(since=…)` plus, when the current branch or working directory implies a ticket key, `get_task_context` for it.
**Presentation rule:** filter hard for *relevance to what the dev is doing right now*, and lead with anything that would change the current approach. Everything else is one line or omitted. A noisy answer here trains the dev to stop asking.

### 6.4 `watchtower-why-decision`

**Triggers:** "why is this done this way", archaeology on a constraint, an agent about to "clean up" something that looks wrong, or a design choice being revisited.
**Does:** `list_ideas`/`get_idea` (the decisions registry), `memory_recall`, `list_messages` (FTS), and `list_transcripts`/`get_transcript` for meeting material.
**Presentation rule:** every claim carries provenance — who, where, when, with the ref. An unprovenanced "we decided X" is worse than no answer, because it will be believed.

**Dropped from v1 (YAGNI):** a separate `meeting-recall` skill and a separate `who-is` skill. Meeting transcripts are a *source*, consumed by the two skills above; a person's card is one step of `who-to-ask`. Neither earns its own scenario yet.

## 7. Control layer — `watchtower integrate`

```
watchtower integrate claude-code [--scope user|project] [--path DIR] [--mcp-only|--skills-only]
watchtower integrate status
watchtower integrate remove [claude-code]
```

- **MCP registration.** Registers the Watchtower server with the client (the documented `claude mcp add watchtower -- watchtower mcp` path, using the resolved absolute binary path). If the client CLI is absent, the command prints the exact manual step instead of failing silently.
- **Skill installation.** Writes the embedded pack into `~/.claude/skills/watchtower-<name>/SKILL.md` (`--scope user`, the default) or `<repo>/.claude/skills/...` (`--scope project`). Files carry a `x-watchtower-pack` frontmatter marker plus a content hash; re-running re-syncs only files whose hash still matches what we shipped. **A file the user has edited is never overwritten** — it is reported as drifted and left alone.
- **`status`** reports: MCP registered or not, each skill's state (installed / drifted / missing / stale-version), and the resolved binary path.
- **`remove`** deletes only marker-carrying files and unregisters the MCP server. Never touches anything else in the skills directory.

Design constraint: the installer only ever writes to paths the user named or the documented client defaults, and every write is reported. This is the customer's machine and the customer's agent configuration.

## 8. Behavioral contracts (proposed, `docs/inventory/`)

To be catalogued alongside the existing INBOX/DASH/MEM/IDEA families:

- **DEV-01 — read-only forever.** Every tool in the dev surface is a read. The MCP connection stays `SetReadOnly`; no dev-surface tool may take a write handle. (Extends, does not replace, the existing MCP read-only guarantee.)
- **DEV-02 — no AI in the data layer.** New tools are mechanical SQL. Interpretation happens in the consumer's agent, on the consumer's tokens. A tool that needs a model is the wrong tool.
- **DEV-03 — evidence, not verdicts.** `find_experts` never asserts expertise; it returns countable evidence with refs, and the ranking weights that produced the order. An unprovenanced expert claim is a defect.
- **DEV-04 — the installer never clobbers.** Only files carrying the pack marker *and* matching a shipped hash are rewritten or removed. User edits are preserved and reported as drift.
- **DEV-05 — pull only.** No component of this surface initiates contact with the dev. Anything that would speak unbidden is out of scope until an explicit, CLI-controlled opt-in exists.

## 9. Slices

**Slice 1 — data layer.** `list_situations`/`get_situation`, `get_task_context`, `find_experts`, with tests. Independently useful: an agent with the MCP server already configured gains all of it with no skills at all.

**Slice 2 — know-how + control.** The four skills, the embed, `watchtower integrate` (+ `status`/`remove`), and the docs. Depends on slice 1 only for the tools its skills reference.

## 10. Testing

- **Tool tests** follow the existing `internal/mcp/*_test.go` shape: fixture DB, call the handler, assert the JSON shape, the caps, and empty-source behavior (no Jira account, no transcripts, no memory — each must degrade to an omitted section, never an error).
- **`find_experts` ranking** gets a deterministic fixture asserting order *and* that every candidate carries at least one evidence entry with a resolvable ref (DEV-03).
- **Installer tests** run against a temp HOME: fresh install, idempotent re-run, user-edited file left untouched and reported as drift (DEV-04), `remove` deleting only marker files.
- **Skill files** are lint-checked for frontmatter validity (name/description present, marker present) so a malformed skill can never ship.

## 11. Open questions for the owner

1. **Tool naming.** `get_task_context` reads well from a skill, but the surface already leans on `get_`/`list_` over domain nouns. Alternative: `get_issue_context`.
2. **`find_experts` beyond Slack-identified people.** People who exist in Jira/Gmail but have no Slack user row currently cannot be candidates. Accept for v1, or resolve identities across sources?
3. **Project-scope skills.** Is `--scope project` (skills committed into the dev's repo, shared with teammates) wanted in v1, or is user-scope enough?
