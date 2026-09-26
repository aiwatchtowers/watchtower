# Quick Connections (external MCP) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the owner add external MCP servers at runtime (no code change, no release) and have the chat assistant use their read-only tools on demand.

**Architecture:** A DB table `external_connections` holds owner-added servers; per-connection secrets live in 0600 files. At chat time `cmd/generator.go` reads enabled connections + secrets and hands them to `ai.Client`, which merges them into the generated `mcpServers` config and extends the `--allowedTools` list. A Desktop Settings card manages the list (read via GRDB, mutate via a new `watchtower connections` CLI). Read-only in v1; native integrations and pipelines are untouched.

**Tech Stack:** Go 1.25 (cobra/viper, modernc.org/sqlite, goose migrations), SwiftUI + GRDB (macOS), the Claude Code / codex CLI as the chat subprocess.

**Spec:** `docs/superpowers/specs/2026-09-09-quick-connections-external-mcp-design.md`

## Global Constraints

- Everything committed to the repo is in English (code, comments, docs, commit messages).
- Read-only external tools only in v1 — no external write path (deferred to runtime B).
- Secrets never appear on argv: persist to a `0600` file under `Config.WorkspaceDir()`, deliver to the chat subprocess via a `0600` mcp-config file (never inline JSON when a secret is present).
- Native integrations, pipelines, memory, digests are NOT touched. `mcp__watchtower` server config is byte-identical to today when zero connections exist (regression pin).
- New table work follows the repo ritual: goose migration + `schema.sql` mirror + `TestAllTablesExist` + golden snapshot regenerate.
- Do NOT bump `CurrentSchemaFormat` in `internal/db/migrations.go`.
- Inner-loop tests only per touched package (`go test ./internal/<pkg>`, `make test-swift FILTER=<Class>`); full gate before the PR.
- Next migration number is `00064` (highest existing is `00063_reaction_commands.sql`).

---

### Task 1: Migration + schema for `external_connections`

**Files:**
- Create: `internal/db/migrations/00064_external_connections.sql`
- Modify: `internal/db/schema.sql` (add the CREATE TABLE block, formatting-model = `slack_accounts` block near `schema.sql:1124`)
- Modify: `internal/db/db_test.go` (add `"external_connections"` to `expectedTables`, near `db_test.go:188`)
- Regenerate: `internal/db/testdata/schema_v73.golden`

**Interfaces:**
- Produces: table `external_connections(id, name, kind, command, args_json, url, enabled, status, error, created_at)` — `kind` CHECK `('stdio','http')`, `name` UNIQUE.

- [ ] **Step 1: Write the migration file**

`internal/db/migrations/00064_external_connections.sql`:
```sql
-- +goose Up
-- Owner-managed external MCP servers ("Quick Connections"). Read-only tools
-- surfaced in the chat on demand; nothing is synced. Secrets live in 0600
-- files (mcp_secret_<id>.json), never in this table.
CREATE TABLE IF NOT EXISTS external_connections (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    name       TEXT    NOT NULL UNIQUE,
    kind       TEXT    NOT NULL DEFAULT 'stdio'
               CHECK(kind IN ('stdio','http')),
    command    TEXT    NOT NULL DEFAULT '',
    args_json  TEXT    NOT NULL DEFAULT '[]',
    url        TEXT    NOT NULL DEFAULT '',
    enabled    INTEGER NOT NULL DEFAULT 0,
    status     TEXT    NOT NULL DEFAULT 'ok',
    error      TEXT    NOT NULL DEFAULT '',
    created_at TEXT    NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now'))
);

-- +goose Down
DROP TABLE IF EXISTS external_connections;
```

- [ ] **Step 2: Mirror the block into `internal/db/schema.sql`**

Add (no goose markers), same column layout as above.

- [ ] **Step 3: Add the table name to `TestAllTablesExist`**

In `internal/db/db_test.go` `expectedTables` slice, add `"external_connections"`.

- [ ] **Step 4: Run migration + table tests (expect PASS after golden regen)**

Run: `go test ./internal/db/ -run 'TestMigrationIdempotent|TestAllTablesExist'`
Expected: PASS.

- [ ] **Step 5: Regenerate the golden snapshot**

Run: `go test ./internal/db/ -run TestSchemaGolden -update`
Then: `go test ./internal/db/ -run TestSchemaGolden` → PASS.

- [ ] **Step 6: Commit**

