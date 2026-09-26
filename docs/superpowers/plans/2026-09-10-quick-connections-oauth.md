# Quick Connections OAuth Sign-in Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the owner connect any spec-compliant remote MCP server (Confluence first) by pasting its URL and clicking Sign in — a generic MCP-spec OAuth client (discovery → dynamic client registration → PKCE → refresh) with a pre-launch refresh step so the chat always receives a live bearer token or the connection is visibly marked revoked.

**Architecture:** A new Go package `internal/mcpoauth` owns discovery, registration, PKCE authorize/exchange, refresh and the loopback `Login` loop (house pattern: each provider owns its loop; shared primitives from `internal/auth`). The grant lives in the existing `0600` `mcp_secret_<id>.json` as an additive `oauth` block. `cmd/generator.go`'s `loadExternalMCPServers` gains a refresh-if-expiring step that injects `Authorization: Bearer …` into a copy of the headers and writes `status`/`error` on the row for the first time. CLI `connections oauth <id>`; Desktop Sign in / Sign in again.

**Tech Stack:** Go 1.25 (`net/http`, `httptest`, cobra), SwiftUI + GRDB (WatchtowerCore + WatchtowerDesktop).

**Spec:** `docs/superpowers/specs/2026-09-10-quick-connections-oauth-design.md` — binding. Contracts: `docs/inventory/quick-connections.md` QC-01..03 + the new QC-04 this plan adds.

## Global Constraints

- **QC-01 (native untouched):** do not modify `internal/ai/client.go`'s `buildMCPConfig`/`externalServerConfig`/zero-connection path or `TestBuildMCPConfig_ZeroExternalUnchanged`. The bearer header is injected into `ai.ExternalMCPServer.Headers` by `cmd`, upstream of `ai`.
- **QC-02 (read-only):** no write tool, no registry path.
- **QC-03 (secrets never on argv):** tokens and client secrets live only in the `0600` secret file; a client secret enters only via `--client-secret-stdin`; the derived bearer travels via the existing `0600` temp mcp-config. Never add a token to an argv token or a log line.
- **QC-04 (fresh-or-visible, new):** an OAuth-backed connection reaches the subprocess only with an access token verified/refreshed by Go immediately before launch; a token that cannot be refreshed never reaches the subprocess and the failure is written to the row (`status='revoked'`, `error`). The `Authorization` header is **never persisted** into `Secret.Headers` — inject into a copy.
- **Persist before use:** a rotated refresh token is saved to disk before the new access token is handed to the subprocess.
- **TLS-only** for discovery/token/registration calls, with exactly one exception: plain `http` is accepted when the host is a loopback address (`127.0.0.1`, `::1`, `localhost`) — so `httptest` servers work in tests. The callback listener itself is plain HTTP on `127.0.0.1` (RFC 8252; Jira precedent).
- HTTP clients: inline `&http.Client{Timeout: 30 * time.Second}` (house convention).
- Repo is English-only. No model names hardcoded in Swift. No force-unwraps.
- Inner loop: Go — `go test ./internal/<pkg>` (if a sandbox refuses a path containing `cmd`, use `go test ./... -run <Name>`); Swift — `cd WatchtowerDesktop && swift test --filter <Class>` (Core tests live in `WatchtowerCore` + `Tests/Core`).
- Commit messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.

---

### Task 1: OAuth grant in the secret file (Go, `internal/externalmcp`)

**Files:**
- Modify: `internal/externalmcp/secret_store.go` (the `Secret` struct, ~L13-16)
- Test: `internal/externalmcp/secret_store_test.go` (extend)

