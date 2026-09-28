# Chat Redesign — Phase 1 Core (Swift), Tasks 10–16

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Swift half of the chat core — goose-owned chat tables read/written through a branch-aware query layer, a warm-session pool that owns every running turn (so turns survive navigation), a swift-markdown renderer shared by every chat, visible tool steps and source chips, and the new main-chat UI.

**Architecture:** Pure logic (models, tree, policy, event parser, markdown AST, highlighter, catalogs) lives in `WatchtowerCore` with tests in `Tests/Core`. The app target holds the process-owning pieces (`ChatSessionClient`, `ChatSessionPool`), the rewritten `ChatViewModel`, and views. **Persistence of a running turn belongs to the session client (via `ChatTurnDriver`), not to the view model** — that is what makes "start → navigate away → return" and CHAT-01 hold. **Render isolation:** the streaming message is a separate `@Observable LiveTurn`; the thread array is not mutated per delta, and finished rows are `Equatable` views.

**Tech Stack:** SwiftUI macOS 14, Swift 5.10 language mode, GRDB 7, `swiftlang/swift-markdown` (product `Markdown`), XCTest + ViewInspector.

**Spec:** `docs/superpowers/specs/2026-09-26-chat-redesign-design.md`. Skeleton with binding interfaces: `docs/superpowers/plans/2026-09-26-chat-redesign.md`. Read both, plus `docs/review/review-rules.md` → "Swift / Desktop conventions".

## Global Constraints

All of the skeleton's Global Constraints apply. The ones this file touches:
- Swift inner loop: `make test-swift FILTER=<TestClass>`; never delete `WatchtowerDesktop/.build`. Gate: `make test-swift`, `make lint-swift`.
- Protocol v2 events exactly: `session_ready`, `turn_start`, `text_delta`, `tool_start`, `tool_end`, `usage`, `turn_done`, `error`. Commands: `turn`, `cancel`, `close`. No `reset`.
- Error codes exactly: `auth`, `rate_limit`, `provider_unavailable`, `session_lost`, `attachment_unsupported`, `interrupted`, `internal`.
- Pool: max 3 live sessions, idle TTL 10 min, poll 30 s; quit: `close`, then SIGTERM after 2 s.
- System prompt, user text and attachment paths never on argv (CHAT-04) — Swift passes only flags; text/paths travel in the stdin `turn` command.
- Guard tests: Swift `testChat0N…`.
- No model names hardcoded in Swift (tests use neutral strings like `"model-b"`). No TCC-prompting APIs.
- SwiftLint runs `--strict`: `implicit_return`, `discouraged_optional_boolean` (no `Bool?`), `enum_case_associated_values_count` (≤ 4), `function_parameter_count` (≤ 8), `cyclomatic_complexity` (≤ 15), `function_body_length` (≤ 80). The code below is written to those limits — keep it that way.
- Every commit message ends with the line `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

## Review Focus (owned here)

1. **Legacy conversation continues with `--resume`** (skeleton RF #1) → Task 14 `testContinuingLegacyConversationResumesItsSession`.
2. **Partial text on stop / process death / quit** (RF #2) → Task 11 `testChat03CloseAllClosesEverySessionAndKeepsPartialText`, Task 14 `testChat01…` trio.
3. **Navigate away while streaming** (RF #3) → Task 14 `testTurnKeepsPersistingAfterViewModelIsReleased`, `testSwitchingConversationMidTurnAndBackShowsTheLiveTurn`.
4. **Render isolation on long threads** (RF #5) → Task 14 `testDeltasDoNotInvalidateTheThread`, Task 15 `ChatMessageRow` `Equatable` test.
5. **Unterminated code fence while streaming** renders as code → Task 12 `testUnterminatedFenceIsCode`.

## Cross-phase alignment (read before starting)

Other phase files already reference these names — keep them exactly:
- `ChatSessionConfig` lives in the app file `Sources/Services/Chat/ChatSessionClient.swift`, has a memberwise-style `init(conversationID:provider:model:…)` with defaults, and its argv builder is `static func ChatSessionClient.arguments(for:dbPath:) -> [String]`. **Phase 4 (Task 24) adds `projectID` itself** — do not add it here.
- `ChatToolCatalog.label(name: String, args: String) -> String` takes the raw `args` JSON string; Phase 2 prepends an `actionLabel(name:args:)` check as the first statement, so `label` must stay a multi-statement function.
- `ChatViewModel`: `draft` (composer text), `currentConversation`, `send(text:attachments:mentions:)`, `edit(messageID:newText:)`, `select(conversationID:)`, `newConversation(projectID:)`, `reloadConversations()`, `errorMessage`. Tests live in `Tests/ChatViewModelTests.swift` with a throwing `makeViewModel()` fixture; the pool exposes `lastConfig`.
- The main-chat composer instantiates `ChatInput(...)` (extended with defaulted parameters), and `ChatSidebarView` takes `chatVM` and has a `projectsSection` slot.
- Swift row model for `chat_messages` is **`ChatMessageRecord`** (the skeleton's `[ChatMessage]` in `ChatTreeQueries` signatures): `ChatMessage` is already the app-side UI struct used by eight Discuss/setup view models, so the persisted row keeps its existing name and moves into Core.

---

### Task 10: Swift DB layer — goose-owned chat tables, branch tree, steps, search, history grouping

**Files:**
- Modify: `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (append chat DDL)
- Create: `WatchtowerDesktop/Tests/Support/TestDatabase+Chat.swift`
- Move: `WatchtowerDesktop/Sources/Models/ChatMessageRecord.swift` → `WatchtowerDesktop/Sources/WatchtowerCore/Models/ChatModels.swift` (rewritten)
- Create: `WatchtowerDesktop/Sources/Models/ChatMessageRecord+UI.swift`
- Move: `WatchtowerDesktop/Sources/Database/Queries/ChatMessageQueries.swift` → `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ChatMessageQueries.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Models/ChatConversation.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ChatConversationQueries.swift`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ChatTree.swift`, `ChatTreeQueries.swift`, `ChatStepQueries.swift`, `ChatSearchQueries.swift`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ChatHistoryGrouping.swift`
- Modify: `WatchtowerDesktop/Sources/Database/DatabaseManager.swift:26-46`
- Modify (delete `ensure*` call lines): every test file listed in Step 9
- Delete: `WatchtowerDesktop/Tests/ChatMessageTurnIDTests.swift`
- Test: `WatchtowerDesktop/Tests/Core/ChatTreeTests.swift`, `ChatTreeQueriesTests.swift`, `ChatStepQueriesTests.swift`, `ChatSearchQueriesTests.swift`, `ChatHistoryGroupingTests.swift`, `ChatConversationQueriesTests.swift`; `WatchtowerDesktop/Tests/DatabaseManagerChatFloorTests.swift`

**Interfaces:**
- Consumes: Task 1 schema (migration 00074; `internal/db/schema.sql` chat DDL).
- Produces (all `package`, WatchtowerCore):
  - Models: `ChatMessageRecord{id, conversationID, parentID: Int64?, role, text, createdAt: Double, turnID, status, provider: String?, model: String?, tokensIn: Int?, tokensOut: Int?, errorCode: String?; createdDate, isUser, isAssistant}`; `ChatConversation` + `pinned: Bool, archivedAt: Double?, titleSource: String, provider: String?, model: String?, projectID: Int64?, activeLeafMessageID: Int64?`; `ChatTurnStep` (row) with `state: StepState`, `sources: [ChatSource]`, `display: ChatStepDisplay`; `enum StepState {running, succeeded, failed}`; `ChatStepDisplay{id: String, name, argsJSON, state, summary, sources, startedAt: Date, endedAt: Date?}`; `ChatSource{kind, title, url: String?, ref; dedupeKey; static dedupe(_:), decodeList(_:), encodeList(_:)}`; `ChatThreadItem{message, steps, siblingIndex, siblingCount; id; stepDisplays; sources}`.
  - `ChatTree(nodes:)`: `path(toLeaf:) -> [Int64]`, `siblings(of:) -> [Int64]`, `newestLeaf(under:) -> Int64`.
  - `ChatTreeQueries`: `activePath(_:conversationID:) -> [ChatMessageRecord]`, `thread(_:conversationID:) -> [ChatThreadItem]`, `siblings(_:messageID:) -> [ChatMessageRecord]`, `insertUser(_:conversationID:parentID:text:turnID:) -> ChatMessageRecord`, `insertAssistant(_:conversationID:parentID:turnID:provider:model:) -> ChatMessageRecord`, `updateAssistant(_:id:text:status:tokensIn:tokensOut:errorCode:)`, `setModel(_:messageID:model:)`, `setActiveLeaf(_:conversationID:messageID:)`, `selectSibling(_:conversationID:siblingID:)`.
  - `ChatStepQueries`: `upsertStart(_:messageID:seq:toolID:name:argsJSON:startedAt:)`, `finish(_:messageID:toolID:ok:summary:sourcesJSON:endedAt:)`, `fetch(_:messageIDs:) -> [Int64: [ChatTurnStep]]`.
  - `ChatSearchQueries`: `markStart`, `markEnd`, `ftsQuery(_:) -> String?`, `search(_:query:limit:) -> [ChatSearchHit]`; `ChatSearchHit{conversationID, messageID: Int64?, title, snippet; id; attributedSnippet}`.
  - `ChatConversationQueries` (+): `create(_:title:contextType:contextID:projectID:)`, `rename(_:id:title:)`, `setPrefixTitle(_:id:text:)`, `pin(_:id:pinned:)`, `archive(_:id:)`, `setProject(_:id:projectID:)`, `setProviderModel(_:id:provider:model:)`; `fetchStandalone` excludes archived. `ensureTable`/`ensureContextColumns` are deleted.
  - `ChatMessageQueries` (moved to Core, `package`, `ensure*` deleted): `fetchByConversation`, `insert`, `deleteByConversation` unchanged.
  - `ChatHistoryGrouping.group(_:now:calendar:) -> [ChatHistorySection]`; `ChatHistorySection{kind, conversations; id}`; `ChatHistorySectionKind{pinned, today, yesterday, previous7Days, previous30Days, older; title}`.
  - Test support: `TestDatabase.insertChatConversation(_:title:sessionID:contextType:provider:updatedAt:pinned:) -> Int64`, `TestDatabase.insertChatMessage(_:conversationID:role:text:parentID:status:turnID:createdAt:) -> Int64`.

- [ ] **Step 1: Mirror the goose chat schema into the test DB**

