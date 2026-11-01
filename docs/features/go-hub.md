# Go hub (phase 1 core on the relay, phase 2 headless hosts)

The phone hub rewritten in Go and run by the daemon: it links phones, applies their actions in order, publishes the
slices on change and starts, types into and stops workbench sessions through `watchtower session-host`. In phase 1 it
runs **only** in a separate `hubtest-*` test workspace behind environment variables; the Swift hub in the Desktop
(`docs/features/mobile-companion.md`) is still the live hub. Phase 2 runs it live on headless hosts — Linux and a Mac
without the app ("Phase 2 — headless hosts" below); phases 3–4 move the Mac onto it and delete the Swift hub.

- Spec: [`docs/superpowers/specs/2026-10-31-go-hub-design.md`](../superpowers/specs/2026-10-31-go-hub-design.md)
  (approved, ask #819). Phone ↔ hub protocol:
  [`docs/superpowers/specs/2026-10-31-hub-phone-protocol-design.md`](../superpowers/specs/2026-10-31-hub-phone-protocol-design.md)
  (approved, ask #834).
- Plans: phase 1 [1a](../superpowers/plans/2026-10-31-go-hub-phase-1.md) and
  [1b](../superpowers/plans/2026-10-31-go-hub-phase-1b.md); phase 2 — headless hosts
  ([`2026-10-31-go-hub-phase-2.md`](../superpowers/plans/2026-10-31-go-hub-phase-2.md), approved ask #838); phase 3 —
  the Mac on the Go hub ([`2026-10-31-go-hub-phase-3.md`](../superpowers/plans/2026-10-31-go-hub-phase-3.md), approved
  ask #856); phase 4 — pushes and measurements (`docs/superpowers/plans/2026-10-31-go-hub-phase-4.md`, in review on
  the `docs/go-hub-phase-4-plan` branch).
- Board: umbrella #1284, phase 1 #1285.

## Architecture

One runtime (`internal/hub`, `Run`) inside the daemon joins these packages:

| Package | What it is |
|---|---|
| `internal/hub/secure` | The one sealing choke point: envelopes (X25519/Ed25519/HKDF/ChaCha20-Poly1305/HPKE, the Swift `SecureTransport`'s twin), wire record names, keyboxes, asset encryption, the four-digit SAS. Everything that leaves the hub is a `secure.Record` from the `Sealer`; the transports refuse anything else. Pinned by the shared Kit E2E vectors (`make e2e-vectors`). |
| `internal/hub/state` | The sidecar `hubstate.db` (own goose migrations, below), the hub lock `hub.lock`, the stored rows (devices, ledger, control queue, held actions, zone tokens, slice hashes, milestones, recording jobs). |
| `internal/hub/identity` | The hub's keys (`hub_sig`, `hub_kx`, wrap key) in a 0600 file `<hub dir>/identity.key` in phase 1; the keyring (epochs, `K_data`/`K_alert`, the per-phone relay keys), wiped when the hub stops. |
| `internal/hub/transport` | The `Transport` seam (`Write`/`Changes`/`Delete`, `Expect` preconditions, zones), `relay` — the hosted relay client (the relay's Go client and generated proto vendored by `make relay-go`, pinned in `transport/relay/VERSION`) — `memfake`, the in-memory relay/CloudKit stand-in for tests, and `cloudkit` (phase 3) — the client of `WatchtowerCloudBridge.app` over `<hub dir>/bridge.sock` (`bridge.proto`/`bridgepb`, frames pinned by `testdata/frames.json` for the Swift bridge; runtime zone names mapped onto `DataZone-<hub_id>`/`RelayZone-<hub_id>`, every phone on the one shared mailbox `relay/<relay id>/*`; the bridge's generation in `<hub dir>/bridge.generation` so a lost `bridge.db` resets cursors and refuses old tags), its `Supervisor` and the `bridgefake` test bridge. |
| `internal/hub/link` | Linking: link codes, the pair zone hello, the awaiting keybox, the SAS confirmation (`Confirm(device, code, ok)`), grants (`typing`, `permissions`, `start_sessions`), unlink and the revoke hook. |
| `internal/hub/actions` | The processor (ordered actions per phone by `action_seq`: hold ahead of a gap, one `resend_from` per gap, `skip_to`, the exactly-once ledger, `received`/final echoes, the legacy unordered path, controls) and the dispatcher; `actions/handlers` holds every action handler (asks, board, session start/stop, session input and Interrupt, permission answers, chat/report requests, recording uploads). |
| `internal/hub/slices` | The publisher (hash per record, urgent/full ticks, the 900 KB guard, heartbeat), the change watch (`data_version` poll: 250 ms for 10 min after a change, else 1 s; nudges from handlers and the session-state lane) and `slices/sources`, one source per slice kind. |
| `internal/hub/platform` | Darwin/Linux specifics: the owner-away signal, keeping the machine awake, and `PeerUID` (the unix-socket peer check of the control socket and the bridge client). |
| `internal/hub/hubtest` | Test-only: the Go phone emulator (`Phone`) and its hosted-relay store. Never imported by production code. |
| `internal/sessionstart` | Sessions created in Go: `Begin`/`Finish`/`Start`, placement (folder or own worktree), `Launch` (the Swift `TerminalLaunch` twin) and `Port`, the hub's `handlers.SessionPort` over `session-host`. |
| `internal/sessionhost` | `watchtower session-host`, protocol v2 (below). |
| `internal/sessionstate` | The session state resolver shared by the hub's handlers and sources (`Resolve`, `IsIdle(row, state)`, `IsWorking`, `NeedsApproval`, `HooksReported`), pinned to the Swift `SessionControl` by fixtures. |

Seams: `transport.Transport` (relay in production, memfake in tests), `handlers.SessionPort` (the real
`sessionstart.Port`, or a refusing port — below), `slices.Source`, and the `Options` test seams in `internal/hub/hub.go`.

## The dev flag and the test workspace

The daemon (`runSyncDaemon` → `startGoHub` in `cmd/sync.go`) starts the hub only when `hub.FromEnv` accepts all of:

| Variable | Meaning |
|---|---|
| `WATCHTOWER_HUB_DIR` | Absolute hub state dir (sidecar, lock, control socket `hub.sock`, status file, `recordings/`). Refused when relative or inside the Swift hub's `<AppSupportDir>/MobileHub` (symlinks resolved). Every `watchtower hub …` verb needs it too; phase 1 has no default. |
| `WATCHTOWER_HUB_TEST_WORKSPACE` | Must equal the daemon's active workspace and start with `hubtest-`; anything else is `not_test_workspace` and the hub stays off. |
| `WATCHTOWER_RELAY_ORIGIN` | The relay origin (`http(s)://host[:port]`), e.g. the local stand from `make relay-interop`. |
| `WATCHTOWER_SESSION_HOST_SOCKET` | The session host the hub may use. Unset: the hub has no session host and every session action is refused (below). Phase 1 never reaches the Desktop's host on its own. |

How to run it: create a workspace named `hubtest-<name>` with its own config and database (never the live one), point
the four variables at a temp dir, the local relay stand and a test `session-host` socket, run `watchtower sync --daemon`
for that workspace, then `watchtower hub enable` and `watchtower hub pair --stream`. The interop run
(`make relay-interop RELAY=<relay checkout>`, `internal/hub/interop_test.go`) does exactly this with the Go phone
emulator: `wrangler dev` from `<relay>/worker` in its own process group, App Attest off, a hub per test on a temp
`hubtest-*` dir.

## CLI

`watchtower hub …` (`cmd/hub.go`, `cmd/hub_link.go`, `cmd/hub_recording.go`). One write rule: with the hub lock free
the CLI writes the sidecar itself; while a hub holds it the write goes over `<dir>/hub.sock` to that hub (peer uid
checked), so the sidecar never has two writers. Refusals print classes only.

| Verb | `--json` keys (pinned) |
|---|---|
| `hub status` | `state` (`off`, `starting`, `running`, `paused`), `reason` (`disabled`, `policy_off`, `locked`, `not_test_workspace`, `sidecar_unreadable`, `not_admitted`, `relay_unreachable`, `start_failed`; phase 2: `desktop_host`, `no_relay_origin`, `run_dir_unusable`, `needs_relay`, `not_vouched`, `vouch_revoked`), `hub_id`, `relay_device_id`, `transport`, `impl`, `dir`, `phones`, `host` (`desktop`/`headless`), `mode` (`test`/`live`, empty = off), `recordings` (`on`/`off`) |
| `hub phones` | `device_id`, `name`, `scope`, `linked_at`, `typing_allowed`, `typing_requested`, `permissions_allowed`, `permissions_requested`, `start_sessions_allowed`, `start_sessions_granted`, `ordered`, `last_applied_action_seq`, `transport` |
| `hub unlink <device>` | `device_id`, `unlinked` |
| `hub allow <device> typing\|permissions\|start_sessions [--revoke]` | `device_id`, `grant`, `allowed` |
| `hub name <name>` | `name` |
| `hub enable` / `hub disable` | `enabled` |
| `hub pair [--stream]` | JSON lines: `{event: qr, url, expires_at}`, `{event: waiting}`, `{event: sas, device_id, name, code}`, `{event: linked, device_id}`, `{event: refused, reason}`; the owner's `{confirm: true\|false}` on stdin |
| `hub desktop heartbeat` (darwin only) | `desktop_at` |
| `hub recordings on\|off` (owner; `on` refused "this host has no transcriber" before any Desktop heartbeat) | `recordings`, `stored` |
| `hub recording claim --upload <id>` | `upload_id`, `audio_path`, `status` |
| `hub recording finish --upload <id> [--transcript N] [--error <class>]` | `upload_id`, `status`, `transcript_id` |
| `hub recording progress --upload <id> --phase transcribing\|diarizing\|summarizing [--percent N]` (tests and the lock-free path; Desktop uses the socket op) | `upload_id`, `status`, `phase`, `percent` |
| `service install\|uninstall\|status` (phase 2, `cmd/service.go`; install/uninstall are owner verbs) | `manager`, `installed`, `running`, `linger` (null on darwin or without `loginctl`) |

`watchtower workbench session start --workbench N [--target T] [--agent claude|codex] [--place folder|worktree|auto]`
answers at once (instant start, `session_id`, `state`, `folder_path`, `worktree_branch`) and a detached hidden
`workbench session finish` places and launches the row in `session-host`; `workbench session stop --session N` is the
host's Stop request (`session_id`, `stopped`). Both refuse another workbench inside an agent's terminal session.

## Sidecar ownership and migrations

`<hub dir>/hubstate.db` belongs to the hub process holding `hub.lock` (the CLI only while it holds the lock itself). It
is never `watchtower.db`: the hub reads the workspace database through its own read-only handle and writes it only
through the handlers' guarded writes. Migrations (`internal/hub/state/migrations`, goose, applied on open):

- `00001_swift_baseline` — the Swift hub's `hubstate.db` as it is today (every statement `IF NOT EXISTS`, so an adopted
  Swift sidecar opens; adoption itself is phase 3).
- `00002_go_hub` — ordered actions per device (`last_applied_action_seq`, `ordered`, `relay_device_id`,
  `resend_requested_from`), `control_queue`, `held_actions`, `zone_tokens`.
- `00003_pending_relay_id` — the relay device id a hello names, on the waiting request.
- `00004_epoch_ack` — `devices.acked_epoch`.
- `00005_recording_jobs` — the phone-recording job queue Desktop claims and finishes.
- `00006_held_uploads` — held recording uploads (ids, first hold, outcome class), so the 7-day expiry and the
  switch-off failure survive a restart.
- `00007_relay_admission` — `devices.relay_admitted_at` (REAL, NULL until the relay lists the phone holding the hub in
  a slot; a re-link clears it).
- `00008_desktop_recordings` — `recording_jobs.phase` (`transcribing|diarizing|summarizing`) and `percent` (0–100,
  transcribing only) of a claimed job, as Desktop reports them; no file name.

New columns hold ids, counters, timestamps and error classes only; envelopes stay sealed. The only plaintext the
sidecar keeps is today's: `held_session_lines.line` (a phone line held behind the owner's draft) and the Swift
baseline's own columns, checked by the canary test.

## `session-host` protocol v2

The host (`internal/sessionhost`) answers v1 and v2 hellos; a v2 client refuses a v1 host and never replaces it. v2 adds
operations that never bind the connection to a session, so the hub never takes a run over from the app's window:
`List`, `InputTo` (bytes into one run and launch — the phone's Interrupt Esc; never the owner's draft), `Deliver`
(PROJ-12's typed-never-submitted delivery inside the host: bracketed paste, the settle pause, `DeliverCheck` before
the Return, `hold_if_prompt_text` for PROJ-16 lines; outcomes `submitted`, `typed`, `held`, `no_paste_mode`,
`no_session`), `PromptHint` and `Stop` (the exit carries `requested`, so no PROJ-18 cleanup follows). Every launch of a
row gets the next value of a per-row launch counter; `InputTo`, `Deliver` and `Stop` name it. PROJ-12, PROJ-16, PROJ-20
and PROJ-21 list the Go guards (`docs/inventory/workbench.md`).

## v1 limits (phase 1)

- Relay only: no CloudKit bridge, no adoption of the Swift hub's sidecar or keys, no transport switch, no pushes, no
  terminal pairing UI and no Desktop wiring until phases 2–4. The Swift hub is the live hub.
- Keys live in a 0600 file in the hub dir (the daemon-owned Keychain items are phase 3).
- The hub runs inside `watchtower sync --daemon` only (on a headless host under `watchtower service install`, phase 2).
- Recording jobs are queued for Desktop (`hub recording claim|finish`). The owner's recording switch (`hub_meta`
  `recordings`, default on iff `desktop_seen_at` — the first Desktop heartbeat — is set) is published as the
  heartbeat's `capabilities.recordings`; off answers an upload the final `failed`/`not_supported`, a held upload gets
  `failed`/`expired` 7 days after its first hold, and the upload echo carries `reason` on a failure (protocol §7.7, §9).

## Linux behaviour

Every darwin-only piece on the daemon path and what a Linux host does instead (phase 2, Task 1 audit; each line
checked against the code named).

| Piece | darwin | Linux |
|---|---|---|
| `internal/sessionhost` socket (`DefaultSocket` → `socketDirFor`) | the user's temp folder (unchanged, `testdata/paths.json`) | `/run/user/<uid>` when it is a real folder owned by the uid with mode 0700, else `<data root>/.run` (created 0700, checked and tightened through one `O_NOFOLLOW` descriptor; a symlink, a file, another owner or a socket path too long for `sockaddr_un` → `run_dir_unusable`; a data root that cannot be determined fails before `/run/user` is tried); computed from the uid alone, no `XDG_RUNTIME_DIR`, never `/tmp` |
| `config.AppSupportDir` (`appSupportDirFor`) | `~/Library/Application Support/Watchtower` | `<data root>/.support`; `RecordingsDir`'s default follows (`<data root>/.support/recordings`, where a Linux host keeps none) |
| Hub control socket and bridge client peer check (`platform/peer_darwin.go` / `platform/peer_linux.go`) | `LOCAL_PEERCRED` | `SO_PEERCRED`; a failed read closes the connection before any request (`TestControlSocketClosesWhenPeerCredentialsFail`); other OSes refuse every client (`platform/peer_other.go`) |
| Live hub dir (`hub.DefaultDir`) | `<data root>/.hub` | the same; `.hub` is never a workspace name (`ValidWorkspaceRe`) |
| `internal/policy` (`reader_other.go`) | MDM managed preferences | no reader: no profile, no restriction (POLICY-01) |
| `internal/backupexclude` (`backupexclude_other.go`) | Time Machine exclusion attribute | no-op |
| `internal/auditlog` (`oslog_other.go`) | unified-log line | no unified-log line (READ-02: a no-op off darwin) |
| `internal/ownerconfirm` (`peer_other.go`) | the Desktop confirms owner gestures | no Desktop: every peer is refused, so AGENT-07 confirmation gestures are refused |
| `internal/sessioncleanup` birth time (`birth_other.go`) | the worktree admin dir's birth time | unknown → a worktree not owned by record is kept |
| `internal/workbenchgit` `.worktreeinclude` (`clone_other.go`) | `clonefile` | plain copy |
| `internal/hub/platform` (`away_linux.go`, `awake_linux.go`) | console lock, input idle and display sleep; keep-awake | always away, no keep-awake (`Hold` does nothing) |
| `internal/chat` sandbox (`NewChildSandbox`) | `sandbox-exec` profile | refused ("needs macOS"), so claude.ai mode stays off |
| `internal/planusage` (`DefaultCredentialSource`) | Keychain, then `~/.claude/.credentials.json` | the credentials file only, no Keychain |
| `internal/daemon` process identity (`procident_other.go`) | `kern.proc.pid` sysctl start time | `ps -o lstart=` under `LC_ALL=C` |
| Phone line or ask answer the session cannot take (`internal/hub/actions/handlers`: `deps.go` `Clipboard`/`DesktopHost`, `session_input.go`, `ask.go`) | a line: copied to the clipboard (pbcopy) while the Desktop heartbeat is fresh, echo `failed(cannot_type)` saying so; an ask answer: saved, `failed(cannot_type)` | no Desktop heartbeat, so no clipboard: `failed(cannot_type)` with `CannotTypeMessage` (an ask answer still saved) |
| `internal/sqlcipher` crypto (`wt_cgo.go`) | CommonCrypto | OpenSSL `libcrypto` (dynamic) |

## Measured cost

An idle hub (one linked phone, a file database, production cadences: 1 s idle `data_version` poll, 5 s state-lane
backstop, 30 s mailbox pass, no writes) used **0.068 % CPU** — 205 ms of CPU over 300 s from `getrusage`, measured for
5 minutes after a 10 s settle (plan 1b Task 10).

## Deviations from the spec

Recorded for the owner; each was a review ruling during phase 1.

1. **The bare probe is applied.** A `probe` action without a `nonce` is applied (its result names the hub); the Swift
   hub failed it `invalid_params`. A phone or a test can check the lane with a bare action (plan 1a Task 10).
2. **Quota and entitlement controls stay queued.** An echo or control the relay refuses for a lapsed entitlement, a
   quota or an outdated protocol waits in `control_queue` and is retried each pass; only a record too large or a
   forbidden mailbox is dropped. The relay sim's rule 7a drops them; the entitlement case is revisited in phase 3
   (sim rule 16).
3. **The Desktop→hub inputs arrive in phase 3.** Since plan 3 Task 5 the control socket takes:
   - `desktop_view`: `hidden` (session ids in the Desktop's PROJ-17 Undo batch: not published, not alerted, no
     window slot) and `display_over` (`[{id, run, reported_at}]`, the background counts the Desktop shows over,
     #411; a count reads Stopped only while the row still holds that run start — null = not live — and that
     `agent_background_at`, as the Swift `ShownOverCount`), each at most 10 000 (`too_many_ids` beyond). In memory
     only; ignored while the Desktop heartbeat is stale (> 90 s), dropped when it was sent before that. The
     `desktop_heartbeat` answer carries `view_needed: true` while the hub holds no current view (never sent, or
     dropped); Desktop sends the view at its start, on every change and on `view_needed`. A stale → fresh heartbeat,
     and a heartbeat going stale, republish the view's slices.
   - `recording_progress` (`upload`, `phase`, `percent`): the `recording_job` slice then reads `transcribing` with its
     percent, `diarizing` or `summarizing`, as the Swift slice.
   - `desktop_watch`: the answer (`{op, ok, state, reason}`, the current status as a snapshot) is the stream's first
     line, then `{event: status, state, reason}`, `{event: recording_queued, upload_id}`, `{event: pair, pair,
     device_id}` (never a URL or a code) and, from the transport switch on, `{event: switched}` lines.

   **Done (phase 3 Task 9): the owner-write notice.** Desktop announces a target's done only when the newest
   `target_status_history` row is not `owner` (`WorkbenchOwnerNoticePolicy`, filled by
   `WorkbenchQueries.activitySnapshot`); a rollup (`system`) row written in the same statement as a child's change
   takes that change's actor. **Accepted effect:** an unclaimed CLI status write (`watchtower targets done N`) is
   recorded as `owner` too and is no longer announced on the Mac.
4. **Test mode is a `hubtest-*` test workspace** (`WATCHTOWER_HUB_TEST_WORKSPACE`). Since phase 2 a headless host also
   runs the live mode (see "Phase 2 — headless hosts"); a desktop host gets the Go hub only in phase 3.
5. **The refusing session port (test mode only).** In test mode, unless `WATCHTOWER_SESSION_HOST_SOCKET` is set, the hub
   uses a port that refuses every session start, stop, line and Interrupt (no session host), so a test workspace never
   reaches the Desktop's host. The live mode (phase 2) uses `sessionhost.DefaultSocket()` (the override still wins
   when set).

