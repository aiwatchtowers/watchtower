# Relay client Phase 1 — ordered actions on the phone Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The phone side of the one action path (spec §5): a gapless per-hub `action_seq` inside the sealed payload, `pending_actions` as a real outbox (`queued | sent | settled | undelivered`, with the epoch each row was sealed in) flushed in order with conditional writes, `ConditionalTransport` on CloudKit and in the in-memory transport, a durable control-record queue (`skip_to` out; `resend_from` and `transport_switch_rejected` in), echo deletes, and the owner-facing **Not delivered** list with **Retry** and **Dismiss All** plus the **Waiting to send** count on Now. The phone uses the ordered path only for a hub whose `device_grant` carries `ordered_actions`; every other hub (today's Swift hub) keeps today's path byte for byte.

**Architecture:** The seam grows by one optional protocol, `ConditionalTransport` (Kit `Sync/`), implemented by `InMemoryCloudTransport` and by `CloudKitTransport` (direct `modifyRecords` outside `CKSyncEngine`, `.ifServerRecordUnchanged`, behind an injectable database seam). `SecureTransport` passes conditional writes through for already-sealed records and opens a conflict's current record. The outbox's state lives in the replica (`pending_actions` gains `action_seq`, `epoch`, `record_seq`, `delivery`, `sent_at`; new `outbound_controls` and `handled_controls`; the counter in `replica_meta`). `ActionOutbox` owns enqueue, a single-flight flush serialised with `resend_from` handling, echo settlement, the 24 h withdrawal to Not delivered, `skip_to`, Retry, Dismiss and Dismiss All; `RelayFeed` routes `control` frames and deletes final echoes and read controls. `HubSession` turns the ordered path on from the grant, flushes after every fetch and enqueue, and publishes the backlog for Now. The hub's order, holds and echoes are the Go hub's (ask #802, `internal/hub/actions`); the Swift Desktop hub is not extended.

**Tech Stack:** Swift 5.10 language mode, SwiftUI, GRDB (SQLCipher fork), CloudKit; packages `WatchtowerKit` (`WatchtowerSync`), `WatchtowerMobile` (xcodegen, iOS 17), XCTest.

**Spec:** `docs/superpowers/specs/2026-10-29-relay-client-design.md` — §5 (actions: one order, one outbox, both transports), §3 (`ConditionalTransport`), §11 (testing), §13 row 1, §14, Decisions. **Wire contract:** `docs/superpowers/specs/2026-10-31-hub-phone-protocol-design.md` §4.5, §5.4, §7.1–§7.6, §7.8, §8, §10 and the Go hub's behaviour (`internal/hub/actions/order.go`, `control.go`, `internal/hub/hubtest/phone.go` — the Go phone emulator this plan mirrors). **Client rules:** relay `sim/README.md` rules 1–7a, 15, "Bounded state". **Mockups:** `docs/design/mockups/relay-client/index.html` §5 (Task 9 adds the Phase 1 states). Feature note: `docs/features/mobile-companion.md`. Board: new target under #1240.

## Global Constraints

- **Today's path stays byte for byte for every hub without `ordered_actions`.** Legacy rows (`action_seq` NULL, `delivery` NULL) are enqueued, saved through `CKSyncEngine`, echoed, swept (24 h) and dismissed exactly as now; every existing test keeps its assertions. The demo seed's grant carries no flag, so demo mode stays legacy.
- **Wire bytes match the Go hub.** Ordered action: plain name `a-<DEVICE_ID>-<action_seq>` (`DEVICE_ID` = the canonical uppercase `UUID.uuidString`), frame kind `action`, payload `ActionRequestPayload` + `action_seq` (u64, absent on the legacy path), `status: pending`. Control: plain name `c-<uuid>` (uppercase `uuidString`), frame kind `control`, payload `{id, kind, device_id, hub_id, seq?, epoch?, target?, by?, at?, reason?, retry_after_s?}`; a phone control always carries `device_id` and `hub_id` (the Go hub drops a `skip_to` without them, or with `m > last_applied + 1 + 65536`). Keys go through `RelayCoder` (snake case, seconds since 1970).
- **Sim rule 1 and 7a, literally.** A flush writes one record per call, in order (controls first, then actions by `action_seq`), and stops at the first non-permanent refusal, of a control or of an action; the next pass starts again from the first unwritten record. A permanent refusal (the zone or the permission is gone, nothing reaches the hub anyway) never stops the pass: a permanently refused action moves to Not delivered, a permanently refused control stays queued and is retried on the next pass, and the records after either go on (Task 6). The flush itself never drops anything: a control leaves its queue only once written, with the hub's replica, or — on the hosted relay route only — past the relay's 14-day mailbox TTL (Task 6); on CloudKit there is no such TTL and a control is never dropped; an action only by an echo, the 24 h withdrawal, Retry or the owner's Dismiss.
- **One flush at a time.** `ActionOutbox` runs flushes, `resend_from` handling and the 24 h withdrawal on one serial operation chain; a second flush request while one runs coalesces into one more run after it.
- `CloudSyncTransport` keeps its three requirements. New surface only through `ConditionalTransport`. Not in Phase 1: `MailboxAddressing`, `PagedChanges` (Phase 2), any `HostedRelay*` type, `epoch_ack` sending, the transport switch, `hub_on_relay` handling, the "Relay unavailable" banner (Phases 3–4).
- **Swift Desktop hub: no behaviour change.** `control` frames are accepted only in the phone role (`SecureTransport`), so the hub keeps dropping them as `unknownKind`; the Desktop compiles against the changed Kit types with no source change. `make test-swift FILTER='RelayProcessorTests|MobileLinkCenterTests'` stays green in Tasks 1–4.
- **No plaintext at rest.** Outbox rows and queued controls keep only the sealed envelope and ids/counters/states/times; Retry opens the stored envelope with the phone's own key.
- **E2E vectors stay frozen.** No `make e2e-vectors`; new contract cases go into `WatchtowerKit/Tests/Fixtures/link/hub_contract_cases.json` as plain JSON.
- Inventory guards stay byte-identical (PROJ-16, PROJ-21; spec §5 p. 12): `WatchtowerDesktop/Tests/MobileHub/SessionInputHandlersTests.swift`, `PermissionAnswerHandlersTests.swift`, `PermissionRequestSliceTests.swift`, `WatchtowerKit/Tests/WatchtowerSyncTests/PermissionAllowRuleTests.swift`, `WatchtowerMobile/Tests/PermissionCardTests.swift`, `WatchtowerMobile/Tests/SessionInputWiringTests.swift`. Every task ends with `git diff --stat origin/main --` those six files printing nothing.
- New phone source or test files: `make mobile-gen` and commit the regenerated `WatchtowerMobile/WatchtowerMobile.xcodeproj` in the same task. Phone tests run with `SIM='iPhone 17 Pro'` (no iPhone 18 Pro simulator installed): `make mobile-test SIM='iPhone 17 Pro' MOBILE_FILTER=…`.
- Inner loop only per task: `make kit-test FILTER=…`, `make test-swift FILTER=…`, `make mobile-test MOBILE_FILTER=…`, `make lint-swift` (`make lint-diff` is Go-only). Never run a build or test in the background. The full gate runs once, in Task 12.
- Public repo: fixtures and mockups use `acme`, `example.com`, `_owner-acme`, "Work Mac", the fixture UUIDs already in `hub_contract_cases.json`; no real ids or live data.

## Review Focus

1. **Gapless counter under reentrancy.** Two enqueues racing across the actor's `await seal` must never draw the same `action_seq` or leave a hole. Task 5 `testTheCounterAdvancesOnlyWithAnInsertedRow`, Task 6 `testTwoConcurrentEnqueuesGetConsecutiveSeqs`.
2. **Order and single flight.** The flush stops at the first refusal (sim rule 1) and never overlaps another flush or a `resend_from` requeue. Task 6 `testATransientRefusalStopsTheFlushAndTheNextPassResumes`, `testAResendFromDuringAFlushIsAppliedAfterIt`.
3. **Sim rule 3 on a conflict** (a final echo of the same seq → settle, a non-final one never settles — only a final echo settles a row; identical bytes → sent; anything else → overwrite under the current `recordSeq`) on both transports. Task 1 (in-memory semantics), Task 2 (CloudKit mapping), Task 6 `testAConflictWith*`.
4. **Nothing dropped silently.** A permanent refusal or 24 h without an answer lists the action as Not delivered (after its record is withdrawn); a `resend_from` resends every requested action the phone still holds unsettled and lists nothing new; an unsent action leaves the phone only through Dismiss or Dismiss All, both through one store call. Task 6, Task 7 `testSkipToMarksUndelivered`, Task 8 `testFeatureDismissAndRetryGoThroughTheOutbox`.
5. **CloudKit refusals are classified right**: request-level `limitExceeded` splits a batch, only true refusals are permanent. Task 2 `testRefusalsMapByCode`, `testABatchTooLargeIsSplit`.
6. **The legacy path is untouched** while a hub lacks the flag, and a gap `held` echo (no reason) changes no overlay, so the PROJ-16/21 screens read as today. Task 6 `testALegacyHubKeepsTodaysPath`, `testAGapHoldLeavesTheOverlayAlone`; guard files.

---

## Lanes

Kit first, three parallel lanes: **A** Task 1 → Task 2 (CloudKit), **B** Task 3 (wire payloads + fixture), **C** Task 5 (replica storage). Then Task 4 (after 1, 3) → Task 6 (after 4, 5) → Task 7 (after 6). Task 2 may still run beside Tasks 4–7 (they test on the in-memory transport). **D** Task 9 (mockup) has no code dependency and runs any time before Task 10. Phone: Task 8 (after 2, 7) → Task 10 (after 8, 9) → Task 11 (guide). Task 12 is the gate.

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
  /// Why a write did not land. A flush stops at a non-`.permanent` refusal of a control or an action. A `.permanent`
  /// refusal never stops it: the action moves to Not delivered, the control stays queued for the next pass, and the flush goes on.
  public enum TransportRefusal: Equatable, Sendable {
      case unreachable                          // no network, the service or the account is away for now
      case rateLimited(retryAfter: TimeInterval?)
      case quotaExceeded
      case entitlementInactive                  // hosted relay (Phase 2+); never produced on CloudKit
      case transient(code: String)              // a failure retrying may clear (cancelled, response lost, unknown codes)
      case permanent(code: String)              // retrying can only repeat it: the zone is gone, permission lost, the record alone too large
      public var isPermanent: Bool { get }
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
- `InMemoryCloudTransport`: one zone-wide counter; every stored version (plain `save` included) gets the next value, returned on `changes`. `.absent` against a present record → `.conflict(current:)`; `.seq(n)` against another version → `.conflict(current:)`; `.seq(n)` against an absent record → `.refused(.permanent(code: "gone"))` (there is no current record to hand back); `.none` always writes. Test hooks (internal, `@testable`): `refuseNext(_ refusal: TransportRefusal, count: Int)` and `suspendNextSave() -> SaveGate` (the save waits until the test opens the gate; Task 6's race test).

- [ ] **Step 1: Write the failing tests** (`InMemoryConditionalTransportTests`)
  - `testAbsentCreatesOnceThenConflicts`: first `.absent` save → `.saved(recordSeq: 1)`; second with other bytes → `.conflict(current:)` whose payload is the first one's and `recordSeq == 1`.
  - `testSeqOverwritesOnlyTheVersionItNames`: `.seq(1)` → `.saved(2)`; a second `.seq(1)` → `.conflict(current.recordSeq == 2)`.
  - `testChangesCarryTheRecordSeq`.
  - `testDeleteUnderSeqAndAbsentRecord`: delete `.seq(2)` of a version-3 record → `.conflict`; `.seq(3)` → `.deleted`, then `changes` lists it deleted; an absent name → `.deleted`.
  - `testScriptedRefusalsComeFirst`.
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
- Modify: `WatchtowerKit/Sources/WatchtowerSync/CloudKitTransport/TransportStore.swift` (`system_fields.record_seq INTEGER NOT NULL DEFAULT 0`, bumped on every `saveSystemFields`, and `system_fields.change_tag TEXT` = the archived record's `recordChangeTag`; `events.record_seq INTEGER` written by `bufferFetched` from the same transaction's system-fields row; all patched in place for older stores like `creator`; `func recordVersion(recordName:zone:) throws -> (recordSeq: UInt64, changeTag: String?)?`; `func latestEvent(recordName:zone:) throws -> CloudRecord?`)
- Modify: `WatchtowerKit/Sources/WatchtowerSync/CloudKitTransport/CloudKitTransport.swift` (an internal init parameter `conditionalDatabase: (any ConditionalDatabase)?`, default the scope's `CKDatabase`, built lazily)
- Modify: `WatchtowerKit/Sources/WatchtowerSync/CloudKitTransport/CloudKitTransport+Mapping.swift` (fetched `CloudRecord.recordSeq` from the buffered event)
- Test: Create `WatchtowerKit/Tests/WatchtowerSyncTests/CloudKitConditionalTests.swift` with a `FakeConditionalDatabase` in `Support/`; extend `TransportStoreTests`

**Interfaces:**
- Consumes: Task 1's types.
- Produces: `extension CloudKitTransport: ConditionalTransport`. The version a `.seq` names is CloudKit's own change tag: `recordSeq` is only the local `UInt64` handle of one stored system-fields archive (CloudKit tags are opaque strings, the seam's type is `UInt64`); the save itself carries that archive, so the **server** enforces the tag through `.ifServerRecordUnchanged`. Rules (spec §3, Ruling 6):
  - Only `.relay` records; a `.data` item → `.refused(.permanent(code: "notMailbox"))` (slices keep today's path).
  - `.absent` → a fresh `CKRecord` (no system fields): the server refuses an existing name with `serverRecordChanged`.
  - `.seq(n)` → the archive whose `record_seq == n`; when the stored handle is newer (`!= n`) the phone already knows a newer version → `.conflict(current: latestEvent)` without a call; no stored archive → `.conflict(current:)` of the buffered event if any, else `.refused(.permanent(code: "unknownVersion"))`.
  - `.none` → stored archive if any, else fresh (overwrite on conflict once, today's direct-save rule).
  - `serverRecordChanged` → store the server record's system fields (bump `record_seq`) and return `.conflict(current:)` mapped from `error.serverRecord` (with that `recordSeq`). Never "my payload wins" on this path.
  - A saved record's system fields are stored (bump) and returned as `.saved(recordSeq:)`.
  - `unknownItem` on a `.seq` save (the record was deleted on the server) → stored fields dropped, `.refused(.permanent(code: "gone"))`, the same outcome as the in-memory transport's.
  - **Delete.** CloudKit has no conditional delete: `CKModifyRecordsOperation`'s save policy applies to saves only, and a record cannot be saved and deleted in one operation. So `.seq(n)` is checked against the stored handle and change tag (mismatch → `.conflict(current: latestEvent)`, no call), then deleted unconditionally (Ruling 6 states the window and its cost). `unknownItem` → `.deleted`; stored fields deleted on success.
  - **Batches.** A request-level `limitExceeded` splits the batch in halves and retries each (as `shrinkBatch` does for the engine); `limitExceeded` on a single record is `.permanent(code: "tooLarge")`.
  - Error map (`TransportRefusal`), per record or per call:
    - `.unreachable`: `networkUnavailable`, `networkFailure`, `serviceUnavailable`, `notAuthenticated`, `accountTemporarilyUnavailable`.
    - `.rateLimited(retryAfter: error.retryAfterSeconds)`: `requestRateLimited`, `zoneBusy`.
    - `.quotaExceeded`: `quotaExceeded`.
    - `.transient(code:)`: `operationCancelled`, `serverResponseLost`, `partialFailure` without a per-record error, `internalError`, `serverRejectedRequest`, and every code not listed below.
    - `.permanent(code:)` — only true refusals: `zoneNotFound`, `userDeletedZone`, `permissionFailure`, `invalidArguments`, `badContainer`, `badDatabase`, `missingEntitlement`, single-record `limitExceeded`.
  - Records written here never enter the engine's `pending` queue; `CKSyncEngine` fetches them later like any other change.

- [ ] **Step 1: Write the failing tests** (`CloudKitConditionalTests`, all on `FakeConditionalDatabase` and a temp `TransportStore`)
  - `testAbsentSendsAFreshRecord`: the fake saw one `CKRecord` with no change tag; `.saved(recordSeq: 1)`; the stored version is 1 with the returned tag.
  - `testASeqSaveCarriesTheStoredChangeTag`: the fake saw the archive's `recordChangeTag`.
  - `testServerRecordChangedIsAConflictNotARetry`: one save seen; `.conflict(current:)` carrying the server payload.
  - `testAStaleSeqConflictsWithoutACall`.
  - `testDeleteChecksLocallyThenDeletes`: `.seq(3)` → one delete call, `.deleted`; `.seq(2)` → `.conflict`, no call; `unknownItem` → `.deleted`.
  - `testRefusalsMapByCode`: table-driven over every code listed above, including `operationCancelled`, `serverResponseLost`, `networkFailure`, `networkUnavailable`, `zoneBusy`, `requestRateLimited`, `serviceUnavailable` (all not permanent) and an unlisted code (transient).
  - `testABatchTooLargeIsSplit`: a request-level `limitExceeded` on four deletes → two calls of two, all `.deleted`; a single-record `limitExceeded` → `.permanent("tooLarge")`.
  - `testADataZoneItemIsRefused`.
  - `TransportStoreTests.testRecordSeqBumpsWithEachSystemFieldsWrite` and `testAStoreFromBeforeRecordSeqOpensWithZero`.
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
  - `action`: `ordered_pending` (`json` = the phone's payload with `action_seq: 7`, `device_id`/`hub_id` from the fixture UUIDs; `kit` = `{action_seq: 7, record_name: "a-<DEVICE>-7"}`), `legacy_pending` (no `action_seq`), `ordered_echo_applied` (with `result`), `unknown_future_key`.
  - `control`: `skip_to` (`seq`, both ids), `resend_from`, `transport_switch_rejected` (`reason`, `retry_after_s`), `transport_switched_with_keybox` (decodes, keybox ignored), `unknown_kind`.

- [ ] **Step 1: Write the failing tests**
  - `HubContractFixtureTests.testActionCasesRoundTrip`: each `action` case decodes; `actionSeq` and the ordered record name equal `kit`; re-encoding with `RelayCoder` gives JSON equal (as objects) to `json` — no key the Go `wire.ActionRequest` lacks.
  - `HubContractFixtureTests.testControlCasesDecode`; `unknown_kind` keeps its raw kind.
  - `HubContractFixtureTests.testDeviceGrantCasesDecodeAndIgnoreNewKeys` asserts `runsOrderedActions` against `kit.ordered_actions`.
  - `RelayPayloadTests.testALegacyActionEncodesNoActionSeq` (byte check against today's encoding of a fixed payload) and `testSkipToCarriesBothIds`.
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
  - `testAConditionalSaveForwardsTheSealedBytes`.
  - `testAConflictsCurrentRecordOpens`: the hub's echo at that name opens as an `action` frame with status `applied` and its `recordSeq`.
  - `testThePhoneOpensHubControlsAndTheHubStillDropsThem`.
  - `testAPlainTransportIsNotConditional`.
- [ ] **Step 2: Run, expect failure** — `make kit-test FILTER=SecureTransportTests` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — `make kit-test FILTER='SecureTransportTests|RelayFeedTests|ActionOutboxTests'`, `make test-swift FILTER='RelayProcessorTests'` — PASS.
- [ ] **Step 5: Lint and guard check.**
- [ ] **Step 6: Commit** — `feat(kit): SecureTransport forwards conditional mailbox writes (#1240)`

### Task 5: The outbox in the replica

**Depends on:** none

**Files:**
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Replica/ReplicaStore.swift:155-177,222-231` (`pending_actions` gains `action_seq INTEGER`, `epoch INTEGER` (the envelope epoch the row was sealed in; Phase 3's switch reseals by it, sim rules 13–14), `record_seq INTEGER` (the version of the phone's own last write), `sent_at REAL`, `delivery TEXT CHECK(delivery IN ('queued','sent','settled','undelivered'))`, and `undelivered_reason TEXT CHECK(undelivered_reason IN ('refused','no_answer'))` (set only with `undelivered`: `refused` = the transport refused the write for good, `no_answer` = withdrawn after 24 h; a row already listed keeps its first reason, and `resendFrom` never sets one), all NULL for a legacy row, added in place by `upgradeSidecarColumns`; a unique index on `action_seq` where not NULL; new tables `outbound_controls` and `handled_controls`, which survive the format wipe like `pending_actions`)
- Create: `WatchtowerKit/Sources/WatchtowerSync/Replica/ReplicaStore+Outbox.swift`
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Replica/ReplicaStore+PendingActions.swift` (`PendingAction.actionSeq`, `epoch`, `delivery`, `undeliveredReason: UndeliveredReason?`; `sweepPendingActions` skips rows with `delivery` set — the ordered rows have their own 24 h rule in Task 6; `removePendingAction` becomes `dismissAction(id:)`, Ruling 16)
- Test: Create `WatchtowerKit/Tests/WatchtowerSyncTests/ReplicaOutboxTests.swift`

**Interfaces:**
- Produces (`ReplicaStore+Outbox.swift`), every write one transaction:
  ```swift
  public enum Delivery: String, Sendable { case queued, sent, settled, undelivered }
  public struct OutboxRow: Equatable, Sendable {
      public let actionID: String; public let actionSeq: UInt64; public let epoch: UInt32
      public let wireName: String; public let envelope: Data; public let delivery: Delivery
      public let recordSeq: UInt64?; public let sentAt: Date?
  }
  public struct QueuedControl: Equatable, Sendable { public let id: String; public let kind: ControlKind; public let wireName: String; public let envelope: Data; public let queuedAt: Date }
  extension ReplicaStore {
      func orderedActionsEnabled() throws -> Bool                 // replica_meta `ordered_actions` = "1"
      func enableOrderedActions() throws                          // sticky (Ruling 3)
      func nextActionSeq() throws -> UInt64                       // replica_meta `action_seq_next`, 1 when absent; unreadable → throws
      /// Inserts the row (`queued`, its epoch) and moves the counter from `seq` to `seq + 1` only if it still reads `seq`; false = lost the race, nothing written.
      func insertOrderedAction(_ action: ActionRequestPayload, entityRecordName: String?, sealed: CloudRecord, epoch: UInt32, seq: UInt64) throws -> Bool
      func outboxRows(_ deliveries: Set<Delivery>) throws -> [OutboxRow]       // by action_seq
      func outboxRows(fromSeq: UInt64, below: UInt64) throws -> [OutboxRow]  // any delivery
      func markSent(actionID: String, recordSeq: UInt64?, at: Date) throws      // only from `queued`
      func setDelivery(_ delivery: Delivery, actionIDs: [String]) throws
      /// `sent` rows at or above `seq` become `queued`; returns the first `queued` seq at or above it, nil when none.
      func requeue(fromSeq seq: UInt64) throws -> UInt64?
      /// `state = failed`, `delivery = undelivered`, the local message (Ruling 16).
      public enum UndeliveredReason: String, Sendable { case refused, noAnswer = "no_answer" }
      func markUndelivered(actionIDs: [String], reason: UndeliveredReason, message: String) throws
      func undeliveredActions(from db: Database) throws -> [PendingAction]
      func outboxCounts(from db: Database) throws -> (queued: Int, undelivered: Int)
      /// The one delete of an overlay row (feature Dismiss, the list's Dismiss All, Retry's old row). Refuses a row
      /// that is `queued` or `sent` (still on its way); returns whether a row went.
      @discardableResult public func dismissAction(id: String) throws -> Bool
      func dismissAllUndelivered() throws -> Int
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
  - `testTheCounterAdvancesOnlyWithAnInsertedRow`.
  - `testARowKeepsItsEpoch`: insert under epoch 3 → `outboxRows([.queued]).first?.epoch == 3`.
  - `testRequeueReturnsTheFirstRowStillHeld`: rows 1 sent, 2 settled, 3 sent, 4 undelivered → `requeue(fromSeq: 1) == 1`, rows 1 and 3 queued, 2 and 4 unchanged.
  - `testMarkSentOnlyMovesAQueuedRow`: a row requeued after the write landed stays `queued`.
  - `testUndeliveredRowsReadAsFailed`, `testDismissAllRemovesOnlyUndelivered`, `testDismissRefusesARowOnItsWay`.
  - `testTheLegacySweepSkipsOrderedRows`.
  - `testControlsQueueInOrderAndHandledIdsAreRememberedOnce`.
  - `testAReplicaFromBeforeTheOutboxOpensWithItsRows`.
  - `testTheOrderedFlagAndCounterSurviveTheFormatWipe`.
- [ ] **Step 2: Run, expect failure** — `make kit-test FILTER=ReplicaOutboxTests` — FAIL.
- [ ] **Step 3: Implement.** Every caller of `removePendingAction` (Kit and phone) moves to `dismissAction` in Task 8; until then a deprecated forwarder keeps them compiling.
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
      public func flush() async throws -> OutboxFlushReport    // single flight (below)
      /// sim rules 5–6, run on the same chain as flush.
      public func resendFrom(_ seq: UInt64) async throws
      /// A new action with the old one's kind, entity and params at the end of the queue; then `dismissAction(old)`.
      public func retry(id: String) async throws -> String
      public func dismissAllUndelivered() throws -> Int
  }
  ```
- **Single flight.** `flush`, `resendFrom` and the 24 h withdrawal run as operations on one serial chain inside the actor (each awaits the previous operation's `Task` before it starts; actor reentrancy cannot interleave them). A `flush()` call while a flush is queued or running returns that run's report and schedules at most one more run after it. `enqueue`, the feed and `HubSession` all go through this entry point.
- `enqueue` keeps its signature. Legacy (flag off, or the transport `!isConditional`): today's body. Ordered: read `nextActionSeq()`, build the payload (`actionSeq`, `hubID`), seal under `orderedRecordName(deviceID:actionSeq:)`, `insertOrderedAction(… epoch: sealed epoch, seq:)`; on false (another enqueue won during the seal) reseal with the next seq, at most 3 tries, then throw `ActionOutboxError.busy`. Then it requests a flush (not awaited); a refused flush never fails the enqueue.
- `flush()` (sim rules 1, 3, 7a), one record per `saveSealed` call, stopping at the first non-permanent refusal of a control or an action (`stoppedOn` set; the next pass starts from the same record). A permanent refusal never stops the pass: a control stays queued (point 1), an action is listed as Not delivered (point 2), and the records after it go on:
  1. Queued controls in order, `.absent`. `.saved` or a `.conflict` (the record already sits under its unique `c-<uuid>` name) → written. A non-permanent refusal stops the pass. A permanent one (zone or permission gone) does not: the control stays queued, is retried on the next pass, and the later controls and actions go on — if the zone is really gone they are refused for good too and the actions land in Not delivered, the owner's signal; if it comes back, the hub holds the actions until the control lands. Either way the control stays queued and is retried every pass. It leaves the queue only once written or with the hub's replica (unlink, re-pair). The one outer bound exists only where a relay mailbox TTL exists, i.e. on a `.hostedRelay` route (none in Phase 1; the rule ships with its test so Phase 2 inherits it): a control still unwritten 14 days after it was queued is dropped with an error log, because the relay would have purged any copy by then (sim "Bounded state"). On a `.cloudKit` route there is no mailbox TTL and the hub writes `resend_from` once per gap, so a dropped `skip_to` could stall every later action: a control is never dropped there; it stays queued until it is written or the hub's replica goes. The outbox learns the route from `ActionOutbox.init(…, route: HubRoute)` (Task 8 passes the session's route).
  2. `outboxRows([.queued])` in seq order. A row never written (`record_seq` NULL) goes with `.absent`. A row `requeue` put back after `resend_from` (it keeps the `record_seq` of its last write) goes with `.seq(record_seq)`: the same envelope bytes written as a **new version**, so the record appears in the hub's `changes` again even when the hub's token has moved past the copy it already holds (on CloudKit an identical record left in place would never be fetched again and the gap would never close). The Go hub accepts this: its rollback guard reads an identical `(epoch, seq)` as `Same` (`internal/hub/secure/rollback.go`) and the order rule then applies, holds or repeat-echoes it (`actions/order.go`). (The Go phone emulator's `resendFrom` uses `Send` with `ExpectAbsent` and takes identical bytes as delivered — sufficient on the relay test fake, where the hub re-reads from its stored cursor; the phone deliberately writes a new version, and the Go hub needs no change for it.)
     - `.saved(recordSeq)` → `markSent(recordSeq:, at: now)`.
     - A resend's conflicts: the current record is the hub's **final** echo of this `action_seq` (the hub answered meanwhile) → sent, then `applyEcho`, which settles the row (the feed deletes the echo); the hub's **non-final** echo (`held` or `received`) → `applyEcho` for the overlay, then one `.seq(current.recordSeq)` overwrite of the echo with the action's bytes, and the row stays `sent` — only a final echo settles a row. If that overwrite meets a conflict, the phone reads the current record (`openConflict`): the hub's final echo → `applyEcho`, the row settles; anything else → the row stays `sent` and is left to the feed, the next `resend_from` or the 24 h rule (no third write). (The Go hub keeps a held action's envelope in `held_actions` and drains from it, so it does not strictly need the record again; the rewrite costs one write and covers a hub that lost its held rows. Re-read, the action is held again — `state.Hold` is `ON CONFLICT DO NOTHING`, the held echo is rewritten, `resend_from` is not repeated (`ResendRequestedFrom`) — or, at or below `last`, answered as a repeat; `order.go` `action`/`hold`/`repeat`.) any other current version (our own earlier copy, an older epoch's copy) → one `.seq(current.recordSeq)` overwrite of the same bytes; the record is gone (`.refused(.permanent(code: "gone"))`: the hub or hygiene deleted it, or the TTL purged it) → one `.absent` write, whose outcome follows the first-write rules below. No third try in either case; a refusal on the retry is handled as below.
     - A first write's `.conflict(current)`: identical bytes → sent (its `recordSeq`); `openConflict` gives an `action` frame with this `action_seq` and a non-`pending` status → sent, then `applyEcho`; otherwise one `.seq(current.recordSeq)` overwrite of the same bytes, whose outcome is handled the same way (no third try).
     - `.refused(.permanent)` → `markUndelivered(reason: .refused)` with "Not delivered to your Mac." and the pass goes on with the next row: a permanent refusal concerns this record alone (the hub's gap rule then asks for it, and Task 6's `resendFrom` skips it).
     - Any other refusal → the row stays `queued`; the pass stops.
- `applyEcho` (ordered echo = `actionSeq != nil`): any echo of a `queued` row makes it `sent`; `held` without `reason` changes no overlay (Ruling 4); `held` with a reason and `received` as today; final: `applied` removes the row (as today, observer fired), `failed`/`expired`/`cancelled` mark it failed and `settled`. An echo of an `undelivered` row (the hub read it after all): `applied` removes it from Not delivered, a failed status settles it. Returns whether the echo was final, so the feed deletes it.
- `resendFrom(m)` (sim rules 5–6): `first = requeue(fromSeq: m) ?? nextActionSeq()`. `requeue` moves every `sent` row at or above `m` back to `queued` (keeping its `record_seq`, so the flush writes a new version under `.seq`, point 2), so `resendFrom` resends them and never lists them; it never calls `markUndelivered`. When `first > m`, the rows in `[m, first)` can only be `settled`, already `undelivered` (each keeps its first reason, `refused` or `no_answer`), or gone; `skip_to(first)` is then queued (sealed once, `ControlPayload.skipTo(first, deviceID:, hubID:)`). Rows there that are `settled` got a final echo and are not listed (sim rule 6 lists never-echoed actions only); seqs there with no row left the phone through an `applied` echo or the owner's Dismiss and have nothing to list (Ruling 1). Then a flush.
- **24 h without an answer** (Ruling 5, owner decision ask #852; replaces the legacy silent sweep for ordered rows; same 24 h window): at each `sweepSilentPending`, which becomes `public func sweepSilentPending(olderThan age: Duration = .seconds(86_400)) async throws -> [String]` and runs as one operation on the outbox's serial chain (so a withdrawal never overlaps a flush or a `resendFrom`; the legacy part of the sweep is unchanged inside it), every ordered row `queued` or `sent` for more than 24 h (by `sent_at`, else `created_at`) is withdrawn and listed as Not delivered, where the owner can Retry or Dismiss it. A `queued` row was never written: listed at once. A `sent` row's own record is first deleted with `.seq(recordSeq)`: `.deleted` → listed with `markUndelivered(reason: .noAnswer)` and "No answer from your Mac for 24 hours." (a never-written `queued` row gets the same reason) (the hub, finding the gap, asks `resend_from` and gets `skip_to`, so nothing behind it waits); `.conflict(current)` → the hub wrote an echo meanwhile, which is applied instead and the row is not listed; a refusal → the row stays and is tried at the next sweep. Withdrawing before listing is what keeps a later Retry from applying the action twice (on CloudKit within Ruling 6's window).
- `retry(id:)`: opens the row's envelope (`opener.openOwnRelay`), enqueues a new action with the same kind, entity and params (new id, `createdAt = now`, next seq, current epoch), then `dismissAction(id:)` on the old row; a locked keychain throws before anything changes. Only rows that are `failed` (settled or undelivered) or legacy failed rows can be retried.

- [ ] **Step 1: Write the failing tests** (`ActionOutboxOrderedTests`; phone `SecureTransport` over `InMemoryCloudTransport`, `TestE2E`)
  - `testALegacyHubKeepsTodaysPath`: flag off → record name `action-<uuid>`, no `action_seq`, nothing in `outbound_controls`, saved through plain `save`.
  - `testOrderedEnqueueWritesAGaplessSeriesInOrder`: three enqueues → `a-<DEV>-1…3`, one call each, all `sent`, epoch stored.
  - `testTwoConcurrentEnqueuesGetConsecutiveSeqs`.
  - `testATransientRefusalStopsTheFlushAndTheNextPassResumes` (twin of `TestRefusedActionWriteRetried`): rows 1–3, `.unreachable` on 2 → 1 sent, 2 and 3 queued and 3 never attempted; the next pass writes 2 then 3.
  - `testAPermanentRefusalListsTheActionAsNotDelivered` and the pass goes on to the next row.
  - `testARefusedControlIsKeptAndRetried`: an `.unreachable` refusal of `skip_to` → still queued, no action written in that pass, written on the next.
  - `testAPermanentlyRefusedControlDoesNotBlockLaterActions`: `.cloudKit` route, `skip_to` refused `.permanent(zoneNotFound)` → the queued actions after it are still attempted in the same pass; the control stays queued and is tried again on the next pass, never dropped.
  - `testAControlIsNeverDroppedOnCloudKit`: `.cloudKit(.private)` route, a control refused for 30 days of fake clock → still queued, written once the refusal clears.
  - `testAControlUnwrittenFor14DaysIsDroppedOnTheHostedRelay`: `.hostedRelay(macDeviceID: "mac-acme")` route → dropped after 14 days, logged.
  - `testAConflictWithIdenticalBytesCountsAsSent`, `testAConflictWithTheHubsEchoSettlesTheRow`, `testAConflictWithAnythingElseIsOverwrittenUnderItsSeq`.
  - `testAGapHoldLeavesTheOverlayAlone`.
  - `testTwoFlushRequestsNeverOverlap`: with `suspendNextSave`, a second `flush()` during the first makes no transport call until the first returns.
  - `testAResendFromDuringAFlushIsAppliedAfterIt`: row 1's save is suspended; `resendFrom(1)` arrives; the gate opens; afterwards row 1 is `queued` again and the following flush writes it a second time (two writes seen), never left `sent`.
  - `testResendFromRequeuesFromTheGap`.
  - `testAResendWritesANewVersionOfARecordThatStillExists`: row 1 written (recordSeq r); `resendFrom(1)` → the flush writes it with `.seq(r)`; the stored `recordSeq` is now > r, `changes(since:)` past r lists the record again, and its envelope bytes are unchanged.
  - `testAResendThatMeetsTheHubsEchoAppliesIt` (a final echo: settled, no rewrite), `testAResendThatMeetsAHeldEchoRewritesTheAction` (the held echo at version v is overwritten under `.seq(v)` with the action's original bytes; the row stays `sent`, its overlay unchanged), `testAResendOverwriteThatMeetsAFinalEchoSettlesTheRow` (the held-echo overwrite conflicts with the hub's `applied` echo written meanwhile → the row settles, no further write) and `testAResendOfAGoneRecordWritesItAgainAsNew` (the record was deleted → `.absent`, saved).
  - `testResendFromSkipsWhatItCannotSendAndListsNothingNew`: rows 1 undelivered (`refused`), 2 settled, 3 sent → `resendFrom(1)` requeues 3, writes `skip_to(3)` with uppercase `device_id` and the `hub_id`; row 1 keeps `refused`, row 2 is not listed, `markUndelivered` is not called.
  - `testResendFromWithNoRowsWritesOnlySkipTo`.
  - `testAQueuedRowOlderThan24HoursIsNotDelivered`, `testASentRowOlderThan24HoursIsWithdrawnThenListed`, `testAWithdrawalThatMeetsAnEchoSettlesInstead`.
  - `testUndeliveredRowsCarryWhyTheyWereListed`: a permanent refusal → `undeliveredReason == .refused`; a 24 h withdrawal → `.noAnswer`; `resendFrom` requeues a `sent` row at or above the gap without listing it, and leaves an already listed row's reason unchanged.
  - `testAWithdrawalNeverOverlapsAFlush`: with `suspendNextSave` holding a flush, `sweepSilentPending()` makes no transport call (no withdrawal delete) until the flush returns; then it runs.
  - `testAnEchoOfAnUndeliveredRowLeavesTheList`.
  - `testRetryGoesToTheEndOfTheQueue` and `testDismissAllNeverResends` (after Dismiss All, `resendFrom(1)` writes only `skip_to`).
- [ ] **Step 2: Run, expect failure** — `make kit-test FILTER=ActionOutboxOrderedTests` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — `make kit-test FILTER='ActionOutboxOrderedTests|ActionOutboxTests|RelayFeedTests|PermissionAllowRuleTests'` — PASS, `ActionOutboxTests` unchanged.
- [ ] **Step 5: Lint and guard check.**
- [ ] **Step 6: Commit** — `feat(kit): ordered actions in the outbox — seq, single-flight flush, resend and skip (#1240)`

### Task 7: `RelayFeed` — controls, echo deletes, sim twins

**Depends on:** Task 6

**Files:**
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Relay/RelayFeed.swift:193-235` (route `control`; collect deletes; one `deleteSealed` call at the end of the cycle, after the token is stored)
- Create: `WatchtowerKit/Tests/WatchtowerSyncTests/Support/OrderedHubFake.swift` (test-only hub over `TestE2E.hubTransport`: applies `last + 1`, echoes every action read with `.seq`, holds ahead of a gap and writes `resend_from(last + 1)` once per gap, honours `skip_to` within `last + 1 + 65536`, deletes the controls it read — the Go hub's `order.go`/`control.go` rules, nothing more)
- Create: `WatchtowerKit/Tests/WatchtowerSyncTests/OrderedSimTwinTests.swift`
- Test: `RelayFeedTests.swift`

**Interfaces:**
- Consumes: `ActionOutbox.applyEcho` (returns final), `resendFrom`, `ReplicaStore.markControlHandled`.
- Produces: in the feed —
  - `action` echo of an ordered row, final → delete under `.seq(record.recordSeq)` by `record.sealed.wireName`.
  - `control` from the hub: decode `ControlPayload`; one whose `device_id` is not this phone or whose `hub_id` is another hub is dropped with a log line and deleted; `markControlHandled(id)` false → deleted unread (second copy); `resend_from(seq)` → `await outbox.resendFrom` (on the outbox's chain, so it never races a flush); `transport_switch_rejected` → logged (Phase 1 never asks) and deleted; `transport_switched`, `hub_on_relay` and unknown kinds are left in the mailbox, not marked handled, logged once per kind (Ruling 9).
  - Deletes are best effort: one try per read, outcome logged by class; the CloudKit hub hygiene and the relay TTL are the fallbacks (Ruling 8). A delete never fails the cycle.
- Sim twins (names as `relay/sim/sim_test.go`, spec §11), phone + `OrderedHubFake` over one `InMemoryCloudTransport`: `testActionsAppliedInOrderOnce`, `testGapTriggersResendFrom`, `testSkipToMarksUndelivered`, `testRefusedActionWriteRetried`, `testPhoneSkipToRetriedUntilWritten`. The hub-side twins and the switch twins wait for Phases 2–3.

- [ ] **Step 1: Write the failing tests**
  - `RelayFeedTests.testAFinalOrderedEchoIsDeletedUnderItsSeq`, `testANonFinalEchoStays`, `testALegacyEchoIsNeverDeleted` (today's behaviour).
  - `RelayFeedTests.testResendFromIsHandledOnceAndDeleted`, `testAControlNamingAnotherDeviceIsDropped`, `testUnknownControlKindsStayInTheMailbox`.
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
- Modify: `WatchtowerMobile/Sources/App/Hubs/HubSession.swift:441-456,481,734-745,930-1019,1101-1160` (the outbox is built as `ActionOutbox(transport:store:deviceID:route:)` with the session's `HubRoute`, which decides the control TTL rule of Task 6; `setHubID`; the grant turns the ordered path on — on every `keyboxSignal` and `indexStoredRows`, a linked grant with `runsOrderedActions` calls `outbox.enableOrderedActions()`; `flush()` after `feed.pollOnce()` in `performFetch` and `applyBuffered`, on `setActive(true)` and on `keysBecameAvailable`; `sweepSilentPending` call sites: `bootstrap()` (`HubSession.swift:739`, already `try await outbox.sweepSilentPending()`, unchanged text, now awaiting the async sweep on the outbox's chain) and a new call in `performFetch` after `feed.pollOnce()` and the flush request (once per fetch cycle, so a phone that stays up still withdraws after 24 h); no other caller exists in the phone or the Kit; `@Observable` `outboxBacklog: OutboxBacklog`)
- Create: `WatchtowerMobile/Sources/App/Hubs/OutboxBacklog.swift` (`struct OutboxBacklog: Equatable { var queued: Int; var undelivered: Int; var lastFlushStopped: Bool; static let empty }`, refreshed by a `ResilientObservation` over `ReplicaStore.outboxCounts` plus the last `OutboxFlushReport`)
- Modify (Dismiss and Retry through the outbox, Ruling 16): `WatchtowerMobile/Sources/Features/Asks/AskAnswerer.swift:79`, `Features/Workbench/BoardWriter.swift:50`, `SessionInputSender.swift:82`, `SessionStarter.swift:104` — each `remove:` closure becomes `store.dismissAction(id:)`; each feature Retry of a failed row ends with that same call on the old row (their own re-enqueue keeps building kind-specific params, as the list's `retry(id:)` does with the stored ones).
- Modify: `WatchtowerMobile/Sources/App/AppRoot.swift:710-720` (`pendingActionCount` also counts `queued` and `sent` ordered rows, so a removal's "not sent" count stays honest)
- Test: Create `WatchtowerMobile/Tests/OrderedActionsWiringTests.swift`; `make mobile-gen`

**Interfaces:**
- Consumes: Tasks 2, 6, 7.
- Produces: `HubSession.outboxBacklog`, `HubSession.retry(actionID:) async throws`, `HubSession.dismissAllUndelivered() throws`.
- No change for a legacy hub: no flush call reaches the transport when the flag is off and `outbound_controls` is empty (the flush returns at once); `dismissAction` on a legacy failed row deletes it exactly as `removePendingAction` did.

- [ ] **Step 1: Write the failing tests** (`OrderedActionsWiringTests`, in-memory transport, test grant)
  - `testAGrantWithOrderedActionsTurnsTheOrderedPathOn` (and the flag survives a session restart).
  - `testAGrantWithoutTheFlagKeepsTodaysPath`.
  - `testAFetchFlushesWhatWasQueued`.
  - `testFeatureDismissAndRetryGoThroughTheOutbox`: for an undelivered ordered row of each of the four writers' kinds, the feature's Dismiss leaves no row and a later `resend_from` writes only `skip_to`; the feature's Retry gives a new `action_seq` at the end of the queue and removes the old row.
  - `testARemovalCountsUnsentOrderedActionsAsNotSent`.
- [ ] **Step 2: Run, expect failure** — `make mobile-gen`, then `make mobile-test SIM='iPhone 17 Pro' MOBILE_FILTER=OrderedActionsWiringTests` — FAIL.
- [ ] **Step 3: Implement**; delete the `removePendingAction` forwarder once nothing calls it.
- [ ] **Step 4: Run** — `make mobile-test SIM='iPhone 17 Pro' MOBILE_FILTER='OrderedActionsWiringTests|FetchCadenceWiringTests|BackgroundWorkTests|AppRootWiringTests|AppRootRelinkTests|MultiHubEnvironmentTests|BoardWriteWiringTests|AskFormTests|StartSheetWiringTests|SessionInputWiringTests|PermissionCardTests'` — PASS, the last two unchanged.
- [ ] **Step 5: Lint and guard check.**
- [ ] **Step 6: Commit** — `feat(mobile): the phone sends ordered actions to a hub that runs them (#1240)`

### Task 9: Mockup — the Phase 1 states

**Depends on:** none (before Task 10)

**Files:**
- Modify: `docs/design/mockups/relay-client/index.html` §5 (neutral names only: "Work Mac", sample asks and targets; no live data)

Adds, next to the existing two phones:
- **Now, Phase 1 (no banner):** the status chip, then one group "Waiting to send · 3" (secondary count) and one row "Not delivered · 2 ›" (red text, chevron), above Waiting for you. A note says the "Relay unavailable" banner joins in Phase 4 (Ruling 12).
- **Dismiss All confirmation:** an action sheet "Dismiss 2 actions? They won't be sent." with **Dismiss All** (red) and **Cancel**.
- **Retry error:** the Not delivered list with one row showing "Unlock your iPhone to retry." under it in secondary text, its Retry disabled while a retry runs.
- **Sub lines per reason:** a list row withdrawn after 24 h reads "No answer from Work Mac for 24 hours"; a refused row shows only its time.

- [ ] **Step 1:** Edit the mockup; open it in a browser and check the four new phones read in light and dark mode.
- [ ] **Step 2: Commit** — `docs(design): Phase 1 states of Not delivered in the relay-client mockup (#1240)`

### Task 10: Now → Waiting to send and Not delivered

**Depends on:** Task 8, Task 9

**Files:**
- Modify: `WatchtowerMobile/Sources/Features/Now/NowModel.swift` (`outbox: NowOutboxRows?` from `OutboxBacklog` + the Mac's display name)
- Modify: `WatchtowerMobile/Sources/Features/Now/NowView.swift:5-7,60-80` (`NowRoute.notDelivered`; the group placed as in the Task 9 mockup)
- Create: `WatchtowerMobile/Sources/Features/Now/NotDeliveredModel.swift`, `NotDeliveredView.swift`
- Modify: `WatchtowerMobile/Sources/App/DemoSeed.swift` + Create `WatchtowerMobile/Sources/App/DemoSeed+Outbox.swift` (a demo-only state with two undelivered rows, one of them withdrawn after 24 h, and three queued ones, sealed with the demo keys, reached from the tour only)
- Test: Create `WatchtowerMobile/Tests/NotDeliveredModelTests.swift`; extend `NowWiringTests`, `OrangeToneTests`, `ScreenshotTourTests`; `make mobile-gen`

**Interfaces:**
- **Matches the Task 9 mockup** state for state; the copy lives in the models and the tests assert it.
- `NowOutboxRows`: **Waiting to send** with the count, shown only while `queued > 0 && lastFlushStopped` (Ruling 12); **Not delivered** with the count and a chevron, shown while `undelivered > 0`. Tones: count `.secondary`, the Not delivered row `.red` with role `.status`; never orange.
- `NotDeliveredModel`: title "Not delivered"; footer "These actions never reached <Mac name>. Retry sends them again, after anything you did since."; one row per undelivered action, oldest first: a one-line summary from `ActionSummary.text(for:snapshot:)` (per kind: `ask_answer` → "Answer “<ask title>” — <verdict>", `board_target_status` → "Move “<target>” to <column>", `board_comment_add`/`reply` → "Comment on “<target>”", `board_target_create` → "New task “<text>”", `session_start` → "Start a session for “<target>”", `session_input` → "Send “<first 60 chars>”", `session_stop`/`session_finish_request`/`session_interrupt` → "Stop/Finish/Interrupt “<session>”", `permission_answer` → "Allow/Deny a permission request", `automation_run` → "Run “<automation>”", any other kind → "An action from this iPhone"; a missing title falls back to the kind's noun), the time via the phone's relative formatter, and a sub line per reason: `.noAnswer` → "No answer from <Mac name> for 24 hours", `.refused` → none (the time only); a **Retry** per row (`HubSession.retry`; disabled while it runs; a failure shows the model's message under the row, "Unlock your iPhone to retry." for a locked keychain, else "Couldn't retry. Try again."); a destructive **Dismiss All** (`.red`, role `.status`) behind the confirmation "Dismiss N actions? They won't be sent."
- Rows come from `ReplicaStore.undeliveredActions` through the existing `ResilientObservation`; the list pops back to Now when it empties.
- Screenshot tour (the phone's design shots; Ruling 14): `now-outbox`, `not-delivered-list`, `not-delivered-dismiss-confirm`, `not-delivered-retry-error`, each light and dark, on the demo outbox state.

- [ ] **Step 1: Write the failing tests**
  - `NotDeliveredModelTests`: summary per kind (table-driven), the footer names the Mac, rows oldest first, the sub line per reason (`.noAnswer`; none for `.refused`), the Dismiss All confirmation copy with the count, both Retry error texts.
  - `NowWiringTests.testWaitingToSendShowsOnlyWhenAFlushStopped`, `testNotDeliveredRowShowsTheCount`.
  - `OrangeToneTests` gains the two new models' `toneUses` (no orange).
  - `ScreenshotTourTests` registers the four shots.
- [ ] **Step 2: Run, expect failure** — `make mobile-gen`, `make mobile-test SIM='iPhone 17 Pro' MOBILE_FILTER='NotDeliveredModelTests|NowWiringTests|OrangeToneTests'` — FAIL.
- [ ] **Step 3: Implement** the models, views and demo state; colours only through `PhoneTone`, components from `Sources/DesignSystem/`.
- [ ] **Step 4: Run** — the Step 2 filter plus `ScreenshotTourTests|SettingsWiringTests` — PASS; then `make mobile-shots SIM='iPhone 17 Pro'` and compare the four shots with the Task 9 mockup.
- [ ] **Step 5: Lint and guard check.**
- [ ] **Step 6: Commit** — `feat(mobile): Now shows Waiting to send and the Not delivered list (#1240)`

### Task 11: User guide

**Depends on:** Task 10 (the final copy)

**Files:**
- Modify: `docs/guide/features/iphone.md` (a "When something is not delivered" subsection under **Using it**: what **Waiting to send** means; when **Not delivered** appears — the Mac refused a change for good, or did not answer it for 24 hours; what **Retry** does (sends it again after anything done since) and that **Dismiss** / **Dismiss All** drop it for good; one sentence in **How it works** that the Mac applies a phone's changes in the order they were made; per `docs/guide/WRITING.md`, bold for UI labels, no internals, no ids). A Learn card only if the section meets `WRITING.md`'s bar; Phase 4 adds the relay parts.

- [ ] **Step 1:** Edit the page; keep it under the 8 KB section cap.
- [ ] **Step 2: Run** — `go test ./docs/guide` — PASS.
- [ ] **Step 3: Commit** — `docs(guide): changes from the iPhone go in order; Not delivered (#1240)`

### Task 12: Phase gate and the feature note

**Depends on:** Tasks 1–11

**Files:**
- Modify: `docs/features/mobile-companion.md` — the **Rollback and replay (D4)** bullet (today's "no strict per-device sequence gate" holds for the legacy path only; an ordered hub orders by `action_seq`, spec §5, Go hub `order.go`); **Deliberate re-sends** (byte-for-byte resends now also from `resend_from`); "Replica, outbox and relay feed (A3, A11)" (`pending_actions` as the outbox — `action_seq`, `epoch`, `record_seq`, `sent_at`, `delivery`, the counter, `outbound_controls`, `handled_controls`; `ActionOutbox`'s single-flight flush, sim rules 1/3/7a, refusals, the 24 h withdrawal; `dismissAction` as the one delete; `RelayFeed` controls and echo deletes); "Transport: scopes, errors and the local buffer" (`ConditionalTransport` on CloudKit outside the engine, `record_seq` as the handle of a stored change tag, the refusal table, the batch split, the local delete check); the hygiene line (echoes and controls are deleted by the phone on the ordered path, hub hygiene stays the fallback); a new bullet "**Ordered actions (relay client Phase 1).**" naming the negotiation (`ordered_actions`, sticky), the shared fixture sections and the Not delivered list; Tests line gains the new test classes.

- [ ] **Step 1: Desktop + Kit suite** — `make test-swift > "${TMPDIR:-/tmp}/p1-swift.log" 2>&1; echo "exit=$?"` — Expected `exit=0`.
- [ ] **Step 2: Phone suite** — `make mobile-test SIM='iPhone 17 Pro' > "${TMPDIR:-/tmp}/p1-mobile.log" 2>&1; echo "exit=$?"` — Expected `exit=0`.
- [ ] **Step 3: Lint** — `make lint-all` — no new issues.
- [ ] **Step 4: Go contract** — `go test ./internal/hub/wire ./docs/guide` — PASS.
- [ ] **Step 4a: The Go hub accepts the phone's resends.** If either test fails, Phase 1 stops before the PR: the failing test and its output go to the Go hub session, and an ask to the owner names the blocker. The phone code is not changed to fit the hub. Required: `go test ./internal/hub/actions -run 'TestResendOfIdenticalBytesAsANewVersionIsAppliedOnce|TestResendOverAHeldEchoIsHeldOnceThenApplied'` — PASS. On 2026-10-31 neither test exists on `origin/main` or `origin/feature/go-hub` (the Go hub 1b plan's Task 17 is its gate and docs; no such test is in it yet). `internal/hub/actions` (with `order.go`) is already on `main`: the Go hub's plan PRs merge into `main` task by task (1a/1b), so the gate runs after Phase 1 merges `origin/main` into its branch. If they are still missing on `main` when this gate runs, Phase 1 adds them itself as one test-only file, `internal/hub/actions/phone_resend_test.go` (package `actions_test`, over `hubtest.Phone` and the in-memory transport as `sim_test.go` does); no production hub code changes. Assertions:
  - `TestResendOfIdenticalBytesAsANewVersionIsAppliedOnce`: the phone queues a1 and a2 and writes a2 only; the hub holds a2 and writes `resend_from(1)`. a1's (wire name, sender, epoch, seq) is put in the hub's `relay_seen` (`state.RecordSeen` in a tx — as if the hub had opened that copy before a crash). The phone writes a1's original envelope, then overwrites it under `ExpectSeq` with the same bytes (a new `RecordSeq`). Next pass: the opener's verdict for a1 is `Same`, not `ErrRolledBack`; a1's handler runs exactly once; a2 is drained from `held_actions` and applied once; `LastAppliedActionSeq == 2`; both echoes are `applied`; no held rows remain; a further identical overwrite is answered as a repeat (echo again, handler count unchanged).
  - `TestResendOverAHeldEchoIsHeldOnceThenApplied`: a2 is written first and held (held echo at a2's name, `resend_from(1)` once). The phone overwrites the held echo under `ExpectSeq(<echo's RecordSeq>)` with a2's original bytes. Next pass: one `held_actions` row for a2, the held echo rewritten, no second `resend_from`. Then a1 is written: a1 and a2 are applied in order, each handler once.
- [ ] **Step 5: Guard files** — `git diff --stat origin/main --` the six guard files — empty.
- [ ] **Step 6: Update the feature note** as listed (English, no ids).
- [ ] **Step 7: Manual device check** (spec §11): a signed phone linked to a signed Mac running today's Desktop hub — answer an ask, move a card, send a session line, dismiss a failed one: each behaves as before (legacy path; no `a-` record in RelayZone). With a Go hub announcing `ordered_actions` where one is available: two quick lines arrive in order; airplane mode → **Waiting to send** → back online → sent.
- [ ] **Step 8: Commit** — `docs(mobile): the ordered action path after relay client Phase 1 (#1240)`

---

## Rulings

Gaps and contradictions found while planning, decided here. Each: what, why, cost if wrong.

1. **What a `resend_from` lists: nothing new; what it rewrites.** A resend meets the hub's echo at the row's name: a final echo settles the row; a non-final (`held`/`received`) echo never does, and is overwritten with the action under `.seq(<the echo's version>)` (Task 6 point 2; the Go side pinned by the Task 12 Step 4a tests). Every requested `sent` or `queued` row is resent with its bytes as a new version (`.seq` of its last write; `.absent` if it was never written or the record is gone; Task 6 point 2), never listed; rows already in Not delivered keep their first reason. Below the first row still held, two kinds of requested seq are not listed, and why: a `settled` row got the hub's final echo, so it was delivered (sim rule 6 lists never-echoed actions only); a seq with no row left the phone in exactly two ways, an `applied` echo (delivered; the hub asking again means it lost its own state, and resending could apply it twice) or the owner's Dismiss/Dismiss All (the owner's explicit choice, spec §5 p. 6). The reinstall case of sim rule 6 cannot leave a counter without rows: a re-pair always opens a fresh replica (`LinkingViewModel` `fresh: true`), restarting the counter with the hub's own re-link reset (protocol §7.5 p. 8). `hub_on_relay` (rule 16 / R32) joins in Phases 3–4. *Cost if wrong:* an action lost some other way (replica damage) is skipped with a log line but no list row. *Cost (whole-branch review):* the feed's `resend_from` waits on the outbox's chain (it runs after any flush in flight), so a CloudKit save that hangs delays that feed cycle until the save returns or times out.
2. **The counter lives in `replica_meta` and is drawn in the insert's transaction (compare-and-set, reseal on a lost race).** `SeqAllocator` reserves blocks and would leave holes, which the hub reads as a gap. *Cost:* up to three seals per enqueue under contention; `ActionOutboxError.busy` past that.
3. **Ordered mode is sticky per replica** once a linked grant carries `ordered_actions ≥ 1`; a grant that later drops it does not switch back. The hub runs a phone ordered from its first ordered action (protocol §7.5 p. 1). Going back to a Swift hub without re-linking is not a supported path: the Swift hub is being retired in favour of the Go hub (ask #802), and a re-link starts a fresh replica anyway. *Cost:* in that unsupported case the Swift hub receives `a-` records until the owner re-links.
4. **A gap `held` (no reason) leaves the overlay alone.** It means "arrived ahead of a gap", not "the Mac picked it up" or a held line; recording it would change what the PROJ-16/21 screens say. *Cost:* while a gap is open, Interrupt or a permission answer reads "Sending…" (ask #796 accepted cost).
5. **Ordered rows leave the legacy silent sweep but get the same 24 h exit.** *Owner decision (ask #852):* a withdrawn row keeps Retry, on the Not delivered list and on the feature screens alike; the rare double apply named below is accepted. Instead of a local `failed` (which a Dismiss would delete while the record still sits in the mailbox), an ordered row with no answer for 24 h is withdrawn — its own record deleted under the version it wrote — and then listed as Not delivered, where the owner can Retry or Dismiss. *Cost:* a hub that answers after 24 h finds the record gone and asks `resend_from`; the phone answers `skip_to` and the action stays Not delivered (on CloudKit, a hub read inside Ruling 6's window may still apply it, and a Retry then applies it twice). *Cost (whole-branch review):* the phone never skips a withdrawn row on its own. Its `skip_to` goes out only in answer to the hub's `resend_from`, so when the hub never asks for that seq again, the later rows stay held behind it on the hub. The hub asks again for any seq it has not applied, so this needs an envelope the hub cannot open at all (no echo it can address), which is rare.
6. **CloudKit: conditional writes go outside `CKSyncEngine` (`modifyRecords`, `.ifServerRecordUnchanged`).** Saves are conditional on CloudKit's own change tag: the stored system-fields archive travels with the save and the server checks it; `recordSeq` is only the local `UInt64` handle of that archive, because the seam's `.seq` is a `UInt64` and CloudKit tags are opaque strings. Deletes cannot be conditional on CloudKit: the save policy applies to saves only and one operation cannot save and delete a record, so a delete checks the stored tag locally and then deletes unconditionally. *Cost:* a hub write that lands between the phone's last fetch and its delete is lost. On this path the phone deletes only final echoes (the hub rewrites one only with the same final outcome), read controls (never rewritten) and, after 24 h, its own unanswered action (Ruling 5: a hub that reads and applies it inside the window loses its echo, and the action is listed as Not delivered although it was applied). One extra CloudKit call per flush record and per feed cycle with deletes.
7. *(Withdrawn in round 1: the flush follows sim rule 1 literally — one record per call, stop at the first refusal.)*
8. **Echo and control deletes are best effort, one try.** Same as the Go hub's `deleteControl`; hub hygiene (CloudKit, 7 days) and the relay TTL (14 days) are the fallbacks (spec §5 p. 8). *Cost:* a leftover record until hygiene.
9. **Hub controls Phase 1 cannot act on stay in the mailbox.** `transport_switched`, `hub_on_relay` and unknown kinds are not deleted or marked handled; `transport_switch_rejected` is deleted (the phone never asks in Phase 1). The Go hub writes the first two only after its own switch work, which needs a Phase 3 phone. *Cost:* Phase 3 must re-read them (token reset or the transport marker, sim rule 12a).
10. **`control` is accepted only in the phone role of `SecureTransport`.** The Swift Desktop hub is not extended: it keeps dropping controls as an unknown kind, as the spec's mixed-version rule expects. *Cost:* none for the Go hub, which has its own opener.
11. **The shared fixture gains `action` and `control` sections, read by the Kit only.** Hub code is out of this plan; the Go decoder ignores unknown sections, so `go test ./internal/hub/wire` stays green. Reading them from `TestHubContractFixture` is a follow-up for the Go hub session (to be filed as an ask on #1240 when Task 3 lands). The opposite direction is already pinned: the Kit opens the Go-sealed `a-<DEVICE>-1` echo (`go-sealed.json`). *Cost:* until the Go test reads them, a Go-side key rename is caught only by the Kit test against the fixture.
12. **Waiting to send shows without the "Relay unavailable" banner in Phase 1; the banner arrives in Phase 4.** The banner states relay reachability (unreachable > 60 s, the switch offer after 10 min, spec §9), which exists only with the hosted relay client of Phases 2–4; on CloudKit the row shows while queued rows exist and the last flush stopped on a refusal. The Task 9 mockup records this Phase 1 state. *Cost:* a brief row during a short iCloud outage.
13. **The user guide is updated in Phase 1**, not only in Phase 4 (spec §14): CLAUDE.md requires a user-facing change to update its guide page in the same PR, and the Not delivered list ships now. Phase 4 adds the transport and subscription parts. *Cost:* none.
14. **The phone has no `DesignShotCatalog`** (it is the Desktop's, `WatchtowerDesktop/Tests/DesignShots`). The workbench rule is met by the phone's equivalent, `ScreenshotTourTests` over a demo state (`make mobile-shots`), with the copy in the models under test and colours through `PhoneTone`. *Cost:* none.
15. **`epoch_ack` is sent from Phase 3**, with the phone's epoch keys; `MailboxAddressing` and `PagedChanges` come with the hosted relay in Phase 2. The control queue built here carries `epoch_ack` unchanged, and each outbox row already keeps its epoch for the Phase 3 reseal. *Cost:* the Go hub records no acks from phones until Phase 3; it retires no keys before then anyway.
16. **One delete and one retry for an action, wherever the button is.** An undelivered row is an overlay `failed` row with `delivery = undelivered`, so feature screens show it failed with their own Retry and Dismiss. Every Dismiss (feature screen, Dismiss All) goes through `ReplicaStore.dismissAction`, which refuses a row still on its way; every Retry ends with a new action at the end of the queue and `dismissAction` on the old row (`ActionOutbox.retry` in the list; the feature writers re-enqueue with their own params). Task 8 tests both paths. *Cost:* the same action appears on its feature screen and in the list.
