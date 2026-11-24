# A Relay phone links to an iCloud Mac, and the Mac moves to Relay — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A phone that pays for Relay links to a Mac whose hub runs on iCloud over a Relay pairing slot, and after the owner's **Link** the hub moves itself to Relay on a fresh account read that lists that phone as paying.

**Architecture:** Three independent halves. The phone's pure route rule (`LinkRoutePolicy.decide`) sends a paying phone to `.relay` for any code that offers Relay. The Go hub derives a *relay-linked candidate* from `devices` and `hub_meta` and accepts a switch to Relay through the existing `Switcher.accept` (`by` = that phone), in a new `checkRelayLink` run from `PollOther`. The Mac's pairing sheet warns before **Link** when the move would cut off iCloud phones. No migration, no phone-wire change.

**Tech Stack:** Go 1.26 (`internal/hub`, `internal/hub/switcher`, `internal/hub/link`, `cmd`), SwiftUI iPhone app (`WatchtowerMobile`), `WatchtowerKit`, SwiftUI macOS app (`WatchtowerDesktop`).

**Spec:** `docs/superpowers/specs/2026-11-24-relay-pairing-on-icloud-mac-design.md` (approved, ask #1756; every open question takes its written default: Q1 keep the relay-code fallback with the existing text, Q2 refuse an unanswered check only with a device entitlement, Q3 existing state, Q4 Connection → **Relay**, Q5 `hub_meta.relay_link_since`, Q6 keep the Mac warning).

**Target:** #2191 · **Umbrella:** #2187 (`umbrella/2187-iphone-pairing`). Inside the umbrella: no GitHub PR per task, the gate runs in the lane's worktree, then `git merge` into the umbrella (CLAUDE.md "Build & Test").

## Global Constraints

- No goose migration, no new `devices` column, no `internal/db/schema.sql` change. The only new persistent value is the `hub_meta` row `relay_link_since` (RFC 3339, the `stamp` format `announce.go` uses for `switched_at`), written once.
- No phone-wire change: `TestHubContractFixture` and `TestHubContractFixture_RecordingSwitch` (`internal/hub/wire/contract_test.go`) pass unedited. The one new key is on the Mac's local `hub pair --json --stream` `sas` line (`moves_to_relay`), which is not the phone wire.
- New user-visible text: exactly one Mac line (Q6), verbatim: `Linking this iPhone moves <Mac> to Relay. iPhones linked over iCloud without Relay lose their connection until they subscribe.` Every other outcome reuses existing copy (`LinkFailure`, follower banners, Settings → Mobile rows).
- New daemon log lines, verbatim: `hub: a phone linked over Relay pays: transport switch to relay accepted`, `hub: a phone linked over Relay: switch waits (<class>)`, `hub: no iCloud code (<class>): a Relay code instead`. Logs carry classes only, never ids.
- An unknown paying answer (failed read, timeout, `ErrNotFresh`, phone not listed) never counts as paying on the hub.
- The App Store build keeps the relay `.off(.notConfigured)`; nothing in this plan changes `RelayAvailability.evaluate`.
- `LinkRoutePolicyTests` stays unedited except `testACloudKitCodeLinksOverICloud`, which gains the free/off precondition and keeps its name. No guard test is weakened.
- Mac UI: design kit only (`WatchtowerDesktop/Sources/DesignKit/`), colours only through `Tone`, no row separators, no stock look (`docs/design/desktop-style-guide.md`).
- Docs in English; the repo is public: no live ids, names or paths in tests, fixtures or docs.
- Tests never wait on wall-clock: `testing/synctest` bubbles and the rigs' clocks (the switcher `world`, `bubble`), fakes on the Swift side.

## Merged code vs the spec (re-checked on `umbrella/2187-iphone-pairing` after #2189 and #2190)

1. **`LinkingViewModel.open` and `connectRelay`: no contradiction.** After #2189 `open` still calls `LinkRoutePolicy.decide` right before the route `switch` (`LinkingViewModel.swift`, `open(_:)`), and `.relay(mac, authPub)` still goes to `connectRelay(RelayCode(…))`, which does not read `payload.transport`. #2189's `PendingLink.baselineSource`/`helloSent`/`baselineFingerprint`, `KeyboxRead` and `completionKeybox` sit in the CloudKit wait and in `connectRelay`'s one slot fetch; the relay path is the same for a code whose hub is on iCloud. The "already linked" short-circuit runs before the route rule, which matches the Q4 default (out of scope). Only the comment above the `decide` call ("the paying check only for a hub on the relay") changes, and the call gains the entitlement closure (Task 5).
2. **Q2 needs a StoreKit read that does not exist.** The only current-entitlement read is `StoreKitRelayStore.restore()`, which calls `AppStore.sync()` first (it may prompt for an Apple ID). Task 5 adds a non-syncing read (`Transaction.currentEntitlement(for:)` only) behind a new `RelayLinkOps.holdsRelayEntitlement()`.
3. **The Mac cannot tell the Q6 condition from what it reads today.** The `sas` line carries `device_id`, `name`, `code` only, and `hub phones`' `transport` reads `cloudkit` for an admitted relay phone while the hub is on iCloud, so "the phone paired over Relay" and "another phone has an iCloud route" are not visible to Swift. Task 4 lets the hub decide: `link.PairEvent` gains `OverRelay` (the hello has no iCloud user), and the runtime sets `MovesToRelay` on the `sas` event (`moves_to_relay` on the CLI line) when the phone paired over Relay, the active transport is CloudKit and another linked phone has an iCloud route (`state.Store.ICloudRoutes`). Local control-socket/CLI JSON only; no phone wire.
4. **F7 is not reachable from the Mac's UI.** On a CloudKit-active Mac whose iCloud account is unusable, the hub status reads `paused` (`ReasonNoICloud`) and `MobileSettingsModel` hides **Link** (`canLink` needs `state == "running"`, and `accountAllowsLinking` refuses `cloudkit` + an unusable account). The §4 fallback would only work from `watchtower hub pair` on the CLI. Task 6 keeps **Link** shown when the hub has a relay (`status.relay != nil`) and the only obstacle is iCloud. This adds no copy and no screen. It carries out the spec's decision "iCloud must not be needed for linking" (ask #1743).
5. **A plain `Kick()` cannot bypass the check's 5-minute throttle.** `Kick()` only wakes `Run` (Step + `PollOther`), and the spec bounds the check to one read per `NoPayerPoll` without a kick. Task 2 adds `Switcher.RelayLinkSoon()`, which marks the next check due and then kicks. The runtime calls it where the spec says `h.sw.Kick()` (Task 3).
6. **The guide page has almost no room.** `docs/guide/features/iphone-relay.md` is about 8.1 KB against the 8192-byte cap in `docs/guide/guide_test.go`. Task 7 tightens existing sentences on that page to fit the new paragraph. It never splits the page and never drops the "Relay isn't in the current version…" opening line.

## Review Focus

- **The iCloud account dies after the code is shown but before the switch (F7 at runtime, not at code issue).** Expected: the paired phone still links over the slot, and the switch to Relay completes with CloudKit held (`applyICloudHold`). The publisher's iCloud hold lifts once `switchedTo` re-runs `applyICloudHold` on the new active transport. Test: `TestRelayPairingOnADesktopWithoutICloudSwitches` (Task 3).
- **A relay-linked phone that was already admitted before the update (Q5).** Expected: no read and no switch. `relay_link_since` survives restarts and is never rewritten. Test: `TestRelayLinkBeforeTheUpdateIsNoCandidate` (Task 2).
- **A candidate that never pays (F5) on a Mac that stays up for days.** Expected: at most one account read per `NoPayerPoll`, never one per `OtherPoll` (30 s). Test: `TestRelayLinkReadsAtMostOncePerPollWithoutAKick` (Task 2).
- **A phone whose device holds an entitlement that has expired or was revoked.** Expected: it counts as "no current entitlement", so an unanswered check on an iCloud code links over iCloud. Test: `StoreKitRelayStoreTests.testOnlyAnUnrevokedUnexpiredTransactionIsCurrent` (Task 5).
- **A Mac without a relay (`RelayOrigin` unset) whose iCloud fails.** Expected: the old refusal (`no_icloud`/`icloud_unreachable`), never a relay code that links the phone nowhere. **Link** on the Mac stays hidden as today. Tests: `TestPairOnACloudKitDesktopWithoutICloudIsRefused` (its no-relay case, Task 1) and `MobileSettingsModelTests.testLinkStaysOnWithoutICloudOnlyWithARelay` (Task 6).

---

## Lanes

| Lane | Tasks | Worktree |
|---|---|---|
| A — Go hub | Task 1 and Task 2 in parallel. Task 4 in parallel with both. Then Task 3 (after 1 and 2). | one worktree per parallel task, merged by the controller |
| B — phone | Task 5 | own worktree, own `-derivedDataPath` |
| C — Mac UI | Task 6 | own worktree (copy main's `WatchtowerDesktop/.build` without `ModuleCache`) |
| — | Task 7 (docs) after 1–6, then the phase gate | umbrella worktree |

Every implementer brief carries `docs/review/review-rules.md` (Go sections; for Task 6 also "Swift / Desktop conventions") and this plan's Global Constraints. The implementer self-reviews against both before hand-back. Each task's review runs a Claude reviewer and the `codex-review` agent in parallel on the same diff (owner's global rule).

---

### Task 1: CloudKit codes list `relay` only with a relay, and a Mac without iCloud issues a relay code

**Depends on:** none

**Files:**
- Modify: `internal/hub/link/codes.go` (`issue`, the `ck != nil` branch and its doc comment)
- Modify: `internal/hub/control.go` (`supervisor.pair`)
- Modify: `internal/hub/cloudkit_runtime.go` (`pairCloudKit` doc comment only, if it names the refusals as final)
- Test: `internal/hub/link/codes_test.go` (create it if `TestIssueCloudKit*` lives elsewhere; put the test beside the existing `IssueCloudKit` tests in `internal/hub/link/cloudkit_test.go` otherwise)
- Test: `internal/hub/pair_cloudkit_test.go`

**Interfaces:**
- Produces: a CloudKit code's `Transports` is `["cloudkit"]` plus `"relay"` exactly when `HostInfo.Transports` contains `wire.TransportRelay`. On `no_icloud`/`icloud_unreachable` with `h.rel != nil`, `hub pair` answers like a relay hub's `OpPair` (`qr`, `waiting`, a `wire.TransportRelay` code with no CloudKit fields).

- [ ] **Step 1: Write the failing link test.** `TestIssueCloudKitTransportsFollowTheHost` is table-driven over `HostInfo.Transports`: `{cloudkit, relay}` → code `Transports == ["cloudkit","relay"]`; `{cloudkit}` → `["cloudkit"]`. In both cases `Transport == "cloudkit"` and `RelayDeviceID`/`RelayAuthPub` stay set (the identity is kept, spec §1).
- [ ] **Step 2: Extend `TestPairOnACloudKitDesktopIssuesACloudKitCode`.** Keep its assertions and add a second case. With `o.RelayOrigin = ""` on `startPairDesk`'s options (add an options hook parameter to `startPairDesk`; do not copy the rig), the code's `Transports` equals `["cloudkit"]`.
- [ ] **Step 3: Write `TestPairOnACloudKitDesktopWithoutICloudFallsBackToARelayCode`.** Use `startPairDesk(t, KindCloudKit)` (it has a relay origin) and `ck.acct.Store(transport.AccountNoAccount)`. `OpPair` yields a `qr` whose code has `Transport == "relay"`, an empty `Container`/`OwnerUser`, a nil `DataShare` and a set `RelayDeviceID`. The answer is OK. `codesStored == 1`. `ck.count("set_public_link:open") == 0`. A second subtest does the same with `icloud_unreachable` (follow `TestPairOnACloudKitDesktopWithICloudBriefyUnavailableIsRetryable` for how that class is produced).
- [ ] **Step 4: Make `TestPairOnACloudKitDesktopWithoutICloudIsRefused` the no-relay case.** Its only edit: start the rig with `RelayOrigin = ""` through the Step 2 hook. Every assertion stays (`no_icloud`, no `qr`, zero codes, the public link never opened).
- [ ] **Step 5: Run them and watch the new ones fail.** `go test ./internal/hub/link -run 'TestIssueCloudKit' && go test ./internal/hub -run 'TestPairOn'`. Expected: FAIL on the transports and the fallback.
- [ ] **Step 6: Implement.**
  - In `issue`, set `p.Transports = []string{wire.TransportCloudKit}` and append `wire.TransportRelay` only when `slices.Contains(c.host.Transports, wire.TransportRelay)`.
  - In `supervisor.pair`, after `h.pairCloudKit(shares)` (and after the `defer h.wg.Done()` scope), check for an answer class `ErrClassNoICloud` or `ErrClassICloudUnreachable`. When it is one of them and `h.rel != nil`, log `hub: no iCloud code (<class>): a Relay code instead`. Then return `s.withHub(func(rt *hubRuntime) ControlAnswer { if rt != h { return ControlAnswer{Error: ErrClassHubOff} }; return rt.handle(r, pl) })`, so the relay code is issued under `hubMu` as on a relay hub.
  - Never set `pl.ckNonce` for the relay code. `icloud_changed`, `hub_off` and `failed` keep their answers.
- [ ] **Step 7: Run the task scope and watch it pass.** `go test ./internal/hub/link ./internal/hub -run 'Issue|Pair'`, then `go test ./internal/hub/...`, `go test ./cmd -run 'Hub|Pair'` and `make lint-diff`. Expected: all PASS, no new lint.
- [ ] **Step 8: Commit.** `fix(hub): CloudKit codes list relay only with a relay; no iCloud → a relay code (#2191)`.

### Task 2: `Switcher.checkRelayLink` — the derived candidate moves a CloudKit hub to Relay

**Depends on:** none

**Files:**
- Create: `internal/hub/switcher/relaylink.go`
- Modify: `internal/hub/switcher/switcher.go` (the `MetaRelayLinkSince` const next to `MetaSwitchedAt`; the `relay_link_since` write in `New`; a `rlMu sync.Mutex` and the `rl relayLink` state in `Switcher`; the `s.checkRelayLink(ctx)` call in `PollOther` right after `s.checkNoPayer(ctx)`)
- Test: `internal/hub/switcher/sim_relaylink_test.go` (on the `world` rig of `sim_entitlement_test.go`: `eachFlavour`, `addPhone`, `route`, `moveTo`, `advance`, `pollAfterInterval`, `wantActive`)
- Test: `internal/hub/switcher/sim_entitlement_test.go` (only the new G2 test below; no existing test edited)

**Interfaces:**
- Consumes: `Config.AccountPhones` (fresh read, `ErrNotFresh` from `admission.go`'s reader), `s.accept`, `s.Pending`, `s.asksWaiting`, `s.activeKind`, `s.oldSide`, `s.SwitchedAt`, `state.Store.Devices`/`ICloudRoutes`/`Meta`/`SetMeta`.
- Produces:
  - `const MetaRelayLinkSince = "relay_link_since"`
  - `func (s *Switcher) RelayLinkSoon()`: marks the next `checkRelayLink` due (an `atomic.Bool`), then `s.Kick()`. Safe from any goroutine.
  - `func (s *Switcher) checkRelayLink(ctx context.Context)` (unexported, called by `PollOther`).

- [ ] **Step 1: Write the failing sim tests** (each in `eachFlavour` where the rig allows; the world starts on CloudKit). A *relay phone* is `addPhone` with a relay id, `route(ph, false)`, linked after `relay_link_since`; `w.paying` is what `AccountPhones` lists.
  - `TestRelayLinkedPayingPhoneMovesTheHubToRelay`: one relay phone, listed paying. After `RelayLinkSoon()`, then `PollOther` and `Step`, the active transport is relay, and `SwitchedAt()`'s `by` equals the phone's device id in `uuidString` form.
  - `TestRelayLinkBeforeTheUpdateIsNoCandidate`: `relay_link_since` is set by `New` and equals the first start's clock. A relay phone linked before it, listed paying, moves nothing and `AccountPhones` is never called. After the store is reopened and `New` runs again, `relay_link_since` is unchanged.
  - `TestRelayLinkWaitsOnAnUnknownRead`: the reader answers an error, `ErrNotFresh`, a hang (bounded by `oldSide()`; the bubble advances past it), and a list without the phone. Each moves nothing. Each next `RelayLinkSoon()` reads again, and a paying answer then moves the hub.
  - `TestRelayLinkNotPayingStays`: listed with `Paying: false` → stays CloudKit. A later read listing it paying (renewal) moves the hub.
  - `TestRelayLinkAfterALaterSwitchIsNoCandidate`: the hub went relay → CloudKit (`moveTo`) after the phone's `linked_at`. Listed paying → no read, no move.
  - `TestRelayLinkRespectsAntiFlap`: a switch rotated less than `AntiFlap` ago. The check reads paying, `accept` answers `too_soon`, nothing is sent to any phone (no `switch_result`/answer queued), and the hub stays on CloudKit. After `advance(RetryAfter)` and a `PollOther` (no kick), the hub moves.
  - `TestRelayLinkSkipsWhilePendingOrAsked`: (a) a pending switch record → no read; (b) an ask waiting (a phone's `transport_switch` control written, not yet decided) → no read. Once the Step decides it, the next check reads.
  - `TestRelayLinkSurvivesRestart`: (a) a crash after the confirm. Close the switcher, reopen the store, `New`, and the first `PollOther` (no kick needed, the throttle is fresh in memory) switches. (b) A crash after `accept` before `Step`: reopen, `Step` → exactly one rotation (count the keyring epochs before/after: +1), and a second `PollOther` reads nothing because the hub is on relay.
  - `TestTwoRelayLinksSwitchOnce`: two relay phones, both paying. One switch, one rotation, and `by` is the first phone in `devices` order (`linked_at, device_id`). The next check reads nothing.
  - `TestRelayLinkUnlinkedPhoneIsNoCandidate` (F11): a relay phone paying, unlinked (`w.center.Unlink`, as `TestUnlinkInsideASwitchTakesTheTargetsOnRelay` does) before the check → no read.
  - `TestRelayLinkReadsAtMostOncePerPollWithoutAKick`: listed not paying. Ten `PollOther` calls `OtherPoll` apart make one read. After `advance(NoPayerPoll)`, a second read.
  - `TestRelayLinkSwitchNoticesOtherPhones`: a free phone with an iCloud route (unordered and ordered variants), a slotted paying iCloud phone, and the relay phone. After the switch: the ordered free phone has `hub_on_relay` in its CloudKit mailbox; the slotted paying phone `Follow`s `transport_switched{relay}` and `ReadMarker` on the relay data zone shows relay; an unordered free phone gets `transport_switched{relay}`.
  - `TestNoPayerIgnoresARelayOnlyLinkAfterRelayLinkSwitch` (in `sim_entitlement_test.go`): after the relay-link switch, the account lists nobody paying. Two `pollAfterInterval` leave the hub on relay (G2's fingerprint is empty while the relay phone has no iCloud route).
- [ ] **Step 2: Run them and watch them fail.** `go test ./internal/hub/switcher -run 'RelayLink|TwoRelayLinks|NoPayerIgnoresARelayOnly'`. Expected: FAIL (`RelayLinkSoon` undefined).
- [ ] **Step 3: Implement in `relaylink.go`.**
  - `type relayLink struct { last time.Time; retryAt time.Time; loggedClass string }`.
  - `candidates() ([]state.Device, error)`: devices with a non-empty `RelayDeviceID`, no iCloud route (`ICloudRoutes`), and `LinkedAt` after both `SwitchedAt()` (when set) and `relay_link_since`. An unreadable `relay_link_since` means no candidate.
  - `checkRelayLink`:
    1. Return early when `AccountPhones`, `Relay` or `CloudKit` is nil, when `activeKind() != KindCloudKit`, when `Pending()`, or when `asksWaiting()`.
    2. Take `rlMu`. Read the candidates; none → return.
    3. Throttle: when not due (the `RelayLinkSoon` flag is unset, `now < retryAt`, or `now - last < NoPayerPoll`), return. Clear the flag and set `last = now`.
    4. Read `AccountPhones` under `context.WithTimeout(ctx, s.oldSide())`. On an error (`ErrNotFresh` included), log `hub: a phone linked over Relay: switch waits (<class>)` once per class change and return.
    5. Pick the first candidate (devices order) whose `RelayDeviceID` the read lists with `Paying` true. None → return. Otherwise `s.mu.Lock(); accepted, err := s.accept(canonical(id), transport.KindRelay, now); s.mu.Unlock()`.
    6. On `*actions.SwitchRejected` with `too_soon`: set `retryAt = now + RetryAfter`, log the waits line with `too_soon`, and send nothing. On `accepted`: log `hub: a phone linked over Relay pays: transport switch to relay accepted`, then `resetBackoff()` and `Kick()`.
  - `New`: when `hub_meta.relay_link_since` is unset, write `stamp(clock())`. Never overwrite it.
- [ ] **Step 4: Run and watch it pass.** `go test ./internal/hub/switcher`, `go test -race ./internal/hub/switcher` (once, at the end), `go test ./internal/hub/...`, `go test ./internal/hub/wire -run TestHubContractFixture` (proves no wire change), `make lint-diff`.
- [ ] **Step 5: Commit.** `feat(hub): a relay-linked paying phone moves a CloudKit hub to Relay (#2191)`.

### Task 3: The runtime asks for the check on a confirm and on a newly listed phone

**Depends on:** Task 1, Task 2

**Files:**
- Modify: `internal/hub/cloudkit_runtime.go` (`afterConfirm`)
- Modify: `internal/hub/admission.go` (`markAdmitted`)
- Test: `internal/hub/relay_link_switch_test.go` (new, on `newDeskRig`/`startPairDesk` and the relay fake the rig carries; `paying_test.go` shows how to send `PairingOpened` and drive a hello)

**Interfaces:**
- Consumes: `Switcher.RelayLinkSoon()` (Task 2); the Task 1 fallback.

- [ ] **Step 1: Write the failing end-to-end tests.**
  - `TestRelayPairingOnACloudKitDesktopSwitches`: CloudKit-active desk rig with a relay. Issue a code (`pairCode`). Send `PAIRING_OPENED` for a slot. Write the phone's hello into `pair/<slot>` with a relay device id and no iCloud user. Confirm over the control socket. The fake account then lists the phone paying and promoted (send `SLOT_ADDED`). The active transport becomes relay within the bubble without advancing `NoPayerPoll`, and `hub status`'s `switched_by` is the phone's device id.
  - `TestRelayPairingKicksOnTheConfirm`: the same up to the confirm, with the account already listing the phone paying before the confirm. The confirm alone (no `SLOT_ADDED`) leads to the switch.
  - `TestRelayPairingOnADesktopWithoutICloudSwitches` (Review Focus, F7): the account is `no_account` before `OpPair`. The fallback relay code is paired as above. The hub switches to relay, the status leaves `paused`/`no_icloud`, and the publisher publishes on relay (one data-zone record appears on the relay fake).
- [ ] **Step 2: Run and watch them fail.** `go test ./internal/hub -run 'RelayPairing'`. Expected: FAIL on the time limit (no kick).
- [ ] **Step 3: Implement.**
  - `afterConfirm`: after the `linked` check and before the share close, `if h.sw != nil { h.sw.RelayLinkSoon() }`. Move the `shares` guard below it, so a desktop host kicks even when the close is skipped.
  - `markAdmitted`: in the `n > 0` branch, `if h.sw != nil { h.sw.RelayLinkSoon() }`.
- [ ] **Step 4: Run and watch it pass.** `go test ./internal/hub -run 'RelayPairing|Pair|NoPayer|G2'`, `go test ./internal/hub/...`, `go test ./cmd -run 'Hub|Pair'`, `make lint-diff`.
- [ ] **Step 5: Commit.** `feat(hub): the confirm and a newly admitted phone run the relay-link check (#2191)`.

### Task 4: The `sas` line says the Link moves the Mac to Relay

**Depends on:** none

**Files:**
- Modify: `internal/hub/link/events.go` (`PairEvent` gains `OverRelay bool`, `MovesToRelay bool`)
- Modify: `internal/hub/link/hello.go` (the `EventSAS` emit sets `OverRelay` when the hello has a relay device id and no iCloud user)
- Modify: `internal/hub/runtime.go` (`forwardPairEvents` sets `MovesToRelay` before `broadcast`)
- Modify: `internal/hub/control.go` (`ControlAnswer` gains `MovesToRelay bool \`json:"moves_to_relay,omitempty"\``; `broadcast` copies it)
- Modify: `cmd/hub_link.go` (`hubPairSAS` gains `MovesToRelay bool \`json:"moves_to_relay"\``)
- Test: `internal/hub/link/center_test.go`, `internal/hub/pair_cloudkit_test.go`, `cmd/hub_test.go` (`TestHubPairStreamEvents`)

**Interfaces:**
- Produces: the Mac's contract for Task 6. The `sas` line of `hub pair --json --stream` is `{"event":"sas","device_id":…,"name":…,"code":…,"moves_to_relay":true|false}`. It is true exactly when the hello came through a Relay pairing slot (no iCloud user), the hub's active transport is CloudKit, and at least one *other* linked phone has an iCloud route (`ICloudRoutes`).
- `func (h *hubRuntime) movesToRelay(ev link.PairEvent) bool` in `runtime.go`. It answers false on any read error, and false on a host without a switcher.

- [ ] **Step 1: Write the failing tests.**
  - `TestASASOverAPairingSlotSaysOverRelay` (`center_test.go`): a slot hello gives `OverRelay` true, a CloudKit hello false.
  - `TestTheSASLineSaysWhenTheLinkMovesTheMacToRelay` (`pair_cloudkit_test.go`): CloudKit-active desk with one linked iCloud phone plus a slot hello → `moves_to_relay` true. With no other iCloud phone → false. On a relay-active desk → false. With a CloudKit hello → false.
  - Extend `TestHubPairStreamEvents` with the key on the `sas` line, both values.
- [ ] **Step 2: Run and watch them fail.** `go test ./internal/hub/link ./internal/hub -run 'SAS' && go test ./cmd -run 'HubPairStream'`.
- [ ] **Step 3: Implement** per the Interfaces block. The route read in `movesToRelay` happens on the forwarder goroutine, outside `pairMu`.
- [ ] **Step 4: Run and watch it pass.** `go test ./internal/hub/... ./cmd -run 'Hub|Pair'`, `go test ./internal/hub/wire -run TestHubContractFixture`, `make lint-diff`.
- [ ] **Step 5: Commit.** `feat(hub): the pairing sas line says a Link moves the Mac to Relay (#2191)`.

### Task 5: The phone's route rule — a paying phone links an iCloud Mac over Relay

**Depends on:** none

**Files:**
- Modify: `WatchtowerMobile/Sources/Features/Onboarding/LinkRoutePolicy.swift`
- Modify: `WatchtowerMobile/Sources/Features/Onboarding/LinkSeams.swift` (`RelayLinkOps.holdsRelayEntitlement() async -> Bool`; `OffRelayLinkOps` answers false)
- Modify: `WatchtowerMobile/Sources/App/Hubs/RelayAvailability.swift` (`HostedRelayLinkOps` gains `let entitlement: @Sendable () async -> Bool`, default `{ false }`)
- Modify: `WatchtowerMobile/Sources/App/Relay/StoreKitRelayStore.swift` (`static func holdsCurrentEntitlement(productID: String, now: Date) async -> Bool` and the pure `static func isCurrent(_ t: RelayTransaction?, now: Date) -> Bool`)
- Modify: `WatchtowerMobile/Sources/App/AppRoot.swift` (build `HostedRelayLinkOps(relay:entitlement:)` from `RelayConfig.from(bundle:).productID`; move `relayConfig` above the `LinkingViewModel` construction)
- Modify: `WatchtowerMobile/Sources/Features/Onboarding/LinkingViewModel.swift` (only the `decide` call in `open(_:)`: pass `entitled: { await relay.holdsRelayEntitlement() }`; fix its comment)
- Modify: `WatchtowerMobile/Tests/Support/RelayFakes.swift` (`RelayTestMac.code` gains `transports: [String]?? = .none`, an override; the fake relay ops gain a settable `entitled` answer and an asked count)
- Test: `WatchtowerMobile/Tests/LinkRoutePolicyTests.swift`, `WatchtowerMobile/Tests/RelayLinkingTests.swift`, `WatchtowerMobile/Tests/StoreKitRelayStoreTests.swift` (create it if no test of that type exists)
- Test: `WatchtowerKit/Tests/WatchtowerSyncTests/TransportFollowerPolicyTests.swift`

**Interfaces:**
- Produces:

```swift
static func decide(
    _ code: LinkPayload,
    relay: RelayAvailability,
    entitled: () async -> Bool = { false },
    paying: () async -> Result<Bool, HostedRelayPairing.Refusal>
) async -> LinkRoute
```

The default keeps every existing `LinkRoutePolicyTests` call compiling unedited.

- [ ] **Step 1: Write the failing route tests** in `LinkRoutePolicyTests`:
  - `testAPayingPhoneLinksACloudKitMacOverRelay`: `code(.cloudKit)` (transports `["cloudkit","relay"]`) and `code(nil)` (no transports, coherent identity) with `available` and paying `.success(true)` → `.relay(mac:authPub:)`, asked 1.
  - `testAnUnknownPayingAnswerWithAnEntitlementIsRelayUnreachable`: `code(.cloudKit)` with `available`, `.failure(.unreachable)` and `.failure(.attestationBackoff(until:))`, entitled true → `.refuse(.relayUnreachable)`.
  - `testAnUnknownPayingAnswerWithoutAnEntitlementLinksOverICloud`: the same with entitled false → `.cloudKit`.
  - `testAFreePhoneLinksACloudKitCodeOverICloud`: `.success(false)` and `.failure(.notPaying)` → `.cloudKit`.
  - `testRelayOffNeverAsksOnACloudKitCode`: `.off(.notConfigured)` and `.off(.unsupportedDevice)` → `.cloudKit`, asked 0, entitlement asked 0.
  - `testACloudKitCodeWithoutRelayNeverAsks`: `code(.cloudKit, transports: ["cloudkit"])` with `available` → `.cloudKit`, asked 0.
  - `testUpdateRequiredOnACloudKitCodeIsUpdateApp`: `.failure(.updateRequired)` → `.refuse(.updateApp)`.
  - Edit `testACloudKitCodeLinksOverICloud` only: its `available` rows pass `paying: .success(false)`, and the `.off` row is unchanged. The `v3` block is unchanged (a v3 code offers no relay). Name, loop and assertions stay.
- [ ] **Step 2: Write the failing wiring and store tests.**
  - `RelayLinkingTests.testACloudKitCodeOnAPayingPhoneOpensAPairingSlot`: `open(url)` of an iCloud code on a paying phone calls `relay.open(mac:)` and makes no CloudKit access calls (`access.availability`/`identity` not asked). The pending link's route is relay.
  - `RelayLinkingTests.testACloudKitCodeOnAPayingPhoneWithTheMacOffRelayOffersTryAgain` (F2): `open` answers `NOT_FOUND` → `.failed(.macNotOnRelay)` with a retry title.
  - `RelayLinkingTests.testAnEntitledPhoneWhoseCheckFailsIsRelayUnreachableOnACloudKitCode` (F1): `.failed(.relayUnreachable)`, and no CloudKit access calls.
  - `StoreKitRelayStoreTests.testOnlyAnUnrevokedUnexpiredTransactionIsCurrent`: `isCurrent` gives nil → false, revoked → false, `expiresAt <= now` → false, otherwise true.
- [ ] **Step 3: Write the Kit follower test.** `testSwitchedToTheRouteItIsOnAcksTheEpoch`: `state(route: .relay, epoch: 1)` and `switched(to: .relay, epoch: 2, on: .relay)` give the commands `[.mergeKeybox, .moveRoute(to: .relay, epoch: 2, by: "phone-a", at: base), .sendEpochAck(2), .markHandled(controlID: "c-1")]`, no `.resendUnechoedOnNewTransport`, `next.newestEpoch == 2`, and `next.leftTransport == nil`. It pins the existing behaviour. If it passes before any code change, keep it as the guard.
- [ ] **Step 4: Run and watch them fail.** `make mobile-test SIM="iPhone Air" MOBILE_FILTER='LinkRoutePolicyTests|RelayLinkingTests|StoreKitRelayStoreTests' MOBILE_XCB_EXTRA="-derivedDataPath $PWD/.derived-mobile"` (`MOBILE_FILTER` takes the Makefile's `-only-testing` form; use one class per run if the alternation is not accepted).
- [ ] **Step 5: Implement `decide`.**
  - `offersRelay = code.offersRelay && (code.transports.map { $0.contains("relay") } ?? true)`.
  - `onRelay` keeps today's expression.
  - When `!onRelay`: if `code.offersCloudKit && offersRelay && relay is .available`, ask `paying()`. `.success(true)` → `.relay`. `.success(false)` or `.failure(.notPaying)` → `.cloudKit`. `.failure(.updateRequired)` → `.refuse(.updateApp)`. Any other failure → `await entitled() ? .refuse(.relayUnreachable) : .cloudKit`.
  - Otherwise keep today's `!onRelay` answer. The `onRelay` branch is unchanged.
  - Update the type's doc comment with the spec §1 table order.
- [ ] **Step 6: Implement the entitlement read.**
  - `holdsCurrentEntitlement` reads `Transaction.currentEntitlement(for:)`: verified only, no `AppStore.sync`, mapped through `map(…)`, then `isCurrent`.
  - `AppRoot` passes `{ productID.map { await StoreKitRelayStore.holdsCurrentEntitlement(productID: $0, now: Date()) } ?? false }`.
- [ ] **Step 7: Run the task scope.**
  - The Step 4 command, plus `make mobile-test SIM="iPhone Air" MOBILE_FILTER=LinkingViewModelTests MOBILE_XCB_EXTRA="-derivedDataPath $PWD/.derived-mobile"` (the #2189/#2190 suites, guard).
  - `make kit-test FILTER=TransportFollowerPolicyTests`.
  - `cd WatchtowerMobile && swiftlint lint --strict` and `cd WatchtowerKit && swiftlint lint --strict` on the touched files.
  - Expected: all PASS. The existing `LinkRoutePolicyTests` cases are green with only the one sanctioned edit.
- [ ] **Step 8: Commit.** `feat(mobile): a paying phone links an iCloud Mac over Relay (#2191)`.

### Task 6: The Mac's Link confirmation warns before the move (Q6), and Link stays available without iCloud

**Depends on:** none (consumes Task 4's `moves_to_relay` key as fixed in its Interfaces block)

**Files:**
- Modify: `WatchtowerDesktop/Sources/ViewModels/MobilePairingModel.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Settings/MobileLinkSheet.swift` (`MobilePairingSheet`)
- Modify: `WatchtowerDesktop/Sources/ViewModels/MobileSettingsModel.swift` (`linkPhone` passes `macName`; `canLink` and `accountAllowsLinking`)
- Test: `WatchtowerDesktop/Tests/MobilePairingModelTests.swift`, `WatchtowerDesktop/Tests/MobileSettingsModelTests.swift`
- Test: `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+MobileSettings.swift` (new `Pairing` cases; `DesignShotCatalog.swift` already maps `Pairing.allCases`)

**Interfaces:**
- Produces:
  - `MobilePairingModel.init(streamer:macName:now:sleep:)`, with `macName: String = ""`.
  - `nonisolated static func relayMoveWarning(_ mac: String) -> String`, returning the Global Constraints line with `<Mac>` replaced by `mac`.
  - `private(set) var relayMoveWarning: String?`: set on a `sas` line with `moves_to_relay == true`, cleared by `start()` and by every non-`sas` step.
  - `func markConfirmed()`: the step change `confirm(true)` makes after it sends the line, callable by the shots.
  - `nonisolated static func accountAllowsLinking(transport:account:hasRelay: Bool = false) -> Bool`.

- [ ] **Step 1: Write the failing model tests.**
  - `MobilePairingModelTests.testTheRelayLinkWarningShowsOnlyWithICloudPhones`: a `sas` line with `"moves_to_relay":true` and `macName: "Work Mac"` gives `relayMoveWarning == "Linking this iPhone moves Work Mac to Relay. iPhones linked over iCloud without Relay lose their connection until they subscribe."`. `false`, or the key absent (an older CLI), gives nil. A `linked`/`refused` line or `start()` afterwards gives nil.
  - Extend `testCopy` with `relayMoveWarning("Work Mac")`, the exact string.
  - `MobileSettingsModelTests.testLinkStaysOnWithoutICloudOnlyWithARelay`: `accountAllowsLinking(transport: "cloudkit", account: "no_account", hasRelay: true)` is true. A status `{"state":"paused","reason":"no_icloud","transport":"cloudkit","relay":{…},…}` gives `canLink == true`. The same status without `relay` gives `canLink == false`. `testLinkNeedsAUsableAccountOnCloudKit` stays unedited.
- [ ] **Step 2: Run and watch them fail.** `make test-swift FILTER='MobilePairingModelTests|MobileSettingsModelTests'`.
- [ ] **Step 3: Implement the model.**
  - Decode `moves_to_relay` as `Bool?` in `Line`.
  - `linkPhone` passes `macName`.
  - `canLink = (status.state == "running" || (status.state == "paused" && status.reason == "no_icloud" && status.relay != nil)) && Self.accountAllowsLinking(transport:account:hasRelay: status.relay != nil)`.
- [ ] **Step 4: Add the mockups first** (before the view change, so the after-shots can be compared with them). New `Pairing` cases, each a `MobilePairingSheet` at its fixed 380 pt width:
  - `mobilePairingSAS-relayWarning`: the warning present, Mac "Work Mac", phone "Phone A".
  - `mobilePairingSAS-relayWarningLongName`: the warning with a long Mac name ("Design Studio Mac Pro (Basement)") and phone name. This is the narrow/wrap case: the sheet never widens, the text wraps, and the buttons stay on one row.
  - `mobilePairingConfirming`: the busy state after **Link** (`markConfirmed()`: progress and "Waiting for your phone…", no warning).
  - `mobilePairingFailed-afterRelayWarning`: the error with **Try again** after a warned `sas` (`streamEnded("The hub is not running.")`).
  - The existing `mobilePairingSAS` stays as the "line absent" state, and `mobilePairingStarting` as loading. No empty state applies to this sheet.
  - Render with `make desktop-shots DESKTOP_SHOTS=build/desktop-shots/2191-before` and keep that directory as the reference.
- [ ] **Step 5: Implement the view.** In `.sas`, under `Copy.checkCodeText`, when `model.relayMoveWarning` is set, show it as a caption-weight note in `Tone.warning` (design-kit text styles; no icon, banner or separator), wrapping inside the sheet. The buttons are unchanged.
- [ ] **Step 6: Compare the shots.** Run `make desktop-shots DESKTOP_SHOTS=build/desktop-shots/2191-after` and compare each new shot by eye with its Step 4 mockup and with `desktop-style-guide.md`: Tone colours only, kit buttons, no separators, no stock look. Fix any drift. The reviewer gets both directories.
- [ ] **Step 7: Run the task scope.** `make test-swift FILTER='MobilePairingModelTests|MobileSettingsModelTests|DesignShotsTests'`, then `cd WatchtowerDesktop && swiftlint lint --strict --baseline .swiftlint-baseline.json` on the touched files (`lint-diff` does not check Swift).
- [ ] **Step 8: Commit.** `feat(desktop): the Link confirmation warns before a Relay move; Link without iCloud on a relay Mac (#2191)`.

### Task 7: Docs and the user guide

**Depends on:** Task 1, Task 2, Task 3, Task 4, Task 5, Task 6

**Files:**
- Modify: `docs/features/relay-client.md` ("The link route rule (Phase 3 R4)": the spec §1 table; the paying check runs for every code that offers Relay; a CloudKit code offers it only when `transports` lists `relay`; the entitlement rule for an unanswered check)
- Modify: `docs/features/go-hub.md` (the #1127 paragraph: the `transports` rule for CloudKit codes and the relay-code fallback on `no_icloud`/`icloud_unreachable`. The "Transport switch" bullet: the third trigger, a confirmed Relay link, with the candidate rule, `relay_link_since`, `checkRelayLink`, `RelayLinkSoon` and the `sas` line's `moves_to_relay`)
- Modify: `docs/features/README.md` (the Relay client and Go hub summaries name `checkRelayLink` and the new route rule)
- Modify: `docs/features/mobile-companion.md` (its link flow: one sentence that a code whose hub is on iCloud also takes the relay route on a paying phone. Nothing else in the #2189 wait changes)
- Modify: `docs/guide/features/iphone-relay.md`:
  - One paragraph: a subscribed iPhone that links to a Mac on iCloud links over Relay and moves that Mac to Relay; phones without a subscription then lose the connection until they subscribe.
  - The "You choose iCloud or Relay for each Mac" sentence gains "linking a subscribed iPhone chooses Relay".
  - The page keeps its "Relay isn't in the current version…" opening line. It is at about 8.1 KB of the 8192-byte cap, so tighten existing sentences to make room; never split the page.
- `docs/guide/features/iphone.md`: no change (the steps are the same).

- [ ] **Step 1: Write the doc changes** per the file list, following `docs/guide/WRITING.md` for the guide page.
- [ ] **Step 2: Run** `go test ./docs/guide`. Expected: PASS, including `TestRelayGuideSaysNotYet` and the 8192-byte cap.
- [ ] **Step 3: Commit.** `docs: relay pairing on an iCloud Mac (#2191)`.

### Phase gate (controller, once, after Task 7 on the merged lanes)

Run each gate command to a log with its exit code:
- `make test`
- `go test -race ./internal/hub/switcher`
- `go test ./cmd -run 'Hub|Pair'`
- `make test-swift` (includes the Kit and the interface package)
- `make lint-all`
- `make mobile-test SIM="iPhone Air" MOBILE_XCB_EXTRA="-derivedDataPath $PWD/.derived-mobile"`
- `go test ./docs/guide`
- `scripts/leak-check.sh`
- every other `.github/workflows/*.yml` job by its own command

Then merge into `umbrella/2187-iphone-pairing` locally. A job that cannot run locally is named in the report.

---

## Spec promise → task → test

| Spec promise | Task | Test |
|---|---|---|
| A paying phone routes a CloudKit code that offers Relay to `.relay` | 5 | `LinkRoutePolicyTests.testAPayingPhoneLinksACloudKitMacOverRelay`; `RelayLinkingTests.testACloudKitCodeOnAPayingPhoneOpensAPairingSlot` |
| Unknown paying on a CloudKit code → `.relayUnreachable` with a device entitlement, `.cloudKit` without (Q2) | 5 | `…testAnUnknownPayingAnswerWithAnEntitlementIsRelayUnreachable`, `…testAnUnknownPayingAnswerWithoutAnEntitlementLinksOverICloud`, `StoreKitRelayStoreTests.testOnlyAnUnrevokedUnexpiredTransactionIsCurrent` |
| `.updateRequired` on any code that offers Relay → `.updateApp` | 5 | `…testUpdateRequiredOnACloudKitCodeIsUpdateApp`; existing `testUpdateRequiredIsUpdateApp` |
| A free phone, or relay `.off`, keeps `.cloudKit`; never asked when off | 5 | `…testAFreePhoneLinksACloudKitCodeOverICloud`, `…testRelayOffNeverAsksOnACloudKitCode` |
| A CloudKit code without `relay` in `transports` never asks the relay | 5 | `…testACloudKitCodeWithoutRelayNeverAsks` |
| The existing route rows are unchanged | 5 | the existing `LinkRoutePolicyTests`, unedited but for `testACloudKitCodeLinksOverICloud`'s precondition |
| `LinkingViewModel.open`'s relay path unchanged after #2189/#2190 | 5 | `LinkingViewModelTests*`, `RelayLinkingTests` (guard runs) |
| `IssueCloudKit` lists `relay` only with a relay origin | 1 | `TestIssueCloudKitTransportsFollowTheHost`; `TestPairOnACloudKitDesktopIssuesACloudKitCode` (extended) |
| iCloud failure on the Mac → relay code; no relay → the old refusal | 1 | `TestPairOnACloudKitDesktopWithoutICloudFallsBackToARelayCode`; `TestPairOnACloudKitDesktopWithoutICloudIsRefused` (no-relay case) |
| Links confirmed before the update never move the Mac (Q5) | 2 | `TestRelayLinkBeforeTheUpdateIsNoCandidate` |
| A relay-paired, confirmed, paying phone moves a CloudKit hub to Relay, `by` = that phone | 2, 3 | `TestRelayLinkedPayingPhoneMovesTheHubToRelay`; `TestRelayPairingOnACloudKitDesktopSwitches` |
| Unknown / `ErrNotFresh` / not-listed reads move nothing; listed not paying moves nothing | 2 | `TestRelayLinkWaitsOnAnUnknownRead`, `TestRelayLinkNotPayingStays` |
| A later `switched_at` drops the candidate | 2 | `TestRelayLinkAfterALaterSwitchIsNoCandidate` |
| Anti-flap: `too_soon` retries after the wait, nothing sent | 2 | `TestRelayLinkRespectsAntiFlap` |
| Pending switch / waiting asks → the check skips | 2 | `TestRelayLinkSkipsWhilePendingOrAsked` |
| Without a kick, at most one read per `NoPayerPoll` | 2 | `TestRelayLinkReadsAtMostOncePerPollWithoutAKick` |
| Crash after confirm / mid-switch: one switch, one rotation | 2 | `TestRelayLinkSurvivesRestart` |
| Two candidates → one switch | 2 | `TestTwoRelayLinksSwitchOnce` |
| Free iCloud phones get `hub_on_relay`; a slotted paying iCloud phone follows | 2 | `TestRelayLinkSwitchNoticesOtherPhones` |
| G2 stays quiet after the move | 2 | `TestNoPayerIgnoresARelayOnlyLinkAfterRelayLinkSwitch` |
| The runtime kicks on a confirm and on a newly listed phone | 3 | `TestRelayPairingOnACloudKitDesktopSwitches`, `TestRelayPairingKicksOnTheConfirm` |
| The follower takes `transport_switched{relay}` on a relay route as move + ack | 5 | Kit `TransportFollowerPolicyTests.testSwitchedToTheRouteItIsOnAcksTheEpoch` |
| The Link confirmation warns only when the phone paired over Relay, the Mac is on iCloud and another phone has an iCloud route (Q6) | 4, 6 | `TestTheSASLineSaysWhenTheLinkMovesTheMacToRelay`, `TestASASOverAPairingSlotSaysOverRelay`, `TestHubPairStreamEvents`; `MobilePairingModelTests.testTheRelayLinkWarningShowsOnlyWithICloudPhones`, `testCopy`; the DesignShotCatalog shots |
| iCloud is not needed for linking on the Mac either (decision, ask #1743) | 6 | `MobileSettingsModelTests.testLinkStaysOnWithoutICloudOnlyWithARelay` |
| No wire change | all | `TestHubContractFixture`, `TestHubContractFixture_RecordingSwitch` |
| No migration, no new field | 2 | no file under `internal/db/migrations/`; `relay_link_since` is a `hub_meta` row (`TestRelayLinkBeforeTheUpdateIsNoCandidate`) |
| Docs and guide updated; the guide passes | 7 | `go test ./docs/guide` |

## Failure path (spec §5) → test

| # | Failure | Test(s) |
|---|---|---|
| F1 | The relay is unreachable from the phone at scan time | `LinkRoutePolicyTests.testAnUnknownPayingAnswerWithAnEntitlementIsRelayUnreachable`; `RelayLinkingTests.testAnEntitledPhoneWhoseCheckFailsIsRelayUnreachableOnACloudKitCode` (Task 5). Without an entitlement it falls to iCloud per Q2: `…testAnUnknownPayingAnswerWithoutAnEntitlementLinksOverICloud` |
| F2 | The Mac's relay is not connected → `NOT_FOUND` → `.macNotOnRelay` + Try Again | `RelayLinkingTests.testACloudKitCodeOnAPayingPhoneWithTheMacOffRelayOffersTryAgain` (Task 5); existing `testAMacNotOnRelayAtOpenOffersTryAgain` |
| F3 | The hub stops while a phone pairs | existing `TestARestartCloseSweepsWithoutTheGrace` (`internal/hub/link`) and `RelayLinkingTests.testNoAnswerClosesTheSlot` (guards, run in Tasks 1 and 5). Nothing linked means no candidate: `TestRelayLinkUnlinkedPhoneIsNoCandidate` (Task 2) |
| F4 | A crash between the confirm and the switch | `TestRelayLinkSurvivesRestart` (Task 2) |
| F5 | The subscription lapses before the switch | `TestRelayLinkNotPayingStays` (Task 2) |
| F6 | The subscription lapses after the switch | `TestRelayLinkAfterALaterSwitchIsNoCandidate` (Task 2); rule 16 unchanged: existing `TestEntitlementExpiredFallsBackToCloudKit` (guard) |
| F7 | iCloud on the Mac is broken entirely | `TestPairOnACloudKitDesktopWithoutICloudFallsBackToARelayCode` (Task 1), `TestRelayPairingOnADesktopWithoutICloudSwitches` (Task 3), `MobileSettingsModelTests.testLinkStaysOnWithoutICloudOnlyWithARelay` (Task 6) |
| F8 | Two phones pair at once | existing `TestAUsedCodeIsRefused` (`internal/hub/link`, guard); `TestTwoRelayLinksSwitchOnce` (Task 2) |
| F9 | An account read fails, hangs or comes too early | `TestRelayLinkWaitsOnAnUnknownRead` (error, hang past `oldSide()`, `ErrNotFresh`, not listed; Task 2) |
| F10 | A switch to iCloud is pending or was just made | `TestRelayLinkSkipsWhilePendingOrAsked`, `TestRelayLinkAfterALaterSwitchIsNoCandidate`, `TestRelayLinkRespectsAntiFlap` (Task 2) |
| F11 | The phone is unlinked before the switch | `TestRelayLinkUnlinkedPhoneIsNoCandidate` (Task 2) |

## Guard suites (every task's brief lists the ones in its scope; the phase gate runs all)

- `go test ./internal/hub/...` (Tasks 1–4)
- `go test -race ./internal/hub/switcher` (Task 2, once at the end; the phase gate)
- `go test ./cmd -run 'Hub|Pair'` (Tasks 1, 3, 4)
- `go test ./internal/hub/wire -run TestHubContractFixture` (Tasks 2, 4): no wire change
- The switcher sim tests (`sim_switch_test.go`, `sim_entitlement_test.go`; Task 2), unedited except the one added G2 test
- `LinkRoutePolicyTests`, unedited except `testACloudKitCodeLinksOverICloud` (Task 5)
- `LinkingViewModelTests`, `LinkingViewModelTests+HelloFirst`, `RelayLinkingTests` (#2189/#2190 guards; Task 5)
- `make kit-test FILTER=TransportFollowerPolicyTests` (Task 5)
- `make lint-diff` (Go) and swiftlint on the touched Swift trees (Tasks 5, 6)
- `go test ./docs/guide` (Task 7)
