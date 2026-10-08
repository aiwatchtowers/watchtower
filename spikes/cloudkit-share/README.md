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

One iPhone can play both roles: sign it into B for the participant items, then sign it into A for (d) "same" and (e). The app keeps the scanned link across the switch.

**Identifiers**

- Container: `iCloud.com.aiwatchtowers.watchtower`.
- macOS bundle id: `com.aiwatchtowers.watchtower.ckspike`. You can override it with `SPIKE_MAC_BUNDLE_ID`.
- iOS bundle id: `com.aiwatchtowers.watchtower.mobile`, the real phone App ID. You can override it with `SPIKE_IOS_BUNDLE_ID`.

Both App IDs need the iCloud capability with CloudKit and that container, plus Push Notifications. Automatic signing (`-allowProvisioningUpdates`) registers missing App IDs and development profiles, provided Xcode is signed into your developer account. Builds are Debug, so they use the CloudKit **Development** environment and the APNs sandbox.

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
3. **CloudKit Console, one time:** open Development → Schema → Indexes → `WatchtowerRecord` and add a **Queryable** index on `kind`. Item (e)'s query subscription needs it. `setup` has just created the record type.
4. iPhone 2: scan the QR with the **Camera** app and tap the banner. CKSpike opens and logs `link: saved owner_user=…`. If scanning is not possible, copy the `LINK` line to the iPhone's clipboard and tap **Paste link from clipboard**.
5. iPhone 2: tap **Accept shares (second Apple ID only)**. Pass: you see `(accept) CKAcceptSharesOperation: … ms — DataZone,RelayZone` and no ERROR line.

### (a) CKSyncEngine on the shared database, with a 64 MiB asset

1. iPhone 2, on Wi-Fi, app in the foreground: tap **a: Sync shared + send 64 MiB asset**. Wait for `RESULT (a)`. The upload can take a minute.
   - Pass: `RESULT (a): PASS — participant side: fetchedBothZones=true relayRecordSent=true assetSent=true total=… ms`.
2. Mac: run `spike fetch-relay`. Add `--reset` if you need to refetch from scratch.
   - Pass: `RESULT (a): PASS — owner downloaded relay-asset-…: size=67108864 sha256 matches …`.
3. **(a) passes only if both RESULT lines are PASS.** Record these timings:
   - phone: the `fetchChanges`, `send small RelayZone record` and `upload CKAsset` timings;
   - Mac: the `fetchChanges (assets downloaded)` timing.

### (b) Silent push on the shared database, app in the background

1. iPhone 2: tap **b: Register silent shared-DB push**. When asked, allow notifications.
2. iPhone 2: go to the Home Screen or lock the phone. **Do not force-quit the app** from the app switcher, because iOS blocks silent pushes to a force-quit app. Keep the phone on Wi-Fi and Low Power Mode off.
3. Mac: run `spike write-data`. It prints `writtenAt=…`. Repeat it up to three times, about a minute apart.
4. Pass: the iPhone shows a local notification "S0 (b) push received". Open the app. The log has `RESULT (b): PASS — silent shared-DB push arrived in the background; Mac write → push latency=… ms`.
   - Fail: no `RESULT (b)` line within five minutes of three writes.
   - A `(b) push arrived with the app active` line is not a pass. Background the app and retry.

### (c) Closing the public link, and fallback F2 if it fails

Run (c) after (a) and (b), because closing the link may cut access.

1. Mac: run `spike participants`. Phone B's record name should be listed under both shares, with status 2 (accepted). The raw values are: `role` 1 = owner, 3 = private user, 4 = public user; `permission` 2 = readOnly, 3 = readWrite; `status` 1 = pending, 2 = accepted, 3 = removed.
2. Mac: run `spike close-link`. Both shares print `publicPermission=1` (none).
3. iPhone 2: tap **c: Check access (after close-link)**.
   - Pass: `RESULT (c): PASS — readDataZone=true readRelayZone=true writeRelayZone=true writeDataZoneRefused=true`.
4. **Only on a FAIL, run F2 in the same session.** The phone prints the exact Mac command:
   1. Mac: run `spike f2 <recordName from the phone>`. This runs `CKFetchShareParticipantsOperation` with `LookupInfo(userRecordID:)`, adds the result as a named participant (readOnly on DataZone, readWrite on RelayZone), and keeps the link closed. Check the timing lines and the participant list.
   2. iPhone 2: tap **c (F2): Re-accept + check**. It fetches the metadata again from the saved URLs, accepts, and repeats the check.
   - Pass: `RESULT (c-F2): PASS — …`. If c-F2 also fails, F3 needs the owner's written OK in the S0 PR.
5. Optional: `spike open-link` reopens the link for retests.

### (d) userRecordID across platforms and Apple IDs

- iPhone 2 (B): tap **d: whoami — different Apple ID**. Pass: `RESULT (d): PASS — different Apple ID expected, values are different`.
- iPhone 1 (A): get the link (scan the same QR, or use Paste link, since Universal Clipboard works on one Apple ID), then tap **d: whoami — same Apple ID**. Pass: `RESULT (d): PASS — same Apple ID expected, values are equal`.
- The phone compares against `owner_user` from the QR, which is the Mac's `userRecordID().recordName`. You can also compare by eye with step 0.1.

### (e) Visible alert from a query subscription in a private custom zone

1. iPhone 1 (A): tap **e: Subscribe visible alerts** and allow notifications. Pass: two `save CKQuerySubscription (private, DataZone|AlertZone)` lines with no ERROR. If the save fails with a "not marked queryable" error, add the index from step 0.3.
2. Lock iPhone 1.
3. Mac: run `spike alert DataZone`, wait about 30 s, then run `spike alert AlertZone`.
4. Pass: the lock screen shows "S0 (e) alert / Query subscription in DataZone", and the same for AlertZone. Leave the notifications in Notification Center. Open CKSpike and tap **e: Read delivered alerts**:
   - `(e) alert delivered: zone=DataZone … Mac write → delivery latency=… ms`, one line per alert;
   - `RESULT (e): PASS — DataZone: visible alert delivered`, and the same for `AlertZone`.
   - If only AlertZone passes, the A3 decision is the `AlertZone` fallback.

### Latency of each path, for the S0 PR

| Path | Where to read it |
|---|---|
| Shared-DB fetch, participant | phone, `(a) CKSyncEngine(.shared).fetchChanges` |
| Relay record send, participant | phone, `(a) send small RelayZone record` |
| 64 MiB asset upload, participant | phone, `(a) upload CKAsset record via sendChanges` |
| Asset download, owner | Mac, `(a) owner CKSyncEngine(.private).fetchChanges (assets downloaded)` |
| Silent shared-DB push | phone, `RESULT (b) … push latency` |
| Visible query alert, DataZone and AlertZone | phone, `(e) alert delivered … delivery latency` |

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
- Delete the app from each iPhone.
