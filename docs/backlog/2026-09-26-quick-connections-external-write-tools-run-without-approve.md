---
type: bug
title: Quick Connections external write tools run without Approve
status: done
priority: high
tags: [quick-connections, security, mcp, qc-02]
context: v0.10.0 pre-release safety audit (2026-09-26) — shipped in v0.10.0 as-is
created: 2026-09-26
---

QC-02 ("external tools are read-only, no auto-execute") is not enforced in
code. `internal/ai/client.go:274-279` (`allowedToolsFlag`) grants the whole
external MCP server via one `mcp__<name>` token, so every tool an added server
exposes — including write tools such as an Atlassian `createJiraIssue` or a
Slack send — is callable from the assistant chat without an Approve card. A
prompt injection in synced content could trigger them.

Mitigations today: connections are owner-added and created disabled, and only
the tool-mode chats (main + target) mount them.

Fix options: a per-tool allowlist of read-only tools per connection (default
deny for anything not known read-only); or route external writes through the
agent-actions registry once runtime B lands. At minimum, a UI warning on the
Quick Connections card until then. Re-check the QC-02 wording in
`docs/inventory/quick-connections.md` against whatever ships.

> Original note: «1 в беклог» (owner, on the pre-release audit finding)

Resolved 2026-10-01 (fix/qc-tool-allowlist, owner decision «allow list»): `ai.AllowedTools` grants each allowed external tool as `mcp__<name>__<tool>` instead of the whole server, and every other listed tool is hidden via `--disallowedTools`. Allowed = the server annotates it `readOnlyHint: true`, or (unannotated) its name starts with get/list/search/read/find/describe/lookup, or the owner listed it (`watchtower connections tools <id> --allow`). The `tools/list` is cached per connection (`external_connection_tools`, migration 00094) at enable/sign-in/`--refresh` or once at the next launch; no usable list or no allowed tool ⇒ not mounted (fail closed). QC-02 wording updated to match. Desktop per-tool toggle not built — the Settings card carries a caption pointing at the CLI.

Update 2026-10-02 (fix/qc02-strict-allow): while the owner decides on a write opt-in, `--allow` refuses a tool its server annotates as a write and such a tool is denied in any allow list; an explicit list applies only once the tools are listed.

Owner decision 2026-10-02 («Write нельзя разрешить»): owner naming never unlocks a tool its server declares a write (no `readOnlyHint`, or `destructiveHint: true`); external MCP writes wait for an Approve path.
