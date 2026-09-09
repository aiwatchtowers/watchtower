# Quick Connections — owner-managed external MCP servers

**Date:** 2026-09-09
**Status:** Draft — pending owner review
**Scope (v1):** Tier 2 only (read-only external MCP tools in chat). Tier 3
(the pipeline bridge) is specified as a Future direction, NOT built here.

## 1. Overview

Today every integration in Watchtower is a *native* one: Slack, Jira, Gmail,
Calendar each get their own OAuth, their own SQLite tables + migrations, their
own daemon sync phase, and their own curated read tools inside the single
`watchtower` MCP server. That is deep, background-observed, and expensive —
days of Go plus a release per source.

The owner wants a second, lighter way in: to **add an external MCP server
himself, at runtime, without a code change or a release**, and have the chat
assistant use its tools on demand — Trello today, Confluence read, Notion,
GitHub tomorrow. Nothing synced, nothing running in the background: ask →
fetch → answer.

This spec introduces that mechanism ("Quick Connections") and, critically,
draws the boundary between it and native integrations so the two never blur.

## 2. Connection taxonomy — the boundary

Watchtower connections fall into three tiers. This spec builds **Tier 2** and
sketches Tier 3 as future work.

| Tier | Name | Storage | Lives in | Cost per source |
|------|------|---------|----------|-----------------|
| 1 | **Native integration** | Full sync into SQLite, rich domain model | Memory, digests, situations, inbox, catch-up, meeting-prep — background | Go package + OAuth + migration + daemon phase + curated tools; a release |
| 2 | **Quick Connection** (this spec) | Nothing persisted | Chat only, on demand | Zero — owner adds it at runtime |
| 3 | **Light observed source** (future bridge) | Normalized rows in a generic `external_items` table | Memory + digests, via a thin adapter | A small adapter per source |

**When a source belongs in Tier 1:** it emits a *stream of events over time*
the assistant must passively weave into proactive intelligence (who decided
what, what changed, what needs you). Slack messages, Jira tickets, mail,
meetings. A Trello board used as a reference, or a wiki page, does not qualify
— native is overkill.

**Tier 2 is deliberately not in the pipelines.** It has no watermark, no stable
local provenance ref, no idempotency key, no determinism guarantee — the four
things every pipeline is built on (`internal/memory` MEM-12 provenance
registry, watermark honesty, dedup, daemon determinism). Wiring a live
external RPC into a background phase would break all four. Tier 3 (below) is
how an external source *can* reach the pipelines — through a normalized local
layer, never a raw live call — and it is out of scope here.

## 3. Scope

**In scope (v1):**
- An owner-managed registry of external MCP servers.
- Merging enabled connections into the chat's MCP config alongside the
  existing `watchtower` server.
- Read-only external tools only (see §6 for why writes are deferred).
- A Desktop Settings surface to add / enable / disable / remove connections.
- Secret storage for connections that need an API key.

**Non-goals (v1):**
- External *write* tools (deferred to runtime B — §6, §10).
- Any pipeline / memory / digest participation (that is Tier 3 — §10).
- Auto-discovery of servers, a server marketplace, or bundled presets.
- OAuth brokering on the owner's behalf for third-party servers (the owner
  supplies whatever credential the server needs).
- Per-connection sync schedules or background execution of any kind.

## 4. Architecture

Five pieces, all additive; nothing native changes.

### 4.1 Connection registry (new)
A new table `external_connections` — one row per server the owner added,
consistent with the `slack_accounts` / `jira_accounts` shape:

- identity: `id`, `name` (owner-chosen label, also the MCP server key), `enabled`
- transport: `kind` (`stdio` | `http`), plus `command` + `args` (stdio) or
  `url` (http/SSE)
- `created_at`, `status`/`error` for surfacing a broken connection

Secrets are **not** columns. A connection's credentials live in a
`0600` file per connection (the `google_token_<id>.json` / `slack_token_<id>.json`
precedent) and are injected as environment variables into the stdio child or as
headers for http — never on argv (house rule: secrets out of argv).

### 4.2 Config merge (`internal/ai/client.go`)
`buildMCPConfig` today hardcodes exactly one server (`watchtower`). It gains a
merge step: enabled `external_connections` rows are added as sibling entries in
the same `mcpServers` object. The `watchtower` server stays exactly as it is —
still local, still no-network, still curated. The two classes sit side by side
in the config but never mix: Watchtower's own server keeps its guarantees; the
external ones are explicitly the owner's, explicitly networked.

### 4.3 Allowlist gating (`buildArgs`)
The chat is locked to `--allowedTools mcp__watchtower`. Each enabled connection
`foo` adds `mcp__foo` to the allowlist. This is the gate: a disabled or removed
connection contributes no allowlist entry, so its tools are invisible to the
model even if a stale config entry lingered. The existing `--disallowedTools`
wall (Bash/WebFetch/Read/…) is untouched.