**Interfaces:**
- Consumes: existing `Secret{Env, Headers}`, `SecretStore.Save/Load` (0600, `(nil, nil)` when absent).
- Produces (used by Tasks 5–8):
```go
// OAuthGrant is the OAuth 2.1 grant behind an http connection signed in via
// `watchtower connections oauth`. The bearer header is derived from AccessToken
// at chat launch and is never persisted into Headers.
type OAuthGrant struct {
	AccessToken        string    `json:"access_token"`
	RefreshToken       string    `json:"refresh_token,omitempty"`
	ExpiresAt          time.Time `json:"expires_at"`            // zero = unknown, never proactively refreshed
	TokenEndpoint      string    `json:"token_endpoint"`
	ClientID           string    `json:"client_id"`
	ClientSecret       string    `json:"client_secret,omitempty"`
	Scope              string    `json:"scope,omitempty"`
	Resource           string    `json:"resource,omitempty"`    // the MCP server URL (RFC 8707)
	RevocationEndpoint string    `json:"revocation_endpoint,omitempty"`
}

type Secret struct {
	Env     map[string]string `json:"env,omitempty"`
	Headers map[string]string `json:"headers,omitempty"`
	OAuth   *OAuthGrant       `json:"oauth,omitempty"`
}

// Expiring reports whether the access token is already expired or expires
// within skew of now. A zero ExpiresAt is treated as not expiring.
func (g *OAuthGrant) Expiring(now time.Time, skew time.Duration) bool
```

- [ ] **Step 1: Write the failing tests** — in `secret_store_test.go`: (a) `TestSecret_OAuthRoundTrip`: Save a Secret with Headers + a full OAuthGrant, Load, assert deep-equal incl. `ExpiresAt` (use `time.Date(...UTC)`), file mode still `0600`; (b) `TestSecret_LegacyJSONDecodesWithNilOAuth`: write a legacy `{"headers":{"X":"y"}}` file by hand, Load ⇒ `OAuth == nil`, Headers intact; (c) `TestOAuthGrant_Expiring` table: expired ⇒ true; within skew ⇒ true; well ahead ⇒ false; zero ExpiresAt ⇒ false.
- [ ] **Step 2: Run** `go test ./internal/externalmcp/ -run 'TestSecret_OAuth|TestSecret_Legacy|TestOAuthGrant' -v` — FAIL (types missing).
- [ ] **Step 3: Implement** the struct + `Expiring` (`!g.ExpiresAt.IsZero() && !now.Add(skew).Before(g.ExpiresAt)`). Keep the package doc comment; add `time` import.
- [ ] **Step 4: Run** the package — PASS. Also `go test ./internal/ai/` must stay green (it only uses Env/Headers).
- [ ] **Step 5: Commit** `feat(externalmcp): OAuth grant block in the connection secret (additive, 0600)`.

---

### Task 2: Connection status setter (Go, `internal/db`)

**Files:**
- Modify: `internal/db/external_connections.go` (after `SetExternalConnectionEnabled`, ~L117-126)
- Test: `internal/db/external_connections_test.go` (extend)

**Interfaces:**
- Produces: `func (d *DB) SetExternalConnectionStatus(id int64, status, errMsg string) error` — `UPDATE external_connections SET status = ?, error = ? WHERE id = ?`; `RowsAffected()==0` ⇒ `fmt.Errorf("no external_connections row with id %d", id)` (mirror `SetExternalConnectionEnabled`). `status` has no CHECK constraint (migration 00064) — the values this plan writes are `"ok"` and `"revoked"`.

- [ ] **Step 1: Failing test** `TestSetExternalConnectionStatus`: insert a connection, set `("revoked","invalid_grant")`, `GetExternalConnection` shows both; set `("ok","")` clears; unknown id ⇒ error.
- [ ] **Step 2: Run** `go test ./internal/db/ -run TestSetExternalConnectionStatus -v` — FAIL.
- [ ] **Step 3: Implement.** No schema change, no `schema.sql` change.
- [ ] **Step 4: Run** — PASS; `go test ./internal/db/` green.
- [ ] **Step 5: Commit** `feat(db): SetExternalConnectionStatus for external_connections health`.

---

### Task 3: Authorization-server discovery (Go, new package `internal/mcpoauth`)

**Files:**
- Create: `internal/mcpoauth/doc.go` (package comment), `internal/mcpoauth/discovery.go`
- Test: `internal/mcpoauth/discovery_test.go`

