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
