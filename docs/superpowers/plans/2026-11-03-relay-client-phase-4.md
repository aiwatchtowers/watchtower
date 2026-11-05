# Relay client Phase 4 — subscription, pushes, screens, measurements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The iPhone can buy, restore and lose a Relay subscription, choose the transport per Mac, get silent pushes and inline ask alerts over the relay, tell the owner when Relay is unavailable, and show its own content-free p50/p90 timings. A Release build has no relay origin, so nothing of Relay runs for users; it does get the changes listed under "What a Release build gets", in Global Constraints.

**Architecture:**

- **Kit, `WatchtowerHostedRelay`:** `HostedRelayAccount` wraps `get_account_state` (entitlement, `moved`, slots), `submit_transaction` and `register_push` over the one `HostedRelaySession`. `FakeHostedRelay` gains the README's `submit_transaction` rules.
- **Kit, `WatchtowerSync`:** `TransportFollowerPolicy` gains the phone half of sim rule 16 (a lapse asks for CloudKit), and `SimPhone` runs it. `RelayPushWake` reads the relay's two APNs bodies. `ActionEffectKinds` and `ReplicaStore+Latency.swift` keep the timings.
- **Phone:** a `RelaySubscriptionStore` seam over StoreKit 2; `RelayAccountCenter`, one per process, the only reader of `HostedRelaySession.events`; `HubSession.requestTransport`; `RelayPushRegistrar`; the screens (Settings → Macs, the Mac's Connection, the subscription screen, the Now banners, Diagnostics).
- **Notification extension:** it opens `AlertSource.inline` with today's `AlertOpener` under `alert-push`, with no network and no relay target linked.

**Tech Stack:** Swift 5.10 language mode, Swift concurrency, StoreKit 2, StoreKitTest (`SKTestSession`), UserNotifications, GRDB, SwiftUI; `WatchtowerKit` (`WatchtowerSync`, `WatchtowerHostedRelay`, `WatchtowerHostedRelayTesting`), `WatchtowerMobile` (xcodegen, iOS 17); XCTest; Go 1.26 (one test-only file).

**Spec:** `docs/superpowers/specs/2026-10-29-relay-client-design.md`: §5 p. 6 (Not delivered, Waiting to send), §6 p. 5 (spacing, for context), §9 (switch and subscription), §10 (pushes, measurements), §13 row 4, §14 (docs), Decisions. Relay design (relay repository, `docs/superpowers/specs/2026-10-28-relay-design.md`): §3.2 p. 1 and p. 4, §4.1, §4.2, §5, §6, §9 p. 8.

**Counterparts:**

- `docs/superpowers/specs/2026-10-31-hub-phone-protocol-design.md` §4.3, §4.6, §4.8, §7.6, §11 item 5;
- `docs/superpowers/plans/2026-10-31-go-hub-phase-4.md`, "Phone contract points" 1–8;
- `docs/features/go-hub.md`, "Phase 4 — pushes, indicators, measurements" and its known limits;
- `docs/features/relay-client.md`, the current state and the v1 limits.

**Relay contract:** the Kit's pin, relay `bcca870`: `proto/README.md` ("Control events", "Errors", "Subscriptions"), `proto/relay/v1/relay.proto` (`RegisterPushToken`, `SubmitTransaction`, `AccountState`), `worker/src/push/apns.ts` (the APNs bodies), `worker/src/do/device/push.ts`, `worker/src/do/subscription.ts`.

**Mockups:** `docs/design/mockups/relay-client/index.html`, sections 3–6 today; Task 1 adds section 8.

## What the merged code gives Phase 4 (checked 2026-11-04 at `21156e0bf`)

| Fact | Where | What Phase 4 does with it |
|---|---|---|
| The alert push body is `{"aps":{"mutable-content":1,"alert":{"title":"Watchtower"}},"e":"<standard base64>"}`; the silent body is `{"aps":{"content-available":1}}`. Neither names a hub. | relay `apns.ts`; Go hub Phase 4 contract point 1 | The extension reads `hub_id` from the envelope's clear header (protocol §4.3, §4.6). A silent push wakes every relay-route session. |
| `AlertOpener` opens the Go-sealed `alertPush` under `alert-push`. | `GoSealedEnvelopeTests.testGoSealedAlertPushOpensWithAlertOpener` | Only the parsing and the extension's wiring are new. |
| `AlertSource.inline(hubID:envelope:)` exists; nothing builds it. | `Sync/PushWake.swift` | Task 11 builds it. |
| `HubRoute.pushOrigin` is nil on the relay, so a relay push reaches every session, CloudKit ones included. | `Sync/PushWake.swift`, `AppEnvironment.handlePush` | Task 11 adds `.hostedRelay`. |
| No `didRegisterForRemoteNotificationsWithDeviceToken`; a token is never read. | `WatchtowerMobileApp.swift` | Task 13. |
| `HostedRelaySession.events` has no reader in the app. | `grep` over `WatchtowerMobile/Sources/App` | Task 6's center is the one reader. |
| `client.accountID` comes only from `register`, and `register` attests afresh each time. | `HostedRelayClient.register` | Task 2 keeps the id in the Keychain (Open decision 9). |
| The fake answers `submit_transaction` "not implemented", has `moveSubscription`, and has `applyEntitlement`. | `FakeHostedRelay+Accounts.swift` | Task 2 adds the rules. |
| The stand has no App Store (`submit_transaction` → `not_implemented`) and no APNs (`send_alert` → `not_implemented`). | relay `ops.ts`, `push.ts`; `docs/features/go-hub.md` known limits | Real purchases and pushes are manual checks (below); the stand keeps `/dev/entitlement`. |
| The phone's lapse exists only in the test port (`SimPhone.lapsed`); production has no rule 16. | `SimPhone.swift:212` | Task 3 moves the decision into the policy. |
| The hub takes the phone's `transport_switch(cloudkit, reason: entitlement_expired)` as that phone's lapse. | `internal/hub/switcher/entitlement.go` | Tasks 3 and 5. No hub change. |
| `transport_switch` toward CloudKit has no phone model: only the upgrade asks toward the relay. | `RelayUpgrade.swift:307` | Task 5. |
| `HubSession.relayUnansweredSince` exists for rule 12. | `HubSession.swift:1440` | Task 10 reads it for the banner. |
| `hub_on_relay` lists Not delivered rows and keeps no flag. | `TransportFollower.swift:241` | Task 5 adds `LinkRecord.hubOnRelayAt` for the banner. |
| Desktop indicators, `send_alert`, hub latency samples and `hub phones` `alerts` are built. | `docs/features/go-hub.md`, Phase 4 | No Desktop or hub production task here. |
| `handlers.NudgeTable` maps action kind → slice kinds. | `internal/hub/actions/handlers/nudge.go` | Task 14 pins the phone's table to it with a shared fixture and a test-only Go reader. |

**Settled before this plan:** ask #1005 is answered: a proven relay-id record moves the id from another row of the hub to the proving row. That fix is merged into `feature/relay-client-next` (PR #667), so no task waits for it. The hello's relay-id proof stays deferred (3b decision 6, ask #980).

## Owner-only steps (named, never faked)

None blocks a task here; each blocks launch or the manual checks. Spec §12 p. 5.

1. App Store Connect: the subscription group, the auto-renewable product (id from Open decision 3, a real price, Family Sharing off), the Paid Apps Agreement.
2. Apple keys for the relay: the APNs `.p8` key and the App Store Server API key, through the relay session's config, plus App Store Server Notifications V2 pointing at the relay.
3. Developer portal: App Attest on the App ID (Open decision 2).
4. The production relay origin (`WATCHTOWER_RELAY_ORIGIN` for Release); until then a Release build ships dark.
5. Terms and Privacy URLs (Open decision 8), and the App Review metadata for a subscription.

## Global Constraints

- **Dark ship.** With an empty `WATCHTOWER_RELAY_ORIGIN` (every committed setting, every Release build) `RelayAvailability` is `.off(.notConfigured)`, and the app builds no relay object, creates no Keychain item, makes no DeviceCheck call and opens no relay connection (Phase 3's `testAnEmptyOriginBuildsNoRelayObject` stays green). On top of that, in this phase it **loads no StoreKit product, reads no `Transaction` stream, sends no `register_push`, and shows no Relay card, Connection section or subscription screen, and no Relay banner but the free-phone one** (it needs `hub_on_relay`, and no Mac can be on Relay before launch) (Task 6: `testAnEmptyOriginTouchesNoStoreKit`; Task 7: `testAnEmptyOriginShowsNoRelayUI`; Task 10: `testAnEmptyOriginShowsOnlyTheMacOnRelayBanner`; Task 13: `testAnEmptyOriginRegistersNoPush`).

  **What a Release build gets**, all of it, each visible change in Open decisions:
  - **the App Attest entitlement** (Task 4, Open decision 2): unused, but a signed archive fails until the owner's portal step;
  - **Settings → Diagnostics** (Task 15, Open decision 11), a new page, with iCloud timings only; the Battery section moves into it;
  - **latency stamping on CloudKit** (Task 14, Open decision 11): one small row per ordered action, on the app's own replica;
  - **the "runs over Relay" banner**, only on a phone told `hub_on_relay` (S51), which no Mac can send before launch;
  - **the alert registrar's rule** (Task 18): no change on a link that never switched, foreground retry included;
  - **the guide's Relay text** (Task 16, Open decision 16): the new page `iphone-relay.md`, a section each on `iphone-alerts.md` and `iphone-not-delivered.md`, and a line on `iphone.md`, `troubleshooting/iphone-not-syncing.md` and `README.md`; any other page that promises a phone user Relay today gets the line too, and the PR body names it. Every Relay passage a phone user can read opens with "Relay isn't in the current version of Watchtower for iPhone." The guide is embedded in the binary, so all of it reaches users;
  - **the Diagnostics text on `iphone.md`** (Task 16), which describes iCloud timings only;
  - **no Learn card about Relay on the phone:** the Go hub's `iphone-alerts-relay` card leaves until launch (Task 16);
  - the push routing (Task 11): a CloudKit push is classified as today, and a payload with `e` that CloudKit never sends falls to the generic notification;
  - `LinkRecord`'s new optional keys, absent on every CloudKit link.

  It gets **no** `MacDetailView`: the Macs list and its Forget action stay exactly as today (Task 8).
- **CloudKit unchanged.** Every existing Kit and phone test keeps its assertions, except the battery section's place (Task 15) and `HubRoute.pushOrigin` on the relay (Task 11), both named there. `CloudSyncTransport` keeps its three requirements.
- **Desktop and Go hub.** No file under `WatchtowerDesktop/Sources` changes, and no Go production file. The Go additions are two test files: `internal/hub/actions/handlers/nudge_fixture_test.go` (Task 14) and `docs/guide/relay_dark_test.go` (Task 16). Hub gaps are listed under "Hub gaps for the Go hub session", never planned as tasks here (ask #802).
- **Inventory guards** (PROJ-16, PROJ-21) are byte-identical at the end of every task: `git diff --stat origin/feature/relay-client-next -- WatchtowerKit/Tests/WatchtowerSyncTests/PermissionAllowRuleTests.swift WatchtowerMobile/Tests/PermissionCardTests.swift WatchtowerMobile/Tests/SessionInputWiringTests.swift` prints nothing.
- **Wire bytes.** The E2E vectors stay frozen (no `make e2e-vectors`). The one new contract section, `action_effect_kinds` in `WatchtowerKit/Tests/Fixtures/link/hub_contract_cases.json`, is read by both sides in the task that adds it.
- **Secrets.** Never logged, never in an error's description: the transaction JWS, the APNs token, the account id, the relay's `Error.message`, the push's envelope. Logs (`RelayAccount`, `RelayPush`, `NotifyService`) carry op names, codes and counts. New Keychain item `relay.account`: `KeyAccess.afterFirstUnlock`, never synchronizable, the app's private group, never the alerts group.
- **The notification extension** links no relay target and makes no network call on the inline path. Any failure delivers the notification as it arrived (today's rule). It writes nothing to the replica.
- **One socket per device.** Every relay call goes through the process's `HostedRelaySession` (Phase 3 R2).
- **Measurements stay on the device.** `latency_samples` holds `at`, `transport`, `answer_ms`, `result_ms`: no ids, kinds or text. `latency_pending` holds an action's id and kind and is deleted when it settles or expires. Nothing leaves the phone.
- **UI rules (the owner's, for every new or changed screen).**
  - Task 1's mockup lands before the UI task, with a frame per state: empty, loading, error with Retry, busy, narrow. A state a screen cannot reach is named in the mockup's note with the reason. The frames do not contradict the spec's text.
  - Every UI text (progress, results, errors) is defined in the model and asserted by a test in the task's `*CopyTests`.
  - Colours come only through `PhoneTone`, and each model that colours exposes `toneUses`, pinned by `OrangeToneTests`' pattern. Components come from `Sources/DesignSystem/`. No stock look, and no `CardRowDivider` in a new card or a new row.
  - After implementation, `make mobile-shots SIM='iPhone 17 Pro'` is compared with the mockup state by state; the differences go in the PR body.
- **Design shots on the phone.** The phone has no `DesignShotCatalog` (Phase 1 Ruling 14). Its equivalent is `WatchtowerMobile/Tests/ScreenshotTourTests.swift` with `ScreenshotHost.captureThree` (light, dark, narrow: iPhone SE at the largest Dynamic Type), run by `make mobile-shots`. Nothing asserts pixels; the tour asserts every file was written. Phase 3 used `R01`–`R30`; this phase uses `S01` upward, in a new `captureRelayPhase4(host:)` (a state-by-state table in Task 1). Alerts cannot be captured on iOS 26 (Phase 3's R07/R20 limit); a confirmation stays a manual check.
- **StoreKit.** All of it sits behind `RelaySubscriptionStore`. Only `StoreKitRelayStore` imports StoreKit, and its tests use `SKTestSession` with `WatchtowerMobile/Tests/Support/Relay.storekit`. A StoreKit Testing JWS is signed by Xcode's local certificate and the real relay refuses it, so the rules are tested on `FakeHostedRelay` with its `fakeJWS` and the real relay is a manual check.
- **Phone project.** A new phone source or test file needs `make mobile-gen`, with the regenerated `WatchtowerMobile/WatchtowerMobile.xcodeproj` committed in the same task.
- **Inner loop per task:** `make kit-test FILTER='…'`, `make mobile-test SIM='iPhone 17 Pro' MOBILE_FILTER='…'`, `make lint-swift` (`make lint-diff` is Go-only), `go test ./internal/hub/actions/handlers` in Task 14. Long runs go to a log with an explicit exit code: `cmd > "${TMPDIR:-/tmp}/p4-<task>.log" 2>&1; echo "exit=$?"`. Never a build or test in the background. The full gate runs once, in Task 17.
- **PRs** target `feature/relay-client-next`, never main. Whether Phase 4 merges without a device check is Open decision 14; the plan assumes it does, and the checks below go in the PR bodies.
- **Public repo.** No staging or production relay URL, real id, token or local path. Fixtures use `https://relay.example.com`, `http://127.0.0.1:8787`, "Work Mac", "Home Mac", "build-box", `acme`.

## Review Focus

1. **A purchase survives anything between Apple and the relay.** The app dies after `purchase` and before `submit_transaction`; the relay is unreachable; the JWS is refused. Expect: never finished before the relay's entitlement answer, resubmitted from `Transaction.unfinished` at the next launch, never a remembered JWS, and the owner told in plain words, also after a killed app, and on the Relay card as well as on the subscription screen. Task 6: `testAKilledPurchaseIsSubmittedAtTheNextLaunch`, `testAnUnreachableRelayLeavesTheTransactionUnfinished`, `testARestoreSubmitsAFreshTransactionNeverACachedOne`, `testARefusalAtLaunchIsShownAndSurvivesLoadProduct`, `testAnOwnerPressIsNotBoundByTheRefusedSet`. Task 7: `testAnUnconfirmedPurchaseIsNeverNotSubscribed`.
2. **A lapse or a move strands no Mac.** The phone was offline when the control went out, the socket is closed, or iCloud is unreachable. Expect: learned from `get_account_state` at the next launch, foreground or connect; the iCloud request stays queued and goes out once per Mac; every unechoed action is resent or listed. Task 3: `testALapseAsksForCloudKitOnce`. Task 5: `testALapsedHubAsksOverICloudAndResumesAfterARelaunch`. Task 6: `testAMoveLearnedFromAccountStateLapsesEveryRelayMac`.
3. **A foreign or broken push never loses the notification or reaches the network.** Malformed `e`, wrong base64 flavour, an unknown hub, an epoch no longer held, a CloudKit payload. Expect: the notification as it arrived; a CloudKit payload classified as today. Task 11: `testBrokenPushesAreNotAlerts` (table). Task 12: `testAnInlineAlertOpensWithNoNetwork`.
4. **A timing never lies about the good-network goal.** An action that waited offline, an answer other than `applied`, a route change or a relaunch midway, a kind with no effect slice. Expect: no sample, and no pending row left. Task 14: `testAQueuedOfflineWaitIsNotCounted`, `testARouteChangeDropsThePendingRow`, `testAnUnfinishedRowExpiresAfterSixtySeconds`.
5. **The Connection section never offers a dead choice.** A free phone, a Mac without a relay identity or `ordered_actions`, a relay-only hub, a 4th Mac with three in slots, a refusal kept on the record, a Mac that is closed. Expect: the row says why, with the one action that helps. Task 8: `testEveryChoiceStateHasItsCopyAndAction` (table), `testAClosedMacShowsWaitingNotAFailure`.

## Writers and races

Every piece of state these tasks write, each writer, and who wins.

| State | Writers | Who wins |
|---|---|---|
| Subscription state (`RelayAccountCenter.phase`, memory only) | relay answers from the purchase, the restore, the `Transaction.updates` listener, `get_account_state`; socket controls | The relay's last answer, serially on the main actor. A `SUBSCRIPTION_MOVED` or `ENTITLEMENT_EXPIRED` control applies at once and is corrected by the read that follows. The state is not persisted: the relay is the truth, and until it answers the card reads "Checking…". |
| `RelayAccountCenter.purchase` (memory only) | the owner's presses: `buy`, `restore`, `retryConfirm`, `screenClosed`, `loadProduct`; an `.active` or `.grace` answer from any path | Serially on the main actor. A running press is never overwritten; the settling rule touches only a finished press's state. |
| The refused id set (memory only) | the submit path adds on a definite refusal; an entitlement answer removes | One main-actor writer. It only stops the automatic paths; a press reads past it. A restart empties it. |
| `RelayAccountCenter.updateRequired` (memory only) | `.unsupportedVersion` and `.attestation(.updateRequired)` set it; `.reachable(true)` clears it | The last event, serially from the one events reader. |
| `RelayAccountCenter.unconfirmed` (memory only) | the submit path, from a press, the sweep or `updates()` | The last answer, serially on the main actor. The next sweep recomputes it from `Transaction.unfinished`, so StoreKit is the truth after a restart. |
| `relay.wasPaying` (app defaults, one flag for the ended and moved banners) | the center sets it on a paying read; the banner's **OK** clears it | One main-actor writer. A paying read after **OK** sets it again, which is right: a new subscription can end again. |
| `submit_transaction` of one transaction | the purchase flow, the `Transaction.updates` listener, the launch's `Transaction.unfinished` sweep | One flight per transaction id in the center (the second caller joins). The relay treats a repeat as idempotent (`retryOf`). `finish()` runs once, after the first entitlement answer. |
| `relay.account` Keychain item | the center's first `register` | `add`, never `write`: a lost race reads the winner's. |
| `LinkRecord.transportRequest`, `.hubOnRelayAt`, `.relayUpgrade`, `.transport` | `HubSession.requestTransport`, `RelayUpgrader`, `TransportFollower`, the lapse command, the unlink | Compare-and-set on the record (as Phase 3b). The hub's answer through the follower wins over a local request; an unlink deletes the record and any write after it is a no-op. |
| Which transport a Mac is on | any paying phone, `entitlement_expired` | The hub: the last accepted switch, with the 5-minute rule toward the relay. The phone only follows (sim rule 11). |
| `transport_switch` for one hub on the phone | the owner's choice, the banner's **Switch to iCloud**, a lapse | One open request per hub. A lapse replaces a pending request toward the relay (the same rule as the hub's "superseding"). A second press is disabled while one runs. |
| Outbox rows and `action_seq` | one session per hub | Unchanged (Phase 1). |
| APNs token on the relay | this phone only | The last `register_push` wins; each is idempotent. |
| `latency_pending`, `latency_samples` | the hub's session in the app, per hub replica | One writer per replica. The extension never writes. Diagnostics reads through `ReplicaStore`'s reader. A row settled twice is a no-op (`DELETE … RETURNING` in one transaction). |
| Delivered notifications | the extension delivers, the app's settled-alert sweep removes | Unchanged. A sweep that runs before a late push leaves that notification until the next sweep. |
| The second screen | Now's banner and Settings → Macs both call `requestTransport`; the Mac's Connection and the subscription screen read the same center | The first press sets the request; the other screen shows it as under way. |

## Hub gaps for the Go hub session (not our tasks)

- **G1. Device records on the relay.** The hub reads `device` records only in CloudKit's shared `RelayZone` (the v1 limit in `docs/features/relay-client.md`). A name change, a typing or permission request and a relay-only farewell never arrive once the phone is on the relay, so permission requests break there. Phase 4 makes this reachable by paying phones. Open decision 1 depends on it.
- **G2. A move with the old phone gone.** On a subscription move the old account's slots are revoked with no `SLOT_REMOVED` and no `ENTITLEMENT_EXPIRED`. The old phone's own `transport_switch(cloudkit, entitlement_expired)` (Task 5) covers the normal case. If that phone is wiped, nothing tells a desktop hub, whose `PayingWatch` pause applies to headless hosts only. To check there: does a desktop host with no paying phone left move to CloudKit by itself? If not, a free second phone waits on it until the owner acts.
- **G3. Duplicate alert at a switch.** `Publisher.Resignal` writes a zone-wide signal, so a phone that got the relay push can get the CloudKit push as well. Phone-side the second cannot be suppressed (Open decision 10).
- **G4. A `push_off` alert at a switch to iCloud.** Task 20's review of Phase 3b found that an alert with `push_off` gets no CloudKit signal after a switch, and left it for the Go hub. Task 18's "every open alert" holds only for alerts the hub signals, so such an alert reaches the phone on its next sync, with no notification. To check there: is that the intent of `push_off`? Until then it is a v1 limit.

## Launch conditions

Phase 4 merges into `feature/relay-client-next` without these. Relay does not turn on for users (a Release origin) until each is closed. G1–G4 are on the board under #1533 and #1537 beside it. No Go hub session runs now (ask #1015): these wait on the board, the owner assigns them, and nothing in Phase 4 depends on them.

| Condition | Owner |
|---|---|
| G1, device records on the relay | Go hub session |
| G2, a desktop hub after a move with the old phone gone: checked, and fixed if needed | Go hub session |
| G3, the duplicate alert at a switch: fixed or accepted (Open decision 10) | Go hub session, owner's ruling |
| G4, a `push_off` alert at a switch to iCloud: checked, and fixed or accepted | Go hub session, owner's ruling |
| #1537, a hello lost on a failed owner read: fixed | Go hub session |
| The Go half of Open decision 1, option A: `wire.DevicePayload` reads `work_alerts_off`, `ApplyDeviceRecord` stores it in the sidecar, `alerts.Eligible` skips the phone. **A dual path with Task 13's Kit field, changing together.** The same change moves the fixture case `work_alerts_off` from `device_payload_kit_only` into `device_payload` in `hub_contract_cases.json`, adds it to the exact-name list in `HubContractFixtureTests` and points `testDevicePayloadWorkAlertsOff` at the new section, so `device_payload` pins it on both sides | Go hub session, approved by name in Open decision 1 |
| The Learn cards `iphone-relay-subscribe`, `iphone-alerts-relay` and `headless-host-run`, and the "not in the current version" line out of every guide page that has it (with `TestRelayGuideSaysNotYet`), and `iphone-alerts.md`'s "will ask the Mac to stop sending" reworded to the present once the Go half and G1 are in, in the release that sets the origin | Relay client session |
| Group #1495, "Relay 3a: deferred review findings" (todo; its text says to close it before Relay is on) | Relay client session |
| Owner-only steps 1–5 above, the signed Release archive included (Task 17 Step 6) | Owner |
| Manual checks M1–M10 on staging | Owner, Open decision 14 |

## Lanes

- **Kit lanes, parallel, each in its own worktree:** K1 Task 2; K2 Task 3; K3 Task 11.
- **Task 14** (it also adds the Go test) starts after Task 5 has merged: both edit `ActionOutbox+Ordered.swift`. From then on it may run beside the phone lane; it touches no phone file.
- **Design:** Task 1 first; no code dependency.
- **Phone lane, serial:** every phone task that adds files regenerates the committed `xcodeproj`, and `ScreenshotTourTests.swift` and `AppRoot.swift` are shared, so the phone tasks run one after another: 4 → 5 → 6 → 7 → 8 → 9 → 10 → 13 → 18 → 15. Task 12 (`NotifyService` only) may run beside them after Task 11.
- **Joins:** Task 16 after everything; Task 17, the gate, last.

Each task's `Depends on:` is the exact list. Each parallel lane runs in its own worktree and branch, merged by the controller.

| Target | Tasks |
|---|---|
| #1243 subscription, transfer, `entitlement_expired` → CloudKit, the transport and subscription screens | 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 16, 17 |
| #1244 relay pushes | 11, 12, 13, 18, 19 |
| #1246 latency samples | 14, 15 |

Tasks 1, 16 and 17 serve all three targets and sit under #1243, the largest; their commit messages name all three.

---

## #1243 — Subscription, transfer, lapse, screens

### Task 1: Mockups: every Phase 4 phone state

**Depends on:** none (before Tasks 7–10 and 15)

**Files:**
- Modify: `docs/design/mockups/relay-client/index.html`: a new section "8. iPhone — Phase 4 states", neutral names only. Sections 3–6 stay; where a new frame replaces one, the old frame says "see 8.x".

**States.** Each frame in light and dark, plus the narrow variant of the longest text. The shot numbers are fixed here and used by Tasks 7–10 and 15. The `b` and `c` frames and S57 were added during execution, each by the task that found the state (Tasks 8, 9, 10, 15).

| Screen | State | Text (new unless marked "mockup") | Shot |
|---|---|---|---|
| Macs: Relay card | Not subscribed (empty) | "Relay" › "Not subscribed" | S01 |
| | Loading | "Checking…" | S02 |
| | Error with Retry | "Couldn't reach Relay." **Retry** | S03 |
| | Active | "Subscription" "Active"; "Macs on this subscription" "2 of 3" (mockup) | S04 |
| | Grace | "Active. Check your payment in the App Store." | S05 |
| | Ended | "Your subscription ended." **Subscribe** | S06 |
| | Moved | "Your subscription moved to another iPhone." **Restore Purchases** | S41 |
| | Purchase not confirmed | "Subscription" "Not confirmed"; "Your purchase isn't confirmed yet." › opens the subscription | S55 |
| | Busy | Not reachable: Retry shows Loading, and **Restore Purchases** (S41) opens the subscription screen, whose S44 is the busy frame | note |
| Macs: a Mac's row | iCloud; Relay with who and when; a lapse; switching | "iCloud" (mockup); "Relay · switched by this iPhone, 10:42" (mockup); "Relay · switched by another iPhone, 10:42"; "iCloud · your subscription ended, 10:42"; "Switching…" | S07 |
| | Narrow | the longest line | S07 narrow |
| Connection | Relay chosen, iCloud chosen (mockup) | "Instant, encrypted end to end"; "Free, slower"; "Applies to every phone of this Mac. Last changed by this iPhone at 10:42." | S08, S09 |
| | Free phone | Relay row "Subscribe to use Relay" › opens the subscription | S10 |
| | Too soon (mockup) | "Switching to Relay is possible again in 4 min"; "The Mac was switched less than 5 minutes ago." | S11 |
| | Mac needs an update (mockup) | "Update Watchtower on this Mac to use Relay" | S12 |
| | Mac reads no ordered actions, Relay route | iCloud row disabled, "Update Watchtower on Work Mac to change how it connects." | S12b |
| | Relay-only hub | Relay row only, "This hub works over Relay only"; on a lapse "This hub needs Relay" (spec §8) | S13 |
| | The relay gave no answer, iCloud route | Relay row disabled, "Couldn't reach Relay." | S54 |
| | Purchase not confirmed | Relay row "Your purchase isn't confirmed yet." › opens the subscription | S56 |
| | Three Macs in slots | "Your subscription already has 3 Macs." **Manage Macs** | S14 |
| | A refused iCloud request | a `TransportRequestRefusal` line with **Try Again** on the iCloud row | S49 |
| | No answer in 24 h | "Work Mac didn't answer for a day, so nothing changed. Try again when it's back." **Try Again**; after a lapse "Work Mac didn't answer for a day. It moves to iCloud when it's back." | S52 |
| | Busy, the upgrade running | "Switching to Relay…" and the step line "Getting Work Mac ready…"; rows disabled | S15 |
| | Busy, waiting for a closed Mac | "Waiting for Work Mac. It switches when it's back." | S16 |
| | Busy, toward iCloud | "Switching to iCloud…" | S17 |
| | Error with Try Again | a `RelayUpgradeRefusal.message` line (Phase 3b texts unchanged) with **Try Again** | S18 |
| | Loading | the rows disabled with "Checking…" while the account is read | S19 |
| | Loading on a Relay route | both rows "Checking…", the check on Relay, iCloud greyed: the press waits for the read | S19b |
| | Empty | Not reachable: the screen exists only for a linked Mac, and only with an available relay (no frame without the section: the row opens nothing then) | note |
| | Narrow | S16's text | S16 narrow |
| Subscription | Loaded (mockup, the price from StoreKit) | "Changes reach your phone in under a second instead of tens of seconds." (mockup); the three bullets; "Subscribe — <price> / month"; **Restore Purchases** · **Terms** · **Privacy** | S20 |
| | Loading | "Loading the price…" | S21 |
| | Error with Retry | "Couldn't load the subscription. Check your connection." **Retry** | S22 |
| | Busy, buying | "Waiting for the App Store…" | S23 |
| | Busy, confirming | "Confirming with Relay…" | S24 |
| | Busy, restoring | "Restoring…" | S44 |
| | No subscription found | "No subscription found on this Apple ID." | S45 |
| | No subscription found, no price | the same line, **Load the Price** | S45b |
| | The App Store call failed | "The App Store didn't finish. Nothing changed; you can try again." **Subscribe** | S57 |
| | The same, no price | the same line, **Load the Price** | S57b |
| | Relay account failed, nothing charged | "Couldn't reach Relay. You weren't charged." **Try Again** | S46 |
| | Pending | "Waiting for approval. Relay turns on when it's approved." | S25 |
| | Bought, relay not reached | "You're subscribed. Relay turns on as soon as Watchtower reaches it." **Try Again** | S26 |
| | Refused | "Relay couldn't confirm this purchase. Try Restore Purchases." **Manage Subscription** | S27 |
| | Transfer limit | "This subscription moved too many times this month. Try again later." **Manage Subscription** | S28 |
| | Relay takes no purchases | "Relay can't take purchases right now. You're not charged again; try again later." **Manage Subscription** | S42 |
| | App too old | "Update Watchtower from the App Store to use Relay." | S43 |
| | Done | "Relay is on. Choose it for each Mac in Macs." **Done** | S29 |
| | Empty | Not reachable: no product is an error, S22 | note |
| | Narrow | S20 | S20 narrow |
| Now banners, one at a time | Free phone, Mac on Relay (mockup) | "Work Mac runs over Relay. This iPhone doesn't get updates from it. Subscribe or switch the Mac to iCloud from a subscribed phone."; "Last update from Work Mac: 10:41" | S30 |
| | The same on a phone that cannot use Relay (Release) | "Work Mac runs over Relay. This iPhone doesn't get updates from it. Switch the Mac to iCloud from a subscribed phone."; the same second line | S51 |
| | A relay-only hub, not paying | "build-box needs Relay. Your subscription ended." **Subscribe** | S47 |
| | The same after a move | "build-box needs Relay. Your subscription moved to another iPhone." **Restore Purchases** | S53 |
| | Relay unavailable, under 10 min | "Relay unavailable for 3 min. Your changes wait on this iPhone."; **Waiting to send** · 3 | S31 |
| | Relay unavailable, past 10 min (mockup) | the same with **Switch Work Mac to iCloud** | S32 |
| | Moved (mockup) | "Your Relay subscription moved to another iPhone. This iPhone is back on iCloud." **Restore Purchases** **OK** | S33 |
| | Ended | "Your Relay subscription ended. This iPhone is back on iCloud." **Subscribe** **OK** | S34 |
| | Ended, the Mac not moved yet (text pending ask #1040) | "Your Relay subscription ended. Work Mac moves to iCloud when it's back." **Subscribe** **OK** | S34b |
| | Ended, the Mac refused | "Your Relay subscription ended." a refusal line, **Switch Work Mac to iCloud** **Subscribe** **OK** | S34c |
| | Moved, the Mac not moved yet | "Your subscription moved to another iPhone." **Restore Purchases** **OK** | S41b |
| | Moved, the Mac refused | the same line, a refusal line, **Switch Work Mac to iCloud** **Restore Purchases** **OK** | S41c |
| | Update the app (mockup) | "Update Watchtower from the App Store to keep using Relay." | S35 |
| | Busy, after the press | "Switching to iCloud…" | S36 |
| | Busy, the relay answers again | "Switching to iCloud…" alone | S36b |
| | Error with Try Again | the request's refusal line under the outage text, **Switch Work Mac to iCloud** again | S50 |
| Diagnostics | Rows (mockup, plus the Mac's-answer line) | "Action → result on screen · 7 days"; "Relay" "214 actions" "p50 0.31 s · p90 0.7 s"; "Mac's answer: p50 0.12 s · p90 0.3 s"; "Measured on this iPhone only. Nothing is sent anywhere."; the Battery section | S37 |
| | Rows, iCloud only (the Release build) | "iCloud" "214 actions" and the result lines; no Relay word | S37b |
| | Empty | "No timings yet. They appear after your first action." | S38 |
| | Empty, no linked Mac on the new action path | "Timings need an updated Watchtower on your Mac." | S48 |
| | Loading | "Reading timings…" | S39 |
| | Error with Retry | "Couldn't read the timings." **Retry** | S40 |
| | Busy | Not reachable: read-only, Retry shows Loading | note |
| | Narrow | S37 | S37 narrow |

The mockup's Diagnostics frame in section 6 shows only the end-to-end row; spec §10 says "the phone's steps". The new frame shows both, so the mockup no longer falls short of the spec's text (Open decision 4).

Section 6's frame with the moved banner and the update line together is split into S33 and S35 (Open decision 17). A note under the section says: alerts cannot be captured on iOS 26, so the Forget and Cancel confirmations are checked by hand; prices in the frames are placeholders, the real one comes from App Store Connect.

- [ ] **Step 1:** Edit the mockup, then open it in a browser and check every new frame in light, dark and narrow.
- [ ] **Step 2:** Compare each frame's text with spec §5 p. 6, §8, §9 and §10; a conflict is fixed in the frame or reported as an open decision.
- [ ] **Step 3: Commit:** `docs(design): Phase 4 phone states in the relay-client mockup (#1243, #1244, #1246)`

### Task 2: `HostedRelayAccount` and `submit_transaction` on the fake

**Depends on:** none

**Files:**
- Create: `WatchtowerKit/Sources/WatchtowerHostedRelay/Transport/HostedRelayAccount.swift`
- Modify: `WatchtowerKit/Sources/WatchtowerHostedRelay/Identity/KeychainRelayIdentity.swift` (the `relay.account` item)
- Modify: `WatchtowerKit/Sources/WatchtowerHostedRelayTesting/FakeHostedRelay+Accounts.swift` (`submit_transaction` per README "Subscriptions"; `fakeJWS`; `billingConfigured`; a log of `register_push`)
- Test: Create `WatchtowerKit/Tests/WatchtowerHostedRelayTests/HostedRelayAccountTests.swift`; extend `FakeHostedRelayTests.swift`, `KeychainRelayIdentityTests.swift`

**Interfaces (Produces):**

```swift
public struct RelayAccountState: Equatable, Sendable {
    public enum Entitlement: Equatable, Sendable { case none, active, grace, expired, revoked }
    public let entitlement: Entitlement
    public let until: Date?
    public let moved: Bool
    public let macs: [String]
    public var paying: Bool { get } // active or grace
}
public enum RelayPushEnvironment: String, Sendable { case sandbox, production }
public enum RelaySubmitRefusal: Error, Equatable {
    case invalidTransaction, transferLimit, notImplemented, unreachable, updateRequired, attestationBackoff
}
public struct HostedRelayAccount: Sendable {
    public init(session: HostedRelaySession, identity: KeychainRelayIdentity)
    /// The stored id, else `register` once and `add` it. Never re-registers while one is stored.
    public func accountID() async throws -> UUID
    public func state() async throws -> RelayAccountState
    public func submit(jws: String) async throws -> RelayAccountState.Entitlement
    public func registerPush(token: String, environment: RelayPushEnvironment) async throws
}
```

`accountID` refuses an answer that does not parse as a UUID (`HostedRelayError.undecodable`): the relay's `submit` tests the token with its `UUID_RE`, and StoreKit's `appAccountToken` is a `UUID`. `submit` retries `UNAVAILABLE` through the client's existing rule (a move waits for the revocation to land). `INVALID_TRANSACTION` → `.invalidTransaction`, `TRANSFER_LIMIT` → `.transferLimit`, `UNSPECIFIED` with "not implemented" → `.notImplemented`, a dial or 5xx failure → `.unreachable`; `.updateRequired` and `.attestationBackoff` as in `HostedRelayPairing`. `Error.message` is compared but never logged or returned.

Fake rules, from the README and `worker/src/do/subscription.ts`:
- `fakeJWS(originalTransactionID:appAccountToken:signedDate:)`: base64url of a JSON object; any other string is `INVALID_TRANSACTION`;
- the token must be the account or the account the subscription was first linked to;
- a restore or a move needs `signedDate` within 10 minutes of the fake's clock;
- a payload older than the last applied changes nothing on a held subscription and is refused on a link;
- a move runs the existing `moveSubscription`, at most 3 in 30 days (`TRANSFER_LIMIT`), and answers `UNAVAILABLE` while `holdRevocations`;
- `billingConfigured = false` answers `UNSPECIFIED` "not implemented", as the stand does;
- a submit activates but never downgrades.

Update the "does not model" list in `docs/features/relay-client.md`.

- [ ] **Step 1: Failing tests** (`HostedRelayAccountTests`, on the fake):
  - `testAccountIDRegistersOnceAndIsKept` (two calls and a new `HostedRelayAccount`: one `register` in the op log);
  - `testALockedKeychainCreatesNoAccountItem`;
  - `testAnAccountIDThatIsNoUUIDIsRefused`;
  - `testStateReadsEntitlementMovedAndSlots` (one per entitlement kind);
  - `testAPurchaseActivatesTheAccount`, `testARestoreOnANewPhoneMovesTheSubscription` (the old phone gets `.control(.subscriptionMoved)`, its `state().moved` is true);
  - `testAStaleRestoreIsRefused` (`signedDate` 11 minutes old);
  - `testAFourthMoveInThirtyDaysIsRefused`;
  - `testASubmitNeverDowngrades`;
  - `testSubmitRetriesWhileTheRevocationIsDelivered`;
  - `testNoBillingIsNotImplemented`;
  - `testRegisterPushIsSentWithItsEnvironment`, `testARefusedTokenIsAnError`;
  - `testNoMessageReachesAnError` (a server message string appears in no `RelaySubmitRefusal` description).
- [ ] **Step 2: Run, expect failure:** `make kit-test FILTER='HostedRelayAccountTests'`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run:** `make kit-test FILTER='HostedRelayAccountTests|FakeHostedRelayTests|KeychainRelayIdentityTests|HostedRelayPairingTests'`, then `make lint-swift`.
- [ ] **Step 5: Commit:** `feat(kit): relay account state, submit_transaction, register_push (#1243)`

### Task 3: The lapse in `TransportFollowerPolicy` (sim rule 16, the phone's half)

**Depends on:** none

**Files:**
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Relay/TransportFollowerPolicy.swift`
- Modify: `WatchtowerKit/Tests/WatchtowerHostedRelayTests/Sim/SimPhone.swift` (`lapsed()` runs the policy)
- Test: extend the policy's tests in `WatchtowerKit/Tests/WatchtowerSyncTests/`

**Interfaces (Produces):**

```swift
// FollowerInput
case relayLapsed
// FollowerCommand
case requestSwitch(target: TransportKind, reason: String)
// FollowerState
public var lapseRequested: Bool // reset by a move to CloudKit or a `canUseRelay` of .yes
public extension TransportFollowerPolicy { static let lapseReason = "entitlement_expired" }
```

`decide(.relayLapsed)`: sets `canUseRelay = .no`. On route `.relay` with `lapseRequested == false` it answers `[.requestSwitch(target: .cloudKit, reason: lapseReason)]` and sets the flag; on route `.cloudKit` or with the flag set it answers `[.ignore]`. The same reason serves a subscription move: the hub knows only `entitlement_expired` (`switcher.Request`), and a plain request toward CloudKit would move the whole Mac away from another paying phone (Open decision 6).

- [ ] **Step 1: Failing tests:** `testALapseAsksForCloudKitOnce`; `testALapseOnICloudAsksNothing`; `testALapseMakesRelayUnusable` (a following `transport_switched{relay}` lists unechoed actions as Not delivered, R32); `testALapseEndsWithAMoveToCloudKit` and `testPayingAgainResetsTheLapse`.
- [ ] **Step 2: Run, expect failure:** `make kit-test FILTER='TransportFollowerPolicy'`.
- [ ] **Step 3: Implement,** and route `SimPhone.lapsed()` through `decide(.relayLapsed)`, so the four entitlement twins pin the production decision. Assertions in the twins do not change.
- [ ] **Step 4: Run:** `make kit-test FILTER='TransportFollowerPolicy|RelaySimSwitchTwins|RelaySimOrderTwins|RelaySimCensusTests'`; `make lint-swift`.
- [ ] **Step 5: Commit:** `feat(kit): a relay lapse asks for CloudKit through the follower policy (#1243)`

### Task 4: StoreKit seam, its test configuration, build settings

**Depends on:** none

**Files:**
- Create: `WatchtowerMobile/Sources/App/Relay/RelaySubscriptionStore.swift` (protocol and value types), `WatchtowerMobile/Sources/App/Relay/StoreKitRelayStore.swift`
- Create: `WatchtowerMobile/Tests/Support/Relay.storekit` (a local configuration: one group, one monthly auto-renewable, `familyShareable: false`, a placeholder price), `WatchtowerMobile/Tests/Support/SubscriptionFakes.swift` (`FakeSubscriptionStore`)
- Modify: `WatchtowerMobile/project.yml` (`StoreKitTest` for the test target, the `.storekit` file as a test resource and the Debug scheme's StoreKit configuration), `WatchtowerMobile/Base.xcconfig`, `WatchtowerMobile/Info.plist`, `WatchtowerMobile/Sources/App/RelayConfig.swift`
- Modify: `WatchtowerMobile/WatchtowerMobile-Release.entitlements`: the App Attest key, production (Open decision 2; refused → this one line stays out)
- Test: Create `WatchtowerMobile/Tests/StoreKitRelayStoreTests.swift`; extend `RelayConfigTests.swift`

**Build settings:** `WT_RELAY_PRODUCT_ID` → `WTRelayProductID` (Open decision 3); `WT_TERMS_URL` → `WTTermsURL`, `WT_PRIVACY_URL` → `WTPrivacyURL`, empty by default (Open decision 8). `RelayConfig` gains `productID`, `termsURL`, `privacyURL`: an empty or unexpanded `$(` value reads as nil.

**Interfaces (Produces):**

```swift
struct RelayProduct: Equatable, Sendable { let id: String; let displayPrice: String }
struct RelayTransaction: Equatable, Sendable {
    let id: UInt64, originalID: UInt64
    let jws: String
    let revoked: Bool
    let isRenewal: Bool                 // Transaction.reason == .renewal
    let expiresAt: Date
}
enum RelayPurchaseResult: Equatable, Sendable { case purchased(RelayTransaction), pending, cancelled, unverified }
protocol RelaySubscriptionStore: Sendable {
    func product() async throws -> RelayProduct?
    func purchase(accountToken: UUID) async throws -> RelayPurchaseResult
    func unfinished() async -> [RelayTransaction]
    /// `AppStore.sync()`, then the current entitlement's fresh transaction.
    func restore() async throws -> RelayTransaction?
    func updates() -> AsyncStream<RelayTransaction>
    func finish(_ transaction: RelayTransaction) async
}
```

Only `StoreKitRelayStore` imports StoreKit. An unverified `VerificationResult` never yields a `RelayTransaction`: it is `.unverified` from `purchase`, and skipped with a log line (code only) in the streams. `updates()` starts its `Transaction.updates` task only when first called.

- [ ] **Step 1: Failing tests** (`StoreKitRelayStoreTests`, `SKTestSession(configurationFileNamed: "Relay")`, `disableDialogs`, `clearTransactions` in `setUp`):
  - `testProductLoadsWithItsPrice`;
  - `testAMissingProductIsNil`;
  - `testPurchaseCarriesTheAccountToken` (the signed transaction's `appAccountToken` equals the UUID);
  - `testAFailedPurchaseThrows` (`failTransactionsEnabled`);
  - `testAskToBuyIsPending` (`askToBuyEnabled`);
  - `testAnUnfinishedPurchaseIsListedUntilFinished`;
  - `testARenewalArrivesOnUpdates` (`forceRenewalOfSubscription`);
  - `testARefundIsReportedRevoked` (`refundTransaction`);
  - `testATransactionCarriesItsExpiry` (`expiresAt` equals the transaction's `expirationDate`);
  - `testARowWithNoExpiryIsNotATransaction` (the mapper, on plain fields: a nil expiry returns nil);
  - `testARenewalIsMarked` (`forceRenewalOfSubscription`: `isRenewal` true; the first purchase false);
  - `testASecondPurchaseOfAnActiveSubscriptionChargesNothing` (`SKTestSession`: buying again in the period adds no new period).
  `RelayConfigTests`: `testProductAndLinksReadEmptyAsNil`; `testReleaseCarriesNoOrigin` stays green; `testEntitlementsNameTheAppAttestEnvironmentPerConfiguration` is **changed**, the Release half now expects `production` (named here because it is a contract test).
- [ ] **Step 2: Run, expect failure:** `make mobile-gen`, then `make mobile-test SIM='iPhone 17 Pro' MOBILE_FILTER='StoreKitRelayStoreTests|RelayConfigTests'`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the same;** `make lint-swift`.
- [ ] **Step 5: Commit** with the regenerated project: `feat(mobile): StoreKit seam and test configuration for the Relay subscription (#1243)`

### Task 5: `HubSession.requestTransport`: asking toward iCloud, the lapse, `hub_on_relay` kept

**Depends on:** Task 3

**Files:**
- Create: `WatchtowerMobile/Sources/App/Hubs/TransportRequest.swift`
- Modify: `WatchtowerMobile/Sources/App/LinkStore.swift`: `LinkRecord.transportRequest: TransportRequestRecord?`, `.hubOnRelayAt: Date?` (JSON only, no registry migration, as Phase 3b; a record a build cannot read reads as absent)
- Modify: `WatchtowerMobile/Sources/App/Hubs/SideMailboxReader.swift` (the read while a request is open), `HubSession.swift`, `TransportFollower.swift` (executes `.requestSwitch`, sets and clears `hubOnRelayAt`, ends a request)
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Relay/ActionOutbox+Ordered.swift`: `enqueueSwitchRequest(target:id:reason:)`, `reason` optional and absent on the wire when nil
- Test: Create `WatchtowerMobile/Tests/TransportRequestWiringTests.swift`, `TransportRequestCopyTests.swift`; extend the outbox tests; `make mobile-gen`

**Interfaces (Produces):**

```swift
struct TransportRequestRecord: Codable, Equatable, Sendable {
    let target: TransportKind
    let controlID: String
    let reason: String?
    let at: Date
    var iCloudWritten: Bool
    var refusal: TransportRequestRefusal?
}
enum TransportRequestRefusal: String, Codable, Sendable {
    case unavailable, notSupported, notOrdered, macNoAnswer, lapseNoAnswer
    func message(macName: String) -> String
}
enum TransportRequestOutcome: Equatable, Sendable { case underWay, refused(TransportRequestRefusal) }
extension HubSession {
    /// Toward iCloud, from route `.relay` only; toward the relay the owner goes through `upgradeToRelay()`.
    func requestTransport(reason: String?) async -> TransportRequestOutcome
    func lapseRelay() async   // TransportFollowerPolicy.decide(.relayLapsed)
    var transportRequest: TransportRequestRecord? { get }
    var hubOnRelayAt: Date? { get }
}
```

**The request's path.** It starts on route `.relay` only; on an iCloud route the Mac is already there and nothing is written. The record is written first (compare-and-set). The same control id then goes two ways (rule 9's initiator write):

- `enqueueSwitchRequest(target: .cloudKit, id:, reason:)` queues it in the outbox on the current transport, the relay, which reaches the hub at once when the relay is up and paying. A refusal there (lapsed, outage) stops only that queue; the row moves with the outbox after the switch, and the hub answers a repeated id once.
- A sealed copy is written directly into the **iCloud** mailbox through `HubSession.sealing(_:)` over the hub's other route (`LinkRecord.otherRoute`), with `expect: .absent`, retried from the record on every pass until it is saved (`TransportRequestRecord.iCloudWritten`). This is the copy that gets through a lapsed relay, which refuses writes, or an outage. A relay-only hub (no other route) has only the first way, and a lapse there leaves "This hub needs Relay".

The hub answers in the mailbox where it read the request, so while a request is open `SideMailboxReader` reads the iCloud mailbox every `otherMailboxEvery` (30 s) even when the relay still answers: a lapsed relay's refusal counts as an answer, so rule 12's 60 s outage test would never start that read.

**How it ends:**
- `transport_switched{cloudkit}` or the marker, through the follower: the route moves and the record clears;
- the hub is already there (`requestAnswered`): clears;
- `transport_switch_rejected`: `unavailable` asks once more after `retry_after_s`, a second ends it as `.unavailable`; `not supported yet` → `.notSupported`. `too_soon` and `not_paying` never answer a request toward CloudKit; if read, they log a code and the request stays;
- `hub_on_relay` (the Mac stays on the relay for another paying phone): the follower's `withoutHub` moves this phone to iCloud, the record clears and `hubOnRelayAt` is set; S30 shows;
- a hub with no `ordered_actions` reads no controls: `.notOrdered` before anything is written;
- a relay-only hub: no request at all. `lapseRelay()` writes nothing, Task 10's S47 shows, and the route stays;
- **24 h of wall time from `at`** with no answer (`TransportRequest.answerLimit`, the value of `RelayUpgrade.readerWaitLimit`; Open decision 15): the record keeps a refusal the owner can leave with **Try Again**. An owner's request withdraws its queued row and iCloud copy, best effort: if the hub read it first it still answers and the follower follows. A lapse's copy stays, because the phone cannot use the relay either way (`.lapseNoAnswer`). **Try Again** reuses the record's `reason`: a plain request would take the Mac away from another paying phone (Open decision 6).

**Three failure classes:**
- **A closed Mac:** the record stays for up to 24 h, and the UI says it waits (Task 8); **Forget This Mac** stays enabled throughout. The iCloud copy waits in the mailbox, and the hub's 30 s CloudKit poll reads it when the Mac returns.
- **A failure midway:** the control row lives in the outbox's durable queue, so a failed save retries on the next pass; a crash between the record and the enqueue is healed at launch by enqueueing the record's same `controlID` again (idempotent by id).
- **A restart:** the record is read at launch, and the session resumes the pass and the read of both mailboxes.

**`hubOnRelayAt`** is set when `hub_on_relay` arrives or when a `transport_switched{relay}`/marker is refused because `canUseRelay == .no`. It clears on any later move or marker toward CloudKit, on the route becoming relay, and on unlink. A relay-only hub is not told `hub_on_relay` over iCloud, so it does not use this flag: `RelayBannerModel.relayOnly` gives S47 or S53, and Connection says "This hub needs Relay" (S13).

**Copy** (`TransportRequestRefusal.message`):
- `.unavailable`: "<Mac> couldn't switch right now. Try again in a minute." (the approved text of Phase 3b decision 3);
- `.notSupported`: "<Mac> can't switch from here. Update Watchtower on the Mac.";
- `.notOrdered`: "Update Watchtower on <Mac> to change how it connects."
- `.macNoAnswer`, `.lapseNoAnswer`: S52's two texts.

- [ ] **Step 1: Failing tests** (`TransportRequestWiringTests`, on `FakeHostedRelay` and `InMemoryCloudTransport` with a scripted hub):
  - `testTheRequestGoesToICloudAndWhenReachableToRelayWithOneID`;
  - `testAFailedRelayCopyDoesNotStopTheICloudRequest`;
  - `testALapsedHubAsksOverICloudAndResumesAfterARelaunch` (the wire control carries `reason: entitlement_expired`; the record survives a new session; the same id is queued again, not a new one);
  - `testAClosedMacWaitsThenEndsAfterADay` (23 h `.underWay`, across a relaunch with the same clock; past 24 h `.macNoAnswer`, the copies withdrawn; **Try Again** starts a new record);
  - `testALapseAfterADayKeepsItsCopy`;
  - `testTryAgainKeepsTheReason`;
  - `testHubOnRelayEndsALapseRequest`;
  - `testARelayOnlyHubIsNeverAskedOnALapse`;
  - `testTheMoveEndsTheRequest`, `testAnAnswerForWhereItRunsEndsTheRequest`;
  - `testUnavailableAsksOnceMoreThenEnds`;
  - `testNotSupportedEndsTheRequest`;
  - `testALegacyHubIsNeverAsked` (`.notOrdered`, nothing written);
  - `testALapseReplacesAPendingUpgradeRequest` (the hub's "superseding" rule on our side: `relayUpgrade` ends, the slot kept);
  - `testHubOnRelayIsKeptAndClearedByAMoveBack`;
  - `testAnUnlinkDuringARequestWinsAndNothingIsWrittenAfter`;
  - `testAnOpenRequestReadsTheICloudMailboxWhileTheRelayAnswers`;
  - `testAFailedICloudCopyIsRetriedOnTheNextPass`;
  - `testARelayOnlyHubHasNoICloudCopy`;
  - `testARequestOnAnICloudRouteWritesNothing` (also with an empty origin: no relay object built).
  `TransportRequestCopyTests`: one assertion per text. Kit: `testASwitchRequestWithoutAReasonHasNoReasonKey`, `testASwitchRequestCarriesItsReason`.
- [ ] **Step 2: Run, expect failure:** `make kit-test FILTER='ActionOutbox'`; `make mobile-gen`; `make mobile-test SIM='iPhone 17 Pro' MOBILE_FILTER='TransportRequestWiringTests|TransportRequestCopyTests'`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the same, plus** `MOBILE_FILTER='TransportFollowerWiringTests|SideMailboxWiringTests|RelayUpgradeWiringTests|HubRegistryTests'`; `make lint-swift`.
- [ ] **Step 5: Commit:** `feat(mobile): ask a Mac for iCloud, follow a relay lapse, keep hub_on_relay (#1243)`

### Task 6: `RelayAccountCenter`: purchase, restore, transfer, entitlement

**Depends on:** Tasks 2, 4, 5

**Files:**
- Create: `WatchtowerMobile/Sources/App/Relay/RelayAccountCenter.swift`
- Modify: `WatchtowerMobile/Sources/App/AppRoot.swift` (build it only when `RelayAvailability == .available`, wire it to the sessions), `AppEnvironment.swift` (`relayAccount: RelayAccountCenter?`)
- Test: Create `WatchtowerMobile/Tests/RelayAccountCenterTests.swift`, `WatchtowerMobile/Tests/Support/RelayAccountFakes.swift`; `make mobile-gen`

**Interfaces (Produces):**

```swift
@MainActor @Observable
final class RelayAccountCenter {
    enum Phase: Equatable {
        case checking
        case unknown                               // the relay gave no answer
        case free(ended: Bool)                     // none, or expired/revoked
        case paying(grace: Bool, macs: [String])
        case moved
    }
    enum PurchaseState: Equatable {
        case idle, loadingProduct, productFailed
        case ready(RelayProduct)
        case buying, confirming, pending
        case boughtNotConfirmed                    // Apple yes, the relay not reached
        case accountFailed                         // no account id: nothing bought yet
        case restoring, noSubscriptionFound
        case refused, transferLimit, notImplemented, updateRequired
        case done
    }
    enum UnconfirmedPurchase: Equatable {
        case confirming, notReached
        case refused, transferLimit, notImplemented, updateRequired
    }
    private(set) var phase: Phase
    private(set) var purchase: PurchaseState
    private(set) var updateRequired: Bool
    /// A current period Apple sold with no entitlement answer. Written only by the submit path; nil when no such row is left.
    private(set) var unconfirmed: UnconfirmedPurchase?
    /// `TransportFollowerPolicy.lapseReason` on `.free` and `.moved`; nil while paying or unknown.
    var switchReason: String? { get }
    func start()            // the event loop, the unfinished sweep, the updates task, first read; nothing without an identity
    func identityAppeared() // idempotent: runs what start() held back
    func refresh() async    // get_account_state
    func screenClosed()        // resets a finished press's state
    func loadProduct() async
    func buy() async
    func restore() async
    func retryConfirm() async
}
protocol RelayLapseTarget: AnyObject { @MainActor func lapseRelay() async; @MainActor var isOnRelay: Bool { get } }
```

**Purchase:** `accountID()` (it may create `relay_auth` and register: the owner's press is the first use, spec §4; a failure is `.accountFailed` with nothing charged, `.updateRequired` on an attestation refusal) → `purchase(accountToken:)` → on `.purchased`, `submit(jws:)` → `finish` only after a definite relay answer → `refresh()`.
- `.pending` shows `pending`; `.cancelled` returns to `ready`; `.unverified` shows `refused`.
- Finish only on an entitlement answer (Open decision 19). **An entitlement answer means `.active` or `.grace`.** `submit` returning `.none`, `.expired` or `.revoked` is a refusal: the row stays, the id joins the refused set, and the owner sees `.refused`. Every refusal leaves the row in `Transaction.unfinished`, and the state shows why. **The bound holds for the automatic paths only** (the sweep and `updates()`): a refused transaction id is kept in memory and they do not send it again in this process; the next launch sends it once. **An owner's press is exempt:** `restore()` and `retryConfirm()` submit what StoreKit returns even when the id is in the refused set, because the same id can come back with a new signature. A press refused again keeps the id in the set, so the automatic paths stay bound. An unreachable relay is not a refusal and stays on the foreground sweep. **The 10-minute window:** a `Transaction.unfinished` JWS keeps its old `signedDate`, which is enough for this account's own purchase, which has no window. A move needs a fresh one, so a refused move passes only through **Restore** (`AppStore.sync()`), as S27 says.

**Two states, two writers.** `purchase` is what an owner's press is doing: `buy`, `restore`, `retryConfirm`, `screenClosed` and `loadProduct` write it, plus the one settling rule below. `unconfirmed` means Apple sold a current period and the relay has not confirmed it, and only the submit path writes it, whichever path called. The sweep and `updates()` write no running or failed `purchase` state, so a background pass cannot interrupt a running purchase or put a failure on the owner's screen by itself.

**An entitlement answer settles the screen.** On an `.active` or `.grace` answer from any path, a `purchase` of `.pending`, `.boughtNotConfirmed`, `.refused`, `.transferLimit`, `.notImplemented`, `.updateRequired` or `.noSubscriptionFound` becomes `.done` (S29): an Ask to Buy approved through `updates()`, or a reconnect that confirmed S26. `.buying`, `.confirming` and `.restoring` are left to their own press, which ends on the same answer.

**Closing the screen clears a finished press.** `RelaySubscriptionView` calls `loadProduct()` from its `.task` and `screenClosed()` from `.onDisappear`. `screenClosed()` resets a `purchase` of `.done`, `.noSubscriptionFound`, `.accountFailed`, `.refused`, `.transferLimit`, `.notImplemented`, `.updateRequired`, `.boughtNotConfirmed` or `.productFailed` to `.idle`. So a result stays until it has been on screen: a Restore that ends before the screen opens (Now's banner, the Relay card) is still there when it opens. A failure that still holds comes back through `unconfirmed`; one that no longer holds is gone. A running press stays, and so does `.pending`: "Waiting for approval" holds until an approval arrives, a press replaces it, or the app relaunches (StoreKit does not report a declined request, so **Restore Purchases** stays enabled). **Retry** on S22 calls `loadProduct()`. `loadProduct()` writes only from `.idle`, `.loadingProduct`, `.productFailed` or `.ready`, and leaves any other `purchase` as it is.

**A renewal is not a purchase.** `RelayTransaction.isRenewal` comes from StoreKit's `Transaction.reason`. A renewal sets `unconfirmed` only on a definite refusal, never `.confirming` or `.notReached`, so a paying phone whose relay is down keeps S03 or S54 and is not told its purchase failed. While `phase` is `.paying`, `unconfirmed` shows nowhere: a renewal refused in the background changes no screen, and the sweep retries it with a log line (code only). If the period really ends, the read says not paying, and that is what the owner sees.

**A row counts only while its period is current:** not `revoked`, and `expiresAt` in the future (the center's injected `now`). A row that is not current is not sent and sets nothing. It also stays unfinished: finishing is only ever an entitlement answer, so a wrong clock cannot finish a live purchase. StoreKit lists it again at each sweep and it is passed over; a v1 limit, harmless because the list grows by at most one row a period. Each sweep recomputes `unconfirmed`: with no current unfinished row it is nil, and a revoked row from `updates()` clears it at once. So **Subscribe** returns when the paid period ends or Apple refunds it, and a permanent refusal hides it for that period at most. While the period is current a second purchase cannot help: the same Apple ID gets the same subscription back. The way out then is **Restore Purchases**, or **Manage Subscription** (Task 9) to cancel at Apple. Cancelling does not return the current month; the guide page names Apple's refund page (Task 16). A clock set ahead brings **Subscribe** back early; that buy charges nothing and returns the same transaction (Task 4: `testASecondPurchaseOfAnActiveSubscriptionChargesNothing`). A clock set behind keeps **Subscribe** away past the period, until the clock is right; Restore still works. A v1 limit.

**How `unconfirmed` is set:** `.confirming` while a current row is submitted and nothing was known yet; `.notReached` on an unreachable relay; `.refused`, `.transferLimit`, `.notImplemented` or `.updateRequired` on a definite answer. An entitlement answer clears it and finishes the row. A sweep that skips a refused id (the bound) leaves it as it is. It lives in memory: the next launch's sweep sets it again, because the row is still unfinished.

**Failures on this path:**

| What happens | Result |
|---|---|
| Killed after `purchase`, before or during `submit` | The next launch's sweep: `.confirming`, then the answer. The relay treats a repeat as idempotent. |
| The relay is unreachable | `.notReached`; retried on the foreground sweep and at `.reachable(true)`; **Try Again** |
| A definite refusal | Sent once per launch; **Restore Purchases** is the exempt press on S27, S28 and S42 (**Try Again** is S26's, `retryConfirm`, exempt as well); **Manage Subscription** is offered |
| A background pass confirms what a press's frame shows | The settling rule: S29, and **Done** |
| Refused every time | As above until `expiresAt`; then the row stops counting and **Subscribe** returns |
| Apple refunds it | `updates()` delivers it revoked: `unconfirmed` clears and the read decides the phase |
| A renewal is refused on a paying phone | Nothing on screen; the sweep retries at the bound's pace |
| A renewal with the relay unreachable | `unconfirmed` stays nil; the card reads S03, the Connection row S54 |
| A first purchase never confirmed, and the relay still unreachable at its first renewal | The old row has expired and the renewal sets nothing, so **Subscribe** shows. That buy charges nothing and the sweep confirms the renewal when the relay returns. A v1 limit: it takes a relay outage of a whole billing month |
| A Restore ends before the screen opens | The result stays until `screenClosed`, so the screen shows it |
| `submit` answers `.none`, `.expired` or `.revoked` | A refusal: not finished, no S29 |
| `.pending`, then killed | No transaction, so no row and nothing unconfirmed: the screen is `.ready`, a second buy is pending again, and an approval arrives on `updates()` |
| A press while a sweep submits the same id | The press joins the flight; if that answer is a refusal, the press sends its own fresh JWS once |
| A sweep answers while a press runs | `unconfirmed` changes underneath; the screen keeps showing the press |
| A row with no expiry (never for this product) | `StoreKitRelayStore` skips it with a log line (code only) |

**With no `relay_auth` yet** (`existingSigner()` nil: a phone that never used Relay): `start()` sets `.free(ended: false)` and does nothing else. No session, register, attestation, read or `Transaction` stream; a reinstalled phone's purchase comes back on Restore. **`identityAppeared()`** starts the rest, called after a successful `accountID()` in `buy` and `restore`, at a finished relay link, and at an upgrade's first step (the same three points call `RelayPushRegistrar.identityMayExist()`), so nothing waits for a relaunch.

**At launch and each foreground** (at most once a minute), **and at every `.reachable(true)`** (spec §7: after every reconnect, `get_account_state`): `unfinished()` is submitted, `updates()` feeds the same path, and `refresh()` runs. The relay's "never a cached JWS" rule holds because nothing persists a JWS; each comes from StoreKit at that moment.

**Restore:** the press is a first use too: `accountID()` first, with `.accountFailed` or `.updateRequired` as in a purchase, and nothing asked of Apple on a failure. Then `restore()` (`AppStore.sync()`) → a transaction → `submit` → `refresh`. No transaction: "No subscription found on this Apple ID." The restored transaction keeps the original account's token and the relay moves it. The new phone then links its Macs by QR (relay design §3.2 p. 4); Settings → Macs shows the adopted slots as "A Mac not on this iPhone" (Phase 3 copy).

**Events** (`HostedRelaySession.events`, one reader):
- `.control(.entitlementExpired, _)` and `.entitlementInactive`: `refresh()`, then every relay-route session's `lapseRelay()`;
- `.control(.subscriptionMoved, _)`: phase `moved`, then the same lapse;
- `.control(.slotRemoved, mac)`: `refresh()`;
- `.unsupportedVersion`, `.attestation(.updateRequired)`: `updateRequired = true`, cleared by `.reachable(true)`, the Kit's latch, which also runs the read above;
- `.attestation(.notSupported)`: `phase = .unknown`, and the relay is not offered until the next launch (`RelayAvailability` decides then);
- `.attestation(.retryLater)`: `phase` stays; the next read shows `unknown`.

**`refresh()`** also lapses when the read says not paying or `moved` while some session is on the relay: a phone offline when the control went out learns it here (controls are best effort, README "Control events"). A failed read is `unknown`, **never** free: as in Phase 3's `canUseRelay`, no paying phone is sent back to iCloud on a network failure.

**Paying again** after a lapse: `canUseRelay` is `.yes`, and nothing moves by itself. The owner chooses Relay per Mac (Open decision 7).

**Failure classes.** The Mac closed: nothing here waits on it (the hub's answer is Task 5's). A failure midway: the unfinished row and the once-a-minute sweep. A restart: the sweep and the first read. Killed during `buy`: StoreKit keeps the purchase, and the next launch's sweep submits it.

**Copy:** on the view models of Tasks 7 and 9, which read this state.

- [ ] **Step 1: Failing tests** (`RelayAccountCenterTests`, `FakeSubscriptionStore` over `FakeHostedRelay`):
  - `testABuyUsesTheAccountIDAsToken`;
  - `testAPurchaseIsSubmittedThenFinishedThenRead` (order on the fakes);
  - `testAKilledPurchaseIsSubmittedAtTheNextLaunch` (the store keeps it unfinished; a new center submits once and finishes);
  - `testAnUnreachableRelayLeavesTheTransactionUnfinished` (`boughtNotConfirmed`, no `finish`; `retryConfirm` then finishes);
  - `testEveryRefusalLeavesTheTransactionUnfinishedAndIsTriedAgain` (table: invalid, transfer limit, not implemented; the state's copy key; a later entitlement answer finishes it);
  - `testARefusedTransactionIsSentOncePerLaunch` (two foregrounds: one op; a new center: one more);
  - `testAStaleUnfinishedMoveIsRefusedAndRestorePasses` (the fake's 10-minute rule);
  - `testAnOwnerPressIsNotBoundByTheRefusedSet` (table: `restore`, `retryConfirm`; the id refused and in the set, the store returns it with a new JWS: one more op with the new JWS; an entitlement answer finishes it);
  - `testAPressRefusedAgainKeepsTheAutomaticBound` (then a foreground sends nothing);
  - `testARefusalAtLaunchIsShownAndSurvivesLoadProduct` (table: invalid, transfer limit, not implemented, attestation update required; a new center: `unconfirmed` set, `purchase` untouched; `loadProduct` leaves `unconfirmed` as it is);
  - `testAnUnreachableRelayAtLaunchIsNotReached` (a new center: `.notReached`, then `retryConfirm` finishes it);
  - `testAnEntitlementAnswerClearsTheUnconfirmedPurchase` (a sweep or a restore: nil, the row finished);
  - `testAnInactiveAnswerIsARefusal` (table: `.none`, `.expired`, `.revoked`: no `finish`, no `.done`, `unconfirmed == .refused`, the id in the refused set);
  - `testASweepNeverTouchesThePurchaseState` (table: during `.buying`, `.confirming`, `.ready`, `.done`: a sweep's submit and its refusal leave `purchase` as it was; only the settling rule writes it);
  - `testAnExpiredRowIsNotSentAndSetsNothing`, and `testAPermanentRefusalEndsWithThePeriod` (refused, then `now` past `expiresAt`: nil, no op);
  - `testARevokedRowClearsAtOnce` (from `updates()`);
  - `testAPressJoiningASweepSendsItsOwnJWSAfterARefusal`;
  - `testASweepWithOneCurrentRowKeepsItThroughTheBound` (a foreground skipping the id leaves `unconfirmed`);
  - `testAFailedAccountIDChargesNothing`;
  - `testARestoreWithNoIdentityCreatesItOnThePress`, and `testARestoreWhoseAccountFailsAsksNothingOfApple`;
  - `testTheCenterStartsWhenAnIdentityAppears` (the events loop and the sweep run with no relaunch, after a link and after a buy);
  - `testNoIdentityReadsNothingAndAttestsNothing` (a counting relay and signer factory: zero calls at launch; the first **Subscribe** makes them);
  - `testAReconnectReadsTheAccount`;
  - `testPendingAndCancelledSubmitNothing`, `testAnUnverifiedPurchaseSubmitsNothing`;
  - `testOneTransactionIsSubmittedOnce` (buy and `updates` deliver it together: one op);
  - `testARenewalIsSubmitted`, and `testARefusedRenewalChangesNoPurchaseState`;
  - `testARenewalWithNoRelayIsNotUnconfirmed` (no `.confirming`, no `.notReached`; a definite refusal does set it);
  - `testAnEntitlementAnswerSettlesAFinishedPress` (table: each of the seven states, from `updates()`, the sweep and a reconnect: `.done`; `.buying`, `.confirming`, `.restoring` untouched);
  - `testScreenClosedClearsAFinishedPress` (table; a running press and `.pending` stay);
  - `testARestoreEndingBeforeTheScreenOpensKeepsItsResult` (`restore`, then `loadProduct`: `.noSubscriptionFound` and `.refused` stay until `screenClosed`);
  - `testARestoreSubmitsAFreshTransactionNeverACachedOne` (two restores read the store twice);
  - `testARestoreRunsAndWithNothingSaysSo`;
  - `testAMoveControlLapsesEveryRelayMac` and `testAMoveLearnedFromAccountStateLapsesEveryRelayMac`;
  - `testAnExpiryControlLapsesEveryRelayMac`, `testAnICloudMacIsNotAsked`;
  - `testAFailedReadIsUnknownAndLapsesNothing`;
  - `testAGraceAccountIsPayingAndLapsesNothing`;
  - `testPayingAgainMovesNoMac`;
  - `testUpdateRequiredLatchesAndClears`;
  - `testAnEmptyOriginTouchesNoStoreKit` (`AppRoot` wiring, a counting store: no call).
- [ ] **Step 2: Run, expect failure:** `make mobile-gen`, `make mobile-test SIM='iPhone 17 Pro' MOBILE_FILTER='RelayAccountCenterTests'`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the same, plus** `MOBILE_FILTER='RelayAvailabilityTests|AppRootWiringTests|TransportRequestWiringTests'`; `make lint-swift`.
- [ ] **Step 5: Commit:** `feat(mobile): the Relay account center: buy, restore, move, lapse (#1243)`

### Task 7: Settings → Macs: the Relay card and each Mac's transport line

**Depends on:** Tasks 1, 6

**Files:**
- Create: `WatchtowerMobile/Sources/Features/Settings/RelayCardModel.swift`
- Modify: `WatchtowerMobile/Sources/Features/Settings/MacsModel.swift`, `MacsView.swift`, `WatchtowerMobile/Sources/Features/Hubs/HubListModel.swift` (the row's line and a link to Connection, Task 8)
- Test: Create `WatchtowerMobile/Tests/RelayCardModelTests.swift`; extend `MacsModelTests.swift`, `ScreenshotTourTests.swift` (`captureRelayPhase4`, S01–S07, S41, S55); `make mobile-gen`

**Interfaces (Produces):**

```swift
struct RelayCardModel: Equatable {
    /// nil on an unavailable relay: no card at all.
    init?(availability: RelayAvailability, phase: RelayAccountCenter.Phase, unconfirmedPurchase: Bool, slotLimit: Int)
    let rows: [Row]          // title + value
    let line: String?
    let action: Action?      // .openSubscription, .retry, .restore
    let toneUses: [ToneUse]
}
extension MacsModel {
    static func transportLine(_ link: LinkRecord, ownDeviceID: String?, inFlight: Bool, now: Date) -> String
}
```

`Phase` → card, with the mockup's texts (Task 1): `.checking` S02; `.unknown` S03 (**Retry** calls `refresh`); `.free(ended: false)` S01 (opens the subscription); `.paying(grace: false)` S04, "N of 3" from `macs.count` and the relay's limit of 3; `.paying(grace: true)` S05; `.free(ended: true)` S06; `.moved` S41 (**Restore Purchases**), never "ended". `.restore` calls `center.restore()` and pushes the subscription screen in one action, as Now's banner does (Task 10), so S44 and the result show there; Task 9 wires the push. **`unconfirmedPurchase` (`center.unconfirmed != nil`) on `.free` or `.unknown` is S55 instead** (opens the subscription, which names the cause and the next step). The other phases win over it: `.paying` has its answer, `.moved` already offers Restore, and `.checking` is about to change.

`transportLine`: "iCloud"; "Relay"; "Relay · switched by this iPhone, <time>"; "Relay · switched by another iPhone, <time>"; "iCloud · switched by this iPhone, <time>", and so on; `by == entitlement_expired` reads "iCloud · your subscription ended, <time>"; `inFlight` (a running upgrade or request) reads "Switching…". The device id never shows. The time uses the app's short format (`RecordingsFormat`).

New rows use no `CardRowDivider`; the card is a `SettingsCard`.

- [ ] **Step 1: Failing tests:** `testEveryPhaseHasItsRowsAndAction` (table, exact strings); `testAnUnconfirmedPurchaseIsNeverNotSubscribed` (`.free(ended: false)`, `.free(ended: true)` and `.unknown`: S55, opening the subscription; `.paying` and `.moved` keep their own frames); `testAnUnavailableRelayHasNoCard`; `testTheSlotCountReadsNOfThree`; `testTransportLines` (table, exact strings, including "entitlement_expired" and a nil `switchedAt`); `testAnotherPhonesIDNeverShows`; `testCardTonesAreDeclared`; `testAnEmptyOriginShowsNoRelayUI` (`MacsView`'s model with `.off(.notConfigured)`: no card and the row line is empty, as today's row).
- [ ] **Step 2: Run, expect failure:** `make mobile-gen`, `make mobile-test SIM='iPhone 17 Pro' MOBILE_FILTER='RelayCardModelTests|MacsModelTests'`.
- [ ] **Step 3: Implement.** Add the shots with `captureThree` on a demo `RelayAccountCenter` fake.
- [ ] **Step 4: Run the same;** `make lint-swift`.
- [ ] **Step 5: Compare** `make mobile-shots SIM='iPhone 17 Pro'` S01–S07, S41, S55 with the mockup; note differences for the PR body.
- [ ] **Step 6: Commit:** `feat(mobile): Relay card and transport lines in Settings → Macs (#1243)`

### Task 8: The Mac's Connection section: the per-Mac choice

**Depends on:** Tasks 1, 5, 6, 7

**Files:**
- Create: `WatchtowerMobile/Sources/Features/Settings/MacTransportModel.swift`, `MacDetailView.swift`
- Modify: `MacsView.swift` (**only with `RelayAvailability == .available`**, a row opens `MacDetailView`, and **Forget This Mac** is there too with today's confirmation; otherwise the list is exactly today's)
- Test: Create `WatchtowerMobile/Tests/MacTransportModelTests.swift`, `MacTransportWiringTests.swift`; extend `ScreenshotTourTests.swift` (S08–S19, S49, S52, S54, S56); `make mobile-gen`

**Interfaces (Produces):**

```swift
struct MacTransportModel: Equatable {
    struct Row: Equatable {
        let kind: TransportKind
        let title: String            // "Relay", "iCloud"
        let line: String?
        let chosen: Bool
        let enabled: Bool
        let action: Action?
    }
    enum Action: Equatable { case chooseRelay, chooseICloud, openSubscription, manageMacs, tryAgain }
    let rows: [Row]
    let footnote: String?
    let busyLine: String?
    let toneUses: [ToneUse]
    init(link: LinkRecord, grant: DeviceGrant?, phase: RelayAccountCenter.Phase, unconfirmedPurchase: Bool,
         availability: RelayAvailability, session: SessionTransportFacts, macName: String,
         ownDeviceID: String?, now: Date)
}
struct SessionTransportFacts: Equatable {
    let upgradeStep: RelayUpgradeStep?
    let upgradeRefusal: RelayUpgradeRefusal?
    let request: TransportRequestRecord?
    let macReachable: Bool
}
```

**Decision table** (`testEveryChoiceStateHasItsCopyAndAction`, one row per line, exact strings from Task 1):

| Condition, first match wins | Relay row | iCloud row |
|---|---|---|
| `availability != .available` | no screen at all | |
| A relay-only hub | chosen, "This hub works over Relay only", or "This hub needs Relay" when not paying (S13) | no row |
| A refused iCloud request | chosen | the refusal's line, **Try Again** (S49; `.macNoAnswer`, `.lapseNoAnswer` S52) |
| A request toward iCloud, Mac reachable | disabled | busy "Switching to iCloud…" (S17) |
| A request or upgrade waiting, Mac closed | busy "Waiting for <Mac>. It switches when it's back." (S16) | disabled |
| An upgrade running | busy "Switching to Relay…", step line (S15) | disabled |
| `phase == .checking` | disabled "Checking…" (S19) | enabled per route |
| A kept refusal | `RelayUpgradeRefusal.message`, **Try Again** (S18); `.tooSoon` shows S11 with no button until `retryAt`; `.vouch(.slotsFull)` shows S14, **Manage Macs** | chosen |
| The grant has no `ordered_actions` or no coherent relay identity | "Update Watchtower on this Mac to use Relay" (S12), disabled | chosen |
| `unconfirmedPurchase`, phase `.free` or `.unknown`, on an iCloud route | "Your purchase isn't confirmed yet." › subscription (S56) | chosen |
| Not paying, `.moved`, or `.unknown` on an iCloud route | "Subscribe to use Relay" › subscription (S10); on `.unknown` "Couldn't reach Relay." disabled (S54) | chosen |
| Paying, route iCloud, the Mac not in slots and 3 taken | S14, **Manage Macs** (`RelaySlotsView`, Phase 3; Open decision 12) | chosen |
| Paying, route iCloud | "Instant, encrypted end to end", **chooseRelay** (S09) | chosen, "Free, slower" |
| Route relay | chosen (S08) | "Free, slower", **chooseICloud** |

`chooseRelay` calls `HubSession.upgradeToRelay()`; this is the first production caller (3b's model-only limit ends here). `chooseICloud` calls `requestTransport(reason: center.switchReason)`, and **Try Again** the record's own reason. `upgradeToRelay()` resumes on foreground, launch and fetch as Phase 3b made it. The footnote is "Applies to every phone of this Mac. Last changed by this iPhone at <time>.", with "another iPhone" or "when your subscription ended" as `switchedBy` says, and no second sentence if never switched.

**`macReachable`** is `RelayFeed.desktopReachability(store:now:) != .unreachable`: the heartbeat's age against `heartbeatStaleAfter` (35 min), the check the uploader already uses. A locked keychain (`.keysUnavailable`) proves nothing, so it reads as reachable, and the row says "Switching…" rather than blaming the Mac. A relay outage also stales the heartbeat, which is why S16's text says only that it waits. The view re-evaluates every 30 s (`TimelineView`, as Settings does).

**Failure classes.** A closed Mac: S16, then S52 after 24 h. A failure midway: the upgrade's persisted steps (Phase 3b) and Task 5's record. A restart: `SessionTransportFacts` is rebuilt from the record, so the same frame returns. A press while busy: rows disabled, and a second call finds the record and does nothing new. A second phone switches the Mac meanwhile: the follower moves the route and the running request ends (`requestAnswered`).

- [ ] **Step 1: Failing tests:** the table above; `testAClosedMacShowsWaitingNotAFailure`; `testTooSoonCountsDownAndReturnsTheAction` (the injected `now` past `retryAt`: the row is enabled again); `testFootnoteNamesWhoChanged`; `testAStaleHeartbeatIsClosedAndLockedKeysAreNot`; `testNoScreenWithoutRelay`; `testTonesAreDeclared`. `MacTransportWiringTests`: `testAnEmptyOriginKeepsTheMacsListAsToday` (a row opens nothing new, Forget where it is), `testForgetStaysEnabledWhileWaiting`,  `testChoosingRelayRunsTheUpgrade`, `testChoosingICloudSendsARequest`, `testChoosingICloudOnALapsedPhoneCarriesTheReason`, `testAFinishedSwitchEndsBusy`, `testARefusalIsKeptAcrossARelaunch`, `testASecondPressStartsNothing`, `testManageMacsOpensTheSlotsScreen`.
- [ ] **Step 2: Run, expect failure:** `make mobile-gen`, `make mobile-test SIM='iPhone 17 Pro' MOBILE_FILTER='MacTransportModelTests|MacTransportWiringTests'`.
- [ ] **Step 3: Implement.** Shots S08–S19, S49, S52, S54, S56 (each light, dark, narrow).
- [ ] **Step 4: Run the same, plus** `MOBILE_FILTER='RelayUpgradeWiringTests|RelayUpgradeCopyTests|RelaySlotsModelTests'`; `make lint-swift`.
- [ ] **Step 5: Compare** the shots with the mockup; note differences for the PR body.
- [ ] **Step 6: Commit:** `feat(mobile): choose iCloud or Relay per Mac (#1243)`

### Task 9: The subscription screen

**Depends on:** Tasks 1, 6, 7, 8

**Files:**
- Create: `WatchtowerMobile/Sources/Features/Settings/RelaySubscriptionModel.swift`, `RelaySubscriptionView.swift`
- Modify: `MacsView.swift`, `MacDetailView.swift`: `.openSubscription` pushes the screen, and the card's `.restore` starts the restore and pushes it (Task 10 adds Now's way in)
- Test: Create `WatchtowerMobile/Tests/RelaySubscriptionModelTests.swift`, extend `MacTransportWiringTests.swift`, `ScreenshotTourTests.swift` (S20–S29, S42–S46); `make mobile-gen`

**Interfaces (Produces):** `struct RelaySubscriptionModel: Equatable { init(purchase: RelayAccountCenter.PurchaseState, unconfirmed: RelayAccountCenter.UnconfirmedPurchase?, phase: RelayAccountCenter.Phase, config: RelayConfig); let bullets: [String]; let primary: Button?; let line: String?; let lineIsError: Bool; let showsRestore: Bool; let manageSubscriptionURL: URL?; let termsURL: URL?; let privacyURL: URL?; let toneUses: [ToneUse] }`.

The lead line, the bullets and every state are Task 1's text, exact. `.ready(product)` builds "Subscribe — <displayPrice> / month"; no price is written in code. `.pending`, `.boughtNotConfirmed` and the rest map one to one. A nil `termsURL` or `privacyURL` hides that link; Task 17's Release check names this as an owner step, because App Review requires both (Open decision 8). **Restore Purchases** is enabled in every state but `.buying`, `.confirming` and `.restoring`. **What shows.** A press in progress or its result wins. With `phase` `.paying` and no press in progress, the frame is S29, whatever else is set: the screen has nothing to sell. Otherwise, with `purchase` in `.idle`, `.loadingProduct`, `.productFailed` or `.ready` and `phase` not `.paying`, a non-nil `unconfirmed` shows its frame: `.confirming` S24, `.notReached` S26, `.refused` S27, `.transferLimit` S28, `.notImplemented` S42, `.updateRequired` S43. So **Subscribe** is not offered during a current period someone already paid for, and returns when `unconfirmed` is nil (Task 6). The Relay card (S55) and the Connection row (S56) lead here. **Manage Subscription** on S27, S28 and S42 opens `https://apps.apple.com/account/subscriptions`, so nobody stays subscribed to what the relay refuses, from the next month on; the screen imports no StoreKit. S43 has no link: updating the app is the fix there.

- [ ] **Step 1: Failing tests:** `testEveryPurchaseStateHasItsCopy` (table, exact strings); `testAnUnconfirmedPurchaseOffersNoSubscribe` (table, each `UnconfirmedPurchase` over `.ready`: its frame, no **Subscribe**, **Restore Purchases** enabled); `testNoUnconfirmedPurchaseOffersSubscribeAgain` (nil over `.ready`, also after a refusal: **Subscribe**); `testAPressWinsOverTheBackgroundOutcome`; `testAPayingPhoneIgnoresUnconfirmed`; `testAPayingPhoneWithNoPressIsDone` (`.idle`, `.ready`, `.loadingProduct`: S29); `testManageSubscriptionOnEveryDefiniteRefusal` (S27, S28, S42 and no other state); `testThePriceComesOnlyFromTheProduct`; `testRestoreIsDisabledOnlyWhileABuyRuns`; `testMissingLinksAreHidden`; `testAnEmptyProductIsTheRetryState`; `testDoneNamesTheNextStep`; `testTonesAreDeclared`. `MacTransportWiringTests`: `testSubscribeRowsOpenTheSubscriptionScreen` (the Relay card and the Connection row); `testTheMovedCardRestoresOnTheSubscriptionScreen` (the press starts the restore and pushes the screen; S44, then `.noSubscriptionFound` or `.refused`, show there).
- [ ] **Step 2: Run, expect failure:** `make mobile-gen`, `make mobile-test SIM='iPhone 17 Pro' MOBILE_FILTER='RelaySubscriptionModelTests|MacTransportWiringTests'`.
- [ ] **Step 3: Implement.** The view only reads the model and calls the center. Shots S20–S29, S42–S46.
- [ ] **Step 4: Run the same;** `make lint-swift`.
- [ ] **Step 5: Compare** the shots with the mockup; note differences for the PR body.
- [ ] **Step 6: Commit:** `feat(mobile): the Relay subscription screen (#1243)`

### Task 10: The Now banners

**Depends on:** Tasks 1, 5, 6, 9

**Files:**
- Create: `WatchtowerMobile/Sources/Features/Now/RelayBannerModel.swift`
- Modify: `WatchtowerMobile/Sources/Features/Now/NowView.swift` (**Subscribe** presents `RelaySubscriptionView` in a sheet with its own stack; **Restore Purchases** calls the center and opens the same sheet to show the result), and `HubSession` (expose `relayUnansweredSince` as observed state)
- Test: Create `WatchtowerMobile/Tests/RelayBannerModelTests.swift`; extend `NowWiringTests.swift`, `ScreenshotTourTests.swift` (S30–S36, S47, S50, S51, S53); `make mobile-gen`

**Interfaces (Produces):**

```swift
struct RelayBannerModel: Equatable {
    enum Action: Equatable { case switchToICloud, subscribe, restore, ok }
    let text: String
    let secondLine: String?
    let actions: [Action]
    let busy: Bool
    let toneUses: [ToneUse]
    static let unavailableAfter: TimeInterval = 60
    static let offerAfter: TimeInterval = 600
    /// One banner at most (Open decision 17), first match wins: update the app, this hub relay-only and not paying, moved, ended, free on a relay Mac, relay unavailable.
    static func banner(availability: RelayAvailability, phase: RelayAccountCenter.Phase, updateRequired: Bool,
                       wasPaying: Bool, route: HubRoute?, relayOnly: Bool, hubOnRelayAt: Date?, unansweredSince: Date?, request: TransportRequestRecord?,
                       lastUpdate: Date?, macName: String, now: Date) -> Self?
}
```

- **Relay unavailable** starts at 60 s of `relayUnansweredSince` and rounds down in whole minutes ("for 1 min" from 60 s). **Switch <Mac> to iCloud** from 10 min (relay design §4.1), calling `requestTransport(reason: center.switchReason)`. There is no automatic switch. Phase 1's **Waiting to send** row stays where it is, under the banner.
- **Moved, ended:** only with `wasPaying` (the persisted flag: this phone was seen paying and has not dismissed the loss), so a phone that never paid sees none and a relaunch does not bring one back. **OK** clears the flag (mockup amended: its moved frame had no way to leave); a paying read also ends it. `.moved` and an ended account stay readable in the Relay card.
- **A relay-only hub, not paying:** S47, or S53 after a move, with no **OK**: the hub gets nothing until the owner pays or unlinks. It comes before moved and ended because this hub's route does not change, and their "back on iCloud" would be false on its Now. Switching to another hub of the phone shows those.
- **Free on a relay Mac:** `hubOnRelayAt` is set, with `lastUpdate` from the heartbeat's date. It leaves when the follower clears the flag.
- **A refused request:** the outage banner adds the refusal's line and the action again (S50), and so does a 24 h no-answer.
- **Dark:** an unavailable relay shows the free-on-a-relay-Mac banner only (a Release phone cannot pay, and no Mac can be on Relay before launch), never the Relay-unavailable or subscription ones. On such a phone it is S51, with no "Subscribe or" clause, as the screen does not exist. Pin: `testAnEmptyOriginShowsOnlyTheMacOnRelayBanner`.

**Failure classes.** The banner writes only through `requestTransport`, so Task 5 covers failure midway and restart; the press shows S36 until the follower moves the route. A closed Mac while the offer is pressed: S36 stays and the request waits. A relaunch during an outage: `relayUnansweredSince` restarts, so the banner returns after 60 s; the minutes count from the new start (v1 limit).

- [ ] **Step 1: Failing tests:** `testBannerTable` (each row, exact strings, first-match order); `testUnavailableStartsAtSixtySeconds`, `testTheOfferStartsAtTenMinutes`; `testTheBannerNeverSwitchesByItself` (no request after an hour of fake time); `testAnEmptyOriginShowsOnlyTheMacOnRelayBanner`; `testAPressShowsBusyAndStaysUntilTheMove`; `testANeverPayingPhoneHasNoEndedBanner`; `testOKEndsTheBannerAcrossARelaunch`; `testAPayingReadEndsTheBanner`; `testARefusedRequestShowsItsLineAndTheActionAgain`; `testARelayOnlyHubShowsNeedsRelayBeforeMovedAndEnded`; `testNoBackOnICloudTextOnARelayOnlyHub`; `testHubOnRelayFlagClearingEndsTheBanner`; `testTonesAreDeclared`. `NowWiringTests`: `testTheBannerSitsAboveWaitingToSend`, `testSubscribeOpensTheSheet`.
- [ ] **Step 2: Run, expect failure:** `make mobile-gen`, `make mobile-test SIM='iPhone 17 Pro' MOBILE_FILTER='RelayBannerModelTests|NowWiringTests'`.
- [ ] **Step 3: Implement.** Shots S30–S36, S47, S50, S51, S53.
- [ ] **Step 4: Run the same;** `make lint-swift`.
- [ ] **Step 5: Compare** the shots with the mockup; note differences for the PR body.
- [ ] **Step 6: Commit:** `feat(mobile): Relay banners on Now (#1243)`

---

## #1244 — Relay pushes

### Task 11: `RelayPushWake`: reading the relay's APNs bodies

**Depends on:** none

**Files:**
- Create: `WatchtowerKit/Sources/WatchtowerSync/Sync/RelayPushWake.swift`
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Sync/PushWake.swift` (`PushOrigin.hostedRelay`; `HubRoute.pushOrigin` answers it on a relay route)
- Test: Create `WatchtowerKit/Tests/WatchtowerSyncTests/RelayPushWakeTests.swift`; extend `CloudKitPushWakeTests.swift`

**Interfaces (Produces):**

```swift
public struct RelayPushWake: PushWake {
    public init()
    // subscribeAlerts: false (the relay's token is phone-wide, Task 13); a CloudKit route throws UnsupportedRouteError.
    // unsubscribeAlerts: no-op.
    // origin: .hostedRelay for {"aps":{"content-available":1}} with no "ck" and no "e"; else nil.
    // alertSource: .inline(hubID:envelope:) for a valid "e"; else nil.
    // envelope(for:timeout:): the inline bytes, no network; a .fetchRecord source throws UnsupportedRouteError.
}
public enum PushRouting {
    /// "ck" present → CloudKit's answer, as today; otherwise RelayPushWake's.
    public static func origin(ofRemoteNotification userInfo: [AnyHashable: Any], cloudKit: any PushWake) -> PushOrigin?
    public static func alertSource(for userInfo: [AnyHashable: Any], cloudKit: any PushWake) -> AlertSource?
}
```

`alertSource` reads `e` as a `String`, decodes **standard base64 with padding** (`Data(base64Encoded:)` without ignoring unknown characters; contract point 1), refuses more than `3021` decoded bytes (`secure.AlertPushMaxEnvelope`), parses `Envelope` strictly, requires class `alert` and `sender_id == hub_id`, and takes `hubID` from the header in the spelling `KeychainPhoneKeyStore.alertMaterial` keys on (uppercase `uuidString`, as `AskAlertSubscription.alertReference` yields; a test pins it). It opens nothing; `AlertOpener` still checks the signature.

**Changed behaviour, named:** a CloudKit push no longer wakes a relay-route session, and a relay silent push no longer wakes a CloudKit-route one. A relay-route session's iCloud control read stays on `SideMailboxReader`'s timer (rule 12).

- [ ] **Step 1: Failing tests:**
  - `testASilentBodyIsARelayOrigin` (the exact bytes of `apns.ts` parsed as JSON);
  - `testAnAlertBodyIsAnInlineSource` (`go-sealed.json` `alertPush` wrapped in the exact body);
  - `testTheHubIDKeysTheAlertMaterial`;
  - `testBrokenPushesAreNotAlerts` (table: no `e`; `e` a number; unpadded; url-safe alphabet; 3022 bytes; a truncated envelope; class `data`; another sender);
  - `testACloudKitPayloadKeepsItsAnswer` (private and shared, through `PushRouting`);
  - `testAnEmptyPayloadHasNoOrigin`;
  - `testAFetchRecordSourceIsRefused`;
  - `testThePushOriginOfARelayRoute` (the assertion on `HubRoute.pushOrigin` changes, named here).
- [ ] **Step 2: Run, expect failure:** `make kit-test FILTER='RelayPushWakeTests|CloudKitPushWakeTests'`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the same, plus** `FILTER='GoSealedEnvelopeTests'`; `make lint-swift`.
- [ ] **Step 5: Commit:** `feat(kit): read the relay's silent and inline alert pushes (#1244)`

### Task 12: The notification extension opens an inline alert

**Depends on:** Task 11

**Files:**
- Modify: `WatchtowerMobile/NotifyService/NotificationService.swift`: `PushRouting.alertSource`; `envelope(for:)` by source; the rest of `fill` unchanged
- Test: extend `WatchtowerMobile/Tests/AlertSubscriptionTests.swift`; a Kit test in `RelayPushWakeTests`

The inline path shares `fill` with CloudKit, so the title, body, thread and `userInfo` come from `WorkAlertContent` as today (contract point 3); the settled-alert sweep and a tap work unchanged (contract point 4). `serviceExtensionTimeWillExpire` is unchanged and the inline path has no wait. Any failure (an unknown hub, no material, an epoch no longer held, a bad signature) delivers the notification as it arrived: title "Watchtower", which is the relay's placeholder.

The "When work stops" switch cannot be enforced here: an extension must deliver what it got. See Open decision 1 and Task 13.

- [ ] **Step 1: Failing tests:**
  - Kit `testAnInlineAlertOpensWithNoNetwork` (the source's envelope with a `URLProtocol` that fails on any call, opened by `AlertOpener` with the fixture's material, matches `WorkAlertContent`);
  - Kit `testAnInlineAlertCarriesTheTapAndSweepFields`;
  - Kit `testAnOldEpochOpensWithARetainedKeyAndFailsWithout`;
  - phone `testTheExtensionLinksNoRelayTarget` (reads `project.yml`: the `NotifyService` dependencies contain no `WatchtowerHostedRelay`).
- [ ] **Step 2: Run, expect failure:** `make kit-test FILTER='RelayPushWakeTests'`, `make mobile-test SIM='iPhone 17 Pro' MOBILE_FILTER='AlertSubscriptionTests'`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the same;** `make mobile-build SIM='iPhone 17 Pro'` (the extension compiles); `make lint-swift`.
- [ ] **Step 5: Commit:** `feat(mobile): the notification extension opens the relay's inline alert (#1244)`

### Task 13: `register_push`, silent pushes, the alert switch on the relay

**Depends on:** Tasks 6, 11

**Files:**
- Create: `WatchtowerMobile/Sources/App/Relay/RelayPushRegistrar.swift`
- Modify: `WatchtowerMobile/Sources/App/WatchtowerMobileApp.swift` (`didRegisterForRemoteNotificationsWithDeviceToken`, `didFailToRegister…`, `PushRouting.origin` at the silent push), `AppRoot.swift`, `RelayConfig.swift`, `Base.xcconfig`, `Info.plist`, `project.yml` (`WT_PUSH_ENV` → `WTPushEnvironment`: `sandbox` in Debug, `production` in Release)
- Modify, only if Open decision 1 chooses A: `WatchtowerKit/Sources/WatchtowerSync/Relay/DevicePayload.swift` and `AppRoot.devicePayload` (`work_alerts_off`, written only when true), a `device_payload` fixture case. If it chooses C: `WorkAlertsCopy.relayFootnote`.
- Test: Create `WatchtowerMobile/Tests/RelayPushRegistrarTests.swift`; extend `AlertSubscriptionTests.swift`, `FetchCadenceWiringTests.swift`, `RelayConfigTests.swift`; `make mobile-gen`

**Interfaces (Produces):**

```swift
@MainActor
final class RelayPushRegistrar {
    init(availability: RelayAvailability, environment: RelayPushEnvironment?,
         hasIdentity: @escaping () -> Bool, send: @escaping (String, RelayPushEnvironment) async throws -> Void)
    func tokenArrived(_ token: Data)       // hex
    func identityMayExist()                // the center's first accountID, a finished relay link, an upgrade's first step
    func reachable()                       // .reachable(true), forwarded by the center
    func foreground()
    private(set) var state: State          // .idle, .sent(tokenHash), .failed
}
```

**The rule.** Send when: a token is known, `hasIdentity()` (`existingSigner()` != nil, **never creating one**; `relay_auth` is created on first use of the relay, spec §4), the environment is known, and this process has not yet sent this token. So once per launch, and again on a token change. A failure stays owed and is retried on `reachable()` and `foreground()`, with no timer. The token lives in memory only; iOS gives it at each launch's `registerForRemoteNotifications` (already called for CloudKit). A token arriving before `AppRoot` exists waits in `AppDelegate`, as `pendingTap` does. `didFailToRegister` logs a code; Desktop then shows "Notifications aren't set up on this iPhone" from `no_token` (the Go hub's line).

**Silent pushes.** `PushCompletion.serve` is unchanged. `AppEnvironment.handlePush` with `.hostedRelay` reaches the relay-route sessions, each through `LiveTransport.fetchForPush` over HTTPS with no socket, and it logs in when it must; a login needs an App Attest assertion, so a refused or unavailable one is `.failed` and the data waits for the next open (a push is only a hint, relay design §5). A real background assertion is manual check M4.

**Failure classes.** The Mac closed: no pushes come; the data waits. Failure midway: owed and retried. A restart: a new process sends once more, which is the spec's "at every launch". A build whose `aps-environment` differs from `WTPushEnvironment` (a Release build run from Xcode): the relay drops the token on `BadDeviceToken`, and Desktop shows the no-token line; a developer-only v1 limit.

**The switch.** With Open decision 1's option A the phone writes `work_alerts_off: true` in its `device` record while the switch is off, and the hub skips `send_alert` (Go hub, G1). The record is sealed and content-free, and an old hub ignores it. Until the hub reads it (Launch conditions), the switch stops iCloud alerts only.

- [ ] **Step 1: Failing tests:**
  - `testTheTokenIsSentOnceAsHexWithItsEnvironment`;
  - `testNoIdentityNoSendAndNoIdentityCreated` (a counting signer factory: zero calls);
  - `testTheFirstIdentityThenSends`;
  - `testAFailureIsRetriedWhenReachableAndOnForeground`;
  - `testANewTokenIsSentAgain`, `testANewProcessSendsAgain`;
  - `testANoEnvironmentBuildSendsNothing`;
  - `testAnEmptyOriginRegistersNoPush` (the registrar is not built; the CloudKit `registerForRemoteNotifications` stays);
  - `testTheTokenIsNeverLogged` (the log helper's text, as Phase 3's Keychain tests do);
  - `testARelayPushReachesOnlyRelaySessions`, `testACloudKitPushReachesOnlyItsScope` (`FetchCadenceWiringTests`);
  - `testAFailedLoginIsAFailedFetch`;
  - `testPushEnvironmentPerConfiguration` (`project.yml`).
- [ ] **Step 2: Run, expect failure:** `make mobile-gen`, `make mobile-test SIM='iPhone 17 Pro' MOBILE_FILTER='RelayPushRegistrarTests|FetchCadenceWiringTests|AlertSubscriptionTests|RelayConfigTests'`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the same, plus** `MOBILE_FILTER='BackgroundWorkTests|RelayAvailabilityTests'`, and `make kit-test FILTER='HubContractFixtureTests'` when the fixture changed; `make lint-swift`.
- [ ] **Step 5: Commit:** `feat(mobile): register the APNs token with the relay and route silent pushes (#1244)`

### Task 18: The alert subscription across a route move

**Depends on:** Tasks 11, 13

The session is rebuilt at a move (`AppRoot.performRouteMove`), with a registrar and a `SharedAlertPoster` chosen from the route, so nothing today handles the CloudKit subscription on the way to the relay, or the shared poster's seen list on the way back.

**Files:**
- Modify: `WatchtowerMobile/Sources/App/Hubs/HubSession.swift` (`makeAlertRegistrar`), `AlertSubscriptionRegistrar.swift` (`idle()`, a foreground retry while `applied == .unknown`, only for a link on the relay or one that ever switched, `switchedAt != nil`; a link that never switched keeps today's rule), `SharedAlertPoster.swift` (`forgetSeen`), `WatchtowerMobile/Sources/App/AppRoot.swift` (`performRouteMove`)
- Test: Create `WatchtowerMobile/Tests/AlertRouteMoveWiringTests.swift`; `make mobile-gen`

**The rule (Open decision 18).** The registrar always targets the hub's **CloudKit route**, whatever transport the session is on: `link.cloudKitRoute` with the CloudKit wake, for any hub that offers CloudKit; none for a relay-only hub. So the private subscription stays while the phone is on the relay, and the "When work stops" switch keeps adding and removing it there.

- **No duplicates on the relay:** a hub on the relay writes no signal (Go hub contract point 6), so the subscription is silent there.
- **No lost alert on the way back:** at a switch to CloudKit the hub re-signals every open alert it signals (`Publisher.Resignal`), before the phone has followed. A subscription removed on the relay would miss exactly those. A `push_off` alert gets no signal (G4): it arrives with the next sync, with no notification, a v1 limit until the Go hub answers.
- **A link paired over the relay with no iCloud account:** the save fails and logs a code, the link keeps working (Phase 3 R19), and a foreground retries it.
- **A shared-scope phone:** no poster on the relay. The new relay session calls `SharedAlertPoster.forgetSeen(hubID:defaults:)`, idempotent, so the return's first fetch is a "first fetch" and posts nothing. Otherwise up to 7 days of alerts already pushed over the relay would arrive as a burst. An alert raised in the move's window stays unposted on that phone: a v1 limit of the best-effort path (ask #622).

**Failure classes.** The Mac closed: nothing changes. A failure midway: a failed save stays `.unknown` and is retried on the next foreground and launch. A restart between the route write and the new session: the launch builds the session from the row, and both calls are idempotent. **The race:** the old session's queued delete or save against the new one's: `performRouteMove` waits for `alertRegistrar.idle()` before it builds the new session.

- [ ] **Step 1: Failing tests:**
  - `testTheSubscriptionStaysOnTheRelay` (a counting saver through a move to the relay and back: no delete, the save on the CloudKit route, no `UnsupportedRouteError`);
  - `testTheSwitchStillWorksOnTheRelay` (off removes, on saves, while the route is relay);
  - `testARelayOnlyHubHasNoRegistrar`;
  - `testAFailedSaveIsRetriedOnForeground`, `testANeverSwitchedLinkKeepsTodaysRetry` (no save on foreground);
  - `testNoICloudAccountDoesNotStopTheRelayLink`;
  - `testAReturnFromRelayPostsNoBurst` (shared scope, alerts in the replica);
  - `testAnAlertAfterTheReturnIsPosted`;
  - `testAMoveWaitsForTheOldRegistrar` (a parked save).
- [ ] **Step 2: Run, expect failure:** `make mobile-gen`, `make mobile-test SIM='iPhone 17 Pro' MOBILE_FILTER='AlertRouteMoveWiringTests|AlertSubscriptionTests|SharedAlertWiringTests'`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the same, plus** `MOBILE_FILTER='TransportFollowerWiringTests'`; `make lint-swift`.
- [ ] **Step 5: Commit:** `feat(mobile): keep the CloudKit alert subscription across a route move (#1244)`

---

### Task 19: A push launch opens no socket until the first activation (added during execution, board #1559)

**Depends on:** Task 18

Not in the approved plan: Task 13's review found that a push launch opened a relay socket, predating this phase (#1240, #1241). Decided by the agent, pending ask #1040 (the list).

**Files:** `WatchtowerMobile/Sources/App/Hubs/HubSession.swift`, `WatchtowerMobile/Tests/PushLaunchSocketTests.swift`, `docs/features/relay-client.md`.

**Behaviour:** a session booted in the background on a relay route does not call `start()`, so it wants no socket; `fetchForPush` goes over HTTPS, logging in when it must; the first `setActive(true)` starts the transport once. A push fetch that brought nothing while the relay is held is `.failed`. CloudKit routes are unchanged. A cold tap launch can read a non-active state at boot, so it may connect at activation rather than in the boot, with no path leaving a person with no socket.

## #1246 — Latency samples

### Task 14: Stamps and storage

**Depends on:** Task 5 (the same file, `ActionOutbox+Ordered.swift`)

**Files:**
- Create: `WatchtowerKit/Sources/WatchtowerSync/Replica/ReplicaStore+Latency.swift`, `WatchtowerKit/Sources/WatchtowerSync/Relay/ActionEffectKinds.swift`
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Relay/ActionOutbox+Ordered.swift` (stamp), `RelayFeed.swift` (echo), `Replica/ReplicaHydrator.swift` (effect), `Replica/ReplicaStore.swift` (`adoptRoute` deletes pending; the tables), `WatchtowerKit/Tests/Fixtures/link/hub_contract_cases.json` (`action_effect_kinds`)
- Create: `internal/hub/actions/handlers/nudge_fixture_test.go` (test-only: `TestNudgeTableMatchesTheSharedFixture`)
- Test: Create `WatchtowerKit/Tests/WatchtowerSyncTests/ActionLatencyTests.swift`; extend `HubContractFixtureTests`

**Schema** (`CREATE TABLE IF NOT EXISTS`, the replica's pattern):

```sql
latency_pending(action_id TEXT PRIMARY KEY, kind TEXT NOT NULL, transport TEXT NOT NULL,
                written_at REAL NOT NULL, answered_at REAL, effect_at REAL)
latency_samples(at REAL NOT NULL, transport TEXT NOT NULL, answer_ms INTEGER NOT NULL, result_ms INTEGER NOT NULL)
```

**Interfaces (Produces):**

```swift
public enum ActionEffectKinds { public static func kinds(for actionKind: String) -> [String] }
public struct LatencySample: Equatable, Sendable { public let at: Date; public let transport: TransportKind; public let answerMs: Int; public let resultMs: Int }
extension ReplicaStore {
    func latencyWritten(actionID: String, kind: String, transport: TransportKind, at: Date) throws
    func latencyAnswered(actionID: String, applied: Bool, at: Date) throws
    func latencyEffect(kind: String, at: Date) throws
    func latencyDrop(actionID: String) throws
    func latencySweep(now: Date) throws
    public func latencySamples(since: Date) throws -> [LatencySample]
    public static let latencyResultWait: TimeInterval = 60
    public static let latencyWindow: TimeInterval = 604_800
    public static let latencyMaxRows = 5_000
}
```

**The three stamps** (spec §10, "action write → echo seen → slice with the effect seen"; Open decision 4):

- **Written:** in the ordered flush, the start of the save that returned `.saved` for that row, when the kind has effect kinds. A kind with none, and the legacy path, leave no row: legacy `save` only queues into the engine, so its time would mean nothing. The transport is the session's route at that moment.
- **Answered:** `RelayFeed` on the action's final echo. `applied` stamps; any other final status drops the row.
- **Effect:** `ReplicaHydrator` on storing a slice of an effect kind stamps every open row of an action kind that maps to it (the earliest wins, and a slice seen before the echo counts: slices and echoes travel in two zones). Open decision 5.
- **The sample** lands when both stamps exist: `answer_ms = answered − written`, `result_ms = max(answered, effect) − written`. A negative value (a clock moved) drops it. Both in one transaction with the pending row's delete, so two ends cannot record twice.

**Dropped, no sample:** a row older than `latencyResultWait` (60 s, the hub's `SaveWait`), swept on each settle and at launch; a route move (`adoptRoute`); a `resend_from` that rewrites the row; `skip_to` or Not delivered. Kept at most 7 days and 5 000 rows per replica, pruned on the sweep. Each write is a short transaction of its own, never joined to the outbox's.

**Failure classes.** A closed Mac: the row expires. A failure midway: a failed stamp write logs a code and never fails the action (the probe sits outside the action's path in a `do/catch`). A restart: the row lives in the file and either finishes within its 60 s or expires at the launch sweep.

**Effect table.** `ActionEffectKinds.table` mirrors `handlers.NudgeTable`, and the fixture section is the two-sided pin: a Kit test and the Go test each compare their table to it, so a new handler nudge fails one side until both change. A kind this build does not know has no row.

- [ ] **Step 1: Failing tests** (`ActionLatencyTests`, a real `ReplicaStore`, `InMemoryCloudTransport`, an injected clock):
  - `testAnActionWithItsEchoAndSliceRecordsOneSample` (exact ms);
  - `testASliceBeforeTheEchoCounts` (`result_ms` is the echo's);
  - `testAQueuedOfflineWaitIsNotCounted` (the first save refused, 10 min pass, then saved: `answer_ms` starts at the second);
  - `testANonAppliedEchoDropsTheRow` (`failed`, `expired`, `cancelled`);
  - `testAnUnrelatedSliceDoesNotStamp`;
  - `testAKindWithNoEffectLeavesNoRow`, `testALegacyActionLeavesNoRow`;
  - `testARouteChangeDropsThePendingRow`, `testAResendDropsThePendingRow`;
  - `testAnUnfinishedRowExpiresAfterSixtySeconds`;
  - `testARelaunchMidwayFinishesOrExpires`;
  - `testABackwardClockDropsTheRow`;
  - `testPruneKeepsSevenDaysAndFiveThousandRows`;
  - `testASampleHoldsNoIDOrKind` (the table's columns are exactly the four);
  - `testAStampFailureDoesNotFailTheAction`;
  - `testTheEffectTableMatchesTheSharedFixture`.
  Go: `TestNudgeTableMatchesTheSharedFixture`.
- [ ] **Step 2: Run, expect failure:** `make kit-test FILTER='ActionLatencyTests|HubContractFixtureTests'`, `go test ./internal/hub/actions/handlers -run TestNudgeTable`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run the same, plus** `FILTER='ActionOutbox|RelayFeed|ReplicaHydrator'`, `go test ./internal/hub/wire`, `make lint-swift`, `make lint-diff`.
- [ ] **Step 5: Commit:** `feat(kit): content-free action latency samples on the phone (#1246)`

### Task 15: Settings → Diagnostics

**Depends on:** Tasks 1, 14

**Files:**
- Create: `WatchtowerMobile/Sources/Features/Settings/LatencyDiagnosticsModel.swift`, `DiagnosticsView.swift`
- Modify: `SettingsView.swift` (a **Diagnostics** row replaces the inline `BatterySection`, which moves into the new page unchanged), `AppEnvironment.swift` (read every session's samples)
- Test: Create `WatchtowerMobile/Tests/LatencyDiagnosticsModelTests.swift`; `SettingsWiringTests.swift` (**changed:** the battery section's place, named here because every Release user sees it; Open decision 11); extend `ScreenshotTourTests.swift` (S37–S40, S48); `make mobile-gen`

**Interfaces (Produces):**

```swift
struct LatencyDiagnosticsModel: Equatable {
    enum State: Equatable { case loading, empty, needsMacUpdate, failed, rows([Row]) }
    struct Row: Equatable { let title: String; let count: String; let result: String; let answer: String }
    static let header = "Action → result on screen · 7 days"
    static let footer = "Measured on this iPhone only. Nothing is sent anywhere."
    static let emptyText = "No timings yet. They appear after your first action."
    static let needsMacUpdateText = "Timings need an updated Watchtower on your Mac." // no sample and no hub on the ordered path: legacy actions are not timed
    static let failedText = "Couldn't read the timings."
    static let loadingText = "Reading timings…"
    static func rows(_ samples: [LatencySample]) -> [Row]   // Relay first; a transport with none has no row
    static func seconds(_ ms: Int) -> String
    static func percentile(_ sorted: [Int], _ p: Int) -> Int // nearest rank, as the hub
    let toneUses: [ToneUse]
}
```

`seconds`: under 1 s two decimals with a trailing zero trimmed (0.31, 0.7); 1 to under 10 s one decimal (6.8); from 10 s a whole number (22). `count`: "1 action", "214 actions". `result`: "p50 0.31 s · p90 0.7 s". `answer`: "Mac's answer: p50 0.12 s · p90 0.3 s". Samples from all hubs' replicas are merged on a background task; one replica's read error makes the whole state `.failed` with **Retry**, because partial numbers would read as true. A linked hub added later simply adds samples.

- [ ] **Step 1: Failing tests:** `testRowsForRelayAndICloud` (mockup numbers from a built sample list); `testNearestRankPercentiles`; `testSecondsFormat` (table); `testOneActionIsSingular`; `testATransportWithNoSamplesHasNoRow`; `testEmptyLoadingAndFailedCopy`; `testNoOrderedHubSaysToUpdateTheMac`; `testOneFailedReplicaFailsTheRead`; `testRetryReadsAgain`; `testHubsAreMerged`; `testTonesAreDeclared`. `SettingsWiringTests`: `testBatteryLivesInDiagnostics`.
- [ ] **Step 2: Run, expect failure:** `make mobile-gen`, `make mobile-test SIM='iPhone 17 Pro' MOBILE_FILTER='LatencyDiagnosticsModelTests|SettingsWiringTests|BatteryDiagnosticsTests'`.
- [ ] **Step 3: Implement.** Shots S37–S40, S48.
- [ ] **Step 4: Run the same;** `make lint-swift`.
- [ ] **Step 5: Compare** the shots with the mockup; note differences for the PR body.
- [ ] **Step 6: Commit:** `feat(mobile): Diagnostics shows action timings per transport (#1246)`

---

## #1243 — Docs and the gate (serving all three targets)

### Task 16: Guide, feature notes, spec text

**Depends on:** Tasks 2–15, 18

**Files:**
- Create: `docs/guide/features/iphone-relay.md` (what Relay does, subscribing, restoring on a new iPhone and re-linking by QR, the choice per Mac, a refused purchase with Manage Subscription and Apple's refund page `https://reportaproblem.apple.com`, what "Relay unavailable" and "Switch to iCloud" mean, the ended and moved messages; Open decision 11). Its first line is "Relay isn't in the current version of Watchtower for iPhone." No Learn card yet: `done_when`/`requires` have no Relay signal, and a card would call users to a screen their build lacks. Every section carries `<!-- learn: none -->` until launch (Launch conditions). `docs/guide/README.md` gets one entry for the page, whose description is that line exactly.
- Modify: `docs/guide/features/iphone-alerts.md`: its existing **Alerts over Relay** section (written with the Go hub) opens with the line above, adds the switch, and loses its `iphone-alerts-relay` card (`<!-- learn: none -->` until launch, Launch conditions).
- Modify: `iphone-not-delivered.md`: a new **Over Relay** section (a lapse; the Relay-unavailable banner above Waiting to send), `<!-- learn: none -->`, opening with the line above. `iphone.md`: the same line with one link to `iphone-relay.md`, and Diagnostics (iCloud timings, no Relay promise).
- Modify: `troubleshooting/iphone-not-syncing.md`: the line, at its first mention of Relay on a phone ("Subscribe on it"). The pages not named `iphone*` (`README.md`, `privacy.md`, `headless-host.md`, `cli.md`, `settings.md`) describe the Mac and a headless host; `git grep -il relay -- docs/guide` lists them, a sentence promising a phone user Relay today gets the line too, and the PR body lists each page and what it did, because the test does not cover them.
- Test: Create `docs/guide/relay_dark_test.go`: `TestRelayGuideSaysNotYet` (every `docs/guide/**/iphone*.md` that mentions Relay contains the line exactly, `troubleshooting/iphone-not-syncing.md` included; `README.md`'s entry for `iphone-relay.md` contains it; it is the first text under the title of `iphone-relay.md`, and the first text of the Relay section on `iphone-alerts.md` and `iphone-not-delivered.md`; no `<!-- learn` card under `docs/guide/` has an id containing `relay`). It is removed with the line at launch.
- Modify: `docs/features/relay-client.md`: a Phase 4 section (`HostedRelayAccount`, `RelayAccountCenter`, `requestTransport`, the banners, `RelayPushWake`, the registrar, the extension, latency); v1 limits: remove "No pushes", "the upgrade is model only", "No switch screen", the StoreKit and APNs parts of the fake's list; add the limits this plan names (a shared-scope alert lost in a move's window, a duplicate alert at a switch, a developer's mismatched push environment, legacy actions unmeasured, an outage's minute count restarting at relaunch, a slice of the same kind from another cause can end a timing early).
- Modify: `docs/features/mobile-companion.md` (push routing, the extension's inline path), `CLAUDE.md` (the feature line names Phase 4), `docs/superpowers/specs/2026-10-31-hub-phone-protocol-design.md` (§4.8, §11 item 5 done; §7.6 `reason` on `transport_switch` for a move), `docs/superpowers/specs/2026-10-29-relay-client-design.md` (§10 what the timing stamps are; §14 the guide page; Decisions: one line per answered Open decision).

- [ ] **Step 1: Edit.** Bold UI text, no internals, per `docs/guide/WRITING.md`.
- [ ] **Step 2: Run:** `go test ./docs/guide ./internal/learn` passes (the 8 KB cap, `TestRelayGuideSaysNotYet`); `bash scripts/leak-check.sh` over the branch's commits finds nothing.
- [ ] **Step 3: Commit:** `docs: relay client Phase 4 — guide, feature notes, spec text (#1243, #1244, #1246)`

### Task 17: Phase 4 gate

**Depends on:** Tasks 1–16, 18

- [ ] **Step 1: Kit and Desktop:** `make test-swift > "${TMPDIR:-/tmp}/p4-swift.log" 2>&1; echo "exit=$?"`. Expect `exit=0`; interop classes skip.
- [ ] **Step 2: Phone:** `make mobile-build SIM='iPhone 17 Pro'`, `make mobile-test SIM='iPhone 17 Pro' > "${TMPDIR:-/tmp}/p4-mobile.log" 2>&1; echo "exit=$?"`. Expect `exit=0`.
- [ ] **Step 3: iOS build of the relay targets:** `cd WatchtowerKit && xcodebuild build -scheme WatchtowerHostedRelay -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO > "${TMPDIR:-/tmp}/p4-ios.log" 2>&1; echo "exit=$?"`.
- [ ] **Step 4: Go:** `make test > "${TMPDIR:-/tmp}/p4-go.log" 2>&1; echo "exit=$?"`.
- [ ] **Step 5: Lint:** `make lint-all`, with no new issues.
- [ ] **Step 6: Boundaries:**
  - the guard-file diff is empty;
  - `git diff --stat origin/feature/relay-client-next -- WatchtowerDesktop/Sources internal/hub ':!internal/hub/actions/handlers/nudge_fixture_test.go'` is empty;
  - `grep -rn 'import StoreKit' WatchtowerMobile/Sources WatchtowerKit/Sources` names only `StoreKitRelayStore.swift`;
  - `grep -n 'WatchtowerHostedRelay' WatchtowerMobile/project.yml` shows it under the app target and the tests only;
  - `grep -rn 'workers.dev\|relay-staging' -- . ':!*.lock'` finds no URL in tracked files outside the relay docs' placeholders;
  - `WATCHTOWER_RELAY_ORIGIN` is still empty in `Base.xcconfig` and forced empty for Release.
- [ ] **Step 6a: Signed Release archive:** `make mobile-archive > "${TMPDIR:-/tmp}/p4-archive.log" 2>&1; echo "exit=$?"` with the owner's `Signing.xcconfig`. CI is unsigned and cannot see this. A signing failure naming App Attest before the portal step is the expected result: record it in the PR body. **Pre-main condition:** `feature/relay-client-next` does not merge into main until this command gives `exit=0` (owner-only step 3, Open decision 2).
- [ ] **Step 6b: Launch conditions:** copy the section's table into the PR body with each row's state.
- [ ] **Step 7: Interop** (local, recorded in the PR description): `make relay-interop-kit RELAY=…`, `make relay-interop-kit-hub RELAY=…`, `make relay-interop-kit-hub RELAY=… RELAY_INTEROP_DESKTOP=1`, with a clean relay worktree at the `VERSION` commit. The third run's step 8 exercises the lapse the policy now decides (Task 3). The stand has no App Store or APNs, so purchases and pushes stay manual.
- [ ] **Step 8: Shots:** `make mobile-shots SIM='iPhone 17 Pro'`. Compare S01–S57, with the frames S12b, S19b, S34b, S34c, S36b, S37b, S41b, S41c, S45b and S57b, with mockup section 8 in light, dark and narrow; list every difference in the PR description.
- [ ] **Step 9: Commit** gate fixes, if any: `fix: relay client Phase 4 gate (#1243, #1244, #1246)`. The PR into `feature/relay-client-next` carries the manual checks below, unrun.

## Manual checks for the PR bodies (Open decision 14)

They need what only the owner can provide (see "Owner-only steps") or a physical iPhone; staging with APNs and an App Store sandbox.

- **M1. Buying.** A sandbox purchase on a device against staging: the price from App Store Connect, the subscription active, the card "Active". A second buy in a paid period charges nothing, in the sandbox (proven only under StoreKit Testing so far).
- **M2. A real App Attest.** The first `register`/`login` with attestation on (spec §4), including on `TestFlight` (production environment).
- **M3. Moving.** Restore Purchases on a second iPhone: the first says "moved" and falls back to iCloud; the new one re-links by QR; at most 3 moves in 30 days.
- **M4. A silent push on a locked phone** (after the first unlock) wakes the app and the background login's assertion succeeds on `fetchForPush`'s path; the replica has the change on next open. Count sockets on a locked launch: none until the first activation (Task 19).
- **M5. An ask alert.** With the app killed, the alert shows its real title and body; a tap opens the ask; resolving the ask removes the notification.
- **M6. A lapse.** A sandbox subscription expiring (accelerated renewal): the phone and the Mac return to iCloud; unechoed actions resent or listed; Subscribe works again.
- **M7. Relay unavailable.** Block the relay host: the banner at 60 s, the offer at 10 min, Switch to iCloud reaching the Mac.
- **M8. The goal.** Settings → Diagnostics on a good network: Relay p50 under 500 ms.
- **M9. Confirmations and screens** that shots cannot capture on iOS 26 or the demo hides: Forget This Mac's layout and confirmation, Cancel Link; the banners' subscription sheet and its **Close**; **Manage Subscription** opens Apple's subscriptions page (`https://apps.apple.com/account/subscriptions`).
- **M10. Xcode-signed builds:** `WTPushEnvironment` matches the signed `aps-environment`; a mismatch shows Desktop's no-token line.

## Decisions

Every decision in this plan, with its source. "Decided by the agent" items that change a contract or a behaviour the owner has not approved are also in "Open decisions" below.

| Decision | Source |
|---|---|
| Hub-side parts (indicators, `send_alert`, hub samples) are the Go hub's; gaps listed, no tasks here | ask #802 |
| PRs target `feature/relay-client-next` | ask #958 |
| Phase 4 merges without a device check | ask #1038, Open decision 14. Ask #884 answered this for Phase 1 and "без проверки мержи" for 0a; neither names Phase 4 |
| Ships dark, with no Release origin | ask #904 (Owner approval 1, Phase 3) |
| A proven relay-id record moves the id from another hub row; handled separately and treated as done here | ask #1005 |
| The hello's relay-id proof is deferred | ask #980 (3b decision 6); before launch: Open decision 13 |
| No automatic fallback to iCloud on an outage; the offer after 10 min | relay design §4.1; spec §9 |
| Macs and slots: at most 3 slots, 5 replacements in 30 days | relay spec §3, §8; spec §8 |
| Upgrade refusal texts come from Phase 3b unchanged | ask #980 |
| The phone's design shots are `ScreenshotTourTests` | Phase 1 Ruling 14 |
| The relay's `Error.message` is never shown | relay `proto/README.md` |
| One reader of `HostedRelaySession.events`, the center | decided by the agent (Phase 3's "for one reader") |
| A failed account read is `unknown`, never free | decided by the agent, by analogy with Phase 3's `canUseRelay` (ask #904) |
| No persisted subscription state or JWS | decided by the agent; relay README "never submit a cached JWS" |
| `finish` only after an entitlement answer | decided by the agent; Open decision 19 |
| No relay read at launch with no `relay_auth` | decided by the agent; spec §4 "first use" |
| The account is read at every reconnect too | spec §7 |
| A relay-only hub's banner comes before moved and ended, whose "back on iCloud" would be false there | decided by the agent |
| A refused transaction is sent once per launch by the automatic paths; an owner's press (Restore, Try Again) is exempt | decided by the agent, exemption from the owner's comment on ask #1012; relay README |
| A purchase Apple sold and the relay did not confirm stays visible after a kill: the subscription screen shows its outcome and offers no Subscribe for that paid period, the Relay card and the Connection row say "not confirmed" | owner's comment on ask #1012 |
| A background pass and a renewal never write a running or failed purchase state, and show nothing on a paying phone; a renewal with no relay is not "unconfirmed" | owner's comment on ask #1035; `isRenewal` decided by the agent |
| An `.active` or `.grace` answer settles a finished press to Done, any other answer is a refusal; closing the screen clears a finished press, and `.pending` stays | decided by the agent, review of asks #1036 and #1037 |
| **Restore Purchases** on the moved card runs on the subscription screen, which shows its progress and result | decided by the agent, review of ask #1037 |
| **Subscribe** returns when the period ends or is refunded; **Manage Subscription** is on every definite refusal | owner's comment on ask #1035; the link's text decided by the agent |
| Every Relay passage for a phone user opens with the "not in the current version" line, and the Go hub's `iphone-alerts-relay` Learn card waits for launch | owner's comment on ask #1012; the card's removal is Open decision 16 |
| Restore creates the identity on the press; the center starts on `identityAppeared()` | decided by the agent; spec §4 "first use" |
| A switch from a lapsed phone carries `entitlement_expired`, Try Again keeps the record's reason | decided by the agent; Open decision 6 |
| The foreground retry of the alert save applies only to a link on the relay or one that ever switched | decided by the agent |
| No Learn card before launch | decided by the agent; Open decision 16 |
| The ended and moved banners show once per loss, with **OK**, through one persisted flag | decided by the agent |
| A relay-only hub is never asked for iCloud on a lapse | spec §8; decided by the agent for "no request" |
| `macReachable` is the heartbeat check; locked keys read as reachable | decided by the agent |
| Subscribe opens a pushed screen from Macs, a sheet from Now | decided by the agent |
| A lapse replaces a pending upgrade request, the slot kept | decided by the agent, mirrors the hub's "superseding" and ask #977 (slot kept) |
| A request toward iCloud waits 24 h, then a refusal the owner can leave; an owner's request is withdrawn, a lapse's is kept | decided by the agent, the 3b reader wait's limit; Open decision 15 |
| The alert registrar targets the hub's CloudKit route on any transport | decided by the agent; Open decision 18 |
| `transport_switch` toward iCloud goes on both transports with one id, the iCloud copy written directly | spec §9, relay design §4.2 p. 2 |
| `RelayPushWake` lives in `WatchtowerSync`, so the extension links no relay target | Phase 3 R20; decided by the agent for the file's place |
| `hub_id` is read from the envelope's clear header | protocol §4.6; decided by the agent, since the APNs body names no hub |
| The push token is in memory only | decided by the agent |
| Samples: 60 s wait, 7 days, nearest rank, as the hub; 5 000 rows per replica | Go hub Phase 4 plan for the first three; decided by the agent for the row cap |
| A failed replica fails the Diagnostics read | decided by the agent |
| Legacy actions are not timed, and Diagnostics says to update the Mac | decided by the agent |
| Now shows one banner at most, in a fixed order | decided by the agent; Open decision 17 |
| An upgrade running when the subscription lapses is refused by the hub (`not_paying`) and shows Phase 3b's refusal; the superseding path looks unreachable on an iCloud route | decided by the agent, Task 5 |
| A store failure is `PurchaseState.storeFailed`, S57, "The App Store didn't finish. Nothing changed; you can try again."; a cancelled sign-in is not a failure | decided by the agent, Task 6; pending ask #1040 (the list) |
| The center's first pass runs from `foreground()`, not `start()`, so a push launch stays frugal | decided by the agent, Task 6, amends its brief's "at launch and each foreground" |
| An expiry control and `.entitlementInactive` sweep before they read, so an unsent renewal cannot lapse Macs | decided by the agent, Task 6; pending ask #1040 (the list) |
| A paying read corrects an expiry control, so no lapse; a failed read after a control still lapses | decided by the agent, Task 6's review, amends its brief's "refresh, then lapse" |
| A non-nil `unconfirmed` wins over `.storeFailed`, `.pending`, `.noSubscriptionFound` and `.accountFailed`, so a charged owner never reads false text | decided by the agent, Tasks 6 and 9, overrides their "What shows" |
| `updateRequired` stops a sale, not an answer: it overrides `.idle`, `.loadingProduct`, `.ready`, `.productFailed`, `.storeFailed`, `.noSubscriptionFound`, `.accountFailed`; S43 shows with no press and no `unconfirmed`; order: running press, paying, unconfirmed, latch, result | decided by the agent, Task 9, corrected in its fix round; pending ask #1040 (the list) |
| A retry on a result with no price reads **Load the Price** (S45b, S57b) | decided by the agent, Task 9; pending ask #1040 (the list) |
| An iCloud row with no `ordered_actions` on a relay route is disabled and reuses `.notOrdered`'s text (S12b), replacing a first ruling's new string | decided by the agent, Task 8 |
| The registrar's foreground gate stands against the spec's "at every launch": a token waits for the next open | decided by the agent, Task 13 |
| `device_payload_kit_only` stands until the Go half, because Go's `TestDevicePayloadCases` re-marshals every case | decided by the agent, Task 13; the move is in Launch conditions |
| A push launch opens no socket until the first activation: new Task 19; a tap launch can connect at activation rather than in the boot | decided by the agent, Tasks 13 and 19; pending ask #1040 (the list) |
| `AlertSubscriptionRegistrar.idle()` is capped at 10 s, like `outboxDrainCap`, against its brief's "no cap": a hung CloudKit call must not leave a stopped session with no error | decided by the agent, Task 18; pending ask #1040 (the list) |
| New frames S34b, S34c, S36b, S41b, S41c: back-on-iCloud is said only once the route moved; a refusal keeps the press; "Switching to iCloud…" alone once the relay answers again | decided by the agent, Task 10 |
| Now's banner is a plain card, not the mockup's amber, because orange means waiting for you (`PhoneTone`, `OrangeToneTests`) | decided by the agent, Task 10; pending ask #1040 (owner rules on it by name) |
| S34b's text: "Your Relay subscription ended. Work Mac moves to iCloud when it's back." with **Subscribe** **OK** | decided by the agent, Task 10; pending ask #1040 (owner rules on it by name) |
| Task 5 starts beside Task 4's investigation, off next | decided by the agent, execution order only |
| Tasks 6 and 14 start before Tasks 2, 4 and 5 clear CI, on branches built from their reviewed heads | decided by the agent, execution order only |
| Tasks 7 and 13 run in parallel off Task 6; Tasks 9 and 15 run in parallel, on separate simulators | decided by the agent, execution order only |
| S01's chevron, the card's button trait and `lineRow`'s Spacer wrap go to Task 8, which edits the same file | decided by the agent, execution order only |
| The Go hub's `headless-host-run` Learn card waits for launch too: it tells users to pair a phone their build cannot pair | decided by the agent, under Open decision 16 |
| Phone tests are signed locally with the private test key `com.apple.appstored.octane` (`StoreKitTesting.entitlements`), which never reaches an archive or TestFlight | decided by the agent, Task 4; pending ask #1040 (the list) |
| `iphone-relay.md` and the other Relay passages stand on a dark build, against `docs/guide/WRITING.md` rule 7 ("Only what ships on `main`"): do not delete them as unshipped. They leave or change at launch (Launch conditions) | owner's comment on ask #1012, which overrides rule 7 for this page |
| Every one of the 19 Open decisions below on its recommended option | ask #1038 |

## Open decisions for the owner

**Answered:** ask #1038 approved all 19 on their recommended options. Open decision 3's price stays with the owner, in App Store Connect. Ask #1040 is open on the banner's colour, the S34b text and seven of the agent's decisions, each marked above.

Each is a proposal with a recommended option. Approving the plan accepts each recommendation; a comment on the approval overrides that decision. Anything raised later goes into its own ask before that task's review. Each Alternative or "Refused" says what changes if it is not taken, and in which task.

1. **"When work stops" off on a relay phone.** The relay's token is phone-wide, has no unregister, and silent pushes need it; the extension must deliver what it gets; so the switch cannot stop `send_alert` from the phone alone. **Recommended: A.** The phone writes `work_alerts_off` in its `device` record, and the hub skips the push (contract §5.5). **Named as Task 23 was:** approving A approves one optional field and the Go half, `wire.DevicePayload`, the store write in `ApplyDeviceRecord` and the check in `alerts.Eligible`, a dual path with Task 13's Kit field that the Go hub session writes (Launch conditions), on top of G1. B: Apple's notification-filtering entitlement lets the extension drop it; approval is uncertain and takes an owner request. C: accept, with the footnote "On Relay, this switch doesn't stop alerts yet."
2. **The App Attest entitlement in Release now.** A signed archive fails until App Attest is on for the App ID. **Recommended:** add it in Task 4; `feature/relay-client-next` does not reach main until the owner turned it on and Task 17's signed archive passes. Alternative: leave the line out until launch, and nothing blocks main.
3. **Product.** **Recommended:** `com.aiwatchtowers.watchtower.relay.monthly`, one monthly auto-renewable, Family Sharing off; the price is set only in App Store Connect, and the `.storekit` file's is a placeholder. Owner: confirm the id and name the price.
4. **What the timing means.** **Recommended:** it starts at the start of the save that put the action on the transport (spec §10's "action write"), so an offline queue does not count, and Diagnostics shows the end-to-end row plus a "Mac's answer" line (mockup amended, spec's "the phone's steps"). Alternative: start at the owner's tap, with one line as the mockup drew.
5. **What ends a timing.** **Recommended:** the first slice of a kind in a table that mirrors `handlers.NudgeTable`, pinned by a shared fixture and one test-only Go file. Cost: a slice of the same kind from another cause can end it early. Alternative: the next non-heartbeat slice of any kind, no table, biased low.
6. **A subscription move uses `reason: entitlement_expired`.** The hub knows that reason only, and a plain request would take a Mac away from another paying phone. **Recommended:** yes, no contract change. Alternative: a new `subscription_moved` reason plus a Go hub change.
7. **After a purchase the Macs stay where they are.** The owner picks Relay per Mac, as spec §9 places it. **Recommended:** yes; the Done screen says so. Alternative: offer "Switch all my Macs" on Done.
8. **Terms and Privacy links.** App Review requires both on the subscription screen. **Recommended:** build settings, owner gives the URLs before launch; empty hides the link in development builds. Refused → the links are fixed in Task 9's model.
9. **The relay account id in the Keychain** (`relay.account`), since every `register` spends a fresh attestation. **Recommended:** yes, private group, never synced; an id, not a secret. Alternative: register once per process.
10. **A second alert at a switch to iCloud** (G3): rare and not suppressible on the phone. **Recommended:** accept as a v1 limit. Refused → the Go hub session changes `Resignal` (G3); no task here.
11. **Two visible changes for free users.** Settings → Diagnostics is a new page in every Release build, the Battery section moves into it, and every ordered action writes one small timing row. **Recommended:** yes (spec §10 places Diagnostics next to the battery report). Alternative: keep Battery in place and show Diagnostics only with a relay origin; iCloud timings then stay out of sight.
12. **A 4th Mac on a phone with three in slots** (protocol open point 7; the registry allows 4, a subscription 3). **Recommended:** the Mac stays on iCloud; its Relay row says "Your subscription already has 3 Macs." with **Manage Macs**. Refused → Task 8's row offers Remove on the spot.
13. **The hello's relay-id proof before launch.** It stays deferred in this plan (ask #980). An owner-confirmed phone is the only one that could misname an id, and a device record's proof already moves it (ask #1005). **Recommended:** keep it deferred past launch. Alternative: add it before launch (Kit, Go, the `device_hello` fixture).
14. **Phase 4 without a device check before merge.** Ask #884 was about Phase 1, and "без проверки мержи" about 0a; this phase adds purchases and real pushes that no CI or stand can run. **Recommended:** merge into `feature/relay-client-next` on green CI and review, and run M1–M10 on staging as a launch condition. Alternative: M1 and M4 on a device before this phase's final merge.
15. **A request toward iCloud that nobody answers.** **Recommended:** 24 h, the 3b reader wait's limit, then a refusal with **Try Again**; an owner's request is withdrawn and a lapse's stays in the mailbox. Alternative: no limit, with a **Cancel** button (Tasks 5 and 8, S52 goes).
16. **Guide and Learn while Relay is dark.** Spec §14 puts Relay in `iphone.md` and a Learn card in the Phase 4 PR, but `iphone.md` is near its 8 KB cap and the feature is off in Release. The branch already carries the Go hub's **Alerts over Relay** section and its `iphone-alerts-relay` card, which sends a phone user to something their build lacks. **Recommended:** a new page `iphone-relay.md` and every other Relay passage for a phone user open by saying Relay is not in the current version, one link from `iphone.md`, and the Learn cards, the Go hub's included, only at launch. Alternative: hold the page and the card for the launch release too (Task 16 shrinks to the feature notes), or ship the card now, which sends users to a screen their build lacks.
17. **One banner at a time on Now.** Mockup section 6 drew the moved banner and the update line together. **Recommended:** one, in the fixed order of Task 10, because a phone screen has little room; the frame is split. Alternative: stack two (Task 10's model returns a list).
18. **The CloudKit alert subscription stays while on the relay.** Spec §10 says it stays "for CloudKit phones only". **Recommended:** keep it for any hub offering CloudKit: it is silent on the relay, and the hub's re-signal at a switch back fires before the phone has followed (a `push_off` alert aside, G4). Alternative: remove it on the move, with a retried removal, and lose those re-signalled alerts (Task 18 changes to that).
19. **A refused purchase is not finished.** Money was taken and the relay said no. **Recommended:** leave it unfinished, sent once per launch by the automatic paths, with an owner's press exempt; it counts only while its paid period is current, so a permanent refusal ends with the period, and **Manage Subscription** lets the owner cancel at Apple; a move refused for its age passes through Restore. Alternative: finish on a definite refusal, leaving only Restore (Task 6).
