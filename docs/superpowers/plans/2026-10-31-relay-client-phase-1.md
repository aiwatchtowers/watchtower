# Relay client Phase 1 — ordered actions on the phone Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The phone side of the one action path (spec §5): a gapless per-hub `action_seq` inside the sealed payload, `pending_actions` as a real outbox (`queued | sent | settled | undelivered`) flushed in order with conditional writes, `ConditionalTransport` on CloudKit and in the in-memory transport, a durable control-record queue (`skip_to` out; `resend_from` and `transport_switch_rejected` in), echo deletes, and the owner-facing **Not delivered** list with **Retry** and **Dismiss All** plus the **Waiting to send** count on Now. The phone uses the ordered path only for a hub whose `device_grant` carries `ordered_actions`; every other hub (today's Swift hub) keeps today's path byte for byte.

**Architecture:** The seam grows by one optional protocol, `ConditionalTransport` (Kit `Sync/`), implemented by `InMemoryCloudTransport` and by `CloudKitTransport` (direct `modifyRecords` outside `CKSyncEngine`, `.ifServerRecordUnchanged`, behind an injectable database seam). `SecureTransport` passes conditional writes through for already-sealed records and opens a conflict's current record. The outbox's state lives in the replica (`pending_actions` gains `action_seq` and `delivery`; new `outbound_controls` and `handled_controls`; the counter in `replica_meta`). `ActionOutbox` owns enqueue, flush, echo settlement, `resend_from` → `skip_to`, Retry and Dismiss All; `RelayFeed` routes `control` frames and deletes final echoes and read controls. `HubSession` turns the ordered path on from the grant, flushes after every fetch and enqueue, and publishes the backlog for Now. The hub's order, holds and echoes are the Go hub's (ask #802, `internal/hub/actions`); the Swift Desktop hub is not extended.

**Tech Stack:** Swift 5.10 language mode, SwiftUI, GRDB (SQLCipher fork), CloudKit; packages `WatchtowerKit` (`WatchtowerSync`), `WatchtowerMobile` (xcodegen, iOS 17), XCTest.

**Spec:** `docs/superpowers/specs/2026-10-29-relay-client-design.md` — §5 (actions: one order, one outbox, both transports), §3 (`ConditionalTransport`), §11 (testing), §13 row 1, §14, Decisions. **Wire contract:** `docs/superpowers/specs/2026-10-31-hub-phone-protocol-design.md` §4.5, §5.4, §7.1–§7.6, §7.8, §8, §10 and the Go hub's behaviour (`internal/hub/actions/order.go`, `control.go`, `internal/hub/hubtest/phone.go` — the Go phone emulator this plan mirrors). **Client rules:** relay `sim/README.md` rules 1–7a, 15, "Bounded state". Feature note: `docs/features/mobile-companion.md`. Board: new target under #1240.

## Global Constraints

- **Today's path stays byte for byte for every hub without `ordered_actions`.** Legacy rows (`action_seq` NULL, `delivery` NULL) are enqueued, saved through `CKSyncEngine`, echoed, swept (24 h) and dismissed exactly as now; every existing test keeps its assertions. The demo seed's grant carries no flag, so demo mode stays legacy.
- **Wire bytes match the Go hub.** Ordered action: plain name `a-<DEVICE_ID>-<action_seq>` (`DEVICE_ID` = the canonical uppercase `UUID.uuidString`), frame kind `action`, payload `ActionRequestPayload` + `action_seq` (u64, absent on the legacy path), `status: pending`. Control: plain name `c-<uuid>` (uppercase `uuidString`), frame kind `control`, payload `{id, kind, device_id, hub_id, seq?, epoch?, target?, by?, at?, reason?, retry_after_s?}`; a phone control always carries `device_id` and `hub_id` (the Go hub drops a `skip_to` without them, or with `m > last_applied + 1 + 65536`). Keys go through `RelayCoder` (snake case, seconds since 1970).
- `CloudSyncTransport` keeps its three requirements. New surface only through `ConditionalTransport`. Not in Phase 1: `MailboxAddressing`, `PagedChanges` (Phase 2), any `HostedRelay*` type, `epoch_ack` sending, the transport switch, `hub_on_relay` handling, the "Relay unavailable" banner (Phases 3–4).
- **Swift Desktop hub: no behaviour change.** `control` frames are accepted only in the phone role (`SecureTransport`), so the hub keeps dropping them as `unknownKind`; the Desktop compiles against the changed Kit types with no source change. `make test-swift FILTER='RelayProcessorTests|MobileLinkCenterTests'` stays green in Tasks 1–4.
- **No plaintext at rest.** Outbox rows and queued controls keep only the sealed envelope and ids/counters/states; Retry opens the stored envelope with the phone's own key.
- **E2E vectors stay frozen.** No `make e2e-vectors`; new contract cases go into `WatchtowerKit/Tests/Fixtures/link/hub_contract_cases.json` as plain JSON.
- Inventory guards stay byte-identical (PROJ-16, PROJ-21; spec §5 p. 12): `WatchtowerDesktop/Tests/MobileHub/SessionInputHandlersTests.swift`, `PermissionAnswerHandlersTests.swift`, `PermissionRequestSliceTests.swift`, `WatchtowerKit/Tests/WatchtowerSyncTests/PermissionAllowRuleTests.swift`, `WatchtowerMobile/Tests/PermissionCardTests.swift`, `WatchtowerMobile/Tests/SessionInputWiringTests.swift`. Every task ends with `git diff --stat origin/main --` those six files printing nothing.
- New phone source or test files: `make mobile-gen` and commit the regenerated `WatchtowerMobile/WatchtowerMobile.xcodeproj` in the same task. Phone tests run with `SIM='iPhone 17 Pro'` (no iPhone 18 Pro simulator installed): `make mobile-test SIM='iPhone 17 Pro' MOBILE_FILTER=…`.
- Inner loop only per task: `make kit-test FILTER=…`, `make test-swift FILTER=…`, `make mobile-test MOBILE_FILTER=…`, `make lint-swift` (`make lint-diff` is Go-only). Never run a build or test in the background. The full gate runs once, in Task 11.
- Public repo: fixtures use `acme`, `example.com`, `_owner-acme`, the fixture UUIDs already in `hub_contract_cases.json`; no real ids.

## Review Focus

1. **Gapless counter under reentrancy.** Two enqueues racing across the actor's `await seal` must never draw the same `action_seq` or leave a hole. Task 5 `testTheCounterAdvancesOnlyWithAnInsertedRow`, Task 6 `testTwoConcurrentEnqueuesGetConsecutiveSeqs`.
2. **Sim rule 3 on a conflict** (echo of the same seq → settle; identical bytes → sent; anything else → overwrite under the current `recordSeq`) on both transports. Task 1 (in-memory semantics), Task 2 (CloudKit mapping), Task 6 `testAConflictWith*`.
3. **Nothing dropped silently.** A permanent refusal lists the action as Not delivered; a `resend_from` for seqs the phone holds no row for writes `skip_to` and lists nothing new (those rows were settled or dismissed); Dismiss All is the only delete of an unsent action. Task 6, Task 7 `testSkipToMarksUndelivered`.
4. **The legacy path is untouched** while a hub lacks the flag, and a gap `held` echo (no reason) changes no overlay, so the PROJ-16/21 screens read as today. Task 6 `testALegacyHubKeepsTodaysPath`, `testAGapHoldLeavesTheOverlayAlone`; Task 8 guard files.
5. **CloudKit conditional semantics**: `.absent` = create-only, `.seq` checked against the stored system fields' counter before the server's change tag; a delete checks locally and then deletes (Ruling 6). Task 2.

---

## Lanes

Kit first, three parallel lanes: **A** Task 1 → Task 2 (CloudKit), **B** Task 3 (wire payloads + fixture), **C** Task 5 (replica storage). Then Task 4 (after 1, 3) → Task 6 (after 4, 5) → Task 7 (after 6). Task 2 may still run beside Tasks 4–7 (they test on the in-memory transport). Phone: Task 8 (after 2, 7) → Task 9 → Task 10 (guide). Task 11 is the gate.

### Task 1: `ConditionalTransport` types, `CloudRecord.recordSeq`, the in-memory transport

**Depends on:** none

**Files:**
- Create: `WatchtowerKit/Sources/WatchtowerSync/Sync/ConditionalTransport.swift`
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Sync/CloudSyncTransport.swift` (`CloudRecord.recordSeq`, init parameter after `sealed:` with default `nil`)
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Sync/InMemoryCloudTransport.swift` (per-record `recordSeq`; conformance)
- Test: Create `WatchtowerKit/Tests/WatchtowerSyncTests/InMemoryConditionalTransportTests.swift`

**Interfaces:**
- Produces (`ConditionalTransport.swift`, no CloudKit):
  ```swift
  public enum WriteExpectation: Equatable, Sendable { case none, absent, seq(UInt64) }
  public struct ConditionalSave: Equatable, Sendable { public let record: CloudRecord; public let expect: WriteExpectation }
  public struct ConditionalDelete: Equatable, Sendable { public let recordName: String; public let zone: CloudZoneID; public let expect: WriteExpectation }
  /// Why a write did not land. Transient ones stop a flush and are retried next pass (sim rule 1).
  public enum TransportRefusal: Equatable, Sendable {
      case unreachable, rateLimited(retryAfter: TimeInterval?), quotaExceeded, entitlementInactive
      case permanent(code: String)          // retrying can only repeat it (zone gone, permission lost, too large)
      public var isTransient: Bool { get }  // every case but .permanent
  }
  public enum SaveOutcome: Equatable, Sendable { case saved(recordSeq: UInt64), conflict(current: CloudRecord), refused(TransportRefusal) }
  public enum DeleteOutcome: Equatable, Sendable { case deleted, conflict(current: CloudRecord), refused(TransportRefusal) }
  public protocol ConditionalTransport: CloudSyncTransport {
      /// One outcome per item, in order. A call-level failure (no network) is `.refused` for every item; it throws only for local errors.
      func save(_ items: [ConditionalSave]) async throws -> [SaveOutcome]
      /// An absent record counts as `.deleted` (the seam's idempotent delete).
      func delete(_ items: [ConditionalDelete]) async throws -> [DeleteOutcome]
  }
  ```
- Produces: `CloudRecord.recordSeq: UInt64?` — read-only transport metadata like `origin`: the version a conditional write's `.seq` names; nil on a record this device built and on transports that keep none. Doc comment says so; `Equatable` includes it.
- `InMemoryCloudTransport`: one zone-wide counter; every stored version (plain `save` included) gets the next value, returned on `changes`. `.absent` against a present record → `.conflict(current:)`; `.seq(n)` against another version → `.conflict(current:)`; `.seq(n)` against an absent record → `.refused(.permanent(code: "gone"))` (there is no current record to hand back); `.none` always writes. A test hook `refuseNext(_ refusal: TransportRefusal, count: Int)` lets Kit tests script refusals (internal, `@testable`).

- [ ] **Step 1: Write the failing tests** (`InMemoryConditionalTransportTests`)
  - `testAbsentCreatesOnceThenConflicts`: first `.absent` save → `.saved(recordSeq: 1)`; second with other bytes → `.conflict(current:)` whose payload is the first one's and `recordSeq == 1`.
  - `testSeqOverwritesOnlyTheVersionItNames`: `.seq(1)` → `.saved(2)`; a second `.seq(1)` → `.conflict(current.recordSeq == 2)`.
  - `testChangesCarryTheRecordSeq`: `changes(in:since:)` returns `recordSeq` of each version.
  - `testDeleteUnderSeqAndAbsentRecord`: delete `.seq(2)` of a version-3 record → `.conflict`; delete `.seq(3)` → `.deleted`, then `changes` lists it deleted; delete of an absent name → `.deleted`.
  - `testScriptedRefusalsComeFirst`: `refuseNext(.unreachable, count: 1)` → first item `.refused(.unreachable)`, second `.saved`.
- [ ] **Step 2: Run, expect failure** — `make kit-test FILTER=InMemoryConditionalTransportTests` — FAIL ("cannot find type 'ConditionalSave'").
- [ ] **Step 3: Implement** the file, the field and the conformance. `InMemoryCloudTransportTests` stays green unchanged.
- [ ] **Step 4: Run** — `make kit-test FILTER='InMemoryConditionalTransportTests|InMemoryCloudTransportTests|SeamTypesTests'`, then `make test-swift FILTER='RelayProcessorTests|MobileLinkCenterTests'` (the Desktop compiles against the new init) — PASS.
- [ ] **Step 5: Lint and guard check** — `make lint-swift`; guard-file diff empty.
- [ ] **Step 6: Commit** — `feat(kit): ConditionalTransport and record versions in the in-memory transport (#1240)`

### Task 2: `ConditionalTransport` on CloudKit

**Depends on:** Task 1

**Files:**
- Create: `WatchtowerKit/Sources/WatchtowerSync/CloudKitTransport/CloudKitTransport+Conditional.swift`
- Create: `WatchtowerKit/Sources/WatchtowerSync/CloudKitTransport/ConditionalDatabase.swift` (the seam: `protocol ConditionalDatabase: Sendable { func modify(saving: [CKRecord], deleting: [CKRecord.ID]) async throws -> (saves: [CKRecord.ID: Result<CKRecord, Error>], deletes: [CKRecord.ID: Result<Void, Error>]) }`; `CKDatabase` conforms with `savePolicy: .ifServerRecordUnchanged, atomically: false`)
- Modify: `WatchtowerKit/Sources/WatchtowerSync/CloudKitTransport/TransportStore.swift` (`system_fields.record_seq INTEGER NOT NULL DEFAULT 0` bumped on every `saveSystemFields`; `events.record_seq INTEGER` written by `bufferFetched` from the same transaction's system-fields row; both patched in place for older stores like `creator`; `func recordSeq(recordName:zone:) throws -> UInt64?`; `func latestEvent(recordName:zone:) throws -> CloudRecord?`)
- Modify: `WatchtowerKit/Sources/WatchtowerSync/CloudKitTransport/CloudKitTransport.swift` (an internal init parameter `conditionalDatabase: (any ConditionalDatabase)?`, default the scope's `CKDatabase`, built lazily)
- Modify: `WatchtowerKit/Sources/WatchtowerSync/CloudKitTransport/CloudKitTransport+Mapping.swift` (fetched `CloudRecord.recordSeq` from the buffered event)
- Test: Create `WatchtowerKit/Tests/WatchtowerSyncTests/CloudKitConditionalTests.swift` with a `FakeConditionalDatabase` in `Support/`; extend `TransportStoreTests`

**Interfaces:**
- Consumes: Task 1's types.
- Produces: `extension CloudKitTransport: ConditionalTransport`. Rules (spec §3, Ruling 6):
  - Only `.relay` records; a `.data` item → `.refused(.permanent(code: "notMailbox"))` (slices keep today's path).
  - `.absent` → a fresh `CKRecord` (no system fields), so the server refuses an existing name with `serverRecordChanged`.
  - `.seq(n)` → the stored system fields when their `record_seq == n`; a stored `record_seq != n` → `.conflict(current: latestEvent)` without a call; no stored fields → `.conflict(current:)` of the buffered event if any, else `.refused(.permanent(code: "unknownVersion"))`.
  - `.none` → stored system fields if any, else fresh (overwrite on conflict once, today's direct-save rule).
  - `serverRecordChanged` → store the server record's system fields (bump `record_seq`) and return `.conflict(current:)` mapped from `error.serverRecord` (with that `recordSeq`). Never "my payload wins" on this path.
  - A saved record's system fields are stored (bump) and returned as `.saved(recordSeq:)`.
  - Delete: `.seq(n)` checked against the stored `record_seq` (mismatch → `.conflict(current: latestEvent)`), then an unconditional delete; `unknownItem` → `.deleted`; stored fields deleted on success.
  - Error map (`TransportRefusal`): `networkUnavailable`, `networkFailure`, `serviceUnavailable`, `zoneBusy`, `notAuthenticated`, `accountTemporarilyUnavailable` → `.unreachable`; `requestRateLimited` → `.rateLimited(retryAfter: error.retryAfterSeconds)`; `quotaExceeded` → `.quotaExceeded`; `zoneNotFound`, `userDeletedZone`, `permissionFailure`, `limitExceeded`, `invalidArguments`, `assetFileNotFound`, anything else → `.permanent(code: "CKError <raw>")`. A call-level throw maps every item through the same table.
  - Records written here never enter the engine's `pending` queue; `CKSyncEngine` fetches them later like any other change.

- [ ] **Step 1: Write the failing tests** (`CloudKitConditionalTests`, all on `FakeConditionalDatabase` and a temp `TransportStore`)
  - `testAbsentSendsAFreshRecord`: the fake saw one `CKRecord` with no change tag; outcome `.saved(recordSeq: 1)`; `store.recordSeq` = 1.
  - `testServerRecordChangedIsAConflictNotARetry`: the fake answers `serverRecordChanged` with a server record; outcome `.conflict(current:)` carrying the server payload; the fake saw exactly one save.
  - `testAStaleSeqConflictsWithoutACall`: stored `record_seq` 3, `.seq(2)` → `.conflict`, the fake saw nothing.
  - `testDeleteChecksLocallyThenDeletes`: `.seq(3)` → one delete call, `.deleted`; `.seq(2)` → `.conflict`, no call; `unknownItem` → `.deleted`.
  - `testRefusalsMapByCode`: one test per row of the table above (table-driven).
  - `testADataZoneItemIsRefused`.
  - `TransportStoreTests.testRecordSeqBumpsWithEachSystemFieldsWrite` and `testAStoreFromBeforeRecordSeqOpensWithZero` (a store file without the columns gains them, rows read 0).
- [ ] **Step 2: Run, expect failure** — `make kit-test FILTER='CloudKitConditionalTests|TransportStoreTests'` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — `make kit-test FILTER='CloudKitConditionalTests|TransportStoreTests|CloudKitTransportMappingTests|CloudKitTransportErrorTests|CloudKitTransportHubTests|CloudKitTransportStopTests'`, `make test-swift FILTER='RelayProcessorTests|MobileHubServiceTests'` — PASS.
- [ ] **Step 5: Lint and guard check.**
- [ ] **Step 6: Commit** — `feat(kit): conditional mailbox writes on CloudKit (#1240)`

### Task 3: Wire payloads — `action_seq`, `ControlPayload`, `ordered_actions`, the shared fixture

**Depends on:** none

**Files:**
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Relay/ActionRequestPayload.swift` (`public var actionSeq: UInt64?`, CodingKey `actionSeq`, decoded with `decodeIfPresent`, encoded only when set; `public static func orderedRecordName(deviceID: UUID, actionSeq: UInt64) -> String` = `"a-\(deviceID.uuidString)-\(actionSeq)"`)
- Create: `WatchtowerKit/Sources/WatchtowerSync/Relay/ControlPayload.swift`
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Relay/RelayRecordKind.swift` (`case control`)
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Link/DeviceGrant.swift` (`public let orderedActions: Int?`, key `orderedActions`; `public var runsOrderedActions: Bool { (orderedActions ?? 0) >= 1 }`)
- Modify: `WatchtowerKit/Tests/Fixtures/link/hub_contract_cases.json` (the `kit` block of each `device_grant` case gains `ordered_actions` — 1 for the Go cases, null for `old_hub_no_new_fields`; new top-level sections `action` and `control`)
- Test: `WatchtowerKit/Tests/WatchtowerSyncTests/HubContractFixtureTests.swift`, `RelayPayloadTests.swift`, `GoSealedEnvelopeTests.swift`

**Interfaces:**
- Produces (`ControlPayload.swift`):
  ```swift
  public struct ControlKind: OpenWireValue {     // an unknown kind decodes, never fails the record
      public static let resendFrom = Self(rawValue: "resend_from"), skipTo = Self(rawValue: "skip_to"),
          epochAck = Self(rawValue: "epoch_ack"), transportSwitch = Self(rawValue: "transport_switch"),
          transportSwitched = Self(rawValue: "transport_switched"),
          transportSwitchRejected = Self(rawValue: "transport_switch_rejected"), hubOnRelay = Self(rawValue: "hub_on_relay")
  }
  public struct ControlPayload: Codable, Equatable, Sendable {
      public let id: String; public let kind: ControlKind
      public let deviceID: String?; public let hubID: String?        // keys deviceId / hubId (snake via RelayCoder)
      public let seq: UInt64?; public let epoch: UInt32?; public let target: String?; public let by: String?
      public let at: Date?; public let reason: String?; public let retryAfterS: UInt32?
      public var recordName: String { "c-\(id)" }
      public static func skipTo(_ seq: UInt64, deviceID: UUID, hubID: UUID, id: UUID = UUID()) -> Self   // uppercase ids
  }
  ```
  `keybox` (inside `transport_switched`) is not decoded in Phase 1; the unknown key is ignored.
- Fixture sections (Kit reads them now; Go reading them is the Go hub session's, Ruling 11):
  - `action`: cases `ordered_pending` (`json` = the phone's payload with `action_seq: 7`, `device_id`/`hub_id` from the fixture UUIDs; `kit` = `{action_seq: 7, record_name: "a-<DEVICE>-7"}`), `legacy_pending` (no `action_seq`; `kit.action_seq` null), `ordered_echo_applied` (the hub's echo with `result`), `unknown_future_key`.
  - `control`: `skip_to` (`seq`, both ids), `resend_from`, `transport_switch_rejected` (`reason`, `retry_after_s`), `transport_switched_with_keybox` (decodes, keybox ignored), `unknown_kind`.

- [ ] **Step 1: Write the failing tests**
  - `HubContractFixtureTests.testActionCasesRoundTrip`: each `action` case decodes; `actionSeq` and the ordered record name equal `kit`; re-encoding with `RelayCoder` gives JSON equal (as objects) to `json` with the fixture's keys — no key the Go `wire.ActionRequest` lacks.
  - `HubContractFixtureTests.testControlCasesDecode`: each `control` case decodes with the `kit` values; `unknown_kind` keeps its raw kind.
  - `HubContractFixtureTests.testDeviceGrantCasesDecodeAndIgnoreNewKeys` asserts `runsOrderedActions` against `kit.ordered_actions`.
  - `RelayPayloadTests.testALegacyActionEncodesNoActionSeq` (byte check against today's encoding of a fixed payload) and `testSkipToCarriesBothIds` (uppercase `device_id`, `hub_id`, `seq`).
  - `GoSealedEnvelopeTests.testTheOrderedActionNameMatchesTheGoHub`: `orderedRecordName(deviceID:actionSeq: 1)` equals the `relayToPhone` case's `id`, and its wire name under the fixture `K_meta` equals the case's `wireName`.
- [ ] **Step 2: Run, expect failure** — `make kit-test FILTER='HubContractFixtureTests|RelayPayloadTests|GoSealedEnvelopeTests'` — FAIL.
- [ ] **Step 3: Implement** and edit the fixture. Check `go test ./internal/hub/wire -run TestHubContractFixture` still passes (its decoder ignores unknown top-level sections).
- [ ] **Step 4: Run** — the Step 2 filter plus `ActionStatusTests|DeviceGrantStartTests|KeyboxTests`, `make test-swift FILTER='RelayProcessorTests'` — PASS.
- [ ] **Step 5: Lint and guard check.**
- [ ] **Step 6: Commit** — `feat(kit): action_seq, control payloads and ordered_actions on the wire (#1240)`

### Task 4: `SecureTransport` passes conditional writes through

**Depends on:** Task 1, Task 3

**Files:**
- Create: `WatchtowerKit/Sources/WatchtowerSync/Secure/SecureTransport+Conditional.swift`
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Secure/SecureTransport.swift:24-26,152,360-385` (relay kinds per role: `control` for the phone role only; `accept` copies `recordSeq` onto the opened record)
- Test: `WatchtowerKit/Tests/WatchtowerSyncTests/SecureTransportTests.swift`

**Interfaces:**
- Produces:
  - `nonisolated public var isConditional: Bool` — the inner transport conforms to `ConditionalTransport`.
  - `public func saveSealed(_ items: [ConditionalSave]) async throws -> [SaveOutcome]` — items are records `seal` already returned (wire names); forwarded unchanged. Throws `SecureTransportError.notConditional` when the inner transport is not.
  - `public func deleteSealed(_ items: [ConditionalDelete]) async throws -> [DeleteOutcome]` — wire names, forwarded.
  - `public func openConflict(_ current: CloudRecord) throws -> CloudRecord?` — opens a conflict's current record through the same path as `changes` (rollback guard included); nil when it does not open.
  - Phone role: `seal` accepts frame kind `control`; `changes` opens `control` frames from the hub (h2p) and the phone's own (p2h). Hub role unchanged (`control` stays `unknownKind`).

- [ ] **Step 1: Write the failing tests**
  - `testAConditionalSaveForwardsTheSealedBytes`: phone seals `a-<DEV>-1`, `saveSealed([.init(record:, expect: .absent)])` → `.saved`; the inner store holds the same envelope under the wire name.
  - `testAConflictsCurrentRecordOpens`: the hub's echo at that name; `openConflict` returns an `action` frame with status `applied` and the `recordSeq`.
  - `testThePhoneOpensHubControlsAndTheHubStillDropsThem`: a hub-sealed `c-<uuid>` opens on the phone; a phone-sealed control in the hub's `changes` is reported `unknownKind`.
  - `testAPlainTransportIsNotConditional`: a stub `CloudSyncTransport` → `isConditional == false`, `saveSealed` throws `.notConditional`.
- [ ] **Step 2: Run, expect failure** — `make kit-test FILTER=SecureTransportTests` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — `make kit-test FILTER='SecureTransportTests|RelayFeedTests|ActionOutboxTests'`, `make test-swift FILTER='RelayProcessorTests'` — PASS.
- [ ] **Step 5: Lint and guard check.**
- [ ] **Step 6: Commit** — `feat(kit): SecureTransport forwards conditional mailbox writes (#1240)`

### Task 5: The outbox in the replica

**Depends on:** none

**Files:**
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Replica/ReplicaStore.swift:155-177,222-231` (`pending_actions` gains `action_seq INTEGER` and `delivery TEXT CHECK(delivery IN ('queued','sent','settled','undelivered'))`, both NULL for a legacy row, added in place by `upgradeSidecarColumns`; a unique index on `action_seq` where not NULL; new tables `outbound_controls` and `handled_controls`, which survive the format wipe like `pending_actions`)
- Create: `WatchtowerKit/Sources/WatchtowerSync/Replica/ReplicaStore+Outbox.swift`
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Replica/ReplicaStore+PendingActions.swift` (`PendingAction.actionSeq: UInt64?`, `delivery: Delivery?`; `sweepPendingActions` skips rows with `delivery` set — Ruling 5)
- Test: Create `WatchtowerKit/Tests/WatchtowerSyncTests/ReplicaOutboxTests.swift`

**Interfaces:**
- Produces (`ReplicaStore+Outbox.swift`), every write one transaction:
  ```swift
  public enum Delivery: String, Sendable { case queued, sent, settled, undelivered }
  public struct OutboxRow: Equatable, Sendable { public let actionID: String; public let actionSeq: UInt64; public let wireName: String; public let envelope: Data; public let delivery: Delivery }
  public struct QueuedControl: Equatable, Sendable { public let id: String; public let kind: ControlKind; public let wireName: String; public let envelope: Data }
  extension ReplicaStore {
      func orderedActionsEnabled() throws -> Bool                 // replica_meta `ordered_actions` = "1"
      func enableOrderedActions() throws                          // sticky (Ruling 3)
      func nextActionSeq() throws -> UInt64                       // replica_meta `action_seq_next`, 1 when absent; unreadable → throws
      /// Inserts the row (`queued`) and moves the counter from `seq` to `seq + 1` only if it still reads `seq`; false = lost the race, nothing written.
      func insertOrderedAction(_ action: ActionRequestPayload, entityRecordName: String?, sealed: CloudRecord, seq: UInt64) throws -> Bool
      func outboxRows(_ deliveries: Set<Delivery>) throws -> [OutboxRow]       // by action_seq
      func setDelivery(_ delivery: Delivery, actionIDs: [String]) throws
      /// `sent`/`queued` rows at or above `seq` become `queued`; returns the first of them, nil when none.
      func requeue(fromSeq seq: UInt64) throws -> UInt64?
      /// `state = failed`, `delivery = undelivered`, the local message (Ruling 16).
      func markUndelivered(actionIDs: [String], message: String) throws
      func undeliveredActions(from db: Database) throws -> [PendingAction]
      func outboxCounts(from db: Database) throws -> (queued: Int, undelivered: Int)
      func dismissUndelivered() throws -> Int
      func enqueueControl(_ control: QueuedControl) throws
      func queuedControls() throws -> [QueuedControl]                         // insertion order
      func controlWritten(id: String) throws
      /// true the first time a hub control id is handled; ids older than 15 days are pruned (sim "Bounded state").
      func markControlHandled(id: String, at: Date) throws -> Bool
      func pruneHandledControls(before: Date) throws
  }
  ```
- `PendingAction.State` stays `pending | failed`; overlay readers keep filtering on it, so undelivered rows read as failed everywhere they read today.

- [ ] **Step 1: Write the failing tests** (`ReplicaOutboxTests`, in-memory replica with `TestE2E.opener()`)
  - `testTheCounterAdvancesOnlyWithAnInsertedRow`: `nextActionSeq() == 1`; insert with seq 1 → true, next 2; insert with seq 1 again → false and nothing written; next still 2.
  - `testRequeueReturnsTheFirstRowStillHeld`: rows 1 sent, 2 settled, 3 sent, 4 undelivered → `requeue(fromSeq: 1) == 1`, rows 1 and 3 queued, 4 unchanged.
  - `testUndeliveredRowsReadAsFailed` and `testDismissRemovesOnlyUndelivered`.
  - `testTheSilentSweepSkipsOrderedRows`: a legacy and an ordered row both older than 24 h → only the legacy one fails.
  - `testControlsQueueInOrderAndHandledIdsAreRememberedOnce`.
  - `testAReplicaFromBeforeTheOutboxOpensWithItsRows`: a file with today's `pending_actions` schema and one row opens; the row reads with `actionSeq == nil`, `delivery == nil`.
  - `testTheOrderedFlagAndCounterSurviveTheFormatWipe`.
- [ ] **Step 2: Run, expect failure** — `make kit-test FILTER=ReplicaOutboxTests` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — `make kit-test FILTER='ReplicaOutboxTests|ReplicaTests|ReplicaResetTests|ActionOutboxTests'` — PASS.
- [ ] **Step 5: Lint and guard check.**
- [ ] **Step 6: Commit** — `feat(kit): the action outbox and control queue in the replica (#1240)`

### Task 6: `ActionOutbox` — the ordered path

**Depends on:** Task 4, Task 5

**Files:**
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Relay/ActionOutbox.swift`
- Create: `WatchtowerKit/Sources/WatchtowerSync/Relay/ActionOutbox+Ordered.swift`
- Test: `WatchtowerKit/Tests/WatchtowerSyncTests/ActionOutboxTests.swift` (existing tests unchanged), Create `ActionOutboxOrderedTests.swift`

**Interfaces:**
- Consumes: Tasks 3–5.
- Produces:
  ```swift
  public struct OutboxFlushReport: Equatable, Sendable { public var written: Int; public var stoppedOn: TransportRefusal?; public var undelivered: Int }
  extension ActionOutbox {
      public func setHubID(_ hubID: String?)                  // the payload's hub_id and the control's hub_id
      public func orderedActions() throws -> Bool              // the replica's sticky flag
      public func enableOrderedActions() throws
      public func flush() async throws -> OutboxFlushReport
      /// sim rule 5/6: rows from `seq` go out again; a missing start writes skip_to(first) (Ruling 1).
      public func resendFrom(_ seq: UInt64) throws
      public func retryUndelivered(id: String) async throws -> String     // the new action id
      public func dismissAllUndelivered() throws -> Int
  }
  ```
- `enqueue` keeps its signature. Legacy (flag off, or the transport `!isConditional`): today's body. Ordered: read `nextActionSeq()`, build the payload (`actionSeq`, `hubID`), seal under `orderedRecordName(deviceID:actionSeq:)`, `insertOrderedAction(… seq:)`; on false (another enqueue won during the seal) reseal with the next seq, at most 3 tries, then throw `ActionOutboxError.busy`. Then a detached `flush()`; a refused flush never fails the enqueue (the row is queued, which is the point of the outbox).
- `flush()`: queued controls first (`.absent`; `.saved` or any `.conflict` → written; a transient refusal stops controls and actions for this pass; a permanent one drops the control, logged), then `outboxRows([.queued])` in seq order as one `saveSealed` batch with `.absent`. Per outcome in seq order:
  - `.saved` → `sent`.
  - `.conflict(current)`: identical bytes → `sent`; `openConflict` gives an `action` frame with this `action_seq` and a non-`pending` status → `sent`, then `applyEcho` with it; otherwise one `.seq(current.recordSeq)` overwrite of the same bytes (its own outcome handled the same way, no third try).
  - `.refused(transient)` → stays `queued`, `stoppedOn` set; later outcomes in the batch are still recorded (Ruling 7), the next pass starts from the first queued row.
  - `.refused(.permanent)` → `markUndelivered` with "Not delivered to your Mac." and go on.
- `applyEcho` (ordered echo = `actionSeq != nil`): any echo of a `queued` row makes it `sent`; `held` without `reason` changes no overlay (Ruling 4); `held` with a reason and `received` as today; final: `applied` removes the row (as today, observer fired), `failed`/`expired`/`cancelled` mark it failed and `settled`. Returns whether the echo was final, so the feed deletes it.
- `resendFrom(m)`: `first = requeue(fromSeq: m) ?? nextActionSeq()`; when `first > m`, queue `skip_to(first)` (sealed once now, `ControlPayload.skipTo(first, deviceID:, hubID:)`). Seqs in `[m, first)` with no row were settled or dismissed and are not listed again; rows there that are `undelivered` are already listed.
- `retryUndelivered(id)`: opens the row's envelope (`opener.openOwnRelay`), enqueues a new action with the same kind, entity and params (new id, `createdAt = now`, next seq), then deletes the old row; a locked keychain throws before anything changes.
- `sweepSilentPending` is unchanged for legacy rows and skips ordered ones (Task 5).

- [ ] **Step 1: Write the failing tests** (`ActionOutboxOrderedTests`; phone `SecureTransport` over `InMemoryCloudTransport`, `TestE2E`)
  - `testALegacyHubKeepsTodaysPath`: flag off → record name `action-<uuid>`, no `action_seq`, nothing in `outbound_controls`, saved through plain `save`.
  - `testOrderedEnqueueWritesAGaplessSeriesInOrder`: three enqueues → `a-<DEV>-1…3`, each `.absent`, all `sent`.
  - `testTwoConcurrentEnqueuesGetConsecutiveSeqs`: two `async let` enqueues → seqs {1, 2}, counter 3, both rows present.
  - `testATransientRefusalStopsTheFlushAndTheNextPassResumes` (twin of `TestRefusedActionWriteRetried`).
  - `testAPermanentRefusalListsTheActionAsNotDelivered` and the flush goes on to the next row.
  - `testAConflictWithIdenticalBytesCountsAsSent`, `testAConflictWithTheHubsEchoSettlesTheRow`, `testAConflictWithAnythingElseIsOverwrittenUnderItsSeq`.
  - `testAGapHoldLeavesTheOverlayAlone`: `held` without reason → `echoStatus == nil`; with `agent_busy` → `.held`.
  - `testResendFromRequeuesFromTheGap` and `testResendFromBelowWhatTheOutboxHoldsWritesSkipTo` (`skip_to(first)` with uppercase `device_id` and the `hub_id`).
  - `testRetryOfAnUndeliveredActionGoesToTheEndOfTheQueue`: rows 1 (undelivered), 2 (sent) → Retry gives seq 3 with the same params and a new id; row 1 is gone.
  - `testDismissAllNeverResends`: after Dismiss All a `resendFrom(1)` writes only `skip_to`.
- [ ] **Step 2: Run, expect failure** — `make kit-test FILTER=ActionOutboxOrderedTests` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — `make kit-test FILTER='ActionOutboxOrderedTests|ActionOutboxTests|RelayFeedTests|PermissionAllowRuleTests'` — PASS, `ActionOutboxTests` unchanged.
- [ ] **Step 5: Lint and guard check.**
- [ ] **Step 6: Commit** — `feat(kit): ordered actions in the outbox — seq, flush, resend and skip (#1240)`

### Task 7: `RelayFeed` — controls, echo deletes, sim twins

**Depends on:** Task 6

**Files:**
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Relay/RelayFeed.swift:193-235` (route `control`; collect deletes; one `deleteSealed` batch at the end of the cycle, after the token is stored)
- Create: `WatchtowerKit/Tests/WatchtowerSyncTests/Support/OrderedHubFake.swift` (test-only hub over `TestE2E.hubTransport`: applies `last + 1`, echoes every action read with `.seq`, holds ahead of a gap and writes `resend_from(last + 1)` once per gap, honours `skip_to` within `last + 1 + 65536`, deletes the controls it read — the Go hub's `order.go`/`control.go` rules, nothing more)
- Create: `WatchtowerKit/Tests/WatchtowerSyncTests/OrderedSimTwinTests.swift`
- Test: `RelayFeedTests.swift`

**Interfaces:**
- Consumes: `ActionOutbox.applyEcho` (returns final), `resendFrom`, `ReplicaStore.markControlHandled`.
- Produces: in the feed —
  - `action` echo of an ordered row, final → delete under `.seq(record.recordSeq)` by `record.sealed.wireName`.
  - `control` from the hub: decode `ControlPayload`; one whose `device_id` is not this phone or whose `hub_id` is another hub is dropped with a log line and deleted; `markControlHandled(id)` false → deleted unread (second copy); `resend_from(seq)` → `outbox.resendFrom`; `transport_switch_rejected` → logged (Phase 1 never asks) and deleted; `transport_switched`, `hub_on_relay` and unknown kinds are left in the mailbox, not marked handled, logged once per kind (Ruling 9).
  - Deletes are best effort: one try per read, outcome logged by class; the CloudKit hub hygiene and the relay TTL are the fallbacks (Ruling 8). A delete never fails the cycle.
  - After the deletes, the feed calls `outbox.flush()` when it requeued anything, so a `resend_from` is answered in the same pass.
- Sim twins (names as `relay/sim/sim_test.go`, spec §11), phone + `OrderedHubFake` over one `InMemoryCloudTransport`: `testActionsAppliedInOrderOnce` (a stale copy of a3 is echoed again and the mailbox ends up empty), `testGapTriggersResendFrom`, `testSkipToMarksUndelivered`, `testRefusedActionWriteRetried`, `testPhoneSkipToRetriedUntilWritten`. The hub-side twins and the switch twins wait for Phases 2–3.

- [ ] **Step 1: Write the failing tests**
  - `RelayFeedTests.testAFinalOrderedEchoIsDeletedUnderItsSeq`, `testANonFinalEchoStays`, `testALegacyEchoIsNeverDeleted` (today's behaviour).
  - `RelayFeedTests.testResendFromIsHandledOnceAndDeleted` (two copies of one control id → one requeue, both deleted), `testAControlNamingAnotherDeviceIsDropped`, `testUnknownControlKindsStayInTheMailbox`.
  - `RelayFeedTests.testAFailedDeleteNeverFailsTheCycle`.
  - The five sim twins above.
- [ ] **Step 2: Run, expect failure** — `make kit-test FILTER='RelayFeedTests|OrderedSimTwinTests'` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — `make kit-test FILTER='RelayFeedTests|RelayFeedRecordingUploadTests|OrderedSimTwinTests|ActionOutboxOrderedTests|ActionOutboxTests'` — PASS.
- [ ] **Step 5: Lint and guard check.**
- [ ] **Step 6: Commit** — `feat(kit): the relay feed reads controls and deletes settled echoes (#1240)`

### Task 8: The phone runs the ordered path

**Depends on:** Task 2, Task 7

**Files:**
- Modify: `WatchtowerMobile/Sources/App/Hubs/HubSession.swift:441-456,481,930-1019,1101-1160` (outbox `setHubID`; the grant turns the ordered path on — on every `keyboxSignal` and `indexStoredRows`, a linked grant with `runsOrderedActions` calls `outbox.enableOrderedActions()`; `flush()` after `feed.pollOnce()` in `performFetch` and `applyBuffered`, on `setActive(true)` and on `keysBecameAvailable`; `@Observable` `outboxBacklog: OutboxBacklog`)
- Create: `WatchtowerMobile/Sources/App/Hubs/OutboxBacklog.swift` (`struct OutboxBacklog: Equatable { var queued: Int; var undelivered: Int; var lastFlushStopped: Bool; static let empty }`, refreshed by a `ResilientObservation` over `ReplicaStore.outboxCounts` plus the last `OutboxFlushReport`)
- Modify: `WatchtowerMobile/Sources/App/AppRoot.swift:710-720` (`pendingActionCount` also counts `queued` ordered rows, so a removal's "not sent" count stays honest)
- Test: Create `WatchtowerMobile/Tests/OrderedActionsWiringTests.swift`; `make mobile-gen`

**Interfaces:**
- Consumes: Tasks 2, 6, 7.
- Produces: `HubSession.outboxBacklog`, `HubSession.retryUndelivered(id:) async`, `HubSession.dismissAllUndelivered()`; both log and keep the row on a failure (a locked phone: "Unlock your iPhone to retry." surfaced by Task 9's model).
- No change for a legacy hub: no flush call reaches the transport when the flag is off and `outbound_controls` is empty (the flush returns at once).

- [ ] **Step 1: Write the failing tests** (`OrderedActionsWiringTests`, in-memory transport, test grant)
  - `testAGrantWithOrderedActionsTurnsTheOrderedPathOn`: before the grant an answer goes out as `action-<uuid>`; after a grant with `ordered_actions: 1`, the next as `a-<DEV>-1`; the flag survives a session restart.
  - `testAGrantWithoutTheFlagKeepsTodaysPath`.
  - `testAFetchFlushesWhatWasQueued`: a scripted transient refusal on enqueue → `outboxBacklog.queued == 1`, `lastFlushStopped`; the next `refresh(.manual)` writes it → 0.
  - `testARemovalCountsQueuedOrderedActionsAsNotSent`.
- [ ] **Step 2: Run, expect failure** — `make mobile-gen`, then `make mobile-test SIM='iPhone 17 Pro' MOBILE_FILTER=OrderedActionsWiringTests` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — `make mobile-test SIM='iPhone 17 Pro' MOBILE_FILTER='OrderedActionsWiringTests|FetchCadenceWiringTests|BackgroundWorkTests|AppRootWiringTests|AppRootRelinkTests|MultiHubEnvironmentTests|SessionInputWiringTests|PermissionCardTests'` — PASS, the last two unchanged.
- [ ] **Step 5: Lint and guard check.**
- [ ] **Step 6: Commit** — `feat(mobile): the phone sends ordered actions to a hub that runs them (#1240)`

### Task 9: Now → Waiting to send and Not delivered

**Depends on:** Task 8

**Files:**
- Modify: `WatchtowerMobile/Sources/Features/Now/NowModel.swift` (`outbox: NowOutboxRows?` from `OutboxBacklog` + the Mac's display name)
- Modify: `WatchtowerMobile/Sources/Features/Now/NowView.swift:5-7,60-80` (`NowRoute.notDelivered`; the group under the Mac status chip)
- Create: `WatchtowerMobile/Sources/Features/Now/NotDeliveredModel.swift`, `NotDeliveredView.swift`
- Modify: `WatchtowerMobile/Sources/App/DemoSeed.swift` + Create `WatchtowerMobile/Sources/App/DemoSeed+Outbox.swift` (a demo-only state with two undelivered rows and three queued ones, sealed with the demo keys, reached from the tour only)
- Test: Create `WatchtowerMobile/Tests/NotDeliveredModelTests.swift`; extend `NowWiringTests`, `OrangeToneTests`, `ScreenshotTourTests`; `make mobile-gen`

**Interfaces:**
- `NowOutboxRows` (copy in the model): **Waiting to send** with the count, shown only while `queued > 0 && lastFlushStopped` (Ruling 12; no "Relay unavailable" banner in Phase 1); **Not delivered** with the count and a chevron, shown while `undelivered > 0`. Tones: count text `.secondary`, the Not delivered row `.red` with role `.status`; never orange.
- `NotDeliveredModel` (copy in the model, mockup §5): title "Not delivered"; footer "These actions never reached <Mac name>. Retry sends them again, after anything you did since."; one row per undelivered action, oldest first: a one-line summary from `ActionSummary.text(for:snapshot:)` (per kind: `ask_answer` → "Answer “<ask title>” — <verdict>", `board_target_status` → "Move “<target>” to <column>", `board_comment_add`/`reply` → "Comment on “<target>”", `board_target_create` → "New task “<text>”", `session_start` → "Start a session for “<target>”", `session_input` → "Send “<first 60 chars>”", `session_stop`/`session_finish_request`/`session_interrupt` → "Stop/Finish/Interrupt “<session>”", `permission_answer` → "Allow/Deny a permission request", `automation_run` → "Run “<automation>”", any other kind → "An action from this iPhone"; a missing title falls back to the kind's noun), the time ("Today 09:58" via the phone's existing relative formatter), a **Retry** button per row, and a destructive **Dismiss All** (`.red`, role `.status`) with a confirmation "Dismiss N actions? They won't be sent." Retry in flight disables that row; a failed Retry shows the model's message under the row.
- Rows come from `ReplicaStore.undeliveredActions` through the existing `ResilientObservation`; the list pops back to Now when it empties.
- Screenshot tour (the phone's design shots; Ruling 14): `now-waiting-to-send`, `now-not-delivered-row`, `not-delivered-list`, `not-delivered-retrying`, each light and dark, on the demo outbox state.

- [ ] **Step 1: Write the failing tests**
  - `NotDeliveredModelTests`: summary per kind (table-driven over the kinds above), the footer names the Mac, rows oldest first, Dismiss All copy with the count, a locked-keychain Retry failure text.
  - `NowWiringTests.testWaitingToSendShowsOnlyWhenAFlushStopped`, `testNotDeliveredRowShowsTheCount`.
  - `OrangeToneTests` gains the two new models' `toneUses` (no orange).
  - `ScreenshotTourTests` registers the four shots (skipped without `WATCHTOWER_SHOTS_DIR`, as today).
- [ ] **Step 2: Run, expect failure** — `make mobile-gen`, `make mobile-test SIM='iPhone 17 Pro' MOBILE_FILTER='NotDeliveredModelTests|NowWiringTests|OrangeToneTests'` — FAIL.
- [ ] **Step 3: Implement** the models, views and demo state; colours only through `PhoneTone`, components from `Sources/DesignSystem/`.
- [ ] **Step 4: Run** — the Step 2 filter plus `ScreenshotTourTests|SettingsWiringTests` — PASS; then `make mobile-shots SIM='iPhone 17 Pro'` and look at the four new shots against `docs/design/mockups/relay-client/index.html` §5.
- [ ] **Step 5: Lint and guard check.**
- [ ] **Step 6: Commit** — `feat(mobile): Now shows Waiting to send and the Not delivered list (#1240)`

### Task 10: User guide

**Depends on:** Task 9 (the final copy)

**Files:**
- Modify: `docs/guide/features/iphone.md` (a "When something is not delivered" subsection under **Using it**: what **Waiting to send** means, when **Not delivered** appears in Phase 1 — the Mac refused a change for good, e.g. its iCloud folder was removed — what **Retry** does (sends it again after anything done since) and that **Dismiss All** drops them for good; one sentence in **How it works** that the Mac applies a phone's changes in the order they were made; per `docs/guide/WRITING.md`, bold for UI labels, no internals, no ids)
- Optionally a Learn card per `docs/guide/WRITING.md` "Learn cards" only if the section meets its bar (a feature the owner acts on); Phase 4 adds the relay parts.

- [ ] **Step 1:** Edit the page; keep it under the 8 KB section cap.
- [ ] **Step 2: Run** — `go test ./docs/guide` — PASS (`TestGuideCardsValid` included).
- [ ] **Step 3: Commit** — `docs(guide): changes from the iPhone go in order; Not delivered (#1240)`

### Task 11: Phase gate and the feature note

**Depends on:** Tasks 1–10

**Files:**
- Modify: `docs/features/mobile-companion.md` — the **Rollback and replay (D4)** bullet (today's "no strict per-device sequence gate" holds for the legacy path only; an ordered hub orders by `action_seq`, spec §5, Go hub `order.go`); **Deliberate re-sends** (byte-for-byte resends now also from `resend_from`); "Replica, outbox and relay feed (A3, A11)" (`pending_actions` as the outbox — `action_seq`, `delivery`, the counter, `outbound_controls`, `handled_controls`; `ActionOutbox` flush, rule 3, refusals; `RelayFeed` controls and echo deletes; the ordered rows' exemption from the 24 h sweep); "Transport: scopes, errors and the local buffer" (`ConditionalTransport` on CloudKit outside the engine, `record_seq`, the local delete check); the hygiene line (echoes and controls are deleted by the phone on the ordered path, hub hygiene stays the fallback); a new bullet "**Ordered actions (relay client Phase 1).**" naming the negotiation (`ordered_actions`, sticky), the shared fixture sections and the Not delivered list; Tests line gains the new test classes.

- [ ] **Step 1: Desktop + Kit suite** — `make test-swift > "${TMPDIR:-/tmp}/p1-swift.log" 2>&1; echo "exit=$?"` — Expected `exit=0`.
- [ ] **Step 2: Phone suite** — `make mobile-test SIM='iPhone 17 Pro' > "${TMPDIR:-/tmp}/p1-mobile.log" 2>&1; echo "exit=$?"` — Expected `exit=0`.
- [ ] **Step 3: Lint** — `make lint-all` — no new issues.
- [ ] **Step 4: Go contract** — `go test ./internal/hub/wire ./docs/guide` — PASS (the fixture's new sections leave the Go decoder green).
- [ ] **Step 5: Guard files** — `git diff --stat origin/main --` the six guard files — empty.
- [ ] **Step 6: Update the feature note** as listed (English, no ids).
- [ ] **Step 7: Manual device check** (spec §11): a signed phone linked to a signed Mac running today's Desktop hub — answer an ask, move a card, send a session line: each behaves as before (legacy path; no `a-` record in RelayZone). With a Go hub announcing `ordered_actions` where one is available: two quick lines arrive in order; airplane mode → **Waiting to send** → back online → sent.
- [ ] **Step 8: Commit** — `docs(mobile): the ordered action path after relay client Phase 1 (#1240)`

---

## Rulings

Gaps and contradictions found while planning, decided here. Each: what, why, cost if wrong.

1. **What Not delivered lists in Phase 1.** Rows the transport refused for good (`.permanent`), and nothing else; a `resend_from` asking for seqs the phone holds no row for writes `skip_to` and lists nothing, because a row leaves the outbox only after a final echo or Dismiss All. Sim rule 6's "reinstall" case does not exist here: a re-pair always opens a fresh replica (`LinkingViewModel` `fresh: true`), which restarts the counter with the hub's own re-link reset (protocol §7.5 p. 8). `hub_on_relay` (rule 16 / R32) joins in Phases 3–4. *Cost if wrong:* an action lost some other way is skipped without a line on the phone.
2. **The counter lives in `replica_meta` and is drawn in the insert's transaction (compare-and-set, reseal on a lost race).** `SeqAllocator` reserves blocks and would leave holes, which the hub reads as a gap. *Cost:* up to three seals per enqueue under contention; `ActionOutboxError.busy` past that.
3. **Ordered mode is sticky per replica** once a linked grant carries `ordered_actions ≥ 1`; a grant that later drops it does not switch back. The hub runs a phone ordered from its first ordered action (protocol §7.5 p. 1); flipping back would mix `a-` and `action-` records under one hub. *Cost:* a Go hub replaced by a Swift hub without a re-link receives `a-` records it does not expect until the owner re-links.
4. **A gap `held` (no reason) leaves the overlay alone.** It means "arrived ahead of a gap", not "the Mac picked it up" or a held line; recording it would change what the PROJ-16/21 screens say. *Cost:* the phone does not show that the Mac is waiting on a gap; Interrupt or a permission answer looks "Sending…" until the gap closes (ask #796 accepted cost).
5. **Ordered rows are exempt from the 24 h silent-pending sweep.** On the ordered path the protocol itself resends and settles; a locally failed row the owner dismisses would later be missing when the hub asks for it. *Cost:* a chip stays "Waiting for your Mac" until the Mac answers or the hub is unlinked.
6. **CloudKit: conditional writes go outside `CKSyncEngine` (`modifyRecords`, `.ifServerRecordUnchanged`); `recordSeq` is a local per-record counter over the stored system fields; a delete checks that counter and then deletes unconditionally.** CloudKit change tags are strings, the engine reports conflicts asynchronously, and CloudKit has no conditional delete. *Cost:* a hub write landing between the phone's fetch and its delete is lost; on the ordered path the phone deletes only final echoes and read controls, which the hub does not rewrite (a repeat echo carries the same final outcome). One extra CloudKit call per flush and per feed cycle with deletes.
7. **A flush batch records every outcome.** The queued run goes out as one call; a row after a transient failure that still landed is `sent`. Sim rule 1 stops at the first failure to keep order, but the hub orders by seq anyway (holds, then `resend_from`). *Cost:* an extra `resend_from` round trip after a partial batch.
8. **Echo and control deletes are best effort, one try.** Same as the Go hub's `deleteControl`; hub hygiene (CloudKit, 7 days) and the relay TTL (14 days) are the fallbacks (spec §5 p. 8). *Cost:* a leftover record until hygiene.
9. **Hub controls Phase 1 cannot act on stay in the mailbox.** `transport_switched`, `hub_on_relay` and unknown kinds are not deleted or marked handled; `transport_switch_rejected` is deleted (the phone never asks in Phase 1). The Go hub writes the first two only after its own switch work, which needs a Phase 3 phone. *Cost:* Phase 3 must re-read them (token reset or the transport marker, sim rule 12a).
10. **`control` is accepted only in the phone role of `SecureTransport`.** "The Swift Desktop hub is not extended": it keeps dropping controls as an unknown kind, as the spec's mixed-version rule expects. *Cost:* none for the Go hub, which has its own opener.
11. **The shared fixture gains `action` and `control` sections, read by the Kit only.** Hub code is out of this plan; the Go decoder ignores unknown sections, so `go test ./internal/hub/wire` stays green. Reading them from `TestHubContractFixture` is a follow-up for the Go hub session (to be filed as an ask on #1240 when Task 3 lands). The opposite direction is already pinned: the Kit opens the Go-sealed `a-<DEVICE>-1` echo (`go-sealed.json`). *Cost:* until the Go test reads them, a Go-side key rename is caught only by the Kit test against the fixture, not by Go CI.
12. **Waiting to send shows without the "Relay unavailable" banner.** The banner belongs to the hosted relay (§9, Phase 4); on CloudKit the row shows while queued rows exist and the last flush stopped on a refusal. *Cost:* a brief row during a short iCloud outage.
13. **The user guide is updated in Phase 1**, not only in Phase 4 (spec §14), because the Not delivered list ships now and CLAUDE.md requires the guide page in the same PR as a user-facing change. Phase 4 adds the transport and subscription parts. *Cost:* none.
14. **The phone has no `DesignShotCatalog`** (it is the Desktop's, `WatchtowerDesktop/Tests/DesignShots`). The workbench rule is met by the phone's equivalent, `ScreenshotTourTests` over a demo state (`make mobile-shots`), with the copy in the models under test and colours through `PhoneTone`. *Cost:* none.
15. **`epoch_ack` is sent from Phase 3**, with the phone's epoch keys; `MailboxAddressing` and `PagedChanges` come with the hosted relay in Phase 2. Spec §5 p. 7 lists `epoch_ack` among the control records; the queue built here carries it unchanged. *Cost:* the Go hub records no acks from phones until Phase 3; it retires no keys before then anyway.
16. **An undelivered row is an overlay `failed` row with `delivery = undelivered`.** Feature screens then show it failed with their own Retry and Dismiss, which mean the same as the list's (a new action at the end; never resent). *Cost:* the same action appears on its feature screen and in the list.
