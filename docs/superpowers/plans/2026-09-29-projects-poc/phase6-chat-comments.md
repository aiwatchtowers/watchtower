# Projects POC — Phase 6: selection comments sent as one batch — AI Chat artifacts, chat answers, project documents (Tasks 23–26)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring Phase 4's select-text-then-comment UX to the main AI Chat, in two places: (a) **artifact comments** — in the artifact side panel the owner selects a passage of an artifact, writes a comment, collects several, and presses **Send N comments**, which sends them to the assistant as one ordinary owner message; the assistant answers with a new version of the same artifact key, and every comment re-anchors onto it (a lost passage makes the comment `outdated`; the owner resolves); (b) **quote-reply** — on a finished assistant answer, **Quote in reply** opens the answer's text in a sheet where the owner selects a passage and adds a comment; each quote joins a pending batch above the composer, and the owner's send takes the whole batch plus the typed text as one turn; (c) **project documents** — a document with open owner comments gets **Send N comments to Claude**, which types one prompt line into the project's running embedded Claude Code session.

**Owner rule (binding, every surface):** comments are drafted first and reach the LLM as ONE batch, never one by one — artifact comments stay `open` drafts until Send N comments; chat quotes wait in the batch until the owner sends; a project document's comments go as one prompt line. The artifact message and the chat batch are composed by one pure function, `CommentBatchComposer` (WatchtowerCore).

**Architecture:** Phase 4's pieces are reused unchanged in behaviour after the small generalisation listed in "Required Phase 4 edits" (end of this file): `CommentAnchor` (make + locate) and `DocumentRendering` (WatchtowerCore, already text-only), `DocumentTextView`/`DocumentAttributedString` and `CommentThreadView` (app target, moved to `Views/Comments/`; `CommentThreadView` takes the new Core value `CommentThreadContent`, not a `ProjectCommentThread`). Artifact comments are a new Swift-written table `chat_artifact_comments` (goose migration `00082`, the chat-tables precedent: goose creates, Swift is the only writer). Everything pure lives in WatchtowerCore with tests in `Tests/Core`: the row model `ArtifactComment`, `ArtifactCommentQueries`, the text an artifact's comments anchor on (`ArtifactCommentText`), the re-anchor plan (`ArtifactCommentReanchor`), the batch rule (`CommentBatchComposer`), the composed artifact message (`ArtifactCommentMessage`), the quote helpers (`ChatQuoteReply`, `ChatQuoteDraft`), the project prompt line (`ProjectCommentPrompt`) and the panel's comment state (`ArtifactCommentsModel`, owned by `ArtifactPanelModel`). The app target adds `ArtifactCommentsView` (the panel's comment mode), `QuoteReplySheet` + `QuoteBatchView`, one `ChatRowActions.quote` closure, `ChatViewModel.sendArtifactComments()` (sends the composed text through the existing `send` path, marking the included rows `sent` **inside the transaction that persists the owner message**) and a per-conversation quote batch that `sendDraft()` sends with the typed text as one turn; and, for projects, `ProjectTerminalCenter.sendPrompt(_:projectID:)` (one line + Enter into a running session via SwiftTerm's `send(data:)`) behind `ProjectCommentsSendBar`.

The assistant learns about artifact comments **only** through that owner message: no Go tool, no prompt block reads `chat_artifact_comments`. The one Go change is a single rule line in `internal/chat.ArtifactsContract` ("answer comments with a new version of the same key") plus its test and the regenerated prompt golden. CHAT-05 stays intact and gets stronger: the artifact side (now including every comment file) still contains no process/CLI/network/session reference, and additionally no `.send(`/`sendDraft`/`startTurn`.

**Tech Stack:** Go 1.25 (goose migration, `internal/chat`), SwiftUI macOS 14, Swift 5.10 language mode, GRDB 7, AppKit `NSTextView` (only through Phase 4's `DocumentTextView`), XCTest + ViewInspector.

**Spec:** `docs/superpowers/specs/2026-09-29-project-board-poc-design.md` §6.3 (anchoring rules this phase reuses) and CLAUDE.md "Chat Redesign" (artifacts, CHAT-01..05). **Plan index (binding):** `docs/superpowers/plans/2026-09-29-projects-poc.md` — Global Constraints apply to every task below.

## Global Constraints (this phase)

- Everything in the repo in English; fixtures neutral (`acme`, `example.com`, "Plan", "Ship on Friday").
- Migration file `internal/db/migrations/00082_chat_artifact_comments.sql`; mirror in `internal/db/schema.sql`, `TestAllTablesExist`, schema golden (`go test ./internal/db/ -run TestSchemaGolden -update`), Swift `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`.
- Swift is the only writer of `chat_artifact_comments`. No Go code reads or writes it; no MCP/registry tool exposes it.
- The artifact side never sends (CHAT-05): only `ChatViewModel.sendArtifactComments()` — reached from the owner's click on **Send N comments** — sends, through the ordinary `send(text:)` owner-turn path (CHAT-01 applies unchanged: the owner message is persisted before anything reaches the session).
- Chat performance: no chat row hosts an `NSTextView`. Rows keep rendering with `MarkdownView`; `ChatMessageRow` equality still ignores its action closures.
- No TCC-prompting APIs (no Accessibility, no `NSEvent` global monitors, no AppleEvents).
- Go inner loop `go test ./internal/<pkg>` (no `-count=1`); Swift `make test-swift FILTER=<Class>`; `make lint-diff`. Never delete `WatchtowerDesktop/.build`. Every command's output goes to a log file with an explicit exit code (`cmd > /tmp/x.log 2>&1; echo "exit=$?"`); read XCTest failures above the swift-testing summary, not only the last line.

## Review Focus (owned here)

1. **Artifact revised between versions** — the passage kept (moved onto the new version, still open/sent), deleted or rewritten (`outdated`, never re-attached to a wrong place, never re-attached later even when the old text comes back), a resolved comment whose passage is gone (stays resolved, loses only its highlight), and the owner's own edit (a new version like any other). → Task 24 `ArtifactCommentReanchorTests`, `ArtifactCommentsModelTests`.
2. **"Sent" is exactly the comments that went out** — only the unsent (`open`) comments included in the composed message become `sent`, in the same transaction as the owner message; a comment added after composing, an already-sent one, a resolved/outdated one are untouched; a failed save leaves every comment unsent; a click while an answer streams sends nothing. → Task 24 `testMarkSentTouchesOnlyTheIncludedOpenComments`, `ChatViewModelTests` artifact-comment tests.
3. **CHAT-05** — no artifact-side file (old or new) references a process, the CLI, the network, the chat session pool, or any send entry point; adding a comment sends nothing. → Task 24 extended `testChat05ArtifactSurfacesNeverWrite`, `testArtifactCommentsReachTheAssistantOnlyAsTheOwnersMessage`.
4. **Chat performance** — a 500-message conversation renders exactly as before: one extra button on a finished assistant row, no text view per row. → Task 25 `ChatQuoteReplyScanTests.testThreadRowsNeverHostATextView`, `ChatMessageRowTests` equality test unchanged.
5. **One batch, never one by one** — adding a quote or an artifact comment sends nothing; one send carries the whole batch; a failed send keeps the batch; project comments go as one prompt line. → Task 25 `testQuotesAccumulateAndNothingIsSentPerQuote`, `testSendDraftSendsEveryQuoteAndTheTypedTextAsOneTurn`, `testAFailedSendKeepsTheQuoteBatch`; Task 24 `testArtifactCommentsReachTheAssistantOnlyAsTheOwnersMessage`; Task 26 `testARunningSessionGetsOneLineAndOneEnter`.
6. **Terminal input is inert text** — an agent-supplied document path can neither submit early nor inject an escape sequence into the owner's terminal; only a running session receives input and sending never starts one. → Task 26 `testControlCharactersInThePathCannotSubmitOrInject`, `testTerminalInputIsTheLineThenExactlyOneEnter`, `testNoSessionStartsNothing`.

## Cross-phase alignment (read before starting)

- **Depends on Phase 4 Tasks 15 and 16 with the "Required Phase 4 edits" applied** — the binding copy is `phase4-generic-edits.md` (the same text is repeated at the end of this file); Task 26 also depends on Phase 4 Task 17. Step 0 of Tasks 24–26 greps for the generalised names; if Phase 4 already landed without the edits, apply them first as their own commit (they are listed with full code at the end of this file) — do not fork a second copy of `DocumentTextView`/`CommentThreadView`.
- **Consumes (existing code, confirmed 2026-09-30):** `ArtifactPanelModel` (`WatchtowerCore/Services/Chat/ArtifactPanelModel.swift`: `init(db: any DatabaseWriter, conversationID:key:)`, `versions: [ChatArtifact]` ordered by version, `selectedVersion: Int?`, `liveDraft`, `isEditing`, `selectedArtifact`, `reload()`, `turnFinished()`, `saveEdit()`); `ChatArtifact` (`id`, `conversationID`, `messageID`, `artifactKey`, `version: Int`, `kind`, `title`, `content`, `edited`, `createdAt: Double`); `ChatArtifactQueries.saveVersion(_:conversationID:messageID:draft:edited:)`; `ArtifactParser.parse(_:final:)` with `.segments` of `.markdown(String)`/`.artifact(ArtifactDraft)`; `ChatViewModel` (`draft`, `artifactPanel`, `isStreaming`, `errorMessage`, `send(text:attachments:mentions:skill:) -> Bool`, private `TurnPlan`/`persistTurnStart`); `ChatInspectorContent` (the only `ArtifactPanelView` call site); `ChatRowActions`/`ChatMessageRow`/`ChatThreadView`; test support `TestDatabase.create()`, `insertChatConversation`, `insertChatMessage`, `FakeChatSessionProcess.turns`, `ChatViewModelTests.makeViewModel()`/`lastFake()`/`lastStoredUserText(_:)`.
- **Consumes (Phase 4, after the edits):** `CommentAnchor` (`init(quote:prefix:suffix:heading:)`, `make(text:range:headings:)`, `locate(in:)`), `RenderedDocument` (`text`, `headings`, `runs`, `headingOffsets`; memberwise init is internal to WatchtowerCore), `DocumentStyleRun`, `DocumentRendering.render(_:)`, `CommentThreadContent`, app-target `DocumentTextView(text:selection:onClick:)`, `DocumentAttributedString.make(_:highlights:activeThreadID:)`, `CommentThreadView(thread:isActive:onReply:onResolve:onReopen:onDelete:)`.
- **Produced for Task 22 (docs):** CLAUDE.md "Chat Redesign" note (migration `00082`, artifact comments, the quote batch) and a Projects-note sentence (Send N comments to Claude), `docs/app-guide.md` (the panel's Comments mode, Send N comments, Quote in reply + batch, the document send bar). Task 24 itself updates `docs/inventory/chat.md` (CHAT-05 scope + changelog).

---

### Task 23: Migration 00082 `chat_artifact_comments` + mirrors

**Depends on:** Task 1 (migration 00081 is the current tip).

**Files:**
- Create: `internal/db/migrations/00082_chat_artifact_comments.sql`
- Modify: `internal/db/schema.sql`, `internal/db/db_test.go` (`TestAllTablesExist`), `internal/db/testdata/schema_v73.golden` (regenerated)
- Create: `internal/db/chat_artifact_comments_migration_test.go`
- Modify: `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`
- Create: `WatchtowerDesktop/Tests/Core/ArtifactCommentSchemaMirrorTests.swift`

**Interfaces:**
- Produces the table (both the goose migration and the Swift test mirror):

```sql
chat_artifact_comments(
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id  INTEGER NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE,
    artifact_key     TEXT NOT NULL,
    artifact_version INTEGER NOT NULL,        -- the version the anchor was last located on
    body             TEXT NOT NULL,
    anchor_quote     TEXT NOT NULL,
    anchor_prefix    TEXT NOT NULL DEFAULT '',
    anchor_suffix    TEXT NOT NULL DEFAULT '',
    anchor_heading   TEXT NOT NULL DEFAULT '',
    status           TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','sent','resolved','outdated')),
    created_at       REAL NOT NULL,
    sent_at          REAL,
    CHECK (anchor_quote != '' AND body != ''),
    CHECK (status != 'sent' OR sent_at IS NOT NULL)
)
idx_chat_artifact_comments_key ON (conversation_id, artifact_key)
```

- Status meaning: `open` = written, not yet sent (the owner's private draft); `sent` = went out in an owner message; `resolved` = the owner closed it; `outdated` = its quote is gone from the latest version. `sent_at` is kept when a sent comment is later resolved or outdated.
- No FK to `chat_artifacts`: a comment belongs to the (conversation, key) and follows it across versions; `artifact_version` is data, not a reference.

- [ ] **Step 1: Failing Go tests**

Create `internal/db/chat_artifact_comments_migration_test.go`:

```go
package db

import (
	"path/filepath"
	"testing"

	"github.com/pressly/goose/v3"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// TestMigration00082_CreatesTheArtifactCommentsTable pins the shape the
// Desktop writes (projects POC phase 6): owner comments anchored on an AI
// Chat artifact's rendered text, keyed by (conversation, artifact key).
func TestMigration00082_CreatesTheArtifactCommentsTable(t *testing.T) {
	d := openTestDB(t)

	got := columnNames(t, d.DB, "chat_artifact_comments")
	for _, c := range []string{"id", "conversation_id", "artifact_key", "artifact_version", "body",
		"anchor_quote", "anchor_prefix", "anchor_suffix", "anchor_heading", "status", "created_at", "sent_at"} {
		assert.True(t, got[c], "chat_artifact_comments.%s missing", c)
	}
	var name string
	require.NoError(t, d.QueryRow(`SELECT name FROM sqlite_master WHERE type = 'index' AND name = ?`,
		"idx_chat_artifact_comments_key").Scan(&name))
}

// TestMigration00082_ConstraintsHold: the status CHECK, a comment always has
// a quote and a body, a sent comment always has sent_at, and deleting the
// conversation deletes its comments.
func TestMigration00082_ConstraintsHold(t *testing.T) {
	d := openTestDB(t)
	res, err := d.Exec(`INSERT INTO chat_conversations (title, created_at, updated_at) VALUES ('', 0, 0)`)
	require.NoError(t, err)
	conv, err := res.LastInsertId()
	require.NoError(t, err)

	insert := func(quote, body, status string, sentAt any) error {
		_, err := d.Exec(`INSERT INTO chat_artifact_comments
			(conversation_id, artifact_key, artifact_version, body, anchor_quote, status, created_at, sent_at)
			VALUES (?, 'plan', 1, ?, ?, ?, 0, ?)`, conv, body, quote, status, sentAt)
		return err
	}
	assert.Error(t, insert("q", "b", "draft", nil), "status CHECK")
	assert.Error(t, insert("", "b", "open", nil), "a comment is always anchored")
	assert.Error(t, insert("q", "", "open", nil), "a comment always has a body")
	assert.Error(t, insert("q", "b", "sent", nil), "a sent comment carries sent_at")
	require.NoError(t, insert("q", "b", "open", nil))
	require.NoError(t, insert("q", "b", "sent", 1.5))

	_, err = d.Exec(`DELETE FROM chat_conversations WHERE id = ?`, conv)
	require.NoError(t, err)
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM chat_artifact_comments`).Scan(&n))
	assert.Zero(t, n, "deleting the conversation deletes its artifact comments")
}

// TestMigration00082_DownDropsTheTable: other tests roll back through 00082,
// so its Down must be real.
func TestMigration00082_DownDropsTheTable(t *testing.T) {
	d, err := Open(filepath.Join(t.TempDir(), "artifact-comments-cycle.db"))
	require.NoError(t, err)
	defer d.Close()

	// DownTo(81), not a bare Down: a later migration can move the tip past 00082.
	require.NoError(t, goose.DownTo(d.DB, "migrations", 81))
	var n int
	require.NoError(t, d.QueryRow(`SELECT COUNT(*) FROM sqlite_master WHERE name LIKE '%chat_artifact_comments%'`).Scan(&n))
	assert.Zero(t, n, "Down drops the table and its index")

	require.NoError(t, goose.Up(d.DB, "migrations"))
	assert.True(t, columnNames(t, d.DB, "chat_artifact_comments")["anchor_quote"], "re-Up restores the table")
}
```

Add `"chat_artifact_comments"` to the expected list in `TestAllTablesExist` (`internal/db/db_test.go`), on the chat line:

```go
		"chat_artifacts", "chat_projects", "chat_project_sources", "chat_fts", "chat_title_fts",
		"chat_artifact_comments",
		"projects", "project_sources", "project_documents", "project_comments",
```

Run: `go test ./internal/db -run 'TestMigration00082|TestAllTablesExist' > /tmp/t23a.log 2>&1; echo "exit=$?"` → `exit≠0` (no such table).

- [ ] **Step 2: The migration**

Create `internal/db/migrations/00082_chat_artifact_comments.sql`:

```sql
-- +goose Up
-- Owner comments on AI Chat artifacts (projects POC phase 6). A comment is
-- anchored on the rendered text of one (conversation, artifact key) and
-- follows the key across versions: every newer version re-anchors it
-- (artifact_version = the version it was last found on), and a quote that is
-- gone makes it 'outdated'. 'open' = written, not sent yet; 'sent' = went out
-- in an owner chat message. The Desktop is the only writer (the chat-tables
-- precedent). The assistant never reads this table: it learns about comments
-- only from the owner's own message ("Send N comments").
CREATE TABLE chat_artifact_comments (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id  INTEGER NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE,
    artifact_key     TEXT NOT NULL,
    artifact_version INTEGER NOT NULL,
    body             TEXT NOT NULL,
    anchor_quote     TEXT NOT NULL,
    anchor_prefix    TEXT NOT NULL DEFAULT '',
    anchor_suffix    TEXT NOT NULL DEFAULT '',
    anchor_heading   TEXT NOT NULL DEFAULT '',
    status           TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','sent','resolved','outdated')),
    created_at       REAL NOT NULL,
    sent_at          REAL,
    CHECK (anchor_quote != '' AND body != ''),
    CHECK (status != 'sent' OR sent_at IS NOT NULL)
);
CREATE INDEX idx_chat_artifact_comments_key ON chat_artifact_comments(conversation_id, artifact_key);

-- +goose Down
DROP INDEX IF EXISTS idx_chat_artifact_comments_key;
DROP TABLE IF EXISTS chat_artifact_comments;
```

- [ ] **Step 3: Mirror in `internal/db/schema.sql`**

Insert right after the `chat_artifacts` table (after its `UNIQUE(conversation_id, artifact_key, version)\n);` lines):

```sql

