# Watchtower MCP Server (v1, read-only) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a read-only MCP server (`watchtower mcp`, stdio) that exposes Watchtower's curated product data (targets, briefings/digests, people/tracks/calendar, Jira) as semantic tools to any MCP client, plus a docs config snippet and a Desktop TOOLS entry.

**Architecture:** A new Go package `internal/mcp/` builds an `mcp.Server` (official `go-sdk`) and registers per-domain read tools, each a thin handler: typed args → existing `internal/db` read method → JSON-text result. A thin cobra command `cmd/mcp.go` resolves config like every other command, opens the DB via `db.Open`, and serves over stdio. Read-only is guaranteed by the tool surface (no write tool is ever registered).

**Tech Stack:** Go 1.25, cobra, `github.com/modelcontextprotocol/go-sdk` v1.6.1 (stdio MCP), `modernc.org/sqlite` via existing `internal/db`. Desktop: SwiftUI/GRDB (existing `WatchtowerDesktop/`).

## Global Constraints

- Go module `watchtower`, Go 1.25.7. SDK dependency pinned to `github.com/modelcontextprotocol/go-sdk v1.6.1`.
- **Read-only only.** No tool may write, update, or delete. Only read methods from `internal/db` / `internal/jira` are called.
- Our package lives in `internal/mcp/` with package name `mcp`; the SDK is imported aliased as `mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"` to avoid the name clash.
- Every tool returns its payload as **JSON text** (`json.MarshalIndent`) in `CallToolResult.Content` as a `*mcpsdk.TextContent`. Missing data → empty result (`[]`/`null`), never an error. Not-found-by-id → `IsError: true` result with a message; handlers never panic.
- Config resolution copies the exact boilerplate used by `runTracks` in `cmd/tracks.go` (`config.Load(flagConfig)` → optional `flagWorkspace` override → `cfg.ValidateWorkspace()` → `db.Open(cfg.DBPath())`).
- Optional string filter args use empty-string = "no filter" semantics (matches `db.*Filter` structs). `limit` is an `int`, `0` = no limit.
- Tests run with `go test ./internal/mcp/...` and the full suite `go test ./...` must stay green.

---

## File Structure

- `cmd/mcp.go` — cobra `watchtower mcp` command; opens DB, builds server, serves stdio.
- `internal/mcp/server.go` — `Server` wrapper, `NewServer(*db.DB) *Server`, `ServeStdio(ctx)`, JSON/error result helpers, calls each `registerX`.
- `internal/mcp/targets.go` — `registerTargets`, `list_targets` + `get_target` handlers.
- `internal/mcp/digests.go` — `registerDigests`, `get_today_briefing` + `list_digests` + `get_digest`.
- `internal/mcp/people.go` — `registerPeople`, `list_people` + `get_person` + `list_tracks` + `get_track` + `list_upcoming_events`.
- `internal/mcp/jira.go` — `registerJira`, `list_jira_issues` + `get_jira_issue`.
- `internal/mcp/server_test.go` — shared in-memory test harness + `tools/list` smoke test + read-only invariant test.
- `internal/mcp/targets_test.go`, `digests_test.go`, `people_test.go`, `jira_test.go` — per-domain handler tests.
- `internal/db/jira.go` — **modify**: add `JiraIssueFilter` + `GetJiraIssues(JiraIssueFilter)` read method (Task 4).
- `internal/db/jira_test.go` — **modify**: test for `GetJiraIssues` (Task 4).
- `docs/mcp-server.md` — **create**: client config snippets (Task 5).
- `README.md` — **modify**: one-line pointer to the MCP server (Task 5).
- Desktop (Task 6, via `add-desktop-feature` skill): a `MCPServerView` in the TOOLS section + nav wiring.

---

### Task 1: Package skeleton + `watchtower mcp` command + Targets tools

**Files:**
- Create: `internal/mcp/server.go`
- Create: `internal/mcp/targets.go`
- Create: `internal/mcp/server_test.go`
- Create: `internal/mcp/targets_test.go`
- Create: `cmd/mcp.go`
- Modify: `go.mod` / `go.sum` (via `go get`)

**Interfaces:**
- Produces:
  - `mcp.NewServer(database *db.DB) *mcp.Server` — builds the server and registers all domain tools.
  - `(*mcp.Server).ServeStdio(ctx context.Context) error` — runs the server over stdio.
  - `(*mcp.Server).s` (unexported `*mcpsdk.Server`) — used only by same-package tests to connect an in-memory client.
  - Helpers `jsonResult(v any) (*mcpsdk.CallToolResult, any, error)` and `errResult(msg string) *mcpsdk.CallToolResult`.
  - `registerTargets(s *mcpsdk.Server, database *db.DB)`.
  - Test helper `newTestSession(t *testing.T, database *db.DB) *mcpsdk.ClientSession` and `seedDB(t *testing.T) *db.DB`.
- Consumes (existing): `db.Open`, `(*db.DB).GetTargets(db.TargetFilter)`, `(*db.DB).GetTargetByID(int)`, `(*db.DB).CreateTarget(db.Target)`, `config.Load`, `cfg.DBPath()`, package vars `flagConfig`, `flagWorkspace`.

- [ ] **Step 1: Add the SDK dependency**

Run:
```bash
cd /Users/user/PhpstormProjects/watchtower
go get github.com/modelcontextprotocol/go-sdk@v1.6.1
```
Expected: `go.mod` now requires `github.com/modelcontextprotocol/go-sdk v1.6.1`.

- [ ] **Step 2: Write the server core + result helpers**

