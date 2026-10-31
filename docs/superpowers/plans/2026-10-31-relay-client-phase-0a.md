# Relay client Phase 0a — CloudKit leaks above the transport seam Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move every CloudKit-specific type and call above `CloudSyncTransport` on the phone and in the Kit behind neutral types (`RecordOrigin`, `HubRoute`, `LinkInvitation`, `LinkAccess`, `PushWake`, `LiveTransport`, the phone's `TransportFactory`), so Phase 1 and Phase 2 can plug in the hosted relay — with no behaviour change on CloudKit and no relay code. The hub side (`TransportAuthorPolicy`, `PhoneAccessService`, `HubTransportFactory`) is the Go hub's (ask #802); the Swift Desktop hub stays as it is until the Go hub replaces it.

**Architecture:** The neutral types live in the Kit (`WatchtowerSync/Sync/`, `WatchtowerSync/Link/`); every CloudKit implementation lives in `WatchtowerSync/CloudKitTransport/` (Kit), in `CloudKit*`-named files on the phone, and in the phone's `TransportFactory`. Today's bodies move unchanged behind the new protocols; phone callers switch from `CloudDatabaseScope` to `HubRoute`, from `CloudKitTransport` casts to `LiveTransport`, from direct construction to the factory. The Desktop is touched only where it compiles against a changed Kit type (Task 1's `CloudRecord` fields). `HubRoute.hostedRelay` and `AlertSource.inline` exist as cases only: every 0a path that meets them refuses with a typed error.

**Tech Stack:** Swift 5.10 language mode, SwiftUI, GRDB (SQLCipher fork), CloudKit / CKSyncEngine; packages `WatchtowerKit` (`WatchtowerSync`), `WatchtowerDesktop`, `WatchtowerMobile` (xcodegen, iOS 17), XCTest.

**Spec:** `docs/superpowers/specs/2026-10-29-relay-client-design.md` — §3 "Layers today and the seam" (the leak table) and §13 row 0a after ask #802 (phone and Kit only; board #1237). Feature note: `docs/features/mobile-companion.md`.

## Global Constraints

- **No behaviour change on CloudKit.** Every moved body is today's body; every existing test keeps its assertions. A test may change only where it constructs a renamed type or passes a renamed argument.
- `CloudSyncTransport` keeps exactly its three requirements (`save`, `delete(recordNames:in:)`, `changes(in:since:)`); new surface comes only through optional protocols (spec Decisions, ask #799). `InMemoryCloudTransport` and the phone's test transports conform to nothing new.
- Not in 0a (§13): `ConditionalTransport`, `MailboxAddressing`, `PagedChanges`, `CloudRecord.recordSeq`, `LinkPayload` v4, `TransportKind`, any `HostedRelay*` type, the `route_kind` column (Phase 3 adds it with its first writer).
- Existing "Relay" names keep their meaning (§2): `RelayZone`, `RelayProcessor`, `RelayFeed`, `CloudZoneID.relay`, `KeyDerivation.zoneByte` — untouched. Wire names, AAD bytes, `TransportStore` columns (`events.creator`, `events.server_modified_at`) and every persisted value keep their exact bytes.
- Inventory guards stay byte-identical: `WatchtowerDesktop/Tests/MobileHub/SessionInputHandlersTests.swift`, `PermissionAnswerHandlersTests.swift`, `PermissionRequestSliceTests.swift`, `WatchtowerKit/Tests/WatchtowerSyncTests/PermissionAllowRuleTests.swift`, `WatchtowerMobile/Tests/PermissionCardTests.swift`, `WatchtowerMobile/Tests/SessionInputWiringTests.swift` (PROJ-16, PROJ-21). Every task ends with `git diff --stat origin/main -- <those six files>` printing nothing.
- Test fakes keep their call logs: `FakeLinkContainer` (renamed `FakeLinkAccess`) keeps `accepted`/`left`/`leftHubIDs` and its `LinkEventLog` strings, so no assertion changes.
- Desktop: no hub code changes beyond Task 1's mechanical reads of `CloudRecord.origin`; no new Desktop types and no Desktop import guard (ask #802).
- A `.hostedRelay` route met by any 0a code throws `UnsupportedRouteError(route:)`; it never falls back to CloudKit.
- New phone source or test files: run `make mobile-gen` and commit the regenerated `WatchtowerMobile/WatchtowerMobile.xcodeproj` in the same task.
- Inner loop only per task: `make kit-test FILTER=…`, `make test-swift FILTER=…`, `make mobile-test MOBILE_FILTER=…`, `make lint-swift` (`make lint-diff` is Go-only). The full gate runs once, in Task 8.
- Public repo: fixtures use `acme`, `example.com`, `_owner-acme`, `_colleague-a`; no real ids.

## Review Focus

1. **Records with no origin** (an event buffered before the `creator`/`server_modified_at` columns, the in-memory transport): `author == nil` must still pass the `private` gate and fail the `shared` one, and hygiene must age by `modifiedAt`. Task 1 `testAnEventWithoutOriginReadsBackAsUnknown`; the Desktop's existing creator tests (`MobileLinkCenterTests+LinkData`) run unchanged in Task 1.
2. **Rows written before the upgrade** (a kept farewell with `owner_name` NULL or set, a `link_json` with `scope`/`ownerName`) must read back as the same route with no migration. Task 3 `testAKeptFarewellReadsBackWithItsRoute`, `testASavedLinkKeepsItsRoute`.
3. **A `.hostedRelay` route reaching 0a code** (registry write, transport factory, link join/leave, alert subscribe) must refuse loudly, never build a CloudKit transport for it. Tests in Tasks 3, 4, 5, 6.
4. **Push routing**: a shared-database push fetches only shared sessions, a non-CloudKit payload fetches every phone session, the NSE fills only a private-scope query notification. Task 6 `testOriginOfANonCloudKitPayloadIsNil`, `testAlertSourceOfANonCloudKitPayloadIsNil`; Task 7 runs `MultiHubEnvironmentTests` unchanged.

---

## Lanes

Kit first (Tasks 1, 2 in parallel), then phone 3 (after 2) → {4, 5}; PushWake 6 (after 2) → 7 (after 4, 6). Task 8 is the gate.

### Task 1: `RecordOrigin` on `CloudRecord` and `UnopenableRecord`

**Depends on:** none

**Files:**
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Sync/CloudSyncTransport.swift:35-102` (`CloudRecord`)
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Secure/SecureKeyProvider.swift:63-79` (`UnopenableRecord`)
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Secure/SecureTransport.swift:258-272,335-380`
- Modify: `WatchtowerKit/Sources/WatchtowerSync/CloudKitTransport/CloudKitTransport+Mapping.swift:125-136`, `CloudKitTransport+Engine.swift:375-386`, `TransportStore.swift:335-345,390-401`
- Modify (call sites only): `WatchtowerDesktop/Sources/Services/MobileHub/RelayProcessor.swift:232-241,776-813`, `MobileLinkCenter.swift:692,752-758` (mechanical: read `record.origin.author` in place of `record.creatorUserRecordName`; the Swift hub otherwise stays as it is, ask #802)
- Test: `WatchtowerKit/Tests/WatchtowerSyncTests/TransportStoreTests.swift:55-67,270-287`, `SecureTransportTests.swift`; Desktop test helpers `WatchtowerDesktop/Tests/MobileHub/MobileHubTestSupport.swift:455-459,661-666`, `MobileLinkCenterTests.swift:270-274,829-833`, `RelayProcessorTests.swift:336-340`, `RelayProcessorRecordingUploadTests.swift:273-276`

**Interfaces:**
- Produces (Kit, in `CloudSyncTransport.swift`):
  `public struct RecordOrigin: Equatable, Sendable { public let author: String?; public let serverAt: Date?; public init(author: String? = nil, serverAt: Date? = nil); public static let unknown: RecordOrigin }`
- Produces: `CloudRecord.origin: RecordOrigin` replacing `creatorUserRecordName` and `serverModifiedAt`; the memberwise init takes `origin: RecordOrigin = .unknown` in their place (between `assetFileURL` and `asset`). Doc comment: read-only server metadata, never sent on a save; CloudKit fills `author` from `creatorUserRecordID.recordName` and `serverAt` from `modificationDate`. The Go hub must produce the same values (the same author string and server date) for the records it reads.
- Produces: `UnopenableRecord.origin: RecordOrigin` replacing `serverModifiedAt`; init `init(wireName:modifiedAt:reason:origin: RecordOrigin = .unknown)`.

- [ ] **Step 1: Write the failing tests**
  - `TransportStoreTests.testAnEventKeepsItsOrigin` (rewrite of the creator test at :55-67): buffer one record with `origin: RecordOrigin(author: "_colleague-a", serverAt: t)` and one without; `XCTAssertEqual(changed.map(\.origin), [RecordOrigin(author: "_colleague-a", serverAt: t), .unknown])`.
  - `TransportStoreTests.testAnEventWithoutOriginReadsBackAsUnknown`: a row inserted with `creator` and `server_modified_at` NULL reads back with `origin == .unknown`.
  - The server-date test at :270-287 compares `origin.serverAt` instead of `serverModifiedAt`.
  - `SecureTransportTests.testOpeningKeepsTheRecordOrigin`: a sealed relay record carrying `origin` opens with the same `origin`; `testTheHygieneScanCarriesTheOriginOfUnopenableRecords`: a record no key opens lands in `relayHygieneScan().unopenable` with the record's `origin`.
- [ ] **Step 2: Run them, expect compile failure**
  Run: `make kit-test FILTER='TransportStoreTests|SecureTransportTests'` — Expected: FAIL, "value of type 'CloudRecord' has no member 'origin'".
- [ ] **Step 3: Implement** `RecordOrigin`, the two fields and every reader/writer above. `TransportStore` keeps its column names and maps `creator` ↔ `origin.author`, `server_modified_at` ↔ `origin.serverAt`. Desktop: `RelayProcessor` hygiene ages by `record.origin.serverAt ?? record.modifiedAt` (:799, :813); its `Origin` struct reads `record.origin.author`.
- [ ] **Step 4: Run Kit and Desktop tests**
  Run: `make kit-test FILTER='TransportStoreTests|SecureTransportTests|CloudKitTransportMappingTests|TransportAssetTests'` then `make test-swift FILTER='RelayProcessorTests|RelayProcessorRecordingUploadTests|MobileLinkCenterTests'` — Expected: PASS.
- [ ] **Step 5: Lint and guard check** — `make lint-swift`; `git diff --stat origin/main --` the six guard files prints nothing.
- [ ] **Step 6: Commit** — `refactor(kit): RecordOrigin replaces the CloudKit creator and server date on CloudRecord (#1237)`

### Task 2: Kit seam types — `HubRoute`, `LinkInvitation`, `LiveTransport`

**Depends on:** none

**Files:**
- Create: `WatchtowerKit/Sources/WatchtowerSync/Sync/HubRoute.swift`
- Create: `WatchtowerKit/Sources/WatchtowerSync/Sync/LiveTransport.swift`
- Create: `WatchtowerKit/Sources/WatchtowerSync/Link/LinkInvitation.swift`
- Create: `WatchtowerKit/Sources/WatchtowerSync/CloudKitTransport/CloudKitTransport+Live.swift` (the conformance)
- Test: `WatchtowerKit/Tests/WatchtowerSyncTests/SeamTypesTests.swift`

**Interfaces:**
- Produces:
  - `public enum HubRoute: Equatable, Sendable { case cloudKit(CloudDatabaseScope); case hostedRelay(macDeviceID: String); public var cloudKitScope: CloudDatabaseScope? }`
  - `public struct UnsupportedRouteError: Error, Equatable, Sendable { public let route: HubRoute; public init(route: HubRoute) }`
  - `public struct LinkInvitation: Equatable, Sendable { public let dataShare: String?; public let relayShare: String?; public init(dataShare: String?, relayShare: String?); public static let none: LinkInvitation }` — the QR carries it (today's `data_share`/`relay_share`), the phone joins with it; on CloudKit the two `CKShare.url` strings.
  - `public protocol LiveTransport: CloudSyncTransport, Sendable` with exactly the members the phone casts for today: `start() async`, `stop() async`, `sendNow() async`, `pull() async throws`, `fetchForPush(since: Date, grace: TimeInterval, pollOnFallback: Bool) async throws`, `availability() async -> CloudAvailability`, `setEventHandler(_: (@Sendable (TransportEvent) -> Void)?) async`, `setAccountResetHandler(_: (@Sendable () -> Void)?) async`, `setEngineFetchedHandler(_: (@Sendable () -> Void)?) async`.
  - `extension CloudKitTransport: LiveTransport {}` (no new code: every member exists in `CloudKitTransport.swift:254-282`, `+Lifecycle.swift:17,73,99,273`, `+HubZones.swift:13`, `+PushFetch.swift:24`).

- [ ] **Step 1: Write the failing tests** (`SeamTypesTests`)
  - `testHubRouteExposesItsCloudKitScope`: `.cloudKit(.shared(ownerName: "_owner-acme")).cloudKitScope == .shared(ownerName: "_owner-acme")`; `.hostedRelay(macDeviceID: "mac-acme").cloudKitScope == nil`.
  - `testLinkInvitationNoneCarriesNoShares`: both fields nil.
  - `testTheCloudKitTransportIsALiveTransportAndTheFakeIsNot`: a `CloudKitTransport` built the way `CloudKitTransportStopTests` builds one (internal init, `FakeSyncEngine`) `is any LiveTransport`; `InMemoryCloudTransport()` is not.
- [ ] **Step 2: Run, expect failure** — `make kit-test FILTER=SeamTypesTests` — FAIL ("cannot find 'HubRoute' in scope").
- [ ] **Step 3: Implement** the four files. No caller changes in this task.
- [ ] **Step 4: Run** — `make kit-test FILTER='SeamTypesTests|CloudKitTransportStopTests'` — PASS.
- [ ] **Step 5: Lint** — `make lint-swift`.
- [ ] **Step 6: Commit** — `refactor(kit): HubRoute, LinkInvitation and LiveTransport seam types (#1237)`

### Task 3: The phone addresses hubs by `HubRoute`

**Depends on:** Task 2

**Files:**
- Modify: `WatchtowerMobile/Sources/App/LinkStore.swift:33-36` (`databaseScope` → `route`)
- Modify: `WatchtowerMobile/Sources/App/Hubs/HubRegistry.swift:30-46,286-320` (`PendingFarewell.route`; read/write)
- Modify: `WatchtowerMobile/Sources/Features/Onboarding/LinkSeams.swift:50-59` (`LinkHost.prepare(route:hubID:fresh:)`)
- Modify: `WatchtowerMobile/Sources/App/Hubs/HubBoot.swift:9-48` (`HubSessionFactory.make(row, hubID, route, device)`; the live closure takes `route.cloudKitScope` or throws `UnsupportedRouteError`)
- Modify: `WatchtowerMobile/Sources/App/Hubs/HubSession.swift:187,371-386,417,478-486,514-525,536-570` (`databaseScope` → `route: HubRoute?`; `makeSharedAlerts` guards `case .cloudKit(.shared)? = route`; the registrar still gets `route?.cloudKitScope` until Task 7)
- Modify: `WatchtowerMobile/Sources/App/Hubs/SessionCadence.swift:43-52` (`PushScope.init?(_ route: HubRoute)`: nil for `.hostedRelay`)
- Modify: `WatchtowerMobile/Sources/App/AppEnvironment.swift:248-252,342-345,525-537`
- Modify: `WatchtowerMobile/Sources/App/AppRoot.swift:58-61,636-640,762-775` (`saveDirectly` gets `farewell.route.cloudKitScope` or throws `UnsupportedRouteError`; Task 4 moves it into the factory)
- Modify: `WatchtowerMobile/Sources/Features/Onboarding/LinkingViewModel.swift:263-326,460-465,806-815,958-980`
- Test: `WatchtowerMobile/Tests/Support/LinkingFakes.swift:160-180,231,320-330,400-430`, `AppRootWiringTests.swift:115-125,520,696,961`, `HubRegistryTests.swift`, the six `databaseScope:` sites in `WatchtowerMobile/Tests`

**Interfaces:**
- Consumes: `HubRoute`, `UnsupportedRouteError` (Task 2).
- Produces: `LinkRecord.route: HubRoute` (computed from the stored `scope`/`ownerName`; `link_json` is unchanged); `PendingFarewell.route: HubRoute`; `LinkHost.prepare(route: HubRoute, hubID: String, fresh: Bool) async throws -> any CloudSyncTransport`; `HubSessionFactory.make: @MainActor (HubRow?, String, HubRoute, LinkedDevice?) throws -> HubSession`; `HubSession.init(…, route: HubRoute? = nil, …)` and `HubSession.route: HubRoute?`; `HubRegistryError.unsupportedRoute`.
- `HubRegistry.savePendingFarewell` writes `owner_name` = the shared owner, NULL for `.cloudKit(.private)`, and throws `.unsupportedRoute` for `.hostedRelay` before any write. `pendingFarewells()` reads `owner_name` NULL → `.cloudKit(.private)`, else `.cloudKit(.shared(ownerName:))`.
- `LinkingViewModel.connect` builds `.cloudKit(.private)` or `.cloudKit(.shared(ownerName: payload.ownerUser))` exactly where it builds the scope today; the `leaveShares` calls stay inside `if case let .cloudKit(.shared(ownerName)) = …`.

- [ ] **Step 1: Write the failing tests**
  - `HubRegistryTests.testAKeptFarewellReadsBackWithItsRoute`: save one farewell with `.cloudKit(.private)` and one with `.cloudKit(.shared(ownerName: "_owner-acme"))` (two hubs); `pendingFarewells().map(\.route)` equals both, in `since` order.
  - `HubRegistryTests.testAHostedRelayFarewellIsRefusedAndNothingIsKept`: `savePendingFarewell` with `.hostedRelay(macDeviceID: "mac-acme")` throws `HubRegistryError.unsupportedRoute`; `pendingFarewells()` is empty.
  - `HubRegistryTests.testASavedLinkKeepsItsRoute`: a `LinkRecord` JSON as today's build writes it (`"scope":"shared","ownerName":"_owner-acme"`) decodes with `route == .cloudKit(.shared(ownerName: "_owner-acme"))`; `"scope":"private"` → `.cloudKit(.private)`.
  - Existing `AppRootWiringTests.testPreparingAnotherScopeRebuildsTheCandidateOnAnEmptyReplica` and the two other `prepare` sites call `prepare(route: .cloudKit(.private), …)`; assertions unchanged.
- [ ] **Step 2: Run, expect failure** — `make mobile-test MOBILE_FILTER=HubRegistryTests` — FAIL (no `route`).
- [ ] **Step 3: Implement** every file above; tests and fakes switch `CloudDatabaseScope` to `HubRoute` where they pass it (`LinkingFakes.prepared: [HubRoute]`, `farewells: [(route: HubRoute, hubID: String)]`, `transport(for route:)`, `deviceWrites(in route:)`, `describe(_ route:)`).
- [ ] **Step 4: Run** — `make mobile-test MOBILE_FILTER='HubRegistryTests|HubBootTests|AppRootWiringTests|AppRootRelinkTests|LinkingViewModelTests|MultiHubEnvironmentTests|SharedAlertWiringTests|SettingsWiringTests|PermissionCardTests|SessionInputWiringTests'` — PASS.
- [ ] **Step 5: Lint and guard check** — `make lint-swift`; guard-file diff empty.
- [ ] **Step 6: Commit** — `refactor(mobile): hubs are addressed by HubRoute (#1237)`

### Task 4: `LiveTransport` and `TransportFactory` on the phone

**Depends on:** Task 3

**Files:**
- Create: `WatchtowerMobile/Sources/App/Hubs/TransportFactory.swift`
- Modify: `WatchtowerMobile/Sources/App/Hubs/HubBoot.swift:12-48` (`HubSessionFactory.live(paths:keys:transports: TransportFactory = .cloudKit)`)
- Modify: `WatchtowerMobile/Sources/App/Hubs/HubSession.swift:400-405,435-440,571-576,604-619,715-736,1293-1318` (the six `CloudKitTransport` casts/checks)
- Modify: `WatchtowerMobile/Sources/App/AppRoot.swift:42-63,193-197`
- Modify: `WatchtowerMobile/Sources/App/BatteryDiagnostics.swift:25-27`
- Test: Create `WatchtowerMobile/Tests/TransportFactoryTests.swift`; regenerate the project (`make mobile-gen`)

**Interfaces:**
- Consumes: `LiveTransport`, `HubRoute`, `UnsupportedRouteError` (Task 2); `HubSession.route` (Task 3).
- Produces:
  ```swift
  struct TransportFactory: Sendable {
      /// The build can run this transport (CloudKit: `CloudKitTransport.entitlementPresent()`).
      let isAvailable: @Sendable () -> Bool
      /// A phone-role transport for `route` on `store`; `.hostedRelay` throws `UnsupportedRouteError`.
      let make: @Sendable (_ route: HubRoute, _ store: TransportStore, _ hubID: String, _ energy: EnergyCounter?) throws -> any LiveTransport
      /// One record saved outside any engine (the kept farewell, #143): CloudKit's `saveDirectly(_:scope:hubID:)`.
      let sendDirectly: @Sendable (_ record: CloudRecord, _ route: HubRoute, _ hubID: String) async throws -> Void
      static let cloudKit: TransportFactory
  }
  ```
- `HubSession` keeps `transport: any CloudSyncTransport & Sendable`; it stores `liveTransport: (any LiveTransport)?` (= `transport as? any LiveTransport`) and reads it at every former cast: the demo precondition (`!(liveTransport != nil && transportKind == .inMemoryDemo)`), `liveSaver` (`liveTransport != nil && TransportFactory.cloudKit.isAvailable()`), `cloudReach`, the boot's handler setup and `start()`, `sendNow()`, `shutDown()`. `RemoteFetchDepth` maps onto `pull()` / `fetchForPush(since:grace:pollOnFallback:)` as today.
- `AppRoot.live()` guards `TransportFactory.cloudKit.isAvailable()`; `Delivery.live.resend` calls `TransportFactory.cloudKit.sendDirectly(farewell.record, farewell.route, farewell.hubID)`; `BatteryDiagnostics.live()` reads `TransportFactory.cloudKit.isAvailable()`.

- [ ] **Step 1: Write the failing tests** (`TransportFactoryTests`)
  - `testACloudKitRouteBuildsAPhoneTransportOnItsScope`: `make(.cloudKit(.shared(ownerName: "_owner-acme")), store, "hub-acme", nil)` returns a `CloudKitTransport` whose `scope == .shared(ownerName: "_owner-acme")`.
  - `testAHostedRelayRouteIsRefused`: `make(.hostedRelay(macDeviceID: "mac-acme"), …)` throws `UnsupportedRouteError(route: .hostedRelay(macDeviceID: "mac-acme"))`; `sendDirectly` with that route throws the same before any CloudKit call.
  - `testAvailabilityIsTheEntitlementCheck`: `TransportFactory.cloudKit.isAvailable() == CloudKitTransport.entitlementPresent()`.
- [ ] **Step 2: Run, expect failure** — `make mobile-gen` then `make mobile-test MOBILE_FILTER=TransportFactoryTests` — FAIL.
- [ ] **Step 3: Implement** the factory and the call-site changes; `grep -n 'CloudKitTransport' WatchtowerMobile/Sources` afterwards finds only `TransportFactory.swift` and doc comments.
- [ ] **Step 4: Run** — `make mobile-test MOBILE_FILTER='TransportFactoryTests|FetchCadenceWiringTests|BackgroundWorkTests|AppRootWiringTests|AppRootRelinkTests|BatteryDiagnosticsTests|HubBootTests'` — PASS.
- [ ] **Step 5: Lint and guard check** — `make lint-swift`; guard-file diff empty.
- [ ] **Step 6: Commit** — `refactor(mobile): LiveTransport and TransportFactory replace CloudKitTransport casts (#1237)`

### Task 5: `LinkAccess` replaces `LinkContainer`

**Depends on:** Task 3

**Files:**
- Modify: `WatchtowerMobile/Sources/Features/Onboarding/LinkSeams.swift:4-17`
- Rename + modify: `WatchtowerMobile/Sources/Features/Onboarding/CloudKitLinkContainer.swift` → `CloudKitLinkAccess.swift`
- Modify: `WatchtowerMobile/Sources/Features/Onboarding/LinkingViewModel.swift:84,101-107,232-240,272-284,786-790,806-815,832-836,972-978`
- Modify: `WatchtowerMobile/Sources/App/AppRoot.swift:234,268`
- Test: `WatchtowerMobile/Tests/Support/LinkingFakes.swift:73-130`, `AppRootWiringTests.swift:42,194`; Create `WatchtowerMobile/Tests/CloudKitLinkAccessTests.swift`; `make mobile-gen`

**Interfaces:**
- Consumes: `HubRoute`, `LinkInvitation`, `UnsupportedRouteError` (Task 2).
- Produces:
  ```swift
  protocol LinkAccess: Sendable {
      func availability() async -> CloudAvailability          // was accountStatus()
      func identity() async throws -> String                  // was userRecordName()
      /// CloudKit shared route: today's acceptShares over the invitation's two URLs, owner = the route's owner.
      /// Private route: nothing. Hosted relay: UnsupportedRouteError.
      func join(_ invitation: LinkInvitation, route: HubRoute, hubID: String) async throws
      /// CloudKit shared route: today's leaveShares. Private route: nothing. Hosted relay: UnsupportedRouteError.
      func leave(route: HubRoute, hubID: String) async throws
  }
  enum LinkAccessError: Error, Equatable { case invalidInvitation }   // a share URL missing or not a URL
  struct CloudKitLinkAccess: LinkAccess   // init(containerID:) as today
  ```
- `LinkingViewModel.init(access:store:identity:keys:…)`; the URL guard at `:272-275` stays before `join` (so `.cannotShare` comes before any call, as today); `join` re-checks and throws `invalidInvitation` on its own.
- The fake (`FakeLinkContainer`, renamed `FakeLinkAccess`) keeps `accepted: [[URL]]` (the invitation's two URLs), `left` (the route's owner name), `leftHubIDs`, `onLeave`, and its `LinkEventLog` strings.

- [ ] **Step 1: Write the failing tests** (`CloudKitLinkAccessTests`, no CloudKit call reached)
  - `testAHostedRelayRouteIsRefused`: `join(.none, route: .hostedRelay(macDeviceID: "mac-acme"), hubID: "hub-acme")` and `leave(route: .hostedRelay(…), hubID:)` throw `UnsupportedRouteError`.
  - `testAnInvitationWithoutShareURLsIsRefusedBeforeAnyCall`: `join(LinkInvitation(dataShare: nil, relayShare: "https://www.icloud.com/share/x"), route: .cloudKit(.shared(ownerName: "_owner-acme")), hubID: "hub-acme")` throws `LinkAccessError.invalidInvitation`.
  - `testAPrivateRouteJoinsAndLeavesWithoutACall`: both return without throwing.
- [ ] **Step 2: Run, expect failure** — `make mobile-gen` then `make mobile-test MOBILE_FILTER=CloudKitLinkAccessTests` — FAIL.
- [ ] **Step 3: Implement** the protocol, the renamed service and the view-model/root changes.
- [ ] **Step 4: Run** — `make mobile-test MOBILE_FILTER='CloudKitLinkAccessTests|LinkingViewModelTests|AppRootWiringTests|AppRootRelinkTests|WelcomeTests'` — PASS, no assertion edited.
- [ ] **Step 5: Lint and guard check** — `make lint-swift`; guard-file diff empty.
- [ ] **Step 6: Commit** — `refactor(mobile): LinkAccess replaces LinkContainer (#1237)`

### Task 6: `PushWake` in the Kit; the CloudKit alert code moves into `CloudKitTransport/`

**Depends on:** Task 2

**Files:**
- Create: `WatchtowerKit/Sources/WatchtowerSync/Sync/PushWake.swift` (no CloudKit)
- Move: `WatchtowerKit/Sources/WatchtowerSync/Secure/AskAlertSubscription.swift` → `WatchtowerKit/Sources/WatchtowerSync/CloudKitTransport/AskAlertSubscription.swift` (`git mv`, body unchanged)
- Create: `WatchtowerKit/Sources/WatchtowerSync/CloudKitTransport/CloudKitPushWake.swift` (with `SubscriptionSaving` and `CloudKitSubscriptionSaver` moved from `WatchtowerMobile/Sources/App/Hubs/AlertSubscriptionRegistrar.swift:6-32`, made `public`, bodies unchanged)
- Modify: `WatchtowerMobile/Sources/App/Hubs/AlertSubscriptionRegistrar.swift:6-32` (the moved types deleted)
- Test: Create `WatchtowerKit/Tests/WatchtowerSyncTests/CloudKitPushWakeTests.swift`, `WatchtowerKit/Tests/WatchtowerSyncTests/SeamBoundaryTests.swift`

**Interfaces:**
- Consumes: `HubRoute`, `UnsupportedRouteError` (Task 2).
- Produces (`PushWake.swift`):
  ```swift
  public enum PushOrigin: Equatable, Sendable { case `private`, shared }   // today's phone PushScope, moved
  public struct AlertRecordRef: Equatable, Sendable { public let hubID: String; public let wireName: String; public let zoneName: String; public let ownerName: String }
  public enum AlertSource: Equatable, Sendable {
      case fetchRecord(AlertRecordRef)            // CloudKit: fetch the sealed ask_alert the signal names
      case inline(hubID: String, envelope: Data)  // hosted relay (Phase 4): the envelope rides in the push
      public static let inlineWireName = "alert-push"   // spec §10
      public var hubID: String { get }
      public var wireName: String { get }          // .inline → inlineWireName
  }
  public protocol PushWake: Sendable {
      /// Registers the hub's work-alert push; false when the route has none (CloudKit shared scope, D14).
      func subscribeAlerts(hubID: String, route: HubRoute) async throws -> Bool
      func unsubscribeAlerts(hubID: String, route: HubRoute) async throws
      /// Which sessions a silent push reaches; nil = not a database push of this transport (every session fetches).
      func origin(ofRemoteNotification userInfo: [AnyHashable: Any]) -> PushOrigin?
      /// The NSE's alert, nil when the payload is not a work-alert push.
      func alertSource(for userInfo: [AnyHashable: Any]) -> AlertSource?
      /// The sealed envelope for `source`, fetched within `timeout` when it must be.
      func envelope(for source: AlertSource, timeout: TimeInterval) async throws -> Data?
  }
  extension HubRoute { public var pushOrigin: PushOrigin? }   // nil for .hostedRelay
  ```
- Produces (`CloudKitPushWake.swift`): `public struct CloudKitPushWake: PushWake { public init(containerID: String = WatchtowerCloud.containerID, saver: (any SubscriptionSaving)? = nil); public static func errorCode(_ error: any Error) -> String? }` — `saver` nil means `CloudKitSubscriptionSaver(containerID:)`, built only when a subscribe/unsubscribe runs. Bodies, each today's code:
  - `subscribeAlerts`: `.cloudKit(scope)` → `AskAlertSubscription.subscription(for: scope, hubID:)`, nil → `false`, else `saver.save` → `true`; `.hostedRelay` → throws.
  - `unsubscribeAlerts`: deletes `subscriptionID(hubID:)` only when `subscription(for: scope, hubID:) != nil` (today's `AlertSubscriptionRegistrar.swift:81-83`); `.hostedRelay` → throws.
  - `origin`: today's `PushScope.init?(remoteNotification:)` (`SessionCadence.swift:55-62`).
  - `alertSource`: today's NSE guard (`NotificationService.swift:28-36`: query notification, private database, `alertReference(forSignal:)`) → `.fetchRecord`.
  - `envelope(for:timeout:)`: `.inline` → its bytes, no network; `.fetchRecord` → today's `NotificationService.fetch` (`:87-93`, the configuration's two timeouts = `timeout`) then `AskAlertSubscription.envelope(of:)`.
  - `errorCode`: `"CKError \(code.rawValue)"` for a `CKError`, else nil.

- [ ] **Step 1: Write the failing tests**
  - `CloudKitPushWakeTests` (a recording `SubscriptionSaving` fake):
    - `testAPrivateRouteSavesTheSubscription`: `subscribeAlerts(hubID: "hub-acme", route: .cloudKit(.private))` → true; the fake saved one subscription with id `"ask-alert-hub-acme"`.
    - `testASharedRouteSavesNothing`: → false; nothing saved; `unsubscribeAlerts` on that route deletes nothing.
    - `testAPrivateRouteUnsubscribeDeletesTheID`: one delete of `"ask-alert-hub-acme"`.
    - `testAHostedRelayRouteIsRefused`: subscribe and unsubscribe throw `UnsupportedRouteError`; the fake saw nothing.
    - `testOriginOfANonCloudKitPayloadIsNil`: `origin(ofRemoteNotification: ["aps": ["content-available": 1]])` is nil.
    - `testAlertSourceOfANonCloudKitPayloadIsNil`.
    - `testAnInlineSourceNeedsNoFetch`: `envelope(for: .inline(hubID: "hub-acme", envelope: Data([1, 2])), timeout: 1)` returns `Data([1, 2])`; `AlertSource.inline(…).wireName == "alert-push"`.
    - `testRoutesMapToPushOrigins`: `.cloudKit(.private).pushOrigin == .private`, `.cloudKit(.shared(ownerName: "_owner-acme")).pushOrigin == .shared`, `.hostedRelay(…).pushOrigin == nil`.
  - `SeamBoundaryTests.testOnlyTheCloudKitFolderImportsCloudKit`: walks `WatchtowerKit/Sources` (from `#filePath`); every `.swift` file with a line starting `import CloudKit` has `/CloudKitTransport/` in its path.
- [ ] **Step 2: Run, expect failure** — `make kit-test FILTER='CloudKitPushWakeTests|SeamBoundaryTests'` — FAIL.
- [ ] **Step 3: Implement** `PushWake.swift`, the move and `CloudKitPushWake.swift`, and delete the phone's own `SubscriptionSaving` / `CloudKitSubscriptionSaver` (`AlertSubscriptionRegistrar.swift:6-32`): the registrar, `HubSession` and `AlertSubscriptionTests` now resolve the Kit's public types of the same name and API, so no other phone line changes in this task.
- [ ] **Step 4: Run** — `make kit-test FILTER='CloudKitPushWakeTests|SeamBoundaryTests|AskAlertSubscriptionTests|AlertOpenerTests|WorkAlertContentTests'` — PASS; `make mobile-build` succeeds.
- [ ] **Step 5: Lint** — `make lint-swift`.
- [ ] **Step 6: Commit** — `refactor(kit): PushWake; the CloudKit alert subscription moves behind it (#1237)`

### Task 7: Pushes go through `PushWake` (phone and NSE)

**Depends on:** Task 4, Task 6

**Files:**
- Modify: `WatchtowerMobile/Sources/App/Hubs/AlertSubscriptionRegistrar.swift:1,39-91` (drops `import CloudKit`; `init(hubID:route:wake:)`)
- Modify: `WatchtowerMobile/Sources/App/Hubs/HubSession.swift:378-392,478-486,536-576` (`subscriptionSaver:` → `pushWake: (any PushWake)?`; `liveSaver` removed)
- Modify: `WatchtowerMobile/Sources/App/Hubs/TransportFactory.swift` (adds `wake: any PushWake`, `CloudKitPushWake()` in `.cloudKit`), `HubBoot.swift` (`pushWake: transports.isAvailable() ? transports.wake : nil`)
- Modify: `WatchtowerMobile/Sources/App/Hubs/SessionCadence.swift:1,41-63` (`PushScope` deleted; `import CloudKit` dropped)
- Modify: `WatchtowerMobile/Sources/App/AppEnvironment.swift:248-252` (`handlePush(at:inForeground:scope: PushOrigin?)`, compares `session.route?.pushOrigin`), `WatchtowerMobile/Sources/App/WatchtowerMobileApp.swift:121,188`
- Modify: `WatchtowerMobile/NotifyService/NotificationService.swift` (no `import CloudKit`: `CloudKitPushWake().alertSource(for:)` → `envelope(for:timeout: fetchTimeout)` → `AlertOpener(material:).open(wireName: source.wireName, envelope:)`; `errorCode` asks `CloudKitPushWake.errorCode` first)
- Test: `WatchtowerMobile/Tests/AlertSubscriptionTests.swift` (construction only)

**Interfaces:**
- Consumes: `PushWake`, `PushOrigin`, `AlertSource`, `CloudKitPushWake`, `SubscriptionSaving` (Task 6); `TransportFactory` (Task 4).
- Produces: `AlertSubscriptionRegistrar.init(hubID: String, route: HubRoute, wake: any PushWake)`; its `applyDesired` keeps today's state machine: enabled → `guard try await wake.subscribeAlerts(…) else { return }` (applied stays as it was, as today's early return), disabled → `try await wake.unsubscribeAlerts(…)`, then `applied = wanted`.
- Produces: `HubSession.init(…, pushWake: (any PushWake)? = nil, …)`; `makeAlertRegistrar` returns nil unless `kind == .cloudKit`, a route and a wake are present.
- Produces: `TransportFactory.wake: any PushWake`.

- [ ] **Step 1: Adapt the tests (the failing step)**: `AlertSubscriptionTests` builds `AlertSubscriptionRegistrar(hubID:route: .cloudKit(.private) / .cloudKit(.shared(ownerName: "_owner-acme")), wake: CloudKitPushWake(saver: fake))`, its fake conforming to the Kit's `SubscriptionSaving`; assertions unchanged.
- [ ] **Step 2: Run, expect failure** — `make mobile-test MOBILE_FILTER=AlertSubscriptionTests` — FAIL.
- [ ] **Step 3: Implement** the phone and NSE changes; `grep -rln '^import CloudKit' WatchtowerMobile/Sources WatchtowerMobile/NotifyService` prints only `CloudKitLinkAccess.swift`.
- [ ] **Step 4: Run** — `make mobile-test MOBILE_FILTER='AlertSubscriptionTests|MultiHubEnvironmentTests|FetchCadenceWiringTests|BackgroundWorkTests|SharedAlertWiringTests|NotificationRouterTests|SettingsWiringTests'`, `make mobile-build` (builds the NSE target) — PASS; `MultiHubEnvironmentTests` unchanged (its `scope: .shared` literals now type-check as `PushOrigin`).
- [ ] **Step 5: Lint and guard check** — `make lint-swift`; guard-file diff empty.
- [ ] **Step 6: Commit** — `refactor: silent pushes and work alerts go through PushWake (#1237)`

### Task 8: Phase gate and the feature note

**Depends on:** Tasks 1–7

**Files:**
- Modify: `docs/features/mobile-companion.md` — line 12 (the seam: the neutral types and where the CloudKit implementations live), line 95 (`CloudRecord.origin.serverAt`, buffered in `events.server_modified_at`), line 243 (the registrar over `PushWake`, `CloudKitPushWake`), lines 309 and 332 (the creator rides on `CloudRecord.origin.author`; the Swift hub's checks are unchanged), the Transport section's **Creator** and **Direct save and close** bullets (`origin.author`; `TransportFactory.sendDirectly`), and one new bullet under Architecture: "**Transport seam (relay client Phase 0a, #1237).**" naming `RecordOrigin`, `HubRoute`, `LinkInvitation`, `LinkAccess`, `PushWake`, `LiveTransport`, `TransportFactory`, the `.hostedRelay` refusal, the Kit import guard (`SeamBoundaryTests`), and that the hub side goes to the Go hub (ask #802) while the Swift hub stays as it is.

- [ ] **Step 1: Desktop + Kit suite** — `make test-swift > "${TMPDIR:-/tmp}/0a-swift.log" 2>&1; echo "exit=$?"` — Expected: `exit=0` (runs the Desktop suite, then the Kit suite; the Desktop compiles against Task 1's changed `CloudRecord`, so it stays in the gate).
- [ ] **Step 2: Phone suite** — `make mobile-test > "${TMPDIR:-/tmp}/0a-mobile.log" 2>&1; echo "exit=$?"` — Expected: `exit=0`.
- [ ] **Step 3: Lint** — `make lint-all` — Expected: no new issues.
- [ ] **Step 4: Guard files** — `git diff --stat origin/main -- WatchtowerDesktop/Tests/MobileHub/SessionInputHandlersTests.swift WatchtowerDesktop/Tests/MobileHub/PermissionAnswerHandlersTests.swift WatchtowerDesktop/Tests/MobileHub/PermissionRequestSliceTests.swift WatchtowerKit/Tests/WatchtowerSyncTests/PermissionAllowRuleTests.swift WatchtowerMobile/Tests/PermissionCardTests.swift WatchtowerMobile/Tests/SessionInputWiringTests.swift` — Expected: empty.
- [ ] **Step 5: Update the feature note** as listed above (English, no ids).
- [ ] **Step 6: Manual device check** (spec §11: one per phase that touches the phone): on a signed phone linked to a signed Mac — scan and link, send a session line, receive a work alert with its title filled by the NSE, pull to refresh, unlink. Each behaves as before.
- [ ] **Step 7: Commit** — `docs(mobile): the transport seam after relay client Phase 0a (#1237)`

---

## Spec notes (decisions this plan takes where the code differs from §3)

- **`LinkAccess.join`/`leave` take the route.** CloudKit needs the share owner (`LinkSeams.swift:13-16`), which lives in `HubRoute.cloudKit(.shared(ownerName:))`.
- **No `route_kind` column in 0a.** The registry keeps a hub's link as JSON (`HubRegistry.swift:89-99`, `link_json`), from which the route is derived; only `pending_farewells.owner_name` is a column (`:104-116`). Nothing writes a relay route before Phase 3, which adds the column with its writer.
- **Leaks outside the §3 table:** `CloudKitTransport.saveDirectly` in `AppRoot.swift:60` (goes into `TransportFactory.sendDirectly`, Task 4).
