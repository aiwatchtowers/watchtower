# Watchtower Mobile — Plan 2: Desktop Hub

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The macOS app becomes the CloudKit hub: it publishes the product slice to DataZone, processes RelayZone commands (mutations via existing Queries, chat via the existing AI service), maintains a heartbeat, and exposes a Settings toggle.

**Architecture:** Two layers. In `WatchtowerKit`: a `CloudKitTransport` actor implementing the frozen `CloudSyncTransport` seam over `CKSyncEngine`, with a GRDB-backed `TransportStore` (event buffer + pending sends + engine state). In `WatchtowerDesktop`: `MobileHubService` owning three Task-loop workers (the `DigestWatcher` pattern) — `SlicePublisher` (poll → diff by payload hash → push), `RelayProcessor` (actions + chat), `HeartbeatPublisher` — plus a Settings tab. All hub logic is unit-tested against `InMemoryCloudTransport` and fixture DBs; only the thin CKSyncEngine wiring is compile-gated (CloudKit cannot run in unit tests).

**Tech Stack:** Swift 5.10, GRDB 7.x, CloudKit (CKSyncEngine, macOS 14+), XCTest.

**Spec:** `docs/superpowers/specs/2026-07-05-mobile-app-design.md`
**Carry-over notes:** `docs/superpowers/plans/2026-07-05-mobile-app-plan-2-notes.md` — all five items are resolved by design decisions below.

## Design decisions (resolve carry-over notes — read before implementing)

1. **Token shape (note 1).** `CloudChangeToken.value: Int` stays. The CKSyncEngine adapter buffers fetched changes into a local GRDB table with a monotonic `seq`; consumer tokens are positions in that buffer, exactly like `InMemoryCloudTransport`. `CKServerChangeToken`/engine state never leaks: `CKSyncEngine.State.Serialization` is persisted internally by the adapter as an opaque blob. The pull-shaped seam wraps the push-shaped engine via this buffer — no reshape, the Plan 1 fake and its tests stay valid.
2. **Encode failures (note 2).** `SlicePublisher` skips-and-logs a record whose `RowPayloadCoder.payload(from:)` throws (Inf/NaN); the push cycle never aborts. Pinned by test.
3. **Idempotent delete (note 3).** Contract decision: `CloudSyncTransport.delete` IS idempotent — deleting an unknown recordName succeeds silently. The CK adapter swallows `.unknownItem` on delete sends. Documented on the protocol in Task 1.
4. **Relay record kinds (note 4).** Canonical `kind` strings defined in Task 1 as `RelayRecordKind`.
5. **ValueObservation correction (spec Section 1).** The Go daemon writes through its own connection, so GRDB `ValueObservation` in the app does NOT fire for daemon writes (see the comment in `InboxViewModel.startPolling()`). The hub polls (60 s slice / adaptive 3–30 s relay), same as `DigestWatcher`/`InboxViewModel`. When the app is later signed with push entitlements, CKSyncEngine push wake makes relay latency near-instant and the poll becomes a safety net — no code change needed beyond entitlements.

## Global Constraints

- Work in worktree `/Users/user/PhpstormProjects/watchtower/.claude/worktrees/mobile-app`, branch `feature/mobile-app-plan-2`. Commands run from the worktree root unless a `cd` is shown.
- Desktop behavior unchanged when the hub is OFF (default): after every task `cd WatchtowerDesktop && swift test` passes with `Executed 914 tests` plus only the tests this plan adds; `cd WatchtowerKit && swift test` passes with `Executed 24 tests` plus additions.
- CloudKit imports are allowed ONLY in `WatchtowerKit/Sources/WatchtowerKit/CloudKitTransport/` (Task 3). Everything else stays Foundation + GRDB.
- The Plan 1 frozen wire formats (RelayCoder fixtures, SliceKind rawValues, recordName schemes) must not change. `CloudSyncTransport` gains no new requirements — additions go to a separate protocol.
- SwiftLint strict passes in both packages (`swiftlint lint --strict`).
- The shared Go SQLite schema is NOT touched (no goose migration; the sidecar is app-private per spec).
- Both runtime sidecar files live under `~/Library/Application Support/Watchtower/`: `cloudkit-transport.sqlite` (Kit-owned, Task 2) and `mobile-hub.sqlite` (desktop-owned, Task 4). Tests use in-memory queues.
- CloudKit container ID constant: `iCloud.com.aiwatchtowers.watchtower` (Task 1; single source of truth, packaging validates it at release time). Dev builds are unsigned for CloudKit — every runtime CK failure must degrade to a reported status, never a crash (Task 3/8).
- UI change (Settings tab) requires updating `docs/app-guide.md` (Task 8) — it is injected into the chat system prompt.

---

### Task 1: Kit contracts — relay record kinds, CloudRecord factories, idempotent-delete doc, container ID

**Files:**
- Create: `WatchtowerKit/Sources/WatchtowerKit/Relay/RelayRecordKind.swift`
- Create: `WatchtowerKit/Sources/WatchtowerKit/Sync/CloudRecordFactory.swift`
- Modify: `WatchtowerKit/Sources/WatchtowerKit/Sync/CloudSyncTransport.swift` (doc comment only)
- Test: `WatchtowerKit/Tests/WatchtowerKitTests/CloudRecordFactoryTests.swift`

**Interfaces:**
- Consumes: `RelayCoder`, relay payload types, `SliceRecord`, `CloudRecord` (Plan 1).
- Produces:
  - `public enum RelayRecordKind: String, CaseIterable` — `action`, `chatMessage = "chat_message"`, `chatChunk = "chat_chunk"`, `heartbeat`.
  - `public enum WatchtowerCloud` — `public static let containerID = "iCloud.com.aiwatchtowers.watchtower"`.
  - `public enum CloudRecordFactory` with throwing static builders returning `CloudRecord`:
    - `record(for action: ActionRequestPayload, modifiedAt: Date) throws -> CloudRecord` (zone `.relay`, kind `RelayRecordKind.action.rawValue`, recordName `action.recordName`, payload = `RelayCoder` JSON)
    - `record(for message: ChatMessagePayload, modifiedAt: Date) throws -> CloudRecord`
    - `record(for chunk: ChatChunkPayload, modifiedAt: Date) throws -> CloudRecord`
    - `record(for heartbeat: HeartbeatPayload, modifiedAt: Date) throws -> CloudRecord`
    - `record(for slice: SliceRecord) -> CloudRecord` (zone `.data`, kind `slice.kind.rawValue`)
  - Idempotent-delete sentence appended to the `delete` requirement's doc comment in `CloudSyncTransport`.

- [ ] **Step 1: Write the failing tests**

`WatchtowerKit/Tests/WatchtowerKitTests/CloudRecordFactoryTests.swift`:

