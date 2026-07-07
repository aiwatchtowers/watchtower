# Watchtower Mobile — Plan 6: Packaging (Real CloudKit, Notifications, TestFlight) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The feature leaves the simulator: real CloudKit transport on both halves, silent-push-driven sync with local notifications, the live-API smoke, and a TestFlight-ready archive lane.

**Architecture:** Everything was built behind seams for exactly this plan: the mobile transport swap is four documented steps in `AppEnvironment` (entitlement-probed — unsigned dev/CI builds keep the InMemory+DemoSeed path unchanged); the desktop already constructs `CloudKitTransport` behind its availability probe and only lacks entitlements on the signed .app. Notifications follow the spec's split: the desktop tags slice rows with `notifyLevel` (the AI already prioritized — the phone stays dumb), CloudKit silent pushes wake the hydrator, and the phone raises LOCAL notifications for fresh high-level rows. The BYOK wire freeze finally meets the real server in a key-gated smoke suite.

**Tech Stack:** CloudKit (CKSyncEngine path from Plans 2-3), UserNotifications, xcodegen signing config, xcodebuild archive/export, Anthropic Messages API (live).

## Global Constraints

- Container ID is FROZEN: `WatchtowerCloud.containerID = "iCloud.com.aiwatchtowers.watchtower"` — entitlements must provision exactly this; never introduce a second identifier.
- All Plan 3-5 wire contracts and design decisions still bind. `notifyLevel` is a wire-format ADDITION and must follow the `isError` precedent: optional field, nil omitted, every pre-existing frozen fixture stays byte-identical.
- Secrets discipline: `DEVELOPMENT_TEAM` and any App Store Connect identifiers live in a gitignored `WatchtowerMobile/Signing.xcconfig` (committed `Signing.xcconfig.template` documents the shape). Never commit a team ID, provisioning profile, or ASC key.
- CI stays green WITHOUT signing: simulator jobs keep `CODE_SIGNING_ALLOWED=NO`; signing settings apply only to device/archive destinations. The live smoke SKIPS without its env key — CI never needs an Anthropic key.
- USER GATES are explicit steps the owner performs (Apple Developer portal, Xcode first-run signing, App Store Connect app record, physical-device checks). A task blocked on a user gate reports BLOCKED with exactly what's needed — it does not improvise around signing.
- Baselines at plan start: Kit `Executed 213`, mobile 41 (1 documented skip), desktop 964+92, lint 0 both, sentrux baseline 62.
- English for all code/comments/GitHub text.

## Design Decisions (fixed — deviations need owner approval)

