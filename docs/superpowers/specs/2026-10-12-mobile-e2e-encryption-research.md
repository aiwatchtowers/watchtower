# End-to-end encryption between the Mac hub and the phone(s) — research report

Branch `feature/mobile-poc`, read-only review, 2026-10-12. Code references are `path:line` in the repo; Apple claims carry a URL and were read from the live pages (DocC JSON or the Platform Security guide) on this date.

## 0. What the current design actually does (verified)

| Item | Where | What the storage layer sees |
|---|---|---|
| Record payload | `WatchtowerKit/Sources/WatchtowerSync/CloudKitTransport/CloudKitTransport.swift:1233` (`ck.encryptedValues["payload"]`), read at `:1262` | CloudKit "encrypted field" — see §3 for what that is worth |
| `notifyLevel` | `:1247` / `:1269` | encrypted field |
| `kind`, `modifiedAt` | `:1234-1235` | **plaintext** |
| Asset (phone audio ≤ 90 MB, `segments.json` ≤ 20 MB) | `:1240` plain `CKAsset`; `RecordingUploader.swift:38,473-476`; `MeetingTranscriptSlice` via `SlicePublisher.swift:289-299` | CloudKit's own asset encryption (keys in Apple's hierarchy, §3) |
| Record names | `SliceRecord.swift` `recordName = "<kind>-<id>"`; `DevicePayload.swift:46` `device-<device_id>`; `DeviceGrant.swift:42`; heartbeat `HeartbeatPayload.swift:11` | **plaintext**: kind, the Mac's row ids, device ids, counts per kind |
| Zone names | `HubZones.swift:24-26` `DataZone-<hub_id>` / `RelayZone-<hub_id>` | plaintext (random UUID, harmless) |
| Who authenticates a phone write | `RelayProcessor.swift:283-312` → `HubSyncState.swift:712-716` (`LinkedDevice.accepts(creator:)`): CloudKit's `creatorUserRecordID` equals the phone's iCloud user (shared) or is the Mac's own user (private) | server-asserted metadata; **no cryptographic device identity** |
| Pairing | `LinkPayload.swift:28-58` (QR: `hub_id`, `mac_name`, `owner_user`, 32-byte `nonce`, `iat/exp` 600 s, two `CKShare` URLs); hub `MobileLinkCenter.swift:160-176` (`issueCode`), `:248-295` (`handleDevice`: the **first** valid nonce links, no owner confirmation), `:222-245` (`closeLink` sweeps unbound participants) | QR is a bearer secret for 600 s; nothing in it authenticates the hub to the phone except the share URLs' owner |
| Phone key material | `WatchtowerMobile/Sources/App/LinkStore.swift:149-185`: only a random **device id** in the Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, falls back to `UserDefaults` on refusal) | — |
| Phone local state | `LinkStore.swift:44-60` link record (nonce, share URLs) in `UserDefaults`; replica + transport DB in the app group (`AppEnvironment.swift:419-430`); fetched assets copied in plaintext to `transport-assets/` (`TransportStore.swift:358-385`); recordings in Application Support `phone-recordings/` | no explicit `FileProtectionType` anywhere (grep over `WatchtowerMobile/`, `WatchtowerKit/`) → iOS default class C |
| Diffing | `SliceDiff.swift:75-90` SHA-256 of the plaintext payload (+ asset digest), stored locally in `slice_state` | local only — compatible with randomized ciphertext (good) |
| Conflicts | `CloudKitTransport.swift:961-977`: local wins by re-saving with the server change tag | content-agnostic |
| Server-side queries on plaintext | none in code today (no `CKQuerySubscription`/`NSPredicate` in Kit, phone or hub). Planned: multi-hub spec §5.5 "query subscription on `kind == "ask_alert"`" and base spec §7 | **future blocker** for hiding `kind` (§5) |
| Notification Service Extension | `WatchtowerMobile/NotifyService/NotificationService.swift` — pass-through today | will need a key when A13 fills the ask title |
| Replay / rollback | exactly-once ledger by **record name** only (`relay_processed`, 7-day prune, `docs/features/mobile-companion.md` RelayProcessor); the phone's `apply` refuses an older *token*, not an older record | storage can replay or roll back content undetected |

Note the spec's own claim (`docs/superpowers/specs/2026-10-07-mobile-poc-design.md:692`): "end-to-end encrypted when the user has Advanced Data Protection on" — correct, and that "when" is the whole problem (§3).

## 1. Threat model

Legend: **Now** = today's design, **E2E** = the scheme in §2, **Left** = what remains after E2E.