```swift
import XCTest
@testable import WatchtowerKit

final class CloudRecordFactoryTests: XCTestCase {
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    func testActionRecordIdentityAndPayload() throws {
        let action = ActionRequestPayload(id: "A1", kind: .inboxResolve, entityID: "5", createdAt: stamp)
        let record = try CloudRecordFactory.record(for: action, modifiedAt: stamp)
        XCTAssertEqual(record.recordName, "action-A1")
        XCTAssertEqual(record.zone, .relay)
        XCTAssertEqual(record.kind, "action")
        let decoded = try RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: record.payload)
        XCTAssertEqual(decoded, action)
    }

    func testChatChunkRecordIdentity() throws {
        let chunk = ChatChunkPayload(sessionID: "S1", messageID: "M1", seq: 0, text: "hi", done: false)
        let record = try CloudRecordFactory.record(for: chunk, modifiedAt: stamp)
        XCTAssertEqual(record.recordName, "chatchunk-M1-0")
        XCTAssertEqual(record.kind, "chat_chunk")
        XCTAssertEqual(record.zone, .relay)
    }

    func testHeartbeatRecordUsesStaticName() throws {
        let beat = HeartbeatPayload(updatedAt: stamp, appVersion: "1.0")
        let record = try CloudRecordFactory.record(for: beat, modifiedAt: stamp)
        XCTAssertEqual(record.recordName, "heartbeat")
        XCTAssertEqual(record.kind, "heartbeat")
    }

    func testSliceRecordMapsKindAndZone() {
        let slice = SliceRecord(kind: .target, id: "9", modifiedAt: stamp, payload: Data("{}".utf8))
        let record = CloudRecordFactory.record(for: slice)
        XCTAssertEqual(record.recordName, "target-9")
        XCTAssertEqual(record.zone, .data)
        XCTAssertEqual(record.kind, "target")
        XCTAssertEqual(record.payload, Data("{}".utf8))
    }

    func testRelayRecordKindRawValuesAreFrozen() {
        XCTAssertEqual(
            RelayRecordKind.allCases.map(\.rawValue),
            ["action", "chat_message", "chat_chunk", "heartbeat"]
        )
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd WatchtowerKit && swift test 2>&1 | head -20`
Expected: compile failure — `CloudRecordFactory`, `RelayRecordKind` not found.

- [ ] **Step 3: Implement**

`WatchtowerKit/Sources/WatchtowerKit/Relay/RelayRecordKind.swift`:

```swift
import Foundation

/// Canonical CloudRecord.kind strings for RelayZone records.
/// rawValues are wire format — never rename existing cases.
public enum RelayRecordKind: String, CaseIterable {
    case action
    case chatMessage = "chat_message"
    case chatChunk = "chat_chunk"
    case heartbeat
}

/// Cross-platform CloudKit constants.
public enum WatchtowerCloud {
    /// Single source of truth for the CloudKit container. Packaging must
    /// provision exactly this identifier in the app's entitlements.
    public static let containerID = "iCloud.com.aiwatchtowers.watchtower"
}
```

`WatchtowerKit/Sources/WatchtowerKit/Sync/CloudRecordFactory.swift`:

```swift
import Foundation

/// Builds CloudRecords from typed payloads so callers never assemble
/// zone/kind/recordName triples by hand.
public enum CloudRecordFactory {
    public static func record(for action: ActionRequestPayload, modifiedAt: Date) throws -> CloudRecord {
        try relayRecord(name: action.recordName, kind: .action, payload: action, modifiedAt: modifiedAt)
    }

    public static func record(for message: ChatMessagePayload, modifiedAt: Date) throws -> CloudRecord {
        try relayRecord(name: message.recordName, kind: .chatMessage, payload: message, modifiedAt: modifiedAt)
    }

    public static func record(for chunk: ChatChunkPayload, modifiedAt: Date) throws -> CloudRecord {
        try relayRecord(name: chunk.recordName, kind: .chatChunk, payload: chunk, modifiedAt: modifiedAt)
    }

    public static func record(for heartbeat: HeartbeatPayload, modifiedAt: Date) throws -> CloudRecord {
        try relayRecord(name: HeartbeatPayload.recordName, kind: .heartbeat, payload: heartbeat, modifiedAt: modifiedAt)
    }

    public static func record(for slice: SliceRecord) -> CloudRecord {
        CloudRecord(
            recordName: slice.recordName,
            zone: .data,
            kind: slice.kind.rawValue,
            modifiedAt: slice.modifiedAt,
            payload: slice.payload
        )
    }

    private static func relayRecord<P: Encodable>(
        name: String,
        kind: RelayRecordKind,
        payload: P,
        modifiedAt: Date
    ) throws -> CloudRecord {
        CloudRecord(
            recordName: name,
            zone: .relay,
            kind: kind.rawValue,
            modifiedAt: modifiedAt,
            payload: try RelayCoder.makeEncoder().encode(payload)
        )
    }
}
```

In `WatchtowerKit/Sources/WatchtowerKit/Sync/CloudSyncTransport.swift`, extend the `delete` requirement's doc comment with:

```swift
    /// Deleting is idempotent: deleting a recordName that was never saved
    /// (or is already deleted) succeeds silently. CloudKit adapters must
    /// swallow the server's unknown-item error to honor this.
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd WatchtowerKit && swift test 2>&1 | tail -3`
Expected: PASS (29 tests: 24 + 5 new).

- [ ] **Step 5: Lint and commit**

Run: `cd WatchtowerKit && swiftlint lint --strict` — expect 0 violations.

```bash
git add WatchtowerKit
git commit -m "feat(kit): relay record kinds, CloudRecord factories, idempotent-delete contract"
```

---

### Task 2: Kit — TransportStore (buffer + pending sends + engine state, pure GRDB)

**Files:**
- Create: `WatchtowerKit/Sources/WatchtowerKit/CloudKitTransport/TransportStore.swift`
- Test: `WatchtowerKit/Tests/WatchtowerKitTests/TransportStoreTests.swift`

**Interfaces:**
- Consumes: GRDB, `CloudRecord`, `CloudZoneID`, `CloudChangeToken`, `CloudChangeBatch`.
- Produces `public final class TransportStore: Sendable` (wraps a `DatabaseQueue`):
  - `public init(path: String) throws` and `public static func inMemory() throws -> TransportStore`
  - Pending sends: `func enqueueSave(_ records: [CloudRecord]) throws`, `func enqueueDelete(recordNames: [String], zone: CloudZoneID) throws`, `func pendingBatch(limit: Int) throws -> (saves: [CloudRecord], deletes: [(name: String, zone: CloudZoneID)])`, `func clearPending(saveNames: [String], deleteNames: [String]) throws`
  - Incoming buffer: `func bufferChanged(_ records: [CloudRecord]) throws`, `func bufferDeleted(recordNames: [String], zone: CloudZoneID) throws`, `func changes(in zone: CloudZoneID, since token: CloudChangeToken?) throws -> CloudChangeBatch` — same latest-event-wins / first-seen-order / stationary-empty-token semantics as `InMemoryCloudTransport` (Plan 1), backed by an `events` table with `AUTOINCREMENT` seq
  - Engine state: `func saveEngineState(_ data: Data) throws`, `func loadEngineState() throws -> Data?`
  - Schema (created in init, `IF NOT EXISTS`): `events(seq INTEGER PRIMARY KEY AUTOINCREMENT, zone TEXT, record_name TEXT, kind TEXT, modified_at REAL, payload BLOB, deleted INTEGER)`, `pending(record_name TEXT, zone TEXT, kind TEXT, modified_at REAL, payload BLOB, deleted INTEGER, PRIMARY KEY(record_name, zone))` (upsert: a later save/delete for the same name replaces the pending row), `engine_state(id INTEGER PRIMARY KEY CHECK (id = 1), data BLOB)`

