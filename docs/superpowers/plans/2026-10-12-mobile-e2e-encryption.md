# Mobile E2E encryption: app-level keys between the Mac hub and the phones

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** every byte the Mac hub and a linked phone exchange through CloudKit is sealed with keys that exist only on the Mac and the paired phones. Apple, a legal request, an Apple-ID or iCloud-Keychain compromise, a share participant and the storage layer then see ciphertext (and the metadata listed in the spec §4), cannot forge a phone action or a hub record, and cannot replay or roll back a record undetected.

**Architecture:**
- A transport-agnostic crypto core in the Kit (`WatchtowerKit/Sources/WatchtowerSync/Secure/`): key derivation, a versioned binary **envelope** (header + AEAD body + optional Ed25519 signature), a chunked streaming **asset cipher**, HPKE sealed boxes for pairing, a **key store** over the Keychain, and frozen known-answer vectors that a Go test re-derives independently.
- A `SecureTransport` wraps any `CloudSyncTransport` (`CloudKitTransport`, `InMemoryCloudTransport`, a future relay) above the existing seam. It seals what its role sends, opens what its role receives in RelayZone, maps plain record names to opaque HMAC names, and passes DataZone reads through untouched: the phone's replica stores **ciphertext** and decrypts on read, so hydration while the phone is locked needs no secret key.
- The Mac hub gets an identity (`hub_sig` Ed25519, `hub_kx` X25519), a group key per **epoch** for DataZone (`K_data`), a low-value `K_alert` for lock-screen ask titles, `K_meta` for record names, and one pairwise relay key per phone and direction. Pairing keeps the QR: the QR carries the hub's public keys (`LinkPayload` v3), the phone's `hello` is sealed to the hub, the owner confirms "Link <name>? Code 7342" on the Mac, and only then the hub publishes the phone's signed, sealed **keybox**. Remove/unlink rotates the epoch and republishes the window.
- Hard cut: new CloudKit record type `WatchtowerEnvelope` (plus `WatchtowerSignal` for the ask-alert subscription), hub marker `e2e_v1`, the hub deletes and recreates its zones once, every phone re-pairs once.

**Tech Stack:** Swift 5.10 language mode, CryptoKit (`Curve25519`, `ChaChaPoly`, `HKDF`, `HMAC`, `HPKE`), Security (Keychain), CloudKit `CKSyncEngine`, GRDB 7, XCTest, ViewInspector (Desktop); Go 1.25 stdlib + `golang.org/x/crypto/chacha20poly1305` for the cross-check only. Packages `WatchtowerKit` (`WatchtowerSync`, `WatchtowerKit`), `WatchtowerDesktop`, `WatchtowerMobile` (xcodegen).

**Spec:** `docs/superpowers/specs/2026-10-12-mobile-e2e-encryption-research.md` (owner-approved, ask #79; § numbers below refer to it). Base specs: `docs/superpowers/specs/2026-10-07-mobile-poc-design.md`, `docs/superpowers/specs/2026-10-11-mobile-multi-hub-design.md`. Feature notes: `docs/features/mobile-companion.md`.

**Scope:** spec §2 (all subsections) and the blockers of §5. **Out of scope** (spec §6): the relay server, Android/web clients, live session streams, Secure Enclave/StrongBox wrapping, suite 2 (ML-KEM hybrid; the `suite` byte is reserved), the optional biometric app lock (§1 threat 3), and the A13 notification feature itself (Task 18 provides the keys, the signal record and the opener it will use).

**Ordering with the multi-hub work:**
- Multi-hub **F1 is merged** on this branch (`HubZones`, `DataZone-<hub_id>`/`RelayZone-<hub_id>`, `TransportRole`, `LinkPayload` v2, `wrong_hub`). This plan builds on it: `hub_id` is a UUID string from `hub_meta`, every key is per hub, the zones stay per hub.
- **F2 is not planned yet** (`HubRegistry`, `HubSession`, per-hub notifications, switcher, the 4-hub limit). Run this plan **before F2**. F2's plan must then (a) carry the per-hub keys of `PhoneKeyStore.hubLink(_:)` in its registry row (spec §2.6 "Several phones"), one device identity for all hubs, (b) use the `WatchtowerSignal` record type of Task 11/18 instead of the multi-hub spec §5.5 query on `kind == "ask_alert"` (the kind is no longer on the wire), (c) fill `hub_id` on actions and uploads through the per-hub `SecureTransport`. If the owner wants F2 first, this plan's Tasks 16–18 must be redone against `HubSession`.
- A13 (notifications, mobile POC plan A) is not built either; Task 18 lands its crypto half.

**Execution (owner requirement, same as the F1 plan):**
- Subagents in a git worktree: superpowers:subagent-driven-development plus superpowers:using-git-worktrees. Branch `feature/mobile-e2e` off `feature/mobile-poc`.
- A new worktree copies the main checkout's `WatchtowerDesktop/.build` into itself, then deletes the path-bound `ModuleCache` inside it (about 1 min rebuild instead of minutes cold). Never delete `.build` otherwise.
- Each task runs only its task-scope checks (the commands in its steps plus `make lint-diff`). The controller runs `bash scripts/dev-health.sh` before each task and the full gate once at the phase end.
- No polling turns. Run a long command to a log with an explicit exit code: `cmd > /tmp/<name>.log 2>&1; echo "exit=$?"`. Never `run_in_background` for builds or tests.
- Public repo hygiene: no real ids, Apple IDs, team ids, emails, names or local paths in code, tests, fixtures, logs or results. Use `acme`, `hub-acme`, `_owner-acme`, "colleague A", `<team-id>`. Crypto fixtures use the fixed synthetic byte patterns defined in Task 1, never a key read off a device.

---

## Global Constraints

Values copied from the spec (§ in brackets); the deviations below the list are this plan's decisions where the spec was silent or self-contradictory.

- **Primitives (§2.1):** CryptoKit only, no third-party crypto. Suite 1 = X25519 (`Curve25519.KeyAgreement`), Ed25519 (`Curve25519.Signing`), HKDF-SHA256, ChaCha20-Poly1305 (`ChaChaPoly`), HPKE RFC 9180 `DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, ChaCha20Poly1305`. Keychain/Secure Enclave are local key storage, never part of the wire format. Suite 2 (hybrid X25519 + ML-KEM-768 for wraps) is reserved: suite byte `2` is refused as unsupported.
- **Key hierarchy (§2.2):** hub `hub_sig` Ed25519 + `hub_kx` X25519; `K_meta` 32 B; `K_data[e]` 32 B random per epoch; `K_relay_i = HKDF(ECDH(hub_kx, dev_kx_i), salt = nonce, info = "wt/relay/v1/" ‖ hub_id ‖ device_id)` with one key per direction; `K_asset` 32 B random per asset; `K_alert[e]` 32 B. Phone `dev_sig_i` Ed25519 (also `device_id = H(pk)`), `dev_kx_i` X25519.
- **DataZone:** group key per epoch, wrapped per device with HPKE to `dev_kx_i`, and every DataZone envelope is signed by `hub_sig` (§2.2).
- **RelayZone:** AEAD under `K_relay_i→hub` authenticates the device; the hub's echo goes under `K_relay_hub→i` (§2.2).
- **Nonces:** random 96-bit per message; rotate the epoch after 2^28 messages or 90 days (§2.2).
- **Rotation:** on Remove, phone unlink, suspected leak or the cap: new `K_data[e+1]`, wrapped for the remaining devices, keyboxes published, window republished (§2.2).
- **Pairing (§2.3):** QR v3 adds `hub_kx_pub`, `hub_sig_pub`; old phones read "Update Watchtower on this iPhone". Phone writes its `device` record sealed to `hub_kx_pub` (HPKE). Hub checks the nonce as `handleDevice` does now, shows "Link <name>? Code 7342", owner confirms on the Mac; only then the keybox (`K_data[e]`, `K_meta`, epoch, grants), signed by `hub_sig`. Nonce single-use, 600 s.
- **Envelope (§2.4):** `magic "WTE" | ver u8 | suite u8 | flags u8 (bit0 signed, bit1 has-asset, bit2 padded) | hub_id 16 B | sender_id 16 B | epoch u32 | seq u64 | nonce 12 B | kind u16 | ct_len u32 | ciphertext ‖ tag 16 B | [sig 64 B over header‖ciphertext]`. Everything before the ciphertext is AAD, plus the record name and the zone kind supplied out of band. Wire `kind` field becomes the constant `"wt"`; `modifiedAt` stays plaintext. Padding to the next of 256 B, 1 KiB, 4 KiB, 16 KiB, 64 KiB, then 64 KiB multiples; must stay under `SlicePublisher.maxPayloadBytes` (900 000) after header and padding. Over CloudKit the envelope is the `encryptedValues["payload"]` blob.
- **Assets (§2.5):** `K_asset` random; header `{asset_id, suite, chunk_size = 1 MiB, total_len, chunk_count}`; chunk `c` = `ChaChaPoly.seal(plain_c, key: K_asset, nonce: u32 0 ‖ u64 c, aad: header ‖ c ‖ last_flag)`; the owning record's envelope carries `K_asset` + header. Assets padded to 1 MiB (§1 threat 8). `ReplicaStore.maxAssetBytes` must allow the chunk overhead.
- **Keys at rest (§2.6):** phone Keychain `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, `kSecAttrSynchronizable` absent; the notification extension gets only `K_alert[e]` in a shared access group with `AfterFirstUnlockThisDeviceOnly`; Mac data protection keychain (`kSecUseDataProtectionKeychain`). Hub identity is deliberately not backed up: a new Mac is a new pairing.
- **Replica (§2.6):** ciphertext in `slice_records.payload` and `slice_assets.data`, decrypted on read; signature verified once at apply with `(epoch, seq)` stored; outbox encrypted at enqueue.
- **File protection (§2.6):** `.completeUnlessOpen` for the recording in progress and the transport's incoming asset stash; DBs class C acceptable because they hold ciphertext (see D8).
- **Names (§2.7):** record name = base32(HMAC-SHA256(`K_meta`, zone ‖ kind ‖ id)[0..<16]); the hub's `heartbeat` and each device's keybox keep fixed key-free names. Unknown `ver`/`suite` is refused loudly.
- **Migration (§2.8):** hard cut, new record type, `LinkPayload.v = 3`, hub marker `e2e_v1` in `hub_meta`, the hub deletes its pre-E2E zones and recreates them, every phone re-pairs once, deploy the new record type to Production before the first Production run (`make cloudkit-check`).
- **Keep `encryptedValues` as the outer layer (§3, §7).**
- **Platforms:** Swift 5.10 language mode; Kit macOS 14 / iOS 17 (CryptoKit `HPKE` needs exactly these minimums); Desktop macOS 14+; phone iOS 17+.

### Plan decisions (deviations and fills; each is called out to the owner)

- **D1 — no kind in the header.** The spec's header `kind u16` would sit in the clear inside a blob Apple can read without ADP, contradicting §1 threat 8 and §2.7. The u16 slot keeps its position and becomes `class` (routing only: data, alert, keybox, hello, relay p2h, relay h2p); the slice kind and id travel in the encrypted **inner frame**.
- **D2 — Mac key class `AfterFirstUnlockThisDeviceOnly`.** The hub must publish and answer the phone while the Mac's screen is locked (the main remote use case); a `WhenUnlocked` item is unreadable then. Still `ThisDeviceOnly`, data protection keychain, never synchronizable. Phone keys stay `WhenUnlockedThisDeviceOnly`.
- **D3 — Mac epoch keys in `hubstate.db`, sealed.** `K_meta`, `K_data[e]`, `K_alert[e]` live in `hubstate.db`, each sealed with ChaChaPoly under a 32-byte wrap key kept in the Keychain. Rotation (new epoch + hash wipe) is then one SQLite transaction (spec §5 "Rotation atomicity"). `hub_sig`/`hub_kx`/wrap key are Keychain items.
- **D4 — relay replay gate.** CloudKit gives no ordering, so a strict per-device `last_seq` would refuse legitimate out-of-order actions. The gate is: AAD binds the opaque record name, zone, hub, epoch and seq; the exactly-once ledger keys on the record name; the authenticated `created_at` age (7 days; 24 h for session kinds) outlives nothing the ledger forgets (the ledger is pruned one day after the age window); and a per-record `(epoch, seq)` rollback guard ignores an older version of the same record. `devices.last_seq` is kept as a high-water mark for diagnostics.
- **D5 — `K_meta` does not rotate on Remove** (v1). A removed phone could still map future opaque names of kinds/ids it already knows (metadata only). Rotating it needs a delete of every old-named record; listed as an open question.
- **D6 — SAS from 4 bytes.** `SAS = UInt32(HKDF(...)[0..<4]) mod 10 000`, zero-padded to four digits (2 bytes mod 10 000 biases low codes).
- **D7 — ids.** `device_id` = UUID form of `SHA-256("wt/device-id/v1" ‖ dev_sig_pub)[0..<16]`; keybox record `keybox-<device_id>`, hello record `hello-<device_id>` (spec: `keybox-<H(dev_kx_pub)>`; same property, one id). The hub's `sender_id` is its `hub_id`.
- **D8 — phone file classes.** The replica, transport store and asset stash hold ciphertext and are written by background hydration and read by the extension, so their directory gets `completeUntilFirstUserAuthentication` (the spec's allowed fallback). `.completeUnlessOpen` for the recording in progress and for a finished recording still waiting to be sealed (finalized while locked). No plaintext content is left at rest after sealing.
- **D9 — revoked keybox instead of `device_not_linked` echoes.** After Remove the hub drops the phone's relay key, so it cannot echo to it. It publishes the phone's keybox as `revoked` (signed, sealed to that phone) for 7 days; the phone reads it as "This Mac removed this phone" in either scope (fixes the known limit "a same-Apple-ID phone removed on the Mac is not told"). A relay record that does not open with a linked device's key is dropped and logged, never echoed.
- **D10 — relay keys per epoch.** The epoch is part of the relay HKDF info, so a rotation also rotates pairwise keys. The hub accepts relay envelopes of the previous epoch for 7 days (the action age window).
- **D11 — replica metadata columns.** After the first unlocked open, the replica stores the plain `kind` and record name of each row (queries need them); payload and asset bytes stay ciphertext.
- **D12 — padding never crosses the cap.** The padded length is clipped to the largest plaintext that fits under 900 000 bytes after header, tag and signature; a record that does not fit even unpadded is skipped as oversized, exactly like today.

## Review Focus

Five failure modes the spec implies but its own tests would not reach, most likely first. Each has a test in the owning task.

1. **The phone is locked when CloudKit delivers.** A silent push hydrates DataZone while keys are unreadable: the batch must be stored (ciphertext, signature checked with the public key), the token must advance, nothing may be lost, and the rows must appear in the UI right after unlock. Test: `testApplyWhileLockedStoresCiphertextAndIndexesAfterUnlock` → Task 8; the same for echoes, `testEchoesThatCannotBeOpenedWhileLockedAreReplayedAfterUnlock` → Task 9.
2. **A deliberate re-send is not a replay.** The uploader's relaunch retry, Retry after a failed upload, and CloudKit's conflict re-save must send the identical envelope bytes, and the hub must take them as the known record (ledger), not refuse them as a rollback or ingest twice. Tests: `testRelaunchRetryResendsTheStoredEnvelopeByteForByte` → Task 9, `testARetriedUploadWithTheSameEnvelopeIsIngestedOnce` → Task 12, `testConflictReSaveKeepsTheSealedPayload` → Task 7.
3. **Padding pushes a near-cap record over 900 000 bytes** and it silently never publishes. Tests: `testPaddedLengthIsClippedToTheCap` → Task 3, `testARecordThatFitsOnlyUnpaddedStillPublishesAndOneThatDoesNotIsSkipped` → Task 11.
4. **A crash in the middle of a rotation** leaves records sealed under an epoch no keybox carries, or two hub processes fork epochs. Tests: `testRotationCommitsTheEpochAndTheHashWipeTogether`, `testAKilledRotationResumesOnTheSameEpoch` → Task 14.
5. **A photographed QR races the owner's phone.** Two hellos arrive for one code; the Mac must show both with different codes, link only the confirmed one, refuse the other, and never wrap a key to an unconfirmed device. Test: `testTwoHellosForOneCodeShowTwoCodesAndOnlyTheConfirmedOneGetsKeys` → Task 13.

## Guard tests and deliberate test changes

- `docs/inventory/` holds **no** guard test for the mobile hub, the Kit or the phone (`grep -rln "MobileHub\|CloudKitTransport\|RelayProcessor\|LinkPayload" docs/inventory/` finds only the dated note in `workbench.md`, which states no contract changed). No owner ask is needed for a guard test. Task 19 re-checks this.
- The creator-gate tests in `RelayProcessorTests`, `RelayProcessorRecordingUploadTests` and `MobileLinkCenterTests` stay (the creator check stays as defense in depth, spec §5 last bullet) and each gets a key-auth twin (Task 12, Task 13).
- Tests that assert plaintext payloads on the wire (`CloudKitTransportMappingTests` payload field, `LinkPayloadTests` v2 fixtures, `DeviceGrantSlice` record names, phone tests that save plaintext records into the in-memory transport) are **rewritten on purpose** to seal through the test hub; each task lists them, and the commit message says so.

## Implementer self-review checklist (every task)

Before hand-back, check the diff against:
1. This plan's Global Constraints and Plan decisions (D1–D12), and the task's Interfaces block (names and types exactly as written).
2. `docs/review/review-rules.md` §7 (tests: no real CLI, processes reaped), §9 (no swallowed error without a log; public-repo hygiene; no absolute paths), and the whole **Swift / Desktop conventions** section (state survives navigation in `AppState`/centers; every new `@Observable` ViewModel or center ships its own test suite; absent vs undecodable is a third state).
3. Crypto hygiene: no key, nonce, plaintext payload or SAS in a log line (`privacy: .public` only on record names, counts and error codes); every `try?` on a crypto call is a bug unless the line documents why the failure is the expected case; no `fatalError`/`preconditionFailure` on attacker-controlled input; secrets compared only through CryptoKit (`SymmetricKey ==` is constant-time) or by AEAD/signature verification.
4. A fixture under `WatchtowerKit/Tests/Fixtures/e2e/` is generated only by the task that introduces it (`WT_E2E_REGENERATE=1`); any later change to one is a wire-format change and needs the owner's approval.

---

## Task 1: Kit — crypto primitives, key derivation, record names, SAS

**Depends on:** none. **Lane:** Kit (light; may run beside one Desktop or phone task).

**Files:**
- Create `WatchtowerKit/Sources/WatchtowerSync/Secure/WireBytes.swift` — big-endian integer read/write, lowercase unpadded base32 (RFC 4648 alphabet), base64url (moved from `LinkPayload`; `LinkPayload.encodeBase64URL`/`decodeBase64URL` forward to it), UUID ↔ 16 bytes.
- Create `WatchtowerKit/Sources/WatchtowerSync/Secure/KeyDerivation.swift`.
- Create `WatchtowerKit/Tests/WatchtowerSyncTests/Support/E2EFixtures.swift` (fixture load/compare/regenerate, `Data(hex:)`, `hexString`).
- Create `WatchtowerKit/Tests/WatchtowerSyncTests/E2EPrimitiveTests.swift`, `E2EKeyDerivationTests.swift`.
- Create (generated) `WatchtowerKit/Tests/Fixtures/e2e/kdf.json`.

**Interfaces (produces):**

```swift
public enum WireBytes {
    public static func append(_ value: UInt16, to data: inout Data)   // big-endian; same for UInt32, UInt64
    public static func append(_ value: UInt32, to data: inout Data)
    public static func append(_ value: UInt64, to data: inout Data)
    public static func readUInt16(_ data: Data, at offset: Int) -> UInt16?   // nil when out of range; same for 32/64
    public static func readUInt32(_ data: Data, at offset: Int) -> UInt32?
    public static func readUInt64(_ data: Data, at offset: Int) -> UInt64?
    public static func base32(_ data: Data) -> String          // lowercase, no padding
    public static func base64URL(_ data: Data) -> String       // no padding
    public static func fromBase64URL(_ string: String) -> Data?  // canonical form only
    public static func bytes(of uuid: UUID) -> Data            // 16 bytes
    public static func uuid(_ data: Data) -> UUID?             // exactly 16 bytes
    public static func hubUUID(_ hubID: String) throws -> UUID // throws E2EError.badHubID
}

public enum E2EError: Error, Equatable { case badHubID(String) }

public enum RelayDirection: String, Sendable, CaseIterable {
    case phoneToHub = "p2h"
    case hubToPhone = "h2p"
}

public enum KeyDerivation {
    /// HKDF-SHA256(ikm: X25519(own, peer), salt: linkNonce,
    /// info: "wt/relay/v1/" ‖ dir ‖ 0x00 ‖ hub_id(16) ‖ device_id(16) ‖ epoch u32 BE), 32 bytes.
    public static func relayKey(
        agreementPrivate: Curve25519.KeyAgreement.PrivateKey,
        peerPublic: Curve25519.KeyAgreement.PublicKey,
        linkNonce: Data, hubID: UUID, deviceID: UUID, epoch: UInt32, direction: RelayDirection
    ) throws -> SymmetricKey
    /// base32(HMAC-SHA256(K_meta, "wt/name/v1" ‖ zone u8 ‖ kind_len u8 ‖ kind ‖ id utf8)[0..<16]),
    /// 26 lowercase characters. zone: .data = 1, .relay = 2.
    public static func recordName(metaKey: SymmetricKey, zone: CloudZoneID, kind: String, id: String) -> String
    /// UUID of SHA-256("wt/device-id/v1" ‖ dev_sig_pub)[0..<16] (D7).
    public static func deviceID(signingPublicKey: Curve25519.Signing.PublicKey) -> UUID
    /// Transcript T = SHA-256("wt/sas/v1" ‖ hub_id(16) ‖ nonce ‖ hub_sig_pub ‖ hub_kx_pub ‖ dev_sig_pub ‖ dev_kx_pub);
    /// okm = HKDF-SHA256(ikm: T, salt: nonce, info: "wt/sas/v1", 4 bytes);
    /// String(format: "%04u", UInt32(bigEndian okm) % 10_000)  (D6)
    public static func sas(
        hubID: UUID, linkNonce: Data,
        hubSigning: Curve25519.Signing.PublicKey, hubAgreement: Curve25519.KeyAgreement.PublicKey,
        deviceSigning: Curve25519.Signing.PublicKey, deviceAgreement: Curve25519.KeyAgreement.PublicKey
    ) -> String
    public static let zoneByte: [CloudZoneID: UInt8] = [.data: 1, .relay: 2]
}
```

Fixed synthetic inputs for every e2e fixture (Tasks 1–4 reuse them; the Go test of Task 6 too): `hub_kx_priv = 0x01…0x20`, `dev_kx_priv = 0x21…0x40`, `hub_sig_seed = 0x41…0x60`, `dev_sig_seed = 0x61…0x80`, `link_nonce = 0xA0…0xBF` (32 bytes), `K_meta = 0xC0…0xDF`, `hub_id = 00112233-4455-6677-8899-AABBCCDDEEFF` (each `a…b` is the byte sequence a, a+1, …, b).

- [ ] **Step 1: Failing RFC known-answer tests.** `E2EPrimitiveTests` pins CryptoKit and `WireBytes` against published vectors. Transcribe each value from the RFC text (the values below are the RFCs'; check every one against the RFC when typing it):

```swift
import CryptoKit
import XCTest
@testable import WatchtowerSync

final class E2EPrimitiveTests: XCTestCase {
    func testHKDFMatchesRFC5869CaseA1() {
        let ikm = SymmetricKey(data: Data(repeating: 0x0b, count: 22))
        let salt = Data(hex: "000102030405060708090a0b0c")
        let info = Data(hex: "f0f1f2f3f4f5f6f7f8f9")
        let okm = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: info, outputByteCount: 42)
        XCTAssertEqual(okm.withUnsafeBytes { Data($0) }.hexString,
                       "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
    }

    func testX25519MatchesRFC7748Section61() throws {
        let alice = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: Data(hex: "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"))
        let bob = try Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: Data(hex: "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb"))
        XCTAssertEqual(alice.publicKey.rawRepresentation.hexString,
                       "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
        XCTAssertEqual(bob.publicKey.rawRepresentation.hexString,
                       "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
        let shared = try alice.sharedSecretFromKeyAgreement(with: bob.publicKey)
        XCTAssertEqual(shared.withUnsafeBytes { Data($0) }.hexString,
                       "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")
    }

    func testEd25519VerifiesRFC8032Test1() throws {
        let key = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(hex: "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"))
        XCTAssertEqual(key.publicKey.rawRepresentation.hexString,
                       "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")
        let signature = Data(hex: "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b")
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: Data()))
    }

    func testHMACSHA256MatchesRFC4231Case2() {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data("what do ya want for nothing?".utf8), using: SymmetricKey(data: Data("Jefe".utf8)))
        XCTAssertEqual(Data(mac).hexString, "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
    }

    /// RFC 8439 §2.8.2: key 80…9f, nonce 07000000 40414243 44454647,
    /// AAD 50515253c0c1c2c3c4c5c6c7, the "Ladies and Gentlemen…" plaintext,
    /// tag 1ae10b594f09e26a7e902ecbd0600691. Copy the full 114-byte
    /// ciphertext from the RFC into `expectedCiphertext`.
    func testChaChaPolyMatchesRFC8439Section282() throws {
        let key = SymmetricKey(data: Data((0x80...0x9f).map { UInt8($0) }))
        let nonce = try ChaChaPoly.Nonce(data: Data(hex: "070000004041424344454647"))
        let plaintext = Data("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.".utf8)
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce,
                                      authenticating: Data(hex: "50515253c0c1c2c3c4c5c6c7"))
        XCTAssertEqual(box.tag.hexString, "1ae10b594f09e26a7e902ecbd0600691")
        XCTAssertEqual(box.ciphertext.hexString, Self.expectedCiphertext)
    }

    func testBase32MatchesRFC4648Section10LowercaseUnpadded() {
        let cases = ["": "", "f": "my", "fo": "mzxq", "foo": "mzxw6", "foob": "mzxw6yq",
                     "fooba": "mzxw6ytb", "foobar": "mzxw6ytboi"]
        for (input, expected) in cases {
            XCTAssertEqual(WireBytes.base32(Data(input.utf8)), expected, input)
        }
    }

    func testBigEndianRoundTripAndOutOfRangeReadsNil() {
        var data = Data()
        WireBytes.append(UInt32(0x0102_0304), to: &data)
        WireBytes.append(UInt64(0x0506_0708_090A_0B0C), to: &data)
        XCTAssertEqual(data.hexString, "01020304" + "05060708090a0b0c")
        XCTAssertEqual(WireBytes.readUInt64(data, at: 4), 0x0506_0708_090A_0B0C)
        XCTAssertNil(WireBytes.readUInt64(data, at: 5))
    }
}
```

- [ ] **Step 2: Failing derivation tests.** `E2EKeyDerivationTests` builds the fixed inputs above and checks properties plus the frozen file:

```swift
final class E2EKeyDerivationTests: XCTestCase {
    func testRelayKeysAgreeOnBothSidesAndDifferPerDirectionAndEpoch() throws {
        let k = try E2EFixtureKeys()
        func key(_ own: Curve25519.KeyAgreement.PrivateKey, _ peer: Curve25519.KeyAgreement.PublicKey,
                 _ dir: RelayDirection, _ epoch: UInt32) throws -> SymmetricKey {
            try KeyDerivation.relayKey(agreementPrivate: own, peerPublic: peer, linkNonce: k.linkNonce,
                                       hubID: k.hubID, deviceID: k.deviceID, epoch: epoch, direction: dir)
        }
        XCTAssertEqual(try key(k.hubKX, k.devKX.publicKey, .phoneToHub, 1), try key(k.devKX, k.hubKX.publicKey, .phoneToHub, 1))
        XCTAssertNotEqual(try key(k.hubKX, k.devKX.publicKey, .phoneToHub, 1), try key(k.hubKX, k.devKX.publicKey, .hubToPhone, 1))
        XCTAssertNotEqual(try key(k.hubKX, k.devKX.publicKey, .phoneToHub, 1), try key(k.hubKX, k.devKX.publicKey, .phoneToHub, 2))
    }

