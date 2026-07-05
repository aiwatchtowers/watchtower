# Watchtower Mobile — Plan 1: WatchtowerKit Foundation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create the shared `WatchtowerKit` SPM package: slice models moved out of the desktop app, the CloudKit-agnostic payload format, the relay protocol types, and the `CloudSyncTransport` seam with an in-memory fake.

**Architecture:** `WatchtowerKit` is a new SPM library (macOS 14+ / iOS 17+) at the repo root, consumed by `WatchtowerDesktop` via a local path dependency. Sync payloads are **row-column JSON dicts** (serialize GRDB `Row` columns), not Codable models — models keep their `init(row:)` and stay untouched by the sync layer. All CloudKit specifics stay behind the `CloudSyncTransport` protocol; this plan ships only the in-memory fake (the real CKSyncEngine transport is Plan 2).

**Tech Stack:** Swift 5.10, SPM, GRDB.swift 7.x, XCTest.

**Spec:** `docs/superpowers/specs/2026-07-05-mobile-app-design.md`

**Follow-up plans (not here):** Plan 2 desktop hub (CKSyncEngine, sidecar sync state, relay processing, heartbeat, Settings), Plan 3 iOS skeleton + replica, Plan 4 mobile actions/chat/notifications, Plan 5 mobile agent fallback.

## Global Constraints

- Work in worktree `/Users/user/PhpstormProjects/watchtower/.claude/worktrees/mobile-app`, branch `feature/mobile-app`. All commands run from the worktree root unless a `cd` is shown.
- Platforms: `.macOS(.v14)`, `.iOS(.v17)`. Swift tools version 5.10. GRDB pinned `from: "7.0.0"` (same as desktop).
- The desktop app's behavior must not change: after every task `cd WatchtowerDesktop && swift test` passes (≈490 tests).
- No CloudKit imports anywhere in this plan. The only Apple frameworks used are Foundation and GRDB.
- Wire-format contracts are frozen by tests: snake_case JSON keys, dates as Unix seconds, `sortedKeys` output for deterministic fixtures.
- New public API lives in `WatchtowerKit`; desktop sees it via one `@_exported import` file.

---

### Task 1: Scaffold WatchtowerKit and wire the desktop dependency

**Files:**
- Create: `WatchtowerKit/Package.swift`
- Create: `WatchtowerKit/Sources/WatchtowerKit/WatchtowerKitInfo.swift`
- Create: `WatchtowerKit/Tests/WatchtowerKitTests/WatchtowerKitInfoTests.swift`
- Create: `WatchtowerDesktop/Sources/App/KitReexport.swift`
- Modify: `WatchtowerDesktop/Package.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: the `WatchtowerKit` module importable from `WatchtowerDesktop` (re-exported), so later tasks can add types without touching desktop imports.

- [ ] **Step 1: Verify the desktop baseline is green**

Run: `cd WatchtowerDesktop && swift test 2>&1 | tail -3`
Expected: `Test Suite 'All tests' passed` (≈490 tests). If it fails, stop and report — do not proceed on a broken baseline.

- [ ] **Step 2: Create the package manifest and a version marker**

`WatchtowerKit/Package.swift`:

```swift
// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "WatchtowerKit",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "WatchtowerKit", targets: ["WatchtowerKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "WatchtowerKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "WatchtowerKitTests",
            dependencies: ["WatchtowerKit"]
        ),
    ]
)
```

`WatchtowerKit/Sources/WatchtowerKit/WatchtowerKitInfo.swift`:

```swift
public enum WatchtowerKitInfo {
    public static let version = "0.1.0"
}
```

`WatchtowerKit/Tests/WatchtowerKitTests/WatchtowerKitInfoTests.swift`:

```swift
import XCTest
@testable import WatchtowerKit

final class WatchtowerKitInfoTests: XCTestCase {
    func testVersionIsSet() {
        XCTAssertFalse(WatchtowerKitInfo.version.isEmpty)
    }
}
```

- [ ] **Step 3: Build and test the new package**

Run: `cd WatchtowerKit && swift build && swift test 2>&1 | tail -3`
Expected: build succeeds, `Test Suite 'All tests' passed` (1 test).

- [ ] **Step 4: Wire the desktop dependency and re-export**

In `WatchtowerDesktop/Package.swift`, add to `dependencies:`:

```swift
        .package(path: "../WatchtowerKit"),