Create `internal/mcp/server.go`:
```go
// Package mcp implements a read-only Model Context Protocol server that
// exposes Watchtower's curated product data to MCP clients. Every registered
// tool is read-only; no tool mutates the database.
package mcp

import (
	"context"
	"encoding/json"
	"fmt"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
)

// version is reported to MCP clients in the server handshake.
const version = "0.1.0"

// Server wraps the SDK server so callers (cmd, tests) do not import the SDK.
type Server struct {
	s *mcpsdk.Server
}

// NewServer builds an MCP server over the given database and registers every
// read-only domain tool.
func NewServer(database *db.DB) *Server {
	s := mcpsdk.NewServer(&mcpsdk.Implementation{
		Name:    "watchtower",
		Title:   "Watchtower",
		Version: version,
	}, nil)

	registerTargets(s, database)

	return &Server{s: s}
}

// ServeStdio runs the server over stdio until the context is cancelled or the
// client disconnects.
func (srv *Server) ServeStdio(ctx context.Context) error {
	return srv.s.Run(ctx, &mcpsdk.StdioTransport{})
}

// jsonResult marshals v to indented JSON and returns it as text content.
func jsonResult(v any) (*mcpsdk.CallToolResult, any, error) {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return errResult(fmt.Sprintf("marshaling result: %v", err)), nil, nil
	}
	return &mcpsdk.CallToolResult{
		Content: []mcpsdk.Content{&mcpsdk.TextContent{Text: string(b)}},
	}, nil, nil
}

// errResult builds a tool-level error result with a human-readable message.
func errResult(msg string) *mcpsdk.CallToolResult {
	return &mcpsdk.CallToolResult{
		IsError: true,
		Content: []mcpsdk.Content{&mcpsdk.TextContent{Text: msg}},
	}
}
```

- [ ] **Step 3: Write the Targets tools**

Create `internal/mcp/targets.go`:
```go
package mcp

import (
	"context"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
)

type listTargetsArgs struct {
	Status    string `json:"status,omitempty" jsonschema:"filter by status: todo|in_progress|blocked|done|dismissed|snoozed"`
	Priority  string `json:"priority,omitempty" jsonschema:"filter by priority: high|medium|low"`
	Level     string `json:"level,omitempty" jsonschema:"filter by level: quarter|month|week|day|custom"`
	Ownership string `json:"ownership,omitempty" jsonschema:"filter by ownership: mine|delegated|watching"`
	Limit     int    `json:"limit,omitempty" jsonschema:"max results, 0 = no limit"`
}

type getTargetArgs struct {
	ID int `json:"id" jsonschema:"target id"`
}

func registerTargets(s *mcpsdk.Server, database *db.DB) {
	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name:        "list_targets",
		Description: "List the user's personal action items (targets), optionally filtered by status, priority, level, or ownership.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args listTargetsArgs) (*mcpsdk.CallToolResult, any, error) {
		targets, err := database.GetTargets(db.TargetFilter{
			Status:    args.Status,
			Priority:  args.Priority,
			Level:     args.Level,
			Ownership: args.Ownership,
			Limit:     args.Limit,
		})
		if err != nil {
			return errResult("listing targets: " + err.Error()), nil, nil
		}
		return jsonResult(targets)
	})

	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name:        "get_target",
		Description: "Get a single target by id, including sub-items, notes, and metadata.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args getTargetArgs) (*mcpsdk.CallToolResult, any, error) {
		target, err := database.GetTargetByID(args.ID)
		if err != nil {
			return errResult("getting target: " + err.Error()), nil, nil
		}
		if target == nil {
			return errResult("no target with id " + itoa(args.ID)), nil, nil
		}
		return jsonResult(target)
	})
}
```

Add a tiny helper at the bottom of `server.go` (used by id-not-found messages):
```go
// itoa avoids importing strconv in every tool file.
func itoa(n int) string { return fmt.Sprintf("%d", n) }
```

- [ ] **Step 4: Write the cobra command**

Create `cmd/mcp.go`:
```go
package cmd

import (
	"fmt"

	"github.com/spf13/cobra"

	internalmcp "watchtower/internal/mcp"
	"watchtower/internal/config"
	"watchtower/internal/db"
)

var mcpCmd = &cobra.Command{
	Use:   "mcp",
	Short: "Run a read-only MCP server exposing Watchtower data over stdio",
	Long: `Run a Model Context Protocol (MCP) server over stdio.

The server exposes Watchtower's product data (targets, briefings, digests,
people, tracks, calendar, Jira) as read-only tools so any MCP client
(Claude Code, Cursor, Codex, ...) can use it for work context.

Add it to Claude Code with:
  claude mcp add watchtower -- watchtower mcp`,
	RunE: runMCP,
}

func init() {
	rootCmd.AddCommand(mcpCmd)
}

func runMCP(cmd *cobra.Command, args []string) error {
	cfg, err := config.Load(flagConfig)
	if err != nil {
		return fmt.Errorf("loading config: %w", err)
	}
	if flagWorkspace != "" {
		cfg.ActiveWorkspace = flagWorkspace
	}
	if err := cfg.ValidateWorkspace(); err != nil {
		return fmt.Errorf("invalid config: %w", err)
	}

	database, err := db.Open(cfg.DBPath())
	if err != nil {
		return fmt.Errorf("opening database: %w", err)
	}
	defer database.Close()

	return internalmcp.NewServer(database).ServeStdio(cmd.Context())
}
```

- [ ] **Step 5: Write the shared test harness + targets failing test**

Create `internal/mcp/server_test.go`:
```go
package mcp

import (
	"context"
	"path/filepath"
	"testing"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
)

// seedDB opens a fresh temp database. Per-test seeding is layered on top.
func seedDB(t *testing.T) *db.DB {
	t.Helper()
	path := filepath.Join(t.TempDir(), "test.db")
	database, err := db.Open(path)
	if err != nil {
		t.Fatalf("opening test db: %v", err)
	}
	t.Cleanup(func() { _ = database.Close() })
	return database
}

// newTestSession wires an in-memory MCP client to a server over our database.
func newTestSession(t *testing.T, database *db.DB) *mcpsdk.ClientSession {
	t.Helper()
	ctx := context.Background()
	srv := NewServer(database)
	client := mcpsdk.NewClient(&mcpsdk.Implementation{Name: "test", Version: "v0"}, nil)
	st, ct := mcpsdk.NewInMemoryTransports()
	if _, err := srv.s.Connect(ctx, st, nil); err != nil {
		t.Fatalf("server connect: %v", err)
	}
	cs, err := client.Connect(ctx, ct, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	t.Cleanup(func() { _ = cs.Close() })
	return cs
}

// textContent extracts the first text content block from a tool result.
func textContent(t *testing.T, res *mcpsdk.CallToolResult) string {
	t.Helper()
	if len(res.Content) == 0 {
		t.Fatalf("result has no content")
	}
	tc, ok := res.Content[0].(*mcpsdk.TextContent)
	if !ok {
		t.Fatalf("first content is not text: %T", res.Content[0])
	}
	return tc.Text
}
```