1. **Apple / iCloud breach or legal request (owner without ADP — the default).**
   Now: Apple's CloudKit service keys for standard protection sit in "available-after-authentication iCloud HSMs in Apple data centers" (Platform Security guide, §3 citations) → Apple (and whoever compels Apple) can decrypt `payload`, `notifyLevel` **and** the assets (the asset key is stored "in an encrypted field on the record", same hierarchy — Apple, *Encrypting User Data*). The 90 MB meeting audio, the transcripts, owner asks, calendar attendees and the heartbeat's account labels are all readable.
   E2E: ciphertext only; keys never exist outside the Mac and the linked phones.
   Left: metadata (threat 8), the Apple IDs involved, APNs tokens, timing of every change, byte sizes.

2. **Compromised Apple ID (password + 2FA or a trusted device), including iCloud Keychain.**
   Now: an attacker who enrols a device into the account reaches the private database; CloudKit decrypts encrypted fields for any trusted device, ADP or not (the key material is "in the user's iCloud Keychain" — Apple). So Apple-ID compromise = full read of everything, plus write access to RelayZone as the Mac's own user, which `LinkedDevice.accepts` treats as a `private`-scope phone (`HubSyncState.swift:714-715`): the attacker can send `session_start`, `board_*`, `ask_answer` for a same-Apple-ID-linked phone's `device_id` (the id is plaintext in record names). This is the strongest argument for app-level keys.
   E2E: content keys are in the device Keychain with a `ThisDeviceOnly` class, which Apple documents as incompatible with `kSecAttrSynchronizable` and as not migrating in backups — so iCloud Keychain never carries them. Phone writes are authenticated with a per-device key; an Apple-ID attacker cannot forge actions.
   Left: the attacker can delete zones/records (DoS, which the phone reads as "unlinked"), read metadata, and — in the 600 s pairing window, if they also see the QR — attempt to pair (owner-visible, §2.3).

3. **Stolen, unlocked phone (or malware on an unlocked phone).**
   Now and E2E: everything the UI can show is readable; the keys are usable while unlocked. Nothing cryptographic helps.
   E2E adds: the Mac can **Remove** the phone → epoch rotation; the removed phone cannot read anything published after that (forward secrecy for the removed device) and its relay key is dropped. Optional: gate the key behind biometrics (`SecAccessControl` `.biometryCurrentSet`) for an "app lock".
   Left: data already on the phone; typed/sent actions before removal.

4. **Lost, locked phone (or seized and imaged).**
   Now: app-group files default to class C, "Protected Until First User Authentication … the decrypted key stays in memory when the device locks" (Apple, Data Protection classes) — i.e., a device that was unlocked once since boot keeps the replica, recordings and the plaintext asset stash readable to a forensic tool that bypasses the lock screen; the link record and nonce are in `UserDefaults`.
   E2E: keys `WhenUnlockedThisDeviceOnly`; the replica stores **ciphertext** and decrypts on read (§2.6), so even class C files are useless when the key is unavailable; plaintext recordings get `.completeUnlessOpen` while recording and are replaced by their encrypted form at finalize.
   Left: anything in memory at seizure time; the OS lock screen itself.

5. **Malicious participant on a share / leaked or photographed QR.**
   Now: whoever scans the QR first within 600 s gets (shared scope) a read-only participant seat on DataZone and read-write on RelayZone, and the hub links the first valid nonce automatically (`MobileLinkCenter.swift:265-290`). Until the owner notices and Removes, the stranger reads the whole replica, every other phone's relay records (CloudKit permissions are per zone: a readWrite participant can read, modify and delete any record in the zone), and can impersonate those phones only insofar as the creator check lets them — in `shared` scope the creator must equal the linked phone's own user, so impersonation is blocked, but overwriting/deleting siblings' records is not.
   E2E: the QR carries the hub's public key; the stranger's device record is sealed to the hub and names the stranger's public key; the hub releases the group key only after the owner confirms the device name + a short authentication string on the Mac (§2.3). A race is visible and refusable; the content key is never wrapped to an unconfirmed key. The share link remains a bearer secret for **ciphertext** access only.
   Left (CloudKit-specific): a participant who sneaked into the zone before the sweep can delete/garble other phones' relay records (DoS) until `closeLink` removes them; CloudKit has no per-record ACL inside a shared zone. The future relay server fixes this with per-device mailboxes (§6).

6. **Network attacker.** CloudKit is TLS-pinned by the OS; pairing is a visual channel. Now: fine. E2E: unchanged, plus content no longer depends on TLS. Left: traffic analysis.

