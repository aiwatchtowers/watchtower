# Relay client — Watchtower side of the paid relay transport

**Status:** draft · **Date:** 2026-10-29 · **Board:** #1230 (umbrella), #1236 (this spec)
**Server design (contract):** `aiwatchtowers/relay` → `docs/superpowers/specs/2026-10-28-relay-design.md` (below: "relay spec"), approved in ask #712; the server moves from AWS to Cloudflare (Workers + Durable Objects + R2) per `docs/superpowers/specs/2026-10-29-relay-cloudflare-design.md` on `feature/relay-cf` (under review in the relay workbench, ask #743), with protocol v1, the proto schema and the client rules unchanged. **Client rules (executable):** `relay/sim/README.md` (below: "sim rule N") with its tests in `relay/sim/sim_test.go`. **Wire contract:** `relay/proto/relay/v1/relay.proto` + `relay/proto/README.md`.

This spec does not repeat the relay spec. It says how Watchtower (Kit, Desktop hub, iPhone app) implements relay spec §9, in which order, and what changes for users who never pay.

## 1. Goal and boundaries

- A paying phone and its Macs run entirely over the relay: slices, actions, echoes, attachments, pushes, transport switch, subscription. Target: action on the phone → result on the phone screen **p50 < 500 ms** on a good network.
- Free users stay on CloudKit. Their crypto, zones, shares and pairing do not change. Two changes reach them too (owner, conversation on ask #795):
  1. one action path for both transports: the hub applies each phone's actions in order with an outbox and control records, and the mailbox lane uses conditional writes on CloudKit (§5). The gain for free users is order: two quick lines to an agent are applied in the order they were sent, which today's path does not guarantee. Nothing else on screen changes in normal use;
  2. the hub publishes on change (§6) — on both transports, faster spacing on the hosted relay only (ask #735).

  The reasons for (1), by the owner's weight: order for everyone; one path in the code instead of two kept forever (§5.11, rejected); and the transport switch, which moves unechoed actions with the same bytes and order (sim rule 13) and so needs the ordered path before the switch.
- **At launch, relay links keep today's key scheme** (90-day epochs, static-static pairwise keys) plus a new epoch at every transport switch. The 7-day rotation with ephemeral X25519 (relay spec §7.4) comes in Phase 5, after launch; relay spec §9 allows that. Until then the relay's "middle" forward secrecy rests on delete-after-delivery and latest-version-only storage alone.
- The relay server, its protocol and its Go reference client are the relay repository's; changes there go through the relay session (ask #734). This spec only lists what it needs from there (§12).
- Not in this spec: Android, web, the full ratchet.

## 2. Names

"Relay" already means something in this codebase: the CloudKit **action lane** — `RelayZone`, `RelayProcessor`, `RelayFeed`, `RelayRecordKind`, `relay_seen`, `CloudZoneID.relay`, the AAD zone byte `relay = 2`. Renaming all of that would touch the E2E format and many tests for no gain.

- The existing names keep their meaning: **the mailbox lane** (phone ↔ hub records), on any transport. `CloudZoneID.relay` is that lane; its AAD byte stays `2`, `.data` stays `1` (`KeyDerivation.zoneByte` never changes).
- The new server is the **hosted relay**. Its Swift types carry `Hosted`: `HostedRelayClient` (protocol client), `HostedRelayTransport` (a `CloudSyncTransport`), `HostedRelayIdentity` (`relay_auth`). The user-facing name stays "Relay" (Settings, guide); the internal prefix only avoids the clash.
- `TransportKind` = `.cloudKit | .hostedRelay` is the hub's current transport (relay spec §3).

## 3. Layers today and the seam

```
phone UI / hub services ─▶ RelayFeed · ActionOutbox · SlicePublisher · RelayProcessor · MobileLinkCenter
                           SecureTransport (seal/open, wire names, rollback guard)
                           ── CloudSyncTransport ── (the seam)
                           CloudKitTransport (CKSyncEngine)  |  InMemoryCloudTransport (tests)
```

`SecureTransport` already depends only on `CloudSyncTransport`. The leaks are above it (recon on #1237):

| Leak | Where | Neutral replacement |
|---|---|---|
| `CloudRecord.creatorUserRecordName`, author check `LinkedDevice.accepts(creator:)` with `CKCurrentUserDefaultName` | Kit seam, `HubSyncState+Linking`, `RelayProcessor`, `MobileLinkCenter` | `CloudRecord.origin: RecordOrigin { author: String?, serverAt: Date? }`; the check moves behind `TransportAuthorPolicy.accepts(origin:device:)`. CloudKit's policy is today's code bit for bit; the hosted relay's is "the server ACL already proved it" (mailbox = device). |
| `CloudRecord.serverModifiedAt` (hygiene ages) | `RelayProcessor` hygiene, `UnopenableRecord` | `origin.serverAt` — same meaning, the relay stamps it. |
| `CloudDatabaseScope` (`private` / `shared(ownerName:)`) | phone `HubBoot`, `HubSession`, `HubRegistry` persistence, `LinkStore`, `LinkingViewModel` | `HubRoute` enum: `.cloudKit(CloudDatabaseScope)` and `.hostedRelay(macDeviceID:)`. Persisted columns keep their raw values; a new nullable `route_kind` column decides. |
| `ShareService` (zone loop, CKShare URLs, public link) | Desktop `MobileLinkCenter`, `ShareService` | `PhoneAccessService`: `ensureInvitation() -> LinkInvitation`, `participants()`, `remove(where:)`, `reconcile(keep:)`; `CloudKitShareService` keeps today's body. |
| `LinkContainer` (accept shares) | phone onboarding | `LinkAccess`: `identity()`, `join(invitation:hubID:)`, `leave(hubID:)`. |
| `AskAlertSubscription` (`import CloudKit` inside the Kit), `PushScope`, `AlertSubscriptionRegistrar`, NSE fetch, `TrayAppDelegate` silent push | Kit Secure, phone, NSE, Desktop | `PushWake` protocol: `subscribe(hub)`, `alertSource(for notification) -> AlertSource` where `AlertSource` is `.fetchRecord(id)` (CloudKit) or `.inline(envelope)` (relay). The CloudKit implementation moves into `CloudKitTransport/`. |
| `transport is/as? CloudKitTransport` casts (`start/stop/sendNow/fetchDepth`) | phone `HubSession` (7 places) | `LiveTransport` capability protocol. |
| Direct `CloudKitTransport(...)` construction, `entitlementPresent()` | `MobileHubService`, `HubBoot`, `AppRoot`, `MobileSettingsViewModel`, `BatteryDiagnostics` | `HubTransportFactory` / phone `TransportFactory` keyed by `HubRoute`. |
| `LinkPayload` v3 CKShare URLs, `owner_user` | Kit Link | v4 adds `transport` and `relay_mac_device_id`; share URLs become optional (§8). |

The seam gains surface only through **optional** protocols, the way `CompactingTransport`/`SweepingTransport` did, so `CloudSyncTransport` keeps its three requirements and the six phone test fakes keep compiling:

- `ConditionalTransport`: `save(_ items: [ConditionalSave]) -> [SaveOutcome]` and `delete(_ items: [ConditionalDelete]) -> [DeleteOutcome]` with `expect: .none | .absent | .seq(UInt64)`, outcomes `.saved(recordSeq)`, `.conflict(current: CloudRecord)`, `.refused(TransportRefusal)`. `CloudRecord` gains `recordSeq: UInt64?`. On CloudKit, `.absent` maps to a create-only save and `.seq` to the stored change tag (`TransportStore` keeps the tag per record); a `serverRecordChanged` becomes `.conflict` instead of today's "my payload wins" retry — **only** for records written through this protocol (the mailbox lane, §5). Slices keep today's path. This is a behaviour change on CloudKit (listed in Decisions): today a phone re-save and a hub echo racing on one action record end with whichever wrote last; with it, the loser sees the winner's record and resolves it by sim rule 3, so an echo is never overwritten by a stale action copy.
- `MailboxAddressing`: `changes(inMailboxOf device:)` / `save(…, mailbox:)` so the hub reads one mailbox per phone on the relay. On CloudKit the mailbox is a filter of the shared `RelayZone` by sender, as today.
- `PagedChanges`: `changes` may return `more`; callers loop. `CloudKitTransport` never returns `more`.

## 4. Identity on the relay

- Every device (phone and Mac) creates an Ed25519 `relay_auth` key in the Keychain on first use of the hosted relay — not at install. Accessibility `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (the Kit's `afterFirstUnlock` class, never synced, never in backups): a silent push on a locked phone must be able to log in and pull `changes`, and session tokens live in memory only, so `whenUnlocked` would make background sync fail until the owner unlocks. The NSE does not need it (ask alerts arrive inline, §10). `relay_device_id` = lower-case unpadded base32 of SHA-256 of the public key (as `relay/client/client.go`).
- Login: challenge–response, signing `nonce ‖ relay_device_id ‖ server_origin` (exact bytes from `client.go`; pinned by a Kit test vector produced by the Go client). Session tokens live in memory only.
- The Mac stores its `relay_device_id` in `hub_meta`; the phone stores `hub_id → mac relay_device_id` in its hub registry row. A Mac reinstall yields a new `relay_device_id`: the phone treats the hub as a new one (sim "Watchtower hub_id vs. the relay's ids").
- The server origin is a build setting (`WATCHTOWER_RELAY_ORIGIN`, default the production origin; Debug builds may point to a local stand, §11).

## 5. Actions: one order, one outbox, both transports

Today's action path does not meet sim rules 1–7a (recon on #1236): the envelope `seq` is shared by every sealed record and has holes; there is no unsent queue; the hub has no per-phone order; echoes are never deleted by the phone; there are no control records. The transport switch cannot be correct without these, and a switch involves both transports, so **the rules below apply on CloudKit too**. For a free user the visible change is order. The "undelivered" list (rule 6 below, sim rule 16 / R32) is part of the relay contract and is kept; in practice it shows up after a lapsed subscription or a Mac reinstall, and almost never on CloudKit alone.

1. **Action counter.** Each phone keeps, per hub, a persisted gapless `action_seq` (u64, starts at 1, never reset while the link lives; R29: it continues across epochs). It is drawn only when an action is committed to the outbox. It travels **inside the sealed payload** (`ActionRequestPayload.action_seq`), not in the envelope header, whose `seq` stays the rollback-guard counter it is today.
2. **Record name.** `a-<action_seq>` under `K_meta` (`wireName(zone: .relay, kind: "a", id: "<device_id>-<action_seq>")`). Deterministic, so a resend overwrites the same record and the hub can tell repeats. On CloudKit the device id in the HMAC input keeps phones apart in the shared zone.
3. **Outbox.** `pending_actions` becomes the outbox: the sealed bytes, `action_seq`, epoch, state `queued | sent | echoed(final) | undelivered`. A flush writes queued actions in order with `expect: .absent`, stops at the first failure (unreachable, rate limit, quota, `ENTITLEMENT_INACTIVE`) and resumes on the next pass (sim rule 1). Conflicts resolve per sim rule 3.
4. **Hub order.** The hub keeps `last_applied_action_seq` per phone (sidecar `devices`). It applies `last + 1` only; a lower or equal seq is a repeat (dropped, echoed); a higher one is held and the hub writes `resend_from(last + 1)` once per gap (sim rules 4–5). `relay_processed` stays as the exactly-once ledger for crash safety. Accepted cost (ask #796): on CloudKit a held gap delays every later action of that phone, Interrupt and permission answers included, until the missing action is resent. On the hosted relay a gap closes within one round trip.
5. **Echo.** The hub echoes every action record it reads — applied or repeat — by overwriting it with `expect: .seq` (sim rule 2). Final statuses: `applied`, `failed`, `expired`, `cancelled`. Non-final: `received`, `held`. On a final echo the phone settles the outbox row and deletes the echo (`expect: .seq`).
6. **Skip.** A phone asked to resend from a seq it no longer has writes `skip_to(m)` and lists each missing action as **not delivered** with **Retry** (a new action at the end of the queue) (sim rule 6). The list (Now → Not delivered) also takes the actions of sim rule 16 / R32. **Dismiss All** clears it: the owner's explicit choice, never automatic, so nothing is dropped silently; a dismissed entry is never resent. Settings → Diagnostics shows the outbox's queued count as **Waiting to send**.
7. **Control records** (`resend_from`, `skip_to`, `epoch_ack`, `transport_switch`, `transport_switched`, `transport_switch_rejected`, `hub_on_relay`, owed echoes) are new `RelayRecordKind`s with a durable per-mailbox queue on both sides, retried every pass (sim rule 7a). Names `c-<uuid>` under `K_meta`.
8. **Hygiene.** On CloudKit, today's 7-day hub hygiene stays as the fallback. On the relay the recipient deletes and the server TTL (14 days) is the fallback (sim rule 15).
9. **Migration.** At upgrade, actions already pending keep today's UUID names and are settled by today's code; new actions use the new path.
10. **Mixed versions — negotiated, never assumed.**
    - *Old phone, new hub:* the hub treats a payload without `action_seq` as today (unordered, by UUID, today's echo). Its ordered mode starts for a phone at that phone's first action carrying `action_seq`.
    - *New phone, old hub* (Desktop not updated yet): the hub announces `ordered_actions: 1` in its `device_grant` (the phone already reads it on every sync). Without that flag the phone uses today's path — UUID record names, today's echo statuses, no control records, no echo deletes — so it never waits for an echo or a control record an old hub cannot send. It switches to the ordered path at the first `device_grant` carrying the flag; actions already sent the old way settle the old way. Unknown record kinds are already dropped by the old hub's `RelayRecordKind` decoding, which a test pins.
    - The hosted relay requires both sides on the new path: a phone can only switch a Mac whose `device_grant` carries the flag (and a `relay_mac_device_id`, §8); otherwise the transport row says "Update Watchtower on this Mac".
11. **Alternative to (1) in §1, rejected by the owner (conversation on ask #795):** keep today's path for free phones and start the ordered path per phone only once it subscribes. Free users see no change at all, but both paths stay forever (every action handler, echo and hygiene rule twice), and a phone that stops paying keeps the ordered path on CloudKit anyway — so the "free" path would cover only phones that never paid.
12. **Inventory.** The action handlers fall under `docs/inventory/workbench.md` PROJ-16 (a phone line reaches the running agent) and PROJ-21 (permission answers and Interrupt from the phone). Ordering changes when an action is applied, never what it does; their guard tests must pass unchanged.

## 6. Publishing on change

Recon on #1238: the ~14 s median comes mostly from actions whose effect is never nudged (session start/stop/input, chat, report requests wait for the 30 s full tick) and from the 3 s / 30 s mailbox pass. The design:

1. **Nudge after apply.** `MobileHubCommandDispatcher` calls `publishSoon(kinds)` from one table `ActionKind → [SliceKind]` after every applied action (generalises `BoardHandlers`).
2. **In-process observation.** One `DatabaseRegionObservation` over every table a slice reads, mapped table → kinds (extends `FastLane.observedTables` from three tables to all).
3. **Writes by Go processes.** Desktop cannot observe another process's commits; today's pattern is per-view-model polling (`SessionAgentStateCenter` polls once a second). Proposal: one `PRAGMA data_version` poll on a dedicated read connection, every 250 ms **while a phone is linked, the hub runs and the phone was in touch in the last 10 minutes**, otherwise every 1 s — never slower than today's `SessionAgentStateCenter` poll, so Desktop's agent states update at least as fast as now for a user without a phone. On change, nudge the DB-backed kinds and `SessionAgentStateCenter`. Cost: a few microseconds of SQLite per poll and 4 timer wake-ups a second while active — the same order as the existing 1 s poll, which this one replaces as a shared change source (the existing poll's own triggers, a live agent session, keep the 1 s floor). The interval is a constant in `HubChangeWatch`, measured before Phase 0b ends (Energy Impact in Activity Monitor, idle hub with a linked phone) and listed in Decisions. Rejected: a file watch on `-wal` (coalesces poorly, misses checkpoints) and a stamp file touched by every Go writer (touches all of `internal/db`).
4. **Debounce** 150 ms trailing on the dirty-kind set; only dirty kinds are diffed. The full diff stays every 60 s as a backstop for clock-driven values (liveness ages, calendar horizon, permission expiry) and runner-fed kinds.
5. **Per transport** (ask #735): steps 1–3 on both transports; the minimum spacing between sends stays ~2 s on CloudKit (each DataZone save is a silent push to the phone, the battery rule of #724) and drops to 150 ms on the hosted relay, where a foreground phone gets events over its WebSocket without pushes.
6. **Mailbox pass.** On the hosted relay the hub reads mailboxes on the WebSocket event, not on a 3 s timer.
7. **The battery test.** `SlicePublisherTests.testANormalKindIsSavedAtMostOncePerThirtySeconds` pins the owner's battery rule (#724). It is rewritten, not deleted: it becomes "a kind is saved at most once per the transport's minimum spacing", with the CloudKit spacing ~2 s (ask #735), so the battery rule stays pinned by a test. The cadence lines of `docs/features/mobile-companion.md` change in the same PR.

## 7. Hosted relay transport

`HostedRelayClient` (Kit, no UI, no GRDB) mirrors the Go client's behaviour (sim "The Go client"): register/login, HTTPS `POST /v1/op` and WebSocket `GET /v1/ws` with `Authorization: Bearer <session token>` on the upgrade (HTTP 401 before the upgrade = log in again; a `Hello` token that differs from the upgrade token closes with 4001), `Relay-Protocol-Version: 1`, a client WebSocket ping every 30 s while the socket is open with a missing pong within 10 s = dead connection, close and reconnect (the server does not ping; a backgrounded iOS app has no socket and is woken by push), relogin once on `UNAUTHENTICATED`/close 4001, reconnect with exponential backoff ≤ 60 s with jitter, reconnect after a random 1–3 s on close 1001, with or without a preceding `GoingAway` frame (the server sends the frame on a deliberate close — displacement by a newer socket of the same device, drain; a platform rollout closes with a bare 1001), one `onGoingAway` per such close; abnormal closes (1006, 1011, …) keep the exponential backoff; one process per device identity, so the Mac never opens two, `UNAVAILABLE` (19) → retry the same idempotent op after 0.5 s doubling up to 8 s, at most 30 s in total, then show the error (v1: `remove_slot`, `submit_transaction` with a transfer; a repeated `remove_slot` within 24 h answers it while the revocation is delivered), `TOKEN_EXPIRED` on `changes` (a `since_seq` older than the server keeps, or one this zone never issued, e.g. above its last seq after a rebuild) → not a session error: reset that zone's `since_seq` to 0 and pull again (full resync of the zone, handled by the caller of `changes`), one-by-one resubscribe (a refused zone is dropped and reported), a record-less `ZoneChanged` means "pull", a full event buffer never blocks the reader, `UNSUPPORTED_VERSION`/close 4000 → "update the app". After every reconnect: resubscribe, pull every zone from its last seq, `get_account_state`.

`HostedRelayTransport` implements `CloudSyncTransport`, `ConditionalTransport`, `MailboxAddressing`, `PagedChanges`, `LiveTransport`:

- Zones: `.data` → `data/<mac>`, `.relay` → `relay/<mac>/<phone>` (the hub enumerates its phones; the phone has one mailbox per hub), pairing → `pair/<slot>`. One persisted change token per zone; `TOKEN_EXPIRED` → full resync of that zone.
- Attachments: `create_upload` → PUT of the already-sealed file (`ChunkedAssetCipher` unchanged) → `save` with `attachment_id`; download via `get_download`. A re-save of a recording uploads again (an overwrite deletes the old object). Pair zones carry none.
- Save is not atomic: after an error response the transport re-reads the affected zone before retrying. `SaveResult` carries metadata only; the transport keeps its bytes and the returned `record_seq`.
- Errors map to today's events: quota codes → `TransportEvent.quotaExceeded` (new cases `hubQuota`, `mailboxQuota`); `ENTITLEMENT_INACTIVE` and `Control{ENTITLEMENT_EXPIRED}` → §9; `FORBIDDEN` on a hub zone → the hub is no longer in any paying slot.
- Generated code: `relay.proto` and the `protoc-gen-swift` output are copied into `WatchtowerKit/Sources/WatchtowerRelayProto/` with a `VERSION` file naming the relay commit (ask #734). New dependency `apple/swift-protobuf`, pinned exactly, in the Kit (Desktop and phone get it through the Kit). `make relay-proto RELAY=../relay` regenerates and refuses a dirty or unpinned source.

## 8. Linking over the relay

- **Upgrading an existing link** (relay spec §3.2 p. 2): when a phone subscribes, the hub publishes its `relay_mac_device_id` in the phone's `device_grant` over CloudKit; the phone calls `add_slot`; the hub calls `set_hub_readers`. No new QR.
- **New link while the phone is on the relay** (§3.2 p. 3): `LinkPayload` v4 adds `transport` and `relay_mac_device_id`; the phone opens a pairing slot, writes today's sealed `DeviceHello` into `pair/<slot>`, the Mac (told by `Control{PAIRING_OPENED}`) answers with today's keybox flow there; after the owner's SAS confirmation the phone calls `promote_pairing`, the hub `set_hub_readers`. Today's attempt caps, refusals and code checks in `MobileLinkCenter` stay as they are — only the record route changes.
- A Mac on the hosted relay still shows the CloudKit QR fields for a free phone; that phone links and then sees `hub_on_relay` ("this Mac runs over Relay").
- Failures as relay spec §3.2 p. 3: slot expired or code refused → `close_pairing`, a new QR; three Macs in slots → the phone asks to remove one first, with the relay's limit as the footnote: at most 5 slot replacements per 30 days (relay spec §8 limits); past it the server's error is shown as is, and adding the Mac over iCloud stays possible.

## 9. Transport switch and subscription

Implemented exactly as sim rules 8–16 (they change only together, relay spec §9 p. 2):

- The switch lives on the phone (Settings → Macs → transport per Mac, paying phones only) and is accepted by the hub with the 5-minute anti-flap rule toward the relay. The hub writes the transport marker record (R30) in its data zone.
- Every switch starts a new epoch (`HubKeyring.rotate(reason: .transportSwitch)`) after the old transport's mailboxes are drained if reachable; the new keybox travels inside `transport_switched` in each phone's mailbox, not in the data zone. Old-epoch receiving keys are kept per sim rule 14 (≤ 14 days), which needs `HubKeyring.latestEpochs` and the phone's `HubLinkKeys.maxEpochs` to hold more than two epochs, and an `epoch_ack` per phone.
- While on the hosted relay the hub keeps CloudKit zones and shares in place and polls its phones' CloudKit mailboxes every 30 s for control records (relay spec §4.1); a phone whose relay is unreachable > 60 s polls its CloudKit mailbox too. "Relay unavailable" shows after 60 s; after 10 min the phone offers **Switch to iCloud**.
- **Subscription** (phone): StoreKit 2, auto-renewable, `appAccountToken = account_id`, Family Sharing off; the signed transaction goes to `submit_transaction`; restore = move (relay spec §3.2 p. 4); `SUBSCRIPTION_MOVED` → the old phone says so and returns to CloudKit. `ENTITLEMENT_EXPIRED` / `ENTITLEMENT_INACTIVE` → sim rule 16, including the lapsed phone's undelivered list (R32) and the Mac acting on the control's `detail` (R31).

## 10. Pushes, Desktop, measurements

- **Pushes (phone).** Forward the APNs token and environment with `register_push` at every launch. Silent push → background `changes` over HTTPS. Ask alerts: the hub calls `send_alert` per paying phone with the sealed `ask_alert`; the NSE takes `AlertSource.inline(envelope)` and opens it with today's `AlertOpener` under a fixed wire name `alert-push` (AAD), no network. CloudKit's `sig-` records and query subscription stay for CloudKit phones only.
- **Desktop.** Settings → Mobile, per linked phone: its transport (iCloud / Relay), "does not receive updates: this Mac runs over Relay" for a free phone, who switched and when, "Relay unavailable", quota errors, and the undelivered-actions count the hub knows of. Built from the design kit.
- **Mockups** for every new screen: [`docs/design/mockups/relay-client/index.html`](../../design/mockups/relay-client/index.html) — Desktop Settings → Mobile (transport per phone, hub states), Desktop Diagnostics, iPhone Settings → Macs and the per-Mac transport choice (incl. the 5-minute refusal), the subscription screen, the "no updates from this Mac" banner for a free phone, "Relay unavailable" with the switch offer, the Not delivered list, iPhone Diagnostics, and the edge states (Mac needs an update, subscription moved, app needs an update, three Macs in slots). Desktop screens are built with `SettingsSection` and `.kitRow` (no row separators, row actions on hover) per `docs/design/desktop-style-guide.md`; the mockups show copy and layout, the kit decides the look.
- **Measurements.** Content-free latency samples on both sides: the phone stamps action write → echo seen → slice with the effect seen; the hub stamps read → applied → slice saved. Stored locally (phone `replica_meta`-side table, hub sidecar) and shown on each side as p50/p90 per transport: on the Mac in Settings → Mobile → Diagnostics (the hub's steps), on the iPhone in Settings → Diagnostics next to the battery report (the phone's steps, including the end-to-end "action → result on screen" this goal is about); **nothing leaves the device**. Consequence: the p50 < 500 ms goal is checked on our own devices and on the relay's synthetic probe (relay spec §10), not on users' devices. An opt-in upload of aggregated timings to the relay can be added later without touching this storage; it is not in v1.

## 11. Testing

- **Kit, public CI:** a Swift port of the sim scenarios against `FakeHostedRelay` (in-memory server: zones, `record_seq`, conditional writes, mailbox ACL, controls, TTL with a fake clock) and against `InMemoryCloudTransport` extended with change tags — every sim test name gets a Swift twin with the same name (`TestGapTriggersResendFrom` → `testGapTriggersResendFrom`), so the two rule sets stay comparable. Login signing and `relay_device_id` pinned by vectors generated with the Go client.
- **Interop with the real relay server:** locally through `make relay-interop RELAY=../relay` (starts the relay's local stand under `wrangler dev`, as the relay's own `go test -tags interop` does; needs Node, §12), and in the relay repository's CI building the Kit's client (ask #734). Public Watchtower CI never needs the private repo.
- **Phone/Desktop:** existing suites keep passing on CloudKit; new wiring tests per phase; one manual device check per phase that touches the phone.

## 12. What we need from the relay repository (relay session)

1. `relay.proto` v1 frozen in the relay's `main` (`buf breaking` against main): the freeze PR `aiwatchtowers/relay#1` (branch `protocol/v1-freeze`, head `2643f78`) waits on the owner (relay ask #763); `feature/relay-v1` (Go) is not merged and relay ask #729 is withdrawn. Before Phase 2 ends. Until the merge, Phase 2 builds against the PR head (`2643f78`); the contract texts are its `proto/README.md` and `sim/README.md`, and the Kit's `VERSION` pins the merge commit once the relay session sends it.
2. ~~A local stand and a dev-only entitlement grant~~ — done on `feature/relay-cf` (`relay/worker/README.md` "Local stand"): the Worker under `wrangler dev` (Node, `npm ci`, a `RELAY_SESSION_SECRET` in `.dev.vars`; `http://127.0.0.1:8787`, `/v1/ws`, `/healthz`; state in `worker/.wrangler/state`). Dev endpoints: `POST /dev/entitlement` (`accountId`, `state`, `forMs`; 503 + `Retry-After` while a revocation is delivered), `/dev/account`, `/dev/pair`, `/dev/expire-mailboxes`, all keyed by `relay_device_id`. No pushes and no App Store locally. Local attachments go through the Worker's own `/v1/blob/...`, so the client treats upload/download URLs as opaque. On staging `/dev/*` needs the admin token; prod has none. From a physical iPhone: the Mac's LAN IP and an ATS exception in Debug.
3. ~~Relay spec §4 wording fixed per R29–R32~~ — done.
4. A CI job that builds the Watchtower Kit client and runs the interop scenarios — Phase 3.
5. Staging on Cloudflare (`relay-staging.<domain>`, the owner's domain); App Store Connect product, Paid Apps Agreement, APNs and App Store Server API keys — before the launch, not before development.

## 13. Phases

| Phase | Content | Depends on | Board |
|---|---|---|---|
| 0a | Seam neutral (§3): `RecordOrigin`, `TransportAuthorPolicy`, `HubRoute`, `PhoneAccessService`/`LinkAccess`, `PushWake`, `LiveTransport`, factories. No behaviour change on CloudKit. | — | #1237 |
| 0b | Publishing on change (§6) | ask #735 | #1238 |
| 1 | Ordered actions and outbox on both transports (§5), `ConditionalTransport` on CloudKit, control-record queue, "not delivered" on the phone | 0a | new under #1240 |
| 2 | Proto in the Kit, `HostedRelayClient`, `HostedRelayTransport`, `FakeHostedRelay`, sim twins | 0a, relay §12 p. 1 | #1239, #1240 |
| 3 | Identity, linking over the relay, transport switch + epochs (§8–9), interop | 1, 2, relay §12 p. 2 | #1241, #1242, #1247 |
| 4 | Subscription, pushes, Desktop indicators, measurements (§9–10), guide pages | 3 | #1243–#1246 |
| 5 | 7-day rotation with ephemeral X25519 (relay spec §7.4) — after launch | 3 | #1248 |

Launch for users waits for Phases 0–4 and §12 p. 5. Each phase gets its own plan; phases 0a and 0b may run in parallel lanes.

## 14. Contracts and docs this touches

- `docs/features/mobile-companion.md` — the feature note of the phone ↔ hub link. Updated in the PR of each phase that changes a rule it states: Phase 0b (cadence lines), Phase 1 (action path, echoes, hygiene, "D4: no ordering gate"), Phase 3 (linking, epochs, transport). A new note `docs/features/relay-client.md` holds the hosted-relay parts (identity, transport, switch, subscription) from Phase 2 on, linked from CLAUDE.md's feature list.
- `docs/inventory/workbench.md` PROJ-16 and PROJ-21 — kept as they are (§5.12).
- The E2E format (`docs/superpowers/specs/2026-10-12-mobile-e2e-encryption-research.md`): unchanged except new record kinds inside sealed payloads; the AAD zone bytes never change.
- User guide: `docs/guide/features/iphone.md` (Macs, transport, subscription, Not delivered) and `docs/guide/features/iphone-alerts.md` (pushes over Relay), in the Phase 4 PR; a Learn card per `docs/guide/WRITING.md`.

## Decisions

- Spec first, start the CloudKit-leak cleanup and publishing on change now — ask #734
- Changes in the relay repository are done by the relay session — ask #734
- `relay.proto` and the generated Swift are copied into the Kit, pinned to a relay commit — ask #734
- Interop tests against the real relay server run locally and in the relay repository's CI; public Watchtower CI uses a fake server — ask #734
- On CloudKit a gap in a phone's actions may delay its later actions, Interrupt and permission answers included; accepted — ask #796
- Publishing on change: the nudge on both transports; minimum spacing ~2 s on CloudKit, 100–200 ms (150 ms) on the hosted relay only — ask #735
- The relay server moves to Cloudflare; protocol v1 and the client rules stay; the client sends the session token on the WebSocket upgrade, pings every 30 s, reconnects after 1–3 s on `GoingAway`, retries `UNAVAILABLE` and resyncs a zone on `TOKEN_EXPIRED` — relay freeze PR #1 (`2643f78`), relay ask #763
- Existing "Relay" names keep meaning the mailbox lane; the new server's types are `HostedRelay*`; the user-facing name stays "Relay" — author's decision, for approval
- One action path for both transports, free CloudKit users included: ordered actions, outbox and control records; the reasons that count are order and one path in the code; the §5.11 two-path alternative is rejected — conversation (ask #795)
- On CloudKit, mailbox-lane records written through `ConditionalTransport` turn `serverRecordChanged` into a conflict instead of "my payload wins"; slices keep today's path — part of the one action path (conversation, ask #795)
- New phone ↔ old hub negotiated by `ordered_actions` in `device_grant`; the hosted relay needs both sides on the new path — author's decision, for approval
- `relay_auth` accessibility `AfterFirstUnlockThisDeviceOnly` — author's decision, for approval
- Go-process writes seen through a `PRAGMA data_version` poll, 250 ms while a phone was in touch in the last 10 min, else 1 s (never slower than today's poll); measured before Phase 0b ends — author's decision, for approval
- The 30 s battery test is rewritten into a per-transport minimum-spacing test, not removed — author's decision, for approval
- `action_seq` is a separate gapless counter inside the sealed payload; the envelope `seq` stays the rollback-guard counter — author's decision, for approval
- Seam grows only through optional protocols (`ConditionalTransport`, `MailboxAddressing`, `PagedChanges`, `LiveTransport`) — author's decision, for approval
- Rotation keyboxes on the relay travel in the phone's mailbox inside `transport_switched` — author's decision, for approval
- `relay_auth` is created on first use of the hosted relay, not at install; never synced or backed up — author's decision, for approval
- Latency measurements stay on the device, shown in Diagnostics; p50 is checked on our devices and the relay probe, not on users' devices — author's decision, for approval
- 7-day rotation with ephemeral keys comes after launch (relay spec §9 allows it); at launch relay links keep 90-day static-key epochs plus a new epoch per switch — author's decision, for approval (security scope narrowed at launch)
- Mockups for every new screen in `docs/design/mockups/relay-client/` — conversation (spec review round 1)
