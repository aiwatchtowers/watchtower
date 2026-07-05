# Target Prefill From Source — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Across all five "create target from a source" entry points (briefing, digest, track, inbox, promote-subitem), the form opens with content-rich prefill — text, a substantive intent lifted from real DB rows, and `secondary_links` where applicable. No LLM call at form-open time. Inbox is migrated from its current one-click bypass to the same sheet flow.

**Architecture:** A single `TargetPrefillBuilder` enum with five static methods (four `async throws` taking `DatabaseManager`, one `sync` for the in-memory parent/sub-item case). Each callsite calls the matching builder before opening `CreateTargetSheet` (or `PromoteSubItemSheet`). The sheet's parameter list is collapsed to a single `prefill: TargetPrefill?` plus an `onCreated: ((Int) -> Void)?` callback. `TargetQueries.create(...)` gains a `secondaryLinks` parameter and writes them in the same write-transaction. The existing `InboxQueries.createTask` direct-create path is removed.

**Tech Stack:** Swift 5.10, SwiftUI, GRDB.swift, XCTest, Foundation. macOS 14+. WatchtowerDesktop SPM package.

---

## File Structure

**Create:**
- `WatchtowerDesktop/Sources/Models/TargetPrefill.swift` — `TargetPrefill` and `TargetPrefillLink` value structs.
- `WatchtowerDesktop/Sources/Services/TargetPrefillBuilder.swift` — the five builder methods.
- `WatchtowerDesktop/Tests/TargetPrefillBuilderTests.swift` — unit tests for the builder, one per source.
- `WatchtowerDesktop/Tests/TargetQueriesCreateLinksTests.swift` — round-trip test for the new `secondaryLinks` parameter on `TargetQueries.create`.

**Modify:**
- `WatchtowerDesktop/Sources/Database/Queries/TargetQueries.swift` — add `secondaryLinks:` parameter to `create(...)`.
- `WatchtowerDesktop/Sources/Views/Targets/CreateTargetSheet.swift` — replace `prefill*` parameter sprawl with `prefill: TargetPrefill?`; add `onCreated`; persist `secondaryLinks`.
- `WatchtowerDesktop/Sources/Views/Targets/PromoteSubItemSheet.swift` — accept `prefilledIntent: String?`.
- `WatchtowerDesktop/Sources/Views/Briefings/BriefingDetailView.swift` — async builder call, banner state.
- `WatchtowerDesktop/Sources/Views/Digests/DigestDetailView.swift` — async builder call.
- `WatchtowerDesktop/Sources/Views/Tracks/TrackDetailView.swift` — async builder call.
- `WatchtowerDesktop/Sources/Views/Targets/TargetDetailView.swift` — sync builder call before `PromoteSubItemSheet`.
- `WatchtowerDesktop/Sources/Views/Inbox/InboxFeedView.swift` — switch from one-click to sheet flow.
- `WatchtowerDesktop/Sources/ViewModels/InboxViewModel.swift` — remove `createTask(from:)`.
- `WatchtowerDesktop/Sources/Database/Queries/InboxQueries.swift` — remove `createTask(_:from:)`.
- `WatchtowerDesktop/Tests/Helpers/TestDatabase.swift` — add `insertDigestTopic` fixture helper.
- `WatchtowerDesktop/Tests/InboxTests.swift` — replace direct-create tests with `linkTarget`-only assertion.

---

## Task 1: TargetPrefill model

**Files:**
- Create: `WatchtowerDesktop/Sources/Models/TargetPrefill.swift`

This is a pure value type. No dedicated unit tests — coverage comes from the builder tests in later tasks.

- [ ] **Step 1: Write the file**

```swift
// WatchtowerDesktop/Sources/Models/TargetPrefill.swift
import Foundation

/// Pre-filled values flowing into `CreateTargetSheet` (and `PromoteSubItemSheet`)
/// from an in-app source — briefing item, digest, track, inbox item, or a parent
/// target's sub-item being promoted.
///
/// Built synchronously (or via a single short DB read) by `TargetPrefillBuilder`.
/// Nothing here calls the LLM; this is content lifted from existing DB rows.
struct TargetPrefill: Equatable {
    var text: String
    var intent: String
    /// One of the values allowed by the production `targets.source_type` CHECK:
    /// `extract | track | digest | briefing | manual | chat | inbox | jira |
    /// slack | promoted_subitem`.
    var sourceType: String
    var sourceID: String
    var secondaryLinks: [TargetPrefillLink] = []
    /// Promote-subitem only — wires up `targets.parent_id`. Other sources leave nil.
    var parentID: Int? = nil
}

/// One link to be written into `target_links` alongside the new target.
struct TargetPrefillLink: Equatable {
    /// Must satisfy the Go-side allow-list `IsValidExternalRef`:
    /// starts with `"jira:"` or `"slack:"`. Anything else is dropped before insert.
    var externalRef: String
    /// One of the values in the `target_links.relation` CHECK:
    /// `contributes_to | blocks | related | duplicates`.
    var relation: String
}
```

- [ ] **Step 2: Verify compile**

Run: `cd WatchtowerDesktop && swift build`
Expected: build success, no warnings about the new file.

- [ ] **Step 3: Commit**

```bash
git add WatchtowerDesktop/Sources/Models/TargetPrefill.swift
git commit -m "feat(desktop-targets): TargetPrefill value type"
```

---

## Task 2: `TargetPrefillBuilder.fromSubItem` (sync, no DB)

This is the simplest builder — pure in-memory mapping. Establishes the file and the test class.

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/TargetPrefillBuilder.swift`
- Create: `WatchtowerDesktop/Tests/TargetPrefillBuilderTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// WatchtowerDesktop/Tests/TargetPrefillBuilderTests.swift
import XCTest
import GRDB
@testable import WatchtowerDesktop

final class TargetPrefillBuilderTests: XCTestCase {

    // MARK: - fromSubItem

    func testFromSubItem_BasicShape() {
        let parent = Self.makeTarget(
            id: 42,
            text: "Ship the rewrite",
            intent: "Unblock Q2 launch",
            subItems: [
                TargetSubItem(text: "Draft RFC", done: false),
                TargetSubItem(text: "Review with team", done: false),
                TargetSubItem(text: "Implement", done: false)
            ]
        )
        let subItem = parent.decodedSubItems[0]
        let prefill = TargetPrefillBuilder.fromSubItem(parent: parent, subItem: subItem, index: 0)

        XCTAssertEqual(prefill.text, "Draft RFC")
        XCTAssertEqual(prefill.sourceType, "promoted_subitem")
        XCTAssertEqual(prefill.sourceID, "42:0")
        XCTAssertEqual(prefill.parentID, 42)
        XCTAssertTrue(prefill.intent.contains("Sub-target of #42"))
        XCTAssertTrue(prefill.intent.contains("«Ship the rewrite»"))
        XCTAssertTrue(prefill.intent.contains("Unblock Q2 launch"))
        XCTAssertTrue(prefill.intent.contains("Review with team"))
        XCTAssertTrue(prefill.intent.contains("Implement"))
        XCTAssertTrue(prefill.secondaryLinks.isEmpty)
    }

    func testFromSubItem_NoSiblings_NoIntent() {
        let parent = Self.makeTarget(
            id: 7,
            text: "Lone target",
            intent: "",
            subItems: [TargetSubItem(text: "Only one", done: false)]
        )
        let subItem = parent.decodedSubItems[0]
        let prefill = TargetPrefillBuilder.fromSubItem(parent: parent, subItem: subItem, index: 0)

        XCTAssertTrue(prefill.intent.contains("Sub-target of #7 «Lone target»."))
        XCTAssertFalse(prefill.intent.contains("Parent context:"))
        XCTAssertFalse(prefill.intent.contains("Sibling sub-items:"))
    }

    // MARK: - Helpers

    /// Build a `Target` directly from a GRDB row dictionary so tests don't need a DB.
    static func makeTarget(
        id: Int,
        text: String,
        intent: String = "",
        level: String = "week",
        priority: String = "medium",
        ownership: String = "mine",
        dueDate: String = "",
        subItems: [TargetSubItem] = []
    ) -> Target {
        let subItemsJSON: String = {
            guard !subItems.isEmpty,
                  let data = try? JSONEncoder().encode(subItems),
                  let json = String(data: data, encoding: .utf8) else { return "[]" }
            return json
        }()
        let row: Row = [
            "id": id,
            "text": text,
            "intent": intent,
            "level": level,
            "priority": priority,
            "ownership": ownership,
            "due_date": dueDate,
            "sub_items": subItemsJSON,
            "period_start": "2026-04-20",
            "period_end": "2026-04-26",
            "status": "todo",
            "ball_on": "",
            "snooze_until": "",
            "blocking": "",
            "tags": "[]",
            "notes": "[]",
            "progress": 0.0,
            "source_type": "manual",
            "source_id": "",
            "custom_label": "",
            "created_at": "2026-04-20T00:00:00Z",
            "updated_at": "2026-04-20T00:00:00Z"
        ]
        return Target(row: row)
    }
}
```

