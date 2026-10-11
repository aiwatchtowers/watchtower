# Mobile multi-hub F1: spike, hub-aware Kit transport, per-hub zones on the Mac

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** prove on devices that one CKSyncEngine per hub works (F0), then make the Kit transport hub-aware and move the Mac hub onto its own zones `DataZone-<hub_id>` / `RelayZone-<hub_id>`, with the single-hub rule I-1 and take over removed. The phone keeps its single link and syncs that link's hub.

**Architecture:**
- A new value `HubZones` (scope + hub id) maps a zone kind (`CloudZoneID`) to `<Kind>Zone-<hubID>` and back. `CloudKitTransport` owns one `HubZones` and a `TransportRole`. Every filter (`cloudZone(for:)`, buffering, sent changes, deleted zones, the poll) goes through it, and only `.hub` writes zones.
- The engine is held to its own zones: manual fetch and send pass `.zoneIDs(own)` options, and the delegate's `nextFetchChangesOptions` scopes the automatic fetches.
- A `TransportStore` is bound to scope + hub id; a store bound to anything else (including no hub) is wiped at `start()`.
- Zone deletion goes through a small `CloudZoneAdministering` seam beside the engine seam: the hub's own zones (Settings off) and the legacy fixed-name zones (first start on the new build).
- The Mac hub builds its transport and its shares with `HubSyncState.ensureHubID()`. `HubIdentity` keeps `hub_id`, `enabled_at` and the heartbeat write; the foreign-heartbeat read, `.otherHub`, `takeOver()`, `onTakeOver` and `.tookOver` go.
- `ActionRequestPayload` and `RecordingUploadPayload` gain `hub_id`; `RelayProcessor` echoes `failed` / `wrong_hub` for another hub's record.

**Tech Stack:** Swift 5.10 language mode, CloudKit `CKSyncEngine` (macOS 14 / iOS 17), GRDB 7, XCTest; packages `WatchtowerKit` (`WatchtowerSync`), `WatchtowerDesktop`, `WatchtowerMobile` (xcodegen).

**Spec:** `docs/superpowers/specs/2026-10-11-mobile-multi-hub-design.md` (owner-approved; § numbers below refer to it). Base spec: `docs/superpowers/specs/2026-10-07-mobile-poc-design.md`. Feature notes: `docs/features/mobile-companion.md`.

**Scope:** phase F, part 1 (spec §8 steps 1–3, and the docs of step 8 for what F1 changes). F2 (`HubRegistry`, `HubSession`, inactive cadence, per-hub notifications, switcher, `LinkPayload v: 2`, the 4-hub limit) is out of scope.

**Execution (owner requirement):**
- Executed by subagents in a git worktree: superpowers:subagent-driven-development plus superpowers:using-git-worktrees. Branch `feature/mobile-multi-hub-f1` off `feature/mobile-poc`.
- A new worktree copies the main checkout's `WatchtowerDesktop/.build` into itself, then deletes the path-bound `ModuleCache` inside it (CLAUDE.md; about 1 min rebuild instead of minutes cold). Never delete `.build` otherwise.
- Heavy Swift work runs one lane at a time: one Desktop or phone build at a time. Kit-only tasks (3, 4) may run beside one Desktop or phone task.
- Each task runs only its task-scope checks (the commands in its steps plus `make lint-diff`). The controller runs `bash scripts/dev-health.sh` before each task and the full gate once at the phase end (see Phase end).
- No polling turns. Run a long command to a log with an explicit exit code: `cmd > /tmp/<name>.log 2>&1; echo "exit=$?"`.
- Public repo hygiene: no real ids, Apple IDs, team ids, emails, names or local paths in code, tests, logs or results. Use `acme`, `hub-acme`, `_owner-acme`, "colleague A", `<team-id>`.

---

## Global Constraints

Verbatim values from the spec:

- **Zones:** the hub writes `DataZone-<hub_id>` and `RelayZone-<hub_id>` in its owner's private database (§3.1). `hub_id` is the existing per-install UUID in `hub_meta` (`HubSyncState.ensureHubID()`), kept across account resets.
- **Transport:** `CloudKitTransport(store:, scope:, hubID:, role:)`; `role` is `.hub` or `.phone` (§4.1).
- **Zone kinds stay the API:** `CloudZoneID` (`.data`, `.relay`) remains the protocol's zone parameter. The transport maps a kind to `CKRecordZone.ID(zoneName: "<Kind>Zone-<hubID>", ownerName: …)` (§4.1).
- **Filter:** `cloudZone(for:)` maps a server zone back to a kind only when the name matches this transport's hub and, in shared scope, the owner matches. Two hubs of one foreign owner never cross (§4.1).
- **Role rule:** zone writes depend on `role`, not on scope. Only `.hub` saves zones. A `.phone` transport never creates or deletes a zone, so a removed hub's zone is never resurrected (§4.1).
- **Engine scope:** every fetch and send passes `CKSyncEngine.FetchChangesOptions(scope: .zoneIDs(own))` and `SendChangesOptions(scope: .zoneIDs(own))` (§4.2).
- **Stores:** one `TransportStore` per hub; `adoptScope` keeps its wipe-on-scope-change semantics, now per hub. The Mac path is unchanged: `MobileHub/transport.db` (§4.4).
- **I-1 replaced:** "a hub publishes only into its own zones; a phone links to at most 4 hubs and shows one at a time" (§2). The heartbeat is still written every 300 s, into the hub's own DataZone (§3.2).
- **Zone lifecycle:** only the hub creates and deletes its zones. Turning the mobile hub off in Settings deletes the hub's two zones and its staged assets (§3.3).
- **Legacy zones (§3.6):** the hub deletes the legacy fixed-name `DataZone`/`RelayZone` at its first start on the new build, only when they hold its own heartbeat or no heartbeat.
- **Addressing (§3.5):** `ActionRequestPayload` and `RecordingUploadPayload` gain `hub_id`; `RelayProcessor` echoes `failed` / `wrong_hub` for a record whose `hub_id` is not its own.
- **Not in F1:** `LinkPayload v: 2` (§6.7), the 4-hub limit, `HubRegistry`, `HubSession`.
- **Platforms:** Swift 5.10 language mode; Kit macOS 14 / iOS 17; Desktop macOS 14+; phone iOS 17+.
- **F1 phone bridge (this plan's decision, replaced by F2's `HubRegistry`):** a live phone builds its transport for the hub of its saved link (`LinkRecord.hubID`), or of the pending link while it waits for the grant. With no link it uses `AppEnvironment.unlinkedHubID = "unlinked"`, a hub no Mac has zones for.

## Review Focus

Five failure modes the spec-derived tests do not otherwise cover, most likely first. Each has a test in the task that owns it.

1. **Records of another hub leak into this transport.** A poll page, an engine event, a sent-change report or a zone deletion about `DataZone-<other hub>`, or about the legacy `DataZone`, would be buffered or acted on, so one Mac's data appears under another. Test: `testRecordsAndDeletionsOfAnotherHubOrTheLegacyZoneAreIgnored` → Task 3.
2. **Archived system fields retarget a save to the legacy zone.** `ckRecord(from:in:systemFields:)` takes the record id from the archive, so a store that kept single-hub system fields would save into the old `DataZone`. Test: `testAStoreBoundToNoHubIsWipedSoNoSaveTargetsTheLegacyZone` → Task 3.
3. **First start on the new build: the relay cursor runs ahead of the wiped store.** The store's event seqs restart, but the sidecar's `relay_change_token` remembers the old seqs, so phone actions in the new RelayZone are never read. Test: `testFirstStartOnPerHubZonesForgetsPublishStateAndTheRelayCursorButKeepsTheLedger` → Task 7.
4. **Legacy cleanup deletes the zones of a second Mac still on the old build.** Its heartbeat is another `hub_id`, or this build can't read it. Tests: `testLegacyZonesWithAnotherHubsHeartbeatAreKept` (Kit, Task 4) and `testLegacyZonesAreDeletedOnlyForOwnOrNoHeartbeatAndCheckedOnce` (Mac, Task 7).
5. **Turning the hub off while offline leaves half a state.** For example, the sync state is wiped but the zones are still there, or the phones are forgotten but still share the zones. Test: `testDisableWhileTheZoneDeleteFailsKeepsSyncStateAndLinkedPhones` → Task 7.

## Guard tests and deliberate test removals

- `docs/inventory/` holds **no** guard test for the mobile hub, the Kit transport or the single-hub rule (checked: `grep -rn "otherHub\|takeOver\|I-1\|single-hub\|MobileHub\|CloudKitTransport" docs/inventory/` finds only the workbench note of 2026-10-10, which states no contract changed). No owner ask is needed for a guard test.
- The owner approved replacing I-1 (spec §2). The tests that assert I-1 or take over are therefore **deleted or rewritten on purpose** in Task 6. They are listed by name there, and the commit message says so. None of them may be "kept passing" by re-adding the refusal.

---

## Task 1: F0 spike harness (throwaway)

**Depends on:** none. **Lane:** its own branch; nothing from it is merged.

**Files** (branch `spike/multi-hub-f0`, created from `spike/cloudkit-share`, which holds the S0 harness in `spikes/cloudkit-share/`):
- Modify `spikes/cloudkit-share/Shared/SpikeCore.swift`: add hub zone names and a hub engine delegate.
- Modify `spikes/cloudkit-share/Mac/main.swift`: add the `hubs-*` commands.
- Modify `spikes/cloudkit-share/iOS/Harness.swift` and `iOS/SpikeApp.swift`: add the F0 buttons.
- Create `spikes/cloudkit-share/F0-RESULTS.md`.

**Interfaces:** none kept. APIs exercised: `CKSyncEngine` with `FetchChangesOptions(scope: .zoneIDs)` and `SendChangesOptions(scope: .zoneIDs)`, `CKSyncEngineDelegate.nextFetchChangesOptions(_:syncEngine:)`, `CKSyncEngine.State.Serialization`, `CKDatabase.modifyRecordZones`, zone-wide `CKShare`.

- [ ] **Step 1: Shared core.** Add to `SpikeCore.swift`:

```swift
extension Spike {
    /// Spike hubs: A, B, C on the owner's private database; D, E shared to Apple ID B.
    static let privateHubs = ["f0-hub-a", "f0-hub-b", "f0-hub-c"]
    static let sharedHubs = ["f0-hub-d", "f0-hub-e"]
    static func hubZoneName(_ kind: String, hub: String) -> String { "\(kind)-\(hub)" }   // kind: dataZone / relayZone
    static func hubZoneIDs(_ hub: String, owner: String = CKCurrentUserDefaultName) -> [CKRecordZone.ID] {
        [dataZone, relayZone].map { zoneID(hubZoneName($0, hub: hub), owner: owner) }
    }
}

/// One phone-role engine per hub: scoped fetches, counts of what each engine saw.
final class F0HubDelegate: CKSyncEngineDelegate, @unchecked Sendable {
    let hub: String
    let own: [CKRecordZone.ID]
    private let lock = NSLock()
    private(set) var foreignRecords = 0     // records of a zone not in `own`
    private(set) var ownRecords = 0
    private(set) var deletedZones: [String] = []
    init(hub: String, own: [CKRecordZone.ID]) { self.hub = hub; self.own = own }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            UserDefaults.standard.set(try? JSONEncoder().encode(update.stateSerialization), forKey: "f0.state.\(hub)")
        case .fetchedRecordZoneChanges(let changes):
            lock.withLock {
                for m in changes.modifications {
                    if own.contains(m.record.recordID.zoneID) { ownRecords += 1 } else { foreignRecords += 1 }
                }
            }
        case .fetchedDatabaseChanges(let changes):
            lock.withLock { deletedZones += changes.deletions.map(\.zoneID.zoneName) }
        default: break
        }
    }

    func nextFetchChangesOptions(
        _ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.FetchChangesOptions {
        var options = context.options
        options.scope = .zoneIDs(own)
        return options
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? { nil }
}
```

- [ ] **Step 2: Mac commands** in `Mac/main.swift` `switch command`:
  - `hubs-setup` creates `DataZone-f0-hub-{a,b,c}` and `RelayZone-…` in the private DB with one seed record each.
  - `hubs-write <hub>` saves one record `probe-<epochMillis>` into `DataZone-<hub>`, which triggers a push.
  - `hubs-delete <hub>` deletes that hub's two zones.
  - `hubs-share` creates `DataZone-`/`RelayZone-` for `f0-hub-d` and `f0-hub-e`, creates zone-wide shares (DataZone `.readOnly`, RelayZone `.readWrite`, public link open for the run), and prints one `ckspike://link?...` URL per hub (the existing `SpikeLink`/`writeQR` helpers).
  - `hubs-teardown` deletes every `*-f0-hub-*` zone.

  Each command prints the `RESULT`/step lines of `SpikeLog`.