**Interfaces:**
- Produces:
```go
// Metadata is the RFC 8414 authorization-server document an MCP server points at.
type Metadata struct {
	Issuer                            string   `json:"issuer"`
	AuthorizationEndpoint             string   `json:"authorization_endpoint"`
	TokenEndpoint                     string   `json:"token_endpoint"`
	RegistrationEndpoint              string   `json:"registration_endpoint,omitempty"`
	RevocationEndpoint                string   `json:"revocation_endpoint,omitempty"`
	CodeChallengeMethodsSupported     []string `json:"code_challenge_methods_supported"`
	TokenEndpointAuthMethodsSupported []string `json:"token_endpoint_auth_methods_supported"`
}

// Discover resolves the authorization-server metadata for an MCP server URL:
//  1. GET <origin>/.well-known/oauth-protected-resource → authorization_servers[0] as issuer (RFC 9728)
//  2. else the server origin is the issuer (the hosted Atlassian case: that document is 404)
//  3. GET <issuer>/.well-known/oauth-authorization-server; on 404 GET <issuer>/.well-known/openid-configuration
// Requires https (plain http only for loopback hosts) and S256 in code_challenge_methods_supported.
func Discover(ctx context.Context, serverURL string) (*Metadata, error)
```
- Internal: `var httpClient = &http.Client{Timeout: 30 * time.Second}`; `func requireSecure(rawURL string) error` (https, or http with loopback host); `func isLoopbackHost(h string) bool`.