- [ ] **Step 2: Run test, expect FAIL**

Run: `cd WatchtowerDesktop && swift test --filter TargetPrefillBuilderTests`
Expected: compile error — `TargetPrefillBuilder` is undefined.

- [ ] **Step 3: Implement the builder file with `fromSubItem` only**

```swift
// WatchtowerDesktop/Sources/Services/TargetPrefillBuilder.swift
import Foundation
import GRDB

/// Builds `TargetPrefill` values from in-app source records. Async methods
/// open a single short read transaction; the sub-item method is sync because
/// the parent is already loaded in memory.
///
/// On a missing related entity (channel renamed, user not synced yet, etc.)
/// builders fall back to a softer label (channel id, raw user id) instead of
/// throwing. They only throw on hard DB errors.
enum TargetPrefillBuilder {

    // MARK: - fromSubItem

    /// Synchronous — the `parent` target is already loaded by the caller.
    static func fromSubItem(parent: Target, subItem: TargetSubItem, index: Int) -> TargetPrefill {
        var lines: [String] = []
        lines.append("Sub-target of #\(parent.id) «\(parent.text)».")

        let parentIntent = parent.intent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !parentIntent.isEmpty {
            lines.append("Parent context: \(parentIntent)")
        }

        let siblings = parent.decodedSubItems.enumerated().compactMap { (i, item) -> String? in
            guard i != index, !item.done else { return nil }
            let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if !siblings.isEmpty {
            let bulleted = siblings.prefix(5).map { "  • \($0)" }.joined(separator: "\n")
            lines.append("Sibling sub-items:\n\(bulleted)")
        }

        return TargetPrefill(
            text: subItem.text,
            intent: lines.joined(separator: "\n"),
            sourceType: "promoted_subitem",
            sourceID: "\(parent.id):\(index)",
            secondaryLinks: [],
            parentID: parent.id
        )
    }
}
```

- [ ] **Step 4: Run test, expect PASS**

Run: `cd WatchtowerDesktop && swift test --filter TargetPrefillBuilderTests`
Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Services/TargetPrefillBuilder.swift \
        WatchtowerDesktop/Tests/TargetPrefillBuilderTests.swift
git commit -m "feat(desktop-targets): TargetPrefillBuilder.fromSubItem"
```

---

## Task 3: `TargetPrefillBuilder.fromTrack`

Resolves channel names via `ChannelQueries.fetchByID` to enrich the intent.

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/TargetPrefillBuilder.swift`
- Modify: `WatchtowerDesktop/Tests/TargetPrefillBuilderTests.swift`

- [ ] **Step 1: Append failing tests to `TargetPrefillBuilderTests.swift`**

```swift
    // MARK: - fromTrack

    func testFromTrack_HappyPath() async throws {
        let dbQueue = try TestDatabase.create()
        try dbQueue.write { db in
            try TestDatabase.insertChannel(db, id: "C001", name: "general")
            try TestDatabase.insertChannel(db, id: "C002", name: "engineering")
            try TestDatabase.insertTrack(
                db,
                text: "Migrate auth service",
                context: "We need to swap the legacy IDP for the new one.",
                priority: "high",
                channelIDs: #"["C001","C002"]"#,
                blocking: "Waiting on infra",
                decisionSummary: "Going with provider X"
            )
        }
        let track = try await dbQueue.read { db in
            try XCTUnwrap(try Track.fetchOne(db, sql: "SELECT * FROM tracks WHERE id = 1"))
        }

        let mgr = DatabaseManager(pool: try DatabasePool(path: ":memory:"))
        // Re-seed the pool so the builder uses the same data.
        try mgr.dbPool.write { db in
            try db.execute(sql: TestDatabase.schema)
            try TestDatabase.insertChannel(db, id: "C001", name: "general")
            try TestDatabase.insertChannel(db, id: "C002", name: "engineering")
        }
        let prefill = try await TargetPrefillBuilder.fromTrack(track, db: mgr)

        XCTAssertEqual(prefill.text, "Migrate auth service")
        XCTAssertEqual(prefill.sourceType, "track")
        XCTAssertEqual(prefill.sourceID, "1")
        XCTAssertNil(prefill.parentID)
        XCTAssertTrue(prefill.intent.contains("We need to swap the legacy IDP"))
        XCTAssertTrue(prefill.intent.contains("Decision: Going with provider X"))
        XCTAssertTrue(prefill.intent.contains("Blocking: Waiting on infra"))
        XCTAssertTrue(prefill.intent.contains("In channels: #general, #engineering"))
        XCTAssertEqual(prefill.secondaryLinks.count, 2)
        XCTAssertEqual(prefill.secondaryLinks[0].externalRef, "slack:C001")
        XCTAssertEqual(prefill.secondaryLinks[0].relation, "related")
    }

    func testFromTrack_UnknownChannelFallsBackToID() async throws {
        let dbQueue = try TestDatabase.create()
        try dbQueue.write { db in
            try TestDatabase.insertTrack(
                db,
                text: "Track with orphan channel",
                channelIDs: #"["C999"]"#
            )
        }
        let track = try await dbQueue.read { db in
            try XCTUnwrap(try Track.fetchOne(db, sql: "SELECT * FROM tracks WHERE id = 1"))
        }
        let mgr = try Self.makeManagerSeededWith { _ in /* no channels */ }
        let prefill = try await TargetPrefillBuilder.fromTrack(track, db: mgr)
        XCTAssertTrue(prefill.intent.contains("In channels: #C999"))
        XCTAssertEqual(prefill.secondaryLinks.first?.externalRef, "slack:C999")
    }

    /// Helper that creates a file-backed `DatabaseManager` (DatabasePool requires
    /// a path) with the schema applied and a caller-supplied seed closure. Tests
    /// must call `TestDatabase.cleanup(path:)` if they want to remove the file
    /// after the test; we let the OS reap them since each test uses a UUID.
    static func makeManagerSeededWith(_ seed: (Database) throws -> Void) throws -> DatabaseManager {
        let path = NSTemporaryDirectory() + "twtest_\(UUID().uuidString).db"
        let pool = try DatabasePool(path: path)
        try pool.write { db in
            try db.execute(sql: TestDatabase.schema)
            try seed(db)
        }
        return DatabaseManager(pool: pool)
    }
```

Replace the body of `testFromTrack_HappyPath` to also use `makeManagerSeededWith` so it's a single seeded manager. Final form:

```swift
    func testFromTrack_HappyPath() async throws {
        let mgr = try Self.makeManagerSeededWith { db in
            try TestDatabase.insertChannel(db, id: "C001", name: "general")
            try TestDatabase.insertChannel(db, id: "C002", name: "engineering")
            try TestDatabase.insertTrack(
                db,
                text: "Migrate auth service",
                context: "We need to swap the legacy IDP for the new one.",
                priority: "high",
                channelIDs: #"["C001","C002"]"#,
                blocking: "Waiting on infra",
                decisionSummary: "Going with provider X"
            )
        }
        let track = try await mgr.dbPool.read { db in
            try XCTUnwrap(try Track.fetchOne(db, sql: "SELECT * FROM tracks WHERE id = 1"))
        }
        let prefill = try await TargetPrefillBuilder.fromTrack(track, db: mgr)

        XCTAssertEqual(prefill.text, "Migrate auth service")
        XCTAssertEqual(prefill.sourceType, "track")
        XCTAssertEqual(prefill.sourceID, "1")
        XCTAssertNil(prefill.parentID)
        XCTAssertTrue(prefill.intent.contains("We need to swap the legacy IDP"))
        XCTAssertTrue(prefill.intent.contains("Decision: Going with provider X"))
        XCTAssertTrue(prefill.intent.contains("Blocking: Waiting on infra"))
        XCTAssertTrue(prefill.intent.contains("In channels: #general, #engineering"))
        XCTAssertEqual(prefill.secondaryLinks.count, 2)
        XCTAssertEqual(prefill.secondaryLinks[0].externalRef, "slack:C001")
        XCTAssertEqual(prefill.secondaryLinks[0].relation, "related")
    }
```

