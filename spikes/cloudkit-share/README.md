# S0 spike: CloudKit sharing and scopes (throwaway)

Mobile POC A, Task 1. This harness checks CloudKit sharing on real devices before the Kit is built on it (spec `docs/superpowers/specs/2026-10-07-mobile-poc-design.md` §2.3 and §13 S0). It lives on branch `spike/cloudkit-share` and is **never merged**. The S0 PR carries only the results and the logs.

- **`CKSpikeMac`** is the owner side, run on the Mac's Apple ID. It is a command-line tool. It is packaged as an app bundle because iCloud entitlements need an embedded provisioning profile. You run its binary from Terminal.
- **`CKSpike`** is the iOS app. It is a list of buttons, one per item. The same build runs on both iPhones.

Every step prints a timed line, for example `[2026-10-08 10:00:01.234] (a) CKSyncEngine(.shared).fetchChanges: 812 ms — DataZone=2 RelayZone=1 records`. Every item ends with one verdict line:

```
RESULT (a): PASS — …
RESULT (c): FAIL — readDataZone=false …
```

On the iPhone, lines that contain FAIL or ERROR are red, and the newest line is at the top.

## Setup

| Device | Apple ID | Used for |
|---|---|---|
| Mac | owner (A) | every Mac command |
| iPhone 1 | owner (A), the same as the Mac | (d) "same", (e) |
| iPhone 2 | test Apple ID (B) | accept, (a), (b), (c), (d) "different" |

The test Apple ID (B) must be signed into iCloud on iPhone 2, with iCloud Drive on (Settings → your name → iCloud). Without that, CloudKit reports no account.

One iPhone can play both roles: sign it into B for the participant items, then sign it into A for (d) "same" and (e). The app keeps the scanned link across the switch.

**Identifiers**

- Container: `iCloud.com.aiwatchtowers.watchtower`.
- macOS bundle id: `com.aiwatchtowers.watchtower.ckspike`. You can override it with `SPIKE_MAC_BUNDLE_ID`.
- iOS bundle id: `com.aiwatchtowers.watchtower.mobile`, the real phone App ID. You can override it with `SPIKE_IOS_BUNDLE_ID`.

**Before the first signed build, in the developer portal:**

1. The container `iCloud.com.aiwatchtowers.watchtower` must exist under your team (Identifiers → iCloud Containers).
2. Both App IDs must have the iCloud capability with CloudKit enabled, with that container checked, and Push Notifications on.
3. `-allowProvisioningUpdates` can create the profiles, but it cannot attach a container that does not exist yet.

The iOS default is the **real phone App ID**. The spike installs as that app, and later dev builds of the real app replace it on the phone. Delete the app after the run (see Clean up).

Automatic signing (`-allowProvisioningUpdates`) registers missing App IDs and development profiles, provided Xcode is signed into your developer account. Builds are Debug, so they use the CloudKit **Development** environment and the APNs sandbox.

## Build and sign

Run these from `spikes/cloudkit-share/`. You need `xcodegen` (`brew install xcodegen`) and Xcode 16 or later. The team id is read only from the environment and is never written to the repo. The generated `CKSpike.xcodeproj` is git-ignored.

```sh
./spike.sh check                                   # unsigned: macOS, iOS device (CODE_SIGNING_ALLOWED=NO), iOS simulator
DEVELOPMENT_TEAM=<team-id> ./spike.sh mac          # signed macOS build; prints the binary path
DEVELOPMENT_TEAM=<team-id> ./spike.sh ios          # signed iOS device build
DEVELOPMENT_TEAM=<team-id> ./spike.sh ios-install <udid>   # build + install (udid: xcrun devicectl list devices)
```

You can also run `./spike.sh gen`, open `CKSpike.xcodeproj`, pick your team, and use Run on the device. On the iPhone, turn on Developer Mode (Settings → Privacy & Security). On first launch, trust the developer profile (Settings → General → VPN & Device Management).

To save typing, set an alias for the Mac binary:

```sh
alias spike="$PWD/build/mac/Build/Products/Debug/CKSpikeMac.app/Contents/MacOS/CKSpikeMac"
spike            # prints the command list
```

If CloudKit refuses the directly started binary (an entitlement or "missing container" error), start it through LaunchServices instead, and keep the output in the terminal:
`open -W --stdout $(tty) --stderr $(tty) build/mac/Build/Products/Debug/CKSpikeMac.app --args whoami`.

## Run, in this order

### 0. Link: Mac and iPhone 2 (B)

1. Mac: run `spike whoami`. It prints `(d) userRecordID.recordName=…`. Write the value down for (d).
2. Mac: run `spike setup`. This creates `DataZone`, `RelayZone` and `AlertZone`, the seed records, and both zone-wide shares with the public link open (DataZone `readOnly`, RelayZone `readWrite`). It prints `(setup) LINK ckspike://link?...` and opens a QR image.
3. **CloudKit Console, one time:** open Development → Schema → Indexes → `WatchtowerRecord` and add a **Queryable** index on `kind`. Item (e)'s DataZone query subscription needs it. `setup` has just created the record type.
4. iPhone 2: scan the QR with the **Camera** app and tap the banner. CKSpike opens and logs `link: saved owner_user=…`. If scanning is not possible, copy the `LINK` line to the iPhone's clipboard and tap **Paste link from clipboard**.
5. iPhone 2: tap **Accept shares (second Apple ID only)**. Pass: you see `(accept) CKAcceptSharesOperation: … ms — DataZone,RelayZone` and no ERROR line.