7. **Replay, rollback, reorder by the storage layer (Apple, a relay server, or an Apple-ID attacker).**
   Now: a RelayZone record re-inserted under a new name with an old payload is a fresh action (`relay_processed` keys on the record name; after the 7-day prune even the same name is fresh). A DataZone record rolled back to an older version is applied by the phone as-is (`ReplicaStore.apply` guards the change token, not the record).
   E2E: AAD binds `recordName | zone | hub_id | epoch | seq | kind` into the AEAD tag; the hub keeps `last_seq` per device and the phone keeps `(epoch, seq)` per record — a swapped, replayed or rolled-back ciphertext fails authentication or is ignored as stale. Deliberate re-sends (the uploader's relaunch retry, `RecordingUploader.swift:384-389`) carry the same `seq` **and** the same ciphertext and are accepted as idempotent duplicates.
   Left: deletion and withholding (availability). The heartbeat's `(seq, time)` lets the phone show staleness, not prevent it.

8. **Metadata.** Now leaks: kind and the Mac's row ids in record names (`owner_ask-<id>`, `calendar_event-<id>`, `device_grant-<device_id>`), counts per kind, exact sizes (audio bytes ≈ meeting length), `modifiedAt`, change timing (the fast lane publishes within 1–2 s of a session state change → the Mac's working rhythm is observable), heartbeat every 300 s, `hub_id`, the Apple IDs of owner and participants.
   E2E: opaque record names (`HMAC(K_meta, kind‖id)`), `kind` moved inside the envelope (a constant on the wire), payloads padded to size buckets, assets padded to 1 MiB.
   Left: total record count and churn, coarse sizes, timing, Apple IDs/APNs tokens, the fact that a hub exists. Do not promise "no metadata".

## 2. Recommended scheme

Design rule: the **envelope and keys know nothing about CloudKit**. Encryption lives in a `SecureTransport` wrapper above the `CloudSyncTransport` seam (`CloudSyncTransport.swift:82-95`), so `InMemoryCloudTransport`, `CloudKitTransport` and a future relay transport carry the same bytes. CloudKit's `encryptedValues` stays as a free outer layer.

### 2.1 Primitives (CryptoKit only, no third-party crypto)

Design constraint (owner): the **protocol** uses only standard, platform-neutral algorithms that exist in Swift CryptoKit, Kotlin/JVM (Tink, BouncyCastle, Android `KeyAgreement`/`Signature` with X25519/Ed25519 since API 33, or libsodium) and Go (`crypto/ecdh`, `crypto/ed25519`, `golang.org/x/crypto/chacha20poly1305`, `hkdf`, `hpke`). Apple-only facilities (Secure Enclave, Keychain) and their Android twins (Keystore/StrongBox) are **local key storage**, never part of the wire format.

- Suite 1 (the protocol): X25519 (`Curve25519.KeyAgreement`), Ed25519 (`Curve25519.Signing`), HKDF-SHA256, ChaCha20-Poly1305 (`ChaChaPoly`), HPKE RFC 9180 `DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, ChaCha20Poly1305` for key wraps and sealed boxes (CryptoKit `HPKE`, iOS 17 / macOS 14 — matches the project minimums; verify in Xcode). All four are byte-for-byte interoperable across the three languages; freeze test vectors in the Kit fixtures and reuse them from Go/Kotlin later. ChaChaPoly over AES-GCM: no hardware dependency, one implementation story on every platform.
- Local storage of the suite-1 private keys: Apple Keychain (§2.6); on Android the equivalent is Keystore/StrongBox wrapping of the software X25519/Ed25519 keys. Secure Enclave and StrongBox cannot hold Curve25519 keys (the SE's nested types are `P256`, `MLKEM768`, `MLKEM1024`, `MLDSA65`, `MLDSA87` — no Curve25519), so using them *as* the protocol key would force a P-256 suite and split the ecosystem; use them only to wrap the software keys at rest if that is ever wanted. Honest value of hardware keys here: they stop key *extraction* (a copied `~/Library`), not *use* by malware running as the user — and the Mac holds all plaintext anyway. Not for v1.
- Suite 2 (reserved): hybrid X25519 + ML-KEM-768 for the key wraps only (recordings are long-lived — "harvest now, decrypt later"); available in CryptoKit (`MLKEM768`), Go (`crypto/mlkem`) and BouncyCastle. Content AEAD is unaffected.

### 2.2 Key hierarchy

```
Mac (hub)                                   Phone i (device)
hub_sig  Ed25519   identity, signs data      dev_sig_i  Ed25519  identity (also device_id = H(pk))
hub_kx   X25519    pairing + sealed inbox    dev_kx_i   X25519   pairing
K_meta   32 B      record-name HMAC          (received at pairing, per hub)
K_data[e] 32 B     DataZone epoch e, random  (unwrapped from keybox_i via HPKE)
K_relay_i = HKDF(ECDH(hub_kx, dev_kx_i), salt = nonce, info = "wt/relay/v1/" ‖ hub_id ‖ device_id)
   → K_relay_i→hub, K_relay_hub→i (two HKDF labels; one key per direction)
K_asset  32 B      random per asset, wrapped inside the owning record's envelope
K_alert[e] 32 B    low-value epoch key for the notification extension only (optional)
```

- DataZone is one sender (hub) → many readers: a **group key per epoch**, wrapped once per device with HPKE to `dev_kx_i` and published in that device's `keybox` record (today's `device_grant-<device_id>` is the natural carrier). Every DataZone envelope is additionally **signed by `hub_sig`**: a same-Apple-ID phone can write to DataZone (CloudKit cannot stop it), and in a relay or team topology other members hold the group key, so readers must verify authorship, not just the AEAD tag.
- RelayZone is pairwise: AEAD under `K_relay_i→hub` authenticates the device (only the hub and that phone know it) — no per-record signature needed. The hub's echo (today: a rewrite of the same record with `status`) goes under `K_relay_hub→i`; the phone verifies it is the hub's.
- No per-record DEK for payloads (one AEAD call per record); per-asset DEK for files.
- Nonces: random 96-bit per message, with a hard cap per key (rotate the epoch after 2^28 messages or 90 days) — simpler and crash-safe compared with persisted counters, and far inside the birthday bound at Watchtower volumes.
- Rotation/epoch: on **Remove**, phone **unlink**, a suspected leak, or the cap, the hub creates `K_data[e+1]`, wraps it for the remaining devices, publishes the keyboxes, and republishes the window (it already knows how: `wipeSyncState`/full republish). Payloads are a few MB; assets (≤ 200 transcripts × ≤ 20 MB) can be re-encrypted lazily or left — the removed device already had them. The removed device's row (and `K_relay_i`) is dropped, so its records fail authentication and are echoed `device_not_linked` as today.