-- Owner comments on an artifact's passages; Desktop-written, never read by
-- the assistant (it sees them only in the owner's own chat message).
CREATE TABLE IF NOT EXISTS chat_artifact_comments (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    conversation_id  INTEGER NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE,
    artifact_key     TEXT NOT NULL,
    artifact_version INTEGER NOT NULL,
    body             TEXT NOT NULL,
    anchor_quote     TEXT NOT NULL,
    anchor_prefix    TEXT NOT NULL DEFAULT '',
    anchor_suffix    TEXT NOT NULL DEFAULT '',
    anchor_heading   TEXT NOT NULL DEFAULT '',
    status           TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','sent','resolved','outdated')),
    created_at       REAL NOT NULL,
    sent_at          REAL,
    CHECK (anchor_quote != '' AND body != ''),
    CHECK (status != 'sent' OR sent_at IS NOT NULL)
);
CREATE INDEX IF NOT EXISTS idx_chat_artifact_comments_key ON chat_artifact_comments(conversation_id, artifact_key);
```

Regenerate the golden and run the package's schema guards:

```bash
go test ./internal/db/ -run TestSchemaGolden -update > /tmp/t23b.log 2>&1; echo "exit=$?"
go test ./internal/db > /tmp/t23c.log 2>&1; echo "exit=$?"
```
Expected: both `exit=0`. `git diff --stat internal/db/testdata/schema_v73.golden` shows only the new table/index lines.

- [ ] **Step 4: Failing Swift mirror test**

Create `WatchtowerDesktop/Tests/Core/ArtifactCommentSchemaMirrorTests.swift`:

```swift
import XCTest
import GRDB
import WatchtowerTestSupport

/// The test schema mirror carries migration 00082 so the artifact-comment
/// queries are tested against the real shape.
final class ArtifactCommentSchemaMirrorTests: XCTestCase {
    func testMirrorHasTheTableAndItsConstraints() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            XCTAssertTrue(try db.tableExists("chat_artifact_comments"))
            let conversation = try TestDatabase.insertChatConversation(db)
            let insert = { (status: String, sentAt: Double?) in
                try db.execute(sql: """
                    INSERT INTO chat_artifact_comments
                        (conversation_id, artifact_key, artifact_version, body, anchor_quote, status, created_at, sent_at)
                    VALUES (?, 'plan', 1, 'b', 'q', ?, 0, ?)
                    """, arguments: [conversation, status, sentAt])
            }
            XCTAssertThrowsError(try insert("draft", nil), "status CHECK")
            XCTAssertThrowsError(try insert("sent", nil), "a sent comment carries sent_at")
            try insert("open", nil)
            try insert("sent", 1)
            try db.execute(sql: "DELETE FROM chat_conversations WHERE id = ?", arguments: [conversation])
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chat_artifact_comments"), 0)
        }
    }
}
```

Run: `make test-swift FILTER=ArtifactCommentSchemaMirrorTests > /tmp/t23d.log 2>&1; echo "exit=$?"` → `exit≠0`.

- [ ] **Step 5: Swift test mirror**

In `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`, right after the `chat_artifacts` table (after its `        UNIQUE(conversation_id, artifact_key, version)\n    );` lines), insert:

```sql

    CREATE TABLE IF NOT EXISTS chat_artifact_comments (
        id               INTEGER PRIMARY KEY AUTOINCREMENT,
        conversation_id  INTEGER NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE,
        artifact_key     TEXT NOT NULL,
        artifact_version INTEGER NOT NULL,
        body             TEXT NOT NULL,
        anchor_quote     TEXT NOT NULL,
        anchor_prefix    TEXT NOT NULL DEFAULT '',
        anchor_suffix    TEXT NOT NULL DEFAULT '',
        anchor_heading   TEXT NOT NULL DEFAULT '',
        status           TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','sent','resolved','outdated')),
        created_at       REAL NOT NULL,
        sent_at          REAL,
        CHECK (anchor_quote != '' AND body != ''),
        CHECK (status != 'sent' OR sent_at IS NOT NULL)
    );
    CREATE INDEX IF NOT EXISTS idx_chat_artifact_comments_key ON chat_artifact_comments(conversation_id, artifact_key);
```

Run:
```bash
make test-swift FILTER=ArtifactCommentSchemaMirrorTests > /tmp/t23d.log 2>&1; echo "exit=$?"
make test-swift FILTER=ProjectSchemaMirrorTests > /tmp/t23e.log 2>&1; echo "exit=$?"
make lint-diff > /tmp/t23-lint.log 2>&1; echo "exit=$?"
```
Expected: every `exit=0`.

- [ ] **Step 6: Commit**

```bash
git add internal/db/migrations/00082_chat_artifact_comments.sql internal/db/schema.sql \
        internal/db/db_test.go internal/db/testdata/schema_v73.golden \
        internal/db/chat_artifact_comments_migration_test.go \
        WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift \
        WatchtowerDesktop/Tests/Core/ArtifactCommentSchemaMirrorTests.swift
git commit -m "$(cat <<'EOF'
feat(db): chat_artifact_comments for owner comments on chat artifacts (00082)

Owner comments anchored on an AI Chat artifact's rendered text, keyed by
(conversation, artifact key) and re-anchored across versions. The Desktop is
the only writer; the assistant never reads the table.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 24: Artifact panel comments — queries, model, view, send, re-anchor

**Depends on:** Task 23; Phase 4 Tasks 15 and 16 **with the Required Phase 4 edits**.

**Files:**
- Create (WatchtowerCore): `Models/ArtifactComment.swift`, `Database/Queries/ArtifactCommentQueries.swift`, `Services/Chat/ArtifactCommentText.swift`, `Services/Chat/ArtifactCommentReanchor.swift`, `Services/Chat/ArtifactCommentMessage.swift`, `Services/Chat/CommentBatchComposer.swift` (shared with Tasks 25–26), `Services/Chat/ArtifactCommentsModel.swift`
- Modify (WatchtowerCore): `Services/Chat/ArtifactPanelModel.swift`
- Create (app): `Views/Chat/ArtifactCommentsView.swift` (+ `ArtifactCommentsSendBar`)
- Modify (app): `Views/Chat/ArtifactPanelView.swift`, `Views/Chat/ChatInspectorContent.swift`, `ViewModels/ChatViewModel.swift`
- Modify (Go): `internal/chat/artifacts_contract.go`, `internal/chat/artifacts_contract_test.go`, `internal/chat/testdata/system_prompt_main.golden` (regenerated)
- Modify (docs): `docs/inventory/chat.md`
- Test: `WatchtowerDesktop/Tests/Core/ArtifactCommentQueriesTests.swift`, `Tests/Core/ArtifactCommentReanchorTests.swift`, `Tests/Core/ArtifactCommentMessageTests.swift`, `Tests/Core/CommentBatchComposerTests.swift`, `Tests/Core/ArtifactCommentsModelTests.swift`, `Tests/Core/ArtifactChat05ScanTests.swift` (extended), `Tests/ChatViewModelTests.swift` (four tests added), `Tests/ArtifactCommentsSendBarTests.swift`

**Interfaces:**
- Consumes: Task 23 table; Phase 4 `CommentAnchor`, `RenderedDocument`, `DocumentStyleRun`, `DocumentRendering`, `CommentThreadContent`, `DocumentTextView`, `DocumentAttributedString`, `CommentThreadView`; existing `ArtifactPanelModel`, `ChatArtifact`, `ChatViewModel.send`.
- Produces (WatchtowerCore, `package`):
  - `struct ArtifactComment: FetchableRecord, Decodable, Identifiable, Equatable, Sendable { id, conversationID: Int64; artifactKey: String; artifactVersion: Int; body, anchorQuote, anchorPrefix, anchorSuffix, anchorHeading: String; status: Status; createdAt: Double; sentAt: Double?; anchor: CommentAnchor; isLive: Bool; content: CommentThreadContent }`, `enum ArtifactComment.Status: String { open, sent, resolved, outdated }`.
  - `enum ArtifactCommentError: LocalizedError { emptyBody, emptyQuote }`.
  - `enum ArtifactCommentQueries`: `comments(_:conversationID:key:) -> [ArtifactComment]` (by id), `@discardableResult add(_:conversationID:key:version:anchor:body:now:) -> Int64`, `@discardableResult deleteUnsent(_:id:) -> Bool`, `@discardableResult resolve(_:id:) -> Bool`, `@discardableResult markSent(_:ids:at:) -> Int`, `apply(_:plan:version:)`.
  - `enum ArtifactCommentText { static func render(kind:content:) -> RenderedDocument }`.
  - `enum ArtifactCommentReanchor { struct Plan { ranges: [Int64: NSRange]; moved, lost: [Int64]; isNoOp }; static func plan(_:text:version:) -> Plan }`.
  - `enum CommentBatchComposer { struct Item { quote, heading, comment: String }; static func compose(header:items:closing:note:) -> String?; static func blockquote(_:) -> String; static func sendButtonTitle(count:) -> String }` — the ONE batch rule (owner: comments go to the LLM as one batch, never one by one), reused by Tasks 25 and 26.
  - `enum ArtifactCommentMessage { struct Outgoing { text: String; ids: [Int64] }; static func compose(title:key:version:comments:) -> String? }` (delegates to `CommentBatchComposer`).
  - `@MainActor @Observable final class ArtifactCommentsModel`: `conversationID`, `key`, `comments`, `artifact: ChatArtifact?`, `rendered: RenderedDocument?`, `ranges: [Int64: NSRange]`, `errorMessage`, `sync(latest:)`, `reload()`, `@discardableResult add(body:selection:) -> Bool`, `delete(_:)`, `resolve(_:)`, `unsent`, `sent`, `resolved`, `outdated`, `threadID(at:)`, `outgoing() -> ArtifactCommentMessage.Outgoing?`.
  - `ArtifactPanelModel` + `let comments: ArtifactCommentsModel`, `var canComment: Bool`; `reload()` now also calls `comments.sync(latest: versions.last)`.
- Produces (app): `ArtifactCommentsView(comments:canSend:onSend:)`, `ArtifactCommentsSendBar(count:canSend:onSend:)`; `ArtifactPanelView` gains `canSendComments: Bool` and `onSendComments: () -> Void` (declared before `onClose`, so the trailing `onClose` closure still binds); `ChatViewModel.sendArtifactComments()`; `ChatViewModel.send(text:attachments:mentions:skill:alsoWrite:)` — new defaulted `alsoWrite: ((Database) throws -> Void)? = nil`, run inside the owner-message transaction.
- Produces (Go): one new rule line in `ArtifactsContract()`.

