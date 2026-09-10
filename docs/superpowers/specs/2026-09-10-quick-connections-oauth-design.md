# Quick Connections — OAuth sign-in for remote MCP servers

**Date:** 2026-09-10
**Status:** Approved (owner, 2026-09-10; autonomous build-to-merge mandate)
**Builds on:** `2026-09-09-quick-connections-external-mcp-design.md` (Tier 2 Quick Connections, PR #147) and its close-v1 wave (PR #148).

**Owner decisions (2026-09-10):**
1. Watchtower owns the OAuth machinery — a generic client implementing the MCP
   authorization flow (discovery → dynamic client registration → PKCE
   authorization code → refresh). Delegating to the claude CLI's own MCP auth
   was rejected: it rides undocumented CLI internals, needs an interactive TUI
   the Desktop cannot drive cleanly, and would leave tokens outside our store.
2. Generic first, no per-service code, ever. A server that lacks dynamic
   registration is handled by the same flow with owner-supplied client
   credentials (BYO) — a fallback inside the one path, not a second path.
3. A successful OAuth sign-in leaves the connection **enabled**. The consent
   screen is the deliberate act; a second "Enable" click after signing in is
   friction with no safety value. The manual (headers/env) add path keeps
   "created disabled".
4. First live target: the hosted Atlassian MCP server (Confluence). A spike on
   2026-09-10 confirmed `https://mcp.atlassian.com/.well-known/oauth-authorization-server`
   publishes RFC 8414 metadata with `registration_endpoint`, PKCE `S256`,
   `token_endpoint_auth_methods_supported` including `none`, and
   `authorization_code` + `refresh_token` grants. Its
   `/.well-known/oauth-protected-resource` returns 404, so discovery must fall
   back to authorization-server metadata at the server origin.

## 1. Overview

Quick Connections v1 stores a **static** secret per connection (`env` for stdio,
`headers` for http) and hands it to the chat subprocess unchanged. That fits API
keys. It does not fit OAuth: an access token expires (Atlassian's in about an
hour), and the chat is a headless `claude -p` subprocess with no stdin and no
TTY — it can neither complete a browser handshake nor refresh a token
mid-conversation (established in the B4 grounding, 2026-09-09).

The owner's requirement is blunt: **paste a server URL, click Sign in, done** —
for Confluence today and for whatever spec-compliant remote MCP server comes
next, with zero code per service.

This spec adds that: a generic OAuth client that speaks the MCP authorization
specification, a token grant stored next to the connection's existing secret,
and a pre-launch refresh step so the subprocess always receives a live bearer
token or the connection is visibly marked broken. Nothing about *what the tools
do* changes — connections stay read-only and chat-only (QC-01..03 hold).

## 2. Scope

**In scope:**
- MCP-spec OAuth client in Go: metadata discovery with fallbacks, dynamic
  client registration (DCR), PKCE (S256) authorization-code flow over the
  existing localhost-loopback + system-browser machinery, refresh-token grant.
- Persisting the grant in the connection's existing `0600` secret file.
- A pre-launch refresh hook in the chat wiring; `status`/`error` written on the
  connection row for the first time (revoked/expired surfaces in Settings).
- CLI `watchtower connections oauth <id>` (+ BYO client-credential flags,
  `--app-return`, `--no-open`) and a `connections list` auth indicator.
- Desktop: "Sign in" path in the add sheet for http servers, a "Sign in again"
  action on a revoked connection, a status dot that finally reflects reality.
- Best-effort token revocation on `connections remove` when the server
  advertises a `revocation_endpoint`.
- Contract QC-04 (below) + inventory/CLAUDE.md updates.

**Out of scope (deliberate):**
- Writing or bundling MCP servers for any service. Never.
- OAuth for stdio servers (they keep the env-token model).
- Presets, marketplace, per-service adapters.
- Wiring Quick Connections into codex/ollama (still claude-only; the close-v1
  honesty caption/warning stays as is).
- Tier 3 (pipeline bridge) and runtime-B external writes (B5).

## 3. Architecture

Five additive pieces. The v1 config merge (`internal/ai.Client`,
`externalServerConfig` → `{"type":"http","url","headers"}`) is untouched: the
refresh hook simply sets `Headers["Authorization"]` before the existing code
sees the connection.

### 3.1 Grant storage — extend the secret, not the schema
`internal/externalmcp.Secret` gains an optional `oauth` block:

```
{"headers": {...},                   // still allowed alongside (manual extras)
 "oauth": {"access_token": "…", "refresh_token": "…", "expires_at": "RFC3339",
           "token_endpoint": "…", "client_id": "…", "client_secret": "…"(optional),
           "scope": "…", "resource": "<MCP server URL>",
           "revocation_endpoint": "…"(optional)}}
```

Same `mcp_secret_<id>.json`, same `0600`, same `SecretStore`. The derived
`Authorization: Bearer …` header is **never written into `headers`** — it is
computed at launch from `oauth.access_token`, so a stale value can never be
persisted as if it were a static secret. No new table or column: the connection
row already has `status`/`error`; `kind` stays `http`.

### 3.2 Discovery (`internal/mcpoauth/discovery.go`)
Input: the connection's server URL. Steps, in order, all `https` only, with a
bounded `http.Client` timeout:
1. `GET <server-origin>/.well-known/oauth-protected-resource` → if 200, take
   `authorization_servers[0]` as the issuer.
2. Otherwise treat the server origin as the issuer (the Atlassian case).
3. `GET <issuer>/.well-known/oauth-authorization-server`; on 404 fall back to
   `GET <issuer>/.well-known/openid-configuration`.
4. Parse RFC 8414 metadata: `authorization_endpoint`, `token_endpoint`,
   `registration_endpoint` (optional), `revocation_endpoint` (optional),
   `code_challenge_methods_supported`, `token_endpoint_auth_methods_supported`.
   Require `S256` in the challenge methods (refuse `plain`-only servers).

A `401` probe of the server itself is not required for discovery; a
`WWW-Authenticate: … resource_metadata="<url>"` hint, when present, is honoured
as step 1's URL.

### 3.3 Client registration (`internal/mcpoauth/flow.go`)
If metadata has `registration_endpoint` and the caller supplied no client id:
`POST` `{client_name:"Watchtower", redirect_uris:[<loopback>],
grant_types:["authorization_code","refresh_token"], response_types:["code"],
token_endpoint_auth_method:"none"}` → persist `client_id` (and `client_secret`
if the server insists on issuing one). If there is no `registration_endpoint`,
the CLI requires `--client-id` (and accepts `--client-secret-stdin`) — the BYO
fallback — and continues down the identical authorize/exchange/refresh path.

### 3.4 Authorization — PKCE over the existing loopback
A new package `internal/mcpoauth` carries its own `Login` loop — the house
pattern (Slack, Jira, Gmail and Calendar each own theirs) — reusing the shared
primitives from `internal/auth`: `RandomState`, `PortFromAddr`, `OpenBrowser`,
`NewPKCEPair`. The loopback listener is **plain HTTP on 127.0.0.1** with its
own port range (RFC 8252, the `internal/jira/auth.go` precedent): no
self-signed certificate, so no browser warning, and dynamic client
registration accepts `http://127.0.0.1:<port>/callback` redirect URIs. The
success page and its `--app-return` block (redirect to
`watchtower-auth://connected`) follow the Jira copy byte for byte.

Authorize URL: `response_type=code`, `client_id`, `redirect_uri`, `state`,
`code_challenge` (S256) + `code_challenge_method=S256`, `scope` if configured,
and `resource=<MCP server URL>` (RFC 8707, as the MCP spec requires). Token
exchange sends `code_verifier`. On success: save the grant, set
`enabled=1`, `status='ok'`, clear `error`.

### 3.5 Pre-launch refresh — the load-bearing piece
`cmd/generator.go`'s `loadExternalMCPServers` gains one step per enabled
connection whose secret carries an `oauth` block:
`mcpoauth.EnsureFresh(ctx, grant, now)`:
- If `expires_at − skew(60s) > now` → no network, use the stored access token.
- Else `POST token_endpoint` `grant_type=refresh_token` (client id; secret if
  present) → persist the rotated tokens (refresh tokens may rotate) → use the
  new access token. Persist **before** launching: a crash after refresh but
  before save would otherwise burn a rotated refresh token.
- Then `Headers["Authorization"] = "Bearer " + access_token` and hand the
  connection to `ai.Client` exactly as today.
- Refresh failure (`invalid_grant`, network, malformed) → skip **only this
  connection**, write `status='revoked'` + the error to its row, log. The chat
  launches without it; the failure is visible in Settings, never silent.
- Refresh success on a row previously `revoked` → `status='ok'`, error cleared.

`loadExternalMCPServers` already degrades gracefully per connection (close-v1
precedent) — this extends that rule to auth freshness. The clock is injected
for tests.

### 3.6 CLI
- `watchtower connections oauth <id> [--app-return] [--no-open] [--client-id X] [--client-secret-stdin]`
  — discovery → (DCR or BYO) → PKCE sign-in → save → enable. `--no-open` prints
  the authorize URL instead of opening the browser (the test/headless hook).
  Errors: not an http connection; discovery failed (with the URLs tried); no
  `registration_endpoint` and no `--client-id` (message names the flag).
- `connections add` unchanged (creates disabled). `connections list` shows an
  `auth` column: `oauth` / `static` / `none`, plus `status`.
- `connections remove`: if the grant has `revocation_endpoint`, best-effort
  `POST` the refresh token (failure logged, removal proceeds).
- `connections enable/disable` unchanged.

### 3.7 Desktop
- Add sheet, http kind: a picker **Sign in with OAuth (recommended)** /
  **Headers (manual)**. OAuth path hides the headers editor; on Add the view
  model creates the row (`connections add`) and then runs
  `connections oauth <id> --app-return`, awaited like `slack add --app-return`
  (`SlackAccountsViewModel` pattern), then refreshes the list. The
  `watchtower-auth://connected` return just refocuses the app, as today.
- Card: the status dot reads the row's `status` (green `ok`, red `revoked`
  with the `error` as help text); a `revoked` row shows **Sign in again**,
  which runs the same CLI command. `ExternalConnection.isOK` is derived from
  `status == "ok"`.
