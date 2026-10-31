# Go hub — Phase 1a: hub core on the hosted relay (crypto, sidecar, transport, actions, linking) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Go hub inside the daemon that is byte-compatible with the Kit, owns its own sidecar, talks to the hosted relay, links a phone, and applies that phone's actions in order exactly once with echoes and a durable control queue — verified against an in-memory relay fake and the relay's local stand, in a separate test workspace, beside the Swift hub and touching none of its state.

**Architecture:** New packages under `internal/hub/`: `wire` (sealed JSON payloads), `secure` (Go port of the Kit's hub-side `Secure/`, the single sealing choke point), `identity` (keys + keyring), `state` (`hubstate.db`, own goose provider through `db.OpenSidecar`, single writer, hub lock), `transport` (neutral interface, `memfake`, `relay` over a pinned copy of the relay repo's Go client and generated proto), `actions` (processor, order, echoes, control queue, dispatcher), `link` (QR v4, hello, SAS, keybox, grants), `slices` (publisher core with `device_grant` + `heartbeat`), `hubtest` (Go phone emulator), and the runtime `hub.Run` started by `runSyncDaemon` only when `WATCHTOWER_HUB_DIR` is set. `watchtower hub …` CLI on top; its writes reach a running hub over the control socket `<dir>/hub.sock` described in spec §4 (0600, peer UID check), which goes to the security review with the phase-1a PR. Plan 1b (`2026-10-31-go-hub-phase-1b.md`) plugs handlers, DB-backed slices, publishing on change, `session-host` v2 and Go session start into the seams this plan fixes.

**Tech Stack:** Go 1.26 (`crypto/ecdh`, `crypto/ed25519`, `crypto/hkdf`, `crypto/hpke`, `golang.org/x/crypto/chacha20poly1305`), goose via `db.OpenSidecar`, `github.com/coder/websocket` + `google.golang.org/protobuf` (new direct deps, from the relay client), cobra; Swift only for Kit vector generation (`make kit-test FILTER=…`) and one Desktop vector (`make test-swift FILTER=…`).

**Spec:** `docs/superpowers/specs/2026-10-31-go-hub-design.md` (§5, §6.1, §7, §8 p. 1–3, 5–6, §9 spacing, §10, §12a, §13, §14 row 1). Hub-side rules of the relay client spec (cited "RC §N": `docs/superpowers/specs/2026-10-29-relay-client-design.md` on `feature/relay-client`) §5 p. 4–5, 7–8, 10; §7. Relay contract: the relay repo's `sim/README.md` (sim rules 1–7a), `proto/README.md`, `proto/relay/v1/relay.proto`.

## Split: Plan 1a / Plan 1b

Phase 1 is ~33 reviewable tasks, too many for one controller run. **Seam:** 1a ends with a hub that never reads workbench tables — it links a phone, publishes `device_grant` and `heartbeat`, and orders/echoes actions with only the `probe` handler registered. Everything that reads or writes `watchtower.db` workbench state or a PTY (handlers, DB-backed slices, publishing on change, `session-host` v2, Go session start, `hub recording …`, the plaintext canaries over real payloads, the phase-1 docs) is Plan 1b. The seam types 1b consumes are fixed here: `actions.Dispatcher.Register` + `actions.Handler`, `slices.Source`, `slices.Publisher.PublishSoon`, `hub.Options`, `state` migrations numbered from `00003`. 1a is the E2E red line in isolation (crypto, choke point, ordering, crash safety), so its review is not diluted by workbench semantics.

## Global Constraints

- **Byte compatibility with the Kit** (spec goal 6, §13): envelope header 68 bytes `"WTE" | ver 1 | suite 1 | flags | hub_id 16 | sender_id 16 | epoch u32 BE | seq u64 BE | nonce 12 | class u16 | body_len u32`; classes `data=1 alert=2 keybox=3 hello=4 relayToHub=5 relayToPhone=6`; flags `signed=1 hasAsset=2 padded=4`; AAD = header ‖ zone u8 ‖ name_len u16 ‖ name; signature message `"wt/sig/v1" ‖ AAD ‖ body`; padding buckets `256, 1024, 4096, 16384, 65536`, then 64 KiB multiples, clipped to the cap; `Envelope.maxBytes = 900_000`; HPKE suite X25519-HKDF-SHA256 / HKDF-SHA256 / ChaCha20-Poly1305, infos `"wt/hello/v1" ‖ hub_id ‖ link_nonce` and `"wt/keybox/v1" ‖ hub_id ‖ device_id`; record names `base32lower(HMAC-SHA256(K_meta, "wt/name/v1" ‖ zone ‖ kind_len ‖ kind ‖ id)[0..<16])` (26 chars); SAS v2 and `linkCodeTag` exactly as `KeyDerivation.swift`; asset chunk 1 MiB, nonce `u32 0 ‖ u64 c`, AAD `header ‖ u64 c ‖ u8 last`. Every rule is pinned by Kit-generated vectors (`WatchtowerKit/Tests/Fixtures/e2e/*.json`); CryptoKit Ed25519 and HPKE are randomized, so those bytes are **verified/opened**, never reproduced.
- **Zone bytes `data = 1`, `relay = 2` never change.** The mailbox lane keeps the name "relay"; the hosted relay server is "hosted relay" in comments, plain "relay" in package names under `transport/relay`.
- `hub_id` and device ids print as Swift `uuidString` (uppercase canonical).
- **Hub key AADs (sidecar):** `hub_meta.k_meta_sealed` = ChaChaPoly(wrap, K_meta, AAD `"wt/hub-meta/v1" ‖ hub_id`), `hub_epochs.sealed_keys` = ChaChaPoly(wrap, K_data ‖ K_alert, AAD `"wt/hub-epoch/v1" ‖ hub_id ‖ epoch u32 BE`), stored as CryptoKit `.combined` (nonce 12 ‖ ct ‖ tag 16); `envelope_seq_ceiling` in `hub_meta`, `SeqAllocator` block 1024, first value 1; previous epoch grace 7 days, rotation at 90 days or seq `1 << 28`.
- **Actions (RC §5, sim rules 1–7a):** `action_seq` inside the sealed payload; record `a-<action_seq>` = `RecordName(K_meta, relay, "a", "<device_id>-<action_seq>")`; control `c-<uuid>` = `RecordName(K_meta, relay, "c", "<uuid>")`; apply `last + 1` only, repeat → dropped and echoed, higher → held and `resend_from(last + 1)` written once per gap; echo by overwrite with `expect: seq`; final `applied | failed | expired | cancelled`, non-final `received | held`; `relay_processed` `begun`/`done` stays the exactly-once ledger, `begun` without `done` → `outcome_unknown`, never applied twice; a payload without `action_seq` takes today's path (UUID record name, today's echo) and `device_grant` announces `ordered_actions: 1`; control queue durable per mailbox, retried every pass; relay hygiene = recipient delete + 14-day server TTL.
- Today's hub constants carried over verbatim: `actionMaxAge` 7 days, `sessionRequestMaxAge` 24 h, `maxClockSkew` 300 s, batch limit 200; link `keptCodes` 50, `maxNoncesPerCode` 3, `maxRefusalsPerCode` 10, `maxLinkRefusals` 50, QR lifetime 600 s, `mac_name` ≤ 60; `device_grant` `maxRecords` 20, refusal lifetime 3600 s, revoked lifetime 7 days.
- **Publishing cadence (pinned now, exercised fully in 1b):** debounce 150 ms trailing; full diff every 60 s; minimum spacing per transport 150 ms on the relay (~2 s on CloudKit, phase 3); `data_version` poll 250 ms while a phone was in touch in the last 10 minutes, else 1 s; mailbox pass on the relay = on the WebSocket event.
- Relay client behaviour = RC §7 (already in the copied Go client): `Relay-Protocol-Version: 1`, ping 30 s / pong 10 s, backoff ≤ 60 s with jitter, 1–3 s after 1001, `UNAVAILABLE` retries 0.5 s doubling to 8 s within 30 s, `TOKEN_EXPIRED` → reset that zone's `since_seq` to 0 and pull, resubscribe one by one, pull every zone after reconnect.
- **E2E red line** (spec §3 anti-goals, §13, ask #807): nothing leaves the hub process unless it passed `secure.Sealer`; no key in logs, keys zeroed after use where Go allows, hub dir 0700, files 0600; the identity file refuses looser permissions.
- **Phase-1 isolation** (spec §14 row 1): the hub starts only when `WATCHTOWER_HUB_DIR` is set (absolute, not under `config.AppSupportDir()/MobileHub`), `WATCHTOWER_RELAY_ORIGIN` is set, **and** `WATCHTOWER_HUB_TEST_WORKSPACE` (which must start with `hubtest-`, so a live workspace can never pass) names the daemon's own active workspace (enforced, not assumed: so every DB read — heartbeat accounts in 1a, slices and handlers in 1b — comes from the test workspace's database); never imports, reads or writes the Swift hub's `MobileHub/`, Keychain items or CloudKit state; one hub per state dir (`hub.lock`).
- `FILES-01`: log lines carry ids, counts and error classes only (`logredact`), never payload text, names or keys.
- **Public-repo hygiene:** fixtures use the Kit's synthetic `a..b` byte runs, `example.com`, `acme`; no real ids, names, hostnames or absolute local paths; relay paths are `RELAY=../relay`.
- **Migrations:** the sidecar is **not** `watchtower.db`: its schema lives in `internal/hub/state/migrations/*.sql` as its own goose provider (like `internal/agentlogdb`); no Go migration files; nothing in `internal/db/migrations`, `schema.sql` or the Desktop test schema changes in this plan.
- Inner loop per task only (`go test ./internal/hub/<pkg>`, `make kit-test FILTER=…`, `make test-swift FILTER=…`, `make lint-diff`, `make lint-swift` when Swift changes); the full gate runs once, in Task 16. No `-count=1`; tests that spawn processes reap their process group in `t.Cleanup`.

## Review Focus

Failure modes no existing test covers; each test lands in the named task.