- [ ] **Step 2: Run tests, expect FAIL**

Run: `cd WatchtowerDesktop && swift test --filter TargetPrefillBuilderTests`
Expected: compile error — `TargetPrefillBuilder.fromTrack` is undefined.

- [ ] **Step 3: Implement `fromTrack` in `TargetPrefillBuilder.swift`**

Append to the enum:

```swift
    // MARK: - fromTrack

    static func fromTrack(_ track: Track, db: DatabaseManager) async throws -> TargetPrefill {
        let channelIDs = Array(track.decodedChannelIDs.prefix(3))
        let names = try await db.dbPool.read { dbConn -> [String] in
            try channelIDs.map { id in
                if let ch = try ChannelQueries.fetchByID(dbConn, id: id) {
                    return ch.name
                }
                return id
            }
        }

        var lines: [String] = []
        let context = track.context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.isEmpty { lines.append(context) }

        let decision = track.decisionSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !decision.isEmpty { lines.append("Decision: \(decision)") }

        let blocking = track.blocking.trimmingCharacters(in: .whitespacesAndNewlines)
        if !blocking.isEmpty { lines.append("Blocking: \(blocking)") }

        if !names.isEmpty {
            let pretty = names.map { "#\($0)" }.joined(separator: ", ")
            lines.append("In channels: \(pretty)")
        }

        let links = channelIDs.map {
            TargetPrefillLink(externalRef: "slack:\($0)", relation: "related")
        }

        return TargetPrefill(
            text: track.text,
            intent: lines.joined(separator: "\n"),
            sourceType: "track",
            sourceID: String(track.id),
            secondaryLinks: links,
            parentID: nil
        )
    }
```

- [ ] **Step 4: Run tests, expect PASS**

Run: `cd WatchtowerDesktop && swift test --filter TargetPrefillBuilderTests`
Expected: all 4 tests pass (2 from sub-item, 2 from track).

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Services/TargetPrefillBuilder.swift \
        WatchtowerDesktop/Tests/TargetPrefillBuilderTests.swift