- Pure Core helpers for anything testable without the app: the CLI
  arg-builder for `oauth` (mirrors `addArgs`), the status→presentation
  mapping.

## 4. Security posture
- Tokens live only in the `0600` secret file and reach the subprocess only via
  the `0600` temp mcp-config (QC-03 unchanged — the presence of an OAuth grant
  makes `hasSecret()` true by construction).
- PKCE S256 + random `state`; public client (no secret) when DCR allows
  `token_endpoint_auth_method=none`; TLS-only discovery and token calls
  (plain http accepted only for loopback hosts, so tests can use `httptest`);
  the callback listener is plain HTTP bound to `127.0.0.1` only (RFC 8252 —
  the authorization code it receives is single-use and bound to the PKCE
  verifier that never leaves the process).
- Refresh-token rotation is persisted before use; a refresh failure is
  surfaced on the row, never swallowed (QC-04).
- Read-only + chat-only + per-connection consent are unchanged (QC-01, QC-02
  and its documented residual).
- The DCR client registration is per install (one `client_id` per connection
  per machine) — no shared Watchtower OAuth app, no shared secret to leak.

## 5. Contracts
QC-01, QC-02, QC-03 unchanged. New:

**QC-04 — Fresh-or-visible.** An OAuth-backed connection reaches the chat
subprocess only with an access token that Go verified or refreshed immediately
before launch. A token that cannot be refreshed never reaches the subprocess,
and that failure is written to the connection row (`status='revoked'`,
`error`) where Settings shows it — no silent degradation, no stale bearer on
the wire. Guards: refresh-hook tests (expiring → refreshed header; failure →
skipped + revoked; fresh → zero network calls), plus the existing
`TestMCPConfigDelivery_SecretGoesToFileNotArgv` covering the bearer's delivery.

