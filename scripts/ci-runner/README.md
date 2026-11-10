# Self-hosted CI on the owner's Mac

When the owner's Mac is online, the Go jobs, the linters, the Kit tests and
the checks run on it; when it is offline, CI runs on GitHub-hosted runners
exactly as before. Nothing else changes for contributors.

## How it works

- The `gate` job in `.github/workflows/ci.yml` runs `scripts/ci-pick-runner.sh`
  (tests: `scripts/tests/test-ci-pick-runner.sh`). It lists the repository's
  runners with the `RUNNER_STATUS_TOKEN` secret and outputs each job class's
  `runs-on`: `linux` and `macos` → `[self-hosted, wt-general]` while a
  `wt-general` runner is online, else `ubuntu-24.04` / `macos-26`.
- Some jobs always run in the cloud:
  - **Swift Test** and **Mobile App** (`macos-26`): they need a window
    server, and the runners have none (see *Why not Swift Test* below);
  - **Go Test (race 1..3/3)** (`ubuntu-24.04`, nightly on main and on
    `workflow_dispatch` only): three race shards beside the other jobs and
    the owner's own work oversubscribed the Mac, and timing-bound tests
    failed;
  - the Dedupe gate, Go Build (Linux) and Prune SPM build cache (ubuntu).
- The Mac is picked only for a push, a `workflow_dispatch`, or a pull request
  whose branch lives in this repository. A fork PR, a missing secret, an API
  error or a timeout keeps everything in the cloud.
- On the Mac the jobs run as a separate standard macOS user, `ci`, so a
  branch's code cannot reach the owner's Keychain, `~/.config/watchtower` or
  the live database. Six runners (`actions-runner-general-1..6` in `ci`'s
  home, named `wt-mac-general-N`, label `wt-general`), each a LaunchAgent in
  `ci`'s GUI session: one run's Mac jobs fit at once, and a second run
  queues instead of piling onto the cores.
- Where a job differs on the Mac it checks `runner.environment`: no
  `apt-get`, no `setup-xcode` (the runners' `.env` sets `DEVELOPER_DIR`),
  no setup-go / golangci-lint caches (the `ci` user's own caches persist),
  Go Lint's timeout is 10 minutes instead of 5, and Go Test runs with
  `GOMAXPROCS=8` (half the cores; `go test -p` follows it), leaving the rest
  to the jobs beside it and to the owner.

## Why not Swift Test

Measured on 2026-11-10 (runs 42908094668 and two probe runs): a process the
runners start has no window server connection — `CGSessionCopyCurrentDictionary`
returns nothing, a new `NSWindow` gets window number 0, so an `NSEvent` made
for it has no window, and no window becomes key. Swift Test's mouse and
keyboard tests (`OwnerAskKeysTests`, `SessionsPanelKeyViewTests`,
`WorkbenchBackSwipeTests`) fail on their first assertion, and a simulator
stays at "Waiting on System App" for ten minutes with the CPU idle. The
runners run while `ci` is switched out (Fast User Switching) and were
started by the setup script's `launchctl bootstrap`; which of the two cuts
them off is not settled. If a later setup gives them a window server, the
probe is: build a window, post a mouse event with its `windowNumber`, and
check `event.window` is that window.

## One-time setup (owner)

1. **Close your home folder to other users** (the setup script refuses to go
   on otherwise):

   ```sh
   chmod 700 "$HOME"
   ```

2. **Create the runners** (asks for your sudo password and, the first time,
   a password for the new `ci` user):

   ```sh
   scripts/ci-runner/setup-mac-runner.sh
   ```

   It creates the standard user `ci`, installs swiftlint with Homebrew if it
   is missing, accepts the Xcode license (`/Applications/Xcode.app`; another
   one with `--xcode <path>`), downloads actions/runner (pinned version,
   checksum checked), registers the six runners and installs their
   LaunchAgents. Your own `xcode-select` choice is not touched: the runners
   use `DEVELOPER_DIR`. Running it again is safe; it restarts the runners and
   removes every other runner folder in `ci`'s home (`ci` is for these
   runners only; from earlier setups: `wt-swift`, `general-7`, `general-8`),
   so run it while no job is running.

3. **Log in as `ci` once and leave it logged in.** Turn on Fast User
   Switching (System Settings → Control Center → Fast User Switching), pick
   `ci` from the menu bar, log in, then switch back to your account — do not
   log out of `ci`. The runners start at that login. After a reboot they stay
   offline (CI goes to the cloud) until `ci` logs in again.

4. **Keep the Mac awake on power:**

   ```sh
   sudo pmset -c sleep 0
   ```

   A Mac that sleeps between the gate's pick and the job's start leaves the
   job queued (GitHub drops it after 24 h): wake the Mac, or cancel and
   re-run the workflow, which picks again.

5. **Create the token the picker reads.** A fine-grained personal access
   token: resource owner `aiwatchtowers`, repository access *Only select
   repositories* → `watchtower`, repository permission **Administration:
   Read-only** (GITHUB_TOKEN cannot list runners). If the organization
   requires approval for fine-grained tokens, approve it under the
   organization's Settings → Personal access tokens. Then:

   ```sh
   gh secret set RUNNER_STATUS_TOKEN --repo aiwatchtowers/watchtower
   ```

   (paste the token when asked). Without the secret, CI stays in the cloud.
   When the token expires, the picker falls back to the cloud: renew it and
   set the secret again.

6. **Fork PRs wait for approval.** The picker never sends a fork PR to the
   Mac, but a fork PR could edit `ci.yml` to ask for `self-hosted` directly.
   The setup script (step 2) therefore requires approval before any outside
   contributor's workflow runs (the repository default only asks for
   first-time contributors), and stops if it cannot. By hand:

   ```sh
   gh api -X PUT repos/aiwatchtowers/watchtower/actions/permissions/fork-pr-contributor-approval \
     -f approval_policy=all_external_contributors
   ```

   (or Settings → Actions → General → *Approval for running fork pull
   request workflows from contributors* → *Require approval for all external
   contributors*). Read a fork PR's workflow changes before approving it.