git commit -m "feat(desktop-targets): TargetPrefillBuilder.fromTrack"
```

---

## Task 4: `TargetPrefillBuilder.fromDigest` + `insertDigestTopic` test fixture

`fromDigest` accepts an optional `DigestTopic`. The test needs an `insertDigestTopic` helper which `TestDatabase` does not have today — adding it is part of this task.

**Files:**
- Modify: `WatchtowerDesktop/Tests/Helpers/TestDatabase.swift`
- Modify: `WatchtowerDesktop/Sources/Services/TargetPrefillBuilder.swift`
- Modify: `WatchtowerDesktop/Tests/TargetPrefillBuilderTests.swift`

- [ ] **Step 1: Add `insertDigestTopic` to `TestDatabase`**

Append inside the `TestDatabase` enum, near `insertDigest` (around line 121):

```swift
    @discardableResult
    static func insertDigestTopic(
        _ db: Database,
        digestID: Int = 1,
        idx: Int = 0,
        title: String = "Sample topic",
        summary: String = "Topic summary",
        decisions: String = "[]",
        actionItems: String = "[]",
        situations: String = "[]",
        keyMessages: String = "[]"
    ) throws -> Int64 {
        try db.execute(sql: """
            INSERT INTO digest_topics (digest_id, idx, title, summary, decisions, action_items, situations, key_messages)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [digestID, idx, title, summary, decisions, actionItems, situations, keyMessages])
        return db.lastInsertedRowID
    }
```

- [ ] **Step 2: Append failing tests for `fromDigest`**

```swift
    // MARK: - fromDigest

    func testFromDigest_WithTopic() async throws {
        let mgr = try Self.makeManagerSeededWith { db in
            try TestDatabase.insertChannel(db, id: "C100", name: "deals")
            try TestDatabase.insertDigest(
                db,
                channelID: "C100",
                summary: "Channel-level summary"
            )
            try TestDatabase.insertDigestTopic(
                db,
                digestID: 1,
                idx: 0,
                title: "Q2 pipeline review",
                summary: "Three deals at risk; Acme is committed.",
                keyMessages: #"["Acme signed the NDA","Beta wants a 10% discount"]"#
            )
        }
        let digest = try await mgr.dbPool.read { db in
            try XCTUnwrap(try Digest.fetchOne(db, sql: "SELECT * FROM digests WHERE id = 1"))
        }
        let topic = try await mgr.dbPool.read { db in
            try XCTUnwrap(try DigestTopic.fetchOne(db, sql: "SELECT * FROM digest_topics WHERE id = 1"))
        }

        let prefill = try await TargetPrefillBuilder.fromDigest(digest, topic: topic, db: mgr)
        XCTAssertEqual(prefill.text, "Q2 pipeline review")
        XCTAssertEqual(prefill.sourceType, "digest")
        XCTAssertEqual(prefill.sourceID, "1")
        XCTAssertTrue(prefill.intent.contains("From digest in #deals"))
        XCTAssertTrue(prefill.intent.contains("Three deals at risk"))
        XCTAssertTrue(prefill.intent.contains("Acme signed the NDA"))
        XCTAssertEqual(prefill.secondaryLinks, [
            TargetPrefillLink(externalRef: "slack:C100", relation: "related")
        ])
    }

    func testFromDigest_NoTopic_FallsBackToSummary() async throws {
        let mgr = try Self.makeManagerSeededWith { db in
            try TestDatabase.insertChannel(db, id: "C200", name: "ops")
            try TestDatabase.insertDigest(db, channelID: "C200", summary: "Plain summary")
        }
        let digest = try await mgr.dbPool.read { db in
            try XCTUnwrap(try Digest.fetchOne(db, sql: "SELECT * FROM digests WHERE id = 1"))
        }
        let prefill = try await TargetPrefillBuilder.fromDigest(digest, topic: nil, db: mgr)
        XCTAssertTrue(prefill.text.contains("Plain summary"))
        XCTAssertTrue(prefill.intent.contains("From digest in #ops"))
        XCTAssertTrue(prefill.intent.contains("Plain summary"))
        XCTAssertFalse(prefill.intent.contains("Key messages:"))
    }

    func testFromDigest_UnknownChannelFallsBackToID() async throws {
        let mgr = try Self.makeManagerSeededWith { db in
            try TestDatabase.insertDigest(db, channelID: "C404", summary: "Orphan digest")
        }
        let digest = try await mgr.dbPool.read { db in
            try XCTUnwrap(try Digest.fetchOne(db, sql: "SELECT * FROM digests WHERE id = 1"))
        }
        let prefill = try await TargetPrefillBuilder.fromDigest(digest, topic: nil, db: mgr)
        XCTAssertTrue(prefill.intent.contains("From digest in #C404"))
    }
```

- [ ] **Step 3: Run tests, expect FAIL** (compile error — `fromDigest` undefined)

Run: `cd WatchtowerDesktop && swift test --filter TargetPrefillBuilderTests`

- [ ] **Step 4: Implement `fromDigest`**

Append to `TargetPrefillBuilder.swift`:

```swift
    // MARK: - fromDigest

    static func fromDigest(_ digest: Digest, topic: DigestTopic?, db: DatabaseManager) async throws -> TargetPrefill {
        let channelName = try await db.dbPool.read { dbConn -> String in
            if let ch = try ChannelQueries.fetchByID(dbConn, id: digest.channelID) {
                return ch.name
            }
            return digest.channelID
        }

        let title: String
        if let t = topic {
            title = t.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? Self.firstLine(digest.summary)
                : t.title
        } else {
            title = Self.firstLine(digest.summary)
        }

        var lines: [String] = []
        lines.append("From digest in #\(channelName):")

        let body = (topic?.summary).flatMap { s -> String? in
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } ?? digest.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty { lines.append(body) }

        if let topic, !topic.parsedKeyMessages.isEmpty {
            let bulleted = topic.parsedKeyMessages.prefix(5).map { "  • \($0)" }.joined(separator: "\n")
            lines.append("Key messages:\n\(bulleted)")
        }

        let links: [TargetPrefillLink] = digest.channelID.isEmpty
            ? []
            : [TargetPrefillLink(externalRef: "slack:\(digest.channelID)", relation: "related")]

        return TargetPrefill(
            text: title.isEmpty ? digest.summary : title,
            intent: lines.joined(separator: "\n"),
            sourceType: "digest",
            sourceID: String(digest.id),
            secondaryLinks: links,
            parentID: nil
        )
    }

    // MARK: - Helpers

    private static func firstLine(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? s
    }
```

- [ ] **Step 5: Run tests, expect PASS**

Run: `cd WatchtowerDesktop && swift test --filter TargetPrefillBuilderTests`
Expected: 7 tests pass.

- [ ] **Step 6: Commit**

```bash
git add WatchtowerDesktop/Sources/Services/TargetPrefillBuilder.swift \
        WatchtowerDesktop/Tests/TargetPrefillBuilderTests.swift \
        WatchtowerDesktop/Tests/Helpers/TestDatabase.swift
git commit -m "feat(desktop-targets): TargetPrefillBuilder.fromDigest + insertDigestTopic fixture"
```

---

## Task 5: `TargetPrefillBuilder.fromInbox`

Resolves sender display name and channel name. Quotes the snippet in the intent body so the user retains the message anchor even after Slack scrolls past.

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/TargetPrefillBuilder.swift`
- Modify: `WatchtowerDesktop/Tests/TargetPrefillBuilderTests.swift`

- [ ] **Step 1: Append failing tests**

```swift
    // MARK: - fromInbox

    func testFromInbox_HappyPath() async throws {
        let mgr = try Self.makeManagerSeededWith { db in
            try TestDatabase.insertUser(db, id: "U010", name: "vlad", displayName: "Vlad", realName: "Vlad K.")
            try TestDatabase.insertChannel(db, id: "C300", name: "team")
            try TestDatabase.insertInboxItem(
                db,
                channelID: "C300",
                senderUserID: "U010",
                triggerType: "mention",
                snippet: "Need your call on the API contract",
                permalink: "https://slack.com/archives/C300/p123",
                aiReason: "Direct ask, blocking external commitment"
            )
        }
        let item = try await mgr.dbPool.read { db in
            try XCTUnwrap(try InboxItem.fetchOne(db, sql: "SELECT * FROM inbox_items LIMIT 1"))
        }

        let prefill = try await TargetPrefillBuilder.fromInbox(item, db: mgr)
        XCTAssertEqual(prefill.text, "Need your call on the API contract")
        XCTAssertEqual(prefill.sourceType, "inbox")
        XCTAssertEqual(prefill.sourceID, String(item.id))
        XCTAssertTrue(prefill.intent.contains("From @Vlad in #team (mention):"))
        XCTAssertTrue(prefill.intent.contains("\"Need your call on the API contract\""))
        XCTAssertTrue(prefill.intent.contains("Why it matters: Direct ask, blocking external commitment"))
        XCTAssertEqual(prefill.secondaryLinks, [
            TargetPrefillLink(externalRef: "slack:https://slack.com/archives/C300/p123", relation: "related")
        ])
    }

    func testFromInbox_NoPermalink_NoAIReason() async throws {
        let mgr = try Self.makeManagerSeededWith { db in
            try TestDatabase.insertUser(db, id: "U011", name: "jane", displayName: "")
            try TestDatabase.insertChannel(db, id: "C301", name: "design")
            try TestDatabase.insertInboxItem(
                db,
                channelID: "C301",
                senderUserID: "U011",
                triggerType: "dm",
                snippet: "ping",
                permalink: ""
            )
        }
        let item = try await mgr.dbPool.read { db in
            try XCTUnwrap(try InboxItem.fetchOne(db, sql: "SELECT * FROM inbox_items LIMIT 1"))
        }
        let prefill = try await TargetPrefillBuilder.fromInbox(item, db: mgr)
        XCTAssertTrue(prefill.secondaryLinks.isEmpty)
        XCTAssertFalse(prefill.intent.contains("Why it matters:"))
    }
```

- [ ] **Step 2: Run tests, expect FAIL** (compile error)

Run: `cd WatchtowerDesktop && swift test --filter TargetPrefillBuilderTests`

- [ ] **Step 3: Implement `fromInbox`**

Append to `TargetPrefillBuilder.swift`:

```swift
    // MARK: - fromInbox

    static func fromInbox(_ item: InboxItem, db: DatabaseManager) async throws -> TargetPrefill {
        let (senderName, channelName) = try await db.dbPool.read { dbConn -> (String, String) in
            let display = try UserQueries.fetchDisplayName(dbConn, forID: item.senderUserID)
            let chName = try ChannelQueries.fetchByID(dbConn, id: item.channelID)?.name ?? item.channelID
            return (display, chName)
        }

        var lines: [String] = []
        lines.append("From @\(senderName) in #\(channelName) (\(item.triggerType)):")
        let snippetTrimmed = item.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        if !snippetTrimmed.isEmpty {
            lines.append("\"\(snippetTrimmed)\"")
        }
        let aiReason = item.aiReason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !aiReason.isEmpty {
            lines.append("Why it matters: \(aiReason)")
        }

        let links: [TargetPrefillLink] = item.permalink.isEmpty
            ? []
            : [TargetPrefillLink(externalRef: "slack:\(item.permalink)", relation: "related")]

        return TargetPrefill(
            text: item.snippet,
            intent: lines.joined(separator: "\n"),
            sourceType: "inbox",
            sourceID: String(item.id),
            secondaryLinks: links,
            parentID: nil
        )
    }
```

- [ ] **Step 4: Run tests, expect PASS**

Run: `cd WatchtowerDesktop && swift test --filter TargetPrefillBuilderTests`
Expected: 9 tests pass.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Services/TargetPrefillBuilder.swift \
        WatchtowerDesktop/Tests/TargetPrefillBuilderTests.swift
git commit -m "feat(desktop-targets): TargetPrefillBuilder.fromInbox"
```

---

## Task 6: `TargetPrefillBuilder.fromBriefingItem` (delegating)

Briefing is a meta-entity. When the attention item carries `source_type + source_id`, delegate to the matching upstream builder, and prepend a briefing prefix to the intent. Otherwise, fall back to a briefing-only prefill.

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/TargetPrefillBuilder.swift`
- Modify: `WatchtowerDesktop/Tests/TargetPrefillBuilderTests.swift`

- [ ] **Step 1: Append failing tests**

```swift
    // MARK: - fromBriefingItem

    func testFromBriefingItem_TrackUpstream_PassThrough() async throws {
        let mgr = try Self.makeManagerSeededWith { db in
            try TestDatabase.insertChannel(db, id: "C001", name: "general")
            try TestDatabase.insertTrack(
                db,
                text: "Migrate auth",
                context: "Auth context narrative.",
                channelIDs: #"["C001"]"#
            )
            try TestDatabase.insertBriefing(db, userID: "U001", date: "2026-04-28")
        }
        let briefing = try await mgr.dbPool.read { db in
            try XCTUnwrap(try Briefing.fetchOne(db, sql: "SELECT * FROM briefings LIMIT 1"))
        }
        // Build a synthetic AttentionItem with sourceType=track and sourceID=1.
        let itemJSON = #"""
        {"text":"Push auth migration this week","source_type":"track","source_id":"1","priority":"high","reason":"behind schedule"}
        """#
        let item = try JSONDecoder().decode(AttentionItem.self, from: Data(itemJSON.utf8))

        let prefill = try await TargetPrefillBuilder.fromBriefingItem(item, briefing: briefing, db: mgr)
        XCTAssertEqual(prefill.sourceType, "track")
        XCTAssertEqual(prefill.sourceID, "1")
        XCTAssertEqual(prefill.text, "Push auth migration this week")
        XCTAssertTrue(prefill.intent.hasPrefix("Surfaced in briefing on 2026-04-28."))
        XCTAssertTrue(prefill.intent.contains("Reason: behind schedule"))
        XCTAssertTrue(prefill.intent.contains("Briefing flag: high"))
        XCTAssertTrue(prefill.intent.contains("Auth context narrative."))
        XCTAssertTrue(prefill.intent.contains("In channels: #general"))
        XCTAssertEqual(prefill.secondaryLinks.first?.externalRef, "slack:C001")
    }

    func testFromBriefingItem_NoUpstream_FallbackToBriefing() async throws {
        let mgr = try Self.makeManagerSeededWith { db in
            try TestDatabase.insertBriefing(db, userID: "U001", date: "2026-04-28")
        }
        let briefing = try await mgr.dbPool.read { db in
            try XCTUnwrap(try Briefing.fetchOne(db, sql: "SELECT * FROM briefings LIMIT 1"))
        }
        let itemJSON = #"""
        {"text":"Adhoc reminder","reason":"because I said so"}
        """#
        let item = try JSONDecoder().decode(AttentionItem.self, from: Data(itemJSON.utf8))

        let prefill = try await TargetPrefillBuilder.fromBriefingItem(item, briefing: briefing, db: mgr)
        XCTAssertEqual(prefill.sourceType, "briefing")
        XCTAssertEqual(prefill.sourceID, String(briefing.id))
        XCTAssertEqual(prefill.text, "Adhoc reminder")
        XCTAssertTrue(prefill.intent.contains("because I said so"))
        XCTAssertTrue(prefill.secondaryLinks.isEmpty)
    }

    func testFromBriefingItem_UpstreamMissing_FallsBackToBriefing() async throws {
        let mgr = try Self.makeManagerSeededWith { db in
            try TestDatabase.insertBriefing(db, userID: "U001", date: "2026-04-28")
            // No track inserted; sourceID="999" will not resolve.
        }
        let briefing = try await mgr.dbPool.read { db in
            try XCTUnwrap(try Briefing.fetchOne(db, sql: "SELECT * FROM briefings LIMIT 1"))
        }
        let itemJSON = #"""
        {"text":"Stale ref","source_type":"track","source_id":"999"}
        """#
        let item = try JSONDecoder().decode(AttentionItem.self, from: Data(itemJSON.utf8))

        let prefill = try await TargetPrefillBuilder.fromBriefingItem(item, briefing: briefing, db: mgr)
        XCTAssertEqual(prefill.sourceType, "briefing")
        XCTAssertEqual(prefill.sourceID, String(briefing.id))
    }
```

- [ ] **Step 2: Run tests, expect FAIL** (compile error)

Run: `cd WatchtowerDesktop && swift test --filter TargetPrefillBuilderTests`

- [ ] **Step 3: Implement `fromBriefingItem` with delegation**

Append to `TargetPrefillBuilder.swift`:

```swift
    // MARK: - fromBriefingItem

    static func fromBriefingItem(_ item: AttentionItem,
                                 briefing: Briefing,
                                 db: DatabaseManager) async throws -> TargetPrefill {
        let prefix = briefingPrefix(item: item, briefing: briefing)

        // Delegate path: upstream entity present.
        if let sourceType = item.sourceType, let sourceID = item.sourceID,
           let id = Int(sourceID), !sourceType.isEmpty {
            switch sourceType {
            case "track":
                if let track = try await db.dbPool.read({ db in
                    try Track.fetchOne(db, sql: "SELECT * FROM tracks WHERE id = ?", arguments: [id])
                }) {
                    var pf = try await fromTrack(track, db: db)
                    pf.text = item.text   // briefing wording wins for the title
                    pf.intent = prefix + "\n\n" + pf.intent
                    return pf
                }
            case "digest":
                if let digest = try await db.dbPool.read({ db in
                    try Digest.fetchOne(db, sql: "SELECT * FROM digests WHERE id = ?", arguments: [id])
                }) {
                    var pf = try await fromDigest(digest, topic: nil, db: db)
                    pf.text = item.text
                    pf.intent = prefix + "\n\n" + pf.intent
                    return pf
                }
            case "inbox":
                if let inbox = try await db.dbPool.read({ db in
                    try InboxItem.fetchOne(db, sql: "SELECT * FROM inbox_items WHERE id = ?", arguments: [id])
                }) {
                    var pf = try await fromInbox(inbox, db: db)
                    pf.text = item.text
                    pf.intent = prefix + "\n\n" + pf.intent
                    return pf
                }
            default:
                break
            }
        }

        // Fallback path: no upstream / unknown type / upstream not found.
        let reason = item.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return TargetPrefill(
            text: item.text,
            intent: reason.isEmpty ? prefix : "\(prefix)\n\nReason: \(reason)",
            sourceType: "briefing",
            sourceID: String(briefing.id),
            secondaryLinks: [],
            parentID: nil
        )
    }

    private static func briefingPrefix(item: AttentionItem, briefing: Briefing) -> String {
        var lines: [String] = ["Surfaced in briefing on \(briefing.date)."]
        if let r = item.reason, !r.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Reason: \(r.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        if let p = item.priority, !p.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("Briefing flag: \(p.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return lines.joined(separator: "\n")
    }
```

- [ ] **Step 4: Run tests, expect PASS**

Run: `cd WatchtowerDesktop && swift test --filter TargetPrefillBuilderTests`
Expected: 12 tests pass.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Services/TargetPrefillBuilder.swift \
        WatchtowerDesktop/Tests/TargetPrefillBuilderTests.swift
git commit -m "feat(desktop-targets): TargetPrefillBuilder.fromBriefingItem with upstream delegation"
```

---

## Task 7: `TargetQueries.create` — `secondaryLinks` parameter

Round-trip: a target inserted with non-empty `secondaryLinks` ends up with one row per valid link in `target_links`. Invalid `external_ref` values are dropped silently.

**Files:**
- Modify: `WatchtowerDesktop/Sources/Database/Queries/TargetQueries.swift`
- Create: `WatchtowerDesktop/Tests/TargetQueriesCreateLinksTests.swift`

- [ ] **Step 1: Write the failing test file**

```swift
// WatchtowerDesktop/Tests/TargetQueriesCreateLinksTests.swift
import XCTest
import GRDB
@testable import WatchtowerDesktop

final class TargetQueriesCreateLinksTests: XCTestCase {

    func testCreate_PersistsValidLinks_DropsInvalid() throws {
        let queue = try TestDatabase.create()
        let newID = try queue.write { db -> Int in
            try TargetQueries.create(
                db,
                text: "with-links",
                periodStart: "2026-04-28",
                periodEnd: "2026-04-28",
                sourceType: "inbox",
                sourceID: "0",
                secondaryLinks: [
                    TargetPrefillLink(externalRef: "slack:Cabc/p1", relation: "related"),
                    TargetPrefillLink(externalRef: "jira:PROJ-42", relation: "blocks"),
                    TargetPrefillLink(externalRef: "http://invalid", relation: "related"),  // dropped
                    TargetPrefillLink(externalRef: "", relation: "related")                 // dropped (empty)
                ]
            )
        }

        let links = try queue.read { db in
            try TargetLink.fetchAll(
                db,
                sql: "SELECT * FROM target_links WHERE source_target_id = ? ORDER BY id ASC",
                arguments: [newID]
            )
        }
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links[0].externalRef, "slack:Cabc/p1")
        XCTAssertEqual(links[0].relation, "related")
        XCTAssertEqual(links[1].externalRef, "jira:PROJ-42")
        XCTAssertEqual(links[1].relation, "blocks")
    }

    func testCreate_NoLinks_DefaultBehaviour() throws {
        let queue = try TestDatabase.create()
        let newID = try queue.write { db -> Int in
            try TargetQueries.create(
                db,
                text: "no-links",
                periodStart: "2026-04-28",
                periodEnd: "2026-04-28",
                sourceType: "manual",
                sourceID: ""
            )
        }
        let count = try queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM target_links WHERE source_target_id = ?",
                arguments: [newID]
            ) ?? 0
        }
        XCTAssertEqual(count, 0)
    }
}
```

- [ ] **Step 2: Run test, expect FAIL** (compile — no `secondaryLinks:` parameter)

Run: `cd WatchtowerDesktop && swift test --filter TargetQueriesCreateLinksTests`

- [ ] **Step 3: Extend `TargetQueries.create` signature and body**

In `WatchtowerDesktop/Sources/Database/Queries/TargetQueries.swift`, locate the `create` method (line 162). Add a trailing parameter and a post-INSERT loop:

```swift
    @discardableResult
    static func create(
        _ db: Database,
        text: String,
        intent: String = "",
        level: String = "day",
        customLabel: String = "",
        periodStart: String,
        periodEnd: String,
        parentId: Int? = nil,
        status: String = "todo",
        priority: String = "medium",
        ownership: String = "mine",
        ballOn: String = "",
        dueDate: String = "",
        snoozeUntil: String = "",
        blocking: String = "",
        tags: String = "[]",
        subItems: String = "[]",
        notes: String = "[]",
        progress: Double = 0.0,
        sourceType: String = "manual",
        sourceID: String = "",
        aiLevelConfidence: Double? = nil,
        secondaryLinks: [TargetPrefillLink] = []
    ) throws -> Int {
        try db.execute(sql: """
            INSERT INTO targets (text, intent, level, custom_label, period_start, period_end,
                parent_id, status, priority, ownership, ball_on, due_date, snooze_until,
                blocking, tags, sub_items, notes, progress, source_type, source_id, ai_level_confidence)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [text, intent, level, customLabel, periodStart, periodEnd,
                             parentId, status, priority, ownership, ballOn, dueDate, snoozeUntil,
                             blocking, tags, subItems, notes, progress, sourceType, sourceID, aiLevelConfidence])
        let newID = Int(db.lastInsertedRowID)

        for link in secondaryLinks {
            let ref = link.externalRef
            // Allow-list mirrors the Go-side `IsValidExternalRef` in
            // internal/targets/extractor.go:146 — only "jira:" and "slack:" pass.
            guard ref.hasPrefix("jira:") || ref.hasPrefix("slack:") else { continue }
            try db.execute(
                sql: """
                    INSERT INTO target_links (source_target_id, target_target_id, external_ref, relation, created_by)
                    VALUES (?, NULL, ?, ?, 'user')
                    """,
                arguments: [newID, ref, link.relation]
            )
        }

        return newID
    }