    func testRecordNameIs26Base32CharactersAndBindsZoneKindAndID() {
        let meta = SymmetricKey(data: E2EFixtureKeys.metaKeyBytes)
        let name = KeyDerivation.recordName(metaKey: meta, zone: .data, kind: "owner_ask", id: "42")
        XCTAssertEqual(name.count, 26)
        XCTAssertTrue(name.allSatisfy { "abcdefghijklmnopqrstuvwxyz234567".contains($0) })
        XCTAssertNotEqual(name, KeyDerivation.recordName(metaKey: meta, zone: .relay, kind: "owner_ask", id: "42"))
        XCTAssertNotEqual(name, KeyDerivation.recordName(metaKey: meta, zone: .data, kind: "owner_as", id: "k42"))
        XCTAssertEqual(name, KeyDerivation.recordName(metaKey: meta, zone: .data, kind: "owner_ask", id: "42"))
    }

    func testSASIsFourDigitsAndChangesWithEveryTranscriptInput() throws {
        let k = try E2EFixtureKeys()
        let base = k.sas()
        XCTAssertEqual(base.count, 4)
        XCTAssertTrue(base.allSatisfy(\.isNumber))
        XCTAssertNotEqual(base, k.sas(nonce: Data(repeating: 0xEE, count: 32)))
        XCTAssertNotEqual(base, k.sas(deviceAgreement: Curve25519.KeyAgreement.PrivateKey().publicKey))
    }

    func testDeviceIDIsDerivedFromTheSigningKey() throws {
        let k = try E2EFixtureKeys()
        XCTAssertEqual(KeyDerivation.deviceID(signingPublicKey: k.devSig.publicKey), k.deviceID)
        XCTAssertNotEqual(KeyDerivation.deviceID(signingPublicKey: k.hubSig.publicKey), k.deviceID)
    }

    func testDerivationsMatchTheFrozenVectors() throws {
        let k = try E2EFixtureKeys()
        let computed = KDFVectors(keys: k)   // every derivation above for epochs 1 and 2, both directions,
                                             // names for (data, heartbeat-free kinds: owner_ask/42, workbench/7),
                                             // (relay, action/<fixed uuid>), the SAS, the device id
        try E2EFixtures.check(computed, file: "kdf")
    }
}
```

  `E2EFixtureKeys` (in `Support/E2EFixtures.swift`) builds the keys from the fixed byte patterns and exposes `hubID`, `deviceID`, `linkNonce`, `hubKX`, `devKX`, `hubSig`, `devSig`, `metaKeyBytes` and `sas(nonce:deviceAgreement:)` with defaults. `KDFVectors` is a `Codable, Equatable` struct of hex strings. `E2EFixtures.check(_:file:)`: when the environment has `WT_E2E_REGENERATE=1` it writes `Fixtures/e2e/<file>.json` (sorted keys, pretty-printed, trailing newline) and fails the test with "regenerated, re-run without WT_E2E_REGENERATE"; otherwise it decodes the file and `XCTAssertEqual`s. The fixture directory is found the way `WorkbenchMirrorFixtureTests` finds `Fixtures/workbench` (relative to `#filePath`).

- [ ] **Step 3: Run to fail.** `make kit-test FILTER='E2EPrimitiveTests|E2EKeyDerivationTests' > /tmp/e2e1a.log 2>&1; echo "exit=$?"` → build failure (`WireBytes`, `KeyDerivation` missing).

- [ ] **Step 4: Implement.** `WireBytes` as specified. `KeyDerivation`:

```swift
import CryptoKit
import Foundation

public enum KeyDerivation {
    public static let zoneByte: [CloudZoneID: UInt8] = [.data: 1, .relay: 2]

    public static func relayKey(
        agreementPrivate: Curve25519.KeyAgreement.PrivateKey, peerPublic: Curve25519.KeyAgreement.PublicKey,
        linkNonce: Data, hubID: UUID, deviceID: UUID, epoch: UInt32, direction: RelayDirection
    ) throws -> SymmetricKey {
        let shared = try agreementPrivate.sharedSecretFromKeyAgreement(with: peerPublic)
        var info = Data("wt/relay/v1/\(direction.rawValue)".utf8)
        info.append(0)
        info.append(WireBytes.bytes(of: hubID))
        info.append(WireBytes.bytes(of: deviceID))
        WireBytes.append(epoch, to: &info)
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: linkNonce, sharedInfo: info, outputByteCount: 32)
    }

    public static func recordName(metaKey: SymmetricKey, zone: CloudZoneID, kind: String, id: String) -> String {
        var message = Data("wt/name/v1".utf8)
        message.append(zoneByte[zone] ?? 0)
        let kindBytes = Data(kind.utf8)
        message.append(UInt8(clamping: kindBytes.count))
        message.append(kindBytes.prefix(255))
        message.append(Data(id.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: metaKey)
        return WireBytes.base32(Data(mac).prefix(16))
    }
    // deviceID and sas exactly as the Interfaces block says.
}
```

  Kinds longer than 255 bytes do not exist (`SliceKind`/`RelayRecordKind` raw values are short); `recordName` clamps rather than traps.

- [ ] **Step 5: Freeze the vectors.** `WT_E2E_REGENERATE=1 make kit-test FILTER=E2EKeyDerivationTests > /tmp/e2e1b.log 2>&1; echo "exit=$?"` (expected: the regeneration failure message), inspect `Fixtures/e2e/kdf.json` (hex only, no secrets beyond the synthetic patterns), then run Step 3's command again → `exit=0`. `make lint-diff`.

- [ ] **Step 6: Commit.**

```bash
git add WatchtowerKit
git commit -m "feat(mobile-e2e): Kit key derivation, record names, SAS and frozen vectors

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

Self-review: the checklist above.

---

## Task 2: Kit — chunked asset cipher

**Depends on:** Task 1. **Lane:** Kit; may run in parallel with Task 5 (separate worktree; distinct files).

**Files:**
- Create `WatchtowerKit/Sources/WatchtowerSync/Secure/ChunkedAssetCipher.swift` (`AssetHeader`, `AssetDescriptor`, `ChunkedAssetCipher`, `AssetCipherError`).
- Create `WatchtowerKit/Tests/WatchtowerSyncTests/ChunkedAssetCipherTests.swift`.
- Create (generated) `WatchtowerKit/Tests/Fixtures/e2e/asset.json`.

**Interfaces (produces):**

```swift
/// 37 bytes on the wire: "WTA" | ver u8 (1) | suite u8 (1) | asset_id 16 | chunk_size u32 | total_len u64 | chunk_count u32.
public struct AssetHeader: Equatable, Sendable {
    public let assetID: UUID
    public let suite: UInt8
    public let chunkSize: UInt32
    public let totalLength: UInt64
    public let chunkCount: UInt32          // max(1, ceil(totalLength / chunkSize))
    public static let encodedLength = 37
    public func encoded() -> Data
    public static func parse(_ data: Data) throws -> AssetHeader
}