Create `internal/mcp/targets_test.go`:
```go
package mcp

import (
	"context"
	"strings"
	"testing"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
)

func TestListTargets(t *testing.T) {
	database := seedDB(t)
	if _, err := database.CreateTarget(db.Target{
		Text:     "Ship MCP server",
		Intent:   "expose context",
		Level:    "week",
		Status:   "todo",
		Priority: "high",
	}); err != nil {
		t.Fatalf("seeding target: %v", err)
	}
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "list_targets",
		Arguments: map[string]any{"status": "todo"},
	})
	if err != nil {
		t.Fatalf("call list_targets: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected error result: %s", textContent(t, res))
	}
	if got := textContent(t, res); !strings.Contains(got, "Ship MCP server") {
		t.Fatalf("expected seeded target in output, got: %s", got)
	}
}

func TestListTargetsEmptyIsNotError(t *testing.T) {
	// Valid-but-degenerate input: a status with no matching rows must return an
	// empty array, not an error.
	database := seedDB(t)
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "list_targets",
		Arguments: map[string]any{"status": "done"},
	})
	if err != nil {
		t.Fatalf("call list_targets: %v", err)
	}
	if res.IsError {
		t.Fatalf("empty result should not be an error: %s", textContent(t, res))
	}
	if got := strings.TrimSpace(textContent(t, res)); got != "[]" && got != "null" {
		t.Fatalf("expected empty array/null, got: %s", got)
	}
}

func TestGetTargetNotFound(t *testing.T) {
	database := seedDB(t)
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "get_target",
		Arguments: map[string]any{"id": 999},
	})
	if err != nil {
		t.Fatalf("call get_target: %v", err)
	}
	if !res.IsError {
		t.Fatalf("expected IsError for unknown id")
	}
}
```

- [ ] **Step 6: Run tests to verify they fail (then pass after code compiles)**

Run:
```bash
cd /Users/user/PhpstormProjects/watchtower && go test ./internal/mcp/... -run 'Target' -v
```
Expected: PASS for all three tests. (If the build fails on the SDK API, reconcile against `go doc github.com/modelcontextprotocol/go-sdk/mcp` for the pinned version — `AddTool`, `NewServer`, `StdioTransport`, `NewInMemoryTransports`, `CallToolParams`, `CallToolResult` are the load-bearing symbols.)

- [ ] **Step 7: Verify the command builds and registers**

Run:
```bash
cd /Users/user/PhpstormProjects/watchtower && go build ./... && go run . mcp --help
```
Expected: build succeeds; help text for `watchtower mcp` prints.

- [ ] **Step 8: Commit**

```bash
cd /Users/user/PhpstormProjects/watchtower
git add go.mod go.sum internal/mcp/server.go internal/mcp/targets.go internal/mcp/server_test.go internal/mcp/targets_test.go cmd/mcp.go
git commit -m "feat(mcp): read-only MCP server skeleton + targets tools"
```

---

### Task 2: Briefings & Digests tools

**Files:**
- Create: `internal/mcp/digests.go`
- Create: `internal/mcp/digests_test.go`
- Modify: `internal/mcp/server.go:NewServer` — add `registerDigests(s, database)`

**Interfaces:**
- Produces: `registerDigests(s *mcpsdk.Server, database *db.DB)`; tools `get_today_briefing`, `list_digests`, `get_digest`.
- Consumes (existing): `(*db.DB).GetRecentBriefings(userID string, limit int) ([]db.Briefing, error)`, `(*db.DB).GetDigests(db.DigestFilter) ([]db.Digest, error)`, `(*db.DB).GetDigestByID(int) (*db.Digest, error)`. `db.DigestFilter{ChannelID, Type, FromUnix, ToUnix, Limit}`.

- [ ] **Step 1: Write the failing test**

Create `internal/mcp/digests_test.go`:
```go
package mcp

import (
	"context"
	"strings"
	"testing"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
)

func TestListDigests(t *testing.T) {
	database := seedDB(t)
	if _, err := database.UpsertDigest(db.Digest{
		ChannelID:   "C1",
		DigestType:  "daily",
		Summary:     "people discussed the launch",
		PeriodFrom:  1.0,
		PeriodTo:    2.0,
		MessageCount: 5,
	}); err != nil {
		t.Fatalf("seeding digest: %v", err)
	}
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "list_digests",
		Arguments: map[string]any{"type": "daily"},
	})
	if err != nil {
		t.Fatalf("call list_digests: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected error: %s", textContent(t, res))
	}
	if got := textContent(t, res); !strings.Contains(got, "discussed the launch") {
		t.Fatalf("expected seeded digest, got: %s", got)
	}
}

func TestGetTodayBriefingEmpty(t *testing.T) {
	// No briefing exists yet → empty/null result, not an error.
	database := seedDB(t)
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "get_today_briefing",
		Arguments: map[string]any{},
	})
	if err != nil {
		t.Fatalf("call get_today_briefing: %v", err)
	}
	if res.IsError {
		t.Fatalf("missing briefing should not be an error: %s", textContent(t, res))
	}
}
```

> NOTE: confirm the exact `db.Digest` field names (`DigestType`, `Summary`, `PeriodFrom`, `PeriodTo`, `MessageCount`, `ChannelID`) against `internal/db/models.go` before seeding; adjust the literal if a field differs. Drop any field that triggers a NOT NULL error and set only what the insert requires.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/user/PhpstormProjects/watchtower && go test ./internal/mcp/... -run 'Digest|Briefing' -v`
Expected: FAIL — tools `list_digests` / `get_today_briefing` not registered.

- [ ] **Step 3: Write the implementation**

Create `internal/mcp/digests.go`:
```go
package mcp