## Testing

- `go test ./internal/hub/...`, `./internal/sessionhost`, `./internal/sessionstart`, `./internal/sessionstate` — the
  handlers' Go guards (PROJ-12/16/20/21, FEED-05, POLICY-03), the relay sim's order rules on memfake (both relay and
  CloudKit kinds), and `TestCanary_NoPlaintextLeavesTheHub` (a marker in every slice row, action payload, alert and
  recording; none appears in a frame, attachment, log line or sidecar cell but the known plaintext columns).
- `hubtest.Phone` answers `resend_from` the way the Swift phone does: each requeued action's same bytes are written as
  a new version under the last `record_seq` the phone knows at that name (its own write or the hub's echo over it). The
  hub then reads an identical record again after its cursor moved; it is the same action — held once, applied once,
  re-echoed once (`TestIdenticalRecordRedeliveredAfterTheCursorMovedIsSame`).
- `make relay-interop RELAY=<relay checkout>` — the hub and the Go phone against the relay's local stand: linking over a
  pairing slot, ordered actions with echoes, reconnect and resubscribe after a stand restart, no plaintext on the wire.
- Linux: the Go Test job of the PR's CI runs on ubuntu, and `go-linux-arm64` on `ubuntu-24.04-arm` (phase 2). A local
  `GOOS=linux go build` cannot run on a Mac (SQLCipher is cgo); every Linux build runs on a native Linux runner.
- `make hub-smoke` (phase 2: `go test -tags smoke ./cmd -run TestHeadlessSmoke -timeout 5m`,
  `cmd/hub_headless_smoke_test.go`) — the headless smoke test: daemon, terminal-free pairing, a stub session, a typed
  line, the `needs_relay` pause; live mode on Linux, the test workspace on darwin. CI runs it in the Go Test job and in
  `go-linux-arm64`.

## Phase 2 — headless hosts

Plan [`2026-10-31-go-hub-phase-2.md`](../superpowers/plans/2026-10-31-go-hub-phase-2.md) (approved ask #838; owner
rulings asks #827, #881, #883). The hub leaves the test workspace for real data on a **headless host**: Linux
(arm64, amd64) or a Mac with only the CLI. Guide: [`docs/guide/features/headless-host.md`](../guide/features/headless-host.md).

- **Live mode beside the test mode.** `hub.Resolve(cfg, db, probe)` is the daemon's only entry: `WATCHTOWER_HUB_DIR`
  set → Plan 1a's test mode, unchanged; else `hostkind.Detect` — Linux is always headless; a Mac is a desktop host when
  `/Applications` or `~/Applications` holds `Watchtower.app` with bundle id `com.watchtower.desktop`, or
  `config.AppSupportDir()/MobileHub` exists. A desktop host stays off with reason `desktop_host` and nothing under the
  hub dir or `MobileHub/` is created, opened or read (existence checks only). The check runs once, at hub start
  (ask #827): no stop or hand-over when the app is installed later. Headless → `<data root>/.hub` (0700, files 0600,
  the 0600 `identity.key`), live only after `hub enable`; off reasons `disabled`, `policy_off`, `no_relay_origin`,
  `run_dir_unusable`. Daemon log lines `hub: started (live, headless)`, `hub: started (test workspace)`,
  `hub: off (<reason>)`. The CLI verbs resolve their dir through `hub.Dir`; on a desktop host every verb but `status`
  exits 1 with "Mobile on this Mac is run by the Watchtower app.". `hub status --json` gains `host` and `mode`.
- **Relay origin**: `WATCHTOWER_RELAY_ORIGIN` > config `hub.relay_origin` > ldflags `hub.DefaultRelayOrigin` (release
  builds: `scripts/build-linux.sh` from `RELAY_ORIGIN`, `scripts/build-app.sh` from `WATCHTOWER_RELAY_ORIGIN_DEFAULT`;
  a release tag with it empty refuses to build). `https://host[:port]` only, `http://` for loopback; `hub status`
  prints "Set the relay: watchtower config set hub.relay_origin <origin>" for `no_relay_origin`.
- **Relay only** (spec §7.3): `transports: ["relay"]` in the QR and every `device_grant`, no shares, no CloudKit bridge,
  `transport_switch_rejected`. `PayingWatch` (`internal/hub/paying.go`): with no phone `paying` in
  `get_account_state` the hub is `paused`/`needs_relay` — `Publisher.Pause`, `Processor.SetPaused(true)`, state kept,
  no handler run, sessions untouched; re-read every 5 min (`NeedsRelayPoll`) and at once on `ENTITLEMENT_EXPIRED`,
  `SLOT_REMOVED` or `ENTITLEMENT_INACTIVE`; pairing is never paused. Resume publishes one full diff.
- **Vouched admission** (spec §7, §12a; relay `bcca870` "Vouched hubs"; `internal/hub/admission.go`): the hub registers
  as `DEVICE_KIND_HUB` with an empty attestation in test and live mode alike (the relay treats `DEVICE_KIND_MAC` as the
  same hub kind, so a sidecar an older build registered as a Mac keeps its device) and logs in by Ed25519 only. Until
  `get_account_state` lists a phone holding it in a slot (`relay.Transport.Vouched`) the hub writes only its
  `pair/<slot>` zones: the publisher and the processor hold with the relay-only pause (`applyGate`), no
  `set_hub_readers`, no data-zone or mailbox op, no wipe; status reason `not_vouched` (state `running` in test mode,
  `paused` live). `HUB_NOT_VOUCHED` (`transport.ErrNotVouched`) on any op clears the transport's slots and closes the
  gate — no re-register, no retry. `CONTROL_KIND_SLOT_ADDED` (`transport.SlotAdded`): the transport reads the account
  state before handing the event on, the gate opens at once and the listed phones get `devices.relay_admitted_at`
  (sidecar `00007`). Every account-state read — the one `Connect` made at start, `SLOT_ADDED`'s, the readers sync,
  the polls — goes through one door (`readAccount`/`followAccount`: stamps, then the gate), and while unvouched
  `accountReader` makes at most one `get_account_state` per `unvouchedPoll` (30 s, the relay's limit) of the hub's
  clock — the short link retry's 2 s ticks and the PayingWatch read the last answer in between; the link backstop
  (`linkEvery`) polls only with a phone linked (the hub expects a slot). Unvouched after a phone had been admitted
  is `vouch_revoked`: nothing published, the sidecar kept, also across a restart; a new vouch and slot (a new
  `hub pair`, or the phone's `add_slot`) admit it again. `hub phones` shows `transport` `pending` for a relay phone
  without `relay_admitted_at`, `relay` with it. `hubtest.Phone.VouchLink` (the copied client's `VouchHub`: VOUCH challenge, then
  `vouch_hub` with no attestation) and `relaytest`'s vouch model (gate incl. open sockets, the relay's refusal order,
  10-minute pending vouch consumed by `promote_pairing`/`add_slot`, best-effort `SLOT_ADDED`, `RemoveSlot`).
- **Session host under a service manager** (PROJ-20 amended for Linux, ask #827): socket dir `/run/user/<uid>` or
  `<data root>/.run` (see Linux behaviour); on Linux `sessionhost.Ensure` always starts the host as the transient unit
  `watchtower-session-host` (`systemd-run --user --collect --quiet --property=UMask=0077`, `--setenv` of `PATH` and the
  socket override only), never a detached child; a failure is `ErrNoUserManager` with class `no_user_bus` |
  `not_found` | `exit_<code>`, and `session start` fails "the session host is not running: no systemd user manager
  (<class>)". darwin keeps Plan 1b's detached spawn (the LaunchAgent sets `AbandonProcessGroup`).
- **`watchtower service install|uninstall|status`** (`internal/service`): systemd user unit `watchtower.service`
  (`ExecStart=<exe> sync --daemon`, `Restart=on-failure`, `UMask=0077`, only `PATH`) or the LaunchAgent
  `com.watchtower.daemon` (stdout/stderr `/dev/null`, `gui/<uid>` else `user/<uid>`); goldens in
  `internal/service/testdata`. Install: agent marker refused, desktop host refused, `systemctl --user show-environment`
  must work, `initWorkspace(…, headless)`, `hub enable`, unit written only when it differs, linger hint (never runs
  `sudo`). `--json` keys `manager`, `installed`, `running`, `linger` (null on darwin or without `loginctl`).
  `workspace init --headless` turns off every non-core feature with a `ConfigKey` in a config it creates.
- **Terminal pairing**: `hub pair` without `--json` (`cmd/hub_pair_tty.go`, `internal/termqr` over
  `github.com/skip2/go-qrcode`, ask #881) prints a half-block QR, the link and expiry, the pinned SAS prompt
  `Confirm code 1234 on your phone? [y/N] `; needs stdin and stdout terminals (exit 2 otherwise); phone strings pass
  `sanitizeForTerminal`. Copy reviewed in `docs/design/mockups/go-hub/hub-pair-terminal.html` (ask #883).
- **Recording switch** (protocol §7.7, §9): see v1 limits; a Linux host never has `desktop_seen_at`, so it always
  publishes `capabilities.recordings: "off"` (`hub desktop heartbeat` is refused off darwin).
- **Builds**: `.github/workflows/linux-build.yml` on native `ubuntu-22.04` / `ubuntu-22.04-arm` (glibc floor 2.35,
  `scripts/check-glibc.sh`, `libcrypto.so.3`) → `watchtower-<v>-linux-<arch>.tar.gz` + `.sha256`; `build-app.sh` adds
  `Watchtower-CLI-<v>-arm64.zip` after notarization. Supported Linux: 64-bit, glibc ≥ 2.35, `libssl3`.
- **Short link retry after pairing** (`internal/hub/runtime.go`): a link change (a phone linked or unlinked) opens a
  window in which the link check runs every 2 s (`linkSoonEvery`) for at most 2 min (`linkSoonFor`) until every linked
  phone holds the hub in a slot — `SLOT_ADDED` is best effort, so otherwise a missed one waited for the next
  minute-long `linkEvery`. Each tick reads `get_account_state` first — while the hub is unvouched through
  `accountReader`, so at most one real read per 30 s (`unvouchedPoll`); once vouched (a second phone joining) the 2 s
  reads are allowed. The full link check (keyboxes, readers, subscriptions, a pass) runs only on the window's first
  tick and when the slotted set changed. When the window settles or runs out, `PayingWatch` re-reads, so a paused
  headless hub resumes as soon as a paying phone is there. A first admission normally comes by `SLOT_ADDED` at once.
- **Owner verbs** (AGENT-07 changelog, ask #827): `hub …` and `service …` writes are refused under every agent marker
  and confirmed by the terminal; the Desktop-confirmed gestures stay refused on Linux.

### Known limits (phase 2)

- Desktop detection looks only at the two app paths and `MobileHub/`: an app elsewhere, or installed but never run, is
  not seen (owner ruling after ask #827).
- Phase 3 does not migrate a CLI-only Mac's `<data root>/.hub` into the desktop hub; its phones link again.
- A Linux host without a systemd user manager is not supported (`service install` refuses, `session start` fails).
- A CLI-only Mac runs the daemon only after a GUI login (LaunchAgent; no linger equivalent without sudo, ask #881).
- The Kit phone's `vouch_hub` (App Attest assertion) is the relay client spec's; the Go phone emulator sends none
  (the stand runs with attestation off), so a real phone vouching is first checked at the Task 13 device gate.
- `SLOT_ADDED` is best effort: a hub whose socket was closed at that moment learns of its slot from a poll, at most
  every 30 s during the short link retry and about once a minute after it (the link backstop).