/// What the owning record's inner frame carries (101 bytes encoded): key 32 ‖ header 37 ‖ SHA-256(plaintext) 32.
public struct AssetDescriptor: Equatable, Sendable {
    public let key: Data                    // 32 bytes (K_asset)
    public let header: AssetHeader
    public let plaintextDigest: Data        // 32 bytes
    public static let encodedLength = 101
    public func encoded() -> Data
    public static func parse(_ data: Data) throws -> AssetDescriptor
}

public enum AssetCipherError: Error, Equatable {
    case badHeader, headerMismatch, truncated, oversized, chunkAuthenticationFailed(UInt32), digestMismatch
}

public enum ChunkedAssetCipher {
    public static let chunkSize: UInt32 = 1 << 20          // 1 MiB (spec §2.5)
    /// File layout: header (37) ‖ chunk_0 … chunk_{n-1}; each chunk = chunkSize plaintext bytes (the last
    /// zero-padded) sealed with nonce u32 0 ‖ u64 c, AAD header ‖ u64 c ‖ u8 last, plus a 16-byte tag.
    public static func sealedLength(forPlaintext length: Int64, chunkSize: UInt32 = chunkSize) -> Int64
    public static func encrypt(_ plaintext: Data, assetID: UUID = UUID(), key: SymmetricKey = SymmetricKey(size: .bits256),
                               chunkSize: UInt32 = chunkSize) throws -> (sealed: Data, descriptor: AssetDescriptor)
    public static func decrypt(_ sealed: Data, descriptor: AssetDescriptor) throws -> Data
    /// Streaming, one chunk resident: reads `source`, writes `destination` atomically (temp file + move).
    public static func encryptFile(at source: URL, to destination: URL, assetID: UUID = UUID(),
                                   key: SymmetricKey = SymmetricKey(size: .bits256),
                                   chunkSize: UInt32 = chunkSize) throws -> AssetDescriptor
    public static func decryptFile(at source: URL, to destination: URL, descriptor: AssetDescriptor) throws
}
```

- [ ] **Step 1: Failing tests.** `ChunkedAssetCipherTests` uses `chunkSize: 16` so cases stay small:

```swift
final class ChunkedAssetCipherTests: XCTestCase {
    private let key = SymmetricKey(data: Data((0xE0...0xFF).map { UInt8($0) }))
    private let assetID = UUID(uuidString: "0F0E0D0C-0B0A-0908-0706-050403020100")!

    func testRoundTripAcrossChunkBoundariesAndPadsEveryChunkToFullSize() throws {
        for length in [0, 1, 15, 16, 17, 47, 48, 49] {
            let plain = Data((0..<length).map { UInt8($0 & 0xFF) })
            let (sealed, descriptor) = try ChunkedAssetCipher.encrypt(plain, assetID: assetID, key: key, chunkSize: 16)
            XCTAssertEqual(Int64(sealed.count), ChunkedAssetCipher.sealedLength(forPlaintext: Int64(length), chunkSize: 16))
            XCTAssertEqual(descriptor.header.chunkCount, UInt32(max(1, (length + 15) / 16)))
            XCTAssertEqual(try ChunkedAssetCipher.decrypt(sealed, descriptor: descriptor), plain, "length \(length)")
        }
    }

    func testTruncationDroppingTheLastChunkFails() throws {
        let (sealed, d) = try ChunkedAssetCipher.encrypt(Data(count: 40), assetID: assetID, key: key, chunkSize: 16)
        XCTAssertThrowsError(try ChunkedAssetCipher.decrypt(sealed.dropLast(32), descriptor: d)) {
            XCTAssertEqual($0 as? AssetCipherError, .truncated)
        }
    }

    func testSwappedChunksFailAuthentication() throws {
        let (sealed, d) = try ChunkedAssetCipher.encrypt(Data((0..<48).map { UInt8($0) }), assetID: assetID, key: key, chunkSize: 16)
        let h = AssetHeader.encodedLength, c = 32
        var swapped = Data(sealed.prefix(h))
        swapped.append(sealed[(h + c)..<(h + 2 * c)])
        swapped.append(sealed[h..<(h + c)])
        swapped.append(sealed.suffix(from: h + 2 * c))
        XCTAssertThrowsError(try ChunkedAssetCipher.decrypt(swapped, descriptor: d)) {
            XCTAssertEqual($0 as? AssetCipherError, .chunkAuthenticationFailed(0))
        }
    }

    func testAFileOfAnotherAssetIsRefusedByTheHeader() throws {
        let (sealed, _) = try ChunkedAssetCipher.encrypt(Data(count: 20), assetID: assetID, key: key, chunkSize: 16)
        let (_, other) = try ChunkedAssetCipher.encrypt(Data(count: 20), assetID: UUID(), key: key, chunkSize: 16)
        XCTAssertThrowsError(try ChunkedAssetCipher.decrypt(sealed, descriptor: other)) {
            XCTAssertEqual($0 as? AssetCipherError, .headerMismatch)
        }
    }

    func testAppendedBytesAreRefused() throws {
        let (sealed, d) = try ChunkedAssetCipher.encrypt(Data(count: 20), assetID: assetID, key: key, chunkSize: 16)
        XCTAssertThrowsError(try ChunkedAssetCipher.decrypt(sealed + Data([0]), descriptor: d))
    }

    func testTheProductionChunkSizeAllowsTwentyMiBInTheReplicaCap() {
        XCTAssertEqual(ChunkedAssetCipher.sealedLength(forPlaintext: 20 * 1_048_576), 20 * 1_048_576 + 37 + 20 * 16)
    }

    func testVectorsMatchTheFrozenFile() throws {
        // AssetVectors: key, asset id, chunk size 16, plaintexts of 0, 16 and 40 bytes → sealed hex + descriptor hex.
        try E2EFixtures.check(AssetVectors(key: key, assetID: assetID), file: "asset")
    }
}
```

  Add one more test in the same file, `testFileStreamingMatchesInMemoryAndLeavesNoTempFileOnFailure`: write 56 bytes (3.5 chunks of 16) to a file in `FileManager.default.temporaryDirectory/<UUID>/`, `encryptFile(at:to:chunkSize: 16)`, `decryptFile` into a third file, assert its bytes equal the input; then flip one byte of the sealed file, assert `decryptFile` throws `.chunkAuthenticationFailed`, that the destination does not exist, and that the directory holds only the input and the sealed file (no temp left). Remove the directory in `tearDown`.

- [ ] **Step 2: Run to fail.** `make kit-test FILTER=ChunkedAssetCipherTests > /tmp/e2e2a.log 2>&1; echo "exit=$?"`.

- [ ] **Step 3: Implement.** Chunk nonce = 4 zero bytes ‖ `UInt64(c)` big-endian. AAD = `header.encoded() ‖ UInt64(c) BE ‖ (c == count − 1 ? 1 : 0)`. Each chunk's plaintext is exactly `chunkSize` bytes: the bytes of the input, then zeros. Decrypt: parse the header from the file and require `== descriptor.header` (`headerMismatch`); require the file length `== sealedLength(header.totalLength, header.chunkSize)` (`truncated` when shorter, `oversized` when longer); open each chunk (`chunkAuthenticationFailed(c)`); keep the first `totalLength` bytes; compare SHA-256 with `plaintextDigest` (`digestMismatch`). `decryptFile` writes into a temp file next to the destination and moves it only after the digest matched; on any throw the temp file is removed. `encryptFile` takes `totalLength` from the file size up front (`attributesOfItem`), so the header is final before the first chunk, then reads with `FileHandle.read(upToCount:)` one chunk at a time, digests incrementally (`var hasher = SHA256()`), and fails with `.truncated` if the file ends before `totalLength` bytes were read (it changed while being sealed).

- [ ] **Step 4: Freeze, run to pass.** `WT_E2E_REGENERATE=1 make kit-test FILTER=ChunkedAssetCipherTests …` once, inspect `asset.json`, then the Step 2 command → `exit=0`. `make lint-diff`.

- [ ] **Step 5: Commit.** `git add WatchtowerKit && git commit -m "feat(mobile-e2e): chunked streaming asset cipher" …` (with the Co-Authored-By line).

Self-review: the checklist above.

---

## Task 3: Kit — envelope, inner frame, padding, sign and verify

**Depends on:** Tasks 1, 2. **Lane:** Kit.

**Files:**
- Create `WatchtowerKit/Sources/WatchtowerSync/Secure/Envelope.swift` (`EnvelopeClass`, `EnvelopeHeader`, `EnvelopeContext`, `Envelope`, `EnvelopeError`).
- Create `WatchtowerKit/Sources/WatchtowerSync/Secure/InnerFrame.swift`, `Padding.swift`, `EnvelopeSealer.swift`.
- Create `WatchtowerKit/Tests/WatchtowerSyncTests/EnvelopeTests.swift`, `PaddingTests.swift`.
- Create (generated) `WatchtowerKit/Tests/Fixtures/e2e/envelope.json`.

**Interfaces (produces):**

```swift
public enum EnvelopeClass: UInt16, Sendable, CaseIterable {
    case data = 1          // AEAD K_data[e], signed by hub_sig
    case alert = 2         // AEAD K_alert[e], signed by hub_sig
    case keybox = 3        // HPKE to dev_kx, signed by hub_sig (Task 4)
    case hello = 4         // HPKE to hub_kx, signed by dev_sig (Task 4)
    case relayToHub = 5    // AEAD K_relay p2h[e]
    case relayToPhone = 6  // AEAD K_relay h2p[e]
}

/// 68 bytes: "WTE" | ver | suite | flags | hub_id 16 | sender_id 16 | epoch u32 | seq u64 | nonce 12 | class u16 | body_len u32.
public struct EnvelopeHeader: Equatable, Sendable {
    public static let length = 68
    public static let version: UInt8 = 1
    public static let suite1: UInt8 = 1
    public struct Flags: OptionSet, Sendable { public let rawValue: UInt8
        public static let signed = Flags(rawValue: 1), hasAsset = Flags(rawValue: 2), padded = Flags(rawValue: 4) }
    public let flags: Flags
    public let hubID: UUID
    public let senderID: UUID
    public let epoch: UInt32
    public let seq: UInt64
    public let nonce: Data            // 12 bytes; zeros for the HPKE classes
    public let envelopeClass: EnvelopeClass
    public let bodyLength: UInt32
    public func encoded() -> Data
}

/// The out-of-band AAD (spec §2.4): which zone and which wire record name the envelope belongs to.
public struct EnvelopeContext: Equatable, Sendable {
    public let zone: CloudZoneID
    public let wireName: String
    public init(zone: CloudZoneID, wireName: String)
    /// header ‖ zone u8 ‖ name_len u16 ‖ name utf8
    func aad(header: EnvelopeHeader) -> Data
}

public struct Envelope: Equatable, Sendable {
    public let header: EnvelopeHeader
    public let body: Data            // ciphertext ‖ tag (AEAD) or enc 32 ‖ ciphertext ‖ tag (HPKE)
    public let signature: Data?      // 64 bytes when header.flags contains .signed
    public func encoded() -> Data
    /// Refuses wrong magic, unknown version or suite (loudly: `.unsupportedVersion`/`.unsupportedSuite`,
    /// the phone's "Update Watchtower" path), unknown class, and any length mismatch.
    public static func parse(_ data: Data) throws -> Envelope
    public static let maxBytes = 900_000          // == SlicePublisher.maxPayloadBytes
}

public enum EnvelopeError: Error, Equatable {
    case tooShort, badMagic, unsupportedVersion(UInt8), unsupportedSuite(UInt8), unknownClass(UInt16)
    case lengthMismatch, signatureMissing, signatureInvalid, authenticationFailed, frameMalformed
    case oversized, wrongClass(EnvelopeClass), wrongHub, wrongSender
}

/// The encrypted plaintext (D1): inner_ver u8 (1) | kind_len u8 | kind | id_len u16 | id | notify_len u8 | notify
/// | asset_flag u8 | [AssetDescriptor 101] | payload_len u32 | payload | zero padding.
public struct InnerFrame: Equatable, Sendable {
    public let kind: String
    public let id: String
    public let notifyLevel: String?
    public let asset: AssetDescriptor?
    public let payload: Data
    public init(kind: String, id: String, notifyLevel: String? = nil, asset: AssetDescriptor? = nil, payload: Data)
    public var encodedLength: Int
    public func encoded(paddedTo length: Int) throws -> Data
    public static func parse(_ data: Data) throws -> InnerFrame   // ignores trailing zeros only; non-zero padding → frameMalformed
}

public enum Padding {
    public static let buckets = [256, 1_024, 4_096, 16_384, 65_536]
    /// Next bucket, then 64 KiB multiples, clipped to `cap` (D12). nil when `length > cap`.
    public static func paddedLength(_ length: Int, cap: Int) -> Int?
}

public enum EnvelopeSealer {
    /// Largest padded frame for a class: Envelope.maxBytes − 68 − 16 − (signed ? 64 : 0).
    public static func frameCap(signed: Bool) -> Int
    /// The envelope size a frame produces (header + padded frame + tag + signature); nil when it cannot fit.
    public static func sealedLength(frameLength: Int, signed: Bool) -> Int?
    public static func sealSymmetric(
        _ frame: InnerFrame, envelopeClass: EnvelopeClass, key: SymmetricKey,
        hubID: UUID, senderID: UUID, epoch: UInt32, seq: UInt64, context: EnvelopeContext,
        signer: Curve25519.Signing.PrivateKey?, nonce: ChaChaPoly.Nonce = ChaChaPoly.Nonce()
    ) throws -> Data
    /// Parses, checks the class is one of `accepting`, verifies the signature when `verifier` is given
    /// (and requires one then), resolves the key from the header, opens, parses the frame.
    public static func openSymmetric(
        _ data: Data, accepting: Set<EnvelopeClass>, context: EnvelopeContext,
        verifier: Curve25519.Signing.PublicKey?, key: (EnvelopeHeader) throws -> SymmetricKey
    ) throws -> (header: EnvelopeHeader, frame: InnerFrame)
    /// Signature check only (no secret key): the replica's apply-time check.
    public static func verify(_ envelope: Envelope, context: EnvelopeContext, key: Curve25519.Signing.PublicKey) throws
    /// Message signed: "wt/sig/v1" ‖ context.aad(header) ‖ body.
    static func signatureMessage(_ header: EnvelopeHeader, body: Data, context: EnvelopeContext) -> Data
}
```

- [ ] **Step 1: Failing tests.**

```swift
final class PaddingTests: XCTestCase {
    func testBucketsThenSixtyFourKiBMultiples() {
        let cap = 10_000_000
        XCTAssertEqual(Padding.paddedLength(0, cap: cap), 256)
        XCTAssertEqual(Padding.paddedLength(256, cap: cap), 256)
        XCTAssertEqual(Padding.paddedLength(257, cap: cap), 1_024)
        XCTAssertEqual(Padding.paddedLength(16_385, cap: cap), 65_536)
        XCTAssertEqual(Padding.paddedLength(65_537, cap: cap), 131_072)
    }

    /// Review Focus 3.
    func testPaddedLengthIsClippedToTheCap() {
        let cap = EnvelopeSealer.frameCap(signed: true)
        XCTAssertEqual(cap, 900_000 - 68 - 16 - 64)
        XCTAssertEqual(Padding.paddedLength(cap - 10, cap: cap), cap)
        XCTAssertEqual(Padding.paddedLength(cap, cap: cap), cap)
        XCTAssertNil(Padding.paddedLength(cap + 1, cap: cap))
        XCTAssertEqual(EnvelopeSealer.sealedLength(frameLength: cap, signed: true), 900_000)
    }
}

final class EnvelopeTests: XCTestCase {
    private let k = try! E2EFixtureKeys()
    private let dataKey = SymmetricKey(data: Data((0x10...0x2F).map { UInt8($0) }))
    private let fixedNonce = try! ChaChaPoly.Nonce(data: Data((0x50...0x5B).map { UInt8($0) }))
    private let context = EnvelopeContext(zone: .data, wireName: "abcdefghijklmnopqrstuvwxyz")

    private func seal(_ frame: InnerFrame, seq: UInt64 = 7, context: EnvelopeContext? = nil) throws -> Data {
        try EnvelopeSealer.sealSymmetric(frame, envelopeClass: .data, key: dataKey, hubID: k.hubID, senderID: k.hubID,
                                         epoch: 1, seq: seq, context: context ?? self.context, signer: k.hubSig, nonce: fixedNonce)
    }