import (
	"context"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
)

type listDigestsArgs struct {
	Type    string `json:"type,omitempty" jsonschema:"digest type: channel|daily|weekly"`
	Channel string `json:"channel,omitempty" jsonschema:"channel id to filter by"`
	Limit   int    `json:"limit,omitempty" jsonschema:"max results, 0 = no limit"`
}

type getDigestArgs struct {
	ID int `json:"id" jsonschema:"digest id"`
}

func registerDigests(s *mcpsdk.Server, database *db.DB) {
	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name:        "get_today_briefing",
		Description: "Get the most recent daily briefing (your personalized roll-up of what needs attention).",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, _ struct{}) (*mcpsdk.CallToolResult, any, error) {
		briefings, err := database.GetRecentBriefings("", 1)
		if err != nil {
			return errResult("getting briefing: " + err.Error()), nil, nil
		}
		if len(briefings) == 0 {
			return jsonResult(nil)
		}
		return jsonResult(briefings[0])
	})

	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name:        "list_digests",
		Description: "List channel/daily/weekly digests (AI summaries of Slack activity), most recent first.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args listDigestsArgs) (*mcpsdk.CallToolResult, any, error) {
		limit := args.Limit
		if limit == 0 {
			limit = 20
		}
		digests, err := database.GetDigests(db.DigestFilter{
			Type:      args.Type,
			ChannelID: args.Channel,
			Limit:     limit,
		})
		if err != nil {
			return errResult("listing digests: " + err.Error()), nil, nil
		}
		return jsonResult(digests)
	})

	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name:        "get_digest",
		Description: "Get a single digest by id, including its full summary.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args getDigestArgs) (*mcpsdk.CallToolResult, any, error) {
		digest, err := database.GetDigestByID(args.ID)
		if err != nil {
			return errResult("getting digest: " + err.Error()), nil, nil
		}
		if digest == nil {
			return errResult("no digest with id " + itoa(args.ID)), nil, nil
		}
		return jsonResult(digest)
	})
}
```

Modify `internal/mcp/server.go` — in `NewServer`, after `registerTargets(s, database)`:
```go
	registerTargets(s, database)
	registerDigests(s, database)
```

> NOTE: `GetRecentBriefings("", 1)` uses an empty userID to mean "any user" (single-user local DB). Confirm `GetRecentBriefings` treats `""` as no user filter; if it requires a real userID, fetch the current user via the existing workspace/`auth` accessor used elsewhere (grep `CurrentUserID` in `internal/db`) and pass it.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/user/PhpstormProjects/watchtower && go test ./internal/mcp/... -run 'Digest|Briefing' -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/user/PhpstormProjects/watchtower
git add internal/mcp/digests.go internal/mcp/digests_test.go internal/mcp/server.go
git commit -m "feat(mcp): briefings + digests tools"
```

---

### Task 3: People, Tracks & Calendar tools

**Files:**
- Create: `internal/mcp/people.go`
- Create: `internal/mcp/people_test.go`
- Modify: `internal/mcp/server.go:NewServer` — add `registerPeople(s, database)`

**Interfaces:**
- Produces: `registerPeople(s *mcpsdk.Server, database *db.DB)`; tools `list_people`, `get_person`, `list_tracks`, `get_track`, `list_upcoming_events`.
- Consumes (existing): `(*db.DB).GetPeopleCards(db.PeopleCardFilter) ([]db.PeopleCard, error)`, `(*db.DB).GetLatestPeopleCard(userID string) (*db.PeopleCard, error)`, `(*db.DB).GetTracks(db.TrackFilter) ([]db.Track, error)`, `(*db.DB).GetTrackByID(int) (*db.Track, error)`, `(*db.DB).GetCalendarEvents(db.CalendarEventFilter) ([]db.CalendarEvent, error)`. `db.CalendarEventFilter{CalendarID, FromTime, ToTime, Limit}` with ISO8601 time strings.

- [ ] **Step 1: Write the failing test**

Create `internal/mcp/people_test.go`:
```go
package mcp

import (
	"context"
	"strings"
	"testing"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
)

func TestListTracks(t *testing.T) {
	database := seedDB(t)
	if _, err := database.UpsertTrack(db.Track{
		Title:         "Launch readiness",
		Narrative:     "team is preparing the launch",
		CurrentStatus: "in progress",
		Status:        "active",
	}); err != nil {
		t.Fatalf("seeding track: %v", err)
	}
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "list_tracks",
		Arguments: map[string]any{},
	})
	if err != nil {
		t.Fatalf("call list_tracks: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected error: %s", textContent(t, res))
	}
	if got := textContent(t, res); !strings.Contains(got, "Launch readiness") {
		t.Fatalf("expected seeded track, got: %s", got)
	}
}

func TestListUpcomingEventsEmpty(t *testing.T) {
	database := seedDB(t)
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "list_upcoming_events",
		Arguments: map[string]any{"hours": 48},
	})
	if err != nil {
		t.Fatalf("call list_upcoming_events: %v", err)
	}
	if res.IsError {
		t.Fatalf("empty calendar should not be an error: %s", textContent(t, res))
	}
}
```

> NOTE: confirm `db.Track` field names (`Title`, `Narrative`, `CurrentStatus`, `Status`) against `internal/db/models.go` before seeding.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/user/PhpstormProjects/watchtower && go test ./internal/mcp/... -run 'Track|Upcoming|People|Person' -v`
Expected: FAIL — tools not registered.

- [ ] **Step 3: Write the implementation**

Create `internal/mcp/people.go`:
```go
package mcp

import (
	"context"
	"time"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
)

type getPersonArgs struct {
	UserID string `json:"user_id" jsonschema:"Slack user id of the person"`
}

