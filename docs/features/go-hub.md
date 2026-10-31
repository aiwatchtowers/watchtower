# Go hub (phase 1 — the core on the relay, dev flag only)

The phone hub rewritten in Go and run by the daemon: it links phones, applies their actions in order, publishes the
slices on change and starts, types into and stops workbench sessions through `watchtower session-host`. In phase 1 it
runs **only** in a separate `hubtest-*` test workspace behind environment variables; the Swift hub in the Desktop
(`docs/features/mobile-companion.md`) is still the live hub. Phases 2–4 take it to headless hosts, move the Mac onto it
and delete the Swift hub.

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
| `internal/hub/transport` | The `Transport` seam (`Write`/`Changes`/`Delete`, `Expect` preconditions, zones), `relay` — the hosted relay client (the relay's Go client and generated proto vendored by `make relay-go`, pinned in `transport/relay/VERSION`) — and `memfake`, the in-memory relay/CloudKit stand-in for tests. |
| `internal/hub/link` | Linking: link codes, the pair zone hello, the awaiting keybox, the SAS confirmation (`Confirm(device, code, ok)`), grants (`typing`, `permissions`, `start_sessions`), unlink and the revoke hook. |
| `internal/hub/actions` | The processor (ordered actions per phone by `action_seq`: hold ahead of a gap, one `resend_from` per gap, `skip_to`, the exactly-once ledger, `received`/final echoes, the legacy unordered path, controls) and the dispatcher; `actions/handlers` holds every action handler (asks, board, session start/stop, session input and Interrupt, permission answers, chat/report requests, recording uploads). |
| `internal/hub/slices` | The publisher (hash per record, urgent/full ticks, the 900 KB guard, heartbeat), the change watch (`data_version` poll: 250 ms for 10 min after a change, else 1 s; nudges from handlers and the session-state lane) and `slices/sources`, one source per slice kind. |
| `internal/hub/platform` | Darwin/Linux specifics: the owner-away signal and keeping the machine awake. |
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
| `hub status` | `state`, `reason` (`disabled`, `policy_off`, `locked`, `not_test_workspace`, `sidecar_unreadable`, `not_admitted`, `relay_unreachable`, `start_failed`), `hub_id`, `relay_device_id`, `transport`, `impl`, `dir`, `phones` |
| `hub phones` | `device_id`, `name`, `scope`, `linked_at`, `typing_allowed`, `typing_requested`, `permissions_allowed`, `permissions_requested`, `start_sessions_allowed`, `start_sessions_granted`, `ordered`, `last_applied_action_seq`, `transport` |
| `hub unlink <device>` | `device_id`, `unlinked` |
| `hub allow <device> typing\|permissions\|start_sessions [--revoke]` | `device_id`, `grant`, `allowed` |
| `hub name <name>` | `name` |
| `hub enable` / `hub disable` | `enabled` |
| `hub pair [--stream]` | JSON lines: `{event: qr, url, expires_at}`, `{event: waiting}`, `{event: sas, device_id, name, code}`, `{event: linked, device_id}`, `{event: refused, reason}`; the owner's `{confirm: true\|false}` on stdin |
| `hub desktop heartbeat` | `desktop_at` |
| `hub recording claim --upload <id>` | `upload_id`, `audio_path`, `status` |
| `hub recording finish --upload <id> [--transcript N] [--error <class>]` | `upload_id`, `status`, `transcript_id` |

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
- No `service install` (phase 2); the hub runs inside `watchtower sync --daemon` only.
- Recording jobs are queued for Desktop (`hub recording claim|finish`); a host that never had a Desktop answers an
  upload `not_supported`.

## Linux behaviour

Every darwin-only piece on the daemon path and what a Linux host does instead (phase 2, Task 1 audit; each line
checked against the code named).

| Piece | darwin | Linux |
|---|---|---|
| `internal/sessionhost` socket (`DefaultSocket` → `socketDirFor`) | the user's temp folder (unchanged, `testdata/paths.json`) | `/run/user/<uid>` when it is a real folder owned by the uid with mode 0700, else `<data root>/.run` (created 0700, checked and tightened through one `O_NOFOLLOW` descriptor; a symlink, a file, another owner or a socket path too long for `sockaddr_un` → `run_dir_unusable`; a data root that cannot be determined fails before `/run/user` is tried); computed from the uid alone, no `XDG_RUNTIME_DIR`, never `/tmp` |
| `config.AppSupportDir` (`appSupportDirFor`) | `~/Library/Application Support/Watchtower` | `<data root>/.support`; `RecordingsDir`'s default follows (`<data root>/.support/recordings`, where a Linux host keeps none) |
| Hub control socket peer check (`peer_darwin.go` / `peer_linux.go`) | `LOCAL_PEERCRED` | `SO_PEERCRED`; a failed read closes the connection before any request (`TestControlSocketClosesWhenPeerCredentialsFail`); other OSes refuse every client (`peer_other.go`) |
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
3. **The phase 3 Desktop→hub inputs are deferred to phase 3**: the Desktop's Undo batch (sessions pending a PROJ-17
   delete), `displayOver`, and the owner-write notice from the history actor. Until then the phone may show a session
   that waits for an Undo on the Mac.
4. **The hub runs only in a `hubtest-*` test workspace** (`WATCHTOWER_HUB_TEST_WORKSPACE`) until phases 2 and 3 give it
   real hosts.
5. **The refusing session port.** Unless `WATCHTOWER_SESSION_HOST_SOCKET` is set the hub uses a port that refuses every
   session start, stop, line and Interrupt (no session host), so a test workspace never reaches the Desktop's host.

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
- Linux: the Go Test job of the PR's CI runs on ubuntu. A local `GOOS=linux go build` cannot run on a Mac (SQLCipher is
  cgo); phase 2 Task 2 adds a native arm64 CI job.