Open `internal/db/schema.sql` (Task 1's output) and copy its `chat_*` DDL. The expected shape is below; **if Task 1's DDL differs, Task 1's text wins** (copy it verbatim, then adapt the insert helpers in Step 2). Append inside the `schema` string of `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`, right before the closing `"""`:

```sql
    CREATE TABLE IF NOT EXISTS chat_projects (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        name         TEXT    NOT NULL,
        instructions TEXT    NOT NULL DEFAULT '',
        created_at   REAL    NOT NULL,
        updated_at   REAL    NOT NULL,
        archived_at  REAL
    );
    CREATE TABLE IF NOT EXISTS chat_conversations (
        id                     INTEGER PRIMARY KEY AUTOINCREMENT,
        title                  TEXT    NOT NULL DEFAULT '',
        session_id             TEXT,
        context_type           TEXT,
        context_id             TEXT,
        created_at             REAL    NOT NULL,
        updated_at             REAL    NOT NULL,
        pinned                 INTEGER NOT NULL DEFAULT 0,
        archived_at            REAL,
        title_source           TEXT    NOT NULL DEFAULT 'prefix' CHECK(title_source IN ('prefix','ai','user')),
        provider               TEXT,
        model                  TEXT,
        project_id             INTEGER REFERENCES chat_projects(id) ON DELETE SET NULL,
        active_leaf_message_id INTEGER
    );
    CREATE TABLE IF NOT EXISTS chat_messages (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        conversation_id INTEGER NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE,
        role            TEXT    NOT NULL,
        text            TEXT    NOT NULL,
        created_at      REAL    NOT NULL,
        turn_id         TEXT    NOT NULL DEFAULT '',
        status          TEXT    NOT NULL DEFAULT 'complete' CHECK(status IN ('complete','partial','error')),
        provider        TEXT,
        model           TEXT,
        tokens_in       INTEGER,
        tokens_out      INTEGER,
        parent_id       INTEGER REFERENCES chat_messages(id) ON DELETE CASCADE,
        error_code      TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_chat_messages_conversation ON chat_messages(conversation_id);
    CREATE INDEX IF NOT EXISTS idx_chat_messages_parent ON chat_messages(parent_id);
    CREATE TABLE IF NOT EXISTS chat_turn_steps (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        message_id   INTEGER NOT NULL REFERENCES chat_messages(id) ON DELETE CASCADE,
        seq          INTEGER NOT NULL,
        tool_id      TEXT    NOT NULL,
        name         TEXT    NOT NULL,
        args_json    TEXT    NOT NULL DEFAULT '{}',
        ok           INTEGER,
        summary      TEXT    NOT NULL DEFAULT '',
        sources_json TEXT    NOT NULL DEFAULT '[]',
        started_at   REAL    NOT NULL,
        ended_at     REAL
    );
    CREATE INDEX IF NOT EXISTS idx_chat_turn_steps_message ON chat_turn_steps(message_id, seq);
    CREATE TABLE IF NOT EXISTS chat_attachments (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        conversation_id INTEGER REFERENCES chat_conversations(id) ON DELETE CASCADE,
        project_id      INTEGER REFERENCES chat_projects(id) ON DELETE CASCADE,
        message_id      INTEGER REFERENCES chat_messages(id) ON DELETE SET NULL,
        name            TEXT    NOT NULL,
        mime            TEXT    NOT NULL,
        size            INTEGER NOT NULL,
        path            TEXT    NOT NULL,
        sha256          TEXT    NOT NULL,
        created_at      REAL    NOT NULL,
        CHECK ((conversation_id IS NULL) <> (project_id IS NULL))
    );
    CREATE TABLE IF NOT EXISTS chat_artifacts (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        conversation_id INTEGER NOT NULL REFERENCES chat_conversations(id) ON DELETE CASCADE,
        message_id      INTEGER NOT NULL REFERENCES chat_messages(id) ON DELETE CASCADE,
        artifact_key    TEXT    NOT NULL,
        version         INTEGER NOT NULL,
        kind            TEXT    NOT NULL,
        title           TEXT    NOT NULL DEFAULT '',
        content         TEXT    NOT NULL DEFAULT '',
        meta_json       TEXT    NOT NULL DEFAULT '{}',
        edited          INTEGER NOT NULL DEFAULT 0,
        created_at      REAL    NOT NULL,
        UNIQUE(conversation_id, artifact_key, version)
    );
    CREATE TABLE IF NOT EXISTS chat_project_sources (
        id         INTEGER PRIMARY KEY AUTOINCREMENT,
        project_id INTEGER NOT NULL REFERENCES chat_projects(id) ON DELETE CASCADE,
        kind       TEXT    NOT NULL CHECK(kind IN ('jira_project','slack_channel','target','track','person')),
        ref        TEXT    NOT NULL,
        label      TEXT    NOT NULL DEFAULT ''
    );
    CREATE VIRTUAL TABLE IF NOT EXISTS chat_fts USING fts5(
        text, content='chat_messages', content_rowid='id', tokenize='porter unicode61'
    );
    CREATE TRIGGER IF NOT EXISTS chat_messages_fts_ai AFTER INSERT ON chat_messages BEGIN
        INSERT INTO chat_fts(rowid, text) VALUES (new.id, new.text);
    END;
    CREATE TRIGGER IF NOT EXISTS chat_messages_fts_ad AFTER DELETE ON chat_messages BEGIN
        INSERT INTO chat_fts(chat_fts, rowid, text) VALUES ('delete', old.id, old.text);
    END;
    CREATE TRIGGER IF NOT EXISTS chat_messages_fts_au AFTER UPDATE OF text ON chat_messages BEGIN
        INSERT INTO chat_fts(chat_fts, rowid, text) VALUES ('delete', old.id, old.text);
        INSERT INTO chat_fts(rowid, text) VALUES (new.id, new.text);
    END;
```

- [ ] **Step 2: Test fixtures for chat rows**

Create `WatchtowerDesktop/Tests/Support/TestDatabase+Chat.swift`:

```swift
import Foundation
import GRDB

extension TestDatabase {
    /// One `chat_conversations` row. Columns not listed keep their schema
    /// defaults; tests that need `archived_at`/`title_source`/leaf set them
    /// with a direct UPDATE so this helper stays under the parameter limit.
    @discardableResult
    package static func insertChatConversation(
        _ db: Database,
        title: String = "",
        sessionID: String? = nil,
        contextType: String? = nil,
        provider: String? = nil,
        updatedAt: Double = Date().timeIntervalSince1970,
        pinned: Bool = false
    ) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO chat_conversations (title, session_id, context_type, provider, created_at, updated_at, pinned)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [title, sessionID, contextType, provider, updatedAt, updatedAt, pinned ? 1 : 0])
        return db.lastInsertedRowID
    }

    @discardableResult
    package static func insertChatMessage(
        _ db: Database,
        conversationID: Int64,
        role: String,
        text: String,
        parentID: Int64? = nil,
        status: String = "complete",
        turnID: String = "",
        createdAt: Double = Date().timeIntervalSince1970
    ) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO chat_messages (conversation_id, role, text, parent_id, status, turn_id, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [conversationID, role, text, parentID, status, turnID, createdAt])
        return db.lastInsertedRowID
    }
}
```

- [ ] **Step 3: Write the failing pure-tree test**

Create `WatchtowerDesktop/Tests/Core/ChatTreeTests.swift`:

```swift
import XCTest
@testable import WatchtowerCore

/// The branch tree behind regenerate/edit (spec §2.3). Fixture:
///   1 user ─ 2 asst ─ 3 user ─┬ 4 asst
///                   │          └ 5 asst   (regenerate of 4)
///                   └ 6 user ─ 7 asst     (edit of 3)
final class ChatTreeTests: XCTestCase {
    private let tree = ChatTree(nodes: [
        .init(id: 1, parentID: nil), .init(id: 2, parentID: 1), .init(id: 3, parentID: 2),
        .init(id: 4, parentID: 3), .init(id: 5, parentID: 3), .init(id: 6, parentID: 2),
        .init(id: 7, parentID: 6)
    ])

    func testPathRunsRootToLeaf() {
        XCTAssertEqual(tree.path(toLeaf: 5), [1, 2, 3, 5])
        XCTAssertEqual(tree.path(toLeaf: 7), [1, 2, 6, 7])
    }

    func testUnknownLeafYieldsEmptyPath() {
        XCTAssertEqual(tree.path(toLeaf: 99), [])
    }

    func testSiblingsShareAParentInIdOrder() {
        XCTAssertEqual(tree.siblings(of: 5), [4, 5])
        XCTAssertEqual(tree.siblings(of: 3), [3, 6])
        XCTAssertEqual(tree.siblings(of: 1), [1])
    }

    func testRootsAreSiblingsOfEachOther() {
        let forest = ChatTree(nodes: [.init(id: 1, parentID: nil), .init(id: 10, parentID: nil)])
        XCTAssertEqual(forest.siblings(of: 10), [1, 10])
    }

    func testNewestLeafIsTheHighestIdLeafUnderTheNode() {
        XCTAssertEqual(tree.newestLeaf(under: 3), 5)
        XCTAssertEqual(tree.newestLeaf(under: 2), 7)
        XCTAssertEqual(tree.newestLeaf(under: 4), 4)
    }

    /// A corrupt parent cycle must terminate, not hang the UI.
    func testParentCycleTerminates() {
        let cyclic = ChatTree(nodes: [.init(id: 8, parentID: 9), .init(id: 9, parentID: 8)])
        XCTAssertEqual(cyclic.path(toLeaf: 8).count, 2)
    }
}
```

- [ ] **Step 4: Run it to verify it fails**

Run: `make test-swift FILTER=ChatTreeTests`
Expected: FAIL — `cannot find 'ChatTree' in scope`.

- [ ] **Step 5: Implement `ChatTree`**

Create `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ChatTree.swift`:

```swift
import Foundation

/// The message tree of one conversation (spec §2.3): `parent_id` edges, the
/// visible thread being the path root → `active_leaf_message_id`. Pure — the
/// queries fetch `(id, parent_id)` once and ask this type everything.
package struct ChatTree: Sendable {
    package struct Node: Equatable, Sendable {
        package let id: Int64
        package let parentID: Int64?

        package init(id: Int64, parentID: Int64?) {
            self.id = id
            self.parentID = parentID
        }
    }

    private let known: Set<Int64>
    private let parentOf: [Int64: Int64]
    private let children: [Int64: [Int64]]
    private let roots: [Int64]

    package init(nodes: [Node]) {
        let sorted = nodes.sorted { $0.id < $1.id }
        known = Set(sorted.map(\.id))
        var parents: [Int64: Int64] = [:]
        var kids: [Int64: [Int64]] = [:]
        var rootIDs: [Int64] = []
        for node in sorted {
            if let parent = node.parentID {
                parents[node.id] = parent
                kids[parent, default: []].append(node.id)
            } else {
                rootIDs.append(node.id)
            }
        }
        parentOf = parents
        children = kids
        roots = rootIDs
    }

    /// Root → leaf ids; empty when the leaf is not in this conversation.
    package func path(toLeaf leaf: Int64) -> [Int64] {
        guard known.contains(leaf) else { return [] }
        var out: [Int64] = []
        var visited = Set<Int64>()
        var current: Int64? = leaf
        while let id = current, known.contains(id), visited.insert(id).inserted {
            out.append(id)
            current = parentOf[id]
        }
        return out.reversed()
    }

    /// Ids sharing `id`'s parent (roots share "no parent"), ascending.
    package func siblings(of id: Int64) -> [Int64] {
        guard let parent = parentOf[id] else { return roots }
        return children[parent] ?? [id]
    }

    /// The most recently created leaf in `id`'s subtree (`id` itself when it
    /// has no children) — where switching to a variant lands.
    package func newestLeaf(under id: Int64) -> Int64 {
        var leaves: [Int64] = []
        var stack = [id]
        var visited = Set<Int64>()
        while let node = stack.popLast() {
            guard visited.insert(node).inserted else { continue }
            let kids = children[node] ?? []
            if kids.isEmpty { leaves.append(node) } else { stack.append(contentsOf: kids) }
        }
        return leaves.max() ?? id
    }
}
```

- [ ] **Step 6: Run the tree test**

Run: `make test-swift FILTER=ChatTreeTests`
Expected: PASS (6 tests).

- [ ] **Step 7: Core chat models**

`git mv WatchtowerDesktop/Sources/Models/ChatMessageRecord.swift WatchtowerDesktop/Sources/WatchtowerCore/Models/ChatModels.swift` and replace its content with:

```swift
import Foundation
import GRDB

/// One `chat_messages` row (goose migration 00074 owns the table). New
/// columns decode with `decodeIfPresent` so a Discuss chat reading an old
/// fixture shape still loads.
package struct ChatMessageRecord: FetchableRecord, Decodable, Identifiable, Equatable, Sendable {
    package let id: Int64
    package let conversationID: Int64
    package let parentID: Int64?
    package let role: String
    package let text: String
    package let createdAt: Double
    package let turnID: String
    package let status: String
    package let provider: String?
    package let model: String?
    package let tokensIn: Int?
    package let tokensOut: Int?
    package let errorCode: String?

    enum CodingKeys: String, CodingKey {
        case id, role, text, status, provider, model
        case conversationID = "conversation_id"
        case parentID = "parent_id"
        case createdAt = "created_at"
        case turnID = "turn_id"
        case tokensIn = "tokens_in"
        case tokensOut = "tokens_out"
        case errorCode = "error_code"
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        conversationID = try c.decode(Int64.self, forKey: .conversationID)
        parentID = try c.decodeIfPresent(Int64.self, forKey: .parentID)
        role = try c.decode(String.self, forKey: .role)
        text = try c.decode(String.self, forKey: .text)
        createdAt = try c.decode(Double.self, forKey: .createdAt)
        turnID = try c.decodeIfPresent(String.self, forKey: .turnID) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "complete"
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        tokensIn = try c.decodeIfPresent(Int.self, forKey: .tokensIn)
        tokensOut = try c.decodeIfPresent(Int.self, forKey: .tokensOut)
        errorCode = try c.decodeIfPresent(String.self, forKey: .errorCode)
    }

    package var createdDate: Date { Date(timeIntervalSince1970: createdAt) }
    package var isUser: Bool { role == "user" }
    package var isAssistant: Bool { role == "assistant" }
}

/// A step's lifecycle. `running` on a finished message means the turn died
/// mid-tool; views render it as stopped, never as a live spinner.
package enum StepState: Equatable, Sendable {
    case running
    case succeeded
    case failed
}

/// One source chip (spec §3.4) — the `tool_end.sources[]` wire item.
package struct ChatSource: Codable, Hashable, Sendable {
    package let kind: String
    package let title: String
    package let url: String?
    package let ref: String

    package init(kind: String, title: String, url: String?, ref: String) {
        self.kind = kind
        self.title = title
        self.url = url
        self.ref = ref
    }

    package var dedupeKey: String {
        if let url, !url.isEmpty { url } else { "\(kind):\(ref)" }
    }

    package static func dedupe(_ sources: [ChatSource]) -> [ChatSource] {
        var seen = Set<String>()
        return sources.filter { seen.insert($0.dedupeKey).inserted }
    }

    /// Display-only column: an undecodable value renders as "no chips",
    /// which is the honest rendering of a column we cannot read.
    package static func decodeList(_ json: String) -> [ChatSource] {
        (try? JSONDecoder().decode([ChatSource].self, from: Data(json.utf8))) ?? []
    }

    package static func encodeList(_ sources: [ChatSource]) -> String {
        guard let data = try? JSONEncoder().encode(sources) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// One `chat_turn_steps` row.
package struct ChatTurnStep: FetchableRecord, Decodable, Identifiable, Equatable, Sendable {
    package let id: Int64
    package let messageID: Int64
    package let seq: Int
    package let toolID: String
    package let name: String
    package let argsJSON: String
    package let okFlag: Int?
    package let summary: String
    package let sourcesJSON: String
    package let startedAt: Double
    package let endedAt: Double?

    enum CodingKeys: String, CodingKey {
        case id, seq, name, summary
        case messageID = "message_id"
        case toolID = "tool_id"
        case argsJSON = "args_json"
        case okFlag = "ok"
        case sourcesJSON = "sources_json"
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }

    package var state: StepState {
        switch okFlag {
        case .some(1): .succeeded
        case .some: .failed
        case .none: .running
        }
    }

    package var sources: [ChatSource] { ChatSource.decodeList(sourcesJSON) }

    package var display: ChatStepDisplay {
        ChatStepDisplay(
            id: toolID, name: name, argsJSON: argsJSON, state: state, summary: summary, sources: sources,
            startedAt: Date(timeIntervalSince1970: startedAt),
            endedAt: endedAt.map { Date(timeIntervalSince1970: $0) }
        )
    }
}

/// What the steps block renders — built from a persisted row or a live step.
package struct ChatStepDisplay: Identifiable, Equatable, Sendable {
    package let id: String
    package let name: String
    package let argsJSON: String
    package var state: StepState
    package var summary: String
    package var sources: [ChatSource]
    package let startedAt: Date
    package var endedAt: Date?

    // swiftlint:disable:next function_parameter_count
    package init(
        id: String, name: String, argsJSON: String, state: StepState, summary: String,
        sources: [ChatSource], startedAt: Date, endedAt: Date?
    ) {
        self.id = id
        self.name = name
        self.argsJSON = argsJSON
        self.state = state
        self.summary = summary
        self.sources = sources
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

/// One visible message of the active branch, with what its row needs.
package struct ChatThreadItem: Identifiable, Equatable, Sendable {
    package let message: ChatMessageRecord
    package let steps: [ChatTurnStep]
    /// 1-based position among siblings; `‹ i/n ›` shows when count > 1.
    package let siblingIndex: Int
    package let siblingCount: Int

    package init(message: ChatMessageRecord, steps: [ChatTurnStep], siblingIndex: Int, siblingCount: Int) {
        self.message = message
        self.steps = steps
        self.siblingIndex = siblingIndex
        self.siblingCount = siblingCount
    }

    package var id: Int64 { message.id }
    package var stepDisplays: [ChatStepDisplay] { steps.map(\.display) }
    package var sources: [ChatSource] { ChatSource.dedupe(steps.flatMap(\.sources)) }
}
```

Create `WatchtowerDesktop/Sources/Models/ChatMessageRecord+UI.swift` (the UI mapping stays app-side because `ChatMessage` is an app type):

```swift
import Foundation
import WatchtowerCore

extension ChatMessageRecord {
    func toChatMessage() -> ChatMessage {
        let msgRole: ChatMessage.Role = switch role {
        case "user": .user
        case "system": .system
        default: .assistant
        }
        return ChatMessage(
            id: UUID(),
            role: msgRole,
            text: text,
            timestamp: createdDate,
            isStreaming: false,
            turnID: turnID.isEmpty ? nil : turnID
        )
    }
}
```

- [ ] **Step 8: `ChatConversation` gains the new columns**

Replace `WatchtowerDesktop/Sources/WatchtowerCore/Models/ChatConversation.swift`:

```swift
import Foundation
import GRDB

package struct ChatConversation: FetchableRecord, Decodable, Identifiable, Equatable, Sendable {
    package let id: Int64
    package let title: String
    package let sessionID: String?
    package let contextType: String?
    package let contextID: String?
    package let createdAt: Double
    package let updatedAt: Double
    package let pinned: Bool
    package let archivedAt: Double?
    /// `prefix` (first 80 chars of the first message), `ai` (`chat title`) or `user` (renamed).
    package let titleSource: String
    package let provider: String?
    package let model: String?
    package let projectID: Int64?
    package let activeLeafMessageID: Int64?

    package enum CodingKeys: String, CodingKey {
        case id, title, pinned, provider, model
        case sessionID = "session_id"
        case contextType = "context_type"
        case contextID = "context_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case archivedAt = "archived_at"
        case titleSource = "title_source"
        case projectID = "project_id"
        case activeLeafMessageID = "active_leaf_message_id"
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        contextType = try c.decodeIfPresent(String.self, forKey: .contextType)
        contextID = try c.decodeIfPresent(String.self, forKey: .contextID)
        createdAt = try c.decode(Double.self, forKey: .createdAt)
        updatedAt = try c.decode(Double.self, forKey: .updatedAt)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        archivedAt = try c.decodeIfPresent(Double.self, forKey: .archivedAt)
        titleSource = try c.decodeIfPresent(String.self, forKey: .titleSource) ?? "prefix"
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        projectID = try c.decodeIfPresent(Int64.self, forKey: .projectID)
        activeLeafMessageID = try c.decodeIfPresent(Int64.self, forKey: .activeLeafMessageID)
    }

    package var createdDate: Date { Date(timeIntervalSince1970: createdAt) }
    package var updatedDate: Date { Date(timeIntervalSince1970: updatedAt) }
    package var displayTitle: String { title.isEmpty ? "New Chat" : title }
}
```

- [ ] **Step 9: Remove the Swift-side DDL everywhere**

1. `git mv WatchtowerDesktop/Sources/Database/Queries/ChatMessageQueries.swift WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ChatMessageQueries.swift`, then in it: change `enum ChatMessageQueries` to `package enum ChatMessageQueries`, prefix each remaining `static func` with `package`, and delete `ensureTable` and `ensureTurnIDColumn` entirely.
2. In `ChatConversationQueries.swift` delete `ensureTable` and `ensureContextColumns` (the `action_item → track` fix now lives in migration 00074).
3. In `DatabaseManager.swift` replace the required-tables loop and delete the "Desktop-only tables" `dbPool.write` block:

```swift
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
            // chat_turn_steps exists only once goose migration 00074 ran; the
            // older Swift-created chat tables alone do not satisfy the floor.
            let required = ["workspace", "channels", "messages", "users", "chat_conversations", "chat_messages", "chat_turn_steps"]
            for table in required {
                guard tables.contains(table) else {
                    throw WatchtowerDatabaseError.missingTable(table)
                }
            }
        }
    }
```

4. Tests: the shared test schema now has every chat table, so delete the per-test DDL calls:

```bash
cd WatchtowerDesktop
grep -rl "ensureTable\|ensureTurnIDColumn\|ensureContextColumns" Tests | xargs sed -i '' \
  -e '/ChatConversationQueries\.ensureTable(db)/d' \
  -e '/ChatConversationQueries\.ensureContextColumns(db)/d' \
  -e '/ChatMessageQueries\.ensureTable(db)/d' \
  -e '/ChatMessageQueries\.ensureTurnIDColumn(db)/d'
git rm Tests/ChatMessageTurnIDTests.swift
grep -rn "ensureTable\|ensureTurnIDColumn\|ensureContextColumns" Tests Sources
```

Expected: the last grep prints nothing. Then fix up by hand the three spots sed leaves awkward:
- `Tests/ViewModelTests.swift` `ChatHistoryViewModelTests.setUp`: delete the now-empty `do { try dbManager.dbPool.write { db in } } catch { XCTFail("setUp ensureTable failed…") }` block and its comment.
- `Tests/Core/IdeaQueriesTests.swift` `createChatTables(_:)`: delete the helper and its call sites (the schema has the tables) along with its doc comment.
- `Tests/Core/ChatConversationQueriesContextTests.swift` `makeDB()`: reduce to `try TestDatabase.create()` and update the type doc comment to "chat tables come from the shared test schema (goose 00074)".
- `Tests/Core/QueryTests.swift`: rename `testEnsureTableAndCreate` → `testCreate`.

- [ ] **Step 10: Run the existing chat-adjacent suites to verify the move compiles**

Run: `cd WatchtowerDesktop && swift build 2>&1 | tail -5; echo "exit ${PIPESTATUS[0]}"`
Expected: `exit 0`. Then `make test-swift FILTER=ChatConversationQuer` → PASS.

- [ ] **Step 11: Write the failing query tests**

Create `WatchtowerDesktop/Tests/Core/ChatTreeQueriesTests.swift`:

```swift
import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class ChatTreeQueriesTests: XCTestCase {
    private var db: DatabaseQueue!

    override func setUpWithError() throws {
        db = try TestDatabase.create()
    }

    /// A conversation migrated from the Swift-created tables has no leaf; its
    /// thread is every message in id order (Go `ActiveChatPath` does the same).
    func testConversationWithoutLeafReadsLinearIdOrder() throws {
        try db.write { d in
            let conv = try TestDatabase.insertChatConversation(d)
            let a = try TestDatabase.insertChatMessage(d, conversationID: conv, role: "user", text: "a")
            let b = try TestDatabase.insertChatMessage(d, conversationID: conv, role: "assistant", text: "b", parentID: a)
            let path = try ChatTreeQueries.activePath(d, conversationID: conv)
            XCTAssertEqual(path.map(\.id), [a, b])
        }
    }

    func testInsertsChainAndMoveTheLeaf() throws {
        try db.write { d in
            let conv = try TestDatabase.insertChatConversation(d)
            let user = try ChatTreeQueries.insertUser(d, conversationID: conv, parentID: nil, text: "q", turnID: "t1")
            let asst = try ChatTreeQueries.insertAssistant(
                d, conversationID: conv, parentID: user.id, turnID: "t1", provider: "claude", model: "")
            XCTAssertEqual(asst.status, "partial", "an assistant row starts partial until turn_done")
            XCTAssertNil(asst.model, "an empty model is stored as NULL")
            let conversation = try XCTUnwrap(ChatConversationQueries.fetchByID(d, id: conv))
            XCTAssertEqual(conversation.activeLeafMessageID, asst.id)
            XCTAssertEqual(try ChatTreeQueries.activePath(d, conversationID: conv).map(\.id), [user.id, asst.id])
        }
    }

    func testRegenerateMakesASiblingAndSelectSiblingSwitchesBranch() throws {
        try db.write { d in
            let conv = try TestDatabase.insertChatConversation(d)
            let user = try ChatTreeQueries.insertUser(d, conversationID: conv, parentID: nil, text: "q", turnID: "t1")
            let first = try ChatTreeQueries.insertAssistant(
                d, conversationID: conv, parentID: user.id, turnID: "t1", provider: "claude", model: "")
            let second = try ChatTreeQueries.insertAssistant(
                d, conversationID: conv, parentID: user.id, turnID: "t2", provider: "claude", model: "")
            XCTAssertEqual(try ChatTreeQueries.siblings(d, messageID: first.id).map(\.id), [first.id, second.id])
            XCTAssertEqual(try ChatTreeQueries.activePath(d, conversationID: conv).last?.id, second.id)

            try ChatTreeQueries.selectSibling(d, conversationID: conv, siblingID: first.id)
            XCTAssertEqual(try ChatTreeQueries.activePath(d, conversationID: conv).last?.id, first.id)
        }
    }

    func testThreadCarriesSiblingPositionsAndSteps() throws {
        try db.write { d in
            let conv = try TestDatabase.insertChatConversation(d)
            let user = try ChatTreeQueries.insertUser(d, conversationID: conv, parentID: nil, text: "q", turnID: "t1")
            _ = try ChatTreeQueries.insertAssistant(d, conversationID: conv, parentID: user.id, turnID: "t1", provider: "claude", model: "")
            let second = try ChatTreeQueries.insertAssistant(
                d, conversationID: conv, parentID: user.id, turnID: "t2", provider: "claude", model: "")
            try ChatStepQueries.upsertStart(d, messageID: second.id, seq: 0, toolID: "tu1", name: "search_knowledge",
                                            argsJSON: #"{"queries":["x"]}"#, startedAt: 10)

            let thread = try ChatTreeQueries.thread(d, conversationID: conv)
            XCTAssertEqual(thread.map(\.id), [user.id, second.id])
            XCTAssertEqual(thread[1].siblingIndex, 2)
            XCTAssertEqual(thread[1].siblingCount, 2)
            XCTAssertEqual(thread[1].steps.map(\.name), ["search_knowledge"])
            XCTAssertEqual(thread[0].siblingCount, 1)
        }
    }

    func testUpdateAssistantWritesStatusUsageAndError() throws {
        try db.write { d in
            let conv = try TestDatabase.insertChatConversation(d)
            let asst = try ChatTreeQueries.insertAssistant(d, conversationID: conv, parentID: nil, turnID: "t", provider: "claude", model: "")
            try ChatTreeQueries.updateAssistant(d, id: asst.id, text: "hi", status: "error", tokensIn: 3, tokensOut: 4, errorCode: "rate_limit")
            try ChatTreeQueries.setModel(d, messageID: asst.id, model: "model-b")
            let row = try XCTUnwrap(ChatMessageRecord.fetchOne(d, sql: "SELECT * FROM chat_messages WHERE id = ?", arguments: [asst.id]))
            XCTAssertEqual(row.text, "hi")
            XCTAssertEqual(row.status, "error")
            XCTAssertEqual(row.tokensIn, 3)
            XCTAssertEqual(row.tokensOut, 4)
            XCTAssertEqual(row.errorCode, "rate_limit")
            XCTAssertEqual(row.model, "model-b")
        }
    }

    /// Discuss chats never set a leaf or parents; they keep reading linearly.
    func testEmptyConversationHasEmptyThread() throws {
        try db.write { d in
            let conv = try TestDatabase.insertChatConversation(d)
            XCTAssertTrue(try ChatTreeQueries.thread(d, conversationID: conv).isEmpty)
        }
    }
}
```

Create `WatchtowerDesktop/Tests/Core/ChatStepQueriesTests.swift`:

```swift
import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class ChatStepQueriesTests: XCTestCase {
    private func withMessage(_ body: (Database, Int64) throws -> Void) throws {
        let db = try TestDatabase.create()
        try db.write { d in
            let conv = try TestDatabase.insertChatConversation(d)
            let msg = try TestDatabase.insertChatMessage(d, conversationID: conv, role: "assistant", text: "")
            try body(d, msg)
        }
    }

    func testStartThenFinishIsOneStepWithResult() throws {
        try withMessage { d, msg in
            try ChatStepQueries.upsertStart(d, messageID: msg, seq: 0, toolID: "a", name: "get_jira_issue", argsJSON: "{}", startedAt: 1)
            try ChatStepQueries.upsertStart(d, messageID: msg, seq: 0, toolID: "a", name: "get_jira_issue", argsJSON: #"{"key":"P-1"}"#, startedAt: 1)
            let sources = ChatSource.encodeList([ChatSource(kind: "jira", title: "P-1", url: "https://x/P-1", ref: "P-1")])
            try ChatStepQueries.finish(d, messageID: msg, toolID: "a", ok: true, summary: "found", sourcesJSON: sources, endedAt: 2)

            let steps = try XCTUnwrap(ChatStepQueries.fetch(d, messageIDs: [msg])[msg])
            XCTAssertEqual(steps.count, 1, "a repeated tool_start updates, never duplicates")
            XCTAssertEqual(steps[0].argsJSON, #"{"key":"P-1"}"#)
            XCTAssertEqual(steps[0].state, .succeeded)
            XCTAssertEqual(steps[0].summary, "found")
            XCTAssertEqual(steps[0].sources.map(\.ref), ["P-1"])
        }
    }

    /// CHAT-02: a tool_end whose tool_start was lost still becomes a step.
    func testFinishWithoutStartStillRecordsAStep() throws {
        try withMessage { d, msg in
            try ChatStepQueries.finish(d, messageID: msg, toolID: "orphan", ok: false, summary: "boom", sourcesJSON: "[]", endedAt: 5)
            let steps = try XCTUnwrap(ChatStepQueries.fetch(d, messageIDs: [msg])[msg])
            XCTAssertEqual(steps.map(\.state), [.failed])
        }
    }

    func testUnfinishedStepIsRunningAndFetchOrdersBySeq() throws {
        try withMessage { d, msg in
            try ChatStepQueries.upsertStart(d, messageID: msg, seq: 1, toolID: "b", name: "second", argsJSON: "{}", startedAt: 2)
            try ChatStepQueries.upsertStart(d, messageID: msg, seq: 0, toolID: "a", name: "first", argsJSON: "{}", startedAt: 1)
            let steps = try XCTUnwrap(ChatStepQueries.fetch(d, messageIDs: [msg])[msg])
            XCTAssertEqual(steps.map(\.name), ["first", "second"])
            XCTAssertEqual(steps.map(\.state), [.running, .running])
        }
    }

    func testFetchWithNoIDsIsEmpty() throws {
        try withMessage { d, _ in
            XCTAssertTrue(try ChatStepQueries.fetch(d, messageIDs: []).isEmpty)
        }
    }
}
```

- [ ] **Step 12: Run them to verify they fail**

Run: `make test-swift FILTER=ChatTreeQueriesTests` and `make test-swift FILTER=ChatStepQueriesTests`
Expected: FAIL — `cannot find 'ChatTreeQueries' in scope` / `'ChatStepQueries'`.

- [ ] **Step 13: Implement `ChatStepQueries`**

Create `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ChatStepQueries.swift`:

```swift
import Foundation
import GRDB

/// `chat_turn_steps` — every tool call of a turn, persisted as it happens
/// (CHAT-02). Keyed by `(message_id, tool_id)` without relying on a UNIQUE
/// index, so a repeated `tool_start` updates rather than duplicates.
package enum ChatStepQueries {
    // swiftlint:disable:next function_parameter_count
    package static func upsertStart(
        _ db: Database, messageID: Int64, seq: Int, toolID: String, name: String, argsJSON: String, startedAt: Double
    ) throws {
        if let existing = try Int64.fetchOne(
            db, sql: "SELECT id FROM chat_turn_steps WHERE message_id = ? AND tool_id = ?", arguments: [messageID, toolID]
        ) {
            try db.execute(
                sql: "UPDATE chat_turn_steps SET name = ?, args_json = ?, started_at = ? WHERE id = ?",
                arguments: [name, argsJSON, startedAt, existing]
            )
            return
        }
        try db.execute(sql: """
            INSERT INTO chat_turn_steps (message_id, seq, tool_id, name, args_json, started_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [messageID, seq, toolID, name, argsJSON, startedAt])
    }

    // swiftlint:disable:next function_parameter_count
    package static func finish(
        _ db: Database, messageID: Int64, toolID: String, ok: Bool, summary: String, sourcesJSON: String, endedAt: Double
    ) throws {
        try db.execute(sql: """
            UPDATE chat_turn_steps SET ok = ?, summary = ?, sources_json = ?, ended_at = ?
            WHERE message_id = ? AND tool_id = ?
            """, arguments: [ok ? 1 : 0, summary, sourcesJSON, endedAt, messageID, toolID])
        guard db.changesCount == 0 else { return }
        // A tool_end whose tool_start never arrived is still a visible step (CHAT-02).
        let seq = try Int.fetchOne(
            db, sql: "SELECT COALESCE(MAX(seq) + 1, 0) FROM chat_turn_steps WHERE message_id = ?", arguments: [messageID]
        ) ?? 0
        try db.execute(sql: """
            INSERT INTO chat_turn_steps (message_id, seq, tool_id, name, ok, summary, sources_json, started_at, ended_at)
            VALUES (?, ?, ?, '', ?, ?, ?, ?, ?)
            """, arguments: [messageID, seq, toolID, ok ? 1 : 0, summary, sourcesJSON, endedAt, endedAt])
    }

    package static func fetch(_ db: Database, messageIDs: [Int64]) throws -> [Int64: [ChatTurnStep]] {
        guard !messageIDs.isEmpty else { return [:] }
        let steps = try ChatTurnStep.fetchAll(
            db,
            sql: """
                SELECT * FROM chat_turn_steps WHERE message_id IN (\(databaseQuestionMarks(count: messageIDs.count)))
                ORDER BY message_id, seq, id
                """,
            arguments: StatementArguments(messageIDs)
        )
        return Dictionary(grouping: steps, by: \.messageID)
    }
}
```

- [ ] **Step 14: Implement `ChatTreeQueries`**

Create `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ChatTreeQueries.swift`:

```swift
import Foundation
import GRDB

/// The main chat's branch-aware message access (spec §2.3). Discuss chats
/// keep using `ChatMessageQueries` (linear, no leaf) — a conversation whose
/// leaf is NULL reads in id order here too, the same fallback Go's
/// `ActiveChatPath` applies.
package enum ChatTreeQueries {
    package static func activePath(_ db: Database, conversationID: Int64) throws -> [ChatMessageRecord] {
        let all = try allMessages(db, conversationID: conversationID)
        return try resolvePath(db, conversationID: conversationID, all: all).path
    }

    package static func thread(_ db: Database, conversationID: Int64) throws -> [ChatThreadItem] {
        let all = try allMessages(db, conversationID: conversationID)
        let resolved = try resolvePath(db, conversationID: conversationID, all: all)
        let steps = try ChatStepQueries.fetch(db, messageIDs: resolved.path.map(\.id))
        return resolved.path.map { message in
            // Without a leaf there are no branches (legacy / never-branched chat).
            let sibs = resolved.tree.map { $0.siblings(of: message.id) } ?? [message.id]
            return ChatThreadItem(
                message: message,
                steps: steps[message.id] ?? [],
                siblingIndex: (sibs.firstIndex(of: message.id) ?? 0) + 1,
                siblingCount: max(sibs.count, 1)
            )
        }
    }

    package static func siblings(_ db: Database, messageID: Int64) throws -> [ChatMessageRecord] {
        try ChatMessageRecord.fetchAll(db, sql: """
            SELECT * FROM chat_messages
            WHERE conversation_id = (SELECT conversation_id FROM chat_messages WHERE id = ?)
              AND parent_id IS (SELECT parent_id FROM chat_messages WHERE id = ?)
            ORDER BY id
            """, arguments: [messageID, messageID])
    }

    @discardableResult
    package static func insertUser(
        _ db: Database, conversationID: Int64, parentID: Int64?, text: String, turnID: String
    ) throws -> ChatMessageRecord {
        try insert(db, NewMessage(conversationID: conversationID, parentID: parentID, role: "user", text: text,
                                  turnID: turnID, status: "complete", provider: nil, model: nil))
    }

    /// The assistant row is created empty and `partial` BEFORE the turn is
    /// sent, so a crash at any point leaves a row the owner can Continue.
    // swiftlint:disable:next function_parameter_count
    @discardableResult
    package static func insertAssistant(
        _ db: Database, conversationID: Int64, parentID: Int64?, turnID: String, provider: String, model: String
    ) throws -> ChatMessageRecord {
        try insert(db, NewMessage(conversationID: conversationID, parentID: parentID, role: "assistant", text: "",
                                  turnID: turnID, status: "partial", provider: provider,
                                  model: model.isEmpty ? nil : model))
    }

    // swiftlint:disable:next function_parameter_count
    package static func updateAssistant(
        _ db: Database, id: Int64, text: String, status: String, tokensIn: Int?, tokensOut: Int?, errorCode: String?
    ) throws {
        try db.execute(sql: """
            UPDATE chat_messages SET text = ?, status = ?, tokens_in = ?, tokens_out = ?, error_code = ? WHERE id = ?
            """, arguments: [text, status, tokensIn, tokensOut, errorCode, id])
    }

    package static func setModel(_ db: Database, messageID: Int64, model: String) throws {
        try db.execute(sql: "UPDATE chat_messages SET model = ? WHERE id = ?", arguments: [model, messageID])
    }

    package static func setActiveLeaf(_ db: Database, conversationID: Int64, messageID: Int64) throws {
        try db.execute(
            sql: "UPDATE chat_conversations SET active_leaf_message_id = ? WHERE id = ?",
            arguments: [messageID, conversationID]
        )
    }

    /// Show `siblingID`'s branch: the leaf moves to the newest leaf under it.
    package static func selectSibling(_ db: Database, conversationID: Int64, siblingID: Int64) throws {
        let tree = ChatTree(nodes: try allMessages(db, conversationID: conversationID).map(node))
        try setActiveLeaf(db, conversationID: conversationID, messageID: tree.newestLeaf(under: siblingID))
    }

    // MARK: - Private

    private struct NewMessage {
        let conversationID: Int64
        let parentID: Int64?
        let role: String
        let text: String
        let turnID: String
        let status: String
        let provider: String?
        let model: String?
    }

    private static func insert(_ db: Database, _ m: NewMessage) throws -> ChatMessageRecord {
        try db.execute(sql: """
            INSERT INTO chat_messages (conversation_id, parent_id, role, text, created_at, turn_id, status, provider, model)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [m.conversationID, m.parentID, m.role, m.text, Date().timeIntervalSince1970,
                             m.turnID, m.status, m.provider, m.model])
        let id = db.lastInsertedRowID
        try setActiveLeaf(db, conversationID: m.conversationID, messageID: id)
        try ChatConversationQueries.touch(db, id: m.conversationID)
        guard let row = try ChatMessageRecord.fetchOne(db, sql: "SELECT * FROM chat_messages WHERE id = ?", arguments: [id]) else {
            throw DatabaseError(message: "chat message \(id) vanished after insert")
        }
        return row
    }

    private static func allMessages(_ db: Database, conversationID: Int64) throws -> [ChatMessageRecord] {
        try ChatMessageRecord.fetchAll(
            db, sql: "SELECT * FROM chat_messages WHERE conversation_id = ? ORDER BY id", arguments: [conversationID]
        )
    }

    private static func node(_ m: ChatMessageRecord) -> ChatTree.Node {
        ChatTree.Node(id: m.id, parentID: m.parentID)
    }

    private static func resolvePath(
        _ db: Database, conversationID: Int64, all: [ChatMessageRecord]
    ) throws -> (path: [ChatMessageRecord], tree: ChatTree?) {
        let leaf = try Int64.fetchOne(
            db, sql: "SELECT active_leaf_message_id FROM chat_conversations WHERE id = ?", arguments: [conversationID]
        )
        guard let leaf else { return (all, nil) }
        let tree = ChatTree(nodes: all.map(node))
        let ids = tree.path(toLeaf: leaf)
        guard !ids.isEmpty else { return (all, nil) }
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        return (ids.compactMap { byID[$0] }, tree)
    }
}
```

- [ ] **Step 15: Run the query tests**

Run: `make test-swift FILTER=ChatTreeQueriesTests` then `make test-swift FILTER=ChatStepQueriesTests`
Expected: PASS, PASS.

- [ ] **Step 16: Write the failing conversation-query tests**

Create `WatchtowerDesktop/Tests/Core/ChatConversationQueriesTests.swift`:

```swift
import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class ChatConversationQueriesTests: XCTestCase {
    func testRenameMarksTitleAsUserOwnedAndPrefixNoLongerOverwrites() throws {
        let db = try TestDatabase.create()
        try db.write { d in
            let conv = try ChatConversationQueries.create(d)
            try ChatConversationQueries.setPrefixTitle(d, id: conv.id, text: String(repeating: "x", count: 100))
            XCTAssertEqual(try ChatConversationQueries.fetchByID(d, id: conv.id)?.title.count, 80)

            try ChatConversationQueries.rename(d, id: conv.id, title: "Mine")
            try ChatConversationQueries.setPrefixTitle(d, id: conv.id, text: "other")
            let row = try XCTUnwrap(ChatConversationQueries.fetchByID(d, id: conv.id))
            XCTAssertEqual(row.title, "Mine")
            XCTAssertEqual(row.titleSource, "user")
        }
    }

    func testPinArchiveAndProjectAndProviderModel() throws {
        let db = try TestDatabase.create()
        try db.write { d in
            let conv = try ChatConversationQueries.create(d)
            try ChatConversationQueries.pin(d, id: conv.id, pinned: true)
            try ChatConversationQueries.setProviderModel(d, id: conv.id, provider: "codex", model: nil)
            var row = try XCTUnwrap(ChatConversationQueries.fetchByID(d, id: conv.id))
            XCTAssertTrue(row.pinned)
            XCTAssertEqual(row.provider, "codex")
            XCTAssertNil(row.model)

            try ChatConversationQueries.archive(d, id: conv.id)
            XCTAssertTrue(try ChatConversationQueries.fetchStandalone(d).isEmpty, "archived chats leave the history")
            row = try XCTUnwrap(ChatConversationQueries.fetchByID(d, id: conv.id))
            XCTAssertNotNil(row.archivedAt)
        }
    }

    func testCreateInProject() throws {
        let db = try TestDatabase.create()
        try db.write { d in
            try d.execute(sql: "INSERT INTO chat_projects (name, created_at, updated_at) VALUES ('P', 0, 0)")
            let project = d.lastInsertedRowID
            let conv = try ChatConversationQueries.create(d, projectID: project)
            XCTAssertEqual(conv.projectID, project)
            try ChatConversationQueries.setProject(d, id: conv.id, projectID: nil)
            XCTAssertNil(try ChatConversationQueries.fetchByID(d, id: conv.id)?.projectID)
        }
    }
}
```

- [ ] **Step 17: Run it to verify it fails**

Run: `make test-swift FILTER=ChatConversationQueriesTests`
Expected: FAIL — `extra argument 'projectID'`, `no member 'rename'`.

- [ ] **Step 18: Extend `ChatConversationQueries`**

In `ChatConversationQueries.swift`, replace `create` and `fetchStandalone`, and add the mutators after `updateTitle`:

```swift
    package static func fetchStandalone(_ db: Database) throws -> [ChatConversation] {
        try ChatConversation.fetchAll(db, sql: """
            SELECT * FROM chat_conversations
            WHERE context_type IS NULL AND archived_at IS NULL
            ORDER BY updated_at DESC
        """)
    }

    @discardableResult
    package static func create(
        _ db: Database, title: String = "", contextType: String? = nil, contextID: String? = nil, projectID: Int64? = nil
    ) throws -> ChatConversation {
        let now = Date().timeIntervalSince1970
        try db.execute(sql: """
            INSERT INTO chat_conversations (title, context_type, context_id, project_id, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
        """, arguments: [title, contextType, contextID, projectID, now, now])
        let rowID = db.lastInsertedRowID
        guard let conversation = try fetchByID(db, id: rowID) else {
            throw DatabaseError(message: "Failed to fetch newly created chat conversation")
        }
        return conversation
    }

    /// Owner rename — `title_source='user'` keeps `chat title` and the
    /// prefix title from ever overwriting it.
    package static func rename(_ db: Database, id: Int64, title: String) throws {
        try db.execute(sql: """
            UPDATE chat_conversations SET title = ?, title_source = 'user', updated_at = ? WHERE id = ?
        """, arguments: [title, Date().timeIntervalSince1970, id])
    }

    /// First-message title (80 chars), only while nothing better exists.
    package static func setPrefixTitle(_ db: Database, id: Int64, text: String) throws {
        try db.execute(sql: """
            UPDATE chat_conversations SET title = ? WHERE id = ? AND title_source = 'prefix' AND title = ''
        """, arguments: [String(text.prefix(80)), id])
    }

    package static func pin(_ db: Database, id: Int64, pinned: Bool) throws {
        try db.execute(sql: "UPDATE chat_conversations SET pinned = ? WHERE id = ?", arguments: [pinned ? 1 : 0, id])
    }

    package static func archive(_ db: Database, id: Int64) throws {
        try db.execute(
            sql: "UPDATE chat_conversations SET archived_at = ? WHERE id = ?",
            arguments: [Date().timeIntervalSince1970, id]
        )
    }

    package static func setProject(_ db: Database, id: Int64, projectID: Int64?) throws {
        try db.execute(sql: "UPDATE chat_conversations SET project_id = ? WHERE id = ?", arguments: [projectID, id])
    }

    package static func setProviderModel(_ db: Database, id: Int64, provider: String, model: String?) throws {
        try db.execute(
            sql: "UPDATE chat_conversations SET provider = ?, model = ? WHERE id = ?",
            arguments: [provider, model, id]
        )
    }
```

Run: `make test-swift FILTER=ChatConversationQueriesTests` → PASS.

- [ ] **Step 19: Write the failing search and grouping tests**

Create `WatchtowerDesktop/Tests/Core/ChatSearchQueriesTests.swift`:

```swift
import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class ChatSearchQueriesTests: XCTestCase {
    func testFTSQueryQuotesAndPrefixesEveryToken() {
        XCTAssertEqual(ChatSearchQueries.ftsQuery(#"payments  roll-out "x""#), #""payments"* "roll"* "out"* "x"*"#)
        XCTAssertNil(ChatSearchQueries.ftsQuery("  -- "))
    }

    func testFindsMessagesWithHighlightedSnippetAndSkipsDiscussAndArchived() throws {
        let db = try TestDatabase.create()
        try db.write { d in
            let main = try TestDatabase.insertChatConversation(d, title: "Rollout")
            let msg = try TestDatabase.insertChatMessage(d, conversationID: main, role: "assistant", text: "The payments rollout slipped")
            let discuss = try TestDatabase.insertChatConversation(d, contextType: "target")
            try TestDatabase.insertChatMessage(d, conversationID: discuss, role: "user", text: "payments again")
            let archived = try TestDatabase.insertChatConversation(d)
            try TestDatabase.insertChatMessage(d, conversationID: archived, role: "user", text: "payments archived")
            try d.execute(sql: "UPDATE chat_conversations SET archived_at = 1 WHERE id = ?", arguments: [archived])

            let hits = try ChatSearchQueries.search(d, query: "payment")
            let messageHits = hits.filter { $0.messageID != nil }
            XCTAssertEqual(messageHits.map(\.messageID), [msg])
            XCTAssertTrue(messageHits[0].snippet.contains(ChatSearchQueries.markStart + "payments" + ChatSearchQueries.markEnd))
            XCTAssertEqual(String(messageHits[0].attributedSnippet.characters), "The payments rollout slipped")
        }
    }

    func testTitleHitsComeFirstAndCyrillicMatchesByPrefix() throws {
        let db = try TestDatabase.create()
        try db.write { d in
            let conv = try TestDatabase.insertChatConversation(d, title: "Платёжный релиз")
            try TestDatabase.insertChatMessage(d, conversationID: conv, role: "user", text: "платёжный шлюз упал")
            // Title LIKE is case-sensitive outside ASCII, so the query keeps
            // the title's capital; FTS (unicode61) folds case for the message.
            let hits = try ChatSearchQueries.search(d, query: "Платёж")
            XCTAssertEqual(hits.first?.messageID, nil, "the title hit is listed first")
            XCTAssertEqual(hits.count, 2)
        }
    }

    func testEmptyQueryYieldsNothing() throws {
        let db = try TestDatabase.create()
        try db.read { d in XCTAssertTrue(try ChatSearchQueries.search(d, query: "   ").isEmpty) }
    }
}
```

Create `WatchtowerDesktop/Tests/Core/ChatHistoryGroupingTests.swift`:

```swift
import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

final class ChatHistoryGroupingTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }

    private func conversations(_ ages: [(String, TimeInterval, Bool)]) throws -> [ChatConversation] {
        let db = try TestDatabase.create()
        return try db.write { d in
            for (title, age, pinned) in ages {
                try TestDatabase.insertChatConversation(
                    d, title: title, updatedAt: now.addingTimeInterval(-age).timeIntervalSince1970, pinned: pinned)
            }
            return try ChatConversationQueries.fetchAll(d)
        }
    }

    func testBucketsByDayWithPinnedFirst() throws {
        let day: TimeInterval = 86_400
        let convs = try conversations([
            ("today", 3600, false), ("yesterday", day, false), ("week", 3 * day, false),
            ("month", 20 * day, false), ("old", 60 * day, false), ("pinned-old", 90 * day, true)
        ])
        let sections = ChatHistoryGrouping.group(convs, now: now, calendar: calendar)
        XCTAssertEqual(sections.map(\.kind), [.pinned, .today, .yesterday, .previous7Days, .previous30Days, .older])
        XCTAssertEqual(sections.map { $0.conversations.map(\.title) },
                       [["pinned-old"], ["today"], ["yesterday"], ["week"], ["month"], ["old"]])
        XCTAssertEqual(sections.map(\.kind.title),
                       ["Pinned", "Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "Older"])
    }

    func testEmptyInputHasNoSections() {
        XCTAssertTrue(ChatHistoryGrouping.group([], now: now, calendar: calendar).isEmpty)
    }

    func testNewestFirstInsideASection() throws {
        let convs = try conversations([("older", 7200, false), ("newer", 60, false)])
        let today = try XCTUnwrap(ChatHistoryGrouping.group(convs, now: now, calendar: calendar).first)
        XCTAssertEqual(today.conversations.map(\.title), ["newer", "older"])
    }
}
```

- [ ] **Step 20: Run them to verify they fail**

Run: `make test-swift FILTER=ChatSearchQueriesTests` and `make test-swift FILTER=ChatHistoryGroupingTests`
Expected: FAIL — `cannot find 'ChatSearchQueries'` / `'ChatHistoryGrouping'`.

- [ ] **Step 21: Implement search**

Create `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ChatSearchQueries.swift`:

```swift
import Foundation
import GRDB

package struct ChatSearchHit: Identifiable, Equatable, Sendable {
    package let conversationID: Int64
    /// nil for a title match.
    package let messageID: Int64?
    package let title: String
    /// Match terms wrapped in `ChatSearchQueries.markStart`/`markEnd`.
    package let snippet: String

    package var id: String { "\(conversationID):\(messageID ?? 0)" }

    /// The snippet with markers removed and matched terms bold.
    package var attributedSnippet: AttributedString {
        var out = AttributedString()
        var buffer = ""
        var bold = false
        func flush() {
            var part = AttributedString(buffer)
            if bold { part.inlinePresentationIntent = .stronglyEmphasized }
            out += part
            buffer = ""
        }
        for ch in snippet {
            if String(ch) == ChatSearchQueries.markStart {
                flush()
                bold = true
            } else if String(ch) == ChatSearchQueries.markEnd {
                flush()
                bold = false
            } else {
                buffer.append(ch)
            }
        }
        flush()
        return out
    }
}

/// ⌘K search over the main chat's history: conversation titles (LIKE) and
/// message text (`chat_fts`, kept by triggers from migration 00074).
package enum ChatSearchQueries {
    package static let markStart = "\u{2}"
    package static let markEnd = "\u{3}"

    /// Owner text → an FTS5 query: every letter/number run quoted (so FTS
    /// syntax in the input is inert) and prefix-matched (`*`), AND-joined.
    package static func ftsQuery(_ raw: String) -> String? {
        let tokens = raw.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    package static func search(_ db: Database, query: String, limit: Int = 30) throws -> [ChatSearchHit] {
        guard let match = ftsQuery(query) else { return [] }
        let titles = try titleMatches(db, query: query.trimmingCharacters(in: .whitespacesAndNewlines), limit: limit)
        let messages = try messageMatches(db, match: match, limit: limit)
        return Array((titles + messages).prefix(limit))
    }

    private static func titleMatches(_ db: Database, query: String, limit: Int) throws -> [ChatSearchHit] {
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, title FROM chat_conversations
            WHERE context_type IS NULL AND archived_at IS NULL AND title LIKE ? ESCAPE '\\'
            ORDER BY updated_at DESC LIMIT ?
            """, arguments: ["%\(escaped)%", limit])
        return rows.map { row in
            let title: String = row["title"]
            return ChatSearchHit(conversationID: row["id"], messageID: nil, title: title, snippet: title)
        }
    }

    private static func messageMatches(_ db: Database, match: String, limit: Int) throws -> [ChatSearchHit] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT m.conversation_id AS cid, m.id AS mid, c.title AS title,
                   snippet(chat_fts, 0, ?, ?, '…', 12) AS snip
            FROM chat_fts
            JOIN chat_messages m ON m.id = chat_fts.rowid
            JOIN chat_conversations c ON c.id = m.conversation_id
            WHERE chat_fts MATCH ? AND c.context_type IS NULL AND c.archived_at IS NULL
              AND m.role IN ('user', 'assistant')
            ORDER BY bm25(chat_fts) LIMIT ?
            """, arguments: [markStart, markEnd, match, limit])
        return rows.map { row in
            ChatSearchHit(conversationID: row["cid"], messageID: row["mid"], title: row["title"], snippet: row["snip"])
        }
    }
}
```

- [ ] **Step 22: Implement grouping**

Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ChatHistoryGrouping.swift`:

```swift
import Foundation

package enum ChatHistorySectionKind: Int, CaseIterable, Sendable {
    case pinned, today, yesterday, previous7Days, previous30Days, older

    package var title: String {
        switch self {
        case .pinned: "Pinned"
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .previous7Days: "Previous 7 Days"
        case .previous30Days: "Previous 30 Days"
        case .older: "Older"
        }
    }
}

package struct ChatHistorySection: Identifiable, Equatable, Sendable {
    package let kind: ChatHistorySectionKind
    package let conversations: [ChatConversation]
    package var id: ChatHistorySectionKind { kind }
}

/// The left history's grouping (spec §3.1). Pure: `now` and `calendar` are
/// injected. Archived rows are skipped defensively; empty sections omitted.
package enum ChatHistoryGrouping {
    package static func group(_ conversations: [ChatConversation], now: Date, calendar: Calendar) -> [ChatHistorySection] {
        var buckets: [ChatHistorySectionKind: [ChatConversation]] = [:]
        for conv in conversations where conv.archivedAt == nil {
            buckets[kind(of: conv, now: now, calendar: calendar), default: []].append(conv)
        }
        return ChatHistorySectionKind.allCases.compactMap { kind in
            guard let items = buckets[kind], !items.isEmpty else { return nil }
            return ChatHistorySection(kind: kind, conversations: items.sorted { $0.updatedAt > $1.updatedAt })
        }
    }

    package static func kind(of conv: ChatConversation, now: Date, calendar: Calendar) -> ChatHistorySectionKind {
        if conv.pinned { return .pinned }
        let from = calendar.startOfDay(for: conv.updatedDate)
        let to = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: from, to: to).day ?? 0
        switch days {
        case ..<1: return .today
        case 1: return .yesterday
        case 2...7: return .previous7Days
        case 8...30: return .previous30Days
        default: return .older
        }
    }
}
```

- [ ] **Step 23: Run search + grouping tests**

Run: `make test-swift FILTER=ChatSearchQueriesTests` then `make test-swift FILTER=ChatHistoryGroupingTests`
Expected: PASS, PASS.

- [ ] **Step 24: DB floor test**

Create `WatchtowerDesktop/Tests/DatabaseManagerChatFloorTests.swift`:

```swift
import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerTestSupport

/// The Desktop no longer creates chat tables; it refuses a DB that goose
/// migration 00074 has not reached (chat_turn_steps is created only there).
final class DatabaseManagerChatFloorTests: XCTestCase {
    func testOpensAMigratedDatabase() throws {
        let path = try makeDB(dropping: nil)
        defer { TestDatabase.cleanup(path: path) }
        XCTAssertNoThrow(try DatabaseManager(path: path))
    }

    func testRefusesADatabaseWithoutTheChatCoreMigration() throws {
        let path = try makeDB(dropping: "chat_turn_steps")
        defer { TestDatabase.cleanup(path: path) }
        XCTAssertThrowsError(try DatabaseManager(path: path)) { error in
            guard case WatchtowerDatabaseError.missingTable(let table) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(table, "chat_turn_steps")
        }
    }

    private func makeDB(dropping table: String?) throws -> String {
        let (pool, path) = try TestDatabase.createPool()
        if let table {
            try pool.write { try $0.execute(sql: "DROP TABLE \(table)") }
        }
        try pool.close()
        return path
    }
}
```

Run: `make test-swift FILTER=DatabaseManagerChatFloorTests` → PASS (the floor was implemented in Step 9).

- [ ] **Step 25: Full chat-adjacent regression + lint**

Run: `make test-swift FILTER=Chat` then `make test-swift FILTER=Idea` then `make test-swift FILTER=Meeting` then `make lint-swift`
Expected: all PASS; lint clean.

- [ ] **Step 26: Commit**

```bash
git add WatchtowerDesktop/Sources WatchtowerDesktop/Tests
git commit -F - <<'EOF'
feat(desktop): goose-owned chat tables, branch tree and search queries