1. **Unsealed bytes reaching a transport.** A zero-value `secure.Record`, or a payload built outside the sealer, must be refused by every transport before any I/O. → Task 4 `TestRecord_ZeroValueIsNotSealed`, Task 7 `TestMemfake_RefusesUnsealedRecord`, Task 8 `TestRelayTransport_RefusesUnsealedRecord`.
2. **Crash windows in the ledger.** A crash after a non-idempotent apply but before the echo, or between the ledger write and the per-phone order write, must never re-apply or skip. → Task 9 `TestCrashMidApplyEchoesOutcomeUnknownOnce`, `TestOrderAndLedgerCommitInOneTransaction`.
3. **A full resync replays the mailbox.** `TOKEN_EXPIRED` (or a lost zone token) resets `since_seq` to 0 and every surviving record comes back: all must be repeats. → Task 9 `TestTokenExpiredResyncAppliesNothingTwice`.
4. **Two hubs, or a phase-1 hub on real state.** → Task 14 `TestSecondHubRefusedWhileLocked`, `TestDevFlagRefusesSwiftHubDir`, `TestHubOffWithoutRelayOrigin`, `TestHubRefusesWithoutMatchingTestWorkspace` (also: a matching name without the `hubtest-` prefix is refused), `TestHubStartWaitsForACLIHoldingTheLock`.
5. **Keys sealed for a phone the owner did not confirm.** A confirm that races an expired code, an unlink or a refusal must seal no `KeyboxKeys`. → Task 11 `TestConfirmAfterExpiryOrUnlinkSealsNoKeys`.

---

### Task 1: Shared phone ↔ hub contract fixture and `hub/wire`

**Files:**
- Create: `WatchtowerKit/Tests/Fixtures/link/hub_contract_cases.json`
- Create: `internal/hub/wire/wire.go` (`Time`, `Marshal`), `internal/hub/wire/grant.go` (`DeviceGrant`), `internal/hub/wire/link.go` (`LinkPayload`), `internal/hub/wire/payloads.go` (`ActionRequest`, `Control`, `Heartbeat`, `DeviceHello`, `Keybox`, `KeyboxKeys`, status/kind constants)
- Test: `internal/hub/wire/contract_test.go`, `internal/hub/wire/wire_test.go`
- Create: `WatchtowerKit/Tests/WatchtowerSyncTests/HubContractFixtureTests.swift`

**Interfaces:**
- Consumes: Kit `DeviceGrant`, `LinkPayload`, `RelayCoder` (behaviour to match).
- Produces:
  ```go
  package wire
  type Time struct{ time.Time }            // JSON number of seconds since 1970 (Swift .secondsSince1970), fraction kept
  func Marshal(v any) ([]byte, error)     // RelayCoder twin: sorted object keys, no HTML escaping
  type DeviceGrant struct {               // json tags snake_case; nil pointer = absent key
      DeviceID, HubID, Name, Scope string; Linked bool
      LinkRefused *string; LinkedAt *Time; TypingAllowed, StartSessionsAllowed bool
      StartSessionsGranted *bool; PermissionsAllowed *bool /* true or absent */
      DecidedAt *Time; AwaitingConfirmation *bool; ConfirmNonce, LinkCodeTag *string; Revoked *bool
      OrderedActions *int `json:"ordered_actions,omitempty"`
      Transports []string `json:"transports,omitempty"`
      RelayDeviceID string `json:"relay_device_id,omitempty"`
      RelayAuthPub string `json:"relay_auth_pub,omitempty"`
  }
  const LinkPayloadVersion = 4; const LinkLifetime = 600 * time.Second; const MaxMacNameLength = 60
  type LinkPayload struct { V int; Container, HubID, MacName, OwnerUser, Nonce string; Iat, Exp int64
      DataShare, RelayShare *string; HubSig, HubKX string
      Transport, RelayDeviceID, RelayAuthPub string; Transports []string }
  func (p LinkPayload) URL() (string, error)          // watchtower://link?d=<base64url(json)>
  func ParseLinkURL(s string) (LinkPayload, error)    // ErrNotALink, ErrBadEncoding, ErrMissingField, ErrNewerVersion, ErrOlderVersion, ErrBadHubKey
  const TransportRelay, TransportCloudKit = "relay", "cloudkit"
  ```
- **Depends on:** none

- [ ] **Step 1: Write the fixture.** One JSON object `{"device_grant": [...], "link_payload": [...]}`; each case `{name, json | url, expect, kit}` where `expect` holds the decoded fields and `kit` what today's Kit must do. Cases: `desktop_awaiting` (awaiting + `confirm_nonce` + `link_code_tag` + `ordered_actions:1` + `transports:["cloudkit","relay"]` + `relay_device_id` + `relay_auth_pub`), `headless_linked` (`transports:["relay"]`), `revoked`, `old_hub_no_new_fields` (no `ordered_actions`: phone stays on the old path), `unknown_future_key` (`"future_field": 1` ignored); link: `v4_desktop` (shares present), `v4_headless` (no shares, `transports:["relay"]`), `v5_newer` (`error: newer_version`), `v3_older` (`error: older_version`), `zero_hub_key` (`error: bad_hub_key`). Synthetic keys from the Kit's `0x41…0x60` style runs.
- [ ] **Step 2: Failing Go test** `TestHubContractFixture` (reads `../../../WatchtowerKit/Tests/Fixtures/link/hub_contract_cases.json`):
  ```go
  for _, c := range f.DeviceGrant { var g wire.DeviceGrant; json.Unmarshal(c.JSON, &g); assertFields(t, g, c.Expect) }
  for _, c := range f.LinkPayload { p, err := wire.ParseLinkURL(c.URL); if c.Error != "" { require.ErrorIs(err, errFor(c.Error)) } else { assertFields(t, p, c.Expect); u, _ := p.URL(); p2, _ := wire.ParseLinkURL(u); require.Equal(p, p2) } }
  ```
  plus `TestMarshal_SortedKeysUnixSeconds` (`{"b":1,"a":wire.Time(1730000000.5)}` → `{"a":1730000000.5,"b":1}`; whole seconds print without fraction), `TestDeviceGrant_PermissionsFalseIsAbsent`.
