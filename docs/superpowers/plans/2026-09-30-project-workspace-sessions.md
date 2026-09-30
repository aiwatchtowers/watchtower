# Project workspace — sessions, split, Work on it, standalone terminals — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Several named, resumable Claude Code sessions per project, an optional split/expandable layout, a "Work on it" button per board target, a collapsible two-level left panel, and standalone terminals.

**Architecture:** A new `terminal_sessions` table (goose, Swift-written; Go writes only the AI title) is the durable list of sessions. `ProjectTerminalCenter` becomes `TerminalCenter`, keyed by session id, launching `claude --session-id <uuid>` / `claude --resume <uuid>` / a plain shell through a pure WatchtowerCore launch builder. The Projects page gets a two-level left panel and a layout model (single / split / expanded) persisted per project in UserDefaults.

**Tech Stack:** Go 1.25 + goose + `modernc.org/sqlite`; SwiftUI (macOS 14), GRDB, SwiftTerm.

**Spec:** `docs/superpowers/specs/2026-09-30-project-workspace-sessions-design.md` — read it first; every task implements a section of it.

## Global Constraints

- Migration number: next free after `00082` → `00083_terminal_sessions.sql`; mirror into `internal/db/schema.sql`, `TestAllTablesExist`, golden snapshot (`go test ./internal/db/ -run TestSchemaGolden -update`), and the Swift test mirror `WatchtowerDesktop/Tests/Support/TestDatabase.swift`.
- Writers: Swift writes every `terminal_sessions` column; Go writes only `title` with `title_source='ai'`, never over `'user'`.
- "Work on it" prompt is the fixed template `Work on target #<id> using the watchtower-project skill.` — one integer, nothing else from the owner or the agent reaches argv.
- Standalone terminals (`project_id IS NULL`) get no project MCP, no hook, nothing written to project tables.
- The Send-comments line still never auto-submits (`ProjectCommentPrompt` unchanged).
- AI title: light tier, prompt id `terminal.title`, transcript text on stdin, never argv; tagged with `digest.WithSource(ctx, "terminal.title")`.
- Contracts PROJ-01..04 (`docs/inventory/projects.md`) and DEV-06 must stay green; PROJ-02's removal test is extended, never relaxed.
- Inner-loop testing only per task (CLAUDE.md "Agent-driven runs"); Swift work is one lane at a time.
- **Depends on Lane A** (`fix/projects-p0-bugs`, #92/#93/#74/#75/#83) being merged first for Tasks 6–11: they touch `ProjectPageView`, `ProjectsView`, `ProjectTerminalView`, `ProjectsViewModel`, `ProjectDocumentsView`.

## Review Focus

1. App restart with sessions that were live → all show "not running", nothing launches at startup, the first click resumes (`--resume`), not a fresh session.
2. A resumed id whose transcript is gone → the pane offers "Start fresh", keeps the row and title, never loops relaunching.
3. Switching sessions/projects fast while one is starting → the pane shows the selected session's view only (the #93 class: a host must swap its subview when the session changes).
4. Deleting a project with live sessions → processes are closed first, rows cascade, no orphaned `claude` process.
5. A target title containing quotes/newlines/`--flag` text → "Work on it" argv is unchanged (title never reaches argv; title shown only in the panel).

---

### Task 1: `terminal_sessions` migration + Go DB access

**Depends on:** none

**Files:**
- Create: `internal/db/migrations/00083_terminal_sessions.sql`
- Create: `internal/db/terminal_sessions.go`, `internal/db/terminal_sessions_test.go`
- Modify: `internal/db/schema.sql`, the `TestAllTablesExist` list, golden snapshot, `internal/db/projects_test.go` (`TestProj02_DeleteProjectLeavesNoRows`)

**Interfaces:**
- Produces: `type TerminalSession struct { ID int64; ProjectID sql.NullInt64; Kind, Title, TitleSource, FolderPath string; ClaudeSessionID sql.NullString }`; `func (db *DB) GetTerminalSession(id int64) (*TerminalSession, error)` (returns `ErrTerminalSessionNotFound`); `func (db *DB) SetTerminalSessionAITitle(id int64, title string) (written bool, err error)` — writes only when `title_source='auto'`.

- [ ] **Step 1: Write the migration** (use the `add-migration` skill)

```sql
-- +goose Up
-- Embedded terminal sessions (spec 2026-09-30-project-workspace-sessions).
-- project_id NULL = a standalone terminal. The Desktop writes every column;
-- Go writes only title with title_source='ai' (`watchtower terminal title`).
CREATE TABLE terminal_sessions (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id        INTEGER REFERENCES projects(id) ON DELETE CASCADE,
    kind              TEXT NOT NULL CHECK(kind IN ('claude','shell')),
    title             TEXT NOT NULL,
    title_source      TEXT NOT NULL DEFAULT 'auto' CHECK(title_source IN ('auto','ai','user')),
    target_id         INTEGER REFERENCES targets(id) ON DELETE SET NULL,
    folder_path       TEXT NOT NULL,
    claude_session_id TEXT,
    created_at        TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    last_active_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),
    closed_at         TEXT,
    CHECK (title != '' AND folder_path != ''),
    CHECK (kind = 'shell' OR claude_session_id IS NOT NULL)
);
CREATE INDEX idx_terminal_sessions_project ON terminal_sessions(project_id, last_active_at);
CREATE INDEX idx_terminal_sessions_target ON terminal_sessions(target_id);

-- +goose Down
DROP INDEX IF EXISTS idx_terminal_sessions_target;
DROP INDEX IF EXISTS idx_terminal_sessions_project;
DROP TABLE IF EXISTS terminal_sessions;
```

- [ ] **Step 2: Failing tests** in `terminal_sessions_test.go`:

```go
func TestSetTerminalSessionAITitle_NeverOverwritesUserOrAI(t *testing.T) {
	d := openTestDB(t)
	pid := newTestProject(t, d)
	for _, src := range []string{"auto", "ai", "user"} {
		res, err := d.Exec(`INSERT INTO terminal_sessions (project_id, kind, title, title_source, folder_path, claude_session_id)
			VALUES (?, 'claude', 'New session', ?, '/tmp/acme', 'uuid-'||?)`, pid, src, src)
		if err != nil { t.Fatal(err) }
		id, _ := res.LastInsertId()
		written, err := d.SetTerminalSessionAITitle(id, "Fix login")
		if err != nil { t.Fatal(err) }
		if want := src == "auto"; written != want {
			t.Fatalf("source %s: written=%v, want %v", src, written, want)
		}
	}
}

func TestGetTerminalSession_NotFound(t *testing.T) {
	d := openTestDB(t)
	if _, err := d.GetTerminalSession(999); !errors.Is(err, ErrTerminalSessionNotFound) {
		t.Fatalf("err = %v", err)
	}
}
```

Extend `TestProj02_DeleteProjectLeavesNoRows` to insert one `terminal_sessions` row for the project and assert `SELECT COUNT(*) FROM terminal_sessions WHERE project_id = ?` is 0 after `DeleteProject`; add a standalone row (`project_id NULL`) and assert it survives.

(Use the helpers that already exist in the package — `newTestProject`, and whatever `projects_test.go` uses to open a DB.)

- [ ] **Step 3: Run** `go test ./internal/db -run 'TerminalSession|Proj02'` → FAIL.
- [ ] **Step 4: Implement** `terminal_sessions.go`:

```go
var ErrTerminalSessionNotFound = errors.New("terminal session not found")

type TerminalSession struct {
	ID              int64
	ProjectID       sql.NullInt64
	Kind            string
	Title           string
	TitleSource     string
	FolderPath      string
	ClaudeSessionID sql.NullString
}

func (db *DB) GetTerminalSession(id int64) (*TerminalSession, error) {
	var s TerminalSession
	err := db.QueryRow(`SELECT id, project_id, kind, title, title_source, folder_path, claude_session_id
		FROM terminal_sessions WHERE id = ?`, id).
		Scan(&s.ID, &s.ProjectID, &s.Kind, &s.Title, &s.TitleSource, &s.FolderPath, &s.ClaudeSessionID)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrTerminalSessionNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("reading terminal session %d: %w", id, err)
	}
	return &s, nil
}

// SetTerminalSessionAITitle stores an AI title only over a provisional one:
// an owner rename ('user') and an earlier AI title ('ai') are kept.
func (db *DB) SetTerminalSessionAITitle(id int64, title string) (bool, error) {
	res, err := db.Exec(`UPDATE terminal_sessions SET title = ?, title_source = 'ai'
		WHERE id = ? AND title_source = 'auto'`, title, id)
	if err != nil {
		return false, fmt.Errorf("setting terminal session %d title: %w", id, err)
	}
	n, err := res.RowsAffected()
	return n > 0, err
}
```

Mirror the table in `schema.sql`, add `terminal_sessions` to `TestAllTablesExist`, regenerate golden.

- [ ] **Step 5: Run** `go test ./internal/db` → PASS; `make lint-diff`.
- [ ] **Step 6: Commit** `feat(db): terminal_sessions table for embedded terminal sessions`

---

### Task 2: `watchtower terminal title <id>` + `terminal.title` prompt

**Depends on:** Task 1

**Files:**
- Create: `internal/terminal/transcript.go`, `internal/terminal/transcript_test.go` (pure: find + read owner messages)
- Create: `cmd/terminal.go`, `cmd/terminal_test.go`
- Modify: `internal/prompts/defaults.go` (+ ids/versions), `internal/digest` tier table (`terminal.title` → light)

**Interfaces:**
- Produces: `func terminal.FindTranscript(claudeDir, sessionID string) (string, error)` — returns `<claudeDir>/projects/<any>/<sessionID>.jsonl`, refusing ids that are not a UUID and any match whose resolved path leaves `<claudeDir>/projects`; `func terminal.OwnerMessages(r io.Reader, capChars int) (string, error)`.
- CLI: `watchtower terminal title <id> [--json]` → `{"title": "...", "written": bool}`; no owner message yet → exit 0, `{"title":"","written":false}`.

- [ ] **Step 1: Failing tests for the transcript reader**

```go
func TestOwnerMessages_SkipsMetaCommandsAndToolResults(t *testing.T) {
	in := strings.Join([]string{
		`{"type":"mode","mode":"default"}`,
		`{"type":"user","isMeta":true,"message":{"role":"user","content":"<local-command-caveat>x</local-command-caveat>"}}`,
		`{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}}`,
		`{"type":"user","message":{"role":"user","content":[{"type":"text","text":"fix the login redirect"},{"type":"image"}]}}`,
		`{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"secret output"}]}}`,
		`{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}`,
		`{"type":"user","message":{"role":"user","content":"and add a test"}}`,
		`not json`,
	}, "\n")
	got, err := OwnerMessages(strings.NewReader(in), 2000)
	if err != nil { t.Fatal(err) }
	if got != "fix the login redirect\nand add a test" {
		t.Fatalf("got %q", got)
	}
}

func TestOwnerMessages_CapsRunes(t *testing.T) {
	in := `{"type":"user","message":{"role":"user","content":"` + strings.Repeat("я", 50) + `"}}`
	got, _ := OwnerMessages(strings.NewReader(in), 10)
	if utf8.RuneCountInString(got) != 10 { t.Fatalf("len %d", utf8.RuneCountInString(got)) }
}

func TestFindTranscript_RefusesNonUUIDAndEscapes(t *testing.T) {
	dir := t.TempDir()
	if _, err := FindTranscript(dir, "../../etc/passwd"); err == nil { t.Fatal("non-uuid accepted") }
	id := "3f2a1b4c-0000-4000-8000-000000000001"
	os.MkdirAll(filepath.Join(dir, "projects", "-tmp-acme"), 0o700)
	outside := filepath.Join(t.TempDir(), id+".jsonl")
	os.WriteFile(outside, []byte("{}"), 0o600)
	os.Symlink(outside, filepath.Join(dir, "projects", "-tmp-acme", id+".jsonl"))
	if _, err := FindTranscript(dir, id); err == nil { t.Fatal("symlink escape accepted") }
}
```

