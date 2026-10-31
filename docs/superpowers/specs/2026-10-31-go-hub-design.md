# Go hub — one phone hub for the Mac and a Raspberry Pi, over the relay and CloudKit

**Status:** draft · **Date:** 2026-10-31 · **Owner decisions:** asks #709, #711, #713, #800, #801, #802
**Adapts:** [relay client design](2026-10-29-relay-client-design.md) (branch `feature/relay-client`, approved in ask #799; below: "relay client spec"). That spec's **hub half moves here and is implemented in Go**; its phone and Kit half stays there unchanged (§2).
**Server contract:** `aiwatchtowers/relay` — [relay spec](https://github.com/aiwatchtowers/relay/blob/main/docs/superpowers/specs/2026-10-28-relay-design.md), the Cloudflare design, the App Attest design, `proto/relay/v1/relay.proto`, `proto/README.md`, `sim/README.md` ("sim rule N"), `docs/watchtower-client-requirements.md`.
**E2E format:** [mobile E2E research](2026-10-12-mobile-e2e-encryption-research.md) and the Kit's `WatchtowerSync/Secure`.

## 1. Intent

The owner wants to run Watchtower on a Raspberry Pi at home and keep workbenches there — Claude Code sessions in the Pi's folders — driven from the iPhone, the same way the phone drives the Mac's sessions today. The Pi has no screen and is not reachable from the internet.

Today the phone hub (slices, the action mailbox, E2E, linking) lives in the Desktop app's Swift code and talks only CloudKit; sessions are created only by Desktop. Neither exists on Linux. The owner's choice (ask #713) is **one Go hub inside the daemon, built for darwin and linux** — not a second implementation for the Pi — and to move the Mac to it at the same time (ask #800). Since the relay client work was about to put the relay's hub side into the Swift hub, that hub side is written directly in Go instead (ask #802).

Side effects the owner gets on the Mac: the hub no longer dies with the Desktop app (today "a quit or crashed Desktop pushes nothing", workbench-remote spec §5.1), and the relay's publishing-on-change is natural in the process that already sees most writes.

## 2. Split with the relay client spec

| Relay client spec | Here (Go hub) | Stays there (phone, Kit) |
|---|---|---|
| §3 seam | hub-side neutral seam in Go (§5) | Kit seam for the phone: `RecordOrigin`, `HubRoute`, `LinkAccess`, `PushWake`, `LiveTransport`, factories |
| §4 identity | hub `relay_auth` + vouching (§7) | phone `relay_auth`, App Attest on the phone |
| §5 actions | hub order, holds, `resend_from`, echoes, control queue, hygiene, `ordered_actions` in `device_grant` (§8) | phone outbox, `action_seq`, `skip_to`, Not delivered |
| §6 publishing on change | all of it, in Go (§9) | — |
| §7 hosted relay transport | Go transport over the relay's Go client (§6) | `HostedRelayClient`/`HostedRelayTransport` in the Kit |
| §8 linking | hub side, plus headless linking on the Pi (§10) | phone side, `LinkPayload` v4 reading |
| §9 switch, subscription | hub side of sim rules 8–16, epochs | phone switch UI, StoreKit, `SUBSCRIPTION_MOVED` |
| §10 pushes, Desktop, measurements | `send_alert`, Desktop Settings → Mobile over the daemon, hub-side samples | `register_push`, NSE, phone Diagnostics |

Everything the relay client spec decided for the hub (Decisions list there: one action path for both transports, conditional mailbox writes on CloudKit, `action_seq` inside the payload, 150 ms / ~2 s spacing, `data_version` poll, epochs per switch, 90-day epochs at launch, keyboxes inside `transport_switched`) holds here unchanged — only the language and process change. Section numbers below cite it as "RC §N".

## 3. Goals, non-goals, anti-goals

**Goals**
1. One Go hub (`internal/hub/…`) in the daemon, built for `darwin/arm64`, `darwin/amd64`, `linux/arm64` (and `linux/amd64` because CI is there). It replaces the Swift hub in `WatchtowerDesktop/Sources/Services/MobileHub/` entirely; that code is deleted in the release that ships the Go hub.
2. The Go hub speaks both transports through one hub logic: the hosted relay (both platforms) and CloudKit (Mac only, through a Swift bridge, §6.2). Free Mac users keep CloudKit with today's crypto, zones, shares and pairing.
3. A Raspberry Pi runs the CLI, the daemon and `session-host`, holds workbenches, and is a hub on the relay: the phone sees it as one more Mac in its hub switcher (multi-hub F2), starts and stops sessions there, reads the workchat, answers asks and permission requests, types lines, moves board cards.
4. Sessions are created in Go: one start path (`watchtower workbench session start …`) used by the phone handler on both platforms and by Desktop's **New Session** on the Mac (§11).
5. Every existing link survives the upgrade: no phone re-pairs because the hub changed language (§12).
6. Byte compatibility with the Kit: envelopes, wire names, AAD, keyboxes, HPKE hello, SAS, padding, chunked assets — pinned by vectors generated from the Kit (§13).

**Non-goals**
- A Desktop UI on the Pi or for the Pi's workbenches on the Mac. The Pi is driven from the phone and its terminal.
- Slack, Gmail, Jira, meetings, digests, Knowledge and other pipelines on the Pi. They are features with their own switches; on the Pi only Workbench is on by default (onboarding is not run there). Whatever the owner turns on later works if it is portable; making each one portable is not this project.
- Phone recordings and transcription on the Pi (the transcriber is the Desktop's ML stack). A Pi hub does not offer recording; the phone hides it for that hub.
- The phone and Kit work of the relay client spec (§2).
- A self-hosted relay, a LAN/direct transport, Tailscale.
- Key rotation with ephemeral X25519 (RC §1: after launch, Phase 5 there).

**Anti-goals (failure even if it works)**
- Any phone has to pair again after the upgrade.
- The Swift hub and the Go hub ever run against the same state at once (double apply, double publish, two relay sockets for one device identity).
- A Pi that opens an inbound port or needs a router change.
- Plaintext of slices, actions or alerts anywhere it is not today: on the relay, in iCloud, in logs (FILES-01), in a bridge socket on disk.
- A phone line landing in the wrong place: PROJ-16 and PROJ-21 guard tests move with the code and pass unchanged in meaning (§8.4).
- The Mac's behaviour for a free CloudKit user gets worse: slower, more battery, lost features. The changes they see are only the ones RC §1 already accepted (order of actions, publish on change).

## 4. Shape

```
iPhone ─E2E─▶ hosted relay (Cloudflare) ◀─E2E, outbound WSS─ watchtower daemon (Go hub)  ─ Raspberry Pi (linux/arm64)
   │                                    ◀─E2E, outbound WSS─ watchtower daemon (Go hub)  ─ Mac
   └─E2E─▶ CloudKit ◀── WatchtowerCloudBridge (Swift, Mac only) ◀─ local socket ─┘
```

- The hub runs inside the daemon process (`runSyncDaemon`) as its own long-lived component with its own goroutines, independent of the sync cycle: a slow cycle never delays a mailbox pass or a publish. It starts when the daemon starts and mobile sync is enabled (`mobileSyncEnabled` moves from Desktop defaults to config, §12), and respects the MDM `MobileSync` key (POLICY: hub off / workbench_only) exactly as today.
- One process per device identity (sim, "one process per device identity"): a pidfile-style lock on the hub's state dir; a second daemon refuses to start its hub.
- Desktop on the Mac becomes a client of the hub: Settings → Mobile, linking sheet, phone list and diagnostics read hub state and call `watchtower hub …` (§10), the way other screens use the CLI with pinned `--json` keys.

## 5. Hub-side seam in Go

The Swift hub's layers map one-to-one; the Go names are the builder's, the boundaries are not:

- **Transport** (`hub/transport`): `Save`, `Delete`, `Changes` + optional capabilities as RC §3 — `Conditional` (`expect: none | absent | seq`, outcomes saved / conflict / refused), `Mailboxes` (one mailbox per phone), `Paged`, `Live` (events). Two implementations: `relay` and `cloudkit` (bridge client), plus an in-memory fake with change tags for tests.
- **Secure** (`hub/secure`): the Go port of the Kit's hub-side `Secure/` — envelope seal/open, `InnerFrame`, `Padding`, `KeyDerivation` (zone bytes `data = 1`, `relay = 2`, never changed), wire names under `K_meta`, `RollbackGuard`, `SeqAllocator`, `ChunkedAssetCipher`, `EnvelopeSealer`, alert sealing. Only the hub's half is needed (no phone key provider).
- **State** (`hub/state`): the sidecar `hubstate.db` (devices, epochs, keybox state, `relay_processed`, contact, slice assets, `phone_recordings`) — same schema, now opened by Go (§12).
- **Publisher** (`hub/slices`): the slice builders and the diff/publish loop (§9).
- **Processor + dispatcher** (`hub/actions`): mailbox reading, order, echoes, control queue, handlers (§8).
- **Linking** (`hub/link`): QR payload, hello, SAS, keybox, phone grants, unlink.
- **Identity** (`hub/identity`): `hub_sig`, `hub_kx`, wrap key, `relay_auth` in a platform key store (§12.2).

## 6. Transports

### 6.1 Hosted relay

- The relay repository's Go client (`client/`) and generated proto (`gen/relay/v1`) are copied into `internal/hub/transport/relay/…` pinned to a relay commit with a `VERSION` file, the same rule as the Kit's copy (ask #734), with a `make relay-go RELAY=../relay` that refuses a dirty or unpinned source. Public Watchtower CI never needs the private repo.
- Behaviour is RC §7's list (login, ping, close codes, backoff, `UNAVAILABLE` retries, `TOKEN_EXPIRED` → zone resync, resubscribe and pull after reconnect), which the Go client already implements; the transport adds zones (`data/<hub relay_device_id>`, `relay/<hub>/<phone>`, `pair/<slot>`), per-zone change tokens in the sidecar, attachments through `create_upload`/`get_download`, and the error mapping of RC §7.
- The sim's `hub.go` and `relaytransport.go` are the reference model: the Go hub's processor is checked against the same scenarios (§13).
- The Pi needs only outbound HTTPS/WSS to the relay origin. Nothing listens.

### 6.2 CloudKit bridge (Mac only)

Apple offers CloudKit only through its frameworks; a Go process cannot write the owner's private database and shares. The bridge is a small signed Swift helper, **`WatchtowerCloudBridge.app`**, embedded in the Desktop bundle with the iCloud container entitlement:

- It wraps the Kit's existing `CloudKitTransport` (CKSyncEngine, `transport.db` state, shares, query subscriptions for `sig-` alert records) and exposes exactly the transport operations — save (incl. conditional), delete, changes, share/participant operations of `PhoneAccessService`, alert subscription — as length-prefixed protobuf frames over a Unix socket in the hub's state dir (0700 dir, 0600 socket, peer UID check).
- It carries only sealed envelopes and metadata — the same bytes it would hand CloudKit. It holds no hub keys and never opens an envelope.
- The daemon launches it on demand (CloudKit transport selected) and supervises it (restart with backoff, shut down when the hub moves to the relay or stops). It does not depend on Desktop running. Silent pushes to the Mac (today `TrayAppDelegate`) are received by the bridge and forwarded as a "pull now" event.
- The Pi never has it: a linux hub supports the relay only (§7.3).

## 7. Identity on the relay: vouched hubs

### 7.1 Rule (asks #800, #801)

Only phones attest with App Attest. **Every hub — Mac or Pi — is admitted because a paying, attested phone of the account vouches for its `relay_auth` key** when it links the hub. This replaces the App Attest design's "Mac: `app_attest` on register, assertion on every login" and removes its "Mac without App Attest support stays on CloudKit" consequence and its open item about Developer ID. Accepted consequence: "only our apps" means, for hubs, "only what a paying owner linked to their own subscription"; a home-built hub gets in only if the owner links it, and it takes one of the 3 slots.

### 7.2 Flow (needs a relay change, §15)

1. The hub creates its Ed25519 `relay_auth` (§12.2) and registers it with `device_kind = HUB` and an empty attestation: the server stores it as **unvouched** — it may only read and write a pairing slot opened for it (relay spec §3.1 already limits an unpaid Mac to that).
2. Linking (RC §8, §10 here) puts `relay_device_id` and `auth_pub` into the QR. The paying phone, after the SAS confirmation, sends `vouch_hub{hub_device_id, auth_pub}` with its own App Attest assertion over `SHA256("relay/v1/vouch" ‖ nonce ‖ hub_device_id ‖ auth_pub ‖ server_origin)` (exact bytes the relay session decides), then `promote_pairing`. The server marks the hub `attest_type = vouched` by that account.
3. The hub logs in with the Ed25519 signature only; the server accepts a vouched hub while it sits in an active slot of the vouching account (or of any account that later vouches for it). Removing the hub from every slot revokes it.
4. Upgrading an existing CloudKit link to the relay (RC §8 first bullet): the hub sends `relay_device_id` + `auth_pub` in the phone's `device_grant`; the phone vouches and calls `add_slot`. No QR.

### 7.3 Pi specifics

- A linux hub runs relay-only. The transport switch toward CloudKit is not offered for it (the phone hides it for a hub whose `device_grant` says `transports: [relay]`), and `entitlement_expired` leaves it with no transport: it keeps working locally, stops publishing, and the phone shows "This hub needs Relay" for it. The hub keeps its state and resumes when a paying phone is back.
- A free (CloudKit-only) phone cannot link a Pi; linking says so before the QR is scanned.

## 8. Actions (RC §5, hub side)

1. **Order.** `last_applied_action_seq` per phone in the sidecar; apply `last + 1` only; a repeat is dropped and echoed; a higher seq is held and `resend_from(last + 1)` is written once per gap (sim rules 4–5). `relay_processed` stays the exactly-once ledger (`begun`/`done`, `outcome_unknown`).
2. **Echo** every action record read, applied or repeat, by an overwrite with `expect: seq`; final statuses `applied | failed | expired | cancelled`, non-final `received | held` (sim rule 2).
3. **Control queue**: durable per mailbox, retried every pass (sim rule 7a): `resend_from`, `epoch_ack` handling, `transport_switch`/`transport_switched`/`transport_switch_rejected`, `hub_on_relay`, owed echoes.
4. **Handlers.** Every handler in `MobileHubCommandDispatcher` and `Handlers/` moves to Go with the same request/outcome payloads: asks (answer), board (create/update/move/comment), session start/stop, session input and Interrupt, permission answers, session chat/report requests, recordings (Mac only). PROJ-16 (a phone line reaches a session only from an allowed device, only through PROJ-12's typed-never-submitted delivery, never answering a permission prompt) and PROJ-21 (permission answers and one-Esc Interrupt under their grants, CAS on `permission_requests`) are re-pointed to the Go files in `docs/inventory/workbench.md` with their guard tests ported one-to-one; the meaning of each assertion does not change (owner approval for the re-pointing is part of approving this spec). Session input goes to the PTY through `session-host` (Go) instead of Desktop's `TerminalCenter`.
5. **Mixed versions** (RC §5 p. 10): the hub announces `ordered_actions: 1` in `device_grant`; a payload without `action_seq` is handled the old way. An old phone keeps working against the Go hub on CloudKit.
6. **Hygiene**: 7-day fallback on CloudKit, recipient delete + 14-day server TTL on the relay (sim rule 15).

## 9. Publishing on change (RC §6, in Go)

- **Nudge after apply**: one table action kind → slice kinds, called after every applied action.
- **Writes in the daemon's own process** (sync phases, automations, the hub's own handlers): the hub gets an in-process change notification from the Go DB layer for tables a slice reads, where that is cheap; everything else is seen by the poll below.
- **Writes by other processes** (Desktop, MCP servers, hooks, CLI): one `PRAGMA data_version` poll on a dedicated read connection, 250 ms while a phone was in touch in the last 10 minutes, else 1 s (RC decision, measured before the phase ends). On change, the DB-backed kinds are diffed.
- **Debounce** 150 ms trailing over the dirty-kind set; full diff every 60 s as the backstop for clock-driven values.
- **Spacing per transport** (ask #735): ~2 s on CloudKit (battery rule #724, its test rewritten as "at most once per the transport's minimum spacing"), 150 ms on the relay. Mailbox pass on the relay = on the WebSocket event; on CloudKit = today's 3 s / 30 s cadence.
- **Runner-fed slices** (session chat, session report, git refresher) call Go functions directly instead of spawning the CLI as the Swift hub does; their caps (300 / 4000 / 600 000, FEED-05) and in-memory payload rule stay.
- **Mac-only inputs**: owner-away (screen lock, 3 min idle, UI session — workbench-remote spec §5.1) and the keep-awake assertion (`MacAwakeAssertion`) are read and taken in Go on darwin (cgo: `CGSessionCopyCurrentDictionary`/`CGEventSourceSecondsSinceLastEventType`, `IOPMAssertionCreateWithName`); on linux owner-away is "always away" (no console to sit at) and there is no keep-awake.

## 10. Linking and hub commands

- `watchtower hub status|phones|unlink <device>|allow <device> <grant>|pair [--json]` with pinned `--json` keys. Desktop's Settings → Mobile is rebuilt on these (same screens, same design kit rows), plus the RC §10 transport indicators per phone.
- **Pairing on the Mac**: Desktop shows the QR and the SAS from `hub pair --json --stream`, and sends the owner's confirmation back through it.
- **Pairing on the Pi (headless)**: `watchtower hub pair` prints the QR as terminal block characters plus the payload as text, waits for the phone, prints the four-digit SAS and asks `Confirm code 1234 on your phone? [y/N]`. Attempt caps, refusals and code checks are the same as `MobileLinkCenter` today.
- `device_grant` gains `transports` (`[cloudkit, relay]` on a Mac, `[relay]` on a Pi) and `relay_device_id` + `auth_pub` (§7.2 p. 4), next to RC's `ordered_actions`.
- The phone shows the Pi under its hostname (overridable with `watchtower hub name <name>`).

## 11. Sessions created in Go

- `watchtower workbench session start --workbench N [--target T] [--agent claude|codex] [--place folder|worktree|auto] --json` does what Desktop's `startNewSession` does today: the `terminal_sessions` row, `SessionStartPlacement` (own worktree when a live agent already works in the folder, `.worktreeinclude`, the setup command), the brief, `claude mcp add` per new worktree, launch args (`workbench launch-args`), and the launch inside `session-host`, returning the session id at once (instant start, #942: row first in **Starting…**, moved into its worktree afterwards). `session stop` likewise.
- Desktop's **New Session** calls the same command, so placement and brief logic exist once. Desktop still attaches its terminal view to the hosted PTY as today (reattach, `HostedTerminalSession`).
- `clonefile` (darwin) falls back to a plain copy on linux for `.worktreeinclude` (`workbenchgit/clone_darwin.go` already isolates it).
- On the Pi `session-host` and the daemon run as **systemd user services** (`watchtower service install` writes the units, `loginctl enable-linger` is documented). Claude Code and Codex are installed and logged in by the owner on the Pi (`claude` login via URL on a headless box), documented in the guide.

## 12. Moving the Mac over

### 12.1 One switch, never two hubs

The release that ships the Go hub ships a Desktop without the Swift hub. At first launch of that Desktop the daemon's hub performs a one-time **adoption** before it publishes anything: it takes the hub lock, imports the Swift hub's state, and records `hub_impl = go` in the sidecar. An older Desktop that finds `hub_impl = go` refuses to start its Swift hub (one guard line shipped in the release *before* this one, so a downgrade cannot run both). Adoption is idempotent and resumable; a failure keeps the hub off and shows the error in Settings → Mobile (no fallback to the Swift hub, which no longer exists in that build).

### 12.2 Keys and state

- **Sidecar** (`MobileHub/hubstate.db` and assets) is opened by Go in place — same schema, a Go migration ledger added.
- **Keychain identity** (`hub_sig`, `hub_kx`, wrap key — `HubKeyStore`): Desktop, which owns the items' ACL, hands them once to the daemon over an inherited pipe (`fsutil.AttachPayloads`, never a file); the daemon stores them in its own Keychain items (darwin, cgo Security framework, `ThisDeviceOnly`, created by the daemon binary so it reads them without prompts). The Desktop items are deleted only after the daemon confirms it can open the sealed sidecar keys with them. On linux the identity lives in a 0600 file in the hub state dir (no Secure Enclave on a Pi — accepted, stated in the guide's privacy page).
- **CloudKit state** (`transport.db`, CKSyncEngine) moves to the bridge as is.
- **Mobile settings** (`mobileSyncEnabled`, start-session allows per phone, …) move from Desktop defaults to the hub's config/sidecar in the same adoption.

### 12.3 What existing phones notice

Nothing beyond RC §1's accepted changes. Same `hub_id`, same keys, same zones and shares, same wire names. A phone whose app predates `ordered_actions` keeps the old action path.

## 12a. Phone ↔ hub contract (shared with the relay client spec)

The phone/Kit side (relay client spec, `feature/relay-client`) and the Go hub meet only at these sealed payloads and records; both specs point here, and a change to any of them changes both sides together:

- **`device_grant`** (hub → phone, data zone): adds `ordered_actions: 1` (RC §5 p. 10), `transports: ["cloudkit","relay"] | ["relay"]` (§7.3, §10), `relay_device_id` and `relay_auth_pub` of the hub (§7.2 p. 4; replaces RC's `relay_mac_device_id`, same value plus the public key the phone vouches for).
- **`LinkPayload` v4** (QR): `transport`, `relay_device_id`, `relay_auth_pub`, `transports`; CKShare URLs optional and absent for a Pi.
- **Vouching** (§7.2): the phone sends `vouch_hub` after the SAS confirmation and before `promote_pairing` (new link) or before `add_slot` (upgraded link); a refusal (`ATTESTATION_*`, slot limit) keeps the hub off the relay and shows the server's reason.
- **Action and control records**: RC §5 (record names `a-<action_seq>`, `c-<uuid>`, echo statuses, control kinds) and sim rules 1–16, unchanged.
- **Alerts**: `send_alert` with the sealed `ask_alert` per paying phone, opened by the NSE under the wire name `alert-push` (RC §10).

## 13. Testing

- **Crypto vectors**: a Kit test target emits vectors (envelopes per zone and kind, wire names, AAD, keybox, HPKE hello, SAS, padding sizes, chunked asset frames, alert envelopes); a Go golden test opens and reproduces each byte for byte. Regenerated by a make target; a Kit change that alters bytes fails the Go test.
- **Sim scenarios**: the Go hub's processor runs the relay's sim scenarios (same test names) against an in-memory relay fake and against the in-memory CloudKit-shaped fake with change tags.
- **Interop**: `make relay-interop RELAY=../relay` runs the Go hub + a Go phone emulator against the relay's local stand; the same with the Kit's phone client once the relay client spec's Phase 3 lands.
- **Bridge**: a contract test drives the bridge with a fake `CloudSyncTransport`; one manual check against real CloudKit per phase that touches it.
- **Ported guards**: PROJ-16/21 and every Swift hub test with a behavioural assertion gets a Go twin before the Swift file is deleted; the deletion PR lists the mapping.
- **Linux**: CI already runs on ubuntu; add `GOARCH=arm64` build and a hub smoke test (start daemon, pair against the fake relay, start a session with a stub agent, echo a typed line).
- **Device**: a real Pi run is the phase gate of §14 phase 2.

## 14. Phases

| Phase | Content | Depends on |
|---|---|---|
| 1 | Go hub core on the relay: secure port + vectors, sidecar, processor/dispatcher/handlers, slices, publishing on change, relay transport, `hub` CLI, Go session start. Runs behind a dev flag next to the Swift hub on a test identity. | relay change §15 p. 1 for real linking; the relay's local stand for tests |
| 2 | Pi: linux/arm64 build, systemd units, headless pairing, vouching end to end, relay-only rules (§7.3), guide page. Gate: a real Pi driven from a real phone. | 1; relay client spec Phases 2–3 on the phone |
| 3 | Mac on the Go hub: CloudKit bridge, adoption (§12), Desktop Settings → Mobile over `hub …`, New Session through Go, transport switch both ways (sim rules 8–16) with epochs, Swift hub deleted. | 1; relay client spec Phase 1 on the phone for ordered actions |
| 4 | Pushes (`send_alert` per paying phone), Desktop indicators and hub-side measurements (RC §10), mobile-companion feature note rewritten. | 3; relay client spec Phase 4 |

Launch for users is one release carrying phases 1–4 (ask #800: the Mac and the Pi move together). Each phase gets its own plan.

## 15. What we need from the relay repository (relay session)

1. **Vouched hubs** (§7): `device_kind = HUB` registers unvouched; `vouch_hub` with the phone's assertion; login for a vouched hub with the Ed25519 signature only; revoke when it leaves every slot; App Attest design and client requirements updated (Mac rows replaced, the Developer ID open item dropped, the Linux open question closed by this rule).
2. The hub-side client rules in `sim/README.md` stay the contract; the Go hub's interop job may run in the relay CI like the Kit's (ask #734).

## 16. Left to the builder

Package layout under `internal/hub`, the bridge's frame schema, the systemd unit details, terminal QR rendering, the in-process change hook in the Go DB layer, exact cgo calls for owner-away and keep-awake, Go names for every seam type, how Desktop screens are split between `hub … --json` reads and direct sidecar reads (reads only; writes always through the hub).

## Decisions

- Pi workbenches driven from the phone; the Pi is not reachable from the internet and connects outbound only — conversation, ask #709
- Full E2E hub on the Pi, as on the Mac — ask #709
- The relay is the owner's `aiwatchtowers/relay` (now Cloudflare) — ask #711
- One Go hub in the daemon for darwin and linux, replacing the Swift hub — ask #713, conversation on ask #800 ("one Go code built for different platforms")
- The Mac and the Pi move to the Go hub together; CloudKit through a Swift bridge on the Mac — ask #800
- Every hub is admitted to the relay by the vouching of a paying attested phone; App Attest only on phones — asks #800, #801
- The relay client spec's hub half is written in Go here; its phone and Kit half stays there — ask #802
- Hub inside the daemon process, not its own process; bridge as an embedded helper app over a Unix socket; daemon-owned Keychain items on darwin and a 0600 file on linux; hub lock + `hub_impl` guard against two hubs; Pi hubs relay-only with "This hub needs Relay"; Pi without recordings; only Workbench on by default on the Pi; sessions started by one Go command used by the phone and Desktop — author's decisions, for approval
