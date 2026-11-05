# Relay client Phase 5 — 7-day key rotation with ephemeral X25519 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On relay links, the hub starts a new epoch every 7 days, each phone's pairwise keys for that epoch come from fresh X25519 keys on both sides, the keybox is sealed to the phone's ephemeral key instead of `dev_kx`, and old keys are erased. CloudKit links keep the 90-day static scheme byte for byte.

**Architecture:**

- **The phone offers, the hub consumes.** The phone holds at most two ephemeral keys per hub: `current` and one `offered`. It sends the offer's public key inside `epoch_ack`. At the next rotation the hub draws a fresh key for each phone that offered, derives that phone's two relay keys, stores them sealed, and erases its private key in the same transaction.
- **The keybox names what it used.** It is sealed to the newest offer the hub holds and says which hub and device public keys built each epoch's relay keys. The phone derives, stores the two keys, promotes the offer, and erases the older private key.
- **A static fallback per phone, per epoch.** No relay-key row for `(epoch, device)` means today's static derivation. This one rule covers CloudKit links, a phone's first week on the relay, an old build and an old hub.

**Tech Stack:** Go 1.26 (`internal/hub/{secure,identity,state,actions,link,switcher,alerts,wire,hubtest}`), Swift 5.10 language mode, CryptoKit (`WatchtowerKit/WatchtowerSync`), SwiftUI app wiring (`WatchtowerMobile`), goose sidecar migrations.