### 2.3 Pairing over the existing QR

QR v3 (`LinkPayload` gains fields, `v` → 3 so old phones read "Update Watchtower on this iPhone", `LinkPayload.swift:177-178`): `hub_kx_pub`, `hub_sig_pub`, `nonce`, `hub_id`, `iat/exp`, the share URLs, `mac_name`, `owner_user`. ≈ +130 base64url characters; the QR already carries two share URLs.

1. Phone scans, learns the hub's public keys from the trusted visual channel (this is what authenticates the Mac to the phone — missing today).
2. Phone writes its `device` record **sealed to `hub_kx_pub`** (HPKE, info = nonce): `{dev_sig_pub, dev_kx_pub, nonce, name, model, scope, user_record_name}`. Nothing in the zone reveals the phone's keys or the nonce to a bystander.
3. Hub opens it, checks the nonce exactly as `handleDevice` does now, derives `K_relay_i`, computes `SAS = HKDF(transcript, "sas")[0..<2] mod 10 000`, and — **new** — shows "Link <name>? Code 7342" in the sheet; the phone shows the same four digits. Owner confirms on the Mac (one click; the same place that today shows "Linked <name>").
4. Only then the hub writes `keybox_i` = HPKE-wrap(`dev_kx_pub`, {`K_data[e]`, `K_meta`, epoch, grants}), signed by `hub_sig`, and links the device. The phone verifies the signature with the key from the QR.

Why not a symmetric key in the QR: it is simpler, but a screenshot/photo of the QR is then the whole secret for 600 s with no visible trace; with the public-key flow the photo lets an attacker *propose* a device the owner sees and can refuse, and it never lets them read the group key without the owner's click. Keep the nonce single-use and 600 s as now. Bootstrap detail: the phone must find its keybox before it has `K_meta` → name it `keybox-<H(dev_kx_pub)>` (the phone knows that), not with the HMAC scheme.

### 2.4 Envelope (transport-agnostic, versioned)

```
magic "WTE" | ver u8 | suite u8 | flags u8 (bit0 signed, bit1 has-asset, bit2 padded)
| hub_id 16 B | sender_id 16 B | epoch u32 | seq u64 | nonce 12 B | kind u16 | ct_len u32
| ciphertext ‖ tag 16 B | [sig 64 B over header‖ciphertext]
```
- Everything before `ciphertext` is the AAD, plus the record name and the zone kind (data/relay) supplied out of band by the transport — so a ciphertext cannot be moved to another record, zone, hub or epoch.
- `kind` inside the envelope lets the wire `kind` field become a constant (`"wt"`); keep plaintext `modifiedAt` (the transport uses it locally as a clear-stamp, `CloudKitTransport.swift:866-868`, and the server stamps modification time anyway, so hiding it buys nothing).
- Plaintext padding to the next of 256 B, 1 KiB, 4 KiB, 16 KiB, 64 KiB, then 64 KiB multiples; must stay under `SlicePublisher.maxPayloadBytes` (900 000) *after* the ~120 B header and padding.
- Over CloudKit the envelope is the `encryptedValues["payload"]` blob; over a relay it is the message body.