```bash
git add internal/db/migrations/00064_external_connections.sql internal/db/schema.sql internal/db/db_test.go internal/db/testdata/schema_v73.golden
git commit -m "feat(db): external_connections table (Quick Connections)"
```

---

### Task 2: DB model + queries for connections

**Files:**
- Create: `internal/db/external_connections.go`
- Test: `internal/db/external_connections_test.go`

**Interfaces:**
- Produces:
```go
type ExternalConnection struct {
    ID        int64
    Name      string
    Kind      string   // "stdio" | "http"
    Command   string
    Args      []string // decoded from args_json
    URL       string
    Enabled   bool
    Status    string
    Error     string
    CreatedAt string
}
func (d *DB) InsertExternalConnection(c ExternalConnection) (int64, error)
func (d *DB) ListExternalConnections() ([]ExternalConnection, error)
func (d *DB) ListEnabledExternalConnections() ([]ExternalConnection, error)
func (d *DB) GetExternalConnection(id int64) (ExternalConnection, error)
func (d *DB) SetExternalConnectionEnabled(id int64, enabled bool) error
func (d *DB) RemoveExternalConnection(id int64) error
```

- [ ] **Step 1: Write failing tests**

`internal/db/external_connections_test.go` — insert two rows (one enabled, one disabled), assert `ListEnabledExternalConnections` returns only the enabled one with `Args` decoded, `SetExternalConnectionEnabled` flips it, `RemoveExternalConnection` deletes it, and inserting a duplicate `name` errors (UNIQUE):
```go
func TestExternalConnections_CRUD(t *testing.T) {
    d := newTestDB(t) // existing helper in this package
    id, err := d.InsertExternalConnection(ExternalConnection{
        Name: "trello", Kind: "stdio", Command: "npx", Args: []string{"-y", "trello-mcp"}, Enabled: true,
    })
    if err != nil { t.Fatal(err) }
    _, err = d.InsertExternalConnection(ExternalConnection{Name: "trello", Kind: "http", URL: "https://x"})
    if err == nil { t.Fatal("expected UNIQUE(name) violation") }
    en, err := d.ListEnabledExternalConnections()
    if err != nil { t.Fatal(err) }
    if len(en) != 1 || en[0].Name != "trello" || len(en[0].Args) != 2 {
        t.Fatalf("enabled = %+v", en)
    }
    if err := d.SetExternalConnectionEnabled(id, false); err != nil { t.Fatal(err) }
    en, _ = d.ListEnabledExternalConnections()
    if len(en) != 0 { t.Fatalf("still enabled: %+v", en) }
    if err := d.RemoveExternalConnection(id); err != nil { t.Fatal(err) }
    all, _ := d.ListExternalConnections()
    if len(all) != 0 { t.Fatalf("not removed: %+v", all) }
}
```
(Confirm the package's existing test-DB helper name — grep `func newTestDB` / `OpenInMemory` in `internal/db/*_test.go` and use whichever exists.)

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/db/ -run TestExternalConnections_CRUD`
Expected: FAIL (undefined symbols).

- [ ] **Step 3: Implement `internal/db/external_connections.go`**

Encode/decode `Args` with `encoding/json` to/from `args_json`. Follow the query style of `internal/db/slack_accounts.go` (same package) — `d.conn.Exec`/`QueryRow`/`Query`, scanning into the struct, `Enabled` as `0/1`.

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/db/ -run TestExternalConnections_CRUD`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/db/external_connections.go internal/db/external_connections_test.go
git commit -m "feat(db): ExternalConnection model + queries"
```

---

### Task 3: Secret store (`internal/externalmcp`)

**Files:**
- Create: `internal/externalmcp/secret_store.go`
- Test: `internal/externalmcp/secret_store_test.go`

**Interfaces:**
- Produces:
```go
package externalmcp

type Secret struct {
    Env     map[string]string `json:"env,omitempty"`
    Headers map[string]string `json:"headers,omitempty"`
}
type SecretStore struct{ path string }
func NewSecretStore(workspaceDir string, connectionID int64) *SecretStore
func (s *SecretStore) Load() (*Secret, error) // (nil, nil) on not-exist
func (s *SecretStore) Save(sec *Secret) error // dir 0700, file 0600
func (s *SecretStore) Exists() bool
func (s *SecretStore) Delete() error          // swallow not-exist
func (s *SecretStore) Path() string
```

- [ ] **Step 1: Write failing test**

`internal/externalmcp/secret_store_test.go` — Save then Load round-trips `Env`/`Headers`; Load of a missing file returns `(nil, nil)`; the written file mode is `0600`:
```go
func TestSecretStore_RoundTrip(t *testing.T) {
    dir := t.TempDir()
    st := NewSecretStore(dir, 7)
    if got, err := st.Load(); err != nil || got != nil {
        t.Fatalf("empty load = %v, %v", got, err)
    }
    want := &Secret{Env: map[string]string{"TRELLO_TOKEN": "abc"}}
    if err := st.Save(want); err != nil { t.Fatal(err) }
    fi, _ := os.Stat(st.Path())
    if fi.Mode().Perm() != 0o600 { t.Fatalf("mode = %v", fi.Mode().Perm()) }
    got, err := st.Load()
    if err != nil || got.Env["TRELLO_TOKEN"] != "abc" { t.Fatalf("load = %v, %v", got, err) }
}
```

- [ ] **Step 2: Run to verify it fails** — `go test ./internal/externalmcp/` → FAIL.

- [ ] **Step 3: Implement** — copy the shape of `internal/slack/token_store.go` verbatim (path field, `os.MkdirAll(dir, 0o700)`, `os.WriteFile(path, data, 0o600)`, `json.MarshalIndent`, filename `fmt.Sprintf("mcp_secret_%d.json", connectionID)`).

- [ ] **Step 4: Run to verify it passes** — `go test ./internal/externalmcp/` → PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/externalmcp/
git commit -m "feat(externalmcp): 0600 per-connection secret store"
```

---

### Task 4: `ai.Client` merges external servers into config + allowlist

**Files:**
- Modify: `internal/ai/client.go` (struct field, setter, `buildMCPConfig`, `buildArgs`)
- Test: `internal/ai/client_test.go`

**Interfaces:**
- Consumes: `db.ExternalConnection` fields via a plain DTO (keep `internal/ai` free of `internal/db`):
```go
// in internal/ai
type ExternalMCPServer struct {
    Name    string            // becomes the mcpServers key and mcp__<Name> allow token
    Kind    string            // "stdio" | "http"
    Command string
    Args    []string
    URL     string
    Env     map[string]string
    Headers map[string]string
}
func (c *Client) SetExternalMCPServers(s []ExternalMCPServer)
```
- Produces: `buildMCPConfig` emits one `mcpServers` entry per server; `buildArgs` `--allowedTools` becomes `mcp__watchtower` + `,mcp__<Name>` per server. Zero servers ⇒ byte-identical to today.

- [ ] **Step 1: Write failing tests**

Extend `internal/ai/client_test.go` (match `TestBuildMCPConfig_IncludesExtraArgs` style):
```go
func TestBuildMCPConfig_MergesExternalServers(t *testing.T) {
    c := NewClient("sonnet", "/tmp/w.db", "")
    c.SetExternalMCPServers([]ExternalMCPServer{{
        Name: "trello", Kind: "stdio", Command: "npx", Args: []string{"-y", "trello-mcp"},
        Env: map[string]string{"K": "v"},
    }})
    var parsed struct {
        Servers map[string]struct {
            Command string            `json:"command"`
            Args    []string          `json:"args"`
            Env     map[string]string `json:"env"`
            URL     string            `json:"url"`
        } `json:"mcpServers"`
    }
    if err := json.Unmarshal([]byte(c.buildMCPConfig()), &parsed); err != nil { t.Fatal(err) }
    if _, ok := parsed.Servers["watchtower"]; !ok { t.Fatal("watchtower server missing") }
    tr, ok := parsed.Servers["trello"]
    if !ok || tr.Command != "npx" || tr.Env["K"] != "v" { t.Fatalf("trello = %+v", tr) }
}

func TestBuildArgs_ExternalServersExtendAllowlist(t *testing.T) {
    c := NewClient("sonnet", "/tmp/w.db", "")
    c.SetExternalMCPServers([]ExternalMCPServer{{Name: "trello", Kind: "stdio", Command: "npx"}})
    args := c.buildArgs("sys", "hi", "json", "")
    assertFlagValue(t, args, "--allowedTools", "mcp__watchtower,mcp__trello")
}

func TestBuildMCPConfig_ZeroExternalUnchanged(t *testing.T) {
    c := NewClient("sonnet", "/tmp/w.db", "")
    // no SetExternalMCPServers call
    got := c.buildMCPConfig()
    if strings.Contains(got, "trello") || strings.Count(got, "\"command\"") != 1 {
        t.Fatalf("expected single watchtower server, got %s", got)
    }
}
```

- [ ] **Step 2: Run to verify they fail** — `go test ./internal/ai/ -run 'External|ZeroExternal'` → FAIL.

- [ ] **Step 3: Implement in `internal/ai/client.go`**

Add field `externalServers []ExternalMCPServer` to `Client`, the setter, and the DTO type. In `buildMCPConfig`, after the `watchtower` entry, loop servers: for `stdio` write `{command, args, env}`, for `http` write `{url, headers}` (use the CLI's documented remote-server key — `"url"` + `"headers"`). In `buildArgs`, replace the hardcoded `"mcp__watchtower"` with a computed value that appends `,mcp__<Name>` for each server (order = slice order for deterministic tests).

- [ ] **Step 4: Run to verify they pass** — `go test ./internal/ai/` → PASS (including the existing `TestBuildMCPConfig_IncludesExtraArgs` and `TestBuildArgs_WithDBPath`, which must stay green — the zero-server path is unchanged).

- [ ] **Step 5: Commit**

```bash
git add internal/ai/client.go internal/ai/client_test.go
git commit -m "feat(ai): merge external MCP servers into chat config + allowlist"
```

---

### Task 5: Secret-safe config delivery (0600 mcp-config file when a secret is present)

**Files:**
- Modify: `internal/ai/client.go` (`buildArgs` / the `Query` + `Complete` call sites that pass `--mcp-config`)
- Test: `internal/ai/client_test.go`

**Interfaces:**
- Produces: when any external server carries `Env`/`Headers`, the `--mcp-config` value is a path to a `0600` temp file (not inline JSON), and the file is removed after the subprocess exits. Zero-secret path stays inline JSON (regression pin).

- [ ] **Step 1: Write failing test**

```go
func TestMCPConfigDelivery_SecretGoesToFileNotArgv(t *testing.T) {
    c := NewClient("sonnet", "/tmp/w.db", "")
    c.SetExternalMCPServers([]ExternalMCPServer{{
        Name: "trello", Kind: "stdio", Command: "npx", Env: map[string]string{"TOKEN": "secret123"},
    }})
    args := c.buildArgs("sys", "hi", "json", "")
    val := flagValue(t, args, "--mcp-config") // helper: returns the token after the flag
    if strings.Contains(strings.Join(args, " "), "secret123") {
        t.Fatal("secret leaked into argv")
    }
    // when a secret is present the value is a path to an existing 0600 file
    fi, err := os.Stat(val)
    if err != nil { t.Fatalf("mcp-config not a file: %v", err) }
    if fi.Mode().Perm() != 0o600 { t.Fatalf("mode = %v", fi.Mode().Perm()) }
}

func TestMCPConfigDelivery_NoSecretStaysInline(t *testing.T) {
    c := NewClient("sonnet", "/tmp/w.db", "")
    args := c.buildArgs("sys", "hi", "json", "")
    val := flagValue(t, args, "--mcp-config")
    if !strings.HasPrefix(strings.TrimSpace(val), "{") {
        t.Fatalf("expected inline JSON, got %q", val)
    }
}
```
Add small helpers `flagValue(t, args, flag)` next to `assertFlagValue` if not present.

- [ ] **Step 2: Run to verify they fail** — `go test ./internal/ai/ -run MCPConfigDelivery` → FAIL.

- [ ] **Step 3: Implement**

Add `func (c *Client) hasSecret() bool` (any server with non-empty Env/Headers). In `buildArgs`, when `hasSecret()`, `os.CreateTemp("", "wt-mcp-*.json")`, `Chmod(0o600)`, write `buildMCPConfig()`, append `--mcp-config <path>`, and record the path on the Client (field `mcpConfigTempPath string`) so the caller can delete it. In `Query`/`Complete`, after `cmd.Wait()` (all return paths), `if c.mcpConfigTempPath != "" { _ = os.Remove(c.mcpConfigTempPath) }`. Keep inline JSON when `!hasSecret()`.

- [ ] **Step 4: Run to verify they pass** — `go test ./internal/ai/` → PASS (all).

- [ ] **Step 5: Commit**

```bash
git add internal/ai/client.go internal/ai/client_test.go
git commit -m "feat(ai): deliver mcp-config via 0600 file when a secret is present"
```

---

### Task 6: Wire connections into the chat client (`cmd/generator.go`)

**Files:**
- Modify: `cmd/generator.go` (`newQueryClient` — the claude/codex chat branch, ~`generator.go:116-122`)
- Modify: `cmd/ai.go` (extend the `mcpConfigurable` interface OR add a sibling interface)
- Test: `cmd/generator_wiring_test.go` (existing file)

**Interfaces:**
- Consumes: `db.ListEnabledExternalConnections`, `externalmcp.NewSecretStore`, `ai.ExternalMCPServer`, `ai.Client.SetExternalMCPServers`.
- Produces: in chat mode, the returned Client has external servers set from enabled DB rows + their secrets.

- [ ] **Step 1: Write failing test**

In `cmd/generator_wiring_test.go`, seed a temp DB with one enabled `external_connections` row + a secret file via `externalmcp.NewSecretStore`, call the chat-mode wiring, and assert the Client received one `ExternalMCPServer` with the decoded args + env. (If the Client's external servers aren't externally observable, add a tiny test accessor `func (c *Client) ExternalServersForTest() []ExternalMCPServer` guarded by intent, or assert via `buildMCPConfig()` output containing the server name.)

- [ ] **Step 2: Run to verify it fails** — `go test ./cmd/ -run <name>` → FAIL.

- [ ] **Step 3: Implement**

In the claude/codex chat branch of `newQueryClient`: open the DB (`db.Open(dbPath)` — mirror the ollama branch's `database` + cleanup `func(){ _ = database.Close() }`), call `database.ListEnabledExternalConnections()`, for each load its secret via `externalmcp.NewSecretStore(cfg.WorkspaceDir(), c.ID).Load()`, build `[]ai.ExternalMCPServer`, and pass via `SetExternalMCPServers`. Extend the type-assert seam next to `SetMCPArgs(chatMCPArgs())`. A DB error here must NOT break chat — log it and proceed with zero external servers (native chat keeps working).

- [ ] **Step 4: Run to verify it passes** — `go test ./cmd/ -run <name>` → PASS.

- [ ] **Step 5: Commit**

```bash
git add cmd/generator.go cmd/ai.go cmd/generator_wiring_test.go
git commit -m "feat(cmd): wire enabled external connections into chat client"
```

---

### Task 7: `watchtower connections` CLI

**Files:**
- Create: `cmd/connections.go`
- Test: `cmd/connections_test.go`

**Interfaces:**
- Consumes: the Task 2 DB queries + Task 3 secret store.
- Produces subcommands:
  - `connections add --name N --kind stdio|http [--command C --arg A ...] [--url U] [--secret-stdin]` — inserts a row (disabled by default? No: created disabled, owner enables explicitly per spec §5 consent — set `enabled=0`); when `--secret-stdin`, read JSON `{"env":{...},"headers":{...}}` from stdin and Save via SecretStore.
  - `connections list [--json]`
  - `connections enable <id>` / `connections disable <id>`
  - `connections remove <id>` — delete row + best-effort `SecretStore.Delete()`.

- [ ] **Step 1: Write failing test**

`cmd/connections_test.go` — run `add` (with a piped secret via stdin), assert the row exists disabled and the secret file exists; run `enable`, assert enabled; run `list --json`, assert JSON contains the name; run `remove`, assert row + secret gone. Use the existing cobra command-execution test helper in `cmd/*_test.go` (grep `executeCommand`/`rootCmd` pattern).

- [ ] **Step 2: Run to verify it fails** — `go test ./cmd/ -run TestConnections` → FAIL.

- [ ] **Step 3: Implement `cmd/connections.go`**

Follow the shape of `cmd/slack.go`'s account subcommands (add/enable/disable/remove/list). Secret is read from stdin (never a flag) to honor the argv rule. Register the parent `connectionsCmd` on `rootCmd` in `init()`.

- [ ] **Step 4: Run to verify it passes** — `go test ./cmd/ -run TestConnections` → PASS.

- [ ] **Step 5: Commit**

```bash
git add cmd/connections.go cmd/connections_test.go
git commit -m "feat(cmd): watchtower connections add/list/enable/disable/remove"
```

---

### Task 8: Desktop model + queries

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Models/ExternalConnection.swift`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ExternalConnectionQueries.swift`
- Test: `WatchtowerDesktop/Tests/Core/ExternalConnectionQueriesTests.swift`

**Interfaces:**
- Produces:
```swift
package struct ExternalConnection: FetchableRecord, Identifiable, Equatable {
    package let id: Int
    package let name: String
    package let kind: String       // "stdio" | "http"
    package let enabled: Bool
    package let status: String
    package let error: String
    package init(row: Row)         // explicit, defaults per column
    package var isOK: Bool { status == "ok" }
}
package enum ExternalConnectionQueries {
    package static func fetchAll(_ db: Database) throws -> [ExternalConnection]
}
```

- [ ] **Step 1: Write failing test**

`ExternalConnectionQueriesTests.swift` (Core bundle, `TestDatabase.createDatabaseManager()`): insert two rows via raw SQL, assert `fetchAll` returns them ordered by id with fields decoded.

- [ ] **Step 2: Run to verify it fails** — `make test-swift FILTER=ExternalConnectionQueriesTests` → FAIL (build/undefined).

- [ ] **Step 3: Implement** the model (copy `SlackAccount.swift` `init(row:)` style) and the query (`fetchAll(db, sql: "SELECT * FROM external_connections ORDER BY id ASC")`).

- [ ] **Step 4: Run to verify it passes** — `make test-swift FILTER=ExternalConnectionQueriesTests` → PASS.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/WatchtowerCore/Models/ExternalConnection.swift WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ExternalConnectionQueries.swift WatchtowerDesktop/Tests/Core/ExternalConnectionQueriesTests.swift
git commit -m "feat(desktop): ExternalConnection model + query"
```

---

### Task 9: Desktop ViewModel (poll + CLI shell-out)

**Files:**
- Create: `WatchtowerDesktop/Sources/ViewModels/ExternalConnectionsViewModel.swift`
- Modify: `WatchtowerDesktop/Sources/App/AppState.swift` (declare + init, mirroring `slackAccountsViewModel` at `AppState.swift:187`/`:691`/`:619`)
- Test: `WatchtowerDesktop/Tests/.../ExternalConnectionsViewModelTests.swift`

**Interfaces:**
- Consumes: `ExternalConnectionQueries.fetchAll`, `Constants.findCLIPath()`.
- Produces:
```swift
@MainActor @Observable
final class ExternalConnectionsViewModel {
    private(set) var connections: [ExternalConnection] = []
    var isBusy = false
    var error: String?
    init(dbPool: DatabasePool)
    func refresh()
    func addConnection(name: String, kind: String, command: String, args: [String], url: String, secretJSON: String?) async
    func setEnabled(_ c: ExternalConnection, enabled: Bool) async
    func remove(_ c: ExternalConnection) async
}
```

- [ ] **Step 1: Write failing test**

Assert the argument-builder statics (pure, testable without a process): e.g. `static func setEnabledArgs(for:enabled:) -> [String]` returns `["connections","enable","3"]`; `addArgs(...)` returns the expected token list; secret is passed via stdin, not in args (assert no secret substring in args). Copy the `SlackAccountsViewModel` static-args test pattern.

- [ ] **Step 2: Run to verify it fails** — `make test-swift FILTER=ExternalConnectionsViewModelTests` → FAIL.

- [ ] **Step 3: Implement** — copy `SlackAccountsViewModel` (poll via `refresh()`/`refreshAsync()`, `runCLI(path:arguments:)` reading pipes concurrently, `applyResult` → `refresh()` + `DaemonManager.restart()` on success). For `add` with a secret, write the secret JSON to the process stdin. Wire onto AppState (`initExternalConnections(dbPool:)` called where `initSlackAccounts` is).

- [ ] **Step 4: Run to verify it passes** — `make test-swift FILTER=ExternalConnectionsViewModelTests` → PASS.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/ViewModels/ExternalConnectionsViewModel.swift WatchtowerDesktop/Sources/App/AppState.swift WatchtowerDesktop/Tests/
git commit -m "feat(desktop): ExternalConnectionsViewModel (poll + CLI)"
```

---

### Task 10: Desktop Settings card + Add sheet

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Settings/QuickConnectionsDetail.swift`
- Create: `WatchtowerDesktop/Sources/Views/Settings/AddExternalConnectionView.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Settings/ConnectionStatusLogic.swift:36` (add `case quickConnections` + `label`/`icon`)
- Modify: `WatchtowerDesktop/Sources/Views/Settings/ConnectionsSettings.swift` (detail switch ~line 56, `accountCount` ~68, `status` ~79, and `refresh` on appear ~30)

**Interfaces:**
- Consumes: `appState.externalConnectionsViewModel`.
- Produces: a Connections-tab card listing connections (name · kind · enabled Toggle → `setEnabled` · Remove → confirm → `remove`) + "Add connection" button → `.sheet { AddExternalConnectionView() }`. The Add sheet has name, a kind picker (stdio/http), command+args or url fields shown by kind, an optional secret field, and — when kind == stdio — the TCC/security note.

- [ ] **Step 1: Implement the card + sheet** (SwiftUI views; copy `slackAccountsSection` in `SlackConnectionDetail.swift` and `AddSlackAccountView.swift` structurally). No unit test for pure SwiftUI layout; correctness is the build + manual check.

- [ ] **Step 2: Add the enum case + Connections wiring** — `ConnectionService.quickConnections`, its `label`="Quick Connections", an SF Symbol icon, and the three switch arms in `ConnectionsSettings.swift`; call `appState.externalConnectionsViewModel?.refresh()` in the tab's `onAppear`.

- [ ] **Step 3: Build + lint**

Run: `cd WatchtowerDesktop && swift build`
Run: `make lint-swift`
Expected: clean.

- [ ] **Step 4: Commit**

```bash
git add WatchtowerDesktop/Sources/Views/Settings/QuickConnectionsDetail.swift WatchtowerDesktop/Sources/Views/Settings/AddExternalConnectionView.swift WatchtowerDesktop/Sources/Views/Settings/ConnectionStatusLogic.swift WatchtowerDesktop/Sources/Views/Settings/ConnectionsSettings.swift
git commit -m "feat(desktop): Quick Connections settings card + add sheet"
```

---

### Task 11: Docs — feature note + inventory contracts

**Files:**
- Modify: `CLAUDE.md` (add a "Quick Connections" feature-note paragraph under Feature Notes)
- Create: `docs/inventory/quick-connections.md` (QC-01..03 contracts) + register it in `docs/inventory/README.md`

**Interfaces:** none (docs).

- [ ] **Step 1: Write the CLAUDE.md feature note** — one paragraph: what Quick Connections are, the tier boundary, read-only v1, secret-in-0600-file + config-file delivery, the `connections` CLI + Settings card, and the runtime-B follow-up for writes.

- [ ] **Step 2: Write `docs/inventory/quick-connections.md`** with:
  - **QC-01 (native untouched):** enabling/adding/removing a Quick Connection never changes native sync, pipelines, memory, or digests; `mcp__watchtower` config is byte-identical with zero connections.
  - **QC-02 (read-only, no auto-execute):** external tools are read-only in v1; there is no external write path through the agent-actions registry.
  - **QC-03 (secrets never on argv):** a connection secret is stored 0600 and delivered to the chat subprocess via a 0600 config file, never as an argv token.
  Register the file in `docs/inventory/README.md`'s module→file map.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md docs/inventory/quick-connections.md docs/inventory/README.md
git commit -m "docs: Quick Connections feature note + QC-01..03 contracts"
```

---

## Self-Review notes

- **Spec coverage:** §4.1 registry → Tasks 1–2; §4.1 secrets → Task 3; §4.2 config merge → Task 4; §4.3 allowlist → Task 4; secret-safe delivery (§5 posture / argv rule) → Task 5; §4.5 surfaces (main+target fall out of tool-mode) → Task 6 (no per-surface code needed); CLI → Task 7; §7 Desktop → Tasks 8–10; contracts/docs → Task 11. Tier-3 bridge is out of scope by design.
- **Type consistency:** `ExternalConnection` (db) ↔ `ai.ExternalMCPServer` DTO ↔ Swift `ExternalConnection` are distinct-by-layer on purpose; the mapping lives in Task 6 (Go) and the CLI/GRDB boundary (Swift reads the table, mutates via CLI). `SetExternalMCPServers` name is used identically in Tasks 4 and 6.
- **Verification gotchas:** run `go test ./internal/db/ -run 'TestMigrationIdempotent|TestAllTablesExist|TestSchemaGolden'` after Task 1; full `make test` + `make test-swift` + `make lint-all` before the PR (never pipe through `tail` — capture `$?`).