- [ ] **Step 2: Run** `go test ./internal/terminal` → FAIL.
- [ ] **Step 3: Implement** `transcript.go`:

```go
package terminal

var uuidRe = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

// FindTranscript locates Claude Code's transcript for a session id. The id is
// generated by Watchtower (a UUID), so a glob over the project folders finds
// it without re-deriving Claude Code's folder-name escaping.
func FindTranscript(claudeDir, sessionID string) (string, error) {
	if !uuidRe.MatchString(sessionID) {
		return "", fmt.Errorf("not a session id: %q", sessionID)
	}
	root, err := filepath.EvalSymlinks(filepath.Join(claudeDir, "projects"))
	if err != nil {
		return "", fmt.Errorf("claude projects dir: %w", err)
	}
	matches, _ := filepath.Glob(filepath.Join(root, "*", sessionID+".jsonl"))
	for _, m := range matches {
		resolved, err := filepath.EvalSymlinks(m)
		if err == nil && strings.HasPrefix(resolved, root+string(filepath.Separator)) {
			return resolved, nil
		}
	}
	return "", fmt.Errorf("no transcript for session %s", sessionID)
}

type transcriptLine struct {
	Type    string `json:"type"`
	IsMeta  bool   `json:"isMeta"`
	Message struct {
		Role    string          `json:"role"`
		Content json.RawMessage `json:"content"`
	} `json:"message"`
}

// OwnerMessages returns the owner's typed text, oldest first, joined by
// newlines and capped at capChars runes: meta lines, slash-command echoes,
// tool results and assistant text are left out.
func OwnerMessages(r io.Reader, capChars int) (string, error) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64*1024), 8*1024*1024)
	var parts []string
	total := 0
	for sc.Scan() && total < capChars {
		var l transcriptLine
		if json.Unmarshal(sc.Bytes(), &l) != nil || l.Type != "user" || l.IsMeta || l.Message.Role != "user" {
			continue
		}
		text := strings.TrimSpace(ownerText(l.Message.Content))
		if text == "" || strings.HasPrefix(text, "<") {
			continue
		}
		parts = append(parts, text)
		total += utf8.RuneCountInString(text) + 1
	}
	if err := sc.Err(); err != nil {
		return "", fmt.Errorf("reading transcript: %w", err)
	}
	return truncateRunes(strings.Join(parts, "\n"), capChars), nil
}

func ownerText(raw json.RawMessage) string {
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	var blocks []struct{ Type, Text string }
	if json.Unmarshal(raw, &blocks) != nil {
		return ""
	}
	var out []string
	for _, b := range blocks {
		if b.Type == "text" {
			out = append(out, b.Text)
		}
	}
	return strings.Join(out, "\n")
}

func truncateRunes(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	return string([]rune(s)[:n])
}
```

- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Prompt + CLI** — follow the `add-ai-prompt` skill for `terminal.title` (both providers, light tier in `digest.TierForSource`, registered default + version, prompt-store wiring so the scan tests stay green). System prompt text:

```
You name a terminal session from the owner's first messages to a coding agent.
Reply with only the name: 3 to 6 words, no quotes, no trailing period, in the
language the owner wrote in. Name the task, not the tool ("Fix login redirect",
not "Claude session").
```

`cmd/terminal.go` mirrors `cmd/chat.go`'s `title` command shape (generator factory seam `terminalTitleGeneratorFactory`, `cleanChatTitle`-style cleanup — reuse `cleanChatTitle` if it is package-level, cap 60 chars): read the row (`GetTerminalSession`), refuse `kind='shell'` and `title_source != 'auto'` with `written:false` and exit 0, find the transcript under `$HOME/.claude` (seam: `terminalClaudeDir`), `OwnerMessages(f, 2000)`, empty → exit 0 without a model call, else `Generate(digest.WithSource(ctx, "terminal.title"), system, user, "")` where `user` is the owner text — the generator's stdin path handles it, never argv — then `SetTerminalSessionAITitle`.

Tests in `cmd/terminal_test.go` with a fake generator: (a) no owner message → no Generate call, `written:false`; (b) `user` title → no Generate call; (c) happy path writes and returns the cleaned title; (d) unknown id → non-zero exit.