type listTracksArgs struct {
	Status string `json:"status,omitempty" jsonschema:"only 'active' tracks exist; leave empty for all non-dismissed"`
	Limit  int    `json:"limit,omitempty" jsonschema:"max results, 0 = no limit"`
}

type getTrackArgs struct {
	ID int `json:"id" jsonschema:"track id"`
}

type listUpcomingEventsArgs struct {
	Hours int `json:"hours,omitempty" jsonschema:"look-ahead window in hours, default 48"`
}

func registerPeople(s *mcpsdk.Server, database *db.DB) {
	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name:        "list_people",
		Description: "List people cards (per-person communication and collaboration profiles).",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, _ struct{}) (*mcpsdk.CallToolResult, any, error) {
		cards, err := database.GetPeopleCards(db.PeopleCardFilter{})
		if err != nil {
			return errResult("listing people: " + err.Error()), nil, nil
		}
		return jsonResult(cards)
	})

	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name:        "get_person",
		Description: "Get the latest people card for a person by Slack user id.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args getPersonArgs) (*mcpsdk.CallToolResult, any, error) {
		card, err := database.GetLatestPeopleCard(args.UserID)
		if err != nil {
			return errResult("getting person: " + err.Error()), nil, nil
		}
		if card == nil {
			return errResult("no people card for user " + args.UserID), nil, nil
		}
		return jsonResult(card)
	})

	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name:        "list_tracks",
		Description: "List narrative tracks (auto-created ongoing storylines across Slack).",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args listTracksArgs) (*mcpsdk.CallToolResult, any, error) {
		tracks, err := database.GetTracks(db.TrackFilter{Limit: args.Limit})
		if err != nil {
			return errResult("listing tracks: " + err.Error()), nil, nil
		}
		return jsonResult(tracks)
	})

	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name:        "get_track",
		Description: "Get a single narrative track by id.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args getTrackArgs) (*mcpsdk.CallToolResult, any, error) {
		track, err := database.GetTrackByID(args.ID)
		if err != nil {
			return errResult("getting track: " + err.Error()), nil, nil
		}
		if track == nil {
			return errResult("no track with id " + itoa(args.ID)), nil, nil
		}
		return jsonResult(track)
	})

	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name:        "list_upcoming_events",
		Description: "List calendar events in the next N hours (default 48).",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args listUpcomingEventsArgs) (*mcpsdk.CallToolResult, any, error) {
		hours := args.Hours
		if hours <= 0 {
			hours = 48
		}
		now := time.Now().UTC()
		events, err := database.GetCalendarEvents(db.CalendarEventFilter{
			FromTime: now.Format(time.RFC3339),
			ToTime:   now.Add(time.Duration(hours) * time.Hour).Format(time.RFC3339),
		})
		if err != nil {
			return errResult("listing events: " + err.Error()), nil, nil
		}
		return jsonResult(events)
	})
}
```

Modify `internal/mcp/server.go` — in `NewServer`, after `registerDigests(s, database)`:
```go
	registerDigests(s, database)
	registerPeople(s, database)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd /Users/user/PhpstormProjects/watchtower && go test ./internal/mcp/... -run 'Track|Upcoming|People|Person' -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/user/PhpstormProjects/watchtower
git add internal/mcp/people.go internal/mcp/people_test.go internal/mcp/server.go
git commit -m "feat(mcp): people, tracks, calendar tools"
```

---

### Task 4: Jira tools (+ new `GetJiraIssues` read method)

**Files:**
- Modify: `internal/db/jira.go` — add `JiraIssueFilter` + `GetJiraIssues`
- Modify: `internal/db/jira_test.go` — add `TestGetJiraIssues`
- Create: `internal/mcp/jira.go`
- Create: `internal/mcp/jira_test.go`
- Modify: `internal/mcp/server.go:NewServer` — add `registerJira(s, database)`

**Interfaces:**
- Produces:
  - `db.JiraIssueFilter{ProjectKey, Status, AssigneeAccountID, SprintID *int, Limit int}`.
  - `(*db.DB).GetJiraIssues(db.JiraIssueFilter) ([]db.JiraIssue, error)` — non-deleted issues, newest `updated_at` first.
  - `registerJira(s *mcpsdk.Server, database *db.DB)`; tools `list_jira_issues`, `get_jira_issue`.
- Consumes (existing): `(*db.DB).GetJiraIssueByKey(key string) (*db.JiraIssue, error)`, `(*db.DB).UpsertJiraIssue(db.JiraIssue) error`, `db.JiraIssue` fields (`Key`, `ProjectKey`, `Status`, `Summary`, `AssigneeAccountID`, `SprintID`, `UpdatedAt`, `IsDeleted`).

- [ ] **Step 1: Write the failing DB test**

Add to `internal/db/jira_test.go`:
```go
func TestGetJiraIssues(t *testing.T) {
	database := openTestDB(t) // use the existing helper in this test file
	defer database.Close()

	mustUpsert := func(key, project, status string) {
		if err := database.UpsertJiraIssue(JiraIssue{
			Key: key, ID: key, ProjectKey: project, Summary: "s",
			Status: status, StatusCategory: "In Progress",
			CreatedAt: "2026-06-01T00:00:00Z", UpdatedAt: "2026-06-02T00:00:00Z",
			SyncedAt: "2026-06-02T00:00:00Z",
		}); err != nil {
			t.Fatalf("upsert %s: %v", key, err)
		}
	}
	mustUpsert("ABC-1", "ABC", "To Do")
	mustUpsert("ABC-2", "ABC", "Done")
	mustUpsert("XYZ-1", "XYZ", "To Do")

	all, err := database.GetJiraIssues(JiraIssueFilter{})
	if err != nil {
		t.Fatalf("GetJiraIssues all: %v", err)
	}
	if len(all) != 3 {
		t.Fatalf("expected 3 issues, got %d", len(all))
	}

	byProject, err := database.GetJiraIssues(JiraIssueFilter{ProjectKey: "ABC"})
	if err != nil {
		t.Fatalf("GetJiraIssues project: %v", err)
	}
	if len(byProject) != 2 {
		t.Fatalf("expected 2 ABC issues, got %d", len(byProject))
	}

	byStatus, err := database.GetJiraIssues(JiraIssueFilter{Status: "To Do"})
	if err != nil {
		t.Fatalf("GetJiraIssues status: %v", err)
	}
	if len(byStatus) != 2 {
		t.Fatalf("expected 2 To Do issues, got %d", len(byStatus))
	}
}
```

> NOTE: reuse whatever DB-open helper `internal/db/jira_test.go` already uses (grep the file for `func openTestDB` / `newTestDB` / `mustOpen`); replace `openTestDB(t)` with that name. Confirm `JiraIssue` required NOT NULL columns from `internal/db/schema.sql` and set them in the seed (the literal above sets the known NOT NULL fields).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/user/PhpstormProjects/watchtower && go test ./internal/db/ -run TestGetJiraIssues -v`
Expected: FAIL — `JiraIssueFilter` / `GetJiraIssues` undefined.

