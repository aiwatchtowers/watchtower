# Phone Inbox on One Tower Interface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the Inbox's logic and every Inbox-row write (and then the Desktop's chat writes) into Go behind one generated tower interface, reached by the Mac over an always-on daemon socket and by the iPhone through the hub, and add an Inbox tab to the iPhone.

**Architecture:** `internal/tower` holds a command registry, an envelope and a request ledger (`tower_requests`) that gives exactly-once writes to both transports. A generator writes the Swift types into a new Foundation-only package `WatchtowerInterface`, which also holds `TowerClient` and the shared screen models. `internal/inboxfeed` builds the feed and applies every Inbox action; the Mac binds to it over `<workspace>/tower.sock`, the hub publishes it as `inbox_folder`/`inbox_card` slices and accepts `inbox_act`.

**Tech Stack:** Go 1.26 (`database/sql` over the in-repo SQLCipher driver, goose migrations, `testing/synctest`), Swift 5.10 language mode (SwiftUI macOS 14 / iOS 17, GRDB fork for reads only), xcodegen for the phone.

**Spec:** `docs/superpowers/specs/2026-11-15-mobile-inbox-design.md` (owner approved in ask #1368). Mockups: `docs/design/mockups/mobile-inbox/index.html` (§§1–6 phone, §7 Mac Inbox states, §8 tray and other screens).

## Global Constraints

- The wire is additive (protocol spec `docs/superpowers/specs/2026-10-31-hub-phone-protocol-design.md` §8). `slices.AllKinds`, `secure.dataKinds` and the Kit `SliceKind` change together. `handlers.NudgeTable` is pinned to `WatchtowerKit/Tests/Fixtures/link/hub_contract_cases.json`. The legacy names `inbox_item` (slice) and `inbox_resolve`/`inbox_dismiss`/`inbox_snooze` (Kit `ActionKind`) stay unused.
- An envelope is at most 900 KB. A block document is at most 128 KB canonical, so one card is one record. `body` is clipped to 16 KB when `opts.Clip` is set.
- The read, done and dismiss marks stay guarded by `content_hash`. Every Go writer keeps its Swift writer's guard.
- Under MDM `MobileSync = workbench_only` the hub publishes no Inbox kinds (POLICY-03).
- Write transactions are `BEGIN IMMEDIATE` and short: no rendering, LLM call, tool run or network call inside one. A new migration follows the `add-migration` skill.
- `WatchtowerCore` stays Kit-free (`PublicAPISurfaceTests`). It may import `WatchtowerInterface`, which depends on Foundation only (swift-tools 5.10, `.macOS(.v14)`, `.iOS(.v17)`, no package dependencies).
- Phone design: flat rows, cards only for waiting items and detail blocks, orange only for waiting-for-you, no row separators outside a card. Desktop: `docs/design/desktop-style-guide.md`. Both: colours only through Tone; every user-facing string lives in a model (`TowerText` or the model that owns it) with a test.
- Refusal codes are exactly `not_found`, `changed`, `args_changed`, `reply_waiting`, `not_permitted`, `unsupported`. A guarded no-op answers `ok` with `already: true`. A refusal `sentence` is written in Go and shown as is by both clients.
- Ledger window: `actions.ActionMaxAge` (7 days) + `retentionMargin` (1 day). Socket retries stop after 15 s. Approve/retry over the socket wait for the tool at most 120 s.
- `TowerClient` timing: retry at 0.2 s doubling to 2 s; "Reconnecting to Watchtower…" only after 1 s down; `failed` after 15 s.
- Change watch: own writes emit `changed` at commit; foreign writes by a `PRAGMA data_version` poll every 250 ms, run only while at least one watch is open.
- Speed gates (fixture: 2 000 outputs, 200 approvals, 500 open items, 30 folders): `inbox.feed` over the socket ≤ 100 ms median, a write command ≤ 15 ms median; `BenchmarkPersistStart` no slower than the Swift start; the stub-provider chat timing test's median no more than 20 ms worse. A path that fails its gate does not switch. A cache table is never the fix.
- Phone feed: `Limit: 300, Clip: true`; Needs approval and Waiting for me first, then the rest newest first.
- Inventory guards move with their `Test<Module>NN_` names and are never weakened; a change that would weaken one stops and asks the owner.
- Tests never wait on wall-clock time (inject clocks, use `testing/synctest` in Go and a manual `Clock` in Swift); a test that spawns a process kills and waits for its process group in `t.Cleanup`; a package whose tests create git repositories calls `gittest.DisableBackgroundGit()` in `TestMain`.
- Repo files stay English and free of live-install data (`acme`, `example.com`, "colleague A").

## Review Focus

1. **A reader in another time zone than the Mac.** The feed carries UTC stamps only (`stamp`, no time inside `source_line`); "Today/Earlier" grouping and every displayed time are computed in the shared screen models with the client's own `TimeZone.current`, so the phone groups by the phone's zone and the Mac by the Mac's. Task 6 adds `TestBuild_StampsAreUTCAndSourceLineHasNoTime`; Task 10 adds `testTodayEarlierFollowsTheClientZone` with a non-UTC zone.
2. **A body clipped in the middle of a multi-byte character or an over-long card.** `Clip` cuts on a rune boundary and sets `body_clipped`; a card whose canonical blocks exceed 128 KB is sent as a notice card, never as a broken record. Task 6 adds `TestClip_CutsOnARuneBoundary` and `TestBuild_OversizeBlocksBecomeANotice`.
3. **An action pressed while the Mac sleeps for more than 15 s.** It fails with Retry, and Retry re-sends the same `request_id`, so a first send that did land returns its stored result instead of acting twice. Task 4 adds `testRetryAfterFailureReusesTheRequestID`.
4. **A malformed or endless frame on the socket** (no newline, garbage, a 50 MB line). The server answers `unsupported` for garbage, closes the connection past `MaxFrame`, and keeps serving others. Task 3 adds `TestSocket_OversizeFrameClosesOnlyThatConnection` and `TestSocket_GarbageLineAnswersUnsupported`.
5. **Folders deeper than three levels on the phone.** The phone draws three levels; a deeper folder's cards and counts roll up into its level-3 ancestor instead of vanishing. Task 10 adds `testFoldersPastThreeLevelsRollUpIntoTheThirdLevel`.

---

## Stage 0 — the tower interface

### Task 1: `internal/tower` core, the ledger and `tower.hello`/`tower.ping`

**Depends on:** none

**Files:**
- Create: `internal/tower/tower.go` (`Tower`, `New`, `Options`, `Origin`), `internal/tower/registry.go` (`Registry`, `Register`, `Spec`, `HandlerFunc`, `Ctx`), `internal/tower/call.go`, `internal/tower/ledger.go`, `internal/tower/refusal.go`, `internal/tower/prune.go`, `internal/tower/builtin.go`
- Create: `internal/tower/api/envelope.go`, `internal/tower/api/tower.go`
- Create: `internal/db/migrations/00190_tower_requests.sql` (next free number at implementation time; 00190 today), `internal/db/tower_requests.go`
- Modify: `internal/db/schema.sql`, `internal/db/db_test.go` (`TestAllTablesExist`), `internal/db/testdata/*.golden`, `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`
- Modify: `internal/hub/actions/hygiene.go` (export the window), `cmd/sync.go` (`runSyncDaemon` starts the prune loop)
- Create: `docs/features/tower-interface.md`; Modify: `CLAUDE.md` (feature line "Tower interface — `tower-interface.md`"), `docs/features/README.md` (summary)
- Test: `internal/tower/call_test.go`, `internal/tower/ledger_test.go`, `internal/tower/prune_test.go`, `internal/db/tower_requests_test.go`

**Interfaces:**
- Produces (Go, `internal/tower/api`):
  - `type Request struct { V int \`json:"v"\`; ID string \`json:"id"\`; Command string \`json:"command"\`; Params json.RawMessage \`json:"params,omitempty"\` }`
  - `type Response struct { ID string \`json:"id"\`; Status Status \`json:"status"\`; Result json.RawMessage \`json:"result,omitempty"\`; Refusal *Refusal \`json:"refusal,omitempty"\` }`; `type Status string` with `StatusOK = "ok"`, `StatusRefused = "refused"`, `StatusUnknown = "unknown"`
  - `type Refusal struct { Code RefusalCode \`json:"code"\`; Sentence string \`json:"sentence"\` }`; `type RefusalCode string` with the six codes as constants (`CodeNotFound` … `CodeUnsupported`)
  - `type WriteParams struct { RequestID string \`json:"request_id"\` }` (embedded in every write request)
  - `type HelloRequest struct{}`; `type HelloResponse struct { InterfaceVersion string \`json:"interface_version"\`; Build string \`json:"build"\`; SyncPaused bool \`json:"sync_paused"\`; NoSync bool \`json:"no_sync"\` }`
  - `type PingRequest struct{}`; `type PingResponse struct { At string \`json:"at"\` }`
  - `const EnvelopeVersion = 1`
- Produces (Go, `internal/tower`):
  - `type Spec struct { Read bool; Idempotent bool; Grant string; ChangeTables []string; Watch bool; IdempotentFor func(params json.RawMessage) (bool, error); GrantFor func(params json.RawMessage) (string, error) }` — `Read`: no ledger, no `request_id`; `ChangeTables` of a read or watch = tables whose change re-reads it, of a write = tables it changes; `IdempotentFor`/`GrantFor` override the static fields when set (used by `inbox.act`).
  - `type HandlerFunc[Req, Resp any] func(ctx context.Context, c *Ctx, req Req) (Resp, error)`
  - `func Register[Req, Resp any](r *Registry, name string, h HandlerFunc[Req, Resp], spec Spec)` — panics on a duplicate name; records `reflect.Type` of `Req` and `Resp`.
  - `func (r *Registry) Commands() []Command`; `type Command struct { Name string; Req, Resp reflect.Type; Spec Spec }`
  - `func (r *Registry) IsIdempotent(name string, params json.RawMessage) (bool, error)`; `func (r *Registry) GrantFor(name string, params json.RawMessage) (string, error)`
  - `type Origin struct { Transport string /* "socket" | "hub" */; Device string }`
  - `type Options struct { Registry *Registry; Build string; Now func() time.Time; Paused func() bool; NoSync bool; Changed func(tables []string); Sentence func(command string, err error) string }`
  - `func New(d *db.DB, o Options) *Tower`; `func (t *Tower) Call(ctx context.Context, req api.Request, o Origin) api.Response`
  - `type Ctx struct { DB *db.DB; Origin Origin; Now func() time.Time }` with `func (c *Ctx) Write(ctx context.Context, fn func(tx *sql.Tx) (any, error)) (any, error)` — opens a write transaction, runs `fn`, for a guarded command writes the `done` ledger row with the marshalled result in the same transaction, commits, then calls `Options.Changed(spec.ChangeTables)`.
  - `func Refuse(code api.RefusalCode, sentence string) error`; `type RefusalError struct { Code api.RefusalCode; Sentence string }`
  - `func RegisterBuiltins(r *Registry)` registers `tower.hello` (Read) and `tower.ping` (Read).
  - `var InterfaceVersion = "dev"` (Task 2 replaces it with a generated constant).
  - `const PruneInterval = time.Hour`; `func Prune(ctx context.Context, d *db.DB, now time.Time) (int64, error)`; `func RunPrune(ctx context.Context, d *db.DB, now func() time.Time)` (prunes at start, then every `PruneInterval`, returns when `ctx` ends).
- Produces (Go, `internal/db`): `type TowerRequest struct { RequestID, Command, State, ResultJSON, At string }`; `func (db *DB) GetTowerRequest(ctx context.Context, id string) (*TowerRequest, error)`; `func BeginTowerRequestTx(tx *sql.Tx, id, command string, at time.Time) error`; `func FinishTowerRequestTx(tx *sql.Tx, id, command, resultJSON string, at time.Time) error` (upsert to `done`); `func (db *DB) PruneTowerRequests(ctx context.Context, before time.Time) (int64, error)` (deletes `done` and `begun` rows with `at < before`).
- Produces (Go, `internal/hub/actions`): `const LedgerRetention = ActionMaxAge + retentionMargin` (8 days).

- [ ] **Step 1: Migration and DB ledger (follow `.claude/skills/add-migration/SKILL.md`)**

`00190_tower_requests.sql` Up: `CREATE TABLE tower_requests (request_id TEXT PRIMARY KEY, command TEXT NOT NULL, state TEXT NOT NULL CHECK (state IN ('begun','done')), result_json TEXT NOT NULL DEFAULT '', at TEXT NOT NULL); CREATE INDEX idx_tower_requests_at ON tower_requests(at);` Down drops both. `at` uses the repo's `%Y-%m-%dT%H:%M:%SZ` UTC format. Mirror into `schema.sql` with a one-line comment per column ("Go-written by internal/tower: the request ledger, exactly-once writes for the socket and the hub"). Add `tower_requests` to `TestAllTablesExist`. Regenerate: `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`.

Tests in `internal/db/tower_requests_test.go`: `TestTowerRequests_BeginThenFinish` (state goes `begun`→`done`, result kept), `TestTowerRequests_PruneDropsOldOfBothStates` (rows at now−9 d of both states gone, rows at now−7 d kept, return value 2).

Run: `go test ./internal/db/ -run 'TowerRequests|TestMigrationIdempotent|TestAllTablesExist|TestSchemaGolden|TestDesktopTestSchema'` — Expected: PASS.

- [ ] **Step 2: Write the failing `Call` tests** (`internal/tower/call_test.go`, `ledger_test.go`; each registers test commands `test.read`, `test.guarded`, `test.once` on a fresh `Registry` over a temp DB)

- `TestCall_UnknownCommandIsUnsupported`: `Status == "refused"`, `Refusal.Code == "unsupported"`.
- `TestCall_WriteWithoutRequestIDIsUnsupported`.
- `TestCall_GuardedDoneRowCommitsWithTheWrite`: after `ok`, the handler's row and a `done` ledger row exist; with a fault returned from `fn`, neither exists.
- `TestCall_GuardedRepeatOfDoneReturnsTheStoredResult`: the handler runs once; the second response's `Result` equals the first byte for byte.
- `TestCall_GuardedBegunIsReRun`: a seeded `begun` row for a guarded command → the handler runs, answer `ok`.
- `TestCall_NonIdempotentCommitsBegunBeforeActing`: inside the handler, `GetTowerRequest` sees `begun`.
- `TestCall_NonIdempotentRepeatOfBegunAnswersUnknown`: the handler does not run; `Status == "unknown"`.
- `TestLedger_KillBetweenBegunAndWrite_Guarded` / `_NonIdempotent` and `TestLedger_KillBetweenWriteAndReply_Guarded` / `_NonIdempotent`: build the database state each kill leaves (no row / `begun` / `done`), resend the same `request_id`; guarded → applied once or stored result; non-idempotent → `unknown` or stored result. Row counts prove "never twice".
- `TestCall_RefusalCarriesCodeAndSentence`: a handler returning `Refuse(CodeChanged, "This card changed — look again")` → that code and sentence; no `done` row for a refused guarded call (a resend may succeed later).
- `TestCall_ChangedFiresAfterCommitOnly`: `Options.Changed` is called with the spec's tables after commit and never on a rollback.
- `TestHello_ReturnsVersionBuildAndPause`, `TestPing_AnswersOK`.

Run: `go test ./internal/tower/` — Expected: FAIL (package does not exist).

- [ ] **Step 3: Implement `internal/tower` and `internal/tower/api` to the Interfaces above**

`Call` decodes `request_id` from `Params` for non-`Read` commands, reads the ledger row, decides by `IsIdempotent`, commits `begun` in its own short transaction for a non-idempotent call, runs the handler, writes `done` (non-idempotent: after the handler returns, in a short transaction; guarded: inside `Ctx.Write`, or after the handler if it never called `Write`). A handler error that is not a `RefusalError`: a `Read` command or a guarded write (its transaction rolled back, so nothing landed) answers `refused` with code `unsupported` and a sentence (`Options.Sentence(command, err)`, default the error text; Task 8 supplies "Couldn't mark it done: the database is busy."-style sentences) and writes no `done` row, so Retry may succeed; a non-idempotent command that fails after its `begun` row answers `unknown`.

- [ ] **Step 4: Run the tests** — `go test ./internal/tower/` — Expected: PASS.

- [ ] **Step 5: Prune, shared window and daemon wiring**

Write `TestPrune_HubOffDropsOldKeepsFresh` (`synctest.Test`: `RunPrune` with no hub, rows at now−8 d−1 s of both states are gone after start, a row at now−1 h survives; advancing the bubble clock by `PruneInterval` prunes a row that aged past the window) and `TestPrune_UsesTheHubLedgerWindow` (`tower`'s window equals `actions.LedgerRetention`). Export `LedgerRetention` in `internal/hub/actions/hygiene.go` and use it in `Prune`. In `cmd/sync.go` `runSyncDaemon`, start `go tower.RunPrune(ctx, database, time.Now)` before `d.Run(ctx)`.

Run: `go test ./internal/tower/ ./internal/hub/actions/ && go build ./cmd/...` — Expected: PASS.

- [ ] **Step 6: Docs** — `docs/features/tower-interface.md` sections: Commands and envelope, Ledger (guarded vs non-idempotent, `begun`/`done`, `unknown`, prune window), Builtins (`tower.hello`, `tower.ping`); later tasks append Generator, Socket, Pause. Add the CLAUDE.md feature line and the README summary (key types `tower.Spec`, `tower_requests`, migration 00190).

- [ ] **Step 7: Lint and commit**

Run: `make lint-diff` — Expected: no new issues.

```bash
git add internal/tower internal/db cmd/sync.go internal/hub/actions/hygiene.go WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift docs/features CLAUDE.md
git commit -m "feat(tower): command registry, envelope and request ledger (#1170)"
```

### Task 2: Generator and the `WatchtowerInterface` package

**Depends on:** Task 1

**Files:**
- Create: `internal/tower/gen/main.go`, `internal/tower/gen/swift.go`, `internal/tower/gen/golden.go`, `internal/tower/gen/gen_test.go`, `internal/tower/gen/testdata/sample/sample.go`, `internal/tower/gen/testdata/sample.swift.golden`
- Create: `internal/tower/commands/commands.go` (`RegisterAll`) — the one place every package registers its commands (Task 1's builtins now; later tasks add theirs)
- Create (generated): `internal/tower/interface_version.go`, `WatchtowerInterface/Sources/WatchtowerInterface/Generated/TowerTypes.swift`, `.../Generated/TowerCommands.swift`, `.../Generated/InterfaceVersion.swift`, `WatchtowerInterface/Tests/WatchtowerInterfaceTests/Generated/GoldenRoundTripTests.swift`
- Create: `WatchtowerInterface/Package.swift`, `WatchtowerInterface/Sources/WatchtowerInterface/RawJSON.swift`, `WatchtowerInterface/.swiftlint.yml` (copy `WatchtowerChatText/.swiftlint.yml` if present, excluding `Generated/`)
- Create: `internal/tower/api/testdata/*.json` (one golden per registered request/response type: `Request.json`, `Response.json`, `HelloResponse.json`, …)
- Modify: `Makefile` (`gen-interface`, `gen-interface-check`, `interface-test`; `test-swift` unfiltered also runs `interface-test`; `lint-swift` lints `WatchtowerInterface`; `lint-all: lint lint-swift gen-interface-check`), `.github/workflows/ci.yml` (Go Test job: `make gen-interface-check` after Build; Swift Lint + Kit Test job: SwiftLint and `swift test` for `WatchtowerInterface`)
- Modify: `WatchtowerDesktop/Package.swift` (`.package(path: "../WatchtowerInterface")`, `WatchtowerCore` depends on product `WatchtowerInterface`), `WatchtowerMobile/project.yml` (package + app dependency), regenerate `WatchtowerMobile/WatchtowerMobile.xcodeproj` with `make mobile-gen`
- Modify: `WatchtowerDesktop/Tests/Core/PublicAPISurfaceTests.swift`
- Modify: `CLAUDE.md` (Build & Test gains `make gen-interface` / `make interface-test`), `docs/features/tower-interface.md` (Generator section)

**Interfaces:**
- Consumes: `tower.Registry.Commands()` (Task 1).
- Produces:
  - Go enum convention: a `type X string` with `func (X) EnumValues() []string` becomes a Swift enum with every value plus `case unknown(String)` (decoding an unlisted value yields `.unknown(value)`, encoding writes it back).
  - Swift mapping: `string`→`String`, `bool`→`Bool`, `int`→`Int`, `int64`→`Int64`, `float64`→`Double`, `[]T`→`[T]`, `map[string]T`→`[String: T]`, `json.RawMessage`→`RawJSON`, pointer or `omitempty`→optional, struct→`public struct X: Codable, Hashable, Sendable` with `CodingKeys` from the JSON tags. `time.Time` and any other type fail the generator with the field's path.
  - `public struct RawJSON: Codable, Hashable, Sendable { public let data: Data }` (hand-written; round-trips any JSON value byte-stable after canonical re-encode).
  - `public enum TowerCommand: String, CaseIterable, Sendable` (one case per registered name, e.g. `case towerHello = "tower.hello"`) with `public var isRead: Bool`.
  - `public enum InterfaceVersion { public static let current: String }` and Go `const InterfaceVersion = "<16 hex>"` — the first 16 hex chars of SHA-256 over `TowerTypes.swift` + `TowerCommands.swift` as generated.
  - `func commands.RegisterAll(r *tower.Registry)`.
  - `go run ./internal/tower/gen -root <repo>` writes; `-check` writes into a temp dir and exits 1 with a unified diff when anything differs.

- [ ] **Step 1: Write the failing generator tests** (`internal/tower/gen/gen_test.go`)

- `TestGenerate_SampleMatchesGolden`: generating the `testdata/sample` types (a struct with a pointer, an `omitempty` field, a slice, a map, a nested struct, an enum with `EnumValues`, a `json.RawMessage`) equals `testdata/sample.swift.golden`.
- `TestGenerate_TimeFieldFails`: a struct with `time.Time` → error naming `Sample.At`.
- `TestGenerate_HeaderOnEveryFile`: every generated file starts with `// Code generated by go run ./internal/tower/gen. DO NOT EDIT.`
- `TestEveryRegisteredTypeHasAGolden`: for every `commands.RegisterAll` command, `internal/tower/api/testdata/<Req>.json` and `<Resp>.json` exist (types with no fields are exempt), and each decodes with `DisallowUnknownFields` and re-encodes to the same canonical JSON.
- `TestInterfaceVersionIsTheOutputHash`: the generated Go constant equals the hash of the generated Swift.

Run: `go test ./internal/tower/gen/` — Expected: FAIL.

- [ ] **Step 2: Implement the generator** (reflection over `Commands()` plus the envelope types; deterministic order by type name; Swift output formatted to pass `swiftlint --strict` with the package's config)

- [ ] **Step 3: Create the Swift package and generate**

`WatchtowerInterface/Package.swift` mirrors `WatchtowerChatText/Package.swift` with no dependencies and test target `WatchtowerInterfaceTests`. Run `make gen-interface`. The generated `GoldenRoundTripTests` has one test per golden file, `test<TypeName>RoundTrip`, which reads `internal/tower/api/testdata/<Type>.json` (path from `#filePath`), decodes it into the generated type, re-encodes with sorted keys, and asserts equality with the file's canonical form; plus `testUnknownEnumValueSurvives` using a sample enum value `"zz_future"`.

Run: `go test ./internal/tower/gen/ && make interface-test` — Expected: PASS.

- [ ] **Step 4: Wire make, CI and both apps**

`PublicAPISurfaceTests` gains `testInterfacePackageIsFoundationOnly` (reads `WatchtowerInterface/Package.swift`: no `.package(` entries; every source file imports only `Foundation`) and keeps `testNoCoreSourceImportsTheKit` unchanged. Run `make mobile-gen`.

Run: `make gen-interface-check` (Expected: exit 0), `make test-swift FILTER=PublicAPISurfaceTests`, `make mobile-build`, `make lint-swift`, `make lint-diff` — Expected: PASS / no new issues.

- [ ] **Step 5: Commit**

```bash
git add internal/tower WatchtowerInterface Makefile .github/workflows/ci.yml WatchtowerDesktop/Package.swift WatchtowerDesktop/Package.resolved WatchtowerDesktop/Tests/Core/PublicAPISurfaceTests.swift WatchtowerMobile CLAUDE.md docs/features/tower-interface.md
git commit -m "feat(tower): Swift generator and WatchtowerInterface package (#1170)"
```

### Task 3: Daemon socket, change watch and `sync.pause`/`sync.resume`

**Depends on:** Task 1

**Files:**
- Create: `internal/tower/socket.go` (`Serve`, `MaxFrame`), `internal/tower/watch.go` (`Changes`), `internal/tower/pause.go` (`PausePath`, `IsPaused`, `SetPaused`, the `sync.pause`/`sync.resume` commands)
- Modify: `internal/tower/api/tower.go` (`ChangedEvent`, `PauseRequest`/`PauseResponse`), `internal/tower/commands/commands.go`
- Modify: `internal/daemon/daemon.go` (`SetSyncPaused`; gate new sync cycles in `runLoop`, scheduled automation runs in `startAutomations`, the plan-usage poll in `startPlanUsage`), `cmd/sync.go` (`--no-sync` flag, forwarded by the detach path; `runSyncDaemon` builds the `Tower`, calls `Serve` on `filepath.Join(cfg.WorkspaceDir(), "tower.sock")`, passes `Paused`)
- Test: `internal/tower/socket_test.go`, `internal/tower/watch_test.go`, `internal/tower/pause_test.go`, `internal/daemon/pause_test.go`, `cmd/sync_test.go`
- Modify: `docs/features/tower-interface.md` (Socket, Change watch, Pause sections)

**Interfaces:**
- Consumes: `tower.Tower.Call`, `Spec.Watch`, `Spec.ChangeTables` (Task 1); `platform.PeerUID` (`internal/hub/platform`, the hub control socket's check).
- Produces:
  - `const SunPathMax = 103` (macOS `sun_path` is 104 bytes with the terminator); `func SocketPath(workspace string) (path string, fallback bool)` — `<workspace>/tower.sock` when its length ≤ `SunPathMax`, else `<os.TempDir()>/wt-<uid>/<first 12 hex of sha256(workspace path)>.sock`; `const SocketPathFile = "tower.sock.path"`
  - `func Serve(ctx context.Context, path string, t *Tower) (stop func(), err error)` — makes sure the socket's directory is 0700 (creates the fallback dir 0700; chmods a wider directory to 0700), binds `path` 0600 (replacing a stale socket); on a fallback path the daemon writes the path into `<workspace>/tower.sock.path` (0600, temp + rename) and removes it on stop; refuses a peer whose uid is not `os.Getuid()` (seam `var peerUID = func(net.Conn) (int, error)`), reads newline-delimited `api.Request` frames, answers `api.Response` frames with the same `id`; a `Watch` command answers `ok` once, then streams `api.ChangedEvent` frames until the client closes.
  - `const MaxFrame = 1 << 20`
  - `type ChangedEvent struct { ID string \`json:"id"\`; Event string \`json:"event"\` /* "changed" */; Tables []string \`json:"tables,omitempty"\` }`
  - `type Changes struct`; `func NewChanges(d *db.DB, poll time.Duration) *Changes`; `func (c *Changes) Publish(tables []string)`; `func (c *Changes) Subscribe(filter []string) (events <-chan api.ChangedEvent, cancel func())` — delivers an event whose tables meet `filter`, or that has none; `const PollInterval = 250 * time.Millisecond`; the poll goroutine runs only while subscribers > 0.
  - `func PausePath(workspace string) string` (`<workspace>/sync.paused`); `func IsPaused(workspace string) bool`; `func SetPaused(workspace string, paused bool) error` (write temp + rename; resume removes the file).
  - Commands `sync.pause` and `sync.resume` (guarded writes, `ChangeTables: nil`), each `{request_id}` → `PauseResponse{ Paused bool \`json:"paused"\` }`.
  - `func (d *Daemon) SetSyncPaused(paused func() bool)`; flag `watchtower sync --daemon --no-sync` (never stored).

- [ ] **Step 1: Write the failing socket tests** (bind under a short `os.MkdirTemp("/tmp", "tw")` dir: macOS limits `sun_path` to 104 bytes, as the hub's `shortDir` helper does)

- `TestSocket_IsPrivateAndChecksPeer` (same shape as `internal/hub/hub_test.go::TestControlSocketIsPrivateAndChecksPeer`): socket mode `0600` and its directory `0700` (a directory created 0755 is tightened); with `peerUID` returning another uid the connection is closed without an answer.
- `TestSocket_PingEndToEnd`: `tower.ping` over a real connection answers `ok`.
- `TestSocket_AnswersMatchIDsWhenInterleaved`: two requests on one connection, answers carry their ids.
- `TestSocket_GarbageLineAnswersUnsupported`, `TestSocket_OversizeFrameClosesOnlyThatConnection` (a frame past `MaxFrame` closes that connection; a second connection still pings).
- `TestSocket_StaleSocketFileIsReplaced`.
- `TestSocketPath_LongWorkspaceFallsBackAndWritesThePathFile`: a workspace whose `tower.sock` path exceeds 103 bytes binds at `<TempDir>/wt-<uid>/<12 hex>.sock` (dir 0700), `tower.sock.path` holds that path (mode 0600), and a client that reads it pings `ok`; a short workspace writes no path file.

- [ ] **Step 2: Write the failing watch tests** (`synctest.Test`; a second `db.Open` handle on the same file is the "other process")

- `TestWatch_OwnWriteEmitsAtCommit`: a `Ctx.Write` through `Call` delivers `changed` with the spec's tables before `Call` returns.
- `TestWatch_ForeignWriteWithinHalfSecond`: an insert on the second handle is delivered with no tables within 500 ms of bubble time (two poll intervals).
- `TestWatch_FilterKeepsOnlyMatchingOrUnlabelled`.
- `TestWatch_PollStopsWithTheLastWatch`: after the last `cancel`, advancing 10 s runs zero `data_version` reads (counted through a seam).
- `TestWatch_SocketStreamsEvents`: a `Watch` command over the socket receives the event frame.

- [ ] **Step 3: Write the failing pause tests**

- `TestPause_FileIsAtomicAndSurvivesARestart`: `sync.pause` creates `sync.paused`; a new `Tower` over the same workspace reports `HelloResponse.SyncPaused == true`; `sync.resume` removes it.
- `TestPause_ServesInboxWhilePaused`: with the file present, `tower.ping` and a registered test read keep answering `ok` across a `Tower` restart (the spec's "serves `inbox.feed` while paused" test; Task 6 adds `inbox.feed` to it).
- `internal/daemon/pause_test.go::TestDaemon_PausedStartsNoCycleAutomationOrPlanPoll` (`synctest`; with `SetSyncPaused(func() bool { return true })` a trigger and two poll intervals start no sync cycle, no scheduled automation slot and no plan-usage poll; a cycle already running finishes).
- `cmd/sync_test.go::TestSyncDetach_ForwardsNoSync`: the detached child's argv contains `--no-sync` when given.
- `TestHello_NoSyncIsReportedAndNeverStored`: with `Options.NoSync` the hello says `no_sync: true`, and no `sync.paused` file is written.

Run: `go test ./internal/tower/ ./internal/daemon/ -run 'Socket|Watch|Pause' && go test ./cmd/ -run TestSyncDetach_ForwardsNoSync` — Expected: FAIL.

- [ ] **Step 4: Implement** to the Interfaces above. `Options.Changed` (Task 1) is wired to `Changes.Publish`. The poll uses its own read-only handle and `PRAGMA data_version`, modelled on `internal/hub/slices/change.go`. `runSyncDaemon` composes `Paused` as `func() bool { return noSync || tower.IsPaused(ws) }` for the daemon and reports the two separately in `tower.hello`.

- [ ] **Step 5: Run the tests** — same command — Expected: PASS. Then `make lint-diff`.

- [ ] **Step 6: Commit**

```bash
git add internal/tower internal/daemon cmd/sync.go cmd/sync_test.go docs/features/tower-interface.md
git commit -m "feat(tower): daemon socket, change watch and sync pause (#1170)"
```

### Task 4: `TowerClient`, `TowerTransport`, `SocketTransport` and `TowerText`

**Depends on:** Task 2, Task 3

**Files:**
- Create: `WatchtowerInterface/Sources/WatchtowerInterface/Client/TowerTransport.swift`, `Client/TowerClient.swift`, `Client/TowerTiming.swift`, `Text/TowerText.swift`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Tower/SocketTransport.swift`
- Test: `WatchtowerInterface/Tests/WatchtowerInterfaceTests/TowerClientTests.swift`, `TowerTextTests.swift`, `Support/FakeTransport.swift`, `Support/ManualClock.swift`; `WatchtowerDesktop/Tests/Core/SocketTransportTests.swift`

**Interfaces:**
- Consumes: generated `Request`, `Response`, `HelloResponse`, `ChangedEvent`, `TowerCommand`, `InterfaceVersion.current`, `RawJSON` (Task 2); the socket protocol (Task 3).
- Produces (all `public`, in `WatchtowerInterface`):
  - `protocol TowerTransport: Sendable { func call(_ request: Request) async throws -> Response; func watch(_ request: Request) -> AsyncThrowingStream<ChangedEvent, Error> }` — `call` throws `TowerTransportError.down` when the tower is unreachable.
  - `enum TowerScreenState: Equatable, Sendable { case idle, loading, ready(stale: Date?), reconnecting, failed(TowerFailure) }`; `struct TowerFailure: Equatable, Sendable { enum Kind { case down, version, refused }; let kind: Kind; let sentence: String }` — `version` draws **Restart**, the others **Retry**.
  - `enum TowerActionState: Equatable, Sendable { case busy, refused(String), unknown }`
  - `enum TowerTiming { static let retryStart: Duration = .milliseconds(200); static let retryMax: Duration = .seconds(2); static let reconnectingLineAfter: Duration = .seconds(1); static let failAfter: Duration = .seconds(15) }`
  - `actor TowerClient { init(transport: any TowerTransport, clock: any Clock<Duration>, restartDaemon: (@Sendable () async -> Bool)?, startDaemon: (@Sendable () async -> Void)?) ; func retry() async /* after failed(.down) also calls startDaemon, then reconnects */; var screenState: TowerScreenState { get }; func screenStates() -> AsyncStream<TowerScreenState>; func showsReconnectingLine() -> Bool; func read<Resp: Decodable & Sendable>(_ command: TowerCommand, params: some Encodable & Sendable) async -> Result<Resp, TowerFailure>; func act<Resp: Decodable & Sendable>(_ command: TowerCommand, key: String, params: (String) -> some Encodable & Sendable) async -> TowerActOutcome<Resp>; func actionState(key: String) -> TowerActionState?; func watch(_ command: TowerCommand) -> AsyncStream<ChangedEvent> }`
  - `enum TowerActOutcome<Resp> { case ok(Resp), refused(String), unknown, failed(TowerFailure) }` — `key` identifies the press (a row's id plus verb); the client makes the `request_id` (UUID) for a new press of `key`, passes it to `params`, and keeps it until a final answer (`ok`, `refused`, `unknown`).
  - `enum TowerText` with: `reconnecting = "Reconnecting to Watchtower…"`, `daemonDown = "Watchtower's background service isn't running"`, `differentVersion = "Watchtower's background service is a different version."`, `retry = "Retry"`, `restart = "Restart"`, `didntConfirmMac = "Didn't confirm — checking again…"` (mockup §8), `didntConfirmPhone = "Didn't confirm — check on the Mac."` (mockup §6), `refresh = "Refresh"`, `syncPaused = "Sync paused"`, `pauseSync = "Pause Sync"`, `resumeSync = "Resume Sync"` (later tasks add the Inbox strings here).
- Produces (WatchtowerCore): `final class SocketTransport: TowerTransport` — `init(workspace: String)`: connects to the path in `<workspace>/tower.sock.path` when that file exists, else `<workspace>/tower.sock` (re-read on every reconnect, so a daemon that moved is found); one connection, newline JSON frames, answers matched by `id`; a closed socket fails every pending call with `.down`.

- [ ] **Step 1: Write the failing `TowerClientTests`** (FakeTransport scripts drops and answers; ManualClock advances virtual time)

- `testReadMovesLoadingThenReady`
- `testDropUnderOneSecondShowsNoLine` (1 s drop: state `reconnecting`, `showsReconnectingLine() == false` until 1 s, then the call succeeds — the spec's 1 s case)
- `testDropOfThreeSecondsShowsTheLineThenRecovers` (3 s drop: line shows after 1 s; on return the client re-opens the watch and reads once)
- `testNeverReturnsFailsAfterFifteenSecondsWithRetry` (`failed(.down, TowerText.daemonDown)`)
- `testRetryAfterDownAsksToStartDaemon` (after `failed(.down)`, `retry()` calls `startDaemon` exactly once, then retries the connection from the 0.2 s backoff)
- `testBackoffDoublesFromTwoHundredMillisecondsToTwoSeconds` (attempt times 0.2, 0.4, 0.8, 1.6, 2.0, 2.0 s)
- `testPressedActionWaitsBusyAndIsSentWithTheSameRequestIDOnReturn`
- `testRetryAfterFailureReusesTheRequestID` (Review Focus 3)
- `testUnknownNeverResendsAndRefreshes` (an `unknown` answer → `actionState == .unknown`, zero further `call`s for that key, one feed read)
- `testRefusalKeepsTheGoSentence`
- `testHelloMismatchRestartsTheDaemonWhenItCan` (restart closure called once, then ready)
- `testHelloMismatchWithoutRestartShowsDifferentVersion` (`failed(.version, TowerText.differentVersion)`)
- `TowerTextTests.testEveryStringIsPinned` (each constant equals the literal above)

Run: `make interface-test FILTER='TowerClientTests|TowerTextTests'` — Expected: FAIL.

- [ ] **Step 2: Implement** `TowerClient` and `TowerText`. Run the same command — Expected: PASS.

- [ ] **Step 3: SocketTransport** — `SocketTransportTests` run against an in-test Unix socket server (a short `/tmp` path; no Go process): `testFramesMatchTheGoGoldens` (the request frame it writes for `tower.ping` decodes as `internal/tower/api/testdata/Request.json`'s shape; the golden `Response.json` line is decoded and matched by `id`), `testInterleavedAnswersMatchByID`, `testServerCloseFailsPendingCallsWithDown`, `testWatchYieldsChangedFrames`, `testReadsTheFallbackPathFile` (a `tower.sock.path` naming a short `/tmp` socket is used instead of `<workspace>/tower.sock`). The end-to-end ping against the real daemon is Go's `TestSocket_PingEndToEnd` (Task 3). Implement `SocketTransport` beside `HubControlClient.swift`.

Run: `make test-swift FILTER=SocketTransportTests`, `make lint-swift` — Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add WatchtowerInterface WatchtowerDesktop/Sources/WatchtowerCore/Services/Tower WatchtowerDesktop/Tests/Core/SocketTransportTests.swift
git commit -m "feat(interface): TowerClient state machine and socket transport (#1170)"
```

### Task 5: Desktop daemon lifecycle — always on, `--no-sync`, tray Pause/Resume

**Depends on:** Task 3, Task 4

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/DaemonManager.swift` (`launchDetachedDaemon(path:noSync:…)`), `Sources/WatchtowerCore/Services/OnboardingFinishPlan.swift` (`DaemonControl.startDetached(noSync:)`, default `false`)
- Modify: `WatchtowerDesktop/Sources/App/AppState.swift` (launch: `ensureDaemonRunning(noSync: needsOnboarding)` after the compaction step for every launch, onboarding included; a `towerClient` over `SocketTransport` with `restartDaemon` and `startDaemon` both wired to the app's daemon start queue (`enqueueDaemonStart`, the queue `ensureDaemonRunning` uses); `syncPaused` read from `tower.hello`; `pauseSync()`/`resumeSync()`)
- Modify: `WatchtowerDesktop/Sources/Views/TrayMenuView.swift` (`TrayMenuContent` gains `syncPaused`, `pauseAction`, `resumeAction`; `statusText(isRunning:syncPaused:syncProgress:now:)`)
- Modify: `WatchtowerDesktop/Tests/DesignShots/DesignShotCatalog.swift` (`tray-menu-running`, `tray-menu-paused`)
- Test: `WatchtowerDesktop/Tests/Core/DaemonManagerStartTests.swift`, `WatchtowerDesktop/Tests/TrayMenuContentTests.swift`, `WatchtowerDesktop/Tests/DaemonLaunchSequenceTests.swift`
- Modify docs: `docs/features/tray-daemon-lifecycle.md` (the daemon is always on; a stop pauses sync; restarts that stay), `docs/guide/features/menu-bar-and-updates.md` (Pause Sync), `docs/features/onboarding-v2.md` (the paused daemon before finish)

**Interfaces:**
- Consumes: `TowerClient`, `TowerText.pauseSync/resumeSync/syncPaused` (Task 4); `sync.pause`/`sync.resume`, `HelloResponse.sync_paused` (Task 3).
- Produces: `AppState.towerClient: TowerClient` (the one client every Desktop screen uses); `AppState.syncPaused: Bool`; `func pauseSync() async`, `func resumeSync() async`.

- [ ] **Step 1: Write the failing tests**

- `DaemonManagerStartTests.testNoSyncStartPassesTheFlag` (argv `["sync", "--daemon", "--detach", "--no-sync"]`) and `testDefaultStartHasNoFlag`.
- `DaemonLaunchSequenceTests.testLaunchStartsADaemonWithNoSyncBeforeOnboardingFinishes` (fake `DaemonControl`: one `startDetached(noSync: true)` after the compaction step), `testOnboardingFinishRestartsWithoutNoSync`, `testLaunchAfterOnboardingStartsWithSync`.
- `TrayMenuContentTests.testStatusLineReadsSyncPausedWhilePaused` (`"Sync paused"`), `testPauseItemBecomesResumeWhilePaused` (labels `"Pause Sync"` / `"Resume Sync"` from `TowerText`), `testPauseCallsTheTowerCommand` (a fake transport receives `sync.pause` with a `request_id`), `DaemonLaunchSequenceTests.testTowerRetryAfterDownEnqueuesADaemonStart` (the client's `startDaemon` puts one start on the fake start queue, never a second while one is queued).

Run: `make test-swift FILTER='DaemonManagerStartTests|DaemonLaunchSequenceTests|TrayMenuContentTests'` — Expected: FAIL.

- [ ] **Step 2: Implement.** Every existing restart (account view models' `restartLoggingQueued`, `restartOnChain`, Slack disconnect, `stopWipeRestart`, `stopDaemonAndRemoveEverything`, `CLIBinaryStore`, quit, crash restart) stays as is; only the owner's stop control becomes Pause. Onboarding never writes or clears `sync.paused`.

- [ ] **Step 3: Run the tests** — same command — Expected: PASS.

- [ ] **Step 4: Shots** — add `tray-menu-running` and `tray-menu-paused` (mockup §8 "Tray menu, running — light" / "paused — dark"); run `make desktop-shots DESKTOP_SHOTS=<scratch dir>` and compare with mockup §8 by eye. Run `make test-swift FILTER=DesignShotsTests`, `make lint-swift`.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop docs/features/tray-daemon-lifecycle.md docs/features/onboarding-v2.md docs/guide/features/menu-bar-and-updates.md
git commit -m "feat(desktop): always-on daemon with tray Pause Sync (#1170)"
```

**Phase gate (stage 0, controller):** `make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`, `make mobile-build`.

---

## Stage 1 — the Inbox core and the Mac

### Task 6: `inboxfeed.Build` part 1 — folders, counts, cards, texts, limit

**Depends on:** Task 1, Task 2 (`commands.RegisterAll`, `make gen-interface`), Task 3 (`Spec.Watch` delivery and `pause_test.go`, which this task extends)

**Files:**
- Create: `internal/inboxfeed/build.go` (`Build`, `Options`), `folders.go`, `counts.go`, `cards.go`, `texts.go`, `limit.go` (`Limit`, `Clip`), `register.go` (`inbox.feed`, `inbox.watch`), `changetables.go`
- Create: `internal/tower/api/inbox.go` — **every** feed and act type (`ActRequest`, `ActParams`, `ActResult` and their enums, listed under Task 8), including the ones Tasks 7–8 fill, so Task 10 can build on them
- Create: `internal/inboxfeed/testdata/inbox_feed_cases.json`, `internal/inboxfeed/testdata/bench_fixture.go` (seeder for the benchmark size)
- Create: `internal/tower/api/testdata/Feed.json`, `FeedRequest.json`
- Modify: `internal/tower/commands/commands.go`; regenerate (`make gen-interface`)
- Test: `internal/inboxfeed/build_test.go`, `cases_test.go`, `bench_test.go`; `WatchtowerDesktop/Tests/Core/InboxFeedParityTests.swift`, `WatchtowerDesktop/Tests/Core/Support/SwiftFeedAdapter.swift` (test-only: maps today's Swift builders' output to the generated `Feed`)
- Create: `docs/features/inbox-core.md`; Modify: `CLAUDE.md`, `docs/features/README.md`

**Interfaces:**
- Consumes: `tower.Register`, `tower.Spec{Read, Watch, ChangeTables}` (Tasks 1, 3).
- Produces (`internal/tower/api/inbox.go`):
  - `type FeedRequest struct { Folder *int64 \`json:"folder,omitempty"\`; Limit int \`json:"limit,omitempty"\`; Clip bool \`json:"clip,omitempty"\` }` — no time zone: the feed is zone-free
  - `type Feed struct { V int \`json:"v"\`; BuiltAt string \`json:"built_at"\`; Folders []Folder \`json:"folders"\`; Cards []Card \`json:"cards"\`; More []FolderMore \`json:"more,omitempty"\` }`; `const FeedVersion = 1`
  - `type Folder struct { ID int64; Kind FolderKind /* root|approvals|owner */; Slug, Title, Icon string; ParentID *int64; Position, Count, Waiting int }` (JSON tags snake_case as in spec §4.2)
  - `type FolderMore struct { FolderID int64 \`json:"folder_id"\`; Count int \`json:"count"\` }`
  - `type Card struct { ID string; FolderID int64; CardKind CardKind /* artifact|approval_native|reminder|notice|legacy */; Title, SourceLine /* no time */, Preview, Stamp /* RFC 3339 UTC */ string; Living, Unread bool; Priority string; Pinned bool; Automation *CardAutomation; Blocks string; Body string; BodyClipped bool; ContentHash string; Actions []CardAction; RefFacts []RefFacts; Approval *Approval; Legacy *LegacySection }`
  - `type CardAutomation struct { ID int64; Name, BuiltinID string; RunID int64 }`
  - `type CardAction struct { Index int; Kind, Label string; State ActionState /* enabled|disabled|pressed|mac_only */ }`
  - `type RefFacts struct { Kind RefKind /* inbox_item|track|idea|reminder|action|plan_item */; ID int64; Open, Waits, Reply, ReplyWaiting bool; Link string }`
  - `type Approval struct { Tool, Title, Summary, ArgsSHA256, Status, Error, Proposer, Reason string; EditOnMac bool }`
  - `type LegacySection struct { Kind LegacyKind /* morning_brief|tracks|ideas|thread_briefs|messages */; Items []LegacyItem }`; `type LegacyItem struct { RefKind RefKind; ID int64; Title, Subtitle, Stamp string; Unread, Stopped bool; Date string }`
  - Card id helpers in `internal/inboxfeed`: `func OutputCardID(id int64) string` (`o<id>`), `ActionCardID` (`a`), `ReminderCardID` (`r`), `NoticeCardID` (`n<builtin migration id>`), `BriefCardID(date string)` (`brief-<date>`), and the constants `"tracks"`, `"ideas"`, `"thread-briefs"`, `"messages"`; `func ParseCardID(id string) (kind string, num int64, date string, err error)`.
- Produces (`internal/inboxfeed`):
  - `type Options struct { Folder *int64; Limit int; Clip bool; Now time.Time }`
  - `func Build(ctx context.Context, d *db.DB, o Options) (api.Feed, error)` — one `BeginTx(ReadOnly: true)`; writes nothing.
  - `var ChangeTables = []string{"automation_outputs", "automation_runs", "automations", "inbox_folders", "inbox_folder_state", "inbox_folder_routes", "inbox_items", "agent_actions", "reminders", "tracks", "track_events", "ideas", "briefings", "day_plans", "day_plan_items", "builtin_migrations"}`
  - `func Register(r *tower.Registry)` — `inbox.feed` (`Spec{Read: true, ChangeTables: ChangeTables}`) and `inbox.watch` (`Spec{Watch: true, ChangeTables: ChangeTables}`).
  - `const ClipBytes = 16 << 10`; `const MaxBlocksBytes = 128 << 10`

The Swift sources ported here (read each before writing its Go half): `WatchtowerCore/Services/Inbox/InboxFolderEntries.swift` (`build`, `row`), `InboxListBuilder.swift` (`sections`, `rootDays`), `InboxFolderCounts.swift` (`counts`, `legacyCounts`, `artifactCount`, `badge`), `InboxCardTexts.swift` (`sourceLine`, `stamped`, `updated`, `readingSourceLine`, `notice`), `InboxCardSubject.swift`, `InboxCardNotice.swift`, `SaveAutomationProposalSummary.swift`, the list/count part of `WatchtowerCore/Services/Actions/ActionStripViewModel.swift`, and the reads in `InboxFeedQueries.read` / `InboxFolderQueries`.

- [ ] **Step 1: Write the fixture and the failing Go tests**

`inbox_feed_cases.json`: `[{ "name", "now", "seed": [SQL...], "opts": FeedRequest, "expect": Feed }]`. Cases (Task 6 part): `empty_install` (root + approvals only, counts 0), `owner_folders_order_and_counts` (three levels, a hidden folder and its subtree out of the root count), `unread_artifact_counts_one`, `artifact_rows_waiting_count_per_ref`, `markdown_card_has_empty_blocks`, `living_card_stamp_updated`, `save_automation_proposal_summary`, `builtin_upgrade_notice_card`, `limit_keeps_approvals_and_waiting_first` (Limit 3 over 5 cards: the approval and the Waiting for me card kept, `more` counts the cut per folder, every folder still sent), `folder_option_narrows`.

`build_test.go`: `TestInboxFeedCases` (every case: `Build` equals `expect` with `built_at` blanked), `TestBuild_IsOneReadOnlySnapshot` (a concurrent writer between two reads inside `Build` is not seen: counts and rows agree), `TestBuild_WritesNothing` (`PRAGMA data_version` and `total_changes` unchanged), `TestBuild_StampsAreUTCAndSourceLineHasNoTime` (Review Focus 1: every `stamp` is RFC 3339 UTC, ending in `Z`; `source_line` carries the source only, the model appends the time), `TestClip_CutsOnARuneBoundary` (a body of 16 KB − 1 byte + "ё" → valid UTF-8, `body_clipped`), `TestBuild_OversizeBlocksBecomeANotice` (Review Focus 2), `TestCardIDs_RoundTripAndNeverCollide`.

Run: `go test ./internal/inboxfeed/` — Expected: FAIL.

- [ ] **Step 2: Implement `Build`, the texts and `Limit`/`Clip`** (port one Swift function at a time, making its cases pass).

- [ ] **Step 3: Register `inbox.feed`/`inbox.watch`, regenerate, add goldens** — `make gen-interface`; extend `internal/tower/pause_test.go::TestPause_ServesInboxWhilePaused` to call `inbox.feed`.

Run: `go test ./internal/inboxfeed/ ./internal/tower/... && make gen-interface-check` — Expected: PASS.

- [ ] **Step 4: Swift parity half** — `InboxFeedParityTests.testSwiftBuilderMatchesEveryGoCase` seeds each case's SQL into a `TestDatabase`, runs today's Swift builders under the case's `now` in UTC, maps them (the adapter strips the time part Swift puts in the source line and keeps sections out: grouping is the models' job, Task 10) through `SwiftFeedAdapter` and asserts equality with `expect`. A field the Swift side does not compute is listed in the adapter's `goOnlyFields` with a one-line reason, never silently skipped.

Run: `make test-swift FILTER=InboxFeedParityTests` — Expected: PASS.

- [ ] **Step 5: Benchmark** — `BenchmarkInboxFeedBuild` seeds 2 000 outputs, 200 approvals, 500 open items and 30 folders once (`b.ResetTimer` after seeding) and runs `Build` with no options. Run `go test ./internal/inboxfeed/ -run '^$' -bench BenchmarkInboxFeedBuild -benchtime 20x` and record the ns/op in the task report (the gate is checked over the socket in Task 11).

- [ ] **Step 6: Docs** — `docs/features/inbox-core.md`: the feed, card ids, options, what moved from Swift (spec §4.1 table), the parity fixture. CLAUDE.md line "Inbox core — `inbox-core.md`" and the README summary.

- [ ] **Step 7: Lint and commit** — `make lint-diff`, `make lint-swift`.

```bash
git add internal/inboxfeed internal/tower WatchtowerInterface WatchtowerDesktop/Tests/Core docs/features CLAUDE.md
git commit -m "feat(inboxfeed): feed builder with folders, counts, cards and texts (#1170)"
```

### Task 7: `inboxfeed` part 2 — Needs approval, ref facts, action states, legacy sections

**Depends on:** Task 6

**Files:**
- Create: `internal/db/approvals_all.go` (the all-automations reader), `internal/inboxfeed/approvals.go`, `reffacts.go`, `actions.go`, `legacy.go`
- Modify: `internal/inboxfeed/testdata/inbox_feed_cases.json`, `WatchtowerDesktop/Tests/Core/Support/SwiftFeedAdapter.swift`
- Test: `internal/db/approvals_all_test.go`, `internal/inboxfeed/approval01_test.go`, `approvals_test.go`, `reffacts_test.go`, `legacy_test.go`
- Modify: `docs/inventory/inbox-folders.md` (APPROVAL-01 gains the Go guards; the Swift guards stay listed until Task 11)

**Interfaces:**
- Consumes: `db.OpenApproval`, `db.ReadApprovalsView` (one automation), `db.OpenInboxItems` (`internal/db/inbox_open.go`), `api.Card.Approval`, `api.RefFacts`, `api.LegacySection` (Task 6).
- Produces:
  - `type NeedsApprovalView struct { Open []OpenApproval; Cards map[string]ApprovalCard; Builtin ApprovalBuiltinState; Settled []AgentAction }` — `Cards` keyed by `action:<id>`/`reminder:<id>` over every automation's living inbox artifacts; `Settled` the approved/executing rows drawn below, uncounted (APPROVAL-01 2026-11-10 amendment).
  - `type ApprovalCard struct { OutputID, AutomationID int64; WrittenAt string }`; `type ApprovalBuiltinState struct { FeatureOn, Stopped, LastRunOK bool }`
  - `func ReadNeedsApprovalTx(ctx context.Context, tx *sql.Tx, now time.Time) (NeedsApprovalView, error)` next to `ReadApprovalsView`, sharing `openApprovals`.
  - `inboxfeed` fills `Card.Approval`, `Card.RefFacts`, `Card.Actions[].State`, `Card.Legacy`, the approvals folder's `Count`/`Waiting` and every folder's `Waiting`.

Swift sources ported: `NeedsApprovalSelection.swift` (`pick`, `items`, the four conditions, the 50 cap), `InboxRefState.swift` (track and idea parts; `action` uses `AgentActionQueries.awaitingOwnerClause`'s rule, `inbox_item` uses `db.OpenInboxItems`), `InboxReplyPolicy.swift` (`tool(for:)`, `isOpenReply`), `InboxTargetButtonFacts.swift`, `InboxCardAction.swift` (button states), and the legacy lists of `InboxListBuilder.sections(_:list:…)` / `rootDays`.

- [ ] **Step 1: Write the failing guards and tests**

- `approval01_test.go` (APPROVAL-01, same meaning as the Swift guards): `TestApproval01_NativeCardWhenRecipeOff` (feature off → `card_kind == "approval_native"` for every open approval), `TestApproval01_NativeCardWhenBehind` (living card `written_at` before the approval's `ChangedAt` → native), `TestApproval01_ClosedNeverDrawn` (a closed approval's living card is in no folder and no count).
- `approvals_test.go`: `TestNeedsApproval_MoreThanFiftyFallsBackToNative`, `TestNeedsApproval_MixedOrderMatchesSwift`, `TestNeedsApproval_SettledRowsShownUncounted`, `TestNeedsApproval_ArgsSHAIsTheRegistryHash` (`Approval.ArgsSHA256 == tools.ArgsSHA256(args)`), `TestNeedsApproval_EditOnMacForEditableTools`.
- `reffacts_test.go`: `TestRefFacts_InboxItemOpenAndWaits`, `TestRefFacts_TrackDoneIsClosed`, `TestRefFacts_IdeaSnoozedIsClosedUntilDue`, `TestRefFacts_ReplyWaitingWhenAProposalIsOpen`, `TestRefFacts_ClosedRowsStayInTheDocument`.
- `legacy_test.go`: `TestLegacy_MorningBriefPerDateUnderTheUnreadRule`, `TestLegacy_TracksCardFlagsStopped`, `TestLegacy_IdeaFinderAndThreadBriefsAndMessages`.
- `internal/db/approvals_all_test.go::TestReadNeedsApprovalTx_SpansEveryAutomation`.
- New fixture cases in `inbox_feed_cases.json` for each of the above, run by both `TestInboxFeedCases` and `InboxFeedParityTests`.

Run: `go test ./internal/inboxfeed/ ./internal/db/ -run 'Approval|NeedsApproval|RefFacts|Legacy|InboxFeedCases'` — Expected: FAIL.

- [ ] **Step 2: Implement** to the Interfaces above.

- [ ] **Step 3: Run Go and Swift parity** — the Go command above, then `make test-swift FILTER=InboxFeedParityTests` — Expected: PASS.

- [ ] **Step 4: Inventory** — in `docs/inventory/inbox-folders.md` add the three Go guards under APPROVAL-01 with a dated changelog line ("Go guards added beside the Swift ones; same meaning; no guard relaxed").

- [ ] **Step 5: Lint and commit** — `make lint-diff`, `make lint-swift`.

```bash
git add internal/db internal/inboxfeed WatchtowerDesktop/Tests/Core docs/inventory/inbox-folders.md
git commit -m "feat(inboxfeed): Needs approval, ref facts, action states and legacy sections (#1170)"
```

### Task 8: Go writers and `inbox.act`

**Depends on:** Task 7

**Files:**
- Create: `internal/db/inbox_writes.go` (the Tx writers below), `internal/inboxfeed/act.go` (`inbox.act` dispatch), `internal/inboxfeed/act_approval.go`, `internal/inboxfeed/sentences.go`
- Modify: existing non-Tx wrappers to call the new Tx writers (one implementation): `internal/db/tracks.go` (`MarkTrackRead`, `DismissTrack`, `RestoreTrack`), `internal/db/reminders.go`, `internal/db/inbox.go` (`ResolveInboxItem`, `DismissInboxItem`, `SnoozeInboxItem`), `internal/db/briefings.go`, `internal/db/dayplans.go`
- Modify: `internal/tools/registry.go` (`ErrArgsChanged`, returned by `ApproveSeen` wrapped together with `ErrBadTransition`)
- Create: `internal/inboxfeed/testdata/inbox_writes.json`
- Test: `internal/inboxfeed/act_test.go`, `writes_cases_test.go`, `race_test.go`, `fault_test.go`; `internal/tools/registry_test.go`; `WatchtowerDesktop/Tests/Core/InboxWritesFixtureTests.swift`
- Modify docs: `docs/features/inbox-core.md` (Writes), `docs/features/inbox-card-blocks.md` and `docs/features/inbox-folders.md` (the builder and writers are in Go)

**Interfaces:**
- Consumes: `tower.Ctx.Write`, `Spec.IdempotentFor`, `Spec.GrantFor` (Task 1); `ParseCardID` (Task 6); `db.PressInboxOutputAction` + `ErrOutputChanged` (`internal/db/automation_outputs_press.go`), `db.InsertInboxReplyProposal` + `*ErrReplyAlreadyWaiting` (`internal/db/agent_actions_reply.go`), `tools.Registry.ApproveSeen/Reject/Apply` and `DismissSessionCall`, `builtin.Fire` (`internal/automations/builtin/approvals.go`), the `automation_run` function behind `handlers.applyAutomationRun`.
- Consumes (types defined in Task 6's `internal/tower/api/inbox.go`):
  - `type ActRequest struct { WriteParams; Target string \`json:"target"\`; Verb ActVerb \`json:"verb"\`; Params ActParams \`json:"params"\` }`; `type ActVerb string` = `read|done|dismiss|press|run_now|ref|reply_propose|approval`
  - `type ActParams struct { ContentHash string; Index *int; Text string; RefKind RefKind; RefID int64; RefVerb RefVerb; Until string; ApprovalVerb ApprovalVerb; ArgsSHA256 string; Patch RawJSON }` (all `omitempty`)
  - `type RefVerb string` = `resolve|dismiss|snooze|done|stop|restore|make_task|approve|reject|not_now|check|uncheck`; `type ApprovalVerb string` = `approve|reject|retry|dismiss`
  - `type ActResult struct { Already bool \`json:"already,omitempty"\`; Status string \`json:"status,omitempty"\` /* applying|applied|failed */; Error string \`json:"error,omitempty"\`; RunID int64 \`json:"run_id,omitempty"\` }`
- Produces (`internal/db`, each one short write in the caller's tx, guard kept from its Swift twin):
  - `MarkOutputReadTx(tx, id int64, contentHash string, now time.Time) (bool, error)`, `MarkOutputDoneTx`, `DismissOutputTx` (open rows only, hash-guarded; port of `AutomationQueries.markOutputOpened/markOutputDone/dismissOutput/stampOnce`)
  - `MarkBriefingReadTx(tx, ids []int) error`, `MarkInboxItemReadTx(tx, id int) error`, `ResolveInboxItemTx(tx, id int, reason string) error`, `DismissInboxItemTx`, `SnoozeInboxItemTx(tx, id int, until string) error`
  - `MarkTrackDoneTx(tx, id int) error` (track read + its events' `read_at`: `TrackQueries.markRead` + `TrackEventQueries.markAllRead`), `StopTrackTx(tx, ids []int) error`, `RestoreTrackTx(tx, id int) error`
  - `SetIdeaVerdictTx(tx, id int, status string) error`, `SnoozeIdeaTx(tx, id int, until *string) error`
  - `MarkReminderDoneTx(tx, id int64) (bool, error)`, `SnoozeReminderTx(tx, id int64, until string) (bool, error)`
  - `SetPlanItemStatusTx(tx, itemID int64, status string, cascadeToTask bool) error` (with `DayPlanQueries.cascadeTaskStatus`'s cascade: a `task`-sourced item sets its `targets.status`, as `TargetQueries.updateStatus` does)
- Produces (`internal/inboxfeed`): `func RegisterAct(r *tower.Registry, deps ActDeps)`; `type ActDeps struct { Registry *tools.Registry; RunNow func(ctx context.Context, automationID int64) (int64, error); Wake func(); Background func(func()) /* hub: run apply off the call */; Clock func() time.Time }`; `const ApproveWaitCap = 120 * time.Second`; `func ActIdempotent(params json.RawMessage) (bool, error)` (false for `approval` approve/retry, `run_now`, and `press` on a `reply` action); `func ActGrant(params json.RawMessage) (string, error)` (`permissions` for approve/retry, `typing` for `reply_propose` and a `reply` press with text, `""` otherwise).

Verb table (spec §4.3) — the dispatch writes exactly these; refusal mapping: `ErrOutputChanged`/hash mismatch → `changed`; `*ErrReplyAlreadyWaiting` → `reply_waiting`; `tools.ErrArgsChanged` → `args_changed`; missing row → `not_found`; `patch` from `Origin.Transport == "hub"` → `not_permitted`; a target/verb pair outside the table → `unsupported`. `ref` on a `reminder` runs `builtin.Fire(d, "reminder:<id>", wake)` after commit (the Swift `ReminderApprovalHook`). `ref make_task` on a track takes the `apply_track_action` propose path as `TrackActionPress` does. `press` with a `target` action takes the `create_target` propose path (`cmd/actions_propose.go::proposeInboxAction`). `approval approve|retry`: the decision commits in one short transaction (`ApproveSeen` with `args_sha256`, or `Apply` for retry), then the tool runs outside any transaction — over the socket the call waits up to `ApproveWaitCap` (on expiry `ok` with `status: "applying"`), over the hub `Background` runs it and the call answers after the decision. Sentences: `"Couldn't <verb phrase>: <reason>"` from `sentences.go`, e.g. `"Couldn't mark it done: this card changed — look again."`; the verb phrases are a table pinned by `TestSentences_EveryVerbHasAPhrase`, and `TestSentences_MockupSentences` pins the four mockup sentences ("Couldn't snooze: the item was already closed on the Mac.", "This proposal changed on the Mac — look again before approving." for `args_changed`, "Couldn't mark it done: the database is busy.", "Couldn't approve it: this idea changed — look again.").

- [ ] **Step 1: Write the shared fixture and the failing tests**

`inbox_writes.json`: `[{ "name", "seed": [SQL], "now", "call": ActRequest, "swift": {"writer": "<Swift function>", "args": {...}} | null, "expect": { "status", "code"?, "already"?, "rows": { "<table>": [ {col: value} ] } } }]` — one case per verb × target kind in the table, one stale-hash case for every hash-guarded verb (`read`, `done`, `dismiss`, `press`), one `already` case per guarded verb, the track-done read cascade, the reminder snooze approval hook (row write only; the fire is asserted in Go), the plan-item cascade.

- `writes_cases_test.go::TestInboxWritesCases` runs every case through `tower.Call("inbox.act")`.
- `act_test.go`: `TestInboxAct_ApprovalArgsChangedIsRefused` (`args_changed`, row stays `pending`), `TestInboxAct_ApproveOverSocketWaitsForTheTool` (`synctest`; tool fake finishes at 5 s → `status: "applied"`), `TestInboxAct_ApproveWaitIsCappedAt120s` (`status: "applying"`), `TestInboxAct_ApproveOverHubAnswersAfterTheDecision`, `TestInboxAct_NoWriteTxHeldAcrossTheTool` (a second writer commits while the fake tool runs), `TestInboxAct_PatchFromTheHubIsNotPermitted`, `TestInboxAct_ReplyPressQueuesTheRun`, `TestInboxAct_RunNowIsNonIdempotent`, `TestActIdempotentAndGrantTables` (every verb's idempotency and grant).
- `race_test.go::TestInboxAct_TwoConnectionsRace/<verb>`: two `db.Open` handles on one file call the same verb on the same row concurrently; exactly one answers `ok` without `already`, the other `already` or `changed`.
- `fault_test.go`: `TestWriters_FaultSeamRollsBack/<writer>` (a seam `var faultAfter func(step string) error` between statements returns an error; the row set equals the seed) for every writer, and `TestWriters_KillBetweenStatements_TrackDone`, `_ReminderHook`, `_PlanItemCascade`.
- `internal/tools/registry_test.go::TestApproveSeen_ArgsChangedIsBothErrors` (`errors.Is` for `ErrArgsChanged` and `ErrBadTransition`).

Run: `go test ./internal/inboxfeed/ ./internal/db/ ./internal/tools/ -run 'InboxAct|InboxWrites|Writers|ApproveSeen|Sentences'` — Expected: FAIL.

- [ ] **Step 2: Implement the Tx writers** (port each Swift query; keep the non-Tx wrappers as one-line calls into them) — run `go test ./internal/db/` — Expected: PASS.

- [ ] **Step 3: Implement `inbox.act`** and register it in `commands.RegisterAll` with `Spec{ChangeTables: inboxfeed.ChangeTables, IdempotentFor: ActIdempotent, GrantFor: ActGrant}`; regenerate (`make gen-interface`) and add `ActRequest.json`/`ActResult.json` goldens.

Run: the Step 1 command and `make gen-interface-check` — Expected: PASS.

- [ ] **Step 4: Swift half of the fixture** — `InboxWritesFixtureTests.testSwiftWritersMatchEveryGoCase` runs each case with a `swift` entry through the named Swift writer (`AutomationQueries.markOutputDone`, `TrackQueries.markRead`, …) and compares `expect.rows`. Run `make test-swift FILTER=InboxWritesFixtureTests` — Expected: PASS.

- [ ] **Step 5: Lint and commit** — `make lint-diff`, `make lint-swift`.

```bash
git add internal/db internal/inboxfeed internal/tools internal/tower WatchtowerInterface WatchtowerDesktop/Tests/Core/InboxWritesFixtureTests.swift docs/features
git commit -m "feat(inboxfeed): Go writers and inbox.act (#1170)"
```

### Task 9: Write commands for the other screens

**Depends on:** Task 8

**Files:**
- Create: `internal/inboxfeed/screens.go` (registrations), `internal/tower/api/screens.go` (request/response types)
- Create: `internal/db/screen_writes.go` (writers that have no Go twin yet), `internal/db/target_owner_writes.go` (`SetTargetStatusOwnerTx`, `SetTargetColumnOwnerTx`, `SnoozeTargetOwnerTx`, each `(tx *sql.Tx, …) (rolledUp []int64, err error)`), `internal/inboxfeed/testdata/screen_writes.json`
- Test: `internal/db/proj_owner_writes_test.go`
- Modify: `docs/inventory/workbench.md` (PROJ-05, PROJ-06, PROJ-19: the Go owner-write guards added beside today's; changelog line, none relaxed)
- Modify: `internal/tower/commands/commands.go`; regenerate
- Test: `internal/inboxfeed/screens_test.go`, `WatchtowerDesktop/Tests/Core/ScreenWritesFixtureTests.swift`

**Interfaces:**
- Consumes: the Task 8 Tx writers and `tower.Ctx.Write`.
- Produces — one guarded command per Swift writer call site found by the grep in Step 1 (every request embeds `WriteParams`; the response is `ActResult` unless noted). The list from today's tree (re-run the grep; the Task 12 guard test proves completeness):

| Command | Params | Go writer (port of) | Swift call sites |
|---|---|---|---|
| `outputs.read` / `outputs.done` / `outputs.dismiss` | `id, content_hash` | `MarkOutputReadTx` / `MarkOutputDoneTx` / `DismissOutputTx` | `ActionStripViewModel`, `HomeFeedActions` |
| `reminders.done` / `reminders.snooze` | `id`, `until` | `MarkReminderDoneTx` / `SnoozeReminderTx` + `builtin.Fire` | `ActionStripViewModel`, `HomeFeedActions`, `Models/Reminder.swift` |
| `briefing.read` | `ids` | `MarkBriefingReadTx` | `ActionStripViewModel` |
| `inbox_items.read` | `id` | `MarkInboxItemReadTx` | `ActionStripViewModel` |
| `tracks.read` | `ids` | `MarkTrackRead` (Tx form, port of `TrackQueries.markRead(ids:)`) | `TracksViewModel` |
| `tracks.done` | `id` | `MarkTrackDoneTx` (read + events) | `ActionStripViewModel` |
| `tracks.stop` / `tracks.restore` | `ids` / `id` | `StopTrackTx` / `RestoreTrackTx` | `ActionStripViewModel`, `TracksViewModel`, `CustomTrackControlling`, `RecipeCustomTrackControls` |
| `tracks.priority` / `tracks.ownership` / `tracks.sub_items` | `id, priority` / `id, ownership` / `id, sub_items` | new (`TrackQueries.updatePriority/updateOwnership/updateSubItems`) | `TracksViewModel` |
| `tracks.enabled` / `tracks.instruction` / `tracks.delete` | `id, enabled` / `id, instruction` / `id` | new (`TrackQueries.setEnabled/updateInstruction/delete`) | `TargetWatchesViewModel`, `CustomTrackControlling` |
| `tracks.event_status` / `tracks.events_read` | `event_id, status` / `track_id` | new (`TrackEventQueries.setActionStatus/markRead/markAllRead`) | `CustomTrackTimelineViewModel`, `TargetWatchesViewModel`, `ActionStripViewModel` |
| `ideas.status` / `ideas.snooze` / `ideas.merge` / `ideas.supersede` / `ideas.rating` | per `IdeaQueries` signature | `SetIdeaVerdictTx` / `SnoozeIdeaTx` / new | `IdeasViewModel`, `DigestViewModel` (reached from `IdeaDetailPane`, `DecisionsListView`) |
| `ideas.create` → `{id}` / `ideas.delete` / `ideas.converted` | `kind, title, essence` / `id` / `id, target_id` | `CreateManualIdea` (Tx form) / new (`IdeaQueries.delete`, incl. its idea-chat cleanup) / new | `IdeasViewModel`, `QuickCaptureView` |
| `ideas.decision_seen` / `ideas.decisions_seen_all` | `id` / none | new (`IdeaQueries.markDecisionSeen/markAllDecisionsSeen`) | `DigestViewModel` |
| `ideas.create_from_chat` → `{id}` / `ideas.undo_chat` → `{undone}` | `conversation_id, message_id, kind, body` / `id, created_updated_at` | `CreateIdeaFromChat` (Tx form) / new | `ChatKnowledgeCenter` |
| `dayplan.done` / `dayplan.pending` / `dayplan.delete` / `dayplan.reorder` / `dayplan.add` → `{id}` | `item_id, cascade` / … / `plan_id, ordered_ids` / `addManualItem`'s fields | `SetPlanItemStatusTx` / `DeleteDayPlanItem` (Tx form) / new | `DayPlanViewModel` |
| `targets.set_status` → `TargetStatusResult` | `id, status` | `SetTargetStatusOwnerTx` — port of `WorkbenchQueries.updateTargetStatus` over `TargetQueries.updateStatus(_:id:status:)` | `WorkbenchBoardViewModel` (via `WorkbenchOwnerWrites.setStatus`), `TargetsViewModel.updateStatus` (reached from `TargetsListView`, `TargetDetailView`, `TargetActionExecutor`), `HomeFeedActions` |
| `targets.set_column` → `TargetStatusResult` | `id, status, column_id?` | `SetTargetColumnOwnerTx` — port of `WorkbenchQueries.updateTargetColumn` over `TargetQueries.updateStatus(_:id:status:boardColumnID:)`: status and column in one `UPDATE` | `WorkbenchBoardViewModel` (via `WorkbenchOwnerWrites.moveToColumn`) |
| `targets.snooze` → `TargetStatusResult` | `id, until` | new (both `TargetQueries` snooze writers that set `status = 'snoozed'`) | `TargetsViewModel` |

The three target commands keep today's contract exactly:
- **PROJ-06** (`docs/inventory/workbench.md`): every write claims `status_actor = 'owner'` in the same statement, so the `targets_status_history_{ai,au}` triggers record one history row with actor `owner`; application code writes no history row.
- **PROJ-05**: the rollup stays the migration-00085 triggers. The Go writer reads the ancestor statuses before and after the write in the same transaction (the Swift `rolledUpAncestors`) and returns them: `type TargetStatusResult struct { RolledUp []int64 \`json:"rolled_up"\` /* ancestors whose status the rollup moved, sorted */ }`. The Desktop reports `[id] + rolled_up` to `onOwnerWrite` exactly as `WorkbenchOwnerWrite.touched` does today, so the owner's own move (and the parents it moved) never notifies.
- **PROJ-19**: `targets.set_column` writes status and column in one statement; a move between two columns of one status writes no history and keeps progress; a column that does not match is refused by the trigger and answers `refused` (`unsupported`, the trigger's sentence).
- `afterStatusWrite` moves with it: `requireUpdated` (a missing row → `not_found`), `applyStatusProgress`, and INBOX-02's cascade (closing a target resolves its pending `target_due` inbox items), which Go's `UpdateTargetStatus` already does.
| `catchup.acknowledge` | `CatchUpQueries.acknowledge`'s inputs | new (one transaction over its six tables) | `CatchUpViewModel` |
| `digests.read` / `digests.decision_read` / `digests.decisions_read_all` | `ids` / `digest_id, idx` / `digest_id` | `MarkDigestRead` (Tx form) / new | `DigestViewModel` |

`catchup.*`, `digests.*` and `targets.*` follow the owner's rule in ask #1362 ("the Inbox moves, and so does every screen that writes the same rows"), though spec §2.1's list does not name them: `CatchUpQueries.acknowledge` writes `tracks`, `inbox_items` and `briefings` (moved tables) in one transaction with `digests`, `stream_digests` and `catchup_recaps`, so it moves whole, and `digests.read_at` then needs one writer. `ideas.create_from_chat`/`ideas.undo_chat` stay in stage 1 for the same reason: they write the moved `ideas` table. `targets.set_status`/`targets.snooze` move because the plan-item cascade writes `targets.status` from Go, so its other Swift writers move with it.

- [ ] **Step 1: Re-run the call-site grep** and reconcile it with the table (add a row for anything new; the grep pattern is the moved writers' names, run over `WatchtowerDesktop/Sources` excluding `WatchtowerCore/Database/Queries`).

- [ ] **Step 2: Write the fixture and failing tests** — `screen_writes.json` (same shape as `inbox_writes.json`, one case per command plus an `already` case where a guard exists) run by `TestScreenWritesCases` and by `ScreenWritesFixtureTests.testSwiftWritersMatchEveryGoCase`; `TestScreenCommands_EveryCommandIsRegisteredGuarded` (each name in the table is registered with `Idempotent: true` and non-empty `ChangeTables`); `screen_writes.json` cases `targets_set_status`, `targets_set_status_rolls_up_two_ancestors` (the response's `rolled_up` and the `target_status_history` rows with actor `owner` for the target and `system` for the rolled-up parents), `targets_set_column`, `targets_set_column_same_status_no_history`, `targets_snooze`, `targets_done_resolves_target_due` (INBOX-02); Go guards in `internal/db/proj_owner_writes_test.go`: `TestProj05_OwnerStatusCommandReturnsTheRolledUpAncestors`, `TestProj05_DismissedAncestorStopsTheRollupAndIsNotReturned`, `TestProj06_OwnerStatusCommandRecordsActorOwner`, `TestProj06_SnoozeRecordsActorOwner`, and the four PROJ-19 Swift guards of `WorkbenchBoardColumnWritesTests` moved with the same names and assertions: `TestProj19_MoveToColumnWritesStatusAndColumnOnce`, `TestProj19_MoveBetweenColumnsOfOneStatusWritesNoHistory`, `TestProj19_MoveWithinOneStatusKeepsProgress`, `TestProj19_MismatchedColumnIsRefusedByTheTrigger`; `TestTargetsSetStatus_TwoConnectionsRace` (two `db.Open` handles set different statuses on one target concurrently: both answer `ok`, the row holds exactly one of the two with its matching `afterStatusWrite` effects, never a mix).

Run: `go test ./internal/inboxfeed/ ./internal/db/ -run 'ScreenWrites|ScreenCommands|TargetsSetStatus|Proj05_Owner|Proj05_Dismissed|Proj06_|Proj19_Move|Proj19_Mismatched'` — Expected: FAIL.

- [ ] **Step 3: Implement** the new writers and registrations; regenerate; add goldens.

- [ ] **Step 4: Run** the Go command, `make gen-interface-check`, `make test-swift FILTER=ScreenWritesFixtureTests` — Expected: PASS. `make lint-diff`.

- [ ] **Step 5: Commit**

```bash
git add internal/db internal/inboxfeed internal/tower WatchtowerInterface WatchtowerDesktop/Tests/Core/ScreenWritesFixtureTests.swift
git commit -m "feat(tower): write commands for Home, Ideas, Tracks, Day plan, CatchUp and Digests (#1170)"
```

### Task 10: Screen models in `WatchtowerInterface`

**Depends on:** Task 2, Task 4 (`TowerText.swift`, which this task extends), Task 6 (the generated feed and act types)

**Files:**
- Create: `WatchtowerInterface/Sources/WatchtowerInterface/Inbox/Platform.swift`, `InboxRootModel.swift`, `InboxFolderModel.swift`, `InboxCardModel.swift`, `InboxRefRowModel.swift`, `InboxApprovalModel.swift`, `InboxTabState.swift`, `InboxHiddenRows.swift`
- Modify: `WatchtowerInterface/Sources/WatchtowerInterface/Text/TowerText.swift`
- Test: `WatchtowerInterface/Tests/WatchtowerInterfaceTests/Inbox/InboxRootModelTests.swift`, `InboxFolderModelTests.swift`, `InboxCardModelTests.swift`, `InboxRefRowModelTests.swift`, `InboxApprovalModelTests.swift`, `InboxTabStateTests.swift`, `InboxHiddenRowsTests.swift`, `TowerTextInboxTests.swift`

**Interfaces:**
- Consumes: generated `Feed`, `Folder`, `Card`, `RefFacts`, `Approval`, `LegacySection`, `ActRequest`, `ActParams`, `RefVerb` (all defined in Task 6). The models hold no client state; action states are drawn by the views from `TowerClient` (Task 4).
- Produces (`public`):
  - `enum Platform: Sendable { case mac, phone }`; `struct Grants: Sendable, Equatable { var permissions: Bool; var typing: Bool; static let all }`
  - `struct InboxRootModel { init(feed: Feed, platform: Platform); let rows: [InboxFolderRow]; let badge: Int /* sum of folders' waiting */ }`; `struct InboxFolderRow { let folder: Folder; let depth: Int /* 0...2 */; let count: Int; let waiting: Int; let children: [InboxFolderRow] }`
  - `struct InboxFolderModel { init(feed: Feed, folderID: Int64, platform: Platform, hidden: InboxHiddenRows, now: Date, timeZone: TimeZone = .current); let sections: [InboxSection] /* Needs your decision / Today / Earlier by the given zone */; let cards: [InboxCardModel]; let olderLine: String?; let empty: (title: String, body: String)? }`
  - `struct InboxCardModel { init(card: Card, platform: Platform, grants: Grants, blocksReadable: Bool, now: Date, timeZone: TimeZone = .current); let id: String; let title, sourceLine /* source + " · " + the time formatted in timeZone */, preview, stamp: String; let unsupportedBanner: String? /* set when !blocksReadable */; let showsUnreadDot: Bool; let actions: [InboxCardActionModel]; let refRows: [InboxRefRowModel] /* open refs only */ }`; `struct InboxCardActionModel { let index: Int; let label: String; let enabled: Bool; let note: String? /* TowerText.onYourMac for mac-only on the phone */ }`
  - `struct InboxRefRowModel { init(facts: RefFacts, platform: Platform, grants: Grants); let leadingSwipe: [RefVerb]; let trailingSwipe: [RefVerb]; let menu: [RefVerb]; func request(_ verb: RefVerb, cardID: String, requestID: String, until: String?) -> ActRequest }` — swipe right Hide, swipe left Done and Snooze; a track gets Done and Stop, a reminder Done and "Snooze 1h"; the menu holds every verb of the kind, Make a Task included.
  - `struct InboxApprovalModel { init(card: Card, platform: Platform, grants: Grants); let canApprove: Bool; let approveNote: String?; let canEdit: Bool; func approve(requestID: String) -> ActRequest /* pins args_sha256 */ }`
  - `enum InboxTabState: Equatable { case loading(hub: String), empty(hub: String), tooOld(hub: String), policyOff, ready, macAway(hub: String, asOf: Date) }` with `static func resolve(capability: String?, fetched: Bool, feed: Feed?, hubName: String, macAway: Date?) -> InboxTabState` (`capability == nil` → `tooOld`; `"policy_off"` → `policyOff`)
  - `struct InboxHiddenRows { mutating func hideOnOK(_ key: String); mutating func observe(feed: Feed); func isHidden(_ key: String) -> Bool }` — a row hidden on `ok` stays hidden until a feed leaves it out (then forgotten) or until two feeds still contain it (then shown again).
  - `TowerText` additions: `loadingInbox(hub:) = "Getting your Inbox from \(hub)…"`, `emptyTitle = "Nothing waits for you"`, `emptyBody(hub:) = "New cards arrive after the next sync on \(hub)."`, `emptyFolderTitle(_:) = "No cards in \(folder)"`, `emptyFolderBody = "Automations routed here write their cards into this folder. Routes are set on your Mac."`, `tooOldTitle(hub:) = "Update Watchtower on \(hub)"`, `tooOldBody(hub:) = "Watchtower on \(hub) is too old to send its Inbox to the phone."`, `policyTitle = "The Inbox stays on your Mac"`, `policyBody = "Your organization lets this phone see only Workbench."`, `olderCards(_ n: Int) = "\(n) older cards are on your Mac."`, `onYourMac = "On your Mac"`, `propose = "Propose"`, `snoozeOneHour = "Snooze 1h"`, `makeATask = "Make a Task"`, `loadingInboxMac = "Loading the Inbox…"` (Mac first load, mockup §7), `refreshFailed(reason: String, shownAt: Date, timeZone: TimeZone) -> String` = `"Couldn't refresh the Inbox: \(reason). Showing the list from \(time)."` with `time` formatted by the model (`h:mm` in the given zone, e.g. "9:14"; a different day adds the short date), `unsupportedCard = "This card needs a newer Watchtower on this iPhone. Showing its text."` (mockup §4), and every other UI string the mockups show:
    - §1: `inThisFolder = "In this folder"`, `waitingSubtitle(_ n: Int, updated: Date, now: Date) = "\(n) waiting · updated \(ago)"` ("4 waiting · updated 6 min ago"), `updatedAgo(_:now:) = "Updated \(ago)"`, `living = "living"`, `runLine(run: Int, at:now:) = "ϟ run #\(run) · \(time)"`, `legacyBriefTitle = "Morning brief · today"`, `withNews(_ n:) = "\(n) with news"`, `toJudge(_ n:) = "\(n) to judge"`.
    - §2: `done = "Done"`, `snooze = "Snooze"`, `hide = "Hide"`, `reply = "Reply…"`, `snoozeMenu = "Snooze ▸"` with `snoozeOneDay = "1 day"`, `snoozeThreeDays = "3 days"`, `snoozeOneWeek = "1 week"`, `snoozePicker = "Snooze ▾"`, `openIn(_ app: String) = "Open in \(app)"` and the detail's `"Open in \(app) ↗"`, `markingDone = "Marking done…"`, `snoozing = "Snoozing…"`, `hiding = "Hiding…"`, `ageBadge(hours:) = "\(h) h"`, `whyItMatters = "Why it matters"`, `thread = "Thread"`, `cancel = "Cancel"`, `replyIn(_ place: String) = "Reply in \(place)"`, `replyNote = "The reply goes to Needs approval. Nothing is sent until you approve it there, on this phone or on the Mac."`.
    - §3: `approve = "Approve"`, `reject = "Reject"`, `dismiss = "Dismiss"`, `approving = "Approving…"`, `rejecting = "Rejecting…"`, `recipeOff(hub:) = "Showing approvals in the standard card — Needs approval is off on \(hub)."`, `editOnYourMac = "Edit on your Mac"`, `openDraftOnYourMac = "Open Draft — on your Mac"`, `failedPrefix(_ error:) = "Failed: \(error)"`, `reminderLine(at:) = "Reminder · \(time)"`, `assistantProposal(at:) = "Assistant proposal · \(time)"`, `replyFromWaiting(device:at:) = "Reply from Waiting for me · \(device) · \(time)"` ("this iPhone" on the phone).
    - §4: `chatOnYourMac = "Chat — on your Mac"`, `scrolls = "scrolls ›"`, `runNow = "Run Now"`, `runningNow = "Running…"`, `macOnlyMenuNote = "Edit, Move to Folder, Turn Off and Delete are on your Mac"`.
    - §5: `stopped(_ n:) = "Stopped · \(n)"`, `show = "Show"`, `toJudgeHeader(_ n:) = "To judge · \(n)"`, `notNow = "Not now"`, `recent = "Recent"`, `trackHint = "Swipe: Done · Stop watching · long press: Make a Task"`. The headings inside the hub's legacy block documents ("Plan · 2 of 6", "Attention") are Go strings in `inboxlegacy`, pinned by its tests (Task 13).
    - §6: the outbox lines ("Waiting to send · N", "Not delivered · N", "Discard", "<hub> · asleep", "as of …") already exist in the phone's outbox/relay models and are reused unchanged.
    - §8: "Synced 2 min ago", "Open Watchtower", "Sync Now", "Quit Watchtower" are the tray's existing strings.
    - Refusal sentences in the mockups ("Couldn't snooze: the item was already closed on the Mac.", "This proposal changed on the Mac — look again before approving.", "Couldn't mark it done: the database is busy.", "Couldn't approve it: this idea changed — look again.") are Go sentences (Task 8 `sentences.go`, pinned there by `TestSentences_MockupSentences`).
    - Sample data, not strings: people and handles ("Colleague A", "partner@example.com"), channels, message and card texts, folder names and icons ("Release acme 2.0", "Blockers", "Team", "QA"), automation and card titles, block contents, counts, times and the hub name "Acme Mac".

- [ ] **Step 1: Write the failing tests** (feeds built from `internal/tower/api/testdata/Feed.json` and small literals)

- `InboxRootModelTests`: `testBadgeIsTheSumOfWaiting`, `testFoldersOrderedByPosition`, `testFoldersPastThreeLevelsRollUpIntoTheThirdLevel` (Review Focus 5).
- `InboxFolderModelTests`: `testTodayEarlierFollowsTheClientZone` (a card at 23:30 UTC is Today in `Asia/Tokyo` and Earlier in `America/Los_Angeles` for the same `now`; Review Focus 1), `testClosedRefRowsAreHidden`, `testOlderLineWhenMoreIsPositive` (`"42 older cards are on your Mac."`), `testEmptyFolderCopy`, `testApprovalsAndWaitingFirst`.
- `InboxCardModelTests`: `testMacOnlyActionsAreDisabledOnThePhoneWithOnYourMac` (`chat`, `agent`, `save_automation`, Discuss, Hand to Agent), `testMacKeepsThemEnabled`, `testUnreadIsADotOnly`.
- `InboxRefRowModelTests`: `testSwipesPerKind` (inbox_item, track, reminder, idea, plan_item), `testMenuHoldsEveryVerbIncludingMakeATask`, `testRequestCarriesRefKindIDAndVerb`.
- `InboxApprovalModelTests`: `testApproveNeedsPermissionsOnThePhone`, `testApprovePinsTheShownArgsHash`, `testEditIsMacOnly`.
- `InboxTabStateTests`: one test per state (`loading`, `empty`, `tooOld` on a missing key, `policyOff`, `macAway`).
- `InboxHiddenRowsTests`: `testHiddenUntilAFeedLeavesItOut`, `testShownAgainAfterTwoFeedsStillContainIt`.
- `TowerTextInboxTests.testEveryInboxStringIsPinned`, `testRefreshFailedFormatsTheTimeInTheGivenZone` (reason `TowerText.daemonDown`, 09:14 in `Europe/Berlin` → `"Couldn't refresh the Inbox: Watchtower's background service isn't running. Showing the list from 9:14."`), `testUnsupportedBannerOnlyWhenBlocksAreUnreadable` (`InboxCardModel`), `testEveryMockupStringIsPinned` (each §1–§5 constant above equals its literal; the formatted ones checked with a fixed `now` and zone: "4 waiting · updated 6 min ago", "ϟ run #12 · 2 h ago", "26 h", "Reminder · 14:00"), `testBusyLabelsPerVerb` (done → "Marking done…", approve → "Approving…", snooze → "Snoozing…", hide → "Hiding…", reject → "Rejecting…", run_now → "Running…").

Run: `make interface-test FILTER='Inbox|TowerTextInbox'` — Expected: FAIL.

- [ ] **Step 2: Implement** — Expected: PASS on the same command; `make lint-swift`.

- [ ] **Step 3: Commit**

```bash
git add WatchtowerInterface
git commit -m "feat(interface): shared Inbox screen models and copy (#1170)"
```

### Task 11: Desktop Inbox on the tower

**Depends on:** Task 4, Task 5 (`AppState.towerClient`), Task 8, Task 10

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Inbox/InboxFeedLoader.swift` (one read in flight + a dirty flag)
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Actions/ActionStripViewModel.swift` (reads the feed through `InboxFeedLoader`; the badge from `InboxRootModel.badge`; actions through `inbox.act`), `Sources/Views/Inbox/*` and `Sources/Views/Inbox/Folders/*` (bind to the models; the mockup §7 states), `Sources/WatchtowerCore/Services/Inbox/InboxFolderMenuModel.swift`, `InboxFolderListContent.swift`, `NeedsApprovalNoteModel.swift`, `InboxArtifactMenuModel.swift`, `InboxCardPress.swift`, `WatchTrackControls.swift`, `RecipeCustomTrackControls.swift` (consume the generated `Card`)
- Delete: `Sources/WatchtowerCore/Services/Inbox/InboxFolderEntries.swift`, `InboxListBuilder.swift`, `InboxFolderCounts.swift`, `NeedsApprovalSelection.swift`, `InboxCardSubject.swift`, `InboxCardNotice.swift`, `SaveAutomationProposalSummary.swift`, `InboxRefState.swift` (track and idea parts; keep nothing else that decides a rule), `InboxReplyPolicy.swift`, `InboxTargetButtonFacts.swift`, the button-state part of `InboxCardAction.swift`; their Core tests (`InboxFolderEntriesTests`, `InboxListBuilderTests`, `InboxFolderCountsTests`, `NeedsApprovalSelectionTests`, `InboxRefState*Tests`, `InboxTargetButtonFactsTests`, `InboxCardSubjectTests`, `Approval01Tests`, the Swift half of `InboxFeedParityTests` → keep the Go golden only)
- Keep (Swift remainder, Mac-only): `InboxCardTexts.preview` (used by `ChatPanelRow`), `InboxCardTexts.targetTitleLimit` (used by `WorkbenchNewTargetSheet`) and the Mac handoff texts (`discussMessage`, `handToAgentTask`, `agentActionTask`, `agentActionHelp`, `attachmentMarkdown`, `targetTitle`, used by `InboxRefHooks`, `InboxCardButtons`, `InboxCardPress`, `InboxCommonRow`, `InboxDayPane`, `AppState+Inbox`), re-typed over the generated `Card`
- Create: `internal/tower/commands/socket_bench_test.go` (`BenchmarkSocketRoundTrip_InboxFeed`, `BenchmarkSocketRoundTrip_Write`)
- Modify: `WatchtowerDesktop/Tests/DesignShots/DesignShotCatalog.swift` (`inbox-feed-first-load`, `inbox-feed-failed-load`, `inbox-feed-failed-action`, `inbox-feed-reconnecting`, `inbox-feed-different-version`)
- Modify: `docs/inventory/inbox-folders.md` (APPROVAL-01 and FOLDER-01 re-pointed to Go), `docs/inventory/reaction-commands.md` (STRIP-01/02 entries that name a deleted Swift type), `docs/features/inbox-folders.md`, `docs/features/inbox-card-blocks.md`, `docs/guide/features/inbox.md` (only if a visible behaviour changed: the new states)
- Test: `WatchtowerDesktop/Tests/Core/InboxFeedLoaderTests.swift`, `WatchtowerDesktop/Tests/ActionStripFeedTests.swift`

**Interfaces:**
- Consumes: `AppState.towerClient` (Task 5), `inbox.feed`/`inbox.watch`/`inbox.act` (Tasks 6–8), the screen models (Task 10).
- Produces: `final class InboxFeedLoader { init(client: TowerClient, request: @escaping () -> FeedRequest); func open() /* starts the watch and reads */; func close() /* closes the watch */; func navigate(to folder: Int64?); var feed: Feed? { get }; var state: TowerScreenState { get } }` — reads on open, on each `changed` and on navigation; a change during a read sets dirty, so at most one read runs, with one more after it. The watch is open only while an Inbox window is on screen (closed on hide and when the app goes to the tray).

- [ ] **Step 1: Before-shots** — on the base commit run `make desktop-shots DESKTOP_SHOTS=<scratch>/before` and keep the `inbox-*` PNGs.

- [ ] **Step 2: Write the failing tests**

- `InboxFeedLoaderTests`: `testReadsOnOpenChangedAndNavigation`, `testAChangeDuringAReadQueuesExactlyOneMore`, `testWatchClosesWhenTheWindowHides`, `testFailedReadKeepsTheLastFeed`.
- `ActionStripFeedTests`: `testBadgeIsTheRootModelBadge`, `testDoneSendsInboxActWithTheContentHash`, `testFailedActionKeepsTheRowWithTheSentenceAndRetry`, `testReconnectingLineAboveTheLastList`.
- Go: `BenchmarkSocketRoundTrip_InboxFeed` (the Task 6 fixture size, `inbox.feed` over a real socket), `BenchmarkSocketRoundTrip_Write` (`inbox.act read` over the socket).

Run: `make test-swift FILTER='InboxFeedLoaderTests|ActionStripFeedTests'` — Expected: FAIL.

- [ ] **Step 3: Implement the switch**, then delete the Swift builders and their tests listed above. `ActionStripViewModel` keeps STRIP-02's rule: `refresh()` writes nothing.

- [ ] **Step 4: Gates**

Run: `go test ./internal/tower/commands/ -run '^$' -bench SocketRoundTrip -benchtime 50x -count 5` — Expected: median `inbox.feed` ≤ 100 ms and write ≤ 15 ms (record both in the task report; over budget → `--folder` reads or a counts-only mode first, never a cache table; the switch does not land while over).
Run: `make test-swift FILTER='InboxFeedLoaderTests|ActionStripFeedTests|ActionStrip|Inbox|DesignShotsTests'`, `make lint-swift`.

- [ ] **Step 5: Shots** — add the five `inbox-feed-*` shots (mockup §7), run `make desktop-shots DESKTOP_SHOTS=<scratch>/after`; the existing `inbox-*` shots must match the before-shots, and the `inbox-feed-*` shots must match mockup §7.

- [ ] **Step 6: Inventory** — APPROVAL-01's guards become the Go `TestApproval01_*` (Task 7); the Swift `Approval01Tests` is deleted in this PR with a dated changelog line ("guards moved to Go with the same names and meaning; none relaxed"). Every other entry naming a deleted Swift type is re-pointed to its Go code the same way.

- [ ] **Step 7: Commit**

```bash
git add -A WatchtowerDesktop internal/tower/commands docs
git commit -m "feat(desktop): Inbox reads and acts through the tower (#1170)"
```

### Task 12: Other screens write through the tower

**Depends on:** Task 9, Task 11

**Files:**
- Modify (callers → `towerClient.act`): `WatchtowerDesktop/Sources/ViewModels/IdeasViewModel.swift`, `DigestViewModel.swift`, `TracksViewModel.swift`, `DayPlanViewModel.swift`, `CatchUpViewModel.swift`, `TargetWatchesViewModel.swift`, `CustomTrackTimelineViewModel.swift`; `Sources/App/AppState+Home.swift`, `Sources/Services/HomeFeedActions.swift`; `Sources/Views/QuickCapture/QuickCaptureView.swift`, `Sources/Views/Ideas/IdeaDetailPane.swift`, `Sources/Views/Digests/DecisionsListView.swift`; `Sources/WatchtowerCore/Services/Actions/ActionStripViewModel.swift`, `Sources/WatchtowerCore/Models/Reminder.swift`, `Sources/WatchtowerCore/Services/Inbox/CustomTrackControlling.swift`, `RecipeCustomTrackControls.swift`, `Sources/Services/ChatKnowledgeCenter.swift`, `Sources/ViewModels/TargetsViewModel.swift` (`updateStatus`, `snooze` — reached from `TargetsListView`, `TargetDetailView` and `TargetActionExecutor`), `Sources/ViewModels/WorkbenchBoardViewModel.swift` (`setStatus`/`moveToColumn` → `targets.set_status`/`targets.set_column`; `onOwnerWrite` gets `[id] + rolled_up` from the result), `Sources/WatchtowerCore/Services/WorkbenchOwnerWrites.swift` (`setStatus`/`moveToColumn` removed; `WorkbenchOwnerWrite` stays and is built from `TargetStatusResult`; `setPriority`/`addComment`/`reply` unchanged), `Sources/WatchtowerCore/Database/Queries/WorkbenchQueries.swift` (`updateTargetStatus`/`updateTargetColumn`/`rolledUpAncestors` deleted) (and every other `targets.status` writer the grep finds)
- Create: `WatchtowerDesktop/Sources/DesignKit/TowerRowState.swift` (the shared row treatment: busy label, refused sentence + Retry, "Didn't confirm — checking again…")
- Delete: the moved Swift writers in `WatchtowerCore/Database/Queries/` (`AutomationQueries.markOutputOpened/markOutputDone/dismissOutput/stampOnce`, `TrackQueries` writers, `TrackEventQueries` writers, `DayPlanQueries` writers, `ReminderQueries.markDone/snooze`, `InboxQueries.markRead`, `BriefingQueries.markRead`, `IdeaQueries` writers, `CatchUpQueries.acknowledge`, `DigestQueries.mark*`, `TargetQueries.updateStatus` (both overloads) and the snooze writers) and the Swift halves of `InboxWritesFixtureTests`/`ScreenWritesFixtureTests` (the JSON stays as the Go golden)
- Create: `WatchtowerDesktop/Tests/Core/MovedTablesWriteGuardTests.swift`
- Modify: `WatchtowerDesktop/Tests/DesignShots/DesignShotCatalog.swift` (`ideas-row-states`, mockup §8 "Ideas: busy, refused, didn't confirm")
- Modify: `docs/inventory/reaction-commands.md` (STRIP-02 writer guards such as `testDoneWritesOnlyDoneAt`, `testDismissWritesOnlyDismissedAt`, `testOutputWritesTouchOnlyTheirOwnColumn`, `testMarkReminderDoneDropsItOnNextRefresh`, `testSnoozeReminderMovesItOutOfTheDueWindow` move to Go as `TestStrip02_DoneWritesOnlyDoneAt` etc. in `internal/inboxfeed/strip02_test.go`, same full-row assertions), any other inventory entry naming a deleted writer (grep `docs/inventory` for each deleted name)
- Test: one refusal test per screen (`IdeasViewModelTowerTests`, `DigestViewModelTowerTests`, `TracksViewModelTowerTests`, `DayPlanViewModelTowerTests`, `HomeActionsTowerTests`, `CatchUpViewModelTowerTests`, `QuickCaptureTowerTests`, `TargetsViewModelTowerTests`), `internal/inboxfeed/strip02_test.go`, and the target call paths:
  - `WorkbenchBoardViewModelTests.testStatusWriteReportsTheParentsTheRollupMoved` (PROJ-05 guard) keeps its name and assertion; its transport answers with the `rolled_up` of the Go fixture case `targets_set_status_rolls_up_two_ancestors`, so the reported owner writes equal exactly what Go returns. New beside it: `testColumnMoveReportsTheParentsTheRollupMoved`, `testOwnerMoveRaisesNoDoneNotice` (no notification for the target or a rolled-up parent).
  - `TargetsViewModelTowerTests.testUpdateStatusSendsSetStatusAndReportsRolledUp`, `testSnoozeSendsTargetsSnooze`.
  - `TargetActionExecutorTowerTests.testDoneGoesThroughSetStatus` (the executor's `updateStatus` path; refusal leaves the target as it was).
  - `TargetsListViewStatusTests.testStatusMenuSendsSetStatus`, `TargetDetailViewStatusTests.testStatusPickerSendsSetStatus` (the view → view-model → command path).
  - The history actor is asserted on the Go side (`TestProj06_OwnerStatusCommandRecordsActorOwner`) and in the fixture rows; `WorkbenchStatusRollupTests.testGRDBChildStatusUpdateRollsTheChainUp` stays (a test-only GRDB write proving the triggers on the Swift test schema).
  - Inventory: `docs/inventory/workbench.md` PROJ-05/06/19 — `WorkbenchBoardColumnWritesTests`' four guards are re-pointed to their Go names (Task 9) and the Swift file deleted with the writers; dated changelog line, none relaxed.

**Interfaces:**
- Consumes: the Task 9 commands; `TowerClient.act`, `TowerActionState` (Task 4); `TowerText.didntConfirmMac` (Task 4).
- Produces: `struct TowerRowState: View { init(state: TowerActionState?, busyLabel: String, retry: @escaping () -> Void) }`; the guard test's table list `MovedTablesWriteGuardTests.movedTables = ["automation_outputs", "briefings", "inbox_items", "tracks", "track_events", "ideas", "reminders", "day_plan_items", "digests", "decision_reads", "stream_digests", "catchup_recaps"]` and the column list `movedColumns = ["targets.status"]` (an `UPDATE targets` whose `SET` names `status` fails; other `targets` columns stay Swift-written).

- [ ] **Step 1: Write the failing guard** — `MovedTablesWriteGuardTests.testNoSwiftWriteToAMovedTable` scans every `.swift` file under `WatchtowerDesktop/Sources` for `INSERT INTO <t>`, `UPDATE <t>`, `DELETE FROM <t>`, `INSERT OR … INTO <t>` (case-insensitive, across line breaks) and GRDB record writes on the moved tables' record types (`.insert(db`, `.update(db`, `.save(db`, `.delete(db`, `updateAll`, `deleteAll` on `Idea`, `Track`, `Reminder`, `DayPlanItem`, `InboxItem`, `Briefing`, `AutomationOutput`, `Digest`), and fails listing file:line. `testTheMatcherCatchesEveryForm` pins the matcher on literals.

Run: `make test-swift FILTER=MovedTablesWriteGuardTests` — Expected: FAIL (lists today's writers).

- [ ] **Step 2: Per-screen refusal tests** — each `<Screen>TowerTests.testRefusalShowsTheSentenceAndRetry` (fake transport refuses with a sentence; the row shows it, Retry re-sends the same `request_id`) and `testRefreshesAfterOK` where the screen refreshed after its GRDB write. Add `TargetsViewModelTowerTests` to the list. Run `make test-swift FILTER='TowerTests'` — Expected: FAIL.

- [ ] **Step 3: Switch every caller**; reads stay on GRDB. Delete the moved writers and the Swift halves of the fixtures. Move the STRIP-02 writer guards to Go with their assertions.

- [ ] **Step 4: Run** `make test-swift FILTER='MovedTablesWriteGuardTests|TowerTests|ActionStrip|Ideas|Digest|Tracks|DayPlan|CatchUp|Home|QuickCapture|WorkbenchBoardViewModelTests|WorkbenchStatusRollupTests|TargetsListViewStatusTests|TargetDetailViewStatusTests'`, `go test ./internal/inboxfeed/`, `make lint-swift`, `make lint-diff` — Expected: PASS.

- [ ] **Step 5: Shot** — `ideas-row-states` vs mockup §8; `make test-swift FILTER=DesignShotsTests`.

- [ ] **Step 6: Commit**

```bash
git add -A WatchtowerDesktop internal/inboxfeed docs/inventory
git commit -m "feat(desktop): Home, Ideas, Tracks, Targets, Day plan, CatchUp and Digests write through the tower (#1170)"
```

**Phase gate (stage 1, controller):** `make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`, the Task 11 socket benchmarks, `make desktop-shots` before/after comparison.

---

## Stage 2 — the phone

### Task 13: Hub — Inbox slices, capability and `inbox_act`

**Depends on:** Task 3 (the daemon's `Tower` and socket wiring in `runSyncDaemon` that `startGoHub` now receives), Task 7, Task 8

**Files:**
- Modify: `internal/hub/slices/kinds.go` (`KindInboxFolder = "inbox_folder"`, `KindInboxCard = "inbox_card"` appended to `AllKinds`), `internal/hub/secure/record.go` (`dataKinds`), `WatchtowerKit/Sources/WatchtowerSync/Sync/SliceRecord.swift` (`SliceKind.inboxFolder`, `.inboxCard`) — one change
- Create: `internal/hub/slices/sources/inbox.go` (`InboxSource`), `internal/hub/slices/sources/inboxlegacy/project.go` (legacy section → block document)
- Modify: `internal/hub/slices/sources/registry.go` (`Config.InboxFeed`, the source in `All`, `ChangeTables` entries for every `inboxfeed.ChangeTables` table → both kinds)
- Modify: `internal/automations/blocks/blocks.go` (`RefPlanItem = "plan_item"`), `internal/automations/blocks/actions.go` (`Options.PlanItemRefs bool`, hub-only), `validate.go`
- Modify: `internal/hub/wire/payloads.go` (`HeartbeatCapabilities.Inbox`, `.InboxReason`; `InboxOn = "on"`, `InboxPolicyOff = "policy_off"`, reason `"policy"`), `internal/hub/slices/heartbeat.go`; Kit `WatchtowerKit/Sources/WatchtowerSync/Relay/HeartbeatPayload.swift` (`inbox`, `inboxReason`)
- Modify: `internal/hub/actions/dispatcher.go` (`KindOptions.NonIdempotentFor func(params json.RawMessage) bool`), `internal/hub/actions/handlers/inbox.go` (new), `handlers/deps.go` (register `inbox_act`; `Deps.Tower *tower.Tower`), `handlers/nudge.go` (`"inbox_act": {inbox_card, inbox_folder}`); Kit `ActionRequestPayload.swift` (`ActionKind.inboxAct = "inbox_act"`)
- Modify: `cmd/sync.go` (`startGoHub` receives the daemon's `*tower.Tower`; `inboxfeed.RegisterAct` gets `Background` from the hub)
- Modify: `WatchtowerKit/Tests/Fixtures/link/hub_contract_cases.json` (nudge rows for `inbox_act`; new section `inbox_act_idempotency`: `[{ "verb", "approval_verb"?, "action_kind"?, "idempotent", "grant" }]`)
- Test: `internal/hub/slices/sources/inbox_test.go`, `internal/hub/slices/sources/inboxlegacy/project_test.go`, `internal/hub/slices/heartbeat_capabilities_test.go`, `internal/hub/actions/handlers/inbox_test.go`, `handlers/nudge_fixture_test.go`, `internal/hub/actions/replay_inbox_test.go`, `internal/automations/blocks/blocks_test.go`, Kit `SliceKindTests`, `HubContractFixtureTests`
- Modify docs: `docs/features/go-hub.md` (the kinds, capability, `inbox_act`), protocol spec `docs/superpowers/specs/2026-10-31-hub-phone-protocol-design.md` §6.2, §7.2, §9 tables

**Interfaces:**
- Consumes: `inboxfeed.Build`, `Options{Limit: 300, Clip: true}`, `ChangeTables`, `ActIdempotent`, `ActGrant`, `RegisterAct` (Tasks 6–8); `tower.Tower.Call` with `Origin{Transport: "hub", Device: …}`; `blocks.Validate`.
- Produces:
  - `sources.Config.InboxFeed func(ctx context.Context, o inboxfeed.Options) (api.Feed, error)`; records `inbox_folder-<id>` (the `api.Folder` JSON) and `inbox_card-<id>` (the `api.Card` JSON; a legacy card's `blocks` from `inboxlegacy.Project`). The feed is built outside any write transaction; a failed build keeps the last records and logs its error class.
  - `func inboxlegacy.Project(s api.LegacySection) (blocksJSON string, err error)` — Morning brief, Track my threads and Idea finder as mockup §5; Thread briefs as a list of rows with `track` refs; Messages as a notice card with its Mac text and "On your Mac"; plan items with `plan_item` refs; validated with `blocks.Options{BuiltIn: true, PlanItemRefs: true}`.
  - Heartbeat `capabilities.inbox`: `"on"`, or `"policy_off"` with `inbox_reason: "policy"` under `workbench_only`; absent on an older hub.
  - Action kind `inbox_act`: params = the generated `ActRequest` JSON; the handler checks `ActGrant` against the device (`permissions` → `device.PermissionsAllowed`, `typing` → the typing grant, sentences through `h.withServerAllowStep`), then calls `tower.Call("inbox.act", …)` and maps `refused` → a failed outcome with the tower's sentence, `unknown` → `outcome_unknown`; nudges `inbox_card` and `inbox_folder`. Dispatcher idempotency comes from `NonIdempotentFor: func(p) bool { ok, _ := inboxfeed.ActIdempotent(actParams(p)); return !ok }`.

- [ ] **Step 1: Write the failing tests**

- `inbox_test.go` (sources): `TestInboxSource_RecordsMatchTheGoGolden` (over `inbox_feed_cases.json`: one record per visible folder and per card), `TestInboxSource_LimitAndClipOnThePhone`, `TestInboxSource_FailedBuildKeepsTheLastRecords`, `TestInboxSource_PolicyWorkbenchOnlyPublishesNoInboxKinds` (POLICY-03: the records are deleted), `TestInboxSource_EveryRecordUnder900KB`.
- `project_test.go`: one test per legacy kind; `TestProject_PlanItemNeedsTheHubOption` (`blocks.Validate` without `PlanItemRefs` refuses it).
- `heartbeat_capabilities_test.go::TestHeartbeatCarriesTheInboxCapability` (on; `policy_off` + `policy`).
- `handlers/inbox_test.go`: `TestInboxAct_PerVerb/<verb>` (each verb reaches the writer once), `TestInboxAct_ApproveNeedsPermissions`, `TestInboxAct_ApproveWithStaleArgsIsArgsChanged`, `TestInboxAct_ReplyNeedsTyping`, `TestInboxAct_OtherVerbsNeedNoGrant`, `TestInboxAct_PatchIsRefusedFromThePhone`, `TestInboxAct_HubStopMidApproveAnswersUnknown` (hub order test shape: `begun` left → `outcome_unknown`, never re-run), `TestInboxAct_NudgesInboxKinds`.
- `TestInboxActIdempotencyMatchesTheContract` (Go table == `hub_contract_cases.json` `inbox_act_idempotency`), `nudge_fixture_test.go` extended.
- `replay_inbox_test.go::TestReplay_InboxActRunsOnceAcrossAMacRestart` (`relay_processed` + `tower_requests`: a replayed envelope after a restart returns the stored result).
- Kit: `SliceKindTests.testAllCasesMatchGo` extended; `HubContractFixtureTests.testInboxActIdempotency`; `HeartbeatPayloadTests.testInboxCapabilityDecodes` (missing key → nil).

Run: `go test ./internal/hub/... ./internal/automations/blocks/` and `make kit-test FILTER='SliceKindTests|HubContractFixtureTests|HeartbeatPayloadTests'` — Expected: FAIL.

- [ ] **Step 2: Implement** to the Interfaces above.

- [ ] **Step 3: Run** the same commands — Expected: PASS. `make lint-diff`, `make lint-swift`.

- [ ] **Step 4: Docs** — `go-hub.md`, protocol spec tables.

- [ ] **Step 5: Commit**

```bash
git add internal/hub internal/automations/blocks cmd/sync.go WatchtowerKit docs
git commit -m "feat(hub): Inbox slices, capability and inbox_act (#1170)"
```

### Task 14: Phone artifact renderer

**Depends on:** none (the Kit's `ArtifactDocument` in `WatchtowerDesign` exists and the phone links `WatchtowerDesign`; this task adds the `plan_item` ref kind the legacy projection needs)

**Files:**
- Modify: `WatchtowerKit/Sources/WatchtowerDesign/ArtifactBlocks.swift` (`ArtifactRefKind.planItem = "plan_item"`), `WatchtowerKit/Tests/Fixtures/artifact_samples.json` (one sample with a `plan_item` ref), `WatchtowerKit/Tests/WatchtowerDesignTests/ArtifactBlocksTests.swift`
- Create: `WatchtowerMobile/Sources/DesignSystem/Artifacts/PhoneArtifactView.swift`, `PhoneArtifactBlocks.swift` (one view per block kind), `PhoneArtifactLayout.swift` (pure: document → ordered draw items)
- Modify: `WatchtowerMobile/Sources/DesignSystem/PhoneTone.swift` (`static func artifact(_ tone: ArtifactTone) -> PhoneTone`)
- Test: `WatchtowerMobile/Tests/PhoneArtifactViewTests.swift`

**Interfaces:**
- Consumes: Kit `ArtifactDocument`, `ArtifactBlock`, `ArtifactTone`, `ArtifactRef`, `ArtifactAction`.
- Produces: `struct PhoneArtifactView: View { init(document: ArtifactDocument, onRef: @escaping (ArtifactRef) -> Void, onAction: @escaping (Int) -> Void) }` — draws heading and text, metrics, lists, tables (sideways scroll inside a card), people as initials, links, actions; colours only through `PhoneTone.artifact(_:)`. `enum PhoneArtifactLayout { static func items(_ doc: ArtifactDocument) -> [PhoneArtifactItem] }`.

- [ ] **Step 1: Failing tests** — Kit `ArtifactBlocksTests.testPlanItemRefDecodes`; `PhoneArtifactViewTests.testEverySampleRendersInLightAndDark` (each `artifact_samples.json` sample through `ImageRenderer` at 393 pt width in both schemes: non-nil image, non-zero height), `testLayoutKeepsDocumentOrder` (texts of `PhoneArtifactLayout.items` equal the Kit's flattened order), `testEveryToneMapsThroughPhoneTone`, `testTableScrollsSideways` (a wide table's layout item is `.table(scrolls: true)`).

Run: `make kit-test FILTER=ArtifactBlocksTests` and `make mobile-test MOBILE_FILTER=PhoneArtifactViewTests` — Expected: FAIL.

- [ ] **Step 2: Implement**; run the same — Expected: PASS. `make lint-swift`.

- [ ] **Step 3: Commit**

```bash
git add WatchtowerKit WatchtowerMobile
git commit -m "feat(mobile): phone artifact renderer over the Kit block document (#1170)"
```

### Task 15: Phone Inbox tab

**Depends on:** Task 4 (`TowerClient`, which `HubTransport` serves), Task 10, Task 13, Task 14

**Files:**
- Modify: `WatchtowerMobile/project.yml` only if new folders need listing; `make mobile-gen`
- Create: `WatchtowerMobile/Sources/Features/Inbox/HubTransport.swift`, `InboxTabView.swift`, `InboxFolderView.swift`, `InboxCardDetailView.swift`, `InboxRefRow.swift`, `InboxApprovalCard.swift`, `InboxReplySheet.swift`, `InboxCenter.swift` (the tab's `TowerClient` over `HubTransport`)
- Modify: `WatchtowerMobile/Sources/App/RootTabView.swift` (`Tab.inbox`, second: `now, inbox, workbench, chats, calendar`; icon `tray`; orange badge = `InboxRootModel.badge`), `Sources/App/AppRoot.swift` (wiring), `Sources/App/DemoSeed.swift` + new `DemoSeed+Inbox.swift` (the sample Inbox: root, Needs approval with 2, Waiting for me with 3, an owner folder, an artifact with every block kind, the legacy entries)
- Modify: `WatchtowerMobile/Tests/ScreenshotTourTests.swift` (`testTheInboxShots`: every frame of mockup §§1–6 has one named shot, rendered light and dark — see the table below)
- Test: `WatchtowerMobile/Tests/HubTransportTests.swift`, `InboxTabWiringTests.swift`, `InboxOutboxWiringTests.swift`
- Modify docs: `docs/features/mobile-companion.md` (Inbox section), `docs/guide/features/iphone.md` (the Inbox tab; stays within the guide's page cap — `go test ./docs/guide`)

**Interfaces:**
- Consumes: the screen models and `TowerText` (Task 10), `TowerClient` (Task 4), slice kinds/capability/`inbox_act` (Task 13), `PhoneArtifactView` (Task 14), Kit `ActionOutbox`.
- Produces: `final class HubTransport: TowerTransport` — `inbox.feed` answered from the slice store (`inbox_folder` + `inbox_card` records assembled into `Feed`; `more` derived per folder); `inbox.act` enqueued as `ActionKind.inboxAct` with the `ActRequest` JSON; outbox states mapped: queued → `busy` (the existing outbox lines show it), not delivered → `refused(sentence)`, applied → `ok`, `outcome_unknown` → `unknown`; `watch` yields `changed` on every publish of the two kinds.

- [ ] **Step 1: Failing tests**

- `HubTransportTests`: `testFeedAssembledFromRecords`, `testActEnqueuesInboxActWithTheRequestJSON`, `testOutboxStatesMapToTowerStates` (four cases), `testUnknownIsNeverResent`.
- `InboxTabWiringTests`: `testInboxIsTheSecondTab`, `testBadgeIsOrangeSumOfWaiting`, `testOptimisticHideThenTheHubWinsAfterTwoPublishes`, `testRefusalBringsTheRowBackWithRetry`, `testReplyOpensASheetWithPropose`, `testMacOnlyActionsShowOnYourMac`, `testApproveWithoutPermissionsGrantIsDisabledWithItsLine`, `testDidntConfirmShowsRefresh` (`TowerText.didntConfirmPhone`, `TowerText.refresh`), `testCardMenuOffersRunNow` (non-idempotent: a second tap while `unknown` sends nothing), `testUnreadableBlocksShowTheUnsupportedBanner` (`TowerText.unsupportedCard` over the card's text).
- `InboxOutboxWiringTests.testQueuedInboxActSurvivesAnAppKill` (persistent outbox replays `inbox_act` after relaunch).

Run: `make mobile-test MOBILE_FILTER='HubTransportTests|InboxTabWiringTests|InboxOutboxWiringTests'` — Expected: FAIL.

- [ ] **Step 2: Implement** the views over the models; gestures: ref rows swipe left Done and Snooze, swipe right Hide (track: Done and Stop; reminder: Done and Snooze 1h); the context menu holds the full verb set and is the accessibility path; a tap pushes the detail. Run the same — Expected: PASS.

Mockup frame → shot:

| Mockup §, frame | Shot |
|---|---|
| 1 Root — dark / light | `inbox-root` |
| 1 Owner folder (pushed) | `inbox-owner-folder` |
| 2 List + one row swiped | `inbox-waiting-swiped` |
| 2 Busy row + failed row with Retry | `inbox-row-busy-failed` |
| 2c Row detail | `inbox-row-detail` |
| 2d Reply… sheet | `inbox-reply-sheet` |
| 3 Needs approval | `inbox-approvals` |
| 3 Approve — sending, then changed on the Mac | `inbox-approve-changed` |
| 4 Feed card | `inbox-artifact` |
| 4 Living card with a table | `inbox-artifact-table` |
| 4 Card ⋯ menu (Run Now) | `inbox-card-menu` |
| 4 Unsupported / unreadable card | `inbox-card-unsupported` |
| 5 Morning brief | `inbox-legacy-brief` |
| 5 Track my threads | `inbox-legacy-tracks` |
| 5 Idea finder | `inbox-legacy-ideas` |
| 6 Loading | `inbox-loading` |
| 6 Empty | `inbox-empty` |
| 6 Empty folder | `inbox-empty-folder` |
| 6 Mac away + queued and not delivered | `inbox-mac-away` |
| 6 Old Mac | `inbox-too-old` |
| 6 Organization policy | `inbox-policy` |
| 6 Didn't confirm | `inbox-didnt-confirm` |
| 6 Older cards on the Mac | `inbox-older-cards` |

`DemoTourTests.testEveryInboxMockupFrameHasAShot` pins this list of 23 names.

- [ ] **Step 3: Tour** — `testTheInboxShots`; run `make mobile-shots` and compare each `inbox-*` shot with mockup §§1–6. Run `make mobile-test MOBILE_FILTER='ScreenshotTourTests|DemoTourTests'`, `make lint-swift`, `go test ./docs/guide`.

- [ ] **Step 4: Commit**

```bash
git add WatchtowerMobile docs
git commit -m "feat(mobile): Inbox tab over the hub (#1170)"
```

**Phase gate (stage 2, controller):** `make test`, `make test-swift` (incl. Kit), `make lint-all`, `make mobile-test`, `make hub-smoke`.

---

## Stage 3 — the Desktop's chat writes in Go

### Task 16: chatstore gaps and `ai session --persist`

**Depends on:** Task 1

**Files:**
- Modify: `internal/chatstore/store.go` (`StartRequest` gains the quote batch and owner-message reuse), `internal/chatstore/testdata/chat_turn_cases.json` (new cases, read by both Go and `WatchtowerDesktop/Tests/Core/ChatTurnStoreFixtureTests.swift` while the Swift store exists)
- Modify: `internal/chat/events.go` (`Command` gains the turn fields; `EventStarted = "started"`, `EventRefused = "refused"`), `cmd/ai_session.go` (`--persist`, `--lease-owner`, `--lease-owner-id`), `cmd/ai.go` (`ai query --events v2` gains the same `--persist` for a database chat: the embedded chats run `ai query` per turn, not the warm session — see `docs/features/embedded-chat.md`)
- Create: `cmd/ai_session_persist.go`
- Test: `internal/chatstore/store_test.go`, `internal/chatstore/fixture_test.go`, `cmd/ai_session_persist_test.go`, `internal/chatstore/bench_test.go`

**Interfaces:**
- Consumes: `chatstore.New(d, owner, ownerID)`, `Store.Start`, `Store.Turn(st).Apply/Flush/Finalize`, `db.HeartbeatChatLease`, `db.GetChatLease` (`CancelRequestedAtMS`), `db.ChatLeaseDesktop`.
- Produces:
  - `StartRequest` adds `ReuseOwnerMessageID int64` (regenerate/edit reuse the owner row and, when the history tip is an unanswered owner message, write its placeholder answer — port of `persistTurnStart`'s `reuseUserMessageID` + `answerIfOwnerMessage`), `TitleText string`, `Quotes []Quote` (the quote batch `persistTurnStart` writes through `plan.alsoWrite`; port its exact rows).
  - stdin `turn` command fields: `text`, `attachment_ids`, `parent_id`, `edit_message_id`, `mode` (`send|regenerate|edit`), `quotes`, `title_text`.
  - Events: `{"type":"started","conversation_id","owner_message_id","assistant_message_id","turn_id"}` before the first delta; `{"type":"refused","reason":"conversation_busy","holder"}` while another owner holds the lease.
  - `--persist` runs `Start` before the provider call, applies every event to the `Turn`, heartbeats and releases the lease, and stops the turn when `cancel_requested_at_ms` is set (the read `internal/hub/chatrun/cancel.go` does).

- [ ] **Step 1: Failing tests**

- `store_test.go`: `TestStart_QuoteBatchRows`, `TestStart_RegenerateReusesTheOwnerMessage`, `TestStart_EditReusesAndWritesThePlaceholder`; fixture cases `quote_batch`, `regenerate_reuse`, `edit_reuse_placeholder` pass in `TestChatstore_MatchesSwiftFixture` and in Swift `ChatTurnStoreFixtureTests`.
- `ai_session_persist_test.go` (a fake provider behind the existing session test seam; any stub process is reaped with its group in `t.Cleanup`): `TestPersist_StartedBeforeTheFirstDelta`, `TestPersist_OwnerRowCommitsBeforeTheProvider` (CHAT-01 order), `TestPersist_RefusedWhileTheHubHoldsTheLease`, `TestPersist_LeaseOwnerIsDesktopWithTheLaunchID`, `TestPersist_RemoteStopEndsTheTurnWithPartial`, `TestPersist_StdinCancelStops`, `TestQueryPersist_EmbeddedChatTurnWritesItsRows`.
- `bench_test.go::BenchmarkPersistStart` (Start on the chat fixture).

Run: `go test ./internal/chatstore/ ./cmd/ -run 'Start_|Persist|Chatstore_MatchesSwiftFixture'` and `make test-swift FILTER=ChatTurnStoreFixtureTests` — Expected: FAIL.

- [ ] **Step 2: Implement**; run the same — Expected: PASS. `go test ./internal/chatstore/ -run '^$' -bench BenchmarkPersistStart -count 5` — record the median beside the Swift start's (measured the same way through `ChatTurnStoreFixtureTests`' timing helper) in the task report. `make lint-diff`.

- [ ] **Step 3: Commit**

```bash
git add internal/chatstore internal/chat cmd WatchtowerDesktop/Tests/Core/ChatTurnStoreFixtureTests.swift
git commit -m "feat(chat): chatstore start gaps and ai session --persist (#1170)"
```

### Task 17: `chat.*` commands

**Depends on:** Task 1, Task 2 (`commands.RegisterAll`, the generator), Task 16

**Files:**
- Create: `internal/chatstore/commands.go` (registrations), `internal/tower/api/chat.go`, `internal/db/chat_projects.go`, `internal/db/artifact_comments.go`, `internal/db/queued_drafts.go`, `internal/db/chat_artifact_keep.go` (the new writers), `internal/chatstore/testdata/chat_writes.json`
- Modify: `internal/db/chat_lease.go` (`ReleaseDesktopLeasesExcept`), `internal/tower/commands/commands.go`; regenerate
- Test: `internal/chatstore/commands_test.go`, `internal/db/chat_lease_test.go`, `WatchtowerDesktop/Tests/Core/ChatWritesFixtureTests.swift`

**Interfaces:**
- Consumes: `chatstore.Store` (`NewConversation`, `Pin`, `Rename`, `Delete`, `SelectBranch`, `MarkRead`), `db.MarkChatTurnSessionLost`, `db.OwnedChatLeases`.
- Produces (guarded unless noted; every request embeds `WriteParams`): `chat.new` → `{conversation_id}`, `chat.pin`, `chat.rename`, `chat.delete`, `chat.archive`, `chat.branch` (`SelectBranch`), `chat.read` (`MarkRead`), `chat.attach` / `chat.attach_link` / `chat.attach_delete` (`ChatAttachmentQueries.insert/link/delete`), `chat.set_project`, `chat.set_routing`, `chat.context` (`EmbeddedChatStore`'s context set), `chat.project.create|rename|instructions|archive|delete|add_source|remove_source|remove_file` (`ChatProjectQueries`), `chat.comment.add|delete_unsent|resolve|mark_sent|apply` (`ArtifactCommentQueries`), `chat.draft.save|clear` (`QueuedDraftQueries`), `chat.artifact.keep|unkeep` (`ChatArtifactQueries.keep/unkeep` — the knowledge-artifact writes), `chat.recover {conversation_id, turn_id}` (marks the turn `session_lost` and releases the lease, as `chatrun.Sweep` does), `chat.release_launches {keep}` (releases every `desktop` lease whose owner id ≠ `keep` and marks their turns `session_lost`; port of `releaseEarlierLaunchesChatLeases`). Re-run a grep of Swift `INSERT|UPDATE|DELETE … chat_` (today: `ChatProjectQueries`, `ArtifactCommentQueries`, `QueuedDraftQueries`, `ChatArtifactQueries`, `ChatAttachmentQueries`, `ChatConversationQueries`, `ChatTreeQueries`, `ChatLeaseQueries`, `ChatStepQueries`, `ChatMessageQueries`, `LiveSlackMark`, `CodeQuestionList`, `TuningChatSurface`, `EmbeddedChatStore`, `IdeaQueries.delete`) and add a command for any writer outside the turn path that the list misses.
- `func (db *DB) ReleaseDesktopLeasesExcept(keep string) ([]ChatLease, error)`.

- [ ] **Step 1: Failing tests** — `chat_writes.json` (one case per command, `swift` naming its Swift writer) run by `TestChatWritesCases` and `ChatWritesFixtureTests.testSwiftWritersMatchEveryGoCase`; `TestChatRecover_MarksSessionLostAndReleases`, `TestReleaseLaunches_KeepsTheCurrentLaunchAndNeverTouchesHubLeases`, `TestChatCommands_RegisteredGuarded`.

Run: `go test ./internal/chatstore/ ./internal/db/ -run 'ChatWrites|ChatRecover|ReleaseLaunches|ChatCommands|ReleaseDesktop'` — Expected: FAIL.

- [ ] **Step 2: Implement**; regenerate; goldens. Run the same plus `make gen-interface-check`, `make test-swift FILTER=ChatWritesFixtureTests` — Expected: PASS. `make lint-diff`.

- [ ] **Step 3: Commit**

```bash
git add internal/chatstore internal/db internal/tower WatchtowerInterface WatchtowerDesktop/Tests/Core/ChatWritesFixtureTests.swift
git commit -m "feat(chat): chat.* tower commands and their Go writers (#1170)"
```

### Task 18: Desktop chat on `--persist` and `TowerClient`

> **Superseded for the main chat (2026-11-18, ask #1469):** the main-chat half of this task (`ai session --persist`, the desktop lease, the main chat's `chat.*` commands and their Swift wiring) was retired when main's unified chat (#1822) was merged in; its engine writes the main chat. The embedded chats' half (`ai query --persist`, their `chat.*` commands, drafts, `meetings.delete`) stays. Spec §8 carries the same note.

**Depends on:** Task 4, Task 5 (`AppState.towerClient`, launch wiring), Task 17

**Files:**
- Modify: `WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift` (send through `--persist`; the owner bubble from the draft at once; keep the draft until `started`; 10 s `started` timeout → the draft comes back and "session ended" shows; reload rows at `started` and at the end; `chat.recover` on a death after `started`), `Sources/WatchtowerCore/Services/Chat/ChatTurnDriver.swift` (stream half only), `Sources/Services/Chat/ChatSessionClient.swift` (`--persist --lease-owner desktop --lease-owner-id <launch id>`; parse `started`/`refused`), `Sources/Services/Chat/ChatSessionPool.swift`, `Sources/App/AppState.swift` and `AppState+Chat.swift` (`chat.release_launches` at launch), `Sources/WatchtowerCore/Services/Chat/Embedded/EmbeddedChatStore.swift` and the embedded engine (database chats on `ai query --events v2 --persist`), every caller of a `chat_*` Swift writer (switch to `chat.*` with optimistic row change and revert on refusal; Delete keeps its confirmation)
- Delete: `Sources/WatchtowerCore/Services/Chat/ChatTurnStore.swift`, `ChatViewModel.persistTurnStart`, `AppState.releaseEarlierLaunchesChatLeases`, every Swift `chat_*` write (the Queries functions listed in Task 17, `LiveSlackMark`'s writes, `CodeQuestionList`'s deletes, `TuningChatSurface`'s title write, `IdeaQueries.delete`'s chat-message delete — now in Go `ideas.delete`), the Swift halves of `ChatTurnStoreFixtureTests` and `ChatWritesFixtureTests` (the JSON stays as the Go golden)
- Create: `WatchtowerDesktop/Tests/Core/ChatTablesWriteGuardTests.swift`; `WatchtowerDesktop/Tests/ChatPersistTimingTests.swift`
- Modify: `docs/inventory/chat.md` (CHAT-01/02/03/05 and LIVE-01: guards re-pointed, same names, none weakened; the 2026-11-15 amendment's "Swift (`ChatTurnStore`)" writer becomes Go only), `docs/features/chat-redesign.md` (**Writers** line), `docs/features/embedded-chat.md`, `docs/features/iphone-chat.md`
- Test: `WatchtowerDesktop/Tests/ChatViewModelTests.swift` (the CHAT-01 guards keep their names and assertions against the new path), `ChatTurnLeaseTests`, per-command refusal tests

**Interfaces:**
- Consumes: `--persist`, `started`/`refused` (Task 16); `chat.*` (Task 17); `TowerClient.act` (Task 4).
- Produces: `ChatSessionClient` events `.started(ChatStarted)`, `.refused(holder: String)`; `ChatViewModel.startedTimeout: Duration = .seconds(10)` (injected clock).

- [ ] **Step 1: Failing tests**

- `ChatTablesWriteGuardTests.testNoSwiftWriteToAChatTable` (same matcher as Task 12 over `chat_[a-z_]+` and the chat record types) — Expected: FAIL listing today's writers.
- `ChatViewModelTests`: `testBubbleShowsBeforeStarted`, `testKillBeforeStartedReturnsTheDraft`, `testKillAfterStartedCallsRecover`, `testSilentProcessGivesUpAfterTenSeconds` (manual clock), `testRefusedConversationBusyRestoresTheDraftWithTheHolderLine`; the eight `testChat01*` guards unchanged in name and assertion.
- Refusal-revert per command: `testPinRefusalRevertsTheRow`, `testRenameRefusalReverts`, `testDeleteRefusalReverts`, `testBranchRefusalReverts`, `testReadRefusalReverts`.
- `ChatPersistTimingTests.testStubProviderMedianNoWorseThanTwentyMilliseconds` — runs the stub-provider turn (first text event) 30 times on the old path recorded once as a baseline file in the scratch dir and 30 times on the new path in the same run, compares medians; it measures relative cost, never sleeps. Gate: ≤ 20 ms worse.

Run: `make test-swift FILTER='ChatTablesWriteGuardTests|ChatViewModelTests|ChatTurnLeaseTests|ChatPersistTimingTests'` — Expected: FAIL.

- [ ] **Step 2: Implement the switch**, then delete the Swift writers. The CHAT-02/03/05 and LIVE-01 guards (`ChatSessionPolicyTests`, `ArtifactActionsTests`, `ArtifactChat05ScanTests`, `LiveSlack01GuardTests` with its `testReaderList` over the Swift sources) stay green; where a guard read a deleted Swift writer, it moves to Go beside `TestChat01Go_OwnerRowBeforeTurn` with the same name.

- [ ] **Step 3: Run** the Step 1 command, `make test-swift FILTER='Chat|Embedded|LiveSlack|Artifact'`, `go test ./internal/chatstore/ ./cmd/ -run 'Persist|Chat'`, `make lint-swift`, `make lint-diff` — Expected: PASS, timing gate met (a miss means the path does not switch; report the numbers).

- [ ] **Step 4: Commit**

```bash
git add -A WatchtowerDesktop docs
git commit -m "feat(desktop): chat writes through Go (--persist and chat.* commands) (#1170)"
```

**Phase gate (stage 3, controller):** `make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`, `BenchmarkPersistStart` vs the recorded Swift start, `ChatPersistTimingTests`.

---

## Spec coverage notes

- Spec §10 docs are folded into Tasks 1–3 (`tower-interface.md`, CLAUDE.md, README), 5 (tray, guide), 6–8 and 11 (`inbox-core.md`, `inbox-folders.md`, `inbox-card-blocks.md`, inventory), 13 (`go-hub.md`, protocol spec), 15 (`mobile-companion.md`, iPhone guide page), 18 (`chat-redesign.md`, `embedded-chat.md`, `iphone-chat.md`, chat inventory).
- Deviations decided in this plan, from reading the code: the phone tab order keeps the existing Chats tab (`now, inbox, workbench, chats, calendar`); the embedded chats run `ai query`, so `--persist` lands on both `ai session` and `ai query --events v2`; `catchup.acknowledge`, `digests.*`, `targets.set_status`/`targets.snooze` and the chat-born idea writes join the stage-1 commands (ask #1362); the Mac handoff texts stay in the Swift `InboxCardTexts` remainder beside `preview` and `targetTitleLimit`; the phone's "too old" body names the hub instead of "This Mac's"; the feed is zone-free and grouping happens in the models.