```

and to the executable target's `dependencies:`:

```swift
                .product(name: "WatchtowerKit", package: "WatchtowerKit"),
```

`WatchtowerDesktop/Sources/App/KitReexport.swift`:

```swift
// Re-export so the whole desktop module sees WatchtowerKit types
// (models migrated there) without per-file imports.
@_exported import WatchtowerKit
```

- [ ] **Step 5: Verify the desktop still builds and tests pass**

Run: `cd WatchtowerDesktop && swift build && swift test 2>&1 | tail -3`
Expected: PASS, same test count as Step 1.

- [ ] **Step 6: Commit**

```bash
git add WatchtowerKit WatchtowerDesktop/Package.swift WatchtowerDesktop/Sources/App/KitReexport.swift
git commit -m "feat(kit): scaffold WatchtowerKit shared package, wire desktop dependency"
```

---

### Task 2: Move the slice models into WatchtowerKit

**Files:**
- Move (git mv) from `WatchtowerDesktop/Sources/Models/` to `WatchtowerKit/Sources/WatchtowerKit/Models/`:
  `Briefing.swift`, `InboxItem.swift`, `Target.swift`, `Track.swift`, `Digest.swift`, `DigestTopic.swift`, `RunningSummary.swift`, `CalendarEvent.swift`, `PeopleCard.swift`
- Modify: the moved files (access-level pass: `public`)
- Possibly modify: files under `WatchtowerDesktop/Tests/` (add `@testable import WatchtowerKit` where fixtures use internal memberwise inits)

**Interfaces:**
- Consumes: Task 1 (package + re-export).
- Produces: the nine slice model types as `public` API of `WatchtowerKit` (unchanged names: `Briefing`, `InboxItem`, `Target`, `Track`, `Digest`, `DigestTopic`, `RunningSummary`, `CalendarEvent`, `PeopleCard`), each still conforming to `FetchableRecord` with `init(row:)`.

- [ ] **Step 1: Move the files**

```bash
mkdir -p WatchtowerKit/Sources/WatchtowerKit/Models
for f in Briefing InboxItem Target Track Digest DigestTopic RunningSummary CalendarEvent PeopleCard; do
  git mv "WatchtowerDesktop/Sources/Models/$f.swift" "WatchtowerKit/Sources/WatchtowerKit/Models/$f.swift"
done
```

- [ ] **Step 2: First-pass publicize with sed, then finish by hand**

```bash
cd WatchtowerKit/Sources/WatchtowerKit/Models
sed -i '' \
  -e 's/^struct /public struct /' \
  -e 's/^enum /public enum /' \
  -e 's/^extension /public extension /' \
  -e 's/^    struct /    public struct /' \
  -e 's/^    enum /    public enum /' \
  -e 's/^    let /    public let /' \
  -e 's/^    var /    public var /' \
  -e 's/^    init(/    public init(/' \
  -e 's/^    static /    public static /' \
  -e 's/^    func /    public func /' \
  *.swift
```

The sed pass is intentionally rough. Hand-finish rules:
- Nested-type members (double-indented `let`/`var`/`init`/`func`/`static`) also need `public` — sed above only catches top-level and one nesting level; fix the rest guided by compile errors in Step 3.
- `public extension` members must NOT also carry `public` (Swift warning) — if sed produced both, drop the inner one.
- Protocol conformance requirements (`init(row:)`, `==`, `encode(to:)`) must be `public`.
- Do NOT add `public` to `private`/`fileprivate` members or to `CodingKeys` enums used only internally by a `Decodable` init (internal is fine there — they are referenced only within the file).

- [ ] **Step 3: Compile WatchtowerKit, fix remaining access errors**

Run: `cd WatchtowerKit && swift build 2>&1 | head -30`
Expected after fixes: `Build complete!`. Every error will be an access-level miss from Step 2 — fix by adding/removing `public` per the rules above. No logic changes of any kind.

- [ ] **Step 4: Build the desktop app and its tests**

Run: `cd WatchtowerDesktop && swift build && swift build --build-tests 2>&1 | head -30`

Two expected classes of errors, with mechanical fixes:
- App code can't see a symbol → it was missed in the publicize pass; make it `public` in the Kit (never work around by duplicating).
- A test file constructs a moved model via its **internal memberwise init** (e.g. `Target(id: 1, text: "x", ...)`) → add `@testable import WatchtowerKit` at the top of that test file (debug builds compile the local package with testability). Do not add public memberwise inits for this.

- [ ] **Step 5: Run the full desktop suite**

Run: `cd WatchtowerDesktop && swift test 2>&1 | tail -3`
Expected: PASS with the same test count as the Task 1 baseline.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor(kit): move slice models (briefing/inbox/target/track/digest/calendar/people) into WatchtowerKit"
```

