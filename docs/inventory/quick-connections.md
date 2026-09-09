# Quick Connections — Behavior Inventory

**Module:** `internal/db/external_connections.go`, `internal/externalmcp/`, `internal/ai/client.go` (config merge + allowlist), `cmd/connections.go`, `WatchtowerDesktop/Sources/ViewModels/ExternalConnectionsViewModel.swift`, `WatchtowerDesktop/Sources/Views/Settings/{ConnectionsSettings,QuickConnectionsDetail,AddExternalConnectionView}.swift`
**Spec:** `docs/superpowers/specs/2026-09-09-quick-connections-external-mcp-design.md`
**Last full audit:** 2026-09-09

## QC-01 — Native untouched

**Status:** Enforced

**Observable:** Adding, enabling, disabling, or removing a Quick Connection touches only the `external_connections` table (and its `mcp_secret_<id>.json` file) — no native sync phase, pipeline, memory extraction, or digest is read or written. `Client.buildMCPConfig()`'s `watchtower` server entry and `allowedToolsFlag()`'s base `mcp__watchtower` token are unchanged regardless of how many connections exist; with zero enabled connections the whole config and allowlist render byte-identical to the pre-feature output.

**Why locked:** Tier 2 (Quick Connections) is deliberately kept out of the pipelines — it has no watermark, no stable provenance ref, no idempotency key, none of the four guarantees `internal/memory`'s MEM-12 registry and every daemon phase are built on (spec §2). Letting a Quick Connection touch native state, even incidentally, would blur the Tier 1/Tier 2 boundary the spec exists to draw.

**Test guards:** `internal/ai/client_test.go` `TestBuildMCPConfig_ZeroExternalUnchanged` (zero connections ⇒ a single `watchtower` server in the config, byte-identical to pre-feature output), `TestBuildMCPConfig_MergesExternalServers` (an enabled connection adds its own `mcpServers` entry alongside — not in place of — `watchtower`); `internal/db/external_connections_test.go` `TestExternalConnections_CRUD` (registry CRUD touches only its own table); `cmd/connections_test.go` `TestConnections_AddListEnableDisableRemove`.

**Locked since:** 2026-09-09

## QC-02 — Read-only, no auto-execute

**Status:** Enforced

**Observable:** External MCP servers are surfaced only as `mcp__<name>` tools the vendor CLI's own tool loop dispatches directly — they never enter `internal/tools`' `Registry` (no `Propose`/`Apply` row, no `agent_actions` entry, no trust level). `cmd/actions_registry.go`'s `buildToolRegistry` — "the ONE place the assistant's tools are assembled", shared by `mcp --chat`, `actions …`, `jira create`, and the runtime-B loop — registers exactly the built-in write tools (`tools.NewCreateTarget()`, `tools.NewCreateJiraIssue(...)`) plus `tools.ReadTools()`; nothing there reads `external_connections`, so an owner-added connection cannot add a registry tool, no matter how it's enabled.

**Why locked:** AGENT-01..06 (`docs/inventory/agent-actions.md`) hold only for tools dispatched through the registry. An external tool executes silently the moment the vendor CLI calls it — there is no propose/approve step to intercept a write. Until runtime B lands (a Go-owned loop that can route an external call through `Registry.Propose`), the only safe posture is read-only: no external tool may mutate a third-party system, and no code path may make one look like it went through the registry's approval machinery.

**Test guards:** `cmd/connections_test.go` `TestConnections_AddListEnableDisableRemove` (a connection row carries no trust/registry state, only `enabled`/`status`) — there is no dedicated registry-side guard in v1 beyond "the registry never grows a tool from `external_connections`" holding by construction, since `buildToolRegistry`'s tool list is a fixed literal with no `external_connections` read in it. Spec §6 records the reasoning.

**Locked since:** 2026-09-09

## QC-03 — Secrets never on argv

**Status:** Enforced

**Observable:** A connection's credential (env vars for stdio, headers for http) is never a table column and never a CLI flag value — `connections add --secret-stdin` reads it as a JSON payload from stdin and `internal/externalmcp.SecretStore.Save` writes it to `mcp_secret_<id>.json` at `0600`. At chat-launch time, `Client.hasSecret()` detects any external server carrying a non-empty `Env`/`Headers` map and routes the **entire** mcp-config JSON — not just the secret value — to a `0600` temp file (`writeMCPConfigTempFile`) passed via `--mcp-config <path>`; only when no connection carries a secret does the config go inline on argv as before. A temp-file write failure omits `--mcp-config` entirely rather than falling back to inline JSON — a degraded chat beats a leaked secret.

**Why locked:** Argv is visible to every other local process via `ps` (and process-list APIs). A secret is only as safe as `google_token_<id>.json`/`slack_token_<id>.json` if it is stored the same way — 0600, file-based, never argv — end to end, including the moment it's *delivered* to the subprocess, not just at rest.

**Test guards:** `internal/externalmcp/secret_store_test.go` `TestSecretStore_RoundTrip` (0600 file round-trip); `cmd/connections_test.go` `TestConnections_AddHTTPWithoutSecretStdinCreatesNoSecretFile` (no `--secret-stdin` ⇒ no secret file at all); `internal/ai/client_test.go` `TestMCPConfigDelivery_SecretGoesToFileNotArgv` (a secret-carrying connection never appears inline in `buildArgs`'s returned argv, only as a `--mcp-config <path>` pointing at a 0600 file), `TestMCPConfigDelivery_NoSecretStaysInline` (no secret ⇒ config stays inline, unchanged from pre-feature behavior).

**Locked since:** 2026-09-09

## Changelog

- 2026-09-09: file created with QC-01..03, all Enforced, by the Quick Connections feature (Tier 2 of the connection taxonomy in `docs/superpowers/specs/2026-09-09-quick-connections-external-mcp-design.md`). Tier 3 (the pipeline bridge) is specced but not built — no contract yet.
