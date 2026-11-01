# Relay client Phase 3 — phone identity, linking over the relay, following a switch, epoch keys, interop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire Phase 2's hosted relay transport into the iPhone app. The phone gets a `relay_auth` key and an App Attest key id in the Keychain, the App Attest entitlement and a relay origin build setting. It reads `LinkPayload` v4, links a Go hub over a relay pairing slot (`pair/<slot>`) and states its own `relay_device_id` in the sealed hello. It follows the hub's `transport_switched`, the transport marker and `hub_on_relay` (sim rules 12–15 and R32). It keeps every epoch key for 7 days after a newer one arrives and sends `epoch_ack`. A Kit phone is shown to link and drive the real Go hub on the relay's local stand. Phase 3 splits in two:

- **Phase 3a** (Tasks 1–18) needs nothing that does not exist: relay `bcca870` ships vouched hubs and `Changes.resync`. It ships dark: a Release build has no relay origin, so it never builds a relay client.
- **Phase 3b** (Tasks 19–21) is blocked on Go hub Phase 3.

**Architecture:**

- **Kit, `WatchtowerHostedRelay`:**
  - `KeychainRelayIdentity`, the `relay_auth` signer and App Attest key id store, on the Kit's `KeychainBackend`;
  - `HostedRelaySession`, one client and one WebSocket per device, shared by every relay hub and pairing slot of the phone;
  - a pairing mode of `HostedRelayTransport`, in which both lanes map to `pair/<slot>`;
  - `HostedRelayPairing`, which wraps `open_pairing`, `promote_pairing`, `close_pairing`, the slot pre-check and `vouch_hub` (Task 18).
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

