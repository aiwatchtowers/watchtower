# Relay client Phase 5 — 7-day key rotation with ephemeral X25519 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On relay links, the hub starts a new epoch every 7 days, each phone's pairwise keys for that epoch come from fresh X25519 keys on both sides, the keybox is sealed to the phone's ephemeral key instead of `dev_kx`, and old keys are erased. CloudKit links keep the 90-day static scheme byte for byte.

**Architecture:**

- **The phone offers, the hub consumes.** The phone holds at most two ephemeral keys per hub: `current` and one `offered`. It sends the offer's public key inside `epoch_ack`. At the next rotation the hub draws a fresh key for each phone that offered, derives that phone's two relay keys, stores them sealed, and erases its private key in the same transaction.
- **The keybox names what it used.** It is sealed to the newest offer the hub holds and says which hub and device public keys built each epoch's relay keys. The phone derives, stores the two keys, promotes the offer, and erases the older private key.
- **A static fallback per phone, per epoch.** No relay-key row for `(epoch, device)` means today's static derivation. This one rule covers CloudKit links, a phone's first week on the relay, and a phone on this branch before the hub half lands.

**Tech Stack:** Go 1.26 (`internal/hub/{secure,identity,state,actions,link,switcher,alerts,wire,hubtest}`), Swift 5.10 language mode, CryptoKit (`WatchtowerKit/WatchtowerSync`), SwiftUI app wiring (`WatchtowerMobile`), goose sidecar migrations.