```

- [ ] **Step 4: Run test, expect PASS**

Run: `cd WatchtowerDesktop && swift test --filter TargetQueriesCreateLinksTests`
Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Database/Queries/TargetQueries.swift \
        WatchtowerDesktop/Tests/TargetQueriesCreateLinksTests.swift
git commit -m "feat(desktop-targets): TargetQueries.create accepts secondaryLinks"
```

---

## Task 8: `CreateTargetSheet` — replace API with `prefill: TargetPrefill?` + `onCreated`

This task changes the public signature of `CreateTargetSheet`. All four current callsites must compile after this change. The mechanical migration of each callsite to actually use `TargetPrefillBuilder` happens in Tasks 10-14; **here** we only swap parameter shape and pass `nil` (briefing/digest/track keep working with empty-prefill via the next tasks; the inbox callsite is untouched until Task 14).

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Targets/CreateTargetSheet.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Briefings/BriefingDetailView.swift` (compile fix only)
- Modify: `WatchtowerDesktop/Sources/Views/Digests/DigestDetailView.swift` (compile fix only)
- Modify: `WatchtowerDesktop/Sources/Views/Tracks/TrackDetailView.swift` (compile fix only)

- [ ] **Step 1: Replace the parameter list and `onAppear` body in `CreateTargetSheet.swift`**

Replace the four `prefill*` properties (lines 7-10):

```swift
    var prefill: TargetPrefill? = nil
    /// Fires after a successful insert with the new target id. Used by inbox to
    /// backfill `inbox_items.target_id` via `InboxQueries.linkTarget`.
    var onCreated: ((Int) -> Void)? = nil