**Rules:**
- Comments live on the **latest stored version** only. Comment mode is available when the panel shows that version (`selectedVersion` nil or equal to it), no live draft is streaming, and no edit is open (`ArtifactPanelModel.canComment`); otherwise the panel renders as today.
- Re-anchor on every panel reload (open, a turn finishing, the owner's own edit — each writes a new version): `open`/`sent` comments are located on the latest version's rendered text; found on a newer version → `artifact_version` moves to it; not found → `outdated` (keeps its `artifact_version`). `resolved` comments are located only for their highlight and never change status; `outdated` ones are never re-located (a quote that comes back later does not re-attach an old comment — the owner resolves it).
- The anchored text: a `document` renders its markdown through `DocumentRendering` (what the owner reads); every other kind is its raw `content`, verbatim (`code` styled as a code block).
- Per status the owner can: `open` → Delete (it was never sent, so it leaves no trace); `sent` and `outdated` → Resolve; `resolved` → nothing. There are no replies: the assistant answers in the chat, not in the comment.
- **Send N comments** is enabled when there are unsent comments and no answer is streaming. It composes one owner message from the unsent comments in text order and sends it through `ChatViewModel.send`; the included ids — exactly those, and only while still `open` — turn `sent` with one `sent_at` inside the transaction that persists the owner message. A refused or failed send changes nothing.

- [ ] **Step 0: Confirm the Phase 4 names**

```bash
cd WatchtowerDesktop
grep -n "package struct CommentThreadContent" Sources/WatchtowerCore/Models/CommentThreadContent.swift
grep -n "struct DocumentTextView\|enum DocumentAttributedString" Sources/Views/Comments/DocumentTextView.swift
grep -n "let thread: CommentThreadContent\|onDelete" Sources/Views/Comments/CommentThreadView.swift
grep -n "static func make\|func locate" Sources/WatchtowerCore/Services/CommentAnchor.swift
```
Every grep must print a line. If one prints nothing, apply the "Required Phase 4 edits" section first (its own commit), then continue.

- [ ] **Step 1: Failing Core tests — model, text, re-anchor, message**

Create `WatchtowerDesktop/Tests/Core/ArtifactCommentReanchorTests.swift`:

```swift
import XCTest
@testable import WatchtowerCore

final class ArtifactCommentReanchorTests: XCTestCase {
    private let v1 = "Keep the retry budget small.\n\nShip on Friday."

    private func comment(
        _ id: Int64, quote: String, in text: String, version: Int = 1, status: ArtifactComment.Status = .open
    ) throws -> ArtifactComment {
        let anchor = CommentAnchor.make(text: text, range: try XCTUnwrap(text.range(of: quote)), headings: [])
        return ArtifactComment(
            id: id, conversationID: 1, artifactKey: "plan", artifactVersion: version, body: "b",
            anchorQuote: anchor.quote, anchorPrefix: anchor.prefix, anchorSuffix: anchor.suffix,
            anchorHeading: anchor.heading, status: status, createdAt: 0, sentAt: status == .open ? nil : 1
        )
    }

    func testAPassageKeptOnANewerVersionMovesOntoIt() throws {
        let v2 = "A new intro.\n\n" + v1
        let plan = ArtifactCommentReanchor.plan([try comment(1, quote: "retry budget", in: v1)], text: v2, version: 2)
        XCTAssertEqual(plan.moved, [1])
        XCTAssertEqual(plan.lost, [])
        XCTAssertEqual(plan.ranges[1], (v2 as NSString).range(of: "retry budget"))
    }

    func testFoundOnItsOwnVersionIsANoOp() throws {
        let plan = ArtifactCommentReanchor.plan([try comment(1, quote: "retry budget", in: v1)], text: v1, version: 1)
        XCTAssertTrue(plan.isNoOp)
        XCTAssertNotNil(plan.ranges[1])
    }

    func testOpenAndSentCommentsWhoseQuoteIsGoneAreLost() throws {
        let comments = [try comment(1, quote: "retry budget", in: v1),
                        try comment(2, quote: "Ship on Friday", in: v1, status: .sent)]
        let plan = ArtifactCommentReanchor.plan(comments, text: "Everything was rewritten.", version: 2)
        XCTAssertEqual(plan.lost, [1, 2])
        XCTAssertEqual(plan.moved, [])
        XCTAssertTrue(plan.ranges.isEmpty)
    }

    func testResolvedCommentsOnlyGetAHighlightAndOutdatedOnesAreNeverRelocated() throws {
        let v2 = "A new intro.\n\n" + v1
        let comments = [try comment(1, quote: "retry budget", in: v1, status: .resolved),
                        try comment(2, quote: "Ship on Friday", in: v1, status: .outdated),
                        try comment(3, quote: "Keep the", in: v1, status: .resolved)]
        let kept = ArtifactCommentReanchor.plan(comments, text: v2, version: 2)
        XCTAssertTrue(kept.isNoOp, "resolved/outdated comments never change")
        XCTAssertNotNil(kept.ranges[1])
        XCTAssertNil(kept.ranges[2], "an outdated comment is not re-attached even though its text is back")
        let gone = ArtifactCommentReanchor.plan(comments, text: "Rewritten.", version: 3)
        XCTAssertTrue(gone.isNoOp)
        XCTAssertTrue(gone.ranges.isEmpty)
    }
}
```

Create `WatchtowerDesktop/Tests/Core/ArtifactCommentMessageTests.swift`:

```swift
import XCTest
@testable import WatchtowerCore

final class ArtifactCommentMessageTests: XCTestCase {
    private func comment(_ id: Int64, quote: String, heading: String, body: String) -> ArtifactComment {
        ArtifactComment(
            id: id, conversationID: 1, artifactKey: "q3-plan", artifactVersion: 2, body: body,
            anchorQuote: quote, anchorPrefix: "", anchorSuffix: "", anchorHeading: heading,
            status: .open, createdAt: 0, sentAt: nil
        )
    }

    func testComposesOneMessageWithEveryQuoteAndCommentInOrder() {
        let text = ArtifactCommentMessage.compose(title: "Q3 plan", key: "q3-plan", version: 2, comments: [
            comment(1, quote: "retry budget small", heading: "Risks", body: "Why so small?"),
            comment(2, quote: "Ship on Friday.\n\nOwners: ops", heading: "", body: "Thursday?")
        ])
        XCTAssertEqual(text, """
            Comments on the artifact "Q3 plan" (key="q3-plan", version 2):

            1. Under "Risks":
            > retry budget small
            Why so small?

            2. On this passage:
            > Ship on Friday.
            >
            > Owners: ops
            Thursday?

            Please reply with a new version of this artifact under the same key that addresses these comments.
            """)
    }

    func testAnUntitledArtifactIsNamedByItsKey() {
        let text = ArtifactCommentMessage.compose(title: "  ", key: "q3-plan", version: 1,
                                                  comments: [comment(1, quote: "x", heading: "", body: "y")])
        XCTAssertTrue(text?.hasPrefix(#"Comments on the artifact "q3-plan" (key="q3-plan", version 1):"#) == true)
    }

    func testNothingToSendComposesNothing() {
        XCTAssertNil(ArtifactCommentMessage.compose(title: "Plan", key: "plan", version: 1, comments: []))
    }

}
```

Create `WatchtowerDesktop/Tests/Core/CommentBatchComposerTests.swift` — the one batch rule every surface uses (artifact comments here, chat quotes in Task 25):

```swift
import XCTest
@testable import WatchtowerCore

final class CommentBatchComposerTests: XCTestCase {
    private typealias Item = CommentBatchComposer.Item

    func testOneMessageCarriesHeaderEveryItemClosingAndNoteInOrder() {
        let text = CommentBatchComposer.compose(
            header: "About these parts of your answers:",
            items: [Item(quote: "retry budget", heading: "Risks", comment: " Why so small? "),
                    Item(quote: "Ship on Friday", heading: "", comment: "  ")],
            closing: "Please revise.",
            note: "  Also: what about staging?\n"
        )
        XCTAssertEqual(text, """
            About these parts of your answers:

            1. Under "Risks":
            > retry budget
            Why so small?

            2. On this passage:
            > Ship on Friday

            Please revise.

            Also: what about staging?
            """)
    }

    func testNoItemsIsJustTheNoteAndNothingAtAllIsNil() {
        XCTAssertEqual(CommentBatchComposer.compose(header: "H", items: [], closing: "C", note: " hi "), "hi")
        XCTAssertNil(CommentBatchComposer.compose(header: "H", items: [], closing: "C", note: " \n"))
    }

    func testBlockquotePrefixesEveryLineAndKeepsBlankLinesInsideTheQuote() {
        XCTAssertEqual(CommentBatchComposer.blockquote("  first line\nsecond\n\n    indented  "),
                       "> first line\n> second\n>\n>     indented")
    }

    func testSendButtonTitle() {
        XCTAssertEqual(CommentBatchComposer.sendButtonTitle(count: 1), "Send 1 comment")
        XCTAssertEqual(CommentBatchComposer.sendButtonTitle(count: 3), "Send 3 comments")
    }
}
```

Create `WatchtowerDesktop/Tests/Core/ArtifactCommentQueriesTests.swift`:

```swift
import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class ArtifactCommentQueriesTests: XCTestCase {
    private var queue: DatabaseQueue!
    private var conversationID: Int64 = 0

    override func setUpWithError() throws {
        queue = try TestDatabase.create()
        conversationID = try queue.write { try TestDatabase.insertChatConversation($0) }
    }

    private func add(_ db: Database, quote: String = "q", body: String = "b") throws -> Int64 {
        try ArtifactCommentQueries.add(db, conversationID: conversationID, key: "plan", version: 1,
                                       anchor: CommentAnchor(quote: quote, prefix: "", suffix: "", heading: ""),
                                       body: body)
    }

    private func status(_ db: Database, _ id: Int64) throws -> String? {
        try String.fetchOne(db, sql: "SELECT status FROM chat_artifact_comments WHERE id = ?", arguments: [id])
    }

    func testAddTrimsTheBodyAndRefusesAnEmptyBodyOrQuote() throws {
        try queue.write { db in
            let id = try add(db, body: "  Why?  \n")
            XCTAssertEqual(try ArtifactCommentQueries.comments(db, conversationID: conversationID, key: "plan").map(\.body), ["Why?"])
            XCTAssertEqual(try status(db, id), "open")
            XCTAssertThrowsError(try add(db, body: " \n")) { XCTAssertEqual($0 as? ArtifactCommentError, .emptyBody) }
            XCTAssertThrowsError(try add(db, quote: "  ")) { XCTAssertEqual($0 as? ArtifactCommentError, .emptyQuote) }
        }
    }

    func testMarkSentTouchesOnlyTheIncludedOpenComments() throws {
        try queue.write { db in
            let (a, b, _, d) = (try add(db), try add(db), try add(db), try add(db))
            let earlier = Date(timeIntervalSince1970: 100)
            XCTAssertEqual(try ArtifactCommentQueries.markSent(db, ids: [d], at: earlier), 1)
            let now = Date(timeIntervalSince1970: 200)

            XCTAssertEqual(try ArtifactCommentQueries.markSent(db, ids: [a, b, d], at: now), 2, "d was sent before")
            let rows = try ArtifactCommentQueries.comments(db, conversationID: conversationID, key: "plan")
            XCTAssertEqual(rows.map(\.status), [.sent, .sent, .open, .sent])
            XCTAssertEqual(rows.map(\.sentAt), [200, 200, nil, 100], "c was not included; d keeps its first sent_at")
            XCTAssertEqual(try ArtifactCommentQueries.markSent(db, ids: [], at: now), 0)
        }
    }

    func testDeleteRemovesOnlyAnUnsentComment() throws {
        try queue.write { db in
            let (draft, sent) = (try add(db), try add(db))
            try ArtifactCommentQueries.markSent(db, ids: [sent], at: Date())
            XCTAssertTrue(try ArtifactCommentQueries.deleteUnsent(db, id: draft))
            XCTAssertFalse(try ArtifactCommentQueries.deleteUnsent(db, id: sent), "a sent comment is part of the conversation")
            XCTAssertEqual(try ArtifactCommentQueries.comments(db, conversationID: conversationID, key: "plan").map(\.id), [sent])
        }
    }

    func testResolveOnlyASentOrOutdatedComment() throws {
        try queue.write { db in
            let (draft, sent, lost) = (try add(db), try add(db), try add(db))
            try ArtifactCommentQueries.markSent(db, ids: [sent], at: Date())
            try ArtifactCommentQueries.apply(db, plan: ArtifactCommentReanchor.Plan(lost: [lost]), version: 2)
            XCTAssertFalse(try ArtifactCommentQueries.resolve(db, id: draft), "an unsent comment is deleted, not resolved")
            XCTAssertTrue(try ArtifactCommentQueries.resolve(db, id: sent))
            XCTAssertTrue(try ArtifactCommentQueries.resolve(db, id: lost))
            XCTAssertEqual(try status(db, draft), "open")
            XCTAssertEqual(try status(db, sent), "resolved")
            XCTAssertEqual(try status(db, lost), "resolved")
        }
    }

    func testApplyMovesAndOutdatesOnlyLiveComments() throws {
        try queue.write { db in
            let (moved, lost, resolved) = (try add(db), try add(db), try add(db))
            try ArtifactCommentQueries.markSent(db, ids: [resolved], at: Date())
            try ArtifactCommentQueries.resolve(db, id: resolved)
            try ArtifactCommentQueries.apply(db, plan: ArtifactCommentReanchor.Plan(moved: [moved, resolved], lost: [lost, resolved]),
                                             version: 3)
            let rows = try ArtifactCommentQueries.comments(db, conversationID: conversationID, key: "plan")
            XCTAssertEqual(rows.map(\.status), [.open, .outdated, .resolved])
            XCTAssertEqual(rows.map(\.artifactVersion), [3, 1, 1], "an outdated comment keeps the version it was last found on")
        }
    }
}
```

Create `WatchtowerDesktop/Tests/Core/ArtifactCommentsModelTests.swift`:

```swift
import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

@MainActor
final class ArtifactCommentsModelTests: XCTestCase {
    private var queue: DatabaseQueue!
    private var conversationID: Int64 = 0
    private var messages: [Int64] = []

    private let v1 = """
    # Plan

    ## Risks

    Keep the retry budget small so a flaky service cannot stall the sync.

    ## Dates

    Ship on Friday.
    """

    override func setUp() async throws {
        queue = try TestDatabase.create()
        (conversationID, messages) = try await queue.write { db in
            let conversation = try TestDatabase.insertChatConversation(db)
            var ids: [Int64] = []
            for _ in 0..<4 {
                ids.append(try TestDatabase.insertChatMessage(db, conversationID: conversation, role: "assistant", text: ""))
            }
            return (conversation, ids)
        }
    }

    /// Stores a version of the "plan" artifact produced by `messages[index]`.
    private func store(_ content: String, message index: Int, kind: String = "document") throws {
        let draft = ArtifactDraft(key: "plan", kind: kind, title: "Plan", meta: [:], content: content, isComplete: true)
        _ = try queue.write {
            try ChatArtifactQueries.saveVersion($0, conversationID: conversationID, messageID: messages[index],
                                                draft: draft, edited: false)
        }
    }

    private func makePanel() -> ArtifactPanelModel {
        ArtifactPanelModel(db: queue, conversationID: conversationID, key: "plan")
    }

    private func range(_ needle: String, in model: ArtifactCommentsModel) throws -> NSRange {
        let text = try XCTUnwrap(model.rendered?.text)
        let found = (text as NSString).range(of: needle)
        XCTAssertNotEqual(found.location, NSNotFound, "\(needle) not in the rendered text")
        return found
    }

    private func row(_ id: Int64) throws -> ArtifactComment? {
        try queue.read {
            try ArtifactComment.fetchOne($0, sql: "SELECT * FROM chat_artifact_comments WHERE id = ?", arguments: [id])
        }
    }

    func testCommentAnchorsOnTheLatestVersionsRenderedText() throws {
        try store(v1, message: 0)
        let model = makePanel().comments
        XCTAssertTrue(model.add(body: "Why so small?", selection: try range("retry budget small", in: model)))
        let comment = try XCTUnwrap(model.comments.first)
        XCTAssertEqual(comment.anchorQuote, "retry budget small")
        XCTAssertEqual(comment.anchorHeading, "Risks")
        XCTAssertEqual(comment.artifactVersion, 1)
        XCTAssertEqual(comment.status, .open)
        XCTAssertEqual(model.ranges[comment.id], try range("retry budget small", in: model))
    }

    func testEmptySelectionOrBodyWritesNothing() throws {
        try store(v1, message: 0)
        let model = makePanel().comments
        XCTAssertFalse(model.add(body: "x", selection: NSRange(location: 3, length: 0)))
        XCTAssertFalse(model.add(body: "   ", selection: try range("retry", in: model)))
        XCTAssertTrue(model.comments.isEmpty)
        XCTAssertEqual(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chat_artifact_comments") }, 0)
    }

    func testANewVersionThatKeepsThePassageMovesTheCommentOntoIt() throws {
        try store(v1, message: 0)
        let panel = makePanel()
        panel.comments.add(body: "Why so small?", selection: try range("retry budget small", in: panel.comments))
        let id = try XCTUnwrap(panel.comments.comments.first?.id)

        try store("Intro added by the assistant.\n\n" + v1.replacingOccurrences(of: "Ship on Friday.", with: "Ship on Thursday."),
                  message: 1)
        panel.turnFinished()

        XCTAssertEqual(try row(id)?.status, .open)
        XCTAssertEqual(try row(id)?.artifactVersion, 2)
        XCTAssertEqual(panel.comments.ranges[id], try range("retry budget small", in: panel.comments))
    }

    func testANewVersionWithoutThePassageMakesOnlyThatCommentOutdated() throws {
        try store(v1, message: 0)
        let panel = makePanel()
        panel.comments.add(body: "Why so small?", selection: try range("retry budget small", in: panel.comments))
        panel.comments.add(body: "Thursday?", selection: try range("Ship on Friday", in: panel.comments))
        let (risk, date) = (panel.comments.comments[0].id, panel.comments.comments[1].id)

        try store(v1.replacingOccurrences(of: "Keep the retry budget small so a flaky service cannot stall the sync.",
                                          with: "Retries are unbounded."), message: 1)
        panel.turnFinished()

        XCTAssertEqual(try row(risk)?.status, .outdated)
        XCTAssertEqual(try row(risk)?.artifactVersion, 1)
        XCTAssertNil(panel.comments.ranges[risk])
        XCTAssertEqual(try row(date)?.status, .open)
        XCTAssertEqual(try row(date)?.artifactVersion, 2)
        XCTAssertEqual(panel.comments.outdated.map(\.id), [risk])
        XCTAssertEqual(panel.comments.unsent.map(\.id), [date])
    }

    func testSentCommentsAreReanchoredAndResolvedOnesOnlyLoseTheirHighlight() throws {
        try store(v1, message: 0)
        let panel = makePanel()
        panel.comments.add(body: "Why so small?", selection: try range("retry budget small", in: panel.comments))
        panel.comments.add(body: "Thursday?", selection: try range("Ship on Friday", in: panel.comments))
        let (sent, resolved) = (panel.comments.comments[0].id, panel.comments.comments[1].id)
        try queue.write { db in
            try ArtifactCommentQueries.markSent(db, ids: [sent, resolved], at: Date())
            try ArtifactCommentQueries.resolve(db, id: resolved)
        }

        try store("# Plan\n\nAll rewritten.", message: 1)
        panel.turnFinished()

        XCTAssertEqual(try row(sent)?.status, .outdated)
        XCTAssertNotNil(try row(sent)?.sentAt, "an outdated sent comment keeps sent_at")
        XCTAssertEqual(try row(resolved)?.status, .resolved)
        XCTAssertTrue(panel.comments.ranges.isEmpty)
    }

    func testTheOwnersEditIsANewVersionAndReanchorsLikeAnyOther() throws {
        try store(v1, message: 0)
        let panel = makePanel()
        panel.comments.add(body: "Thursday?", selection: try range("Ship on Friday", in: panel.comments))
        let id = try XCTUnwrap(panel.comments.comments.first?.id)
        panel.beginEdit()
        panel.editText = panel.editText.replacingOccurrences(of: "Ship on Friday.", with: "Ship on Thursday.")
        panel.saveEdit()
        XCTAssertEqual(try row(id)?.status, .outdated)
    }

    func testAnOutdatedCommentIsNeverReattachedWhenItsTextComesBack() throws {
        try store(v1, message: 0)
        let panel = makePanel()
        panel.comments.add(body: "Thursday?", selection: try range("Ship on Friday", in: panel.comments))
        let id = try XCTUnwrap(panel.comments.comments.first?.id)
        try store("# Plan\n\nRewritten.", message: 1)
        panel.turnFinished()
        try store(v1, message: 2)
        panel.turnFinished()
        XCTAssertEqual(try row(id)?.status, .outdated)
        XCTAssertNil(panel.comments.ranges[id])
    }

    func testUnsentAreInTextOrderAndTheOutgoingMessageCarriesExactlyThem() throws {
        try store(v1, message: 0)
        let model = makePanel().comments
        model.add(body: "Thursday?", selection: try range("Ship on Friday", in: model))
        model.add(body: "Why so small?", selection: try range("retry budget small", in: model))
        model.add(body: "Already sent", selection: try range("flaky service", in: model))
        let alreadySent = try XCTUnwrap(model.comments.last?.id)
        _ = try queue.write { try ArtifactCommentQueries.markSent($0, ids: [alreadySent], at: Date()) }
        model.reload()

        XCTAssertEqual(model.unsent.map(\.body), ["Why so small?", "Thursday?"])
        XCTAssertEqual(model.sent.map(\.id), [alreadySent])
        let outgoing = try XCTUnwrap(model.outgoing())
        XCTAssertEqual(outgoing.ids, model.unsent.map(\.id))
        XCTAssertEqual(outgoing.text,
                       ArtifactCommentMessage.compose(title: "Plan", key: "plan", version: 1, comments: model.unsent))
    }

    func testNothingUnsentHasNoOutgoingMessage() throws {
        try store(v1, message: 0)
        XCTAssertNil(makePanel().comments.outgoing())
    }

    func testDeleteAndResolveFollowTheStatusRules() throws {
        try store(v1, message: 0)
        let model = makePanel().comments
        model.add(body: "Draft", selection: try range("Ship on Friday", in: model))
        model.add(body: "Sent", selection: try range("retry budget small", in: model))
        let (draft, sent) = (model.comments[0].id, model.comments[1].id)
        _ = try queue.write { try ArtifactCommentQueries.markSent($0, ids: [sent], at: Date()) }
        model.reload()
        model.delete(draft)
        model.resolve(sent)
        XCTAssertEqual(model.comments.map(\.id), [sent])
        XCTAssertEqual(model.resolved.map(\.id), [sent])
        XCTAssertNil(model.ranges[draft])
    }

    func testNonDocumentKindsAnchorOnTheirRawContent() throws {
        try store("a,b\nretry,small", message: 0, kind: "table")
        let model = makePanel().comments
        XCTAssertEqual(model.rendered?.text, "a,b\nretry,small")
        XCTAssertTrue(model.add(body: "Rename", selection: try range("retry", in: model)))
    }

    func testCommentingNeedsTheLatestStoredVersionOnScreen() throws {
        try store(v1, message: 0)
        try store(v1 + "\n\nMore.", message: 1)
        let panel = makePanel()
        XCTAssertTrue(panel.canComment)
        panel.selectedVersion = 1
        XCTAssertFalse(panel.canComment, "an older version is read-only for comments")
        panel.selectedVersion = 2
        XCTAssertTrue(panel.canComment)
        panel.selectedVersion = nil
        panel.applyStreaming([ArtifactDraft(key: "plan", kind: "document", title: "Plan", meta: [:], content: "partial",
                                            isComplete: false)])
        XCTAssertFalse(panel.canComment, "a version being written is not commentable")
        panel.turnFinished()
        panel.beginEdit()
        XCTAssertFalse(panel.canComment, "editing and commenting are exclusive")
    }
}
```

Run: `make test-swift FILTER=ArtifactComment > /tmp/t24a.log 2>&1; echo "exit=$?"` and `make test-swift FILTER=CommentBatchComposerTests > /tmp/t24j.log 2>&1; echo "exit=$?"` → both `exit≠0` (`ArtifactComment`/`CommentBatchComposer` not found). (`FILTER` is a substring match of `swift test --filter`, so the first runs all four `ArtifactComment…` classes.)

- [ ] **Step 2: The row model**

Create `WatchtowerDesktop/Sources/WatchtowerCore/Models/ArtifactComment.swift`:

```swift
import Foundation
import GRDB

/// One `chat_artifact_comments` row (goose migration 00082): the owner's
/// comment on a passage of an AI Chat artifact. It belongs to the
/// (conversation, key), not to one version: `artifactVersion` is the version
/// its anchor was last found on, and every newer version re-anchors it
/// (`ArtifactCommentReanchor`).
package struct ArtifactComment: FetchableRecord, Decodable, Identifiable, Equatable, Sendable {
    package enum Status: String, Decodable, Sendable {
        /// Written, not sent yet — the owner's private draft.
        case open
        /// Went out in an owner chat message.
        case sent
        case resolved
        /// Its quote is gone from the latest version.
        case outdated
    }

    package let id: Int64
    package let conversationID: Int64
    package let artifactKey: String
    package let artifactVersion: Int
    package let body: String
    package let anchorQuote: String
    package let anchorPrefix: String
    package let anchorSuffix: String
    package let anchorHeading: String
    package let status: Status
    package let createdAt: Double
    package let sentAt: Double?

    package enum CodingKeys: String, CodingKey {
        case id, body, status
        case conversationID = "conversation_id"
        case artifactKey = "artifact_key"
        case artifactVersion = "artifact_version"
        case anchorQuote = "anchor_quote"
        case anchorPrefix = "anchor_prefix"
        case anchorSuffix = "anchor_suffix"
        case anchorHeading = "anchor_heading"
        case createdAt = "created_at"
        case sentAt = "sent_at"
    }

    package var anchor: CommentAnchor {
        CommentAnchor(quote: anchorQuote, prefix: anchorPrefix, suffix: anchorSuffix, heading: anchorHeading)
    }

    /// Open and sent comments follow the artifact to its newer versions.
    package var isLive: Bool { status == .open || status == .sent }

    /// What `CommentThreadView` shows: the quote and the owner's one comment.
    package var content: CommentThreadContent {
        CommentThreadContent(
            id: id,
            quote: anchorQuote,
            statusNote: statusNote,
            entries: [CommentThreadContent.Entry(id: id, author: "You", body: body)]
        )
    }

    private var statusNote: String {
        switch status {
        case .open: "Not sent yet"
        case .sent: "Sent to the assistant"
        case .resolved: "Resolved"
        case .outdated: "Outdated — the quoted text changed"
        }
    }
}
```

- [ ] **Step 3: Anchored text, re-anchor plan, batch composer, message**

Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ArtifactCommentText.swift`:

```swift
import Foundation

/// The plain text an artifact's comments anchor on. A `document` renders its
/// markdown through `DocumentRendering` — the text the owner reads; every
/// other kind is its raw content (a table's CSV, an email body, code), shown
/// verbatim, `code` in the code-block style.
package enum ArtifactCommentText {
    package static func render(kind: String, content: String) -> RenderedDocument {
        switch kind {
        case "document":
            return DocumentRendering.render(content)
        case "code":
            let runs = content.isEmpty
                ? [] : [DocumentStyleRun(location: 0, length: content.utf16.count, style: .codeBlock)]
            return RenderedDocument(text: content, headings: [], runs: runs)
        default:
            return RenderedDocument(text: content, headings: [], runs: [])
        }
    }
}
```

Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ArtifactCommentReanchor.swift`:

```swift
import Foundation

/// Re-anchors an artifact's comments on its latest version (pure; the model
/// applies the plan in one write). Open and sent comments follow the text:
/// found → they move onto this version, gone → outdated. Resolved comments
/// only get a highlight when their quote is still there; outdated ones are
/// never re-located, so a passage that comes back later does not silently
/// re-attach an old comment.
package enum ArtifactCommentReanchor {
    package struct Plan: Equatable, Sendable {
        /// Comment id → its range (UTF-16) in the version's rendered text.
        package var ranges: [Int64: NSRange] = [:]
        /// Live comments found on a version other than the one they were anchored on.
        package var moved: [Int64] = []
        /// Live comments whose quote is gone.
        package var lost: [Int64] = []

        package init(ranges: [Int64: NSRange] = [:], moved: [Int64] = [], lost: [Int64] = []) {
            self.ranges = ranges
            self.moved = moved
            self.lost = lost
        }

        package var isNoOp: Bool { moved.isEmpty && lost.isEmpty }
    }

    package static func plan(_ comments: [ArtifactComment], text: String, version: Int) -> Plan {
        var plan = Plan()
        for comment in comments where comment.status != .outdated {
            if let found = comment.anchor.locate(in: text) {
                plan.ranges[comment.id] = NSRange(found, in: text)
                if comment.isLive, comment.artifactVersion != version { plan.moved.append(comment.id) }
            } else if comment.isLive {
                plan.lost.append(comment.id)
            }
        }
        return plan
    }
}
```

Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/CommentBatchComposer.swift`:

```swift
import Foundation

/// The owner's comments go to the assistant as ONE batch, never one by one
/// (owner rule, every surface): artifact comments ("Send N comments", Task 24)
/// and chat quotes (the pending quote batch, Task 25) both compose their
/// single owner message here. Pure.
package enum CommentBatchComposer {
    /// One quoted passage and the owner's comment on it.
    package struct Item: Equatable, Sendable {
        package let quote: String
        /// The nearest heading above the quote ("" = none).
        package let heading: String
        package let comment: String

        package init(quote: String, heading: String, comment: String) {
            self.quote = quote
            self.heading = heading
            self.comment = comment
        }
    }

    /// `header`, the numbered items, `closing`, then the owner's own `note`,
    /// separated by blank lines. With no items only the note remains (header
    /// and closing describe items); nil when there is nothing at all.
    package static func compose(header: String?, items: [Item], closing: String? = nil, note: String = "") -> String? {
        var blocks: [String] = []
        if !items.isEmpty {
            if let header { blocks.append(header) }
            for (index, item) in items.enumerated() {
                let place = item.heading.isEmpty ? "On this passage:" : "Under \"\(item.heading)\":"
                var lines = ["\(index + 1). \(place)", blockquote(item.quote)]
                let comment = item.comment.trimmingCharacters(in: .whitespacesAndNewlines)
                if !comment.isEmpty { lines.append(comment) }
                blocks.append(lines.joined(separator: "\n"))
            }
            if let closing { blocks.append(closing) }
        }
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNote.isEmpty { blocks.append(trimmedNote) }
        return blocks.isEmpty ? nil : blocks.joined(separator: "\n\n")
    }

    /// `text` as one markdown blockquote: surrounding whitespace trimmed,
    /// every line prefixed with "> ", a blank line kept as ">" so the quote
    /// stays a single block. A line's own indentation is kept.
    package static func blockquote(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                let kept = String(line.reversed().drop(while: \.isWhitespace).reversed())
                return kept.isEmpty ? ">" : "> " + kept
            }
            .joined(separator: "\n")
    }

    package static func sendButtonTitle(count: Int) -> String {
        count == 1 ? "Send 1 comment" : "Send \(count) comments"
    }
}
```

Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ArtifactCommentMessage.swift`:

```swift
import Foundation

/// The owner message "Send N comments" composes — the only way the assistant
/// ever learns about artifact comments. Pure: the chat sends the text as an
/// ordinary owner turn (`ChatViewModel.sendArtifactComments`).
package enum ArtifactCommentMessage {
    /// The composed text and exactly the comment ids it carries.
    package struct Outgoing: Equatable, Sendable {
        package let text: String
        package let ids: [Int64]
    }

    /// nil when there is nothing to send. `comments` are used in the given
    /// order (the model passes them in text order). One batch, via
    /// `CommentBatchComposer` — the same rule the chat quote batch uses.
    package static func compose(title: String, key: String, version: Int, comments: [ArtifactComment]) -> String? {
        guard !comments.isEmpty else { return nil }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? key : title
        return CommentBatchComposer.compose(
            header: "Comments on the artifact \"\(name)\" (key=\"\(key)\", version \(version)):",
            items: comments.map {
                CommentBatchComposer.Item(quote: $0.anchorQuote, heading: $0.anchorHeading, comment: $0.body)
            },
            closing: "Please reply with a new version of this artifact under the same key that addresses these comments."
        )
    }
}
```

- [ ] **Step 4: Queries**

Create `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ArtifactCommentQueries.swift`:

```swift
import Foundation
import GRDB

package enum ArtifactCommentError: LocalizedError, Equatable {
    case emptyBody
    case emptyQuote

    package var errorDescription: String? {
        switch self {
        case .emptyBody: "Write a comment first."
        case .emptyQuote: "Select the text to comment on."
        }
    }
}

/// `chat_artifact_comments` (migration 00082). The Desktop is the only
/// writer; nothing here reaches the assistant — sent comments travel only in
/// the owner's own chat message.
package enum ArtifactCommentQueries {
    package static func comments(_ db: Database, conversationID: Int64, key: String) throws -> [ArtifactComment] {
        try ArtifactComment.fetchAll(db, sql: """
            SELECT * FROM chat_artifact_comments WHERE conversation_id = ? AND artifact_key = ? ORDER BY id
            """, arguments: [conversationID, key])
    }

    @discardableResult
    package static func add(
        _ db: Database, conversationID: Int64, key: String, version: Int, anchor: CommentAnchor, body: String,
        now: Date = Date()
    ) throws -> Int64 {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ArtifactCommentError.emptyBody }
        guard !anchor.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ArtifactCommentError.emptyQuote
        }
        try db.execute(sql: """
            INSERT INTO chat_artifact_comments
                (conversation_id, artifact_key, artifact_version, body,
                 anchor_quote, anchor_prefix, anchor_suffix, anchor_heading, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [conversationID, key, version, trimmed,
                             anchor.quote, anchor.prefix, anchor.suffix, anchor.heading, now.timeIntervalSince1970])
        return db.lastInsertedRowID
    }

    /// An unsent comment is the owner's private draft: deleting it leaves no
    /// trace. A sent one is part of the conversation — it can only be resolved.
    @discardableResult
    package static func deleteUnsent(_ db: Database, id: Int64) throws -> Bool {
        try db.execute(sql: "DELETE FROM chat_artifact_comments WHERE id = ? AND status = 'open'", arguments: [id])
        return db.changesCount > 0
    }

    @discardableResult
    package static func resolve(_ db: Database, id: Int64) throws -> Bool {
        try db.execute(sql: """
            UPDATE chat_artifact_comments SET status = 'resolved' WHERE id = ? AND status IN ('sent', 'outdated')
            """, arguments: [id])
        return db.changesCount > 0
    }

    /// Marks exactly `ids` sent, and only those still unsent — a comment added
    /// after the message was composed, or one sent earlier, is never touched.
    /// Runs inside the transaction that persists the owner message.
    @discardableResult
    package static func markSent(_ db: Database, ids: [Int64], at date: Date) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        var arguments: StatementArguments = [date.timeIntervalSince1970]
        arguments += StatementArguments(ids)
        try db.execute(sql: """
            UPDATE chat_artifact_comments SET status = 'sent', sent_at = ?
            WHERE status = 'open' AND id IN (\(databaseQuestionMarks(count: ids.count)))
            """, arguments: arguments)
        return db.changesCount
    }

    /// Applies a re-anchor plan: found live comments move onto `version`, lost
    /// ones become outdated (keeping the version they were last found on).
    /// Resolved and outdated rows are never touched.
    package static func apply(_ db: Database, plan: ArtifactCommentReanchor.Plan, version: Int) throws {
        for id in plan.moved {
            try db.execute(sql: """
                UPDATE chat_artifact_comments SET artifact_version = ? WHERE id = ? AND status IN ('open', 'sent')
                """, arguments: [version, id])
        }
        for id in plan.lost {
            try db.execute(sql: """
                UPDATE chat_artifact_comments SET status = 'outdated' WHERE id = ? AND status IN ('open', 'sent')
                """, arguments: [id])
        }
    }
}
```

- [ ] **Step 5: `ArtifactCommentsModel` + `ArtifactPanelModel` wiring**

Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ArtifactCommentsModel.swift`:

```swift
import Foundation
import GRDB
import Observation

/// The comments of one artifact panel (conversation, key): the latest stored
/// version's text they anchor on, their located ranges, and the owner's
/// writes. Owned by `ArtifactPanelModel`, so it lives as long as the panel.
/// It never sends anything (CHAT-05): it only hands out the composed message
/// (`outgoing()`); the chat sends it as the owner's own turn.
@MainActor @Observable
package final class ArtifactCommentsModel {
    package let conversationID: Int64
    package let key: String
    package private(set) var comments: [ArtifactComment] = []
    /// The latest stored version the comments are anchored on; nil = none yet.
    package private(set) var artifact: ChatArtifact?
    package private(set) var rendered: RenderedDocument?
    /// Comment id → its range (UTF-16) in `rendered.text`.
    package private(set) var ranges: [Int64: NSRange] = [:]
    package private(set) var errorMessage: String?
    @ObservationIgnored private let db: any DatabaseWriter

    package init(db: any DatabaseWriter, conversationID: Int64, key: String) {
        self.db = db
        self.conversationID = conversationID
        self.key = key
    }

    // MARK: - Groups

    /// Unsent comments in text order (unlocated ones last), then by id.
    package var unsent: [ArtifactComment] {
        comments.filter { $0.status == .open }.sorted { lhs, rhs in
            (ranges[lhs.id]?.location ?? .max, lhs.id) < (ranges[rhs.id]?.location ?? .max, rhs.id)
        }
    }

    package var sent: [ArtifactComment] { comments.filter { $0.status == .sent } }
    package var resolved: [ArtifactComment] { comments.filter { $0.status == .resolved } }
    package var outdated: [ArtifactComment] { comments.filter { $0.status == .outdated } }

    package func threadID(at location: Int) -> Int64? {
        ranges.first { NSLocationInRange(location, $0.value) }?.key
    }

    // MARK: - Loading

    /// Anchors on `latest` (the key's newest stored version): re-locates every
    /// comment and, when something moved or was lost, writes the plan once.
    /// Called on every panel reload — open, a finished turn, the owner's edit.
    package func sync(latest: ChatArtifact?) {
        artifact = latest
        let text = latest.map { ArtifactCommentText.render(kind: $0.kind, content: $0.content) }
        rendered = text
        do {
            var loaded = try db.read { try ArtifactCommentQueries.comments($0, conversationID: conversationID, key: key) }
            guard let latest, let text else {
                comments = loaded
                ranges = [:]
                errorMessage = nil
                return
            }
            let plan = ArtifactCommentReanchor.plan(loaded, text: text.text, version: latest.version)
            if !plan.isNoOp {
                loaded = try db.write { db in
                    try ArtifactCommentQueries.apply(db, plan: plan, version: latest.version)
                    return try ArtifactCommentQueries.comments(db, conversationID: conversationID, key: key)
                }
            }
            comments = loaded
            ranges = plan.ranges
            errorMessage = nil
        } catch {
            errorMessage = "Could not load the comments: \(error.localizedDescription)"
        }
    }

    /// Re-reads the rows and re-locates them on the current version, without
    /// writing (after the chat marked some sent, or a test's direct write).
    package func reload() {
        sync(latest: artifact)
    }

    // MARK: - Owner actions

    @discardableResult
    package func add(body: String, selection: NSRange) -> Bool {
        guard let artifact, let rendered, selection.length > 0,
              let range = Range(selection, in: rendered.text),
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let anchor = CommentAnchor.make(text: rendered.text, range: range, headings: rendered.headingOffsets)
        do {
            _ = try db.write {
                try ArtifactCommentQueries.add($0, conversationID: conversationID, key: key,
                                               version: artifact.version, anchor: anchor, body: body)
            }
            reload()
            return true
        } catch {
            errorMessage = "Could not save the comment: \(error.localizedDescription)"
            return false
        }
    }

    package func delete(_ id: Int64) {
        write { try ArtifactCommentQueries.deleteUnsent($0, id: id) }
    }

    package func resolve(_ id: Int64) {
        write { try ArtifactCommentQueries.resolve($0, id: id) }
    }

    /// The owner message for "Send N comments" and the ids it carries; nil
    /// when nothing is unsent.
    package func outgoing() -> ArtifactCommentMessage.Outgoing? {
        guard let artifact else { return nil }
        let pending = unsent
        guard let text = ArtifactCommentMessage.compose(title: artifact.title, key: key,
                                                        version: artifact.version, comments: pending) else { return nil }
        return ArtifactCommentMessage.Outgoing(text: text, ids: pending.map(\.id))
    }

    private func write(_ change: (Database) throws -> Bool) {
        do {
            _ = try db.write(change)
            reload()
        } catch {
            errorMessage = "Could not update the comment: \(error.localizedDescription)"
        }
    }
}
```

`reload()` re-plans against the same version: a comment that was just added or already moved is a no-op there, so it writes nothing.

In `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ArtifactPanelModel.swift`:

1. Add a stored property after `errorMessage`:

```swift
    /// The comments on this key, anchored on its latest stored version.
    package let comments: ArtifactCommentsModel
```

2. In `init`, before `reload()`:

```swift
        comments = ArtifactCommentsModel(db: db, conversationID: conversationID, key: key)
```

3. In `reload()`, inside the `do` block right after `versions = …` and the `selectedVersion` reset:

```swift
            comments.sync(latest: versions.last)
```

4. Add after `displayed`:

```swift
    /// Comments go on the latest stored version, shown as stored: not an
    /// older version, not a version being written, not while editing.
    package var canComment: Bool {
        guard let latest = versions.last, liveDraft == nil, !isEditing else { return false }
        return selectedArtifact?.id == latest.id
    }
```

Run:
```bash
make test-swift FILTER=ArtifactComment > /tmp/t24a.log 2>&1; echo "exit=$?"
make test-swift FILTER=CommentBatchComposerTests > /tmp/t24j.log 2>&1; echo "exit=$?"
make test-swift FILTER=ArtifactPanelModelTests > /tmp/t24b.log 2>&1; echo "exit=$?"
```
Expected: every `exit=0` (the existing panel tests are unaffected: with no comments, `sync` reads and writes nothing).

- [ ] **Step 6: CHAT-05 scan — failing first**

Replace the body of `testChat05ArtifactSurfacesNeverWrite` in `WatchtowerDesktop/Tests/Core/ArtifactChat05ScanTests.swift` (keep the class, its doc comment and the test's name and `/// BEHAVIOR CHAT-05` line):

```swift
    /// BEHAVIOR CHAT-05 — see docs/inventory/chat.md
    func testChat05ArtifactSurfacesNeverWrite() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .appendingPathComponent("Sources")
        let files = [
            "WatchtowerCore/Services/Chat/ArtifactParser.swift",
            "WatchtowerCore/Services/Chat/ArtifactActions.swift",
            "WatchtowerCore/Services/Chat/ArtifactPanelModel.swift",
            "Views/Chat/ArtifactPanelView.swift",
            "Views/Chat/ArtifactCardView.swift",
            "Views/Chat/ArtifactActionPerformer.swift",
            "Views/Chat/ChatMessageRow.swift",
            "Views/Chat/ChatInspectorContent.swift",
            // Artifact comments (projects POC phase 6): comments reach the
            // assistant only as the owner's own message, sent by the chat.
            "WatchtowerCore/Services/Chat/ArtifactCommentsModel.swift",
            "WatchtowerCore/Services/Chat/ArtifactCommentMessage.swift",
            "WatchtowerCore/Services/Chat/ArtifactCommentReanchor.swift",
            "WatchtowerCore/Services/Chat/ArtifactCommentText.swift",
            "WatchtowerCore/Services/Chat/CommentBatchComposer.swift",
            "WatchtowerCore/Database/Queries/ArtifactCommentQueries.swift",
            "Views/Chat/ArtifactCommentsView.swift"
        ]
        let forbidden = ["Process(", "CLIRunner", "URLSession", "findCLIPath", "WatchtowerAIService", "ChatSessionPool",
                         ".send(", "sendDraft", "startTurn"]
        for file in files {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for token in forbidden {
                XCTAssertFalse(text.contains(token), "\(file) must not reference \(token) (CHAT-05)")
            }
        }
    }
```

Run: `make test-swift FILTER=ArtifactChat05ScanTests > /tmp/t24c.log 2>&1; echo "exit=$?"` → `exit≠0` (`ArtifactCommentsView.swift` does not exist yet — the read throws).

- [ ] **Step 7: Send through the chat — failing `ChatViewModel` tests**

Append to `WatchtowerDesktop/Tests/ChatViewModelTests.swift` (inside the class):

```swift
    // MARK: - Artifact comments

    /// A conversation with one stored `document` artifact ("plan"), its panel open.
    private func conversationWithArtifact(_ vm: ChatViewModel, content: String) throws -> Int64 {
        let convID = try XCTUnwrap(vm.newConversation())
        try dbManager.dbPool.write { d in
            let message = try TestDatabase.insertChatMessage(d, conversationID: convID, role: "assistant", text: "")
            _ = try ChatArtifactQueries.saveVersion(
                d, conversationID: convID, messageID: message,
                draft: ArtifactDraft(key: "plan", kind: "document", title: "Plan", meta: [:], content: content,
                                     isComplete: true),
                edited: false)
        }
        vm.openArtifact(key: "plan")
        return convID
    }

    private func addComment(_ vm: ChatViewModel, on needle: String, body: String) throws -> ArtifactCommentsModel {
        let comments = try XCTUnwrap(vm.artifactPanel?.comments)
        let text = try XCTUnwrap(comments.rendered?.text)
        XCTAssertTrue(comments.add(body: body, selection: (text as NSString).range(of: needle)))
        return comments
    }

    private func commentStatuses() throws -> [String] {
        try dbManager.dbPool.read { try String.fetchAll($0, sql: "SELECT status FROM chat_artifact_comments ORDER BY id") }
    }

    /// CHAT-05 spirit: a comment never leaves the machine by itself — it
    /// reaches the assistant only inside the owner's own message.
    func testArtifactCommentsReachTheAssistantOnlyAsTheOwnersMessage() throws {
        let vm = try makeViewModel()
        _ = try conversationWithArtifact(vm, content: "# Plan\n\nShip on Friday.")
        let comments = try addComment(vm, on: "Ship on Friday", body: "Thursday?")
        XCTAssertTrue(try lastFake().turns.isEmpty, "adding a comment sends nothing")
        let expected = try XCTUnwrap(comments.outgoing()).text

        vm.sendArtifactComments()

        XCTAssertEqual(try lastFake().turns.count, 1)
        XCTAssertEqual(try lastStoredUserText(vm), expected)
        XCTAssertEqual(comments.comments.map(\.status), [.sent])
        XCTAssertNotNil(comments.comments.first?.sentAt)
    }

    func testAFailedSaveLeavesTheCommentsUnsent() throws {
        let vm = try makeViewModel()
        _ = try conversationWithArtifact(vm, content: "# Plan\n\nShip on Friday.")
        _ = try addComment(vm, on: "Ship on Friday", body: "Thursday?")
        try dbManager.dbPool.write { d in
            try d.execute(sql: """
                CREATE TRIGGER fail_user BEFORE INSERT ON chat_messages WHEN NEW.role = 'user'
                BEGIN SELECT RAISE(ABORT, 'boom'); END
                """)
        }
        vm.sendArtifactComments()
        XCTAssertTrue(try lastFake().turns.isEmpty)
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertEqual(try commentStatuses(), ["open"])
    }

    func testNothingIsSentWhileAnAnswerIsStreaming() throws {
        let vm = try makeViewModel()
        _ = try conversationWithArtifact(vm, content: "# Plan\n\nShip on Friday.")
        XCTAssertTrue(vm.send(text: "q"))
        _ = try addComment(vm, on: "Ship on Friday", body: "Thursday?")
        vm.sendArtifactComments()
        XCTAssertEqual(try lastFake().turns.count, 1, "only the first question went out")
        XCTAssertEqual(try commentStatuses(), ["open"])
    }

    func testOnlyTheUnsentCommentsAreIncludedAndMarked() throws {
        let vm = try makeViewModel()
        _ = try conversationWithArtifact(vm, content: "# Plan\n\nKeep the retry budget small.\n\nShip on Friday.")
        let comments = try addComment(vm, on: "Ship on Friday", body: "Thursday?")
        let earlier = try XCTUnwrap(comments.comments.first?.id)
        _ = try dbManager.dbPool.write { try ArtifactCommentQueries.markSent($0, ids: [earlier], at: Date(timeIntervalSince1970: 100)) }
        comments.reload()
        _ = try addComment(vm, on: "retry budget", body: "Why?")

        vm.sendArtifactComments()

        let stored = try XCTUnwrap(try lastStoredUserText(vm))
        XCTAssertTrue(stored.contains("Why?"))
        XCTAssertFalse(stored.contains("Thursday?"), "an already-sent comment is not sent again")
        XCTAssertEqual(comments.comments.map(\.status), [.sent, .sent])
        XCTAssertEqual(comments.comments.first?.sentAt, 100, "the earlier send keeps its sent_at")
    }
```