- [ ] **Step 3: Implement the read method**

Add to `internal/db/jira.go` (near the other Jira issue readers):
```go
// JiraIssueFilter narrows GetJiraIssues. Empty/zero fields are not applied.
type JiraIssueFilter struct {
	ProjectKey        string
	Status            string
	AssigneeAccountID string
	SprintID          *int
	Limit             int
}

// GetJiraIssues returns non-deleted Jira issues matching the filter, most
// recently updated first.
func (db *DB) GetJiraIssues(f JiraIssueFilter) ([]JiraIssue, error) {
	query := `SELECT key, id, project_key, board_id, summary, description_text,
		issue_type, issue_type_category, is_bug, status, status_category,
		status_category_changed_at, assignee_account_id, assignee_email,
		assignee_display_name, assignee_slack_id, reporter_account_id,
		reporter_email, reporter_display_name, reporter_slack_id, priority,
		story_points, due_date, sprint_id, sprint_name, epic_key, labels,
		components, fix_versions, created_at, updated_at, resolved_at,
		raw_json, custom_fields_json, synced_at, is_deleted
		FROM jira_issues WHERE is_deleted = 0`
	var args []any
	if f.ProjectKey != "" {
		query += ` AND project_key = ?`
		args = append(args, f.ProjectKey)
	}
	if f.Status != "" {
		query += ` AND status = ?`
		args = append(args, f.Status)
	}
	if f.AssigneeAccountID != "" {
		query += ` AND assignee_account_id = ?`
		args = append(args, f.AssigneeAccountID)
	}
	if f.SprintID != nil {
		query += ` AND sprint_id = ?`
		args = append(args, *f.SprintID)
	}
	query += ` ORDER BY updated_at DESC`
	if f.Limit > 0 {
		query += fmt.Sprintf(` LIMIT %d`, f.Limit)
	}
	return db.scanJiraIssues(query, args...)
}
```

> NOTE: this assumes a private `scanJiraIssues(query string, args ...any) ([]JiraIssue, error)` row-scanner already exists (the other `GetJiraIssues*` readers must scan the same columns). Grep `internal/db/jira.go` for the existing scanner helper (likely `scanJiraIssues` / `queryJiraIssues`) and call it; if the column list differs, copy it verbatim from that helper to stay consistent.

- [ ] **Step 4: Run the DB test to verify it passes**

Run: `cd /Users/user/PhpstormProjects/watchtower && go test ./internal/db/ -run TestGetJiraIssues -v`
Expected: PASS.

- [ ] **Step 5: Write the MCP jira test**

Create `internal/mcp/jira_test.go`:
```go
package mcp

import (
	"context"
	"strings"
	"testing"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
)

func TestListJiraIssues(t *testing.T) {
	database := seedDB(t)
	if err := database.UpsertJiraIssue(db.JiraIssue{
		Key: "ABC-1", ID: "ABC-1", ProjectKey: "ABC", Summary: "fix the thing",
		Status: "To Do", StatusCategory: "To Do",
		CreatedAt: "2026-06-01T00:00:00Z", UpdatedAt: "2026-06-02T00:00:00Z",
		SyncedAt: "2026-06-02T00:00:00Z",
	}); err != nil {
		t.Fatalf("seeding jira issue: %v", err)
	}
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "list_jira_issues",
		Arguments: map[string]any{"project": "ABC"},
	})
	if err != nil {
		t.Fatalf("call list_jira_issues: %v", err)
	}
	if res.IsError {
		t.Fatalf("unexpected error: %s", textContent(t, res))
	}
	if got := textContent(t, res); !strings.Contains(got, "fix the thing") {
		t.Fatalf("expected seeded issue, got: %s", got)
	}
}

func TestGetJiraIssueNotFound(t *testing.T) {
	database := seedDB(t)
	cs := newTestSession(t, database)

	res, err := cs.CallTool(context.Background(), &mcpsdk.CallToolParams{
		Name:      "get_jira_issue",
		Arguments: map[string]any{"key": "NOPE-1"},
	})
	if err != nil {
		t.Fatalf("call get_jira_issue: %v", err)
	}
	if !res.IsError {
		t.Fatalf("expected IsError for unknown key")
	}
}
```

- [ ] **Step 6: Implement the MCP jira tools**