---

### Task 3: Payload format — JSONValue, RowPayloadCoder, SliceKind, SliceRecord

**Files:**
- Create: `WatchtowerKit/Sources/WatchtowerKit/Sync/JSONValue.swift`
- Create: `WatchtowerKit/Sources/WatchtowerKit/Sync/RowPayloadCoder.swift`
- Create: `WatchtowerKit/Sources/WatchtowerKit/Sync/SliceRecord.swift`
- Test: `WatchtowerKit/Tests/WatchtowerKitTests/RowPayloadCoderTests.swift`

**Interfaces:**
- Consumes: GRDB `Row`, `DatabaseValue`.
- Produces:
  - `public enum JSONValue: Codable, Equatable` — cases `.null`, `.integer(Int64)`, `.double(Double)`, `.string(String)`, `.blob(Data)`; `init(_ dbValue: DatabaseValue)`, `var databaseValue: DatabaseValue`.
  - `public enum RowPayloadCoder` — `static func payload(from row: Row) throws -> Data`, `static func row(from payload: Data) throws -> Row`.
  - `public enum SliceKind: String, Codable, CaseIterable` — `briefing`, `inbox_item`, `target`, `track`, `digest`, `digest_topic`, `calendar_event`, `person_card`; `func recordName(id: String) -> String` returning `"<rawValue>-<id>"`.
  - `public struct SliceRecord: Equatable` — `kind: SliceKind`, `id: String`, `modifiedAt: Date`, `payload: Data`, computed `recordName: String`; memberwise `public init`.

- [ ] **Step 1: Write the failing tests**

`WatchtowerKit/Tests/WatchtowerKitTests/RowPayloadCoderTests.swift`:

```swift
import XCTest
import GRDB
@testable import WatchtowerKit

final class RowPayloadCoderTests: XCTestCase {
    func testRowRoundTripPreservesAllStorageClasses() throws {
        let original = Row([
            "id": 42,
            "score": 0.5,
            "title": "hello",
            "raw": "bytes".data(using: .utf8)!,
            "missing": nil,
        ])

        let payload = try RowPayloadCoder.payload(from: original)
        let decoded = try RowPayloadCoder.row(from: payload)

        XCTAssertEqual(decoded["id"] as Int64?, 42)
        XCTAssertEqual(decoded["score"] as Double?, 0.5)
        XCTAssertEqual(decoded["title"] as String?, "hello")
        XCTAssertEqual(decoded["raw"] as Data?, "bytes".data(using: .utf8)!)
        XCTAssertTrue((decoded["missing"] as DatabaseValue?)?.isNull ?? false)
        XCTAssertEqual(decoded.count, original.count)
    }

    func testRowFromRealDatabaseQueryRoundTrips() throws {
        let queue = try DatabaseQueue()
        let payload: Data = try queue.read { db in
            let row = try Row.fetchOne(db, sql: "SELECT 7 AS n, 'x' AS s, NULL AS z, 1.5 AS f")!
            return try RowPayloadCoder.payload(from: row)
        }
        let decoded = try RowPayloadCoder.row(from: payload)
        XCTAssertEqual(decoded["n"] as Int64?, 7)
        XCTAssertEqual(decoded["s"] as String?, "x")
        XCTAssertEqual(decoded["f"] as Double?, 1.5)
    }

    func testPayloadIsAJSONObject() throws {
        let payload = try RowPayloadCoder.payload(from: Row(["a": 1]))
        let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        XCTAssertNotNil(object)
    }

    func testSliceKindRecordName() {
        XCTAssertEqual(SliceKind.target.recordName(id: "123"), "target-123")
        XCTAssertEqual(SliceKind.inboxItem.recordName(id: "9"), "inbox_item-9")
    }

    func testSliceRecordRecordName() {
        let record = SliceRecord(kind: .digest, id: "55", modifiedAt: Date(timeIntervalSince1970: 0), payload: Data())
        XCTAssertEqual(record.recordName, "digest-55")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd WatchtowerKit && swift test 2>&1 | head -20`
