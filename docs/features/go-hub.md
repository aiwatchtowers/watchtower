# Go hub (phase 1 core on the relay, phase 2 headless hosts, phase 3 the Mac, phase 4 pushes and measurements)

The phone hub rewritten in Go and run by the daemon: it links phones, applies their actions in order, publishes the
slices on change and starts, types into and stops workbench sessions through `watchtower session-host`. In phase 1 it
runs **only** in a separate `hubtest-*` test workspace behind environment variables. Phase 2 runs it live on headless
hosts — Linux and a Mac without the app ("Phase 2 — headless hosts" below). Phase 3 moves the Mac onto it ("Phase 3 —
the Mac on the Go hub" below) and deletes the Swift hub that lived in the Desktop: since go hub plan 3 Task 24 the Go
hub is the only hub. Phase 4 adds pushes over the relay, the Desktop's Relay indicators and hub-side latency samples
("Phase 4 — pushes, indicators, measurements" below). The phone-facing map of all of it is
[mobile-companion.md](mobile-companion.md).

- Spec: [`docs/superpowers/specs/2026-10-31-go-hub-design.md`](../superpowers/specs/2026-10-31-go-hub-design.md)
  (approved, ask #819). Phone ↔ hub protocol:
  [`docs/superpowers/specs/2026-10-31-hub-phone-protocol-design.md`](../superpowers/specs/2026-10-31-hub-phone-protocol-design.md)
  (approved, ask #834).
- Plans: phase 1 [1a](../superpowers/plans/2026-10-31-go-hub-phase-1.md) and
  [1b](../superpowers/plans/2026-10-31-go-hub-phase-1b.md); phase 2 — headless hosts
  ([`2026-10-31-go-hub-phase-2.md`](../superpowers/plans/2026-10-31-go-hub-phase-2.md), approved ask #838); phase 3 —
  the Mac on the Go hub ([`2026-10-31-go-hub-phase-3.md`](../superpowers/plans/2026-10-31-go-hub-phase-3.md), approved
  ask #856); phase 4 — pushes and measurements ([`2026-10-31-go-hub-phase-4.md`](../superpowers/plans/2026-10-31-go-hub-phase-4.md);
  owner decisions ask #864, review asks #866/#872/#875/#877, answers #966/#968/#970).
- Board: umbrella #1284, phase 1 #1285.

## Architecture

One runtime (`internal/hub`, `Run`) inside the daemon joins these packages:

| Package | What it is |
|---|---|
| `internal/hub/secure` | The one sealing choke point: envelopes (X25519/Ed25519/HKDF/ChaCha20-Poly1305/HPKE, the Swift `SecureTransport`'s twin), wire record names, keyboxes, asset encryption, the four-digit SAS. Everything that leaves the hub is a `secure.Record` from the `Sealer`; the transports refuse anything else. Pinned by the shared Kit E2E vectors (`make e2e-vectors`). |
| `internal/hub/state` | The sidecar `hubstate.db` (own goose migrations, below), the hub lock `hub.lock`, the stored rows (devices, ledger, control queue, held actions, zone tokens, slice hashes, milestones, recording jobs). |
| `internal/hub/identity` | The hub's keys (`hub_sig`, `hub_kx`, wrap key) in a 0600 file `<hub dir>/identity.key` in phase 1; the keyring (epochs, `K_data`/`K_alert`, the per-phone relay keys), wiped when the hub stops. |
| `internal/hub/transport` | The `Transport` seam (`Write`/`Changes`/`Delete`, `Expect` preconditions, zones), `relay` — the hosted relay client (the relay's Go client and generated proto vendored by `make relay-go`, pinned in `transport/relay/VERSION`) — `memfake`, the in-memory relay/CloudKit stand-in for tests, and `cloudkit` (phase 3) — the client of `WatchtowerCloudBridge.app` over `<hub dir>/bridge.sock` (`bridge.proto`/`bridgepb`, frames pinned by `testdata/frames.json` for the Swift bridge; runtime zone names mapped onto `DataZone-<hub_id>`/`RelayZone-<hub_id>`, every phone on the one shared mailbox `relay/<relay id>/*`; the bridge's generation in `<hub dir>/bridge.generation` so a lost `bridge.db` resets cursors and refuses old tags), its `Supervisor` and the `bridgefake` test bridge. |
| `internal/hub/link` | Linking: link codes, the pair zone hello, the awaiting keybox, the SAS confirmation (`Confirm(device, code, ok)`), grants (`typing`, `permissions`, `start_sessions`), unlink and the revoke hook; a linked phone's `device` record naming its relay id with the `relay_auth` key's proof (`VerifyRelayIDProof`, relay client Phase 3b Task 23) sets `devices.relay_device_id`, takes the id (with its admission stamp and any relay lapse) off any other row (ask #1005; a hello's unproven id is stored only when no other row holds it), clears the phone's own admission stamp, and `OnRelayIDNamed` makes the runtime run the link upkeep (`set_hub_readers`) and read the account state at once. |
| `internal/hub/actions` | The processor (ordered actions per phone by `action_seq`: hold ahead of a gap, one `resend_from` per gap (asked again once the ask is 10 minutes old and another action is read ahead of it, #1498), `skip_to`, the exactly-once ledger, `received`/final echoes, the legacy unordered path, controls, and the phone's `device-<id>` record through `link.Center.ApplyDeviceRecord`, on CloudKit's shared `RelayZone` and, since G1, in its relay mailbox with no creator check, see `relay-client.md`) and the dispatcher; the hosted relay keeps one mailbox per phone, read drain-then-read per phone as in phase 1 (a zone event reads only the mailbox it names, see Phase 4 → Relay ops per action), while the shared `RelayZone` (`actions/shared.go`) is read once per pass with every record routed to the phone its envelope's sender names (every linked phone with or without a relay id; a name naming another device than its sender is dropped as `sender_mismatch`; the hub's own records go to the phone whose key opens them; `control_queue` keyed `<zone>@<device>`, moved when a phone's mailbox changes shape; a failed phone's records wait for the next pass with the zone token held back; only a record whose own content fails is struck, and it is passed over after `MaxRecordStrikes` = 3 failures over at least `StrikeWindow` = 10 min — a store or transport error never strikes); `actions/handlers` holds every action handler (asks, board, session start/stop, session input and Interrupt, permission answers, chat/report requests, recording uploads). |
| `internal/hub/slices` | The publisher (hash per record, debounced saves with a 60 s full diff — only the kinds an applied phone action nudges (`PublishNow`) skip the debounce; they are still held by the transport spacing and by a failed save's retry (the backoff, or the relay's `retry_after_s` after RATE_LIMITED, capped at `RetryRateLimitedMax` 60 s); a held kind keeps its time across the periodic full diff and Resume's full diff, which cover only the kinds not held —, the 900 KB guard, heartbeat), the change watch (`data_version` poll: 250 ms while a phone was in touch within the last 10 min (`ActiveWindow`), else 1 s; nudges from handlers and the session-state lane) and `slices/sources`, one source per slice kind. |
| `internal/hub/alerts` (phase 4) | The pusher: work alerts to the paying phones over the relay's `send_alert`, at most once per (alert key, phone), with the `alert_pushes` ledger (below). |
| `internal/hub/measure` (phase 4) | `Recorder`: content-free latency samples (read → applied → slice saved) into `latency_samples`. |
| `internal/hub/platform` | Darwin/Linux specifics: the owner-away signal, keeping the machine awake, and `PeerUID` (the unix-socket peer check of the control socket and the bridge client). |
| `WatchtowerDesktop/Sources/CloudBridgeCore` + `WatchtowerCloudBridge` (phase 3) | `WatchtowerCloudBridge.app`, the signed `LSUIElement` helper at `Watchtower.app/Contents/Helpers/` (bundle id `com.watchtower.desktop.cloudbridge`, its own provisioning profile `WATCHTOWER_BRIDGE_PROFILE` — required by a release build, left out with a warning otherwise — checked by `scripts/check-bridge-signing.sh`): serves `--socket <hub dir>/bridge.sock` (0600, peer uid checked, Hello first, the hub's two zones only, assets read from `<hub dir>/assets` and downloads written under `<hub dir>/downloads` only, a refused frame answered `bad_request` and the connection closed, a late answer to a closed connection dropped), hand-coded frames (`BridgeFrames.swift`, pinned by `frames.json`), `BridgeTagMap` in `<hub dir>/cloudkit/bridge.db` (change tag → `tag_seq`, server change token → cursor, the `generation` minted with the file; another generation's cursor or tag is `token_expired`), the private database through the `BridgeDatabase` seam: conditional saves as `.ifServerRecordUnchanged` with the last known system fields (a conflict carries the server copy), conditional deletes checked against one read of the batch (not atomic — the hub deletes conditionally only write-once records and its own echoes), change feeds without assets (a relay record's name is its `asset_id`; `Download` fetches the asset) and failed whole when one record fails; the share code moved from the Swift hub's `ShareService` (`CloudKitZoneShares`, which `CloudKitShareService` wraps until the Swift hub goes; `EnsureShares` creates the zones first); silent pushes → `Event{pull_now}` through its own database subscription `watchtower-bridge-db-<hub_id>` (the phone's `ask-alert-<hub_id>` is never touched); exit after 10 minutes without the daemon. It links `WatchtowerSync` and GRDB only and references no sealing, opening or key type nor an entry point that reaches one (`CloudBridgeTests.testBridgeNeverOpensEnvelopes`). |
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
| `hub status` | `state` (`off`, `starting`, `running`, `paused`), `reason` (`disabled`, `policy_off`, `locked`, `not_test_workspace`, `sidecar_unreadable`, `not_admitted`, `relay_unreachable`, `start_failed`; phase 2: `desktop_host`, `no_relay_origin`, `run_dir_unusable`, `needs_relay`, `not_vouched`, `vouch_revoked`; phase 3: `no_icloud` with `paused` on a CloudKit desktop host), `hub_id`, `relay_device_id`, `transport`, `impl`, `dir`, `phones`, `host` (`desktop`/`headless`), `mode` (`test`/`live`, empty = off), `recordings` (`on`/`off`); phase 3: `adoption` (`none`, `in_progress`, `failed`, `done`), `bridge` (`running`, `restarting`, `unavailable`; "" off a desktop host), `identity` (`keychain`/`file`, "" = not known), `switched_at` (RFC 3339, "" = never), `switched_by` (a device id or `entitlement_expired`), `off_delete` {`state` (`ok`/`pending`/`failed` while the owner's switch is off, "" while on: the owner's off deletes the records the hub published, as POLICY-03's wipe, through the running transports before the hub stops, then retried while off from 1 min doubling to 1 h while records stay; it removes the staged assets (`<hub dir>/assets` and the `slice_assets` descriptors an adoption brought, also on an iCloud account change; a plain stop keeps them); and it unlinks every phone, as the Swift hub's off did (owner, ask #956): `supervisor.unlinkForOff` runs `hub unlink`'s offline path for each linked phone (row and grants gone, keybox read revoked, epoch rotated) and refuses each waiting one, at every reconcile while the switch is written off (`0`; read again under the lock `hub enable` also takes; one phone failing does not stop the rest), so turning on again needs a fresh pairing; the hub's identity key stays, as the Swift hub's Keychain identity did. The policy's off never unlinks), `at` (last try, RFC 3339)}, `transcriber` (a Desktop heartbeat ever arrived: recordings can go on), `cloudkit` {`account` (bridge account state, "" = not read), `throttled_since` (RFC 3339, "" = not throttled), `signed` (a desktop host's build has the bridge and its entitlement)}, `kept_recordings` (absent at 0), `name` (the name phones show: `hub name`'s value, else the short host name; Settings → Mobile's Mac name row); phase 4: `relay` (below), `paying_phones`, `mailbox_full_phones` |
| `hub phones` | `device_id`, `name`, `scope`, `linked_at`, `typing_allowed`, `typing_requested`, `permissions_allowed`, `permissions_requested`, `start_sessions_allowed`, `start_sessions_granted`, `ordered`, `last_applied_action_seq`, `transport`; phase 4: `paying` (true, false, or null unless the hub runs on the relay and knows the account state), `undelivered` (this Mac's side: held actions plus 1 for an open gap), `mailbox_full`, `alerts` ("" or the last outcome class of 7 days) — each null when the read behind it failed (a stderr warning; the phones are still listed) |
| `hub diagnostics [--days 1..7]` (phase 4, `cmd/hub_diagnostics.go`; reads the sidecar through `state.OpenReadOnly`, no hub needed; no sidecar = no rows) | `window_days`, `rows` [{`step` (`read_applied`, `applied_saved`, `read_saved`), `transport` (`cloudkit`, `relay`), `p50_ms`, `p90_ms`, `samples`}] (nearest rank), `push_overflow_expired` |
| `hub unlink <device>` | `device_id`, `unlinked` |
| `hub allow <device> typing\|permissions\|start_sessions [--revoke]` | `device_id`, `grant`, `allowed` |
| `hub name <name>` | `name` |
| `hub enable` / `hub disable` | `enabled` |
| `hub pair [--stream]` | JSON lines: `{event: qr, url, expires_at}`, `{event: waiting}`, `{event: sas, device_id, name, code}`, `{event: linked, device_id}`, `{event: refused, reason}`; the owner's `{confirm: true\|false}` on stdin |
| `hub desktop heartbeat` (darwin only) | `desktop_at` (the socket op's answer also carries `phone_contact_at`, RFC 3339, when a hub runs and a phone was ever in touch: this run's last admitted phone contact (an action past the gates, or a linked phone's device record at its `seen_at`, never later than now; a refused action or an unlink is none), else `hub_meta.phone_contact_at` stored each daemon cycle — Desktop's keep-awake input, Task 23) |
| `hub recordings on\|off` (owner; `on` refused "this host has no transcriber" before any Desktop heartbeat — with `--json` the refusal is exit 0 with `stored: false` and `error: no_transcriber`) | `recordings`, `stored`, `error` (refusals only) |
| `hub recording claim --upload <id>` (a failed job claims again for the owner's Retry; `done` and `hub_moved` never) | `upload_id`, `audio_path`, `status` |
| `hub recording list` (read only; refused under an agent marker) | `ready` (false: no queue to read yet) and `jobs`, each `upload_id`, `status`, `phase`, `percent`, `audio_path`, `event_id`, `started_at`, `error_class` |
| `hub recording finish --upload <id> [--transcript N] [--error <class>]` | `upload_id`, `status`, `transcript_id` |
| `hub recording discard --upload <id>` (owner; phase 3 Task 23: a `failed` job only, else `job_state`; checks the status and deletes the row in one write transaction, then removes `<recordings>/<upload_id>.m4a` (a claim that came first wins), through the running hub's `recording_discard` op so the phone's `recording_job` slice drops it) | `upload_id`, `discarded` |
| `hub recording progress --upload <id> --phase transcribing\|diarizing\|summarizing [--percent N]` (tests and the lock-free path; Desktop uses the socket op) | `upload_id`, `status`, `phase`, `percent` |
| `service install\|uninstall\|status` (phase 2, `cmd/service.go`; install/uninstall are owner verbs) | `manager`, `installed`, `running`, `linger` (null on darwin or without `loginctl`) |

`watchtower workbench session start --workbench N [--target T] [--agent claude|codex] [--place folder|worktree|auto]
[--title T] [--automation-run R] [--brief-stdin] --json` answers at once (instant start, `session_id`, `state`,
`folder_path`, `worktree_branch`) and a detached hidden `workbench session finish` places and launches the row in
`session-host`. The first prompt comes on stdin only (`--brief-stdin`) and reaches the finish over an inherited pipe. A
missing agent binary answers exit 3 with `{"error":"agent_not_found","agent":"…"}` and writes no row. The finish holds
the workbench's placement lock (`<workspace>/workbench-<id>.place.lock`, `sessionstart.PlacementLockPath`; the
Desktop's own launch path takes the same flock) from the place decision until the run is in the host, at most 60 s
(then the row fails with "another start of this workbench is still placing"). It writes the owner's line about the
place on the row (`terminal_sessions.start_notice`, migration 00184), fails a row it could not move into its worktree
with `Could not move the session into its worktree: …` instead of deleting it, and watches the launch 3 s for an
exit 127 (`<agent> was not found`). The Desktop's reasons are pinned by `internal/sessionstart/testdata/desktop_contract.json`.
**Migration numbers (merges of main, 2026-11-09 and 2026-11-10).** The branch's `start_notice` and `upload_id`
migrations were first numbered 00169/00170, then 00179/00180; main took both pairs (`llm_call_attempts`/
`daily_digest_attempt`, then `review_overview_parts`/`review_reviewer_threads`), so they are now 00184/00185. A dev
database that ran a branch build with an old pair recorded that pair under the branch's names, so main's migrations
of those numbers are skipped and 00184 fails with "duplicate column". Repair (on a backup copy, then reopen with a
current build; a fresh database works too): `ALTER TABLE terminal_sessions DROP COLUMN start_notice; ALTER TABLE
pending_transcripts DROP COLUMN upload_id;` then `DELETE FROM goose_db_version WHERE version_id IN (169, 170);` for
a database from the first branch build, or `IN (179, 180)` for one from the second. No release tag ever shipped the
old numbers.
`workbench session stop --session N` is the host's Stop request (`session_id`, `stopped`). Both refuse another workbench
inside an agent's terminal session.

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
- `00009_recording_origin` — `recording_jobs.event_id` (the calendar event the phone recorded for, an opaque id) and
  `started_at` (REAL), so Desktop links the transcript and rebuilds the phone's title (phase 3 Task 17); never the
  upload's `title_hint` (content).
- `00010_switch_epochs` — `hub_epochs.reason` (`age`, `cap`, `unlink`, `manual`, `transport_switch`) and
  `retire_after`; `devices.relay_lapsed_at`, `relay_skip_before`, `relay_skip_seq` (a lapsed phone's pre-lapse relay
  actions are never applied later, sim rule 16).
- `00011_latency_samples` (phase 4) — `latency_samples(at, transport, step, ms)` and its `at` index: a time, two
  enums and a duration, no id or kind.
- `00012_alert_pushes` (phase 4) — `alert_pushes(alert_key, device_id, outcome, reason, attempts, first_at,
  settled_at)`, primary key (alert key, device): ids, counters, timestamps and classes only.
- `00013_alert_pushes_settled_index` (phase 4) — index on `alert_pushes.settled_at` for the status reads.
- `00015_resend_requested_at` — `devices.resend_requested_at` (REAL, NULL when not known; a re-link clears it): when the
  gap was last asked, so an ask lost for good is asked again (#1498).

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
     window slot, never reopened by an `open_existing` start) and `display_over` (`[{id, run, reported_at}]`, the background counts the Desktop shows over,
     #411; a count reads Stopped only while the row still holds that run start — null = not live — and that
     `agent_background_at`, as the Swift `ShownOverCount`), each at most 10 000 (`too_many_ids` beyond). In memory
     only; ignored while the Desktop heartbeat is stale (> 90 s), dropped when it was sent before that. The
     `desktop_heartbeat` answer carries `view_needed: true` while the hub holds no current view (never sent, or
     dropped); Desktop sends the view at its start, on every change and on `view_needed`. A stale → fresh heartbeat,
     and a heartbeat going stale, republish the view's slices.
   - `recording_progress` (`upload`, `phase`, `percent`): the `recording_job` slice then reads `transcribing` with its
     percent, `diarizing` or `summarizing`, as the Swift slice; a claimed job with no phase yet reads `queued` (it
     waits in the Mac's transcriber queue, as the Swift hub's job did).
   - `recording_claim`'s answer carries `audio_path` (Desktop never derives it) and the job's origin, `event_id` and
     `started_at` (Unix seconds).

   **Done (phase 3 Task 17): the Desktop recording queue.** `PhoneRecordingQueue` (beside the Swift hub's
   `PhoneRecordingJobs` until Task 24) claims a job on `recording_queued` and on a rescan of `hub recording list
   --json` (`{ready, jobs}`; a not-ready answer is skipped, an empty one erases nothing) at every watch snapshot,
   ingests the audio through `MeetingRecorderCenter.ingestPhoneRecording`, follows the transcriber through
   `addJobObserver` into `recording_progress` and finishes with the transcript or a class: `no_speech`,
   `transcription_failed`, `not_audio`, `unreadable`, `ingest_failed`, `missing_audio`. **The hub's audio is the only
   copy** (the phone deleted its own on `received`): Desktop removes it only after the transcript is saved; every
   failure keeps it until the hub's 31-day prune, which now also removes it for a job failed with one of these
   classes. `unreadable` and `ingest_failed` (disk full, a failed copy, cancellation) are reported and tried again
   with a backoff (30 s doubling to 30 min); a database not open yet and a calendar read error are tried again
   unreported (never saved ad-hoc on an error); `not_audio` keeps the file for the owner (a Mac-side Retry/discard
   control is Task 23's). The phone's texts (`failureTexts`, pinned by `TestRecordingFailureTextsPinned`; Swift
   `testFailureClassesPinned` pins the classes) never ask it to send the recording again. Only a job failed with one
   of these classes claims again (`state.DesktopFailureClasses`); `hub_moved`, an adopted Swift failure and `done`
   stay terminal. **Exactly once:** the upload is remembered as `ingesting` before the ingest starts, and the
   ingest's reservation keeps the upload id (`pending_transcripts.upload_id`, migration 00185), so after a crash a
   claimed job is matched to its reservation (`phoneRecording(forUpload:)`) instead of being ingested again;
   unreadable bookkeeping matches claimed jobs by upload id only and leaves an unmatched one alone. The uploads it
   took (ids, the Mac's recording path, the hub's audio path, an unsent finish) are remembered in the app's
   defaults. The title comes back
   from the origin, never stored: an `event_id` this Mac's calendar has links the transcript and takes the event's
   title (the phone's meeting title); one it lacks saves ad-hoc and untitled (the Swift hub dropped the event too but
   kept `title_hint` — the one remaining gap); no event is the phone's voice note, `Voice note — d MMM, HH:mm` from
   `started_at` (`PhoneRecordingQueue.voiceNoteTitle`, pinned), formatted in the Mac's time zone (the phone uses its
   own; they differ only when the two are set to different zones). An `event_id` is stored only in a calendar id's
   shape (`[A-Za-z0-9_.:@-]`, at most 256 bytes), so it cannot carry free text.
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

## Phase 3 — the Mac on the Go hub

Plan [`2026-10-31-go-hub-phase-3.md`](../superpowers/plans/2026-10-31-go-hub-phase-3.md) (approved ask #856; owner
decisions asks #843, #851, #956; the plan's Global Constraints are the contract).

- **Desktop live mode.** On a desktop host the daemon runs the hub in `<config.DataRoot()>/.hub` (0700, files 0600).
  Never two hubs: it starts on real data only once adoption finished (`hub_meta.adopted_at`) or when the Mac had no
  Swift hub state and the owner turned Mobile on. A `MobileHub/` that appears after `adopted_at` is logged and never
  read, imported or deleted.
- **CloudKit bridge.** `WatchtowerCloudBridge.app` (an `LSUIElement` helper the daemon launches directly and restarts
  with backoff 1 s → 60 s) carries sealed envelopes and metadata over `<hub dir>/bridge.sock` (0600, peer UID
  checked, u32 BE length ‖ protobuf, 4 MiB max); assets travel as file paths only. It holds no hub key and opens no
  envelope. Its CloudKit state is `<hub dir>/cloudkit/`. It keeps running while the hub is on the relay, to poll the
  CloudKit mailboxes for a switch back (decision 4). One frame's saves or deletes reach CloudKit in modify requests of
  at most 200 records and about 1 MiB (`CloudKitBridgeCloud.batches`); a request CloudKit still refuses as a whole
  (`limitExceeded`) is halved and each half sent again, and only a record refused alone is answered
  `record_too_large`, for that item alone (#1745: a 4 MiB frame in one request failed every publish cycle). A
  request that fails otherwise after earlier ones went through keeps their results and refuses the rest with its
  class; a failure before anything went through still fails the whole call.
- **Adoption** (`hub adopt`). Desktop's `HubAdoptionDriver` reads the state only through `hub adopt --status --json`,
  hands the settings over on stdin (`--settings-stdin`), then the keys on stdin (`--keys-stdin`, a separate call),
  deletes its Keychain items, and confirms (`--confirm-deleted`). Go derives the Swift directory itself and leaves
  `MobileHub/` empty but for `MOVED` (`hub_impl=go\nmoved_to=<hub dir>\n`). A phone recording mid-transcription
  becomes one `failed` job with class `hub_moved` (decision 3). Until `--confirm-deleted`, the Swift identity stays in
  the Desktop's Keychain items, which Reset All Data does not remove (the guide's privacy page says so).
  **Set up Mobile again** (`hub adopt --set-aside`, after `no_keys`) writes `MOVED` and moves the Swift files into
  `MobileHub/set-aside-<UTC time>/`: kept, never imported or deleted.
- **Transport switch.** Only a person switches: a paying phone's `transport_switch`, or `entitlement_expired`. A switch
  toward the relay waits at least 5 minutes after the previous one; a switch toward CloudKit is immediate. Every
  accepted switch rotates the keyring. A notice is left in the transport being left (decision 1), and old keys are
  kept for 7 days (decision 2). `hub_meta.transport` is `cloudkit|relay`.
- **A phone's relay id from its `device` record** (relay client Phase 3b Task 23, R22). An iCloud-linked phone that
  upgrades names its `relay_device_id` in its own `device` record with the `relay_auth` key's proof; the hub stores it
  only when the proof holds, moves the id off any other row that holds it (ask #1005), then counts the phone as paying
  and a reader. See
  [relay-client.md](relay-client.md), "Phase 3b".
- **Desktop's watch events** (`desktop_watch`, besides `status`, `recording_queued`, `pair` and `switched`):
  `typing_request` (`device_id`, `name`: a linked phone newly asks to type, once per request; Desktop posts the
  PROJ-16 notice "Allow "<name>" to type into Claude Code sessions?" while the app is in the background),
  `bring_forward` (`workbench_id`, `session_id`: an applied phone start with `bring_forward`; Desktop brings the
  workbench forward and shows the session) and `devices_changed` (no fields: a link, an unlink from either side or a
  grant changed; Desktop reads `hub status` again, Learn's "iPhone paired"). A headless host has no Desktop
  watching: these events reach nobody and `bring_forward` moves nothing.
- **Desktop never opens `hubstate.db`** (decision 5): every Desktop read is `hub … --json` or the control socket
  (`HubCenter`, `MobileSettingsModel`, `PhoneRecordingQueue`, `HubKeepAwake`). Guard:
  `WatchtowerDesktop/Tests/Core/DesktopNeverOpensTheSidecarTests.swift` refuses every Swift string literal under
  `WatchtowerDesktop/Sources` that names `hubstate.db` or `MobileHub`, with no exception.
- **The Swift hub is deleted** (Task 24). `Services/MobileHub/`, `MobileHubMovedGuard`, `OwnerAwayCenter`/`OwnerAwayPolicy`
  (Go: `internal/hub/platform`, `TestAwayFromThePolicy`) and the tray's CloudKit push forwarding are gone. Each Swift
  hub test is mapped in the Task 24 PR (spec §13 "Ported guards"): most have a Go twin, the obsolete ones are listed
  with their reasons. The two POLICY-03 guards on the `MobileSync = off` wipe of a Swift state not yet handed over
  (`testRetiredOffWipesAPendingSwiftStateAndKeepsSetting`, `testRetiredWipeNeverCreatesOrRepairsKeys`) are retired with no
  Go twin (owner decision, ask #969 Q1): nothing wipes what the Swift hub published to iCloud before the hand-over; those
  records stay in iCloud until the owner handles them (v1 limit). `HubKeyringVectorTests` stays as a standalone ChaChaPoly check of the Swift
  vector `internal/hub/identity/testdata/swift-keyring.json`. Learn's "iPhone paired" signal reads `phones` from
  `hub status --json`.

### The identity store on a desktop host

`identity.ForDesktopHost(st, dir, identity.KeychainUsable)` picks the store once and records it in `hub_meta`
`identity_store` (`keychain` | `file`); later starts follow the record and never re-decide. `KeychainStore` keeps the whole
identity as one generic-password item (service `com.watchtower.hub`, account `identity`; the staged copy is a second item,
`identity.staged`), its data one blob in the identity file's format (`WTHUBID` + version byte, then the four raw keys),
never synchronizable, with every query set to fail instead of prompting. Save, SaveStaged and the promote's write are
each one `SecItemAdd`/`SecItemUpdate`; promote = write the live item from the staged blob, then delete the staged item,
so a crash in between leaves two equal items and a repeat finishes. A staged item that is missing or not a valid blob
reads as nothing staged (SaveStaged overwrites it) and `PromoteStaged` answers `identity.ErrNothingStaged` (wraps
`ErrNoIdentity`) without touching the live item; Task 16 treats it as done when the identity is already adopted. Items
are requested `AfterFirstUnlockThisDeviceOnly`, but the file-based login keychain keeps no accessibility class, so
nothing relies on it. `FileStore` gained the same staged trio (`identity.staged.key`, 0600; promote = one rename; a
malformed staged file is nothing staged too). The probe refuses every service starting with `com.watchtower` (any
case). `KeychainUsable` comes from the string ldflag
`identity.KeychainBuildFlag` (`-X` sets strings only); a plain `go build` defaults to the Keychain.

#### Keychain check (2026-11-01, Task 1 Step 1)

`scripts/hub-keychain-check.sh` (run from a plain Terminal; refuses under an agent marker) builds two `watchtower`
binaries of different versions, signs both as `scripts/build-app.sh` signs `Contents/MacOS/watchtower` (same identity
selection, identifier `watchtower`, hardened runtime, no entitlements), and runs the hidden owner-only
`hub keychain-probe write|read|delete` on a throwaway service: the older build writes, the newer build reads and
deletes, in Terminal and in a temporary user LaunchAgent.

Result on a real Mac (Developer ID identity, unlocked login keychain), both contexts:

| Step | Result |
|---|---|
| older build: write | ok |
| newer build: read | ok, no prompt |
| newer build: delete | `errSecInvalidOwnerEdit` (-25244) |

**Result: fail → file store.** The newer build may read the items (the login keychain's partition list trusts the
team id) but it is not their owner, so it cannot delete them: a hand-over finished by an updated build, an unlink-all
or a reset could not remove the old keys. The data-protection keychain, where `kSecAttrAccessible` would apply, is not
reachable: a binary without a `keychain-access-groups` entitlement gets `errSecMissingEntitlement` (-34018), and the
CLI has no provisioning profile of its own. Both `scripts/build-app.sh` and the `Makefile` therefore pass
`-X watchtower/internal/hub/identity.KeychainBuildFlag=false` (pinned by `scripts/tests/test-build-app-relay.sh`), so a
desktop host keeps its identity in `<hub dir>/identity.key` (0600), like a headless host (owner, ask #807). The guide's
privacy page says so.

## Phase 3 — the iCloud account (ask #969 Q3: as the Swift hub)

- **No usable account** (`no_account`, `restricted`, `temporarily_unavailable`, `no_entitlement`, as the bridge's
  `AccountStatus` reads it at start, each daemon cycle, every 10 minutes and on `Event{account_changed}`) holds the
  CloudKit side (`icloud.go`, hold reason `no_icloud`): CloudKit's processor reads nothing and, while CloudKit is the
  active transport, the publisher publishes nothing and no mailbox pass or share sweep runs. A desktop host on the relay
  goes on publishing there; only CloudKit's mailbox (the switch's standby poll) waits. The next read that finds the
  account available releases it: one full diff and one pass. An account not read yet holds nothing (the bridge
  starts after the hub, so each pass reads it again until a first answer). While
  CloudKit is the active transport the status reads `state: paused`, `reason: no_icloud` (the Swift hub showed itself
  unavailable, "No iCloud account is signed in"): `hub status` adds a line saying so and Settings → Mobile shows
  "Paused until iCloud is available on this Mac. It goes on by itself." above the account's own line. On the relay
  the status keeps `state: running`; the account shows in the `cloudkit` block either way.
- **An account change** (`Event{account_changed}`) and **a zone deleted on the server** (the bridge saw
  `zoneNotFound`/`userDeletedZone`, created the hub's zones again and sends `Event{zones_recreated}`, `frames.json`
  case `event_zones_recreated`) run `resetCloudKit` with CloudKit's processor and the publisher held (reason
  `cloudkit_reset`): `state.WipeSyncState` (the Swift `wipeSyncState`) deletes every `slice_state` row, forgets the
  unpublished work alerts of the current generation within the alert lifetime, bumps `sync_generation` and, for an
  account change only, deletes CloudKit's mailbox token (`zone_tokens` of `relay/<relay id>/*`; a zone deletion keeps
  it, the relay buffer survived); the staged assets go (`forgetStagedAssets`) and the resumed full diff republishes
  and restages everything. The exactly-once ledger, the hub id, `enabled_at` and the keys stay. On a desktop host
  whose active transport is the relay only the mailbox token is reset: the published state is the relay's, and a
  switch to CloudKit republishes under a new epoch anyway; a zone recreated there keeps the staged assets too (an
  account change still removes them). A wipe that fails keeps both held and is retried at each housekeeping run
  (daemon cycle, `houseEvery`) until it succeeds: released unwiped, the full diff would match the old hashes and
  publish nothing into the new zone (in memory: a restart in between forgets it). On an account change the wipe runs
  before the account is read again, and a pass follows at once. The account change still closes the old user's link
  (`link.Center.AccountChanged`). The bridge cannot tell which zone was missing, so a deleted RelayZone alone also
  republishes the data zone once. The bridge creates the zones lazily (on the first `zoneNotFound`), so the
  first-ever CloudKit save of a hub — and the first save into a new account's zones — also reads as a recreation and
  costs one extra full publish (v1 limit; telling a first creation apart needs state the bridge does not keep). No
  sidecar migration: the tables were all there.

### Phase 3 gate record (2026-11-03)

- **Automated (Task 25 Step 1), on `feature/go-hub`:** `make test`, `make lint-all`, `make kit-test`,
  `make mobile-test` (777 tests) and `make relay-interop` (5/5, relay at the pinned `VERSION`) pass. `make test-swift`
  passes class by class after two test-isolation fixes (#646: a pair test reset the inherited `--config` flag; #648:
  `HubDesktopEventsTests` wrote layouts to the runner's defaults). The Task 20 `/dev/entitlement` scenarios move to
  Task 27 with the rest of the switch.
- **Manual (Step 2, M1–M5 + the no-iCloud pause):** not run. The owner closed the check ask (#972) as not a priority
  now; the default taken is to run them on the owner's Mac before `feature/go-hub` merges into main. Until then
  adoption on a real Mac, the downgrade guard and the bridge with Desktop quit are covered by tests only.

## Phase 4 — pushes, indicators, measurements

Plan [`2026-10-31-go-hub-phase-4.md`](../superpowers/plans/2026-10-31-go-hub-phase-4.md) (relay pinned at `bcca870`,
re-checked in its Task 0; the plan's Global Constraints, Decisions and Known limits are the contract).

- **The push envelope** (`internal/hub/secure`, protocol §4.8). `Sealer.AlertPush(key, WorkAlertFields)` seals the
  `ask_alert-<key>` frame as class `alert` under `K_alert[current]`, signed, AAD wire name `alert-push`
  (`AlertPushWireName`) in the data zone. The frame is padded to the 1 KiB bucket (a 1172-byte envelope); a payload
  whose frame does not fit 1024 bytes has its body, then title, then workbench name (ask #968) clipped one grapheme
  cluster at a time with "…", `ErrAlertTooLarge` only when all three are empty and it still does not fit. The final
  bound is `AlertPushMaxEnvelope` = 3021 bytes (relay `MAX_PAYLOAD_BYTES` 4096 − the 67-byte APNs body, base64). The data-zone record keeps the full text (ask #864).
  `secure.WorkAlertFields` is the one JSON shape of the record and the push (the Kit's `WorkAlertPayload` keys).
  `secure.Push` has no exported constructor: only `AlertPush` makes one. Pinned by `go-sealed.json` case `alertPush`
  and the Kit's `GoSealedEnvelopeTests.testGoSealedAlertPushOpensWithAlertOpener`.
- **`send_alert`** (`transport.Alerts`, implemented by the relay transport only; `memfake` and `cloudkit` have none).
  `relay.Transport.SendAlert(ctx, phoneRelayID, secure.Push)` refuses an unsealed push before any I/O and sends the
  envelope only. On this op `NOT_FOUND` is `transport.ErrNoPushToken` and `UNSPECIFIED` "not implemented"
  `transport.ErrPushOff`; the rest maps through `MapError`; `relay.RetryAfter(err)` reads `retry_after_s`.
- **The pusher** (`internal/hub/alerts`, wired in `alerts_wiring.go`). The publisher calls
  `slices.Config.OnAlertSaved` once per alert key after its first successful save, only while the relay is the active
  transport (republishes and rotations never; on CloudKit the `sig-` signal path runs instead). `Pusher.Enqueue`
  writes a `pending` row for every target in one short transaction, then queues the sealed push in memory (64 per
  phone, `QueuePerPhone`; more settle `expired`/`overflow`); one sender per phone, the publisher never waits. Targets
  (`pushTargets`, `alerts.Eligible`): linked phones with a relay device id that the last account state holds in a
  paying slot and that the last accepted `set_hub_readers` names. Before every send, retries included, the owner-away
  input is read again (`platform.Away`; back at the Mac → `expired`/`owner_back`). Freshness 5 minutes from the first
  save (`Freshness`). `RATE_LIMITED`/`TRAFFIC_LIMIT_EXCEEDED` retry after `retry_after_s` (1 s default, 60 s cap), a
  relay-coded `UNAVAILABLE` on the next connect (`Pusher.Reconnected`) or after 30 s; `not_paying` and `forbidden`
  run one shared account refresh; `HUB_NOT_VOUCHED` is `forbidden` and the runtime's `noteNotVouched`. A request that
  may have reached the relay with no answer heard (interrupted by `Abandon`/`Stop`, the window's deadline, or a
  transport failure with no relay code) settles `expired`/`in_flight`: never resent, counted as received (ask #970).
  At start every `pending` row settles `expired`/`restart`. A switch toward CloudKit runs `Pusher.Abandon("switched")`
  and `Publisher.Resignal` with the keys it returns: unless the owner is back, each alert still open that some phone
  has not received is saved on CloudKit with its signal. Ledger rows are pruned after 7 days.
- **Outcome classes** (ledger, `hub phones` `alerts`, logs): `accepted` (the relay's `Ok`, not an APNs delivery),
  `no_token`, `not_paying`, `forbidden`, `push_off`, `too_large`, `expired` (reasons `freshness`, `owner_back`,
  `restart`, `switched`, `overflow`, `stopped`, `in_flight`), `failed`. Logs carry ids and classes only (FILES-01).
- **Relay health in the status file** (`relayhealth.go`, through `setStatus`, so every change emits the existing
  `status` watch event). `hub status --json` gains `relay` (absent with no relay origin): `state` `connected`,
  `connecting` or `unavailable` (no connection for 60 s, RC §9's threshold), `since`, `quota_hub` (set by a data-zone
  save refused as over quota, cleared by the next good one), `push_off` (case B: the relay has no push-config signal,
  so the line is set by a `push_off` answer and cleared only by a later `accepted`, `not_paying`, `too_large` or
  `no_token` for any phone, read from the ledger), `last_saved_at` (RFC 3339 rounded down to the minute, or ""). Also
  `paying_phones` (empty unless the relay is active; null = unknown — no hub, no account state yet, or forgotten after
  `HUB_NOT_VOUCHED`; never read as "nobody pays") and `mailbox_full_phones` (per phone, set by a refused write to that
  phone's mailbox and cleared only by a good write to it or by unlinking it, kept in `hub_meta` key
  `mailbox_full_phones`).
- **Latency samples** (`internal/hub/measure`, RC §10). `Recorder.Applied` for an action applied on its first read
  (a held action measures the phone's gap, not the hub) writes `read_applied`; the first save of one of its slice
  kinds whose read began after the apply, within `SaveWait` (60 s), writes `applied_saved` and `read_saved` together;
  waiting applies are in memory (256 at most). Batched once a second, never inside a pass transaction; pruned once a
  minute to 7 days and 20 000 rows. Nothing leaves the device; the 500 ms line reads the relay p50 of `read_saved`.
- **Desktop.** Settings → Mobile shows the Relay row (connection, push-off, storage-full lines) and per-phone lines
  (mailbox full, free phone on a relay hub, not applied on this Mac's side, notifications not set up / last alert sent
  to relay) from `hub status|phones --json` (`MobileHubCLI`, `MobileSettingsModel+Indicators.swift`), and
  **Diagnostics**, a read-only sheet over `hub diagnostics --days 7 --json` (`MobileDiagnosticsModel`). The strings
  and their tones are in mobile-companion.md → Hub → Desktop over the hub.

### Relay ops per action (ask #976)

The relay limits each device to 50 ops/s (burst 100). A full pass per mailbox event read every linked phone's mailbox,
and the hub's own echoes came back as events (the relay tells the writer too), so an applied action cost about six ops
and a burst of 8–10 actions/s ran into `rate_limited`. Now:

- **One mailbox per event.** `actions.Processor.PassEvent` reads only the phone's own mailbox the event names (its held
  actions next in line first, as Pass does), then writes the queues; an event for any other zone, the shared
  `RelayZone` or a transport that is not an `EventPuller` runs `Pass`. The runtime's 30 s backstop still runs `Pass`
  over every mailbox, and an event pass does not move its timer. So a phone whose mailbox read failed is read again at
  its own next event or the next backstop pass, not at another phone's event as before.
- **No read when the event says it all** (`relay.Transport.PullEvent`; zone seqs grow by one per write, so the seqs
  between the stored token and the event's `seq` are exactly the writes not read yet). Already read (`seq` ≤ token):
  nothing. Every seq after the token is one the hub's own `Save` got (`OwnWrites`; kept per zone in memory, at most
  256, forgotten once the token passes them; a restart forgets them and the hub reads again): the event pass does
  nothing at all (`PassReport.OwnEcho`: no read, no queue write, and the runtime neither stamps a phone contact nor
  kicks the other transport's poll); the token passes those seqs with the next read. Only the event's own seq is
  someone else's and the relay carried the record inline (≤ 64 KiB, one-record saves): that one-record page is
  applied, then the token moves. Anything else — another writer's seq in between, no inline record (a delete, a merged
  event, a large record), the resync marker (seq 0), a zone never read (token 0) — is `Pull` of that zone. An own
  write never stands for a write it may hide, and one whose event overtakes its `Save`'s answer is read, never
  skipped. A mailbox whose last read stopped on an error (a claim whose done transaction failed among them) is read
  with `Pull` at its next event, its own writes not skipped (`Processor.unread`), so the hub's own `received` echo of
  a begun action is read back and settled `outcome_unknown`. `transport.Event` carries `Seq` and `Inline`.
- **One save per mailbox.** `flushMailbox` writes the mailbox's queued echoes and controls in one `Save` (in queue
  order, at most 50 rows per call) and settles each row by its outcome as before. The queued echoes of one record (a
  held echo and the final one, a received echo and the final one) are folded into one row first — the last echo's
  content at its place, under the last one's precondition when it names a record version, else the latest one an
  earlier echo names — so one batch never writes a record twice and a partly written batch cannot leave an older echo
  over a newer one; the folded rows leave the queue with it. An echo that meets the hub's own older record is
  written over it in one more `Save`, together with every row after it that landed, so the phone's feed keeps the
  queue order; a conflict with the hub's own identical record means it landed in an earlier, partly written batch
  (done). A `Save` refused as a whole may have written part of the batch: nothing is settled, the first row is marked
  failed, and the next pass reads the mailbox before it writes again. A whole-batch refusal for good is retried row
  by row so only the refused row is dropped. The `received` echo of a claim still goes out before its handler runs.
- **relaytest** sends one `ZoneChanged` per write call and zone (the zone's last seq, the record inline only when the
  call wrote exactly that one record), to the writer too, as the relay does.

Measured with `TestMeasure_HubLatencyOverTheStand` (200 actions, local stand, hub ops counted on its HTTP client; the
1 s run includes the test's 1 s link and backstop cadence, about three reads and two other ops per second):

| Run | ops/action before → after | `changes` | `save` | `rate_limited` lines | failed passes | p50/p90 `read_saved` |
|---|---|---|---|---|---|---|
| back to back | 5.87 → 2.83 | 3.71 → 1.19 | 1.98 → 1.50 | 299 → 0 | 147 → 0 | 90/257 → 83/144 ms |
| back to back | 5.51 → 2.84 | 3.56 → 1.20 | 1.79 → 1.50 | 225 → 0 | 107 → 0 | 94/510 → 75/139 ms |
| 1 s gap | 11.44 → 9.40 | 6.22 → 4.19 | 3.07 → 3.07 | 0 → 0 | 0 → 0 | 10/11 → 9/11 ms |

### Known limits (phase 4)

- The push-off line appears only after a first `send_alert` and leaves with the 7-day prune.
- The local stand has no APNs: CI and local runs see only `push_off`; a real push needs relay staging with APNs and
  the phone's `register_push` and inline open (relay client spec Phase 4, plan Task 12).
- `accepted` is not a delivery: the relay keeps at most 4 alerts in flight per phone and cancels the oldest, and APNs
  may drop one.
- A save the relay refuses whole names every zone in its batch; the hub's mailbox writes save one mailbox's queue per
  call, so in practice only the refused phone is flagged.
- An alert raised before the first readers sync succeeded, or between a phone's admission and the next readers sync,
  is not pushed to that phone (it still reaches the replica).
- A crash during a switch toward CloudKit leaves queued pushes `pending`: they settle `expired`/`restart` at the next
  start and get no CloudKit signal.
- An alert sealed in an epoch the phone's alert material no longer holds does not open; the notification extension
  shows the generic notification.

## Relay key rotation (relay client Phase 5, ask #1066/#1067)

On a relay route the keyring rotates every 7 days (`relayRotationAge`; 90 days on iCloud). A phone's `epoch_ack.next_kx` is stored as `devices.kx_offer`/`kx_offer_epoch` (only on the relay, only while not lapsed); at the rotation the hub draws `hub_eph` per offering phone, seals the derived keys as `epoch_relay_keys`, clears `hub_eph`, and sends a keybox sealed to the offer (`KeyboxRecipient`, `relay_kx`/`previous_relay_kx`), in the data zone for timer rotations. A free phone gets a grant and no keys on the relay. Erasure runs only on epochs that began on the relay (`hub_epochs.on_relay`). Each republish after a rotation logs `hub: rotation republish: complete|interrupted|resumed, N records, B asset bytes, E envelope bytes, D s`. Limits: see relay-client.md "Phase 5 limits".
