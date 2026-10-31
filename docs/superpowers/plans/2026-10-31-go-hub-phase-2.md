# Go hub — Phase 2: headless hosts (Linux, a Mac without the app) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Phase 1 Go hub runs on real data on a headless host (linux/arm64, linux/amd64, a Mac with only the CLI) as a user service, pairs a phone from a terminal, is admitted to the relay by the phone's vouch, follows the relay-only rules of spec §7.3, and is accepted on a real Pi and a real CLI-only Mac driven from a real phone.

**Architecture:** Phase 1 starts the hub only in a `hubtest-*` workspace behind `WATCHTOWER_HUB_DIR` (Plan 1a Task 14). This plan adds a second, **live** mode next to that test mode: `hub.Resolve` picks the test mode exactly as before when `WATCHTOWER_HUB_DIR` is set, and otherwise starts a live hub in `<data root>/.hub` only on a host that `internal/hub/hostkind` classifies as headless (Linux always; a Mac with neither the Desktop app bundle nor the Swift hub's `MobileHub/` state) and only after the owner ran `hub enable` (done by `watchtower service install`). On a desktop host the live mode never starts and never creates or reads hub state, so the Go hub can never run beside the Swift hub on a Mac (spec §12.1); a desktop host gets the Go hub only through phase 3's adoption. Around that: Linux-safe paths (`session-host` socket in `$XDG_RUNTIME_DIR`, `AppSupportDir` off darwin, peer credentials on Linux), CI and release builds on native Linux runners (cgo: the SQLCipher amalgamation does not cross-compile without a C toolchain), `watchtower service install|uninstall|status` (systemd user unit, LaunchAgent), `session-host` started as its own transient systemd unit so a daemon restart keeps sessions, terminal pairing (QR in block characters, `[y/N]` SAS prompt), the relay-only pause, a Linux smoke test, vouching once the relay ships it, the guide page, and the manual device gate.

**Tech Stack:** Go 1.26 with cgo (SQLCipher over OpenSSL `libcrypto.so.3` on Linux, CommonCrypto on darwin), `golang.org/x/term` (already a direct dependency), `github.com/skip2/go-qrcode` (new, MIT, terminal half-block rendering), `golang.org/x/sys/unix` (`SO_PEERCRED`, `LOCAL_PEERCRED`), systemd user units and `systemd-run --user`, launchd LaunchAgents, GitHub Actions `ubuntu-22.04`/`ubuntu-22.04-arm`/`ubuntu-24.04-arm` runners; Swift only in the blocked Kit interop task.

**Spec:** `docs/superpowers/specs/2026-10-31-go-hub-design.md` — §14 row 2 (this phase), §7 (§7.3 headless hosts), §10 (terminal pairing, `transports`, hostname), §11 (`service install`, Claude Code login on a headless box), §12.1 (never two hubs), §12.2 (0600 identity file on Linux), §12.4 (terminal mockup), §12a (contract), §13 (Linux smoke, vouch branch tests, device gate), §15 (relay change), Decisions. Owner rulings on this plan: ask #827 (see Resolved). Prerequisites: Plans 1a (`docs/superpowers/plans/2026-10-31-go-hub-phase-1.md`) and 1b (`…-phase-1b.md`) merged; this plan builds on their **Produces** blocks only.

## External dependencies (ordered last)

| Blocker | What is missing | Tasks it blocks |
|---|---|---|
| **Relay ask #805** (spec §15 p. 1) | `device_kind = HUB` registering unvouched, `vouch_hub`, `HUB_NOT_VOUCHED`, revoke on leaving every slot. Not in the relay's `main` today (its proto has `DEVICE_KIND_PHONE`/`DEVICE_KIND_MAC`, `ATTESTATION_REQUIRED`/`FAILED`, `SLOT_LIMIT` only, and a Mac must attest). Until then the hub registers as `DEVICE_KIND_MAC` with no attestation, which only the local stand (attestation `off`) accepts. | Task 9; through it Tasks 10, 11, 12 |
| **Relay client spec Phases 2–3 on the phone** (neighbour session, Kit/phone) | Hosted relay client, phone identity, linking from the phone (`LinkPayload` v4 reading, `DeviceHello.relay_device_id`, `vouch_hub` + `promote_pairing`), "This hub needs Relay", "A free phone can't link this hub". | Tasks 11, 12 |
| **Relay deploy** | The vouch change live on the staging relay (staging accepts development App Attest). | Task 12 |

Tasks 1–8 need neither: they run against `memfake`, the in-process fake relay and the local stand with attestation `off`, driven by the Go phone emulator `hubtest.Phone`.

## Phone contract points (the phone must match; spec §12a)

The hub builds only what §12a fixes. The neighbour session's phone code must match these, and the shared fixture `WatchtowerKit/Tests/Fixtures/link/hub_contract_cases.json` (Plan 1a Task 1: cases `v4_headless`, `headless_linked`) already pins the bytes:

1. **QR of a headless hub** (`LinkPayload` v4): `transport: "relay"`, `transports: ["relay"]`, `relay_device_id` (lower-case unpadded base32 of SHA-256 of `relay_auth_pub`), `relay_auth_pub`, `mac_name` = the hub's display name (hostname by default, ≤ 60), **no** `data_share`/`relay_share`. A phone without Relay refuses on reading `transports == ["relay"]`, before it writes a hello ("A free phone can't link this hub"); the terminal says "Needs a phone with Relay." on its side.
2. **Pairing:** the phone opens a pairing slot naming the QR's `relay_device_id`; its sealed `DeviceHello` carries its own `relay_device_id` (without it the link completes but that phone can never read a relay-only hub).
3. **Vouch:** after the owner confirms the SAS in the terminal and the keybox opens, the phone sends `vouch_hub{hub_device_id = QR.relay_device_id, auth_pub = QR.relay_auth_pub}` with its assertion, then `promote_pairing`. A refusal leaves the hub `not_vouched`; the phone shows the server's reason.
4. **`device_grant`** of a headless hub: `ordered_actions: 1`, `transports: ["relay"]`, `relay_device_id`, `relay_auth_pub`. The phone hides the iCloud choice and, when its own entitlement lapses, shows "This hub needs Relay".
5. **Recording on a headless hub:** final echo `failed` with reason `not_supported`; the phone keeps the audio (Plan 1b Task 5). Whether a hub can record at all is a simple on/off capability **pending the protocol document** (the separate phone ↔ hub protocol document the owner approves on its own, ask #827): this plan does not decide its field; when the document lands, the hub publishes what it says (a headless hub = off) in a follow-up task.
6. **Grants:** typing and starting sessions stay requested by the phone and allowed on the host (`watchtower hub allow <device> typing|start_sessions`), as Plan 1a Task 11.

## Global Constraints

All Global Constraints of Plans 1a and 1b hold (byte compatibility, zone bytes, E2E red line, FILES-01, migrations as the sidecar's own goose provider, guard tests one-to-one, hygiene, inner loop). In addition:

- **Platforms** (spec goal 1): `darwin/arm64`, `darwin/amd64`, `linux/arm64`, `linux/amd64`. Linux builds link `libcrypto.so.3` dynamically (`internal/sqlcipher/wt_cgo.go`: `-DSQLCIPHER_CRYPTO_OPENSSL`, `-lcrypto -lm`) and are built on `ubuntu-22.04` runners: glibc floor **2.35**, so they run on Debian 12 / Raspberry Pi OS bookworm (2.36) and Ubuntu 22.04+. `CGO_ENABLED=0` does not build (`internal/sqlcipher/wt_nocgo.go`), and a cross build from macOS fails for the same reason: every Linux build runs on a native Linux runner.
- **Never two hubs** (spec §3 anti-goal, §12.1): a live hub starts only on a headless host. Desktop host signals (darwin): `/Applications/Watchtower.app/Contents/Info.plist` or `~/Applications/Watchtower.app/Contents/Info.plist` holding the bundle id `com.watchtower.desktop`, or a directory `config.AppSupportDir()/MobileHub`. On a desktop host the live mode creates, opens and reads nothing under the hub dir or `MobileHub/` (existence checks only); the test mode of Plan 1a is unchanged. The check runs **once, at start** (ask #827): a Desktop app installed later on a CLI-only Mac gets no stop or hand-over.
- **Live hub dir** `<config.DataRoot()>/.hub` (dir 0700, files 0600; `.hub` cannot be a workspace name: `ValidWorkspaceRe` = `^[a-zA-Z0-9][a-zA-Z0-9_.-]*$`). Hub identity there in `identity.key` through Plan 1a's `identity.FileStore` (0600, a looser mode refused) on Linux and on a CLI-only Mac (spec §12.2, §7.3).
- **Relay-only** (spec §7.3): a headless hub's `transports` are `["relay"]` in the QR and in every `device_grant`, it has no CloudKit bridge, and a phone's `transport_switch` keeps Plan 1a's `transport_switch_rejected` answer. With no paying phone (`get_account_state` → no phone with `paying`), the hub pauses: it keeps its state and local work, saves and deletes nothing, runs no handler, and re-reads the account state every **5 min** and on every `ENTITLEMENT_EXPIRED`/`SLOT_REMOVED` control or `ENTITLEMENT_INACTIVE` error.
- **Host differences, all of them** (spec §7.3): no CloudKit bridge, no recordings (`failed(not_supported)`), owner-away always away and no keep-awake on Linux (Plan 1b Task 7), no `.copied` fallback (`cannot_type`, Plan 1b Task 2), `clonefile` → plain copy on Linux (`workbenchgit/clone_other.go`), service manager systemd (Linux) / launchd (CLI-only Mac), key store 0600 file.
- **`session-host` survives a daemon restart:** under systemd the daemon starts the host as its own transient user unit `watchtower-session-host` (`systemd-run --user`), never as a child in the daemon unit's cgroup (a stop or restart of that unit would kill every session, against PROJ-20's "an update keeps sessions running"; PROJ-20 amendment, Linux only, approved in ask #827); under launchd the plist sets `AbandonProcessGroup`.
- **Linux socket and support paths:** the `session-host` socket lives in `$XDG_RUNTIME_DIR` (owned by the user, mode 0700) or else in `<data root>/.run` (0700), never in the shared `/tmp`; the file name is unchanged (`watchtower-sh-<first 8 hex of SHA-256("com.watchtower.desktop")>.sock`). `config.AppSupportDir()` off darwin is `<data root>/.support`. darwin paths are unchanged (Plan 1b's `paths.json` fixture still passes). Approved in ask #827.
- **Relay origin** = `WATCHTOWER_RELAY_ORIGIN` if set, else config `hub.relay_origin`, else ldflags `watchtower/internal/hub.DefaultRelayOrigin` (empty until the relay session announces the production origin); empty → hub off, reason `no_relay_origin`. Accepted: `https://host[:port]` with no path, query or fragment; `http://` only for `127.0.0.1`, `localhost`, `[::1]`. Plans and docs write `<staging-relay-origin>`, never the real staging host.
- **Owner verbs on a headless host** (ask #827): they go through `watchtower hub …` (and `watchtower service …`): `service install|uninstall`, `hub pair|allow|unlink|enable|disable|name` are refused under an agent marker (as Plan 1a Task 15) and confirmed by the terminal — the human `hub pair` needs stdin and stdout to be terminals. AGENT-07's Desktop-confirmed gestures stay refused on Linux (no Desktop to confirm them). No sudo is ever run by Watchtower.
- **Pinned terminal copy** (spec §10; the rest reviewed in the Task 6 mockup): `Confirm code 1234 on your phone? [y/N] `.
- **FILES-01 on the host:** unit files hold no secret (only `PATH`), the daemon's stdout/stderr under launchd go to `/dev/null` (it writes `watchtower.log` itself), journald sees only what the daemon already logs (ids, counts, classes).
- **Inner loop:** `go test ./<pkg>`, `make lint-diff`, `bash scripts/tests/<file>.sh` for shell; the Linux-only tests run in the CI Linux jobs, and every rule they pin also has an OS-parameterised test that runs on the dev Mac. The full gate runs once, in Task 12.

## Review Focus

1. **A live hub beside the Swift hub.** A Mac with the app (or with `MobileHub/` from an older app) must never start a live hub, even with `hub enable` written by hand. → Task 3 `TestResolve_DesktopHostNeverStartsALiveHub`, `TestHubCLIRefusesTheLiveDirOnADesktopHost`; Task 5 `TestInstallRefusedOnADesktopHost`.
2. **A daemon restart that kills the sessions.** `systemctl --user restart watchtower.service` (an update) must leave every agent running. → Task 4 `TestEnsureUnderSystemdUsesATransientUnit`; Task 12 step P14.
3. **A shared `/tmp` on Linux.** Another local user pre-creating the host socket or its `.lock` must not capture a phone line or stop the host. → Task 1 `TestSocketDirLinuxRefusesAForeignOrLooseRuntimeDir`, `TestSocketDirLinuxFallbackIsPrivate`.
4. **A phone name that is a terminal escape.** The phone names itself; the terminal prints it before the SAS prompt. → Task 6 `TestHubPairEscapesThePhoneName`.
5. **A binary that does not start on the Pi.** A runner image upgrade raising the glibc requirement past bookworm's. → Task 2 `scripts/check-glibc.sh` in the build job.

---

### Task 1: Linux-safe paths, peer credentials and the darwin-only audit

**Files:**
- Modify: `internal/sessionhost/paths.go` (`DefaultSocket` through `socketDirFor`)
- Modify: `internal/config/config.go` (`AppSupportDir` through `appSupportDirFor`)
- Create: `internal/hub/dirs.go` (`DefaultDir`)
- Create or modify: `internal/hub/peercred_linux.go`, `internal/hub/peercred_darwin.go` (behind Plan 1a Task 14's peer-credential seam; if 1a already ships both, this task only adds the tests)
- Modify: `cmd/hub_recording.go` (`hub desktop heartbeat` refused off darwin)
- Test: `internal/sessionhost/paths_test.go`, `internal/config/config_test.go`, `internal/hub/dirs_test.go`, `internal/hub/peercred_linux_test.go` (`//go:build linux`), `cmd/hub_recording_test.go`

**Interfaces:**
- Consumes: `sessionhost.SocketPath`, `sessionhost.SocketEnv`, `config.DataRoot`, the control socket of Plan 1a Task 14.
- Produces:
  ```go
  package sessionhost
  func socketDirFor(goos, xdgRuntimeDir, tempDir, dataRoot string, uid int, stat func(string) (os.FileInfo, error)) (string, error)
  // darwin: tempDir (unchanged). linux: xdgRuntimeDir when absolute, a directory owned by uid with mode 0700; else <dataRoot>/.run, created 0700 (and tightened if looser).
  package config
  func appSupportDirFor(goos, home, dataRoot string) string // darwin: ~/Library/Application Support/Watchtower; else <dataRoot>/.support
  package hub
  func DefaultDir() (string, error) // <config.DataRoot()>/.hub
  func peerUID(c *net.UnixConn) (int, error) // linux: SO_PEERCRED; darwin: LOCAL_PEERCRED (xucred)
  ```
- **Depends on:** none (Phase 1 merged)

- [ ] **Step 1: Failing tests:** `TestSocketDirDarwinUnchanged` (`socketDirFor("darwin", …)` = tempDir; `TestPathsFixture` still passes), `TestSocketDirLinuxPrefersXDGRuntimeDir`, `TestSocketDirLinuxRefusesAForeignOrLooseRuntimeDir` (owned by another uid, or mode 0755 → `<dataRoot>/.run`; Review Focus 3), `TestSocketDirLinuxFallbackIsPrivate` (created 0700; an existing 0755 dir is tightened; a symlink is refused), `TestAppSupportDirOffDarwinIsUnderDataRoot`, `TestDefaultHubDirCannotBeAWorkspace` (`.hub` fails `ValidWorkspaceRe`), `TestControlSocketAcceptsTheSameUIDOnLinux` (linux-tagged: a real connection from this process → accepted), `TestControlSocketRefusesAnotherUID` (seam returns uid+1 → closed, no request read), `TestDesktopHeartbeatRefusedOffDarwin` (`runtime.GOOS` seam = `linux` → exit 1 "there is no Watchtower app on Linux", `hub_meta.desktop_seen` never written — so a headless host keeps answering recordings `not_supported`).
- [ ] **Step 2:** `go test ./internal/sessionhost ./internal/config ./internal/hub ./cmd -run 'SocketDir|AppSupportDir|DefaultHubDir|ControlSocket|DesktopHeartbeat'` → FAIL.
- [ ] **Step 3: Implement.** `cmd/session_host.go` keeps calling `DefaultSocket`, so the host and its clients agree; the host log follows `AppSupportDir`.
- [ ] **Step 4: Audit note.** Add a "Linux behaviour" table to `docs/features/go-hub.md` listing every darwin-only piece on the daemon path and what Linux does instead — `internal/policy` (no MDM reader: no profile, no restriction, POLICY-01), `internal/backupexclude` (no-op), `internal/auditlog` (no unified-log line; READ-02 already says "a no-op off darwin"), `internal/ownerconfirm` (no Desktop: AGENT-07 confirmation gestures are refused), `internal/sessioncleanup` birth time (unknown → a worktree not owned by record is kept), `internal/workbenchgit` (plain copy for `.worktreeinclude`), `internal/hub/platform` (always away, no keep-awake), `internal/chat` sandbox (claude.ai mode off), `internal/planusage` (credentials file, no Keychain), `internal/daemon` process identity (`ps -o lstart=`), the clipboard (`cannot_type`), and this task's three fixes.
- [ ] **Step 5:** → PASS; `make lint-diff`.
- [ ] **Step 6: Commit** `hub: Linux-safe socket and support paths, peer credentials, darwin-only audit`.

### Task 2: Linux builds — CI on arm64, release tarballs, glibc floor, CLI-only Mac zip

**Files:**
- Modify: `.github/workflows/ci.yml` (job `go-linux-arm64`)
- Create: `.github/workflows/linux-build.yml` (`workflow_dispatch` and tags `v*`)
- Create: `scripts/build-linux.sh`, `scripts/check-glibc.sh`, `scripts/tests/test-build-linux.sh`
- Modify: `scripts/build-app.sh` (CLI zip after notarization), `Makefile` (`test-scripts` runs the new suite; remove Plan 1b Task 17's local `GOOS=linux GOARCH=arm64 go build ./...` check, which cannot build cgo without a cross C toolchain, with a comment pointing at the CI job), `.claude/commands/release.md` (artifact step: the two Linux tarballs from the tag's `linux-build` run and the CLI zip, attached only from the launch release — decided by agent, see Resolved)

**Interfaces:**
- Produces:
  - CI job `go-linux-arm64` on `ubuntu-24.04-arm` (same `gate` condition as Go Test, `timeout-minutes: 30`): `apt-get install libssl-dev`, `go build ./...`, `go test ./internal/hub/... ./internal/sessionhost/... ./internal/sessionstart/...`, and Task 8's `make hub-smoke`.
  - `scripts/build-linux.sh VERSION OUTDIR`: `go build -tags codegrammars -ldflags "-X watchtower/cmd.Version=$VERSION -X watchtower/cmd.Commit=<sha> -X watchtower/cmd.BuildDate=<utc>"`, then `check-glibc.sh`, then `watchtower-$VERSION-linux-$(go env GOARCH).tar.gz` (one file `watchtower`, mode 0755) and `…tar.gz.sha256`. No OAuth client ids are baked in (none are needed for Workbench).
  - `scripts/check-glibc.sh BINARY 2.35`: fails when `objdump -T` shows a `GLIBC_x.y` newer than the floor, or when `readelf -d` lists a `NEEDED` library outside `libc.so.6`, `libm.so.6`, `libresolv.so.2`, `libpthread.so.0`, `libdl.so.2`, `ld-linux-*.so.*`, `libcrypto.so.3`.
  - `linux-build.yml`: matrix `ubuntu-22.04` (amd64) / `ubuntu-22.04-arm` (arm64), Go `1.26.9`, `libssl-dev`, `scripts/build-linux.sh "${GITHUB_REF_NAME}" dist`, `actions/upload-artifact` (`watchtower-linux-<arch>`, 30 days).
  - `build-app.sh`: after the ZIP is notarized, `build/Watchtower-CLI-<version>-arm64.zip` = the signed `Contents/MacOS/watchtower` (its cdhash is in the notarized submission), added to `checksums.txt`; the ad-hoc branch skips it.
- **Depends on:** none

- [ ] **Step 1: Failing shell suite** `scripts/tests/test-build-linux.sh` (stubs `go`, `objdump`, `readelf`, `tar`, `sha256sum` on `PATH`): `test_names_carry_version_and_arch`, `test_glibc_newer_than_floor_fails` (stub prints `GLIBC_2.38`), `test_unexpected_needed_library_fails` (`libsqlite3.so.0`), `test_ldflags_carry_version`, `test_tarball_holds_only_the_binary`.
- [ ] **Step 2:** `bash scripts/tests/test-build-linux.sh` → FAIL.
- [ ] **Step 3: Implement** the scripts, the workflow, the CI job and the `build-app.sh` step (its existing suite `scripts/tests/test-build-app*.sh` keeps passing; add `test_cli_zip_only_on_the_signed_branch`).
- [ ] **Step 4:** `make test-scripts` → PASS; `actionlint .github/workflows/*.yml` if installed; push the branch and dispatch `linux-build` once: both artifacts appear and the job log shows `check-glibc: max GLIBC_2.3x <= 2.35`.
- [ ] **Step 5: Commit** `build: Linux tarballs on native runners, arm64 CI job, glibc floor, CLI-only Mac zip`.

### Task 3: Host kind and the live headless mode

**Files:**
- Create: `internal/hub/hostkind/{hostkind.go,probe.go}`
- Modify: `internal/hub/hub.go` (`Resolve`, the start-time host check), `internal/hub/status.go` (reasons, `Host`, `Mode`), `internal/hub/control.go` (`hub.Dir`)
- Modify: `internal/config/config.go` (`Hub.RelayOrigin`), `cmd/config.go` (`knownConfigKeys["hub.relay_origin"]` + validation), `cmd/hub.go` (dir resolution, status keys), `cmd/sync.go` (call `hub.Resolve`)
- Test: `internal/hub/hostkind/hostkind_test.go`, `internal/hub/resolve_test.go`, `cmd/hub_test.go`, `cmd/config_test.go`

**Interfaces:**
- Consumes: Plan 1a `hub.FromEnv`, `hub.Options`, `hub.Run`, `hub.ReadStatus`, `state.Store.Meta(state.MetaEnabled)`, `state.MetaDisplayName`, `identity.FileStore`, `link.HostInfo`, `policy.MobileSync()`; Task 1 `hub.DefaultDir`.
- Produces:
  ```go
  package hostkind
  type Kind string; const ( Desktop Kind = "desktop"; Headless Kind = "headless" )
  type Probe struct{ GOOS, Home, AppSupport string; Stat func(string) (os.FileInfo, error); ReadFile func(string) ([]byte, error) }
  func System() Probe
  func Detect(p Probe) (k Kind, signal string) // signal "app_bundle" | "swift_hub_state" | "" ; non-darwin → Headless
  const BundleID = "com.watchtower.desktop"
  package hub
  type Mode string; const ( ModeOff Mode = ""; ModeTest Mode = "test"; ModeLive Mode = "live" )
  func Resolve(cfg *config.Config, d *db.DB, p hostkind.Probe) (Options, Mode, error) // the daemon's only entry; FromEnv stays as its test branch
  func Dir(cfg *config.Config, p hostkind.Probe) (dir string, mode Mode, err error) // CLI: WATCHTOWER_HUB_DIR, else DefaultDir on a headless host, else ErrDesktopHost
  var ErrDesktopHost = errors.New("hub: mobile on this Mac is run by the Watchtower app")
  var DefaultRelayOrigin string // ldflags
  func RelayOrigin(cfg *config.Config) string
  func DefaultName() string // hub_meta.display_name, else os.Hostname() up to its first '.', clipped to wire.MaxMacNameLength
  // Options gains: Mode Mode; Host hostkind.Kind; Transports []string
  // Status gains: Host, Mode string; reasons gain "desktop_host", "no_relay_origin"
  ```
  **Resolve:** `WATCHTOWER_HUB_DIR` set → `ModeTest` through `FromEnv`, exactly Plan 1a (a set dir never falls back to live). Else `Detect`; `Desktop` → `ModeOff`, reason `desktop_host`, nothing created or opened. Else dir = `DefaultDir`: `hubstate.db` absent or `hub_meta.enabled` ≠ `1` (opened read-only) → off `disabled`, dir not created; `policy.MobileSync() == off` → `policy_off`; `RelayOrigin` empty → `no_relay_origin`; else `ModeLive` with `Transports: ["relay"]`, `identity.FileStore{<dir>/identity.key}`, `RecordingsDir: <dir>/recordings` (never written: no Desktop heartbeat on a headless host). `Detect` runs once per `Resolve`, i.e. at hub start; there is no runtime re-check (ask #827). Daemon log lines: `hub: started (live, headless)`, `hub: started (test workspace)`, `hub: off (<reason>)`.
  **CLI:** every `hub …` verb resolves its dir through `hub.Dir`; on `ErrDesktopHost` `hub status` prints state `off`, reason `desktop_host`, and every other verb exits 1 with "Mobile on this Mac is run by the Watchtower app." `hub status --json` keys become `{"state","reason","hub_id","relay_device_id","transport","impl","dir","phones","host","mode"}` (additive). `hub enable` on a headless host creates `DefaultDir` 0700.
- **Depends on:** Task 1

- [ ] **Step 1: Failing tests:** `TestDetect_LinuxIsHeadless`, `TestDetect_DarwinAppBundleIsDesktop` (both locations), `TestDetect_DarwinSwiftHubStateIsDesktop`, `TestDetect_DarwinCLIOnlyIsHeadless`, `TestDetect_ABundleWithAnotherIDIsIgnored`, `TestResolve_TestModeUnchangedWhenHubDirSet` (Plan 1a's `FromEnv` cases through `Resolve`), `TestResolve_DesktopHostNeverStartsALiveHub` (Review Focus 1: probe = desktop, `hub_meta.enabled = 1` written by hand into `DefaultDir` → `ModeOff`; a listing of `DefaultDir` and `MobileHub/` before and after is identical, mtimes included), `TestResolve_LiveIsOffUntilEnabled` (dir not created), `TestResolve_LiveNeedsARelayOrigin`, `TestRelayOriginPrecedence`, `TestConfigSetRelayOriginValidates` (`https://relay.example.com` ok; `http://relay.example.com`, a path, a query → refused, nothing written; `http://127.0.0.1:8787` ok), `TestLiveHubAnnouncesRelayOnly` (`link.Center.Issue` → `Transports == ["relay"]`, `DataShare`/`RelayShare` nil; every `Grants()` row `Transports == ["relay"]`), `TestLiveHubUsesTheFileIdentityStore`, `TestDefaultNameIsTheHostname` (`pi-acme.local` → `pi-acme`; `display_name` wins), `TestHubStatusJSONKeys` (updated), `TestHubCLIRefusesTheLiveDirOnADesktopHost`, `TestHubEnableCreatesTheLiveDirOnAHeadlessHost`.
- [ ] **Step 2:** `go test ./internal/hub/... ./cmd -run 'TestHub|TestConfigSet|TestSyncDaemon'` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** → PASS (Plan 1a's `internal/hub` tests unchanged); `make lint-diff`.
- [ ] **Step 5: Commit** `hub: live mode on headless hosts only (host kind, data-root hub dir, relay origin)`.

### Task 4: `session-host` under a service manager

**Files:**
- Modify: `internal/sessionhost/ensure.go`
- Test: `internal/sessionhost/ensure_test.go`

**Interfaces:**
- Consumes: Plan 1b Task 11 `sessionhost.Ensure(ctx, socket, exe)`, `ErrHostV1`.
- Produces:
  ```go
  type Spawner interface{ Spawn(ctx context.Context, exe, socket string) error }
  func EnsureWith(ctx context.Context, socket, exe string, s Spawner) error // Ensure = EnsureWith(ctx, socket, exe, SystemSpawner(os.Getenv, exec.LookPath))
  func SystemSpawner(getenv func(string) string, lookPath func(string) (string, error)) Spawner
  // linux with INVOCATION_ID set and systemd-run on PATH → transient unit; else the detached (setsid) spawn of Plan 1b
  const SystemdUnit = "watchtower-session-host"
  ```
  Transient unit argv, exactly: `systemd-run --user --unit=watchtower-session-host --collect --quiet --property=UMask=0077 -- <exe> session-host --socket <socket>`. An exit saying the unit already exists or is active means another `Ensure` won: dial again, not an error. The host still exits 60 s after its last session (PROJ-20), which ends the transient unit.
- **Depends on:** Task 1

- [ ] **Step 1: Failing tests:** `TestEnsureUnderSystemdUsesATransientUnit` (Review Focus 2: fake runner records the argv above byte for byte; no child of the test process), `TestEnsureOutsideSystemdSpawnsDetached`, `TestEnsureOnDarwinNeverUsesSystemdRun` (`INVOCATION_ID` set, GOOS seam darwin → detached), `TestEnsureTreatsAnExistingUnitAsRunning`, `TestEnsureNeverReplacesAV1Host` (Plan 1b's, unchanged).
- [ ] **Step 2:** `go test ./internal/sessionhost -run Ensure` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `sessionhost: start the host as its own systemd unit so a daemon restart keeps sessions`.

### Task 5: `watchtower service install|uninstall|status` and the headless workspace profile

**Files:**
- Create: `internal/service/{service.go,systemd.go,launchd.go}`, `internal/service/testdata/{watchtower.service.golden,com.watchtower.daemon.plist.golden}`
- Create: `cmd/service.go`
- Modify: `cmd/workspace.go` (`--headless`)
- Test: `internal/service/service_test.go`, `cmd/service_test.go`, `cmd/workspace_test.go`

**Interfaces:**
- Consumes: Task 3 `hostkind.Detect`, `hub.Dir`; Plan 1a `hub enable` write path; `initWorkspace`; `features.All()` (`ConfigKey`, `Core`); `refuseUnderAgent`.
- Produces:
  ```go
  package service
  type Unit struct{ Exe, Path string } // Exe absolute (os.Executable, symlinks resolved); Path = the installing shell's PATH
  func SystemdUnit(u Unit) string
  func LaunchdPlist(u Unit) string
  type Runner func(ctx context.Context, name string, args ...string) ([]byte, error)
  type Installer struct{ GOOS, Home, ConfigHome, User string; UID int; Run Runner }
  type Status struct{ Manager string; Installed, Running bool; Linger *bool }
  func (i Installer) Install(ctx context.Context, u Unit) (Status, error)
  func (i Installer) Uninstall(ctx context.Context) (Status, error)
  func (i Installer) Status(ctx context.Context) (Status, error)
  const SystemdUnitName = "watchtower.service"; const LaunchdLabel = "com.watchtower.daemon"
  ```
  **systemd unit** (golden), at `$XDG_CONFIG_HOME/systemd/user/watchtower.service` (default `~/.config/…`):
  ```ini
  [Unit]
  Description=Watchtower daemon (workbenches and the phone hub)
  After=network-online.target
  Wants=network-online.target

  [Service]
  Type=simple
  ExecStart=<exe> sync --daemon
  Restart=on-failure
  RestartSec=10
  TimeoutStopSec=30
  UMask=0077
  Environment=PATH=<path>

  [Install]
  WantedBy=default.target
  ```
  Install runs `systemctl --user daemon-reload`, then `systemctl --user enable --now watchtower.service`; reads `loginctl show-user <user> --property=Linger --value`, and on `no` prints "Run `sudo loginctl enable-linger <user>` so Watchtower starts at boot and keeps running after you log out." (never runs it). **LaunchAgent** (golden) at `~/Library/LaunchAgents/com.watchtower.daemon.plist`: `Label`, `ProgramArguments` [`<exe>`, `sync`, `--daemon`], `RunAtLoad` true, `KeepAlive` {`SuccessfulExit` false}, `AbandonProcessGroup` true, `ProcessType` `Background`, `EnvironmentVariables` {`PATH`}, `StandardOutPath`/`StandardErrorPath` `/dev/null`; `launchctl bootstrap gui/<uid> <plist>`, or `user/<uid>` when `launchctl print gui/<uid>` fails (no console login). Uninstall: `systemctl --user disable --now` + remove + `daemon-reload` / `launchctl bootout` + remove; never touches data, the hub dir or a running `session-host`.
  **`service install` order:** refused under an agent marker; refused on a desktop host ("This Mac has the Watchtower app, which runs the daemon itself."); `initWorkspace(configPath, override, name, headless bool)` (the existing function gains the flag; `workspace init` passes `--headless`); `hub enable` (direct write, no hub runs yet); write the unit (rewritten only when it differs, then restarted); start; print status and "Next: watchtower hub pair". Idempotent.
  **`workspace init --headless`:** when it creates the config, writes `enabled: false` for every registry feature with a `ConfigKey` that is not `Core` (spec §3: only Workbench on, onboarding not run); on an existing config it changes no feature ("Kept your feature settings."). `--json` keys unchanged.
  **CLI keys (pinned):** `service status --json` → `{"manager","installed","running","linger"}` (`linger` null on darwin); `service install|uninstall --json` → the same object.
- **Depends on:** Task 3, Task 4

- [ ] **Step 1: Failing tests:** `TestSystemdUnitGolden`, `TestLaunchdPlistGolden`, `TestUnitsHoldNoSecret` (only `PATH` in the environment; no token, no key), `TestInstallRunsSystemctlInOrder` (fake runner), `TestInstallPrintsTheLingerHintWhenOff`, `TestInstallRefusedOnADesktopHost` (no unit written, no workspace created), `TestServiceVerbsRefusedUnderAnAgentMarker`, `TestInstallIsIdempotent` (second run: no rewrite, no restart), `TestUninstallKeepsData`, `TestLaunchdFallsBackToTheUserDomain`, `TestServiceStatusJSONKeys`, `TestWorkspaceInitHeadlessTurnsOffEveryNonCoreFeature`, `TestWorkspaceInitHeadlessKeepsAnExistingConfig`.
- [ ] **Step 2:** `go test ./internal/service`, `go test ./cmd -run 'TestService|TestWorkspaceInit'` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `cmd: service install|uninstall|status (systemd user unit, LaunchAgent), workspace init --headless`.

### Task 6: Terminal pairing

**Files:**
- Create: `docs/design/mockups/go-hub/hub-pair-terminal.html` (owner review before Step 3, spec §12.4)
- Create: `internal/termqr/termqr.go`; Modify: `go.mod`/`go.sum` (`github.com/skip2/go-qrcode`)
- Create: `cmd/hub_pair_tty.go`; Modify: `cmd/hub.go` (`hub pair` without `--json`)
- Test: `internal/termqr/termqr_test.go`, `cmd/hub_pair_tty_test.go`, `internal/hub/link/headless_test.go`

**Interfaces:**
- Consumes: Plan 1a Task 15's pair stream over `hub.sock` (events `qr` `{url, expires_at}`, `waiting`, `sas` `{device_id, name, code}`, `linked` `{device_id}`, `refused` `{reason}`; request `{"confirm":true|false}`); Task 3 `hub.Dir`, `DefaultName`.
- Produces:
  ```go
  package termqr
  func Render(w io.Writer, text string) (width int, err error) // qrcode.New(text, qrcode.Low).ToSmallString(false): two module rows per line, quiet zone included
  func Width(text string) (int, error)
  package cmd
  func sanitizeForTerminal(s string) string // drops C0/C1 controls, DEL and bidi controls (U+202A–U+202E, U+2066–U+2069)
  ```
  **Flow** (copy as reviewed in the mockup; the SAS prompt is the spec's): needs stdin and stdout terminals (`term.IsTerminal`), else exit 2 "hub pair needs a terminal; scripts use --json --stream"; prints `Link your iPhone to <name>`, the QR (or, when `term.GetSize` is narrower than `Width`, "Widen this window to at least N columns to see the QR code."), `Scan it with the Watchtower app on your iPhone, or open this link on the phone:`, the URL, `Needs a phone with Relay. The code expires at HH:MM.`, `Waiting for your phone… (Ctrl-C cancels)`; on `sas`: `"<name>" wants to link.` then `Confirm code 1234 on your phone? [y/N] ` (`y`/`yes`, any case → confirm; anything else, EOF or the code's expiry → `{"confirm":false}`); `linked` → `Linked "<name>".` and `To let it type into sessions or start them: watchtower hub allow <device> typing|start_sessions`, exit 0; `refused` → one line per reason, exit 1: `used_code` "This code was already used. Run watchtower hub pair for a new one.", `expired_code` "This code expired. Run watchtower hub pair for a new one.", `unknown_code` "The phone sent a code this host does not know. Run watchtower hub pair again.", `not_confirmed` "Not linked: the code was not confirmed.", `too_many_requests` "Too many phones tried this code. Run watchtower hub pair for a new one."; an unknown reason prints "Not linked (<reason>)."; Ctrl-C sends `{"confirm":false}` when a SAS is pending, exits 130 (a code with no phone yet expires after 600 s, Plan 1a). Every phone-supplied string passes `sanitizeForTerminal`.
- **Depends on:** Task 3

- [ ] **Step 1: Mockup** `hub-pair-terminal.html`: one panel per state (QR + waiting, narrow window, SAS prompt, linked, each refusal, not a terminal) with exactly the copy above; the owner reviews it (ask) before Step 3.
- [ ] **Step 2: Failing tests:** `TestRenderMatchesTheBitmap` (decode the half-block lines back into a module matrix; equal to `qrcode.New(url, Low).Bitmap()`), `TestWidthOfAV4HeadlessLink` (the fixture's `v4_headless` URL; asserts the number used by the narrow-window hint), `TestHubPairNeedsATerminal`, `TestHubPairTTYFlowLinked` (pty via `github.com/creack/pty`; scripted `y` → `{"confirm":true}` sent, output lines in order), `TestHubPairTTYAnythingButYesRefuses` (`n`, empty line, EOF), `TestHubPairTTYRefusalLines` (table over the five reasons + an unknown one; exit 1), `TestHubPairCtrlCDuringTheSASSendsNo`, `TestHubPairEscapesThePhoneName` (Review Focus 4: name `"acme\x1b]0;x\x07‮"` prints as `acme0;x`), `TestHubPairNarrowWindowPrintsTheWidenHint`, `TestHeadlessLinkPayloadHasNoShares` (live headless `Issue()` → `transport "relay"`, `transports ["relay"]`, no shares, `mac_name == DefaultName()`).
- [ ] **Step 3:** `go test ./internal/termqr ./internal/hub/link ./cmd -run 'TestHubPair|TestRender|TestWidth|TestHeadlessLinkPayload'` → FAIL.
- [ ] **Step 4: Implement.**
- [ ] **Step 5:** → PASS; `make lint-diff`.
- [ ] **Step 6: Commit** `cmd: hub pair in a terminal (block-character QR, SAS prompt, refusals)`.

### Task 7: Relay-only rules on a headless hub

**Files:**
- Create: `internal/hub/admission.go`
- Modify: `internal/hub/hub.go` (wire `Admission` in live mode), `internal/hub/status.go` (state `paused`, reason `needs_relay`), `internal/hub/slices/publisher.go` (`Pause`/`Resume`), `internal/hub/actions/processor.go` (`SetPaused`)
- Test: `internal/hub/admission_test.go`

**Interfaces:**
- Consumes: Plan 1a `relay.Transport.AccountState`, `transport.Event{Control}`, `transport.ErrEntitlementInactive`, `slices.Publisher`, `actions.Processor`, `FlushControls`.
- Produces:
  ```go
  type AccountState func(ctx context.Context) (*relayv1.AccountState, error)
  type Admission struct{…}
  func NewAdmission(state AccountState, clock func() time.Time) *Admission
  func (a *Admission) Observe(ev transport.Event, saveErr error) // ENTITLEMENT_EXPIRED, SLOT_REMOVED or ErrEntitlementInactive → re-read now
  func (a *Admission) Run(ctx context.Context, onChange func(paying bool)) error // re-read every NeedsRelayPoll while not paying
  const NeedsRelayPoll = 5 * time.Minute
  func (p *Publisher) Pause(); func (p *Publisher) Resume() // Resume runs one full diff; dirty kinds survive the pause
  func (p *Processor) SetPaused(on bool)                    // a paused pass reads and writes nothing; FlushControls returns at once
  ```
  Paying = at least one entry of `AccountState.phones` with `paying` (active or grace). Not paying → `Pause`, `SetPaused(true)`, status `paused`/`needs_relay`; the control queue, held actions, held lines and sidecar stay; sessions and `session-host` are untouched. Paying again → `Resume`, `SetPaused(false)`, one mailbox pass, `FlushControls`. Only in live mode on a headless host (a desktop host's rules are phase 3's). Pairing is never paused: the link center keeps answering `PAIRING_OPENED` in `pair/<slot>`, so a hub with no paying phone yet (a fresh install) can still run `hub pair`; the first promoted paying phone ends the pause.
- **Depends on:** Task 3

- [ ] **Step 1: Failing tests:** `TestPairingWorksWhilePaused` (no phone yet → paused; a `hubtest.Phone` links through the pairing slot; after promotion the hub resumes and publishes `device_grant`), `TestHeadlessHubPausesWithoutAPayingPhone` (every phone `paying: false` → zero saves or deletes after the pause; status `needs_relay`), `TestPausedHubKeepsStateAndRunsNoHandler` (an action written during the pause: no handler call, no echo, sidecar unchanged; after resume applied once, echoed `applied`), `TestPausedHubRereadsTheAccountStateEvery5Min` (fake clock: reads at 0, 5, 10 min), `TestEntitlementExpiredRereadsAtOnce`, `TestOnePayingPhoneKeepsTheHubPublishing`, `TestResumePublishesOneFullDiff`, `TestHeadlessHubNeverUsesCloudKit` (live `Options.Transports == ["relay"]`; a phone's `transport_switch` still gets Plan 1a's `transport_switch_rejected`).
- [ ] **Step 2:** `go test ./internal/hub ./internal/hub/slices ./internal/hub/actions` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `hub: relay-only rules — pause without a paying phone, resume when one is back`.

### Task 8: Linux hub smoke test (spec §13)

**Files:**
- Create: `internal/hub/relaytest/server.go` (exported in-process fake relay over the copied proto; Plan 1a Task 8's test server moves here unchanged in behaviour, and its tests import it)
- Create: `cmd/hub_headless_smoke_test.go` (`//go:build smoke`)
- Modify: `Makefile` (`hub-smoke`), `.github/workflows/ci.yml` (Go Test job runs `make hub-smoke` after the coverage gate; Task 2's arm64 job already does)

**Interfaces:**
- Consumes: `hubtest.Phone`, Tasks 3–7, Plan 1b `workbench session start`, `session-host` v2.
- Produces:
  ```go
  package relaytest
  type Server struct{ URL string; … }
  func Start(t testing.TB) *Server // challenge/register/login (no attestation), subscribe, save (expect), changes, delete, open_pairing → PAIRING_OPENED, promote_pairing, add_slot, set_hub_readers, get_account_state (phones + paying), create_upload/get_download
  func (s *Server) SetPaying(phone string, paying bool)  // and sends ENTITLEMENT_EXPIRED to the hub on false
  func (s *Server) Frames() [][]byte                     // every envelope received (canary capture)
  ```
  `make hub-smoke` = `go test -tags smoke ./cmd -run TestHeadlessSmoke -timeout 5m`.
- **Depends on:** Task 2, Task 5, Task 6, Task 7

- [ ] **Step 1: Failing test** `TestHeadlessSmoke_PairStartTypeEcho`: builds the binary into `t.TempDir()`; `HOME` and `XDG_RUNTIME_DIR` (0700) in temp dirs; on darwin it runs in Plan 1a's test mode (`WATCHTOWER_HUB_DIR`, `WATCHTOWER_HUB_TEST_WORKSPACE=hubtest-smoke`, because a dev Mac is a desktop host), on linux in live mode (no `WATCHTOWER_HUB_DIR`). Steps: `workspace init --headless` (`--name hubtest-smoke` on darwin); `config set hub.relay_origin <relaytest URL>`; `hub enable`; `sync --daemon` in its own process group; wait for `hub status --json` `state == "running"`; `hub pair --json --stream` → `hubtest.Phone` reads the `qr` URL, opens the slot, writes its hello with its `relay_device_id`, both SAS codes equal, `{"confirm":true}` → `linked`; `workbench create --folder <temp git repo>`; `hub allow <dev> start_sessions` and `typing`; the phone sends `session_start` (a stub `claude` first on `PATH` that turns bracketed paste on and appends its stdin to a file) then `session_input "hello"`; the stub's file holds `ESC[200~hello ESC[201~` followed by a lone CR; echo `applied`; no plaintext marker from the action payload in `relaytest.Frames()`; `relaytest.SetPaying(phone, false)` → `hub status` reason `needs_relay` within one admission read. Cleanup: `sync stop`, then SIGKILL to the daemon's group and to `session-host`'s group (pid from the host's hello), waited for.
- [ ] **Step 2:** `make hub-smoke` → FAIL.
- [ ] **Step 3: Implement** the exported server and fix whatever the smoke finds at its source.
- [ ] **Step 4:** `make hub-smoke` → PASS locally (darwin, test mode) and in the CI Linux jobs (live mode, amd64 and arm64).
- [ ] **Step 5: Commit** `hub: Linux smoke test — daemon, terminal-free pairing, stub session, typed line`.

### Task 9: Vouching end to end — **blocked on relay ask #805**

**Files:**
- Re-copy: `internal/hub/transport/relay/{client,relayv1,VERSION}` with `make relay-go RELAY=../relay REF=<vouch commit>` (copy committed alone first, as Plan 1a Task 8)
- Modify: `internal/hub/transport/relay/transport.go` (register as the hub kind, empty attestation), `internal/hub/transport/relay/errors.go`, `internal/hub/transport/errors.go` (`ErrNotVouched`)
- Create: `internal/hub/state/migrations/00004_relay_admission.sql`
- Modify: `internal/hub/link/relay.go` (admission per phone), `internal/hub/admission.go` (Task 7: unvouched = no publishing), `internal/hub/status.go`, `cmd/hub.go` (`hub phones` `transport`), `internal/hub/hubtest/phone.go` (`Vouch`), `internal/hub/relaytest/server.go` (vouch model), `internal/hub/state/columns_test.go` (allowlist), `internal/hub/interop_test.go`
- Test: `internal/hub/transport/relay/vouch_test.go`, `internal/hub/vouch_test.go`

**Interfaces:**
- Consumes: the relay commit's names. Working names below; **copy the names the relay commit fixes** and rename here and in the §12a list if they differ: `DEVICE_KIND_HUB`, op `vouch_hub{hub_device_id, auth_pub}` with the phone's App Attest assertion over the relay's vouch digest, `ERROR_CODE_HUB_NOT_VOUCHED`.
- Produces:
  - `00004`: `ALTER TABLE devices ADD COLUMN relay_admitted_at REAL` (a timestamp, no content; allowlist class `timestamp`).
  - `var ErrNotVouched = errors.New("transport: the relay has not admitted this hub")`; status reasons `not_vouched` (registered, no vouching phone in an active slot yet; replaces Plan 1a's `not_admitted` for a headless hub) and `vouch_revoked` (`HUB_NOT_VOUCHED` after having been admitted: the hub left every slot).
  - Rules: register with the hub kind and no attestation; until `get_account_state` lists a phone holding this hub in an active slot, the hub saves only into the `pair/<slot>` zone it was opened for — never the data zone, never a mailbox — and does not count itself on the relay (spec §12a); a phone listed there gets `relay_admitted_at`; `hub phones` shows `transport: "pending"` for a linked phone without it, `"relay"` with it; `vouch_revoked` stops publishing, keeps the sidecar, and a new `hub pair` + vouch admits it again.
  - `func (p *Phone) Vouch(ctx context.Context, hubDeviceID string, authPub []byte) error` then the existing promote.
- **Depends on:** Task 7, Task 8, relay ask #805

- [ ] **Step 1: Failing tests** (spec §13 vouch branches): `TestRegistersAsAHubWithoutAttestation`, `TestUnvouchedHubOnlyWritesItsPairingSlot`, `TestVouchAcceptedAdmitsTheHub` (vouch + promote → account state lists the phone → first data-zone save; `relay_admitted_at` set), `TestVouchRefusedKeepsTheHubOffTheRelay` (table: `ATTESTATION_REQUIRED`, `ATTESTATION_FAILED`, `SLOT_LIMIT` on the phone's `vouch_hub` → no promote, no data-zone or mailbox save, status `not_vouched`, `hub phones` `transport: "pending"`), `TestHubNotVouchedAtLoginIsRevoked` (→ `vouch_revoked`, nothing published, sidecar intact; a new link re-admits), `TestHubNeverCountsItselfOnTheRelayBeforeAdmitted`, `TestRelayAdmittedAtIsATimestamp` (allowlist), `TestInterop_VouchedHubLinksAndPublishes` (`-tags interop`, local stand).
- [ ] **Step 2:** `go test ./internal/hub/...` → FAIL.
- [ ] **Step 3: Implement.** Write the final wire names and error codes into this spec's §12a vouching bullet (one line, as §12a requires); the relay client spec's copy is its session's edit, named in the PR body.
- [ ] **Step 4:** `go test ./internal/hub/...`, `make relay-interop RELAY=../relay`, `make hub-smoke` → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `hub: vouched admission on the relay (unvouched registration, not_vouched / vouch_revoked)`.

### Task 10: Guide page, privacy, CLI reference, feature note

**Files:**
- Create: `docs/guide/features/headless-host.md` (feature template, < 8 KB without its card)
- Modify: `docs/guide/README.md` (one catalogue line), `docs/guide/concepts/privacy.md` (`## On a Linux host or a Mac without the app`), `docs/guide/reference/cli.md` (`hub …`, `service …`, `workspace init --headless`)
- Modify: `docs/features/go-hub.md` (Phase 2 section), `CLAUDE.md` (the go-hub feature line mentions phase 2), the chat system prompt golden (regenerated in Step 3)
- Modify: `docs/inventory/workbench.md` (PROJ-20 changelog line: "2026-10-31 (Go hub phase 2, ask #827): amended for Linux only — the `session-host` socket is in `$XDG_RUNTIME_DIR` (fallback `<data root>/.run`, 0700) instead of `/tmp`, and the daemon starts the host as its own transient systemd user unit so a daemon restart keeps sessions; darwin unchanged, no guard relaxed."), `docs/inventory/agent-actions.md` (AGENT-07 changelog line, ask #827: on a headless host the owner verbs are `watchtower hub …`/`service …`, refused under every marker and confirmed by the terminal; the Desktop-confirmed gestures stay refused on Linux)

**Interfaces:** none new.
- **Depends on:** Task 5, Task 6, Task 7, Task 9 (WRITING.md rule 7: the page ships only once a headless host works against the real relay)

- [ ] **Step 1: Write the page** (WRITING.md rules; every string checked against the code): *Why use it* (workbenches on a box with no screen, driven from the phone; one scenario: a Pi on a shelf runs a Claude Code session while you are out); *How it works* (outbound only, nothing listens; the phone's subscription admits the host; relay only, no iCloud; what a headless host does not do: recordings, the clipboard fallback, Slack/Gmail/Jira pipelines are off); *Using it* (Linux: download the tarball for your architecture, check its `.sha256`, put `watchtower` on your `PATH`; needs 64-bit, glibc 2.35+, `libssl3`, `git`; install Claude Code or Codex and sign in — on a box with no browser `claude` prints a URL to open on another device; `watchtower service install`; `sudo loginctl enable-linger <user>` when asked; `watchtower config set hub.relay_origin …` only if told to; `watchtower workbench create --folder …`; `watchtower integrate claude-code`; `watchtower hub pair`; `watchtower hub allow …`; a Mac without the app: the CLI zip and the same steps with a LaunchAgent); *When it's empty or wrong* (`watchtower hub status` reasons → fixes: `needs_relay`, `not_vouched`, `vouch_revoked`, `desktop_host`, `no_relay_origin`, `disabled`; "[Watchtower] the session host is not running"; the QR is cut → widen the window or open the link); *Related*. One learn card: `id: headless-host-run`, `title: Run workbenches on a Linux box`, `area: iphone`, `level: power`, `kind: feature`, `since: next`.
- [ ] **Step 2: Privacy section:** the hub identity is a 0600 file under `~/.local/share/watchtower/.hub` (no Keychain or Secure Enclave on a headless host — spec §12.2); no unified-log audit line off macOS (READ-02); no organization policy off macOS; everything that leaves the host is end-to-end encrypted as on the Mac.
- [ ] **Step 3:** `go test ./docs/guide/ ./internal/kb/ ./internal/chat/ ./internal/learn/` → FAIL on the golden; regenerate with `go test ./internal/chat -run TestBuildSystemPrompt_Golden -update`; → PASS.
- [ ] **Step 4: Commit** `docs: headless host guide page, privacy and CLI reference, go-hub phase 2 note`.

### Task 11: Kit phone ↔ Go headless hub interop — **blocked on relay client spec Phase 3 (phone) and Task 9**

**Files:**
- Modify: `scripts/relay-interop.sh` (`KIT=1`: starts a live headless hub against the stand, then runs the Kit suite)
- Create: `WatchtowerKit/Tests/WatchtowerSyncTests/GoHubInteropTests.swift` (skipped unless `WT_RELAY_INTEROP_URL` and `WT_HUB_INTEROP_DIR` are set)

**Interfaces:**
- Consumes: the neighbour session's `HostedRelayTransport` and phone link flow; the hub side's `hub pair --json --stream`.
- Produces: the script writes the pairing URL to `$WT_HUB_INTEROP_DIR/pair.url`, waits for the Kit test's code in `pair.sas`, and answers `{"confirm":true}` only when it equals the hub's `sas.code`.
- **Depends on:** Task 8, Task 9, relay client spec Phase 3

- [ ] **Step 1: Failing Kit tests:** `testKitPhoneLinksAHeadlessHub` (Kit parses the relay-only v4 QR, hello with its `relay_device_id`, SAS equal, vouch, promote, `device_grant.transports == ["relay"]`), `testKitPhoneOpensEveryRecordKindTheGoHubSealed` (spec §13 E2E (3)), `testGoHubAppliesKitActionsInOrder` (a1..a3 incl. a `session_input` to a stub session → `applied`), `testRecordingOnAHeadlessHubIsNotSupported`.
- [ ] **Step 2:** `make relay-interop RELAY=../relay KIT=1` → FAIL; implement the script part; → PASS; `make lint-swift`.
- [ ] **Step 3: Commit** `hub: Kit phone interop with a headless hub over the relay stand`.

### Task 12: Phase 2 gate — a real Pi and a real CLI-only Mac from a real phone — **blocked on the relay deploy and the phone**

**Files:** none (results in the PR body, redacted: no hostnames, ids, accounts or origins).

**Interfaces:** none.
- **Depends on:** Tasks 1–11; the vouch change on the staging relay; a phone development build with relay client Phases 2–3.

- [ ] **Step 1: Automated gate:** `make test`, `make lint-all`, `make test-scripts`, `make hub-smoke`, `make relay-interop RELAY=../relay KIT=1`; CI green including `go-linux-arm64`; a `linux-build` run with both tarballs.
- [ ] **Step 2: Pi** (Raspberry Pi 4 or 5, Raspberry Pi OS Lite 64-bit bookworm, SSH, user `<user>`). Expected result after each step in brackets.
  - P1 `sudo apt-get install -y git` [`libssl3` already present: `dpkg -s libssl3` installed].
  - P2 Download `watchtower-<v>-linux-arm64.tar.gz` and its `.sha256` from the `linux-build` run; `sha256sum -c`; `tar xzf`; `install -m 0755 watchtower ~/.local/bin/` [`watchtower version` prints `<v>`; `ldd ~/.local/bin/watchtower` shows only libc/libm/libcrypto.so.3 and the loader].
  - P3 Install Claude Code per Anthropic's instructions; run `claude`, open the printed URL on another device, finish the login [`claude --version` works in a fresh SSH shell].
  - P4 `watchtower service install` [prints `manager systemd, installed, running`, the linger hint if off, "Next: watchtower hub pair"]; `sudo loginctl enable-linger <user>` if hinted; `systemctl --user status watchtower.service` [active].
  - P5 `watchtower config set hub.relay_origin <staging-relay-origin>`; `systemctl --user restart watchtower.service`; `watchtower hub status` [`state starting|running`, `host headless`, `mode live`, reason `not_vouched`].
  - P6 `mkdir -p ~/code/acme && git -C ~/code/acme init && git -C ~/code/acme commit --allow-empty -m init`; `watchtower workbench create --folder ~/code/acme`; `watchtower integrate claude-code` [workbench id printed].
  - P7 On the phone (operator granted the staging entitlement through the relay's operator endpoint, never in the app): link a host. In the SSH terminal, at least as wide as the hint says: `watchtower hub pair` [QR, link, "Needs a phone with Relay…", waiting line]. Scan [`"<phone>" wants to link.` and `Confirm code NNNN on your phone? [y/N]`; the phone shows the same four digits]. Type `y` [`Linked "<phone>".`; the phone vouches and promotes].
  - P8 `watchtower hub status` [`running`, phones 1, no reason]; `watchtower hub phones` [`transport relay`, `ordered true`].
  - P9 Phone: the hub switcher shows the Pi's hostname; the workbench and its board appear within 5 s; Settings shows the iCloud choice hidden; the record button is hidden or a recording ends "this host cannot transcribe" (`failed not_supported`).
  - P10 Phone asks for typing and starting sessions; on the Pi `watchtower hub allow <device> typing` and `… start_sessions` [`allowed: true`].
  - P11 Phone: start a Claude session on the workbench [row shows Starting… then working; on the Pi `systemctl --user status watchtower-session-host` is active].
  - P12 Phone workchat: send "list the files here" [the line is submitted once; the answer appears in the workchat].
  - P13 Make the agent ask (`ask_owner`) and hit a permission prompt [both reach the phone; the answer and an Allow/Deny land; **Interrupt** stops a working turn with one Esc].
  - P14 While the agent works: `systemctl --user restart watchtower.service` [the agent keeps working; `systemctl --user status watchtower-session-host` shows the same main PID; the phone reconnects within 60 s] (Review Focus 2).
  - P15 Move a card on the phone [`watchtower workbench board <id>` shows it moved].
  - P16 Operator expires the staging entitlement [within 5 min `hub status` → `paused`, `needs_relay`; the phone shows "This hub needs Relay"; the session keeps running]. Answer an ask on the phone while paused [it waits]. Grant again [within 5 min `running`; the answer is applied once].
  - P17 `sudo reboot` [after boot, without logging in: `systemctl --user status watchtower.service` active (linger); the phone sees the host again; the rebooted session shows as stopped].
  - P18 Privacy: `stat -c '%a' ~/.local/share/watchtower/.hub ~/.local/share/watchtower/.hub/identity.key` [`700`, `600`]; `journalctl --user -u watchtower.service | grep -c '<a word typed in P12>'` [0]; `ls -ld "$XDG_RUNTIME_DIR"/watchtower-sh-*.sock` [mode `srw-------`, in `/run/user/<uid>`].
  - P19 `watchtower hub unlink <device>` [the phone shows the host unlinked]; `watchtower service uninstall` [unit gone, data still there].
- [ ] **Step 3: CLI-only Mac** (no Watchtower app, no `~/Library/Application Support/Watchtower/MobileHub`):
  - M1 Download `Watchtower-CLI-<v>-arm64.zip` in a browser (so it carries the quarantine attribute), unzip it into `~/.local/bin` [`watchtower version` runs with no Gatekeeper block].
  - M2 `watchtower service install` [`manager launchd`; `launchctl print gui/$(id -u)/com.watchtower.daemon` shows it running].
  - M3 Repeat P5–P15 [same results; `hub status` `host headless`]. With the screen locked, an ask produces a work alert on the phone; with the owner active at the Mac, it does not (owner-away on darwin).
  - M4 On a second Mac that has the Watchtower app: `watchtower service install` [refused: "This Mac has the Watchtower app, which runs the daemon itself."]; `watchtower hub status` [`off`, `desktop_host`] (Review Focus 1).
- [ ] **Step 4:** Record the step results, the relay commit (`internal/hub/transport/relay/VERSION`) and the phone build number in the PR body; file every failure as a fix before the phase closes.

---

## Resolved in ask #827

- **CLI-only Mac** stays a headless host: the same headless build for darwin, a LaunchAgent, the 0600 identity file in phase 2 (phase 3 may move it into Keychain under spec §12.2), a darwin CLI zip next to the Linux tarballs. The live hub refuses on a Mac with the Desktop app bundle or `MobileHub/` — one check at start, reason `desktop_host`, no stop or hand-over later (Task 3; spec §7.3 and Decisions amended).
- **PROJ-20 amended, Linux only:** socket in `$XDG_RUNTIME_DIR` (fallback `<data root>/.run`), `session-host` as its own transient systemd unit (Tasks 1, 4; changelog in Task 10).
- **Owner verbs on a headless host** go through `watchtower hub …`, confirmed by the terminal (Tasks 3, 5, 6; changelog in Task 10).
- **Decided by agent:** the live hub dir `<data root>/.hub` and `config.AppSupportDir()` = `<data root>/.support` off darwin (Tasks 1, 3); Linux tarballs and the CLI zip attached to releases only from the launch release, supported Linux = 64-bit, glibc ≥ 2.35, `libssl3` (Task 2).
- **Recording capability: pending the protocol document.** The owner wants it as a simple on/off and approves the phone ↔ hub protocol in a separate document; this plan decides no field, and a headless hub keeps answering `failed(not_supported)` until that document lands.

## Later (not in this plan)

- A thin management CLI for a headless Watchtower (owner, ask #827); until then the owner manages a headless host with `watchtower hub …`, `watchtower service …` and the existing commands.
- Publishing the recording capability once the protocol document is approved.

## Self-review (done while writing)

- **Spec coverage:** §14 row 2 — linux/arm64 + amd64 builds (Task 2), CLI-only Mac (Tasks 2, 3, 5, 12 M1–M4), systemd units (Tasks 4, 5), headless pairing (Task 6), vouching end to end (Task 9, interop 11), relay-only rules (Task 7), guide page (Task 10), gate on a real Pi from a real phone (Task 12). §7.3 — relay-only, needs Relay, free phone (contract point 1 + Task 6 terminal line + Task 3 no shares), CLI-only Mac rule: one start check, `desktop_host` (Task 3), host differences (Global Constraints, Task 1 audit). §10 — terminal QR, SAS prompt, `transports`, hostname (Tasks 3, 6). §11 — `service install`, Claude login on a headless box (Tasks 5, 10, 12 P3). §12.1 — never two hubs (Task 3). §12.2 — 0600 file on Linux (Task 3, privacy page Task 10). §12.4 — terminal mockup (Task 6). §13 — Linux arm64 build + smoke (Tasks 2, 8), vouch branches (Task 9), relay-only on `entitlement_expired` (Task 7), free phone for a headless host (Task 6 `TestHeadlessLinkPayloadHasNoShares`; the refusal itself is the phone's), device gate (Task 12). Out of scope: CloudKit bridge, adoption, Keychain store, Desktop rewiring (phase 3); pushes (phase 4).
- **Phase 1 hand-offs fixed here:** Plan 1b Task 17's local `GOOS=linux GOARCH=arm64 go build ./...` cannot build (cgo, verified: `internal/sqlcipher/wt_nocgo.go`); Task 2 replaces it with the native arm64 CI job. Plan 1a Task 12's deferral of the vouch tests lands in Task 9.
- **Types across tasks:** `hostkind.Detect`/`Kind` (3 → 5, 12), `hub.Resolve`/`Dir`/`Mode`/`DefaultDir` (1, 3 → 5, 6, 8), `sessionhost.EnsureWith`/`SystemSpawner` (4 → 8), `service.Installer` (5 → 8), `termqr.Render` (6), `Admission`/`Publisher.Pause`/`Processor.SetPaused` (7 → 8, 9), `relaytest.Server` (8 → 9), `transport.ErrNotVouched`, `devices.relay_admitted_at` (9).
- **Ask #827 revision re-checked:** no task depends on a runtime host re-check (removed from Task 3; Review Focus 1 now points at start-time tests only); the recording field appears in no task or contract point; every former open item is either a Resolved line or a Later line.
- **Dependency waves:** 1 — Tasks 1, 2; 2 — Tasks 3, 4; 3 — Tasks 5, 6, 7; 4 — Task 8; then external — Task 9 (relay), Task 10, Task 11 (phone), Task 12 (relay deploy + phone).
