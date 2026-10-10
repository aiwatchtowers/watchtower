# S0 results

Logs are redacted: record names are `<record>`, share URLs are `<share-url>`. The team id and Apple IDs are left out.

## 2026-10-10: signing, and the Mac-side checks (no iPhone)

**Environment:** Xcode 27.0, iOS 27.0 simulator, CloudKit **Development** on both sides (Debug builds).

### Signing

| Build | Result |
|---|---|
| Mac, `./spike.sh mac` | PASS. Signed `Apple Development: <name>`, real TeamIdentifier, `get-task-allow`. The entitlements carry `iCloud.com.aiwatchtowers.watchtower`, CloudKit and the `development` APS environment. The embedded profile allows the `Development` and `Production` container environments. The first build needed `-allowProvisioningDeviceRegistration`, to register this Mac as a team device. |
| iOS simulator, `./spike.sh sim` | PASS for a simulator. Xcode always signs simulator apps "Sign to Run Locally" (ad hoc), even with `CODE_SIGN_IDENTITY=Apple Development`. The team's entitlements are embedded in `__TEXT,__entitlements`: `<team>.com.aiwatchtowers.watchtower.mobile`, the container, CloudKit and `aps-environment=development`. The app registers for remote notifications. |
| iOS device, `./spike.sh ios` | BLOCKED. `Your team has no devices from which to generate a provisioning profile`. The build needs a connected iPhone (or its UDID added in the portal). |

Signing created the `Apple Development` identity in the keychain on the first build.

**Mac App ID:** the fresh App ID `com.aiwatchtowers.watchtower.ckspike` signed fine, but CloudKit refused every record save with `CKError 10 "Invalid bundle ID for container"` (three tries within 3 minutes, binary and LaunchServices). Zone saves passed. With the real App ID `com.watchtower.desktop`, `setup` passed at once. `spike.sh` now defaults to it. The Kit runs under that id anyway.

### Mac side

```
(d) accountStatus + userRecordID: 470 ms
(d) container=iCloud.com.aiwatchtowers.watchtower accountStatus=1 (available)
(d) userRecordID.recordName=<record>
(setup) save zones: 3702 ms — DataZone,RelayZone,AlertZone
(setup) seed records: 1385 ms
(setup) save zone-wide shares: 3439 ms
  DataZone: publicPermission=2 url=<share-url>
  RelayZone: publicPermission=3 url=<share-url>
(setup) LINK <link>
```

The Mac side is ready: zones, seed records and both shares with an open link exist in Development.

### Per item

| Item | Status |
|---|---|
| (a) shared sync + 64 MiB asset | Not run: needs iPhone 2 on a second Apple ID. |
| (b) silent shared-DB push | Not run: needs iPhone 2, the app in the background. |
| (c) close the link, F2 | Not run: needs an accepted participant (iPhone 2). |
| (d) userRecordID | The Mac half is done. "Same" can run on the simulator after the owner signs it in (`./sim.sh run`). "Different" needs a second Apple ID. Simulator smoke test before sign-in: the link is saved, then the expected `CKError 9 No iCloud account is configured`. |
| (e) visible alert | Ready for `./sim.sh run` after the owner signs in and adds the Queryable `kind` index. A simulator pass is indicative; the lock-screen check is on a device. |

## Simulator run 2026-10-10 (iPhone 18 Pro simulator, iOS 27.0, signed into the Mac's Apple ID; Mac in Development)

- (d) same Apple ID: **PASS**. accountStatus=available in 527 ms; the simulator's userRecordID equals the Mac's owner_user.
- (e) subscriptions: CKQuerySubscription (private, DataZone) saved in 1980 ms; CKRecordZoneSubscription (private, AlertZone) saved in 363 ms; notification authorization granted.
- (e) DataZone alert: **PASS**. A visible alert was delivered while the app was in the background, 1472 ms after the Mac's write.
- (e) AlertZone alert: delivered and **tapped by the owner** 1030 ms after the Mac's write. The automated read reports FAIL only because the tap removed it from Notification Center before `e-read` looked; the delivery itself is logged with its latency. Treat it as delivered.
- Indicative only: the simulator stands in for iPhone 1. The lock-screen check, background delivery on a real device, and (a)/(b)/(c) across two Apple IDs still need the device run.
- Owner note: Xcode 27's DeviceHub ignores clicks in its embedded simulator view (scroll only); a detached simulator window accepts clicks. The simulator's on-screen keyboard did not appear; text was entered with `pbpaste | xcrun simctl pbcopy booted` and Paste.

## Device run 2026-10-10 (one iPhone on the Mac's Apple ID; no second Apple ID yet)

**Environment:** Xcode 26.4, iPhone 15 Pro on iOS 26.6.2 over USB, CloudKit **Development** on both sides (Debug builds, Apple Development signing). Driven with launch arguments through `xcrun devicectl device process launch` (`-ckspikeLink`, `-ckspikeRun d-same|e-subscribe|e-read`), the same as `sim.sh`.

**Signing:** the first device install failed with `0xe8008012 This provisioning profile cannot be installed on this device`: a build for `generic/platform=iOS` cannot register a new iPhone. `spike.sh ios-install` now builds for the concrete device (`-destination id=<udid> -allowProvisioningDeviceRegistration`), which registers it and puts it into the profile. Developer Mode had to be turned on on the phone first (`CoreDeviceError 10005`).

```
(d) accountStatus + userRecordID: 373 ms — status=1
(d) Mac owner_user=<record> → EQUAL
RESULT (d): PASS — same Apple ID expected, values are equal
(e) save CKQuerySubscription (private, DataZone): 750 ms — spike-ask-alerts-DataZone
(e) save CKRecordZoneSubscription (private, AlertZone): 264 ms — spike-ask-alerts-AlertZone
(e) alert delivered: zone=AlertZone subscription=spike-ask-alerts-AlertZone … Mac write → delivery latency=621 ms
(e) alert delivered: zone=DataZone subscription=spike-ask-alerts-DataZone … Mac write → delivery latency=1498 ms
RESULT (e): PASS — DataZone: visible alert delivered after the subscribe, latency known (lines above)
RESULT (e): PASS — AlertZone: visible alert delivered after the subscribe, latency known (lines above)
```

- (d) same Apple ID: **PASS** on the device.
- (e) visible alert, phone locked, app in the background (not force-quit): **PASS** on both paths; the owner saw the alerts on the lock screen. DataZone query subscription 1.5 s, AlertZone zone subscription 0.6 s after the Mac's write. The A3 decision can use the primary DataZone query subscription.
- Still open, all need a second Apple ID: (a) shared sync + 64 MiB asset, (b) silent shared-DB push in the background, (c) closing the link and F2, (d) "different".
