# Secretary Memory Slice C: Chat Relevant-Memory Unification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Read `docs/superpowers/specs/2026-07-22-memory-slice-c-chat-relevant-memory-design.md` (the whole thing — it's short) first.

**Goal:** Generalize Discuss chat's existing `relevantMemory` (Swift, direct GRDB reads) into one shared, importance-ranked memory-context builder with a new recent-episodes section, and wire it into Track/Target/Meeting chat, which have no memory lookup today.

**Architecture:** A new file `WatchtowerDesktop/Sources/Services/Memory/RelevantMemory.swift` holds the shared ranking-and-render engine (`relevantMemoryContext`, `renderMemorySection`, `hotMap`, `cap4KB`), extracted from `SituationChatViewModel`. Each of the four chat view models keeps its own subject-resolution logic (which Slack channel/user ids or emails this chat is "about") next to its own code, then calls the shared engine. No Go or MCP changes — this is a Swift-only feature reading the already-shipped `memory_nodes.importance_score`/`memory_provenance.sender_id` columns.

**Tech Stack:** Swift 5.10, GRDB.swift, XCTest, `TestDatabase.swift` fixtures (WatchtowerDesktop).

## Global Constraints

- Swift Testing / XCTest via `swift test` (see `WatchtowerDesktop/Package.swift`); capture the real exit code, never pipe through `tail` alone.
- The `memory.surfaces.chat` config flag (`Constants.memorySurfacesChatEnabled()`) gates ALL FOUR chat types' memory blocks — no new flag. Flag off: Discuss stays byte-identical to today; Track/Target/Meeting simply never build a memory block (as now).
- No Go-side or MCP change. Only `WatchtowerDesktop/` is touched.
- Every new memory block is framed model-mediated ("notes the secretary has built from Slack/Jira — model-mediated, not the owner's own words" or the block's own equivalent wording) — never presented as the owner's/attendee's own words.
- A failed memory read (missing tables, query error) degrades to an empty context and logs once — it must never throw or block the chat from opening (the existing `relevantMemory`'s contract, unchanged).
- No dark compare-mode — this is a single-consumer local Swift feature, not shared server infrastructure (see design spec's Concept section for the reasoning).

## File Structure

- `WatchtowerDesktop/Sources/Services/Memory/RelevantMemory.swift` (new) — `MemoryContextResult`, `relevantMemoryContext(subjects:dbPool:)`, `renderMemorySection(hotMap:context:)`, `hotMap(vaultDir:)`, `cap4KB(_:)`.
- `WatchtowerDesktop/Tests/RelevantMemoryTests.swift` (new) — direct tests of the shared engine.
- `WatchtowerDesktop/Tests/Helpers/TestDatabase.swift` (modify) — `memory_nodes.importance_score` column, new `memory_provenance` table, `tracks.linked_target_id` column, `insertMemoryNode`'s new `importanceScore` param, new `insertMemoryProvenance` helper, `insertTrack`'s new `linkedTargetID` param + `Int64` return.
- `WatchtowerDesktop/Sources/ViewModels/SituationChatViewModel.swift` (modify) — delete the private `relevantMemory`/`memorySection`/`hotMap`/`cap4KB`/`MemoryBelief`, call the shared engine instead.
- `WatchtowerDesktop/Tests/SituationChatMemoryPromptTests.swift` (modify) — update ranking assertions, add a recent-activity assertion.
- `WatchtowerDesktop/Sources/Views/Tracks/TrackChatView.swift` (modify) — new `trackMemorySubjects(track:)`, memory block spliced into `buildSystemPrompt`.
- `WatchtowerDesktop/Tests/TrackChatMemoryPromptTests.swift` (new).
- `WatchtowerDesktop/Sources/ViewModels/TargetChatViewModel.swift` (modify) — new `targetMemorySubjects(target:dbPool:)`, memory block spliced into `buildSystemPrompt`.
- `WatchtowerDesktop/Tests/TargetChatMemoryPromptTests.swift` (new).
- `WatchtowerDesktop/Sources/ViewModels/MeetingChatViewModel.swift` (modify) — `buildSystemPrompt` gains a `dbPool: DatabasePool` parameter, new `meetingMemorySubjects(transcript:dbPool:)`, memory block spliced in.
- `WatchtowerDesktop/Tests/MeetingChatMemoryPromptTests.swift` (new).

---

## Task 1: Test infrastructure — importance_score, memory_provenance, tracks.linked_target_id

**Depends on:** nothing. **Blocks:** all other tasks (every test fixture in this plan needs these).

**Files:**
- Modify: `WatchtowerDesktop/Tests/Helpers/TestDatabase.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `memory_nodes.importance_score` column, `memory_provenance` table, `tracks.linked_target_id` column, `TestDatabase.insertMemoryNode(...)` gains `importanceScore: Double = 0`, new `TestDatabase.insertMemoryProvenance(...)`, `TestDatabase.insertTrack(...)` gains `linkedTargetID: Int? = nil` and returns `@discardableResult -> Int64` — consumed by every later task's tests.

This is pure test-infrastructure work — no production Swift code changes. `TestDatabase.swift`'s in-memory schema mirror is missing three things the real `internal/db/schema.sql` already has (Slice A's `memory_nodes.importance_score`, Slice B's `memory_provenance` table, and the pre-existing `tracks.linked_target_id` FK) — this is the same class of schema-drift this codebase has hit before (see `[[reference_tasks_targets]]`-style TestDatabase-vs-schema divergence).

Current `memory_nodes` mirror (`TestDatabase.swift`, in the `schema` string):

```sql
CREATE TABLE IF NOT EXISTS memory_nodes (
    id            TEXT PRIMARY KEY,
    type          TEXT NOT NULL CHECK (type IN ('entity','episode','rollup','belief')),
    tier          TEXT NOT NULL DEFAULT 'long' CHECK (tier IN ('short','long')),
    status        TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','closed','tombstone','shaken','retired')),
    redirect_to   TEXT,
    title         TEXT NOT NULL DEFAULT '',
    path          TEXT NOT NULL DEFAULT '',
    content_hash  TEXT NOT NULL DEFAULT '',
    indexed_at    TEXT NOT NULL DEFAULT '',
    subject       TEXT NOT NULL DEFAULT '',
    confidence    REAL NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS memory_aliases (
    alias    TEXT PRIMARY KEY COLLATE NOCASE,
    node_id  TEXT NOT NULL REFERENCES memory_nodes(id)
);
```

becomes:

```sql
CREATE TABLE IF NOT EXISTS memory_nodes (
    id            TEXT PRIMARY KEY,
    type          TEXT NOT NULL CHECK (type IN ('entity','episode','rollup','belief')),
    tier          TEXT NOT NULL DEFAULT 'long' CHECK (tier IN ('short','long')),
    status        TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','closed','tombstone','shaken','retired')),
    redirect_to   TEXT,
    title         TEXT NOT NULL DEFAULT '',
    path          TEXT NOT NULL DEFAULT '',
    content_hash  TEXT NOT NULL DEFAULT '',
    indexed_at    TEXT NOT NULL DEFAULT '',
    subject       TEXT NOT NULL DEFAULT '',
    confidence    REAL NOT NULL DEFAULT 0,
    importance_score REAL NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS memory_aliases (
    alias    TEXT PRIMARY KEY COLLATE NOCASE,
    node_id  TEXT NOT NULL REFERENCES memory_nodes(id)
);
CREATE TABLE IF NOT EXISTS memory_provenance (
    node_id     TEXT NOT NULL REFERENCES memory_nodes(id),
    scheme      TEXT NOT NULL DEFAULT '',
    channel_id  TEXT NOT NULL,
    ts_raw      TEXT NOT NULL,
    ts_unix     REAL NOT NULL,
    sender_id   TEXT NOT NULL DEFAULT '',
    PRIMARY KEY (node_id, channel_id, ts_raw)
);
```

Current `tracks` mirror's last two columns before the closing paren:

```sql
        created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        updated_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
    );
    CREATE TABLE IF NOT EXISTS track_states (
```

becomes:

```sql
        created_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        updated_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        linked_target_id    INTEGER REFERENCES targets(id) ON DELETE SET NULL
    );
    CREATE TABLE IF NOT EXISTS track_states (
```

- [ ] **Step 1: apply the three schema changes above** to `WatchtowerDesktop/Tests/Helpers/TestDatabase.swift`'s `schema` string, exactly as shown.

- [ ] **Step 2: update `insertMemoryNode`** — current signature (`TestDatabase.swift`):

```swift
    static func insertMemoryNode(
        _ db: Database,
        id: String,
        type: String = "entity",
        title: String = "",
        subject: String = "",
        confidence: Double = 0,
        status: String = "active",
        tier: String = "long",
        path: String = "",
        redirectTo: String? = nil,
        indexedAt: String = ""
    ) throws {
        try db.execute(sql: """
            INSERT INTO memory_nodes (id, type, tier, status, redirect_to, title, path, content_hash, indexed_at, subject, confidence)
            VALUES (?, ?, ?, ?, ?, ?, ?, '', ?, ?, ?)
            """, arguments: [id, type, tier, status, redirectTo, title, path, indexedAt, subject, confidence])
    }
```

becomes:

```swift
    static func insertMemoryNode(
        _ db: Database,
        id: String,
        type: String = "entity",
        title: String = "",
        subject: String = "",
        confidence: Double = 0,
        status: String = "active",
        tier: String = "long",
        path: String = "",
        redirectTo: String? = nil,
        indexedAt: String = "",
        importanceScore: Double = 0
    ) throws {
        try db.execute(sql: """
            INSERT INTO memory_nodes (id, type, tier, status, redirect_to, title, path, content_hash, indexed_at, subject, confidence, importance_score)
            VALUES (?, ?, ?, ?, ?, ?, ?, '', ?, ?, ?, ?)
            """, arguments: [id, type, tier, status, redirectTo, title, path, indexedAt, subject, confidence, importanceScore])
    }

    static func insertMemoryProvenance(
        _ db: Database,
        nodeID: String,
        channelID: String,
        tsRaw: String,
        tsUnix: Double,
        senderID: String,
        scheme: String = ""
    ) throws {
        try db.execute(sql: """
            INSERT INTO memory_provenance (node_id, scheme, channel_id, ts_raw, ts_unix, sender_id)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [nodeID, scheme, channelID, tsRaw, tsUnix, senderID])
    }
```

- [ ] **Step 3: update `insertTrack`** — current signature and body (`TestDatabase.swift`):

```swift
    static func insertTrack(
        _ db: Database,
        text: String = "Fix the bug",
        context: String = "Discussed in standup",
        category: String = "task",
        ownership: String = "mine",
        priority: String = "medium",
        tags: String = "[]",
        channelIDs: String = "[\"C001\"]",
        sourceRefs: String = "[]",
        hasUpdates: Bool = false,
        participants: String = "[]",
        requesterName: String = "",
        blocking: String = "",
        decisionSummary: String = "",
        decisionOptions: String = "[]",
        subItems: String = "[]",
        relatedDigestIDs: String = "[]",
        model: String = "haiku"
    ) throws {
        try db.execute(sql: """
            INSERT INTO tracks (text, context, category, ownership, priority, tags,
                channel_ids, source_refs, has_updates, participants, requester_name,
                blocking, decision_summary, decision_options, sub_items, related_digest_ids, model)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [text, context, category, ownership, priority, tags,
                             channelIDs, sourceRefs, hasUpdates ? 1 : 0, participants,
                             requesterName, blocking, decisionSummary, decisionOptions,
                             subItems, relatedDigestIDs, model])
    }
```

becomes:

```swift
    @discardableResult
    static func insertTrack(
        _ db: Database,
        text: String = "Fix the bug",
        context: String = "Discussed in standup",
        category: String = "task",
        ownership: String = "mine",
        priority: String = "medium",
        tags: String = "[]",
        channelIDs: String = "[\"C001\"]",
        sourceRefs: String = "[]",
        hasUpdates: Bool = false,
        participants: String = "[]",
        requesterName: String = "",
        blocking: String = "",
        decisionSummary: String = "",
        decisionOptions: String = "[]",
        subItems: String = "[]",
        relatedDigestIDs: String = "[]",
        model: String = "haiku",
        assigneeUserID: String = "",
        ownerUserID: String = "",
        requesterUserID: String = "",
        linkedTargetID: Int? = nil
    ) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO tracks (text, context, category, ownership, priority, tags,
                channel_ids, source_refs, has_updates, participants, requester_name,
                blocking, decision_summary, decision_options, sub_items, related_digest_ids, model,
                assignee_user_id, owner_user_id, requester_user_id, linked_target_id)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [text, context, category, ownership, priority, tags,
                             channelIDs, sourceRefs, hasUpdates ? 1 : 0, participants,
                             requesterName, blocking, decisionSummary, decisionOptions,
                             subItems, relatedDigestIDs, model,
                             assigneeUserID, ownerUserID, requesterUserID, linkedTargetID])
        return db.lastInsertedRowID
    }
```

(Adding `assigneeUserID`/`ownerUserID`/`requesterUserID` params here too — Task 5's target-subject test fixtures need tracks with these scalar user ids set, and they were previously not settable at all via this helper.)

- [ ] **Step 4: build and run the existing Swift test suite to confirm nothing broke** (this task only adds columns/params with defaults, so every existing call site keeps compiling and every existing test keeps passing unchanged):

```
$ cd WatchtowerDesktop && swift build 2>&1 | tee /tmp/build.log; echo "exit=$?"
exit=0

$ swift test 2>&1 | tee /tmp/test.log; echo "exit=$?"
exit=0
```

Expected: `exit=0` for both, no new failures relative to the pre-task baseline (grep `/tmp/test.log` for `failed` and confirm the count matches what `git stash` + a baseline run showed, or simply confirm zero `** TEST FAILED **` lines).

- [ ] **Step 5: commit:**

```
$ git add WatchtowerDesktop/Tests/Helpers/TestDatabase.swift
$ git commit -m "test(memory): TestDatabase gains importance_score, memory_provenance, tracks.linked_target_id (Slice C foundation)

Three schema-drift gaps between TestDatabase.swift's in-memory mirror and
the real schema.sql: memory_nodes.importance_score (Slice A), the whole
memory_provenance table (Slice B), and tracks.linked_target_id (pre-existing,
never mirrored). All three are needed by this plan's later tasks' fixtures.
insertMemoryNode gains importanceScore, insertTrack gains
assignee/owner/requester user ids + linkedTargetID and now returns its id
(matching insertTarget's shape). Every existing call site keeps compiling
unchanged (new params all default)."
```

---

## Task 2: Shared `RelevantMemory.swift` — ranking engine + recent-episodes

**Depends on:** Task 1. **Blocks:** Tasks 3, 4, 5, 6.

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/Memory/RelevantMemory.swift`
- Create: `WatchtowerDesktop/Tests/RelevantMemoryTests.swift`

**Interfaces:**
- Consumes: `memory_nodes.importance_score`/`memory_provenance.sender_id` (Task 1's test schema; the real app schema already has both, shipped by Slice A/B on the Go side and read here via GRDB against the same DB file).
- Produces:
  ```swift
  struct MemoryBelief { let title: String; let confidence: Double; let status: String }
  struct MemoryContextResult {
      let entityTitles: [String]
      let beliefs: [MemoryBelief]
      let recentEpisodeTitles: [String]
  }
  func relevantMemoryContext(subjects: [String], dbPool: DatabasePool) -> MemoryContextResult
  func hotMap(vaultDir: String?) -> String?
  func renderMemorySection(hotMap: String?, context: MemoryContextResult) -> String
  func cap4KB(_ text: String) -> String
  ```
  Consumed by Task 3 (Situation, refactored) and Tasks 4/5/6 (Track/Target/Meeting, new).

This file is a near-verbatim extraction of `SituationChatViewModel.swift`'s current `relevantMemory`/`memorySection`/`hotMap`/`cap4KB`/`MemoryBelief` (lines 358-482), generalized from `memberSignals: [InboxItem]` to `subjects: [String]` (the caller now computes the alias-key set itself), with the entity/belief ranking upgraded to `importance_score` and a new recent-episodes query added. `renderMemorySection` also changes shape slightly: it now takes an already-computed `MemoryContextResult` (produced by `relevantMemoryContext`) rather than calling it internally, and an already-resolved `hotMap: String?` rather than a `vaultDir` — the caller composes the two independent reads (`hotMap(vaultDir:)` and `relevantMemoryContext(subjects:dbPool:)`) and passes both results in, so a caller (e.g. Task 3) that wants to log or test them independently can.

- [ ] **Step 1: write the failing tests** — create `WatchtowerDesktop/Tests/RelevantMemoryTests.swift`:

```swift
import XCTest
import GRDB
@testable import WatchtowerDesktop

final class RelevantMemoryTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        do { (dbManager, dbPath) = try TestDatabase.createDatabaseManager() }
        catch { XCTFail("setUp failed: \(error)") }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    // MARK: - Entities ranked by importance

    func testEntitiesRankedByImportanceNotTitle() throws {
        try dbManager.dbPool.write { db in
            // "Zebra" would sort first alphabetically; importance must win.
            try TestDatabase.insertMemoryNode(db, id: "ent_a", type: "entity", title: "Zebra Corp", importanceScore: 1)
            try TestDatabase.insertMemoryAlias(db, alias: "U1", nodeID: "ent_a")
            try TestDatabase.insertMemoryNode(db, id: "ent_b", type: "entity", title: "Acme Inc", importanceScore: 9)
            try TestDatabase.insertMemoryAlias(db, alias: "U1", nodeID: "ent_b")
        }
        let result = relevantMemoryContext(subjects: ["U1"], dbPool: dbManager.dbPool)
        XCTAssertEqual(result.entityTitles, ["Acme Inc", "Zebra Corp"], "higher importance_score must rank first")
    }

    func testEntitiesTitleIsDeterministicTiebreakOnEqualImportance() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ent_z", type: "entity", title: "Zebra Corp", importanceScore: 5)
            try TestDatabase.insertMemoryAlias(db, alias: "U1", nodeID: "ent_z")
            try TestDatabase.insertMemoryNode(db, id: "ent_a", type: "entity", title: "Acme Inc", importanceScore: 5)
            try TestDatabase.insertMemoryAlias(db, alias: "U1", nodeID: "ent_a")
        }
        let result = relevantMemoryContext(subjects: ["U1"], dbPool: dbManager.dbPool)
        XCTAssertEqual(result.entityTitles, ["Acme Inc", "Zebra Corp"], "equal importance falls back to title order")
    }

    // MARK: - Beliefs ranked by importance, confidence as tiebreak

    func testBeliefsRankedByImportanceNotConfidence() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ent_cf", type: "entity", title: "Cloudflare")
            try TestDatabase.insertMemoryAlias(db, alias: "U1", nodeID: "ent_cf")
            try TestDatabase.insertMemoryNode(
                db, id: "bel_low_imp_high_conf", type: "belief", title: "renewals close on time",
                subject: "ent_cf", confidence: 0.95, status: "active", importanceScore: 1)
            try TestDatabase.insertMemoryNode(
                db, id: "bel_high_imp_low_conf", type: "belief", title: "support is responsive",
                subject: "ent_cf", confidence: 0.30, status: "active", importanceScore: 9)
        }
        let result = relevantMemoryContext(subjects: ["U1"], dbPool: dbManager.dbPool)
        XCTAssertEqual(result.beliefs.first?.title, "support is responsive", "higher importance_score must rank first despite lower confidence")
    }

    func testBeliefsConfidenceIsTiebreakOnEqualImportance() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ent_cf", type: "entity", title: "Cloudflare")
            try TestDatabase.insertMemoryAlias(db, alias: "U1", nodeID: "ent_cf")
            try TestDatabase.insertMemoryNode(
                db, id: "bel_a", type: "belief", title: "belief A", subject: "ent_cf",
                confidence: 0.40, status: "active", importanceScore: 5)
            try TestDatabase.insertMemoryNode(
                db, id: "bel_b", type: "belief", title: "belief B", subject: "ent_cf",
                confidence: 0.90, status: "active", importanceScore: 5)
        }
        let result = relevantMemoryContext(subjects: ["U1"], dbPool: dbManager.dbPool)
        XCTAssertEqual(result.beliefs.first?.title, "belief B", "equal importance falls back to confidence order")
    }

    // MARK: - Recent (short-tier) episodes

    func testRecentEpisodesOrderedByRecencyAndDedupedPerNode() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ep_recent", type: "episode", tier: "short", title: "Recent episode")
            try TestDatabase.insertMemoryProvenance(db, nodeID: "ep_recent", channelID: "C1", tsRaw: "200.0", tsUnix: 200.0, senderID: "U1")
            // Same node, an OLDER ref from the same sender — must dedup to one row, keyed on the newest ref.
            try TestDatabase.insertMemoryProvenance(db, nodeID: "ep_recent", channelID: "C1", tsRaw: "50.0", tsUnix: 50.0, senderID: "U1")

            try TestDatabase.insertMemoryNode(db, id: "ep_older", type: "episode", tier: "short", title: "Older episode")
            try TestDatabase.insertMemoryProvenance(db, nodeID: "ep_older", channelID: "C1", tsRaw: "100.0", tsUnix: 100.0, senderID: "U1")

            try TestDatabase.insertMemoryNode(db, id: "ep_long_tier", type: "episode", tier: "long", title: "Long-tier episode")
            try TestDatabase.insertMemoryProvenance(db, nodeID: "ep_long_tier", channelID: "C1", tsRaw: "300.0", tsUnix: 300.0, senderID: "U1")

            try TestDatabase.insertMemoryNode(db, id: "ep_tombstoned", type: "episode", tier: "short", status: "tombstone", title: "Tombstoned episode")
            try TestDatabase.insertMemoryProvenance(db, nodeID: "ep_tombstoned", channelID: "C1", tsRaw: "400.0", tsUnix: 400.0, senderID: "U1")

            try TestDatabase.insertMemoryNode(db, id: "ep_other_sender", type: "episode", tier: "short", title: "Other sender episode")
            try TestDatabase.insertMemoryProvenance(db, nodeID: "ep_other_sender", channelID: "C1", tsRaw: "500.0", tsUnix: 500.0, senderID: "U2")
        }
        let result = relevantMemoryContext(subjects: ["U1"], dbPool: dbManager.dbPool)
        XCTAssertEqual(result.recentEpisodeTitles, ["Recent episode", "Older episode"],
                       "short-tier, non-tombstone, matching-sender episodes only, newest first, deduped per node")
    }

    // MARK: - Empty / degenerate

    func testEmptySubjectsReturnsEmptyContext() throws {
        let result = relevantMemoryContext(subjects: [], dbPool: dbManager.dbPool)
        XCTAssertTrue(result.entityTitles.isEmpty)
        XCTAssertTrue(result.beliefs.isEmpty)
        XCTAssertTrue(result.recentEpisodeTitles.isEmpty)
    }

    func testNoMatchesReturnsEmptyContext() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ent_x", type: "entity", title: "Unrelated")
            try TestDatabase.insertMemoryAlias(db, alias: "U_other", nodeID: "ent_x")
        }
        let result = relevantMemoryContext(subjects: ["U1"], dbPool: dbManager.dbPool)
        XCTAssertTrue(result.entityTitles.isEmpty)
        XCTAssertTrue(result.beliefs.isEmpty)
        XCTAssertTrue(result.recentEpisodeTitles.isEmpty)
    }

    // MARK: - Rendering

    func testRenderMemorySectionIncludesRecentActivitySubsection() {
        let context = MemoryContextResult(
            entityTitles: ["Acme Inc"],
            beliefs: [MemoryBelief(title: "renewals close on time", confidence: 0.8, status: "active")],
            recentEpisodeTitles: ["Nova Card rollout update"])
        let section = renderMemorySection(hotMap: "- billing team owns renewals", context: context)
        XCTAssertTrue(section.contains("Recent activity"), "a new subsection must appear when recent episodes exist")
        XCTAssertTrue(section.contains("Nova Card rollout update"))
        XCTAssertTrue(section.contains("model-mediated"))
    }

    func testRenderMemorySectionOmitsRecentActivityWhenEmpty() {
        let context = MemoryContextResult(entityTitles: [], beliefs: [], recentEpisodeTitles: [])
        let section = renderMemorySection(hotMap: nil, context: context)
        XCTAssertFalse(section.contains("Recent activity"))
        XCTAssertTrue(section.contains("Relevant notes: (none match"))
    }

    func testCap4KBTruncatesOnLineBoundary() {
        let big = (0..<600).map { "line \($0)" }.joined(separator: "\n")
        let capped = cap4KB(big)
        XCTAssertLessThanOrEqual(capped.utf8.count, 4096)
        XCTAssertTrue(capped.contains("line 0"))
        XCTAssertFalse(capped.contains("line 599"))
    }
}
```

- [ ] **Step 2: run it — expect a build failure** (the symbols don't exist yet):

```
$ cd WatchtowerDesktop && swift build 2>&1 | tail -20
error: cannot find 'relevantMemoryContext' in scope
error: cannot find 'MemoryContextResult' in scope
...
```

- [ ] **Step 3: write the minimal implementation** — create `WatchtowerDesktop/Sources/Services/Memory/RelevantMemory.swift`:

```swift
import Foundation
import GRDB

// MARK: - Shared chat relevant-memory engine (Secretary Memory Slice C)
//
// Extracted from SituationChatViewModel's original relevantMemory/memorySection
// (Phase 4), generalized so Track/Target/Meeting chat can share the same
// ranking-and-render logic. Each chat type computes its own `subjects: [String]`
// (which Slack channel/user ids or emails this chat is "about") next to its own
// code, then calls into this file. Ranking now uses `memory_nodes.importance_score`
// (Slice A/B on the Go side, read here via the same shared SQLite mirror) instead
// of raw title/confidence order, and a new recent-activity section surfaces
// short-tier episodes by provenance recency (mirrors Go's
// ListShortTierEpisodesForAliases, Slice B).

struct MemoryBelief {
    let title: String
    let confidence: Double
    let status: String
}

struct MemoryContextResult {
    let entityTitles: [String]
    let beliefs: [MemoryBelief]
    let recentEpisodeTitles: [String]
}

/// Pure GRDB index reads: entity nodes whose aliases match `subjects` (≤5,
/// ranked by importance_score DESC then title ASC), active/shaken beliefs
/// whose subject is one of those entities (≤5, ranked by importance_score DESC
/// then confidence DESC), and short-tier non-tombstone episodes whose
/// provenance sender matches `subjects` (≤5, ranked by recency, deduped per
/// node by its most recent matching ref). Tolerant of the memory tables being
/// absent (a DB that hasn't run the memory migrations) — a failed read
/// degrades to an empty result rather than throwing.
func relevantMemoryContext(subjects: [String], dbPool: DatabasePool) -> MemoryContextResult {
    guard !subjects.isEmpty else {
        return MemoryContextResult(entityTitles: [], beliefs: [], recentEpisodeTitles: [])
    }

    do {
        return try dbPool.read { db in
            let placeholders = subjects.map { _ in "?" }.joined(separator: ",")

            let entityRows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT n.id AS id, n.title AS title
                FROM memory_nodes n
                JOIN memory_aliases a ON a.node_id = n.id
                WHERE n.type = 'entity' AND a.alias IN (\(placeholders))
                ORDER BY n.importance_score DESC, n.title ASC
                LIMIT 5
                """, arguments: StatementArguments(subjects))
            let entityIDs = entityRows.map { $0["id"] as String }
            let entityTitles = entityRows.map { $0["title"] as String }

            var beliefs: [MemoryBelief] = []
            if !entityIDs.isEmpty {
                let subjectPlaceholders = entityIDs.map { _ in "?" }.joined(separator: ",")
                let beliefRows = try Row.fetchAll(db, sql: """
                    SELECT title, confidence, status
                    FROM memory_nodes
                    WHERE type = 'belief' AND status IN ('active','shaken') AND subject IN (\(subjectPlaceholders))
                    ORDER BY importance_score DESC, confidence DESC
                    LIMIT 5
                    """, arguments: StatementArguments(entityIDs))
                beliefs = beliefRows.map {
                    MemoryBelief(title: $0["title"], confidence: $0["confidence"], status: $0["status"])
                }
            }

            let recentRows = try Row.fetchAll(db, sql: """
                SELECT n.title AS title
                FROM memory_nodes n
                JOIN (
                    SELECT node_id, MAX(ts_unix) AS max_ts
                    FROM memory_provenance
                    WHERE sender_id IN (\(placeholders))
                    GROUP BY node_id
                ) latest ON latest.node_id = n.id
                WHERE n.tier = 'short' AND n.status != 'tombstone'
                ORDER BY latest.max_ts DESC
                LIMIT 5
                """, arguments: StatementArguments(subjects))
            let recentEpisodeTitles = recentRows.map { $0["title"] as String }

            return MemoryContextResult(entityTitles: entityTitles, beliefs: beliefs, recentEpisodeTitles: recentEpisodeTitles)
        }
    } catch {
        print("RelevantMemory: memory read failed: \(error)")
        return MemoryContextResult(entityTitles: [], beliefs: [], recentEpisodeTitles: [])
    }
}

/// Reads `<vaultDir>/map.md` verbatim, trimmed. Nil when the vault dir is
/// unknown, the file is missing, or it is blank.
func hotMap(vaultDir: String?) -> String? {
    guard let vaultDir else { return nil }
    let path = "\(vaultDir)/map.md"
    guard let data = FileManager.default.contents(atPath: path),
          let text = String(data: data, encoding: .utf8) else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

/// The `=== MEMORY ===` block: the hot vault map plus the entities/beliefs/
/// recent activity this chat's subjects match. Framed as model-mediated notes
/// (not the owner's/attendee's own words) and capped at 4 KB. Always returns a
/// non-empty block — degrading to one-line notes when there is no map or
/// nothing relevant.
func renderMemorySection(hotMap: String?, context: MemoryContextResult) -> String {
    var lines: [String] = [
        "=== MEMORY (notes the secretary has built from Slack/Jira — model-mediated, not the owner's own words) ==="
    ]

    if let hotMap {
        lines.append("Hot map:")
        lines.append(hotMap)
    } else {
        lines.append("Hot map: (none yet — the secretary hasn't written a memory map for this workspace).")
    }

    if context.entityTitles.isEmpty && context.beliefs.isEmpty && context.recentEpisodeTitles.isEmpty {
        lines.append("Relevant notes: (none match the people or channels here yet).")
    } else {
        if !context.entityTitles.isEmpty {
            lines.append("People & topics the secretary already tracks:")
            for title in context.entityTitles { lines.append("- \(title)") }
        }
        if !context.beliefs.isEmpty {
            lines.append("What the secretary believes (model-mediated, may be wrong):")
            for belief in context.beliefs {
                var line = "- \(belief.title) (confidence \(String(format: "%.2f", belief.confidence)), \(belief.status))"
                if belief.status == "shaken" { line += " (uncertain — evidence conflicts)" }
                lines.append(line)
            }
        }
        if !context.recentEpisodeTitles.isEmpty {
            lines.append("Recent activity (model-mediated):")
            for title in context.recentEpisodeTitles { lines.append("- \(title)") }
        }
    }

    return cap4KB(lines.joined(separator: "\n"))
}

/// Truncate `text` to at most 4 KB (UTF-8), on a line boundary so a partial
/// line is never emitted.
func cap4KB(_ text: String) -> String {
    let limit = 4096
    guard text.utf8.count > limit else { return text }
    var result = ""
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let candidate = result.isEmpty ? String(line) : result + "\n" + line
        if candidate.utf8.count > limit { break }
        result = candidate
    }
    return result
}
```

- [ ] **Step 4: run it — expect green:**

```
$ cd WatchtowerDesktop && swift test --filter RelevantMemoryTests 2>&1 | tail -30
Test Suite 'RelevantMemoryTests' passed
     Executed 10 tests, with 0 failures
```

- [ ] **Step 5: full build/test sanity + commit:**

```
$ swift build 2>&1 | tee /tmp/build.log; echo "exit=$?"
exit=0
$ swift test 2>&1 | tee /tmp/test.log; echo "exit=$?"
exit=0
$ git add WatchtowerDesktop/Sources/Services/Memory/RelevantMemory.swift WatchtowerDesktop/Tests/RelevantMemoryTests.swift
$ git commit -m "feat(memory): shared RelevantMemory engine — importance ranking + recent activity (Slice C foundation)

Extracts SituationChatViewModel's relevantMemory/memorySection/hotMap/cap4KB
into a shared, subject-agnostic engine: entities/beliefs now rank by
importance_score (Slice A/B) with title/confidence as tiebreaks, and a new
recent-activity section surfaces short-tier episodes by provenance
recency, mirroring Go's ListShortTierEpisodesForAliases. Not yet wired into
any chat view model — that's the next tasks."
```

---

## Task 3: Wire Situation (Discuss) to the shared engine, upgrade ranking

**Depends on:** Task 2. **Blocks:** nothing further in this plan (independent of Tasks 4-6).

**Files:**
- Modify: `WatchtowerDesktop/Sources/ViewModels/SituationChatViewModel.swift`
- Modify: `WatchtowerDesktop/Tests/SituationChatMemoryPromptTests.swift`

**Interfaces:**
- Consumes: `relevantMemoryContext`, `hotMap`, `renderMemorySection` (Task 2).
- Produces: nothing new — this task only rewires an existing consumer.

Delete `SituationChatViewModel.swift`'s private `MemoryBelief` struct and `relevantMemory`/`memorySection`/`hotMap`/`cap4KB` methods (lines 358-482 of the current file) entirely. Replace the one call site inside `buildSystemPrompt` (currently `memorySection(memberSignals: memberSignals, vaultDir: memoryVaultDir, dbPool: dbPool)`, line 308) with:

```swift
        let memoryBlock = memoryChatEnabled
            ? renderMemorySection(
                hotMap: RelevantMemory.hotMap(vaultDir: memoryVaultDir),
                context: relevantMemoryContext(subjects: situationSubjects(memberSignals: memberSignals), dbPool: dbPool)
              ) + "\n\n"
            : ""
```

Wait — `hotMap`/`relevantMemoryContext`/`renderMemorySection` are free functions in this plan (Task 2 defines them as bare `func`s, not members of an enum/namespace), so call them unqualified: `hotMap(vaultDir: memoryVaultDir)`, not `RelevantMemory.hotMap(...)`. Add a new private static helper for Discuss's own subject computation (this is the one piece of subject-resolution logic Discuss keeps, per the design's "Situation — unchanged" clause):

```swift
    /// Discuss's subjects: the situation's member signals' channel and sender
    /// user ids — unchanged from the pre-Slice-C relevantMemory's alias-key
    /// computation.
    nonisolated private static func situationSubjects(memberSignals: [InboxItem]) -> [String] {
        var subjects = Set<String>()
        for signal in memberSignals {
            if !signal.channelID.isEmpty { subjects.insert(signal.channelID) }
            if !signal.senderUserID.isEmpty { subjects.insert(signal.senderUserID) }
        }
        return Array(subjects)
    }
```

- [ ] **Step 1: make the deletions and additions above** in `SituationChatViewModel.swift`.

- [ ] **Step 2: run the existing test file — expect specific failures** (the ranking assertions in the current tests don't exercise importance yet, so most pass, but confirm the file still compiles and the existing behavior tests are green before adding new ones):

```
$ cd WatchtowerDesktop && swift test --filter SituationChatMemoryPromptTests 2>&1 | tail -30
```

Expected: all existing tests still PASS (none of them assert an ordering that importance-ranking would break — `testEntitySelectionRespectsAliasJoinAndCap`'s six entities are all inserted with the default `importanceScore: 0`, so ties fall back to title order exactly as before; verify this is actually true by reading the test before assuming it).

- [ ] **Step 3: add new tests** to `SituationChatMemoryPromptTests.swift`, after `testEntitySelectionRespectsAliasJoinAndCap`:

```swift
    func testEntitiesRankedByImportanceScore() throws {
        let situation = try makeSituation()
        let signals = try signals(channelID: "C1", senderUserID: "U9")
        try dbManager.dbPool.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ent_low", type: "entity", title: "Zebra Corp", importanceScore: 1)
            try TestDatabase.insertMemoryAlias(db, alias: "C1", nodeID: "ent_low")
            try TestDatabase.insertMemoryNode(db, id: "ent_high", type: "entity", title: "Acme Inc", importanceScore: 9)
            try TestDatabase.insertMemoryAlias(db, alias: "C1", nodeID: "ent_high")
        }
        let prompt = build(situation, signals, enabled: true, vault: vaultDir)
        let acmeIdx = try XCTUnwrap(prompt.range(of: "Acme Inc")).lowerBound
        let zebraIdx = try XCTUnwrap(prompt.range(of: "Zebra Corp")).lowerBound
        XCTAssertLessThan(acmeIdx, zebraIdx, "higher-importance entity must render first despite alphabetical order")
    }

    func testRecentActivitySectionAppearsForMatchingShortTierEpisode() throws {
        let situation = try makeSituation()
        let signals = try signals(channelID: "C1", senderUserID: "U9")
        try dbManager.dbPool.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ep_recent", type: "episode", tier: "short", title: "Nova Card rollout update")
            try TestDatabase.insertMemoryProvenance(db, nodeID: "ep_recent", channelID: "C1", tsRaw: "100.0", tsUnix: 100.0, senderID: "U9")
        }
        let prompt = build(situation, signals, enabled: true, vault: vaultDir)
        XCTAssertTrue(prompt.contains("Recent activity"))
        XCTAssertTrue(prompt.contains("Nova Card rollout update"))
    }
```

- [ ] **Step 4: run — expect green:**

```
$ swift test --filter SituationChatMemoryPromptTests 2>&1 | tail -30
Test Suite 'SituationChatMemoryPromptTests' passed
     Executed 9 tests, with 0 failures
```

- [ ] **Step 5: full build/test sanity, confirm the disabled-path byte-identical guard still holds unchanged, then commit:**

```
$ swift build 2>&1 | tee /tmp/build.log; echo "exit=$?"
exit=0
$ swift test 2>&1 | tee /tmp/test.log; echo "exit=$?"
exit=0
$ grep -A2 "testDisabledPathByteIdenticalRegardlessOfMemoryData" /tmp/test.log
Test Case '-[WatchtowerDesktopTests.SituationChatMemoryPromptTests testDisabledPathByteIdenticalRegardlessOfMemoryData]' passed

$ git add WatchtowerDesktop/Sources/ViewModels/SituationChatViewModel.swift WatchtowerDesktop/Tests/SituationChatMemoryPromptTests.swift
$ git commit -m "refactor(memory): Discuss chat uses the shared RelevantMemory engine (Slice C)

SituationChatViewModel's private relevantMemory/memorySection/hotMap/cap4KB
are deleted; buildSystemPrompt now calls the shared engine (Task 2) with
Discuss's own subject computation (situationSubjects, the same member-signal
channel/user-id set as before, unchanged). Entities/beliefs now rank by
importance_score; a new Recent activity section can appear. The
disabled-path byte-identical guard test still passes unchanged."
```

---

## Task 4: Track chat memory block (new)

**Depends on:** Task 2. **Blocks:** Task 5 (which calls `TrackChatViewModel.trackMemorySubjects(track:)` to build a target's unioned subjects) — independent of Tasks 3, 6.

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Tracks/TrackChatView.swift`
- Create: `WatchtowerDesktop/Tests/TrackChatMemoryPromptTests.swift`

**Interfaces:**
- Consumes: `relevantMemoryContext`, `hotMap`, `renderMemorySection` (Task 2).
- Produces: `TrackChatViewModel.trackMemorySubjects(track: Track) -> [String]` — a pure function, not consumed elsewhere in this plan, but the same shape Task 5 mirrors for targets.

`Track`'s relevant fields (`WatchtowerDesktop/Sources/Models/Track.swift`): `assigneeUserID: String`, `ownerUserID: String`, `requesterUserID: String` (all plain, non-optional, `""` when unset), `decodedChannelIDs: [String]`, `decodedParticipants: [TrackParticipant]` where `TrackParticipant.userID: String?`.

Add to `TrackChatViewModel` (inside `TrackChatView.swift`), right before `buildSystemPrompt`:

```swift
    /// This track's subjects for the MEMORY block: its own channels, every
    /// participant's user id, and the three scalar assignee/owner/requester
    /// user ids — mirroring Go's TrackSubjectRefs (internal/db/memory.go),
    /// reimplemented directly against the same tables since this is a cheap,
    /// simple local read. Also includes the literal alias "track:<id>" so the
    /// track's own memory-mirror entity page (if one exists, Phase 5 slice 4)
    /// can itself surface as a connected entity — mirroring trackMirrorAlias's
    /// prepend on the Go write side (chat_ingest.go).
    nonisolated static func trackMemorySubjects(track: Track) -> [String] {
        var subjects = Set<String>()
        subjects.insert("track:\(track.id)")
        for channelID in track.decodedChannelIDs where !channelID.isEmpty {
            subjects.insert(channelID)
        }
        for participant in track.decodedParticipants {
            if let userID = participant.userID, !userID.isEmpty { subjects.insert(userID) }
        }
        for userID in [track.assigneeUserID, track.ownerUserID, track.requesterUserID] where !userID.isEmpty {
            subjects.insert(userID)
        }
        return Array(subjects)
    }
```

Update `buildSystemPrompt(track:dbPool:)` to splice in the memory block. Current tail of the function's returned string starts with `=== CAPABILITIES ===` right after the `=== CURRENT TRACK ===` block (see the file's actual current content around line 315-337) — insert the memory block between them:

```swift
    nonisolated static func buildSystemPrompt(
        track: Track, dbPool: DatabasePool,
        memoryChatEnabled: Bool = Constants.memorySurfacesChatEnabled(),
        memoryVaultDir: String? = Constants.memoryVaultDir()
    ) -> String {
        let schema = (try? dbPool.read { db in
            try ChatViewModel.fetchSchema(db)
        }) ?? ""
        let dbPath = dbPool.path

        let ws: Workspace? = try? dbPool.read { db in
            try WorkspaceQueries.fetchWorkspace(db)
        }
        let teamID = ws?.id ?? "unknown"
        let rawDomain = ws?.domain ?? ""
        let domain = rawDomain.isEmpty ? "unknown" : rawDomain

        let channelIDs = track.decodedChannelIDs
        let channelList = channelIDs.isEmpty ? "none" : channelIDs.joined(separator: ", ")
        let channelInClause = channelIDs.joined(separator: "','")

        // memoryChatEnabled/memoryVaultDir default to the config-derived values
        // in production; tests inject them explicitly — the same pattern
        // SituationChatViewModel's buildSystemPrompt already uses. On the
        // disabled path the block is an empty string, so the prompt is
        // byte-identical to pre-Slice-C output — no memory read runs.
        let memoryBlock = memoryChatEnabled
            ? renderMemorySection(
                hotMap: hotMap(vaultDir: memoryVaultDir),
                context: relevantMemoryContext(subjects: trackMemorySubjects(track: track), dbPool: dbPool)
              ) + "\n\n"
            : ""

        return """
        You are Watchtower, an AI assistant helping the user understand a specific track \
        from their Slack workspace.

        === CURRENT TRACK ===
        ID: \(track.id)
        Text: \(track.text)
        Context: \(track.context)
        Category: \(track.category)
        Ownership: \(track.ownership)
        Priority: \(track.priority)
        Requester: \(track.requesterName)
        Blocking: \(track.blocking)
        Channels: \(channelList)
        Created: \(track.createdAt)
        Updated: \(track.updatedAt)

        \(memoryBlock)=== CAPABILITIES ===
        You can query the database to find related messages, threads, and people involved.

        === DATABASE ===
        Database: \(dbPath)
        \(schema)

        === WORKSPACE ===
        Slack team ID: \(teamID)
        Slack web domain: \(domain).slack.com

        === QUERY TIPS ===
        - Always SELECT m.thread_ts alongside m.ts so you can build correct links for threaded messages.
        - Find messages in track channels:
          SELECT m.text, u.display_name, m.ts, m.thread_ts FROM messages m
          JOIN users u ON m.user_id = u.id
          WHERE m.channel_id IN ('\(channelInClause)')
          ORDER BY m.ts_unix DESC LIMIT 20

        === LINKING RULES ===
        ALWAYS use markdown links with descriptive text in the user's language. Never output bare URLs.

        Channel link:
          [#channel-name](slack://channel?team=\(teamID)&id={channel_id})

        Message link (top-level message, thread_ts is NULL or empty):
          [descriptive text](slack://channel?team=\(teamID)&id={channel_id}&message={ts})

        Message link inside a thread — use thread_ts (the parent's ts), NOT the reply's ts:
          [descriptive text](slack://channel?team=\(teamID)&id={channel_id}&message={thread_ts})

        Web permalink (only when the user explicitly asks for an https link):
          Top-level:     https://\(domain).slack.com/archives/{channel_id}/p{ts_without_dot}
          Thread reply:  https://\(domain).slack.com/archives/{channel_id}/p{ts_without_dot}?thread_ts={thread_ts}&cid={channel_id}
          Remove the dot from ts: 1740577800.000100 → p1740577800000100

        Rules:
        - Every referenced message MUST have a link
        - Link text describes WHAT is linked, not "link" or "click here"
        - Always SELECT channel_id, ts, AND thread_ts when fetching messages so you can build correct links
        - NEVER link to a channel when the user asked for a specific message — resolve the actual ts first

        === RESPONSE STYLE ===
        - Be concise and direct
        - Match the user's language
        - Use markdown for readability
        """
    }
```

(The body after `=== CURRENT TRACK ===` and everything from `=== CAPABILITIES ===` onward is unchanged from the file's current content — verify the exact current text with `sed -n '296,375p' WatchtowerDesktop/Sources/Views/Tracks/TrackChatView.swift` before editing, since only the one line `\(memoryBlock)=== CAPABILITIES ===` is new/changed.)

- [ ] **Step 1: write the failing test** — create `WatchtowerDesktop/Tests/TrackChatMemoryPromptTests.swift`:

```swift
import XCTest
import GRDB
@testable import WatchtowerDesktop

final class TrackChatMemoryPromptTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        do { (dbManager, dbPath) = try TestDatabase.createDatabaseManager() }
        catch { XCTFail("setUp failed: \(error)") }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    private func makeTrack(channelIDs: String = "[\"C1\"]", assigneeUserID: String = "", participants: String = "[]") throws -> Track {
        let id = try dbManager.dbPool.write { db in
            try TestDatabase.insertTrack(db, channelIDs: channelIDs, assigneeUserID: assigneeUserID, participants: participants)
        }
        return try XCTUnwrap(try dbManager.dbPool.read { db in try Track.fetchOne(db, sql: "SELECT * FROM tracks WHERE id = ?", arguments: [id]) })
    }

    func testTrackMemorySubjectsIncludesChannelsParticipantsScalarsAndMirrorAlias() throws {
        let participants = #"[{"name":"Bob","user_id":"U2","stance":"blocker"}]"#
        let track = try makeTrack(channelIDs: "[\"C1\",\"C2\"]", assigneeUserID: "U1", participants: participants)
        let subjects = Set(TrackChatViewModel.trackMemorySubjects(track: track))
        XCTAssertEqual(subjects, Set(["track:\(track.id)", "C1", "C2", "U1", "U2"]))
    }

    func testMemoryBlockAppearsWhenFlagOnAndSubjectMatches() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ent_cf", type: "entity", title: "Cloudflare (vendor)")
            try TestDatabase.insertMemoryAlias(db, alias: "C1", nodeID: "ent_cf")
        }
        let track = try makeTrack(channelIDs: "[\"C1\"]")
        let prompt = TrackChatViewModel.buildSystemPrompt(
            track: track, dbPool: dbManager.dbPool, memoryChatEnabled: true, memoryVaultDir: nil)
        XCTAssertTrue(prompt.contains("=== MEMORY ("))
        XCTAssertTrue(prompt.contains("Cloudflare (vendor)"))
        XCTAssertTrue(prompt.contains("model-mediated"))
    }

    func testMemoryBlockAbsentWhenFlagOff() throws {
        try dbManager.dbPool.write { db in
            try TestDatabase.insertMemoryNode(db, id: "ent_cf", type: "entity", title: "Cloudflare (vendor)")
            try TestDatabase.insertMemoryAlias(db, alias: "C1", nodeID: "ent_cf")
        }
        let track = try makeTrack(channelIDs: "[\"C1\"]")
        let prompt = TrackChatViewModel.buildSystemPrompt(
            track: track, dbPool: dbManager.dbPool, memoryChatEnabled: false, memoryVaultDir: nil)
        XCTAssertFalse(prompt.contains("=== MEMORY ("))
        XCTAssertFalse(prompt.contains("Cloudflare (vendor)"), "no memory read should leak into the prompt when disabled")
    }

    func testEmptyTrackHasOnlyMirrorAliasSubject() throws {
        let track = try makeTrack(channelIDs: "[]", participants: "[]")
        XCTAssertEqual(TrackChatViewModel.trackMemorySubjects(track: track), ["track:\(track.id)"])
    }
}
```

- [ ] **Step 2: run it — expect a build failure:**

```
$ cd WatchtowerDesktop && swift test --filter TrackChatMemoryPromptTests 2>&1 | tail -20
error: type 'TrackChatViewModel' has no member 'trackMemorySubjects'
```

- [ ] **Step 3: implement the additions above** in `TrackChatView.swift`.

- [ ] **Step 4: run — expect green:**

```
$ swift test --filter TrackChatMemoryPromptTests 2>&1 | tail -20
Test Suite 'TrackChatMemoryPromptTests' passed
     Executed 5 tests, with 0 failures
```

- [ ] **Step 5: full build/test sanity + commit:**

```
$ swift build 2>&1 | tee /tmp/build.log; echo "exit=$?"
exit=0
$ swift test 2>&1 | tee /tmp/test.log; echo "exit=$?"
exit=0
$ git add WatchtowerDesktop/Sources/Views/Tracks/TrackChatView.swift WatchtowerDesktop/Tests/TrackChatMemoryPromptTests.swift
$ git commit -m "feat(memory): track chat gains a MEMORY block (Slice C)

trackMemorySubjects mirrors Go's TrackSubjectRefs (channels + participant
user ids + assignee/owner/requester scalars) plus the track's own
track:<id> mirror alias. Gated by the existing memory.surfaces.chat flag,
same as Discuss — no new config surface."
```

---

## Task 5: Target chat memory block (new, unions linked tracks)

**Depends on:** Task 2, Task 4 (calls `TrackChatViewModel.trackMemorySubjects(track:)`, produced by Task 4 — this task cannot start until Task 4 is committed). **Blocks:** nothing further in this plan (independent of Tasks 3, 6).

**Files:**
- Modify: `WatchtowerDesktop/Sources/ViewModels/TargetChatViewModel.swift`
- Create: `WatchtowerDesktop/Tests/TargetChatMemoryPromptTests.swift`

**Interfaces:**
- Consumes: `relevantMemoryContext`, `hotMap`, `renderMemorySection` (Task 2); `TrackChatViewModel.trackMemorySubjects(track: Track) -> [String]` (Task 4).
- Produces: `TargetChatViewModel.targetMemorySubjects(target: Target, dbPool: DatabasePool) -> [String]` — not consumed elsewhere in this plan.

A `Target` has no channels/participants of its own (confirmed: `Target.swift` has no such fields) — subjects come entirely from every `tracks` row where `linked_target_id = target.id`, unioned, using the exact same per-track extraction Task 4's `trackMemorySubjects` does (channels + participants + scalars), plus the literal `"target:<id>"` mirror alias. A bare target with no linked track yields just its own mirror alias — the same accepted limitation the write-side `targetSubjects` (Go) already documents.

Add to `TargetChatViewModel.swift`, right before `buildSystemPrompt`:

```swift
    /// This target's subjects for the MEMORY block: every track linked via
    /// `tracks.linked_target_id = target.id` (unfiltered by origin/dismissed —
    /// unlike TrackQueries.fetchByLinkedTarget, which is scoped to custom
    /// watches for a different UI feature), each contributing the same
    /// channels/participants/scalars TrackChatViewModel.trackMemorySubjects
    /// extracts, unioned, plus the target's own "target:<id>" mirror alias
    /// (mirroring Go's targetSubjects prepend). A bare target with no linked
    /// track yields just its own mirror alias.
    nonisolated static func targetMemorySubjects(target: Target, dbPool: DatabasePool) -> [String] {
        var subjects = Set<String>()
        subjects.insert("target:\(target.id)")
        let linkedTracks = (try? dbPool.read { db in
            try Track.fetchAll(db, sql: "SELECT * FROM tracks WHERE linked_target_id = ?", arguments: [target.id])
        }) ?? []
        for track in linkedTracks {
            for subject in TrackChatViewModel.trackMemorySubjects(track: track) where subject != "track:\(track.id)" {
                subjects.insert(subject)
            }
        }
        return Array(subjects)
    }
```

(The `where subject != "track:\(track.id)"` filter drops each linked track's own mirror alias from the union — a target's memory context is about ITS mirror plus the tracks' real-world channels/people, not every linked track's own separate mirror entity, which would be noise for a target chat specifically.)

Update `buildSystemPrompt(target:dbPool:)` to splice in the memory block, right after `taskContextBlock`/`watchActivityBlock` and before `taskActionsContract` (matching the current structure at lines 537-544):

```swift
    nonisolated static func buildSystemPrompt(
        target: Target, dbPool: DatabasePool,
        memoryChatEnabled: Bool = Constants.memorySurfacesChatEnabled(),
        memoryVaultDir: String? = Constants.memoryVaultDir()
    ) -> String {
        let schema = (try? dbPool.read { db in
            try ChatViewModel.fetchSchema(db)
        }) ?? ""
        let dbPath = dbPool.path

        let ws: Workspace? = try? dbPool.read { db in
            try WorkspaceQueries.fetchWorkspace(db)
        }
        let teamID = ws?.id ?? "unknown"
        let rawDomain = ws?.domain ?? ""
        let domain = rawDomain.isEmpty ? "unknown" : rawDomain

        // memoryChatEnabled/memoryVaultDir default to the config-derived values
        // in production; tests inject them explicitly — same pattern as
        // SituationChatViewModel/TrackChatViewModel.
        let memoryBlock = memoryChatEnabled
            ? renderMemorySection(
                hotMap: hotMap(vaultDir: memoryVaultDir),
                context: relevantMemoryContext(subjects: targetMemorySubjects(target: target, dbPool: dbPool), dbPool: dbPool)
              ) + "\n\n"
            : ""

        return """
        You are Watchtower, an AI assistant helping the user make progress on a specific \
        task (target) tracked in their workspace.

        \(Self.taskContextBlock(target))
        \(Self.watchActivityBlock(target: target, dbPool: dbPool))

        \(memoryBlock)\(Self.taskActionsContract)

        === CAPABILITIES ===
        You can query the database to find related messages, threads, and people involved.

        === DATABASE ===
        Database: \(dbPath)
        \(schema)

        === WORKSPACE ===
        Slack team ID: \(teamID)
        Slack web domain: \(domain).slack.com

        === QUERY TIPS ===
        - Always SELECT m.thread_ts alongside m.ts so you can build correct links for threaded messages.
        - Find messages by text or people involved:
          SELECT m.text, u.display_name, m.ts, m.thread_ts, m.channel_id FROM messages m
          JOIN users u ON m.user_id = u.id
          WHERE m.text LIKE '%keyword%'
          ORDER BY m.ts_unix DESC LIMIT 20

        === LINKING RULES ===
        ALWAYS use markdown links with descriptive text in the user's language. Never output bare URLs.

        Channel link:
          [#channel-name](slack://channel?team=\(teamID)&id={channel_id})

        Message link (top-level message, thread_ts is NULL or empty):
          [descriptive text](slack://channel?team=\(teamID)&id={channel_id}&message={ts})

        Message link inside a thread — use thread_ts (the parent's ts), NOT the reply's ts:
          [descriptive text](slack://channel?team=\(teamID)&id={channel_id}&message={thread_ts})

        Web permalink (only when the user explicitly asks for an https link):
          Top-level:     https://\(domain).slack.com/archives/{channel_id}/p{ts_without_dot}
          Thread reply:  https://\(domain).slack.com/archives/{channel_id}/p{ts_without_dot}?thread_ts={thread_ts}&cid={channel_id}
          Remove the dot from ts: 1740577800.000100 → p1740577800000100

        Rules:
        - Every referenced message MUST have a link
        - Link text describes WHAT is linked, not "link" or "click here"
        - Always SELECT channel_id, ts, AND thread_ts when fetching messages so you can build correct links
        - NEVER link to a channel when the user asked for a specific message — resolve the actual ts first

        === RESPONSE STYLE ===
        - Be concise and direct
        - Match the user's language
        - Use markdown for readability
        """
    }
```

(Only the `memoryBlock` computation and its splice into the returned string are new — verify the exact current text of the rest with `sed -n '522,593p' WatchtowerDesktop/Sources/ViewModels/TargetChatViewModel.swift` before editing.)

- [ ] **Step 1: write the failing test** — create `WatchtowerDesktop/Tests/TargetChatMemoryPromptTests.swift`:

```swift
import XCTest
import GRDB
@testable import WatchtowerDesktop

final class TargetChatMemoryPromptTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        do { (dbManager, dbPath) = try TestDatabase.createDatabaseManager() }
        catch { XCTFail("setUp failed: \(error)") }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    private func fetchTarget(_ id: Int64) throws -> Target {
        try XCTUnwrap(try dbManager.dbPool.read { db in
            try Target.fetchOne(db, sql: "SELECT * FROM targets WHERE id = ?", arguments: [id])
        })
    }

    func testBareTargetWithNoLinkedTrackYieldsOnlyItsOwnMirrorAlias() throws {
        let targetID = try dbManager.dbPool.write { db in try TestDatabase.insertTarget(db) }
        let target = try fetchTarget(targetID)
        let subjects = TargetChatViewModel.targetMemorySubjects(target: target, dbPool: dbManager.dbPool)
        XCTAssertEqual(subjects, ["target:\(target.id)"])
    }

    func testTargetUnionsSubjectsAcrossTwoLinkedTracks() throws {
        let targetID = try dbManager.dbPool.write { db in try TestDatabase.insertTarget(db) }
        try dbManager.dbPool.write { db in
            try TestDatabase.insertTrack(db, channelIDs: "[\"C1\"]", assigneeUserID: "U1", linkedTargetID: Int(targetID))
            try TestDatabase.insertTrack(db, channelIDs: "[\"C2\"]", assigneeUserID: "U2", linkedTargetID: Int(targetID))
            // An unrelated track (no linked_target_id) must not leak in.
            try TestDatabase.insertTrack(db, channelIDs: "[\"C_other\"]", assigneeUserID: "U_other")
        }
        let target = try fetchTarget(targetID)
        let subjects = Set(TargetChatViewModel.targetMemorySubjects(target: target, dbPool: dbManager.dbPool))
        XCTAssertEqual(subjects, Set(["target:\(target.id)", "C1", "U1", "C2", "U2"]))
        XCTAssertFalse(subjects.contains("C_other"))
        XCTAssertFalse(subjects.contains("U_other"))
    }

    func testLinkedTrackMirrorAliasIsExcludedFromTargetSubjects() throws {
        let targetID = try dbManager.dbPool.write { db in try TestDatabase.insertTarget(db) }
        let trackID = try dbManager.dbPool.write { db in
            try TestDatabase.insertTrack(db, channelIDs: "[]", linkedTargetID: Int(targetID))
        }
        let target = try fetchTarget(targetID)
        let subjects = TargetChatViewModel.targetMemorySubjects(target: target, dbPool: dbManager.dbPool)
        XCTAssertFalse(subjects.contains("track:\(trackID)"), "a linked track's own mirror alias must not leak into the target's subjects")
    }

    func testMemoryBlockAppearsWhenFlagOnViaLinkedTrack() throws {
        let targetID = try dbManager.dbPool.write { db in try TestDatabase.insertTarget(db) }
        try dbManager.dbPool.write { db in
            try TestDatabase.insertTrack(db, channelIDs: "[\"C1\"]", linkedTargetID: Int(targetID))
            try TestDatabase.insertMemoryNode(db, id: "ent_cf", type: "entity", title: "Cloudflare (vendor)")
            try TestDatabase.insertMemoryAlias(db, alias: "C1", nodeID: "ent_cf")
        }
        let target = try fetchTarget(targetID)
        let prompt = TargetChatViewModel.buildSystemPrompt(
            target: target, dbPool: dbManager.dbPool, memoryChatEnabled: true, memoryVaultDir: nil)
        XCTAssertTrue(prompt.contains("=== MEMORY ("))
        XCTAssertTrue(prompt.contains("Cloudflare (vendor)"))
    }

    func testMemoryBlockAbsentWhenFlagOff() throws {
        let targetID = try dbManager.dbPool.write { db in try TestDatabase.insertTarget(db) }
        let target = try fetchTarget(targetID)
        let prompt = TargetChatViewModel.buildSystemPrompt(
            target: target, dbPool: dbManager.dbPool, memoryChatEnabled: false, memoryVaultDir: nil)
        XCTAssertFalse(prompt.contains("=== MEMORY ("))
    }
}
```

- [ ] **Step 2: run it — expect a build failure:**

```
$ cd WatchtowerDesktop && swift test --filter TargetChatMemoryPromptTests 2>&1 | tail -20
error: type 'TargetChatViewModel' has no member 'targetMemorySubjects'
```

- [ ] **Step 3: implement the additions above** in `TargetChatViewModel.swift`.

- [ ] **Step 4: run — expect green:**

```
$ swift test --filter TargetChatMemoryPromptTests 2>&1 | tail -20
Test Suite 'TargetChatMemoryPromptTests' passed
     Executed 5 tests, with 0 failures
```

- [ ] **Step 5: full build/test sanity + commit:**

```
$ swift build 2>&1 | tee /tmp/build.log; echo "exit=$?"
exit=0
$ swift test 2>&1 | tee /tmp/test.log; echo "exit=$?"
exit=0
$ git add WatchtowerDesktop/Sources/ViewModels/TargetChatViewModel.swift WatchtowerDesktop/Tests/TargetChatMemoryPromptTests.swift
$ git commit -m "feat(memory): target chat gains a MEMORY block, unioned across linked tracks (Slice C)

targetMemorySubjects unions every tracks row with linked_target_id = target.id
(unfiltered by origin/dismissed, unlike TrackQueries.fetchByLinkedTarget's
custom-watches scoping) via the same per-track extraction Task 4's
trackMemorySubjects performs, plus the target's own target:<id> mirror
alias — each linked track's own mirror alias is excluded from the union. A
bare target with no linked track yields just its own mirror alias, the same
accepted limitation Go's write-side targetSubjects documents."
```

---

## Task 6: Meeting chat memory block (new, calendar attendees)

**Depends on:** Task 2. **Blocks:** Task 7.

**Files:**
- Modify: `WatchtowerDesktop/Sources/ViewModels/MeetingChatViewModel.swift`
- Create: `WatchtowerDesktop/Tests/MeetingChatMemoryPromptTests.swift`

**Interfaces:**
- Consumes: `relevantMemoryContext`, `hotMap`, `renderMemorySection` (Task 2).
- Produces: `MeetingChatViewModel.meetingMemorySubjects(transcript: MeetingTranscript, dbPool: DatabasePool) -> [String]` — not consumed elsewhere in this plan. `buildSystemPrompt`'s signature changes (adds `dbPool: DatabasePool`) — its one call site (line 138, same file) must be updated too.

`MeetingTranscript.eventID: String?` — nil for an ad-hoc recording. When set, look up `calendar_events` by that id (the same `CalendarEvent.fetchOne(db, sql: "SELECT * FROM calendar_events WHERE id = ?", ...)` shape `FeedItemQueries.fetchEvent` already uses), decode `.parsedAttendees: [EventAttendee]`, and collect each attendee's `slackUserID` (non-empty) and `email` as subjects.

Add to `MeetingChatViewModel.swift`, right before `buildSystemPrompt`:

```swift
    /// This meeting's subjects for the MEMORY block: the linked calendar
    /// event's attendees (Slack user id where already resolved via
    /// calendar_attendee_map, plus email always). An ad-hoc recording with no
    /// linked event (eventID == nil) or a since-deleted event yields an empty,
    /// clean subject list — not an error.
    nonisolated static func meetingMemorySubjects(transcript: MeetingTranscript, dbPool: DatabasePool) -> [String] {
        guard let eventID = transcript.eventID else { return [] }
        let event = try? dbPool.read { db in
            try CalendarEvent.fetchOne(db, sql: "SELECT * FROM calendar_events WHERE id = ?", arguments: [eventID])
        }
        guard let event = event ?? nil else { return [] }
        var subjects = Set<String>()
        for attendee in event.parsedAttendees {
            if !attendee.slackUserID.isEmpty { subjects.insert(attendee.slackUserID) }
            if !attendee.email.isEmpty { subjects.insert(attendee.email) }
        }
        return Array(subjects)
    }
```

Update `buildSystemPrompt` to take `dbPool` and splice in the memory block — current signature and body (`MeetingChatViewModel.swift`, lines 273-299):

```swift
    nonisolated static func buildSystemPrompt(
        transcript: MeetingTranscript, recapContent: MeetingRecap.Content?
    ) -> String {
        let excerpt = String(transcript.transcriptText.prefix(transcriptExcerptLimit))
        let truncated = transcript.transcriptText.count > transcriptExcerptLimit

        return """
        You are the user's AI secretary, discussing ONE recorded meeting. \
        Help them recall what was said, clarify decisions, and draft follow-ups when asked.

        \(meetingContextBlock(transcript, recapContent: recapContent))

        === TRANSCRIPT EXCERPT (single-track, speakers not labeled, may mix ru/uk/en) ===
        \(excerpt)
        \(truncated ? "(…truncated — use get_transcript with the transcript id above for the full text)" : "(full transcript shown)")

        === TOOLS (local Watchtower data — already connected; use them, never ask the user) ===
        - get_transcript / list_transcripts — the full transcript text of this and other recordings.
        - list_messages, get_person / list_people, get_target / list_tracks — surrounding work context.
        Never ask for a database path; the data is already local and the tools are already connected.

        === RESPONSE STYLE ===
        - Match the user's language in conversation.
        - Be concise; this is a working discussion, not a report.
        - Quote the transcript verbatim when the user asks "what exactly was said".
        """
    }
```

becomes:

```swift
    nonisolated static func buildSystemPrompt(
        transcript: MeetingTranscript, recapContent: MeetingRecap.Content?, dbPool: DatabasePool,
        memoryChatEnabled: Bool = Constants.memorySurfacesChatEnabled(),
        memoryVaultDir: String? = Constants.memoryVaultDir()
    ) -> String {
        let excerpt = String(transcript.transcriptText.prefix(transcriptExcerptLimit))
        let truncated = transcript.transcriptText.count > transcriptExcerptLimit

        // memoryChatEnabled/memoryVaultDir default to the config-derived values
        // in production; tests inject them explicitly — same pattern as
        // SituationChatViewModel/TrackChatViewModel/TargetChatViewModel.
        let memoryBlock = memoryChatEnabled
            ? renderMemorySection(
                hotMap: hotMap(vaultDir: memoryVaultDir),
                context: relevantMemoryContext(subjects: meetingMemorySubjects(transcript: transcript, dbPool: dbPool), dbPool: dbPool)
              ) + "\n\n"
            : ""

        return """
        You are the user's AI secretary, discussing ONE recorded meeting. \
        Help them recall what was said, clarify decisions, and draft follow-ups when asked.

        \(meetingContextBlock(transcript, recapContent: recapContent))

        \(memoryBlock)=== TRANSCRIPT EXCERPT (single-track, speakers not labeled, may mix ru/uk/en) ===
        \(excerpt)
        \(truncated ? "(…truncated — use get_transcript with the transcript id above for the full text)" : "(full transcript shown)")

        === TOOLS (local Watchtower data — already connected; use them, never ask the user) ===
        - get_transcript / list_transcripts — the full transcript text of this and other recordings.
        - list_messages, get_person / list_people, get_target / list_tracks — surrounding work context.
        Never ask for a database path; the data is already local and the tools are already connected.

        === RESPONSE STYLE ===
        - Match the user's language in conversation.
        - Be concise; this is a working discussion, not a report.
        - Quote the transcript verbatim when the user asks "what exactly was said".
        """
    }
```

Update the one call site (`MeetingChatViewModel.swift` line 138, inside the streaming-prompt-build path):

```swift
            ? Self.buildSystemPrompt(transcript: transcript, recapContent: recapContent)
```

becomes:

```swift
            ? Self.buildSystemPrompt(transcript: transcript, recapContent: recapContent, dbPool: dbPool)
```

(`dbPool` is already a local `let` in that same method, per line 136 — `let dbPool = dbManager.dbPool` — so this is a same-scope reference, no new plumbing needed.)

- [ ] **Step 1: write the failing test** — create `WatchtowerDesktop/Tests/MeetingChatMemoryPromptTests.swift`:

```swift
import XCTest
import GRDB
@testable import WatchtowerDesktop

final class MeetingChatMemoryPromptTests: XCTestCase {
    private var dbManager: DatabaseManager!
    private var dbPath: String!

    override func setUp() {
        super.setUp()
        do { (dbManager, dbPath) = try TestDatabase.createDatabaseManager() }
        catch { XCTFail("setUp failed: \(error)") }
    }

    override func tearDown() {
        TestDatabase.cleanup(path: dbPath)
        super.tearDown()
    }

    private func makeTranscript(eventID: String?) throws -> MeetingTranscript {
        // SQLite's IS is NULL-safe equality (unlike =, which never matches a
        // bound NULL), so this one query correctly fetches both the ad-hoc
        // (eventID == nil) and event-linked cases.
        try dbManager.dbPool.write { db in
            try TestDatabase.insertMeetingTranscript(db, eventID: eventID, transcriptText: "hello world")
        }
        return try XCTUnwrap(try dbManager.dbPool.read { db in
            try MeetingTranscript.fetchOne(db, sql: "SELECT * FROM meeting_transcripts WHERE event_id IS ? ORDER BY id DESC LIMIT 1", arguments: [eventID])
        })
    }

    func testAdHocRecordingWithNoEventYieldsEmptySubjects() throws {
        let transcript = try makeTranscript(eventID: nil)
        let subjects = MeetingChatViewModel.meetingMemorySubjects(transcript: transcript, dbPool: dbManager.dbPool)
        XCTAssertTrue(subjects.isEmpty)
    }

    func testEventLinkedRecordingCollectsAttendeeSlackIDsAndEmails() throws {
        let attendeesJSON = """
        [{"email":"alice@example.com","display_name":"Alice","response_status":"accepted","slack_user_id":"U1"},
         {"email":"bob@example.com","display_name":"Bob","response_status":"accepted","slack_user_id":""}]
        """
        try dbManager.dbPool.write { db in
            try TestDatabase.insertCalendarEvent(db, id: "evt_1", attendees: attendeesJSON)
        }
        let transcript = try makeTranscript(eventID: "evt_1")
        let subjects = Set(MeetingChatViewModel.meetingMemorySubjects(transcript: transcript, dbPool: dbManager.dbPool))
        XCTAssertEqual(subjects, Set(["U1", "alice@example.com", "bob@example.com"]),
                       "an attendee with no resolved Slack id still contributes its email")
    }

    func testDeletedEventYieldsEmptySubjectsNotAnError() throws {
        let transcript = try makeTranscript(eventID: "evt_missing")
        let subjects = MeetingChatViewModel.meetingMemorySubjects(transcript: transcript, dbPool: dbManager.dbPool)
        XCTAssertTrue(subjects.isEmpty)
    }

    func testMemoryBlockAppearsWhenFlagOnAndAttendeeMatches() throws {
        let attendeesJSON = #"[{"email":"alice@example.com","display_name":"Alice","response_status":"accepted","slack_user_id":"U1"}]"#
        try dbManager.dbPool.write { db in
            try TestDatabase.insertCalendarEvent(db, id: "evt_1", attendees: attendeesJSON)
            try TestDatabase.insertMemoryNode(db, id: "ent_alice", type: "entity", title: "Alice (backend)")
            try TestDatabase.insertMemoryAlias(db, alias: "U1", nodeID: "ent_alice")
        }
        let transcript = try makeTranscript(eventID: "evt_1")
        let prompt = MeetingChatViewModel.buildSystemPrompt(
            transcript: transcript, recapContent: nil, dbPool: dbManager.dbPool,
            memoryChatEnabled: true, memoryVaultDir: nil)
        XCTAssertTrue(prompt.contains("=== MEMORY ("))
        XCTAssertTrue(prompt.contains("Alice (backend)"))
    }

    func testMemoryBlockAbsentWhenFlagOff() throws {
        let transcript = try makeTranscript(eventID: nil)
        let prompt = MeetingChatViewModel.buildSystemPrompt(
            transcript: transcript, recapContent: nil, dbPool: dbManager.dbPool,
            memoryChatEnabled: false, memoryVaultDir: nil)
        XCTAssertFalse(prompt.contains("=== MEMORY ("))
    }
}
```

- [ ] **Step 2: run it — expect a build failure:**

```
$ cd WatchtowerDesktop && swift test --filter MeetingChatMemoryPromptTests 2>&1 | tail -20
error: type 'MeetingChatViewModel' has no member 'meetingMemorySubjects'
```

- [ ] **Step 3: implement the additions above** in `MeetingChatViewModel.swift`, and update its one internal call site.

- [ ] **Step 4: run — expect green:**

```
$ swift test --filter MeetingChatMemoryPromptTests 2>&1 | tail -20
Test Suite 'MeetingChatMemoryPromptTests' passed
     Executed 5 tests, with 0 failures
```

- [ ] **Step 5: full build/test sanity + commit:**

```
$ swift build 2>&1 | tee /tmp/build.log; echo "exit=$?"
exit=0
$ swift test 2>&1 | tee /tmp/test.log; echo "exit=$?"
exit=0
$ git add WatchtowerDesktop/Sources/ViewModels/MeetingChatViewModel.swift WatchtowerDesktop/Tests/MeetingChatMemoryPromptTests.swift
$ git commit -m "feat(memory): meeting chat gains a MEMORY block from calendar attendees (Slice C)

meetingMemorySubjects resolves the transcript's linked calendar_events row
(when present) and collects each attendee's resolved Slack user id plus
email. An ad-hoc recording (no linked event) or a since-deleted event
yields a clean empty subject list, not an error. buildSystemPrompt gains a
dbPool parameter; its one call site updated."
```

---

## Task 7: Final verification

**Depends on:** Tasks 1-6. **Blocks:** nothing further in this plan.

**Files:** none (verification only).

- [ ] **Step 1: full build.**

```
$ cd WatchtowerDesktop && swift build 2>&1 | tee /tmp/build.log; echo "exit=$?"
```

Expected: `exit=0`, no warnings about the new files.

- [ ] **Step 2: full test suite, verbose, checking the real exit code (never piped through `tail` alone):**

```
$ swift test 2>&1 | tee /tmp/test.log; echo "exit=$?"
```

Expected: `exit=0`.

- [ ] **Step 3: confirm every new/changed test file passed, by name:**

```
$ grep -E "Test Suite '(RelevantMemoryTests|SituationChatMemoryPromptTests|TrackChatMemoryPromptTests|TargetChatMemoryPromptTests|MeetingChatMemoryPromptTests)' (passed|failed)" /tmp/test.log
Test Suite 'RelevantMemoryTests' passed
Test Suite 'SituationChatMemoryPromptTests' passed
Test Suite 'TrackChatMemoryPromptTests' passed
Test Suite 'TargetChatMemoryPromptTests' passed
Test Suite 'MeetingChatMemoryPromptTests' passed

$ grep -c "failed" /tmp/test.log
0
```

- [ ] **Step 4: confirm no stray references to the deleted `SituationChatViewModel` private symbols remain anywhere** (a leftover call would be a build error already caught in Step 1, but grep confirms the deletion was clean, not just shadowed):

```
$ grep -rn "private static func relevantMemory\|private static func memorySection\|private struct MemoryBelief" WatchtowerDesktop/Sources/ViewModels/SituationChatViewModel.swift
(no output expected)
```

- [ ] **Step 5: manual smoke check note** (per this repo's UI-change convention — cannot be automated in this environment, flag explicitly rather than silently skip): before merging, run the Desktop app with `memory.surfaces.chat: true` in a real or sandboxed config.yaml, open a Track chat, a Target chat, and a Meeting chat each linked to a workspace with real memory data, and visually confirm the MEMORY block renders sensibly (no truncation artifacts, no raw JSON leaking, model-mediated framing reads naturally) — this plan's automated tests cover correctness of the underlying data/ranking, not visual/prompt-quality review.

No commit for this task unless Step 1 needed fixes (in which case commit those fixes with a `fix(memory): ...` message and re-run Steps 1-4).
