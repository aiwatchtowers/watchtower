# Mobile multi-hub F2: one phone, several Macs (registry, sessions, switcher)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the phone links to up to 4 Mac hubs (on its own Apple ID or another), keeps every one of them synced, shows one at a time, and switches between them; linking another Mac adds it instead of replacing the current one.

**Architecture:**
- Today's `AppEnvironment` (one hub's object graph) becomes `HubSession`, almost unchanged. A new, thin `AppEnvironment` owns a `HubRegistry` (`hubs.sqlite`), one `HubSession` per linked hub and the active hub id; it forwards today's per-hub API (`store`, `workbenchReplica`, `recorder`, …) to the active session, so the views keep reading `env.<x>`. A switch rebuilds the tab tree (`.id(activeHubID)`), which resets navigation to the root.
- Each session lives in its own directory, `hubs/<hub_id>/` (replica, transport store) and `phone-recordings/hubs/<hub_id>/` (audio). The recording hold (`phone-recordings/.held`) stays shared: a session adopts only its own hub's held recordings, as today.
- Cadence: the active session runs today's loop (5 s / 30 s by tab); an inactive one fetches every 300 s, or every 30 s while it has unsent actions or uploads. A silent push refreshes every session. The app icon badge is the sum of the sessions' open asks.
- The link flow keeps its steps, but its host stops restarting "the" environment: `prepare` builds (or reuses) the session of the scanned hub, a completed link adds a registry row and activates it, an unlink removes one hub, a Mac-side removal freezes that hub read-only until Forget, and an iCloud account change removes every hub.
- A one-time migration moves an F1 phone's single link and its files into the registry layout, so a linked test phone stays linked.

**Tech Stack:** Swift 5.10 language mode, SwiftUI (iOS 17), GRDB 7, CloudKit through `WatchtowerSync` (`CloudKitTransport`, unchanged here), XCTest; xcodegen (`WatchtowerMobile/project.yml`, generated `.xcodeproj` committed).

**Spec:** `docs/superpowers/specs/2026-10-11-mobile-multi-hub-design.md` (owner-approved; § numbers below refer to it). Base spec: `docs/superpowers/specs/2026-10-07-mobile-poc-design.md`. Feature notes: `docs/features/mobile-companion.md`. F1 plan (done): `docs/superpowers/plans/2026-10-11-mobile-multi-hub-f1-kit-hub.md`. F0 verdict (GO, one `CKSyncEngine` per hub): `spikes/cloudkit-share/F0-RESULTS.md` on branch `spike/multi-hub-f0`.

**Scope:** phase F, part 2: spec §5.1–§5.4, §5.5 (only the silent push and the badge), §5.6, §5.7, §6.1–§6.3, §6.5, §6.6, spec §8 steps 4–6, 8 and 9. **Not in F2:** the ask-alert subscription per hub, local notifications and the notification tap (§5.5 bullets 1–3). They do not exist on the phone yet at all: board #17 (A13, "notifications: subscriptions and pushes") builds them, and this plan rewrites #17 to build them per hub from the start (Task 9). Nothing changes on the Mac or in the Kit.

**Execution (owner requirement):**
- **Base:** start only after the open mobile PRs that rewrite the same phone files are merged into `main`: #200 (phone link tails), #201 (Mac link tails), #203 (B18 session input) and #205 (phone shows Stopped, Settings → Mobile, same-Apple-ID removal #64). Task 4 builds on #205's `LinkRecord.deviceID`/`linkedAt`, `LinkStore.grantMissingSince` and `LinkingViewModel.evaluate(grant:heartbeat:)`. The controller rebases `feature/mobile-multi-hub-f2` onto that `main` before Task 1.
- Executed by subagents in the worktree `.claude/worktrees/multi-hub-f2` (branch `feature/mobile-multi-hub-f2`): superpowers:subagent-driven-development. One lane: every task is phone Swift, and the tasks build on each other in order.
- Each task runs only its task-scope checks (the commands in its steps plus `make lint-diff`). The controller runs `bash scripts/dev-health.sh` before each task and the full gate once at the end (see Phase end).
- A task that adds or removes a Swift file runs `make mobile-gen` and commits the regenerated `WatchtowerMobile/WatchtowerMobile.xcodeproj` with it.
- No polling turns. Run a long command to a log with an explicit exit code: `cmd > /tmp/<name>.log 2>&1; echo "exit=$?"`.
- Public repo hygiene: no real ids, Apple IDs, team ids, emails, names or local paths in code, tests or docs. Use `acme`, `hub-acme`, `hub-home`, `_owner-acme`, "colleague A".

---

## Global Constraints

Verbatim from the spec unless marked as this plan's decision:

- **At most 4 linked Macs** (§2, §5.1). "A fifth Mac is refused with a message" (§5.7). Message (this plan's decision): title "You can link up to 4 Macs", hint "Unlink one in Settings → Macs, then scan again".
- **Registry** (§5.1): `HubRegistry` in `<appGroup>/hubs.sqlite`: one row per linked hub — `hub_id`, `mac_name`, `flavor`, scope (`private` or `shared(owner)`), share URLs, `linked_at`, `sort_order`, `state` (`linked`, `unlinked_by_mac`) — plus the active `hub_id`. The phone's `device_id` (Keychain) is one for all hubs.
- **Per-hub files** (§5.1): `<appGroup>/hubs/<hub_id>/`: `cloudkit-transport.sqlite`, `replica.sqlite`; the alert watermark stays in `replica_meta`. The app group directory is `<group>/Library/Application Support` (`AppEnvironment.appGroupDirectory()`). Audio (this plan's decision): `Application Support/phone-recordings/hubs/<hub_id>/`; the shared hold stays at `Application Support/phone-recordings/.held`.
- **HubSession** (§5.2): today's `AppEnvironment` object graph for one hub. `AppEnvironment` owns the registry, one session per linked hub and `activeSession`; the UI reads the active one. "Switching resets navigation to the root; `AskDraftStore` is keyed by hub so drafts survive a switch" (each session owns its own `AskDraftStore`).
- **Cadence** (§5.3): an inactive session keeps a full replica; "data fetch on a silent push and every 5 min while the app is in the foreground (the active hub keeps 5 s / 30 s)"; "the relay loop runs only while the session has pending actions or uploads" — this plan reads it as: an inactive session with unsent actions or uploads fetches every 30 s, else every 300 s. Nothing loops in the background.
- **Recording** (§5.4): "A recording goes to the Mac that was active when it started; … that session's uploader finishes it even after a switch. The recordings list shows the active hub's recordings. One microphone, so one capture at a time across hubs."
- **Push and badge** (§5.5): "A silent push refreshes every session." "The app icon badge is the sum of open asks across hubs."
- **Switcher** (§5.6): "A chip with the active Mac's name at the top of Now and Workbench opens the list of Macs: name, `flavor`, an online dot (heartbeat under 720 s), the open-ask count; at the bottom **Add Mac** (QR scan)." "Settings → Macs: reorder, unlink any Mac, Forget a long-offline or Mac-unlinked one." "Two Macs with the same name also show a short `hub_id` suffix."
- **Linking** (§5.7): "Linking runs the base spec §2.3 flow for one hub and adds a registry row; the new Mac becomes active." The switch prompt ("Switch from <old> to <new>?") is dropped (§2).
- **Unlinking** (§5.7): "deletes its directory and row. If it was active, the next Mac in order becomes active; with none left the app returns to onboarding."
- **Errors** (§6): 1. hub zones vanish (or, since #64, the Mac deleted this phone's grant) → "that session gets `.unlinked`, its row turns `unlinked_by_mac`, its data stays read-only until Forget, and the phone must scan the QR again. Other hubs are untouched." 2. the phone's Apple ID changes → "every session and the registry are wiped"; onboarding. 3. quota, rate limit, store failure "stay within one hub's transport". 5. a reinstalled Mac → the old row shows "offline N days", Forget. 6. duplicate names → `flavor` + `hub_id` suffix.
- **Long offline** (this plan's decision): a row whose last heartbeat is 7 days old or more (or never came, linked 7 days ago or more) offers Forget; the list shows "Offline N days".
- **The "moved" notice goes** (this plan's decision): since F1 a heartbeat in `DataZone-<hub_id>` can only be that hub's, so `LinkNotice.moved` and `LinkingViewModel.writesBlocked` are dead and are removed in Task 4. The stale notice ("hasn't synced for a day") is kept, for the active hub only.
- **Platforms:** Swift 5.10 language mode; phone iOS 17+; the demo transport on unsigned builds seeds two hubs (§7).

## Review Focus

Five failure modes the spec implies but no task's own feature tests would exercise, most likely first. Each has a test in the task that owns it.

1. **A linked F1 phone loses its link or its unsent recordings on the update.** The new build boots from `hubs.sqlite`; without the migration it shows Welcome, and the launch sweep of an empty per-hub recordings folder never sees the old audio, which then sits orphaned. Test: `testF1LinkAndFilesMoveIntoTheRegistryLayoutOnce` → Task 3.
2. **One hub's launch sweep deletes another hub's audio.** The sweep deletes files with no ledger row in its own replica; with a shared folder every other hub's recordings qualify. Test: `testEachSessionSweepsOnlyItsOwnRecordingsFolder` → Task 2.
3. **Two sessions adopting held recordings at the same boot clobber the hold manifest.** Both read the manifest, each drops its own entries, the second write restores the first one's. Test: `testTwoSessionsAdoptTheirOwnHeldRecordingsAtOneBoot` → Task 5.
4. **A Mac-side removal of one hub stops, wipes or unlinks another.** The `.unlinked` event or the #64 grant check reaches the link flow without its hub id, and the flow acts on the active hub. Test: `testRemovalOfAnInactiveHubFreezesOnlyThatHub` → Task 4.
5. **A recording started on hub A is sent to hub B after a switch**, or stops uploading because A is inactive. Test: `testARecordingStartedOnOneHubFinishesThereAfterASwitch` → Task 5.

## Guard tests and deliberate test removals

No `docs/inventory/` entry covers the phone app. These existing tests are replaced, not weakened, because the behaviour they pin is removed by the spec:
- the switch prompt tests in `LinkingViewModelTests` (`confirmSwitch`, `switchPrompt`) — §2 drops step 6;
- the moved-hub tests in `LinkingViewModelTests` and `AppRootWiringTests` (`LinkNotice.moved`, `writesAllowed: false` on a foreign heartbeat) — dead since F1 (Global Constraints);
- the single-environment restart tests in `AppRootWiringTests` (`Restarter`, `retireEnvironment`) — replaced by the per-hub tests of Task 4.
Each removal is listed in its task's commit message.

---

## Task 0: base (controller)

- [ ] **Step 1:** check that #200, #201, #203 and #205 are merged: `gh pr view <n> --json state -q .state` prints `MERGED` for each. If not, stop and tell the owner (ask #69 is the open question about merging them).
- [ ] **Step 2:** `git fetch origin && git rebase origin/main` in the worktree; `make mobile-gen` and `make mobile-test MOBILE_FILTER='AppRootWiringTests|LinkingViewModelTests'` pass before any change (`> /tmp/f2-base.log 2>&1; echo "exit=$?"`).
- [ ] **Step 3:** `update_target` #116 stays `in_progress` with branch `feature/mobile-multi-hub-f2`; the plan's tasks are its sub-targets.

---

## Task 1: HubRegistry and per-hub paths

**Files:**
- Create: `WatchtowerMobile/Sources/App/Hubs/HubRegistry.swift`
- Create: `WatchtowerMobile/Sources/App/Hubs/HubPaths.swift`
- Create: `WatchtowerMobile/Sources/App/Hubs/HubDisplayName.swift`
- Test: `WatchtowerMobile/Tests/HubRegistryTests.swift`

**Interfaces:**
- Consumes: `LinkRecord` (`App/LinkStore.swift`, with #205's `deviceID` and `linkedAt`), `DeviceScope`, `CloudDatabaseScope` (WatchtowerSync).
- Produces:
  - `struct HubRow: Equatable, Sendable { var link: LinkRecord; var flavor: String?; var sortOrder: Int; var state: HubRow.State; var grantMissingSince: Date?; var lastHeartbeatAt: Date?; var linkedOn: Date; enum State: String { case linked, unlinkedByMac = "unlinked_by_mac" }; var hubID: String { link.hubID } }`
  - `final class HubRegistry` — `init(path: String) throws`, `static func inMemory() throws -> HubRegistry`, `static let limit = 4`, `func rows() throws -> [HubRow]` (by `sortOrder`), `func row(_ hubID: String) throws -> HubRow?`, `func upsert(_ link: LinkRecord, now: Date) throws` (a new row goes last and is `linked`; an existing row keeps its order, takes the new link and turns `linked`, `grantMissingSince` cleared), `func remove(_ hubID: String) throws`, `func move(_ hubID: String, to index: Int) throws`, `func setState(_ state: HubRow.State, for hubID: String) throws`, `func setGrantMissingSince(_ date: Date?, for hubID: String) throws`, `func noteHeartbeat(flavor: String, at: Date, for hubID: String) throws`, `var activeHubID: String? { get throws }`, `func setActive(_ hubID: String?) throws`, `func removeAll() throws`, `func isFull(adding hubID: String) throws -> Bool`.
  - `enum HubRegistryError: Error { case full }` — `upsert` of a new hub into a full registry throws `.full`.
  - `struct HubPaths { let groupDirectory: URL; let recordingsBase: URL; func hubDirectory(_ hubID: String) -> URL; func replicaPath(_ hubID: String) -> String; func transportStorePath(_ hubID: String) -> String; func recordingsDirectory(_ hubID: String) -> URL; var holdDirectory: URL; var registryPath: String; func removeHubFiles(_ hubID: String) throws; func hubIDsOnDisk() throws -> [String] }`.
  - `enum HubDisplayName { static func names(for rows: [HubRow]) -> [String: String] }` — the name per hub id: `mac_name`; if two rows share a `mac_name`, each of those gets ` · <first 4 of hub_id>`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import WatchtowerMobile
import WatchtowerSync

final class HubRegistryTests: XCTestCase {
    private func link(_ hub: String, mac: String = "Acme Mac", scope: DeviceScope = .private) -> LinkRecord {
        LinkRecord(
            hubID: hub, macName: mac, scope: scope, ownerName: "_owner-acme", userRecordName: "_owner-acme",
            nonce: "nonce-\(hub)", dataShareURL: nil, relayShareURL: nil, deviceID: "device-acme-1", linkedAt: nil
        )
    }

    func testRowsKeepLinkOrderAndTheLimitRefusesAFifthHub() throws {
        let registry = try HubRegistry.inMemory()
        let now = Date(timeIntervalSince1970: 1_000)
        for hub in ["hub-a", "hub-b", "hub-c", "hub-d"] { try registry.upsert(link(hub), now: now) }
        XCTAssertEqual(try registry.rows().map(\.hubID), ["hub-a", "hub-b", "hub-c", "hub-d"])
        XCTAssertTrue(try registry.isFull(adding: "hub-e"))
        XCTAssertFalse(try registry.isFull(adding: "hub-b"), "re-linking a linked hub is not a fifth")
        XCTAssertThrowsError(try registry.upsert(link("hub-e"), now: now)) { XCTAssertEqual($0 as? HubRegistryError, .full) }
    }

    func testRelinkKeepsTheOrderAndClearsTheRemovedState() throws {
        let registry = try HubRegistry.inMemory()
        let now = Date(timeIntervalSince1970: 1_000)
        try registry.upsert(link("hub-a"), now: now)
        try registry.upsert(link("hub-b"), now: now)
        try registry.setState(.unlinkedByMac, for: "hub-a")
        try registry.setGrantMissingSince(now, for: "hub-a")
        try registry.upsert(link("hub-a", mac: "Acme Mac 2"), now: now)
        let row = try XCTUnwrap(registry.row("hub-a"))
        XCTAssertEqual(row.state, .linked)
        XCTAssertNil(row.grantMissingSince)
        XCTAssertEqual(row.link.macName, "Acme Mac 2")
        XCTAssertEqual(try registry.rows().map(\.hubID), ["hub-a", "hub-b"])
    }

    func testMoveRemoveAndActiveSurviveReopen() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        let now = Date(timeIntervalSince1970: 1_000)
        do {
            let registry = try HubRegistry(path: path)
            for hub in ["hub-a", "hub-b", "hub-c"] { try registry.upsert(link(hub), now: now) }
            try registry.move("hub-c", to: 0)
            try registry.setActive("hub-b")
            try registry.noteHeartbeat(flavor: "corp", at: now, for: "hub-b")
            try registry.remove("hub-a")
        }
        let reopened = try HubRegistry(path: path)
        XCTAssertEqual(try reopened.rows().map(\.hubID), ["hub-c", "hub-b"])
        XCTAssertEqual(try reopened.activeHubID, "hub-b")
        XCTAssertEqual(try reopened.row("hub-b")?.flavor, "corp")
        XCTAssertEqual(try reopened.row("hub-b")?.lastHeartbeatAt, now)
    }

    func testRemovingTheActiveHubClearsActive() throws {
        let registry = try HubRegistry.inMemory()
        try registry.upsert(link("hub-a"), now: Date())
        try registry.setActive("hub-a")
        try registry.remove("hub-a")
        XCTAssertNil(try registry.activeHubID)
    }

    func testSharedScopeRoundTrips() throws {
        let registry = try HubRegistry.inMemory()
        let shared = LinkRecord(
            hubID: "hub-home", macName: "Home Mac", scope: .shared, ownerName: "_owner-home", userRecordName: "_owner-acme",
            nonce: "n", dataShareURL: "https://example.com/d", relayShareURL: "https://example.com/r",
            deviceID: "device-acme-1", linkedAt: Date(timeIntervalSince1970: 5)
        )
        try registry.upsert(shared, now: Date())
        XCTAssertEqual(try registry.row("hub-home")?.link, shared)
        XCTAssertEqual(try registry.row("hub-home")?.link.databaseScope, .shared(ownerName: "_owner-home"))
    }

    func testDuplicateMacNamesGetAHubSuffix() {
        let now = Date()
        let rows = [
            HubRow(link: link("a1b2c3d4-x", mac: "MacBook Pro"), flavor: nil, sortOrder: 0, state: .linked, grantMissingSince: nil, lastHeartbeatAt: nil, linkedOn: now),
            HubRow(link: link("e5f6a7b8-y", mac: "MacBook Pro"), flavor: nil, sortOrder: 1, state: .linked, grantMissingSince: nil, lastHeartbeatAt: nil, linkedOn: now),
            HubRow(link: link("hub-home", mac: "Home Mac"), flavor: nil, sortOrder: 2, state: .linked, grantMissingSince: nil, lastHeartbeatAt: nil, linkedOn: now)
        ]
        XCTAssertEqual(HubDisplayName.names(for: rows), [
            "a1b2c3d4-x": "MacBook Pro · a1b2",
            "e5f6a7b8-y": "MacBook Pro · e5f6",
            "hub-home": "Home Mac"
        ])
    }

    func testPathsAreHubScoped() {
        let paths = HubPaths(groupDirectory: URL(fileURLWithPath: "/g"), recordingsBase: URL(fileURLWithPath: "/r"))
        XCTAssertEqual(paths.replicaPath("hub-a"), "/g/hubs/hub-a/replica.sqlite")
        XCTAssertEqual(paths.transportStorePath("hub-a"), "/g/hubs/hub-a/cloudkit-transport.sqlite")
        XCTAssertEqual(paths.recordingsDirectory("hub-a").path, "/r/hubs/hub-a")
        XCTAssertEqual(paths.holdDirectory.path, "/r/.held")
        XCTAssertEqual(paths.registryPath, "/g/hubs.sqlite")
    }
}
```

If #205 merged `LinkRecord` with a different memberwise order, adjust the `link(_:)` helper only.

- [ ] **Step 2: Run them to see them fail**

Run: `make mobile-gen && make mobile-test MOBILE_FILTER=HubRegistryTests > /tmp/f2-t1.log 2>&1; echo "exit=$?"`
Expected: build failure, `HubRegistry` not found.

- [ ] **Step 3: Implement**

`HubPaths.swift`:

```swift
import Foundation

/// Where one hub's files live (multi-hub spec §5.1): the replica and the
/// transport store under the app group, the audio under the app's own
/// Application Support. The hold stays shared across hubs.
struct HubPaths {
    /// `AppEnvironment.appGroupDirectory()` (or a test directory).
    let groupDirectory: URL
    /// `PhoneRecorderController.defaultDirectory()`: `phone-recordings`.
    let recordingsBase: URL

    var registryPath: String { groupDirectory.appendingPathComponent("hubs.sqlite").path }
    var holdDirectory: URL { recordingsBase.appendingPathComponent(".held", isDirectory: true) }

    func hubDirectory(_ hubID: String) -> URL {
        groupDirectory.appendingPathComponent("hubs", isDirectory: true).appendingPathComponent(hubID, isDirectory: true)
    }

    func replicaPath(_ hubID: String) -> String { hubDirectory(hubID).appendingPathComponent("replica.sqlite").path }
    func transportStorePath(_ hubID: String) -> String { hubDirectory(hubID).appendingPathComponent("cloudkit-transport.sqlite").path }

    func recordingsDirectory(_ hubID: String) -> URL {
        recordingsBase.appendingPathComponent("hubs", isDirectory: true).appendingPathComponent(hubID, isDirectory: true)
    }

    /// Creates the hub's two directories.
    func prepare(_ hubID: String) throws {
        try FileManager.default.createDirectory(at: hubDirectory(hubID), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recordingsDirectory(hubID), withIntermediateDirectories: true)
    }

    /// Deletes the hub's directories. Call only after its recordings were
    /// handed to the hold and its session shut down.
    func removeHubFiles(_ hubID: String) throws {
        for directory in [hubDirectory(hubID), recordingsDirectory(hubID)]
        where FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// Hub directories present on disk (orphans are those without a row).
    func hubIDsOnDisk() throws -> [String] {
        let hubs = groupDirectory.appendingPathComponent("hubs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: hubs.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: hubs.path).filter { !$0.hasPrefix(".") }
    }
}
```

`HubRegistry.swift`: a GRDB `DatabaseQueue` (or `inMemory()` → `DatabaseQueue()`), one migration `v1`:

```sql
CREATE TABLE hubs (
  hub_id TEXT PRIMARY KEY,
  link_json BLOB NOT NULL,          -- LinkRecord, plain JSONEncoder (as LinkStore stores it)
  flavor TEXT,
  sort_order INTEGER NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('linked','unlinked_by_mac')),
  grant_missing_since REAL,
  last_heartbeat_at REAL,
  linked_on REAL NOT NULL
);
CREATE TABLE registry_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);  -- 'active_hub_id'
```

Rules: `upsert` of a new hub sets `sort_order = (max + 1)` and throws `HubRegistryError.full` when 4 rows exist; `move` renumbers 0…n−1 in one write; `remove` deletes the row, renumbers, and clears `active_hub_id` when it named that hub; `removeAll` empties both tables. Every write is one `write {}` transaction. The class is not an actor: callers are `@MainActor`.

`HubDisplayName.swift`:

```swift
/// The names the switcher and Settings show (multi-hub spec §5.6): the Mac's
/// name, with a short hub id suffix when two linked Macs share it.
enum HubDisplayName {
    static func names(for rows: [HubRow]) -> [String: String] {
        let counts = Dictionary(grouping: rows, by: \.link.macName).mapValues(\.count)
        return Dictionary(uniqueKeysWithValues: rows.map { row in
            let name = row.link.macName
            return (row.hubID, (counts[name] ?? 0) > 1 ? "\(name) · \(row.hubID.prefix(4))" : name)
        })
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `make mobile-gen && make mobile-test MOBILE_FILTER=HubRegistryTests > /tmp/f2-t1.log 2>&1; echo "exit=$?"`
Expected: `exit=0`, 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git add WatchtowerMobile/Sources/App/Hubs WatchtowerMobile/Tests/HubRegistryTests.swift WatchtowerMobile/WatchtowerMobile.xcodeproj
git commit -m "feat(mobile): HubRegistry and per-hub paths (multi-hub F2)"
```

---

## Task 2: HubSession and the multi-session AppEnvironment

**Files:**
- Rename: `WatchtowerMobile/Sources/App/AppEnvironment.swift` → `WatchtowerMobile/Sources/App/Hubs/HubSession.swift` (`git mv`), and `AppEnvironment+RecordingHandover.swift` → `Hubs/HubSession+RecordingHandover.swift`
- Create: `WatchtowerMobile/Sources/App/AppEnvironment.swift` (new, multi-session)
- Create: `WatchtowerMobile/Sources/App/Hubs/SessionCadence.swift`
- Modify: `WatchtowerMobile/Sources/App/DeviceSettings.swift` (per-hub keys)
- Modify: `WatchtowerMobile/Sources/Features/Recording/RecordingHold.swift` (explicit hold directory)
- Modify: `WatchtowerMobile/Sources/App/WatchtowerMobileApp.swift` (silent push refreshes every session)
- Modify: every test that builds an `AppEnvironment` through its designated init (`grep -rln "AppEnvironment(" WatchtowerMobile/Tests`) — they build a `HubSession` instead, or an `AppEnvironment` over one session through `AppEnvironment.single(_:)`.
- Test: `WatchtowerMobile/Tests/MultiHubEnvironmentTests.swift`

**Interfaces:**
- Consumes: Task 1 (`HubRegistry`, `HubRow`, `HubPaths`, `HubDisplayName`).
- Produces:
  - `HubSession` — today's `AppEnvironment` class renamed, with these changes: `navigation` and `recordingsSeen` move to `AppEnvironment` (app-wide); `transportKind` stays; the init takes `hold: RecordingHold?` instead of deriving it from the recordings folder; `DeviceSettings(transport:defaults:hubID:)`; the loop is driven by `func setCadence(_ cadence: SessionCadence)` instead of `setFetchInterval`/`setActive`; new `private(set) var heartbeat: HeartbeatPayload?` (read from the replica after every successful fetch, before `onFetched`); new `private(set) var lastFetchError: String?` (the last failed fetch's `localizedDescription`, cleared by a successful one: §6.3, the row shows the error); new `var hasPendingWork: Bool { get async }` (an outbox row in `.pending`, or an uploader item not yet acknowledged); new `func freeze() async` (stops the loop and the engine for good, sets writes off — `setLinkedDevice(linkedDevice, writesAllowed: false)` — and keeps the replica open for reading); `onLinkSignal` and `onFetched` keep their shapes (the root knows which session it wired).
  - `enum SessionCadence: Equatable { case active(Duration); case inactive; case paused }` and `static func interval(for cadence: SessionCadence, hasPendingWork: Bool) -> Duration?` in `SessionCadence.swift`: `.active(d)` → `d`; `.inactive` → `hasPendingWork ? .seconds(30) : .seconds(300)`; `.paused` → nil (no loop).
  - `AppEnvironment` (`@MainActor @Observable final class`): `let transportKind: TransportKind`, `let navigation: AppNavigation`, `let recordingsSeen: RecordingsSeenStore`, `private(set) var sessions: [String: HubSession]`, `private(set) var order: [String]` (registry order of the sessions on screen), `private(set) var activeHubID: String?`, `var active: HubSession?`, `func session(_ hubID: String) -> HubSession?`, `func add(_ session: HubSession)`, `func remove(_ hubID: String)` (drops it from `sessions`/`order`; the caller has shut it down), `func activate(_ hubID: String)` (sets `activeHubID`, persists it through the registry when one is set, then re-applies cadence), `func setTabInterval(_ interval: Duration)` (the active session's 5 s / 30 s), `func setForeground(_ foreground: Bool)`, `func refreshAll() async -> Bool` (refreshes every session concurrently; true when any succeeded), `var openAskTotal: Int` (sum of `workbenchReplica.openAskCount` over sessions), `static func single(_ session: HubSession, defaults: UserDefaults) -> AppEnvironment` (tests and the pre-Task 3 boot: one session, active).
  - Forwarding, so the views keep compiling: `store`, `outbox`, `reportRequests`, `boardWriter`, `askDrafts`, `askAnswerer`, `sessionStarts`, `sessionInputs`, `deviceSettings`, `workbenchReplica`, `calendarReplica`, `phoneRecordings`, `heldRecordings`, `linkedDevice`, `lastSyncAt`, `refresh()` (active only), `showRecordings()`, `sendNow()`. Each reads `active!` — the root never shows the tabs without an active session (Task 4 holds that invariant; until then `single` guarantees it). `recorder` is `capturingSession?.recorder ?? active!.recorder`, where `capturingSession` is the session whose recorder is capturing (Task 5 fills in the cross-hub rules; here it is just the active one).
  - The badge: `AppEnvironment.init(… setBadge: @escaping @MainActor (Int) -> Void)`, default `{ UNUserNotificationCenter.current().setBadgeCount($0) }` (log a thrown error); it is called whenever `openAskTotal` changes (observe with `withObservationTracking`, re-armed after each change, as `WorkbenchReplicaModel` does).

- [ ] **Step 1: Move and rename**

`git mv` the two files, rename the class and the extension to `HubSession`, then fix the compile errors only (no behaviour change yet). `nonisolated static let appGroupID`, `appGroupDirectory()`, `applicationSupportDirectory()` and the live/demo convenience init move to the new `AppEnvironment` (they are app-wide); `unlinkedHubID` stays on `HubSession` until Task 4 removes it.

- [ ] **Step 2: Write the failing tests**

`MultiHubEnvironmentTests` builds sessions with `InMemoryCloudTransport`s on temp replica paths, a fake audio engine (reuse `FakeAudioEngine`, `FakeClock` from `Tests/Support`) and a stepping `sleep` that records the durations it was asked for:

```swift
@MainActor
final class MultiHubEnvironmentTests: XCTestCase {
    private var sleeps: [String: [Duration]] = [:]

    private func makeSession(_ hubID: String, base: URL) throws -> HubSession {
        let paths = HubPaths(groupDirectory: base.appendingPathComponent("g"), recordingsBase: base.appendingPathComponent("r"))
        try paths.prepare(hubID)
        let engine = FakeAudioEngine()
        let clock = FakeClock()
        let session = try HubSession(
            transport: InMemoryCloudTransport(),
            replicaPath: paths.replicaPath(hubID),
            transportKind: .cloudKit,
            hubID: hubID,
            linkedDevice: nil,
            defaults: try makeDefaults(),
            recordingsDirectory: paths.recordingsDirectory(hubID),
            hold: RecordingHold(directory: paths.holdDirectory),
            makeRecorder: { uploader in
                PhoneRecorderController(uploader: uploader, engine: engine, notificationCenter: NotificationCenter(), now: { clock.now }, tickInterval: nil)
            },
            sleep: { [weak self] duration in
                await MainActor.run { self?.sleeps[hubID, default: []].append(duration) }
                try await Task.sleep(for: .seconds(3600))
            }
        )
        addTeardownBlock { @MainActor in session.stop() }
        return session
    }

    func testTheActiveSessionRunsTheTabCadenceAndTheOthersFiveMinutes() async throws { … }
    func testAnInactiveSessionWithUnsentActionsFetchesEveryThirtySeconds() async throws { … }
    func testBackgroundPausesEverySession() async throws { … }
    func testActivateSwitchesWhatTheForwardedPropertiesRead() async throws { … }
    func testRefreshAllRefreshesEverySession() async throws { … }
    func testTheBadgeIsTheSumOfOpenAsksAcrossSessions() async throws { … }
    func testEachSessionSweepsOnlyItsOwnRecordingsFolder() async throws { … }
}
```

What each asserts (write them in full in the file):
- **cadence:** two sessions `hub-a` (active) and `hub-b`; after both boot, `sleeps["hub-a"]?.last == .seconds(30)` (the default tab interval) and `sleeps["hub-b"]?.last == .seconds(300)`; `env.setTabInterval(.seconds(5))` → `hub-a` next sleep is 5 s, `hub-b` still 300 s; `env.activate("hub-b")` → `hub-b` sleeps 5 s, `hub-a` 300 s.
- **pending work:** queue an action through `hub-b`'s outbox (`session.boardWriter` status change, as `BoardWriteWiringTests` does), then `env.activate("hub-a")` → `hub-b`'s next sleep is 30 s.
- **background:** `env.setForeground(false)` → no session `isLooping`; `true` → both loop again and each begins one cycle at once (`fetchCycles` +1).
- **forwarding:** seed a different `WorkbenchSlice` into each transport (`CloudRecordFactory.record(for:)`), `await env.refreshAll()`; `env.workbenchReplica` shows `hub-a`'s workbench; after `env.activate("hub-b")` it shows `hub-b`'s; `env.askDrafts` is `hub-b`'s store (identity, `===`).
- **refreshAll:** each session's `lastSyncAt` is set after one `refreshAll()`.
- **badge:** seed one open ask into `hub-a` and two into `hub-b`; the injected `setBadge` was last called with `3`; answer… (simpler: delete one of `hub-b`'s ask records in its transport and `refreshAll()`) → last call `2`.
- **sweep (Review Focus 2):** write `orphan.m4a` into `hub-b`'s recordings folder and register a recording row for it in `hub-b`'s replica the way `RecordingsWiringTests` does; boot `hub-a`; after `hub-a`'s bootstrap (`await session.adoption?.value` and its `recoverOnLaunch`), the file in `hub-b`'s folder still exists. Then a file with no row in `hub-a`'s own folder is deleted by `hub-a`'s sweep (today's behaviour, now per folder).

- [ ] **Step 3: Run them to see them fail**

Run: `make mobile-gen && make mobile-test MOBILE_FILTER=MultiHubEnvironmentTests > /tmp/f2-t2.log 2>&1; echo "exit=$?"`
Expected: build failure (`setCadence`, `AppEnvironment.add`, `RecordingHold(directory:)` missing).

- [ ] **Step 4: Implement**

1. `RecordingHold`: `init(directory: URL)` (the `.held` folder itself). Every method that moved audio back into "the recordings folder" (the parent of `.held`) takes the destination as a parameter instead: `recordingsDirectory: URL`. `HubSession` passes its own `uploader.directory`. Keep the old behaviour otherwise; `RecordingHoldTests` updates its init calls only.
2. `DeviceSettings`: `init(transport:defaults:hubID:)`; `typingRequested` and `startSessions` keys become `"hub.\(hubID).device.typingRequested"` / `"hub.\(hubID).device.startSessions"`; `newAskAlerts` keeps its global key (A13 owns it).
3. `HubSession`: replace `fetchInterval`/`isActive`/`setFetchInterval`/`setActive` with:

```swift
    /// What the root asks of this session's loop (multi-hub spec §5.3).
    private(set) var cadence: SessionCadence = .active(.seconds(30))

    func setCadence(_ cadence: SessionCadence) {
        guard cadence != self.cadence else { return }
        let wasPaused = self.cadence == .paused
        self.cadence = cadence
        recorder.setForeground(cadence != .paused)
        restartLoop(fetchFirst: wasPaused)
    }
```

   and the loop asks for its interval each cycle, so pending work changes the inactive cadence without a restart:

```swift
    private func restartLoop(fetchFirst: Bool = true) {
        loopTask?.cancel()
        loopTask = nil
        guard isBootstrapped, !stopped, cadence != .paused else { return }
        let sleep = sleep
        loopTask = Task { [weak self] in
            var first = true
            while !Task.isCancelled {
                guard let self else { return }
                if !first || fetchFirst {
                    self.fetchCycles += 1
                    await self.refresh()
                }
                first = false
                guard let interval = SessionCadence.interval(for: self.cadence, hasPendingWork: await self.hasPendingWork) else { return }
                try? await sleep(interval)
            }
        }
    }
```

   `hasPendingWork`: `(try? store.pendingActions().contains { $0.state == .pending }) == true || (try? store.phoneRecordings().contains { $0.needsUpload }) == true` — use the recording ledger's existing "not acknowledged" predicate (the one `uploadPending()` selects by; name it in a small `PhoneRecording` extension if it is inline today). `heartbeat`: in `refresh()`, after a successful hydrate, decode `HeartbeatPayload` exactly as `AppRoot.checkHeartbeat` does today and store it.
4. New `AppEnvironment`: holds the app-wide parts and the sessions; `applyCadence()` sets `.active(tabInterval)` on the active session, `.inactive` on the others, `.paused` on all when not in the foreground; `add`/`remove`/`activate`/`setTabInterval`/`setForeground` call it. `refreshAll()` uses a `withTaskGroup` over the sessions' `refresh()` (each is `@MainActor`, so they interleave at their awaits). The live convenience init is reduced to `static func liveSingle(scope:hubID:linkedDevice:) throws -> AppEnvironment` that builds today's one session on the old file paths (`<group>/replica.sqlite`, `<group>/cloudkit-transport.sqlite`, `phone-recordings` with hold `phone-recordings/.held`) and wraps it with `single`; Task 3 replaces it with the registry boot. The demo path likewise wraps one demo session (Task 8 adds the second).
5. `RootTabView`/`NowView`/… call sites: `env.setFetchInterval` → `env.setTabInterval`; `env.setActive` → `env.setForeground`. `AppRoot` keeps building one environment through `Restarter.make`, which now returns `AppEnvironment.liveSingle(...)`; its `env.onLinkSignal`/`onFetched` wiring moves to `env.active!` (Task 4 replaces it).
6. `AppDelegate.didReceiveRemoteNotification`: `completionHandler(await root.env.refreshAll() ? .newData : .failed)`.

- [ ] **Step 5: Run the new tests and the suites the rename touches**

Run: `make mobile-gen && make mobile-test MOBILE_FILTER='MultiHubEnvironmentTests|ReplicaWiringTests|AppRootWiringTests|RecordingsWiringTests|RecordingHoldTests|SettingsWiringTests|BoardWriteWiringTests' > /tmp/f2-t2.log 2>&1; echo "exit=$?"`
Expected: `exit=0`. Then the whole phone suite once, since every wiring test builds an environment: `make mobile-test > /tmp/f2-t2-all.log 2>&1; echo "exit=$?"`.

- [ ] **Step 6: Commit**

```bash
git add -A WatchtowerMobile
git commit -m "refactor(mobile): HubSession per hub; AppEnvironment holds the sessions, cadence and badge (multi-hub F2)"
```

---

## Task 3: registry boot and the F1 migration

**Files:**
- Create: `WatchtowerMobile/Sources/App/Hubs/HubBoot.swift`
- Modify: `WatchtowerMobile/Sources/App/AppEnvironment.swift` (live boot from the registry)
- Modify: `WatchtowerMobile/Sources/App/LinkStore.swift` (the `link` key is read once by the migration, then removed; `pending` stays)
- Test: `WatchtowerMobile/Tests/HubBootTests.swift`

**Interfaces:**
- Consumes: Tasks 1–2.
- Produces:
  - `struct HubSessionFactory { let make: @MainActor (_ row: HubRow?, _ hubID: String, _ scope: CloudDatabaseScope, _ device: LinkedDevice?) throws -> HubSession }` — `row` nil for a hub being linked (Task 4). The live one builds a `CloudKitTransport(store: TransportStore(path: paths.transportStorePath(hubID)), scope:, hubID:, role: .phone)` and a `HubSession` on `paths`.
  - `enum HubBoot { static func migrateF1(store: LinkStore, registry: HubRegistry, paths: HubPaths, legacyGroupDirectory: URL, legacyRecordings: URL, defaults: UserDefaults, now: Date) throws; static func removeOrphans(registry: HubRegistry, paths: HubPaths, keeping pendingHubID: String?) throws }`
  - `AppEnvironment.live(registry:paths:factory:identity:defaults:) throws -> AppEnvironment` — one session per registry row (frozen rows are built and frozen at once, Task 4's `freeze`), active = the registry's active hub, else the first row.

Migration rules (`migrateF1`, idempotent, runs before any session opens):
1. Runs only when the registry has no rows and `LinkStore`'s legacy `link.record` key holds a link.
2. `paths.prepare(hubID)`; move `<legacyGroup>/replica.sqlite`, `-wal`, `-shm` and `cloudkit-transport.sqlite`, `-wal`, `-shm` into `hubs/<hub_id>/` (a missing file is skipped). Move every non-hidden file of `phone-recordings/` into `phone-recordings/hubs/<hub_id>/` (`.held` and `hubs` stay).
3. Copy `device.typingRequested` / `device.startSessions` into the hub's keys (Task 2) when set.
4. `registry.upsert(link, now:)`, `setActive(hubID)`, `setGrantMissingSince(store.grantMissingSince, …)`; then remove the `link.record` and `link.grantMissingSince` keys.
5. With no legacy link: delete the legacy replica and transport files (an unlinked phone's, they hold nothing to keep) and leave the audio folder as is.
A failure in step 2 throws before step 4: the next launch tries again from the same state.

`removeOrphans`: a `hubs/<id>` directory with no row and not the pending link's hub (`LinkStore.pending?.link.hubID`) is a link that never completed: its recordings are handed to the hold first (`HubSession.handOverRecordings` needs a session — build one with the factory, call it with `keep: true`, shut it down), then `paths.removeHubFiles(id)`.

- [ ] **Step 1: Write the failing tests** (`HubBootTests`, temp directories for the legacy group, the recordings base and defaults):
  - `testF1LinkAndFilesMoveIntoTheRegistryLayoutOnce` (Review Focus 1): legacy `replica.sqlite` (a real `ReplicaStore` with one recording row), `cloudkit-transport.sqlite`, an audio file `rec-1.m4a` and a `.held/manifest.json` → after `migrateF1`: the registry has the one row, active; the files are under `hubs/<hub>/`; `rec-1.m4a` is in `phone-recordings/hubs/<hub>/`; `.held/manifest.json` did not move; the replica opened at the new path still has the recording row; the `link.record` key is gone. A second `migrateF1` call changes nothing.
  - `testNoLegacyLinkDeletesTheLegacyReplicaAndKeepsAudio`.
  - `testAFailedFileMoveLeavesTheLegacyLinkForTheNextLaunch` (make the destination unwritable, or inject a `FileManager` seam if simpler).
  - `testOrphanHubDirectoryIsHandedToTheHoldAndRemoved`, and `testThePendingLinksDirectoryIsNotAnOrphan`.
  - `testLiveBootBuildsOneSessionPerRowAndActivatesTheSavedHub` (factory returning in-memory sessions; two rows, active = second).
- [ ] **Step 2:** `make mobile-gen && make mobile-test MOBILE_FILTER=HubBootTests > /tmp/f2-t3.log 2>&1; echo "exit=$?"` — fails to build.
- [ ] **Step 3: Implement** `HubBoot` and `AppEnvironment.live`; `AppRoot.live()` calls `HubBoot.migrateF1`, `HubBoot.removeOrphans`, then `AppEnvironment.live(...)` (until Task 4 rewires `AppRoot`, keep its single-link restart path working on top of the active session).
- [ ] **Step 4:** `make mobile-test MOBILE_FILTER='HubBootTests|MultiHubEnvironmentTests|AppRootWiringTests' > /tmp/f2-t3.log 2>&1; echo "exit=$?"` → `exit=0`.
- [ ] **Step 5: Commit** `feat(mobile): boot every linked hub from the registry; move an F1 link into it (multi-hub F2)`.

---

## Task 4: the link flow over the registry

**Files:**
- Modify: `WatchtowerMobile/Sources/Features/Onboarding/LinkSeams.swift` (`LinkHost`)
- Modify: `WatchtowerMobile/Sources/Features/Onboarding/LinkingViewModel.swift`
- Modify: `WatchtowerMobile/Sources/Features/Onboarding/LinkFailure.swift` (`.tooManyMacs`), `LinkNotice.swift` (`moved` removed, `removed(macName:notSent:)`)
- Modify: `WatchtowerMobile/Sources/App/AppRoot.swift` (host over `AppEnvironment` + registry; `Restarter` removed)
- Modify: `WatchtowerMobile/Sources/App/AppRootView.swift` (`showsOnboarding`, notice banner)
- Modify: `WatchtowerMobile/Sources/App/LinkStore.swift` (`link` and `grantMissingSince` removed; `pending` stays)
- Test: `WatchtowerMobile/Tests/LinkingViewModelTests.swift`, `WatchtowerMobile/Tests/AppRootWiringTests.swift`, `WatchtowerMobile/Tests/Support/LinkingFakes.swift`

**Interfaces:**
- Consumes: Tasks 1–3 (`HubRegistry`, `HubSessionFactory`, `HubPaths`, `HubSession.freeze()`, `handOverRecordings`).
- Produces — `LinkHost` becomes hub-addressed:

```swift
@MainActor
protocol LinkHost: AnyObject {
    /// The saved links, in registry order (rows of both states).
    func linkedHubs() -> [HubRow]
    /// `hubID`'s transport in `scope`'s database: its session if one runs in
    /// that scope; else a new session in its own directory (a row in another
    /// scope, or frozen, is removed first with its recordings held).
    func prepare(scope: CloudDatabaseScope, hubID: String) async throws -> any CloudSyncTransport
    /// One fetch of `hubID`'s session, then this phone's grant there.
    func fetchGrant(hubID: String, deviceID: String) async -> DeviceGrant?
    /// The link completed: adds or updates the row, sets the device on the
    /// session (writes on) and activates it.
    func linked(_ record: LinkRecord, device: LinkedDevice) async throws
    func devicePayload(hubID: String, for device: LinkedDevice, linkNonce: String?, unlinked: Bool, now: Date) -> DevicePayload
    /// Writes `record` through a fresh transport on `hubID`'s zones after the
    /// session's files are gone (only the farewell is sent), sends it, stops.
    func sendFarewell(_ record: CloudRecord, scope: CloudDatabaseScope, hubID: String) async
    /// Removes `hubID`: stops its session (a running capture stopped and
    /// saved), hands its recordings to the hold (`keepRecordings`), deletes its
    /// files and its row; the next hub in order becomes active. Returns what
    /// was lost. Also drops a session that never got a row (a failed link).
    func removeHub(_ hubID: String, keepRecordings: Bool) async -> LocalWipe
    /// The Mac removed this phone: the row turns `unlinked_by_mac` and the
    /// session freezes (no sync, no writes, data readable).
    func markRemovedByMac(_ hubID: String) async
    func setGrantMissingSince(_ date: Date?, hubID: String)
    func requestNotificationPermission() async
    func openNow()
}
```

`LinkingViewModel` changes:
- `link: LinkRecord?` → `links: [HubRow]` (refreshed from `host.linkedHubs()` after every change); `linkedDevice` → `func linkedDevice(for hubID: String) -> LinkedDevice?`; `var hasLinks: Bool`.
- `scanned`/`open`: the switch prompt and `confirmSwitch`/`pendingSwitch`/`Phase.confirmSwitch`/`switchPrompt` are removed. Before accepting shares: `if links.count >= HubRegistry.limit, !links.contains(where: { $0.hubID == payload.hubID }) { phase = .failed(.tooManyMacs); return }`.
- `connect`: unchanged steps; `host.prepare(scope:hubID:)` as before; every failure after `prepare` calls `await host.removeHub(record.hubID, keepRecordings: true)` when that hub has no row (a failed first link leaves no directory behind); `complete` calls `host.linked(record, device:)`.
- `waitForGrant`, `isGranted`: `fetchGrant(hubID: pending.link.hubID, …)`.
- `func unlink(_ hubID: String) async` (Settings → Macs): the row's link; `notice = LinkNotice.after(await unlinkHub(row, writeUnlinked: true))`. `unlinkHub`: `host.removeHub(hubID, keepRecordings: true)` first (it counts "Not sent" and holds recordings), then `sendFarewell(unlinkedDeviceRecord, scope:, hubID:)`, then, in shared scope, `container.leaveShares(ownerName:hubID:)` (failure logged). No second wipe and no `retireEnvironment`: the hub's files are already gone.
- `func forget(_ hubID: String) async` (a frozen or long-offline row): `removeHub(hubID, keepRecordings: true)`; no farewell, no share leave for a frozen row (its zones are gone); for a long-offline `linked` row the same as `unlink`.
- `func removedByMac(_ hubID: String) async`: `host.markRemovedByMac(hubID)`; `notice = .removed(macName: row.link.macName, notSent: 0)`. Nothing is wiped (§6.1).
- `accountChanged()`: compares with any row's `userRecordName`; on a change removes every hub (`removeHub(…, keepRecordings: false)` for each, summing the wipes), `store.pending = nil`, notice from the sum. With no rows left the root shows onboarding.
- `evaluate(heartbeat:)` → `evaluate(hubID:heartbeat:isActive:)`: only the stale check, and only when `isActive`; the moved branch and `writesBlocked` are removed.
- `evaluate(grant:heartbeat:)` (#205) → `evaluate(hubID:grant:heartbeat:)`: the same rules on that hub's row; `grantMissingSince` read from and written to the row (`host.setGrantMissingSince`); the confirmed removal calls `removedByMac(hubID)`.

`AppRoot`:
- Holds `env: AppEnvironment` for good (no restart), the registry, the paths, the factory, and `linking`.
- Wires every session it adds: `session.onLinkSignal = { [weak self] signal in self?.handle(signal, hubID: id) }` and `session.onFetched = { [weak self] in self?.checkLink(hubID: id) }` (`checkLink` = today's `checkHeartbeat` per session, plus `registry.noteHeartbeat(flavor:at:for:)` from `session.heartbeat`).
- `handle(.unlinked, hubID)` → `linking.removedByMac(hubID)`; `.accountChanged` → `linking.accountChanged()`.
- `showsOnboarding`: `!isDemo && linking.links.isEmpty`.
- `prepare` keeps candidate sessions in `env` without a row and without activating them; `linked` upserts the row (`HubRegistryError.full` is surfaced as `.tooManyMacs` — the check before the accept makes it a race only), `await session.setLinkedDevice(device)`, `env.activate(hubID)`.
- `removeHub`: `stopForWipe` → `shutDown` → `handOverRecordings(stoppedCapture:keep:)` → count pending actions → `env.remove(hubID)` → `paths.removeHubFiles(hubID)` → `registry.remove(hubID)` → if it was active, `env.activate(next in order)` when any → then the remaining sessions adopt held recordings again only on their next boot (unchanged).
- `markRemovedByMac`: `registry.setState(.unlinkedByMac, for:)`, `await session.freeze()`.
- `sendFarewell`: the live root builds `CloudKitTransport(store: TransportStore(path: <hubDirectory>/farewell.sqlite), scope:, hubID:, role: .phone)`, `start()`, `save`, `sendNow()`, `stop()`, then deletes the farewell store file; the test root injects a closure that records the record and scope (the existing `SaveLogTransport`).

- [ ] **Step 1: Rewrite the fakes and tests first.** `FakeLinkHost` implements the new protocol over an in-memory list of `HubRow`s and records calls. In `LinkingViewModelTests`: delete the switch-prompt and moved tests (see Guard tests); port every other test to the new names; add:
  - `testLinkingASecondMacAddsItAndMakesItActive` (no prompt; two rows; the second is active via `host.linked`).
  - `testAFifthMacIsRefusedBeforeAnyShareIsAccepted` (`container.acceptedURLs` empty; `phase == .failed(.tooManyMacs)`).
  - `testRescanningALinkedMacRelinksWithoutAFifthSlot` (4 rows, scan one of them → links).
  - `testAFailedFirstLinkRemovesItsCandidate` (grant wait times out → `host.removeHub(hub, keepRecordings: true)` was called; no row).
  - `testUnlinkRemovesFirstThenSendsTheFarewellThenLeavesShares` (call order in `LinkEventLog`).
  - `testRemovedByMacFreezesThatHubAndKeepsItsRow` (row state `unlinked_by_mac`; no `removeHub`).
  - `testAccountChangeRemovesEveryHubWithoutKeepingRecordings`.
  - `testStaleNoticeOnlyForTheActiveHub`.
  In `AppRootWiringTests`, replace the restart tests with (real `AppEnvironment`, in-memory transports through an injected factory, temp `HubPaths`):
  - `testRemovalOfAnInactiveHubFreezesOnlyThatHub` (Review Focus 4): two linked hubs, `hub-a` active; `hub-b`'s session emits the unlinked signal → `hub-b` row `unlinked_by_mac`, `hub-b` not looping and its outbox refuses (no device id); `hub-a` still loops, still active, its row `linked`.
  - `testUnlinkingTheActiveHubActivatesTheNextAndTheLastReturnsToOnboarding`.
  - `testUnlinkDeletesTheHubsFilesAndHoldsItsRecordings` (its `hubs/<id>` and recordings folder are gone; the hold manifest names its unsent recording).
  - `testTheGrantRemovalCheckReadsEachHubsOwnGrant` (#205's two-look rule on `hub-b` while `hub-a` is active).
- [ ] **Step 2:** `make mobile-test MOBILE_FILTER='LinkingViewModelTests|AppRootWiringTests' > /tmp/f2-t4.log 2>&1; echo "exit=$?"` — fails to build.
- [ ] **Step 3: Implement** the protocol, the view model, `AppRoot`, `AppRootView` (`LinkNoticeBanner`: `.stale` keeps its Scan button; `.removed` gets a Close button and the text "<Mac name> removed this phone" — plus "— N not sent" when `notSent > 0`, as #205 words it), `LinkFailure.tooManyMacs` (title "You can link up to 4 Macs", hint "Unlink one in Settings → Macs, then scan again", retryable false), `LinkStore` cleanup. `HubSession.unlinkedHubID` and every use of it are removed (a phone with no links has no sessions).
- [ ] **Step 4:** `make mobile-test MOBILE_FILTER='LinkingViewModelTests|AppRootWiringTests|HubBootTests|MultiHubEnvironmentTests' > /tmp/f2-t4.log 2>&1; echo "exit=$?"` → `exit=0`; then `make mobile-test > /tmp/f2-t4-all.log 2>&1; echo "exit=$?"`.
- [ ] **Step 5: Commit** `feat(mobile): link, unlink and removal per hub over the registry; drop the switch prompt and the moved notice (multi-hub F2)` — the message lists the removed tests.

---

## Task 5: recording across hubs

**Files:**
- Modify: `WatchtowerMobile/Sources/App/AppEnvironment.swift` (`recorder`, `capturingSession`, the start gate)
- Modify: `WatchtowerMobile/Sources/Features/Recording/PhoneRecorderController.swift` (only if a start needs a refusal reason; see Step 3)
- Modify: `WatchtowerMobile/Sources/Features/Recording/RecordingView.swift` (the Mac's name on a capture for another hub)
- Modify: `WatchtowerMobile/Sources/App/Hubs/HubSession+RecordingHandover.swift` (serialised hold access)
- Test: `WatchtowerMobile/Tests/MultiHubRecordingTests.swift`

**Interfaces:**
- Consumes: Tasks 2–4.
- Produces: `AppEnvironment.capturingSession: HubSession?` (the session whose recorder is capturing or paused); `AppEnvironment.recorder` = `capturingSession?.recorder ?? active!.recorder`; `AppEnvironment.canStartCapture: Bool` (no session capturing); `HubSession.hubName` (for the recorder chrome: the registry display name, set by the root). A process-wide `HoldGate` actor (`static let shared`) that `adoptHeld` and `handOverRecordings` run their hold reads and writes through.

Rules:
- The recorder chrome and the Record buttons read `env.recorder`. While a capture runs on hub A, switching to hub B keeps showing A's capture (with "Recording for <A name>") and B's Record buttons are disabled (`!env.canStartCapture`).
- A capture finished on hub A after a switch is uploaded by A's uploader: nothing changes in `HubSession`, which already owns its uploader; the inactive cadence keeps A fetching every 30 s while the upload is pending (Task 2).
- The Recordings list reads `env.phoneRecordings` (the active session's) and `env.heldRecordings`.

- [ ] **Step 1: Write the failing tests** (`MultiHubRecordingTests`, two sessions with fake audio engines):
  - `testARecordingStartedOnOneHubFinishesThereAfterASwitch` (Review Focus 5): start on `hub-a`, `env.activate("hub-b")`, stop; the recording's upload records land in `hub-a`'s transport only; `hub-b`'s transport has no `recording_upload` record; `env.recorder === hubA.recorder` until the capture ends, then `=== hubB.recorder`.
  - `testOneCaptureAtATimeAcrossHubs` (`canStartCapture` false on `hub-b` while `hub-a` captures).
  - `testTheRecordingsListShowsTheActiveHubsRecordings`.
  - `testTwoSessionsAdoptTheirOwnHeldRecordingsAtOneBoot` (Review Focus 3): a hold manifest with one recording for `hub-a` and one for `hub-b`; build both sessions at once; after both `adoption` tasks, each session's replica has its own recording, each audio file is in its hub's folder, and the manifest is empty.
- [ ] **Step 2:** `make mobile-gen && make mobile-test MOBILE_FILTER=MultiHubRecordingTests > /tmp/f2-t5.log 2>&1; echo "exit=$?"` — fails.
- [ ] **Step 3: Implement.** The start gate lives in the views' Record actions (`guard env.canStartCapture`), not in the recorder; change `PhoneRecorderController` only if a test shows a start path that bypasses the views (the calendar's "Record this meeting" and the Now tab's button both go through `env.recorder`). `HoldGate`: an `actor` with `func run<T>(_ body: () throws -> T) rethrows -> T`; `adoptHeld` and `handOverRecordings` wrap each load-modify-save of the manifest in one `run`.
- [ ] **Step 4:** `make mobile-test MOBILE_FILTER='MultiHubRecordingTests|RecordingsWiringTests|RecorderTests|RecordingHoldTests' > /tmp/f2-t5.log 2>&1; echo "exit=$?"` → `exit=0`.
- [ ] **Step 5: Commit** `feat(mobile): a recording stays with the Mac it started on; one capture across hubs (multi-hub F2)`.

---

## Task 6: the switcher

**Files:**
- Create: `WatchtowerMobile/Sources/Features/Hubs/HubSwitcherChip.swift`
- Create: `WatchtowerMobile/Sources/Features/Hubs/HubListSheet.swift`
- Create: `WatchtowerMobile/Sources/Features/Hubs/HubListModel.swift`
- Modify: `WatchtowerMobile/Sources/Features/Now/NowView.swift`, `WatchtowerMobile/Sources/Features/Workbench/WorkbenchView.swift` (the chip), `WatchtowerMobile/Sources/App/AppRootView.swift` (`RootTabView().id(env.activeHubID)`)
- Test: `WatchtowerMobile/Tests/HubSwitcherTests.swift`

**Interfaces:**
- Consumes: Tasks 1–5 (`HubRow`, `HubDisplayName`, `MacStatus` from `Features/Settings/SettingsViewModel.swift`, `AppEnvironment.sessions/order/activeHubID/activate`, `LinkingViewModel.startScan()`, `links`).
- Produces: `struct HubListItem: Identifiable, Equatable { let id: String; let name: String; let flavor: String?; let online: Bool; let offlineDays: Int?; let openAsks: Int; let isActive: Bool; let removedByMac: Bool; let canForget: Bool; let problem: String? }` and `enum HubListModel { static func items(rows: [HubRow], sessions: [String: HubSession], activeHubID: String?, now: Date) -> [HubListItem] }`.

Rules (§5.6): online = `MacStatus(heartbeat:now:)` is `.online` (heartbeat under 720 s); `offlineDays` = whole days since the last heartbeat (`row.lastHeartbeatAt`, else `linkedOn`) when offline; `flavor` shown only when it is not `"default"`; `canForget` = `removedByMac || offlineDays ?? 0 >= 7`. `problem` = the session's `lastFetchError`, shown as a secondary line under the name. The chip shows the active item's name and a small open-ask total of the other hubs when it is above 0 (accessibility label "<name>, Mac. N asks waiting on other Macs"). The sheet lists the items in registry order (tap = `env.activate(id)` and dismiss; a `removedByMac` row reads "Removed this phone" in place of the online dot), then **Add Mac** (`linking.startScan()`, disabled with the footnote "You can link up to 4 Macs" at the limit). With one linked Mac the chip still shows (it is the way to Add Mac).

- [ ] **Step 1: Write the failing tests** (`HubSwitcherTests`, pure `HubListModel` plus one wiring test):
  - online and offline days from heartbeats at `now − 600 s` and `now − 8 d`; `canForget` for the 8-day and the removed rows only.
  - duplicate names get the suffix (through `HubDisplayName`).
  - a session whose last fetch failed shows its `lastFetchError` as the row's `problem`; the other row has none (§6.3).
  - `flavor` hidden for `"default"`, shown for `"corp"`.
  - open-ask counts per hub from each session's `workbenchReplica.openAskCount`.
  - wiring: `env.activate` from the list resets `env.navigation` to its root (`navigation.calendarPath` empty, tab unchanged) — implement by `AppNavigation.resetStacks()` called in `activate`.
- [ ] **Step 2:** `make mobile-gen && make mobile-test MOBILE_FILTER=HubSwitcherTests > /tmp/f2-t6.log 2>&1; echo "exit=$?"` — fails.
- [ ] **Step 3: Implement** the model, the chip (a `Button` in the toolbar's leading/principal slot of Now and Workbench, using the design system's `Pill` and `PhoneTone`), and the sheet (`List` with `FlatRow`s; follow `Features/Settings/MacStatusRow.swift` for the dot). `AppNavigation.resetStacks()`.
- [ ] **Step 4:** `make mobile-test MOBILE_FILTER='HubSwitcherTests|MultiHubEnvironmentTests' > /tmp/f2-t6.log 2>&1; echo "exit=$?"` → `exit=0`; `make mobile-build > /tmp/f2-t6-build.log 2>&1; echo "exit=$?"`.
- [ ] **Step 5: Commit** `feat(mobile): Mac switcher chip and list with Add Mac (multi-hub F2)`.

---

## Task 7: Settings → Macs

**Files:**
- Create: `WatchtowerMobile/Sources/Features/Settings/MacsView.swift`
- Modify: `WatchtowerMobile/Sources/Features/Settings/SettingsView.swift`
- Test: `WatchtowerMobile/Tests/SettingsWiringTests.swift`

**Interfaces:**
- Consumes: Task 6's `HubListModel`/`HubListItem`; Task 4's `LinkingViewModel.unlink(_:)`, `forget(_:)`; `HubRegistry.move(_:to:)` through a new `AppRoot.moveHub(_:to:)` (updates the registry and `env.order`).
- Produces: `MacsView`.

Rules (§5.6): Settings' "Your Mac" section becomes "This Mac" (the active hub, unchanged content) and gains a row "Macs" (with the linked count) that opens `MacsView`. `MacsView`: the items in order with `EditButton` reordering (`onMove` → `moveHub`); each row's swipe action and context menu offer **Unlink** (linked rows; the existing confirmation dialog, now "Unlink <name>?") or **Forget** (`canForget` rows; dialog "Forget <name>? Its data on this iPhone is deleted."); **Add Mac** at the bottom as in the sheet. The old bottom "Unlink this Mac" section unlinks the active hub (kept, renamed "Unlink <name>"). The settings toggles (typing, start sessions) are the active hub's (Task 2 made them per hub).

- [ ] **Step 1: Write the failing tests** in `SettingsWiringTests`: reorder persists (`registry.rows()` order and `env.order`); Unlink on an inactive hub removes only it; Forget on a frozen hub removes it with no farewell record (`SaveLogTransport` empty); the toggles read the active hub's keys after a switch.
- [ ] **Step 2:** `make mobile-gen && make mobile-test MOBILE_FILTER=SettingsWiringTests > /tmp/f2-t7.log 2>&1; echo "exit=$?"` — fails.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** `make mobile-test MOBILE_FILTER='SettingsWiringTests|HubSwitcherTests' > /tmp/f2-t7.log 2>&1; echo "exit=$?"` → `exit=0`.
- [ ] **Step 5: Commit** `feat(mobile): Settings → Macs — reorder, unlink, forget (multi-hub F2)`.

---

## Task 8: the demo seeds two hubs

**Files:**
- Modify: `WatchtowerMobile/Sources/App/DemoSeed.swift` (+ `DemoSeed+Workbench.swift` for the second hub's small board)
- Modify: `WatchtowerMobile/Sources/App/AppEnvironment.swift` / `AppRoot.swift` (the demo root: two in-memory sessions, an in-memory registry with two rows)
- Test: `WatchtowerMobile/Tests/ReplicaWiringTests.swift` (the seed tally), `WatchtowerMobile/Tests/ScreenshotTourTests.swift` (one shot of the switcher sheet)

**Interfaces:**
- Produces: `DemoSeed.Hub` (`hubID`, `macName`, `flavor`) with `DemoSeed.primary` (`demo-hub`, "Acme Mac", default — today's seed) and `DemoSeed.secondary` (`demo-hub-home`, "Home Mac", default): one workbench, three targets, one open ask, a heartbeat and a grant, no calendar; `DemoSeed.load(into:hub:now:)`.

- [ ] **Step 1:** extend the seed-tally test: the primary tally is unchanged; the secondary's records are counted separately; the demo root has two rows, the primary active.
- [ ] **Step 2:** run `make mobile-test MOBILE_FILTER='ReplicaWiringTests|ScreenshotTourTests' > /tmp/f2-t8.log 2>&1; echo "exit=$?"` — fails.
- [ ] **Step 3: Implement**; the demo never links or unlinks (Add Mac in the demo opens the scan, which the demo already ignores for link URLs).
- [ ] **Step 4:** the same run → `exit=0`; `make mobile-build`.
- [ ] **Step 5: Commit** `feat(mobile): the demo shows two Macs (multi-hub F2)`.

---

## Task 9: docs and the board

**Files:**
- Modify: `docs/features/mobile-companion.md` — the phone half: replace the "One link: the transport runs the linked hub's zones (multi-hub F1 bridge)" bullet with a "Several Macs (multi-hub F2)" subsection: registry and paths, `HubSession`/`AppEnvironment`, cadence, recording rules, the switcher and Settings → Macs, the link flow per hub, removal = freeze until Forget, account change, the F1 migration; update the "Onboarding and linking, phone half (A12)" bullets that name the switch prompt, the moved notice, `Restarter` or `retireEnvironment`.
- Modify: `docs/superpowers/specs/2026-10-11-mobile-multi-hub-design.md` — Status line: "F1 and F2 built; §5.5 notifications per hub built with A13".
- Modify: `CLAUDE.md` — the Mobile companion feature-note line: add "multi-hub F2 (registry, `HubSession`, switcher)".

- [ ] **Step 1:** write the docs. **Step 2:** the controller (not the subagent) updates board #17's intent: "Build per hub from the start (multi-hub spec §5.5): subscription `ask-alerts-<hub_id>` per private-scope session, local notifications from every session's fetch with that hub's watermark, `hub_id` in every notification, a tap activates that hub and opens the ask (`AppEnvironment.activate`); the badge already sums the hubs (F2)." **Step 3:** commit `docs(mobile): multi-hub F2 on the phone`.

---

## Task 10: owner smoke on two Macs (OWNER-RUN, filed as an ask)

**Depends on:** Tasks 1–9 merged, a TestFlight build (`make testflight`) for the phone, and two Macs with the hub on: Mac 1 on the phone's Apple ID, Mac 2 on another Apple ID (a second Mac, or a second user account on one Mac with its own Apple ID and a `dev`-flavor install).

`ask_owner` `kind: check`, `target_id` = this task's board target, checklist:
1. The phone, still linked to Mac 1 from the previous build, updates to this build and stays linked; its board and recordings are there.
2. Settings → Mobile on Mac 2 → scan its code: the phone links Mac 2 without asking to switch; Mac 2 is active.
3. The chip on Now shows Mac 2; the list shows both Macs, both online, each with its open-ask count.
4. Answer an ask on Mac 2, switch to Mac 1, answer an ask there: each Mac gets its own answer only.
5. Start a voice note on Mac 1, switch to Mac 2 while recording, stop: the recording reaches Mac 1.
6. Lock the phone, create an ask on the inactive Mac, unlock after a minute: the app icon badge counts it; the list shows it within 5 minutes in the foreground.
7. Settings → Macs: reorder, then unlink Mac 2: Mac 1 stays and is active; Mac 2 no longer lists the phone.
8. Link Mac 2 again, then remove the phone on Mac 2 (Settings → Mobile → Remove): the phone shows "Mac 2 removed this phone", Mac 2's data stays readable, Forget deletes it; Mac 1 untouched.
9. Two Macs with the same name show a short suffix (rename one Mac temporarily if needed — optional).

---

## Phase end (controller)

- [ ] `bash scripts/dev-health.sh`; then the gate: `make test-swift > /tmp/f2-gate-swift.log 2>&1; echo "exit=$?"` (Desktop + Kit, untouched but run once), `make mobile-test > /tmp/f2-gate-mobile.log 2>&1; echo "exit=$?"`, `make lint-all > /tmp/f2-gate-lint.log 2>&1; echo "exit=$?"`. `make test` is not needed (no Go change).
- [ ] The whole-branch review (local-review skill, debate-review for the PR into `main`), then the PR, then Task 10's ask.