- [ ] **Step 6: Run** `go test ./internal/terminal ./internal/prompts ./internal/digest && go test ./cmd -run 'Terminal|PromptStore|TierForSource'` → PASS; `make lint-diff`.
- [ ] **Step 7: Commit** `feat(cli): terminal title — AI name for an embedded Claude Code session`

---

### Task 3: Swift model + queries for `terminal_sessions`

**Depends on:** Task 1 (schema shape)

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Models/TerminalSession.swift`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/TerminalSessionQueries.swift`
- Modify: `WatchtowerDesktop/Tests/Support/TestDatabase.swift` (mirror the table)
- Test: `WatchtowerDesktop/Tests/Core/TerminalSessionQueriesTests.swift`

**Interfaces:**
- Produces:

```swift
package struct TerminalSession: Codable, FetchableRecord, Identifiable, Equatable, Sendable {
    package enum Kind: String, Codable, Sendable { case claude, shell }
    package enum TitleSource: String, Codable, Sendable { case auto, ai, user }
    package var id: Int64
    package var projectID: Int64?
    package var kind: Kind
    package var title: String
    package var titleSource: TitleSource
    package var targetID: Int64?
    package var folderPath: String
    package var claudeSessionID: String?
    package var createdAt: String
    package var lastActiveAt: String
    package var closedAt: String?
    package var isClosed: Bool { closedAt != nil }
}

package enum TerminalSessionQueries {
    package struct NewSession: Sendable { var projectID: Int64?; var kind: TerminalSession.Kind; var title: String; var targetID: Int64?; var folderPath: String; var claudeSessionID: String? }
    package static func create(_ db: Database, _ new: NewSession) throws -> TerminalSession
    package static func fetchForProject(_ db: Database, projectID: Int64) throws -> [TerminalSession]   // last_active_at DESC
    package static func fetchStandalone(_ db: Database) throws -> [TerminalSession]                   // project_id IS NULL, last_active_at DESC
    package static func fetchForTarget(_ db: Database, targetID: Int64) throws -> [TerminalSession]    // last_active_at DESC
    package static func touch(_ db: Database, id: Int64) throws                                        // last_active_at = now
    package static func close(_ db: Database, id: Int64) throws                                        // closed_at = now
    package static func reopen(_ db: Database, id: Int64) throws                                       // closed_at = NULL, touch
    package static func rename(_ db: Database, id: Int64, title: String) throws                        // title_source = 'user'; empty title refused
    package static func replaceClaudeSessionID(_ db: Database, id: Int64, uuid: String) throws         // "Start fresh"
    package static func delete(_ db: Database, id: Int64) throws
}
```

Column mapping via `CodingKeys` (`project_id`, `title_source`, `target_id`, `folder_path`, `claude_session_id`, `created_at`, `last_active_at`, `closed_at`) — follow `ArtifactComment`'s model for the house pattern.

