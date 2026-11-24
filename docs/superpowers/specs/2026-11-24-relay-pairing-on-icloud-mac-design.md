# A Relay phone links to an iCloud Mac, and the Mac moves to Relay — design

**Target:** #2191 · **Umbrella:** #2187 (`umbrella/2187-iphone-pairing`) · **Owner decision:** ask #1744, "Relay + Mac переходит на Relay"

## Problem

A phone with a Relay subscription scans the code of a Mac whose hub runs on iCloud (CloudKit). Since #1127/#1092 (`git show dcefe0a51`) that Mac issues a CloudKit code (`link.Center.IssueCloudKit`: v4, `transport: cloudkit`, `transports: ["cloudkit","relay"]`, relay identity kept; `docs/features/go-hub.md`, "The code `hub pair` issues follows the active transport (#1127)"). The phone's route rule then sends it to iCloud whatever it pays (`LinkRoutePolicy.decide`, `WatchtowerMobile/Sources/Features/Onboarding/LinkRoutePolicy.swift`; `docs/features/relay-client.md`, "The link route rule (Phase 3 R4)"). The owner paid for Relay, the Mac never learns of it, and linking fails outright when iCloud does not work (ask #1743: "У меня на телефоне релей, но товер не знает. iCloud может не работать… Не зря ж я релей купил.").

Before #1092 every code was a relay code. A paying phone linked through a pairing slot while the hub kept publishing only on CloudKit, so the phone saw the Mac offline. #1092 fixed that by sending the phone to iCloud. This design fixes it the other way round, as the owner chose: the phone links over Relay and the Mac follows it there.

## Goal

- A phone that pays for Relay links to an iCloud Mac over a Relay pairing slot. Linking needs no iCloud on the phone, and none on the Mac.
- After the owner presses **Link** on the Mac and the phone finishes its pairing, the hub switches its active transport to Relay once a fresh account read lists **this** phone as paying.
- Phones linked over iCloud that do not pay get `hub_on_relay` and lose the connection until they subscribe, as the current switch rules already do.
- No new field, no migration, no wire change. No new screen and no new user-visible text.

## What exists already

Most of the path is already in place. The design adds two decisions and one fallback.

- **The code already carries what relay pairing needs.** Every code `link.Center.issue` stores (`internal/hub/link/codes.go`) has `relay_device_id` and `relay_auth_pub` from `HostInfo` (`link.HeadlessHost`, `internal/hub/link/relay.go`). The phone opens the pairing slot itself (`open_pairing(mac:)`, `HostedRelayPairing`), so the code carries no slot. The Kit checks that the identity is coherent (`LinkPayload.offersRelay`, `WatchtowerKit/Sources/WatchtowerSync/Link/LinkPayload.swift`).
- **The Mac answers pairing slots while it runs on CloudKit.** A desktop host builds the relay transport next to CloudKit (`desktopTransports`, `internal/hub/desktop_runtime.go`). `connectRelay` registers it in the link upkeep. Its events reach `onControl`, and `PAIRING_OPENED` calls `hubRuntime.pairing`, which calls `link.Center.OnPairingOpened` on `relayT()` (`h.rel` on a desktop host, whichever transport is active; `internal/hub/runtime.go`). An unvouched hub may write its `pair/<slot>` zones (`internal/hub/admission.go`, "Vouched admission"). `HandleHello` checks the hello against `link_codes`, which a CloudKit code's nonce is in too (`internal/hub/link/hello.go`). `Confirm` links the phone with the hello's `relay_device_id` and an empty `user_record_name` (`internal/hub/link/keybox.go`, `state.LinkDevice`). Such a phone has no iCloud route (`state.Store.ICloudRoutes`).
- **The pairing phone vouches.** After the confirm, the phone stores its keys, then runs `vouch_hub` and `promote_pairing` (`relay-client.md`, "Pairing mode and `HostedRelayPairing`", `PromotedLinkResumer`). Before that, the hub is registered but unvouched, and it needs no payer to answer in a pairing slot. Once the phone has promoted, `get_account_state` lists the phone as holding this Mac in a slot, with its `paying` flag (`SLOT_ADDED` → `onSlotAdded`, the `linkSoonEvery` reads for `linkSoonFor` after a link change).
- **The switch machinery.** `Switcher.acceptTx` (`internal/hub/switcher/accept.go`) records an accepted switch: last request wins, `AntiFlap` (5 min) applies toward the relay, and a pending switch is handled. `Step`/`carryOut`/`announce` (`internal/hub/switcher/announce.go`) then rotate the keyring once, queue `transport_switched` for every phone and `hub_on_relay` for every ordered phone that does not pay (`freeOrderedPhones`), set `hub_meta.transport`, and owe the markers. The switch record and `switched_at`/`switched_by` are durable in `hub_meta`, so a restart finishes the same switch and never rotates twice.