**Relay contract:** relay `main` at `bcca870` (PR #5, vouched hubs; it contains PR #3's `Changes.resync`, `1c6e9e0`): `proto/README.md` ("Control events", "Operations notes", "Errors", "Vouched hubs", "Slots", "Zone names", "Failure paths on the client") and `sim/README.md` (rules 8–16, "Bounded state", "Watchtower `hub_id` vs. the relay's ids", "Attestation scenarios"); board #1432's comment (the vouch hash vector). Phase 2 pinned `3a99bd7`; Task 17 moves the Kit to `bcca870`.

**Mockups:** `docs/design/mockups/relay-client/index.html`.

## External dependencies

Checked on 2026-10-31:

- relay branches were searched read-only for `vouch` and `DEVICE_KIND_HUB` (none in any branch);
- `origin/main` contains Go hub plans 1a and 1b;
- `origin/feature/go-hub` holds Go hub Phase 2 in progress.

| # | Dependency | Status | Blocks |
|---|---|---|---|
| E1 | **Go hub 1a/1b**: the hub half of linking over the relay. `OnPairingOpened` reads hellos in `pair/<slot>` and answers keyboxes there; `SyncReaders` calls `set_hub_readers`; the hello's `relay_device_id` is validated and stored. Also: the v4 QR, the ordered path, controls (records `epoch_ack`, rejects `transport_switch` "not supported yet"), `hub pair --json --stream`, the interop harness. | **Done**, on `main` | nothing: Phase 3a builds against it |
| E2 | **Relay ask #805**: `DEVICE_KIND_HUB`, `vouch_hub{hub_device_id, auth_pub, nonce, attestation}`, `CHALLENGE_PURPOSE_VOUCH`, `HUB_NOT_VOUCHED`, `SLOT_ADDED`. | **Done**: relay `main` `bcca870` (PR #5, "Vouched hubs"), deployed on staging; it includes `1c6e9e0` (PR #3, `Changes.resync`). Contract: `proto/README.md` "Vouched hubs" and board #1432's comment (vouch hash vector). | nothing: Tasks 17 and 18 are now Phase 3a |
| E3 | **Go hub Phase 2 Task 10**: vouched admission on the hub (the Go copy's pin move, board task #1345). | **Unblocked by E2, not done**; the rest of Go hub Phase 2 is in progress on `feature/go-hub`. Phase 3a does not need it: on the stand at `bcca870` today's Go hub (copy at `3a99bd7`, registering as a MAC with no attestation) is a hub the phone vouches for, and it only reads its pair zone until it is in a slot. | Task 21 (a headless host with real vouched admission) |
| E4 | **Go hub Phase 3 Tasks 18 and 20**: the hub's switcher, which writes `transport_switched` with the keybox, the transport marker and `hub_on_relay`, and handles epochs, entitlement and `resend_from` for retired epochs. **Go hub Phase 3 Tasks 12 and 21**: a Mac on the Go hub publishes its relay identity in `device_grant`. | **Not started**: the plan is approved (ask #856) | Tasks 19, 20, 21 |
| E5 | **Relay PR #3** (`fix/changes-resync`): `Changes.resync = 4`. | **Done**: merged as `1c6e9e0`, contained in `bcca870` (board #1430) | nothing: Task 17 is Phase 3a |
| E6 | **Relay §12 p. 4**: a job in the relay repository's CI that builds the Kit client and runs the interop. | **Relay session's work** (ask #734). Phase 3a provides the entry point (Task 14). | nothing in Phase 3a; it closes Phase 2's R15 fake-only gap when it lands |
| E7 | **Relay §12 p. 5**: staging, the production origin, App Store Connect, APNs. | Before launch. The production origin is not announced yet. | the Release origin (R1); Phase 4 |

Phase 3a = Tasks 1–18; the gate, Task 16, runs last, after Tasks 17 and 18. Phase 3b = Tasks 19–21, drafts blocked on E4 (and E3 for Task 21). Each 3b task names its blockers in its title and its `Depends on:` line.

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

  - **a Mac on Relay refused on the iCloud path** (Task 10): the completion fetch after the keys checks the newest transport marker and `hub_on_relay`, and a link that never came alive ends on either. A Release phone cannot use Relay, so it would apply to every Mac on Relay; no Mac can be on Relay before Phase 4 (a paying phone must switch it), so in a Release build this check runs and finds nothing.

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
   - Vouch, then promote, come only after the keys arrived.
   - A failure before the owner's confirmation closes the slot and removes the hub's keys and session; after it, every definite refusal moves the link to `.needsOwner` with the keys kept, and only Cancel deletes them.
   - The slot limit is checked before `open_pairing`.
   - `FORBIDDEN` on the data zone before the first successful read is "not a reader yet" and is never a revocation; a failure after promote resumes or ends the link with the farewell and `remove_slot`, never half-linked.
   - Tasks 5, 10 and 18.
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

- **A (Kit relay):** Task 17 (proto pin) → Task 3 → Task 5 → Task 18 (vouch).
- **B (wire):** Task 4.
- **C (identity and build settings):** Task 1 and Task 2, in parallel.
- **D (keys and policy):** Task 6 and Task 7, in parallel; Task 7's twins need no other task.
- **E (design):** Task 8, with no code dependency.
- **Joins:**
  - Task 9 after 1, 2, 3, 4;
  - Task 10 after 5, 8, 9, 18;
  - Task 11 strictly after Task 10 (and after 6, 7, 8): never in parallel with it. Both edit `AppRoot.swift`, `LinkingViewModel.swift` and `HubSession.swift`, in that order: Task 10 first, Task 11 on top of it;
  - Task 12 after 11;
  - Task 13 after 4, 5 and 18, beside 9–12;
  - Task 14 after 13;
  - Task 15 after 10–14;
  - Task 16, the gate, after 1–15, 17 and 18.
- **Blocked (3b):** Tasks 19–21 wait for E4 (Task 21 also for E3).

Each parallel lane runs in its own worktree and branch, merged by the controller. The phone registry gets exactly one new migration in the whole phase, `v3-relay`, in Task 9; Tasks 10, 11 and 12 add no migration (their state lives in `LinkRecord`'s JSON and in the tables `v3-relay` creates). Tasks 1 and 2 both touch `WatchtowerMobile/project.yml`, so Task 2 rebases on Task 1 before `make mobile-gen`. Tasks 17, 3, 5 and 18 touch the proto, `HostedRelayTransport` and `HostedRelayPairing`, so they run in one lane, Task 17 first (every later task builds on the `bcca870` proto).

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
    /// `vouch_hub`: declared here, implemented in Task 18; until then it throws and has no caller.
    public func vouch(hubDeviceID: String, authPub: Data) async throws
}
```

- The 3 in `.slotsFull` is `HostedRelayLimits.maxMacSlots = 3` (relay spec §8). A pairing-mode transport answers `FORBIDDEN` on a data-zone write to the pair zone as the relay does: the phone only writes its hello, which is relay lane.
- Cursors in `relay_cursors` are keyed by lane (`DataZone`/`RelayZone`), not by relay zone. A new table, `relay_zone_names`, records each lane's relay zone (`TransportStore.adoptRelayZones`, called by the transport's init). When a lane's zone changes, the new zone is read from 0 as a resync, which deletes the old zone's records from the buffer. A store used first in pairing mode and then in hub mode therefore keeps one monotonic local buffer (R3). On a zone change, writes still queued for an old `pair/` zone are dropped and logged. Writes queued for any other old zone throw `TransportStoreError.queuedWritesForAnotherZone`, so the caller wipes deliberately.

- [ ] **Step 1: Failing tests:**
  - `testPairingModeMapsBothLanesToThePairZone`;
  - `testAHelloAndAKeyboxRoundTripThroughThePairZone` (a `SimHub`-style MAC device answers in the zone);
  - `testAttachmentsAreRefusedInPairingMode`;
  - `testSlotsFullIsRefusedBeforeOpenPairing`;
  - `testNotPayingIsRefusedByOpenPairing`;
  - `testPromoteAfterExpiryIsPairingExpired`;
  - `testReplacementLimitOnPromote`;
  - `testCloseIsBestEffort`;
  - `testASecondOpenForTheSameMacReplacesTheSlot` (Worker `pairing.ts:47`: the old slot is gone, its promote answers `NOT_FOUND`);
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
     - a slot whose Mac is a promoted link still finishing reads its name with the sub line "Finishing link"; its **Remove** shows the confirmation "Cancel the link to build-box? It frees its Relay slot.";
     - **Remove** busy ("Removing…", the other rows disabled), and its error with **Try Again** ("Couldn't remove the Mac. Try again.");
     - after a removal the link goes on with the same code (no new scan while it is valid);
     - no **Link over iCloud**: this screen arises only for a Mac whose current transport is Relay (R4), and such a Mac answers an iCloud link with `hub_on_relay`, so the option would be dead. The footnote reads "Up to 5 replacements in 30 days." only;
     - narrow (iPhone SE width, largest Dynamic Type).
  4. **Replacement limit.** No screen of its own: `SLOT_REPLACEMENT_LIMIT` comes only from promote, after the owner confirmed, so it is the `.needsOwner(.replacementLimit)` row below ("Too many Mac changes on Relay. Try again later, or cancel this link."). The relay's `Error.message` is not shown: `proto/README.md` says it is "for logs, never for users".
  5. The existing "This code expired" for an expired pairing slot. No new copy.
  6. **A Mac on Relay, this iPhone can't use Relay.** "Work Mac runs over Relay" / "This iPhone can't use Relay, so it would get no updates from it. Link it when the Mac is back on iCloud." with **Scan again** only.
  7. **A never-live iCloud link ended (notice).** The existing `LinkNotice` banner on Now with "Work Mac runs over Relay — This iPhone can't use Relay, so it would get no updates from it. Link it when the Mac is back on iCloud." and its **OK**, and narrow.
- **Finishing a promoted link (R5): a row in Settings → Macs, never a blocking screen**, for all three states (`.promoteSent`, `.promoted`, `.needsOwner`). Next to the linked Macs (mockup section 3's list):
  - **needs the owner** (`.needsOwner(reason)`): one frame per reason with its sub line from Task 10 point 6's table (timed out, 3 Macs, replacement limit, Relay not active, Mac not on Relay yet, not confirmed, update Watchtower), each with **Try Again** and **Cancel**, and the 3-Macs frame also with **Manage Macs** (opens the three-slots screen); the link screen's notice shows the same copy plus "See Settings → Macs." and **OK**;
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

**Depends on:** Tasks 5, 8, 9, 18 (vouch) (Task 11 starts only after this task is merged; this task adds no migration, it uses Task 9's `v3-relay` tables)

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

**A Mac on Relay is refused on every path, the iCloud path included (`.macOnRelay`).** The hub's current transport is read from the code when it carries one (`transport`). `device_grant` carries no current transport (only `transports`, what the hub offers: protocol §5.4), so when the code carries none (v3, or v4 without `transport`) or says `cloudkit` but the Mac has switched since the code was shown, the phone reads it from the hub's own records on the iCloud route, which a hub on Relay writes there (contract points 6 and 6a of Go hub Phase 3): the newest transport marker in `DataZone-<hub_id>` (`target`) and a `hub_on_relay` control in the phone's mailbox. Rule, applied whenever this phone cannot use Relay (relay `.off` or a definite `paying == false`):
- **during the link flow:** after the keys arrive on the iCloud path, `complete(…)` runs one fetch of the hub's session (the existing `fetchKeybox` fetch, which also hydrates the data zone and runs the mailbox pass) before it shows "Linked". If the newest marker's `target` is `relay`, or a `hub_on_relay` control is there, the link ends at once: today's CloudKit unlink (the `unlinked` farewell, best effort, then the hub's row, keys, session and directory removed) and the failure screen `.macOnRelay(macName)`;
- **after the link flow, on a link that never came alive:** a link whose row has never seen a heartbeat newer than its `linkedAt` (`lastHeartbeatAt` nil or older; a hub on Relay publishes no heartbeat on iCloud) that then receives `hub_on_relay` or a relay marker ends the same way, and the phone shows the same copy as a `LinkNotice` ("Work Mac runs over Relay — This iPhone can't use Relay, so it would get no updates from it. Link it when the Mac is back on iCloud."). A dead link never stays silently;
- **a link that was alive** (a heartbeat after `linkedAt`) and later gets `hub_on_relay` is not dead: the Mac can switch back. It follows Task 11 (unechoed actions to Not delivered with "Work Mac runs over Relay now", the row kept; Phase 4 adds the banner).
A phone that can use Relay never ends a link this way; it follows the switch (Task 11).

**The relay path in `connect`:**

1. **Keys.** The device keys and the hub's link keys are saved as today.
2. **Open.** `HostedRelayPairing.open(mac:)`. A refusal maps to `LinkFailure` and nothing is written.
3. **Prepare.** `host.preparePairing(…)` makes a fresh session on the relay store in pairing mode.
4. **Hello.** The hello is written with `relayDeviceID` = the session client's device id.
5. **Wait.** `waitForGrant` is unchanged: it reads the keybox in the pair zone, and the code check and SAS stay as today.
6. **Keys arrive** (the owner confirmed the code on the Mac). In order:
   - in one `UserDefaults` write, the link moves from `store.pending` (the one link the link screen holds) to `store.promoted[hubID]` (`PromotedLink`: the `LinkRecord`, the slot, the Mac's relay id, `state`, `since`) with `state = .confirmed`, and `store.pending` is cleared. The same write deletes that Mac's `pending_slot_removals` row and that hub's relay `pending_farewells` row (point 9). From here the link never belongs to the link screen, and **its keys are deleted only by the owner's Cancel**;
   - `vouch(hubDeviceID:authPub:)` (Task 18) → `Ok`, then one write `state = .promoteSent`, then `promote(slot:)` within the vouch's 10 minutes;
   - `promote` `Ok` → `state = .promoted`; `HUB_NOT_VOUCHED` (the vouch is missing or older than 10 min) → vouch again, then promote once more (`proto/README.md` client rules); a second `HUB_NOT_VOUCHED` → `.needsOwner(.notConfirmed)`;
   - a `.promoteSent` link whose answer was lost (a kill, a dropped response) is never promoted blindly again: point 9's `.promoteSent` rule asks the account state first;
   - **every definite refusal of `vouch` or `promote` after the `.confirmed` write, in the live flow or on a retry after a relaunch, moves the link to `.needsOwner(reason)` with the keys kept**:

     | Answer | `reason` | Row and notice copy (from the Task 8 mockup) | **Try Again** does |
     |---|---|---|---|
     | `PAIRING_EXPIRED` (the slot passed its 600 s, typical on a relaunch retry) | `.slotExpired` | "The link timed out on Relay. Try again, or cancel it." | `open_pairing` for a new slot (no hello, no keybox: the keys are held), vouch, promote |
     | `SLOT_LIMIT` (vouch or promote) | `.slotsFull` | "Relay already has 3 Macs. Remove one, then try again, or cancel this link." | the row's **Manage Macs** opens the three-slots screen (below); after a removal there the link goes on by itself (vouch, promote; a new slot first if the old one expired). **Try Again** does the same without the screen |
     | `SLOT_REPLACEMENT_LIMIT` | `.replacementLimit` | "Too many Mac changes on Relay. Try again later, or cancel this link." | same |
     | `ENTITLEMENT_INACTIVE` (vouch or promote) | `.notPaying` | "Relay isn't active on this iPhone. Try again when it is, or cancel this link." | same |
     | `NOT_FOUND` from `vouch` (the hub is not registered on the relay) | `.hubNotOnRelay` | "<Mac> isn't on Relay yet. Keep Watchtower open on it and try again, or cancel this link." | same |
     | a re-promote of a still-open slot that answers `NOT_FOUND` with the Mac not in slots; a second `HUB_NOT_VOUCHED`; `FORBIDDEN` (cannot happen for a phone session; logged) | `.notConfirmed` | "Relay didn't confirm the link. Try again, or cancel it." | new slot, vouch, promote |
     | `ATTESTATION_REQUIRED`, or `ATTESTATION_FAILED` after Task 18's retries | `.updateApp` | "Update Watchtower to finish this link, or cancel it." | vouch, promote |

     A transient answer (unreachable, attestation backoff, a failed account check) changes no state; the link is resumed (point 9). In the live flow the link screen shows no failure screen for these: it shows the reason's copy as the notice "… See Settings → Macs." with **OK**, returns to idle, and the row carries **Try Again** and **Cancel**. **A fresh scan of the same hub's code reuses the record**: it runs the reason's Try Again (a new slot where one is needed), never a second hello;
   - **Try Again with a new slot needs no hello** (checked against the Go hub on `main`). The relay tells the hub only which slot opened: `PAIRING_OPENED`'s detail is the slot id (`internal/hub/runtime.go:507-508`, then `OnPairingOpened`, `internal/hub/link/relay.go:84`). The hub learns which phone it is from the hello alone: `HandleHello` stores the hello's `relay_device_id` with the pending device (`internal/hub/link/hello.go:57`, `:79`), and the link copies it to the device row. After that, which slot the phone promotes is irrelevant to the hub: `SyncReaders` names every linked device's stored relay id in `set_hub_readers` (`internal/hub/link/relay.go:279-288`), run by `linkUpkeep` on a link change and on its timer (`internal/hub/runtime.go:555-559`), and `promote_pairing` is the phone's own account op. A new slot with no hello is read and left unanswered without an error (`OnPairingOpened` keeps only `hello-` records, `internal/hub/link/relay.go:113`, and answers only those, `:138`, `:158`). So Try Again opens a new slot, vouches and promotes, and writes no hello; the stored hello is not re-sent (the hub would only find its code already used by this device). Task 13 runs this step against the real Go hub;
   - one inline attempt once `.promoted`: `host.prepare(route: .hostedRelay(mac), fresh: false)` on the same store, then `linked(…)` with `transport = .relay`, which removes `store.promoted[hubID]` and shows "Linked to <Mac>" as today. If it fails, point 9.
7. **Not a reader yet (R5).** Promote puts the hub in the phone's slots, and the Go hub adds the phone to `set_hub_readers` on its next readers sync; the relay sends neither side an event. Until the first data-zone read succeeds, a `FORBIDDEN` on `data/<mac>` is retried by the next pull (the transport's normal backoff) and changes nothing. Phase 3 never infers a removal from `FORBIDDEN`: a removal reaches the phone as today, through the hub's `revoked` keybox (`removedByMac`); a slot lost on the relay's side (`SLOT_REMOVED`, entitlement) is Phase 4's. Now shows the existing "Waiting for <Mac>" status meanwhile. There is no time window to tune.
8. **Failure before the owner confirmed** (open, prepare, hello, the wait for the keys: nothing is confirmed, so nothing is kept). `close(slot:)`, then today's `fail(…)`: the hub's keys, session and directory are removed. No refusal of `vouch` or `promote` ever lands here: those come after the confirmation (point 6).
9. **Failure after promote** (`prepare` or `linked` throws, or the app is killed). Rule:
   - **Only the half before the owner's confirmation is bounded by the code's deadline** (open, hello, the wait for the keys). A confirmed link never is: it resumes until it succeeds or the owner cancels it.
   - **One rule for every state past the link screen.** `store.promoted[hubID].state` is `.confirmed`, `.promoteSent`, `.promoted` or `.needsOwner(reason)`. All four leave the link screen, show as a Settings → Macs row, never block scanning a code for another hub, and keep the keys until the link completes or the owner cancels. `PromotedLinkResumer` (app, one per `store.promoted` entry) runs at every launch, on every foreground and on **Try Again**, with the transport's backoff between failed attempts, and does exactly this per state:
     - `.confirmed` (keys held, no vouch yet) → vouch, then `.promoteSent`, then promote (point 6);
     - `.promoteSent` (promote sent, its answer unknown) → `get_account_state` first: the Mac in this phone's slots → `.promoted` (no promote is sent); the Mac not in slots and the slot still open (before its `expires_at` from `open_pairing`) → promote again, vouching first when the vouch is older than 10 min; the Mac not in slots and the slot past `expires_at` → `.needsOwner(.slotExpired)`; the account check fails → no state change, next pass;
     - `.promoted` → `prepare` and `linked` only; no relay pairing op;
     - `.needsOwner(reason)` → nothing automatic; it waits for the owner's **Try Again** (the reason's row in point 6), **Manage Macs** (`.slotsFull`) or **Cancel** (the cancel path below).
   - **What "never" means here.** Never a second hello: the hello with the phone's keys is written once, into the first slot; no state, Try Again or rescan writes another one, and no new key exchange happens. Never a second promote of a slot the account state already shows granted: a promote is sent only from `.confirmed`, from `.promoteSent` after the account state answered that the Mac holds no slot and the slot is still open, or by the owner's **Try Again** / **Manage Macs** on a `.needsOwner` row, which first asks the account state the same way (the Mac in slots → `.promoted`, no promote) and promotes only a slot that is not granted (a new one where the old one is gone). Never a key deletion without the owner's Cancel once the owner confirmed the code.
   - **It never holds the link screen.** After the inline attempt fails (or any state other than `.promoted` → linked), the link screen shows the notice "<Mac> will finish linking in the background. See Settings → Macs." (or the reason's copy for `.needsOwner`) with **OK** and returns to idle: scanning is free.
   - **Scanning a code for the same hub resumes that promoted link.** `open(_:)` checks `store.promoted[code.hubID]` right after parsing, before the expiry check and before any relay call: it runs one resume attempt (the code itself is not used, so its expiry does not matter) and writes no hello.
   - **Scanning a code for a different hub works normally**, the pre-promote half with its own `store.pending`, as today one at a time.
   - **Settings → Macs shows each promoted link as a row** ("Finishing the link…", or its error with **Try Again** and **Cancel**; Task 8 state). **Cancel** (after "Cancel the link to <Mac>? It frees its Relay slot." → **Cancel Link** / **Keep Trying**) runs the cancel path below.
   - **The cancel path of a promoted link** (also used by **Remove** on the slots screen for a promoted Mac). Cancel is pressed exactly when the hub transport may not come up, so no step waits on `prepare`:
     1. **Farewell, best effort, bounded.** The `unlinked` device record, sealed with the keys the phone holds, is written straight into the mailbox through `TransportFactory.sendDirectly` on the relay route (the shared client, no hub session needed), with a 10 s bound. A failure or timeout is logged by code and the sealed record is kept in `pending_farewells` (relay route, Task 9), so it is not dropped: at each launch it is sent before that Mac's pending slot removal is retried. Once the slot is freed the mailbox can no longer be written; a farewell still unsent then is deleted with one log line (`relay farewell undeliverable after slot removal`, no ids), since nothing can deliver it any more.
     2. **`remove_slot`, always**, whether the farewell went out or not, with Phase 2's `UNAVAILABLE` retry. A failure is kept as a `pending_slot_removals` row and retried at every launch until the relay answers `Ok` or `NOT_FOUND`; it is never dropped, except by a new link to the same Mac (below).
     - **Never `remove_slot` for a Mac a local link names.** The row is keyed by the Mac's relay id, and a retry after a re-link would free the new link's slot. So: the `.confirmed` write for that Mac deletes its `pending_slot_removals` row (and that hub's relay `pending_farewells` row); and the launch retry calls `remove_slot` only when no local link record names that Mac: no registry row, no `store.promoted` entry in any state, and no `store.pending` entry. When one does, the row is deleted instead. Test `testARelinkOfTheSameMacCancelsItsPendingSlotRemoval`.
     3. **Local state removed either way:** the hub's keys, session, directory and the `store.promoted` entry go at once, whatever steps 1 and 2 did.
     4. **What the Mac learns.** The Go hub does not read `device` records yet (protocol §5.5), so the farewell is for later hubs. The Mac learns from the freed slot: its `get_account_state` no longer lists this phone in `phones`, so its readers sync drops the phone from `set_hub_readers` and the phone can no longer read the data zone. The phone stays in the hub's device list until the owner presses **Remove…** on the Mac (stated in the feature note's v1 limits); while the slot removal is still pending, the phone holds no keys or state any more, so nothing it could read reaches it.
   - **Several promoted links at once are fine.** Each resume attaches its hub transport to the one `HostedRelaySession` (R2), so there is still one socket per device; the pairing-mode transport is not used after promote. Each promoted link already holds a relay slot, so `get_account_state`'s slot count (the pre-check before `open_pairing`) includes it; and it counts toward `HubRegistry.limit` (4 Macs on the phone) like a linked row, so a fifth code is refused with today's `.tooManyMacs`.

**`LinkFailure` additions.** The copy lives in the model, from the Task 8 mockup:

| Case | Title | Hint | `offersScan` |
|---|---|---|---|
| `.needsRelay(macName:)` | "\(macName) works over Relay only" | "Relay isn't available on this iPhone" | true |
| `.relayUnreachable` | "Couldn't reach Relay" | "Check your connection and scan again" | true |
| `.macOnRelay(macName:)` | "\(macName) runs over Relay" | "This iPhone can't use Relay, so it would get no updates from it. Link it when the Mac is back on iCloud." | true |

No relay failure offers **Link over iCloud**: every one of them arises only for a Mac whose current transport is Relay (R4), which would answer an iCloud link with `hub_on_relay`. Spec §8's "adding the Mac over iCloud stays possible" holds for a Mac on iCloud, which links over iCloud anyway. The relay's `Error.message` is never shown (`proto/README.md`: "for logs, never for users"). `PAIRING_EXPIRED` before the owner confirmed maps to `.expired`; after the confirmation it is `.needsOwner(.slotExpired)` (point 6).

**Three Macs in slots (spec §8, mockup section 6).** Not a failure screen: `HostedRelayPairing.open` refuses `.slotsFull(macs:)` before any hello, and the phone shows the section 6 frame `RelaySlotsView` with `RelaySlotsModel`:

- title "Your subscription already has \(HostedRelayLimits.maxMacSlots) Macs. Remove one to add this Mac over Relay.";
- one row per Mac in slots, named from the registry (`relayMacDeviceID` match) or else from `store.promoted` (its `LinkRecord.macName`, with the sub line "Finishing link"), else "A Mac not on this iPhone"; each with **Remove**;
- footnote "Up to 5 replacements in 30 days.", with no iCloud option (the Mac is on Relay).

**Remove** on a Mac linked on this iPhone runs that Mac's whole unlink (R14: farewell, then `remove_slot`), after the existing unlink confirmation; on a promoted Mac still finishing it runs the promoted link's cancel path (point 9), after the same "Cancel the link to <Mac>? It frees its Relay slot." confirmation; on a Mac not on this iPhone it calls `remove_slot` only. While it runs the row shows "Removing…" and the others are disabled; a failure shows "Couldn't remove the Mac. Try again." with **Try Again**. The screen opens in two places, with one rule: **before the owner confirmed** (the `open` pre-check), it shows inline on the link screen and, after a removal, the link goes on with the same code while it is valid (else `.expired`); **after the owner confirmed** (`SLOT_LIMIT` from vouch or promote, live or on a retry), the link is `.needsOwner(.slotsFull)` and the screen opens from its Settings → Macs row (**Manage Macs**), and after a removal the confirmed link goes on (vouch, promote) without a scan.

**Every step and its failure.** Nothing in Task 10 fails without one of these outcomes:

| Step | Failure | Outcome | Test |
|---|---|---|---|
| Parse the code | not a link, bad encoding, newer/older version, bad hub key, mismatched relay identity | today's `.refused` / `.updateApp` / `.updateMac`; nothing stored | `HubContractFixtureTests` (Task 4), `testUpdateRequiredIsUpdateApp` |
| Same hub already promoted | — | one resume attempt, no hello | `testScanningTheSameHubResumesItsPromotedLink` |
| Fifth Mac | registry plus promoted links at `HubRegistry.limit` | `.tooManyMacs` | `testAPromotedLinkCountsTowardTheFourMacs` |
| Route decision | relay off / not paying / unknown paying / update required / relay-only / Mac on Relay | `.cloudKit`, or `.needsRelay`, `.relayUnreachable`, `.updateApp`, `.macOnRelay`; no Keychain item when relay off | `LinkRoutePolicyTests` (all rows), `testAnUnknownPayingAnswerIsRelayUnreachableNeverICloud` |
| iCloud path: link to a Mac on Relay | marker or `hub_on_relay` seen in the completion fetch, or later on a never-live link | the link ends (farewell best effort, local state removed), `.macOnRelay` screen or notice | `testAnICloudLinkToAMacOnRelayEndsWithMacOnRelay`, `testANeverLiveLinkThatGetsHubOnRelayEnds`, `testALiveLinkThatGetsHubOnRelayIsKept` |
| 1. Keys | Keychain locked or failing | today's `.local(keysUnavailable)` | existing `LinkingViewModelTests` |
| 2. Open | slots full (pre-check, before confirmation) / not paying / unreachable / backoff / update | the slots screen inline / `.needsRelay` or `.macOnRelay` / `.relayUnreachable` / `.updateApp`; nothing written | `testSlotsFullBeforeConfirmationShowsTheSlotsScreenInline`, `testSlotsFullRefusesBeforeAnyHello`, `testNotPayingAtOpenIsRefused`, `testOpenUnreachableIsRelayUnreachable` |
| 3. Prepare (pairing) | store bound elsewhere, local error | `close(slot:)`, `.local(reason)`, keys removed | `testAPairingPrepareFailureClosesTheSlot` |
| 4. Hello | queued save throws (local store) | `close(slot:)`, `.local(reason)` | `testAHelloWriteFailureClosesTheSlot` |
| 5. Wait | no answer by the deadline / refusal in the keybox / code mismatch | `close(slot:)`, today's `.noAnswer` / `.refused` / `.expired` | `testNoAnswerClosesTheSlot`, existing grant-wait tests |
| 6. Keys arrive | the `.confirmed` write fails | the link stays in `store.pending`; at launch its resume writes `.confirmed` before any relay call | `testTheConfirmedWriteIsRetriedBeforeVouch` |
| 6. Vouch | `ATTESTATION_FAILED` / `ATTESTATION_REQUIRED` / `ENTITLEMENT_INACTIVE` / `NOT_FOUND` / `SLOT_LIMIT` / transient | Task 18's retries, then `.needsOwner(.updateApp / .notPaying / .hubNotOnRelay / .slotsFull)`, keys kept; transient: state unchanged | `testEveryVouchRefusalKeepsTheKeysAndAsksTheOwner` (table), Task 18's Kit tests |
| 6. Promote, live | `PAIRING_EXPIRED` / `SLOT_LIMIT` / `SLOT_REPLACEMENT_LIMIT` / `ENTITLEMENT_INACTIVE` | `.needsOwner(.slotExpired / .slotsFull / .replacementLimit / .notPaying)`, keys kept, notice + row | `testAPromoteRefusalInTheLiveFlowKeepsTheKeysAndAsksTheOwner` (table over the four codes) |
| 6. Promote | `HUB_NOT_VOUCHED` | vouch again, promote once more; twice → `.needsOwner(.notConfirmed)` | `testHubNotVouchedVouchesAgainOnce` |
| 6. Promote | unreachable / transient / the answer lost (kill) | state stays `.promoteSent` | `testAKillBetweenPromoteAndItsAnswerLeavesAPromoteSentRow` |
| 9. Resume `.confirmed` | — | vouch, then promote (the rows above) | `testAConfirmedLinkVouchesThenPromotesOnResume` |
| 9. Resume `.promoteSent` | account lists the Mac | `.promoted`, no promote sent | `testPromoteSentWithTheMacInSlotsBecomesPromotedWithoutPromoting` |
| 9. Resume `.promoteSent` | account without the Mac, slot still open | promote again (vouch first if older than 10 min); its answer goes through the rows above | `testPromoteSentWithAnOpenSlotPromotesAgainOnce` |
| 9. Resume `.promoteSent` | re-promote of the open slot answers `NOT_FOUND` | `.needsOwner(.notConfirmed)` | `testNotFoundAndNotInSlotsKeepsTheKeysAndAsksTheOwner` |
| 9. Resume `.promoteSent` | account without the Mac, slot past `expires_at` (`PAIRING_EXPIRED` on a relaunch) | `.needsOwner(.slotExpired)`, no promote sent | `testPairingExpiredOnARelaunchRetryAsksTheOwnerAndTryAgainUsesANewSlot` |
| 9. Resume `.promoteSent` | `SLOT_LIMIT` / `SLOT_REPLACEMENT_LIMIT` / `ENTITLEMENT_INACTIVE` on that re-promote | `.needsOwner(reason)`, keys kept | `testDefiniteRefusalsAfterPromoteSentAskTheOwner` (table over the three codes) |
| 9. Resume `.promoteSent` | the account check fails | no state change, next pass | `testNotFoundWithAnUnreachableAccountStateKeepsTheLinkAndRechecks` |
| 9. Resume `.needsOwner` | — | nothing automatic | `testNeedsOwnerWaitsForTheOwner` |
| 9. Try Again with a new slot | `open_pairing` refused: slots full / not paying / unreachable | `.needsOwner(.slotsFull / .notPaying)` / no state change; never a hello | `testTryAgainOpensANewSlotWithoutAHello`, `testTryAgainOpenRefusalsKeepTheLinkWaiting` |
| 9. Manage Macs (`.slotsFull` row) | a removal succeeds / fails | the confirmed link goes on (vouch, promote) / the screen's row error, link unchanged | `testManageMacsAfterConfirmationContinuesTheLinkAfterARemoval`, `testRemoveFailureShowsTryAgain` |
| Same hub scanned while `.needsOwner` | — | the reason's Try Again (a new slot where needed), no second hello | `testScanningTheSameHubWhileNeedsOwnerReusesTheRecord` |
| Same hub scanned while `.promoteSent` or `.promoted` | — | one resume pass of that state, no hello | `testScanningTheSameHubResumesItsPromotedLink` |
| 6. Inline `prepare`/`linked` | throws | point 9: background resume, notice, scanner free | `testAPromotedLinkNeverHoldsTheLinkScreen` |
| 7. First data read | `FORBIDDEN` (not a reader yet) | retried, never a removal | `testForbiddenBeforeTheFirstReadIsRetriedAndNeverARemoval` |
| 9. Resume `.promoted` | `prepare`/`linked` keep failing | keeps resuming every launch and foreground, Settings row error with Try Again; no pairing op | `testAPromotedLinkKeepsResumingUntilItSucceeds`, `testKilledPastTheDeadlineAfterPromoteResumesOnRelaunch` |
| 9. Cancel | farewell fails, `remove_slot` succeeds | slot freed, local state gone | `testCancelFarewellFailsRemoveSlotSucceeds` |
| Launch retry of a slot removal | the same Mac was linked again meanwhile | the row is deleted, `remove_slot` not called | `testARelinkOfTheSameMacCancelsItsPendingSlotRemoval` |
| 9. Cancel | farewell and `remove_slot` both fail | local state gone; the farewell in `pending_farewells` and the `pending_slot_removals` row retried at launch, farewell first | `testCancelBothFailKeepsTheSlotRemovalForLaunch` |
| Slots screen Remove | `remove_slot` fails | row error "Couldn't remove the Mac. Try again." | `testRemoveFailureShowsTryAgain` |
| Unlink | farewell kept (#143) / `remove_slot` fails | farewell resent later / `pending_slot_removals` row | `testUnlinkingARelayHubSendsTheFarewellThenRemovesTheSlot`, `testASlotRemovalThatFailedIsRetriedAtLaunch` |

**Unlink of a relay hub (R14):**

1. The farewell (the `unlinked` device record) goes into the mailbox, as today through the hub's transport.
2. Once it has left the queue, or was kept per #143, the phone calls `remove_slot`. Phase 2's `UNAVAILABLE` retry runs within 30 s.
3. A failure is logged and retried at the next launch from a kept `pending_slot_removals` row (created by Task 9's `v3-relay`; a Mac id and a date, no content). The row goes when the relay answers `Ok` or `NOT_FOUND`, or when a new link to the same Mac cancels it (point 9).

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
    - `testAPromoteRefusalInTheLiveFlowKeepsTheKeysAndAsksTheOwner` (table: `PAIRING_EXPIRED`, `SLOT_LIMIT`, `SLOT_REPLACEMENT_LIMIT`, `ENTITLEMENT_INACTIVE`; keys and record kept, `.needsOwner(reason)`, the notice's copy per reason);
    - `testPairingExpiredOnARelaunchRetryAsksTheOwnerAndTryAgainUsesANewSlot`;
    - `testDefiniteRefusalsAfterPromoteSentAskTheOwner` (table: `SLOT_LIMIT`, `SLOT_REPLACEMENT_LIMIT`, `ENTITLEMENT_INACTIVE` on a relaunch retry);
    - `testEveryVouchRefusalKeepsTheKeysAndAsksTheOwner`;
    - `testHubNotVouchedVouchesAgainOnce`;
    - `testScanningTheSameHubWhileNeedsOwnerReusesTheRecord`;
    - `testTheConfirmedWriteIsRetriedBeforeVouch`;
    - `testSlotsFullBeforeConfirmationShowsTheSlotsScreenInline`;
    - `testManageMacsAfterConfirmationContinuesTheLinkAfterARemoval`;
    - `testAConfirmedLinkVouchesThenPromotesOnResume`;
    - `testPromoteSentWithTheMacInSlotsBecomesPromotedWithoutPromoting`;
    - `testPromoteSentWithAnOpenSlotPromotesAgainOnce`;
    - `testNeedsOwnerWaitsForTheOwner`;
    - `testTryAgainOpensANewSlotWithoutAHello` (no record written in the new pair zone; vouch and promote of the new slot; the Mac in slots afterwards);
    - `testTryAgainOpenRefusalsKeepTheLinkWaiting`;
    - `testNoStateEverWritesASecondHello` (every state × Try Again × rescan: the fake's pair zones hold one hello in all);
    - `testOnlyCancelDeletesTheKeysOfAConfirmedLink` (every state × every refusal: keys present until Cancel);
    - `testForbiddenBeforeTheFirstReadIsRetriedAndNeverARemoval`;
    - `testAFailureAfterPromoteResumesWithoutASecondHelloOrPromote`;
    - `testKilledPastTheDeadlineAfterPromoteResumesOnRelaunch` (promote done, app killed, the clock moved past the code's `exp`, relaunch: `prepare` and `linked` succeed in the background, no second hello or promote, the row's route is `.hostedRelay`);
    - `testAPromotedLinkKeepsResumingUntilItSucceeds` (three failing launches, then success);
    - `testAPromotedLinkNeverHoldsTheLinkScreen` (the inline attempt fails: the notice shows, the phase returns to idle, `store.pending` is nil);
    - `testScanningTheSameHubResumesItsPromotedLink` (an expired code of that hub: one resume, no hello, no `open_pairing`);
    - `testScanningAnotherHubLinksNormallyWhileOneIsPromoted` (a second hub links over CloudKit and over the relay; one socket on the fake);
    - `testAPromotedLinkCountsTowardTheFourMacs`;
    - `testCancellingAPromotedLinkSendsTheFarewellThenRemovesTheSlot`;
    - `testCancelFarewellFailsRemoveSlotSucceeds` (prepare broken, `sendDirectly` times out after 10 s: the slot is freed on the fake, keys and directory gone, the kept farewell deleted with its log line because the mailbox can no longer be written);
    - `testCancelBothFailKeepsTheSlotRemovalForLaunch` (relay unreachable: local state gone, one `pending_slot_removals` row and one relay `pending_farewells` row; the next launch sends the farewell, then frees the slot);
    - `testARelinkOfTheSameMacCancelsItsPendingSlotRemoval`;
    - `testNotFoundWithAnUnreachableAccountStateKeepsTheLinkAndRechecks`;
    - `testNotFoundAndNotInSlotsKeepsTheKeysAndAsksTheOwner` (the row shows the needs-owner line; keys kept; Try Again asks the account state, then opens a new slot, vouches and promotes, as the `.notConfirmed` row of point 6 says; Cancel runs the cancel path);
    - `testAKillBetweenPromoteAndItsAnswerLeavesAPromoteSentRow` (the exact sequence: owner confirms, `.promoteSent` written, the promote reaches the relay, killed before the answer; relaunch: the account state lists the Mac → `.promoted` with **no promote sent** → `linked`);
    - `testASlotRemovalIsNeverRetriedForAMacALocalLinkNames` (a `pending_slot_removals` row for Mac M, then a link to M stuck in `.promoteSent`, `.needsOwner` or `store.pending`: launch deletes the row, no `remove_slot` on the fake);
    - `testScanAnotherHubWhilePromoteSent` and `testScanAnotherHubWhileNeedsOwner` (another hub links normally; the first row stays);
    - `testPromoteSentAndNeedsOwnerResumeAtLaunchAndForeground`;
    - `testAnICloudLinkToAMacOnRelayEndsWithMacOnRelay` (a v4 code without `transport` on a free phone; the hub's DataZone holds a marker with `target: relay`: the completion fetch ends the link, `.macOnRelay`, no row left);
    - `testANeverLiveLinkThatGetsHubOnRelayEnds` (no heartbeat since `linkedAt`; `hub_on_relay` arrives later: the link ends with the notice);
    - `testALiveLinkThatGetsHubOnRelayIsKept`;
    - `testAPromotedMacIsNamedOnTheSlotsScreenAndItsRemoveCancels` (a promoted link's Mac reads "build-box" / "Finishing link"; Remove runs the cancel path: farewell attempt, `remove_slot`, local state gone);
    - `testNotPayingAtOpenIsRefused`, `testOpenUnreachableIsRelayUnreachable`, `testAPairingPrepareFailureClosesTheSlot`, `testAHelloWriteFailureClosesTheSlot`, `testNoAnswerClosesTheSlot`, `testRemoveFailureShowsTryAgain`;
    - `testTheHalfBeforePromoteIsBoundedByTheCodesDeadline`;
    - `testAnUnknownPayingAnswerIsRelayUnreachableNeverICloud`;
    - `testSlotsFullShowsTheMacsWithRemove`, `testRemovingALinkedMacUnlinksItThenLinksWithTheSameCode`, `testRemovingAnUnknownSlotCallsRemoveSlotOnly`;
    - `testUnlinkingARelayHubSendsTheFarewellThenRemovesTheSlot`;
    - `testASlotRemovalThatFailedIsRetriedAtLaunch`;
    - `testARelayLinkNeedsNoICloudAccount`.
  - `LinkingViewModelTests`: every existing test unchanged, plus `testFailureCopyMatchesTheMockup` for the three new cases (`.needsRelay`, `.relayUnreachable`, `.macOnRelay`) and the finishing state's copy and `RelaySlotsModelTests` (create) for the slots screen's copy and states.
  - `OrangeToneTests`: the failure view's `toneUses`.
  - `ScreenshotTourTests`: `link-needs-relay`, `link-relay-unreachable`, `relay-slots-full`, `relay-slots-removing`, `relay-slots-remove-error`, `link-mac-on-relay`, `link-finish-in-background`, `relay-slots-finishing-mac`, `notice-mac-on-relay`, `macs-finishing-row`, `macs-finishing-row-error`, `macs-needs-owner-<reason>` for each of the seven reasons, `macs-finishing-cancel-confirm`, each in light, dark and narrow.
- [ ] **Step 2: Run, expect failure:** `make mobile-gen`, then `make mobile-test SIM='iPhone 17 Pro' MOBILE_FILTER='LinkRoutePolicyTests|RelayLinkingTests|LinkingViewModelTests'`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run:** the Step 2 filter plus `AppRootRelinkTests|WelcomeTests|ScreenshotTourTests|OrangeToneTests|HubRegistryTests`. All pass. Then run `make mobile-shots SIM='iPhone 17 Pro'` and compare every shot listed in Step 1 (nineteen, each light, dark and narrow) with Task 8's frames and section 6's "Add Mac" frame; record any difference in the commit body.
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

**Depends on:** Tasks 4, 5, 17 and 18 (the `bcca870` proto and `vouch`)

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
5. **Try Again with a new slot, against the real Go hub:** after the keys arrived in the first slot, call `HostedRelayPairing.open` again for the same Mac (the relay replaces the phone's open slot for that Mac: Worker `worker/src/do/account/pairing.ts:47` at `bcca870` deletes the Mac's open slot before inserting the new one, and Task 5's fake follows it, pinned by `testASecondOpenForTheSameMacReplacesTheSlot`; if the Worker ever refused instead, this step fails loudly on the stand and is rewritten, so the first slot is gone, the same position a Try Again is in after `PAIRING_EXPIRED`; the stand has no endpoint that ages a slot, and the expiry itself is pinned on the fake by `testPairingExpiredOnARelaunchRetryAsksTheOwnerAndTryAgainUsesANewSlot`), assert `promote` of the first slot answers `NOT_FOUND`; then write nothing into the new slot, `vouch` (Task 18; a phone on the dev stand sends no attestation) and `promote` the new slot. The Go side checks that the hub logged no hello and wrote no keybox in the new pair zone, and that the phone becomes a reader (`set_hub_readers`) from the relay id it stored at the hello. Before that, a `promote` without a vouch answers `HUB_NOT_VOUCHED` (asserted once); the Go hub, unvouched until promote, reads only its pair zone.
6. Read the data zone through `HostedRelayTransport` (`.hub`) and `SecureTransport`. Open the `device_grant` and the `heartbeat`, and assert every slice kind the hub published opens (spec §13 E2E (3)).
7. Enqueue three ordered actions through `ActionOutbox` with a canary marker, so the hub's `interop_mark` handler applies them. Read the `applied` echoes and delete them (`expect: .seq`).
8. Merge the grant's keys and send `epoch_ack`.
9. Write `actions.done`, then wait for `go.ok`.
10. **Unlink**, the same steps as the phone's unlink (R14): save the `unlinked` device record (sealed `DevicePayload` with `unlinked: true`) into the mailbox, flush it, then `HostedRelayPairing.removeSlot(mac:)`. Assert the phone's `get_account_state` no longer lists the Mac, write `unlinked`, wait for `unlink.ok`.
11. **The slot is free:** `add_slot` of the same Mac succeeds (and the account still lists at most 3 Macs); write `readded`, wait for `go.done`.

- [ ] **Step 1: Write** the Go test, the Kit test and the script tests. The script refuses a missing relay checkout or a held port.
- [ ] **Step 2: Run:** `bash scripts/tests/test-relay-interop-kit-hub.sh`, and `go vet -tags interop ./internal/hub` (compiles the Go test). Then run `make relay-interop-kit-hub RELAY=<clean relay worktree at bcca870> > "${TMPDIR:-/tmp}/p3-interop-hub.log" 2>&1; echo "exit=$?"`, expecting `exit=0`. Record the run (passed, skipped, failed) in the commit body.
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
  - v1 limits updated: `testAttestUnsupportedStaysOnCloudKit` done; the dark ship; vouching proven on the stand (attestation off), a real assertion first on staging; a cancelled or unlinked relay link stays in the Go hub's device list until the owner removes it on the Mac (the Go hub reads no `device` records yet), although the freed slot already drops it from the readers; no pushes, so a backgrounded app on the relay waits for the foreground; the promote residual (R5). Task 17 removes the stalled-resync limit (`Changes.resync`).
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

**Depends on:** Tasks 1–15, 17 and 18

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

### Task 17: Move the proto pin to relay `bcca870` and set `Changes.resync`

**Depends on:** none (E2 and E5 are done: `bcca870` contains `1c6e9e0`). First task of lane A: Tasks 3, 5 and 18 build on its proto.

**Files:**
- Regenerate: `WatchtowerKit/Sources/WatchtowerRelayProto/{relay.proto,relay.pb.swift,VERSION}` with `make relay-proto RELAY=<clean relay worktree> REF=bcca870`, committed alone first. New in the proto: `Changes.resync = 4`, `DEVICE_KIND_HUB = 3`, `CHALLENGE_PURPOSE_VOUCH = 2`, `Request.vouch_hub = 21` (`VouchHub{hub_device_id, auth_pub, nonce, attestation}`), `ERROR_CODE_HUB_NOT_VOUCHED = 22`, `CONTROL_KIND_SLOT_ADDED = 6`.
- Modify: `WatchtowerKit/Sources/WatchtowerHostedRelay/Transport/HostedRelayTransport+Pull.swift`. Every page of a resync from 0 sends `resync = true`, and an incremental pull never does. The stall hold (`resyncStallHold`) stays only for a `TOKEN_EXPIRED` on a resync page with the flag set, which the README still allows for a `since_seq` above the zone's seq.
- Modify: `HostedRelayTransport+Errors.swift`: `HUB_NOT_VOUCHED` on a mailbox op → `.permanent(code: "hub_not_vouched")` (it cannot happen for a phone; named so it is not a `relay_22` transient), pinned by `testErrorMapping`. The phone ignores `SLOT_ADDED` (a hub-only control).
- Modify: `WatchtowerKit/Sources/WatchtowerHostedRelayTesting/FakeHostedRelay+Zones.swift` (the flag skips only the floor check)
- Modify: `docs/features/relay-client.md` (v1 limit "Resync below the tombstone floor" removed; the pin line)
- Test: `HostedRelayTransportTests`:
  - `testAResyncSetsTheFlagOnEveryPage`;
  - `testAnIncrementalPullNeverSetsIt`;
  - `testAResyncBelowTheFloorFinishesAndDeletesWhatItDidNotReturn`;
  - `testErrorMapping` (with `HUB_NOT_VOUCHED`);
  - `RelayProtoPinTests` passes on the new `VERSION`.

- [ ] **Step 1:** Regenerate and commit the copy alone; then the failing tests, then implement.
- [ ] **Step 2:** `make kit-test FILTER='HostedRelayTransportTests|RelayProtoPinTests|RelaySim'`, then `make relay-interop-kit RELAY=<clean relay worktree at bcca870>`.
- [ ] **Step 3:** `make relay-go` is the Go hub session's (board task #1345; Phase 2's R14: the pins are not forced equal). Note both pins in the PR body.
- [ ] **Step 4: Commit:** `build(kit): relay proto at bcca870 (vouched hubs, Changes.resync); full resyncs set the flag (#1430)`

### Task 18: `vouch_hub` on the phone

**Depends on:** Tasks 5 and 17

**Files:**
- Modify: `WatchtowerKit/Sources/WatchtowerHostedRelay/Identity/RelayAuthMessages.swift`: `vouchClientDataHash(nonce:hubDeviceID:authPub:origin:)` = `SHA256("relay/v1/vouch" ‖ nonce ‖ hub_device_id ‖ auth_pub ‖ server_origin)`, strings as UTF-8.
- Modify: `WatchtowerKit/Sources/WatchtowerHostedRelay/Client/HostedRelayClient+Ops.swift`: `challenge(purpose: .vouch) -> Data`, `vouchHub(_:)`.
- Modify: `WatchtowerKit/Sources/WatchtowerHostedRelay/Attest/RelayAttestor.swift`: `vouchAssertion(clientDataHash:)`, and **one assertion at a time**. The attestor is the only caller of `generateAssertion`; login and vouch assertions go through one serial queue, and the next assertion is generated only after the previous request was answered (`proto/README.md` client rules: login and `vouch_hub` share the assertion counter, and a later assertion reaching the server first makes the earlier one fail).
- Modify: `WatchtowerKit/Sources/WatchtowerHostedRelay/Transport/HostedRelayPairing.swift`: `vouch(hubDeviceID:authPub:)`.
- Modify: `WatchtowerKit/Sources/WatchtowerHostedRelayTesting/FakeHostedRelay+Accounts.swift`, `+Auth.swift`: the vouch model of `proto/README.md` "Vouched hubs": the six checks in their order; a pending vouch per hub kept 10 min and renewed by a repeat; `add_slot`/`promote_pairing` of a hub not in slots consumes it or answers `HUB_NOT_VOUCHED`; a failing `add_slot` does not consume it; a hub already in slots needs none; the assertion counter shared with login; an unvouched hub limited to its pair zone; a phone on dev sends no attestation.
- Test: Create `WatchtowerKit/Tests/WatchtowerHostedRelayTests/HostedRelayVouchTests.swift`; extend `RelayAuthVectorTests`, `RelayAttestorTests`

**Interfaces:**
```swift
extension HostedRelayPairing {
    public enum VouchRefusal: Error, Equatable { case notPaying, updateRequired, hubNotOnRelay, slotsFull, notConfirmed, unreachable, attestationBackoff(until: Date) }
    /// GetChallenge{purpose: VOUCH} → assertion over the vouch hash → vouch_hub. Every attempt takes a new nonce and a new assertion.
    public func vouch(hubDeviceID: String, authPub: Data) async throws   // throws VouchRefusal
}
```

**Answers.** The server checks in this order and answers the first failure: `FORBIDDEN` → `ENTITLEMENT_INACTIVE` → `ATTESTATION_REQUIRED` → `ATTESTATION_FAILED` → `NOT_FOUND` → `SLOT_LIMIT`.

| Answer | Phone action | Thrown |
|---|---|---|
| `Ok` | the pending vouch holds 10 min; promote or `add_slot` follows within it | — |
| `ATTESTATION_FAILED` | a new `VOUCH` nonce and assertion, retry once; on a second failure the lost-key path (`RelayAttestor`'s fresh attestation at the next login, Phase 2), then retry once more; after that | `.updateRequired` |
| `ATTESTATION_REQUIRED` | no retry | `.updateRequired` |
| `ENTITLEMENT_INACTIVE` | no retry (the subscription screen is Phase 4) | `.notPaying` |
| `NOT_FOUND` | no retry: the hub has not registered on the relay | `.hubNotOnRelay` |
| `SLOT_LIMIT` | no retry | `.slotsFull` |
| `FORBIDDEN` | cannot happen for a phone session; logged | `.notConfirmed` |
| unreachable, `UNAVAILABLE` past 30 s, attestation `.retryLater` | the next attempt takes a new nonce and assertion | `.unreachable` / `.attestationBackoff` |

Task 10 maps these to `.needsOwner(reason)` (point 6) and handles `HUB_NOT_VOUCHED` from `promote_pairing`/`add_slot` (vouch again, then repeat once).

- [ ] **Step 1: Failing tests:**
  - `RelayAuthVectorTests.testVouchClientDataHashVector`: nonce `[1, 2]`, hub_device_id `"h"`, auth_pub `[3]`, origin `"https://r"` → `ecdda44ae74bd86e122f2edd43708cf2b8012cc194f78ed5728052e5c109956d` (the relay's vector, board #1432);
  - `HostedRelayVouchTests`:
    - `testVouchSendsAVouchChallengeThenTheAssertion` (purpose `VOUCH`; the assertion is over the vouch hash of that nonce, the hub's id and key);
    - `testEveryRetryTakesANewNonceAndAssertion`;
    - `testAttestationFailedRetriesOnceThenLostKeyThenOnceMoreThenUpdate`;
    - `testAttestationRequiredIsUpdateRequired`;
    - `testEntitlementInactiveIsNotPaying`, `testNotFoundIsHubNotOnRelay`, `testSlotLimitIsSlotsFull`;
    - `testRefusalsComeInTheServersOrder` (the fake fails several checks at once; the first in the order is answered);
    - `testPromoteWithoutAVouchIsHubNotVouched`, `testAVouchOlderThanTenMinutesIsHubNotVouched`, `testAFailedAddSlotDoesNotConsumeTheVouch`, `testAHubAlreadyInSlotsNeedsNoVouch`;
  - `RelayAttestorTests.testLoginAndVouchAssertionsNeverOverlap`: a login and a vouch started together; the second assertion is generated only after the first request was answered, and the fake's counter never sees an older assertion after a newer one.
- [ ] **Step 2: Run, expect failure:** `make kit-test FILTER='HostedRelayVouchTests|RelayAuthVectorTests|RelayAttestorTests'`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run:** the Step 2 filter plus `HostedRelayPairingTests|HostedRelayAttestationTests|HostedRelayClientTests`, then `make relay-interop-kit RELAY=<clean relay worktree at bcca870>`.
- [ ] **Step 5: Lint.**
- [ ] **Step 6: Commit:** `feat(kit): the phone vouches for the hub — vouch_hub with a serialized assertion (#1242)`

---

## Phase 3b — blocked tasks

**Drafts, not approved with this plan.** Each task outlines what its dependency unlocks, so the 3a work leaves room for it. When a dependency lands, its task is re-planned against the Go hub code and that plan goes to the owner for approval on its own.

### Task 19: Upgrade an existing CloudKit link to the relay (blocked on Go hub Phase 3)

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

### Task 21: Phase 3b gate (blocked on E3, E4)

**Depends on:** Tasks 19 and 20; E3

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
  - Why: in pairing mode both lanes map to `pair/<slot>`. The hello is relay-lane and the keybox data-lane, as on CloudKit, so `SecureTransport`, the replica's keybox read and `waitForGrant` work unchanged. After promote, the same store serves hub mode. Cursors are keyed by lane, and `relay_zone_names` records each lane's relay zone, so a lane whose zone changed resyncs from 0 and the local buffer tokens stay monotonic. Owner approval 6 of Phase 2 put the `pair/<slot>` mapping here.
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
- **R5. Vouch and promote come only after the keys; slots are checked first; a confirmed link is never dropped without the owner.**
  - Why: spec §8 and `proto/README.md` "Vouched hubs" order vouch, then promote, after the owner's confirmation. The slot count is checked before `open_pairing`, so the common refusal never reaches the Mac. Once the keys arrived (the owner confirmed), the link lives in `store.promoted` (`.confirmed` → `.promoteSent` → `.promoted`); every definite refusal of vouch or promote, live or on a relaunch retry (`PAIRING_EXPIRED` included), moves it to `.needsOwner(reason)` with the keys kept, and only the owner's Cancel deletes them. A confirmed link resumes in the background at every launch and foreground, never holds the link screen, and never blocks scanning another hub; a code of the same hub reuses the record (a new slot where needed, no second hello). Until the first data-zone read succeeds, `FORBIDDEN` is "not a reader yet", retried with no time window; Phase 3 never infers a removal from it. Several confirmed links share the one socket (R2), each holds its slot and counts toward the 4 Macs.
  - Cost if wrong: a link refused for good after the confirmation waits as a row until the owner cancels it, and the Mac keeps a linked device that never reads until removed there (v1 limit). A slow readers sync keeps "Waiting for <Mac>" longer.
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
- **R15. The Kit ↔ Go hub interop is Kit-level and runs on the stand at `bcca870`, vouch included.**
  - Why: the app's link flow is covered by phone tests on the fake. The interop proves wire compatibility with the real Go hub (test mode, `WATCHTOWER_HUB_DIR`) on the real stand. With attestation off there, today's Go hub (copy at `3a99bd7`, registering as a MAC with no attestation) is a hub the phone vouches for, so the interop runs vouch → promote end to end without waiting for Go hub Phase 2 Task 10. It takes over Go hub Phase 2 Task 12's Kit half; that task keeps the headless-host checks.
  - Cost if wrong: a second harness if the Go hub session prefers its own.
- **R16. The relay CI job is the relay session's; Phase 3a provides its entry point.**
  - Why: spec §12 p. 4 lists the job under what we need from the relay repository (ask #734). Task 14 gives it two non-interactive commands with a summary line.
  - Cost if wrong: none for this repository.
- **R17. The Kit pins relay `bcca870`.**
  - Why: it is relay `main` and deployed on staging, and it holds both what Phase 3 needs: `Changes.resync` (PR #3, `1c6e9e0`) and vouched hubs (PR #5). Task 17 runs first in lane A, so every relay task builds on that proto. The Go copy moves on its own train (#1345); the wire is additive, so a Go hub at `3a99bd7` and a Kit at `bcca870` interoperate.
  - Cost: none known; moving again is `make relay-proto REF=<commit>`.
- **R21. The phone vouches with a serialized assertion and a fresh nonce per attempt.**
  - Why: `proto/README.md` "Vouched hubs" client rules. Login and `vouch_hub` share the App Attest counter, so `RelayAttestor` generates one assertion at a time and the next only after the previous request returned; `NOT_FOUND` and `SLOT_LIMIT` are checked after the nonce and counter were spent, so every retry takes a new `VOUCH` nonce and assertion. `ATTESTATION_FAILED` retries once, then the lost-key path, then once more; the hash is pinned by the relay's vector.
  - Cost if wrong: a vouch that fails against a login racing it, which the serial queue rules out.
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

1. **Split and dark ship (R1, External dependencies).** Phase 3 splits into 3a (Tasks 1–18, vouch included now that relay `bcca870` ships it), shippable now, and 3b (Tasks 19–21), blocked on Go hub Phase 3. 3a ships with no Release relay origin, against spec §4's "default the production origin", until §12 p. 5. What still runs in a Release build is listed in full under Global Constraints, "Dark ship" (v4 codes, epoch retention and `epoch_ack`, the rule 14 reseal, the follower on CloudKit that finds nothing until a Go hub can switch, one registry migration). The deviation from spec §4 is the author's: no production origin exists (E7), and the relay refuses pairing to a phone that cannot pay before Phase 4. Refused → Phase 3 waits for E4 as one phase, and the origin needs a value that does not exist yet.
2. **The link route rule (R4).** A v4 code links over the hub's current transport. A phone that cannot use Relay is refused for a Mac on Relay on every path, the iCloud path included: from the code's `transport`, or, when the code has none or is stale, from the hub's transport marker or a `hub_on_relay` control read in the link's completion fetch, or later on a link that never came alive (no heartbeat after its `linkedAt`), which then ends with the same copy as a notice. The alive/never-live boundary is the author's: a link that was alive is kept and follows Task 11, because its Mac can switch back. Refused for that part → every link that gets `hub_on_relay` on a phone that can't use Relay ends, alive or not. The copy is "<Mac> runs over Relay / This iPhone can't use Relay, so it would get no updates from it. Link it when the Mac is back on iCloud.", instead of spec §8's iCloud link that only receives `hub_on_relay`; no relay failure offers **Link over iCloud**, because each arises only for a Mac on Relay; a relay-only hub is refused with "<hub> works over Relay only / Relay isn't available on this iPhone". This copy reaches production phones from headless-host codes. Also: a failed paying check refuses with "Couldn't reach Relay" instead of falling back to iCloud; three Macs in slots shows mockup section 6's "Add Mac" screen with **Remove** (unlinks a Mac on this iPhone, or only frees an unknown slot) and without its "Or add this Mac over iCloud"; the replacement limit shows its own text, not the relay's message (`proto/README.md`: messages are for logs). Refused → a Mac on Relay links over iCloud as spec §8 says and the phone shows `hub_on_relay`'s Not delivered lines; `LinkRoutePolicy`, the slots screen and the Task 8 copy change.
3. **Pairing order, confirmed links and their residual (R5, R21).** The slot pre-check comes before `open_pairing`; vouch, then promote, only after the keys arrived. From the owner's confirmation on, the link is kept in `store.promoted` (`.confirmed`, `.promoteSent`, `.promoted`, `.needsOwner(reason)`); **every definite refusal of vouch or promote, in the live flow or on a retry after a relaunch, `PAIRING_EXPIRED` included, moves it to `.needsOwner` with the keys kept**, and only the owner's Cancel deletes them. Each state is a Settings → Macs row with **Try Again** and **Cancel** that never holds the link screen and never blocks scanning another hub; the row's copy follows the refusal ("The link timed out on Relay. Try again, or cancel it.", "Relay already has 3 Macs…", "Too many Mac changes on Relay…", "Relay isn't active on this iPhone…", "<Mac> isn't on Relay yet…", "Relay didn't confirm the link…", "Update Watchtower to finish this link…"). Try Again opens a new slot where needed and writes no hello (the Go hub learns the phone from the first hello and names it in `set_hub_readers` whatever slot is promoted: `internal/hub/link/hello.go:79`, `relay.go:279-288`); a fresh scan of the same hub's code does the same. `SLOT_LIMIT` before the confirmation shows the three-slots screen inline; after it, the link is `.needsOwner(.slotsFull)` and its row's **Manage Macs** opens that screen. After a removal on that screen the confirmed link goes on by itself (vouch, promote), with no extra Try Again: the owner opened the screen from that link's row to make room for it (author's decision; the removed Mac is unlinked in full, R14). Refused for that part → after the removal the row shows **Try Again** and waits. The resumer acts per state: `.confirmed` vouches and promotes; `.promoteSent` asks the account state first and promotes again only when the Mac holds no slot and the slot is still open (else `.promoted` or `.needsOwner`); `.promoted` only runs `prepare`/`linked`; `.needsOwner` waits for the owner. A slot removal is never retried for a Mac any local link names. Cancel tries the farewell for at most 10 s, calls `remove_slot` whether or not the farewell went out (a failed removal kept and retried at launch), and removes the local state either way; the Mac learns from the freed slot and keeps the phone in its device list until the owner removes it there. `FORBIDDEN` is never read as a removal in Phase 3. Refused → a refusal after the confirmation fails the link and deletes the keys at once (the owner scans again), and the link screen waits on a resuming link.
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
9. **Cross-plan interop ownership (R15).** This plan's Task 13 adds `internal/hub/interop_kit_test.go` (Go, test only, `-tags interop`) and `scripts/relay-interop-kit-hub.sh`, and runs link, vouch, promote, actions and unlink against the real Go hub on the stand at `bcca870`. It takes over Go hub Phase 2 Task 12's Kit half; that task keeps the headless-host checks. Refused → Task 13 shrinks to a Kit test against the Go phone emulator's expectations, and Go hub Phase 2 Task 12 keeps the whole interop.
10. **Tasks 17 and 18 are now part of what this plan approves.** Relay `bcca870` (PR #5, deployed on staging) shipped vouched hubs and contains PR #3, so Task 17 pins it and Task 18 builds the phone's `vouch_hub` (`GetChallenge{VOUCH}` → assertion → `vouch_hub`, then promote within 10 min; the server's refusal order; a new nonce and assertion per retry; assertions serialized with login; the relay's hash vector), with vouch → promote in Task 10. Refused → Tasks 17 and 18 go back to drafts and Task 10 promotes without a vouch, which `bcca870` refuses with `HUB_NOT_VOUCHED`: no relay link would work. Tasks 19–21 stay drafts, not approved here; each is re-planned and approved when Go hub Phase 3 lands.

Already approved, listed for reference only:

- the Keychain key id next to `relay_auth` with `AfterFirstUnlockThisDeviceOnly`, and the App Attest entitlement per configuration (ask #854, ask #799);
- the routing test's name and place (Phase 2 R16, ask #854);
- the `pair/<slot>` zone in Phase 3 (Phase 2 Owner approval 6, ask #854);
- 7-day retention for every rotation (ask #843; R8 only applies it on the phone and sets the cap).