**Spec:** `docs/superpowers/specs/2026-10-29-relay-client-design.md` §1 ("At launch, relay links keep today's key scheme"), §9 (switch and epochs), §13 row 5. Relay design in the relay repository at `bcca870`: `docs/superpowers/specs/2026-10-28-relay-design.md` §7 items 1–5, §4.2 item 6, §9 item 7; `sim/README.md` rules 13 and 14. Protocol: `docs/superpowers/specs/2026-10-31-hub-phone-protocol-design.md` §4.2, §4.3, §5.4, §7.6, §7.7. Go hub: `docs/superpowers/specs/2026-10-31-go-hub-design.md` §3 lists this as out of scope, and the relay client spec keeps Phase 5 to the phone and the Kit. **This session builds the hub half too (ask #1067): the phase does not work without it, and no Go hub session runs (ask #1015).** E2E research: `docs/superpowers/specs/2026-10-12-mobile-e2e-encryption-research.md` §2.2–§2.3.

## Read this first: what the recon found

1. **The relay at `bcca870` lacks nothing for this to run.** Records stay opaque, the keybox overwrites its record in the data zone, and `epoch_ack` is an ordinary sealed mailbox record. No server or protocol work is needed. The one thing that goes to the relay session (the ask #734 route) is a text-only edit of its spec and its `docs/watchtower-client-requirements.md`: launch condition 5.
2. **The phase cannot usefully be split into "cadence first, keys later".** With a 7-day cadence and static keys, a stolen `dev_kx` plus recorded keyboxes still opens every epoch, and static pairwise keys still open every recorded mailbox record. Only the two together deliver what §7.4 promises. A smaller alternative, a symmetric key chain with no ephemeral keys, was put to the owner, who chose X25519 as in the spec (ask #1077).
3. **Shorter epochs turn four rare paths into weekly ones.** None of these is a problem at 90 days. Each has a task:
   - **Recording uploads can be lost.** A recording is sealed once and every send repeats those bytes (protocol §7.7), and `RetireIfDone` can end an epoch at once. An upload sealed in that epoch is then dropped unanswered, forever. Task 9.
   - **A locked phone's alerts go blank.** A relay `alert_push` is sealed in the current epoch, but the extension's key copy updates only after an unlock. Task 5.
   - **The phone's mailbox feed can jam.** Today the phone derives a relay key for any epoch. With stored keys, a missing key throws `keysUnavailable`, and the feed replays that batch forever. Task 8.
   - **Every rotation re-uploads the whole window, transcript assets included.** That is at most 200 transcripts of at most 20 MiB each, weekly. Measured as "Measuring the cost" says, before launch (ask #1077).
4. **A free phone linked to a relay hub would defeat the whole scheme.** Today every linked phone's keybox goes into the relay data zone, sealed to its static `dev_kx`. A free phone never reads it, yet recording it and later stealing that phone's `dev_kx` opens `K_data` of every relay epoch. Task 4 takes the keys out (ask #1077).
5. **The hub never erases retired epoch keys.** `hub_epochs.sealed_keys` stays forever; "retired" only filters reads. §7.4 says old epochs are erased. Task 3 does it, for relay epochs only (ask #1066).
6. **The relay's own retention is weaker than the design this threat model came from.** Relay design §7 assumes 1-day backups; the Cloudflare design §9 has Durable Object point-in-time recovery for 30 days. For 30 days, whoever controls that account may be able to restore overwritten ciphertext from the objects it covers. This raises the value of the phase, and it is the honest reason to do it.
7. **Timing, ruled.** The spec said "after launch" (ask #799). The owner chose **with launch** (ask #1066): rotation ships on, and launch waits for this phase's reviews and its staging run. No relay user exists before launch, so there is no old relay build to support.
8. **A phone can stop being a reader while the hub stays on the relay** (its subscription moved or ended, another phone still pays). Without a design, the hub keeps deriving keys for it, its keybox has no keys, and records sealed in those epochs jam its feed, even `hub_on_relay`. Task 13 and "Losing and regaining reader status" design this in both directions.
9. **The phase changes who can talk to whom once a retention has passed.** A lapsed phone that subscribes again has an old newest epoch, and the hub drops a control sealed in a retired epoch (`ErrEpochNotAccepted`, only actions get `resend_from`). At 90 days that was rare. Task 13 merges the keybox at the reader wait, before the request.

## The threat, honestly

**What it addresses.** An attacker who has recorded ciphertext from the relay (the operator, a breach of the Cloudflare account, or the 30-day recovery above) and who later extracts one phone's keys. Today that yields up to 90 days of `K_data` and `K_alert`, plus every recorded action and echo of that link for its whole life. After this phase it yields the epochs the phone still holds. If the thief stays passive, the next rotation with a fresh offer heals the link, because the new keys depend on a private key the thief never saw.

**How much that is. There is no fixed bound, and no user-facing text may state one (ask #1077).** With the Mac running and the phone in touch, a stolen phone opens the current epoch and the previous one: up to 7 + 7 days of recorded data (ask #843). Four cases go past that:

- **Mac closed, a paused or unvouched hub, or a hub with no reader or nobody paying.** No new epoch begins (F1, F5, F36), so one epoch's keys stay current on the phone for as long as that lasts; a hub with no reader or nobody paying starts one more at 14 days, which clears its rows and which a phone reads only if it comes back. A paused hub whose answered reads still show a paying phone in a slot has no such end: it stays on that epoch until the pause ends. Little is sealed in that time: nothing from the hub, only the phone's own actions.
- **Phone offline.** It erases nothing until it reads a newer keybox, because retention starts at the merge. Stolen after six months away, it still opens what it held when it left.
- **Phone offline while the hub rotates.** Every epoch of the absence is sealed to its one last offer, so that phone's theft opens **all of those epochs**, however many weeks they span. The same holds, for one extra week, after a lost ack (F8).
- **A relay-only phone the relay refused.** It gets neither `hub_on_relay` nor a follow, so it keeps its keys for a term: 21 days from the first refusal, unless the refusal ends first. The link then ends the next time the person opens the app past that, once an account read shows the refusal stands, and not during a recording. A phone never opened, or whose account reads never answer, keeps them until then, with no cap ("The term on a refused phone's link").

**What it does not fix:**

- A thief with a live, unlocked phone reads the replica directly. Keys are not the barrier there.
- An **active** thief holding current keys can send their own `next_kx` and stay in the link until the owner removes the phone. Only a re-link or Remove ends that.
- **Mac compromise.** The hub holds plaintext. Hub key erasure is hygiene, not a barrier, and `hub_kx`, `hub_sig` and the wrap key stay.
- **`K_meta` does not rotate** (protocol §4.2), so record names stay linkable over time. Sizes, timing, ids and APNs tokens stay visible to the relay (relay design §7).
- **It is not a ratchet.** Inside an epoch one key seals everything, and a phone that stays away reuses its last offer across rotations.
- **The first week on the relay is static** (ask #1077): after a link, a switch or a renewed subscription, the first keybox must go to `dev_kx`. Such a phone is the weakest link for that epoch's `K_data` while it reads the zone.
- iCloud links get none of this, by decision.

## Global Constraints

- `relayRotationAge` = 7 days on a hub whose transport is the relay; `RotationAge` = 90 days on CloudKit; `RotationSeqCap` = 2^28 stays. The age depends on the transport (relay design §7.4: "a hub has one scheme"; ask #1077). A held hub does not rotate while held. One with no reader or nobody paying does not rotate either, and ends at 14 days (asks #1077, #1081).
- **Rotation is on at launch (ask #1066).** There is no build setting for it. Until launch a Release build has an empty `WATCHTOWER_RELAY_ORIGIN`, so no phone is on a relay route.
- The `relaystaging` build tag is the only way to shorten the age and the hub's retention (Task 3, ask #1077); no release path may set it.
- Retention stays 7 days on both sides (`PreviousEpochGrace`, `previousEpochGrace`, ask #843) and at most 8 epochs on the phone (`maxEpochs`).
- CloudKit links: same bytes, same recipient (`dev_kx`), same `wt/relay/v1/` derivation, no offer ever sent. Guard: `TestKeyring_RotatesAt90DaysOrSeqCap` stays unchanged.
- Existing frozen vectors do not change. New vectors are additive (`kdf.json`, `go-sealed.json`, `hub_contract_cases.json`).
- Sim rule 13's byte-for-byte switch resend, and the `action_seq` that never resets, stay.
- Ephemeral private keys live only in the `hub.<id>` Keychain item (`whenUnlocked`, `ThisDeviceOnly`). They and the derived relay keys never reach the `afterFirstUnlock` alert material or any log.
- **Two new phone states on Now, the parked row and the left-behind banner, one link notice, and no other new text; no Desktop change** (see "Phone screens").
- Go hub ↔ Kit bytes change together: `wire.KeyboxKeys`/`KeyboxKeys`, `wire.Control`/`ControlPayload`, `secure.EphemeralRelayKey`/`KeyDerivation.ephemeralRelayKey`.
- Agent-run rules (the relay launch `common.md`): TDD with RED and GREEN logs, inner loop only, foreground only, no repo-built CLI on live data, no live data in the repo, guard files untouched, a stop-and-report on any contract, wire or behaviour change beyond the rulings below.

### What reaches iCloud users (ask #1066)

Only the inert sidecar migration. Offers go only on a relay route. Erasure runs only on epochs that began on the relay (`hub_epochs.on_relay`), and with none to erase there is no pragma and no checkpoint. The upload reseal runs only on a relay route or a link that has moved routes.

## Launch condition (ask #1066)

Relay does not turn on for users until all of these hold. Task 12 adds them to the spec and to Phase 4's Launch conditions:

1. Phase 5's PRs are reviewed and merged into `feature/relay-client-next`.
2. "The staging run" below has passed, with "Measuring the cost" read against its thresholds or ruled on by the owner.
3. Its dependency is met: Phase 4's owner-only steps and manual checks M1–M10 on staging, **none of which has run**.
4. **No build with a set relay origin has left development.** "No old relay build" (Decisions) holds only while this does. Check: `TestNoReleasePhoneBuildSetsRelayOrigin` (Task 12) looks for the phone's setting by its exact name, `WATCHTOWER_RELAY_ORIGIN`, in `WatchtowerMobile/Base.xcconfig`, `project.yml`, the `Makefile`'s `mobile-archive` and `mobile-testflight` targets and `.github/workflows/`, and fails on a non-empty value. `linux-build.yml`'s `RELAY_ORIGIN` is the hub's own variable under another name, so it does not match; the test names that file in a comment and pins that it does not set the phone's. **The change that sets the Release origin at launch deletes this test in the same PR;** the controller does that, on the owner's go. M2 needs a TestFlight build with an origin: it goes only to an internal group of the owner's own devices, and **the owner confirms that at launch**. If such a build reached anyone else without Phase 5's phone half, stop: the old-build path is back, and it goes to the owner. A Linux hub tag pins `RELAY_ORIGIN` (`linux-build.yml`); that is no relay user by itself, because a hub needs a paying phone to vouch for it.
5. **The relay session has made these text edits** (ask #1077). We cannot do this ourselves. They are **not yet delivered to the relay session**, and this plan is their only lasting record. **The check: the controller reads the relay repository at the launch gate, before the joint merge.** This condition stays open until the edits are read there. If they are missing then, the owner rules at that gate; meanwhile `docs/features/relay-client.md` states the difference.
   - Relay design §7 item 5: "(the hub keeps its last ephemeral key until the device confirms the new one)" becomes "(the hub draws a fresh ephemeral key per phone at each rotation and erases it at once; until the device offers a newer key, the hub keeps sealing to its last offer, and the device keeps that key until a keybox names a newer one)".
   - Relay design §7 item 4, after "sealed to the device's current ephemeral key, not to the permanent `dev_kx`": add "; the first keybox after a link, a transport switch or a renewal goes to `dev_kx`, because the device has offered no key yet, until the next rotation".
   - Relay design §9: "waits for items 1–6 and 8; key rotation (item 7) concerns only links via the relay and may arrive in the next client release — it does not block the launch." becomes "waits for items 1–8. Key rotation (item 7) concerns only links via the relay."
   - `sim/README.md` rule 5, in place of "`resend_from(n+1)` once per gap": "`resend_from` is once per gap, and repeated when the ask is 10 minutes old, or dated in the future, and another action is read ahead of that gap (watchtower ask #1073)."
   - `docs/watchtower-client-requirements.md` §1a: "Launch for users waits for items 1–7 and 9; item 8 (key rotation) may come in the next client release." becomes "Launch for users waits for items 1–9."
6. **The G2 lane has merged the `lapse` change (ask #1075):** the Mac stays on the relay while someone else pays, and moves when nobody pays, routes playing no part. **"Someone pays" means a paying phone holding this Mac in its slots, linked or not (ask #1079).** On an unreadable account: **a phone's own `entitlement_expired` request moves the Mac at once, by the relay's rule 10 (ask #1079). The relay's own signal waits:** the undecided lapse is kept in `hub_meta.lapse_pending` and retried at every Step, about every 30 s, with no cap on tries, across a restart, until a read answers (ask #1079). A waiting lapse ends when the phone is listed paying past `LapseFresh`, 2 minutes. Read at `affeebb8e`, PR #702, in CI, not merged.

## Review Focus

1. **A phone away for three or more rotations returns with an old outbox and an old echo.** It must recover with no owner action and no permanent feed jam. Tests: Task 8 `testARelayRecordInAGoneEpochIsDroppedNotReplayed`, Task 11 step 4.
2. **Rotation hits a recording that is sealed but not yet sent.** The audio must arrive once. Test: Task 9 `testARowSealedInAnOlderEpochIsResealedBeforeSending`.
3. **Two rotation triggers overlap: an age rotation falls inside a transport switch.** The `transport_switched` epoch and the keybox must match. Test: Task 3 `TestRotateIfDueSkipsWhileASwitchIsRunning`.
4. **A phone on iOS is locked across the rotation and an alert arrives.** The owner still reads the alert's text. Test: Task 5 `TestAlertPushSealedInAnEpochThePhoneHolds`.
5. **A switch to iCloud with a free phone linked.** The free phone must still get its keybox, though it got no keys on the relay. Test: Task 4 `TestSwitchToCloudKitGivesAFreePhoneItsKeys`.

## What was checked against code, and at which commit

The plan's reviewer cannot read this branch, so this is where to look. Each was read, not run.

| Claim | Read at |
|---|---|
| The table "What the merged code gives Phase 5", `lapse`, `owe`'s call and package note, `sealEpochFor`, `TransportFollowerPolicy`, `SideMailboxReader.look`, `TransportRequest`'s relay-only refusal, `NowOutboxRows`, `HostedRelayTransport.fetchForPush`, PROJ-21's words | `92636f852` |
| `resend_from` and its re-ask, `askDue`, `drainHeld`, `ResendAskAgainAfter`, the outbox's `closeAskedGap`, `ActionOutbox.retry` (a new id and seq), `withdrawUnanswered`, the ledger key and `repeat` | `2bfcae86f` |
| G2's `checkNoPayer`, `fingerprint` with `ICloudRoutes`, every linked phone needing a route; `lapse`, `queueLapse`, `lapse_pending`, `Config.AccountPhones`, `LapseFresh`, `owe` (it marks a route-less phone lapsed); `RelayAccountCenter`'s event handling, `RelayBannerModel`, `refusesTheAccount`, `LinkNotice`, `endLink`, `unlinkRow`, `performRemoval`, the `ErrEntitlementInactive` branch in `actions/control.go` | `affeebb8e`, PR #702 on `relay-lc/g2`, in CI, unmerged |
| G1's rules | `g1-design.md`, a design; its code was not read |
| The relay's `COALESCE_MS`, PITR, and `zoneAccess` (`worker/src/do/zone/acl.ts`): a phone with no slot gets `FORBIDDEN` on a mailbox save or read and may still delete; a slotted phone not paying gets `ENTITLEMENT_INACTIVE` on a save; a non-reader gets `FORBIDDEN` on the data zone; the Mac too gets `FORBIDDEN` on a mailbox whose phone holds no slot, and `ENTITLEMENT_INACTIVE` only where a slot holds it and nobody pays. `remove_slot` has no payment rule in `proto/README.md` | relay `bcca870` |

**Two claims are not settled by reading, and each has a step.**

- **A phone's resend over an unreadable echo overwrites under sim rule 3, and the real hub answers it as a repeat.** Read: the rule in `sim/README.md` and the repeat path in `order.go`. Run: Task 6's `TestLostResendFromFilledByResendingUnechoed` on the fake, and Task 11 step 4 on the stand, before PR C can merge. **If it is false,** the drop's requeue does not recover, so F16 and the `resend_from` row change. The implementer stops and reports; the fallback is a dropped record listing the unechoed rows Not delivered.
- **G2's code as merged.** PR #702 is not merged. Task 13's re-check reads `owe`, `queueLapse` and `AccountPhones` as they land. If `owe` stops marking a route-less phone, `ReaderLost` also calls `state.LapseRelay`; `TestReaderLostMarksARouteLessPhoneLapsed` holds either way.

The relay's refusals were read in `acl.ts` and are also asserted on the real relay in Task 11 step 7.

## Interplay with G1, G2, #1497 and #1498, and the re-check before Tasks 2–4

The owner has ruled on all four; the code is landing while this plan is under review. The table below is pinned to `92636f852`. **Before Task 2, and again before Tasks 3, 4 and 13,** the implementer compares what merged with what this section says and reports any difference to the controller; a difference in a rule below goes back to the owner before the task continues.

- **G2 (asks #1055, #1070, #1072).** The rule: the Mac moves to iCloud by itself **only** when the account lists no paying phone on two answered reads at least `NoPayerPoll` (5 min) apart **and every linked phone has an iCloud route** (ask #1072). A paying phone not linked to this Mac: the Mac stays (ask #1070). A linked phone with no route: the Mac stays (asks #1070, #1072). Every phone with a route and a long empty list: it moves after two reads (ask #1070). Unknown moves nothing. PR #702 at `affeebb8e`, unmerged, read for this plan: `checkNoPayer` has the two reads, `ErrNotFresh` and the stay on a paying phone, and its `fingerprint` requires a route on every linked phone (`ICloudRoutes`). The re-check confirms that what merges still says this. Task 13's outcomes below are written against these rules. 
  `lapse` is a separate rule, for an explicit expiry or the phone's own request (ask #1075): the Mac stays while someone else pays, meaning a paying phone holding this Mac in its slots, linked or not (ask #1079), and moves when nobody pays, whatever the routes; a route-less phone is then left to re-link. It reads the account afresh through `Config.AccountPhones`, and a waiting lapse ends if the phone is listed paying past `LapseFresh`. On a failed read, a phone's own request moves the Mac at once (rule 10, ask #1079), and the relay's own signal waits and retries at every Step from `hub_meta.lapse_pending` with no cap (launch condition 6). The G2 lane builds this. G2's self-move keeps ask #1072's rule (ask #1075), and **rule 16 wins over it (ask #1087):** nobody paying and a phone with no route, a refused write or the relay's signal runs `lapse`, which moves the Mac. **That is not always soon.** The only refusal that runs `lapse` is `ENTITLEMENT_INACTIVE` on a hub write into a phone's mailbox (`actions/control.go`). `acl.ts` gives that only where a slot holds the hub and nobody pays. With no slot the hub gets `FORBIDDEN`, which runs nothing, an idle hub writes nothing, and a signal can be lost. So the hub may stay for as long as that lasts (F45). The re-check compares what merges with both rules, with "someone pays", with the two failed-read paths and with that retry, checks `queueLapse` still exists as the one entry for Task 13's clear and writes `lapse_pending` first, and reads `owe` as above.
- **G1 (ask #1056: on the relay the phone's sealed record and the mailbox rule replace the creator check; a 3-second pause before `remove_slot`).** A phone's relay-lane record is AEAD under the pairwise key, not signed, so its authority is that key, the sender check and the mailbox's write rule. The ask's own word was "signature"; this plan uses what the code does. Design: `g1-design.md` in the launch directory. Three consequences:
  - `epoch_ack` is a control, not a `device` record, and never had a creator check. Its authority on the relay is the same mailbox rule plus the pairwise key. The offer needs no signature of its own, and Task 2's `decide` gate does not change.
  - `device` records now arrive on the relay, sealed in the phone's newest epoch, so they follow the same key rule. A record sealed under deleted rows or a retired epoch is dropped; the hourly `touchIfStale` rewrite heals it after the next merge. A **farewell** is not rewritten: F32.
  - G1's sidecar migration takes `00014` (`device_work_alerts`), so Task 2's file takes the next free number.
- **#1498 (ask #1073), merged as `2bfcae86f`.** The hub asks a gap again once its ask is 10 minutes old (`ResendAskAgainAfter`), and a late copy of a skipped action gets `expired`. A row refused for good gets `skip_to` (`closeAskedGap`). The re-check compares `order.go`, `dispatcher.go` and the outbox's ask handling with "What a dropped or parked record costs".
- **#1497 (ask #1060: its window is an accepted limit).** It concerns a route move's sweep. A rotation is not a route move and must not sweep: `testARotationDoesNotSweepTheReplica`, once #1497 is in the branch.

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
2. **Hub.** It stores the offer as `devices.kx_offer` and `kx_offer_epoch`, newest ack epoch winning, and only while on the relay and not lapsed.
3. **Hub, at rotation (transaction).** For each linked phone with an offer: draw `hub_eph`, derive both directions, seal them under the wrap key as `epoch_relay_keys(epoch, device_id, hub_pub, device_pub, sealed_keys)`, and let `hub_eph` go out of scope, its bytes cleared.
4. **Hub, keybox.** HPKE to the offer (`KeyboxRecipient`) with `relay_kx: {hub_pub, device_pub}` and, for the previous epoch, `previous_relay_kx`.
5. **Phone.** It tries `offered`, `current`, then `dev_kx` to open the keybox. It finds the private key named by `device_pub`, derives, stores the pair on `EpochKeys`, promotes `offered` to `current` when `device_pub` is the offer, and erases the older key. Back to step 1.

**A lost ack costs one week and needs no new record.** At the next raise, the keybox names the same `device_pub`, the offer is still outstanding, and the next `epoch_ack` carries it again.

**A phone that offers again in the same epoch** (renewed after a lapse, or a dev build updated mid-epoch) has already acked it. `epochAckDue` therefore also says yes for the same epoch with an offer not yet sent.

**The phone's rule for a relay key:**

| Epoch entry on the phone | Link has ephemeral state | Key |
|---|---|---|
| Present, with a stored pair | — | the stored pair |
| Present, no pair | — | static (`wt/relay/v1/`) |
| Absent | no (iCloud, a hub without the hub half, before the first offer) | static, any epoch, as today |
| Absent, epoch above the newest held | yes | `epochKeysPending`: on the active route the batch replays with its token kept, **for at most `keyboxWaitCap` = 1 h from the first sighting** (`relay_wait_since` in replica meta). Then the feed **parks**: token kept, nothing skipped, no more fetches until a merge, a foreground or a launch. In the side reader it holds nothing back and drops nothing: the look handles what it can open behind it, and keeps its token at that batch, so the record is read again once the keys come. While `waitsForKeybox` is false (no key source) the feed parks at once with no row |
| Absent, epoch at or below the newest held | yes | `epochKeysGone`: the record is dropped, the feed moves on |

**One exception to every row above:** when no row's key opens an h2p record, the phone tries the static key, and accepts the result **only if the frame is a `hub_on_relay` control**. Anything else opened that way is unopenable. So a thief holding only an old `dev_kx` can at worst push the phone off the relay, visibly, and cannot forge echoes. See "Losing and regaining reader status".

**Hub-side sealing:** for a phone with `kx_offer` set, echoes and controls are sealed in its acked epoch while the hub still retains it, else in the current one. A phone with no offer gets today's sealing and static keys.

**What a dropped or parked record costs.** Parking loses nothing: the token stays, and every record is read in order once the keys come. The side reader's pending record is not lost either, as the table says. Only `epochKeysGone` drops a record, because those keys can never come. The hub asks a gap when it holds an action behind it, and asks again only when its ask is at least 10 minutes old (`askDue`, #1498, ask #1073). That repeat runs from `hold`, so it needs a further action to arrive: an idle hub writes nothing (`drainHeld`). A dropped `resend_from` with no later action would wait. So **every `epochGone` drop queues all this phone's unechoed actions again, once per batch, in order** (`requeueUnechoedAfterDrop`). The hub applies the missing seq, releases what it held, and answers the rest as repeats (sim rules 3 and 4). A row the phone can no longer send is refused for good and gets `skip_to` (`closeAskedGap`, #1498); a late copy of a skipped action gets `expired` (ask #1073).

| Dropped record | Recovery | Test |
|---|---|---|
| Echo | The action goes again, the hub re-echoes it as a repeat | `testADroppedEchoQueuesTheUnechoedAgain` |
| `resend_from` | The same resend fills the gap. Its arrival behind the gap also lets `hold` ask again if the old ask is 10 minutes old. A row sealed in a retired epoch draws a new `resend_from` (`oldEpochAction`, once per record version) and is resealed; one past its key is refused for good and gets `skip_to` | `testADroppedResendFromRecoversByResending`, Go `TestLostResendFromFilledByResendingUnechoed` |
| `transport_switched` | The transport marker on the next sync (rule 12a) | Existing `TestMarkerLeadsReturningPhone` shape, `testADroppedSwitchIsFollowedByTheMarker` |
| `transport_switch_rejected` | The request's existing 24 h end with **Try Again** (Phase 4, Open decision 15) | Existing |
| `hub_on_relay` | Never dropped: the static exception opens it | `testHubOnRelayOpensOverAStaleEphemeralState` |

**A `resend_from` in the iCloud mailbox.** The hub writes it on its active transport, so it sits in iCloud only for a phone there or moving there. On a follow, rule 13 resends every unechoed action, which does its work. On `withoutHub`, every unechoed action is listed Not delivered, so no gap remains. Otherwise the active feed reads it under the rules above. `testAResendFromInTheICloudMailboxIsCoveredByTheFollow`.

## Losing and regaining reader status

**A relay-eligible phone** is linked, not lapsed, and held in a slot by the last account read that answered. An offer exists only for such a phone, with one exception: the held offer of the empty-list case below. That is what lets `RotateToward` derive for every row with an offer and nothing else: no age rotation runs during that hold, the day-14 rotation derives nothing, and the zone keybox carries no keys until the phone is back.

**The signals the hub really has** (checked in `internal/hub/switcher/entitlement.go`, `transport/relay/pairing.go`, `runtime.go`):

| Signal | Durable? | Covers |
|---|---|---|
| The relay's `ENTITLEMENT_EXPIRED` naming the phone (`OnControl`) | runs `lapse`, which sets `devices.relay_lapsed_at` | Subscription ended |
| The phone's own `transport_switch(cloudkit, entitlement_expired)` (`Request`) | same | A move or end the phone heard of. On all three, the Mac itself follows ask #1075 |
| A hub write into a phone's mailbox refused `ENTITLEMENT_INACTIVE` (`EntitlementInactive`, from `actions/control.go`) | same, at the next Step | That phone's account holds the hub and does not pay. `FORBIDDEN` (no slot) does not run it |
| `AnyPaying` false on two reads, every phone with a route (G2, `checkNoPayer`, ask #1072) | moves the whole hub; the rotation clears all offers | Nobody pays, and everyone can follow. With a route-less phone, the hub waits for the rows above (ask #1087), which may not come (F45) |
| `get_account_state`: a linked phone in no slot (`SetReadersFrom`) | in memory only | A phone gone with the Mac staying: the relay sends **no** control, G2 stays quiet, and today nothing acts on it. See the outcomes below |
| `Paying` read lists the phone again (`recheckLapsed`, every `PollOther`) | clears `relay_lapsed_at` (`endLapse`) | Paying again |

**Going out, on the hub.** `queueLapse`, the one entry of all three signals, runs `state.ClearDeviceKX` first, in its own transaction, whatever the account read later says (ask #1081 for the relay's signal; the agent's inference for the phone's own request): the offer and all of that phone's relay-key rows go. From that commit every key for this phone in every epoch is static, in both directions. `SetKXOffer` refuses while `relay_lapsed_at` is set **or the phone is in `hub_meta.lapse_pending`**, read in the ack's own transaction. A failed read can leave that window open for a long time, and an old `epoch_ack` in the same batch would otherwise write the offer back. `queueLapse` writes `lapse_pending` before it clears, so there is no moment with neither (`TestOfferRefusedWhileLapsePending`). The slot signal has its own rule, below. `KeysInZone` turns false, so its next keybox has no keys, and `PublishSoon(KindDeviceGrant)` publishes it.

**A phone gone while the Mac stays: `ReaderLost`.** New `Switcher.checkDeparted` runs on the same poll as G2, and also on a host with no CloudKit, where `checkNoPayer` returns early. It reads the slot list only, so **who pays plays no part in it**. A phone *departs* when it has an offer or relay-key rows, a non-empty answered list omits it on two reads at least `NoPayerPoll` apart, the linked phones are unchanged and none was just linked (G2's guards). `ReaderLost(device)` then runs `ClearDeviceKX` and `owe(device, stay: true)`, which queues `hub_on_relay` where it has an iCloud mailbox and marks the phone lapsed, a route-less one too (see the re-check; `TestReaderLostMarksARouteLessPhoneLapsed`). **It never calls `lapse`'s move branch and never moves the Mac.**

| Answered account state, on two reads | iCloud routes | The Mac | The gone phone's keys | Source |
|---|---|---|---|---|
| Another linked phone in a slot | any | stays | offer and rows cleared, no more keys in the zone | Task 13 |
| A paying phone not linked to this Mac, holding this Mac in its slots | any | **stays** | the same: that phone counts only as making the list non-empty | asks #1070, #1079 |
| Nobody pays, the list is not empty, a linked phone has no route | not on all | **stays, until the relay's signal or a mailbox write refused `ENTITLEMENT_INACTIVE` moves it** (ask #1087); no rotation; 14-day end | the same for a phone absent from the list; the hold below for those still on it. A route-less phone gets no `hub_on_relay`: it hears the relay's refusal | asks #1072, #1081, #1087 |
| The list is **empty**, a linked phone has no route | not on all | **stays.** Its writes get `FORBIDDEN`, which moves nothing, so only the relay's signal moves it | **held, for at most 14 days:** offer and rows stay at first. No rotation, so nothing new is sealed to it, and the zone keybox carries no keys. An empty answer cannot be told from a revoked account, and clearing a phone that is really there at once would break a link that has no iCloud way out | asks #1070, #1072, #1077 |
| Empty or nobody pays, every phone has a route | all | **moves** after two reads | G2 goes first in the poll; the rotation clears every offer; `checkDeparted` skips this poll | asks #1070, #1072 |
| A failed read, `ErrNotFresh`, unreadable phones | — | stays | nothing moves, nothing is cleared, the count does not advance | ask #1070 |

**That table is for a phone gone with no signal. On an explicit signal `lapse` runs instead (ask #1075):** a paying phone other than this one holds this Mac in its slots, linked or not (ask #1079): the Mac stays, that phone's keys are cleared, and it leaves through `hub_on_relay` where it has an iCloud mailbox. Nobody pays: the Mac moves whatever the routes, the rotation clears every offer, and a route-less phone is left to re-link. A failed account read: on the phone's own request the Mac moves at once (ask #1079); on the relay's signal it moves nothing and retries from `lapse_pending`. That phone's keys are already cleared in both cases: on the relay's signal by ask #1081, on the phone's own request by the agent's inference, since `queueLapse` is one entry. `TestLapseClearsKeysUnderEveryAnswer`, over each of these.

**How the hub knows it serves nobody.** From the answered `get_account_state`, not from refusals: a refusal says one write failed, and `FORBIDDEN` says even less. The hub keeps `relay_serving_nobody_since` in `hub_meta`: set when an answered read holds no linked phone in a slot **or no phone pays** (ask #1081), cleared when an answered read has a paying phone and a linked phone in a slot, or by a rotation toward iCloud, so it survives a restart and never outlives the relay. A failed read changes nothing, and a refusal alone never sets it. **While it is set, or the hub is held, there is no age rotation (asks #1077, #1081).**

**The end of the hold (asks #1077, #1081).** At 14 days, the mailbox TTL, after which no relay record sealed under those keys remains, the hub rotates once and clears every remaining offer and row. The rotation is local; the publish waits. "Once" needs no second flag: it is due only while the current epoch began before `since + 14 days`, so the new epoch ends it, across a restart too. The old epoch retires and is erased under the usual 7-day rule, so the old keys are gone about 21 days after the mark was set. Clearing the mark returns to the normal age, which is usually due at once. `TestDay14RotationOnceAcrossRestart`. **Dropped from the earlier version: a separate `relay_serving_nobody_rotated` flag.**

**What it costs a phone that really is there.** Back before day 14, its keybox still names its keys, and nothing changed. Back after it, the hub's keybox for the new epoch, static and sealed to `dev_kx`, gets keys in the zone. The phone merges it and works, with one static week before its new offer counts. An action it wrote in between does not open and gets no answer. Its next action reaches `hold`, the hub asks for the gap, and the old row is resealed from the keys the phone still holds. If it writes nothing more, that action stays unanswered.

**After a restart** the reader list is unknown until the first answer. The mark decides: if set, no rotation until an answered read clears it. If not set, an unknown list rotates when due.

**What a relay action already written does.** Sealed under the deleted rows, it no longer opens; `Lapsed` already says no relay action written before a lapse is applied, and the phone lists it Not delivered on `hub_on_relay`. Nothing that would have been applied is lost.

**What the phone really hears, and what changes (read in `RelayAccountCenter` at `affeebb8e` and `acl.ts`).** A slotted phone not paying gets `ENTITLEMENT_INACTIVE` on a save: `syncThenLapse`, then `lapseRelay()`, `relayLapsed`. **A phone out of the slot gets `FORBIDDEN`, and its subscription may stand. `RelayAccountCenter` ignores `.forbidden` today,** and `SLOT_REMOVED` only re-reads the account, so nothing tells the session. A paying phone also has no banner, as `needsRelay` returns nil for `.paying`. Its queued rows do go Not delivered one by one, because a `FORBIDDEN` save is a permanent refusal, but rows already `sent` hang.

**New: `slotLost` (Task 13, ask #1081).** On `.forbidden` and on `SLOT_REMOVED`, the center reads the account. If that read answers and a relay-route hub's Mac is in none of this phone's slots, it calls `HubSession.relaySlotLost()`, which sends `FollowerInput.slotLost` to the follower. A failed read does nothing and waits for the next event. A `FORBIDDEN` with the Mac still in a slot, a hub that has not named it a reader yet, does nothing. The policy: with another route, withdraw (below), then move as `withoutHub` does, without waiting for `hub_on_relay`, which is then read and marked handled. With none, as below.

**What may still be applied, and the phone's rule (read at `2bfcae86f` and relay `bcca870`).** `ActionOutbox.retry` makes a **new action with a new id and seq**, so the hub's ledger cannot tell it from the old one: if the old one is applied too, it ran twice. The hub can still read a written action in that window: a slot given back makes a slot-less phone's mailbox readable again while its rows live, and a lapsed phone's mailbox stays readable until `Lapsed` holds. **The rule needs nothing new: the 24-hour path's `withdrawUnanswered` already deletes the phone's own record under the version it wrote, then lists the row, "so a later Retry cannot apply the action twice", and takes an echo met on the way instead.** `zoneAccess` lets a phone delete in its own mailbox with no slot and no payment. So the policy's `withdrawUnechoed` runs it for every unechoed row at once, with reason `.refused`, on `slotLost`, and on `relayLapsed` or a move read with no other route. A refused delete leaves the row `sent` for the next event or today's 24-hour sweep. An action the hub already applied comes back as its echo, not as Not delivered. A phone with another route on `relayLapsed` does as today: it asks, then follows with rule 13's resend or leaves on `hub_on_relay`. On an opened `hub_on_relay`, withdrawal is not needed for safety, as the hub has marked the phone, and `withoutHub` lists as today. `testSlotLostWithdrawsThenLists`, `testAnEchoMetOnWithdrawalIsAppliedNotListed`, `testARefusedDeleteKeepsTheRowSent`, `TestAWithdrawnActionIsNeverApplied`.

**A departed phone with no iCloud route (relay-only link).** `hub_on_relay` cannot reach it. On `relayLapsed` or `slotLost` with no other route, the rule above applies, and the route stays relay. **What is true of its written actions:** a withdrawn one is never applied. One the hub read before the withdrawal may have been applied, and its echo says so if the phone can read it. One whose delete was refused stays `sent` until a later pass; once the hub has cleared the phone's rows it no longer opens either: `droppable`, dropped with no answer. On its return, its next action leaves a gap, the hub asks, the phone has no row, and `skip_to` closes it (#1498). Requeue does not fire here, as nothing was `epochGone`. `testRelayOnlyLapseWithdrawsAndLists`, `testSlotLostWithASubscriptionWithdrawsAndLists`, `TestDepartedPhoneActionNotAppliedOnceRowsAreCleared`, `TestReturnAfterDepartureSkipsTheGap`.

**The term on a refused phone's link.** A relay-only link gets no proof, and today retention runs only on a merge. So `LinkRecord.relayRefused` holds `since` and a `cause`, set at the first `relayLapsed` (`.lapse`), `slotLost` (`.slot`) or move read (`.macMoved`) with no other route; a move read replaces the cause and keeps `since`. **One field, and each answered account read sets it by what it shows.** For `.lapse` and `.slot`: paying with the Mac in a slot clears the mark; not paying makes the cause `.lapse`; paying with the Mac in no slot makes it `.slot`; `since` stays. So a `.slot` phone whose subscription also ended keeps its term when the slot returns, and its banner becomes needs-Relay. `.macMoved` ignores reads, which say nothing of where the Mac is, and clears only on a marker toward the relay, because a stale keybox left in the relay zone could still raise. No merge clears the mark.

**The term runs only in the foreground.** `HubSession` checks it when the app comes to the foreground, on a launch or a return. A background launch does nothing: S60 lives only in the model's memory and would die with the process, leaving a Mac gone with no reason. It waits while a recording runs, so the term never stops one, and looks again after the read below.

**A due term reads the account first (`RelayAccountCenter`), because the mark may be old.** The person may have renewed, or got the slot back, while the app was closed. The read sets the mark as above: if the mark clears, the link stays. If the refusal stands, the link ends. For `.macMoved`, a read showing paying with a slot lets that foreground's first feed pass go first, so a waiting marker toward the relay can clear it; with no such marker, or no read access, the link ends. **A failed read waits: the mark stays, the term stays due, and the next foreground reads again, with no cap and no second number.** Ending the link needs an answered read. A cap would erase on no evidence, and it would not stop a thief, who can keep the phone off the network and never run this code at all. So the term is never cancelled by failed reads, and a phone whose reads never answer keeps its keys, like a phone never opened.

**At 21 days, on that answer, the link ends, by today's `unlinkRow`, the path Forget takes:** the farewell, then `remove_slot`, each kept and retried at launch when refused, the Keychain item with every key (ask #1086), the replica's files and the Not delivered rows go, recordings stay, and the row leaves Settings → Macs. The notice is `LinkNotice.after(wipe, macName:, otherwise: .relayEnded(macName, notSent))`, so a recording problem still comes first, as on every removal: "The link to <Mac> ended after 21 days without Relay. Link it again to see its data." and, with rows lost, today's "Not sent" count. S60. **The cost: a person back on day 22 whose refusal still stands has no history of that Mac on this phone and its unsent actions are gone, and they must link it again, even if they pay afterwards.** With no link, no new action can be made for it, and a stored keybox has nothing to merge into.

**The hub's side is a limit, and it is the usual case.** The term runs because the relay refuses this phone's writes, so its farewell is almost always refused too, and a kept farewell stops being sent after 7 days (`farewellLifetime`). `remove_slot` has no payment rule, so it usually succeeds, and `ReaderLost` then clears that phone's keys, or the 14-day end does if the list is left empty. **So the phone's row normally stays on the Mac** until the owner removes it or a re-link clears it. While it stays, a route-less row keeps G2's self-move from happening for other phones (ask #1072). Rule 16 still moves the Mac when a signal or a refused write comes, which may not happen (F45). `testRelayOnlyLinkEndsAt21DaysWithoutAMerge`, `testABackgroundLaunchDoesNotRunTheTerm`, `testRenewedWhileClosedKeepsTheLink`, `testSlotBackWhileClosedKeepsTheLink`, `testAFailedReadKeepsTheTermDue`, `testTheFirstAnsweredReadEndsADueLink`, `testAMarkerWaitingAtTheTermKeepsTheLink`, `testTheTermWaitsForARunningRecording`, `testALapseEndStopsTheTerm`, `testAnAnsweredSlotDoesNotStopTheTermOfALapse`, `testAnAnsweredSlotStopsTheTermOfASlotLoss`, `testASlotBackWithTheSubscriptionEndedKeepsTheTerm`, `testAStoredKeyboxDoesNotStopTheTerm`, `testARoutedLinkHasNoTerm`, `testTheNoticeNamesTheMacAndTheNotSentCount`, `testARecordingProblemWinsOverTheTermsNotice`, Go `TestRelinkAfterTheTermClearsOfferAndRelayKeys`.

**A route-less phone left behind (ask #1075): what it can know.** After the Mac moves to iCloud, only a new link brings this phone back, but `needsRelay` says "<Mac> needs Relay." with **Subscribe**, and paying alone does nothing. The phone can know in two cases: it reads `transport_switched{cloudkit}` or the marker while its read window lasts, or it is paying and its Mac is in no slot (`slotLost`). Both set `LinkRecord.relayRefused` with that cause, the follower does not move the route, **and a route-less phone does not merge the switch notice's keybox, as it cannot follow,** unechoed rows are withdrawn and listed as above (a move made by another phone brings no `relayLapsed`), and Now shows S59 in place of the needs-Relay banner: "<Mac> can't be reached over Relay any more. Link this iPhone to it again." with **Forget This Mac** (Task 17, ask #1081). **It cannot know otherwise:** a lapsed phone past its read window, whose slot stays, reads nothing, so it keeps "<Mac> needs Relay." and **Subscribe**. Paying then gives it the read, the marker, and S59, so the person may pay and still have to re-link. That limit stays, and the guide says so. S59 shows for `.slot` and `.macMoved`, and clears with the mark, by the one rule above. An old echo clears nothing. `.lapse` keeps today's banner.

**Going out, on the phone.** On `relayLapsed` it queues its `transport_switch` (sealed with what it holds, as today). On `relayLapsed` and `slotLost` it clears `relay_feed_parked_since`, and **while it has no key source it parks at once, silently:** `SecureTransport` asks `waitsForKeybox`, false while `canUseRelay == .no` or `relayRefused` is set, and a pending record then stops the feed as parking does, token kept, no refetch until a merge, a foreground or a launch, with no parked mark and no row: the records behind it are not read until then, and Now shows nothing about it, because S59 or the needs-Relay banner already says why. So nothing rereads a batch on every pass. Clearing the mark turns it back on. **It erases no key then:** the hub may not have acted yet (it waits for two reads, or holds up to 14 days), and a slot given back in that gap would otherwise leave a keybox sealed to an erased offer, which is F17 with no way out. The private keys and stored pairs go only on proof the hub has cleared them, `droppingEphemeral()` on an opened `hub_on_relay`, or with the link at the term above. **`hub_on_relay` is sealed static** because the rows are gone, and the exception above lets the phone read it while it still holds its state; the side reader never replays, so owed echoes ahead of it in the iCloud mailbox cannot hold it back. It then leaves: route to iCloud, unechoed actions Not delivered, relay mailbox drained, control marked handled, exactly `withoutHub` today.

**The keybox is the one truth for an epoch's keys.** It is signed by `hub_sig`, so only the hub can say this. For an epoch it carries: `relay_kx` means that pair; no `relay_kx` means static, and **the phone drops any stored pair it holds for that epoch**, whatever else it thinks. So a hub that cleared a phone's rows inside an epoch and a phone that kept its pair agree as soon as the keybox arrives. A lost ack's mismatch ends the same way. On such a keybox for the newest epoch, with an offer outstanding, the phone clears `epoch_ack_kx` **only when that merge really dropped a stored pair,** so its offer goes again once: merges run after every fetch and at unlock, and a first week's static keybox has no pair to drop. The offer is refused while the phone is lapsed.

**A plain follow to iCloud** (the whole hub moved) uses `clearingEphemeral()` instead: it erases the two private keys and keeps stored pairs, because rule 13's resends and a `resend_from` reseal still need them and the hub keeps those rows until retention ends.

**Coming back.** A renewed phone goes through the upgrade path, and at `awaitReader`'s first successful read of `data/<mac>` it **merges the keybox it finds** before `request`. That keybox has keys once the hub names it a reader and `recheckLapsed` has ended the lapse, sealed to `dev_kx` because the hub holds no offer. The phone's newest epoch is then current, so its `transport_switch{relay}` is accepted however long it was away; without this it is sealed in a retired epoch and dropped unanswered. A read with no keys yet counts as not read, under the existing 24 h `readerWaitLimit` (`.readerNotConfirmed`). After following, its `epoch_ack` carries a new offer; it is stored once it is eligible, and the first ephemeral epoch comes at the next rotation. An offer read too early is refused and sent again at the next raise (one more static week).

## Mixed fleets

| Case | What happens | Test |
|---|---|---|
| Hub on the relay, one paying phone, one free phone | The cadence is 7 days. The paying phone goes ephemeral. The free phone is not a reader: its relay data-zone keybox carries the grant and **no keys**. It reads nothing there anyway and gets `hub_on_relay`. It keeps its static link. | `TestFreePhoneKeyboxOnRelayHasNoKeys` |
| That hub switches to iCloud | New epoch, all offers cleared in the rotation's transaction, every keybox to `dev_kx` with keys. `transport_switched` uses `KeyboxesAll`, so the free phone gets its keys. Cadence back to 90 days. | `TestSwitchToCloudKitGivesAFreePhoneItsKeys` |
| A relay phone with no offer yet (its first minutes after a link, a lost first ack, a pre-launch dev build) | Every epoch is static for it and its keybox goes to `dev_kx` **with keys**. It works. The hub logs a count per rotation. No relay user has a build without offers, because rotation ships with launch. | `TestPhoneWithNoOfferStaysStaticAcrossRotations` |
| A new phone, an old hub | The hub ignores `next_kx` (plain `encoding/json`; no `DisallowUnknownFields` under `wire` or `actions`). No `relay_kx` arrives, so the phone stays static. One unused offer sits in the Keychain. | Kit `testAHubThatNeverConsumesStaysStatic`, Go `TestEpochAckOfferUnknownToOlderHubDecodes` (decode pin) |
| An old phone build on iCloud | Nothing changes: 90 days, static. | Existing tests plus the unchanged vectors |
| Switch to iCloud mid-rotation (offer in flight) | The offer read after the switch's transaction is dropped because the transport is no longer relay. The phone clears its ephemeral state when it follows. A keybox naming no `relay_kx` means static. | `TestOfferReadAfterSwitchAwayIsDropped`, `testFollowingToICloudClearsEphemeralState` |
| Switch to the relay | New epoch, no offers yet, so it is static. The first offer comes with the ack after the follow. First ephemeral epoch at the next rotation, at most 7 days later (ask #1077). | Task 11 step 2 |
| Relay, iCloud and back within a week | Each switch starts an epoch; old relay rows stay until retention ends; the phone's `maxEpochs` of 8 holds them. A `dev_kx` keybox omits `previous*` when that epoch has a relay-key row for this phone. | `TestStaticKeyboxOmitsAnEphemeralPreviousEpoch` |
| A paying phone lapses, another phone still pays, hub stays on the relay | "Losing and regaining reader status": offer and rows gone in `queueLapse`, keybox without keys, `hub_on_relay` readable static, phone back on iCloud with static keys. The other phone keeps rotating. | `TestLapseWithAnotherPayerClearsOfferAndRows`, `testHubOnRelayOpensOverAStaleEphemeralState` |
| The same phone's subscription moved and the phone is gone, another linked phone in a slot | `ReaderLost` after two answered reads. The Mac stays; the gone phone's offer and rows go. | `TestReaderLostAfterTwoReadsClearsKeys`, `TestOneMissingReadChangesNothing` |
| The paying phone is not linked to this Mac (ask #1070) | The Mac stays on the relay. A linked phone absent from the list departs: its keys go. | `TestDepartedUnlinkedPayerMacStaysKeysCleared` |
| A linked phone with no iCloud route, nobody pays, no explicit signal (asks #1070, #1072, #1087) | G2 keeps the Mac on the relay until the relay's signal or a mailbox write refused `ENTITLEMENT_INACTIVE` moves it (ask #1087); no rotation meanwhile. A phone absent from a non-empty list departs. | `TestDepartedPhoneNoRouteMacStaysKeysCleared`, `TestDepartedRelayOnlyPhoneReturnsAndOffersAgain` |
| No route on some phone, the relay answers an empty list (ask #1070) | The Mac stays: its writes get `FORBIDDEN`, so only the relay's signal moves it. `ReaderLost` is silent; keys are held for at most 14 days; no rotation; no keys in the zone. | `TestEmptyListNoRouteMacStaysKeysHeld`, `TestEmptyListForbiddenWriteMovesNothing`, `TestEmptyListHoldEndsAt14DaysRotatesOnceAndClears` |
| An explicit expiry, nobody else pays, a phone has no route (ask #1075) | `lapse` moves the Mac to iCloud; the rotation clears every offer; the route-less phone is left to re-link | `TestLapseClearsKeysUnderEveryAnswer`; the move's own tests are the G2 lane's |
| Nobody pays and **every** phone has a route | G2 moves the whole hub to iCloud after two reads; the rotation clears every offer. | `TestNoPayerMoveClearsOffers`, `TestAllRoutesNobodyPaysG2MovesDepartedSkips` |
| A lapsed phone on iCloud, the hub still on the relay, pays again | "Coming back": keybox merged at the reader wait, request accepted, follow, new offer | `testAwaitReaderMergesTheKeyboxBeforeTheRequest`, `TestRenewedPhoneOffersAgain`, Task 11 step 8 |
| A re-link (the phone reinstalled, the Keychain survives) | The hub clears the phone's offer and relay-key rows with the new nonce; the phone's fresh link has no ephemeral state. | `TestRelinkClearsOfferAndRelayKeys` |

**Why a free phone's switch notice still carries keys:** `transport_switched` toward the relay goes to every linked phone with the first relay epoch's keybox. That hands one static week's `K_data` to the free phone's iCloud mailbox. It is a v1 limit, accepted in ask #1077.

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
| F15 | Echo arrives before the keybox | Feed replays with its token untouched, for at most 1 h, then parks; `keysMerged` wakes it. Nothing is lost | `testAnEchoAboveTheNewestEpochWaitsForTheKeybox` | 8 |
| F16 | Any record in an epoch the phone will never hold | Dropped as unopenable; all unechoed actions are queued again once per batch ("What a dropped or parked record costs") | `testARelayRecordInAGoneEpochIsDroppedNotReplayed` | 8 |
| F17 | Keybox names a key the phone no longer has. Only a restored hub sidecar reaches this: the phone erases its offer only after `hub_on_relay` or a follow to iCloud, when the hub has already cleared it | Merge refused, link kept, logged once, nothing wiped. Stale data until re-link (ask #1077). A phone past the term has no link at all, so a closed Mac's old offer never reaches this | `testAKeyboxNamingAnUnknownKeyIsNotMerged` | 7 |
| F18 | Age rotation inside a running switch | Skipped; the next cycle decides | `TestRotateIfDueSkipsWhileASwitchIsRunning` | 3 |
| F19 | Unlink during a rotation cycle | Serialised by the transaction; the removed phone's rows go with it; no keybox keys for it | `TestUnlinkRemovesOfferAndRelayKeys` | 3 |
| F20 | Recording sealed in an epoch the hub retired | Resealed before each send; a raise re-arms a stuck row; if its key is gone it is sealed afresh from the plain file | Task 9's tests | 9 |
| F21 | Data-zone quota refuses the keybox | Existing quota error on the Mac. Echoes stay readable while the acked epoch is retained; after that the feed parks, Now says so (F38), and the phone's actions wait | `TestEchoSealedInAckedEpochWhileKeyboxIsStuck` | 3 |
| F22 | Hub closed for over 7 days right after a partial republish | Phone drops the old key on schedule; rows not yet republished stay unreadable until the hub returns and finishes (ask #1077) | `testRowsInAnErasedEpochStayPendingUntilRepublished` | 7 |
| F23 | Phone linked while a rotation commits | Static until its first offer | `TestLinkDuringRotationStartsStatic` | 3 |
| F24 | Rotation and a lapse in the same moment | Serialised. Rotate first: the row it wrote is deleted by the lapse. Lapse first: no offer, no row | `TestLapseAndRotationEitherOrder` | 13 |
| F25 | Restart between the lapse's commit and `hub_on_relay` written | `owe` is durable as today; the offer and rows stayed cleared | `TestLapseRestartKeepsKXCleared` | 13 |
| F26 | Phone reads its feed on the relay route after the hub cleared its rows, and `epoch` is above its newest | Parks after 1 h, losing nothing, and Now says so (F38). The relay's refusal or the side reader's `hub_on_relay` gets it out, on a hub with both routes. On a relay-only host the refusal clears the parked mark, and the feed then stays stopped with no row | `testAPendingEpochParksAfterTheCapAndLosesNothing` | 8 |
| F27 | A false absence from one account read | Nothing happens; two answered reads `NoPayerPoll` apart are needed | `TestOneMissingReadChangesNothing` | 13 |
| F28 | A forged static record that is not `hub_on_relay` | Unopenable | `testAStaticEchoIsRefusedOnAnEphemeralLink` | 13 |
| F29 | A renewed phone's offer arrives before its lapse ended | Refused, sent again at the next raise | `TestOfferRefusedWhileLapsed` | 2 |
| F29b | An old `epoch_ack` read between `queueLapse` and the lapsed mark, a failed read holding that window open | Refused: the phone is in `lapse_pending`. The hub writes no offer or rows, and `hub_on_relay` stays static | `TestOfferRefusedWhileLapsePending`, `TestOldAckInTheLapseWindowLeavesHubOnRelayStatic` | 13 |
| F29c | Slot back before the hub acts, or the hub cleared while the phone kept its keys | The next keybox settles it: it names `relay_kx` or it does not | `testSlotLostThenSlotBackBeforeTheHubActsKeepsTheLink`, `testAStaticKeyboxDropsThatEpochsPairAndOffersAgain` | 13 |
| F30 | A `permission_answer` or `session_interrupt` sealed before a rotation (PROJ-21) | The answer is resealed and decides its row by the same compare-and-set, once; a stale one gets `not_pending` or `answer_on_mac`. An interrupt past its 120 s window gets `expired`. If its key is gone it is Not delivered, and the prompt stays on the Mac. PROJ-21's guards are unchanged | `TestPermissionAnswerAcrossARotationAppliedOnce`, `TestSessionInterruptAcrossARotationExpires` | 6 |
| F31 | A `device` record sealed under deleted rows or a retired epoch (G1) | Dropped, no state change; the hourly rewrite heals it after the next merge | `TestDeviceRecordInARetiredEpochDroppedRewriteApplies` | 13 |
| F32 | A farewell from a phone away past retention (G1) | Sealed in an epoch the hub no longer holds, dropped, not rewritten. The hub keeps the row until the owner removes it on the Mac; the slot is gone, so `ReaderLost` stops its keys. A limit, in ask #1077 | `TestFarewellInARetiredEpochLeavesTheRowAndStopsKeys` | 13 |
| F33 | Dropped `resend_from` with later actions held | The resend of unechoed actions fills the gap and releases them | `TestLostResendFromFilledByResendingUnechoed` | 6 |
| F34 | Unknown account read during `checkDeparted` | Nothing moves or clears; the count holds | `TestUnknownReadMovesAndClearsNothing` | 13 |
| F35 | Restart between the two reads | The count is in memory, so it starts again, which only delays | `TestRestartRestartsTheDepartureCount` | 13 |
| F36 | No reader or nobody paying on an answered read, the rotation is due, including after a restart | No rotation, by `relay_serving_nobody_since`; it runs at the first cycle after an answered read clears the mark | `TestNoRotationWithNoReaderOnAnsweredList`, `TestNobodyPaysListNotEmptyNoRotation`, `TestRestartWithNoReaderMetaDoesNotRotate`, `TestUnknownListWithoutMetaRotates`, `TestRefusalAloneDoesNotSetServingNobody` | 3 |
| F37 | A departed phone returns to the list | Its lapse ends by the `Paying` read, keys in the zone, static, a new offer at its ack | `TestDepartedRelayOnlyPhoneReturnsAndOffersAgain` | 13 |
| F38 | Feed parked (F21, F26) | Now shows the row with its count; it goes on a merge, a lapse or `slotLost`, and does not come back while there is no key source, when the feed stays stopped | `testNowShowsTheParkedRowWithSentCount`, `testTheRowGoesOnAMerge`, Task 13's `testALapseClearsTheParkedRow`, `testAPhoneWithNoKeySourceDoesNotParkAgain` | 16, 13 |
| F39 | A departed phone with no iCloud route has unechoed actions | On `relayLapsed`, `slotLost` or a move read on `switched` or the marker, each is withdrawn and listed, and then never applied. One the hub already applied returns as its echo. A refused delete keeps the row `sent` for the next pass. On return `skip_to` closes the gap | `testRelayOnlyLapseWithdrawsAndLists`, `testSlotLostWithASubscriptionWithdrawsAndLists`, `testAMoveReadOnARelayOnlyLinkListsUnechoed`, `TestDepartedPhoneActionNotAppliedOnceRowsAreCleared`, `TestReturnAfterDepartureSkipsTheGap` | 13, 17 |
| F39b | The hub reads an action in the moment before its withdrawal | The delete conflicts, the echo is taken, and the row is not listed, so Retry is not offered. If the hub's echo write fails on the deleted record, the row is listed while the hub applied it: today's 24-hour limit, unchanged | `testAnEchoMetOnWithdrawalIsAppliedNotListed`, `TestAWithdrawnActionIsNeverApplied` | 13 |
| F39c | A refused relay-only phone reaches 21 days, in the foreground, and a read shows the refusal stands | The link ends as Forget ends it: every key, the replica, Not delivered rows and the row go, recordings stay, the notice names the Mac. A running recording delays it. The hub's row usually stays, because the farewell is usually refused | `testRelayOnlyLinkEndsAt21DaysWithoutAMerge`, `testTheTermWaitsForARunningRecording`, `testAStoredKeyboxDoesNotStopTheTerm`, `testTheNoticeNamesTheMacAndTheNotSentCount` | 17 |
| F39d | The term is due and the account read fails, or the refusal ended while the app was closed, or the launch is in the background | A failed read waits, with no cap, and the term stays due. An ended refusal clears the mark and keeps the link. A background launch does nothing | `testAFailedReadKeepsTheTermDue`, `testTheFirstAnsweredReadEndsADueLink`, `testRenewedWhileClosedKeepsTheLink`, `testSlotBackWhileClosedKeepsTheLink`, `testABackgroundLaunchDoesNotRunTheTerm` | 17 |
| F40 | The hold reaches 14 days, including across a restart | One local rotation, offers and rows cleared; a phone really there recovers on the static epoch | `TestEmptyListHoldEndsAt14DaysRotatesOnceAndClears`, `TestNobodyPaysListNotEmptyEndsAt14Days`, `TestDay14RotationOnceAcrossRestart`, `TestRealPhoneAfterHoldEndRecovers` | 3 |
| F41 | `FORBIDDEN` with the subscription standing | The center reads the account: Mac in no slot is `slotLost`; Mac in a slot, or a failed read, does nothing | `testForbiddenWithTheMacGoneIsSlotLost`, `testForbiddenWithTheMacInASlotDoesNothing`, `testForbiddenWithAFailedReadDoesNothing` | 13 |
| F42 | Nobody pays, the list is not empty, a phone has no route, the hub writes into a slotted phone's mailbox | `ENTITLEMENT_INACTIVE` runs `lapse`, which moves the Mac, and the rotation clears every offer (ask #1087). The relay's signal does the same | `TestFirstRefusedWriteEndsG2sHold` | 13 |
| F43 | The relay's signal with a failed read, then a restart; or the phone renews meanwhile | Keys already cleared; the lapse stays in `lapse_pending` and is retried, or ends when the phone is listed paying past `LapseFresh`, and a new offer is then taken | The G2 lane's retry test; `TestLapseClearsKeysUnderEveryAnswer`, `TestLapseEndedByRenewalAcceptsANewOffer` | 13 |
| F44 | A phone's own request with a failed read | The Mac moves at once (rule 10, ask #1079); the rotation clears every offer; that phone's keys were cleared first | The G2 lane's test; `TestLapseClearsKeysUnderEveryAnswer` | 13 |
| F45 | As F42, or an empty list, with **neither a refused write nor a signal:** an idle hub, a lost signal, or `FORBIDDEN` | The Mac stays on the relay, serving nobody, with no end to that by itself. No rotation; the 14-day end clears the keys. A phone's own request, the signal if it comes, or the owner ends it | `TestEmptyListForbiddenWriteMovesNothing`, `TestIdleHubWithNoSignalStaysAndEndsAt14Days` | 13 |

## Writers and races

| Data | Writers | Who wins |
|---|---|---|
| `hub_epochs`, `epoch_relay_keys` | The daemon's housekeeping (age), its switcher (switch), its link center (unlink), or the CLI under `hub.lock` when no hub runs | One holder of `hub.lock`; `BEGIN IMMEDIATE` serialises the daemon's goroutines. The later transaction builds on the committed newest epoch |
| `devices.kx_offer`, `kx_offer_epoch` | Processor (`epoch_ack`), switcher (clear on leaving the relay, in `queueLapse`, in `ReaderLost`), link center (relink, unlink) | Highest ack epoch; a clear beats any offer read afterwards, because the ack's transaction reads `hub_meta.transport`, `relay_lapsed_at` and `lapse_pending` |
| `HubLinkKeys` (`hub.<id>`) | Link flow's merge, the upgrade's merge at the reader wait, the session's offer, the follower's clear or drop, re-link, unlink | New `PhoneKeyStore.updateHubLink` under the store's lock, so no read-modify-write is lost. **It returns nil and writes nothing when the link is gone**, so an unlink is never undone |
| `lapse_pending` in `hub_meta` | The switcher, `queueLapse` and `decideLapses`, under its lock; read by the processor in the ack's transaction | Writes are serial. An ack before the key is written may store an offer, and `queueLapse`'s clear, after that write, removes it. An ack after is refused |
| `relay_serving_nobody_since` in `hub_meta` | The runtime, on an answered account read; a rotation toward iCloud removes it | The newest answered read wins. The day-14 rotation writes nothing here: the new epoch's date ends it |
| `relayRefused` on `LinkRecord` | The follower sets; the session updates or clears on each answered account read; the follower clears `.macMoved` on a marker | Main-actor registry writes; the newest event wins, and a re-link starts without it |
| `epoch_ack_*` replica meta, `outbound_controls` | `ActionOutbox`'s chain | Serial; an unsent ack is replaced by a newer one |
| Alert material (`alert.<id>`) | `saveHubLink` only | The extension only reads it |
| Second phone | Its own `devices` row, relay-key rows and Keychain | Independent. Early retirement needs every phone's ack, with the 7-day cap |
| Second Mac on the phone | Its own `hub.<id>` item and replica | Independent |
| Desktop (second screen) | None; it reads through CLI JSON | — |

## Phone screens

**Two new states on Now and one notice, each with a frame drawn before any code (Task 0): the parked feed's row (Task 16, ask #1077, S58), the left-behind phone's banner (Task 17, S59, ask #1081), and the notice when a link ends at the term (Task 17, S60).** A row already `sent` has no state of its own to show: Waiting to send covers only queued rows after a stopped flush, so a parked feed would otherwise leave actions unanswered with nothing on screen. Rotation itself is automatic (relay design §7.5). Every other outcome reuses a state that already has text and a test:

- **Not delivered:** `ActionOutbox.refusedMessage`.
- **An uploader row:** its existing states.
- **A lapsed relay-only phone:** S47 and S53's "<Mac> needs Relay.", which is why S58b was dropped (ask #1081).
- **A locked phone's content-free notification:** `AlertOpener`'s fallback.
- **An unreadable keybox:** `readGrant`'s `.unreadable`, logged, never judged.
- **Past the term:** no row and no replica, so no new action and no Now for that Mac; S60 says why, once, with the "Not sent" count. The Not delivered rows go with the link. Everywhere else only the owner clears them, so this is a cost of ending the link, and it waits for the owner with that decision (Decisions).

Apart from S59 and S60, the reader transition has no new text: `hub_on_relay` shows what it shows today (Phase 4's S51 banner, Not delivered rows).


## Lanes

```
Task 1 ─┬─ Task 2 ─ Task 3 ─┬─ Task 4 ─┐
        │                   ├─ Task 5 ─┴─ Task 6 ─┐
        │                   └─ Task 14
        │                                         ├─ Task 13 ─ Task 11 ─ Task 12
        └─ Task 7 ─┬─ Task 8 ─┬─ Task 10 ─────────┘
                   └─ Task 9 ─┘
Task 15 (no dependency, PR A)
Task 0 (mockup only, needs no code and no other task; waits for nothing)
Task 8, Task 0 ─ Task 16 (PR A)
Task 13, Task 0 ─ Task 17 ─ Task 11 (PR C)
```

**No code starts until this plan is approved.** Task 0 is a mockup, not code, and may run first, so the owner can see the frames. Go and Kit are parallel lanes after Task 1. Each Swift lane gets its own worktree and simulator.

**PRs into `feature/relay-client-next`, in this merge order:** Plan = this plan and Task 0, from `relay-p5/plan`. A = Tasks 1, 7–10, 15, 16 (the phone first: its offers go to a hub that ignores them, the "new phone, old hub" row, and no Release build is on a relay route). B = Tasks 2–6, plus Task 14 (the hub now rotates weekly on the relay, and the phones on this branch already have Tasks 8 and 9). C = Tasks 13, 17, 11, 12. **PR B does not merge before PR A:** other lanes on this branch would otherwise run a weekly hub with phones that can lose uploads.

---

## Contract

### Task 0: Draw the frames

**Depends on:** none. It needs no code: the text is in Task 16, "A route-less phone left behind" and "The term".

**Files:**
- Modify: `docs/design/mockups/relay-client/index.html` (S58, S59, S60)

**Interfaces:** the strings the two tasks then pin.

- [ ] **Step 1:** Draw S58 (Now, the parked row, secondary tone, with one and with two sent actions) and S59 (Now, the calm card of ask #1040 with **Forget This Mac**) and S60 (the link notice), under `docs/design/desktop-style-guide.md`'s rules as the phone's mockups follow them.
- [ ] **Step 2: Commit on `relay-p5/plan`,** the plan's branch. `docs: mockup frames for the parked row, the left-behind banner and the term's notice (#1248)`. Tasks 16 and 17 compare with the mockup there, or on `feature/relay-client-next` once it merges.
- [ ] **Step 3:** The controller shows them to the owner. Tasks 16 and 17 start only after that.

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
- Create: `internal/hub/state/migrations/<next free number>_ephemeral_kx.sql` (G1 takes `00014`), `internal/hub/state/relaykeys.go`
- Modify: `internal/hub/state/devices.go` (`deviceColumns`, scan), `internal/hub/state/link.go`, `internal/hub/actions/control.go` (`epochAck`)
- Test: `internal/hub/state/state_test.go`, `internal/hub/state/columns_test.go`, `internal/hub/actions/control_test.go`, `internal/hub/state/swift_file_test.go` (a Swift-era file still migrates)

**Interfaces:**
- Produces, migration: `ALTER TABLE devices ADD COLUMN kx_offer BLOB`; `ADD COLUMN kx_offer_epoch INTEGER NOT NULL DEFAULT 0`; `ALTER TABLE hub_epochs ADD COLUMN on_relay INTEGER`; `CREATE TABLE epoch_relay_keys (epoch INTEGER NOT NULL, device_id TEXT NOT NULL COLLATE NOCASE, hub_pub BLOB NOT NULL, device_pub BLOB NOT NULL, sealed_keys BLOB NOT NULL, PRIMARY KEY (epoch, device_id))`.
- Produces, state: `Device.KXOffer []byte`, `Device.KXOfferEpoch uint32`; `SetKXOffer(tx, device string, pub []byte, epoch uint32) (bool, error)` (writes only when `epoch >= kx_offer_epoch`, `relay_lapsed_at IS NULL` and the device is not in `lapse_pending`; before G2 merges that key is simply absent); `ClearKXOffers(tx) error`; `ClearDeviceKX(tx, device string) error` (offer and relay-key rows); `InsertEpochRelayKeys(tx, EpochRelayKeys) error`; `(*Store).EpochRelayKeys(epoch uint32, device string) (EpochRelayKeys, bool, error)`; `EraseEpoch(tx, epoch uint32) error` (deletes its relay-key rows, sets `sealed_keys = x''`); `hub_epochs.on_relay INTEGER` (set when the epoch begins; NULL on older rows, which are never erased (ask #1066)).

- [ ] **Step 1: Failing tests.** `TestOlderAckDoesNotReplaceANewerOffer`, `TestBadOfferIsIgnoredAckStillCounted` (a short key, a non-curve value, an all-zero point), `TestOfferReadAfterSwitchAwayIsDropped` (`hub_meta.transport` is `cloudkit`: the ack counts, the offer does not), `TestEpochAckStoresOffer`, `TestRelinkClearsOfferAndRelayKeys` (`LinkDevice` with a new nonce), `TestOfferRefusedWhileLapsed`, `TestOfferRefusedWhileLapsePending`, `TestEraseEpochLeavesTheRowWithoutKeys`.
- [ ] **Step 2: Run** `go test ./internal/hub/state ./internal/hub/actions -run 'Offer|Ack|Relink|EraseEpoch'`. Expected: FAIL.
- [ ] **Step 3: Implement.** `epochAck` validates inside the processor, before `decide`: `ecdh.X25519().NewPublicKey` and a non-zero test exchange. In `decide`'s transaction it reads `MetaTransport`, calls `AckEpoch`, and calls `SetKXOffer` only on `relay`. A bad offer logs its class, never bytes. Relink: `LinkDevice`'s caller path clears when the nonce changes; put the clear in `LinkDevice` so no path misses it.
- [ ] **Step 4: Run** Step 2 and `go test ./internal/hub/state`. Expected: PASS.
- [ ] **Step 5: Commit.** `feat: hub stores phone key offers and per-epoch relay keys (#1248)`

### Task 3: Keyring: cadence, ephemeral rotation, lookup, recipient, erasure, echo sealing

**Depends on:** Task 2, and the re-check above

**Files:**
- Modify: `internal/hub/identity/keyring.go`, `internal/hub/runtime.go` (`housekeeping`), `internal/hub/switcher/announce.go` (`rotate`), `internal/hub/secure/record.go` (no new key logic; echoes use `InEpoch`), `internal/hub/actions/echo.go` and `control.go` (the sealer choice), `Makefile` (the `hub-staging` target)
- Create: `internal/hub/identity/rotation_staging.go` (`//go:build relaystaging`: `init` sets `relayRotationAge` to 10 minutes or to `WATCHTOWER_RELAYSTAGING_EPOCH` when set, read only in this file, and `PreviousEpochGrace` to 30 minutes)
- Modify: `internal/hub/hubtest/phone.go` (a twin phone with `current` and `offered`, `relay_kx` read, stored pairs)
- Test: `internal/hub/identity/keyring_test.go`, `internal/hub/runtime_test.go`, `internal/hub/actions/epoch_test.go`

**Interfaces:**
- Consumes: Task 1's `secure.EphemeralRelayKey`, Task 2's state functions.
- Produces:
  - `var relayRotationAge = 7 * 24 * time.Hour` (unexported), and `PreviousEpochGrace` becomes a `var`; only the tagged file changes them
  - `(*Keyring).RotateToward(r Reason, onRelay bool, also func(*sql.Tx) error) error` (`RotateWith` reads `MetaTransport` and calls it; the switcher passes the target)
  - `(*Keyring).RotateIfDue(also func(*sql.Tx) error) (bool, error)`
  - `(*Keyring).EraseExpired() (int, error)`: how many epochs it erased
  - `(*Keyring).PhoneEpoch(dev state.Device) (uint32, error)`: the acked epoch while retained if the phone has `kx_offer`, else 0 meaning current
  - `(*Keyring).AckedEpochRetained(dev state.Device) (uint32, error)`: the acked epoch while retained, else 0, for any phone (Task 5)
  - `(*Keyring).KeyboxKeysFor(device secure.ID) (wire.KeyboxKeys, error)`, replacing the shared `KeyboxKeys()`
  - `switcher.RotationBlocked(tx *sql.Tx) (bool, error)`: true while a switch record exists (over `recordTx`); the runtime's `also` uses it, since `identity` cannot import `switcher`
  - `state.MetaServingNobodySince`: the `hub_meta` key `relay_serving_nobody_since`, written by the runtime and read by `rotationDue`

- [ ] **Step 1: Failing tests:**
  - `TestKeyring_RotatesAt7DaysOnRelay`, with or without an offer
  - `TestRelayRotationAgeIs7DaysInTheDefaultBuild`, `TestRetentionIs7DaysInTheDefaultBuild`
  - `TestNoReleasePathSetsRelayStaging`: reads `Makefile`, `scripts/*.sh` and every `.github/workflows/*.yml`, `release.yml` above all, which builds the release with its own `-tags`; the tag appears only on the `hub-staging` target
  - `TestKeyring_RotatesAt90DaysOrSeqCap` stays as it is
  - `TestKeyring_RotatesOnceAfterALongClose`
  - `TestRotationDerivesRelayKeysForOfferedPhonesOnly`: phone A offered, phone B not. A's row exists and both sides derive equal keys; B uses `wt/relay/v1/`
  - `TestRotationErasesTheHubEphemeral`: nothing private stored; `sealed_keys` opens to 64 bytes under the AAD `wt/hub-epoch-relay/v1` ‖ hub_id ‖ epoch ‖ device_id
  - `TestRotationFailureMidwayWritesNothing`
  - `TestRotateToCloudKitClearsOffersAndDerivesNone`
  - `TestRotateIfDueSkipsWhileASwitchIsRunning`
  - `TestRotateIfDueSkippedWhileHeldOnRelay`, with a held CloudKit hub still rotating at 90 days as today
  - `TestNobodyPaysListNotEmptyNoRotation`, `TestRefusalAloneDoesNotSetServingNobody`, `TestFailedReadLeavesServingNobodyAsItWas`, `TestLeavingTheRelayClearsServingNobody`
  - `TestNoRotationWithNoReaderOnAnsweredList`, `TestRestartWithNoReaderMetaDoesNotRotate`, `TestUnknownListWithoutMetaRotates`
  - `TestEmptyListHoldEndsAt14DaysRotatesOnceAndClears`, `TestNobodyPaysListNotEmptyEndsAt14Days`, `TestDay14RotationOnceAcrossRestart`, `TestRealPhoneAfterHoldEndRecovers`, over `hubtest`'s twin phone
  - `TestKeyboxRecipientIsTheOfferForALinkedPhone`: a pending, revoked or refused device still gets `dev_kx`
  - `TestKeyboxKeysNameBothEpochs`
  - `TestStaticKeyboxOmitsAnEphemeralPreviousEpoch`
  - `TestEraseExpiredRemovesKeysAtRetentionEnd`: a retired epoch past `retire_after` opens to nothing, its relay rows are gone, `RelayKey` for it is refused by `AcceptsRelayEpoch`
  - `TestRotationWritesOnRelay`: `on_relay` is 1 for an epoch begun toward the relay, 0 toward iCloud, also on a switch
  - `TestEraseExpiredLeavesAnICloudEpoch`: an epoch with `on_relay` 0 or NULL keeps its `sealed_keys`
  - `TestNoEraseNoPragmaNoCheckpoint`: with no relay epoch to erase, on a CloudKit hub above all, housekeeping issues neither `secure_delete` nor `wal_checkpoint`
  - `TestICloudHubHousekeepingIsAsToday`: the sidecar's epoch rows are byte-identical after a retirement
  - `TestUnlinkRemovesOfferAndRelayKeys`
  - `TestLinkDuringRotationStartsStatic`
  - `TestLostAckStillRetiresAt7Days`
  - `TestEchoSealedInAckedEpochWhileKeyboxIsStuck`
  - `TestNeverOfferedPhoneSealsInCurrentEpoch`
  - `TestRelayKeyCacheDropsAnErasedEpoch`
- [ ] **Step 2: Run** `go test ./internal/hub/identity ./internal/hub/actions ./internal/hub -run 'Rotat|Keybox|Erase|Echo|Unlink|Lost|Link|Retention|Release|ICloudHub|NeverOffered|RelayKeyCache|NoErase|ServingNobody|EndsAt14|Day14|RealPhone'`. Expected: FAIL.
- [ ] **Step 3: Implement:**
  - **`rotationDue`** picks `relayRotationAge` when `MetaTransport` is `relay`, else `RotationAge`. With the mark set it is due only when `since + 14 days` has passed and the current epoch began before that.
  - **The day-14 rotation**, as "The end of the hold" states, derives nothing and clears every offer and row, in its transaction.
  - **`RotateToward`:** in the transaction, after `also`, inserting the epoch with `on_relay` set from `onRelay`: when `onRelay`, for each `devices` row with an offer draw `ecdh.X25519().GenerateKey`, derive, seal, insert; when not `onRelay`, `ClearKXOffers`. Log `epoch N begun (reason): k ephemeral, m static`, numbers only.
  - **`RelayKey`:** the sealed row if there is one, else today's derivation; cache as today, dropped by `EraseExpired`.
  - **`KeyboxRecipient`:** the offer for a linked row with `kx_offer`, else today's order.
  - **`housekeeping`:** `RotateIfDue` gets an `also` that returns `ErrSkipRotation` when the switch record is in progress (`switcher.RotationBlocked`), and the call is skipped when on the relay and `isHeld()` or `relay_serving_nobody_since` is set, except the day-14 rotation. The runtime writes that `hub_meta` key at each answered account read. After `RetireOld`, `EraseExpired`, and only if it erased something a best-effort `wal_checkpoint(TRUNCATE)`.
  - **Echoes and controls** for a phone use `Sealer.InEpoch(PhoneEpoch(dev))` when non-zero.
  - **`EraseExpired`** erases only epochs with `on_relay = 1` (ask #1066). It sets `PRAGMA secure_delete = ON` on its connection only when it has an epoch to erase.
  - **`make hub-staging`** builds the headless binary with `-tags relaystaging`, for the staging run only (ask #1077).
- [ ] **Step 4: Run** Step 2's command, then `go test ./internal/hub/identity ./internal/hub/actions ./internal/hub/switcher ./internal/hub/link`. Expected: PASS. Tests that move the clock past 7 days on a relay hub now see a rotation: those in `internal/hub` and the interop's switch scenario keep their meaning; a changed assertion is reported, not relaxed.
- [ ] **Step 5: Commit.** `feat: hub rotates relay epochs weekly with ephemeral keys (#1248)`

### Task 4: Per-phone keyboxes and the free phone

**Depends on:** Task 3, and the re-check above

**Files:**
- Modify: `internal/hub/link/grants.go`, `internal/hub/link/center.go` (config), `internal/hub/switcher/announce.go`, `internal/hub/switcher/accept.go`, `internal/hub/runtime.go` (the wiring)
- Test: `internal/hub/link/center_test.go`, `internal/hub/switcher/switcher_test.go`

**Interfaces:**
- Consumes: `KeyboxKeysFor`.
- Produces: `Center.Keyboxes()` (what the data zone carries, applying the rule) and `Center.KeyboxesAll()` (always keys for a linked phone); config `KeysInZone func(device string) bool`, where nil means true. The runtime sets it to "not on the relay, or (not lapsed, and a reader of the data zone or the reader list is still unknown)" over `devices.relay_lapsed_at` and `Transport.Readers()`.

- [ ] **Step 1: Failing tests.** `TestFreePhoneKeyboxOnRelayHasNoKeys`; `TestReaderListUnknownKeepsKeys` (availability first at startup); `TestPayingPhoneBecomesReaderGetsKeysNextCycle`; `TestSwitchToCloudKitGivesAFreePhoneItsKeys`; `TestStaleActionNoticeUsesKeyboxesAll`; `TestPhoneWithNoOfferStaysStaticAcrossRotations`; `TestSecondPhoneIndependentOffers`; `TestCloudKitHubKeyboxesAreAsToday`.
- [ ] **Step 2: Run** `go test ./internal/hub/link ./internal/hub/switcher -run 'Keybox|Free|Reader|Stale|PhoneWithNoOffer|SecondPhone'`. Expected: FAIL.
- [ ] **Step 3: Implement.** `linked[i].Keys` is built per phone under the center's lock. Every `transport_switched` (`announce`, the stale-action answer) reads `KeyboxesAll`. A linked phone with `Keys == nil` is ignored harmlessly by the phone's `mergeKeys`, as today. `notice`'s `kb.Keys == nil` skip stays for pending and refused rows.
- [ ] **Step 4: Run** Step 2 and `go test ./internal/hub/link ./internal/hub/switcher ./internal/hub/slices`. Expected: PASS.
- [ ] **Step 5: Commit.** `fix: a phone that cannot read the relay zone gets no epoch keys there (#1248)`

### Task 5: Alert pushes sealed in an epoch the phone holds

**Depends on:** Task 3

**Files:**
- Modify: `internal/hub/alerts/pusher.go`, `internal/hub/alerts_wiring.go`
- Test: `internal/hub/alerts/pusher_test.go`, `internal/hub/alerts_wiring_test.go`, `internal/hub/hubtest/phone.go` (opening at the acked epoch)

**Interfaces:**
- Consumes: `Sealer.InEpoch`; the acked-while-retained rule (`Keyring.AckedEpochRetained(dev)`, for every relay phone, offering or not).
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
- Produces: tests, plus a content-free log line for each republish after a rotation: `hub: rotation republish: complete|interrupted, N records, B asset bytes, D s`. A next rotation that wipes the hashes first writes `interrupted`, with the counts so far. **The log line is an instrument, not the measurement.** On the fake transport it proves only that the count is right; "Measuring the cost" says how real numbers get taken.

- [ ] **Step 1: Failing tests.** `TestRuntime_RestartAfterRotationRepublishesOnce`. `TestRotationWhileRelayDownPublishesOnReturn`. `TestRuntime_ThreeRotationsTwoPhones`: one offered, one static, each opens slices, echoes and controls in every epoch. `TestRotationRepublishLogsCounts`, with no names or bytes in the line (`logcanary`-style check). `TestRotationRepublishInterruptedSaysSo`. `TestPermissionAnswerAcrossARotationAppliedOnce`, `TestSessionInterruptAcrossARotationExpires` (PROJ-21). `TestLostResendFromFilledByResendingUnechoed`.
- [ ] **Step 2: Run** `go test ./internal/hub -run 'Runtime_|RotationWhile|RotationRepublish|PermissionAnswer|SessionInterrupt|LostResendFrom'`. Expected: FAIL.
- [ ] **Step 3: Implement** the log line in the publisher's cycle report path, only for the cycles after a hash wipe, until the wiped kinds are all saved or the next wipe.
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
  - `HubLinkKeys.merging(_ keys: KeyboxKeys, identity: DeviceIdentityKeys, hubID: UUID, deviceID: UUID, now: Date) throws -> KeyboxMerge` (`keys: HubLinkKeys`, `droppedNewestPair: Bool`), which throws `KeyboxKeysError.unknownEphemeral`
  - `HubLinkKeys.withOffer() -> (HubLinkKeys, publicKey: Data)`, a no-op when one exists
  - `HubLinkKeys.clearingEphemeral() -> HubLinkKeys` (the two private keys go; stored pairs stay)
  - `HubLinkKeys.droppingEphemeral() -> HubLinkKeys` (stored pairs go too: the link is static for every epoch), only on an opened `hub_on_relay`
  - `PhoneKeyStore.updateHubLink(_ hubID: String, _ change: (HubLinkKeys) throws -> HubLinkKeys) throws -> HubLinkKeys?`
  - `SecureTransportError.epochKeysGone`, `.epochKeysPending`
  - `SecureKeyProvider.keyboxRecipients() throws -> [Curve25519.KeyAgreement.PrivateKey]`

- [ ] **Step 1: Failing tests:**
  - `testOldItemDecodesWithNoEphemeralState`
  - `testMergeDerivesPromotesAndErases`: after the merge `currentKX` is the old offer, `offeredKX` nil, the older private key nowhere in the encoded item
  - `testMergeDerivesThePreviousEpochTooWhenMissing`
  - `testMergeWithoutRelayKXIsStatic`, and `testAStaticKeyboxDropsThatEpochsPairAndOffersAgain`: a held pair for that epoch goes, the offer stays, and `droppedNewestPair` is true
  - `testAStaticKeyboxWithNoPairReportsNothing`; `testRepeatedMergesReportOnce`
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
  - `ReplicaStore.epochAckDue(_ epoch: UInt32, nextKX: Data?) throws -> Bool` (new meta key `epoch_ack_kx`); `ActionOutbox.offerAgain()` clears it
  - `ActionOutbox.requeueUnechoedAfterDrop() async throws -> Int`
  - `SecureTransport.keyboxWaitCap: TimeInterval = 3600`, `SecureTransport.waitsForKeybox: @Sendable () -> Bool` (true by default; Task 13 sets it)
  - `RelayFeed.resumeIfParked()`; `relay_feed_parked_since` in replica meta (Task 16 reads it)

- [ ] **Step 1: Failing tests:**
  - `testAKeyboxSealedToTheOfferOpens`, `...ToCurrentOpens`, `...ToDevKXOpens`
  - `testNoCandidateOpensIsNotALockError`, with `.locked` still thrown as `keysUnavailable`
  - `testASignatureFailureIsNotRetriedOnOtherKeys`
  - `testAnEchoAboveTheNewestEpochWaitsForTheKeybox`: `changes` throws `keysUnavailable`, the token is kept, the replay after merge opens
  - `testARotationDoesNotSweepTheReplica`, once #1497 is in the branch
  - `testARelayRecordInAGoneEpochIsDroppedNotReplayed`: `.unopenable("epochGone")`, the batch finishes, the token moves
  - `testADroppedEchoQueuesTheUnechoedAgain`: the flush overwrites by sim rule 3
  - `testADroppedResendFromRecoversByResending`
  - `testADroppedSwitchIsFollowedByTheMarker`
  - `testTwoDropsInABatchRequeueOnce`
  - `testAPendingEpochParksAfterTheCapAndLosesNothing`: a `resend_from` behind the pending record is read, in order, after the merge
  - `testNoKeySourceStopsTheFeedSilently`: `waitsForKeybox` false: token kept, no parked mark, no fetch until a merge, a foreground or a launch
  - `testAMergeClearsTheWaitSince`; `testResumeIfParkedFetchesAgain`; `testParkingWritesTheMetaKeyAndAResumeRemovesIt`
  - `testAnOutboxRowPastItsKeyIsNotDelivered`: `reseal` returns nil on `epochKeysGone`
  - `testALostAckResendsTheOfferAtTheNextRaise`
  - `testTheSameEpochWithANewOfferIsDue`; `testTheSameEpochSameOfferIsNotDue`; `testALowerEpochIsNeverDue`
  - `testAnUnsentAckIsReplacedKeepingTheNewestOffer`
  - `testResealUsesStoredKeysForTheOldEpochAndTheCurrentForTheNew`
  - `testGoSealedKeyboxWithRelayKXOpens`
  - `testAHubThatNeverConsumesStaysStatic`
- [ ] **Step 2: Run** `make kit-test FILTER='SecureTransportTests|ActionOutboxOrderedTests|RelayFeedTests|KeyboxTests|GoSealedEnvelopeTests'`. Expected: FAIL.
- [ ] **Step 3: Implement.** The signature is verified once, before any HPKE attempt. `openRelay` maps `epochKeysGone` to `.unopenable("epochGone")` in the phone branch only. `epochKeysPending` throws as `keysUnavailable` does (token kept) until `relay_wait_since` is `keyboxWaitCap` old; then the feed parks. An `epochGone` outcome makes the feed call `requeueUnechoedAfterDrop` once for the batch. `queueEpochAck` puts `nextKX` (base64url) on the payload. An ack sealed with the old epoch's stored keys is fine: the hub retains it.
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
- [ ] **Step 3: Implement** at the point `saveSealed` reads the stored envelope: parse the header epoch, compare with `currentEpoch()`, reseal, persist before saving. The hub's window for the old epoch is not consulted: the phone cannot know it. This runs only on a relay route or a link that has moved routes (ask #1066; a new init flag, `resealsOlderEpochs: @Sendable () -> Bool`). `testAnICloudOnlyLinkSendsItsBytesUnchanged` pins that.
- [ ] **Step 4: Run** Step 2. Expected: PASS. `make lint-swift`.
- [ ] **Step 5: Commit.** `fix: a recording sealed before a rotation is resealed, not lost (#1248)`

### Task 10: App wiring

**Depends on:** Tasks 8, 9

**Files:**
- Modify: `WatchtowerMobile/Sources/Features/Onboarding/LinkingViewModel.swift` (`mergeKeys`), `WatchtowerMobile/Sources/App/Hubs/HubSession.swift` (`acknowledgeNewestEpoch`, `keysMerged`), `WatchtowerMobile/Sources/App/Hubs/TransportFollower.swift`, `WatchtowerMobile/Sources/App/AppRoot.swift` (`mergeSwitchKeys`, the host seam)
- Test: `WatchtowerMobile/Tests/LinkingViewModelTests.swift`, `TransportFollowerWiringTests.swift`, a new `EphemeralRotationWiringTests.swift`

**Interfaces:**
- Consumes: Tasks 7–9.
- Produces: `mergeKeys` goes through `keys.updateHubLink` and `merging`; `.unknownEphemeral` logs once and returns false. `droppedNewestPair` reaches `HubSession.keysMerged(newestEpochRaised:droppedNewestPair:)`, which calls `outbox.offerAgain()` and acknowledges.

- [ ] **Step 1: Failing tests:**
  - `testARelayRoutePhoneOffersOnEveryRaise`
  - `testKeysMergedWakesAParkedFeed`, and a foreground
  - `testAnICloudRoutePhoneNeverOffers`: a guard for "CloudKit crypto does not change"; the control's bytes have no `next_kx`
  - `testAnOfferNotYetAckedGoesAtBoot`
  - `testAFailedSaveKeepsTheOldLinkAndRetries`
  - `testADroppedPairSendsOneAckAcrossRepeatedMerges`, at each fetch and unlock
  - `testFollowingToICloudClearsEphemeralState`, after the keybox merge, in the follower's crash-safe order
  - `testFollowingToRelayOffersAfterTheMove`
  - `testARaiseKicksTheUploader`
  - `testUnlinkDuringAMergeDoesNotResurrectTheLink`
  - `testNoNewScreenStateOnAnUnreadableKeybox`: `readGrant` is `.unreadable`, the link row unchanged
  - `testTwoHubsKeepSeparateOffers`
- [ ] **Step 2: Run** `make mobile-test SIM='<yours>' MOBILE_FILTER='EphemeralRotationWiringTests|TransportFollowerWiringTests'`. Expected: FAIL. On "missing required module GRDBSQLCipher": `make mobile-build SIM='<yours>'`, then rerun.
- [ ] **Step 3: Implement.** `acknowledgeNewestEpoch`: on route `.relay`, `updateHubLink { $0.withOffer() }` first (the private key is saved before any ack exists), then `enqueueEpochAck(epoch:nextKX:)`; on any other route `nextKX: nil`. `keysMerged` calls `uploader.epochRaised()` on a raise and `feed.resumeIfParked()`; so does the return to the foreground. The guard files `PermissionAllowRuleTests`, `PermissionCardTests` and `SessionInputWiringTests` stay untouched.
- [ ] **Step 4: Run** Step 2 and `make mobile-test SIM='<yours>' MOBILE_FILTER='LinkingViewModelTests|RelayLinkingTests'`. Expected: PASS. `make lint-swift`.
- [ ] **Step 5: Commit.** `feat: the phone runs relay key rotation (#1248)`

---

## Together

### Task 11: Kit ↔ Go hub interop on the stand

**Depends on:** Tasks 6, 10, 13, 17

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
  4. Three rotations with the phone away, an action held in its outbox (`created_at` on the hub's moved clock, within the age window). `resend_from`, resealed under the same `action_seq`, applied once. A sealed recording in the same state is resealed and received once. The mailbox feed is not jammed. **Then one echo left in a gone epoch:** the phone drops it, resends, its write overwrites under sim rule 3, and the real hub answers it as a repeat.
  5. Switch to iCloud in the middle of an outstanding offer. New epoch static, offer cleared on both sides, an action applied. Back to the relay after the 5-minute rule: a static epoch, then ephemeral after one more rotation.
  6. A second, static test phone (no offers) stays linked through steps 2–3 and opens every epoch.
  7. A paying phone not linked to the hub, a linked phone out of its slot: **the real relay answers that phone `FORBIDDEN` on a save and a read, and a slotted, non-paying one `ENTITLEMENT_INACTIVE`;** the relay lets it delete its own record with no slot; the phone reaches `slotLost`, withdraws and lists its unechoed actions; the hub stays on the relay and clears that phone's keys. Then an empty list with a route-less phone: the hub's mailbox write gets `FORBIDDEN`, the hub stays and does not rotate. Then a slotted, non-paying phone with a route-less one beside it: the hub's mailbox write gets `ENTITLEMENT_INACTIVE`, and the Mac moves (ask #1087).
  8. Two paying phones; one lapses on the stand's `/dev/entitlement` with the hub staying on the relay. Its offer and rows are gone, it reads `hub_on_relay` and leaves, the other phone rotates. It pays again 15 moved days later: keybox merged at the reader wait, request accepted, followed, new offer, ephemeral at the next rotation.
- [ ] **Step 2: Run** `make relay-interop-kit-hub RELAY=<relay checkout>`. Expected: FAIL at the first new assertion until the steps above are wired, then PASS.
- [ ] **Step 3: Run** `go test -tags interop ./internal/hub -run TestInterop_KitPhone` and `make kit-test FILTER=KitGoHubInteropTests` if the script's CI mode needs them separately. Expected: PASS.
- [ ] **Step 4: Commit.** `test: Kit and Go hub rotate relay keys on the stand (#1248)`

### Task 12: Docs and the gate

**Depends on:** Task 11

**Files:**
- Modify: `docs/features/relay-client.md` (a "Phase 5" section, the Epochs section, v1 limits), `docs/features/go-hub.md`, `docs/features/mobile-companion.md`, `docs/superpowers/specs/2026-10-31-hub-phone-protocol-design.md` (§4.2 epochs, §7.7 for relay links, Decisions with ask #1066's frozen-bytes approval, §11), `docs/superpowers/specs/2026-10-29-relay-client-design.md` (§1's "At launch, relay links keep today's key scheme", §13 row 5 and the line "Launch for users waits for Phases 0a and 1–4", all to with-launch per ask #1066; the Decisions "7-day rotation … comes after launch" and "Rotation keyboxes on the relay travel in the phone's mailbox", amended to cite ask #1066: switch keyboxes stay in the mailbox, timer rotation keyboxes go in the data zone), `docs/superpowers/specs/2026-10-31-go-hub-design.md` (§3's non-goal, citing ask #1067), `docs/superpowers/plans/2026-11-03-relay-client-phase-4.md` (Launch conditions: this plan's six, including the staging run and its dependency on Owner-only steps and M1–M10), this plan's Decisions
- Create: `internal/hub/release_guard_test.go`
- Check: `grep -rn -i 'rotat\|epoch\|every 90' docs/guide` (no page states the key schedule today, so no change is expected for it; a hit means a same-PR fix under `docs/guide/WRITING.md`), and `grep -rln 'Waiting to send\|Not delivered' docs/guide`: the page that explains Now's outbox group gets the parked row, the left-behind banner, with the limit that paying alone may not bring a phone back, and the term: the link ends after 21 days without Relay, its history on this phone and unsent actions go, and it must be linked again, in the same PR, under `TestRelayGuideSaysNotYet`'s rule for Relay passages, `docs/inventory/workbench.md` PROJ-16's note and PROJ-21 (both stay true; no PROJ text changes)

**Interfaces:** none.

- [ ] **Step 1:** Write the docs, including the honest threat text, with no fixed bound. Add `TestNoReleasePhoneBuildSetsRelayOrigin` (launch condition 4), run it with `go test ./internal/hub -run ReleasePhone`.
- [ ] **Step 2: Gate (controller).** `make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`, `make mobile-test SIM='<yours>'`, `make relay-interop-kit-hub RELAY=<relay checkout>`. Expected: exit 0 for each; a known flake is named, not skipped.
- [ ] **Step 3: Commit.** `docs: relay key rotation (#1248)`
- [ ] **Step 4: Staging run, for launch.** See "The staging run". It does not block merging PR C into the branch; it blocks launch ("Launch condition").

### Task 13: Losing and regaining reader status

**Depends on:** Tasks 4, 8, 10; G1 and G2 merged into the branch; the re-check above

**Files:**
- Modify: `internal/hub/switcher/entitlement.go` (`queueLapse`), `internal/hub/switcher/departed.go` (new: `checkDeparted`, `ReaderLost`), the switcher's poll, its `Config` (`Slotted`, with G2's `ErrNotFresh`), `internal/hub/state/devices.go` if `ClearDeviceKX` needs a transaction form
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Secure/SecureTransport.swift` (the static exception), `Relay/TransportFollowerPolicy.swift` (a `dropEphemeral` command on an opened `hub_on_relay`; `withdrawUnechoed` on `slotLost`, and on `relayLapsed` with no other route; a new `FollowerState.hasOtherRoute`), `WatchtowerMobile/Sources/App/Hubs/TransportFollower.swift`, `SideMailboxReader.swift` and `RelayFeed`'s side read (the pending rule), `RelayUpgrade.swift` (`awaitReader`), `WatchtowerMobile/Sources/App/Relay/RelayAccountCenter.swift` (`.forbidden`, `SLOT_REMOVED`), `HubSession.swift` (`relaySlotLost`, `waitsForKeybox`), `WatchtowerKit/Sources/WatchtowerSync/Relay/ActionOutbox+Ordered.swift`, `WatchtowerMobile/Sources/App/LinkStore.swift`
- Test: `internal/hub/switcher/switcher_test.go`, `internal/hub/runtime_test.go` (the idle hub, through `housekeeping`), `internal/hub/actions/device_record_test.go`, `SecureTransportTests.swift`, `TransportFollowerWiringTests.swift`, `RelayUpgradeWiringTests.swift`, `WatchtowerMobile/Tests/RelayAccountCenterTests.swift`; Kit twin in `WatchtowerHostedRelayTests/Sim/SimPhone.swift` runs the new command

**Interfaces:**
- Consumes: Task 2's `ClearDeviceKX`, Task 4's `KeysInZone`, Task 7's `droppingEphemeral`, Task 8's mapping; G2's `queueLapse` and `lapse_pending`.
- Produces: `(*Switcher).checkDeparted(ctx)`, `(*Switcher).ReaderLost(device string) error`; `FollowerCommand.dropEphemeral`; `FollowerInput.slotLost`; `HubSession.relaySlotLost()`; `ActionOutbox.withdrawUnanswered(before:reason:)`, today's with a `reason` parameter; `LinkRecord.relayRefused` (`since`, `cause`: `.lapse`, `.slot`); `RelayUpgrade`'s keybox merge through `RelayUpgradeHost.mergeKeybox(hubID:) async -> Bool`.

- [ ] **Step 1: Failing tests.** Go:
  - `TestLapseWithAnotherPayerClearsOfferAndRows`: afterwards `RelayKey` for every epoch is static and `KeyboxRecipient` is `dev_kx`
  - `TestLapseClearsKeysUnderEveryAnswer`: another phone pays, an unlinked one pays, nobody pays, a failed read on the phone's own request and on the relay's signal, and on a headless host with no CloudKit
  - `TestRotationAfterLapseDerivesNoRowForThatPhone`
  - `TestLapseAndRotationEitherOrder`
  - `TestLapseRestartKeepsKXCleared`
  - `TestHubOnRelaySealedStaticAfterLapse`
  - `TestReaderLostAfterTwoReadsClearsKeys`, `TestOneMissingReadChangesNothing`, `TestAnUnansweredReadCountsAsNothing`, `TestReaderLostIgnoresAPhoneWithNoEphemeralState`, `TestReaderLostNeverMovesTheMac`, `TestReaderLostMarksARouteLessPhoneLapsed`
  - `TestDepartedUnlinkedPayerMacStaysKeysCleared`, `TestDepartedPhoneNoRouteMacStaysKeysCleared`, `TestDepartedRelayOnlyPhoneReturnsAndOffersAgain`
  - `TestReturnAfterAnEmptyListOpensTheKeybox`, before day 14; `TestFirstRefusedWriteEndsG2sHold`, `TestEmptyListForbiddenWriteMovesNothing`, `TestIdleHubWithNoSignalStaysAndEndsAt14Days`; `TestLapseEndedByRenewalAcceptsANewOffer`
  - `TestDepartedPhoneActionNotAppliedOnceRowsAreCleared`, `TestAWithdrawnActionIsNeverApplied`, `TestReturnAfterDepartureSkipsTheGap`
  - `TestEmptyListNoRouteMacStaysKeysHeld`, `TestAllRoutesNobodyPaysG2MovesDepartedSkips`, `TestUnknownReadMovesAndClearsNothing`, `TestRestartRestartsTheDepartureCount`
  - `TestNoPayerMoveClearsOffers`
  - `TestDeviceRecordInARetiredEpochDroppedRewriteApplies`, `TestFarewellInARetiredEpochLeavesTheRowAndStopsKeys`
  - `TestLapsedPhoneKeyboxHasNoKeysAndIsRepublished`
  - `TestOldAckInTheLapseWindowLeavesHubOnRelayStatic`: `queueLapse` with a failed read, an old `epoch_ack` read, then the read answers
  - `TestRenewedPhoneGetsKeysInZoneThenOffersAgain`, `TestRenewedPhoneOffersAgain`

  Kit and phone:
  - `testHubOnRelayOpensOverAStaleEphemeralState`, for each row of the key table
  - `testAStaticEchoIsRefusedOnAnEphemeralLink`
  - `testTheSideReaderReadsPastAPendingEpochAndKeepsItsToken`: owed echoes ahead of `hub_on_relay` in the iCloud mailbox do not stop it, and are read after the merge
  - `testAResendFromInTheICloudMailboxIsCoveredByTheFollow`
  - `testRelayOnlyLapseWithdrawsAndLists`: reason `.refused`, route stays relay, keys kept
  - `testSlotLostWithASubscriptionWithdrawsAndLists`, `testSlotLostWithARouteWithdrawsMovesAndLists`, `testARefusedDeleteKeepsTheRowSent`, `testAnEchoMetOnWithdrawalIsAppliedNotListed`
  - `testAPhoneWithNoKeySourceDoesNotParkAgain`: lapse, then a record above the newest epoch, past the cap: no parked mark, no row, no refetch
  - `testForbiddenWithTheMacGoneIsSlotLost`, `testForbiddenWithTheMacInASlotDoesNothing`, `testForbiddenWithAFailedReadDoesNothing`
  - `testALapseClearsTheParkedRow`, for `relayLapsed`, `withoutHub` and `slotLost`
  - `testRelayLapsedQueuesTheRequestAndKeepsKeys`, `testSlotLostKeepsKeys`, `testHubOnRelayDropsEphemeral`; `testAPlainFollowToICloudKeepsStoredPairs`
  - `testSlotLostThenSlotBackBeforeTheHubActsKeepsTheLink`: the keybox sealed to the offer still opens, keys intact
  - `testAPhoneBackOnICloudWithTheHubOnRelayStaysStatic`
  - `testAwaitReaderMergesTheKeyboxBeforeTheRequest`, `testAwaitReaderWithNoKeysYetKeepsWaiting`, `testAwaitReaderLimitStillEndsInReaderNotConfirmed`
- [ ] **Step 2: Run** `go test ./internal/hub ./internal/hub/switcher ./internal/hub/link ./internal/hub/actions -run 'Lapse|ReaderLost|Renewed|OneMissing|Unanswered|NoPayer|OldAck|FirstRefused|IdleHub|Withdrawn|Departed|EmptyList|ReturnAfter|AllRoutes|UnknownRead|RestartRestarts|HubOnRelay|RotationAfter|DeviceRecord|Farewell'`, `make kit-test FILTER='SecureTransportTests|TransportFollowerPolicyTests|ActionOutboxOrderedTests|RelaySimSwitchTwins'`, `make mobile-test SIM='<yours>' MOBILE_FILTER='TransportFollowerWiringTests|RelayUpgradeWiringTests|RelayAccountCenterTests|EphemeralRotationWiringTests'`. Expected: FAIL.
- [ ] **Step 3: Implement** as "Losing and regaining reader status" states. The clear sits in `queueLapse`, before any read, so an undecided lapse has it too and a retry finds nothing to clear, because `SetKXOffer` refuses throughout. The outcomes table is the specification of `checkDeparted`; the 14-day rule is Task 3's, with its tests, and `TestIdleHubWithNoSignalStaysAndEndsAt14Days` here pins that it holds beside G2 and `checkDeparted`. The two-read rule is in memory, like G2's: a restart starts counting again, which only delays. If `fingerprint` does not have ask #1072's rule at the re-check, report it; do not edit G2's check here.
- [ ] **Step 4: Run** Step 2, then `make lint-diff` and `make lint-swift`. Expected: PASS, no new issues.
- [ ] **Step 5: Commit.** `fix: a phone that stops being a reader leaves cleanly and can come back (#1248)`

### Task 14: Rotation visibility

**Depends on:** Task 3

**Files:**
- Modify: `cmd/hub_link.go` (`hub status`, `hub phones`, both read-only over `state.OpenReadOnly`), `internal/hub/runtime.go`
- Test: `cmd/hub_link_test.go`

**Interfaces:** `hub status --json` adds `epoch`, `epoch_age_days`; `hub phones --json` adds `keys` = `"ephemeral"|"static"` per phone (a relay-key row in the current epoch). No key material; no names beyond what these verbs already print.

- [ ] **Step 1: Failing tests.** `TestHubPhonesJSONKeysPinned`, `TestHubStatusShowsEpochAge`, `TestStuckRotationLogsOncePerDay`: a running relay hub, epoch older than 14 days.
- [ ] **Step 2: Run** `go test ./cmd -run 'HubPhones|HubStatus'` and `go test ./internal/hub -run StuckRotation`. Expected: FAIL.
- [ ] **Step 3: Implement** the additive keys and the log line.
- [ ] **Step 4: Run** Step 2. Expected: PASS.
- [ ] **Step 5: Commit.** `feat: hub shows epoch age and each phone's key scheme (#1248)`

### Task 15: The phone's traffic and wake readings

**Depends on:** none

**Files:**
- Modify: `WatchtowerKit/Sources/WatchtowerHostedRelay/Transport/HostedRelayTransport+Pull.swift`, `HostedRelayTransport.swift` (where the relay's `fetchForPush` runs)
- Create: `WatchtowerKit/Sources/WatchtowerHostedRelay/Transport/RelayTrafficMeter.swift`
- Test: `WatchtowerKit/Tests/WatchtowerHostedRelayTests/HostedRelayTransportTests.swift`

**Interfaces:** `RelayTrafficMeter`, a counter of bytes per `changes` page and per download and of `fetchForPush` calls, compiled only under `#if DEBUG`. It logs one `relay traffic: pages N, bytes B, downloads D, download bytes E, wakes W` line per pass, numbers only, at notice level. A parked or stopped feed adds nothing to it, which `testAStoppedFeedAddsNoPages` pins.

- [ ] **Step 1: Failing tests.** `testTheMeterCountsPagesDownloadsAndWakes` over `FakeHostedRelay`; `testTheMeterLineHoldsNumbersOnly`; `testAStoppedFeedAddsNoPages`.
- [ ] **Step 2: Run** `make kit-test FILTER=HostedRelayTransportTests`. Expected: FAIL.
- [ ] **Step 3: Implement** behind `#if DEBUG`, so a Release build has no meter.
- [ ] **Step 4: Run** Step 2. Expected: PASS. `make lint-swift`.
- [ ] **Step 5: Commit.** `test: a debug meter for the phone's relay traffic and wakes (#1248)`

### Task 16: Now says when the feed is parked

**Depends on:** Task 8; Task 0, seen by the owner

**Files:**
- Modify: `WatchtowerMobile/Sources/Features/Now/NowModel.swift`, `NowView.swift`, `WatchtowerMobile/Sources/App/Hubs/OutboxBacklog.swift`, `WatchtowerMobile/Sources/App/DemoSeed+Outbox.swift`, `WatchtowerMobile/Tests/ScreenshotTourTests.swift` (S58, `make mobile-shots SHOTS_ONLY=relay-phase5`), `Makefile` (that value)
- Test: `WatchtowerMobile/Tests/NowWiringTests.swift`

**Interfaces:**
- Consumes: `relay_feed_parked_since` in replica meta (Task 8), `ReplicaStore.outboxCounts`, which gains `sent`; the hub's display name.
- Produces: `NowOutboxRows.parked: NowParkedRow?` with `title`, `detail`, and a `ToneUse` with `.secondary`, `.info`, never orange. The strings live in the model, for the hub on screen, and must be true whether the Mac is closed, online with its keybox refused (F21), or has cleared this phone (F26). S58: "Waiting for new keys from <Mac>", under it "2 actions have no answer yet. They finish once it sends them. If this lasts, open Watchtower on the Mac." ("1 action has"; the first two sentences go with none sent.) A phone with no key source never shows it (Task 13's `waitsForKeybox`: its feed stops with no mark), so S58's advice is always worth following.

- [ ] **Step 1: Failing tests.** `testNowShowsTheParkedRowWithSentCount`, with both strings exact and the Mac's name; `testOneSentActionReadsSingular`; `testNoSentActionsOmitsTheCountSentences`; `testTwoMacsEachNameTheirOwn`; `testTheRowGoesOnAMerge`; `testNoParkedRowWhileReplayingUnderTheCap`; `testParkedRowUsesNoOrange` beside `OrangeToneTests`; `testParkedAndWaitingToSendShowTogether`. Screenshot frame S58.
- [ ] **Step 2: Run** `make mobile-test SIM='<yours>' MOBILE_FILTER=NowWiringTests`. Expected: FAIL.
- [ ] **Step 3: Implement** in the model, tones only. Task 8 writes the meta key on parking and removes it on a resume that opens.
- [ ] **Step 4: Run** Step 2, then `make mobile-shots SHOTS_ONLY=relay-phase5 SIM='<yours>'` and compare with the mockup. `make lint-swift`. Expected: PASS.
- [ ] **Step 5: Commit.** `feat: Now says when actions wait for the Mac's new keys (#1248)`

### Task 17: The left-behind phone's banner and the term

**Depends on:** Task 13; Task 0, seen by the owner; the owner's answer in ask #1091 on how the term ends

**Files:**
- Modify: `WatchtowerMobile/Sources/App/Relay/RelayAccountCenter.swift` (a read that sets the mark, and the term's read), `WatchtowerMobile/Sources/App/LinkStore.swift` (the `.macMoved` cause), `WatchtowerKit/Sources/WatchtowerSync/Relay/TransportFollowerPolicy.swift` (a command, on `slotLost`, `switched` or `marker` toward iCloud with no other route), `WatchtowerMobile/Sources/App/Hubs/TransportFollower.swift`, `WatchtowerMobile/Sources/Features/Now/RelayBannerModel.swift`, `WatchtowerMobile/Sources/Features/Onboarding/LinkNotice.swift`, `LinkingViewModel.swift` (`unlinkRow` at the term), `WatchtowerMobile/Sources/App/Hubs/HubSession.swift` (the check in the foreground), `WatchtowerMobile/Tests/ScreenshotTourTests.swift` (S59, S60). The banner is the plain, calm card of ask #1040, not amber
- Test: `WatchtowerMobile/Tests/RelayBannerModelTests.swift`, `TransportFollowerWiringTests.swift`, `LinkingViewModelTests.swift`, `RelayAccountCenterTests.swift`, `internal/hub/link/center_test.go`

**Interfaces:** `FollowerCommand.markRefused(.macMoved)`, with `withdrawUnechoed`; `RelayBannerModel` takes `relayRefused`, ahead of `needsRelay`. `LinkNotice.relayEnded(macName:notSent:)`. S59's and the notice's strings live in the model.

- [ ] **Step 1: Failing tests.** `testLinkGoneBeatsNeedsRelayAndSubscribe`, with the exact string and **Forget This Mac**; `testAPayingPhoneWithItsSlotGoneShowsLinkGone`; `testAMarkerTowardICloudOnARelayOnlyLinkDoesNotMoveTheRoute`; `testAMoveReadOnARelayOnlyLinkListsUnechoed`, for `switched` and the marker, a move made by another phone; `testForgetWorksWhenTheRelayRefusesTheFarewell`: the row and local data go, the unsent farewell and `remove_slot` retry at launch and block nothing; `testLinkGoneBannerUsesNoOrange` beside `OrangeToneTests`; `testAnOldEchoClearsNothing`; `testTheSwitchNoticesKeyboxIsNotMergedOnARelayOnlyLink`; `testRelayOnlyLinkEndsAt21DaysWithoutAMerge`; `testABackgroundLaunchDoesNotRunTheTerm`: nothing ends and the next foreground ends it with S60 on screen; `testRenewedWhileClosedKeepsTheLink`, `testSlotBackWhileClosedKeepsTheLink`: the read clears the mark on day 22; `testAFailedReadKeepsTheTermDue`, `testTheFirstAnsweredReadEndsADueLink`: weeks of failed reads erase nothing, and the first answer that shows the refusal ends it; `testAMarkerWaitingAtTheTermKeepsTheLink`; `testTheTermWaitsForARunningRecording`, `testALapseEndStopsTheTerm`, `testAnAnsweredSlotDoesNotStopTheTermOfALapse`, `testAnAnsweredSlotStopsTheTermOfASlotLoss`; `testASlotBackWithTheSubscriptionEndedKeepsTheTerm`: the cause becomes `.lapse` and `since` stays; `testAStoredKeyboxDoesNotStopTheTerm`: no merge clears the mark; `testAnAnsweredSlotAllowsParkingAgain`: paying with the slot clears the mark, so `waitsForKeybox` is true again; `testARoutedLinkHasNoTerm`; `testTheNoticeNamesTheMacAndTheNotSentCount`; `testARecordingProblemWinsOverTheTermsNotice`; `testTheTermSendsTheFarewellAndRemovesTheSlot`, with both refused and retried at launch; `testAStaleKeyboxDoesNotClearMacMoved`; Go `TestRelinkAfterTheTermClearsOfferAndRelayKeys`, a re-link after the phone's end; `testAMarkerTowardTheRelayClearsMacMoved`; `testARelinkStartsWithoutLinkGone`; `testLapsedPastTheReadWindowKeepsNeedsRelay`.
- [ ] **Step 2: Run** `make mobile-test SIM='<yours>' MOBILE_FILTER='RelayBannerModelTests|TransportFollowerWiringTests|LinkingViewModelTests|RelayAccountCenterTests'` and `make kit-test FILTER=TransportFollowerPolicyTests`, and `go test ./internal/hub/link -run RelinkAfterTheTerm`. Expected: FAIL for the phone's tests. The Go test passes at once: it pins Task 2's clear for this path, so a pass here is not a missing RED.
- [ ] **Step 3: Implement** in the model, tones only, one banner at a time as Phase 4's order says.
- [ ] **Step 4: Run** Step 2, then `make mobile-shots SHOTS_ONLY=relay-phase5 SIM='<yours>'`. `make lint-swift`. Expected: PASS.
- [ ] **Step 5: Commit.** `feat: a phone left behind by a move says it needs a new link (#1248)`

## Measuring the cost

Task 6's fake transport cannot give real size, phone traffic or wakes. Three separate measurements, with the owner's only live-data step named.

**M-A. Real size. Owner step, or the controller at the owner's request; read-only.** On the owner's Mac, with the installed app, using nothing built from this repo:

```
sqlite3 -readonly "<workspace>/watchtower.db" "SELECT count(*), sum(length(CAST(segments_json AS BLOB))) FROM meeting_transcripts WHERE created_at >= datetime('now','-30 days');"
sqlite3 -readonly "<hub state dir>/hubstate.db" "SELECT count(*) FROM slice_state;"
```

Never a dev CLI on the live database. **The numbers go to the ask's answer only, never into a repo file, PR or plan: this repo is public.** The first gives the plain asset volume (an upper bound: `segments_json` before the 20 MB clip), the second the record count; each record costs at most one envelope, padded to at least 256 B and at most 900 KB.

**M-B. Traffic and wakes, on staging.** After M-A, and after "The staging run"'s dependencies. The controller generates a synthetic workspace with M-A's counts and sizes (no real content), runs `make hub-staging` on a test host, and links one real iPhone with a DEBUG build against staging. **The 10-minute epoch is not for this run,** because a republish that outlasts it would be wiped by the next rotation. Set `WATCHTOWER_RELAYSTAGING_EPOCH` to 2 h. **A reading counts only from a line that says `complete`.** If a line says `interrupted`, double the epoch and run again. If the republish does not complete within a 24 h epoch, that is itself a fail: it goes to the owner with the `interrupted` counts. Over three rotations:

- **Hub upload:** the Task 6 log line, `complete` only.
- **Phone traffic:** Task 15's meter line, read from Console by the owner or controller.
- **A refused phone:** the same line stays flat while its feed is stopped.
- **Wakes:** with the phone locked and the app in the background, the same line's `wakes`, per rotation. The relay coalesces silent pushes per device into one per 2 s window (`COALESCE_MS`), and a republish lasting minutes can ask for many; APNs may throttle them further, so a device count is the only real figure.

**Thresholds, each checkable from those three readings:**

| Reading | Pass |
|---|---|
| Hub upload per rotation | at most 500 MB |
| Phone download per rotation | at most 500 MB, so at most about 2.2 GB a month against the relay's 100 GB |
| Background wakes per rotation, locked phone | at most 6. Over that, the battery rule (#724) applies: the owner rules before launch |

These numbers are the agent's proposal, and 6 is a guess with no data behind it: **the owner sets them before the measuring run** (ask #1077; the controller asks). The reasoning: 500 MB per rotation because four a month is about 2 % of the relay's 100 GB per phone; 6 wakes to say "a handful, not one every 2 s". A fail goes to the owner before launch; the known way out is to reuse the already-uploaded asset (`K_asset` is unchanged by rotation), which needs a transport change and possibly relay work, and is not in this plan. **By whom and when:** M-A by the owner before the staging run; M-B by the controller with the owner's device, in the staging run. They do not block merging into the branch; they block launch.

## The staging run

Moving a real hub's clock is not possible (`interopOpts.clock` exists only on the test stand), and a week's wait is not a check. So `-tags relaystaging` gives a 10-minute epoch (or `WATCHTOWER_RELAYSTAGING_EPOCH`) and 30-minute hub retention, on a test host only, guarded by `TestNoReleasePathSetsRelayStaging`, `TestRelayRotationAgeIs7DaysInTheDefaultBuild` and `TestRetentionIs7DaysInTheDefaultBuild`.

**A launch condition (ask #1066). Depends on:** Phase 4's owner-only steps and M1–M10 on staging, **none of which has run**. Staging readiness is therefore unproven, and launch waits on this chain. This run comes after M2 (a real App Attest) and M4 and M5 (pushes) at least.

**Steps, on one iPhone and one test hub:**

1. On a small synthetic workspace, whose republish fits inside 10 minutes (a line saying `interrupted` means make it smaller): link over the relay. A static first epoch; after 10 minutes the first ephemeral one. An action goes through.
2. Phone locked across a rotation: an ask alert shows its text (Task 5).
3. Airplane mode for 40 minutes, one action queued and one recording finished. The hub has retired their epoch, so the action draws `resend_from` and is resealed, and the recording is resealed. Back on: both arrive once.
4. M-B's readings, in their own run with the longer epoch.
5. On a second paying phone, or with a sandbox expiry: the lapse path of Task 13.
6. A free phone linked to the same hub: it shows S51 and no keys reach it in the relay zone (Task 4), which ships live with launch.

**What this does not reach:** the phone's own retention stays 7 days, so it never loses a key here. Review Focus 1's key-gone path (F7's Not delivered row, F16's drop) is proven only by Kit tests and the stand's step 4.

**The owner runs the device steps; the results go in an ask, numbers from synthetic data only.** Until this passes, launch does not happen.

---

## Decisions

| Decision | Source |
|---|---|
| Rotation ships **on, with launch**; launch waits for this phase's reviews and its staging run, which depends on Phase 4's owner steps and M1–M10. Against the spec's "after launch" (ask #799), the agent's recommendation (dark landing) and its earlier advice on ask #1051 | ask #1066 |
| Timer rotation keyboxes go in the **data zone**, `keybox-<device>`: latest version only, not cut by the 14-day mailbox TTL, sealed to the offer. Amends the spec's "travel in the phone's mailbox inside `transport_switched`" (ask #799), which now covers switches only | ask #1066 |
| Frozen bytes approved: `relay_kx`, `previous_relay_kx`, `next_kx`, `wt/relay/v2/`, an HPKE recipient that is not always `dev_kx`. Envelope header, classes and existing vectors unchanged | ask #1066 |
| iCloud users get **only the inert migration**; erasure and the upload reseal are limited to relay links, with no pragma or checkpoint when nothing is erased | ask #1066 |
| This session builds the Go hub half | ask #1067 |
| PR base `feature/relay-client-next` | controller's brief |
| No old relay build is supported: no relay user exists before launch, **as long as launch condition 4 holds**. This removes the old-build option, its refusal screen, a phase-wide build setting and the rule on when to turn one on. The static path stays, because a phone's first week, iCloud and pre-launch dev builds use it | decided by the agent, from ask #1066 |
| X25519 offers as the spec says, not a symmetric chain; `ikm` mixes in the static secret | ask #1077 |
| The hub keeps no ephemeral key: it erases its own at once and draws a fresh one per phone against that phone's last offer. The relay text edit is launch condition 5 | ask #1077 |
| Every rotation re-sends the window, transcript assets included (at most 200 × 20 MiB). Measured on staging; launch on a pass or the owner's ruling | ask #1077 |
| No keys in the relay data zone for a non-reader or a lapsed phone; an unknown reader list keeps keys, for availability at startup. Limit: a free phone's `transport_switched` at the switch to the relay carries the first, static, relay epoch's keybox, in iCloud | ask #1077 |
| Relay alert pushes are sealed in the epoch the phone acked while it is retained. Limit: a phone not unlocked and merged for over 14 days gets the content-free notification | ask #1077 |
| A held hub, or one with no reader on an answered list, does not rotate on the relay; the epoch's calendar life stretches with nothing sent under it. A CloudKit hub stays as it is | ask #1077 |
| No rotation when an answered read shows nobody pays, ending at 14 days. The hub knows from that read, not from refusals | ask #1081 |
| The hold ends at 14 days with one rotation and a clear. A relay fault that long costs each phone on the hub a static week and possibly one unanswered action | ask #1077 |
| With nobody paying and a phone without a route, a refused write or the relay's signal moves the Mac; G2's hold lasts only until then. Refines asks #1072, #1075. In the code a refused write means a mailbox write answered `ENTITLEMENT_INACTIVE`; `FORBIDDEN` on an empty list moves nothing, and a hub with neither stays (F45). **This is narrower than the answer's words, "Rule 16: Mac leaves"; the controller tells the owner** | ask #1087 |
| Two limits with no screen: a hub closed over 7 days right after a partial republish leaves those rows unreadable until it returns; a keybox naming a key the phone lost (only a restored sidecar) leaves it stale until a re-link, logged only | ask #1077 |
| The first week after a link, a switch or a renewal is static | ask #1077 |
| No user-facing number for exposure. Any text says keys change about weekly while the Mac runs and a stolen phone can open what it still holds, with no figure | ask #1077 |
| Rotation visibility: Task 14, additive `hub status` and `hub phones --json` keys and a daily log line on a stuck epoch; no Desktop line | ask #1077 |
| The feed parks after 1 h, losing nothing, and resumes on a merge, a foreground or a launch. Only an `epochGone` record is dropped, and that re-sends every unechoed action | ask #1077 |
| A static-keyed `hub_on_relay` is accepted on an ephemeral link, so someone with an old `dev_kx` and write access to that mailbox can push the phone off the relay | ask #1077 |
| A farewell from a phone away past retention does not reach the hub; the row stays until the owner removes it on the Mac (F32) | ask #1077 |
| The `relaystaging` tag: a 10-minute epoch (or `WATCHTOWER_RELAYSTAGING_EPOCH`) and 30-minute hub retention, in test builds only. **Its numeric thresholds stay open until the owner sets them** | ask #1077 |
| Now's parked row and S58's text (Task 16); its frame is shown to the owner before the code | ask #1077 |
| The relay's own expiry signal with a failed account read: that phone's keys are cleared at the signal, before the read. A wrong signal costs it one static week | ask #1081 |
| A relay-only phone refused by the relay: its sent and queued actions go to Not delivered, with today's text | ask #1081 |
| The phone left behind after the Mac moved to iCloud gets banner S59, "<Mac> can't be reached over Relay any more. Link this iPhone to it again." with **Forget This Mac**, when it can know; S58b is dropped. Limit: a lapsed phone past its read window can't know, keeps **Subscribe**, and may pay and still need a new link | ask #1081 |
| A phone out of its slot while its subscription stands reads the account and, with its Mac in no slot, acts at once (`slotLost`): with a route it moves to iCloud without waiting for `hub_on_relay`, without one it lists its actions and shows S59 | ask #1081 |
| `ReaderLost` clears a gone phone's offer and rows and marks it lapsed, whoever pays, after two reads of a non-empty list. A wrong answer repeated 5 minutes apart pushes a real phone out: with a route through `hub_on_relay`, without one until its return | ask #1077 |
| The hub's age depends on the transport, and on the rules above for a hub with no reader or nobody paying; the earlier "no offering phone stays at 90 days" gate is dropped. A hub with only static phones pays the republish with no gain, which at launch lasts minutes | ask #1077 |
| Relay links rotate; CloudKit keeps 90 days and static keys | relay design §7 item 4; relay client spec §1 |
| A hub has one scheme, by its current transport; every switch starts an epoch | relay design §3, §7.4 (ask #702 there); relay client spec §9 |
| Retention 7 days, at most 8 epochs, on both sides; not rule 14's 14 days | ask #843; Phase 3 Owner approval 4, ask #904 |
| `epoch_ack` to ordered hubs; reseal with the same `action_seq` on `resend_from` | Phase 3 Owner approval 4 (R9, R10), ask #904 |
| Switch keyboxes stay inside `transport_switched` | ask #799 |
| `K_meta`, `hub_sig`, `hub_kx`, `dev_kx`, `dev_sig` do not rotate | protocol §4.2; decided by the agent for this phase |
| Rotation is automatic with no owner action | relay design §7 item 5 |
| No relay server or protocol change is needed | decided by the agent after reading the relay at `bcca870` |
| A Mac with no paying phone moves to iCloud by itself (G2) | ask #1055, refined by asks #1070 and #1072 |
| A paying phone not linked to this Mac: the Mac stays on the relay. Every phone with a route and a long empty list: it moves after two reads | ask #1070 |
| The Mac moves only if **every** linked phone has an iCloud route; otherwise it stays, a paying phone left without a route included | ask #1072 |
| On the relay the phone's sealed record (AEAD under the pairwise key, not signed) and the mailbox rule replace the creator check; a 3-second pause before `remove_slot` (G1) | ask #1056 |
| On an explicit expiry the Mac stays on the relay while someone else pays, and moves when nobody pays, routes playing no part; a route-less phone is left to re-link. The G2 lane builds it | ask #1075 |
| "Someone pays" means a paying phone holding this Mac in its slots, linked or not | ask #1079 |
| A phone's own `entitlement_expired` request on an unreadable account moves the Mac at once, by the relay's rule 10. The relay's own signal with a failed read waits and retries | ask #1079 |
| That phone's keys are cleared on its own request, whether or not the account can be read: `queueLapse` is the one entry for both signals | decided by the agent, an inference; ask #1079's answer speaks only of the Mac's move |
| G2's self-move keeps ask #1072's rule: nobody paying and a phone with no route, it does not move the Mac by itself | ask #1075 |
| The hub asks a gap again after 10 minutes; a late copy of a skipped action gets `expired` (#1498) | ask #1073 |
| #1497's window is an accepted limit | ask #1060 |
| The phone erases no key on a refusal or `slotLost`, only on an opened `hub_on_relay` or a follow, or with the link at the term below; the keybox alone says each epoch's keys | accepted by the owner with a term, ask #1082 |
| A relay-only phone's keys have a term of about 21 days from the first refusal | ask #1082 |
| At the term all link keys go | ask #1086 |
| The term is carried out by ending the link through today's `unlinkRow`: the replica, Not delivered rows and the row go too, recordings stay, it waits for a running recording, and the person links again, even if they pay afterwards. The hub's row usually stays, because the farewell is usually refused | decided by the agent after ask #1085; **for the owner to confirm, ask #1091** |
| The term acts only in the foreground and only after an account read answers and shows the refusal stands. A failed read waits, with no cap, so a phone whose reads never answer keeps its keys | decided by the agent, review of ask #1090 |
| S60 names 21 days. That is the link's term, not an exposure bound, so ask #1077's rule on numbers does not touch it; the wording is the agent's, and the owner checks it on Task 0's frame | decided by the agent, review of ask #1089 |
| One stored cause: each answered read clears the mark on paying with a slot, and else sets `.lapse` or `.slot` by what it shows, keeping `since`. A known move clears only on a marker toward the relay | decided by the agent, reviews of asks #1089 and #1090 |
| A phone with no key source does not park or show S58; its feed stops until a merge, a foreground or a launch, with nothing on Now but the banner it already has | ask #1082's comment; mechanism by the agent |
| Before listing, a written action is withdrawn through today's `withdrawUnanswered`, so a Retry cannot run it twice | decided by the agent after reading `retry`; ask #1082's comment |
| An offer is refused while the phone is in `lapse_pending` | decided by the agent, review of ask #1080 |
| Offer on `epoch_ack`, no new control kind, no grant capability field | decided by the agent |
| At most two ephemeral keys per hub on the phone | decided by the agent |
| A static fallback decided by the row's presence, per `(epoch, device)` | decided by the agent |
| Sealed relay keys in the sidecar under the AAD `wt/hub-epoch-relay/v1` | decided by the agent |
| `PhoneKeyStore.updateHubLink` serialises all writers | decided by the agent |
| A re-link clears the offer and rows inside `LinkDevice` | decided by the agent |
| Age rotation skips a running switch | decided by the agent |
| The reader transition: `relay_lapsed_at` as the durable signal, keys static after it; `ReaderLost` never moves the Mac | decided by the agent, rounds 1 and 3; its keys in ask #1077 |
| No Desktop change; a content-free log line per rotation | decided by the agent |
| No phone screen or text but the parked row, the banner of ask #1081 and the term's notice | decided by the agent; relay design §7 item 5 |

## Still waiting on later owner steps

- **The term carried out by ending the link (Decisions, ask #1091).** The owner's answer on ask #1086 was about erasing keys, not ending the link. It stays open until the owner answers, and Task 17 does not start before that.
- **The numeric thresholds in "Measuring the cost."** The owner sets them before the measuring run; the controller asks.
- **Frames S58, S59 and S60.** Shown to the owner before Tasks 16 and 17 (Task 0).

**Contracts:** no `PROJ-*` change is proposed. `docs/inventory/` has no entry on epochs or rotation. PROJ-16's dated note ("every relay record is sealed") stays true. PROJ-21 says a prompt is answered "only by the owner's explicit Allow once or Deny, from a device allowed for it on the Mac, through the hook; the answer types nothing, allows one call, and never answers a prompt the Mac answered first". Rotation changes none of that: a resealed answer goes through the same device gate and compare-and-set (F30), and one whose key is gone becomes Not delivered, leaving the prompt on the Mac. Its guards do not change; if review reads it otherwise, it goes to the owner. Task 12 re-checks both. Guard `TestKeyring_RotatesAt90DaysOrSeqCap` keeps its assertions: it runs with no relay transport, on the 90-day path. The amended, non-guard Kit test is `epoch_ack`'s "never for an epoch at or below", which gains the same-epoch-new-offer case in Task 8. If review reads that as a contract, it goes to the owner.
