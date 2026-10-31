# Phone ↔ hub protocol — design

**Status:** draft for owner approval · **Date:** 2026-10-31
**Covers:** the wire contract between the iPhone app (the Kit, `WatchtowerKit/`) and a hub: today the Swift hub in `WatchtowerDesktop/Sources/Services/MobileHub/`, tomorrow the Go hub in `internal/hub/`.
**Sources, in order of authority:** the code and fixtures (Kit `WatchtowerSync`/`WatchtowerKit`, Swift hub `MobileHub*`, Go `internal/hub/wire|secure|actions|link|slices`); [mobile companion](../../features/mobile-companion.md); [Go hub design](2026-10-31-go-hub-design.md) §8–§12a; the relay client design (`docs/superpowers/specs/2026-10-29-relay-client-design.md` on branch `feature/relay-client`, below "RC"); the relay repository's design (`docs/superpowers/specs/2026-10-28-relay-design.md`) and its `docs/watchtower-client-requirements.md`.

Every rule below is built unless it is marked **Proposed**. "Swift hub" and "Go hub" are named only where they differ.

## 1. Intent

The phone and the hub are built by different people, in different languages, on different release trains. This document is the one place where their contract is written down, so that a phone engineer and a hub engineer can each build against it without reading the other side's code, and so that the owner can approve the protocol separately from the hub specs and plans. A change to anything here changes both sides together and is pinned by a shared fixture (§10).

## 2. Scope and non-goals

**In scope:** roles and transports; the security envelope; linking, grants, unlink and revoke; every slice (hub → phone record) and action (phone → hub record) with their names, keys, outcomes and caps; ordered delivery and control records; errors and versioning; the proposed capabilities block; the fixtures that pin it.

**Not in scope:**
- The relay server's own protocol (`relay.proto`, login, slots, subscriptions, App Attest): the relay repository owns it. Only what the phone and the hub exchange through it is here.
- Hub internals (sidecar schema, publisher loop, handler logic beyond its observable answer), phone UI, Desktop UI.
- The CloudKit bridge's local socket and the `session-host` protocol (both are hub-local).
- Key rotation with ephemeral X25519 (RC §1: after launch).

## 3. Roles, transports and zones

### 3.1 Roles