Swift stops creating chat tables (migration 00074 owns them) and gains the
branch-aware query layer: active path with the linear legacy fallback,
siblings, variant switching, turn steps, FTS history search and history
grouping. The test schema mirrors the new chat DDL.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
EOF
```

---
### Task 11: v2 event parser, turn driver, session client, policy, pool

**Files:**
- Create (Core): `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ChatEvent.swift`, `ChatCommand.swift`, `ChatSessionProcess.swift`, `ChatSessionPolicy.swift`, `LiveTurn.swift`, `ChatTurnStore.swift`, `ChatTurnDriver.swift`
- Create (app): `WatchtowerDesktop/Sources/Services/Chat/ChatSessionClient.swift`, `WatchtowerDesktop/Sources/Services/Chat/ChatSessionPool.swift`
- Create (test support): `WatchtowerDesktop/Tests/Support/FakeChatSessionProcess.swift`, `WatchtowerDesktop/Tests/Support/ChatTestSupport.swift`
- Test: `WatchtowerDesktop/Tests/Core/ChatEventTests.swift`, `ChatCommandTests.swift`, `ChatSessionPolicyTests.swift`, `LiveTurnTests.swift`, `ChatTurnDriverTests.swift`; `WatchtowerDesktop/Tests/ChatSessionClientTests.swift`, `WatchtowerDesktop/Tests/ChatSessionPoolTests.swift`

**Interfaces:**
- Consumes: Task 7/8 `watchtower ai session` flags and NDJSON v2 events; Task 10 `ChatTreeQueries.updateAssistant/setModel`, `ChatStepQueries.upsertStart/finish`, `ChatConversationQueries.updateSessionID`, `ChatSource`, `ChatStepDisplay`, `StepState`.
- Produces (Core, `package`):
  - `enum ChatEvent { sessionReady(sessionID: String?, provider: String, model: String), turnStart(turnID:), textDelta(turnID:text:), toolStart(ChatToolStart), toolEnd(ChatToolEnd), usage(ChatUsage), turnDone(turnID:status:sessionID:), error(ChatSessionError), exited(status: Int32, stderrTail: String) }` + `static func parse(_ line: String) -> ChatEvent?`. `exited` is synthesized by the process wrapper, never on the wire.
  - `ChatToolStart{turnID, id, name, argsJSON}`, `ChatToolEnd{turnID, id, ok: Bool, summary, sources}`, `ChatUsage{turnID, tokensIn, tokensOut, model}`, `ChatSessionError: Error {turnID: String?, code: ChatErrorCode, message, retryable}`, `enum ChatErrorCode: String {auth, rateLimit, providerUnavailable, sessionLost, attachmentUnsupported, interrupted, internalError}` (raw values = wire codes), `enum ChatTurnStatus: String {complete, interrupted}`.
  - `ChatCommandAttachment{path, mime, name}`, `ChatTurnCommand{turnID, text, attachments, replay}`, `enum ChatCommand { turn(ChatTurnCommand), cancel, close }` + `func jsonLine() throws -> String`.
  - `ChatTurnRequest{command: ChatTurnCommand, assistantMessageID: Int64}`.
  - `ChatContinuity.initialLeaf(resumeSessionID:activeLeafID:) -> Int64?`, `.replayNeeded(historyTipID:continuousLeafID:) -> Bool`.
  - `ChatTurnText.compose(userText:outcomes:mentions:) -> String`.
  - `protocol ChatSessionProcess: AnyObject, Sendable { var events: AsyncStream<ChatEvent>; func send(_:) throws; func terminate() }`.
  - `ChatSessionPolicy.decide(sessions: [SessionSnapshot], now: Date, wanted: Int64?) -> [PoolAction]`, nested `SessionSnapshot{conversationID, lastActivity, busy, alive}`, `PoolAction{evict(Int64), spawn(Int64)}`, constants `maxLive = 3`, `idleTTL = 600`, `pollInterval = .seconds(30)`.
  - `@MainActor @Observable LiveTurn{messageID, turnID, startedAt, text (≤30 fps), fullText, steps: [ChatStepDisplay], phase: Phase{running, complete, interrupted, failed(ChatSessionError)}, usage: ChatUsage?, persistError, endedAt; isRunning}`; `TextThrottle`.
  - `ChatTurnStore(dbPool:)`; `@MainActor @Observable ChatTurnDriver(conversationID:store:clock:)` with `liveTurn`, `sessionID`, `lastSessionError`, `begin(messageID:turnID:) -> LiveTurn`, `apply(_:)`, `finishRunningAsPartial()`, `onTurnFinished: ((LiveTurn) -> Void)?`, `flushInterval = 1`.
- Produces (app):
  - `struct ChatSessionConfig: Equatable, Sendable {conversationID, provider, model: String?, surface = "main", resumeSessionID: String?; init(conversationID:provider:model:surface:resumeSessionID:); isCompatible(with:)}` (Phase 4 adds `projectID`).
  - `@MainActor @Observable ChatSessionClient`: `conversationID`, `config`, `driver`, `isAlive`, `startupError`, `lastActivity`, `continuousLeafID`, `liveTurn`, `isBusy`, `startTurn(_ request: ChatTurnRequest)`, `adoptInitialContinuity(_:)`, `cancel(grace:)`, `close(grace:) async`, `touch()`, `onTurnFinished: ((Int64) -> Void)?`; `static func arguments(for config: ChatSessionConfig, dbPath: String?) -> [String]`.
  - `FoundationChatSessionProcess.launch(arguments:) throws -> any ChatSessionProcess`.
  - `@MainActor @Observable ChatSessionPool(dbPool:processFactory:clock:closeGrace:)`: `clients`, `lastConfig`, `onTurnFinished`, `client(for:)`, `session(for:config:) -> ChatSessionClient`, `prewarm(conversationID:config:)`, `close(conversationID:)`, `closeAll() async`, `tick()`, `startPolicy()`, `stopPolicy()`.
  - Test support: `FakeChatSessionProcess(arguments:)` (`sent`, `turns`, `terminated`, `onSend`, `sendError`, `exitsOnClose`, `emit(_:)`, `exit(status:stderr:)`, `argument(after:)`), `ChatTestClock`, `waitForCondition(timeout:_:) async -> Bool`.

- [ ] **Step 1: Write the failing event/command tests**

Create `WatchtowerDesktop/Tests/Core/ChatEventTests.swift`:

```swift
import XCTest
@testable import WatchtowerCore

