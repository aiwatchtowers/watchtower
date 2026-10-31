# Go hub — Phase 4: pushes, Desktop indicators, hub-side measurements, the mobile-companion note Implementation Plan

**Before starting: re-check this plan against the code** (phases 1–3 as merged into feature/go-hub, the relay's push API at its then-current commit, the relay client spec's Phase 4 on the phone). Update the plan, or file an owner ask, before Task 1.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Go hub on the hosted relay pushes each work alert to every paying phone through `send_alert` as a sealed `ask_alert` envelope the phone's notification extension opens with no network; Desktop's Settings → Mobile shows the RC §10 indicators per phone and for the hub, plus a Diagnostics screen of content-free hub-side latency samples; `docs/features/mobile-companion.md` and the guide describe the Go hub.

**Architecture:** On top of Phase 3 (the switcher, `HubCenter`, `MobileSettingsModel`, `hub status|phones --json`) and the relay push API pinned at relay commit `3a99bd72758687e1393c3ab036484ac03cee98b1` (the commit in `internal/hub/transport/relay/VERSION` today). New Go: `secure.Sealer.AlertPush` (AAD wire name `alert-push`, a `secure.Push` value only the sealer builds), `transport.Alerts` implemented by the relay transport (`send_alert`), `internal/hub/alerts` (the pusher: eligibility from the relay account state, an at-most-once sidecar ledger, retry inside a freshness window, outcome classes), `internal/hub/measure` (read → applied → slice saved stamps into a bounded sidecar table, p50/p90 per step and transport), runtime facts in `status.json` (relay health, quota class, paying phones), `hub diagnostics --json`. New Swift: indicator rows in `MobileSettingsModel`, `MobileDiagnosticsModel` + view, design shots. Docs: the note rewrite, `go-hub.md`, the guide pages.

