# Relay client Phase 3 — phone identity, linking over the relay, following a switch, epoch keys, interop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire Phase 2's hosted relay transport into the iPhone app. The phone gets a `relay_auth` key and an App Attest key id in the Keychain, the App Attest entitlement and a relay origin build setting. It reads `LinkPayload` v4, links a Go hub over a relay pairing slot (`pair/<slot>`) and states its own `relay_device_id` in the sealed hello. It follows the hub's `transport_switched`, the transport marker and `hub_on_relay` (sim rules 12–15 and R32). It keeps every epoch key for 7 days after a newer one arrives and sends `epoch_ack`. A Kit phone is shown to link and drive the real Go hub on the relay's local stand. Phase 3 splits in two:

- **Phase 3a** (Tasks 1–16) needs nothing that does not exist. It ships dark: a Release build has no relay origin, so it never builds a relay client.
- **Phase 3b** (Tasks 17–21) is blocked on named relay and Go hub work.

**Architecture:**

- **Kit, `WatchtowerHostedRelay`:**
  - `KeychainRelayIdentity`, the `relay_auth` signer and App Attest key id store, on the Kit's `KeychainBackend`;
  - `HostedRelaySession`, one client and one WebSocket per device, shared by every relay hub and pairing slot of the phone;
  - a pairing mode of `HostedRelayTransport`, in which both lanes map to `pair/<slot>`;
  - `HostedRelayPairing`, which wraps `open_pairing`, `promote_pairing`, `close_pairing`, the slot pre-check and a vouch seam that stays empty until Phase 3b.
- **Kit, `WatchtowerSync`:**
  - `LinkPayload` reads v4 (it still issues v3 for the Swift hub);
  - `DeviceHello.relayDeviceID`, and `DeviceGrant` relay fields;
  - time-based epoch retention in `HubLinkKeys`;
  - `TransportFollowerPolicy`, a pure decision table for sim rules 12, 12a, 13, 15 and R32. The production follower and the sim twins' `SimPhone` both run it.
- **Phone:**
  - `RelayConfig` (origin, from `Info.plist`);
  - `RelayAvailability`;
  - `TransportFactory` builds the relay transport, with one `TransportStore` file per route;
  - `LinkRecord` keeps the hub's relay identity and current transport;
  - `LinkRoutePolicy` decides the route from the code;
  - `LinkingViewModel` adds the relay path and new failures;
  - `TransportFollower` moves a hub's session to the new route;
  - `SideMailboxReader` covers rule 12's 60 s poll and rule 15's drain.
- **Interop:** a Kit-level test links and drives the Go hub (test mode, `WATCHTOWER_HUB_DIR`) on the relay's local stand. It coordinates with a Go `-tags interop` test through files. Phase 3a changes no Go hub production code.

**Tech Stack:** Swift 5.10 language mode, Swift concurrency, CryptoKit, DeviceCheck (`DCAppAttestService`), Security (Keychain), GRDB, SwiftUI; `WatchtowerKit` (`WatchtowerSync`, `WatchtowerHostedRelay`, `WatchtowerHostedRelayTesting`), `WatchtowerMobile` (xcodegen, iOS 17); XCTest; Go 1.26 (test-only files, `-tags interop`); Node/`wrangler` for the stand (developer machine only).

**Spec:** `docs/superpowers/specs/2026-10-29-relay-client-design.md`:

- §3 (`HubRoute`, `LinkAccess`, `TransportFactory`);
- §4 (identity, App Attest, origin);
- §8 (linking over the relay, vouching);
- §9 (switch and epochs);
- §11 (testing);
- §12 p. 4 (relay CI interop job);
- §13 row 3 (board #1241, #1242, #1247);
- §14 (docs);
- Decisions, including ask #854's Phase 3 items: the Keychain key id and the entitlement, the routing test `testAttestUnsupportedStaysOnCloudKit`, and the `pair/<slot>` zone.

**Counterpart:**

- `docs/superpowers/specs/2026-10-31-hub-phone-protocol-design.md`: §3.3, §4.2, §5.1–§5.10, §7.6, Decisions (ask #843: 7-day retention, the switch notice in the transport being left);
- `docs/superpowers/specs/2026-10-31-go-hub-design.md`: §7, §10, §12a;
- the Go hub plans `2026-10-31-go-hub-phase-{1,1b,2,3}.md`, including Phase 3's "Phone contract points" 1–8;
- the Go hub code on `main`: `internal/hub/link/relay.go`, `link/hello.go`, `wire/{link,grant,payloads}.go`, `actions/control.go`, `hubtest/{phone,relay}.go`, `interop_test.go`, `cmd/hub_link.go` (`hub pair --json --stream`).

**Relay contract:** relay `main` at `3a99bd7`: `proto/README.md` ("Control events", "Operations notes", "Slots", "Zone names", "Failure paths on the client") and `sim/README.md` (rules 8–16, "Bounded state", "Watchtower `hub_id` vs. the relay's ids", "Attestation scenarios"). Relay PR #3 (`fix/changes-resync`, `5d8b577`): `Changes.resync`.

**Mockups:** `docs/design/mockups/relay-client/index.html`.

## External dependencies

Checked on 2026-10-31:

- relay branches were searched read-only for `vouch` and `DEVICE_KIND_HUB` (none in any branch);
- `origin/main` contains Go hub plans 1a and 1b;
- `origin/feature/go-hub` holds Go hub Phase 2 in progress.

| # | Dependency | Status | Blocks |
|---|---|---|---|
| E1 | **Go hub 1a/1b**: the hub half of linking over the relay. `OnPairingOpened` reads hellos in `pair/<slot>` and answers keyboxes there; `SyncReaders` calls `set_hub_readers`; the hello's `relay_device_id` is validated and stored. Also: the v4 QR, the ordered path, controls (records `epoch_ack`, rejects `transport_switch` "not supported yet"), `hub pair --json --stream`, the interop harness. | **Done**, on `main` | nothing: Phase 3a builds against it |
| E2 | **Relay ask #805**: `DEVICE_KIND_HUB`, `vouch_hub{hub_device_id, auth_pub}` with the phone's assertion over the relay's vouch digest, `HUB_NOT_VOUCHED`. | **Not started on the relay**: no branch of `aiwatchtowers/relay` has `vouch_hub` or `DEVICE_KIND_HUB` (`3a99bd7`, `fix/changes-resync`, `ops/staging-rollout`, `feature/relay-cf`, `feature/relay-v1`, `protocol/v1-freeze`, `aa/task-2`, `aa/task-3`). The relay's App Attest rule reversal waits on the owner in relay ask #805. | Tasks 17–19, 21; any production relay admitting a hub |
| E3 | **Go hub Phase 2 Task 10**: vouched admission on the hub. | **Blocked on E2**; the rest of Go hub Phase 2 is in progress on `feature/go-hub`: Tasks 3, 5, 6, 7 and 8 have merged there. | Task 18's interop, Task 21 |
| E4 | **Go hub Phase 3 Tasks 18 and 20**: the hub's switcher, which writes `transport_switched` with the keybox, the transport marker and `hub_on_relay`, and handles epochs, entitlement and `resend_from` for retired epochs. **Go hub Phase 3 Tasks 12 and 21**: a Mac on the Go hub publishes its relay identity in `device_grant`. | **Not started**: the plan is approved (ask #856) | Tasks 19, 20, 21 |
| E5 | **Relay PR #3** (`fix/changes-resync`, `5d8b577`): `Changes.resync = 4`. | **Open, not merged**; the Kit move is tracked by board #1430 | Task 17 |
| E6 | **Relay §12 p. 4**: a job in the relay repository's CI that builds the Kit client and runs the interop. | **Relay session's work** (ask #734). Phase 3a provides the entry point (Task 14). | nothing in Phase 3a; it closes Phase 2's R15 fake-only gap when it lands |
| E7 | **Relay §12 p. 5**: staging, the production origin, App Store Connect, APNs. | Before launch. The production origin is not announced yet. | the Release origin (R1); Phase 4 |

Phase 3a = Tasks 1–16. Phase 3b = Tasks 17–21. Each 3b task names its blockers in its title and its `Depends on:` line.

## Global Constraints

- **Dark ship.** With an empty `WATCHTOWER_RELAY_ORIGIN` (every committed build setting, and so every Release build) `RelayAvailability` is `.off(.notConfigured)`. In that state the app:
  - constructs no `HostedRelayClient`, `HostedRelaySession` or `KeychainRelayIdentity`;
  - creates no Keychain item;
  - makes no DeviceCheck call;
  - opens no network connection to a relay.

  Task 9's `testAnEmptyOriginBuildsNoRelayObject` pins this.

  What a Release build still runs, all of it, so Owner approval 1 is informed:
  - **v4 link codes:** a Go hub's code on a Mac (when one ships) links over iCloud; a headless host's relay-only code is refused with "works over Relay only" (the one new screen a production phone can reach);
  - **epoch keys:** the time-based retention (R8), the `supersededAt` stamp in `mergeKeys`, the NSE's alert material carrying every retained epoch, and `epoch_ack` toward an ordered (Go) hub;
  - **rule 14 reseal** on `resend_from` toward an ordered hub (R10);
  - **following a switch on CloudKit:** `RelayFeed` hands `transport_switched` and `hub_on_relay` to the follower, and the hydrator reads the transport marker. A switch to CloudKit is followed; a switch to the relay or `hub_on_relay` lists unechoed actions as Not delivered (R32). Only a Go hub writes these records, and only after a paying phone switched it (Go hub Phase 3 Task 18), which no production phone can do before Phase 4: in a Release build this code runs and finds nothing;
  - **registry migration `v3-relay`** (Task 9) and the new optional `LinkRecord` keys, written as nil/absent for every CloudKit link.

  Nothing else changes for a Release phone.
- **CloudKit unchanged.** Every existing Kit, Desktop and phone test keeps its assertions. Contract tests that change are named in Owner approval. `CloudSyncTransport` keeps its three requirements.
- **Desktop.** No behaviour change. A `WatchtowerDesktop/Sources` file may change only where the compiler requires it for `LinkPayload`'s optional v4 fields (Task 4), and only to keep today's values. `make test-swift FILTER='MobileLink|SeamTypesTests'` stays green.
- **Go.** Phase 3a adds test-only Go files: the `device_hello` case in `internal/hub/wire`'s fixture test (Task 4) and `internal/hub/interop_kit_test.go` under `-tags interop` (Task 13). It changes no Go hub production file. `go test ./internal/hub/...` stays green.
- **Inventory guards** (PROJ-16, PROJ-21) are byte-identical at the end of every task. This command prints nothing: `git diff --stat origin/main -- WatchtowerDesktop/Tests/MobileHub/SessionInputHandlersTests.swift WatchtowerDesktop/Tests/MobileHub/PermissionAnswerHandlersTests.swift WatchtowerDesktop/Tests/MobileHub/PermissionRequestSliceTests.swift WatchtowerKit/Tests/WatchtowerSyncTests/PermissionAllowRuleTests.swift WatchtowerMobile/Tests/PermissionCardTests.swift WatchtowerMobile/Tests/SessionInputWiringTests.swift`.
- **Wire bytes.** The E2E vectors stay frozen (no `make e2e-vectors`). New contract cases go into `WatchtowerKit/Tests/Fixtures/link/hub_contract_cases.json` as plain JSON, read by the Kit test and by the Go test named in Task 4.
  - The hello's new key is `relay_device_id` on the wire. Under `RelayCoder` (snake-case conversion) its `CodingKey` raw value is `relayDeviceId`, lowercase `d`, as `ControlPayload`'s `deviceId`.
  - A phone's `relay_device_id` is lower-case unpadded base32 of SHA-256 of its `relay_auth` public key: 52 characters `a–z2–7`, the Go hub's `validRelayDeviceID`.
- **Secrets.** These are never logged, never in an error's description, and never written outside the Keychain:
  - the `relay_auth` private key, the App Attest key id and session tokens;
  - keybox envelopes, including the one inside `transport_switched`;
  - attestation bytes.

  Keychain items:
  - are `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (`KeyAccess.afterFirstUnlock`);
  - never set `kSecAttrSynchronizable`;
  - live in the app's private access group, never the alerts group the NSE reads.

  Logs (category `HostedRelay`, `Linking`, `TransportFollower`) carry op names, codes, zone kinds, epochs and counts only.
- **One socket per device.** The relay displaces an older socket of the same device (close 1001 after `GoingAway`). Every phone-side relay object goes through the one `HostedRelaySession` of the process, so the app never opens two. The NSE links no relay target (R20).
- **UI rules.** These apply to every new or changed screen:
  - the mockup task (Task 8) lands before its UI task;
  - UI copy lives in the models and tests assert it;
  - colours come only through `PhoneTone`, and components from `Sources/DesignSystem/`;
  - each new state gets a `ScreenshotTourTests` shot (the phone has no `DesignShotCatalog`, Phase 1 Ruling 14);
  - after implementation, `make mobile-shots SIM='iPhone 17 Pro'` is compared with the mockup state by state.
- **Phone project.** A new phone source or test file needs `make mobile-gen`, and the regenerated `WatchtowerMobile/WatchtowerMobile.xcodeproj` is committed in the same task. Phone tests run with `SIM='iPhone 17 Pro'`.
- **Inner loop per task:**
  - `make kit-test FILTER='…'`;
  - `make test-swift FILTER='…'` (Desktop compile checks);
  - `make mobile-test SIM='iPhone 17 Pro' MOBILE_FILTER='…'`;
  - `make lint-swift`;
  - `go test ./internal/hub/wire` in Task 4 and `make lint-diff` in Tasks 4 and 13, the tasks that add Go.

  Never run a build or test in the background. Long runs go to a log with an explicit exit code: `cmd > "${TMPDIR:-/tmp}/p3-<task>.log" 2>&1; echo "exit=$?"`. The full gate runs once, in Task 16.
- **Processes are reaped.** Interop scripts start `wrangler dev` and the Go interop test each in its own process group, and kill and wait for both on every exit path (`trap … EXIT INT TERM`). Tests never start processes.
- **Public repo.** No staging or production relay URL is committed: the staging host carries a personal handle. Fixtures and mockups use:
  - `https://relay.example.com` and `http://127.0.0.1:8787`;
  - "Work Mac" and "build-box";
  - `acme`;
  - the fixture UUIDs already in `hub_contract_cases.json`;
  - relay device ids derived from fixed test seeds.

  There are no real device ids, account ids, tokens or local paths.

## Review Focus

1. **One socket per device.** Two relay hubs plus a pairing slot share one `HostedRelayConnection`, and a zone's events reach only the transport that owns it. Task 3: `testTwoHubsAndAPairingSlotShareOneSocket`, `testAZoneEventReachesOnlyItsTransport`, `testRemovingATransportKeepsTheOthersSubscribed`.
2. **The route decision.**
   - A free phone, an unsupported device or an empty origin never goes to the relay; a v4 code of a Mac on iCloud links over iCloud as today; a Mac on Relay is refused with no dead iCloud option.
   - A relay-only code on such a phone is refused, with no Keychain item, register or hello.
   - Task 9: `testAttestUnsupportedStaysOnCloudKit`, `testAnEmptyOriginBuildsNoRelayObject`. Task 10: `LinkRoutePolicyTests`.
3. **Pairing leaves nothing half-done.**
   - The hello is written only into `pair/<slot>`.
   - Promote comes only after the keys arrived.
   - A failure before promote closes the slot and removes the hub's keys and session.
   - The slot limit is checked before `open_pairing`.
   - `FORBIDDEN` on the data zone before the first successful read is "not a reader yet" and is never a revocation; a failure after promote resumes or ends the link with the farewell and `remove_slot`, never half-linked.
   - Tasks 5 and 10.
4. **Epoch keys.**
   - No data or alert key is dropped earlier than 7 days after a newer epoch arrived.
   - `epoch_ack` is never lowered and is sent only to an ordered hub.
   - The NSE's alert material follows the same set.
   - Task 6: `testAnEpochIsKeptSevenDaysAfterItWasSuperseded`, `testEpochAckNeverGoesDown`.
5. **Following a switch** (rules 12, 12a, 13, 15, R32).
   - Unechoed actions go only to the new transport, with the same envelope bytes.
   - A marker is followed only when its epoch is newer than the phone's.
   - The old mailbox is drained after unseen hub records were handled.
   - On `hub_on_relay` every unechoed action is listed as Not delivered: nothing is applied twice or dropped silently.
   - Tasks 7, 11, 12.
6. **Rule 14 reseal.** Only rows sealed in an epoch older than the current one are resealed, under the same `action_seq`. Rows in the current epoch are resent byte for byte, as in Phase 1. Task 6: `testResendFromResealsOnlyOlderEpochRows`.
7. **Secrets and Keychain classes.** Task 1: `testItemsAreAfterFirstUnlockThisDeviceOnlyAndNeverSynced`. Task 13's canary covers the interop run's wire.

## Lanes

- **A (Kit relay):** Task 3 → Task 5.
- **B (wire):** Task 4.
- **C (identity and build settings):** Task 1 and Task 2, in parallel.
- **D (keys and policy):** Task 6 and Task 7, in parallel; Task 7's twins need no other task.
- **E (design):** Task 8, with no code dependency.
- **Joins:**
  - Task 9 after 1, 2, 3, 4;
  - Task 10 after 5, 8, 9;
  - Task 11 strictly after Task 10 (and after 6, 7, 8): never in parallel with it. Both edit `AppRoot.swift`, `LinkingViewModel.swift` and `HubSession.swift`, in that order: Task 10 first, Task 11 on top of it;
  - Task 12 after 11;
  - Task 13 after 4 and 5, beside 9–12;
  - Task 14 after 13;
  - Task 15 after 10–14;
  - Task 16, the gate, after 1–15.
- **Blocked (3b):** Task 17 waits for E5 and may run any time after Task 3 once E5 has landed. Tasks 18–21 wait for E2–E4.

Each parallel lane runs in its own worktree and branch, merged by the controller. The phone registry gets exactly one new migration in the whole phase, `v3-relay`, in Task 9; Tasks 10, 11 and 12 add no migration (their state lives in `LinkRecord`'s JSON and in the tables `v3-relay` creates). Tasks 1 and 2 both touch `WatchtowerMobile/project.yml`, so Task 2 rebases on Task 1 before `make mobile-gen`. Tasks 3 and 5 both touch `HostedRelayTransport`, so they run in one lane.

---

### Task 1: The relay identity in the Keychain

**Depends on:** none

**Files:**
- Create: `WatchtowerKit/Sources/WatchtowerHostedRelay/Identity/KeychainRelayIdentity.swift`
- Modify: `WatchtowerKit/Sources/WatchtowerHostedRelay/Attest/AppAttestKeyStore.swift` (doc comment: the Keychain store is `KeychainRelayIdentity`; the in-memory one stays for tests)
- Test: Create `WatchtowerKit/Tests/WatchtowerHostedRelayTests/KeychainRelayIdentityTests.swift`; Create `WatchtowerMobile/Tests/RelayKeychainDeviceTests.swift` (a real Keychain on the simulator, as `KeychainKeyStoreDeviceTests`); `make mobile-gen`

**Interfaces:**
```swift
public final class KeychainRelayIdentity: AppAttestKeyStore, @unchecked Sendable {
    /// `group`: the app's private Keychain group (never the alerts group).
    public init(backend: any KeychainBackend, group: String?)
    /// The stored signer; nil when none exists. Never creates.
    public func existingSigner() throws -> (any RelaySigner)?
    /// The stored signer, created on first use (`add`, never `write`: two creators never clobber; a lost race reads the winner's).
    public func signer() throws -> any RelaySigner
    public func keyID() -> String?          // AppAttestKeyStore
    public func setKeyID(_ id: String?)     // nil deletes the item
}
```

- Items:
  - `relay.auth` holds the raw 32-byte Ed25519 private key;
  - `relay.attestkey` holds the App Attest key id as UTF-8.

  Both are `.afterFirstUnlock`, `dataProtection: true`, in `group`.
- A locked device throws `KeyStoreError.locked` and creates nothing.
- A key that is not 32 bytes throws `KeyStoreError.corrupt` and is never replaced silently.
- `setKeyID` errors are logged by code only. `AppAttestKeyStore` is non-throwing, so a failed write reads as "no key" next time, which is the lost-key path.

- [ ] **Step 1: Failing tests**
  - `KeychainRelayIdentityTests`, on a recording in-memory `KeychainBackend`:
    - `testSignerIsCreatedOnceAndReused`;
    - `testExistingSignerNeverCreates`;
    - `testALostCreateRaceReadsTheWinner` (`add` returns false);
    - `testItemsAreAfterFirstUnlockThisDeviceOnlyAndNeverSynced` (the access class and group passed to every call);
    - `testACorruptKeyThrowsAndIsKept`;
    - `testLockedCreatesNothing`;
    - `testKeyIDRoundTripsAndNilDeletes`;
    - `testRelayDeviceIDOfTheStoredKeyIsStable` (`RelayAuthMessages.deviceID` over the stored public key).
  - `RelayKeychainDeviceTests.testRealKeychainRoundTrip` creates, re-reads and deletes items under a test-only service.
- [ ] **Step 2: Run, expect failure:** `make kit-test FILTER=KeychainRelayIdentityTests` fails.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run:** the Step 2 filter, then `make mobile-gen`, then `make mobile-test SIM='iPhone 17 Pro' MOBILE_FILTER=RelayKeychainDeviceTests`. Both pass.
- [ ] **Step 5: Lint and guard check:** `make lint-swift` and the guard-file diff.
- [ ] **Step 6: Commit:** `feat(kit): relay_auth and the App Attest key id in the Keychain (#1241)`

### Task 2: Relay origin, App Attest entitlement, the app links the relay product

**Depends on:** none (rebase on Task 1 before `make mobile-gen`)

**Files:**
- Modify: `WatchtowerMobile/Base.xcconfig`:
  - `WATCHTOWER_RELAY_ORIGIN =` (empty);
  - `WT_APP_ATTEST_ENV = development`;
  - a comment: an origin in an xcconfig needs `https:/$()/host`, because `//` starts a comment.
- Modify: `WatchtowerMobile/Signing.xcconfig.template` (commented example lines for a stand origin and `WT_APP_ATTEST_ENV`; no real host)
- Modify: `WatchtowerMobile/project.yml`:
  - the app target depends on the Kit product `WatchtowerHostedRelay`;
  - Release sets `WT_APP_ATTEST_ENV: production`;
  - NotifyService and NotifyContent gain no dependency.
- Modify: `WatchtowerMobile/Info.plist`: `WTRelayOrigin` = `$(WATCHTOWER_RELAY_ORIGIN)`.
- Modify: `WatchtowerMobile/WatchtowerMobile.entitlements`: `com.apple.developer.devicecheck.appattest-environment` = `$(WT_APP_ATTEST_ENV)`, with a comment naming the relay's environment check.
- Create: `WatchtowerMobile/Sources/App/RelayConfig.swift`
- Test: Create `WatchtowerMobile/Tests/RelayConfigTests.swift`; `make mobile-gen`

**Interfaces:**
```swift
struct RelayConfig: Equatable, Sendable {
    let origin: RelayOrigin?            // nil = not configured
    static func from(bundle: Bundle) -> RelayConfig
    static func parse(_ raw: String?) -> RelayConfig   // empty, "$(…)" unexpanded, or not https / loopback http → nil
}
```

- `parse` rules:
  - an empty or whitespace value is nil;
  - a value still holding `$(` is nil;
  - otherwise the value goes through `RelayOrigin(_:)`, which trims a trailing `/`;
  - plain `http` is accepted only for loopback or a private LAN address (`10/8`, `172.16/12`, `192.168/16`), for a phone talking to a stand on the developer's Mac. Release builds are checked to carry an empty origin by `testReleaseCarriesNoOrigin` (reads `Base.xcconfig` and `project.yml`).
- An ATS exception for a LAN stand is not committed. Spec §12 p. 2 notes it as a local Debug edit.

- [ ] **Step 1: Failing tests** (`RelayConfigTests`):
  - `testEmptyOrUnexpandedOriginIsNotConfigured`;
  - `testHTTPSOriginIsTrimmedOfItsSlash`;
  - `testPlainHTTPOnlyToLoopbackOrLAN`;
  - `testReleaseCarriesNoOrigin`;
  - `testEntitlementsNameTheAppAttestEnvironmentPerConfiguration` (development in Debug, production in Release, read from `project.yml`, the xcconfig and the entitlements file);
  - `testOnlyTheAppTargetLinksTheRelayProduct` (`project.yml`: NotifyService and NotifyContent list no `WatchtowerHostedRelay`).
- [ ] **Step 2: Run, expect failure:** `make mobile-gen`, then `make mobile-test SIM='iPhone 17 Pro' MOBILE_FILTER=RelayConfigTests`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run:** the Step 2 filter, then `make mobile-build SIM='iPhone 17 Pro'`. The app links the product; the build stays unsigned.
- [ ] **Step 5: Lint and guard check.**
- [ ] **Step 6: Commit:** `build(mobile): relay origin setting, App Attest entitlement, the app links the relay product (#1241)`

### Task 3: One socket per device: `HostedRelaySession`

**Depends on:** none

**Files:**
- Create: `WatchtowerKit/Sources/WatchtowerHostedRelay/Transport/HostedRelaySession.swift`
- Modify:
  - `HostedRelayTransport.swift`: an init taking a session; the old init stays for Phase 2's tests and builds a private session;
  - `HostedRelayTransport+Pull.swift`: socket events come from the session;
  - `HostedRelayEvent.swift`: account-level controls go to the session's stream.
- Test: Create `WatchtowerKit/Tests/WatchtowerHostedRelayTests/HostedRelaySessionTests.swift`

**Interfaces:**
```swift
public actor HostedRelaySession {
    public init(client: HostedRelayClient)
    nonisolated public let client: HostedRelayClient
    /// Account-level relay signals: Control ENTITLEMENT_EXPIRED / SUBSCRIPTION_MOVED / SLOT_REMOVED / PAIRING_OPENED-for-phones-never,
    /// `.entitlementInactive`, `.unsupportedVersion`, `.attestation(…)`, `.reachable(Bool)`. Newest 256 kept.
    nonisolated public let events: AsyncStream<HostedRelayEvent>
    /// Adds `zones` for `owner` to the one connection and routes their `zoneChanged` events to `handler`. Opens the socket on first use.
    func attach(owner: ObjectIdentifier, zones: [String], handler: @escaping @Sendable (HostedRelayConnection.Event) async -> Void) async
    func detach(owner: ObjectIdentifier) async            // last owner gone → socket closed
}
extension HostedRelayTransport {
    public init(session: HostedRelaySession, store: TransportStore, macDeviceID: String, energy: EnergyCounter? = nil, maxAttachmentBytes: Int64 = 100 << 20) throws
}
```

- The session owns the one `HostedRelayConnection` through `client.connect(zones:)` and `setZones(_:)`. The zone set is the union of the attached owners' zones.
- A connection event for a zone goes to the owner of that zone only. A record-less `zoneChanged` after a connect goes to each owner once.
- `stop()` on one transport detaches it. It never closes the socket while another owner is attached.
- A per-transport `.forbidden(zone:)` stays on that transport's `relayEvents`. Account-level events go to `session.events`, and every transport keeps re-emitting `.reachable` for its own consumers.

- [ ] **Step 1: Failing tests** (on `FakeHostedRelay`):
  - `testTwoHubsAndAPairingSlotShareOneSocket` (the fake counts dials per device: one);
  - `testAZoneEventReachesOnlyItsTransport`;
  - `testRemovingATransportKeepsTheOthersSubscribed`;
  - `testTheLastDetachClosesTheSocket`;
  - `testAReconnectResubscribesTheUnion`;
  - `testAccountControlsGoToTheSession`;
  - `testDisplacementNeverLoops` (two transports started together: no 1001 from the fake).
- [ ] **Step 2: Run, expect failure:** `make kit-test FILTER=HostedRelaySessionTests`.
- [ ] **Step 3: Implement.** Phase 2's transport tests keep passing on the old init.
- [ ] **Step 4: Run:** `make kit-test FILTER='HostedRelaySessionTests|HostedRelayTransportTests|HostedRelayConnectionTests|RelaySim'`. All pass.
- [ ] **Step 5: Lint.**
- [ ] **Step 6: Commit:** `feat(kit): one relay socket per device, shared by every hub (#1241)`

### Task 4: Link wire: `LinkPayload` v4, the hello's `relay_device_id`, `DeviceGrant` relay fields, the shared fixture

**Depends on:** none

**Files:**
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Link/LinkPayload.swift`, `DeviceHello.swift`, `DeviceGrant.swift`
- Modify: `WatchtowerKit/Tests/Fixtures/link/hub_contract_cases.json`:
  - a new `device_hello` section, with cases `with_relay_id`, `without_relay_id` and `bad_relay_id`;
  - `link_payload` `v4_desktop` and `v4_headless` get `kit` set to the decoded fields;
  - their `relay_device_id` and `relay_auth_pub` become a coherent pair derived from a fixed test seed;
  - `device_grant` `headless_linked` gets a coherent pair too.
- Modify: `WatchtowerKit/Tests/WatchtowerSyncTests/HubContractFixtureTests.swift`
- Modify (Go, test only): `internal/hub/wire/contract_test.go` (`TestHubContractFixture` reads the `device_hello` section)
- Modify (Desktop, compile only if needed): `WatchtowerDesktop/Sources/ViewModels/MobileLinkSheetViewModel.swift` and the Swift hub's issue site (today's values, R6)
- Test: the files above; `make mobile-gen` is not needed (Kit only)

**Interfaces:**

- `LinkPayload`:
  - `currentVersion` stays `3` (what the Swift hub issues). New `static let newestReadable = 4`.
  - `parse` accepts 3 and 4: `> 4` is `.newerVersion`, `< 3` is `.olderVersion`.
  - In v4, `container` and `ownerUser` are `String?`. They are required in v3 (`missingField` as today).
  - New optional fields:
    - `transport: TransportKind?` (`"cloudkit"`, `"relay"`; an unknown value reads as nil);
    - `transports: [String]?`;
    - `relayDeviceID: String?`;
    - `relayAuthPub: String?`.
  - New computed properties:
    - `offersCloudKit` (v3, or v4 with `container` and `ownerUser` present);
    - `offersRelay` (`relayDeviceID` and `relayAuthPub` present and coherent).
  - New `LinkPayloadError.badRelayIdentity`: `relay_auth_pub` is not base64url of 32 non-zero bytes, or `relay_device_id` ≠ `RelayIDs.deviceID(publicKey:)`.
- `public enum RelayIDs { static func deviceID(publicKey: Data) -> String; static func isValid(_ id: String) -> Bool }` lives in `WatchtowerSync`: it is CryptoKit and base32 only, so the Kit's `WatchtowerSync` stays free of protobuf. `RelayAuthMessages.deviceID` forwards to it, and `RelayAuthVectorTests` pins both.
- `DeviceHello` gains `relayDeviceID: String?`. Its `CodingKey` raw value is `relayDeviceId` (the wire key is `relay_device_id`), and it is absent from the JSON when nil. A decoded id failing `RelayIDs.isValid` is dropped to nil (the Go hub drops such a hello: the phone never sends one).
- `DeviceGrant` gains `transports: [String]?`, `relayDeviceID: String?`, `relayAuthPub: String?` (`relayDeviceId`, `relayAuthPub` keys) and `hubTransports: Set<TransportKind>` (absent means `[.cloudKit]`).

- [ ] **Step 1: Failing tests**
  - `HubContractFixtureTests.testV4LinksDecodeOnThisPhone` replaces `testAV4LinkIsRefusedAsNewerByTodaysPhone` (Owner approval 5). `v4_desktop` decodes with both route sets; `v4_headless` decodes relay-only, with `offersCloudKit == false`.
  - `testV5IsStillNewerAndV2Older`.
  - `testAMismatchedRelayIdentityIsRefused`.
  - `testHelloCasesRoundTrip`: `with_relay_id` encodes byte for byte to the fixture's JSON under `RelayCoder`; `without_relay_id` has no key; `bad_relay_id` decodes to nil.
  - `testDeviceGrantRelayFieldsDecode`, and the existing ignore-unknown cases unchanged.
  - Go `TestHubContractFixture` reads `device_hello`: `with_relay_id` decodes to `wire.DeviceHello{RelayDeviceID: …}`; `bad_relay_id` fails `validRelayDeviceID`, so the Go test checks the format rule the hub's `link` applies, through an exported test helper or a copy of the rule pinned to `link`'s by a test.
- [ ] **Step 2: Run, expect failure:** `make kit-test FILTER='HubContractFixtureTests|LinkPayloadTests|RelayAuthVectorTests'` and `go test ./internal/hub/wire`.
- [ ] **Step 3: Implement.** Re-encode the two v4 URLs from the updated JSON with the Go `wire.LinkPayload.URL()`, so both sides see the same bytes (a one-off `go test -run TestHubContractFixture -update`, if the test has that flag; otherwise by hand with a scratch Go program outside the repo).
- [ ] **Step 4: Run:**
  - the Step 2 commands;
  - `make test-swift FILTER='MobileLink|SeamTypesTests'` (the Desktop still issues v3);
  - `go test ./internal/hub/...`;
  - `make lint-diff`.
- [ ] **Step 5: Lint and guard check.**
- [ ] **Step 6: Commit:** `feat(kit): read LinkPayload v4; the hello carries the phone's relay_device_id (#1242)`

### Task 5: Pairing on the relay in the Kit

**Depends on:** Task 3

**Files:**
- Modify: `WatchtowerKit/Sources/WatchtowerHostedRelay/Transport/HostedRelayTransport.swift`, `HostedRelayZones.swift` (`Mode`)
- Create: `WatchtowerKit/Sources/WatchtowerHostedRelay/Transport/HostedRelayPairing.swift`
- Modify (if the fake lacks a rule): `WatchtowerKit/Sources/WatchtowerHostedRelayTesting/FakeHostedRelay+Accounts.swift`. Covered: the pair zone's 1 MiB cap, `create_upload` `FORBIDDEN` in a pair zone, `PAIRING_EXPIRED` on promote, `SLOT_LIMIT`/`SLOT_REPLACEMENT_LIMIT` on promote and `add_slot`, `ENTITLEMENT_INACTIVE` on `open_pairing`. These follow the Worker's `pairing.ts`/`slots.ts`.
- Test: Create `WatchtowerKit/Tests/WatchtowerHostedRelayTests/HostedRelayPairingTests.swift`

**Interfaces:**
```swift
public enum HostedRelayTransportMode: Equatable, Sendable { case hub; case pairing(slot: String) }
extension HostedRelayTransport {
    /// `.pairing`: `.data` and `.relay` both map to `pair/<slot>`; attachments refused before any request; same store binding (the Mac).
    public init(session: HostedRelaySession, store: TransportStore, macDeviceID: String, mode: HostedRelayTransportMode, …) throws
}
public struct HostedRelayPairing: Sendable {
    public init(session: HostedRelaySession)
    public enum Refusal: Error, Equatable { case notPaying, slotsFull(macs: [String]), replacementLimit, pairingExpired, unreachable, updateRequired, attestationBackoff(until: Date) }
    /// `get_account_state`: paying (active or grace), the Macs in slots.
    public func accountState() async throws -> (paying: Bool, macs: [String])
    /// Refuses `.slotsFull` before any request when 3 Macs hold slots and `mac` is not one of them; else `open_pairing`.
    public func open(mac: String) async throws -> (slot: String, expiresAt: Date)
    public func promote(slot: String) async throws
    public func close(slot: String) async            // best effort, logged
    /// `remove_slot` with Phase 2's `UNAVAILABLE` retry; `NOT_FOUND` counts as done (R14).
    public func removeSlot(mac: String) async throws
    /// Phase 3b: `vouch_hub`. Until relay ask #805 lands the relay has no such op: returns `.notAvailable` without a request.
    public func vouch(hubDeviceID: String, authPub: Data) async -> VouchOutcome   // .notAvailable | .vouched | .refused(code)
}
```

- The 3 in `.slotsFull` is `HostedRelayLimits.maxMacSlots = 3` (relay spec §8). A pairing-mode transport answers `FORBIDDEN` on a data-zone write to the pair zone as the relay does: the phone only writes its hello, which is relay lane.
- Unchanged from Phase 2: cursors are per zone name in `relay_cursors`, so a store used first in pairing mode and then in hub mode keeps one monotonic local buffer (R3).

- [ ] **Step 1: Failing tests:**
  - `testPairingModeMapsBothLanesToThePairZone`;
  - `testAHelloAndAKeyboxRoundTripThroughThePairZone` (a `SimHub`-style MAC device answers in the zone);
  - `testAttachmentsAreRefusedInPairingMode`;
  - `testSlotsFullIsRefusedBeforeOpenPairing`;
  - `testNotPayingIsRefusedByOpenPairing`;
  - `testPromoteAfterExpiryIsPairingExpired`;
  - `testReplacementLimitOnPromote`;
  - `testCloseIsBestEffort`;
  - `testVouchIsNotAvailableAndSendsNothing`;
  - `testOneStoreFromPairingToHubModeKeepsItsBufferTokens`.
- [ ] **Step 2: Run, expect failure:** `make kit-test FILTER=HostedRelayPairingTests`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run:** the Step 2 filter plus `HostedRelayTransportTests|HostedRelaySessionTests`. All pass.
- [ ] **Step 5: Lint.**
- [ ] **Step 6: Commit:** `feat(kit): relay pairing slot — pairing mode, open/promote/close, slot pre-check (#1242)`

### Task 6: The phone's epoch keys: 7-day retention, `epoch_ack`, the rule 14 reseal

**Depends on:** none

**Files:**
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Secure/KeyStore.swift`:
  - `EpochKeys.supersededAt: Date?`, an optional Codable key absent in today's items;
  - `HubLinkKeys.maxEpochs` 2 → 8;
  - `HubLinkKeys.retained(now:)`.
- Modify: `KeychainKeyStore.swift` (trim by `retained(now:)`, then the cap), `InMemoryKeyStore.swift`
- Modify: `WatchtowerMobile/Sources/Features/Onboarding/LinkingViewModel.swift` `mergeKeys(of:into:)`. It stamps `supersededAt` on the previous newest epoch when a newer one merges, and reports `newestEpochRaised`.
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Relay/ActionOutbox+Ordered.swift`:
  - `enqueueEpochAck(epoch:)` through the Phase 1 outbound control queue;
  - `resendFrom` reseals rows whose `epoch` is below the current epoch.
- Modify: `WatchtowerMobile/Sources/App/Hubs/HubSession.swift`: a raised epoch on an ordered hub enqueues `epoch_ack`.
- Test: `WatchtowerKit/Tests/WatchtowerSyncTests/EpochRetentionTests.swift` (create), `ActionOutboxOrderedTests.swift` (extend); `WatchtowerMobile/Tests/OrderedActionsWiringTests.swift` (extend)

**Interfaces:**
- `retained(now:)` keeps:
  - the newest epoch;
  - every epoch whose `supersededAt` is nil (written before this build: stamped `now` on first merge after upgrade);
  - every epoch superseded `< 7 days` ago (`HubLinkKeys.previousEpochGrace = 7 * 86_400`). The owner chose "7 days everywhere" over sim rule 14's 14 days in ask #843 (q2); the protocol spec's Decisions and Go hub Phase 3's Global Constraints record it, and the hub retires an epoch after 7 days, so a phone keeping 14 would hold keys nobody uses. Task 15 replaces "≤ 14 days" in spec §9.

  Then the newest `maxEpochs`. `AlertMaterial` carries the same epochs, so the NSE opens an alert sealed in any retained epoch.
- `epoch_ack{epoch: newest}`:
  - is queued once per raise, only when the hub's grant `runsOrderedActions`;
  - a lower or equal epoch is never queued;
  - a queued, unsent ack for a lower epoch is replaced.
- Rule 14:
  - on `resend_from(m)`, every unsettled row with `action_seq ≥ m` and `epoch < currentEpoch` is resealed. The phone opens its own stored envelope with its `K_relay[p2h, epoch]`, derived from the static link keys (no retained key needed), and seals again under `currentEpoch` with the same `action_seq` and a fresh envelope `seq`;
  - the outbox row's `epoch` and bytes are replaced, and the record is overwritten (`.seq` of its last write, else `.absent`);
  - rows in the current epoch keep Phase 1's byte-for-byte resend;
  - a row that cannot be opened (a corrupt envelope) goes to Not delivered with reason `.refused`.

- [ ] **Step 1: Failing tests:**
  - `EpochRetentionTests`:
    - `testAnEpochIsKeptSevenDaysAfterItWasSuperseded` (6 d 23 h kept, 7 d dropped);
    - `testThreeSwitchesInSevenDaysKeepFourEpochs`;
    - `testAnUnstampedEpochIsStampedNotDropped`;
    - `testTheCapKeepsTheNewest`;
    - `testAlertMaterialFollowsTheRetainedSet`;
    - `testTodaysKeychainJSONStillDecodes`.
  - `ActionOutboxOrderedTests`:
    - `testEpochAckIsQueuedOncePerRaise`;
    - `testEpochAckNeverGoesDown`;
    - `testNoEpochAckToALegacyHub`;
    - `testResendFromResealsOnlyOlderEpochRows`;
    - `testAResealKeepsTheActionSeq`;
    - `testAnUnopenableOldRowIsNotDelivered`.
  - `OrderedActionsWiringTests.testANewerKeyboxSendsEpochAck`.
- [ ] **Step 2: Run, expect failure:** `make kit-test FILTER='EpochRetentionTests|ActionOutboxOrderedTests'` and `make mobile-test SIM='iPhone 17 Pro' MOBILE_FILTER=OrderedActionsWiringTests`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run:**
  - the Step 2 commands;
  - `make kit-test FILTER='KeychainKeyStore|AlertOpener|E2E'`;
  - `make mobile-test SIM='iPhone 17 Pro' MOBILE_FILTER='CachingPhoneKeyStoreTests|KeychainKeyStoreDeviceTests|LinkingViewModelTests'`.
- [ ] **Step 5: Lint and guard check.**
- [ ] **Step 6: Commit:** `feat(kit): epoch keys kept 7 days after a newer one; epoch_ack; rule 14 reseal (#1247)`

### Task 7: `TransportFollowerPolicy` and the switch twins on it

**Depends on:** none

**Files:**
- Create: `WatchtowerKit/Sources/WatchtowerSync/Relay/TransportFollowerPolicy.swift`
- Modify: `WatchtowerKit/Tests/WatchtowerHostedRelayTests/Sim/SimPhone.swift` (its switch handling calls the policy and executes its commands on the sim's legs)
- Test: Create `WatchtowerKit/Tests/WatchtowerSyncTests/TransportFollowerPolicyTests.swift`; `RelaySimSwitchTwins` runs unchanged

**Interfaces:**
```swift
public enum TransportKind: String, Codable, Sendable { case cloudKit = "cloudkit", relay }   // moved here from Task 4's file if it landed first
public struct FollowerState: Equatable, Sendable {
    public var route: TransportKind; public var newestEpoch: UInt32; public var canUseRelay: RelayUse   // enum RelayUse { case yes, no, unknown }
    public var leftTransport: TransportKind?          // a mailbox still to drain (rule 15)
    public var relayUnreachableSince: Date?
}
public enum FollowerInput: Sendable {
    case switched(target: TransportKind, epoch: UInt32, by: String, at: Date, keyboxOpened: Bool, controlID: String, on: TransportKind)
    case marker(target: TransportKind, epoch: UInt32, by: String, at: Date, on: TransportKind)
    case hubOnRelay(controlID: String)
    case relayReachable(Bool, at: Date)
    case oldMailboxDrained(TransportKind)
}
public enum FollowerCommand: Equatable, Sendable {
    case mergeKeybox, moveRoute(to: TransportKind, epoch: UInt32, by: String, at: Date)
    case resendUnechoedOnNewTransport            // rule 13: same bytes, in order, only on the new route
    case sendEpochAck(UInt32)
    case listUnechoedAsUndelivered(reason: UndeliveredReason)   // R32 (.hubOnRelay)
    case drainMailbox(on: TransportKind)          // rule 15: unseen hub records first, then delete the rest
    case pollOtherMailbox(on: TransportKind)      // rule 12: relay unreachable > 60 s
    case markHandled(controlID: String), ignore
}
public enum TransportFollowerPolicy {
    public static let otherMailboxAfter: TimeInterval = 60
    public static let otherMailboxEvery: TimeInterval = 30
    public static func decide(_ input: FollowerInput, state: FollowerState, now: Date) -> (state: FollowerState, commands: [FollowerCommand])
}
```

- A `switched` or `marker` whose epoch is not newer than `newestEpoch` is only marked handled. A second copy of a control is a repeat.
- A `switched` to `.relay` while `canUseRelay == .no` acts as `hubOnRelay`: no route move, and unechoed actions are listed as undelivered. With `.unknown` (and for `hubOnRelay` too) the policy returns no command and no `markHandled`: the record stays and is decided on a later pass.
- A `switched` without an opened keybox (it failed to open) moves nothing and is left unhandled. It is retried on the next pass, and the marker or the new transport's keybox recovers it.
- A `marker` moves the route without merging keys. The keybox is read on the new route's data zone.
- `relayReachable(false)` past 60 s on route `.relay` yields `pollOtherMailbox(.cloudKit)` every 30 s until the relay is reachable again.

- [ ] **Step 1: Failing tests:**
  - `TransportFollowerPolicyTests`:
    - `testASwitchMovesResendsAndAcks` (order of commands: merge, move, resend, ack, drain old, mark);
    - `testAnOlderOrEqualEpochIsOnlyHandled`;
    - `testASecondCopyIsARepeat`;
    - `testSwitchToRelayOnAFreePhoneActsAsHubOnRelay`;
    - `testUnknownPayingDecidesNothingAndKeepsTheControl`;
    - `testHubOnRelayListsUnechoedAsUndelivered`;
    - `testAMarkerNewerThanTheEpochIsFollowed`;
    - `testAMarkerIsNeverFollowedBackwards`;
    - `testAnUnopenedKeyboxMovesNothing`;
    - `testRelayUnreachableSixtySecondsPollsCloudKit`;
    - `testReachableAgainStopsThePoll`.
  - `RelaySimSwitchTwins` (14 tests) and `RelaySimCensusTests` pass with `SimPhone` on the policy.
- [ ] **Step 2: Run, expect failure:** `make kit-test FILTER=TransportFollowerPolicyTests`.
- [ ] **Step 3: Implement** the policy, then switch `SimPhone` onto it.
- [ ] **Step 4: Run:** `make kit-test FILTER='TransportFollowerPolicyTests|RelaySim'`. All pass.
- [ ] **Step 5: Lint.**
- [ ] **Step 6: Commit:** `feat(kit): transport follower policy (sim rules 12–15, R32); the switch twins run on it (#1247)`

### Task 8: Mockups: the Phase 3 phone states

**Depends on:** none (before Tasks 10 and 11)

**Files:**
- Modify: `docs/design/mockups/relay-client/index.html`: a new section "7. iPhone — linking over Relay (Phase 3)", with neutral names only ("Work Mac", "build-box").

**States.** Each state is a phone frame in light and dark, plus a narrow variant (iPhone SE width, largest Dynamic Type) of the longest text:

- **Loading** (unchanged, shown for reference): "Checking…".
- **Busy:** waiting for the code on the Mac. Unchanged copy; the code shows as today.
- **Error with Retry.** Each error has the failure screen's **Scan again** where `offersScan`:
  1. "build-box works over Relay only" / "Relay isn't available on this iPhone". This is the one state a production phone can reach in Phase 3, from a headless host's code.
  2. "Couldn't reach Relay" / "Check your connection and scan again".
  3. **Three Macs in slots.** This is the existing section 6 frame "Add Mac" ("Your subscription already has 3 Macs. Remove one to add this Mac over Relay." / the three Macs with **Remove** / "Up to 5 replacements in 30 days. Or add this Mac over iCloud."), built in Phase 3 rather than redrawn. Task 8 extends that frame with its states instead of adding a new one:
     - a slot whose Mac is not linked on this iPhone reads "A Mac not on this iPhone";
     - **Remove** busy ("Removing…", the other rows disabled), and its error with **Try Again** ("Couldn't remove the Mac. Try again.");
     - after a removal the link goes on with the same code (no new scan while it is valid);
     - no **Link over iCloud**: this screen arises only for a Mac whose current transport is Relay (R4), and such a Mac answers an iCloud link with `hub_on_relay`, so the option would be dead. The footnote reads "Up to 5 replacements in 30 days." only;
     - narrow (iPhone SE width, largest Dynamic Type).
  4. **Replacement limit.** "Too many Mac changes on Relay" / "Try again later", with no **Link over iCloud** (the Mac is on Relay, same reason as state 3). The relay's `Error.message` is not shown: `proto/README.md` says it is "for logs, never for users"; the text is the meaning of `SLOT_REPLACEMENT_LIMIT`.
  5. The existing "This code expired" for an expired pairing slot. No new copy.
  6. **A Mac on Relay, this iPhone can't use Relay.** "Work Mac runs over Relay" / "This iPhone can't use Relay, so it would get no updates from it. Link it when the Mac is back on iCloud." with **Scan again** only.
- **Finishing a promoted link (R5): a row in Settings → Macs, never a blocking screen.** Next to the linked Macs (mockup section 3's list):
  - **busy:** row "build-box" with the sub line "Finishing the link…" and a spinner; no actions while an attempt runs;
  - **error with Retry:** sub line "Couldn't finish the link. Watchtower tries again when it opens." with **Try Again** and **Cancel**;
  - Cancel's confirmation "Cancel the link to build-box? It frees its Relay slot." with **Cancel Link** (red) and **Keep Trying**;
  - the link screen right after promote when the first attempt failed: the existing "Linked to build-box" is not shown; instead the notice "build-box will finish linking in the background. See Settings → Macs." with **OK**, and the scanner is free;
  - narrow (iPhone SE width, largest Dynamic Type) for the error row.
- **Linked, not readable yet:** "Linked to build-box" with the existing **Continue**; the hub's Now shows the existing "Waiting for build-box" status until the first data-zone read succeeds (R5). No new copy.
- **Not delivered, narrow scope:** one row with the new sub line "Work Mac runs over Relay now" (R32), next to Phase 1's rows.
- **Empty:** none is new; the Not delivered list keeps Phase 1's empty pop-back.

A note under the section says:

- the "Relay unavailable" banner, the per-Mac transport row ("switched by … at …") and the "no updates from this Mac" banner stay Phase 4 (R13);
- Phase 3 records who switched and when without showing it.

- [ ] **Step 1:** Edit the mockup, then open it in a browser and check every new frame in light, dark and narrow.
- [ ] **Step 2: Commit:** `docs(design): Phase 3 linking-over-Relay states in the relay-client mockup (#1242)`

### Task 9: Phone routing: availability, the relay transport, one store per route, the link record

**Depends on:** Tasks 1, 2, 3, 4

**Files:**
- Create: `WatchtowerMobile/Sources/App/Hubs/RelayAvailability.swift`
- Modify:
  - `WatchtowerMobile/Sources/App/Hubs/TransportFactory.swift`: `TransportFactory.live(config:)` builds the relay branch and keeps `.cloudKit` for tests;
  - `WatchtowerMobile/Sources/App/Hubs/HubPaths.swift`: `transportStorePath(hubID:route:)`, with `transport.db` for CloudKit (today's name, unchanged) and `transport-relay.db` for the relay;
  - `HubBoot.swift`;
  - `WatchtowerMobile/Sources/App/AppEnvironment.swift`: owns the process's one `HostedRelaySession`, built lazily and only when `RelayAvailability` is not `.off`;
  - `AppRoot.swift`.
- Modify:
  - `WatchtowerMobile/Sources/App/LinkStore.swift`: `LinkRecord` relay fields and `route`;
  - `WatchtowerMobile/Sources/App/Hubs/HubRegistry.swift`: `savePendingFarewell` on a relay route; the one registry migration of this phase, `v3-relay`: `pending_farewells.route_kind TEXT` and `relay_mac_device_id TEXT` (both nullable), and the table `pending_slot_removals (mac_device_id TEXT PRIMARY KEY, since REAL NOT NULL)` that Task 10 uses (ids and a date, no content). The follower's state (Task 11: `transport`, `switchedBy`, `switchedAt`, `leftTransport`) lives in `LinkRecord`'s JSON (`link_json`), not in columns;
  - `WatchtowerMobile/Sources/Features/Onboarding/CloudKitLinkAccess.swift`: `.hostedRelay` join and leave are no-ops; the relay's access is the pairing slot, R19.
- Test: Modify `WatchtowerMobile/Tests/TransportFactoryTests.swift`, `HubRegistryTests.swift`, `HubBootTests.swift`; Create `WatchtowerMobile/Tests/RelayAvailabilityTests.swift`; `make mobile-gen`

**Interfaces:**
```swift
enum RelayAvailability: Equatable, Sendable {
    enum Off: Equatable, Sendable { case notConfigured, unsupportedDevice }
    case off(Off)
    case available(RelayOrigin)
    static func evaluate(config: RelayConfig, attestSupported: Bool) -> RelayAvailability
}
struct LinkRecord {   // additions; all optional, absent in links saved before
    var transport: TransportKind?          // nil = .cloudKit
    var relayMacDeviceID: String?
    var relayAuthPub: String?
    var hubTransports: [String]?
    var switchedBy: String?; var switchedAt: Date?     // recorded for Phase 4's row (R13)
    var leftTransport: TransportKind?      // a mailbox still to drain (Task 12)
    var route: HubRoute { transport == .relay ? .hostedRelay(macDeviceID: relayMacDeviceID!) : today's CloudKit scope }  // a relay transport without a Mac id never saves (precondition in `LinkRecord.init` and decode)
}
```

- `TransportFactory.live(config:)`:
  - `make(.hostedRelay(mac), store, hubID, energy)` builds `HostedRelayTransport(session:store:macDeviceID:mode: .hub)` on the shared session;
  - with `RelayAvailability` `.off`, `make(.hostedRelay…)` throws `UnsupportedRouteError` and never falls back to CloudKit;
  - `sendDirectly` on a relay route saves through the shared client into the mailbox;
  - `wake` stays `CloudKitPushWake`, since relay pushes are Phase 4.
- `KeychainRelayIdentity` and `HostedRelayClient` (`DEVICE_KIND_PHONE`, `RelayAttestor(DeviceCheckAppAttest(), identity)`, `URLSessionRelayHTTP`, `URLSessionRelaySocketDialer`) are built only behind `.available`.

- [ ] **Step 1: Failing tests:**
  - `RelayAvailabilityTests`:
    - `testAttestUnsupportedStaysOnCloudKit`, the relay's `attestUnsupportedStaysOnCloudKit` scenario (R18): `isSupported == false` yields `.off(.unsupportedDevice)`. A v4 code offering both transports routes to CloudKit, and a hub row on `.cloudKit` builds `CloudKitTransport`;
    - `testAnEmptyOriginBuildsNoRelayObject`: factory, session, Keychain and DeviceCheck spies count zero;
    - `testAvailableNeedsBothOriginAndSupport`.
  - `TransportFactoryTests`:
    - `testRelayRouteBuildsAHostedRelayTransportOnTheSharedSession`;
    - `testRelayRouteWhenOffThrowsAndNeverFallsBack`;
    - `testEachRouteHasItsOwnStoreFile`.
  - `HubRegistryTests`:
    - `testALinkSavedBeforeReadsAsCloudKit`;
    - `testARelayLinkRoundTrips`;
    - `testARelayFarewellIsKept`.
  - `HubBootTests.testARelayRowBootsOnItsStore`.
- [ ] **Step 2: Run, expect failure:** `make mobile-gen`, then `make mobile-test SIM='iPhone 17 Pro' MOBILE_FILTER='RelayAvailabilityTests|TransportFactoryTests|HubRegistryTests|HubBootTests'`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run:** the Step 2 filter plus `AppRootWiringTests|MultiHubEnvironmentTests|CloudKitLinkAccessTests`. All pass.
- [ ] **Step 5: Lint and guard check.**
- [ ] **Step 6: Commit:** `feat(mobile): relay routing — availability, the relay transport, one store per route (#1241)`

### Task 10: Linking from the phone over the relay

**Depends on:** Tasks 5, 8, 9 (Task 11 starts only after this task is merged; this task adds no migration, it uses Task 9's `v3-relay` tables)

**Files:**
- Create: `WatchtowerMobile/Sources/Features/Onboarding/LinkRoutePolicy.swift`
- Modify: `WatchtowerMobile/Sources/Features/Onboarding/LinkingViewModel.swift`:
  - `open(_:)`: route decision, and step 2 skipped for a relay route;
  - `connect(…)`: the relay path;
  - `helloRecord`: `relayDeviceID`;
  - `complete(…)`: promote, then the hub route;
  - `endLink`: a relay hub's farewell, then `remove_slot`.
- Create: `WatchtowerMobile/Sources/Features/Onboarding/RelaySlotsModel.swift`, `RelaySlotsView.swift`
- Create: `WatchtowerMobile/Sources/App/Hubs/PromotedLinkResumer.swift`
- Modify: `WatchtowerMobile/Sources/Features/Settings/MacsModel.swift`, `MacsView.swift` (the finishing row; copy in `MacsModel`, tests in `MacsModelTests`)
- Modify: `LinkSeams.swift` (`LinkHost.preparePairing(macDeviceID:slot:hubID:) async throws -> any CloudSyncTransport`), `LinkStore.swift` (`promoted: [String: PromotedLink]`), `LinkFailure.swift` (new cases), `ScanView.swift`/the failure view if layout needs it, `AppRoot.swift` (the `LinkHost` side)
- Modify: `WatchtowerMobile/Sources/App/DemoSeed.swift` and the tour (demo-only failure states reached from the tour)
- Test: Modify `WatchtowerMobile/Tests/LinkingViewModelTests.swift`, `ScreenshotTourTests.swift`, `OrangeToneTests.swift`; Create `WatchtowerMobile/Tests/LinkRoutePolicyTests.swift`, `WatchtowerMobile/Tests/RelaySlotsModelTests.swift`, `WatchtowerMobile/Tests/RelayLinkingTests.swift` (on `FakeHostedRelay` and a test hub that answers in the pair zone); `make mobile-gen`

**Interfaces:**
```swift
enum LinkRoute: Equatable { case cloudKit; case relay(mac: String, authPub: Data); case refuse(LinkFailure) }
enum LinkRoutePolicy {
    /// Pure. `paying` is asked only when the code's hub is on the relay and the relay is available.
    static func decide(_ code: LinkPayload, relay: RelayAvailability, paying: () async -> Result<Bool, HostedRelayPairing.Refusal>) async -> LinkRoute
}
```

**Rules (R4):**

- **v3, or v4 with `transport` absent or `cloudkit`:** `.cloudKit`, as today. The relay identity from a v4 code is kept on the `LinkRecord` for Phase 3b's upgrade.
- **v4 with `transport == relay`:**
  - relay available and paying: `.relay`;
  - relay available and the paying check failed (`accountState()` unreachable, attestation backoff): `.refuse(.relayUnreachable)`, whatever else the code offers. An unknown answer is never read as "not paying", so a paying phone is never sent to iCloud for a hub that then answers `hub_on_relay`;
  - relay `.off`, or a definite `paying == false`: a code that offers CloudKit (a Mac on Relay) → `.refuse(.macOnRelay(macName))`; a relay-only code (a headless host) → `.refuse(.needsRelay(macName))`. Neither links: an iCloud link to a Mac on Relay would only receive `hub_on_relay` (a dead link). This departs from spec §8's third bullet (Owner approval 2);
  - `.updateRequired` from the attestor: `.refuse(.updateApp)`.

**The relay path in `connect`:**

1. **Keys.** The device keys and the hub's link keys are saved as today.
2. **Open.** `HostedRelayPairing.open(mac:)`. A refusal maps to `LinkFailure` and nothing is written.
3. **Prepare.** `host.preparePairing(…)` makes a fresh session on the relay store in pairing mode.
4. **Hello.** The hello is written with `relayDeviceID` = the session client's device id.
5. **Wait.** `waitForGrant` is unchanged: it reads the keybox in the pair zone, and the code check and SAS stay as today.
6. **Keys arrive.** In order:
   - `vouch` (Phase 3a: `.notAvailable`, nothing sent);
   - `promote(slot:)`. A refusal is a failure before promote (point 8);
   - right after a successful promote, in one `UserDefaults` write, the link moves from `store.pending` (the one link the link screen holds) to `store.promoted[hubID]` (`PromotedLink`: the `LinkRecord`, the slot, the Mac's relay id, `promotedAt`) and `store.pending` is cleared. From here the link is committed on the relay's side and no longer belongs to the link screen;
   - one inline attempt: `host.prepare(route: .hostedRelay(mac), fresh: false)` on the same store, then `linked(…)` with `transport = .relay`, which removes `store.promoted[hubID]` and shows "Linked to <Mac>" as today. If it fails, point 9.
7. **Not a reader yet (R5).** Promote puts the hub in the phone's slots, and the Go hub adds the phone to `set_hub_readers` on its next readers sync; the relay sends neither side an event. Until the first data-zone read succeeds, a `FORBIDDEN` on `data/<mac>` is retried by the next pull (the transport's normal backoff) and changes nothing. Phase 3 never infers a removal from `FORBIDDEN`: a removal reaches the phone as today, through the hub's `revoked` keybox (`removedByMac`); a slot lost on the relay's side (`SLOT_REMOVED`, entitlement) is Phase 4's. Now shows the existing "Waiting for <Mac>" status meanwhile. There is no time window to tune.
8. **Failure before promote.** `close(slot:)`, then today's `fail(…)`: the hub's keys, session and directory are removed.
9. **Failure after promote** (`prepare` or `linked` throws, or the app is killed). Rule:
   - **Only the half before promote is bounded by the code's deadline** (open, hello, the wait for the keys, promote). A promoted link never is: it resumes until it succeeds or the owner cancels it.
   - **It resumes in the background, per hub, and never holds the link screen.** `PromotedLinkResumer` (app, one per `store.promoted` entry) retries `prepare` and `linked` with the keys already saved, at every launch, on every foreground, and on **Try Again**, with the transport's backoff between failed attempts; it never writes a second hello and never promotes again. After the inline attempt fails, the link screen shows the notice "<Mac> will finish linking in the background. See Settings → Macs." with **OK** and returns to idle: scanning is free.
   - **Scanning a code for the same hub resumes that promoted link.** `open(_:)` checks `store.promoted[code.hubID]` right after parsing, before the expiry check and before any relay call: it runs one resume attempt (the code itself is not used, so its expiry does not matter) and writes no hello.
   - **Scanning a code for a different hub works normally**, the pre-promote half with its own `store.pending`, as today one at a time.
   - **Settings → Macs shows each promoted link as a row** ("Finishing the link…", or its error with **Try Again** and **Cancel**; Task 8 state). **Cancel** (after "Cancel the link to <Mac>? It frees its Relay slot." → **Cancel Link** / **Keep Trying**) ends the link the relay way: the farewell (the `unlinked` device record, sealed with the keys it holds) into the mailbox, then `remove_slot` (R14), then the hub's keys, session and directory and the `store.promoted` entry are removed. A `remove_slot` that fails is kept in `pending_slot_removals` and retried at launch; nothing is dropped.
   - **Several promoted links at once are fine.** Each resume attaches its hub transport to the one `HostedRelaySession` (R2), so there is still one socket per device; the pairing-mode transport is not used after promote. Each promoted link already holds a relay slot, so `get_account_state`'s slot count (the pre-check before `open_pairing`) includes it; and it counts toward `HubRegistry.limit` (4 Macs on the phone) like a linked row, so a fifth code is refused with today's `.tooManyMacs`.

**`LinkFailure` additions.** The copy lives in the model, from the Task 8 mockup:

| Case | Title | Hint | `offersScan` |
|---|---|---|---|
| `.needsRelay(macName:)` | "\(macName) works over Relay only" | "Relay isn't available on this iPhone" | true |
| `.relayUnreachable` | "Couldn't reach Relay" | "Check your connection and scan again" | true |
| `.relayReplacementLimit` | "Too many Mac changes on Relay" | "Try again later" | true |
| `.macOnRelay(macName:)` | "\(macName) runs over Relay" | "This iPhone can't use Relay, so it would get no updates from it. Link it when the Mac is back on iCloud." | true |

No relay failure offers **Link over iCloud**: every one of them arises only for a Mac whose current transport is Relay (R4), which would answer an iCloud link with `hub_on_relay`. Spec §8's "adding the Mac over iCloud stays possible" holds for a Mac on iCloud, which links over iCloud anyway. The relay's `Error.message` is never shown (`proto/README.md`: "for logs, never for users"). `PAIRING_EXPIRED` maps to `.expired`.

**Three Macs in slots (spec §8, mockup section 6).** Not a failure screen: `HostedRelayPairing.open` refuses `.slotsFull(macs:)` before any hello, and the phone shows the section 6 frame `RelaySlotsView` with `RelaySlotsModel`:

- title "Your subscription already has \(HostedRelayLimits.maxMacSlots) Macs. Remove one to add this Mac over Relay.";
- one row per Mac in slots: its name from the registry (`relayMacDeviceID` match), else "A Mac not on this iPhone"; each with **Remove**;
- footnote "Up to 5 replacements in 30 days.", with no iCloud option (the Mac is on Relay).

**Remove** on a Mac linked on this iPhone runs that Mac's whole unlink (R14: farewell, then `remove_slot`), after the existing unlink confirmation; on a Mac not on this iPhone it calls `remove_slot` only. While it runs the row shows "Removing…" and the others are disabled; a failure shows "Couldn't remove the Mac. Try again." with **Try Again**. After a removal the link goes on with the same code while it is valid (else `.expired`). `SLOT_LIMIT` on promote (a slot taken meanwhile) shows the same screen.

**Unlink of a relay hub (R14):**

1. The farewell (the `unlinked` device record) goes into the mailbox, as today through the hub's transport.
2. Once it has left the queue, or was kept per #143, the phone calls `remove_slot`. Phase 2's `UNAVAILABLE` retry runs within 30 s.
3. A failure is logged and retried at the next launch from a kept `pending_slot_removals` row (created by Task 9's `v3-relay`; a Mac id and a date, no content). The row goes only when the relay answers `Ok` or `NOT_FOUND`.

- [ ] **Step 1: Failing tests:**
  - `LinkRoutePolicyTests` (table-driven, every row above):
    - `testACloudKitCodeLinksOverICloud`;
    - `testARelayMacOnAFreePhoneIsRefusedWithNoDeadOption` (`.macOnRelay`, no iCloud link, no hello written);
    - `testNoRelayFailureOffersLinkOverICloud`;
    - `testARelayOnlyHubOnAFreePhoneNeedsRelay`;
    - `testUnsupportedDeviceNeverAsksTheRelay`;
    - `testUpdateRequiredIsUpdateApp`.
  - `RelayLinkingTests`:
    - `testAPhoneLinksAHubOverAPairingSlot` (hello only in `pair/<slot>`, keys, promote, the row's route `.hostedRelay`, the data zone read);
    - `testTheHelloCarriesThePhonesRelayDeviceID`;
    - `testSlotsFullRefusesBeforeAnyHello`;
    - `testAnExpiredSlotClosesAndAsksForANewCode`;
    - `testAPromoteRefusalClosesTheSlotAndRemovesTheKeys`;
    - `testForbiddenBeforeTheFirstReadIsRetriedAndNeverARemoval`;
    - `testAFailureAfterPromoteResumesWithoutASecondHelloOrPromote`;
    - `testKilledPastTheDeadlineAfterPromoteResumesOnRelaunch` (promote done, app killed, the clock moved past the code's `exp`, relaunch: `prepare` and `linked` succeed in the background, no second hello or promote, the row's route is `.hostedRelay`);
    - `testAPromotedLinkKeepsResumingUntilItSucceeds` (three failing launches, then success);
    - `testAPromotedLinkNeverHoldsTheLinkScreen` (the inline attempt fails: the notice shows, the phase returns to idle, `store.pending` is nil);
    - `testScanningTheSameHubResumesItsPromotedLink` (an expired code of that hub: one resume, no hello, no `open_pairing`);
    - `testScanningAnotherHubLinksNormallyWhileOneIsPromoted` (a second hub links over CloudKit and over the relay; one socket on the fake);
    - `testAPromotedLinkCountsTowardTheFourMacs`;
    - `testCancellingAPromotedLinkSendsTheFarewellThenRemovesTheSlot`;
    - `testTheHalfBeforePromoteIsBoundedByTheCodesDeadline`;
    - `testAnUnknownPayingAnswerIsRelayUnreachableNeverICloud`;
    - `testSlotsFullShowsTheMacsWithRemove`, `testRemovingALinkedMacUnlinksItThenLinksWithTheSameCode`, `testRemovingAnUnknownSlotCallsRemoveSlotOnly`;
    - `testUnlinkingARelayHubSendsTheFarewellThenRemovesTheSlot`;
    - `testASlotRemovalThatFailedIsRetriedAtLaunch`;
    - `testARelayLinkNeedsNoICloudAccount`.
  - `LinkingViewModelTests`: every existing test unchanged, plus `testFailureCopyMatchesTheMockup` for the four new cases and the finishing state's copy and `RelaySlotsModelTests` (create) for the slots screen's copy and states.
  - `OrangeToneTests`: the failure view's `toneUses`.
  - `ScreenshotTourTests`: `link-needs-relay`, `link-relay-unreachable`, `link-relay-replacement-limit`, `relay-slots-full`, `relay-slots-removing`, `relay-slots-remove-error`, `link-mac-on-relay`, `link-finish-in-background`, `macs-finishing-row`, `macs-finishing-row-error`, `macs-finishing-cancel-confirm`, each in light, dark and narrow.
- [ ] **Step 2: Run, expect failure:** `make mobile-gen`, then `make mobile-test SIM='iPhone 17 Pro' MOBILE_FILTER='LinkRoutePolicyTests|RelayLinkingTests|LinkingViewModelTests'`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run:** the Step 2 filter plus `AppRootRelinkTests|WelcomeTests|ScreenshotTourTests|OrangeToneTests|HubRegistryTests`. All pass. Then run `make mobile-shots SIM='iPhone 17 Pro'` and compare the seven shots (light, dark, narrow) with Task 8's frames and section 6's "Add Mac" frame; record any difference in the commit body.
- [ ] **Step 5: Lint and guard check.**
- [ ] **Step 6: Commit:** `feat(mobile): link a hub over a Relay pairing slot; the new link failures (#1242)`

### Task 11: Following a switch on the phone

**Depends on:** Tasks 6, 7, 8, 9, and Task 10 (strictly after it: both edit `AppRoot.swift`, `LinkingViewModel.swift` and `HubSession.swift`; no migration)

**Files:**
- Create: `WatchtowerMobile/Sources/App/Hubs/TransportFollower.swift`, which executes `TransportFollowerPolicy` commands for one hub.
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Relay/RelayFeed.swift`:
  - `transport_switched` and `hub_on_relay` go to a handler set by the session;
  - the control is marked handled and deleted only after the handler returns `handled` (Phase 1 Ruling 9 ends);
  - this runs on the ordered path and on the legacy path (contract point 6a).
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Replica/ReplicaHydrator.swift`: the data-zone kind `transport` (id `marker`) is decoded to `TransportMarker` and passed to a handler, and is still stored.
- Create: `WatchtowerKit/Sources/WatchtowerSync/Relay/TransportMarker.swift`
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Replica/ReplicaStore.swift`: a public `routeChanged()` that resets both sync tokens and records `sweep_after_full_pull`; the next complete data pull deletes slice rows it did not return. The outbox, controls, keys and the alert watermark stay.
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Secure/SecureTransport.swift`: `openKeybox(sealed: Data, deviceID:)` opens a keybox envelope taken from a control, under the wire name `keybox-<DEVICE_ID>`, data lane, signed by `hub_sig` and sealed to `dev_kx`.
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Relay/ActionOutbox+Ordered.swift`:
  - `resendUnechoed(onNewTransport:)` resets every `sent` row to `queued` with `record_seq = nil`, so the next flush writes the same bytes with `.absent` on the new transport (rule 13);
  - `listUnechoedAsUndelivered(reason: .hubOnRelay)`.
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Relay/ActionReason.swift` or the outbox's undelivered reason: add `.hubOnRelay`. Modify `WatchtowerMobile/Sources/Features/Now/NotDeliveredModel.swift`: the sub line "\(macName) runs over Relay now".
- Modify: `WatchtowerMobile/Sources/App/Hubs/HubSession.swift` and `AppRoot.swift`. A route move:
  1. persists the new `LinkRecord.transport`, `switchedBy` and `switchedAt` in one registry write;
  2. stops the old transport and starts the new route's transport on its own store;
  3. calls `routeChanged()`;
  4. keeps the session, replica and outbox.
- Test: Create `WatchtowerMobile/Tests/TransportFollowerWiringTests.swift`, `WatchtowerKit/Tests/WatchtowerSyncTests/TransportMarkerTests.swift`; extend `RelayFeedTests`, `NotDeliveredModelTests`, `ScreenshotTourTests`; `make mobile-gen`

**Interfaces:**
- `TransportFollower(hubID:, policy state from the row, outbox:, host:)`, with `func handle(_ input: FollowerInput) async -> Bool`. It returns `handled`. Its state persists in the registry row's `LinkRecord` JSON: `transport`, `switchedBy`, `switchedAt`, `leftTransport` (Task 9; no new migration).
- `canUseRelay` is `RelayAvailability == .available` and the account is paying, read from `HostedRelayPairing.accountState()` at the switch. It is a three-way value: `.yes`, `.no` (relay `.off`, or the relay answered not paying), `.unknown` (the call failed: unreachable, attestation backoff). On `.unknown` the follower does nothing: the control is not marked handled and stays in the mailbox, the phone stays on its route, no action moves to Not delivered, and the next pass (the feed's normal cadence, at most every 30 s while active) asks again. Only `.no` acts as `hub_on_relay`.
- On CloudKit the phone reads controls sealed `relayToPhone` with its own relay key. Another phone's controls in the shared zone fail to open and are left alone (contract point 2).

- [ ] **Step 1: Failing tests:**
  - `TransportFollowerWiringTests`, on `InMemoryCloudTransport` and `FakeHostedRelay`, with a scripted hub writing sealed controls:
    - `testSwitchedToRelayMovesTheHubAndResendsTheSameBytes`;
    - `testSwitchedToCloudKitMovesBack`;
    - `testTheKeyboxInsideSwitchedIsMergedAndAcked`;
    - `testAMarkerLeadsAReturningPhone` (no control, marker epoch newer);
    - `testAnOlderMarkerIsIgnored`;
    - `testHubOnRelayListsUnechoedAsNotDelivered`;
    - `testSwitchedToRelayOnAFreePhoneActsAsHubOnRelay`;
    - `testAFailedAccountStateKeepsThePhoneOnItsRouteAndRetries`;
    - `testARouteChangeSweepsSlicesTheNewTransportDidNotReturn`;
    - `testTheOutboxAndKeysSurviveARouteChange`;
    - `testALegacyPathPhoneFollowsToo` (a hub without `ordered_actions`);
    - `testAnotherPhonesControlIsLeftAlone`;
    - `testTheMoveIsPersistedBeforeTheControlIsDeleted` (a crash between the two re-reads the control and changes nothing twice).
  - `TransportMarkerTests`: decode, unknown target, missing fields.
  - `RelayFeedTests`: `testSwitchedAndHubOnRelayReachTheHandler` and `testUnhandledSwitchedStaysInTheMailbox`.
  - `NotDeliveredModelTests.testHubOnRelaySubLine`.
  - `ScreenshotTourTests`: `not-delivered-hub-on-relay` in light, dark and narrow.
- [ ] **Step 2: Run, expect failure:** `make kit-test FILTER='TransportMarkerTests|RelayFeedTests'`, then `make mobile-gen`, then `make mobile-test SIM='iPhone 17 Pro' MOBILE_FILTER='TransportFollowerWiringTests|NotDeliveredModelTests'`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run:**
  - the Step 2 commands;
  - `make kit-test FILTER='ActionOutbox|ReplicaHydrator|RelaySim'`;
  - `make mobile-test SIM='iPhone 17 Pro' MOBILE_FILTER='OrderedActionsWiringTests|ReplicaWiringTests|NowWiringTests|ScreenshotTourTests'`;
  - compare `not-delivered-hub-on-relay` with Task 8's frame.
- [ ] **Step 5: Lint and guard check.**
- [ ] **Step 6: Commit:** `feat(mobile): follow the hub's transport switch, marker and hub_on_relay (sim rules 12a, 13, R32) (#1247)`

### Task 12: The other transport's mailbox (rules 12 and 15)

**Depends on:** Task 11

**Files:**
- Create: `WatchtowerMobile/Sources/App/Hubs/SideMailboxReader.swift`
- Modify: `WatchtowerMobile/Sources/App/Hubs/HubSession.swift`, `SessionCadence.swift`
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Relay/RelayFeed.swift`: a controls-only pass over a given transport, plus `drainMailbox`, which reads unseen hub records, handles them, and then deletes everything left in the phone's own mailbox there, its own leftover actions included.
- Test: Create `WatchtowerMobile/Tests/SideMailboxWiringTests.swift`; extend `RelayFeedTests`

**Interfaces:**
- `SideMailboxReader` exists only while the hub has both routes. A relay link from a code without CloudKit has no CloudKit route, so it never polls.
- On route `.relay` with `relayUnreachableSince` older than 60 s, it pulls the CloudKit `RelayZone` every 30 s. It reads controls only, through the same `TransportFollower`, while the app is active.
- After a route move with `leftTransport` set, it drains that mailbox once the old transport is reachable, then clears `leftTransport`. The relay mailbox of a lapsed or forbidden account can still be read and deleted (sim rule 16): a `FORBIDDEN`/`ENTITLEMENT_INACTIVE` on that delete is logged and stops the drain until the next launch.
- It builds its transport through `TransportFactory` on that route's own store, never a second relay socket (it attaches to the shared session).

- [ ] **Step 1: Failing tests:**
  - `SideMailboxWiringTests`:
    - `testRelayDownSixtySecondsReadsTheCloudKitMailbox`;
    - `testASwitchWrittenDuringAnOutageIsFollowed` (`TestSwitchToCloudKitDuringRelayOutage`'s phone half: the second phone is still on the relay before 60 s and on CloudKit after);
    - `testTheOldMailboxIsDrainedOnceReachable` (`TestNoCopiesLeftOnRelayAfterSwitch`'s phone half);
    - `testUnseenHubRecordsAreHandledBeforeTheDrainDeletes`;
    - `testNoPollWithoutACloudKitRoute`;
    - `testThePollUsesTheSharedSocket`.
  - `RelayFeedTests.testDrainDeletesOwnLeftoversAfterHandlingHubRecords`.
- [ ] **Step 2: Run, expect failure:** `make mobile-gen`, then `make mobile-test SIM='iPhone 17 Pro' MOBILE_FILTER=SideMailboxWiringTests`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run:** the Step 2 filter, `make kit-test FILTER='RelayFeedTests|RelaySim'`, and `make mobile-test SIM='iPhone 17 Pro' MOBILE_FILTER='FetchCadenceWiringTests|BackgroundWorkTests'`.
- [ ] **Step 5: Lint and guard check.**
- [ ] **Step 6: Commit:** `feat(mobile): read the other transport's mailbox — outage poll and drain after a switch (sim rules 12, 15) (#1247)`

### Task 13: Kit phone ↔ Go hub interop on the relay's stand

**Depends on:** Tasks 4, 5

**Files:**
- Create (Go, test only): `internal/hub/interop_kit_test.go` (`//go:build interop`), `TestInterop_KitPhone`. It reuses `interop_test.go`'s `startHub`, `next`, `dev` and the wire tap. The handshake runs over files in `-kit-dir`:
  1. the hub writes `pair.url` (the `link.EventQR` URL);
  2. it waits up to 120 s for `pair.sas`;
  3. it confirms over the control socket only when the code equals the hub's `sas.code`;
  4. it writes `confirmed`;
  5. it then waits for `actions.done`, checks `interop_mark` was applied for `action_seq` 1..3 in order and once each, checks the device's `acked_epoch` equals the hub's epoch and that the canary is absent from every tapped stream, and writes `go.ok`, or `go.fail` with the failed check's name;
  6. it waits for `unlinked`, then checks, against the stand: the phone's `device-<DEVICE_ID>` record in its mailbox opens with the hub's opener and carries `unlinked: true` (the Go hub does not act on `device` records yet, protocol §5.5, so the check is that the farewell arrived intact); the hub's `get_account_state` no longer lists the phone in `phones`; writes `unlink.ok`;
  7. it waits for `readded`, checks the hub's `get_account_state` lists the phone again, and writes `go.done`.
- Create: `scripts/relay-interop-kit-hub.sh`. It starts the stand as `relay-interop-kit.sh` does, starts the Go test in its own process group, runs `make kit-test FILTER=GoHubInteropTests` with `WATCHTOWER_RELAY_INTEROP_URL` and `WT_GO_HUB_INTEROP_DIR`, waits for both, and reaps both groups and wrangler on every path. Make target `relay-interop-kit-hub`.
- Create: `WatchtowerKit/Tests/WatchtowerHostedRelayTests/Interop/GoHubInteropTests.swift`. It skips unless both variables are set.
- Test: `scripts/tests/test-relay-interop-kit-hub.sh` (argument and environment refusals, no stand needed)

**Kit test flow** (`testKitPhoneLinksDrivesAndUnlinksTheGoHub`). It uses Kit pieces only, the same ones the phone app uses:

1. Parse the v4 URL.
2. Register a `DEVICE_KIND_PHONE` with `FakeAppAttest` bytes; the stand's attestation is off. Grant the entitlement with `HTTPRelayStandControl`.
3. `HostedRelayPairing.open`, then seal and write the hello with `relayDeviceID` into `pair/<slot>`.
4. Read the awaiting keybox, compute SAS v2, write `pair.sas`, wait for `confirmed`, and read the keys.
5. `promote`.
6. Read the data zone through `HostedRelayTransport` (`.hub`) and `SecureTransport`. Open the `device_grant` and the `heartbeat`, and assert every slice kind the hub published opens (spec §13 E2E (3)).
7. Enqueue three ordered actions through `ActionOutbox` with a canary marker, so the hub's `interop_mark` handler applies them. Read the `applied` echoes and delete them (`expect: .seq`).
8. Merge the grant's keys and send `epoch_ack`.
9. Write `actions.done`, then wait for `go.ok`.
10. **Unlink**, the same steps as the phone's unlink (R14): save the `unlinked` device record (sealed `DevicePayload` with `unlinked: true`) into the mailbox, flush it, then `HostedRelayPairing.removeSlot(mac:)`. Assert the phone's `get_account_state` no longer lists the Mac, write `unlinked`, wait for `unlink.ok`.
11. **The slot is free:** `add_slot` of the same Mac succeeds (and the account still lists at most 3 Macs); write `readded`, wait for `go.done`.

- [ ] **Step 1: Write** the Go test, the Kit test and the script tests. The script refuses a missing relay checkout or a held port.
- [ ] **Step 2: Run:** `bash scripts/tests/test-relay-interop-kit-hub.sh`, and `go vet -tags interop ./internal/hub` (compiles the Go test). Then run `make relay-interop-kit-hub RELAY=<clean relay worktree at 3a99bd7> > "${TMPDIR:-/tmp}/p3-interop-hub.log" 2>&1; echo "exit=$?"`, expecting `exit=0`. Record the run (passed, skipped, failed) in the commit body.
- [ ] **Step 3:** `make lint-diff`, `make lint-swift`, `go test ./internal/hub/...` (interop excluded).
- [ ] **Step 4: Commit:** `test: a Kit phone links, drives and unlinks the Go hub on the relay's stand (#1242)`

### Task 14: The relay CI entry point (spec §12 p. 4)

**Depends on:** Task 13

**Files:**
- Modify:
  - `scripts/relay-interop-kit.sh` and `scripts/relay-interop-kit-hub.sh`: `RELAY_INTEROP_CI=1` makes them non-interactive, prints one summary line `relay-interop: passed=N skipped=M failed=K`, and exits non-zero on any failure or when zero tests ran;
  - each script also accepts `WATCHTOWER_CHECKOUT` (default: the script's repo), so a relay CI job can call it from a relay checkout.
- Modify: `docs/features/relay-client.md` (a "Relay CI job" subsection: the two commands, Node and Xcode needs, macOS runner, the stand's port, what each runs, and that the job itself is the relay session's, ask #734)
- Test: extend `scripts/tests/test-relay-interop-kit-hub.sh` and the Phase 2 script test for the CI mode's refusals and summary line

- [ ] **Step 1:** Failing script tests: `RELAY_INTEROP_CI=1` with zero tests run exits 1, and the summary line format is pinned.
- [ ] **Step 2:** Implement, then run the script tests.
- [ ] **Step 3: Commit:** `build: CI mode for the Kit relay interop scripts (#1242)`
- [ ] **Step 4: Hand-off:** file a note on board #1242 (and the relay session's ask, linked from the PR body) naming the two commands for the relay job. The job is E6.

### Task 15: User guide, feature notes, spec text

**Depends on:** Tasks 10, 11, 12, 13, 14

**Files:**
- Modify: `docs/guide/features/iphone.md`. Add one bullet under **When it's empty or wrong**: **"<hub> works over Relay only"**. That hub (a Linux box or a Mac without the Watchtower app) links only over Relay, which this version of Watchtower for iPhone doesn't offer; link it from the Mac app instead if it has one. The bullet follows `docs/guide/WRITING.md`: bold for UI text, no internals. There is no Learn card: nothing new to learn until Phase 4.
- Modify: `docs/features/relay-client.md`:
  - a Phase 3 section: identity and Keychain items (R1 of Phase 3), origin and entitlement, `RelayAvailability`, the shared session (R2), pairing mode and `HostedRelayPairing`, the link route rule (R4), the follower, the side reader, epochs (R8–R10), the interop and CI entry point;
  - v1 limits updated: `testAttestUnsupportedStaysOnCloudKit` done; the dark ship; no vouch; no pushes, so a backgrounded app on the relay waits for the foreground; the promote residual (R5); the stalled-resync limit kept until Task 17.
- Modify: `docs/features/mobile-companion.md`: linking (v4 codes, the relay pairing slot, the hello's `relay_device_id`), epochs (7-day retention, `epoch_ack`), the transport per hub and the follower (cite the protocol spec §7.6), and the per-route transport store file.
- Modify: `CLAUDE.md` (the relay-client feature line names Phase 3a)
- Modify: `docs/superpowers/specs/2026-10-29-relay-client-design.md`:
  - §4: the origin's default is empty until §12 p. 5;
  - §9: 7-day retention per ask #843, replacing "≤ 14 days";
  - §13: row 3 split into 3a and 3b, each with its blockers;
  - Decisions: one line per Owner approval item.

  These are text only; the owner approves them with this plan.
- Modify: `docs/superpowers/specs/2026-10-31-hub-phone-protocol-design.md` §5.1, §5.2, §11: the Kit reads v4, and the hello field and its fixture case exist.

- [ ] **Step 1: Edit.** Keep `iphone.md` under the 8 KB rule's spirit: one bullet only.
- [ ] **Step 2: Run:** `go test ./docs/guide`, which passes, and `bash scripts/leak-check.sh` over the branch's commits, which finds nothing.
- [ ] **Step 3: Commit:** `docs: relay client Phase 3a — guide line, feature notes, spec text (#1241, #1242, #1247)`

### Task 16: Phase 3a gate

**Depends on:** Tasks 1–15

- [ ] **Step 1: Kit and Desktop:** `make test-swift > "${TMPDIR:-/tmp}/p3-swift.log" 2>&1; echo "exit=$?"`. Expect `exit=0`; interop classes skip.
- [ ] **Step 2: Phone:** `make mobile-build SIM='iPhone 17 Pro'`, then `make mobile-test SIM='iPhone 17 Pro' > "${TMPDIR:-/tmp}/p3-mobile.log" 2>&1; echo "exit=$?"`. Expect `exit=0`.
- [ ] **Step 3: iOS build of the relay targets:** `cd WatchtowerKit && xcodebuild build -scheme WatchtowerHostedRelay -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO > "${TMPDIR:-/tmp}/p3-ios.log" 2>&1; echo "exit=$?"`. Expect `exit=0`.
- [ ] **Step 4: Go:** `make test > "${TMPDIR:-/tmp}/p3-go.log" 2>&1; echo "exit=$?"`. Expect `exit=0`.
- [ ] **Step 5: Lint:** `make lint-all`, with no new issues; the script tests pass.
- [ ] **Step 6: Boundaries:**
  - the guard-file diff is empty;
  - `git diff --stat origin/main -- WatchtowerMobile/NotifyService WatchtowerMobile/NotifyContent` is empty;
  - `grep -rn 'WatchtowerHostedRelay\|SwiftProtobuf' WatchtowerDesktop/Package.swift` prints nothing;
  - `grep -rn 'workers.dev\|relay-staging' -- . ':!*.lock'` finds no URL in tracked files outside the relay docs' placeholders.
- [ ] **Step 7: Interop:** `make relay-interop-kit RELAY=<clean relay worktree at the VERSION commit>` and `make relay-interop-kit-hub RELAY=…`, both `exit=0`. These run locally; record them in the PR description.
- [ ] **Step 8: Shots:** `make mobile-shots SIM='iPhone 17 Pro'`. Compare the Phase 3 shots (Tasks 10 and 11) with the Task 8 mockup and section 6 in light, dark and narrow; list the differences in the PR description.
- [ ] **Step 9: No manual device check.** The owner ruled that relay-client phases merge without a check on a live phone (ask #884); spec §11's "one manual device check per phase" is read with that ruling. What such a check would have shown is covered automatically: the link, ordered actions and unlink by Step 7's stand interop against the real Go hub; "no relay object without an origin" by Task 9's `testAnEmptyOriginBuildsNoRelayObject`; the Release origin and entitlement by Task 2's `testReleaseCarriesNoOrigin` and `testEntitlementsNameTheAppAttestEnvironmentPerConfiguration`. A real App Attest attestation cannot run in CI or on the stand (attestation off); it is first exercised on staging, a v1 limit in the feature note.
- [ ] **Step 10: Commit:** gate fixes, if any: `fix: relay client Phase 3a gate (#1241, #1242, #1247)`

---

## Phase 3b — blocked tasks

**Draft, not approved with this plan.** Each task is an outline of what the dependency unlocks, so the 3a work leaves room for it. Op, field and error names are working names (relay ask #805 is not started). When a task's dependency lands, it is re-planned against the shipped relay commit and the Go hub code, and that plan goes to the owner for approval on its own. Task 17 is the exception: its dependency (relay PR #3) is written, so its text is final and its approval is item 10 below.

### Task 17: Move the proto pin to relay PR #3 and set `Changes.resync` (after relay PR #3 merges)

**Depends on:** E5 (relay PR #3, `fix/changes-resync` `5d8b577`, merged into relay `main`; board #1430); Task 3

**Files:**
- Regenerate: `WatchtowerKit/Sources/WatchtowerRelayProto/{relay.proto,relay.pb.swift,VERSION}` with `make relay-proto RELAY=<clean relay worktree> REF=<merge commit>`, committed alone first.
- Modify: `WatchtowerKit/Sources/WatchtowerHostedRelay/Transport/HostedRelayTransport+Pull.swift`. Every page of a resync from 0 sends `resync = true`, and an incremental pull never does. The stall hold (`resyncStallHold`) stays only for a `TOKEN_EXPIRED` on a resync page with the flag set, which the README still allows for a `since_seq` above the zone's seq.
- Modify: `WatchtowerKit/Sources/WatchtowerHostedRelayTesting/FakeHostedRelay+Zones.swift` (the flag skips only the floor check)
- Modify: `docs/features/relay-client.md` (v1 limit "Resync below the tombstone floor" removed; the pin line)
- Test: `HostedRelayTransportTests`:
  - `testAResyncSetsTheFlagOnEveryPage`;
  - `testAnIncrementalPullNeverSetsIt`;
  - `testAResyncBelowTheFloorFinishesAndDeletesWhatItDidNotReturn`;
  - `RelayProtoPinTests` passes on the new `VERSION`.

- [ ] **Step 1:** Run the failing tests, then regenerate, then implement.
- [ ] **Step 2:** `make kit-test FILTER='HostedRelayTransportTests|RelayProtoPinTests|RelaySim'`, then `make relay-interop-kit RELAY=<worktree at the new pin>`.
- [ ] **Step 3:** `make relay-go` is the Go hub session's choice (R14 of Phase 2: the pins are not forced equal). Note both pins in the PR body.
- [ ] **Step 4: Commit:** `build(kit): relay proto at <commit>; full resyncs set Changes.resync (#1430)`

### Task 18: `vouch_hub` on a new link (blocked on relay ask #805)

**Depends on:** E2 (relay `vouch_hub`, `DEVICE_KIND_HUB`, `HUB_NOT_VOUCHED` and the vouch digest bytes, in relay `main`); a Kit proto pin at that commit (Task 17's procedure); Task 10. E3 for its interop half.

**Files:**
- `HostedRelayPairing.swift`: `vouch` sends the op with `RelayAttestor`'s assertion over the relay's vouch digest. The bytes are copied from the relay README, and a Go-generated vector extends `RelayAuthVectorTests`.
- `FakeHostedRelay+Accounts.swift`: the vouch model and an unvouched hub.
- `LinkingViewModel.swift`: vouch after the keys, before promote. A refusal (`ATTESTATION_*`, slot limit) closes the slot and shows the server's reason as `LinkFailure.vouchRefused(code)`, with mockup copy added to Task 8's section in this task.
- `GoHubInteropTests`: `testVouchedHubLinksAndPublishes` against Go hub Phase 2 Task 10.

**Tests:**

- `testVouchCarriesTheAssertionOverTheVouchDigest`;
- `testAVouchRefusalKeepsTheHubOffTheRelay` (table: `ATTESTATION_REQUIRED`, `ATTESTATION_FAILED`, `SLOT_LIMIT`);
- `testNoPromoteWithoutAVouch`;
- the Go hub Phase 2 Task 12 vouch tests, which run on our script (Owner approval 9).

**Commit:** `feat: the phone vouches for the hub before promote (#1242)`

### Task 19: Upgrade an existing CloudKit link to the relay (blocked on relay ask #805 and Go hub Phase 3)

**Depends on:** Task 18; E4 (a Mac on the Go hub publishes `relay_device_id` and `relay_auth_pub` in `device_grant`: Go hub Phase 3 Tasks 12 and 21)

**Model-level only.** The trigger (subscribing, the per-Mac transport choice) is Phase 4's screen. This task adds `HubSession.upgradeToRelay()`:

1. read the hub's relay identity from the linked grant, which must be coherent (`RelayIDs`);
2. `vouch`;
3. `add_slot`;
4. store the identity on the `LinkRecord`;
5. send `transport_switch(relay)`, rule 9's initiator write on both transports wherever reachable, through the Phase 1 control queue;
6. the phone stays on CloudKit until `transport_switched` (Task 11) or `transport_switch_rejected(too_soon, retry_after_s)`, whose `retry_after_s` is kept for Phase 4's "available in N min".

**Tests** (twins of the initiator half, on the fake and `InMemoryCloudTransport`):

- `testUpgradeVouchesAddsTheSlotAndAsksForTheSwitch`;
- `testTheInitiatorStaysUntilSwitchedOrRejected`;
- `testTooSoonKeepsRetryAfter`;
- `testAGrantWithoutRelayIdentityCannotUpgrade`.

**Commit:** `feat: upgrade a CloudKit link to the relay — vouch, add_slot, transport_switch (#1247)`

### Task 20: The switch end to end with the Go hub (blocked on Go hub Phase 3 Tasks 18 and 20)

**Depends on:** Task 19; E4 (Go hub Phase 3 Tasks 18 and 20 on `main`; the Mac's CloudKit leg through `bridgefake` in the Go interop)

**Files:** `internal/hub/interop_kit_test.go` gains `TestInterop_KitPhoneFollowsASwitch`; `GoHubInteropTests` gains `testKitPhoneFollowsBothWays`.

**What it checks:**

- the Go hub switches toward the relay and back;
- the Kit phone follows `transport_switched` (keybox inside, `epoch_ack`), reads the marker after missing a control, and resends unechoed actions with the same bytes;
- nothing is applied twice;
- the old mailbox is empty after the drain;
- a `resend_from` for a retired epoch is resealed under the same `action_seq` (`TestAPhoneOfflineOver7DaysAcrossASwitchRecovers`'s phone half);
- a free Kit phone gets `hub_on_relay`, and its unechoed actions are listed.

This also closes Go hub Phase 3 Task 27's interop step for the Kit phone.

**Commit:** `test: the Kit phone follows the Go hub's switch both ways (#1247)`

### Task 21: Phase 3b gate (blocked on E2, E3, E4)

**Depends on:** Tasks 17–20

1. Rerun Task 16's suites.
2. Run `make relay-interop-kit-hub` with vouching.
3. No manual device check (ask #884). A run against staging with attestation on is done only if the owner asks for one; otherwise real attestation stays a v1 limit until Phase 4.
4. Update `docs/features/relay-client.md`'s v1 limits.

**Commit:** `fix: relay client Phase 3b gate (#1241, #1242, #1247)`

---

## Rulings

Decisions taken where the spec is silent, outdated, or contradicts the code or the Go hub. Each: what, why, cost if wrong.

- **R1. Phase 3a ships dark; the origin defaults to empty.**
  - Why: spec §4 says the origin defaults to the production one, but no production origin exists yet (E7), and the relay requires a paying account for `open_pairing` and `add_slot` (Worker `pairing.ts`, `slots.ts`), which no phone can have before Phase 4's StoreKit. An empty origin makes `RelayAvailability` `.off(.notConfigured)`, so a Release build builds nothing relay-shaped. Debug builds set a stand or staging origin in the gitignored `Signing.xcconfig`.
  - Cost if wrong: Phase 4 sets the Release origin in one xcconfig line.
- **R2. One `HostedRelaySession` per process.**
  - Why: Phase 2's transport opens its own socket per Mac. The relay displaces an older socket of the same device (close 1001), so two relay hubs, or a hub plus a pairing slot, would displace each other in a loop. The session owns the one connection and routes events by zone; transports attach and detach.
  - Cost if wrong: none for one hub; for several hubs this is required.
- **R3. Pairing is a mode of `HostedRelayTransport` on the hub's own store.**
  - Why: in pairing mode both lanes map to `pair/<slot>`. The hello is relay-lane and the keybox data-lane, as on CloudKit, so `SecureTransport`, the replica's keybox read and `waitForGrant` work unchanged. After promote, the same store serves hub mode; cursors are per zone name, so the local buffer tokens stay monotonic. Owner approval 6 of Phase 2 put the `pair/<slot>` mapping here.
  - Cost if wrong: a separate pairing reader, one file.
- **R4. A code links over the hub's current transport.**
  - Why: a hub uses one transport at a time (protocol §3.1), so a phone pairing over the relay with a Mac that is on CloudKit could never read it.
  - The rule:
    - `transport == relay` and a paying phone with the relay available → relay;
    - a hub on the relay that also offers CloudKit, to a phone that cannot use the relay → refused with "<Mac> runs over Relay" and no option that would link it dead (spec §8's third bullet linked it over iCloud only to receive `hub_on_relay`; Owner approval 2);
    - a relay-only hub → refused with "works over Relay only";
    - everything else → iCloud, as today.

    A relay identity in a CloudKit code is kept for Phase 3b's upgrade.
  - Cost if wrong: one function (`LinkRoutePolicy`).
- **R5. Promote comes only after the keys; slots are checked first.**
  - Why: spec §8 orders vouch and promote after the owner's confirmation. `promote_pairing` can still be refused after the Mac linked the phone (`PAIRING_EXPIRED` past 600 s, `SLOT_REPLACEMENT_LIMIT`). The slot count is checked before `open_pairing` from `get_account_state`, so the common refusal never reaches the Mac. Until the first data-zone read succeeds, `FORBIDDEN` is "not a reader yet" and is retried on the transport's backoff with no time window: the Go hub syncs readers after a link with no relay event, as `interop_test.go`'s `eventually` shows. Phase 3 never infers a removal from `FORBIDDEN` at all (removals come through the hub's `revoked` keybox, as today). After a successful promote the link moves out of the link screen into `store.promoted[hubID]` and resumes in the background, per hub, at every launch and foreground, with no time limit, until it succeeds or the owner cancels it from its Settings → Macs row; Cancel ends the link with the farewell and `remove_slot` (R14). It never blocks scanning: a code of the same hub resumes it without a hello, a code of another hub links normally. Only the half before promote is bounded by the code's deadline. Several promoted links share the one socket (R2), each holds its relay slot and counts toward the 4 Macs.
  - Cost if wrong: a refused promote leaves a linked phone on the Mac that never reads. The owner removes it with **Remove…** (v1 limit). A Go hub that is slow to sync readers keeps the phone on "Waiting for <Mac>" longer, never unlinked.
- **R6. The Kit reads v3 and v4 and still issues v3.**
  - Why: the Swift hub issues v3 until the Go hub replaces it (Go hub Phase 3 Task 24). `container` and `owner_user` are optional only in v4. A v4 code's `relay_device_id` must equal the base32 SHA-256 of its `relay_auth_pub`: the phone vouches for that key and opens a slot for that id, and a mismatch would admit or address the wrong device.
  - Cost if wrong: a Go hub with a mismatched pair cannot be linked. The fixture now pins a coherent pair, and the Go hub derives both from one key (`HeadlessHost`).
- **R7. The hello's new key goes through the shared fixture, read on both sides.**
  - Why: Go hub spec §12a and protocol open point 10 ask for a hello case. Phase 1 Ruling 11 left Go reading new sections to the Go session; this case is small and pins a field the Go hub already reads, so Task 4 adds the Go test-only reader.
  - Cost if wrong: one Go test file.
- **R8. Epoch keys are kept 7 days after a newer epoch arrived, at most 8.**
  - Why: ask #843 replaced sim rule 14's 14 days with 7 for every rotation. Go hub Phase 3 contract point 3 asks the phone to keep every epoch's keys for at least 7 days; switches and unlinks can stack several epochs in a week. Time-based retention with `supersededAt` meets that; the cap of 8 only bounds a pathological rotation spree. Items written before this build have no stamp and are stamped at the first merge, never dropped.
  - Cost if wrong: a few more 32-byte keys in the Keychain.
- **R9. `epoch_ack` goes out on every raise of the newest epoch, to an ordered hub only.**
  - Why: Phase 1 Ruling 15 deferred it to here, and the Go hub already records it (`00004_epoch_ack.sql`). A legacy hub cannot read controls (spec §5 p. 10).
  - Cost if wrong: none; the hub never retires an epoch early on a missing ack.
- **R10. The rule 14 reseal opens the phone's own envelope with a derived key.**
  - Why: `K_relay[dir, e]` is derived from the static link keys and the epoch (protocol §4.2), so the phone can always reopen its own action. No plaintext is stored, which keeps Phase 1's "no plaintext at rest". Only rows sealed in an older epoch than the current one are resealed on `resend_from`, so a plain gap resend stays byte for byte.
  - Cost if wrong: an older-epoch row resent with its old bytes to a hub that dropped that epoch would loop on `resend_from`; the reseal ends that.
- **R11. The follower's decisions are one pure function, shared with the sim twins.**
  - Why: `TransportFollowerPolicy` is pure and lives in `WatchtowerSync`. `SimPhone` executes its commands on the sim's legs, so Phase 2's 14 switch twins pin the production decision logic (Phase 2 R12 foresaw this). The app's `TransportFollower` executes the same commands on real sessions.
  - Cost if wrong: the twins would test a copy of the logic.
- **R12. A route change uses that route's own store and re-reads the data zone.**
  - Why: Phase 2 binds a `TransportStore` to one route (Owner approval 10 there). On a move the replica's two sync tokens reset (`routeChanged()`), the first complete data pull of the new route is the hub's whole republished window, and slice rows it did not return are deleted. The outbox, controls, keys and the alert watermark stay.
  - Cost if wrong: a brief re-read on each switch; a switch is a rare, person-made event.
- **R13. Phase 3 adds no switch screen.**
  - What: the switch line ("switched by … at …"), the "Relay unavailable" banner, the "no updates from this Mac" banner and the per-Mac transport choice are Phase 4 screens (spec §10, §13 row 4).
  - What Phase 3 adds instead: it records `switchedBy` and `switchedAt` on the registry row, and shows `hub_on_relay` only as Not delivered rows with their sub line (R32). The phone's own `transport_switch` request (rule 9) arrives with that choice: Task 19 builds its model half.
  - Cost if wrong: before Phase 4 a developer sees a switch only in logs and the registry. No production phone can be switched before Phase 4 (R1).
- **R14. Unlinking a relay hub frees its slot.**
  - Why: the farewell goes first, through the hub's mailbox while the phone can still write it, then `remove_slot` is called. A failed removal is kept and retried at launch. Without this the slot leaks and the subscription fills (3 slots). The relay counts a later add after a removal as a replacement (5 per 30 days); that is the relay's rule.
  - Cost if wrong: a slot the owner frees later in Phase 4's slots screen.
- **R15. The Kit ↔ Go hub interop is Kit-level and needs no vouch.**
  - Why: the app's link flow is covered by phone tests on the fake. The interop proves wire compatibility with the real Go hub (test mode, `WATCHTOWER_HUB_DIR`) on the real stand, which has attestation off, so the Go hub registers as a MAC device (`transport/relay/transport.go`). It takes over the non-vouch part of Go hub Phase 2 Task 12; the vouch part stays there and runs through our script (Task 18).
  - Cost if wrong: a second harness if the Go hub session prefers its own.
- **R16. The relay CI job is the relay session's; Phase 3a provides its entry point.**
  - Why: spec §12 p. 4 lists the job under what we need from the relay repository (ask #734). Task 14 gives it two non-interactive commands with a summary line.
  - Cost if wrong: none for this repository.
- **R17. The proto pin moves only after relay PR #3 merges.**
  - Why: pinning an unmerged branch would make the Kit speak a proto that `main` might never have. Until then, Phase 2's v1 limit (a resync below the tombstone floor stalls for 1 h, deleting nothing) stays.
  - Cost: that limit stays until E5.
- **R18. `testAttestUnsupportedStaysOnCloudKit` lives in `WatchtowerMobile/Tests/RelayAvailabilityTests.swift`.**
  - Why: Phase 2 R16 promised it in `WatchtowerMobile/Tests`. It asserts the routing half: `isSupported == false` → no relay, CloudKit transport.
  - Cost: none.
- **R19. A relay link does not depend on iCloud.**
  - Why: the relay needs no Apple ID. A relay-only link skips the iCloud step, and `accountChanged` ends CloudKit-route links only. A relay link to a hub that also offers CloudKit runs the CloudKit step at link time as today when iCloud is available, so a later switch to iCloud or an entitlement fallback has a scope. Without iCloud it links over the relay with no CloudKit route, so no fallback exists until a re-link.
  - Cost: a relay-only phone without iCloud cannot fall back; that is stated in the v1 limits.
- **R20. The notification extensions link nothing new.**
  - Why: ask alerts over the relay arrive inline with Phase 4's pushes (spec §10). The NSE reads the alert material, which now carries every retained epoch (R8).
  - Cost: none.

## Owner approval

These contract and behaviour changes are not approved yet. Approving this plan's review ask approves them; a refused item changes what its line names.

1. **Split and dark ship (R1, External dependencies).** Phase 3 splits into 3a, shippable now, and 3b, blocked on relay ask #805 and Go hub Phase 3. 3a ships with no Release relay origin, against spec §4's "default the production origin", until §12 p. 5. What still runs in a Release build is listed in full under Global Constraints, "Dark ship" (v4 codes, epoch retention and `epoch_ack`, the rule 14 reseal, the follower on CloudKit that finds nothing until a Go hub can switch, one registry migration). The deviation from spec §4 is the author's: no production origin exists (E7), and the relay refuses pairing to a phone that cannot pay before Phase 4. Refused → Phase 3 waits for E2 and E4 as one phase, and the origin needs a value that does not exist yet.
2. **The link route rule (R4).** A v4 code links over the hub's current transport. A phone that cannot use Relay is refused for a Mac on Relay with "<Mac> runs over Relay / This iPhone can't use Relay, so it would get no updates from it. Link it when the Mac is back on iCloud.", instead of spec §8's iCloud link that only receives `hub_on_relay`; no relay failure offers **Link over iCloud**, because each arises only for a Mac on Relay; a relay-only hub is refused with "<hub> works over Relay only / Relay isn't available on this iPhone". This copy reaches production phones from headless-host codes. Also: a failed paying check refuses with "Couldn't reach Relay" instead of falling back to iCloud; three Macs in slots shows mockup section 6's "Add Mac" screen with **Remove** (unlinks a Mac on this iPhone, or only frees an unknown slot) and without its "Or add this Mac over iCloud"; the replacement limit shows its own text, not the relay's message (`proto/README.md`: messages are for logs). Refused → a Mac on Relay links over iCloud as spec §8 says and the phone shows `hub_on_relay`'s Not delivered lines; `LinkRoutePolicy`, the slots screen and the Task 8 copy change.
3. **Pairing order and its residual (R5).** The slot pre-check comes before `open_pairing`, and promote only after the keys. A promote refused after the Mac confirmed leaves a linked phone on the Mac for the owner to remove. After a successful promote the link resumes in the background, per hub, at every launch and foreground with no time limit, until it succeeds or the owner cancels it; it never holds the link screen. It shows as a Settings → Macs row ("Finishing the link…", or "Couldn't finish the link. Watchtower tries again when it opens." with **Try Again** and **Cancel**), and the link screen says "<Mac> will finish linking in the background. See Settings → Macs." A code of the same hub resumes it with no new hello; a code of another hub links normally; a promoted link counts toward the 4 Macs and holds its relay slot. Cancel sends the farewell and calls `remove_slot`. Only the half before promote is bounded by the code's deadline. Refused → the link screen waits on a promoted link until it finishes or is cancelled. `FORBIDDEN` is never read as a removal in Phase 3. Refused → promote before the hello (against spec §8's order) or a farewell path through the hub; both are new contracts.
4. **Epoch keys (R8–R10).**
   - Retention: 7 days after a newer epoch arrived, at most 8 epochs (`HubLinkKeys.maxEpochs` 2 → 8); the NSE's alert material follows.
   - `epoch_ack` to ordered hubs.
   - On `resend_from`, rows sealed in an older epoch are resealed with the same `action_seq`. This is sim rule 14 as written ("the phone reseals every outbox action from that seq that is older than its current epoch, with the same seq"), which spec §9 adopts ("implemented exactly as sim rules 8–16") and the protocol spec's Decisions confirm (ask #843). What needs approval is only that it amends Phase 1's "resends are byte for byte" for those rows; rule 13's switch resend stays byte for byte.

   Refused → Task 6 changes; a count-only cap cannot promise 7 days.
5. **Shared fixture and contract tests (R6, R7).**
   - `hub_contract_cases.json` gains `device_hello`.
   - The v4 cases' Kit expectation flips from `newer_version` to decoded.
   - Their relay ids become a coherent, derived pair.
   - `HubContractFixtureTests.testAV4LinkIsRefusedAsNewerByTodaysPhone` is replaced by `testV4LinksDecodeOnThisPhone`.
   - The phone refuses a code whose relay id does not match its key.
   - The Go fixture test reads the hello section.

   Refused → the phone cannot link a Go hub at all (protocol §11 p. 1).
6. **Following a switch (R11–R13).**
   - On `transport_switched` or a newer marker, the phone moves the hub to the new route on that route's store, re-reads the data zone, sweeps slices the new transport did not return, and resends unechoed actions there.
   - On `hub_on_relay` it lists unechoed actions as Not delivered, with the sub line "<Mac> runs over Relay now".
   - No switch screen comes until Phase 4. Phase 1 Ruling 9 (switch controls left in the mailbox) ends.

   Refused → Tasks 11–12 change.
7. **Unlink frees the relay slot (R14).** Unlinking a relay hub calls `remove_slot` after the farewell; a later add of another Mac counts toward the relay's 5 replacements per 30 days (the relay's rule, Worker `slots.ts`). The guide's unlink line says so when the relay ships to users (Phase 4). Refused → slots stay until Phase 4's slot screen, and three linked-then-unlinked Macs fill the subscription.
8. **Relay links without iCloud (R19).** A relay-only link needs no Apple ID, and an iCloud account change does not end relay links. Refused → step 2 stays for every link.
9. **Cross-plan interop ownership (R15).** This plan's Task 13 adds `internal/hub/interop_kit_test.go` (Go, test only, `-tags interop`) and `scripts/relay-interop-kit-hub.sh`. It takes over the non-vouch half of Go hub Phase 2 Task 12, whose vouch half runs on this script. Refused → Task 13 shrinks to a Kit test against the Go phone emulator's expectations, and Go hub Phase 2 Task 12 keeps the whole interop.
10. **Task 17 (proto pin to relay PR #3, `Changes.resync`)** runs as soon as PR #3 merges, without a new plan review. Refused → Task 17 is re-planned after the merge. Tasks 18–21 are drafts and are not approved here; each is re-planned and approved when its dependency lands.

Already approved, listed for reference only:

- the Keychain key id next to `relay_auth` with `AfterFirstUnlockThisDeviceOnly`, and the App Attest entitlement per configuration (ask #854, ask #799);
- the routing test's name and place (Phase 2 R16, ask #854);
- the `pair/<slot>` zone in Phase 3 (Phase 2 Owner approval 6, ask #854);
- 7-day retention for every rotation (ask #843; R8 only applies it on the phone and sets the cap).
