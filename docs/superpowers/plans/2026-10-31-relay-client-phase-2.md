# Relay client Phase 2 — proto, client with App Attest, transport, fake relay and sim twins Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Kit everything the phone needs to talk to the hosted relay, without wiring it into the app yet: the relay's `relay.proto` with generated Swift pinned to a relay commit, `HostedRelayClient` (HTTPS ops, WebSocket, login with the phone's App Attest), `HostedRelayTransport` (the phone-role `CloudSyncTransport` + `ConditionalTransport` + `LiveTransport` over the relay), `FakeHostedRelay` so public CI never needs the relay repository, Swift twins of the relay's Go client tests and sim scenarios, and a local-only interop run against the relay's stand. No phone or Desktop production code changes; Phase 3 wires identity, linking and the transport into the app.

**Architecture:** Three new Kit targets beside `WatchtowerSync`: `WatchtowerRelayProto` (the copied `relay.proto`, the `protoc-gen-swift` output, `VERSION`), `WatchtowerHostedRelay` (identity messages, App Attest seam, client, connection, transport) and `WatchtowerHostedRelayTesting` (fake App Attest, manual clock, `FakeHostedRelay`; linked by test targets only). `WatchtowerSync` gains only the transport-neutral `ConditionalTransport` seam and `CloudRecord.recordSeq`, and stays free of protobuf, so the Desktop links nothing new (its hub side is the Go hub's, ask #802). The client talks to the network through two seams (`RelayHTTP`, `RelaySocketDialer`) and one clock (`RelayClock`); production uses `URLSession`, tests use `FakeHostedRelay` or scripted stubs. The transport buffers server changes into the existing `TransportStore`, so consumers keep today's local change tokens, compaction and asset stash. Behaviour mirrors the Go client copy the Go hub already runs (`internal/hub/transport/relay`, same relay commit).

**Tech Stack:** Swift 5.10 language mode, Swift concurrency (actors), CryptoKit (Ed25519, SHA-256), DeviceCheck (`DCAppAttestService`), Foundation `URLSession` (HTTPS, `URLSessionWebSocketTask`), `apple/swift-protobuf` (new, pinned exactly), GRDB (via `TransportStore`), XCTest; `buf` + `protoc-gen-swift` for regeneration (developer machine only); Go for the auth vector generator; Node/`wrangler` for the local stand (developer machine only).

**Spec:** `docs/superpowers/specs/2026-10-29-relay-client-design.md` — §3 (seam, optional protocols), §4 (identity, App Attest, amended 2026-10-31), §7 (hosted relay transport), §11 (testing), §12 (relay repository), §13 row 2 (board #1239, #1240), §14 (docs). Contract: relay `main` at `3a99bd72758687e1393c3ab036484ac03cee98b1` (below "relay@3a99bd7") — `proto/relay/v1/relay.proto`, `proto/README.md` (incl. "Attestation (App Attest)"), `sim/README.md`, `client/client.go`, `client/ws.go`, `worker/README.md` "Local stand". Go parity: `internal/hub/transport/relay` (copy pinned to the same commit, `VERSION`), `scripts/relay-go.sh`.

## Global Constraints

- **Kit only.** Production code changes land in `WatchtowerKit/` (three new targets, plus Task 2's `WatchtowerSync` seam), one Go test file and its fixture, one script, the `Makefile`, docs. No file under `WatchtowerMobile/Sources`, `WatchtowerMobile/NotifyService` or `WatchtowerDesktop/Sources` changes. A `Package.resolved` change produced by the new dependency is committed with the task that causes it.
- **No behaviour change on CloudKit.** `CloudSyncTransport` keeps its three requirements; new surface is optional protocols only (spec Decisions, ask #799). `CloudKitTransport`, `InMemoryCloudTransport` and the phone's test transports conform to nothing new. Every existing Kit, Desktop and phone test keeps its assertions.
- **Inventory guards untouched** (PROJ-16, PROJ-21): `git diff --stat origin/main --` `WatchtowerDesktop/Tests/MobileHub/SessionInputHandlersTests.swift WatchtowerDesktop/Tests/MobileHub/PermissionAnswerHandlersTests.swift WatchtowerDesktop/Tests/MobileHub/PermissionRequestSliceTests.swift WatchtowerKit/Tests/WatchtowerSyncTests/PermissionAllowRuleTests.swift WatchtowerMobile/Tests/PermissionCardTests.swift WatchtowerMobile/Tests/SessionInputWiringTests.swift` prints nothing at the end of every task.
- **`WatchtowerSync` never imports `SwiftProtobuf`, `WatchtowerRelayProto` or `DeviceCheck`.** Task 1 adds `SeamBoundaryTests.testOnlyTheHostedRelayTargetsImportProtobuf`.
- **Go parity.** Where the Go client or the Go hub's relay transport has a test, the Swift twin has the same name with a lower-case `test` prefix (`TestRetryOnUnavailable` → `testRetryOnUnavailable`, `TestRelayTransport_SaveConditionalOutcomes` → `testSaveConditionalOutcomes`), and the numbers are the Go client's: backoff 500 ms doubling to 60 s, jitter in the upper half of the window; `UNAVAILABLE` retry 0.5 s doubling to 8 s within 30 s; ping every 30 s, pong within 10 s; 1–3 s after 1001; event buffer 256.
- **Secrets.** Session tokens, `relay_auth` private keys, App Attest key ids, envelopes and attestation bytes are never logged, never written to disk by the Kit in Phase 2 (key storage is Phase 3), never put in an error's `description`. Logs (`os.Logger`, category `HostedRelay`) carry op names, error codes, zone kinds and counts only.
- **No network in public CI.** Unit tests build the client on `FakeHostedRelay` or scripted stubs; `URLSessionRelayHTTP` and `URLSessionRelaySocketDialer` are constructed only by production code (none in Phase 2) and by the interop tests, which skip unless `WATCHTOWER_RELAY_INTEROP_URL` is set.
- **Public repo.** Fixtures use `https://relay.example.com`, `http://127.0.0.1:8787`, `acme`, fixed test seeds; no real device ids, account ids, tokens or local paths. Generated code and copied proto carry only the relay's public module path.
- **Inner loop per task:** `make kit-test FILTER='…'`, `make lint-swift` (`make lint-diff` is Go-only; run it only in Task 3, which adds Go), `go test ./internal/hub/transport/relay -run …` in Task 3. Never in the background; long runs go to a log with an explicit exit code (`cmd > "${TMPDIR:-/tmp}/p2-<task>.log" 2>&1; echo "exit=$?"`). The full gate runs once, in Task 15.
- **Processes are reaped.** `scripts/relay-interop.sh` starts `wrangler dev` in its own process group and kills the group on every exit path (`trap … EXIT INT TERM`); tests never start processes.

## Review Focus

1. **Signed bytes.** `relay_device_id`, the register `clientDataHash`, the login message and the login `clientDataHash` must equal the relay's bytes exactly, including the origin string (trailing `/` trimmed). Task 3 vectors come from the Go client copy; CryptoKit's Ed25519 is randomized, so the Kit pins message bytes and verifies Go's signatures, never compares signature bytes (`RelayAuthVectorTests`).
2. **Attestation never loops and never blocks CloudKit.** `ATTESTATION_REQUIRED` → `.updateRequired` with no retry; `ATTESTATION_FAILED` on an assertion login → exactly one fresh attestation, then `.updateRequired`; `invalidKey` → discard, regenerate, attest; `serverUnavailable`/no network → same key, backoff 1 s doubling to 5 min; `isSupported == false` → no network call at all. Task 5's eight scenario tests (names from relay `sim/README.md`).
3. **No lost or reordered write.** A save answer is matched to its items by index; an answer that does not cover the request exactly is an error, never a partial success; after any save/delete error the zone is re-read before a conditional retry; the server cursor moves only in the same transaction that buffers the page. Task 9 `testMalformedSaveAnswerIsAnError`, `testSaveErrorRereadsZone`, `testCursorMovesOnlyWithTheBufferedPage`.
4. **`TOKEN_EXPIRED` resync drops what the server forgot.** A full resync of a zone from 0 buffers deletions for every record the transport knew in that zone and the resync did not return. Task 9 `testTokenExpiredResetsZoneToZero`.
5. **Socket lifecycle.** No tight reconnect loop (1001 → 1–3 s; abnormal → exponential), one `onGoingAway` per such close, a subscribe without an answer cuts the connection, a full event buffer never blocks the reader and never drops a control. Tasks 6 and 8.
6. **Boundaries.** The Desktop links no protobuf; `WatchtowerSync` imports none of the new modules; public CI needs neither the relay repository nor the network. Tasks 1, 13, 15.

## Rulings

Decisions this plan takes where the spec is silent, outdated or contradicts the code. Each: what — why — cost if wrong.

- **R1. Pin relay@3a99bd7 (relay `main`, PR #2), not the closed freeze PR's head `2643f78`.** The proto landed in `main` with PR #2; the Go hub's copy already pins the same commit, so both clients of one hub/phone pair speak the same proto. Spec §12 p. 1 amended. — Cost: none known; moving the pin later is `make relay-proto REF=<commit>`.
- **R2. App Attest is built in the Kit in Phase 2; its Keychain storage and the app entitlement come with Phase 3's identity.** relay@3a99bd7 enforces attestation on every `register` and `login` (`proto/README.md`), which the spec did not know; without it no phone can log in outside the local stand. Phase 2 builds the `AppAttesting` seam, the DeviceCheck adapter, the attestor state machine and every failure path, with the key id behind `AppAttestKeyStore` (in-memory implementation only). Phase 3 adds the Keychain store next to `relay_auth` and the `com.apple.developer.devicecheck.appattest-environment` entitlement. Spec §4, §7, §11, §13, Decisions amended. — Cost if wrong: Phase 3 grows by one small store and one entitlement line.
- **R3. Own Kit targets, phone only.** The spec said "Desktop and phone get it through the Kit"; after ask #802 the Desktop runs no relay code, and adding protobuf to `WatchtowerSync` would grow every Desktop build. `WatchtowerRelayProto`, `WatchtowerHostedRelay` and `WatchtowerHostedRelayTesting` are separate products; `WatchtowerSync` depends on none of them. Spec §7 amended. — Cost if wrong: a later Swift consumer adds one product dependency.
- **R4. Phone role only; no `MailboxAddressing`.** `MailboxAddressing` exists so a hub can read one mailbox per phone; the hub is Go (ask #802) and the phone has exactly one mailbox per hub. `HostedRelayTransport` maps `.data` → `data/<mac>` and `.relay` → `relay/<mac>/<self>` and nothing else. The sim twins' hub (`SimHub`) talks to the relay through the raw `HostedRelayClient` with `DEVICE_KIND_MAC`, as a test model. Pairing zones (`pair/<slot>`) come with Phase 3 linking. — Cost if wrong: a Swift hub role would need a second zone mapper; nothing here blocks it.
- **R5. No `PagedChanges`; the transport buffers into `TransportStore`.** The phone's consumers (`ReplicaHydrator`, `RelayFeed`) pass local buffer tokens and compact the buffer (`CompactingTransport`); `CloudKitTransport` works the same way. `HostedRelayTransport` pulls server pages (looping on `more`) into the buffer and serves `changes(in:since:)` from it, so consumers and `CloudChangeToken` stay as they are, and the server's `UInt64` seq lives in a transport-private table. — Cost if wrong: if a consumer later needs server pages directly, `PagedChanges` is added then as an optional protocol.
- **R6. Task 2 defines `ConditionalTransport` and `CloudRecord.recordSeq`; Phase 1 implements them on CloudKit.** Phase 2 depends only on 0a (§13), but the relay transport needs the protocol now; Phase 1's plan is not written. The shape is spec §3's, with two precisions taken from the relay and the Go hub: a conflict's `current` is optional (`SaveConflict.current` is absent when the record does not exist), and a delete with `.absent` is refused before any I/O (the relay has no "must not exist" delete; Go `Delete` does the same). If Phase 1 lands first with a different shape, Task 2 adopts Phase 1's shape and only adds what is missing. — Cost if wrong: a rename in Task 9 and in the sim harness.
- **R7. On the relay `RecordOrigin.serverAt` = `client_modified_at_ms`.** The spec's §3 table said "the relay stamps it"; the relay keeps no server time per record, and the Go hub's `stored()` uses the writer's time. `author` stays nil on the relay (the server ACL already proved the mailbox). Spec §3 row corrected. — Cost if wrong: phone code that ages relay records by `serverAt` would trust a writer's clock; Phase 2 has no such consumer and the relay's hygiene is TTL-based.
- **R8. Plain `save`/`delete` queue durably; `ConditionalTransport` calls are direct.** `CloudKitTransport.save` enqueues to `TransportStore.pending` and a later flush sends it; existing phone callers (device record, recording uploads) rely on that. `HostedRelayTransport` keeps the contract: plain saves enqueue and flush on `sendNow()`/connect/each pull, in enqueue order, unconditionally. Conditional saves and deletes go straight to the relay and return outcomes (the outbox of Phase 1 owns their retries). After any error answer the transport pulls the affected zone before it reports, so a caller's next conditional write sees the current `record_seq` (relay `Save` comment: "the client must re-read the affected zones"). — Cost if wrong: one function in Task 9.
- **R9. A `ZoneChanged` carrying a record is still just "pull this zone".** The Go hub's transport does the same and it keeps one code path (cursor, attachments, conditional seqs). — Cost: one extra small `changes` round trip per event; the 64 KiB inline record could be used later as an optimisation.
- **R10. A `TOKEN_EXPIRED` resync buffers deletions for records the server no longer returns.** The spec says only "full resync of that zone"; a resync from 0 returns the live set but not tombstones purged after 30 days, so a record deleted meanwhile would live on in the replica. The transport keeps `(zone, name, record_seq)` of every record it saw; after the resync's last page (`more == false`) it buffers a deletion for each known name the resync did not return. Go marks `Batch.Reset` for its consumer; the Kit's consumers read a plain change buffer, so the transport does the diff itself. — Cost if wrong: none for correctness; a few extra deletion events.
- **R11. No new `TransportEvent` cases.** The spec lists `hubQuota`/`mailboxQuota`; the phone writes only its mailbox, so it can meet `MAILBOX_QUOTA_EXCEEDED` (→ today's `.quotaExceeded`) but never `HUB_QUOTA_EXCEEDED` (the Mac's data zone, the Go hub's). Relay-only signals (controls, `ENTITLEMENT_INACTIVE`, `FORBIDDEN` on a zone, unsupported version, attestation outcome, connection state) go on `HostedRelayTransport.relayEvents`, which Phases 3–4 wire to §9's screens. Adding cases to `TransportEvent` would touch every exhaustive switch on the phone for nothing in Phase 2. — Cost if wrong: Phase 4 adds a case.
- **R12. The sim twins run a test-only Swift port of the relay's sim model.** The spec's twins need a phone and a hub obeying sim rules 1–16; the phone's production outbox is Phase 1 and the hub is the Go hub. Like the Go sim, the twins use a model (`SimPhone`, `SimHub`, transparent JSON envelopes); the phone's relay leg goes through the real `HostedRelayTransport` and `HostedRelayClient`, so what the twins pin is that the Kit's client and transport carry every rule. The CloudKit leg is a port of the sim's own `FakeCloudKit` (`SimCloudKit`), not `InMemoryCloudTransport` extended with change tags: 0a's constraint keeps that fake conforming to nothing new, and change tags on CloudKit are Phase 1's. — Cost if wrong: the twins test a model phone; Phase 1 or 3 can point `SimPhone`'s outbox at the production `ActionOutbox` without touching the scenarios.
- **R13. WebSocket on `URLSessionWebSocketTask`, close codes read from `closeCode.rawValue`.** The imported NS_ENUM keeps unknown raw values, so 4000/4001/4008 survive. The interop's `testHelloMismatchRelogsIn` on the stand checks it. — Cost if wrong: `URLSessionRelaySocketDialer` (one file behind the `RelaySocketDialer` seam) is rewritten on Network.framework (`NWProtocolWebSocket`, `.privateCode`); nothing else changes.
- **R14. Regeneration with `buf` and a `protoc-gen-swift` built from the Kit's pinned swift-protobuf checkout.** The relay generates with `buf`; the generator must match the runtime exactly (generated code checks the library version at compile time). `scripts/relay-proto.sh` mirrors `scripts/relay-go.sh` (refuses a dirty or unpinned relay checkout). `VERSION` line 1 has the Go copy's format (`<commit> <commit date>`), line 2 `protoc-gen-swift <tag>`; a Kit test checks line 2 equals the `exact:` pin in `Package.swift`. The Kit and Go pins are not forced equal (different release trains); the script prints both. — Cost if wrong: a developer without `buf` installs it (`brew install bufbuild/buf/buf`); public CI never regenerates.
- **R15. Interop runs the same scenario classes against the stand; outage, deploy and crash scenarios run on the fake only.** The Go sim stops and restarts the server through its own proxy (`internal/testenv`); our script runs a plain `wrangler dev`, so a scenario that needs the server down (`testSwitchToCloudKitDuringRelayOutage`, `testNoAckedWriteLostAcrossDeploy`, `…AcrossCrash`, the 1001/4001 fault scenarios) skips on the stand with the reason. The relay CI job building the Kit client (spec §12 p. 4, Phase 3) covers them against the real server. The stand runs with attestation off; the Swift client sends `FakeAppAttest` bytes there, which exercises the same register/login code the phone uses. — Cost if wrong: those scenarios are proven against the fake only until Phase 3's relay CI job.
- **R16. `testAttestUnsupportedStaysOnCloudKit` at Kit level asserts the refusal, not the routing.** The client throws `.notSupported` before any network call when `isSupported == false`; "sync stays on CloudKit" is the phone's `TransportFactory`, wired in Phase 3, which adds the routing test under the same name in `WatchtowerMobile/Tests`. — Cost: none.
- **R17. Auth vectors are generated by a Go test over the Go client copy.** `client.DeviceID` and `client.RegisterClientDataHash` are the Go client's own; the login message follows `loginLocked` (`nonce ‖ id ‖ base`); the login `clientDataHash` (not in the Go client, which never attests) follows `proto/README.md` and the Worker's rule. Ed25519 seeds are fixed test values. — Cost if wrong: the interop login on the stand would fail loudly.
- **R18. Macs do not attest; MAC-kind devices appear only in tests on the stand or the fake.** relay@3a99bd7 still requires App Attest for `DEVICE_KIND_MAC` and has no `vouch_hub` or `DEVICE_KIND_HUB` (relay ask #805); the hub's admission is the Go hub's and Phase 3's vouching. `FakeHostedRelay` in `enforce` mode applies the README's table for phones and lets test-only MAC devices in through an exempt list, the way the relay's probe devices are exempt. — Cost: none for the phone; vouching is planned in Phase 3.
- **R19. The phone app links nothing new in Phase 2.** No phone code uses the client before Phase 3; the iOS build of the new targets is checked in the gate by `xcodebuild … -scheme WatchtowerHostedRelay -destination 'generic/platform=iOS Simulator' build` inside `WatchtowerKit`, and `make mobile-build` confirms the app still resolves the Kit with its new dependency. — Cost: none.
- **R20. `FakeHostedRelay` follows `proto/README.md`; where the stand disagrees, the stand wins.** Task 13's interop runs the same scenarios on both; a difference is fixed in the fake in the same task and noted in the feature note. — Cost: one interop round.

## Lanes

- Lane A (proto → client): Task 1 → {Task 3, Task 4} (parallel) → Task 5 → Task 6.
- Lane B (seam): Task 2 — independent, starts with Task 1.
- Lane C (fake server): Task 7 after Tasks 3 and 4, parallel with Tasks 5–6.
- Join: Task 8 (after 6, 7) → Task 9 (after 2, 8) → Task 10 → {Task 11, Task 12} (parallel) → Task 13 → Task 14 → Task 15 (gate).

Parallel lanes run in their own worktrees and branches, merged by the controller; Task 1 changes `Package.swift`, so lanes B and C rebase on it before touching the manifest.

---

### Task 1: The proto and generated Swift in the Kit, pinned to relay@3a99bd7

**Depends on:** none

**Files:**
- Create: `scripts/relay-proto.sh`, `scripts/tests/test-relay-proto.sh`
- Modify: `Makefile` (target `relay-proto`, next to `relay-go`; add it to `.PHONY`)
- Create: `WatchtowerKit/Sources/WatchtowerRelayProto/relay.proto` (copy), `relay.pb.swift` (generated), `VERSION`
- Create: `WatchtowerKit/Sources/WatchtowerHostedRelay/HostedRelay.swift`
- Modify: `WatchtowerKit/Package.swift`, `WatchtowerKit/Package.resolved`; `WatchtowerDesktop/Package.resolved` only if SwiftPM rewrites it
- Modify: `WatchtowerKit/.swiftlint.yml` (`excluded: Sources/WatchtowerRelayProto`)
- Test: Create `WatchtowerKit/Tests/WatchtowerHostedRelayTests/RelayProtoPinTests.swift`; modify `WatchtowerKit/Tests/WatchtowerSyncTests/SeamBoundaryTests.swift`

**Interfaces:**
- `Package.swift`: dependency `.package(url: "https://github.com/apple/swift-protobuf", exact: "<tag>")` — the newest release tag at least two weeks old when the task runs (record it in the commit message and `VERSION`). Products added: `WatchtowerHostedRelay`, `WatchtowerHostedRelayTesting` (the latter's target arrives in Task 4; add the product there). Targets: `WatchtowerRelayProto` (deps `SwiftProtobuf`; `exclude: ["relay.proto", "VERSION"]`), `WatchtowerHostedRelay` (deps `WatchtowerSync`, `WatchtowerRelayProto`, `SwiftProtobuf`), test target `WatchtowerHostedRelayTests` (deps `WatchtowerHostedRelay`, `WatchtowerRelayProto`, `WatchtowerSync`, `SwiftProtobuf`, GRDB). The header comment's product list gains the three new products and says they are linked by the phone only (R3).
- Generated types: `Relay_V1_Frame`, `Relay_V1_Request`, `Relay_V1_Response`, `Relay_V1_ErrorCode`, … with `Visibility=Public`, `FileNaming=DropPath`.
- `public enum HostedRelay { public static let protocolVersion: UInt32 = 1 }` — the `Relay-Protocol-Version` header and `Hello.protocol_version` (relay `gen/relay/v1/version.go`).
- `VERSION`: line 1 `3a99bd72758687e1393c3ab036484ac03cee98b1 <commit date, ISO 8601>`, line 2 `protoc-gen-swift <tag>`.
- `scripts/relay-proto.sh <relay checkout> [<commit>]` / `make relay-proto RELAY=../relay [REF=<commit>]`: default commit from `VERSION`; refuses a non-git, dirty, or not-at-the-commit checkout with the same messages as `relay-go.sh` (prefix `relay-proto:`); requires `buf` (prints `brew install bufbuild/buf/buf` when missing); runs `swift package resolve` in `WatchtowerKit`, builds `protoc-gen-swift` from `.build/checkouts/swift-protobuf` (`swift build -c release --product protoc-gen-swift --package-path …`), runs `buf generate <relay>/proto --path <relay>/proto/relay/v1/relay.proto --template '<inline v2 template: local plugin, out, opt Visibility=Public, FileNaming=DropPath>'` into a temp dir, copies `relay.proto` and `relay.pb.swift`, writes `VERSION`, prints the Kit and Go (`internal/hub/transport/relay/VERSION`) commits. Temp dirs are removed by a `trap`.

- [ ] **Step 1: Write the failing tests**
  - `RelayProtoPinTests.testVersionPinsARelayCommitAndTheGenerator`: reads `VERSION` from `#filePath`; line 1 matches `^[0-9a-f]{40} \d{4}-\d{2}-\d{2}T`; line 2 is `protoc-gen-swift <tag>` and `<tag>` equals the `exact:` string of the swift-protobuf dependency read from `WatchtowerKit/Package.swift`.
  - `RelayProtoPinTests.testGeneratedTypesRoundTrip`: a `Relay_V1_Frame` with `request.save` of one `SaveItem{record{zone: "relay/mac-acme/phone-acme", name: "a-1", envelope: [1,2,3]}, mustNotExist: true}` serializes and parses back equal; `Relay_V1_ErrorCode.attestationFailed.rawValue == 21`; `HostedRelay.protocolVersion == 1`.
  - `SeamBoundaryTests.testOnlyTheHostedRelayTargetsImportProtobuf`: no `.swift` file under `Sources/WatchtowerSync` or `Sources/WatchtowerKit` has a line starting `import SwiftProtobuf`, `import WatchtowerRelayProto`, `import WatchtowerHostedRelay` or `import DeviceCheck`.
  - `scripts/tests/test-relay-proto.sh`: a temp git repo as `RELAY` — dirty tree → exit 1 with `refusing a dirty source`; HEAD ≠ requested commit → exit 1 with `refusing an unpinned source`; not a git dir → exit 1. (No `buf` needed: refusals come first.)
- [ ] **Step 2: Run, expect failure** — `make kit-test FILTER='RelayProtoPinTests|SeamBoundaryTests'` — FAIL (no target).
- [ ] **Step 3: Implement** the script, Make target and manifest; then, in a clean relay worktree at the pin (`git -C <relay> worktree add <tmp> 3a99bd7`), run `make relay-proto RELAY=<tmp>` and commit the output. Remove the relay worktree afterwards.
- [ ] **Step 4: Run** — `make kit-test FILTER='RelayProtoPinTests|SeamBoundaryTests'`, `bash scripts/tests/test-relay-proto.sh`, and `make test-swift FILTER=SeamTypesTests` (the Desktop still resolves the Kit) — PASS.
- [ ] **Step 5: Lint** — `make lint-swift` (generated file excluded).
- [ ] **Step 6: Commit** — `build(kit): relay.proto and generated Swift pinned to relay 3a99bd7 (#1239)`

### Task 2: `ConditionalTransport` and `CloudRecord.recordSeq` in `WatchtowerSync`

**Depends on:** none (if Phase 1 has already landed these types, adopt its shape per R6 and only add what is missing)

**Files:**
- Create: `WatchtowerKit/Sources/WatchtowerSync/Sync/ConditionalTransport.swift`
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Sync/CloudSyncTransport.swift` (`CloudRecord.recordSeq`)
- Modify: `WatchtowerKit/Sources/WatchtowerSync/CloudKitTransport/TransportStore.swift` (`events.record_seq` column, patched in like `creator`; read and written by `bufferChanged`/`changes`)
- Modify: `WatchtowerKit/Sources/WatchtowerSync/Secure/SecureTransport.swift` (an opened record keeps `recordSeq`, as it keeps `origin`)
- Test: `WatchtowerKit/Tests/WatchtowerSyncTests/TransportStoreTests.swift`, `SecureTransportTests.swift`, `SeamTypesTests.swift`

**Interfaces:**
```swift
public enum TransportExpect: Equatable, Sendable { case none, absent, seq(UInt64) }
public struct ConditionalSave: Equatable, Sendable { public let record: CloudRecord; public let expect: TransportExpect; public init(_:expect:) }
public struct ConditionalDelete: Equatable, Sendable { public let recordName: String; public let zone: CloudZoneID; public let expect: TransportExpect; public init(recordName:zone:expect:) }
public enum TransportRefusal: Error, Equatable, Sendable {
    case quotaExceeded, recordTooLarge, rateLimited, entitlementInactive, forbidden
    case unsupportedPrecondition   // e.g. a delete with .absent (R6)
}
public enum SaveOutcome: Equatable, Sendable { case saved(recordSeq: UInt64); case conflict(current: CloudRecord?); case refused(TransportRefusal) }
public enum DeleteOutcome: Equatable, Sendable { case deleted; case conflict(current: CloudRecord?); case refused(TransportRefusal) }
/// Optional surface (spec §3): conditional writes for the mailbox lane. Outcomes are in item order, one per item.
/// A thrown error means the batch may be partly applied: the caller re-reads the zone before retrying (relay `Save`).
public protocol ConditionalTransport: CloudSyncTransport {
    func save(_ items: [ConditionalSave]) async throws -> [SaveOutcome]
    func delete(_ items: [ConditionalDelete]) async throws -> [DeleteOutcome]
}
```
- `CloudRecord.recordSeq: UInt64?` — read-only server metadata like `origin`, never sent on a plain save; the memberwise init takes `recordSeq: UInt64? = nil` after `origin`. On the relay it is the record's `record_seq`; on CloudKit (Phase 1) it stands for the change tag, compared for equality only (Go `transport.Stored.RecordSeq` doc).

- [ ] **Step 1: Write the failing tests**
  - `TransportStoreTests.testAnEventKeepsItsRecordSeq`: buffer one record with `recordSeq: 7` and one without; `changes` returns `[7, nil]`; a store file created before the column (raw `events` table without `record_seq`) opens and reads `nil`.
  - `SecureTransportTests.testOpeningKeepsTheRecordSeq`: a sealed relay record carrying `recordSeq: 42` opens with `recordSeq == 42`.
  - `SeamTypesTests.testTheCloudKitTransportAndTheFakeAreNotConditional`: `CloudKitTransport` (built as in `CloudKitTransportStopTests`) and `InMemoryCloudTransport()` are not `any ConditionalTransport` (Phase 2 changes nothing on CloudKit).
- [ ] **Step 2: Run, expect failure** — `make kit-test FILTER='TransportStoreTests|SecureTransportTests|SeamTypesTests'` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — the same filter plus `CloudKitTransportMappingTests|InMemoryCloudTransportTests`, then `make test-swift FILTER='RelayProcessorTests|MobileLinkCenterTests'` (the Desktop compiles against the changed `CloudRecord`) — PASS.
- [ ] **Step 5: Lint and guard check** — `make lint-swift`; guard-file diff empty.
- [ ] **Step 6: Commit** — `feat(kit): ConditionalTransport seam and CloudRecord.recordSeq (#1240)`

### Task 3: Relay identity messages and Go-generated auth vectors

**Depends on:** Task 1

**Files:**
- Create: `WatchtowerKit/Sources/WatchtowerHostedRelay/Identity/RelayAuthMessages.swift`, `RelaySigner.swift`, `RelayOrigin.swift`
- Create: `internal/hub/transport/relay/kitvectors_test.go`
- Create: `WatchtowerKit/Tests/Fixtures/relay/auth_vectors.json` (written by the Go test)
- Test: Create `WatchtowerKit/Tests/WatchtowerHostedRelayTests/RelayAuthVectorTests.swift`

**Interfaces:**
```swift
public struct RelayOrigin: Equatable, Sendable {
    /// scheme://host[:port] as configured, trailing "/" trimmed (the Go client's `base`); signed at login and register.
    public let string: String
    public let url: URL
    public init(_ string: String) throws   // throws RelayOriginError.invalid for a non-http(s) URL or one with a path/query
}
public enum RelayAuthMessages {
    /// lower-case unpadded RFC 4648 base32 of SHA-256(publicKey)
    public static func deviceID(publicKey: Data) -> String
    /// SHA256("relay/v1/register" ‖ nonce ‖ authPub ‖ origin)
    public static func registerClientDataHash(nonce: Data, authPub: Data, origin: RelayOrigin) -> Data
    /// nonce ‖ deviceID ‖ origin — what the Ed25519 key signs at login
    public static func loginMessage(nonce: Data, deviceID: String, origin: RelayOrigin) -> Data
    /// SHA256("relay/v1/login" ‖ nonce ‖ deviceID ‖ origin) — what the App Attest assertion covers
    public static func loginClientDataHash(nonce: Data, deviceID: String, origin: RelayOrigin) -> Data
}
public protocol RelaySigner: Sendable { var publicKey: Data { get }; func sign(_ message: Data) throws -> Data }
public struct Ed25519RelaySigner: RelaySigner { public init(_ key: Curve25519.Signing.PrivateKey) }
```
- Go: `TestKitRelayAuthVectors` in package `relay` (internal test of `internal/hub/transport/relay`), flag `-update` (`var updateKitVectors = flag.Bool("update", …)`). Two cases with fixed 32-byte seeds and nonces (hex constants in the test), origins `https://relay.example.com` and `http://127.0.0.1:8787`. Fields per case: `seed`, `auth_pub`, `relay_device_id` (`client.DeviceID`), `nonce`, `origin`, `register_client_data_hash` (`client.RegisterClientDataHash`), `register_signature`, `login_message` (as `loginLocked` builds it), `login_signature`, `login_client_data_hash` (per `proto/README.md`). Without `-update` it recomputes and compares with the committed file (so a Go-side change is caught by public CI).

- [ ] **Step 1: Write the Go test, generate the fixture** — `go test ./internal/hub/transport/relay -run TestKitRelayAuthVectors -update`, then without `-update` — PASS; `make lint-diff`.
- [ ] **Step 2: Write the failing Kit tests** (`RelayAuthVectorTests`)
  - `testDeviceIDMatchesTheGoClient`: `deviceID(publicKey:)` of each case's `auth_pub` equals `relay_device_id`; `Ed25519RelaySigner(seed).publicKey == auth_pub`.
  - `testRegisterClientDataHashVector` (twin of Go `TestRegisterClientDataHashVector`): equals the case's bytes.
  - `testLoginMessageAndHashMatchTheGoClient`: both equal.
  - `testGoSignaturesVerifyAndOursVerifyToo`: CryptoKit verifies `register_signature`/`login_signature`; a fresh Swift signature over the same message verifies under `auth_pub` (CryptoKit's Ed25519 is randomized: bytes are not compared, R17).
  - `testOriginTrimsTheTrailingSlashAndRefusesPaths`: `"https://relay.example.com/"` → `"https://relay.example.com"`; `"https://relay.example.com/v1"` and `"ftp://x"` throw.
- [ ] **Step 3: Run, expect failure** — `make kit-test FILTER=RelayAuthVectorTests` — FAIL.
- [ ] **Step 4: Implement** (base32 written out, no dependency).
- [ ] **Step 5: Run** — `make kit-test FILTER=RelayAuthVectorTests` — PASS. Lint `make lint-swift`.
- [ ] **Step 6: Commit** — `feat(kit): relay device id and login/register messages pinned by Go vectors (#1239)`

### Task 4: App Attest seam, attestor and fake

**Depends on:** Task 1

**Files:**
- Create: `WatchtowerKit/Sources/WatchtowerHostedRelay/Attest/AppAttesting.swift`, `AppAttestKeyStore.swift`, `DeviceCheckAppAttest.swift`, `RelayAttestor.swift`
- Create: `WatchtowerKit/Sources/WatchtowerHostedRelayTesting/FakeAppAttest.swift`, `ManualRelayClock.swift` (virtual time: `now()`, `advance(by:)`; `sleep` suspends until advanced past its deadline; used by every later task); `Package.swift` (target `WatchtowerHostedRelayTesting`, deps `WatchtowerHostedRelay`, `WatchtowerRelayProto`, `SwiftProtobuf`; product of the same name; `WatchtowerHostedRelayTests` depends on it)
- Test: Create `WatchtowerKit/Tests/WatchtowerHostedRelayTests/RelayAttestorTests.swift`

**Interfaces:**
```swift
public protocol AppAttesting: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
}
/// How a DeviceCheck failure is handled (proto README, "Failure paths on the client").
public enum AppAttestFailure: Error, Equatable, Sendable { case invalidKey, serverUnavailable, other(String) }
public protocol AppAttestKeyStore: Sendable { func keyID() async -> String?; func setKeyID(_ id: String?) async }
public actor InMemoryAppAttestKeyStore: AppAttestKeyStore { public init(keyID: String? = nil) }   // Phase 3 adds the Keychain one (R2)
#if canImport(DeviceCheck)
public struct DeviceCheckAppAttest: AppAttesting { public init() }  // DCAppAttestService.shared; maps DCError.invalidKey → .invalidKey,
                                                                    // DCError.serverUnavailable and URLError → .serverUnavailable, else .other(code)
#endif
public enum HostedRelayAttestError: Error, Equatable, Sendable {
    case notSupported                 // isSupported == false: the relay is not offered (CloudKit stays)
    case retryLater(after: Duration)  // generateKey / attestKey / assertion failed transiently
    case updateRequired               // ATTESTATION_REQUIRED, or ATTESTATION_FAILED after the one fresh attestation
}
public actor RelayAttestor {
    public init(attest: any AppAttesting, keys: any AppAttestKeyStore, clock: any RelayClock)
    /// For `register`: a fresh attestation over `clientDataHash` (generateKey when no key is stored).
    public func registerAttestation(clientDataHash: Data) async throws -> Relay_V1_Attestation
    /// For `login`: an assertion when a key is stored, else a fresh attestation (lost-key path).
    public func loginAttestation(clientDataHash: Data) async throws -> Relay_V1_Attestation
    /// The server answered ATTESTATION_FAILED to an assertion login: forget the key so the next login attests afresh.
    /// Returns false when this already happened once since the last successful login (→ updateRequired).
    public func serverRefusedAssertion() -> Bool
    public func loginSucceeded()
    /// Backoff for transient failures: 1 s doubling to 5 min (proto README).
    public static func backoff(failures: Int) -> Duration
}
public protocol RelayClock: Sendable { func now() -> Date; func sleep(for duration: Duration) async throws }
public struct SystemRelayClock: RelayClock { public init() }
```
- `FakeAppAttest` (testing target): `isSupported` settable; queues of scripted failures per call; attestation object = JSON `{"fake_app_attest":1,"key_id","client_data_hash","app_id":"acme.test"}`; assertion = JSON `{"key_id","client_data_hash","counter"}` with a counter increasing per key; a call log (`calls: [String]`). Task 7's fake server verifies these bytes.
- `invalidKey` handling: on `attestKey` or `generateAssertion` → `keys.setKeyID(nil)`, `generateKey`, `attestKey` once more within the same call; a second `invalidKey` → `.retryLater`.
- `serverUnavailable` on `attestKey` keeps the stored key id (Apple: reuse the key) and throws `.retryLater(backoff(failures:))`; the failure count resets on success.

- [ ] **Step 1: Write the failing tests** (`RelayAttestorTests`, `FakeAppAttest` + `InMemoryAppAttestKeyStore` + `ManualRelayClock`)
  - `testAttestUnsupportedRefusesBeforeAnyCall` — both entry points throw `.notSupported`; `FakeAppAttest.calls` is empty.
  - `testGenerateKeyFailsBacksOff` — `generateKey` fails three times: `.retryLater` with 1 s, 2 s, 4 s; `backoff(failures: 20) == .seconds(300)`.
  - `testAttestKeyServerUnavailableRetriesSameKey` — first `attestKey` fails `.serverUnavailable`: `.retryLater`, the stored key id is kept; the next call attests the same key id (one `generateKey` in total).
  - `testInvalidKeyRegeneratesAndAttests` — `attestKey` fails `.invalidKey` once: a second `generateKey` and a successful attestation with the new id, which is stored; same for `generateAssertion` in `loginAttestation`.
  - `testLoginWithoutAStoredKeyAttestsAfresh` — no key id: `loginAttestation` returns `.appAttest` over the login hash.
  - `testServerRefusedAssertionAllowsOneFreshAttestation` — `serverRefusedAssertion()` → true and clears the key; again before `loginSucceeded()` → false.
- [ ] **Step 2: Run, expect failure** — `make kit-test FILTER=RelayAttestorTests` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — `make kit-test FILTER=RelayAttestorTests` — PASS. Lint.
- [ ] **Step 5: Commit** — `feat(kit): App Attest seam and attestor for the relay client (#1239)`

### Task 5: `HostedRelayClient` over HTTPS — ops, retries, register and login with App Attest

**Depends on:** Task 3, Task 4

**Files:**
- Create: `WatchtowerKit/Sources/WatchtowerHostedRelay/Client/RelayHTTP.swift` (seam + `URLSessionRelayHTTP`), `HostedRelayClient.swift`, `HostedRelayClient+Ops.swift`, `HostedRelayError.swift`
- Test: Create `WatchtowerKit/Tests/WatchtowerHostedRelayTests/HostedRelayClientTests.swift`, `HostedRelayAttestationTests.swift`, `Support/ScriptedRelayHTTP.swift`

**Interfaces:**
```swift
public protocol RelayHTTP: Sendable {
    func post(_ url: URL, body: Data, headers: [String: String]) async throws -> (status: Int, body: Data)
    func put(_ url: URL, file: URL, headers: [String: String]) async throws -> Int                       // attachment upload
    func get(_ url: URL, to file: URL, maxBytes: Int64, headers: [String: String]) async throws -> Int  // attachment download, capped
}
public struct URLSessionRelayHTTP: RelayHTTP { public init(session: URLSession = .shared) }   // 30 s request timeout (Go)
public enum HostedRelayError: Error, Equatable, Sendable {
    case server(code: Relay_V1_ErrorCode, retryAfter: UInt32?)   // Error.message is for logs only, never kept
    case unsupportedVersion                                        // UNSUPPORTED_VERSION / close 4000: "update the app"
    case undecodable(status: Int)
    case unreachable                                               // no answer, dropped connection
    case attestation(HostedRelayAttestError)
}
public actor HostedRelayClient {
    public init(origin: RelayOrigin, signer: any RelaySigner, kind: Relay_V1_DeviceKind, attestor: RelayAttestor,
                http: any RelayHTTP, sockets: any RelaySocketDialer /* Task 6; a stub until then */,
                clock: any RelayClock, backoff: @escaping @Sendable (Int) -> Duration = HostedRelayClient.defaultBackoff,
                onGoingAway: (@Sendable () -> Void)? = nil)
    public nonisolated let deviceID: String
    public static func defaultBackoff(_ attempt: Int) -> Duration   // 500 ms << min(attempt, 8), capped 60 s, uniform in the upper half
    public func register() async throws -> String                    // challenge(REGISTER) → attestation → register; keeps accountID
    public var accountID: String? { get }
    public func login() async throws                                  // challenge(LOGIN) → signature + attestation → session
    /// One op over HTTPS: session (single-flight login), UNAUTHENTICATED → one relogin and one retry,
    /// UNAVAILABLE → 0.5 s doubling to 8 s, ≤ 30 s total, then the error.
    public func perform(_ op: Relay_V1_Request.OneOf_Op) async throws -> Relay_V1_Response
}
```
- Typed helpers in `+Ops.swift` for the phone's ops only: `save`, `delete`, `changes`, `createUpload`, `getDownload`, `addSlot`, `removeSlot`, `openPairing`, `closePairing`, `promotePairing`, `registerPush`, `submitTransaction`, `accountState`. Mac ops (`set_hub_readers`, `send_alert`) are reached through `perform` by tests only (R4, R18).
- Request: `POST <origin>/v1/op`, `Content-Type: application/x-protobuf`, `Relay-Protocol-Version: 1`, `Authorization: Bearer <token>` except for `register`/`challenge`/`login`. Any status: the body is decoded as `Relay_V1_Response`; undecodable → `.undecodable(status:)`; `Response.error` → `.server` (`UNSUPPORTED_VERSION` → `.unsupportedVersion`).
- Login attestation flow (spec §4): assertion when a key id is stored; `ATTESTATION_FAILED` on an assertion login → `attestor.serverRefusedAssertion()` → one login with a fresh attestation, else `.attestation(.updateRequired)`; `ATTESTATION_REQUIRED` → `.attestation(.updateRequired)` at once; neither is ever retried by the relogin path. `loginSucceeded()` after a session.
- The token lives in actor memory only; a stale token (the one a request was refused with) triggers one login shared by concurrent callers (Go `sessionToken(stale)`).

- [ ] **Step 1: Write the failing tests** (`ScriptedRelayHTTP` answers per op from a script and records requests; `ManualRelayClock` advances virtual time)
  - `HostedRelayClientTests`: `testDefaultBackoffJitteredUpTo60s`, `testRegisterAsksForRegisterNonce` (first request `challenge{purpose: REGISTER, device_id}`; then `register` with that nonce), `testLoginUnsupportedVersion` (→ `.unsupportedVersion`, no retry), `testRetryOnUnavailable` (two `UNAVAILABLE` then `Ok`: delays 0.5 s, 1 s), `testRetryGivesUpAfter30s` (always `UNAVAILABLE`: returns the error at 30 s of virtual time, last delay clipped), `testDoReturnsProtocolErrors` (`FORBIDDEN` → `.server(code: .forbidden, …)`), `testUnauthenticatedRelogsInOnceAndRetries` (401 + `UNAUTHENTICATED` → one challenge/login, the op retried once; a second 401 is returned), `testConcurrentCallersShareOneLogin`, `testRequestsCarryTheProtocolHeaderAndBearer`, `testTokensAreNeverInErrorDescriptions`.
  - `HostedRelayAttestationTests` (the relay's names, `sim/README.md` "Attestation scenarios for the Swift client"): `testAttestUnsupportedStaysOnCloudKit` (R16: `.attestation(.notSupported)` and no HTTP request), `testGenerateKeyFailsBacksOff`, `testAttestKeyServerUnavailableRetriesSameKey`, `testInvalidKeyRegeneratesAndAttests`, `testAssertionFailsRetriesLogin` (a transient `generateAssertion` failure → `.attestation(.retryLater)`; a valid session in hand keeps serving ops until it is refused), `testAttestationFailedOnLoginReattestsOnce` (assertion login → `ATTESTATION_FAILED` → exactly one login with `app_attest`; a second `ATTESTATION_FAILED` → `.updateRequired`, three login requests in total), `testAttestationRequiredShowsUpdate` (one request, `.updateRequired`, nothing more), `testRegisterSendsPurposeRegisterAndSignature` (the `register` carries the nonce, `app_attest` with the register hash, and an Ed25519 signature verifying over `registerClientDataHash`).
- [ ] **Step 2: Run, expect failure** — `make kit-test FILTER='HostedRelayClientTests|HostedRelayAttestationTests'` — FAIL.
- [ ] **Step 3: Implement.** `sockets` takes a `RelaySocketDialer`; until Task 6 lands, declare the protocol in `Client/RelaySocket.swift` with no conformer.
- [ ] **Step 4: Run** — same filter — PASS. Lint.
- [ ] **Step 5: Commit** — `feat(kit): HostedRelayClient HTTPS ops with App Attest login (#1239)`

### Task 6: The WebSocket connection

**Depends on:** Task 5

**Files:**
- Modify: `WatchtowerKit/Sources/WatchtowerHostedRelay/Client/RelaySocket.swift` (seam + `URLSessionRelaySocketDialer`)
- Create: `WatchtowerKit/Sources/WatchtowerHostedRelay/Client/HostedRelayConnection.swift`, `HostedRelayConnection+Events.swift`
- Test: Create `WatchtowerKit/Tests/WatchtowerHostedRelayTests/HostedRelayConnectionTests.swift`, `Support/ScriptedRelaySocket.swift`

**Interfaces:**
```swift
public enum RelaySocketMessage: Equatable, Sendable { case binary(Data); case closed(code: Int) }
public protocol RelaySocket: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> RelaySocketMessage
    func ping() async throws            // returns on pong; the caller bounds it by 10 s
    func close(code: Int) async
}
public enum RelayDialError: Error, Equatable, Sendable { case http(status: Int); case unreachable }
public protocol RelaySocketDialer: Sendable { func dial(_ url: URL, headers: [String: String]) async throws -> any RelaySocket }
public struct URLSessionRelaySocketDialer: RelaySocketDialer { public init(session: URLSession = .shared) }  // close code = closeCode.rawValue (R13)
public enum HostedRelayClientEvent: Equatable, Sendable {
    case zoneChanged(zone: String, seq: UInt64)       // seq 0 = record-less: "pull, you may have missed changes"
    case zoneRefused(zone: String, error: HostedRelayError)
    case control(kind: Relay_V1_ControlKind, detail: String)
    case connected, disconnected
    case stopped(HostedRelayError)                     // unsupported version or attestation updateRequired: no more reconnects
}
extension HostedRelayClient {
    /// Opens and keeps the socket: dial with Authorization → Hello{1, token} → HelloOk → subscribe each zone one by one.
    public func connect(zones: [String], eventBuffer: Int = 256) -> HostedRelayConnection
}
public final class HostedRelayConnection: Sendable {
    public var events: AsyncStream<HostedRelayClientEvent> { get }
    /// A Request over the socket, answered by id; UNAVAILABLE retried like `perform`.
    public func send(_ op: Relay_V1_Request.OneOf_Op) async throws -> Relay_V1_Response
    public func setZones(_ zones: [String]) async
    public func close() async
}
```
- Rules (relay `proto/README.md` WebSocket, sim "The Go client"): HTTP 401 at dial → login, redial; close 4001 → login, reconnect; close 4000 / `UNSUPPORTED_VERSION` → `.stopped(.unsupportedVersion)`; close 1001 (with or without a `GoingAway` frame before it) → reconnect after a uniform 1–3 s, `onGoingAway` once per such close; 4008 and abnormal closes (1006, 1011, a dial failure) → `defaultBackoff(attempt)`, attempt reset after a connection that reached `HelloOk`; ping every 30 s while open, no pong within 10 s → close and reconnect; after every connect: subscribe zones one by one (a refused zone → `.zoneRefused`, dropped from the set), then a record-less `.zoneChanged(zone, 0)` per subscribed zone; a subscribe with no answer within 10 s cuts the connection; `Control{SESSION_EXPIRED}` is handled by the 4001 that follows (the token used by this connection is invalidated, not a newer one).
- Event buffer: a bounded queue the reader never waits on; when full, a zone event is folded into that zone's record-less `zoneChanged` once there is room; controls, refusals and lifecycle events are queued, never dropped (Go `TestFullEventBufferNeverBlocksReader`).

- [ ] **Step 1: Write the failing tests** (`ScriptedRelaySocket`/dialer scripted per dial; `ManualRelayClock`)
  - Twins: `testDialSendsAuthorizationHeader`, `testClientPings30s`, `testDialRelogsInOn401`, `testHelloMismatchRelogsIn` (close 4001 after `Hello` → one login, one redial), `testReconnectDelayAfterGoingAway` (delay in [1 s, 3 s]), `testCloseGoingAwayWithoutFrame` (bare 1001 → same delay, `onGoingAway` called once).
  - New: `testMissingPongClosesAndReconnects`, `testClose4000StopsWithUnsupportedVersion` (no redial), `testAbnormalCloseKeepsExponentialBackoff` (1006 ×3 → delays from `defaultBackoff(0…2)`), `testSubscribeWithoutAnswerCutsTheConnection`, `testRefusedZoneIsDroppedAndReported`, `testEventsAfterConnectAreRecordLessPerZone`, `testFullBufferFoldsZoneEventsAndKeepsControls` (unit-level; the end-to-end twin is Task 8's).
- [ ] **Step 2: Run, expect failure** — `make kit-test FILTER=HostedRelayConnectionTests` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — `make kit-test FILTER='HostedRelayConnectionTests|HostedRelayClientTests'` — PASS. Lint.
- [ ] **Step 5: Commit** — `feat(kit): HostedRelayClient WebSocket with the relay's reconnect rules (#1239)`

### Task 7: `FakeHostedRelay` — the server model

**Depends on:** Task 3, Task 4

**Files:**
- Create: `WatchtowerKit/Sources/WatchtowerHostedRelayTesting/FakeHostedRelay.swift`, `FakeHostedRelay+Auth.swift`, `FakeHostedRelay+Zones.swift`, `FakeHostedRelay+Accounts.swift`, `RelayStandControl.swift`
- Test: Create `WatchtowerKit/Tests/WatchtowerHostedRelayTests/FakeHostedRelayTests.swift`

**Interfaces:**
```swift
/// In-memory relay following relay@3a99bd7 `proto/README.md` (R20). Thread-safe (one lock); time from a ManualRelayClock.
public final class FakeHostedRelay: @unchecked Sendable {
    public enum AttestMode: Sendable { case enforce(exemptDeviceIDs: Set<String>), off }
    public init(origin: String = "https://relay.example.com", attest: AttestMode = .enforce(exemptDeviceIDs: []),
                clock: ManualRelayClock)
    /// The server side of one op, as POST /v1/op would answer it (HTTP status + Response).
    public func handle(_ request: Relay_V1_Request, bearer: String?) -> (status: Int, response: Relay_V1_Response)
    public private(set) var log: [Relay_V1_Request.OneOf_Op]     // for assertions; never holds tokens
}
/// What a test may do to the server besides the protocol: the stand's /dev endpoints, on the fake or on the stand (Task 13).
public protocol RelayStandControl: Sendable {
    func setEntitlement(accountID: String, state: String, for duration: Duration) async throws   // active|grace|expired|revoked
    func accountID(ofPhone phoneID: String) async throws -> String
    func pair(mac: String, phones: [String]) async throws
    func expireMailboxes(_ zones: [String], elapsed: Duration) async throws
}
extension FakeHostedRelay: RelayStandControl {}
```
- Model (each rule cites its `proto/README.md` section in a doc comment): devices (Ed25519 signature checked with CryptoKit; `relay_device_id` derived; `account_id` for phones), registration nonce (stateless, 5 min) and single-use login nonce (60 s); attestation in `enforce` (the README's "Who must attest" table and failure codes over `FakeAppAttest` bytes: register needs `app_attest` over the register hash, login an assertion with a strictly increasing counter, lost-key login with `app_attest`; a wrong Ed25519 signature is `UNAUTHENTICATED` whatever the attestation) and `off` (ignored); sessions (token, expiry, `SESSION_EXPIRED`); zones `data/<mac>`, `relay/<mac>/<phone>`, `pair/<slot>` with per-zone `server_seq`, last-version records, tombstones (purged after 30 days → `TOKEN_EXPIRED` below the horizon; a `since_seq` above the zone's last → `TOKEN_EXPIRED`); conditional save/delete per item (`must_not_exist` counts a tombstone as absent; conflicts carry `current` or none); `changes` pages (`limit` default and max 500, ≤ 4 MiB of envelopes but at least one record, `more`); ACL (data zone: the Mac writes, `set_hub_readers` phones read; mailbox: the Mac and that phone, phone writes need a paying account → `ENTITLEMENT_INACTIVE`; Mac writes need the phone paying); slots (≤ 3 Macs per account → `SLOT_LIMIT`; ≤ 5 replacements per 30 days → `SLOT_REPLACEMENT_LIMIT`; `remove_slot` remembered 24 h, a repeat answers `UNAVAILABLE` until delivery is marked done); pairing (`open_pairing` → `PAIRING_OPENED` to the Mac, slot expiry → `PAIRING_EXPIRED`, pair zones ≤ 1 MiB, no attachments → `FORBIDDEN`); mailbox TTL 14 days; attachments (`create_upload` returns a `https://relay.example.com/v1/blob/<id>` URL, one live record per attachment, overwrite drops the old one); controls (`ENTITLEMENT_EXPIRED` to the phone with empty detail and to each of its Macs with the phone id; `SLOT_REMOVED`; `SUBSCRIPTION_MOVED`); `get_account_state` for phones and Macs; quotas (`MAILBOX_QUOTA_EXCEEDED`, `RECORD_TOO_LARGE`) with test-settable limits.

- [ ] **Step 1: Write the failing tests** (`FakeHostedRelayTests`, driving `handle` directly with requests signed by `Ed25519RelaySigner` and `FakeAppAttest`)
  - `testConditionalSaveOutcomesPerItem`, `testDeleteIsConditionalPerItem`, `testRecordSeqGrowsPerZone`, `testChangesPagesByLimitAndBytes`, `testTokenExpiredAboveLastAndBelowPurgedTombstones`, `testPhoneCannotWriteTheDataZone`, `testOnlyReadersReadTheDataZone`, `testLapsedPhoneWriteIsEntitlementInactive`, `testPairZoneRefusesAttachmentsAndCapsBytes`, `testMailboxRecordsExpireAfter14Days`, `testRemoveSlotAnswersUnavailableUntilDelivered`, `testEntitlementExpiredControlNamesThePhoneForMacs`.
  - Attestation (enforce): `testRegisterWithoutAttestationIsRequired`, `testRegisterHashMismatchFails`, `testAssertionCounterMustGrow`, `testAssertionWithoutStoredKeyFails`, `testWrongSignatureIsUnauthenticatedWhateverTheAttestation`, `testOffModeIgnoresAttestation`, `testExemptMacRegistersWithoutAttestation` (R18).
- [ ] **Step 2: Run, expect failure** — `make kit-test FILTER=FakeHostedRelayTests` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — same — PASS. Lint.
- [ ] **Step 5: Commit** — `test(kit): FakeHostedRelay server model for public CI (#1240)`

### Task 8: `FakeHostedRelay` on the network seams, faults, and the client scenarios

**Depends on:** Task 6, Task 7

**Files:**
- Create: `WatchtowerKit/Sources/WatchtowerHostedRelayTesting/FakeHostedRelay+Network.swift` (`RelayHTTP` and `RelaySocketDialer` over `handle`, blob store, sockets), `FakeHostedRelay+Faults.swift`
- Create: `WatchtowerKit/Tests/WatchtowerHostedRelayTests/Support/RelayBackend.swift` (`RelayBackend.fake` now; `.stand` in Task 13)
- Test: Create `WatchtowerKit/Tests/WatchtowerHostedRelayTests/HostedRelayClientScenarios.swift` (`class HostedRelayClientScenarios: HostedRelayScenarioCase`, not final)

**Interfaces:**
```swift
extension FakeHostedRelay {
    public var http: any RelayHTTP { get }
    public var sockets: any RelaySocketDialer { get }
    // Faults (fake only, R15)
    public func failNext(_ op: String, with code: Relay_V1_ErrorCode, times: Int)   // op = the oneof case name, e.g. "save"
    public func refuseNextDial(status: Int, times: Int)
    public func deploy()                // finish in-flight requests, close every socket 1001 without GoingAway
    public func displace(deviceID: String)  // GoingAway then 1001 on that device's socket
    public func crash(); public func restart()   // cut every connection / come back with the same state
    public func setPongs(_ on: Bool)
    public func silenceSubscribe(zone: String)
    public func expireSessions(of deviceID: String)   // SESSION_EXPIRED then 4001
}
/// Where scenario tests run: `.fake` builds a FakeHostedRelay; `.stand(URL)` (Task 13) the local stand.
enum RelayBackend { case fake(FakeHostedRelay); /* case stand(URL) in Task 13 */ }
class HostedRelayScenarioCase: XCTestCase {   // base: backend = .fake; Task 13 subclasses it for the stand
    func makeClient(kind: Relay_V1_DeviceKind, seed: UInt8) async throws -> HostedRelayClient
    func requireFake(_ why: String) throws -> FakeHostedRelay   // XCTSkip on the stand (R15)
    var stand: any RelayStandControl { get }
}
```
- The fake's socket answers `Hello` (checks the token equals the dial's bearer, else 4001), `Request` frames by id, emits `ZoneChanged` (record inline when ≤ 64 KiB) and `Control` events, only one socket per device (a newer one displaces the older with `GoingAway` + 1001).

- [ ] **Step 1: Write the failing tests** (`HostedRelayClientScenarios: HostedRelayScenarioCase`, the Go interop names)
  - `testReconnectAfterGoingAway`, `testReloginOnSessionExpired`, `testDoReturnsProtocolErrors`, `testResubscribeDropsOnlyRefusedZone`, `testFullEventBufferNeverBlocksReader`, `testOnGoingAwayCallback`, `testNoAckedWriteLostAcrossDeploy` (fake only), `testNoAckedWriteLostAcrossCrash` (fake only), plus `testRegisterLoginAndSaveOnAFreshDevice` and `testLostAppAttestKeyLogsInWithAFreshAttestation` (enforce mode; on the stand attestation is off and the test checks only that the login succeeds).
- [ ] **Step 2: Run, expect failure** — `make kit-test FILTER=HostedRelayClientScenarios` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — `make kit-test FILTER='HostedRelayClientScenarios|FakeHostedRelayTests|HostedRelayConnectionTests'` — PASS. Lint.
- [ ] **Step 5: Commit** — `test(kit): the relay client's Go scenarios against FakeHostedRelay (#1239)`

### Task 9: `HostedRelayTransport` (phone role)

**Depends on:** Task 2, Task 8

**Files:**
- Create: `WatchtowerKit/Sources/WatchtowerHostedRelay/Transport/HostedRelayZones.swift`, `HostedRelayTransport.swift`, `HostedRelayTransport+Pull.swift`, `HostedRelayTransport+Save.swift`, `HostedRelayTransport+Attachments.swift`, `HostedRelayTransport+Errors.swift`, `HostedRelayEvent.swift`
- Modify: `WatchtowerKit/Sources/WatchtowerSync/CloudKitTransport/TransportStore.swift` — `package` access on `enqueueSave`, `enqueueDelete`, `pendingBatch`, `clearPending`, `bufferChanged`, `bufferDeleted`, `stashAsset`; new tables `relay_cursors(zone TEXT PRIMARY KEY, seq INTEGER NOT NULL)` and `relay_records(zone TEXT NOT NULL, name TEXT NOT NULL, record_seq INTEGER NOT NULL, PRIMARY KEY (zone, name))` created with the others (empty on CloudKit stores); `package func bufferRelayPage(zone:changed:deleted:newSeq:)` (events, `relay_records` and the cursor in one transaction), `package func relayCursor(zone:)`, `resetRelayZone(_:)`, `relayRecordNames(zone:)`
- Test: Create `WatchtowerKit/Tests/WatchtowerHostedRelayTests/HostedRelayTransportTests.swift` (`class HostedRelayTransportTests: HostedRelayScenarioCase`, not final: Task 13 subclasses it); `WatchtowerKit/Tests/WatchtowerSyncTests/TransportStoreTests.swift` (relay tables)

**Interfaces:**
```swift
public enum HostedRelayZones {
    public static func data(mac: String) -> String            // "data/<mac>"
    public static func mailbox(mac: String, phone: String) -> String   // "relay/<mac>/<phone>"
    public static func pair(slot: String) -> String           // "pair/<slot>" (Phase 3)
}
public enum HostedRelayEvent: Equatable, Sendable {
    case control(kind: Relay_V1_ControlKind, detail: String)
    case entitlementInactive, forbidden(zone: CloudZoneID), unsupportedVersion
    case attestation(HostedRelayAttestError), reachable(Bool)
}
public actor HostedRelayTransport: LiveTransport, ConditionalTransport, CompactingTransport {
    public init(client: HostedRelayClient, store: TransportStore, macDeviceID: String,
                energy: EnergyCounter? = nil, maxAttachmentBytes: Int64 = 100 << 20)  // the relay's default cap, as Go `MaxAttachmentBytes`
    public nonisolated var relayEvents: AsyncStream<HostedRelayEvent> { get }
}
```
- Zone mapping (R4): `.data` → `data/<mac>` (read), `.relay` → `relay/<mac>/<client.deviceID>` (read and write). A save to `.data` throws `TransportRefusal.forbidden` before any I/O.
- `changes(in:since:)` / `compact(in:keepSince:)`: served by `TransportStore` (R5). `pull()`: for each zone, pages from `relay_cursors` (`changes`, looping on `more`), downloading attachments to the stash first (`get_download` → `RelayHTTP.get` capped at `maxAttachmentBytes`; a redirect or an oversize body fails the page, the cursor stays), then `bufferRelayPage`; `TOKEN_EXPIRED` → `resetRelayZone`, pull from 0, after the last page buffer deletions for known names the resync did not return (R10). Record mapping: `envelope` → `payload`, `name` → `recordName`, `kind` = `WireKind.envelope`, `client_modified_at_ms` → `modifiedAt` and `origin.serverAt` (R7), `record_seq` → `recordSeq`, `deleted` → deletion event.
- Plain `save`/`delete` (R8): enqueue in `pending`; `sendNow()`, `start()` and each `pull()` flush in order — attachments first (`create_upload(zone, size)` → `RelayHTTP.put(url, file, headers)` → save with `attachment_id`), unconditional saves; a failure stops the flush, keeps the rest queued, pulls the zone.
- `ConditionalTransport`: direct `save`/`delete` with `must_not_exist` / `expected_seq`; outcomes by index (a missing, repeated or out-of-range index → `HostedRelayError.undecodable`, nothing reported as saved); per-item refusals map to `TransportRefusal`; after any thrown error the zone is pulled before rethrowing. `delete` with `.absent` → `.refused(.unsupportedPrecondition)` for that item with no request (R6).
- `LiveTransport`: `start()` registers if needed (idempotent), connects with both zones, flushes, pulls; socket `zoneChanged` → pull that zone (R9); `control` → `relayEvents`; reconnect → pull all + `get_account_state`. `stop()` closes the socket. `fetchForPush` = one HTTPS `pull()` (joins one in flight). `availability()` → `.available` after the last op reached the relay, else `.unavailable("relay")`. `setEventHandler`: `MAILBOX_QUOTA_EXCEEDED` → `.quotaExceeded` (R11). `setAccountResetHandler` stores and never fires. `setEngineFetchedHandler` fires after a pull that buffered anything.
- Errors (`+Errors.swift`, the Go hub's `MapError` table for the phone's codes): `MAILBOX_QUOTA_EXCEEDED` → `.quotaExceeded`, `RECORD_TOO_LARGE`/`ATTACHMENT_TOO_LARGE` → `.recordTooLarge`, `RATE_LIMITED`/`TRAFFIC_LIMIT_EXCEEDED` → `.rateLimited`, `ENTITLEMENT_INACTIVE` → `.entitlementInactive` + event, `FORBIDDEN` → `.forbidden` + `.forbidden(zone)` event, `UNSUPPORTED_VERSION` → event, unreachable → `reachable(false)`.

- [ ] **Step 1: Write the failing tests** (`HostedRelayTransportTests: HostedRelayScenarioCase`; a phone and a test Mac on `FakeHostedRelay`, the Mac writing its data zone through `perform`)
  - Twins of `internal/hub/transport/relay/transport_test.go`: `testSaveConditionalOutcomes`, `testZoneTokensPersist` (a new transport on the same store file resumes from the stored cursor), `testTokenExpiredResetsZoneToZero` (+ deletions for purged records, R10), `testSaveErrorRereadsZone`, `testErrorMapping`, `testZoneChangedWithoutRecordMeansPull`, `testUploadThenSaveWithAttachment`, `testDownloadCappedAndRedirectsChecked`, `testMalformedSaveAnswerIsAnError`, `testDeviceIDMatchesIdentity`.
  - New: `testPlainSavesQueueAndFlushInOrder`, `testCursorMovesOnlyWithTheBufferedPage` (an insert failure — `TransportStore.failInserts`, through `@testable import WatchtowerSync` — leaves the cursor), `testADataZoneSaveIsRefusedWithoutARequest`, `testAnAbsentDeleteIsRefusedWithoutARequest`, `testServerAtIsTheWritersClock`, `testEntitlementInactiveIsReportedOnRelayEvents`, `testFetchForPushPullsOverHTTPSWithoutASocket`.
  - `TransportStoreTests.testRelayTablesAreEmptyOnACloudKitStore`.
- [ ] **Step 2: Run, expect failure** — `make kit-test FILTER='HostedRelayTransportTests|TransportStoreTests'` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** — `make kit-test FILTER='HostedRelayTransportTests|TransportStoreTests|CloudKitTransport|ReplicaHydratorTests|RelayFeedTests'` — PASS (the CloudKit and consumer suites prove `TransportStore` is unchanged for them). Lint; guard-file diff empty.
- [ ] **Step 5: Commit** — `feat(kit): HostedRelayTransport, the phone's transport over the hosted relay (#1240)`

### Task 10: The sim model in Swift (tests only)

**Depends on:** Task 9

**Files:**
- Create under `WatchtowerKit/Tests/WatchtowerHostedRelayTests/Sim/`: `SimEnvelope.swift` (port of `sim/transport.go` envelopes and names), `SimTransport.swift` (the sim's `Transport` over `ConditionalTransport` + `changes`; `SimRelayPhoneLeg` over `HostedRelayTransport`, `SimRelayHubLeg` over `HostedRelayClient` with `DEVICE_KIND_MAC`), `SimCloudKit.swift` (port of `sim/fakecloudkit.go`), `SimPhone.swift` (port of `sim/phone.go`), `SimHub.swift` (port of `sim/hub.go`), `SimWorld.swift` (one Mac, N phones, both legs, the shared `ManualRelayClock`, `stand: RelayStandControl`)
- Test: Create `WatchtowerKit/Tests/WatchtowerHostedRelayTests/Sim/SimModelTests.swift`

**Interfaces:**
- `SimWorld(backend:)`, `world.addPhone(paying: Bool) -> SimPhone`, `world.hub`, `world.relayDown()/relayUp()` (fake only: `FakeHostedRelay.crash/restart`; on the stand → `XCTSkip`, R15), `world.advance(_:)`, `world.syncAll()`.
- `SimPhone`: `act(_ payload: String)`, `sync()`, `switchTransport(to:)`, `outbox`, `undelivered`, `retry(_:)`, `epoch`, `transport`. `SimHub`: `applied(from:) -> [String]`, `sync()`, `epoch`, `transport`. Names, kinds, reasons and statuses are the Go sim's strings (`a-<seq>`, `c-<id>`, `transport`, `action`, `echo`, …).
- Port rule: a Go function becomes a Swift method of the same name (camelCase); the bounded-state notes of `sim/README.md` are not implemented (the model is test-only, like Go's).

- [ ] **Step 1: Write the failing tests** (`SimModelTests`): `testEnvelopeRoundTripsAsTheGoSimJSON` (field names and omitted empties as Go's `json` tags), `testAPhoneActionReachesTheHubOverTheRelay` (one action, applied once, echo deleted, mailbox empty), `testAPhoneActionReachesTheHubOverCloudKit`.
- [ ] **Step 2: Run, expect failure** — `make kit-test FILTER=SimModelTests` — FAIL.
- [ ] **Step 3: Implement** the port, file by file against relay@3a99bd7's `sim/*.go`.
- [ ] **Step 4: Run** — same — PASS. Lint.
- [ ] **Step 5: Commit** — `test(kit): Swift port of the relay sim model over HostedRelayTransport (#1240)`

### Task 11: Sim twins — outbox, order, control records

**Depends on:** Task 10

**Files:**
- Test: Create `WatchtowerKit/Tests/WatchtowerHostedRelayTests/Sim/RelaySimOrderTwins.swift` (`class RelaySimOrderTwins: HostedRelayScenarioCase`)

**Interfaces:** consumes Task 10's `SimWorld`.

- [ ] **Step 1: Write the twins** — each a line-by-line port of the Go test body in `sim/sim_interop_test.go` at relay@3a99bd7, with its Go name: `testActionsAppliedInOrderOnce`, `testGapTriggersResendFrom`, `testSkipToMarksUndelivered`, `testHubResendFromRetriedUntilWritten`, `testPhoneSkipToRetriedUntilWritten`, `testRefusedActionWriteRetried`. Each test's doc comment names its sim rule numbers.
- [ ] **Step 2: Run** — `make kit-test FILTER=RelaySimOrderTwins`. A failure here is a defect in Tasks 7–10 (the rules are fixed): fix it there, in this task's commit, and note the cause in the commit message.
- [ ] **Step 3: Lint** — `make lint-swift`.
- [ ] **Step 4: Commit** — `test(kit): sim twins for ordered actions and control records (#1240)`

### Task 12: Sim twins — transport switch and entitlement

**Depends on:** Task 10

**Files:**
- Test: Create `WatchtowerKit/Tests/WatchtowerHostedRelayTests/Sim/RelaySimSwitchTwins.swift` (`class RelaySimSwitchTwins: HostedRelayScenarioCase`), `Sim/RelaySimCensusTests.swift`

- [ ] **Step 1: Write the twins** (Go names, line-by-line ports): `testSwitchToCloudKitDuringRelayOutage` (fake only), `testSwitchToRelayRejectedWithin5Min`, `testSecondPhoneFollowsSwitch`, `testOldEpochActionAfter14DaysResealed`, `testNoCopiesLeftOnRelayAfterSwitch`, `testEntitlementExpiredFallsBackToCloudKit`, `testEntitlementExpiredOtherPayingPhoneKeepsHub`, `testLapsedPhoneActionAppliedBeforeHubKnewIsEchoed`, `testHubActsOnEntitlementControl`, `testStaleActionGetsSwitchAgain`, `testMarkerLeadsReturningPhone`, `testStaleSwitchedIgnored`, `testSwitchedRetriedWhenBothMailboxesFailed`, `testHubOnRelayTellsFreePhone`. Together with Task 11 every `Test*` in `sim/sim_interop_test.go` has a twin (twenty).
- [ ] **Step 2: Run** — `make kit-test FILTER=RelaySimSwitchTwins`; failures handled as in Task 11.
- [ ] **Step 3: Twin census** — `RelaySimCensusTests.testEverySimTestHasATwin` (in this task): a list of the twenty Go names, kept in the test, equals the `test…` methods of `RelaySimOrderTwins` + `RelaySimSwitchTwins` (`XCTestCase.defaultTestSuite` names) with `Test` → `test`.
- [ ] **Step 4: Lint** — `make lint-swift`.
- [ ] **Step 5: Commit** — `test(kit): sim twins for the transport switch and lapsed subscriptions (#1240)`

### Task 13: Local interop against the relay's stand

**Depends on:** Task 11, Task 12

**Files:**
- Create: `scripts/relay-interop.sh`; `Makefile` target `relay-interop` (`.PHONY`)
- Create: `WatchtowerKit/Tests/WatchtowerHostedRelayTests/Support/HTTPRelayStandControl.swift` (`/dev/entitlement`, `/dev/account`, `/dev/pair`, `/dev/expire-mailboxes`; 503 + `Retry-After` retried)
- Modify: `Support/RelayBackend.swift` (`.stand(URL)` from `WATCHTOWER_RELAY_INTEROP_URL`; `URLSessionRelayHTTP`, `URLSessionRelaySocketDialer`, real `SystemRelayClock` for the client, `ManualRelayClock` still drives the sim model's own timers)
- Test: Create `WatchtowerKit/Tests/WatchtowerHostedRelayTests/Interop/HostedRelayInteropTests.swift`: `final class HostedRelayClientInteropTests: HostedRelayClientScenarios`, `HostedRelayTransportInteropTests: HostedRelayTransportTests`, `RelaySimOrderInteropTests: RelaySimOrderTwins`, `RelaySimSwitchInteropTests: RelaySimSwitchTwins` — each overrides the backend with `.stand` and `XCTSkip`s in `setUp` unless the variable is set.

**Interfaces:**
- `scripts/relay-interop.sh <relay checkout>` / `make relay-interop RELAY=../relay`: checks `node`/`npx`; runs `npm ci` in `<relay>/worker` only when `node_modules` is missing; makes a temp dir for state; starts, in its own process group, `npx wrangler dev --port 0 --ip 127.0.0.1 --inspector-port 0 --persist-to <tmp> --show-interactive-dev-session=false --var RELAY_SESSION_SECRET:<openssl rand -hex 32> --var RELAY_ATTEST_MODE:off` from `<relay>/worker` (nothing is written into the relay checkout besides `npm ci`'s ignored `node_modules`); waits ≤ 90 s for `Ready on http://…` and `/healthz`; runs `WATCHTOWER_RELAY_INTEROP_URL=<url> make kit-test FILTER='InteropTests'` to a log; kills the group and removes the temp dir on every exit (`trap`); exits with the tests' code. Prints the relay checkout's HEAD and warns when it differs from the Kit's `VERSION` commit.
- The stand runs attestation off: the client still sends `FakeAppAttest` bytes through the real register/login path (R15); fake-only scenarios skip with the R15 reason.

- [ ] **Step 1: Write** the control, backend and interop classes; `make kit-test FILTER=InteropTests` without the variable → every interop test skipped, exit 0 (public CI behaviour).
- [ ] **Step 2: Run against the stand** — `make relay-interop RELAY=<a clean relay worktree at 3a99bd7> > "${TMPDIR:-/tmp}/p2-interop.log" 2>&1; echo "exit=$?"` — Expected `exit=0`. Each difference between the fake and the stand is fixed in `FakeHostedRelay` (R20) and listed in the commit message; a close-code problem on `URLSessionWebSocketTask` triggers R13's fallback.
- [ ] **Step 3: Lint** — `make lint-swift`.
- [ ] **Step 4: Commit** — `test(kit): local interop of the relay client against the relay stand (#1240)`

### Task 14: Feature note and links

**Depends on:** Task 13

**Files:**
- Create: `docs/features/relay-client.md`
- Modify: `CLAUDE.md` (feature list: one entry after "Mobile companion"), `docs/features/mobile-companion.md` (one line under the Phase 0a seam bullet pointing to the new note)

**Content of `docs/features/relay-client.md`** (English, no ids, no local paths): what Phase 2 ships and what it does not (no app wiring; Phase 3 identity, linking, vouching, Keychain, entitlement); the three Kit targets and why the Desktop links none (R3); the proto pin (`VERSION`, `make relay-proto`, the Go copy pinned to the same commit by `make relay-go`, R14); `HostedRelayClient` rules with the Go numbers; App Attest (seam, attestor, failure paths and their test names, the stand runs with attestation off, Macs do not attest, R2/R18); `HostedRelayTransport` (zone mapping, buffer in `TransportStore`, cursor and `relay_records`, plain vs conditional writes, `TOKEN_EXPIRED` deletions, attachments, error mapping and `relayEvents`, R4–R11); `FakeHostedRelay` and `RelayStandControl`; the twins (client, transport, twenty sim tests) and how to run them on the stand (`make relay-interop RELAY=../relay`, Node, `WATCHTOWER_RELAY_INTEROP_URL`), which scenarios are fake-only (R15); v1 limits (`URLSessionWebSocketTask` close codes, R13; the fake follows the README and the stand wins, R20).

- [ ] **Step 1: Write** the note and the two links.
- [ ] **Step 2: Check** — `bash scripts/leak-check.sh` over the branch's commits (or `make leak-check`), no hits.
- [ ] **Step 3: Commit** — `docs: relay client feature note after Phase 2 (#1239, #1240)`

### Task 15: Phase gate

**Depends on:** Tasks 1–14

- [ ] **Step 1: Kit + Desktop suites** — `make test-swift > "${TMPDIR:-/tmp}/p2-swift.log" 2>&1; echo "exit=$?"` — Expected `exit=0` (the Desktop suite unchanged, then the whole Kit suite, interop classes skipped).
- [ ] **Step 2: Phone** — `make mobile-build SIM='iPhone 17 Pro'` and `make mobile-test SIM='iPhone 17 Pro' > "${TMPDIR:-/tmp}/p2-mobile.log" 2>&1; echo "exit=$?"` — Expected `exit=0` (the app resolves the Kit with swift-protobuf; nothing on the phone changed, R19).
- [ ] **Step 3: iOS build of the new targets** — `cd WatchtowerKit && xcodebuild build -scheme WatchtowerHostedRelay -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO > "${TMPDIR:-/tmp}/p2-ios.log" 2>&1; echo "exit=$?"` (DeviceCheck adapter compiles for iOS) — Expected `exit=0`.
- [ ] **Step 4: Go** — `go test ./internal/hub/transport/relay` and `make test > "${TMPDIR:-/tmp}/p2-go.log" 2>&1; echo "exit=$?"` — Expected `exit=0`.
- [ ] **Step 5: Lint** — `make lint-all` — no new issues; `bash scripts/tests/test-relay-proto.sh`.
- [ ] **Step 6: Boundaries** — guard-file diff empty; `git diff --stat origin/main -- WatchtowerMobile/Sources WatchtowerMobile/NotifyService WatchtowerDesktop/Sources` empty; `grep -rn 'SwiftProtobuf\|WatchtowerHostedRelay' WatchtowerDesktop/Package.swift WatchtowerMobile/project.yml` prints nothing.
- [ ] **Step 7: Interop once more** — `make relay-interop RELAY=<clean relay worktree at the VERSION commit>` — `exit=0` (local only; record the result in the PR description).
- [ ] **Step 8: Commit** any gate fixes — `fix: relay client Phase 2 gate (#1239, #1240)`