Create `internal/mcp/jira.go`:
```go
package mcp

import (
	"context"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"watchtower/internal/db"
)

type listJiraIssuesArgs struct {
	Project  string `json:"project,omitempty" jsonschema:"Jira project key, e.g. ABC"`
	Status   string `json:"status,omitempty" jsonschema:"exact status name, e.g. 'In Progress'"`
	Assignee string `json:"assignee,omitempty" jsonschema:"assignee Jira account id"`
	Limit    int    `json:"limit,omitempty" jsonschema:"max results, 0 = no limit"`
}

type getJiraIssueArgs struct {
	Key string `json:"key" jsonschema:"Jira issue key, e.g. ABC-123"`
}

func registerJira(s *mcpsdk.Server, database *db.DB) {
	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name:        "list_jira_issues",
		Description: "List synced Jira issues, optionally filtered by project, status, or assignee account id.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args listJiraIssuesArgs) (*mcpsdk.CallToolResult, any, error) {
		limit := args.Limit
		if limit == 0 {
			limit = 50
		}
		issues, err := database.GetJiraIssues(db.JiraIssueFilter{
			ProjectKey:        args.Project,
			Status:            args.Status,
			AssigneeAccountID: args.Assignee,
			Limit:             limit,
		})
		if err != nil {
			return errResult("listing jira issues: " + err.Error()), nil, nil
		}
		return jsonResult(issues)
	})

	mcpsdk.AddTool(s, &mcpsdk.Tool{
		Name:        "get_jira_issue",
		Description: "Get a single Jira issue by key, including full fields.",
	}, func(ctx context.Context, req *mcpsdk.CallToolRequest, args getJiraIssueArgs) (*mcpsdk.CallToolResult, any, error) {
		issue, err := database.GetJiraIssueByKey(args.Key)
		if err != nil {
			return errResult("getting jira issue: " + err.Error()), nil, nil
		}
		if issue == nil {
			return errResult("no jira issue with key " + args.Key), nil, nil
		}
		return jsonResult(issue)
	})
}
```

Modify `internal/mcp/server.go` — in `NewServer`, after `registerPeople(s, database)`:
```go
	registerPeople(s, database)
	registerJira(s, database)
```

- [ ] **Step 7: Run the MCP jira tests to verify they pass**

Run: `cd /Users/user/PhpstormProjects/watchtower && go test ./internal/mcp/... -run 'Jira' -v`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
cd /Users/user/PhpstormProjects/watchtower
git add internal/db/jira.go internal/db/jira_test.go internal/mcp/jira.go internal/mcp/jira_test.go internal/mcp/server.go
git commit -m "feat(mcp): jira issue tools + GetJiraIssues read method"
```

---

### Task 5: `tools/list` smoke + read-only invariant test + docs

**Files:**
- Modify: `internal/mcp/server_test.go` — add `TestToolsList` and `TestAllToolsAreReadOnly`
- Create: `docs/mcp-server.md`
- Modify: `README.md` — add a pointer to the MCP server

**Interfaces:**
- Consumes (existing): `(*mcpsdk.ClientSession).ListTools(ctx, *ListToolsParams) (*ListToolsResult, error)`; `ListToolsResult.Tools` is `[]*mcpsdk.Tool` with a `Name` field.

- [ ] **Step 1: Write the smoke + invariant tests**

Add to `internal/mcp/server_test.go`:
```go
func TestToolsList(t *testing.T) {
	cs := newTestSession(t, seedDB(t))

	res, err := cs.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatalf("list tools: %v", err)
	}
	got := map[string]bool{}
	for _, tool := range res.Tools {
		got[tool.Name] = true
	}
	want := []string{
		"list_targets", "get_target",
		"get_today_briefing", "list_digests", "get_digest",
		"list_people", "get_person", "list_tracks", "get_track", "list_upcoming_events",
		"list_jira_issues", "get_jira_issue",
	}
	for _, name := range want {
		if !got[name] {
			t.Errorf("missing tool %q", name)
		}
	}
	if len(res.Tools) != len(want) {
		t.Errorf("expected exactly %d tools, got %d", len(want), len(res.Tools))
	}
}

func TestAllToolsAreReadOnly(t *testing.T) {
	// Guard the read-only invariant: every exposed tool name must be a known
	// read verb. A new write tool would have to be added here deliberately —
	// which is the point: it forces a conscious change to this guard.
	cs := newTestSession(t, seedDB(t))
	res, err := cs.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatalf("list tools: %v", err)
	}
	for _, tool := range res.Tools {
		if !strings.HasPrefix(tool.Name, "list_") &&
			!strings.HasPrefix(tool.Name, "get_") {
			t.Errorf("tool %q is not a read-only verb (list_/get_)", tool.Name)
		}
	}
}
```

Ensure `server_test.go` imports `"context"` and `"strings"`.

- [ ] **Step 2: Run the tests to verify they pass**

Run: `cd /Users/user/PhpstormProjects/watchtower && go test ./internal/mcp/... -run 'ToolsList|ReadOnly' -v`
Expected: PASS (12 tools, all `list_`/`get_`).

- [ ] **Step 3: Write the docs page**

Create `docs/mcp-server.md`:
```markdown
# Watchtower MCP Server

