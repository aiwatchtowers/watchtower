# Mobile POC A: skeleton, linking and real-iCloud smoke (#423)

**Goal:** a signed Mac and an iPhone, on the same Apple ID or on different ones, link by scanning a QR code and exchange a probe slice and a probe action through the user's own CloudKit, with the transport proven on real devices before B and C build on it.

**Architecture:**
- The Desktop app hosts an opt-in `MobileHub`. It publishes capped projections into `DataZone` and applies phone requests from `RelayZone`, through `CKSyncEngine`, in the Mac user's private database.
- A same-Apple-ID phone syncs that private database. A different-Apple-ID phone reaches both zones through zone-wide shares that it accepts from the QR code.
- The shared Kit (`WatchtowerSync` + `WatchtowerKit`) is ported file by file from branch `mobile-app` (no merge base; never merge it). It carries both database scopes behind one interface.

**Specs:** `docs/superpowers/specs/2026-10-07-mobile-poc-business.md` (owner-approved) and `docs/superpowers/specs/2026-10-07-mobile-poc-design.md` (technical; § numbers below refer to it).

## Global constraints (verbatim from the spec)

**Container and zones**
- Container for all build flavors: `iCloud.com.aiwatchtowers.watchtower`.
- Zones: `DataZone` and `RelayZone`, custom zones in the Mac user's private DB. A different-Apple-ID phone reaches them through zone-wide shares in its shared DB.
- DataZone share: read-only. RelayZone share: read-write.
- Record type `WatchtowerRecord`. Fields: `kind` (plain), `modifiedAt` (plain), `encryptedValues["payload"]`, `encryptedValues["notifyLevel"]`, `asset`.
- Record name: `<kind>-<id>`.
- Kit database scopes: `private` and `shared(ownerName)`. In `shared` scope the phone never saves or deletes zones.

**Identifiers**
- Phone bundle id: `com.aiwatchtowers.watchtower.mobile`.
- Extensions: `com.aiwatchtowers.watchtower.mobile.notify-service` and `com.aiwatchtowers.watchtower.mobile.notify-content`.
- App group: `group.com.aiwatchtowers.watchtower.mobile`.
- iOS 17 floor. Kit: swift-tools 5.10, GRDB `from: "7.0.0"`.

