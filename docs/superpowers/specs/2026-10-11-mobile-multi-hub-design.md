# Mobile companion — one phone, several Macs (multi-hub) — design

Date: 2026-10-11. Status: draft for owner review. Phase F of the mobile POC (after A–E).
Builds on `docs/superpowers/specs/2026-10-07-mobile-poc-design.md` (the POC spec, "the base spec") and `docs/features/mobile-companion.md`.

## 1. Goal

A phone links to more than one Mac hub and switches between them. Both setups work:

- several Macs on the phone's own Apple ID (private database);
- Macs on other Apple IDs (a personal and a work Mac), reached through zone shares (shared database);
- any mix of the two.

Decisions taken with the owner (asks #21–#27, #41–#43):

| Question | Decision |
|---|---|
| Scenario | Both: same Apple ID and different Apple IDs |
| Presentation | **Switcher** — one active Mac on screen, like accounts in a mail client; no merged views, no cross-hub deduplication |
| Inactive Macs | Kept in the background at a lower cadence: pushes, badge and online state work for every Mac (§5.3 explains why this means a full replica) |
| Timing | Fully inside the POC, as phase F |
| Architecture | **Transport per hub** behind the `CloudSyncTransport` protocol, proved by a device spike first; a multiplexing transport is the fallback (§4.3) |
| Discovery | Every Mac links through its QR code, including Macs on the phone's own Apple ID; no auto-discovery |

Non-goals: merged Now/calendar/asks across Macs, deduplicating sources two Macs share, choosing a target Mac per action, cloud cleanup of a dead hub's zones, more than 4 linked Macs.

## 2. What changes in the base spec

- **Invariant I-1 ("one Mac per iCloud account publishes, a phone links to exactly one hub") is replaced** by: *a hub publishes only into its own zones; a phone links to at most 4 hubs and shows one at a time.*
- Spec §2.3 step 6 ("switch from <old> to <new>?" with unlink of the old hub) is dropped: linking a new Mac adds it.
- The take-over flow (`otherHub`, `takeOver()`, `tookOver`, risk 6) is removed.
- The link flow (A8 Mac `MobileLinkCenter`, A12 phone link persistence) is not built yet; it is built multi-hub from the start, per this spec.

## 3. Mac hub

### 3.1 Zones per hub

The hub writes `DataZone-<hub_id>` and `RelayZone-<hub_id>` in its owner's private database. `hub_id` is the existing per-install UUID in `hub_meta` (`HubSyncState.ensureHubID()`), kept across account resets. Zone shares are zone-wide, so per-hub zones are also what lets two Macs on one Apple ID share different data with different people.

### 3.2 Hub identity

- `HubIdentity` keeps `hub_id`, `enabled_at` and the heartbeat. The foreign-heartbeat read, the refusal (`.otherHub`), `takeOver()`, the `onTakeOver` seam and the heartbeat-tick stop (`.tookOver`) are removed. The heartbeat is still written every 300 s, into the hub's own DataZone.
- Two installs on one Mac (two build flavors) are two hubs; the phone tells them apart by `flavor`.

### 3.3 Zone lifecycle

- Only the hub creates and deletes its zones.
- Turning the mobile hub off in Settings deletes the hub's two zones (the phones see an unlink, §6) and its staged assets.
- A reinstall that loses the sidecar makes a new `hub_id`; the old zones stay behind. They are small, the phone shows that Mac as long offline and offers Forget (§5.6). No cloud cleanup in phase F.

### 3.4 Shares and link

A8 creates two zone-wide shares per hub (DataZone read-only, RelayZone read-write) at the first QR and reuses them, as the base spec says, on the hub's own zones. `LinkPayload` goes to `v: 2` (§6.7); its fields are unchanged (`hub_id` already present).

### 3.5 Action addressing

`ActionRequestPayload` and `RecordingUploadPayload` gain `hub_id`. `RelayProcessor` echoes `failed` / `wrong_hub` for a record whose `hub_id` is not its own (defence in depth; the per-hub outbox already makes misrouting impossible).

### 3.6 No migration

POC only, no users: the hub deletes the legacy fixed-name `DataZone`/`RelayZone` at its first start on the new build (only when they hold its own heartbeat or no heartbeat), and test phones link again.

## 4. Kit (WatchtowerSync)

### 4.1 Transport knows its hub

- `CloudKitTransport(store:, scope:, hubID:, role:)`; `role` is `.hub` or `.phone`.
- The protocol stays keyed by zone kind: `CloudZoneID` (`.data`, `.relay`) remains the API's zone parameter. The transport maps a kind to `CKRecordZone.ID(zoneName: "<Kind>Zone-<hubID>", ownerName: …)`. Callers (`SlicePublisher`, `RelayProcessor`, `HubIdentity`, `ReplicaHydrator`, `RelayFeed`, `ActionOutbox`, `RecordingUploader`) change only where the transport is built.
- `cloudZone(for:)` maps a server zone back to a kind only when the name matches this transport's hub and, in shared scope, the owner matches. Two hubs of one foreign owner never cross. `ckRecord(from:)`, `existingZoneNames` and every inbound/outbound filter go through it.
- Zone writes depend on `role`, not on scope: only `.hub` saves zones. A `.phone` transport never creates or deletes a zone, so a removed hub's zone is never resurrected.

### 4.2 Each engine limited to its zones

Every fetch and send passes `CKSyncEngine.FetchChangesOptions(scope: .zoneIDs(own))` and `SendChangesOptions(scope: .zoneIDs(own))`. A transport neither downloads nor sends another hub's changes.

### 4.3 Spike F0 and the fallback

Phase F opens with a device spike (about 2 h, throwaway code), three phone-role transports on one private database plus one shared-scope pair:

1. each engine sees only its own zones' changes;
2. a silent push wakes the app and every engine catches up;
3. deleting one hub's zones fires `zoneGone` only in that hub's transport;
4. two hubs of one foreign owner work side by side in shared scope;
5. engine states survive a relaunch without clobbering each other.

If any check fails, the fallback is a **multiplexing transport**: one `CKSyncEngine` per database, and a per-hub view object implementing `CloudSyncTransport` over it. Everything above the protocol (§5) is unchanged.

### 4.4 Stores

One `TransportStore` per hub, in its own file. `adoptScope` keeps its wipe-on-scope-change semantics, now per hub. Mac path unchanged (`MobileHub/transport.db`); phone paths in §5.1.

## 5. Phone

### 5.1 Hub registry

`HubRegistry` in `<appGroup>/hubs.sqlite`: one row per linked hub — `hub_id`, `mac_name`, `flavor`, scope (`private` or `shared(owner)`), share URLs, `linked_at`, `sort_order`, `state` (`linked`, `unlinked_by_mac`) — plus the active `hub_id`. At most 4 rows. The phone's `device_id` (Keychain) is one for all hubs; each hub issues its own `device_grant-<device_id>`.

Per-hub files live in `<appGroup>/hubs/<hub_id>/`: `cloudkit-transport.sqlite`, `replica.sqlite`, the recordings marks and the alert watermark (in `replica_meta`).

### 5.2 HubSession

`HubSession` is today's `AppEnvironment` object graph for one hub: transport, `TransportStore`, `ReplicaStore`, `ReplicaHydrator`, `RelayFeed`, `ActionOutbox`, `RecordingUploader`, the writers (`BoardWriter`, `AskAnswerer`, `SessionStarter`, `SessionReportRequester`), `DeviceSettings` and the replica models. `AppEnvironment` owns the registry, one session per linked hub and `activeSession`; the UI reads the active one. Switching resets navigation to the root; `AskDraftStore` is keyed by hub so drafts survive a switch.

### 5.3 Inactive hubs: same data, lower cadence

A CloudKit fetch is per zone and advances one change token for the whole zone, so a hub cannot pull only `heartbeat` and `ask_alert`: skipped records would be lost behind the token. An inactive session therefore keeps a full replica but syncs less often:

- data fetch on a silent push and every 5 min while the app is in the foreground (the active hub keeps 5 s / 30 s);
- the relay loop runs only while the session has pending actions or uploads;
- side effect: switching is instant and works offline.

### 5.4 Recording

A recording goes to the Mac that was active when it started; the ledger row records that `hub_id`, and that session's uploader finishes it even after a switch. The recordings list shows the active hub's recordings. One microphone, so one capture at a time across hubs.

### 5.5 Notifications and badge

- Private scope: one query subscription per hub, `ask-alerts-<hub_id>`, on `kind == "ask_alert"` in `DataZone-<hub_id>` (base spec §7, made per hub). It is created by the phone's session for that hub.
- Shared scope: a local notification raised when any session's fetch applies a new `ask_alert`, deduplicated by that hub's watermark (base spec §7).
- Every notification carries `hub_id`; a tap activates that hub and opens the ask.
- A silent push refreshes every session.
- The app icon badge is the sum of open asks across hubs.

### 5.6 Switcher UI

- A chip with the active Mac's name at the top of Now and Workbench opens the list of Macs: name, `flavor`, an online dot (heartbeat under 720 s), the open-ask count; at the bottom **Add Mac** (QR scan).
- Settings → Macs: reorder, unlink any Mac, Forget a long-offline or Mac-unlinked one.
- Two Macs with the same name also show a short `hub_id` suffix.

### 5.7 Linking and unlinking

- Linking runs the base spec §2.3 flow for one hub and adds a registry row; the new Mac becomes active. A fifth Mac is refused with a message.
- Unlinking a Mac (base spec unlink for that hub) deletes its directory and row. If it was active, the next Mac in order becomes active; with none left the app returns to onboarding.

## 6. Errors

1. **Hub zones vanish** (the Mac turned the hub off, removed the phone or deleted the share): that session gets `.unlinked`, its row turns `unlinked_by_mac`, its data stays read-only until Forget. Other hubs are untouched.
2. **The phone's Apple ID changes**: every session and the registry are wiped (accepted shares belong to the account too); onboarding.
3. **Quota, rate limit, store failure** stay within one hub's transport; the row shows the error.
4. **Misaddressed record**: `wrong_hub` echo (§3.5).
5. **Reinstalled Mac** with a new `hub_id`: old row shows "offline N days", Forget; link the new hub by QR.
6. **Duplicate Mac names**: `flavor` + `hub_id` suffix.
7. **Versions**: `LinkPayload v: 2`; an older phone shows "Update Watchtower on this iPhone"; a v2 phone refuses a v1 code with "Update Watchtower on this Mac".

## 7. Testing

- **Kit** (fake engine): zone naming per hub, `cloudZone(for:)` filter by hub and owner, only `.hub` writes zones, fetch/send scope set to own zones, per-hub `adoptScope`.
- **Mac**: `HubIdentity` without I-1, disable deletes the hub's zones, `wrong_hub` echo, legacy zone removal rules.
- **Phone**: `HubRegistry` (limit, order, active), `AppEnvironment` with two in-memory transports (switch, unlink one, badge sum, inactive cadence), notification tap routing, recording finishing on its hub after a switch. `DemoSeed` seeds two hubs.
- **Device**: spike F0 first; at the end of the phase an owner smoke check with two Macs — one on the phone's Apple ID, one on another — filed as an ask with a checklist.

## 8. Phase F outline (for the plan)

1. F0 spike on device (go/no-go for transport per hub).
2. Kit: hub-aware transport, role, scoped fetch/send.
3. Mac: per-hub zones, I-1 and take-over removal, disable deletes zones, legacy zone cleanup, `wrong_hub`.
4. Phone: `HubRegistry`, `HubSession` split of `AppEnvironment`, per-hub files.
5. Phone: inactive cadence, notifications per hub, badge.
6. Phone: switcher chip, Settings → Macs, Add Mac.
7. Link flow A8/A12 built against this spec (multi-hub from the start).
8. Docs: `docs/features/mobile-companion.md`, base spec I-1 note.
9. Owner smoke on two Macs.