**Spec:** `docs/superpowers/specs/2026-10-29-relay-client-design.md` §1 ("At launch, relay links keep today's key scheme"), §9 (switch and epochs), §13 row 5. Relay design in the relay repository at `bcca870`: `docs/superpowers/specs/2026-10-28-relay-design.md` §7 items 1–5, §4.2 item 6, §9 item 7; `sim/README.md` rules 13 and 14. Protocol: `docs/superpowers/specs/2026-10-31-hub-phone-protocol-design.md` §4.2, §4.3, §5.4, §7.6, §7.7. Go hub: `docs/superpowers/specs/2026-10-31-go-hub-design.md` §3 (it listed this as out of scope; ask #1051 brings the hub half here). E2E research: `docs/superpowers/specs/2026-10-12-mobile-e2e-encryption-research.md` §2.2–§2.3.

## Read this first: what the recon found

1. **The relay at `bcca870` lacks nothing.** Records stay opaque, the keybox overwrites its record in the data zone, and `epoch_ack` is an ordinary sealed mailbox record. No relay session work is needed (ask #734 is not triggered).
2. **The phase cannot usefully be split into "cadence first, keys later".** With a 7-day cadence and static keys, a stolen `dev_kx` plus recorded keyboxes still opens every epoch, and static pairwise keys still open every recorded mailbox record. Only the two together deliver what §7.4 promises. A genuinely smaller alternative exists: a symmetric key chain with no ephemeral keys. It is in Open decision 1, recommended against.
3. **Shorter epochs turn four rare paths into weekly ones.** None of these is a problem at 90 days. Each has a task:
   - **Recording uploads can be lost.** A recording is sealed once and every send repeats those bytes (protocol §7.7), and `RetireIfDone` can end an epoch at once. An upload sealed in that epoch is then dropped unanswered, forever. Task 9.
   - **A locked phone's alerts go blank.** A relay `alert_push` is sealed in the current epoch, but the extension's key copy updates only after an unlock. Task 5.
   - **The phone's mailbox feed can jam.** Today the phone derives a relay key for any epoch. With stored keys, a missing key throws `keysUnavailable`, and the feed replays that batch forever. Task 8.
   - **Every rotation re-uploads the whole window, transcript assets included.** That is at most 200 transcripts of at most 20 MiB each, weekly. Open decision 5, measured in Task 6.
4. **A free phone linked to a relay hub would defeat the whole scheme.** Today every linked phone's keybox goes into the relay data zone, sealed to its static `dev_kx`. A free phone never reads it, yet recording it and later stealing that phone's `dev_kx` opens `K_data` of every relay epoch. Task 4 takes the keys out (Open decision 7).
5. **The hub never erases retired epoch keys.** `hub_epochs.sealed_keys` stays forever; "retired" only filters reads. §7.4 says old epochs are erased. Task 3 does it (Open decision 9).
6. **The relay's own retention is weaker than the design this threat model came from.** Relay design §7 assumes 1-day backups; the Cloudflare design §9 has Durable Object point-in-time recovery for 30 days. For 30 days, whoever controls that account may be able to restore overwritten ciphertext from the objects it covers. This raises the value of the phase, and it is the honest reason to do it.
7. **Timing conflict.** The spec says "after launch"; the brief's PR base is `feature/relay-client-next`, which is the launch branch. Merged there, Phase 5 ships with launch. That is Open decision 3. The owner should rule on it first.

## The threat, honestly

**What it addresses.** An attacker who has recorded ciphertext from the relay (the operator, a breach of the Cloudflare account, or the 30-day recovery above) and who later extracts one phone's keys. Today that yields up to 90 days of `K_data` and `K_alert`, plus every recorded action and echo of that link for its whole life. After this phase it yields the epochs the phone still holds: **up to about 14 days, not 7**. That is the current epoch (at most 7 days old) plus the previous one, kept 7 more days (ask #843). If the thief stays passive, the next rotation with a fresh offer heals the link, because the new keys depend on a private key the thief never saw.

**What it does not fix:**

- A thief with a live, unlocked phone reads the replica directly. Keys are not the barrier there.
- An **active** thief holding current keys can send their own `next_kx` and stay in the link until the owner removes the phone. Only a re-link or Remove ends that.
- **Mac compromise.** The hub holds plaintext. Hub key erasure is hygiene, not a barrier, and `hub_kx`, `hub_sig` and the wrap key stay.
- **`K_meta` does not rotate** (protocol §4.2), so record names stay linkable over time. Sizes, timing, ids and APNs tokens stay visible to the relay (relay design §7).
- **It is not a ratchet.** Inside an epoch one key seals everything, and a phone that stays away reuses its last offer across rotations.
- **The first week on the relay is static** (Open decision 13): after a link or a switch, the first keybox must go to `dev_kx`.
- **A static phone on the same hub is the weakest link** for `K_data` while it reads the zone (Open decision 8).
- iCloud links get none of this, by decision.

## Global Constraints

- `RelayRotationAge` = 7 days on the relay; `RotationAge` = 90 days and `RotationSeqCap` = 2^28 stay. The cadence is chosen by the hub's current transport (relay design §7.4: "a hub has one scheme").
- Retention stays 7 days on both sides (`PreviousEpochGrace`, `previousEpochGrace`, ask #843) and at most 8 epochs on the phone (`maxEpochs`).
- CloudKit links: same bytes, same recipient (`dev_kx`), same `wt/relay/v1/` derivation, no offer ever sent. Guard: `TestKeyring_RotatesAt90DaysOrSeqCap` stays unchanged.
- Existing frozen vectors do not change. New vectors are additive (`kdf.json`, `go-sealed.json`, `hub_contract_cases.json`).
- Sim rule 13's byte-for-byte switch resend, and the `action_seq` that never resets, stay.
- Ephemeral private keys live only in the `hub.<id>` Keychain item (`whenUnlocked`, `ThisDeviceOnly`). They and the derived relay keys never reach the `afterFirstUnlock` alert material or any log.
- **No new phone screen, no new user text, no Desktop change** (see "Phone screens").
- Go hub ↔ Kit bytes change together: `wire.KeyboxKeys`/`KeyboxKeys`, `wire.Control`/`ControlPayload`, `secure.EphemeralRelayKey`/`KeyDerivation.ephemeralRelayKey`.
- Agent-run rules (the relay launch `common.md`): TDD with RED and GREEN logs, inner loop only, foreground only, no repo-built CLI on live data, no live data in the repo, guard files untouched, a stop-and-report on any contract, wire or behaviour change beyond the rulings below.

### What a Release build gets while Relay stays dark

With an empty `WATCHTOWER_RELAY_ORIGIN` no phone is on a relay route, so no offer is sent and no ephemeral path runs. Three things do reach CloudKit users, all covered by Open decisions:

- the sidecar migration;
- the erasure of retired epoch keys on the Go hub (Open decision 9);
- the recording upload reseal when a row's envelope is older than the current epoch (Open decision 6).

## Review Focus

1. **A phone away for three or more rotations returns with an old outbox and an old echo.** It must recover with no owner action and no permanent feed jam. Tests: Task 8 `testARelayRecordInAGoneEpochIsDroppedNotReplayed`, Task 11 step 4.
2. **Rotation hits a recording that is sealed but not yet sent.** The audio must arrive once. Test: Task 9 `testARowSealedInAnOlderEpochIsResealedBeforeSending`.
3. **Two rotation triggers overlap: an age rotation falls inside a transport switch.** The `transport_switched` epoch and the keybox must match. Test: Task 3 `TestRotateIfDueSkipsWhileASwitchIsRunning`.
4. **A phone on iOS is locked across the rotation and an alert arrives.** The owner still reads the alert's text. Test: Task 5 `TestAlertPushSealedInAnEpochThePhoneHolds`.
5. **A switch to iCloud with a free phone linked.** The free phone must still get its keybox, though it got no keys on the relay. Test: Task 4 `TestSwitchToCloudKitGivesAFreePhoneItsKeys`.

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
| Absent, epoch above the newest held | yes | `keysUnavailable`: the batch replays when the keybox arrives |
| Absent, epoch at or below the newest held | yes | `epochKeysGone`: the record is dropped, the feed moves on |

**Hub-side sealing:** for a phone with `kx_offer_epoch > 0`, echoes and controls are sealed in its acked epoch while the hub still retains it, else in the current one. A phone that never offered gets today's current-epoch sealing.

## Mixed fleets

| Case | What happens | Test |
|---|---|---|
| Hub on the relay, one paying phone, one free phone | The cadence is 7 days. The paying phone goes ephemeral. The free phone is not a reader: its relay data-zone keybox carries the grant and **no keys**. It reads nothing there anyway and gets `hub_on_relay`. It keeps its static link. | `TestFreePhoneKeyboxOnRelayHasNoKeys` |
| That hub switches to iCloud | New epoch, all offers cleared in the rotation's transaction, every keybox to `dev_kx` with keys. `transport_switched` uses `KeyboxesAll`, so the free phone gets its keys. Cadence back to 90 days. | `TestSwitchToCloudKitGivesAFreePhoneItsKeys` |
| Hub on the relay, an old phone build on the relay route | It never offers, so every epoch is static for it and its keybox goes to `dev_kx` **with keys**. It works. It is the weakest link for `K_data` (Open decision 8). The hub logs a count per rotation. | `TestOldBuildPhoneStaysStaticAcrossRotations` |
| A new phone, an old hub | The hub ignores `next_kx` (plain `encoding/json`; no `DisallowUnknownFields` under `wire` or `actions`). No `relay_kx` arrives, so the phone stays static. One unused offer sits in the Keychain. | Kit `testAHubThatNeverConsumesStaysStatic`, Go `TestEpochAckOfferUnknownToOlderHubDecodes` (decode pin) |
| An old phone build on iCloud | Nothing changes: 90 days, static. | Existing tests plus the unchanged vectors |
| Switch to iCloud mid-rotation (offer in flight) | The offer read after the switch's transaction is dropped because the transport is no longer relay. The phone clears its ephemeral state when it follows. A keybox naming no `relay_kx` means static. | `TestOfferReadAfterSwitchAwayIsDropped`, `testFollowingToICloudClearsEphemeralState` |
| Switch to the relay | New epoch, no offers yet, so it is static. The first offer comes with the ack after the follow. First ephemeral epoch at the next rotation, at most 7 days later (Open decision 13). | Task 11 step 2 |
| Relay, iCloud and back within a week | Each switch starts an epoch; old relay rows stay until retention ends; the phone's `maxEpochs` of 8 holds them. A `dev_kx` keybox omits `previous*` when that epoch has a relay-key row for this phone. | `TestStaticKeyboxOmitsAnEphemeralPreviousEpoch` |
| A re-link (the phone reinstalled, the Keychain survives) | The hub clears the phone's offer and relay-key rows with the new nonce; the phone's fresh link has no ephemeral state. | `TestRelinkClearsOfferAndRelayKeys` |

**Why a free phone's switch notice still carries keys:** `transport_switched` toward the relay goes to every linked phone with the first relay epoch's keybox. That hands one static week's `K_data` to the free phone's iCloud mailbox. It is a v1 limit, listed in Open decision 7.

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
| F17 | Keybox names a key the phone no longer has (only a restored hub sidecar reaches this) | Merge refused, link kept, logged once, nothing wiped. Stale data until re-link (Open decision 12) | `testAKeyboxNamingAnUnknownKeyIsNotMerged` | 7 |
| F18 | Age rotation inside a running switch | Skipped; the next cycle decides | `TestRotateIfDueSkipsWhileASwitchIsRunning` | 3 |
| F19 | Unlink during a rotation cycle | Serialised by the transaction; the removed phone's rows go with it; no keybox keys for it | `TestUnlinkRemovesOfferAndRelayKeys` | 3 |
| F20 | Recording sealed in an epoch the hub retired | Resealed before each send; a raise re-arms a stuck row; if its key is gone it is sealed afresh from the plain file | Task 9's tests | 9 |
| F21 | Data-zone quota refuses the keybox | Existing quota error on the Mac. Echoes stay readable while the acked epoch is retained; after that the feed waits and the phone's actions wait | `TestEchoSealedInAckedEpochWhileKeyboxIsStuck` | 3 |
| F22 | Hub closed for over 7 days right after a partial republish | Phone drops the old key on schedule; rows not yet republished stay unreadable until the hub returns and finishes (Open decision 12) | `testRowsInAnErasedEpochStayPendingUntilRepublished` | 7 |
| F23 | Phone linked while a rotation commits | Static until its first offer | `TestLinkDuringRotationStartsStatic` | 3 |

## Writers and races

| Data | Writers | Who wins |
|---|---|---|
| `hub_epochs`, `epoch_relay_keys` | The daemon's housekeeping (age), its switcher (switch), its link center (unlink), or the CLI under `hub.lock` when no hub runs | One holder of `hub.lock`; `BEGIN IMMEDIATE` serialises the daemon's goroutines. The later transaction builds on the committed newest epoch |
| `devices.kx_offer`, `kx_offer_epoch` | Processor (`epoch_ack`), switcher (clear on leaving the relay), link center (relink, unlink) | Highest ack epoch; a clear beats any offer read afterwards, because the ack's transaction reads `hub_meta.transport` and the switcher's record state |
| `HubLinkKeys` (`hub.<id>`) | Link flow's merge, the session's offer, the follower's clear, re-link, unlink | New `PhoneKeyStore.updateHubLink` under the store's lock, so no read-modify-write is lost. **It returns nil and writes nothing when the link is gone**, so an unlink is never undone |
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

If review rules that F17 needs words, that is a new frame and a new task (Open decision 12).

## Lanes

```
Task 1 ─┬─ Task 2 ─ Task 3 ─┬─ Task 4 ─┐
        │                   ├─ Task 5 ─┼─ Task 6 ─┐
        │                   └──────────┘          ├─ Task 11 ─ Task 12
        └─ Task 7 ─┬─ Task 8 ─┬─ Task 10 ─────────┘
                   └─ Task 9 ─┘
```

Go and Kit are parallel lanes after Task 1. Each Swift lane gets its own worktree and simulator.

**PRs into `feature/relay-client-next`:** A = Tasks 1–6 (safe alone: no phone offers yet, so every path is static). B = Tasks 7–10. C = Tasks 11–12.

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

**Depends on:** Task 1

**Files:**
- Create: `internal/hub/state/migrations/00014_ephemeral_kx.sql`, `internal/hub/state/relaykeys.go`
- Modify: `internal/hub/state/devices.go` (`deviceColumns`, scan), `internal/hub/state/link.go`, `internal/hub/actions/control.go` (`epochAck`)
- Test: `internal/hub/state/state_test.go`, `internal/hub/state/columns_test.go`, `internal/hub/actions/control_test.go`, `internal/hub/state/swift_file_test.go` (a Swift-era file still migrates)

**Interfaces:**
- Produces, migration: `ALTER TABLE devices ADD COLUMN kx_offer BLOB`; `ADD COLUMN kx_offer_epoch INTEGER NOT NULL DEFAULT 0`; `CREATE TABLE epoch_relay_keys (epoch INTEGER NOT NULL, device_id TEXT NOT NULL COLLATE NOCASE, hub_pub BLOB NOT NULL, device_pub BLOB NOT NULL, sealed_keys BLOB NOT NULL, PRIMARY KEY (epoch, device_id))`.
- Produces, state: `Device.KXOffer []byte`, `Device.KXOfferEpoch uint32`; `SetKXOffer(tx, device string, pub []byte, epoch uint32) error` (writes only when `epoch >= kx_offer_epoch`); `ClearKXOffers(tx) error`; `ClearDeviceKX(tx, device string) error` (offer and relay-key rows); `InsertEpochRelayKeys(tx, EpochRelayKeys) error`; `(*Store).EpochRelayKeys(epoch uint32, device string) (EpochRelayKeys, bool, error)`; `EraseEpoch(tx, epoch uint32) error` (deletes its relay-key rows, sets `sealed_keys = x''`).

- [ ] **Step 1: Failing tests.** `TestOlderAckDoesNotReplaceANewerOffer`, `TestBadOfferIsIgnoredAckStillCounted` (a short key, a non-curve value, an all-zero point), `TestOfferReadAfterSwitchAwayIsDropped` (`hub_meta.transport` is `cloudkit`: the ack counts, the offer does not), `TestEpochAckStoresOffer`, `TestRelinkClearsOfferAndRelayKeys` (`LinkDevice` with a new nonce), `TestEraseEpochLeavesTheRowWithoutKeys`.
- [ ] **Step 2: Run** `go test ./internal/hub/state ./internal/hub/actions -run 'Offer|Ack|Relink|EraseEpoch'`. Expected: FAIL.
- [ ] **Step 3: Implement.** `epochAck` validates inside the processor, before `decide`: `ecdh.X25519().NewPublicKey` and a non-zero test exchange. In `decide`'s transaction it reads `MetaTransport`, calls `AckEpoch`, and calls `SetKXOffer` only on `relay`. A bad offer logs its class, never bytes. Relink: `LinkDevice`'s caller path clears when the nonce changes; put the clear in `LinkDevice` so no path misses it.
- [ ] **Step 4: Run** Step 2 and `go test ./internal/hub/state`. Expected: PASS.
- [ ] **Step 5: Commit.** `feat: hub stores phone key offers and per-epoch relay keys (#1248)`

### Task 3: Keyring: cadence, ephemeral rotation, lookup, recipient, erasure, echo sealing

**Depends on:** Task 2

**Files:**
- Modify: `internal/hub/identity/keyring.go`, `internal/hub/runtime.go` (`housekeeping`), `internal/hub/switcher/announce.go` (`rotate`), `internal/hub/secure/record.go` (no new key logic; echoes use `InEpoch`), `internal/hub/actions/echo.go` and `control.go` (the sealer choice), `internal/hub/state/state.go` (`secure_delete`)
- Modify: `internal/hub/hubtest/phone.go` (a twin phone with `current` and `offered`, `relay_kx` read, stored pairs)
- Test: `internal/hub/identity/keyring_test.go`, `internal/hub/runtime_test.go`, `internal/hub/actions/epoch_test.go`

**Interfaces:**
- Consumes: Task 1's `secure.EphemeralRelayKey`, Task 2's state functions.
- Produces:
  - `identity.RelayRotationAge = 7 * 24 * time.Hour`
  - `(*Keyring).RotateToward(r Reason, onRelay bool, also func(*sql.Tx) error) error` (`RotateWith` reads `MetaTransport` and calls it; the switcher passes the target)
  - `(*Keyring).RotateIfDue(also func(*sql.Tx) error) (bool, error)`
  - `(*Keyring).EraseExpired() error`
  - `(*Keyring).PhoneEpoch(dev state.Device) (uint32, error)`: the acked epoch while retained if `KXOfferEpoch > 0`, else 0 meaning current
  - `(*Keyring).KeyboxKeysFor(device secure.ID) (wire.KeyboxKeys, error)`, replacing the shared `KeyboxKeys()`
  - `switcher.RotationBlocked(tx *sql.Tx) (bool, error)`: true while a switch record exists (over `recordTx`); the runtime's `also` uses it, since `identity` cannot import `switcher`

- [ ] **Step 1: Failing tests:**
  - `TestKeyring_RotatesAt7DaysOnRelay`
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
  - **`rotationDue`** picks the age by `MetaTransport`.
  - **`RotateToward`:** in the transaction, after `also` and after inserting the epoch: when `onRelay`, for each `devices` row with an offer draw `ecdh.X25519().GenerateKey`, derive, seal, insert; when not `onRelay`, `ClearKXOffers`. Log `epoch N begun (reason): k ephemeral, m static`, numbers only.
  - **`RelayKey`:** the sealed row if there is one, else today's derivation; cache as today, dropped by `EraseExpired`.
  - **`KeyboxRecipient`:** the offer for a linked row with `kx_offer`, else today's order.
  - **`housekeeping`:** `RotateIfDue` gets an `also` that returns `ErrSkipRotation` when the switch record is in progress (`switcher.RotationBlocked`), and the call is skipped when on the relay and `isHeld()`. After `RetireOld`, `EraseExpired`, then a best-effort `wal_checkpoint(TRUNCATE)`.
  - **Echoes and controls** for a phone use `Sealer.InEpoch(PhoneEpoch(dev))` when non-zero.
  - **`state.Open`** sets `secure_delete = ON`.
- [ ] **Step 4: Run** Step 2's command, then `go test ./internal/hub/identity ./internal/hub/actions ./internal/hub/switcher ./internal/hub/link`. Expected: PASS.
- [ ] **Step 5: Commit.** `feat: hub rotates relay epochs weekly with ephemeral keys (#1248)`

### Task 4: Per-phone keyboxes and the free phone

**Depends on:** Task 3

**Files:**
- Modify: `internal/hub/link/grants.go`, `internal/hub/link/center.go` (config), `internal/hub/switcher/announce.go`, `internal/hub/switcher/accept.go`, `internal/hub/runtime.go` (the wiring)
- Test: `internal/hub/link/center_test.go`, `internal/hub/switcher/switcher_test.go`

**Interfaces:**
- Consumes: `KeyboxKeysFor`.
- Produces: `Center.Keyboxes()` (what the data zone carries, applying the rule) and `Center.KeyboxesAll()` (always keys for a linked phone); config `KeysInZone func(device string) bool`, where nil or an unknown reader list means true. The runtime sets it to "not on the relay, or a reader of the data zone" over `Transport.Readers()`.

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
- Consumes: `Keyring.PhoneEpoch`, `Sealer.InEpoch`.
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
- Produces: tests, plus a content-free log line at the end of the first full republish after a rotation: `hub: rotation republish: N records, B asset bytes, D s`. This line is Open decision 5's measurement.

- [ ] **Step 1: Failing tests.** `TestRuntime_RestartAfterRotationRepublishesOnce`. `TestRotationWhileRelayDownPublishesOnReturn`. `TestRuntime_ThreeRotationsTwoPhones`: one offered, one static, each opens slices, echoes and controls in every epoch. `TestRotationRepublishLogsCounts`, with no names or bytes in the line (`logcanary`-style check).
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
  - `HubLinkKeys.clearingEphemeral() -> HubLinkKeys`
  - `PhoneKeyStore.updateHubLink(_ hubID: String, _ change: (HubLinkKeys) throws -> HubLinkKeys) throws -> HubLinkKeys?`
  - `SecureTransportError.epochKeysGone`
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
- [ ] **Step 3: Implement.** The signature is verified once, before any HPKE attempt. `openRelay` maps `epochKeysGone` to `.unopenable("epochGone")` in the phone branch only. The feed hands that outcome's wire name to the outbox. `queueEpochAck` puts `nextKX` (base64url) on the payload. An ack sealed with the old epoch's stored keys is fine: the hub retains it.
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
- [ ] **Step 3: Implement** at the point `saveSealed` reads the stored envelope: parse the header epoch, compare with `currentEpoch()`, reseal, persist before saving. The hub's window for the old epoch is not consulted: the phone cannot know it.
- [ ] **Step 4: Run** Step 2. Expected: PASS. `make lint-swift`.
- [ ] **Step 5: Commit.** `fix: a recording sealed before a rotation is resealed, not lost (#1248)`

### Task 10: App wiring

**Depends on:** Tasks 8, 9

**Files:**
- Modify: `WatchtowerMobile/Sources/Features/Onboarding/LinkingViewModel.swift` (`mergeKeys`), `WatchtowerMobile/Sources/App/Hubs/HubSession.swift` (`acknowledgeNewestEpoch`, `keysMerged`), `WatchtowerMobile/Sources/App/Hubs/TransportFollower.swift`, `WatchtowerMobile/Sources/App/AppRoot.swift` (`mergeSwitchKeys`, the host seam)
- Test: `WatchtowerMobile/Tests/LinkingViewModelTests.swift`, `TransportFollowerWiringTests.swift`, a new `EphemeralRotationWiringTests.swift`

**Interfaces:**
- Consumes: Tasks 7–9.
- Produces: no new public surface. `mergeKeys` goes through `keys.updateHubLink` and `merging`; `.unknownEphemeral` logs once and returns false.

- [ ] **Step 1: Failing tests:**
  - `testARelayRoutePhoneOffersOnEveryRaise`
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
- [ ] **Step 3: Implement.** `acknowledgeNewestEpoch`: on route `.relay`, `updateHubLink { $0.withOffer() }` first (the private key is saved before any ack exists), then `enqueueEpochAck(epoch:nextKX:)`; on any other route `nextKX: nil`. `keysMerged` calls `uploader.epochRaised()` on a raise. The guard files `PermissionAllowRuleTests`, `PermissionCardTests` and `SessionInputWiringTests` stay untouched.
- [ ] **Step 4: Run** Step 2 and `make mobile-test SIM='<yours>' MOBILE_FILTER='LinkingViewModelTests|RelayLinkingTests'`. Expected: PASS. `make lint-swift`.
- [ ] **Step 5: Commit.** `feat: the phone runs relay key rotation (#1248)`

---

## Together

### Task 11: Kit ↔ Go hub interop on the stand

**Depends on:** Tasks 6, 10

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
- [ ] **Step 2: Run** `make relay-interop-kit-hub RELAY=<relay checkout>`. Expected: FAIL at the first new assertion until the steps above are wired, then PASS.
- [ ] **Step 3: Run** `go test -tags interop ./internal/hub -run TestInterop_KitPhone` and `make kit-test FILTER=KitGoHubInteropTests` if the script's CI mode needs them separately. Expected: PASS.
- [ ] **Step 4: Commit.** `test: Kit and Go hub rotate relay keys on the stand (#1248)`

### Task 12: Docs and the gate

**Depends on:** Task 11

**Files:**
- Modify: `docs/features/relay-client.md` (a "Phase 5" section, the Epochs section, v1 limits), `docs/features/go-hub.md`, `docs/features/mobile-companion.md`, `docs/superpowers/specs/2026-10-31-hub-phone-protocol-design.md` (§4.2 epochs, Decisions, §11), `docs/superpowers/specs/2026-10-29-relay-client-design.md` (§1 and §13 row 5 per Open decision 3, Decisions), `docs/superpowers/specs/2026-10-31-go-hub-design.md` (§3's non-goal), this plan's Decisions
- Check: `grep -rn -i 'rotat\|epoch\|every 90' docs/guide` (no page states the key schedule today, so no guide change is expected; a hit means a same-PR fix under `docs/guide/WRITING.md`), `docs/inventory/workbench.md` PROJ-16's note (it stays true: every relay record is sealed; no PROJ text changes)

**Interfaces:** none.

- [ ] **Step 1:** Write the docs, including the honest threat text and the 14-day figure.
- [ ] **Step 2: Gate (controller).** `make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`, `make mobile-test SIM='<yours>'`, `make relay-interop-kit-hub RELAY=<relay checkout>`. Expected: exit 0 for each; a known flake is named, not skipped.
- [ ] **Step 3: Manual check for the PR body, not faked.** On staging, one phone and one desktop hub with the clock unmoved is a week's wait, so the check is the moved-clock interop above plus one real device link on staging at an 8-day-old hub. Note the rotation-republish log line's three numbers in the PR for Open decision 5.
- [ ] **Step 4: Commit.** `docs: relay key rotation (#1248)`

---

## Decisions

| Decision | Source |
|---|---|
| The plan covers the phone, the Kit and the Go hub; PR base `feature/relay-client-next` | ask #1051 |
| Relay links rotate; CloudKit keeps 90 days and static keys | relay design §7 item 4; relay client spec §1, ask #799 |
| At launch static keys were accepted; this phase replaces them | ask #799 (timing is Open decision 3) |
| A hub has one scheme, by its current transport; every switch starts an epoch | relay design §3, §7.4 (ask #702 there); relay client spec §9 |
| Retention 7 days, at most 8 epochs, on both sides; not rule 14's 14 days | ask #843; Phase 3 Owner approval 4, ask #904 |
| `epoch_ack` to ordered hubs; reseal with the same `action_seq` on `resend_from` | Phase 3 Owner approval 4 (R9, R10), ask #904 |
| Switch keyboxes stay inside `transport_switched`; rotation keyboxes stay in the data zone (latest version, not cut by the mailbox TTL, and any later keybox replaces it) | first half ask #799; second half decided by the agent |
| `K_meta`, `hub_sig`, `hub_kx`, `dev_kx`, `dev_sig` do not rotate | protocol §4.2; decided by the agent for this phase |
| Rotation is automatic with no owner action | relay design §7 item 5 |
| No relay change is needed | decided by the agent after reading the relay at `bcca870`; ask #734 not triggered |
| Offer on `epoch_ack`, no new control kind, no grant capability field | decided by the agent |
| At most two ephemeral keys per hub on the phone | decided by the agent |
| A static fallback decided by the row's presence, per `(epoch, device)` | decided by the agent |
| The hub draws a per-phone ephemeral and never stores it | decided by the agent; see Open decision 2 |
| Sealed relay keys in the sidecar under the AAD `wt/hub-epoch-relay/v1` | decided by the agent |
| `PhoneKeyStore.updateHubLink` serialises all writers | decided by the agent |
| A re-link clears the offer and rows inside `LinkDevice` | decided by the agent |
| Age rotation skips a running switch, and skips a held hub on the relay only | decided by the agent; second half in Open decision 11 |
| No CLI verb, no JSON key, no Desktop change; a content-free log line per rotation | decided by the agent |
| No phone screen or text | decided by the agent; relay design §7 item 5 |

## Open decisions for the owner

Each is a proposal with a recommended option. Approving the plan accepts each recommendation; a comment overrides it. Anything raised later goes into its own ask before that task's review.

1. **The scheme (wire and crypto).** Spec'd X25519 offers (this plan) versus a **symmetric key chain**: `K_chain[e+1] = HKDF(K_chain[e])`, old value erased, keybox AEAD-sealed under the chain. The chain drops Task 2's offers, the lost-ack path, the two-key state and about a third of the failure table, and it gives forward secrecy the same. It never heals: a thief who copies the chain once reads every later epoch. It also changes the frozen keybox class from HPKE to symmetric. **Recommended:** X25519, because §7.4 names it, healing against a passive thief is the part a stolen key most needs, and the envelope class stays. Also part of this ruling: `ikm` mixes in the static secret. **Refused** means re-planning before Task 1.
2. **The spec's sentence "the hub keeps its last ephemeral key until the device confirms the new one" (behaviour, spec text).** This plan's hub keeps none: it has the phone's public offer when it rotates, so it erases its own at once, and a phone away for several rotations keeps getting a fresh hub key against its last offer. What the sentence protects still holds: the phone is never locked out. **Recommended:** accept and amend relay design §7 item 5's reading in our notes. The relay repository's text goes through the relay session.
3. **When it ships (behaviour, ask #799 narrowed the other way).** The spec says after launch; the PR base is the launch branch. **Recommended: merge it there, so launch carries it.** No relay phone without rotation ever exists, so Open decision 8 stays theoretical, and §1's "middle" forward secrecy is real from day one. The cost: more key code in the launch's risk, and launch waits on this phase's review. **Alternative:** a separate branch off `feature/relay-client-next` merged after launch; nothing else in this plan changes, Open decision 8 becomes real, and the spec stays as it is. Tell the controller before PR A.
4. **Frozen bytes (wire).** Protocol Decisions freeze the keybox and envelope bytes, changed only with owner approval. This adds: JSON keys `relay_kx`, `previous_relay_kx`; `next_kx` on `epoch_ack`; a `wt/relay/v2/` derivation; and an HPKE recipient that is sometimes not `dev_kx`. The envelope header, the classes and every existing vector are unchanged. **Recommended:** approve.
5. **Weekly full republish (behaviour, cost).** Every rotation wipes the hashes and re-sends the window, transcript assets included (at most 200 × 20 MiB, about 4 GiB at the absolute limit, far less in usual use; the relay's limits are 5 GB per hub and 100 GB per phone per month). The phone pulls the re-sent records again. Nothing measures the real figure yet: Task 6's log line will. **Recommended:** ship as is, read the numbers in PR A's staging run, and open a follow-up only if a typical week exceeds 500 MB. **Alternative:** reuse the already-uploaded asset (`K_asset` is unchanged by rotation, so reuse is safe), which needs a transport change and possibly relay work. Not in this plan.
6. **Recording reseal (contract text, reaches CloudKit).** Protocol §7.7 says a retry reuses the same name and bytes. Without this change a recording sealed before a rotation can be lost. The audio's sealed file stays the same; only the record's envelope changes, and only when older than the current epoch, on both transports. **Recommended:** approve and amend §7.7.
7. **A free phone's keybox on a relay hub (behaviour).** No keys in the relay data zone for a non-reader; today it has them. The phone sees no difference, because it cannot read that zone. An unknown reader list keeps keys, for availability at startup. **Limit:** a free phone's `transport_switched` at the switch to the relay still carries the first, static, relay epoch's keybox, in iCloud. **Recommended:** approve both.
8. **An old build on the relay (behaviour).** It stays static and its `dev_kx` keybox carries `K_data`, so a theft of that one phone reopens those epochs for all phones' data. Options: keep serving it (**recommended**, with a count in the log), or refuse it on the relay with an update prompt, which is a new screen and a new refusal. Theoretical if Open decision 3 is taken.
9. **Erasing retired keys on the hub (behaviour, reaches CloudKit).** `sealed_keys` is blanked at retention's end, on every transport, with `secure_delete` on and a best-effort checkpoint. **Recommended:** approve. CloudKit's crypto and bytes do not change, and no reader needs a retired epoch's keys past its retention. **Alternative:** relay only, which needs a per-epoch transport mark.
10. **Alert pushes in the acked epoch (behaviour).** A relay alert stays readable on a locked phone across a rotation. **Limit:** a phone not unlocked and merged for over 14 days gets the content-free notification until it is opened; that is today's behaviour for an unknown epoch. **Recommended:** approve and accept the limit.
11. **A held hub does not rotate on the relay (behaviour).** A paused or unvouched hub cannot publish, so the epoch waits and the key lifetime stretches past 7 days with nothing sent under it. A CloudKit hub stays as it is. **Recommended:** approve.
12. **Two accepted limits with no screen (behaviour).** (a) A hub closed over 7 days right after a partial republish leaves those rows unreadable on the phone until it returns. (b) A keybox naming a key the phone lost can only come from a hub sidecar restored from an old copy, since Keychain items are atomic and do not migrate. The phone logs it and goes stale until a re-link, with no text. **Recommended:** accept both. **Alternative for (b):** a Settings → Macs line, needing a new frame and model text.
13. **The first week is static (behaviour).** After a link or a switch the first keybox goes to `dev_kx`, and the first ephemeral epoch arrives at the next rotation, at most 7 days later. **Alternative:** rotate as soon as every relay reader has offered, which costs a full republish right after each switch. **Recommended:** accept the week.
14. **The promise's real number (user-facing claim, none shipped).** §7.4 says "days, not 90"; the plan's figure is up to about 14 days. Any future guide or marketing text must use that. **Recommended:** keep 7-day retention (ask #843) and say "about two weeks at most".

**Contracts:** no `PROJ-*` change is proposed. `docs/inventory/` has no entry on epochs or rotation; PROJ-16's dated note ("every relay record is sealed") stays true. Task 12 re-checks it. Guard `TestKeyring_RotatesAt90DaysOrSeqCap` stays unchanged. The amended, non-guard Kit test is `epoch_ack`'s "never for an epoch at or below", which gains the same-epoch-new-offer case in Task 8. If review reads that as a contract, it goes to the owner.