### (a) CKSyncEngine on the shared database, with a 64 MiB asset

1. iPhone 2, on Wi-Fi, app in the foreground: tap **a: Sync shared + send 64 MiB asset**. Wait for `RESULT (a)`. The upload can take a minute.
   - Pass: `RESULT (a): PASS — participant side: fetchedBothZones=true relayRecordSent=true assetSent=true total=… ms`.
2. Mac: run `spike fetch-relay`. Add `--reset` if you need to refetch from scratch.
   - Pass: `RESULT (a): PASS — owner downloaded relay-asset-…: size=67108864 sha256 matches …`.
   - The Mac prints one RESULT per asset record it fetches, and earlier runs leave records behind. Take the line whose `relay-asset-<id>` equals the name in this run's phone line `(a) upload CKAsset record via sendChanges: … saved relay-asset-<id>`.
3. **(a) passes only if both RESULT lines are PASS.** Record these timings:
   - phone: the `fetchChanges`, `send small RelayZone record` and `upload CKAsset` timings;
   - Mac: the `fetchChanges (assets downloaded)` timing.

### (b) Silent push on the shared database, app in the background

1. iPhone 2: tap **b: Register silent shared-DB push**. When asked, allow notifications.
2. iPhone 2: go to the Home Screen or lock the phone. **Do not force-quit the app** from the app switcher, because iOS blocks silent pushes to a force-quit app. Keep the phone on Wi-Fi and Low Power Mode off.
3. Mac: run `spike write-data`. It prints `writtenAt=…`. Repeat it up to three times, about a minute apart.
4. Pass: the iPhone shows a local notification "S0 (b) push received". Open the app. The log has `RESULT (b): PASS — silent shared-DB push arrived in the background; Mac write → push latency=… ms`.
   - A push counts only when `probe-push.writtenAt` is later than the moment you tapped **b: Register**, and the latency is known and between -5 s (clock skew) and 300 s.
   - A background push that fails these checks logs `RESULT (b): FAIL — background push arrived but is not attributable to write-data: <reason>`. This happens, for example, with a delayed delivery or a change from (a). Run `write-data` again.
   - Fail: no `RESULT (b): PASS` line within five minutes of three writes.
   - A `(b) push arrived with the app active` line is not a pass. Background the app and retry.

### (c) Closing the public link, and fallback F2 if it fails

Run (c) after (a) and (b), because closing the link may cut access.

1. Mac: run `spike participants`. Phone B's record name should be listed under both shares, with status 2 (accepted). The raw values are: `role` 1 = owner, 3 = private user, 4 = public user; `permission` 2 = readOnly, 3 = readWrite; `status` 1 = pending, 2 = accepted, 3 = removed.
2. Mac: run `spike close-link`. Both shares print `publicPermission=1` (none).
3. iPhone 2: tap **c: Check access (after close-link)**.
   1. The phone first fetches both share records and requires `publicPermission=1` (none) on both. It logs its own participant entry (`me: role=… permission=… status=…`). Copy this line into the PR: it shows whether the phone is a public user or a named participant.
   2. If a share was read but its link is still open, you get `RESULT (c): FAIL — precondition miss, not a (c) verdict: the public link is still open … close the link on the Mac first`. Run `spike close-link` and tap again. Do not count this as a (c) failure.
   3. If the phone **cannot read** a share record (for example permissionFailure, unknownItem or zoneNotFound), that is a real (c) failure: closing the link dropped the participant. You get `RESULT (c): FAIL — the participant can no longer read a share after the link closed — <error>`, followed by the F2 hint (step 4).
   4. The phone then reads both zones, writes RelayZone, and tries a DataZone write. The DataZone write passes the check only when it is refused with `CKError.permissionFailure`. Any other error is a FAIL and is logged.
   - Pass: `RESULT (c): PASS — readDataZone=true readRelayZone=true writeRelayZone=true writeDataZoneRefusedByPermission=true`.
4. **Only on a real FAIL, run F2 in the same session.** The phone prints the exact Mac command.
   1. Mac: run `spike f2 <recordName from the phone>`. It follows the spec §2.3 production order, as three timed saves:
      1. it reopens the public link;
      2. it adds the phone as a named participant, from `CKFetchShareParticipantsOperation` with `LookupInfo(userRecordID:)` (readOnly on DataZone, readWrite on RelayZone);
      3. it closes the link.
   2. If the lookup finds no participant (the user is not discoverable, or the record name is wrong), the Mac prints `RESULT (c-F2): FAIL — LookupInfo(userRecordID: …) returned no participant …` and closes the link again. That is an F2 failure.
   3. If a later share save fails, the Mac prints `RESULT (c-F2): FAIL — a share save failed after the link was reopened`, closes the link and exits 1. Either way the link is never left open.
   4. iPhone 2: tap **c (F2): Re-accept + check**. It fetches the metadata again from the saved URLs, accepts, and repeats the whole (c) check, the closed-link precondition included.
   - Pass: `RESULT (c-F2): PASS — …`. If c-F2 also fails, F3 needs the owner's written OK in the S0 PR.