**Tech Stack:** Go 1.26 (cgo build as before), `google.golang.org/protobuf` (vendored relay proto, no regeneration needed — `relayv1` already carries `SendAlert`/`RegisterPushToken`); Swift 5.10 mode / Swift 6 toolchain for Desktop and one Kit test; no new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-31-go-hub-design.md` — §14 row 4 (this phase), §2 row "§10", §6.1, §12.4, §12a "Alerts", §13 (canaries, one test per branch). Protocol: `docs/superpowers/specs/2026-10-31-hub-phone-protocol-design.md` §4.3 (AAD), §4.6, §4.8 (relay alerts), §6.2 (`ask_alert` row), §10, §11 item 5. Relay client spec (`git show origin/feature/relay-client:docs/superpowers/specs/2026-10-29-relay-client-design.md`, "RC §N") §1 (p50 < 500 ms), §9 ("Relay unavailable" after 60 s), §10 (pushes, Desktop, measurements), §13 row 4, §14 (docs). Relay contract at `3a99bd7`: `proto/relay/v1/relay.proto` (`register_push = 17`, `send_alert = 18`, `SendAlert{phone_device_id = 1, envelope = 2}`, `RegisterPushToken{token = 1, env = 2}`, `PushEnv`, `AccountState.phones` / `SlotHolder{phone_device_id, paying}`, `ErrorCode`, `Error.retry_after_s`), `worker/src/do/device/push.ts`, `worker/src/do/device/ops.ts` (`ERRORS`), `worker/src/push/apns.ts`. Prerequisites: Plans 1a, 1b, 2, 3 merged into `feature/go-hub`; this plan builds on their **Produces** blocks only, every one of which Task 0 re-checks.

## External dependencies (ordered last)

| Blocker | What is missing | Tasks it blocks |
|---|---|---|
| **Relay client spec Phase 4 on the phone** (neighbour session; RC §13 row 4, boards #1243/#1244/#1246) | `register_push{token, env}` at every launch; the NSE reading the inline envelope (`AlertSource.inline`) and opening it under `alert-push`; silent push → background `changes`; the phone's Diagnostics with its own end-to-end samples. | Task 12 |
| **Relay staging with an APNs key** (RC §12 p. 5) | The local stand has no APNs: `send_alert` answers `not implemented` there (`ERROR_CODE_UNSPECIFIED`). A real push needs staging with `RELAY_APNS_*` set. | Task 12 |
| **Phase 2 Task 10 / relay ask #805** (vouched hubs) | A vouched hub must still pass `send_alert`'s `requireKind(session, "mac")` at `3a99bd7` (`ops.ts`); Task 0 re-checks what kind a vouched hub's session has. | Task 12 |

Tasks 1–11 need none of them: the pusher runs against the in-process fake relay (`internal/hub/transport/relay/fakerelay_test.go`, extended) and the local stand (where the answer `not implemented` is itself an outcome under test); the alert bytes are proven against the Kit's existing `AlertOpener` by a Go-sealed fixture.

## Phone contract points (the phone must match; spec §12a "Alerts", protocol §4.8, RC §10)

1. **APNs body** (relay `apns.ts`, not ours, pinned for the phone): `{"aps":{"mutable-content":1,"alert":{"title":"Watchtower"}},"e":"<envelope>"}`, `e` = **standard** base64 with padding of the envelope bytes. The NSE replaces the placeholder title; on any failure it delivers the content-free notification unchanged (today's rule).
2. **Opening:** `AlertOpener.open(wireName: "alert-push", envelope:)` — AAD = header ‖ zone byte `data = 1` ‖ length-prefixed `"alert-push"`; class `alert` (2); signed by `hub_sig`; `sender_id == hub_id`; key = `K_alert[header.epoch]` from the shared alert group's material (current and previous epoch, as today); frame kind `ask_alert`, frame id `ask_alert-<key>`; payload `WorkAlertPayload` unchanged. No network.
3. **Identity of a notification:** `payload.key` (`ask-<id>`, `perm-<id>`, `stop-<session>-<ms>`) is the identifier and thread, as on CloudKit; the push is sent at most once per key and phone (Global Constraints), so the phone needs no dedupe of its own beyond today's.
4. **Settling:** the `ask_alert` record still lives in `data/<hub>` while the alert is open and is deleted when it resolves; the phone removes the delivered notification on that delete exactly as for a CloudKit alert. The push itself is never "recalled".
5. **Eligibility:** the hub sends only to a linked phone whose relay device id is in its `set_hub_readers` and whose `SlotHolder.paying` is true; the phone gets a push only after it called `register_push` (else the relay answers `NOT_FOUND`, which Desktop shows as "Notifications aren't set up on this iPhone"). `env` must match the phone build (sandbox for Xcode/TestFlight-development, production otherwise).
6. **CloudKit phones** keep `sig-` records and the query subscription (Phase 3 Task 15); a hub on the relay writes no signal and a hub on CloudKit calls no `send_alert`.
7. **Silent pushes** for zone changes are the relay's (`push.ts` coalesce 2 s); the hub does nothing for them.
8. **Measurements stay on each device** (RC §10): the hub's steps are read → applied → slice saved; the phone's are its own, including the end-to-end "action → result on screen" the p50 < 500 ms goal is about. Nothing is exchanged.

## Global Constraints

All Global Constraints of Plans 1a, 1b, 2 and 3 hold (byte compatibility, zone bytes, E2E red line, FILES-01, sidecar migrations as the hub's own goose provider, guard tests one-to-one, Desktop never opens `hubstate.db`, public-repo hygiene, inner loop per task). In addition:

- **Branch rule (owner, 2026-10-31):** all Go hub work branches from `feature/go-hub` and merges into it; one PR goes from `feature/go-hub` to `main` when all four phases are done. Each task branch here starts from `feature/go-hub`.
- **E2E red line for pushes:** the only bytes the hub hands `send_alert` are a `secure.Push` built by `Sealer.AlertPush`; `transport.Alerts.SendAlert` accepts no other type. No plaintext preview, title or count goes in any request field — the relay's own `"Watchtower"` placeholder is the only visible text.
- **Push size:** relay `MAX_PAYLOAD_BYTES = 4096`, body overhead 67 bytes, base64 → envelope ≤ **3021** bytes. `AlertPush` pads the frame to the **1 KiB** bucket (envelope 68 + 1024 + 16 + 64 = 1172 bytes) and, when the payload does not fit that bucket, clips `body`, then `title`, on rune boundaries with `…` until it does; `WorkAlertPayload` keys and every other field stay as they are. The data-zone `ask_alert` record is not clipped (decided by agent; Needs owner decision 2).
- **At most once per (alert key, phone):** a ledger row is written `pending` before the request and settled after; a row found `pending` at hub start is settled `expired` and never resent (decided by agent; Needs owner decision 1).
- **Freshness window** `alerts.Freshness = 5 * time.Minute` from the alert's first save: retries (`RATE_LIMITED` after `retry_after_s`, default 1 s, capped 60 s; `transport.ErrUnavailable` after the client's own 30 s, on the next connect) stop at its end with outcome `expired`.
- **Outcome classes** (ledger `outcome`, Desktop and logs): `sent | no_token | not_paying | forbidden | push_off | too_large | expired | failed`. Mapping from the relay at `3a99bd7`: `NOT_FOUND` → `no_token`; `ENTITLEMENT_INACTIVE` → `not_paying` (and one account-state refresh); `FORBIDDEN` → `forbidden`; `RECORD_TOO_LARGE` → `too_large` (a bug: logged once); `ERROR_CODE_UNSPECIFIED` with message `not implemented` → `push_off`; any other `UNSPECIFIED` → `failed`; `RATE_LIMITED`/`TRAFFIC_LIMIT_EXCEEDED` → retry; nothing else retried.
- **No hub-side rate limit** beyond the relay's (token bucket per device, `MAX_ALERTS_PER_PHONE = 4` in flight, oldest cancelled): the work-alert policy already sends one push per stop and only while the owner is away. One sender goroutine per phone; the publisher never waits on a push (buffered queue, 64 per phone; overflow → `expired`).
- **Measurements** (RC §10): sidecar table `latency_samples` holds `at`, `transport` (`cloudkit|relay`), `step` (`read_applied|applied_saved`), `ms` — nothing else; kept 7 days and at most **20 000** rows (pruned once a minute). Only actions applied on first read count (a held action measures the phone's gap, not the hub). An applied action with no slice save within 60 s leaves no `applied_saved` sample. Percentiles: nearest rank over the window. Nothing leaves the device.
- **Indicators** (RC §10): "Relay unavailable" after **60 s** without a relay connection (RC §9's phone threshold, reused); quota from the last save error class, cleared by the next successful save of that zone kind; undelivered count = held actions + 1 for an open gap (`resend_requested_from` set) as the hub knows them.
- **Desktop screens** (spec §12.4 and the workbench rule): every new or changed screen gets its mockup states in `docs/design/mockups/go-hub/index.html` (Task 1) and a `DesignShotCatalog` entry per state — **empty, loading, error with Retry, busy, narrow width** — on fixture data (`acme`, `example.com`); every UI string lives in its model and is pinned by a model test (view-source scan, as Phase 3 Task 23); colours only through `Tone`/semantic styles, `SettingsSection` + `.kitRow`, no row separators; after implementation `make desktop-shots DESKTOP_SHOTS=<dir>` is compared with the mockup and the PNGs go into the PR.
- **Pinned copy** (RC §10 mockup, verbatim where it exists): "Doesn't get updates: this Mac runs over Relay. Switch this Mac to iCloud from a subscribed phone, or subscribe on <phone>."; "<N> actions from this phone were not delivered — it shows them with Retry." (`1 action … was not delivered`); "Relay unavailable for <N> min. Phones keep their changes and send them when it is back."; "Connected · last change delivered <age> ago"; "Content-free timings kept on this Mac only."; new: "This Mac's Relay storage is full. New changes are not sent until older recordings are removed.", "A phone's Relay mailbox is full. Its updates wait until it reads them.", "Notifications aren't set up on this iPhone. Open Watchtower on it once.", "Relay has no notifications configured.", "No timings yet. They appear after the first action from a phone.", "This Mac's part alone is over the 500 ms goal."
- **Swift** follows the "Swift / Desktop conventions" of `docs/review/review-rules.md`; every Swift task runs `make lint-swift`.
- Sidecar migrations continue from the newest file on `feature/go-hub` (`00010` expected after Phase 3's `00009_switch_epochs`; re-check when the task starts).
- Inner loop only per task; the full gate (`make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`) runs once, in Task 11.

## Review Focus

1. **A payload in 4-byte characters** (emoji or CJK titles and bodies at their caps) would overflow the 4096-byte push. Expect it clipped, still opened by the Kit, the key intact. → Task 2 `TestAlertPushFitsWorstCaseRunes`.
2. **A crash between `send_alert` and the settle write.** The phone must not get the same alert twice after the restart. → Task 4 `TestPendingPushAtStartIsSettledExpiredNeverResent`.
3. **A phone that stopped paying or lost its slot since the last account read.** Expect `not_paying`/`forbidden`, one account refresh, no retry loop, and the other phones still pushed. → Task 4 `TestEntitlementInactiveStopsRetriesAndRefreshesOnce`, `TestOnePhoneRefusedOthersStillSent`.
4. **A burst of stops** (ten sessions end at once while away) against a rate-limiting relay. Publishing must never stall, retries honour `retry_after_s`, the leftovers expire after 5 min. → Task 5 `TestRateLimitedBurstNeverBlocksPublishing`.
5. **A switch to CloudKit while pushes are queued.** No `send_alert` after the switch; the queued ones settle `expired`; signals take over. → Task 5 `TestSwitchToCloudKitStopsQueuedPushes`.

---

### Task 0: Re-verify the plan against the code (blocking, no code)

**Files:** none changed unless the plan is wrong; then this plan file and/or an owner ask.

- [ ] **Step 1: Relay proto messages and error codes.** Read `internal/hub/transport/relay/VERSION` on `feature/go-hub` and, at that commit in the relay repo, `proto/relay/v1/relay.proto`, `worker/src/do/device/push.ts`, `worker/src/do/device/ops.ts` (`ERRORS`, `case "sendAlert"`, `registerPush`), `worker/src/push/apns.ts` (`MAX_PAYLOAD_BYTES`, `pushBody`). Confirm: `Request.send_alert = 18`, `SendAlert{string phone_device_id = 1; bytes envelope = 2}`, response `Ok`; `RegisterPushToken{token = 1, env = 2}`, `PushEnv` SANDBOX = 1 / PRODUCTION = 2; `AccountState.phones` of `SlotHolder{phone_device_id, paying}`; `alertSender` order forbidden → entitlement_inactive → forbidden → alert_too_large, `not_found` without a token, `not_implemented` without an APNs key; codes FORBIDDEN 3, NOT_FOUND 4, RECORD_TOO_LARGE 7, TRAFFIC_LIMIT_EXCEEDED 11, RATE_LIMITED 12 (+ `retry_after_s`), ENTITLEMENT_INACTIVE 17, UNAVAILABLE 19, UNSPECIFIED with message `not implemented`; 4096 bytes and a 67-byte body overhead; `MAX_ALERTS_PER_PHONE = 4`; `requireKind(session, "mac")` and the kind a **vouched** hub's session has (Phase 2 Task 10). **Invalidates:** a renamed or renumbered field; a result other than `Ok` (e.g. a receipt to store); a dedicated code for "no token" or "push off" (update the outcome map); a different size budget or `e` encoding (re-derive 3021 and the 1 KiB bucket); a vouched hub refused by `send_alert` (owner ask to the relay session before Task 3).
- [ ] **Step 2: Phase 3 Desktop files and `HubCenter`.** Read the merged `WatchtowerDesktop/Sources/Services/HubCenter.swift` (`status`, the watch stream's event names), `WatchtowerCore/Services/HubControlClient.swift` (`HubStatus` keys), `ViewModels/MobileSettingsModel.swift` (`State`, `PhoneRow` fields, how rows are loaded from `hub phones --json`), `Views/Settings/MobileSettingsView.swift`, the `mobileSettings*` entries in `Tests/DesignShots/DesignShotCatalog.swift`, `docs/design/mockups/go-hub/index.html`, and `cmd/hub_link.go` (`hubPhoneJSON`, `runHubStatus`), `internal/hub/status.go` (`Status`, its writer). **Invalidates:** Settings → Mobile split into other files or models (re-point Tasks 8–9); `HubCenter` without a status event on the watch stream (Task 7 adds it, plus its test); a Desktop read that does not go through `hub … --json` or the socket (stop: Phase 3's sidecar guard).
- [ ] **Step 3: The protocol's alert path.** Read protocol §4.3, §4.8, §6.2 (`ask_alert` row) at `feature/go-hub`, `internal/hub/secure/record.go` (`Sealer.Alert`, `signedSymmetric`, `Record`), `internal/hub/slices/publisher.go` (the `!published` "first reaches the zone" point and `alertSignals`), `internal/hub/slices/sources/work_alert.go` (caps 60/60/120, `quick`), Phase 3's `slices/signals.go` and `switcher.Switcher.Active()`. **Invalidates:** the relay alert amended to another wire name or zone byte; alerts no longer sealed under `K_alert`; the publisher no longer able to tell a first save of an alert (Task 5 must find another hook); a signal written on the relay.
- [ ] **Step 4: Kit and NSE decoding.** Read `WatchtowerKit/Sources/WatchtowerSync/Secure/AlertOpener.swift` (`EnvelopeContext(zone: .data, wireName:)`, `.alert` only, `frame.kind == ask_alert`, epochs from `AlertMaterial`), `WatchtowerMobile/NotifyService/NotificationService.swift`, and on the neighbour's branch the RC Phase 4 plan / code for `AlertSource.inline` (field `e`, base64 flavour, `register_push` env choice). **Invalidates:** the NSE expecting another wire name, zone byte, field or base64url (contract points 1–2 change together with the phone — owner ask); the material holding only the current epoch (a push sealed just before a rotation would not open: keep `AlertPush` on the current epoch and note it in Known limits, or ask).
- [ ] **Step 5: Sim rules.** Read the relay's `sim/README.md` at the pinned commit — rules 11, 15, 16, "Bounded state", "The Go client" — and search it for `alert`/`push`. **Invalidates:** any rule that makes alerts a mailbox record, asks the hub to dedupe or acknowledge pushes, or forbids `send_alert` in a state this plan sends in (e.g. during a switch).
- [ ] **Step 6: Phase 1–3 Go names this plan consumes.** Confirm each exists with this shape: `relay.Transport.AccountState(ctx) (*relayv1.AccountState, error)`, `Admitted()`, `MapError`, `client.Code(err)`; `transport.Kind` `KindRelay`/`KindCloudKit`; `state.Store.WithTx`, `state.OpenReadOnly`, `Store.Devices()` with `RelayDeviceID`, `Store.HeldActions(device)`, `Device.ResendRequestedFrom`; `actions.Processor.Pass` and `PassReport`; `slices.Publisher` save path; `switcher.Config.Paying`; `hub.Status`, `writeStatusRun`, `hubRuntime`; the newest sidecar migration number. **Invalidates:** a renamed type → fix the names in Tasks 3–7 before Task 1.
- [ ] **Step 7: Record the result.** Either commit `docs: Go hub phase 4 plan re-checked against <feature/go-hub sha> and relay <sha>` with the corrections, or file an owner ask listing each invalidated assumption and stop.

### Task 1: Mockups for the phase 4 Desktop states

**Files:**
- Modify: `docs/design/mockups/go-hub/index.html` (Phase 3 Task 3's page)

**Interfaces:**
- Produces: sections with the exact copy of Global Constraints "Pinned copy": Settings → Mobile hub block (Connected, Relay unavailable, hub storage full, mailbox full, Relay has no notifications configured), phone rows (subscribed, free phone on a relay hub, undelivered count, notifications not set up), each in empty / loading / error with **Retry** / busy / narrow; Settings → Mobile → Diagnostics (table step × transport × p50/p90/samples; empty "No timings yet…", loading, error with **Retry**, busy refresh, narrow; the over-goal line). Base: `docs/design/mockups/relay-client/index.html` sections 1–2 (on `feature/relay-client`).
- **Depends on:** Task 0

- [ ] **Step 1:** Add the sections; open the page locally and check light/dark and 600 px width.
- [ ] **Step 2:** The controller files the owner review of the page; Tasks 8–9 wait for it.
- [ ] **Step 3: Commit** `docs: Go hub phase 4 mockups (Mobile indicators, Diagnostics)`.

### Task 2: `Sealer.AlertPush` — the `alert-push` envelope, its size rule and the Kit check

**Files:**
- Modify: `internal/hub/secure/record.go`
- Modify: `internal/hub/secure/testdata/go-sealed.json` (new case `alertPush`), its writer `TestWriteGoSealed`
- Modify: `WatchtowerKit/Tests/WatchtowerSyncTests/GoSealedEnvelopeTests.swift`
- Test: `internal/hub/secure/alert_push_test.go`

**Interfaces:**
- Consumes: `Sealer.signedSymmetric`'s pieces (`KeySource.AlertKey`, `NextSeq`, `SealSymmetric`, `Context`).
- Produces:
  ```go
  package secure
  const AlertPushWireName = "alert-push"
  const AlertPushMaxEnvelope = 3021 // relay MAX_PAYLOAD_BYTES 4096 − 67-byte body, base64
  // Push is a sealed alert for send_alert; only AlertPush builds one (zero value: Sealed() false).
  type Push struct{ envelope []byte; key string; sealed bool }
  func (p Push) Envelope() []byte; func (p Push) Key() string /* the alert key, ids only */; func (p Push) Sealed() bool
  // AlertPush seals ask_alert-<key> as class alert under K_alert[current], signed, AAD wire name "alert-push"
  // in the data zone, frame padded to the 1 KiB bucket after clipping body then title (rune-safe, "…").
  func (s *Sealer) AlertPush(key string, payload WorkAlertFields) (Push, error)
  type WorkAlertFields struct{ Event, Key string; WorkbenchID int64; WorkbenchName string; SessionID, AskID, RequestID *int64; Title, Body string; Quick bool } // marshals to the Kit's WorkAlertPayload keys
  var ErrAlertTooLarge = errors.New("secure: alert does not fit a push")
  ```
  The source's `workAlertPayload` struct in `slices/sources/work_alert.go` is replaced by `secure.WorkAlertFields` (one type, one JSON shape for the record and the push).
- **Depends on:** Task 0

- [ ] **Step 1: Failing tests** in `alert_push_test.go`: `TestAlertPushOpensUnderTheFixedWireName` (an `Opener`-side helper opens it with `Context{Zone: ZoneData, WireName: "alert-push"}`; class 2; `sender_id == hub_id`; frame kind `ask_alert`, id `ask_alert-ask-42`); `TestAlertPushDoesNotOpenUnderTheRecordWireName` (AAD binding); `TestAlertPushFitsWorstCaseRunes` (workbench name 60 × `😀`, title 123 × `😀`, body 120 × `😀` → `len(Envelope()) ≤ 3021`, payload decodes, `key` unchanged, body ends with `…`); `TestAlertPushKeepsShortTextAsIs` (ASCII at the caps: no clipping, 1172-byte envelope); `TestAlertPushPayloadKeysMatchTheKit` (JSON keys equal `WorkAlertPayload.CodingKeys`); `TestZeroPushIsNotSealed`.
- [ ] **Step 2:** `go test ./internal/hub/secure -run AlertPush` → FAIL.
- [ ] **Step 3: Implement** `AlertPush`; clip loop: marshal, measure padded frame, drop one rune from `Body` (then `Title`) until the frame fits 1024 bytes; return `ErrAlertTooLarge` if even empty texts do not fit.
- [ ] **Step 4:** `go test ./internal/hub/secure` → PASS; regenerate `go-sealed.json` (`go test ./internal/hub/secure -run TestWriteGoSealed -update`), adding case `alertPush` with the hub signing key and alert key it was sealed with.
- [ ] **Step 5: Kit test** `testGoSealedAlertPushOpensWithAlertOpener` in `GoSealedEnvelopeTests.swift`: `AlertOpener(material:).open(wireName: "alert-push", envelope:)` returns the fixture's payload; `open(wireName: <the record wire name>, …)` returns nil. `make kit-test FILTER=GoSealedEnvelopeTests` → PASS; `make lint-swift`; `make lint-diff`.
- [ ] **Step 6: Commit** `hub/secure: alert-push envelope for relay pushes, pinned by the Kit's AlertOpener`.