- [ ] **Step 1: Failing tests** with `httptest.NewServer` (http on 127.0.0.1 — allowed by the loopback rule): (a) protected-resource present ⇒ issuer taken from `authorization_servers[0]` (serve that issuer's metadata on a second httptest server); (b) protected-resource 404 ⇒ origin is issuer, AS metadata found; (c) AS metadata 404 ⇒ openid-configuration used; (d) all 404 ⇒ error text contains each URL tried; (e) `plain`-only PKCE ⇒ error mentioning S256; (f) `http://example.com/mcp` (non-loopback http) ⇒ error before any request; (g) ctx cancelled ⇒ error.
- [ ] **Step 2: Run** `go test ./internal/mcpoauth/ -v` — FAIL (package missing).
- [ ] **Step 3: Implement** per the doc comment. Origin = scheme+host of the server URL. Decode with `json.NewDecoder`; reject empty `authorization_endpoint`/`token_endpoint`.
- [ ] **Step 4: Run** — PASS. `go vet ./internal/mcpoauth/` clean.
- [ ] **Step 5: Commit** `feat(mcpoauth): authorization-server discovery with RFC 9728/8414 fallbacks`.

---

### Task 4: Registration, PKCE authorize URL, code exchange, refresh, revoke (Go, `internal/mcpoauth`)

**Files:**
- Create: `internal/mcpoauth/flow.go`
- Test: `internal/mcpoauth/flow_test.go` (+ a reusable in-package fake authorization server `fakeAS` used again by Tasks 5 and 6's package tests)

**Interfaces:**
- Consumes: `Metadata` (Task 3), `auth.PKCEPair{Verifier, Challenge}` / `auth.NewPKCEPair()` (`internal/auth/pkce.go`).
- Produces:
```go
type Token struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	Scope        string `json:"scope"`
	ExpiresIn    int    `json:"expires_in"`
}

// ErrInvalidGrant marks a token endpoint answering invalid_grant: the refresh
// token was revoked or expired and the owner must sign in again.
var ErrInvalidGrant = errors.New("mcpoauth: invalid_grant (sign in again)")

// Register performs RFC 7591 dynamic client registration for a public client.
func Register(ctx context.Context, md *Metadata, redirectURI string) (clientID, clientSecret string, err error)
// AuthorizeURL builds the authorization request (PKCE S256, state, optional scope, RFC 8707 resource).
func AuthorizeURL(md *Metadata, clientID, redirectURI, state string, pkce auth.PKCEPair, scope, resource string) (string, error)
// ExchangeCode redeems the authorization code with the PKCE verifier.
func ExchangeCode(ctx context.Context, md *Metadata, clientID, clientSecret, code, redirectURI, codeVerifier, resource string) (*Token, error)
// Refresh performs grant_type=refresh_token; returns ErrInvalidGrant on a 400 invalid_grant.
func Refresh(ctx context.Context, tokenEndpoint, clientID, clientSecret, refreshToken, resource string) (*Token, error)
// Revoke posts the token to the revocation endpoint (RFC 7009); best-effort for callers.
func Revoke(ctx context.Context, revocationEndpoint, clientID, clientSecret, token string) error
```
- Wire format: registration is a JSON POST `{"client_name":"Watchtower","redirect_uris":[redirectURI],"grant_types":["authorization_code","refresh_token"],"response_types":["code"],"token_endpoint_auth_method":"none"}` → read `client_id` and optional `client_secret` from a 201/200 JSON body. Token calls are `application/x-www-form-urlencoded`; `client_id` always in the form; `client_secret` in the form only when non-empty (`client_secret_post`). A non-2xx token response is decoded as `{"error":..,"error_description":..}`; `error == "invalid_grant"` ⇒ `ErrInvalidGrant`, otherwise a wrapped error carrying both fields. Never log token values.

- [ ] **Step 1: Failing tests** — implement `fakeAS` in `flow_test.go`: an `httptest.Server` serving `/.well-known/oauth-authorization-server`, `/register` (returns `client_id`), `/authorize` (records the request), `/token` (authorization_code: verifies `code_verifier` S256 ⇒ stored challenge and `redirect_uri`, issues access+refresh with `expires_in: 3600`; refresh_token: rotates the refresh token, or returns 400 `invalid_grant` when configured), `/revoke` (records). Tests: `TestRegister_PublicClient`; `TestAuthorizeURL_ContainsPKCEStateResource` (parse the URL, assert `code_challenge_method=S256`, `resource`, `state`, `scope` only when set); `TestExchangeCode_Success` and `_WrongVerifierRejected`; `TestRefresh_RotatesToken`, `TestRefresh_InvalidGrantSentinel` (`errors.Is(err, ErrInvalidGrant)`), `TestRefresh_ClientSecretPostedOnlyWhenSet`; `TestRevoke_Posts`.
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** `flow.go`. Shared helper `postForm(ctx, endpoint string, form url.Values) (*Token, error)` for exchange/refresh.
- [ ] **Step 4: Run** `go test ./internal/mcpoauth/` — PASS.
- [ ] **Step 5: Commit** `feat(mcpoauth): DCR, PKCE authorize URL, code exchange, refresh and revoke`.

---

### Task 5: The sign-in loop over a plain-HTTP loopback (Go, `internal/mcpoauth`)

**Files:**
- Create: `internal/mcpoauth/login.go`, `internal/mcpoauth/pages.go` (success/error HTML + app-return block — copy the shape of `internal/jira/auth.go`'s pages and `jiraAppReturnBlock` byte for byte, with "Watchtower" wording)
- Test: `internal/mcpoauth/login_test.go`

**Interfaces:**
- Consumes: `Discover`, `Register`, `AuthorizeURL`, `ExchangeCode` (Tasks 3–4); `auth.RandomState()`, `auth.PortFromAddr(addr)`, `auth.OpenBrowser(url)`, `auth.NewPKCEPair()` from `internal/auth`; `externalmcp.OAuthGrant` (Task 1).
- Produces:
```go
type LoginConfig struct {
	ServerURL    string // the MCP server URL (also the RFC 8707 resource)
	ClientID     string // optional: BYO client id when the server has no registration_endpoint
	ClientSecret string // optional: BYO client secret (came in via stdin)
	Scope        string // optional
}
type LoginOptions struct {
	SkipBrowserOpen bool // print the URL instead of opening the browser
	AppReturn       bool // success page redirects to watchtower-auth://connected
}
// OpenBrowser opens the authorization URL; tests swap it to capture the URL and drive the callback.
var OpenBrowser = auth.OpenBrowser
// Now is the clock used to stamp ExpiresAt; tests swap it.
var Now = time.Now
// Login runs discovery → (registration | BYO) → PKCE authorization over a
// 127.0.0.1 HTTP loopback → code exchange, and returns the grant to persist.
func Login(ctx context.Context, cfg LoginConfig, out io.Writer, opts LoginOptions) (*externalmcp.OAuthGrant, error)
```
- Loop: `Discover` → `listenLocal()` (`net.Listen("tcp","127.0.0.1:%d")` over ports 18531–18540, then `:0`; redirectURI `http://127.0.0.1:<port>/callback`) → client id: `cfg.ClientID`, else `Register` if `md.RegistrationEndpoint != ""`, else error `mcpoauth: server publishes no registration_endpoint; pass --client-id (and --client-secret-stdin if required)` → `state := auth.RandomState()`, `pkce := auth.NewPKCEPair()` → `AuthorizeURL` → `fmt.Fprintf(out, "Open this URL to sign in:\n%s\n", url)`; if `!opts.SkipBrowserOpen` → `OpenBrowser(url)` → serve `/callback` on the listener: `state` mismatch ⇒ error page + error; `error` query param ⇒ error page + error; otherwise `ExchangeCode` ⇒ success page (with app-return block when `opts.AppReturn`) ⇒ result channel. Honour `ctx.Done()`. Build the grant: `ExpiresAt = Now().Add(time.Duration(tok.ExpiresIn)*time.Second)` when `ExpiresIn > 0`, else zero; `TokenEndpoint = md.TokenEndpoint`; `RevocationEndpoint = md.RevocationEndpoint`; `Resource = cfg.ServerURL`.

- [ ] **Step 1: Failing test** `TestLogin_HappyPath` (the `internal/auth/oauth_test.go` `TestLogin_HappyPath` pattern): start `fakeAS`; swap `OpenBrowser` with a func that parses `state`/`redirect_uri` from the captured URL and, in a goroutine, `GET`s `<redirect_uri>?code=<fake code>&state=<state>`; swap `Now`; call `Login` with `SkipBrowserOpen:false`; assert the returned grant (access/refresh tokens from the fake, `ExpiresAt == Now+3600s`, `ClientID` from registration, `TokenEndpoint`, `Resource`). Also: `TestLogin_StateMismatchRejected`; `TestLogin_NoRegistrationAndNoClientIDErrors` (fake without `registration_endpoint`, error mentions `--client-id`); `TestLogin_BYOClientIDSkipsRegistration`; `TestLogin_SkipBrowserOpenPrintsURL` (out contains the authorize URL, `OpenBrowser` never called); `TestLogin_ContextCancelled`.
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** `login.go` + `pages.go`.
- [ ] **Step 4: Run** `go test ./internal/mcpoauth/` — PASS; `go vet` clean.
- [ ] **Step 5: Commit** `feat(mcpoauth): loopback PKCE sign-in loop with DCR and BYO fallback`.

---

### Task 6: Pre-launch refresh hook (Go, `internal/mcpoauth` + `cmd/generator.go`)

**Files:**
- Create: `internal/mcpoauth/refresh.go`; Test: `internal/mcpoauth/refresh_test.go`
- Modify: `cmd/generator.go` — `loadExternalMCPServers` (~L137-171), inside the per-connection loop right after `Load()`
- Test: `cmd/generator_test.go` (extend; create if absent following `cmd/connections_test.go`'s temp-workspace helper)

**Interfaces:**
- Produces:
```go
// RefreshSkew is how early before expiry a token is refreshed.
const RefreshSkew = 60 * time.Second
// EnsureFresh refreshes g in place when it is expiring (or already expired) and
// reports whether it changed. A grant without a refresh token that is expiring
// is an error (sign in again). Returns ErrInvalidGrant when the server revoked it.
func EnsureFresh(ctx context.Context, g *externalmcp.OAuthGrant, now time.Time) (changed bool, err error)
```
- `cmd/generator.go`: add `var externalMCPNow = time.Now` (test seam). In the loop, after `secret, err := store.Load()` succeeds and `secret != nil && secret.OAuth != nil`:
```go
changed, err := mcpoauth.EnsureFresh(context.Background(), secret.OAuth, externalMCPNow())
if err != nil {
	log.Printf("external connection %d (%s): token refresh failed, skipping: %v", c.ID, c.Name, err)
	if serr := database.SetExternalConnectionStatus(c.ID, "revoked", err.Error()); serr != nil { log.Printf(...) }
	continue
}
if changed {
	if err := store.Save(secret); err != nil { log.Printf("... persisting rotated token: %v", err); continue } // persist BEFORE use
}
headers := make(map[string]string, len(secret.Headers)+1)
for k, v := range secret.Headers { headers[k] = v }
headers["Authorization"] = "Bearer " + secret.OAuth.AccessToken   // into the COPY — never into secret.Headers
if c.Status != "ok" {
	if serr := database.SetExternalConnectionStatus(c.ID, "ok", ""); serr != nil { log.Printf(...) }
}
// then build ai.ExternalMCPServer{..., Headers: headers, Env: secret.Env}
```
For connections without `OAuth`, behavior is byte-identical to today.

- [ ] **Step 1: Failing tests** — `refresh_test.go` (uses `fakeAS`): fresh grant ⇒ `changed=false`, zero token-endpoint hits; expiring ⇒ `changed=true`, tokens replaced, `ExpiresAt` advanced from `now`; expiring without refresh token ⇒ error; `invalid_grant` ⇒ `errors.Is(err, ErrInvalidGrant)`. `cmd/generator_test.go` `TestLoadExternalMCPServers_OAuth` table: temp workspace + DB + one enabled http connection + secret file with an `oauth` grant pointing `TokenEndpoint` at an `httptest` token server (loopback http): (a) fresh ⇒ header `Authorization: Bearer <access>` present, no server hit, secret file unchanged; (b) expiring ⇒ server hit once, secret file on disk holds the rotated tokens, header carries the NEW token, `secret.Headers` on disk has NO `Authorization` key; (c) `invalid_grant` ⇒ connection absent from the result, row `status='revoked'` + `error` non-empty, a second non-OAuth connection in the same DB is still returned; (d) row previously `revoked` + successful refresh ⇒ `status='ok'`, `error=''`. Swap `externalMCPNow`.
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** `refresh.go` and the `generator.go` wiring.
- [ ] **Step 4: Run** `go test ./internal/mcpoauth/` and the cmd tests (`go test ./... -run 'TestLoadExternalMCPServers'` if the sandbox refuses the `cmd` path) — PASS; `go test ./internal/ai/` untouched and green.
- [ ] **Step 5: Commit** `feat(connections): refresh OAuth tokens before chat launch; revoked connections surface on the row (QC-04)`.

---

### Task 7: CLI — `connections oauth <id>`, `list` auth column, revoke on `remove` (Go, `cmd`)

**Files:**
- Modify: `cmd/connections.go` (new subcommand registered next to `enable`/`disable`; `list` output; `remove`)
- Test: `cmd/connections_test.go` (extend; the `runConnections`/`runConnectionsSplit` + `writeConnectionsConfig` helpers)

**Interfaces:**
- Consumes: `mcpoauth.Login/LoginConfig/LoginOptions/OpenBrowser/Revoke`, `externalmcp.SecretStore`, `db.SetExternalConnectionEnabled/SetExternalConnectionStatus/GetExternalConnection`.
- Produces (CLI surface — Task 8's Swift arg-builder must match verbatim):
```
connections oauth <id> [--app-return] [--no-open] [--client-id <s>] [--client-secret-stdin]
connections list [--json]      # gains an "auth" column/field: oauth | static | none
connections remove <id>        # best-effort revocation when the grant has a revocation_endpoint
```
- Flag vars (pflag-singleton convention): `connectionsOAuthFlagAppReturn bool`, `connectionsOAuthFlagNoOpen bool`, `connectionsOAuthFlagClientID string`, `connectionsOAuthFlagClientSecretStdin bool`; reset them in `resetConnectionsFlags()` (test helper).
- `runConnectionsOAuth`: `openConnectionsCmdDB` → `GetExternalConnection(id)` → must be `kind == "http"` (else `connection %d is %q; OAuth sign-in applies to http servers only`) → `store := externalmcp.NewSecretStore(cfg.WorkspaceDir(), id)`; `secret, _ := store.Load()` (nil ⇒ `&externalmcp.Secret{}`) → client secret from stdin if flagged (trim; never a flag) → `grant, err := mcpoauth.Login(ctx, LoginConfig{ServerURL: conn.URL, ClientID: flag, ClientSecret: stdinSecret}, cmd.OutOrStdout(), LoginOptions{SkipBrowserOpen: noOpen, AppReturn: appReturn})` → `secret.OAuth = grant` (keep existing Headers/Env) → `store.Save(secret)` → `SetExternalConnectionEnabled(id, true)` → `SetExternalConnectionStatus(id, "ok", "")` → `fmt.Fprintf(out, "Connection %d signed in and enabled.\n", id)` → `warnIfProviderIgnoresConnections(cmd.ErrOrStderr(), cfg, conn.Name)` (the close-v1 honesty rule applies here too).
- `list`: derive `auth` per row from the secret file: `oauth` when `secret.OAuth != nil`, `static` when Env/Headers non-empty, else `none`; a secret-load error renders `?` and never fails the listing.
- `remove`: before deleting the secret file, if `secret.OAuth != nil && secret.OAuth.RevocationEndpoint != ""` → `mcpoauth.Revoke(ctx, ..., secret.OAuth.RefreshToken)`; on error `fmt.Fprintf(cmd.ErrOrStderr(), "warning: token revocation failed: %v\n", err)` and proceed (the existing remove warning precedent).

- [ ] **Step 1: Failing tests** — `TestConnectionsOAuth_SignsInAndEnables`: `fakeAS`-equivalent inline `httptest` server (metadata/register/token) as the connection URL; swap `mcpoauth.OpenBrowser` with a hook that GETs the callback with the state from the URL (in a goroutine); run `connections oauth <id> --no-open`… note `--no-open` bypasses `OpenBrowser`, so for the hook path run WITHOUT `--no-open`; assert exit 0, row `enabled=1`, `status='ok'`, secret file has `oauth.access_token`, stdout contains "signed in and enabled". `TestConnectionsOAuth_RejectsStdioKind`. `TestConnectionsOAuth_NoRegistrationNeedsClientID` (fake without `registration_endpoint` ⇒ non-zero exit, stderr names `--client-id`); `TestConnectionsOAuth_BYOClientIDAndSecretStdin` (secret via stdin, never appears in argv — assert by inspecting the args slice passed to `runConnections`); `TestConnectionsList_ShowsAuthColumn` (oauth/static/none rows); `TestConnectionsRemove_RevokesBestEffort` (fake revocation endpoint records the token; a failing endpoint still removes and prints a warning on stderr — use `runConnectionsSplit`).
- [ ] **Step 2: Run** `go test ./... -run TestConnections -v` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — PASS; whole `cmd` package green; `gofmt -l` clean.
- [ ] **Step 5: Commit** `feat(connections): oauth sign-in subcommand, auth column, best-effort revoke on remove`.

---

### Task 8: Desktop — Sign in with OAuth, Sign in again (Swift)

**Files:**
- Modify: `WatchtowerDesktop/Sources/ViewModels/ExternalConnectionsViewModel.swift` (`oauthArgs`, `signIn`, `addConnection(useOAuth:)`, cancellable auth process — the `SlackAccountsViewModel.runAuthFlow`/`authProcess`/`cancelConnect` pattern)
- Modify: `WatchtowerDesktop/Sources/Views/Settings/AddExternalConnectionView.swift` (http kind: picker **Sign in with OAuth (recommended)** / **Headers (manual)**; OAuth hides the secret editor; Add runs add-then-sign-in)
- Modify: `WatchtowerDesktop/Sources/Views/Settings/QuickConnectionsDetail.swift` (a non-`ok` row shows **Sign in again** → `vm.signIn(connection)`; the dot/help already read `status`/`error`)
- Test: `WatchtowerDesktop/Tests/Core/ExternalConnectionsViewModelArgsTests.swift` (or the existing pure-args test file for this VM — extend where `testAddArgsWithSecretAppendsSecretStdinFlagOnly` lives)

**Interfaces:**
- Consumes the Task 7 CLI surface verbatim: `["connections", "oauth", "<id>", "--app-return"]`.
- Produces: `static func oauthArgs(id: Int64) -> [String]` (always `--app-return`); `func signIn(_ connection: ExternalConnection) async`; `addConnection(name:kind:command:args:url:secretJSON:useOAuth:)` — when `useOAuth`, after a successful add, `refresh()`, find the row by `name` (UNIQUE), then `await signIn(row)`; `cancelSignIn()` terminates the in-flight process (exit 15/9 ⇒ not an error, the Slack precedent).
- Rules: the sign-in process is stored on the VM (`authProcess`) so it survives the sheet closing and can be cancelled; stdout/stderr read before `waitUntilExit()` (the `runProcess` deadlock note); exit 0 ⇒ `refresh()`; non-zero ⇒ stderr prefix as `error`.

- [ ] **Step 1: Failing Core tests** — `oauthArgs(id: 7) == ["connections","oauth","7","--app-return"]`; `addArgs` unchanged (existing test still green).
- [ ] **Step 2: Run** `cd WatchtowerDesktop && swift test --filter ExternalConnectionsViewModel` — FAIL.
- [ ] **Step 3: Implement** the VM pieces; then the views (picker default = OAuth for http; manual path unchanged; `inputError`/`vm.error` display unchanged). `QuickConnectionsDetail`: `if !connection.isOK { Button("Sign in again") { Task { await vm.signIn(connection) } }.disabled(vm.isBusy) }`.
- [ ] **Step 4: Run** the filtered Swift test — PASS; the whole package must build (the filtered `swift test` builds every target).
- [ ] **Step 5: Commit** `feat(desktop): Sign in with OAuth for http Quick Connections; Sign in again on revoked`.

---

### Task 9: Docs — QC-04, inventory changelog, CLAUDE.md

**Files:**
- Modify: `docs/inventory/quick-connections.md` (add `## QC-04 — Fresh-or-visible` with Status/Observable/Why locked/Test guards/Locked since, mirroring QC-03's shape; extend "Known v1 limitation" note if wording changes; changelog entry 2026-09-10)
- Modify: `CLAUDE.md` (Quick Connections feature note: one paragraph on OAuth sign-in — `internal/mcpoauth`, `connections oauth`, pre-launch refresh, QC-04)
- Modify: `docs/inventory/README.md` only if the module→file mapping needs `internal/mcpoauth` added to the Quick Connections row.

- [ ] **Step 1: Write** QC-04 with the exact guard test names from Tasks 6 (`TestLoadExternalMCPServers_OAuth`, `refresh_test.go` cases) and the existing `TestMCPConfigDelivery_SecretGoesToFileNotArgv`.
- [ ] **Step 2: Verify** every symbol/test name named in the docs exists (`grep -rn <name>`).
- [ ] **Step 3: Commit** `docs(quick-connections): QC-04 fresh-or-visible, OAuth sign-in notes`.

---

## Self-review

- **Spec coverage:** §3.1 → T1; §3.2 → T3; §3.3/§3.4 → T4+T5; §3.5 → T6 (+T2 for the status write); §3.6 → T7; §3.7 → T8; §5 QC-04 → T6 guards + T9 doc; revocation on remove → T7; Atlassian fallback discovery (protected-resource 404) → T3 case (b).
- **Contracts:** QC-01 untouched (no `internal/ai` edits); QC-02 no write path; QC-03 client secret via stdin only, tokens in 0600 file, bearer via existing 0600 temp config; QC-04 enforced in T6 with the persist-before-use order and copy-not-mutate header injection.
- **Type consistency:** `externalmcp.OAuthGrant` (T1) is the type `mcpoauth.Login` returns (T5) and `EnsureFresh` mutates (T6); `Metadata` (T3) feeds T4/T5; `Token` (T4) feeds T5/T6; CLI flags (T7) are copied verbatim into `oauthArgs` (T8).
- **Placeholders:** none — every task names files, signatures, wire formats and test cases; the only lookups are file-location conventions (`cmd/generator_test.go` may need creating; the VM's existing pure-args test file name), each with the resolution rule stated.