- **Hub**: one per host, identified by `hub_id` (a UUID made once per install, kept across account resets). It is the only writer of its data zone and the only reader of its mailboxes. It holds the plaintext; nothing else does.
- **Phone**: one device identity for every hub. `device_id` = UUID form of `SHA-256("wt/device-id/v1" ‖ dev_sig_pub)[0..<16]`, written as uppercase `uuidString`; the hub compares ids case-insensitively.
- **Transport**: stores sealed records, last version only. It never sees a key. Two transports exist: **CloudKit** (the owner's iCloud) and the **hosted relay** (paid). A hub uses one transport at a time (relay design §4.2).
- **Multi-hub.** A phone links up to `HubRegistry.limit` = 4 hubs; each is its own session with its own replica, keys (`PhoneKeyStore.hubLink(hub_id)`), seq ceiling and outbox. Nothing is shared between hubs on the wire except the phone's `device_id`. On the hosted relay a subscription holds at most 3 hubs in slots (see Open points).

### 3.2 CloudKit

- Two custom zones per hub in the hub owner's **private** database: `DataZone-<hub_id>` (hub writes, phones read) and `RelayZone-<hub_id>` (phones write actions, uploads, device records and hellos; the hub writes echoes).
- A phone on the same Apple ID reads them in its `private` scope. A phone on another Apple ID joins them through one zone-wide `CKShare` per zone in its `shared` scope: DataZone read-only, RelayZone read-write. The share URLs travel in the QR (§5.1).
- Record types: `WatchtowerEnvelope` (every sealed record; field `kind` = constant `"wt"`, the envelope in `encryptedValues["payload"]`, `modifiedAt` in the clear, a sealed asset as the record's `CKAsset`) and `WatchtowerSignal` (the one plaintext type, §4.8). The pre-E2E `WatchtowerRecord` is ignored.
- Swift hub today; on the Go hub CloudKit runs through a Swift bridge on desktop hosts (Go hub design §6.2) — **Proposed**, not built.

### 3.3 Hosted relay

- Zones (relay proto README): `data/<hub relay_device_id>` (the data zone), `relay/<hub relay_device_id>/<phone relay_device_id>` (one mailbox per phone), `pair/<slot>` (a pairing slot). `relay_device_id` = lower-case unpadded base32 of SHA-256 of the device's Ed25519 `relay_auth` public key. The relay knows no `hub_id`; each side keeps the `hub_id ↔ relay_device_id` mapping.
- The hub names the phones that may read its data zone (`set_hub_readers`; Go `SetLinkedReaders`). Mailbox writes are conditional (`expect: absent | seq`); data-zone writes are unconditional.
- Built in the Go hub (`internal/hub/transport/relay`, pinned relay client copy, `VERSION`). The phone side (`HostedRelayClient`/`HostedRelayTransport`) is **Proposed** (RC §7, branch `feature/relay-client`).

### 3.4 Which record goes where

The AAD zone byte (§4.3) is the logical lane, not the transport zone: `data = 1`, `relay = 2`, never changed.

| Record (plain name) | Writer | Lane (AAD byte) | CloudKit zone | Relay zone |
|---|---|---|---|---|
| `heartbeat`, `<slice kind>-<id>` | hub | data (1) | `DataZone-<hub_id>` | `data/<hub>` |
| `device_grant-<device_id>` (wire `keybox-<DEVICE_ID>`) | hub | data (1) | `DataZone-<hub_id>` | `data/<hub>`, and `pair/<slot>` while linking |
| `sig-<wire name>` (signal) | hub | none (plaintext) | `DataZone-<hub_id>` | not used (alerts go by push, §4.8) |
| `hello-<device_id>` | phone | relay (2) | `RelayZone-<hub_id>` | `pair/<slot>` |
| `device-<device_id>` | phone | relay (2) | `RelayZone-<hub_id>` | `relay/<hub>/<phone>` |
| `action-<uuid>` (legacy) / `a-<DEVICE_ID>-<action_seq>` (ordered) | phone, echo by hub | relay (2) | `RelayZone-<hub_id>` | `relay/<hub>/<phone>` |
| `recupload-<upload id>` (+ sealed asset) | phone, echo by hub | relay (2) | `RelayZone-<hub_id>` | `relay/<hub>/<phone>` (attachment) |
| `c-<uuid>` (control) | either | relay (2) | `RelayZone-<hub_id>` (**Proposed**) | `relay/<hub>/<phone>` |

## 4. Security envelope

### 4.1 The red line

**Nothing readable leaves the hub.** Every record either side writes to a transport is sealed with keys that exist only on the hub and on the paired phones; Apple, the relay operator, share participants and anyone holding the Apple ID see ciphertext and the metadata of §4.6 only. There is no plaintext fallback: a hub without keys publishes and reads nothing (Swift `keyring` nil; Go `secure.Record` can only come from the `Sealer`, and every transport refuses an unsealed record with `ErrUnsealed` before any I/O). CloudKit's `encryptedValues` stays as an outer layer and is not what protects content.

### 4.2 Keys and epochs

Suite 1 only: X25519, Ed25519, HKDF-SHA256, ChaCha20-Poly1305, HPKE RFC 9180 `DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, ChaCha20Poly1305`. Suite byte `2` is reserved (hybrid ML-KEM) and refused today.

| Key | Holder | Use |
|---|---|---|
| `hub_sig` (Ed25519) | hub | signs every data-lane envelope, keyboxes included |
| `hub_kx` (X25519) | hub | receives hellos; derives relay keys |
| wrap key (32 B) | hub | seals the hub's keys and content at rest (§4.9) |
| `K_meta` (32 B) | hub + linked phones | record names (§4.5); does not rotate |
| `K_data[e]`, `K_alert[e]` | hub + linked phones | data-lane content, ask alerts, per epoch `e` |
| `dev_sig` (Ed25519), `dev_kx` (X25519) | phone | signs hellos; receives keyboxes; derives relay keys |
| relay key `K_relay[dir, e]` | hub + one phone | `HKDF-SHA256(X25519(hub_kx, dev_kx), salt: link_nonce, info: "wt/relay/v1/" ‖ p2h\|h2p ‖ 0x00 ‖ hub_id(16) ‖ device_id(16) ‖ epoch u32 BE)` |

- **Epochs.** A new epoch on a phone's removal, on the cap (90 days or 2^28 seqs) and, with the relay, on every transport switch (RC §9). The previous epoch's relay-lane envelopes are accepted for 7 days — for every rotation, transport-switch epochs included (ask #843: sim rule 14's "no longer than 14 days" is not used; the hub may retire an epoch earlier once every phone acked a newer one and nothing sealed in it is held); the hub publishes the window again under `e+1`.
- **Sequence numbers.** Each sender draws envelope `seq` (u64, from 1) from a crash-safe allocator; `0` means "none". Envelope `seq` is the rollback counter only; it is not an action order (§7.5).

### 4.3 Envelope

```
"WTE" | ver u8 = 1 | suite u8 = 1 | flags u8 (bit0 signed, bit1 has-asset, bit2 padded)
| hub_id 16 | sender_id 16 | epoch u32 | seq u64 | nonce 12 | class u16 | body_len u32     (68 bytes, big-endian)
body: ciphertext ‖ tag 16   (HPKE classes: enc 32 ‖ ciphertext ‖ tag 16)
[signature 64 when signed: Ed25519 over "wt/sig/v1" ‖ AAD ‖ body]
```

- **AAD** = header ‖ zone byte ‖ length-prefixed wire record name (`EnvelopeContext` / Go `secure.Context`). A record moved to another name or lane does not open.
- Nonces are 96 random bits; for the HPKE classes the header nonce is 12 zero bytes. Parsing is strict on both sides: wrong magic, unknown version, suite, class or flag fails.
- A data or alert envelope that is unsigned, or opened without a verifier, is refused.

One example per class (frame kind / id / payload are inside the ciphertext, §4.4):

| class (u16) | Key, signer | `sender_id` | Example record |
|---|---|---|---|
| `data` (1) | `K_data[e]`, signed `hub_sig` | hub_id | frame `owner_ask` / `owner_ask-42` / `{"id":42,"title":"…","state":"open",…}` |
| `alert` (2) | `K_alert[e]`, signed `hub_sig` | hub_id | frame `ask_alert` / `ask_alert-ask-42` / `{"event":"ask","key":"ask-42","title":"Acme · Fix login","body":"…"}` |
| `keybox` (3) | HPKE to `dev_kx`, info `"wt/keybox/v1" ‖ hub_id ‖ device_id`, signed `hub_sig` | hub_id | wire `keybox-<DEVICE_ID>` / `{"grant":{…},"keys":{"epoch":3,"data_key":"…","alert_key":"…","meta_key":"…"}}` |
| `hello` (4) | HPKE to `hub_kx`, info `"wt/hello/v1" ‖ hub_id ‖ link_nonce`, signed `dev_sig` | device_id | frame `hello` / `hello-<DEVICE_ID>` / `{"device":{…},"signing_key":"…","agreement_key":"…"}` |
| `relayToHub` (5) | `K_relay[p2h, e]`, unsigned | device_id | frame `action` / `a-<DEVICE_ID>-7` / `{"id":"…","kind":"session_input","entity_id":"12","params":{"text":"run the tests"},"status":"pending","action_seq":7,…}` |
| `relayToPhone` (6) | `K_relay[h2p, e]`, unsigned | hub_id | frame `action` / `a-<DEVICE_ID>-7` / same payload with `"status":"applied","result":{"delivery":"submitted"}` |

Frozen bytes: `WatchtowerKit/Tests/Fixtures/e2e/envelope.json` (data, alert, keybox, relayToPhone) and `hpke-envelope.json` (hello, keybox).

### 4.4 Inner frame, padding, assets

- **Inner frame** (the plaintext): `inner_ver u8 (1) | kind_len u8 | kind | id_len u16 | id | notify_len u8 | notify | asset_flag u8 | [AssetDescriptor 101] | payload_len u32 | payload | zero padding`. `kind` is the plain kind, `id` the plain record name, `notify` the notify level (only ever inside the frame). A non-zero byte after the payload is malformed.
- **Padding** to the next of 256 B, 1 KiB, 4 KiB, 16 KiB, 64 KiB, then 64 KiB multiples, clipped so the envelope stays ≤ `Envelope.maxBytes` = 900 000. A record that does not fit unpadded is not published (logged, throttled).
- **Assets** (`ChunkedAssetCipher` / Go `secure.EncryptAssetFile`): a fresh `K_asset` per asset, 1 MiB chunks, chunk `c` nonce `u32 0 ‖ u64 c`, AAD = the 37-byte `AssetHeader` (`"WTA" | ver | suite | asset_id | chunk_size | total_len | chunk_count`) ‖ `c` ‖ last flag; last chunk zero-padded. The sealed file has no plaintext header; the header and key ride in the encrypted `AssetDescriptor` (key ‖ header ‖ SHA-256 of the plaintext). Caps: phone replica 20 MiB sealed (`ReplicaStore.maxAssetBytes`), recording 90 MB plaintext.

### 4.5 Record names

Wire name = 26 lower-case base32 characters of `HMAC-SHA256(K_meta, "wt/name/v1" ‖ zone u8 ‖ kind_len ‖ kind ‖ id)[0..<16]`, with the plain name split at its first `-` into kind and id. Fixed names that contain no key: `heartbeat`, `keybox-<DEVICE_ID>` (plain `device_grant-<device_id>`), `hello-<DEVICE_ID>`, and `sig-<wire name>`. Frozen: `kdf.json` `recordNames`.

### 4.6 What is in the clear

| In the clear | Sealed |
|---|---|
| Envelope header: magic, version, suite, flags, `hub_id`, `sender_id`, epoch, seq, class, body length | kind, plain record name, notify level, payload, asset key and digest |
| Wire record name (opaque HMAC; fixed names above), zone names (`DataZone-<hub_id>`, relay ids) | every slice and action field, every grant, every key except the public ones in the QR |
| Padded sizes (buckets; assets in whole MiB), record counts, timing, `modifiedAt` | the asset bytes (no plaintext header) |
| `sig-<wire name>` records (an alert exists, not its content) | alert title, workbench name, body |
| Apple IDs of share participants; APNs tokens; relay device ids | |
| The QR (shown on the hub's screen only): public keys, link nonce, share URLs | |

The phone's replica keeps each row's plain `kind` and record name in the clear on the device (class C file protection); payloads are opened again on every read.

### 4.7 Replay, rollback and the device gate

- The relay-lane hub opens a `relayToHub` record only from a linked phone, in an accepted epoch, and only when the frame's plain name maps to the wire name the AAD authenticated. Anything else is dropped unanswered (the hub has no key to answer with) and deleted by hygiene.
- A per-record `(epoch, seq)` guard keyed by wire name and sender (`relay_seen` on the hub, in the replica on the phone) ignores an older version; an identical re-delivery is idempotent. The phone's replica also refuses a data record older than the newest it has seen under that name (`data_seen`), across deletions.
- **Device gate.** An action or upload acts only for the phone whose relay key opened it: the payload's `device_id` must equal the envelope's sender and be a linked device (else `failed` `device_not_linked`); on CloudKit the record's creator is checked too. A `device` record acts only for its own sender (a mismatch is dropped, never echoed).
- **Re-sends are byte-for-byte.** The phone seals an action or upload once and every retry sends the stored envelope unchanged.

### 4.8 Alerts

- **CloudKit (built).** An `ask_alert` slice record is sealed as class `alert` under `K_alert` (the only key the phone's notification extension holds, readable after first unlock). When an alert first reaches the zone the hub also writes a payload-free `WatchtowerSignal` named `sig-<wire name of the alert>`, deleted with the alert; a private-scope query subscription fires on its creation, and the extension fetches and opens the alert (`AlertOpener.open(wireName:envelope:)`). A republish gets no new signal. A `shared`-scope phone has no subscription and posts alerts locally after each fetch.
- **Hosted relay (Proposed, not built; source: RC §10, owner-approved in that spec, ask #799; it changes only together with that spec).** The hub calls `send_alert` per paying phone with the sealed `ask_alert` envelope inline (relay design: ≤ ~3.5 KB); the extension opens it with the same `AlertOpener` under the fixed wire name **`alert-push`** in the AAD, no network. Reason: the relay pushes the envelope itself, so there is no record to fetch and no per-record wire name to bind. Neither side builds this yet.

### 4.9 Local sealing on the hub

Content the hub keeps at rest in its sidecar is sealed under the wrap key, never stored plain. `K_meta` and each epoch's `K_data ‖ K_alert` are sealed with hub id and epoch in the AAD (Swift-compatible layout, pinned by `swift-keyring.json`). Go adds `SealLocal(label, plain)` = `ChaChaPoly(wrap, plain, AAD "wt/hub-local/v1" ‖ hub_id ‖ label)`, combined layout `nonce 12 ‖ ct ‖ tag 16`, the label naming the column (today `session_milestones.text`), so a value moved to another column does not open. This is hub-local, not wire, and is listed because the red line covers it: new sidecar columns hold ids, counters, timestamps and error classes only (Go hub design §8 p. 4a).

## 5. Linking and pairing

### 5.1 The link code (QR)

`watchtower://link?d=<base64url, no padding, of the JSON>`, keys sorted, `/` not escaped. Lifetime 600 s; only the newest code links (a new code retires the open one).

| Key | v3 (Swift hub, today's phone) | v4 (Go hub) |
|---|---|---|
| `v` | 3 | 4 |
| `hub_id`, `mac_name` (≤ 60), `nonce` (link nonce, base64url), `iat`, `exp` (Unix seconds) | required | required |
| `hub_sig`, `hub_kx` (base64url, 32 bytes, not all zero) | required | required |
| `container`, `owner_user` | required | optional (absent on a headless host) |
| `data_share`, `relay_share` (CKShare URLs) | optional (absent: only a same-Apple-ID phone can link) | optional, absent without CloudKit |
| `transport` (the hub's current one), `transports` (`["cloudkit","relay"]` or `["relay"]`), `relay_device_id`, `relay_auth_pub` | — | present when the hub has a relay identity |

A reader probes `v` first: higher than its own → "newer" (update the app), lower → "older". **Today's phone refuses every v4 code as newer** (pinned by `HubContractFixtureTests.testAV4LinkIsRefusedAsNewerByTodaysPhone`), so a phone cannot link a Go hub until the Kit reads v4 — **Proposed** (RC §8, phone half).

### 5.2 The hello

The phone creates its identity on first scan, stores the scan's keys, and writes `hello-<DEVICE_ID>` (class `hello`, §4.3) carrying `DeviceHello` = `{device: DevicePayload, signing_key, agreement_key, relay_device_id?}` (keys base64url, 32 bytes). `relay_device_id` is the phone's own relay id, sent only when linking over the relay (Go reads and stores it; the Kit field is **Proposed**: RC §8). The hub tries each kept code's nonce, newest first, and checks that the signature verifies under the enclosed key and that the device id, the header's sender and the record name all hash to that key (D7). A hello that opens under no code or fails a check is dropped unanswered (the phone times out). Caps: 3 confirm nonces per code across all devices (a re-sent unchanged hello draws none), 10 refusals per code on top, 50 refusals held at once.

### 5.3 The four-digit code (SAS v2)

The hub draws `confirm_nonce` (32 random bytes) only after it accepted the hello. Code = `HKDF-SHA256(ikm: SHA-256("wt/sas/v2" ‖ hub_id ‖ link_nonce ‖ hub_sig ‖ hub_kx ‖ dev_sig ‖ dev_kx ‖ confirm_nonce), salt: link_nonce, info: "wt/sas/v2", 4 bytes)` as a big-endian u32 mod 10 000, four digits. The waiting keybox carries `confirm_nonce`; the phone shows no code until it has a well-formed one. The owner confirms on the hub (Desktop sheet; on a headless host the terminal, **Proposed**); the confirmation is bound to the code the owner saw. Frozen: `kdf.json` `sas`.

### 5.4 The keybox and `device_grant`

The hub answers each phone with one keybox `keybox-<DEVICE_ID>` = `{grant: DeviceGrant, keys?: KeyboxKeys}`. Keys are present only for a linked phone the owner confirmed under a code still valid at that moment. `KeyboxKeys` = `{epoch, data_key, alert_key, meta_key, previous_epoch?, previous_data_key?, previous_alert_key?}` (base64url, 32 bytes). At most 20 keybox records: every linked phone, then waiting requests, refusals (1 h) and revoked phones (7 days), each newest first.

| `DeviceGrant` key | Type | Meaning |
|---|---|---|
| `device_id`, `hub_id`, `name`, `scope` (`private`\|`shared`) | string | identity |
| `linked` | bool | |
| `link_refused` | `used_code`\|`expired_code`\|`unknown_code`\|`not_confirmed`\|`too_many_requests`, optional | refusal |
| `linked_at`, `decided_at` | time, optional | `linked_at` on the hub's clock; a scan accepts a link only with `linked_at ≥ iat` |
| `awaiting_confirmation`, `confirm_nonce`, `link_code_tag` | optional | waiting request; `link_code_tag` = base64url(SHA-256(`"wt/link-code/v1"` ‖ link_nonce)[0..<16]) of the scan's code |
| `revoked` | bool, optional | removed on the hub (§5.7) |
| `typing_allowed` | bool | owner grant: typed input, start brief, starting sessions, interrupt |
| `start_sessions_allowed` | bool | the phone's own opt-out as the hub stored it; an older phone reads it as the start grant |
| `start_sessions_granted` | bool, optional | owner grant for starts; the phone may start when `start_sessions_granted ?? start_sessions_allowed`, and the hub requires granted ∧ typing ∧ allowed |
| `permissions_allowed` | true or absent | owner grant for permission answers; `false` is never written |
| `ordered_actions` | int, optional | `1` = the hub runs the ordered path (§7.5). Go hub only |
| `transports` | string array, optional | the transports this hub offers. Go hub only |
| `relay_device_id`, `relay_auth_pub` | string, optional | the hub's relay identity the phone vouches for. Go hub only |

Fixture: `WatchtowerKit/Tests/Fixtures/link/hub_contract_cases.json` `device_grant`.

### 5.5 The phone's `device` record

`device-<DEVICE_ID>` (`relayToHub`) carries `DevicePayload` = `{device_id, name, model, app_version, scope, user_record_name, link_nonce?, unlinked?, typing_requested, start_sessions, permissions_requested? (true or absent), seen_at?, updated_at}`. It states what the phone asks for; it never grants anything. `start_sessions` is mirrored into `start_sessions_allowed`; `typing_requested` and `permissions_requested` show the owner a request to allow. `unlinked: true` is the phone's own unlink. The Go hub does not read `device` records yet (Swift hub only).

### 5.6 Unlink and revoke

- **Triggers:** the owner's Remove on the hub, or the phone's `device` record with `unlinked: true`.
- **One transaction** on the hub: a new epoch, the old one retired, the device removed, every slice hash blanked so the next cycle republishes the window under `e+1`. The remaining phones' keyboxes carry the new keys plus the previous epoch's.
- **The removed phone** gets, for 7 days, a keybox with `revoked: true` and no keys, signed and sealed to its own `dev_kx`; it wipes that hub's data in either scope. It holds no relay key of the new epoch, so it is never answered again. On the relay the hub also drops it from `set_hub_readers`. `K_meta` does not rotate (a removed phone can map future names of ids it knows: metadata only).
- A re-link of the same phone keeps the owner's grants and restarts its action order and rollback marks.

### 5.7 Linking over the hosted relay; vouching

- **New link (Go hub built, phone Proposed):** the phone opens a pairing slot and writes its hello into `pair/<slot>`; the hub, told by `Control{PAIRING_OPENED}` (the slot id only), answers with the keybox in the same zone. After the SAS confirmation the phone sends **`vouch_hub{hub_device_id, auth_pub}`** with its App Attest assertion, then `promote_pairing`; the hub calls `set_hub_readers`. A hub is admitted to the relay only once a paying phone vouched for its `relay_auth` key (asks #800, #801). `vouch_hub` and `HUB_NOT_VOUCHED` are **pending on the relay side** (relay ask #805); until then a refused hub login is `ErrForbidden`.
- **Upgrade of a CloudKit link (Proposed):** the hub publishes `relay_device_id` + `relay_auth_pub` in the phone's `device_grant`; the phone vouches and calls `add_slot`. No QR.
- A refusal (`ATTESTATION_*`, slot limit) keeps the hub off the relay and the phone surfaces the server's reason.
- **Accepted residual risk (Go hub design §12a, PR #523; for the owner to see at this review).** The phone's `relay_device_id` in the hello is its own claim, not bound to its `relay_auth` key, and the hub publishes it to `set_hub_readers`. An owner-confirmed phone could therefore name another slotted phone of the same account as a reader of the hub's data zone; that phone would only ever see ciphertext (it holds no keys of this hub).

### 5.8 Headless linking (Proposed)

A headless host (no Desktop, no CloudKit) prints the QR as terminal blocks with `watchtower hub pair`, waits for the hello, prints the code and asks `Confirm code 1234 on your phone? [y/N]`. Its code is v4 with `transports: ["relay"]` and no `container`, `owner_user` or share URLs; caps and refusals as above. A free (CloudKit-only) phone cannot link it. The Go link center supports it (`HeadlessHost`); the CLI verb is not built.

### 5.9 Link flow

```
Phone                              Transport                          Hub                      Owner
  | scan QR (v, hub keys, nonce)      |                                 |                         |
  |-- hello-<DEV> (HPKE→hub_kx, ----->|------------------------------->| open under kept nonces  |
  |   signed dev_sig)                 |                                 | check D7, caps          |
  |                                   |<-- keybox-<DEV> {awaiting,  ----| draw confirm_nonce      |
  |<-- poll keybox every 2 s ---------|    confirm_nonce, code_tag}     |                         |
  | show SAS 7342                     |                                 | show SAS 7342 --------->| compare
  |                                   |                                 |<------------- Link -----|
  |                                   |<-- keybox-<DEV> {linked,     ---| link in one tx; refuse  |
  |<----------------------------------|    linked_at, keys}             | other waiters used_code |
  | store keys; (relay: vouch_hub,    |                                 |                         |
  |  promote_pairing)                 |                                 | (relay: set_hub_readers)|
```

### 5.10 Revoke flow

```
Owner        Hub                                   Transport                 Removed phone      Other phones
  |-- Remove -->| rotate: e→e+1, drop device,           |                          |                  |
  |             | blank slice hashes (one tx)           |                          |                  |
  |             |-- keybox-<DEV> {revoked, no keys} --->|------------------------->| wipe hub data    |
  |             |-- keybox-<other> {keys e+1, prev e} ->|-------------------------------------------->| merge keys
  |             |-- republish window under e+1 -------->|-------------------------------------------->|
  |             | (relay: set_hub_readers without DEV)  |                          | reads nothing new|
```

## 6. Slices (hub → phone)

### 6.1 Encoding

Payloads are JSON objects with snake_case keys, keys sorted at every level, `/` written `\/`, control characters as `\u00xx`, no trailing newline, dates as JSON numbers of seconds since 1970 (fraction kept). Go `wire.Marshal` is the twin of the Kit's `RelayCoder` (fixture `hub_contract_cases.json` `encoding`). Clipped text ends in `…` and sets `<field>_clipped: true`; a clipped list sets `<list>_more` (count of what was left out); an unclipped field has no flag key.

### 6.2 Kinds

Record name `<kind>-<id>` (`heartbeat` alone has no id). Every published record is a capped projection, never a row. Urgent kinds are diffed first in every cycle (`owner_ask`, `ask_alert`, `device_grant`, `permission_request`, then `session_chat`). With no phone linked only `device_grant` (and the heartbeat) is published.

| Kind | Id | Window and caps | Payload (Kit mirror; fixture) | Urgent | Go hub |
|---|---|---|---|---|---|
| `heartbeat` | — | one record; restamped every 15 min and at once when accounts or `sharing` change; the phone calls a hub offline after 35 min | `updated_at, app_version, hub_id, mac_name ≤ 60, flavor (default\|corp), last_publish_at?, last_relay_at?, relay_backlog, accounts[≤ 20]{kind, label ≤ 80, status}, enabled_at, owner_user, sharing (available\|none\|unavailable)` | — | yes |
| `device_grant` | device_id | §5.4; keybox class | `DeviceGrant` + keys; `hub_contract_cases.json` | yes | yes |
| `workbench` | workbench id | ≤ 100 by latest session activity | `Workbench`; `workbench/workbench.json` (incl. `automations ≤ 50`) | — | yes |
| `workbench_target` | target id | per workbench ≤ 2000 open + ≤ 500 archived within 90 days; `session_ids ≤ 20` | `WorkbenchTarget`; `workbench_target.json` | — | yes |
| `workbench_comment` | comment id | newest 200 per published target; `body` ≤ 4000 | `workbench_comment.json` | — | yes |
| `terminal_session` | session id | `claude` sessions: every live one + newest 50 per workbench | `TerminalSessionState`; `terminal_session.json` | — | yes |
| `owner_ask` | ask id | open asks + closed within 7 days, newest 50 per workbench; `title` 200, `summary`/`changes` 4000, `payload`/`answer` dropped over 64 KiB, `doc_snapshot` ≤ 256 KiB (`doc_clipped`, `doc_bytes`) | `OwnerAsk`; `owner_ask*.json` | yes | yes |
| `ask_alert` | alert key `ask-<id>`, `perm-<id>`, `stop-<session>-<ms>` | while away, 7 days after push; class `alert` + signal | `WorkAlertPayload` `{event, key, workbench_id, workbench_name ≤ 60, session_id?, ask_id?, request_id?, title, body ≤ 120, quick}` | yes | yes |
| `permission_request` | request id | pending rows of live sessions; `summary` ≤ 2000 | `{id, session_id, workbench_id, tool_name, summary, summary_clipped?, created_at}`; `permission_request.json` | yes | yes |
| `session_report` | session id | live or active within 7 days; lists capped, ≤ 128 KiB | `SessionReport`; `session_report.json` | — | not yet |
| `session_timeline` | session id | same window; ≤ 100 milestones, `text` ≤ 200 | `session_timeline.json` | — | yes |
| `session_chat` | `<session>` or `<session>-<agent>` | only while a phone watches (5 min after its last `session_chat_request`); 300 entries, text 4000, labels 200, 600 000 bytes | `SessionChat`; `session_chat*.json` (FEED-05) | yes | not yet |
| `calendar_event` | event id | local today − 1 day … now + 14 days, ≤ 500 | `CalendarEvent` (inline literal in `CalendarMirrorFixtureTests`) | — | not yet |
| `meeting_transcript` | transcript id | 30 days or in the calendar window, ≤ 200; body as sealed asset `segments.json` ≤ 20 MiB | `MeetingTranscript` (inline literal) | — | not yet |
| `recording_job` | upload id | until 7 days after it ended, ≤ 100 | `{id, status, percent?, transcript_id?, error? ≤ 300, updated_at}` | — | not yet |

The Kit's `SliceKind` also lists legacy kinds (`briefing`, `inbox_item`, `target`, `track`, `digest`, `digest_topic`, `person_card`, `situation`, `day_plan`, `day_plan_item`, `feature_state`, `stream_digest`, `slack_account`, `google_account`, `jira_account`) that no hub publishes today. The MDM `MobileSync = workbench_only` policy narrows the published kinds.

### 6.3 Cadence

Cadence is not a correctness contract, but the phone's battery and latency depend on it.

- **Swift hub (today):** full hash diff of every kind every 30 s; urgent kinds every 10 s; fast lane for urgent kinds (coalesced 1 s, ≥ 2 s between sends) from in-process table observation; the owner's own board write asks for its board kinds through the fast lane once.
- **Go hub (built in the publisher; RC §6):** a change marks its kinds dirty (nudge after every applied action, in-process notifications, a `PRAGMA data_version` poll for other processes); debounce **150 ms** trailing, **max wait 1 s**; full diff every **60 s** as a backstop; minimum spacing between sends **2 s on CloudKit** (each data save is a silent push), **150 ms on the relay**.

### 6.4 Deletion

A record missing from its kind's window is deleted from the data zone at the next diff of that kind (a deleted workbench drops its workbench, target and comment records). An `ask_alert` delete also deletes its signal. The phone removes the row from its replica; `data_seen` keeps the newest version per wire name, so a deleted record never comes back older. On rotation the hub republishes, it does not delete.

## 7. Actions (phone → hub)

### 7.1 The action payload and its echo

`ActionRequest` (both directions; Kit `ActionRequestPayload`, Go `wire.ActionRequest`):

| Key | Phone writes | Hub's echo |
|---|---|---|
| `id` | UUID | same |
| `kind` | §7.2 | same |
| `entity_id` | per kind, string, optional | same |
| `params` | object | same |
| `created_at` | phone clock | same |
| `status` | `pending` | §7.3 |
| `device_id`, `hub_id` | the sender and the addressed hub | same |
| `action_seq` | ordered path only (§7.5) | same |
| `reason`, `error_message`, `result` | — | §7.3 |

The echo overwrites the action record at the same name, sealed `relayToPhone` to the authenticated sender.

### 7.2 Kinds

Age window: 7 days after `created_at`, 24 h for the session-request kinds (marked 24 h). A `created_at` more than 5 min ahead of the hub's clock is `expired` with "Your iPhone's and Mac's clocks differ by more than 5 minutes — check Date & Time on both." Non-idempotent kinds (NI) are claimed `begun` before the handler, so a crash mid-apply answers `failed`/`outcome_unknown` and never applies twice. Kinds marked R get a non-final `received` echo before work.

| Kind | Entity | Params | Grant | Flags | Kind-specific reasons | Go hub |
|---|---|---|---|---|---|---|
| `probe` | — | `{nonce?}` | — | | applied `{nonce, hub_id}`; Swift: no nonce → `invalid_params` | yes |
| `ask_answer` | ask id | `{workbench_id, answer: {verdict, answers, checklist, comments, note}}` | — | | `not_found`, `ask_not_open`, `invalid_answer`, `conflict`, `cannot_type`; applied `result.delivery` ∈ `submitted\|typed\|held\|queued\|copied\|no_session\|automation` | yes |
| `board_target_status` | target id | `{workbench_id, status, from_status}` | — | | `not_found`, `not_on_board`, `conflict` | yes |
| `board_target_priority` | target id | `{workbench_id, priority, from_priority}` | — | | as above | yes |
| `board_comment_add` | target id | `{workbench_id, body ≤ 4000}` | — | NI | as above | yes |
| `board_comment_reply` | root comment id | `{workbench_id, body ≤ 4000}` | — | NI | as above | yes |
| `board_target_create` | — | `{workbench_id, parent_id?, text ≤ 200, intent ≤ 4000, priority}` | — | NI, R | as above | yes |
| `session_start` | target id, or none (an untargeted session: `brief` required, `mode` `new`) | `{workbench_id, mode: new\|open_existing, plan_first, bring_forward, brief?}` | start (`brief` only with typing; untargeted needs typing) | NI, R, 24 h | `device_not_allowed`, `not_found`, `not_on_board`, `conflict`, `claude_not_found`, `codex_not_found` | not yet |
| `session_input` | session id | `{text}` 1–4000 after `SessionInputText.normalize` | typing | NI, R, 24 h | `device_not_allowed`, `not_found`, `session_not_running`, `cannot_type`; held: `agent_busy`, `needs_approval`, `prompt_has_text`, `state_unknown`; applied `{delivery: submitted\|typed, while_busy?}` | not yet |
| `session_input_cancel` | original action id | `{}` | sender only | | `device_not_allowed`; original echoed `cancelled` | not yet |
| `session_finish_request` | session id | `{}` | typing | NI, 24 h | as `session_input` | not yet |
| `session_stop` | session id | `{}` | — | | `not_found`; idempotent (a session not live is `applied` with no signal) | not yet |
| `session_report_request` | session id | `{}` | — | | `not_found`; applied `{}` | yes |
| `session_chat_request` | session id | `{session_id?, subagent_id?, tool_use_id?}` (subagent ids together) | — | 24 h | `not_found`, `invalid_params` | yes |
| `permission_answer` | session id | `{request_id, behavior: allow\|deny}` | permissions | NI | `device_not_allowed`, `not_found`, `not_pending`, `answer_on_mac`, `session_not_running`; applied `{status: allowed\|denied}` | yes |
| `session_interrupt` | session id | `{}` | typing | NI | `device_not_allowed`, `not_found`, `session_not_running`, `not_working`, `expired` (> 120 s) | yes |
| `automation_run` | automation id | `{workbench_id, confirmed}` | start | NI, 24 h | `device_not_allowed`, `not_found`, `not_on_board`, `conflict`; applied `{run_id, coalesced}` | yes |
| `target_done`, `target_snooze`, `task_create` | | | | | always `unsupported_in_poc` | yes |
| any other kind, or a kind with no handler | | | | | `unsupported_in_poc` | yes |

**Held deliveries.**
- An `ask_answer` stored with `delivery: held` waits for its session and is typed **at most once**: after a hub crash in the middle of its delivery it is not retried and may never reach the session. The answer itself is stored, so the agent still reads it through `get_ask` and the session brief (plan 1b ruling).
- A held recording upload expires after 7 days with the final `failed`/`expired`, and is failed `not_supported` when the owner turns recording off (§7.7, Proposed).

The Kit still lists the pre-POC Today kinds (`inbox_*`, `situation_*`, `day_plan_item_*`, `track_read`, `digest_read`, `stream_digest_read`); no hub registers them.

### 7.3 Statuses and reasons

| `status` | Final | Meaning |
|---|---|---|
| `pending` | — | written by the phone; an unknown status decodes as `pending` on the phone |
| `received` | no | the hub took it (kinds marked R; also a recording upload's final answer, §7.7) |
| `held` | no | without `reason`: arrived ahead of a gap (§7.5). With `reason`: a session line waiting (§7.8) |
| `applied` | yes | done; `result` per kind |
| `failed` | yes | `reason` is the class, `error_message` an owner-facing sentence when there is one |
| `expired` | yes | past its age window or the clock-skew bound (`reason: expired`) |
| `cancelled` | yes | a held line the phone cancelled |

Generic `reason` values (Kit `ActionReason`): `device_not_linked`, `device_not_allowed`, `wrong_hub`, `invalid_params`, `not_found`, `write_failed` (a handler threw or answered nothing usable), `outcome_unknown` ("The Mac restarted while applying this"), `unsupported_in_poc`, `expired`, `cancelled`. A reason the phone does not know decodes as no reason; the phone then shows the message or a generic failure.

### 7.4 The legacy (unordered) path — today

Every phone today, against either hub, and any phone whose hub's `device_grant` lacks `ordered_actions`:
- Record `action-<id>`; the outbox keeps the sealed envelope and resends it unchanged until a final echo arrives.
- The hub applies in the order read, with no hold, exactly once through its ledger (`relay_processed`, `begun`/`done`, keyed by the plain name), and echoes `received` then a final status. A record the ledger holds as done is echoed again with the stored outcome, never applied again — only to the phone that sent it.
- The phone does not delete echoes; hub hygiene removes action and upload records older than 7 days (CloudKit).

### 7.5 The ordered path (Go hub built; phone Proposed)

RC §5 and relay sim rules 1–7a, 15. Same handlers and outcomes as §7.2; only when and how often an action is applied changes.

1. **Negotiation.** The hub announces `ordered_actions: 1` in `device_grant`. A phone uses the ordered path only for a hub that announces it; a hub runs a phone ordered from that phone's first action carrying `action_seq` and keeps a payload without it on the legacy path. Actions sent the old way settle the old way.
2. **Counter.** Per phone per hub, a persisted gapless `action_seq` (u64 from 1, drawn when an action enters the outbox, never reset while the link lives, continues across epochs). It travels inside the sealed payload; the envelope `seq` stays the rollback counter.
3. **Record name.** Plain `a-<DEVICE_ID>-<action_seq>` (`DEVICE_ID` uppercase), wire `RecordName(K_meta, relay, "a", "<DEVICE_ID>-<action_seq>")`. Deterministic, so a resend overwrites the same record. The hub drops a record whose `action_seq` is 0 or whose frame name differs.
4. **Outbox.** The phone writes queued actions in order with `expect: absent`, stops at the first failure and resumes next pass; a conflict resolves per sim rule 3.
5. **Order.** The hub keeps `last_applied_action_seq` per phone. `last + 1` is applied, then any held actions that now follow; `≤ last` is a repeat (echoed again with the stored final outcome, never dispatched); `> last + 1` is held (echo `held`, no reason) and `resend_from(last + 1)` is written once per gap. Each pass applies or holds at most 200 actions.
6. **Echo.** Every action record read gets an echo by overwrite with `expect: seq`. On a final echo the phone settles its outbox row and deletes the echo (`expect: seq`).
7. **Skip.** A phone asked to resend from a seq it no longer has writes `skip_to(m)`; the hub moves `last` to `m − 1` when that moves it forward and applies what now follows. The hub drops a `skip_to` without `device_id` and `hub_id`, or with `m > last + 1 + 65536`. The phone must surface each missing action to the owner as not delivered and may offer to send it again as a new action at the end of the queue; nothing is dropped silently (UI: relay client spec).
8. **Re-link** restarts the order at 1 and forgets held actions and marks; the ledger key of an ordered action is scoped to the link.
9. **Accepted cost** (ask #796): on CloudKit a gap delays every later action of that phone until the missing one is resent.

### 7.6 Control records

Plain name `c-<uuid>`, frame kind `control`, sealed like an action in the sender's direction; written with `expect: absent`; the recipient deletes what it read (sim rule 15). Each side keeps a durable per-mailbox queue retried every pass (sim rule 7a). Body `wire.Control` = `{id, kind, device_id, hub_id, …}`:

| `kind` | Direction | Fields | Status |
|---|---|---|---|
| `resend_from` | hub → phone | `seq` | Go hub writes |
| `skip_to` | phone → hub | `seq` | Go hub reads; phone Proposed |
| `epoch_ack` | phone → hub | `epoch` (newest hub epoch the phone holds; never lowered) | Go hub records it; retirement Proposed (sim rule 14) |
| `transport_switch` | phone → hub | `target` (`relay`\|`cloudkit`), `reason?` | Go hub answers `transport_switch_rejected` "not supported yet" until the switch is built |
| `transport_switched` | hub → phone | `target, epoch, by, at, keybox` (the new epoch's keybox) | Proposed |
| `transport_switch_rejected` | hub → phone | `reason`, `retry_after_s` | Go hub writes |
| `hub_on_relay` | hub → free phone | none | Proposed |

**Switch notice in the transport being left** (ask #843, Proposed; closes open point 6). On every accepted switch, in both directions, before it stops publishing there, the hub writes into the transport it leaves, sealed in the old epoch: the `transport_switched` control to every phone's mailbox there, whatever action path the phone is on, and the transport marker (plain kind `transport`, id `marker`, the latest `transport_switched` minus `keybox` and `device_id`) into that transport's data zone (`DataZone-<hub_id>` or `data/<hub>`), never swept by hygiene. A phone reads mailbox controls and the data-zone marker independently of the ordered path; on `target: relay` without a subscription it acts as on `hub_on_relay`. No existing record of today's Kit can carry this: `WorkAlertPayload.Event` is a closed enum and `owner_ask` would show a false event, and `device_grant`/`heartbeat` describe the link, not a move. A phone whose Kit predates control records reads it after its next update.

### 7.7 Recording uploads

Not an action: record `recupload-<upload id>`, kind `recording_upload`, no order and no handler table, its own ledger. Payload `{id, started_at, ended_at, duration_sec, title_hint?, sample_format, status, error_message?, event_id?, device_id?, hub_id?}`, the audio as a sealed asset (§4.4). No age window; a retry reuses the same name and bytes. The hub rewrites the record without the asset: `received`, or `failed` with an owner-facing `error_message` — the upload echo has **no `reason` key** (the class stays in the hub's ledger). The phone deletes its plain audio and ciphertext only on `received`; a `failed` echo keeps both. Progress then arrives as the `recording_job` slice.

Go hub, **built today** (`internal/hub/actions/handlers/recording.go`): a host that has never had a Desktop transcriber heartbeat answers the final `failed` "This host can't transcribe recordings. Your recording stays on your phone." (ledger `not_supported`); a host whose Desktop heartbeat is stale answers `held` "Your Mac's transcriber isn't running. The recording waits on your phone." and retries each pass (in memory, no expiry); a fresh heartbeat lets the upload be opened and answered `received`. Today's Kit decodes `held` as `pending` and keeps waiting.

Go hub, **Proposed** (§9):
- The owner's recording switch replaces the never-had-Desktop rule: switch `off` → final `failed`/`not_supported`; switch `on` → the Desktop heartbeat decides only `received` (fresh) vs `held` (stale).
- A held upload gets the final `failed`/`expired` 7 days after it was first held; turning the switch `off` fails every held upload with `not_supported`. Either way the phone keeps its audio.
- These change together:
  - the Go intake (`internal/hub/actions/handlers/recording.go` and the hold in `internal/hub/actions/recording.go`);
  - the heartbeat slice (`internal/hub/slices/heartbeat.go`, `capabilities`);
  - the `watchtower hub recordings` verb;
  - the sidecar: `hub_meta` keys `desktop_seen_at` and the switch value (`internal/hub/state`). `hub_meta` is a key-value table, so no schema change and no goose migration — only the one-time `desktop_seen` → `desktop_seen_at` carry-over (§9);
  - the Kit (`WatchtowerKit`): `HeartbeatPayload` decodes `capabilities.recordings`, `RecordingUploadPayload` decodes the echo's `reason`, `ActionReason` gains `not_supported`;
  - the shared fixture: a `heartbeat` section in `WatchtowerKit/Tests/Fixtures/link/hub_contract_cases.json` (capabilities on, off, absent, unknown value; an upload echo with `reason`), read by Kit `HubContractFixtureTests` and Go `TestHubContractFixture`.

### 7.8 Action flows

Ordered round trip with a gap:

```
Phone outbox                         Mailbox                              Hub
  | a-DEV-7 (seq 7) expect absent ---->|                                    |
  | a-DEV-8 (seq 8) expect absent ---->|                                    |
  |                                    |--- reads 8 first ----------------->| last = 6: hold 8
  |<--- echo a-DEV-8 {held} -----------|<-- overwrite expect seq -----------| (no reason)
  |<--- c-<uuid> resend_from(7) -------|<-- once per gap -------------------|
  | resend a-DEV-7, same bytes ------->|                                    |
  |                                    |--- reads 7 ----------------------->| apply 7, then held 8
  |<--- echo a-DEV-7 {applied} --------|<-----------------------------------| last = 8
  |<--- echo a-DEV-8 {applied} --------|<-----------------------------------|
  | settle rows; delete echoes         |                                    |
  |   (expect seq) ------------------->|                                    |
  | delete c-<uuid> ------------------>|                                    |
```

Held line (`session_input`, Swift hub today):

```
Phone                                Mailbox                              Hub                         Session
  | session_input {text} ------------->|------------------------------------>| gates: typing, live         |
  |<-- echo {received} ----------------|<------------------------------------|                             |
  |                                    |                                     | prompt holds owner's draft  |
  |<-- echo {held, prompt_has_text} ---|<------------------------------------| keep line (sidecar)         |
  |   (optional) session_input_cancel ->|----------------------------------->| drop line, echo original    |
  |                                    |                                     |   {cancelled}               |
  |                                    |                                     | state read: idle, no draft  |
  |                                    |                                     |-- paste, re-check, Return ->|
  |<-- echo {applied, delivery:        |<------------------------------------| (late echo replaces ledger)|
  |      submitted}                    |                                     |                             |
```

A hub restart re-queues held lines: one being typed becomes `outcome_unknown`, an expired one `expired`, one whose session ended `session_not_running`.

### 7.9 Hygiene

CloudKit: the hub deletes action and upload records older than 7 days once a day (an unhandled pending one waits for its `expired` echo) and anything that opened under no key, aged by the server's modification date; the ledger keeps rows one day past the window. Hosted relay: recipients delete what they read, and the server's 14-day mailbox TTL is the fallback; the hub scans nothing there.

## 8. Errors and versioning

- **Unknown fields are ignored** on both sides (Kit `Codable` without strict decoding; Go `encoding/json`). Pinned for `device_grant` by `hub_contract_cases.json` `unknown_future_key` and `old_hub_no_new_fields`.
- **Unknown enum values:** an unknown action `status` reads `pending` on the phone; an unknown `reason` reads as none; an unknown upload status reads `pending`. An unknown action `kind` at the hub is `failed`/`unsupported_in_poc`. An unknown slice kind is stored on the phone but never indexed (invisible). An unknown relay frame kind (e.g. `control` at today's Kit or Swift hub) does not open and is dropped.
- **Version fields:** envelope `ver` (1) and `suite` (1); inner frame `inner_ver` (1); link code `v` (3 Swift, 4 Go); `ordered_actions` (1); the relay's `Relay-Protocol-Version: 1` header.
- **Newer side, older side:**
  - A newer envelope version or suite: the phone stores it unindexed and shows "Update Watchtower on this iPhone: your Mac uses a newer format."; the hub's strict parse drops it.
  - A newer link code: "newer version" on the phone; an older one: "older version".
  - New `device_grant` keys reach an old phone harmlessly. A new phone without `ordered_actions` from the hub stays on the legacy path. An old phone against the Go hub stays on the legacy path. The hosted relay requires both sides on the ordered path (RC §5 p. 10).
  - A slice field a phone needs and an older hub does not send is absent; mirrors decode it as optional.
- **Additive only.** A required key is never removed or retyped; a changed meaning is a new key. Optional booleans that default to false are written only when true (`permissions_allowed`, `permissions_requested`), so older peers' bytes stay as they were.
- **Frozen vectors** change only with the owner's approval (§10).

## 9. Capabilities (Proposed)

**Need.** The owner wants recording to be a plain on/off function of a hub (conversation 2026-10-31). A headless host cannot transcribe (the transcriber is Desktop's Swift ML stack), yet today's phone offers recording for every hub and only learns after the upload.

**Proposal.** The hub publishes a `capabilities` object in its **heartbeat**, starting with one key:

```json
"capabilities": {"recordings": "on"}
```

- **An owner switch, not a derived value.** `recordings` is the value of a switch on the hub: `watchtower hub recordings on|off`, stored in the sidecar's `hub_meta`. **Default** (decided by agent; owner confirms on this review): until the owner sets the switch, its value is `on` if the hub has ever seen a Desktop transcriber heartbeat, else `off`, so a Mac with Desktop keeps recording as today. Once set, the stored value wins. A change restamps the heartbeat at once (the existing facts check).
- **Where "ever seen" lives** (ask #833). The fact is persisted in the sidecar's `hub_meta`, never kept in memory only: key `desktop_seen_at` = the time of the first Desktop transcriber heartbeat (a timestamp, no content), written by the hub, the sidecar's single writer. Otherwise a Mac with Desktop would publish `off` after a hub restart until the next heartbeat, and the phone would stop offering recording. The key is never cleared automatically; turning recording off is the owner's switch. Today the Go hub stores `desktop_seen = "1"` and the last beat in `desktop_at` (`internal/hub/state/recordings.go`); `desktop_seen_at` replaces the flag, and a sidecar that has `desktop_seen = "1"` without it gets `desktop_seen_at` from `desktop_at` once. Required test: after a hub restart with no new heartbeat, the default is still `on` on a host that once had Desktop.
- **The verb.** `watchtower hub recordings on|off` is an owner verb, refused under an agent marker like the other hub write verbs. `on` is refused on a host that has never had a Desktop transcriber heartbeat, with "this host has no transcriber", so a headless host can never publish `on`.
- **Never derived from the Desktop heartbeat.** The Desktop transcriber heartbeat (`watchtower hub desktop heartbeat`; a running Go hub receives it over its control socket, being added in plan 1a Task 15's fix round) only decides, while the switch is `on`, whether an upload is `received` (Desktop fresh) or `held` (Desktop away, §7.7). A missing Desktop heartbeat can never turn the capability `off`.
- **Off.** With the switch `off`, every upload gets the final `failed` with reason `not_supported` ("This host can't transcribe recordings. Your recording stays on your phone."), and any upload held when the switch is turned off is failed the same way. The phone keeps its audio.
- **The phone's contract.** It must not offer recording for a hub whose heartbeat says `"off"`, and it must surface a final `failed` of an upload to the owner. An absent `capabilities` (an older hub) means `on`. Unknown capability keys are ignored; an unknown value of a known key reads as "not off" (today's behaviour), so a newer hub never hides a feature from an older phone by accident; the hub's answer stays the authority.
- Phone UI and its mockups: relay client spec.

**Why the heartbeat, not `device_grant`.** Recording is a fact about the host, the same for every phone; the heartbeat is the hub's one self-description record (name, flavor, accounts, sharing), already republished at once when its facts change, and read by every linked phone. `device_grant` is per phone and carries this link's grants and keys: putting host facts there means re-sealing an HPKE keybox per phone for each change, up to 20 records. `transports` sits in `device_grant` because the phone needs it while linking, before it holds `K_data`; recording matters only after the link, when the heartbeat is readable.

**Old and new sides.**

| Phone \ Hub | Swift hub (no `capabilities`) | Go hub, switch `on` | Go hub, switch `off` |
|---|---|---|---|
| Today's phone | offers recording, works (as today) | key ignored, works | key ignored, offers recording; upload `failed` with the message (no `reason` it can read), audio kept |
| New phone | absent = on: offers recording | offers recording | does not offer recording; a stray upload is surfaced as `failed`/`not_supported` |

**The upload echo's `reason` (Proposed, same change).** The upload echo gains an optional `reason` (`not_supported`, `expired`, `not_found`, …), and the Kit's `ActionReason` gains `not_supported`. Without it the phone cannot tell "this host does not record" from a retryable failure except by parsing text, which the owner's "let it get `not_supported`" requires. An old phone ignores the key and shows `error_message`, as today; an old hub (Swift) sends no `reason`, and a new phone then treats the failure as generic. Pinned by a new `heartbeat` section in `hub_contract_cases.json` (on, off, absent, unknown value) and upload-echo cases.

## 10. Fixtures and tests that pin the contract

| Fixture | Read by | Guards |
|---|---|---|
| `WatchtowerKit/Tests/Fixtures/link/hub_contract_cases.json` (`device_grant`, `link_payload`, `encoding`) | Kit `HubContractFixtureTests`; Go `internal/hub/wire` `TestHubContractFixture`, `TestParseLinkURL_Refusals` | §5.1, §5.4, §6.1, §8 (ignore unknown keys; today's phone refuses v4) |
| `WatchtowerKit/Tests/Fixtures/e2e/{kdf,envelope,asset,padding,hpke-envelope,hpke-rfc9180-a21}.json`, regenerated only by `make e2e-vectors` (`WT_E2E_REGENERATE=1`) | Kit `E2EKeyDerivationTests`, `EnvelopeTests`, `ChunkedAssetCipherTests`, `E2EPaddingVectorTests`, `HPKEEnvelopeVectorTests`, `HPKEVectorTests`; Go `internal/hub/secure` `TestKitVectors_KDF/_Padding/_Asset/_Envelope` | §4.2–§4.5, §5.3 (relay keys, record names, device id, SAS v2, link-code tag, padding, asset frames, envelope header and body bytes; randomized signatures and HPKE verified/opened) |
| `internal/hub/secure/testdata/go-sealed.json` (written by `go test ./internal/hub/secure -run TestWriteGoSealed -update`) | Kit `GoSealedEnvelopeTests` | §4.3 the other direction: Go-sealed `data`, `alert`, `keybox`, `relayToPhone` open in the Kit |
| `internal/hub/identity/testdata/swift-keyring.json` | Desktop `HubKeyringVectorTests` (writes); Go `TestKeyring_OpensSwiftSealedKeys`, `TestKeyring_SealsWhatSwiftFormatReads` | §4.9 hub keys at rest, so an adopted hub keeps every link |
| `WatchtowerKit/Tests/Fixtures/permissions/allow_block_cases.json` | Kit `PermissionAllowRuleTests`; Go `TestAllowBlockSharedCases` | §7.2 `permission_answer` → `answer_on_mac` (PROJ-21) |
| `WatchtowerKit/Tests/Fixtures/workbench/*.json` | Kit `WorkbenchMirrorFixtureTests`, `OwnerAskDecodingTests`, `WorkbenchTargetTests`; Desktop slice tests; Go `slices/sources` tests (keys and literal types) | §6.2 workbench kinds' payload shape |
| `WatchtowerKit/Tests/Fixtures/asks/anchor-fixtures.json` | Kit `CommentAnchorBuilderTests`; Desktop `CommentAnchorFixtures` | review-comment anchors inside `ask_answer` |
| Inline literals in Kit `CalendarMirrorFixtureTests` | Desktop `CalendarEventSliceTests`, `MeetingTranscriptSliceTests`, `RecordingJobSliceTests` | §6.2 calendar, transcript, recording job |
| Kit `SessionInputTextTests` | Kit; the Swift hub calls the same `SessionInputText` | §7.2 `session_input` text rule (PROJ-16). No shared fixture yet: the Go handler is not ported |
| Go `internal/hub/actions` tests (`processor_test`, `control_test`, `legacy_test`, `sim_test`) | Go | §7.4–§7.6 against relay sim rules |

## 11. Proposed changes in one list

1. Kit reads `LinkPayload` v4 and sends `DeviceHello.relay_device_id` (RC §8) — so a phone can link a Go hub at all.
2. Phone ordered path: `action_seq`, `a-` names, outbox states, echo deletes, `skip_to`, surfacing undelivered actions, `epoch_ack` (RC §5) — the Go hub already runs its half.
3. Hosted relay transport on the phone (RC §7) and `vouch_hub` on the relay and phone (relay ask #805).
4. Transport switch: `transport_switched`, `hub_on_relay`, old-epoch retention (sim rules 8–16).
5. Relay alerts: `send_alert` with the envelope opened under `alert-push` (RC §10).
6. Conditional mailbox writes on CloudKit through the bridge (RC §3, Go hub design §6.2).
7. Headless pairing in the terminal (`watchtower hub pair`).
8. The owner's recording switch published as `capabilities.recordings` in the heartbeat, the upload echo's `reason`, `ActionReason.not_supported`, and the held-upload expiry (§7.7, §9).
9. The Go hub's remaining kinds: `device` records, the session start/stop/input handlers, `session_report`, `session_chat`, `calendar_event`, `meeting_transcript`, `recording_job` sources.
10. A shared hello case (`relay_device_id`) in `hub_contract_cases.json` (RC: Phase 3).

## Decisions

- One phone ↔ hub contract for both hubs and both transports; a change changes both sides and the shared fixture together — Go hub design §12a (existing code: `hub_contract_cases.json`).
- Everything leaves the hub sealed; no plaintext fallback, CloudKit `encryptedValues` is only the outer layer — mobile E2E spec, existing code.
- Envelope, record names, keybox, hello, SAS v2 and padding bytes are frozen and change only with owner approval — existing code (`make e2e-vectors`); SAS v2 regenerated once, ask #97.
- Starting sessions needs the owner's grant together with typing; the phone's toggle is only its opt-out — ask #305 (#565).
- Answering an ask from the phone is not gated by typing — existing code (owner decision 2026-10-14).
- Permission answers need their own grant, never implied by typing; allows on shortened or settings-touching requests are refused — ask #268, ask #312.
- Automation runs use the start-sessions grant, run only — ask #692.
- Plain audio stays on the phone until the hub confirms receipt — ask #89.
- Shared-scope phones post work alerts locally — ask #622.
- One ordered action path on both transports, `action_seq` inside the sealed payload — RC Decisions, conversation on ask #795.
- On CloudKit a gap delays later actions of that phone until resent — ask #796.
- Publishing on change, ~2 s spacing on CloudKit, 150 ms on the relay — ask #735; battery rule from board #724.
- Hubs are admitted to the relay by a paying phone's vouch, not by App Attest — asks #800, #801.
- The phone states its own `relay_device_id` inside the hello — Go hub design §12a (existing code in `internal/hub/link`).
- A headless hub runs relay-only and offers no recording — Go hub design §3, §7.3.
- Recording intake: with the owner's switch `off` an upload is `failed`/`not_supported`; with it `on` the Desktop heartbeat decides only `received` vs `held` — conversation 2026-10-31 (replaces the built never-had-Desktop rule of Go hub design §8 p. 4a; Proposed).
- The switch defaults to `on` when the hub has ever seen a Desktop transcriber heartbeat, else `off`; a stored value wins; `on` is refused on a host with no transcriber; owner verb, refused under an agent marker — decided by agent; owner confirms on this review (ask #832).
- Capabilities live in the heartbeat; unknown values read as not off — conversation (this document, Proposed).
- Recording is an owner on/off switch published in the heartbeat — conversation 2026-10-31, supersedes ask #827 N7 (owner confirms on this review).
- Owner verbs go through `watchtower hub …` (a thin CLI later) — ask #827.
- A held ask answer is delivered at most once; after a crash mid-delivery it stays readable via `get_ask` and the brief — plan 1b ruling.
- A held upload expires after 7 days with `failed`/`expired`, the phone keeping its audio — decided by agent; owner confirms on this review (ask #832).
- Phone UI and mockups are out of this document; they belong to the relay client spec — decided by agent; owner confirms on this review (ask #832).
- On every transport switch, both directions, the hub writes a sealed switch notice (`transport_switched` to each phone's mailbox plus the transport marker in the data zone) into the transport it is leaving, before it stops publishing there; a phone reads them independently of the ordered path. This closes open point 6 — owner, ask #843.
- Old-epoch keys are kept 7 days for every rotation, transport-switch epochs included; sim rule 14's 14 days is not used. A phone away longer gets `resend_from` for its old-epoch actions and reseals them with the same `action_seq` — owner, ask #843.

## Open points

1. **Order key.** The relay design §4 says the hub orders a phone's actions by the envelope's `(epoch, seq)`; RC §5 and the Go hub use `action_seq` inside the payload (the envelope `seq` has holes). The relay design text should be aligned.
2. **Record-name shorthand.** Go hub design §12a writes `a-<action_seq>`; the code and RC §5 p. 2 name `a-<DEVICE_ID>-<action_seq>` (HMAC id `<DEVICE_ID>-<action_seq>`). Same wire bytes; the shorthand should be corrected.
3. **Old-epoch resend bytes.** Relay design §4.2 p. 6: an old-epoch action the hub can no longer open is answered `resend_from` and the phone reseals it under the new epoch with the same `seq` — not the same bytes, while RC §5 / sim rule 13 and the Kit's outbox say resends are byte-for-byte. Which rule wins after a switch is not written down.
4. **Late echo on the ordered path.** The Go hub moves `last_applied_action_seq` on any handler answer, including a non-final `held` session line; the later final echo of that line (Swift `lateEcho`) has no ordered-path rule yet (it is outside the order, at the same name). Needed before `session_input` is ported.
5. **Mac attestation.** The relay's client requirements (§1, §3, §9) still say every device attests with App Attest and a Mac without it stays on CloudKit; asks #800/#801 replaced that with vouching. The relay repo's document is not updated, and the relay has no `vouch_hub` yet (relay ask #805).
6. ~~**`hub_on_relay` carrier.**~~ **Resolved (ask #843):** the switch notice in the transport being left (§7.6) reaches every phone whose Kit decodes control records, a phone on the legacy action path included (today's App Store build reads it after its next update). Relay design §4.2 p. 3 says the hub "publishes `hub_on_relay` in CloudKit"; RC §5 and Go `wire.Control` make it a control record in the free phone's mailbox. A control record needs the ordered path on that phone; a free phone on the legacy path would not read it.
7. **Hub count.** The phone links up to 4 hubs (`HubRegistry.limit`); a relay subscription holds 3 hub slots. What the phone shows for a 4th hub on the relay is not specified.
8. **`probe` without a nonce.** The Swift hub answers `failed`/`invalid_params`, the Go hub `applied`. Harmless (today's phone always sends one) but a divergence.
9. **`not_supported` on the wire.** The Go hub's `failed(not_supported)` exists only in its ledger: the upload echo has no `reason`, and the Kit's `ActionReason` has no `not_supported`. §9 proposes adding both (kept as Proposed after review).
10. **Shared hello fixture.** Go hub design §12a says the hello's `relay_device_id` is pinned by the shared fixture; `hub_contract_cases.json` has no hello section yet (RC: Phase 3).