### 2.5 Assets (chunked streaming AEAD, encrypt before `CKAsset`)

- Per asset: `K_asset` random; header `{asset_id, suite, chunk_size = 1 MiB, total_len, chunk_count}`; chunk `c` = `ChaChaPoly.seal(plain_c, key: K_asset, nonce: u32 0 ‖ u64 c, aad: header ‖ c ‖ last_flag)`. The last-chunk flag and `total_len` stop truncation and reordering; the owning record's envelope carries `K_asset` + header, binding file to record.
- Phone: encrypt at `finishCapture` into `phone-recordings/<id>.enc` streaming with `FileHandle` (1 MiB resident), delete the plain `.m4a`, attach the `.enc` as the `CKAsset` (`RecordingUploader.swift:473-476`), delete on `received` as now. CPU: ChaChaPoly runs at hundreds of MB/s on A-series; 90 MB is ≈ 1 s.
- Hub: decrypt streaming in the ingest path before `MeetingRecorderCenter.ingestPhoneRecording`; `SliceAssetStore` stages the **ciphertext** of `segments.json` and keeps the plaintext digest in its index (today `stagedDigest` hashes the file; it must not re-hash ciphertext and compare with a plaintext digest).
- Phone replica: `slice_assets` stores the encrypted bytes; `ReplicaStore.maxAssetBytes` (20 MiB) must allow the chunk overhead (+16 B per MiB).

### 2.6 Where keys and plaintext live