## 6. Testing
- Fake authorization server (`httptest`): metadata (with/without
  `registration_endpoint`, with/without protected-resource document),
  registration, token (authorization_code with PKCE verifier check,
  refresh_token with rotation, `invalid_grant`), revocation.
- Discovery: protected-resource → issuer; 404 fallback to origin; 404 fallback
  to openid-configuration; refuse non-https; refuse `plain`-only PKCE.
- Flow: PKCE verifier/challenge correctness; `state` mismatch rejected; CLI
  `oauth --no-open` driven end to end by hitting the callback URL from the test
  (the existing loopback test pattern), asserting the saved grant, `enabled=1`,
  `status='ok'`.
- Refresh hook with an injected clock: fresh token → no network; expiring →
  refreshed + persisted + header set; failure → connection skipped, row
  `revoked`, other connections unaffected; previously revoked → `ok` on
  success.
- Swift Core: `oauthArgs` builder (verbatim flag names), status → dot/label
  mapping; VM add-then-sign-in ordering with a fake CLI runner.
- Gate: `go test ./...`, `make lint-all`, `make test-swift`.

## 7. Future (not here)
- Token revocation from Settings without removing the connection.
- Reusing one DCR registration across connections to the same issuer.
- OAuth-backed stdio servers (if any ever need it).
- Tier 3 bridge; runtime-B governed external writes (B5).

## 8. References
- `internal/auth/oauth.go` — loopback + browser + `--app-return` machinery.
- `internal/jira/auth.go` — Atlassian OAuth precedent (refresh, token store).
- `internal/externalmcp/secret_store.go`, `cmd/generator.go`
  (`loadExternalMCPServers`), `cmd/connections.go`, `internal/ai/client.go`.
- `docs/inventory/quick-connections.md` — QC-01..03.
- MCP authorization specification; RFC 8414 (AS metadata), RFC 7591 (DCR),
  RFC 7636 (PKCE), RFC 8707 (resource indicators), RFC 9728 (protected
  resource metadata).