## The design

### 1. The route rule on the phone (`LinkRoutePolicy.decide`)

A code **offers Relay** when its relay identity is coherent (`offersRelay`) and its `transports` lists `relay`. For a code whose `transports` is absent, the identity alone decides, as today. The new order:

| Code | Relay on this phone | Paying answer | Route |
|---|---|---|---|
| any code that offers Relay | `.available` | yes | `.relay(mac:authPub:)` (**new** for a CloudKit code) |
| any code that offers Relay | `.available` | no answer (unreachable, attestation backoff), and the phone holds a current Relay entitlement on the device (StoreKit) | `.refuse(.relayUnreachable)` (**new** for a CloudKit code; default pending Q2) |
| hub on iCloud | `.available` | no answer, and no current entitlement on the device | `.cloudKit`, as today (default pending Q2) |
| any code that offers Relay | `.available` | `.updateRequired` | `.refuse(.updateApp)` |
| hub on iCloud (v3, v4 `transport` absent or `cloudkit`) | `.off`, or `.available` and not paying | n/a | `.cloudKit`, as today |
| hub on Relay | `.off`, or not paying | n/a | `.macOnRelay` / `.needsRelay`, as today |
| a code that offers neither route | n/a | n/a | `.refuse(.refused)`, as today |

A CloudKit code whose `transports` does not list `relay` (a Mac with no relay origin) never asks the relay and links over iCloud. The paying check now runs for every code that offers Relay while the relay is `.available`, not only for a hub on Relay. A free phone pays one extra account read per scan.

The App Store build keeps the relay `.off(.notConfigured)` (`RelayAvailability.evaluate`). That build therefore never reaches the new rows, and its free phones keep linking over iCloud even when the relay is down. Only builds with an origin (TestFlight, dev) get `.relayUnreachable` for an unanswered paying check, and only on a phone whose device holds a current Relay entitlement: a phone that never subscribed links over iCloud as today. This keeps everything that works today working until the owner answers Q2.

`LinkingViewModel.open` takes the `.relay` route into `connectRelay(RelayCode(…))`; this spec changes nothing in it. #2189 (the hello sent at once, its resend on resume) and #2190 (refusals shown on the phone) rewrite parts of `LinkingViewModel` in the same umbrella, so the plan for this spec is written after both are merged into it and re-checks every reference to that file against the merged code. That path does not read `payload.transport`. After the promote, the link is a relay route (`LinkRecord.transport = .relay`) and the phone waits for data like any new relay link.

**Hub side of the code.** `IssueCloudKit` hard-codes `transports: ["cloudkit","relay"]` (`internal/hub/link/codes.go`, `issue`). It is changed to carry `cloudkit` plus the host's own `relay` entry: `HostInfo.Transports`, which `desktopTransportList` fills only when `o.RelayOrigin` is set (`internal/hub/desktop.go`). Without this change, a paying phone would scan the code of a Mac that has no relay, get `NOT_FOUND` at `open_pairing`, and reach the dead end `.macNotOnRelay`.

### 2. The Mac moves to Relay (hub side)

**Who decides:** the hub, in the switcher. No phone request and no new wire message are involved. The person's act is the owner's **Link** on the Mac for a phone that paired over Relay. The switch is recorded `by` that phone's device id, so rule 8 ("only a person switches") holds and the phones' notices name the phone that linked.

**The candidate is derived, never stored.** On a desktop host whose active transport is CloudKit, a *relay-linked candidate* is a linked phone that meets all of these:

- it has a `relay_device_id`;
- it has no iCloud route (`ICloudRoutes` false: it linked through a pairing slot);
- its `linked_at` is later than both the last switch's `switched_at` (if any) and `hub_meta.relay_link_since`. That key is written once, with the time the first build carrying this change starts the hub (a `hub_meta` row, no migration), so a phone linked over a pairing slot before the update never moves the Mac by itself (default pending Q5).

