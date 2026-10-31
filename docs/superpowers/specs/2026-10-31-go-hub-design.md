# Go hub — one phone hub for the Mac and headless hosts (Linux, a headless host, a Mac without the app), over the relay and CloudKit

**Status:** draft · **Date:** 2026-10-31 · **Owner decisions:** asks #709, #711, #713, #800, #801, #802
**Adapts:** [relay client design](2026-10-29-relay-client-design.md) (branch `feature/relay-client`, approved in ask #799; below: "relay client spec"). That spec's **hub half moves here and is implemented in Go**; its phone and Kit half stays there unchanged (§2).
**Server contract:** `aiwatchtowers/relay` — [relay spec](https://github.com/aiwatchtowers/relay/blob/main/docs/superpowers/specs/2026-10-28-relay-design.md), the Cloudflare design, the App Attest design, `proto/relay/v1/relay.proto`, `proto/README.md`, `sim/README.md` ("sim rule N"), `docs/watchtower-client-requirements.md`.
**E2E format:** [mobile E2E research](2026-10-12-mobile-e2e-encryption-research.md) and the Kit's `WatchtowerSync/Secure`.

## 1. Intent

The owner wants Watchtower to keep workbenches — Claude Code sessions in its folders — on **any host**, driven from the iPhone the way the phone drives the Mac's sessions today. There are only two roles: **host** and **client** (the phone). A host may be a Mac with the Desktop app, a Mac without it, a Linux box or a Raspberry Pi, typically with no monitor and not reachable from the internet. Watchtower is not tied to the Pi; the Pi is just one such host.

**Terms used below.** *Desktop host* = a Mac with the Desktop app installed (has the CloudKit bridge, §6.2). *Headless host* = any host without the Desktop app: Linux (`arm64`/`amd64`, e.g. a Pi or a PC) or a Mac with only the CLI. "The Mac" in this text means a desktop host. Everything the hub does is the same code on both; the differences are listed in §7.3 and §9 ("Mac-only inputs").

Today the phone hub (slices, the action mailbox, E2E, linking) lives in the Desktop app's Swift code and talks only CloudKit; sessions are created only by Desktop. Neither exists on Linux. The owner's choice (ask #713) is **one Go hub inside the daemon, built for darwin and linux** — not a second implementation for a headless host — and to move the Mac to it at the same time (ask #800). Since the relay client work was about to put the relay's hub side into the Swift hub, that hub side is written directly in Go instead (ask #802).

Side effects the owner gets on the Mac: the hub no longer dies with the Desktop app (today "a quit or crashed Desktop pushes nothing", workbench-remote spec §5.1), and the relay's publishing-on-change is natural in the process that already sees most writes.

## 2. Split with the relay client spec

| Relay client spec | Here (Go hub) | Stays there (phone, Kit) |
|---|---|---|
| §3 seam | hub-side neutral seam in Go (§5) | Kit seam for the phone: `RecordOrigin`, `HubRoute`, `LinkAccess`, `PushWake`, `LiveTransport`, factories |
| §4 identity | hub `relay_auth` + vouching (§7) | phone `relay_auth`, App Attest on the phone |
| §5 actions | hub order, holds, `resend_from`, echoes, control queue, hygiene, `ordered_actions` in `device_grant` (§8) | phone outbox, `action_seq`, `skip_to`, Not delivered |
| §6 publishing on change | all of it, in Go (§9) | — |
| §7 hosted relay transport | Go transport over the relay's Go client (§6) | `HostedRelayClient`/`HostedRelayTransport` in the Kit |
| §8 linking | hub side, plus headless linking on a headless host (§10) | phone side, `LinkPayload` v4 reading |
| §9 switch, subscription | hub side of sim rules 8–16, epochs | phone switch UI, StoreKit, `SUBSCRIPTION_MOVED` |
| §10 pushes, Desktop, measurements | `send_alert`, Desktop Settings → Mobile over the daemon, hub-side samples | `register_push`, NSE, phone Diagnostics |

Everything the relay client spec decided for the hub (Decisions list there: one action path for both transports, conditional mailbox writes on CloudKit, `action_seq` inside the payload, 150 ms / ~2 s spacing, `data_version` poll, epochs per switch, 90-day epochs at launch, keyboxes inside `transport_switched`) holds here unchanged — only the language and process change. Section numbers below cite it as "RC §N".

## 3. Goals, non-goals, anti-goals

**Goals**
1. One Go hub (`internal/hub/…`) in the daemon, built for `darwin/arm64`, `darwin/amd64`, `linux/arm64` (and `linux/amd64` because CI is there). It replaces the Swift hub in `WatchtowerDesktop/Sources/Services/MobileHub/` entirely; that code is deleted in the release that ships the Go hub.
2. The Go hub speaks both transports through one hub logic: the hosted relay (both platforms) and CloudKit (desktop hosts only, through a Swift bridge, §6.2). Free Mac users keep CloudKit with today's crypto, zones, shares and pairing.
3. A headless host runs the CLI, the daemon and `session-host`, holds workbenches, and is a hub on the relay: the phone sees it as one more host in its hub switcher (multi-hub F2), starts and stops sessions there, reads the workchat, answers asks and permission requests, types lines, moves board cards.
4. Sessions are created in Go: one start path (`watchtower workbench session start …`) used by the phone handler on both platforms and by Desktop's **New Session** on the Mac (§11).
5. Every existing link survives the upgrade: no phone re-pairs because the hub changed language (§12).
6. Byte compatibility with the Kit: envelopes, wire names, AAD, keyboxes, HPKE hello, SAS, padding, chunked assets — pinned by vectors generated from the Kit (§13).

**Non-goals**
- A Desktop UI on a headless host or for a headless host's workbenches on the Mac. A headless host is driven from the phone and its terminal.
- Slack, Gmail, Jira, meetings, digests, Knowledge and other pipelines on a headless host. They are features with their own switches; on a headless host only Workbench is on by default (onboarding is not run there). Whatever the owner turns on later works if it is portable; making each one portable is not this project.
- Phone recordings and transcription on a headless host (the transcriber is the Desktop's ML stack). A headless hub does not offer recording; the phone hides it for that hub.
- The phone and Kit work of the relay client spec (§2).
- A self-hosted relay, a LAN/direct transport, Tailscale.
- Key rotation with ephemeral X25519 (RC §1: after launch, Phase 5 there).

**Anti-goals (failure even if it works)**
- Any phone has to pair again after the upgrade.
- The Swift hub and the Go hub ever run against the same state at once (double apply, double publish, two relay sockets for one device identity).
- A host that opens an inbound port or needs a router change.
- Plaintext of slices, actions or alerts anywhere it is not today: on the relay, in iCloud, in logs (FILES-01), in a bridge socket on disk.
- A phone line landing in the wrong place: PROJ-16 and PROJ-21 guard tests move with the code and pass unchanged in meaning (§8.4).
- The Mac's behaviour for a free CloudKit user gets worse: slower, more battery, lost features. The changes they see are only the ones RC §1 already accepted (order of actions, publish on change).

## 4. Shape

```
iPhone ─E2E─▶ hosted relay (Cloudflare) ◀─E2E, outbound WSS─ watchtower daemon (Go hub)  ─ headless host (Linux / Pi / Mac without the app)
   │                                    ◀─E2E, outbound WSS─ watchtower daemon (Go hub)  ─ desktop host (Mac with the app)
   └─E2E─▶ CloudKit ◀── WatchtowerCloudBridge (Swift, desktop host only) ◀─ local socket ─┘
```

- The hub runs inside the daemon process (`runSyncDaemon`) as its own long-lived component with its own goroutines, independent of the sync cycle: a slow cycle never delays a mailbox pass or a publish. It starts when the daemon starts and mobile sync is enabled (`mobileSyncEnabled` moves from Desktop defaults to config, §12), and respects the MDM `MobileSync` key (POLICY: hub off / workbench_only) exactly as today.
- One process per device identity (sim, "one process per device identity"): a pidfile-style lock on the hub's state dir; a second daemon refuses to start its hub.
- **Several workspaces** (my call): the hub state stays per user (one `hub_id`, as today), and the hub runs in the daemon of the **active workspace** (`active_workspace`), which is what the Swift hub follows today through Desktop. A workspace switch stops the old daemon's hub (releasing the lock) before the new one starts; slices read the active workspace's database, as now. A headless host has one workspace.
- **`session-host`** (my call): the daemon may start `session-host` itself when it is not running (on a headless host always, on the Mac when Desktop is closed), with the same per-workspace socket and adoption rules (PROJ-20); Desktop attaches to the same host as today.
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
- A headless host needs only outbound HTTPS/WSS to the relay origin. Nothing listens.

### 6.2 CloudKit bridge (desktop hosts only)

Apple offers CloudKit only through its frameworks; a Go process cannot write the owner's private database and shares. The bridge is a small signed Swift helper, **`WatchtowerCloudBridge.app`**, embedded in the Desktop bundle with the iCloud container entitlement:

- It wraps the Kit's existing `CloudKitTransport` (CKSyncEngine, `transport.db` state, shares, query subscriptions for `sig-` alert records) and exposes exactly the transport operations — save (incl. conditional), delete, changes, share/participant operations of `PhoneAccessService`, alert subscription — as length-prefixed protobuf frames over a Unix socket in the hub's state dir (0700 dir, 0600 socket, peer UID check).
- It carries only sealed envelopes and metadata — the same bytes it would hand CloudKit. It holds no hub keys and never opens an envelope.
- The daemon launches it on demand (CloudKit transport selected) and supervises it (restart with backoff, shut down when the hub moves to the relay or stops). It does not depend on Desktop running. Silent pushes to the Mac (today `TrayAppDelegate`) are received by the bridge and forwarded as a "pull now" event.
- A headless host never has it: a headless host supports the relay only (§7.3).

## 7. Identity on the relay: vouched hubs

### 7.1 Rule (asks #800, #801)

Only phones attest with App Attest. **Every hub — desktop or headless — is admitted because a paying, attested phone of the account vouches for its `relay_auth` key** when it links the hub. This replaces the App Attest design's "Mac: `app_attest` on register, assertion on every login" and removes its "Mac without App Attest support stays on CloudKit" consequence and its open item about Developer ID. Accepted consequence: "only our apps" means, for hubs, "only what a paying owner linked to their own subscription"; a home-built hub gets in only if the owner links it, and it takes one of the 3 slots.

### 7.2 Flow (needs a relay change, §15)

1. The hub creates its Ed25519 `relay_auth` (§12.2) and registers it with `device_kind = HUB` and an empty attestation: the server stores it as **unvouched** — it may only read and write a pairing slot opened for it (relay spec §3.1 already limits an unpaid Mac to that).
2. Linking (RC §8, §10 here) puts `relay_device_id` and `auth_pub` into the QR. The paying phone, after the SAS confirmation, sends `vouch_hub{hub_device_id, auth_pub}` with its own App Attest assertion over `SHA256("relay/v1/vouch" ‖ nonce ‖ hub_device_id ‖ auth_pub ‖ server_origin)` (exact bytes the relay session decides), then `promote_pairing`. The server marks the hub `attest_type = vouched` by that account.
3. The hub logs in with the Ed25519 signature only; the server accepts a vouched hub while it sits in an active slot of the vouching account (or of any account that later vouches for it). Removing the hub from every slot revokes it.
4. Upgrading an existing CloudKit link to the relay (RC §8 first bullet): the hub sends `relay_device_id` + `auth_pub` in the phone's `device_grant`; the phone vouches and calls `add_slot`. No QR.

### 7.3 Headless hosts

- A headless hub runs relay-only. The transport switch toward CloudKit is not offered for it (the phone hides it for a hub whose `device_grant` says `transports: [relay]`), and `entitlement_expired` leaves it with no transport: it keeps working locally, stops publishing, and the phone shows "This hub needs Relay" for it. The hub keeps its state and resumes when a paying phone is back.
- A free (CloudKit-only) phone cannot link a headless host; linking says so before the QR is scanned.
- The rule follows the bridge, not the OS: a Mac with only the CLI is a headless host (relay-only, terminal pairing, LaunchAgent); installing the Desktop app later makes it a desktop host: phones linked from then on may use CloudKit too; phones already linked over the relay keep using the relay for this host (they are paying phones; moving one of them to iCloud means linking it again by QR, which also accepts the CloudKit share). No phone has to re-pair for the host to keep working. Its hub identity lives in daemon-owned Keychain items, or the 0600 file under the same rule as §12.2.
- Differences between hosts, all of them: the CloudKit bridge, recordings (need Desktop's transcriber), owner-away and keep-awake (darwin only; on Linux owner-away = always away), `.copied` clipboard fallback (desktop hosts only), `clonefile` (darwin, plain copy on Linux), service manager (launchd vs systemd), key store (Keychain vs 0600 file). The rest of the hub is one code path.

## 8. Actions (RC §5, hub side)

Contracts touched by this section: PROJ-16, PROJ-21 (phone input, permission answers, Interrupt), PROJ-12 (delivery), PROJ-20 (session host), PROJ-18 (cleanup after exits), all in `docs/inventory/workbench.md`; FEED-01..05 in `docs/inventory/session-feed.md` (session chat slice); POLICY rows for `MobileSync` in `docs/inventory/policy.md`. Their guard tests are ported to Go one-to-one with unchanged meaning where the code moves (§13). Failure paths of the action lane are the relay spec's §4.3 table and sim rules 1–16 (unreachable transport, gaps, conflicts, expired tokens, lapsed subscription, switch races), plus the hub's own: sidecar unreadable or locked → the hub stays off and says so in `hub status`; a handler fails → final echo `failed` with the error class; the hub crashes mid-apply → `relay_processed` `begun` without `done` → `outcome_unknown` echo, never applied twice.

1. **Order.** `last_applied_action_seq` per phone in the sidecar; apply `last + 1` only; a repeat is dropped and echoed; a higher seq is held and `resend_from(last + 1)` is written once per gap (sim rules 4–5). `relay_processed` stays the exactly-once ledger (`begun`/`done`, `outcome_unknown`).
2. **Echo** every action record read, applied or repeat, by an overwrite with `expect: seq`; final statuses `applied | failed | expired | cancelled`, non-final `received | held` (sim rule 2).
3. **Control queue**: durable per mailbox, retried every pass (sim rule 7a): `resend_from`, `epoch_ack` handling, `transport_switch`/`transport_switched`/`transport_switch_rejected`, `hub_on_relay`, owed echoes.
4. **Handlers.** Every handler in `MobileHubCommandDispatcher` and `Handlers/` moves to Go with the same request/outcome payloads: asks (answer), board (create/update/move/comment), session start/stop, session input and Interrupt, permission answers, session chat/report requests, recordings (Mac only). PROJ-16 (a phone line reaches a session only from an allowed device, only through PROJ-12's typed-never-submitted delivery, never answering a permission prompt) and PROJ-21 (permission answers and one-Esc Interrupt under their grants, CAS on `permission_requests`) are re-pointed to the Go files in `docs/inventory/workbench.md` with their guard tests ported one-to-one; the meaning of each assertion does not change (owner approval for the re-pointing is part of approving this spec). Session input goes to the PTY through `session-host` (Go) instead of Desktop's `TerminalCenter`: `session-host` gains a **list and input operation that does not attach** (a newer attach takes Desktop's pane over; this one never does). PROJ-20 is amended for it, and PROJ-16's "the session is live" and "the same run" checks are redefined on that operation's answer, with the same meaning — owner approved in ask #807. **Desktop's local-PTY fallback is removed** (owner, 2026-10-31: one path on every host): every session runs in `session-host`; if Desktop cannot reach or start it, opening a session fails with the reason in the pane ("[Watchtower] the session host is not running" and the like, as today's mid-run failures already say), and the daemon retries starting the host. Removed with it: `TerminalCenter`'s SwiftTerm local process path and its test seam, the `unprotected` state and its "This session stops when Watchtower quits." pane line, the quit alert's "N unprotected sessions will stop." line; PROJ-20 and `docs/features/workbench.md`'s Session host paragraph are amended (its **Fallback** sentence goes).
4b. **Delivery into the terminal moves into `session-host`.** Today the state that keeps a phone line out of the owner's way lives in Desktop's memory (`TerminalCenter`): `promptDrafts` (built from the owner's keystrokes in the pane — any non-Return key leaves a draft, a Return clears it), `pendingReturns` (a pasted line waiting for its Return after `pasteSettle`), `pasteHints`/`sharedPrompts`/answer hints, the run number, the agent's input profile (Claude vs Codex settle and busy hold), and bracketed-paste mode read from the terminal emulator. A Go hub writing to the PTY without that state could submit the owner's half-typed text with its Return or paste into the middle of it — PROJ-12/PROJ-16's core promise. So the whole **typed-never-submitted delivery** (paste, pause, re-check, Return or leave typed) and the prompt state move into `session-host`, the one place every byte of input already passes through (Desktop's keystrokes arrive as `Input` frames):
   - `session-host` tracks per session: owner draft (from client `Input` frames by the same rule as `ownerInput`), pending Return, lines left typed, the run (a launch counter that survives Desktop restarts — better than today's per-launch `runs`), bracketed-paste mode (parsed from `ESC[?2004h/l` in the output it already rings).
   - A new `Deliver{session, text, keep_line_breaks, keep_format, submit_if}` request returns `submitted | typed | held(reason) | no_session`; the hub's handlers (session input, ask answers, finish request) and Desktop's own Workchat composer and ask answers call it, so there is one delivery path instead of Desktop's plus the hub's.
   - Delivery events (`pasted`, `left_typed`, `submitted`) are broadcast to attached clients so Desktop keeps showing its pane hints.
   - Hook-fed conditions (permission prompt pending, agent busy, `submitSettle`) stay in the database and are checked by the caller before and by the re-check callback during the pause, as `SessionControl` does today.
   - The `.copied` fallback (line put on the clipboard when the session can't take typed text) exists only on a **desktop host**, where Desktop shows the clipboard hint (`pbcopy` from the daemon); on any headless host, a CLI-only Mac included, it is `cannot_type` with the message "This session can't take typed text right now".
   - PROJ-12 is re-pointed to the `session-host` delivery and Desktop's composer moves onto `Deliver`, with PROJ-12's guard tests ported unchanged in meaning — owner approved in ask #812.
   - **Older host, once.** `Deliver` and the non-attaching list/input are protocol v2 of `session-host` (additive frames; the hello carries the version). There is **no transition path** (owner, ask #813: one user, delete everything at once): at the first launch of the Go-hub release, if the running host speaks v1, Desktop restarts every live session once into a v2 host, **before the hub's adoption starts** (the hub never talks to a v1 host; on a Mac it cannot run earlier, because the new CLI arrives with this Desktop launch, and a headless host is a fresh install with no v1 host):
     0. Desktop first shows an in-app notice (not the updater window, which a silent install skips): "Running sessions restart once with this update; their conversations continue" with one button **Continue**. Nothing below happens, and the hub does not start, until it is pressed; closing the notice or quitting leaves everything as it was (old host, sessions running) and the notice comes back at the next launch until the step is done. While it waits, the phone sees this Mac as offline (its heartbeat goes stale), as it does today when the Desktop is closed.
     1. Desktop connects to the old host as a **v1 client** (its hello says version 1; v1 frames are a subset of v2, so the client keeps them), lists the runs of **every scope** (the host is one per user, shared by all workspaces) and records them in a restart list (`<app support>/session-host-restart.json`: scope, row id, agent, resume id) before touching anything.
     2. It stops each run as **Stop Sessions** does (SIGHUP → 3 s → SIGKILL) through the app's close path: the run is first dropped from `TerminalCenter`'s processes (as `close` does), **then** signalled, so its exit reports `closedByApp` and **no PROJ-18 cleanup** touches its worktree or branch before the resume (a test pins this order); after the exit it forgets the run, then sends SIGTERM to the idle old host (pid from `HelloOK`) and starts the v2 host.
     3. It relaunches each listed row of the open workspace with resume (Claude `--resume`, Codex `resume`) and removes it from the list once launched; rows of other workspaces stay in the list and are relaunched the same way when that workspace is opened (the reattach step at workspace open reads the list). Until then Desktop's workspace switcher shows "N sessions wait to resume" on that workspace, so none of them sits stopped unnoticed.
     - **The daemon waits — only for a v1 host.** If a **v1** host answers on the socket, the daemon starts no `session-host` of its own and does not start its hub (it checks the host's hello version each cycle) until a v2 host answers. If **no** host answers, the daemon starts a v2 host itself as §4 says (on a headless host always; there is never a v1 host there). adoption cannot begin anyway without Desktop's key hand-over (§12.2). Only Desktop's restart step replaces a v1 host.
     - Owner, ask #814: a one-time exception to PROJ-20's "an update keeps sessions running", accepted for this feature only; from then on every update keeps sessions as PROJ-20 says.
     - **Failures.** Interrupted at any step (crash, quit): the next Desktop launch resumes from the restart list — rows already relaunched are skipped, a v1 host still running is handled from step 1. Resume finds no conversation (no transcript / no rollout): the row ends in today's resume-failure state (the existing "could not resume" handling with a fresh start offered), never silently started fresh. A relaunch that fails for another reason leaves the row stopped with its reason in the pane, like any failed launch (#1281: not a natural exit, no cleanup). Desktop not launched after the update: nothing happens until it is — the old host keeps the sessions running and no Go hub exists yet. No v1 delivery code is kept in Desktop, and no phone action is ever held for a host version.
   - There is no session outside `session-host` (Desktop's local-PTY fallback is removed, board #1281, ask #811), so `Deliver` has no "no host" case besides `no_session`.
4a. **Phone recordings on the Mac** (my call): the transcriber stays in Desktop. The Go hub acts on a recording upload only while Desktop is running and has registered as the transcriber (`watchtower hub recording heartbeat`, fresh for 90 s — written by the hub, so the sidecar keeps one writer): then it opens the upload into the recordings dir (`config.AppSupportDir()`, excluded from Time Machine, 0600) and echoes `received` exactly as the Swift hub does, and Desktop takes the job from a queue table and drives `phone_recordings`. While Desktop is absent the recording action is held with the non-final echo `held`, so the phone keeps its audio; no plaintext audio is written by Go without a transcriber to take it. FILES-01 review of the queue is part of phase 3. This is no regression: today the Swift hub, and so recording intake, runs only while Desktop runs. **Desktop never writes the sidecar**: it claims and finishes recording jobs through `watchtower hub recording claim|finish --upload <id> [--transcript <id>]` and reads the queue only; the Go hub is the sidecar's single writer and owns its schema and migrations.
5. **Mixed versions** (RC §5 p. 10): the hub announces `ordered_actions: 1` in `device_grant`; a payload without `action_seq` is handled the old way. An old phone keeps working against the Go hub on CloudKit.
6. **Hygiene**: 7-day fallback on CloudKit, recipient delete + 14-day server TTL on the relay (sim rule 15).

## 9. Publishing on change (RC §6, in Go)

- **Nudge after apply**: one table action kind → slice kinds, called after every applied action.
- **Writes in the daemon's own process** (sync phases, automations, the hub's own handlers): the hub gets an in-process change notification from the Go DB layer for tables a slice reads, where that is cheap; everything else is seen by the poll below.
- **Writes by other processes** (Desktop, MCP servers, hooks, CLI): one `PRAGMA data_version` poll on a dedicated read connection, 250 ms while a phone was in touch in the last 10 minutes, else 1 s (RC decision, measured before the phase ends). On change, the DB-backed kinds are diffed.
- **Debounce** 150 ms trailing over the dirty-kind set, with a maximum wait of 1 s so continuous writes never hold publishing off; full diff every 60 s as the backstop for clock-driven values.
- **Spacing per transport** (ask #735): ~2 s on CloudKit (battery rule #724, its test rewritten as "at most once per the transport's minimum spacing"), 150 ms on the relay. Mailbox pass on the relay = on the WebSocket event; on CloudKit = today's 3 s / 30 s cadence.
- **Runner-fed slices** (session chat, session report, git refresher) call Go functions directly instead of spawning the CLI as the Swift hub does; their caps (300 / 4000 / 600 000, FEED-05) and in-memory payload rule stay.
- **Mac-only inputs**: owner-away (screen lock, 3 min idle, UI session — workbench-remote spec §5.1) and the keep-awake assertion (`MacAwakeAssertion`) are read and taken in Go on darwin (cgo: `CGSessionCopyCurrentDictionary`/`CGEventSourceSecondsSinceLastEventType`, `IOPMAssertionCreateWithName`); on linux owner-away is "always away" (no console to sit at) and there is no keep-awake.

## 10. Linking and hub commands

- `watchtower hub status|phones|unlink <device>|allow <device> <grant>|pair [--json]` with pinned `--json` keys. Desktop's Settings → Mobile is rebuilt on these (same screens, same design kit rows), plus the RC §10 transport indicators per phone.
- **Pairing on the Mac**: Desktop shows the QR and the SAS from `hub pair --json --stream`, and sends the owner's confirmation back through it.
- **Pairing on a headless host**: `watchtower hub pair` prints the QR as terminal block characters plus the payload as text, waits for the phone, prints the four-digit SAS and asks `Confirm code 1234 on your phone? [y/N]`. Attempt caps, refusals and code checks are the same as `MobileLinkCenter` today.
- `device_grant` gains `transports` (`[cloudkit, relay]` on a Mac, `[relay]` on a headless host) and `relay_device_id` + `auth_pub` (§7.2 p. 4), next to RC's `ordered_actions`.
- The phone shows a headless host under its hostname (overridable with `watchtower hub name <name>`).

## 11. Sessions created in Go

- `watchtower workbench session start --workbench N [--target T] [--agent claude|codex] [--place folder|worktree|auto] --json` does what Desktop's `startNewSession` does today: the `terminal_sessions` row, `SessionStartPlacement` (own worktree when a live agent already works in the folder, `.worktreeinclude`, the setup command), the brief, `claude mcp add` per new worktree, launch args (`workbench launch-args`), and the launch inside `session-host`, returning the session id at once (instant start, #942: row first in **Starting…**, moved into its worktree afterwards). `session stop` likewise.
- Desktop's **New Session** calls the same command, so placement and brief logic exist once. Desktop still attaches its terminal view to the hosted PTY as today (reattach, `HostedTerminalSession`).
- `clonefile` (darwin) falls back to a plain copy on linux for `.worktreeinclude` (`workbenchgit/clone_darwin.go` already isolates it).
- On a headless host `session-host` and the daemon run as user services: `watchtower service install` writes **systemd user units** on Linux (`loginctl enable-linger` documented) and a **launchd LaunchAgent** on a Mac without the app. With no Desktop there is no local-PTY fallback: if `session-host` cannot start, `session start` fails with the reason and the phone shows it. Claude Code and Codex are installed and logged in by the owner on a headless host (`claude` login via URL on a headless box), documented in the guide.

## 12. Moving the Mac over

### 12.1 One switch, never two hubs

The release that ships the Go hub ships a Desktop without the Swift hub. At first launch of that Desktop the daemon's hub performs a one-time **adoption** before it publishes anything: it takes the hub lock, imports the Swift hub's state, and records `hub_impl = go` in the sidecar. An older Desktop that finds `hub_impl = go` refuses to start its Swift hub and says "Mobile is run by a newer Watchtower". That guard ships **in the next regular release, ahead of the Go hub** (my call), so every later version an owner could downgrade to has it. A Desktop older than the guard is neutralised by the adoption itself: the adopted state moves out of `MobileHub/` into the Go hub's dir and the Desktop Keychain items are deleted after the hand-over (§12.2), so such an app finds no identity and no links — it can only start as a new, unlinked hub with a new `hub_id`, which holds no phone's link keys and so can never open, apply or echo an action of an adopted link (no double apply). Settings → Mobile in it shows "No phones linked", and the guide's downgrade note says to update. A downgrade after adoption is not supported for the mobile link (the hub stays off in the older app); everything else in the app keeps working. Adoption runs once per Mac: it is recorded in the Go hub's own state dir, and a later `MobileHub/` (created by a pre-guard app after a downgrade, with its new unlinked identity) is never imported over the adopted state on the next upgrade — it is logged and left alone, its Keychain items untouched, so the adopted links stay as they were. Adoption is idempotent and resumable; a failure keeps the hub off and shows the error in Settings → Mobile (no fallback to the Swift hub, which no longer exists in that build).

### 12.2 Keys and state

- **Sidecar** (`MobileHub/hubstate.db` and assets) is **moved** by the adoption into the Go hub's state dir (same schema, a Go migration ledger added); `MobileHub/` is left empty with a `MOVED` note file. Moving it is what neutralises a pre-guard app (§12.1).
- **Keychain identity** (`hub_sig`, `hub_kx`, wrap key — `HubKeyStore`): Desktop, which owns the items' ACL, hands them once to the daemon over an inherited pipe (`fsutil.AttachPayloads`, never a file); the daemon stores them in its own Keychain items (darwin, cgo Security framework, `ThisDeviceOnly`, created by the daemon binary; the legacy keychain ACL follows the binary's designated requirement, so a CLI update signed with the same team and identifier reads them without prompts — verified on a real Mac as the first task of phase 3). **If that check fails, the identity lives in a 0600 file in the hub state dir, as on a headless host** (owner, ask #807); the guide's privacy page says so. The bridge never holds keys either way. The hand-over is two-phase and safe to interrupt anywhere:
  1. Desktop writes the three items to the daemon's pipe (`hub adopt --keys-fd N`); the daemon stores them as **staged** (overwriting any earlier staged copy).
  2. The daemon opens the sealed sidecar keys with the staged identity; on success it marks the identity **adopted** in the sidecar and answers `adopted`; on failure it deletes the staged copy and answers the error.
  3. Only on `adopted` does Desktop delete its own items, then calls `hub adopt --confirm-deleted`.
  A crash, a closed pipe or a killed process at any step leaves Desktop's items in place; the next Desktop launch runs the hand-over again from step 1 (staged copies are overwritten, an adopted identity answers `adopted` at once, a missing `--confirm-deleted` makes Desktop retry the delete). The hub stays off — publishing nothing — until the identity is adopted. On linux the identity lives in a 0600 file in the hub state dir (no Secure Enclave on a headless host — accepted, stated in the guide's privacy page).
- **CloudKit state** (`transport.db`, CKSyncEngine) moves to the bridge as is.
- **Mobile settings** (`mobileSyncEnabled`, start-session allows per phone, …) move from Desktop defaults to the hub's config/sidecar in the same adoption. Readers of `mobileSyncEnabled` that change together: `WatchtowerCore/Utilities/Constants.swift` (the key), `App/AppState.swift` and `App/AppState+MobileHub.swift` (read `hub status --json` instead), `Services/MobileHub/MobileHubService.swift` (deleted with the Swift hub); Settings → Mobile's toggle calls `hub enable|disable`.

### 12.4 Screens

New or changed screens get mockups in `docs/design/mockups/go-hub/` before their UI task, reviewed by the owner, and Desktop screens are checked with `make desktop-shots` per `docs/design/desktop-style-guide.md` before review:
- Desktop Settings → Mobile rebuilt over the daemon: the phone list with transport per phone (RC's mockup `docs/design/mockups/relay-client/index.html` on branch `feature/relay-client` is the base; it reaches main with that branch), "Mobile is run by a newer Watchtower", the adoption error state, the hand-over in progress.
- Phone: a headless hub in the hub switcher (hostname), "This hub needs Relay", a hub without recording (record button hidden, with a one-line reason in the hub's info), "A free phone can't link this hub" before scanning.
- Desktop in-app notice at the first launch of the Go-hub release (when a v1 host holds sessions): "Running sessions restart once with this update; their conversations continue" + **Continue**.
- Desktop workspace switcher: "N sessions wait to resume" on a workspace whose sessions are still in the restart list (§8 p. 4b).
- Terminal (headless host): `hub pair` output — QR, waiting line, SAS prompt, success and each refusal.

### 12.3 What existing phones notice

Nothing beyond RC §1's accepted changes. Same `hub_id`, same keys, same zones and shares, same wire names. A phone whose app predates `ordered_actions` keeps the old action path.

## 12a. Phone ↔ hub contract (shared with the relay client spec)

The phone/Kit side (relay client spec, `feature/relay-client`) and the Go hub meet only at these sealed payloads and records; both specs point here, and a change to any of them changes both sides together:

- **`device_grant`** (hub → phone, data zone): adds `ordered_actions: 1` (RC §5 p. 10), `transports: ["cloudkit","relay"] | ["relay"]` (§7.3, §10), `relay_device_id` and `relay_auth_pub` of the hub (§7.2 p. 4; replaces RC's `relay_mac_device_id`, same value plus the public key the phone vouches for).
- **`LinkPayload` v4** (QR): `transport`, `relay_device_id`, `relay_auth_pub`, `transports`; CKShare URLs optional and absent for a headless host.
- **Vouching** (§7.2): the phone sends `vouch_hub` after the SAS confirmation and before `promote_pairing` (new link) or before `add_slot` (upgraded link); a refusal (`ATTESTATION_*`, slot limit) keeps the hub off the relay and shows the server's reason.
- **Action and control records**: RC §5 (record names `a-<action_seq>`, `c-<uuid>`, echo statuses, control kinds) and sim rules 1–16, unchanged.
- **Alerts**: `send_alert` with the sealed `ask_alert` per paying phone, opened by the NSE under the wire name `alert-push` (RC §10).
- **Unknown fields are ignored.** A phone that predates vouching sees `relay_device_id`/`relay_auth_pub`/`transports` in `device_grant` and ignores them (today's JSON decoding already drops unknown keys; a Kit test pins it). The hub never counts itself on the relay, and never stops publishing to CloudKit, until the server reports it vouched and in an active slot.
- **One shared fixture.** `device_grant` and `LinkPayload` v4 bytes are pinned by one JSON fixture in the repo (like `policy_cases.json`), read by a Kit test and a Go test: each case gives the payload and the expected decoded fields, including the ignore-unknown cases above. The Go hub plan's first task creates it; the relay client spec consumes it.
- The `vouch_hub` bytes and error codes come from the relay repository (§15 p. 1) and are copied into both specs once fixed there.

## 13. Testing

- **Crypto vectors**: a Kit test target emits vectors (envelopes per zone and kind, wire names, AAD, keybox, HPKE hello, SAS, padding sizes, chunked asset frames, alert envelopes); a Go golden test reproduces every deterministic part byte for byte (wire names, AAD, key derivation, padding, headers and bodies under the vector's fixed nonce) and opens or verifies every randomized one (CryptoKit's Ed25519 signatures and HPKE are randomized, so they cannot be reproduced; they are verified and opened). The other direction is a Go-sealed fixture the Kit opens. Regenerated by a make target; a Kit change that alters bytes fails the Go test.
- **E2E stays end to end** (owner, ask #807: "end-to-end encryption — don't screw it up"). Besides the vectors: (1) a canary test seeds every slice, action payload, alert and recording with known plaintext markers and asserts none of them appears in anything that leaves the hub process — relay frames (captured by the fake relay and in the interop run), bridge socket frames, the sidecar's sealed record blobs, logs (`logcanary`) — the only plaintext the sidecar holds is what it holds today (`held_session_lines.line`, `relay_processed.echo`, on the device, 0600), pinned by the test as the only such columns; (2) the Go hub refuses to send any record that did not pass through the sealer (one choke point, a type the transport accepts that only the sealer can build); (3) a Kit phone opens what the Go hub sealed and the Go hub opens what a Kit phone sealed, for every record kind, in the interop run; (4) the security review of each phase PR checks key handling (never logged, zeroed after use where the language allows, 0600/0700 on disk, never in the bridge).
- **One test per new branch of behaviour** — the plan names a test for each: vouch accepted / refused (`ATTESTATION_*`, slot limit, `HUB_NOT_VOUCHED`); relay-only hub on `entitlement_expired`; free phone refused for a headless host; adoption steps 1–3 and each interruption; pre-guard app neutralised; once-only adoption; v1 host restart steps and each failure above; `Deliver` outcomes (`submitted`, `typed`, `held(*)`, `no_session`) incl. owner draft and pending Return; never-started exit; recordings held without Desktop; `device_grant`/`LinkPayload` fixture cases; plaintext canaries.
- **Sim scenarios**: the Go hub's processor runs the relay's sim scenarios (same test names) against an in-memory relay fake and against the in-memory CloudKit-shaped fake with change tags.
- **Interop**: `make relay-interop RELAY=../relay` runs the Go hub + a Go phone emulator against the relay's local stand; the same with the Kit's phone client once the relay client spec's Phase 3 lands.
- **Bridge**: a contract test drives the bridge with a fake `CloudSyncTransport`; one manual check against real CloudKit per phase that touches it.
- **Ported guards**: PROJ-16/21 and every Swift hub test with a behavioural assertion gets a Go twin before the Swift file is deleted; the deletion PR lists the mapping.
- **Linux**: CI already runs on ubuntu; add `GOARCH=arm64` build and a hub smoke test (start daemon, pair against the fake relay, start a session with a stub agent, echo a typed line).
- **Device**: a real Linux host (e.g. a Pi) and a CLI-only Mac, each driven from a real phone, are the phase gate of §14 phase 2.

## 14. Phases

| Phase | Content | Depends on |
|---|---|---|
| 1 | Go hub core on the relay: secure port + vectors, sidecar, processor/dispatcher/handlers, slices, publishing on change, relay transport, `hub` CLI, Go session start. Verified in a **separate test workspace** (own database, own sidecar dir, own hub identity, `WATCHTOWER_HUB_DIR`) so it never touches the real workspace's asks, permission requests or sessions while the Swift hub runs; real data first in phase 3 (adoption) and on a headless host in phase 2 (my call). | relay change §15 p. 1 for real linking; the relay's local stand for tests |
| 2 | Headless hosts: linux/arm64 + linux/amd64 builds, a headless Mac (CLI only), systemd units, headless pairing, vouching end to end, relay-only rules (§7.3), guide page. Gate: a real headless host (a Pi) driven from a real phone. | 1; relay client spec Phases 2–3 on the phone |
| 3 | Mac on the Go hub: CloudKit bridge, adoption (§12), Desktop Settings → Mobile over `hub …`, New Session through Go, transport switch both ways (sim rules 8–16) with epochs, Swift hub deleted. | 1; relay client spec Phase 1 on the phone for ordered actions |
| 4 | Pushes (`send_alert` per paying phone), Desktop indicators and hub-side measurements (RC §10), mobile-companion feature note rewritten. | 3; relay client spec Phase 4 |

Launch for users is one release carrying phases 1–4 (ask #800: the Mac and a headless host move together). Each phase gets its own plan.

## 15. What we need from the relay repository (relay session)

1. **Vouched hubs** (§7): `device_kind = HUB` registers unvouched; `vouch_hub` with the phone's assertion; login for a vouched hub with the Ed25519 signature only; revoke when it leaves every slot; App Attest design and client requirements updated (Mac rows replaced, the Developer ID open item dropped, the Linux open question closed by this rule).
2. The hub-side client rules in `sim/README.md` stay the contract; the Go hub's interop job may run in the relay CI like the Kit's (ask #734).

## 15a. Status of the other two documents (2026-10-31)

- Relay client spec: moved onto §12a (`feature/relay-client` 6bcbca73e — `relay_device_id` + `relay_auth_pub`, `transports`, `vouch_hub` before `add_slot`/`promote_pairing`, relay-only hubs). No phone code with the old names has shipped; nothing needs a compatibility shim.
- Relay: the vouching form is accepted by the relay session; the reversal of the App Attest rule (relay ask #772) waits on the owner in relay ask #805, then App Attest spec amendment → plan → code. Phase 1 builds and tests against the local stand with attestation off; real linking waits on that.

## 16. Left to the builder

Package layout under `internal/hub`, the bridge's frame schema, the systemd unit details, terminal QR rendering, the in-process change hook in the Go DB layer, exact cgo calls for owner-away and keep-awake, Go names for every seam type, how Desktop screens are split between `hub … --json` reads and direct read-only sidecar reads (Desktop never writes the sidecar, §8 p. 4a).

## Decisions

- Workbenches on any host (Mac, Linux, Pi, a Mac without the app; usually no monitor) driven from the phone, two roles only: host and client — conversation 2026-10-31; a headless host is not reachable from the internet and connects outbound only — conversation, ask #709
- Full E2E hub on a headless host, as on the Mac — ask #709
- The relay is the owner's `aiwatchtowers/relay` (now Cloudflare) — ask #711
- One Go hub in the daemon for darwin and linux, replacing the Swift hub — ask #713, conversation on ask #800 ("one Go code built for different platforms")
- The Mac and a headless host move to the Go hub together; CloudKit through a Swift bridge on the Mac — ask #800
- Every hub is admitted to the relay by the vouching of a paying attested phone; App Attest only on phones — asks #800, #801
- The relay client spec's hub half is written in Go here; its phone and Kit half stays there — ask #802
- `session-host` gets a non-attaching list/input operation; PROJ-20 amended and PROJ-16's live/same-run checks redefined on it with the same meaning; — ask #807
- Desktop's local-PTY fallback (terminal inside the app when `session-host` is unavailable) is removed; every session on every host runs in `session-host`; PROJ-20 amended — owner, conversation 2026-10-31 and ask #811 (done separately as board #1281)
- Hub keys on the Mac in daemon-owned Keychain items; if that fails without prompts, a 0600 file as on a headless host; the bridge never holds keys — ask #807
- E2E is the red line: vectors, plaintext canaries on everything leaving the hub, one sealing choke point, two-way Kit interop — ask #807
Author's decisions, for the owner's approval in the review (each marked "my call" in the text):
- The hub runs in the daemon of the active workspace; a workspace switch stops it there and starts it in the new daemon (§4).
- The daemon may start `session-host` itself (headless hosts always; the Mac when Desktop is closed); Desktop attaches to the same host (§4).
- Phone recordings on the Mac are taken only while Desktop (the transcriber) runs; otherwise held, the phone keeps the audio — same as today, when the hub itself needs Desktop (§8 p. 4a).
- Desktop never writes the sidecar; recording jobs through `hub recording claim|finish` (§8 p. 4a).
- The downgrade guard ships in the next regular release; after adoption the mobile link cannot go back to an older app (it stays off there); a pre-guard app comes up as a new unlinked hub (§12.1).
- Two-phase key hand-over, Desktop items deleted only after `adopted` (§12.2).
- Phase 1 is verified in a separate test workspace; real data from phase 2 (headless host) and phase 3 (adoption) (§14).
- A headless hub without a paying phone has no transport: it keeps working locally, stops publishing, the phone shows "This hub needs Relay" (§7.3).
- Typed-never-submitted delivery and prompt state move into `session-host`; Desktop's composer and the hub use one `Deliver` path (§8 p. 4b); PROJ-12 re-pointed to it with the same meaning — ask #812.
- `session-host` protocol v2 for `Deliver`; no transition code: at the Go-hub release live sessions on a v1 host restart once with resume after an in-app **Continue** that comes back until done (v1 client, every scope, drop-then-signal so no cleanup, restart list, resumable, other workspaces flagged in the switcher; the daemon waits only while a v1 host answers) (§8 p. 4b) — owner, asks #813, #814 (one-time PROJ-20 exception accepted).
- A CLI-only Mac that later gets the Desktop app offers CloudKit only to phones linked after that; relay-linked phones stay on the relay for it (§7.3).
- Adoption runs once per Mac; a `MobileHub/` recreated by a downgraded app is never imported later (§12.1).
- Mockups for every new or changed screen before its UI task (§12.4).
- Hub inside the daemon process, not its own process; bridge as an embedded helper app over a Unix socket; daemon-owned Keychain items on darwin and a 0600 file on linux; hub lock + `hub_impl` guard against two hubs; Pi hubs relay-only with "This hub needs Relay"; Pi without recordings; only Workbench on by default on a headless host; sessions started by one Go command used by the phone and Desktop — author's decisions, for approval