### Task 3: `send_alert` on the relay transport

**Files:**
- Modify: `internal/hub/transport/transport.go` (capability), `internal/hub/transport/relay/transport.go`, `internal/hub/transport/relay/errors.go`, `internal/hub/transport/relay/fakerelay_test.go` (send_alert with scripted answers)
- Test: `internal/hub/transport/relay/alerts_test.go`

**Interfaces:**
- Consumes: Task 2 `secure.Push`; `client.Code`, `MapError`.
- Produces:
  ```go
  package transport
  // Alerts is the optional capability of a transport that pushes alerts itself (the hosted relay).
  type Alerts interface{ SendAlert(ctx context.Context, phoneRelayID string, p secure.Push) error }
  var ErrNoPushToken = errors.New("transport: phone has no push token")   // NOT_FOUND on send_alert
  var ErrPushOff     = errors.New("transport: relay pushes are off")       // UNSPECIFIED "not implemented"
  package relay
  func (t *Transport) SendAlert(ctx context.Context, phoneRelayID string, p secure.Push) error // refuses !p.Sealed() with ErrUnsealed before I/O
  func RetryAfter(err error) time.Duration // Error.retry_after_s, 0 when absent
  ```
  Error mapping on this op only: `NOT_FOUND` → `ErrNoPushToken`; `UNSPECIFIED` with message `not implemented` → `ErrPushOff`; the rest through `MapError` (`ErrForbidden`, `ErrEntitlementInactive`, `ErrRecordTooLarge`, `ErrRateLimited`, `ErrUnavailable`).