- [ ] **Step 3: iPhone buttons** in `Harness.swift`. Each item ends with `SpikeLog.shared.result("F0-n", pass:, detail)`:
  - **F0-1 "Three engines, own zones":** build three `CKSyncEngine`s on the private DB, each with an `F0HubDelegate` and the state from `UserDefaults` `f0.state.<hub>`. Call `fetchChanges(.init(scope: .zoneIDs(own)))` on each. PASS when each `ownRecords ≥ 1` and every `foreignRecords == 0`. Then save one record into `RelayZone-<hub>` through engine A with `sendChanges(.init(scope: .zoneIDs(ownA)))`, and check that engines B and C sent nothing.
  - **F0-2 "Silent push wakes all":** register for remote notifications. The owner runs `hubs-write f0-hub-b` on the Mac with the app in the background. On the push, call `fetchChanges` on every engine. PASS when engine B's `ownRecords` grew, A and C saw no foreign record, and the time from the record's write to the fetch is logged.
  - **F0-3 "Zone delete hits one hub":** the owner runs `hubs-delete f0-hub-c`, then the button fetches every engine. PASS when only C's `deletedZones` names `DataZone-f0-hub-c`/`RelayZone-f0-hub-c` after the per-hub name filter (log the raw deletions of A and B too, since database changes may reach every engine), and A and B still fetch without error.
  - **F0-4 "Two hubs, one foreign owner" (Apple ID B):** accept both `hubs-share` links, then build two `.shared` engines scoped to `hubZoneIDs("f0-hub-d", owner:)` and `("f0-hub-e", owner:)`. The owner runs `hubs-write f0-hub-d` on the Mac. PASS when D's engine sees it, E's sees no foreign record, and a record E saves into `RelayZone-f0-hub-e` reaches the Mac (`fetch-relay` on the Mac, pointed at the hub zone).
  - **F0-5 "States survive a relaunch":** after F0-1 the owner kills and relaunches the app, then taps the button. It rebuilds the three engines from their saved states and fetches. PASS when no engine errors, each `ownRecords` counts only records written since the kill (no full re-download), and the three `f0.state.*` blobs differ.

- [ ] **Step 4: Build check.** Run `cd spikes/cloudkit-share && ./spike.sh check > /tmp/f0-check.log 2>&1; echo "exit=$?"`. Expected: `exit=0` (unsigned macOS, iOS device, simulator).

- [ ] **Step 5: Results file.** Create `F0-RESULTS.md` with a table: item, device and Apple ID role ("owner A" / "test B"), PASS/FAIL/PENDING, the timing line, and notes. No real ids.

- [ ] **Step 6: Commit (spike branch only):**

