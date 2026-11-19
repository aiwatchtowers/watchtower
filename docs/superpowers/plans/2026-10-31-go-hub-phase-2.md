# Go hub — Phase 2: headless hosts (Linux, a Mac without the app) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Phase 1 Go hub runs on real data on a headless host (linux/arm64, linux/amd64, a Mac with only the CLI) as a user service, pairs a phone from a terminal, is admitted to the relay by the phone's vouch, follows the relay-only rules of spec §7.3, and is accepted on a real Pi and a real CLI-only Mac driven from a real phone.

**Architecture:** Phase 1 starts the hub only in a `hubtest-*` workspace behind `WATCHTOWER_HUB_DIR` (Plan 1a Task 14). This plan adds a second, **live** mode next to that test mode: `hub.Resolve` picks the test mode exactly as before when `WATCHTOWER_HUB_DIR` is set, and otherwise starts a live hub in `<data root>/.hub` only on a host that `internal/hub/hostkind` classifies as headless (Linux always; a Mac with neither the Desktop app bundle nor the Swift hub's `MobileHub/` state) and only after the owner ran `hub enable` (done by `watchtower service install`). On a desktop host the live mode never starts and never creates or reads hub state, so the Go hub can never run beside the Swift hub on a Mac (spec §12.1); a desktop host gets the Go hub only through phase 3's adoption. Around that: Linux-safe paths (`session-host` socket in `/run/user/<uid>`, `AppSupportDir` off darwin, peer credentials on Linux), CI and release builds on native Linux runners (cgo: the SQLCipher amalgamation does not cross-compile without a C toolchain), `watchtower service install|uninstall|status` (systemd user unit, LaunchAgent), `session-host` started as its own transient systemd unit so a daemon restart keeps sessions, terminal pairing (QR in block characters, `[y/N]` SAS prompt), the relay-only pause, a Linux smoke test, vouching once the relay ships it, the guide page, and the manual device gate.

**Tech Stack:** Go 1.26 with cgo (SQLCipher over OpenSSL `libcrypto.so.3` on Linux, CommonCrypto on darwin), `golang.org/x/term` (already a direct dependency), `github.com/skip2/go-qrcode` (new, MIT, terminal half-block rendering), `golang.org/x/sys/unix` (`SO_PEERCRED`, `LOCAL_PEERCRED`), systemd user units and `systemd-run --user`, launchd LaunchAgents, GitHub Actions `ubuntu-22.04`/`ubuntu-22.04-arm`/`ubuntu-24.04-arm` runners; Swift only in the blocked Kit interop task.

**Spec:** `docs/superpowers/specs/2026-10-31-go-hub-design.md` — §14 row 2 (this phase), §7 (§7.3 headless hosts), §10 (terminal pairing, `transports`, hostname), §11 (`service install`, Claude Code login on a headless box), §12.1 (never two hubs), §12.2 (0600 identity file on Linux), §12.4 (terminal mockup), §12a (contract), §13 (Linux smoke, vouch branch tests, device gate), §15 (relay change), Decisions. Phone ↔ hub protocol: `docs/superpowers/specs/2026-10-31-hub-phone-protocol-design.md` (approved, ask #834; §7.7, §9 for Task 9). Owner rulings on this plan: ask #827 (see Resolved). Prerequisites: Plans 1a (`docs/superpowers/plans/2026-10-31-go-hub-phase-1.md`) and 1b (`…-phase-1b.md`) merged; this plan builds on their **Produces** blocks only.

## External dependencies (ordered last)

| Blocker | What is missing | Tasks it blocks |
|---|---|---|
| **Relay ask #805** (spec §15 p. 1) | `device_kind = HUB` registering unvouched, `vouch_hub`, `HUB_NOT_VOUCHED`, revoke on leaving every slot. Not in the relay's `main` today (its proto has `DEVICE_KIND_PHONE`/`DEVICE_KIND_MAC`, `ATTESTATION_REQUIRED`/`FAILED`, `SLOT_LIMIT` only, and a Mac must attest). Until then the hub registers as `DEVICE_KIND_MAC` with no attestation, which only the local stand (attestation `off`) accepts. | Task 10; through it Tasks 11, 12, 13 |
| **Relay client spec Phases 2–3 on the phone** (neighbour session, Kit/phone) | Hosted relay client, phone identity, linking from the phone (`LinkPayload` v4 reading, `DeviceHello.relay_device_id`, `vouch_hub` + `promote_pairing`), "This hub needs Relay", "A free phone can't link this hub". | Tasks 12, 13 |
| **Relay deploy** | The vouch change live on the staging relay (staging accepts development App Attest). | Task 13 |

Tasks 1–8 need neither: they run against `memfake`, the in-process fake relay and the local stand with attestation `off`, driven by the Go phone emulator `hubtest.Phone`.

## Phone contract points (the phone must match; spec §12a)

The hub builds only what §12a fixes. The neighbour session's phone code must match these, and the shared fixture `WatchtowerKit/Tests/Fixtures/link/hub_contract_cases.json` (Plan 1a Task 1: cases `v4_headless`, `headless_linked`) already pins the bytes:

1. **QR of a headless hub** (`LinkPayload` v4): `transport: "relay"`, `transports: ["relay"]`, `relay_device_id` (lower-case unpadded base32 of SHA-256 of `relay_auth_pub`), `relay_auth_pub`, `mac_name` = the hub's display name (hostname by default, ≤ 60), **no** `data_share`/`relay_share`. A phone without Relay refuses on reading `transports == ["relay"]` — right after the scan, before it writes a hello (spec §7.3's "before the QR is scanned" means before any pairing traffic; same moment) ("A free phone can't link this hub"); the terminal says "Needs a phone with Relay." on its side.
2. **Pairing:** the phone opens a pairing slot naming the QR's `relay_device_id`; its sealed `DeviceHello` carries its own `relay_device_id` (without it the link completes but that phone can never read a relay-only hub).
3. **Vouch:** after the owner confirms the SAS in the terminal and the keybox opens, the phone sends `vouch_hub{hub_device_id = QR.relay_device_id, auth_pub = QR.relay_auth_pub}` with its assertion, then `promote_pairing`. A refusal leaves the hub `not_vouched`; the phone shows the server's reason.
4. **`device_grant`** of a headless hub: `ordered_actions: 1`, `transports: ["relay"]`, `relay_device_id`, `relay_auth_pub`. The phone hides the iCloud choice and, when its own entitlement lapses, shows "This hub needs Relay".
5. **Recording switch** (protocol §7.7, §9, approved in ask #834; hub side = Task 9): the heartbeat carries `capabilities.recordings` `"on"|"off"` (absent = on; an unknown value reads as not off; unknown keys ignored); the phone does not offer recording for `"off"`; the upload echo carries an optional `reason` (`not_supported`, `expired`, …) and a `failed` echo keeps the phone's audio. **External:** the Kit decoding — `HeartbeatPayload.capabilities.recordings`, `RecordingUploadPayload.reason`, `ActionReason.not_supported` — and Kit `HubContractFixtureTests` reading the new `heartbeat` section are the neighbour session's (relay client spec). A Linux hub always publishes `off`.
6. **Grants:** typing and starting sessions stay requested by the phone and allowed on the host (`watchtower hub allow <device> typing|start_sessions`), as Plan 1a Task 11.

## Global Constraints

All Global Constraints of Plans 1a and 1b hold (byte compatibility, zone bytes, E2E red line, FILES-01, migrations as the sidecar's own goose provider, guard tests one-to-one, hygiene, inner loop). In addition:

- **Platforms** (spec goal 1): `darwin/arm64` (the desktop host and the CLI-only build; Intel Macs are not supported for the CLI-only build), `linux/arm64`, `linux/amd64`. Linux builds link `libcrypto.so.3` dynamically (`internal/sqlcipher/wt_cgo.go`: `-DSQLCIPHER_CRYPTO_OPENSSL`, `-lcrypto -lm`) and are built on `ubuntu-22.04` runners: glibc floor **2.35**, so they run on Ubuntu 22.04+ and Debian 12+ / Raspberry Pi OS bookworm (2.36), with `libssl3`; Ubuntu 20.04 (glibc 2.31, OpenSSL 1.1) and Debian 11 (glibc 2.31, OpenSSL 1.1) are not supported, nor are 32-bit systems (decided by agent). `CGO_ENABLED=0` does not build (`internal/sqlcipher/wt_nocgo.go`), and a cross build from macOS fails for the same reason: every Linux build runs on a native Linux runner.
- **Never two hubs** (spec §3 anti-goal, §12.1): a live hub starts only on a headless host. Desktop host signals (darwin): `/Applications/Watchtower.app/Contents/Info.plist` or `~/Applications/Watchtower.app/Contents/Info.plist` holding the bundle id `com.watchtower.desktop`, or a directory `config.AppSupportDir()/MobileHub`. On a desktop host the live mode creates, opens and reads nothing under the hub dir or `MobileHub/` (existence checks only); the test mode of Plan 1a is unchanged. The check runs **once, at start** (ask #827): a Desktop app installed later on a CLI-only Mac gets no stop or hand-over.
- **Live hub dir** `<config.DataRoot()>/.hub` (dir 0700, files 0600; `.hub` cannot be a workspace name: `ValidWorkspaceRe` = `^[a-zA-Z0-9][a-zA-Z0-9_.-]*$`). Hub identity there in `identity.key` through Plan 1a's `identity.FileStore` (0600, a looser mode refused) on Linux and on a CLI-only Mac (spec §12.2, §7.3).
- **Relay-only** (spec §7.3): a headless hub's `transports` are `["relay"]` in the QR and in every `device_grant`, it has no CloudKit bridge, and a phone's `transport_switch` keeps Plan 1a's `transport_switch_rejected` answer. With no paying phone (`get_account_state` → no phone with `paying`), the hub pauses: it keeps its state and local work, saves and deletes nothing, runs no handler, and re-reads the account state every **5 min** and on every `ENTITLEMENT_EXPIRED`/`SLOT_REMOVED` control or `ENTITLEMENT_INACTIVE` error.
- **Host differences, all of them** (spec §7.3): no CloudKit bridge, no recordings (`failed(not_supported)`), owner-away always away and no keep-awake on Linux (Plan 1b Task 7), no `.copied` fallback (`cannot_type`, Plan 1b Task 2), `clonefile` → plain copy on Linux (`workbenchgit/clone_other.go`), service manager systemd (Linux) / launchd (CLI-only Mac), key store 0600 file.
- **`session-host` survives a daemon restart:** under systemd the daemon starts the host as its own transient user unit `watchtower-session-host` (`systemd-run --user`), never as a child in the daemon unit's cgroup (a stop or restart of that unit would kill every session, against PROJ-20's "an update keeps sessions running"; PROJ-20 amendment, Linux only, approved in ask #827); under launchd the plist sets `AbandonProcessGroup`.
- **Linux socket and support paths:** the `session-host` socket dir is computed from the UID alone, the same in the host and in every client, and no environment variable is read (a caller's `XDG_RUNTIME_DIR` may be unset or differ, e.g. under `sudo -u` or cron): `/run/user/<uid>` when it exists, is owned by the uid and has mode 0700, else `<data root>/.run` (0700); never the shared `/tmp`; the file name is unchanged (`watchtower-sh-<first 8 hex of SHA-256("com.watchtower.desktop")>.sock`). `config.AppSupportDir()` off darwin is `<data root>/.support`. darwin paths are unchanged (Plan 1b's `paths.json` fixture still passes). Approved in ask #827.
- **Relay origin** = `WATCHTOWER_RELAY_ORIGIN` if set, else config `hub.relay_origin`, else the build-time default `watchtower/internal/hub.DefaultRelayOrigin` (ldflags: the release builds — `scripts/build-linux.sh` from the repository variable `RELAY_ORIGIN`, `scripts/build-app.sh` from `.env`'s `WATCHTOWER_RELAY_ORIGIN_DEFAULT` — pin the origin the relay session announces; dev builds leave it empty). `config set hub.relay_origin` overrides the default. With none set the hub stays off, reason `no_relay_origin`, and `hub status` prints one remedy line: "Set the relay: watchtower config set hub.relay_origin <origin>". Accepted: `https://host[:port]` with no path, query or fragment; `http://` only for `127.0.0.1`, `localhost`, `[::1]`. Plans and docs write `<staging-relay-origin>`, never the real staging host.
- **Owner verbs on a headless host** (ask #827): they go through `watchtower hub …` (and `watchtower service …`): `service install|uninstall`, `hub pair|allow|unlink|enable|disable|name` are refused under an agent marker (as Plan 1a Task 15) and confirmed by the terminal — the human `hub pair` needs stdin and stdout to be terminals. AGENT-07's Desktop-confirmed gestures stay refused on Linux (no Desktop to confirm them). No sudo is ever run by Watchtower.
- **Pinned terminal copy** (spec §10; the rest reviewed in the Task 6 mockup): `Confirm code 1234 on your phone? [y/N] `.
- **FILES-01 on the host:** unit files hold no secret (only `PATH`), the daemon's stdout/stderr under launchd go to `/dev/null` (it writes `watchtower.log` itself), journald sees only what the daemon already logs (ids, counts, classes).
- **Inner loop:** `go test ./<pkg>`, `make lint-diff`, `bash scripts/tests/<file>.sh` for shell; the Linux-only tests run in the CI Linux jobs, and every rule they pin also has an OS-parameterised test that runs on the dev Mac. The full gate runs once, in Task 13.

## Review Focus

1. **A live hub beside the Swift hub.** A Mac with the app (or with `MobileHub/` from an older app) must never start a live hub, even with `hub enable` written by hand. → Task 3 `TestResolve_DesktopHostNeverStartsALiveHub`, `TestHubCLIRefusesTheLiveDirOnADesktopHost`; Task 5 `TestInstallRefusedOnADesktopHost`.
2. **A daemon restart that kills the sessions.** `systemctl --user restart watchtower.service` (an update) must leave every agent running. → Task 4 `TestEnsureUnderSystemdUsesATransientUnit`; Task 13 step P14.
3. **A shared `/tmp` on Linux.** Another local user pre-creating the host socket or its `.lock` must not capture a phone line or stop the host. → Task 1 `TestSocketDirLinuxRefusesAForeignOrLooseRuntimeDir`, `TestSocketDirLinuxFallbackIsPrivate`.
4. **A phone name that is a terminal escape.** The phone names itself; the terminal prints it before the SAS prompt. → Task 6 `TestHubPairEscapesThePhoneName`.
5. **A binary that does not start on the Pi.** A runner image upgrade raising the glibc requirement past bookworm's. → Task 2 `scripts/check-glibc.sh` in the build job.

---

### Task 1: Linux-safe paths, peer credentials and the darwin-only audit

**Files:**
- Modify: `internal/sessionhost/paths.go` (`DefaultSocket` through `socketDirFor`)
- Modify: `internal/config/config.go` (`AppSupportDir` through `appSupportDirFor`: today it returns `~/Library/Application Support/Watchtower` on every OS, Linux included (`internal/config/config.go:875`); this task fixes it off darwin)
- Create: `internal/hub/dirs.go` (`DefaultDir`)
- Peer credentials already ship (Fable check): `socketPeerUID` in `internal/hub/peer_linux.go` (SO_PEERCRED), `peer_darwin.go` (LOCAL_PEERCRED), `peer_other.go` (refuses), seam `Options.peerUID` (`hub.go`), checked in `control.go` before `serveConn`, guarded by `TestControlSocketIsPrivateAndChecksPeer` (`hub_test.go`, a real connection on both OSes). This task creates no peer-credential file; it adds only `TestControlSocketClosesWhenPeerCredentialsFail`.
- Modify: `internal/sessionstart/start.go` (the only `DefaultSocket()` caller, `Deps.socket()`), for the signature change below
- Test: `internal/sessionhost/paths_test.go`, `internal/config/config_test.go`, `internal/hub/dirs_test.go`, `internal/hub/hub_test.go`

**Interfaces:**
- Consumes: `sessionhost.SocketPath`, `sessionhost.SocketEnv`, `config.DataRoot`, the control socket of Plan 1a Task 14.
- Produces:
  ```go
  package sessionhost
  func socketDirFor(goos, tempDir, dataRoot string, uid int, stat func(string) (os.FileInfo, error)) (string, error)
  // darwin: tempDir (unchanged). linux: /run/user/<uid> when it exists, is owned by uid (Lstat, not a symlink) and has mode 0700; else <dataRoot>/.run, created 0700 (and tightened if looser). No env var is read.
  package config
  func appSupportDirFor(goos, home, dataRoot string) string // darwin: ~/Library/Application Support/Watchtower; else <dataRoot>/.support
  package hub
  func DefaultDir() (string, error) // <config.DataRoot()>/.hub
  // changed: sessionhost.DefaultSocket() string → DefaultSocket() (string, error), so the run_dir_unusable class reaches the caller (sessionstart's Deps.socket(), and Task 3's live Resolve)
  ```
- **Depends on:** none (Phase 1 merged)

- [ ] **Step 1: Failing tests:** `TestSocketDirDarwinUnchanged` (`socketDirFor("darwin", …)` = tempDir; `TestPathsFixture` still passes), `TestSocketDirLinuxUsesRunUserUID` (`/run/user/<uid>` owned, 0700 → chosen), `TestSocketDirLinuxIgnoresXDGRuntimeDir` (`XDG_RUNTIME_DIR` set to another dir → same answer as unset), `TestSocketDirLinuxRefusesAForeignOrLooseRuntimeDir` (`/run/user/<uid>` missing, owned by another uid, mode 0755 or a symlink → `<dataRoot>/.run`; Review Focus 3), `TestAClientWithoutXDGRuntimeDirFindsTheRunningHost` (linux-tagged: a host started with `XDG_RUNTIME_DIR` set, a client process with it unset → `DefaultSocket()` is the same path and `Dial` reaches the host), `TestSocketDirLinuxFallbackIsPrivate` (created 0700; an existing 0755 dir is tightened; a symlink is refused), `TestAppSupportDirOffDarwinIsUnderDataRoot` (`appSupportDirFor("linux", home, root)` = `<root>/.support`, never a path containing `Library/Application Support`; darwin unchanged), `TestDefaultHubDirCannotBeAWorkspace` (`.hub` fails `ValidWorkspaceRe`); the same-uid / other-uid cases are already `TestControlSocketIsPrivateAndChecksPeer` (Phase 1), kept unchanged.
- [ ] **Step 1b: Failure paths, each with its test** (added to Step 1's run):
  - `/run/user/<uid>` missing → `<data root>/.run`: `TestSocketDirLinuxMissingRunUserFallsBack`.
  - `/run/user/<uid>` present but owned by another uid, mode ≠ 0700, or a symlink → fallback, never used (no file created there): `TestSocketDirLinuxRefusesAForeignOrLooseRuntimeDir`.
  - `<data root>/.run` cannot be created (parent read-only) or is not ours (other owner, a symlink, a file) → `socketDirFor` returns an error naming the class (`run_dir_unusable`), `DefaultSocket` and `session-host` exit with "[Watchtower] the session host cannot use its socket folder: …", and nothing is created under `/tmp`: `TestSocketDirLinuxUnusableFallbackIsAnErrorNotTmp` (asserts no `watchtower-sh-*` entry appears in `os.TempDir()`).
  - A stale socket file from a dead host in the Linux dir → removed and rebound under the existing `.lock` rule, a live host never displaced: `TestListenRebindsAStaleSocketInTheRunDir`, `TestListenRefusesWhileALiveHostHoldsTheLock`.
  - Peer-credential read fails (`SO_PEERCRED` error) → the connection is closed before any request is read, never trusted: `TestControlSocketClosesWhenPeerCredentialsFail` (seam returns an error).
  - Home / data root cannot be determined (`HOME` unset) or the data root is unwritable → `AppSupportDir`, `DataRoot`-based `DefaultDir` and `socketDirFor` return a clear error, no relative or temp path is used: `TestAppSupportDirWithoutHomeIsAnError`, `TestDefaultHubDirWithoutHomeIsAnError` (`DefaultDir` is this task's). `TestHubEnableOnAnUnwritableDataRootFails` is Task 3's (`hub enable` creating `DefaultDir` lands there).
- [ ] **Step 2:** `go test ./internal/sessionhost ./internal/sessionstart ./internal/config ./internal/hub -run 'SocketDir|AppSupportDir|DefaultHubDir|ControlSocket|Listen'` → FAIL.
- [ ] **Step 3: Implement.** `watchtower session-host` takes its socket from `--socket` or `WATCHTOWER_SESSION_HOST_SOCKET` only (`cmd/session_host.go`) and has no log; the host and its clients agree because every client (`sessionstart` and the Desktop's Swift twin through `paths.json`) computes `DefaultSocket` and `Ensure` passes that path in the host's argv. `config.RecordingsDir` follows `AppSupportDir`, so off darwin its orphan-scan dir becomes `<data root>/.support/recordings` (harmless: a Linux host keeps no recordings).
- [ ] **Step 4: Audit note.** Add a "Linux behaviour" table to `docs/features/go-hub.md` listing every darwin-only piece on the daemon path and what Linux does instead — `internal/policy` (no MDM reader: no profile, no restriction, POLICY-01), `internal/backupexclude` (no-op), `internal/auditlog` (no unified-log line; READ-02 already says "a no-op off darwin"), `internal/ownerconfirm` (no Desktop: AGENT-07 confirmation gestures are refused), `internal/sessioncleanup` birth time (unknown → a worktree not owned by record is kept), `internal/workbenchgit` (plain copy for `.worktreeinclude`), `internal/hub/platform` (always away, no keep-awake), `internal/chat` sandbox (claude.ai mode off), `internal/planusage` (credentials file, no Keychain), `internal/daemon` process identity (`ps -o lstart=`), the clipboard (`cannot_type`), and this task's three fixes.
- [ ] **Step 5:** → PASS; `make lint-diff`.
- [ ] **Step 6: Commit** `hub: Linux-safe socket and support paths, peer credentials, darwin-only audit`.

### Task 2: Linux builds — CI on arm64, release tarballs, glibc floor, CLI-only Mac zip

**Files:**
- Modify: `.github/workflows/ci.yml` (job `go-linux-arm64`)
- Create: `.github/workflows/linux-build.yml` (`workflow_dispatch` and tags `v*`)
- Create: `scripts/build-linux.sh`, `scripts/check-glibc.sh`, `scripts/tests/test-build-linux.sh`
- Modify: `scripts/build-app.sh` (the `-X watchtower/internal/hub.DefaultRelayOrigin` ldflag from `WATCHTOWER_RELAY_ORIGIN_DEFAULT`, the release-build refusal, the CLI zip after notarization), `scripts/tests/test-build-app*.sh`, `Makefile` (`test-scripts` runs the new suite; Plan 1b Task 17's local `GOOS=linux GOARCH=arm64 go build ./...` check never landed in the Makefile — nothing to remove; add a comment that Linux builds run only in CI, cgo cannot cross-compile), `.claude/commands/release.md` (artifact step: the two Linux tarballs from the tag's `linux-build` run and the CLI zip, attached only from the launch release — decided by agent, see Resolved)

**Interfaces:**
- Produces:
  - CI job `go-linux-arm64` on `ubuntu-24.04-arm` (same `gate` condition as the existing `go-test` job, `timeout-minutes: 30`; every current CI job already runs on `ubuntu-24.04` with `libssl-dev`): `apt-get install libssl-dev`, `go build ./...`, `go test ./internal/hub/... ./internal/sessionhost/... ./internal/sessionstart/...`, and Task 8's `make hub-smoke`.
  - `scripts/build-linux.sh VERSION OUTDIR`: `go build -tags codegrammars -ldflags "-X watchtower/cmd.Version=$VERSION -X watchtower/cmd.Commit=<sha> -X watchtower/cmd.BuildDate=<utc> -X watchtower/internal/hub.DefaultRelayOrigin=$RELAY_ORIGIN"` (empty when unset), refuses to run (exit 1, "RELAY_ORIGIN is empty: a release build must pin the relay origin") when `VERSION` is a release tag (`v[0-9]*`) and `RELAY_ORIGIN` is empty — a dev version may build with it empty; then `check-glibc.sh`, then `watchtower-$VERSION-linux-$(go env GOARCH).tar.gz` (one file `watchtower`, mode 0755) and `…tar.gz.sha256`. No OAuth client ids are baked in (none are needed for Workbench).
  - `scripts/check-glibc.sh BINARY 2.35`: fails when `objdump -T` shows a `GLIBC_x.y` newer than the floor, or when `readelf -d` lists a `NEEDED` library outside `libc.so.6`, `libm.so.6`, `libresolv.so.2`, `libpthread.so.0`, `libdl.so.2`, `ld-linux-*.so.*`, `libcrypto.so.3`.
  - `linux-build.yml` (its own workflow, not a `release.yml` job: `release.yml` runs the macOS notarized build on a self-hosted path, and the Linux artifacts must be dispatchable alone for the smoke and the Pi): matrix `ubuntu-22.04` (amd64) / `ubuntu-22.04-arm` (arm64) (ask #881: native 22.04 runners, not a container; when GitHub retires the 22.04 image the floor is revisited then), Go `1.26.9`, `libssl-dev`, `scripts/build-linux.sh "${GITHUB_REF_NAME}" dist`, `actions/upload-artifact` (`watchtower-linux-<arch>`, 30 days).
  - `build-app.sh`: passes `-X watchtower/internal/hub.DefaultRelayOrigin=$WATCHTOWER_RELAY_ORIGIN_DEFAULT` in its CLI `go build` (the Global Constraint's darwin half); a release build (a clean tag version, the signed branch) with it empty exits 1 with "WATCHTOWER_RELAY_ORIGIN_DEFAULT is empty: a release build must pin the relay origin"; the ad-hoc dev branch may leave it empty. After the ZIP is notarized, `build/Watchtower-CLI-<version>-arm64.zip` = the signed `Contents/MacOS/watchtower` (its cdhash is in the notarized submission), added to `checksums.txt`; the ad-hoc branch skips it.
- **Depends on:** none

- [ ] **Step 1: Failing shell suite** `scripts/tests/test-build-linux.sh` (stubs `go`, `objdump`, `readelf`, `tar`, `sha256sum` on `PATH`): `test_names_carry_version_and_arch`, `test_glibc_newer_than_floor_fails` (stub prints `GLIBC_2.38`), `test_unexpected_needed_library_fails` (`libsqlite3.so.0`), `test_ldflags_carry_version`, `test_ldflags_carry_the_relay_origin` (`RELAY_ORIGIN=https://relay.example.com` → the `-X …DefaultRelayOrigin=` flag; unset on a dev version → empty value), `test_release_build_refuses_an_empty_relay_origin` (version `v1.2.3`, `RELAY_ORIGIN` unset → exit 1, the message, no tarball), `test_tarball_holds_only_the_binary`.
- [ ] **Step 2:** `bash scripts/tests/test-build-linux.sh` → FAIL.
- [ ] **Step 3: Implement** the scripts, the workflow, the CI job and the `build-app.sh` step (its existing suite `scripts/tests/test-build-app*.sh` keeps passing; add `test_cli_zip_only_on_the_signed_branch`, `test_cli_carries_the_relay_origin_ldflag`, `test_release_build_refuses_an_empty_relay_origin`). `linux-build.yml` passes `RELAY_ORIGIN: ${{ vars.RELAY_ORIGIN }}`.
- [ ] **Step 4:** `make test-scripts` → PASS; `actionlint .github/workflows/*.yml` if installed; push the branch and dispatch `linux-build` once: both artifacts appear and the job log shows `check-glibc: max GLIBC_2.3x <= 2.35`.
- [ ] **Step 5: Commit** `build: Linux tarballs on native runners, arm64 CI job, glibc floor, CLI-only Mac zip`.

### Task 3: Host kind and the live headless mode

**Files:**
- Create: `internal/hub/hostkind/{hostkind.go,probe.go}`
- Modify: `internal/hub/hub.go` (`Resolve`, `hub.Dir` beside `FromEnv`, the start-time host check; `supervisor.hostName()` strips at the first `.`), `internal/hub/status.go` (reasons, `Host`, `Mode`)
- Modify: `internal/config/config.go` (new `Hub` struct with `RelayOrigin`; `config.Config` has no `Hub` today), `cmd/config.go` (`knownConfigKeys["hub.relay_origin"]` + validation; no `hub.*` key exists today), `cmd/hub.go` (`hubDir()` today hard-requires `WATCHTOWER_HUB_DIR`, and `hubTestWorkspaceOK` calls `FromEnv` — both move to `hub.Dir`; status keys), `cmd/sync.go` (`startGoHub` calls `hub.Resolve` instead of `FromEnv`; its `hub: started (dir set)` log line becomes the lines below)
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
  var DefaultRelayOrigin string // ldflags: release builds pin the origin the relay session announced (a tag build refuses an empty one, Task 2); dev builds leave it empty
  func RelayOrigin(cfg *config.Config) string // WATCHTOWER_RELAY_ORIGIN > config hub.relay_origin (config set overrides the default) > DefaultRelayOrigin > "" (off, no_relay_origin)
  // no DefaultName: Phase 1's supervisor.hostName() (hub.go: display_name, else os.Hostname(); clipped by wire.ClipMacName in link/codes.go) gains the strip at the first '.'
  // Options gains: Mode Mode; Host hostkind.Kind. No Transports field: every Phase 1 hub already announces relay-only — runtime.go builds the link center with link.HeadlessHost(name, authPub) (link/relay.go: Transports [relay], RelayDeviceID, RelayAuthPub, no shares); phase 3 adds the desktop variant
  // Status gains: Host, Mode string; reasons gain "desktop_host", "no_relay_origin"
  ```
  **Resolve:** `WATCHTOWER_HUB_DIR` set → `ModeTest` through `FromEnv`, exactly Plan 1a (a set dir never falls back to live). Else `Detect`; `Desktop` → `ModeOff`, reason `desktop_host`, nothing created or opened. Else dir = `DefaultDir`: `hubstate.db` absent or `hub_meta.enabled` ≠ `1` (opened read-only) → off `disabled`, dir not created; `policy.MobileSync() == off` → `policy_off`; `RelayOrigin` empty → `no_relay_origin`; else `ModeLive` with `SessionStart: sessionstart.Deps{Socket: <sessionhost.DefaultSocket()>}` (`WATCHTOWER_SESSION_HOST_SOCKET` still wins when set; a `DefaultSocket` error → off, reason `run_dir_unusable`) — without it `wiring.sessionPort` installs the refusing `noSessionHost` port (`wiring.go`, go-hub.md Deviations 5) and every `session_start` from the phone fails — and `RecordingsDir: <dir>/recordings` (never written: no Desktop heartbeat on a headless host). The identity is already the 0600 `identity.FileStore` in the hub dir (`runtime.go` `loadIdentity`, no Options field); nothing to wire. `Detect` runs once per `Resolve`, i.e. at hub start; there is no runtime re-check (ask #827). Daemon log lines: `hub: started (live, headless)`, `hub: started (test workspace)`, `hub: off (<reason>)`.
  **CLI:** every `hub …` verb resolves its dir through `hub.Dir`; on `ErrDesktopHost` `hub status` prints state `off`, reason `desktop_host`, and every other verb exits 1 with "Mobile on this Mac is run by the Watchtower app." `hub status --json` keys become `{"state","reason","hub_id","relay_device_id","transport","impl","dir","phones","host","mode"}` (additive). `hub enable` on a headless host creates `DefaultDir` 0700.
- **Depends on:** Task 1

- [ ] **Step 1: Failing tests:** `TestDetect_LinuxIsHeadless`, `TestDetect_DarwinAppBundleIsDesktop` (both locations), `TestDetect_DarwinSwiftHubStateIsDesktop`, `TestDetect_DarwinCLIOnlyIsHeadless`, `TestDetect_ABundleWithAnotherIDIsIgnored`, `TestResolve_TestModeUnchangedWhenHubDirSet` (Plan 1a's `FromEnv` cases through `Resolve`), `TestResolve_DesktopHostNeverStartsALiveHub` (Review Focus 1: probe = desktop, `hub_meta.enabled = 1` written by hand into `DefaultDir` → `ModeOff`; a listing of `DefaultDir` and `MobileHub/` before and after is identical, mtimes included), `TestResolve_LiveIsOffUntilEnabled` (dir not created), `TestResolve_LiveNeedsARelayOrigin`, `TestRelayOriginPrecedence` (table: ldflags default only → default; default + `config set` → config; env set → env; none → `""` and reason `no_relay_origin`), `TestHubStatusPrintsTheNoRelayOriginRemedy`, `TestConfigSetRelayOriginValidates` (`https://relay.example.com` ok; `http://relay.example.com`, a path, a query → refused, nothing written; `http://127.0.0.1:8787` ok), `TestLiveHubUsesTheDefaultSessionHostSocket` (live `Resolve` with `WATCHTOWER_SESSION_HOST_SOCKET` unset → `SessionStart.Socket == DefaultSocket()`, port is not `noSessionHost`; env set → the env path), `TestLiveHubAnnouncesRelayOnly` (guard over Phase 1 behaviour, passes at once: `link.Center.Issue` → `Transports == ["relay"]`, `DataShare`/`RelayShare` nil; every `Grants()` row `Transports == ["relay"]`), `TestLiveHubUsesTheFileIdentityStore` (guard, passes at once), `TestHubEnableOnAnUnwritableDataRootFails` (moved from Task 1: exit 1, nothing written elsewhere), `TestHostNameStripsTheDomain` (`pi-acme.local` → `pi-acme`; `display_name` wins), `TestHubStatusJSONKeys` (updated), `TestHubCLIRefusesTheLiveDirOnADesktopHost`, `TestHubEnableCreatesTheLiveDirOnAHeadlessHost`.
- [ ] **Step 2:** `go test ./internal/hub/... ./cmd -run 'TestHub|TestConfigSet|TestSyncDaemon'` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** → PASS (Plan 1a's `internal/hub` tests unchanged); `make lint-diff`.
- [ ] **Step 5: Commit** `hub: live mode on headless hosts only (host kind, data-root hub dir, relay origin)`.

### Task 4: `session-host` under a service manager

**Files:**
- Modify: `internal/sessionhost/ensure.go`, `internal/sessionhost/client_test.go` (switch to the seam), `internal/sessionstart/start.go` (the failure text keeps the class)
- Create: `internal/sessionhost/export_test.go` (`SetTestLauncher`), `internal/sessionhost/sessionhosttest/serve.go` (test-only package, `ServeInProcess`)
- Test: `internal/sessionhost/ensure_test.go`

**Interfaces:**
- Consumes: Plan 1b Task 11 `sessionhost.Ensure(ctx, socket, exe)`, `ErrHostV1`.
- Produces:
  ```go
  type launcher interface{ launch(ctx context.Context, exe, socket string) error } // unexported
  func Ensure(ctx context.Context, socket, exe string) error // signature unchanged; uses productionLauncher(runtime.GOOS, exec.LookPath) unless a test launcher is installed
  func productionLauncher(goos string, lookPath func(string) (string, error)) launcher
  // test seams only. export_test.go (package sessionhost, for the in-package Ensure tests):
  func SetTestLauncher(t testing.TB) (started func() []int) // installs a launcher that starts `<exe> session-host --socket <socket>` as a child in its own process group, killed and waited for in t.Cleanup; restores the production launcher after the test
  // internal/sessionhost/sessionhosttest (test-only package, used by Task 8):
  func ServeInProcess(t testing.TB, socket string) // sessionhost.Listen(socket) + sessionhost.NewServer(sessionhost.Options{IdleExit: 0, RingSize: <the command's ring size>}).Serve in a goroutine for the whole test; IdleExit 0 disables the idle exit by construction (server.go: no idle timer when IdleExit <= 0); t.Cleanup cancels Serve, kills every hosted session's process group and waits for them. No production flag or env var is added
  // production linux: always the transient unit — there is no other way to start the host on Linux (one path per host; no detached fallback). The test launcher is a test seam, not a product mode: it lives only in export_test.go, and sessionhosttest holds only ServeInProcess (a package only tests import; a guard test fails if a non-test file imports it). darwin: the detached (setsid) spawn of Plan 1b (the CLI-only Mac's LaunchAgent sets AbandonProcessGroup)
  var ErrNoUserManager = errors.New("sessionhost: systemd-run --user failed") // wrapped with the class: no_user_bus | not_found | exit_<code>
  const SystemdUnit = "watchtower-session-host"
  ```
  Transient unit argv, exactly: `systemd-run --user --unit=watchtower-session-host --collect --quiet --property=UMask=0077 --setenv=PATH=<the daemon's PATH> [--setenv=WATCHTOWER_SESSION_HOST_SOCKET=<value>, only when set] -- <exe> session-host --socket <socket>`. A `systemd-run --user` unit runs with the user manager's environment, not the caller's: without `--setenv=PATH` the sessions it hosts cannot find `claude` in `~/.local/bin` (Fable check; only `PATH` and the socket env are passed, ask #881). `--collect` needs systemd ≥ 236 (bookworm 252, Ubuntu 22.04 249). An exit saying the unit already exists or is active means another `Ensure` won: dial again, not an error (the host side of that race is `sessionhost.Listen`'s `ErrHostRunning` under the held `.lock`). Any other failure (no user bus, `systemd-run` missing, another exit code) returns `ErrNoUserManager` with its class; `session start` then fails with "[Watchtower] the session host is not running: no systemd user manager (<class>)" in the row's `agent_error` and the phone's echo — never a detached spawn. Today `sessionstart` marks the row with the fixed `markFailed(ctx, "the session host is not running")` (`start.go`) and drops the cause: this task passes the class through for `ErrNoUserManager` (Modify `internal/sessionstart/start.go`). The host still exits 60 s after its last session (PROJ-20), which ends the transient unit.
- **Depends on:** Task 1

- [ ] **Step 0: Switch the existing tests to the seam.** `git grep -n 'Ensure(' -- '*_test.go'` finds them; today (origin/main): `internal/sessionhost/client_test.go` `TestEnsureStartsAHostWhenNoneAnswers` (spawns a host; switches to `SetTestLauncher`) and `TestEnsureNeverReplacesAV1Host` (spawns nothing; unchanged). Any test of Plan 1b Task 15 (`internal/sessionstart`, `internal/hub`) that reaches `Ensure` when it lands switches the same way. The launcher serves only these in-package `Ensure` tests; Task 8's smoke test does not use it (it runs the host with `sessionhosttest.ServeInProcess`). Re-run the grep when this task starts and list the switched tests in the commit message.
- [ ] **Step 1: Failing tests:** `TestProductionLauncherOnLinuxIsSystemdRun` (guard: `productionLauncher("linux", …)` is the systemd-run launcher, whatever the environment), `TestSessionhosttestIsImportedOnlyByTests` (guard: `go list -deps` of every non-test package excludes `internal/sessionhost/sessionhosttest`), `TestEnsureUnderSystemdUsesATransientUnit` (Review Focus 2: fake runner records the argv above byte for byte; no child of the test process), `TestEnsureOnLinuxNeverSpawnsDetached` (even without `INVOCATION_ID`: only `systemd-run` is called), `TestEnsureOnDarwinSpawnsDetached` (GOOS seam darwin → detached, `systemd-run` never called), `TestEnsureStartsAHostWhenNoneAnswers` (switched to `SetTestLauncher`; still asserts one host started, a second `Ensure` starts nothing), `TestSystemdRunFailureIsASessionStartError` (table: no user bus, `systemd-run` not on PATH, exit 1 with another message → `ErrNoUserManager` with class `no_user_bus`/`not_found`/`exit_1`; no process spawned; Plan 1b's `session start` marks the row with the pinned reason), `TestEnsureTreatsAnExistingUnitAsRunning`, `TestEnsureNeverReplacesAV1Host` (Plan 1b's, unchanged).
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
  type Status struct{ Manager string; Installed, Running bool; Linger *bool } // Linger nil on darwin or when loginctl is missing
  var ErrNoUserManager = errors.New("service: no systemd user manager is reachable")
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
  **`service install` order:** refused under an agent marker; refused on a desktop host ("This Mac has the Watchtower app, which runs the daemon itself."); on Linux, `systemctl --user show-environment` must succeed first, else exit 1 with `ErrNoUserManager` and: "Watchtower needs a systemd user manager, and this shell cannot reach one. Log in through a real session (a console or SSH login, not `su` or `sudo -u`), or run `sudo loginctl enable-linger <user>` for a host that should run without a login, then try again." — nothing written; `loginctl` missing → linger unknown (`linger: null`), the linger hint printed anyway, install continues; `initWorkspace(configPath, override, name, headless bool)` (the existing function gains the flag; `workspace init` passes `--headless`); `hub enable` (direct write, no hub runs yet); write the unit (rewritten only when it differs, then restarted); start; print status and "Next: watchtower hub pair". Idempotent.
  **`workspace init --headless`:** when it creates the config, writes `enabled: false` for every registry feature with a `ConfigKey` that is not `Core` (spec §3: only Workbench on, onboarding not run); on an existing config it changes no feature ("Kept your feature settings."). `--json` keys unchanged.
  **CLI keys (pinned):** `service status --json` → `{"manager","installed","running","linger"}` (`linger` null on darwin); `service install|uninstall --json` → the same object.
- **Depends on:** Task 3, Task 4

- [ ] **Step 1: Failing tests:** `TestSystemdUnitGolden`, `TestLaunchdPlistGolden`, `TestUnitsHoldNoSecret` (only `PATH` in the environment; no token, no key), `TestInstallRunsSystemctlInOrder` (fake runner), `TestInstallPrintsTheLingerHintWhenOff`, `TestInstallRefusedWhenSystemctlUserIsUnreachable` (fake runner fails `show-environment` → exit 1, the message above, no unit, no workspace, no `hub enable`), `TestInstallWithoutLoginctlPrintsTheHintAndContinues` (`linger` null), `TestInstallRefusedOnADesktopHost` (no unit written, no workspace created), `TestServiceVerbsRefusedUnderAnAgentMarker`, `TestInstallIsIdempotent` (second run: no rewrite, no restart), `TestUninstallKeepsData`, `TestLaunchdFallsBackToTheUserDomain`, `TestServiceStatusJSONKeys`, `TestWorkspaceInitHeadlessTurnsOffEveryNonCoreFeature`, `TestWorkspaceInitHeadlessKeepsAnExistingConfig`.
- [ ] **Step 2:** `go test ./internal/service`, `go test ./cmd -run 'TestService|TestWorkspaceInit'` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `cmd: service install|uninstall|status (systemd user unit, LaunchAgent), workspace init --headless`.

### Task 6: Terminal pairing

**Files:**
- Create: `docs/design/mockups/go-hub/hub-pair-terminal.html` (owner review before Step 3, spec §12.4)
- Create: `internal/termqr/termqr.go`; Modify: `go.mod`/`go.sum` (`github.com/skip2/go-qrcode`, new — approved in ask #881), the CLI's generated third-party notices (`scripts/build-app.sh` notices step, ruling R18) and `scripts/tests/test-build-app-notices.sh` so the new module is listed
- Create: `cmd/hub_pair_tty.go`; Modify: `cmd/hub.go` (`hub pair` without `--json`)
- Test: `internal/termqr/termqr_test.go`, `cmd/hub_pair_tty_test.go`, `internal/hub/link/headless_test.go`

**Interfaces:**
- Consumes: Plan 1a Task 15's pair stream over `hub.sock` (events `qr` `{url, expires_at}`, `waiting`, `sas` `{device_id, name, code}`, `linked` `{device_id}`, `refused` `{reason}`, key `event`, `cmd/hub_link.go`; reasons `wire.Refused*`; request `{"confirm":true|false}`; today `hub pair` refuses anything but `--json --stream`); Task 3 `hub.Dir`, the hub's display name.
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
- [ ] **Step 2: Failing tests:** `TestRenderMatchesTheBitmap` (decode the half-block lines back into a module matrix; equal to `qrcode.New(url, Low).Bitmap()`), `TestWidthOfAV4HeadlessLink` (the fixture's `v4_headless` URL; asserts the number used by the narrow-window hint), `TestHubPairNeedsATerminal`, `TestHubPairTTYFlowLinked` (pty via `github.com/creack/pty`; scripted `y` → `{"confirm":true}` sent, output lines in order), `TestHubPairTTYAnythingButYesRefuses` (`n`, empty line, EOF), `TestHubPairTTYRefusalLines` (table over the five reasons + an unknown one; exit 1), `TestHubPairCtrlCDuringTheSASSendsNo`, `TestHubPairEscapesThePhoneName` (Review Focus 4: name `"acme\x1b]0;x\x07‮"` prints as `acme0;x`), `TestHubPairNarrowWindowPrintsTheWidenHint`, `TestHeadlessLinkPayloadHasNoShares` (guard over Phase 1's `link.HeadlessHost`, passes at once: live headless `Issue()` → `transport "relay"`, `transports ["relay"]`, no shares, `mac_name` = the stripped hostname).
- [ ] **Step 3:** `go test ./internal/termqr ./internal/hub/link ./cmd -run 'TestHubPair|TestRender|TestWidth|TestHeadlessLinkPayload'` → FAIL.
- [ ] **Step 4: Implement.**
- [ ] **Step 5:** → PASS; `make lint-diff`.
- [ ] **Step 6: Commit** `cmd: hub pair in a terminal (block-character QR, SAS prompt, refusals)`.

### Task 7: Relay-only rules on a headless hub

**Files:**
- Create: `internal/hub/paying.go`
- Modify: `internal/hub/hub.go`/`runtime.go` (wire `PayingWatch` in live mode), `internal/hub/status.go` (state `paused`, reason `needs_relay`), `internal/hub/slices/publisher.go` (`Pause`/`Resume`), `internal/hub/actions/processor.go` (`SetPaused`)
- Test: `internal/hub/paying_test.go`

**Interfaces:**
- Consumes: Plan 1a `relay.Transport.AccountState` (only `*relay.Transport` has it; the `transport.Transport` interface does not), `transport.Event{Control}`, `transport.ErrEntitlementInactive`, `slices.Publisher`, `actions.Processor`, `FlushControls`. The runtime already asserts an optional `admission interface{ Admitted() bool }` on the transport (`runtime.go`, reason `ReasonNotAdmitted`): the account-state hook is a second optional interface asserted the same way (`accountStater interface{ AccountState(ctx) (*relayv1.AccountState, error) }`, implemented by `*relay.Transport` and `memfake`), and the new type is named `PayingWatch` so it does not sit beside the existing `admission`.
- Produces:
  ```go
  type AccountState func(ctx context.Context) (*relayv1.AccountState, error)
  type PayingWatch struct{…}
  func NewPayingWatch(state AccountState, clock func() time.Time) *PayingWatch
  func (a *PayingWatch) Observe(ev transport.Event, saveErr error) // ENTITLEMENT_EXPIRED, SLOT_REMOVED or ErrEntitlementInactive → re-read now
  func (a *PayingWatch) Run(ctx context.Context, onChange func(paying bool)) error // re-read every NeedsRelayPoll while not paying
  // status.go gains StatePaused beside its existing states
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
- Create: `internal/hub/relaytest/server.go` (exported in-process fake relay over the copied proto). Phase 1's `fakeRelay` (`internal/hub/transport/relay/fakerelay_test.go`, HTTP ops + `/v1/ws`) moves here and its tests import it, but it is **extended**, not moved unchanged: today it has no `open_pairing`/`promote_pairing`/`add_slot`, no per-phone `paying` model and no `ENTITLEMENT_EXPIRED` control push. This task adds them (`PAIRING_OPENED` over the ws, `SetPaying` + the control push, `Frames()`); the phone side already exists (`hubtest.RelayStore.OpenPairing/PromotePairing`). Budget the task accordingly.
- Create: `cmd/hub_headless_smoke_test.go` (`//go:build smoke`)
- Test: `cmd/session_host_test.go` (`TestSessionHostCommandUsesTheFixed60sIdleExit`)
- Modify: `cmd/session_host.go` (a test seam capturing the `Options` it builds, no behaviour change), `Makefile` (`hub-smoke`), `.github/workflows/ci.yml` (Go Test job runs `make hub-smoke` after the coverage gate; Task 2's arm64 job already does)

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

- [ ] **Step 1: Failing test** `TestHeadlessSmoke_PairStartTypeEcho`: builds the binary into `t.TempDir()`; `HOME` in a temp dir; on linux the daemon finds the in-process host through `sessionhost.DefaultSocket()` under the temp `HOME` (`<data root>/.run` on a runner without `/run/user/<uid>`, else the runner's own `/run/user/<uid>` — the test then asserts no other host answers there first), so the hub side never relies on `WATCHTOWER_SESSION_HOST_SOCKET` (it must catch a live `Resolve` that forgets the socket, Task 3); on darwin's test mode the env is still set; before starting the daemon the test runs the host **in-process** with `sessionhosttest.ServeInProcess(t, <that socket>)` for the whole test (CI runners have no systemd user manager, and Linux has no detached fallback); with `IdleExit: 0` it never idle-exits, so build, daemon start and pairing may take as long as they take; just before `session_start` the test asserts the host still answers (`sessionhost.Dial` + `List` succeed), so the daemon's `Ensure` finds it running and spawns nothing; on darwin it runs in Plan 1a's test mode (`WATCHTOWER_HUB_DIR`, `WATCHTOWER_HUB_TEST_WORKSPACE=hubtest-smoke`, because a dev Mac is a desktop host), on linux in live mode (no `WATCHTOWER_HUB_DIR`). Steps: `workspace init --headless` (`--name hubtest-smoke` on darwin); `config set hub.relay_origin <relaytest URL>`; `hub enable`; `sync --daemon` in its own process group; wait for `hub status --json` `state == "running"`; `hub pair --json --stream` → `hubtest.Phone` reads the `qr` URL, opens the slot, writes its hello with its `relay_device_id`, both SAS codes equal, `{"confirm":true}` → `linked`; `workbench create --folder <temp git repo>`; `hub allow <dev> start_sessions` and `typing`; the phone sends `session_start` (a stub `claude` first on `PATH` that turns bracketed paste on and appends its stdin to a file) then `session_input "hello"`; the stub's file holds `ESC[200~hello ESC[201~` followed by a lone CR; echo `applied`; no plaintext marker from the action payload in `relaytest.Frames()`; `relaytest.SetPaying(phone, false)` → `hub status` reason `needs_relay` within one admission read. Cleanup: `sync stop`, SIGKILL to the daemon's group, waited for; the in-process host and its sessions are stopped by `ServeInProcess`'s cleanup.
  Failure path covered — idle exit: `session-host` exits 60 s after start when no session is attached (PROJ-20), and on a slow arm64 runner building, starting the daemon and pairing can take longer; with no systemd user manager `Ensure` could not restart it and `session_start` would fail. A held client connection would not help: `isIdle()` counts only sessions and bound connections, and an unbound control connection explicitly does not keep the host alive (`Options.IdleExit` doc). The test avoids the case by running the host in-process with `IdleExit: 0` and pins it with the liveness assertion above; the production command keeps its fixed 60 s, pinned by `TestSessionHostCommandUsesTheFixed60sIdleExit` (`cmd/session_host_test.go`: the `Options` passed to `NewServer` by `watchtower session-host`, captured through a test seam, carry `IdleExit == 60 * time.Second`; no flag or env changes it).
- [ ] **Step 2:** `make hub-smoke` → FAIL.
- [ ] **Step 3: Implement** the exported server and fix whatever the smoke finds at its source.
- [ ] **Step 4:** `make hub-smoke` → PASS locally (darwin, test mode) and in the CI Linux jobs (live mode, amd64 and arm64).
- [ ] **Step 5: Commit** `hub: Linux smoke test — daemon, terminal-free pairing, stub session, typed line`.

### Task 9: Recording switch (protocol §9, §7.7)

**Files** (protocol §7.7's list):
- Modify: `internal/hub/state/recordings.go` (`desktop_seen_at`, the switch, the one-time carry-over), `internal/hub/actions/handlers/recording.go` (intake by the switch, echo `reason`), `internal/hub/actions/recording.go` (the hold: first-held time, 7-day expiry, fail-all on off), `internal/hub/slices/heartbeat.go` (`capabilities`)
- Create: `cmd/hub_recordings.go`; Modify: `cmd/hub_recording.go` (`hub desktop heartbeat` refused off darwin — moved here from Task 1 so wave 1 stays parallel; Task 1 touches neither this file nor `internal/hub/slices/heartbeat.go`)
- Create: `internal/hub/state/migrations/00006_held_uploads.sql` (the next free number: origin/main has `00001`–`00005`; re-check the newest file when the task starts)
- Modify: `WatchtowerKit/Tests/Fixtures/link/hub_contract_cases.json` (new `heartbeat` and `upload_echo` lists in the file's existing shape — top-level lists like `device_grant`/`link_payload`/`encoding`, each case `{name, json, expect, kit}`), `internal/hub/wire/contract_test.go` (`TestHubContractFixture` reads them), `internal/hub/wire/payloads.go` (`Heartbeat` has no `capabilities` field yet)
- Test: `internal/hub/state/recordings_test.go`, `internal/hub/actions/handlers/recording_test.go`, `internal/hub/slices/heartbeat_test.go`, `cmd/hub_recordings_test.go`

**Interfaces:**
- Consumes: Plan 1b Task 5 (`Store.DesktopHost`, `hub_meta.desktop_at`/`desktop_seen`, `recording_upload` intake, `hub desktop heartbeat`), Plan 1a Task 13 `slices.HeartbeatSource`, Plan 1a Task 14/15 control socket and owner-verb refusal. Protocol: `docs/superpowers/specs/2026-10-31-hub-phone-protocol-design.md` §7.7, §9 (approved, ask #834).
- Produces:
  ```go
  package state
  const MetaDesktopSeenAt, MetaRecordings = "desktop_seen_at", "recordings" // hub_meta keys: a timestamp; "on" | "off"
  func (s *Store) DesktopSeenAt() (time.Time, bool, error) // the first Desktop heartbeat; never cleared automatically
  func (s *Store) Recordings() (on bool, stored bool, err error) // stored value wins; else on iff DesktopSeenAt is set
  func (s *Store) SetRecordings(on bool) error              // refuses on=true with ErrNoTranscriber when DesktopSeenAt is unset
  var ErrNoTranscriber = errors.New("this host has no transcriber")
  const HeldUploadMaxAge = 7 * 24 * time.Hour
  func HoldUpload(tx *sql.Tx, uploadID, deviceID string, at time.Time) error // INSERT OR IGNORE: the first hold's time stays
  func (s *Store) HeldUploads() ([]HeldUpload, error)                       // unsettled rows
  func SettleHeldUpload(tx *sql.Tx, uploadID, outcome string, at time.Time) error // outcome "received" | "not_supported" | "expired"
  type HeldUpload struct{ UploadID, DeviceID string; HeldAt time.Time }
  ```
  - `00006_held_uploads.sql`: `CREATE TABLE held_uploads(upload_id TEXT PRIMARY KEY, device_id TEXT NOT NULL, held_at REAL NOT NULL, outcome TEXT CHECK (outcome IN ('received','not_supported','expired')), settled_at REAL)` — ids, timestamps and an outcome class only, no record name, no text. Today (Plan 1b Task 5) held uploads live in memory; the intake now writes the row in the same transaction as its first `held` echo, and the 7-day expiry and the switch-off failure read the table, so both survive a restart.
  - `hub_meta` keys need no migration. On `Open`, a sidecar with `desktop_seen = "1"` and no `desktop_seen_at` gets `desktop_seen_at = desktop_at` once (one transaction); the first heartbeat on a fresh sidecar writes it.
  - Heartbeat payload gains `"capabilities": {"recordings": "on"|"off"}`; a switch change nudges `Publisher.PublishSoon("heartbeat")`, so the new value is published in the next publish cycle, within `slices.MaxDebounceWait` (1 s).
  - Intake: switch off → final `failed`, `reason: "not_supported"`, `error_message` "This host can't transcribe recordings. Your recording stays on your phone.", nothing written; switch on → Desktop fresh = `received` (as Plan 1b), stale = `held`. A held upload's first-held time is its `held_uploads.held_at`; `HeldUploadMaxAge` after it → final `failed`, `reason: "expired"`. Turning the switch off fails every held upload with `not_supported`. The phone keeps its audio on every `failed`.
  - Upload echo gains the optional `reason` key (`not_supported`, `expired`, …); `received` carries none.
  - CLI (pinned keys): `hub recordings on|off [--json]` → `{"recordings","stored"}`; `hub status --json` gains `"recordings"` (additive). Owner verb: refused under an agent marker; `on` on a host with no `desktop_seen_at` → exit 1 "this host has no transcriber" (so a Linux host never publishes `on`).
- **Depends on:** none (Phase 1 merged)

- [ ] **Step 1: Fixture cases** in `hub_contract_cases.json` `heartbeat`: `capabilities_on`, `capabilities_off`, `capabilities_absent` (expect: reads as on), `capabilities_unknown_value` (`"recordings": "partial"` → not off), `unknown_capability_key` (ignored); `upload_echo`: `failed_not_supported` (with `reason`), `failed_expired`, `received` (no `reason`), `failed_legacy_no_reason`. The Kit side that decodes them is the neighbour's (Phone contract point 5).
- [ ] **Step 2: Failing tests:** `TestHubContractFixture` (heartbeat and upload-echo cases decode to `expect`; Go encodes `capabilities` and `reason` byte-equal to the `on`/`off`/`failed_not_supported` cases), `TestRecordingsDefaultIsOnIfDesktopWasEverSeen`, `TestRecordingsDefaultIsOffWithoutDesktop`, `TestStoredRecordingsValueWins`, `TestDesktopSeenAtSurvivesARestart` (protocol §9's required test: a heartbeat, close, reopen with no new heartbeat → default still `on`), `TestDesktopSeenCarriedOverOnce` (`desktop_seen = "1"`, `desktop_at = T` → `desktop_seen_at = T`; a second open changes nothing), `TestDesktopSeenAtIsATimestamp` (Plan 1b Task 16's column/key allowlist), `TestRecordingsOnRefusedWithoutATranscriber` (CLI exit 1, the message, nothing stored), `TestHubRecordingsRefusedUnderAnAgentMarker`, `TestHubRecordingsJSONKeys`, `TestHeartbeatCarriesTheRecordingsCapability` (on/off), `TestSwitchChangeIsPublishedWithinMaxDebounceWait` (fake clock: `hub recordings off` → a saved heartbeat with `"off"` no later than `slices.MaxDebounceWait` after the change), `TestSwitchOffFailsUploadsNotSupported` (echo `failed`, `reason: "not_supported"`, no file under the recordings dir), `TestHeldUploadExpiresAfter7Days` (fake clock: 6 d 23 h still `held`, 7 d → `failed`/`expired`), `TestHeldUploadExpirySurvivesARestart` (held at T, hub closed and reopened at T + 7 d with no new upload record → `failed`/`expired`; the row's `held_at` unchanged by repeated passes), `TestHeldUploadsHoldNoContent` (Plan 1b Task 16's `TestSidecarHasNoNewUnsealedContentColumns` allowlist gains `held_uploads.upload_id: id`, `device_id: id`, `held_at: timestamp`, `outcome: enum`, `settled_at: timestamp`; the test fails if the migration adds anything else), `TestDesktopHeartbeatRefusedOffDarwin` (moved from Task 1: `runtime.GOOS` seam `linux` → exit 1 "there is no Watchtower app on Linux", `desktop_seen_at` never written, so `hub recordings on` stays refused on Linux), `TestTurningOffFailsEveryHeldUpload`, `TestFILES01_RecordingSwitchLogsNoNames` (`logcanary`).
- [ ] **Step 3:** `go test ./internal/hub/... ./cmd -run 'TestHubRecordings|TestHubContractFixture'` → FAIL.
- [ ] **Step 4: Implement.** The `hub recordings` write goes over the control socket to a running hub, else under the hub lock (Plan 1a Task 15's rule).
- [ ] **Step 5:** → PASS; `make kit-test FILTER=HubContractFixtureTests` still passes with today's Kit (unknown keys ignored); `make lint-diff`.
- [ ] **Step 6: Commit** `hub: recording switch — capabilities.recordings, desktop_seen_at, upload echo reason, 7-day held expiry`.

### Task 10: Vouching end to end — **blocked on relay ask #805**

**Files:**
- Re-copy: `internal/hub/transport/relay/{client,relayv1,VERSION}` with `make relay-go RELAY=../relay REF=<vouch commit>` (copy committed alone first, as Plan 1a Task 8)
- Modify: `internal/hub/transport/relay/transport.go` (register as the hub kind, empty attestation), `internal/hub/transport/relay/errors.go`, `internal/hub/transport/errors.go` (`ErrNotVouched`)
- Create: `internal/hub/state/migrations/00007_relay_admission.sql` (after Task 9's `00006`; re-check the newest file)
- Modify: `internal/hub/link/relay.go` (admission per phone), `internal/hub/admission.go` (Task 7: unvouched = no publishing), `internal/hub/status.go`, `cmd/hub.go` (`hub phones` `transport`), `internal/hub/hubtest/phone.go` (`Vouch`), `internal/hub/relaytest/server.go` (vouch model), `internal/hub/state/columns_test.go` (allowlist), `internal/hub/interop_test.go`
- Test: `internal/hub/transport/relay/vouch_test.go`, `internal/hub/vouch_test.go`

**Interfaces:**
- Consumes: the relay commit's names. Working names below; **copy the names the relay commit fixes** and rename here and in the §12a list if they differ: `DEVICE_KIND_HUB`, op `vouch_hub{hub_device_id, auth_pub}` with the phone's App Attest assertion over the relay's vouch digest, `ERROR_CODE_HUB_NOT_VOUCHED`.
- Produces:
  - `00007`: `ALTER TABLE devices ADD COLUMN relay_admitted_at REAL` (a timestamp, no content; allowlist class `timestamp`).
  - `var ErrNotVouched = errors.New("transport: the relay has not admitted this hub")`; status reasons `not_vouched` (registered, no vouching phone in an active slot yet; replaces Plan 1a's `not_admitted` for a headless hub) and `vouch_revoked` (`HUB_NOT_VOUCHED` after having been admitted: the hub left every slot).
  - Rules: register with the hub kind and no attestation; until `get_account_state` lists a phone holding this hub in an active slot, the hub saves only into the `pair/<slot>` zone it was opened for — never the data zone, never a mailbox — and does not count itself on the relay (spec §12a); a phone listed there gets `relay_admitted_at`; `hub phones` shows `transport: "pending"` for a linked phone without it, `"relay"` with it; `vouch_revoked` stops publishing, keeps the sidecar, and a new `hub pair` + vouch admits it again.
  - `func (p *Phone) Vouch(ctx context.Context, hubDeviceID string, authPub []byte) error` then the existing promote.
- **Depends on:** Task 7, Task 8, relay ask #805

- [ ] **Step 1: Failing tests** (spec §13 vouch branches): `TestRegistersAsAHubWithoutAttestation`, `TestUnvouchedHubOnlyWritesItsPairingSlot`, `TestVouchAcceptedAdmitsTheHub` (vouch + promote → account state lists the phone → first data-zone save; `relay_admitted_at` set), `TestVouchRefusedKeepsTheHubOffTheRelay` (table: `ATTESTATION_REQUIRED`, `ATTESTATION_FAILED`, `SLOT_LIMIT` on the phone's `vouch_hub` → no promote, no data-zone or mailbox save, status `not_vouched`, `hub phones` `transport: "pending"`), `TestHubNotVouchedAtLoginIsRevoked` (→ `vouch_revoked`, nothing published, sidecar intact; a new link re-admits), `TestHubNeverCountsItselfOnTheRelayBeforeAdmitted`, `TestRelayAdmittedAtIsATimestamp` (allowlist), `TestInterop_VouchedHubLinksAndPublishes` (`-tags interop`, local stand).
- [ ] **Step 2:** `go test ./internal/hub/...` → FAIL.
- [ ] **Step 3: Implement.** Write the final wire names and error codes into this spec's §12a vouching bullet (one line, as §12a requires); the relay client spec's copy is its session's edit, named in the PR body.
- [ ] **Step 4:** `go test ./internal/hub/...`, `make relay-interop RELAY=../relay`, `make hub-smoke` → PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `hub: vouched admission on the relay (unvouched registration, not_vouched / vouch_revoked)`.

### Task 11: Guide page, privacy, CLI reference, feature note

**Files:**
- Create: `docs/guide/features/headless-host.md` (feature template, < 8 KB without its card)
- Modify: `docs/guide/README.md` (one catalogue line), `docs/guide/concepts/privacy.md` (`## On a Linux host or a Mac without the app`), `docs/guide/reference/cli.md` (`hub …`, `service …`, `workspace init --headless`)
- Modify: `docs/features/go-hub.md` (Phase 2 section), `CLAUDE.md` (the go-hub feature line mentions phase 2), the chat system prompt golden (regenerated in Step 3)
- Modify: `docs/inventory/workbench.md` (PROJ-20 changelog line: "2026-10-31 (Go hub phase 2, ask #827): amended for Linux only — the `session-host` socket is in `/run/user/<uid>` (fallback `<data root>/.run`, 0700) instead of `/tmp`, and the daemon starts the host as its own transient systemd user unit so a daemon restart keeps sessions; darwin unchanged, no guard relaxed."), `docs/inventory/agent-actions.md` (AGENT-07 changelog line, ask #827: on a headless host the owner verbs are `watchtower hub …`/`service …`, refused under every marker and confirmed by the terminal; the Desktop-confirmed gestures stay refused on Linux)

**Interfaces:** none new.
- **Depends on:** Task 5, Task 6, Task 7, Task 10 (WRITING.md rule 7: the page ships only once a headless host works against the real relay)

- [ ] **Step 1: Write the page** (WRITING.md rules; every string checked against the code): *Why use it* (workbenches on a box with no screen, driven from the phone; one scenario: a Pi on a shelf runs a Claude Code session while you are out); *How it works* (outbound only, nothing listens; the phone's subscription admits the host; relay only, no iCloud; what a headless host does not do: recordings, the clipboard fallback, Slack/Gmail/Jira pipelines are off); *Using it* (Linux: download the tarball for your architecture, check its `.sha256`, put `watchtower` on your `PATH`; needs 64-bit, glibc 2.35+, `libssl3`, `git`; install Claude Code or Codex and sign in — on a box with no browser `claude` prints a URL to open on another device; `watchtower service install`; `sudo loginctl enable-linger <user>` when asked; `watchtower config set hub.relay_origin …` only if told to; `watchtower workbench create --folder …`; `watchtower integrate claude-code`; `watchtower hub pair`; `watchtower hub allow …`; a Mac without the app: the CLI zip and the same steps with a LaunchAgent); *When it's empty or wrong* (`watchtower hub status` reasons → fixes: `needs_relay`, `not_vouched`, `vouch_revoked`, `desktop_host`, `no_relay_origin`, `disabled`; "[Watchtower] the session host is not running"; the QR is cut → widen the window or open the link); *Related*. One learn card: `id: headless-host-run`, `title: Run workbenches on a Linux box`, `area: iphone`, `level: power`, `kind: feature`, `since: next`.
- [ ] **Step 2: Privacy section:** the hub identity is a 0600 file under `~/.local/share/watchtower/.hub` (no Keychain or Secure Enclave on a headless host — spec §12.2); no unified-log audit line off macOS (READ-02); no organization policy off macOS; everything that leaves the host is end-to-end encrypted as on the Mac.
- [ ] **Step 3:** `go test ./docs/guide/ ./internal/kb/ ./internal/chat/ ./internal/learn/` → FAIL on the golden; regenerate with `go test ./internal/chat -run TestBuildSystemPrompt_Golden -update`; → PASS.
- [ ] **Step 4: Commit** `docs: headless host guide page, privacy and CLI reference, go-hub phase 2 note`.

### Task 12: Kit phone ↔ Go headless hub interop — **blocked on relay client spec Phase 3 (phone) and Task 10**

**Files:**
- Modify: `scripts/relay-interop.sh` (`KIT=1`: starts a live headless hub against the stand, then runs the Kit suite)
- Create: `WatchtowerKit/Tests/WatchtowerSyncTests/GoHubInteropTests.swift` (skipped unless `WT_RELAY_INTEROP_URL` and `WT_HUB_INTEROP_DIR` are set)

**Interfaces:**
- Consumes: the neighbour session's `HostedRelayTransport` and phone link flow; the hub side's `hub pair --json --stream`.
- Produces: the script writes the pairing URL to `$WT_HUB_INTEROP_DIR/pair.url`, waits for the Kit test's code in `pair.sas`, and answers `{"confirm":true}` only when it equals the hub's `sas.code`.
- **Depends on:** Task 8, Task 10, relay client spec Phase 3

- [ ] **Step 1: Failing Kit tests:** `testKitPhoneLinksAHeadlessHub` (Kit parses the relay-only v4 QR, hello with its `relay_device_id`, SAS equal, vouch, promote, `device_grant.transports == ["relay"]`), `testKitPhoneOpensEveryRecordKindTheGoHubSealed` (spec §13 E2E (3)), `testGoHubAppliesKitActionsInOrder` (a1..a3 incl. a `session_input` to a stub session → `applied`), `testRecordingOnAHeadlessHubIsNotSupported`.
- [ ] **Step 2:** `make relay-interop RELAY=../relay KIT=1` → FAIL; implement the script part; → PASS; `make lint-swift`.
- [ ] **Step 3: Commit** `hub: Kit phone interop with a headless hub over the relay stand`.

### Task 13: Phase 2 gate — a real Pi and a real CLI-only Mac from a real phone — **blocked on the relay deploy and the phone**

**Files:** none (results in the PR body, redacted: no hostnames, ids, accounts or origins).

**Interfaces:** none.
- **Depends on:** Tasks 1–12; the vouch change on the staging relay; a phone development build with relay client Phases 2–3.

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
  - P18 Privacy: `stat -c '%a' ~/.local/share/watchtower/.hub ~/.local/share/watchtower/.hub/identity.key` [`700`, `600`]; `journalctl --user -u watchtower.service | grep -c '<a word typed in P12>'` [0]; `ls -ld /run/user/$(id -u)/watchtower-sh-*.sock` [mode `srw-------`]; from a `sudo -u <user> -i` shell without `XDG_RUNTIME_DIR`, `watchtower hub status` still reaches the running host [same answer as P8].
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
- **PROJ-20 amended, Linux only:** socket in `/run/user/<uid>` (fallback `<data root>/.run`), `session-host` as its own transient systemd unit (Tasks 1, 4; changelog in Task 11).
- **Owner verbs on a headless host** go through `watchtower hub …`, confirmed by the terminal (Tasks 3, 5, 6; changelog in Task 11).
- **Decided by agent:** the live hub dir `<data root>/.hub` and `config.AppSupportDir()` = `<data root>/.support` off darwin (Tasks 1, 3); Linux tarballs and the CLI zip attached to releases only from the launch release, supported Linux = 64-bit, glibc ≥ 2.35, `libssl3` (Task 2).
- **Recording capability:** approved in the phone ↔ hub protocol (ask #834, `docs/superpowers/specs/2026-10-31-hub-phone-protocol-design.md` §7.7, §9) and built here as Task 9.
- **Linux hosts need a systemd user manager; no detached session-host** (spec Decisions, ask #829; the owner saw it across asks #830/#835 without objection). **Glibc floor 2.35 / `libssl3` / 64-bit, Linux tarballs from the launch release:** decided by agent (Global Constraints, Task 2).

## Resolved in ask #881 (after the Fable check)

- `github.com/skip2/go-qrcode` (MIT) is approved for `hub pair`, listed in the CLI's third-party notices (Task 6).
- Linux builds run on native `ubuntu-22.04` / `ubuntu-22.04-arm` runners for the glibc 2.35 floor, not in a container (Task 2).
- A CLI-only Mac without a GUI login runs no daemon until a login: a known limit, no sudo step (Task 5, Known limits).
- The `session-host` transient unit gets only `PATH` and `WATCHTOWER_SESSION_HOST_SOCKET` (when set) through `--setenv` (Task 4).

## Known limits

- Desktop detection on a Mac looks only at `/Applications/Watchtower.app`, `~/Applications/Watchtower.app` and `MobileHub/`: a Desktop installed at another path, or installed but never run (no `MobileHub/`), is not detected, and the live hub starts beside it. The owner ruled this case not relevant (conversation after ask #827).
- Phase 3 does not migrate a CLI-only Mac's `<data root>/.hub` state into the desktop hub; such a Mac that later runs the Desktop app links its phones again.
- A Linux host without a systemd user manager is not supported: `service install` refuses, and `session start` fails with the reason class.
- A CLI-only Mac starts the daemon only at a GUI login: a `~/Library/LaunchAgents` plist is loaded by launchd at login, and there is no linger equivalent without a LaunchDaemon (sudo). A CLI-only Mac that reboots into the login window runs no hub until the owner logs in (Task 5 M-steps and the guide say so; accepted as a known limit in ask #881).

## Later (not in this plan)

- A thin management CLI for a headless Watchtower (owner, ask #827); until then the owner manages a headless host with `watchtower hub …`, `watchtower service …` and the existing commands.

## Self-review (done while writing)

- **Spec coverage:** protocol §7.7/§9 recording switch (Task 9); §14 row 2 — linux/arm64 + amd64 builds (Task 2), CLI-only Mac (Tasks 2, 3, 5, 13 M1–M4), systemd units (Tasks 4, 5), headless pairing (Task 6), vouching end to end (Task 10, interop 12), relay-only rules (Task 7), guide page (Task 11), gate on a real Pi from a real phone (Task 13). §7.3 — relay-only, needs Relay, free phone (contract point 1 + Task 6 terminal line + Task 3 no shares), CLI-only Mac rule: one start check, `desktop_host` (Task 3), host differences (Global Constraints, Task 1 audit). §10 — terminal QR, SAS prompt, `transports`, hostname (Tasks 3, 6). §11 — `service install`, Claude login on a headless box (Tasks 5, 11, 13 P3). §12.1 — never two hubs (Task 3). §12.2 — 0600 file on Linux (Task 3, privacy page Task 11). §12.4 — terminal mockup (Task 6). §13 — Linux arm64 build + smoke (Tasks 2, 8), vouch branches (Task 10), relay-only on `entitlement_expired` (Task 7), free phone for a headless host (Task 6 `TestHeadlessLinkPayloadHasNoShares`; the refusal itself is the phone's), device gate (Task 13). Out of scope: CloudKit bridge, adoption, Keychain store, Desktop rewiring (phase 3); pushes (phase 4).
- **Phase 1 hand-offs fixed here:** Plan 1b Task 17's local `GOOS=linux GOARCH=arm64 go build ./...` cannot build (cgo, verified: `internal/sqlcipher/wt_nocgo.go`); Task 2 replaces it with the native arm64 CI job. Plan 1a Task 12's deferral of the vouch tests lands in Task 10.
- **Types across tasks:** `hostkind.Detect`/`Kind` (3 → 5, 12), `hub.Resolve`/`Dir`/`Mode`/`DefaultDir` (1, 3 → 5, 6, 8), `sessionhost.Ensure` + in-package seam `SetTestLauncher` (4) and `sessionhosttest.ServeInProcess` (4 → 8), `service.Installer` (5 → 8), `termqr.Render` (6), `PayingWatch`/`Publisher.Pause`/`Processor.SetPaused` (7 → 8, 10), `relaytest.Server` (8 → 10), `state.Recordings`/`SetRecordings`/`DesktopSeenAt`, `HeldUploadMaxAge` (9), `transport.ErrNotVouched`, `devices.relay_admitted_at` (10).
- **Ask #828 review round re-checked:** the socket dir has one signature (`socketDirFor(goos, tempDir, dataRoot, uid, stat)`, no env) used by host and clients; `productionLauncher(goos, lookPath)` has no detached path on Linux and both `sessionhost.ErrNoUserManager` (runtime) and `service.ErrNoUserManager` (install) have a test; the relay origin precedence (env > config > ldflags default > off) is pinned by one table test and the build script test; the smoke test pre-starts its host, so it needs no user manager; darwin/amd64 is gone from every task (the CLI zip was already arm64 only).
- **Ask #830/#835 re-checked:** the smoke test no longer depends on timing: its host runs in-process with `IdleExit: 0` for the whole test (no held-connection claim), an assertion checks it answers before `session_start`, and a guard pins the production 60 s; Task 1's failure paths each name a test.
- **Ask #829 review round re-checked:** `Ensure` keeps its signature; the only non-production launcher lives in `export_test.go` for the in-package `Ensure` tests, `sessionhosttest` holds only `ServeInProcess` for the smoke test, with two guard tests; both build scripts carry the relay-origin ldflag and refuse an empty one on a release build, each with a script test; the relay-origin rule reads the same in Global Constraints and Task 3.
- **Ask #827 revision re-checked:** no task depends on a runtime host re-check (removed from Task 3; Review Focus 1 now points at start-time tests only); the recording field appears in no task or contract point; every former open item is either a Resolved line or a Later line.
- **Ask #836 re-checked:** Task 9 depends only on Phase 1 and covers every hub-side item of protocol §7.7/§9 with a test (verb, default, restart, carry-over, capability, echo `reason`, 7-day expiry, fail-on-off, fixture); its Kit counterpart is an external contract point; no smoke-test reference to `SetTestLauncher` remains.
- **Ask #837 re-checked:** held uploads persist in `held_uploads` (`00006`) with a restart test and the column allowlist; the vouch migration moved to `00007`; Task 1 no longer touches recordings or the heartbeat, so wave 1 (Tasks 1, 2, 9) stays parallel with no shared file; the switch-change publish has one rule (`PublishSoon`, within `MaxDebounceWait`) in text and test.
- **Fable check (2026-10-31, target #1426)** against `origin/feature/go-hub` after Phase 1 landed: the live hub now wires the session-host socket (Task 3, it was getting the refusing port); the transient unit gets `PATH` through `--setenv` (Task 4); the fake relay is extended, not moved unchanged (Task 8), and the smoke's hub side no longer leans on the socket env; Phase 1 already ships peer credentials, the file identity store, relay-only link payloads and the hostname — Tasks 1, 3, 6, 7 keep those as guards and drop the duplicate code; `PayingWatch` asserts an optional account-state interface like the existing `admission`; `markFailed` keeps the class; Task 1's `DefaultSocket` grows an error; the `hub enable` failure test moves to Task 3; fixture shape and the notices step named. Owner decisions in ask #881 (see Resolved).
- **Dependency waves:** 1 — Tasks 1, 2, 9; 2 — Tasks 3, 4; 3 — Tasks 5, 6, 7; 4 — Task 8; then external — Task 10 (relay), Task 11, Task 12 (phone), Task 13 (relay deploy + phone).