final class ChatEventTests: XCTestCase {
    func testParsesEveryV2Event() {
        XCTAssertEqual(ChatEvent.parse(#"{"type":"session_ready","session_id":"s1","provider":"claude","model":"m"}"#),
                       .sessionReady(sessionID: "s1", provider: "claude", model: "m"))
        XCTAssertEqual(ChatEvent.parse(#"{"type":"session_ready","provider":"codex","model":""}"#),
                       .sessionReady(sessionID: nil, provider: "codex", model: ""))
        XCTAssertEqual(ChatEvent.parse(#"{"type":"turn_start","turn_id":"t"}"#), .turnStart(turnID: "t"))
        XCTAssertEqual(ChatEvent.parse(#"{"type":"text_delta","turn_id":"t","text":"Hi\n"}"#),
                       .textDelta(turnID: "t", text: "Hi\n"))
        XCTAssertEqual(
            ChatEvent.parse(#"{"type":"tool_start","turn_id":"t","id":"a","name":"get_jira_issue","args":{"z":1,"key":"P-1"}}"#),
            .toolStart(ChatToolStart(turnID: "t", id: "a", name: "get_jira_issue", argsJSON: #"{"key":"P-1","z":1}"#)))
        XCTAssertEqual(
            ChatEvent.parse(#"{"type":"tool_end","turn_id":"t","id":"a","ok":true,"summary":"s","sources":[{"kind":"jira","title":"P-1","url":"https://x","ref":"P-1"}]}"#),
            .toolEnd(ChatToolEnd(turnID: "t", id: "a", ok: true, summary: "s",
                                 sources: [ChatSource(kind: "jira", title: "P-1", url: "https://x", ref: "P-1")])))
        XCTAssertEqual(ChatEvent.parse(#"{"type":"usage","turn_id":"t","tokens_in":5,"tokens_out":7,"model":"m"}"#),
                       .usage(ChatUsage(turnID: "t", tokensIn: 5, tokensOut: 7, model: "m")))
        XCTAssertEqual(ChatEvent.parse(#"{"type":"turn_done","turn_id":"t","status":"interrupted","session_id":"s2"}"#),
                       .turnDone(turnID: "t", status: .interrupted, sessionID: "s2"))
        XCTAssertEqual(ChatEvent.parse(#"{"type":"error","code":"rate_limit","message":"slow","retryable":true}"#),
                       .error(ChatSessionError(turnID: nil, code: .rateLimit, message: "slow", retryable: true)))
    }

    /// Degenerate inputs: garbage, unknown types, a missing `sources` array,
    /// an unknown error code — none may crash or invent data.
    func testDegenerateLines() {
        XCTAssertNil(ChatEvent.parse("not json"))
        XCTAssertNil(ChatEvent.parse(#"{"type":"reset"}"#), "v2 has no reset")
        XCTAssertNil(ChatEvent.parse(#"{"text":"no type"}"#))
        XCTAssertEqual(ChatEvent.parse(#"{"type":"tool_end","turn_id":"t","id":"a","ok":false}"#),
                       .toolEnd(ChatToolEnd(turnID: "t", id: "a", ok: false, summary: "", sources: [])))
        XCTAssertEqual(ChatEvent.parse(#"{"type":"error","code":"weird","message":"m"}"#),
                       .error(ChatSessionError(turnID: nil, code: .internalError, message: "m", retryable: false)))
        XCTAssertEqual(ChatEvent.parse(#"{"type":"tool_start","turn_id":"t","id":"a","name":"x"}"#),
                       .toolStart(ChatToolStart(turnID: "t", id: "a", name: "x", argsJSON: "{}")))
    }
}
```

Create `WatchtowerDesktop/Tests/Core/ChatCommandTests.swift`:

```swift
import XCTest
@testable import WatchtowerCore

final class ChatCommandTests: XCTestCase {
    func testTurnLineIsOneLineOfSortedJSON() throws {
        let command = ChatCommand.turn(ChatTurnCommand(
            turnID: "t1", text: "line1\nline2",
            attachments: [ChatCommandAttachment(path: "/a/x.png", mime: "image/png", name: "x.png")],
            replay: false))
        let line = try command.jsonLine()
        XCTAssertFalse(line.contains("\n"), "a newline in the text is escaped, never breaks the JSONL frame")
        XCTAssertEqual(line, #"{"attachments":[{"mime":"image/png","name":"x.png","path":"/a/x.png"}],"replay":false,"text":"line1\nline2","turn_id":"t1","type":"turn"}"#)
    }

    /// Wire shape: no attachments is `[]`, never `null` (review-rules wire rule).
    func testEmptyAttachmentsEncodeAsEmptyArray() throws {
        let line = try ChatCommand.turn(ChatTurnCommand(turnID: "t", text: "x", attachments: [], replay: true)).jsonLine()
        XCTAssertTrue(line.contains(#""attachments":[]"#))
        XCTAssertTrue(line.contains(#""replay":true"#))
    }

    func testControlCommands() throws {
        XCTAssertEqual(try ChatCommand.cancel.jsonLine(), #"{"type":"cancel"}"#)
        XCTAssertEqual(try ChatCommand.close.jsonLine(), #"{"type":"close"}"#)
    }

    func testContinuity() {
        XCTAssertNil(ChatContinuity.initialLeaf(resumeSessionID: nil, activeLeafID: 5))
        XCTAssertNil(ChatContinuity.initialLeaf(resumeSessionID: "", activeLeafID: 5))
        XCTAssertEqual(ChatContinuity.initialLeaf(resumeSessionID: "s", activeLeafID: 5), 5)
        XCTAssertFalse(ChatContinuity.replayNeeded(historyTipID: nil, continuousLeafID: nil), "a brand-new chat")
        XCTAssertFalse(ChatContinuity.replayNeeded(historyTipID: 5, continuousLeafID: 5))
        XCTAssertTrue(ChatContinuity.replayNeeded(historyTipID: 3, continuousLeafID: 5), "regenerate/edit/branch")
        XCTAssertTrue(ChatContinuity.replayNeeded(historyTipID: 5, continuousLeafID: nil), "history the session never saw")
    }

    func testTurnTextComposition() {
        XCTAssertEqual(ChatTurnText.compose(userText: "hi", outcomes: nil, mentions: []), "hi")
        XCTAssertEqual(
            ChatTurnText.compose(userText: "hi", outcomes: "=== ACTIONS ===", mentions: ["jira:P-1", #"person:1:U1 "Anna""#]),
            "=== ACTIONS ===\n\nhi\n\nREFERENCED: jira:P-1; person:1:U1 \"Anna\"")
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `make test-swift FILTER=ChatEventTests` and `make test-swift FILTER=ChatCommandTests`
Expected: FAIL — `cannot find 'ChatEvent' in scope` / `'ChatCommand'`.

- [ ] **Step 3: Implement `ChatEvent`**

Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ChatEvent.swift`:

```swift
import Foundation

package enum ChatErrorCode: String, Equatable, Sendable {
    case auth
    case rateLimit = "rate_limit"
    case providerUnavailable = "provider_unavailable"
    case sessionLost = "session_lost"
    case attachmentUnsupported = "attachment_unsupported"
    case interrupted
    case internalError = "internal"
}

package enum ChatTurnStatus: String, Equatable, Sendable {
    case complete
    case interrupted
}

package struct ChatToolStart: Equatable, Sendable {
    package let turnID: String
    package let id: String
    package let name: String
    /// The `args` object re-serialized with sorted keys ("{}" when absent).
    package let argsJSON: String

    package init(turnID: String, id: String, name: String, argsJSON: String) {
        self.turnID = turnID
        self.id = id
        self.name = name
        self.argsJSON = argsJSON
    }
}

package struct ChatToolEnd: Equatable, Sendable {
    package let turnID: String
    package let id: String
    package let ok: Bool
    package let summary: String
    package let sources: [ChatSource]

    package init(turnID: String, id: String, ok: Bool, summary: String, sources: [ChatSource]) {
        self.turnID = turnID
        self.id = id
        self.ok = ok
        self.summary = summary
        self.sources = sources
    }
}

package struct ChatUsage: Equatable, Sendable {
    package let turnID: String
    package let tokensIn: Int
    package let tokensOut: Int
    package let model: String

    package init(turnID: String, tokensIn: Int, tokensOut: Int, model: String) {
        self.turnID = turnID
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.model = model
    }
}

package struct ChatSessionError: Error, Equatable, Sendable {
    package let turnID: String?
    package let code: ChatErrorCode
    package let message: String
    package let retryable: Bool

    package init(turnID: String?, code: ChatErrorCode, message: String, retryable: Bool) {
        self.turnID = turnID
        self.code = code
        self.message = message
        self.retryable = retryable
    }
}

/// One `watchtower ai session` protocol-v2 event (spec §1.1). There is no
/// `reset` in v2: text already shown is never wiped (CHAT-02).
package enum ChatEvent: Equatable, Sendable {
    case sessionReady(sessionID: String?, provider: String, model: String)
    case turnStart(turnID: String)
    case textDelta(turnID: String, text: String)
    case toolStart(ChatToolStart)
    case toolEnd(ChatToolEnd)
    case usage(ChatUsage)
    case turnDone(turnID: String, status: ChatTurnStatus, sessionID: String?)
    case error(ChatSessionError)
    /// Synthesized by the process wrapper when the session process exits.
    case exited(status: Int32, stderrTail: String)

    package static func parse(_ line: String) -> ChatEvent? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return nil }
        let f = Fields(json: json)
        switch type {
        case "session_ready":
            return .sessionReady(sessionID: f.optional("session_id"), provider: f.string("provider"), model: f.string("model"))
        case "turn_start":
            return .turnStart(turnID: f.string("turn_id"))
        case "text_delta":
            return .textDelta(turnID: f.string("turn_id"), text: f.string("text"))
        case "tool_start":
            return .toolStart(ChatToolStart(turnID: f.string("turn_id"), id: f.string("id"),
                                            name: f.string("name"), argsJSON: f.object("args")))
        case "tool_end":
            return .toolEnd(ChatToolEnd(turnID: f.string("turn_id"), id: f.string("id"), ok: f.bool("ok"),
                                        summary: f.string("summary"), sources: f.sources()))
        case "usage":
            return .usage(ChatUsage(turnID: f.string("turn_id"), tokensIn: f.int("tokens_in"),
                                    tokensOut: f.int("tokens_out"), model: f.string("model")))
        case "turn_done":
            // An unknown status keeps the text as partial (Continue offered) rather than claiming completion.
            let status = ChatTurnStatus(rawValue: f.string("status")) ?? .interrupted
            return .turnDone(turnID: f.string("turn_id"), status: status, sessionID: f.optional("session_id"))
        case "error":
            return .error(ChatSessionError(turnID: f.optional("turn_id"),
                                           code: ChatErrorCode(rawValue: f.string("code")) ?? .internalError,
                                           message: f.string("message"), retryable: f.bool("retryable")))
        default:
            return nil
        }
    }
}

private struct Fields {
    let json: [String: Any]

    func string(_ key: String) -> String { json[key] as? String ?? "" }

    func optional(_ key: String) -> String? {
        guard let value = json[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    func int(_ key: String) -> Int { (json[key] as? NSNumber)?.intValue ?? 0 }

    func bool(_ key: String) -> Bool { json[key] as? Bool ?? false }

    func object(_ key: String) -> String {
        guard let value = json[key], JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    func sources() -> [ChatSource] {
        let items = json["sources"] as? [[String: Any]] ?? []
        return items.map { item in
            let url = item["url"] as? String
            return ChatSource(kind: item["kind"] as? String ?? "", title: item["title"] as? String ?? "",
                              url: (url?.isEmpty ?? true) ? nil : url, ref: item["ref"] as? String ?? "")
        }
    }
}
```

- [ ] **Step 4: Implement commands, continuity, turn text, the process seam**

Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ChatCommand.swift`:

```swift
import Foundation

package struct ChatCommandAttachment: Codable, Equatable, Sendable {
    package let path: String
    package let mime: String
    package let name: String

    package init(path: String, mime: String, name: String) {
        self.path = path
        self.mime = mime
        self.name = name
    }
}

package struct ChatTurnCommand: Equatable, Sendable {
    package let turnID: String
    package let text: String
    package let attachments: [ChatCommandAttachment]
    /// The provider session is not continuous with this branch — Go rebuilds
    /// the history from `chat_messages` (spec §2.4).
    package let replay: Bool

    package init(turnID: String, text: String, attachments: [ChatCommandAttachment], replay: Bool) {
        self.turnID = turnID
        self.text = text
        self.attachments = attachments
        self.replay = replay
    }
}

/// One JSONL command on the session's stdin. Text and attachment paths
/// travel ONLY here, never on argv (CHAT-04).
package enum ChatCommand: Equatable, Sendable {
    case turn(ChatTurnCommand)
    case cancel
    case close

    package func jsonLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(Wire(self))
        return String(decoding: data, as: UTF8.self)
    }

    private struct Wire: Encodable {
        let type: String
        let turnID: String?
        let text: String?
        let attachments: [ChatCommandAttachment]?
        let replay: Bool?

        enum CodingKeys: String, CodingKey {
            case type, text, attachments, replay
            case turnID = "turn_id"
        }

        init(_ command: ChatCommand) {
            switch command {
            case let .turn(turn):
                (type, turnID, text, attachments, replay) = ("turn", turn.turnID, turn.text, turn.attachments, turn.replay)
            case .cancel:
                (type, turnID, text, attachments, replay) = ("cancel", nil, nil, nil, nil)
            case .close:
                (type, turnID, text, attachments, replay) = ("close", nil, nil, nil, nil)
            }
        }
    }
}

/// What a view model asks a session client to run.
package struct ChatTurnRequest: Equatable, Sendable {
    package let command: ChatTurnCommand
    /// The `partial` assistant row created before sending (CHAT-01).
    package let assistantMessageID: Int64

    package init(command: ChatTurnCommand, assistantMessageID: Int64) {
        self.command = command
        self.assistantMessageID = assistantMessageID
    }
}

/// Whether a provider session has seen the history a turn builds on.
/// `continuousLeafID` is the last message the live session answered — or,
/// for a session spawned with `--resume`, the conversation's leaf at spawn.
package enum ChatContinuity {
    package static func initialLeaf(resumeSessionID: String?, activeLeafID: Int64?) -> Int64? {
        guard let resumeSessionID, !resumeSessionID.isEmpty else { return nil }
        return activeLeafID
    }

    /// `historyTipID` is the parent of the user message being sent.
    package static func replayNeeded(historyTipID: Int64?, continuousLeafID: Int64?) -> Bool {
        historyTipID != continuousLeafID
    }
}

/// The text a turn sends (spec §4.3): only structured additions — the
/// actions-outcome block before, the REFERENCED block after. The persisted
/// user message keeps the owner's raw text.
package enum ChatTurnText {
    package static func compose(userText: String, outcomes: String?, mentions: [String]) -> String {
        var parts: [String] = []
        if let outcomes, !outcomes.isEmpty { parts.append(outcomes) }
        parts.append(userText)
        if !mentions.isEmpty { parts.append("REFERENCED: " + mentions.joined(separator: "; ")) }
        return parts.joined(separator: "\n\n")
    }
}
```

Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ChatSessionProcess.swift`:

```swift
import Foundation

/// The seam between a session client and the `watchtower ai session`
/// process: the real one wraps `Process`, tests use `FakeChatSessionProcess`.
/// `events` yields `.exited` and then finishes when the process ends.
package protocol ChatSessionProcess: AnyObject, Sendable {
    var events: AsyncStream<ChatEvent> { get }
    func send(_ command: ChatCommand) throws
    func terminate()
}
```

- [ ] **Step 5: Run the event/command tests**

Run: `make test-swift FILTER=ChatEventTests` then `make test-swift FILTER=ChatCommandTests`
Expected: PASS, PASS.

- [ ] **Step 6: Write the failing policy test**

Create `WatchtowerDesktop/Tests/Core/ChatSessionPolicyTests.swift`:

```swift
import XCTest
@testable import WatchtowerCore

/// CHAT-03's decision half: at most 3 live sessions, LRU eviction, idle TTL.
final class ChatSessionPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 0)
    private typealias Snap = ChatSessionPolicy.SessionSnapshot

    private func snap(_ id: Int64, idle: TimeInterval, busy: Bool = false, alive: Bool = true) -> Snap {
        Snap(conversationID: id, lastActivity: now.addingTimeInterval(-idle), busy: busy, alive: alive)
    }

    func testSpawnsWhenBelowTheBound() {
        XCTAssertEqual(ChatSessionPolicy.decide(sessions: [snap(1, idle: 5)], now: now, wanted: 2), [.spawn(2)])
    }

    func testWantedAndAliveIsANoOp() {
        XCTAssertEqual(ChatSessionPolicy.decide(sessions: [snap(1, idle: 5)], now: now, wanted: 1), [])
    }

    func testEvictsTheLeastRecentlyUsedIdleSessionAtTheBound() {
        let sessions = [snap(1, idle: 30), snap(2, idle: 90), snap(3, idle: 10)]
        XCTAssertEqual(ChatSessionPolicy.decide(sessions: sessions, now: now, wanted: 4), [.evict(2), .spawn(4)])
    }

    func testPrefersIdleOverBusyWhenEvicting() {
        let sessions = [snap(1, idle: 300, busy: true), snap(2, idle: 20), snap(3, idle: 10)]
        XCTAssertEqual(ChatSessionPolicy.decide(sessions: sessions, now: now, wanted: 4), [.evict(2), .spawn(4)])
    }

    /// The bound is hard: with three busy sessions the oldest still goes (the
    /// client persists its partial text first, CHAT-01).
    func testEvictsABusySessionWhenAllAreBusy() {
        let sessions = [snap(1, idle: 30, busy: true), snap(2, idle: 90, busy: true), snap(3, idle: 10, busy: true)]
        XCTAssertEqual(ChatSessionPolicy.decide(sessions: sessions, now: now, wanted: 4), [.evict(2), .spawn(4)])
    }

    func testIdleTTLExpiresOnlyIdleNonWantedSessions() {
        let sessions = [snap(1, idle: 600), snap(2, idle: 599), snap(3, idle: 900, busy: true), snap(4, idle: 700)]
        XCTAssertEqual(ChatSessionPolicy.decide(sessions: sessions, now: now, wanted: 4), [.evict(1)])
    }

    func testDeadSessionsAreEvictedAndRespawnedWhenWanted() {
        XCTAssertEqual(ChatSessionPolicy.decide(sessions: [snap(1, idle: 1, alive: false)], now: now, wanted: 1),
                       [.evict(1), .spawn(1)])
    }

    func testNoSessionsNoWantIsEmpty() {
        XCTAssertEqual(ChatSessionPolicy.decide(sessions: [], now: now, wanted: nil), [])
    }
}
```

- [ ] **Step 7: Run it to verify it fails**

Run: `make test-swift FILTER=ChatSessionPolicyTests`
Expected: FAIL — `cannot find 'ChatSessionPolicy' in scope`.

- [ ] **Step 8: Implement the policy**

Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ChatSessionPolicy.swift`:

```swift
import Foundation

/// Pure pool decisions (the `WarmEnginePolicy` precedent): no clock reads,
/// no I/O. `ChatSessionPool` gathers snapshots and applies the actions.
/// CHAT-03: at most `maxLive` live sessions; an idle one dies within
/// `idleTTL` + one `pollInterval`.
package enum ChatSessionPolicy {
    package static let maxLive = 3
    package static let idleTTL: TimeInterval = 10 * 60
    package static let pollInterval: Duration = .seconds(30)

    package struct SessionSnapshot: Equatable, Sendable {
        package let conversationID: Int64
        package let lastActivity: Date
        package let busy: Bool
        package let alive: Bool

        package init(conversationID: Int64, lastActivity: Date, busy: Bool, alive: Bool) {
            self.conversationID = conversationID
            self.lastActivity = lastActivity
            self.busy = busy
            self.alive = alive
        }
    }

    package enum PoolAction: Equatable, Sendable {
        case evict(Int64)
        case spawn(Int64)
    }

    package static func decide(sessions: [SessionSnapshot], now: Date, wanted: Int64?) -> [PoolAction] {
        var actions: [PoolAction] = sessions.filter { !$0.alive }.map { .evict($0.conversationID) }
        var live = sessions.filter(\.alive)
        let expired = live.filter {
            !$0.busy && $0.conversationID != wanted && now.timeIntervalSince($0.lastActivity) >= idleTTL
        }
        actions += expired.map { .evict($0.conversationID) }
        let expiredIDs = Set(expired.map(\.conversationID))
        live.removeAll { expiredIDs.contains($0.conversationID) }

        guard let wanted, !live.contains(where: { $0.conversationID == wanted }) else { return actions }
        // Idle before busy, then least recently used first.
        var candidates = live.sorted { lhs, rhs in
            lhs.busy != rhs.busy ? !lhs.busy : lhs.lastActivity < rhs.lastActivity
        }
        while live.count >= maxLive, !candidates.isEmpty {
            let victim = candidates.removeFirst()
            actions.append(.evict(victim.conversationID))
            live.removeAll { $0.conversationID == victim.conversationID }
        }
        actions.append(.spawn(wanted))
        return actions
    }
}
```

Run: `make test-swift FILTER=ChatSessionPolicyTests` → PASS.

- [ ] **Step 9: Test support — fake process, clock, wait helper**

Create `WatchtowerDesktop/Tests/Support/FakeChatSessionProcess.swift`:

```swift
import Foundation
import WatchtowerCore

/// Scripted stand-in for `watchtower ai session`. Records every command,
/// lets a test emit v2 events, and models exit/terminate. `@unchecked
/// Sendable`: `lock` guards the recorded state; the config flags are set
/// before the client starts using the fake.
package final class FakeChatSessionProcess: ChatSessionProcess, @unchecked Sendable {
    package let arguments: [String]
    package let events: AsyncStream<ChatEvent>
    private let continuation: AsyncStream<ChatEvent>.Continuation
    private let lock = NSLock()
    private var sentStorage: [ChatCommand] = []
    private var terminatedStorage = false

    /// Called synchronously inside `send`, after recording — lets a test
    /// inspect the database at the exact moment a turn goes out (CHAT-01).
    package var onSend: ((ChatCommand) -> Void)?
    package var sendError: Error?
    package var exitsOnClose = false

    package init(arguments: [String]) {
        self.arguments = arguments
        (events, continuation) = AsyncStream.makeStream(of: ChatEvent.self)
    }

    package var sent: [ChatCommand] {
        lock.lock()
        defer { lock.unlock() }
        return sentStorage
    }

    package var turns: [ChatTurnCommand] {
        sent.compactMap { command in
            if case let .turn(turn) = command { turn } else { nil }
        }
    }

    package var terminated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminatedStorage
    }

    package func argument(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    package func send(_ command: ChatCommand) throws {
        if let sendError { throw sendError }
        lock.lock()
        sentStorage.append(command)
        lock.unlock()
        onSend?(command)
        if exitsOnClose, command == .close { exit(status: 0) }
    }

    package func terminate() {
        lock.lock()
        terminatedStorage = true
        lock.unlock()
        exit(status: 15)
    }

    package func emit(_ event: ChatEvent) {
        continuation.yield(event)
    }

    package func exit(status: Int32, stderr: String = "") {
        continuation.yield(.exited(status: status, stderrTail: stderr))
        continuation.finish()
    }
}
```

Create `WatchtowerDesktop/Tests/Support/ChatTestSupport.swift`:

```swift
import Foundation

/// A settable clock for policy/driver tests (`clock: { testClock.now }`).
package final class ChatTestClock: @unchecked Sendable {
    package var now: Date

    package init(now: Date = Date(timeIntervalSinceReferenceDate: 0)) {
        self.now = now
    }

    package func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

/// Polls `condition` on the main actor until it holds or `timeout` passes (a
/// deadline, not a spin count). Returns the final verdict so the caller
/// asserts it: `XCTAssertTrue(await waitForCondition { … })`.
@MainActor
package func waitForCondition(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let start = ContinuousClock.now
    while ContinuousClock.now - start < timeout {
        if condition() { return true }
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(2))
    }
    return condition()
}
```

- [ ] **Step 10: Write the failing LiveTurn and driver tests**

Create `WatchtowerDesktop/Tests/Core/LiveTurnTests.swift`:

```swift
import XCTest
import WatchtowerTestSupport
@testable import WatchtowerCore

@MainActor
final class LiveTurnTests: XCTestCase {
    func testThrottlePublishesAtMostOncePerInterval() {
        var throttle = TextThrottle(interval: 1.0 / 30)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertTrue(throttle.shouldPublish(now: t0))
        XCTAssertFalse(throttle.shouldPublish(now: t0.addingTimeInterval(0.01)))
        XCTAssertTrue(throttle.shouldPublish(now: t0.addingTimeInterval(0.05)))
    }

    /// Deltas inside one frame accumulate in `fullText`; the published `text`
    /// catches up via the trailing flush.
    func testDeltasAccumulateAndTrailingFlushPublishes() async {
        let turn = LiveTurn(messageID: 1, turnID: "t", startedAt: Date())
        let now = Date()
        turn.appendDelta("Hel", now: now)
        turn.appendDelta("lo", now: now)
        XCTAssertEqual(turn.fullText, "Hello")
        XCTAssertEqual(turn.text, "Hel", "the second delta is inside the same frame")
        let flushed = await waitForCondition { turn.text == "Hello" }
        XCTAssertTrue(flushed)
    }

    func testStepsStartAndFinish() {
        let turn = LiveTurn(messageID: 1, turnID: "t", startedAt: Date())
        let seq = turn.startStep(ChatToolStart(turnID: "t", id: "a", name: "get_jira_issue", argsJSON: "{}"), at: Date())
        XCTAssertEqual(seq, 0)
        turn.finishStep(ChatToolEnd(turnID: "t", id: "a", ok: false, summary: "nope", sources: []), at: Date())
        XCTAssertEqual(turn.steps.map(\.state), [.failed])
        XCTAssertEqual(turn.steps.first?.summary, "nope")
    }

    func testFinishPublishesFullTextAndStopsRunning() {
        let turn = LiveTurn(messageID: 1, turnID: "t", startedAt: Date())
        let now = Date()
        turn.appendDelta("a", now: now)
        turn.appendDelta("b", now: now)
        turn.finish(.complete, at: now)
        XCTAssertEqual(turn.text, "ab")
        XCTAssertFalse(turn.isRunning)
    }
}
```

Create `WatchtowerDesktop/Tests/Core/ChatTurnDriverTests.swift`:

```swift
import XCTest
import GRDB
import WatchtowerTestSupport
@testable import WatchtowerCore

@MainActor
final class ChatTurnDriverTests: XCTestCase {
    private var pool: DatabasePool!
    private var path: String!
    private var clock: ChatTestClock!
    private var conversationID: Int64 = 0
    private var messageID: Int64 = 0

    override func setUpWithError() throws {
        (pool, path) = try TestDatabase.createPool()
        clock = ChatTestClock()
        (conversationID, messageID) = try pool.write { d in
            let conv = try TestDatabase.insertChatConversation(d)
            let msg = try ChatTreeQueries.insertAssistant(
                d, conversationID: conv, parentID: nil, turnID: "t", provider: "claude", model: "")
            return (conv, msg.id)
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
    }

    private func makeDriver() -> ChatTurnDriver {
        let clock = self.clock!
        return ChatTurnDriver(conversationID: conversationID, store: ChatTurnStore(dbPool: pool), clock: { clock.now })
    }

    private func row() throws -> ChatMessageRecord {
        let id = messageID
        return try XCTUnwrap(pool.read { d in
            try ChatMessageRecord.fetchOne(d, sql: "SELECT * FROM chat_messages WHERE id = ?", arguments: [id])
        })
    }

    func testTextIsFlushedAtMostOncePerSecondThenCompleted() throws {
        let driver = makeDriver()
        driver.begin(messageID: messageID, turnID: "t")
        driver.apply(.textDelta(turnID: "t", text: "Hel"))
        XCTAssertEqual(try row().text, "Hel", "the first delta flushes (no flush yet)")
        driver.apply(.textDelta(turnID: "t", text: "lo"))
        XCTAssertEqual(try row().text, "Hel", "inside the flush interval")
        clock.advance(1.1)
        driver.apply(.textDelta(turnID: "t", text: "!"))
        XCTAssertEqual(try row().text, "Hello!")
        XCTAssertEqual(try row().status, "partial")

        var finished: LiveTurn?
        driver.onTurnFinished = { finished = $0 }
        driver.apply(.usage(ChatUsage(turnID: "t", tokensIn: 3, tokensOut: 4, model: "model-b")))
        driver.apply(.turnDone(turnID: "t", status: .complete, sessionID: "s9"))
        let done = try row()
        XCTAssertEqual(done.status, "complete")
        XCTAssertEqual(done.tokensOut, 4)
        XCTAssertEqual(done.model, "model-b")
        XCTAssertNil(driver.liveTurn)
        XCTAssertEqual(finished?.messageID, messageID)
        let conv = conversationID
        let session = try pool.read { d in try ChatConversationQueries.fetchByID(d, id: conv)?.sessionID }
        XCTAssertEqual(session, "s9")
    }

    /// CHAT-02: every tool call is persisted as it happens.
    func testToolStepsArePersistedImmediately() throws {
        let driver = makeDriver()
        let msg = messageID
        driver.begin(messageID: msg, turnID: "t")
        driver.apply(.toolStart(ChatToolStart(turnID: "t", id: "a", name: "search_knowledge", argsJSON: "{}")))
        var steps = try pool.read { d in try ChatStepQueries.fetch(d, messageIDs: [msg])[msg] ?? [] }
        XCTAssertEqual(steps.map(\.state), [.running])
        driver.apply(.toolEnd(ChatToolEnd(turnID: "t", id: "a", ok: true, summary: "3 hits",
                                          sources: [ChatSource(kind: "slack", title: "x", url: nil, ref: "r")])))
        steps = try pool.read { d in try ChatStepQueries.fetch(d, messageIDs: [msg])[msg] ?? [] }
        XCTAssertEqual(steps.map(\.state), [.succeeded])
        XCTAssertEqual(steps.first?.sources.map(\.ref), ["r"])
    }

    func testInterruptedAndExitedKeepPartialText() throws {
        let driver = makeDriver()
        driver.begin(messageID: messageID, turnID: "t")
        driver.apply(.textDelta(turnID: "t", text: "part"))
        driver.apply(.turnDone(turnID: "t", status: .interrupted, sessionID: nil))
        XCTAssertEqual(try row().status, "partial")
        XCTAssertEqual(try row().text, "part")

        driver.begin(messageID: messageID, turnID: "t2")
        driver.apply(.textDelta(turnID: "t2", text: "more"))
        driver.apply(.exited(status: 9, stderrTail: ""))
        XCTAssertEqual(try row().text, "more")
        XCTAssertEqual(try row().status, "partial")
    }

    func testErrorMarksTheRowWithItsCode() throws {
        let driver = makeDriver()
        driver.begin(messageID: messageID, turnID: "t")
        driver.apply(.error(ChatSessionError(turnID: "t", code: .rateLimit, message: "slow", retryable: true)))
        XCTAssertEqual(try row().status, "error")
        XCTAssertEqual(try row().errorCode, "rate_limit")
    }

    func testEventsForAnotherTurnAreIgnored() {
        let driver = makeDriver()
        driver.begin(messageID: messageID, turnID: "t")
        driver.apply(.textDelta(turnID: "stale", text: "zzz"))
        driver.apply(.turnDone(turnID: "stale", status: .complete, sessionID: nil))
        XCTAssertEqual(driver.liveTurn?.fullText, "")
        XCTAssertEqual(driver.liveTurn?.isRunning, true)
    }

    /// A session-level error with no running turn is remembered, not dropped.
    func testSessionErrorWithoutATurnIsKept() {
        let driver = makeDriver()
        driver.apply(.error(ChatSessionError(turnID: nil, code: .auth, message: "login", retryable: false)))
        XCTAssertEqual(driver.lastSessionError?.code, .auth)
    }
}
```

- [ ] **Step 11: Run them to verify they fail**

Run: `make test-swift FILTER=LiveTurnTests` and `make test-swift FILTER=ChatTurnDriverTests`
Expected: FAIL — `cannot find 'LiveTurn'` / `'ChatTurnDriver'`.

- [ ] **Step 12: Implement `LiveTurn`**

Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/LiveTurn.swift`:

```swift
import Foundation
import Observation

/// Publishes at most once per `interval` (≈30 fps for streaming markdown).
package struct TextThrottle: Sendable {
    package let interval: TimeInterval
    private var lastPublish: Date?

    package init(interval: TimeInterval) {
        self.interval = interval
    }

    package mutating func shouldPublish(now: Date) -> Bool {
        if let lastPublish, now.timeIntervalSince(lastPublish) < interval { return false }
        lastPublish = now
        return true
    }
}

/// The one streaming assistant message. Its own observable, so only the row
/// showing it re-renders on a delta — the thread array and every finished
/// row stay untouched (render isolation, skeleton Review Focus #5).
@MainActor
@Observable
package final class LiveTurn {
    package enum Phase: Equatable {
        case running
        case complete
        case interrupted
        case failed(ChatSessionError)
    }

    package let messageID: Int64
    package let turnID: String
    package let startedAt: Date
    /// Throttled copy of `fullText` for rendering.
    package private(set) var text = ""
    package private(set) var steps: [ChatStepDisplay] = []
    package private(set) var phase: Phase = .running
    package private(set) var endedAt: Date?
    package private(set) var usage: ChatUsage?
    package internal(set) var persistError: String?

    /// Authoritative text — what is persisted.
    @ObservationIgnored package private(set) var fullText = ""
    @ObservationIgnored private var throttle: TextThrottle
    @ObservationIgnored private var trailingFlush: Task<Void, Never>?

    package init(messageID: Int64, turnID: String, startedAt: Date, publishInterval: TimeInterval = 1.0 / 30) {
        self.messageID = messageID
        self.turnID = turnID
        self.startedAt = startedAt
        throttle = TextThrottle(interval: publishInterval)
    }

    package var isRunning: Bool { phase == .running }

    package func appendDelta(_ chunk: String, now: Date) {
        fullText += chunk
        if throttle.shouldPublish(now: now) {
            text = fullText
            return
        }
        guard trailingFlush == nil else { return }
        let delay = Duration.milliseconds(Int(throttle.interval * 1000) + 1)
        trailingFlush = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.text = self.fullText
            self.trailingFlush = nil
        }
    }

    @discardableResult
    package func startStep(_ start: ChatToolStart, at date: Date) -> Int {
        if let index = steps.firstIndex(where: { $0.id == start.id }) { return index }
        steps.append(ChatStepDisplay(id: start.id, name: start.name, argsJSON: start.argsJSON, state: .running,
                                     summary: "", sources: [], startedAt: date, endedAt: nil))
        return steps.count - 1
    }

    package func finishStep(_ end: ChatToolEnd, at date: Date) {
        guard let index = steps.firstIndex(where: { $0.id == end.id }) else {
            steps.append(ChatStepDisplay(id: end.id, name: "", argsJSON: "{}", state: end.ok ? .succeeded : .failed,
                                         summary: end.summary, sources: end.sources, startedAt: date, endedAt: date))
            return
        }
        steps[index].state = end.ok ? .succeeded : .failed
        steps[index].summary = end.summary
        steps[index].sources = end.sources
        steps[index].endedAt = date
    }

    package func setUsage(_ usage: ChatUsage) {
        self.usage = usage
    }

    package func finish(_ phase: Phase, at date: Date) {
        trailingFlush?.cancel()
        trailingFlush = nil
        text = fullText
        endedAt = date
        self.phase = phase
    }
}
```

- [ ] **Step 13: Implement the store and the driver**

Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ChatTurnStore.swift`:

```swift
import Foundation
import GRDB

/// The writes a running turn makes. Swift is the only writer of these rows
/// (spec §2.2); every write is synchronous and small.
package struct ChatTurnStore: Sendable {
    package let dbPool: DatabasePool

    package init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    package func saveProgress(messageID: Int64, text: String, status: String, usage: ChatUsage?, errorCode: String?) throws {
        try dbPool.write { db in
            try ChatTreeQueries.updateAssistant(db, id: messageID, text: text, status: status,
                                                tokensIn: usage?.tokensIn, tokensOut: usage?.tokensOut, errorCode: errorCode)
            if let model = usage?.model, !model.isEmpty {
                try ChatTreeQueries.setModel(db, messageID: messageID, model: model)
            }
        }
    }

    package func stepStarted(messageID: Int64, seq: Int, start: ChatToolStart, at date: Date) throws {
        try dbPool.write { db in
            try ChatStepQueries.upsertStart(db, messageID: messageID, seq: seq, toolID: start.id, name: start.name,
                                            argsJSON: start.argsJSON, startedAt: date.timeIntervalSince1970)
        }
    }

    package func stepFinished(messageID: Int64, end: ChatToolEnd, at date: Date) throws {
        try dbPool.write { db in
            try ChatStepQueries.finish(db, messageID: messageID, toolID: end.id, ok: end.ok, summary: end.summary,
                                       sourcesJSON: ChatSource.encodeList(end.sources), endedAt: date.timeIntervalSince1970)
        }
    }

    package func saveSessionID(conversationID: Int64, sessionID: String) throws {
        try dbPool.write { db in
            try ChatConversationQueries.updateSessionID(db, id: conversationID, sessionID: sessionID)
        }
    }
}
```

Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ChatTurnDriver.swift`:

```swift
import Foundation
import Observation

/// Folds a session's v2 events into the live turn AND the database. Owned by
/// the session client (app-lifetime, on the pool), never by a view model —
/// so a turn keeps persisting when the owner navigates away (CHAT-01,
/// skeleton Review Focus #3).
@MainActor
@Observable
package final class ChatTurnDriver {
    package static let flushInterval: TimeInterval = 1

    package private(set) var liveTurn: LiveTurn?
    package private(set) var sessionID: String?
    package private(set) var lastSessionError: ChatSessionError?

    @ObservationIgnored package let conversationID: Int64
    @ObservationIgnored package var onTurnFinished: ((LiveTurn) -> Void)?
    @ObservationIgnored private let store: ChatTurnStore
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var lastFlush = Date.distantPast

    package init(conversationID: Int64, store: ChatTurnStore, clock: @escaping () -> Date = Date.init) {
        self.conversationID = conversationID
        self.store = store
        self.clock = clock
    }

    @discardableResult
    package func begin(messageID: Int64, turnID: String) -> LiveTurn {
        let turn = LiveTurn(messageID: messageID, turnID: turnID, startedAt: clock())
        liveTurn = turn
        lastFlush = .distantPast
        return turn
    }

    package func apply(_ event: ChatEvent) {
        switch event {
        case let .sessionReady(sid, _, _):
            recordSession(sid)
        case .turnStart:
            break
        case let .textDelta(turnID, text):
            guard let turn = running(turnID) else { return }
            turn.appendDelta(text, now: clock())
            flushIfDue(turn)
        case let .toolStart(start):
            stepStarted(start)
        case let .toolEnd(end):
            stepFinished(end)
        case let .usage(usage):
            running(usage.turnID)?.setUsage(usage)
        case let .turnDone(turnID, status, sid):
            recordSession(sid)
            guard running(turnID) != nil else { return }
            finalize(status == .complete ? .complete : .interrupted)
        case let .error(error):
            handle(error)
        case .exited:
            finishRunningAsPartial()
        }
    }

    /// Stop watchdog, process death, eviction, app quit: whatever was
    /// streamed stays, as `partial` (CHAT-01).
    package func finishRunningAsPartial() {
        finalize(.interrupted)
    }

    // MARK: - Private

    private func running(_ turnID: String) -> LiveTurn? {
        guard let turn = liveTurn, turn.isRunning, turn.turnID == turnID else { return nil }
        return turn
    }

    private func recordSession(_ sid: String?) {
        guard let sid, !sid.isEmpty, sid != sessionID else { return }
        sessionID = sid
        do {
            try store.saveSessionID(conversationID: conversationID, sessionID: sid)
        } catch {
            liveTurn?.persistError = "Couldn't save the session id: \(error.localizedDescription)"
        }
    }

    private func stepStarted(_ start: ChatToolStart) {
        guard let turn = running(start.turnID) else { return }
        let seq = turn.startStep(start, at: clock())
        let now = clock()
        persist(turn) { try store.stepStarted(messageID: turn.messageID, seq: seq, start: start, at: now) }
    }

    private func stepFinished(_ end: ChatToolEnd) {
        guard let turn = running(end.turnID) else { return }
        let now = clock()
        turn.finishStep(end, at: now)
        persist(turn) { try store.stepFinished(messageID: turn.messageID, end: end, at: now) }
        flush(turn, status: "partial", errorCode: nil)
    }

    private func handle(_ error: ChatSessionError) {
        guard let turn = liveTurn, turn.isRunning, error.turnID == nil || error.turnID == turn.turnID else {
            lastSessionError = error
            return
        }
        finalize(.failed(error))
    }

    private func flushIfDue(_ turn: LiveTurn) {
        guard clock().timeIntervalSince(lastFlush) >= Self.flushInterval else { return }
        flush(turn, status: "partial", errorCode: nil)
    }

    private func flush(_ turn: LiveTurn, status: String, errorCode: String?) {
        lastFlush = clock()
        persist(turn) {
            try store.saveProgress(messageID: turn.messageID, text: turn.fullText, status: status,
                                   usage: turn.usage, errorCode: errorCode)
        }
    }

    private func persist(_ turn: LiveTurn, _ write: () throws -> Void) {
        do {
            try write()
        } catch {
            turn.persistError = "Couldn't save the reply: \(error.localizedDescription)"
        }
    }

    private func finalize(_ phase: LiveTurn.Phase) {
        guard let turn = liveTurn, turn.isRunning else { return }
        turn.finish(phase, at: clock())
        switch phase {
        case .complete: flush(turn, status: "complete", errorCode: nil)
        case let .failed(error): flush(turn, status: "error", errorCode: error.code.rawValue)
        case .interrupted, .running: flush(turn, status: "partial", errorCode: nil)
        }
        liveTurn = nil
        onTurnFinished?(turn)
    }
}
```

- [ ] **Step 14: Run the LiveTurn and driver tests**

Run: `make test-swift FILTER=LiveTurnTests` then `make test-swift FILTER=ChatTurnDriverTests`
Expected: PASS, PASS.

- [ ] **Step 15: Write the failing client tests**

Create `WatchtowerDesktop/Tests/ChatSessionClientTests.swift`:

```swift
import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class ChatSessionClientTests: XCTestCase {
    private var dbPool: DatabasePool!
    private var path: String!
    private var conversationID: Int64 = 0
    private var assistantID: Int64 = 0

    override func setUpWithError() throws {
        (dbPool, path) = try TestDatabase.createPool()
        (conversationID, assistantID) = try dbPool.write { d in
            let conv = try TestDatabase.insertChatConversation(d)
            let asst = try ChatTreeQueries.insertAssistant(d, conversationID: conv, parentID: nil, turnID: "t1",
                                                           provider: "claude", model: "")
            return (conv, asst.id)
        }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: path)
    }

    private func config() -> ChatSessionConfig {
        ChatSessionConfig(conversationID: conversationID, provider: "claude", model: nil)
    }

    private func makeClient(_ spawn: () throws -> any ChatSessionProcess) -> ChatSessionClient {
        ChatSessionClient(config: config(), spawn: spawn, store: ChatTurnStore(dbPool: dbPool), clock: Date.init)
    }

    private func request(_ text: String = "hi") -> ChatTurnRequest {
        ChatTurnRequest(command: ChatTurnCommand(turnID: "t1", text: text, attachments: [], replay: false),
                        assistantMessageID: assistantID)
    }

    private func row() throws -> ChatMessageRecord {
        let id = assistantID
        return try XCTUnwrap(dbPool.read { d in
            try ChatMessageRecord.fetchOne(d, sql: "SELECT * FROM chat_messages WHERE id = ?", arguments: [id])
        })
    }

    func testArgumentsCarryOnlyFlags() {
        var cfg = ChatSessionConfig(conversationID: 7, provider: "claude", model: "model-b", resumeSessionID: "s1")
        XCTAssertEqual(ChatSessionClient.arguments(for: cfg, dbPath: "/tmp/w.db"),
                       ["ai", "session", "--conversation", "7", "--provider", "claude", "--surface", "main",
                        "--model", "model-b", "--resume", "s1", "--db-path", "/tmp/w.db"])
        cfg.model = nil
        cfg.resumeSessionID = ""
        XCTAssertEqual(ChatSessionClient.arguments(for: cfg, dbPath: nil),
                       ["ai", "session", "--conversation", "7", "--provider", "claude", "--surface", "main"])
    }

    /// CHAT-04 (Swift half): the session argv is built from the config
    /// alone — the turn text and attachment paths exist only in the stdin
    /// command.
    func testChat04SessionArgvNeverCarriesContent() throws {
        let cfg = ChatSessionConfig(conversationID: 7, provider: "claude", model: nil, resumeSessionID: "s1")
        let args = ChatSessionClient.arguments(for: cfg, dbPath: "/tmp/w.db").joined(separator: " ")
        let turn = ChatCommand.turn(ChatTurnCommand(
            turnID: "t", text: "SECRET-TEXT",
            attachments: [ChatCommandAttachment(path: "/tmp/SECRET.pdf", mime: "application/pdf", name: "SECRET.pdf")],
            replay: false))
        XCTAssertFalse(args.contains("SECRET"))
        XCTAssertTrue(try turn.jsonLine().contains("SECRET-TEXT"))
        XCTAssertTrue(try turn.jsonLine().contains("/tmp/SECRET.pdf"))
    }

    func testTurnStreamsIntoTheDatabaseAndReportsCompletion() async throws {
        let fake = FakeChatSessionProcess(arguments: [])
        let client = makeClient { fake }
        var finished: [Int64] = []
        client.onTurnFinished = { finished.append($0) }
        client.startTurn(request())
        XCTAssertEqual(fake.turns.map(\.text), ["hi"])
        XCTAssertTrue(client.isBusy)

        fake.emit(.textDelta(turnID: "t1", text: "Hello"))
        fake.emit(.turnDone(turnID: "t1", status: .complete, sessionID: "s1"))
        let done = await waitForCondition { !client.isBusy }
        XCTAssertTrue(done)
        XCTAssertEqual(try row().text, "Hello")
        XCTAssertEqual(try row().status, "complete")
        XCTAssertEqual(finished, [conversationID])
        XCTAssertEqual(client.continuousLeafID, assistantID, "the session has now seen this answer")
    }

    /// A spawn failure never throws at the caller: the turn fails visibly.
    func testSpawnFailureFailsTheTurnWithProviderUnavailable() throws {
        struct Boom: Error {}
        let client = makeClient { throw Boom() }
        XCTAssertFalse(client.isAlive)
        XCTAssertEqual(client.startupError?.code, .providerUnavailable)
        client.startTurn(request())
        XCTAssertEqual(try row().status, "error")
        XCTAssertEqual(try row().errorCode, "provider_unavailable")
    }

    func testProcessDeathKeepsPartialTextAndMarksTheClientDead() async throws {
        let fake = FakeChatSessionProcess(arguments: [])
        let client = makeClient { fake }
        client.startTurn(request())
        fake.emit(.textDelta(turnID: "t1", text: "half"))
        fake.exit(status: 9)
        let dead = await waitForCondition { !client.isAlive }
        XCTAssertTrue(dead)
        XCTAssertEqual(try row().text, "half")
        XCTAssertEqual(try row().status, "partial")
    }

    /// Stop without a `turn_done` (a hung provider): the watchdog keeps the
    /// partial text and kills the process.
    func testCancelWatchdogFinishesTheTurnWhenNoTurnDoneArrives() async throws {
        let fake = FakeChatSessionProcess(arguments: [])
        let client = makeClient { fake }
        client.startTurn(request())
        fake.emit(.textDelta(turnID: "t1", text: "stuck"))
        _ = await waitForCondition { client.liveTurn?.fullText == "stuck" }
        client.cancel(grace: .milliseconds(20))
        XCTAssertEqual(fake.sent.last, .cancel)
        let finished = await waitForCondition { !client.isBusy && fake.terminated }
        XCTAssertTrue(finished)
        XCTAssertEqual(try row().status, "partial")
        XCTAssertEqual(try row().text, "stuck")
    }

    func testAdoptInitialContinuityOnlyBeforeTheFirstTurn() {
        let fake = FakeChatSessionProcess(arguments: [])
        let client = makeClient { fake }
        client.adoptInitialContinuity(41)
        XCTAssertEqual(client.continuousLeafID, 41)
        client.startTurn(request())
        client.adoptInitialContinuity(99)
        XCTAssertEqual(client.continuousLeafID, 41)
    }

    func testCloseSendsCloseThenTerminatesAfterGrace() async {
        let fake = FakeChatSessionProcess(arguments: [])
        let client = makeClient { fake }
        await client.close(grace: .milliseconds(20))
        XCTAssertEqual(fake.sent, [.close])
        XCTAssertTrue(fake.terminated)
        XCTAssertFalse(client.isAlive)
    }

    func testCloseDoesNotTerminateAProcessThatExitsOnItsOwn() async {
        let fake = FakeChatSessionProcess(arguments: [])
        fake.exitsOnClose = true
        let client = makeClient { fake }
        await client.close(grace: .seconds(2))
        XCTAssertFalse(fake.terminated)
    }
}
```

- [ ] **Step 16: Run it to verify it fails**

Run: `make test-swift FILTER=ChatSessionClientTests`
Expected: FAIL — `cannot find 'ChatSessionConfig' in scope`.

- [ ] **Step 17: Implement the session client and the real process**

Create `WatchtowerDesktop/Sources/Services/Chat/ChatSessionClient.swift`:

```swift
import Foundation
import GRDB
import WatchtowerCore

/// What a session process is spawned with. Every argv-affecting field
/// except `resumeSessionID` (a spawn-time hint) belongs in `isCompatible`.
struct ChatSessionConfig: Equatable, Sendable {
    var conversationID: Int64
    var provider: String
    var model: String?
    var surface: String
    var resumeSessionID: String?

    init(conversationID: Int64, provider: String, model: String?, surface: String = "main", resumeSessionID: String? = nil) {
        self.conversationID = conversationID
        self.provider = provider
        self.model = model
        self.surface = surface
        self.resumeSessionID = resumeSessionID
    }

    func isCompatible(with other: ChatSessionConfig) -> Bool {
        conversationID == other.conversationID && provider == other.provider
            && model == other.model && surface == other.surface
    }
}

/// One warm `watchtower ai session` process for one conversation. Owns the
/// turn driver, so a running turn keeps streaming into the database no
/// matter which view (if any) is showing it.
@MainActor
@Observable
final class ChatSessionClient {
    let conversationID: Int64
    let config: ChatSessionConfig
    let driver: ChatTurnDriver
    private(set) var isAlive: Bool
    private(set) var startupError: ChatSessionError?
    private(set) var lastActivity: Date
    /// The last message this provider session has seen (see `ChatContinuity`).
    var continuousLeafID: Int64?

    @ObservationIgnored var onTurnFinished: ((Int64) -> Void)?
    @ObservationIgnored private let process: (any ChatSessionProcess)?
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var exited = false
    @ObservationIgnored private var hasRunTurn = false

    init(config: ChatSessionConfig, spawn: () throws -> any ChatSessionProcess, store: ChatTurnStore, clock: @escaping () -> Date) {
        self.conversationID = config.conversationID
        self.config = config
        self.clock = clock
        self.lastActivity = clock()
        self.driver = ChatTurnDriver(conversationID: config.conversationID, store: store, clock: clock)
        do {
            process = try spawn()
            isAlive = true
        } catch {
            process = nil
            isAlive = false
            exited = true
            startupError = ChatSessionError(turnID: nil, code: .providerUnavailable,
                                            message: error.localizedDescription, retryable: true)
        }
        driver.onTurnFinished = { [weak self] turn in self?.turnFinished(turn) }
        startReading()
    }

    var liveTurn: LiveTurn? { driver.liveTurn }
    var isBusy: Bool { driver.liveTurn?.isRunning == true }

    /// The argv — flags only, never content (CHAT-04).
    static func arguments(for config: ChatSessionConfig, dbPath: String?) -> [String] {
        var args = ["ai", "session", "--conversation", String(config.conversationID),
                    "--provider", config.provider, "--surface", config.surface]
        if let model = config.model, !model.isEmpty { args += ["--model", model] }
        if let resume = config.resumeSessionID, !resume.isEmpty { args += ["--resume", resume] }
        if let dbPath, !dbPath.isEmpty { args += ["--db-path", dbPath] }
        return args
    }

    func touch() {
        lastActivity = clock()
    }

    /// Only a session that has run no turn yet may adopt the conversation's
    /// history as "already seen" (a `--resume` spawn).
    func adoptInitialContinuity(_ leafID: Int64?) {
        guard !hasRunTurn else { return }
        continuousLeafID = leafID
    }

    func startTurn(_ request: ChatTurnRequest) {
        guard !isBusy else { return }
        hasRunTurn = true
        touch()
        let command = request.command
        driver.begin(messageID: request.assistantMessageID, turnID: command.turnID)
        guard let process, isAlive else {
            failTurn(command.turnID, message: startupError?.message ?? "The chat session is not running.")
            return
        }
        do {
            try process.send(.turn(command))
        } catch {
            failTurn(command.turnID, message: error.localizedDescription)
        }
    }

    /// Stop: ask the provider to interrupt; if no `turn_done` arrives within
    /// `grace`, keep the partial text and kill the process (Go already kills
    /// its child after 5 s, so 7 s covers a Go side that hung too).
    func cancel(grace: Duration = .seconds(7)) {
        guard let turn = driver.liveTurn, turn.isRunning else { return }
        do {
            guard let process else { throw CancellationError() }
            try process.send(.cancel)
        } catch {
            driver.finishRunningAsPartial()
            return
        }
        let turnID = turn.turnID
        Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard let self, self.driver.liveTurn?.turnID == turnID else { return }
            self.driver.finishRunningAsPartial()
            self.process?.terminate()
        }
    }

    /// Quit / eviction: keep what streamed, ask politely, then SIGTERM.
    func close(grace: Duration) async {
        driver.finishRunningAsPartial()
        guard let process, !exited else {
            isAlive = false
            return
        }
        // A failed write means the pipe is already closed — the process is gone.
        try? process.send(.close)
        let deadline = ContinuousClock.now + grace
        while !exited, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if !exited { process.terminate() }
        isAlive = false
    }

    // MARK: - Private

    private func startReading() {
        guard let process else { return }
        readTask = Task { [weak self] in
            for await event in process.events {
                guard let self else { return }
                self.handle(event)
            }
            self?.processEnded()
        }
    }

    private func handle(_ event: ChatEvent) {
        touch()
        if case .exited = event {
            processEnded()
            return
        }
        driver.apply(event)
    }

    private func processEnded() {
        guard !exited else { return }
        exited = true
        isAlive = false
        driver.finishRunningAsPartial()
    }

    private func failTurn(_ turnID: String, message: String) {
        driver.apply(.error(ChatSessionError(turnID: turnID, code: .providerUnavailable, message: message, retryable: true)))
    }

    private func turnFinished(_ turn: LiveTurn) {
        // A failed turn may or may not have reached the provider: force a replay next time.
        if case .failed = turn.phase { continuousLeafID = nil } else { continuousLeafID = turn.messageID }
        touch()
        onTurnFinished?(conversationID)
    }
}

/// The real session process. Writes JSONL to stdin, parses NDJSON from
/// stdout, drains stderr concurrently (sequential pipe reads deadlock).
final class FoundationChatSessionProcess: ChatSessionProcess, @unchecked Sendable {
    let events: AsyncStream<ChatEvent>
    private let process: Process
    private let stdin: FileHandle
    private let writeLock = NSLock()

    static func launch(arguments: [String]) throws -> any ChatSessionProcess {
        guard let cliPath = Constants.findCLIPath() else { throw WatchtowerAIError.cliNotFound }
        return try FoundationChatSessionProcess(executable: cliPath, arguments: arguments)
    }

    init(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = Constants.processWorkingDirectory()
        process.environment = Constants.resolvedEnvironment()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // A write after the child died must fail with EPIPE, not kill the app with SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let (stream, continuation) = AsyncStream.makeStream(of: ChatEvent.self)
        self.events = stream
        self.process = process
        self.stdin = input.fileHandleForWriting
        try process.run()
        Self.pump(process: process, stdout: output.fileHandleForReading, stderr: errors.fileHandleForReading, into: continuation)
    }

    func send(_ command: ChatCommand) throws {
        let line = try command.jsonLine() + "\n"
        writeLock.lock()
        defer { writeLock.unlock() }
        try stdin.write(contentsOf: Data(line.utf8))
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }

    private static func pump(
        process: Process, stdout: FileHandle, stderr: FileHandle, into continuation: AsyncStream<ChatEvent>.Continuation
    ) {
        let stderrTail = Task.detached { () -> String in
            let data = stderr.readDataToEndOfFile()
            return String(decoding: data.suffix(8192), as: UTF8.self)
        }
        Task.detached {
            do {
                for try await line in stdout.bytes.lines {
                    if let event = ChatEvent.parse(line) { continuation.yield(event) }
                }
            } catch {
                // A read error means stdout closed; the exit status below says why.
            }
            process.waitUntilExit()
            continuation.yield(.exited(status: process.terminationStatus, stderrTail: await stderrTail.value))
            continuation.finish()
        }
    }
}
```

- [ ] **Step 18: Run the client tests**

Run: `make test-swift FILTER=ChatSessionClientTests`
Expected: PASS (9 tests).

- [ ] **Step 19: Write the failing pool tests**

Create `WatchtowerDesktop/Tests/ChatSessionPoolTests.swift`:

```swift
import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class ChatSessionPoolTests: XCTestCase {
    private var dbPool: DatabasePool!
    private var path: String!
    private var fakes: [FakeChatSessionProcess] = []
    private var clock: ChatTestClock!
    private var pool: ChatSessionPool!

    override func setUpWithError() throws {
        (dbPool, path) = try TestDatabase.createPool()
        fakes = []
        clock = ChatTestClock()
        let clock = self.clock!
        pool = ChatSessionPool(
            dbPool: dbPool,
            processFactory: { [unowned self] args in
                let fake = FakeChatSessionProcess(arguments: args)
                self.fakes.append(fake)
                return fake
            },
            clock: { clock.now },
            closeGrace: .milliseconds(20)
        )
    }

    override func tearDown() async throws {
        await pool.closeAll()
        TestDatabase.cleanup(path: path)
    }

    private func config(_ id: Int64, provider: String = "claude") -> ChatSessionConfig {
        ChatSessionConfig(conversationID: id, provider: provider, model: nil)
    }

    func testChat03PoolNeverRunsMoreThanThreeSessions() async {
        for id: Int64 in 1...4 {
            _ = pool.session(for: id, config: config(id))
            clock.advance(1)
        }
        XCTAssertEqual(pool.clients.count, 3)
        XCTAssertNil(pool.client(for: 1), "the least recently used session is evicted")
        let closed = await waitForCondition { self.fakes[0].terminated }
        XCTAssertTrue(closed)
        XCTAssertEqual(fakes[0].sent.first, .close, "eviction asks politely before SIGTERM")
    }

    func testChat03IdleSessionIsClosedByTheNextTickAfterTTL() async {
        _ = pool.session(for: 1, config: config(1))
        clock.advance(ChatSessionPolicy.idleTTL - 1)
        pool.tick()
        XCTAssertNotNil(pool.client(for: 1))
        clock.advance(2)
        pool.tick()
        XCTAssertNil(pool.client(for: 1))
        let closed = await waitForCondition { self.fakes[0].terminated }
        XCTAssertTrue(closed)
    }

    func testReusesACompatibleLiveSessionAndRecyclesAnIncompatibleOne() async {
        let first = pool.session(for: 1, config: config(1))
        XCTAssertTrue(pool.session(for: 1, config: config(1)) === first)
        XCTAssertEqual(fakes.count, 1)

        let second = pool.session(for: 1, config: config(1, provider: "codex"))
        XCTAssertFalse(second === first)
        XCTAssertEqual(fakes.count, 2)
        XCTAssertEqual(fakes[1].argument(after: "--provider"), "codex")
        XCTAssertEqual(pool.lastConfig?.provider, "codex")
        let closed = await waitForCondition { self.fakes[0].terminated }
        XCTAssertTrue(closed)
    }

    func testDeadSessionIsRespawnedOnNextRequest() async {
        _ = pool.session(for: 1, config: config(1))
        fakes[0].exit(status: 1)
        let dead = await waitForCondition { self.pool.client(for: 1)?.isAlive == false }
        XCTAssertTrue(dead)
        let again = pool.session(for: 1, config: config(1))
        XCTAssertTrue(again.isAlive)
        XCTAssertEqual(fakes.count, 2)
    }

    /// CHAT-03 on quit, and CHAT-01 with it: every session gets `close` then
    /// SIGTERM, and a turn still streaming keeps its text as `partial`.
    func testChat03CloseAllClosesEverySessionAndKeepsPartialText() async throws {
        let (conv, asst) = try dbPool.write { d in
            let conv = try TestDatabase.insertChatConversation(d)
            let asst = try ChatTreeQueries.insertAssistant(d, conversationID: conv, parentID: nil, turnID: "t",
                                                           provider: "claude", model: "")
            return (conv, asst.id)
        }
        let busy = pool.session(for: conv, config: config(conv))
        _ = pool.session(for: conv + 100, config: config(conv + 100))
        busy.startTurn(ChatTurnRequest(command: ChatTurnCommand(turnID: "t", text: "q", attachments: [], replay: false),
                                       assistantMessageID: asst))
        fakes[0].emit(.textDelta(turnID: "t", text: "Hel"))
        _ = await waitForCondition { busy.liveTurn?.fullText == "Hel" }

        await pool.closeAll()

        XCTAssertTrue(pool.clients.isEmpty)
        XCTAssertTrue(fakes.allSatisfy { $0.sent.contains(.close) && $0.terminated })
        let row = try XCTUnwrap(dbPool.read { d in
            try ChatMessageRecord.fetchOne(d, sql: "SELECT * FROM chat_messages WHERE id = ?", arguments: [asst])
        })
        XCTAssertEqual(row.text, "Hel")
        XCTAssertEqual(row.status, "partial")
    }

    func testTurnFinishedIsForwarded() async throws {
        var finished: [Int64] = []
        pool.onTurnFinished = { finished.append($0) }
        let asst = try dbPool.write { d in
            try ChatTreeQueries.insertAssistant(d, conversationID: TestDatabase.insertChatConversation(d),
                                                parentID: nil, turnID: "t", provider: "claude", model: "").id
        }
        let client = pool.session(for: 1, config: config(1))
        client.startTurn(ChatTurnRequest(command: ChatTurnCommand(turnID: "t", text: "q", attachments: [], replay: false),
                                         assistantMessageID: asst))
        fakes[0].emit(.turnDone(turnID: "t", status: .complete, sessionID: nil))
        let forwarded = await waitForCondition { finished == [1] }
        XCTAssertTrue(forwarded)
    }
}
```

- [ ] **Step 20: Run it to verify it fails**

Run: `make test-swift FILTER=ChatSessionPoolTests`
Expected: FAIL — `cannot find 'ChatSessionPool' in scope`.

- [ ] **Step 21: Implement the pool**

Create `WatchtowerDesktop/Sources/Services/Chat/ChatSessionPool.swift`:

```swift
import Foundation
import GRDB
import WatchtowerCore

/// App-wide owner of warm chat sessions (spec §1.4) — on `AppState`, so it
/// survives navigation (the center house pattern). All decisions come from
/// `ChatSessionPolicy`; this type only applies them. CHAT-03.
@MainActor
@Observable
final class ChatSessionPool {
    typealias ProcessFactory = @MainActor ([String]) throws -> any ChatSessionProcess

    private(set) var clients: [Int64: ChatSessionClient] = [:]
    /// The config of the most recent `session(for:config:)` request.
    @ObservationIgnored private(set) var lastConfig: ChatSessionConfig?
    /// One subscriber: the main `ChatViewModel` (reload, feed refresh, titles).
    @ObservationIgnored var onTurnFinished: ((Int64) -> Void)?

    @ObservationIgnored private let dbPool: DatabasePool
    @ObservationIgnored private let processFactory: ProcessFactory
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let closeGrace: Duration
    @ObservationIgnored private var policyTask: Task<Void, Never>?

    init(
        dbPool: DatabasePool,
        processFactory: @escaping ProcessFactory = { try FoundationChatSessionProcess.launch(arguments: $0) },
        clock: @escaping () -> Date = Date.init,
        closeGrace: Duration = .seconds(2)
    ) {
        self.dbPool = dbPool
        self.processFactory = processFactory
        self.clock = clock
        self.closeGrace = closeGrace
    }

    func client(for conversationID: Int64?) -> ChatSessionClient? {
        conversationID.flatMap { clients[$0] }
    }

    /// The live session for this conversation, spawning (and evicting to stay
    /// within the bound) when needed. Never throws: a spawn failure yields a
    /// dead client whose next turn fails visibly with `provider_unavailable`.
    func session(for conversationID: Int64, config: ChatSessionConfig) -> ChatSessionClient {
        lastConfig = config
        if let existing = clients[conversationID], existing.isAlive, existing.config.isCompatible(with: config) {
            existing.touch()
            return existing
        }
        if let stale = clients.removeValue(forKey: conversationID) { retire(stale) }
        apply(ChatSessionPolicy.decide(sessions: snapshots(), now: clock(), wanted: conversationID))
        let arguments = ChatSessionClient.arguments(for: config, dbPath: dbPool.path)
        let factory = processFactory
        let client = ChatSessionClient(config: config, spawn: { try factory(arguments) },
                                       store: ChatTurnStore(dbPool: dbPool), clock: clock)
        client.onTurnFinished = { [weak self] id in self?.onTurnFinished?(id) }
        clients[conversationID] = client
        return client
    }

    /// Opening a conversation or the first keystroke: be ready at Enter.
    func prewarm(conversationID: Int64, config: ChatSessionConfig) {
        _ = session(for: conversationID, config: config)
    }

    func close(conversationID: Int64) {
        if let client = clients.removeValue(forKey: conversationID) { retire(client) }
    }

    /// App quit: every session gets `close`, then SIGTERM after the grace.
    func closeAll() async {
        stopPolicy()
        let all = Array(clients.values)
        clients = [:]
        let grace = closeGrace
        await withTaskGroup(of: Void.self) { group in
            for client in all {
                group.addTask { await client.close(grace: grace) }
            }
        }
    }

    /// One policy poll: expire idle sessions, drop dead ones.
    func tick() {
        apply(ChatSessionPolicy.decide(sessions: snapshots(), now: clock(), wanted: nil))
    }

    func startPolicy() {
        policyTask?.cancel()
        policyTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: ChatSessionPolicy.pollInterval)
                self?.tick()
            }
        }
    }

    func stopPolicy() {
        policyTask?.cancel()
        policyTask = nil
    }

    // MARK: - Private

    private func snapshots() -> [ChatSessionPolicy.SessionSnapshot] {
        clients.values.map {
            ChatSessionPolicy.SessionSnapshot(conversationID: $0.conversationID, lastActivity: $0.lastActivity,
                                              busy: $0.isBusy, alive: $0.isAlive)
        }
    }

    private func apply(_ actions: [ChatSessionPolicy.PoolAction]) {
        for case let .evict(id) in actions {
            if let client = clients.removeValue(forKey: id) { retire(client) }
        }
    }

    private func retire(_ client: ChatSessionClient) {
        let grace = closeGrace
        Task { await client.close(grace: grace) }
    }
}
```

- [ ] **Step 22: Run the pool tests and the whole Task 11 set**

Run: `make test-swift FILTER=ChatSessionPoolTests` then `make test-swift FILTER=ChatSessionClientTests` then `make test-swift FILTER=ChatTurnDriverTests` then `make lint-swift`
Expected: PASS ×3, lint clean.

- [ ] **Step 23: Commit**

```bash
git add WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat WatchtowerDesktop/Sources/Services/Chat \
  WatchtowerDesktop/Tests/Support/FakeChatSessionProcess.swift WatchtowerDesktop/Tests/Support/ChatTestSupport.swift \
  WatchtowerDesktop/Tests/Core/ChatEventTests.swift WatchtowerDesktop/Tests/Core/ChatCommandTests.swift \
  WatchtowerDesktop/Tests/Core/ChatSessionPolicyTests.swift WatchtowerDesktop/Tests/Core/LiveTurnTests.swift \
  WatchtowerDesktop/Tests/Core/ChatTurnDriverTests.swift WatchtowerDesktop/Tests/ChatSessionClientTests.swift \
  WatchtowerDesktop/Tests/ChatSessionPoolTests.swift
git commit -m "feat(desktop): warm chat session pool with persisted turns" \
  -m "v2 event parser, JSONL commands, a turn driver that streams text/steps into the DB, the session client and an LRU/TTL pool bounded at three live sessions (CHAT-03). Turns are owned by the pool, not a view model." \
  -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 12: swift-markdown renderer shared by every chat

**Files:**
- Modify: `WatchtowerDesktop/Package.swift` (+ `Package.resolved` via `swift package resolve`)
- Create (Core): `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/MarkdownDocument.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/CodeHighlighter.swift`
- Create (app): `WatchtowerDesktop/Sources/Views/Chat/MarkdownView.swift`, `WatchtowerDesktop/Sources/Views/Chat/CodeBlockView.swift`
- Modify (replace `MarkdownText(text:` → `MarkdownView(text:`): `Sources/Views/Chat/MessageBubble.swift:39`, `Sources/Views/Targets/TargetChatView.swift:437`, `Sources/Views/Tracks/TrackChatView.swift:532`, `Sources/Views/Ideas/IdeaDiscussSection.swift:136`, `Sources/Views/Calendar/RecordingDetailTabs.swift:473,966`, `Sources/Views/Memory/MemoryNodeDetailView.swift:24`
- Modify: `WatchtowerDesktop/Sources/Utilities/MarkdownToHTML.swift:3-7` (doc comment)
- Delete: `WatchtowerDesktop/Sources/Views/Chat/MarkdownText.swift`, `WatchtowerDesktop/Tests/MarkdownTextTests.swift`
- Test: `WatchtowerDesktop/Tests/Core/MarkdownDocumentTests.swift`, `WatchtowerDesktop/Tests/Core/CodeHighlighterTests.swift`, `WatchtowerDesktop/Tests/MarkdownViewTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces (Core, `package`): `MarkdownDocument.parse(_ text: String) -> [MarkdownBlock]` (memoized); `indirect enum MarkdownBlock { heading(level: Int, inlines: [MarkdownInline]), paragraph([MarkdownInline]), code(language: String?, code: String), list(MarkdownList), quote([MarkdownBlock]), table(MarkdownTable), rule }`; `MarkdownList{ordered, start, items: [MarkdownListItem]}`; `MarkdownListItem{task: MarkdownTaskState, blocks}`; `MarkdownTaskState{none, checked, unchecked}`; `MarkdownTable{header: [[MarkdownInline]], rows: [[[MarkdownInline]]], alignments: [MarkdownAlignment]}`; `MarkdownAlignment{leading, center, trailing}`; `indirect enum MarkdownInline { text, emphasis, strong, strikethrough, code, link(destination:children:), lineBreak, softBreak }`; `MarkdownInlineRenderer.attributed(_:) -> AttributedString`; `CodeHighlighter.tokens(_ code: String, language: String?) -> [CodeToken]`, `CodeToken{kind: Kind{plain, keyword, string, comment, number}, text}`.
- Produces (app): `MarkdownView(text:)` (replaces every `MarkdownText`), `MarkdownView.inlineText(_:) -> AttributedString` (link-sanitized), `CodeBlockView(language:code:)`.

- [ ] **Step 1: Add the dependency**

In `WatchtowerDesktop/Package.swift` replace the line `// swift-markdown removed: MarkdownText uses Foundation's AttributedString(markdown:)` with:

```swift
        // Markdown AST for the shared chat renderer (tables, task lists, fences).
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.5.0"),
```

and add to the `WatchtowerCore` target's `dependencies`:

```swift
                .product(name: "Markdown", package: "swift-markdown"),
```

Run: `cd WatchtowerDesktop && swift package resolve > /tmp/wt-resolve.log 2>&1; echo "exit $?"`
Expected: `exit 0`; `Package.resolved` gains `swift-markdown` and `swift-cmark`.

- [ ] **Step 2: Write the failing AST tests**

Create `WatchtowerDesktop/Tests/Core/MarkdownDocumentTests.swift`:

```swift
import XCTest
@testable import WatchtowerCore

final class MarkdownDocumentTests: XCTestCase {
    func testHeadingParagraphAndInlines() {
        XCTAssertEqual(MarkdownDocument.parse("# T **b**\n\nx *i* `c` ~~s~~ [l](https://a.b)"), [
            .heading(level: 1, inlines: [.text("T "), .strong([.text("b")])]),
            .paragraph([.text("x "), .emphasis([.text("i")]), .text(" "), .code("c"), .text(" "),
                        .strikethrough([.text("s")]), .text(" "), .link(destination: "https://a.b", children: [.text("l")])])
        ])
    }

    func testNestedListsAndTasks() {
        let blocks = MarkdownDocument.parse("- a\n  - b\n- [x] done\n- [ ] todo")
        XCTAssertEqual(blocks, [.list(MarkdownList(ordered: false, start: 1, items: [
            MarkdownListItem(task: .none, blocks: [
                .paragraph([.text("a")]),
                .list(MarkdownList(ordered: false, start: 1, items: [MarkdownListItem(task: .none, blocks: [.paragraph([.text("b")])])]))
            ]),
            MarkdownListItem(task: .checked, blocks: [.paragraph([.text("done")])]),
            MarkdownListItem(task: .unchecked, blocks: [.paragraph([.text("todo")])])
        ]))])
    }

    func testOrderedListKeepsItsStart() {
        guard case let .list(list) = MarkdownDocument.parse("3. c\n4. d").first else { return XCTFail("no list") }
        XCTAssertTrue(list.ordered)
        XCTAssertEqual(list.start, 3)
    }

    func testTable() {
        XCTAssertEqual(MarkdownDocument.parse("| A | B |\n|:--|--:|\n| 1 | 2 |"), [.table(MarkdownTable(
            header: [[.text("A")], [.text("B")]],
            rows: [[[.text("1")], [.text("2")]]],
            alignments: [.leading, .trailing]))])
    }

    func testFencedCodeQuoteAndRule() {
        XCTAssertEqual(MarkdownDocument.parse("```go\nx := 1\n```\n\n> q\n\n---"), [
            .code(language: "go", code: "x := 1"),
            .quote([.paragraph([.text("q")])]),
            .rule
        ])
    }

    /// Streaming: a fence not yet closed renders as code, not as prose that
    /// jumps into a code block when the closing fence arrives.
    func testUnterminatedFenceIsCode() {
        XCTAssertEqual(MarkdownDocument.parse("Here:\n```swift\nlet x = 1"), [
            .paragraph([.text("Here:")]),
            .code(language: "swift", code: "let x = 1")
        ])
    }

    func testEmptyAndSoftBreaks() {
        XCTAssertEqual(MarkdownDocument.parse(""), [])
        XCTAssertEqual(MarkdownDocument.parse("a\nb"), [.paragraph([.text("a"), .softBreak, .text("b")])])
    }

    func testAttributedInlinesKeepIntentsAndLinks() {
        let attr = MarkdownInlineRenderer.attributed([.strong([.text("b")]), .link(destination: "https://x.y", children: [.text("l")])])
        XCTAssertEqual(String(attr.characters), "bl")
        XCTAssertTrue(attr.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(attr.runs.contains { $0.link?.absoluteString == "https://x.y" })
    }

    func testParseIsMemoizedAndPure() {
        let text = "## H\n\n- one\n- two"
        XCTAssertEqual(MarkdownDocument.parse(text), MarkdownDocument.parse(text))
    }
}
```

Create `WatchtowerDesktop/Tests/Core/CodeHighlighterTests.swift`:

```swift
import XCTest
@testable import WatchtowerCore

final class CodeHighlighterTests: XCTestCase {
    private func kinds(_ code: String, _ lang: String?) -> [(CodeToken.Kind, String)] {
        CodeHighlighter.tokens(code, language: lang).map { ($0.kind, $0.text) }
    }

    func testSwiftLine() {
        let tokens = CodeHighlighter.tokens(#"let x = "a" // c"#, language: "swift")
        XCTAssertEqual(tokens.first, CodeToken(kind: .keyword, text: "let"))
        XCTAssertTrue(tokens.contains(CodeToken(kind: .string, text: #""a""#)))
        XCTAssertEqual(tokens.last, CodeToken(kind: .comment, text: "// c"))
    }

    func testPythonHashCommentAndNumber() {
        let tokens = CodeHighlighter.tokens("def f(): return 42 # done", language: "py")
        XCTAssertEqual(tokens.first, CodeToken(kind: .keyword, text: "def"))
        XCTAssertTrue(tokens.contains(CodeToken(kind: .number, text: "42")))
        XCTAssertEqual(tokens.last, CodeToken(kind: .comment, text: "# done"))
    }

    func testBlockCommentAndSQLKeywordsAreCaseInsensitive() {
        XCTAssertTrue(CodeHighlighter.tokens("/* a\nb */ x", language: "go").contains(CodeToken(kind: .comment, text: "/* a\nb */")))
        XCTAssertEqual(CodeHighlighter.tokens("select 1", language: "sql").first, CodeToken(kind: .keyword, text: "select"))
    }

    /// Lossless for every language and for unknown ones; never crashes on an
    /// unterminated string or comment.
    func testTokensConcatenateBackToTheInput() {
        let samples = [#"let s = "unterminated"#, "/* open", "x = 'y' + `z` 0x1F", "Привет мир 3.14"]
        for lang in ["swift", "go", "python", "js", "json", "sql", "bash", "yaml", "rust", "unknown-lang", nil] {
            for sample in samples {
                XCTAssertEqual(CodeHighlighter.tokens(sample, language: lang).map(\.text).joined(), sample)
            }
        }
    }

    func testUnknownLanguageIsOnePlainToken() {
        XCTAssertEqual(CodeHighlighter.tokens("let x = 1", language: "brainfuck"), [CodeToken(kind: .plain, text: "let x = 1")])
        XCTAssertEqual(CodeHighlighter.tokens("", language: "swift"), [])
    }

    func testIdentifierContainingDigitsIsNotANumber() {
        XCTAssertFalse(kinds("v2 = 1", "go").contains { $0.0 == .number && $0.1 == "2" })
    }
}
```

- [ ] **Step 3: Run them to verify they fail**

Run: `make test-swift FILTER=MarkdownDocumentTests` and `make test-swift FILTER=CodeHighlighterTests`
Expected: FAIL — `cannot find 'MarkdownDocument'` / `'CodeHighlighter'`.

- [ ] **Step 4: Implement the markdown model**

Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/MarkdownDocument.swift`:

```swift
import Foundation
import Markdown

package enum MarkdownTaskState: Equatable, Sendable { case none, checked, unchecked }

package enum MarkdownAlignment: Equatable, Sendable { case leading, center, trailing }

package struct MarkdownListItem: Equatable, Sendable {
    package let task: MarkdownTaskState
    package let blocks: [MarkdownBlock]

    package init(task: MarkdownTaskState, blocks: [MarkdownBlock]) {
        self.task = task
        self.blocks = blocks
    }
}

package struct MarkdownList: Equatable, Sendable {
    package let ordered: Bool
    package let start: Int
    package let items: [MarkdownListItem]

    package init(ordered: Bool, start: Int, items: [MarkdownListItem]) {
        self.ordered = ordered
        self.start = start
        self.items = items
    }
}

package struct MarkdownTable: Equatable, Sendable {
    package let header: [[MarkdownInline]]
    package let rows: [[[MarkdownInline]]]
    package let alignments: [MarkdownAlignment]

    package init(header: [[MarkdownInline]], rows: [[[MarkdownInline]]], alignments: [MarkdownAlignment]) {
        self.header = header
        self.rows = rows
        self.alignments = alignments
    }
}

package indirect enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, inlines: [MarkdownInline])
    case paragraph([MarkdownInline])
    case code(language: String?, code: String)
    case list(MarkdownList)
    case quote([MarkdownBlock])
    case table(MarkdownTable)
    case rule
}

package indirect enum MarkdownInline: Equatable, Sendable {
    case text(String)
    case emphasis([MarkdownInline])
    case strong([MarkdownInline])
    case strikethrough([MarkdownInline])
    case code(String)
    case link(destination: String, children: [MarkdownInline])
    case lineBreak
    case softBreak
}

/// swift-markdown (cmark-gfm) → our render model. Pure and memoized: chat
/// transcripts rebuild rows while scrolling, and the streaming row re-parses
/// at ≤30 fps — only that row, since finished rows hit the cache.
package enum MarkdownDocument {
    private final class Box {
        let blocks: [MarkdownBlock]
        init(_ blocks: [MarkdownBlock]) { self.blocks = blocks }
    }

    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.totalCostLimit = 8 << 20
        return cache
    }()

    package static func parse(_ text: String) -> [MarkdownBlock] {
        let key = text as NSString
        if let hit = cache.object(forKey: key) { return hit.blocks }
        let blocks = Document(parsing: text).children.compactMap(block)
        cache.setObject(Box(blocks), forKey: key, cost: text.utf16.count)
        return blocks
    }

    private static func block(_ node: Markup) -> MarkdownBlock? {
        switch node {
        case let heading as Heading: .heading(level: heading.level, inlines: inlines(heading))
        case let paragraph as Paragraph: .paragraph(inlines(paragraph))
        case let code as CodeBlock: .code(language: nonEmpty(code.language), code: trimTrailingNewline(code.code))
        case let list as UnorderedList: .list(MarkdownList(ordered: false, start: 1, items: list.listItems.map(item)))
        case let list as OrderedList: .list(MarkdownList(ordered: true, start: Int(list.startIndex), items: list.listItems.map(item)))
        case let quote as BlockQuote: .quote(quote.children.compactMap(block))
        case let table as Markdown.Table: .table(self.table(table))
        case is ThematicBreak: .rule
        case let html as HTMLBlock: .paragraph([.text(html.rawHTML)])
        default: nil
        }
    }

    private static func item(_ item: ListItem) -> MarkdownListItem {
        let task: MarkdownTaskState = switch item.checkbox {
        case .checked: .checked
        case .unchecked: .unchecked
        case .none: .none
        }
        return MarkdownListItem(task: task, blocks: item.children.compactMap(block))
    }

    private static func table(_ table: Markdown.Table) -> MarkdownTable {
        let header = table.head.cells.map { inlines($0) }
        let rows = table.body.rows.map { row in row.cells.map { inlines($0) } }
        let alignments: [MarkdownAlignment] = table.columnAlignments.map { alignment in
            switch alignment {
            case .center: .center
            case .right: .trailing
            case .left, .none: .leading
            }
        }
        return MarkdownTable(header: Array(header), rows: Array(rows), alignments: alignments)
    }

    private static func inlines(_ node: Markup) -> [MarkdownInline] {
        node.children.compactMap(inline)
    }

    private static func inline(_ node: Markup) -> MarkdownInline? {
        switch node {
        case let text as Markdown.Text: .text(text.string)
        case let emphasis as Emphasis: .emphasis(inlines(emphasis))
        case let strong as Strong: .strong(inlines(strong))
        case let strike as Strikethrough: .strikethrough(inlines(strike))
        case let code as InlineCode: .code(code.code)
        case let link as Markdown.Link: .link(destination: link.destination ?? "", children: inlines(link))
        case let image as Markdown.Image: .link(destination: image.source ?? "", children: inlines(image))
        case is LineBreak: .lineBreak
        case is SoftBreak: .softBreak
        case let html as InlineHTML: .text(html.rawHTML)
        default: nil
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private static func trimTrailingNewline(_ code: String) -> String {
        code.hasSuffix("\n") ? String(code.dropLast()) : code
    }
}

/// Inline model → AttributedString with Foundation presentation intents
/// (SwiftUI `Text` renders them). Link sanitizing is the app's job
/// (`AllowedURLSchemes`), applied by `MarkdownView.inlineText`.
package enum MarkdownInlineRenderer {
    package static func attributed(_ inlines: [MarkdownInline]) -> AttributedString {
        inlines.reduce(into: AttributedString()) { $0 += render($1, intent: [], link: nil) }
    }

    private static func render(_ inline: MarkdownInline, intent: InlinePresentationIntent, link: URL?) -> AttributedString {
        switch inline {
        case let .text(value): styled(value, intent, link)
        case let .code(value): styled(value, intent.union(.code), link)
        case let .emphasis(children): group(children, intent.union(.emphasized), link)
        case let .strong(children): group(children, intent.union(.stronglyEmphasized), link)
        case let .strikethrough(children): group(children, intent.union(.strikethrough), link)
        case let .link(destination, children): group(children, intent, URL(string: destination))
        case .lineBreak: styled("\n", intent, link)
        case .softBreak: styled(" ", intent, link)
        }
    }

    private static func group(_ children: [MarkdownInline], _ intent: InlinePresentationIntent, _ link: URL?) -> AttributedString {
        children.reduce(into: AttributedString()) { $0 += render($1, intent: intent, link: link) }
    }

    private static func styled(_ value: String, _ intent: InlinePresentationIntent, _ link: URL?) -> AttributedString {
        var out = AttributedString(value)
        if !intent.isEmpty { out.inlinePresentationIntent = intent }
        out.link = link
        return out
    }
}
```

- [ ] **Step 5: Implement the highlighter**

Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/CodeHighlighter.swift`:

```swift
import Foundation

package struct CodeToken: Equatable, Sendable {
    package enum Kind: Equatable, Sendable { case plain, keyword, string, comment, number }

    package let kind: Kind
    package let text: String

    package init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

/// A deliberately small highlighter (spec §3.3): keywords, strings, comments
/// and numbers for common languages. Lossless — the tokens always
/// concatenate back to the input — and an unknown language is one plain
/// token rather than a guess.
package enum CodeHighlighter {
    private struct Spec {
        let keywords: Set<String>
        let lineComments: [String]
        let blockComments: Bool
        let quotes: Set<Character>
        let caseInsensitive: Bool
    }

    package static func tokens(_ code: String, language: String?) -> [CodeToken] {
        guard !code.isEmpty else { return [] }
        guard let spec = language.flatMap({ specs[$0.lowercased()] }) else { return [CodeToken(kind: .plain, text: code)] }
        var scanner = Scanner(chars: Array(code), spec: spec)
        return scanner.run()
    }

    private struct Scanner {
        let chars: [Character]
        let spec: Spec
        var index = 0
        var out: [CodeToken] = []

        mutating func run() -> [CodeToken] {
            while index < chars.count {
                if let end = commentEnd() {
                    emit(.comment, until: end)
                } else if spec.quotes.contains(chars[index]) {
                    emit(.string, until: stringEnd())
                } else if chars[index].isNumber, !previousIsIdentifier() {
                    emit(.number, until: runEnd { $0.isHexDigit || $0 == "." || $0 == "_" || $0 == "x" })
                } else if chars[index].isLetter || chars[index] == "_" {
                    let end = runEnd { $0.isLetter || $0.isNumber || $0 == "_" }
                    let word = String(chars[index..<end])
                    let key = spec.caseInsensitive ? word.lowercased() : word
                    emit(spec.keywords.contains(key) ? .keyword : .plain, until: end)
                } else {
                    emit(.plain, until: index + 1)
                }
            }
            return out
        }

        private func startsWith(_ marker: String, at position: Int) -> Bool {
            let m = Array(marker)
            guard position + m.count <= chars.count else { return false }
            return Array(chars[position..<position + m.count]) == m
        }

        private func commentEnd() -> Int? {
            for marker in spec.lineComments where startsWith(marker, at: index) {
                var end = index
                while end < chars.count, chars[end] != "\n" { end += 1 }
                return end
            }
            guard spec.blockComments, startsWith("/*", at: index) else { return nil }
            var end = index + 2
            while end < chars.count, !startsWith("*/", at: end) { end += 1 }
            return min(end + 2, chars.count)
        }

        private func stringEnd() -> Int {
            let quote = chars[index]
            var end = index + 1
            while end < chars.count {
                if chars[end] == "\\" { end += 2; continue }
                if chars[end] == quote { return end + 1 }
                if chars[end] == "\n", quote != "`" { return end }
                end += 1
            }
            return chars.count
        }

        private func runEnd(_ predicate: (Character) -> Bool) -> Int {
            var end = index + 1
            while end < chars.count, predicate(chars[end]) { end += 1 }
            return end
        }

        private func previousIsIdentifier() -> Bool {
            guard index > 0 else { return false }
            let prev = chars[index - 1]
            return prev.isLetter || prev.isNumber || prev == "_"
        }

        private mutating func emit(_ kind: CodeToken.Kind, until end: Int) {
            let bounded = min(max(end, index + 1), chars.count)
            let text = String(chars[index..<bounded])
            if kind == .plain, let last = out.last, last.kind == .plain {
                out[out.count - 1] = CodeToken(kind: .plain, text: last.text + text)
            } else {
                out.append(CodeToken(kind: kind, text: text))
            }
            index = bounded
        }
    }

    private static let cLike: Set<Character> = ["\"", "'"]

    private static let specs: [String: Spec] = {
        let swift = Spec(keywords: ["let", "var", "func", "if", "else", "guard", "return", "struct", "class", "enum",
                                    "protocol", "extension", "import", "for", "in", "while", "switch", "case", "default",
                                    "true", "false", "nil", "self", "try", "await", "async", "throws", "private",
                                    "public", "static", "init"],
                         lineComments: ["//"], blockComments: true, quotes: ["\""], caseInsensitive: false)
        let go = Spec(keywords: ["func", "package", "import", "var", "const", "type", "struct", "interface", "if", "else",
                                 "for", "range", "return", "go", "defer", "switch", "case", "default", "map", "chan",
                                 "nil", "true", "false", "err"],
                      lineComments: ["//"], blockComments: true, quotes: ["\"", "'", "`"], caseInsensitive: false)
        let python = Spec(keywords: ["def", "class", "return", "if", "elif", "else", "for", "while", "in", "import",
                                     "from", "as", "with", "try", "except", "finally", "raise", "lambda", "None",
                                     "True", "False", "and", "or", "not", "yield", "async", "await"],
                          lineComments: ["#"], blockComments: false, quotes: cLike, caseInsensitive: false)
        let js = Spec(keywords: ["const", "let", "var", "function", "return", "if", "else", "for", "while", "class",
                                 "import", "from", "export", "new", "this", "null", "undefined", "true", "false",
                                 "async", "await", "type", "interface"],
                      lineComments: ["//"], blockComments: true, quotes: ["\"", "'", "`"], caseInsensitive: false)
        let json = Spec(keywords: ["true", "false", "null"], lineComments: [], blockComments: false,
                        quotes: ["\""], caseInsensitive: false)
        let sql = Spec(keywords: ["select", "from", "where", "and", "or", "not", "insert", "into", "values", "update",
                                  "set", "delete", "create", "table", "index", "join", "left", "on", "group", "by",
                                  "order", "limit", "as", "null", "is", "in"],
                       lineComments: ["--"], blockComments: true, quotes: cLike, caseInsensitive: true)
        let bash = Spec(keywords: ["if", "then", "else", "fi", "for", "do", "done", "while", "case", "esac", "function",
                                   "return", "export", "local", "echo"],
                        lineComments: ["#"], blockComments: false, quotes: cLike, caseInsensitive: false)
        let yaml = Spec(keywords: ["true", "false", "null", "yes", "no"], lineComments: ["#"], blockComments: false,
                        quotes: cLike, caseInsensitive: true)
        let rust = Spec(keywords: ["fn", "let", "mut", "pub", "struct", "enum", "impl", "trait", "use", "mod", "if",
                                   "else", "match", "for", "in", "loop", "while", "return", "true", "false", "self"],
                        lineComments: ["//"], blockComments: true, quotes: ["\""], caseInsensitive: false)
        let java = Spec(keywords: ["class", "public", "private", "protected", "static", "final", "void", "return", "if",
                                   "else", "for", "while", "new", "null", "true", "false", "import", "package", "fun",
                                   "val", "var", "when", "interface"],
                        lineComments: ["//"], blockComments: true, quotes: cLike, caseInsensitive: false)
        let c = Spec(keywords: ["int", "char", "void", "return", "if", "else", "for", "while", "struct", "typedef",
                                "const", "static", "include", "define", "class", "namespace", "auto", "nullptr"],
                     lineComments: ["//"], blockComments: true, quotes: cLike, caseInsensitive: false)
        return ["swift": swift, "go": go, "golang": go, "python": python, "py": python,
                "javascript": js, "js": js, "typescript": js, "ts": js, "jsx": js, "tsx": js,
                "json": json, "sql": sql, "bash": bash, "sh": bash, "shell": bash, "zsh": bash,
                "yaml": yaml, "yml": yaml, "rust": rust, "rs": rust,
                "java": java, "kotlin": java, "kt": java, "c": c, "cpp": c, "c++": c, "h": c]
    }()
}
```

- [ ] **Step 6: Run the Core tests**

Run: `make test-swift FILTER=MarkdownDocumentTests` then `make test-swift FILTER=CodeHighlighterTests`
Expected: PASS, PASS. If a swift-markdown API name differs in the resolved version (e.g. `Table.Cell` children, `OrderedList.startIndex`), fix the mapping in `MarkdownDocument.swift` — the tests are the contract.

- [ ] **Step 7: Write the failing view test**

Create `WatchtowerDesktop/Tests/MarkdownViewTests.swift`:

```swift
import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore

@MainActor
final class MarkdownViewTests: XCTestCase {
    /// Assistant text is attacker-reachable: a disallowed scheme loses its
    /// link attribute but keeps its visible text.
    func testInlineTextStripsDisallowedLinks() {
        let attr = MarkdownView.inlineText([.link(destination: "javascript:alert(1)", children: [.text("x")])])
        XCTAssertEqual(String(attr.characters), "x")
        XCTAssertFalse(attr.runs.contains { $0.link != nil })
    }

    func testInlineTextKeepsAllowedLinksAndBold() {
        let attr = MarkdownView.inlineText([.strong([.text("b")]), .link(destination: "slack://channel?id=C1", children: [.text("c")])])
        XCTAssertTrue(attr.runs.contains { $0.link != nil })
        XCTAssertTrue(attr.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
    }

    func testCodeBlockShowsLanguageAndCopy() throws {
        let view = CodeBlockView(language: "swift", code: "let x = 1")
        XCTAssertNoThrow(try view.inspect().find(text: "swift"))
        let helps = try view.inspect().findAll(ViewType.Button.self).compactMap { try? $0.help().string() }
        XCTAssertTrue(helps.contains("Copy code"))
    }

    func testRendersATable() throws {
        let view = MarkdownView(text: "| A | B |\n|---|---|\n| 1 | 2 |")
        XCTAssertNoThrow(try view.inspect().find(ViewType.Grid.self))
    }
}
```

- [ ] **Step 8: Run it to verify it fails**

Run: `make test-swift FILTER=MarkdownViewTests`
Expected: FAIL — `cannot find 'MarkdownView' in scope`.

- [ ] **Step 9: Implement the views**

Create `WatchtowerDesktop/Sources/Views/Chat/MarkdownView.swift`:

```swift
import SwiftUI
import WatchtowerCore

/// The one markdown renderer for every chat surface (spec §3.3) — main chat,
/// Discuss chats, setup assistants, recording notes, memory pages.
struct MarkdownView: View {
    let text: String

    var body: some View {
        MarkdownBlocksView(blocks: MarkdownDocument.parse(text))
            .textSelection(.enabled)
            .environment(\.openURL, AllowedURLSchemes.openURLAction)
    }

    /// Inline render with disallowed-scheme links stripped (defence in depth
    /// on top of the app-wide `openURL` gate).
    static func inlineText(_ inlines: [MarkdownInline]) -> AttributedString {
        AllowedURLSchemes.strippingDisallowedLinks(MarkdownInlineRenderer.attributed(inlines))
    }
}

struct MarkdownBlocksView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks.indices, id: \.self) { index in
                MarkdownBlockView(block: blocks[index])
            }
        }
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case let .heading(level, inlines):
            inline(inlines).font(Self.headingFont(level)).fontWeight(.bold)
        case let .paragraph(inlines):
            inline(inlines)
        case let .code(language, code):
            CodeBlockView(language: language, code: code)
        case let .list(list):
            MarkdownListView(list: list)
        case let .quote(children):
            HStack(spacing: 0) {
                Rectangle().fill(Color.accentColor.opacity(0.4)).frame(width: 3)
                MarkdownBlocksView(blocks: children).foregroundStyle(.secondary).padding(.leading, 8)
            }
        case let .table(table):
            MarkdownTableView(table: table)
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    // fixedSize keeps long lines wrapping inside HStack rows (AppKit-backed
    // Text otherwise truncates to one line).
    private func inline(_ inlines: [MarkdownInline]) -> some View {
        Text(MarkdownView.inlineText(inlines)).fixedSize(horizontal: false, vertical: true)
    }

    private static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title
        case 2: .title2
        case 3: .title3
        default: .headline
        }
    }
}

struct MarkdownListView: View {
    let list: MarkdownList

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(list.items.indices, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    marker(for: list.items[index], index: index)
                    MarkdownBlocksView(blocks: list.items[index].blocks)
                }
            }
        }
    }

    @ViewBuilder
    private func marker(for item: MarkdownListItem, index: Int) -> some View {
        switch item.task {
        case .checked: Image(systemName: "checkmark.square").foregroundStyle(.secondary)
        case .unchecked: Image(systemName: "square").foregroundStyle(.secondary)
        case .none:
            Text(list.ordered ? "\(list.start + index)." : "\u{2022}")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

struct MarkdownTableView: View {
    let table: MarkdownTable

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(table.header.indices, id: \.self) { column in
                        Text(MarkdownView.inlineText(table.header[column]))
                            .fontWeight(.semibold)
                            .gridColumnAlignment(alignment(column))
                    }
                }
                Divider()
                ForEach(table.rows.indices, id: \.self) { row in
                    GridRow {
                        ForEach(table.rows[row].indices, id: \.self) { column in
                            Text(MarkdownView.inlineText(table.rows[row][column]))
                        }
                    }
                }
            }
            .padding(8)
        }
        .background(Color(.textBackgroundColor).opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    private func alignment(_ column: Int) -> HorizontalAlignment {
        guard column < table.alignments.count else { return .leading }
        switch table.alignments[column] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}
```

Create `WatchtowerDesktop/Sources/Views/Chat/CodeBlockView.swift`:

```swift
import SwiftUI
import AppKit
import WatchtowerCore

struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: copy) {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc").font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Copy code")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            Divider()
            ScrollView(.horizontal, showsIndicators: false) {
                Text(Self.highlighted(code, language: language))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.textBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }

    static func highlighted(_ code: String, language: String?) -> AttributedString {
        CodeHighlighter.tokens(code, language: language).reduce(into: AttributedString()) { out, token in
            var part = AttributedString(token.text)
            switch token.kind {
            case .keyword: part.foregroundColor = Color(nsColor: .systemPurple)
            case .string: part.foregroundColor = Color(nsColor: .systemRed)
            case .comment: part.foregroundColor = Color(nsColor: .secondaryLabelColor)
            case .number: part.foregroundColor = Color(nsColor: .systemOrange)
            case .plain: break
            }
            out += part
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        didCopy = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { didCopy = false }
    }
}
```

- [ ] **Step 10: Replace every `MarkdownText` and delete it**

```bash
cd WatchtowerDesktop
grep -rl "MarkdownText(text:" Sources | xargs sed -i '' 's/MarkdownText(text:/MarkdownView(text:/g'
git rm Sources/Views/Chat/MarkdownText.swift Tests/MarkdownTextTests.swift
grep -rn "MarkdownText" Sources Tests
```

Expected: the last grep prints only the doc comment in `Sources/Utilities/MarkdownToHTML.swift`. Update that comment's first sentence to:

```swift
/// Converts the markdown subset the pasteboard needs (headers, bullet /
/// numbered lists, blockquotes, code blocks, dividers, inline bold/italic/code/
/// links) into HTML, so pasting into rich-text targets (Slack, Mail, Notes)
/// keeps the formatting. Rendering is `MarkdownView` (swift-markdown); this
/// export path stays a hand-rolled subset on purpose — extend it when a
/// rendered construct must survive a paste.
```

In `MessageBubble.swift` the assistant branch now renders markdown while streaming too (spec §3.2.2) — replace:

```swift
                if message.isStreaming {
                    Text(message.text)
                        .textSelection(.enabled)
                } else {
                    MarkdownView(text: message.text)
                }
```

with:

```swift
                MarkdownView(text: message.text)
```

- [ ] **Step 11: Run tests, build, lint**

Run: `make test-swift FILTER=MarkdownViewTests` then `make test-swift FILTER=MessageBubbleViewTests` then `make test-swift FILTER=TargetChatView` then `make lint-swift`
Expected: PASS ×3, lint clean.

- [ ] **Step 12: Commit**

```bash
git add WatchtowerDesktop/Package.swift WatchtowerDesktop/Package.resolved WatchtowerDesktop/Sources WatchtowerDesktop/Tests
git commit -m "feat(desktop): swift-markdown renderer shared by every chat" \
  -m "Tables, nested and task lists, quotes, fenced code with language label, copy and a small highlighter. Replaces MarkdownText everywhere; an unterminated fence renders as code while streaming." \
  -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 13: Tool catalog, steps block, source chips

**Files:**
- Create (Core): `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ChatToolCatalog.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/StepsSummary.swift`
- Create (app): `WatchtowerDesktop/Sources/Views/Chat/StepsBlockView.swift`, `WatchtowerDesktop/Sources/Views/Chat/SourceChipsView.swift`
- Test: `WatchtowerDesktop/Tests/Core/ChatToolCatalogTests.swift`, `WatchtowerDesktop/Tests/Core/StepsSummaryTests.swift`, `WatchtowerDesktop/Tests/StepsBlockViewTests.swift`

**Interfaces:**
- Consumes: Task 10 `ChatStepDisplay`, `StepState`, `ChatSource`; existing `ReactionToolCatalog.info(for:)`.
- Produces (Core): `ChatToolCatalog.label(name: String, args: String) -> String` (`args` = the raw `args` JSON; multi-statement so Phase 2 can prepend its `actionLabel` check), `ChatToolCatalog.icon(name:) -> String`; `StepsSummary.header(stepCount:elapsed:running:) -> String`, `StepsSummary.duration(_:) -> String`, `StepsSummary.elapsed(steps:running:now:) -> TimeInterval`.
- Produces (app): `StepsBlockView(steps: [ChatStepDisplay], isRunning: Bool)`, `SourceChipsView(sources: [ChatSource])`.

- [ ] **Step 1: Write the failing catalog + summary tests**

Create `WatchtowerDesktop/Tests/Core/ChatToolCatalogTests.swift`:

```swift
import XCTest
@testable import WatchtowerCore

final class ChatToolCatalogTests: XCTestCase {
    func testReadToolLabelsCarryTheirSubject() {
        XCTAssertEqual(ChatToolCatalog.label(name: "search_knowledge", args: #"{"queries":["payments rollout","платежи"]}"#),
                       "Searched knowledge: payments rollout, платежи")
        XCTAssertEqual(ChatToolCatalog.label(name: "get_jira_issue", args: #"{"key":"PROJ-123"}"#), "Opened PROJ-123")
        XCTAssertEqual(ChatToolCatalog.label(name: "list_messages", args: #"{"person":"anna"}"#), "Searched Slack: anna")
        XCTAssertEqual(ChatToolCatalog.label(name: "load_skill", args: #"{"name":"triage"}"#), "Loaded skill triage")
    }

    func testMissingSubjectFallsBack() {
        XCTAssertEqual(ChatToolCatalog.label(name: "get_jira_issue", args: "{}"), "Opened a Jira issue")
        XCTAssertEqual(ChatToolCatalog.label(name: "search_knowledge", args: "not json"), "Searched knowledge")
        XCTAssertEqual(ChatToolCatalog.label(name: "memory_map", args: "{}"), "Read the memory map")
    }

    func testWriteToolsReadAsProposals() {
        XCTAssertEqual(ChatToolCatalog.label(name: "create_jira_issue", args: "{}"), "Proposed: Create a Jira issue")
    }

    func testExternalAndUnknownTools() {
        XCTAssertEqual(ChatToolCatalog.label(name: "confluence:search_pages", args: "{}"), "Used confluence: search pages")
        XCTAssertEqual(ChatToolCatalog.label(name: "brand_new_tool", args: "{}"), "Used brand new tool")
    }

    /// A 200 KB argument never becomes a 200 KB label.
    func testSubjectIsCapped() throws {
        let data = try JSONSerialization.data(withJSONObject: ["queries": [String(repeating: "x", count: 500)]])
        let label = ChatToolCatalog.label(name: "search_knowledge", args: String(decoding: data, as: UTF8.self))
        XCTAssertLessThanOrEqual(label.count, 120)
        XCTAssertTrue(label.hasSuffix("…"))
    }

    func testIcons() {
        XCTAssertEqual(ChatToolCatalog.icon(name: "search_knowledge"), "magnifyingglass")
        XCTAssertEqual(ChatToolCatalog.icon(name: "get_jira_issue"), "ticket")
        XCTAssertEqual(ChatToolCatalog.icon(name: "create_target"), "hand.raised")
        XCTAssertEqual(ChatToolCatalog.icon(name: "x:y"), "puzzlepiece.extension")
        XCTAssertEqual(ChatToolCatalog.icon(name: "zzz"), "wrench.and.screwdriver")
    }
}
```

Create `WatchtowerDesktop/Tests/Core/StepsSummaryTests.swift`:

```swift
import XCTest
@testable import WatchtowerCore

final class StepsSummaryTests: XCTestCase {
    func testHeader() {
        XCTAssertEqual(StepsSummary.header(stepCount: 4, elapsed: 12.2, running: false), "Worked for 12s · 4 steps")
        XCTAssertEqual(StepsSummary.header(stepCount: 1, elapsed: 65, running: false), "Worked for 1m 05s · 1 step")
        XCTAssertEqual(StepsSummary.header(stepCount: 2, elapsed: 3, running: true), "Working… · 2 steps")
    }

    func testElapsedSpansFirstStartToLastEnd() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let steps = [
            ChatStepDisplay(id: "a", name: "x", argsJSON: "{}", state: .succeeded, summary: "", sources: [],
                            startedAt: t0, endedAt: t0.addingTimeInterval(3)),
            ChatStepDisplay(id: "b", name: "y", argsJSON: "{}", state: .running, summary: "", sources: [],
                            startedAt: t0.addingTimeInterval(4), endedAt: nil)
        ]
        XCTAssertEqual(StepsSummary.elapsed(steps: steps, running: true, now: t0.addingTimeInterval(10)), 10)
        XCTAssertEqual(StepsSummary.elapsed(steps: steps, running: false, now: t0.addingTimeInterval(99)), 3)
        XCTAssertEqual(StepsSummary.elapsed(steps: [], running: false, now: t0), 0)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `make test-swift FILTER=ChatToolCatalogTests` and `make test-swift FILTER=StepsSummaryTests`
Expected: FAIL — `cannot find 'ChatToolCatalog'` / `'StepsSummary'`.

- [ ] **Step 3: Implement the catalog and summary**

Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ChatToolCatalog.swift`:

```swift
import Foundation

/// The ONE tool name → human step label/icon mapping for chat steps (spec
/// §3.2, the `ReactionToolCatalog` precedent). Write tools reuse
/// `ReactionToolCatalog` titles so a tool never goes by two names.
package enum ChatToolCatalog {
    private struct Entry {
        let template: String?
        let fallback: String
        let keys: [String]
    }

    private static let maxSubject = 80

    private static let reads: [String: Entry] = [
        "search_knowledge": Entry(template: "Searched knowledge: {}", fallback: "Searched knowledge", keys: ["queries"]),
        "get_knowledge_document": Entry(template: nil, fallback: "Opened a document", keys: []),
        "list_messages": Entry(template: "Searched Slack: {}", fallback: "Searched Slack messages", keys: ["query", "person", "channel"]),
        "list_digests": Entry(template: nil, fallback: "Listed digests", keys: []),
        "get_digest": Entry(template: nil, fallback: "Opened a digest", keys: []),
        "get_today_briefing": Entry(template: nil, fallback: "Read today's briefing", keys: []),
        "list_jira_issues": Entry(template: "Listed Jira issues: {}", fallback: "Listed Jira issues", keys: ["project", "assignee", "status"]),
        "list_jira_projects": Entry(template: nil, fallback: "Listed Jira projects", keys: []),
        "get_jira_issue": Entry(template: "Opened {}", fallback: "Opened a Jira issue", keys: ["key"]),
        "get_task_context": Entry(template: "Gathered context for {}", fallback: "Gathered task context", keys: ["key", "issue_key"]),
        "list_people": Entry(template: nil, fallback: "Listed people", keys: []),
        "get_person": Entry(template: "Looked up {}", fallback: "Looked up a person", keys: ["name", "query", "id"]),
        "list_tracks": Entry(template: nil, fallback: "Listed tracks", keys: []),
        "get_track": Entry(template: nil, fallback: "Opened a track", keys: []),
        "list_targets": Entry(template: nil, fallback: "Listed targets", keys: []),
        "get_target": Entry(template: nil, fallback: "Opened a target", keys: []),
        "list_upcoming_events": Entry(template: nil, fallback: "Checked the calendar", keys: []),
        "list_transcripts": Entry(template: "Searched meetings: {}", fallback: "Listed meeting transcripts", keys: ["query"]),
        "get_transcript": Entry(template: nil, fallback: "Opened a meeting transcript", keys: []),
        "memory_recall": Entry(template: "Recalled from memory: {}", fallback: "Recalled from memory", keys: ["query"]),
        "memory_open": Entry(template: "Opened memory {}", fallback: "Opened a memory page", keys: ["ref"]),
        "memory_map": Entry(template: nil, fallback: "Read the memory map", keys: []),
        "find_experts": Entry(template: "Found experts: {}", fallback: "Found experts", keys: ["topic", "issue_key"]),
        "list_ideas": Entry(template: nil, fallback: "Listed ideas", keys: []),
        "get_idea": Entry(template: nil, fallback: "Opened an idea", keys: []),
        "load_skill": Entry(template: "Loaded skill {}", fallback: "Loaded a skill", keys: ["name"]),
        "get_action": Entry(template: nil, fallback: "Checked a proposal", keys: [])
    ]

    /// `args` is the step's raw `args` JSON; unparseable args just lose the subject.
    package static func label(name: String, args: String) -> String {
        if let (server, tool) = external(name) {
            return "Used \(server): \(tool.replacingOccurrences(of: "_", with: " "))"
        }
        if let write = ReactionToolCatalog.info(for: name) {
            return "Proposed: \(write.title)"
        }
        guard let entry = reads[name] else {
            return "Used \(name.replacingOccurrences(of: "_", with: " "))"
        }
        guard let template = entry.template, let subject = subject(args: args, keys: entry.keys) else {
            return entry.fallback
        }
        return template.replacingOccurrences(of: "{}", with: subject)
    }

    package static func icon(name: String) -> String {
        if external(name) != nil { return "puzzlepiece.extension" }
        if ReactionToolCatalog.info(for: name) != nil { return "hand.raised" }
        let rules: [(String, String)] = [
            ("knowledge", "magnifyingglass"), ("messages", "bubble.left.and.bubble.right"), ("jira", "ticket"),
            ("task_context", "ticket"), ("transcript", "waveform"), ("person", "person"), ("people", "person.2"),
            ("experts", "person.2"), ("memory", "brain"), ("digest", "doc.text"), ("briefing", "sun.max"),
            ("target", "target"), ("track", "arrow.triangle.branch"), ("events", "calendar"),
            ("skill", "book"), ("idea", "lightbulb"), ("action", "checklist")
        ]
        return rules.first { name.contains($0.0) }?.1 ?? "wrench.and.screwdriver"
    }

    private static func external(_ name: String) -> (String, String)? {
        let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    private static func subject(args: String, keys: [String]) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(args.utf8)) as? [String: Any] else { return nil }
        for key in keys {
            if let value = json[key] as? String, !value.isEmpty { return capped(value) }
            if let values = json[key] as? [String], !values.isEmpty { return capped(values.joined(separator: ", ")) }
        }
        return nil
    }

    private static func capped(_ value: String) -> String {
        value.count <= maxSubject ? value : String(value.prefix(maxSubject - 1)) + "…"
    }
}
```

Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/StepsSummary.swift`:

```swift
import Foundation

/// The steps block header (spec §3.2.1): "Worked for 12s · 4 steps".
package enum StepsSummary {
    package static func header(stepCount: Int, elapsed: TimeInterval, running: Bool) -> String {
        let steps = stepCount == 1 ? "1 step" : "\(stepCount) steps"
        return running ? "Working… · \(steps)" : "Worked for \(duration(elapsed)) · \(steps)"
    }

    package static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return total < 60 ? "\(total)s" : "\(total / 60)m \(String(format: "%02d", total % 60))s"
    }

    /// First step start → last step end (→ `now` while running).
    package static func elapsed(steps: [ChatStepDisplay], running: Bool, now: Date) -> TimeInterval {
        guard let start = steps.map(\.startedAt).min() else { return 0 }
        let end = running ? now : (steps.compactMap(\.endedAt).max() ?? start)
        return max(0, end.timeIntervalSince(start))
    }
}
```

Run: `make test-swift FILTER=ChatToolCatalogTests` then `make test-swift FILTER=StepsSummaryTests` → PASS, PASS.

- [ ] **Step 4: Write the failing view test**

Create `WatchtowerDesktop/Tests/StepsBlockViewTests.swift`:

```swift
import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore

@MainActor
final class StepsBlockViewTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private func step(_ id: String, _ name: String, _ state: StepState, end: TimeInterval? = 2) -> ChatStepDisplay {
        ChatStepDisplay(id: id, name: name, argsJSON: #"{"key":"P-1"}"#, state: state, summary: "sum", sources: [],
                        startedAt: t0, endedAt: end.map { t0.addingTimeInterval($0) })
    }

    func testFinishedBlockShowsHeaderAndLabels() throws {
        let view = StepsBlockView(steps: [step("a", "get_jira_issue", .succeeded), step("b", "search_knowledge", .failed)],
                                  isRunning: false)
        XCTAssertNoThrow(try view.inspect().find(text: "Worked for 2s · 2 steps"))
        XCTAssertNoThrow(try view.inspect().find(text: "Opened P-1"))
    }

    func testEmptyStepsRenderNothing() throws {
        let view = StepsBlockView(steps: [], isRunning: false)
        XCTAssertThrowsError(try view.inspect().find(ViewType.DisclosureGroup.self))
    }

    func testSourceChipsDedupe() throws {
        let src = ChatSource(kind: "jira", title: "P-1", url: "https://x/P-1", ref: "P-1")
        let view = SourceChipsView(sources: [src, src])
        XCTAssertEqual(try view.inspect().findAll(ViewType.Button.self).count, 1)
    }
}
```

- [ ] **Step 5: Run it to verify it fails**

Run: `make test-swift FILTER=StepsBlockViewTests`
Expected: FAIL — `cannot find 'StepsBlockView' in scope`.

- [ ] **Step 6: Implement the views**

Create `WatchtowerDesktop/Sources/Views/Chat/StepsBlockView.swift`:

```swift
import SwiftUI
import WatchtowerCore

/// "Worked for 12s · 4 steps" (spec §3.2.1): expanded with the live step on
/// top while running, collapsed when done. Every tool call is visible
/// (CHAT-02); a failed step is red.
struct StepsBlockView: View {
    let steps: [ChatStepDisplay]
    let isRunning: Bool
    @State private var expanded: Bool?

    var body: some View {
        if !steps.isEmpty {
            DisclosureGroup(isExpanded: expandedBinding) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(ordered) { step in
                        StepRow(step: step, turnRunning: isRunning)
                    }
                }
                .padding(.top, 4)
            } label: {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(StepsSummary.header(
                        stepCount: steps.count,
                        elapsed: StepsSummary.elapsed(steps: steps, running: isRunning, now: context.date),
                        running: isRunning))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var ordered: [ChatStepDisplay] { isRunning ? steps.reversed() : steps }

    /// Follows the running state until the owner toggles it by hand.
    private var expandedBinding: Binding<Bool> {
        Binding(get: { expanded ?? isRunning }, set: { expanded = $0 })
    }
}

private struct StepRow: View {
    let step: ChatStepDisplay
    let turnRunning: Bool
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 2) {
                Text(step.argsJSON).font(.caption.monospaced()).textSelection(.enabled)
                if !step.summary.isEmpty {
                    Text(step.summary).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        } label: {
            HStack(spacing: 6) {
                statusIcon
                Image(systemName: ChatToolCatalog.icon(name: step.name)).font(.caption)
                Text(ChatToolCatalog.label(name: step.name, args: step.argsJSON))
                    .font(.caption)
                    .foregroundStyle(step.state == .failed ? Color.red : Color.primary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch step.state {
        case .succeeded: Image(systemName: "checkmark.circle").foregroundStyle(.green).font(.caption)
        case .failed: Image(systemName: "xmark.octagon").foregroundStyle(.red).font(.caption)
        case .running:
            if turnRunning {
                ProgressView().controlSize(.mini)
            } else {
                // The turn ended while this tool was in flight.
                Image(systemName: "stop.circle").foregroundStyle(.secondary).font(.caption)
            }
        }
    }
}
```

Create `WatchtowerDesktop/Sources/Views/Chat/SourceChipsView.swift`:

```swift
import SwiftUI
import WatchtowerCore

/// Onyx-style source chips (spec §3.2.3), deduplicated; a chip opens its
/// permalink through the app-wide allowed-scheme `openURL`.
struct SourceChipsView: View {
    let sources: [ChatSource]
    @Environment(\.openURL) private var openURL

    var body: some View {
        let unique = ChatSource.dedupe(sources)
        if !unique.isEmpty {
            FlowLayout(spacing: 6) {
                ForEach(unique, id: \.dedupeKey) { source in
                    Button {
                        if let link = source.url.flatMap(URL.init(string:)) { openURL(link) }
                    } label: {
                        Label(source.title.isEmpty ? source.ref : source.title, systemImage: Self.icon(source.kind))
                            .font(.caption)
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .disabled(source.url == nil)
                    .help(source.url ?? source.ref)
                }
            }
        }
    }

    static func icon(_ kind: String) -> String {
        switch kind {
        case "slack": "number"
        case "jira": "ticket"
        case "email": "envelope"
        case "meeting": "waveform"
        case "document": "doc.text"
        case "person": "person.crop.circle"
        default: "link"
        }
    }
}
```

- [ ] **Step 7: Run tests and lint**

Run: `make test-swift FILTER=StepsBlockViewTests` then `make lint-swift`
Expected: PASS; lint clean.

- [ ] **Step 8: Commit**

```bash
git add WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ChatToolCatalog.swift \
  WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/StepsSummary.swift \
  WatchtowerDesktop/Sources/Views/Chat/StepsBlockView.swift WatchtowerDesktop/Sources/Views/Chat/SourceChipsView.swift \
  WatchtowerDesktop/Tests/Core/ChatToolCatalogTests.swift WatchtowerDesktop/Tests/Core/StepsSummaryTests.swift \
  WatchtowerDesktop/Tests/StepsBlockViewTests.swift
git commit -m "feat(desktop): visible tool steps and source chips" \
  -m "ChatToolCatalog is the single tool-to-label/icon map; StepsBlockView shows every tool call (CHAT-02) and SourceChipsView the turn's deduplicated sources." \
  -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 14: ChatViewModel rewrite — sessions, branches, CHAT-01

**Files:**
- Create (Core): `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ChatPromptRules.swift`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Database/Queries/ChatConversationQueries.swift` (add `needsAITitle`)
- Rewrite: `WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift`
- Create: `WatchtowerDesktop/Sources/Views/Chat/ChatMessageRow.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Chat/ChatView.swift` (targeted replacements below)
- Modify: `WatchtowerDesktop/Sources/App/AppState.swift:147-311` (`ensureChatViewModels`, delete `maybeCreateWelcomeChat`)
- Modify (rule references): `Sources/ViewModels/IdeaChatViewModel.swift`, `TargetChatViewModel.swift`, `MeetingChatViewModel.swift`, `Sources/Views/Tracks/TrackChatView.swift`, and any test referencing `ChatViewModel.noLiveSourcesRule`/`knowledgeLinkRule`
- Delete: `WatchtowerDesktop/Tests/ChatViewModelStreamFoldTests.swift`, `WatchtowerDesktop/Tests/ChatViewModelOutcomesTests.swift`; the `ChatViewModelTests` and `ChatViewModelProviderTests` classes inside `WatchtowerDesktop/Tests/ViewModelTests.swift`
- Test: `WatchtowerDesktop/Tests/ChatViewModelTests.swift` (new file, the Phase 4 fixture host), `WatchtowerDesktop/Tests/Core/ChatConversationQueriesTests.swift` (extend)

**Interfaces:**
- Consumes: Task 10 queries/models; Task 11 `ChatSessionPool`, `ChatSessionConfig`, `ChatSessionClient`, `ChatTurnCommand`, `ChatTurnRequest`, `ChatContinuity`, `ChatTurnText`, `LiveTurn`; Task 12 `MarkdownView`; Task 13 `StepsBlockView`, `SourceChipsView`; existing `AgentActionFeed.outcomesBlock(after:)`.
- Produces (app): `ChatViewModel(dbManager:pool:provider:cliRunner:makeTurnID:)` with `conversationID`, `currentConversation`, `thread: [ChatThreadItem]`, `draft`, `errorMessage`, `selectedProvider`, `selectedModel`, `scrollTarget`, `editingMessageID`, `liveTurn`, `isStreaming`, `actionFeed`, `pool`, `onConversationsChanged`; methods `select(conversationID:)`, `newConversation(projectID:) -> Int64?`, `forget(conversationID:)`, `reload()`, `reloadConversations()`, `prewarm()`, `switchProvider(_:)`, `sendDraft()`, `send(text:attachments: [ChatCommandAttachment], mentions: [String]) -> Bool`, `stop()`, `retry(messageID:)`, `continueStopped(messageID:)`, `regenerate(messageID:)`, `edit(messageID:newText:)`, `beginEditingLast()`, `selectVariant(messageID:)`, `variant(of:offset:) -> Int64?`. `mentions` are finished REFERENCED tokens (`jira:PROJ-1`, `person:<id> "Label"`); Phase 4 Task 25 may switch the parameter to its `MentionCandidate` and map through `referenceToken`. Views: `ChatMessageRow(item:)` (`Equatable`), `LiveAssistantRow(turn:)`, `AssistantMessageBody(text:steps:isRunning:)`, `UserMessageBubble(text:)`.
- Produces (Core): `ChatPromptRules.noLiveSourcesRule`, `.knowledgeLinkRule` (moved from `ChatViewModel`); `ChatConversationQueries.needsAITitle(_:id:) -> Bool`.

- [ ] **Step 1: Move the shared prompt rules to Core**

Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ChatPromptRules.swift`:

```swift
import Foundation

/// Prompt rules the Discuss chats still build in Swift (the main chat's
/// prompt moved to Go, `internal/chat`). `knowledgeLinkRule` is a deliberate
/// dual path with Go's `LinkingRules` — change both together.
package enum ChatPromptRules {
    /// Written against a real failure: tools the model cannot use get
    /// silently denied in headless mode, so an unbriefed model wastes a turn
    /// on them and then asks the owner to "approve tool permissions".
    package static let noLiveSourcesRule = """
        You have NO shell, NO filesystem access, NO internet, and NO live access to Slack, Jira, \
        or Calendar — the local Watchtower database already mirrors them, and the tools listed above \
        are the ONLY way in. Never say you will check an external system, and never ask the user to \
        approve tool permissions: everything you can use is already connected; everything else is \
        unavailable by design.
        """

    package static let knowledgeLinkRule =
        "search_knowledge hits: prefer the hit's \"link\" (a permalink) when present. To link a specific " +
        "Slack message instead, take anchor.channel_id without its \"N:\" account prefix (\"1:C123\" → C123) " +
        "and, as the message ts, anchor.thread_ts for a thread hit, otherwise the hit's chunk_anchor."
}
```

Then:

```bash
cd WatchtowerDesktop
grep -rl "ChatViewModel\.noLiveSourcesRule\|ChatViewModel\.knowledgeLinkRule" Sources Tests | xargs sed -i '' \
  -e 's/ChatViewModel\.noLiveSourcesRule/ChatPromptRules.noLiveSourcesRule/g' \
  -e 's/ChatViewModel\.knowledgeLinkRule/ChatPromptRules.knowledgeLinkRule/g'
grep -rn "ChatViewModel\.\(noLiveSourcesRule\|knowledgeLinkRule\)" Sources Tests
```

Expected: the grep prints nothing. Every edited file must `import WatchtowerCore` (they already do; add it if the build says otherwise).

- [ ] **Step 2: Add `needsAITitle` with its test**

Append to `WatchtowerDesktop/Tests/Core/ChatConversationQueriesTests.swift` (inside the class):

```swift
    /// `chat title` fires once: after the FIRST completed assistant reply,
    /// and never over an owner rename.
    func testNeedsAITitleOnlyAfterTheFirstCompletedReply() throws {
        let db = try TestDatabase.create()
        try db.write { d in
            let conv = try TestDatabase.insertChatConversation(d)
            XCTAssertFalse(try ChatConversationQueries.needsAITitle(d, id: conv))
            try TestDatabase.insertChatMessage(d, conversationID: conv, role: "assistant", text: "a", status: "partial")
            XCTAssertFalse(try ChatConversationQueries.needsAITitle(d, id: conv), "a partial reply is not a finished exchange")
            try TestDatabase.insertChatMessage(d, conversationID: conv, role: "assistant", text: "b")
            XCTAssertTrue(try ChatConversationQueries.needsAITitle(d, id: conv))
            try TestDatabase.insertChatMessage(d, conversationID: conv, role: "assistant", text: "c")
            XCTAssertFalse(try ChatConversationQueries.needsAITitle(d, id: conv))
        }
    }

    func testNeedsAITitleIsFalseForAUserTitle() throws {
        let db = try TestDatabase.create()
        try db.write { d in
            let conv = try TestDatabase.insertChatConversation(d)
            try TestDatabase.insertChatMessage(d, conversationID: conv, role: "assistant", text: "b")
            try ChatConversationQueries.rename(d, id: conv, title: "Mine")
            XCTAssertFalse(try ChatConversationQueries.needsAITitle(d, id: conv))
        }
    }
```

Run: `make test-swift FILTER=ChatConversationQueriesTests` → FAIL (`no member 'needsAITitle'`). Add to `ChatConversationQueries`:

```swift
    /// True exactly when the conversation still has its prefix title and has
    /// just finished its first assistant reply (spec §4.4).
    package static func needsAITitle(_ db: Database, id: Int64) throws -> Bool {
        let completed = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM chat_messages m
            JOIN chat_conversations c ON c.id = m.conversation_id
            WHERE c.id = ? AND c.title_source = 'prefix' AND m.role = 'assistant' AND m.status = 'complete'
            """, arguments: [id]) ?? 0
        return completed == 1
    }
```

Run again → PASS.

- [ ] **Step 3: Remove the old main-chat tests**

```bash
cd WatchtowerDesktop
git rm Tests/ChatViewModelStreamFoldTests.swift Tests/ChatViewModelOutcomesTests.swift
sed -i '' '/^\/\/ MARK: - ChatViewModel$/,/^\/\/ MARK: - AIProvider Tests$/{/^\/\/ MARK: - AIProvider Tests$/!d;}' Tests/ViewModelTests.swift
sed -i '' '/^\/\/ MARK: - ChatViewModel Provider Switching Tests$/,/^\/\/ MARK: - SearchViewModel$/{/^\/\/ MARK: - SearchViewModel$/!d;}' Tests/ViewModelTests.swift
grep -n "class ChatViewModel\|class AIProviderTests\|class SearchViewModelTests" Tests/ViewModelTests.swift
```

Expected: only `AIProviderTests` and `SearchViewModelTests` remain from that list. (The old tests covered the one-shot `ai query` stream; their behaviors — outcomes block, provider independence, persistence on navigation — are re-pinned against the session engine in Step 4.)

- [ ] **Step 4: Write the failing view-model tests**

Create `WatchtowerDesktop/Tests/ChatViewModelTests.swift`:

```swift
import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// The main chat against a real pool with scripted session processes. The
/// turn is owned by the pool, so several tests release or switch the view
/// model mid-turn (review-rules: start → navigate away → return).
@MainActor
final class ChatViewModelTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!
    private(set) var pool: ChatSessionPool!
    private var fakes: [FakeChatSessionProcess] = []
    private var turnCounter = 0

    override func setUpWithError() throws {
        (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
        fakes = []
        turnCounter = 0
        pool = ChatSessionPool(
            dbPool: dbManager.dbPool,
            processFactory: { [unowned self] args in
                let fake = FakeChatSessionProcess(arguments: args)
                self.fakes.append(fake)
                return fake
            },
            closeGrace: .milliseconds(20)
        )
    }

    override func tearDown() async throws {
        await pool.closeAll()
        TestDatabase.cleanup(path: dbPath)
    }

    func makeViewModel(cliRunner: FakeCLIRunner? = nil) throws -> ChatViewModel {
        ChatViewModel(dbManager: dbManager, pool: pool, provider: .claude, cliRunner: cliRunner,
                      makeTurnID: { [unowned self] in
                          self.turnCounter += 1
                          return "turn-\(self.turnCounter)"
                      })
    }

    private func lastFake() throws -> FakeChatSessionProcess {
        try XCTUnwrap(fakes.last)
    }

    private func lastAssistant(_ conversationID: Int64) throws -> ChatMessageRecord? {
        try dbManager.dbPool.read { d in
            try ChatMessageRecord.fetchOne(d, sql: """
                SELECT * FROM chat_messages WHERE conversation_id = ? AND role = 'assistant' ORDER BY id DESC LIMIT 1
                """, arguments: [conversationID])
        }
    }

    private func complete(_ vm: ChatViewModel, turn: String, text: String) async throws {
        let fake = try lastFake()
        fake.emit(.textDelta(turnID: turn, text: text))
        fake.emit(.turnDone(turnID: turn, status: .complete, sessionID: nil))
        let done = await waitForCondition { !vm.isStreaming && vm.thread.last?.message.status == "complete" }
        XCTAssertTrue(done, "turn \(turn) did not complete")
    }

    // MARK: - CHAT-01

    func testChat01UserMessageIsPersistedBeforeTheTurnIsSent() throws {
        let vm = try makeViewModel()
        let convID = try XCTUnwrap(vm.newConversation())
        let fake = try lastFake()
        let db = dbManager.dbPool
        var userRowsAtSend: [String] = []
        fake.onSend = { command in
            guard case .turn = command else { return }
            userRowsAtSend = (try? db.read { d in
                try String.fetchAll(d, sql: "SELECT text FROM chat_messages WHERE conversation_id = ? AND role = 'user'",
                                    arguments: [convID])
            }) ?? []
        }
        XCTAssertTrue(vm.send(text: "hello"))
        XCTAssertEqual(userRowsAtSend, ["hello"])
    }

    func testChat01NothingIsSentWhenTheMessageCannotBeSaved() throws {
        let vm = try makeViewModel()
        _ = try XCTUnwrap(vm.newConversation())
        try dbManager.dbPool.write { d in
            try d.execute(sql: """
                CREATE TRIGGER fail_user BEFORE INSERT ON chat_messages WHEN NEW.role = 'user'
                BEGIN SELECT RAISE(ABORT, 'boom'); END
                """)
        }
        vm.draft = "hello"
        vm.sendDraft()
        XCTAssertTrue(try lastFake().turns.isEmpty)
        XCTAssertEqual(vm.draft, "hello", "the owner's text stays in the composer")
        XCTAssertNotNil(vm.errorMessage)
    }

    func testChat01PartialTextSurvivesStop() async throws {
        let vm = try makeViewModel()
        let convID = try XCTUnwrap(vm.newConversation())
        vm.send(text: "q")
        let fake = try lastFake()
        fake.emit(.textDelta(turnID: "turn-1", text: "Hel"))
        fake.emit(.textDelta(turnID: "turn-1", text: "lo"))
        _ = await waitForCondition { vm.liveTurn?.fullText == "Hello" }
        vm.stop()
        XCTAssertEqual(fake.sent.last, .cancel)
        fake.emit(.turnDone(turnID: "turn-1", status: .interrupted, sessionID: nil))
        let stopped = await waitForCondition { !vm.isStreaming }
        XCTAssertTrue(stopped)
        let row = try XCTUnwrap(lastAssistant(convID))
        XCTAssertEqual(row.text, "Hello")
        XCTAssertEqual(row.status, "partial")
    }

    func testChat01PartialTextSurvivesProcessDeathAndTheNextTurnResumes() async throws {
        let vm = try makeViewModel()
        let convID = try XCTUnwrap(vm.newConversation())
        vm.send(text: "q")
        let fake = try lastFake()
        fake.emit(.sessionReady(sessionID: "sess-1", provider: "claude", model: "m"))
        fake.emit(.textDelta(turnID: "turn-1", text: "half"))
        fake.exit(status: 9)
        let persisted = await waitForCondition { (try? self.lastAssistant(convID))?.status == "partial" && !vm.isStreaming }
        XCTAssertTrue(persisted)
        XCTAssertEqual(try lastAssistant(convID)?.text, "half")

        XCTAssertTrue(vm.send(text: "again"))
        XCTAssertEqual(fakes.count, 2, "a dead session is respawned")
        XCTAssertEqual(try lastFake().argument(after: "--resume"), "sess-1")
    }

    // MARK: - Navigation (review-rules: start → navigate away → return)

    func testTurnKeepsPersistingAfterViewModelIsReleased() async throws {
        var vm: ChatViewModel? = try makeViewModel()
        let convID = try XCTUnwrap(vm?.newConversation())
        XCTAssertEqual(vm?.send(text: "q"), true)
        let fake = try lastFake()
        weak var released = vm
        vm = nil
        XCTAssertNil(released, "the turn is owned by the pool, not by the view model")

        fake.emit(.textDelta(turnID: "turn-1", text: "Hello"))
        fake.emit(.turnDone(turnID: "turn-1", status: .complete, sessionID: nil))
        let persisted = await waitForCondition { (try? self.lastAssistant(convID))?.status == "complete" }
        XCTAssertTrue(persisted)

        let back = try makeViewModel()
        back.select(conversationID: convID)
        XCTAssertEqual(back.thread.last?.message.text, "Hello")
    }

    func testSwitchingConversationMidTurnAndBackShowsTheLiveTurn() async throws {
        let vm = try makeViewModel()
        let first = try XCTUnwrap(vm.newConversation())
        vm.send(text: "q")
        let firstFake = try lastFake()
        _ = vm.newConversation()

        firstFake.emit(.textDelta(turnID: "turn-1", text: "Hel"))
        _ = await waitForCondition { self.pool.client(for: first)?.liveTurn?.fullText == "Hel" }
        vm.select(conversationID: first)
        XCTAssertTrue(vm.isStreaming)
        XCTAssertEqual(vm.liveTurn?.fullText, "Hel")
        XCTAssertEqual(vm.thread.last?.id, vm.liveTurn?.messageID, "the live row replaces the partial assistant row")

        firstFake.emit(.textDelta(turnID: "turn-1", text: "lo"))
        firstFake.emit(.turnDone(turnID: "turn-1", status: .complete, sessionID: nil))
        let done = await waitForCondition { vm.thread.last?.message.text == "Hello" }
        XCTAssertTrue(done)
    }

    // MARK: - Render isolation (skeleton Review Focus #5)

    func testDeltasDoNotInvalidateTheThread() async throws {
        final class Flag: @unchecked Sendable { var fired = false }
        let vm = try makeViewModel()
        _ = vm.newConversation()
        vm.send(text: "q")
        let fake = try lastFake()
        let flag = Flag()
        withObservationTracking { _ = vm.thread } onChange: { flag.fired = true }
        for _ in 0..<50 { fake.emit(.textDelta(turnID: "turn-1", text: "x")) }
        let streamed = await waitForCondition { vm.liveTurn?.fullText.count == 50 }
        XCTAssertTrue(streamed)
        XCTAssertFalse(flag.fired, "a delta touches only LiveTurn, never the thread array")
    }

    // MARK: - Legacy (skeleton Review Focus #1)

    func testContinuingLegacyConversationResumesItsSession() throws {
        let (convID, lastID) = try dbManager.dbPool.write { d in
            let conv = try TestDatabase.insertChatConversation(d, title: "Old", sessionID: "sess-legacy")
            let user = try TestDatabase.insertChatMessage(d, conversationID: conv, role: "user", text: "old q")
            let asst = try TestDatabase.insertChatMessage(d, conversationID: conv, role: "assistant", text: "old a", parentID: user)
            return (conv, asst)
        }
        let vm = try makeViewModel()
        vm.select(conversationID: convID)
        XCTAssertEqual(vm.thread.map(\.message.text), ["old q", "old a"])

        XCTAssertTrue(vm.send(text: "next"))
        let fake = try lastFake()
        XCTAssertEqual(fake.argument(after: "--resume"), "sess-legacy")
        XCTAssertEqual(fake.turns.last?.replay, false, "the resumed session already holds this history")
        let user = try XCTUnwrap(vm.thread.first { $0.message.text == "next" })
        XCTAssertEqual(user.message.parentID, lastID)
    }

    // MARK: - Branches

    func testRegenerateMakesASiblingReplaysAndVariantsSwitch() async throws {
        let vm = try makeViewModel()
        _ = vm.newConversation()
        vm.send(text: "q")
        try await complete(vm, turn: "turn-1", text: "a1")
        let firstAnswer = try XCTUnwrap(vm.thread.last?.id)

        vm.regenerate(messageID: firstAnswer)
        let fake = try lastFake()
        XCTAssertEqual(fake.turns.last?.text, "q")
        XCTAssertEqual(fake.turns.last?.replay, true)
        try await complete(vm, turn: "turn-2", text: "a2")
        XCTAssertEqual(vm.thread.map(\.message.text), ["q", "a2"], "regenerate never duplicates the user message")
        XCTAssertEqual(vm.thread.last?.siblingIndex, 2)
        XCTAssertEqual(vm.thread.last?.siblingCount, 2)

        let previous = try XCTUnwrap(vm.variant(of: try XCTUnwrap(vm.thread.last?.id), offset: -1))
        vm.selectVariant(messageID: previous)
        XCTAssertEqual(vm.thread.last?.message.text, "a1")
        XCTAssertNil(vm.variant(of: previous, offset: -1))
    }

    func testEditMakesAUserSiblingAndReplays() async throws {
        let vm = try makeViewModel()
        _ = vm.newConversation()
        vm.send(text: "q")
        try await complete(vm, turn: "turn-1", text: "a1")
        let userID = try XCTUnwrap(vm.thread.first?.id)

        vm.edit(messageID: userID, newText: "q2")
        XCTAssertEqual(try lastFake().turns.last?.text, "q2")
        XCTAssertEqual(try lastFake().turns.last?.replay, true)
        try await complete(vm, turn: "turn-2", text: "a2")
        XCTAssertEqual(vm.thread.map(\.message.text), ["q2", "a2"])
        XCTAssertEqual(vm.thread.first?.siblingCount, 2)
    }

    func testErrorMarksTheMessageAndRetryRegenerates() async throws {
        let vm = try makeViewModel()
        _ = vm.newConversation()
        vm.send(text: "q")
        let fake = try lastFake()
        fake.emit(.error(ChatSessionError(turnID: "turn-1", code: .rateLimit, message: "slow", retryable: true)))
        let failed = await waitForCondition { vm.thread.last?.message.status == "error" }
        XCTAssertTrue(failed)
        XCTAssertEqual(vm.thread.last?.message.errorCode, "rate_limit")

        vm.retry(messageID: try XCTUnwrap(vm.thread.last?.id))
        XCTAssertEqual(fake.turns.count, 2)
        XCTAssertEqual(fake.turns.last?.replay, true, "a failed turn may not have reached the provider")
    }

    func testContinueStoppedSendsContinue() async throws {
        let vm = try makeViewModel()
        _ = vm.newConversation()
        vm.send(text: "q")
        let fake = try lastFake()
        fake.emit(.turnDone(turnID: "turn-1", status: .interrupted, sessionID: nil))
        _ = await waitForCondition { !vm.isStreaming }
        vm.continueStopped(messageID: try XCTUnwrap(vm.thread.last?.id))
        XCTAssertEqual(fake.turns.last?.text, "Continue")
    }

    func testSendingWhileStreamingIsRefused() throws {
        let vm = try makeViewModel()
        _ = vm.newConversation()
        XCTAssertTrue(vm.send(text: "q"))
        XCTAssertFalse(vm.send(text: "again"))
        XCTAssertFalse(vm.send(text: "   "))
    }

    // MARK: - Titles, outcomes, settings

    func testTitleIsRequestedOnceAfterTheFirstCompletedTurn() async throws {
        let runner = FakeCLIRunner(stdout: Data(#"{"title":"T","written":true}"#.utf8))
        let vm = try makeViewModel(cliRunner: runner)
        let convID = try XCTUnwrap(vm.newConversation())
        vm.send(text: "q")
        try await complete(vm, turn: "turn-1", text: "a")
        _ = await waitForCondition { runner.invocations.count == 1 }
        vm.send(text: "q2")
        try await complete(vm, turn: "turn-2", text: "b")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(runner.invocations, [["chat", "title", String(convID)]])
    }

    /// Ported from the old outcomes test: codex never emits a session id, so
    /// the floor is the previous owner message, not the session.
    func testOutcomesOfProposalsPrefixTheNextTurn() async throws {
        let vm = try makeViewModel()
        let convID = try XCTUnwrap(vm.newConversation())
        vm.send(text: "first")
        try await complete(vm, turn: "turn-1", text: "a")
        let applied = AgentActionFeed.timestampString(Date().addingTimeInterval(60))
        try dbManager.dbPool.write { d in
            try TestDatabase.insertAgentAction(d, conversationID: convID, status: "applied",
                                               resultJSON: #"{"target_id":5}"#, appliedAt: applied)
        }
        _ = await waitForCondition { vm.actionFeed.rows.count == 1 }
        vm.send(text: "second")
        let text = try XCTUnwrap(lastFake().turns.last?.text)
        XCTAssertTrue(text.hasPrefix("=== ACTIONS SINCE YOUR LAST MESSAGE ==="))
        XCTAssertTrue(text.contains("create_target: applied"))
        XCTAssertTrue(text.hasSuffix("second"))
    }

    func testSelectRestoresTheConversationsProviderAndModel() throws {
        let convID = try dbManager.dbPool.write { d in
            let conv = try TestDatabase.insertChatConversation(d, provider: "codex")
            try d.execute(sql: "UPDATE chat_conversations SET model = 'model-b' WHERE id = ?", arguments: [conv])
            return conv
        }
        let vm = try makeViewModel()
        vm.select(conversationID: convID)
        XCTAssertEqual(vm.selectedProvider, .codex)
        XCTAssertEqual(vm.selectedModel, "model-b")
        XCTAssertEqual(try lastFake().argument(after: "--provider"), "codex")
        XCTAssertNil(try lastFake().argument(after: "--resume"), "only claude resumes")
    }
}
```

- [ ] **Step 5: Run it to verify it fails**

Run: `make test-swift FILTER=ChatViewModelTests`
Expected: FAIL — compile errors (`extra argument 'pool'`, `no member 'thread'`).

- [ ] **Step 6: Rewrite the view model**

Replace `WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift` with (the `ChatMessage` struct and `AIProvider` enum at the top are kept verbatim — Discuss and setup chats use them):

```swift
import Foundation
import GRDB
import WatchtowerCore

struct ChatMessage: Identifiable, Equatable {
    let id: UUID
    var role: Role
    var text: String
    var timestamp: Date
    var isStreaming: Bool
    var turnID: String?

    enum Role: Equatable {
        case user
        case assistant
        case system
    }
}

enum AIProvider: String, CaseIterable, Identifiable {
    case claude
    case codex
    case ollama

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .ollama: "Ollama"
        }
    }
}

/// The main AI Chat (spec §1.4, §2.3). An action surface (AGENT-04): the Go
/// session mounts the registry's write tools for `--surface main`.
///
/// Ownership: running turns live in `ChatSessionPool` (app-wide), which
/// persists them. This view model only starts turns and renders — so it can
/// be released or switched mid-turn without losing a byte (CHAT-01).
@MainActor
@Observable
final class ChatViewModel {
    private(set) var conversationID: Int64?
    private(set) var currentConversation: ChatConversation?
    /// Finished rows of the active branch. Never mutated by a streaming
    /// delta — the live message is `liveTurn` (render isolation).
    private(set) var thread: [ChatThreadItem] = []
    var draft = ""
    var errorMessage: String?
    private(set) var selectedProvider: AIProvider
    /// Model override; "" = the provider's resolved strong model (the CLI resolves it).
    var selectedModel = ""
    var scrollTarget: Int64?
    var editingMessageID: Int64?
    /// History list refresh (conversation order, titles written by Go).
    @ObservationIgnored var onConversationsChanged: (() -> Void)?

    let actionFeed: AgentActionFeed
    let pool: ChatSessionPool

    @ObservationIgnored private let dbManager: DatabaseManager
    @ObservationIgnored private let cliRunner: CLIRunnerProtocol?
    @ObservationIgnored private let makeTurnID: () -> String
    @ObservationIgnored private var titleRequests: Set<Int64> = []

    init(
        dbManager: DatabaseManager,
        pool: ChatSessionPool,
        provider: AIProvider = .claude,
        cliRunner: CLIRunnerProtocol? = nil,
        makeTurnID: @escaping () -> String = { UUID().uuidString }
    ) {
        self.dbManager = dbManager
        self.pool = pool
        self.selectedProvider = provider
        self.cliRunner = cliRunner
        self.makeTurnID = makeTurnID
        self.actionFeed = AgentActionFeed(dbPool: dbManager.dbPool, cliRunner: cliRunner)
        pool.onTurnFinished = { [weak self] id in self?.turnFinished(conversationID: id) }
    }

    var liveTurn: LiveTurn? { pool.client(for: conversationID)?.liveTurn }
    var isStreaming: Bool { liveTurn?.isRunning == true }

    // MARK: - Conversations

    func select(conversationID id: Int64) {
        let switching = id != conversationID
        conversationID = id
        editingMessageID = nil
        reload()
        guard switching else { return }
        errorMessage = nil
        applyConversationSettings()
        actionFeed.start(conversationID: id)
        prewarm()
    }

    @discardableResult
    func newConversation(projectID: Int64? = nil) -> Int64? {
        do {
            let conv = try dbManager.dbPool.write { db in try ChatConversationQueries.create(db, projectID: projectID) }
            select(conversationID: conv.id)
            reloadConversations()
            return conv.id
        } catch {
            errorMessage = "Couldn't start a new chat: \(error.localizedDescription)"
            return nil
        }
    }

    /// A conversation is being deleted: close its session; stop showing it.
    func forget(conversationID id: Int64) {
        pool.close(conversationID: id)
        guard id == conversationID else { return }
        conversationID = nil
        currentConversation = nil
        thread = []
        editingMessageID = nil
        errorMessage = nil
        actionFeed.stop()
    }

    func reloadConversations() {
        onConversationsChanged?()
    }

    func reload() {
        guard let id = conversationID else {
            thread = []
            currentConversation = nil
            return
        }
        do {
            let (conv, items) = try dbManager.dbPool.read { db in
                (try ChatConversationQueries.fetchByID(db, id: id), try ChatTreeQueries.thread(db, conversationID: id))
            }
            currentConversation = conv
            if items != thread { thread = items }
        } catch {
            errorMessage = "Couldn't load the conversation: \(error.localizedDescription)"
        }
    }

    /// Opening a conversation or the first keystroke: spawn the session now.
    func prewarm() {
        guard let id = conversationID else { return }
        pool.prewarm(conversationID: id, config: sessionConfig(conversationID: id))
    }

    func switchProvider(_ provider: AIProvider) {
        guard provider != selectedProvider else { return }
        selectedProvider = provider
        selectedModel = ""
    }

    // MARK: - Turns

    /// Sends the composer text; clears it only when the turn really started.
    func sendDraft() {
        if send(text: draft) { draft = "" }
    }

    @discardableResult
    func send(text: String, attachments: [ChatCommandAttachment] = [], mentions: [String] = []) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return false }
        guard let id = conversationID ?? newConversation() else { return false }
        return startTurn(TurnPlan(conversationID: id, historyTipID: thread.last?.message.id, userText: trimmed,
                                  reuseUserMessageID: nil, attachments: attachments, mentions: mentions))
    }

    func stop() {
        pool.client(for: conversationID)?.cancel()
    }

    func retry(messageID: Int64) {
        regenerate(messageID: messageID)
    }

    func continueStopped(messageID: Int64) {
        guard thread.last?.message.id == messageID else { return }
        send(text: "Continue")
    }

    /// A new assistant sibling under the same user message (spec §2.3).
    func regenerate(messageID: Int64) {
        guard !isStreaming, let id = conversationID,
              let index = thread.firstIndex(where: { $0.message.id == messageID }), index > 0,
              thread[index].message.isAssistant, thread[index - 1].message.isUser else { return }
        let user = thread[index - 1].message
        startTurn(TurnPlan(conversationID: id, historyTipID: user.parentID, userText: user.text,
                           reuseUserMessageID: user.id, attachments: [], mentions: []))
    }

    /// A new user sibling under the original's parent, then a fresh reply.
    func edit(messageID: Int64, newText: String) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming, let id = conversationID,
              let item = thread.first(where: { $0.message.id == messageID }), item.message.isUser else { return }
        editingMessageID = nil
        startTurn(TurnPlan(conversationID: id, historyTipID: item.message.parentID, userText: trimmed,
                           reuseUserMessageID: nil, attachments: [], mentions: []))
    }

    /// ↑ in an empty composer (spec §3.5).
    func beginEditingLast() {
        editingMessageID = thread.last { $0.message.isUser }?.message.id
    }

    func selectVariant(messageID: Int64) {
        guard let id = conversationID else { return }
        do {
            try dbManager.dbPool.write { db in try ChatTreeQueries.selectSibling(db, conversationID: id, siblingID: messageID) }
            reload()
        } catch {
            errorMessage = "Couldn't switch the variant: \(error.localizedDescription)"
        }
    }

    /// The sibling `offset` steps from `messageID` (‹ = -1, › = +1), nil at an
    /// end. A read failure also answers nil: the arrow simply does nothing.
    func variant(of messageID: Int64, offset: Int) -> Int64? {
        guard let siblings = try? dbManager.dbPool.read({ db in try ChatTreeQueries.siblings(db, messageID: messageID) }),
              let index = siblings.firstIndex(where: { $0.id == messageID }) else { return nil }
        let target = index + offset
        return siblings.indices.contains(target) ? siblings[target].id : nil
    }

    // MARK: - Private

    private struct TurnPlan {
        let conversationID: Int64
        /// The parent of the user message this turn answers.
        let historyTipID: Int64?
        let userText: String
        /// Regenerate reuses the existing user message.
        let reuseUserMessageID: Int64?
        let attachments: [ChatCommandAttachment]
        let mentions: [String]
    }

    @discardableResult
    private func startTurn(_ plan: TurnPlan) -> Bool {
        let config = sessionConfig(conversationID: plan.conversationID)
        let turnID = makeTurnID()
        let activeLeafBefore = thread.last?.message.id
        let outcomes = actionFeed.outcomesBlock(after: thread.last { $0.message.isUser }?.message.createdDate)
        let assistant: ChatMessageRecord
        do {
            // CHAT-01: the owner's text is on disk before anything is sent.
            assistant = try persistTurnStart(plan, turnID: turnID, config: config)
        } catch {
            errorMessage = "Your message wasn't sent because it couldn't be saved: \(error.localizedDescription)"
            return false
        }
        errorMessage = nil
        reload()
        let client = pool.session(for: plan.conversationID, config: config)
        client.adoptInitialContinuity(
            ChatContinuity.initialLeaf(resumeSessionID: config.resumeSessionID, activeLeafID: activeLeafBefore))
        let command = ChatTurnCommand(
            turnID: turnID,
            text: ChatTurnText.compose(userText: plan.userText, outcomes: outcomes, mentions: plan.mentions),
            attachments: plan.attachments,
            replay: ChatContinuity.replayNeeded(historyTipID: plan.historyTipID, continuousLeafID: client.continuousLeafID))
        client.startTurn(ChatTurnRequest(command: command, assistantMessageID: assistant.id))
        reloadConversations()
        return true
    }

    private func persistTurnStart(_ plan: TurnPlan, turnID: String, config: ChatSessionConfig) throws -> ChatMessageRecord {
        try dbManager.dbPool.write { db in
            let userID: Int64
            if let reuse = plan.reuseUserMessageID {
                userID = reuse
            } else {
                userID = try ChatTreeQueries.insertUser(db, conversationID: plan.conversationID, parentID: plan.historyTipID,
                                                        text: plan.userText, turnID: turnID).id
                try ChatConversationQueries.setPrefixTitle(db, id: plan.conversationID, text: plan.userText)
            }
            try ChatConversationQueries.setProviderModel(db, id: plan.conversationID, provider: config.provider, model: config.model)
            return try ChatTreeQueries.insertAssistant(db, conversationID: plan.conversationID, parentID: userID,
                                                       turnID: turnID, provider: config.provider, model: config.model ?? "")
        }
    }

    private func sessionConfig(conversationID id: Int64) -> ChatSessionConfig {
        // Only claude sessions resume; codex/ollama replay every turn (spec §1.1).
        let resume = selectedProvider == .claude ? currentConversation?.sessionID : nil
        return ChatSessionConfig(conversationID: id, provider: selectedProvider.rawValue,
                                 model: selectedModel.isEmpty ? nil : selectedModel, resumeSessionID: resume)
    }

    /// A conversation remembers the provider/model it last ran with; a new
    /// one keeps the current picker selection.
    private func applyConversationSettings() {
        guard let conv = currentConversation, let raw = conv.provider else { return }
        if let provider = AIProvider(rawValue: raw) { selectedProvider = provider }
        selectedModel = conv.model ?? ""
    }

    private func turnFinished(conversationID id: Int64) {
        if id == conversationID {
            reload()
            // Proposals were written by the MCP subprocess, which the feed's
            // ValueObservation cannot see — the turn boundary surfaces them.
            actionFeed.refresh()
        }
        reloadConversations()
        requestTitleIfNeeded(conversationID: id)
    }

    /// Fire-and-forget `watchtower chat title` after the first completed
    /// exchange (spec §4.4). Go writes the title; the list reloads after.
    private func requestTitleIfNeeded(conversationID id: Int64) {
        guard let cliRunner, !titleRequests.contains(id) else { return }
        let needed: Bool
        do {
            needed = try dbManager.dbPool.read { db in try ChatConversationQueries.needsAITitle(db, id: id) }
        } catch {
            return // an unreadable count only skips the optional AI title; the prefix title stands
        }
        guard needed else { return }
        titleRequests.insert(id)
        Task { [weak self] in
            // ProcessCLIRunner logs a failure (CLILog); the prefix title stays, which is still correct.
            _ = try? await cliRunner.run(args: ["chat", "title", String(id)])
            guard let self else { return }
            self.titleRequests.remove(id)
            self.reloadConversations()
            if self.conversationID == id { self.reload() }
        }
    }
}
```

- [ ] **Step 7: Basic thread rows**

Create `WatchtowerDesktop/Sources/Views/Chat/ChatMessageRow.swift`:

```swift
import SwiftUI
import WatchtowerCore

/// A finished message of the active branch. `Equatable` + `.equatable()` at
/// the call site: a row whose item did not change never re-renders its
/// markdown, whatever else happens in the thread (render isolation).
struct ChatMessageRow: View, Equatable {
    let item: ChatThreadItem

    var body: some View {
        if item.message.isUser {
            UserMessageBubble(text: item.message.text)
        } else if item.message.isAssistant {
            AssistantMessageBody(text: item.message.text, steps: item.stepDisplays, isRunning: false)
        } else {
            Text(item.message.text)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
        }
    }
}

/// The streaming message: the only view that reads `LiveTurn.text`, so only
/// it re-renders on a delta.
struct LiveAssistantRow: View {
    let turn: LiveTurn

    var body: some View {
        AssistantMessageBody(text: turn.text, steps: turn.steps, isRunning: turn.isRunning)
    }
}

/// Steps → text → sources (spec §3.2).
struct AssistantMessageBody: View {
    let text: String
    let steps: [ChatStepDisplay]
    let isRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StepsBlockView(steps: steps, isRunning: isRunning)
            if text.isEmpty && isRunning {
                StreamingIndicator()
            } else {
                MarkdownView(text: text)
            }
            SourceChipsView(sources: steps.flatMap(\.sources))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct UserMessageBubble: View {
    let text: String

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 40)
            Text(text)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .foregroundStyle(.white)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}
```

- [ ] **Step 8: Adapt `ChatView` to the new API**

In `WatchtowerDesktop/Sources/Views/Chat/ChatView.swift` (Task 15 replaces the layout; this keeps it compiling and correct):

1. Replace the `.onChange(of: historyVM.selectedConversationID)` closure body with:

```swift
        .onChange(of: historyVM.selectedConversationID) { _, newID in
            if let newID { chatVM.select(conversationID: newID) }
        }
```

2. Replace `createNewChat()` and `deleteCurrentChat()` with:

```swift
    private func createNewChat() {
        if let id = chatVM.newConversation() { historyVM.selectedConversationID = id }
    }

    private func deleteCurrentChat() {
        guard let id = chatVM.conversationID else { return }
        chatVM.forget(conversationID: id)
        historyVM.deleteConversation(id)
        if let next = historyVM.conversations.first { chatVM.select(conversationID: next.id) }
    }
```

3. Replace the whole `chatContent` property, `quickPromptButton(_:)`, `actionCards(for:)` and `unattachedActionCards` with:

```swift
    private var chatContent: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if chatVM.thread.isEmpty && chatVM.conversationID != nil {
                            quickPrompts
                        } else if chatVM.thread.isEmpty {
                            emptyState
                        }
                        ForEach(chatVM.thread) { item in
                            threadRow(item).id(item.id)
                            actionCards(forTurn: item.message.turnID)
                        }
                        unattachedActionCards
                        if let error = chatVM.errorMessage {
                            Text(error)
                                .font(.callout)
                                .foregroundStyle(.red)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                        }
                        if let err = chatVM.actionFeed.lastError {
                            Text(err).font(.caption).foregroundStyle(.red)
                        }
                    }
                    .padding()
                }
                .onChange(of: chatVM.thread.last?.id) {
                    if let last = chatVM.thread.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            ChatInput(
                text: $chatVM.draft,
                isStreaming: chatVM.isStreaming,
                onSend: { chatVM.sendDraft() },
                onStop: { chatVM.stop() },
                dictationTargetID: "chat.workspace"
            )
        }
    }

    /// The live turn renders in place of its (partial) assistant row.
    @ViewBuilder
    private func threadRow(_ item: ChatThreadItem) -> some View {
        if let live = chatVM.liveTurn, live.messageID == item.id {
            LiveAssistantRow(turn: live)
        } else {
            ChatMessageRow(item: item).equatable()
        }
    }

    private func quickPromptButton(_ text: String) -> some View {
        Button(text) { chatVM.send(text: text) }
            .buttonStyle(.bordered)
    }

    @ViewBuilder
    private func actionCards(forTurn turn: String) -> some View {
        if !turn.isEmpty {
            let cards = chatVM.actionFeed.cards(forTurn: turn)
            if cards.filter(\.isPending).count >= 2 {
                Button("Approve all") { Task { await chatVM.actionFeed.approveAllPending(forTurn: turn) } }
                    .font(.caption)
            }
            ForEach(cards) { action in agentActionCard(action) }
        }
    }

    /// Proposals whose turn never persisted a message — unreachable otherwise.
    @ViewBuilder
    private var unattachedActionCards: some View {
        let orphans = AgentActionFeed.unattached(
            rows: chatVM.actionFeed.rows,
            messageTurnIDs: Set(chatVM.thread.map(\.message.turnID).filter { !$0.isEmpty })
        )
        if !orphans.isEmpty {
            Text("Proposals from an interrupted turn")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(orphans) { action in agentActionCard(action) }
        }
    }
```

- [ ] **Step 9: AppState — pool construction, no Welcome chat**

In `WatchtowerDesktop/Sources/App/AppState.swift`, next to `chatViewModel`/`chatHistoryViewModel` add:

```swift
    /// App-wide warm chat sessions (spec §1.4) — owns every running main-chat
    /// turn, so turns survive navigation. Created once the DB is open.
    private(set) var chatSessionPool: ChatSessionPool?
```

Replace `ensureChatViewModels()` and delete `maybeCreateWelcomeChat(chatVM:historyVM:)` entirely (spec §3.6: the auto-generated Welcome chat is removed):

```swift
    /// Ensures chat ViewModels exist (lazy init, called from ChatView).
    func ensureChatViewModels() {
        guard let db = databaseManager, chatViewModel == nil else { return }
        let configProvider = ConfigService().aiProvider
        let provider: AIProvider = configProvider == "codex" ? .codex : .claude
        let cvm = ChatViewModel(
            dbManager: db,
            pool: ensureChatSessionPool(db),
            provider: provider,
            cliRunner: Constants.findCLIPath().map { ProcessCLIRunner(binaryPath: $0) }
        )
        let hvm = ChatHistoryViewModel(dbManager: db)
        hvm.load()
        cvm.onConversationsChanged = { [weak hvm] in hvm?.load() }
        chatViewModel = cvm
        chatHistoryViewModel = hvm
    }

    @discardableResult
    func ensureChatSessionPool(_ db: DatabaseManager) -> ChatSessionPool {
        if let chatSessionPool { return chatSessionPool }
        let pool = ChatSessionPool(dbPool: db.dbPool)
        chatSessionPool = pool
        return pool
    }
```

Then check nothing else referenced the removed API:

```bash
cd WatchtowerDesktop
grep -rn "sendWelcomeMessage\|maybeCreateWelcomeChat\|\.bind(to:\|cancelStream()\|chatVM\.messages\|\.inputText" Sources/App Sources/Views/Chat Sources/ViewModels/ChatViewModel.swift
```

Expected: no output (the Discuss VMs have their own `bind`/`inputText`; this grep is scoped to the main chat).

- [ ] **Step 10: Run the tests**

Run: `make test-swift FILTER=ChatViewModelTests` then `make test-swift FILTER=ChatHistoryViewModelTests` then `make test-swift FILTER=AIProviderTests` then `make test-swift FILTER=TrackChatSkillsPromptTests`
Expected: all PASS.

- [ ] **Step 11: Build + lint**

Run: `cd WatchtowerDesktop && swift build > /tmp/wt-build.log 2>&1; echo "exit $?"` then `make lint-swift`
Expected: `exit 0`; lint clean.

- [ ] **Step 12: Commit**

```bash
git add WatchtowerDesktop/Sources WatchtowerDesktop/Tests
git commit -m "feat(desktop): main chat runs on warm sessions with branches" \
  -m "ChatViewModel persists the owner's message before sending (CHAT-01), hands turns to the pool, supports regenerate/edit/variants/continue/retry and requests an AI title after the first exchange. Removes the Welcome chat and the Swift-built main-chat prompt." \
  -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 15: Chat UI — left history, ⌘K search, thread column, row actions, composer, empty state

**Files:**
- Create (Core): `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ChatErrorPresentation.swift`
- Modify: `WatchtowerDesktop/Sources/ViewModels/ChatHistoryViewModel.swift`, `WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift` (add `open(_:)`)
- Modify: `WatchtowerDesktop/Sources/Views/Chat/ChatInput.swift` (defaulted `maxHeight`/`onEscape`/`onArrowUpWhenEmpty`)
- Modify: `WatchtowerDesktop/Sources/Views/Chat/ChatMessageRow.swift` (actions, hover, cards, inline edit)
- Rewrite: `WatchtowerDesktop/Sources/Views/Chat/ChatView.swift`
- Create: `WatchtowerDesktop/Sources/Views/Chat/ChatSidebarView.swift`, `ChatSearchView.swift`, `ChatThreadView.swift`, `ChatComposerView.swift`, `ChatEmptyState.swift`
- Delete: `WatchtowerDesktop/Sources/Views/Chat/ChatHistoryView.swift`
- Test: `WatchtowerDesktop/Tests/Core/ChatErrorPresentationTests.swift`, `WatchtowerDesktop/Tests/ChatHistoryViewModelSectionsTests.swift`, `WatchtowerDesktop/Tests/ChatMessageRowTests.swift`, `WatchtowerDesktop/Tests/ChatViewModelTests.swift` (append)

**Interfaces:**
- Consumes: Task 10 `ChatHistoryGrouping`, `ChatSearchQueries`, `ChatSearchHit`, `ChatConversationQueries.rename/pin/archive`; Task 14 `ChatViewModel` API, `ChatMessageRow`, `LiveAssistantRow`, `AssistantMessageBody`, `UserMessageBubble`; Task 12/13 views.
- Produces: `ChatErrorPresentation.message(for:) -> String`, `.isRetryable(_:) -> Bool` (Core); `ChatHistoryViewModel.sections`, `rename(_:title:)`, `togglePin(_:)`, `archive(_:)`, `search(_:) -> [ChatSearchHit]`, `lastError`, `now`; `ChatViewModel.open(_ hit: ChatSearchHit)`; `ChatRowActions`; `ChatMessageRow(item:isLast:isEditing:actions:)`; `ChatSidebarView(historyVM:chatVM:onNewChat:onDelete:)` with a `projectsSection` slot for Phase 4; `ChatSearchView(search:onOpen:)`; `ChatThreadView(chatVM:ownerName:)`; `ChatComposerView(chatVM:modelSuggestions:maxHeight:)` (instantiates `ChatInput`); `ChatEmptyState`; `ChatInput(…, maxHeight:, onEscape:, onArrowUpWhenEmpty:)`.

- [ ] **Step 1: Write the failing pure + VM tests**

Create `WatchtowerDesktop/Tests/Core/ChatErrorPresentationTests.swift`:

```swift
import XCTest
@testable import WatchtowerCore

/// Spec §5's table: which codes offer Retry and what the card says.
final class ChatErrorPresentationTests: XCTestCase {
    func testRetryability() {
        XCTAssertFalse(ChatErrorPresentation.isRetryable("auth"))
        XCTAssertFalse(ChatErrorPresentation.isRetryable("attachment_unsupported"))
        for code in ["rate_limit", "provider_unavailable", "internal", "session_lost", nil, "unknown"] {
            XCTAssertTrue(ChatErrorPresentation.isRetryable(code), "\(code ?? "nil")")
        }
    }

    func testMessages() {
        XCTAssertTrue(ChatErrorPresentation.message(for: "auth").contains("claude login"))
        XCTAssertTrue(ChatErrorPresentation.message(for: "rate_limit").contains("rate"))
        XCTAssertFalse(ChatErrorPresentation.message(for: nil).isEmpty)
    }
}
```

Create `WatchtowerDesktop/Tests/ChatHistoryViewModelSectionsTests.swift`:

```swift
import XCTest
import GRDB
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class ChatHistoryViewModelSectionsTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUpWithError() throws {
        (dbManager, dbPath) = try TestDatabase.createDatabaseManager()
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
    }

    private func loaded() async -> ChatHistoryViewModel {
        let vm = ChatHistoryViewModel(dbManager: dbManager)
        let done = expectation(description: "load")
        vm.load { done.fulfill() }
        await fulfillment(of: [done], timeout: 5)
        return vm
    }

    func testSectionsPinRenameArchive() async throws {
        let (a, b) = try dbManager.dbPool.write { d in
            (try TestDatabase.insertChatConversation(d, title: "A"), try TestDatabase.insertChatConversation(d, title: "B"))
        }
        let vm = await loaded()
        XCTAssertEqual(vm.sections.map(\.kind), [.today])

        vm.togglePin(a)
        XCTAssertEqual(vm.sections.map(\.kind), [.pinned, .today])
        vm.rename(b, title: "  Renamed  ")
        XCTAssertEqual(vm.conversations.first { $0.id == b }?.title, "Renamed")
        XCTAssertEqual(vm.conversations.first { $0.id == b }?.titleSource, "user")
        vm.rename(b, title: "   ")
        XCTAssertEqual(vm.conversations.first { $0.id == b }?.title, "Renamed", "an empty rename is ignored")

        vm.archive(a)
        XCTAssertFalse(vm.conversations.contains { $0.id == a })
        XCTAssertNil(vm.lastError)
    }

    func testSearchFindsMessages() async throws {
        try dbManager.dbPool.write { d in
            let conv = try TestDatabase.insertChatConversation(d, title: "X")
            try TestDatabase.insertChatMessage(d, conversationID: conv, role: "user", text: "payments rollout")
        }
        let vm = await loaded()
        XCTAssertEqual(vm.search("rollout").compactMap(\.messageID).count, 1)
        XCTAssertTrue(vm.search("").isEmpty)
    }
}
```

Append to `WatchtowerDesktop/Tests/ChatViewModelTests.swift` (inside the class):

```swift
    func testOpeningASearchHitShowsItsBranchAndScrollsToIt() async throws {
        let vm = try makeViewModel()
        let convID = try XCTUnwrap(vm.newConversation())
        vm.send(text: "q")
        try await complete(vm, turn: "turn-1", text: "first answer")
        let firstAnswer = try XCTUnwrap(vm.thread.last?.id)
        vm.regenerate(messageID: firstAnswer)
        try await complete(vm, turn: "turn-2", text: "second answer")
        _ = vm.newConversation()

        vm.open(ChatSearchHit(conversationID: convID, messageID: firstAnswer, title: "", snippet: ""))
        XCTAssertEqual(vm.conversationID, convID)
        XCTAssertEqual(vm.thread.last?.id, firstAnswer, "the hit's branch becomes the active one")
        XCTAssertEqual(vm.scrollTarget, firstAnswer)
    }

    func testArrowUpEditsTheLastUserMessage() async throws {
        let vm = try makeViewModel()
        _ = vm.newConversation()
        vm.send(text: "q")
        try await complete(vm, turn: "turn-1", text: "a")
        vm.beginEditingLast()
        XCTAssertEqual(vm.editingMessageID, vm.thread.first?.id)
    }
```

Create `WatchtowerDesktop/Tests/ChatMessageRowTests.swift`:

```swift
import XCTest
import SwiftUI
import GRDB
import ViewInspector
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

@MainActor
final class ChatMessageRowTests: XCTestCase {
    private func item(role: String, status: String, errorCode: String? = nil, siblings: Int = 1) throws -> ChatThreadItem {
        let db = try TestDatabase.create()
        let message = try db.write { d -> ChatMessageRecord in
            let conv = try TestDatabase.insertChatConversation(d)
            let id = try TestDatabase.insertChatMessage(d, conversationID: conv, role: role, text: "body", status: status)
            try d.execute(sql: "UPDATE chat_messages SET error_code = ? WHERE id = ?", arguments: [errorCode, id])
            return try XCTUnwrap(ChatMessageRecord.fetchOne(d, sql: "SELECT * FROM chat_messages WHERE id = ?", arguments: [id]))
        }
        return ChatThreadItem(message: message, steps: [], siblingIndex: 1, siblingCount: siblings)
    }

    func testRetryableErrorShowsRetry() throws {
        let row = ChatMessageRow(item: try item(role: "assistant", status: "error", errorCode: "rate_limit"),
                                 isLast: true, isEditing: false, actions: ChatRowActions())
        XCTAssertNoThrow(try row.inspect().find(text: "Retry"))
    }

    func testAuthErrorHasNoRetry() throws {
        let row = ChatMessageRow(item: try item(role: "assistant", status: "error", errorCode: "auth"),
                                 isLast: true, isEditing: false, actions: ChatRowActions())
        XCTAssertThrowsError(try row.inspect().find(text: "Retry"))
        XCTAssertNoThrow(try row.inspect().find(text: ChatErrorPresentation.message(for: "auth")))
    }

    func testStoppedLastMessageOffersContinue() throws {
        let row = ChatMessageRow(item: try item(role: "assistant", status: "partial"),
                                 isLast: true, isEditing: false, actions: ChatRowActions())
        XCTAssertNoThrow(try row.inspect().find(text: "Stopped"))
        XCTAssertNoThrow(try row.inspect().find(text: "Continue"))
    }

    func testVariantCounterShowsWithSiblings() throws {
        let row = ChatMessageRow(item: try item(role: "assistant", status: "complete", siblings: 3),
                                 isLast: true, isEditing: false, actions: ChatRowActions())
        XCTAssertNoThrow(try row.inspect().find(text: "1/3"))
    }

    /// Render isolation: equality ignores the action closures, so SwiftUI
    /// skips an unchanged row even though its closures are rebuilt per render.
    func testRowEqualityIgnoresClosures() throws {
        let base = try item(role: "assistant", status: "complete")
        let a = ChatMessageRow(item: base, isLast: false, isEditing: false, actions: ChatRowActions())
        let b = ChatMessageRow(item: base, isLast: false, isEditing: false,
                               actions: ChatRowActions(regenerate: { _ in XCTFail("never invoked by ==") }))
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, ChatMessageRow(item: base, isLast: true, isEditing: false, actions: ChatRowActions()))
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `make test-swift FILTER=ChatErrorPresentationTests`, `make test-swift FILTER=ChatHistoryViewModelSectionsTests`, `make test-swift FILTER=ChatMessageRowTests`
Expected: FAIL — missing `ChatErrorPresentation`, `sections`, `ChatRowActions`.

- [ ] **Step 3: Error presentation (Core)**

Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/Chat/ChatErrorPresentation.swift`:

```swift
import Foundation

/// Spec §5 error table → card text + Retry. Keyed by the persisted
/// `chat_messages.error_code` (the wire message is not stored).
package enum ChatErrorPresentation {
    package static func message(for code: String?) -> String {
        switch code {
        case "auth": "The AI provider isn't signed in. Open Terminal and run: claude login"
        case "rate_limit": "The provider is rate-limiting requests. Try again in a moment."
        case "provider_unavailable": "The AI provider couldn't be started."
        case "session_lost": "The previous session couldn't be resumed."
        case "attachment_unsupported": "An attachment isn't supported by this provider."
        default: "Something went wrong while answering."
        }
    }

    package static func isRetryable(_ code: String?) -> Bool {
        code != "auth" && code != "attachment_unsupported"
    }
}
```

- [ ] **Step 4: History view model additions**

In `ChatHistoryViewModel.swift` add (keeping the existing members):

```swift
    var lastError: String?
    /// Injectable for tests; section boundaries are computed against it.
    @ObservationIgnored var now: () -> Date = Date.init

    var sections: [ChatHistorySection] {
        ChatHistoryGrouping.group(filteredConversations, now: now(), calendar: .current)
    }

    func rename(_ id: Int64, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutate { db in try ChatConversationQueries.rename(db, id: id, title: String(trimmed.prefix(120))) }
    }

    func togglePin(_ id: Int64) {
        let pinned = conversations.first { $0.id == id }?.pinned ?? false
        mutate { db in try ChatConversationQueries.pin(db, id: id, pinned: !pinned) }
    }

    func archive(_ id: Int64) {
        mutate { db in try ChatConversationQueries.archive(db, id: id) }
        if selectedConversationID == id { selectedConversationID = conversations.first?.id }
    }

    /// ⌘K. A read failure is reported, not shown as "no results".
    func search(_ query: String) -> [ChatSearchHit] {
        do {
            return try dbManager.dbPool.read { db in try ChatSearchQueries.search(db, query: query) }
        } catch {
            lastError = "Search failed: \(error.localizedDescription)"
            return []
        }
    }

    private func mutate(_ write: (Database) throws -> Void) {
        do {
            try dbManager.dbPool.write { db in try write(db) }
            lastError = nil
            reloadSynchronously()
        } catch {
            lastError = error.localizedDescription
        }
    }
```

- [ ] **Step 5: `ChatViewModel.open(_:)`**

Add to `ChatViewModel` (Conversations section):

```swift
    /// ⌘K hit: open the conversation, make the hit's branch active, scroll to it.
    func open(_ hit: ChatSearchHit) {
        select(conversationID: hit.conversationID)
        guard let messageID = hit.messageID else { return }
        selectVariant(messageID: messageID)
        scrollTarget = messageID
    }
```

- [ ] **Step 6: Row actions, hover, cards, inline edit**

Replace `ChatMessageRow` in `ChatMessageRow.swift` (keep `LiveAssistantRow`, `AssistantMessageBody`, `UserMessageBubble`):

```swift
/// What a row can ask of the thread. Closures are rebuilt per render and are
/// deliberately excluded from `ChatMessageRow`'s equality.
struct ChatRowActions {
    var copy: (String) -> Void = { _ in }
    var regenerate: (Int64) -> Void = { _ in }
    var retry: (Int64) -> Void = { _ in }
    var continueStopped: (Int64) -> Void = { _ in }
    var showVariant: (Int64, Int) -> Void = { _, _ in }
    var beginEdit: (Int64) -> Void = { _ in }
    var submitEdit: (Int64, String) -> Void = { _, _ in }
    var cancelEdit: () -> Void = {}
}

/// A finished message. `Equatable` on its data only + `.equatable()` at the
/// call site: an unchanged row never re-renders its markdown (render isolation).
struct ChatMessageRow: View, Equatable {
    let item: ChatThreadItem
    let isLast: Bool
    let isEditing: Bool
    let actions: ChatRowActions
    @State private var hovering = false
    @State private var editText = ""

    static func == (lhs: ChatMessageRow, rhs: ChatMessageRow) -> Bool {
        lhs.item == rhs.item && lhs.isLast == rhs.isLast && lhs.isEditing == rhs.isEditing
    }

    var body: some View {
        VStack(alignment: item.message.isUser ? .trailing : .leading, spacing: 4) {
            content
            if !item.message.isAssistant || item.message.status == "complete" {
                actionBar.opacity(hovering || isLast ? 1 : 0)
            }
        }
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var content: some View {
        if item.message.isUser {
            if isEditing { editor } else { UserMessageBubble(text: item.message.text) }
        } else if item.message.isAssistant {
            AssistantMessageBody(text: item.message.text, steps: item.stepDisplays, isRunning: false)
            statusCard
        } else {
            Text(item.message.text).font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private var statusCard: some View {
        switch item.message.status {
        case "error":
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
                Text(ChatErrorPresentation.message(for: item.message.errorCode)).font(.callout)
                Spacer()
                if ChatErrorPresentation.isRetryable(item.message.errorCode) {
                    Button("Retry") { actions.retry(item.id) }
                }
            }
            .padding(8)
            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        case "partial":
            HStack(spacing: 8) {
                Text("Stopped").font(.caption).foregroundStyle(.secondary)
                if isLast { Button("Continue") { actions.continueStopped(item.id) }.controlSize(.small) }
            }
        default:
            EmptyView()
        }
    }

    private var editor: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextEditor(text: $editText)
                .frame(minHeight: 60, maxHeight: 200)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(.textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Button("Cancel", role: .cancel) { actions.cancelEdit() }
                Button("Save & Send") { actions.submitEdit(item.id, editText) }
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .onAppear { editText = item.message.text }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button { actions.copy(item.message.text) } label: { Image(systemName: "doc.on.doc") }
                .help("Copy message")
            if item.message.isUser {
                Button { actions.beginEdit(item.id) } label: { Image(systemName: "pencil") }
                    .help("Edit")
            } else if item.message.isAssistant {
                Button { actions.regenerate(item.id) } label: { Image(systemName: "arrow.clockwise") }
                    .help("Regenerate")
            }
            if item.siblingCount > 1 {
                Button { actions.showVariant(item.id, -1) } label: { Image(systemName: "chevron.left") }
                    .disabled(item.siblingIndex <= 1)
                Text("\(item.siblingIndex)/\(item.siblingCount)").font(.caption).monospacedDigit()
                Button { actions.showVariant(item.id, 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(item.siblingIndex >= item.siblingCount)
            }
            Text(caption).font(.caption2).foregroundStyle(.tertiary)
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }

    private var caption: String {
        let time = item.message.createdDate.formatted(date: .omitted, time: .shortened)
        guard let model = item.message.model, !model.isEmpty else { return time }
        return "\(model) · \(time)"
    }
}
```

Run: `make test-swift FILTER=ChatMessageRowTests` → PASS.

- [ ] **Step 7: `ChatInput` gains the composer hooks (additive, defaulted)**

In `WatchtowerDesktop/Sources/Views/Chat/ChatInput.swift`:
1. In `ChatInput`, after `var dictationTargetID: String?`, add:

```swift
    /// Main-chat composer grows to ~40% of the window; Discuss chats keep 120.
    var maxHeight: CGFloat = 120
    var onEscape: (() -> Void)?
    /// ↑ in an empty field (main chat: edit the last message).
    var onArrowUpWhenEmpty: (() -> Void)?
```

and pass `maxHeight: maxHeight, onEscape: onEscape, onArrowUpWhenEmpty: onArrowUpWhenEmpty` into `ChatInputContent(...)`.
2. In `ChatInputContent`, after `var dictationCenter: DictationCenter?`, add the same three properties (same defaults), and construct the text input as:

```swift
                ExpandingTextInput(
                    text: $text,
                    height: $inputHeight,
                    maxHeight: maxHeight,
                    onEscape: onEscape,
                    onArrowUpWhenEmpty: onArrowUpWhenEmpty
                ) {
                    guard canSend else { return }
                    onSend()
                }
```

3. `ExpandingTextInput`: drop `private` from `private struct ExpandingTextInput`, replace `private let maxHeight: CGFloat = 120` with the three properties below (declared before `var onSubmit`):

```swift
    var maxHeight: CGFloat = 120
    var onEscape: (() -> Void)?
    var onArrowUpWhenEmpty: (() -> Void)?
```

make `updateNSView` start with `context.coordinator.parent = self` (so closures and `maxHeight` stay current), and in `Coordinator.textView(_:doCommandBy:)` add before `return false`:

```swift
            if sel == #selector(NSResponder.cancelOperation(_:)), let onEscape = parent.onEscape {
                onEscape()
                return true
            }
            if sel == #selector(NSResponder.moveUp(_:)), textView.string.isEmpty, let up = parent.onArrowUpWhenEmpty {
                up()
                return true
            }
```

Run: `make test-swift FILTER=ChatInput` → existing `ChatInputContent` tests still PASS (new params are defaulted).

- [ ] **Step 8: The new views**

Create `WatchtowerDesktop/Sources/Views/Chat/ChatEmptyState.swift`:

```swift
import SwiftUI

struct ChatStarterPrompt: Identifiable {
    let title: String
    let text: String
    /// "Summarize PROJ-…" needs the owner's issue key: it fills the composer instead.
    let sendsImmediately: Bool
    var id: String { title }

    static let all = [
        ChatStarterPrompt(title: "What mattered yesterday?", text: "What mattered yesterday?", sendsImmediately: true),
        ChatStarterPrompt(title: "Prep me for today's meetings", text: "Prep me for today's meetings", sendsImmediately: true),
        ChatStarterPrompt(title: "What's waiting on me?", text: "What's waiting on me?", sendsImmediately: true),
        ChatStarterPrompt(title: "Summarize PROJ-…", text: "Summarize ", sendsImmediately: false)
    ]
}

/// Spec §3.6: greeting + four work prompts. Replaces the Welcome chat.
struct ChatEmptyState: View {
    let ownerName: String
    let onPrompt: (ChatStarterPrompt) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text(greeting).font(.title2).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(ChatStarterPrompt.all) { prompt in
                    Button(prompt.title) { onPrompt(prompt) }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: 520)
        }
        .padding(.top, 80)
        .frame(maxWidth: .infinity)
    }

    private var greeting: String {
        let first = ownerName.split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? "What can I help with?" : "What can I help with, \(first)?"
    }
}
```

Create `WatchtowerDesktop/Sources/Views/Chat/ChatThreadView.swift`:

```swift
import SwiftUI
import AppKit
import WatchtowerCore

/// The centered thread column (spec §3.1, max ~760 pt). Reads `liveTurn`
/// identity only; its text is read by `LiveAssistantRow` alone.
struct ChatThreadView: View {
    @Bindable var chatVM: ChatViewModel
    let ownerName: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if chatVM.thread.isEmpty {
                        ChatEmptyState(ownerName: ownerName, onPrompt: usePrompt)
                    }
                    ForEach(chatVM.thread) { item in
                        row(item).id(item.id)
                        actionCards(forTurn: item.message.turnID)
                    }
                    unattachedActionCards
                    errors
                }
                .padding(.vertical, 16)
                .padding(.horizontal, 20)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: chatVM.thread.last?.id) {
                if let last = chatVM.thread.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: chatVM.scrollTarget) {
                if let target = chatVM.scrollTarget { proxy.scrollTo(target, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private func row(_ item: ChatThreadItem) -> some View {
        if let live = chatVM.liveTurn, live.messageID == item.id {
            LiveAssistantRow(turn: live)
        } else {
            ChatMessageRow(item: item, isLast: item.id == chatVM.thread.last?.id,
                           isEditing: chatVM.editingMessageID == item.id, actions: actions)
                .equatable()
        }
    }

    private var actions: ChatRowActions {
        ChatRowActions(
            copy: { text in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            regenerate: { chatVM.regenerate(messageID: $0) },
            retry: { chatVM.retry(messageID: $0) },
            continueStopped: { chatVM.continueStopped(messageID: $0) },
            showVariant: { id, offset in
                if let target = chatVM.variant(of: id, offset: offset) { chatVM.selectVariant(messageID: target) }
            },
            beginEdit: { chatVM.editingMessageID = $0 },
            submitEdit: { chatVM.edit(messageID: $0, newText: $1) },
            cancelEdit: { chatVM.editingMessageID = nil }
        )
    }

    private func usePrompt(_ prompt: ChatStarterPrompt) {
        if prompt.sendsImmediately {
            chatVM.send(text: prompt.text)
        } else {
            chatVM.draft = prompt.text
        }
    }

    @ViewBuilder
    private func actionCards(forTurn turn: String) -> some View {
        if !turn.isEmpty {
            let cards = chatVM.actionFeed.cards(forTurn: turn)
            if cards.filter(\.isPending).count >= 2 {
                Button("Approve all") { Task { await chatVM.actionFeed.approveAllPending(forTurn: turn) } }
                    .font(.caption)
            }
            ForEach(cards) { action in agentActionCard(action) }
        }
    }

    /// Proposals whose turn never persisted a message — unreachable otherwise.
    @ViewBuilder
    private var unattachedActionCards: some View {
        let orphans = AgentActionFeed.unattached(
            rows: chatVM.actionFeed.rows,
            messageTurnIDs: Set(chatVM.thread.map(\.message.turnID).filter { !$0.isEmpty })
        )
        if !orphans.isEmpty {
            Text("Proposals from an interrupted turn").font(.caption).foregroundStyle(.secondary)
            ForEach(orphans) { action in agentActionCard(action) }
        }
    }

    @ViewBuilder
    private var errors: some View {
        if let error = chatVM.errorMessage {
            Text(error)
                .font(.callout)
                .foregroundStyle(.red)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
        if let persist = chatVM.liveTurn?.persistError {
            Text(persist).font(.caption).foregroundStyle(.red)
        }
        if let err = chatVM.actionFeed.lastError {
            Text(err).font(.caption).foregroundStyle(.red)
        }
    }

    private func agentActionCard(_ action: AgentAction) -> some View {
        AgentActionCardView(
            action: action,
            inFlight: chatVM.actionFeed.inFlight.contains(action.id),
            onApprove: { Task { await chatVM.actionFeed.approve(action.id) } },
            onReject: { Task { await chatVM.actionFeed.reject(action.id) } },
            onRetry: { Task { await chatVM.actionFeed.retry(action.id) } }
        )
    }
}
```

Create `WatchtowerDesktop/Sources/Views/Chat/ChatComposerView.swift`:

```swift
import SwiftUI
import WatchtowerCore

/// Spec §3.5: Enter send, Shift+Enter newline, Esc stop, ↑ in an empty field
/// edits the last message, dictation, and the provider/model pill. Grows to
/// `maxHeight` (~40% of the window). The first keystroke prewarms the session.
struct ChatComposerView: View {
    @Bindable var chatVM: ChatViewModel
    let modelSuggestions: [String]
    let maxHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ChatInput(
                text: $chatVM.draft,
                isStreaming: chatVM.isStreaming,
                onSend: { chatVM.sendDraft() },
                onStop: { chatVM.stop() },
                placeholder: "Ask about your work…",
                dictationTargetID: "chat.workspace",
                maxHeight: maxHeight,
                onEscape: { chatVM.stop() },
                onArrowUpWhenEmpty: { chatVM.beginEditingLast() }
            )
            modelPill.padding(.horizontal, 16).padding(.bottom, 6)
        }
        .onChange(of: chatVM.draft) { old, new in
            if old.isEmpty, !new.isEmpty { chatVM.prewarm() }
        }
    }

    private var modelPill: some View {
        Menu {
            Section("Provider") {
                ForEach(AIProvider.allCases) { provider in
                    Button(provider.displayName) { chatVM.switchProvider(provider) }
                }
            }
            Section("Model") {
                Button("Auto") { chatVM.selectedModel = "" }
                ForEach(modelSuggestions, id: \.self) { model in
                    Button(model) { chatVM.selectedModel = model }
                }
            }
        } label: {
            Text("\(chatVM.selectedProvider.displayName) · \(chatVM.selectedModel.isEmpty ? "Auto" : chatVM.selectedModel)")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(chatVM.isStreaming)
        .help("Provider and model for this chat")
    }
}
```

Create `WatchtowerDesktop/Sources/Views/Chat/ChatSearchView.swift`:

```swift
import SwiftUI
import WatchtowerCore

/// ⌘K (spec §3.1): FTS over chat history with highlighted snippets.
struct ChatSearchView: View {
    let search: (String) -> [ChatSearchHit]
    let onOpen: (ChatSearchHit) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [ChatSearchHit] = []

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search chats", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(12)
                .onSubmit { if let first = hits.first { open(first) } }
                .onChange(of: query) { hits = search(query) }
            Divider()
            List(hits) { hit in
                Button { open(hit) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hit.title.isEmpty ? "New Chat" : hit.title).font(.headline)
                        if hit.messageID != nil {
                            Text(hit.attributedSnippet).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .frame(width: 560, height: 420)
        .onExitCommand { dismiss() }
    }

    private func open(_ hit: ChatSearchHit) {
        onOpen(hit)
        dismiss()
    }
}
```

Create `WatchtowerDesktop/Sources/Views/Chat/ChatSidebarView.swift`:

```swift
import SwiftUI
import WatchtowerCore

/// History on the left (spec §3.1): Pinned / Today / Yesterday / 7 / 30 /
/// Older, with rename, pin, archive, delete. Projects (Phase 4) sit above.
struct ChatSidebarView: View {
    @Bindable var historyVM: ChatHistoryViewModel
    let chatVM: ChatViewModel
    let onNewChat: () -> Void
    let onDelete: (Int64) -> Void
    @State private var renaming: ChatConversation?
    @State private var renameText = ""
    @State private var deleting: ChatConversation?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chats").font(.headline)
                Spacer()
                Button(action: onNewChat) { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.borderless)
                    .help("New Chat (⌘N)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            List(selection: $historyVM.selectedConversationID) {
                projectsSection
                ForEach(historyVM.sections) { section in
                    Section(section.kind.title) {
                        ForEach(section.conversations) { conv in
                            Text(conv.displayTitle)
                                .lineLimit(1)
                                .tag(conv.id)
                                .contextMenu { menu(conv) }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            if let error = historyVM.lastError {
                Text(error).font(.caption).foregroundStyle(.red).padding(8)
            }
        }
        .alert("Rename Chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Save") {
                if let conv = renaming { historyVM.rename(conv.id, title: renameText) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete Chat?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) {
                if let conv = deleting { onDelete(conv.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This conversation will be permanently deleted.")
        }
    }

    /// Phase 4 (Task 24) replaces this with the Projects section.
    @ViewBuilder private var projectsSection: some View {
        EmptyView()
    }

    @ViewBuilder
    private func menu(_ conv: ChatConversation) -> some View {
        Button("Rename…") {
            renameText = conv.title
            renaming = conv
        }
        Button(conv.pinned ? "Unpin" : "Pin") { historyVM.togglePin(conv.id) }
        Button("Archive") {
            chatVM.forget(conversationID: conv.id)
            historyVM.archive(conv.id)
        }
        Divider()
        Button("Delete…", role: .destructive) { deleting = conv }
    }
}
```

`git rm WatchtowerDesktop/Sources/Views/Chat/ChatHistoryView.swift`.

- [ ] **Step 9: Rewrite `ChatView`**

Replace `WatchtowerDesktop/Sources/Views/Chat/ChatView.swift`:

```swift
import SwiftUI
import WatchtowerCore

struct ChatView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            if let chatVM = appState.chatViewModel, let historyVM = appState.chatHistoryViewModel {
                ChatSplitView(chatVM: chatVM, historyVM: historyVM)
            } else {
                ProgressView()
            }
        }
        .onAppear { appState.ensureChatViewModels() }
        .task { await appState.aiModelCatalog.load() }
    }
}

/// Holds view-local layout state; the VMs live on AppState and survive tab switches.
private struct ChatSplitView: View {
    @Environment(AppState.self) private var appState
    @Bindable var chatVM: ChatViewModel
    @Bindable var historyVM: ChatHistoryViewModel
    @State private var showSidebar = true
    @State private var showSearch = false
    @State private var showRename = false
    @State private var renameText = ""

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                if showSidebar {
                    ChatSidebarView(historyVM: historyVM, chatVM: chatVM, onNewChat: createNewChat, onDelete: delete)
                        .frame(width: 260)
                    Divider()
                }
                VStack(spacing: 0) {
                    toolbar
                    Divider()
                    ChatThreadView(chatVM: chatVM, ownerName: appState.owner.displayName)
                    ChatComposerView(
                        chatVM: chatVM,
                        modelSuggestions: appState.aiModelCatalog.suggestions(for: chatVM.selectedProvider.rawValue),
                        maxHeight: max(120, geo.size.height * 0.4)
                    )
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .onChange(of: historyVM.selectedConversationID) { _, newID in
            if let newID { chatVM.select(conversationID: newID) }
        }
        .sheet(isPresented: $showSearch) {
            ChatSearchView(search: { historyVM.search($0) }, onOpen: open)
        }
        .alert("Rename Chat", isPresented: $showRename) {
            TextField("Title", text: $renameText)
            Button("Save") {
                if let id = chatVM.conversationID {
                    historyVM.rename(id, title: renameText)
                    chatVM.reload()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { showSidebar.toggle() } } label: {
                Image(systemName: "sidebar.leading")
            }
            .help("Toggle Chat History")
            Text(chatVM.currentConversation?.displayTitle ?? "New Chat")
                .font(.headline)
                .lineLimit(1)
                .onTapGesture(count: 2) {
                    guard chatVM.conversationID != nil else { return }
                    renameText = chatVM.currentConversation?.title ?? ""
                    showRename = true
                }
                .help("Double-click to rename")
            Spacer()
            Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }
                .keyboardShortcut("k", modifiers: .command)
                .help("Search Chats (⌘K)")
            Button(action: createNewChat) { Image(systemName: "square.and.pencil") }
                .keyboardShortcut("n", modifiers: .command)
                .help("New Chat (⌘N)")
            Button { appState.startOnboarding() } label: { Image(systemName: "person.crop.circle.badge.questionmark") }
                .help(appState.profileComplete ? "Update Profile" : "Setup Profile")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func createNewChat() {
        if let id = chatVM.newConversation() { historyVM.selectedConversationID = id }
    }

    private func delete(_ id: Int64) {
        chatVM.forget(conversationID: id)
        historyVM.deleteConversation(id)
        if let next = historyVM.selectedConversationID { chatVM.select(conversationID: next) }
    }

    private func open(_ hit: ChatSearchHit) {
        chatVM.open(hit)
        historyVM.selectedConversationID = hit.conversationID
    }
}
```

- [ ] **Step 10: Run the tests, build, lint**

Run: `make test-swift FILTER=ChatErrorPresentationTests`, `make test-swift FILTER=ChatHistoryViewModel`, `make test-swift FILTER=ChatMessageRowTests`, `make test-swift FILTER=ChatViewModelTests`, `make test-swift FILTER=ChatInput`, then `cd WatchtowerDesktop && swift build > /tmp/wt-build.log 2>&1; echo "exit $?"`, then `make lint-swift`
Expected: all PASS, `exit 0`, lint clean.

- [ ] **Step 11: Manual smoke (record the result in the PR description)**

`make app-dev`, open AI Chat: history on the left grouped by day; ⌘K finds an old message and scrolls to it; ⌘N opens the empty state with four prompts; a long answer streams as markdown with a steps block and chips; hover a reply → Copy / Regenerate / ‹ 1/2 ›; Esc stops a reply ("Stopped" + Continue); ↑ in the empty composer edits the last message; switch to another tab mid-answer and back — the answer is still streaming.

- [ ] **Step 12: Commit**

```bash
git add WatchtowerDesktop/Sources WatchtowerDesktop/Tests
git commit -m "feat(desktop): new main chat UI" \
  -m "Left history grouped by day with rename/pin/archive/delete, Cmd-K search over chat history, centered thread with hover actions, variants, error/stopped cards, a growing composer with Esc/arrow-up and a provider/model pill, and a work-prompt empty state." \
  -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 16: App wiring — policy poll, quit closes sessions, provider/model recycling

**Files:**
- Modify: `WatchtowerDesktop/Sources/App/AppState.swift` (`ensureChatSessionPool`, `initFeatureViewModels(manager:)`)
- Modify: `WatchtowerDesktop/Sources/App/QuitCoordinator.swift`
- Modify: `WatchtowerDesktop/Sources/App/TrayAppDelegate.swift:215-244`
- Modify: `WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift` (`selectedModel` observer, `switchProvider`, `applyConversationSettings`)
- Test: `WatchtowerDesktop/Tests/QuitCoordinatorTests.swift`, `WatchtowerDesktop/Tests/TrayAppDelegateTests.swift`, `WatchtowerDesktop/Tests/ChatViewModelTests.swift` (append)

**Interfaces:**
- Consumes: Task 11 `ChatSessionPool.startPolicy()`, `.closeAll()`, `.close(conversationID:)`; Task 14 `AppState.chatSessionPool`, `ensureChatSessionPool(_:)`, `ChatViewModel`.
- Produces: `QuitCoordinator.shouldTerminate(hasBlockingWork:confirmQuit:closeChatSessions:stopDaemon:reply:)` (new parameter defaulted to `{}`); `TrayAppDelegate.terminateDecision(managesLifecycle:hasBlockingWork:confirmQuit:closeChatSessions:stopDaemon:reply:)` (same default); the pool polls from DB-open; a provider/model change closes the conversation's live session.

- [ ] **Step 1: Write the failing tests**

Append to `QuitCoordinatorTests` (the `@MainActor final class` in `WatchtowerDesktop/Tests/QuitCoordinatorTests.swift`):

```swift
    /// CHAT-03: no chat session process outlives the app, and they are closed
    /// BEFORE the daemon stop (each keeps its partial text, CHAT-01).
    func testChat03QuitClosesChatSessionsBeforeStoppingTheDaemon() async {
        var order: [String] = []
        let replied = expectation(description: "replied")
        let reply = QuitCoordinator.shouldTerminate(
            hasBlockingWork: false,
            confirmQuit: { true },
            closeChatSessions: { order.append("chat") },
            stopDaemon: { order.append("daemon") },
            reply: { ok in XCTAssertTrue(ok); replied.fulfill() })
        XCTAssertEqual(reply, .terminateLater)
        await fulfillment(of: [replied], timeout: 5)
        XCTAssertEqual(order, ["chat", "daemon"])
    }

    func testCancelledQuitLeavesChatSessionsRunning() {
        var closed = false
        let reply = QuitCoordinator.shouldTerminate(
            hasBlockingWork: true,
            confirmQuit: { false },
            closeChatSessions: { closed = true },
            stopDaemon: {},
            reply: { _ in XCTFail("must not reply") })
        XCTAssertEqual(reply, .terminateCancel)
        XCTAssertFalse(closed)
    }
```

Append to the class in `WatchtowerDesktop/Tests/TrayAppDelegateTests.swift`:

```swift
    func testTerminateDecisionClosesChatSessionsWhenManagingLifecycle() async {
        var closed = false
        let replied = expectation(description: "replied")
        _ = TrayAppDelegate.terminateDecision(
            managesLifecycle: true, hasBlockingWork: false, confirmQuit: { true },
            closeChatSessions: { closed = true }, stopDaemon: {}, reply: { _ in replied.fulfill() })
        await fulfillment(of: [replied], timeout: 5)
        XCTAssertTrue(closed)
    }
```

(If `TrayAppDelegateTests` is not `@MainActor`, mark this method `@MainActor`.)

Append to `ChatViewModelTests`:

```swift
    // MARK: - Provider / model recycling (spec §1.4)

    func testSwitchingProviderClosesTheSessionAndTheNextTurnUsesTheNewProvider() async throws {
        let vm = try makeViewModel()
        _ = vm.newConversation()
        let first = try lastFake()
        vm.switchProvider(.codex)
        let closed = await waitForCondition { first.sent.contains(.close) }
        XCTAssertTrue(closed)
        XCTAssertTrue(vm.send(text: "q"))
        XCTAssertEqual(try lastFake().argument(after: "--provider"), "codex")
        XCTAssertNil(try lastFake().argument(after: "--resume"), "codex replays instead of resuming")
    }

    func testChangingModelKeepsClaudeResume() async throws {
        let convID = try dbManager.dbPool.write { d in
            try TestDatabase.insertChatConversation(d, sessionID: "s1", provider: "claude")
        }
        let vm = try makeViewModel()
        vm.select(conversationID: convID)
        let first = try lastFake()
        vm.selectedModel = "model-b"
        let closed = await waitForCondition { first.sent.contains(.close) }
        XCTAssertTrue(closed)
        XCTAssertTrue(vm.send(text: "q"))
        XCTAssertEqual(try lastFake().argument(after: "--model"), "model-b")
        XCTAssertEqual(try lastFake().argument(after: "--resume"), "s1")
    }

    /// Restoring a conversation's own provider/model on select is not a change.
    func testSelectingAConversationDoesNotRecycleItsOwnSession() throws {
        let convID = try dbManager.dbPool.write { d in
            let conv = try TestDatabase.insertChatConversation(d, provider: "codex")
            try d.execute(sql: "UPDATE chat_conversations SET model = 'model-b' WHERE id = ?", arguments: [conv])
            return conv
        }
        let vm = try makeViewModel()
        vm.select(conversationID: convID)
        XCTAssertEqual(fakes.count, 1)
        XCTAssertFalse(try lastFake().sent.contains(.close))
    }
```

- [ ] **Step 2: Run them to verify they fail**

Run: `make test-swift FILTER=QuitCoordinatorTests`, `make test-swift FILTER=TrayAppDelegateTests`, `make test-swift FILTER=ChatViewModelTests`
Expected: FAIL — `extra argument 'closeChatSessions'`; the two recycling tests fail (`first.sent` never contains `.close`).

- [ ] **Step 3: Quit path**

Replace `QuitCoordinator.shouldTerminate` in `WatchtowerDesktop/Sources/App/QuitCoordinator.swift`:

```swift
    static func shouldTerminate(
        hasBlockingWork: Bool,
        confirmQuit: () -> Bool,
        closeChatSessions: @escaping () async -> Void = {},
        stopDaemon: @escaping () async -> Void,
        reply: @escaping (Bool) -> Void
    ) -> NSApplication.TerminateReply {
        if hasBlockingWork && !confirmQuit() {
            return .terminateCancel
        }
        Task { @MainActor in
            // CHAT-03: every chat session gets `close`, then SIGTERM after
            // its grace — bounded, and each keeps its partial text (CHAT-01).
            await closeChatSessions()
            await stopDaemon()
            // Always let termination proceed: a stuck daemon must never trap
            // the user in a quit — the next launch adopts or replaces it.
            reply(true)
        }
        return .terminateLater
    }
```

In `TrayAppDelegate.swift`, give `terminateDecision` the same defaulted parameter after `confirmQuit` and pass it through:

```swift
    @MainActor
    static func terminateDecision(
        managesLifecycle: Bool,
        hasBlockingWork: Bool,
        confirmQuit: () -> Bool,
        closeChatSessions: @escaping () async -> Void = {},
        stopDaemon: @escaping () async -> Void,
        reply: @escaping (Bool) -> Void
    ) -> NSApplication.TerminateReply {
        guard managesLifecycle else { return .terminateNow }
        return QuitCoordinator.shouldTerminate(
            hasBlockingWork: hasBlockingWork,
            confirmQuit: confirmQuit,
            closeChatSessions: closeChatSessions,
            stopDaemon: stopDaemon,
            reply: reply
        )
    }
```

and in `applicationShouldTerminate` add the argument:

```swift
            closeChatSessions: { await AppState.shared.chatSessionPool?.closeAll() },
```

- [ ] **Step 4: The pool polls from DB-open**

In `AppState.ensureChatSessionPool(_:)` start the policy loop when the pool is created:

```swift
    @discardableResult
    func ensureChatSessionPool(_ db: DatabaseManager) -> ChatSessionPool {
        if let chatSessionPool { return chatSessionPool }
        let pool = ChatSessionPool(dbPool: db.dbPool)
        // CHAT-03: an idle session dies within TTL + one 30 s poll.
        pool.startPolicy()
        chatSessionPool = pool
        return pool
    }
```

and at the end of `initFeatureViewModels(manager:)` add:

```swift
        ensureChatSessionPool(manager)
```

(so the quit path has a pool to close even before the Chat tab was ever opened — `closeAll()` on an empty pool is a no-op).

- [ ] **Step 5: Provider/model change recycles the session**

In `ChatViewModel.swift`:
1. Replace `var selectedModel = ""` with:

```swift
    /// Model override; "" = the provider's resolved strong model (the CLI resolves it).
    var selectedModel = "" {
        didSet { if selectedModel != oldValue { recycleSession() } }
    }
```

2. Add under the other `@ObservationIgnored` state:

```swift
    @ObservationIgnored private var applyingConversationSettings = false
```

3. Replace `switchProvider(_:)` and `applyConversationSettings()`, and add `recycleSession()`:

```swift
    func switchProvider(_ provider: AIProvider) {
        guard provider != selectedProvider else { return }
        selectedProvider = provider
        selectedModel = ""
        recycleSession()
    }

    private func applyConversationSettings() {
        guard let conv = currentConversation, let raw = conv.provider else { return }
        applyingConversationSettings = true
        defer { applyingConversationSettings = false }
        if let provider = AIProvider(rawValue: raw) { selectedProvider = provider }
        selectedModel = conv.model ?? ""
    }

    /// The live process was spawned for the old provider/model: close it; the
    /// next turn spawns a matching one (Claude keeps `--resume`, the others
    /// replay). Never mid-turn — the picker is disabled while streaming.
    private func recycleSession() {
        guard !applyingConversationSettings, !isStreaming, let id = conversationID else { return }
        pool.close(conversationID: id)
    }
```

- [ ] **Step 6: Run the tests**

Run: `make test-swift FILTER=QuitCoordinatorTests` then `make test-swift FILTER=TrayAppDelegateTests` then `make test-swift FILTER=ChatViewModelTests` then `make test-swift FILTER=ChatSessionPoolTests`
Expected: all PASS.

- [ ] **Step 7: Phase gate**

Run: `make test-swift > /tmp/wt-swift.log 2>&1; echo "exit $?"` then `make lint-swift`
Expected: `exit 0` (check the XCTest summary above the swift-testing tail, not only the last line); lint clean.

- [ ] **Step 8: Manual quit check (record in the PR description)**

`make app-dev`; open two chats, start a long answer in one; Cmd+Q. Then `pgrep -fl "watchtower ai session"` and `pgrep -fl "claude -p"` print nothing, and reopening the app shows the interrupted answer with "Stopped" + Continue.

- [ ] **Step 9: Commit**

```bash
git add WatchtowerDesktop/Sources/App WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift \
  WatchtowerDesktop/Tests/QuitCoordinatorTests.swift WatchtowerDesktop/Tests/TrayAppDelegateTests.swift \
  WatchtowerDesktop/Tests/ChatViewModelTests.swift
git commit -m "feat(desktop): chat sessions close on quit and recycle on provider change" \
  -m "The pool polls from DB-open, QuitCoordinator closes every chat session before stopping the daemon (CHAT-03), and a provider or model change closes the conversation's live session so the next turn spawns a matching one." \
  -m "Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

## Self-review notes (resolved while writing)

- **Spec coverage (Swift half of Phase 1):** §1.4 pool (Tasks 11, 16), §2.1 test mirror + floor check (Task 10), §2.3 branches (Tasks 10, 14), §3.1 layout/⌘K (Task 15), §3.2 steps/text/chips/hover/error cards (Tasks 13–15; artifact cards are Task 22/23), §3.3 renderer everywhere (Task 12), §3.5 composer minus attachments/mentions/skills (Task 15; Phase 3/4 add those), §3.6 empty state + Welcome removal (Tasks 14–15), §4.3 turn text (Task 11 `ChatTurnText`), §4.4 title trigger (Task 14), §5 error table (Task 15), CHAT-01/02/03/04 Swift guards (Tasks 11, 13, 14, 16).
- **Where persistence lives:** the skeleton lists the pool/client in the app target — kept; the logic they run (`ChatTurnDriver`, `LiveTurn`, `ChatTurnStore`, policy) is in Core so it is tested without the ML link.
- **Replay decision** is Swift-side (`ChatContinuity`): a turn replays whenever the parent of its user message is not the last message the live provider session saw; a `--resume` spawn adopts the conversation's leaf at its first turn.
- **Known v1 limit:** regenerate/edit re-send the stored user text only — REFERENCED mentions and attachments of the original turn are not re-attached (they are not persisted on the user row).