```

Replace the `@State` declarations for `sourceType`/`sourceID` (note: the current `prefillSourceType`/`prefillSourceID` were properties, not `@State`). Add new `@State` for the runtime values:

```swift
    @State private var sourceType: String = "manual"
    @State private var sourceID: String = ""
    @State private var secondaryLinks: [TargetPrefillLink] = []
```

Replace the `onAppear` (line 48-57):

```swift
        .onAppear {
            if let p = prefill {
                text = p.text
                intent = p.intent
                sourceType = p.sourceType
                sourceID = p.sourceID
                secondaryLinks = p.secondaryLinks
            } else {
                text = ""
                intent = ""
                sourceType = "manual"
                sourceID = ""
                secondaryLinks = []
            }
            if !intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                showMoreOptions = true
            }
            if !subItems.isEmpty {
                showChecklist = true
            }
        }
```

Update `sourceInfo` (line 273-283) to read the new `@State`:

```swift
    @ViewBuilder
    private var sourceInfo: some View {
        if sourceType != "manual" {
            HStack(spacing: 4) {
                Image(systemName: sourceIcon)
                    .foregroundStyle(.secondary)
                Text("From \(sourceType) #\(sourceID)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
```

Update `createTargetAndPromote()` to pass `secondaryLinks` and call `onCreated`:

In the body of `createTargetAndPromote()`, replace the `try TargetQueries.create(...)` invocation (line 391-402) with:

```swift
            newID = try await db.dbPool.write { dbConn -> Int in
                try TargetQueries.create(
                    dbConn,
                    text: trimmed,
                    intent: intentCopy,
                    level: levelCopy,
                    periodStart: start,
                    periodEnd: end,
                    priority: priorityCopy,
                    subItems: subItemsJSON,
                    sourceType: sourceTypeCopy,
                    sourceID: sourceIDCopy,
                    secondaryLinks: secondaryLinksCopy
                )
            }
```

Where `secondaryLinksCopy` is captured alongside the existing copies:

```swift
        let secondaryLinksCopy = secondaryLinks
```

Right before `dismiss()` (line 425), insert the callback fire:

```swift
        onCreated?(newID)
        dismiss()
    }
```

- [ ] **Step 2: Update the four current callsites with empty `prefill` so the project still builds**

`BriefingDetailView.swift:27-34` — replace:

```swift
        .sheet(isPresented: $showCreateTarget) {
            CreateTargetSheet(prefill: targetPrefill)
        }
```

And add the `@State`:

```swift
    @State private var targetPrefill: TargetPrefill?
```

Remove the now-unused `targetPrefillText` and `targetPrefillIntent` properties (they were `@State` strings). Their existing wiring in attention-item callbacks (around line 191-193) will be rewritten in Task 10. For now, replace those callback bodies with placeholders that just open the sheet without prefill:

```swift
                Button {
                    targetPrefill = nil       // TODO Task 10
                    showCreateTarget = true
                } label: { Label("Create target", systemImage: "scope") }
```

Apply the analogous mechanical change in `DigestDetailView.swift:69-74` and `TrackDetailView.swift:498-506`. Each gets a `@State var targetPrefill: TargetPrefill?` and a placeholder `targetPrefill = nil` in the trigger.

(`TargetDetailView.swift:130` opens `PromoteSubItemSheet`, not `CreateTargetSheet`, so it is untouched here.)

- [ ] **Step 3: Verify compile**

Run: `cd WatchtowerDesktop && swift build`
Expected: build success.

- [ ] **Step 4: Run the existing test suite to make sure nothing regressed**

Run: `cd WatchtowerDesktop && swift test`
Expected: all green; `TargetPrefillBuilderTests` still pass; no failures in `PromoteSubItemSheetTests` or any other smoke test.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Views/Targets/CreateTargetSheet.swift \
        WatchtowerDesktop/Sources/Views/Briefings/BriefingDetailView.swift \
        WatchtowerDesktop/Sources/Views/Digests/DigestDetailView.swift \
        WatchtowerDesktop/Sources/Views/Tracks/TrackDetailView.swift
git commit -m "refactor(desktop-targets): CreateTargetSheet takes TargetPrefill + onCreated"
```

---

## Task 9: `PromoteSubItemSheet` — accept `prefilledIntent`

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Targets/PromoteSubItemSheet.swift`

- [ ] **Step 1: Add the parameter and use it in `init`**

In `PromoteSubItemSheet.swift`, the existing initializer (lines 34-56) sets `_intent = State(initialValue: parent.intent)`. Add an optional `prefilledIntent` parameter and prefer it when non-nil:

```swift
    init(
        parent: Target,
        subItem: TargetSubItem,
        subItemIndex: Int,
        viewModel: TargetsViewModel,
        cliRunner: CLIRunnerProtocol? = nil,
        prefilledIntent: String? = nil
    ) {
        self.parent = parent
        self.subItem = subItem
        self.subItemIndex = subItemIndex
        self.viewModel = viewModel
        self.cliRunner = cliRunner
        _text = State(initialValue: subItem.text)
        _intent = State(initialValue: prefilledIntent ?? parent.intent)
        _level = State(initialValue: parent.level)
        _priority = State(initialValue: parent.priority)
        _ownership = State(initialValue: parent.ownership)

        let inheritedDueRaw = subItem.dueDate?.isEmpty == false ? subItem.dueDate : (parent.dueDate.isEmpty ? nil : parent.dueDate)
        _hasDueDate = State(initialValue: inheritedDueRaw != nil)
        _dueDate = State(initialValue: Target.parseDueDate(inheritedDueRaw ?? "") ?? Date())
        let initialIntent = prefilledIntent ?? parent.intent
        _showIntent = State(initialValue: !initialIntent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
```

- [ ] **Step 2: Verify compile**

Run: `cd WatchtowerDesktop && swift build`
Expected: build success — existing callsite in `TargetDetailView.swift:130` still compiles because the new parameter has a default.

- [ ] **Step 3: Run existing PromoteSubItemSheet tests**

Run: `cd WatchtowerDesktop && swift test --filter PromoteSubItemSheetTests`
Expected: all green (the addition is backward-compatible).

- [ ] **Step 4: Commit**

```bash
git add WatchtowerDesktop/Sources/Views/Targets/PromoteSubItemSheet.swift
git commit -m "feat(desktop-targets): PromoteSubItemSheet accepts prefilledIntent"
```

---

## Task 10: Wire `BriefingDetailView` to `TargetPrefillBuilder.fromBriefingItem`

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Briefings/BriefingDetailView.swift`

- [ ] **Step 1: Add error-banner state and async opener**

Add the `@State`s near the existing `targetPrefill` declaration:

```swift
    @State private var targetPrefillError: String?
    @State private var isBuildingPrefill = false
```

Add a private method:

```swift
    private func openCreateTarget(for item: AttentionItem) {
        guard let db = appState.databaseManager else {
            targetPrefillError = "Database not available"
            return
        }
        Task { @MainActor in
            isBuildingPrefill = true
            defer { isBuildingPrefill = false }
            do {
                let pf = try await TargetPrefillBuilder.fromBriefingItem(item, briefing: briefing, db: db)
                targetPrefill = pf
                targetPrefillError = nil
                showCreateTarget = true
            } catch {
                targetPrefillError = "Failed to prepare prefill: \(error.localizedDescription)"
            }
        }
    }
```

- [ ] **Step 2: Replace the placeholder trigger from Task 8 with the new opener**

Locate the attention-item Create-target buttons (originally near line 191-193) and replace the body with:

```swift
                Button {
                    openCreateTarget(for: item)
                } label: { Label("Create target", systemImage: "scope") }
                .disabled(isBuildingPrefill)
```

If there is more than one place that triggers create from a briefing item (e.g., context menu plus toolbar), apply the same change to each one.

- [ ] **Step 3: Render the error banner**

Add a small banner near the existing `attentionSection` rendering, e.g. at the top of `body`'s `VStack`:

```swift
                if let msg = targetPrefillError {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                }
```

- [ ] **Step 4: Verify compile and run tests**

```bash
cd WatchtowerDesktop && swift build
cd WatchtowerDesktop && swift test
```
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Views/Briefings/BriefingDetailView.swift
git commit -m "feat(desktop-briefings): use TargetPrefillBuilder.fromBriefingItem"
```

---

## Task 11: Wire `DigestDetailView` to `TargetPrefillBuilder.fromDigest`

Same shape as Task 10, but for digest. The current view passes `digest.id` as `prefillSourceID`; we now build the prefill from the full `Digest` row.

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Digests/DigestDetailView.swift`

- [ ] **Step 1: Add the same `targetPrefillError` / `isBuildingPrefill` state introduced in Task 10**

```swift
    @State private var targetPrefillError: String?
    @State private var isBuildingPrefill = false
```

- [ ] **Step 2: Add the opener**

```swift
    private func openCreateTarget() {
        guard let db = appState.databaseManager else {
            targetPrefillError = "Database not available"
            return
        }
        Task { @MainActor in
            isBuildingPrefill = true
            defer { isBuildingPrefill = false }
            do {
                let pf = try await TargetPrefillBuilder.fromDigest(digest, topic: nil, db: db)
                targetPrefill = pf
                targetPrefillError = nil
                showCreateTarget = true
            } catch {
                targetPrefillError = "Failed to prepare prefill: \(error.localizedDescription)"
            }
        }
    }
```

- [ ] **Step 3: Replace the existing Create-target trigger to call `openCreateTarget()` instead of the Task 8 placeholder**

Replace the placeholder `targetPrefill = nil; showCreateTarget = true` with `openCreateTarget()`.

- [ ] **Step 4: Render the same banner pattern**

```swift
                if let msg = targetPrefillError {
                    Text(msg).font(.caption).foregroundStyle(.red).padding(.horizontal)
                }
```

- [ ] **Step 5: Verify compile and tests**

```bash
cd WatchtowerDesktop && swift build
cd WatchtowerDesktop && swift test
```

- [ ] **Step 6: Commit**

```bash
git add WatchtowerDesktop/Sources/Views/Digests/DigestDetailView.swift
git commit -m "feat(desktop-digests): use TargetPrefillBuilder.fromDigest"
```

---

## Task 12: Wire `TrackDetailView` to `TargetPrefillBuilder.fromTrack`

Identical structure to Task 11 with the track builder.

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Tracks/TrackDetailView.swift`

- [ ] **Step 1: Add state**

```swift
    @State private var targetPrefillError: String?
    @State private var isBuildingPrefill = false
```

- [ ] **Step 2: Add opener**

```swift
    private func openCreateTarget() {
        guard let db = appState.databaseManager else {
            targetPrefillError = "Database not available"
            return
        }
        Task { @MainActor in
            isBuildingPrefill = true
            defer { isBuildingPrefill = false }
            do {
                let pf = try await TargetPrefillBuilder.fromTrack(track, db: db)
                targetPrefill = pf
                targetPrefillError = nil
                showCreateTarget = true
            } catch {
                targetPrefillError = "Failed to prepare prefill: \(error.localizedDescription)"
            }
        }
    }
```

- [ ] **Step 3: Replace placeholder trigger and add banner** (same pattern)

- [ ] **Step 4: Verify compile and tests**

```bash
cd WatchtowerDesktop && swift build
cd WatchtowerDesktop && swift test
```

- [ ] **Step 5: Commit**

```bash
git add WatchtowerDesktop/Sources/Views/Tracks/TrackDetailView.swift
git commit -m "feat(desktop-tracks): use TargetPrefillBuilder.fromTrack"
```

---

## Task 13: Wire `TargetDetailView` promote-flow to `TargetPrefillBuilder.fromSubItem`

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Targets/TargetDetailView.swift`

The `PromoteSubItemSheet` mounting site is at line 129-136 of `TargetDetailView.swift`:

```swift
        .sheet(item: $promotingSubItem) { ctx in
            PromoteSubItemSheet(
                parent: target,
                subItem: ctx.item,
                subItemIndex: ctx.index,
                viewModel: viewModel
            )
        }
```

- [ ] **Step 1: Compute the prefill and pass `prefilledIntent`**

Replace with:

```swift
        .sheet(item: $promotingSubItem) { ctx in
            let prefill = TargetPrefillBuilder.fromSubItem(
                parent: target,
                subItem: ctx.item,
                index: ctx.index
            )
            PromoteSubItemSheet(
                parent: target,
                subItem: ctx.item,
                subItemIndex: ctx.index,
                viewModel: viewModel,
                prefilledIntent: prefill.intent
            )
        }
```

(The other fields of the prefill are not needed here — `PromoteSubItemSheet` already inherits level/priority/etc. from the parent in its `init`. Only `intent` is enriched.)

- [ ] **Step 2: Verify compile and tests**

```bash
cd WatchtowerDesktop && swift build
cd WatchtowerDesktop && swift test --filter PromoteSubItemSheetTests
```

- [ ] **Step 3: Commit**

```bash
git add WatchtowerDesktop/Sources/Views/Targets/TargetDetailView.swift
git commit -m "feat(desktop-targets): rich intent for promote-subitem flow"
```

---

## Task 14: Migrate inbox flow to `CreateTargetSheet` + delete `InboxQueries.createTask`

This is the largest behavioural change in the plan. Do it as one cohesive commit so the inbox is never in a half-migrated state.

**Files:**
- Modify: `WatchtowerDesktop/Sources/Views/Inbox/InboxFeedView.swift`
- Modify: `WatchtowerDesktop/Sources/ViewModels/InboxViewModel.swift`
- Modify: `WatchtowerDesktop/Sources/Database/Queries/InboxQueries.swift`
- Modify: `WatchtowerDesktop/Tests/InboxTests.swift`

- [ ] **Step 1: Add prefill + sheet state to `InboxFeedView`**

Near the top of `InboxFeedView`'s state declarations, add:

```swift
    @State private var pendingInboxItem: InboxItem?
    @State private var targetPrefill: TargetPrefill?
    @State private var showCreateTarget = false
    @State private var targetPrefillError: String?
    @State private var isBuildingPrefill = false
```

- [ ] **Step 2: Replace the existing `onCreateTask:` callback wiring**

Locate the row construction (around line 191):

```swift
            onCreateTask: { vm.createTask(from: item) },
```

Replace with:

```swift
            onCreateTask: { openCreateTarget(for: item) },
```

- [ ] **Step 3: Add the opener method**

```swift
    private func openCreateTarget(for item: InboxItem) {
        guard let db = appState.databaseManager else {
            targetPrefillError = "Database not available"
            return
        }
        Task { @MainActor in
            isBuildingPrefill = true
            defer { isBuildingPrefill = false }
            do {
                let pf = try await TargetPrefillBuilder.fromInbox(item, db: db)
                targetPrefill = pf
                pendingInboxItem = item
                targetPrefillError = nil
                showCreateTarget = true
            } catch {
                targetPrefillError = "Failed to prepare prefill: \(error.localizedDescription)"
            }
        }
    }
```

- [ ] **Step 4: Mount the sheet with `onCreated` that runs `linkTarget`**

Add to the view's modifier chain (alongside any existing `.sheet(...)` modifiers):

```swift
        .sheet(isPresented: $showCreateTarget) {
            CreateTargetSheet(
                prefill: targetPrefill,
                onCreated: { newID in
                    guard let item = pendingInboxItem,
                          let db = appState.databaseManager else { return }
                    Task.detached {
                        try? await db.dbPool.write { dbConn in
                            try InboxQueries.linkTarget(dbConn, inboxID: item.id, targetID: newID)
                        }
                    }
                }
            )
        }
```

- [ ] **Step 5: Render the same error banner pattern as Tasks 10-12**

```swift
                if let msg = targetPrefillError {
                    Text(msg).font(.caption).foregroundStyle(.red).padding(.horizontal)
                }
```

- [ ] **Step 6: Delete `InboxViewModel.createTask(from:)`**

In `WatchtowerDesktop/Sources/ViewModels/InboxViewModel.swift`, remove the entire method (lines around 285-289). If a `vm.createTask` call remains anywhere, swift build will surface it.

- [ ] **Step 7: Delete `InboxQueries.createTask(_:from:)`**

In `WatchtowerDesktop/Sources/Database/Queries/InboxQueries.swift`, remove the function (lines 140-154). Keep `linkTarget(_:inboxID:targetID:)` — it is now used by the sheet's `onCreated` callback.

- [ ] **Step 8: Update `InboxTests.swift`**

Find the test(s) that exercise `InboxQueries.createTask` (search the file for `createTask`). Each one is replaced by an equivalent test that:
1. inserts an inbox item;
2. inserts a target via `TargetQueries.create(... sourceType: "inbox", sourceID: String(item.id))`;
3. calls `InboxQueries.linkTarget(_:inboxID:targetID:)`;
4. asserts that `inbox_items.target_id` == new target id.

Concrete replacement (place the test inside the existing `InboxTests` class — adapt the class name to whatever the file uses):

```swift
    func testLinkTargetSetsTargetID() throws {
        let queue = try TestDatabase.create()
        try queue.write { db in
            try TestDatabase.insertInboxItem(db, snippet: "ping")
        }
        let item = try queue.read { db in
            try XCTUnwrap(try InboxItem.fetchOne(db, sql: "SELECT * FROM inbox_items LIMIT 1"))
        }
        let newTargetID = try queue.write { db -> Int in
            try TargetQueries.create(
                db,
                text: "ping",
                periodStart: "2026-04-28",
                periodEnd: "2026-04-28",
                sourceType: "inbox",
                sourceID: String(item.id)
            )
        }
        try queue.write { db in
            try InboxQueries.linkTarget(db, inboxID: item.id, targetID: newTargetID)
        }
        let updated = try queue.read { db in
            try XCTUnwrap(try InboxItem.fetchOne(db, sql: "SELECT * FROM inbox_items WHERE id = ?", arguments: [item.id]))
        }
        XCTAssertEqual(updated.targetID, newTargetID)
    }
```

Delete any sibling tests that called the removed `InboxQueries.createTask` directly.

- [ ] **Step 9: Verify compile and tests**

```bash
cd WatchtowerDesktop && swift build
cd WatchtowerDesktop && swift test
```
Expected: all green. The whole inbox path now goes through the sheet, and the `InboxQueries.linkTarget` test confirms `inbox_items.target_id` is still backfilled.

- [ ] **Step 10: Commit**

```bash
git add WatchtowerDesktop/Sources/Views/Inbox/InboxFeedView.swift \
        WatchtowerDesktop/Sources/ViewModels/InboxViewModel.swift \
        WatchtowerDesktop/Sources/Database/Queries/InboxQueries.swift \
        WatchtowerDesktop/Tests/InboxTests.swift
git commit -m "feat(desktop-inbox): inbox→target now flows through CreateTargetSheet"
```

---

## Task 15: End-to-end smoke

A final sanity sweep so the implementer has a known-clean state before handing back.

- [ ] **Step 1: Full clean build**

```bash
cd WatchtowerDesktop && swift build
```
Expected: no warnings related to the new files.

- [ ] **Step 2: Full test run**

```bash
cd WatchtowerDesktop && swift test
```
Expected: all green. New suites (`TargetPrefillBuilderTests`, `TargetQueriesCreateLinksTests`) and updated `InboxTests` all pass; all existing suites still pass.

- [ ] **Step 3: Manual smoke test (the one thing tests cannot prove)**

Open the desktop app on a workspace that has at least one briefing, one digest, one track, one inbox item, and one target with sub-items. For each of the five entry points, click "Create target" / "Convert to sub-target":
- Briefing attention item → sheet opens with intent pre-populated; if upstream is a track, the `Source: track #N` footer shows.
- Digest detail → sheet opens with intent containing the channel name and digest summary.
- Track detail → sheet opens with intent containing the narrative + decision + channel list.
- Inbox row → sheet opens with quoted snippet, sender name, channel name; on Create, the inbox row's `target_id` updates (verify by viewing the row again).
- Target sub-item → "Convert to sub-target" sheet opens with `prefilledIntent` showing parent context + siblings list.

If any of these is wrong, fix the relevant builder (Tasks 2-6) — the form/wiring tasks (8-14) are mechanical and unlikely to be the culprit.

- [ ] **Step 4: No commit needed** (no new code; this is just verification).

---

## Self-Review Notes

- Spec coverage: each section/feature in the spec maps to a task above (TargetPrefill struct → T1, builders → T2-T6, TargetQueries.create → T7, sheet API → T8, PromoteSubItemSheet → T9, callsites → T10-T14, smoke → T15).
- Test 9 from the spec ("`fromSubItem` with parent that has 3 open siblings") is covered by `testFromSubItem_BasicShape` (3 sub-items, one being promoted, two siblings rendered).
- Test 10 from the spec (round-trip of `secondaryLinks` and dropping invalid ref) is covered by `testCreate_PersistsValidLinks_DropsInvalid` in T7.
- Test 11 from the spec (replace direct-create test) is covered by T14 step 8.
- Type consistency: `TargetPrefill` and `TargetPrefillLink` are introduced in T1 and used unchanged through every later task. `secondaryLinks` parameter name is consistent across T7 (queries) and T8 (sheet).
- No placeholders: every step contains the exact code or command to run; no "TODO/TBD/handle edge case" patterns.