7. **Check:** Settings → Actions → Runners lists `wt-mac-general-1..6` as
   Idle. Push a branch: the gate's *pick* step logs
   `runs-on: linux=["self-hosted","wt-general"] …`.

## Day to day

- **Stop using the Mac for CI:** log out of `ci` (or shut the Mac down);
  runs go to the cloud from the next push. To remove the runners:
  `scripts/ci-runner/setup-mac-runner.sh --uninstall` (the `ci` user stays;
  `sudo sysadminctl -deleteUser ci` removes it and its caches).
- **Disk:** `ci` keeps the Go build cache, golangci-lint's cache and the Kit's
  SwiftPM build in its home. To reclaim space, delete `~ci/Library/Caches` as
  root while no job runs; the next run rebuilds. An earlier setup's Swift Test
  `.build` (~11 GB) and phone DerivedData go with the setup script's removal
  of the wt-swift runner and with `~ci/Library/Developer/Xcode/DerivedData`.
- **Logs:** each runner logs to
  `~ci/Library/Logs/actions.runner.aiwatchtowers-watchtower.wt-mac-<name>/`
  and to `_diag/` inside its folder.
- **Xcode:** the Mac runs whatever Xcode `--xcode` points at (the setup
  script prints its version); the cloud runs Xcode 26.4.1. Keep them on the
  same Swift version, or a Mac-only failure may be a toolchain difference.

## Known trade-offs

- **Little Linux CI while the Mac is online.** The `linux` class runs on
  macOS then; only **Go Build (Linux)** stays on ubuntu (`go build` + `go
  vet` with OpenSSL), so a Linux build break still shows on the PR, but the
  Go tests run on Linux only in the release workflow. To test a branch on
  Linux, take the Mac offline (log out of `ci`) and re-run.
- **The critical path stays in the cloud.** Swift Test (~8–12 min on
  `macos-26`) is the longest job, so the Mac shortens the Go side of a run,
  not its total.
- **One home for every job.** Jobs share `ci`'s home and run six at a
  time, so a test that writes to the real home (rather than a temp folder)
  sees what other jobs and earlier runs left there.
- **No spill-over.** A class goes to the Mac whenever one of its runners is
  online, busy or not; concurrent runs queue for the six runners rather
  than overflow to the cloud.