`watchtower mcp` runs a read-only [Model Context Protocol](https://modelcontextprotocol.io)
server over stdio. It exposes your Watchtower data — targets, briefings,
digests, people, tracks, calendar, and Jira — as tools any MCP client can use
for work context.

It is **read-only**: no tool can modify your data.

## Tools

| Tool | What it returns |
|------|-----------------|
| `list_targets` | Your action items, filterable by status/priority/level/ownership |
| `get_target` | One target by id |
| `get_today_briefing` | Your latest daily briefing |
| `list_digests` | Channel/daily/weekly Slack digests |
| `get_digest` | One digest by id |
| `list_people` | People cards |
| `get_person` | One person card by Slack user id |
| `list_tracks` | Narrative tracks |
| `get_track` | One track by id |
| `list_upcoming_events` | Calendar events in the next N hours |
| `list_jira_issues` | Synced Jira issues, filterable by project/status/assignee |
| `get_jira_issue` | One Jira issue by key |

## Add to Claude Code

```bash
claude mcp add watchtower -- watchtower mcp
```

## Add to a `.mcp.json` (Cursor, Claude Code project config, etc.)

```json
{
  "mcpServers": {
    "watchtower": {
      "command": "watchtower",
      "args": ["mcp"]
    }
  }
}
```

If `watchtower` is not on your `PATH`, use its absolute path as `command`.

## Add to Codex (`~/.codex/config.toml`)

```toml
[mcp_servers.watchtower]
command = "watchtower"
args = ["mcp"]
```

The server reads the same SQLite database the CLI uses (the active workspace's
`watchtower.db`); pass `--workspace <name>` after `mcp` to target a specific
workspace.
```

- [ ] **Step 4: Add a README pointer**

In `README.md`, add a line under the features/usage list (match the surrounding style):
```markdown
- **MCP server:** `watchtower mcp` exposes your data to any MCP client (read-only). See [docs/mcp-server.md](docs/mcp-server.md).
```

- [ ] **Step 5: Run the full Go suite**

Run: `cd /Users/user/PhpstormProjects/watchtower && go build ./... && go test ./internal/mcp/... ./internal/db/ ./cmd/`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/user/PhpstormProjects/watchtower
git add internal/mcp/server_test.go docs/mcp-server.md README.md
git commit -m "feat(mcp): tools/list + read-only invariant tests; docs"
```

---

### Task 6: Desktop TOOLS entry (informational config screen)

**Files (discover exact paths via the skill):**
- Create: `WatchtowerDesktop/Sources/Views/Tools/MCPServerView.swift`
- Modify: the `Destination` enum, sidebar TOOLS section, and routing switch (same files the existing "AI Chat" TOOLS item touches)
- Create: `WatchtowerDesktop/Tests/MCPServerViewTests.swift` (a minimal test consistent with existing Desktop tests)

**Interfaces:**
- Produces: a `.mcpServer` (or similarly named) `Destination` case + a sidebar row in the TOOLS section + an `MCPServerView`.
- Consumes (existing): the TOOLS sidebar section and `Destination` routing established by recent commits (`feat(desktop): move AI Chat to bottom of sidebar (last TOOLS item)`).

- [ ] **Step 1: Invoke the Desktop feature skill**

Use the `add-desktop-feature` skill. This screen is **informational only** (it does not run or manage the server — an external MCP client spawns `watchtower mcp`), so the Models/Queries layers are minimal; the work is a `Destination` case, a sidebar row, and a static SwiftUI view.

- [ ] **Step 2: Locate the TOOLS section + Destination enum**

Run:
```bash
cd /Users/user/PhpstormProjects/watchtower
grep -rn "case aiChat\|AI Chat\|enum Destination\|TOOLS" WatchtowerDesktop/Sources | head -30
```
Expected: the `Destination` enum, the sidebar TOOLS list, and the routing `switch`. Note the exact file paths and the pattern the AI Chat item follows.

- [ ] **Step 3: Add the `Destination` case + sidebar row**

Following the AI Chat pattern exactly (icon, label, section placement), add an `mcpServer` case to `Destination`, a TOOLS sidebar row labelled **"MCP Server"** with SF Symbol `"terminal"`, and a routing arm that shows `MCPServerView()`.

- [ ] **Step 4: Write the view**

Create `WatchtowerDesktop/Sources/Views/Tools/MCPServerView.swift`:
```swift
import SwiftUI

/// Informational screen for the read-only Watchtower MCP server.
/// It does not run the server — an external MCP client spawns `watchtower mcp`.
/// This screen only helps the user wire it up.
struct MCPServerView: View {
    private let claudeSnippet = "claude mcp add watchtower -- watchtower mcp"
    private let jsonSnippet = """
    {
      "mcpServers": {
        "watchtower": {
          "command": "watchtower",
          "args": ["mcp"]
        }
      }
    }
    """

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("MCP Server")
                    .font(.largeTitle).bold()
                Text("Expose your Watchtower data (read-only) to any MCP client — Claude Code, Cursor, Codex — so it can use your targets, briefings, digests, people, tracks, calendar, and Jira as work context.")
                    .foregroundStyle(.secondary)

                snippetBlock(title: "Add to Claude Code", text: claudeSnippet)
                snippetBlock(title: "Add to .mcp.json", text: jsonSnippet)

                Text("The server reads the same database as the app. It is read-only — no tool can modify your data.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func snippetBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label("Copy config", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }
            Text(text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
```

- [ ] **Step 5: Build & test the Desktop app**

Run:
```bash
cd /Users/user/PhpstormProjects/watchtower/WatchtowerDesktop && swift build && swift test
```
Expected: build succeeds; existing + new tests pass.

- [ ] **Step 6: Commit**

```bash
cd /Users/user/PhpstormProjects/watchtower
git add WatchtowerDesktop/Sources WatchtowerDesktop/Tests
git commit -m "feat(desktop): MCP Server config screen in TOOLS section"
```

---

## Self-Review

**Spec coverage:**
- Curated semantic tools over Watchtower product data → Tasks 1–4. ✅
- Domains: Targets (T1), Briefings+Digests (T2), People+Tracks+Calendar (T3), Jira (T4). ✅ (Inbox explicitly out of v1 per spec.)
- `watchtower mcp` stdio cobra command, config like other commands, reuse `db.Open` → T1. ✅
- Read-only enforced by tool surface (no write tool) + guard test → T1 (no writes) + T5 (`TestAllToolsAreReadOnly`). ✅
- JSON-text output, empty-not-error, not-found→isError, no panics → result helpers in T1, exercised in every domain test. ✅
- SDK pinned v1.6.1, package-name clash handled via `mcpsdk` alias → Global Constraints + T1. ✅
- Surfacing: CLI (T1) + docs config snippet (T5) + Desktop TOOLS entry (T6). ✅
- Tests: per-handler + tools/list smoke + read-only invariant → T1–T5. ✅

**Placeholder scan:** No "TBD/TODO". The `> NOTE:` blocks are not placeholders — they are explicit "verify this exact symbol against the source before relying on it" instructions for fields/helpers that exist in the codebase but whose precise names must be confirmed at the point of use (a deliberate guard against drift, not deferred work). All code steps contain complete code.

**Type consistency:** `NewServer(*db.DB) *Server`, `ServeStdio(ctx)`, `jsonResult`/`errResult`/`itoa`, and each `registerX(s *mcpsdk.Server, database *db.DB)` are used consistently across tasks. Tool names in T5's `want` list exactly match those registered in T1–T4 (12 total). `db.JiraIssueFilter`/`GetJiraIssues` defined in T4 Step 3 and consumed in T4 Step 6 with matching field names.