- [ ] **Step 3:** `go test ./internal/hub/wire` → FAIL (package missing).
- [ ] **Step 4: Implement** the types above; `ParseLinkURL` checks scheme `watchtower`, host `link`, param `d`, version probe first (newer/older before field checks), hub keys = base64url of 32 non-zero bytes; `container`/`owner_user` optional in v4 (see gap list in the hand-off).
- [ ] **Step 5: Failing Kit test** `HubContractFixtureTests`: `testDeviceGrantCasesDecodeAndIgnoreNewKeys` (`RelayCoder.makeDecoder()` → `DeviceGrant`, every Kit-known field equals `expect`, decoding never throws on the new keys), `testAV4LinkIsRefusedAsNewerByTodaysPhone` (`LinkPayload.parse` → `.failure(.newerVersion)` for every v4 case — the relay client spec's Phase 3 replaces this with field checks).
- [ ] **Step 6:** `go test ./internal/hub/wire` and `make kit-test FILTER=HubContractFixtureTests` → PASS; `make lint-diff`, `make lint-swift`.
- [ ] **Step 7: Commit** `hub: shared device_grant / LinkPayload v4 fixture and wire types`.

### Task 2: Kit vectors for every remaining E2E rule

**Files:**
- Modify: `WatchtowerKit/Tests/WatchtowerSyncTests/EnvelopeTests.swift` (add `alert` case to `EnvelopeVectors`)
- Modify: `WatchtowerKit/Tests/WatchtowerSyncTests/E2EKeyDerivationTests.swift` (add `linkCodeTag`)
- Create: `WatchtowerKit/Tests/WatchtowerSyncTests/E2EPaddingVectorTests.swift`, `WatchtowerKit/Tests/WatchtowerSyncTests/HPKEEnvelopeVectorTests.swift`
- Create (generated): `WatchtowerKit/Tests/Fixtures/e2e/padding.json`, `WatchtowerKit/Tests/Fixtures/e2e/hpke-envelope.json`; regenerated: `envelope.json`, `kdf.json`
- Modify: `Makefile` (`e2e-vectors` target)

**Interfaces:**
- Consumes: `E2EFixtures.check`, `E2EFixtureKeys`, `WT_E2E_REGENERATE=1`.
- Produces: frozen JSON the Go golden tests read: `padding.json` `{"cases":[{"length":N,"cap":C,"padded":P|null}]}` over lengths `0,1,255,256,257,1023,65536,65537,131072, cap, cap+1` for `frameCap(signed:true|false)`; `envelope.json` gains `alert` (class 2, signed, `K_alert` = `0xD0…0xEF`, zone data); `hpke-envelope.json` `{"hello": {...}, "keybox": {...}}` each with `envelope` hex, `zone`, `wireName`, `info` hex, `kind`, `id`, `payload` hex — a hello sealed with the fixture phone keys to `hub_kx`, a keybox sealed by `hub_sig` to `dev_kx` with a `Keybox` JSON payload (grant + keys).
- **Depends on:** none

- [ ] **Step 1: Failing Kit tests** `testPaddingVectors`, `testAlertEnvelopeVector`, `testLinkCodeTagVector`, `testHelloAndKeyboxVectorsOpen` (each `E2EFixtures.check(...)`; the HPKE test opens the stored envelope with `SealedBox.open` instead of comparing bytes, since HPKE is randomized).
- [ ] **Step 2:** `make kit-test FILTER='E2EPaddingVectorTests|HPKEEnvelopeVectorTests|EnvelopeTests|E2EKeyDerivationTests'` → FAIL (fixtures missing / mismatched).
- [ ] **Step 3: Implement** the vector structs and the `e2e-vectors` target:
  ```make
  e2e-vectors:  ## regenerate the Kit E2E vectors (expected XCTFail "regenerated"), then verify
  	-WT_E2E_REGENERATE=1 $(MAKE) kit-test FILTER='$(E2E_VECTOR_TESTS)'
  	$(MAKE) kit-test FILTER='$(E2E_VECTOR_TESTS)'
  ```
  Existing deterministic fields (`header`, `body`, `recordNames`, `relayKeys`, `sas`) must come out unchanged; `git diff` of `envelope.json`/`kdf.json` shows only new keys and new random signatures.
- [ ] **Step 4:** `make e2e-vectors` → second run PASS; `make lint-swift`.
- [ ] **Step 5: Commit** `kit: E2E vectors for padding, alert envelopes, link code tag, hello/keybox`.

### Task 3: `hub/secure` primitives — byte for byte with the Kit

**Files:**
- Create: `internal/hub/secure/{id.go,wirebytes.go,kdf.go,padding.go,frame.go,envelope.go,symmetric.go,asset.go,seq.go,rollback.go,errors.go}`
- Test: `internal/hub/secure/vectors_test.go`, `internal/hub/secure/frame_test.go`, `internal/hub/secure/seq_test.go`
- Delete: `internal/mobilee2e/` (its three checks move into `vectors_test.go` unchanged in meaning)

**Interfaces:**
- Produces:
  ```go
  package secure
  type ID [16]byte; func ParseID(s string) (ID, error); func (ID) String() string // uppercase canonical
  type Zone uint8; const ( ZoneData Zone = 1; ZoneRelay Zone = 2 )
  type Direction string; const ( PhoneToHub Direction = "p2h"; HubToPhone Direction = "h2p" )
  func RelayKey(own *ecdh.PrivateKey, peer *ecdh.PublicKey, linkNonce []byte, hub, device ID, epoch uint32, dir Direction) ([]byte, error)
  func RecordName(metaKey []byte, z Zone, kind, id string) string
  func DeviceID(sigPub ed25519.PublicKey) ID
  func LinkCodeTag(linkNonce []byte) string
  func SAS(hub ID, linkNonce []byte, hubSig ed25519.PublicKey, hubKX *ecdh.PublicKey, devSig ed25519.PublicKey, devKX *ecdh.PublicKey, confirmNonce []byte) string
  const ConfirmNonceLength = 32
  var Buckets = []int{256, 1024, 4096, 16384, 65536}
  func PaddedLength(n, cap int) (int, bool)
  type AssetHeader struct{ AssetID ID; ChunkSize uint32; TotalLength uint64; ChunkCount uint32 } // 37 bytes "WTA"
  type AssetDescriptor struct{ Key [32]byte; Header AssetHeader; PlaintextDigest [32]byte }       // 101 bytes
  type InnerFrame struct{ Kind, ID, NotifyLevel string; Asset *AssetDescriptor; Payload []byte }
  func (f InnerFrame) EncodedLength() int; func (f InnerFrame) Encode(paddedTo int) ([]byte, error); func ParseInnerFrame(b []byte) (InnerFrame, error)
  type EnvelopeClass uint16 // ClassData=1 … ClassRelayToPhone=6
  type Header struct{ Flags uint8; Hub, Sender ID; Epoch uint32; Seq uint64; Nonce [12]byte; Class EnvelopeClass; BodyLen uint32 }
  const HeaderLen = 68; const MaxEnvelopeBytes = 900_000
  type Context struct{ Zone Zone; WireName string }
  func FrameCap(signed bool) int
  func SealSymmetric(f InnerFrame, c EnvelopeClass, key []byte, hub, sender ID, epoch uint32, seq uint64, ctx Context, signer ed25519.PrivateKey /*nil = unsigned*/, nonce []byte /*nil = random*/) ([]byte, error)
  func OpenSymmetric(raw []byte, accepting []EnvelopeClass, ctx Context, verifier ed25519.PublicKey, key func(Header) ([]byte, error)) (Header, InnerFrame, error)
  const ChunkSize uint32 = 1 << 20
  func EncryptAsset(plain []byte, assetID ID, key []byte, chunkSize uint32) ([]byte, AssetDescriptor, error)
  func DecryptAsset(sealed []byte, d AssetDescriptor) ([]byte, error)
  func EncryptAssetFile(src, dst string, assetID ID) (AssetDescriptor, error) // one chunk resident, temp + rename, fresh key
  type SeqAllocator struct{…}; func NewSeqAllocator(block uint64, load func() (uint64, error), store func(uint64) error) *SeqAllocator; func (a *SeqAllocator) Next() (uint64, error)
  type Verdict int; const ( Newer Verdict = iota; Same; Older )
  type RollbackGuard interface{ Check(wire string, sender ID, epoch uint32, seq uint64) (Verdict, error); Record(wire string, sender ID, epoch uint32, seq uint64) error }
  var ErrTooShort, ErrBadMagic, ErrUnsupportedVersion, ErrUnsupportedSuite, ErrUnknownClass, ErrLengthMismatch, ErrSignatureMissing, ErrSignatureInvalid, ErrAuthenticationFailed, ErrFrameMalformed, ErrSignatureRequired, ErrOversized, ErrWrongClass error
  ```
- **Depends on:** Task 2

- [ ] **Step 1: Failing tests** (fixtures read from `../../../WatchtowerKit/Tests/Fixtures/e2e/`):
  - `TestKitVectors_KDF`: `RecordName` for `data/owner_ask/42`, `data/workbench/7`, `relay/action/<uuid>`; `RelayKey` for `p2h/1 h2p/1 p2h/2 h2p/2`; `DeviceID == "880B6D06-8852-6316-76C4-9A1A29E1EB29"`; `SAS == "3378"`; `LinkCodeTag` equal.
  - `TestKitVectors_Envelope`: for `data`, `alert`, `relayToHub`, `relayToPhone`: `SealSymmetric` with the fixture nonce `0x50…0x5B` reproduces `header` and `body` hex exactly; the stored signature verifies under `hub_sig`; `OpenSymmetric` returns the fixture frame.
  - `TestKitVectors_Padding`: every `padding.json` case.
  - `TestKitVectors_Asset`: descriptors and sealed chunks reproduce for chunk sizes 0/16/40; `DecryptAsset` round-trips; one flipped bit → `ErrAuthenticationFailed`.
  - `TestEnvelope_StrictParse`: unknown flag bit → `ErrFrameMalformed`; version 2 → `ErrUnsupportedVersion`; `len > 900_000` → `ErrOversized`; moving the envelope to another wire name or zone → `ErrAuthenticationFailed`; `data`/`alert` without verifier → `ErrSignatureRequired`.
  - `TestInnerFrame_TrailingNonZeroIsMalformed`, `TestSeqAllocator_FirstIsOneAndCeilingPersistsPerBlock` (block 1024: first `Next()` stores 1025, values 1..1024 need no store).
- [ ] **Step 2:** `go test ./internal/hub/secure` → FAIL.
- [ ] **Step 3: Implement** as the Swift sources (`Padding.swift`, `KeyDerivation.swift`, `Envelope.swift`, `InnerFrame.swift`, `EnvelopeSealer.swift`, `ChunkedAssetCipher.swift`, `SeqAllocator.swift`, `RollbackGuard.swift`, `WireBytes.swift`); one error per Swift case; open failures inside AEAD collapse to `ErrAuthenticationFailed` (no detail leaks). Remove `internal/mobilee2e`.
- [ ] **Step 4:** `go test ./internal/hub/secure` → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `hub/secure: Kit-compatible envelope, KDF, padding, frames, assets`.

### Task 4: HPKE hello/keybox, the record sealer (choke point) and the reverse vectors

**Files:**
- Create: `internal/hub/secure/hpke.go`, `internal/hub/secure/record.go` (`Record`, `KeySource`, `Sealer`, `Opener`, naming)
- Test: `internal/hub/secure/hpke_test.go`, `internal/hub/secure/record_test.go`
- Create (generated by `go test ./internal/hub/secure -run TestWriteGoSealed -update`): `internal/hub/secure/testdata/go-sealed.json`
- Create: `WatchtowerKit/Tests/WatchtowerSyncTests/GoSealedEnvelopeTests.swift`

**Interfaces:**
- Produces:
  ```go
  func HelloInfo(hub ID, linkNonce []byte) []byte
  func KeyboxInfo(hub, device ID) []byte
  func SealHPKE(f InnerFrame, c EnvelopeClass, to *ecdh.PublicKey, info []byte, hub, sender ID, epoch uint32, seq uint64, ctx Context, signer ed25519.PrivateKey) ([]byte, error) // hello/keybox only, always signed + padded, cap FrameCap(true)-32
  func OpenHPKE(raw []byte, c EnvelopeClass, recipient *ecdh.PrivateKey, info []byte, ctx Context, verifier ed25519.PublicKey) (Header, InnerFrame, error) // keybox requires verifier

  // The only value a transport accepts. Unexported fields: a literal outside this package is the zero value, which Sealed() reports false.
  type Record struct{ zone, wireName string; envelope []byte; assetPath string; sealed bool }
  func (r Record) Zone() string; func (r Record) WireName() string; func (r Record) Envelope() []byte; func (r Record) AssetPath() string; func (r Record) Sealed() bool

  type KeySource interface {
      HubID() ID; CurrentEpoch() (uint32, error); NextSeq() (uint64, error)
      DataKey(epoch uint32) ([]byte, error); AlertKey(epoch uint32) ([]byte, error); MetaKey() ([]byte, error)
      RelayKey(dir Direction, device ID, epoch uint32) ([]byte, error); AcceptsRelayEpoch(epoch uint32, device ID) (bool, error)
      Signer() ed25519.PrivateKey; Agreement() *ecdh.PrivateKey; KeyboxRecipient(device ID) (*ecdh.PublicKey, error)
  }
  type Sealer struct{…}; func NewSealer(k KeySource) *Sealer
  func (s *Sealer) WireName(z Zone, plain string) (string, error) // SecureTransport rules: "heartbeat" stays; device_grant-<id> → keybox-<id>; hello-<id> stays; else RecordName(K_meta, z, kind, id) split at first '-'
  func (s *Sealer) Data(zone, plain, notify string, payload []byte, asset *AssetDescriptor, assetPath string) (Record, error) // class data, signed
  func (s *Sealer) Alert(zone, plain string, payload []byte) (Record, error)                                                  // class alert, signed
  func (s *Sealer) ToPhone(zone string, device ID, wireName, kind, id string, payload []byte) (Record, error)                 // class relayToPhone, h2p key, unsigned
  func (s *Sealer) Keybox(zone string, device ID, payload []byte) (Record, error)                                              // HPKE to KeyboxRecipient(device)
  type Opened struct{ Sender ID; Epoch uint32; Seq uint64; Frame InnerFrame; Verdict Verdict }
  type Opener struct{…}; func NewOpener(k KeySource, g RollbackGuard) *Opener
  func (o *Opener) FromPhone(zone, wireName string, envelope []byte) (Opened, error) // relayToHub, accepted epoch, rollback Check only — never Record: the processor records the mark inside its own transaction (Task 9)
  func (o *Opener) OwnEcho(zone, wireName string, envelope []byte) (Opened, error)   // the hub's own relayToPhone record read back
  func (o *Opener) Hello(zone, wireName string, envelope []byte, linkNonce []byte) (Header, InnerFrame, error)
  var ErrUnsealed = errors.New("secure: record did not pass the sealer")
  ```
- **Depends on:** Task 3

- [ ] **Step 1: Failing tests:**
  - `TestOpener_FromPhoneNeverRecords` (two `FromPhone` calls on the same record both return `Newer`; `relay_seen` untouched).
  - `TestHPKE_RFC9180A21` (the existing `hpke-rfc9180-a21.json`), `TestKitVectors_HelloAndKeyboxOpen` (`hpke-envelope.json`: hello opens with `hub_kx` + `HelloInfo`; keybox opens with `dev_kx` + `KeyboxInfo`, verifies `hub_sig`; moved wire name → `ErrAuthenticationFailed`).
  - `TestRecord_ZeroValueIsNotSealed` (`secure.Record{}.Sealed() == false`) — Review Focus 1.
  - `TestSealer_WireNames` (`heartbeat` → `heartbeat`, `device_grant-<id>` → `keybox-<id>`, `hello-<id>` → itself, `target-7` → `RecordName(meta, data, "target", "7")`, a delete by plain name maps to the same wire name).
  - `TestOpener_RollbackRefusesOlderAndSame` (`Older` refused; `Same` reported as `Same` for the processor's repeat path), `TestOpener_UnacceptedEpochRefused`.
  - `TestWriteGoSealed` (with `-update`): writes `data`, `alert`, `relayToPhone` and `keybox` envelopes sealed by Go from the Kit fixture keys.
- [ ] **Step 2:** `go test ./internal/hub/secure` → FAIL.
- [ ] **Step 3: Implement** with stdlib `crypto/hpke` (mode base, the three suite ids above; `enc` 32 bytes prepended to the body as in `SealedBox.swift`). The fixed `InMemoryKeySource` for tests lives in `record_test.go`.
- [ ] **Step 4: Kit reverse test** `GoSealedEnvelopeTests.testEveryGoSealedRecordOpensInTheKit` (`EnvelopeSealer.openSymmetric` / `SealedBox.open` over `../../../internal/hub/secure/testdata/go-sealed.json`; frames equal the stored plaintext).
- [ ] **Step 5:** `go test ./internal/hub/secure`, `make kit-test FILTER=GoSealedEnvelopeTests` → PASS; `make lint-diff`, `make lint-swift`.
- [ ] **Step 6: Commit** `hub/secure: HPKE hello/keybox, the sealing choke point, Go→Kit vectors`.

### Task 5: `hub/state` — the sidecar in Go, single writer, hub lock

**Files:**
- Create: `internal/hub/state/state.go` (`Open`, `Store`, `WithTx`), `internal/hub/state/lock.go`, `internal/hub/state/{meta.go,ledger.go,devices.go,keys.go,link.go,slices.go,control.go,tokens.go}`
- Create: `internal/hub/state/migrations/00001_swift_baseline.sql`, `internal/hub/state/migrations/00002_go_hub.sql`
- Test: `internal/hub/state/state_test.go`, `internal/hub/state/lock_test.go`, `internal/hub/state/swift_file_test.go`

**Interfaces:**
- Consumes: `db.OpenSidecar(path string, migrations fs.FS) (*sql.DB, error)`.
- Produces:
  ```go
  package state
  type Store struct{…}
  func Open(dir string) (*Store, error)       // <dir>/hubstate.db; dir created 0700, file 0600; plaintext (no SQLCipher key), like today's GRDB file
  func (s *Store) WithTx(ctx context.Context, fn func(*sql.Tx) error) error // BEGIN IMMEDIATE
  func (s *Store) Close() error
  var ErrLocked = errors.New("hub: another hub holds this state dir")
  type Lock struct{…}; func AcquireLock(dir string) (*Lock, error); func (l *Lock) Release() error // <dir>/hub.lock, flock LOCK_EX|LOCK_NB, pid written
  // hub_meta keys
  const MetaHubID, MetaEnabledAt, MetaKMetaSealed, MetaSeqCeiling, MetaHubImpl, MetaEnabled, MetaDisplayName = "hub_id", "enabled_at", "k_meta_sealed", "envelope_seq_ceiling", "hub_impl", "enabled", "display_name"
  func (s *Store) Meta(key string) (string, bool, error); func (s *Store) SetMeta(key, value string) error
  // relay_processed (exactly-once ledger)
  func Begin(tx *sql.Tx, record string, at time.Time) error
  func MarkDone(tx *sql.Tx, record, outcome string, echo []byte, doneSeq *uint64, at time.Time) error
  func (s *Store) Phase(record string) (phase string, outcome string, echo []byte, err error) // "", "begun", "done"
  // devices
  type Device struct{ ID string; Name, Scope string; LinkedAt time.Time; SigningKey, AgreementKey []byte; LinkNonce string
      TypingAllowed, TypingRequested, PermissionsAllowed, PermissionsRequested, StartSessionsAllowed, StartSessionsGranted bool
      LastAppliedActionSeq uint64; Ordered bool; RelayDeviceID string; ResendRequestedFrom uint64 }
  func (s *Store) Devices() ([]Device, error); func (s *Store) Device(id string) (Device, bool, error)
  func SetLastApplied(tx *sql.Tx, device string, seq uint64) error
  // control queue (sealed envelopes only)
  type Control struct{ ID int64; Mailbox, RecordName, Kind string; Envelope []byte; Expect string; ExpectSeq uint64; Attempts int }
  func Enqueue(tx *sql.Tx, c Control) error; func (s *Store) PendingControls(mailbox string) ([]Control, error); func (s *Store) ControlDone(id int64) error; func (s *Store) ControlFailed(id int64, class string) error // writes last_error_class
  func (s *Store) HoldAction(device string, seq uint64, record string, envelope []byte) error; func (s *Store) HeldActions(device string) ([]Held, error); func DropHeld(tx *sql.Tx, device string, seq uint64) error
  func (s *Store) ZoneToken(zone string) (uint64, error); func (s *Store) SetZoneToken(zone string, since uint64) error
  func RecordSeen(tx *sql.Tx, wire, sender string, epoch uint32, seq uint64) error // relay_seen inside the caller's transaction (the rollback mark)
  ```
- **Depends on:** none

- [ ] **Step 1: Write `00001_swift_baseline.sql`:** every table and column `HubSyncState.createSchema` + `createLinkTables` + `createKeyTables` + `createSliceAssetTable` produce today, **with** the columns those functions add by `ALTER TABLE` folded in, all as `CREATE TABLE IF NOT EXISTS` / `CREATE INDEX IF NOT EXISTS` (so the same file applies to an adopted Swift sidecar in phase 3): `slice_state(+wire_name)`, `hub_meta`, `work_alerts`, `relay_processed(+echo, done_seq)`, `ask_answer_deliveries`, `phone_recordings`, `session_reports`, `session_milestones` + index, `held_session_lines`, `link_codes(+confirm_nonces_drawn)`, `devices(+typing_requested, permissions_allowed, permissions_requested, start_sessions_granted, signing_key, agreement_key, link_nonce, last_seq)`, `link_refusals(+agreement_key)`, `hub_epochs`, `pending_devices(+typing_requested, confirm_nonce, start_sessions)`, `revoked_devices(+name, scope)`, `relay_seen`, `slice_assets`, `slice_state_by_wire`. Down = drop nothing (comment why: the baseline may be an adopted file).
- [ ] **Step 2: Write `00002_go_hub.sql`:** `ALTER TABLE devices ADD COLUMN last_applied_action_seq INTEGER NOT NULL DEFAULT 0`, `ordered INTEGER NOT NULL DEFAULT 0`, `relay_device_id TEXT`, `resend_requested_from INTEGER NOT NULL DEFAULT 0`; `control_queue(id INTEGER PRIMARY KEY, mailbox TEXT NOT NULL, record_name TEXT NOT NULL, kind TEXT NOT NULL, envelope BLOB NOT NULL, expect TEXT NOT NULL CHECK (expect IN ('none','absent','seq')), expect_seq INTEGER, attempts INTEGER NOT NULL DEFAULT 0, last_error_class TEXT, created_at REAL NOT NULL)` (an error class only, never error text: new sidecar columns hold no content, spec §8 p. 4a); `held_actions(device_id TEXT NOT NULL, action_seq INTEGER NOT NULL, record_name TEXT NOT NULL, envelope BLOB NOT NULL, held_at REAL NOT NULL, PRIMARY KEY (device_id, action_seq))`; `zone_tokens(zone TEXT PRIMARY KEY, since_seq INTEGER NOT NULL)`.
- [ ] **Step 3: Failing tests:** `TestOpen_CreatesDirAndFilePrivate` (0700/0600), `TestSwiftShapedFileMigrates` (a file created with the Swift `CREATE TABLE` text copied into the test, including a row in `devices`, opens and gains the `00002` columns with the row intact), `TestLedger_BeginThenDone`, `TestSecondLockRefused` (`AcquireLock` twice → second `ErrLocked`; after `Release` it succeeds; a child process holding it is reaped in `t.Cleanup`), `TestControlQueueStoresSealedOnly` (Enqueue with an empty envelope → error).
- [ ] **Step 4:** `go test ./internal/hub/state` → FAIL.
- [ ] **Step 5: Implement.** `Open` checks the dir mode and tightens it; the store is the sidecar's only writer (Desktop reads it read-only in phase 3).
- [ ] **Step 6:** `go test ./internal/hub/state` → PASS; `make lint-diff`.
- [ ] **Step 7: Commit** `hub/state: hubstate.db as its own goose provider, hub lock`.

### Task 6: `hub/identity` — keys, file store, keyring

**Files:**
- Create: `internal/hub/identity/{identity.go,filestore.go,keyring.go}`
- Test: `internal/hub/identity/{filestore_test.go,keyring_test.go}`
- Create: `WatchtowerDesktop/Tests/MobileHub/HubKeyringVectorTests.swift`; generated `internal/hub/identity/testdata/swift-keyring.json`

**Interfaces:**
- Consumes: `secure.KeySource`, `secure.RollbackGuard`, `state.Store`.
- Produces:
  ```go
  package identity
  type Identity struct{ Signing ed25519.PrivateKey; Agreement *ecdh.PrivateKey; Wrap [32]byte; RelayAuth ed25519.PrivateKey }
  func New() (Identity, error); func (i *Identity) Zero()
  type Store interface{ Load() (Identity, error); Save(Identity) error }
  type FileStore struct{ Path string } // <hub dir>/identity.key, 0600, refuses a looser mode (ErrInsecureMode); phase 3 adds a Keychain store
  var ErrNoIdentity, ErrInsecureMode error
  func RelayDeviceID(pub ed25519.PublicKey) string // = vendored client.DeviceID (Task 8); until then lower base32 unpadded SHA-256
  const PreviousEpochGrace = 7 * 24 * time.Hour; const RotationAge = 90 * 24 * time.Hour; const RotationSeqCap uint64 = 1 << 28
  type Reason string // "age", "cap", "unlink", "manual"
  type Keyring struct{…} // implements secure.KeySource and secure.RollbackGuard (relay_seen)
  func NewKeyring(id Identity, st *state.Store, now func() time.Time) (*Keyring, error) // ensures hub_id (uppercase UUID), K_meta, epoch 1
  func (k *Keyring) Rotate(r Reason) error; func (k *Keyring) RotateIfDue() (bool, error)
  func (k *Keyring) KeyboxKeys() (wire.KeyboxKeys, error) // current + previous epoch within grace
  func (k *Keyring) SealLocal(label string, plain []byte) ([]byte, error) // ChaChaPoly(wrap, plain, AAD "wt/hub-local/v1" ‖ hub_id ‖ label), .combined layout — for sidecar content columns (Plan 1b)
  func (k *Keyring) OpenLocal(label string, sealed []byte) ([]byte, error)
  ```
- **Depends on:** Task 3, Task 5

- [ ] **Step 1: Desktop vector.** `HubKeyringVectorTests.testEmitSidecarKeyVector` builds a `HubKeyring` over an in-memory sidecar with fixed identity bytes (`0x41…`, `0x01…`, wrap `0xF0…`) and writes `{hub_id, k_meta_sealed, epochs:[{epoch, sealed_keys}], k_meta, data_key, alert_key}` (hex) under `WT_E2E_REGENERATE=1` to `internal/hub/identity/testdata/swift-keyring.json`; without the variable it re-opens the file's sealed values and checks they open.
- [ ] **Step 2: Failing Go tests:** `TestKeyring_OpensSwiftSealedKeys` (Go opens `k_meta_sealed`/`sealed_keys` with the wrap key and the pinned AADs → equals the plain keys), `TestKeyring_SealsWhatSwiftFormatReads` (Go-sealed blobs parse as nonce 12 ‖ ct ‖ tag 16 and open with the same AAD), `TestKeyring_RotatesAt90DaysOrSeqCap`, `TestKeyring_PreviousEpochAcceptedFor7Days`, `TestSealLocalRoundTripAndLabelBinding` (opening under another label fails), `TestFileStore_RefusesLooserMode` (0644 → `ErrInsecureMode`), `TestFileStore_RoundTrip`, `TestIdentityNeverLogged` (`logcanary.Capture`; load/save/rotate leave no key hex in the log).
- [ ] **Step 3:** `make test-swift FILTER=HubKeyringVectorTests` (with the env var once, then without) → PASS; `go test ./internal/hub/identity` → FAIL.
- [ ] **Step 4: Implement.** Relay keys cached per (device, epoch, direction), re-derived when the device row's `agreement_key`/`link_nonce` change; `NextSeq` over one `SeqAllocator` on `envelope_seq_ceiling`; rotation is one `state.WithTx`.
- [ ] **Step 5:** `go test ./internal/hub/identity` → PASS; `make lint-diff`, `make lint-swift`.
- [ ] **Step 6: Commit** `hub/identity: file identity store and a Swift-compatible keyring`.

### Task 7: `hub/transport` — neutral seam and the in-memory fake

**Files:**
- Create: `internal/hub/transport/transport.go`, `internal/hub/transport/zones.go`, `internal/hub/transport/errors.go`
- Create: `internal/hub/transport/memfake/memfake.go`
- Test: `internal/hub/transport/memfake/memfake_test.go`

**Interfaces:**
- Consumes: `secure.Record`.
- Produces:
  ```go
  package transport
  type Kind string; const ( KindRelay Kind = "relay"; KindCloudKit Kind = "cloudkit" )
  type ExpectMode int; const ( ExpectNone ExpectMode = iota; ExpectAbsent; ExpectSeq )
  type Expect struct{ Mode ExpectMode; Seq uint64 }
  type SaveItem struct{ Record secure.Record; Expect Expect }
  type Stored struct{ Zone, Name string; Envelope []byte; RecordSeq uint64; ServerAt time.Time; AttachmentID string }
  type Outcome struct{ Saved bool; RecordSeq uint64; Conflict *Stored; Refused error }
  type DeleteItem struct{ Name string; Expect Expect }
  type Batch struct{ Changed []Stored; Deleted []string; NewSeq uint64; More bool }
  type ControlKind int // EntitlementExpired, SubscriptionMoved, SlotRemoved, PairingOpened, SessionExpired
  type Event struct{ Zone string; Control *Control; Err error } // Zone set = "pull this zone"
  type Control struct{ Kind ControlKind; Detail string }
  type Transport interface {
      Kind() Kind
      Save(ctx context.Context, items []SaveItem) ([]Outcome, error)   // refuses !Record.Sealed() with secure.ErrUnsealed before any I/O
      Delete(ctx context.Context, zone string, items []DeleteItem) ([]Outcome, error)
      Changes(ctx context.Context, zone string, since uint64) (Batch, error)
      Events() <-chan Event
      Download(ctx context.Context, attachmentID, dst string) error
  }
  func DataZone(hub string) string; func MailboxZone(hub, phone string) string; func PairZone(slot string) string
  var ErrTokenExpired, ErrUnavailable, ErrEntitlementInactive, ErrForbidden, ErrHubQuota, ErrMailboxQuota, ErrRecordTooLarge, ErrUnsupportedVersion, ErrRateLimited error
  package memfake
  func New(kind transport.Kind, clock func() time.Time) *Fake  // relay-shaped record_seq, or CloudKit-shaped change tags (kind cloudkit)
  func (f *Fake) SetAvailable(bool); func (f *Fake) FailNext(op string, err error); func (f *Fake) Frames() [][]byte // every envelope byte the fake ever received (canary capture)
  func (f *Fake) ExpireBefore(zone string, seq uint64) // next Changes(since<seq) → ErrTokenExpired
  func (f *Fake) Write(zone, name string, env []byte, expect transport.Expect) (transport.Outcome, error) // the phone's side, no sealer needed
  ```
  Conditional saves are part of `Save` (both Go transports support them; the spec's `Conditional` capability folds in). `Paged` = `Batch.More`; `Live` = `Events`.
- **Depends on:** Task 4

- [ ] **Step 1: Failing tests:** `TestMemfake_RefusesUnsealedRecord` (Review Focus 1: `Save([{Record: secure.Record{}}])` → `secure.ErrUnsealed`, `Frames()` empty), `TestMemfake_ExpectAbsentConflictReturnsCurrent`, `TestMemfake_ExpectSeqOverwrite`, `TestMemfake_ChangesPagesWithMore` (limit 200), `TestMemfake_TokenExpired`, `TestMemfake_EventOnWrite`, both kinds where the rule applies.
- [ ] **Step 2:** `go test ./internal/hub/transport/...` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** `go test ./internal/hub/transport/...` → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `hub/transport: neutral seam and in-memory fake`.

### Task 8: Pinned copy of the relay Go client, `make relay-go`, and the relay transport

**Files:**
- Create (copied, generated): `internal/hub/transport/relay/client/{client.go,ws.go,client_test.go}`, `internal/hub/transport/relay/relayv1/{relay.pb.go,version.go,zone.go}`, `internal/hub/transport/relay/VERSION`
- Create: `scripts/relay-go.sh`; Modify: `Makefile` (`relay-go`), `go.mod`/`go.sum` (`github.com/coder/websocket`, `google.golang.org/protobuf` direct)
- Create: `internal/hub/transport/relay/transport.go`, `internal/hub/transport/relay/errors.go`, `internal/hub/transport/relay/pairing.go`
- Test: `internal/hub/transport/relay/transport_test.go` (httptest + a small fake op server over the copied proto)

**Interfaces:**
- Consumes: `transport.*`, `state.Store` (`ZoneToken`/`SetZoneToken`), `identity.Identity.RelayAuth`.
- Produces:
  ```go
  package relay
  type Options struct{ Origin string; HubRelayID string; Store *state.Store; Clock func() time.Time }
  func New(c *client.Client, o Options) *Transport // implements transport.Transport
  func (t *Transport) Connect(ctx context.Context, zones []string) error // Connect + Subscribe; after every reconnect: resubscribe, pull every zone from its token, get_account_state
  func (t *Transport) SetHubReaders(ctx context.Context, phones []string) error
  func (t *Transport) PairZoneFor(slot string) string
  func (t *Transport) AccountState(ctx context.Context) (*relayv1.AccountState, error)
  func MapError(err error) error // relay ErrorCode → transport errors (QUOTA→Hub/Mailbox, ENTITLEMENT_INACTIVE, FORBIDDEN, TOKEN_EXPIRED, UNSUPPORTED_VERSION, RECORD_TOO_LARGE, RATE_LIMITED, ATTESTATION_REQUIRED/FAILED, SLOT_LIMIT)
  ```
  `scripts/relay-go.sh RELAY REF`: refuses a dirty tree (`git -C $RELAY status --porcelain` non-empty) or `HEAD != REF`; copies `client/{client,ws,client_test}.go` and `gen/relay/v1/*.go`; rewrites `github.com/aiwatchtowers/relay/gen/relay/v1` → `watchtower/internal/hub/transport/relay/relayv1` and `…/relay/client` → `watchtower/internal/hub/transport/relay/client`; writes `VERSION` = `<commit> <ISO date>`; `gofmt`. Public CI never runs it.
- **Depends on:** Task 5, Task 7

- [ ] **Step 1: Copy** with `make relay-go RELAY=../relay REF=<commit named by the relay session>`; commit the copy alone first (`hub/transport/relay: copy relay client <short sha>`), so review sees our code separately. `go test ./internal/hub/transport/relay/client` → PASS (the relay's own unit tests).
- [ ] **Step 2: Failing tests:** `TestRelayTransport_RefusesUnsealedRecord` (Review Focus 1), `TestRelayTransport_ZoneTokensPersist` (a pull stores `new_seq`; a new transport resumes from it), `TestRelayTransport_TokenExpiredResetsZoneToZero` (`ErrTokenExpired` from `Changes` → stored token 0, next pull from 0), `TestRelayTransport_SaveErrorRereadsZone`, `TestRelayTransport_ErrorMapping` (table over every code above), `TestRelayTransport_ZoneChangedWithoutRecordMeansPull`, `TestRelayTransport_UploadThenSaveWithAttachment` (`create_upload` → PUT of the already-sealed file → `save` with `attachment_id`; URLs opaque).
- [ ] **Step 3:** `go test ./internal/hub/transport/relay` → FAIL.
- [ ] **Step 4: Implement.** Register as `DEVICE_KIND_MAC` with no attestation until the relay ships `DEVICE_KIND_HUB` (gap 1 in the hand-off); the hub never counts itself on the relay until the account state reports it in an active slot.
- [ ] **Step 5:** `go test ./internal/hub/transport/relay/...` → PASS; `make lint-diff`.
- [ ] **Step 6: Commit** `hub/transport/relay: hosted relay transport over the pinned client`.

### Task 9: Action processor core — ledger, order, echoes, holds, resend/skip

**Files:**
- Create: `internal/hub/actions/{processor.go,order.go,echo.go,dispatcher.go}`
- Create: `internal/hub/hubtest/phone.go` (Go phone emulator: keys, relay key derivation, seal `relayToHub` actions with `action_seq`, open echoes and controls, write `skip_to`)
- Test: `internal/hub/actions/processor_test.go`, `internal/hub/actions/sim_test.go`

**Interfaces:**
- Consumes: `transport.Transport`, `secure.Sealer`/`Opener`/`KeySource`, `state.Store`, `wire.ActionRequest`.
- Produces:
  ```go
  package actions
  type Request struct{ Device secure.ID; RecordName string; Action wire.ActionRequest; ReceivedAt time.Time }
  type Outcome struct{ Status string; Reason, Message, Delivery string; Result map[string]any }
  type Handler func(ctx context.Context, r Request) Outcome
  type KindOptions struct{ NonIdempotent, ReceivedEcho bool; MaxAge time.Duration; Nudges []string }
  type Dispatcher struct{…}; func NewDispatcher() *Dispatcher
  func (d *Dispatcher) Register(kind string, h Handler, o KindOptions) // panics on a duplicate kind
  type Config struct{ Store *state.Store; Transport transport.Transport; Sealer *secure.Sealer; Opener *secure.Opener; Keys secure.KeySource
      Dispatcher *Dispatcher; HubRelayID string; Clock func() time.Time; Nudge func(kinds []string) }
  type Processor struct{…}; func NewProcessor(c Config) *Processor
  func (p *Processor) Pass(ctx context.Context) (PassReport, error) // every linked phone's mailbox; called on each transport Event and by the runtime's backstop timer
  func (p *Processor) FlushControls(ctx context.Context) (written, failed int, err error) // writes queued echoes/controls per mailbox in order; Task 10 adds retry classes and refusal drop
  type PassReport struct{ Read, Applied, Repeats, Held, Echoed, ControlsWritten int }
  const ActionMaxAge = 7 * 24 * time.Hour; const SessionRequestMaxAge = 24 * time.Hour; const MaxClockSkew = 300 * time.Second; const BatchLimit = 200
  var NonIdempotentKinds = []string{"board_comment_add","board_comment_reply","board_target_create","session_start","session_input","session_finish_request","permission_answer","session_interrupt","automation_run"}
  var ReceivedEchoKinds = []string{"session_start","session_input","board_target_create"}
  var RefusedKinds = []string{"target_done","target_snooze","task_create"}
  ```
  **Algorithm (one record, ordered path):** open (`FromPhone`; an unopenable record from no linked key is dropped with no answer, D9; a record naming another `device_id` → `failed device_not_linked`); `seq := action.ActionSeq`; in one `WithTx`: if `seq <= last` → repeat: re-echo the stored `done` echo (or `applied` if none) with `expect: seq`; if `seq > last+1` → `HoldAction`, echo `held`, and when `resend_requested_from != last+1` enqueue one `resend_from(last+1)` control and set it; if `seq == last+1` → `Begin` (non-idempotent kinds), commit, run the handler outside any transaction, then one `WithTx`: `MarkDone` + `SetLastApplied(seq)` + `DropHeld` + enqueue the final echo as a sealed control-queue row; **the rollback mark (`state.RecordSeen`) is written in the first transaction that commits a decision about the record — the repeat echo, the hold, `Begin`, or for idempotent kinds the done transaction — never before it**, so a crash between open and that commit leaves the record new; after it, drain held actions `last+1…` the same way. Kinds in `ReceivedEchoKinds` get a `received` echo before the handler runs. Echoes go out through the control queue (Task 10), never fire-and-forget.
- **Depends on:** Task 4, Task 5, Task 6, Task 7

- [ ] **Step 1: Failing sim twins**, each run as a subtest on **both** memfake kinds (`relay` with `record_seq`, `cloudkit` with change tags; names match the relay `sim` tests): `TestActionsAppliedInOrderOnce` (a1..a3 applied once in order; a stale copy of a3 echoed, mailbox ends empty after the phone deletes echoes), `TestGapTriggersResendFrom` (a3 before a2: a3 held, one `resend_from(2)`; a2 resent with the same bytes → a2 then a3 applied), `TestSkipToMarksUndelivered` (hub side: `skip_to(4)` → `last` jumps to 3, held a4 applied).
- [ ] **Step 2: Failing hub tests:** `TestCrashMidApplyEchoesOutcomeUnknownOnce` (handler panics after `Begin` → next pass echoes `failed`/`outcome_unknown`, handler call count stays 1) and `TestOrderAndLedgerCommitInOneTransaction` (fault-inject the commit of the done transaction: neither `relay_processed.done` nor `last_applied_action_seq` moved) — Review Focus 2; `TestTokenExpiredResyncAppliesNothingTwice` (after 3 applies, `ExpireBefore` + pass from 0 → 0 handler calls, 3 repeat echoes) — Review Focus 3; `TestCrashBetweenOpenAndBeginRedeliveryIsApplied` (fault injected after `FromPhone` and before the deciding transaction: no `relay_seen` row; the redelivered record is applied once, not dropped as a repeat); `TestResendFromWrittenOncePerGap`; `TestHandlerFailureEchoesFailedWithClass`; `TestActionOlderThan7DaysExpires`; `TestClockSkewOver300sFails`; `TestRefusedKindsFailWithoutHandler`.
- [ ] **Step 3:** `go test ./internal/hub/actions` → FAIL.
- [ ] **Step 4: Implement** (handlers run with the context of the pass; a handler never sees a transaction).
- [ ] **Step 5:** `go test ./internal/hub/actions` → PASS; `make lint-diff`.
- [ ] **Step 6: Commit** `hub/actions: ordered exactly-once processor with echoes and holds`.

### Task 10: Control queue, mixed versions, hygiene, `probe`

**Files:**
- Create: `internal/hub/actions/{control.go,legacy.go,hygiene.go,probe.go}`
- Test: `internal/hub/actions/control_test.go`, `internal/hub/actions/legacy_test.go`

**Interfaces:**
- Produces:
  ```go
  // FlushControls (Task 9) gains: a row that fails stays queued and is retried every pass; a row refused for good is dropped with its class logged
  const ControlResendFrom, ControlSkipTo, ControlEpochAck, ControlSwitch, ControlSwitched, ControlSwitchRejected, ControlHubOnRelay = "resend_from","skip_to","epoch_ack","transport_switch","transport_switched","transport_switch_rejected","hub_on_relay"
  func RegisterProbe(d *Dispatcher) // "probe" → applied {}
  ```
  Phone-written `c-*` (`skip_to`, `epoch_ack`) are handled once and deleted by the hub (recipient delete); a second copy of the same control id is deleted unread. A phone's `transport_switch` is answered at once with `transport_switch_rejected` carrying the reason "not supported yet" (no `retry_after` beyond what the proto's field already means; queued like any control, so it is retried until written), and the control is deleted — a phone never waits on a hub that cannot switch. Phase 3 implements sim rules 8–16.
- **Depends on:** Task 9

- [ ] **Step 1: Failing tests:** `TestHubResendFromRetriedUntilWritten` (sim twin on both memfake kinds: first two saves fail unreachable, third lands; one record), `TestEchoOwedIsRetriedEveryPass`, `TestPhoneControlsDeletedOnceRead`, `TestLegacyActionWithoutSeqTakesTodaysPath` (UUID record `action-<uuid>`, today's echo statuses, `ordered` stays false, no control records), `TestOrderedModeStartsAtFirstSeq` (`ordered` true from the first payload with `action_seq`), `TestEpochAckRecorded`, `TestTransportSwitchIsRejectedNotSupportedYet` (one `transport_switch_rejected` with that reason in the phone's mailbox, the request deleted, the hub's transport unchanged), `TestProbeApplied`, `TestUnknownRecordKindIgnored`.
- [ ] **Step 2:** `go test ./internal/hub/actions` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** `go test ./internal/hub/actions` → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `hub/actions: durable control queue, legacy path, probe`.

### Task 11: `hub/link` — codes, hello, SAS, keybox, grants, unlink

**Files:**
- Create: `internal/hub/link/{center.go,codes.go,hello.go,keybox.go,grants.go,events.go}`
- Test: `internal/hub/link/center_test.go`

**Interfaces:**
- Consumes: `wire.LinkPayload`/`DeviceHello`/`Keybox`/`DeviceGrant`, `secure.Opener.Hello`, `secure.SAS`, `secure.LinkCodeTag`, `identity.Keyring.KeyboxKeys`, `state.Store`.
- Produces:
  ```go
  package link
  type Grant string; const ( GrantTyping Grant = "typing"; GrantPermissions Grant = "permissions"; GrantStartSessions Grant = "start_sessions" )
  const KeptCodes = 50; const MaxNoncesPerCode = 3; const MaxRefusalsPerCode = 10; const MaxLinkRefusals = 50
  type HostInfo struct{ Name string; Transports []string; RelayDeviceID, RelayAuthPub string }
  type Config struct{ Store *state.Store; Keys *identity.Keyring; Opener *secure.Opener; Host HostInfo; Clock func() time.Time; Publish func(kinds ...string) }
  type Center struct{…}; func NewCenter(c Config) *Center
  func (c *Center) Issue() (wire.LinkPayload, string, error)                       // v4, transport "relay", relay_device_id, relay_auth_pub, transports
  func (c *Center) HandleHello(zone, wireName string, env []byte) (Pending, error) // refusals: used_code, expired_code, unknown_code, too_many_requests
  func (c *Center) Confirm(device string, ok bool) error                         // ok=false → not_confirmed
  func (c *Center) Unlink(device string) error                                   // revoked keybox, rotate epoch (reason unlink)
  func (c *Center) Allow(device string, g Grant, on bool) error
  func (c *Center) Grants() ([]wire.DeviceGrant, error)                          // the device_grant slice's rows (≤ 20), ordered_actions:1 + transports + relay ids on every row
  type PairEvent struct{ Kind string /* qr|waiting|sas|linked|refused */; URL string; ExpiresAt time.Time; DeviceID, Name, Code, Reason string }
  func (c *Center) Events() <-chan PairEvent
  ```
- **Depends on:** Task 1, Task 4, Task 5, Task 6, Task 7

- [ ] **Step 1: Failing tests** (port the behaviour of `MobileLinkCenterTests` / `MobileLinkPairingCodeTests` that does not involve CloudKit shares; same assertions, Go names): `TestIssueKeepsAtMost50Codes`, `TestAUsedCodeIsRefused`, `TestAnExpiredCodeIsRefused` (600 s), `TestFourthNonceOnACodeIsTooManyRequests`, `TestRefusalsCappedPerCodeAndOverall` (10 / 50), `TestSASMatchesKit` (code equals `secure.SAS` over the hello keys + drawn confirm nonce; the waiting grant carries `confirm_nonce` and `link_code_tag`), `TestConfirmSealsKeyboxWithGrantAndKeys`, `TestConfirmAfterExpiryOrUnlinkSealsNoKeys` (Review Focus 5: expired code, an `Unlink` and a `Confirm(false)` racing `Confirm(true)` → the keybox for that device holds `keys == nil`, no `devices` row), `TestUnlinkWritesRevokedKeyboxAndRotates`, `TestTypingRequestIsStoredNotGranted`, `TestPermissionsGrantIsSeparateFromTyping`, `TestEveryGrantAnnouncesOrderedActionsAndTransports`.
- [ ] **Step 2:** `go test ./internal/hub/link` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** `go test ./internal/hub/link` → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `hub/link: linking state machine with SAS v2 and keyboxes`.

### Task 12: Linking over the relay — pairing slot, readers, relay identity

**Files:**
- Modify: `internal/hub/transport/relay/pairing.go`
- Create: `internal/hub/link/relay.go`
- Test: `internal/hub/link/relay_test.go`

**Interfaces:**
- Consumes: `transport.Event{Control: PairingOpened}`, `relay.Transport.SetHubReaders`, `link.Center`.
- Produces:
  ```go
  func (c *Center) OnPairingOpened(ctx context.Context, t transport.Transport, slot string) error // read hello in pair/<slot>, answer keybox there
  func (c *Center) SyncReaders(ctx context.Context, set func(context.Context, []string) error) error // linked phones' relay ids → set_hub_readers
  ```
  Vouching (`vouch_hub`) is the phone's call; the hub only reports the server's state. `HUB_NOT_VOUCHED` is not in the relay proto yet (gap 1): until it is, a refused login/register maps to `ErrForbidden` and `hub status` says "not admitted by the relay". **Phase-2 dependency:** the spec §13 vouch-branch tests (vouch accepted; refused with `ATTESTATION_*`, slot limit, `HUB_NOT_VOUCHED`) are written when the relay proto carries those codes and `vouch_hub`, in phase 2's plan.
- **Depends on:** Task 8, Task 11

- [ ] **Step 1: Failing tests:** `TestPairingOpenedAnswersKeyboxInPairZone`, `TestPromotedPhoneBecomesReader` (after Confirm, `SyncReaders` called with the phone's relay id), `TestRemovedPhoneLeavesReaders`, `TestPairZoneCarriesNoAttachments`.
- [ ] **Step 2:** `go test ./internal/hub/link ./internal/hub/transport/relay` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `hub/link: pairing over the hosted relay`.

### Task 13: Slice publisher core, `device_grant` and `heartbeat`

**Files:**
- Create: `internal/hub/slices/{publisher.go,kinds.go,grant.go,heartbeat.go}`
- Test: `internal/hub/slices/publisher_test.go`, `internal/hub/slices/heartbeat_test.go`

**Interfaces:**
- Consumes: `secure.Sealer.Data`, `transport.Transport`, `state` (`slice_state` hashes + `wire_name`), `link.Center.Grants`.
- Produces:
  ```go
  package slices
  type Kind string // raw values of the Kit's SliceKind ("device_grant", "heartbeat", "owner_ask", …)
  type Item struct{ ID string; Payload []byte; Notify string; Asset *secure.AssetDescriptor; AssetPath string }
  type Source interface{ Kind() Kind; Items(ctx context.Context) ([]Item, error) }
  type Config struct{ Store *state.Store; Transport transport.Transport; Sealer *secure.Sealer; DataZone string; Sources []Source
      Spacing time.Duration; Clock func() time.Time; Linked func() (bool, error) }
  type Publisher struct{…}; func NewPublisher(c Config) *Publisher
  func (p *Publisher) PublishSoon(kinds ...Kind)         // marks dirty; debounced 150 ms
  func (p *Publisher) Cycle(ctx context.Context, kinds []Kind) (CycleReport, error) // diff by payload hash, seal, save, delete gone records
  func (p *Publisher) Run(ctx context.Context) error     // debounce + 60 s full diff + spacing
  const Debounce = 150 * time.Millisecond; const MaxDebounceWait = time.Second /* a trailing debounce never holds a dirty kind longer */; const FullDiffEvery = 60 * time.Second; const RelaySpacing = 150 * time.Millisecond; const CloudKitSpacing = 2 * time.Second
  var UrgentKinds = []Kind{"owner_ask", "ask_alert", "device_grant", "permission_request", "session_chat"}
  var UnlinkedKinds = []Kind{"device_grant"}
  func GrantSource(c *link.Center) Source
  func HeartbeatSource(f HeartbeatFacts) Source // record "heartbeat"; owner_user "" and sharing "none" on a relay-only hub (gap 6); accounts ≤ 20 read from the daemon's database — in phase 1 that is always the test workspace's, because the hub refuses to start in any other workspace (Task 14)
  ```
- **Depends on:** Task 1, Task 4, Task 5, Task 7, Task 11

- [ ] **Step 1: Failing tests:** `TestUnchangedPayloadIsNotResaved`, `TestGoneRecordIsDeleted`, `TestOnlyUnlinkedKindsWhileNoPhone`, `TestAKindIsSavedAtMostOncePerSpacing` (the rewritten battery rule: relay 150 ms; the CloudKit 2 s value is asserted on the constant here and exercised in phase 3), `TestDebounceCoalescesBurst` (5 `PublishSoon` within 100 ms → one cycle), `TestDebounceMaxWaitBoundsAContinuousBurst` (`PublishSoon` every 100 ms for 3 s → a cycle at least every `MaxDebounceWait`; Plan 1b Task 10 repeats it with the real DB sources), `TestOversizedRecordIsSkippedAndLogged` (> 900 000 bytes sealed), `TestHeartbeatPayloadDecodesInKitShape` (keys equal the Kit `HeartbeatPayload` coding keys).
- [ ] **Step 2:** `go test ./internal/hub/slices` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `hub/slices: publisher core with device_grant and heartbeat`.

### Task 14: Hub runtime, dev flag, MDM gating, daemon wiring

**Files:**
- Create: `internal/hub/hub.go` (`Options`, `FromEnv`, `Run`), `internal/hub/status.go`, `internal/hub/control.go` (control socket server + `Dial`)
- Modify: `cmd/sync.go` (`runSyncDaemon`: start `hub.Run` in its own goroutine when `hub.FromEnv` says so)
- Test: `internal/hub/hub_test.go`

**Interfaces:**
- Consumes: everything above; `policy.MobileSync()` (`allowed | workbench_only | off`); `config.AppSupportDir()`.
- Produces:
  ```go
  package hub
  type Options struct{ Dir, RelayOrigin, RecordingsDir string /* <Dir>/recordings in phase 1 */; DB *db.DB; CycleTick <-chan struct{}; Clock func() time.Time; Register func(*actions.Dispatcher); Sources func(*state.Store) []slices.Source }
  func FromEnv(cfg *config.Config, db *db.DB) (Options, bool, error) // WATCHTOWER_HUB_DIR (absolute; refused under AppSupportDir()/MobileHub) + WATCHTOWER_RELAY_ORIGIN + WATCHTOWER_HUB_TEST_WORKSPACE == cfg.ActiveWorkspace and the name starts with `hubtest-` (a live workspace is never named so; a live name is refused even if the env var points at it) (else ErrNotTestWorkspace, hub off)
  func Run(ctx context.Context, o Options) error // lock → state → identity → keyring → transport → link/processor/publisher; returns on ctx cancel, releases the lock
  // Lock: AcquireLock retried every 1 s for up to 30 s, then once per daemon cycle (Options.CycleTick <-chan struct{}); meanwhile status is state "starting", reason "locked" (a CLI write holds the lock for milliseconds).
  type Status struct{ State, Reason, HubID, RelayDeviceID, Transport, Impl, Dir string; Phones int }
  func ReadStatus(dir string) (Status, error) // read-only; reasons: "disabled", "policy_off", "locked" (with state "starting" while retrying), "not_test_workspace", "sidecar_unreadable", "not_admitted", "relay_unreachable"
  // Control socket <dir>/hub.sock (0600, peer UID checked), served while Run holds the lock: one JSON request per line, JSON answers/events per line.
  type ControlRequest struct{ Op string /* unlink|allow|name|enable|disable|pair|confirm */; Device, Grant, Name string; On, Confirm bool }
  func Dial(dir string) (*ControlClient, error)
  ```
  `hub_meta.enabled` = `1` is the on switch (Desktop's `mobileSyncEnabled` moves here in phase 3); MDM `off` stops the hub and deletes what it published from the data zone but leaves `enabled` (POLICY-03); `workbench_only` restricts the sources 1b registers. The runtime writes `hub_impl = go` on first start.
- **Depends on:** Task 8, Task 10, Task 12, Task 13

- [ ] **Step 1: Failing tests:** `TestSecondHubRefusedWhileLocked` (two `Run` on one dir: the second never opens the sidecar for writing and reports `starting`/`locked` while the first runs), `TestHubStartWaitsForACLIHoldingTheLock` (a CLI-style holder keeps the lock 2.5 s: status `starting: locked`, then the hub starts within the next 1 s retry; past 30 s it retries on `CycleTick`), `TestHubRefusesWithoutMatchingTestWorkspace` (variable unset or naming another workspace → hub off, reason `not_test_workspace`, nothing created in the dir), `TestDevFlagRefusesSwiftHubDir` (dir = `<AppSupportDir>/MobileHub` or below → error, nothing created there), `TestHubOffWithoutRelayOrigin` — Review Focus 4; `TestPolicy03_OffStopsHubKeepsSetting` and `TestPolicy03_LooseningDoesNotStartHubWhenSettingOff` (Go twins of `MobileHubPolicyTests.testOffStopsHubKeepsSetting` / `testLooseningDoesNotStartHubWhenSettingOff`, same meaning), `TestSidecarUnreadableKeepsHubOffAndSaysSo`, `TestRunReleasesLockOnCancel`, `TestControlSocketIsPrivateAndChecksPeer` (0600; a request from another UID is closed — simulated through the peer-credential seam), `TestEndToEndOverMemfake` (`hubtest.Phone` links, sends probe a1..a2, gets `applied` echoes and a `device_grant` with `ordered_actions:1`).
- [ ] **Step 2:** `go test ./internal/hub` → FAIL.
- [ ] **Step 3: Implement**; in `runSyncDaemon` add only the start call and the log line `hub: started (dir set)` / `hub: off (<reason>)`.
- [ ] **Step 4:** `go test ./internal/hub` and `go test ./cmd -run 'TestSyncDaemon'` → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `hub: runtime behind WATCHTOWER_HUB_DIR, started by the daemon`.

### Task 15: `watchtower hub …` CLI with pinned `--json` keys

**Files:**
- Create: `cmd/hub.go`
- Test: `cmd/hub_test.go`

**Interfaces:**
- Consumes: `hub.ReadStatus`, `hub.Dial` (Task 14's control socket), `state.Store`. Reads (`status`, `phones`) open the sidecar read-only. A write first tries `state.AcquireLock`: it gets the lock only when no hub runs, writes directly and releases; on `ErrLocked` it sends the request over `<dir>/hub.sock` to the running hub — so the sidecar never has two writers at once. `pair` needs the running hub (its pending link and the relay connection live there): without it, exit 1 "the hub is not running".
- Produces commands and pinned keys:
  - `hub status [--json]` → `{"state","reason","hub_id","relay_device_id","transport","impl","dir","phones"}`
  - `hub phones [--json]` → array of `{"device_id","name","scope","linked_at","typing_allowed","typing_requested","permissions_allowed","permissions_requested","start_sessions_allowed","start_sessions_granted","ordered","last_applied_action_seq","transport"}`
  - `hub unlink <device> [--json]` → `{"device_id","unlinked"}`
  - `hub allow <device> typing|permissions|start_sessions [--revoke] [--json]` → `{"device_id","grant","allowed"}`
  - `hub pair --json --stream` → JSON lines `{"event":"qr","url","expires_at"}`, `{"event":"waiting"}`, `{"event":"sas","device_id","name","code"}`, reads `{"confirm":true|false}` from stdin, then `{"event":"linked","device_id"}` or `{"event":"refused","reason"}` (reasons = `LinkRefusal` raw values). The terminal QR and `[y/N]` prompt are phase 2.
  - `hub name <name> [--json]` → `{"name"}` (≤ 60 characters, `hub_meta.display_name`)
  - `hub enable|disable [--json]` → `{"enabled"}`
  Every write is an owner verb refused under an agent marker, as the other owner-only CLIs do: `unlink`, `allow`, `pair`, `enable`, `disable`, `name` (Plan 1b's `hub desktop heartbeat` and `hub recording claim|finish` are refused under a marker too: only Desktop calls them); all need `WATCHTOWER_HUB_DIR` in phase 1.
- **Depends on:** Task 11, Task 14

- [ ] **Step 1: Failing tests:** `TestHubStatusJSONKeys`, `TestHubPhonesJSONKeys`, `TestHubAllowJSONKeys`, `TestHubPairStreamEvents` (scripted stdin, memfake phone: `qr` → `waiting` → `sas` → confirm → `linked`; and the refusal path), `TestHubOwnerVerbsRefusedUnderAgent` (each of the six verbs, one table), `TestHubCLIWriteGoesThroughRunningHub` (with a running `hub.Run`, `hub allow` lands over the socket and the CLI never opens the sidecar for writing), `TestHubEnableWritesDirectlyWhenNoHubRuns`, `TestHubPairWithoutRunningHubFails`.
- [ ] **Step 2:** `go test ./cmd -run 'TestHub'` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `cmd: watchtower hub status|phones|unlink|allow|pair|name|enable|disable`.

### Task 16: Interop against the relay's local stand and the Plan 1a gate

**Files:**
- Create: `scripts/relay-interop.sh`; Modify: `Makefile` (`relay-interop`)
- Create: `internal/hub/interop_test.go` (`//go:build interop`)

**Interfaces:**
- Consumes: `hubtest.Phone`, `hub.Run`, relay dev endpoints `/dev/entitlement`, `/dev/pair`, `/healthz`.
- Produces: `make relay-interop RELAY=../relay` — starts `wrangler dev` from `$RELAY/worker` in its own process group (needs Node and `npm ci` there), waits for `/healthz`, runs `go test -tags interop ./internal/hub/... -relay=http://127.0.0.1:8787`, kills the group on exit and on failure.
- **Depends on:** Task 15

- [ ] **Step 1: Interop tests:** `TestInterop_LinkOverPairingSlot` (Go phone opens a slot, hub answers keybox, SAS equal on both sides, phone promotes), `TestInterop_ActionsInOrderWithEchoes` (a1..a5 with a deliberate gap; `resend_from` once; all applied once), `TestInterop_ReconnectResubscribesAndPulls` (stand restarted mid-run), `TestInterop_NoPlaintextOnTheWire` (every envelope the phone reads back from the relay parses as an envelope; a known marker in each action payload never appears in any frame).
- [ ] **Step 2: Gate:** `make test`, `make lint-all`, `make relay-interop RELAY=../relay` → all PASS (record the relay commit from `internal/hub/transport/relay/VERSION` in the PR body).
- [ ] **Step 3: Commit** `hub: relay interop job`.

---

## Self-review (done while writing)

- Spec coverage for 1a: §5 seams (Tasks 3–13), §6.1 (8, 16), §7.1–7.2 hub side up to what the relay supports today (8, 12; gap 1), §8 p. 1–3, 5, 6 (9, 10), §10 CLI minus recordings (15), §12a fixture (1), §13 vectors + choke point + Kit two-way (2–4), sim scenarios 1–7a (9, 10), §14 isolation (14). Switch scenarios (rules 8–16), CloudKit, adoption, Desktop wiring, pushes: phases 2–4.
- Types used across tasks: `secure.Record`/`Sealer`/`Opener`/`KeySource` (4 → 7, 8, 9, 11, 13), `state.Store`/`WithTx`/`Begin`/`MarkDone`/`SetLastApplied` (5 → 9, 10), `transport.Transport`/`SaveItem`/`Expect` (7 → 8, 9, 13), `actions.Dispatcher.Register` (9 → 10, 14, Plan 1b), `slices.Source`/`PublishSoon` (13 → 14, Plan 1b), `link.Center` (11 → 12, 13, 15).