- **Depends on:** Task 2

- [ ] **Step 1: Failing tests:** `TestSendAlertSendsTheEnvelopeOnly` (the fake captures `SendAlert{phone_device_id, envelope}` = the Push bytes; no other field set), `TestSendAlertRefusesAnUnsealedPush` (no request made), a table `TestSendAlertErrorMapping` (each relay answer above → its error, `RetryAfter` 7 s for `RATE_LIMITED` with `retry_after_s: 7`), `TestCloudKitTransportHasNoAlerts` (`memfake` and Phase 3's `cloudkit` do not implement `transport.Alerts`).
- [ ] **Step 2:** `go test ./internal/hub/transport/...` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `hub/transport: send_alert on the hosted relay`.

### Task 4: The pusher — eligibility, ledger, retries, outcomes

**Files:**
- Create: `internal/hub/state/migrations/00010_alert_pushes.sql`, `internal/hub/state/alertpushes.go`
- Create: `internal/hub/alerts/pusher.go`
- Test: `internal/hub/alerts/pusher_test.go`, `internal/hub/state/alertpushes_test.go`

**Interfaces:**
- Consumes: Task 3 `transport.Alerts`, errors, `relay.RetryAfter`; Task 2 `Sealer.AlertPush`; `state.Store.Devices()`; the relay account state (`SlotHolder`).
- Produces:
  ```go
  package state
  // 00010: CREATE TABLE alert_pushes(alert_key TEXT NOT NULL, device_id TEXT NOT NULL,
  //   outcome TEXT NOT NULL CHECK (outcome IN ('pending','sent','no_token','not_paying','forbidden','push_off','too_large','expired','failed')),
  //   attempts INTEGER NOT NULL DEFAULT 0, first_at REAL NOT NULL, settled_at REAL, PRIMARY KEY (alert_key, device_id))
  // ids, counters, timestamps and a class only (allowlist: alert_key = key, outcome = enum).
  func (s *Store) BeginAlertPush(key, device string, at time.Time) (bool, error) // false: a row exists (never twice)
  func (s *Store) SettleAlertPush(key, device, outcome string, attempts int, at time.Time) error
  func (s *Store) ExpirePendingAlertPushes(at time.Time) (int, error)            // at hub start
  func (s *Store) LastAlertOutcomes(since time.Time) (map[string]string, error)  // device → newest settled outcome
  func (s *Store) PruneAlertPushes(before time.Time) error                       // 7 days, with the alert lifetime
  package alerts
  const Freshness = 5 * time.Minute; const QueuePerPhone = 64
  type Target struct{ DeviceID, RelayID string }
  type Config struct {
      Store *state.Store; Sealer *secure.Sealer; Send transport.Alerts
      Targets func(ctx context.Context) ([]Target, error) // linked, relay id set, a hub reader, SlotHolder.paying
      RefreshAccount func(ctx context.Context)            // called once on not_paying / forbidden
      Clock func() time.Time
  }
  type Pusher struct{…}; func New(c Config) *Pusher
  func (p *Pusher) Start(ctx context.Context) error // ExpirePendingAlertPushes, then per-phone senders
  func (p *Pusher) Enqueue(key string, fields secure.WorkAlertFields, savedAt time.Time) // never blocks
  func (p *Pusher) Stop()                                                              // queued items settle expired
  ```
- **Depends on:** Task 3

- [ ] **Step 1: Failing tests** (fake `transport.Alerts` with scripted answers, fake clock): `TestPushedOncePerKeyAndPhone` (two `Enqueue` of one key → one request per phone), `TestOnlyPayingReadersAreTargets`, `TestPendingPushAtStartIsSettledExpiredNeverResent` (Review Focus 2), `TestRateLimitedRetriesAfterRetryAfterWithinFreshness` (7 s answer → retry at 7 s; a key still failing at 5 min → `expired`), `TestEntitlementInactiveStopsRetriesAndRefreshesOnce` and `TestOnePhoneRefusedOthersStillSent` (Review Focus 3), `TestOutcomeClasses` (table: each error → its outcome), `TestQueueOverflowSettlesExpired`, `TestStopSettlesQueuedExpired`, `TestFILES01_PusherLogsIdsAndClassesOnly` (`logcanary` marker in title/body never in logs), `TestAlertPushLedgerHasNoContent` (canary: the sidecar file never contains the marker), state: `TestBeginAlertPushRefusesASecondRow`, `TestSidecarHasNoNewUnsealedContentColumns` (allowlist updated).
- [ ] **Step 2:** `go test ./internal/hub/alerts ./internal/hub/state` → FAIL.
- [ ] **Step 3: Implement.** The payload stays in memory only, in the queue item; `BeginAlertPush` in its own short transaction before the request, `SettleAlertPush` after; no request inside a write transaction.
- [ ] **Step 4:** → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `hub/alerts: push work alerts to paying phones over send_alert, at most once`.

### Task 5: Wire the pusher into the publisher and the runtime

**Files:**
- Modify: `internal/hub/slices/publisher.go` (hook on a new alert's first save, transport-aware), `internal/hub/runtime.go` (build/start/stop the pusher with the relay transport; targets from the account state and devices; prune), `internal/hub/wiring.go`
- Test: `internal/hub/slices/alert_push_test.go`, `internal/hub/alerts_wiring_test.go`, `internal/hub/interop_test.go` (local stand case)

**Interfaces:**
- Consumes: Task 4 `alerts.Pusher`; Phase 3 `switcher.Switcher.Active()`, `switcher.Config.Paying`; `relay.Transport.AccountState`.
- Produces:
  ```go
  package slices
  // Config gains: OnAlertSaved func(key string, fields secure.WorkAlertFields, savedAt time.Time)
  // called once per alert key after its first successful save, only while the active transport is the relay;
  // on CloudKit the signal path (Phase 3) runs instead. Republishes and rotations never call it.
  ```
- **Depends on:** Task 4

- [ ] **Step 1: Failing tests:** `TestFirstSaveOfAnAlertEnqueuesAPushOnRelay`, `TestRepublishAndRotationNeverPushAgain`, `TestNoSendAlertOnCloudKit` (and no signal on the relay, Phase 3's test stays green), `TestSwitchToCloudKitStopsQueuedPushes` (Review Focus 5), `TestRateLimitedBurstNeverBlocksPublishing` (Review Focus 4: ten alerts, relay answers `RATE_LIMITED` 30 s; the next slice save still happens within the 150 ms spacing), `TestAccountRefreshUpdatesTargets` (a phone becomes paying after a `Control` → the next alert reaches it), `TestE2ECanary_AlertPushCarriesNoPlaintext` (canary markers in workbench name/title/body; the fake relay's captured `send_alert` frames contain none; the envelope opens with the alert key to the marker), interop (`make relay-interop RELAY=../relay`): `TestInterop_SendAlertOnTheLocalStandIsPushOff` (outcome `push_off`, no retry).
- [ ] **Step 2:** `go test ./internal/hub/... -run 'Alert|Push|SendAlert'` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** → PASS; `make relay-interop RELAY=../relay` once; `make lint-diff`.
- [ ] **Step 5: Commit** `hub: push new work alerts over the relay from the publisher`.

### Task 6: Hub-side latency samples

**Files:**
- Create: `internal/hub/state/migrations/00011_latency_samples.sql`, `internal/hub/state/latency.go`, `internal/hub/measure/measure.go`
- Modify: `internal/hub/actions/processor.go` (stamps), `internal/hub/slices/publisher.go` (save stamps), `internal/hub/runtime.go` (recorder, prune ticker)
- Test: `internal/hub/measure/measure_test.go`, `internal/hub/state/latency_test.go`, `internal/hub/actions/processor_test.go` (stamp cases)

**Interfaces:**
- Consumes: `actions.Processor.Pass`, the nudge's action-kind → slice-kind table (Plan 1b), `slices.Publisher` save path, active transport kind.
- Produces:
  ```go
  package state
  // 00011: CREATE TABLE latency_samples(at REAL NOT NULL, transport TEXT NOT NULL CHECK (transport IN ('cloudkit','relay')),
  //   step TEXT NOT NULL CHECK (step IN ('read_applied','applied_saved')), ms INTEGER NOT NULL CHECK (ms >= 0));
  //   CREATE INDEX latency_samples_at ON latency_samples(at)
  type LatencyRow struct{ Step, Transport string; P50, P90 time.Duration; Samples int }
  func (s *Store) AddLatencySamples(xs []LatencySample) error
  func (s *Store) LatencyStats(since time.Time) ([]LatencyRow, error) // nearest rank, sorted step, transport
  func (s *Store) PruneLatency(before time.Time, keep int) error       // 7 days, 20 000 rows
  package measure
  const Window = 7 * 24 * time.Hour; const MaxRows = 20000; const SaveWait = 60 * time.Second
  type Recorder struct{…}; func New(store *state.Store, clock func() time.Time) *Recorder
  func (r *Recorder) Applied(transport string, readAt, appliedAt time.Time, kinds []string) // first-read applies only
  func (r *Recorder) Saved(transport string, kind string, startedAt, doneAt time.Time)    // resolves waiting applies of kind
  func (r *Recorder) Flush() error                                                         // batched write, once a second
  ```
  `readAt` = when the transport handed the processor the record's batch. A waiting apply resolves at the first successful save of one of its kinds whose cycle started after `appliedAt`; none within `SaveWait` → no sample. Waiting applies are in memory, capped at 256 (oldest dropped).
- **Depends on:** Task 0

- [ ] **Step 1: Failing tests:** `TestAppliedActionGivesReadAppliedSample`, `TestHeldThenAppliedGivesNoSample`, `TestRepeatGivesNoSample`, `TestSliceSaveResolvesAppliedSaved` (an `ask_answer` → `owner_ask` save), `TestNoSaveWithin60sGivesNoSample`, `TestSamplesTaggedWithTheActiveTransport`, `TestLatencyStatsNearestRank` (table of known ms → p50/p90), `TestLatencySamplesAreContentFreeAndBoundedPrune` (20 001 rows → 20 000; 8-day-old row gone; column allowlist: `at`, `transport`, `step`, `ms`), `TestRecorderNeverWritesInsideAPassTransaction`.
- [ ] **Step 2:** `go test ./internal/hub/measure ./internal/hub/state ./internal/hub/actions -run 'Latency|Sample|Recorder'` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `hub: content-free latency samples (read → applied → slice saved)`.

### Task 7: Indicators in `hub status`, `hub phones`, and `hub diagnostics`

**Files:**
- Modify: `internal/hub/status.go`, `internal/hub/runtime.go` (relay health, quota class, last save, paying phones into the status file; a `status` event on `desktop_watch` at each rewrite), `cmd/hub_link.go` (`hubPhoneJSON` keys), `cmd/hub.go` (new verb)
- Create: `cmd/hub_diagnostics.go`
- Test: `internal/hub/status_test.go`, `cmd/hub_test.go`

**Interfaces:**
- Consumes: Task 4 `LastAlertOutcomes`; Task 6 `LatencyStats`; `Store.HeldActions`, `Device.ResendRequestedFrom`; the relay transport's connection events and save errors.
- Produces (pinned `--json` keys, additive):
  ```go
  // hub.Status gains:
  Relay        *RelayHealth `json:"relay,omitempty"`        // absent when the hub has no relay origin
  PayingPhones []string     `json:"paying_phones"`          // device ids; empty unless the active transport is the relay
  type RelayHealth struct {
      State string `json:"state"` // "connected" | "unavailable" (no connection for ≥ 60 s) | "connecting"
      Since string `json:"since"` // RFC 3339, when State began
      Quota string `json:"quota"` // "" | "hub" | "mailbox"
      LastSavedAt string `json:"last_saved_at"` // RFC 3339 or ""
  }
  // hub phones --json rows gain: "paying" (true|false|null — null unless the hub runs on the relay),
  //   "undelivered" (int), "alerts" ("" | an outcome class of the last 7 days)
  // hub diagnostics [--days N] --json → {"window_days":7,"rows":[{"step","transport","p50_ms","p90_ms","samples"}]}
  //   reads the sidecar through state.OpenReadOnly (no hub needed); --days 1..7
  ```
- **Depends on:** Task 4, Task 6

- [ ] **Step 1: Failing tests:** `TestRelayUnavailableAfter60s` (59 s → `connecting`, 60 s → `unavailable`, reconnect → `connected` and a `status` watch event), `TestQuotaClassSetAndClearedBySave`, `TestPayingPhonesOnlyOnRelay`, `TestHubStatusJSONKeys` (updated pinned set), `TestHubPhonesJSONKeys` (`paying`, `undelivered`, `alerts`), `TestUndeliveredCountsHeldAndGap`, `TestHubDiagnosticsJSONKeys`, `TestHubDiagnosticsWithoutSidecarIsEmpty`, `TestStatusFileHasNoContent` (canary).
- [ ] **Step 2:** `go test ./internal/hub ./cmd -run 'TestHub|TestRelayUnavailable|TestQuota|TestPaying|TestUndelivered|TestStatus'` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `hub: relay health, paying phones, undelivered and alert outcomes; hub diagnostics`.

### Task 8: Settings → Mobile indicators (Desktop)

**Files:**
- Modify: `WatchtowerDesktop/Sources/ViewModels/MobileSettingsModel.swift`, `WatchtowerDesktop/Sources/Views/Settings/MobileSettingsView.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/HubControlClient.swift` (`HubStatus` keys)
- Modify: `WatchtowerDesktop/Tests/DesignShots/DesignShotCatalog.swift`
- Test: `WatchtowerDesktop/Tests/ViewModels/MobileSettingsModelTests.swift`, `WatchtowerDesktop/Tests/Core/HubControlClientTests.swift`

**Interfaces:**
- Consumes: Task 7 keys; Phase 3 `HubCenter.status`, `MobileSettingsModel`, `PhoneRow`.
- Produces:
  ```swift
  // HubStatus gains: relay: RelayHealth?; payingPhones: [String]
  struct RelayHealth: Decodable, Equatable { let state: String; let since: Date; let quota: String; let lastSavedAt: Date? }
  // MobileSettingsModel.PhoneRow gains:
  let updatesLine: String?      // free phone on a relay hub: the pinned "Doesn't get updates…" text with the phone's name
  let undeliveredLine: String?  // N > 0: pinned singular/plural text
  let alertsLine: String?       // "no_token" → "Notifications aren't set up on this iPhone. Open Watchtower on it once."
  // MobileSettingsModel gains:
  var relayLine: (text: String, tone: Tone)? // connected (age), unavailable (minutes), "push_off" → "Relay has no notifications configured."
  var quotaLine: String?                      // hub / mailbox pinned texts
  ```
- **Depends on:** Task 1 (mockup approved), Task 7

- [ ] **Step 1: DesignShots** (light/dark): `mobileSettingsRelayConnected`, `mobileSettingsRelayUnavailable`, `mobileSettingsQuotaFull`, `mobileSettingsFreePhoneOnRelay`, `mobileSettingsUndelivered`, `mobileSettingsNotificationsMissing`, each also narrow; the existing empty/loading/error/busy shots updated with the hub block.
- [ ] **Step 2: Failing tests:** `testDecodesRelayHealthAndPayingPhones`, `testFreePhoneOnRelayLine` (`paying: false` on a relay hub → the line naming the phone; on CloudKit → none), `testUndeliveredSingularPlural` (1, 3), `testNoTokenLine`, `testRelayUnavailableMinutes` (since 2 min 30 s → "2 min"), `testQuotaLines`, `testPushOffLineWhenAllPhonesPushOff`, `testWatchStatusEventRefreshesLines`, `testEveryUIStringLivesInTheModel`.
- [ ] **Step 3:** `make test-swift FILTER='MobileSettingsModelTests|HubControlClientTests'` → FAIL.
- [ ] **Step 4: Implement.**
- [ ] **Step 5:** → PASS; `make desktop-shots DESKTOP_SHOTS=<dir>` compared with Task 1's page; `make lint-swift`.
- [ ] **Step 6: Commit** `desktop: Settings → Mobile shows Relay health, free phones, undelivered actions and notifications`.

### Task 9: Settings → Mobile → Diagnostics (Desktop)

**Files:**
- Create: `WatchtowerDesktop/Sources/ViewModels/MobileDiagnosticsModel.swift`, `WatchtowerDesktop/Sources/Views/Settings/MobileDiagnosticsView.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Settings/MobileSettingsView.swift` (a **Diagnostics** row opening the view), `DesignShotCatalog.swift`
- Test: `WatchtowerDesktop/Tests/ViewModels/MobileDiagnosticsModelTests.swift`

**Interfaces:**
- Consumes: Task 7 `watchtower hub diagnostics --days 7 --json` (through the app's existing CLI runner).
- Produces:
  ```swift
  @MainActor @Observable final class MobileDiagnosticsModel {
      enum State: Equatable { case loading, empty, rows([Row]), error(String) }
      struct Row: Equatable, Identifiable { let stepLabel: String /* "Phone action read → applied" | "Applied → slice saved" */; let transportLabel: String /* "Relay" | "iCloud" */; let p50: String; let p90: String; let samples: String }
      var isRefreshing: Bool
      var overGoalLine: String? // relay p50(read_applied) + p50(applied_saved) ≥ 500 ms → "This Mac's part alone is over the 500 ms goal."
      static let caption = "Content-free timings kept on this Mac only."
      static let emptyText = "No timings yet. They appear after the first action from a phone."
      func load() async; func retry() async
  }
  ```
  Durations format: < 1 s as "38 ms", else "2.1 s".
- **Depends on:** Task 1 (mockup approved), Task 7

- [ ] **Step 1: DesignShots** (light/dark): `mobileDiagnosticsRows` (relay and iCloud rows), `mobileDiagnosticsEmpty`, `mobileDiagnosticsLoading`, `mobileDiagnosticsError` (with **Retry**), `mobileDiagnosticsBusy` (refresh in flight over rows), `mobileDiagnosticsNarrow`, `mobileDiagnosticsOverGoal`.
- [ ] **Step 2: Failing tests:** `testRowsFromPinnedJSON`, `testDurationFormatting`, `testEmptyWhenNoRows`, `testErrorThenRetryLoads`, `testOverGoalLineOnlyOnRelay`, `testEveryUIStringLivesInTheModel`.
- [ ] **Step 3:** `make test-swift FILTER=MobileDiagnosticsModelTests` → FAIL.
- [ ] **Step 4: Implement.**
- [ ] **Step 5:** → PASS; desktop shots vs the mockup; `make lint-swift`.
- [ ] **Step 6: Commit** `desktop: Settings → Mobile → Diagnostics (hub latency, on this Mac only)`.

### Task 10: `mobile-companion.md` rewritten for the Go hub, `go-hub.md`, CLAUDE.md, the guide

**Files:**
- Modify (rewrite): `docs/features/mobile-companion.md`
- Modify: `docs/features/go-hub.md` (Phase 1b Task 17's note), `CLAUDE.md` (the Mobile companion bullet), `docs/superpowers/specs/2026-10-31-hub-phone-protocol-design.md` §4.8 ("Proposed, not built" → the hub half built; §11 item 5 status)
- Modify (guide): `docs/guide/features/iphone-alerts.md` (alerts over Relay arrive by push, need the subscription and Watchtower opened once on the phone; nothing readable in the push), `docs/guide/features/iphone.md` (Mac side: transport per phone, the indicator lines, Diagnostics), `docs/guide/troubleshooting/iphone-not-syncing.md` (Relay unavailable, storage or mailbox full, a free phone on a relay Mac, notifications not set up), `docs/guide/concepts/privacy.md` (a push carries only a sealed envelope; timings stay on the Mac), `docs/guide/reference/cli.md` (`hub diagnostics`)
- Test: `go test ./docs/guide` (8 KB section cap, Learn cards)

**Interfaces:**
- Consumes: every Produces block of Phases 1–4 (names only).
- Produces: `mobile-companion.md` restructured as **Architecture** (the Go hub in the daemon, transports, the bridge on a desktop host, headless hosts) · **End-to-end encryption** (kept, plus `alert-push` and the choke points) · **Hub** (Go packages, sidecar ownership and migrations, linking, slices and cadence per transport, actions and order, switch and epochs, recordings, work alerts and pushes, measurements, `hub …` CLI with pinned keys, Desktop over the hub) · **Kit** and **Phone app** (kept; the phone's Phase 4 parts named as the neighbour's, with the contract points above) · **Building and testing** (Go, Kit, interop, vectors). Every Swift-hub statement (`MobileHubService`, `SlicePublisher`, `RelayProcessor`, `MobileHubCommandDispatcher`, `MobileLinkCenter`, 30 s/10 s ticks) is removed or moved into a one-paragraph "History: the Swift hub (until <release>)". The Learn card `iphone-alerts-relay` (`since: next`, area `iphone`) under the new alerts section, per `docs/guide/WRITING.md`.
- **Depends on:** Tasks 5, 7, 8, 9

- [ ] **Step 1:** Rewrite the note from the merged code (grep each name before writing it; no real ids, emails or paths).
- [ ] **Step 2:** Guide edits per `docs/guide/WRITING.md`; `go test ./docs/guide` → PASS.
- [ ] **Step 3:** `grep -rn "MobileHubService\|SlicePublisher\|RelayProcessor" docs/features/mobile-companion.md CLAUDE.md` returns only the History paragraph.
- [ ] **Step 4: Commit** `docs: mobile-companion note for the Go hub; guide pages for pushes, indicators and diagnostics`.

### Task 11: Phase 4 gate

**Files:** none (results go into the PR description, measurements without ids).

- **Depends on:** Tasks 1–10

- [ ] **Step 1: Full gate:** `make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`, `make relay-interop RELAY=../relay` → all PASS.
- [ ] **Step 2: Manual, real Mac + local stand:** Settings → Mobile on a relay hub shows Connected, then "Relay unavailable for 1 min" after stopping the stand ≥ 60 s, back to Connected on restart; a scripted `hubtest.Phone` action burst fills Diagnostics; `hub diagnostics --json` agrees with the screen; an away-time work alert gives one `alert_pushes` row `push_off` and no retry in `watchtower.log` (ids and classes only).
- [ ] **Step 3: Measurement:** 200 scripted actions from a `hubtest.Phone` over the local stand on the same Mac: the hub's relay p50 `read_applied` + `applied_saved` written into the PR. Over 500 ms → stop and file an owner ask (the phone end-to-end goal cannot be met with this hub share).
- [ ] **Step 4:** Security review of the phase diff: `secure.Push` the only `send_alert` input, no payload in the ledger, logs, status file or samples.

### Task 12: Pushes end to end with a real phone — **blocked on relay client spec Phase 4, relay staging with APNs, vouched-hub `send_alert`**

**Files:** none unless a defect is found.

- **Depends on:** Task 11; the External dependencies table.

- [ ] **Step 1:** Phone build with `register_push` and the inline NSE, linked to a Mac hub on staging. Owner away (screen locked): an ask → one notification with the decrypted title and body within seconds; tap opens the ask; answering it removes the notification (record delete). Same for a permission request and a stopped session.
- [ ] **Step 2:** A phone that never opened the new build → Desktop shows "Notifications aren't set up on this iPhone…"; after opening it once, the next alert arrives.
- [ ] **Step 3:** Subscription lapsed on the phone → `not_paying`, no push, the free-phone line on Desktop.
- [ ] **Step 4:** Diagnostics on both sides after a day of use; the phone's end-to-end p50 on a good network < 500 ms (RC §1), recorded in the PR without ids.

## Needs owner decision

1. **At-most-once pushes.** A push left `pending` by a crash is settled `expired` and never resent, so a crash at the wrong moment loses that one notification (the alert record still reaches the phone's replica). The alternative, at-least-once, could show the same alert twice. Decided by agent: at most once.
2. **Clipping for the push only.** An alert whose text would push the envelope past the 4096-byte APNs limit has its body, then its title, shortened with "…" in the **push**; the `ask_alert` record in the data zone keeps the full capped text. Decided by agent.
3. **5-minute freshness window.** A push not delivered within 5 minutes of the alert's first save (rate limit, relay outage) is dropped as `expired`, never sent late. Decided by agent.
4. **Indicators beyond the RC §10 list:** "Notifications aren't set up on this iPhone. Open Watchtower on it once." (from `NOT_FOUND`), "Relay has no notifications configured." (from `not implemented`), and the Diagnostics line "This Mac's part alone is over the 500 ms goal." Decided by agent; each can be dropped without touching the hub.
5. **What a sample counts.** Only actions applied on first read, 7 days, at most 20 000 rows, no sample when no slice was saved within 60 s. Decided by agent (RC §10 fixes only "content-free, on the device, p50/p90 per transport").
6. **Protocol status text.** §4.8's relay paragraph and §11 item 5 move from "Proposed, not built" to "hub half built (phase 4)"; no wire change. Needs only the owner's acknowledgement.

No inventory contract changes: no `docs/inventory/` entry covers `ask_alert`, pushes or the hub's diagnostics; PROJ-16/21 and FEED-* are untouched.

## Known limits

- The local stand has no APNs: CI and local runs see only `push_off`. Real pushes are checked once, in Task 12.
- A free phone linked to a Mac that runs over Relay gets no updates and no alerts until it subscribes or the Mac switches back (RC §8), as Desktop now says.
- Push timing on the phone (APNs delivery) is not measured by the hub; it is part of the phone's end-to-end sample.
- An alert sealed in an epoch the phone's alert material no longer holds (more than one rotation since) does not open; the NSE shows the generic notification, as on CloudKit today.

## Self-review (done while writing)

- **Spec coverage, §14 row 4:** `send_alert` per paying phone — Tasks 2–5; sealed `ask_alert` under `alert-push` — Task 2 (+ Kit fixture); entitlement rules — Task 4 targets, `not_paying`; rate limits and errors — Global Constraints, Tasks 3–5; Desktop indicators (RC §10: transport per phone from Phase 3, free phone, who switched from Phase 3, Relay unavailable, quota, undelivered) — Tasks 7–8; Diagnostics and samples (RC §10) — Tasks 6, 7, 9; p50 < 500 ms — Task 11 Step 3 (hub share), Task 12 Step 4 (end to end); mobile-companion rewrite and guide (RC §14) — Task 10; mockups (§12.4) — Task 1; §13 canaries — Tasks 4, 5, 7.
- **Types across tasks:** `secure.Push`/`AlertPush`/`WorkAlertFields` Task 2 → 3, 4, 5; `transport.Alerts`/`ErrNoPushToken`/`ErrPushOff` Task 3 → 4; `alerts.Pusher`/`Enqueue` Task 4 → 5; `slices.Config.OnAlertSaved` Task 5; `measure.Recorder` Task 6 → 7 (stats via `state.LatencyStats`); `hub.Status.Relay`/`PayingPhones`, phones `paying|undelivered|alerts`, `hub diagnostics` Task 7 → 8, 9.
- **Dependency waves:** Wave 0: Task 0. Wave 1: Tasks 1, 2, 6. Wave 2: Task 3. Wave 3: Task 4. Wave 4: Tasks 5, 7. Wave 5: Tasks 8, 9 (after the Task 1 review). Wave 6: Task 10, then 11. External, last: Task 12.
