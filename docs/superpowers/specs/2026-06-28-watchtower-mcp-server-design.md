# Watchtower MCP Server — v1 (read-only)

**Date:** 2026-06-28
**Status:** Design approved, pending implementation plan
**Scope:** First iteration — a read-only MCP server exposing Watchtower's curated product data to any MCP client (Claude Code, Cursor, Codex, etc.).

## Goal

Let any MCP client pull "what's going on with my work" context from Watchtower into an AI session. The value over the existing third-party `@anthropic-ai/mcp-server-sqlite` (which Watchtower already spawns for its *own* AI subprocesses) is **curated semantic tools** instead of raw SQL — clean, typed, structured results over Watchtower's domains.

This is strictly **read-only**. No write/mutation tools exist in v1.

## Architecture

- **`internal/mcp/`** — new Go package: server construction + tool registration + per-domain tool handlers. Handlers are thin: typed args → existing `internal/db` / `internal/jira` read function → structured JSON result.
- **`cmd/mcp.go`** — thin cobra subcommand `watchtower mcp`. Resolves the DB path via the same `internal/config` resolution used by every other command, opens SQLite **read-only**, builds the MCP server, serves over **stdio**.
- **SDK:** official `github.com/modelcontextprotocol/go-sdk` (pinned `v1.6.1`). It owns the JSON-RPC protocol, tool schemas, and (un)marshaling. No new runtime — everything ships in the existing single Go binary.
- **Read-only enforcement is belt-and-suspenders:** (1) the DB is opened in SQLite read-only mode, and (2) only read tools are ever registered. No code path can write.

### Data flow

```
MCP client (Claude Code/Cursor/Codex)
  → spawns `watchtower mcp` as a stdio subprocess
  → JSON-RPC over stdio
  → go-sdk routes tools/call
  → handler in internal/mcp
  → existing read func in internal/db / internal/jira
  → structured JSON returned as text content
```

## Tools (v1, ≈12)

All results are returned as **JSON text** in the tool's text content (machine-readable, easy to test). Missing data → empty result (`[]` / `null`), never an error. DB errors → MCP `isError` result with a message; handlers never panic.

### Targets
- `list_targets(status?, priority?, level?, ownership?, limit?)` → array of target summaries
- `get_target(id)` → full target incl. sub_items, notes, links

### Briefings / Digests
- `get_today_briefing()` → latest daily briefing
- `list_digests(type?, channel?, since?, limit?)` → digest summaries (channel/daily/weekly)
- `get_digest(id)` → full digest

### People / Tracks / Calendar
- `list_people()` → people-card summaries
- `get_person(query)` → person card by user_id or name match
- `list_tracks(status?)` → narrative tracks
- `get_track(id)` → full track
- `list_upcoming_events(hours?)` → calendar events in the next N hours (default 48)

### Jira
- `list_jira_issues(assignee?, status?, project?, sprint?, limit?)` → issue summaries
- `get_jira_issue(key)` → full issue

**Not in v1** (easy follow-ups): Inbox, meeting-prep (it triggers an AI pipeline, not a cheap read), Jira boards/blockers/workload, full-text digest search.

## Surfacing — "add it to tools"

1. **CLI:** the `watchtower mcp` command itself (stdio server).
2. **Docs:** `docs/` page with a copy-paste config snippet — `claude mcp add watchtower -- watchtower mcp` and the equivalent `.mcp.json` / Cursor / Codex `config.toml` blocks, plus the resolved DB-path note.
3. **Desktop:** a new entry in the macOS app's **TOOLS** sidebar section — a small informational screen showing: server status hint (is `watchtower` on PATH / DB found), the resolved DB path, and a **"Copy config"** button that yields the client config snippet. This screen does **not** run the server (the external MCP client spawns it); it is config/onboarding help only. Follows the existing Models→Queries→ViewModel→View shape per the `add-desktop-feature` skill (read-only / mostly static, so Queries are minimal).

## Error handling

- Handlers return typed errors mapped to MCP `isError` results; no panics escape a handler.
- Absent rows are a normal empty result, not an error (degenerate-but-valid input is a first-class case — covered by tests).
- Unknown/invalid arguments → validation error result with a clear message.
- DB open failure at startup → command exits non-zero with a clear stderr message (before serving).

## Testing

- **Per-handler unit tests** against a temp seeded SQLite DB, mirroring existing `internal/db/*_test.go` fixture patterns. Cover: happy path, empty-result (valid-but-degenerate, e.g. no targets / no briefing today), and a filter-applied case.
- **Smoke test:** build the server, assert `tools/list` returns the expected tool set with valid schemas.
- **Read-only invariant test:** assert no registered tool can mutate (only read tools registered; DB opened read-only).
- Desktop: a minimal ViewModel/Queries test consistent with `add-desktop-feature` conventions.

## Out of scope (v1)

- Any write/mutation tool.
- MCP resources/prompts (tools only for v1).
- Auth / multi-user (local single-user, same DB as the CLI).
- HTTP/SSE transport (stdio only).