1. **Transport selection is probe-driven, not build-flag-driven**: `AppEnvironment.init()` checks the CloudKit entitlement (same `com.apple.developer.icloud-container-identifiers` probe the Kit transport uses, exposed as a small internal helper) — entitled → real `TransportStore`+`CloudKitTransport` (the four swap steps), not entitled → today's InMemory+DemoSeed. One binary serves signed device builds and unsigned sim/CI builds.
2. **DemoSeed runs ONLY on the in-memory path.** A real-transport install starts empty and hydrates from the user's own zone (spec onboarding: "replica hydrates automatically, zero configuration").
3. **`notifyLevel` is computed desktop-side in SlicePublisher** and carried as an optional field in slice row payloads: `"urgent"` (inbox item with priority high + status pending), `"briefing"` (today's briefing row on its first publish). Calendar-conflict level is OUT of v1 (needs the day-plan conflict engine; ledger it). The phone NEVER re-derives importance.
4. **Local notifications are raised by the hydrator's consumer**, not CloudKit visible pushes: silent push (`content-available`) → `hydrateOnce` → post-batch hook reports newly-applied records with a notifyLevel → `NotificationCenter` (the app-level coordinator) → `UNUserNotificationCenter` local alert. Dedup by recordName + modifiedAt (a re-publish of the same row does not re-alert): store the last-alerted watermark in `replica_meta`.
5. **Permission ask is contextual**: first successful real-transport hydration with an alertable row → one-time `UNUserNotificationCenter.requestAuthorization` prompt, never on cold launch (spec: no prompts before value is visible). Declining is remembered; Settings shows the state.
6. **CKSyncEngine owns subscriptions/push registration** (it does this internally); the app side only implements `UIApplicationDelegate.didReceiveRemoteNotification` → `transport.handleRemoteNotification(userInfo)` → hydrate/poll nudge. RelayFeed's 5 s poll and hydrator's 30 s loop STAY as the fallback cadence on device v1 — tune only after real-device observation (ledgered).
7. **Live smoke = one XCTest suite, key-gated**: `ANTHROPIC_LIVE_KEY` env var absent → `XCTSkip`. Two tests, both `claude-haiku-4-5` and `max_tokens ≤ 256` (cheapest real validation): raw `AnthropicClient` round-trip pins the frozen request format against the real server; one `DirectAPIAgent` turn with a real `list_targets` tool round over a fixture replica. `make smoke-live` runs just this suite.
8. **App icon is generated, flat, scripted** (`scripts/mobile-icon.sh`, sips/ImageMagick from a simple layered glyph) — TestFlight requires a full icon set; art comes later, the lane must not block on it.
9. **Archive lane is a make target** (`make mobile-archive`): xcodebuild archive (generic/iOS, Release, signing from Signing.xcconfig) + `-exportArchive` with an app-store-connect export plist. The UPLOAD is a user gate (Xcode Organizer / Transporter first time; ASC API key automation is out of v1).
10. **Desktop entitlements ride the existing `make app` signing lane** — add the CloudKit container + push entitlement to the .app's entitlements file; the existing availability probe turns the hub on by itself once the signed build runs.

---

### Task 1: Signing scaffolding + mobile entitlements (USER GATE at the end)

**Files:**
- Create: `WatchtowerMobile/WatchtowerMobile.entitlements` (iCloud container `iCloud.com.aiwatchtowers.watchtower`, CloudKit services, `aps-environment: development`, background modes `remote-notification` go to Info.plist keys)
- Create: `WatchtowerMobile/Signing.xcconfig.template` (+ gitignore `Signing.xcconfig`)
- Modify: `WatchtowerMobile/project.yml` (entitlements path, Info.plist `UIBackgroundModes: [remote-notification]`, per-config signing: simulator/CI keeps unsigned, device+archive configs read `Signing.xcconfig` via optional include), regenerate `.xcodeproj`
- Test: existing suites (config change — the proof is the build matrix)

**Interfaces:** none new — build configuration only.

- [ ] Entitlements + template + gitignore + project.yml (xcodegen `mobile-gen`); document each key with one comment line
- [ ] Gates: `make mobile-build` AND `make mobile-test` still green UNSIGNED (CI parity — the critical regression check); `xcodebuild -showBuildSettings` for a device destination shows the entitlements wired
- [ ] Commit: `feat(mobile): CloudKit + push entitlements, signing scaffolding (unsigned CI unchanged)`
- [ ] **USER GATE (report, don't block the next tasks):** owner fills `Signing.xcconfig` with `DEVELOPMENT_TEAM`, opens the project once in Xcode with automatic signing to mint the container + profiles on the portal

### Task 2: Probe-driven transport swap in AppEnvironment

**Files:**
- Modify: `WatchtowerMobile/Sources/App/AppEnvironment.swift` (the four documented swap steps behind the probe; DemoSeed gated to the in-memory path; `transportLabel` reflects which)
- Modify: `WatchtowerKit/Sources/WatchtowerKit/CloudKitTransport/CloudKitTransport.swift` (expose the existing entitlement probe as `public static func entitlementPresent(containerID:) -> Bool` — it exists as a private helper; do NOT change its logic)
- Test: `WatchtowerMobile/Tests/ReplicaWiringTests.swift` additions

**Interfaces:**
- Consumes: the four-step swap doc at AppEnvironment.swift:20-29; `TransportStore(path:)`, `CloudKitTransport(store:)`, `transport.start()`, hydrator/feed `pull` hooks.
- Produces: `AppEnvironment.transportKind` (enum `.cloudKit`/`.inMemoryDemo`, drives `transportLabel` + Settings display + DemoSeed gate).

- [ ] TDD: designated-init tests already inject transports — add: probe-false env → in-memory + demo seeded (today's behavior pinned); a `transportKind`-forced env → NO DemoSeed rows, transport label correct; sim boot-check unchanged (probe false on unsigned sim)
- [ ] Implementation: probe → branch in `init()`; `cloudkit-transport.sqlite` next to the replica; `await transport.start()` in bootstrap on the cloudKit path; both `pull` hooks wired
- [ ] Gates: Kit suite, `make mobile-test` + boot-check (still demo on sim), lint 0
- [ ] Commit: `feat(mobile): probe-driven CloudKit transport swap — signed builds go live, sim stays demo`

### Task 3: notifyLevel — desktop half (wire addition + SlicePublisher tagging)

**Files:**
- Modify: `WatchtowerKit/Sources/WatchtowerKit/Sync/SliceRecord.swift` (or the row payload coder site — find where slice payload dictionaries are built) — optional `notifyLevel` field, nil omitted, `isError` precedent
- Modify: `WatchtowerDesktop/Sources/Services/MobileHub/SlicePublisher.swift` — compute per Decision 3 ("urgent": inbox pending+high; "briefing": first publish of today's briefing row — track "first" via the sidecar hash state it already keeps)
- Test: Kit fixture tests (old fixtures BYTE-IDENTICAL — the freeze proof) + `WatchtowerDesktop/Tests/MobileHub/SlicePublisherTests.swift` additions

**Interfaces:**
- Produces: `SliceRecord.notifyLevel: String?` (raw values `"urgent"`, `"briefing"`); mobile reads it in Task 4.

- [ ] TDD: Kit — a fixture WITH notifyLevel round-trips; every pre-existing fixture literal untouched and green (byte-freeze pin). Desktop — high+pending inbox row published with "urgent"; medium/resolved rows publish with nil; today's briefing first publish carries "briefing", the re-publish of the SAME briefing does not (sidecar-hash-driven), tomorrow's does
- [ ] Gates: Kit suite, desktop suite, relay fixtures untouched, lint 0
- [ ] Commit: `feat(kit,desktop): notifyLevel slice tagging — desktop decides what matters`

### Task 4: notifyLevel — mobile half (silent push wake + local notifications)

**Files:**
- Create: `WatchtowerMobile/Sources/App/NotificationCoordinator.swift` (@MainActor; consumes the hydrator hook; dedup watermark in replica_meta via a small Kit accessor; contextual permission ask per Decision 5; raises UNNotificationRequest — title/body per level: urgent → item snippet, briefing → "Your briefing is ready")
- Modify: `WatchtowerKit/Sources/WatchtowerKit/Replica/ReplicaHydrator.swift` — post-batch hook surfacing newly-applied records (recordName, kind, notifyLevel, modifiedAt); follow the `onActionApplied` hook precedent (fire-and-forget after persist)
- Modify: `WatchtowerMobile/Sources/App/WatchtowerMobileApp.swift` — UIApplicationDelegateAdaptor: `didReceiveRemoteNotification` → transport nudge + `hydrateOnce`; registerForRemoteNotifications on the cloudKit path only
- Modify: `WatchtowerMobile/Sources/Features/SettingsView.swift` — notifications state row (authorized/denied/not-asked)
- Test: Kit hook tests; `WatchtowerMobile/Tests/NotificationTests.swift` (coordinator logic with a UNUserNotificationCenter seam — protocol over the two calls used)

**Interfaces:**
- Consumes: Task 3 `notifyLevel`; hydrator hook.
- Produces: `ReplicaHydrator.onRecordsApplied: (([AppliedSliceRecord]) -> Void)?` where `AppliedSliceRecord = (recordName: String, kind: SliceKind, notifyLevel: String?, modifiedAt: Date)`.

- [ ] TDD: hook fires once per batch with only newly-applied records (monotonic guard interplay — a stale batch fires nothing); coordinator — urgent row → one alert; same row re-applied → zero (watermark); two new rows one batch → two alerts; permission not-yet-granted → asks once THEN posts; denied → silently skips, Settings state reflects
- [ ] Gates: Kit suite, mobile suite + boot-check, desktop untouched, lint 0
- [ ] Commit: `feat(mobile): silent-push wake + local notifications from desktop notifyLevel`

### Task 5: Live-API smoke (the wire freeze meets the real server)

**Files:**
- Create: `WatchtowerKit/Tests/WatchtowerKitTests/LiveAPISmokeTests.swift` (key-gated per Decision 7)
- Modify: `Makefile` (`smoke-live` target: `ANTHROPIC_LIVE_KEY` pass-through, runs only this suite)
- Test: the suite IS the deliverable

**Interfaces:** consumes AnthropicClient/DirectAPIAgent/ReplicaToolbox as shipped — ZERO production changes allowed in this task; a live failure is a FINDING for the controller (the frozen format would be wrong), not something to patch silently.

- [ ] `testLiveRequestFormatAccepted`: haiku, max_tokens 64, no tools — full SSE round-trip, assert non-empty text + `finished(end_turn)`; `testLiveToolRoundExecutes`: haiku, the 12 tools, a prompt engineered to force `list_targets` ("Use the list_targets tool and tell me how many targets exist") over a 2-row fixture replica → assert the thread completes and mentions the count. Both `XCTSkip` without the key; both assert the key never appears in any failure output
- [ ] Gates: full matrix WITHOUT the key (both skip — CI safe); then `make smoke-live` ONCE with the owner's key (controller/user provides at runtime, never persisted) — paste the Executed line into the report
- [ ] Commit: `test(kit): live-API smoke — key-gated validation of the frozen BYOK wire format`

### Task 6: UX polish batch (carried ledger)

**Files:**
- Modify: `WatchtowerKit/Sources/WatchtowerKit/Agent/DirectAPIAgent.swift` (empty/refusal turn: `completeTurn` with seq 0 + empty buffer → readable copy "The model returned no answer (possibly refused). Try rephrasing." as a normal completed turn, NOT isError)
- Modify: `WatchtowerMobile/Sources/Features/ChatView.swift` (direct-mode waiting hint past `unreachableAfter`: neutral "Still thinking…" — reuses the existing TimelineView; sessions list row gets a small `bolt` glyph for direct-flagged sessions)
- Test: Kit (empty-turn copy), mobile (hint state function; badge presence via ChatSession.directMode)

**Interfaces:** none new.

- [ ] TDD per above (three small behaviors, three tests)
- [ ] Gates: Kit, mobile + boot-check, lint 0
- [ ] Commit: `polish(mobile,kit): empty-turn copy, direct waiting hint, session list badge`

### Task 7: Desktop entitlements + icon + archive lane

**Files:**
- Modify: desktop entitlements file used by `make app` (find it via the Makefile signing lane) — add the CloudKit container + `com.apple.developer.aps-environment`
- Create: `scripts/mobile-icon.sh` + generated `WatchtowerMobile/Sources/Assets.xcassets/AppIcon.appiconset` (Decision 8)
- Modify: `WatchtowerMobile/project.yml` (asset catalog, `CFBundleShortVersionString`/`CFBundleVersion` seed 1.0/1, export plist), `Makefile` (`mobile-archive` per Decision 9)
- Test: build matrix

**Interfaces:** none new.

- [ ] Icon script + assets; archive target; desktop entitlements
- [ ] Gates: `make app-dev` still builds+signs; `make mobile-build`/`mobile-test` green; `make mobile-archive` reaches the SIGNING step and reports cleanly if Signing.xcconfig is absent (a helpful error, not a cryptic xcodebuild dump)
- [ ] Commit: `feat(build): desktop CloudKit entitlements, mobile app icon + archive lane`
- [ ] **USER GATE:** with Signing.xcconfig filled — `make mobile-archive` end-to-end, App Store Connect app record, first upload via Organizer/Transporter, TestFlight internal testing invite

### Task 8: End-to-end verification pass + docs

**Files:**
- Modify: `docs/app-guide.md` (notifications paragraph; transport states), `docs/superpowers/plans/2026-07-07-mobile-app-plan-6-notes.md` (create: residual ledger — cadence tuning after device observation, calendar-conflict notifyLevel, ASC upload automation, prefix removal once version floor exists, frozen-token dead-relay mitigation)
- Test: full matrix + a written DEVICE CHECKLIST for the user

**Interfaces:** none.

- [ ] Full matrix: Kit, desktop, mobile, boot-check, lint, sentrux (bump if drifted — established flow)
- [ ] Device checklist (docs/superpowers/plans/plan-6-device-checklist.md): desktop signed build → enable Mobile sync → phone TestFlight install same Apple ID → replica hydrates → swipe action lands on Mac → chat via relay → Mac asleep → 45 s → BYOK offer → direct answer → notification on urgent inbox item. Each step with the expected observable outcome
- [ ] Commit: `docs: plan 6 wrap — device checklist, notifications guide, residual ledger`

---

## Self-review notes

- Spec coverage: Section 3 notifications (T3+T4), Section 4 onboarding zero-config (T2 probe + DemoSeed gate), security bullets (entitlements T1/T7, no new key surfaces), error handling quotaExceeded/no-account (already shipped in Plan 2/3 status paths — device checklist verifies visibility).
- Carried ledger coverage: live smoke MUST-DO (T5), refusal copy + hint + badge (T6), dev-sim key volatility (resolved by T1 entitlements — signed dev builds get real Keychain), cadence tuning + calendar conflicts + ASC automation (T8 notes).
- Type consistency: `transportKind` (T2) consumed by DemoSeed gate + Settings; `notifyLevel` (T3) consumed by T4 hook; `AppliedSliceRecord` defined T4.
