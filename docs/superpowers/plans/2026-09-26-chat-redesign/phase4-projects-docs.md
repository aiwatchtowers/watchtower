# Chat Redesign — Phase 4: Projects, mentions, skills, docs (Tasks 24–27)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the main AI Chat projects (instructions, pinned sources, files, their chats), `@`-mentions over the local DB, a `/` skill picker, and ship the contracts and docs for the whole redesign.

**Architecture:** Projects are Swift-written rows (`chat_projects`, `chat_project_sources`, project-owned `chat_attachments`) that Go reads through `db.GetChatProjectContext` when a session starts: text files and sources go into the prompt (Task 5), binary files are attached by the Go Claude backend to the first turn of every fresh provider session (this phase, Task 24A) — Swift sends nothing extra. Mentions and skills are composer-only features: a pure Core tokenizer + search + picker model, a stored-turn format owned by `ChatTurnComposer`, and two small hooks in the existing `NSTextView` composer.

**Tech Stack:** Go 1.25 (`internal/chat`, `cmd`), SwiftUI macOS 14+, GRDB 7, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-26-chat-redesign-design.md` (§6, §9, §11). **Skeleton with binding interfaces:** `docs/superpowers/plans/2026-09-26-chat-redesign.md` — read its Global Constraints; every task below implicitly includes them.

## Interface assumptions from earlier phases

This phase is written in parallel with Phases 1–3. It consumes these names from the skeleton's binding interfaces. **Before starting each task, run the task's Step 0 grep.** If an earlier task landed a name differently, adapt the code in THIS phase to the real name — never rename an earlier task's API.

- Task 1 (Go): `type ChatProjectContext struct{ Name, Instructions string; Sources []ChatProjectSource; TextFiles []ChatProjectFile; BinaryFiles []ChatProjectFile }`, `func (db *DB) GetChatProjectContext(projectID int64) (*ChatProjectContext, error)`. Assumed `ChatProjectFile` fields: `Name, Mime, Path string; Size int64`. `BinaryFiles` = images and PDFs of the project; `TextFiles` = text-like files.
- Task 1 (schema): `chat_projects(id, name, instructions, created_at, updated_at, archived_at)` with REAL unix timestamps (the chat tables' convention), `chat_project_sources(id, project_id, kind, ref, label)` with `kind IN ('jira_project','slack_channel','target','track','person')`, `chat_attachments(…, project_id FK cascade, …)`, `chat_conversations.project_id … ON DELETE SET NULL`, `chat_conversations.archived_at REAL`. Mirrored in `WatchtowerDesktop/Tests/Support/TestDatabase.swift` by Task 10, so `TestDatabase.create()` has every chat table.
- Task 2 (Go): `type Attachment struct{ Path, Mime, Name string }`, `type Command struct{ Type, TurnID, Text string; Attachments []Attachment; Replay bool }`.
- Task 7 (Go): `type ClaudeOptions struct{ … }` (the resume field is called `ResumeSessionID` below — use Task 7's actual field name), the concrete backend type returned by `NewClaudeBackend` (called `*claudeBackend` below), `cmd/ai_session.go` building `ClaudeOptions` when `--provider` is claude.
- Task 10 (Swift): `ChatConversation` gains `projectID: Int64?` and `archivedAt: Double?`; models `ChatProject`, `ChatProjectSource`, `ChatAttachment` in `Sources/WatchtowerCore/Models/ChatModels.swift` (Task 24 Step B0 adds them if absent); `ChatConversationQueries.setProject(_:id:projectID:)`.
- Task 11 (Swift): `ChatSessionPool.session(for:config:)`; the config value type is called `ChatSessionConfig` below and its argv builder `ChatSessionClient.arguments(for:dbPath:)`.
- Task 14 (Swift): `ChatViewModel` API `send(text:attachments:mentions:)`, `edit(messageID:newText:)`, `select(conversationID:)`, `newConversation(projectID:)`; its test fixture (called `makeViewModel()` + a fake session process capturing sent commands below).
- Task 15 (Swift): `Views/Chat/ChatSidebarView.swift` with a Projects header slot; the main-chat composer instantiates `ChatInput(...)`.
- Task 21 (Swift): `ChatAttachmentStore.importFile(url:projectID:) throws -> ChatAttachment` (and the `conversationID:` twin), `AttachmentValidator`.

## Phase-specific review focus

1. A project file deleted from disk behind the app's back must not break every turn of every chat in that project → Task 24A skips missing files (test `TestProjectAttachments_SkipsMissingFile`).
2. `@` inside an email address (`anna@example.com`) or a `/` inside a path (`see /usr/bin`) must not open a picker → Task 25/26 tokenizer tests.
3. Editing a user message that carried mentions or a skill must keep them → `ChatTurnComposer.recompose` test (Task 25).
4. A Cyrillic lower-case query (`ива`) must find `Иван` (SQLite `LIKE` folds ASCII only) → Task 24C test.
5. `%`/`_` typed into the picker must not match everything → Task 24C wildcard-escape test.

---

### Task 24: Projects

Split into five commits (A–E). Each part ends green.

**Files:**
- Create: `internal/chat/project_attachments.go`, `internal/chat/project_attachments_test.go`
- Modify: `internal/chat/claude_backend.go` (Task 7), `internal/chat/claude_backend_test.go` (Task 7), `cmd/ai_session.go` (Task 7)
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ChatProjectQueries.swift`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ChatEntitySearch.swift`
- Modify (only if Step B0 finds them missing): `WatchtowerDesktop/Sources/WatchtowerCore/Models/ChatModels.swift`
- Create: `WatchtowerDesktop/Sources/ViewModels/ProjectDetailViewModel.swift`
- Create: `WatchtowerDesktop/Sources/Views/Chat/ProjectDetailView.swift`, `WatchtowerDesktop/Sources/Views/Chat/ProjectSourcePickerSheet.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Chat/ChatSidebarView.swift` (Task 15), `WatchtowerDesktop/Sources/Views/Chat/ChatView.swift`, `WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift` (Task 14), `WatchtowerDesktop/Sources/Services/Chat/ChatSessionClient.swift` (Task 11)
- Test: `WatchtowerDesktop/Tests/Core/ChatProjectQueriesTests.swift`, `WatchtowerDesktop/Tests/Core/ChatEntitySearchTests.swift`, `WatchtowerDesktop/Tests/ProjectDetailViewModelTests.swift`, `WatchtowerDesktop/Tests/ChatSessionClientTests.swift` (Task 11 file), `WatchtowerDesktop/Tests/ChatViewModelTests.swift` (Task 14 file)

**Interfaces:**
- Consumes: see "Interface assumptions" (Tasks 1, 2, 7, 10, 11, 14, 15, 21).
- Produces (Go): `func ProjectAttachments(pc *db.ChatProjectContext, warn io.Writer) []Attachment`; `ClaudeOptions.ProjectAttachments []Attachment`; `func initialProjectPending(opts ClaudeOptions) bool`; `func (b *claudeBackend) turnAttachments(cmd Command) []Attachment`.
- Produces (Swift, Core): `ChatProjectQueries.fetchActive/fetchByID/create/rename/updateInstructions/archive/delete/sources/addSource/removeSource/files/removeFile/conversations`; `ChatEntityKind`, `ChatEntityHit`, `ChatEntitySearch.people/channels/jiraIssues/jiraProjects/targets/tracks/search(_:kind:query:limit:)`, `ChatEntitySearch.defaultLimit = 8`; `ChatProjectSource.Kind(entity:)`.
- Produces (Swift, app): `ProjectDetailViewModel`; `ChatViewModel.openProjectID`, `openProject(_:)`, `projects`, `reloadProjects()`, `createProject(name:) -> Int64?`; `ChatSessionConfig.projectID` → `--project-id`.

#### Part A — Go: project binary files on the first turn of a fresh provider session (addendum to Tasks 7/20)

Decision (spec §6.1 leaves the side open): **Go attaches them.** `ai session --project-id K` already loads the project context for the prompt; the Claude backend prepends the project's binary files to the first `turn` it writes to a freshly started `claude` child (a `Start` without `--resume`, the replay restart, the `session_lost` retry). Swift sends nothing extra, so no Swift code knows which turn is "first". A `--resume`d child does not re-attach (its history already holds the blocks). Codex/Ollama never receive them (they would fail `attachment_unsupported`); the prompt's project block still lists the files by name.

- [ ] **Step A0: Confirm the Task 7/20 names**

Run: `grep -n "type ClaudeOptions\|type claudeBackend\|func NewClaudeBackend\|BuildContentBlocks\|Resume" internal/chat/claude_backend.go`
Expected: the options struct, the backend struct, the resume field, and the call to `BuildContentBlocks(cmd.Attachments)` inside `Turn`. Use those names below.

- [ ] **Step A1: Write the failing tests**

Create `internal/chat/project_attachments_test.go`:

```go
package chat

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"watchtower/internal/db"
)

