---
type: bug
title: Quick Connections external write tools run without Approve
status: open
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