### 4.4 Transport — remote-preferred
Both stdio and http are supported, but the **recommended** path is a remote
http/SSE endpoint (e.g. Atlassian's hosted Rovo MCP for Confluence). Rationale:
a local `npx`/binary child spawned by the app is a TCC-prompt risk (project
P0 — a child process probing the filesystem can trigger a Files-&-Folders
prompt attributed to Watchtower). stdio children inherit the same CWD pinning
to `os.TempDir()` the chat already uses, and the Settings UI warns when adding
a stdio connection. **[OWNER DECISION 1:** ship both, or remote-only in v1?]**

### 4.5 Surfaces
External tools are offered on the **main AI Chat only** in v1. Draft-only chats
(situation / meeting / idea) carry `toolMode: nil` today and see no tools; the
target chat has its own tightly-scoped mandate. Widening later is additive.
**[OWNER DECISION 2:** main chat only, or also the target chat?]**

## 5. Security posture — the central tension

The chat deliberately hides Bash / WebFetch / Read from the model because
synced Slack/Jira text is a prompt-injection surface, and the open web is an
exfiltration channel (`client.go` comments spell this out). An external MCP
server is, by definition, a network egress the model can call — so Quick
Connections **reopen a channel the current design closes**. This must be faced,
not waved away.

What contains it:
- **Informed, per-connection consent.** Nothing is enabled by default. The
  owner names, adds, and enables each server himself — a deliberate act, not an
  ambient capability. This is the difference between "the model may browse the
  web" and "the owner wired in a Trello reader".
- **Read-only in v1 (§6).** No external tool can *mutate* a third-party system.
- **Named, allowlisted tools.** Only `mcp__<connection>` tools the owner
  enabled are reachable; the deny-wall stays.

What it does **not** fully contain (stated honestly for the review):
- **Read tools still leak.** A prompt-injection payload in synced content can
  steer the model to call `search_trello("<secret from context>")`, sending
  data outward through the query. Read-only shrinks the blast radius (no
  third-party writes) but does not zero the exfiltration surface.
- Mitigation posture for v1: accept the residual risk as the owner's explicit
  per-connection choice, keep it to the main chat, and document it. A harder
  control (e.g. routing external calls through a Go-owned loop that can strip
  or confirm arguments) rides on runtime B. **[OWNER DECISION 3:** accept the
  residual exfiltration risk per-connection in v1, or hold Quick Connections
  until runtime B can mediate the calls?]**

## 6. Why read-only in v1

External MCP tools are dispatched by the vendor CLI's own tool loop, **not**
through `internal/tools`' `Registry.Propose` / `Apply`. That means the entire
agent-actions trust machinery — `External: true` ⇒ always-Approve, the
`agent_actions` proposal ledger, the Desktop approval cards — does **not** wrap
an external write. An external write would either execute silently or fall into
the vendor CLI's own permission prompt (the dead-end UX the chat was built to
avoid). Neither is acceptable.

So v1 exposes external servers as **read-only**: the assistant may query them,
never mutate through them. Governed external writes wait for **runtime B** (the
Go-owned tool loop, `2026-09-05-runtime-b-design.md`), which dispatches tools
in-process and can therefore route an external write through `Registry.Propose`
like any other External tool. This keeps AGENT-01..06 intact.

## 7. Desktop UX (high-level)

A new card under Settings (near the native integrations): a list of Quick
Connections (name · transport · enabled · status), an "Add connection" sheet
(name, transport = remote URL / local command, optional secret), and
enable/disable/remove. Adding a stdio connection shows the TCC/security note.
No connection is enabled until the owner flips it on. Writes verdicts directly
via GRDB (the Settings-editor precedent), then triggers one chat-config refresh.

## 8. Testing (high-level)

- Config-merge unit test: N enabled connections ⇒ N+1 `mcpServers` entries and
  N+1 allowlist tokens; disabled/removed ⇒ absent. The `watchtower` entry is
  byte-identical to today when zero connections exist (no-regression pin).
- Secret never appears on argv (assert the child's argv).
- Registry CRUD + status transitions.
- Allowlist gate: a disabled connection contributes no `mcp__` token.

## 9. Open decisions for owner review

1. **Transport** — ship both stdio + remote http, or remote-only in v1? (§4.4)
2. **Surfaces** — main chat only, or also the target chat? (§4.5)
3. **Residual exfiltration risk** — accept per-connection in v1 (read-only,
   main chat, documented), or hold the whole feature until runtime B can
   mediate external calls? (§5) — *this is the load-bearing one.*
4. **Storage** — DB table (as specced, consistent with `*_accounts`) vs a
   plain config-file list. DB recommended.

## 10. Future — Tier 3, the pipeline bridge (NOT in this spec)

When the owner has a concrete external source he wants *observed in the
background* (not merely queried in chat), the bridge is:

- A generic `external_items` table (id, connector, external_id, title, body,
  ts, url) with a stable provenance ref `ext:<connector>:<id>`.
- The MEM-12 provenance registry extended with an `ext:` resolver (it was
  built to generalize exactly this).
- A thin per-source **adapter** contract `Sync(since) → []ExternalItem`, run as
  its own daemon phase with its own watermark, swallowing failures like every
  other sync phase. An adapter may use an external MCP server as its transport,
  but the pipelines only ever read the normalized local table — never a live
  RPC.

This keeps watermark honesty, provenance, idempotency, and determinism intact.
Its shape should be designed against the *first real source the owner wants
observed*, not speculatively — so it is deliberately deferred.

## 11. References

- `internal/ai/client.go` — chat MCP config, allowlist, deny-wall, TCC posture.
- `internal/tools/registry.go` — `External`, `Trust`, `Propose`/`Apply`.
- `docs/superpowers/specs/2026-09-04-agent-actions-design.md` — AGENT-01..06.
- `docs/superpowers/specs/2026-09-05-runtime-b-design.md` — the Go-owned loop
  that later enables governed external writes.
- `docs/inventory/memory.md` — MEM-12 provenance registry (Tier 3 anchor).
