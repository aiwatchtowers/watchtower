# Relay client — the phone's hosted relay transport in the Kit (Phase 2, 2026-10-31, board #1239, #1240)

Spec: `docs/superpowers/specs/2026-10-29-relay-client-design.md` (below: "the spec"). Plan: `docs/superpowers/plans/2026-10-31-relay-client-phase-2.md`, whose rulings R1–R20 this note cites. Server contract: the relay repository's `proto/README.md` and `relay.proto` at the pinned commit; client rules: its `sim/README.md` ("sim rule N").

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

**Does not ship.** Nothing is wired into the app: no phone code constructs the client or the transport (R19), and nothing reaches a screen, a setting or a notification, so no guide page changed. Phase 3 brings:

- the relay identity (`relay_auth` keys and their storage);
- the App Attest key id's Keychain store and the `com.apple.developer.devicecheck.appattest-environment` entitlement (R2);
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

The pin is relay `main` at `3a99bd7` (PR #2), the same commit as the Go hub's copy, so both ends of a hub/phone pair speak one proto.

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
- **Opening a socket.** The client dials `GET /v1/ws` with the bearer token, then sends `Hello{1, token}` and waits for `HelloOk`. It then subscribes each zone one by one: a refused zone is dropped and reported, and a subscribe with no answer within 10 s cuts the connection. After every connect the client emits a record-less `zoneChanged` for each subscribed zone.
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

**`TOKEN_EXPIRED` (R10).** The zone resyncs from 0. The resync's progress — its cursor and the names seen so far — is kept page by page in `relay_resync_seen`, so after a restart an interrupted resync resumes where it stopped. Only after the last page does the transport buffer a deletion for each name in `relay_records` that the resync did not return. A record this device never saw from the server is never deleted by the diff. If the relay refuses a middle page, the resync is marked stalled and the zone is held for `resyncStallHold` (1 h). `start()` ends the hold at once.

**Socket events (R9).** A `zoneChanged`, with or without a record, means "pull this zone". After a connect, the transport reads `get_account_state`; an entitlement that does not pay is reported.

**Attachments.** A save uploads its asset first: `create_upload`, then a PUT of the file; the save names the `attachment_id`. A pulled record's attachment is fetched with `get_download` and a GET, capped at `maxAttachmentBytes`, into the stash before its page is buffered. Blob URLs must be HTTPS (plain HTTP only to loopback, for the stand). A redirect or any non-2xx answer fails. Signed URLs are never logged.

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
| `ERROR_CODE_UNSPECIFIED` | `.permanent("unspecified")` |

**`relayEvents` (R11).** `TransportEvent` gets no new cases, and `MAILBOX_QUOTA_EXCEEDED` is today's `.quotaExceeded`. Relay-only signals go on `HostedRelayTransport.relayEvents` (`HostedRelayEvent`, newest 256 kept):

- `.control(kind:detail:)`;
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

Task 12's run against the stand at `3a99bd7`: 44 passed, 20 skipped, 0 failed.

## v1 limits

- **Resync below the tombstone floor.** This is a relay bug. A `TOKEN_EXPIRED` resync from 0 of a zone whose tombstones were purged is refused again partway. The fix is relay PR #3 (`Changes.resync`), not merged yet and tracked as board #1430. Until it lands, the transport marks the resync stalled and holds the zone for 1 h (`resyncStallHold`). It deletes nothing, because R10's diff runs only after a complete resync. A resumed resync stalls again at its first expiry.
- **A stalled resync is silent.** The only trace is one `relay resync stalled partway, held` log line (category `HostedRelay`, zone kind only). No `relayEvents` case or screen reports it.
- **Macs do not attest (R18).** The relay at the pin still requires App Attest for `DEVICE_KIND_MAC` and has no `vouch_hub` or `DEVICE_KIND_HUB` (relay ask #805). Until that ships and Phase 3 vouches the hub, no production relay can admit a Watchtower hub. "A phone and its Mac on the real relay" is proven only on the fake, and on the stand with attestation off.
- **`testAttestUnsupportedStaysOnCloudKit` (R16)** is the one attestation scenario still open. The relay's scenario promises that an unsupported device stays on CloudKit, which is `TransportFactory`'s routing. Phase 3 adds the test in `WatchtowerMobile/Tests`. Phase 2 pins only the client half, in `testAttestUnsupportedRefusesBeforeAnyRequest`.
- **No `MailboxAddressing` and no `PagedChanges`** in the Kit (R4, R5). They served a Swift hub, which ask #802 moved to Go. A later consumer that needs server pages adds `PagedChanges` as an optional protocol.
- **Close codes (R13).** The WebSocket runs on `URLSessionWebSocketTask`, and close codes are read from `closeCode.rawValue`. The stand confirms that 4000 and 4001 survive. If an OS release breaks this, `URLSessionRelaySocketDialer` moves to Network.framework behind the same `RelaySocketDialer` seam.
- **The fake follows the README; where the stand disagrees, the stand wins (R20).** Task 12 found no protocol difference in the scenarios that run on both. The only stand-only difference is the register rate limit, which the fake does not model and the script raises. `send_alert` (the stand has no APNs key) and multi-page resyncs past the tombstone floor are not exercised on the stand.
- **Fake-only proof (R15).** The outage, deploy, crash and 1001/4001 fault scenarios are proven against the fake only. Phase 3's relay CI job, which builds the Kit client against the real server (spec §12 p. 4), will cover them.
- **Smaller parked items.** A pull after a terminal stop redials the socket each time. A `ZoneChanged` that carries a record still costs one `changes` round trip (R9).