- [ ] **Step 1: Write the failing tests**

`WatchtowerKit/Tests/WatchtowerKitTests/TransportStoreTests.swift`:

```swift
import XCTest
@testable import WatchtowerKit

final class TransportStoreTests: XCTestCase {
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    private func record(_ name: String, zone: CloudZoneID = .data, payload: String = "{}") -> CloudRecord {
        CloudRecord(recordName: name, zone: zone, kind: "target", modifiedAt: stamp, payload: Data(payload.utf8))
    }

    func testChangesMirrorInMemorySemantics() throws {
        let store = try TransportStore.inMemory()
        try store.bufferChanged([record("target-1"), record("target-2")])
        let first = try store.changes(in: .data, since: nil)
        XCTAssertEqual(first.changed.map(\.recordName), ["target-1", "target-2"])

        try store.bufferChanged([record("target-3")])
        let second = try store.changes(in: .data, since: first.newToken)
        XCTAssertEqual(second.changed.map(\.recordName), ["target-3"])

        let third = try store.changes(in: .data, since: second.newToken)
        XCTAssertTrue(third.changed.isEmpty)
        XCTAssertEqual(third.newToken, second.newToken)
    }

    func testLatestEventWinsIncludingDeleteThenResave() throws {
        let store = try TransportStore.inMemory()
        try store.bufferDeleted(recordNames: ["target-1"], zone: .data)
        try store.bufferChanged([record("target-1", payload: "{\"v\":2}")])
        let batch = try store.changes(in: .data, since: nil)
        XCTAssertEqual(batch.changed.map(\.recordName), ["target-1"])
        XCTAssertEqual(batch.changed[0].payload, Data("{\"v\":2}".utf8))
        XCTAssertTrue(batch.deletedRecordNames.isEmpty)
    }

    func testZonesIsolatedInBuffer() throws {
        let store = try TransportStore.inMemory()
        try store.bufferChanged([record("target-1", zone: .data)])
        try store.bufferChanged([record("action-1", zone: .relay)])
        XCTAssertEqual(try store.changes(in: .relay, since: nil).changed.map(\.recordName), ["action-1"])
        XCTAssertEqual(try store.changes(in: .data, since: nil).changed.map(\.recordName), ["target-1"])
    }

    func testPendingUpsertLatestWriteWins() throws {
        let store = try TransportStore.inMemory()
        try store.enqueueSave([record("target-1", payload: "{\"v\":1}")])
        try store.enqueueSave([record("target-1", payload: "{\"v\":2}")])
        let batch = try store.pendingBatch(limit: 10)
        XCTAssertEqual(batch.saves.count, 1)
        XCTAssertEqual(batch.saves[0].payload, Data("{\"v\":2}".utf8))
        XCTAssertTrue(batch.deletes.isEmpty)
    }

    func testDeleteReplacesPendingSaveForSameName() throws {
        let store = try TransportStore.inMemory()
        try store.enqueueSave([record("target-1")])
        try store.enqueueDelete(recordNames: ["target-1"], zone: .data)
        let batch = try store.pendingBatch(limit: 10)
        XCTAssertTrue(batch.saves.isEmpty)
        XCTAssertEqual(batch.deletes.map(\.name), ["target-1"])
    }

    func testClearPendingRemovesOnlyNamed() throws {
        let store = try TransportStore.inMemory()
        try store.enqueueSave([record("target-1"), record("target-2")])
        try store.clearPending(saveNames: ["target-1"], deleteNames: [])
        XCTAssertEqual(try store.pendingBatch(limit: 10).saves.map(\.recordName), ["target-2"])
    }

    func testEngineStateRoundTrip() throws {
        let store = try TransportStore.inMemory()
        XCTAssertNil(try store.loadEngineState())
        try store.saveEngineState(Data("state-blob".utf8))
        XCTAssertEqual(try store.loadEngineState(), Data("state-blob".utf8))
        try store.saveEngineState(Data("state-blob-2".utf8))
        XCTAssertEqual(try store.loadEngineState(), Data("state-blob-2".utf8))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd WatchtowerKit && swift test 2>&1 | head -15`
Expected: compile failure — `TransportStore` not found.

- [ ] **Step 3: Implement**

`WatchtowerKit/Sources/WatchtowerKit/CloudKitTransport/TransportStore.swift`:

```swift
import Foundation
import GRDB

/// Persistence for the CloudKit adapter: an incoming change buffer (the
/// source of pull-shaped `changes(since:)` tokens — seqs in this store),
/// a pending-send queue, and the opaque CKSyncEngine state blob.
/// Pure GRDB — fully unit-testable without CloudKit.
public final class TransportStore: Sendable {
    private let queue: DatabaseQueue

    public init(path: String) throws {
        queue = try DatabaseQueue(path: path)
        try createSchema()
    }

    private init(queue: DatabaseQueue) throws {
        self.queue = queue
        try createSchema()
    }

    public static func inMemory() throws -> TransportStore {
        try TransportStore(queue: DatabaseQueue())
    }

    private func createSchema() throws {
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS events (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    zone TEXT NOT NULL,
                    record_name TEXT NOT NULL,
                    kind TEXT NOT NULL DEFAULT '',
                    modified_at REAL NOT NULL DEFAULT 0,
                    payload BLOB,
                    deleted INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE IF NOT EXISTS pending (
                    record_name TEXT NOT NULL,
                    zone TEXT NOT NULL,
                    kind TEXT NOT NULL DEFAULT '',
                    modified_at REAL NOT NULL DEFAULT 0,
                    payload BLOB,
                    deleted INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (record_name, zone)
                );
                CREATE TABLE IF NOT EXISTS engine_state (
                    id INTEGER PRIMARY KEY CHECK (id = 1),
                    data BLOB NOT NULL
                );
                """)
        }
    }

    // MARK: - Pending sends

    public func enqueueSave(_ records: [CloudRecord]) throws {
        try queue.write { db in
            for record in records {
                try db.execute(
                    sql: """
                        INSERT INTO pending (record_name, zone, kind, modified_at, payload, deleted)
                        VALUES (?, ?, ?, ?, ?, 0)
                        ON CONFLICT(record_name, zone) DO UPDATE SET
                            kind = excluded.kind,
                            modified_at = excluded.modified_at,
                            payload = excluded.payload,
                            deleted = 0
                        """,
                    arguments: [
                        record.recordName, record.zone.rawValue, record.kind,
                        record.modifiedAt.timeIntervalSince1970, record.payload,
                    ]
                )
            }
        }
    }

    public func enqueueDelete(recordNames: [String], zone: CloudZoneID) throws {
        try queue.write { db in
            for name in recordNames {
                try db.execute(
                    sql: """
                        INSERT INTO pending (record_name, zone, deleted)
                        VALUES (?, ?, 1)
                        ON CONFLICT(record_name, zone) DO UPDATE SET
                            payload = NULL, deleted = 1
                        """,
                    arguments: [name, zone.rawValue]
                )
            }
        }
    }

    public func pendingBatch(limit: Int) throws -> (saves: [CloudRecord], deletes: [(name: String, zone: CloudZoneID)]) {
        try queue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM pending ORDER BY rowid LIMIT ?",
                arguments: [limit]
            )
            var saves: [CloudRecord] = []
            var deletes: [(name: String, zone: CloudZoneID)] = []
            for row in rows {
                guard let zone = CloudZoneID(rawValue: row["zone"]) else { continue }
                if (row["deleted"] as Int64? ?? 0) != 0 {
                    deletes.append((name: row["record_name"], zone: zone))
                } else {
                    saves.append(CloudRecord(
                        recordName: row["record_name"],
                        zone: zone,
                        kind: row["kind"],
                        modifiedAt: Date(timeIntervalSince1970: row["modified_at"] ?? 0),
                        payload: row["payload"] ?? Data()
                    ))
                }
            }
            return (saves, deletes)
        }
    }

    public func clearPending(saveNames: [String], deleteNames: [String]) throws {
        try queue.write { db in
            for name in saveNames {
                try db.execute(sql: "DELETE FROM pending WHERE record_name = ? AND deleted = 0", arguments: [name])
            }
            for name in deleteNames {
                try db.execute(sql: "DELETE FROM pending WHERE record_name = ? AND deleted = 1", arguments: [name])
            }
        }
    }

    // MARK: - Incoming buffer

    public func bufferChanged(_ records: [CloudRecord]) throws {
        try queue.write { db in
            for record in records {
                try db.execute(
                    sql: """
                        INSERT INTO events (zone, record_name, kind, modified_at, payload, deleted)
                        VALUES (?, ?, ?, ?, ?, 0)
                        """,
                    arguments: [
                        record.zone.rawValue, record.recordName, record.kind,
                        record.modifiedAt.timeIntervalSince1970, record.payload,
                    ]
                )
            }
        }
    }

    public func bufferDeleted(recordNames: [String], zone: CloudZoneID) throws {
        try queue.write { db in
            for name in recordNames {
                try db.execute(
                    sql: "INSERT INTO events (zone, record_name, deleted) VALUES (?, ?, 1)",
                    arguments: [zone.rawValue, name]
                )
            }
        }
    }

    public func changes(in zone: CloudZoneID, since token: CloudChangeToken?) throws -> CloudChangeBatch {
        try queue.read { db in
            let floor = token?.value ?? 0
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM events WHERE zone = ? AND seq > ? ORDER BY seq",
                arguments: [zone.rawValue, floor]
            )

            // Latest event per recordName wins, in first-seen order —
            // mirrors InMemoryCloudTransport (semantics frozen in Plan 1).
            var latest: [String: Row] = [:]
            var order: [String] = []
            var maxSeq = floor
            for row in rows {
                let name: String = row["record_name"]
                if latest[name] == nil { order.append(name) }
                latest[name] = row
                maxSeq = max(maxSeq, Int(row["seq"] as Int64? ?? 0))
            }

            var changed: [CloudRecord] = []
            var deleted: [String] = []
            for name in order {
                guard let row = latest[name] else { continue }
                if (row["deleted"] as Int64? ?? 0) != 0 {
                    deleted.append(name)
                } else {
                    changed.append(CloudRecord(
                        recordName: name,
                        zone: zone,
                        kind: row["kind"],
                        modifiedAt: Date(timeIntervalSince1970: row["modified_at"] ?? 0),
                        payload: row["payload"] ?? Data()
                    ))
                }
            }
            return CloudChangeBatch(changed: changed, deletedRecordNames: deleted, newToken: CloudChangeToken(value: maxSeq))
        }
    }

    // MARK: - Engine state

    public func saveEngineState(_ data: Data) throws {
        try queue.write { db in
            try db.execute(
                sql: "INSERT INTO engine_state (id, data) VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET data = excluded.data",
                arguments: [data]
            )
        }
    }

    public func loadEngineState() throws -> Data? {
        try queue.read { db in
            try Data.fetchOne(db, sql: "SELECT data FROM engine_state WHERE id = 1")
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd WatchtowerKit && swift test 2>&1 | tail -3`
Expected: PASS (36 tests: 29 + 7 new).

- [ ] **Step 5: Lint and commit**

Run: `cd WatchtowerKit && swiftlint lint --strict` — 0 violations.

```bash
git add WatchtowerKit
git commit -m "feat(kit): TransportStore — change buffer, pending sends, engine state (pure GRDB)"
```

---

### Task 3: Kit — CloudKitTransport actor (CKSyncEngine wiring, compile-gated)

**Files:**
- Create: `WatchtowerKit/Sources/WatchtowerKit/CloudKitTransport/CloudKitTransport.swift`
- Test: `WatchtowerKit/Tests/WatchtowerKitTests/CloudKitTransportMappingTests.swift`