- **Phone Keychain**: `dev_sig/dev_kx`, per-hub `K_relay`, `K_data[e]`, `K_meta` under `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, `kSecAttrSynchronizable` absent. Apple: `ThisDeviceOnly` items "do not migrate to a new device" and may not be combined with `kSecAttrSynchronizable`. Why this matters: iCloud Keychain is the trust domain an Apple-ID attacker inherits (threat 2); keys that never enter it make the whole cloud a ciphertext store from Apple's and the attacker's point of view. The cost is that a phone restored to new hardware re-pairs (the replica is disposable).
- **Replica = ciphertext, decrypt on read.** `slice_records.payload` and `slice_assets.data` keep the wire envelope; `ReplicaStore.fetchAll`/`payloads(of:)` (payloads are already opaque blobs decoded on read) decrypt with the epoch key. This solves the background problem: hydration while the phone is locked only *stores* ciphertext and needs no key; the UI reads happen unlocked. Verify the hub signature once at apply and store `(epoch, seq)`; reads only do the AEAD open (≈ µs per record, a snapshot of a few thousand records costs milliseconds).
- **Outbox / pending actions**: encrypted at enqueue (the user is present).
- **File protection**: set `FileProtectionType.complete` on the per-hub directory before creating the databases (new files inherit the directory class, which covers GRDB's `-wal`/`-shm`), `.completeUnlessOpen` for the recording in progress and the transport's incoming asset stash. Because the replica holds ciphertext, a write that fails under `.complete` while locked only delays sync; if that proves noisy, class C for the DBs is acceptable **because** they hold ciphertext.
- **Notification extension**: if A13 wants the ask title in the banner while locked, give the extension only `K_alert[e]` (encrypts `ask_alert` payloads) in a shared access group with `AfterFirstUnlockThisDeviceOnly`. Everything else stays `WhenUnlocked`. The alternative is a content-free push ("A session is waiting") and no key in the extension.
- **Mac**: `hub_sig`, `hub_kx`, `K_meta`, `K_data[*]` in the Data Protection keychain (`kSecUseDataProtectionKeychain`, `WhenUnlockedThisDeviceOnly`); epoch state and per-device `pubkey`, `last_seq`, `keybox` in `hubstate.db` `devices`. The Mac holds plaintext anyway (source of truth); FileVault is the at-rest story.
- **Mac reinstall / new Mac**: the hub identity is deliberately **not** backed up. Losing it = new `hub_id` (a reinstall that loses the sidecar already makes new zones, `mobile-companion.md` §Zone lifecycle), phones show "Watchtower moved to <mac>… scan again", old zones are deleted by the legacy-zone cleanup. Nothing is lost: the Mac is the source of truth and every phone's data is a replica. Document it as a feature ("a new Mac is a new pairing").
- **Several phones**: one keybox and one pairwise key per device; the registry row per hub on the phone (multi-hub spec §5.1) gains the hub's public keys; one device identity serves all hubs, pairwise keys are per hub via the HKDF info.

### 2.7 Metadata minimization and crypto-agility

- Record name = base32(HMAC-SHA256(`K_meta`, zone ‖ kind ‖ id)[0..<16]): deterministic (upserts and deletions keep working; `slice_state` stores the opaque name next to the plain one), uninvertible to the server. The hub's own `heartbeat`, and each device's `keybox-<H(pk)>`, keep fixed, key-free names (the phone needs them before it has `K_meta`; they carry no identifying information).
- `ver`/`suite` bytes in the envelope; a receiver refuses unknown versions loudly (the phone's "Update Watchtower" path).

### 2.8 Migration from today's plaintext records

No users yet: do a hard cut. New record type name (CloudKit cannot convert existing fields and keeps the old ones in the schema), `LinkPayload.v = 3`, hub marker `e2e_v1` in `hub_meta`: on first start the hub deletes its pre-E2E zones (extend `removeLegacyZones`, `CloudKitTransport.swift:1391-1410`) and recreates them; every phone must re-pair once (it has no keys). Deploy the new record type to Production in the Console before the first Production run (`make cloudkit-check` catches it).

## 3. Compared with `encryptedValues` + ADP only

What Apple documents (quotes from the pages read on 2026-10-12):

- `encryptedValues`: "CloudKit encrypts the fields' values on-device before saving them to iCloud"; "You can encrypt values of any data type that CloudKit supports, except CKAsset, which is encrypted by default, and CKRecord.Reference"; "CloudKit doesn't support indexes on encrypted fields"; "When you enable Advanced Data Protection, the encryption keys are available exclusively to the record's owner and, if the user shares the record, that share's participants." — https://developer.apple.com/documentation/cloudkit/ckrecord/encryptedvalues
- *Encrypting User Data*: "CloudKit encrypts data with the key material in the user's iCloud Keychain. If the user loses access to iCloud Keychain, CloudKit can't access the key material"; assets: "CloudKit breaks up the asset's contents into chunks, and encrypts each chunk … CloudKit automatically stores the asset key in an encrypted field on the record"; keychain reset → `zoneNotFound` + `CKErrorUserDidResetEncryptedDataKey`, "the data becomes permanently lost". — https://developer.apple.com/documentation/cloudkit/encrypting-user-data
- Platform Security, ADP: "Advanced Data Protection also automatically protects CloudKit fields that third-party developers choose to mark as encrypted, and all CloudKit assets"; without ADP the CloudKit service keys are "uploaded to the available-after-authentication iCloud Hardware Security Modules (HSMs) in Apple data centers"; with ADP they "are deleted from those HSMs, and instead kept entirely within the Apple Account's iCloud Keychain protection domain"; and "This metadata is always encrypted, but the encryption keys are stored by Apple with standard data protection." — https://support.apple.com/guide/security/advanced-data-protection-for-icloud-sec973254c5f/web
- iCloud data security overview: under standard protection "Third-party app data stored in iCloud is always encrypted in transit and on server" (Apple holds keys); under ADP "CloudKit encrypted fields and assets are end-to-end encrypted". — https://support.apple.com/en-us/102651
- CloudKit E2E page: service keys are "available only on the user's trusted devices", "synchronized between a user's devices even if the user chooses not to use iCloud Keychain". — https://support.apple.com/guide/security/cloudkit-end-to-end-encryption-sec3cac31735/web

Consequences:

| Property | `encryptedValues`, no ADP (today, default) | `encryptedValues` + ADP | App E2E (§2) |
|---|---|---|---|
| Apple / legal request reads content | yes (HSM-held service keys) | no | no |
| Apple-ID compromise reads content | yes | yes, once a device is trusted (Apple ID + a device passcode, or recovery key/contact) | no (keys never in iCloud Keychain) |
| Share participant reads content | yes | yes (Apple: keys available to share participants) | only after owner confirmation; revocable by epoch |
| Phone writes authenticated as a specific device | no (server-asserted creator) | no | yes (pairwise AEAD) |
| Replay / rollback / swap detected | no | not documented — do not rely on it | yes (AAD + seq) |
| Per-device revocation in private scope | impossible (known limit, `mobile-companion.md:367`) | impossible | yes (epoch rotation) |
| Enforceable by the app | n/a | **no**: user opt-in, not available on managed Apple IDs / some regions, no public API to detect it | yes |
| Transport-agnostic | no | no | yes |
| Metadata | kind, names, sizes, timing | same | names/kind hidden, sizes bucketed; timing stays |

Keep `encryptedValues` as the outer layer: it costs nothing and, when the owner does have ADP, hides the envelope headers from Apple too.

## 4. Honest limits

- A compromised **unlocked** phone, or any malware on the Mac, defeats everything; the Mac is the plaintext source of truth by design.
- The platform is trusted: Apple ships the OS, CryptoKit, the Keychain and the CloudKit client. "Zero trust in Apple" is not achievable on Apple devices; "zero knowledge for Apple's servers" is.
- Metadata stays (threat 8): who, when, how much, and the push tokens. A relay server sees the same.
- Availability: Apple, a relay or an Apple-ID attacker can delete, withhold or delay; the design detects staleness, it does not prevent it.
- CloudKit shared zones have no per-record ACLs: a participant with read-write on RelayZone can trample other phones' records until swept (DoS only).
- Usability: lost phone key or restore to new hardware = re-scan the QR; new Mac = re-pair all phones; the pairing gains one confirmation click and a four-digit code. Owner must be at the Mac for every pairing (true today).
- The notification extension either shows a generic banner or holds a (low-value) key accessible after first unlock.
- Performance on the phone: AEAD on a few thousand small records per snapshot is milliseconds; 90 MB audio ≈ 1 s; Ed25519 verification once per record at apply (≈ 0.1 ms each) is invisible against the network. Decrypt-on-read costs one extra pass in the replica observers; the Kit's observations already decode on read.
- Padding costs iCloud quota (≤ 2× on small records, ≤ 1 MiB per asset) — bounded and in the owner's own quota.

## 5. Effort and the blockers in the current code

Rough plan (one engineer; the Kit first, because both ends link it):

| # | Task | Touches | Days |
|---|---|---|---|
| 1 | `Envelope` codec, `CryptoSuite` (HKDF/ChaChaPoly/HPKE/Ed25519), frozen test vectors in `WatchtowerKit/Tests/Fixtures` | Kit | 2–3 |
| 2 | `KeyStore` protocol: Keychain impl (iOS + macOS data-protection keychain), in-memory for tests; identity, per-hub pairwise, epochs | Kit | 2 |
| 3 | `ChunkedAssetCipher` streaming encrypt/decrypt, truncation/reorder tests | Kit | 1–2 |
| 4 | `SecureTransport` wrapper over `CloudSyncTransport`; opaque names; new record type; `ckRecord(from:)`/`cloudRecord(from:)` carry the envelope | Kit transport | 2–3 |
| 5 | Replica stores ciphertext, decrypts on read, `(epoch, seq)` rollback guard; outbox encrypts; `RelayFeed` verifies echoes | Kit replica/relay | 2–3 |
| 6 | `LinkPayload` v3, sealed `DevicePayload`, signed keybox (`DeviceGrant` v2), SAS derivation | Kit link | 1–2 |
| 7 | Hub identity + Keychain; `HubSyncState.devices` gains `pubkey`, `last_seq`, `keybox`; epoch table | Desktop | 2 |
| 8 | `SlicePublisher.stage()` encrypts; `slice_state` keeps opaque names; `SliceAssetStore` stages ciphertext with plaintext digests | Desktop | 2 |
| 9 | `RelayProcessor`: open + verify, seq replay check replaces the creator check as the gate (keep creator as defense in depth), encrypted echoes, streaming asset decrypt into ingest | Desktop | 2–3 |
| 10 | `MobileLinkCenter`: handshake, confirmation + SAS in `MobileLinkSheet`, rotation on Remove/unlink with full republish | Desktop | 3 |
| 11 | Migration: `e2e_v1` marker, legacy-zone deletion, Console schema deploy | Desktop | 1 |
| 12 | Phone: Keychain, pairing screen with SAS, ciphertext replica reads, recorder encrypt-at-finalize + `.enc` upload, file-protection classes, extension key group decision | Phone | 4–5 |
| 13 | Device smoke: shared scope, locked-phone background fetch, 90 MB asset, rotation, Apple-ID sign-out/in | all | 3 |

≈ 6–8 engineer-weeks including review rounds. Risky spots and blockers found in the code:

- **Background hydration while locked** vs `WhenUnlocked` keys — solved by storing ciphertext (§2.6); do not store plaintext in the replica or the key class has to drop to `AfterFirstUnlock`.
- **Planned `kind == "ask_alert"` query subscription** (multi-hub spec §5.5, base spec §7) needs a plaintext predicate. With `kind` hidden, use a separate content-free signal record type (`WatchtowerSignal`, no payload) or a zone subscription with local filtering.
- **Payload cap**: `SlicePublisher.isOversized` (900 000 B) must be checked on the padded envelope; `ReplicaStore.maxAssetBytes` on the chunked size.
- **`SliceAssetStore.stagedDigest`** hashes the staged file; with ciphertext staging it must compare the stored plaintext digest instead (it already keeps a digest index).
- **`handleSentChanges` uses the plaintext `modifiedAt`** as its clear-stamp (`CloudKitTransport.swift:866-868`): keep that field plaintext or move the stamp to a local column.
- **Bootstrap read of the grant** (`LinkingViewModel.swift:430-436`, `fetchGrant(deviceID:)`) happens before the phone has `K_meta`: the keybox needs a key-free name (§2.3).
- **Rotation atomicity**: epoch bump, wraps and the hash wipe must commit together in `hubstate.db`; a crash mid-rotation must resume, not fork epochs.
- **Relaunch retries** (`RecordingUploader` re-saves `uploading` rows; the relay's claim/retry rules) must re-send the *same* envelope bytes, not re-encrypt — otherwise the replay guard rejects the retry. Persist the envelope with the pending row.
- **Conflict path** (`fixSystemFieldsForFailedSaves`) is content-agnostic — no change, but the re-save must reuse the pending envelope bytes for the same reason.
- **`CKCurrentUserDefaultName` creator semantics** in private scope become defense in depth only; the tests in `RelayProcessorTests`/`MobileLinkCenterTests` that pin the creator gate need a key-auth twin.

## 6. Future compatibility (not part of this work)

The owner's roadmap — an own relay as the primary transport later, Android/web clients within a year, a solo-developer product with instant pushes and live session input — constrains the design here in four ways, none of which needs more than the choices already made in §2:

- **Platform-neutral protocol.** Suite 1 (§2.1) is X25519 / Ed25519 / HKDF-SHA256 / ChaCha20-Poly1305 / HPKE, all standard and available in CryptoKit, Kotlin and Go; the envelope (§2.4) is plain bytes with no CloudKit field inside it. Keychain, Secure Enclave, Android Keystore are storage only.
- **Relay later.** The envelope is already a relay message: a zero-knowledge relay would see `hub_id`, device ids, envelope headers, sizes, timing and push tokens, never keys or plaintext. Two rules to keep now so nothing has to be redone: device authentication to any server uses a **separate** credential key, never `hub_kx`/`dev_kx`/`dev_sig`; and the hub's `hub_kx_pub` doubles as a sealed-box inbox key (HPKE, RFC 9180) that any third party in any language can encrypt to. CloudKit's shared-zone weakness (no per-record ACL, threat 5) is naturally fixed by per-device mailboxes on a relay.
- **Streams, not records, for live session input / terminal mirror.** Per-record envelopes are wrong for a byte stream at keystroke latency. The same identity keys bootstrap a session: an X25519 handshake authenticated by the pairwise key (Noise-style, or simply HKDF over `K_relay_i` + fresh ephemerals), two directional ChaChaPoly keys, **counter nonces** per direction (a stream has an ordered single writer, so the random-nonce argument of §2.2 does not apply), one frame per chunk with the counter in the AAD, rekey every 2^20 frames. Terminal bytes never go through CloudKit anyway (its latency is seconds), so this is relay-only work.
- **Several Macs / a team.** DataZone is already "one group key per epoch, wrapped per member, author-signed records"; a team space is the same construction with a signed member roster. Fine to ~100 members with per-member wraps; beyond that MLS (RFC 9420). Keep `sender_id`, `epoch` and the signature in the envelope header as they are.

## 7. Verdict

**Yes, with caveats.** Confidentiality and authenticity against Apple, a legal request, a relay operator, an Apple-ID/iCloud-Keychain compromise, a lost locked phone and storage-layer replay can all be made to rest on keys that exist only on the Mac and the paired phones — that is as "maximally secure" as a client-side scheme on Apple hardware gets. What no scheme buys: a compromised unlocked endpoint, metadata (who/when/how much), availability, and trust in the platform itself.

Recommendation: build §2 now, while the POC has no users and a hard-cut migration is free; keep `encryptedValues` as the outer layer; put the encryption in a `SecureTransport` layer above the `CloudSyncTransport` seam so the relay transport inherits it unchanged; add the owner-confirmation + SAS step to pairing (the one place where today's design is weaker than it needs to be); store ciphertext in the phone replica and decrypt on read; keep keys out of iCloud Keychain and out of backups and document "new device = re-pair" as intended. Do not spend the first iteration on hardware-backed keys (and never make them the protocol key: the Secure Enclave has no Curve25519); do reserve the suite byte for an ML-KEM hybrid on the wraps.