Expected: FAIL to compile — `RowPayloadCoder`, `SliceKind`, `SliceRecord` not found.

- [ ] **Step 3: Implement**

`WatchtowerKit/Sources/WatchtowerKit/Sync/JSONValue.swift`:

```swift
import Foundation
import GRDB

/// JSON-representable mirror of SQLite's five storage classes.
/// The sync payload is a `[column: JSONValue]` object, so the sync layer
/// never needs models to be Codable — it round-trips raw rows.
public enum JSONValue: Equatable {
    case null
    case integer(Int64)
    case double(Double)
    case string(String)
    case blob(Data)

    public init(_ dbValue: DatabaseValue) {
        switch dbValue.storage {
        case .null: self = .null
        case .int64(let value): self = .integer(value)
        case .double(let value): self = .double(value)
        case .string(let value): self = .string(value)
        case .blob(let value): self = .blob(value)
        }
    }

    public var databaseValue: DatabaseValue {
        switch self {
        case .null: return .null
        case .integer(let value): return value.databaseValue
        case .double(let value): return value.databaseValue
        case .string(let value): return value.databaseValue
        case .blob(let value): return value.databaseValue
        }
    }
}

extension JSONValue: Codable {
    private static let blobKey = "$blob"

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let object = try? container.decode([String: String].self),
                  let base64 = object[Self.blobKey],
                  let data = Data(base64Encoded: base64) {
            self = .blob(data)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSONValue payload"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .integer(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .blob(let value): try container.encode([Self.blobKey: value.base64EncodedString()])
        }
    }
}
```

`WatchtowerKit/Sources/WatchtowerKit/Sync/RowPayloadCoder.swift`:

```swift
import Foundation
import GRDB

/// Encodes a GRDB row as a JSON object of column name → JSONValue,
/// and reconstructs a Row from such a payload. Schema-agnostic: works
/// for any slice table, models decode via their existing init(row:).
public enum RowPayloadCoder {
    public static func payload(from row: Row) throws -> Data {
        var dict: [String: JSONValue] = [:]
        for (column, dbValue) in row {
            dict[column] = JSONValue(dbValue)
        }
        return try JSONEncoder().encode(dict)
    }

    public static func row(from payload: Data) throws -> Row {
        let dict = try JSONDecoder().decode([String: JSONValue].self, from: payload)
        var rowDict: [String: DatabaseValueConvertible?] = [:]
        for (column, value) in dict {
            rowDict[column] = value.databaseValue
        }
        return Row(rowDict)
    }
}
```

`WatchtowerKit/Sources/WatchtowerKit/Sync/SliceRecord.swift`:

```swift
import Foundation

/// The product-slice entity kinds synced through DataZone.
/// rawValue is part of the wire format — never rename existing cases.
public enum SliceKind: String, Codable, CaseIterable {
    case briefing
    case inboxItem = "inbox_item"
    case target
    case track
    case digest
    case digestTopic = "digest_topic"
    case calendarEvent = "calendar_event"
    case personCard = "person_card"

    public func recordName(id: String) -> String {
        "\(rawValue)-\(id)"
    }
}

/// One synced slice row: identity + row payload (RowPayloadCoder JSON).
public struct SliceRecord: Equatable {
    public let kind: SliceKind
    public let id: String
    public let modifiedAt: Date
    public let payload: Data

    public var recordName: String { kind.recordName(id: id) }

    public init(kind: SliceKind, id: String, modifiedAt: Date, payload: Data) {
        self.kind = kind
        self.id = id
        self.modifiedAt = modifiedAt
        self.payload = payload
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd WatchtowerKit && swift test 2>&1 | tail -3`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add WatchtowerKit
git commit -m "feat(kit): row-dict payload format (JSONValue, RowPayloadCoder, SliceRecord)"
```

---

### Task 4: Relay protocol payloads and wire-format coder

**Files:**
- Create: `WatchtowerKit/Sources/WatchtowerKit/Relay/RelayCoder.swift`
- Create: `WatchtowerKit/Sources/WatchtowerKit/Relay/ActionRequestPayload.swift`
- Create: `WatchtowerKit/Sources/WatchtowerKit/Relay/ChatPayloads.swift`
- Test: `WatchtowerKit/Tests/WatchtowerKitTests/RelayPayloadTests.swift`

**Interfaces:**
- Consumes: `JSONValue` (Task 3).
- Produces:
  - `public enum RelayCoder` — `static func makeEncoder() -> JSONEncoder`, `static func makeDecoder() -> JSONDecoder` (snake_case keys, dates as Unix seconds, sorted keys).
  - `public enum ActionKind: String, Codable, CaseIterable` — `target_done`, `target_snooze`, `inbox_resolve`, `inbox_dismiss`, `inbox_snooze`, `task_create`, `track_read`.
  - `public enum ActionStatus: String, Codable` — `pending`, `applied`, `failed`.
  - `public struct ActionRequestPayload: Codable, Equatable` — `id: String`, `kind: ActionKind`, `entityID: String?`, `params: [String: JSONValue]`, `createdAt: Date`, `var status: ActionStatus`, `var errorMessage: String?`, computed `recordName: String` = `"action-<id>"`.
  - `public struct ChatMessagePayload: Codable, Equatable` — `id: String`, `sessionID: String`, `text: String`, `createdAt: Date`; `recordName` = `"chatmsg-<id>"`.
  - `public struct ChatChunkPayload: Codable, Equatable` — `sessionID: String`, `messageID: String`, `seq: Int`, `text: String`, `done: Bool`; `recordName` = `"chatchunk-<messageID>-<seq>"`.
  - `public struct HeartbeatPayload: Codable, Equatable` — `updatedAt: Date`, `appVersion: String`; `static let recordName = "heartbeat"`.

- [ ] **Step 1: Write the failing tests**

`WatchtowerKit/Tests/WatchtowerKitTests/RelayPayloadTests.swift`:

```swift
import XCTest
@testable import WatchtowerKit