Run: `make test-swift FILTER=ChatViewModelTests > /tmp/t24d.log 2>&1; echo "exit=$?"` → `exit≠0` (`sendArtifactComments` missing).

- [ ] **Step 8: `ChatViewModel` — `alsoWrite` + `sendArtifactComments`**

In `WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift`:

1. `TurnPlan` gains, after `var titleText: String?`:

```swift
        /// Extra rows written in the SAME transaction as the owner message
        /// (CHAT-01) — e.g. artifact comments turning `sent`. New messages
        /// only; regenerate/edit never set it.
        var alsoWrite: ((Database) throws -> Void)?
```

2. `send(text:attachments:mentions:skill:)` gains a last parameter and passes it on:

```swift
    @discardableResult
    func send(
        text: String, attachments: [ChatAttachment] = [], mentions: [MentionCandidate] = [], skill: String? = nil,
        alsoWrite: ((Database) throws -> Void)? = nil
    ) -> Bool {
```

and its `TurnPlan(…)` gets `titleText: trimmed, alsoWrite: alsoWrite` (the existing `titleText: trimmed` argument stays; append `alsoWrite:` after it).

3. In `persistTurnStart`, inside the `else` (new message) branch, right after `try ChatAttachmentQueries.link(…)`:

```swift
                try plan.alsoWrite?(db)
```

4. Add under `// MARK: - Artifacts`, after `closeArtifactPanel()`:

```swift
    /// "Send N comments" in the artifact panel: the unsent comments go out as
    /// one ordinary owner turn, and exactly those rows turn `sent` in the
    /// transaction that persists that message — a refused or failed send
    /// leaves them unsent, a sent message never leaves them open.
    func sendArtifactComments() {
        guard let comments = artifactPanel?.comments, let outgoing = comments.outgoing() else { return }
        let ids = outgoing.ids
        let sentAt = Date()
        guard send(text: outgoing.text, alsoWrite: { db in
            try ArtifactCommentQueries.markSent(db, ids: ids, at: sentAt)
        }) else { return }
        comments.reload()
    }
```

Run: `make test-swift FILTER=ChatViewModelTests > /tmp/t24d.log 2>&1; echo "exit=$?"` → `exit=0` (the whole class: the CHAT-01 tests must stay green with the new parameter).

- [ ] **Step 9: Views — comment mode in the panel**

Create `WatchtowerDesktop/Sources/Views/Chat/ArtifactCommentsView.swift`:

```swift
import SwiftUI
import WatchtowerCore

/// The artifact panel's comment mode: the latest version as selectable text
/// with every comment highlighted, the comment list, and "Send N comments".
/// It never sends by itself (CHAT-05): the send bar calls back into the chat,
/// which sends the composed text as the owner's own message.
struct ArtifactCommentsView: View {
    let comments: ArtifactCommentsModel
    let canSend: Bool
    let onSend: () -> Void
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var activeID: Int64?
    @State private var composing = false
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            if let rendered = comments.rendered {
                HStack {
                    Text("Select text, then Comment.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Comment") { composing = true }
                        .disabled(selection.length == 0)
                        .popover(isPresented: $composing) { composer }
                }
                .padding(8)
                DocumentTextView(
                    text: DocumentAttributedString.make(rendered, highlights: comments.ranges, activeThreadID: activeID),
                    selection: $selection,
                    onClick: { activeID = comments.threadID(at: $0) ?? activeID }
                )
                .frame(minHeight: 180)
                Divider()
                list.frame(minHeight: 100, maxHeight: 260)
                Divider()
                ArtifactCommentsSendBar(count: comments.unsent.count, canSend: canSend, onSend: onSend)
            } else {
                ContentUnavailableView("Nothing to comment on yet", systemImage: "text.bubble")
            }
            if let error = comments.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).padding(6)
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Comment on the selection").font(.headline)
            TextEditor(text: $draft).frame(width: 300, height: 90)
            HStack {
                Spacer()
                Button("Cancel") { composing = false }
                Button("Comment") {
                    if comments.add(body: draft, selection: selection) { draft = "" }
                    composing = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(comments.unsent) { row($0) }
                ForEach(comments.sent) { row($0) }
                if !comments.outdated.isEmpty {
                    DisclosureGroup("Outdated (\(comments.outdated.count))") {
                        ForEach(comments.outdated) { row($0) }
                    }
                }
                if !comments.resolved.isEmpty {
                    DisclosureGroup("Resolved (\(comments.resolved.count))") {
                        ForEach(comments.resolved) { row($0) }
                    }
                }
            }
            .padding(10)
        }
    }

    private func row(_ comment: ArtifactComment) -> some View {
        CommentThreadView(
            thread: comment.content,
            isActive: comment.id == activeID,
            onReply: nil,
            onResolve: comment.status == .sent || comment.status == .outdated ? { comments.resolve(comment.id) } : nil,
            onReopen: nil,
            onDelete: comment.status == .open ? { comments.delete(comment.id) } : nil
        )
        .onTapGesture { activeID = comment.id }
    }
}

/// "Send N comments": enabled with unsent comments and no answer streaming.
struct ArtifactCommentsSendBar: View {
    let count: Int
    let canSend: Bool
    let onSend: () -> Void

    var body: some View {
        HStack {
            Text(count == 0 ? "No unsent comments" : "The assistant sees them only when you send them.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(CommentBatchComposer.sendButtonTitle(count: count), action: onSend)
                .disabled(count == 0 || !canSend)
                .help(canSend ? "Send the comments to the assistant as your next message"
                              : "Wait for the current answer to finish")
        }
        .padding(10)
    }
}
```

In `WatchtowerDesktop/Sources/Views/Chat/ArtifactPanelView.swift`:

1. Properties become (new two before `onClose`, so the call site's trailing closure still binds to `onClose`):

```swift
    @Bindable var model: ArtifactPanelModel
    let gmailConnected: Bool
    let slackLinks: SlackLinkResolver?
    /// No answer is streaming (the chat refuses a second turn anyway).
    let canSendComments: Bool
    /// "Send N comments" — the chat sends them as the owner's message.
    let onSendComments: () -> Void
    var onClose: () -> Void

    @State private var notice: String?
    @State private var commenting = false
```

2. In `header`, before `Spacer()`, add:

```swift
            if !model.versions.isEmpty {
                Button { commenting.toggle() } label: {
                    Label(commentsLabel, systemImage: commenting ? "text.bubble.fill" : "text.bubble")
                }
                .buttonStyle(.borderless)
                .disabled(!model.canComment && !commenting)
                .help(commenting ? "Back to the artifact" : "Comment on passages of this artifact")
                .accessibilityLabel("Comments")
            }
```

and add to the struct:

```swift
    private var commentsLabel: String {
        let unsent = model.comments.unsent.count
        return unsent == 0 ? "Comments" : "Comments (\(unsent))"
    }
```

3. `content` gets a first branch:

```swift
    @ViewBuilder
    private var content: some View {
        if commenting, model.canComment {
            ArtifactCommentsView(comments: model.comments, canSend: canSendComments, onSend: onSendComments)
        } else if model.isEditing {
```

(the rest of `content` unchanged). While a version streams, an older version is picked, or an edit is open, `canComment` is false and the panel shows its normal content; comment mode comes back by itself once it is true again.

In `WatchtowerDesktop/Sources/Views/Chat/ChatInspectorContent.swift` replace the `ArtifactPanelView(…)` call with:

```swift
                ArtifactPanelView(
                    model: panel, gmailConnected: chatVM.gmailConnected, slackLinks: chatVM.slackLinks,
                    canSendComments: !chatVM.isStreaming,
                    onSendComments: { chatVM.sendArtifactComments() }
                ) {
                    chatVM.closeArtifactPanel()
                }
```

Create `WatchtowerDesktop/Tests/ArtifactCommentsSendBarTests.swift`:

```swift
import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop

@MainActor
final class ArtifactCommentsSendBarTests: XCTestCase {
    func testSendTapsTheCallbackWithUnsentCommentsAndNoStream() throws {
        var sent = 0
        let bar = ArtifactCommentsSendBar(count: 2, canSend: true) { sent += 1 }
        let button = try bar.inspect().find(button: "Send 2 comments")
        XCTAssertFalse(try button.isDisabled())
        try button.tap()
        XCTAssertEqual(sent, 1)
    }

    func testDisabledWithNothingUnsentOrWhileStreaming() throws {
        XCTAssertTrue(try ArtifactCommentsSendBar(count: 0, canSend: true) {}.inspect()
            .find(button: "Send 0 comments").isDisabled())
        XCTAssertTrue(try ArtifactCommentsSendBar(count: 1, canSend: false) {}.inspect()
            .find(button: "Send 1 comment").isDisabled())
    }
}
```

- [ ] **Step 10: Go — one contract line**

In `internal/chat/artifacts_contract.go`, add one line to `artifactsRules`, right after the `- To revise an artifact, …` line:

```go
- When the owner sends comments on an artifact (a message quoting passages of it, each with a note), reply with a new version of that artifact under the SAME key that addresses every comment, and say in one line what changed.
```

Append to `internal/chat/artifacts_contract_test.go`:

```go
// TestArtifactsContract_CommentsAreAnsweredWithANewVersion: the owner's
// "Send N comments" message is ordinary chat text; the contract tells the
// model to answer it with a new version of the same key, which the Desktop
// re-anchors the comments onto.
func TestArtifactsContract_CommentsAreAnsweredWithANewVersion(t *testing.T) {
	c := ArtifactsContract()
	assert.Contains(t, c, "sends comments on an artifact")
	assert.Contains(t, c, "new version of that artifact under the SAME key")
}
```

Run:
```bash
go test ./internal/chat -run 'TestArtifactsContract|TestChat05' > /tmp/t24e.log 2>&1; echo "exit=$?"
go test ./internal/chat -run TestBuildSystemPrompt_Golden -update > /tmp/t24f.log 2>&1; echo "exit=$?"
go test ./internal/chat > /tmp/t24g.log 2>&1; echo "exit=$?"
```
Expected: every `exit=0` (`TestArtifactsContract_StaysSmall` keeps the contract under 4500 bytes); `git diff internal/chat/testdata/system_prompt_main.golden` shows exactly the one added line.

- [ ] **Step 11: Inventory (CHAT-05 scope)**

In `docs/inventory/chat.md`, CHAT-05 **Observable**, after the sentence ending `— a source scan, not just a behavioral test.` insert:

```markdown
The same scan covers the artifact-comment files (`ArtifactCommentsModel`,
`ArtifactCommentMessage`, `ArtifactCommentReanchor`, `ArtifactCommentText`,
`ArtifactCommentQueries`, `ArtifactCommentsView`, the shared `CommentBatchComposer`), and no scanned file may
reference `.send(`, `sendDraft` or `startTurn`: an artifact comment reaches
the assistant only inside the owner's own chat message, sent by the chat
(`ChatViewModel.sendArtifactComments`) when the owner presses
**Send N comments**.
```

and add to its **Guard** list:

```markdown
`testArtifactCommentsReachTheAssistantOnlyAsTheOwnersMessage`
(`WatchtowerDesktop/Tests/ChatViewModelTests.swift`);
```

Append to `## Changelog`:

```markdown
- 2026-09-30: CHAT-05 extended to artifact comments (projects POC phase 6, migration 00082): the source scan covers the comment files and forbids send entry points on the artifact side; comments leave the machine only as the owner's own message. Strengthening only — no guard relaxed.
```

- [ ] **Step 12: Run — PASS**

```bash
make test-swift FILTER=ArtifactComment > /tmp/t24a.log 2>&1; echo "exit=$?"
make test-swift FILTER=CommentBatchComposerTests > /tmp/t24j.log 2>&1; echo "exit=$?"
make test-swift FILTER=ArtifactPanelModelTests > /tmp/t24b.log 2>&1; echo "exit=$?"
make test-swift FILTER=ArtifactChat05ScanTests > /tmp/t24c.log 2>&1; echo "exit=$?"
make test-swift FILTER=ChatViewModelTests > /tmp/t24d.log 2>&1; echo "exit=$?"
make test-swift FILTER=ArtifactCommentsSendBarTests > /tmp/t24h.log 2>&1; echo "exit=$?"
make test-swift FILTER=ArtifactContractFixtureTests > /tmp/t24i.log 2>&1; echo "exit=$?"
make lint-diff > /tmp/t24-lint.log 2>&1; echo "exit=$?"
```
Expected: every `exit=0`. Then a bounded mutation check, once, on the committed-to-be code: (1) drop `status = 'open' AND` from `markSent`'s WHERE → `testMarkSentTouchesOnlyTheIncludedOpenComments` and `testOnlyTheUnsentCommentsAreIncludedAndMarked` fail; (2) in `ArtifactCommentReanchor.plan` remove `where comment.status != .outdated` → `testAnOutdatedCommentIsNeverReattachedWhenItsTextComesBack` fails; (3) delete `try plan.alsoWrite?(db)` from `persistTurnStart` → `testArtifactCommentsReachTheAssistantOnlyAsTheOwnersMessage` fails (the comment stays `open`). Revert each (`git diff` clean for those files afterwards).

Manual smoke (`make app-dev`): ask the chat for a plan as a document artifact → Comments → select a sentence → Comment → yellow highlight + "Not sent yet"; add a second → **Send 2 comments** → the owner bubble shows the quoted comments; when the assistant answers with v2 the kept passages stay highlighted, a rewritten one moves to Outdated; Resolve clears it.

- [ ] **Step 13: Commit**

```bash
git add WatchtowerDesktop/Sources/WatchtowerCore/Models/ArtifactComment.swift \
        WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ArtifactCommentQueries.swift \
        WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ArtifactCommentText.swift \
        WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ArtifactCommentReanchor.swift \
        WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ArtifactCommentMessage.swift \
        WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/CommentBatchComposer.swift \
        WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ArtifactCommentsModel.swift \
        WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ArtifactPanelModel.swift \
        WatchtowerDesktop/Sources/Views/Chat/ArtifactCommentsView.swift \
        WatchtowerDesktop/Sources/Views/Chat/ArtifactPanelView.swift \
        WatchtowerDesktop/Sources/Views/Chat/ChatInspectorContent.swift \
        WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift \
        WatchtowerDesktop/Tests/Core/ArtifactCommentQueriesTests.swift \
        WatchtowerDesktop/Tests/Core/ArtifactCommentReanchorTests.swift \
        WatchtowerDesktop/Tests/Core/ArtifactCommentMessageTests.swift \
        WatchtowerDesktop/Tests/Core/CommentBatchComposerTests.swift \
        WatchtowerDesktop/Tests/Core/ArtifactCommentsModelTests.swift \
        WatchtowerDesktop/Tests/Core/ArtifactChat05ScanTests.swift \
        WatchtowerDesktop/Tests/ChatViewModelTests.swift \
        WatchtowerDesktop/Tests/ArtifactCommentsSendBarTests.swift \
        internal/chat/artifacts_contract.go internal/chat/artifacts_contract_test.go \
        internal/chat/testdata/system_prompt_main.golden docs/inventory/chat.md
git commit -m "$(cat <<'EOF'
feat(chat): comment on artifact passages and send the comments as one message

The artifact panel gains a Comments mode: select a passage, comment, collect
several, Send N comments. They go out as one ordinary owner message and turn
sent in the transaction that persists it; the assistant answers with a new
version of the same key and every comment re-anchors onto it (a lost passage
becomes outdated). The artifact side still never sends (CHAT-05, scan
extended).

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 25: Quote-reply on chat answers — a batch sent in one turn

**Depends on:** Task 24 (`CommentBatchComposer`); Phase 4 Tasks 15 and 16 with the Required Phase 4 edits (`phase4-generic-edits.md`).

**Choice (owner decisions 4 and "batches"):** a per-answer **Quote in reply** button (the row's hover action bar, next to Copy/Regenerate) opens the answer in a **sheet** hosting Phase 4's `DocumentTextView` — the only `NSTextView` the chat ever creates, and only while the owner is quoting. **Add to reply** puts the selected passage and an optional comment into a **pending quote batch** shown above the composer (removable, comment editable); quoting again adds to the same batch. Nothing is sent per quote: the owner's normal send (Enter / the send button) sends every quote plus the typed text as **one** owner turn, composed by `CommentBatchComposer` — the same rule as artifact comments. Rows keep `MarkdownView`; a 500-message thread costs one extra `Button` per finished assistant row and nothing else (closures stay out of `ChatMessageRow`'s equality, so render isolation is unchanged). Rejected: making `MarkdownView` selectable-with-range (it is SwiftUI `Text`, which exposes no selection range — it would need an `NSTextView` per row, the regression the owner ruled out) and an on-demand in-row `NSTextView` swap (it re-lays out the row inside the `LazyVStack` and fights the follow-scroll tracker). The sheet uses no TCC-sensitive API.

**Files:**
- Create (WatchtowerCore): `Services/Chat/ChatQuoteReply.swift` (`ChatQuoteDraft`, `quotableMarkdown`, `selectedText`, `compose(quotes:typed:)`)
- Create (app): `Views/Chat/QuoteReplySheet.swift`, `Views/Chat/QuoteBatchView.swift`
- Modify (app): `Views/Chat/ChatMessageRow.swift` (`ChatRowActions.quote` + button), `Views/Chat/ChatThreadView.swift` (sheet), `Views/Chat/ChatComposerView.swift` (batch above the input), `Views/Chat/ChatInput.swift` (`hasPendingContent`), `ViewModels/ChatViewModel.swift` (quote batch + `sendDraft`)
- Test: `WatchtowerDesktop/Tests/Core/ChatQuoteReplyTests.swift`, `Tests/Core/ChatQuoteReplyScanTests.swift`, `Tests/ChatMessageRowTests.swift` (two tests added), `Tests/ChatViewModelTests.swift` (four tests added), `Tests/ChatInputViewTests.swift` (one test added), `Tests/QuoteBatchViewTests.swift`

**Interfaces:**
- Consumes: Task 24 `CommentBatchComposer`; Phase 4 `DocumentRendering`, `DocumentTextView`, `DocumentAttributedString`; `ArtifactParser`.
- Produces (WatchtowerCore): `struct ChatQuoteDraft: Identifiable, Equatable, Sendable { id: UUID; quote: String; comment: String }`; `enum ChatQuoteReply { static let batchHeader; quotableMarkdown(_:) -> String; selectedText(_:selection:) -> String?; compose(quotes:typed:) -> String? }`.
- Produces (app): `QuoteReplySheet(messageText:onAdd:)`, `QuoteBatchView(quotes:onEditComment:onRemove:)`; `ChatRowActions.quote: (Int64, String) -> Void`; `ChatViewModel.quoteBatches: [Int64: [ChatQuoteDraft]]` (private(set)), `pendingQuotes`, `addQuote(_:comment:)`, `updateQuoteComment(id:comment:)`, `removeQuote(id:)`; `sendDraft()` now sends batch + typed text as one turn; `ChatInput(…, hasPendingContent:)` (defaulted `false`).

**Rules:**
- Only a finished (`complete`) assistant answer offers the button (the row shows its action bar only then).
- The quote is the selected span of the rendered text; the comment is optional and editable in the batch until sent.
- The batch is kept **per conversation** on `ChatViewModel` (which lives on `AppState`, so it survives navigation and switching chats); forgetting (deleting/archiving) a conversation drops its batch.
- `sendDraft()` composes the batch and the typed text into one message (quotes first, typed text last) and clears the batch **only when the turn actually started** — a refused or failed send keeps both, like the draft (CHAT-01 spirit). No other code path sends a quote.
- Nothing about a quote is stored until it is sent (the chat is the thread).

- [ ] **Step 0: Confirm names**

```bash
cd WatchtowerDesktop
grep -n "enum CommentBatchComposer" Sources/WatchtowerCore/Services/Chat/CommentBatchComposer.swift
grep -n "struct DocumentTextView\|enum DocumentAttributedString" Sources/Views/Comments/DocumentTextView.swift
grep -n "struct ChatRowActions" Sources/Views/Chat/ChatMessageRow.swift
grep -n "private var canSend" Sources/Views/Chat/ChatInput.swift
```
Every grep must print a line.

- [ ] **Step 1: Failing Core tests**

Create `WatchtowerDesktop/Tests/Core/ChatQuoteReplyTests.swift`:

```swift
import XCTest
@testable import WatchtowerCore

final class ChatQuoteReplyTests: XCTestCase {
    func testArtifactFencesBecomeOneBracketedLine() {
        let text = """
        Intro text.

        :::artifact key="plan" kind="document" title="Plan"
        Body of the plan.
        :::

        Outro.
        """
        XCTAssertEqual(ChatQuoteReply.quotableMarkdown(text), "Intro text.\n\n[Artifact: Plan]\n\nOutro.")
        XCTAssertEqual(ChatQuoteReply.quotableMarkdown(":::artifact key=\"k1\" kind=\"code\" title=\"\"\nx\n:::"),
                       "[Artifact: k1]")
    }

    func testSelectedTextIsTheRangeOrNilWhenEmpty() {
        let text = "Keep the retry budget small."
        XCTAssertEqual(ChatQuoteReply.selectedText(text, selection: (text as NSString).range(of: "retry budget")),
                       "retry budget")
        XCTAssertNil(ChatQuoteReply.selectedText(text, selection: NSRange(location: 4, length: 0)))
        XCTAssertNil(ChatQuoteReply.selectedText(text, selection: NSRange(location: 4, length: 1)), "a lone space")
        XCTAssertNil(ChatQuoteReply.selectedText(text, selection: NSRange(location: 20, length: 500)), "out of range")
    }

    func testTheBatchAndTheTypedTextBecomeOneMessage() {
        let quotes = [ChatQuoteDraft(quote: "retry budget", comment: "Why so small?"),
                      ChatQuoteDraft(quote: "Ship on Friday\nwith ops", comment: "")]
        XCTAssertEqual(ChatQuoteReply.compose(quotes: quotes, typed: "And staging? "), """
            About these parts of your answers:

            1. On this passage:
            > retry budget
            Why so small?

            2. On this passage:
            > Ship on Friday
            > with ops

            And staging?
            """)
    }

    func testNoQuotesIsTheTypedTextAndNothingIsNil() {
        XCTAssertEqual(ChatQuoteReply.compose(quotes: [], typed: " hi "), "hi")
        XCTAssertNil(ChatQuoteReply.compose(quotes: [], typed: "  "))
        XCTAssertEqual(ChatQuoteReply.compose(quotes: [ChatQuoteDraft(quote: "x", comment: "")], typed: ""),
                       "About these parts of your answers:\n\n1. On this passage:\n> x")
    }
}
```

Create `WatchtowerDesktop/Tests/Core/ChatQuoteReplyScanTests.swift`:

```swift
import XCTest

/// Chat performance + "comments go as one batch" for quote-reply (projects
/// POC phase 6): no thread row hosts a text view (only the quote sheet does,
/// while it is open), and neither the sheet nor the batch view can send — the
/// batch goes out only through the chat's own send.
final class ChatQuoteReplyScanTests: XCTestCase {
    private func source(_ path: String) throws -> String {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .appendingPathComponent("Sources")
        return try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
    }

    func testThreadRowsNeverHostATextView() throws {
        for file in ["Views/Chat/ChatMessageRow.swift", "Views/Chat/ChatThreadView.swift", "Views/Chat/MarkdownView.swift"] {
            let text = try source(file)
            for token in ["NSTextView", "DocumentTextView", "NSViewRepresentable"] {
                XCTAssertFalse(text.contains(token), "\(file) must not reference \(token): rows stay SwiftUI text")
            }
        }
    }

    func testTheQuoteSheetAndTheBatchViewNeverSend() throws {
        for file in ["Views/Chat/QuoteReplySheet.swift", "Views/Chat/QuoteBatchView.swift"] {
            let text = try source(file)
            for token in [".send(", "sendDraft", "startTurn", "ChatSessionPool", "Process(", "URLSession"] {
                XCTAssertFalse(text.contains(token), "\(file) must not reference \(token)")
            }
        }
    }
}
```

Run: `make test-swift FILTER=ChatQuoteReply > /tmp/t25a.log 2>&1; echo "exit=$?"` → `exit≠0` (`ChatQuoteReply` missing; the view files missing).

- [ ] **Step 2: Implement the Core helpers**

Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ChatQuoteReply.swift`:

```swift
import Foundation

/// One quoted passage of an assistant answer waiting in the composer's
/// batch, with the owner's (optional, editable) comment.
package struct ChatQuoteDraft: Identifiable, Equatable, Sendable {
    package let id: UUID
    package let quote: String
    package var comment: String

    package init(quote: String, comment: String, id: UUID = UUID()) {
        self.id = id
        self.quote = quote
        self.comment = comment
    }
}

/// "Quote in reply" for the main chat. Pure.
package enum ChatQuoteReply {
    package static let batchHeader = "About these parts of your answers:"

    /// An assistant answer's markdown without its artifact fences: each
    /// artifact becomes one bracketed line — the card the owner saw — so the
    /// quote sheet never shows raw `:::artifact` syntax.
    package static func quotableMarkdown(_ assistantText: String) -> String {
        ArtifactParser.parse(assistantText, final: true).segments
            .map { segment -> String in
                switch segment {
                case .markdown(let markdown):
                    markdown.trimmingCharacters(in: .whitespacesAndNewlines)
                case .artifact(let draft):
                    "[Artifact: \(draft.title.isEmpty ? draft.key : draft.title)]"
                }
            }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// The selected span of `text` (a UTF-16 `NSRange`, as `NSTextView`
    /// reports it); nil when nothing but whitespace is selected.
    package static func selectedText(_ text: String, selection: NSRange) -> String? {
        guard selection.length > 0, let range = Range(selection, in: text) else { return nil }
        let quote = String(text[range])
        return quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : quote
    }

    /// The one owner message for a send: every pending quote (in the order
    /// added), then the owner's typed text. nil = nothing to send.
    package static func compose(quotes: [ChatQuoteDraft], typed: String) -> String? {
        CommentBatchComposer.compose(
            header: batchHeader,
            items: quotes.map { CommentBatchComposer.Item(quote: $0.quote, heading: "", comment: $0.comment) },
            note: typed
        )
    }
}
```

Run: `make test-swift FILTER=ChatQuoteReplyTests > /tmp/t25a.log 2>&1; echo "exit=$?"` → `exit=0`. If `testArtifactFencesBecomeOneBracketedLine` shows a different markdown segmentation (e.g. the fence's trailing newline kept in the outro), fix the trimming in `quotableMarkdown`, not the expected string.

- [ ] **Step 3: Failing app tests**

Append to `WatchtowerDesktop/Tests/ChatMessageRowTests.swift` (inside the class):

```swift
    func testAFinishedAnswerOffersQuoteInReplyWithItsText() throws {
        var quoted: (Int64, String)?
        let base = try item(role: "assistant", status: "complete")
        let row = ChatMessageRow(item: base, isLast: true, isEditing: false,
                                 actions: ChatRowActions(quote: { quoted = ($0, $1) }))
        try row.inspect().find(ViewType.Button.self) { try $0.accessibilityLabel().string() == "Quote in reply" }.tap()
        XCTAssertEqual(quoted?.0, base.id)
        XCTAssertEqual(quoted?.1, "body")
    }

    func testOwnerMessagesHaveNoQuoteButton() throws {
        let row = ChatMessageRow(item: try item(role: "user", status: "complete"),
                                 isLast: true, isEditing: false, actions: ChatRowActions())
        XCTAssertThrowsError(try row.inspect().find(ViewType.Button.self) {
            try $0.accessibilityLabel().string() == "Quote in reply"
        })
    }
```

Append to `WatchtowerDesktop/Tests/ChatViewModelTests.swift` (inside the class):

```swift
    // MARK: - Quote batch

    private func userMessageCount() throws -> Int? {
        try dbManager.dbPool.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM chat_messages WHERE role = 'user'") }
    }

    /// Owner rule: comments go to the LLM as one batch — a quote never sends
    /// by itself, however many are added.
    func testQuotesAccumulateAndNothingIsSentPerQuote() throws {
        let vm = try makeViewModel()
        _ = try XCTUnwrap(vm.newConversation())
        vm.addQuote("retry budget", comment: "Why so small?")
        vm.addQuote("Ship on Friday", comment: "")
        vm.addQuote("   ", comment: "ignored")
        XCTAssertEqual(vm.pendingQuotes.map(\.quote), ["retry budget", "Ship on Friday"])
        XCTAssertTrue(try lastFake().turns.isEmpty)
        XCTAssertEqual(try userMessageCount(), 0, "a quote is stored nowhere until the owner sends")
        let second = try XCTUnwrap(vm.pendingQuotes.last?.id)
        vm.updateQuoteComment(id: second, comment: "Thursday?")
        vm.removeQuote(id: try XCTUnwrap(vm.pendingQuotes.first?.id))
        XCTAssertEqual(vm.pendingQuotes.map(\.comment), ["Thursday?"])
    }

    func testSendDraftSendsEveryQuoteAndTheTypedTextAsOneTurn() throws {
        let vm = try makeViewModel()
        _ = try XCTUnwrap(vm.newConversation())
        vm.addQuote("retry budget", comment: "Why so small?")
        vm.addQuote("Ship on Friday", comment: "")
        vm.draft = "And staging?"
        let expected = ChatQuoteReply.compose(quotes: vm.pendingQuotes, typed: "And staging?")

        vm.sendDraft()

        XCTAssertEqual(try lastFake().turns.count, 1)
        XCTAssertEqual(try lastStoredUserText(vm), expected)
        XCTAssertTrue(vm.pendingQuotes.isEmpty)
        XCTAssertEqual(vm.draft, "")
    }

    func testAFailedSendKeepsTheQuoteBatch() throws {
        let vm = try makeViewModel()
        _ = try XCTUnwrap(vm.newConversation())
        vm.addQuote("retry budget", comment: "Why so small?")
        try dbManager.dbPool.write { d in
            try d.execute(sql: """
                CREATE TRIGGER fail_user BEFORE INSERT ON chat_messages WHEN NEW.role = 'user'
                BEGIN SELECT RAISE(ABORT, 'boom'); END
                """)
        }
        vm.sendDraft()
        XCTAssertTrue(try lastFake().turns.isEmpty)
        XCTAssertEqual(vm.pendingQuotes.count, 1, "the owner's quotes survive a failed send")
    }

    func testQuoteBatchesAreKeptPerConversationAndDroppedWithIt() throws {
        let vm = try makeViewModel()
        let first = try XCTUnwrap(vm.newConversation())
        vm.addQuote("retry budget", comment: "")
        _ = try XCTUnwrap(vm.newConversation())
        XCTAssertTrue(vm.pendingQuotes.isEmpty)
        vm.select(conversationID: first)
        XCTAssertEqual(vm.pendingQuotes.map(\.quote), ["retry budget"])
        vm.forget(conversationID: first)
        XCTAssertNil(vm.quoteBatches[first])
    }
```

Append to `WatchtowerDesktop/Tests/ChatInputViewTests.swift` (inside the class):

```swift
    /// A pending quote batch is sendable content even with an empty field.
    func testPendingContentEnablesSendWithEmptyText() throws {
        var sent = 0
        var stored = ""
        let view = ChatInput(text: Binding(get: { stored }, set: { stored = $0 }), isStreaming: false,
                             onSend: { sent += 1 }, hasPendingContent: true)
        let button = try view.inspect().find(ViewType.Button.self)
        XCTAssertFalse(try button.isDisabled())
        try button.tap()
        XCTAssertEqual(sent, 1)
    }
```

Create `WatchtowerDesktop/Tests/QuoteBatchViewTests.swift`:

```swift
import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore

@MainActor
final class QuoteBatchViewTests: XCTestCase {
    func testShowsEveryQuoteAndRemoveReportsItsID() throws {
        let quotes = [ChatQuoteDraft(quote: "retry budget", comment: "Why?"), ChatQuoteDraft(quote: "Ship on Friday", comment: "")]
        var removed: [UUID] = []
        let view = QuoteBatchView(quotes: quotes, onEditComment: { _, _ in }, onRemove: { removed.append($0) })
        XCTAssertNoThrow(try view.inspect().find(text: "\u{201C}retry budget\u{201D}"))
        XCTAssertNoThrow(try view.inspect().find(text: "\u{201C}Ship on Friday\u{201D}"))
        let buttons = try view.inspect().findAll(ViewType.Button.self) { try $0.accessibilityLabel().string() == "Remove quote" }
        XCTAssertEqual(buttons.count, 2)
        try buttons[1].tap()
        XCTAssertEqual(removed, [quotes[1].id])
    }
}
```

Run: `make test-swift FILTER=ChatMessageRowTests > /tmp/t25b.log 2>&1; echo "exit=$?"` → `exit≠0` (`quote:` is not a `ChatRowActions` member).

- [ ] **Step 4: View model — the batch and the one-turn send**

In `WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift`:

1. Add a stored property next to `draft`:

```swift
    /// "Quote in reply" batches, per conversation: quotes wait here (with the
    /// owner's comments) and go out together with the typed text as ONE owner
    /// turn in `sendDraft` — never one by one (owner rule).
    private(set) var quoteBatches: [Int64: [ChatQuoteDraft]] = [:]
```

2. Replace `sendDraft()` with:

```swift
    /// Sends the composer text + the pending quote batch + any pending
    /// attachments as one owner turn; clears them only when the turn really
    /// started (a failed send keeps them for retry).
    func sendDraft() {
        let attachments = composerAttachments.pending
        let batchID = conversationID
        let text = ChatQuoteReply.compose(quotes: pendingQuotes, typed: draft) ?? draft
        if send(text: text, attachments: attachments, mentions: composer.mentions, skill: composer.skill) {
            draft = ""
            _ = composerAttachments.takeForSend()
            if let batchID { quoteBatches[batchID] = nil }
        }
    }
```

3. Add after `sendDraft()`:

```swift
    /// The current conversation's quote batch (empty on the landing).
    var pendingQuotes: [ChatQuoteDraft] {
        conversationID.flatMap { quoteBatches[$0] } ?? []
    }

    /// "Add to reply" in the quote sheet: one more quote in the batch.
    /// Nothing is sent or stored until the owner sends the draft.
    func addQuote(_ quote: String, comment: String) {
        guard let id = conversationID, !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        quoteBatches[id, default: []].append(ChatQuoteDraft(quote: quote, comment: comment))
    }

    func updateQuoteComment(id quoteID: UUID, comment: String) {
        guard let id = conversationID, let index = quoteBatches[id]?.firstIndex(where: { $0.id == quoteID }) else { return }
        quoteBatches[id]?[index].comment = comment
    }

    func removeQuote(id quoteID: UUID) {
        guard let id = conversationID else { return }
        quoteBatches[id]?.removeAll { $0.id == quoteID }
        if quoteBatches[id]?.isEmpty == true { quoteBatches[id] = nil }
    }
```

4. In `forget(conversationID id:)`, add as its first line:

```swift
        quoteBatches[id] = nil
```

- [ ] **Step 5: Row action, sheet, batch view, composer**

In `WatchtowerDesktop/Sources/Views/Chat/ChatMessageRow.swift`:

1. `ChatRowActions` gains, after `openSources`:

```swift
    var quote: (Int64, String) -> Void = { _, _ in }
```

2. In `actionBar`, the `else if item.message.isAssistant {` branch becomes:

```swift
            } else if item.message.isAssistant {
                Button { actions.quote(item.id, item.message.text) } label: { Image(systemName: "text.quote") }
                    .help("Quote in reply")
                    .accessibilityLabel("Quote in reply")
                Button { actions.regenerate(item.id) } label: { Image(systemName: "arrow.clockwise") }
                    .help("Regenerate")
                    .accessibilityLabel("Regenerate")
            }
```

Create `WatchtowerDesktop/Sources/Views/Chat/QuoteReplySheet.swift`:

```swift
import AppKit
import SwiftUI
import WatchtowerCore

/// "Quote in reply" on an assistant answer: the answer as selectable text in
/// a sheet — the chat's only text view, alive only while the owner quotes;
/// thread rows keep rendering with `MarkdownView`. "Add to reply" hands the
/// selection and the owner's comment to the pending batch; nothing is sent
/// or stored here.
struct QuoteReplySheet: View {
    let onAdd: (_ quote: String, _ comment: String) -> Void
    private let rendered: RenderedDocument
    /// Built once: `DocumentTextView` re-applies its text only when the
    /// instance changes, so a stable one keeps the owner's selection.
    private let attributed: NSAttributedString
    @Environment(\.dismiss) private var dismiss
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var comment = ""

    init(messageText: String, onAdd: @escaping (_ quote: String, _ comment: String) -> Void) {
        let rendered = DocumentRendering.render(ChatQuoteReply.quotableMarkdown(messageText))
        self.rendered = rendered
        attributed = DocumentAttributedString.make(rendered, highlights: [:], activeThreadID: nil)
        self.onAdd = onAdd
    }

    private var quote: String? { ChatQuoteReply.selectedText(rendered.text, selection: selection) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Select the part to quote").font(.headline)
            DocumentTextView(text: attributed, selection: $selection, onClick: { _ in })
                .frame(minHeight: 240)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            if let quote {
                Text("\u{201C}\(quote)\u{201D}")
                    .font(.caption).italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            TextField("Your comment on the quote (optional)", text: $comment, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
            Text("Quotes collect above the message box and go out together when you send.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add to reply") {
                    guard let quote else { return }
                    onAdd(quote, comment)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(quote == nil)
            }
        }
        .padding(16)
        .frame(width: 600, height: 500)
    }
}
```

Create `WatchtowerDesktop/Sources/Views/Chat/QuoteBatchView.swift`:

```swift
import SwiftUI
import WatchtowerCore

/// The pending quote batch above the composer: each quote with its editable
/// comment and a remove button. It never sends — the composer's send takes
/// the whole batch as one message.
struct QuoteBatchView: View {
    let quotes: [ChatQuoteDraft]
    let onEditComment: (UUID, String) -> Void
    let onRemove: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(quotes) { quote in
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\u{201C}\(quote.quote)\u{201D}")
                            .font(.caption).italic()
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        TextField("Comment (optional)", text: Binding(
                            get: { quote.comment },
                            set: { onEditComment(quote.id, $0) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.callout)
                    }
                    Button { onRemove(quote.id) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .help("Remove quote")
                        .accessibilityLabel("Remove quote")
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 16)
    }
}
```

In `WatchtowerDesktop/Sources/Views/Chat/ChatInput.swift`:

1. `ChatInput` gains, after `onPickerKey`:

```swift
    /// Content outside the text field that is also sent (the main chat's
    /// quote batch): enables Send with an empty field. Defaults to none, so
    /// every other call site is unchanged.
    var hasPendingContent = false
```

2. `ChatInput.body` passes `hasPendingContent: hasPendingContent` as the last argument of `ChatInputContent(…)`; `ChatInputContent` gains the same `var hasPendingContent = false` after its `onPickerKey`.

3. `ChatInputContent.canSend` becomes:

```swift
    /// A message may carry only attachments, or only pending quotes (no text).
    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty || hasPendingContent
    }
```

In `WatchtowerDesktop/Sources/Views/Chat/ChatComposerView.swift`, in `composer`'s `VStack`, insert before `ComposerChipsRow(`:

```swift
            if !chatVM.pendingQuotes.isEmpty {
                QuoteBatchView(
                    quotes: chatVM.pendingQuotes,
                    onEditComment: { chatVM.updateQuoteComment(id: $0, comment: $1) },
                    onRemove: { chatVM.removeQuote(id: $0) }
                )
            }
```

and add `hasPendingContent: !chatVM.pendingQuotes.isEmpty` as the last argument of `ChatInput(…)` (after `onPickerKey:`).

In `WatchtowerDesktop/Sources/Views/Chat/ChatThreadView.swift`:

1. Add next to the other `@State` properties:

```swift
    /// The answer being quoted ("Quote in reply"); nil = no sheet.
    @State private var quoting: QuoteTarget?
```

and at file scope (above `struct ChatThreadView`):

```swift
/// One assistant answer handed to `QuoteReplySheet`.
private struct QuoteTarget: Identifiable {
    let id: Int64
    let text: String
}
```

2. In `body`, attach to the outer `ScrollViewReader { … }` (after its closing brace):

```swift
        .sheet(item: $quoting) { target in
            QuoteReplySheet(messageText: target.text) { chatVM.addQuote($0, comment: $1) }
        }
```

3. In `actions`, add as the last argument of `ChatRowActions(…)`:

```swift
            openSources: { chatVM.openSources(messageID: $0, sources: $1) },
            quote: { id, text in quoting = QuoteTarget(id: id, text: text) }
```

- [ ] **Step 6: Run — PASS**

```bash
make test-swift FILTER=ChatQuoteReply > /tmp/t25a.log 2>&1; echo "exit=$?"
make test-swift FILTER=ChatMessageRowTests > /tmp/t25b.log 2>&1; echo "exit=$?"
make test-swift FILTER=ChatViewModelTests > /tmp/t25c.log 2>&1; echo "exit=$?"
make test-swift FILTER=ChatInputViewTests > /tmp/t25e.log 2>&1; echo "exit=$?"
make test-swift FILTER=QuoteBatchViewTests > /tmp/t25f.log 2>&1; echo "exit=$?"
make test-swift FILTER=ArtifactChat05ScanTests > /tmp/t25d.log 2>&1; echo "exit=$?"
make lint-diff > /tmp/t25-lint.log 2>&1; echo "exit=$?"
```
Expected: every `exit=0` (`ChatQuoteReply` matches both `ChatQuoteReplyTests` and `ChatQuoteReplyScanTests`; the CHAT-05 scan still passes with the new `quote` closure in `ChatMessageRow.swift`; the CHAT-01 tests in `ChatViewModelTests` pass with the new `sendDraft`). `testRowEqualityIgnoresClosures` passing unchanged is the render-isolation proof. Bounded mutation check, once: make `addQuote` also call `sendDraft()` → `testQuotesAccumulateAndNothingIsSentPerQuote` fails; clear the batch before `send` instead of after it succeeds → `testAFailedSendKeepsTheQuoteBatch` fails. Revert both.

Manual smoke (`make app-dev`): scroll a long conversation (hundreds of messages) — no change in smoothness; hover a finished answer → Quote in reply → select a sentence → comment → Add to reply → the quote appears above the composer; quote a second passage; edit a comment, remove one; type a line and press Enter → ONE owner bubble with the numbered quotes and the typed line last; the batch is gone.

- [ ] **Step 7: Commit**

```bash
git add WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ChatQuoteReply.swift \
        WatchtowerDesktop/Sources/Views/Chat/QuoteReplySheet.swift \
        WatchtowerDesktop/Sources/Views/Chat/QuoteBatchView.swift \
        WatchtowerDesktop/Sources/Views/Chat/ChatMessageRow.swift \
        WatchtowerDesktop/Sources/Views/Chat/ChatThreadView.swift \
        WatchtowerDesktop/Sources/Views/Chat/ChatComposerView.swift \
        WatchtowerDesktop/Sources/Views/Chat/ChatInput.swift \
        WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift \
        WatchtowerDesktop/Tests/Core/ChatQuoteReplyTests.swift \
        WatchtowerDesktop/Tests/Core/ChatQuoteReplyScanTests.swift \
        WatchtowerDesktop/Tests/ChatMessageRowTests.swift \
        WatchtowerDesktop/Tests/ChatViewModelTests.swift \
        WatchtowerDesktop/Tests/ChatInputViewTests.swift \
        WatchtowerDesktop/Tests/QuoteBatchViewTests.swift
git commit -m "$(cat <<'EOF'
feat(chat): quote parts of answers and send the quotes as one batch

A finished assistant answer gets Quote in reply: the answer opens as
selectable text in a sheet, and Add to reply puts the selection and an
optional comment into a batch above the composer. The owner's send takes
every quote and the typed text as one owner turn; a quote never sends by
itself. Rows keep rendering as SwiftUI text.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 26: Project documents — "Send N comments to Claude"

**Depends on:** Phase 4 Tasks 16 and 17 (documents pane, `ProjectTerminalCenter`); Task 24 (`CommentBatchComposer.sendButtonTitle`).

**Choice (owner "batches", surface c):** a document with open owner comments gets **Send N comments to Claude**. When the project's embedded Claude Code session is running (`ProjectTerminalCenter` state `.running`), it types **one** prompt line into that terminal and presses Enter — `Address the N open comments on <rel_path> (watchtower document <id>) using the watchtower-project skill.` — which makes Claude Code read all of them through its own `list_comments` tool. It writes nothing to the DB and never starts a session. With no running session the bar explains that the next Claude Code session gets the comments in its brief (`project brief` lists owner comments new for the agent, Phase 1 Task 5) and offers **Open terminal**. The comments themselves never travel in the prompt line: only a path and an id, so the batch is whatever is open when Claude reads it.

**SwiftTerm input API (verified on the pinned 1.20.0 source):** `TerminalView.send(data: ArraySlice<UInt8>)` (`Sources/SwiftTerm/Apple/AppleTerminalView.swift`) is public, must run on the main thread, and routes through `LocalProcessTerminalView.send(source:data:)` → `process.send(data:)` — the same path as a keystroke. There is no `send(txt:)` on the macOS view. Enter in Claude Code's raw-mode TUI is a carriage return (`0x0D`), not `\n`.

**Files:**
- Create (WatchtowerCore): `Services/ProjectCommentPrompt.swift`
- Modify (app): `Services/ProjectTerminalCenter.swift` (`ProjectTerminalSession.sendInput`, `SwiftTermSession.sendInput`, `ProjectTerminalCenter.PromptDelivery` + `sendPrompt(_:projectID:)`)
- Create (app): `Views/Projects/ProjectCommentsSendBar.swift`
- Modify (app): `Views/Projects/ProjectDocumentsView.swift` (the bar under the document)
- Test: `WatchtowerDesktop/Tests/Core/ProjectCommentPromptTests.swift`, `Tests/ProjectTerminalCenterTests.swift` (`FakeTerminalSession.inputs` + three tests), `Tests/ProjectCommentsSendBarTests.swift`

**Interfaces:**
- Consumes: Phase 4 `ProjectCommentThread`, `ProjectDocument`, `ProjectDocumentViewModel.openThreads`, `ProjectsViewModel.pane`/`selectedProject`, `ProjectTerminalCenter` (`states`, `start(project:firstRun:)`), `AppState.projectTerminalCenter`; Task 24 `CommentBatchComposer.sendButtonTitle`.
- Produces (WatchtowerCore): `enum ProjectCommentPrompt { static func openOwnerCount(_: [ProjectCommentThread]) -> Int; static func line(relPath:documentID:count:) -> String; static func terminalInput(_:) -> [UInt8] }`.
- Produces (app): `ProjectTerminalSession.sendInput(_ bytes: [UInt8])` (protocol requirement — the Phase 4 `FakeTerminalSession` gains it too); `ProjectTerminalCenter.PromptDelivery { sent, noSession }`, `sendPrompt(_ line: String, projectID: Int64) -> PromptDelivery`; `ProjectCommentsSendBar(count:delivery:onSend:onOpenTerminal:)`.

**Rules:**
- One click = one line + one Enter, whatever the number of comments. Nothing is marked, stored or sent anywhere else.
- The line never carries a control character: the rel path is untrusted (the agent attached it), so every control/newline scalar in it becomes a space and `terminalInput` strips any that remain before appending the single `0x0D` — a crafted path can neither submit early nor inject an escape sequence.
- Only a `.running` session receives input; `.exited`, `.unavailable` and no session at all answer `.noSession` and start nothing.
- The count is open **owner** roots (the agent's own threads are not "comments to send").

- [ ] **Step 0: Confirm names**

```bash
cd WatchtowerDesktop
grep -n "protocol ProjectTerminalSession" -A 8 Sources/Services/ProjectTerminalCenter.swift
grep -n "final class FakeTerminalSession" Tests/ProjectTerminalCenterTests.swift
grep -n "var openThreads" Sources/ViewModels/ProjectDocumentViewModel.swift
grep -n "private func documentView" Sources/Views/Projects/ProjectDocumentsView.swift
```
Every grep must print a line.

- [ ] **Step 1: Failing Core tests**

Create `WatchtowerDesktop/Tests/Core/ProjectCommentPromptTests.swift`:

```swift
import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class ProjectCommentPromptTests: XCTestCase {
    func testTheLineNamesTheDocumentTheCountAndTheSkill() {
        XCTAssertEqual(ProjectCommentPrompt.line(relPath: "docs/plan.md", documentID: 7, count: 3),
                       "Address the 3 open comments on docs/plan.md (watchtower document 7) using the watchtower-project skill.")
        XCTAssertEqual(ProjectCommentPrompt.line(relPath: "docs/plan.md", documentID: 7, count: 1),
                       "Address the open comment on docs/plan.md (watchtower document 7) using the watchtower-project skill.")
    }

    func testControlCharactersInThePathCannotSubmitOrInject() {
        let line = ProjectCommentPrompt.line(relPath: "docs/a\nrm -rf x\r\u{1B}[2J\u{2028}.md", documentID: 1, count: 2)
        XCTAssertFalse(line.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) })
        XCTAssertTrue(line.contains("docs/a rm -rf x  [2J .md"))
    }

    func testTerminalInputIsTheLineThenExactlyOneEnter() {
        let bytes = ProjectCommentPrompt.terminalInput("Address x\n\u{1B}y")
        XCTAssertEqual(bytes.last, 0x0D)
        XCTAssertEqual(bytes.filter { $0 < 0x20 || $0 == 0x7F }, [0x0D], "no other control byte reaches the terminal")
        XCTAssertEqual(String(bytes: bytes.dropLast(), encoding: .utf8), "Address xy")
    }

    func testOpenOwnerCountIgnoresResolvedAndAgentThreads() throws {
        let queue = try TestDatabase.create()
        try queue.write { d in
            let p = try TestDatabase.insertProject(d)
            let doc = try TestDatabase.insertProjectDocument(d, projectID: p)
            _ = try TestDatabase.insertProjectComment(d, projectID: p, author: "owner", body: "a", documentID: doc, quote: "q1")
            _ = try TestDatabase.insertProjectComment(d, projectID: p, author: "owner", body: "b", documentID: doc, quote: "q2")
            _ = try TestDatabase.insertProjectComment(d, projectID: p, author: "owner", body: "c", documentID: doc,
                                                      status: "resolved", quote: "q3")
            _ = try TestDatabase.insertProjectComment(d, projectID: p, author: "agent", body: "d", documentID: doc, quote: "q4")
            let threads = ProjectCommentThread.group(try ProjectQueries.comments(d, documentID: doc))
            XCTAssertEqual(ProjectCommentPrompt.openOwnerCount(threads), 2)
        }
    }
}
```

Run: `make test-swift FILTER=ProjectCommentPromptTests > /tmp/t26a.log 2>&1; echo "exit=$?"` → `exit≠0` (`ProjectCommentPrompt` not found).

- [ ] **Step 2: Implement `ProjectCommentPrompt`**

Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/ProjectCommentPrompt.swift`:

```swift
import Foundation

/// "Send N comments to Claude" on a project document: ONE prompt line typed
/// into the project's Claude Code session. The line carries only the
/// document's path and id — Claude reads the open comments themselves through
/// its `list_comments` tool — so the whole batch goes at once. Pure.
package enum ProjectCommentPrompt {
    /// Open owner threads on a document — what the button counts.
    package static func openOwnerCount(_ threads: [ProjectCommentThread]) -> Int {
        threads.filter { $0.root.isOpen && !$0.root.isAgent }.count
    }

    /// The rel path is agent-supplied, so every control or newline scalar in
    /// it becomes a space: the line can never submit early or carry an escape.
    package static func line(relPath: String, documentID: Int64, count: Int) -> String {
        let path = String(relPath.unicodeScalars.map { scalar -> Character in
            isControl(scalar) ? " " : Character(scalar)
        })
        let what = count == 1 ? "the open comment" : "the \(count) open comments"
        return "Address \(what) on \(path) (watchtower document \(documentID)) using the watchtower-project skill."
    }

    /// Bytes for the terminal: the line with any control scalar dropped, then
    /// one carriage return — Enter in Claude Code's raw-mode prompt.
    package static func terminalInput(_ line: String) -> [UInt8] {
        var clean = String.UnicodeScalarView()
        clean.append(contentsOf: line.unicodeScalars.filter { !isControl($0) })
        return Array(String(clean).utf8) + [0x0D]
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
    }
}
```

Run: `make test-swift FILTER=ProjectCommentPromptTests > /tmp/t26a.log 2>&1; echo "exit=$?"` → `exit=0`.

- [ ] **Step 3: Failing center + bar tests**

In `WatchtowerDesktop/Tests/ProjectTerminalCenterTests.swift`, `FakeTerminalSession` gains (next to `launches`):

```swift
    private(set) var inputs: [[UInt8]] = []
    func sendInput(_ bytes: [UInt8]) { inputs.append(bytes) }
```

and `ProjectTerminalCenterTests` gains:

```swift
    // MARK: - Send comments (Task 26)

    func testARunningSessionGetsOneLineAndOneEnter() throws {
        let center = makeCenter()
        let p = try project()
        center.start(project: p)
        let line = ProjectCommentPrompt.line(relPath: "docs/plan.md", documentID: 7, count: 3)
        XCTAssertEqual(center.sendPrompt(line, projectID: p.id), .sent)
        XCTAssertEqual(sessions[0].inputs, [ProjectCommentPrompt.terminalInput(line)])
    }

    func testAnExitedSessionReceivesNothing() throws {
        let center = makeCenter()
        let p = try project()
        center.start(project: p)
        sessions[0].exit(0)
        XCTAssertEqual(center.sendPrompt("x", projectID: p.id), .noSession)
        XCTAssertTrue(sessions[0].inputs.isEmpty)
    }

    func testNoSessionStartsNothing() throws {
        let center = makeCenter()
        let p = try project()
        XCTAssertEqual(center.sendPrompt("x", projectID: p.id), .noSession)
        XCTAssertTrue(sessions.isEmpty, "sending never starts a session")
        XCTAssertNil(center.states[p.id])
    }
```

Create `WatchtowerDesktop/Tests/ProjectCommentsSendBarTests.swift`:

```swift
import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop

@MainActor
final class ProjectCommentsSendBarTests: XCTestCase {
    func testSendTapsOnce() throws {
        var sent = 0
        let bar = ProjectCommentsSendBar(count: 2, delivery: nil, onSend: { sent += 1 }, onOpenTerminal: {})
        try bar.inspect().find(button: "Send 2 comments to Claude").tap()
        XCTAssertEqual(sent, 1)
    }

    func testNoSessionExplainsTheBriefAndOffersTheTerminal() throws {
        var opened = 0
        let bar = ProjectCommentsSendBar(count: 1, delivery: .noSession, onSend: {}, onOpenTerminal: { opened += 1 })
        XCTAssertNoThrow(try bar.inspect().find(text: ProjectCommentsSendBar.noSessionNote))
        try bar.inspect().find(button: "Open terminal").tap()
        XCTAssertEqual(opened, 1)
    }

    func testNothingOpenHidesTheButton() throws {
        let bar = ProjectCommentsSendBar(count: 0, delivery: nil, onSend: {}, onOpenTerminal: {})
        XCTAssertThrowsError(try bar.inspect().find(ViewType.Button.self))
    }
}
```

Run: `make test-swift FILTER=ProjectTerminalCenterTests > /tmp/t26b.log 2>&1; echo "exit=$?"` → `exit≠0` (`sendPrompt` missing).

- [ ] **Step 4: Session input + center send path**

In `WatchtowerDesktop/Sources/Services/ProjectTerminalCenter.swift`:

1. `protocol ProjectTerminalSession` gains, after `detach()`:

```swift
    /// Writes bytes to the session as if typed (the owner's "Send N
    /// comments to Claude"). Main thread only.
    func sendInput(_ bytes: [UInt8])
```

2. `ProjectTerminalCenter` gains, after `session(for:)`:

```swift
    enum PromptDelivery: Equatable {
        case sent
        /// Nothing running: the next session gets it from `project brief`.
        case noSession
    }

    /// Types one prompt line + Enter into the project's running Claude Code
    /// session. Never starts a session, never writes anything else.
    func sendPrompt(_ line: String, projectID: Int64) -> PromptDelivery {
        guard states[projectID] == .running, let session = sessions[projectID] else { return .noSession }
        session.sendInput(ProjectCommentPrompt.terminalInput(line))
        return .sent
    }
```

3. `SwiftTermSession` gains, after `detach()`:

```swift
    /// SwiftTerm's own keystroke path (`TerminalView.send(data:)` →
    /// `LocalProcess.send`), on the main actor as it requires.
    func sendInput(_ bytes: [UInt8]) {
        terminal.send(data: bytes[...])
    }
```

- [ ] **Step 5: The bar and the documents pane**

Create `WatchtowerDesktop/Sources/Views/Projects/ProjectCommentsSendBar.swift`:

```swift
import SwiftUI
import WatchtowerCore

/// Under an open project document: "Send N comments to Claude" types one
/// prompt line into the project's running Claude Code session; with none
/// running it explains the brief and offers the terminal.
struct ProjectCommentsSendBar: View {
    static let noSessionNote =
        "No Claude Code session is running for this project. The next session you start gets these comments in its brief."

    let count: Int
    /// The last click's result; nil = not clicked yet.
    let delivery: ProjectTerminalCenter.PromptDelivery?
    let onSend: () -> Void
    let onOpenTerminal: () -> Void

    var body: some View {
        if count > 0 {
            HStack(spacing: 8) {
                switch delivery {
                case .sent:
                    Label("Sent to Claude Code", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
                case .noSession:
                    Text(Self.noSessionNote).font(.caption).foregroundStyle(.secondary)
                    Button("Open terminal", action: onOpenTerminal)
                case nil:
                    EmptyView()
                }
                Spacer()
                Button(CommentBatchComposer.sendButtonTitle(count: count) + " to Claude", action: onSend)
                    .help("Ask Claude Code to address every open comment on this document")
            }
            .padding(8)
        }
    }
}
```

In `WatchtowerDesktop/Sources/Views/Projects/ProjectDocumentsView.swift`:

1. Add `@Environment(AppState.self) private var appState` and `@State private var delivery: ProjectTerminalCenter.PromptDelivery?` to the struct's properties.

2. In `documentView(_:)`, right after the `if let error = docVM.errorMessage { … }` block (inside the `VStack`), add:

```swift
            Divider()
            ProjectCommentsSendBar(
                count: ProjectCommentPrompt.openOwnerCount(docVM.threads),
                delivery: delivery,
                onSend: { sendComments(docVM) },
                onOpenTerminal: openTerminal
            )
```

3. Add to the struct:

```swift
    private func sendComments(_ docVM: ProjectDocumentViewModel) {
        let line = ProjectCommentPrompt.line(
            relPath: docVM.document.relPath, documentID: docVM.document.id,
            count: ProjectCommentPrompt.openOwnerCount(docVM.threads)
        )
        delivery = appState.projectTerminalCenter.sendPrompt(line, projectID: docVM.project.id)
    }

    private func openTerminal() {
        if let project = vm.selectedProject { appState.projectTerminalCenter.start(project: project) }
        vm.pane = .terminal
        delivery = nil
    }
```

4. Reset `delivery` when another document opens: add `.onChange(of: vm.documentViewModel?.document.id) { _, _ in delivery = nil }` next to the existing `.onChange(of: vm.pendingDocumentID)`.

- [ ] **Step 6: Run — PASS**

```bash
make test-swift FILTER=ProjectCommentPromptTests > /tmp/t26a.log 2>&1; echo "exit=$?"
make test-swift FILTER=ProjectTerminalCenterTests > /tmp/t26b.log 2>&1; echo "exit=$?"
make test-swift FILTER=ProjectCommentsSendBarTests > /tmp/t26c.log 2>&1; echo "exit=$?"
make test-swift FILTER=ProjectDocumentViewModelTests > /tmp/t26d.log 2>&1; echo "exit=$?"
make lint-diff > /tmp/t26-lint.log 2>&1; echo "exit=$?"
```
Expected: every `exit=0`. Bounded mutation check, once: drop the `states[projectID] == .running` guard → `testAnExitedSessionReceivesNothing` fails; make `line` keep control scalars → `testControlCharactersInThePathCannotSubmitOrInject` fails. Revert both.

Manual smoke (`make app-dev`): a project with Claude Code running in the embedded terminal and a plan with two open comments → Send 2 comments to Claude → the prompt appears in the terminal once and Claude starts working (it calls `list_comments`); close the terminal → the button explains the brief and Open terminal switches to the Terminal pane with a fresh session whose brief lists the comments. Type a partial message in the terminal first and send: the line is appended to the owner's partial input (the known limit in the errata).

- [ ] **Step 7: Commit**

```bash
git add WatchtowerDesktop/Sources/WatchtowerCore/Services/ProjectCommentPrompt.swift \
        WatchtowerDesktop/Sources/Services/ProjectTerminalCenter.swift \
        WatchtowerDesktop/Sources/Views/Projects/ProjectCommentsSendBar.swift \
        WatchtowerDesktop/Sources/Views/Projects/ProjectDocumentsView.swift \
        WatchtowerDesktop/Tests/Core/ProjectCommentPromptTests.swift \
        WatchtowerDesktop/Tests/ProjectTerminalCenterTests.swift \
        WatchtowerDesktop/Tests/ProjectCommentsSendBarTests.swift
git commit -m "$(cat <<'EOF'
feat(projects): send a document's open comments to Claude in one prompt

A document with open owner comments gets Send N comments to Claude: when
the project's embedded Claude Code session is running it types one prompt
line naming the document into it; otherwise the bar explains that the next
session's brief carries them and offers the terminal. Nothing is stored or
marked.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
EOF
)"
```

---

## Phase gate (controller, once)

After Task 26: `bash scripts/dev-health.sh`; then
```bash
make test > /tmp/p6-go.log 2>&1; echo "exit=$?"
make test-swift > /tmp/p6-swift.log 2>&1; echo "exit=$?"
make lint-all > /tmp/p6-lint.log 2>&1; echo "exit=$?"
```
All `exit=0` (read the XCTest failures above the swift-testing summary). Then the manual smokes of Tasks 24–26 on a real build (`make app-dev`), including: a `table` artifact comment (raw CSV text), a comment on an artifact the owner then edits, Send while an answer streams (button disabled), a quote from an answer that contains an artifact card (shows `[Artifact: …]`), a three-quote batch sent with typed text (one bubble), and Send N comments to Claude with and without a running terminal.

## Interface errata

1. **Table shape refined from the suggested one.** `chat_artifact_comments` has **no `parent_id` and no `author`**: under decision 3 the assistant never writes a comment (it answers in the chat with a new version), so an `assistant` author value and reply threading would be schema nothing writes. It also has **no FK to `chat_artifacts`** — a comment follows the (conversation, key) across versions; `artifact_version` records where it was last found. `created_at`/`sent_at` are `REAL` epoch seconds (the chat-tables precedent), and two CHECKs pin "always anchored, always a body" and "sent ⇒ sent_at". `sent_at` survives a later resolve/outdated.
2. **"Send N comments" sends directly as the next turn; it does not fill the composer.** The `sent` transition has to be tied to a persisted owner message, atomically: `ChatViewModel.send` gains a defaulted `alsoWrite: ((Database) throws -> Void)?` executed inside `persistTurnStart`'s transaction (new messages only). Filling the composer would leave "sent" undecidable (the owner may edit or discard the draft). The owner's composer draft is untouched by a comment send; like the existing Continue (`send(text: "Continue")`), a comment send runs `composer.reset()`, which drops any @-mention/skill picks of an unsent draft — pre-existing behaviour of `send`, not changed here.
3. **Comments exist only on the latest stored version** (`ArtifactPanelModel.canComment`); comment mode falls back to the normal panel while a version streams, an older version is selected, or an edit is open. The owner's own edit is a new version and re-anchors like an assistant one.
4. **Non-`document` kinds anchor on raw `content`** (`ArtifactCommentText`): a table comments on its CSV text, not on the grid; an email on its body. The panel's normal rendering (grid, fields) is unchanged — comment mode shows the text form.
5. **No replies, no reopen on artifact comments.** `CommentThreadView` gets `onReply: nil`/`onReopen: nil`; `open` → Delete (never sent, leaves no trace), `sent`/`outdated` → Resolve. This relies on the optional-closure signature from the Phase 4 edits.
6. **One batch composer.** `CommentBatchComposer` (Task 24) owns the format — header, numbered items (`Under "<heading>":` / `On this passage:`, blockquoted quote, comment), closing, then the owner's own text — and `sendButtonTitle`; `ArtifactCommentMessage.compose` and `ChatQuoteReply.compose(quotes:typed:)` only supply header/closing. `ChatQuoteReply.swift` is created in Task 25.
7. **CHAT-05 guard strengthened, not relaxed:** `testChat05ArtifactSurfacesNeverWrite` keeps its name and every existing file/token, and adds the six comment files plus `.send(`/`sendDraft`/`startTurn`; `docs/inventory/chat.md` records it. `ChatInspectorContent.swift` stays in the scan — it calls `chatVM.sendArtifactComments()`, which none of the tokens match.
8. **Go change is one rule line** in `ArtifactsContract()` + `TestArtifactsContract_CommentsAreAnsweredWithANewVersion` + the regenerated `internal/chat/testdata/system_prompt_main.golden`. There is no Swift copy of the artifacts contract (confirmed: only Go's `artifacts_contract.go` carries `=== ARTIFACTS ===`), so no dual-path fixture changes.
9. **Task 22 (docs) must also cover:** a CLAUDE.md "Chat Redesign" sentence (migration `00082`, artifact Comments mode + Send N comments, Quote in reply) and a `docs/app-guide.md` entry for both. Task 24 already updates `docs/inventory/chat.md`.
10. **Phase 5 Task 19 call site** changes with the Phase 4 edit E3: `CommentThreadView(thread: thread.content, onReply: { … }, onResolve: thread.root.isOpen ? { … } : nil, onReopen: thread.root.isOpen ? nil : { … })` — same behaviour (open → Resolve, else Reopen). Its Step 0 grep for `thread:|onReply|onResolve|onReopen` must look in `Sources/Views/Comments/CommentThreadView.swift`.
11. **The chat quote batch replaces "insert into the composer".** Quotes are `ChatQuoteDraft`s in `ChatViewModel.quoteBatches[conversationID]` (in memory on the AppState-owned VM: survives navigation and chat switches, not an app restart — nothing is stored before send, owner decision 5). `sendDraft()` composes quotes first, typed text last; `ChatInput` gains `hasPendingContent` so a batch alone is sendable. The quote text in the sent message is plain chat text; the thread shows it in the owner bubble as written.
12. **Task 26 changes a Phase 4 protocol:** `ProjectTerminalSession` gains `sendInput(_:)`, so Phase 4's `FakeTerminalSession` gains `inputs`/`sendInput` in the same commit. SwiftTerm 1.20.0 has no `send(txt:)` on macOS; the code uses `TerminalView.send(data:)` (public, main thread) and a carriage return for Enter.
13. **Task 26 known limit:** the line is typed into whatever Claude Code's prompt holds — if the owner has half-typed a message there, the line is appended to it before Enter. Claude Code queues input while it is busy, so a send mid-answer runs after it. No DB write and no `read_at` change happen on send; the brief keeps listing the comments until Claude answers or resolves them.

## Required Phase 4 edits

> The binding copy of this section is `docs/superpowers/plans/2026-09-29-projects-poc/phase4-generic-edits.md` (same content plus the Phase 5 Task 19 note); it is repeated here for reading convenience.

Minimal and behaviour-preserving: after these, the Documents pane (and Task 19's board threads) behave exactly as Phase 4 specifies; only names/locations/signatures change so Phase 6 can reuse the pieces outside projects.

**Task 13 — no change.** `CommentAnchor`'s data shape already lives in `WatchtowerCore/Services/CommentAnchor.swift` with no project dependency; `ProjectCommentThread` stays the project's thread model (Task 16's edit adds a mapping from it).

**Task 15 — no change.** `CommentAnchor.make(text:range:headings:)`/`locate(in:)` and `DocumentRendering.render(_:)` → `RenderedDocument` already take plain text/markdown and know nothing about projects; Phase 6 calls them as specified (and builds `RenderedDocument(text:headings:runs:)` for non-markdown artifacts from inside WatchtowerCore, where the memberwise init is visible).

**Task 16 — five edits:**

- **E1. Move `DocumentTextView.swift` to `WatchtowerDesktop/Sources/Views/Comments/DocumentTextView.swift`** (was `Views/Projects/`). Content unchanged (`DocumentAttributedString` + `DocumentTextView(text:selection:onClick:)`), except the `DocumentAttributedString` doc comment's first line reads "Rendered text → `NSAttributedString`: …" (no "document" wording tied to projects).
- **E2. New Core value `CommentThreadContent`** — create `WatchtowerDesktop/Sources/WatchtowerCore/Models/CommentThreadContent.swift`:

```swift
import Foundation

/// What `CommentThreadView` shows, independent of where the comments live
/// (project documents/targets, chat artifacts): the quoted text, a status
/// line (nil for an open thread) and the comments in order.
package struct CommentThreadContent: Identifiable, Equatable, Sendable {
    package struct Entry: Identifiable, Equatable, Sendable {
        package let id: Int64
        package let author: String
        package let body: String

        package init(id: Int64, author: String, body: String) {
            self.id = id
            self.author = author
            self.body = body
        }
    }

    package let id: Int64
    package let quote: String
    package let statusNote: String?
    package let entries: [Entry]

    package init(id: Int64, quote: String, statusNote: String?, entries: [Entry]) {
        self.id = id
        self.quote = quote
        self.statusNote = statusNote
        self.entries = entries
    }
}
```

  and append to `WatchtowerDesktop/Sources/WatchtowerCore/Models/Project.swift`:

```swift
extension ProjectCommentThread {
    /// The thread as `CommentThreadView` shows it — the same labels the
    /// Phase 4 view derived itself ("You"/the agent's label/"Agent";
    /// "Resolved"/"Outdated — the quoted text changed").
    package var content: CommentThreadContent {
        let note: String? = switch root.status {
        case "open": nil
        case "resolved": "Resolved"
        default: "Outdated — the quoted text changed"
        }
        return CommentThreadContent(
            id: id,
            quote: root.anchorQuote,
            statusNote: note,
            entries: ([root] + replies).map { comment in
                let author = comment.isAgent ? (comment.agentLabel.isEmpty ? "Agent" : comment.agentLabel) : "You"
                return CommentThreadContent.Entry(id: comment.id, author: author, body: comment.body)
            }
        )
    }
}
```

  with a test `WatchtowerDesktop/Tests/Core/CommentThreadContentTests.swift`:

```swift
import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class CommentThreadContentTests: XCTestCase {
    func testProjectThreadMapsAuthorsQuoteAndStatus() throws {
        let queue = try TestDatabase.create()
        try queue.write { d in
            let p = try TestDatabase.insertProject(d)
            let doc = try TestDatabase.insertProjectDocument(d, projectID: p)
            let root = try TestDatabase.insertProjectComment(d, projectID: p, author: "owner", body: "Why?",
                                                             documentID: doc, quote: "retry")
            _ = try TestDatabase.insertProjectComment(d, projectID: p, author: "agent", body: "Because.",
                                                      documentID: doc, parentID: root)
            _ = try TestDatabase.insertProjectComment(d, projectID: p, author: "owner", body: "Old",
                                                      documentID: doc, status: "outdated", quote: "gone")
            let threads = ProjectCommentThread.group(try ProjectQueries.comments(d, documentID: doc))

            let open = threads[0].content
            XCTAssertEqual(open.id, root)
            XCTAssertEqual(open.quote, "retry")
            XCTAssertNil(open.statusNote)
            XCTAssertEqual(open.entries.map(\.author), ["You", "Agent"])
            XCTAssertEqual(open.entries.map(\.body), ["Why?", "Because."])
            XCTAssertEqual(threads[1].content.statusNote, "Outdated — the quoted text changed")
        }
    }
}
```

  Run: `make test-swift FILTER=CommentThreadContentTests > /tmp/p16e.log 2>&1; echo "exit=$?"` → `exit=0`.
- **E3. Move `CommentThreadView.swift` to `WatchtowerDesktop/Sources/Views/Comments/CommentThreadView.swift`** and replace its body with the generic version (optional closures: `nil` hides the control):

```swift
import SwiftUI
import WatchtowerCore

/// One comment thread: the quote, the comments, a status line, and the
/// actions its owner allows — a nil closure hides that control. Knows nothing
/// about where the comments live: project document/target threads (Tasks
/// 16/19) and chat artifact comments (Task 24) all pass a
/// `CommentThreadContent`.
struct CommentThreadView: View {
    let thread: CommentThreadContent
    var isActive = false
    var onReply: ((String) async -> Void)?
    var onResolve: (() async -> Void)?
    var onReopen: (() async -> Void)?
    var onDelete: (() async -> Void)?
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !thread.quote.isEmpty {
                Text("\u{201C}\(thread.quote)\u{201D}")
                    .font(.caption).italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            ForEach(thread.entries) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.author).font(.caption).fontWeight(.semibold)
                    Text(entry.body).font(.callout).textSelection(.enabled)
                }
            }
            if let note = thread.statusNote {
                Text(note).font(.caption2).foregroundStyle(.secondary)
            }
            if onReply != nil {
                TextField("Reply", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
            }
            HStack {
                if let onReply {
                    Button("Reply") {
                        let text = draft
                        draft = ""
                        Task { await onReply(text) }
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Spacer()
                if let onDelete { Button("Delete", role: .destructive) { Task { await onDelete() } } }
                if let onResolve { Button("Resolve") { Task { await onResolve() } } }
                if let onReopen { Button("Reopen") { Task { await onReopen() } } }
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.yellow.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
        )
    }
}
```

- **E4. `ProjectDocumentsView.thread(_:_:)` call site** becomes (same behaviour: an open thread offers Resolve, any other offers Reopen; replies always):

```swift
    private func thread(_ thread: ProjectCommentThread, _ docVM: ProjectDocumentViewModel) -> some View {
        CommentThreadView(
            thread: thread.content,
            isActive: thread.id == activeThreadID,
            onReply: { await docVM.reply(to: thread.id, body: $0) },
            onResolve: thread.root.isOpen ? { await docVM.resolve(thread.id) } : nil,
            onReopen: thread.root.isOpen ? nil : { await docVM.reopen(thread.id) }
        )
        .onTapGesture { activeThreadID = thread.id }
    }
```

- **E5. Task 16's Files / Interfaces / commit list** follow the moves: `Views/Comments/DocumentTextView.swift` and `Views/Comments/CommentThreadView.swift` (instead of `Views/Projects/…`), plus `WatchtowerCore/Models/CommentThreadContent.swift`, the `Project.swift` extension and `Tests/Core/CommentThreadContentTests.swift` (add them to Step 11's `git add`; run `make test-swift FILTER=CommentThreadContentTests` in Step 10). The Interfaces line reads `CommentThreadView(thread: CommentThreadContent, isActive:onReply:onResolve:onReopen:onDelete:)` (closures optional) — "reused by Task 19 for target threads and by Task 24 for artifact comments".