**Interfaces:**
- Consumes: `TransportStore` (Task 2), `WatchtowerCloud.containerID` (Task 1), CloudKit.
- Produces:
  - `public enum CloudAvailability: Equatable, Sendable` — `.available`, `.noAccount`, `.restricted`, `.unavailable(String)`.
  - `public actor CloudKitTransport: CloudSyncTransport` —
    `public init(store: TransportStore, containerID: String = WatchtowerCloud.containerID)`;
    seam methods `save`/`delete` enqueue into the store and nudge the engine; `changes(in:since:)` reads the store buffer;
    `public func start() async` (create container/engine, ensure zones exist, load state);
    `public func pull() async throws` (manual `fetchChanges()` — poll loops call this; push wake calls it implicitly when entitlements land);
    `public func availability() async -> CloudAvailability` (checks `CKContainer.accountStatus()`, maps thrown CK errors to `.unavailable(message)` — NEVER crashes on unsigned dev builds).
  - Static pure mapper (unit-testable without CloudKit): `static func ckRecord(from record: CloudRecord, in zoneID: CKRecordZone.ID) -> CKRecord` (fields: `payload` via `encryptedValues["payload"]`, plaintext `kind`, `modifiedAt`) and `static func cloudRecord(from ckRecord: CKRecord) -> CloudRecord?` (nil when `payload` missing; zone from the record's zoneID name).

This task is the **spike** from carry-over note 1: the engine's push shape is absorbed by the store buffer, consumer tokens stay local seqs. CloudKit code cannot run in unit tests — the test target covers only the pure `ckRecord`/`cloudRecord` mappers; the rest is compile-gated + reviewed. Delegate skeleton:

- `handleEvent`: `.stateUpdate` → `store.saveEngineState`; `.fetchedRecordZoneChanges` → `store.bufferChanged`/`bufferDeleted` per modification/deletion; `.sentRecordZoneChanges` → `store.clearPending` for successes, failed saves stay pending (engine retries), failed deletes with `.unknownItem` → `clearPending` (idempotent-delete contract, Task 1).
- `nextRecordZoneChangeBatch`: read `store.pendingBatch(limit: 200)` → build `CKSyncEngine.RecordZoneChangeBatch` (`recordsToSave` via the mapper, `recordIDsToDelete`).
- Zone setup in `start()`: save `CKRecordZone(zoneName: CloudZoneID.data.rawValue)` and `.relay` equivalents via the engine's pending database changes.

The exact CKSyncEngine API spellings (event case names, batch initializer) must be finished compile-driven against the macOS 14 SDK — structure and store calls above are the requirements; if an API mismatch forces a structural change (not a spelling change), report BLOCKED rather than redesigning.

- [ ] **Step 1: Write the failing mapper tests**

`WatchtowerKit/Tests/WatchtowerKitTests/CloudKitTransportMappingTests.swift`:

```swift
import XCTest
import CloudKit
@testable import WatchtowerKit

final class CloudKitTransportMappingTests: XCTestCase {
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    func testCloudRecordToCKRecordAndBack() {
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneID.data.rawValue, ownerName: CKCurrentUserDefaultName)
        let original = CloudRecord(
            recordName: "target-9",
            zone: .data,
            kind: "target",
            modifiedAt: stamp,
            payload: Data("{\"id\":9}".utf8)
        )
        let ck = CloudKitTransport.ckRecord(from: original, in: zoneID)
        XCTAssertEqual(ck.recordID.recordName, "target-9")
        XCTAssertEqual(ck.recordType, "WatchtowerRecord")

        let roundTripped = CloudKitTransport.cloudRecord(from: ck)
        XCTAssertEqual(roundTripped, original)
    }

    func testCKRecordWithoutPayloadMapsToNil() {
        let zoneID = CKRecordZone.ID(zoneName: CloudZoneID.relay.rawValue, ownerName: CKCurrentUserDefaultName)
        let ck = CKRecord(recordType: "WatchtowerRecord", recordID: CKRecord.ID(recordName: "x", zoneID: zoneID))
        XCTAssertNil(CloudKitTransport.cloudRecord(from: ck))
    }

    func testUnknownZoneNameMapsToNil() {
        let zoneID = CKRecordZone.ID(zoneName: "SomeOtherZone", ownerName: CKCurrentUserDefaultName)
        let ck = CKRecord(recordType: "WatchtowerRecord", recordID: CKRecord.ID(recordName: "x", zoneID: zoneID))
        ck.encryptedValues["payload"] = Data("{}".utf8)
        ck["kind"] = "target"
        ck["modifiedAt"] = Date(timeIntervalSince1970: 0)
        XCTAssertNil(CloudKitTransport.cloudRecord(from: ck))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd WatchtowerKit && swift test 2>&1 | head -15`
Expected: compile failure — `CloudKitTransport` not found.

- [ ] **Step 3: Implement the actor**

Structure (finish API spellings compile-driven; store interactions and semantics are fixed requirements):

```swift
import CloudKit
import Foundation

/// CloudKit adapter for the CloudSyncTransport seam, built on CKSyncEngine.
/// Push-shaped engine events land in the TransportStore buffer; the seam's
/// pull-shaped changes(since:) reads that buffer, so consumer tokens are
/// local seqs and CKServerChangeToken/engine state never leak (design
/// decision 1 in the Plan 2 header).
public enum CloudAvailability: Equatable, Sendable {
    case available
    case noAccount
    case restricted
    case unavailable(String)
}

public actor CloudKitTransport: CloudSyncTransport {
    static let recordType = "WatchtowerRecord"

    private let store: TransportStore
    private let containerID: String
    private var engine: CKSyncEngine?
    private var delegateBox: DelegateBox?

    public init(store: TransportStore, containerID: String = WatchtowerCloud.containerID) {
        self.store = store
        self.containerID = containerID
    }

    // MARK: - CloudSyncTransport

    public func save(_ records: [CloudRecord]) async throws {
        try store.enqueueSave(records)
        nudgeEngine()
    }

    public func delete(recordNames: [String], in zone: CloudZoneID) async throws {
        try store.enqueueDelete(recordNames: recordNames, zone: zone)
        nudgeEngine()
    }

    public func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
        try store.changes(in: zone, since: token)
    }

    // MARK: - Lifecycle

    public func start() async { /* build CKContainer/engine with stored state
        serialization, register zones (CloudZoneID rawValues) via pending
        database changes; failures recorded, surfaced via availability() */ }

    public func pull() async throws { try await engine?.fetchChanges() }

    public func availability() async -> CloudAvailability { /* CKContainer
        accountStatus → .available/.noAccount/.restricted; thrown errors →
        .unavailable(localizedDescription). Never crash. */ }

    private func nudgeEngine() { /* mark pending record-zone changes on the
        engine so nextRecordZoneChangeBatch gets called; no-op when engine
        is nil (unavailable) — records wait in the store. */ }

    // MARK: - Mapping (pure, unit-tested)

    static func ckRecord(from record: CloudRecord, in zoneID: CKRecordZone.ID) -> CKRecord {
        let id = CKRecord.ID(recordName: record.recordName, zoneID: zoneID)
        let ck = CKRecord(recordType: Self.recordType, recordID: id)
        ck.encryptedValues["payload"] = record.payload
        ck["kind"] = record.kind
        ck["modifiedAt"] = record.modifiedAt
        return ck
    }

    static func cloudRecord(from ck: CKRecord) -> CloudRecord? {
        guard let payload = ck.encryptedValues["payload"] as? Data,
              let zone = CloudZoneID(rawValue: ck.recordID.zoneID.zoneName) else { return nil }
        return CloudRecord(
            recordName: ck.recordID.recordName,
            zone: zone,
            kind: (ck["kind"] as? String) ?? "",
            modifiedAt: (ck["modifiedAt"] as? Date) ?? Date(timeIntervalSince1970: 0),
            payload: payload
        )
    }
}
```

Plus the delegate (`DelegateBox: NSObject, CKSyncEngineDelegate`) implementing `handleEvent`/`nextRecordZoneChangeBatch` per the skeleton in the task intro, forwarding into the actor.

- [ ] **Step 4: Build and run tests**

Run: `cd WatchtowerKit && swift build && swift test 2>&1 | tail -3`
Expected: build succeeds (full CKSyncEngine wiring compiles), PASS (39 tests: 36 + 3 new).

- [ ] **Step 5: Verify the desktop still builds, lint, commit**

Run: `cd WatchtowerDesktop && swift build 2>&1 | tail -2 && cd ../WatchtowerKit && swiftlint lint --strict`
Expected: `Build complete!`, 0 violations.

```bash
git add WatchtowerKit
git commit -m "feat(kit): CloudKitTransport — CKSyncEngine adapter over TransportStore"
```

---

### Task 4: Desktop — HubSyncState sidecar + slice diffing core

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/MobileHub/HubSyncState.swift`
- Create: `WatchtowerDesktop/Sources/Services/MobileHub/SliceDiff.swift`
- Test: `WatchtowerDesktop/Tests/MobileHub/SliceDiffTests.swift`

**Interfaces:**
- Consumes: GRDB, `SliceKind`/`SliceRecord`/`RowPayloadCoder` (Kit, via existing re-export).
- Produces:
  - `final class HubSyncState: Sendable` — `init(path: String) throws`, `static func inMemory() throws -> HubSyncState`; table `slice_state(record_name TEXT PRIMARY KEY, payload_hash TEXT, pushed_at REAL)`; `func hashes(forKind kind: SliceKind) throws -> [String: String]` (recordName → hash, filtered by `record_name LIKE '<kind>-%'`), `func setHash(_ hash: String, for recordName: String) throws`, `func removeHashes(_ recordNames: [String]) throws`.
  - `enum SliceDiff` — `struct Result: Equatable { let upserts: [SliceRecord]; let deletions: [String]; let skipped: [String] }`; `static func compute(kind: SliceKind, rows: [(id: String, row: Row)], knownHashes: [String: String], now: Date) -> Result`:
    - payload via `RowPayloadCoder.payload(from:)`; a throwing row goes to `skipped` (recordName), never fails the whole diff (**design decision 2**)
    - hash = SHA-256 hex of the payload (`CryptoKit.SHA256`)
    - upsert when recordName absent from `knownHashes` or hash differs; deletion = knownHashes keys not present in `rows`
    - deterministic order: upserts in `rows` order, deletions sorted

- [ ] **Step 1: Write the failing tests**

`WatchtowerDesktop/Tests/MobileHub/SliceDiffTests.swift`:

```swift
import XCTest
import GRDB
@testable import WatchtowerDesktop
@testable import WatchtowerKit

final class SliceDiffTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testNewRowsBecomeUpserts() throws {
        let result = SliceDiff.compute(
            kind: .target,
            rows: [(id: "1", row: Row(["id": 1, "text": "a"]))],
            knownHashes: [:],
            now: now
        )
        XCTAssertEqual(result.upserts.map(\.recordName), ["target-1"])
        XCTAssertTrue(result.deletions.isEmpty)
        XCTAssertTrue(result.skipped.isEmpty)
    }

    func testUnchangedRowProducesNothing() throws {
        let row = Row(["id": 1, "text": "a"])
        let first = SliceDiff.compute(kind: .target, rows: [(id: "1", row: row)], knownHashes: [:], now: now)
        let payload = first.upserts[0].payload
        let hash = SliceDiff.hashHex(payload)

        let second = SliceDiff.compute(
            kind: .target,
            rows: [(id: "1", row: row)],
            knownHashes: ["target-1": hash],
            now: now
        )
        XCTAssertTrue(second.upserts.isEmpty)
        XCTAssertTrue(second.deletions.isEmpty)
    }

    func testChangedRowProducesUpsert() throws {
        let result = SliceDiff.compute(
            kind: .target,
            rows: [(id: "1", row: Row(["id": 1, "text": "b"]))],
            knownHashes: ["target-1": "stale-hash"],
            now: now
        )
        XCTAssertEqual(result.upserts.map(\.recordName), ["target-1"])
    }

    func testVanishedRowBecomesDeletion() throws {
        let result = SliceDiff.compute(
            kind: .target,
            rows: [],
            knownHashes: ["target-1": "h1", "target-2": "h2"],
            now: now
        )
        XCTAssertEqual(result.deletions, ["target-1", "target-2"])
        XCTAssertTrue(result.upserts.isEmpty)
    }

    func testNonFiniteDoubleRowIsSkippedNotFatal() throws {
        let bad = Row(["id": 1, "score": Double.infinity])
        let good = Row(["id": 2, "text": "ok"])
        let result = SliceDiff.compute(
            kind: .target,
            rows: [(id: "1", row: bad), (id: "2", row: good)],
            knownHashes: [:],
            now: now
        )
        XCTAssertEqual(result.skipped, ["target-1"])
        XCTAssertEqual(result.upserts.map(\.recordName), ["target-2"])
    }

    func testHubSyncStateRoundTrip() throws {
        let state = try HubSyncState.inMemory()
        try state.setHash("h1", for: "target-1")
        try state.setHash("h2", for: "inbox_item-5")
        XCTAssertEqual(try state.hashes(forKind: .target), ["target-1": "h1"])
        try state.removeHashes(["target-1"])
        XCTAssertEqual(try state.hashes(forKind: .target), [:])
        XCTAssertEqual(try state.hashes(forKind: .inboxItem), ["inbox_item-5": "h2"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd WatchtowerDesktop && swift build --build-tests 2>&1 | head -10`
Expected: compile failure — `SliceDiff`, `HubSyncState` not found.

- [ ] **Step 3: Implement** (full code; `SliceDiff.hashHex(_ data: Data) -> String` exposed internal for the test; use `import CryptoKit`)

`HubSyncState` mirrors the `TransportStore` GRDB pattern (DatabaseQueue, `CREATE TABLE IF NOT EXISTS`, `inMemory()`); `SliceDiff.compute` is a pure function per the interface block.

- [ ] **Step 4: Run the new tests, then the full desktop suite**

Run: `cd WatchtowerDesktop && swift test --filter SliceDiffTests 2>&1 | tail -3`, then `swift test 2>&1 | grep "Executed"`
Expected: 6 new tests pass; full suite `Executed 920 tests, with 0 failures` (914 + 6).

- [ ] **Step 5: Lint and commit**

```bash
cd WatchtowerDesktop && swiftlint lint --strict
git add WatchtowerDesktop
git commit -m "feat(desktop): hub sync-state sidecar and pure slice diffing"
```

---

### Task 5: Desktop — SlicePublisher (windows + poll loop)

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/MobileHub/SlicePublisher.swift`
- Test: `WatchtowerDesktop/Tests/MobileHub/SlicePublisherTests.swift`

**Interfaces:**
- Consumes: `SliceDiff`/`HubSyncState` (Task 4), `CloudSyncTransport` + `CloudRecordFactory` (Kit), `DatabasePool` (main DB, read-only), `TestDatabase` helper (existing, `WatchtowerDesktop/Tests/Helpers/TestDatabase.swift`) and `InMemoryCloudTransport` in tests.
- Produces `final class SlicePublisher: Sendable`:
  - `init(dbPool: DatabasePool, state: HubSyncState, transport: any CloudSyncTransport)`
  - `func publishOnce() async throws -> (pushed: Int, deleted: Int, skipped: [String])` — for each `SliceKind`: fetch rows with the v1 window SQL below (`Row.fetchAll`), run `SliceDiff.compute`, `transport.save` upserts (as `CloudRecordFactory.record(for:)`), `transport.delete` deletions, update `HubSyncState`; skipped recordNames aggregated and logged once per cycle via `os.Logger` (never silent — final-review "no silent caps" rule)
  - `func start(interval: Duration = .seconds(60))` / `func stop()` — `Task { while !Task.isCancelled { try? await publishOnce(); sleep } }`, the `DigestWatcher` pattern (poll, because ValueObservation can't see daemon writes — design decision 5)
  - `static let sliceSQL: [SliceKind: String]` — the v1 window per kind (single source of truth):
    - `.briefing`: `SELECT * FROM briefings ORDER BY id DESC LIMIT 30`
    - `.inboxItem`: `SELECT * FROM inbox_items WHERE status != 'archived' ORDER BY id DESC LIMIT 200`
    - `.target`: `SELECT * FROM targets WHERE status != 'archived' ORDER BY id DESC LIMIT 300`
    - `.track`: `SELECT * FROM tracks WHERE dismissed = 0 ORDER BY id DESC LIMIT 200`
    - `.digest`: `SELECT * FROM digests ORDER BY id DESC LIMIT 50`
    - `.digestTopic`: `SELECT * FROM digest_topics WHERE digest_id IN (SELECT id FROM digests ORDER BY id DESC LIMIT 50)`
    - `.calendarEvent`: `SELECT * FROM calendar_events WHERE start_time >= datetime('now', '-1 day') AND start_time <= datetime('now', '+14 days')`
    - `.personCard`: `SELECT * FROM people_cards ORDER BY id DESC LIMIT 100`
  - **Before writing tests, verify each SQL against the real schema** (`internal/db/schema.sql`) — column names (`status`, `dismissed`, `start_time`, table names) must match; adjust the SQL (not the schema) where the schema differs, and note adjustments in the report. Rows fetch id via `String(row["id"] as Int64? ?? 0)`.

- [ ] **Step 1: Write the failing tests** — using `TestDatabase` fixtures (existing helper) + `InMemoryCloudTransport`:

```swift
// SlicePublisherTests.swift — core cases:
// 1. publishOnce on a fixture DB with 2 targets + 1 inbox item pushes 3 records
//    (assert via transport.changes(in: .data, since: nil) recordNames).
// 2. Second publishOnce with no DB change pushes nothing (hash short-circuit).
// 3. Deleting a target row from the fixture DB → next publishOnce emits
//    transport delete; state hash removed.
// 4. A row updated in the DB → exactly that record re-pushed.
// (Write them as real XCTest code against TestDatabase — follow the existing
// desktop test style for fixture setup; assert counts AND recordNames.)
```

- [ ] **Step 2: RED** — `swift build --build-tests` fails on missing `SlicePublisher`.

- [ ] **Step 3: Implement** per the interface block (full code).

- [ ] **Step 4: GREEN** — `swift test --filter SlicePublisherTests` passes (4 tests); full suite `Executed 924 tests`.

- [ ] **Step 5: Lint and commit**

```bash
cd WatchtowerDesktop && swiftlint lint --strict
git add WatchtowerDesktop
git commit -m "feat(desktop): SlicePublisher — windowed slice push with hash diffing"
```

---

### Task 6: Desktop — RelayProcessor: actions

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/MobileHub/RelayProcessor.swift`
- Test: `WatchtowerDesktop/Tests/MobileHub/RelayProcessorActionTests.swift`

**Interfaces:**
- Consumes: `CloudSyncTransport`, relay payloads + `RelayCoder` + `CloudRecordFactory` (Kit), existing Queries (`TargetQueries`, `InboxQueries`, `TrackQueries`), `DatabasePool` (write), `HubSyncState`-style sidecar table for processed-set + relay token.
- Produces `final class RelayProcessor: Sendable` (chat added in Task 7):
  - `init(dbPool: DatabasePool, transport: any CloudSyncTransport, sidecar: HubSyncState, aiService: any AIServiceProtocol, now: @escaping @Sendable () -> Date = Date.init)`
  - `func processOnce() async throws -> Int` — `transport.changes(in: .relay, since: storedToken)`; for each changed record with `kind == RelayRecordKind.action.rawValue`: decode `ActionRequestPayload`; skip when `status != .pending` (echo of our own status write-back) or recordName in processed-set (**duplicate-delivery idempotency**, spec Section 4); apply in one `dbPool.write` transaction; write back `status: applied` (or `.failed` + `errorMessage` from the thrown error) via `transport.save(CloudRecordFactory.record(for:))`; mark processed; persist the new token in the sidecar (`hub_meta(key PRIMARY KEY, value)` table — add to `HubSyncState` here)
  - Action → Query mapping (exact signatures verified against the codebase):
    - `.targetDone` → `TargetQueries.updateStatus(db, id: entityInt, status: "done")`
    - `.targetSnooze` → `TargetQueries.snooze(db, id: entityInt, until: dateParam)` (`params["snooze_until"]` ISO8601 string → `Date`; unparseable → `.failed`)
    - `.inboxResolve` → `InboxQueries.resolve(db, id: entityInt, reason: "Resolved from mobile")`
    - `.inboxDismiss` → `InboxQueries.dismiss(db, id: entityInt)`
    - `.inboxSnooze` → `InboxQueries.snooze(db, id: entityInt, until: stringParam)` (String, NOT Date — the two snoozes differ)
    - `.taskCreate` → `TargetQueries.create(db, text: textParam, periodStart: todayYYYYMMDD, periodEnd: todayYYYYMMDD)` (other params default)
    - `.trackRead` → `TrackQueries.markRead(db, id: entityInt)`
    - missing/non-int `entityID` where required, unknown id (query throws or affects 0 rows) → `.failed` with message; the cycle continues to the next action (one bad action never stops the queue)

- [ ] **Step 1: Failing tests** (`RelayProcessorActionTests.swift`, fixture DB + `InMemoryCloudTransport`; `MockClaudeService` from `Tests/Helpers` satisfies the aiService param):
  1. `inbox_resolve` action → inbox item status becomes resolved in DB; a status record with `status: applied` lands in `.relay`; second `processOnce` (same record still in changes) does not re-apply (processed-set).
  2. `target_snooze` with ISO `snooze_until` → `TargetQueries`-visible snooze; `applied`.
  3. Action for a nonexistent id → `.failed` with non-empty `errorMessage`; a following valid action in the same batch still applies.
  4. `task_create` with `params["text"]` → a new target row exists; `applied`.
  5. Token persistence: after `processOnce`, a new action buffered → second `processOnce` sees ONLY the new one (assert apply-count == 1).

- [ ] **Step 2: RED.** — build-tests fails on `RelayProcessor`.

- [ ] **Step 3: Implement** per interface block (full code).

- [ ] **Step 4: GREEN** — 5 new tests; full suite `Executed 929 tests`.

- [ ] **Step 5: Lint and commit**

```bash
cd WatchtowerDesktop && swiftlint lint --strict
git add WatchtowerDesktop
git commit -m "feat(desktop): RelayProcessor actions — idempotent apply via existing Queries"
```

---

### Task 7: Desktop — RelayProcessor: chat

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/MobileHub/RelayProcessor.swift`
- Modify (add table use): `WatchtowerDesktop/Sources/Services/MobileHub/HubSyncState.swift` (`chat_sessions(mobile_session_id TEXT PRIMARY KEY, cli_session_id TEXT)`)
- Test: `WatchtowerDesktop/Tests/MobileHub/RelayProcessorChatTests.swift`

**Interfaces:**
- Consumes: `AIServiceProtocol.stream(...)` (`StreamEvent`: `.text`, `.turnComplete`, `.sessionID`, `.done`), `ChatViewModel.buildSystemPrompt(dbPool:)` (nonisolated static — reuse as-is), `MockClaudeService` (existing test helper).
- Produces, inside `RelayProcessor`:
  - `processOnce` also handles `kind == RelayRecordKind.chatMessage.rawValue`: decode `ChatMessagePayload`, skip if processed; look up `cli_session_id` for `payload.sessionID` (nil on first turn → send `buildSystemPrompt`); run the stream; **flush a `ChatChunkPayload` at most every 1.5 s** (accumulate `.text` deltas; each flush = next `seq`, `done: false`); on `.sessionID(id)` persist the mapping; on completion flush the final chunk `done: true` (remaining text; empty text is fine); on stream error → final chunk `done: true` with `text: "⚠️ " + error.localizedDescription`; mark processed. Chunks/statuses go through `transport.save`.
  - Flush cadence injectable for tests: `init` gains `chunkInterval: Duration = .milliseconds(1500)`.

- [ ] **Step 1: Failing tests** (`RelayProcessorChatTests.swift`, MockClaudeService + InMemory transport, `chunkInterval: .milliseconds(10)`):
  1. Chat message → chunks appear in `.relay` with monotonic `seq`, final chunk `done: true`; concatenated chunk text equals the mock's streamed text.
  2. `.sessionID` from the stream persisted: a second message in the same mobile session passes that `sessionID` to the mock (MockClaudeService records call args — extend the mock minimally if needed; note it in the report).
  3. First turn sends a non-nil systemPrompt; second turn sends nil.
  4. Stream error → final `done: true` chunk with the error text; message marked processed (no retry loop).

- [ ] **Step 2: RED.**

- [ ] **Step 3: Implement.**

- [ ] **Step 4: GREEN** — 4 new tests; full suite `Executed 933 tests`.

- [ ] **Step 5: Lint and commit**

```bash
cd WatchtowerDesktop && swiftlint lint --strict
git add WatchtowerDesktop
git commit -m "feat(desktop): RelayProcessor chat — relay streaming via chunk records"
```

---

### Task 8: Desktop — HeartbeatPublisher, MobileHubService, Settings tab, AppState wiring

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/MobileHub/MobileHubService.swift` (includes `HeartbeatPublisher`)
- Create: `WatchtowerDesktop/Sources/Views/Settings/MobileSettings.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Settings/SettingsView.swift` (add tab)
- Modify: `WatchtowerDesktop/Sources/App/AppState.swift` (create/start service when enabled)
- Modify: `docs/app-guide.md` (new Settings tab section)
- Test: `WatchtowerDesktop/Tests/MobileHub/MobileHubServiceTests.swift`

**Interfaces:**
- Consumes: everything above; `@AppStorage` pattern from `NotificationSettings.swift`; `DigestWatcher` start/stop pattern; `AppState.initialize()`.
- Produces:
  - `@MainActor @Observable final class MobileHubService` — `init(dbPool: DatabasePool, transport: any CloudSyncTransport, publisher: SlicePublisher, processor: RelayProcessor)`; `private(set) var status: HubStatus` (`enum HubStatus: Equatable { case off, starting, running, unavailable(String) }`); `func start() async` (transport `start()` + `availability()` gate → `.unavailable(reason)` stays harmless on unsigned dev builds; then `publisher.start()`, relay loop, heartbeat loop); `func stop()` (cancel all).
  - Heartbeat: Task-loop every 300 s writing `HeartbeatPayload(updatedAt: now, appVersion: Bundle.main version)` via `CloudRecordFactory` + `transport.save` (spec Section 2).
  - Relay adaptive poll: 30 s idle; 3 s when the last relay activity (any processed record or chat stream in flight) is < 5 min old — chat latency without push entitlements.
  - Hygiene pass once per day inside the relay loop: `transport.delete` of action records older than 7 days and chat records older than 30 (list obtained from a full `changes(in: .relay, since: nil)` scan; guarded by a `hub_meta` last-run stamp).
  - `MobileSettings` tab: `@AppStorage("mobileSyncEnabled") private var mobileSyncEnabled = false`; `Toggle("Enable Mobile Sync", ...)`; status line rendering `HubStatus` (running / unavailable reason / off); short explanatory footer. New `.tabItem { Label("Mobile", systemImage: "iphone") }` in `SettingsView`.
  - `AppState`: after `initialize()` succeeds and when `UserDefaults.standard.bool(forKey: "mobileSyncEnabled")`, build the chain (TransportStore at Application Support path → CloudKitTransport → HubSyncState → SlicePublisher/RelayProcessor with `WatchtowerAIService()` → MobileHubService) and `start()`; expose `var mobileHub: MobileHubService?` for the Settings status line; toggle changes start/stop the service live (observe via `.onChange` in `MobileSettings`).
- Tests (`MobileHubServiceTests`, InMemory transport + fixture DB): 1) `start()` flips status to `.running` and a heartbeat record appears; 2) `stop()` cancels loops (status `.off`, no new heartbeat after interval); 3) with a transport whose `availability()` returns `.noAccount` (tiny stub conforming to the transport + availability seams — add a `HubTransport` protocol combining them so the stub is trivial), status becomes `.unavailable` and no loops start. Heartbeat/poll intervals injectable.

- [ ] **Step 1: Failing tests** per above (3 tests).
- [ ] **Step 2: RED.**
- [ ] **Step 3: Implement** (service, settings tab, AppState wiring, app-guide.md update).
- [ ] **Step 4: GREEN** — full suite `Executed 936 tests`; `swift build` clean.
- [ ] **Step 5: Lint both packages, run the FULL verification** (`cd WatchtowerKit && swift test && cd ../WatchtowerDesktop && swift test`), commit:

```bash
git add WatchtowerDesktop docs/app-guide.md
git commit -m "feat(desktop): MobileHubService — heartbeat, adaptive relay poll, Settings tab"
```

---

## Out of scope for Plan 2 (explicit)

- CloudKit entitlements/signing/provisioning — packaging/release task; the hub degrades to `.unavailable` on dev builds by design. Manual E2E with a signed build happens then.
- Push-notification wake (silent push) — free upgrade once entitlements land (CKSyncEngine handles it; poll stays as safety net).
- The iOS app (Plans 3–5).