**QR code**
- URL: `watchtower://link?d=<base64url(JSON)>`, no padding, sorted keys.
- Payload v1 keys:
  - `v` = 1
  - `container`
  - `hub_id`
  - `mac_name` (≤ 60)
  - `owner_user` (the Mac's `CKContainer.userRecordID().recordName`)
  - `nonce` (32 random bytes, base64url, 43 chars, single use)
  - `iat`, `exp` with `exp = iat + 600`
  - optional `data_share` and `relay_share` (`CKShare.url`)
- The payload is under 700 bytes.
- The public link is open only while a QR is on screen, for at most 600 s.
- The phone waits 60 s for its grant.
- `link_codes` is pruned to the newest 50 rows.

**Hub timing and limits**
- Payload guard: `maxPayloadBytes = 900_000`. A record over it is skipped and not hashed, with a throttled warning.
- Hub full diff tick: 10 s.
- Fast lane: 1 s coalescing, with at least 2 s between fast sends.
- Mac relay poll: 3 s while a phone action was seen in the last 300 s, otherwise 30 s, plus CKSyncEngine pushes.
- Heartbeat: written every 300 s. The phone shows "online" while `updated_at` is under 720 s old. The heartbeat record is `heartbeat`, in **DataZone**.
- Relay action max age: 7 days.

**Phone sync and notifications**
- Foreground fetch: 5 s while Now or Workbench is on screen, 30 s otherwise.
- Shared-scope background: `BGAppRefreshTask` with `earliestBeginDate` 15 min.
- Subscriptions: `ask-alerts-v1` (private scope, `CKQuerySubscription`, `kind == "ask_alert"`, `.firesOnRecordCreation`, `alertLocalizationKey = "ASK_ALERT_GENERIC"`, `soundName = "default"`, `shouldSendMutableContent = true`, category `ASK`, no `desiredKeys`) and `shared-db-v1` (shared scope, silent database subscription).
- Notification categories: `ASK` and `ASK_QUICK`.

**Storage and signing**
- Hub sidecar directory: `~/Library/Application Support/Watchtower/MobileHub/` (`transport.db`, `hubstate.db`).
- The hub is opt-in in every flavor (Settings → Mobile, off by default).
- Corp-flavor notice, exactly: "Work data from this Mac will be stored in your personal iCloud account."
- The hub needs a Developer ID build with an embedded provisioning profile. `make app-dev` (ad-hoc) keeps the base entitlements and shows "Needs a signed build".

**Visual rules**
- Native iOS with SF. Light and dark follow the system.
- Accent is `Color.accentColor` (system blue).
- Orange is used only for "waiting for you" and asks. Red is used for recording and failures.
- App icon: `WatchtowerDesktop/Sources/Resources/Assets.xcassets/AppIcon.appiconset`.

**Repo hygiene**
- Everything in the repo is English.
- The repo is public. Fixtures use only `acme`, `example.com`, `~/Projects/acme` and "colleague A". No real ids, names, mail domains or local paths, and nothing read off a live install.

**Inner loop only**
- Go: `go test ./internal/<pkg>`.
- Desktop: `make test-swift FILTER=<Class>`.
- Kit: `make kit-test FILTER=<Class>` (added in Task 3).
- Phone: `make mobile-test MOBILE_FILTER=<Class>` (added in Task 11).
- Lint: `make lint-diff`.
- No full runs per task. Uninstall the simulator app before `make mobile-test` (spec §10).

**Lanes**
- Kit and Go tasks may run beside one Desktop or phone task.
- At most one Desktop or phone Swift lane links at a time (CLAUDE.md).
- Each lane works in its own worktree. The controller merges.

## Review focus

Five failure modes that no task's spec-derived tests cover. Each one has a test added to the task that owns it.

1. **Clock skew between Mac and phone at the scan.** A phone clock 5 min ahead would falsely reject a fresh code. The phone's local expiry check allows 120 s of grace, and the Mac's check is authoritative → Task 12.
2. **App killed mid-link,** after the share accept and before the grant. On relaunch the phone must resume waiting or restart cleanly, never sit half-linked → Task 12.
3. **Phone switches iCloud account while linked.** The phone wipes its replica and shows unlinked, and it never syncs the old account's shares under the new one → Task 12.
4. **Mac name edge cases.** Covers names over 60 characters, emoji ZWJ sequences cut at a grapheme boundary, and two phones with the same name, which the phone list tells apart by link date → Task 8.
5. **Backlog after a long Mac sleep.** 500 queued relay records are processed in 200-record batches with a re-nudge, each applied exactly once, and the heartbeat's `relay_backlog` counts down → Task 6.

---

## Task 1: S0 spike harness (throwaway)

**Depends on:** none. **Lane:** its own spike branch; nothing from it is merged.

**Files:** spike-only targets on a branch `spike/cloudkit-share`: a macOS command-line target and an iOS app target, signed for `iCloud.com.aiwatchtowers.watchtower`. They are not merged into main. The S0 PR carries the results and the owner's checklist.

**Interfaces:** none kept. The harness exercises these CloudKit APIs:
- `CKShare(recordZoneID:)` and `publicPermission`;
- `CKFetchShareMetadataOperation` and `CKAcceptSharesOperation`;
- `CKSyncEngine` on `.shared` and `.private`;
- `CKDatabaseSubscription` (silent) on the shared database;
- `CKQuerySubscription` with a visible alert in a private custom zone;
- `CKFetchShareParticipantsOperation` with `CKUserIdentity.LookupInfo(userRecordID:)`;
- `CKContainer.userRecordID()`.

**Must demonstrate (spec §13 S0), as buttons that print pass/fail with timings:**
- **(a)** A participant fetches both zones, sends a RelayZone record, and uploads a CKAsset of at least 60 MB that the owner downloads.
- **(b)** A silent shared-database push arrives with the app in the background.
- **(c)** After `publicPermission = .none`, the accepted participant keeps read access (DataZone) and read-write access (RelayZone). On a fail, the harness runs F2 in the same session: named participant via `LookupInfo(userRecordID:)`, then re-accept from the saved URL.
- **(d)** `userRecordID().recordName` is equal across macOS and iOS for one Apple ID, and differs for two Apple IDs.
- **(e)** A visible alert from a query subscription in a private custom zone, with the latency of each path.

**Checks:** builds for device. No unit tests (throwaway).

## Task 2: S0 spike run — OWNER-RUN, filed as an ask with a checklist

**Depends on:** Task 1.

**Setup:** the owner's Mac on the owner's Apple ID; iPhone 1 on the same Apple ID; iPhone 2 (or the same phone, re-signed in) on a test Apple ID.

**Checklist:** items (a)–(e) from Task 1, each recorded as pass/fail with a log in the S0 PR.

**Decisions this result feeds (spec §2.3, §13):**

| Item fails | Consequence |
|---|---|
| (a) | Stop A. The owner chooses between a hand-rolled shared-database sync and no different-Apple-ID support in the POC |
| (b) | The polling fallback ships: `BGAppRefreshTask` every 15 min plus the foreground fetch, and Settings shows "On this iPhone, notifications can be late" |
| (c) | F2 is the implementation. If F2 fails too, F3 needs the owner's written OK |
| (d) | Same-Apple-ID detection uses the zone lookup fallback (§2.3) |
| (e) | Private-scope alerts use the `AlertZone` fallback |

Tasks 4, 8 and 12 read this result.

## Task 3: Kit package port and split

**Depends on:** none. It may start before Task 2 ends; it does not touch scope code. **Lane:** Kit.

**Files:**
- Create `WatchtowerKit/Package.swift` with products `WatchtowerSync` and `WatchtowerKit`.
- Port as-is with `git show mobile-app:<path>`:
  - `Sync/JSONValue.swift`, `RowPayloadCoder.swift`, `CloudSyncTransport.swift`, `InMemoryCloudTransport.swift`, `CloudRecordFactory.swift`, `SliceRecord.swift`;
  - `CloudKitTransport/CloudKitTransport.swift`, `TransportStore.swift`;
  - `Relay/RelayCoder.swift`, `RelayRecordKind.swift`, `ActionOutbox.swift`, `ActionRequestPayload.swift`, `RelayFeed.swift`, `RecordingUploadPayload.swift`, `RecordingUploader.swift`;
  - `Replica/ReplicaStore.swift`, `+PendingActions`, `+PhoneRecordings`, `ReplicaHydrator.swift`.
- Move `HeartbeatPayload` out of `ChatPayloads.swift` into `Relay/HeartbeatPayload.swift`.
- Drop `Agent/*`, `ChatPayloads`/`ChatAssembler`/`ReplicaStore+Chat`, every model except `CalendarEvent`/`MeetingTranscript`/`SlackID` (those are adapted in C), and their tests.
- Port the sync-core test suites listed in spec §12.
- `Makefile`: add `kit-test` (`cd WatchtowerKit && swift test --filter '$(FILTER)'`).
- `WatchtowerDesktop/Package.swift`: the executable target `WatchtowerDesktop` depends on `WatchtowerSync` only. `WatchtowerCore` gets no Kit dependency.

**Interfaces produced:**
- `SliceKind`: the old cases are kept unpublished, plus `heartbeat` (DataZone) and `device_grant`.
- `RelayRecordKind`: `action`, `recording_upload`, and the new `device`. `heartbeat` stays for wire compatibility.
- `ActionKind`: + `probe`.
- `ActionStatus`: `pending`, `received`, `held`, `applied`, `failed`, `expired`, `cancelled`.
- `ActionRequestPayload`: + `device_id`, `reason`, `result`.
- `HeartbeatPayload` fields: `updated_at`, `app_version`, `hub_id`, `mac_name`, `flavor`, `last_publish_at`, `last_relay_at`, `relay_backlog`, `accounts[]` (`{kind, label ≤ 80, status}`, ≤ 20), `enabled_at`, `owner_user`, `sharing` (`available` | `unavailable` | `none`).
- `DevicePayload` fields: `device_id`, `name ≤ 60`, `model`, `app_version`, `scope`, `user_record_name`, `link_nonce?`, `unlinked?`, `typing_requested`, `start_sessions`, `updated_at`.
- `DeviceGrant` mirror fields: `device_id`, `hub_id`, `name`, `scope`, `linked`, `link_refused?` (`used_code` | `expired_code` | `unknown_code`), `linked_at`, `typing_allowed`, `start_sessions_allowed`, `decided_at`.
- The `reason` code enum, exactly as listed in spec §5.2, `device_not_linked` included.

**Tests:**
- `KitFixtureTests`: every kept kind and each new payload round-trips through a frozen fixture. A nil optional is encoded as an absent key.
- `SliceKindTests`: every raw value decodes. An unknown kind is stored in `slice_records` and not surfaced.
- `PublicAPISurfaceTests`: a grep test asserts that no file under `WatchtowerDesktop/Sources/WatchtowerCore` imports `WatchtowerSync` or `WatchtowerKit`.
- `ActionStatusTests`: an unknown status decodes as `pending` on the phone side.

**Checks:** `make kit-test FILTER='KitFixtureTests|SliceKindTests|ActionStatusTests'`, `make test-swift FILTER=PublicAPISurfaceTests`, `make lint-diff`.

## Task 4: database scopes and transport error handling

**Depends on:** Task 2 (results for (a) and (d)), Task 3. **Lane:** Kit.

**Files:**
- Modify `WatchtowerKit/Sources/WatchtowerSync/CloudKitTransport/CloudKitTransport.swift`, `CloudSyncTransport.swift` and `TransportStore.swift` (it stores the scope and owner name).
- Add `CloudDatabaseScope.swift`.

**Interfaces:**
- `CloudDatabaseScope { case private, shared(ownerName: String) }`, injected into `CloudKitTransport`.
- In `shared` scope the transport never issues `.saveZone` or `.deleteZone`.
- The transport emits `TransportEvent.unlinked`:
  - on a zone-deleted event in `shared` scope;
  - on `zoneNotFound`;
  - on `changeTokenExpired` for a zone that no longer exists.
- Error handling per spec §9:
  - `.limitExceeded`: halve the batch (200 → 100 → … → 1). A single record that still fails is logged with its record name, and its `slice_state` hash is cleared through a callback.
  - `.requestRateLimited` and `.zoneBusy`: honour `CKErrorRetryAfterKey`, with a default of 5 s doubling to a 120 s cap. While throttled, a `throttledSince` timestamp is exposed.
  - `.quotaExceeded`: sync pauses and `TransportEvent.quotaExceeded` is emitted.

**Tests (`CloudKitTransportScopeTests`, `CloudKitTransportErrorTests`, on the mapping and fake layers):**
- **Shared scope, no zone writes:** start, an account change and a reset each issue no zone save or delete.
- **Shared scope, unlinked:** zone-deleted → `unlinked`. `zoneNotFound` on fetch → `unlinked`. `changeTokenExpired` on an existing zone → re-fetch, not `unlinked`.
- **limitExceeded:** a 200-record batch with one bad record → batches 100, 50, …, 1, and only the bad record's hash is cleared. A 1-record batch that fails → logged, hash cleared, no infinite retry.
- **Rate limiting:**
  - `retryAfter` = 7 s → waits 7 s.
  - No `retryAfter` → 5 s, then 10 s.
  - The backoff caps at 120 s.
  - `throttledSince` is set; the Settings line appears after 60 s (asserted in Task 9).
- **quotaExceeded:** the event is emitted, and nothing is retried until `resume()`.
- **Private scope:** behaviour is unchanged from the branch (the ported mapping tests pass).

**Checks:** `make kit-test FILTER='CloudKitTransport'`, `make lint-diff`.

## Task 5: link payload codec

**Depends on:** Task 3. **Lane:** Kit, in parallel with Task 4 (different files).

**Files:** create `WatchtowerKit/Sources/WatchtowerSync/Link/LinkPayload.swift` and its test file.

**Interfaces:**
- `LinkPayload` with fields `v`, `container`, `hub_id`, `mac_name`, `owner_user`, `nonce`, `iat`, `exp`, `data_share?`, `relay_share?`.
- `LinkPayload.url() -> URL` builds `watchtower://link?d=<base64url, no padding, sorted keys>`.
- `LinkPayload.parse(_ url: URL) -> Result<LinkPayload, LinkPayloadError>`, where `LinkPayloadError` is `.notALink`, `.badEncoding`, `.missingField(String)`, `.newerVersion`, `.wrongContainer`.
- `LinkPayload.makeNonce()` returns 32 random bytes as 43 base64url characters.

**Tests (`LinkPayloadTests`):**
- A frozen fixture round-trips byte for byte.
- `v: 2` → `.newerVersion`.
- A missing `nonce` → `.missingField("nonce")`.
- `d` with padding or with invalid characters → `.badEncoding`.
- Another container → `.wrongContainer`.
- A `https://` URL → `.notALink`.
- Encoded size with both share URLs at 120 characters each is under 700 bytes.
- An absent share URL is an absent key.
- A `mac_name` of 61 characters is clipped to 60 at a grapheme boundary, including a ZWJ emoji at the boundary.
- The nonce is 43 characters, and 1000 nonces are all distinct.

**Checks:** `make kit-test FILTER=LinkPayloadTests`, `make lint-diff`.

## Task 6: hub skeleton on the Mac

**Depends on:** Tasks 3 and 4. **Lane:** Desktop Swift.

**Files:**
- Create under `WatchtowerDesktop/Sources/Services/MobileHub/`:
  - port and adapt `HubSyncState.swift` (tables `slice_state`, `hub_meta`, `relay_processed(record_name, phase, outcome)`; the old `chat_sessions` table is not created);
  - port `SliceDiff.swift`;
  - adapt `SlicePublisher.swift` (an empty `sliceSQL`; the non-SQL source protocol `SliceSource`; `nudge(kinds:)`; tick 10 s; fast lane 1 s / 2 s);
  - adapt `RelayProcessor.swift` (begun/done phases, hygiene sweep, max age 7 days, `probe`; refuses `target_done`, `target_snooze` and `task_create` with `unsupported_in_poc`);
  - create `MobileHubCommandDispatcher.swift` (`@MainActor`, empty handler table in A);
  - adapt `MobileHubService.swift`.
- Modify `WatchtowerDesktop/Sources/App/AppState.swift`: add `initMobileHub(dbPool:)`, called at the end of `initWorkbenches` (`:1703-1778`). It is torn down and rebuilt where `initWorkbenches` re-runs. The hub is built only when `mobileSyncEnabled` is on.
- Modify `WatchtowerDesktop/Sources/WatchtowerCore/Utilities/Constants.swift`: add `mobileSyncEnabledKey`.
- Docs:
  - create `docs/features/mobile-companion.md` (architecture, scopes, kinds; extended by later tasks);
  - add a feature index line to `CLAUDE.md`.

**Interfaces:**
- `SliceSource { kind: SliceKind; func records(_ db: Database) throws -> [SliceRecord] }`, used by B and C.
- `SlicePublisher.nudge(kinds: Set<SliceKind>)`.
- `RelayProcessor` exactly-once handling per spec §5.2 rule 1.
- `MobileHubCommandDispatcher.register(_ kind: ActionKind, handler:)`.

**Tests (`MobileHubServiceTests`, `RelayProcessorTests`, `SlicePublisherTests`, on `InMemoryCloudTransport`):**
- **Toggle off:** no transport is created and nothing is written. Toggling on, then off, then on creates exactly one hub.
- **Payload guard:** an empty payload publishes. A payload of exactly 900_000 bytes publishes. One of 900_001 bytes is skipped, not hashed, and warned once per (recordName, hash).
- **Probe:** a `probe` delivered twice echoes `applied` once with `{nonce, hub_id}`.
- **Interrupted apply:** a record found `begun` at start → `failed` with `outcome_unknown`, never applied again.
- **Age:** a record 7 days + 1 s old → `expired`; one 6 days old is applied.
- **D kinds:** `task_create` → `failed` with `unsupported_in_poc`.
- **Long sleep (Review focus 5):** 500 pending relay records are processed across batches of 200 with a re-nudge, each `probe` is echoed exactly once, and `relay_backlog` falls to 0.
- **Fast lane:** a `nudge` inside the 1 s window coalesces into one send, and two nudges 1.5 s apart produce sends ≥ 2 s apart.
- **Restart:** `initWorkbenches` re-running tears the old hub down (no second publisher).

**Guards that must stay green unchanged:** `AppStateTests`, and the PROJ-11 and PROJ-12 suites (`SessionAgentStateCenterTests`, `OwnerAsksViewModelTests`), because `initWorkbenches` is touched.

**Checks:** `make test-swift FILTER='MobileHubServiceTests|RelayProcessorTests|SlicePublisherTests|AppStateTests|SessionAgentStateCenterTests|OwnerAsksViewModelTests'`, `make lint-diff`.

## Task 7: heartbeat and the single-hub rule

**Depends on:** Task 6. **Lane:** Desktop Swift.

**Files:** modify `MobileHubService.swift`; create `HubIdentity.swift` (stores `hub_id` and `enabled_at` in `hub_meta`).

**Interfaces:**
- A `heartbeat` record in DataZone, rewritten every 300 s with every field from Task 3, `flavor` included (`default` | `corp`).
- `accounts[]` comes from the Desktop's account rows: label and status only, never a token.
- Enabling the hub reads `heartbeat`. If it holds a foreign `hub_id` with `updated_at` under 720 s old, `enable()` returns `.otherHub(macName)`. `takeOver()` writes this hub's heartbeat. A hub that reads a foreign `hub_id` stops publishing with status `.tookOver(macName)`.

**Tests (`HubSingleHubTests`):**
- A foreign heartbeat 719 s old → refused. One exactly 720 s old → allowed.
- No heartbeat → allowed.
- Take over: the other (fake) hub stops after its next read.
- `enabled_at` is set on the first enable and kept across an app relaunch.
- `accounts` holds no key named `token`, `secret` or `password` (key scan).
- `mac_name` of 70 characters → 60, at a grapheme boundary.

**Checks:** `make test-swift FILTER=HubSingleHubTests`, `make lint-diff`.

## Task 8: MobileLinkCenter, the Mac side of linking

**Depends on:** Tasks 2 ((c) and (d) results), 5 and 7. **Lane:** Desktop Swift.

**Files:**
- Create `WatchtowerDesktop/Sources/Services/MobileHub/MobileLinkCenter.swift` and `ShareService.swift` (a protocol plus a CloudKit implementation; a fake for tests).
- Create `hubstate.db` tables:
  - `link_codes(nonce PRIMARY KEY, issued_at, exp, used_by_device, used_at)`, pruned to 50;
  - `devices(device_id, name, scope, user_record_name, linked_at, typing_allowed, start_sessions_allowed, decided_at)`.
- Publish a `device_grant` `SliceSource`.

**Interfaces (spec §2.3):**
- `MobileLinkCenter.issueCode() -> LinkPayload`:
  - creates the two zone shares on first use;
  - opens the public link (DataZone `.readOnly`, RelayZone `.readWrite`);
  - `exp = iat + 600`.
- `closeLink(reason:)` runs on use, on expiry and when the sheet closes. It sets `publicPermission = .none`, then removes every participant not bound to a used nonce. Or it follows F2 if Task 2 said so.
- `handleDevice(_ record:)`:
  - A valid nonce links the device: it must be known, unused and `exp ≥ now`, and in `shared` scope the record's `creatorUserRecordID.recordName` must equal `user_record_name` and be an accepted participant of both shares.
  - The same nonce from the same device is idempotent.
  - Otherwise it publishes `link_refused` with `used_code`, `expired_code` or `unknown_code`.
- `remove(deviceID:)` deletes the device from `devices`, deletes its `device_grant`, and in `shared` scope removes the participant.
- `takeOverReset()` deletes both shares and clears `devices`.
- `RelayProcessor` device gate (spec §5.2 rule 4): an unlinked `device_id`, or a creator mismatch, → `failed` with `device_not_linked`.
- `accountAvailability() -> .available | .noAccount | .restricted`.

**Tests (`MobileLinkCenterTests`, fake ShareService and fake clock):**
- **One link, idempotent:** a valid code links once. The same QR scanned twice by the same phone gives one row and one grant.
- **Refusals:** a second phone with a used code → `used_code`. Code age 601 s → `expired_code`. A made-up nonce → `unknown_code`.
- **Two phones,** each with its own code: both are linked. Removing one leaves the other's actions applied.
- **Shared scope, wrong creator:** a `device` record whose creator differs from `user_record_name` → refused, with no grant.
- **Unlinked device:** a relay action from an unlinked `device_id` → `device_not_linked`, never dispatched.
- **Closing the link:** it closes at use, at 600 s and on `sheetClosed`. A participant bound to no used nonce is removed, and the bound participant is kept.
- **Account:** `.noAccount` and `.restricted` → `issueCode()` refuses, with no share created.
- **Take over:** `takeOverReset` deletes the shares, so the next `issueCode` creates new ones, and `devices` is empty.
- **Pruning:** `link_codes` keeps the 50 newest after 60 issues.
- **Review focus 4:** two phones named "iPhone" are both listed and distinguished by `linked_at`; a 70-character emoji name is clipped at a grapheme boundary.
- **Same Apple ID:** a `private`-scope phone needs no share calls.

**Checks:** `make test-swift FILTER='MobileLinkCenterTests|RelayProcessorTests'`, `make lint-diff`.

## Task 9: Settings → Mobile on the Mac

**Depends on:** Task 8. **Lane:** Desktop Swift.

**Files:**
- Modify `WatchtowerDesktop/Sources/Views/Settings/SettingsView.swift`: `SettingsTab` gains `mobile` (`:6-7`).
- Create `WatchtowerDesktop/Sources/Views/Settings/MobileSettingsView.swift`, `MobileLinkSheet.swift` and the view models `MobileSettingsViewModel`, `MobileLinkSheetViewModel`.
- Docs:
  - `docs/app-guide.md`: a new "Mobile" section (toggle, QR, phone list);
  - `docs/features/mobile-companion.md`: Mac UI.

**Interfaces:**
- **Toggle:** "Use Watchtower on iPhone" opt-in, off by default.
- **Hub status:** on, last publish, backlog, "iCloud is slowing sync down" after 60 s of throttling.
- **Corp notice:** shown only in the corp flavor, with the exact text above.
- **Use Watchtower on iPhone:** a QR sheet with a 10-minute countdown and **New code**.
- **Phone list:** name, "Same Apple ID" or "Shared", link date, typing state, **Allow…** / **Revoke** / **Remove**. Allow and Revoke write `devices.typing_allowed`; it takes effect in B.
- **Remove a same-Apple-ID phone:** shows "Removed. It is signed into your Apple ID, so it can still read synced data until you sign it out of iCloud".
- **Messages:**
  - "Mobile isn't available on this Mac: iCloud is off."
  - "Mobile isn't available on this Mac: iCloud is restricted by your organization."
  - "Needs a signed build" with the toggle disabled when `CloudKitTransport.entitlementPresent()` is false.
  - "<mac_name> is your hub. Turn it off there, or Take over".

**Tests (`MobileSettingsViewTests` with ViewInspector, `MobileSettingsViewModelTests`):**
- An ad-hoc build shows "Needs a signed build" with the toggle disabled.
- The corp flavor shows the notice, and the default flavor does not.
- `.noAccount` and `.restricted` show their sentences and no QR button.
- Countdown at 0 → "Show a new code", and the link is closed (`closeLink(.expired)` called).
- Closing the sheet calls `closeLink(.sheetClosed)`.
- Allow sets `typing_allowed`, and Revoke clears it.
- 61 s of throttling shows the slowing line, and 59 s does not.

**Checks:** `make test-swift FILTER='MobileSettingsViewTests|MobileSettingsViewModelTests'`, `make lint-diff`.

## Task 10: cloud signing in build-app.sh

**Depends on:** none. **Lane:** scripts (parallel to any).

**Files:**
- Modify `scripts/build-app.sh` beside `:416-418`: with a real identity and `WATCHTOWER_PROVISION_PROFILE` set, sign with `scripts/Watchtower-cloud.entitlements` (create it: iCloud container `iCloud.com.aiwatchtowers.watchtower`, CloudKit service, `aps-environment`) and embed `Contents/embedded.provisionprofile`. The ad-hoc path (`:425-428`) keeps `scripts/Watchtower.entitlements`. Both flavors use the same container.
- Create `scripts/tests/test-build-app-cloud.sh`.
- Docs: a short build note in `docs/features/mobile-companion.md`.

**Tests (`scripts/tests/test-build-app-cloud.sh`, run by `make test-scripts`):**
- A stubbed real identity plus a profile → the cloud entitlements are used and the profile is embedded.
- The ad-hoc path → the base entitlements only.
- A real identity without a profile → the base entitlements and a warning line "hub disabled: no provisioning profile".
- `BUILD_FLAVOR=corp` → the same container.

**Checks:** `bash scripts/tests/test-build-app-cloud.sh`, `make lint-diff`.

## Task 11: phone app shell

**Depends on:** Tasks 3 and 5. **Lane:** phone Swift (not at the same time as a Desktop lane link).

**Files:**
- Port and adapt `WatchtowerMobile/project.yml`: the app plus the two extensions, the app group, iCloud/CloudKit and push entitlements, `Base.xcconfig`, `Signing.xcconfig.template`, `Info.plist` (URL scheme `watchtower`, camera usage string, background modes: remote-notification, audio, fetch).
- Regenerate the project with `make mobile-gen`. Never hand-edit it.
- `App/AppEnvironment.swift` (transport switch by `entitlementPresent()`; demo otherwise), `App/DemoSeed.swift` (rewritten: heartbeat and device_grant; B and C extend it), `App/RootTabView.swift` (tabs Now, Workbench, Calendar, More), `Features/Settings/SettingsView.swift`.
- `Assets.xcassets/AppIcon` exported from the desktop AppIcon.
- `Makefile`: port `mobile-gen/build/test/run/archive`; add `MOBILE_FILTER` → `-only-testing:WatchtowerMobileTests/$(MOBILE_FILTER)`.
- `.gitignore`: `Signing.xcconfig`.

**Interfaces:**
- **Settings → Your Mac:** online when the heartbeat is under 720 s old; mac name; "last sync" (phone's last fetch); queued (pending outbox rows); accounts read-only.
- **Settings → Workbench toggles:** "Type into sessions from this phone" (off) and "Start sessions from this phone" (on). They write the `device` record.
- **Settings → Notifications:** "New asks" (on).
- **Settings → "Chat without the Mac — later":** a disabled row.
- **More:** Settings only.

**Tests (`SettingsWiringTests`, `ReplicaWiringTests`, `RootTabTests`):**
- Heartbeat 719 s old → online; 720 s → offline.
- No heartbeat → "Your Mac has not connected yet".
- The queued count equals the pending outbox rows (0, 1 and 25).
- `ReplicaWiringTests` counts match DemoSeed after an uninstall.
- Exactly four tabs in order: Now, Workbench, Calendar, More.
- Toggling "Type into sessions" writes `typing_requested: true` once (idempotent on a repeated toggle).

**Checks:** `make mobile-gen`, `make mobile-test MOBILE_FILTER='SettingsWiringTests|ReplicaWiringTests|RootTabTests'`, `make lint-diff`.

## Task 12: phone onboarding and linking

**Depends on:** Tasks 2, 4, 5, 8 and 11. **Lane:** phone Swift.

**Files:**
- Create `WatchtowerMobile/Sources/Features/Onboarding/`: `WelcomeView`, `ScanView` (AVFoundation QR plus the `watchtower://link` URL handler), `LinkingViewModel`, `LinkedView`, `MacNotShowingView`.
- Create `WatchtowerMobile/Sources/App/LinkStore.swift`: linked `hub_id`, scope, owner name, saved share URLs.
- Settings: **Unlink this Mac**.
- Docs:
  - `docs/app-guide.md`: an "iPhone" section covering onboarding and unlinking;
  - `docs/features/mobile-companion.md`: linking.

**Interfaces (spec §2.3):**
- The scan flow follows spec §2.3 steps 1–6:
  1. Parse the payload. Expired → "This code expired — Show a new code on the Mac". The local check rejects only when `exp < now − 120 s`.
  2. Check `accountStatus`. Not available → "Sign in to iCloud on this iPhone to use Watchtower".
  3. Pick the scope by comparing `owner_user` with the phone's `userRecordID().recordName` (or the Task 2 fallback). In `shared` scope, fetch the share metadata and accept both shares. A missing or failed URL → "This Mac can't share with another Apple ID right now — Show a new code on the Mac".
  4. Write the `device` record with `link_nonce`.
  5. Wait 60 s for the grant. None → "Your Mac didn't answer — keep Settings → Mobile open on the Mac and scan again". `link_refused` → "This code can't be used — Show a new code on the Mac".
  6. Then show "Linked to <Mac name>", request notification permission, and open Now.
- **Switch:** "Switch from <old Mac> to <new Mac>?".
- **Unlink:** write `unlinked: true`, leave the shares in `shared` scope, wipe the replica and outbox (pending items are reported "Not sent"), and go back to Welcome.
- **Unlinked events:**
  - `TransportEvent.unlinked` → "This Mac removed this phone".
  - The heartbeat's `hub_id` differs from the linked one → "Watchtower moved to <mac_name> — scan the code on that Mac".
  - Stale for 24 h → "Your Mac hasn't synced for a day — if it changed iCloud account, link again".
- **"The Mac doesn't show up" checklist:** Watchtower is open on the Mac, Settings → Mobile is on, the Mac is awake, it is a signed build, iCloud is on.

**Tests (`LinkingViewModelTests` with a fake container and transport, a fake clock and a fake grant feed):**
- **Same Apple ID with share URLs:** a same-Apple-ID payload that carries share URLs → `private` scope, and accept is never called.
- **Different Apple ID:** → both shares accepted, then `shared(ownerName)`, then the device record is written to the shared database.
- **Expiry:** `exp` 1 s ago → still proceeds (grace). `exp` 121 s ago → the expired message and nothing written.
- **Clock skew (Review focus 1):** a phone clock 5 min ahead and a code issued 1 min ago → proceeds, and the Mac's grant decides.
- **Phone not in iCloud:** `.noAccount` → the sign-in message.
- **Grant wait:** no grant in 60 s → "didn't answer". `link_refused: used_code` → "can't be used".
- **Same QR twice:** scanning the same QR twice on a linked phone → stays linked, with no second device-record write beyond the idempotent rewrite.
- **Killed mid-link (Review focus 2):** the app is killed after accept and before the grant; on relaunch it resumes waiting until the remaining part of the 60 s, then offers to scan again. It is never shown as linked.
- **iCloud account switch (Review focus 3):** the phone's iCloud account changes while linked → the replica is wiped and Welcome is shown.
- **Unlink:** wipes the replica and outbox, and three pending items are reported "Not sent".
- **Removed while offline:** a `TransportEvent.unlinked` arriving after offline time → the removed message and a wipe.
- **Hub changed:** the heartbeat's `hub_id` changes → the moved message, and no writes are sent.
- **Switch Mac:** scanning another Mac's QR → the confirm prompt, and No keeps the old link.
- **Other payloads:** `v: 2` → "Update Watchtower on this iPhone". A camera-opened `watchtower://link` URL runs the same flow as an in-app scan.

**Checks:** `make mobile-test MOBILE_FILTER=LinkingViewModelTests`, `make lint-diff`.

## Task 13: notification plumbing

**Depends on:** Tasks 2 ((b) and (e) results) and 11. **Lane:** phone Swift.

**Files:**
- `WatchtowerMobile/NotifyService/NotificationService.swift` (NSE) and `WatchtowerMobile/NotifyContent/NotificationViewController.swift` (the content extension's options UI; the answer write is wired in B).
- `App/NotificationCoordinator.swift`: adapted, re-keyed on `ask_alert` with the alert watermark.
- `App/SubscriptionManager.swift`.
- Kit: add `SliceKind.askAlert = "ask_alert"` and the `AskAlert` mirror (`ask_id`, `workbench_id`, `workbench_name ≤ 60`, `session_id`, `kind`, `title ≤ 120`, `quick`).

**Interfaces:**
- `ask-alerts-v1` exactly as in the Global constraints (or the `AlertZone` fallback, if Task 2(e) failed).
- In `shared` scope: the `shared-db-v1` silent database subscription, a local notification on a newly applied `ask_alert` (deduplicated by `ask_id`), `BGAppRefreshTask` with `earliestBeginDate` 15 min, and the Settings line "On this iPhone, notifications can be late".
- NSE: fetch `ask_alert-<id>` within 25 s; title = `workbench_name`; body = `title`; category `ASK_QUICK` when `quick`, else `ASK`; `userInfo.ask_id`. On failure the generic text and `ASK` stay.
- Category `ASK` has one action, "Open the ask", which deep-links to the ask.
- The Settings toggle saves or deletes `ask-alerts-v1` in private scope (label "New asks (all your devices)"). In shared scope it switches local alerts on or off.

**Tests (`NotificationTests`, `NotificationServiceTests`, `SubscriptionManagerTests`):**
- The NSE with a fixture record rewrites the title and body and sets `ASK_QUICK` for `quick`.
- An NSE fetch timeout (fake 26 s) → the generic text and `ASK`.
- A shared-scope fetch applying the same `ask_alert` twice → exactly one local notification.
- An `ask_alert` older than the watermark → no notification.
- Toggle off in private scope → the subscription is deleted. Toggle on → it is saved once (a second save is idempotent).
- The shared-scope Settings line is shown in shared scope only.

**Checks:** `make mobile-test MOBILE_FILTER='NotificationTests|NotificationServiceTests|SubscriptionManagerTests'`, `make kit-test FILTER=KitFixtureTests`, `make lint-diff`.

## Task 14: A3 real-iCloud device smoke — OWNER-RUN, filed as an ask with a checklist

**Depends on:** Tasks 6–13 merged and a `make app` build with a profile.

**Setup:** the owner's Mac; iPhone 1 on the same Apple ID; iPhone 2 on a second Apple ID.

**Checklist (spec §13 A3; each item pass/fail in the ask):**
- **(a)** A probe slice reaches the phone in ≤ 15 s, measured 10 times; record the p50 and p90.
- **(b)** A probe action round-trips in ≤ 30 s.
- **(c)** A 60 MB CKAsset uploads from the phone.
- **(d)** A silent push arrives in the background.
- **(e)** A visible `ask_alert` arrives on the lock screen (a test `ask_alert` written by a debug menu item on the Mac).
- **(f)** A record ≥ 800 KB saves.
- **(g)** Sign-out and sign-in reset cleanly.
- **(h)** iPhone 1 links in `private` scope.
- **(i)** iPhone 2 links in `shared` scope and reads the probe.
- **(j)** iPhone 1 scanning a QR with share URLs links in `private` scope.
- **(k)** The Mac signs out of iCloud after linking: offline, and resumed on sign-in.
- **(l)** iPhone 2 is removed on the Mac while in airplane mode, and shows "This Mac removed this phone" at its next fetch.

**Gate:** no B or C task that needs CloudKit behaviour starts until this passes, or until the owner accepts each failed item in writing. Pure-logic B and C tasks may proceed (each plan names them).