- [ ] **Step 1: Failing tests** (`TerminalSessionQueriesTests`): create→fetchForProject order by `last_active_at` after `touch`; `rename` sets `titleSource == .user` and refuses `""` (throws); `close` then `reopen`; `fetchStandalone` excludes project rows; deleting the project (`DELETE FROM projects`) removes its rows but not standalone ones; deleting a target sets `targetID` nil; mirror test asserts `db.tableExists("terminal_sessions")`.
- [ ] **Step 2: Run** `make test-swift FILTER=TerminalSessionQueriesTests` → FAIL.
- [ ] **Step 3: Implement** the model, queries (plain SQL in the house style of `ProjectQueries.swift`), mirror table in `TestDatabase.swift` (copy of the migration's CREATE TABLE).
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(desktop): TerminalSession model and queries`

---

### Task 4: Launch builder, Work-on-it prompt, provisional names (WatchtowerCore)

**Depends on:** Task 3

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/ProjectTerminalLaunch.swift` → rename file/type to `TerminalLaunch.swift` / `TerminalLaunch` (keep `exitMessage`, `fallbackShell`, `firstRunPrompt`)
- Modify: `WatchtowerDesktop/Tests/Core/ProjectTerminalLaunchTests.swift` → `TerminalLaunchTests.swift`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/TerminalSessionNaming.swift` + `Tests/Core/TerminalSessionNamingTests.swift`

**Interfaces:**
- Produces:

```swift
package struct TerminalLaunch: Equatable, Sendable {
    package enum Mode: Equatable, Sendable {
        case newClaude(uuid: String, prompt: String?)
        case resumeClaude(uuid: String)
        case shell
    }
    package let executable: String
    package let args: [String]
    package let currentDirectory: String
    package static func make(shell: String?, folder: String, mode: Mode) -> Self
    package static func workOnTargetPrompt(targetID: Int64) -> String   // "Work on target #\(targetID) using the watchtower-project skill."
    package static func exitMessage(code: Int32?) -> String
}

package enum TerminalSessionNaming {
    package static func provisional(now: Date, calendar: Calendar = .current) -> String   // "New session · HH:MM"
    package static func shell(shellPath: String?, folder: String) -> String               // "zsh — acme"
    package static let setupTitle = "Project setup"
}
```

- [ ] **Step 1: Failing tests** (`TerminalLaunchTests`):

```swift
func testNewClaudeWithPromptQuotesPromptAndPassesSessionID() {
    let l = TerminalLaunch.make(shell: "/bin/zsh", folder: "/tmp/acme",
        mode: .newClaude(uuid: "3f2a1b4c-0000-4000-8000-000000000001",
                         prompt: TerminalLaunch.workOnTargetPrompt(targetID: 42)))
    XCTAssertEqual(l.args, ["-l", "-c",
        "exec claude --session-id 3f2a1b4c-0000-4000-8000-000000000001 'Work on target #42 using the watchtower-project skill.'"])
    XCTAssertEqual(l.currentDirectory, "/tmp/acme")
}
func testResume() {
    let l = TerminalLaunch.make(shell: nil, folder: "/tmp/acme", mode: .resumeClaude(uuid: "3f2a1b4c-0000-4000-8000-000000000001"))
    XCTAssertEqual(l.executable, "/bin/zsh")
    XCTAssertEqual(l.args.last, "exec claude --resume 3f2a1b4c-0000-4000-8000-000000000001")
}
func testShellIsPlainLoginShell() {
    XCTAssertEqual(TerminalLaunch.make(shell: "/bin/bash", folder: "/tmp", mode: .shell).args, ["-l"])
}
func testFirstRunKeepsTheSetupPrompt() {
    let l = TerminalLaunch.make(shell: "/bin/zsh", folder: "/tmp/acme",
        mode: .newClaude(uuid: "3f2a1b4c-0000-4000-8000-000000000001", prompt: TerminalLaunch.firstRunPrompt))
    XCTAssertTrue(l.args.last!.hasSuffix("'\(TerminalLaunch.firstRunPrompt)'"))
}
func testSessionIDValidation() {
    XCTAssertTrue(TerminalLaunch.isValidSessionID("3f2a1b4c-0000-4000-8000-000000000001"))
    XCTAssertFalse(TerminalLaunch.isValidSessionID("3F2A1B4C-0000-4000-8000-000000000001"))
    XCTAssertFalse(TerminalLaunch.isValidSessionID("x; rm -rf ~"))
    XCTAssertFalse(TerminalLaunch.isValidSessionID(""))
}
func testFixedPromptsHoldNoQuote() {
    XCTAssertFalse(TerminalLaunch.firstRunPrompt.contains("'"))
    XCTAssertFalse(TerminalLaunch.workOnTargetPrompt(targetID: 9_223_372_036_854_775_807).contains("'"))
}
```

Implement `package static func isValidSessionID(_:) -> Bool` (lowercase UUID regex, same as Go's `uuidRe`). `make` does not validate; the center (Task 6) checks `isValidSessionID` before calling `make` and reports `.unavailable` otherwise. The prompt is only ever one of the two fixed constants, both free of `'`, so single-quoting is sufficient — add a test asserting neither constant contains `'`.

`TerminalSessionNamingTests`: provisional uses the injected clock (`Date(timeIntervalSince1970:)` with a UTC calendar → `"New session · 09:05"`), shell name uses the last path components (`/opt/homebrew/bin/fish`, `/Users/x/acme` → `"fish — acme"`, nil shell → `"zsh — acme"`).

- [ ] **Step 2: Run** `make test-swift FILTER=TerminalLaunchTests` and `FILTER=TerminalSessionNamingTests` → FAIL.
- [ ] **Step 3: Implement.** `make`: `.newClaude` → `"exec claude --session-id \(uuid)"` + (prompt.map { " '\($0)'" } ?? ""); `.resumeClaude` → `"exec claude --resume \(uuid)"`; `.shell` → args `["-l"]`. Update the existing call site in `ProjectTerminalCenter` minimally so the target still builds (Task 6 rewrites it).
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(desktop): TerminalLaunch modes (new/resume/shell) and session naming`

---

### Task 5: Workspace layout + session selection policies (WatchtowerCore)

**Depends on:** Task 3

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/WorkspaceLayout.swift`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/TerminalSessionPolicy.swift`
- Test: `Tests/Core/WorkspaceLayoutTests.swift`, `Tests/Core/TerminalSessionPolicyTests.swift`

**Interfaces:**
- Produces:

```swift
package enum WorkspacePane: Codable, Hashable, Sendable {
    case session(Int64)
    case board
    case documents
}

package struct WorkspaceLayout: Codable, Equatable, Sendable {
    package var primary: WorkspacePane
    package var secondary: WorkspacePane?      // nil = single pane
    package var expanded: WorkspacePane?       // non-nil = that pane alone, split remembered
    package var dividerFraction: Double        // 0.2...0.8, default 0.5
    package static let `default` = Self(primary: .board, secondary: nil, expanded: nil, dividerFraction: 0.5)
    package var isSplit: Bool { secondary != nil }
    package var visiblePanes: [WorkspacePane]  // expanded → [expanded]; else [primary] + secondary
    package mutating func split(with pane: WorkspacePane)   // no-op if pane == primary
    package mutating func unsplit()                         // keeps primary, clears secondary + expanded
    package mutating func toggleExpand(_ pane: WorkspacePane)
    package mutating func show(_ pane: WorkspacePane)       // panel click: if visible → no-op; else replaces the primary (single) or the secondary (split)
    package mutating func forgetSession(_ id: Int64, fallback: WorkspacePane)  // a deleted session never stays in the layout
    package static func key(projectID: Int64) -> String     // "projects.layout.<id>"
    package static func decode(_ data: Data?) -> Self       // bad/missing data → .default, dividerFraction clamped
}

package enum TerminalSessionPolicy {
    /// Send-comments destination: the most recently focused live claude session.
    package static func activeSession(_ sessions: [TerminalSession], live: Set<Int64>, lastFocused: [Int64]) -> TerminalSession?
    /// "Work on it": most recently active session for the target, or nil (create one).
    package static func sessionForTarget(_ targetID: Int64, in sessions: [TerminalSession]) -> TerminalSession?
    /// Sessions that still need an AI title attempt.
    package static func needsTitle(_ s: TerminalSession, attempts: Int) -> Bool   // kind == .claude && titleSource == .auto && targetID == nil && attempts < 5
}
```

- [ ] **Step 1: Failing tests.** Layout: `split(with:)` then `toggleExpand(.board)` → `visiblePanes == [.board]`, toggle again → both back; `unsplit` keeps primary; `show(.documents)` in single mode replaces primary, in split replaces secondary, on a visible pane is a no-op; `forgetSession(7, fallback: .board)` removes `.session(7)` from any slot (a split whose secondary was it becomes single; an expanded one clears); JSON round-trip; `decode(Data("junk".utf8)) == .default`; fraction 1.5 decodes clamped to 0.8. Policy: `activeSession` prefers the last element of `lastFocused` that is live and `.claude`, falls back to the most recently active live claude session, nil when none live; `sessionForTarget` picks the highest `lastActiveAt` among rows with that target id (closed ones included); `needsTitle` table test incl. `attempts == 5` → false and `.shell` → false.
- [ ] **Step 2: Run** filtered → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(desktop): workspace layout and terminal session policies`

---

### Task 6: `TerminalCenter` keyed by session

**Depends on:** Tasks 4, 5, **Lane A merged**

**Files:**
- Rename/modify: `WatchtowerDesktop/Sources/Services/ProjectTerminalCenter.swift` → `TerminalCenter.swift` (protocol `ProjectTerminalSession` → `TerminalSessionProcess`, `SwiftTermSession` stays)
- Modify: `Sources/App/AppState.swift` (`let terminalCenter = TerminalCenter()`), `QuitCoordinator` call site, `ProjectsViewModel` delete path, every reference found by `grep -rn "projectTerminalCenter\|ProjectTerminalCenter" WatchtowerDesktop/Sources WatchtowerDesktop/Tests`
- Test: `Tests/ProjectTerminalCenterTests.swift` → `Tests/TerminalCenterTests.swift`

**Interfaces:**
- Consumes: `TerminalLaunch.make(shell:folder:mode:)`, `TerminalLaunch.isValidSessionID`, `TerminalSession`.
- Produces:

```swift
@MainActor @Observable final class TerminalCenter {
    enum State: Equatable { case running, exited(Int32?), unavailable(String) }
    private(set) var states: [Int64: State]            // key = terminal_sessions.id
    private(set) var clipboardHints: Set<Int64>
    private(set) var focusOrder: [Int64]               // most recent last; fed to TerminalSessionPolicy.activeSession
    var liveIDs: Set<Int64> { get }                    // states == .running
    func process(for sessionID: Int64) -> (any TerminalSessionProcess)?
    /// Starts the row's process unless running. A claude row with a stored uuid
    /// that has run before resumes; `fresh: true` (first start / Start fresh) uses --session-id.
    func start(_ session: TerminalSession, fresh: Bool, prompt: String? = nil)
    func focus(_ sessionID: Int64)
    func sendPrompt(_ line: String, sessionID: Int64) -> PromptDelivery
    func dismissClipboardHint(sessionID: Int64)
    func close(sessionID: Int64) async
    func closeAll(where predicate: (Int64) -> Bool = { _ in true }) async
}
```

- [ ] **Step 1: Port the existing tests** to session ids, then add failing ones (fake process from the existing test file): two sessions of one project run at once and `close(sessionID: a)` signals only `a`'s pid; `start` on an invalid uuid → `.unavailable("…")`, nothing launched; `start(fresh: false)` launch args contain `--resume`, `fresh: true` + prompt contain `--session-id` and the prompt; missing folder → `.unavailable`; `.shell` row launches `["-l"]`; `closeAll(where:)` closes only matching ids (used by project delete); `focus` moves an id to the end of `focusOrder` without duplicates.
- [ ] **Step 2: Run** `make test-swift FILTER=TerminalCenterTests` → FAIL.
- [ ] **Step 3: Implement** by rekeying the existing class (logic of `close`/`closeAll`/`sendPrompt` unchanged, dictionary keys become session ids). Project creation's first run (`ProjectsViewModel.createProject`) now creates a `TerminalSession` row (title `TerminalSessionNaming.setupTitle`, new UUID) and calls `start(row, fresh: true, prompt: TerminalLaunch.firstRunPrompt)`. `deleteProject` calls `closeAll { sessionIDsOfProject.contains($0) }` before `project delete`. Keep `ProjectTerminalView` compiling against the new API by showing the project's active session (Task 8 replaces the view).
- [ ] **Step 4: Run** `TerminalCenterTests`, `ProjectsViewModelDeleteTests` → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `refactor(desktop): TerminalCenter keyed by terminal session`

---

### Task 7: Sessions in `ProjectsViewModel` (create / resume / close / delete / rename / title refresh)

**Depends on:** Task 6

**Files:**
- Modify: `WatchtowerDesktop/Sources/ViewModels/ProjectsViewModel.swift` (or a focused extension file `ProjectsViewModel+Sessions.swift` if the VM would pass ~400 lines)
- Create: `WatchtowerDesktop/Sources/Services/TerminalTitleService.swift` (runs `watchtower terminal title <id> --json` via the existing CLI runner used by `ProjectCLI.swift`)
- Test: `Tests/ProjectsViewModelSessionsTests.swift`

**Interfaces:**
- Consumes: `TerminalSessionQueries`, `TerminalCenter`, `TerminalSessionPolicy`, `WorkspaceLayout`.
- Produces on the VM (all `@MainActor`):

```swift
var sessions: [TerminalSession]                 // selected project's, refreshed by reload / after every write
var standaloneSessions: [TerminalSession]
var layout: WorkspaceLayout                     // selected project's; didSet persists to UserDefaults (WorkspaceLayout.key)
var drilledProjectID: Int64?                    // left panel level 2 (nil = level 1)
func newSession(projectID: Int64) async
func newStandalone(kind: TerminalSession.Kind, folder: URL) async
func open(_ session: TerminalSession) async     // reopen if closed, start (resume) if not running, focus, layout.show(.session(id))
func workOn(targetID: Int64, targetText: String) async   // TerminalSessionPolicy.sessionForTarget → open, else create(title: targetText, targetID) + start(fresh: true, prompt: workOnTargetPrompt)
func startFresh(_ session: TerminalSession) async        // new uuid, replaceClaudeSessionID, start(fresh: true)
func close(_ session: TerminalSession) async             // center.close + TerminalSessionQueries.close
func delete(_ session: TerminalSession) async            // close first, then delete row, layout.forgetSession
func rename(_ session: TerminalSession, to title: String) async
func activeSessionID(projectID: Int64) -> Int64?         // TerminalSessionPolicy.activeSession
func refreshTitles() async                               // for each needsTitle session: TerminalTitleService; attempts counted in memory per session id
```

Title refresh triggers (spec §5): `open` of a different session (for the one switched away from), `close`, and a 2-minute `Task` loop started by `initProjects` while the app runs (the `ProjectNotificationCenter` poll shape). The service's failure is logged (`Log`/`os_log` as the VM already does) and never surfaces as `errorMessage`.

Resume failure: if a `resumeClaude` process exits within 3 s with a non-zero code, the pane (Task 9) offers "Start fresh" — the VM exposes `var resumeFailed: Set<Int64>` set from the center's `.exited` state + a launch timestamp.

- [ ] **Step 1: Failing tests** (fake center session factory + `TestDatabase.createPool()` + a fake title service closure): `workOn` twice for the same target creates one row and the second call focuses it; `workOn` for a target with only a closed session reopens and resumes it (launch args contain `--resume`); `delete` of a running session closes it before the row goes and removes it from `layout`; `rename("")` leaves the title; `refreshTitles` calls the service only for `needsTitle` rows and stops after 5 attempts; the "started → navigated away → result arrives" rule: a `newSession` for project A finishing after the owner selected project B does not change B's `sessions`/`layout`; layout persisted per project (select A, split; select B, single; back to A → split).
- [ ] **Step 2: Run** `make test-swift FILTER=ProjectsViewModelSessionsTests` → FAIL.
- [ ] **Step 3: Implement.** UUIDs: `UUID().uuidString.lowercased()`.
- [ ] **Step 4: Run** → PASS; also `FILTER=ProjectsViewModel` for the existing suites.
- [ ] **Step 5: Commit** `feat(desktop): project sessions in ProjectsViewModel`

---

### Task 8: Two-level collapsible left panel + Terminals section (#73, #77, #103 entry)

**Depends on:** Task 7

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Projects/ProjectsView.swift`
- Create: `WatchtowerDesktop/Sources/Views/Projects/ProjectSessionsPanel.swift` (level 2), `WatchtowerDesktop/Sources/Views/Projects/TerminalsSection.swift` (level-1 standalone list + New terminal menu)

Behaviour (spec §3):
- Toolbar button `Image(systemName: "sidebar.leading")` toggles `@AppStorage("projects.panelVisible")` (default `true`) with `withAnimation(.easeInOut(duration: 0.2))` — the `ChatView` `chat.historyVisible` pattern.
- Level 1: the existing project list (badges unchanged), then a "Terminals" section listing `vm.standaloneSessions` (title, live dot) and a "New terminal" `Menu` → "Claude Code in Home", "Claude Code in Folder…", "Shell in Home", "Shell in Folder…" (NSOpenPanel for the folder, directories only) → `vm.newStandalone`.
- Clicking a project sets `selectedProjectID` and `drilledProjectID`. Level 2: `Button { vm.drilledProjectID = nil } label: { Label("Projects", systemImage: "chevron.backward") }`, project name, rows "Board" and "Documents" (→ `vm.layout.show(.board/.documents)`), then `vm.sessions` (live = `terminalCenter.liveIDs.contains(id)` → filled dot; closed rows `.foregroundStyle(.secondary)`; target sessions show `#<targetID>` caption), "New session" button. Context menu per session: Rename… (sheet with a TextField), Close (disabled when not live), Delete (confirmation).
- Selecting a standalone terminal clears `selectedProjectID` and shows it single-pane (spec: standalone always single).

- [ ] **Step 1:** Implement the views (no logic beyond calling VM methods — logic lives in Tasks 5/7).
- [ ] **Step 2:** Build: `cd WatchtowerDesktop && swift build > /tmp/build.log 2>&1; echo "exit=$?"` → exit 0; `make lint-diff`.
- [ ] **Step 3:** Screenshot check via the `run` skill (launch `make app-dev`, open Projects, drill into a project, collapse/expand the panel) and attach what you saw to the task report.
- [ ] **Step 4: Commit** `feat(desktop): two-level collapsible project panel with sessions and terminals`

---

### Task 9: Main area — single / split / expand, per-project layout; Send comments to the active session (#86)

**Depends on:** Task 8

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Projects/ProjectPageView.swift` (drop the segmented `Picker`; render `vm.layout.visiblePanes`)
- Modify: `WatchtowerDesktop/Sources/Views/Projects/ProjectTerminalView.swift` → shows one `TerminalSession` (argument `session: TerminalSession`), states from `terminalCenter.states[session.id]`, "Resume" on `.exited`, "Start fresh" when `vm.resumeFailed.contains(session.id)`; the `TerminalHost` must **replace** its container's subviews when the session changes (`container.subviews.forEach { $0.removeFromSuperview() }` before adding) and be `.id(session.id)` — Review Focus 3
- Modify: `WatchtowerDesktop/Sources/Views/Projects/ProjectDocumentsView.swift`, `ProjectCommentsSendBar.swift` (send to `vm.activeSessionID(projectID:)`; switch panes only when no terminal pane is visible: `vm.layout.show(.session(id))` is already a no-op for a visible pane)
- Create: `WatchtowerDesktop/Sources/Views/Projects/WorkspacePaneView.swift` (one pane: header with a pane `Menu` picker — sessions, Board, Documents — plus expand button `arrow.up.left.and.arrow.down.right` / `arrow.down.right.and.arrow.up.left`)

Behaviour: toolbar "Split" toggle (`rectangle.split.2x1`) → `vm.layout.split(with:)` defaulting the second pane to Board if the primary is a session, else to the active session (or Board if none); split renders an `HSplitView` (or a `GeometryReader` + draggable divider if `HSplitView` cannot restore `dividerFraction` — prefer the simplest that restores the fraction); unsplit button in the secondary pane header. Header (name, folder, install badge, Delete) unchanged.

- [ ] **Step 1:** Implement.
- [ ] **Step 2:** `make test-swift FILTER=ProjectCommentPrompt` (existing) + `FILTER=WorkspaceLayoutTests` → PASS; build exit 0; `make lint-diff`.
- [ ] **Step 3:** Manual check via the `run` skill: split Terminal|Board, expand the board, collapse back, switch project and back (layout restored), Send comments while split (terminal stays, no pane switch), switch between two sessions quickly (the pane shows the selected session — Review Focus 3).
- [ ] **Step 4: Commit** `feat(desktop): split and expandable project panes with per-project layout`

---

### Task 10: "Work on it" on board rows (#87)

**Depends on:** Task 9

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Projects/ProjectBoardView.swift` (row trailing button)
- Test: extend `Tests/ProjectsViewModelSessionsTests.swift` if anything new lands in the VM (it should not — Task 7 has `workOn`)

Behaviour: each row (target and sub-target) gets `Button { Task { await vm.workOn(targetID: t.id, targetText: t.text) } } label: { Label("Work on it", systemImage: "play.circle") }.labelStyle(.iconOnly).help(existing ? "Open its session" : "Start a Claude Code session for this target")`, visible on hover and on the selected row; `existing` = `TerminalSessionPolicy.sessionForTarget(t.id, in: vm.sessions) != nil` (icon `arrow.right.circle` then). After the call the session is shown via `layout.show` (Task 7), so in split mode the board stays visible next to the new terminal.

- [ ] **Step 1:** Implement. **Step 2:** build exit 0, `make lint-diff`. **Step 3:** manual: Work on it → a session named after the target starts and Claude receives the prompt; second press switches to it; a target with a quote in its title still launches the fixed prompt.
- [ ] **Step 4: Commit** `feat(desktop): Work on it — start or open a session for a board target`

---

### Task 11: Standalone terminal pane (#103)

**Depends on:** Task 8

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Projects/ProjectsView.swift` (detail shows a standalone session when one is selected)
- Reuse: `ProjectTerminalView` (now session-based) — rename to `TerminalSessionView` if it no longer mentions projects

Behaviour: a selected standalone session renders single-pane with a slim header (title, folder, Close, Delete); no install badge, no Board/Documents. Its launch never includes project flags (Task 4 has no project-specific args at all — the project MCP/hook come from the folder's own local config, spec §2).

- [ ] **Step 1:** Implement. **Step 2:** build exit 0, `make lint-diff`. **Step 3:** manual: new Shell in Home runs a login shell; new Claude Code in a folder starts Claude; quit the app → both processes gone (`pgrep -f "claude --session-id"` empty).
- [ ] **Step 4: Commit** `feat(desktop): standalone terminals in the Projects panel`

---

### Task 12: Docs and contracts

**Depends on:** Tasks 1–11

**Files:**
- Modify: `CLAUDE.md` ("Projects" section: sessions table, TerminalCenter, layout, Work on it, standalone terminals, `terminal title`), `docs/inventory/projects.md` (PROJ-02 now names `terminal_sessions`; a changelog line), `docs/app-guide.md` (Projects page), the spec's status line.

- [ ] **Step 1:** Edit the docs. **Step 2:** `make lint-diff`. **Step 3: Commit** `docs: project workspace sessions`

---

## Phase gate (controller, once, after Task 12)

`make test`, `make test-swift`, `make lint-all`, then the `local-review` skill's final-PR path (debate-review) and a PR into main.