    func testHeaderLayoutIsSixtyEightBytesInSpecOrder() throws {
        let data = try seal(InnerFrame(kind: "owner_ask", id: "42", payload: Data("{}".utf8)))
        XCTAssertEqual(data.prefix(3), Data("WTE".utf8))
        XCTAssertEqual(data[3], 1); XCTAssertEqual(data[4], 1); XCTAssertEqual(data[5], 0b101)   // signed | padded
        XCTAssertEqual(data[6..<22], WireBytes.bytes(of: k.hubID))
        XCTAssertEqual(WireBytes.readUInt32(data, at: 38), 1)
        XCTAssertEqual(WireBytes.readUInt64(data, at: 42), 7)
        XCTAssertEqual(data[50..<62], Data((0x50...0x5B).map { UInt8($0) }))
        XCTAssertEqual(WireBytes.readUInt16(data, at: 62), EnvelopeClass.data.rawValue)
        XCTAssertEqual(data.count, 68 + 256 + 16 + 64)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("owner_ask"), "the kind is inside the ciphertext (D1)")
    }

    func testRoundTripReturnsTheFrame() throws {
        let frame = InnerFrame(kind: "meeting_transcript", id: "9", notifyLevel: "urgent",
                               asset: try ChunkedAssetCipher.encrypt(Data("[]".utf8), chunkSize: 16).descriptor,
                               payload: Data(#"{"title":"Acme sync"}"#.utf8))
        let opened = try EnvelopeSealer.openSymmetric(try seal(frame), accepting: [.data], context: context,
                                                      verifier: k.hubSig.publicKey) { _ in self.dataKey }
        XCTAssertEqual(opened.frame, frame)
        XCTAssertEqual(opened.header.seq, 7)
    }

    func testMovingTheEnvelopeToAnotherRecordOrZoneFails() throws {
        let data = try seal(InnerFrame(kind: "owner_ask", id: "42", payload: Data()))
        for other in [EnvelopeContext(zone: .data, wireName: "another-record-name-aaaaaa"),
                      EnvelopeContext(zone: .relay, wireName: context.wireName)] {
            XCTAssertThrowsError(try EnvelopeSealer.openSymmetric(data, accepting: [.data], context: other,
                                                                  verifier: k.hubSig.publicKey) { _ in self.dataKey })
        }
    }

    func testAFlippedHeaderByteFailsAndUnsignedDataIsRefusedWhenAVerifierIsGiven() throws {
        var data = try seal(InnerFrame(kind: "owner_ask", id: "42", payload: Data()))
        data[45] ^= 1   // seq
        XCTAssertThrowsError(try EnvelopeSealer.openSymmetric(data, accepting: [.data], context: context,
                                                              verifier: k.hubSig.publicKey) { _ in self.dataKey })
        let unsigned = try EnvelopeSealer.sealSymmetric(InnerFrame(kind: "x", id: "1", payload: Data()), envelopeClass: .data,
                                                        key: dataKey, hubID: k.hubID, senderID: k.hubID, epoch: 1, seq: 1,
                                                        context: context, signer: nil)
        XCTAssertThrowsError(try EnvelopeSealer.openSymmetric(unsigned, accepting: [.data], context: context,
                                                              verifier: k.hubSig.publicKey) { _ in self.dataKey }) {
            XCTAssertEqual($0 as? EnvelopeError, .signatureMissing)
        }
    }

    func testASignatureByAnotherKeyIsRefusedEvenWithTheRightAEADKey() throws {
        // A same-Apple-ID writer that learned K_data (a relay or team member, spec §2.2) still cannot author.
        let forged = try EnvelopeSealer.sealSymmetric(InnerFrame(kind: "owner_ask", id: "42", payload: Data()),
                                                      envelopeClass: .data, key: dataKey, hubID: k.hubID, senderID: k.hubID,
                                                      epoch: 1, seq: 9, context: context, signer: k.devSig)
        XCTAssertThrowsError(try EnvelopeSealer.openSymmetric(forged, accepting: [.data], context: context,
                                                              verifier: k.hubSig.publicKey) { _ in self.dataKey }) {
            XCTAssertEqual($0 as? EnvelopeError, .signatureInvalid)
        }
    }

    func testUnknownVersionAndSuiteAreRefusedLoudly() throws {
        var data = try seal(InnerFrame(kind: "x", id: "1", payload: Data()))
        data[3] = 2
        XCTAssertThrowsError(try Envelope.parse(data)) { XCTAssertEqual($0 as? EnvelopeError, .unsupportedVersion(2)) }
        data[3] = 1; data[4] = 2
        XCTAssertThrowsError(try Envelope.parse(data)) { XCTAssertEqual($0 as? EnvelopeError, .unsupportedSuite(2)) }
    }

    func testTrailingBytesAreRefused() throws {
        let data = try seal(InnerFrame(kind: "x", id: "1", payload: Data()))
        XCTAssertThrowsError(try Envelope.parse(data + Data([0]))) { XCTAssertEqual($0 as? EnvelopeError, .lengthMismatch) }
    }

    func testNonZeroPaddingIsRefused() throws {
        var frame = try InnerFrame(kind: "x", id: "1", payload: Data([7])).encoded(paddedTo: 256)
        frame[255] = 1
        XCTAssertThrowsError(try InnerFrame.parse(frame)) { XCTAssertEqual($0 as? EnvelopeError, .frameMalformed) }
    }

    func testAFrameThatDoesNotFitEvenUnpaddedThrowsOversized() {
        let frame = InnerFrame(kind: "x", id: "1", payload: Data(count: EnvelopeSealer.frameCap(signed: true)))
        XCTAssertThrowsError(try seal(frame)) { XCTAssertEqual($0 as? EnvelopeError, .oversized) }
    }

    func testVectorsMatchTheFrozenFile() throws {
        // EnvelopeVectors: for classes data (signed), relayToHub and relayToPhone (unsigned, relay keys from Task 1),
        // fixed nonce, the context, the frame fields, the sealed hex. Signatures are checked by verification, not
        // compared as bytes (CryptoKit's Ed25519 is randomized): the vector stores one signature produced once,
        // and the test verifies it against the stored message.
        try E2EFixtures.check(EnvelopeVectors(keys: k, dataKey: dataKey, nonce: fixedNonce), file: "envelope")
    }
}
```

- [ ] **Step 2: Run to fail.** `make kit-test FILTER='EnvelopeTests|PaddingTests' > /tmp/e2e3a.log 2>&1; echo "exit=$?"`.

- [ ] **Step 3: Implement.** Seal: `paddedLength(frame.encodedLength, cap: frameCap(signed:))` else `.oversized`; flags = `.padded` always, `.signed` with a signer, `.hasAsset` with `frame.asset`; header with `bodyLength = padded + 16`; `ChaChaPoly.seal(frameBytes, using: key, nonce: nonce, authenticating: context.aad(header:))`; body = `ciphertext ‖ tag`; signature = `signer.signature(for: signatureMessage(...))`. Open: parse (strict lengths: `68 + bodyLength + (signed ? 64 : 0) == data.count`), class in `accepting` else `.wrongClass`, verifier → require `.signed` (`.signatureMissing`) and verify (`.signatureInvalid`) **before** decrypting, then key(header), `ChaChaPoly.open` (`.authenticationFailed`), `InnerFrame.parse`. Header `nonce` must be 12 bytes; `EnvelopeHeader.encoded()` writes in the order of the Interfaces block.

- [ ] **Step 4: Freeze, run to pass.** Regenerate `envelope.json` once with `WT_E2E_REGENERATE=1`, inspect, re-run → `exit=0`. `make lint-diff`.

- [ ] **Step 5: Commit.** `feat(mobile-e2e): versioned envelope with inner frame, padding and hub signatures`.

Self-review: the checklist above.

---

## Task 4: Kit — pairing wire: HPKE boxes, hello, keybox, `LinkPayload` v3

**Depends on:** Task 3. **Lane:** Kit.

**Files:**
- Create `WatchtowerKit/Sources/WatchtowerSync/Secure/SealedBox.swift` (HPKE classes on top of the envelope).
- Create `WatchtowerKit/Sources/WatchtowerSync/Link/DeviceHello.swift`, `Link/Keybox.swift`.
- Modify `WatchtowerKit/Sources/WatchtowerSync/Link/LinkPayload.swift` (v3; `hubSigningKey`, `hubAgreementKey`), `Link/DeviceGrant.swift` (`awaitingConfirmation`, `revoked`), `Relay/RelayRecordKind.swift` (`hello`), `Sync/CloudRecordFactory.swift` (`record(for hello:)`).
- Test: `WatchtowerKit/Tests/WatchtowerSyncTests/HPKEVectorTests.swift`, `SealedBoxTests.swift`, `KeyboxTests.swift`; modify `LinkPayloadTests.swift` (v2 cases become "older version" cases; new v3 frozen URL).
- Create `WatchtowerKit/Tests/Fixtures/e2e/hpke-rfc9180-a21.json` (transcribed, not generated).

**Interfaces (produces):**

```swift
public enum SealedBox {
    public static let ciphersuite = HPKE.Ciphersuite(kem: .Curve25519_HKDF_SHA256, kdf: .HKDF_SHA256, aead: .chaChaPoly)
    /// class .hello: info "wt/hello/v1" ‖ hub_id ‖ link_nonce; signed by the device's own key (proof of possession).
    /// class .keybox: info "wt/keybox/v1" ‖ hub_id ‖ device_id; signed by hub_sig.
    /// Body = enc (32) ‖ HPKE ciphertext ‖ tag; header nonce = 12 zero bytes; AAD = context.aad(header).
    public static func seal(_ frame: InnerFrame, envelopeClass: EnvelopeClass, to recipient: Curve25519.KeyAgreement.PublicKey,
                            info: Data, hubID: UUID, senderID: UUID, epoch: UInt32, seq: UInt64,
                            context: EnvelopeContext, signer: Curve25519.Signing.PrivateKey) throws -> Data
    public static func open(_ data: Data, envelopeClass: EnvelopeClass, recipient: Curve25519.KeyAgreement.PrivateKey,
                            info: Data, context: EnvelopeContext,
                            verifier: Curve25519.Signing.PublicKey?) throws -> (header: EnvelopeHeader, frame: InnerFrame)
    public static func helloInfo(hubID: UUID, linkNonce: Data) -> Data
    public static func keyboxInfo(hubID: UUID, deviceID: UUID) -> Data
}

/// Plain payload of the hello (RelayCoder JSON). The phone's `DevicePayload` plus its public keys (base64url).
public struct DeviceHello: Codable, Equatable, Sendable {
    public let device: DevicePayload
    public let signingKey: String          // wire "signing_key"
    public let agreementKey: String        // wire "agreement_key"
    public var recordName: String { "hello-\(device.deviceID)" }   // key-free name (D7)
}

/// Plain payload of the keybox (RelayCoder JSON): the grant every reader already decodes, plus keys once linked.
public struct Keybox: Codable, Equatable, Sendable {
    public let grant: DeviceGrant
    public let keys: KeyboxKeys?
    public static func recordName(deviceID: String) -> String { "keybox-\(deviceID)" }
}
public struct KeyboxKeys: Codable, Equatable, Sendable {
    public let epoch: UInt32
    public let dataKey: String             // base64url, 32 bytes
    public let alertKey: String
    public let metaKey: String
    public let previousEpoch: UInt32?      // the epoch just retired, kept while its records are being republished
    public let previousDataKey: String?
    public let previousAlertKey: String?
}

// DeviceGrant gains (absent keys when nil, the wire stays compatible):
public let awaitingConfirmation: Bool?    // the hub read the hello and waits for the owner
public let revoked: Bool?                 // removed on the Mac (D9)

// LinkRefusal gains `.notConfirmed = "not_confirmed"` (in knownValues): the owner refused, or closed the sheet.

// LinkPayload: currentVersion = 3; new required fields
public let hubSigningKey: String          // wire "hub_sig", base64url of 32 bytes
public let hubAgreementKey: String        // wire "hub_kx"
// RelayRecordKind: case hello
```

- [ ] **Step 1: Failing tests.**
  - `HPKEVectorTests.testCryptoKitOpensRFC9180A21BaseModeFirstEncryption`: load `hpke-rfc9180-a21.json` — transcribe from RFC 9180 Appendix A.2.1 (DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, ChaCha20Poly1305, mode_base): `info`, `skRm`, `enc`, and the first encryption's `aad`, `pt`, `ct` — then `HPKE.Recipient(privateKey: skRm, ciphersuite: SealedBox.ciphersuite, info: info, encapsulatedKey: enc).open(ct, authenticating: aad) == pt`. This is the one cross-language check for HPKE (Go 1.25 has no `crypto/hpke`).
  - `SealedBoxTests`: `testAHelloOpensOnlyWithTheHubKeyAndTheCodesNonce` (another nonce in `info` fails; another hub private key fails); `testAKeyboxIsRefusedWithoutTheHubSignature` (signed by `devSig` → `.signatureInvalid`); `testHPKEBodiesDifferEachSealButOpenToTheSameFrame`; `testTheEnvelopeNonceOfAnHPKEClassIsZero`.
  - `KeyboxTests`: `testAKeyboxEncodesTheGrantByteForByteAsDeviceGrant` (the `grant` object's JSON equals `RelayCoder` of the same `DeviceGrant`, so every reader keeps decoding `DeviceGrant`); `testAbsentKeysAndFlagsAreAbsentKeys`.
  - `LinkPayloadTests`: `testV3RoundTripsAndCarriesTheHubKeys`, `testAV2CodeReadsUpdateTheMac` (`.olderVersion`), `testAV4CodeReadsUpdateThePhone`, `testAMissingHubKeyIsMissingField("hub_kx")`, `testAQRWithHubKeysStaysUnderTheEncoderLimit` (the URL is ≤ 1 200 characters with two 120-character share URLs; error correction M holds it). Keep the existing v2 frozen URL test, renamed to assert `.olderVersion`.

- [ ] **Step 2: Run to fail.** `make kit-test FILTER='HPKEVectorTests|SealedBoxTests|KeyboxTests|LinkPayloadTests' > /tmp/e2e4a.log 2>&1; echo "exit=$?"`.

- [ ] **Step 3: Implement.** `SealedBox.seal`: build the header with zero nonce and `bodyLength = 32 + padded + 16`, `var sender = try HPKE.Sender(recipientKey:ciphersuite:info:)`, `sender.seal(frameBytes, authenticating: context.aad(header:))`, body = `sender.encapsulatedKey ‖ sealed`, sign. `open`: verify first when a verifier is given (for `.hello` the verifier is nil at the parse step; the hub verifies with `DeviceHello.signingKey` after opening, and checks `device_id == KeyDerivation.deviceID(signingKey)` — Task 13), then `HPKE.Recipient(...).open`. `LinkPayload.issue(...)` gains the two keys as parameters.

- [ ] **Step 4: Run to pass.** Step 2 command → `exit=0`; `make lint-diff`.

- [ ] **Step 5: Commit.** `feat(mobile-e2e): HPKE hello and keybox, LinkPayload v3` (the message notes the rewritten v2 LinkPayload tests).

Self-review: the checklist above.

---

## Task 5: Kit — key stores and the sequence allocator

**Depends on:** Task 1. **Lane:** Kit; may run in parallel with Task 2.

**Files:**
- Create `WatchtowerKit/Sources/WatchtowerSync/Secure/KeyStore.swift` (protocols, value types, errors), `Secure/KeychainBackend.swift` (`SecItem` wrapper), `Secure/KeychainKeyStore.swift` (`KeychainPhoneKeyStore`, `KeychainHubKeyStore`), `Secure/InMemoryKeyStore.swift`, `Secure/SeqAllocator.swift`.
- Test: `WatchtowerKit/Tests/WatchtowerSyncTests/KeyStoreTests.swift`, `SeqAllocatorTests.swift` (over a fake backend; the real `SecItem` path is exercised by the phone suite in Task 16 and the device smoke).

**Interfaces (produces):**

```swift
public enum KeyAccess: Sendable, Equatable { case whenUnlocked, afterFirstUnlock }   // always ThisDeviceOnly
public enum KeyStoreError: Error, Equatable { case locked, missingEntitlement, corrupt(String), unexpected(Int32) }

public protocol KeychainBackend: Sendable {
    func read(account: String, group: String?) throws -> Data?                 // locked → KeyStoreError.locked
    func write(_ data: Data, account: String, access: KeyAccess, group: String?, dataProtection: Bool) throws
    func delete(account: String, group: String?) throws
}
/// kSecClassGenericPassword, service "com.aiwatchtowers.watchtower.e2e", kSecAttrSynchronizable never set,
/// kSecAttrAccessibleWhenUnlockedThisDeviceOnly / AfterFirstUnlockThisDeviceOnly, kSecUseDataProtectionKeychain
/// on macOS. errSecInteractionNotAllowed → .locked, errSecMissingEntitlement → .missingEntitlement.
public struct SecItemKeychainBackend: KeychainBackend { public init(service: String = "com.aiwatchtowers.watchtower.e2e") }

public struct DeviceIdentityKeys: Sendable {
    public let signing: Curve25519.Signing.PrivateKey
    public let agreement: Curve25519.KeyAgreement.PrivateKey
    public var deviceID: UUID { KeyDerivation.deviceID(signingPublicKey: signing.publicKey) }
}
public struct EpochKeys: Codable, Equatable, Sendable { public let epoch: UInt32; public let dataKey: Data; public let alertKey: Data }
public struct HubLinkKeys: Codable, Equatable, Sendable {
    public let hubID: String
    public let hubSigningKey: Data          // 32 bytes public
    public let hubAgreementKey: Data        // 32 bytes public
    public let linkNonce: Data
    public var metaKey: Data?               // nil until the keybox arrived
    public var epochs: [EpochKeys]          // newest last, at most 2 kept
}

public protocol PhoneKeyStore: Sendable {
    func identity() throws -> DeviceIdentityKeys                 // created on first use, whenUnlocked
    func hubLink(_ hubID: String) throws -> HubLinkKeys?         // whenUnlocked
    func saveHubLink(_ keys: HubLinkKeys) throws                 // also refreshes the two afterFirstUnlock copies below
    func removeHubLink(_ hubID: String) throws
    /// afterFirstUnlock copy of the hub's public signing key: the replica verifies signatures while locked.
    func hubSigningKey(_ hubID: String) throws -> Curve25519.Signing.PublicKey?
    /// afterFirstUnlock, shared access group: only K_alert epochs + the hub signing key, for the extension (Task 18).
    func alertKeys(_ hubID: String) throws -> [EpochKeys]
}

public struct HubIdentityKeys: Sendable {
    public let signing: Curve25519.Signing.PrivateKey
    public let agreement: Curve25519.KeyAgreement.PrivateKey
    public let wrapKey: SymmetricKey                              // D3
}
public protocol HubKeyStore: Sendable {
    /// Loads the hub's identity; creates all three items when none exists. `created` is true when it did:
    /// the hub then treats the install as a new pairing (Task 10).
    func hubIdentity(hubID: String) throws -> (keys: HubIdentityKeys, created: Bool)
    func deleteHubIdentity(hubID: String) throws
}

public final class KeychainPhoneKeyStore: PhoneKeyStore { public init(backend: any KeychainBackend, alertGroup: String?) }
public final class KeychainHubKeyStore: HubKeyStore { public init(backend: any KeychainBackend) }   // afterFirstUnlock (D2)
public final class InMemoryPhoneKeyStore: PhoneKeyStore { public init(); public var isLocked: Bool }  // tests + demo
public final class InMemoryHubKeyStore: HubKeyStore { public init() }

/// Monotonic u64 counter with block reservation: persists `ceiling = next + blockSize` before handing out
/// a value of a new block, so a crash skips ahead and never reuses a seq.
public final class SeqAllocator: Sendable {
    public init(blockSize: UInt64 = 1_024, load: @escaping @Sendable () throws -> UInt64,
                store: @escaping @Sendable (UInt64) throws -> Void)
    public func next() throws -> UInt64
}
```

- [ ] **Step 1: Failing tests.** `KeyStoreTests` over `FakeKeychainBackend` (records each write's `access`, `group`, `dataProtection`):
  - `testPhoneIdentityIsCreatedOnceAndStoredWhenUnlockedThisDeviceOnly` — two `identity()` calls give the same `deviceID`; the backend saw exactly one write per key with `.whenUnlocked`, `group == nil`.
  - `testSaveHubLinkWritesTheSecretItemWhenUnlockedAndOnlyPublicOrAlertMaterialAfterFirstUnlock` — the `afterFirstUnlock` writes contain no `dataKey` and no `metaKey` bytes (search the written blobs for them).
  - `testALockedKeychainSurfacesLockedNotMissing` — backend throws `.locked` → `hubLink` throws `.locked` (never returns nil: absent vs unavailable are different states, review rules).
  - `testACorruptItemIsCorruptNotAbsent`.
  - `testHubIdentityIsCreatedAfterFirstUnlockWithDataProtectionAndReportsCreatedOnce`.
  - `testAtMostTwoEpochsAreKept`.
  - `SeqAllocatorTests`: `testValuesAreStrictlyIncreasingAcrossARestart` (a new allocator over the same stored ceiling starts at the ceiling), `testTheCeilingIsPersistedBeforeAValueOfTheBlockIsReturned` (a throwing `store` → `next()` throws and returns nothing), `testConcurrentCallersNeverGetTheSameValue` (200 tasks).

- [ ] **Step 2: Run to fail.** `make kit-test FILTER='KeyStoreTests|SeqAllocatorTests' > /tmp/e2e5a.log 2>&1; echo "exit=$?"`.

- [ ] **Step 3: Implement.** Items: accounts `identity.sig`, `identity.kx` (raw 32-byte representations), `hub.<hub_id>` (`HubLinkKeys` JSON), `hubpub.<hub_id>` (32 bytes, `afterFirstUnlock`), `alert.<hub_id>` (`[EpochKeys]` with `dataKey` emptied, plus the hub signing key, `afterFirstUnlock`, `group: alertGroup`), `hubid.<hub_id>.sig|.kx|.wrap` (Mac). A write is delete-then-add (`SecItemAdd` after `SecItemDelete`) so the accessibility class is always the one asked for. `SecItemKeychainBackend` never sets `kSecAttrSynchronizable`. `InMemoryPhoneKeyStore.isLocked` makes every `whenUnlocked` read throw `.locked` (tests of Review Focus 1). No fallback to `UserDefaults` for any key.

- [ ] **Step 4: Run to pass.** Step 2 command → `exit=0`; `make lint-diff`.

- [ ] **Step 5: Commit.** `feat(mobile-e2e): Keychain key stores (ThisDeviceOnly, never synchronizable) and seq allocator`.

Self-review: the checklist above.

---

## Task 6: Go — independent cross-check of the frozen vectors

**Depends on:** Tasks 1, 2, 3 (their fixture files). **Lane:** Go; runs beside anything.

**Files:**
- Create `internal/mobilee2e/doc.go` — package doc: "Reference checks of the mobile E2E wire format (docs/superpowers/plans/2026-10-12-mobile-e2e-encryption.md). Test-only; no production code."
- Create `internal/mobilee2e/vectors_test.go`.
- Modify `go.mod`/`go.sum` via `go mod tidy` (`golang.org/x/crypto` becomes a direct requirement; no new module).

**Interfaces:** consumes `WatchtowerKit/Tests/Fixtures/e2e/{kdf,asset,envelope}.json`; produces nothing for Swift.

- [ ] **Step 1: Write the test** (it fails until it matches the fixtures, which is the point):
  - `TestKDFVectorsMatchAGoDerivation`: X25519 via `crypto/ecdh.X25519()`, HKDF via `crypto/hkdf` (Go 1.24+: `hkdf.Key(sha256.New, secret, salt, info, 32)`), HMAC-SHA256, base32 via `base32.StdEncoding.WithPadding(base32.NoPadding)` lowercased, device id and SAS from the Task 1 definitions. Every value equals the fixture's hex.
  - `TestEnvelopeVectorsOpenInGo`: parse the 68-byte header with `encoding/binary.BigEndian`, rebuild the AAD (`header ‖ zone ‖ u16 len ‖ name`), verify the stored signature with `crypto/ed25519.Verify` over `"wt/sig/v1" ‖ aad ‖ body`, open with `chacha20poly1305.New(key)` and parse the inner frame; compare kind, id, notify level, asset descriptor and payload with the fixture.
  - `TestAssetVectorsDecryptInGo`: chunk loop with nonce `0x00000000 ‖ u64 c`, AAD `header ‖ c ‖ last`, digest check.
  - Fixture path: `filepath.Join("..", "..", "WatchtowerKit", "Tests", "Fixtures", "e2e", name)`.
- [ ] **Step 2: Run.** `go test ./internal/mobilee2e > /tmp/e2e6.log 2>&1; echo "exit=$?"` → `exit=0`. A mismatch is a bug in the Swift implementation or in this transcription of the spec: fix the Swift side and regenerate its fixture only with the owner's approval if the Swift side is wrong, never "fix" the Go test toward the fixture. `make lint-diff`.
- [ ] **Step 3: Commit.** `test(mobile-e2e): Go cross-check of the frozen E2E vectors`.

Self-review: the checklist above (plus review-rules §7: no subprocess, no network).

---

## Task 7: Kit — `SecureTransport` and the CloudKit wire mapping

**Depends on:** Tasks 3, 4, 5. **Lane:** Kit.

**Files:**
- Create `WatchtowerKit/Sources/WatchtowerSync/Secure/SecureKeyProvider.swift`, `Secure/SecureTransport.swift`, `Secure/RollbackGuard.swift`, `Secure/PhoneKeyProvider.swift` (the phone's `SecureKeyProvider` over `PhoneKeyStore`).
- Modify `WatchtowerKit/Sources/WatchtowerSync/Sync/CloudSyncTransport.swift` (`CloudRecord.asset`, `CloudRecord.sealed`, `WireKind`).
- Modify `WatchtowerKit/Sources/WatchtowerSync/CloudKitTransport/CloudKitTransport.swift` (`recordType = "WatchtowerEnvelope"`, `signalRecordType = "WatchtowerSignal"`, the legacy type ignored on fetch).
- Test: `WatchtowerKit/Tests/WatchtowerSyncTests/SecureTransportTests.swift`; modify `CloudKitTransportMappingTests.swift`; create `Support/TestE2E.swift` (a test hub and a test phone over in-memory key stores, shared by Tasks 8–9 and the phone suite's support copy).

**Interfaces (produces):**

```swift
public enum WireKind { public static let envelope = "wt"; public static let signal = "sig" }

// CloudRecord gains (defaults nil; Equatable):
public let asset: AssetDescriptor?   // save: the descriptor of a ciphertext `assetFileURL`; open: from the inner frame
public let sealed: SealedInfo?       // set on records SecureTransport opened
public struct SealedInfo: Equatable, Sendable {
    public let wireName: String
    public let senderID: UUID
    public let epoch: UInt32
    public let seq: UInt64
    public let envelopeClass: EnvelopeClass
}

public enum SecureRole: Equatable, Sendable { case hub(hubID: UUID), phone(hubID: UUID, deviceID: UUID) }

public protocol SecureKeyProvider: Sendable {
    var role: SecureRole { get }
    func metaKey() throws -> SymmetricKey
    func currentEpoch() throws -> UInt32
    func dataKey(epoch: UInt32) throws -> SymmetricKey
    func alertKey(epoch: UInt32) throws -> SymmetricKey
    func relayKey(_ direction: RelayDirection, deviceID: UUID, epoch: UInt32) throws -> SymmetricKey
    /// Accepted relay epochs for a sender: the current one, and the previous one for 7 days (D10).
    func acceptsRelayEpoch(_ epoch: UInt32, deviceID: UUID) throws -> Bool
    func nextSeq() throws -> UInt64
    // hub only (a phone provider throws SecureTransportError.wrongRole):
    func hubSigner() throws -> Curve25519.Signing.PrivateKey
    func hubAgreement() throws -> Curve25519.KeyAgreement.PrivateKey
    func keyboxRecipient(deviceID: UUID) throws -> Curve25519.KeyAgreement.PublicKey?
    // phone only:
    func deviceSigner() throws -> Curve25519.Signing.PrivateKey
    func hubAgreementPublicKey() throws -> Curve25519.KeyAgreement.PublicKey
    func linkNonce() throws -> Data
}

public protocol RollbackGuard: Sendable {
    /// .newer: store and use; .same: an identical re-delivery (idempotent); .older: ignore (rollback).
    func check(wireName: String, epoch: UInt32, seq: UInt64) throws -> RollbackVerdict
    func record(wireName: String, epoch: UInt32, seq: UInt64) throws
}
public enum RollbackVerdict: Equatable, Sendable { case newer, same, older }
public final class InMemoryRollbackGuard: RollbackGuard { public init() }

public enum SecureTransportError: Error, Equatable {
    case wrongRole, keysUnavailable, unknownKind(String), noKeyboxRecipient(String)
}

/// Seals what its role sends; opens what its role receives in RelayZone; DataZone reads pass through (the
/// replica opens on read). Record naming: `heartbeat` stays `heartbeat`; `device_grant-<id>` → `keybox-<id>`;
/// `hello-<id>` stays; signals keep their name; everything else → KeyDerivation.recordName(K_meta, zone, kind, id).
public actor SecureTransport: CloudSyncTransport {
    public init(inner: any CloudSyncTransport & Sendable, keys: any SecureKeyProvider, rollback: any RollbackGuard,
                onRejected: (@Sendable (_ wireName: String, _ reason: String) -> Void)? = nil)
    public nonisolated func wireName(for record: CloudRecord) throws -> String
    public nonisolated func wireName(plain: String, zone: CloudZoneID) throws -> String
    /// The plain name of a record this transport sealed in this process (the rejected-record callback, Task 11).
    public func plainName(forWire wireName: String) -> String?
    /// Plain → sealed wire record (kind "wt", payload = envelope, asset descriptor inside the frame).
    public func seal(_ record: CloudRecord) throws -> CloudRecord
    /// Sends already-sealed wire records unchanged (stored envelopes: outbox rows, uploads; Review Focus 2).
    public func saveSealed(_ records: [CloudRecord]) async throws
    public func save(_ records: [CloudRecord]) async throws            // seal + saveSealed
    public func delete(recordNames: [String], in zone: CloudZoneID) async throws   // plain names → wire names
    public func changes(in zone: CloudZoneID, since token: CloudChangeToken?) async throws -> CloudChangeBatch
    public func compact(in zone: CloudZoneID, keepSince token: CloudChangeToken) async throws   // forwards (throws if inner can't)
    public func sweepEvents(in zone: CloudZoneID, olderThan cutoff: Date, upTo token: CloudChangeToken) async throws -> Int
}
```

Sealing rules (by role, plain kind → class): hub — `heartbeat` and every `SliceKind` → `.data` signed; `ask_alert` → `.alert` signed (Task 11); `device_grant` → `.keybox` (HPKE to `keyboxRecipient`, signed); relay echoes (`action`, `recording_upload`, `device`) → `.relayToPhone` under the sender's h2p key (the device id is the payload's `device_id`). Phone — `hello` → `.hello` (HPKE to the hub's agreement key, signed by the device); `action`, `recording_upload`, `device` → `.relayToHub`. Opening rules for `changes(.relay)`: hub opens `.hello` (Task 13 consumes it) and `.relayToHub` from a sender with a relay key and an accepted epoch; phone opens `.relayToPhone` addressed by the frame to itself and its own `.relayToHub` records; everything else in RelayZone is dropped and reported through `onRejected` (another phone's records in a shared zone are expected: reported once per wire name at debug level). The rollback guard runs on every opened relay record. Keys unavailable (`KeyStoreError.locked`) → `changes` throws `SecureTransportError.keysUnavailable`, so the consumer keeps its token and replays (Review Focus 1).

- [ ] **Step 1: Failing tests** (`SecureTransportTests`, over `InMemoryCloudTransport` and `TestE2E.hub()`/`TestE2E.phone()`, which share one pairing):
  - `testHubSealsDataRecordsUnderOpaqueNamesWithAConstantWireKind` — after `hub.save([slice])` the inner transport holds a record whose name is 26 base32 chars, `kind == "wt"`, payload parses as an `Envelope` of class `.data`, `modifiedAt` unchanged (spec §5: kept plaintext).
  - `testHeartbeatKeyboxAndHelloKeepKeyFreeNames`.
  - `testDataZoneReadsPassThroughUntouched`.
  - `testPhoneActionRoundTripsToTheHubAndTheEchoBack` — phone `save(action)`; hub `changes(.relay)` returns the plain `action-<id>` record, kind `action`, plaintext payload, `sealed.senderID == deviceID`; hub saves the echo; phone `changes(.relay)` returns it opened.
  - `testAnUnknownSendersRelayRecordIsDroppedAndReported` — a record sealed by a phone the hub has no key for is not in `changed`, `onRejected` fired once.
  - `testARolledBackRelayRecordIsIgnoredAndAnIdenticalRedeliveryPasses` — save v1 (seq 5), save v2 (seq 6) of the same record, then the inner transport re-presents v1: the hub ignores it; the same v2 bytes again are returned (`.same`).
  - `testLockedKeysMakeChangesThrowSoTheTokenIsKept`.
  - `testDeleteMapsPlainNamesToWireNames`.
  - `testSaveSealedSendsStoredBytesUnchanged` — `seal` then `saveSealed` twice: the inner transport holds byte-identical payloads.
  - `testThePreviousEpochIsAcceptedOnlyWhileTheProviderSaysSo` (D10).
  - `testARelayRecordWhosePayloadDeviceIDIsNotItsSenderIsStillReturnedWithTheAuthenticatedSender` — the processor (Task 12) decides; the transport must not hide the mismatch.
  - `CloudKitTransportMappingTests`: `testEnvelopeRecordsUseTheWatchtowerEnvelopeType`, `testSignalRecordsUseTheWatchtowerSignalTypeAndCarryNoPayload`, `testARecordOfThePreE2ETypeIsIgnoredOnFetch` (`cloudRecord(from:)` returns nil for `WatchtowerRecord`), `testPayloadStaysAnEncryptedValueAndModifiedAtAPlainField`.
  - `testConflictReSaveKeepsTheSealedPayload` (Review Focus 2): in `CloudKitTransportErrorTests`' style, a `serverRecordChanged` failure on a pending envelope record re-saves the pending row's payload byte for byte (the conflict path is content-agnostic; this pins it).

- [ ] **Step 2: Run to fail.** `make kit-test FILTER='SecureTransportTests|CloudKitTransportMappingTests|CloudKitTransportErrorTests' > /tmp/e2e7a.log 2>&1; echo "exit=$?"`.

- [ ] **Step 3: Implement.** `ckRecord(from:)`: `recordType` = `signalRecordType` when `record.kind == WireKind.signal`, else `"WatchtowerEnvelope"`; a signal sets no `payload`. `cloudRecord(from:)`: accept only the two new types (a signal's payload is `Data()`); the old type `WatchtowerRecord` returns nil and is logged once per record type. The phone's `PhoneKeyProvider(store: any PhoneKeyStore, hubID: String, seq: SeqAllocator)` derives relay keys on demand from `identity().agreement`, the stored hub agreement key, link nonce and epoch, and caches them in memory.

- [ ] **Step 4: Run to pass.** Step 2 command → `exit=0`. Then the whole Kit transport suites, because `CloudRecord` gained fields: `make kit-test FILTER='CloudKitTransport|TransportStore|TransportAsset|InMemoryCloudTransport|CloudRecordFactory' > /tmp/e2e7b.log 2>&1; echo "exit=$?"`. `make lint-diff`.

- [ ] **Step 5: Commit.** `feat(mobile-e2e): SecureTransport above the transport seam; WatchtowerEnvelope and WatchtowerSignal record types`.

Self-review: the checklist above.

---

## Task 8: Kit — ciphertext replica, apply-time verify and rollback guard, decrypt on read

**Depends on:** Task 7. **Lane:** Kit.

**Files:**
- Modify `WatchtowerKit/Sources/WatchtowerSync/Replica/ReplicaStore.swift`, `ReplicaStore+SliceAssets.swift`, `ReplicaHydrator.swift`.
- Create `WatchtowerKit/Sources/WatchtowerSync/Replica/ReplicaOpener.swift`.
- Test: create `WatchtowerKit/Tests/WatchtowerSyncTests/ReplicaEnvelopeTests.swift`; rewrite the record builders of `ReplicaTests`, `ReplicaResetTests`, `ReplicaSliceAssetTests` to seal through `TestE2E.hub()` (deliberate: the replica no longer accepts plaintext).

**Interfaces (produces):**

```swift
public protocol ReplicaOpening: Sendable {
    /// Apply time, no secret key: parse, check hub id and class, verify the hub signature (public key).
    func verify(wireName: String, envelope: Data) throws -> EnvelopeHeader
    /// Read time: open and return the inner frame. A keybox opens to its `Keybox`, and the frame's payload is
    /// the `grant` JSON, so `device_grant` readers stay unchanged.
    func open(wireName: String, envelope: Data) throws -> InnerFrame
    /// The kind and plain record name of a fixed-name record, without opening it (`heartbeat`, `keybox-<id>`).
    func fixedName(_ wireName: String) -> (kind: String, plainName: String)?
    /// The phone's own `.relayToHub` envelopes (the `pending_actions` overlay, Task 9), under its p2h key.
    func openOwnRelay(wireName: String, envelope: Data) throws -> InnerFrame
}
public final class EnvelopeReplicaOpener: ReplicaOpening {
    public init(hubID: String, keys: any PhoneKeyStore)
}

// ReplicaStore
public init(path: String, opener: any ReplicaOpening) throws
public static func inMemory(opener: any ReplicaOpening) throws -> ReplicaStore
/// Verifies and stores each data-zone envelope; rows whose kind is unknown until opened are stored unindexed.
@discardableResult public func apply(_ batch: CloudChangeBatch) throws -> Bool
/// Opens every unindexed row it can and fills `kind`/`plain_name`; returns the indexed records (for
/// `onRecordsApplied`). Rows that stay unopenable for `.locked` stay unindexed; others are counted corrupt.
@discardableResult public func indexPending() throws -> [IndexedRecord]
public struct IndexedRecord: Equatable, Sendable { public let kind: String; public let plainName: String; public let modifiedAt: Date }
public static let maxAssetBytes: Int     // = ChunkedAssetCipher.sealedLength(forPlaintext: 20 MiB)
public func rejectedCount() -> Int       // signature failures, wrong hub, rollbacks ignored
public func newerFormatCount() -> Int    // unsupportedVersion/unsupportedSuite: "Update Watchtower on this iPhone"
/// The phone's relay rollback guard (Task 7's protocol), persisted in a `relay_seen(wire_name PK, epoch, seq)`
/// table of the replica; rows older than 8 days are pruned with `sweepSilentPending`.
extension ReplicaStore: RollbackGuard
```

Schema (replica format 2; `replica_meta.replica_format`): `slice_records(record_name TEXT PRIMARY KEY /* wire name */, plain_name TEXT, kind TEXT /* NULL until indexed */, epoch INTEGER NOT NULL, seq INTEGER NOT NULL, payload BLOB NOT NULL /* envelope */, modified_at REAL NOT NULL)`, indexes on `kind` and `plain_name`; `slice_assets.data` holds the sealed asset bytes. A store whose format is not 2 drops `slice_records`, `slice_assets` and the data/relay tokens on open (hard cut; `pending_actions`, `phone_recordings` and their marks are kept and handled by Task 9). Every read that used `record_name` as a plain name (`payload(forRecordName:)`, `heartbeatAge`, `sliceAsset(forRecordName:)`) now queries `plain_name`; `payloads(of:)` and `fetchAll` query `kind`, open each payload and return `frame.payload` (an unopenable row is skipped and counted like an undecodable one today). `sliceAsset(forRecordName:)` decrypts with the descriptor from the record's frame.

- [ ] **Step 1: Failing tests** (`ReplicaEnvelopeTests`, with `TestE2E` and `InMemoryPhoneKeyStore`):
  - `testApplyWhileLockedStoresCiphertextAndIndexesAfterUnlock` (Review Focus 1): keys locked → `apply` returns true, the token advances, `payloads(of: .ownerAsk)` is empty; unlock → `indexPending()` returns the record; `payloads(of: .ownerAsk)` returns the plaintext; the stored `payload` column is the envelope (the plaintext title is not in the database file: read it with `Data(contentsOf:)` and search).
  - `testASignatureByAnotherKeyIsRejectedAtApplyAndNeverStored`.
  - `testAnOlderVersionOfARecordIsIgnoredAndTheNewerKept` — apply seq 10, then a batch with seq 9 of the same wire name → payload stays seq 10's; `rejectedCount() == 1`.
  - `testAnEnvelopeOfAnotherHubIsRejected`.
  - `testDeletionsRemoveByWireName`.
  - `testHeartbeatAndKeyboxAreIndexedByNameWithoutOpening`.
  - `testANewerFormatIsKeptUnindexedAndCounted`.
  - `testRowsOfThePreviousEpochStayReadableUntilRepublished`.
  - `testAnAssetIsStoredSealedAndDecryptedOnRead` and `testAnAssetOverTheSealedCapIsRefusedUnread`.
  - `testAFormatOneStoreIsWipedOnOpenButKeepsTheRecordingLedger`.
  - `ReplicaHydrator`: `testOnRecordsAppliedReportsIndexedRecordsAndLockedOnesAfterUnlock`.

- [ ] **Step 2: Run to fail.** `make kit-test FILTER='ReplicaEnvelopeTests|ReplicaTests|ReplicaResetTests|ReplicaSliceAssetTests' > /tmp/e2e8a.log 2>&1; echo "exit=$?"`.

- [ ] **Step 3: Implement.** `apply`: for each changed data record, `opener.verify` (throwing records are skipped and counted, never stored), then the rollback check against the stored `(epoch, seq)` of that wire name (older → skip and count; same → no-op), upsert with `plain_name`/`kind` from `fixedName` or NULL; asset files are read before the write transaction (unchanged). `ReplicaHydrator.hydrateOnce()` calls `indexPending()` after `apply` and reports its records; `AppEnvironment` (Task 17) also calls it on unlock.

- [ ] **Step 4: Run to pass.** Step 2 command → `exit=0`; `make kit-test FILTER=ReplicaHydrator > /tmp/e2e8b.log 2>&1; echo "exit=$?"`. `make lint-diff`.

- [ ] **Step 5: Commit.** `feat(mobile-e2e): the phone replica keeps ciphertext, verifies at apply, decrypts on read` (message lists the rewritten replica test builders).

Self-review: the checklist above.

---

## Task 9: Kit — outbox, relay feed and uploader under E2E

**Depends on:** Tasks 7, 8. **Lane:** Kit.

**Files:**
- Modify `WatchtowerKit/Sources/WatchtowerSync/Relay/ActionOutbox.swift`, `Replica/ReplicaStore+PendingActions.swift` (`wire_name`, sealed `payload`), `Relay/RelayFeed.swift`, `Relay/RecordingUploader.swift`, `Replica/ReplicaStore+PhoneRecordings.swift` (`envelope`, `sealed_path` columns).
- Test: modify `ActionOutboxTests`, `RelayFeedTests`, `RelayFeedRecordingUploadTests`, `RecordingUploaderTests` (seal through `TestE2E`); add the tests below.

**Interfaces (produces):**

```swift
// ActionOutbox / RecordingUploader take the secure transport (not the raw one):
public init(transport: SecureTransport, store: ReplicaStore, deviceID: String?)
// pending_actions: + wire_name TEXT; payload = the sealed envelope (the overlay opens it on read through the
// store's opener, which can open the phone's own p2h envelopes)
// phone_recordings: + envelope BLOB (the sealed upload record, kept for every re-send), + sealed_path TEXT (.enc)
public func sealPending() async throws -> Int   // RecordingUploader: seals `waiting` rows without an envelope; locked → 0, retried later
```

- [ ] **Step 1: Failing tests.**
  - `ActionOutboxTests.testEnqueueSealsOnceAndTheOverlayReadsTheSealedRow` — the `pending_actions.payload` is an `Envelope` (class `.relayToHub`), `pendingActions()` still returns the decoded action.
  - `RelayFeedTests.testEchoesThatCannotBeOpenedWhileLockedAreReplayedAfterUnlock` (Review Focus 1) — locked: `pollOnce` throws/keeps the token, no echo applied; unlocked: the same batch applies.
  - `RelayFeedTests.testARolledBackEchoIsIgnored` (`received` after `applied` re-presented with an older seq).
  - `RecordingUploaderTests.testSealPendingEncryptsTheFileDeletesThePlainAudioAndStoresTheEnvelope` — after `finishCapture` + `sealPending()`: `.m4a` gone, `.enc` exists, decrypts (with the descriptor from the opened envelope) to the original bytes.
  - `testSealPendingWhileLockedKeepsThePlainFileAndSealsAfterUnlock`.
  - `testRelaunchRetryResendsTheStoredEnvelopeByteForByte` (Review Focus 2) — first pass saves; a new uploader over the same store (relaunch) re-saves `uploading` rows: the inner transport saw two identical payloads and identical asset files.
  - `testRetryAfterAFailedEchoReusesTheEnvelope`.
  - `testTheNinetyMBCapIsCheckedOnThePlainSizeBeforeSealing`.
  - `testReceivedDeletesTheSealedFile`.

- [ ] **Step 2: Run to fail.** `make kit-test FILTER='ActionOutboxTests|RelayFeed|RecordingUploaderTests' > /tmp/e2e9a.log 2>&1; echo "exit=$?"`.

- [ ] **Step 3: Implement.** `ActionOutbox.enqueue`: `let wire = try await transport.seal(record)`; `try await transport.saveSealed([wire])`; then insert the overlay row with `wire_name` and the sealed payload (order unchanged: save first, no phantom chip). `RecordingUploader.sealPending()`: for each `waiting` row without `envelope`, `ChunkedAssetCipher.encryptFile` into `<id>.enc` (then `FileProtectionType` is the phone's job, Task 17), build the upload record with `asset: descriptor`, `transport.seal`, store `envelope` + `sealed_path` in one row update, then delete the `.m4a`; `send` uses `saveSealed` with the stored envelope and `assetFileURL = sealed_path`; `uploadPending()` calls `sealPending()` first. `RelayFeed` reads through `SecureTransport.changes(.relay)` and lets `keysUnavailable` propagate (token kept).

- [ ] **Step 4: Run to pass.** Step 2 command → `exit=0`; `make lint-diff`.

- [ ] **Step 5: Commit.** `feat(mobile-e2e): outbox seals at enqueue, uploader seals at finalize and re-sends the stored envelope`.

Self-review: the checklist above.

---

## Task 10: Mac — hub keyring, epochs and the sidecar key tables

**Depends on:** Tasks 4, 5, 7 (`SecureKeyProvider`, `RollbackGuard`). **Lane:** Desktop (heavy Swift: one Desktop or phone task at a time; Kit tasks may run beside it).

**Files:**
- Create `WatchtowerDesktop/Sources/Services/MobileHub/HubKeyring.swift`.
- Create `WatchtowerDesktop/Sources/Services/MobileHub/HubSyncState+Keys.swift`.
- Modify `WatchtowerDesktop/Sources/Services/MobileHub/HubSyncState.swift` (schema: new tables and `devices` columns, called from `createSchema`), `MobileHubService.swift` (`MobileHubStorage.live()` builds `KeychainHubKeyStore(backend: SecItemKeychainBackend())` and the `HubKeyring`; a stub storage gets `InMemoryHubKeyStore`).
- Test: create `WatchtowerDesktop/Tests/MobileHub/HubKeyringTests.swift`.

**Interfaces (produces):**

```swift
// hubstate.db
//   hub_epochs(epoch INTEGER PRIMARY KEY, sealed_keys BLOB NOT NULL /* ChaChaPoly(wrap, K_data‖K_alert) */,
//              created_at REAL NOT NULL, first_seq INTEGER NOT NULL, retired_at REAL)
//   hub_meta keys: "k_meta_sealed", "envelope_seq_ceiling", "e2e_v1" (Task 15)
//   devices + columns: signing_key BLOB, agreement_key BLOB, link_nonce TEXT, last_seq INTEGER
//   pending_devices(device_id TEXT PRIMARY KEY, name, model, scope, user_record_name, signing_key BLOB,
//                   agreement_key BLOB, link_nonce TEXT, sas TEXT, received_at REAL)          (Task 13)
//   revoked_devices(device_id TEXT PRIMARY KEY, agreement_key BLOB NOT NULL, removed_at REAL NOT NULL)  (Task 14)
//   relay_seen(wire_name TEXT PRIMARY KEY, epoch INTEGER NOT NULL, seq INTEGER NOT NULL, at REAL NOT NULL)
final class HubKeyring: SecureKeyProvider, RollbackGuard, @unchecked Sendable {
    init(hubID: String, sidecar: HubSyncState, store: any HubKeyStore, now: @escaping @Sendable () -> Date = Date.init) throws
    /// true when the Keychain identity was created now while the sidecar already had linked phones or epochs:
    /// the old pairing is unusable, so the hub must delete its zones and forget phones (Task 15 acts on it).
    var identityWasRecreated: Bool { get }
    var signingPublicKey: Curve25519.Signing.PublicKey { get }
    var agreementPublicKey: Curve25519.KeyAgreement.PublicKey { get }
    /// Creates K_meta and epoch 1 when none exists (idempotent).
    func ensureGroupKeys() throws
    func epochKeys(_ epoch: UInt32) throws -> EpochKeys
    /// Due when the current epoch is 90 days old or has used 2^28 seqs (spec §2.2).
    func rotationDue() throws -> Bool
    /// Clears K_meta and every epoch (hub turned off / zones deleted): the next pairing starts fresh.
    func resetGroupKeys() throws
}
```

- [ ] **Step 1: Failing tests** (`HubKeyringTests`, `InMemoryHubKeyStore`, in-memory sidecar):
  - `testGroupKeysAreCreatedOnceAndSurviveANewKeyring` — a second `HubKeyring` over the same sidecar returns the same `metaKey` and epoch 1 keys.
  - `testEpochKeysAreSealedAtRest` — `hub_epochs.sealed_keys` and `k_meta_sealed` do not contain the raw key bytes.
  - `testSeqIsMonotonicAcrossRestartsAndPersistedInHubMeta`.
  - `testRelayKeysAgreeWithThePhonesDerivation` — the phone side derived with `KeyDerivation.relayKey(dev, hub.agreementPublicKey, …)` equals `relayKey(.phoneToHub, …)`.
  - `testThePreviousEpochIsAcceptedForSevenDaysThenRefused`.
  - `testRotationIsDueAtNinetyDaysOrTheSeqCap`.
  - `testARecreatedIdentityWithLinkedPhonesIsReported`.
  - `testRollbackGuardKeepsTheHighestSeqPerWireNameAndPrunesWithTheLedger` (`relay_seen` rows go when `pruneRelayProcessed` prunes their record).
  - `testResetGroupKeysForgetsEveryEpochAndKMeta`.

- [ ] **Step 2: Run to fail.** `make test-swift FILTER=HubKeyringTests > /tmp/e2e10a.log 2>&1; echo "exit=$?"`.

- [ ] **Step 3: Implement.** Columns are added with the existing `ALTER TABLE … ADD COLUMN` pattern inside `createSchema`'s immediate transaction. `SeqAllocator` over `hub_meta.envelope_seq_ceiling`. Relay keys are derived from `agreement` + the device row's `agreement_key`/`link_nonce` and cached per `(device, epoch, direction)`; a removed device's cache entries are dropped by Task 14. `keyboxRecipient(deviceID:)` returns a linked, pending (Task 13) or revoked (Task 14) device's agreement key.

- [ ] **Step 4: Run to pass.** Step 2 command → `exit=0`; plus `make test-swift FILTER='MobileHubServiceTests|MobileLinkCenterTests' > /tmp/e2e10b.log 2>&1; echo "exit=$?"` (schema change). `make lint-diff`.

- [ ] **Step 5: Commit.** `feat(mobile-e2e): hub identity in the Keychain, sealed epoch keys in hubstate.db`.

Self-review: the checklist above.

---

## Task 11: Mac — the publisher seals; staged assets are ciphertext; ask alerts and the signal record

**Depends on:** Tasks 7, 10. **Lane:** Desktop.

**Files:**
- Modify `WatchtowerDesktop/Sources/Services/MobileHub/SlicePublisher.swift` (sealed-size guard, asset descriptor on the record), `SliceAssetStore.swift` (stage ciphertext + a `.desc` descriptor file; `stagedDigest` reads the descriptor's plaintext digest), `HubIdentity.swift` (heartbeat through the secure transport), `Slices/AskAlertSlice.swift` (title clipped as today; the record is sealed under `K_alert`), `Slices/DeviceGrantSlice.swift` (publishes `Keybox` plaintext; Task 13/14 fill keys and revocations), `MobileHubService.swift` (the hub's record I/O goes through `SecureTransport`; lifecycle calls stay on `HubTransport`; the rejected-record handler maps wire → plain via `plainName(forWire:)`), `WatchtowerDesktop/Sources/App/AppState+MobileHub.swift` (wiring).
- Create `WatchtowerDesktop/Sources/Services/MobileHub/AskAlertSignal.swift` (writes `sig-<wire name of the alert>` records of kind `WireKind.signal` when an alert is published, deletes them with the alert).
- Test: modify `SlicePublisherTests`, `MeetingTranscriptSliceTests`, `AskAlertSliceTests`, `HubHeartbeatTests`, `MobileHubServiceTests` (records read back through `TestE2E` on the Desktop side: `WatchtowerDesktop/Tests/MobileHub/MobileHubTestSupport.swift` gains `openedRecords(in:)`).

**Interfaces (produces):**

```swift
// SliceAssetStore
func stage(_ data: Data, fileName: String, recordName: String) throws -> (url: URL, descriptor: AssetDescriptor)
func stagedDescriptor(recordName: String, fileName: String) -> AssetDescriptor?   // from <recordName>/<fileName>.desc
func stagedDigest(recordName: String, fileName: String) -> Data?                  // = stagedDescriptor?.plaintextDigest
// SlicePublisher
static func isOversized(_ record: SliceRecord, signed: Bool) -> Bool   // EnvelopeSealer.sealedLength(frameLength:) == nil
// AskAlertSignal
static func signalName(forAlertWireName: String) -> String              // "sig-" + wire name
```

- [ ] **Step 1: Failing tests.**
  - `SlicePublisherTests.testEveryPublishedRecordIsASignedEnvelopeUnderAnOpaqueName`.
  - `SlicePublisherTests.testARecordThatFitsOnlyUnpaddedStillPublishesAndOneThatDoesNotIsSkipped` (Review Focus 3): payload sized to `frameCap(signed: true) − frameOverhead` publishes (envelope exactly ≤ 900 000); one byte more is skipped, unhashed, warned once.
  - `SlicePublisherTests.testAnUnchangedTickSendsNothingDespiteRandomNonces` (the hash is of the plaintext; `SliceDiff` unchanged).
  - `SlicePublisherTests.testARejectedRecordClearsThePlainNamesHash` (the handler receives the wire name).
  - `MeetingTranscriptSliceTests.testSegmentsAreStagedSealedAndTheDigestIndexIsOfThePlaintext` — the staged file is not the JSON; `stagedDigest == SHA256(json)`; a second tick reuses the staged file without restaging; a missing `.desc` restages.
  - `HubHeartbeatTests.testTheHeartbeatIsASignedEnvelopeNamedHeartbeat`.
  - `AskAlertSliceTests.testAnAlertIsSealedUnderTheAlertKeyAndHasASignal` — the alert opens with `K_alert` and not with `K_data`; a `sig-…` record of type signal exists with an empty payload; deleting the alert deletes the signal.
  - `MobileHubServiceTests.testAccountResetAndDisableStillRemoveStagedFilesAndDescriptors`.

- [ ] **Step 2: Run to fail.** `make test-swift FILTER='SlicePublisherTests|MeetingTranscriptSliceTests|AskAlertSliceTests|HubHeartbeatTests|MobileHubServiceTests' > /tmp/e2e11a.log 2>&1; echo "exit=$?"`.

- [ ] **Step 3: Implement.** In `SlicePublisher.stage`, an asset record is saved with `assetFileURL` = the sealed file and `asset` = its descriptor; `splitOversized` uses `isOversized(_:signed:)` on the frame length (kind, id, notify level, descriptor, payload). `SliceAssetStore.stage` encrypts with `ChunkedAssetCipher.encrypt(data)` (≤ 20 MB in memory, as today), writes the sealed file and `<fileName>.desc` (`AssetDescriptor.encoded()`) atomically; the Mac keeps `K_asset` next to the file (it holds the plaintext anyway; FileVault is the at-rest story, spec §2.6).

- [ ] **Step 4: Run to pass.** Step 2 command → `exit=0`; then every slice suite (they build records the publisher seals): `make test-swift FILTER='SliceTests|Slice' > /tmp/e2e11b.log 2>&1; echo "exit=$?"`. `make lint-diff`.

- [ ] **Step 5: Commit.** `feat(mobile-e2e): the hub publishes signed envelopes, stages sealed assets, signals ask alerts`.

Self-review: the checklist above.

---

## Task 12: Mac — relay processor: key-authenticated phones, sealed echoes, sealed uploads

**Depends on:** Tasks 9, 10, 11. **Lane:** Desktop.

**Files:**
- Modify `WatchtowerDesktop/Sources/Services/MobileHub/RelayProcessor.swift` (gate, decrypt-to-ingest), `HubSyncState.swift` (`devices.last_seq` high-water update), `PhoneRecordingJobs.swift` only if the ingest signature needs the plaintext temp URL.
- Test: modify `RelayProcessorTests.swift`, `RelayProcessorRecordingUploadTests.swift`, `MobileHubTestSupport.swift` (`pendingActionRecord` and `uploadPayload` seal through the test phone).

**Behaviour:**
- The processor reads `SecureTransport.changes(.relay)`: only records that opened with a linked device's key reach it (D4, D9). Gate order in `processAction`/`processUpload`: `begun` → `wrong_hub` → **sender check**: `record.sealed?.senderID` must equal the payload's `device_id` and name a linked device (else `failed`/`device_not_linked`, echoed under the sender's key) → **creator check** kept as defense in depth (`LinkedDevice.accepts(creator:)`) → age (`created_at` is now authenticated) → apply. `devices.last_seq = max(last_seq, seq)`.
- Echoes: `transport.save` of the echo record seals it `.relayToPhone` for the payload's device.
- Upload ingest: decrypt the stashed sealed asset with `record.asset` into a temp file in the stash's directory (`ChunkedAssetCipher.decryptFile`), ingest that file, delete it after ingest whatever the outcome, and delete the sealed stash on `received` as today. A decrypt failure is `failed`/`not_found` with the existing "did not reach your Mac" message (nothing written).

- [ ] **Step 1: Failing tests.**
  - `RelayProcessorTests.testAnActionThatOpensWithALinkedPhonesKeyIsApplied` (key-auth twin of the creator tests; the existing creator tests stay).
  - `testAnActionSealedByAnUnlinkedKeyNeverReachesTheProcessor` (not echoed, not ledgered; `onRejected` counted).
  - `testAPayloadNamingAnotherDeviceThanItsSenderFailsDeviceNotLinked`.
  - `testAnActionOfThePreviousEpochIsAppliedDuringTheGrace`.
  - `testTheEchoIsSealedForThePhoneAndOpensOnlyWithItsKey`.
  - `testAnExpiredCreatedAtStillExpiresNowThatItIsAuthenticated`.
  - `testLastSeqIsAHighWaterMarkNotAGate` — seq 9 after seq 12 from the same phone (another record) is applied (D4).
  - `RelayProcessorRecordingUploadTests.testARetriedUploadWithTheSameEnvelopeIsIngestedOnce` (Review Focus 2): the same sealed record twice → one ingest, re-echo `received`.
  - `testTheIngestReceivesThePlainAudioAndNoPlainCopyIsLeft`.
  - `testATamperedSealedAssetFailsNotFoundAndWritesNothing`.

- [ ] **Step 2: Run to fail.** `make test-swift FILTER='RelayProcessorTests|RelayProcessorRecordingUploadTests' > /tmp/e2e12a.log 2>&1; echo "exit=$?"`.

- [ ] **Step 3: Implement** the behaviour above; the handlers (`AskAnswerHandler`, `BoardHandlers`, `SessionStartStopHandlers`) are unchanged (they receive the decoded `ActionRequestPayload`).

- [ ] **Step 4: Run to pass.** Step 2 command, then the handler suites (they drive actions through the relay): `make test-swift FILTER='AskAnswerHandlerTests|BoardHandlersTests|SessionStartHandlerTests' > /tmp/e2e12b.log 2>&1; echo "exit=$?"`. `make lint-diff`.

- [ ] **Step 5: Commit.** `feat(mobile-e2e): relay actions authenticated by pairwise keys; sealed echoes and uploads`.

Self-review: the checklist above.

---

## Task 13: Mac — pairing with hub keys, owner confirmation and SAS

**Depends on:** Tasks 11, 12. **Lane:** Desktop.

**Files:**
- Modify `WatchtowerDesktop/Sources/Services/MobileHub/MobileLinkCenter.swift` (`issueCode` puts the hub keys in the QR; `handleHello`; `pendingLinks`; `confirmLink`/`refuseLink`; `closeLink` refuses pending requests), `RelayProcessor.swift` (route `hello` records to the link center, unbudgeted like `device`), `HubSyncState+Keys.swift` (pending device rows; `confirmPendingDevice` = `linkDevice` + key columns in one transaction), `Slices/DeviceGrantSlice.swift` (keybox payloads: `awaitingConfirmation` for pending, keys for linked, refusals).
- Modify `WatchtowerDesktop/Sources/ViewModels/MobileLinkSheetViewModel.swift`, `WatchtowerDesktop/Sources/Views/Settings/MobileLinkSheet.swift`.
- Test: modify `MobileLinkCenterTests.swift`, `MobileLinkSheetViewModelTests.swift`, `MobileSettingsViewTests.swift`.

**Interfaces (produces):**

```swift
// MobileLinkCenter (@MainActor, @Observable)
struct PendingLink: Identifiable, Equatable { let id: String /* device id */; let name: String; let sas: String; let receivedAt: Date }
private(set) var pendingLinks: [PendingLink]
func handleHello(_ record: CloudRecord) async throws        // the relay hands it every opened hello
func confirmLink(deviceID: String) async throws             // owner clicked Link
func refuseLink(deviceID: String) async throws              // owner clicked Refuse; also on sheet close and code expiry
// uses LinkRefusal.notConfirmed (Kit, Task 4)
```

**Behaviour:** `handleHello` opens the hello with `hub_kx` (SecureTransport already did), verifies the hello signature with the enclosed `signing_key`, requires `device_id == KeyDerivation.deviceID(signing_key)`, runs the creator check (unchanged rules), then the nonce decision **without consuming the code** (`LinkDecision.of`): a refused nonce publishes a refusal keybox sealed to the hello's agreement key, as today's `link_refused`; a valid one stores `pending_devices` (same device + nonce again → no-op), computes the SAS, nudges the publisher (the keybox reads `awaitingConfirmation: true`, no keys) and shows the pending row. `confirmLink` runs `linkDevice` (re-checking the code; it may have expired meanwhile → refusal `expired_code`), stores the keys, deletes the pending row, publishes the keybox with keys (epoch, `K_data`, `K_alert`, `K_meta`), then `closeAfterLink` as today. A second pending device on the same code stays pending until the owner decides (it cannot link once the first consumed the code: `used_code`). `refuseLink` publishes `not_confirmed`. `closeLink(reason:)` refuses every pending request first; the participant sweep runs after that, so a pending phone's participant is never swept before the owner decided.

**Sheet:** while `pendingLinks` is non-empty, the QR is replaced by one row per request: "Link "<name>"?" over "Code 7342 — check that your iPhone shows the same code", buttons **Link** and **Refuse**. A refused or expired request disappears; a confirmed one shows "Linked <name>" as today.

- [ ] **Step 1: Failing tests.**
  - `MobileLinkCenterTests.testAValidHelloWaitsForTheOwnerAndPublishesNoKeys` — the keybox (opened with the test phone's key) has `awaitingConfirmation == true`, `keys == nil`; `devices` is empty; the code is unused.
  - `testConfirmLinksAndPublishesASignedKeyboxWithTheCurrentEpoch`.
  - `testTwoHellosForOneCodeShowTwoCodesAndOnlyTheConfirmedOneGetsKeys` (Review Focus 5) — two phones, two different SAS strings; confirm A → A linked with keys; B's confirm → refusal `used_code`, never keys.
  - `testClosingTheSheetRefusesPendingRequestsBeforeTheSweep`.
  - `testAHelloWhoseDeviceIDIsNotItsKeyHashIsIgnored`.
  - `testAHelloSignedByAnotherKeyIsIgnored`.
  - `testTheQRCarriesTheHubsPublicKeys` (decode `issueCode()`'s payload; keys equal the keyring's).
  - `testTheSASMatchesThePhonesComputation` (`KeyDerivation.sas` with the phone's inputs).
  - The existing creator, nonce and expiry tests keep their assertions, driven through hellos.
  - `MobileLinkSheetViewModelTests.testAPendingRequestReplacesTheQRWithItsCodeAndButtons`, `testLinkAndRefuseCallTheCenter`.
  - `MobileSettingsViewTests.testThePendingRowShowsNameCodeAndBothButtons` (ViewInspector).

- [ ] **Step 2: Run to fail.** `make test-swift FILTER='MobileLinkCenterTests|MobileLinkSheetViewModelTests|MobileSettingsViewTests' > /tmp/e2e13a.log 2>&1; echo "exit=$?"`.

- [ ] **Step 3: Implement** as described.

- [ ] **Step 4: Run to pass.** Step 2 command → `exit=0`; `make test-swift FILTER='MobileSettingsViewModelTests|RelayProcessorTests' > /tmp/e2e13b.log 2>&1; echo "exit=$?"`. `make lint-diff`.

- [ ] **Step 5: Commit.** `feat(mobile-e2e): QR v3 with hub keys, sealed hello, owner confirmation with a four-digit code`.

Self-review: the checklist above (Swift conventions: the pending state lives in `MobileLinkCenter`, which survives the sheet; every new observable state has tests).

---

## Task 14: Mac — rotation on Remove and unlink; revoked keyboxes; hub off

**Depends on:** Task 13. **Lane:** Desktop.

**Files:**
- Modify `WatchtowerDesktop/Sources/Services/MobileHub/HubSyncState+Keys.swift` (`removeDeviceAndRotate`), `HubKeyring.swift` (`rotate(reason:)`, cache drop), `MobileLinkCenter.swift` (`remove(deviceID:)` and the phone's own `unlinked: true` use it; `hubZonesDeleted()` also resets group keys), `MobileHubService.swift` (cycle start: `rotationDue()` → rotate; a resume check), `Slices/DeviceGrantSlice.swift` (revoked keyboxes for 7 days).
- Modify `WatchtowerDesktop/Sources/Views/Settings/MobileSettingsView.swift` (the same-Apple-ID Remove sentence; see below).
- Test: modify `MobileLinkCenterTests.swift`, `MobileHubServiceTests.swift`, `HubKeyringTests.swift`, `MobileSettingsViewTests.swift`.

**Interfaces (produces):**

```swift
// HubSyncState
/// One immediate transaction: delete the device row (and its relay_seen rows), insert revoked_devices,
/// retire the current epoch, insert the new sealed epoch, wipe slice hashes (keeping the relay token).
func removeDeviceAndRotate(_ deviceID: String, newEpoch: (epoch: UInt32, sealedKeys: Data), at: Date) throws -> LinkedDevice?
/// The same without a device (cap, suspected leak).
func rotate(newEpoch: (epoch: UInt32, sealedKeys: Data), at: Date) throws
// HubKeyring
func rotate(reason: RotationReason) throws        // .removed(deviceID), .cap, .manual
enum RotationReason: Equatable { case removed(String), cap, manual }
```

**Behaviour:** rotation is one transaction (Review Focus 4); the publisher's next cycle sees no hashes and republishes the whole window under the new epoch, keyboxes included (remaining phones get the new keys and the previous epoch's keys). A crash before the commit leaves the old epoch and the device linked (Remove reports failure); after it, everything follows from the committed state. `revoked_devices` rows publish `Keybox(grant: linked false, revoked true, keys nil)` for 7 days, then are pruned. Removing a same-Apple-ID phone now says "Removed <name>. It can no longer read anything new from this Mac." (D9; the old "can still read synced data until you sign it out of iCloud" sentence goes — what the phone already holds stays, which the doc states).

- [ ] **Step 1: Failing tests.**
  - `HubKeyringTests.testRotationCommitsTheEpochAndTheHashWipeTogether` (Review Focus 4) — the test installs a SQLite trigger on the in-memory sidecar, `CREATE TRIGGER fail_wipe BEFORE DELETE ON slice_state BEGIN SELECT RAISE(ABORT, 'test'); END`, so the transaction fails after the epoch insert: `rotate` throws, the current epoch is still the old one, the hashes are intact, and the device is still linked. No production test hook.
  - `HubKeyringTests.testAKilledRotationResumesOnTheSameEpoch` — rotate, drop the keyring, build a new one over the same sidecar: current epoch is the new one, never a third.
  - `MobileLinkCenterTests.testRemoveRotatesAndTheRemovedPhoneCannotOpenNewRecords` — the removed phone's keys open epoch-1 records, not epoch-2 ones; the remaining phone opens epoch 2 after reading its keybox.
  - `testTheRemovedPhonesKeyboxReadsRevokedForSevenDays`.
  - `testAPhonesOwnUnlinkRotatesLikeRemove`.
  - `testRelayRecordsOfTheRemovedPhoneAreDroppedNotEchoed`.
  - `MobileHubServiceTests.testRotationRunsWhenDueAtCycleStart`, `testTurningTheHubOffResetsGroupKeys`.
  - `MobileSettingsViewTests.testRemovingASameAppleIDPhoneShowsTheNewSentence`.

- [ ] **Step 2: Run to fail.** `make test-swift FILTER='HubKeyringTests|MobileLinkCenterTests|MobileHubServiceTests|MobileSettingsViewTests' > /tmp/e2e14a.log 2>&1; echo "exit=$?"`.

- [ ] **Step 3: Implement** as described.

- [ ] **Step 4: Run to pass.** Step 2 command → `exit=0`; `make lint-diff`.

- [ ] **Step 5: Commit.** `feat(mobile-e2e): epoch rotation on remove and unlink, revoked keyboxes`.

Self-review: the checklist above.

---

## Task 15: Mac — hard-cut migration (`e2e_v1`)

**Depends on:** Tasks 11–14. **Lane:** Desktop.

**Files:**
- Modify `WatchtowerDesktop/Sources/Services/MobileHub/MobileHubService.swift` (start path), `HubIdentity.swift` or a new `HubSyncState+Keys.swift` helper for the marker.
- Test: modify `MobileHubServiceTests.swift`.

**Behaviour:** at `start()`, before `transport.start()` and before the per-hub adoption (the place that today re-runs a pending zone delete): if `hub_meta.e2e_v1` is absent, or `HubKeyring.identityWasRecreated` is true, set `hub_zones_delete_pending` and `e2e_v1 = pending`. The existing pending-delete code then deletes the hub's two zones (with their shares), forgets phones (`hubZonesDeleted()`, which also resets group keys), wipes sync state and clears the marker; only when that succeeded is `e2e_v1 = 1` written and `ensureGroupKeys()` run. A failure or timeout keeps both markers (hub `.unavailable`, the reprobe loop retries), exactly like today's Settings-off path. Records of the old type that a phone still holds in a zone are never read by the new build (Task 7 ignores them).

- [ ] **Step 1: Failing tests.**
  - `testFirstStartOnTheE2EBuildDeletesTheZonesForgetsPhonesAndSetsTheMarkerOnce`.
  - `testAFailedMigrationDeleteKeepsTheMarkerPendingAndRetriesNextStart`.
  - `testARecreatedIdentityTriggersTheSameCut`.
  - `testAMigratedHubDoesNotCutAgain`.

- [ ] **Step 2: Run to fail.** `make test-swift FILTER=MobileHubServiceTests > /tmp/e2e15a.log 2>&1; echo "exit=$?"`.

- [ ] **Step 3: Implement**; **Step 4:** run to pass + `make lint-diff`.

- [ ] **Step 5: Commit.** `feat(mobile-e2e): hard cut — the hub recreates its zones once and every phone re-pairs`.

Self-review: the checklist above.

---

## Task 16: Phone — device keys, pairing v3 with the code, keybox handling

**Depends on:** Tasks 4, 5, 8 (and 13 for the end-to-end shape). **Lane:** phone (heavy; never beside a Desktop task).

**Files:**
- Modify `WatchtowerMobile/Sources/App/LinkStore.swift` (`DeviceIdentity.deviceID` from `PhoneKeyStore.identity().deviceID`; `DeviceIDKeychain` removed; `LinkRecord` gains nothing secret — keys live in the Keychain; a stored v2 `LinkRecord` without a `HubLinkKeys` entry is "not linked"), `Sources/Features/Onboarding/LinkingViewModel.swift` (hello, SAS, wait), `Sources/Features/Onboarding/LinkSteps.swift` and the waiting view (the code), `Sources/App/AppRoot.swift` (revoked keybox → the removal flow; the v2 link drop at launch with "Watchtower now encrypts your data. Scan the code on your Mac again.").
- Test: modify `WatchtowerMobile/Tests/LinkingViewModelTests.swift`, `AppRootWiringTests.swift`; create `WatchtowerMobile/Tests/KeychainKeyStoreDeviceTests.swift` (real `SecItemKeychainBackend` on the simulator; `XCTSkip` on `.missingEntitlement`).

**Behaviour:** scanning a v3 code saves `HubLinkKeys(hubSigningKey, hubAgreementKey, linkNonce, metaKey: nil, epochs: [])`, writes the `hello-<device_id>` record (sealed by `SecureTransport`), and shows "Check that your Mac shows **7342**, then click Link on the Mac." The wait polls the keybox (`device_grant-<device_id>` in the replica, opened through the keybox path) every 2 s until the code's `exp + expiryGrace` (not 60 s: the owner needs time): `awaitingConfirmation` → "Your Mac sees this iPhone"; `linked` with keys → `saveHubLink` with `metaKey` and epochs, the link is saved, "Linked to <Mac>"; any refusal (including `not_confirmed`) → the refusal screen; timeout → "Your Mac didn't answer". Later keyboxes with a new epoch update the stored epochs (after unlock, through `indexPending`'s callback). A keybox with `revoked == true` runs the existing "This Mac removed this phone" wipe (both scopes). Unlink and removal delete the hub's keys (`removeHubLink`).

- [ ] **Step 1: Failing tests.**
  - `LinkingViewModelTests.testAV3ScanWritesASealedHelloAndShowsTheCode` (the fake Mac opens it with the hub key and computes the same SAS).
  - `testTheWaitLastsUntilTheCodeExpiresAndShowsMacSeesThisIPhone`.
  - `testAConfirmedKeyboxStoresKeysAndLinks`.
  - `testANotConfirmedRefusalShowsTheRefusal`.
  - `testAV2CodeReadsUpdateTheMac`.
  - `AppRootWiringTests.testARevokedKeyboxRemovesThePhoneInPrivateScope`.
  - `testAV2LinkIsDroppedAtLaunchWithTheReScanNotice`.
  - `KeychainKeyStoreDeviceTests.testIdentityRoundTripsAndIsNotSynchronizable` (reads the item's attributes: `kSecAttrSynchronizable` false, accessibility `WhenUnlockedThisDeviceOnly`).

- [ ] **Step 2: Run to fail.** `make mobile-test MOBILE_FILTER='LinkingViewModelTests|AppRootWiringTests|KeychainKeyStoreDeviceTests' > /tmp/e2e16a.log 2>&1; echo "exit=$?"`.

- [ ] **Step 3: Implement** as described; `make mobile-gen` only if a file was added to a new directory that `project.yml` does not already cover (`Sources` and `Tests` are globbed).

- [ ] **Step 4: Run to pass.** Step 2 command → `exit=0`; `make lint-diff`.

- [ ] **Step 5: Commit.** `feat(mobile-e2e): phone pairing with device keys, the four-digit code and keyboxes`.

Self-review: the checklist above.

---

## Task 17: Phone — E2E wiring, locked-state behaviour, file protection, the demo

**Depends on:** Tasks 9, 16. **Lane:** phone.

**Files:**
- Modify `WatchtowerMobile/Sources/App/AppEnvironment.swift` (build `SecureTransport(inner: CloudKitTransport/InMemory, keys: PhoneKeyProvider, rollback: replica-backed guard)`, `ReplicaStore(path:opener: EnvelopeReplicaOpener)`, pass the secure transport to the outbox, uploader, feed, `DeviceSettings`; call `store.indexPending()` and `uploader.sealPending()` on `UIApplication.protectedDataDidBecomeAvailableNotification`; set file protection), `Sources/App/DemoSeed*.swift` (seed through a demo hub `SecureTransport` with `InMemoryHubKeyStore` and a demo phone `InMemoryPhoneKeyStore` paired in code), `Sources/Features/Recording/PhoneRecorderController.swift` (`.completeUnlessOpen` on the capture file; `sealPending()` right after a finish), `Sources/Features/Settings/SettingsViewModel.swift` (`newerFormatCount() > 0` → "Update Watchtower on this iPhone: your Mac uses a newer format.").
- Modify `WatchtowerKit/Sources/WatchtowerSync/CloudKitTransport/TransportStore.swift` only to expose the stash directory URL for the protection call (no behaviour change).
- Test: modify `ReplicaWiringTests`, `RecordingUploadWiringTests`, `SettingsWiringTests`, `ScreenshotTourTests` (must still render every screen), and every phone test that saved plaintext records directly into the in-memory transport (seal through the demo hub; listed in the commit message).

**File protection (D8):** `appGroupDirectory()/replica*`, the transport store and its `transport-assets/` stash → `FileProtectionType.completeUntilFirstUserAuthentication` set on the directory before the databases are created; `phone-recordings/` → `.completeUnlessOpen` for `.m4a` files (set on creation by the recorder), sealed `.enc` files inherit the directory's class C. A test reads the attributes back.

- [ ] **Step 1: Failing tests.**
  - `ReplicaWiringTests.testTheLiveEnvironmentReadsOnlyThroughTheEnvelopeOpener` (a plaintext record saved straight into the inner transport never appears).
  - `testUnlockIndexesRowsHydratedWhileLocked` (drives `protectedDataDidBecomeAvailable` with `InMemoryPhoneKeyStore.isLocked`).
  - `RecordingUploadWiringTests.testFinishSealsTheRecordingAndRemovesThePlainFile`.
  - `testFileProtectionClassesAreSetOnTheDirectoriesAndTheCapture`.
  - `SettingsWiringTests.testANewerFormatShowsTheUpdateRow`.
  - `ScreenshotTourTests` unchanged assertions (every file written) — the demo still renders through E2E.

- [ ] **Step 2: Run to fail.** `make mobile-test MOBILE_FILTER='ReplicaWiringTests|RecordingUploadWiringTests|SettingsWiringTests' > /tmp/e2e17a.log 2>&1; echo "exit=$?"`.

- [ ] **Step 3: Implement** as described.

- [ ] **Step 4: Run to pass.** Step 2 command → `exit=0`. This task touches the boot path of every screen, so it also runs the phone suites that build an environment, by name: `make mobile-test MOBILE_FILTER='AppRootWiringTests|NowWiringTests|WorkbenchWiringTests|CalendarWiringTests|RecordingsWiringTests|BoardWriteWiringTests|StartSheetWiringTests|SessionDetailWiringTests|OrangeToneTests' > /tmp/e2e17b.log 2>&1; echo "exit=$?"`. `make lint-diff`.

- [ ] **Step 5: Commit.** `feat(mobile-e2e): the phone runs every read and write through E2E; file protection classes`.

Self-review: the checklist above.

---

## Task 18: Phone — `K_alert` for the notification extension

**Depends on:** Tasks 11, 17. **Lane:** phone.

**Files:**
- Create `WatchtowerKit/Sources/WatchtowerSync/Secure/AlertOpener.swift` (opens an `ask_alert` envelope with `K_alert[e]` and the hub signing key from `PhoneKeyStore.alertKeys`; returns the alert payload).
- Create `WatchtowerKit/Sources/WatchtowerSync/Secure/AskAlertSubscription.swift` (the `CKQuerySubscription` on `WatchtowerSignal` with `NSPredicate(value: true)` in the hub's DataZone, `shouldSendContentAvailable = false`, an alert body placeholder "A session is waiting"; registering it is A13's job).
- Modify `WatchtowerMobile/WatchtowerMobile.entitlements`, `WatchtowerMobile/NotifyService/NotifyService.entitlements` (`keychain-access-groups`: `$(AppIdentifierPrefix)com.aiwatchtowers.watchtower.mobile.alerts`), `WatchtowerMobile/NotifyService/NotificationService.swift` (on a CloudKit query notification for a `sig-…` record: fetch the alert record named by the suffix with a 20 s bound, open it, set the title and body; any failure delivers the content-free notification unchanged), `WatchtowerMobile/project.yml` (the extension links `WatchtowerSync`), then `make mobile-gen`.
- Test: create `WatchtowerKit/Tests/WatchtowerSyncTests/AlertOpenerTests.swift`, `AskAlertSubscriptionTests.swift`.

- [ ] **Step 1: Failing tests.**
  - `AlertOpenerTests.testAnAlertOpensWithTheAlertKeyOnly` — the data key cannot open it; a record of class `.data` is refused by the opener.
  - `testTheAlertStoreHoldsNoDataOrMetaKey` (the shared-group item's bytes).
  - `testAnAlertOfAnUnknownEpochFailsQuietly` (returns nil; the extension then shows the generic text).
  - `AskAlertSubscriptionTests.testTheSubscriptionTargetsTheSignalTypeInTheHubsDataZone`.

- [ ] **Step 2: Run to fail.** `make kit-test FILTER='AlertOpenerTests|AskAlertSubscriptionTests' > /tmp/e2e18a.log 2>&1; echo "exit=$?"`.

- [ ] **Step 3: Implement**; the extension code is thin glue over `AlertOpener` (no logic beyond fetch → open → set fields).

- [ ] **Step 4: Run to pass.** Step 2 command → `exit=0`; `make mobile-build > /tmp/e2e18b.log 2>&1; echo "exit=$?"` (the extension compiles and links). `make lint-diff`.

- [ ] **Step 5: Commit.** `feat(mobile-e2e): K_alert in a shared keychain group, the ask-alert signal subscription and opener`.

Self-review: the checklist above.

---

## Task 19: Docs — feature notes, index line, inventory check

**Depends on:** Tasks 1–18. **Lane:** any (no build).

**Files:**
- Modify `docs/features/mobile-companion.md`: a new top-level section **"End-to-end encryption (E2E1–E2E18)"** between Architecture and Building (keys and where they live, the envelope and its classes, record naming, pairing with the code, rotation and revocation, the locked-phone behaviour, file protection, the migration and "a new Mac is a new pairing", the Go cross-check, `WT_E2E_REGENERATE`); update **Architecture** (Kinds/record names are opaque on the wire; `SecureTransport` above the seam), **Linking, hub half** (hello, pending requests, confirmation, keyboxes replacing `device_grant`, the device gate is key-based with the creator check as defense in depth), **Settings → Mobile** (the pending row, the new Remove sentence), **Transport** (record types, legacy type ignored), **Replica, outbox and relay feed** (ciphertext, apply-time verify, rollback guard, indexing on unlock), **Link code and device grant** (`LinkPayload` v3, `Keybox`), **Onboarding and linking, phone half** (the code, the longer wait, v2 drop at launch), **Phone recorder and uploader** (seal at finalize, `.enc`, re-send the stored envelope), **Known limits** (replace "A same-Apple-ID phone removed on the Mac is not told" with what D9 does; add: metadata left per spec §4, `K_meta` not rotated (D5), relay ordering (D4), availability, the extension's low-value key, re-pair after restore to new hardware).
- Modify `CLAUDE.md`: the Mobile companion index line gains "; E2E (2026-10-12): `SecureTransport`, envelope + keybox + hub-signed DataZone, owner-confirmed pairing with a four-digit code, ciphertext replica" (one clause, keep the line's style).
- Inventory: run `grep -rln "MobileHub\|CloudKitTransport\|RelayProcessor\|LinkPayload\|device_grant" docs/inventory/`. If it finds only the dated note in `workbench.md`, add nothing (no contract moved: the hub's owner-surface write paths are unchanged). If it finds anything else, stop and ask the owner before editing it.
- The base design spec's sentence "end-to-end encrypted when the user has Advanced Data Protection on" (`docs/superpowers/specs/2026-10-07-mobile-poc-design.md`) is history; add one line under it: "Superseded by app-level E2E, see docs/features/mobile-companion.md (2026-10-12)."

- [ ] **Step 1:** write the sections; every name used (types, tables, columns, messages) must match the code on the branch (`grep` each before writing it).
- [ ] **Step 2:** `bash scripts/leak-check.sh` over the working tree's diff if the script supports it, else review by eye for ids, emails and paths.
- [ ] **Step 3: Commit.** `docs(mobile-e2e): feature notes, index line`.

Self-review: the checklist above (public-repo hygiene especially).

---

## Task 20: Owner device smoke (an ask with a checklist)

**Depends on:** Task 19 and the phase-end gate. **Lane:** owner.

The controller opens a CHECK ask on the board (`ask_owner`, kind check) with the steps below, the builds to use, and "Broken" notes going back to the owning task. Prerequisites the controller states in the ask: a Development-signed Mac build (`WATCHTOWER_CLOUDKIT_ENV=Development`) with an Xcode-run phone **or** a Developer ID Mac with a TestFlight phone; before the Production pair, the owner deploys the `WatchtowerEnvelope` and `WatchtowerSignal` record types from Development to Production in the CloudKit Console and `make cloudkit-check` passes.

Checklist (each an item of the ask):
1. **Migration.** Start the new Mac build with an old pairing: the hub recreates its zones once; the old phone build shows "This Mac removed this phone"; the new phone build with a v2 link shows "Watchtower now encrypts… scan again".
2. **Same-Apple-ID pairing.** Scan the QR: the Mac shows "Link <iPhone>? Code NNNN", the phone shows the same code; Link → phone shows "Linked". Refuse on a second attempt → phone shows the refusal.
3. **Shared-scope pairing** (a second Apple ID): the same, plus the share accept.
4. **Photographed QR race.** Scan one QR with two phones: the Mac lists two codes; only the confirmed phone links.
5. **Content.** Now, Workbench, Calendar, an ask answer, a board write, a session start/stop all work; CloudKit Console (Development) shows records named by 26 random characters, kind `wt`, no readable payload.
6. **Locked phone.** Lock the phone, change something on the Mac, wait for the silent push, unlock: the change shows within seconds of unlocking.
7. **Recording.** Record 2 minutes, stop while unlocked: it reaches the Mac and is transcribed; then record, lock the phone, stop from the lock screen or let auto-stop run in a test build: it is sealed and sent after unlock. A long recording (≈ 60–90 MB) uploads and ingests.
8. **Transcript asset.** A meeting transcript's segments open on the phone.
9. **Remove and rotation.** With two phones linked, Remove one: it shows "This Mac removed this phone" (also for the same-Apple-ID one); the other keeps working after the republish.
10. **Apple ID sign-out/in on the phone.** Same account: the link and data survive; another account: Welcome.
11. **Mac locked screen.** Lock the Mac screen: the phone still sees the heartbeat and its actions are applied (D2).
12. **Ask alert signal** (if A13 is wired by then): the banner shows the ask title on a locked phone; otherwise the signal record appears next to each new ask in the Console.

---

## Phase end (controller)

1. Run `bash scripts/dev-health.sh`; stop if it reports `HEALTH: overloaded`.
2. Run the full gate once, in one lane, each to a log with its exit code: `make test` (the Go cross-check is a Go package), `make test-swift` (Desktop suite, then the Kit), `make lint-all`, `make mobile-test`. A failure goes back to the owning task as a fix round.
3. Then Task 20 (the owner's device smoke), then the PR into `feature/mobile-poc`.

## Parallel lanes

| Lane | Tasks | Notes |
|---|---|---|
| Kit (light) | 1 → {2 ∥ 5} → 3 → 4 → 7 → 8 → 9 | 2 and 5 in separate worktrees (distinct files and fixtures). Kit tasks may run beside one Desktop or phone task. |
| Go | 6 | After 1–3; beside anything. |
| Desktop (heavy) | 10 → 11 → 12 → 13 → 14 → 15 | 10 may start once 4, 5, 7 are merged, beside Kit 8–9. |
| Phone (heavy) | 16 → 17 → 18 | Never at the same time as a Desktop task (one heavy Swift build at a time). 16 needs 8 merged. |
| Docs/owner | 19 → 20 | After everything. |