final class RelayPayloadTests: XCTestCase {
    func testActionRequestWireFormatIsFrozen() throws {
        let action = ActionRequestPayload(
            id: "A1",
            kind: .inboxSnooze,
            entityID: "42",
            params: ["snooze_until": .string("2026-07-06T09:00:00Z")],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let json = String(data: try RelayCoder.makeEncoder().encode(action), encoding: .utf8)!
        XCTAssertEqual(json, #"{"created_at":1700000000,"entity_id":"42","id":"A1","kind":"inbox_snooze","params":{"snooze_until":"2026-07-06T09:00:00Z"},"status":"pending"}"#)
    }

    func testActionRequestRoundTrip() throws {
        var action = ActionRequestPayload(
            id: "A2",
            kind: .taskCreate,
            entityID: nil,
            params: ["text": .string("call bob"), "priority": .string("high")],
            createdAt: Date(timeIntervalSince1970: 1_700_000_001)
        )
        action.status = .failed
        action.errorMessage = "row not found"

        let data = try RelayCoder.makeEncoder().encode(action)
        let decoded = try RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: data)
        XCTAssertEqual(decoded, action)
        XCTAssertEqual(decoded.recordName, "action-A2")
    }

    func testChatChunkRecordNameAndRoundTrip() throws {
        let chunk = ChatChunkPayload(sessionID: "S1", messageID: "M1", seq: 3, text: "partial", done: false)
        XCTAssertEqual(chunk.recordName, "chatchunk-M1-3")
        let data = try RelayCoder.makeEncoder().encode(chunk)
        XCTAssertEqual(try RelayCoder.makeDecoder().decode(ChatChunkPayload.self, from: data), chunk)
    }

    func testChatMessageRecordName() {
        let message = ChatMessagePayload(id: "M9", sessionID: "S1", text: "hi", createdAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(message.recordName, "chatmsg-M9")
    }

    func testHeartbeatRoundTrip() throws {
        let beat = HeartbeatPayload(updatedAt: Date(timeIntervalSince1970: 1_700_000_002), appVersion: "1.0")
        let data = try RelayCoder.makeEncoder().encode(beat)
        XCTAssertEqual(try RelayCoder.makeDecoder().decode(HeartbeatPayload.self, from: data), beat)
        XCTAssertEqual(HeartbeatPayload.recordName, "heartbeat")
    }

    func testAllActionKindsAreStable() {
        XCTAssertEqual(
            ActionKind.allCases.map(\.rawValue),
            ["target_done", "target_snooze", "inbox_resolve", "inbox_dismiss", "inbox_snooze", "task_create", "track_read"]
        )
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd WatchtowerKit && swift test 2>&1 | head -20`
Expected: FAIL to compile — relay types not found.

- [ ] **Step 3: Implement**

`WatchtowerKit/Sources/WatchtowerKit/Relay/RelayCoder.swift`:

```swift
import Foundation

/// Wire format for RelayZone payloads: snake_case keys, Unix-second dates,
/// sorted keys for deterministic fixtures. Frozen by RelayPayloadTests.
public enum RelayCoder {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
```

`WatchtowerKit/Sources/WatchtowerKit/Relay/ActionRequestPayload.swift`:

```swift
import Foundation

/// Commands mobile can enqueue; the desktop applies them through its
/// existing Queries. Closed set — rawValues are wire format, never rename.
public enum ActionKind: String, Codable, CaseIterable {
    case targetDone = "target_done"
    case targetSnooze = "target_snooze"
    case inboxResolve = "inbox_resolve"
    case inboxDismiss = "inbox_dismiss"
    case inboxSnooze = "inbox_snooze"
    case taskCreate = "task_create"
    case trackRead = "track_read"
}

public enum ActionStatus: String, Codable {
    case pending
    case applied
    case failed
}

public struct ActionRequestPayload: Codable, Equatable {
    public let id: String
    public let kind: ActionKind
    public let entityID: String?
    public let params: [String: JSONValue]
    public let createdAt: Date
    public var status: ActionStatus
    public var errorMessage: String?

    public var recordName: String { "action-\(id)" }

    public init(
        id: String,
        kind: ActionKind,
        entityID: String?,
        params: [String: JSONValue] = [:],
        createdAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.entityID = entityID
        self.params = params
        self.createdAt = createdAt
        self.status = .pending
        self.errorMessage = nil
    }
}
```

`WatchtowerKit/Sources/WatchtowerKit/Relay/ChatPayloads.swift`:

```swift
import Foundation

/// One user turn sent from mobile to the desktop agent.
public struct ChatMessagePayload: Codable, Equatable {
    public let id: String
    public let sessionID: String
    public let text: String
    public let createdAt: Date

    public var recordName: String { "chatmsg-\(id)" }

    public init(id: String, sessionID: String, text: String, createdAt: Date) {
        self.id = id
        self.sessionID = sessionID
        self.text = text
        self.createdAt = createdAt
    }
}

/// Monotonic response chunks (pseudo-streaming). Chunks are append-only
/// records — never rewritten — so they cannot conflict.
public struct ChatChunkPayload: Codable, Equatable {
    public let sessionID: String
    public let messageID: String
    public let seq: Int
    public let text: String
    public let done: Bool

    public var recordName: String { "chatchunk-\(messageID)-\(seq)" }

    public init(sessionID: String, messageID: String, seq: Int, text: String, done: Bool) {
        self.sessionID = sessionID
        self.messageID = messageID
        self.seq = seq
        self.text = text
        self.done = done
    }
}

/// Desktop liveness marker, refreshed every 5 minutes (spec Section 2).
public struct HeartbeatPayload: Codable, Equatable {
    public static let recordName = "heartbeat"

    public let updatedAt: Date
    public let appVersion: String

    public init(updatedAt: Date, appVersion: String) {
        self.updatedAt = updatedAt
        self.appVersion = appVersion
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd WatchtowerKit && swift test 2>&1 | tail -3`
Expected: PASS (12 tests total).

Note: if `testActionRequestWireFormatIsFrozen` fails on key spelling (e.g. `entity_i_d`), fix by adding explicit `CodingKeys` to `ActionRequestPayload` (`case entityID = "entity_id"`, plus verbatim cases for the rest) rather than changing the fixture — the wire format is the contract.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerKit
git commit -m "feat(kit): relay protocol payloads (actions, chat chunks, heartbeat) with frozen wire format"
```

---

### Task 5: CloudSyncTransport seam and in-memory fake

**Files:**
- Create: `WatchtowerKit/Sources/WatchtowerKit/Sync/CloudSyncTransport.swift`
- Create: `WatchtowerKit/Sources/WatchtowerKit/Sync/InMemoryCloudTransport.swift`
- Test: `WatchtowerKit/Tests/WatchtowerKitTests/InMemoryCloudTransportTests.swift`

**Interfaces:**
- Consumes: nothing new (Foundation only).
- Produces:
  - `public enum CloudZoneID: String, Codable, CaseIterable` — `case data = "DataZone"`, `case relay = "RelayZone"`.
  - `public struct CloudRecord: Equatable` — `recordName: String`, `zone: CloudZoneID`, `kind: String`, `modifiedAt: Date`, `payload: Data`; memberwise `public init`.
  - `public struct CloudChangeToken: Codable, Equatable` — `value: Int`; `public init(value: Int)`.
  - `public struct CloudChangeBatch: Equatable` — `changed: [CloudRecord]`, `deletedRecordNames: [String]`, `newToken: CloudChangeToken`.
  - `public protocol CloudSyncTransport` — `func save(_ records: [CloudRecord]) async throws`, `func delete(recordNames: [String], in zone: CloudZoneID) async throws`, `func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch`.
  - `public actor InMemoryCloudTransport: CloudSyncTransport` — the test fake used by all sync/relay unit tests in Plans 2–5 (Plan 2 adds the real CKSyncEngine-backed implementation).

- [ ] **Step 1: Write the failing tests**

`WatchtowerKit/Tests/WatchtowerKitTests/InMemoryCloudTransportTests.swift`:

```swift
import XCTest
@testable import WatchtowerKit

final class InMemoryCloudTransportTests: XCTestCase {
    private func record(_ name: String, zone: CloudZoneID = .data, kind: String = "target", payload: String = "{}") -> CloudRecord {
        CloudRecord(
            recordName: name,
            zone: zone,
            kind: kind,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            payload: Data(payload.utf8)
        )
    }

    func testSavedRecordsAppearInChanges() async throws {
        let transport = InMemoryCloudTransport()
        try await transport.save([record("target-1"), record("target-2")])

        let batch = try await transport.changes(in: .data, since: nil)
        XCTAssertEqual(batch.changed.map(\.recordName).sorted(), ["target-1", "target-2"])
        XCTAssertTrue(batch.deletedRecordNames.isEmpty)
    }

    func testChangesSinceTokenReturnsOnlyNewEvents() async throws {
        let transport = InMemoryCloudTransport()
        try await transport.save([record("target-1")])
        let first = try await transport.changes(in: .data, since: nil)

        try await transport.save([record("target-2")])
        let second = try await transport.changes(in: .data, since: first.newToken)
        XCTAssertEqual(second.changed.map(\.recordName), ["target-2"])

        let third = try await transport.changes(in: .data, since: second.newToken)
        XCTAssertTrue(third.changed.isEmpty)
        XCTAssertEqual(third.newToken, second.newToken)
    }

    func testLatestWriteWinsWithinABatch() async throws {
        let transport = InMemoryCloudTransport()
        try await transport.save([record("target-1", payload: "{\"v\":1}")])
        try await transport.save([record("target-1", payload: "{\"v\":2}")])

        let batch = try await transport.changes(in: .data, since: nil)
        XCTAssertEqual(batch.changed.count, 1)
        XCTAssertEqual(batch.changed[0].payload, Data("{\"v\":2}".utf8))
    }

    func testDeleteProducesTombstoneAndSuppressesEarlierSave() async throws {
        let transport = InMemoryCloudTransport()
        try await transport.save([record("target-1")])
        try await transport.delete(recordNames: ["target-1"], in: .data)

        let batch = try await transport.changes(in: .data, since: nil)
        XCTAssertTrue(batch.changed.isEmpty)
        XCTAssertEqual(batch.deletedRecordNames, ["target-1"])
    }

    func testZonesAreIsolated() async throws {
        let transport = InMemoryCloudTransport()
        try await transport.save([record("target-1", zone: .data)])
        try await transport.save([record("action-1", zone: .relay, kind: "action")])

        let dataBatch = try await transport.changes(in: .data, since: nil)
        let relayBatch = try await transport.changes(in: .relay, since: nil)
        XCTAssertEqual(dataBatch.changed.map(\.recordName), ["target-1"])
        XCTAssertEqual(relayBatch.changed.map(\.recordName), ["action-1"])
    }

    func testDataZoneTokenUnaffectedByRelayWrites() async throws {
        let transport = InMemoryCloudTransport()
        try await transport.save([record("target-1", zone: .data)])
        let dataToken = try await transport.changes(in: .data, since: nil).newToken

        try await transport.save([record("action-1", zone: .relay, kind: "action")])
        let batch = try await transport.changes(in: .data, since: dataToken)
        XCTAssertTrue(batch.changed.isEmpty)
        XCTAssertTrue(batch.deletedRecordNames.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd WatchtowerKit && swift test 2>&1 | head -20`
Expected: FAIL to compile — transport types not found.

- [ ] **Step 3: Implement**

`WatchtowerKit/Sources/WatchtowerKit/Sync/CloudSyncTransport.swift`:

```swift
import Foundation

/// CloudKit zone identifiers. rawValue is the CKRecordZone name (Plan 2).
public enum CloudZoneID: String, Codable, CaseIterable {
    case data = "DataZone"
    case relay = "RelayZone"
}

/// One record on the wire: identity + opaque payload. The real transport
/// (Plan 2) maps this 1:1 onto a CKRecord with `payload` in encryptedValues.
public struct CloudRecord: Equatable {
    public let recordName: String
    public let zone: CloudZoneID
    public let kind: String
    public let modifiedAt: Date
    public let payload: Data

    public init(recordName: String, zone: CloudZoneID, kind: String, modifiedAt: Date, payload: Data) {
        self.recordName = recordName
        self.zone = zone
        self.kind = kind
        self.modifiedAt = modifiedAt
        self.payload = payload
    }
}

/// Opaque, monotonically increasing per-zone change cursor.
public struct CloudChangeToken: Codable, Equatable {
    public let value: Int

    public init(value: Int) {
        self.value = value
    }
}

public struct CloudChangeBatch: Equatable {
    public let changed: [CloudRecord]
    public let deletedRecordNames: [String]
    public let newToken: CloudChangeToken

    public init(changed: [CloudRecord], deletedRecordNames: [String], newToken: CloudChangeToken) {
        self.changed = changed
        self.deletedRecordNames = deletedRecordNames
        self.newToken = newToken
    }
}

/// The seam that hides CloudKit. Everything above this protocol is unit-testable
/// against InMemoryCloudTransport; only Plan 2's CKSyncEngine adapter touches CloudKit.
public protocol CloudSyncTransport {
    func save(_ records: [CloudRecord]) async throws
    func delete(recordNames: [String], in zone: CloudZoneID) async throws
    func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch
}
```

`WatchtowerKit/Sources/WatchtowerKit/Sync/InMemoryCloudTransport.swift`:

```swift
import Foundation

/// Test fake: an append-only event log per zone with CloudKit-like change
/// semantics (latest state per recordName since a token; deletes win).
public actor InMemoryCloudTransport: CloudSyncTransport {
    private struct Event {
        let seq: Int
        let zone: CloudZoneID
        let recordName: String
        /// nil means tombstone (deleted)
        let record: CloudRecord?
    }

    private var events: [Event] = []
    private var nextSeq = 1

    public init() {}

    public func save(_ records: [CloudRecord]) async throws {
        for record in records {
            events.append(Event(seq: nextSeq, zone: record.zone, recordName: record.recordName, record: record))
            nextSeq += 1
        }
    }

    public func delete(recordNames: [String], in zone: CloudZoneID) async throws {
        for name in recordNames {
            events.append(Event(seq: nextSeq, zone: zone, recordName: name, record: nil))
            nextSeq += 1
        }
    }

    public func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch {
        let floor = token?.value ?? 0
        let relevant = events.filter { $0.zone == zone && $0.seq > floor }

        // Latest event per recordName wins, in first-seen order.
        var latest: [String: Event] = [:]
        var order: [String] = []
        for event in relevant {
            if latest[event.recordName] == nil { order.append(event.recordName) }
            latest[event.recordName] = event
        }

        var changed: [CloudRecord] = []
        var deleted: [String] = []
        for name in order {
            if let record = latest[name]?.record {
                changed.append(record)
            } else {
                deleted.append(name)
            }
        }

        let zoneMax = relevant.map(\.seq).max() ?? floor
        return CloudChangeBatch(
            changed: changed,
            deletedRecordNames: deleted,
            newToken: CloudChangeToken(value: max(floor, zoneMax))
        )
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd WatchtowerKit && swift test 2>&1 | tail -3`
Expected: PASS (18 tests total).

- [ ] **Step 5: Final full verification and commit**

Run: `cd WatchtowerKit && swift test 2>&1 | tail -3 && cd ../WatchtowerDesktop && swift test 2>&1 | tail -3`
Expected: both PASS; desktop count matches the Task 1 baseline.

```bash
git add WatchtowerKit
git commit -m "feat(kit): CloudSyncTransport seam with in-memory fake"
```
