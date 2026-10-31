# Go hub — Phase 3: the Mac on the Go hub (CloudKit bridge, adoption, Desktop over `hub …`, the transport switch) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Mac with the Desktop app runs its phone hub in the Go daemon: CloudKit through the signed `WatchtowerCloudBridge.app`, the Swift hub's state and keys adopted once and interrupt-safely (no phone re-pairs), Desktop's Settings → Mobile, New Session, composer, recordings and notices driven over `watchtower hub …` / the control socket / `session-host` v2, the transport switch both ways (sim rules 8–16) with an epoch per switch, and the Swift hub deleted.

**Architecture:** On top of Phase 1 (`internal/hub/…`, `session-host` v2, `internal/sessionstart`) and Phase 2's live mode (`hub.Resolve`, `hostkind`, `<data root>/.hub`, the recording switch). New Go: `internal/hub/transport/cloudkit` (bridge client implementing `transport.Transport` plus `Shares`/`Signals`; frames in `bridgepb`; `bridgefake` for tests; a supervisor in the hub runtime), the CloudKit shape in `actions` (one shared `RelayZone` routed by sender, `device-` records) and `link` (shares, public link, participants), `internal/hub/adopt` (one-time import of `MobileHub/` and the two-phase key hand-over), `identity.KeychainStore` (darwin cgo), `internal/hub/switcher` (dual transport, sim rules 8–16), Desktop inputs on the control socket (`desktop_view`, `recording_progress`, `desktop_watch`). New Swift: the `WatchtowerCloudBridge` executable target (wraps the Kit's `CloudKitTransport` and the share code of today's `ShareService`), `HubControlClient` + `HubCenter` (heartbeat, view, recording queue, status), the `session-host` v2 client in Desktop (`Deliver`, `Stop`), the one-time v1-host restart step, the adoption driver, and Settings → Mobile rebuilt; then `Services/MobileHub/` is deleted with a guard mapping.

**Tech Stack:** Go 1.26 with cgo on darwin (Security framework `SecItemAdd`/`SecItemCopyMatching`/`SecItemDelete`), `google.golang.org/protobuf` (already direct), `github.com/yuin/goldmark` (indirect → direct, Task 6); Swift 5.10 mode / Swift 6 toolchain: a new SwiftPM executable target `WatchtowerCloudBridge` in `WatchtowerDesktop/Package.swift` over `WatchtowerSync` (CloudKit, CKSyncEngine), `swift-protobuf` only if `Package.swift` already resolves it (else hand-coded frames from the `.proto`, decided in Task 4 Step 1 and pinned by the fixture), GRDB for Desktop's own DB only.