```bash
git add spikes/cloudkit-share
git commit -m "spike(mobile): F0 multi-hub harness (throwaway, never merged)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

## Task 2: F0 device run — owner check, go/no-go

**Depends on:** Task 1.

- [ ] **Step 1: File the ask.** The controller files `ask_owner` with `kind: "check"`, title "F0: one CKSyncEngine per hub on devices", reason "Phase F's Kit design depends on it (spec §4.3)". The summary gives the build commands from the spike README (`DEVELOPMENT_TEAM=<team-id> ./spike.sh mac` / `ios-install <udid>`) and the go/no-go rule below. Checklist:
  1. `id: f0-1` — "Three engines on one private DB: each sees only its own hub's zones (button F0-1 after `hubs-setup`)."
  2. `id: f0-2` — "Silent push with the app in the background: every engine catches up after `hubs-write f0-hub-b` (F0-2)."
  3. `id: f0-3` — "`hubs-delete f0-hub-c`: only hub C's engine reports its zones gone; A and B keep working (F0-3)."
  4. `id: f0-4` — "Second Apple ID: two shared hubs of one owner side by side (F0-4). Needs a second Apple ID (board target #55). If you don't have one yet, mark this PENDING."
  5. `id: f0-5` — "Kill and relaunch: the three engine states come back without re-downloading or clobbering each other (F0-5)."

  The hint of each item asks the owner to paste the `RESULT (F0-n)` line.
- [ ] **Step 2: Record and decide.** When the answer arrives (`get_ask`), the controller records it in `F0-RESULTS.md` on the spike branch (commit as in Task 1, Step 6), then applies the go/no-go rule:
  - **GO:** F0-1, F0-2, F0-3 and F0-5 PASS, and F0-4 either PASS or PENDING. With F0-4 PENDING, the Kit's shared-scope path ships tested on the fake engine only. F2 must re-run F0-4 before it builds shared-scope multi-hub (the phase-F owner smoke covers it at the latest). The controller notes this on board target #55.
  - **NO-GO:** any of F0-1, F0-2, F0-3, F0-5 FAIL, or F0-4 FAIL. F1 stops after this task. Tasks 3 and 4 are replaced by a **multiplexing transport** (spec §4.3): one `CKSyncEngine` per database, and a per-hub view object conforming to `CloudSyncTransport` (and `CompactingTransport`/`SweepingTransport`) over it, which buffers into one `TransportStore` per hub and routes by the same `HubZones` mapping. The protocol and everything above it stay unchanged, so Tasks 5–8 still apply on top of it. The controller writes that plan as a replacement for Tasks 3–4 and asks the owner for review before any Kit code changes.

## Task 3: Kit — hub-aware transport, role, scoped fetch/send, per-hub store

**Depends on:** Task 2 (GO). **Lane:** Kit.

**Files:**
- Create `WatchtowerKit/Sources/WatchtowerSync/CloudKitTransport/HubZones.swift`.
- Modify `WatchtowerKit/Sources/WatchtowerSync/CloudKitTransport/CloudDatabaseScope.swift`: remove `writesZones`, `zoneID(for:)` and `cloudZone(for:)`; keep `database(in:)`.
- Modify `WatchtowerKit/Sources/WatchtowerSync/CloudKitTransport/SyncEngineDriving.swift`: scoped `fetchChanges`/`sendChanges`, driver built on `HubZones`.
- Modify `WatchtowerKit/Sources/WatchtowerSync/CloudKitTransport/CloudKitTransport.swift`: inits, `zones`/`role`, every `scope.writesZones` / `scope.zoneID(for:` / `scope.cloudZone(for:` site (lines 261–263, 347, 373, 404, 414–419, 472–475, 508, 528–541, 576–595, 621, 641, 717–728, 759–793, 823–847, 875–954, 985), `cloudRecord(from:zone:)` (1209), the `DelegateBox` (1230–1245), and `emitUnlinked` (1078).
- Modify `WatchtowerKit/Sources/WatchtowerSync/CloudKitTransport/TransportStore.swift`: `scope.hub_id`, `adoptScope(_:hubID:)`, `saveScope(_:hubID:)`, `storedHubID()`.
- Modify `WatchtowerKit/Sources/WatchtowerSync/Sync/CloudSyncTransport.swift`: the doc comment of `TransportEvent.unlinked` ("phone role" instead of "`shared` scope only").
- Test: create `WatchtowerKit/Tests/WatchtowerSyncTests/CloudKitTransportHubTests.swift`; modify `Support/FakeSyncEngine.swift`, `CloudKitTransportScopeTests.swift`, `CloudKitTransportPollTests.swift`, `CloudKitTransportErrorTests.swift`, `CloudKitTransportMappingTests.swift`, `CloudKitTransportResetTests.swift`, `CloudKitTransportStopTests.swift`, `TransportAssetTests.swift`, `TransportStoreTests.swift`.
- Modify `WatchtowerDesktop/Sources/Services/MobileHub/MobileHubService.swift:78` and `WatchtowerMobile/Sources/App/AppEnvironment.swift:139` with a one-line compile fix only (the real wiring is in Tasks 6 and 8): `CloudKitTransport(store: store, scope: .private, hubID: try sidecar.ensureHubID(), role: .hub)`; this moves the `sidecar` line above the store line. On the phone: `CloudKitTransport(store: transportStore, scope: scope, hubID: AppEnvironment.unlinkedHubID, role: .phone)` plus `static let unlinkedHubID = "unlinked"` on `AppEnvironment`.

**Interfaces (produces):**

```swift
public enum TransportRole: Equatable, Sendable { case hub, phone }

public struct HubZones: Equatable, Sendable {
    public let scope: CloudDatabaseScope
    public let hubID: String
    public init(scope: CloudDatabaseScope, hubID: String)
    public static func zoneName(_ zone: CloudZoneID, hubID: String) -> String     // "DataZone-<hubID>"
    public func zoneID(for zone: CloudZoneID) -> CKRecordZone.ID
    public var allZoneIDs: [CKRecordZone.ID]                                       // data, relay
    public func cloudZone(for zoneID: CKRecordZone.ID) -> CloudZoneID?
    static var legacyZoneIDs: [CKRecordZone.ID]                                    // "DataZone", "RelayZone", private
}

// CloudKitTransport
public init(store: TransportStore, scope: CloudDatabaseScope, hubID: String, role: TransportRole,
            containerID: String = WatchtowerCloud.containerID)
nonisolated public let zones: HubZones
nonisolated public let role: TransportRole
nonisolated public var scope: CloudDatabaseScope { get }   // zones.scope (kept: callers read it)
static func cloudRecord(from ck: CKRecord, zone: CloudZoneID) -> CloudRecord?

// SyncEngineDriving
func fetchChanges(scope zoneIDs: [CKRecordZone.ID]) async throws
func sendChanges(scope zoneIDs: [CKRecordZone.ID]) async throws

// TransportStore
public func storedHubID() throws -> String?
func saveScope(_ scope: CloudDatabaseScope, hubID: String) throws
@discardableResult func adoptScope(_ scope: CloudDatabaseScope, hubID: String) throws -> Bool
```

**Consumes:** `CloudZoneID`, `CloudDatabaseScope`, `PolledZoneChanges`, the existing `FakeSyncEngine`.

- [ ] **Step 1: Test support.** In `Support/FakeSyncEngine.swift`:
  - change `fetchChanges()`/`sendChanges()` to the scoped signatures, recording each call's `zoneIDs` in `fetchScopes` / `sendScopes` (`[[CKRecordZone.ID]]`, lock-guarded like `zoneFetches`);
  - add the helpers below;
  - give `testing` two parameters, `hubID: String = HubZones.testHubID` and `role: TransportRole? = nil`, passed to the transport as `role: role ?? (scope == .private ? .hub : .phone)` (so every existing private-scope test keeps its hub meaning and every shared one its phone meaning).

```swift
extension HubZones {
    static let testHubID = "hub-test"
    static func test(_ scope: CloudDatabaseScope = .private) -> HubZones { HubZones(scope: scope, hubID: testHubID) }
    static let testDataZoneName = zoneName(.data, hubID: testHubID)
    static let testRelayZoneName = zoneName(.relay, hubID: testHubID)
}
```

- [ ] **Step 2: Write the failing tests** in `CloudKitTransportHubTests.swift`:

```swift
import CloudKit
import XCTest
@testable import WatchtowerSync

/// Multi-hub spec §4: a transport knows its hub, maps zone kinds to
/// `<Kind>Zone-<hubID>`, ignores every other hub, and only a hub writes zones.
final class CloudKitTransportHubTests: XCTestCase {
    private let owner = "_owner-acme"
    private var shared: CloudDatabaseScope { .shared(ownerName: owner) }

    private func record(_ name: String, zone: CloudZoneID = .relay) -> CloudRecord {
        CloudRecord(recordName: name, zone: zone, kind: "action", modifiedAt: Date(), payload: Data("{}".utf8))
    }

    private func ckRecord(_ name: String, in zoneID: CKRecordZone.ID) -> CKRecord {
        let ck = CKRecord(recordType: "WatchtowerRecord", recordID: CKRecord.ID(recordName: name, zoneID: zoneID))
        ck.encryptedValues["payload"] = Data("{}".utf8)
        ck["kind"] = "action"
        ck["modifiedAt"] = Date(timeIntervalSince1970: 1_700_000_000)
        return ck
    }

    private func savedZoneNames(_ engine: FakeSyncEngine) -> [String] {
        engine.databaseChanges.compactMap { if case .saveZone(let zone) = $0 { return zone.zoneID.zoneName } else { return nil } }
    }

    func testZoneNamesCarryTheHubID() {
        let zones = HubZones(scope: .private, hubID: "hub-acme")
        XCTAssertEqual(zones.zoneID(for: .data).zoneName, "DataZone-hub-acme")
        XCTAssertEqual(zones.zoneID(for: .relay).zoneName, "RelayZone-hub-acme")
        XCTAssertEqual(zones.zoneID(for: .data).ownerName, CKCurrentUserDefaultName)
        XCTAssertEqual(HubZones(scope: shared, hubID: "hub-acme").zoneID(for: .relay).ownerName, owner)
        XCTAssertEqual(zones.allZoneIDs.map(\.zoneName), ["DataZone-hub-acme", "RelayZone-hub-acme"])
    }

    func testCloudZoneMatchesOnlyThisHubAndInSharedScopeThisOwner() {
        let zones = HubZones(scope: .private, hubID: "hub-acme")
        XCTAssertEqual(zones.cloudZone(for: zones.zoneID(for: .relay)), .relay)
        XCTAssertNil(zones.cloudZone(for: HubZones(scope: .private, hubID: "hub-other").zoneID(for: .data)))
        XCTAssertNil(zones.cloudZone(for: CKRecordZone.ID(zoneName: "DataZone", ownerName: CKCurrentUserDefaultName)),
                     "the single-hub build's zone is not ours")
        XCTAssertNil(zones.cloudZone(for: CKRecordZone.ID(zoneName: "DataZone-hub-acme-x", ownerName: CKCurrentUserDefaultName)))
        let sharedZones = HubZones(scope: shared, hubID: "hub-acme")
        XCTAssertNil(sharedZones.cloudZone(for: CKRecordZone.ID(zoneName: "DataZone-hub-acme", ownerName: "_someone-else")))
        XCTAssertNil(sharedZones.cloudZone(for: HubZones(scope: shared, hubID: "hub-acme-2").zoneID(for: .data)),
                     "two hubs of one foreign owner never cross")
    }

    func testHubRoleStartRegistersItsOwnTwoZones() async throws {
        let engine = FakeSyncEngine()
        _ = await CloudKitTransport.testing(store: try .inMemory(), engine: engine)
        XCTAssertEqual(savedZoneNames(engine), [HubZones.testDataZoneName, HubZones.testRelayZoneName])
    }

    func testPhoneRoleInPrivateScopeNeverWritesZonesAndUnlinksWhenItsHubsZonesGo() async throws {
        let engine = FakeSyncEngine()
        let transport = await CloudKitTransport.testing(store: try .inMemory(), role: .phone, engine: engine)
        let events = Collector<TransportEvent>()
        await transport.setEventHandler { events.append($0) }

        await transport.handleDeletedZones([HubZones.test().zoneID(for: .data)])
        await transport.resetForAccountChange()
        await transport.restartTask?.value

        XCTAssertTrue(engine.databaseChanges.isEmpty, "a phone never creates or deletes a zone")
        XCTAssertEqual(events.values, [.unlinked])
    }

    func testFetchAndSendAreScopedToThisHubsZones() async throws {
        let engine = FakeSyncEngine()
        let transport = await CloudKitTransport.testing(store: try .inMemory(), engine: engine)
        try await transport.save([record("action-1")])

        try await transport.pull()
        await transport.sendNow()

        let own = HubZones.test().allZoneIDs
        XCTAssertFalse(engine.fetchScopes.isEmpty)
        XCTAssertTrue(engine.fetchScopes.allSatisfy { $0 == own })
        XCTAssertEqual(engine.sendScopes, [own])
        XCTAssertEqual(Set(engine.zoneFetches.map(\.zoneID)), Set(own), "the poll reads only this hub's zones")
    }

    /// Review focus 1.
    func testRecordsAndDeletionsOfAnotherHubOrTheLegacyZoneAreIgnored() async throws {
        let store = try TransportStore.inMemory()
        let transport = await CloudKitTransport.testing(store: store)
        let events = Collector<TransportEvent>()
        await transport.setEventHandler { events.append($0) }
        let other = HubZones(scope: .private, hubID: "hub-other").zoneID(for: .relay)
        let legacy = CKRecordZone.ID(zoneName: "RelayZone", ownerName: CKCurrentUserDefaultName)
        let own = HubZones.test().zoneID(for: .relay)

        await transport.bufferFetched(
            modifications: [ckRecord("action-other", in: other), ckRecord("action-legacy", in: legacy), ckRecord("action-own", in: own)],
            deletions: [CKRecord.ID(recordName: "action-gone", zoneID: other)]
        )
        await transport.handleDeletedZones([other, legacy])
        await transport.handleSentChanges(
            saved: [ckRecord("action-x", in: other)], deleted: [], failedSaves: [], failedDeletes: [:]
        )

        let batch = try await transport.changes(in: .relay, since: nil)
        XCTAssertEqual(batch.changed.map(\.recordName), ["action-own"])
        XCTAssertTrue(batch.deletedRecordNames.isEmpty)
        XCTAssertNil(try store.systemFields(recordName: "action-other", zone: .relay))
        XCTAssertTrue(events.values.isEmpty)
    }

    /// Review focus 2: archived single-hub system fields carry the legacy
    /// zone in their record id; a store bound to no hub is wiped at start.
    func testAStoreBoundToNoHubIsWipedSoNoSaveTargetsTheLegacyZone() async throws {
        let store = try TransportStore.inMemory()
        let legacy = CKRecordZone.ID(zoneName: "RelayZone", ownerName: CKCurrentUserDefaultName)
        try store.saveSystemFields(CloudKitTransport.archivedSystemFields(of: ckRecord("action-1", in: legacy)),
                                   recordName: "action-1", zone: .relay)
        try store.enqueueSave([record("action-1")])

        let transport = await CloudKitTransport.testing(store: store)
        try await transport.save([record("action-1")])
        let batch = await transport.nextEngineBatch()

        XCTAssertEqual(batch?.recordsToSave.map(\.recordID.zoneID.zoneName), [HubZones.testRelayZoneName])
        XCTAssertEqual(try store.storedHubID(), HubZones.testHubID)
    }

    func testAStoreOfAnotherHubIsWipedAndOfTheSameHubKept() async throws {
        let store = try TransportStore.inMemory()
        try store.saveScope(.private, hubID: "hub-other")
        try store.saveEngineState(Data("other-engine".utf8))
        _ = await CloudKitTransport.testing(store: store)
        XCTAssertNil(try store.loadEngineState(), "another hub's engine state must not drive this hub")

        try store.saveEngineState(Data("own-engine".utf8))
        _ = await CloudKitTransport.testing(store: store)
        XCTAssertEqual(try store.loadEngineState(), Data("own-engine".utf8))
    }
}
```

- [ ] **Step 3: Run to fail.** `make kit-test FILTER=CloudKitTransportHubTests > /tmp/t3a.log 2>&1; echo "exit=$?"`. Expected: a build failure (`HubZones`, `role:`, `fetchScopes` unknown).

- [ ] **Step 4: Implement `HubZones.swift`:**

```swift
import CloudKit

/// Which side of a link a transport plays (multi-hub spec §4.1). Only the
/// hub creates, re-creates and deletes zones; a phone never does, so a zone
/// its hub removed is never resurrected — the phone reads it as unlinked.
public enum TransportRole: Equatable, Sendable {
    case hub
    case phone
}

/// The two zones of one hub (multi-hub spec §3.1, §4.1): `DataZone-<hubID>`
/// and `RelayZone-<hubID>`, owned by the hub's iCloud user. Maps a zone kind
/// to its server id and back; a zone of another hub, the single-hub build's
/// fixed-name zones, and (shared scope) another owner's zones are not ours.
public struct HubZones: Equatable, Sendable {
    public let scope: CloudDatabaseScope
    public let hubID: String

    public init(scope: CloudDatabaseScope, hubID: String) {
        self.scope = scope
        self.hubID = hubID
    }

    public static func zoneName(_ zone: CloudZoneID, hubID: String) -> String {
        "\(zone.rawValue)-\(hubID)"
    }

    public func zoneID(for zone: CloudZoneID) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: Self.zoneName(zone, hubID: hubID), ownerName: ownerName)
    }

    public var allZoneIDs: [CKRecordZone.ID] {
        CloudZoneID.allCases.map(zoneID(for:))
    }

    public func cloudZone(for zoneID: CKRecordZone.ID) -> CloudZoneID? {
        guard let zone = CloudZoneID.allCases.first(where: { Self.zoneName($0, hubID: hubID) == zoneID.zoneName }) else {
            return nil
        }
        if case .shared(let owner) = scope, zoneID.ownerName != owner { return nil }
        return zone
    }

    /// The single-hub build's fixed-name zones in the private database
    /// (multi-hub spec §3.6).
    static var legacyZoneIDs: [CKRecordZone.ID] {
        CloudZoneID.allCases.map { CKRecordZone.ID(zoneName: $0.rawValue, ownerName: CKCurrentUserDefaultName) }
    }

    private var ownerName: String {
        switch scope {
        case .private: return CKCurrentUserDefaultName
        case .shared(let owner): return owner
        }
    }
}
```

- [ ] **Step 5: Implement the transport changes.**
  - Stored properties: replace `nonisolated public let scope: CloudDatabaseScope` with `nonisolated public let zones: HubZones`, `nonisolated public let role: TransportRole`, `nonisolated public var scope: CloudDatabaseScope { zones.scope }`, and add `private var managesZones: Bool { role == .hub }`.
  - Public init: `public init(store: TransportStore, scope: CloudDatabaseScope, hubID: String, role: TransportRole, containerID: String = WatchtowerCloud.containerID)`. Build `let zones = HubZones(scope: scope, hubID: hubID)`. The engine factory becomes `CKSyncEngineDriver(containerID: containerID, zones: zones, stateSerialization: state, delegate: delegate)`. Start with `precondition(role == .phone || scope == .private, "a hub syncs its own private database")`.
  - The internal test init takes `hubID: String` and `role: TransportRole` after `scope`. `CloudKitTransportStopTests` (lines 26, 49) pass `hubID: HubZones.testHubID, role: .hub`; `CloudKitTransportResetTests:26` uses `CloudKitTransport(store: store, scope: .private, hubID: HubZones.testHubID, role: .hub)`.
  - Mechanical replacements across the file: `scope.writesZones` → `managesZones`; `scope.zoneID(for:` → `zones.zoneID(for:`; `scope.cloudZone(for:` → `zones.cloudZone(for:`. In `startEngine`, use `CloudZoneID.allCases.map { .saveZone(CKRecordZone(zoneID: zones.zoneID(for: $0))) }` and `store.adoptScope(scope, hubID: zones.hubID)`.
  - `engine.fetchChanges()` (in `fetchAndHandle` and `refetchAfterExpiredToken`) → `engine.fetchChanges(scope: zones.allZoneIDs)`. `engine.sendChanges()` (in `resend`) → `engine.sendChanges(scope: zones.allZoneIDs)`.
  - `bufferFetched`: map each kept modification with `zones.cloudZone(for: modification.recordID.zoneID).flatMap { Self.cloudRecord(from: modification, zone: $0) }`. `cloudRecord(from:zone:)` drops the `CloudZoneID(rawValue: zoneName)` guard and uses `zone`.
  - `emitUnlinked` logs `"hub zones gone (\(reason)); unlinked"`. Reword the doc comments that say "`shared` scope" for the unlinked rules to "phone role", and those that say "`private` scope" for zone re-creation to "hub role".
  - `DelegateBox` gains `let ownZoneIDs: [CKRecordZone.ID]` (set in `startEngine`: `DelegateBox(ownZoneIDs: zones.allZoneIDs)`) and:

```swift
    /// The engine's own (push-driven) fetches read this hub's zones only
    /// (multi-hub spec §4.2): another hub's changes are never downloaded.
    func nextFetchChangesOptions(
        _ context: CKSyncEngine.FetchChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.FetchChangesOptions {
        var options = context.options
        options.scope = .zoneIDs(ownZoneIDs)
        return options
    }
```

- [ ] **Step 6: Implement the driver.** In `SyncEngineDriving.swift`, the protocol takes the scoped `fetchChanges(scope:)`/`sendChanges(scope:)`. `CKSyncEngineDriver` stores `zones: HubZones` instead of `scope` (`init(containerID:zones:stateSerialization:delegate:)`, database `zones.scope.database(in:)`), and:

```swift
    func fetchChanges(scope zoneIDs: [CKRecordZone.ID]) async throws {
        try await engine.fetchChanges(CKSyncEngine.FetchChangesOptions(scope: .zoneIDs(zoneIDs)))
    }

    func sendChanges(scope zoneIDs: [CKRecordZone.ID]) async throws {
        try await engine.sendChanges(CKSyncEngine.SendChangesOptions(scope: .zoneIDs(zoneIDs)))
    }

    func existingZoneNames() async throws -> Set<String> {
        let all = try await database.allRecordZones()
        return Set(all.compactMap { zones.cloudZone(for: $0.zoneID)?.rawValue })
    }
```

- [ ] **Step 7: Implement the per-hub store binding** in `TransportStore.swift`:
  - In `createSchema`, after the `creator` patch: `if try !db.columns(in: "scope").contains(where: { $0.name == "hub_id" }) { try db.execute(sql: "ALTER TABLE scope ADD COLUMN hub_id TEXT") }`.
  - `readScope` becomes `readBinding(_ db:) -> (scope: CloudDatabaseScope, hubID: String?)?` (selects `kind, owner_name, hub_id`). `storedScope()` returns `.scope`; the new `storedHubID()` returns `.hubID`.
  - `writeScope(_:hubID:_:)` upserts `hub_id` too.
  - `saveScope(_:hubID:)` follows the same pattern.
  - `adoptScope(_ scope:, hubID:)`:

```swift
    /// Binds the store to `scope` and `hubID` (multi-hub spec §4.4). Engine
    /// state, system fields and buffered events of another database or
    /// another hub mean nothing here — archived system fields even name the
    /// old zone — so a store bound to anything else, or to no hub (every
    /// store of the single-hub build), is wiped first. Returns whether it was.
    @discardableResult
    func adoptScope(_ scope: CloudDatabaseScope, hubID: String) throws -> Bool {
        let wiped = try queue.write { db in
            let stored = try Self.readBinding(db)
            let wipe = stored?.scope != scope || stored?.hubID != hubID
            if wipe { try Self.wipeState(db) }
            try Self.writeScope(scope, hubID: hubID, db)
            return wipe
        }
        if wiped { sweepUnreferencedStash() }
        return wiped
    }
```

  Update the `startEngine` log line: "transport store held another database's or hub's state; wiped it".

- [ ] **Step 8: Update the existing tests mechanically.** Replacement rules:
  - `CloudDatabaseScope.private.zoneID(for: X)` → `HubZones.test().zoneID(for: X)`.
  - In `CloudKitTransportScopeTests` and `CloudKitTransportPollTests`, `shared.zoneID(for:` → `sharedZones.zoneID(for:`, with `private var sharedZones: HubZones { .test(shared) }`.
  - Zone-name literals `"DataZone"` / `"RelayZone"` passed to `enqueueZonePage(zoneName:)`, compared with `zoneID.zoneName`, or used in `CKRecordZone.ID(zoneName:ownerName:)` for a foreign *owner* → `HubZones.testDataZoneName` / `HubZones.testRelayZoneName`. The tests still check the owner filter, not the name filter.
  - `FakeSyncEngine(existingZones: ["DataZone"])` stays: `existingZoneNames()` returns kind names.
  - `CloudKitTransport.cloudRecord(from: ck)` → `cloudRecord(from: ck, zone: .data)` (Mapping, TransportAsset).
  - Delete `CloudKitTransportMappingTests.testUnknownZoneNameMapsToNil`; `testCloudZoneMatchesOnlyThisHubAndInSharedScopeThisOwner` covers it.
  - `testScopeDatabaseAndZoneOwner`: assert on `HubZones.test(...)` and `transport.role`.
  - `testPrivateScopeStartRegistersBothZones`: expect `[HubZones.testDataZoneName, HubZones.testRelayZoneName]`.
  - `store.saveScope(X)` → `store.saveScope(X, hubID: HubZones.testHubID)`.
  - `testStoreWithoutARecordedScopeAdoptsItAndKeepsState` is **rewritten on purpose** as `testStoreWithoutABindingIsWipedOnAdopt`: same setup, now asserting `loadEngineState()` is nil and the queue is empty. Per-hub binding means a single-hub store must not keep its state (Review focus 2).
  - `testStoredScopeSurvivesAccountWipe` also asserts `storedHubID()` survives.

  Afterwards, `grep -rnE '"(Data|Relay)Zone"|CloudDatabaseScope\.private\.zoneID|cloudRecord\(from: [a-z]+\)' WatchtowerKit/Tests` may show only the `existingZones:` kind-name use.

- [ ] **Step 9: Run to pass.** `make kit-test FILTER='CloudKitTransport|TransportStore|TransportAsset' > /tmp/t3b.log 2>&1; echo "exit=$?"`. Expected: `exit=0`, `CloudKitTransportHubTests` 8 tests pass, and no test of the five other classes is skipped.

- [ ] **Step 10: Compile the dependants.** `make test-swift FILTER=MobileHubServiceTests > /tmp/t3c.log 2>&1; echo "exit=$?"` and `make mobile-build > /tmp/t3d.log 2>&1; echo "exit=$?"`. Expected: both `exit=0` (the Step-level compile fixes only; behaviour lands in Tasks 6 and 8). Then `make lint-diff`.

- [ ] **Step 11: Commit.**

```bash
git add WatchtowerKit WatchtowerDesktop/Sources/Services/MobileHub/MobileHubService.swift WatchtowerMobile/Sources/App/AppEnvironment.swift
git commit -m "feat(kit): hub-aware CloudKitTransport — per-hub zones, role, scoped engine, per-hub store

Zone kinds map to <Kind>Zone-<hubID>; only the hub role writes zones; fetch
and send are scoped to the hub's zones; a store bound to another hub or to
none is wiped at start (multi-hub spec §4.1, §4.2, §4.4).

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

## Task 4: Kit — hub zone deletion and legacy zone cleanup

**Depends on:** Task 3. **Lane:** Kit.

**Files:**
- Create `WatchtowerKit/Sources/WatchtowerSync/CloudKitTransport/CloudZoneAdmin.swift`.
- Modify `WatchtowerKit/Sources/WatchtowerSync/CloudKitTransport/CloudKitTransport.swift`: inits (a `zoneAdmin` parameter) and a new extension "Hub zones".
- Test: create `WatchtowerKit/Tests/WatchtowerSyncTests/CloudKitTransportZoneAdminTests.swift`; add `FakeZoneAdmin` to `Support/FakeSyncEngine.swift` and a `zoneAdmin:` parameter (default `FakeZoneAdmin()`) to `testing`.

**Interfaces (produces):**

```swift
protocol CloudZoneAdministering: Sendable {
    func zoneIDs() async throws -> [CKRecordZone.ID]
    func record(_ id: CKRecord.ID) async throws -> CKRecord?          // nil: no such record or zone
    func deleteZones(_ ids: [CKRecordZone.ID]) async throws           // an already-gone zone counts as deleted
}
struct CKDatabaseZoneAdmin: CloudZoneAdministering { init(containerID: String, scope: CloudDatabaseScope) }

public enum LegacyZoneCleanup: String, Equatable, Sendable { case noneFound = "none_found", deleted, kept }
public enum HubZoneError: Error, Equatable { case notHub, noEntitlement, engineRunning }

// CloudKitTransport
public func deleteHubZones() async throws
public func removeLegacyZones(deleteIf: @Sendable (_ heartbeatPayload: Data?) -> Bool) async throws -> LegacyZoneCleanup
```

**Consumes:** `HubZones`, `HubZones.legacyZoneIDs`, `HeartbeatPayload.recordName`, `TransportStore.wipe()`.

- [ ] **Step 1: Fake.** Add to `Support/FakeSyncEngine.swift`:

```swift
/// Zones and records on a fake server, for the hub's zone deletions.
final class FakeZoneAdmin: CloudZoneAdministering, @unchecked Sendable {
    private let lock = NSLock()
    private var zones: [CKRecordZone.ID]
    private var records: [CKRecord.ID: CKRecord]
    private var _deleted: [[CKRecordZone.ID]] = []
    private var failure: Error?

    init(zones: [CKRecordZone.ID] = [], records: [CKRecord] = [], failure: Error? = nil) {
        self.zones = zones
        self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.recordID, $0) })
        self.failure = failure
    }

    var deleted: [[CKRecordZone.ID]] { lock.withLock { _deleted } }

    func zoneIDs() async throws -> [CKRecordZone.ID] {
        try lock.withLock { if let failure { throw failure }; return zones }
    }

    func record(_ id: CKRecord.ID) async throws -> CKRecord? {
        lock.withLock { records[id] }
    }

    func deleteZones(_ ids: [CKRecordZone.ID]) async throws {
        try lock.withLock {
            if let failure { throw failure }
            _deleted.append(ids)
            zones.removeAll(where: ids.contains)
        }
    }
}
```

- [ ] **Step 2: Write the failing tests** (`CloudKitTransportZoneAdminTests.swift`):

```swift
import CloudKit
import XCTest
@testable import WatchtowerSync

/// Multi-hub spec §3.3 and §3.6: the hub deletes its own two zones when
/// turned off, and the single-hub build's zones only when they are its own.
final class CloudKitTransportZoneAdminTests: XCTestCase {
    private let legacyData = CKRecordZone.ID(zoneName: "DataZone", ownerName: CKCurrentUserDefaultName)
    private let legacyRelay = CKRecordZone.ID(zoneName: "RelayZone", ownerName: CKCurrentUserDefaultName)

    private func heartbeatRecord(hubID: String) throws -> CKRecord {
        let id = CKRecord.ID(recordName: HeartbeatPayload.recordName, zoneID: legacyData)
        let ck = CKRecord(recordType: "WatchtowerRecord", recordID: id)
        var heartbeat = HeartbeatFixtures.minimal(updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        heartbeat = HeartbeatPayload(
            updatedAt: heartbeat.updatedAt, appVersion: heartbeat.appVersion, hubID: hubID, macName: heartbeat.macName,
            flavor: heartbeat.flavor, lastPublishAt: nil, lastRelayAt: nil, relayBacklog: 0, accounts: [],
            enabledAt: heartbeat.enabledAt, ownerUser: heartbeat.ownerUser, sharing: .none
        )
        ck.encryptedValues["payload"] = try RelayCoder.makeEncoder().encode(heartbeat)
        return ck
    }

    private func isOwn(_ payload: Data?) -> Bool {
        guard let payload else { return true }
        return (try? RelayCoder.makeDecoder().decode(HeartbeatPayload.self, from: payload))?.hubID == "hub-own"
    }

    func testDeleteHubZonesDeletesOnlyThisHubsTwoZonesAndWipesTheStore() async throws {
        let store = try TransportStore.inMemory()
        let admin = FakeZoneAdmin(zones: HubZones.test().allZoneIDs + [legacyData])
        let transport = await CloudKitTransport.testing(store: store, zoneAdmin: admin)
        try await transport.save([CloudRecord(recordName: "heartbeat", zone: .data, kind: "heartbeat", modifiedAt: Date(), payload: Data("{}".utf8))])
        await transport.stop()

        try await transport.deleteHubZones()

        XCTAssertEqual(admin.deleted, [HubZones.test().allZoneIDs])
        XCTAssertTrue(try store.pendingBatch(limit: 10).saves.isEmpty, "the deleted zones' queue and state are gone")
    }

    func testDeleteHubZonesIsRefusedForAPhoneAndWhileTheEngineRuns() async throws {
        let phone = await CloudKitTransport.testing(store: try .inMemory(), role: .phone)
        await phone.stop()
        do { try await phone.deleteHubZones(); XCTFail("a phone never deletes zones") } catch HubZoneError.notHub {}

        let hub = await CloudKitTransport.testing(store: try .inMemory())
        do { try await hub.deleteHubZones(); XCTFail("stop first") } catch HubZoneError.engineRunning {}
    }

    func testNoLegacyZonesIsNoneFound() async throws {
        let admin = FakeZoneAdmin(zones: HubZones.test().allZoneIDs)
        let transport = await CloudKitTransport.testing(store: try .inMemory(), zoneAdmin: admin)
        let outcome = try await transport.removeLegacyZones(deleteIf: isOwn)
        XCTAssertEqual(outcome, .noneFound)
        XCTAssertTrue(admin.deleted.isEmpty)
    }

    func testLegacyZonesWithOwnOrNoHeartbeatAreDeleted() async throws {
        let own = FakeZoneAdmin(zones: [legacyData, legacyRelay], records: [try heartbeatRecord(hubID: "hub-own")])
        let first = await CloudKitTransport.testing(store: try .inMemory(), zoneAdmin: own)
        let deletedOwn = try await first.removeLegacyZones(deleteIf: isOwn)
        XCTAssertEqual(deletedOwn, .deleted)
        XCTAssertEqual(own.deleted, [[legacyData, legacyRelay]])

        let empty = FakeZoneAdmin(zones: [legacyRelay])
        let second = await CloudKitTransport.testing(store: try .inMemory(), zoneAdmin: empty)
        let deletedEmpty = try await second.removeLegacyZones(deleteIf: isOwn)
        XCTAssertEqual(deletedEmpty, .deleted, "no heartbeat: nobody else's")
    }

    /// Review focus 4.
    func testLegacyZonesWithAnotherHubsHeartbeatAreKept() async throws {
        let admin = FakeZoneAdmin(zones: [legacyData, legacyRelay], records: [try heartbeatRecord(hubID: "hub-other")])
        let transport = await CloudKitTransport.testing(store: try .inMemory(), zoneAdmin: admin)
        let outcome = try await transport.removeLegacyZones(deleteIf: isOwn)
        XCTAssertEqual(outcome, .kept)
        XCTAssertTrue(admin.deleted.isEmpty)
    }
}
```

`HeartbeatFixtures` is in `Support/SyncTestFixtures.swift`. If `RelayCoder.makeEncoder()` has another name, use the encoder `CloudRecordFactory.record(for:modifiedAt:)` uses.

- [ ] **Step 3: Run to fail.** `make kit-test FILTER=CloudKitTransportZoneAdminTests > /tmp/t4a.log 2>&1; echo "exit=$?"`. Expected: a build failure.

- [ ] **Step 4: Implement `CloudZoneAdmin.swift`:**

```swift
import CloudKit

/// Zone administration outside the engine (multi-hub spec §3.3, §3.6): the
/// hub's own zones when it is turned off, and the single-hub build's
/// leftovers. A seam like `SyncEngineDriving`, so it is testable unentitled.
protocol CloudZoneAdministering: Sendable {
    func zoneIDs() async throws -> [CKRecordZone.ID]
    /// nil when the record (or its zone) does not exist.
    func record(_ id: CKRecord.ID) async throws -> CKRecord?
    /// A zone that is already gone counts as deleted.
    func deleteZones(_ ids: [CKRecordZone.ID]) async throws
}

/// The CloudKit implementation. It reaches `CKContainer` only per call, and
/// the transport calls it only after its entitlement check.
struct CKDatabaseZoneAdmin: CloudZoneAdministering {
    let containerID: String
    let scope: CloudDatabaseScope

    private var database: CKDatabase { scope.database(in: CKContainer(identifier: containerID)) }

    func zoneIDs() async throws -> [CKRecordZone.ID] {
        try await database.allRecordZones().map(\.zoneID)
    }

    func record(_ id: CKRecord.ID) async throws -> CKRecord? {
        do {
            return try await database.record(for: id)
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound {
            return nil
        }
    }

    func deleteZones(_ ids: [CKRecordZone.ID]) async throws {
        let (_, results) = try await database.modifyRecordZones(saving: [], deleting: ids)
        for (_, result) in results {
            if case .failure(let error) = result, (error as? CKError)?.code != .zoneNotFound { throw error }
        }
    }
}
```

- [ ] **Step 5: Implement the transport API.** Add `private let zoneAdmin: any CloudZoneAdministering`. The public init passes `CKDatabaseZoneAdmin(containerID: containerID, scope: scope)`; the internal init takes `zoneAdmin: any CloudZoneAdministering` after `role`. Then:

```swift
public enum LegacyZoneCleanup: String, Equatable, Sendable {
    case noneFound = "none_found"
    case deleted
    case kept
}

public enum HubZoneError: Error, Equatable {
    case notHub
    case noEntitlement
    case engineRunning
}

// MARK: - Hub zones (multi-hub spec §3.3, §3.6)

extension CloudKitTransport {
    /// Hub role, after `stop()`: deletes this hub's two zones on the server
    /// (the owner turned the hub off; their shares and every participant go
    /// with them) and wipes the store, whose engine state and system fields
    /// describe zones that no longer exist. A failure leaves both in place.
    public func deleteHubZones() async throws {
        guard role == .hub else { throw HubZoneError.notHub }
        guard engine == nil else { throw HubZoneError.engineRunning }
        guard entitlementCheck() else { throw HubZoneError.noEntitlement }
        try await zoneAdmin.deleteZones(zones.allZoneIDs)
        try store.wipe()
    }

    /// Hub role: the single-hub build's fixed-name `DataZone`/`RelayZone`.
    /// `deleteIf` gets the legacy DataZone `heartbeat` payload (nil: none)
    /// and decides; both legacy zones that exist go together, or neither.
    public func removeLegacyZones(deleteIf: @Sendable (_ heartbeatPayload: Data?) -> Bool) async throws -> LegacyZoneCleanup {
        guard role == .hub else { throw HubZoneError.notHub }
        guard entitlementCheck() else { throw HubZoneError.noEntitlement }
        let legacy = HubZones.legacyZoneIDs
        let present = try await zoneAdmin.zoneIDs().filter(legacy.contains)
        guard !present.isEmpty else { return .noneFound }
        var payload: Data?
        if let data = legacy.first, present.contains(data) {
            let heartbeat = try await zoneAdmin.record(CKRecord.ID(recordName: HeartbeatPayload.recordName, zoneID: data))
            payload = heartbeat?.encryptedValues["payload"] as? Data
        }
        guard deleteIf(payload) else { return .kept }
        try await zoneAdmin.deleteZones(present)
        return .deleted
    }
}
```

`engine`, `entitlementCheck`, `store` and `zones` are actor-private, so this extension lives in `CloudKitTransport.swift`. Two more call sites need the same new argument: the `CloudKitTransportStopTests` inits pass `zoneAdmin: FakeZoneAdmin()`, and `testing` passes its `zoneAdmin`.

- [ ] **Step 6: Run to pass.** `make kit-test FILTER='CloudKitTransport' > /tmp/t4b.log 2>&1; echo "exit=$?"`. Expected `exit=0`. Then `make lint-diff`.

- [ ] **Step 7: Commit.**

```bash
git add WatchtowerKit
git commit -m "feat(kit): the hub deletes its own zones and the single-hub build's leftovers

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

## Task 5: hub_id addressing and the wrong_hub echo

**Depends on:** none (no transport code). Lane: Desktop Swift, so it runs one at a time with Tasks 6–8; schedule it before Task 6.

**Files:**
- Modify `WatchtowerKit/Sources/WatchtowerSync/Relay/ActionRequestPayload.swift` (fields, `CodingKeys`, init, `init(from:)`).
- Modify `WatchtowerKit/Sources/WatchtowerSync/Relay/RecordingUploadPayload.swift` (field, `CodingKeys`, init).
- Modify `WatchtowerKit/Sources/WatchtowerSync/Relay/ActionReason.swift`: add `case wrongHub = "wrong_hub"` after `unsupportedInPOC`, before `writeFailed`.
- Modify `WatchtowerDesktop/Sources/Services/MobileHub/RelayProcessor.swift` (`processAction`, `processUpload`, a message constant).
- Test: `WatchtowerKit/Tests/WatchtowerSyncTests/RelayPayloadTests.swift`, `RecordingUploadPayloadTests.swift`, `WatchtowerKit/Tests/WatchtowerKitTests/KitFixtureTests.swift` (`testReasonCodesAreExactlyTheSpecList` gains `"wrong_hub"`; the multi-hub spec §3.5 extends the list), `WatchtowerDesktop/Tests/MobileHub/RelayProcessorTests.swift`, `RelayProcessorRecordingUploadTests.swift`.

**Interfaces (produces):**

```swift
// ActionRequestPayload
public let hubID: String?            // wire key "hub_id"; nil = absent key, not checked (pre-F phone)
public init(id:kind:entityID:params:createdAt:deviceID:hubID: String? = nil)
// RecordingUploadPayload
public let hubID: String?
public init(id:startedAt:endedAt:durationSec:titleHint:sampleFormat:status:errorMessage:eventID:deviceID:hubID: String? = nil)
// ActionReason
case wrongHub = "wrong_hub"
// RelayProcessor
static let wrongHubMessage = "This was sent to another Mac."
```

The phone's `ActionOutbox`/`RecordingUploader` keep sending `hub_id` absent in F1. F2's per-hub outbox fills it.

- [ ] **Step 1: Failing Kit tests.**

```swift
    // RelayPayloadTests
    func testHubIDEncodesAsHubIdAndNilIsAbsent() throws {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let addressed = ActionRequestPayload(id: "a1", kind: .probe, entityID: nil, createdAt: created, deviceID: "device-a", hubID: "hub-acme")
        let json = try XCTUnwrap(String(bytes: try RelayCoder.makeEncoder().encode(addressed), encoding: .utf8))
        XCTAssertTrue(json.contains("\"hub_id\":\"hub-acme\""), json)
        let plain = ActionRequestPayload(id: "a2", kind: .probe, entityID: nil, createdAt: created)
        let plainJSON = try XCTUnwrap(String(bytes: try RelayCoder.makeEncoder().encode(plain), encoding: .utf8))
        XCTAssertFalse(plainJSON.contains("hub_id"))
        let decoded = try RelayCoder.makeDecoder().decode(ActionRequestPayload.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.hubID, "hub-acme")
    }

    // RecordingUploadPayloadTests
    func testHubIDRoundTripsAndNilIsAbsent() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let upload = RecordingUploadPayload(id: "R1", startedAt: start, endedAt: start + 60, durationSec: 60,
                                            sampleFormat: "aac-64k-mono", deviceID: "device-a", hubID: "hub-acme")
        let data = try RelayCoder.makeEncoder().encode(upload)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"hub_id\":\"hub-acme\""))
        XCTAssertEqual(try RelayCoder.makeDecoder().decode(RecordingUploadPayload.self, from: data).hubID, "hub-acme")
        let plain = RecordingUploadPayload(id: "R2", startedAt: start, endedAt: start + 60, durationSec: 60, sampleFormat: "aac-64k-mono")
        XCTAssertFalse(String(decoding: try RelayCoder.makeEncoder().encode(plain), as: UTF8.self).contains("hub_id"))
    }
```

  Use the encoder the existing frozen-format tests use, if it is named differently. The existing frozen fixtures stay byte-identical (an absent key).

- [ ] **Step 2: Failing Desktop tests.** Add a `hubID` parameter to `pendingActionRecord` in `MobileHubTestSupport.swift` (`hubID: String? = nil`, passed to `ActionRequestPayload`). Then:

```swift
    // RelayProcessorTests — MARK: - Hub addressing (multi-hub spec §3.5)
    func testAnActionForAnotherHubFailsWrongHubIsLedgeredAndReEchoedNeverDispatched() async throws {
        let latch = HandlerLatch()
        dispatcher.register(.boardCommentAdd) { try await latch.handle($0) }
        let record = try pendingActionRecord(kind: .boardCommentAdd, entityID: "7", hubID: "hub-other")
        try await transport.save([record])
        let processor = makeProcessor()

        _ = try await processor.processOnce()
        try await transport.save([record])          // the phone's pending save wins over the echo
        _ = try await processor.processOnce()

        let echoes = try echoes(of: record.recordName)
        XCTAssertEqual(echoes.map(\.status), [.failed, .failed])
        XCTAssertEqual(echoes.map(\.reason), [.wrongHub, .wrongHub])
        XCTAssertEqual(echoes.first?.errorMessage, RelayProcessor.wrongHubMessage)
        XCTAssertEqual(try sidecar.relayOutcome(record.recordName), "failed:wrong_hub")
        XCTAssertTrue(latch.calls.isEmpty, "another hub's action is never applied")
    }

    func testAnActionForThisHubOrWithoutAHubIDIsApplied() async throws {
        for (index, hubID) in ["hub-acme", nil].enumerated() {
            let record = try pendingActionRecord(kind: .probe, params: ["nonce": .string("n-\(index)")], hubID: hubID)
            try await transport.save([record])
            _ = try await makeProcessor().processOnce()
            XCTAssertEqual(try echoes(of: record.recordName).first?.status, .applied)
        }
    }

    // RelayProcessorRecordingUploadTests — MARK: - Hub addressing
    func testAnUploadForAnotherHubFailsWrongHubAndWritesNothing() async throws {
        let record = try await send(uploadPayload(hubID: "hub-other"), asset: try makeAsset())

        _ = try await makeProcessor().processOnce()

        XCTAssertEqual(try sidecar.relayOutcome(record.recordName), "failed:wrong_hub")
        XCTAssertTrue(enqueued.isEmpty)
        XCTAssertTrue(recordingFiles().isEmpty)
    }
```

  `uploadPayload` gains `hubID: String? = nil`. If `HandlerLatch` registration differs, use the pattern of `testNonIdempotentKindIsMarkedBegunBeforeItsHandlerRuns`. The processor's hub id in both suites is `"hub-acme"` (see `makeProcessor`).

- [ ] **Step 3: Run to fail.** `make kit-test FILTER='RelayPayloadTests|RecordingUploadPayloadTests|KitFixtureTests' > /tmp/t5a.log 2>&1; echo "exit=$?"` → build failure.

- [ ] **Step 4: Implement the payloads.** In `ActionRequestPayload`:
  - add `public let hubID: String?` with doc "The hub the phone addressed (multi-hub spec §3.5); nil encodes to an absent key and is not checked";
  - add `case hubID = "hubId"` to `CodingKeys`;
  - add the init parameter `hubID: String? = nil`, after `deviceID`;
  - decode with `hubID = try container.decodeIfPresent(String.self, forKey: .hubID)`.

  Do the same in `RecordingUploadPayload` (`case hubID = "hubId"`; synthesized decoding). Add `ActionReason.wrongHub` with doc "The record names another hub (multi-hub spec §3.5)."

- [ ] **Step 5: Implement `RelayProcessor`.** In `processAction`, insert this right after the `begun` branch, before the device gate:

```swift
        } else if let target = action.hubID, target != hubID {
            outcome = .failed(.wrongHub, message: Self.wrongHubMessage)
```

  In `processUpload`, after the `begun` branch:

```swift
        } else if let target = upload.hubID, target != hubID {
            outcome = .failed(.wrongHub, message: Self.wrongHubMessage)
```

  Add `static let wrongHubMessage = "This was sent to another Mac."` next to `notLinkedMessage`, and one line in the type's doc comment: "Hub addressing (multi-hub spec §3.5): a record whose `hub_id` names another hub fails `wrong_hub`, ledgered `done` like any refusal, so a re-save is re-echoed, never dispatched."

- [ ] **Step 6: Run to pass.** Run the Step 3 command, then `make test-swift FILTER='RelayProcessorTests|RelayProcessorRecordingUploadTests' > /tmp/t5b.log 2>&1; echo "exit=$?"`. Expected: both `exit=0`. Then `make lint-diff`.

- [ ] **Step 7: Commit.**

```bash
git add WatchtowerKit WatchtowerDesktop/Sources/Services/MobileHub/RelayProcessor.swift WatchtowerDesktop/Tests/MobileHub
git commit -m "feat(mobile): hub_id on actions and uploads; the hub echoes wrong_hub

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

## Task 6: Mac — the hub on its own zones; I-1 and take over removed

**Depends on:** Task 3, Task 5 (lane order). **Lane:** Desktop Swift.

**Files:**
- Modify `WatchtowerDesktop/Sources/Services/MobileHub/MobileHubService.swift`:
  - `MobileHubStorage.live()` (lines 72–83);
  - `HubStatus` (drop `.otherHub`, `.tookOver`);
  - remove `onTakeOver` (≈133) and add `onZonesDeleted`;
  - remove `takeOver()` and `start(takingOver:)`;
  - remove `Claim`/`claimHub`;
  - change `heartbeatTick` and `writeHeartbeat`;
  - update the doc comments of `enable`/`start`/`defaultCloudTimeout`.
- Modify `WatchtowerDesktop/Sources/Services/MobileHub/HubIdentity.swift`: remove `heartbeatCursorKey`, `heartbeatSeenKey`, `heartbeatReadKeys`, `liveWindow`, `readHeartbeat`, `remember`, `storedHeartbeat`, `isLiveForeign`; rewrite the type doc.
- Modify `WatchtowerDesktop/Sources/Services/MobileHub/HubSyncState.swift:686`: `relayKeys + HubIdentity.heartbeatReadKeys` → `relayKeys`, and drop "the heartbeat read state" from the `wipeSyncState` doc.
- Modify `WatchtowerDesktop/Sources/Services/MobileHub/ShareService.swift`: `CloudKitShareService(hubID:)`, shares on the hub's zones, remove `deleteShares()`.
- Modify `WatchtowerDesktop/Sources/Services/MobileHub/MobileLinkCenter.swift`: `attach(to:)`, `takeOverReset()` → `hubZonesDeleted()`.
- Modify `WatchtowerDesktop/Sources/ViewModels/MobileSettingsViewModel.swift`: remove `offersTakeOver`, `takeOver()`, and the two `statusLine` cases.
- Modify `WatchtowerDesktop/Sources/Views/Settings/MobileSettingsView.swift:96-98`: remove the Take over button.
- Tests:
  - rename `WatchtowerDesktop/Tests/MobileHub/HubSingleHubTests.swift` → `HubHeartbeatTests.swift` (`git mv`);
  - modify `MobileLinkCenterTests.swift`, `MobileSettingsViewModelTests.swift`, `MobileHubTestSupport.swift` (`StubHubTransport`), `MobileHubServiceTests.swift`.
- Docs:
  - `docs/features/mobile-companion.md`: the Architecture "Zones and scopes" bullet, "Hub skeleton, heartbeat and the single-hub rule (A6, A7)" retitled "Hub skeleton and heartbeat (A6, A7; multi-hub F1)", its heartbeat bullet, the Take over bullet (≈72), the hub status bullet (≈79), and the known limits "One hub, one version" and "Take over on a failed pull" (≈351–352);
  - `docs/superpowers/specs/2026-10-07-mobile-poc-design.md`: a note at §8 I-1 (line ≈653), §2.3 (≈181) and line ≈52.

**Interfaces:**
- Consumes: `CloudKitTransport(store:scope:hubID:role:)`, `HubZones`.
- Produces:

```swift
enum HubStatus: Equatable { case off, starting, running, unavailable(String) }
@ObservationIgnored var onZonesDeleted: (@MainActor () -> Void)?        // MobileHubService; called by Task 7
struct CloudKitShareService: ShareService { init(hubID: String, containerID: String = WatchtowerCloud.containerID,
                                                  entitlementPresent: (@Sendable () -> Bool)? = nil)
                                             func shareID(_ zone: CloudZoneID) -> CKRecord.ID }
func hubZonesDeleted()                                                   // MobileLinkCenter
```

**Deliberately deleted or rewritten tests (owner-approved I-1 replacement, spec §2):**
- In `HubSingleHubTests`, deleted:
  - `testForeignHeartbeat719SecondsOldRefusesEnable`, `testForeignHeartbeatExactly720SecondsOldAllowsEnable`, `testNoHeartbeatAllowsEnable`, `testOwnFreshHeartbeatAllowsEnable`;
  - `testAHungPullAfterAnEarlierReadDoesNotClaim`, `testAFailingPullWithAStaleCursorDoesNotClaimButATakeOverDoes`, `testAHungPullBeforeAnyHeartbeatReadDoesNotClaim`, `testAFailingPullBeforeAnyHeartbeatReadDoesNotClaim`;
  - `testAnAccountResetForgetsTheHeartbeatReadState`, `testTakeOverStopsTheOtherHubAfterItsNextRead`, `testATakeOverBeatsAnOldHubWhoseClockRunsAhead`, `testAHeartbeatFromAClockADayAheadIsNotFollowed`;
  - `testATakenOverHubRestartsAtOnceOnATransportThatNeverEchoesItsOwnSaves`, `testAForeignHeartbeatOlderThanThisHubsOwnArrivingLateKeepsItRunning`, `testAStaleForeignHeartbeatReadWhileRunningDoesNotStopTheHub`.
- Rewritten:
  - `testPinnedHeartbeatTiming` keeps only the 300 s interval;
  - `testThreeFailedTicksInARowStopTheHubAsUnavailable` now fails the save;
  - `MobileLinkCenterTests.testTakeOverDeletesTheSharesClearsDevicesAndTheNextCodeMakesNewShares` → `testHubZonesDeletedForgetsCodesAndPhonesAndTheNextCodeMakesNewShares`;
  - `MobileSettingsViewModelTests.testTheHubStatusLines` loses the two I-1 lines;
  - `testWithoutTheEntitlementTheCloudKitShareServiceTouchesNoContainer` loses its `deleteShares` block.

- [ ] **Step 1: Failing tests.** In `HubHeartbeatTests.swift` (after the `git mv`, class renamed `HubHeartbeatTests`, header doc "The heartbeat (multi-hub spec §3.2): written into the hub's own DataZone every 300 s; another Mac's heartbeat changes nothing."), delete the tests listed above and add:

```swift
    func testAnotherMacsLiveHeartbeatNeitherRefusesNorStopsThisHub() async throws {
        let cloud = InMemoryCloudTransport()
        try await seed(foreignHeartbeat(age: 5, macName: "Mac B"), into: cloud)
        let transport = StubHubTransport(cloud: cloud)
        let hub = try makeHub(transport: transport, sidecar: try HubSyncState.inMemory())

        let status = await hub.enable()
        try await seed(foreignHeartbeat(age: -5, macName: "Mac B"), into: cloud)
        await hub.heartbeatTick()

        XCTAssertEqual(status, .running)
        XCTAssertEqual(hub.status, .running, "each Mac publishes into its own zones (spec §2)")
        XCTAssertEqual(try savedHeartbeats(transport).count, 2)
        XCTAssertEqual(try savedHeartbeats(transport).last?.updatedAt, now, "stamped with this Mac's clock")
    }
```

  Replace the body of `testThreeFailedTicksInARowStopTheHubAsUnavailable`: the `setDataChangesFail` calls become `transport.failNextSaves(2)`, one good tick, `transport.failNextSaves(3)`, then three ticks. The message prefix is `"Couldn't write the heartbeat"`. In `testPinnedHeartbeatTiming`, drop the `liveWindow` line.

  In `MobileLinkCenterTests`:
  - rename `FakeShareService.deleteShares()` → `func dropAll() { lock.withLock { shareByZone = [:] } }` (a test helper: the zones and their shares are gone; not a protocol member);
  - rewrite the take-over test:

```swift
    // MARK: - Hub zones deleted (multi-hub spec §3.3)

    func testHubZonesDeletedForgetsCodesAndPhonesAndTheNextCodeMakesNewShares() async throws {
        let first = try await center.issueCode()
        try await handle(try deviceRecord("phone-a", nonce: first.nonce))
        shares.dropAll()

        center.hubZonesDeleted()

        XCTAssertNil(center.openCode)
        XCTAssertTrue(center.devices.isEmpty)
        XCTAssertTrue(try sidecar.linkedDevices().isEmpty)
        XCTAssertTrue(try grants().isEmpty)
        XCTAssertEqual(sharing.last, HubSharing.none)
        let next = try await center.issueCode()
        XCTAssertEqual(shares.created, 4, "new shares")
        XCTAssertNotEqual(next.dataShare, first.dataShare)
    }

    func testTheCloudKitShareServiceAddressesTheHubsOwnZones() {
        let service = CloudKitShareService(hubID: "hub-acme") { false }
        XCTAssertEqual(service.shareID(.data).zoneID.zoneName, "DataZone-hub-acme")
        XCTAssertEqual(service.shareID(.relay).zoneID.zoneName, "RelayZone-hub-acme")
        XCTAssertEqual(service.shareID(.relay).recordName, CKRecordNameZoneWideShare)
    }
```

  (`import CloudKit` at the top of the file if it is missing.) In `testWithoutTheEntitlement…`, use `CloudKitShareService(hubID: "hub-acme") { false }` and delete the `deleteShares` do/catch. In `MobileSettingsViewModelTests.testTheHubStatusLines`, delete the `.otherHub` and `.tookOver` assertions.

- [ ] **Step 2: Run to fail.** `make test-swift FILTER='HubHeartbeatTests|MobileLinkCenterTests|MobileSettingsViewModelTests' > /tmp/t6a.log 2>&1; echo "exit=$?"` → build failure (`hubZonesDeleted`, `shareID`, `init(hubID:)`).

- [ ] **Step 3: Implement `MobileHubStorage.live()`:**

```swift
    /// The real storage (multi-hub spec §3.1): `hubstate.db`, whose `hub_id`
    /// names this hub's zones, and `transport.db` behind a hub-role
    /// CloudKitTransport on those zones; the shares are of the same zones.
    static func live() throws -> Self {
        let dir = directory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sidecar = try HubSyncState(path: dir.appendingPathComponent("hubstate.db").path)
        let hubID = try sidecar.ensureHubID()
        let store = try TransportStore(path: dir.appendingPathComponent("transport.db").path)
        return Self(
            transport: CloudKitTransport(store: store, scope: .private, hubID: hubID, role: .hub),
            sidecar: sidecar, ownerUser: HubHostInfo.iCloudUserRecordName,
            sliceAssets: SliceAssetStore(directory: dir.appendingPathComponent("SliceAssets", isDirectory: true)),
            shares: CloudKitShareService(hubID: hubID),
            registerForPushes: registerForCloudKitPushes
        )
    }
```

- [ ] **Step 4: Implement `MobileHubService` without I-1.**
  - `HubStatus` keeps `off`, `starting`, `running` and `unavailable(String)`.
  - Delete `takeOver()`, the `Claim` enum and `claimHub`. `start()` becomes the former `start(takingOver:)` body without the parameter; replace its `switch await claimHub(...)` block with:

```swift
        reprobeTask?.cancel()
        reprobeTask = nil
        // Each Mac publishes into its own zones (multi-hub spec §2, §3.2):
        // no other hub's heartbeat is read, so there is nothing to refuse.
        await resolveOwnerUser()
        guard status == .starting, epoch == startEpoch else { return }
        do {
            try await writeHeartbeat(hubID: try identity.hubID())
        } catch {
            logger.error("first heartbeat failed: \(error.localizedDescription, privacy: .public)")
            status = .unavailable("Couldn't write the heartbeat: \(error.localizedDescription)")
            startReprobeLoop()
            return
        }
```

  - `heartbeatTick()`:

```swift
    /// One heartbeat tick: rewrites this hub's heartbeat (multi-hub spec
    /// §3.2). `maxTickFailures` failures in a row stop the hub as
    /// `.unavailable` (its local store is failing), and the reprobe loop
    /// restarts it.
    func heartbeatTick() async {
        guard status == .running else { return }
        let tickEpoch = epoch
        do {
            let hubID = try identity.hubID()
            await resolveOwnerUser()
            guard status == .running, epoch == tickEpoch else { return }
            try await writeHeartbeat(hubID: hubID)
            tickFailures = 0
        } catch {
            guard status == .running, epoch == tickEpoch else { return }
            tickFailures += 1
            if tickFailures == 1 || tickFailures >= Self.maxTickFailures {
                logger.error(
                    "heartbeat tick failed (\(self.tickFailures, privacy: .public) in a row): \(error.localizedDescription, privacy: .public)"
                )
            }
            guard tickFailures >= Self.maxTickFailures else { return }
            stop()
            status = .unavailable("Couldn't write the heartbeat: \(error.localizedDescription)")
            startReprobeLoop()
        }
    }
```

  - `writeHeartbeat(hubID:)` drops `after latest:` and the skew logic: `let at = now()`. It builds the same `HeartbeatPayload` and saves it, and no longer calls `identity.remember`.
  - Replace `onTakeOver` with:

```swift
    /// Runs after Settings turned the hub off and its zones were deleted
    /// (multi-hub spec §3.3): the link center forgets codes and phones.
    @ObservationIgnored var onZonesDeleted: (@MainActor () -> Void)?
```

  - The `defaultCloudTimeout` doc becomes "Bound on each CloudKit wait the hub adds: the iCloud user lookup, the legacy zone check and the zone delete."

- [ ] **Step 5: Implement `HubIdentity`.** Remove the members listed under Files. The doc becomes "Who this hub is (multi-hub spec §3.2): `hub_id` and `enabled_at` in the sidecar's `hub_meta`, kept for good. Since phase F each Mac publishes into its own zones; no other hub's heartbeat is read." In `HubSyncState.wipeSyncState`, change the loop to `for key in relayKeys`. Old `heartbeat_cursor`/`heartbeat_seen` rows stay as dead rows: nothing reads them.

- [ ] **Step 6: Implement shares and the link center.** `CloudKitShareService` gains `let hubID: String`, and its init becomes `init(hubID: String, containerID: String = WatchtowerCloud.containerID, entitlementPresent: (@Sendable () -> Bool)? = nil)`. `shareID` becomes an internal instance method:

```swift
    /// The zone-wide share of one of this hub's zones (multi-hub spec §3.4).
    func shareID(_ zone: CloudZoneID) -> CKRecord.ID {
        CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: HubZones(scope: .private, hubID: hubID).zoneID(for: zone))
    }
```

  - `Self.shareID` call sites become `shareID`.
  - Delete `deleteShares()` from the protocol (its doc says "(take over)") and from the implementation.
  - In `MobileLinkCenter`, `attach(to:)` sets `hub.onZonesDeleted = { [weak self] in self?.hubZonesDeleted() }`. Its doc changes "a take over tears the shares down" to "the hub's zones deleted forget every phone".
  - `takeOverReset()` becomes:

```swift
    // MARK: - Hub zones deleted (multi-hub spec §3.3)

    /// Settings turned the hub off and its zones were deleted: their shares
    /// and every participant went with them. Forgets every code and phone,
    /// so the next QR creates new shares and every phone scans again.
    func hubZonesDeleted() {
        expiryTask?.cancel()
        expiryTask = nil
        openCode = nil
        do {
            try sidecar.setMetaValue("0", forKey: Self.sweepPendingKey)
            try sidecar.clearLinkState()
        } catch {
            logger.error("hub zones deleted: link state not cleared: \(error.localizedDescription, privacy: .public)")
        }
        reloadDevices()
        nudge([.deviceGrant])
        onSharingChanged?(.none)
    }
```

- [ ] **Step 7: Implement Settings.** In `MobileSettingsViewModel`, delete `offersTakeOver`, `takeOver()`, and the `.otherHub`/`.tookOver` cases of `statusLine`. In `MobileSettingsView`, delete the `if model.offersTakeOver { Button("Take over") … }` block.

- [ ] **Step 8: Run to pass.** `make test-swift FILTER='HubHeartbeatTests|MobileHubServiceTests|MobileLinkCenterTests|MobileSettingsViewModelTests|MobileSettingsViewTests|MobileLinkSheetViewModelTests' > /tmp/t6b.log 2>&1; echo "exit=$?"`. Expected `exit=0`. Then `grep -rn "otherHub\|tookOver\|takeOver\|onTakeOver\|isLiveForeign\|readHeartbeat\|heartbeatReadKeys\|deleteShares" WatchtowerDesktop` must print nothing.

- [ ] **Step 9: Docs.**
  - `mobile-companion.md`, the "Zones and scopes" bullet: "The hub writes `DataZone-<hub_id>` (its only writer) and reads phone requests from `RelayZone-<hub_id>`, both in the Mac user's private database (`hub_id` from `hub_meta`, multi-hub spec §3.1) … through a hub-role `CloudKitTransport` …".
  - The heartbeat bullet is reduced to: `HubIdentity` keeps `hub_id` and `enabled_at`; `start()` writes the heartbeat after the availability gate; the 300 s loop rewrites it; three failed writes stop as `.unavailable` and reprobe; no foreign heartbeat is read and there is no take over (I-1 replaced, multi-hub spec §2). The `accounts`/`mac_name`/`flavor`/`owner_user`/`sharing` sentences are kept.
  - The Take over bullet is replaced by: "**Hub off:** see Task 7's lifecycle bullet". Task 7 writes that bullet; until it lands, write "the hub's zones are deleted when it is turned off (Task 7)".
  - In the hub status bullet, drop the two I-1 lines.
  - In known limits, delete "Take over on a failed pull" and reword "One hub, one version" to "Several hubs, one version: an older hub next to a newer one … (multi-hub phase F; decode an unknown status as a distinct inert case on both sides if it matters)".
  - Base spec: at §8 I-1 add "*Superseded 2026-10-11 by `docs/superpowers/specs/2026-10-11-mobile-multi-hub-design.md` §2: a hub publishes only into its own zones `DataZone-<hub_id>`/`RelayZone-<hub_id>`; a phone links to at most 4 hubs; take over is removed.*". Add the same one-line pointer at the §2.3 take-over sentence and at the line "DataZone has one writer, the hub. Single-hub rule: §8, I-1."

- [ ] **Step 10: Lint and commit.** `make lint-diff`, then:

```bash
git add -A WatchtowerDesktop docs/features/mobile-companion.md docs/superpowers/specs/2026-10-07-mobile-poc-design.md
git commit -m "feat(mobile): the Mac hub publishes into its own zones; I-1 and take over removed

The owner approved replacing I-1 (multi-hub spec §2): the single-hub and
take-over tests are deleted or rewritten on purpose, not weakened.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

## Task 7: Mac — zone lifecycle: first start, legacy zones, turning the hub off

**Depends on:** Task 4, Task 6. **Lane:** Desktop Swift.

**Files:**
- Modify `WatchtowerDesktop/Sources/Services/MobileHub/MobileHubService.swift`:
  - the `HubTransport` protocol (lines 9–30): add `deleteHubZones` and `removeLegacyZones`;
  - `start()`: add the per-hub adoption before `transport.start()` and the legacy check after the availability gate;
  - `disable()` (≈324): delete the zones.
- Modify `WatchtowerDesktop/Sources/Services/MobileHub/HubIdentity.swift`: the two marker keys and the legacy decision.
- Test: `WatchtowerDesktop/Tests/MobileHub/MobileHubTestSupport.swift` (`StubHubTransport` additions and `HubSyncState.inMemoryPerHub()`), and `MobileHubServiceTests.swift` (its `setUp` uses `inMemoryPerHub()`; new tests in a "Zone lifecycle" section).
- Docs: `docs/features/mobile-companion.md`, a "Zone lifecycle (multi-hub F1)" bullet under the hub skeleton section.

**Interfaces:**
- Consumes: `CloudKitTransport.deleteHubZones()`, `removeLegacyZones(deleteIf:)`, `LegacyZoneCleanup`, `HubSyncState.wipeSyncState(now:keepingRelayToken:)`, `MobileHubService.onZonesDeleted`.
- Produces:

```swift
// HubTransport (CloudKitTransport conforms natively)
func deleteHubZones() async throws
func removeLegacyZones(deleteIf: @Sendable (_ heartbeatPayload: Data?) -> Bool) async throws -> LegacyZoneCleanup
// HubIdentity
static let perHubZonesKey = "per_hub_zones"
static let legacyZonesCheckedKey = "legacy_zones_checked"
static func legacyZonesAreOurs(heartbeat payload: Data?, hubID: String) -> Bool
```

- [ ] **Step 1: Stub and support.** In `MobileHubTestSupport.swift`:

```swift
extension HubSyncState {
    /// A sidecar the per-hub zone adoption already ran on (most tests seed
    /// sync state before `start()` and must keep it).
    static func inMemoryPerHub() throws -> HubSyncState {
        let state = try inMemory()
        try state.setMetaValue("1", forKey: HubIdentity.perHubZonesKey)
        return state
    }
}
```

  `StubHubTransport` gains:

```swift
    enum LegacyZones { case none, present(heartbeat: Data?) }
    private var legacy: LegacyZones = .none
    private var legacyChecks = 0
    private var legacyFails = false
    private var zoneDeletesFail = false
    private var zoneDeleteCount = 0

    func setLegacyZones(_ value: LegacyZones) { lock.withLock { legacy = value } }
    func setLegacyCheckFails(_ value: Bool) { lock.withLock { legacyFails = value } }
    func setZoneDeletesFail(_ value: Bool) { lock.withLock { zoneDeletesFail = value } }
    var legacyCheckCount: Int { lock.withLock { legacyChecks } }
    var zoneDeletes: Int { lock.withLock { zoneDeleteCount } }
    var legacyZonesPresent: Bool { lock.withLock { if case .present = legacy { return true } else { return false } } }

    func deleteHubZones() async throws {
        let fails = lock.withLock { () -> Bool in
            lifecycleLog.append("deleteZones")
            return zoneDeletesFail
        }
        if fails { throw URLError(.notConnectedToInternet) }
        lock.withLock { zoneDeleteCount += 1 }
    }

    func removeLegacyZones(deleteIf: @Sendable (Data?) -> Bool) async throws -> LegacyZoneCleanup {
        let (state, fails) = lock.withLock { () -> (LegacyZones, Bool) in
            legacyChecks += 1
            return (legacy, legacyFails)
        }
        if fails { throw URLError(.notConnectedToInternet) }
        guard case .present(let heartbeat) = state else { return .noneFound }
        guard deleteIf(heartbeat) else { return .kept }
        lock.withLock { legacy = .none }
        return .deleted
    }
```

  Switch `MobileHubServiceTests.setUp` to `sidecar = try HubSyncState.inMemoryPerHub()`. `HubHeartbeatTests` uses `HubSyncState.inMemory()` and seeds nothing before `enable()` it later asserts, so it stays unchanged; if any of its tests fails on a wiped value, switch that one to `inMemoryPerHub()`.

- [ ] **Step 2: Failing tests** (`MobileHubServiceTests`, `// MARK: - Zone lifecycle (multi-hub spec §3.3, §3.6)`):

```swift
    /// Review focus 3.
    func testFirstStartOnPerHubZonesForgetsPublishStateAndTheRelayCursorButKeepsTheLedger() async throws {
        sidecar = try HubSyncState.inMemory()
        try sidecar.setMetaValue("42", forKey: RelayProcessor.relayTokenKey)
        try sidecar.markRelayDone("action-x", outcome: "applied", at: Date())
        let service = makeService(transport: StubHubTransport())

        await service.start()

        XCTAssertNil(try sidecar.metaValue(forKey: RelayProcessor.relayTokenKey), "the wiped store's seqs restart")
        XCTAssertEqual(try sidecar.relayPhase("action-x"), .done, "exactly-once survives")
        XCTAssertEqual(try sidecar.metaValue(forKey: HubIdentity.perHubZonesKey), "1")

        try sidecar.setMetaValue("43", forKey: RelayProcessor.relayTokenKey)
        service.stop()
        await service.waitUntilStopped()
        await service.start()
        XCTAssertNotNil(try sidecar.metaValue(forKey: RelayProcessor.relayTokenKey), "only the first start adopts")
        service.stop()
    }

    /// Review focus 4.
    func testLegacyZonesAreDeletedOnlyForOwnOrNoHeartbeatAndCheckedOnce() async throws {
        let hubID = try sidecar.ensureHubID()
        let cases: [(Data?, Bool, String)] = [
            (nil, true, "deleted"),
            (try heartbeatPayload(hubID: hubID), true, "deleted"),
            (try heartbeatPayload(hubID: "hub-other"), false, "kept"),
            (Data("not json".utf8), false, "kept")
        ]
        for (heartbeat, deletes, marker) in cases {
            sidecar = try HubSyncState.inMemoryPerHub()
            try sidecar.setMetaValue(hubID, forKey: HubSyncState.hubIDKey)
            let transport = StubHubTransport()
            transport.setLegacyZones(.present(heartbeat: heartbeat))
            let service = makeService(transport: transport)

            await service.start()
            service.stop()
            await service.waitUntilStopped()
            await service.start()

            XCTAssertEqual(transport.legacyZonesPresent, !deletes)
            XCTAssertEqual(try sidecar.metaValue(forKey: HubIdentity.legacyZonesCheckedKey), marker)
            XCTAssertEqual(transport.legacyCheckCount, 1, "checked once, at the first start")
            service.stop()
        }
    }

    func testAFailedLegacyCheckIsRetriedAtTheNextStartAndDoesNotBlockTheHub() async throws {
        let transport = StubHubTransport()
        transport.setLegacyCheckFails(true)
        let service = makeService(transport: transport)

        await service.start()
        XCTAssertEqual(service.status, .running)
        XCTAssertNil(try sidecar.metaValue(forKey: HubIdentity.legacyZonesCheckedKey))
        service.stop()
        await service.waitUntilStopped()
        transport.setLegacyCheckFails(false)
        await service.start()

        XCTAssertEqual(try sidecar.metaValue(forKey: HubIdentity.legacyZonesCheckedKey), "none_found")
        service.stop()
    }

    func testDisableDeletesTheHubsZonesWipesSyncStateAndForgetsPhones() async throws {
        let transport = StubHubTransport()
        let service = makeService(transport: transport)
        var forgotten = 0
        service.onZonesDeleted = { forgotten += 1 }
        await service.start()
        try sidecar.setMetaValue("42", forKey: RelayProcessor.relayTokenKey)

        service.disable()
        await service.waitUntilStopped()

        XCTAssertEqual(transport.zoneDeletes, 1)
        XCTAssertEqual(Array(transport.lifecycle.suffix(2)), ["stop", "deleteZones"], "the engine stops first")
        XCTAssertNil(try sidecar.metaValue(forKey: RelayProcessor.relayTokenKey))
        XCTAssertEqual(forgotten, 1)
    }

    /// Review focus 5.
    func testDisableWhileTheZoneDeleteFailsKeepsSyncStateAndLinkedPhones() async throws {
        let transport = StubHubTransport()
        transport.setZoneDeletesFail(true)
        let service = makeService(transport: transport)
        var forgotten = 0
        service.onZonesDeleted = { forgotten += 1 }
        await service.start()
        try sidecar.setMetaValue("42", forKey: RelayProcessor.relayTokenKey)

        service.disable()
        await service.waitUntilStopped()
        await service.start()

        XCTAssertEqual(try sidecar.metaValue(forKey: RelayProcessor.relayTokenKey), "42", "zones still there: state still true")
        XCTAssertEqual(forgotten, 0, "the phones still share the zones")
        XCTAssertEqual(service.status, .running, "the hub comes back on its existing zones")
        service.stop()
    }
```

  Add a helper next to `appliedEchoes`:

```swift
    private func heartbeatPayload(hubID: String) throws -> Data {
        try CloudRecordFactory.record(for: HeartbeatPayload(
            updatedAt: Date(), appVersion: "0.0.0-test", hubID: hubID, macName: "Mac acme", flavor: .default,
            lastPublishAt: nil, lastRelayAt: nil, relayBacklog: 0, accounts: [], enabledAt: Date(),
            ownerUser: "_owner-acme", sharing: .none
        ), modifiedAt: Date()).payload
    }
```

  `HubSyncState.hubIDKey` (`"hub_id"`) is internal and reachable through `@testable import`.

- [ ] **Step 3: Run to fail.** `make test-swift FILTER=MobileHubServiceTests > /tmp/t7a.log 2>&1; echo "exit=$?"` → build failure (protocol members, keys).

- [ ] **Step 4: Implement `HubIdentity`:**

```swift
    /// Set once the sidecar forgot the single-hub zones' publish state
    /// (multi-hub spec §3.6, first start on the per-hub build).
    static let perHubZonesKey = "per_hub_zones"
    /// The legacy zone check's outcome (`LegacyZoneCleanup.rawValue`); set
    /// once the check completed, so it runs at one start only.
    static let legacyZonesCheckedKey = "legacy_zones_checked"

    /// The single-hub build's zones go only when they hold this hub's
    /// heartbeat or none (multi-hub spec §3.6). Another Mac's — or one this
    /// build cannot read, so possibly a newer Mac's — is left alone.
    static func legacyZonesAreOurs(heartbeat payload: Data?, hubID: String) -> Bool {
        guard let payload else { return true }
        do {
            return try RelayCoder.makeDecoder().decode(HeartbeatPayload.self, from: payload).hubID == hubID
        } catch {
            return false
        }
    }
```

- [ ] **Step 5: Implement `MobileHubService`.**
  - `HubTransport` adds the two members from Interfaces, with doc lines "Hub zones deleted when Settings turns the hub off (multi-hub spec §3.3); call after `stop()`" and "The single-hub build's fixed-name zones (multi-hub spec §3.6)".
  - In `start()`, after `installTransportHandlers()` and its epoch guard, before `transport.start()`:

```swift
        do {
            try adoptPerHubZones()
        } catch {
            logger.error("per-hub zone adoption failed: \(error.localizedDescription, privacy: .public)")
            status = .unavailable("Couldn't prepare this Mac's iCloud zones: \(error.localizedDescription)")
            startReprobeLoop()
            return
        }
```

  - After `reprobeTask = nil` (before `resolveOwnerUser`): `await removeLegacyZonesIfDue()` followed by `guard status == .starting, epoch == startEpoch else { return }`.
  - New private members:

```swift
    // MARK: - Zone lifecycle (multi-hub spec §3.3, §3.6)

    /// First start on the per-hub build: the transport store, bound to no
    /// hub, wipes itself at `start()`, so what the sidecar believes published
    /// and its relay cursor describe the old fixed-name zones. Forgets them
    /// once (Review focus 3); the exactly-once ledger stays.
    private func adoptPerHubZones() throws {
        guard try sidecar.metaValue(forKey: HubIdentity.perHubZonesKey) == nil else { return }
        try sidecar.wipeSyncState(now: now())
        publisher.removeStagedAssets()
        try sidecar.setMetaValue("1", forKey: HubIdentity.perHubZonesKey)
    }

    /// Deletes the single-hub build's zones when they are this hub's (or
    /// nobody's), bounded by `cloudTimeout`. Best-effort: a failure or a
    /// timeout leaves the marker unset, so the next start checks again; it
    /// never blocks the hub.
    private func removeLegacyZonesIfDue() async {
        do {
            guard try sidecar.metaValue(forKey: HubIdentity.legacyZonesCheckedKey) == nil else { return }
            let hubID = try identity.hubID()
            let transport = self.transport
            let outcome = await Self.bounded(cloudTimeout) { () -> Result<LegacyZoneCleanup, any Error> in
                do {
                    return .success(try await transport.removeLegacyZones {
                        HubIdentity.legacyZonesAreOurs(heartbeat: $0, hubID: hubID)
                    })
                } catch {
                    return .failure(error)
                }
            }
            switch outcome {
            case .success(let cleanup)?:
                try sidecar.setMetaValue(cleanup.rawValue, forKey: HubIdentity.legacyZonesCheckedKey)
                logger.notice("legacy zones: \(cleanup.rawValue, privacy: .public)")
            case .failure(let error)?:
                logger.warning("legacy zone check failed: \(error.localizedDescription, privacy: .public)")
            case nil:
                logger.warning("legacy zone check timed out")
            }
        } catch {
            logger.error("legacy zone check: sidecar unreadable: \(error.localizedDescription, privacy: .public)")
        }
    }
```

  - `disable()`:

```swift
    /// The Settings toggle turned off (multi-hub spec §3.3): stops, removes
    /// the staged slice assets, then deletes this hub's two zones (bounded).
    /// Once they are gone the sync state is wiped (nothing is published, the
    /// relay seqs restart; the ledger stays) and the link center forgets
    /// every phone. A delete that fails or times out changes nothing: the
    /// zones, the state and the phones stay consistent (Review focus 5).
    func disable() {
        stop()
        publisher.closeStagedAssets()
        let previous = teardown
        let transport = self.transport
        let sidecar = self.sidecar
        let now = self.now
        let logger = self.logger
        let timeout = cloudTimeout
        teardown = Task { [weak self] in
            await previous?.value
            let deleted = await Self.bounded(timeout) { () -> Bool in
                do {
                    try await transport.deleteHubZones()
                    return true
                } catch {
                    logger.error("hub off: zones not deleted: \(error.localizedDescription, privacy: .public)")
                    return false
                }
            }
            guard deleted == true else { return }
            do {
                try sidecar.wipeSyncState(now: now())
            } catch {
                logger.error("hub off: wipeSyncState failed: \(error.localizedDescription, privacy: .public)")
            }
            self?.onZonesDeleted?()
        }
    }
```

  A timed-out delete may still land on the server. The next `start()` then sees the zone deletion through the engine (`handleDeletedZones`, hub role: re-create plus the data-zone reset), so the hub recovers. Record this in the docs bullet (Step 7).

- [ ] **Step 6: Run to pass.** `make test-swift FILTER='MobileHubServiceTests|HubHeartbeatTests|MobileSettingsViewModelTests' > /tmp/t7b.log 2>&1; echo "exit=$?"`. Expected `exit=0`. Then `make lint-diff`.

- [ ] **Step 7: Docs.** In `mobile-companion.md`, add under the hub skeleton section:
  - **Zone lifecycle (multi-hub F1)**:
    - **First start on the per-hub build.** The transport store (bound to no hub) wipes itself, and `adoptPerHubZones` wipes the sidecar's sync state once (`per_hub_zones`), keeping the ledger. Then `removeLegacyZonesIfDue` deletes the fixed-name `DataZone`/`RelayZone` only for this hub's heartbeat or none (`legacy_zones_checked` = `none_found` | `deleted` | `kept`). It is bounded and retried at the next start on failure.
    - **Settings off.** `disable()` deletes the hub's two zones (with their shares). On success it wipes the sync state and calls `onZonesDeleted`: the link center forgets codes and phones. A failed delete changes nothing. A timed-out delete that lands anyway is seen as a zone deletion at the next start.
    - **No cloud cleanup.** A reinstall that loses the sidecar leaves its zones behind (spec §3.3).

  Replace the Task 6 placeholder in the Take over line with a pointer to this bullet.

- [ ] **Step 8: Commit.**

```bash
git add WatchtowerDesktop docs/features/mobile-companion.md
git commit -m "feat(mobile): the hub deletes its zones when turned off and cleans up the single-hub zones

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

## Task 8: Phone — sync the linked hub's zones (F1 bridge)

**Depends on:** Task 3. **Lane:** phone Swift; it runs after Task 7 or before Task 5, never beside a Desktop task.

**Files:**
- Modify `WatchtowerMobile/Sources/App/AppEnvironment.swift` (convenience init ≈129–150, `unlinkedHubID` from Task 3).
- Modify `WatchtowerMobile/Sources/App/AppRoot.swift` (`Restarter.make` ≈26, `scope` state ≈34, `init`, `live()`, `demo`, `restart`/`performRestart`, `prepare`, `wipeLocalData`).
- Modify `WatchtowerMobile/Sources/App/LinkStore.swift` (`bootHubID` next to `bootScope` ≈72).
- Modify `WatchtowerMobile/Sources/Features/Onboarding/LinkingViewModel.swift` (`LinkHost` ≈38–58; call sites ≈346, 381, 528, 531–533, 546).
- Test: `WatchtowerMobile/Tests/Support/LinkingFakes.swift` (≈123–185), `WatchtowerMobile/Tests/LinkingViewModelTests.swift`, `WatchtowerMobile/Tests/AppRootWiringTests.swift`.
- Docs: `docs/features/mobile-companion.md`, the phone link section ("one link: the transport runs the linked hub's zones; F2's `HubRegistry` replaces this").

**Interfaces:**

```swift
// AppEnvironment
static let unlinkedHubID = "unlinked"
convenience init(recordingsDirectory: URL? = nil, scope: CloudDatabaseScope = .private,
                 hubID: String = AppEnvironment.unlinkedHubID, linkedDevice: LinkedDevice? = nil) throws
// LinkStore
var bootHubID: String    // link?.hubID ?? pending?.link.hubID ?? AppEnvironment.unlinkedHubID
// AppRoot
struct Restarter { let make: @MainActor (_ scope: CloudDatabaseScope, _ hubID: String, _ device: LinkedDevice?) throws -> AppEnvironment }
init(env: AppEnvironment, scope: CloudDatabaseScope, hubID: String, linking: LinkingViewModel, restarter: Restarter?)
// LinkHost
func prepare(scope: CloudDatabaseScope, hubID: String) async throws -> any CloudSyncTransport
func wipeLocalData(restartingOn scope: CloudDatabaseScope, hubID: String) async -> Int
```

- [ ] **Step 1: Failing tests.**
  - `LinkingFakes`:
    - add `private(set) var preparedHubIDs: [String] = []`;
    - `prepare(scope:hubID:)` appends `hubID` too (the log line stays `"prepare <scope>"`, so the logged sequences are unchanged);
    - `wipeLocalData(restartingOn:hubID:)` keeps its log line.
  - `LinkingViewModelTests`, in `testSameAppleIDWithShareURLsLinksPrivateWithoutAccepting`, after the `prepared` assertion: `XCTAssertEqual(host.preparedHubIDs, ["hub-acme"], "the scan syncs the code's hub")`.
  - `AppRootWiringTests`:
    - `built` becomes `[(env: AppEnvironment, scope: CloudDatabaseScope, hubID: String)]`;
    - the `make` closure takes `(scope, hubID, device)` and builds `CloudKitTransport(store:, scope: scope, hubID: hubID, role: .phone)` on the persistent-store path;
    - `AppRoot(env: try make(.private, AppEnvironment.unlinkedHubID, linked), scope: .private, hubID: AppEnvironment.unlinkedHubID, …)`;
    - every `wipeLocalData(restartingOn: .private)` call adds `hubID: AppEnvironment.unlinkedHubID`;
    - `prepare(scope: X)` calls add `hubID: AppEnvironment.unlinkedHubID`.
  - New test:

```swift
    func testPreparingAnotherHubOnTheSameScopeRestartsOnAnEmptyReplica() async throws {
        let root = try makeRoot(linked: nil)
        let first = root.env
        let now = Date()
        try await transports[0].save([try CloudRecordFactory.record(for: heartbeat(updatedAt: now), modifiedAt: now)])
        try await poll { (try? self.sliceCountSync(first)) == 1 }

        _ = try await root.prepare(scope: .private, hubID: "hub-acme")

        XCTAssertFalse(root.env === first, "another hub is another pair of zones")
        XCTAssertEqual(built.last?.hubID, "hub-acme")
        XCTAssertEqual(try await sliceCount(root.env), 0)
        _ = try await root.prepare(scope: .private, hubID: "hub-acme")
        XCTAssertEqual(built.count, 2, "the running hub needs no restart")
    }
```

- [ ] **Step 2: Run to fail.** `make mobile-test MOBILE_FILTER='AppRootWiringTests|LinkingViewModelTests' > /tmp/t8a.log 2>&1; echo "exit=$?"` → build failure.

- [ ] **Step 3: Implement.**
  - `AppEnvironment` convenience init: add `hubID: String = AppEnvironment.unlinkedHubID` after `scope`, and build `CloudKitTransport(store: transportStore, scope: scope, hubID: hubID, role: .phone)`. The doc of `unlinkedHubID`: "The hub a live phone syncs while it has no link (F1 bridge, replaced by F2's `HubRegistry`): no Mac has zones of this name, so it syncs nothing."
  - `LinkStore`: add `var bootHubID: String { link?.hubID ?? pending?.link.hubID ?? AppEnvironment.unlinkedHubID }`.
  - `AppRoot`:
    - add `@ObservationIgnored private var hubID: String`, set in `init`;
    - `live()` reads `let hubID = store.bootHubID` and calls `make(scope, hubID, …)`; `make` is `{ scope, hubID, device in try AppEnvironment(scope: scope, hubID: hubID, linkedDevice: device) }`;
    - `demo` passes `hubID: AppEnvironment.unlinkedHubID`;
    - `restart`/`performRestart` take `hubID`, call `restarter.make(scope, hubID, device)` and set `self.hubID = hubID`;
    - `prepare(scope:hubID:)` restarts when `scope != self.scope || hubID != self.hubID`;
    - `wipeLocalData(restartingOn:hubID:)` passes it through.
  - `LinkingViewModel`:
    - `LinkHost` signatures as in Interfaces;
    - ≈346: `host.prepare(scope: scope, hubID: record.hubID)`;
    - ≈381: `host?.prepare(scope: pending.link.databaseScope, hubID: pending.link.hubID)`;
    - ≈528 and ≈546: `host.wipeLocalData(restartingOn: .private, hubID: AppEnvironment.unlinkedHubID)`;
    - ≈531: `host.wipeLocalData(restartingOn: scope, hubID: current.hubID)`;
    - ≈533: `host.prepare(scope: scope, hubID: current.hubID)`.
  - Update the `LinkHost` doc: "The transport of `scope`'s database for `hubID`'s zones. Another scope or hub restarts the sync stack with an empty replica."

- [ ] **Step 4: Run to pass.** Run the Step 2 command, then `make mobile-test MOBILE_FILTER='ReplicaWiringTests|SettingsWiringTests' > /tmp/t8b.log 2>&1; echo "exit=$?"`. Expected: both `exit=0`. Then `make lint-diff`.

- [ ] **Step 5: Docs.** Add one bullet to the phone link section of `mobile-companion.md`: the live transport is phone-role, built for the linked (or pending) link's `hub_id` and `AppEnvironment.unlinkedHubID` otherwise. A vanished hub zone now unlinks in private scope too (phone role, multi-hub spec §6.1). This is F1's single-link bridge; F2's `HubRegistry`/`HubSession` replace it.

- [ ] **Step 6: Commit.**

```bash
git add WatchtowerMobile docs/features/mobile-companion.md
git commit -m "feat(mobile): the phone syncs its linked hub's zones (F1 bridge until HubRegistry)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Phase end (controller)

1. Run `bash scripts/dev-health.sh`; stop if it reports `HEALTH: overloaded`.
2. Run the full gate once, in one lane, each to a log with its exit code: `make kit-test`, `make test-swift` (which runs the Desktop suite and then the Kit), `make lint-all`, `make mobile-test`. Go is untouched, so `make test` is not needed. A failure goes back to the owning task as a fix round.
3. Before the PR, the owner smoke on two Macs stays at the end of phase F (spec §7, after F2). F1 asks nothing more of the owner than Task 2.