The last condition makes a later decision win. If the Mac moved to iCloud after this phone linked (a lapse under rule 16, a person's switch to iCloud), the phone is no candidate any more, and the hub does not move back by itself.

**When:** a new `Switcher.checkRelayLink(ctx)` (new file `internal/hub/switcher/relaylink.go`), called from `PollOther` next to G2 (`checkNoPayer`). It runs only while:

- the active transport is CloudKit;
- no switch is pending (`Pending()`);
- no ask waits (`asksWaiting()`, the same guard G2 uses, so requests read before it are decided first);
- a candidate exists.

The check makes one fresh account read: `Config.AccountPhones`, the runtime's `acct.Fresh`. If the read lists a candidate's `relay_device_id` with `paying = true`, the check calls `accept(by = candidate's device id, target = relay, now)` under `s.mu`, the same call G2 makes. The Step then carries the switch out unchanged.

The runtime kicks the switcher (`h.sw.Kick()`) at two moments, so the check runs within seconds instead of at the next poll:

- after a `Confirm` that linked such a phone (`hubRuntime.afterConfirm`, `internal/hub/cloudkit_runtime.go`);
- when an account read newly lists a linked phone (`followAccount`/`onSlotAdded`, `internal/hub/admission.go`).

Without a kick, the check retries at most once per `NoPayerPoll` (5 min), the cadence G2 already pays on the relay.

**Why not at `PAIRING_OPENED`.** The Mac does learn of a paying phone at scan time: the relay opens a pairing slot only for a paying phone (`open_pairing` refuses `notPaying`), and `PAIRING_OPENED` reaches `hubRuntime.pairing` before the **Link** (ask #1744). The hub still does not act there, for two reasons. The owner may refuse the link. And the account state lists the phone only after `promote_pairing`, so a fresh read "for this phone" can only be made then. The design therefore triggers the switch at the first fresh read after the confirm that lists the phone.

**Outcomes of the read:**

| Read | Effect |
|---|---|
| lists the candidate as paying | `accept` → switch to Relay (`by` = phone) |
| lists the candidate as not paying | nothing. The relay refuses the phone itself (`ENTITLEMENT_INACTIVE`), and the phone runs its own lapse path (`TransportFollowerPolicy.relayLapsed`, `markRefused(.lapse)`, the existing term banner). The candidate stays, so a renewal later moves the Mac. |
| does not list the candidate (not promoted yet, `needsOwner`) | nothing; tried again on the next kick or poll |
| failed, timed out, or `ErrNotFresh` | nothing; tried again. Unlike `Switcher.follows`, an unknown answer never counts as paying here: the owner asked for a fresh "this account pays" read. |

**Anti-flap.** If `acceptTx` answers `too_soon` (a switch rotated less than `AntiFlap` ago), nobody waits for a refusal, so nothing is sent. The check logs once and kicks again after `RetryAfter`.

**A switch already pending.** The check skips while `Pending()`. A pending move to Relay makes the check pointless. A pending move to iCloud finishes first; its `switched_at` is later than the candidate's `linked_at`, so that decision wins.

**Vouching.** A CloudKit hub does not need to be vouched before a paying phone exists. It answers in the pairing zone unvouched, and the pairing phone vouches (`vouch_hub`, then `promote_pairing`) after the confirm. The gate opens on the same account state that the check reads. So once the switch commits, the relay data zone, `set_hub_readers` and the mailboxes are open.

**What the new phone sees meanwhile.** Between the promote and the switch, the hub still publishes only on CloudKit. The relay phone shows its first-load state (`InitialLoadReporting.dataLoadComplete` false). Then the switch's `transport_switched{relay}` and the relay marker arrive. The phone's follower reads `transport_switched{relay}` in a newer epoch on its current route as `moveRoute` plus `sendEpochAck`, with no resend (`TransportFollowerPolicy.follow`). The normal gap is a few seconds: promote, `SLOT_ADDED` or a `linkSoon` read, a Step, a bounded old-side drain (`OldSideTimeout`, 10 s), the rotation, and the full diff on the relay. If the switch does not come (not paying, the Mac cannot read the relay), the phone gets no new screen. It shows what a relay link to an unreachable Mac shows today (see Q3).

### 3. The Mac's other phones

- **Free phones linked over iCloud** get `hub_on_relay` in their CloudKit mailbox (`announce`, `freeOrderedPhones`). They lose the connection until they subscribe, as with any switch to Relay. A phone with an old build that has no ordered actions gets `transport_switched{relay}`, and its follower, unable to use Relay, takes it as `withoutHub`.
- **A paying iCloud phone that holds this Mac in a slot** (it upgraded before) is listed as paying and follows `transport_switched{relay}` as today.
- **A paying iCloud phone that never added this Mac to a slot** is treated as free (the relay lists only phones that hold this Mac) and gets `hub_on_relay`. Scanning a new code then links it over Relay under the new route rule. This is the same treatment it gets today when another phone switches the Mac.
- **G2 cannot move the Mac back.** `checkNoPayer` runs only on the relay, and its `fingerprint` is empty while any linked phone has no iCloud route, which the new phone does not have. It also waits for two answered reads `NoPayerPoll` apart, with nobody linked in between. After the switch, only rule 16 (the relay phone's lapse) moves the Mac to iCloud.

### 4. A Mac whose iCloud does not work

Today `hub pair` on a CloudKit-active Mac whose iCloud fails answers `no_icloud` or `icloud_unreachable` and shows no code (`supervisor.pair`, `pairCloudKit`, `internal/hub/control.go`). New rule: when `IssueCloudKit` refuses with one of those two classes and the host has a relay (`h.rel != nil`), `supervisor.pair` falls back to `Issue()`, the relay code, and logs `hub: no iCloud code (<class>): a Relay code instead`. A paying phone pairs over Relay and the Mac moves by §2. The switch drains the CloudKit side within the old-side timeout and owes its notices and marker there. It never waits on iCloud.

A free phone scanning that code gets the existing `.needsRelay` ("<Mac> works over Relay only") because the code offers no iCloud route (see Q1). `icloud_changed`, `hub_off` and `failed` keep their answers.

### 5. Failure paths

Every path names its outcome and its test (see the test plan).

| # | Failure | Outcome |
|---|---|---|
| F1 | The relay is unreachable from the phone at scan time | The paying check gives no answer → `.relayUnreachable` ("Couldn't reach Relay — Check your connection and scan again"). Never iCloud. |
| F2 | The Mac's relay is not connected or registered | `open_pairing` answers `NOT_FOUND` → `.macNotOnRelay` with **Try Again**, as today. |
| F3 | The hub stops (Mobile off, daemon stop) while a phone pairs | The slot state is in memory (`link.Center.pairs`) and the waiting request in `pending_devices`. The next start's close (`CloseOnStart`, `CloseRestart`) refuses the requests waiting under the earlier run's codes (`not_confirmed`, in the keybox only). The phone cannot read that answer, because the new run does not know the slot, so it times out with `.noAnswer` ("Your tower didn't answer"). Nothing is linked, so there is no candidate. |
| F4 | A crash between the confirm and the switch | The candidate is derived from `devices` and `switched_at`, so the next run's `PollOther` finds it and switches. A crash after `accept` resumes the durable switch record. The `heading == target` guard in `acceptTx` and `active == CloudKit` in the check prevent a second switch. |
| F5 | The subscription lapses right after the link, before the switch | The read lists the phone as not paying → no switch. The relay refuses the phone, and the phone's lapse path starts the term. If it renews, the next read moves the Mac. |
| F6 | The subscription lapses after the switch | Rule 16 as today: with no other payer the Mac moves to iCloud (`entitlement_expired`). `switched_at` is now later than `linked_at`, so the check never moves it back. The relay-only phone shows S59 (`markMoved`). |
| F7 | iCloud on the Mac is broken entirely | The relay-code fallback (§4). The switch completes without CloudKit. Free phones hear `hub_on_relay` only once iCloud works again; until then they are offline anyway. |
| F8 | Two phones pair at once | One code links one phone: `Confirm` refuses the other waiting requests `used_code`. Two codes in turn give two candidates. The first paying read moves the Mac, and the second check sees the active transport is Relay and stops. |
| F9 | An account read fails, hangs or comes too early | Bounded by `oldSide()`; `ErrNotFresh` counts nothing; tried again on the next kick or poll. The Mac stays on iCloud meanwhile. |
| F10 | A switch to iCloud is pending or was just made | The check skips while one is pending. A later `switched_at` drops the candidate, and that decision wins. Anti-flap answers `too_soon` and the check retries after the wait. |
| F11 | The phone is unlinked before the switch | Its row is gone, so it is no candidate. |

**Writers of `hub_meta.transport`:** `adopt` (`internal/hub/adopt/adopt.go`, sets `cloudkit` once at adoption), `switcher.New` (the first decision when it is unset, `switcher.go`), and `announce` step 4 (`announce.go`). This design adds none.

**Writers of the switch record (`hub_meta.transport_switch`):** `acceptTx` for every caller, all under `s.mu` in one transaction (a phone's `Request` toward iCloud, the Step's `acceptAsk`, rule 16's lapse, G2, and now `checkRelayLink`), plus `rotate`, `announce`, `settleNoSwitch` and `queueNextTx` while the switch is carried out.

**Who wins a race:** the last accepted request before the rotation (the replaced requester is answered when it ends), or the `Next` request after it. Ordering between the new check and the other writers:

- The check never runs while an ask waits, so asks are decided first, as for G2.
- A lapse decided in the same Step comes before the next `PollOther`.
- A person's request toward iCloud while the Mac is already on iCloud is not accepted and writes no `switched_at`. The candidate can still move the Mac to Relay afterwards. This is an accepted limit: a phone has no "Switch to iCloud" to press on a Mac that runs on iCloud.

### 6. User-visible text and screens

**One new line on the Mac (proposed, Q6); no other new text or screen change.** Pressing **Link** for a phone that paired over Relay can cut off this Mac's phones that run over iCloud without Relay (a family member's phone, for example), so the Mac says so before the press. In the Link confirmation (Settings → Mobile, the pairing sheet's "Link “<phone>”?" step), when the phone paired over Relay, the Mac runs on iCloud and at least one other linked phone has an iCloud route, the sheet adds:

> Linking this iPhone moves <Mac> to Relay. iPhones linked over iCloud without Relay lose their connection until they subscribe.

The text lives in `MobilePairingModel` with its test. The sheet gets DesignShotCatalog mockups for its states: the line absent (no other iCloud phone), the line present, the confirm busy, and an error with Retry; the plan adds them and the screen is compared with them after implementation. The Mac cannot tell which iCloud phones pay (it reads only the relay account's phones), so the line names the group, not a count.

Every other outcome reuses existing copy pinned by its model's tests:

- `LinkFailure`: `.relayUnreachable`, `.macNotOnRelay`, `.noAnswer`, `.needsRelay`, `.updateApp`;
- the follower's banners: the lapse term, S59;
- the Mac's existing `switched` watch event and its Settings → Mobile rows (**iCloud**, **Relay**, **Waiting for Relay**).

Q1 and Q3 may add more copy. Each such text goes into its model with a test and DesignShotCatalog mockups for each state, in this same target, once the owner answers.

New log lines (daemon log, not UI):

- `hub: a phone linked over Relay pays: transport switch to relay accepted`
- `hub: a phone linked over Relay: switch waits (<class>)`
- `hub: no iCloud code (<class>): a Relay code instead`

### 7. Docs to update (same PR)

- `docs/features/relay-client.md`, "The link route rule (Phase 3 R4)": the new table. The paying check runs for every code that offers Relay, and a CloudKit code offers it only when `transports` lists `relay`.
- `docs/features/go-hub.md`: the #1127 paragraph gains the relay-code fallback on an iCloud failure and the `transports` rule for CloudKit codes. The "Transport switch" bullet gains the third person-equivalent trigger (a confirmed Relay link) with the candidate rule.
- `docs/features/README.md`: the Relay client and Go hub summaries name `checkRelayLink` and the new route rule.
- `docs/guide/features/iphone-relay.md`: one paragraph. A subscribed iPhone that links to a Mac on iCloud links over Relay and moves that Mac to Relay; phones without a subscription then lose the connection until they subscribe. The "You choose iCloud or Relay for each Mac" line gains "linking a subscribed iPhone chooses Relay". `docs/guide/features/iphone.md`'s link steps get no change, since the steps are the same. Run `go test ./docs/guide` (the 8 KB cap and `TestRelayGuideSaysNotYet`: the new passage keeps the "Relay isn't in the current version…" opening rule).

### 8. Test plan

| Promise | Test |
|---|---|
| A paying phone routes a CloudKit code that offers Relay to `.relay` | `LinkRoutePolicyTests.testAPayingPhoneLinksACloudKitMacOverRelay` (`make mobile-test MOBILE_FILTER=LinkRoutePolicyTests`) |
| Unknown paying on a CloudKit code → `.relayUnreachable` with a device entitlement, `.cloudKit` without | `…testAnUnknownPayingAnswerWithAnEntitlementIsRelayUnreachable`, `…testAnUnknownPayingAnswerWithoutAnEntitlementLinksOverICloud` |
| Links confirmed before the update never move the Mac | `internal/hub/switcher` `TestRelayLinkBeforeTheUpdateIsNoCandidate` (`relay_link_since` written once, kept across restarts) |
| The Link confirmation warns only when another phone has an iCloud route | `MobilePairingModelTests.testTheRelayLinkWarningShowsOnlyWithICloudPhones` + DesignShotCatalog shots |
| A free phone, or relay `.off`, keeps `.cloudKit` and is never asked when off | `…testAFreePhoneLinksACloudKitCodeOverICloud`, `…testRelayOffNeverAsksOnACloudKitCode` |
| A CloudKit code without `relay` in `transports` never asks the relay | `…testACloudKitCodeWithoutRelayNeverAsks` |
| The existing rows are unchanged | the current `LinkRoutePolicyTests` stay green unedited, except `testACloudKitCodeLinksOverICloud`, which gains the free/off precondition and keeps its name |
| `IssueCloudKit` lists `relay` only with a relay origin | `internal/hub/link` `TestIssueCloudKitTransportsFollowTheHost`; `internal/hub` `TestPairOnACloudKitDesktopIssuesACloudKitCode` extended |
| iCloud failure on the Mac → relay code; no relay → the old refusal | `internal/hub` `TestPairOnACloudKitDesktopWithoutICloudFallsBackToARelayCode`; `TestPairOnACloudKitDesktopWithoutICloudIsRefused` keeps its case for a host with no relay |
| A relay-paired, confirmed, paying phone moves a CloudKit hub to Relay, `by` = that phone | `internal/hub/switcher` `TestRelayLinkedPayingPhoneMovesTheHubToRelay` (sim over `hubtest`) |
| Unknown, `ErrNotFresh` or not-listed reads move nothing; listed not paying moves nothing | `TestRelayLinkWaitsOnAnUnknownRead`, `TestRelayLinkNotPayingStays` |
| `switched_at` later than `linked_at` → no candidate (no move back after a lapse or a person's iCloud switch) | `TestRelayLinkAfterALaterSwitchIsNoCandidate` |
| Anti-flap: `too_soon` retries after the wait, no answer sent | `TestRelayLinkRespectsAntiFlap` |
| Pending switch / waiting asks → the check skips | `TestRelayLinkSkipsWhilePendingOrAsked` |
| Crash after confirm, and crash mid-switch: one switch, one rotation | `TestRelayLinkSurvivesRestart` (the store reopened, the rotation count asserted) |
| Two candidates → one switch | `TestTwoRelayLinksSwitchOnce` |
| Free iCloud phones get `hub_on_relay`; a slotted paying iCloud phone follows | `TestRelayLinkSwitchNoticesOtherPhones` (sim, `hubtest.Phone.Follow` / `ReadMarker`) |
| G2 stays quiet after the move | `TestNoPayerIgnoresARelayOnlyLinkAfterRelayLinkSwitch` |
| The runtime kicks on a confirm and on a newly listed phone | `internal/hub` `TestRelayPairingOnACloudKitDesktopSwitches` (end to end over `relaytest` and the CloudKit fake: `PAIRING_OPENED`, hello, Confirm, vouch, promote, then the active transport is Relay) |
| The follower takes `transport_switched{relay}` on a relay route as move + ack | Kit `TransportFollowerPolicyTests.testSwitchedToTheRouteItIsOnAcksTheEpoch` (`make kit-test FILTER=TransportFollowerPolicyTests`) |
| The guide still passes | `go test ./docs/guide` |

**Guard suites the implementer brief lists:**

- `go test ./internal/hub/...`;
- `go test -race ./internal/hub/switcher`;
- `go test ./cmd -run 'Hub|Pair'`;
- `TestHubContractFixture`, which proves no wire change;
- `make kit-test`, `make mobile-test`, `make lint-swift`, `make lint-diff`.

## Decisions

- The spec is approved as written, with no answers to Q1–Q6, so every open question takes the default written here: Q1 keeps the relay-code fallback with the existing text; Q2 and Q5 take the defaults under "Defaults pending the owner"; Q3 keeps the existing state; Q4 keeps the path through Connection → **Relay**; Q6 keeps the warning line on the Mac (ask #1756).
- Relay pairing on an iCloud Mac: the phone links over Relay, and the Mac moves to Relay after the owner's **Link**, on a fresh read that lists this phone as paying. Free iCloud phones get `hub_on_relay` (ask #1744).
- iCloud must not be needed for linking: the phone takes the relay route, and a Mac whose iCloud fails issues a relay code (ask #1743, "iCloud может не работать").
- The Mac learns of the paying phone at scan time (`PAIRING_OPENED`) but switches only after the confirm and promote (ask #1744, "мы никак про релей не узнаем пока телефон не свяжем"; the timing is the agent's reading of the "fresh read for this phone" requirement).
- Fix everything found in this area, one item after another (ask #1743, "все чиним"). This covers the defect found while designing: `IssueCloudKit` lists `relay` in `transports` only when the host has a relay origin.
- The hub decides the switch through `Switcher.accept` with `by` = the linked phone, and the candidate is derived from `devices` and `switched_at`. No new field, no new wire message (decided by the agent, #2191, to keep it simple).

## Out of scope

- A paying phone already linked to this Mac over iCloud: a re-scan still says "already linked". It moves the Mac through the existing **Relay** choice under Connection (`RelayUpgrader`). See Q4.
- A crash of the Mac after `Confirm` but before the phone reads its keybox from the pairing slot (the slot list is in memory): an existing limit of relay pairing, unchanged.
- A proof on the hello's `relay_device_id` (ask #980), unchanged.
- Any change to rule 16, G2, the departure check or anti-flap.

## Defaults pending the owner

These defaults keep today's behaviour wherever the owner has not decided; each changes only with the answer to its question.

- Q2: an unanswered paying check refuses with `.relayUnreachable` only on a phone holding a current Relay entitlement; any other phone links over iCloud.
- Q5: only links confirmed after the update can move the Mac (`hub_meta.relay_link_since`).
- Q6: the Mac's Link confirmation carries the warning line (proposed; dropped if the owner says no).

## Open questions for the owner

1. **Free phone vs. a Mac whose iCloud is broken.** With the relay-code fallback (§4), a free phone sees "<Mac> works over Relay only / Relay isn't available on this iPhone", which is not quite true for a Mac whose iCloud is only down. Keep the existing text, add a Mac-side line under the code ("iCloud isn't working: only an iPhone with Relay can link now"; a new text and mockups), or drop the fallback and keep `no_icloud`/`icloud_unreachable`?
2. **Unknown paying for a free phone.** In TestFlight and dev builds (relay configured), a free phone that scans an iCloud Mac's code while the relay is down now gets "Couldn't reach Relay" instead of linking over iCloud. Is that acceptable, or should a phone that has never paid (no current StoreKit entitlement) skip the relay check and link over iCloud?
3. **When the Mac does not move.** If the Mac cannot read the relay account (or the phone was not paying), the new relay phone shows an empty, never-live Mac with no explanation. Is the existing state enough for v1, or do you want a phone notice such as "<Mac> hasn't moved to Relay yet" (new text and mockups)?
4. **Already-linked paying phones.** Should re-scanning a code on a paying phone that is already linked over iCloud re-link it over Relay and move the Mac, or should it keep pointing at Connection → **Relay**, as now?
5. **Links made before this change.** A paying phone that linked over a pairing slot to a CloudKit Mac before #1092, and never saw a switch, is a candidate under the derived rule: after the update the Mac moves to Relay without a new **Link**. Is that wanted (it is the same situation), or should only links confirmed after the update count?
6. **A warning on the Mac before Link.** Should the Link confirmation say "Linking this iPhone moves <Mac> to Relay. iPhones linked over iCloud without Relay lose their connection until they subscribe." when other phones run over iCloud (§6)? Recommended: yes.