**Spec:** `docs/superpowers/specs/2026-10-31-go-hub-design.md` — §14 row 3 (this phase), §6.2 (bridge), §8 p. 4a (recordings, heartbeat) and p. 4b (composer on `Deliver`, the v1-host one-time restart), §11 (New Session through Go, requested stops), §12 / §12.1–§12.4 (adoption, never two hubs, keys and state, screens, what phones notice), §12a (contract), §13 (tests), Decisions. Protocol: `docs/superpowers/specs/2026-10-31-hub-phone-protocol-design.md` (approved, ask #834) §3.2, §3.4, §4.2, §5.4–§5.10, §7.5–§7.9, §9. Relay client spec (`docs/superpowers/specs/2026-10-29-relay-client-design.md`, "RC §N") §5 p. 10, §8, §9, §10 (Desktop rows). Relay contract: the relay repo's `sim/README.md` rules 8–16 and "Records in a phone's mailbox". Prerequisites: Plans 1a, 1b merged; Phase 2 Tasks 1, 3, 9 merged (host kind, `hub.Resolve`, `held_uploads`, recording switch). This plan builds on their **Produces** blocks only.

## External dependencies (ordered last)

| Blocker | What is missing | Tasks it blocks |
|---|---|---|
| **Relay client spec Phase 1 on the phone** (neighbour session) | The phone's ordered path on CloudKit: `action_seq`, `a-<DEVICE_ID>-<seq>` names, outbox, conditional writes (`ConditionalTransport` on CloudKit), echo deletes, `skip_to`, `epoch_ack`, control records in `RelayZone`, Not delivered. | Task 26 |
| **Relay client spec Phases 2–3 on the phone**, **relay ask #805** and **Phase 2 Task 10** (vouching) | Phone on the hosted relay, `transport_switch` from the phone UI, reaction to `transport_switched` (keybox inside, more than two epochs, `epoch_ack`), `vouch_hub` + `add_slot` for an upgraded CloudKit link. | Task 27 |

Tasks 1–25 need none of them: the hub side of every rule is driven by the Go phone emulator `hubtest.Phone` over `memfake` (both kinds), `bridgefake` and the relay's local stand; real phones run today's (legacy, CloudKit) path against the Go hub in the Task 25 gate.

## Phone contract points (the phone must match; spec §12a, protocol §7.5–§7.6)

1. **Ordered actions on CloudKit.** Records `a-<DEVICE_ID>-<action_seq>` in `RelayZone-<hub_id>` (one zone for every phone of the hub, private or shared scope), written with `expect: absent` (CloudKit: save with no change tag, `.ifServerRecordUnchanged`); the phone deletes a final echo with `expect: seq` (its last seen change tag). The hub never reads a phone record whose envelope `sender_id` differs from the device id in its name.
2. **Controls in the shared zone.** `c-<uuid>` hub → phone controls are sealed `relayToPhone` with that phone's relay key: another phone of the hub sees the record but cannot open it and **must neither delete nor answer it**. A phone deletes only the controls it opened (rule 15).
3. **`transport_switched`** body `{id, kind, device_id, hub_id, target, epoch, by, at, keybox}`; `keybox` = base64url of the sealed `keybox-<DEVICE_ID>` envelope of the new epoch for that phone (same bytes the data zone would carry); `by` = the initiating device id or `"entitlement_expired"`; `at` = `wire.Time`. The phone keeps the keys of every epoch it was given for at least 7 days and answers `epoch_ack{epoch}` (one switch per 5 min at most, so two switches within 7 days mean up to three epochs).
4. **Transport marker** in the relay data zone: plain kind `transport`, id `marker` (wire `RecordName(K_meta, data, "transport", "marker")`), payload = the latest `transport_switched` minus `keybox` and `device_id`; no TTL; a phone on the relay follows a marker epoch newer than its own (rule 12a).
5. **Anti-flap answer:** `transport_switch_rejected{reason: "too_soon", retry_after_s}` toward the relay within 5 min of the last accepted switch; toward CloudKit never rejected.
6. **`hub_on_relay`** (control, no fields) in the CloudKit `RelayZone` for every ordered phone without a subscription when the hub moves to the relay, and as the answer to such a phone's action read on CloudKit while the hub is on the relay (once per record version) — sim rules 11.4, 12a, 16, unchanged.
6a. **Switch notice in the transport being left** (ask #843; protocol open point 6 resolved). On every accepted switch, in both directions, before it stops publishing there, the hub writes into the **old** transport, sealed in the **old** epoch (the one every phone there holds): (a) the `transport_switched` control (contract point 3) to every phone's mailbox there, whatever action path the phone is on; (b) the transport marker (contract point 4) into the old transport's data zone — on CloudKit `DataZone-<hub_id>` record `transport`/`marker`, on the relay `data/<hub>` — kept there with no hygiene (the hub never deletes it while the old zones exist). Reused, not new: the `transport_switched` body and the relay marker of sim rules 11.3 and 12a; nothing else in today's Kit fits (checked: the closed `WorkAlertPayload.Event` enum and `owner_ask` would show a false event; `device_grant` and `heartbeat` describe the link, not a move). **Phone rule:** a phone reads controls in its mailbox and the `transport` marker in the data zone **independently of the ordered path** (a legacy-path phone too, once its Kit decodes control records); on a notice whose `target` it can follow it follows (rule 12); on `target: relay` without a subscription it acts as on `hub_on_relay` (shows "this Mac runs over Relay", lists unechoed actions as not delivered, R32). A phone whose Kit predates control records (today's App Store build) decodes neither: the unknown frame kind is dropped and the unknown slice kind is stored unindexed (protocol §8); it shows the Mac as not updating, as when Desktop is closed today, and reads the marker after its next update.
7. **Resends after a switch:** same envelope bytes on the new transport (rule 13); reseal with the same `action_seq` only after a `resend_from` for an epoch the hub no longer holds (rule 14).
8. **Unchanged for today's phone:** `hub_id`, keys, zones, shares, wire names, `device_grant` keys and the legacy path (protocol §7.4) — Task 25 checks a today's-build phone against the Go hub on CloudKit.

## Global Constraints

All Global Constraints of Plans 1a, 1b and 2 hold (byte compatibility, zone bytes, E2E red line, FILES-01, sidecar migrations as its own goose provider, guard tests one-to-one with unchanged meaning, public-repo hygiene, inner loop). In addition:

- **Never two hubs** (spec §12.1): a Desktop without the Swift hub starts no Go hub on real data until adoption finished (`hub_meta.adopted_at` set in the Go dir) or the Mac had no Swift hub state (`MobileHub/hubstate.db` absent) and the owner enabled Mobile. A `MobileHub/` that appears **after** `adopted_at` is logged (`hub: ignoring a later MobileHub (pre-guard app)`) and never read, imported or deleted; its Keychain items untouched.
- **Live hub dir on a desktop host** = Phase 2's `hub.DefaultDir` (`<config.DataRoot()>/.hub`, 0700, files 0600). The bridge's CloudKit state (`transport.db`) lives in `<hub dir>/cloudkit/` (0700). `MobileHub/` is left empty with one file `MOVED` (0600) holding exactly `hub_impl=go\nmoved_to=<hub dir>\n`.
- **Desktop never opens `hubstate.db`**, not even read-only (stricter than spec §16; removes the WAL `-shm` question): every read is `hub … --json` or a control-socket answer; guard test `TestDesktopNeverOpensTheSidecar` (Task 24) greps `WatchtowerDesktop/Sources` for `hubstate.db`.
- **Bridge** (spec §6.2): socket `<hub dir>/bridge.sock` (0600; dir 0700), peer UID checked; frames = u32 BE length ‖ protobuf, max 4 MiB; assets travel as file paths only (`<hub dir>/assets/…` sealed files out, `<hub dir>/downloads/…` in) — never bytes of an asset on the socket; it carries sealed envelopes and metadata only, holds no hub key, opens no envelope, logs ids/counts/classes. The daemon launches it on demand with `open -g -j` semantics (no Dock icon, `LSUIElement`), restarts it with backoff 1 s doubling to 60 s, stops it when the hub stops. Silent pushes reach the bridge (`registerForRemoteNotifications`) and become a `pull_now` event.
- **CloudKit cadence** (spec §9, ask #735): publish spacing `slices.CloudKitSpacing` = 2 s; mailbox pass 3 s while a phone was in touch in the last 10 minutes or a link is waiting, else 30 s (`defaultRelayActiveInterval` / `defaultRelayIdleInterval` today); push → immediate pass. The `data_version` poll and debounce rules of Plan 1b are unchanged.
- **Transport switch** (sim rules 8–16, RC §9): only a person switches (a paying phone's `transport_switch`, or `entitlement_expired`); toward the relay at least **5 min** after the previous accepted switch; toward CloudKit always and at once; the other transport's mailboxes polled every **30 s** for controls; every accepted switch = `Keyring.Rotate(ReasonTransportSwitch)`; an old epoch's receiving keys are kept until every phone acked a newer epoch and no held action is sealed in it, at most **7 days** — the same grace as every other rotation (ask #843; sim rule 14's 14 days is not used); a switch notice in the transport being left (contract point 6a) is written before the hub stops publishing there. `hub_meta.transport` = `cloudkit|relay` (default after adoption: `cloudkit`); `hub_meta.switched_at`, `switched_by` (device id or `entitlement_expired`).
- **Key hand-over** (spec §12.2): over an inherited pipe only (`fsutil.AttachPayloads`, `hub adopt --keys-fd N`), never a file, never the control socket; staged → adopted → Desktop deletes its items → `--confirm-deleted`. The hub stays off (`awaiting_adoption`) until the identity is adopted.
- **Identity store on a desktop host:** daemon-owned Keychain items, service `com.watchtower.hub`, accounts `hub_sig`, `hub_kx`, `wrap`, `relay_auth`, each `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, created by the `watchtower` binary — **if Task 1's real-Mac check fails**, `identity.FileStore{<hub dir>/identity.key}` as on a headless host (owner, ask #807). The choice is recorded once in `hub_meta.identity_store` = `keychain|file` and never re-decided at runtime.
- **Desktop over the control socket** (`<hub dir>/hub.sock`, Plan 1a Task 14): heartbeat every 30 s (fresh 90 s), recording claim/progress/finish, the view inputs (PROJ-17 hidden ids, `displayOver` ids), status/pair/recording events. Owner and Desktop verbs refused under an agent marker (Plan 1a Task 15, 1b Task 5).
- **Recordings on the Mac** (spec §8 p. 4a): `hub.Options.RecordingsDir` = `config.AppSupportDir()/recordings` (Time Machine excluded, files 0600) — the folder Desktop's transcriber already uses; new file name `<upload_id>.m4a`.
- **Desktop screens** (spec §12.4, `docs/design/desktop-style-guide.md`, workbench rule for screen specs): each changed screen gets (a) its mockup states in `docs/design/mockups/go-hub/index.html` (Task 3), (b) a `DesignShotCatalog` entry per state — **empty, loading, error with Retry, busy, narrow width** — on fixture data (`acme`, `example.com`), (c) every UI string defined in its model (no literal in the view) and pinned by a model test, (d) colours only through `Tone`/semantic styles, `SettingsSection` + `.kitRow`, no row separators, (e) `make desktop-shots DESKTOP_SHOTS=<dir>` compared with the mockup before review, PNGs attached to the PR.
- **Pinned copy** (spec text, verbatim): "Mobile is run by a newer Watchtower"; "Running sessions restart once with this update; their conversations continue" + **Continue**; "N sessions wait to resume" (`1 session waits to resume` for one); "[Watchtower] the session host is not running"; "No phones linked"; "This session can't take typed text right now".
- **Swift** follows the "Swift / Desktop conventions" of `docs/review/review-rules.md` and the `add-desktop-feature` skill; every Swift task runs `make lint-swift` (lint-diff is Go-only).
- Sidecar migrations continue from the newest file on origin/main (`00008` expected after Phase 2's `00006_held_uploads`, `00007` vouch; re-check when the task starts).
- Inner loop only per task (`go test ./internal/hub/<pkg>`, `make test-swift FILTER=…`, `make kit-test FILTER=…`, `make lint-diff`, `make lint-swift`); the full gate runs once, in Task 25.

## Review Focus

1. **Adoption interrupted between the file move and `adopted_at`.** A kill after `hubstate.db` moved but before the identity is adopted must leave the Swift items in the Keychain, no hub running, and the next launch finishing the same adoption — never a second import, never a new `hub_id`. → Task 13 `TestAdoptResumesAfterAKillAtEveryStep` (kill points: after copy, after rename, after migrate, after recordings import, after `MOVED`); Task 16 `TestHandOverCrashBeforeAdoptedKeepsDesktopItems`.
2. **A pre-guard app after a downgrade and re-upgrade.** A new `MobileHub/` with a new unlinked identity must not overwrite the adopted links. → Task 13 `TestALaterMobileHubIsNeverImported`; Task 21 `TestResolveIgnoresALaterMobileHub`.
3. **A control record for phone A in the shared CloudKit zone.** Phone B's pass must not delete, answer or apply it; the hub must not attribute B's record to A. → Task 11 `TestSharedRelayZoneRoutesBySender`, `TestARecordWhoseSenderDiffersFromItsNameIsDropped`.
4. **A switch while one transport is unreachable.** The hub must never wait for the unreachable side, and nothing stuck there may apply twice when it comes back. → Task 18 `TestSwitchToCloudKitDuringRelayOutage`, `TestSecondPhoneFollowsSwitch`; Task 20 `TestNoCopiesLeftOnRelayAfterSwitch`.
5. **Plaintext crossing the bridge socket.** Every frame the Go side writes must carry only envelope bytes and metadata. → Task 4 `TestBridgeFramesCarryNoPlaintext` (canary markers in every slice, action, alert and recording through `bridgefake` frame capture); Task 10 `testBridgeNeverOpensEnvelopes` (the bridge links no `Secure` sealing API — a build-graph assertion).

---

### Task 1: Keychain identity on a desktop host — the real-Mac check and `identity.KeychainStore`

**Files:**
- Create: `internal/hub/identity/keychain_darwin.go` (cgo Security), `internal/hub/identity/keychain_other.go` (`ErrNoKeychain`), `internal/hub/identity/select.go`
- Create: `scripts/hub-keychain-check.sh` (the manual check)
- Test: `internal/hub/identity/keychain_darwin_test.go` (`//go:build darwin && keychain`, run by hand), `internal/hub/identity/select_test.go`

**Interfaces:**
- Consumes: Plan 1a `identity.Identity`, `identity.Store`, `identity.FileStore`, `state.Store.Meta/SetMeta`.
- Produces:
  ```go
  package identity
  const KeychainService = "com.watchtower.hub"
  type KeychainStore struct{ Service string } // accounts hub_sig, hub_kx, wrap, relay_auth; ThisDeviceOnly; created by this binary
  func (KeychainStore) Load() (Identity, error); func (KeychainStore) Save(Identity) error; func (KeychainStore) Delete() error
  func (KeychainStore) Staged() (Identity, bool, error); func (KeychainStore) SaveStaged(Identity) error; func (KeychainStore) PromoteStaged() error; func (KeychainStore) DeleteStaged() error // accounts "<name>.staged"
  // FileStore gains the same staged trio (<dir>/identity.staged.key, 0600)
  type Staging interface{ Store; Staged() (Identity, bool, error); SaveStaged(Identity) error; PromoteStaged() error; DeleteStaged() error }
  const MetaIdentityStore = "identity_store" // "keychain" | "file"
  func ForDesktopHost(st *state.Store, dir string, keychainWorks bool) (Staging, error) // first call records the choice in hub_meta; later calls follow the record
  var KeychainUsable = true // set false by the release build flag when Task 1 Step 1 fails (ldflags: -X …identity.KeychainUsable=false)
  ```
- **Depends on:** none

- [ ] **Step 1: Manual check on a real Mac** (spec §12.2: "verified on a real Mac as the first task of phase 3"). `scripts/hub-keychain-check.sh` builds two signed `watchtower` binaries with the same team id and identifier but different versions (`scripts/build-app.sh` signing identity), runs `watchtower hub keychain-probe write` with the first and `… read` with the second, from a LaunchAgent context and from Terminal, and prints `ok` or the `OSStatus` class. Record the result in the PR body and in `docs/features/go-hub.md`: **ok** → `KeychainUsable = true`; any prompt or error → `false` (file store), and the guide's privacy page says so (Task 24).
- [ ] **Step 2: Failing tests:** `TestKeychainRoundTripThisDeviceOnly` (tag `keychain`: save, load equal, attribute `kSecAttrAccessible` = `AfterFirstUnlockThisDeviceOnly`), `TestKeychainStagedPromoteAndDelete`, `TestForDesktopHostRecordsTheChoiceOnce` (first call with `keychainWorks=false` → `file`, a second call with `true` still `file`), `TestFileStoreStagedIsPrivate` (0600; a looser mode → `ErrInsecureMode`), `TestKeychainNeverLogsKeys` (`logcanary`).
- [ ] **Step 3:** `go test ./internal/hub/identity` → FAIL; `go test -tags keychain ./internal/hub/identity -run Keychain` on the dev Mac → FAIL.
- [ ] **Step 4: Implement**; a hidden owner-only `hub keychain-probe write|read` (refused under an agent marker) exists only for Step 1.
- [ ] **Step 5:** → PASS; `make lint-diff`.
- [ ] **Step 6: Commit** `hub/identity: Keychain store on a desktop host, staged identities, the recorded choice`.

### Task 2: Downgrade guard in the Swift hub (ships in the next regular release, ahead of the Go hub)

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/MobileHub/MobileHubService.swift` (refuse to start), `WatchtowerDesktop/Sources/App/AppState+MobileHub.swift` (state), `WatchtowerDesktop/Sources/Views/Settings/MobileSettingsView.swift` (the line)
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/MobileHubMovedGuard.swift`
- Test: `WatchtowerDesktop/Tests/Core/MobileHubMovedGuardTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum MobileHubMovedGuard {
      static let noteName = "MOVED"
      static func isMoved(mobileHubDir: URL, fileManager: FileManager = .default) -> Bool // the note exists and contains the line "hub_impl=go"
      static let message = "Mobile is run by a newer Watchtower"
  }
  ```
- **Depends on:** none. Merged and released before any Go-hub release (spec §12.1).

- [ ] **Step 1: Failing tests:** `testMovedNoteStopsTheSwiftHub` (note present → `MobileHubService` never opens `hubstate.db`, never touches the Keychain, never starts a transport; Settings model state `.movedToNewerApp` with `message`), `testANoteWithoutTheImplLineIsIgnored`, `testNoNoteKeepsTodaysBehaviour`.
- [ ] **Step 2:** `make test-swift FILTER=MobileHubMovedGuardTests` → FAIL.
- [ ] **Step 3: Implement**; Settings → Mobile shows `message` in one `.kitRow` with no toggle; DesignShot entry `mobileSettingsMoved` (one state; this screen is replaced in Task 23).
- [ ] **Step 4:** → PASS; `make lint-swift`.
- [ ] **Step 5: Commit** `desktop: the Swift hub refuses to start when Mobile moved to a newer Watchtower`.

### Task 3: Mockups for every new or changed screen

**Files:**
- Create: `docs/design/mockups/go-hub/index.html` (self-contained, light/dark, no external loads)

**Interfaces:**
- Produces: one section per screen and state, with the exact copy later tasks put in their models: Settings → Mobile (phone list with transport per phone and "switched by <phone> <time>", grants, recordings switch, name; states empty "No phones linked", loading, hand-over in progress, adoption error with **Retry**, hub off with its reason, busy, narrow), the pairing sheet (QR, waiting, SAS confirm, linked, each refusal), the v1-host notice ("Running sessions restart once with this update; their conversations continue" + **Continue**), the workspace switcher line ("N sessions wait to resume"), the session pane line "[Watchtower] the session host is not running". Base: `docs/design/mockups/relay-client/index.html` Desktop sections.
- **Depends on:** none. The controller files the owner review ask with the mockup; Tasks 19, 22, 23 wait for its approval.

- [ ] **Step 1:** Write the page; every state listed above present; copy matches Global Constraints verbatim.
- [ ] **Step 2:** `rg -n "https?://" docs/design/mockups/go-hub/index.html` → no external URL; `make leak-check`-style scan via `scripts/leak-check.sh` on the file → clean.
- [ ] **Step 3: Commit** `docs: Go hub phase 3 mockups (Settings → Mobile, pairing, v1-host notice, switcher line)`.

### Task 4: Bridge wire protocol, the Go `transport/cloudkit` client and `bridgefake`

**Files:**
- Create: `internal/hub/transport/cloudkit/bridge.proto`, generated `internal/hub/transport/cloudkit/bridgepb/bridge.pb.go`, `internal/hub/transport/cloudkit/testdata/frames.json` (shared fixture)
- Create: `internal/hub/transport/cloudkit/{client.go,frames.go,zones.go,supervisor.go,shares.go,signals.go}`
- Create: `internal/hub/transport/cloudkit/bridgefake/bridgefake.go`
- Modify: `internal/hub/transport/transport.go` (optional capabilities), `internal/hub/secure/sealer.go` (`Signal`)
- Test: `internal/hub/transport/cloudkit/{client_test.go,frames_test.go,supervisor_test.go,canary_test.go}`

**Interfaces:**
- Consumes: Plan 1a `transport.Transport`, `secure.Record`, `memfake` (record model for the fake).
- Produces:
  ```go
  package transport
  // optional capabilities, type-asserted by callers
  type SharedMailbox interface{ MailboxFor(hub, phone string) string } // cloudkit: every phone → the one RelayZone; relay: MailboxZone
  type Shares interface {
      AccountStatus(ctx context.Context) (Account, error)                 // available | no_account | restricted | temporarily_unavailable | no_entitlement
      EnsureShares(ctx context.Context) (dataURL, relayURL string, err error)
      SetPublicLink(ctx context.Context, open bool) error
      Participants(ctx context.Context, zone string) ([]Participant, error)
      RemoveParticipants(ctx context.Context, zone string, userRecordNames []string) error
  }
  type Participant struct{ UserRecordName string; Accepted bool }
  type Signals interface{ SaveSignal(ctx context.Context, r secure.Record) error; DeleteSignal(ctx context.Context, wire string) error }
  // Event gains PullNow bool (a silent push reached the bridge)
  package secure
  func (s *Sealer) Signal(wireName string) (Record, error) // class "signal": the plaintext WatchtowerSignal (protocol §4.8), the only unsealed record kind, still built only here
  package cloudkit
  const SocketName = "bridge.sock"; const MaxFrame = 4 << 20
  type Config struct{ Dir, HubID string; Launch func(ctx context.Context) (*os.Process, error); Clock func() time.Time }
  func New(c Config) *Client // implements transport.Transport (Kind() == KindCloudKit), SharedMailbox, Shares, Signals
  func DataZoneName(hubID string) string  // "DataZone-<hub_id>"
  func RelayZoneName(hubID string) string // "RelayZone-<hub_id>"
  type Supervisor struct{…}; func NewSupervisor(c Config) *Supervisor; func (s *Supervisor) Run(ctx context.Context) error // launch, restart 1 s → 60 s backoff, stop on ctx
  package bridgefake
  func Serve(t testing.TB, dir string, kind ...Option) *Fake // a bridge on <dir>/bridge.sock over a CloudKit-shaped memfake; Frames() [][]byte captures every frame received
  ```
  **Frames** (`bridge.proto`, one oneof per request/answer, `id` correlates): `Hello{version=1, hub_id}`, `Save{items[{zone, name, envelope, asset_path?, expect{mode, tag_seq}}]}` → `Outcomes[{saved, tag_seq, conflict?, refused_class?}]`, `Delete{zone, items[{name, expect}]}`, `Changes{zone, since}` → `Batch{changed[{name, envelope, tag_seq, server_at, asset_id?}], deleted[], new_seq, more}`, `Download{zone, asset_id, dst}`, `AccountStatus`, `EnsureShares`, `SetPublicLink{open}`, `Participants{zone}`, `RemoveParticipants{zone, user_record_names}`, `SaveSignal{wire}`, `DeleteSignal{wire}`, server-sent `Event{zone? | pull_now | error_class}`. **CloudKit change tags never cross the socket**: the bridge maps each record's tag to a per-record `tag_seq` (u64) and each zone's change feed to a `bridge_seq` cursor in its own `transport.db`, so Go keeps `RecordSeq`/`since` as `uint64` with the memfake CloudKit rule (opaque, equality only). Zones: Go names `data/<x>` → `DataZone-<hub_id>`, `relay/<x>/<y>` → `RelayZone-<hub_id>`, `pair/<slot>` → refused (`ErrUnsupported`).
- **Depends on:** none

- [ ] **Step 1: Fixture** `frames.json`: one case per frame type `{name, json, hex}` (protobuf bytes), read by Go `TestFramesFixture` and Swift `BridgeFramesFixtureTests` (Task 10). Decide here: if `WatchtowerDesktop/Package.resolved` already has `swift-protobuf`, the bridge uses it; else the bridge hand-codes these few messages and the fixture pins the bytes.
- [ ] **Step 2: Failing tests:** `TestFramesFixture`, `TestClientRefusesUnsealedRecord` (before any frame is written; `bridgefake.Frames()` empty), `TestSignalIsTheOnlyUnsealedKindAndOnlyFromTheSealer` (a `secure.Record` with class signal made outside `Sealer.Signal` is refused), `TestZonesMapToHubZones`, `TestPairZoneIsUnsupportedOnCloudKit`, `TestTagSeqIsOpaqueEqualityOnly` (memfake CloudKit rule: ordering two `tag_seq` values is never used — `TestRecordSeqNeverComparedWithCursor` reused over the client), `TestExpectAbsentConflictCarriesTheServerCopy`, `TestAssetsCrossAsPathsOnly` (a `Save` with an asset writes `asset_path` under `<dir>/assets`, a path outside is refused; no frame exceeds 64 KiB with an asset), `TestSupervisorRestartsWithBackoff` (1, 2, 4 … 60 s on a fake clock; a stub bridge process group reaped in `t.Cleanup`), `TestSocketPrivateAndPeerChecked` (0600, other-UID peer closed via the Plan 1a peer seam), `TestPullNowEventTriggersAPass`, `TestBridgeFramesCarryNoPlaintext` (Review Focus 5).
- [ ] **Step 3:** `go test ./internal/hub/transport/... ./internal/hub/secure` → FAIL.
- [ ] **Step 4: Implement.**
- [ ] **Step 5:** → PASS; `make lint-diff`.
- [ ] **Step 6: Commit** `hub/transport: CloudKit bridge protocol, Go client, supervisor and fake`.

### Task 5: Desktop inputs reach the hub — `desktop_view`, `recording_progress`, `desktop_watch`

**Files:**
- Create: `internal/hub/state/migrations/00008_desktop_recordings.sql`
- Modify: `internal/hub/control.go` (ops), `internal/hub/state/recordings.go`, `internal/hub/slices/sources/terminal_session.go` (hidden + displayOver), `internal/hub/slices/sources/recording_job.go` (phase, percent), `cmd/hub_recording.go` (`progress`)
- Create: `internal/hub/desktopview.go`
- Test: `internal/hub/desktopview_test.go`, `internal/hub/control_test.go`, `internal/hub/slices/sources/terminal_session_test.go`, `internal/hub/slices/sources/recording_job_test.go`, `internal/hub/state/columns_test.go`, `cmd/hub_recording_test.go`

**Interfaces:**
- Consumes: Plan 1a control socket (`ControlRequest`/`ControlAnswer`), Plan 1b `TerminalSessionOptions`, `sessionstate.Resolve`, `recording_jobs`.
- Produces:
  ```go
  package hub
  const OpDesktopView, OpRecordingProgress, OpDesktopWatch = "desktop_view", "recording_progress", "desktop_watch"
  // ControlRequest gains: Hidden, DisplayOver []int64; Upload, Phase string; Percent *int
  type DesktopView struct{ Hidden, DisplayOver map[int64]bool; At time.Time } // in memory only; empty once the Desktop heartbeat is stale (> 90 s)
  func (h *hubRuntime) SetDesktopView(v DesktopView)
  // desktop_watch: the connection stays open and receives {"event":"status"|"recording_queued"|"pair"|"switched", …} lines
  package sources
  // TerminalSessionOptions gains: View func() (hidden, displayOver map[int64]bool)
  package state
  func (s *Store) RecordingProgress(uploadID, phase string, percent *int, now time.Time) error // phase transcribing|diarizing|summarizing; percent 0..100 only while transcribing
  ```
  - `00008`: `ALTER TABLE recording_jobs ADD COLUMN phase TEXT CHECK (phase IN ('transcribing','diarizing','summarizing'))`, `percent INTEGER CHECK (percent BETWEEN 0 AND 100)`, — no file-name column (ask #843). Allowlist (Plan 1b Task 16): `phase: enum`, `percent: counter`.
  - `recording_job` slice: `claimed` + `phase` → the Swift statuses `transcribing` (with `percent`), `diarizing`, `summarizing`, exactly as today's `RecordingJobSlice`; the phone sees no change from the Swift hub.
  - `terminal_session` (and the `workbench`/`session_timeline` sources that read its published set): a hidden id (PROJ-17 Undo batch) is not published; a `displayOver` id resolves with `displayOver: true` (#411) — the two "Known divergences" in the source's doc comment are removed.
  - CLI (pinned): `hub recording progress --upload <id> --phase <p> [--percent N] --json` → `{"upload_id","status","phase","percent"}`; Desktop uses the socket op, the CLI is its fallback when no hub runs (then exit 1 "the hub is not running": progress needs a running hub).
- **Depends on:** none

- [ ] **Step 1: Failing tests:** `TestHiddenSessionIsNotPublished` (Go twin of the Swift slice's `hiddenIDs` test, same assertion), `TestDisplayOverCountReadsAsShownOver` (twin of the `displayOver` case), `TestDesktopViewClearsWhenHeartbeatGoesStale` (91 s → hidden session published again), `TestRecordingProgressMapsToSwiftStatuses` (table: claimed+transcribing 40 → `transcribing` percent 40; diarizing; summarizing; done → transcript id), `TestPercentOnlyWhileTranscribing`, `TestDesktopWatchStreamsRecordingQueued` (an intake `received` → one `recording_queued` line with the upload id only), `TestDesktopOpsRefusedUnderAnAgentMarker`, `TestHubRecordingProgressJSONKeys`, `TestSidecarHasNoNewUnsealedContentColumns` (updated allowlist), `TestFILES01_DesktopViewLogsCountsOnly`.
- [ ] **Step 2:** `go test ./internal/hub/... ./cmd -run 'TestHubRecording|TestDesktop'` → FAIL.
- [ ] **Step 3: Implement.** A view change calls `Publisher.PublishSoon("terminal_session")`.
- [ ] **Step 4:** → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `hub: Desktop view inputs (PROJ-17 Undo batch, displayOver), recording progress, desktop_watch`.

### Task 6: Spec-review comment context in Go (prefix/suffix re-location)

**Files:**
- Create: `internal/hub/actions/handlers/docrender.go` (twin of `DocumentRendering`'s plain-text rendering)
- Modify: `internal/hub/actions/handlers/ask_specreview.go` (`markComments` fills `prefix`/`suffix`), `go.mod` (goldmark direct)
- Test: `internal/hub/actions/handlers/docrender_test.go`, `internal/hub/actions/handlers/ask_specreview_test.go`

**Interfaces:**
- Consumes: `WatchtowerKit/Tests/Fixtures/asks/anchor-fixtures.json` (shared with Kit `CommentAnchorBuilderTests` and Desktop `CommentAnchorFixtures`).
- Produces:
  ```go
  func renderPlain(markdown string) string                              // DocumentRendering twin: the text the Desktop anchors quotes in
  func relocate(rendered, quote string) (prefix, suffix string, ok bool) // CommentAnchorBuilder twin: same context length and tie-break as the fixture
  ```
  The "Known divergence" comment in `buildSpecReviewAnswer` is removed: a phone answer to a review ask carries the same `prefix`/`suffix` the Desktop's `SpecReviewAnswer` builds.
- **Depends on:** none

- [ ] **Step 1: Failing tests:** `TestAnchorFixtures` (every case in `anchor-fixtures.json`: `relocate(renderPlain(doc), quote)` equals the fixture's prefix/suffix), `TestSpecReviewAnswerCarriesContextLikeDesktop` (a phone `ask_answer` over a loop review → comment `prefix`/`suffix` equal to the Swift `SpecReviewAnswer` output pinned in a new fixture case), `TestQuoteNotFoundKeepsEmptyContext`.
- [ ] **Step 2:** `go test ./internal/hub/actions/handlers -run 'Anchor|SpecReview'` → FAIL.
- [ ] **Step 3: Implement** on goldmark's AST (headings, lists, code fences, emphasis stripped as `DocumentRendering` does; if a fixture case disagrees, the fixture wins and the case is added to the Swift side too).
- [ ] **Step 4:** → PASS; `make kit-test FILTER=CommentAnchorBuilderTests`; `make lint-diff`.
- [ ] **Step 5: Commit** `hub/handlers: spec-review comment prefix and suffix like the Desktop`.

### Task 7: Desktop on `session-host` v2 — `Deliver` for the composer and ask answers, owner stops

**Files:**
- Modify: `WatchtowerDesktop/Sources/Services/SessionHost/SessionHostClient.swift` (hello v2, `Deliver`/`DeliverCheck`/`Delivered`/`DeliveryEvent`/`PromptHint`/`Stop` frames), `WatchtowerDesktop/Sources/Services/SessionHost/HostedTerminalSession.swift`, `WatchtowerDesktop/Sources/Services/TerminalCenter.swift` (delivery state removed), `WatchtowerDesktop/Sources/Services/SessionLineDelivery.swift`, `WatchtowerDesktop/Sources/Services/SessionControl.swift` (the re-check answer), the Workchat composer and `OwnerAsksViewModel` answer path
- Test: `WatchtowerDesktop/Tests/SessionHost/SessionHostV2ClientTests.swift`, `WatchtowerDesktop/Tests/Services/ComposerDeliverTests.swift`

**Interfaces:**
- Consumes: Plan 1b Tasks 11–13 frames (`ProtocolVersion = 2`, `DeliverReq`, `DeliverCheckReplyMsg`, `DeliveredMsg`, `DeliveryEventMsg`, `StopReq`, `ExitMsg.Requested`), `internal/sessionhost/testdata/paths.json`.
- Produces:
  ```swift
  enum DeliverOutcome: Equatable { case submitted, typed, held(String), noSession, noPasteMode }
  extension SessionHostClient {
      func deliver(_ r: DeliverRequest, check: @Sendable () async -> DeliverCheckReply) async throws -> DeliverOutcome
      func stop(row: Int64, run: String, launch: UInt64) async throws
  }
  ```
  The composer and ask answers call `deliver` with `holdIfPromptText: false`, `submitIf` = `SessionControl`'s pre-check; `noPasteMode` → `.copied` (pasteboard + today's hint) — Desktop is a desktop host by definition. `DeliveryEvent`s drive the pane hints `TerminalCenter` showed. An `Exit` with `requested: true` maps to `closedByApp` (no PROJ-18 cleanup). Removed from `TerminalCenter`: `promptDrafts`, `pendingReturns`, `pasteHints`, `sharedPrompts`, answer hints, per-launch `runs`, the bracketed-paste reader — the host owns them (spec §8 p. 4b).
- **Depends on:** none

- [ ] **Step 1: Failing tests:** `testHelloV2`, `testDeliverAnswersTheRecheckWithSessionControlState` (fake host frames: `DeliverCheck` → reply carries `fresh`, `canSubmit`, `answersDialog` from a stubbed `SessionControl`), `testNoPasteModeCopiesToThePasteboard`, `testDeliveryEventsShowPaneHints`, `testRequestedExitIsClosedByAppAndCleansNothing` (PROJ-18), `testComposerNeverWritesThePTYDirectly` (the composer path has no `send(bytes)` call left — a seam counts PTY writes = 0), `testAskAnswerGoesThroughDeliver`. Swift PROJ-12 guards that tested `TerminalCenter` delivery are deleted **in this task** with a mapping table in the PR body to their Go twins from Plan 1b Task 13 (`TestProj12_*`), names unchanged.
- [ ] **Step 2:** `make test-swift FILTER='SessionHostV2ClientTests|ComposerDeliverTests'` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** → PASS; `go test ./internal/sessionhost` unchanged; `make lint-swift`.
- [ ] **Step 5: Commit** `desktop: composer and ask answers through session-host Deliver, owner stops as host Stop`.

### Task 8: New Session through Go

**Files:**
- Modify: `WatchtowerDesktop/Sources/ViewModels/WorkbenchesViewModel+Sessions.swift` (`startNewSession` and every Desktop start path: Work on it, automations `session()`, In This Folder / In Its Own Worktree), `WatchtowerDesktop/Sources/Services/TerminalCenter.swift` (attach only)
- Test: `WatchtowerDesktop/Tests/ViewModels/StartNewSessionViaCLITests.swift`

**Interfaces:**
- Consumes: Plan 1b Task 15 `workbench session start --workbench N [--target T] [--agent claude|codex] [--place folder|worktree|auto] --json` → `{"session_id","state","folder_path","worktree_branch"}`, `workbench session stop --session S --json`.
- Produces: Desktop runs the CLI (pinned keys decoded by a `Decodable` with exactly those keys), then attaches `HostedTerminalSession` to the returned row (reattach path, no Launch from Swift). Removed: Swift `SessionStartPlacement` call sites in the start path, Swift `TerminalLaunch` use for new launches (kept only as the dual-path fixture test of Plan 1b Task 14 until Task 24).
- **Depends on:** none

- [ ] **Step 1: Failing tests:** `testNewSessionRunsWorkbenchSessionStart` (argv exact; the row selected is `session_id`), `testPlaceOverrideIsPassed` (folder / worktree / auto), `testStartFailureShowsTheReasonAndKeepsTheRow` (CLI exit 1 with a reason class → pane line, no Swift cleanup), `testNoSwiftLaunchOnNewSession` (seam: `TerminalCenter.launch` count 0, `attach` 1), `testDecodesOnlyPinnedKeys`.
- [ ] **Step 2:** `make test-swift FILTER=StartNewSessionViaCLITests` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** → PASS; `make lint-swift`.
- [ ] **Step 5: Commit** `desktop: New Session through watchtower workbench session start`.

### Task 9: The owner-write notice from the history actor

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Services/` workbench notice policy (the target-change notice the board's `onOwnerWrite` suppresses), `WatchtowerDesktop/Sources/App/AppState.swift` (`onOwnerWrite` wiring)
- Test: `WatchtowerDesktop/Tests/Core/WorkbenchOwnerNoticePolicyTests.swift`

**Interfaces:**
- Consumes: Go `db.ActorOwner` written by the hub's board handlers (Plan 1b Task 2) into the target history rows.
- Produces: the notice center announces a target change only when its newest history row's actor is not `owner` (`"owner"` literal = Go `db.ActorOwner`, pinned by a dual-path test reading `internal/db` constants through a fixture line in `internal/db/testdata/actors.json`); the in-process `onOwnerWrite` stays for the Desktop's own edits (same effect, earlier).
- **Depends on:** none

- [ ] **Step 1: Failing tests:** `testAPhoneEditWithOwnerActorIsNotAnnounced` (a history row written as by the hub, no `onOwnerWrite` call → no notice), `testAnAgentChangeIsStillAnnounced`, `testActorLiteralMatchesGo` (fixture).
- [ ] **Step 2:** `make test-swift FILTER=WorkbenchOwnerNoticePolicyTests` → FAIL.
- [ ] **Step 3: Implement**; add `internal/db/testdata/actors.json` and `TestActorsFixture` in `internal/db`.
- [ ] **Step 4:** → PASS; `go test ./internal/db -run TestActorsFixture`; `make lint-swift`, `make lint-diff`.
- [ ] **Step 5: Commit** `desktop: no notice for the owner's own phone edits (history actor)`.

### Task 10: `WatchtowerCloudBridge.app`

**Files:**
- Modify: `WatchtowerDesktop/Package.swift` (executable target `WatchtowerCloudBridge` depending on `WatchtowerSync`)
- Create: `WatchtowerDesktop/Sources/WatchtowerCloudBridge/{main.swift,BridgeServer.swift,BridgeFrames.swift,BridgeTransport.swift,BridgeShares.swift,BridgeTagMap.swift,PushReceiver.swift}`, `WatchtowerDesktop/Resources/WatchtowerCloudBridge/{Info.plist,WatchtowerCloudBridge.entitlements}`
- Modify: `scripts/build-app.sh` (build, embed at `Watchtower.app/Contents/Helpers/WatchtowerCloudBridge.app`, sign with the iCloud container + `aps-environment` entitlements, notarize with the app), `Makefile` (`bridge-build`)
- Test: `WatchtowerDesktop/Tests/CloudBridge/{BridgeFramesFixtureTests.swift,BridgeContractTests.swift,BridgeTagMapTests.swift}`

**Interfaces:**
- Consumes: Task 4 `bridge.proto` + `frames.json`; Kit `CloudKitTransport` (CKSyncEngine, `TransportStore`, zones, `AskAlertSubscription`, push fetch), the share logic of today's `ShareService` (moved here), `InMemoryCloudTransport` for the contract test.
- Produces: an `LSUIElement` app that serves `<hub dir>/bridge.sock` (path from `--socket`), checks the peer UID (`getpeereid`), answers every Task 4 frame, keeps `tag_seq`/`bridge_seq` in `BridgeTagMap` (GRDB, `<hub dir>/cloudkit/bridge.db`, ids and numbers only), conditional saves as `modifyRecords(savePolicy: .ifServerRecordUnchanged)` with the last known change tag (`expect: absent` = no tag; conflict answers carry the server copy's envelope), receives silent pushes and emits `Event{pull_now}`; exits when the socket peer closes for 60 s and the daemon does not reconnect.
- **Depends on:** Task 4

- [ ] **Step 1: Failing tests:** `testFramesFixture` (every `frames.json` case decodes and re-encodes byte-equal), `testSaveDeleteChangesOverAFakeTransport` (the spec §13 bridge contract test, fake `CloudSyncTransport`), `testConditionalSaveConflictReturnsServerCopy`, `testExpectAbsentRefusesAnExistingRecord`, `testTagSeqStableAcrossRestarts` (`BridgeTagMapTests`), `testPeerWithAnotherUIDIsClosed`, `testAssetPathOutsideTheHubDirIsRefused`, `testBridgeNeverOpensEnvelopes` (Review Focus 5: the target's dependency graph has no `EnvelopeOpener`/`HubKeyring`/key provider symbol — checked by a test that reflects over the linked module list), `testSilentPushEmitsPullNow`.
- [ ] **Step 2:** `make test-swift FILTER='BridgeFramesFixtureTests|BridgeContractTests|BridgeTagMapTests'` → FAIL.
- [ ] **Step 3: Implement**; `scripts/build-app.sh` embeds and signs it (verify with `codesign -d --entitlements - …/WatchtowerCloudBridge.app` in the script's check step).
- [ ] **Step 4:** → PASS; `make lint-swift`; `bash scripts/tests/build-app-bridge.sh` (new: asserts the helper path and entitlements in a dry-run build).
- [ ] **Step 5: Commit** `bridge: WatchtowerCloudBridge.app — CloudKit transport over a Unix socket, no keys`.

### Task 11: Processor and records on the CloudKit shape

**Files:**
- Modify: `internal/hub/actions/processor.go` (`mailboxes` over `SharedMailbox`), `internal/hub/actions/order.go`, `internal/hub/actions/legacy.go`, `internal/hub/actions/hygiene.go`
- Create: `internal/hub/actions/device_record.go`
- Test: `internal/hub/actions/cloudkit_test.go`, `internal/hub/actions/device_record_test.go`, `internal/hub/actions/sim_test.go` (both memfake kinds)

**Interfaces:**
- Consumes: Task 4 `transport.SharedMailbox`, Plan 1a `link.Center.Unlink/Allow`, `state.Device`.
- Produces:
  - A pass reads each distinct mailbox zone once: on CloudKit the one `RelayZone`, routed per record to the device named in it (`a-<DEVICE_ID>-…`, legacy `action-<uuid>` by envelope `sender_id`, `device-<DEVICE_ID>`, `hello-<DEVICE_ID>`, `recupload-<id>`); every linked phone has a mailbox on CloudKit (relay id not required). A record whose envelope `sender_id` ≠ its name's device id → dropped, class `sender_mismatch`; a hub-written record (echo, `c-*` to a phone) is never handled as input.
  - `device-<DEVICE_ID>` (`DevicePayload`, protocol §5.5): `unlinked: true` → `Center.Unlink`; `typing_requested`, `permissions_requested` → requests shown to the owner; `start_sessions` → `start_sessions_allowed`; `name`, `user_record_name` stored for the participant sweep (Task 12). Go twins of the Swift `RelayProcessor` device-record tests, same assertions.
  - CloudKit hygiene stays Plan 1a's (7 days, daily, server modification date).
  ```go
  func (p *Processor) handleDeviceRecord(ctx context.Context, b mailbox, rec transport.Stored) error
  ```
- **Depends on:** Task 4

- [ ] **Step 1: Failing tests:** `TestSharedRelayZoneRoutesBySender` (Review Focus 3: phones A and B; a `c-*` for A and an echo for B in the zone; B's actions apply only as B's, A's control is neither deleted nor answered), `TestARecordWhoseSenderDiffersFromItsNameIsDropped`, `TestLegacyActionOnCloudKitTakesTodaysPath` (UUID name, today's echo, `ordered` false — a today's phone), `TestDeviceRecordUnlinkedUnlinks`, `TestDeviceRecordRequestsAreNotGrants`, `TestEveryLinkedPhoneHasACloudKitMailbox` (no relay id), and every sim test of Plans 1a (`TestGapTriggersResendFrom`, `TestHubResendFromRetriedUntilWritten`, …) run on `memfake.New(KindCloudKit, …)` through a `SharedMailbox` adapter.
- [ ] **Step 2:** `go test ./internal/hub/actions` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `hub/actions: one shared CloudKit mailbox routed by sender, device records`.

### Task 12: Linking over CloudKit — shares, public link, participants, QR fields

**Files:**
- Create: `internal/hub/link/cloudkit.go`
- Modify: `internal/hub/link/center.go` (`Issue` fills CloudKit fields when `Shares` is present), `internal/hub/link/hello.go` (hellos from `RelayZone`)
- Test: `internal/hub/link/cloudkit_test.go`

**Interfaces:**
- Consumes: Task 4 `transport.Shares`, Plan 1a `link.Center`, `wire.LinkPayload` (`container`, `owner_user`, `data_share`, `relay_share`), today's `MobileLinkCenter` rules.
- Produces:
  ```go
  type Sweep struct{ AnswerGrace time.Duration } // today's answerGrace, copied verbatim from MobileLinkCenter
  func (c *Center) IssueCloudKit(ctx context.Context, s transport.Shares) (wire.LinkPayload, string, error) // EnsureShares, open public link, v4 with container, owner_user, data_share, relay_share, transports ["cloudkit","relay"]
  func (c *Center) CloseLink(ctx context.Context, s transport.Shares, reason CloseReason) error // close public link; sweep participants not bound to a linked device's user_record_name (after AnswerGrace for answering closes)
  func (c *Center) HandleCloudKitHello(ctx context.Context, rec transport.Stored) (Pending, error)
  ```
  Port of every `MobileLinkCenterTests` / `MobileLinkPairingCodeTests` behaviour that involves shares (Plan 1a Task 11 ported the rest), same names in Go form.
- **Depends on:** Task 4

- [ ] **Step 1: Failing tests:** `TestIssueOnCloudKitOpensThePublicLinkAndCarriesShares`, `TestCloseSweepsUnboundParticipants`, `TestAWaitingPhonesParticipantIsNeverSweptBeforeTheOwnerDecides`, `TestAnsweringCloseKeepsParticipantsForAnswerGrace`, `TestRemoveDropsTheParticipant`, `TestAFailedSweepIsRetried`, `TestWrongCreatorGetsNoKeys` (`user_record_name` must match an accepted participant of both shares), `TestNoAccountRefusesToIssue` (account status ≠ available → error class, nothing opened).
- [ ] **Step 2:** `go test ./internal/hub/link` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `hub/link: linking over CloudKit (shares, public link, participant sweep)`.

### Task 13: Adoption — the Swift hub's state into the Go hub, once, interrupt-safe

**Files:**
- Create: `internal/hub/adopt/{adopt.go,steps.go,recordings.go,settings.go,check.go}`
- Create: `cmd/hub_adopt.go` (state part; keys in Task 16)
- Test: `internal/hub/adopt/{adopt_test.go,steps_test.go,recordings_test.go}`, `cmd/hub_adopt_test.go`

**Interfaces:**
- Consumes: Plan 1a `state.Open`/`AcquireLock`, migrations `00001`–`00008`; Phase 2 `held_uploads`; Task 5 `recording_jobs` (`phase`, `percent`), `state.ErrorClass`.
- Produces:
  ```go
  package adopt
  type Step string // "copy" | "verify" | "rename" | "migrate" | "recordings" | "settings" | "transport" | "moved" | "done"
  const MetaAdoptStep, MetaAdoptedAt, MetaAdoptError = "adopt_step", "adopted_at", "adopt_error"
  type Settings struct{ Enabled bool; StartSessionAllows map[string]bool /* device id → owner grant */ } // read by Desktop from its defaults, sent on stdin as JSON
  type Result struct{ Step Step; Imported Counts; Error string /* class */ }
  type Counts struct{ Devices, Jobs, Skipped int }
  func Run(ctx context.Context, mobileHubDir, hubDir string, s Settings, now func() time.Time) (Result, error) // under the hub lock; resumable from hub_meta.adopt_step
  func Status(hubDir string) (Result, error) // read-only
  func CheckSwiftFile(path string) error // pragma_table_info: every folded-in ALTER column of 00001 present, else ErrSwiftSchema
  var ErrSwiftSchema, ErrAlreadyAdopted, ErrLaterMobileHub error
  ```
  **Steps** (each commits `adopt_step` before the next; a re-run starts at the recorded step): `copy` — `hubstate.db` (+ `-wal`/`-shm` checkpointed first: open read-write once, `PRAGMA wal_checkpoint(TRUNCATE)`, close), slice assets dir and `transport.db` copied to `<hub dir>/adopt.tmp/`; `verify` — `CheckSwiftFile` and `PRAGMA integrity_check` on the copy; `rename` — atomic `rename` into `<hub dir>/hubstate.db`, `<hub dir>/assets/`, `<hub dir>/cloudkit/transport.db`; `migrate` — `state.Open` (goose `00001` is idempotent over the Swift tables, then `00002`–`00008`; the open switches the file DELETE → WAL); `recordings` — Swift `phone_recordings` → `recording_jobs`: `received|queued|transcribing|diarizing|summarizing` → `failed` with error class `hub_moved` (ask #843: a recording mid-transcription at adoption fails once with a clear reason; the `recording_job` slice publishes this class as the fixed text "Watchtower was updated while this recording was being transcribed. The audio is kept on your Mac; send it again if you still have it on this iPhone."; the audio file on the Mac is left in place and never deleted by the adoption); `done` → `done` + `transcript_id`; `failed` → `failed` + `state.ErrorClass(error)`; `created_at`/`finished_at` from `updated_at`; then the Swift table's text columns are blanked (`audio_path = ''`, `error = NULL`) — **`held_uploads` gets no row** (the Swift hub never held an upload; an upload record still in `RelayZone` is read once by the Go intake and is a repeat when its upload id is already a job); `settings` — `hub_meta.enabled`, per-device `start_sessions_granted`; `transport` — `hub_meta.transport = cloudkit`; `moved` — remove the originals from `MobileHub/`, write `MOVED`; `done` — `adopted_at` (identity adoption is Task 16; the hub stays off until both are set).
  **Once only:** `adopted_at` set → `Run` returns `ErrAlreadyAdopted` at once; a `MobileHub/hubstate.db` that appears after `adopted_at` → `ErrLaterMobileHub`, logged, nothing read.
  CLI (pinned, owner/Desktop verb, refused under an agent marker): `hub adopt --mobile-hub <dir> --settings-stdin --json` → `{"step","imported":{"devices","jobs","skipped"},"error"}`; `hub adopt --status --json` → same keys plus `"identity"` (`none|staged|adopted|confirmed`).
- **Depends on:** Task 5

- [ ] **Step 1: Fixture:** a Swift-shaped sidecar built in the test from the Swift `CREATE TABLE` text (as Plan 1a `TestSwiftShapedFileMigrates`), with rows in `devices`, `phone_recordings` (one per status), `slice_assets`, `relay_processed`, journal mode DELETE.
- [ ] **Step 2: Failing tests:** `TestAdoptImportsEveryTable` (devices, ledger, epochs, slice hashes intact; `hub_id` unchanged), `TestAdoptResumesAfterAKillAtEveryStep` (Review Focus 1: a fault seam returns at each step boundary; a second `Run` finishes with identical end state, one copy of every row), `TestAdoptRefusesAMissingFoldedInColumn` (`CheckSwiftFile`; nothing moved, `adopt_error = swift_schema`), `TestAdoptSwitchesToWAL`, `TestPhoneRecordingsMapToRecordingJobs` (table over the seven statuses), `TestRecordingMidTranscriptionAtAdoptionFailsOnceWithHubMoved` (each of the five in-progress statuses → one `failed`/`hub_moved` job; a second adoption run and later passes change nothing; the published `recording_job` carries the fixed text; the Mac's audio file still exists; no `recording_upload` echo is rewritten), `TestAdoptedJobsHoldNoText` (no `audio_path`/`error` text anywhere in the Go file after adoption), `TestAdoptCreatesNoHeldUploads`, `TestAPendingUploadAfterAdoptionIsARepeat`, `TestALaterMobileHubIsNeverImported` (Review Focus 2), `TestMovedNoteContent` (exact bytes), `TestAdoptIsRefusedUnderAnAgentMarker`, `TestHubAdoptJSONKeys`, `TestFILES01_AdoptLogsCountsOnly`.
- [ ] **Step 3:** `go test ./internal/hub/adopt ./cmd -run TestHubAdopt` → FAIL.
- [ ] **Step 4: Implement.**
- [ ] **Step 5:** → PASS; `make lint-diff`.
- [ ] **Step 6: Commit** `hub/adopt: one-time, resumable import of the Swift hub's sidecar, recordings and settings`.

### Task 14: `HubControlClient` and `HubCenter` in Desktop — heartbeat, view, status

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/HubControlClient.swift` (JSON lines over `hub.sock`), `WatchtowerDesktop/Sources/Services/HubCenter.swift`
- Modify: `WatchtowerDesktop/Sources/App/AppState.swift` (`hubCenter`), the sessions panel (`PendingSessionDeletes` changes → `desktop_view`), `SessionBackgroundProber` (`displayOver` → `desktop_view`)
- Test: `WatchtowerDesktop/Tests/Core/HubControlClientTests.swift`, `WatchtowerDesktop/Tests/Services/HubCenterTests.swift`

**Interfaces:**
- Consumes: Task 5 ops; Plan 1a `hub status --json` keys (+ Phase 2 `host`, `mode`, `recordings`).
- Produces:
  ```swift
  struct HubStatus: Decodable, Equatable { let state: String; let reason: String?; let hubID: String?; let transport: String?; let host: String?; let mode: String?; let recordings: String?; let adoption: String? }
  final class HubControlClient: Sendable { init(socketPath: String); func send(_ r: HubControlRequest) async throws -> HubControlAnswer; func watch() -> AsyncThrowingStream<HubEvent, Error> }
  @MainActor @Observable final class HubCenter {
      private(set) var status: HubStatus?
      func start(); func stop()          // heartbeat every 30 s while Desktop runs (op desktop_heartbeat); watch stream with reconnect 1 s → 30 s
      func publishView(hidden: Set<Int64>, displayOver: Set<Int64>) // coalesced 250 ms
  }
  ```
  No hub running → the client falls back to `watchtower hub status --json` for status and skips heartbeat/view (nothing to tell); never opens `hubstate.db`.
- **Depends on:** Task 5

- [ ] **Step 1: Failing tests:** `testHeartbeatEvery30Seconds` (fake clock + fake socket), `testWatchReconnectsWithBackoff`, `testUndoBatchReachesTheHub` (a pending delete → `desktop_view` with that id; Undo → without it), `testDisplayOverReachesTheHub`, `testNoHubFallsBackToCLIStatus`, `testDecodesPinnedStatusKeys`.
- [ ] **Step 2:** `make test-swift FILTER='HubControlClientTests|HubCenterTests'` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** → PASS; `make lint-swift`.
- [ ] **Step 5: Commit** `desktop: HubCenter over the hub control socket (heartbeat, view inputs, status)`.

### Task 15: Publishing on CloudKit — spacing, mailbox cadence, ask-alert signals, pull-now

**Files:**
- Modify: `internal/hub/runtime.go` (pass cadence by transport), `internal/hub/slices/publisher.go` (2 s spacing exercised), `internal/hub/slices/sources/work_alert.go` / `owner_ask.go` (signals)
- Create: `internal/hub/slices/signals.go`
- Test: `internal/hub/slices/cloudkit_test.go`, `internal/hub/runtime_test.go`

**Interfaces:**
- Consumes: Task 4 `transport.Signals`, `secure.Sealer.Signal`, `Event.PullNow`; Task 11.
- Produces:
  ```go
  const CloudKitActivePass, CloudKitIdlePass = 3 * time.Second, 30 * time.Second
  func SignalSource(...) // `sig-<wire name>` per open ask alert, as AskAlertSignal (protocol §4.8): written on CloudKit only, deleted when the alert closes
  ```
- **Depends on:** Task 11

- [ ] **Step 1: Failing tests:** `TestAKindIsSavedAtMostOncePerSpacingOnCloudKit` (2 s — the battery rule #724 rewritten, Plan 1a constant now exercised), `TestCloudKitPassIs3sWhileInTouchElse30s`, `TestPullNowRunsAPassAtOnce`, `TestAskAlertSignalWrittenAndDeletedLikeSwift` (Go twin of `AskAlertSignal` tests, same names in Go form), `TestSignalsNeverOnTheRelay`, `TestSignalRecordCarriesOnlyTheWireName` (canary: no ask text in the signal).
- [ ] **Step 2:** `go test ./internal/hub/slices ./internal/hub -run 'CloudKit|Signal|Pass'` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `hub: CloudKit cadence, ask-alert signals, pull-now passes`.

### Task 16: Two-phase key hand-over and the desktop-host identity

**Files:**
- Modify: `cmd/hub_adopt.go` (`--keys-fd`, `--confirm-deleted`), `internal/hub/adopt/keys.go` (new)
- Test: `internal/hub/adopt/keys_test.go`, `cmd/hub_adopt_test.go`

**Interfaces:**
- Consumes: Task 1 `identity.ForDesktopHost`, `Staging`; Task 13 `adopt.Run`; Plan 1a `identity.NewKeyring` (opens `k_meta_sealed`/`sealed_keys` with the wrap key — `TestKeyring_OpensSwiftSealedKeys`); `fsutil.AttachPayloads` (Desktop side, Task 22).
- Produces:
  ```go
  const MetaIdentity = "identity" // "staged" | "adopted" | "confirmed"
  type KeysPayload struct{ HubSig, HubKX, Wrap []byte } // JSON on the fd, base64; relay_auth is created by the Go hub (the Swift hub had none)
  func HandOver(ctx context.Context, hubDir string, fd *os.File, st identity.Staging) (string, error) // "adopted" | error class; zeroes the payload after use
  func ConfirmDeleted(hubDir string) error // identity → confirmed
  ```
  Order: read the fd to EOF (cap 4 KiB) → `SaveStaged` (overwrites) → open the sealed sidecar keys with the staged identity → on success `PromoteStaged` and `identity = adopted` in one sidecar transaction after the store write; answer `adopted` → on failure `DeleteStaged`, answer the class (`wrong_keys`, `no_sidecar`). An already `adopted`/`confirmed` identity answers `adopted` at once without reading new keys (the fd is drained and discarded). CLI: `hub adopt --keys-fd N --json` → `{"identity"}`; `hub adopt --confirm-deleted --json` → `{"identity"}`. Refused under an agent marker.
- **Depends on:** Task 1, Task 13

- [ ] **Step 1: Failing tests:** `TestHandOverStagesThenAdopts`, `TestWrongKeysDeleteTheStagedCopy`, `TestHandOverCrashBeforeAdoptedKeepsDesktopItems` (Review Focus 1: kill after `SaveStaged` → identity `staged`, Desktop sees no `adopted`, a re-run overwrites and adopts), `TestAdoptedAnswersAtOnce`, `TestConfirmDeletedOnlyAfterAdopted`, `TestKeysNeverTouchDisk` (a temp-dir walk during the hand-over finds no file containing the key bytes when the store is Keychain; with the file store only `identity.staged.key`/`identity.key` at 0600), `TestKeysNeverLogged` (`logcanary`), `TestPayloadZeroedAfterUse`.
- [ ] **Step 2:** `go test ./internal/hub/adopt ./cmd -run TestHubAdopt` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `hub/adopt: two-phase key hand-over over an inherited pipe`.

### Task 17: The Desktop recording queue over the control socket

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/PhoneRecordingQueue.swift` (replaces `MobileHub/PhoneRecordingJobs.swift`)
- Modify: `WatchtowerDesktop/Sources/Services/MeetingRecorderCenter.swift` (phone ingest entry by URL), `HubCenter` (`recording_queued` events)
- Test: `WatchtowerDesktop/Tests/Services/PhoneRecordingQueueTests.swift`

**Interfaces:**
- Consumes: Task 5 `recording_progress`, `desktop_watch`; Plan 1b `recording_claim` → `{"upload_id","audio_path","status"}`, `recording_finish`; Task 13 adopted rows (in-progress ones arrive `failed`/`hub_moved`, never claimable).
- Produces: on `recording_queued` (and once at start for jobs already `queued`/`claimed` by this Desktop — read by `hub recording list --json`, added here with pinned keys `[{"upload_id","status","phase","percent","audio_path"}]`): claim → `MeetingRecorderCenter.ingestPhoneRecording(url:)` → each processing phase → `recording_progress` → `recording_finish --transcript` or `--error <class>`. A `failed`/`hub_moved` row is never claimed or reported; the recorder's own pending job for that audio is left alone.
- **Depends on:** Task 14

- [ ] **Step 1: Failing tests:** `testQueuedRecordingIsClaimedAndIngested`, `testProgressPhasesReachTheHub` (transcribing 0→100, diarizing, summarizing), `testFinishCarriesTheTranscriptID`, `testFailureSendsAClassNeverText`, `testAHubMovedJobIsNeverClaimed`, `testNoHubLeavesTheQueueAlone`.
- [ ] **Step 2:** `make test-swift FILTER=PhoneRecordingQueueTests` → FAIL.
- [ ] **Step 3: Implement**; `go test ./cmd -run TestHubRecordingListJSONKeys` for the new verb.
- [ ] **Step 4:** → PASS; `make lint-swift`, `make lint-diff`.
- [ ] **Step 5: Commit** `desktop: phone recordings claimed, reported and finished through the hub`.

### Task 18: Dual transport and the switch (sim rules 8–13)

**Files:**
- Create: `internal/hub/switcher/{switcher.go,accept.go,announce.go,marker.go}`
- Modify: `internal/hub/runtime.go` (active + other transport), `internal/hub/actions/control.go` (`transport_switch` → switcher instead of the Plan 1a rejection), `internal/hub/identity/keyring.go` (`ReasonTransportSwitch`)
- Test: `internal/hub/switcher/{switcher_test.go,sim_switch_test.go}`

**Interfaces:**
- Consumes: Plan 1a `actions.Processor`, control queue, `link.Center.Grants`, `Keyring.Rotate`, `relay.Transport` (account state: `paying` per phone), Task 4 cloudkit client, Task 11.
- Produces:
  ```go
  package switcher
  const AntiFlap = 5 * time.Minute; const OtherPoll = 30 * time.Second
  type Config struct{ Store *state.Store; Keys *identity.Keyring; Relay, CloudKit transport.Transport; Processor *actions.Processor; Publisher *slices.Publisher; Grants func() ([]wire.DeviceGrant, error); Paying func(ctx context.Context) (map[string]bool, error); Clock func() time.Time }
  type Switcher struct{…}; func New(c Config) *Switcher
  func (s *Switcher) Active() transport.Transport
  func (s *Switcher) Request(ctx context.Context, from string, target transport.Kind, reason string) error // rules 8–10
  func (s *Switcher) Run(ctx context.Context) error // polls the other transport's mailboxes every OtherPoll for controls (rule 11)
  ```
  **Accepted switch (rule 11):** (1) finish every phone's mailbox on the old transport if reachable, in the old epoch, never waiting on an unreachable one; (2) `Rotate(ReasonTransportSwitch)`; (3) enqueue `transport_switched{target, epoch, by, at, keybox}` per phone on both transports wherever reachable (contract point 3) — the copy on the old transport sealed in the old epoch, plus the marker in the old transport's data zone (contract point 6a), both written before the hub stops publishing there; (4) toward the relay, `hub_on_relay` to the CloudKit mailbox of every ordered phone not paying; (5) set `hub_meta.transport`, write the relay data-zone marker (contract point 4), full republish on the new transport, apply only from the new transport. **Rule 12a:** an action read on the inactive transport → `transport_switched` again to a phone whose acked epoch < current, or `hub_on_relay` to one that cannot follow, once per record version; the record is left to the phone. Same record ids on both transports (one control id, two copies).
- **Depends on:** Task 11, Task 12

- [ ] **Step 1: Failing sim twins** (relay sim names, both fakes): `TestSwitchToCloudKitDuringRelayOutage`, `TestSwitchToRelayRejectedWithin5Min`, `TestSecondPhoneFollowsSwitch`, `TestHubOnRelayTellsFreePhone`, `TestMarkerLeadsReturningPhone`, `TestStaleActionGetsSwitchAgain`; plus `TestOnlyAPersonSwitches` (a transport failure never switches), `TestLastAcceptedSwitchWins`, `TestTransportSwitchedCarriesTheNewEpochKeybox` (the keybox opens with the phone's `dev_kx` and holds epoch e+1), `TestSwitchRotatesEpochOnce`, `TestOldTransportMailboxDrainedBeforeRotation`, `TestSwitchNoticeWrittenIntoTheTransportBeingLeft` (both directions: to the relay → `transport_switched` in every phone's CloudKit mailbox and the marker in `DataZone-<hub_id>`; to CloudKit → in every relay mailbox and `data/<hub>`; each sealed in the old epoch and opened by a `hubtest.Phone` holding only old keys; written before the last publish on the old transport), `TestALegacyPathPhoneGetsTheNoticeToo` (a phone that never sent `action_seq` still receives the control and the marker), `TestTheOldTransportMarkerIsNeverSwept` (CloudKit hygiene past 7 days leaves it).
- [ ] **Step 2:** `go test ./internal/hub/switcher ./internal/hub/actions` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** → PASS (Plan 1a's `TestTransportSwitchIsRejectedNotSupportedYet` is rewritten to `TestTransportSwitchOnAHeadlessHubIsRejected`: relay-only hubs keep the rejection, Phase 2); `make lint-diff`.
- [ ] **Step 5: Commit** `hub/switcher: transport switch both ways with an epoch per switch (sim rules 8–13)`.

### Task 19: The one-time v1-host restart (Desktop)

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/SessionHost/HostRestartStep.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Models/HostRestartList.swift`, `WatchtowerDesktop/Sources/Views/Shared/HostRestartNotice.swift`
- Modify: `WatchtowerDesktop/Sources/App/AppState+SessionHost.swift` (launch order: migrate → compact → restart step → adoption → daemon), the workspace switcher view (line), `SessionHostClient.swift` (a v1 hello used only by this step)
- Test: `WatchtowerDesktop/Tests/SessionHost/HostRestartStepTests.swift`, `WatchtowerDesktop/Tests/Core/HostRestartListTests.swift`, DesignShots

**Interfaces:**
- Consumes: spec §8 p. 4b steps 0–3 and Failures; Task 7 v2 client; `<app support>/session-host-restart.json`.
- Produces:
  ```swift
  struct HostRestartList: Codable { struct Row: Codable, Equatable { let scope: String; let rowID: Int64; let agent: String; let resumeID: String } var rows: [Row] }
  @MainActor @Observable final class HostRestartStep {
      enum Phase: Equatable { case notNeeded, waitingForContinue, stopping(done: Int, total: Int), relaunching(done: Int, total: Int), finished, failed(String) }
      static let noticeText = "Running sessions restart once with this update; their conversations continue"
      static let continueTitle = "Continue"
      static func waitLine(_ n: Int) -> String // "1 session waits to resume" / "N sessions wait to resume"
      func runIfNeeded() async; func pressContinue() async
  }
  ```
  Order pinned by a test: list every scope's runs as a v1 client and write the list **before** touching anything; per run, drop from `TerminalCenter`'s processes, **then** SIGHUP → 3 s → SIGKILL (exit = `closedByApp`, no PROJ-18 cleanup); forget the run; SIGTERM the idle v1 host (pid from `HelloOK`); `sessionhost` v2 started (`watchtower session-host` via the existing ensure path); relaunch this workspace's rows with resume, removing each from the list after launch; other workspaces' rows stay and are relaunched at that workspace's open; no conversation → today's resume-failure state; other failure → stopped with the reason, no cleanup. The daemon's hub does not start while a v1 host answers (Task 21).
- **Depends on:** Task 7, Task 3 (mockup approved)

- [ ] **Step 1: DesignShots** (from the Task 3 mockup): `hostRestartNotice` (waiting), `hostRestartBusy` (stopping 2/5), `hostRestartError` (failed, with **Retry**), `workspaceSwitcherWaitLine` (narrow width too); empty = `notNeeded` renders nothing (asserted in a model test).
- [ ] **Step 2: Failing tests:** `testNothingHappensUntilContinue` (closing/quitting leaves the old host and sessions; the notice returns next launch), `testListIsWrittenBeforeAnyStop`, `testDropThenSignalSoNoCleanup` (spec: "a test pins this order"), `testRelaunchWithResumeRemovesTheRow`, `testOtherWorkspacesWaitAndShowTheLine`, `testInterruptedRunResumesFromTheList` (rows already relaunched skipped; a v1 host still up handled from step 1), `testNoConversationEndsInResumeFailure`, `testOtherLaunchFailureLeavesTheRowStoppedWithReason`, `testCopyIsInTheModel` (`noticeText`, `continueTitle`, `waitLine(1)`, `waitLine(3)`).
- [ ] **Step 3:** `make test-swift FILTER='HostRestartStepTests|HostRestartListTests'` → FAIL.
- [ ] **Step 4: Implement**; colours via `Tone` only.
- [ ] **Step 5:** → PASS; `make desktop-shots DESKTOP_SHOTS=<dir>` compared with the mockup; `make lint-swift`.
- [ ] **Step 6: Commit** `desktop: the one-time restart of sessions from a v1 session host (asks #813, #814)`.

### Task 20: Old-epoch keys, entitlement, no copies left (sim rules 14–16)

**Files:**
- Modify: `internal/hub/identity/keyring.go` (multi-epoch retention), `internal/hub/state/epochs.go` (per-device acked epoch, `retire_after`), `internal/hub/switcher/entitlement.go` (new), `internal/hub/actions/control.go` (resend for an unknown epoch, second-copy delete), `internal/hub/transport/relay/transport.go` (`ENTITLEMENT_EXPIRED` `Control.detail`)
- Create: `internal/hub/state/migrations/00009_switch_epochs.sql`
- Test: `internal/hub/switcher/sim_entitlement_test.go`, `internal/hub/identity/retention_test.go`

**Interfaces:**
- Consumes: Task 18; Plan 1a `epoch_ack` (`00004`).
- Produces:
  ```go
  // retention = Plan 1a identity.PreviousEpochGrace (7 days) for every epoch, switch epochs included (ask #843)
  func (k *Keyring) Retained() ([]uint32, error)              // every epoch whose relay-lane keys are still accepted
  func (k *Keyring) RetireIfDone(acked map[string]uint32, heldIn map[uint32]bool) error // rule 14 with the 7-day cap
  ```
  - `00009`: `ALTER TABLE hub_epochs ADD COLUMN reason TEXT CHECK (reason IN ('age','cap','unlink','manual','transport_switch'))`, `retire_after REAL` (timestamps and an enum only).
  - Rule 14: an action sealed in an epoch no longer held → `resend_from(seq)` once per record version. Rule 15: the hub deletes what it read and a second copy of a control id unread. Rule 16: `ENTITLEMENT_EXPIRED` with `detail` naming a phone → act as that phone's `transport_switch(cloudkit, reason=entitlement_expired)`; no other paying phone → move to CloudKit (rule 11); another paying phone → stay, apply none of that phone's relay actions, `hub_on_relay` over CloudKit; an echo refused on the relay (`ENTITLEMENT_INACTIVE`) is owed and written over CloudKit **before** `hub_on_relay`. Plan 1a's queued entitlement/quota controls (sim rule 7a drops) are revisited: `ENTITLEMENT_INACTIVE` on a hub write now triggers rule 16 for the phone of that mailbox.
- **Depends on:** Task 18

- [ ] **Step 1: Failing sim twins:** `TestOldEpochActionAfter7DaysResealed` (the sim's `TestOldEpochActionAfter14DaysResealed` scenario with the 7-day cap of ask #843), `TestNoCopiesLeftOnRelayAfterSwitch` (Review Focus 4), `TestEntitlementExpiredFallsBackToCloudKit`, `TestEntitlementExpiredOtherPayingPhoneKeepsHub`, `TestLapsedPhoneActionAppliedBeforeHubKnewIsEchoed`, `TestHubActsOnEntitlementControl`; plus `TestSwitchEpochRetiredWhenEveryPhoneAcked`, `TestEveryEpochKeptAtMost7Days` (switch and non-switch rotations alike: 6 d 23 h accepted, 7 d → `resend_from`), `TestAPhoneOfflineOver7DaysAcrossASwitchRecovers` (the accepted behaviour below: a `hubtest.Phone` away 8 days follows the marker, reads its keybox on the new transport, its old-epoch actions get one `resend_from`, are resealed with the same `action_seq` and applied once), `TestSidecarHasNoNewUnsealedContentColumns` (allowlist: `reason: enum`, `retire_after: timestamp`).
- [ ] **Step 2:** `go test ./internal/hub/switcher ./internal/hub/identity ./internal/hub/state` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** → PASS; `make relay-interop RELAY=../relay` (the entitlement scenarios against the local stand's `/dev/entitlement`); `make lint-diff`.
- [ ] **Step 5: Commit** `hub: switch epochs, entitlement fallbacks, no copies left (sim rules 14–16)`.

### Task 21: Desktop-host live mode — `Resolve`, the bridge, the v1-host wait, status

**Files:**
- Modify: `internal/hub/hub.go` (`Resolve` desktop branch, `Dir`), `internal/hub/status.go` (reasons, keys), `internal/hub/runtime.go` (bridge supervisor, switcher, recordings dir), `cmd/hub.go`, `cmd/sync.go` (unchanged call)
- Test: `internal/hub/resolve_desktop_test.go`, `cmd/hub_test.go`

**Interfaces:**
- Consumes: Phase 2 `hub.Resolve`/`Dir`/`Mode`/`hostkind.Detect`; Tasks 1, 4, 10, 13, 15, 16, 18; Plan 1b `sessionhost.Dial` (`ErrHostV1`).
- Produces:
  ```go
  // Resolve on a desktop host (Phase 2 returned ModeOff/desktop_host):
  //   adopt step unfinished or identity not adopted → off, reason "awaiting_adoption" (or "adoption_failed" with adopt_error);
  //   MobileHub/hubstate.db present and no adopted_at → off, "awaiting_adoption";
  //   no Swift state and hub_meta.enabled != 1 → off, "disabled";
  //   a v1 session host answers → off, "session_host_v1" (re-checked each cycle; the daemon starts no host of its own then);
  //   policy MobileSync off → "policy_off"; else ModeLive with Transports ["cloudkit","relay"], Store identity.ForDesktopHost(...),
  //   RecordingsDir config.AppSupportDir()/recordings, the bridge supervisor and the switcher; relay origin optional on a desktop host (none → CloudKit only, relay side "no_relay_origin" in status, no switch to the relay accepted)
  // Dir: on a desktop host returns DefaultDir (ErrDesktopHost removed)
  // Status gains: Adoption ("none"|"in_progress"|"failed"|"done"), Bridge ("running"|"restarting"|"unavailable"), Identity ("keychain"|"file")
  ```
  `hub status --json` keys: Phase 2's set plus `"adoption","bridge","identity","switched_at","switched_by"` (additive). `hub phones --json` rows gain `"transport"` (`cloudkit|relay`, the phone's current one as the hub knows it) — the RC §10 transport indicator; the other §10 indicators are phase 4.
- **Depends on:** Task 10, Task 15, Task 16, Task 18

- [ ] **Step 1: Failing tests:** `TestDesktopHostOffUntilAdopted`, `TestResolveIgnoresALaterMobileHub` (Review Focus 2), `TestFreshDesktopHostStartsWhenEnabled` (no `MobileHub/`, `hub enable` → live, new `hub_id`, identity in the recorded store), `TestDaemonWaitsWhileAV1HostAnswers` (no hub, no `session-host` spawned; a v2 host appears → the hub starts within one cycle), `TestDesktopHostAnnouncesBothTransports`, `TestRecordingsDirIsAppSupport` (test seam: `config.AppSupportDir()` under `t.TempDir()`), `TestBridgeUnavailableSaysSoInStatus`, `TestHubStatusJSONKeys`, `TestHubPhonesJSONKeys` (with `transport`), `TestPolicy03_OffStopsDesktopHostHubKeepsSetting` (desktop host variant of the Plan 1a guard, same meaning).
- [ ] **Step 2:** `go test ./internal/hub ./cmd -run 'TestHub|TestResolve|TestDesktopHost|TestDaemonWaits'` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** → PASS; Phase 2's `TestResolve_DesktopHostNeverStartsALiveHub` is rewritten as `TestResolve_DesktopHostNeverStartsBeforeAdoption` (same meaning: no live hub beside Swift state); `make lint-diff`.
- [ ] **Step 5: Commit** `hub: live mode on a desktop host after adoption, the bridge, the v1-host wait`.

### Task 22: The Desktop adoption driver and Settings → Mobile hand-over states

**Files:**
- Create: `WatchtowerDesktop/Sources/Services/HubAdoptionDriver.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Models/HubAdoptionState.swift`
- Modify: `WatchtowerDesktop/Sources/App/AppState+MobileHub.swift` (rewritten: start order after Task 19's step), `WatchtowerDesktop/Sources/WatchtowerCore/Utilities/Constants.swift` (`mobileSyncEnabled` read once for adoption, then removed from defaults), `WatchtowerDesktop/Sources/App/AppState.swift`
- Test: `WatchtowerDesktop/Tests/Services/HubAdoptionDriverTests.swift`, `WatchtowerDesktop/Tests/Core/HubAdoptionStateTests.swift`, DesignShots

**Interfaces:**
- Consumes: Task 13 `hub adopt --mobile-hub … --settings-stdin --json`, `--status`; Task 16 `--keys-fd N`, `--confirm-deleted`; Kit `KeychainKeyStore.hubIdentity`/`deleteHubIdentity`; `fsutil.AttachPayloads` Swift twin (`Process` with an inherited pipe, the Files-outside-DB Stage A pattern).
- Produces:
  ```swift
  enum HubAdoptionState: Equatable { case notNeeded, inProgress(step: String), failed(reason: String), done
      var title: String; var detail: String?; var retryTitle: String? } // copy in the model, pinned by tests
  @MainActor final class HubAdoptionDriver { func run() async -> HubAdoptionState; func retry() async -> HubAdoptionState }
  ```
  Sequence (spec §12.1–§12.2): skip when `MobileHub/hubstate.db` is absent; `hub adopt` with settings `{enabled: mobileSyncEnabled, start_session_allows}` on stdin → `hub adopt --keys-fd 3` with the three items from `HubKeyStore` on the pipe → only on `{"identity":"adopted"}` delete the Desktop items, then `--confirm-deleted`; a missing confirm retries the delete at the next launch; any failure → `.failed(reason)` with **Retry**, the hub stays off (no Swift fallback). Settings → Mobile's toggle calls `hub enable|disable` (Task 23); `mobileSyncEnabled` readers (`Constants.swift`, `AppState.swift`, `AppState+MobileHub.swift`) read `hub status --json` instead.
- **Depends on:** Task 14, Task 16, Task 19, Task 21, Task 3 (mockup approved)

- [ ] **Step 1: DesignShots:** `mobileHandOverInProgress` (busy), `mobileAdoptionFailed` (error with **Retry**), `mobileAdoptionLoading`, narrow width of each.
- [ ] **Step 2: Failing tests:** `testKeysOnlyOverTheInheritedPipe` (no temp file, argv carries no key; a fake `Process` seam records fds), `testDesktopItemsDeletedOnlyAfterAdopted`, `testCrashBeforeConfirmRetriesTheDeleteNextLaunch`, `testFailureShowsRetryAndKeepsTheHubOff`, `testRunsAfterTheRestartStep` (order: restart step `finished` or `notNeeded` first), `testNoMobileHubSkips`, `testSettingsCarryEnabledAndAllows`, `testStateCopy` (every `title`/`detail`/`retryTitle`).
- [ ] **Step 3:** `make test-swift FILTER='HubAdoptionDriverTests|HubAdoptionStateTests'` → FAIL.
- [ ] **Step 4: Implement**; colours via `Tone`.
- [ ] **Step 5:** → PASS; `make desktop-shots DESKTOP_SHOTS=<dir>` vs the mockup; `make lint-swift`.
- [ ] **Step 6: Commit** `desktop: hand Mobile over to the Go hub once (state, then keys)`.

### Task 23: Settings → Mobile over `hub …`, the pairing sheet, the recordings control

**Files:**
- Create: `WatchtowerDesktop/Sources/ViewModels/MobileSettingsModel.swift`, `WatchtowerDesktop/Sources/ViewModels/MobilePairingModel.swift`
- Modify (rewrite): `WatchtowerDesktop/Sources/Views/Settings/MobileSettingsView.swift`, `WatchtowerDesktop/Sources/Views/Settings/MobileLinkSheet.swift`
- Test: `WatchtowerDesktop/Tests/ViewModels/MobileSettingsModelTests.swift`, `WatchtowerDesktop/Tests/ViewModels/MobilePairingModelTests.swift`, DesignShots

**Interfaces:**
- Consumes: `hub status|phones --json` (Task 21 keys), `hub unlink|allow|name|enable|disable --json`, `hub recordings on|off --json` → `{"recordings","stored"}` (Phase 2 Task 9), `hub pair --json --stream` events `qr|waiting|sas|linked|refused` + `{"confirm":…}` on stdin (Plan 1a Task 15), `HubCenter.status` and `desktop_watch` `pair`/`switched` events.
- Produces:
  ```swift
  @MainActor @Observable final class MobileSettingsModel {
      enum State: Equatable { case loading, off(reason: String), noPhones, phones([PhoneRow]), adoption(HubAdoptionState), error(String) }
      struct PhoneRow: Equatable, Identifiable { let id: String; let name: String; let transportLabel: String /* "iCloud" | "Relay" */; let switchedLine: String?; let typing, permissions, startSessions: Bool; let requests: [String] }
      var recordingsOn: Bool; var recordingsAvailable: Bool // off-only when the hub has no transcriber
      func load() async; func setEnabled(_ on: Bool) async; func setRecordings(_ on: Bool) async; func allow(_ id: String, _ grant: String, _ on: Bool) async; func unlink(_ id: String) async; func rename(_ name: String) async
      static let emptyText = "No phones linked"
  }
  @MainActor @Observable final class MobilePairingModel { enum Step: Equatable { case starting, qr(URL, expires: Date), waiting, sas(code: String, phone: String), linked(String), refused(String), failed(String) }; func start() async; func confirm(_ ok: Bool) async; func cancel() }
  ```
  The QR is rendered from the `qr` event's URL (today's QR view); the SAS and refusal texts are today's `MobileLinkCenter` strings moved into the model. Rows built with `SettingsSection` + `.kitRow`, actions on hover, no separators.
- **Depends on:** Task 3 (mockup approved), Task 21, Task 22

- [ ] **Step 1: DesignShots** (each light/dark): `mobileSettingsEmpty`, `mobileSettingsLoading`, `mobileSettingsError` (with **Retry**), `mobileSettingsBusy` (a write in flight), `mobileSettingsPhones` (two phones, one iCloud one Relay with "switched by …"), `mobileSettingsNarrow`, `mobileSettingsOff` (MDM `policy_off` reason), `mobilePairingQR`, `mobilePairingSAS`, `mobilePairingRefused`.
- [ ] **Step 2: Failing tests:** `testStatesFromHubJSON` (table: each `hub status` reason → its `State` and copy), `testTransportLabelPerPhone`, `testToggleCallsEnableDisable`, `testRecordingsSwitchCallsHubRecordings` (and `on` refused "this host has no transcriber" shown inline), `testAllowAndUnlinkCallTheCLI`, `testPairingStreamDrivesSteps` (scripted JSON lines → steps; confirm writes `{"confirm":true}`), `testCancelClosesTheStream`, `testEveryUIStringLivesInTheModel` (view source scan: no string literal besides SF Symbol names), `testNeverOpensTheSidecar`.
- [ ] **Step 3:** `make test-swift FILTER='MobileSettingsModelTests|MobilePairingModelTests'` → FAIL.
- [ ] **Step 4: Implement.**
- [ ] **Step 5:** → PASS; `make desktop-shots DESKTOP_SHOTS=<dir>` vs the mockup; `make lint-swift`.
- [ ] **Step 6: Commit** `desktop: Settings → Mobile and pairing over watchtower hub`.

### Task 24: Delete the Swift hub; guards, inventory, docs, guide

**Files:**
- Delete: `WatchtowerDesktop/Sources/Services/MobileHub/` (all), their tests under `WatchtowerDesktop/Tests/MobileHub/` (except `HubKeyringVectorTests.swift`, kept as the vector writer), `TrayAppDelegate`'s remote-notification forwarding to the hub, Swift `TerminalLaunch`/`SessionStartPlacement` start-path code left by Task 8 (their fixture tests stay as the Go dual-path check)
- Create: `WatchtowerDesktop/Tests/Core/DesktopNeverOpensTheSidecarTests.swift`
- Modify: `docs/inventory/workbench.md` (PROJ-12/16/21 Swift paths → Go files; PROJ-17 note: the Undo batch reaches the hub, Task 5), `docs/inventory/session-feed.md` (FEED Swift hub paths → Go), `docs/inventory/policy.md` (`MobileSyncPolicy.swift` → Go), `docs/inventory/README.md` (module paths), each with a changelog line citing spec approval and asks #807, #812, #813, #814
- Modify: `docs/features/go-hub.md` (phase 3: bridge, adoption, desktop live mode, switch, the Task 1 Keychain result), `docs/features/mobile-companion.md` (Swift hub sections replaced by a pointer; full rewrite is phase 4), `CLAUDE.md` (Mobile line), `docs/guide/features/iphone.md` (downgrade note: "after this update, an older Watchtower can't run Mobile — update instead"), the guide's privacy page (hub keys in the Keychain or a 0600 file per Task 1)

**Interfaces:** none new.
- **Depends on:** Task 6, Task 9, Task 17, Task 20, Task 22, Task 23

- [ ] **Step 1: Mapping table** in the PR body: every Swift hub test with a behavioural assertion → its Go twin (name, file); a Swift test without a twin blocks the deletion (spec §13 "Ported guards"). PROJ-16/21, FEED-05, POLICY-03 Swift guards → their Plan 1b Go twins, names unchanged.
- [ ] **Step 2: Failing test** `testDesktopNeverOpensTheSidecar` (no `hubstate.db` string in `WatchtowerDesktop/Sources`; no `MobileHub` directory read besides `MobileHubMovedGuard` and the adoption driver's existence check).
- [ ] **Step 3: Delete and re-point**; `go test ./docs/guide` (8 KB cap).
- [ ] **Step 4:** `make test-swift FILTER='DesktopNeverOpensTheSidecarTests|MobileSettingsModelTests|HubCenterTests'`, `go test ./internal/hub/...`, `make lint-swift`, `make lint-diff` → PASS.
- [ ] **Step 5: Commit** `desktop: the Swift hub is deleted; inventory and docs point at the Go hub`.

### Task 25: Phase 3 gate — a real Mac, real CloudKit, a today's-build phone

**Files:**
- Modify: `docs/features/go-hub.md` (gate record), `Makefile` (none expected)

**Interfaces:** none.
- **Depends on:** Task 24

- [ ] **Step 1: Automated gate:** `make test`, `make test-swift`, `make lint-all`, `make relay-interop RELAY=../relay`, `make kit-test`, `make mobile-test` (phone unchanged, must still pass) → all PASS.
- [ ] **Step 2: Manual checks on a real Mac** (owner's machine, a **copy** of the live data root first: `cp -R` into a scratch user account or a second macOS user — never the live install before the copy passes):
  - M1 Adoption: a Mac with today's release and a linked phone → install the build → the v1-host notice appears, **Continue** → sessions resume → Settings → Mobile shows "hand-over in progress" then the phone list; `hub status --json` `adoption: done`, same `hub_id`; the phone (today's App Store/TestFlight build) keeps working without re-pairing: asks, board move, session line typed, permission answer, recording upload (received, transcribed, progress phases on the phone).
  - M2 Interrupt: kill Desktop during the hand-over (after `hub adopt` state, before `--keys-fd`) → relaunch finishes; Keychain shows the Desktop items deleted only after `adopted`.
  - M3 Downgrade: install the previous release with the Task 2 guard → "Mobile is run by a newer Watchtower", no Swift hub runs; re-upgrade → the adopted links intact.
  - M4 Bridge: quit Desktop → the phone still gets updates (the daemon and bridge run); a silent push wakes a pass within seconds.
  - M5 FILES-01: `watchtower.log`, the bridge's log lines and `Console.app` for the bridge show ids, counts and classes only.
- [ ] **Step 3: Commit** `docs: Go hub phase 3 gate record`.

### Task 26: Ordered actions over CloudKit with a real phone — **blocked on relay client spec Phase 1**

**Files:**
- Create: `internal/hub/interop_cloudkit_test.go` (`//go:build interop_ck`, manual), `docs/features/go-hub.md` (record)

**Interfaces:**
- Consumes: Phone contract points 1, 2, 7; Tasks 10, 11.
- **Depends on:** Task 25; relay client spec Phase 1 on the phone.

- [ ] **Step 1:** A phone build with RC Phase 1 against the Go hub over real CloudKit: a1..a5 with a forced gap (`resend_from` once, every action applied once, in order), echo deletes leave `RelayZone` empty, a second phone in the shared scope never deletes or answers the first phone's controls (contract point 2), `skip_to` surfaces Not delivered on the phone.
- [ ] **Step 2: Commit** `docs: ordered actions over CloudKit verified with a real phone`.

### Task 27: Transport switch end to end — **blocked on relay client spec Phases 2–3, relay ask #805, Phase 2 Task 10**

**Files:**
- Create: `docs/features/go-hub.md` (record); extend `internal/hub/interop_test.go` (`TestInterop_SwitchBothWays`)

**Interfaces:**
- Consumes: Phone contract points 3–7; Tasks 18, 20.
- **Depends on:** Task 26; the blockers above.

- [ ] **Step 1:** Interop (Go phone emulator) `TestInterop_SwitchBothWays` against the local stand + `bridgefake`; then real devices: a paying phone switches the Mac to the relay (vouch + `add_slot` for the upgraded link, `transport_switched` with the keybox, the free phone gets `hub_on_relay`), back to iCloud at once, a second switch to the relay within 5 min refused with "available in N min", an entitlement lapse falls back per rule 16 with nothing dropped silently, and after each switch a phone that knows only the old transport reads the notice there (contract point 6a).
- [ ] **Step 2: Commit** `docs: transport switch verified end to end`.

---

## Decisions (owner, ask #843)

1. **A switch leaves a notice in the transport it leaves.** On every switch, both directions, the hub writes the sealed `transport_switched` control to every phone's mailbox there and the transport marker into that transport's data zone, sealed in the old epoch, before it stops publishing there (contract point 6a, Task 18). This reuses the `transport_switched` body and the marker of sim rules 11.3 and 12a; no other record in today's Kit fits. It replaces the earlier "`transport: relay` in the heartbeat" proposal and closes protocol open point 6 (amended in this branch).
2. **7 days of key retention everywhere, switch epochs included.** Sim rule 14's 14 days is not used (Global Constraints, Task 20; protocol Decisions amended). **Accepted behaviour:** a phone offline more than 7 days across a switch keeps reading the hub. It holds its own old keys, so it can open the marker in the old transport, follow it, and read its keybox (sealed to its `dev_kx`, not tied to an epoch) on the new transport. What it does notice: each of its queued actions sealed in the retired epoch is answered `resend_from` once and resealed with the same `action_seq` (one extra round trip, outbox shows "waiting"), and an action it no longer has lands in Not delivered (rule 6). Nothing is applied twice or dropped silently. Pinned by `TestAPhoneOfflineOver7DaysAcrossASwitchRecovers`.
3. **No `recording_jobs.audio_file` column.** A phone recording mid-transcription at adoption becomes one `failed` job with class `hub_moved`, which the phone sees as the fixed text in Task 13 (Tasks 5, 13, 17; test `TestRecordingMidTranscriptionAtAdoptionFailsOnceWithHubMoved`). **Correction to the brief:** these uploads were already echoed `received`, so the phone deleted its audio then (protocol §7.7). "The phone can re-send" holds only while the phone still has a copy. The plain audio stays on the Mac, in the recordings folder (the adoption never deletes it), so nothing is lost. If the owner wants the Mac to transcribe those files again, that is a later choice.

## Known limits

- The other RC §10 indicators (Relay unavailable, quota errors, undelivered count, Diagnostics, latency samples) and `send_alert` pushes are phase 4. Phase 3 shows only the transport per phone and who switched it last.
- A CLI-only Mac's `<data root>/.hub` relay links are not merged into a later Desktop adoption (Phase 2 Known limits). On such a Mac, Desktop finds no `MobileHub/`, so it starts the existing Go hub as a desktop host: the relay links stay and CloudKit is offered to new links only (spec §7.3).
- A phone whose Kit predates control records (today's App Store build) cannot read a switch notice. It shows the Mac as not updating until it is updated, and then reads the marker left in the old transport (contract point 6a).
- The bridge implements CloudKit conditional saves itself, over change tags. When the Kit's `ConditionalTransport` arrives with relay client Phase 1, both implementations exist until the bridge moves onto it (Later).

## Later (not in this plan)

- Move the bridge onto the Kit's `ConditionalTransport` once relay client Phase 1 merges, so one CloudKit conditional implementation remains.
- Phase 4: pushes, Desktop indicators, measurements, the full `mobile-companion.md` rewrite.

## Self-review (done while writing)

- **Spec coverage, §14 row 3:**
  - CloudKit bridge, §6.2: Tasks 4, 10, 15, 21.
  - Adoption, §12.1–§12.2: sidecar move, `MOVED`, once only, a later `MobileHub/` ignored, resumable (Task 13); two-phase keys (Task 16); Keychain or file (Task 1); CloudKit state moves to the bridge (Task 13 `transport.db`); mobile settings (Tasks 13, 22); downgrade guard ahead of the Go hub (Task 2).
  - Screens, §12.4: mockups (Task 3); Settings → Mobile (Tasks 22, 23); v1 notice and switcher line (Task 19).
  - New Session through Go, §11: Task 8. Requested stops: Task 7.
  - The switch both ways (rules 8–16) with epochs: Tasks 18, 20. Switch notice into the old transport (ask #843): Task 18. 7-day retention everywhere: Global Constraints, Task 20.
  - Swift hub deleted: Task 24.
  - §8 p. 4a: heartbeat and the recording queue over the socket (Tasks 14, 17), live recordings dir (Task 21), FILES-01 review of the queue (Tasks 5, 17).
  - §8 p. 4b: composer on `Deliver` (Task 7), v1-host restart (Task 19), daemon waits only for a v1 host (Task 21).
  - §12.3, phones notice nothing: Task 25 M1.
  - §13: bridge contract test (Task 10), branch tests named for adoption steps and each interruption (13, 16), pre-guard app (13, 21), once-only (13), v1 restart steps and failures (19), canaries over the bridge (4).
- **Carries landed:**
  - Undo batch and `displayOver` (Tasks 5, 14).
  - Spec-review prefix/suffix (Task 6).
  - Owner-write notice (Task 9).
  - `pragma_table_info` folded columns and DELETE → WAL (Task 13; Desktop never opens the sidecar, Global Constraints, Task 24).
  - `recording_job` reads adopted `phone_recordings` and keeps the 31-day prune (Tasks 13, 5).
  - Entitlement controls revisited, rule 16 (Task 20).
  - Heartbeat and claim/finish over the control socket (Tasks 14, 17).
  - Owner recording switch in Settings (Task 23).
  - `held_uploads` on adoption: explicitly empty, with a test (Task 13).
  - Recordings mid-transcription at adoption fail once as `hub_moved`, with no file-name column (Tasks 5, 13, 17; ask #843).
- **Types across tasks:**
  - `transport.SharedMailbox`/`Shares`/`Signals`, `Sealer.Signal`: Task 4 → 10, 11, 12, 15.
  - `cloudkit.New`/`Supervisor`: Task 4 → 21.
  - `OpDesktopView`/`OpRecordingProgress`/`OpDesktopWatch`: Task 5 → 14, 17.
  - `identity.ForDesktopHost`/`Staging`: Task 1 → 16, 21.
  - `adopt.Run`/`Status`/`MetaAdoptedAt`: Task 13 → 16, 21, 22.
  - `switcher.New`/`Request`: Task 18 → 20, 21.
  - `HubCenter`: Task 14 → 17, 22, 23.
  - `HostRestartStep`: Task 19 → 22.
  - `HubAdoptionState`: Task 22 → 23.
- **Dependency waves:**
  - Wave 1: Tasks 1, 2, 3, 4, 5, 6, 7, 8, 9.
  - Wave 2: Tasks 10, 11, 12, 13, 14.
  - Wave 3: Tasks 15, 16, 17, 18, 19.
  - Wave 4: Tasks 20, 21, then 22.
  - Wave 5: Task 23, then 24, then 25.
  - External, last: Tasks 26, 27.
  - Task 2 is released on its own, before any Go-hub release.
