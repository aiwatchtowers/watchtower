# Workbench sessions survive an app restart — design

**Board:** #496. **Status:** draft for owner review. **Date:** 2026-10-17.

## 1. Why

Updating Watchtower kills every workbench terminal session. The terminal is a
SwiftTerm `LocalProcessTerminalView` inside the app process
(`SwiftTermSession`, `WatchtowerDesktop/Sources/Services/TerminalCenter.swift`),
so `claude`/`codex` is the app's grandchild; on quit `QuitCoordinator` calls
`TerminalCenter.closeAll()`, which sends SIGHUP to each session's process group
and SIGKILL after 3 s. Everything in the group dies: the agent mid-turn, its
subagents and workflows, its MCP servers, background shells, dev servers,
long builds and test runs.

The next launch can `claude --resume <uuid>`, but that only restores the
conversation. The owner named exactly what hurts (ask #246):

- an agent's turn cut off mid-work (it sits waiting and has to be poked),
- subagents and workflows dying with their results,
- background processes (dev servers, builds, tests) dying.

The trigger that matters is **a Watchtower update** (ask #246). A Mac reboot is
out of scope.

## 2. Goals, non-goals, anti-goals

**Goals**
- An update (and an app crash) leaves every running session's process tree
  untouched: the agent keeps working through the restart, subagents and
  background processes keep running.
- After the app comes back, each session's pane shows its live terminal again
  — the current screen restored, input working — without the owner doing
  anything.
- Everything the app does with a session today keeps working on a reattached
  one: owner input, ask answers and comment hand-offs (`sendInput`,
  bracketed-paste detection), the prompt-draft tracking, ⌘-click path links,
  `ask #N` links, exit detection, agent state, mobile input.
- A normal quit (⌘Q, tray Quit) with live sessions asks the owner (ask #247):
  **Keep Running** or **Stop Sessions**. An update never asks: it always keeps
  them.

**Non-goals**
- Surviving a Mac reboot or logout. (The existing `--resume` relaunch stays the
  path there.)
- Remote / multi-machine sessions.
- Full scrollback preservation beyond a bounded buffer (the owner did not pick
  scrollback as a pain, ask #246).

**Anti-goals** (failure even if it technically works)
- The terminal stops feeling native: SwiftTerm's own scrollback, selection,
  copy, mouse, ⌘-click links lost to a multiplexer's copy mode. This rules out
  running sessions inside tmux/screen.
- Orphans: a session the owner deleted or stopped keeps a process alive; a host
  with no sessions lingers forever.
- A silent kill: an update that cannot keep a session (e.g. an incompatible
  host) kills it without saying so.

## 3. Decided (owner)

- Trigger to cover: Watchtower updates (ask #246).
- What must survive: the agent's turn, subagents/workflows, background
  processes (ask #246).
- Quit behaviour (ask #247): an update keeps sessions without asking; a normal
  quit with at least one live session asks **Keep Running / Stop Sessions**;
  with none it quits as today.

## 4. Design (builder's calls unless marked)

### 4.1 Session host

A small long-lived process, `watchtower session-host` (a subcommand of the Go
CLI binary in the CLI binary store), owns the PTYs. **My call:** Go, because
the CLI binary is already shipped and updated by the app, and `forkpty` +
a unix socket is a single small package (`internal/sessionhost`).

- One host per user (not per workspace), socket at
  `~/Library/Application Support/Watchtower/session-host.sock`, mode 0600, with
  a pid/lock file beside it. The app starts it on demand (first session
  launch, or at launch when sessions are recorded as hosted) fully detached
  (`setsid`, stdio to a log file), so it is not in the app's process group and
  survives the app's exit.
- The host spawns each session exactly as `TerminalLaunch.make` describes it
  today (executable, args, environment, cwd, `TERM=xterm-256color`), in its own
  session/process group, so the existing SIGHUP→SIGKILL stop semantics apply to
  the same group as now.
- Per session the host keeps: the PTY master, the child pid, the window size,
  the exit status once it exits, and a ring buffer of the last output bytes
  (**my call:** 2 MB per session — enough for Claude Code to redraw, bounded
  memory with many sessions).
- Keyed by `terminal_sessions.id` plus a per-launch run token, so a stale
  attach never lands on a newer run.
- The host exits on its own when it holds no sessions and no client has been
  attached for a grace period (**my call:** 60 s).

### 4.2 Protocol

Length-prefixed frames over the unix socket; first frame is a hello carrying a
protocol version. Operations: `launch`, `attach` (replays the ring buffer, then
streams live output), `input`, `resize`, `signal` (HUP/KILL to the group),
`list` (sessions with pid, run token, running/exited + code), `forget` (drop an
exited session's record). Output and exit events are pushed to attached
clients. One client at a time per session is enough (the app is single
instance).

**Versioning (my call, kept simple):** the hello carries the host's protocol
version, and the protocol only grows additively — a newer app always speaks
every older host's operations, so it attaches to a host started by the app it
replaced. A host is never killed to upgrade it: the CLI binary store replaces
`bin/watchtower` by an atomic rename, so a running host keeps its old code,
and the next host (after the idle exit) starts from the new binary. If the app
cannot talk to a host at all, it says so on each affected session's pane and
offers the existing Restart (resume) — never a silent kill.

**Binary and environment across an update (checked):** a surviving session
keeps the environment it was launched with. Its hooks and MCP server call the
store path `~/Library/Application Support/Watchtower/bin/watchtower`, which is
stable across updates, so after an update they run the new CLI. That is the
same situation as today for an owner's own terminal running `claude` across an
update; hook and MCP command lines stay backward compatible as they already
must.

**Which host (my call):** one host per app bundle id — the socket and lock
names carry it — so a dev or corp build never attaches to the release build's
sessions. A row whose session lives in another build's host reads as stopped
in this build.

### 4.3 App side

- A second `TerminalSessionProcess` implementation, `HostedTerminalSession`:
  a SwiftTerm `TerminalView` (not `LocalProcessTerminalView`) fed by the host's
  byte stream and sending its input/resize back. SwiftTerm still parses every
  byte locally, so `bracketedPasteMode`, path/ask links, owner input and focus
  hooks, palette and scrollback behave as now.
- `TerminalCenter` launches through the host; `close` sends `signal` HUP, then
  KILL after the same `killGrace`, through the host. `pid` is the host-reported
  child pid (still a real pid of the same user, so `kill(pid, 0)` and the
  session-probe keep working).
- **Reattach at launch:** after `initWorkbenches`, the app asks the host for
  `list` and, for every listed running session whose row still exists,
  registers a `HostedTerminalSession` in `.running` state and attaches —
  without going through `activate`'s launch path (no `--resume`, no new
  process). `startedAt` comes from the host so agent-state staleness stays
  right. A listed session whose row was deleted while the app was away is
  stopped. A listed exited session is reported through the normal `onExit`
  path once, then forgotten. That path does what a natural exit does today,
  including the automatic worktree cleanup with its fail-closed safety
  catches (**my call:** an exit while the app was away is still a natural
  exit).
- **Screen restore (my call):** the replay is approximate by design. The app
  resets the fresh `TerminalView`, replays the buffer (the host cuts it at a
  safe point — not inside an escape sequence — and prefixes the alternate
  screen switch when the session is in it), sends the pane's current size,
  and the host nudges the child with SIGWINCH so Claude Code / Codex redraw
  the screen completely. Until that redraw a few lines may look off; no
  headless emulator in the host.
- Mobile input queued while the app was away is delivered after reattach
  under the relay's existing expiry rules, as it is today after any app
  downtime.
- Today's direct `LocalProcessTerminalView` path stays as the fallback when
  the host cannot start; a session started that way behaves as today (dies on
  quit). The pane says it is not protected.

### 4.4 Quit and update

- `UpdateService.relaunch()` marks the quit as an update; `QuitCoordinator`
  then skips `closeTerminals` and only detaches (closes the socket).
- A normal quit with live hosted sessions shows the **Keep Running / Stop
  Sessions** prompt. **My call:** one alert with the existing quit prompt
  (recording, ask drafts) — its text lists what is live, its buttons are
  **Keep Sessions and Quit**, **Stop Sessions and Quit** and **Cancel**. Keep
  detaches; Stop runs today's `closeAll` through the host. Only hosted
  sessions count; with none it quits as today.
- Logout and shutdown never prompt: the system ends the host and its sessions
  with the login session, as it ends everything else.
- Keep means keep: a kept session runs until its agent exits or the owner
  stops it, even if the app is never opened again (**my call:** an idle agent
  at its prompt costs nothing; the host itself exits once no session is left).
- An app crash leaves the host and sessions running; the next launch
  reattaches.
- While the app is closed nothing in the app watches the sessions: hooks still
  write agent state and asks to the database (they do not need the app), but
  there are no macOS notices and the phone sees no updates until the app is
  back (**my call:** acceptable for v1, the gap is minutes in the update case).

### 4.5 What else to keep straight

- Deleting a session, deleting a workbench, Clean Up and worktree cleanup stop
  the session through the host as they do today.
- Tests never start a real host: the host client sits behind a seam like
  `ProcessGroupSignaller`; Go tests of `internal/sessionhost` spawn their own
  host in a temp dir and reap its process group in `t.Cleanup`.
- `docs/features/workbench.md`, PROJ-11 (session states) and the user guide's
  workbench page are updated; inventory entries touching the quit path and
  session lifecycle are read first and changed only with the owner's OK.

## 5. Left to the builder

Frame encoding, buffer data structure, exact socket/lock file names, the
host's log rotation, how `TerminalView` is subclassed to keep `PalettedTerminalView`'s
behaviour, how the compatibility path for an older host is shaped, and the
split into plan tasks.