func writeTempFile(t *testing.T, dir, name string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestProjectAttachments_NilAndEmpty(t *testing.T) {
	var warn bytes.Buffer
	if got := ProjectAttachments(nil, &warn); got != nil {
		t.Fatalf("nil context: want nil, got %v", got)
	}
	if got := ProjectAttachments(&db.ChatProjectContext{Name: "p"}, &warn); got != nil {
		t.Fatalf("no binary files: want nil, got %v", got)
	}
	if warn.Len() != 0 {
		t.Fatalf("no warnings expected, got %q", warn.String())
	}
}

func TestProjectAttachments_MapsBinaryFilesInOrder(t *testing.T) {
	dir := t.TempDir()
	png := writeTempFile(t, dir, "a.png")
	pdf := writeTempFile(t, dir, "b.pdf")
	pc := &db.ChatProjectContext{BinaryFiles: []db.ChatProjectFile{
		{Name: "diagram.png", Mime: "image/png", Path: png, Size: 1},
		{Name: "spec.pdf", Mime: "application/pdf", Path: pdf, Size: 1},
	}}
	var warn bytes.Buffer
	got := ProjectAttachments(pc, &warn)
	want := []Attachment{
		{Path: png, Mime: "image/png", Name: "diagram.png"},
		{Path: pdf, Mime: "application/pdf", Name: "spec.pdf"},
	}
	if len(got) != len(want) {
		t.Fatalf("want %d attachments, got %d: %v", len(want), len(got), got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("attachment %d: want %+v, got %+v", i, want[i], got[i])
		}
	}
}

// A file removed from disk behind the app's back must not fail every turn of
// every chat in the project: it is skipped and named on the warn writer.
func TestProjectAttachments_SkipsMissingFile(t *testing.T) {
	dir := t.TempDir()
	png := writeTempFile(t, dir, "a.png")
	pc := &db.ChatProjectContext{BinaryFiles: []db.ChatProjectFile{
		{Name: "gone.pdf", Mime: "application/pdf", Path: filepath.Join(dir, "gone.pdf")},
		{Name: "diagram.png", Mime: "image/png", Path: png},
	}}
	var warn bytes.Buffer
	got := ProjectAttachments(pc, &warn)
	if len(got) != 1 || got[0].Name != "diagram.png" {
		t.Fatalf("want only diagram.png, got %v", got)
	}
	if !strings.Contains(warn.String(), "gone.pdf") {
		t.Fatalf("warning must name the skipped file, got %q", warn.String())
	}
}
```

Append to `internal/chat/claude_backend_test.go`:

```go
func TestClaudeBackend_ProjectAttachmentsOnlyOnFreshSessionFirstTurn(t *testing.T) {
	proj := []Attachment{{Path: "/p/spec.pdf", Mime: "application/pdf", Name: "spec.pdf"}}
	own := Attachment{Path: "/c/shot.png", Mime: "image/png", Name: "shot.png"}
	b := &claudeBackend{opts: ClaudeOptions{ProjectAttachments: proj}}
	b.projectPending = initialProjectPending(b.opts)

	first := b.turnAttachments(Command{Type: "turn", Attachments: []Attachment{own}})
	if len(first) != 2 || first[0] != proj[0] || first[1] != own {
		t.Fatalf("first turn: want project file then own attachment, got %v", first)
	}
	// Not cleared until the turn was actually written to the child.
	again := b.turnAttachments(Command{Type: "turn"})
	if len(again) != 1 || again[0] != proj[0] {
		t.Fatalf("unsent first turn must still carry the project file, got %v", again)
	}
	b.projectSent()
	second := b.turnAttachments(Command{Type: "turn", Attachments: []Attachment{own}})
	if len(second) != 1 || second[0] != own {
		t.Fatalf("second turn: want only own attachment, got %v", second)
	}
	// A replay / session_lost restart is a fresh provider session again.
	b.markFreshSession()
	third := b.turnAttachments(Command{Type: "turn"})
	if len(third) != 1 || third[0] != proj[0] {
		t.Fatalf("after a fresh restart the project file must be re-attached, got %v", third)
	}
}

func TestClaudeBackend_ResumedSessionDoesNotReattachProjectFiles(t *testing.T) {
	opts := ClaudeOptions{
		ProjectAttachments: []Attachment{{Path: "/p/spec.pdf", Mime: "application/pdf", Name: "spec.pdf"}},
		ResumeSessionID:    "sid-1",
	}
	if initialProjectPending(opts) {
		t.Fatal("a --resume'd session already holds the project files in its history")
	}
	opts.ResumeSessionID = ""
	if !initialProjectPending(opts) {
		t.Fatal("a fresh session with project files must attach them")
	}
	opts.ProjectAttachments = nil
	if initialProjectPending(opts) {
		t.Fatal("no project files, nothing pending")
	}
}
```

- [ ] **Step A2: Run tests to verify they fail**

Run: `go test ./internal/chat -run 'TestProjectAttachments|TestClaudeBackend_ProjectAttachments|TestClaudeBackend_Resumed'`
Expected: FAIL — `undefined: ProjectAttachments`, `unknown field ProjectAttachments`, `undefined: initialProjectPending`.

- [ ] **Step A3: Implement `ProjectAttachments`**

Create `internal/chat/project_attachments.go`:

```go
package chat

import (
	"fmt"
	"io"
	"os"

	"watchtower/internal/db"
)

// ProjectAttachments turns a chat project's binary files (images, PDFs) into
// the attachments the Claude backend sends on the first turn of every fresh
// provider session (spec §6.1). Text files are not here: they ride the system
// prompt's project block (BuildSystemPrompt, block 8).
//
// A file no longer on disk is skipped and named on warn instead of failing:
// one stale row must not break every turn of every chat in the project, and
// the project page still lists it for the owner to remove.
func ProjectAttachments(pc *db.ChatProjectContext, warn io.Writer) []Attachment {
	if pc == nil || len(pc.BinaryFiles) == 0 {
		return nil
	}
	out := make([]Attachment, 0, len(pc.BinaryFiles))
	for _, f := range pc.BinaryFiles {
		if _, err := os.Stat(f.Path); err != nil {
			fmt.Fprintf(warn, "chat project file %q skipped: %v\n", f.Name, err)
			continue
		}
		out = append(out, Attachment{Path: f.Path, Mime: f.Mime, Name: f.Name})
	}
	if len(out) == 0 {
		return nil
	}
	return out
}
```

- [ ] **Step A4: Wire it into the Claude backend**

In `internal/chat/claude_backend.go`:

1. Add to `ClaudeOptions`:

```go
	// ProjectAttachments are the project's binary files. They are sent ahead
	// of the owner's own attachments on the first turn of every fresh
	// provider session — never on a --resume, whose history already holds
	// them (spec §6.1).
	ProjectAttachments []Attachment
```

2. Add to the backend struct: `projectPending bool` (with the comment `// true until the first turn of the current provider session is written`).

3. Add:

```go
// initialProjectPending reports whether the first turn of a newly started
// child must carry the project files.
func initialProjectPending(opts ClaudeOptions) bool {
	return opts.ResumeSessionID == "" && len(opts.ProjectAttachments) > 0
}

// markFreshSession is called wherever the backend starts a child WITHOUT
// --resume after Start (the replay restart, the session_lost retry).
func (b *claudeBackend) markFreshSession() {
	b.projectPending = len(b.opts.ProjectAttachments) > 0
}

// projectSent clears the pending flag once a turn carrying the project
// files has been written to the child's stdin.
func (b *claudeBackend) projectSent() { b.projectPending = false }

// turnAttachments is the attachment list for one turn: the project files
// first (when pending), then the owner's own.
func (b *claudeBackend) turnAttachments(cmd Command) []Attachment {
	if !b.projectPending {
		return cmd.Attachments
	}
	out := make([]Attachment, 0, len(b.opts.ProjectAttachments)+len(cmd.Attachments))
	out = append(out, b.opts.ProjectAttachments...)
	return append(out, cmd.Attachments...)
}
```

4. In `Start`, after the child is up: `b.projectPending = initialProjectPending(b.opts)`.
5. In every code path that starts a new child without `--resume` (grep `ResumeSessionID = ""` / the replay branch / the `session_lost` retry): call `b.markFreshSession()` right after the child is up.
6. In `Turn`, replace `BuildContentBlocks(cmd.Attachments)` with `BuildContentBlocks(b.turnAttachments(cmd))`, and after the user message line has been written to the child's stdin without error, call `b.projectSent()`.

- [ ] **Step A5: Load the files in `ai session`**

In `cmd/ai_session.go`, where `ClaudeOptions` is built (claude provider only), after the database is open:

```go
	if projectID > 0 {
		pc, err := database.GetChatProjectContext(projectID)
		if err != nil {
			return fmt.Errorf("loading chat project %d: %w", projectID, err)
		}
		claudeOpts.ProjectAttachments = chat.ProjectAttachments(pc, cmd.ErrOrStderr())
	}
```

(`projectID`, `database`, `claudeOpts` are the local names in Task 7's `runAISession`; use its actual names.) The turn backend (codex/ollama, Task 8) is untouched.

- [ ] **Step A6: Run tests to verify they pass**

Run: `go test ./internal/chat ./cmd -run 'TestProjectAttachments|TestClaudeBackend|TestAISession'`
Expected: PASS (the Task 7 session tests still pass — `ProjectAttachments` is empty there).

- [ ] **Step A7: Commit**

```bash
git add internal/chat/project_attachments.go internal/chat/project_attachments_test.go internal/chat/claude_backend.go internal/chat/claude_backend_test.go cmd/ai_session.go
git commit -m "feat(chat): attach project binary files on a fresh provider session's first turn

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

#### Part B — `ChatProjectQueries`

- [ ] **Step B0: Confirm the models**

Run: `grep -n "struct ChatProject\b\|struct ChatProject:\|struct ChatProjectSource\|struct ChatAttachment\|projectID\|archivedAt" WatchtowerDesktop/Sources/WatchtowerCore/Models/ChatModels.swift WatchtowerDesktop/Sources/WatchtowerCore/Models/ChatConversation.swift`

If `ChatProject` or `ChatProjectSource` is missing, append to `Sources/WatchtowerCore/Models/ChatModels.swift`:

```swift
package struct ChatProject: FetchableRecord, Decodable, Identifiable, Equatable, Hashable, Sendable {
    package let id: Int64
    package let name: String
    package let instructions: String
    package let createdAt: Double
    package let updatedAt: Double
    package let archivedAt: Double?

    package enum CodingKeys: String, CodingKey {
        case id, name, instructions
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case archivedAt = "archived_at"
    }
}

package struct ChatProjectSource: FetchableRecord, Decodable, Identifiable, Equatable, Hashable, Sendable {
    /// The `chat_project_sources.kind` CHECK values (migration 00074).
    package enum Kind: String, CaseIterable, Sendable {
        case jiraProject = "jira_project"
        case slackChannel = "slack_channel"
        case target
        case track
        case person
    }

    package let id: Int64
    package let projectID: Int64
    package let kind: String
    package let ref: String
    package let label: String

    package var sourceKind: Kind? { Kind(rawValue: kind) }

    package enum CodingKeys: String, CodingKey {
        case id, kind, ref, label
        case projectID = "project_id"
    }
}
```

If `ChatProjectSource` exists but has no nested `Kind`, add only the enum and `sourceKind`. `ChatAttachment` must exist from Task 10/21 (fields used below: `id`, `projectID`, `name`, `mime`, `size`, `path`).

- [ ] **Step B1: Write the failing tests**

Create `WatchtowerDesktop/Tests/Core/ChatProjectQueriesTests.swift`:

```swift
import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class ChatProjectQueriesTests: XCTestCase {
    private var db: DatabaseQueue!

    override func setUpWithError() throws {
        db = try TestDatabase.create()
    }

    @discardableResult
    private func insertConversation(_ d: Database, title: String, projectID: Int64?) throws -> Int64 {
        try d.execute(
            sql: """
                INSERT INTO chat_conversations (title, created_at, updated_at, project_id)
                VALUES (?, 1, 1, ?)
                """,
            arguments: [title, projectID]
        )
        return d.lastInsertedRowID
    }

    @discardableResult
    private func insertProjectFile(_ d: Database, projectID: Int64, path: String) throws -> Int64 {
        try d.execute(
            sql: """
                INSERT INTO chat_attachments (project_id, name, mime, size, path, sha256, created_at)
                VALUES (?, 'spec.pdf', 'application/pdf', 10, ?, 'abc', 1)
                """,
            arguments: [projectID, path]
        )
        return d.lastInsertedRowID
    }

    func testCreateTrimsNameAndFallsBackWhenEmpty() throws {
        try db.write { d in
            let named = try ChatProjectQueries.create(d, name: "  Payments  ")
            XCTAssertEqual(named.name, "Payments")
            XCTAssertEqual(named.instructions, "")
            XCTAssertNil(named.archivedAt)
            let unnamed = try ChatProjectQueries.create(d, name: "   ")
            XCTAssertEqual(unnamed.name, "New project")
        }
    }

    func testFetchActiveSkipsArchivedAndSortsByName() throws {
        try db.write { d in
            let beta = try ChatProjectQueries.create(d, name: "beta")
            _ = try ChatProjectQueries.create(d, name: "Alpha")
            let gone = try ChatProjectQueries.create(d, name: "Archived")
            try ChatProjectQueries.archive(d, id: gone.id)
            XCTAssertEqual(try ChatProjectQueries.fetchActive(d).map(\.name), ["Alpha", "beta"])
            XCTAssertNotNil(try ChatProjectQueries.fetchByID(d, id: beta.id))
        }
    }

    func testRenameIgnoresBlankAndUpdateInstructionsPersists() throws {
        try db.write { d in
            let p = try ChatProjectQueries.create(d, name: "P")
            try ChatProjectQueries.rename(d, id: p.id, name: "  ")
            try ChatProjectQueries.rename(d, id: p.id, name: "Q3 launch")
            try ChatProjectQueries.updateInstructions(d, id: p.id, instructions: "Answer in Russian.")
            let reloaded = try XCTUnwrap(ChatProjectQueries.fetchByID(d, id: p.id))
            XCTAssertEqual(reloaded.name, "Q3 launch")
            XCTAssertEqual(reloaded.instructions, "Answer in Russian.")
        }
    }

    func testAddSourceDedupesAndRemoveSourceDeletes() throws {
        try db.write { d in
            let p = try ChatProjectQueries.create(d, name: "P")
            XCTAssertTrue(try ChatProjectQueries.addSource(
                d, projectID: p.id, kind: .jiraProject, ref: "PAY", label: "PAY"))
            XCTAssertFalse(try ChatProjectQueries.addSource(
                d, projectID: p.id, kind: .jiraProject, ref: "PAY", label: "PAY again"),
                "same (kind, ref) twice is a no-op")
            XCTAssertTrue(try ChatProjectQueries.addSource(
                d, projectID: p.id, kind: .person, ref: "1:U1", label: "Anna"))
            let sources = try ChatProjectQueries.sources(d, projectID: p.id)
            XCTAssertEqual(sources.map(\.kind), ["jira_project", "person"])
            try ChatProjectQueries.removeSource(d, id: sources[0].id)
            XCTAssertEqual(try ChatProjectQueries.sources(d, projectID: p.id).map(\.ref), ["1:U1"])
        }
    }

    func testFilesAndRemoveFileReturnsPath() throws {
        try db.write { d in
            let p = try ChatProjectQueries.create(d, name: "P")
            let fileID = try insertProjectFile(d, projectID: p.id, path: "/tmp/a.pdf")
            XCTAssertEqual(try ChatProjectQueries.files(d, projectID: p.id).map(\.path), ["/tmp/a.pdf"])
            XCTAssertEqual(try ChatProjectQueries.removeFile(d, id: fileID), "/tmp/a.pdf")
            XCTAssertTrue(try ChatProjectQueries.files(d, projectID: p.id).isEmpty)
            XCTAssertNil(try ChatProjectQueries.removeFile(d, id: fileID), "second remove finds nothing")
        }
    }

    func testConversationsListsOnlyThisProjectsUnarchivedChats() throws {
        try db.write { d in
            let p = try ChatProjectQueries.create(d, name: "P")
            try insertConversation(d, title: "in", projectID: p.id)
            try insertConversation(d, title: "outside", projectID: nil)
            let archived = try insertConversation(d, title: "old", projectID: p.id)
            try d.execute(sql: "UPDATE chat_conversations SET archived_at = 5 WHERE id = ?", arguments: [archived])
            XCTAssertEqual(try ChatProjectQueries.conversations(d, projectID: p.id).map(\.title), ["in"])
        }
    }

    /// Spec §6.1: deleting a project keeps its chats (ON DELETE SET NULL) and
    /// deletes its files — the rows by cascade, the disk files by the caller
    /// from the returned paths, post-commit.
    func testDeleteKeepsChatsAndReturnsFilePaths() throws {
        try db.write { d in
            let p = try ChatProjectQueries.create(d, name: "P")
            let chat = try insertConversation(d, title: "keep me", projectID: p.id)
            try insertProjectFile(d, projectID: p.id, path: "/tmp/a.pdf")
            try ChatProjectQueries.addSource(d, projectID: p.id, kind: .track, ref: "7", label: "T")

            XCTAssertEqual(try ChatProjectQueries.delete(d, id: p.id), ["/tmp/a.pdf"])

            XCTAssertNil(try ChatProjectQueries.fetchByID(d, id: p.id))
            let projectOfChat = try Int64?.fetchOne(
                d, sql: "SELECT project_id FROM chat_conversations WHERE id = ?", arguments: [chat])
            XCTAssertEqual(projectOfChat, .some(nil), "the chat survives, detached")
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM chat_attachments"), 0)
            XCTAssertEqual(try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM chat_project_sources"), 0)
        }
    }
}
```

- [ ] **Step B2: Run tests to verify they fail**

Run: `make test-swift FILTER=ChatProjectQueriesTests`
Expected: FAIL — `cannot find 'ChatProjectQueries' in scope`.

- [ ] **Step B3: Implement**

Create `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ChatProjectQueries.swift`:

```swift
import Foundation
import GRDB

/// Chat projects (spec §6.1). Swift is the only writer of `chat_projects`,
/// `chat_project_sources` and project-owned `chat_attachments` rows; Go only
/// reads them (`db.GetChatProjectContext`) when `ai session --project-id`
/// builds the prompt and the first-turn attachments.
package enum ChatProjectQueries {
    package static let defaultName = "New project"

    package static func fetchActive(_ db: Database) throws -> [ChatProject] {
        try ChatProject.fetchAll(db, sql: """
            SELECT * FROM chat_projects WHERE archived_at IS NULL
            ORDER BY name COLLATE NOCASE, id
            """)
    }

    package static func fetchByID(_ db: Database, id: Int64) throws -> ChatProject? {
        try ChatProject.fetchOne(db, sql: "SELECT * FROM chat_projects WHERE id = ?", arguments: [id])
    }

    @discardableResult
    package static func create(_ db: Database, name: String) throws -> ChatProject {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date().timeIntervalSince1970
        try db.execute(
            sql: """
                INSERT INTO chat_projects (name, instructions, created_at, updated_at)
                VALUES (?, '', ?, ?)
                """,
            arguments: [trimmed.isEmpty ? defaultName : trimmed, now, now]
        )
        guard let project = try fetchByID(db, id: db.lastInsertedRowID) else {
            throw DatabaseError(message: "Failed to fetch newly created chat project")
        }
        return project
    }

    /// A blank name is ignored rather than stored: a project row always has a
    /// name to show in the sidebar.
    package static func rename(_ db: Database, id: Int64, name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try db.execute(
            sql: "UPDATE chat_projects SET name = ?, updated_at = ? WHERE id = ?",
            arguments: [trimmed, Date().timeIntervalSince1970, id]
        )
    }

    package static func updateInstructions(_ db: Database, id: Int64, instructions: String) throws {
        try db.execute(
            sql: "UPDATE chat_projects SET instructions = ?, updated_at = ? WHERE id = ?",
            arguments: [instructions, Date().timeIntervalSince1970, id]
        )
    }

    package static func archive(_ db: Database, id: Int64) throws {
        let now = Date().timeIntervalSince1970
        try db.execute(
            sql: "UPDATE chat_projects SET archived_at = ?, updated_at = ? WHERE id = ?",
            arguments: [now, now, id]
        )
    }

    /// Deletes the project. Its chats survive detached (`ON DELETE SET NULL`),
    /// its sources and file rows go by cascade. Returns the file paths so the
    /// caller removes them from disk AFTER the transaction commits.
    package static func delete(_ db: Database, id: Int64) throws -> [String] {
        let paths = try String.fetchAll(
            db, sql: "SELECT path FROM chat_attachments WHERE project_id = ? ORDER BY id",
            arguments: [id]
        )
        try db.execute(sql: "DELETE FROM chat_projects WHERE id = ?", arguments: [id])
        return paths
    }

    package static func sources(_ db: Database, projectID: Int64) throws -> [ChatProjectSource] {
        try ChatProjectSource.fetchAll(
            db,
            sql: """
                SELECT * FROM chat_project_sources WHERE project_id = ?
                ORDER BY kind, label COLLATE NOCASE, id
                """,
            arguments: [projectID]
        )
    }

    /// Returns false (and writes nothing) when the same (kind, ref) is already
    /// pinned to the project.
    @discardableResult
    package static func addSource(
        _ db: Database, projectID: Int64, kind: ChatProjectSource.Kind, ref: String, label: String
    ) throws -> Bool {
        let exists = try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(SELECT 1 FROM chat_project_sources
                              WHERE project_id = ? AND kind = ? AND ref = ?)
                """,
            arguments: [projectID, kind.rawValue, ref]
        ) ?? false
        guard !exists else { return false }
        try db.execute(
            sql: "INSERT INTO chat_project_sources (project_id, kind, ref, label) VALUES (?, ?, ?, ?)",
            arguments: [projectID, kind.rawValue, ref, label]
        )
        try touch(db, id: projectID)
        return true
    }

    package static func removeSource(_ db: Database, id: Int64) throws {
        try db.execute(sql: "DELETE FROM chat_project_sources WHERE id = ?", arguments: [id])
    }

    package static func files(_ db: Database, projectID: Int64) throws -> [ChatAttachment] {
        try ChatAttachment.fetchAll(
            db,
            sql: "SELECT * FROM chat_attachments WHERE project_id = ? ORDER BY created_at, id",
            arguments: [projectID]
        )
    }

    /// Deletes one project file row and returns its path for post-commit disk
    /// removal; nil when no project file has that id.
    package static func removeFile(_ db: Database, id: Int64) throws -> String? {
        guard let path = try String.fetchOne(
            db, sql: "SELECT path FROM chat_attachments WHERE id = ? AND project_id IS NOT NULL",
            arguments: [id]
        ) else { return nil }
        try db.execute(sql: "DELETE FROM chat_attachments WHERE id = ?", arguments: [id])
        return path
    }

    package static func conversations(_ db: Database, projectID: Int64) throws -> [ChatConversation] {
        try ChatConversation.fetchAll(
            db,
            sql: """
                SELECT * FROM chat_conversations
                WHERE project_id = ? AND archived_at IS NULL
                ORDER BY updated_at DESC, id DESC
                """,
            arguments: [projectID]
        )
    }

    private static func touch(_ db: Database, id: Int64) throws {
        try db.execute(
            sql: "UPDATE chat_projects SET updated_at = ? WHERE id = ?",
            arguments: [Date().timeIntervalSince1970, id]
        )
    }
}
```

- [ ] **Step B4: Run tests to verify they pass**

Run: `make test-swift FILTER=ChatProjectQueriesTests`
Expected: PASS (7 tests).

- [ ] **Step B5: Commit**

```bash
git add WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ChatProjectQueries.swift WatchtowerDesktop/Tests/Core/ChatProjectQueriesTests.swift WatchtowerDesktop/Sources/WatchtowerCore/Models/ChatModels.swift
git commit -m "feat(desktop): chat project queries

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

#### Part C — `ChatEntitySearch` (shared by the source picker and Task 25's mentions)

- [ ] **Step C1: Write the failing tests**

Create `WatchtowerDesktop/Tests/Core/ChatEntitySearchTests.swift`:

```swift
import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class ChatEntitySearchTests: XCTestCase {
    private var db: DatabaseQueue!

    override func setUpWithError() throws {
        db = try TestDatabase.create()
    }

    private func insertIssue(
        _ d: Database, accountID: Int64, key: String, project: String, summary: String,
        updatedAt: String = "2026-09-01T00:00:00Z", deleted: Bool = false
    ) throws {
        try d.execute(
            sql: """
                INSERT INTO jira_issues (account_id, key, project_key, summary, status, status_category,
                                         created_at, updated_at, synced_at, is_deleted)
                VALUES (?, ?, ?, ?, 'Open', 'todo', ?, ?, ?, ?)
                """,
            arguments: [accountID, key, project, summary, updatedAt, updatedAt, updatedAt, deleted ? 1 : 0]
        )
    }

    func testPeopleMatchPrefixAndWordPrefixAndSkipBotsAndDeleted() throws {
        try db.write { d in
            try TestDatabase.insertUser(d, id: "1:U1", name: "anna", displayName: "Anna Ivanova", realName: "")
            try TestDatabase.insertUser(d, id: "1:U2", name: "ivan", displayName: "", realName: "Ivan Petrov")
            try TestDatabase.insertUser(d, id: "1:U3", name: "ivanbot", displayName: "Ivan Bot", isBot: true)
            try TestDatabase.insertUser(d, id: "1:U4", name: "ivanold", displayName: "Ivan Old", isDeleted: true)

            let hits = try ChatEntitySearch.people(d, query: "iva")
            XCTAssertEqual(Set(hits.map(\.ref)), ["1:U1", "1:U2"], "word prefix 'Iva' in 'Anna Ivanova' + prefix 'ivan'")
            XCTAssertEqual(hits.first { $0.ref == "1:U2" }?.label, "Ivan Petrov", "falls back to real_name")
            XCTAssertTrue(hits.allSatisfy { $0.kind == .person })
        }
    }

    /// SQLite LIKE folds only ASCII case: a lower-case Cyrillic query must
    /// still find a capitalized name.
    func testPeopleCyrillicLowercaseQueryFindsCapitalizedName() throws {
        try db.write { d in
            try TestDatabase.insertUser(d, id: "1:U9", name: "ivan", displayName: "Иван Петров")
            XCTAssertEqual(try ChatEntitySearch.people(d, query: "ива").map(\.ref), ["1:U9"])
        }
    }

    func testWildcardsInQueryAreLiteral() throws {
        try db.write { d in
            try TestDatabase.insertUser(d, id: "1:U1", name: "anna", displayName: "Anna")
            XCTAssertTrue(try ChatEntitySearch.people(d, query: "%").isEmpty)
            XCTAssertTrue(try ChatEntitySearch.people(d, query: "_nna").isEmpty)
        }
    }

    func testEmptyQueryListsUpToLimit() throws {
        try db.write { d in
            for i in 0..<12 {
                try TestDatabase.insertUser(d, id: "1:U\(i)", name: "user\(i)", displayName: "User \(i)")
            }
            XCTAssertEqual(try ChatEntitySearch.people(d, query: "").count, ChatEntitySearch.defaultLimit)
            XCTAssertEqual(try ChatEntitySearch.people(d, query: "", limit: 3).count, 3)
        }
    }

    func testChannelsSkipArchivedAndDMs() throws {
        try db.write { d in
            try TestDatabase.insertChannel(d, id: "1:C1", name: "payments")
            try TestDatabase.insertChannel(d, id: "1:C2", name: "payments-old", isArchived: true)
            try TestDatabase.insertChannel(d, id: "1:D1", name: "payuser", type: "dm")
            let hits = try ChatEntitySearch.channels(d, query: "pay")
            XCTAssertEqual(hits.map(\.ref), ["1:C1"])
            XCTAssertEqual(hits.first?.label, "#payments")
        }
    }

    func testJiraIssuesByKeyOrSummaryDedupedAcrossSites() throws {
        try db.write { d in
            let a = try TestDatabase.insertJiraAccount(d, cloudID: "a")
            let b = try TestDatabase.insertJiraAccount(d, cloudID: "b")
            try insertIssue(d, accountID: a, key: "PAY-12", project: "PAY", summary: "Refund flow")
            try insertIssue(d, accountID: b, key: "PAY-12", project: "PAY", summary: "Refund flow")
            try insertIssue(d, accountID: a, key: "OPS-1", project: "OPS", summary: "Payout alerts")
            try insertIssue(d, accountID: a, key: "PAY-99", project: "PAY", summary: "gone", deleted: true)

            XCTAssertEqual(try ChatEntitySearch.jiraIssues(d, query: "pay-1").map(\.ref), ["PAY-12"])
            XCTAssertEqual(Set(try ChatEntitySearch.jiraIssues(d, query: "payout").map(\.ref)), ["OPS-1"])
            let hit = try XCTUnwrap(ChatEntitySearch.jiraIssues(d, query: "PAY-12").first)
            XCTAssertEqual(hit.label, "PAY-12")
            XCTAssertEqual(hit.detail, "Refund flow")
        }
    }

    func testJiraProjectsAreDistinctKeys() throws {
        try db.write { d in
            let a = try TestDatabase.insertJiraAccount(d, cloudID: "a")
            try insertIssue(d, accountID: a, key: "PAY-1", project: "PAY", summary: "x")
            try insertIssue(d, accountID: a, key: "PAY-2", project: "PAY", summary: "y")
            try insertIssue(d, accountID: a, key: "OPS-1", project: "OPS", summary: "z")
            let hits = try ChatEntitySearch.jiraProjects(d, query: "")
            XCTAssertEqual(hits.map(\.ref), ["OPS", "PAY"])
            XCTAssertEqual(hits.last?.detail, "2 issues")
        }
    }

    func testTargetsSkipDoneAndDismissedTracksSkipDismissed() throws {
        try db.write { d in
            let live = try TestDatabase.insertTarget(d, text: "Ship refunds\nsecond line")
            _ = try TestDatabase.insertTarget(d, text: "Ship old thing", status: "done")
            _ = try TestDatabase.insertTarget(d, text: "Ship dropped", status: "dismissed")
            let targets = try ChatEntitySearch.targets(d, query: "ship")
            XCTAssertEqual(targets.map(\.ref), [String(live)])
            XCTAssertEqual(targets.first?.label, "Ship refunds", "first line only")

            let track = try TestDatabase.insertTrack(d, text: "Refund review")
            let gone = try TestDatabase.insertTrack(d, text: "Refund dismissed")
            try d.execute(sql: "UPDATE tracks SET dismissed_at = '2026-01-01' WHERE id = ?", arguments: [gone])
            XCTAssertEqual(try ChatEntitySearch.tracks(d, query: "refund").map(\.ref), [String(track)])
        }
    }

    func testSearchByKindDispatches() throws {
        try db.write { d in
            try TestDatabase.insertChannel(d, id: "1:C1", name: "general")
            XCTAssertEqual(try ChatEntitySearch.search(d, kind: .channel, query: "gen").map(\.ref), ["1:C1"])
            XCTAssertTrue(try ChatEntitySearch.search(d, kind: .person, query: "gen").isEmpty)
        }
    }

    func testProjectSourceKindMapping() {
        XCTAssertEqual(ChatProjectSource.Kind(entity: .person), .person)
        XCTAssertEqual(ChatProjectSource.Kind(entity: .channel), .slackChannel)
        XCTAssertEqual(ChatProjectSource.Kind(entity: .jiraProject), .jiraProject)
        XCTAssertEqual(ChatProjectSource.Kind(entity: .target), .target)
        XCTAssertEqual(ChatProjectSource.Kind(entity: .track), .track)
        XCTAssertNil(ChatProjectSource.Kind(entity: .jiraIssue), "an issue is a mention, not a project source")
    }
}
```

- [ ] **Step C2: Run tests to verify they fail**

Run: `make test-swift FILTER=ChatEntitySearchTests`
Expected: FAIL — `cannot find 'ChatEntitySearch' in scope`.

- [ ] **Step C3: Implement**

Create `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ChatEntitySearch.swift`:

```swift
import Foundation
import GRDB

/// What the chat composer and the project source picker can point at.
package enum ChatEntityKind: String, CaseIterable, Sendable {
    case person
    case channel
    case jiraIssue = "jira"
    case jiraProject = "jira_project"
    case target
    case track
}

/// One local-DB entity found by a prefix search. `ref` is the id the model's
/// `get_*` tools take: a namespaced Slack user/channel id, an issue key, a
/// project key, or a target/track row id.
package struct ChatEntityHit: Equatable, Hashable, Sendable {
    package let kind: ChatEntityKind
    package let ref: String
    package let label: String
    package let detail: String

    package init(kind: ChatEntityKind, ref: String, label: String, detail: String) {
        self.kind = kind
        self.ref = ref
        self.label = label
        self.detail = detail
    }
}

extension ChatProjectSource.Kind {
    /// The project-source kind for a search hit; nil for a Jira issue, which
    /// can be mentioned but not pinned (a project pins the whole Jira project).
    package init?(entity: ChatEntityKind) {
        switch entity {
        case .person: self = .person
        case .channel: self = .slackChannel
        case .jiraProject: self = .jiraProject
        case .target: self = .target
        case .track: self = .track
        case .jiraIssue: return nil
        }
    }
}

/// Prefix search over the local DB (spec §6.2: people, Slack channels, Jira
/// issues, targets, tracks — prefix match, 8 results), plus Jira project keys
/// for the project source picker. Pure reads; every function is bounded by
/// `limit`.
package enum ChatEntitySearch {
    package static let defaultLimit = 8

    package static func search(
        _ db: Database, kind: ChatEntityKind, query: String, limit: Int = defaultLimit
    ) throws -> [ChatEntityHit] {
        switch kind {
        case .person: return try people(db, query: query, limit: limit)
        case .channel: return try channels(db, query: query, limit: limit)
        case .jiraIssue: return try jiraIssues(db, query: query, limit: limit)
        case .jiraProject: return try jiraProjects(db, query: query, limit: limit)
        case .target: return try targets(db, query: query, limit: limit)
        case .track: return try tracks(db, query: query, limit: limit)
        }
    }

    package static func people(_ db: Database, query: String, limit: Int = defaultLimit) throws -> [ChatEntityHit] {
        let match = PrefixMatch(query).clause(columns: ["name", "display_name", "real_name"])
        var args = StatementArguments(match.args)
        args += [limit]
        return try Row.fetchAll(
            db,
            sql: """
                SELECT id, name,
                       COALESCE(NULLIF(display_name, ''), NULLIF(real_name, ''), name) AS label
                FROM users
                WHERE is_bot = 0 AND is_deleted = 0 AND is_stub = 0 AND \(match.sql)
                ORDER BY label COLLATE NOCASE, id
                LIMIT ?
                """,
            arguments: args
        ).map { row in
            ChatEntityHit(kind: .person, ref: row["id"], label: row["label"], detail: "@" + (row["name"] as String))
        }
    }

    package static func channels(_ db: Database, query: String, limit: Int = defaultLimit) throws -> [ChatEntityHit] {
        let match = PrefixMatch(query).clause(columns: ["name"])
        var args = StatementArguments(match.args)
        args += [limit]
        return try Row.fetchAll(
            db,
            sql: """
                SELECT id, name FROM channels
                WHERE type IN ('public', 'private') AND is_archived = 0 AND \(match.sql)
                ORDER BY is_member DESC, name COLLATE NOCASE, id
                LIMIT ?
                """,
            arguments: args
        ).map { row in
            ChatEntityHit(kind: .channel, ref: row["id"], label: "#" + (row["name"] as String), detail: "Slack channel")
        }
    }

    /// Key prefix (`pay-1` → `PAY-12`) or summary word prefix. A key shared by
    /// two Jira sites is one hit (the multi-account bare-key convention).
    package static func jiraIssues(_ db: Database, query: String, limit: Int = defaultLimit) throws -> [ChatEntityHit] {
        let prefix = PrefixMatch(query)
        let summary = prefix.clause(columns: ["summary"])
        let keyPattern = PrefixMatch.escape(query.trimmingCharacters(in: .whitespaces).uppercased()) + "%"
        var args: StatementArguments = [keyPattern]
        args += StatementArguments(summary.args)
        args += [limit]
        return try Row.fetchAll(
            db,
            sql: """
                SELECT key, summary, MAX(updated_at) AS newest FROM jira_issues
                WHERE is_deleted = 0 AND (key LIKE ? ESCAPE '\\' OR \(summary.sql))
                GROUP BY key
                ORDER BY newest DESC, key
                LIMIT ?
                """,
            arguments: args
        ).map { row in
            ChatEntityHit(kind: .jiraIssue, ref: row["key"], label: row["key"], detail: row["summary"])
        }
    }

    package static func jiraProjects(_ db: Database, query: String, limit: Int = defaultLimit) throws -> [ChatEntityHit] {
        let pattern = PrefixMatch.escape(query.trimmingCharacters(in: .whitespaces).uppercased()) + "%"
        return try Row.fetchAll(
            db,
            sql: """
                SELECT project_key, COUNT(DISTINCT key) AS n FROM jira_issues
                WHERE is_deleted = 0 AND project_key LIKE ? ESCAPE '\\'
                GROUP BY project_key
                ORDER BY project_key
                LIMIT ?
                """,
            arguments: [pattern, limit]
        ).map { row in
            let count: Int = row["n"]
            return ChatEntityHit(
                kind: .jiraProject, ref: row["project_key"], label: row["project_key"],
                detail: count == 1 ? "1 issue" : "\(count) issues"
            )
        }
    }

    package static func targets(_ db: Database, query: String, limit: Int = defaultLimit) throws -> [ChatEntityHit] {
        let match = PrefixMatch(query).clause(columns: ["text"])
        var args = StatementArguments(match.args)
        args += [limit]
        return try Row.fetchAll(
            db,
            sql: """
                SELECT id, text, status FROM targets
                WHERE status NOT IN ('done', 'dismissed') AND \(match.sql)
                ORDER BY updated_at DESC, id DESC
                LIMIT ?
                """,
            arguments: args
        ).map { row in
            let id: Int64 = row["id"]
            return ChatEntityHit(kind: .target, ref: String(id), label: firstLine(row["text"]), detail: row["status"])
        }
    }

    package static func tracks(_ db: Database, query: String, limit: Int = defaultLimit) throws -> [ChatEntityHit] {
        let match = PrefixMatch(query).clause(columns: ["text"])
        var args = StatementArguments(match.args)
        args += [limit]
        return try Row.fetchAll(
            db,
            sql: """
                SELECT id, text, priority FROM tracks
                WHERE dismissed_at = '' AND \(match.sql)
                ORDER BY updated_at DESC, id DESC
                LIMIT ?
                """,
            arguments: args
        ).map { row in
            let id: Int64 = row["id"]
            return ChatEntityHit(
                kind: .track, ref: String(id), label: firstLine(row["text"]),
                detail: "track · " + (row["priority"] as String)
            )
        }
    }

    /// First non-empty line, capped at 60 characters — a label, not the text.
    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count <= 60 ? trimmed : String(trimmed.prefix(59)) + "…"
    }
}

/// A prefix / word-prefix LIKE matcher. SQLite `LIKE` folds ASCII case only,
/// so the query's first letter is also tried upper- and lower-cased (`ива`
/// finds `Иван`); `%`, `_` and `\` are escaped so they match literally. An
/// empty query matches everything (`1`).
struct PrefixMatch {
    let patterns: [String]

    init(_ raw: String) {
        let query = raw.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else {
            patterns = []
            return
        }
        var variants: [String] = [query]
        for variant in [query.prefix(1).uppercased() + query.dropFirst(),
                        query.prefix(1).lowercased() + query.dropFirst()]
        where !variants.contains(variant) {
            variants.append(variant)
        }
        patterns = variants.flatMap { variant -> [String] in
            let escaped = Self.escape(variant)
            return [escaped + "%", "% " + escaped + "%"]
        }
    }

    func clause(columns: [String]) -> (sql: String, args: [String]) {
        guard !patterns.isEmpty else { return ("1", []) }
        var parts: [String] = []
        var args: [String] = []
        for column in columns {
            for pattern in patterns {
                parts.append("\(column) LIKE ? ESCAPE '\\'")
                args.append(pattern)
            }
        }
        return ("(" + parts.joined(separator: " OR ") + ")", args)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
```

- [ ] **Step C4: Run tests to verify they pass**

Run: `make test-swift FILTER=ChatEntitySearchTests`
Expected: PASS (10 tests).

- [ ] **Step C5: Commit**

```bash
git add WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ChatEntitySearch.swift WatchtowerDesktop/Tests/Core/ChatEntitySearchTests.swift
git commit -m "feat(desktop): local-DB entity prefix search for chat pickers

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

#### Part D — `ProjectDetailViewModel`

- [ ] **Step D1: Write the failing tests**

Create `WatchtowerDesktop/Tests/ProjectDetailViewModelTests.swift`:

```swift
import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore
@testable import WatchtowerDesktop

@MainActor
final class ProjectDetailViewModelTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var projectID: Int64!
    private var importedURLs: [URL] = []

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        projectID = try pool.write { try ChatProjectQueries.create($0, name: "Payments").id }
        importedURLs = []
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
        super.tearDown()
    }

    private func makeVM(debounce: Duration = .zero) -> ProjectDetailViewModel {
        ProjectDetailViewModel(
            projectID: projectID,
            dbPool: pool,
            debounce: debounce,
            importFile: { [unowned self] url, pid in
                self.importedURLs.append(url)
                return try self.pool.write { d in
                    try d.execute(
                        sql: """
                            INSERT INTO chat_attachments (project_id, name, mime, size, path, sha256, created_at)
                            VALUES (?, ?, 'application/pdf', 1, ?, 'h', 1)
                            """,
                        arguments: [pid, url.lastPathComponent, url.path]
                    )
                    return try XCTUnwrap(ChatProjectQueries.files(d, projectID: pid).last)
                }
            }
        )
    }

    func testLoadFillsDraftsAndLists() throws {
        try pool.write { d in
            try ChatProjectQueries.updateInstructions(d, id: self.projectID, instructions: "Be brief.")
            try ChatProjectQueries.addSource(d, projectID: self.projectID, kind: .jiraProject, ref: "PAY", label: "PAY")
        }
        let vm = makeVM()
        vm.load()
        XCTAssertEqual(vm.project?.name, "Payments")
        XCTAssertEqual(vm.nameDraft, "Payments")
        XCTAssertEqual(vm.instructionsDraft, "Be brief.")
        XCTAssertEqual(vm.sources.map(\.ref), ["PAY"])
        XCTAssertNil(vm.errorMessage)
    }

    func testInstructionsEditIsDebouncedThenSaved() async throws {
        let vm = makeVM(debounce: .milliseconds(50))
        vm.load()
        vm.instructionsEdited("First")
        vm.instructionsEdited("Second")
        await vm.pendingSave?.value
        let stored = try pool.read { try ChatProjectQueries.fetchByID($0, id: self.projectID)?.instructions }
        XCTAssertEqual(stored, "Second", "only the latest draft is written")
    }

    /// Leaving the page before the debounce fires must not lose the edit.
    func testFlushWritesPendingDraftImmediately() async throws {
        let vm = makeVM(debounce: .seconds(60))
        vm.load()
        vm.instructionsEdited("Keep me")
        await vm.flush()
        let stored = try pool.read { try ChatProjectQueries.fetchByID($0, id: self.projectID)?.instructions }
        XCTAssertEqual(stored, "Keep me")
    }

    func testRenameAddRemoveSource() throws {
        let vm = makeVM()
        vm.load()
        vm.rename("Q3 payments")
        XCTAssertEqual(vm.project?.name, "Q3 payments")
        vm.addSource(ChatEntityHit(kind: .channel, ref: "1:C1", label: "#payments", detail: ""))
        vm.addSource(ChatEntityHit(kind: .jiraIssue, ref: "PAY-1", label: "PAY-1", detail: ""))
        XCTAssertEqual(vm.sources.map(\.kind), ["slack_channel"], "an issue hit is not a project source")
        vm.removeSource(vm.sources[0])
        XCTAssertTrue(vm.sources.isEmpty)
    }

    func testAddAndRemoveFilesRemovesDiskFile() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory() + "proj_\(UUID().uuidString).pdf")
        try Data("x".utf8).write(to: file)
        let vm = makeVM()
        vm.load()
        vm.addFiles([file])
        XCTAssertEqual(importedURLs, [file])
        XCTAssertEqual(vm.files.map(\.name), [file.lastPathComponent])
        vm.removeFile(vm.files[0])
        XCTAssertTrue(vm.files.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "disk file removed post-commit")
    }

    func testImportFailureSurfacesError() {
        let vm = ProjectDetailViewModel(
            projectID: projectID, dbPool: pool, debounce: .zero,
            importFile: { _, _ in throw NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "too big"]) }
        )
        vm.load()
        vm.addFiles([URL(fileURLWithPath: "/tmp/huge.pdf")])
        XCTAssertEqual(vm.errorMessage, "huge.pdf: too big")
        XCTAssertTrue(vm.files.isEmpty)
    }

    func testDeleteProjectKeepsChats() throws {
        let chatID = try pool.write { d -> Int64 in
            try d.execute(
                sql: "INSERT INTO chat_conversations (title, created_at, updated_at, project_id) VALUES ('c', 1, 1, ?)",
                arguments: [self.projectID]
            )
            return d.lastInsertedRowID
        }
        let vm = makeVM()
        vm.load()
        XCTAssertEqual(vm.chats.map(\.id), [chatID])
        XCTAssertTrue(vm.deleteProject())
        let remaining = try pool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chat_conversations") }
        XCTAssertEqual(remaining, 1)
        XCTAssertNil(try pool.read { try ChatProjectQueries.fetchByID($0, id: self.projectID) })
    }
}
```

- [ ] **Step D2: Run tests to verify they fail**

Run: `make test-swift FILTER=ProjectDetailViewModelTests`
Expected: FAIL — `cannot find 'ProjectDetailViewModel' in scope`.

- [ ] **Step D3: Implement**

Create `WatchtowerDesktop/Sources/ViewModels/ProjectDetailViewModel.swift`:

```swift
import Foundation
import GRDB
import Observation
import WatchtowerCore

/// The chat project page (spec §6.1): name, instructions (debounced save),
/// pinned sources, files, and the project's chats. The page is short-lived
/// and its only async state is a pending instructions save, which `flush()`
/// writes on disappear — so the VM can be view-local.
///
/// Edits reach the assistant when a conversation starts a fresh provider
/// session (a new chat, or an existing one after its warm session ends): the
/// project block and first-turn files are read by `ai session` at spawn.
@MainActor
@Observable
final class ProjectDetailViewModel {
    let projectID: Int64
    private(set) var project: ChatProject?
    private(set) var sources: [ChatProjectSource] = []
    private(set) var files: [ChatAttachment] = []
    private(set) var chats: [ChatConversation] = []
    private(set) var errorMessage: String?
    private(set) var pendingSave: Task<Void, Never>?
    var nameDraft = ""
    private(set) var instructionsDraft = ""

    private let dbPool: DatabasePool
    private let debounce: Duration
    private let importFile: (URL, Int64) throws -> ChatAttachment

    init(
        projectID: Int64,
        dbPool: DatabasePool,
        debounce: Duration = .milliseconds(500),
        importFile: @escaping (URL, Int64) throws -> ChatAttachment
    ) {
        self.projectID = projectID
        self.dbPool = dbPool
        self.debounce = debounce
        self.importFile = importFile
    }

    func load() {
        do {
            let id = projectID
            let snapshot = try dbPool.read { db in
                (try ChatProjectQueries.fetchByID(db, id: id),
                 try ChatProjectQueries.sources(db, projectID: id),
                 try ChatProjectQueries.files(db, projectID: id),
                 try ChatProjectQueries.conversations(db, projectID: id))
            }
            project = snapshot.0
            sources = snapshot.1
            files = snapshot.2
            chats = snapshot.3
            nameDraft = snapshot.0?.name ?? ""
            instructionsDraft = snapshot.0?.instructions ?? ""
            errorMessage = nil
        } catch {
            errorMessage = "Could not load the project: \(error.localizedDescription)"
        }
    }

    func instructionsEdited(_ text: String) {
        instructionsDraft = text
        pendingSave?.cancel()
        let delay = debounce
        pendingSave = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            self?.saveInstructions()
        }
    }

    /// Writes a pending instructions draft now (the page is going away).
    func flush() async {
        guard let task = pendingSave else { return }
        task.cancel()
        pendingSave = nil
        saveInstructions()
    }

    func rename(_ name: String) {
        write { db, id in try ChatProjectQueries.rename(db, id: id, name: name) }
    }

    func addSource(_ hit: ChatEntityHit) {
        guard let kind = ChatProjectSource.Kind(entity: hit.kind) else { return }
        write { db, id in
            try ChatProjectQueries.addSource(db, projectID: id, kind: kind, ref: hit.ref, label: hit.label)
        }
    }

    func removeSource(_ source: ChatProjectSource) {
        write { db, _ in try ChatProjectQueries.removeSource(db, id: source.id) }
    }

    func addFiles(_ urls: [URL]) {
        var failures: [String] = []
        for url in urls {
            do {
                _ = try importFile(url, projectID)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        load()
        if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
    }

    func removeFile(_ file: ChatAttachment) {
        do {
            let path = try dbPool.write { try ChatProjectQueries.removeFile($0, id: file.id) }
            if let path { Self.removeFromDisk([path]) }
            load()
        } catch {
            errorMessage = "Could not remove \(file.name): \(error.localizedDescription)"
        }
    }

    /// Deletes the project (chats survive, detached). Returns false on a
    /// write failure, with `errorMessage` set.
    func deleteProject() -> Bool {
        do {
            let id = projectID
            let paths = try dbPool.write { try ChatProjectQueries.delete($0, id: id) }
            Self.removeFromDisk(paths)
            return true
        } catch {
            errorMessage = "Could not delete the project: \(error.localizedDescription)"
            return false
        }
    }

    private func saveInstructions() {
        let text = instructionsDraft
        let id = projectID
        do {
            try dbPool.write { try ChatProjectQueries.updateInstructions($0, id: id, instructions: text) }
            pendingSave = nil
        } catch {
            errorMessage = "Could not save instructions: \(error.localizedDescription)"
        }
    }

    private func write(_ body: (Database, Int64) throws -> Void) {
        let id = projectID
        do {
            try dbPool.write { try body($0, id) }
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Best effort, post-commit (spec §7.1): a file already gone is success.
    private static func removeFromDisk(_ paths: [String]) {
        for path in paths where FileManager.default.fileExists(atPath: path) {
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch {
                NSLog("ProjectDetailViewModel: could not remove %@: %@", path, error.localizedDescription)
            }
        }
    }
}
```

Note: `load()` resets `nameDraft`/`instructionsDraft` from the DB — `write` calls `load()`, so `saveInstructions` deliberately does not, keeping the draft the owner is typing.

- [ ] **Step D4: Run tests to verify they pass**

Run: `make test-swift FILTER=ProjectDetailViewModelTests`
Expected: PASS (7 tests).

- [ ] **Step D5: Commit**

```bash
git add WatchtowerDesktop/Sources/ViewModels/ProjectDetailViewModel.swift WatchtowerDesktop/Tests/ProjectDetailViewModelTests.swift
git commit -m "feat(desktop): project detail view model

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

#### Part E — Views, sidebar, navigation, `--project-id`

- [ ] **Step E0: Confirm the Task 11/14/15 names**

Run: `grep -n "struct ChatSessionConfig\|static func arguments\|project-id" WatchtowerDesktop/Sources/Services/Chat/ChatSessionClient.swift; grep -n "func newConversation\|func select(conversationID\|projectID" WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift; grep -n "Projects" WatchtowerDesktop/Sources/Views/Chat/ChatSidebarView.swift`
If `--project-id` is already emitted by Task 11, skip Step E1/E3's argv part and keep its test.

- [ ] **Step E1: Write the failing tests**

Append to `WatchtowerDesktop/Tests/ChatSessionClientTests.swift` (Task 11 file):

```swift
    func testSessionArgumentsCarryProjectIDOnlyWhenSet() {
        var config = ChatSessionConfig(conversationID: 7, provider: "claude", model: nil)
        XCTAssertFalse(ChatSessionClient.arguments(for: config, dbPath: "/tmp/w.db").contains("--project-id"))
        config.projectID = 42
        let args = ChatSessionClient.arguments(for: config, dbPath: "/tmp/w.db")
        let flag = args.firstIndex(of: "--project-id")
        XCTAssertEqual(flag.map { args[$0 + 1] }, "42")
    }
```

(Use Task 11's actual `ChatSessionConfig` initializer; only the `projectID` property is new here.)

Append to `WatchtowerDesktop/Tests/ChatViewModelTests.swift` (Task 14 file):

```swift
    func testCreateProjectOpensItAndSelectingAConversationLeavesIt() throws {
        let vm = try makeViewModel()
        let id = try XCTUnwrap(vm.createProject(name: "Payments"))
        XCTAssertEqual(vm.openProjectID, id)
        XCTAssertEqual(vm.projects.map(\.name), ["Payments"])

        vm.newConversation(projectID: id)
        XCTAssertNil(vm.openProjectID, "starting a chat leaves the project page")
        XCTAssertEqual(vm.currentConversation?.projectID, id)

        vm.openProject(id)
        XCTAssertEqual(vm.openProjectID, id)
        vm.select(conversationID: try XCTUnwrap(vm.currentConversation?.id))
        XCTAssertNil(vm.openProjectID)
    }

    func testNewConversationInProjectPassesProjectIDToTheSession() throws {
        let vm = try makeViewModel()
        let id = try XCTUnwrap(vm.createProject(name: "P"))
        vm.newConversation(projectID: id)
        vm.send(text: "hi", attachments: [], mentions: [])
        XCTAssertEqual(fakePool.lastConfig?.projectID, id)
    }
```

(`makeViewModel()`, `fakePool.lastConfig` and `currentConversation` are the Task 14 fixture's names — adapt to what it provides for "the config the pool was asked for" and "the selected conversation".)

- [ ] **Step E2: Run tests to verify they fail**

Run: `make test-swift FILTER=ChatSessionClientTests` then `make test-swift FILTER=ChatViewModelTests`
Expected: FAIL — `value of type 'ChatSessionConfig' has no member 'projectID'`, `value of type 'ChatViewModel' has no member 'createProject'`.

- [ ] **Step E3: Implement the session flag and VM navigation**

In `ChatSessionClient.swift`: add `var projectID: Int64? = nil` to `ChatSessionConfig`, and in `arguments(for:dbPath:)`:

```swift
        if let projectID = config.projectID {
            args += ["--project-id", String(projectID)]
        }
```

In `ChatViewModel.swift`:

```swift
    /// The project page open in the detail area, or nil when a conversation
    /// (or the empty state) is shown.
    private(set) var openProjectID: Int64?
    private(set) var projects: [ChatProject] = []

    func reloadProjects() {
        do {
            projects = try dbManager.dbPool.read { try ChatProjectQueries.fetchActive($0) }
        } catch {
            errorMessage = "Could not load projects: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func createProject(name: String) -> Int64? {
        do {
            let project = try dbManager.dbPool.write { try ChatProjectQueries.create($0, name: name) }
            reloadProjects()
            openProjectID = project.id
            return project.id
        } catch {
            errorMessage = "Could not create the project: \(error.localizedDescription)"
            return nil
        }
    }

    func openProject(_ id: Int64) {
        openProjectID = id
    }

    /// Called by the project page after it deleted its project.
    func projectDeleted(_ id: Int64) {
        if openProjectID == id { openProjectID = nil }
        reloadProjects()
        reloadConversations()
    }
```

(`errorMessage` and `reloadConversations()` are Task 14's error surface and history reload; use its names.) Then: in `select(conversationID:)` and `newConversation(projectID:)` add `openProjectID = nil` as the first line; where Task 14 builds the `ChatSessionConfig` for a conversation, set `config.projectID = conversation.projectID`; call `reloadProjects()` wherever Task 14 loads the history on start.

- [ ] **Step E4: Run tests to verify they pass**

Run: `make test-swift FILTER=ChatSessionClientTests` then `make test-swift FILTER=ChatViewModelTests`
Expected: PASS.

- [ ] **Step E5: Project page and source picker views**

Create `WatchtowerDesktop/Sources/Views/Chat/ProjectSourcePickerSheet.swift`:

```swift
import GRDB
import SwiftUI
import WatchtowerCore

/// Picks one entity to pin as a project source (spec §6.1): a Jira project,
/// Slack channel, target, track or person, from the local DB.
struct ProjectSourcePickerSheet: View {
    let dbPool: DatabasePool
    let onPick: (ChatEntityHit) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind: ChatEntityKind = .jiraProject
    @State private var query = ""
    @State private var hits: [ChatEntityHit] = []
    @State private var searchError: String?

    private static let kinds: [(ChatEntityKind, String)] = [
        (.jiraProject, "Jira project"), (.channel, "Slack channel"),
        (.target, "Target"), (.track, "Track"), (.person, "Person")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pin a source").font(.headline)
            Picker("Kind", selection: $kind) {
                ForEach(Self.kinds, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
            if let searchError {
                Text(searchError).font(.caption).foregroundStyle(.red)
            }
            List(hits, id: \.self) { hit in
                Button {
                    onPick(hit)
                    dismiss()
                } label: {
                    VStack(alignment: .leading) {
                        Text(hit.label)
                        Text(hit.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(minHeight: 240)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
            }
        }
        .padding(16)
        .frame(width: 460)
        .onAppear(perform: runSearch)
        .onChange(of: kind) { runSearch() }
        .onChange(of: query) { runSearch() }
    }

    private func runSearch() {
        do {
            hits = try dbPool.read { try ChatEntitySearch.search($0, kind: kind, query: query, limit: 30) }
            searchError = nil
        } catch {
            hits = []
            searchError = error.localizedDescription
        }
    }
}
```

Create `WatchtowerDesktop/Sources/Views/Chat/ProjectDetailView.swift`:

```swift
import GRDB
import SwiftUI
import UniformTypeIdentifiers
import WatchtowerCore

/// The project page shown in the chat detail area (spec §6.1).
struct ProjectDetailView: View {
    @State var vm: ProjectDetailViewModel
    @Bindable var chatVM: ChatViewModel
    let dbPool: DatabasePool
    @State private var showSourcePicker = false
    @State private var showFileImporter = false
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let message = vm.errorMessage {
                    Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                TextField("Project name", text: $vm.nameDraft)
                    .font(.title2.weight(.semibold))
                    .textFieldStyle(.plain)
                    .onSubmit { vm.rename(vm.nameDraft); chatVM.reloadProjects() }

                section("Instructions", caption: "Given to the assistant in every chat of this project.") {
                    TextEditor(text: Binding(get: { vm.instructionsDraft }, set: { vm.instructionsEdited($0) }))
                        .font(.body)
                        .frame(minHeight: 120)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(.separatorColor)))
                }

                section("Files", caption: "Text files are read in full; images and PDFs are shown to Claude at the start of each session.") {
                    ForEach(vm.files) { file in
                        HStack {
                            Image(systemName: file.mime.hasPrefix("image/") ? "photo" : "doc")
                            Text(file.name)
                            Spacer()
                            Button { vm.removeFile(file) } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    Button("Add files…") { showFileImporter = true }
                }
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    loadDropped(providers)
                    return true
                }

                section("Pinned sources", caption: "Where the assistant looks first for this project.") {
                    ForEach(vm.sources) { source in
                        HStack {
                            Text(source.label)
                            Text(source.kind.replacingOccurrences(of: "_", with: " "))
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button { vm.removeSource(source) } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    Button("Pin a source…") { showSourcePicker = true }
                }

                section("Chats", caption: nil) {
                    Button("New chat in this project") { chatVM.newConversation(projectID: vm.projectID) }
                    ForEach(vm.chats) { chat in
                        Button(chat.displayTitle) { chatVM.select(conversationID: chat.id) }
                            .buttonStyle(.link)
                    }
                }

                Button("Delete project…", role: .destructive) { confirmDelete = true }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .onAppear { vm.load() }
        .onDisappear { Task { await vm.flush() } }
        .sheet(isPresented: $showSourcePicker) {
            ProjectSourcePickerSheet(dbPool: dbPool) { vm.addSource($0) }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { vm.addFiles(urls) }
        }
        .confirmationDialog("Delete this project?", isPresented: $confirmDelete) {
            Button("Delete project and its files", role: .destructive) {
                if vm.deleteProject() { chatVM.projectDeleted(vm.projectID) }
            }
        } message: {
            Text("Its chats are kept and move out of the project.")
        }
    }

    private func section<Content: View>(_ title: String, caption: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if let caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
            content()
        }
    }

    private func loadDropped(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in vm.addFiles([url]) }
            }
        }
    }
}
```

(`ChatAttachment` must be `Identifiable`; if Task 10 did not declare it, add `Identifiable` conformance in `ChatModels.swift`.)

- [ ] **Step E6: Sidebar Projects section and detail switch**

In `ChatSidebarView.swift`, in the Projects slot above the history groups:

```swift
    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Projects").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { chatVM.createProject(name: "") } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("New project")
            }
            ForEach(chatVM.projects) { project in
                Button { chatVM.openProject(project.id) } label: {
                    Label(project.name, systemImage: "folder")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 3)
                .background(chatVM.openProjectID == project.id ? Color.accentColor.opacity(0.15) : .clear)
            }
        }
        .padding(.horizontal, 8)
    }
```

Add a "Move to project" submenu to the conversation row's context menu (if Task 15 did not already wire one to real data):

```swift
            Menu("Move to project") {
                Button("None") { chatVM.moveConversation(conversation.id, toProject: nil) }
                ForEach(chatVM.projects) { project in
                    Button(project.name) { chatVM.moveConversation(conversation.id, toProject: project.id) }
                }
            }
```

and in `ChatViewModel`:

```swift
    func moveConversation(_ conversationID: Int64, toProject projectID: Int64?) {
        do {
            try dbManager.dbPool.write {
                try ChatConversationQueries.setProject($0, id: conversationID, projectID: projectID)
            }
            reloadConversations()
        } catch {
            errorMessage = "Could not move the chat: \(error.localizedDescription)"
        }
    }
```

In `ChatView.swift`, where the detail area chooses between the thread and the empty state, put the project page first:

```swift
            if let projectID = chatVM.openProjectID {
                ProjectDetailView(
                    vm: ProjectDetailViewModel(
                        projectID: projectID,
                        dbPool: appState.databaseManager!.dbPool,
                        importFile: { url, pid in try ChatAttachmentStore.importFile(url: url, projectID: pid) }
                    ),
                    chatVM: chatVM,
                    dbPool: appState.databaseManager!.dbPool
                )
                .id(projectID)
            } else {
                // existing thread / empty state
            }
```

(Adapt the `importFile` closure to Task 21's real call — it may need the db pool or an instance. Use the same non-optional DB accessor the rest of `ChatView` uses instead of `!` if one exists.)

- [ ] **Step E7: Build and run the chat test classes**

Run: `make test-swift FILTER=ChatViewModelTests` then `make test-swift FILTER=ProjectDetailViewModelTests` then `cd WatchtowerDesktop && swift build 2>&1 > /tmp/wt-build.log; echo "exit $?"`
Expected: PASS, PASS, `exit 0`.

- [ ] **Step E8: Commit**

```bash
git add WatchtowerDesktop/Sources/Views/Chat/ProjectDetailView.swift WatchtowerDesktop/Sources/Views/Chat/ProjectSourcePickerSheet.swift WatchtowerDesktop/Sources/Views/Chat/ChatSidebarView.swift WatchtowerDesktop/Sources/Views/Chat/ChatView.swift WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift WatchtowerDesktop/Sources/Services/Chat/ChatSessionClient.swift WatchtowerDesktop/Tests/ChatSessionClientTests.swift WatchtowerDesktop/Tests/ChatViewModelTests.swift WatchtowerDesktop/Sources/WatchtowerCore/Models/ChatModels.swift
git commit -m "feat(desktop): chat projects — sidebar, project page, --project-id

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 25: @-mentions

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/MentionTokenizer.swift` (tokenizer + `MentionCandidate` + `MentionSearch`)
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ChatTurnComposer.swift`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ComposerPickerModel.swift`
- Create: `WatchtowerDesktop/Sources/Views/Chat/MentionPicker.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Chat/ChatInput.swift`, `WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift`, the main-chat composer view (find with `grep -n "ChatInput(" WatchtowerDesktop/Sources/Views/Chat/*.swift`), the user-message view (find with `grep -rn "role == \"user\"\|isUser" WatchtowerDesktop/Sources/Views/Chat/`)
- Test: `WatchtowerDesktop/Tests/Core/MentionTokenizerTests.swift`, `WatchtowerDesktop/Tests/Core/ChatTurnComposerTests.swift`, `WatchtowerDesktop/Tests/Core/MentionSearchTests.swift`, `WatchtowerDesktop/Tests/Core/ComposerPickerModelTests.swift`, `WatchtowerDesktop/Tests/ChatViewModelTests.swift`

**Interfaces:**
- Consumes: `ChatEntitySearch`, `ChatEntityHit`, `ChatEntityKind` (Task 24C); `ChatViewModel.send(text:attachments:mentions:)`, `edit(messageID:newText:)` (Task 14).
- Produces: `ComposerTrigger{start: Int, query: String}`; `MentionTokenizer.activeQuery(text:cursor:) -> String?`, `.activeMention(text:cursor:) -> ComposerTrigger?`, `.replace(_:in:cursor:with:) -> ComposerEdit`, `.liveMentions(text:mentions:) -> [MentionCandidate]`, internal `.trigger(text:cursor:character:)`; `MentionCandidate{kind, ref, label, detail; referenceToken; insertionText}` with `Kind: person|channel|jira|target|track`; `MentionSearch.search(_ db:, query:) -> [MentionCandidate]`, `MentionSearch.resultLimit = 8`; `ChatTurnComposer.compose(text:skill:mentions:)`, `.skillLine(_:)`, `.displayParts(_:) -> ChatTurnDisplayParts`, `.recompose(stored:newBody:)`; `ComposerPickerKey`, `ComposerEdit`, `ComposerKeyResult`, `ComposerPickerItem`, `ComposerPickerModel` (`update(text:cursor:)`, `handle(_:text:cursor:)`, `accept(index:text:cursor:)`, `removeMention(_:)`, `reset()`, `mentions`, `items`, `selectedIndex`, `isOpen`); `ChatInput(onCursorChange:onPickerKey:)`; `ChatViewModel.composer`.

Decisions: a mention is inserted as plain `@Label ` text (the composer is a plain-text `NSTextView`); the "chip" is a removable chip row above the field listing the pending mentions, and only mentions whose `@Label` is still in the text at send time are sent (`liveMentions`). The stored user message is the composed turn (`CHAT-01`: exactly what was sent is what is persisted and replayed); the bubble renders `displayParts(…).body` with chips for the skill and references. Keyboard accept restores the caret after the insertion; a mouse click on a picker row sets the text and leaves the caret at the end.

- [ ] **Step 1: Write the failing tokenizer + composer tests**

Create `WatchtowerDesktop/Tests/Core/MentionTokenizerTests.swift`:

```swift
import XCTest
@testable import WatchtowerCore

final class MentionTokenizerTests: XCTestCase {
    private func utf16Count(_ s: String) -> Int { s.utf16.count }

    func testActiveQueryAtStartAndAfterSpace() {
        XCTAssertEqual(MentionTokenizer.activeQuery(text: "@an", cursor: 3), "an")
        XCTAssertEqual(MentionTokenizer.activeQuery(text: "ask @an", cursor: 7), "an")
        XCTAssertEqual(MentionTokenizer.activeQuery(text: "ask @", cursor: 5), "")
        XCTAssertEqual(MentionTokenizer.activeMention(text: "ask @an", cursor: 7), ComposerTrigger(start: 4, query: "an"))
    }

    func testNoTriggerInsideEmailOrAfterSpaceInQuery() {
        XCTAssertNil(MentionTokenizer.activeQuery(text: "anna@example.com", cursor: 16))
        XCTAssertNil(MentionTokenizer.activeQuery(text: "@anna ivanova", cursor: 13), "query ends at whitespace")
        XCTAssertNil(MentionTokenizer.activeQuery(text: "no mention", cursor: 10))
    }

    func testCursorInTheMiddleUsesTextBeforeCursorOnly() {
        let text = "ask @an about it"
        XCTAssertEqual(MentionTokenizer.activeQuery(text: text, cursor: 7), "an")
        XCTAssertNil(MentionTokenizer.activeQuery(text: text, cursor: text.utf16.count))
    }

    func testCursorIsUTF16Offset() {
        let text = "привет 👋 @Ив"
        XCTAssertEqual(MentionTokenizer.activeQuery(text: text, cursor: utf16Count(text)), "Ив")
    }

    func testOutOfRangeCursorIsNil() {
        XCTAssertNil(MentionTokenizer.activeQuery(text: "@a", cursor: 5))
        XCTAssertNil(MentionTokenizer.activeQuery(text: "@a", cursor: -1))
    }

    func testReplaceActiveQueryKeepsSuffixAndMovesCursor() {
        let edit = MentionTokenizer.replace(
            ComposerTrigger(start: 4, query: "an"), in: "ask @an about", cursor: 7, with: "@Anna Ivanova ")
        XCTAssertEqual(edit.text, "ask @Anna Ivanova  about")
        XCTAssertEqual(edit.cursor, 4 + "@Anna Ivanova ".utf16.count)
    }

    func testLiveMentionsKeepsOnlyThoseStillInTextDeduped() {
        let anna = MentionCandidate(kind: .person, ref: "1:U1", label: "Anna", detail: "")
        let pay = MentionCandidate(kind: .jira, ref: "PAY-1", label: "PAY-1", detail: "")
        XCTAssertEqual(
            MentionTokenizer.liveMentions(text: "ping @Anna about it", mentions: [anna, pay, anna]),
            [anna]
        )
    }

    func testReferenceTokensAndInsertionText() {
        XCTAssertEqual(MentionCandidate(kind: .person, ref: "1:U1", label: "Anna", detail: "").referenceToken, "person:1:U1")
        XCTAssertEqual(MentionCandidate(kind: .channel, ref: "1:C1", label: "#pay", detail: "").referenceToken, "channel:1:C1")
        XCTAssertEqual(MentionCandidate(kind: .jira, ref: "PAY-1", label: "PAY-1", detail: "").referenceToken, "jira:PAY-1")
        XCTAssertEqual(MentionCandidate(kind: .target, ref: "5", label: "Ship", detail: "").referenceToken, "target:5")
        XCTAssertEqual(MentionCandidate(kind: .track, ref: "9", label: "Rev", detail: "").referenceToken, "track:9")
        XCTAssertEqual(MentionCandidate(kind: .channel, ref: "1:C1", label: "#pay", detail: "").insertionText, "@#pay")
    }

    func testCandidateFromHitSkipsJiraProjects() {
        XCTAssertNil(MentionCandidate(hit: ChatEntityHit(kind: .jiraProject, ref: "PAY", label: "PAY", detail: "")))
        XCTAssertEqual(
            MentionCandidate(hit: ChatEntityHit(kind: .jiraIssue, ref: "PAY-1", label: "PAY-1", detail: "x"))?.kind,
            .jira
        )
    }
}
```

Create `WatchtowerDesktop/Tests/Core/ChatTurnComposerTests.swift`:

```swift
import XCTest
@testable import WatchtowerCore

final class ChatTurnComposerTests: XCTestCase {
    private let anna = MentionCandidate(kind: .person, ref: "1:U1", label: "Anna \"Ann\" I", detail: "")
    private let pay = MentionCandidate(kind: .jira, ref: "PAY-1", label: "PAY-1", detail: "")

    func testComposePlainTextIsUnchangedButTrimmed() {
        XCTAssertEqual(ChatTurnComposer.compose(text: "  hello \n", skill: nil, mentions: []), "hello")
    }

    func testComposeAppendsReferencedLineWithEscapedLabels() {
        let out = ChatTurnComposer.compose(text: "ask @Anna \"Ann\" I about @PAY-1", skill: nil, mentions: [anna, pay])
        XCTAssertEqual(out, """
            ask @Anna "Ann" I about @PAY-1

            REFERENCED: person:1:U1 "Anna \\"Ann\\" I"; jira:PAY-1 "PAY-1"
            """)
    }

    func testComposePrefixesSkillLine() {
        XCTAssertEqual(
            ChatTurnComposer.compose(text: "draft it", skill: "status-update", mentions: []),
            "Use skill status-update: load it with load_skill first.\n\ndraft it"
        )
    }

    func testDisplayPartsRoundTrip() {
        let stored = ChatTurnComposer.compose(text: "line one\n\nline two", skill: "break-down", mentions: [anna, pay])
        let parts = ChatTurnComposer.displayParts(stored)
        XCTAssertEqual(parts.skill, "break-down")
        XCTAssertEqual(parts.body, "line one\n\nline two")
        XCTAssertEqual(parts.references, [
            ChatTurnReference(token: "person:1:U1", label: "Anna \"Ann\" I"),
            ChatTurnReference(token: "jira:PAY-1", label: "PAY-1")
        ])
    }

    func testDisplayPartsOfPlainLegacyMessage() {
        let parts = ChatTurnComposer.displayParts("just text\n\nmore")
        XCTAssertNil(parts.skill)
        XCTAssertEqual(parts.body, "just text\n\nmore")
        XCTAssertTrue(parts.references.isEmpty)
        XCTAssertNil(parts.referencedLine)
    }

    /// Anything the send path appended after the REFERENCED line (the
    /// "ACTIONS SINCE YOUR LAST MESSAGE" block) is not part of the body.
    func testDisplayPartsIgnoresTrailingBlocksAfterReferenced() {
        let stored = ChatTurnComposer.compose(text: "hi", skill: nil, mentions: [pay])
            + "\n\nACTIONS SINCE YOUR LAST MESSAGE:\n- approved x"
        XCTAssertEqual(ChatTurnComposer.displayParts(stored).body, "hi")
    }

    /// Editing a message keeps its skill and references (Review Focus 3).
    func testRecomposeKeepsSkillAndReferences() {
        let stored = ChatTurnComposer.compose(text: "old", skill: "break-down", mentions: [pay])
        XCTAssertEqual(
            ChatTurnComposer.recompose(stored: stored, newBody: "new"),
            ChatTurnComposer.compose(text: "new", skill: "break-down", mentions: [pay])
        )
        XCTAssertEqual(ChatTurnComposer.recompose(stored: "plain", newBody: "edited"), "edited")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test-swift FILTER=MentionTokenizerTests` then `make test-swift FILTER=ChatTurnComposerTests`
Expected: FAIL — `cannot find 'MentionTokenizer' in scope`, `cannot find 'ChatTurnComposer' in scope`.

- [ ] **Step 3: Implement tokenizer, candidate, composer**

Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/MentionTokenizer.swift`:

```swift
import Foundation
import GRDB

/// A trigger character's position (UTF-16 offset, the `NSTextView`
/// `selectedRange` unit) and the query typed after it, up to the cursor.
package struct ComposerTrigger: Equatable, Sendable {
    package let start: Int
    package let query: String

    package init(start: Int, query: String) {
        self.start = start
        self.query = query
    }
}

/// A text edit the composer applies: the new text and the caret after it.
package struct ComposerEdit: Equatable, Sendable {
    package let text: String
    package let cursor: Int

    package init(text: String, cursor: Int) {
        self.text = text
        self.cursor = cursor
    }
}

/// One thing an `@` mention can point at (spec §6.2).
package struct MentionCandidate: Equatable, Hashable, Sendable, Identifiable {
    package enum Kind: String, Sendable {
        case person, channel, jira, target, track
    }

    package let kind: Kind
    package let ref: String
    package let label: String
    package let detail: String

    package init(kind: Kind, ref: String, label: String, detail: String) {
        self.kind = kind
        self.ref = ref
        self.label = label
        self.detail = detail
    }

    /// nil for a Jira project hit — projects are pinned, not mentioned.
    package init?(hit: ChatEntityHit) {
        let kind: Kind
        switch hit.kind {
        case .person: kind = .person
        case .channel: kind = .channel
        case .jiraIssue: kind = .jira
        case .target: kind = .target
        case .track: kind = .track
        case .jiraProject: return nil
        }
        self.init(kind: kind, ref: hit.ref, label: hit.label, detail: hit.detail)
    }

    package var id: String { referenceToken }

    /// `person:<id>`, `channel:<id>`, `jira:<KEY>`, `target:<id>`, `track:<id>`.
    package var referenceToken: String { "\(kind.rawValue):\(ref)" }

    /// What the picker inserts into the composer text.
    package var insertionText: String { "@\(label)" }
}

package enum MentionTokenizer {
    static let maxQueryLength = 40

    /// The query after an active `@` ending at `cursor`, or nil.
    package static func activeQuery(text: String, cursor: Int) -> String? {
        activeMention(text: text, cursor: cursor)?.query
    }

    /// An `@` opens a mention only at the start of the text or after
    /// whitespace (so `anna@example.com` never does), and the query runs to
    /// the cursor without whitespace.
    package static func activeMention(text: String, cursor: Int) -> ComposerTrigger? {
        trigger(text: text, cursor: cursor, character: "@")
    }

    /// Replaces `trigger.start ..< cursor` with `replacement`.
    package static func replace(
        _ trigger: ComposerTrigger, in text: String, cursor: Int, with replacement: String
    ) -> ComposerEdit {
        let units = Array(text.utf16)
        let start = max(0, min(trigger.start, units.count))
        let end = max(start, min(cursor, units.count))
        let prefix = String(decoding: units[..<start], as: UTF16.self)
        let suffix = String(decoding: units[end...], as: UTF16.self)
        return ComposerEdit(text: prefix + replacement + suffix, cursor: start + replacement.utf16.count)
    }

    /// The picked mentions whose `@Label` is still in the text, in pick
    /// order, without duplicates.
    package static func liveMentions(text: String, mentions: [MentionCandidate]) -> [MentionCandidate] {
        var seen = Set<String>()
        return mentions.filter { text.contains($0.insertionText) && seen.insert($0.referenceToken).inserted }
    }

    /// Scans back from `cursor` to `character`; nil on whitespace first, on a
    /// non-boundary before the trigger, or on an over-long query.
    static func trigger(text: String, cursor: Int, character: Character) -> ComposerTrigger? {
        let units = Array(text.utf16)
        guard cursor >= 0, cursor <= units.count, let mark = character.utf16.first else { return nil }
        var index = cursor - 1
        while index >= 0 {
            let unit = units[index]
            if unit == mark {
                guard index == 0 || isWhitespace(units[index - 1]) else { return nil }
                let query = String(decoding: units[(index + 1)..<cursor], as: UTF16.self)
                guard query.count <= maxQueryLength else { return nil }
                return ComposerTrigger(start: index, query: query)
            }
            if isWhitespace(unit) { return nil }
            index -= 1
        }
        return nil
    }

    private static func isWhitespace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D
    }
}

/// `@` picker search (spec §6.2): people, Jira issues, Slack channels,
/// targets, tracks — prefix match, at most 8 results. Label-prefix hits come
/// first; ties keep kind order then each kind's own SQL order.
package enum MentionSearch {
    package static let resultLimit = 8

    package static func search(_ db: Database, query: String) throws -> [MentionCandidate] {
        var hits: [ChatEntityHit] = []
        for kind in [ChatEntityKind.person, .jiraIssue, .channel, .target, .track] {
            hits += try ChatEntitySearch.search(db, kind: kind, query: query, limit: resultLimit)
        }
        let candidates = hits.compactMap(MentionCandidate.init(hit:))
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let ranked = candidates.enumerated().sorted { lhs, rhs in
            let lp = labelMatches(lhs.element, needle) ? 0 : 1
            let rp = labelMatches(rhs.element, needle) ? 0 : 1
            return lp != rp ? lp < rp : lhs.offset < rhs.offset
        }
        return Array(ranked.map(\.element).prefix(resultLimit))
    }

    private static func labelMatches(_ candidate: MentionCandidate, _ needle: String) -> Bool {
        guard !needle.isEmpty else { return true }
        let label = candidate.label.hasPrefix("#") ? String(candidate.label.dropFirst()) : candidate.label
        return label.lowercased().hasPrefix(needle)
    }
}
```

Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ChatTurnComposer.swift`:

```swift
import Foundation

package struct ChatTurnReference: Equatable, Sendable {
    package let token: String
    package let label: String

    package init(token: String, label: String) {
        self.token = token
        self.label = label
    }
}

package struct ChatTurnDisplayParts: Equatable, Sendable {
    package let skill: String?
    package let body: String
    package let referencedLine: String?
    package let references: [ChatTurnReference]
}

/// The stored/sent user-turn format (spec §4.3, §6.2, §6.3), one place:
///
///     Use skill <name>: load it with load_skill first.   ← optional
///
///     <the owner's text>
///
///     REFERENCED: person:<id> "Label"; jira:PROJ-1 "PROJ-1"   ← optional
///
/// The stored message is exactly what was sent (CHAT-01, and replay
/// fidelity); the bubble renders `displayParts` so the owner sees their text
/// plus chips.
package enum ChatTurnComposer {
    static let referencedPrefix = "REFERENCED: "
    private static let skillLinePrefix = "Use skill "
    private static let skillLineSuffix = ": load it with load_skill first."

    package static func skillLine(_ name: String) -> String {
        skillLinePrefix + name + skillLineSuffix
    }

    /// The skill name when `line` is exactly a `skillLine`, else nil.
    private static func skillName(inLine line: String) -> String? {
        guard line.hasPrefix(skillLinePrefix), line.hasSuffix(skillLineSuffix) else { return nil }
        let name = String(line.dropFirst(skillLinePrefix.count).dropLast(skillLineSuffix.count))
        return SkillsCatalog.isValidSkillName(name) ? name : nil
    }

    package static func compose(text: String, skill: String?, mentions: [MentionCandidate]) -> String {
        var parts: [String] = []
        if let skill { parts.append(skillLine(skill)) }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { parts.append(body) }
        if !mentions.isEmpty {
            let refs = mentions.map { "\($0.referenceToken) \"\(escape($0.label))\"" }
            parts.append(referencedPrefix + refs.joined(separator: "; "))
        }
        return parts.joined(separator: "\n\n")
    }

    package static func displayParts(_ stored: String) -> ChatTurnDisplayParts {
        var rest = stored
        var skill: String?
        let firstLine = rest.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        if let name = skillName(inLine: firstLine) {
            skill = name
            rest = String(rest.dropFirst(firstLine.count)).trimmingPrefixNewlines()
        }

        var referencedLine: String?
        var references: [ChatTurnReference] = []
        if let marker = referencedMarker(in: rest) {
            let after = rest[marker.upperBound...]
            let line = String(after.prefix { $0 != "\n" })
            referencedLine = referencedPrefix + line
            references = parseReferences(line)
            rest = String(rest[..<marker.lowerBound])
        }
        return ChatTurnDisplayParts(
            skill: skill,
            body: rest.trimmingCharacters(in: .whitespacesAndNewlines),
            referencedLine: referencedLine,
            references: references
        )
    }

    /// The stored turn for an edited message: same skill and references, new body.
    package static func recompose(stored: String, newBody: String) -> String {
        let parts = displayParts(stored)
        var out: [String] = []
        if let skill = parts.skill { out.append(skillLine(skill)) }
        let body = newBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { out.append(body) }
        if let line = parts.referencedLine { out.append(line) }
        return out.joined(separator: "\n\n")
    }

    /// The LAST `REFERENCED: ` that starts the text or follows a blank line.
    private static func referencedMarker(in text: String) -> Range<String.Index>? {
        if let range = text.range(of: "\n\n" + referencedPrefix, options: .backwards) {
            return range
        }
        return text.hasPrefix(referencedPrefix) ? text.range(of: referencedPrefix) : nil
    }

    /// Each item is `<token> "<escaped label>"`; a malformed item is dropped.
    private static func parseReferences(_ line: String) -> [ChatTurnReference] {
        splitReferences(line).compactMap { item in
            guard let space = item.firstIndex(of: " ") else { return nil }
            let token = String(item[..<space])
            let quoted = item[item.index(after: space)...]
            guard !token.isEmpty, quoted.count >= 2, quoted.hasPrefix("\""), quoted.hasSuffix("\"") else {
                return nil
            }
            return ChatTurnReference(token: token, label: unescape(String(quoted.dropFirst().dropLast())))
        }
    }

    /// Splits on `; ` outside quoted labels.
    private static func splitReferences(_ line: String) -> [String] {
        var items: [String] = []
        var current = ""
        var inQuotes = false
        var escaped = false
        var iterator = line.makeIterator()
        while let char = iterator.next() {
            if escaped { current.append(char); escaped = false; continue }
            if char == "\\" && inQuotes { current.append(char); escaped = true; continue }
            if char == "\"" { inQuotes.toggle() }
            if char == ";" && !inQuotes {
                items.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
            current.append(char)
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            items.append(current.trimmingCharacters(in: .whitespaces))
        }
        return items
    }

    private static func escape(_ label: String) -> String {
        label.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func unescape(_ label: String) -> String {
        label.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }
}

private extension String {
    func trimmingPrefixNewlines() -> String {
        String(drop { $0 == "\n" })
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test-swift FILTER=MentionTokenizerTests` then `make test-swift FILTER=ChatTurnComposerTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/MentionTokenizer.swift WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ChatTurnComposer.swift WatchtowerDesktop/Tests/Core/MentionTokenizerTests.swift WatchtowerDesktop/Tests/Core/ChatTurnComposerTests.swift
git commit -m "feat(desktop): mention tokenizer and the stored chat-turn format

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 6: Write the failing search + picker model tests**

Create `WatchtowerDesktop/Tests/Core/MentionSearchTests.swift`:

```swift
import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class MentionSearchTests: XCTestCase {
    func testMixesKindsCapsAtEightAndRanksLabelPrefixFirst() throws {
        let db = try TestDatabase.create()
        try db.write { d in
            for i in 0..<6 {
                try TestDatabase.insertUser(d, id: "1:U\(i)", name: "pa\(i)", displayName: "Old Pa\(i)")
            }
            try TestDatabase.insertChannel(d, id: "1:C1", name: "payments")
            _ = try TestDatabase.insertTarget(d, text: "Payments launch")
            _ = try TestDatabase.insertTrack(d, text: "Payout review")
            let hits = try MentionSearch.search(d, query: "pa")
            XCTAssertEqual(hits.count, MentionSearch.resultLimit)
            XCTAssertEqual(Array(hits.prefix(3)).map(\.kind), [.channel, .target, .track],
                           "label-prefix hits ('#payments', 'Payments launch', 'Payout review') beat word-prefix people")
        }
    }

    func testNeverReturnsJiraProjects() throws {
        let db = try TestDatabase.create()
        try db.write { d in
            let acct = try TestDatabase.insertJiraAccount(d, cloudID: "a")
            try d.execute(sql: """
                INSERT INTO jira_issues (account_id, key, project_key, summary, status, status_category,
                                         created_at, updated_at, synced_at)
                VALUES (?, 'PAY-1', 'PAY', 'x', 'Open', 'todo', 't', 't', 't')
                """, arguments: [acct])
            XCTAssertEqual(try MentionSearch.search(d, query: "PAY").map(\.referenceToken), ["jira:PAY-1"])
        }
    }
}
```

Create `WatchtowerDesktop/Tests/Core/ComposerPickerModelTests.swift`:

```swift
import XCTest
@testable import WatchtowerCore

@MainActor
final class ComposerPickerModelTests: XCTestCase {
    private let anna = MentionCandidate(kind: .person, ref: "1:U1", label: "Anna", detail: "@anna")
    private let pay = MentionCandidate(kind: .jira, ref: "PAY-1", label: "PAY-1", detail: "Refund")
    private var queries: [String] = []

    private func makeModel() -> ComposerPickerModel {
        ComposerPickerModel(searchMentions: { [unowned self] query in
            self.queries.append(query)
            return [self.anna, self.pay]
        })
    }

    func testOpensOnActiveMentionAndClosesWithoutOne() {
        let model = makeModel()
        model.update(text: "ask @an", cursor: 7)
        XCTAssertTrue(model.isOpen)
        XCTAssertEqual(model.items.map(\.title), ["Anna", "PAY-1"])
        XCTAssertEqual(queries, ["an"])
        model.update(text: "ask ", cursor: 4)
        XCTAssertFalse(model.isOpen)
    }

    func testArrowKeysWrapAndAcceptInsertsMention() {
        let model = makeModel()
        model.update(text: "ask @an", cursor: 7)
        XCTAssertEqual(model.handle(.down, text: "ask @an", cursor: 7), ComposerKeyResult(consumed: true, edit: nil))
        XCTAssertEqual(model.selectedIndex, 1)
        _ = model.handle(.down, text: "ask @an", cursor: 7)
        XCTAssertEqual(model.selectedIndex, 0, "wraps")
        _ = model.handle(.up, text: "ask @an", cursor: 7)
        XCTAssertEqual(model.selectedIndex, 1)

        let result = model.handle(.accept, text: "ask @an", cursor: 7)
        XCTAssertEqual(result.edit, ComposerEdit(text: "ask @PAY-1 ", cursor: 11))
        XCTAssertEqual(model.mentions, [pay])
        XCTAssertFalse(model.isOpen)
    }

    func testKeysPassThroughWhenClosed() {
        let model = makeModel()
        XCTAssertEqual(model.handle(.accept, text: "hi", cursor: 2), ComposerKeyResult(consumed: false, edit: nil))
    }

    func testEscapeSuppressesUntilANewMentionStarts() {
        let model = makeModel()
        model.update(text: "@an", cursor: 3)
        XCTAssertTrue(model.handle(.dismiss, text: "@an", cursor: 3).consumed)
        model.update(text: "@ann", cursor: 4)
        XCTAssertFalse(model.isOpen, "same @ stays dismissed while typing on")
        model.update(text: "@ann @p", cursor: 7)
        XCTAssertTrue(model.isOpen, "a new @ opens again")
    }

    func testAcceptingTheSameMentionTwiceKeepsOneChipAndResetClears() {
        let model = makeModel()
        model.update(text: "@a", cursor: 2)
        _ = model.accept(index: 0, text: "@a", cursor: 2)
        model.update(text: "@Anna @a", cursor: 8)
        _ = model.accept(index: 0, text: "@Anna @a", cursor: 8)
        XCTAssertEqual(model.mentions, [anna])
        model.removeMention(anna)
        XCTAssertTrue(model.mentions.isEmpty)
        model.update(text: "@a", cursor: 2)
        _ = model.accept(index: 0, text: "@a", cursor: 2)
        model.reset()
        XCTAssertTrue(model.mentions.isEmpty)
        XCTAssertFalse(model.isOpen)
    }

    func testEmptySearchResultKeepsPickerClosed() {
        let model = ComposerPickerModel(searchMentions: { _ in [] })
        model.update(text: "@zz", cursor: 3)
        XCTAssertFalse(model.isOpen)
        XCTAssertEqual(model.handle(.accept, text: "@zz", cursor: 3).consumed, false,
                       "Enter must still send when nothing matches")
    }
}
```

- [ ] **Step 7: Run tests to verify they fail**

Run: `make test-swift FILTER=MentionSearchTests` then `make test-swift FILTER=ComposerPickerModelTests`
Expected: MentionSearchTests PASS already (implemented in Step 3 — keep it as a regression pin); ComposerPickerModelTests FAIL — `cannot find 'ComposerPickerModel' in scope`.

- [ ] **Step 8: Implement the picker model**

Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ComposerPickerModel.swift`:

```swift
import Foundation
import Observation

package enum ComposerPickerKey: Sendable {
    case up, down, accept, dismiss
}

/// What a key did: `consumed == false` lets the text view handle it (Enter
/// sends, Esc stops); `edit` is a text change to apply with its caret.
package struct ComposerKeyResult: Equatable, Sendable {
    package let consumed: Bool
    package let edit: ComposerEdit?

    package init(consumed: Bool, edit: ComposerEdit?) {
        self.consumed = consumed
        self.edit = edit
    }
}

package struct ComposerPickerItem: Equatable, Identifiable, Sendable {
    package let id: String
    package let icon: String
    package let title: String
    package let subtitle: String
}

/// The composer's `@` picker state (spec §6.2): what is open, the rows, the
/// selection, and the mentions picked for the current draft. Lives on
/// `ChatViewModel` (so a draft's mentions survive navigation with it); the
/// search is injected so tests run without a database.
@MainActor
@Observable
package final class ComposerPickerModel {
    package enum Mode: Equatable, Sendable {
        case none
        case mention(query: String)
    }

    package private(set) var mode: Mode = .none
    package private(set) var items: [ComposerPickerItem] = []
    package private(set) var selectedIndex = 0
    package private(set) var mentions: [MentionCandidate] = []

    private var mentionHits: [MentionCandidate] = []
    private var suppressedStart: Int?
    private let searchMentions: (String) -> [MentionCandidate]

    package init(searchMentions: @escaping (String) -> [MentionCandidate]) {
        self.searchMentions = searchMentions
    }

    package var isOpen: Bool { mode != .none && !items.isEmpty }

    /// Called on every text/caret change.
    package func update(text: String, cursor: Int) {
        guard let trigger = MentionTokenizer.activeMention(text: text, cursor: cursor) else {
            suppressedStart = nil
            close()
            return
        }
        guard trigger.start != suppressedStart else {
            close()
            return
        }
        suppressedStart = nil
        mentionHits = searchMentions(trigger.query)
        items = mentionHits.map(Self.item(for:))
        mode = .mention(query: trigger.query)
        selectedIndex = 0
    }

    package func handle(_ key: ComposerPickerKey, text: String, cursor: Int) -> ComposerKeyResult {
        guard isOpen else { return ComposerKeyResult(consumed: false, edit: nil) }
        switch key {
        case .up:
            selectedIndex = (selectedIndex - 1 + items.count) % items.count
            return ComposerKeyResult(consumed: true, edit: nil)
        case .down:
            selectedIndex = (selectedIndex + 1) % items.count
            return ComposerKeyResult(consumed: true, edit: nil)
        case .dismiss:
            suppressedStart = MentionTokenizer.activeMention(text: text, cursor: cursor)?.start
            close()
            return ComposerKeyResult(consumed: true, edit: nil)
        case .accept:
            return ComposerKeyResult(consumed: true, edit: accept(index: selectedIndex, text: text, cursor: cursor))
        }
    }

    /// Inserts the row's mention in place of the active `@query`.
    package func accept(index: Int, text: String, cursor: Int) -> ComposerEdit? {
        guard case .mention = mode, mentionHits.indices.contains(index),
              let trigger = MentionTokenizer.activeMention(text: text, cursor: cursor) else { return nil }
        let candidate = mentionHits[index]
        let edit = MentionTokenizer.replace(trigger, in: text, cursor: cursor, with: candidate.insertionText + " ")
        if !mentions.contains(candidate) { mentions.append(candidate) }
        close()
        return edit
    }

    package func removeMention(_ candidate: MentionCandidate) {
        mentions.removeAll { $0 == candidate }
    }

    /// After a send: the draft is gone, so are its mentions.
    package func reset() {
        mentions = []
        suppressedStart = nil
        close()
    }

    private func close() {
        mode = .none
        items = []
        mentionHits = []
        selectedIndex = 0
    }

    package static func item(for candidate: MentionCandidate) -> ComposerPickerItem {
        let icon: String
        switch candidate.kind {
        case .person: icon = "person.crop.circle"
        case .channel: icon = "number"
        case .jira: icon = "ticket"
        case .target: icon = "target"
        case .track: icon = "point.topleft.down.to.point.bottomright.curvepath"
        }
        return ComposerPickerItem(id: candidate.id, icon: icon, title: candidate.label, subtitle: candidate.detail)
    }
}
```

- [ ] **Step 9: Run tests to verify they pass**

Run: `make test-swift FILTER=ComposerPickerModelTests` then `make test-swift FILTER=MentionSearchTests`
Expected: PASS.

- [ ] **Step 10: Commit**

```bash
git add WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ComposerPickerModel.swift WatchtowerDesktop/Tests/Core/ComposerPickerModelTests.swift WatchtowerDesktop/Tests/Core/MentionSearchTests.swift
git commit -m "feat(desktop): composer @-mention picker model and search

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 11: Write the failing ChatViewModel tests**

Append to `WatchtowerDesktop/Tests/ChatViewModelTests.swift`:

```swift
    func testSendAppendsReferencedLineForLiveMentionsAndPersistsIt() throws {
        let vm = try makeViewModel()
        let anna = MentionCandidate(kind: .person, ref: "1:U1", label: "Anna", detail: "")
        let gone = MentionCandidate(kind: .jira, ref: "PAY-1", label: "PAY-1", detail: "")
        vm.send(text: "ask @Anna", attachments: [], mentions: [anna, gone])

        let expected = "ask @Anna\n\nREFERENCED: person:1:U1 \"Anna\""
        XCTAssertEqual(fakeProcess.sentTurns.last?.text.hasPrefix(expected), true,
                       "the turn text carries the live mention only")
        XCTAssertEqual(try lastStoredUserText(vm), expected, "what was sent is what is stored (CHAT-01)")
        XCTAssertTrue(vm.composer.mentions.isEmpty, "the draft's mentions are cleared after send")
    }

    func testEditKeepsReferences() throws {
        let vm = try makeViewModel()
        let pay = MentionCandidate(kind: .jira, ref: "PAY-1", label: "PAY-1", detail: "")
        vm.send(text: "look at @PAY-1", attachments: [], mentions: [pay])
        let messageID = try XCTUnwrap(lastStoredUserID(vm))
        vm.edit(messageID: messageID, newText: "now @PAY-1 again")
        XCTAssertEqual(try lastStoredUserText(vm),
                       "now @PAY-1 again\n\nREFERENCED: jira:PAY-1 \"PAY-1\"")
    }
```

(`fakeProcess.sentTurns`, `lastStoredUserText`, `lastStoredUserID` — use/extend the Task 14 fixture's capture of `turn` commands and its DB read helpers; add the two small read helpers to the test class if absent, reading `ChatTreeQueries.activePath(db, conversationID:)` and taking the last `role == "user"` row.)

- [ ] **Step 12: Run tests to verify they fail**

Run: `make test-swift FILTER=ChatViewModelTests`
Expected: FAIL — `value of type 'ChatViewModel' has no member 'composer'` / text mismatch.

- [ ] **Step 13: Implement VM + composer + bubble wiring**

In `ChatViewModel.swift`:

```swift
    /// The composer's @-picker and the current draft's picked mentions.
    let composer: ComposerPickerModel
```

initialized in `init` (after `dbManager` is stored):

```swift
        let pool = dbManager.dbPool
        self.composer = ComposerPickerModel(searchMentions: { query in
            do {
                return try pool.read { try MentionSearch.search($0, query: query) }
            } catch {
                NSLog("ChatViewModel: mention search failed: %@", error.localizedDescription)
                return []
            }
        })
```

In `send(text:attachments:mentions:)` (change the parameter type to `[MentionCandidate]` if Task 14 used a stub), compute the turn text first and use it wherever Task 14 used `text` for the persisted user message and the `turn` command (the ACTIONS block is appended after it, as before):

```swift
        let live = MentionTokenizer.liveMentions(text: text, mentions: mentions)
        let turnText = ChatTurnComposer.compose(text: text, skill: nil, mentions: live)
        guard !turnText.isEmpty else { return }
        composer.reset()
```

In `edit(messageID:newText:)`, before creating the sibling user message:

```swift
        let original = try dbManager.dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT text FROM chat_messages WHERE id = ?", arguments: [messageID])
        } ?? ""
        let turnText = ChatTurnComposer.recompose(stored: original, newBody: newText)
```

and use `turnText` in place of `newText` for the stored sibling and the turn. Wherever Task 14/15 pre-fills an editor or the "↑ edits last message" composer with a stored user text, pre-fill `ChatTurnComposer.displayParts(stored).body` instead.

In `ChatInput.swift`: add `import WatchtowerCore`; add to `ChatInput`, `ChatInputContent` and `ExpandingTextInput` (passing through):

```swift
    /// Called with the full text and the caret (UTF-16 offset) on every edit
    /// or caret move — the @/ pickers' input.
    var onCursorChange: ((String, Int) -> Void)?
    /// Offered Up/Down/Enter/Tab/Esc first while a picker may be open;
    /// `consumed == false` falls through to the normal handling.
    var onPickerKey: ((ComposerPickerKey, String, Int) -> ComposerKeyResult)?
```

(defaulted to `nil` on `ChatInput`/`ChatInputContent` so the Discuss-chat call sites are unchanged). In `ExpandingTextInput.updateNSView`, first line: `context.coordinator.parent = self` (so the closures stay current). In the `Coordinator`:

```swift
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.onCursorChange?(textView.string, textView.selectedRange().location)
        }

        private static func pickerKey(for selector: Selector) -> ComposerPickerKey? {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): return .up
            case #selector(NSResponder.moveDown(_:)): return .down
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)): return .accept
            case #selector(NSResponder.cancelOperation(_:)): return .dismiss
            default: return nil
            }
        }

        private func apply(_ edit: ComposerEdit, to textView: NSTextView) {
            textView.string = edit.text
            textView.setSelectedRange(NSRange(location: edit.cursor, length: 0))
            parent.text = edit.text
            recalculateHeight(textView)
            parent.onCursorChange?(edit.text, edit.cursor)
        }
```

and at the very top of `textView(_:doCommandBy:)` — before the Enter/Shift+Enter branch and before Task 15's Esc/↑ handling:

```swift
            if let handler = parent.onPickerKey, let key = Self.pickerKey(for: sel) {
                let result = handler(key, textView.string, textView.selectedRange().location)
                if let edit = result.edit { apply(edit, to: textView) }
                if result.consumed { return true }
            }
```

Create `WatchtowerDesktop/Sources/Views/Chat/MentionPicker.swift`:

```swift
import SwiftUI
import WatchtowerCore

/// The @/`/` picker list shown above the composer while open.
struct ComposerPickerList: View {
    let items: [ComposerPickerItem]
    let selectedIndex: Int
    let onPick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button { onPick(index) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.icon).frame(width: 18)
                        Text(item.title).lineLimit(1)
                        Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(index == selectedIndex ? Color.accentColor.opacity(0.18) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(.separatorColor)))
        .padding(.horizontal, 12)
    }
}

/// Removable chips for the draft's picked mentions (and, from Task 26, its skill).
struct ComposerChipsRow: View {
    let mentions: [MentionCandidate]
    var skill: String?
    let onRemoveMention: (MentionCandidate) -> Void
    var onRemoveSkill: (() -> Void)?

    var body: some View {
        if !mentions.isEmpty || skill != nil {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if let skill {
                        chip("/" + skill, icon: "wand.and.stars") { onRemoveSkill?() }
                    }
                    ForEach(mentions) { mention in
                        chip(mention.label, icon: ComposerPickerModel.item(for: mention).icon) { onRemoveMention(mention) }
                    }
                }
                .padding(.horizontal, 12)
            }
        }
    }

    private func chip(_ title: String, icon: String, onRemove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(title).lineLimit(1)
            Button(action: onRemove) { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
    }
}
```

In the main-chat composer view (where Task 15 instantiates `ChatInput`), wrap it:

```swift
        VStack(spacing: 4) {
            if chatVM.composer.isOpen {
                ComposerPickerList(items: chatVM.composer.items, selectedIndex: chatVM.composer.selectedIndex) { index in
                    if let edit = chatVM.composer.accept(index: index, text: chatVM.draft, cursor: lastCursor) {
                        chatVM.draft = edit.text
                    }
                }
            }
            ComposerChipsRow(mentions: chatVM.composer.mentions,
                             onRemoveMention: { chatVM.composer.removeMention($0) })
            ChatInput(
                text: $chatVM.draft,
                // … Task 15's existing arguments …
                onCursorChange: { text, cursor in
                    lastCursor = cursor
                    chatVM.composer.update(text: text, cursor: cursor)
                },
                onPickerKey: { key, text, cursor in chatVM.composer.handle(key, text: text, cursor: cursor) }
            )
        }
```

with `@State private var lastCursor = 0`, and the send action calling `chatVM.send(text: chatVM.draft, attachments: …, mentions: chatVM.composer.mentions)`. (`chatVM.draft` is Task 14/15's composer text binding — use its real name.)

In the user-message view, render the display split instead of the raw stored text:

```swift
        let parts = ChatTurnComposer.displayParts(message.text)
        VStack(alignment: .trailing, spacing: 4) {
            if parts.skill != nil || !parts.references.isEmpty {
                HStack(spacing: 4) {
                    if let skill = parts.skill {
                        Label("/" + skill, systemImage: "wand.and.stars").font(.caption)
                    }
                    ForEach(parts.references, id: \.token) { ref in
                        Text("@" + ref.label).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Text(parts.body)   // keep Task 15's existing text styling/modifiers
        }
```

Copy on a user message copies `parts.body`.

- [ ] **Step 14: Run tests and build**

Run: `make test-swift FILTER=ChatViewModelTests` then `make test-swift FILTER=ChatInputTests` then `cd WatchtowerDesktop && swift build > /tmp/wt-build.log 2>&1; echo "exit $?"`
Expected: PASS, PASS (the existing `ChatInputContent` tests still compile — new params are defaulted), `exit 0`.

- [ ] **Step 15: Commit**

```bash
git add WatchtowerDesktop/Sources/Views/Chat/MentionPicker.swift WatchtowerDesktop/Sources/Views/Chat/ChatInput.swift WatchtowerDesktop/Sources/Views/Chat/ WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ComposerPickerModel.swift WatchtowerDesktop/Tests/ChatViewModelTests.swift
git commit -m "feat(desktop): @-mentions in the chat composer with REFERENCED turn suffix

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 26: `/` skills

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Skills/SkillsCatalog.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/MentionTokenizer.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ComposerPickerModel.swift`
- Modify: `WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift`, the main-chat composer view (Task 25 Step 13)
- Test: `WatchtowerDesktop/Tests/Core/SkillsCatalogTests.swift`, `WatchtowerDesktop/Tests/Core/MentionTokenizerTests.swift`, `WatchtowerDesktop/Tests/Core/ComposerPickerModelTests.swift`, `WatchtowerDesktop/Tests/ChatViewModelTests.swift`

**Interfaces:**
- Consumes: `SkillsCatalog.list(dir:)`, `SkillsCatalog.isValidSkillName(_:)`, `SkillSummary`; Task 25's tokenizer, picker model, `ChatTurnComposer.skillLine`.
- Produces: `SkillsCatalog.chatContextTypes` ∋ `"main"`; `SkillsCatalog.pickerSkills(contextType:dir:) -> [SkillSummary]`; `MentionTokenizer.activeSkill(text:cursor:) -> ComposerTrigger?`; `ComposerPickerModel.Mode.skill(query:)`, `ComposerPickerModel.skill`, `clearSkill()`, init param `skills:`; `ChatViewModel.send(text:attachments:mentions:skill:)`.

Decisions: `/` opens the skill picker only when it is the first non-whitespace character of the draft and the query is a valid skill-name prefix (so `/usr/bin` mid-text or a URL never triggers). Picking removes the `/query` text and shows a `/name` chip; the skill line is added at send (`ChatTurnComposer.compose(…skill:)`). The main chat's system prompt already lists skills (Go `internal/chat` block 6); adding `"main"` to `chatContextTypes` is the Swift record that the main chat is a skills surface and gates the picker — no Swift prompt uses `promptBlock(contextType: "main")`.

- [ ] **Step 1: Write the failing tests**

In `WatchtowerDesktop/Tests/Core/SkillsCatalogTests.swift`, replace `testChatContextTypesMatchesTheContract` with:

```swift
    func testChatContextTypesMatchesTheContract() {
        XCTAssertEqual(SkillsCatalog.chatContextTypes,
                       ["main", "meeting", "target", "track", "idea"])
    }

    func testPickerSkillsListsOnlyEnabledSkillsOnAListedSurface() {
        seedMixedCatalog()
        XCTAssertEqual(SkillsCatalog.pickerSkills(contextType: "main", dir: dir).map(\.name),
                       ["alpha-on", "beta-on"])
        XCTAssertTrue(SkillsCatalog.pickerSkills(contextType: "onboarding", dir: dir).isEmpty)
        XCTAssertTrue(SkillsCatalog.pickerSkills(contextType: "main", dir: nil).isEmpty)
    }
```

Append to `WatchtowerDesktop/Tests/Core/MentionTokenizerTests.swift`:

```swift
    func testActiveSkillOnlyAtTheStartOfTheDraft() {
        XCTAssertEqual(MentionTokenizer.activeSkill(text: "/sta", cursor: 4), ComposerTrigger(start: 0, query: "sta"))
        XCTAssertEqual(MentionTokenizer.activeSkill(text: "  /", cursor: 3), ComposerTrigger(start: 2, query: ""))
        XCTAssertNil(MentionTokenizer.activeSkill(text: "see /usr", cursor: 8), "not the first word")
        XCTAssertNil(MentionTokenizer.activeSkill(text: "/usr/bin", cursor: 8), "second slash is mid-word")
        XCTAssertNil(MentionTokenizer.activeSkill(text: "/Status!", cursor: 8), "not a skill-name prefix")
        XCTAssertNil(MentionTokenizer.activeSkill(text: "/status now", cursor: 11), "query ended")
    }
```

Append to `WatchtowerDesktop/Tests/Core/ComposerPickerModelTests.swift`:

```swift
    private func skill(_ name: String) -> SkillSummary {
        SkillSummary(name: name, description: "Does \(name).", enabled: true)
    }

    func testSlashOpensSkillPickerAndAcceptSetsSkillAndClearsQuery() {
        let model = ComposerPickerModel(
            searchMentions: { _ in [] },
            skills: { [self.skill("break-down"), self.skill("status-update")] }
        )
        model.update(text: "/st", cursor: 3)
        XCTAssertEqual(model.mode, .skill(query: "st"))
        XCTAssertEqual(model.items.map(\.title), ["status-update"], "prefix filter on the name")
        let result = model.handle(.accept, text: "/st", cursor: 3)
        XCTAssertEqual(result.edit, ComposerEdit(text: "", cursor: 0))
        XCTAssertEqual(model.skill, "status-update")
        model.clearSkill()
        XCTAssertNil(model.skill)
    }

    func testBareSlashListsAllSkillsAndResetClearsSkill() {
        let model = ComposerPickerModel(searchMentions: { _ in [] }, skills: { [self.skill("a-one"), self.skill("b-two")] })
        model.update(text: "/", cursor: 1)
        XCTAssertEqual(model.items.map(\.title), ["a-one", "b-two"])
        _ = model.accept(index: 1, text: "/", cursor: 1)
        XCTAssertEqual(model.skill, "b-two")
        model.reset()
        XCTAssertNil(model.skill)
    }
```

Append to `WatchtowerDesktop/Tests/ChatViewModelTests.swift`:

```swift
    func testSendWithSkillPrefixesTheSkillLine() throws {
        let vm = try makeViewModel()
        vm.send(text: "for PAY", attachments: [], mentions: [], skill: "status-update")
        XCTAssertEqual(try lastStoredUserText(vm),
                       "Use skill status-update: load it with load_skill first.\n\nfor PAY")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test-swift FILTER=SkillsCatalogTests` then `make test-swift FILTER=MentionTokenizerTests` then `make test-swift FILTER=ComposerPickerModelTests` then `make test-swift FILTER=ChatViewModelTests`
Expected: FAIL — set mismatch; `has no member 'pickerSkills'`, `'activeSkill'`, `extra argument 'skills'`, `extra argument 'skill'`.

- [ ] **Step 3: Implement `SkillsCatalog`**

In `SkillsCatalog.swift`, replace the `chatContextTypes` declaration and its doc comment with:

```swift
    /// Chat surfaces that offer skills, mirroring the assistant contract in
    /// `docs/review/review-rules.md` ("The assistant & chat contracts").
    /// Setup/onboarding chats are deliberately absent.
    ///
    /// The four Discuss chats build their prompts in Swift and read the set
    /// through `promptBlock(contextType:dir:)`. `main` — the main AI Chat, whose
    /// conversations store no `context_type` — has its prompt built in Go
    /// (`internal/chat`, which lists skills itself); it is listed here because
    /// the `/` skill picker reads the set through `pickerSkills`.
    package static let chatContextTypes: Set<String> = [
        "main", "meeting", "target", "track", "idea"
    ]
```

and add below `promptBlock(contextType:dir:)`:

```swift
    /// The enabled skills a surface's `/` picker offers; empty for a surface
    /// not in `chatContextTypes`.
    package nonisolated static func pickerSkills(
        contextType: String,
        dir: String? = defaultDir()
    ) -> [SkillSummary] {
        guard chatContextTypes.contains(contextType) else { return [] }
        return list(dir: dir).filter(\.enabled)
    }
```

- [ ] **Step 4: Implement the tokenizer and picker skill mode**

In `MentionTokenizer.swift` add:

```swift
    /// A `/` opens the skill picker only as the first non-whitespace character
    /// of the draft, with a query that is a valid skill-name prefix.
    package static func activeSkill(text: String, cursor: Int) -> ComposerTrigger? {
        guard let trigger = trigger(text: text, cursor: cursor, character: "/") else { return nil }
        let before = String(decoding: Array(text.utf16)[..<trigger.start], as: UTF16.self)
        guard before.allSatisfy(\.isWhitespace) else { return nil }
        guard trigger.query.isEmpty || SkillsCatalog.isValidSkillName(trigger.query) else { return nil }
        return trigger
    }
```

In `ComposerPickerModel.swift`:

1. `Mode` gains `case skill(query: String)`.
2. Add `package private(set) var skill: String?`, `private var skillHits: [SkillSummary] = []`, `private let skills: () -> [SkillSummary]`.
3. Init becomes `package init(searchMentions: @escaping (String) -> [MentionCandidate], skills: @escaping () -> [SkillSummary] = { [] })` storing both.
4. At the top of `update(text:cursor:)`:

```swift
        if let trigger = MentionTokenizer.activeSkill(text: text, cursor: cursor) {
            guard trigger.start != suppressedStart else {
                close()
                return
            }
            suppressedStart = nil
            skillHits = skills().filter { trigger.query.isEmpty || $0.name.hasPrefix(trigger.query) }
            items = skillHits.map {
                ComposerPickerItem(id: "skill:" + $0.name, icon: "wand.and.stars", title: $0.name, subtitle: $0.description)
            }
            mentionHits = []
            mode = .skill(query: trigger.query)
            selectedIndex = 0
            return
        }
```

5. In `handle`'s `.dismiss` branch, compute the start from whichever trigger is active: `suppressedStart = (MentionTokenizer.activeSkill(text: text, cursor: cursor) ?? MentionTokenizer.activeMention(text: text, cursor: cursor))?.start`.
6. Replace `accept(index:text:cursor:)` with:

```swift
    package func accept(index: Int, text: String, cursor: Int) -> ComposerEdit? {
        switch mode {
        case .skill:
            guard skillHits.indices.contains(index),
                  let trigger = MentionTokenizer.activeSkill(text: text, cursor: cursor) else { return nil }
            skill = skillHits[index].name
            let edit = MentionTokenizer.replace(trigger, in: text, cursor: cursor, with: "")
            close()
            return edit
        case .mention:
            guard mentionHits.indices.contains(index),
                  let trigger = MentionTokenizer.activeMention(text: text, cursor: cursor) else { return nil }
            let candidate = mentionHits[index]
            let edit = MentionTokenizer.replace(trigger, in: text, cursor: cursor, with: candidate.insertionText + " ")
            if !mentions.contains(candidate) { mentions.append(candidate) }
            close()
            return edit
        case .none:
            return nil
        }
    }

    package func clearSkill() {
        skill = nil
    }
```

7. `reset()` also sets `skill = nil`; `close()` also sets `skillHits = []`.

- [ ] **Step 5: Implement the VM and composer wiring**

In `ChatViewModel`: pass `skills: { SkillsCatalog.pickerSkills(contextType: "main") }` to the `ComposerPickerModel` init; change the send signature to `send(text: String, attachments: [...], mentions: [MentionCandidate], skill: String? = nil)` (keep Task 14's attachments type) and use `ChatTurnComposer.compose(text: text, skill: skill, mentions: live)`. In the composer view: `ComposerChipsRow(mentions: …, skill: chatVM.composer.skill, onRemoveMention: …, onRemoveSkill: { chatVM.composer.clearSkill() })`, and the send action passes `skill: chatVM.composer.skill`.

- [ ] **Step 6: Run tests to verify they pass**

Run: `make test-swift FILTER=SkillsCatalogTests` then `make test-swift FILTER=MentionTokenizerTests` then `make test-swift FILTER=ComposerPickerModelTests` then `make test-swift FILTER=ChatViewModelTests` then `make test-swift FILTER=ChatSkillsPromptTests`
Expected: all PASS (the last runs the three Discuss-chat skills prompt suites — `MeetingChatSkillsPromptTests`, `TrackChatSkillsPromptTests`, `IdeaChatSkillsPromptTests` — unchanged).

- [ ] **Step 7: Commit**

```bash
git add WatchtowerDesktop/Sources/WatchtowerCore/Services/Skills/SkillsCatalog.swift WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/MentionTokenizer.swift WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ComposerPickerModel.swift WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift WatchtowerDesktop/Sources/Views/Chat/ WatchtowerDesktop/Tests/Core/SkillsCatalogTests.swift WatchtowerDesktop/Tests/Core/MentionTokenizerTests.swift WatchtowerDesktop/Tests/Core/ComposerPickerModelTests.swift WatchtowerDesktop/Tests/ChatViewModelTests.swift
git commit -m "feat(desktop): / skill picker in the main chat composer

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 27: Contracts & docs

**Files:**
- Create: `docs/inventory/chat.md`
- Modify: `docs/inventory/README.md`, `docs/app-guide.md` (line 114; the `### AI Chat` section at ~236; the Skills bullet at ~447), `CLAUDE.md` (new feature note), `docs/superpowers/specs/2026-09-26-chat-redesign-design.md` (status line 4)
- Modify (markers only): every CHAT guard test file

**Interfaces:**
- Consumes: the CHAT-01..05 guard tests planted by Tasks 2, 7, 11, 14, 22/23.
- Produces: the inventory contract file and the documentation of the finished feature.

- [ ] **Step 1: Find the guard tests**

Run: `grep -rn "func TestChat0[1-5]_" internal cmd; grep -rn "func testChat0[1-5]" WatchtowerDesktop/Tests`
Expected: at least one guard per contract. The phase files planned these (use the names the grep prints where they differ):

| Contract | Go | Swift |
|---|---|---|
| CHAT-01 | — (persistence is Swift-side) | `testChat01_UserMessagePersistedBeforeTurnSent`, `testChat01_PartialTextSurvivesStopAndCrash` (`Tests/ChatViewModelTests.swift`, Task 14) |
| CHAT-02 | `TestChat02_TranslatorNeverWipesText`, `TestChat02_EveryToolUseYieldsStartAndEnd` (`internal/chat/claude_translate_test.go`, Task 2) | `testChat02_EveryToolEventPersistedAsStep` (`Tests/ChatViewModelTests.swift`, Task 14) |
| CHAT-03 | `TestChat03_ChildReapedOnCloseAndStdinEOF` (`internal/chat/session_test.go`, Task 7) | `testChat03_NeverMoreThanThreeLive`, `testChat03_IdleSessionDiesWithinTTLPlusPoll` (`Tests/Core/ChatSessionPolicyTests.swift`, Task 11), `testChat03_CloseAllTerminatesEverySession` (`Tests/ChatSessionPoolTests.swift`, Task 11) |
| CHAT-04 | `TestChat04_NoContentOnArgv` (`internal/chat/claude_backend_test.go`, Task 7) | `testChat04_SessionArgvCarriesNoContent` (`Tests/ChatSessionClientTests.swift`, Task 11) |
| CHAT-05 | `TestChat05_ArtifactsHaveNoWritePath` (if Task 23 added one) | `testChat05_ArtifactActionsOnlyOpenOrCopy` (`Tests/Core/ArtifactActionsTests.swift`, Task 22) |

If a contract has **no** guard at all, stop and return to the task that owns it (the table's task column) — a guard is written with the code it pins, never invented in a docs task.

- [ ] **Step 2: Add `BEHAVIOR` markers**

Directly above each guard test function found in Step 1, add one line (Go `//`, Swift `///`):

```go
// BEHAVIOR CHAT-02 — see docs/inventory/chat.md
```

- [ ] **Step 3: Write `docs/inventory/chat.md`**

Create it with this content, replacing each **Guard** list with the exact names from Step 1:

```markdown
# Behavior Inventory — Chat (main AI Chat)

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @owner.

The main AI Chat: warm per-conversation `watchtower ai session` processes
speaking protocol v2 (NDJSON events on stdout, JSONL commands on stdin), a
Go-built system prompt, branching history in goose-owned chat tables, visible
tool steps and sources, attachments, artifacts, projects, mentions and
skills. Design: `docs/superpowers/specs/2026-09-26-chat-redesign-design.md`.

**Module:** `internal/chat/`, `cmd/ai_session.go`, `cmd/chat.go`,
`internal/db/chat.go`, `internal/db/chat_migrate.go`,
`internal/db/migrations/00074_chat_core.sql`,
`WatchtowerDesktop/Sources/Services/Chat/`,
`WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/`,
`WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift`,
`WatchtowerDesktop/Sources/Views/Chat/`
**Last full audit:** 2026-09-26

## CHAT-01 — owner text is never lost

**Status:** Enforced

**Observable:** The owner's message is written to `chat_messages` before the
`turn` command is sent to the session process, so a failed spawn, a crashed
session or an app quit mid-turn never loses what was typed. Assistant text
that already streamed survives Stop, a session crash and app quit: it is
persisted with `status='partial'` (Stop renders "Stopped" + Continue; a
crash renders an error card + Retry). The stored user message is exactly the
composed turn (`ChatTurnComposer`: optional skill line, the owner's text,
optional `REFERENCED:` line), so replay and edit see what the model saw.

**Guard:** `testChat01_UserMessagePersistedBeforeTurnSent`,
`testChat01_PartialTextSurvivesStopAndCrash`
(`WatchtowerDesktop/Tests/ChatViewModelTests.swift`)

## CHAT-02 — no silent tool activity

**Status:** Enforced

**Observable:** Every tool call in a turn becomes a `tool_start`/`tool_end`
event pair, is persisted as a `chat_turn_steps` row, and is visible as a step
in the message's steps block (a failed tool is a red step, not a turn
error). Protocol v2 has no `reset` event: text already shown is never wiped
— the Claude translator turns a mid-turn `tool_use` into steps, never into a
clear.

**Guard:** `TestChat02_TranslatorNeverWipesText`,
`TestChat02_EveryToolUseYieldsStartAndEnd`
(`internal/chat/claude_translate_test.go`);
`testChat02_EveryToolEventPersistedAsStep`
(`WatchtowerDesktop/Tests/ChatViewModelTests.swift`)

## CHAT-03 — bounded warm sessions

**Status:** Enforced

**Observable:** At most 3 session processes are alive at once (LRU
eviction); a session idle for 10 minutes is terminated within one 30 s poll
after its TTL (`ChatSessionPolicy.decide`); quitting the app (Cmd+Q, tray
Quit — `QuitCoordinator`) closes every session (`close`, then SIGTERM after
2 s). A session's `claude` child and its `watchtower mcp` server are reaped
when the session closes, when its stdin reaches EOF, and when its parent
dies — no orphan survives eviction or quit.

**Guard:** `testChat03_NeverMoreThanThreeLive`,
`testChat03_IdleSessionDiesWithinTTLPlusPoll`
(`WatchtowerDesktop/Tests/Core/ChatSessionPolicyTests.swift`);
`testChat03_CloseAllTerminatesEverySession`
(`WatchtowerDesktop/Tests/ChatSessionPoolTests.swift`);
`TestChat03_ChildReapedOnCloseAndStdinEOF` (`internal/chat/session_test.go`)

## CHAT-04 — content stays off argv

**Status:** Enforced

**Observable:** The system prompt, the owner's text and attachment paths
never appear on any process's argv: the prompt travels in a 0600 temp file
(`--system-prompt-file`, deleted when the session exits), turn text and
attachment paths travel in the `turn` command on stdin, the current turn id
reaches the MCP server through a 0600 `--turn-file`. `ai session`'s own
argv carries only ids and names (`--conversation`, `--provider`, `--model`,
`--surface`, `--project-id`, `--resume`, `--db-path`). Extends QC-03's
"secrets never on argv" to all chat content.

**Guard:** `TestChat04_NoContentOnArgv`
(`internal/chat/claude_backend_test.go`);
`testChat04_SessionArgvCarriesNoContent`
(`WatchtowerDesktop/Tests/ChatSessionClientTests.swift`)

## CHAT-05 — artifacts never send

**Status:** Enforced

**Observable:** Artifact actions only open or copy: an `email` artifact
opens a Gmail compose URL (or `mailto:`), a `slack` artifact copies its body
and opens the channel/thread deep link, an `event` artifact opens a Google
Calendar template URL, and Copy/Export write the clipboard or a local file.
Nothing is sent, posted or created in an external system from an artifact;
every external write in the chat goes through the tool registry's
Propose → Approve path (AGENT-01..06 unchanged).

**Guard:** `testChat05_ArtifactActionsOnlyOpenOrCopy`
(`WatchtowerDesktop/Tests/Core/ArtifactActionsTests.swift`)

## Changelog

- 2026-09-26: initial contracts CHAT-01..05 (spec `docs/superpowers/specs/2026-09-26-chat-redesign-design.md` §9).
```

- [ ] **Step 4: Add the README row**

In `docs/inventory/README.md`, append to the module table (after the Knowledge Search row):

```markdown
| Chat (main AI Chat) | [chat.md](chat.md) | `internal/chat/`, `cmd/ai_session.go`, `cmd/chat.go`, `internal/db/chat.go`, `internal/db/chat_migrate.go`, `internal/db/migrations/00074_chat_core.sql`, `WatchtowerDesktop/Sources/Services/Chat/`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/`, `WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift`, `WatchtowerDesktop/Sources/Views/Chat/` |
```

- [ ] **Step 5: Update `docs/app-guide.md`**

1. Replace line 114 (`**AI Chat integration** — Upcoming calendar events (next 48 hours) are automatically injected…`) — stale: nothing injects a calendar block into any live chat prompt (`internal/ai/context_builder.go`'s `buildCalendarContext` has no caller) — with:

```markdown
**AI Chat integration** — The assistant reads your calendar on demand: ask about your schedule and it looks events up with its calendar tool (upcoming events) or searches meetings, transcripts and recaps through knowledge search. Nothing is pre-loaded into the chat.
```

2. Replace the whole `### AI Chat` section (from `### AI Chat` up to, not including, `### Tracks`) with:

```markdown
### AI Chat
The main assistant: ask about your work, keep long conversations organized, attach files, get documents back, and have it do things — every change to the outside world waits for your Approve.

**Layout** — Your chats are on the left, grouped Pinned / Today / Yesterday / Previous 7 days / Previous 30 days / Older, with your Projects above them. Right-click a chat to rename, pin, move it to a project, archive or delete it; double-click the title in the toolbar to rename. New chat is ⌘N; ⌘K searches the text of every message and jumps to the hit. A chat gets a short title automatically after its first reply — a title you set yourself is never replaced.

**Answers show their work** — while the assistant works you see each step live ("Searched knowledge: payments rollout", "Opened PROJ-123"); when it is done the steps fold into "Worked for 12s · 4 steps" (click to expand the arguments and results; a failed step is marked red). Below the answer, source chips link to the Slack threads, Jira issues, emails, meetings, documents and people it used. Topical questions search everything Watchtower has synced and indexed (Slack, mail, Jira with comments, calendar, meeting transcripts and recaps, digests, decisions and ideas) — controlled by the Knowledge search feature toggle.

**Streaming and control** — text and formatting appear as they are written: tables, lists, quotes, and code blocks with a language label and Copy. Enter sends, Shift+Enter adds a line, Esc stops, ↑ in an empty composer edits your last message. Stop keeps what was already written ("Stopped" + Continue); an error shows a card with Retry and your message is never lost. Hover a reply for Copy, Regenerate and its model/time; hover your own message for Copy and Edit. Regenerating or editing keeps every version — switch between them with ‹ 1/2 ›.

**Provider and model** — the pill in the composer picks Claude, Codex or Ollama and the model (**Auto** = the provider's configured strong model; suggestions come from `watchtower ai models`, nothing is hardcoded). Claude gets the full experience: live token streaming, visible steps, images and PDFs. Codex and Ollama answer in the same chat but may show the reply all at once, may not show steps, and cannot read images or PDFs. Recently used chats stay warm (up to three, for ten minutes) so the next reply starts fast.

**Attachments** — paperclip, drag & drop, or paste an image. Images (PNG, JPEG, GIF, WebP) up to 5 MB, PDFs up to 32 MB, and text-like files (txt, md, csv, json, yaml, logs, source code) up to 256 KB; anything else is refused in the composer with the reason. Files are kept privately in the workspace folder and deleted with their chat.

**Artifacts** — anything you'll copy, send or keep (a document, a table, an email or Slack draft, an event, code) opens in the artifact panel on the right instead of cluttering the chat. Each change is a new version you can switch between; you can edit it (your edit becomes a version too), copy it, or export it (.md / .csv / .txt). Drafts open ready in their app but are **never sent** by Watchtower: an email opens in Gmail compose, a Slack draft is copied and its channel or thread is opened, an event opens Google Calendar's new-event page.

**Projects** — group chats that share context. A project has instructions (given to the assistant in every chat of the project), files (text files are read in full; images and PDFs are shown to Claude at the start of each session), and pinned sources — Jira projects, Slack channels, targets, tracks and people — that tell it where to look first. Start a chat from the project page with "New chat in this project", or move an existing chat into a project. Changes to a project reach an open chat when it starts a fresh session (a new chat always has them). Deleting a project deletes its files and keeps its chats.

**@-mentions and / skills** — type `@` to point at a person, Slack channel, Jira issue, target or track from your synced data (↑/↓ and Enter to pick, Esc to close); the pick appears as a chip and the assistant knows exactly which one you meant. Type `/` at the start of a message to pick one of your enabled skills; the assistant loads it before answering.

**Write tools (proposals):** the assistant can propose changes as well as answer — `create_target` (a task), `create_idea`, `create_track`, `remind_me`, `connect_jira_board`, `create_jira_issue`, and on existing Jira issues `add_jira_comment`, `transition_jira_issue` (move to a status), `assign_jira_issue` and `update_jira_issue` (summary, priority, labels, due date). A write tool never does anything by itself: calling it records a proposal and shows a card in the chat saying what it wants to do and why. Nothing happens until you press Approve; Reject discards it, and a failed action can be retried from the same card; a done card links to what was created or changed. Settings → Assistant tools lists every write tool with an "Execute without approval" switch — off by default, so each call asks. The switch is locked off for every tool that writes outside this Mac (all the Jira tools), which therefore always need your click. Proposals left over from an interrupted turn are gathered at the bottom of the chat, so nothing is stranded without a decision. The target chat's Discuss tab works the same way, alongside its own task-edit cards.

The Discuss chats (target, idea, meeting, track) share the new message rendering; they keep their own history and behavior.
```

3. In the Skills bullet (`- **Skills** — …`, ~line 447), replace `Every enabled skill is available in every Discuss chat (Meeting, Target, Track, Idea); when you ask for something a skill covers, the chat loads it and follows it.` with `Every enabled skill is available in the main AI Chat (type `/` to pick one explicitly) and in every Discuss chat (Meeting, Target, Track, Idea); when you ask for something a skill covers, the chat loads it and follows it.`

- [ ] **Step 6: Add the CLAUDE.md feature note**

Insert this section in `CLAUDE.md` directly after the `### Knowledge search (2026-09-26)` section (before `### Catch-Up — absence recap`):

```markdown
### Chat Redesign (2026-09-26)
- The main AI Chat runs on warm per-conversation sessions: `watchtower ai session --conversation N [--provider --model --surface main --project-id K --resume SID --db-path]` (`cmd/ai_session.go`, `internal/chat/session.go`) keeps one `claude -p --input-format stream-json --output-format stream-json --include-partial-messages --verbose` child for the conversation's life and speaks **protocol v2** — NDJSON events on stdout (`session_ready`/`turn_start`/`text_delta`/`tool_start`/`tool_end`/`usage`/`turn_done`/`error`; there is **no `reset`**, text is never wiped) for JSONL commands on stdin (`turn`/`cancel`/`close`). `cancel` sends Claude's `interrupt` control request; no `result` within 5 s → the child is killed and the next turn `--resume`s. Codex/Ollama (`NewTurnBackend`) run one provider call per turn behind the same protocol, always with replay (`BuildReplay` over the active branch, 24k-char cap) and reject binary attachments (`attachment_unsupported`). Error codes: `auth`, `rate_limit`, `provider_unavailable`, `session_lost` (retried once with replay), `attachment_unsupported`, `interrupted`, `internal`. `ai query` stays for the Discuss chats (`--events v2` opt-in; engine migration per surface is a follow-up). A warm process spans many turns, so the chat-mode MCP server reads the current turn id from a 0600 `--turn-file` (`tools.Binding.TurnIDFunc`; `--turn` stays for one-shot use, exactly one accepted).
- **The system prompt is Go-owned** (`internal/chat.BuildSystemPrompt`, budget `PromptBudgetChars` = 40k chars without project files, pinned by a golden + budget test): identity/time/owner (`db.ResolveOwner`) + language directive, connected sources + the per-account Slack link rule (closes the "account #1 team for `slack://`" gap for the main chat), tools & linking rules (`LinkingRules`, shared with `internal/ai/prompt.go` — one copy), the actions contract (`ActionsContract`, a Go port of Swift `AgentToolsContract.promptBlock(.main)` — a dual path with the Swift copy the target chat still uses, pinned by fixtures on both sides), the artifacts contract, enabled skills (Go reader of the `load_skill` frontmatter), the memory hot map (gated `memory.surfaces.chat`), the project block, a short app guide. Written to a 0600 temp file passed via `--system-prompt-file`, never argv. The DB schema is no longer in any chat prompt.
- **Data — migration 00074 adopts the Swift-created chat tables into goose.** `normalizeLegacyChatTables` runs in `(*DB).migrate()` before `goose.Up` to add the columns old Swift installs may lack; the SQL migration then creates/extends everything. Swift's `ensureTable`/`ensure*Column` are gone (the `action_item → track` fix moved into the migration). New: conversation `pinned`/`archived_at`/`title_source` (`prefix|ai|user`)/`provider`/`model`/`project_id`/`active_leaf_message_id`; message `status` (`complete|partial|error`)/`provider`/`model`/`tokens_in`/`tokens_out`/`parent_id`/`error_code`; tables `chat_turn_steps`, `chat_attachments`, `chat_artifacts`, `chat_projects`, `chat_project_sources`, and trigger-maintained `chat_fts` (so Swift writes need no indexing code). Messages form a tree via `parent_id` (legacy rows backfilled to a linear chain); regenerate/edit create a sibling (`‹ i/n ›`); the visible thread is root → `active_leaf_message_id`, and every Go reader (memory chat ingest, `ListRecentChatTurns`) reads only the active branch via `db.ActiveChatPath`. **Writers:** Swift writes every chat table; Go writes only titles — `watchtower chat title <id>` (prompt `chat.title`, light tier), never over `title_source='user'`.
- **Swift:** `ChatSessionPool` on `AppState` (max 3 live sessions, LRU, idle TTL 10 min on a 30 s poll via the pure `ChatSessionPolicy.decide`, prewarm on open/first keystroke, crash → respawn with `--resume` or replay; `QuitCoordinator` closes all: `close`, then SIGTERM after 2 s). `ChatViewModel` persists the user message before sending and partial assistant text on stop/crash, persists every tool step, and fires `chat title` after the first completed turn. The swift-markdown `MarkdownView` (`MarkdownDocument.parse` in Core, in-house `CodeHighlighter`) replaces `MarkdownText` in **every** chat, Discuss and setup chats included. UI: left history (Pinned/Today/Yesterday/7/30 days/Older + Projects, ⌘K over `chat_fts`), steps block and source chips (`ChatToolCatalog` labels; sources extracted in Go by `SummarizeToolResult`, summary ≤300 runes, ≤10 sources), error/stopped cards, a static-prompt empty state (the auto-created Welcome chat is gone).
- **Files & artifacts:** attachments (images png/jpeg/gif/webp ≤5 MB → `image` block, PDF ≤32 MB → `document` block, text-like ≤256 KB → inlined) are stored 0600 under `<workspace>/chat_files/<conversation|project>/`, sha256-deduped per conversation, and travel as paths in the `turn` command (stdin) — Go builds the content blocks (`BuildContentBlocks`, `*AttachmentError` → `attachment_unsupported`). Artifacts are `:::artifact key="…" kind="…" title="…"` fences (`document|table|email|slack|event|code`) parsed streaming-aware by `ArtifactParser` (a fence inside a code block is not an artifact; one unterminated at turn end is kept), versioned per (conversation, key) in `chat_artifacts` (an owner edit is a version with `edited=1`), shown in a side panel whose kind actions only **open or copy** — Gmail compose URL (`mailto:` fallback), Slack body to clipboard + deep link, Google Calendar template URL.
- **Actions:** new External registry tools `add_jira_comment`, `transition_jira_issue`, `assign_jira_issue`, `update_jira_issue` (surfaces main + target, always behind Approve; `internal/jira/write.go` + `internal/tools/jira_write.go`, local mirror refresh after apply); `create_idea`/`create_track`/`remind_me` widened to `main` (`remind_me` gains optional `message_ref`; the reaction surface is unchanged, REACT-02). `AgentActionCardView` renders any `url` (+ `label`) in `result_json`.
- **Projects, mentions, skills:** a project has instructions, pinned sources (`jira_project`/`slack_channel`/`target`/`track`/`person`) and files; `ai session --project-id` puts instructions, sources and text files (120k-char cap, larger listed by name) in the prompt, and the Go Claude backend attaches the project's images/PDFs to the **first turn of every fresh provider session** (`chat.ProjectAttachments`; not on a `--resume`, whose history holds them; a file missing on disk is skipped with a stderr warning) — Swift sends nothing extra. Deleting a project keeps its chats (`ON DELETE SET NULL`) and deletes its files post-commit. `@` opens a local-DB picker (`MentionSearch` over `ChatEntitySearch`: people/Jira issues/channels/targets/tracks, prefix + word-prefix, first-letter case variants because SQLite `LIKE` folds ASCII only, 8 results); `/` as the first character lists enabled skills (`SkillsCatalog.pickerSkills`; `chatContextTypes` gained `main`). `ChatTurnComposer` owns the stored turn format — optional `Use skill <name>: load it with load_skill first.` line, the text, optional `REFERENCED: person:<id> "Label"; jira:KEY "KEY"` line — and its display split (`displayParts`/`recompose`), so edits keep references.
- Contracts CHAT-01..05 in `docs/inventory/chat.md` (owner text never lost, no silent tool activity, bounded warm sessions, content off argv, artifacts never send). Spec `docs/superpowers/specs/2026-09-26-chat-redesign-design.md`, plan `docs/superpowers/plans/2026-09-26-chat-redesign.md`. **v1 limits (accepted):** Codex/Ollama get no guaranteed token streaming or steps and no binary attachments; project edits reach an open conversation only when it starts a fresh provider session; Slack/Gmail/Calendar sends are not API calls (artifacts open ready instead — new OAuth scopes are a separate decision); no numbered citations, web search or vectors.
```

- [ ] **Step 7: Mark the spec implemented**

In `docs/superpowers/specs/2026-09-26-chat-redesign-design.md`, replace line 4 (`**Status:** design approved by owner (…)`) with:

```markdown
**Status:** implemented on `feature/chat-redesign` (2026-09-26); design approved by owner (sections 1–3 in conversation; remaining sections delegated). Contracts: `docs/inventory/chat.md`.
```

- [ ] **Step 8: Commit the docs**

```bash
git add docs/inventory/chat.md docs/inventory/README.md docs/app-guide.md CLAUDE.md docs/superpowers/specs/2026-09-26-chat-redesign-design.md internal/chat WatchtowerDesktop/Tests
git commit -m "docs(chat): CHAT-01..05 inventory, app guide, CLAUDE.md note, spec status

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

(`internal/chat` and `WatchtowerDesktop/Tests` are staged for the Step 2 `BEHAVIOR` marker lines only — check `git diff --cached --stat` shows nothing else.)

- [ ] **Step 9: Full gate — logs to files, explicit exit codes**

Run each command separately; do not pipe through `tail`/`head`, read the exit code, then inspect the log:

```bash
LOGDIR=$(mktemp -d)
make test > "$LOGDIR/go-test.log" 2>&1; echo "make test exit: $?"
```

Expected: `make test exit: 0`. On non-zero: `grep -n -- "--- FAIL\|^FAIL\|panic:" "$LOGDIR/go-test.log"`.

```bash
make test-swift > "$LOGDIR/swift-test.log" 2>&1; echo "make test-swift exit: $?"
```

Expected: `make test-swift exit: 0`, and `grep -n "error: .* failed\|with [1-9][0-9]* failures" "$LOGDIR/swift-test.log"` prints nothing (XCTest failures print ABOVE the swift-testing summary — the trailing `✔ Test run` line covers swift-testing only, never trust it alone). Do not wrap this in `timeout` (it breaks xctest's arch; see the project memory).

```bash
make lint-all > "$LOGDIR/lint.log" 2>&1; echo "make lint-all exit: $?"
```

Expected: `make lint-all exit: 0`. On non-zero, fix the reported findings (a complexity-gate hit is fixed by splitting the function, never by re-baselining) and re-run the failing target, then the full three again.

Finally confirm every CHAT guard actually ran (the full runs are not verbose):

```bash
go test ./internal/chat -run 'TestChat0' -v > "$LOGDIR/chat-guards.log" 2>&1; echo "go guards exit: $?"
grep -c -- "--- PASS: TestChat0" "$LOGDIR/chat-guards.log"
make test-swift FILTER=testChat0 > "$LOGDIR/swift-guards.log" 2>&1; echo "swift guards exit: $?"
grep -c "testChat0.*passed" "$LOGDIR/swift-guards.log"
```

Expected: both exits `0`; the Go count equals the number of Go guards in `docs/inventory/chat.md`, the Swift count the number of Swift guards.