5. Optional: `spike open-link` reopens the link for retests.

### (d) userRecordID across platforms and Apple IDs

- iPhone 2 (B): tap **d: whoami — different Apple ID**. Pass: `RESULT (d): PASS — different Apple ID expected, values are different`.
- iPhone 1 (A): get the link (scan the same QR, or use Paste link, since Universal Clipboard works on one Apple ID), then tap **d: whoami — same Apple ID**. Pass: `RESULT (d): PASS — same Apple ID expected, values are equal`.
- The phone compares against `owner_user` from the QR, which is the Mac's `userRecordID().recordName`. You can also compare by eye with step 0.1.

### (e) Visible alert in a private custom zone

There are two paths, and both use the spec §7 alert settings: `alertLocalizationKey = "ASK_ALERT_GENERIC"` ("A session is waiting for you"), sound `default`, `shouldSendMutableContent`, category `ASK`.

- **Primary:** a `CKQuerySubscription` in `DataZone`, `kind == "ask_alert"`, `.firesOnRecordCreation`.
- **Fallback:** a `CKRecordZoneSubscription` on `AlertZone`.

1. iPhone 1 (A): tap **e: Subscribe visible alerts** and allow notifications.
   - Pass: `save CKQuerySubscription (private, DataZone)` and `save CKRecordZoneSubscription (private, AlertZone)`, with no ERROR.
   - If the query subscription fails with a "not marked queryable" error, add the index from step 0.3 and tap again.
2. Lock iPhone 1.
3. Mac: run `spike alert DataZone`, wait about 30 s, then run `spike alert AlertZone`.
4. Pass: the lock screen shows "A session is waiting for you" twice, once per path. Leave the notifications in Notification Center. Open CKSpike and tap **e: Read delivered alerts**:
   - you see `(e) alert delivered: zone=DataZone … Mac write → delivery latency=… ms`, one line per alert;
   - you see `RESULT (e): PASS — DataZone: visible alert delivered after the subscribe …`, and the same for `AlertZone`.
   - An alert counts only when all of these hold:
     - it is that zone's expected notification: a query notification from `spike-ask-alerts-DataZone`, or a record-zone notification from `spike-ask-alerts-AlertZone`;
     - its trigger record was written after that path's subscription save succeeded;
     - its latency is known.
   - Anything else, such as a leftover alert from an earlier round, is logged with `NOT counted`. A path whose subscription save failed can never pass.
   - If only AlertZone passes, the A3 decision is the `AlertZone` fallback.

### Latency of each path, for the S0 PR

| Path | Where to read it |
|---|---|
| Shared-DB fetch, participant | phone, `(a) CKSyncEngine(.shared).fetchChanges` |
| Relay record send, participant | phone, `(a) send small RelayZone record` |
| 64 MiB asset upload, participant | phone, `(a) upload CKAsset record via sendChanges` |
| Asset download, owner | Mac, `(a) owner CKSyncEngine(.private).fetchChanges (assets downloaded)` |
| Silent shared-DB push | phone, `RESULT (b) … push latency` |
| Visible alert, DataZone query and AlertZone zone subscription | phone, `(e) alert delivered … delivery latency` |

Push and alert latencies compare the Mac's `writtenAt` with the iPhone's clock, and both clocks are network-synced. Treat about 1 s as noise.

## Collect the logs

- **Mac:** `~/Library/Application Support/CKSpike/spike-mac.log` collects every run, and the terminal shows the same lines.
- **iPhone:** in the Log section, **Copy** puts the log on the clipboard, and **Share file** sends `ckspike.log` by AirDrop, Mail or Save to Files. You can also open Finder → the iPhone → Files → CKSpike → `ckspike.log`.

**Redact before you paste into the PR. The repo is public.**

- Replace every `recordName` (`_…`) with `<owner-record>` or `<participant-record>`.
- Replace every `https://www.icloud.com/share/…` URL and the `ckspike://link?...` line with `<share-url>`. A share URL is a bearer secret.
- Remove any Apple ID or e-mail address.

## Clean up

- Mac: run `spike teardown`. It deletes the three zones, and the shares go with them.
- Delete the app from each iPhone. This matters, because it was installed under the real phone App ID `com.aiwatchtowers.watchtower.mobile`. The phone's subscriptions (`spike-shared-db-v1`, `spike-ask-alerts-*`) belong to the iCloud account and stay after the app is deleted. Once `teardown` has deleted the zones, they have nothing left to fire on.
