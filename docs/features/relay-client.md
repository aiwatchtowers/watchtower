# Relay client — the phone's hosted relay transport in the Kit (Phase 2, 2026-10-31, board #1239, #1240; Phase 3a, board #1241, #1242, #1247; Phase 3b, 2026-11-03)

Spec: `docs/superpowers/specs/2026-10-29-relay-client-design.md` (below: "the spec"). Plans: `docs/superpowers/plans/2026-10-31-relay-client-phase-2.md` (rulings R1–R20) and `…-phase-3.md` (its own R1–R21; "Phase 3 R4" below means the latter). Where the two collide, the section says which. Server contract: the relay repository's `proto/README.md` and `relay.proto` at the pinned commit; client rules: its `sim/README.md` ("sim rule N").

The phone side of the paid relay transport. The hub side is the Go hub (`internal/hub/transport/relay`, ask #802); the Swift hub and the Desktop never talk to the relay. Phase 0a (the transport seam) is in [mobile-companion.md](mobile-companion.md), "Transport seam".

## What Phase 2 ships, and what it does not

**Ships**, all in `WatchtowerKit/`:

- the vendored proto and its generated Swift (`WatchtowerRelayProto`);
- `HostedRelayClient` over HTTPS and `HostedRelayConnection` over a WebSocket, with the Go client's rules and numbers;
- App Attest for `register` and `login`: the `AppAttesting` seam, the `DeviceCheckAppAttest` adapter and the `RelayAttestor` state machine;
- `HostedRelayTransport`, a `LiveTransport` + `ConditionalTransport` + `CompactingTransport` for the phone's two relay zones;
- four relay tables in `TransportStore`;
- the test kit `FakeHostedRelay`, `FakeAppAttest`, `ManualRelayClock` and `RelayStandControl`;
- the Swift twins of the Go client's, the Go hub transport's and the relay sim's tests;
- local interop against the relay's stand (`make relay-interop-kit`).

**Does not ship.** Nothing is wired into the app: no phone code constructs the client or the transport (R19), and nothing reaches a screen, a setting or a notification, so no guide page changed. Phase 3a ("Phase 3a" below) brings:

- the relay identity (`relay_auth` keys and their storage);
- the App Attest key id's Keychain store and the `com.apple.developer.devicecheck.appattest-environment` entitlement (R2), in Debug only (`WatchtowerMobile-Release.entitlements` has no App Attest key): Phase 4 adds the key to Release, and enabling App Attest on the App ID is the owner's portal step at that point;
- linking over the relay (`pair/<slot>`, `LinkPayload` v4);
- hub vouching (`vouch_hub`);
- `TransportFactory` choosing the relay.

The transport switch and subscription screens are Phases 3–4. CloudKit behaviour is unchanged: `CloudSyncTransport` keeps its three requirements, and the new surface is optional protocols only.

## Kit targets — phone only (R3)

| Target | Kind | Holds |
|---|---|---|
| `WatchtowerRelayProto` | target (no product) | `relay.proto`, generated `relay.pb.swift`, `VERSION` |
| `WatchtowerHostedRelay` | product | client, connection, identity messages, App Attest, transport, zones, `HostedRelayEvent` |
| `WatchtowerHostedRelayTesting` | product | `FakeHostedRelay`, `FakeAppAttest`, `ManualRelayClock`, `RelayStandControl` |

`WatchtowerSync` depends on none of them and never imports `SwiftProtobuf`, `WatchtowerRelayProto` or `DeviceCheck`. `SeamBoundaryTests.testOnlyTheHostedRelayTargetsImportProtobuf` pins that boundary.

The Desktop links no protobuf. After ask #802 it runs no relay code, and protobuf in `WatchtowerSync` would grow every Desktop build. The relay targets are phone-only products, and in Phase 2 the phone app links none of them yet. The gate checks their iOS build with `xcodebuild -scheme WatchtowerHostedRelay -destination 'generic/platform=iOS Simulator' build` inside `WatchtowerKit`.

## Proto pin (R1, R14)

The Kit's pin is relay `main` at `bcca870` (relay PR #5, vouched hubs; it contains PR #3's `Changes.resync`, board #1430). The Go hub's copy moves on its own (board #1345; R14: the pins are not forced equal), so the two may differ; `make relay-proto` prints both.

`WatchtowerKit/Sources/WatchtowerRelayProto/VERSION` has two lines:

- line 1: `<commit> <commit date>`, the Go copy's format;
- line 2: `protoc-gen-swift <tag>`. `RelayProtoPinTests` checks that it equals the `exact:` swift-protobuf pin in `Package.swift`, because generated code checks the runtime's version at compile time.

To regenerate, run `make relay-proto RELAY=../relay [REF=<commit>]` (`scripts/relay-proto.sh`). It uses `buf` and a `protoc-gen-swift` built from the Kit's pinned swift-protobuf checkout, and refuses a dirty or unpinned relay checkout.

`make relay-go` moves the Go copy (`internal/hub/transport/relay`) to the same commit. The two pins are not forced equal, because their release trains differ, and the script prints both. Public CI never regenerates.

## `HostedRelayClient` and `HostedRelayConnection`

These are the Go client's rules with the Go client's numbers. Twins of Go tests keep the Go name with a lower-case `test` prefix: `TestRetryOnUnavailable` → `testRetryOnUnavailable`.

- **HTTPS ops.** `register` and `login` carry an attestation. Concurrent callers share one login in flight. An `UNAVAILABLE` answer is retried from 0.5 s, doubling to 8 s, within 30 s in total, and then fails. `UNAUTHENTICATED` triggers one relogin.
- **Session token.** The token lives only in the actor's memory. Tokens, keys, envelopes and attestation bytes are never logged, never written to disk, and never put in an error. Logs (`os.Logger`, category `HostedRelay`) carry op names, codes, zone kinds and counts only.
- **Reconnect backoff.** `defaultBackoff` starts at 500 ms and doubles to 60 s, with jitter in the upper half of the window. A connection that reaches `HelloOk` resets it.
- **Opening a socket.** The client dials `GET /v1/ws` with the bearer token, then sends `Hello{1, token}` and waits for `HelloOk`. It then subscribes each zone one by one: a refused zone is dropped and reported. A subscribe with no answer within 10 s, or answered "try again later" (`UNAVAILABLE`, `RATE_LIMITED`, `TRAFFIC_LIMIT_EXCEEDED`), cuts the connection and keeps the zone; such cuts in a row redial on a growing `defaultBackoff`, so no zone goes quiet for good. After every connect the client emits a record-less `zoneChanged` for each subscribed zone.
- **Keepalive.** The client pings every 30 s. With no pong within 10 s it closes the socket and reconnects.

How the connection reacts to each upgrade answer and close code:

| Event | Reaction |
|---|---|
| HTTP 401 at the upgrade, or close 4001 after `Hello` | One login, one redial at once |
| Close 4001 mid-connection | The token is replaced by a login, then reconnect |
| Close 1001 | `onGoingAway` once, reconnect after a uniform 1–3 s |
| Close 4000 | `.stopped(.unsupportedVersion)`, no more dials |
| 4008, 1006, 1011, a failed dial, a dead socket | `defaultBackoff` |

The event buffer holds 256 events.

## App Attest (R2, R16, R18)

Every relay `register` and `login` carries App Attest (relay `proto/README.md`, "Attestation (App Attest)").

**Pieces:**

- `AppAttesting` is the seam: `DCAppAttestService` in production (`DeviceCheckAppAttest`), `FakeAppAttest` in tests.
- `AppAttestFailure.classify` maps DeviceCheck errors:
  - `invalidKey` → `.invalidKey`;
  - `serverUnavailable` or any `URLError` → `.serverUnavailable`;
  - any other code → `.other("dc_<code>")`.
- `AppAttestKeyStore` holds the key id, in memory only in Phase 2.
- `RelayAttestor` follows the README's client failure-path table:
  - a register attests afresh;
  - a login asserts with the stored key, or attests afresh when no key is stored (lost-key path);
  - a transient failure backs off from 1 s, doubling to 5 min;
  - a refused assertion allows one fresh attestation since the last successful login.

**Outcomes** (`HostedRelayAttestError`):

- `.notSupported` (`isSupported == false`): the client refuses before any request;
- `.retryLater(after:)`;
- `.updateRequired`, on `ATTESTATION_REQUIRED` or on `ATTESTATION_FAILED` after the one fresh attestation.

**Failure-path tests** (`RelayAttestorTests`, `HostedRelayAttestationTests`):

- `testAttestUnsupportedRefusesBeforeAnyRequest` / `…BeforeAnyCall`;
- `testGenerateKeyFailsBacksOff`;
- `testAttestKeyServerUnavailableRetriesSameKey`;
- `testInvalidKeyRegeneratesAndAttests`;
- `testAssertionFailsRetriesLogin` and `testAssertionServerUnavailableKeepsKeyAndBacksOff`;
- `testAttestationFailedOnLoginReattestsOnce` and `testServerRefusedAssertionAllowsOneFreshAttestation`;
- `testAttestationRequiredShowsUpdate` and `testAttestationFailedOnRegisterShowsUpdate`;
- `testLoginWithoutAStoredKeyAttestsAfresh`;
- `testDeviceCheckErrorsAreClassified`.

R17's auth vectors (`RelayAuthVectorTests`) come from a Go test over the Go client copy, with fixed Ed25519 seeds.

**How the transport reacts:**

- `.notSupported` or `.updateRequired` sets `stoppedBy`. The transport is then stopped until `start()`: no login, no register, no request, and queued writes stay queued.
- `.retryLater` sets `loginNotBefore`. Until that deadline every call answers without the attestor or the network. `start()` clears the hold, and so does any op that reaches the relay.
- Both outcomes go out on `relayEvents` as `.attestation(…)`.

**Where attestation is checked.** The local stand runs with attestation off, and the Swift client sends `FakeAppAttest` bytes there through the same register and login code. `FakeHostedRelay` in `enforce` mode applies the README's table to phones. It lets test-only MAC devices in through an exempt list, the way the relay exempts its probe devices.

**Macs do not attest.** MAC-kind devices appear only in tests, on the stand or the fake.

## `HostedRelayTransport` (R4–R11)

**Zones (R4).** The transport serves the phone role only, for one Mac:

- `.data` → `data/<mac>`, read only: a write throws `.server(code: .forbidden)` and nothing is queued;
- `.relay` → `relay/<mac>/<phone>`, the phone's mailbox.

There is no `MailboxAddressing`, because the phone has exactly one mailbox per hub. Pairing zones (`pair/<slot>`) come with Phase 3. `HostedRelayZones` names the zones.

**Store binding.** `relay_binding` binds the `TransportStore` to one relay Mac (and its hub id once known) before any request. A store bound to a CloudKit scope or to another Mac throws `TransportStoreError.boundToAnotherRoute`.

**Buffer (R5).** There is no `PagedChanges`. A pull pages each zone from its stored server cursor (`relay_cursors`, 500 records a page, looping on `more`) into `TransportStore`'s change buffer. `changes(in:since:)` serves that buffer. The consumers (`ReplicaHydrator`, `RelayFeed`) keep their local tokens, compaction and the asset stash, as on CloudKit. A cursor moves only with the page it covers. One pull runs at a time, and later callers join it.

**Records.** `relay_records` keeps `(zone, name, record_seq)` for every record the server returned. Each buffered event carries `record_seq` for later conditional writes. On the relay, `origin.serverAt` is the writer's `client_modified_at_ms` and `author` is nil (R7).

**Writes (R8):**

- Plain `save` and `delete` queue durably in `pending` and flush in enqueue order, unconditionally, on `sendNow()`, on connect and before each pull. The flush is single-flight. A `.permanent` refusal drops that row and goes on, as `CloudKitTransport` does; any other refusal stops the flush and leaves the rest queued.
- `ConditionalTransport` calls go straight to the relay after flushing the plain queue, and send nothing if that flush stopped. They return one outcome per item, matched by index.
- After any refusal other than a per-item conflict, the transport re-reads the zone before it returns. A failed re-read is only logged.

**`TOKEN_EXPIRED` (R10).** The zone resyncs from 0. The resync's progress — its cursor and the names seen so far — is kept page by page in `relay_resync_seen`, so after a restart an interrupted resync resumes where it stopped. Only after the last page does the transport buffer a deletion for each name in `relay_records` that the resync did not return. A record this device never saw from the server is never deleted by the diff. Every page of a pull that started at 0 — the resync, and a zone's first pull — sets `Changes.resync = true`, so the relay skips its tombstone floor on the middle pages; a pull from a stored cursor never sets it. If the relay still refuses a flagged middle page (its README keeps `TOKEN_EXPIRED` for a `since_seq` above the zone's seq, e.g. a zone rebuilt mid-resync), the resync is marked stalled and the zone is held for `resyncStallHold` (1 h). `start()` ends the hold at once.

**Socket events (R9).** A `zoneChanged`, with or without a record, means "pull this zone". After a connect, the transport reads `get_account_state` (an entitlement that does not pay is reported) and flushes the plain queue, so a row saved while the socket could not be dialed goes out then. A push wake (`fetchForPush`) runs its own pull of both zones: it joins a pull in flight, a socket's one-zone pull included, with both zones owed.

**Attachments.** A save uploads its asset first: `create_upload`, then a PUT of the file; the save names the `attachment_id`. A pulled record's attachment is fetched with `get_download` and a GET, capped at `maxAttachmentBytes`, into the stash before its page is buffered. What is enforced on blob URLs:

- the URL the relay hands out must be HTTPS; plain HTTP is allowed only to loopback, or to the origin's own host when the origin is plain HTTP itself (a stand), and is checked before any request;
- `URLSessionRelayHTTP` gives every request a task delegate. `POST /v1/op` follows no redirect. A blob GET or PUT follows one only under the Go `checkRedirect` rule: at most three requests in all (two redirects), each hop HTTPS or plain HTTP to loopback;
- a redirect that is not followed comes back as its 3xx, and any non-2xx answer fails.

Signed URLs are never logged.

**Error mapping (R6 as amended).** `HostedRelayTransport+Errors.swift` holds the whole table, pinned by `testErrorMapping`:

| Relay answer | Outcome |
|---|---|
| `SaveConflict` with `current` | `.conflict(current:)` |
| `SaveConflict` without `current` | `.refused(.permanent("gone"))` |
| `DeleteConflict` without `current` | `.deleted` |
| A delete with `.absent` | `.refused(.permanent("unsupported_precondition"))`, before any request |
| `MAILBOX_QUOTA_EXCEEDED` | `.quotaExceeded` |
| `RATE_LIMITED`, `TRAFFIC_LIMIT_EXCEEDED` | `.rateLimited(retryAfter:)` |
| `ENTITLEMENT_INACTIVE` | `.entitlementInactive` |
| No network, a dial failure, `UNAVAILABLE` past 30 s, HTTP 5xx | `.unreachable` |
| App Attest `.notSupported`/`.updateRequired`, `UNSUPPORTED_VERSION` | `.unreachable` |
| **A response lost after the request was sent** | **`.unreachable`** (amended in Task 8: the client cannot tell a lost answer from no network; both stop a flush, neither marks an action Not delivered) |
| A cancelled request | `.transient("cancelled")` |
| A malformed answer | `.transient("malformed_answer")` |
| App Attest `.retryLater` | `.transient("attestation_backoff")` |
| `UNAUTHENTICATED` after the one relogin | `.transient("unauthenticated")` |
| An unnamed or future code | `.transient("relay_<n>")` |
| `RECORD_TOO_LARGE`, `ATTACHMENT_TOO_LARGE` | `.permanent("record_too_large")` |
| `FORBIDDEN` | `.permanent("forbidden")` |
| `NOT_FOUND` | `.permanent("not_found")` |
| `HUB_NOT_VOUCHED` (never sent to a phone on a mailbox or data op; a phone's `add_slot` / `promote_pairing` answer is handled by the pairing flow, not by this table; named so it is not read as the transient `relay_22`) | `.permanent("hub_not_vouched")` |
| `ERROR_CODE_UNSPECIFIED` | `.permanent("unspecified")` |

**`relayEvents` (R11).** `TransportEvent` gets no new cases, and `MAILBOX_QUOTA_EXCEEDED` is today's `.quotaExceeded`. Relay-only signals go on `HostedRelayTransport.relayEvents` (`HostedRelayEvent`, newest 256 kept):

- `.control(kind:detail:)` (every control as it comes; nothing on the phone acts on the hub-only `SLOT_ADDED`);
- `.entitlementInactive`;
- `.forbidden(zone:)`;
- `.unsupportedVersion`;
- `.attestation(…)`;
- `.reachable(Bool)`.

Phases 3–4 wire them to screens. No case carries a token, a key or an envelope.

## Test kit: `FakeHostedRelay` and `RelayStandControl`

**`FakeHostedRelay`** is an in-memory relay that follows `proto/README.md` at the pin, and the Worker's code where the README is silent (R20). It is thread-safe and runs on `ManualRelayClock` time, so TTLs run when a test advances the clock. It provides:

- HTTP, socket and blob seams;
- faults (`FakeHostedRelay+Faults.swift`): failed ops, refused dials, deploy, displace, crash (also after a given op), restart, no pongs, a silent subscribe, expired sessions;
- accounts, entitlements and pairing;
- App Attest in `enforce` mode.

It does not model:

- rate limits;
- phone traffic;
- App Store transactions;
- APNs (`send_alert` answers `Ok` after its rule checks);
- the Hello and session-expiry timers;
- the attachment settle and orphan timers;
- the 1009 frame close;
- signed blob URLs.

**`RelayStandControl`** is what a test may do besides the protocol: entitlement, account, pair and expire-mailboxes. These are the stand's `/dev/*` endpoints. The fake implements them in memory, and the interop tests' `HTTPRelayStandControl` calls them on the stand.

## Twins and interop (R12, R15)

There are three families of twins:

- **Client.** `HostedRelayClientScenarios`, `HostedRelayConnectionTests` and `HostedRelayClientTests` twin the Go client's tests, for example `testRetryOnUnavailable`, `testHelloMismatchRelogsIn`, `testReconnectAfterGoingAway`, `testNoAckedWriteLostAcrossDeploy` and `…AcrossCrash`.
- **Transport.** `HostedRelayTransportTests` twins the Go hub's relay transport tests, for example `testSaveConditionalOutcomes` and `testErrorMapping`.
- **Sim (twenty tests).** `RelaySimOrderTwins` has 6 and `RelaySimSwitchTwins` has 14. They run the relay sim's rules on a test-only Swift port of the sim model: `SimPhone` and `SimHub` with transparent JSON envelopes. The phone's relay leg is the real `HostedRelayTransport` and `HostedRelayClient`. The CloudKit leg is `InMemoryCloudTransport` as a `ConditionalTransport` behind `SimCloudKitLeg`. `SimHub` uses the raw client with `DEVICE_KIND_MAC`. `RelaySimCensusTests` checks that every `Test*` of the relay's `sim/sim_interop_test.go` has a twin under the same name.

Every scenario class runs on a `RelayBackend`: the fake by default, with no network in public CI. On the stand, the `*InteropTests` subclasses in `Interop/HostedRelayInteropTests.swift` rerun the same classes. `RelaySocketInteropTests` adds checks of the production socket seam:

- the real dialer opens;
- a refused upgrade is `.http(status: 401)`;
- close codes 4000 and 4001 survive (R13);
- an idle socket outlives 45 s.

**Running on the stand:** `make relay-interop-kit RELAY=../relay`.

Do not confuse it with `make relay-interop`, which is the Go hub's interop target. The script, `scripts/relay-interop-kit.sh`:

1. needs Node (`npx`), `curl` and `openssl`;
2. runs `npm ci` in `<relay>/worker` when `node_modules` is missing;
3. starts `wrangler dev` there, in its own process group, on fresh state in a temp dir. The stand uses `RELAY_ENV=dev` (the `/dev` endpoints), attestation off and a random session secret;
4. waits for `/healthz`;
5. runs `make kit-test FILTER='InteropTests'` with `WATCHTOWER_RELAY_INTEROP_URL` set to the stand's origin;
6. kills and waits for the wrangler group and the test run on exit, failure, SIGINT and SIGTERM, and removes the temp dir.

Without `WATCHTOWER_RELAY_INTEROP_URL`, every interop test skips in `setUp`.

Script settings and its stand config:

- **Fixed port.** The port is 8787 (`RELAY_INTEROP_PORT`), not a random one: the relay checks the origin signed into `register` and `login` against `RELAY_SERVER_ORIGIN`, so the origin must be known before the stand starts. The script refuses a port that is already held.
- **Register limit.** The stand's config is a copy of the worker's `wrangler.jsonc` in the temp dir, with `REGISTER_LIMIT` raised from 10 registrations a minute per address. Every test registers devices of its own, all from 127.0.0.1. The relay checkout itself is never edited.
- **Other settings.** `RELAY_INTEROP_FILTER` overrides the test filter. `RELAY_INTEROP_KEEP=1` keeps the temp dir with wrangler's log and state.
- **Proto pin.** The script warns when the relay checkout's `HEAD` is not the Kit's proto pin.

**Fake-only scenarios (R15).** Some scenarios need the fake's log, faults, limits or clock, or need the server down. These skip on the stand and give their reason (`requireFake`, `SimWorld.fake`): `testSwitchToCloudKitDuringRelayOutage`, `testNoAckedWriteLostAcrossDeploy`, `…AcrossCrash`, and the 1001/4001 fault scenarios. The relay's own interop suite proves their server half against the real server. Their client half is client code, the same on the fake.

Task 12's run against the stand at `3a99bd7`: 44 passed, 20 skipped, 0 failed. Task 17's run at `bcca870` (Phase 3): 46 passed, 24 skipped, 0 failed.

**Two Kit ↔ Go hub harnesses (since Phase 3b's merge of `feature/go-hub`).** They check different things and both stay; 3b attempts no merge of the two (R15's cost).

- `scripts/relay-interop.sh KIT=1` + `GoHubInteropTests` (Go hub Phase 2 Task 12, env `WT_HUB_INTEROP_DIR`): the built CLI as a live headless hub, with the typing and session grants.
- `scripts/relay-interop-kit-hub.sh` + `internal/hub/interop_kit_test.go` + `KitGoHubInteropTests` (Phase 3a Task 13, env `WT_GO_HUB_INTEROP_DIR`): the Kit's link pieces, vouch, Try Again, ordered actions and unlink.

The environment variables do not collide, and `TestInterop_KitPhone` skips without `-kit-dir`, so the first runner's `-run '^TestInterop_'` passes over it.

**The desktop host on the stand (Phase 3b Task 24, R24).** `RELAY_INTEROP_DESKTOP=1 make relay-interop-kit-hub RELAY=<relay checkout>` is the second harness's desktop run: the Go half runs `-run '^TestInterop_KitPhoneFollowsASwitch$' -kit-desktop` and the Kit half gets `WT_GO_HUB_INTEROP_DESKTOP=1`; in it the relay-only `testKitPhoneLinksDrivesAndUnlinksTheGoHub` skips, so the one handoff folder serves the switch test alone (Task 20). Unset or `0` is the relay-only run, unchanged. Its pieces, test-only:

- `startDesktopHub` (`internal/hub/interop_desktop_test.go`, build tag `interop`) runs `Run` as a desktop host: the relay on the stand through the wire tap, CloudKit through the real bridge client over a `bridgefake` on the hub dir (the bridge process is a `sleep` stub in its own process group), `["cloudkit","relay"]`, the gate opened by a fresh sidecar and `hub enable`. `TestInterop_DesktopHostOnTheStand` runs it under `make relay-interop`.
- `serveCloudKitLoop` serves that fake's phone side on `127.0.0.1:<random port>` behind a per-run token (32 random bytes, `Authorization: Bearer`; a request without it is 403): `POST /changes`, `/save`, `/delete` (conditional on `absent` or the change tag) and `/accept-share` (the phone's iCloud user becomes an accepted participant of both shares, and its writes carry it as their creator). The Go test hands the URL and the token to the Kit in `ck.url` (`{"url","token"}`, mode 0600). `TestLoopbackRefusesWithoutTheToken` and `TestLoopbackListensOnLoopbackOnly` pin the boundary.
- `LoopbackCloudTransport` (`WatchtowerHostedRelayTesting`, linked by no app target) is the Kit phone's iCloud leg over it: `CloudSyncTransport` + `ConditionalTransport`, every change page in one batch, a record with an asset refused (assets are not carried). `LoopbackCloudTransportTests` runs it against a `URLProtocol` stub.

**The switch end to end (Phase 3b Task 20).** `make relay-interop-kit-hub RELAY=<relay checkout at the pinned commit> RELAY_INTEROP_DESKTOP=1` runs `TestInterop_KitPhoneFollowsASwitch` (Go) beside `KitGoHubInteropTests.testKitPhoneFollowsBothWays` (Kit). Each skips without its switch (`-kit-desktop` / `WT_GO_HUB_INTEROP_DESKTOP=1`), and the desktop run is never part of a CI path. The relay checkout must be the proto pin's commit (`internal/hub/transport/relay/VERSION`): a later relay answers the Go hub's `register` "invalid request". The run:

1. Two Kit phones link over iCloud (the loopback store, private scope) with the code `OpPair` issues; the hello carries no relay id.
2. The first phone upgrades with the calls `RelayUpgrader` makes: the device record with the proven relay id, `vouch`, `add_slot`, the first `data/<mac>` read, `transport_switch(relay)` through the outbox and its copy in the relay mailbox. The Go side checks the stored `relay_device_id`, `set_hub_readers` (the wire tap keeps the last reader set), the hub on the relay, and that the free phone's record naming the first phone's id is refused `key_mismatch` with nothing stored.
3. The phone follows `transport_switched` through `TransportFollowerPolicy` (a test-side executor with the app's order: outbox held, unechoed actions queued again, route, keybox, `epoch_ack`), its three canary actions written on iCloud before the switch are resent with the same bytes and applied once, its iCloud mailbox is drained; the free phone lists its two actions Not delivered on `hub_on_relay`.
4–5. The phone asks for iCloud; the Go side deletes every save into the phone's relay mailbox the moment it lands, so the phone follows the relay data zone's marker and reads its keybox from the iCloud data zone; the relay mailbox is drained. The ask alert raised while on the relay is in the iCloud data zone with one signal and opens with `AlertOpener`. The stand has no APNs key and would settle the push `push_off` at once, so a test round tripper (`pushWait`) answers the hub's `send_alert` `RATE_LIMITED`: the push still waits at the switch, as `TestSwitchToCloudKitResignalsOpenQueuedAlerts` needs.
6. The relay again at once: `too_soon` with `retry_after_s` ≤ 300, the phone stays on iCloud. The Go side then moves its clock 8 days (`interopOpts.clock`; the relay transport keeps the real clock) and runs a daemon cycle until the relay epoch is no longer retained.
7. An action sealed in that epoch before the move (held in the outbox, its `created_at` on the hub's moved clock, "made on the last day" as in `TestAPhoneOfflineOver7DaysAcrossASwitchRecovers`; one 8 days old is answered expired) draws `resend_from`, is resealed under the same `action_seq` and applied once.
8. The relay again (the anti-flap is past on the hub's clock), then `/dev/entitlement` expires the phone's account: the hub falls back to iCloud `by: entitlement_expired`, the phone follows, nothing is applied twice and nothing is left unlisted.
10. No canary in any tapped relay stream or loopback request body (`cloudKitLoop` keeps every authorized body).

The handoff files are listed at the top of the Go test's section in `internal/hub/interop_kit_test.go`.

### CI mode of the interop scripts

There is no relay CI job: the owner dropped it on 2026-11-02 (spec §12 p. 4; the Swift part is being rewritten in Go). The two Kit interop scripts stay as local entry points, run by hand, and keep a non-interactive CI mode:

```
RELAY_INTEROP_CI=1 WATCHTOWER_CHECKOUT=<watchtower checkout> bash <watchtower checkout>/scripts/relay-interop-kit.sh <relay checkout>
RELAY_INTEROP_CI=1 WATCHTOWER_CHECKOUT=<watchtower checkout> bash <watchtower checkout>/scripts/relay-interop-kit-hub.sh <relay checkout>
```

(or `make relay-interop-kit` and `make relay-interop-kit-hub` with `RELAY=<relay checkout>`, run from the Watchtower checkout.)

- **What each runs.** `relay-interop-kit.sh` runs the Kit's `*InteropTests` classes against the stand. `relay-interop-kit-hub.sh` runs the Kit phone against the Go hub on the same stand: the Go test `TestInterop_KitPhone` (build tag `interop`) beside the Kit's `KitGoHubInteropTests`, handing off through files.
- **Needs.** A Mac with Xcode (Swift 6 toolchain), Node with `npx` (`npm ci` runs in `<relay>/worker` when `node_modules` is missing), `curl` and `openssl`. The hub script also needs Go with cgo. Both scripts use the stand's fixed port 8787 (`RELAY_INTEROP_PORT`) and refuse a port that is held or already answers, so run the two one after the other, not at the same time.
- **`WATCHTOWER_CHECKOUT`** is the Watchtower checkout to test. It defaults to the script's own repo, and must hold a `Makefile` and `WatchtowerKit/`, otherwise the script refuses.
- **`RELAY_INTEROP_CI=1`.** Non-interactive: stdin is `/dev/null` and the scripts never prompt. The tests' output goes to stderr when the run ends. The last line of stdout, printed exactly once and also on failure or refusal, is `relay-interop: passed=N skipped=M failed=K`. The counts come from the runners' own output (XCTest's `Executed N tests, with S tests skipped and K failures` for the total, with the `Test Case '...' failed` lines as the failed tests because K counts assertions, and `go test -v`'s top-level `--- PASS/SKIP/FAIL` lines). The exit code is non-zero on any failure, and 1 when no test passed or failed, even if some were skipped (every interop test skips without the stand's URL). A run that fails without a failing test (a build error, a timeout) has `failed=0` and a non-zero exit.
- **Cleanup.** The stand, the Go test and the Kit run each have a process group; all are killed and waited for on every exit path, as without CI mode. After a SIGINT or SIGTERM (a cancelled or timed-out run) the output so far is still shown on stderr and counted, and the summary line is still printed. Give an unattended run a timeout.
- **Tests.** `scripts/tests/test-relay-interop-kit-ci.sh` and `scripts/tests/test-relay-interop-kit-hub.sh` run the scripts against stubs (`make test-scripts`).

## Phase 3a — the phone app uses it (2026-11-02, board #1241, #1242, #1247)

Plan: `docs/superpowers/plans/2026-10-31-relay-client-phase-3.md`. Phase 3a wires the relay into the iPhone app and ships dark: no Release build builds a relay client (Phase 3 R1). Phase 3a changes no Go hub production file; the Go side is test-only. Phase 3b (upgrading a CloudKit link to the relay, the switch end to end) is the next section.

### Identity and Keychain items (Phase 3 R1)

`KeychainRelayIdentity` (`WatchtowerHostedRelay/Identity`) is the `AppAttestKeyStore` of the app and owns two items on the Kit's `KeychainBackend`:

- `relay.auth`: the `relay_auth` Ed25519 private key, raw 32 bytes. `signer()` creates it on first use with `add`, never `write`, so two creators never clobber and a lost race reads the winner's. `existingSigner()` never creates. A locked device throws `KeyStoreError.locked` and creates nothing; a stored key that does not parse is `.corrupt` and is kept.
- `relay.attestkey`: the App Attest key id, UTF-8. A read error returns nil and leads into the lost-key path; it never touches `relay.auth`.

Both are `KeyAccess.afterFirstUnlock` (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), data-protection keychain, never synchronizable, in the app's private access group and never in the alerts group the notification extension reads. The phone's `relay_device_id` is lower-case unpadded base32 of SHA-256 of the `relay_auth` public key (52 characters, `RelayIDs`). Nothing is logged but op names and codes.

### Origin, entitlement and `RelayAvailability`

- **Origin.** `WATCHTOWER_RELAY_ORIGIN` in `WatchtowerMobile/Base.xcconfig` is empty in every committed setting, so a Release build has no relay origin (spec §4 said "default the production origin"; no production origin exists until spec §12 p. 5). It reaches `Info.plist` as `WTRelayOrigin`, and `RelayConfig` parses it: empty, an unexpanded `$(`, an invalid origin, or plain `http` to a host that is neither loopback nor a private LAN address is "not configured". A developer sets it for Debug only in the gitignored `Signing.xcconfig` (`Signing.xcconfig.template` shows `http://127.0.0.1:8787`, the stand).
- **Entitlement.** `WatchtowerMobile.entitlements` (Debug) carries `com.apple.developer.devicecheck.appattest-environment` = `$(WT_APP_ATTEST_ENV)`; `WatchtowerMobile-Release.entitlements` has no App Attest key. Phase 4 adds it to Release, and enabling App Attest on the App ID is the owner's portal step then.
- **`RelayAvailability`** (`WatchtowerMobile/Sources/App/Hubs`) is `.off(.notConfigured)` without an origin, `.off(.unsupportedDevice)` when DeviceCheck reports no App Attest, else `.available(origin)`. The attest check runs only when an origin is configured. `testAttestUnsupportedStaysOnCloudKit` (`WatchtowerMobile/Tests/RelayAvailabilityTests.swift`, Phase 3 R18) asserts that an unsupported device gets no relay and the CloudKit transport; `testAnEmptyOriginBuildsNoRelayObject` pins the dark ship (no `HostedRelayClient`, `HostedRelaySession` or `KeychainRelayIdentity`, no Keychain item, no DeviceCheck call, no connection).
- **What a Release build still runs:** v4 link codes (a headless host's relay-only code is refused with "works over Relay only"), epoch retention and `epoch_ack` toward an ordered hub, the rule 14 reseal, the follower on CloudKit (it finds nothing until a Go hub can switch), and the registry migration `v3-relay`.

### The shared session (Phase 3 R2)

The relay displaces an older socket of the same device (close 1001), so two relay hubs, or a hub plus a pairing slot, would displace each other. `HostedRelaySession` (`Transport/`) owns the process's one client and WebSocket and routes events by zone; transports attach and detach (`attach`, `detach(owner:)`). `SharedRelaySession` (`RelayAvailability.swift`) builds it on first use, only when the relay is `.available`, from `RelayParts.live` (DeviceCheck App Attest, `SecItemKeychainBackend` in the private group, `URLSessionRelayHTTP`, `URLSessionRelaySocketDialer`). Latched account events (`.entitlementInactive`, `.unsupportedVersion`, `.attestation`) are level-like; `.reachable(true)` clears them. The notification extensions link no relay target (Phase 3 R20).

### Pairing mode and `HostedRelayPairing` (Phase 3 R3, R5, R21)

`HostedRelayTransportMode` is `.hub` or `.pairing(slot:)`. In pairing mode both lanes map to the zone `pair/<slot>`, so the hello is the relay lane and the keybox the data lane, as on CloudKit, and `SecureTransport`, the replica's keybox read and `waitForGrant` work unchanged. After promote, the same store serves hub mode; cursors are keyed by lane and `relay_zone_names` records each lane's relay zone, so a lane whose zone changed resyncs from 0.

`HostedRelayPairing` wraps the account operations: `accountState()` (paying, slotted Macs), `open(mac:)` (`open_pairing`, with the slot pre-check first), `promote(slot:)`, `close(slot:)`, `removeSlot(mac:)` and `vouch(hubDeviceID:authPub:)`. Refusals are `Refusal` (`notPaying`, `slotsFull(macs:)`, `replacementLimit`, `pairingExpired`, `unreachable`, `updateRequired`, `attestationBackoff`) and `VouchRefusal` (`notPaying`, `updateRequired`, `hubNotOnRelay`, `slotsFull`, `notConfirmed`, `unreachable`, `attestationBackoff`). `vouch` is `GetChallenge{VOUCH}` → assertion → `vouch_hub`; every attempt takes a new nonce and a new assertion (assertions are serialized with login on the one App Attest counter), `ATTESTATION_FAILED` retries once, then the lost-key path, then once more.

Order after the owner confirmed the link: keys saved → `PromotedLink` (`LinkStore`, state `.confirmed`) → `vouch` → `.promoteSent` → `promote` (a `HUB_NOT_VOUCHED` vouches again once) → `.promoted` → linked. Every definite refusal after `.confirmed` moves it to `.needsOwner(reason)` with the keys kept; only the owner's Cancel deletes them. `PromotedLinkResumer` resumes confirmed links at every launch and foreground; they never hold the link screen. A `.promoteSent` link whose answer was lost asks the account state before it promotes again. A full phone registry when a link finishes is `.needsOwner(.tooManyMacs)` (ask #915).

### The link route rule (Phase 3 R4)

`LinkRoutePolicy.decide` is pure over the code and `RelayAvailability`:

- the hub is on iCloud (a v3 code, or v4 with `transport` absent or `cloudkit`) → `.cloudKit`;
- the hub is on the relay, the relay is available and the account is paying → `.relay(mac:authPub:)`;
- the paying check gave no definite answer (unreachable, attestation backoff) → `LinkFailure.relayUnreachable` ("Couldn't reach Relay"); an unknown answer is never read as "not paying", so a paying phone is never sent to iCloud;
- the hub is on the relay and the phone cannot use it: a hub that also offers CloudKit → `.macOnRelay` ("<Mac> runs over Relay"), a relay-only hub → `.needsRelay` ("<hub> works over Relay only", "Relay isn't available on this iPhone"). This departs from spec §8's third bullet, which linked such a Mac over iCloud only to receive `hub_on_relay`;
- `NOT_FOUND` at `open_pairing` → `.macNotOnRelay` ("<Mac> isn't on Relay yet", ask #915).

A Mac on Relay is also refused on the iCloud path: the completion fetch after the keys checks the newest transport marker and `hub_on_relay`; a link that never saw a heartbeat after its `linkedAt` ends with a `LinkNotice`, while a link that was alive follows the follower. The Kit reads `LinkPayload` v3 and v4 (`newestReadable` 4) and still issues v3; a v4 code's `relay_device_id` must equal the base32 SHA-256 of its `relay_auth_pub` (`badRelayIdentity` otherwise). The hello carries the phone's own `relay_device_id` (`DeviceHello`; the Go hub's `validRelayDeviceID` is the format rule), pinned by `device_hello` in `hub_contract_cases.json`, read by `HubContractFixtureTests` and Go's `TestHubContractFixture`. `DeviceGrant` gains the hub's relay fields. An iCloud-linked phone names its relay id in its own `device` record instead (Phase 3b Task 23, R22): `DevicePayload` carries `relayDeviceID`, `relayAuthPub` and `relayIDSig` (an invalid id decodes as nil), signed by the `relay_auth` key over `RelayIDProof.message` (`"watchtower/v1/relay-id"` ‖ 0x00 ‖ hub_id ‖ device_id ‖ id). The Go hub stores the id only when `link.VerifyRelayIDProof` holds and no other linked phone holds it, clears the phone's admission stamp, and re-syncs `set_hub_readers` and the account state at once, so `payingByDevice` sees the phone; pinned by `device_payload` in `hub_contract_cases.json` (Go `TestDevicePayloadCases`, Kit `testDevicePayloadRelayIDCases`, `RelayIDProofTests`). The phone fills and signs them in `AppRoot.devicePayload` only while the hub's `LinkRecord.relayUpgrade` is set and the relay is available (Task 19); every other device record is byte for byte an iCloud link's. The hello's `relay_device_id` carries no proof yet: a proof there is a later hardening (ask #980). A relay-only link needs no iCloud account (Phase 3 R19): `CloudKitLinkAccess` joins and leaves nothing for a relay route, and an iCloud account change ends CloudKit-route links only.

**Upgrading an iCloud link to the relay (Phase 3b Task 19, model only).** `HubSession.upgradeToRelay()` runs `RelayUpgrader` (`WatchtowerMobile/Sources/App/Hubs/RelayUpgrade.swift`), whose state is `LinkRecord.relayUpgrade` (JSON only, no registry migration; one a build cannot read reads as absent). Step 0 writes nothing: `.relayOff` unless the relay is `.available`, `.noRelayIdentity` unless the linked grant's `relay_device_id`/`relay_auth_pub` are coherent, `.notSupported` for a hub without `ordered_actions`, then `get_account_state` three-way (not paying refuses, a failed read is a no-op). Then, each step persisted before the next (a compare-and-set on the record, so a rejection or a switch meanwhile wins): the device record names the relay id with its proof and is flushed on iCloud; `vouch_hub`; `add_slot` (`HUB_NOT_VOUCHED` vouches again once; a Mac already in the slots skips both; on success the link keeps the Mac's relay identity, `setRelayIdentity`, and the route stays iCloud); the reader wait, one `data/<mac>` pull on the relay per pass (`FORBIDDEN` = not a reader yet) for at most 24 h of wall time from `add_slot` (`RelayUpgrade.readerWaitLimit`, `.readerNotConfirmed` past it); then `transport_switch{relay}` through the ordered outbox (`ActionOutbox.enqueueSwitchRequest`) with the same control id in the relay mailbox. The answer: the follower's move to the relay or `requestAnswered` ends it as `switched` (while the request waits, the shared policy takes a same-epoch `transport_switched{relay}` on iCloud as that move, `FollowerState.relaySwitchRequested`); `RelayFeed`'s rejection handler takes `transport_switch_rejected` (read on iCloud by the feed, on the relay by the pass, a second copy deleted unread): `too_soon` keeps `retry_after_s` as `.tooSoon(retryAt:)`, `not_paying` and `not supported yet` end it, a first `unavailable` asks once more after `retry_after_s`, a second ends it; a reason this build does not know is read as `unavailable`. The slot is kept after any refusal and freed only by an unlink (the farewell over iCloud, then `remove_slot`, a failure kept in `pending_slot_removals`). Passes resume at launch, on the return to the foreground and after a fetch (at most every 30 s while active). Every text lives in `RelayUpgradeRefusal.message(macName:now:)`, pinned by `RelayUpgradeCopyTests`; the wiring is `RelayUpgradeWiringTests`.

Three Macs in slots shows the "Add Mac" screen (`RelaySlotsModel`, `RelaySlotsView`) with **Remove**, which runs that Mac's whole unlink: the farewell first, then `remove_slot`, retried at launch on failure (`pending_slot_removals`, `pending_farewells` in the registry migration `v3-relay`; Phase 3 R14).

### The follower, the side reader and the stores (Phase 3 R11, R12)

- **`TransportFollowerPolicy`** (`WatchtowerSync/Relay`) is a pure decision table for sim rules 12, 12a, 13, 15 and R32. The sim twins' `SimPhone` and the app's `TransportFollower` (`WatchtowerMobile/Sources/App/Hubs`) both run it, so the twins pin the production logic. The follower hears `transport_switched` and `hub_on_relay` (from `RelayFeed`) and the transport marker (from the hydrator) and acts in a crash-safe order: the outbox stops writing, unechoed actions are queued again for the new transport (rule 13) or listed as Not delivered (R32, "<Mac> runs over Relay now"), the new route is written to the registry row (`LinkRecord.transport`, `leftTransport`, `switchedBy`, `switchedAt`), the switch's keybox is merged, and only then is the control reported handled; the session is rebuilt on the new route's store.
- **Stores.** Each route has its own `TransportStore` file per hub (`cloudkit-transport.sqlite`, `relay-transport.sqlite`; `HubPaths.transportStorePath(_:route:)`). A move resets the replica's two sync tokens (`ReplicaStore.adoptRoute`), the first data pull of the new route is the hub's whole republished window and slice rows it did not return are deleted; the outbox, controls, keys and alert watermark stay.
- **`SideMailboxReader`** reads the mailbox of the transport the phone is not on, only while the hub has both routes. Rule 15: with `leftTransport` set, the mailbox there is drained once, then `leftTransport` is cleared. A relay account that refuses (`ENTITLEMENT_INACTIVE`, `FORBIDDEN`) stops the drain until the next launch (rule 16). Rule 12: on route `.relay`, once the relay has not answered for more than 60 s, the CloudKit `RelayZone` is read every 30 s for controls only (`TransportFollowerPolicy.otherMailboxAfter`/`otherMailboxEvery`). It never writes on that transport.
- No switch screen exists before Phase 4 (Phase 3 R13): a developer sees a switch in logs and the registry, and `hub_on_relay` only as Not delivered rows.

### Epochs (Phase 3 R8–R10)

- **R8.** `HubLinkKeys` keeps a superseded epoch's keys for 7 days after a newer epoch arrived (`previousEpochGrace`, `EpochKeys.supersededAt`), at most `maxEpochs` = 8. Items written before this build have no stamp and are stamped at the first merge, never dropped. The notification extension's alert material carries every retained epoch. Ask #843 replaced sim rule 14's 14 days with 7.
- **R9.** `epoch_ack` goes out on every raise of the newest epoch, to an ordered hub only (`TransportFollowerPolicy` command `sendEpochAck`).
- **R10.** On `resend_from`, `ActionOutbox` reseals rows sealed in an epoch older than the current one (`resealOlderEpochs`) by opening the phone's own envelope with the derived `K_relay[dir, e]`, with the same `action_seq`; rule 13's switch resend and a plain gap resend stay byte for byte.

### Interop and CI entry points

`make relay-interop-kit-hub RELAY=<relay checkout>` (`scripts/relay-interop-kit-hub.sh`) runs the real Go hub's `TestInterop_KitPhone` (`internal/hub/interop_kit_test.go`, build tag `interop`, test-only) beside the Kit's `KitGoHubInteropTests` (`FILTER=KitGoHubInteropTests`) on the relay's stand, handing off through files: link, vouch, promote, actions and unlink. With attestation off, today's Go hub registering as a Mac is a hub the phone vouches for. The CI mode's switches, `RELAY_INTEROP_CI=1` (`scripts/relay-interop-ci-lib.sh`) and `WATCHTOWER_CHECKOUT`, are in "CI mode of the interop scripts" above.

## Phase 3b — upgrading an iCloud link and the switch end to end (2026-11-03, board #1241, #1242, #1247)

Same plan, Tasks 19–24 (rulings R22–R25). Phase 3b merged `feature/go-hub` into the branch (Task 22), so the phone's switch runs against the real Go desktop hub. It is still dark: nothing outside tests starts an upgrade (R23).

- **The device record's relay id (Task 23, R22).** An iCloud-linked phone names its `relay_device_id` in its own `device` record, with `relay_auth_pub` and `relay_id_sig` over `"watchtower/v1/relay-id"` ‖ 0x00 ‖ hub_id ‖ device_id ‖ id; the Go hub stores it only with a valid proof, takes it off any other row holding it (ask #1005: only the key's holder can sign, so a stale row or a hello's unproven claim loses it) and re-syncs `set_hub_readers`. A hello never takes an id another row holds. Details in "The link route rule" above and in the protocol spec §5.5; the Go side is in [go-hub.md](go-hub.md), Phase 3.
- **The upgrade's steps and refusals (Task 19).** Step 0 checks (relay available, the hub's relay identity, `ordered_actions`, paying), then the device record, `vouch_hub`, `add_slot`, the reader wait (24 h), `transport_switch{relay}`; refusals `too_soon` (keeps `retry_after_s`), `not_paying`, `not supported yet`, `unavailable` (one automatic retry) and `.readerNotConfirmed`, each its own state, with the slot kept until an unlink. Details in "Upgrading an iCloud link to the relay" above.
- **The switch interop (Task 20)** and **the second harness's desktop run (Task 24, R24)**: "The desktop host on the stand" and "The switch end to end" under "Twins and interop"; the two Kit ↔ Go hub harnesses both stay (R25).

## v1 limits

- **A resync that the relay refuses mid-way is silent.** Every pull from 0 sets `Changes.resync` (relay `bcca870`, Phase 3 Task 17), so the tombstone floor no longer stalls a multi-page resync. What can still stall one is the relay refusing a flagged middle page with `TOKEN_EXPIRED` (a zone rebuilt mid-resync); the pull is then held, and the only trace is one `relay resync stalled partway, held` log line (category `HostedRelay`, zone kind only). No `relayEvents` case or screen reports it.
- **Macs do not attest (R18); vouching is proven on the stand with attestation off.** The relay requires App Attest for `DEVICE_KIND_MAC`. Phase 3a builds the phone's `vouch_hub` and the Kit pins relay `bcca870`, but the interop's hub registers without attestation on a stand with attestation off. A real attestation assertion is first exercised on staging.
- **`testAttestUnsupportedStaysOnCloudKit` (R16) is done** in `WatchtowerMobile/Tests/RelayAvailabilityTests.swift` (the routing half; Phase 2 pins the client half in `testAttestUnsupportedRefusesBeforeAnyRequest`).
- **No `MailboxAddressing` and no `PagedChanges`** in the Kit (R4, R5). They served a Swift hub, which ask #802 moved to Go. A later consumer that needs server pages adds `PagedChanges` as an optional protocol.
- **Close codes (R13).** The WebSocket runs on `URLSessionWebSocketTask`, and close codes are read from `closeCode.rawValue`. The stand confirms that 4000 and 4001 survive. If an OS release breaks this, `URLSessionRelaySocketDialer` moves to Network.framework behind the same `RelaySocketDialer` seam.
- **The fake follows the README; where the stand disagrees, the stand wins (R20).** Task 12 found no protocol difference in the scenarios that run on both. The only stand-only difference is the register rate limit, which the fake does not model and the script raises. `send_alert` (the stand has no APNs key) and multi-page resyncs past the tombstone floor (`Changes.resync`) are not exercised on the stand.
- **Fake-only proof (R15).** The outage, deploy, crash and 1001/4001 fault scenarios are proven against the fake in CI and against the real server only in local interop runs, since the relay CI job was dropped (owner, 2026-11-02).
- **Attachments (#1469).** `NOT_FOUND` from `get_download`, or a blob 404 that a second `get_download` confirms as `NOT_FOUND`, skips the attachment: the record is buffered without a file and the next page read brings it as it is now. Every other error (a 403 or other non-2xx, an unsafe blob URL, a body over `maxAttachmentBytes`, a 404 on an attachment the relay still serves) still fails the page, so the zone's cursor stays put. The phone's own uploads are never downloaded back: `relay_own_attachments(zone, name, attachment_id)` in `TransportStore` records each attachment this store uploaded, the Kit relay pull skips those, and `finishRelayResync` deletes orphan rows.
- **An undecided switch control is retried only in memory (Phase 3).** A `transport_switched` or `hub_on_relay` the follower could not decide (the paying check did not answer) is handed again every cycle, but the feed's token has moved past it, so a relaunch forgets it. The transport marker, which every switch writes into the transport it leaves, then leads the phone; what stays open is only an answer that never comes before a relaunch on a hub that wrote no newer marker.
- **Actions on today's path are not moved by a switch (Phase 3).** The rule 13 resend and the R32 listing touch ordered actions only. An action sent before the hub's grant turned the ordered path on settles the old way, and one never answered fails after 24 hours with a visible message.
- **No pushes (Phase 3a).** A backgrounded app on the relay waits for the foreground: the relay has no APNs path until Phase 4.
- **A relay link outlives its unlink in the Go hub's device list.** The Go hub reads `device` records only in CloudKit's shared RelayZone (`internal/hub/actions/processor.go`, `kindDevice`; on the CloudKit standby side too), so a farewell written over the relay, from a relay-paired link or an upgraded link on the relay, is never applied. The row stays until the owner removes it on the Mac, although the freed slot already drops it from the readers. The same gap means a name change or a typing/permission request made while on the relay does not reach the hub. An iCloud link's farewell, mid-upgrade included, removes the row. A stale row keeps its relay id until the same phone's proven `device` record moves it to the new row (ask #1005), so a later upgrade works. A relay-paired re-link under a new device id cannot do that, because the relay path reads no `device` records: its unproven hello links with no relay id while the stale row holds it, and the phone is not heard until the owner removes the stale row and it links again. The phone's Keychain keeps its device identity and `relay_auth` key together, so this needs the identity lost and the relay key kept.
- **Promote residual (Phase 3 R5).** A link refused for good after the owner's confirmation waits as a Settings → Macs row until the owner cancels it, and the Mac keeps a linked device that never reads until it is removed there. A slow readers sync keeps "Waiting for <Mac>" longer; until the first data-zone read succeeds, `FORBIDDEN` is "not a reader yet", retried with no time window.
- **Linking over Relay may dial twice in sequence (Task 10).** At most one socket at a time, never in parallel.
- **R07/R20 alerts have no shots.** The two alerts cannot be captured as shots on iOS 26 (see the shots INDEX); they are checked by hand on a device.
- **`relayUse` is `.no` for a hub without the Mac's relay id (Task 11):** a move to the relay is refused, the policy never asks.
- **Side mailbox (Task 12).** The CloudKit drain keeps the phone's own `device` record (the relay drain deletes it per rule 15), so a stale `device` record stays in the CloudKit zone. A CloudKit drain re-fetches the whole CloudKit database once per launch (the engine keeps one state for the whole database). The outage poll starts at the session's first unanswered fetch, with a 60 s floor.
- **A relay-only link without iCloud has no fallback** (Phase 3 R19) until a re-link.
- **An upgrade whose answer never arrives waits at `.requested` (Phase 3b).** Once `transport_switch{relay}` is sent, the pass waits for the follower's move or a `transport_switch_rejected`; an answer that is lost (for example a rejection queued only in the relay mailbox that the rule-15 side reader drains before a pass reads it) leaves `upgradeToRelay()` at `.underWay(.requested)` with no time bound, each pass pulling the relay mailbox at most every 30 s while active. A rejection reason this build does not know is not this case: it is read as `unavailable` (one automatic retry, then refused).
- **Phase 3b, the upgrade is model only (Task 19, R23):** `HubSession.upgradeToRelay()` exists and is tested, but no screen calls it: the per-Mac switch screen is Phase 4; the switch end to end on the real hub is Task 20. The dark ship means no production phone can pay, link or switch over Relay before Phase 4.
- **Smaller parked items.** A pull after a terminal stop redials the socket each time. A `ZoneChanged` that carries a record still costs one `changes` round trip (R9).
