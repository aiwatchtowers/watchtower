# Relay client Phase 5 — 7-day key rotation with ephemeral X25519 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On relay links, the hub starts a new epoch every 7 days, each phone's pairwise keys for that epoch come from fresh X25519 keys on both sides, the keybox is sealed to the phone's ephemeral key instead of `dev_kx`, and old keys are erased. CloudKit links keep the 90-day static scheme byte for byte.

**Architecture:**

- **The phone offers, the hub consumes.** The phone holds at most two ephemeral keys per hub: `current` and one `offered`. It sends the offer's public key inside `epoch_ack`. At the next rotation the hub draws a fresh key for each phone that offered, derives that phone's two relay keys, stores them sealed, and erases its private key in the same transaction.
- **The keybox names what it used.** It is sealed to the newest offer the hub holds and says which hub and device public keys built each epoch's relay keys. The phone derives, stores the two keys, promotes the offer, and erases the older private key.
- **A static fallback per phone, per epoch.** No relay-key row for `(epoch, device)` means today's static derivation. This one rule covers CloudKit links, a phone's first week on the relay, an old build and an old hub.

**Tech Stack:** Go 1.26 (`internal/hub/{secure,identity,state,actions,link,switcher,alerts,wire,hubtest}`), Swift 5.10 language mode, CryptoKit (`WatchtowerKit/WatchtowerSync`), SwiftUI app wiring (`WatchtowerMobile`), goose sidecar migrations.

**Spec:** `docs/superpowers/specs/2026-10-29-relay-client-design.md` §1 ("At launch, relay links keep today's key scheme"), §9 (switch and epochs), §13 row 5. Relay design in the relay repository at `bcca870`: `docs/superpowers/specs/2026-10-28-relay-design.md` §7 items 1–5, §4.2 item 6, §9 item 7; `sim/README.md` rules 13 and 14. Protocol: `docs/superpowers/specs/2026-10-31-hub-phone-protocol-design.md` §4.2, §4.3, §5.4, §7.6, §7.7. Go hub: `docs/superpowers/specs/2026-10-31-go-hub-design.md` §3 lists this as out of scope, and the relay client spec keeps Phase 5 to the phone and the Kit. **The phase does not work without a hub half and no Go hub session runs (ask #1015), so this plan includes it. That is a proposal, Open decision 5, not an existing ruling.** E2E research: `docs/superpowers/specs/2026-10-12-mobile-e2e-encryption-research.md` §2.2–§2.3.

## Read this first: what the recon found

1. **The relay at `bcca870` lacks nothing.** Records stay opaque, the keybox overwrites its record in the data zone, and `epoch_ack` is an ordinary sealed mailbox record. No relay session work is needed (ask #734 is not triggered).
2. **The phase cannot usefully be split into "cadence first, keys later".** With a 7-day cadence and static keys, a stolen `dev_kx` plus recorded keyboxes still opens every epoch, and static pairwise keys still open every recorded mailbox record. Only the two together deliver what §7.4 promises. A genuinely smaller alternative exists: a symmetric key chain with no ephemeral keys. It is in Open decision 6, recommended against.
3. **Shorter epochs turn four rare paths into weekly ones.** None of these is a problem at 90 days. Each has a task:
   - **Recording uploads can be lost.** A recording is sealed once and every send repeats those bytes (protocol §7.7), and `RetireIfDone` can end an epoch at once. An upload sealed in that epoch is then dropped unanswered, forever. Task 9.
   - **A locked phone's alerts go blank.** A relay `alert_push` is sealed in the current epoch, but the extension's key copy updates only after an unlock. Task 5.
   - **The phone's mailbox feed can jam.** Today the phone derives a relay key for any epoch. With stored keys, a missing key throws `keysUnavailable`, and the feed replays that batch forever. Task 8.
   - **Every rotation re-uploads the whole window, transcript assets included.** That is at most 200 transcripts of at most 20 MiB each, weekly. Open decision 8, measured as "Measuring the cost" says.
4. **A free phone linked to a relay hub would defeat the whole scheme.** Today every linked phone's keybox goes into the relay data zone, sealed to its static `dev_kx`. A free phone never reads it, yet recording it and later stealing that phone's `dev_kx` opens `K_data` of every relay epoch. Task 4 takes the keys out (Open decision 9).
5. **The hub never erases retired epoch keys.** `hub_epochs.sealed_keys` stays forever; "retired" only filters reads. §7.4 says old epochs are erased. Task 3 does it (Open decision 4).
6. **The relay's own retention is weaker than the design this threat model came from.** Relay design §7 assumes 1-day backups; the Cloudflare design §9 has Durable Object point-in-time recovery for 30 days. For 30 days, whoever controls that account may be able to restore overwritten ciphertext from the objects it covers. This raises the value of the phase, and it is the honest reason to do it.
7. **Timing conflict.** The spec says "after launch"; the brief's PR base is `feature/relay-client-next`, which is the launch branch. Merged there and switched on, Phase 5 ships with launch. This plan makes the two separable: the code can land dark, and a build setting turns on the phone's offers. Open decision 1 has both options and their cost.
8. **A phone can stop being a reader while the hub stays on the relay** (its subscription moved or ended, another phone still pays). Without a design, the hub keeps deriving keys for it, its keybox has no keys, and records sealed in those epochs jam its feed, even `hub_on_relay`. Task 13 and "Losing and regaining reader status" design this in both directions.
9. **The phase changes who can talk to whom after two weeks.** A lapsed phone that subscribes again has an old newest epoch, and the hub drops a control sealed in a retired epoch (`ErrEpochNotAccepted`, only actions get `resend_from`). At 90 days that was rare. Task 13 merges the keybox at the reader wait, before the request.

## The threat, honestly

**What it addresses.** An attacker who has recorded ciphertext from the relay (the operator, a breach of the Cloudflare account, or the 30-day recovery above) and who later extracts one phone's keys. Today that yields up to 90 days of `K_data` and `K_alert`, plus every recorded action and echo of that link for its whole life. After this phase it yields the epochs the phone still holds. If the thief stays passive, the next rotation with a fresh offer heals the link, because the new keys depend on a private key the thief never saw.

**How much that is. There is no fixed bound, and no user-facing text may state one (Open decision 15).** With the Mac running and the phone in touch, a stolen phone opens the current epoch and the previous one, normally about two weeks of recorded data (7 + 7, ask #843). Three cases go past that:

- **Mac closed or hub paused.** No new epoch begins (F1, Open decision 12), so one epoch's keys stay current on the phone for as long as that lasts. Little is sealed in that time: nothing from the hub, only the phone's own actions.
- **Phone offline.** It erases nothing until it reads a newer keybox, because retention starts at the merge. Stolen after six months away, it still opens what it held when it left.
- **Phone offline while the hub rotates.** Every epoch of the absence is sealed to its one last offer, so that phone's theft opens **all of those epochs**, however many weeks they span. The same holds, for one extra week, after a lost ack (F8).

**What it does not fix:**

- A thief with a live, unlocked phone reads the replica directly. Keys are not the barrier there.
- An **active** thief holding current keys can send their own `next_kx` and stay in the link until the owner removes the phone. Only a re-link or Remove ends that.
- **Mac compromise.** The hub holds plaintext. Hub key erasure is hygiene, not a barrier, and `hub_kx`, `hub_sig` and the wrap key stay.
- **`K_meta` does not rotate** (protocol §4.2), so record names stay linkable over time. Sizes, timing, ids and APNs tokens stay visible to the relay (relay design §7).
- **It is not a ratchet.** Inside an epoch one key seals everything, and a phone that stays away reuses its last offer across rotations.
- **The first week on the relay is static** (Open decision 14): after a link, a switch or a renewed subscription, the first keybox must go to `dev_kx`.
- **A static phone on the same hub is the weakest link** for `K_data` while it reads the zone (Open decision 10).
- iCloud links get none of this, by decision.

## Global Constraints

- `relayRotationAge` = 7 days on a relay hub **with at least one phone holding an offer**; `RotationAge` = 90 days and `RotationSeqCap` = 2^28 stay. A relay hub with no offering phone stays at 90 days, so PR A and any old-build-only hub change nothing. Relay design §7.4 says "a hub has one scheme": it does, at any moment; this only delays the 7-day scheme until a phone can use it.
- The `relaystaging` build tag is the only way to shorten the age (Task 3); no release path may set it.
- Retention stays 7 days on both sides (`PreviousEpochGrace`, `previousEpochGrace`, ask #843) and at most 8 epochs on the phone (`maxEpochs`).
- CloudKit links: same bytes, same recipient (`dev_kx`), same `wt/relay/v1/` derivation, no offer ever sent. Guard: `TestKeyring_RotatesAt90DaysOrSeqCap` stays unchanged.
- Existing frozen vectors do not change. New vectors are additive (`kdf.json`, `go-sealed.json`, `hub_contract_cases.json`).
- Sim rule 13's byte-for-byte switch resend, and the `action_seq` that never resets, stay.
- Ephemeral private keys live only in the `hub.<id>` Keychain item (`whenUnlocked`, `ThisDeviceOnly`). They and the derived relay keys never reach the `afterFirstUnlock` alert material or any log.
- **No new phone screen, no new user text, no Desktop change** (see "Phone screens").
- Go hub ↔ Kit bytes change together: `wire.KeyboxKeys`/`KeyboxKeys`, `wire.Control`/`ControlPayload`, `secure.EphemeralRelayKey`/`KeyDerivation.ephemeralRelayKey`.
- Agent-run rules (the relay launch `common.md`): TDD with RED and GREEN logs, inner loop only, foreground only, no repo-built CLI on live data, no live data in the repo, guard files untouched, a stop-and-report on any contract, wire or behaviour change beyond the rulings below.

### What a Release build gets while Relay stays dark

With an empty `WATCHTOWER_RELAY_ORIGIN` no phone is on a relay route, so no offer is sent and no ephemeral path runs. Under Open decision 4's recommended option, one thing reaches CloudKit users: the sidecar migration, which is inert schema. With option B, two more reach them: erasure of retired epoch keys and the upload reseal.

## Review Focus

1. **A phone away for three or more rotations returns with an old outbox and an old echo.** It must recover with no owner action and no permanent feed jam. Tests: Task 8 `testARelayRecordInAGoneEpochIsDroppedNotReplayed`, Task 11 step 4.
2. **Rotation hits a recording that is sealed but not yet sent.** The audio must arrive once. Test: Task 9 `testARowSealedInAnOlderEpochIsResealedBeforeSending`.
3. **Two rotation triggers overlap: an age rotation falls inside a transport switch.** The `transport_switched` epoch and the keybox must match. Test: Task 3 `TestRotateIfDueSkipsWhileASwitchIsRunning`.
4. **A phone on iOS is locked across the rotation and an alert arrives.** The owner still reads the alert's text. Test: Task 5 `TestAlertPushSealedInAnEpochThePhoneHolds`.
5. **A switch to iCloud with a free phone linked.** The free phone must still get its keybox, though it got no keys on the relay. Test: Task 4 `TestSwitchToCloudKitGivesAFreePhoneItsKeys`.

## Re-check before Tasks 2–4 (blocks them)

The table below is pinned to `92636f852`. Three things may land and change it, and asks #1055 and #1056 are unanswered. Before Task 2 starts, and again before Tasks 3 and 4, the implementer runs this and reports any change to the controller; a change to a rule below goes back to the owner before the task continues.

- **G1** (device records on the relay; the design changes the creator check): does `epoch_ack`'s handling, `decide`'s device gate or `relayMaterial` read a new author check? `git log origin/feature/relay-client-next -- internal/hub/actions/device_record.go internal/hub/actions/control.go`.
- **G2** (a move with the old phone gone; it may add an automatic move to iCloud): does it add a trigger to `Switcher.lapse`? If so, Task 13's `ReaderLost` drops its own trigger and uses G2's. `git log origin/feature/relay-client-next -- internal/hub/switcher/entitlement.go`.
- **#1497** (the route-change sweep on the phone waits for a full load, `relay-lc/1497`): a rotation is not a route change, so the sweep must not run on it. Task 8 pins this once #1497 is in the branch (`testARotationDoesNotSweepTheReplica`).

## What the merged code gives Phase 5 (checked 2026-11-05 at `92636f852`)

| Fact | Where | What Phase 5 does with it |
|---|---|---|
| All rotation goes through `RotateWith`, one transaction: retire, insert, wipe hashes, move alerts. | `identity/keyring.go` | Task 3 adds the relay keys to that transaction. |
| `RotateIfDue` runs in `housekeeping`, `PublishSoon(AllKinds)` follows, and wiped hashes make the republish durable. | `hub/runtime.go` | Task 3 changes the age check and adds the skip. |
| One seam picks the keybox recipient: `Keyring.KeyboxRecipient`, used by the slice and by `transport_switched`. | `identity/keyring.go`, `secure/record.go` | Task 3 returns the offer there. |
| `Keyboxes()` builds one `KeyboxKeys` for all phones. | `link/grants.go` | Task 4 makes it per phone. |
| `epoch_ack` is sealed, durable, never lowered; `devices.acked_epoch` exists. | `actions/control.go`, `state/devices.go`, `ReplicaStore+Outbox.swift` | Tasks 2 and 8 carry the offer on it. |
| `Sealer.InEpoch` and `sealEpochFor` seal in an epoch the phone holds. | `secure/record.go`, `switcher/accept.go` | Tasks 3 and 5 use the same rule for echoes and alert pushes. |
| A fresh `K_asset` per asset, carried in the sealed frame. | protocol §4.4 | Reseal keeps the sealed file (Task 9). |
| `PhoneKeyProvider.relayKey` derives statically for any epoch and caches for the provider's life. | `Secure/PhoneKeyProvider.swift` | Task 7. |
| `saveHubLink` keeps `retained(now:)`; the alert material copies epochs with data keys emptied. | `Secure/KeychainKeyStore.swift` | Task 7 keeps relay keys out of that copy. |
| `mergeKeys` runs on the main actor; the merge's `adding` lives in the app. | `LinkingViewModel.swift`, `ScannedHubKeys.swift` | Tasks 7 and 10 move the merge into the Kit. |
| `reseal(ownEnvelope:)` exists; `nil` lists the action Not delivered. | `SecureTransport.swift`, `ActionOutbox+Ordered.swift` | Reused by Tasks 8 and 9. |
| Rotation and republish send no second alert. | `alerts` (Go hub note), `MoveWorkAlertsForRotation` | Pinned at 7 days in Task 5. |
| `hub unlink` runs in the daemon over its control socket, or in the CLI under `hub.lock` when no hub runs. | `cmd/hub_link.go`, `state/lock.go` | See "Writers and races". |
| `interopOpts.clock` moves the Go hub's clock on the stand. | `internal/hub/interop_kit_test.go` | Task 11. |

## The scheme

**Derivation** (new, additive, `wt/relay/v2/`):

```
ikm  = X25519(hub_eph, dev_eph) ‖ X25519(hub_kx, dev_kx)
salt = link_nonce
info = "wt/relay/v2/" ‖ p2h|h2p ‖ 0x00 ‖ hub_id(16) ‖ device_id(16) ‖ epoch u32 BE ‖ hub_eph_pub(32) ‖ dev_eph_pub(32)
K_relay[dir, e] = HKDF-SHA256(ikm, salt, info, 32)
```

An all-zero shared secret is refused on either side.

**One cycle:**

1. **Phone (route relay).** After merging any epoch, or at boot, it generates `offered` if it has none, saves it, then queues `epoch_ack{epoch, next_kx}`.
2. **Hub.** It stores the offer as `devices.kx_offer` and `kx_offer_epoch`, newest ack epoch winning, and only while on the relay.
3. **Hub, at rotation (transaction).** For each linked phone with an offer: draw `hub_eph`, derive both directions, seal them under the wrap key as `epoch_relay_keys(epoch, device_id, hub_pub, device_pub, sealed_keys)`, and let `hub_eph` go out of scope, its bytes cleared.
4. **Hub, keybox.** HPKE to the offer (`KeyboxRecipient`) with `relay_kx: {hub_pub, device_pub}` and, for the previous epoch, `previous_relay_kx`.
5. **Phone.** It tries `offered`, `current`, then `dev_kx` to open the keybox. It finds the private key named by `device_pub`, derives, stores the pair on `EpochKeys`, promotes `offered` to `current` when `device_pub` is the offer, and erases the older key. Back to step 1.

**A lost ack costs one week and needs no new record.** At the next raise, the keybox names the same `device_pub`, the offer is still outstanding, and the next `epoch_ack` carries it again.

**A phone that upgrades mid-epoch** has already acked that epoch. `epochAckDue` therefore also says yes for the same epoch with an offer not yet sent.

**The phone's rule for a relay key:**

| Epoch entry on the phone | Link has ephemeral state | Key |
|---|---|---|
| Present, with a stored pair | — | the stored pair |
| Present, no pair | — | static (`wt/relay/v1/`) |
| Absent | no (iCloud, old hub, before the first offer) | static, any epoch, as today |
| Absent, epoch above the newest held | yes | `epochKeysPending`: on the active route the batch replays, **for at most `keyboxWaitCap` = 1 h from the first sighting** (`relay_wait_since` in replica meta, cleared by any merge), then it is unopenable. In the side reader, or with `canUseRelay == .no`, it is unopenable at once |
| Absent, epoch at or below the newest held | yes | `epochKeysGone`: the record is dropped, the feed moves on |

**One exception to every row above:** when no row's key opens an h2p record, the phone tries the static key, and accepts the result **only if the frame is a `hub_on_relay` control**. Anything else opened that way is unopenable. So a thief holding only an old `dev_kx` can at worst push the phone off the relay, visibly, and cannot forge echoes. See "Losing and regaining reader status".

**Hub-side sealing:** for a phone with `kx_offer` set, echoes and controls are sealed in its acked epoch while the hub still retains it, else in the current one. A phone with no offer gets today's sealing and static keys.

## Losing and regaining reader status

**A relay-eligible phone** is linked, not lapsed, and held in a slot by the last account read that answered. An offer exists only for such a phone: that invariant is what lets `RotateToward` derive for every row with an offer and nothing else.

**The signals the hub really has** (checked in `internal/hub/switcher/entitlement.go`, `transport/relay/pairing.go`, `runtime.go`):

| Signal | Durable? | Covers |
|---|---|---|
| The relay's `ENTITLEMENT_EXPIRED` naming the phone (`OnControl`) | runs `lapse`, which sets `devices.relay_lapsed_at` | Subscription ended |
| The phone's own `transport_switch(cloudkit, entitlement_expired)` (`Request`) | same | A move or end the phone heard of |
| A mailbox write refused `ENTITLEMENT_INACTIVE` (`EntitlementInactive`) | same, at the next Step | The relay refuses that phone |
| `get_account_state`: a linked phone in no slot (`SetReadersFrom`) | in memory only | A move with the old phone gone (G2): the relay sends **no** control for it. Today nothing acts on this for a desktop hub |
| `Paying` read lists the phone again (`recheckLapsed`, every `PollOther`) | clears `relay_lapsed_at` (`endLapse`) | Paying again |

**Going out, on the hub.** `lapse` runs `state.ClearDeviceKX` first, in every branch, in its own transaction: the offer and all of that phone's relay-key rows go. From that commit every key for this phone in every epoch is static, in both directions. `SetKXOffer` refuses while `relay_lapsed_at` is set. For the slot signal, new `Switcher.ReaderLost(device)` runs `lapse` when a phone **with an offer or relay-key rows** is absent from two answered account reads at least `linkEvery` apart, the same rule whether or not G2 lands (see the re-check). `KeysInZone` turns false, so its next keybox has no keys, and `PublishSoon(KindDeviceGrant)` publishes it.

**What a relay action already written does.** Sealed under the deleted rows, it no longer opens; `Lapsed` already says no relay action written before a lapse is applied, and the phone lists it Not delivered on `hub_on_relay`. Nothing that would have been applied is lost.

**Going out, on the phone.** On `relayLapsed` it first queues its `transport_switch` (sealed with what it holds, as today), then on `.hubOnRelay` or `withoutHub` runs `droppingEphemeral()`: `currentKX`, `offeredKX` and every stored pair are erased, and the link is static for every epoch (row 3). A lapse while the phone still sits on the relay route runs it on `relayLapsed` too, so nothing waits on a mailbox it may not read. **`hub_on_relay` is sealed static** because the rows are gone, and the exception above lets the phone read it before it has dropped its state; the side reader never replays, so owed echoes ahead of it in the iCloud mailbox cannot hold it back. It then leaves: route to iCloud, unechoed actions Not delivered, relay mailbox drained, control marked handled, exactly `withoutHub` today.

**A plain follow to iCloud** (the whole hub moved) uses `clearingEphemeral()` instead: it erases the two private keys and keeps stored pairs, because rule 13's resends and a `resend_from` reseal still need them and the hub keeps those rows until retention ends.

**Coming back.** A renewed phone goes through the upgrade path, and at `awaitReader`'s first successful read of `data/<mac>` it **merges the keybox it finds** before `request`. That keybox has keys once the hub names it a reader and `recheckLapsed` has ended the lapse, sealed to `dev_kx` because the hub holds no offer. The phone's newest epoch is then current, so its `transport_switch{relay}` is accepted however long it was away; without this it is sealed in a retired epoch and dropped unanswered. A read with no keys yet counts as not read, under the existing 24 h `readerWaitLimit` (`.readerNotConfirmed`). After following, its `epoch_ack` carries a new offer; it is stored once it is eligible, and the first ephemeral epoch comes at the next rotation. An offer read too early is refused and sent again at the next raise (one more static week).

## Mixed fleets

| Case | What happens | Test |
|---|---|---|
| Hub on the relay, one paying phone, one free phone | The cadence is 7 days. The paying phone goes ephemeral. The free phone is not a reader: its relay data-zone keybox carries the grant and **no keys**. It reads nothing there anyway and gets `hub_on_relay`. It keeps its static link. | `TestFreePhoneKeyboxOnRelayHasNoKeys` |
| That hub switches to iCloud | New epoch, all offers cleared in the rotation's transaction, every keybox to `dev_kx` with keys. `transport_switched` uses `KeyboxesAll`, so the free phone gets its keys. Cadence back to 90 days. | `TestSwitchToCloudKitGivesAFreePhoneItsKeys` |
| Hub on the relay, an old phone build on the relay route | It never offers, so every epoch is static for it and its keybox goes to `dev_kx` **with keys**. It works. It is the weakest link for `K_data` (Open decision 10). The hub logs a count per rotation. | `TestOldBuildPhoneStaysStaticAcrossRotations` |
| A new phone, an old hub | The hub ignores `next_kx` (plain `encoding/json`; no `DisallowUnknownFields` under `wire` or `actions`). No `relay_kx` arrives, so the phone stays static. One unused offer sits in the Keychain. | Kit `testAHubThatNeverConsumesStaysStatic`, Go `TestEpochAckOfferUnknownToOlderHubDecodes` (decode pin) |
| An old phone build on iCloud | Nothing changes: 90 days, static. | Existing tests plus the unchanged vectors |
| Switch to iCloud mid-rotation (offer in flight) | The offer read after the switch's transaction is dropped because the transport is no longer relay. The phone clears its ephemeral state when it follows. A keybox naming no `relay_kx` means static. | `TestOfferReadAfterSwitchAwayIsDropped`, `testFollowingToICloudClearsEphemeralState` |
| Switch to the relay | New epoch, no offers yet, so it is static. The first offer comes with the ack after the follow. First ephemeral epoch at the next rotation, at most 7 days later (Open decision 14). | Task 11 step 2 |
| Relay, iCloud and back within a week | Each switch starts an epoch; old relay rows stay until retention ends; the phone's `maxEpochs` of 8 holds them. A `dev_kx` keybox omits `previous*` when that epoch has a relay-key row for this phone. | `TestStaticKeyboxOmitsAnEphemeralPreviousEpoch` |
| A paying phone lapses, another phone still pays, hub stays on the relay | "Losing and regaining reader status": offer and rows gone in `lapse`, keybox without keys, `hub_on_relay` readable static, phone back on iCloud with static keys. The other phone keeps rotating. | `TestLapseWithAnotherPayerClearsOfferAndRows`, `testHubOnRelayOpensOverAStaleEphemeralState` |
| The same phone's subscription moved and the phone is gone (G2) | `ReaderLost` after two answered reads runs the same `lapse`. The hub's keys for the old phone stop | `TestReaderLostAfterTwoReadsRunsLapse`, `TestOneMissingReadChangesNothing` |
| The last offering phone lapses | Hub back to the 90-day age at the next check; if nobody pays, `lapse` moves it to iCloud as today | `TestLastOfferGoneBackTo90Days` |
| A lapsed phone on iCloud, the hub still on the relay, pays again | "Coming back": keybox merged at the reader wait, request accepted, follow, new offer | `testAwaitReaderMergesTheKeyboxBeforeTheRequest`, `TestRenewedPhoneOffersAgain`, Task 11 step 7 |
| A re-link (the phone reinstalled, the Keychain survives) | The hub clears the phone's offer and relay-key rows with the new nonce; the phone's fresh link has no ephemeral state. | `TestRelinkClearsOfferAndRelayKeys` |

**Why a free phone's switch notice still carries keys:** `transport_switched` toward the relay goes to every linked phone with the first relay epoch's keybox. That hands one static week's `K_data` to the free phone's iCloud mailbox. It is a v1 limit, listed in Open decision 9.

## Failures

The last column is the task whose test pins the row.

| # | Failure | Behaviour | Test | Task |
|---|---|---|---|---|
| F1 | Host closed past the due date | Rotates once at the first cycle, no catch-up | `TestKeyring_RotatesOnceAfterALongClose` | 3 |
| F2 | Failure midway through a rotation (a seal fails for the second phone) | Nothing written; next housekeeping retries | `TestRotationFailureMidwayWritesNothing` | 3 |
| F3 | Restart after commit, before the republish | Hashes stay wiped, publish resumes, no second rotation | `TestRuntime_RestartAfterRotationRepublishesOnce` | 6 |
| F4 | Relay unreachable at rotation | Rotation is local; keybox and slices wait. The phone stays on the old epoch; echoes stay in its acked epoch | `TestRotationWhileRelayDownPublishesOnReturn` | 6 |
| F5 | Hub paused or unvouched on the relay | No rotation: nothing can be published | `TestRotateIfDueSkippedWhileHeldOnRelay` | 3 |
| F6 | Phone offline for one rotation | The keybox, sealed to its offer, is read on return; the offer is promoted | Task 11 step 3 | 11 |
| F7 | Phone offline past retention (three or more rotations) | The keybox still opens: the hub reuses the last offer with a fresh `hub_eph`. Old actions get `resend_from` and are resealed; one past its own key is Not delivered, and an action that old is answered expired anyway | Task 11 step 4, `testAnOutboxRowPastItsKeyIsNotDelivered` | 11, 8 |
| F8 | `epoch_ack` lost (TTL purge, failed write) | Hub keeps the old offer and seals to it; the phone still holds it. Next raise re-sends the offer. Early retirement simply does not happen; the 7-day cap still does | `testALostAckResendsTheOfferAtTheNextRaise`, `TestLostAckStillRetiresAt7Days` | 8, 3 |
| F9 | Old ack copy replayed after a newer one | `kx_offer_epoch` keeps the newest | `TestOlderAckDoesNotReplaceANewerOffer` | 2 |
| F10 | Malformed or low-order `next_kx` | Offer ignored and logged by class, ack still counted | `TestBadOfferIsIgnoredAckStillCounted` | 2 |
| F11 | Phone locked at rotation | Keybox waits for unlock (`hub.<id>` is `whenUnlocked`). Alert pushes stay sealed in the acked epoch while retained | `TestAlertPushSealedInAnEpochThePhoneHolds` | 5 |
| F12 | Phone killed after saving the offer, before queueing the ack | Boot's `acknowledgeNewestEpoch` finds the unsent offer | `testAnOfferNotYetAckedGoesAtBoot` | 10 |
| F13 | Phone killed between merge and promote | One Keychain item, one write: both or neither | `testMergeIsOneKeychainWrite` | 7 |
| F14 | Keychain write fails during a merge | Epoch unmerged; the next pass retries from the stored keybox | `testAFailedSaveKeepsTheOldLinkAndRetries` | 10 |
| F15 | Echo arrives before the keybox | Feed replays with its token untouched until the merge, and `keysMerged` re-reads | `testAnEchoAboveTheNewestEpochWaitsForTheKeybox` | 8 |
| F16 | Echo in an epoch the phone will never hold | Dropped as unopenable; the action matched by wire name is queued again; the hub re-echoes it as a repeat | `testARelayRecordInAGoneEpochIsDroppedNotReplayed` | 8 |
| F17 | Keybox names a key the phone no longer has (only a restored hub sidecar reaches this) | Merge refused, link kept, logged once, nothing wiped. Stale data until re-link (Open decision 13) | `testAKeyboxNamingAnUnknownKeyIsNotMerged` | 7 |
| F18 | Age rotation inside a running switch | Skipped; the next cycle decides | `TestRotateIfDueSkipsWhileASwitchIsRunning` | 3 |
| F19 | Unlink during a rotation cycle | Serialised by the transaction; the removed phone's rows go with it; no keybox keys for it | `TestUnlinkRemovesOfferAndRelayKeys` | 3 |
| F20 | Recording sealed in an epoch the hub retired | Resealed before each send; a raise re-arms a stuck row; if its key is gone it is sealed afresh from the plain file | Task 9's tests | 9 |
| F21 | Data-zone quota refuses the keybox | Existing quota error on the Mac. Echoes stay readable while the acked epoch is retained; after that the feed waits and the phone's actions wait | `TestEchoSealedInAckedEpochWhileKeyboxIsStuck` | 3 |
| F22 | Hub closed for over 7 days right after a partial republish | Phone drops the old key on schedule; rows not yet republished stay unreadable until the hub returns and finishes (Open decision 13) | `testRowsInAnErasedEpochStayPendingUntilRepublished` | 7 |
| F23 | Phone linked while a rotation commits | Static until its first offer | `TestLinkDuringRotationStartsStatic` | 3 |
| F24 | Rotation and a lapse in the same moment | Serialised. Rotate first: the row it wrote is deleted by the lapse. Lapse first: no offer, no row | `TestLapseAndRotationEitherOrder` | 13 |
| F25 | Restart between the lapse's commit and `hub_on_relay` written | `owe` is durable as today; the offer and rows stayed cleared | `TestLapseRestartKeepsKXCleared` | 13 |
| F26 | Phone reads its feed on the relay route after the hub cleared its rows, and `epoch` is above its newest | Replays for at most 1 h, then unopenable. The relay's refusal or the side reader gets it out sooner | `testAPendingEpochStopsReplayingAfterTheCap` | 13 |
| F27 | A false absence from one account read | Nothing happens; two reads `linkEvery` apart are needed | `TestOneMissingReadChangesNothing` | 13 |
| F28 | A forged static record that is not `hub_on_relay` | Unopenable | `testAStaticEchoIsRefusedOnAnEphemeralLink` | 13 |
| F29 | A renewed phone's offer arrives before its lapse ended | Refused, sent again at the next raise | `TestOfferRefusedWhileLapsed` | 2 |
| F30 | A `permission_answer` or `session_interrupt` sealed before a rotation (PROJ-21) | Applied exactly once through `resend_from`/reseal under its own age window, or Not delivered; never applied twice and never silently lost. PROJ-21's guards are unchanged | `TestPermissionAnswerAcrossARotationAppliedOnce` | 6 |

## Writers and races

| Data | Writers | Who wins |
|---|---|---|
| `hub_epochs`, `epoch_relay_keys` | The daemon's housekeeping (age), its switcher (switch), its link center (unlink), or the CLI under `hub.lock` when no hub runs | One holder of `hub.lock`; `BEGIN IMMEDIATE` serialises the daemon's goroutines. The later transaction builds on the committed newest epoch |
| `devices.kx_offer`, `kx_offer_epoch` | Processor (`epoch_ack`), switcher (clear on leaving the relay, clear in `lapse`), link center (relink, unlink) | Highest ack epoch; a clear beats any offer read afterwards, because the ack's transaction reads `hub_meta.transport` and `relay_lapsed_at` |
| `HubLinkKeys` (`hub.<id>`) | Link flow's merge, the upgrade's merge at the reader wait, the session's offer, the follower's clear or drop, re-link, unlink | New `PhoneKeyStore.updateHubLink` under the store's lock, so no read-modify-write is lost. **It returns nil and writes nothing when the link is gone**, so an unlink is never undone |
| `epoch_ack_*` replica meta, `outbound_controls` | `ActionOutbox`'s chain | Serial; an unsent ack is replaced by a newer one |
| Alert material (`alert.<id>`) | `saveHubLink` only | The extension only reads it |
| Second phone | Its own `devices` row, relay-key rows and Keychain | Independent. Early retirement needs every phone's ack, with the 7-day cap |
| Second Mac on the phone | Its own `hub.<id>` item and replica | Independent |
| Desktop (second screen) | None; it reads through CLI JSON | — |

## Phone screens

**None new, none changed; no `DesignShotCatalog` or `mobile-shots` frame.** Rotation is automatic (relay design §7.5). Every outcome reuses a state that already has text and a test:

- **Not delivered:** `ActionOutbox.refusedMessage`.
- **An uploader row:** its existing states.
- **A locked phone's content-free notification:** `AlertOpener`'s fallback.
- **An unreadable keybox:** `readGrant`'s `.unreadable`, logged, never judged.

The reader transition has no new text either: `hub_on_relay` shows what it shows today (Phase 4's S51 banner, Not delivered rows).

If the owner rules that F17 needs words (Open decision 13), that is a new frame and a new task.

## Lanes

```
Task 1 ─┬─ Task 2 ─ Task 3 ─┬─ Task 4 ─┐
        │                   ├─ Task 5 ─┼─ Task 6 ─┐
        │                   │          └─ Task 14 │  (only if Open decision 16)
        │                   └──────────┐          ├─ Task 13 ─ Task 11 ─ Task 12
        └─ Task 7 ─┬─ Task 8 ─┬─ Task 10 ─────────┘
                   └─ Task 9 ─┘
```

Go and Kit are parallel lanes after Task 1. Each Swift lane gets its own worktree and simulator.

**PRs into `feature/relay-client-next`:** A = Tasks 1–6 (safe alone and safe for the other lanes on this branch: no phone offers yet, so the age stays 90 days and every path is static; `TestKeyring_StaysAt90DaysOnRelayWithNoOffer` pins it). B = Tasks 7–10, with offers off by the build setting. C = Tasks 13, 11, 12. Turning the setting on is a separate one-line change under Open decision 1.

---

## Contract

### Task 1: Derivation, wire fields, vectors

**Depends on:** none

**Files:**
- Modify: `internal/hub/secure/kdf.go`, `internal/hub/wire/payloads.go`, `WatchtowerKit/Sources/WatchtowerSync/Secure/KeyDerivation.swift`, `Link/Keybox.swift`, `Relay/ControlPayload.swift`
- Modify (fixtures): `WatchtowerKit/Tests/Fixtures/e2e/kdf.json`, `WatchtowerKit/Tests/Fixtures/link/hub_contract_cases.json`
- Test: `internal/hub/secure/vectors_test.go`, `internal/hub/wire/contract_test.go`, `WatchtowerKit/Tests/WatchtowerSyncTests/E2EKeyDerivationTests.swift`, `HubContractFixtureTests.swift`, `KeyboxTests.swift`
- Docs: protocol spec §4.2 (key table), §5.4 (`KeyboxKeys`), §7.6 (`epoch_ack`)

**Interfaces:**
- Produces, Go: `secure.EphemeralRelayKey(ownEph *ecdh.PrivateKey, peerEph *ecdh.PublicKey, ownKX *ecdh.PrivateKey, peerKX *ecdh.PublicKey, hubEphPub, devEphPub, linkNonce []byte, hub, device ID, epoch uint32, dir Direction) ([]byte, error)`; `wire.KeyboxRelayKX{HubPub, DevicePub string}` (`hub_pub`, `device_pub`, unpadded base64url); `wire.KeyboxKeys.RelayKX *KeyboxRelayKX` (`relay_kx`), `PreviousRelayKX` (`previous_relay_kx`); `wire.Control.NextKX *string` (`next_kx`).
- Produces, Swift: `KeyDerivation.ephemeralRelayKey(ownEphemeral:peerEphemeral:ownStatic:peerStatic:hubEphemeralPublic:deviceEphemeralPublic:linkNonce:hubID:deviceID:epoch:direction:) throws -> SymmetricKey`; `KeyboxRelayKX`, `KeyboxKeys.relayKX`, `.previousRelayKX`; `ControlPayload.nextKX: String?`.

- [ ] **Step 1: Failing tests.** Kit `testEphemeralRelayKeyVector` reads the new `ephemeralRelayKeys` block of `kdf.json` (`p2h/1`, `h2p/1`, `p2h/2`, `h2p/2`, from fixed test keys) with its two ephemeral public keys. Go `TestEphemeralRelayKeyMatchesKitVectors` reads the same file. Also: both sides derive the same key; the key differs from the `wt/relay/v1/` one; differs when either ephemeral changes; an all-zero shared secret returns an error. Contract cases: `epoch_ack` with and without `next_kx`, a keybox with `relay_kx` and `previous_relay_kx`, and an old-shape keybox still decoding with nil fields. `TestEpochAckOfferUnknownToOlderHubDecodes` pins that the Go decoder, like today's, tolerates an unknown field.
- [ ] **Step 2: Run.** `go test ./internal/hub/secure ./internal/hub/wire -run 'Ephemeral|Contract'` and `make kit-test FILTER='E2EKeyDerivationTests|HubContractFixtureTests|KeyboxTests'`. Expected: FAIL, undefined symbols.
- [ ] **Step 3: Implement** the derivation exactly as "The scheme" says, and the fields. Generate the vector with `make e2e-vectors`; only the new block may differ (`git diff --stat` on the fixture shows additions only).
- [ ] **Step 4: Run** Step 2's commands. Expected: PASS. Run `go test ./internal/hub/secure -run TestWriteGoSealed` (unchanged bytes) and Kit `GoSealedEnvelopeTests`.
- [ ] **Step 5: Commit.** `feat: ephemeral relay key derivation and wire fields (#1248)`

---

## Go hub

### Task 2: Sidecar: offers and per-epoch relay keys

**Depends on:** Task 1, and the re-check above

**Files:**
- Create: `internal/hub/state/migrations/00014_ephemeral_kx.sql`, `internal/hub/state/relaykeys.go`
- Modify: `internal/hub/state/devices.go` (`deviceColumns`, scan), `internal/hub/state/link.go`, `internal/hub/actions/control.go` (`epochAck`)
- Test: `internal/hub/state/state_test.go`, `internal/hub/state/columns_test.go`, `internal/hub/actions/control_test.go`, `internal/hub/state/swift_file_test.go` (a Swift-era file still migrates)

**Interfaces:**
- Produces, migration: `ALTER TABLE devices ADD COLUMN kx_offer BLOB`; `ADD COLUMN kx_offer_epoch INTEGER NOT NULL DEFAULT 0`; `ALTER TABLE hub_epochs ADD COLUMN on_relay INTEGER`; `CREATE TABLE epoch_relay_keys (epoch INTEGER NOT NULL, device_id TEXT NOT NULL COLLATE NOCASE, hub_pub BLOB NOT NULL, device_pub BLOB NOT NULL, sealed_keys BLOB NOT NULL, PRIMARY KEY (epoch, device_id))`.
- Produces, state: `Device.KXOffer []byte`, `Device.KXOfferEpoch uint32`; `SetKXOffer(tx, device string, pub []byte, epoch uint32) (bool, error)` (writes only when `epoch >= kx_offer_epoch` and `relay_lapsed_at IS NULL`); `ClearKXOffers(tx) error`; `ClearDeviceKX(tx, device string) error` (offer and relay-key rows); `InsertEpochRelayKeys(tx, EpochRelayKeys) error`; `(*Store).EpochRelayKeys(epoch uint32, device string) (EpochRelayKeys, bool, error)`; `EraseEpoch(tx, epoch uint32) error` (deletes its relay-key rows, sets `sealed_keys = x''`); `hub_epochs.on_relay INTEGER` (set when the epoch begins; NULL on older rows, so option A of Open decision 4 never erases them).

- [ ] **Step 1: Failing tests.** `TestOlderAckDoesNotReplaceANewerOffer`, `TestBadOfferIsIgnoredAckStillCounted` (a short key, a non-curve value, an all-zero point), `TestOfferReadAfterSwitchAwayIsDropped` (`hub_meta.transport` is `cloudkit`: the ack counts, the offer does not), `TestEpochAckStoresOffer`, `TestRelinkClearsOfferAndRelayKeys` (`LinkDevice` with a new nonce), `TestOfferRefusedWhileLapsed`, `TestEraseEpochLeavesTheRowWithoutKeys`.
- [ ] **Step 2: Run** `go test ./internal/hub/state ./internal/hub/actions -run 'Offer|Ack|Relink|EraseEpoch'`. Expected: FAIL.
- [ ] **Step 3: Implement.** `epochAck` validates inside the processor, before `decide`: `ecdh.X25519().NewPublicKey` and a non-zero test exchange. In `decide`'s transaction it reads `MetaTransport`, calls `AckEpoch`, and calls `SetKXOffer` only on `relay`. A bad offer logs its class, never bytes. Relink: `LinkDevice`'s caller path clears when the nonce changes; put the clear in `LinkDevice` so no path misses it.
- [ ] **Step 4: Run** Step 2 and `go test ./internal/hub/state`. Expected: PASS.
- [ ] **Step 5: Commit.** `feat: hub stores phone key offers and per-epoch relay keys (#1248)`

### Task 3: Keyring: cadence, ephemeral rotation, lookup, recipient, erasure, echo sealing

**Depends on:** Task 2, and the re-check above

**Files:**
- Modify: `internal/hub/identity/keyring.go`, `internal/hub/runtime.go` (`housekeeping`), `internal/hub/switcher/announce.go` (`rotate`), `internal/hub/secure/record.go` (no new key logic; echoes use `InEpoch`), `internal/hub/actions/echo.go` and `control.go` (the sealer choice), `internal/hub/state/state.go` (`secure_delete`)
- Create: `internal/hub/identity/rotation_age_staging.go` (`//go:build relaystaging`: `func init() { relayRotationAge = 10 * time.Minute }`)
- Modify: `internal/hub/hubtest/phone.go` (a twin phone with `current` and `offered`, `relay_kx` read, stored pairs)
- Test: `internal/hub/identity/keyring_test.go`, `internal/hub/runtime_test.go`, `internal/hub/actions/epoch_test.go`

**Interfaces:**
- Consumes: Task 1's `secure.EphemeralRelayKey`, Task 2's state functions.
- Produces:
  - `var relayRotationAge = 7 * 24 * time.Hour` (unexported; only the tagged file changes it)
  - `(*Keyring).RotateToward(r Reason, onRelay bool, also func(*sql.Tx) error) error` (`RotateWith` reads `MetaTransport` and calls it; the switcher passes the target)
  - `(*Keyring).RotateIfDue(also func(*sql.Tx) error) (bool, error)`
  - `(*Keyring).EraseExpired() error`
  - `(*Keyring).PhoneEpoch(dev state.Device) (uint32, error)`: the acked epoch while retained if the phone has `kx_offer`, else 0 meaning current
  - `(*Keyring).AckedEpochRetained(dev state.Device) (uint32, error)`: the acked epoch while retained, else 0, for any phone (Task 5)
  - `(*Keyring).KeyboxKeysFor(device secure.ID) (wire.KeyboxKeys, error)`, replacing the shared `KeyboxKeys()`
  - `switcher.RotationBlocked(tx *sql.Tx) (bool, error)`: true while a switch record exists (over `recordTx`); the runtime's `also` uses it, since `identity` cannot import `switcher`

- [ ] **Step 1: Failing tests:**
  - `TestKeyring_RotatesAt7DaysOnRelayWithAnOffer`
  - `TestKeyring_StaysAt90DaysOnRelayWithNoOffer`
  - `TestRelayRotationAgeIs7DaysInTheDefaultBuild`
  - `TestNoReleasePathSetsRelayStaging`: reads `Makefile`, `scripts/build-app.sh` and the release scripts; the tag appears only on the `hub-staging` target
  - `TestKeyring_RotatesAt90DaysOrSeqCap` stays as it is
  - `TestKeyring_RotatesOnceAfterALongClose`
  - `TestRotationDerivesRelayKeysForOfferedPhonesOnly`: phone A offered, phone B not. A's row exists and both sides derive equal keys; B uses `wt/relay/v1/`
  - `TestRotationErasesTheHubEphemeral`: nothing private stored; `sealed_keys` opens to 64 bytes under the AAD `wt/hub-epoch-relay/v1` ‖ hub_id ‖ epoch ‖ device_id
  - `TestRotationFailureMidwayWritesNothing`
  - `TestRotateToCloudKitClearsOffersAndDerivesNone`
  - `TestRotateIfDueSkipsWhileASwitchIsRunning`
  - `TestRotateIfDueSkippedWhileHeldOnRelay`, with a held CloudKit hub still rotating at 90 days as today
  - `TestKeyboxRecipientIsTheOfferForALinkedPhone`: a pending, revoked or refused device still gets `dev_kx`
  - `TestKeyboxKeysNameBothEpochs`
  - `TestStaticKeyboxOmitsAnEphemeralPreviousEpoch`
  - `TestEraseExpiredRemovesKeysAtRetentionEnd`: a retired epoch past `retire_after` opens to nothing, its relay rows are gone, `RelayKey` for it is refused by `AcceptsRelayEpoch`
  - `TestUnlinkRemovesOfferAndRelayKeys`
  - `TestLinkDuringRotationStartsStatic`
  - `TestLostAckStillRetiresAt7Days`
  - `TestEchoSealedInAckedEpochWhileKeyboxIsStuck`
  - `TestNeverOfferedPhoneSealsInCurrentEpoch`
  - `TestRelayKeyCacheDropsAnErasedEpoch`
- [ ] **Step 2: Run** `go test ./internal/hub/identity ./internal/hub/actions ./internal/hub -run 'Rotat|Keybox|Erase|Echo|Unlink|Lost|Link'`. Expected: FAIL.
- [ ] **Step 3: Implement:**
  - **`rotationDue`** picks `relayRotationAge` when `MetaTransport` is `relay` and any `devices` row has `kx_offer`, else `RotationAge`.
  - **`RotateToward`:** in the transaction, after `also` and after inserting the epoch: when `onRelay`, for each `devices` row with an offer draw `ecdh.X25519().GenerateKey`, derive, seal, insert; when not `onRelay`, `ClearKXOffers`. Log `epoch N begun (reason): k ephemeral, m static`, numbers only.
  - **`RelayKey`:** the sealed row if there is one, else today's derivation; cache as today, dropped by `EraseExpired`.
  - **`KeyboxRecipient`:** the offer for a linked row with `kx_offer`, else today's order.
  - **`housekeeping`:** `RotateIfDue` gets an `also` that returns `ErrSkipRotation` when the switch record is in progress (`switcher.RotationBlocked`), and the call is skipped when on the relay and `isHeld()`. After `RetireOld`, `EraseExpired`, then a best-effort `wal_checkpoint(TRUNCATE)`.
  - **Echoes and controls** for a phone use `Sealer.InEpoch(PhoneEpoch(dev))` when non-zero.
  - **`EraseExpired`** erases only epochs allowed by Open decision 4 (`on_relay = 1` under option A), and sets `PRAGMA secure_delete = ON` on its connection first.
  - **`make hub-staging`** builds the headless binary with `-tags relaystaging`, for the staging run only.
- [ ] **Step 4: Run** Step 2's command, then `go test ./internal/hub/identity ./internal/hub/actions ./internal/hub/switcher ./internal/hub/link`. Expected: PASS.
- [ ] **Step 5: Commit.** `feat: hub rotates relay epochs weekly with ephemeral keys (#1248)`

### Task 4: Per-phone keyboxes and the free phone

**Depends on:** Task 3, and the re-check above

**Files:**
- Modify: `internal/hub/link/grants.go`, `internal/hub/link/center.go` (config), `internal/hub/switcher/announce.go`, `internal/hub/switcher/accept.go`, `internal/hub/runtime.go` (the wiring)
- Test: `internal/hub/link/center_test.go`, `internal/hub/switcher/switcher_test.go`

**Interfaces:**
- Consumes: `KeyboxKeysFor`.
- Produces: `Center.Keyboxes()` (what the data zone carries, applying the rule) and `Center.KeyboxesAll()` (always keys for a linked phone); config `KeysInZone func(device string) bool`, where nil means true. The runtime sets it to "not on the relay, or (not lapsed, and a reader of the data zone or the reader list is still unknown)" over `devices.relay_lapsed_at` and `Transport.Readers()`.

- [ ] **Step 1: Failing tests.** `TestFreePhoneKeyboxOnRelayHasNoKeys`; `TestReaderListUnknownKeepsKeys` (availability first at startup); `TestPayingPhoneBecomesReaderGetsKeysNextCycle`; `TestSwitchToCloudKitGivesAFreePhoneItsKeys`; `TestStaleActionNoticeUsesKeyboxesAll`; `TestOldBuildPhoneStaysStaticAcrossRotations`; `TestSecondPhoneIndependentOffers`.
- [ ] **Step 2: Run** `go test ./internal/hub/link ./internal/hub/switcher -run 'Keybox|Free|Reader|Stale|OldBuild|SecondPhone'`. Expected: FAIL.
- [ ] **Step 3: Implement.** `linked[i].Keys` is built per phone under the center's lock. Every `transport_switched` (`announce`, the stale-action answer) reads `KeyboxesAll`. A linked phone with `Keys == nil` is ignored harmlessly by the phone's `mergeKeys`, as today. `notice`'s `kb.Keys == nil` skip stays for pending and refused rows.
- [ ] **Step 4: Run** Step 2 and `go test ./internal/hub/link ./internal/hub/switcher ./internal/hub/slices`. Expected: PASS.
- [ ] **Step 5: Commit.** `fix: a phone that cannot read the relay zone gets no epoch keys there (#1248)`

### Task 5: Alert pushes sealed in an epoch the phone holds

**Depends on:** Task 3

**Files:**
- Modify: `internal/hub/alerts/pusher.go`, `internal/hub/alerts_wiring.go`
- Test: `internal/hub/alerts/pusher_test.go`, `internal/hub/alerts_wiring_test.go`, `internal/hub/hubtest/phone.go` (opening at the acked epoch)

**Interfaces:**
- Consumes: `Sealer.InEpoch`; the acked-while-retained rule (`Keyring.AckedEpochRetained(dev)`, for **every** relay phone, offering or not, so an old build's alerts stay readable on a locked phone too).
- Produces: pusher config `EpochFor func(device string) uint32`. 0 = current. `AlertPush` is sealed once per distinct epoch among the `begun` devices of that key.

- [ ] **Step 1: Failing tests.** `TestAlertPushSealedInAnEpochThePhoneHolds`: phone acked `e`, hub at `e+1`, push opens with `K_alert[e]`. `TestAlertPushFallsBackToCurrentAfterRetention`. `TestTwoPhonesOnDifferentEpochsGetTheirOwnSeal`. `TestRotationAt7DaysSendsNoSecondAlert`: three rotations on the relay with an open ask, exactly one `send_alert` and one signal.
- [ ] **Step 2: Run** `go test ./internal/hub/alerts ./internal/hub -run 'AlertPush|TwoPhones|SecondAlert'`. Expected: FAIL.
- [ ] **Step 3: Implement** the grouping at `pusher.go`'s seal. Settlements stay per `(key, device)`.
- [ ] **Step 4: Run** Step 2. Expected: PASS.
- [ ] **Step 5: Commit.** `fix: relay alert pushes open on a locked phone across a rotation (#1248)`

### Task 6: Go end to end over the fake transport

**Depends on:** Tasks 4, 5

**Files:**
- Create: `internal/hub/rotation_test.go`
- Modify: `internal/hub/hubtest/phone.go` as needed

**Interfaces:**
- Consumes: Tasks 3–5.
- Produces: tests, plus a content-free log line at the end of the first full republish after a rotation: `hub: rotation republish: N records, B asset bytes, D s`. **The log line is an instrument, not the measurement.** On the fake transport it proves only that the count is right; "Measuring the cost" says how real numbers get taken.

- [ ] **Step 1: Failing tests.** `TestRuntime_RestartAfterRotationRepublishesOnce`. `TestRotationWhileRelayDownPublishesOnReturn`. `TestRuntime_ThreeRotationsTwoPhones`: one offered, one static, each opens slices, echoes and controls in every epoch. `TestRotationRepublishLogsCounts`, with no names or bytes in the line (`logcanary`-style check). `TestPermissionAnswerAcrossARotationAppliedOnce` and the same for `session_interrupt` (PROJ-21).
- [ ] **Step 2: Run** `go test ./internal/hub -run 'Runtime_|RotationWhile|RotationRepublish'`. Expected: FAIL.
- [ ] **Step 3: Implement** the log line in the publisher's cycle report path, only for the cycle after a hash wipe.
- [ ] **Step 4: Run** Step 2, then `make lint-diff`. Expected: PASS, no new issues.
- [ ] **Step 5: Commit.** `test: rotation end to end on the hub, with its republish cost logged (#1248)`

---

## Kit and phone

### Task 7: `HubLinkKeys`: ephemeral state, merge, atomic update, key rule

**Depends on:** Task 1

**Files:**
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Secure/KeyStore.swift`, `KeychainKeyStore.swift`, `InMemoryKeyStore.swift`, `PhoneKeyProvider.swift`, `SecureKeyProvider.swift`, `WatchtowerMobile/Sources/App/CachingPhoneKeyStore.swift`
- Move: `HubLinkKeys.adding(_:)` from `WatchtowerMobile/Sources/Features/Onboarding/ScannedHubKeys.swift` into the Kit, with a thin caller left
- Test: `WatchtowerKit/Tests/WatchtowerSyncTests/KeyStoreTests.swift`, a new `EphemeralKeysTests.swift`, `WatchtowerMobile/Tests/CachingPhoneKeyStoreTests.swift`

**Interfaces:**
- Produces:
  - `EphemeralKey: Codable, Sendable { publicKey: Data; privateKey: Data }`
  - `HubLinkKeys.currentKX: EphemeralKey?`, `.offeredKX: EphemeralKey?` (absent keys decode as nil)
  - `EpochKeys.relayKeys: EpochRelayKeys?` with `p2h`, `h2p`, `Data`
  - `HubLinkKeys.merging(_ keys: KeyboxKeys, identity: DeviceIdentityKeys, hubID: UUID, deviceID: UUID, now: Date) throws -> HubLinkKeys`, which throws `KeyboxKeysError.unknownEphemeral`
  - `HubLinkKeys.withOffer() -> (HubLinkKeys, publicKey: Data)`, a no-op when one exists
  - `HubLinkKeys.clearingEphemeral() -> HubLinkKeys` (the two private keys go; stored pairs stay)
  - `HubLinkKeys.droppingEphemeral() -> HubLinkKeys` (stored pairs go too: the link is static for every epoch)
  - `PhoneKeyStore.updateHubLink(_ hubID: String, _ change: (HubLinkKeys) throws -> HubLinkKeys) throws -> HubLinkKeys?`
  - `SecureTransportError.epochKeysGone`, `.epochKeysPending`
  - `SecureKeyProvider.keyboxRecipients() throws -> [Curve25519.KeyAgreement.PrivateKey]`

- [ ] **Step 1: Failing tests:**
  - `testOldItemDecodesWithNoEphemeralState`
  - `testMergeDerivesPromotesAndErases`: after the merge `currentKX` is the old offer, `offeredKX` nil, the older private key nowhere in the encoded item
  - `testMergeDerivesThePreviousEpochTooWhenMissing`
  - `testMergeWithoutRelayKXIsStatic`
  - `testAKeyboxNamingAnUnknownKeyIsNotMerged`
  - `testMergeIsOneKeychainWrite`
  - `testUpdateHubLinkOnARemovedLinkWritesNothing`
  - `testConcurrentUpdatesLoseNothing`
  - `testAlertMaterialCarriesNoRelayKeysOrEphemerals`
  - `testRetentionDropsRelayKeysWithTheEpoch`
  - `testRowsInAnErasedEpochStayPendingUntilRepublished`
  - `testKeychainSizeCheckCoversTheNewKeys`
  - the provider's five rows from "The scheme" as `testRelayKey_<row>`
  - `testProviderHoldsNoEphemeralRelayKeyInItsCache`
  - `CachingPhoneKeyStoreTests.testUpdateWritesThroughTheCache`
- [ ] **Step 2: Run** `make kit-test FILTER='EphemeralKeysTests|KeyStoreTests'`. Expected: FAIL.
- [ ] **Step 3: Implement.** `updateHubLink` runs the read, change and write under the store's existing lock (`CachingPhoneKeyStore` forwards it and replaces its cached link). `saveHubLink`'s alert copy is already built field by field: keep it that way and pin it. `merging` compares by pair presence as well as epoch number, so a pair missing on a held epoch still merges. The provider's in-memory `relayKeys` cache keeps static keys only.
- [ ] **Step 4: Run** Step 2, then `make mobile-test SIM='<yours>' MOBILE_FILTER=CachingPhoneKeyStoreTests`. Expected: PASS. `make lint-swift`.
- [ ] **Step 5: Commit.** `feat: phone keeps ephemeral keys and stored relay keys per epoch (#1248)`

### Task 8: Opening with candidates, gone epochs, the offer on `epoch_ack`

**Depends on:** Task 7

**Files:**
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Secure/SealedBox.swift`, `SecureTransport.swift`, `Replica/ReplicaOpener.swift`, `Relay/RelayFeed.swift`, `Relay/ActionOutbox+Ordered.swift`, `Replica/ReplicaStore+Outbox.swift`
- Test: `SecureTransportTests.swift`, `ActionOutboxOrderedTests.swift`, `RelayFeedTests.swift`, `KeyboxTests.swift`; `WatchtowerKit/Tests/WatchtowerSyncTests/GoSealedEnvelopeTests.swift` (the Go-sealed keybox with `relay_kx`)
- Modify (fixture): `internal/hub/secure/testdata/go-sealed.json` through `go test ./internal/hub/secure -run TestWriteGoSealed -update` (a new case only)

**Interfaces:**
- Consumes: Task 7.
- Produces:
  - `SealedBox.open(_:envelopeClass:recipients:info:context:verifier:)`
  - `ActionOutbox.enqueueEpochAck(epoch: UInt32, nextKX: Data?) async throws -> Bool`
  - `ReplicaStore.epochAckDue(_ epoch: UInt32, nextKX: Data?) throws -> Bool` (new meta key `epoch_ack_kx`)
  - `ActionOutbox.requeueUnreadableEcho(wireName: String) async throws -> Bool`

- [ ] **Step 1: Failing tests:**
  - `testAKeyboxSealedToTheOfferOpens`, `...ToCurrentOpens`, `...ToDevKXOpens`
  - `testNoCandidateOpensIsNotALockError`, with `.locked` still thrown as `keysUnavailable`
  - `testASignatureFailureIsNotRetriedOnOtherKeys`
  - `testAnEchoAboveTheNewestEpochWaitsForTheKeybox`: `changes` throws `keysUnavailable`, the token is kept, the replay after merge opens
  - `testARotationDoesNotSweepTheReplica`, once #1497 is in the branch
  - `testARelayRecordInAGoneEpochIsDroppedNotReplayed`: `.unopenable("epochGone")`, the batch finishes, the token moves
  - `testADroppedEchoQueuesItsActionAgain`: matched by `row.wireName`, row `sent`; the flush overwrites by sim rule 3
  - `testAnOutboxRowPastItsKeyIsNotDelivered`: `reseal` returns nil on `epochKeysGone`
  - `testALostAckResendsTheOfferAtTheNextRaise`
  - `testTheSameEpochWithANewOfferIsDue`; `testTheSameEpochSameOfferIsNotDue`; `testALowerEpochIsNeverDue`
  - `testAnUnsentAckIsReplacedKeepingTheNewestOffer`
  - `testResealUsesStoredKeysForTheOldEpochAndTheCurrentForTheNew`
  - `testGoSealedKeyboxWithRelayKXOpens`
  - `testAHubThatNeverConsumesStaysStatic`
- [ ] **Step 2: Run** `make kit-test FILTER='SecureTransportTests|ActionOutboxOrderedTests|RelayFeedTests|KeyboxTests|GoSealedEnvelopeTests'`. Expected: FAIL.
- [ ] **Step 3: Implement.** The signature is verified once, before any HPKE attempt. `openRelay` maps `epochKeysGone` to `.unopenable("epochGone")` in the phone branch only. `epochKeysPending` is mapped with `relay_wait_since` and `keyboxWaitCap` (Task 13 adds the cap's tests). The feed hands an `epochGone` outcome's wire name to the outbox. `queueEpochAck` puts `nextKX` (base64url) on the payload. An ack sealed with the old epoch's stored keys is fine: the hub retains it.
- [ ] **Step 4: Run** Step 2. Expected: PASS. `make lint-swift`.
- [ ] **Step 5: Commit.** `feat: phone opens keyboxes with its ephemeral keys and offers the next one (#1248)`

### Task 9: Recording uploads survive a rotation

**Depends on:** Task 7

**Files:**
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Relay/RecordingUploader.swift`
- Docs: protocol spec §7.7
- Test: `WatchtowerKit/Tests/WatchtowerSyncTests/RecordingUploaderTests.swift`, `internal/hub/actions/recording_twins_test.go` (a resealed copy is received once)

**Interfaces:**
- Consumes: `SecureTransport.reseal(ownEnvelope:wireName:modifiedAt:)`, `currentEpoch()`.
- Produces: `RecordingUploader.epochRaised()`, which re-arms rows whose stored envelope is older than the current epoch (resets their backoff, including a "stuck" row).

- [ ] **Step 1: Failing tests.**
  - `testARowSealedInAnOlderEpochIsResealedBeforeSending`: new stored envelope, same wire name, same sealed file, same asset descriptor.
  - `testARowInTheCurrentEpochSendsItsBytesUnchanged`.
  - `testEpochRaisedReArmsAStuckRow`.
  - `testAKeyGoneRowIsSealedFreshFromThePlainFile`.
  - `testAKeyGoneRowWithNoPlainFileFailsAsTheMissingFileCase`: the existing "missing file, no Retry".
  - `testALockedPhoneKeepsTheRowWaiting`.
  - Go: `TestResealedUploadReceivedOnce`.
- [ ] **Step 2: Run** `make kit-test FILTER=RecordingUploaderTests` and `go test ./internal/hub/actions -run ResealedUpload`. Expected: FAIL.
- [ ] **Step 3: Implement** at the point `saveSealed` reads the stored envelope: parse the header epoch, compare with `currentEpoch()`, reseal, persist before saving. The hub's window for the old epoch is not consulted: the phone cannot know it. Under Open decision 4's option A this runs only on a relay route or a link that has moved routes (a new init flag, `resealsOlderEpochs: @Sendable () -> Bool`); under option B always. `testAnICloudOnlyLinkSendsItsBytesUnchanged` pins option A.
- [ ] **Step 4: Run** Step 2. Expected: PASS. `make lint-swift`.
- [ ] **Step 5: Commit.** `fix: a recording sealed before a rotation is resealed, not lost (#1248)`

### Task 10: App wiring

**Depends on:** Tasks 8, 9

**Files:**
- Modify: `WatchtowerMobile/Base.xcconfig`, `Info.plist`, `project.yml` (`WATCHTOWER_RELAY_KEY_ROTATION`, empty by default, as `WATCHTOWER_RELAY_ORIGIN`)
- Modify: `WatchtowerMobile/Sources/Features/Onboarding/LinkingViewModel.swift` (`mergeKeys`), `WatchtowerMobile/Sources/App/Hubs/HubSession.swift` (`acknowledgeNewestEpoch`, `keysMerged`), `WatchtowerMobile/Sources/App/Hubs/TransportFollower.swift`, `WatchtowerMobile/Sources/App/AppRoot.swift` (`mergeSwitchKeys`, the host seam)
- Test: `WatchtowerMobile/Tests/LinkingViewModelTests.swift`, `TransportFollowerWiringTests.swift`, a new `EphemeralRotationWiringTests.swift`

**Interfaces:**
- Consumes: Tasks 7–9.
- Produces: no new public surface. `mergeKeys` goes through `keys.updateHubLink` and `merging`; `.unknownEphemeral` logs once and returns false.

- [ ] **Step 1: Failing tests:**
  - `testARelayRoutePhoneOffersOnEveryRaise`
  - `testWithTheBuildSettingEmptyAPhoneNeverOffers`
  - `testAnICloudRoutePhoneNeverOffers`: a guard for "CloudKit crypto does not change"; the control's bytes have no `next_kx`
  - `testAnOfferNotYetAckedGoesAtBoot`
  - `testAFailedSaveKeepsTheOldLinkAndRetries`
  - `testFollowingToICloudClearsEphemeralState`, after the keybox merge, in the follower's crash-safe order
  - `testFollowingToRelayOffersAfterTheMove`
  - `testARaiseKicksTheUploader`
  - `testUnlinkDuringAMergeDoesNotResurrectTheLink`
  - `testNoNewScreenStateOnAnUnreadableKeybox`: `readGrant` is `.unreadable`, the link row unchanged
  - `testTwoHubsKeepSeparateOffers`
- [ ] **Step 2: Run** `make mobile-test SIM='<yours>' MOBILE_FILTER='EphemeralRotationWiringTests|TransportFollowerWiringTests'`. Expected: FAIL. On "missing required module GRDBSQLCipher": `make mobile-build SIM='<yours>'`, then rerun.
- [ ] **Step 3: Implement.** `acknowledgeNewestEpoch`: on route `.relay` with the build setting on, `updateHubLink { $0.withOffer() }` first (the private key is saved before any ack exists), then `enqueueEpochAck(epoch:nextKX:)`; on any other route `nextKX: nil`. `keysMerged` calls `uploader.epochRaised()` on a raise. The guard files `PermissionAllowRuleTests`, `PermissionCardTests` and `SessionInputWiringTests` stay untouched.
- [ ] **Step 4: Run** Step 2 and `make mobile-test SIM='<yours>' MOBILE_FILTER='LinkingViewModelTests|RelayLinkingTests'`. Expected: PASS. `make lint-swift`.
- [ ] **Step 5: Commit.** `feat: the phone runs relay key rotation (#1248)`

---

## Together

### Task 11: Kit ↔ Go hub interop on the stand

**Depends on:** Tasks 6, 10, 13

**Files:**
- Modify: `internal/hub/interop_kit_test.go`, `internal/hub/interop_test.go` if a helper belongs there
- Create: `WatchtowerKit/Tests/WatchtowerHostedRelayTests/Interop/KitGoHubInteropTests+Rotation.swift`
- Modify: `WatchtowerKit/Tests/WatchtowerHostedRelayTests/Sim/SimPhone.swift` only if the census test requires a twin line

**Interfaces:**
- Consumes: everything above, `interopOpts.clock`, the file hand-off of `make relay-interop-kit-hub RELAY=<relay checkout>`.
- Produces: tests only. The relay stays pinned at `bcca870`, unchanged.

- [ ] **Step 1: Write the scenario**, driven through the Go hub's moved clock, with the Kit phone's real `HubLinkKeys` over an in-memory key store:
  1. Link over a relay pairing slot. Hub sends a `dev_kx` keybox with no `relay_kx`. The phone acks with `next_kx`.
  2. Clock +8 days, one daemon cycle. Epoch `e+1` is ephemeral. The phone opens the keybox with its offer, derives, promotes. An action goes out and is echoed and applied once. The hub's `relay_kx.device_pub` equals the offer. The old private key is gone from the encoded item.
  3. One rotation with the phone away. Its action sealed in `e+1` is still accepted; the keybox opens on return.
  4. Three rotations with the phone away, an action held in its outbox (`created_at` on the hub's moved clock, within the age window). `resend_from`, resealed under the same `action_seq`, applied once. A sealed recording in the same state is resealed and received once. The mailbox feed is not jammed.
  5. Switch to iCloud in the middle of an outstanding offer. New epoch static, offer cleared on both sides, an action applied. Back to the relay after the 5-minute rule: a static epoch, then ephemeral after one more rotation.
  6. A second, static test phone (no offers) stays linked through steps 2–3 and opens every epoch.
  7. Two paying phones; one lapses on the stand's `/dev/entitlement` with the hub staying on the relay. Its offer and rows are gone, it reads `hub_on_relay` and leaves, the other phone rotates. It pays again 15 moved days later: keybox merged at the reader wait, request accepted, followed, new offer, ephemeral at the next rotation.
- [ ] **Step 2: Run** `make relay-interop-kit-hub RELAY=<relay checkout>`. Expected: FAIL at the first new assertion until the steps above are wired, then PASS.
- [ ] **Step 3: Run** `go test -tags interop ./internal/hub -run TestInterop_KitPhone` and `make kit-test FILTER=KitGoHubInteropTests` if the script's CI mode needs them separately. Expected: PASS.
- [ ] **Step 4: Commit.** `test: Kit and Go hub rotate relay keys on the stand (#1248)`

### Task 12: Docs and the gate

**Depends on:** Task 11

**Files:**
- Modify: `docs/features/relay-client.md` (a "Phase 5" section, the Epochs section, v1 limits), `docs/features/go-hub.md`, `docs/features/mobile-companion.md`, `docs/superpowers/specs/2026-10-31-hub-phone-protocol-design.md` (§4.2 epochs, Decisions, §11), `docs/superpowers/specs/2026-10-29-relay-client-design.md` (§1, §13 row 5 and the line "Launch for users waits for Phases 0a and 1–4", per Open decision 1; the Decision on rotation keyboxes, per Open decision 2), `docs/superpowers/specs/2026-10-31-go-hub-design.md` (§3's non-goal), `docs/superpowers/plans/2026-11-03-relay-client-phase-4.md` (Launch conditions and manual checks, if Open decision 1 is option A), this plan's Decisions
- Check: `grep -rn -i 'rotat\|epoch\|every 90' docs/guide` (no page states the key schedule today, so no guide change is expected; a hit means a same-PR fix under `docs/guide/WRITING.md`), `docs/inventory/workbench.md` PROJ-16's note and PROJ-21 (both stay true; no PROJ text changes)

**Interfaces:** none.

- [ ] **Step 1:** Write the docs, including the honest threat text and the 14-day figure.
- [ ] **Step 2: Gate (controller).** `make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`, `make mobile-test SIM='<yours>'`, `make relay-interop-kit-hub RELAY=<relay checkout>`. Expected: exit 0 for each; a known flake is named, not skipped.
- [ ] **Step 3: Commit.** `docs: relay key rotation (#1248)`
- [ ] **Step 4: Staging run, for turning the setting on, not for merging.** See "The staging run". It does not block PR C under Open decision 1's option B.

### Task 13: Losing and regaining reader status

**Depends on:** Tasks 4, 8, 10

**Files:**
- Modify: `internal/hub/switcher/entitlement.go` (`lapse`, new `ReaderLost`), `internal/hub/link/relay.go` or `internal/hub/runtime.go` (feeding answered account reads to `ReaderLost`), `internal/hub/state/devices.go` if `ClearDeviceKX` needs a transaction form
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Secure/SecureTransport.swift` (the static exception, the replay cap), `Relay/TransportFollowerPolicy.swift` (a `dropEphemeral` command on `relayLapsed` and `withoutHub`), `WatchtowerMobile/Sources/App/Hubs/TransportFollower.swift`, `SideMailboxReader.swift`, `RelayUpgrade.swift` (`awaitReader`)
- Test: `internal/hub/switcher/switcher_test.go`, `SecureTransportTests.swift`, `TransportFollowerWiringTests.swift`, `RelayUpgradeWiringTests.swift`; Kit twin in `WatchtowerHostedRelayTests/Sim/SimPhone.swift` runs the new command

**Interfaces:**
- Consumes: Task 2's `ClearDeviceKX`, Task 4's `KeysInZone`, Task 7's `droppingEphemeral`, Task 8's mapping.
- Produces: `(*Switcher).ReaderLost(device string) error`; `FollowerCommand.dropEphemeral`; `SecureTransport`'s `keyboxWaitCap: TimeInterval = 3600`; `RelayUpgrade`'s keybox merge through `RelayUpgradeHost.mergeKeybox(hubID:) async -> Bool`.

- [ ] **Step 1: Failing tests.** Go:
  - `TestLapseWithAnotherPayerClearsOfferAndRows`: afterwards `RelayKey` for every epoch is static and `KeyboxRecipient` is `dev_kx`
  - `TestLapseWithNobodyElseStillClears`, and on a headless host with no CloudKit
  - `TestRotationAfterLapseDerivesNoRowForThatPhone`
  - `TestLapseAndRotationEitherOrder`
  - `TestLapseRestartKeepsKXCleared`
  - `TestHubOnRelaySealedStaticAfterLapse`
  - `TestReaderLostAfterTwoReadsRunsLapse`, `TestOneMissingReadChangesNothing`, `TestAnUnansweredReadCountsAsNothing`, `TestReaderLostIgnoresAPhoneWithNoEphemeralState`
  - `TestLastOfferGoneBackTo90Days`
  - `TestLapsedPhoneKeyboxHasNoKeysAndIsRepublished`
  - `TestRenewedPhoneGetsKeysInZoneThenOffersAgain`, `TestRenewedPhoneOffersAgain`

  Kit and phone:
  - `testHubOnRelayOpensOverAStaleEphemeralState`, for each row of the key table
  - `testAStaticEchoIsRefusedOnAnEphemeralLink`
  - `testAPendingEpochStopsReplayingAfterTheCap`, `testAMergeClearsTheWaitSince`
  - `testTheSideReaderNeverReplaysAPendingEpoch`: owed echoes ahead of `hub_on_relay` in the iCloud mailbox do not stop it
  - `testCanUseRelayNoMakesPendingUnopenableAtOnce`
  - `testRelayLapsedQueuesTheRequestThenDropsEphemeral`
  - `testWithoutHubDropsEphemeral`; `testAPlainFollowToICloudKeepsStoredPairs`
  - `testAPhoneBackOnICloudWithTheHubOnRelayStaysStatic`
  - `testAwaitReaderMergesTheKeyboxBeforeTheRequest`, `testAwaitReaderWithNoKeysYetKeepsWaiting`, `testAwaitReaderLimitStillEndsInReaderNotConfirmed`
- [ ] **Step 2: Run** `go test ./internal/hub/switcher ./internal/hub/link -run 'Lapse|ReaderLost|Renewed|LastOffer|OneMissing|Unanswered'`, `make kit-test FILTER='SecureTransportTests|TransportFollowerPolicyTests|RelaySimSwitchTwins'`, `make mobile-test SIM='<yours>' MOBILE_FILTER='TransportFollowerWiringTests|RelayUpgradeWiringTests'`. Expected: FAIL.
- [ ] **Step 3: Implement** as "Losing and regaining reader status" states. `lapse`'s clear runs before `othersPay`, so every branch has it. The two-read rule is in memory: a restart starts counting again, which only delays. If G2 has landed with its own trigger (the re-check), `ReaderLost` is not added and G2's trigger reaches `lapse`.
- [ ] **Step 4: Run** Step 2, then `make lint-diff` and `make lint-swift`. Expected: PASS, no new issues.
- [ ] **Step 5: Commit.** `fix: a phone that stops being a reader leaves cleanly and can come back (#1248)`

### Task 14: Rotation visibility (only if Open decision 16 is approved)

**Depends on:** Task 3

**Files:**
- Modify: `cmd/hub_link.go` (`hub status`, `hub phones`, both read-only over `state.OpenReadOnly`), `internal/hub/runtime.go`
- Test: `cmd/hub_link_test.go`

**Interfaces:** `hub status --json` adds `epoch`, `epoch_age_days`; `hub phones --json` adds `keys` = `"ephemeral"|"static"` per phone (a relay-key row in the current epoch). No key material; no names beyond what these verbs already print.

- [ ] **Step 1: Failing tests.** `TestHubPhonesJSONKeysPinned`, `TestHubStatusShowsEpochAge`, `TestStuckRotationLogsOncePerDay`: a relay hub, not held, epoch older than 14 days.
- [ ] **Step 2: Run** `go test ./cmd -run 'HubPhones|HubStatus'` and `go test ./internal/hub -run StuckRotation`. Expected: FAIL.
- [ ] **Step 3: Implement** the additive keys and the log line.
- [ ] **Step 4: Run** Step 2. Expected: PASS.
- [ ] **Step 5: Commit.** `feat: hub shows epoch age and each phone's key scheme (#1248)`

## Measuring the cost

Task 6's fake transport cannot give real size, phone traffic or wakes. Three separate measurements, with the owner's only live-data step named.

**M-A. Real size. Owner step, or the controller at the owner's request; read-only.** On the owner's Mac, with the installed app, using nothing built from this repo:

```
sqlite3 -readonly "<workspace>/watchtower.db" "SELECT count(*), sum(length(CAST(segments_json AS BLOB))) FROM meeting_transcripts WHERE created_at >= datetime('now','-30 days');"
sqlite3 -readonly "<hub state dir>/hubstate.db" "SELECT count(*) FROM slice_state;"
```

Never a dev CLI on the live database. **The numbers go to the ask's answer only, never into a repo file, PR or plan: this repo is public.** The first gives the plain asset volume (an upper bound: `segments_json` before the 20 MB clip), the second the record count; each record costs at most one envelope, padded to at least 256 B and at most 900 KB.

**M-B. Traffic and wakes, on staging.** After M-A, and after "The staging run"'s dependencies. The controller generates a synthetic workspace with M-A's counts and sizes (no real content), runs `make hub-staging` on a test host with a 10-minute epoch, and links one real iPhone with a build that has the setting on. Over three rotations:

- **Hub upload:** the Task 6 log line.
- **Phone traffic:** a content-free debug log in `HostedRelayTransport` (bytes per `changes` page and per download, DEBUG builds only), read from Console by the owner or controller.
- **Wakes:** with the phone locked and the app in the background, count `fetchForPush` log lines per rotation. The relay coalesces silent pushes per device into one per 2 s window (`COALESCE_MS`), and a republish lasting minutes can ask for many; APNs may throttle them further, so a device count is the only real figure.

**Thresholds, each checkable from those three readings:**

| Reading | Pass |
|---|---|
| Hub upload per rotation | at most 500 MB |
| Phone download per rotation | at most 500 MB, so at most about 2.2 GB a month against the relay's 100 GB |
| Background wakes per rotation, locked phone | at most 6. Over that, the battery rule (#724) applies: the owner rules before the setting turns on |

A fail reopens Open decision 8. **By whom and when:** M-A by the owner before PR A's review closes; M-B by the controller with the owner's device, before the setting turns on. It does not block merging dark code.

## The staging run

Moving a real hub's clock is not possible (`interopOpts.clock` exists only on the test stand), and a week's wait is not a check. So `-tags relaystaging` gives a 10-minute epoch, on a test host only, guarded by `TestNoReleasePathSetsRelayStaging` and `TestRelayRotationAgeIs7DaysInTheDefaultBuild`.

**Depends on:** Phase 4's owner-only steps and M1–M10 on staging, **none of which has run**. Staging readiness is therefore unproven. This run comes after M2 (a real App Attest) and M4 and M5 (pushes) at least.

**Steps, on one iPhone and one test hub:**

1. Link over the relay. A static first epoch; after 10 minutes the first ephemeral one. An action goes through.
2. Phone locked across a rotation: an ask alert shows its text (Task 5).
3. Airplane mode for three rotations, one action queued and one recording finished. Back on: both arrive once.
4. M-B's readings.
5. On a second paying phone, or with a sandbox expiry: the lapse path of Task 13.

**The owner runs the device steps; the results go in PR C's follow-up or the ask, numbers from synthetic data only.** Until this passes, `WATCHTOWER_RELAY_KEY_ROTATION` stays empty.

---

## Decisions

| Decision | Source |
|---|---|
| PR base `feature/relay-client-next` | controller's brief; timing of turning it on is Open decision 1 |
| The plan covers the Go hub half | **not yet ruled**: Open decision 5 |
| Relay links rotate; CloudKit keeps 90 days and static keys | relay design §7 item 4; relay client spec §1, ask #799 |
| At launch static keys were accepted; this phase replaces them | ask #799 (timing is Open decision 1) |
| A hub has one scheme, by its current transport; every switch starts an epoch | relay design §3, §7.4 (ask #702 there); relay client spec §9 |
| Retention 7 days, at most 8 epochs, on both sides; not rule 14's 14 days | ask #843; Phase 3 Owner approval 4, ask #904 |
| `epoch_ack` to ordered hubs; reseal with the same `action_seq` on `resend_from` | Phase 3 Owner approval 4 (R9, R10), ask #904 |
| Switch keyboxes stay inside `transport_switched` | ask #799 |
| Rotation keyboxes on a timer: where they travel | **not yet ruled**: Open decision 2 (the plan is written for option A) |
| `K_meta`, `hub_sig`, `hub_kx`, `dev_kx`, `dev_sig` do not rotate | protocol §4.2; decided by the agent for this phase |
| Rotation is automatic with no owner action | relay design §7 item 5 |
| No relay change is needed | decided by the agent after reading the relay at `bcca870`; ask #734 not triggered |
| Offer on `epoch_ack`, no new control kind, no grant capability field | decided by the agent |
| At most two ephemeral keys per hub on the phone | decided by the agent |
| A static fallback decided by the row's presence, per `(epoch, device)` | decided by the agent |
| The hub draws a per-phone ephemeral and never stores it | decided by the agent; see Open decision 7 |
| Sealed relay keys in the sidecar under the AAD `wt/hub-epoch-relay/v1` | decided by the agent |
| `PhoneKeyStore.updateHubLink` serialises all writers | decided by the agent |
| A re-link clears the offer and rows inside `LinkDevice` | decided by the agent |
| Age rotation skips a running switch, and skips a held hub on the relay only | decided by the agent; second half in Open decision 12 |
| The 7-day age applies only with an offering phone on the hub | decided by the agent, review round 1 |
| A build setting turns on the phone's offers, and so the whole phase | decided by the agent, review round 1; Open decision 1 |
| `relaystaging` build tag for a 10-minute epoch | controller's ruling, review round 1 |
| The reader transition: `relay_lapsed_at` as the durable signal, keys static after it | controller's ruling, review round 1; details in Open decision 17 |
| No Desktop change; a content-free log line per rotation | decided by the agent; CLI keys are Open decision 16 |
| No phone screen or text | decided by the agent; relay design §7 item 5 |

## Open decisions for the owner

**Approving the plan settles nothing below by silence.** Numbers 1–5 need an explicit answer each; the controller files them as separate questions before PR A. The rest carry a recommendation, and the owner may overturn any of them. Anything raised later goes into its own ask before that task's review.

### Needs an explicit answer

1. **When it turns on (timing, against ask #799's "after launch").**
   - **Option A, with launch.** Cost: launch waits for this phase's review and for the staging run, which waits for Phase 4's M1–M10, none yet run; launch carries new key code and a weekly republish whose real cost is unmeasured. The gain: the old-build path never exists, and §1's "middle" forward secrecy is real from day one, which matters given the relay's 30-day recovery.
   - **Option B, after launch, code landing dark.** PRs A–C merge when reviewed, with `WATCHTOWER_RELAY_KEY_ROTATION` empty. No phone offers, so hubs stay at 90 days and static, and launch does not wait on the staging run. A later release sets the value after the staging run and measurements pass. Cost: until then relay links have static keys, as ask #799 accepted. After the flip a phone not yet updated stays static (Open decision 10), but Task 9 is already in its build and Task 5 is on the hub, so it loses no uploads and no alert text. Launch still carries dark code that is reviewed but not run by users, though Task 4's keybox rule, Task 9's reseal and Task 13's lapse handling are live.
   - **Option C, a separate branch after launch.** No dark code in launch. Cost: launch phones lack Tasks 8 and 9, so on a mixed hub they can lose uploads weekly, and the branch must be kept up to date with a moving main.
   - **Earlier advice:** my message on ask #1051 advised leaving this until after launch. The first version of this plan recommended the opposite, because it saw only A and C, and C's old-build path is costly. **Recommended: B.** It follows that earlier advice and removes what made me doubt it. PR base stays as the brief says. If reviews are not done by launch, the PRs simply do not merge, and nothing waits.
2. **Where a timer rotation's keybox travels (contradicts a recorded decision).** The spec's Decisions say "Rotation keyboxes on the relay travel in the phone's mailbox inside `transport_switched` — approved in ask #799".
   - **Option A, the data zone, `keybox-<device>`.** Latest version only, not cut by the 14-day mailbox TTL, so a phone away a month still finds it. Sealed to its offer, so a recording of it is useless without that key. It stays on the relay until replaced.
   - **Option B, the mailbox, inside `transport_switched` with `target` = the current route** (the policy's `follow` already handles a newer epoch on the same route). Deleted after delivery, closer to §7's promise. But a phone away over 14 days loses it, and it can no longer write to the hub (a retired epoch's control is dropped), so **it needs a re-link or a data-zone fallback anyway**. Delivery then needs both paths.
   - **Recommended: A,** and the spec's Decision is read as covering switches only. If B, Tasks 3, 4 and 8 change and F7 needs a re-link screen.
3. **Frozen bytes (wire).** Protocol Decisions freeze the keybox and envelope bytes, changed only with owner approval. This adds JSON keys `relay_kx`, `previous_relay_kx`; `next_kx` on `epoch_ack`; a `wt/relay/v2/` derivation; and an HPKE recipient that is sometimes not `dev_kx`. The envelope header, the classes and every existing vector are unchanged. **Options:** approve; or refuse, and there is no ephemeral scheme, so this phase stops. **Recommended:** approve.
4. **What reaches iCloud users.** The spec names only two changes for free users; this phase must not silently add more.
   - **Option A, relay only.** The inert sidecar migration reaches everyone. Erasure runs only on epochs that began on the relay (`hub_epochs.on_relay`). The upload reseal runs only on a relay route or a link that has moved routes. iCloud behaves exactly as today, including today's rare loss of an upload sealed before a 90-day rotation.
   - **Option B, everywhere.** Erasure and the reseal for all, closing that rare loss, and amending protocol §7.7 for iCloud too. Their crypto and bytes still do not change.
   - **Recommended: A,** because the spec's promise is explicit and the loss is rare at 90 days. §7.7 is amended for relay links only.
5. **Who builds the hub half.** The relay client spec keeps Phase 5 to the phone and the Kit, the Go hub spec lists it out of scope, and no Go hub session runs (ask #1015). The phase does not work without it: Tasks 2–6 and half of 13. "Do it in this session" on ask #1051 answered G1–G4 and #1537, not this.
   - **Option A, this phase's session builds both,** as planned; the two specs are amended in Task 12.
   - **Option B, wait for a Go hub session;** Tasks 7–10 can land dark but nothing runs until it exists, and Task 11 waits.
   - **Recommended: A,** since hub and phone bytes change together and split reviews would miss the transitions.

### With a recommendation

6. **The scheme (wire and crypto).** Spec'd X25519 offers (this plan) versus a **symmetric key chain**: `K_chain[e+1] = HKDF(K_chain[e])`, old value erased, keybox AEAD-sealed under the chain. The chain drops Task 2's offers, the lost-ack path, the two-key state and about a third of the failure table, and it gives forward secrecy the same. It never heals: a thief who copies the chain once reads every later epoch. It also changes the frozen keybox class from HPKE to symmetric. **Recommended:** X25519, because §7.4 names it, healing against a passive thief is the part a stolen key most needs, and the envelope class stays. Also part of this ruling: `ikm` mixes in the static secret. **Refused** means re-planning before Task 1.
7. **The relay spec's sentence "the hub keeps its last ephemeral key until the device confirms the new one" (behaviour, contract text).** This plan's hub keeps none: it has the phone's public offer when it rotates, so it erases its own at once, and a phone away for several rotations keeps getting a fresh hub key against its last offer. What the sentence protects still holds: the phone is never locked out. **Recommended:** accept. The relay repository's text must then change, or contract and code differ: the controller sends the relay session this one-line text change for §7 item 5 before PR C, per ask #734. **Alternative:** keep the hub's key per phone until an ack, which protects nothing further and stores a private key for weeks.
8. **Weekly full republish (behaviour, cost, battery).** Every rotation wipes the hashes and re-sends the window, transcript assets included (at most 200 × 20 MiB, about 4 GiB at the absolute limit; the relay's limits are 5 GB per hub and 100 GB per phone per month). The real figure is unknown; "Measuring the cost" gives the method and thresholds. **Recommended:** ship dark, measure, turn on only on a pass. **Alternative on a fail:** reuse the already-uploaded asset (`K_asset` is unchanged by rotation, so reuse is safe), which needs a transport change and possibly relay work; not in this plan.
9. **A free phone's keybox on a relay hub (behaviour).** No keys in the relay data zone for a non-reader or a lapsed phone; today it has them. The phone sees no difference, because it cannot read that zone. An unknown reader list keeps keys, for availability at startup. **Limit:** a free phone's `transport_switched` at the switch to the relay still carries the first, static, relay epoch's keybox, in iCloud. **Recommended:** approve both.
10. **An old build on the relay (behaviour).** It stays static and its `dev_kx` keybox carries `K_data`, so a theft of that one phone reopens those epochs for all phones' data. **On top of that, the hub cannot fix its phone-side gaps:** a build without Tasks 8 and 9 on a 7-day hub can lose uploads weekly. Under Open decision 1's option B every launch build has those tasks, so only the weak link stays; under option C both are real; under option A this never arises. Options: keep serving it (**recommended**, with a count in the log), or refuse it on the relay with an update prompt, which is a new screen and a new refusal.
11. **Alert pushes in the acked epoch (behaviour).** A relay alert stays readable on a locked phone across a rotation. **Limit:** a phone not unlocked and merged for over 14 days gets the content-free notification until it is opened; that is today's behaviour for an unknown epoch. **Recommended:** approve and accept the limit.
12. **A held hub does not rotate on the relay (behaviour).** A paused or unvouched hub cannot publish, so the epoch waits and its calendar life stretches past 7 days with nothing sent under it. A CloudKit hub stays as it is. **Recommended:** approve.
13. **Two accepted limits with no screen (behaviour).** (a) A hub closed over 7 days right after a partial republish leaves those rows unreadable on the phone until it returns. (b) F17: a keybox naming a key the phone lost can only come from a hub sidecar restored from an old copy, since Keychain items are atomic and do not migrate. The phone logs it and goes stale until a re-link, with no text. **Recommended:** accept both, because (b) is unreachable in normal use and a screen for it is a screen nobody sees. **Alternative for (b):** a Settings → Macs line, needing a new frame and model text. Task 14's `keys` value would show it from the Mac's side.
14. **The first week is static (behaviour).** After a link, a switch or a renewal the first keybox goes to `dev_kx`, and the first ephemeral epoch arrives at the next rotation, at most 7 days later. **Alternative:** rotate as soon as every relay reader has offered, which costs a full republish right after each switch. **Recommended:** accept the week.
15. **The promise's real number (user-facing claim, none shipped).** §7.4 says "a leak reveals days, not 90 days". That is not a bound here: see "How much that is". **Recommended: no user-facing number at all.** If text is ever wanted: "Keys change about weekly while your Mac is running. A phone that was stolen can open what it still holds; that is normally about two weeks of data, and more if the phone had been offline a long time."
16. **Rotation visibility (behaviour).** As planned, a rotation shows only in a log line, so a stuck rotation or a phone that stayed static goes unnoticed. **Options:** (a) Task 14: additive `hub status` and `hub phones --json` keys plus a daily log line on a stuck epoch; (b) that plus a Desktop line in Settings → Mobile, needing a design-kit frame; (c) nothing. **Recommended: (a).** The owner can check with the installed binary, read-only, and nothing new is on screen.
17. **The reader transition's details (behaviour).** (a) `ReaderLost` runs a full `lapse` after two answered account reads with the phone in no slot; if nobody else pays, a desktop hub moves to iCloud, which is what G2 is checking. (b) `keyboxWaitCap` of 1 h: past it a record is skipped and, if it was a control, is lost to that token; a switch is still seen through the marker, and an echo is asked for again. (c) A static-keyed `hub_on_relay` is accepted on an ephemeral link, so someone holding an old `dev_kx` with write access to that mailbox can push the phone off the relay. **Recommended:** approve all three; (a) defers to G2 if it lands first.

**Contracts:** no `PROJ-*` change is proposed. `docs/inventory/` has no entry on epochs or rotation. PROJ-16's dated note ("every relay record is sealed") stays true. PROJ-21 (permission answers, `session_interrupt`) is read at Task 6: such an action can now reach Not delivered when its key is gone, which its "exactly once or told" meaning allows, and its guards do not change; if review reads it otherwise, it goes to the owner. Task 12 re-checks both. Guard `TestKeyring_RotatesAt90DaysOrSeqCap` stays unchanged: it runs on CloudKit, and the relay hub with no offer takes the same path. The amended, non-guard Kit test is `epoch_ack`'s "never for an epoch at or below", which gains the same-epoch-new-offer case in Task 8. If review reads that as a contract, it goes to the owner.
