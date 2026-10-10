# Claude binary resolution — one ladder for every launch (2026-10-10)

## Problem

A new workbench session fails with `zsh:1: command not found: claude` (exit 127)
on a machine where Claude Code works fine in Terminal.

The embedded terminal starts a session as `$SHELL -l -c "exec claude …"`
(`TerminalLaunch.make`). A non-interactive login zsh reads `/etc/zprofile` and
`~/.zprofile` but **not** `~/.zshrc`. Claude Code's native installer puts the
binary in `~/.local/bin` and adds that directory to `PATH` in `~/.zshrc`, so
every owner who installed Claude Code the recommended way hits this. Their
onboarding still shows "Claude Code found": the onboarding check resolves the
binary through the well-known-directory ladder, the terminal does not.

The rest of the app already knows the trap:

- Go `claude.FindBinary` (`internal/claude/resolve.go`): `claude_path`
  override → `exec.LookPath` → login-shell `which` → well-known dirs
  (`~/.local/bin`, `~/.claude/bin`, Homebrew, `/usr/local/bin`, Volta).
- Swift `Constants.findInPath` (`WatchtowerCore/Utilities/Constants.swift`):
  well-known dirs → nvm/fnm version dirs → resolved `PATH`.

Places that still depend on the login shell's `PATH` alone:

1. `TerminalLaunch.make` — bare `claude` in all three Claude modes.
2. `Constants.resolvedEnvironment()` — `PATH` from `$SHELL -lc 'echo $PATH'`,
   patched only with an nvm/fnm dir. 38 Desktop call sites launch CLI
   processes with it.
3. `cmd/integrate.go` — `exec.LookPath("claude")` + `exec.Command("claude", …)`
   in `registerMCPWithClaudeCode` and the `integrate remove` path.

## Goal

Every place Watchtower launches `claude` finds the same binary the onboarding
check found, whatever shell file the owner's `PATH` export lives in. No change
to the owner's shell files, no interactive (`-i`) shells.

## Design

### 1. One Swift resolver: `Constants.claudeBinary()`

`package nonisolated static func claudeBinary() -> String?` in `Constants`:

1. `claude_path` from `config.yaml`, when it names an executable file (the
   Swift twin of Go `FindBinary`'s override; read the same way `ConfigService`
   reads it, without needing the `ConfigService` instance).
2. Otherwise `findInPath("claude")`.
3. Otherwise `nil`.

Not cached: the owner may set `claude_path` or install Claude Code while the
app runs, and the lookups are a handful of `stat` calls (the resolved-PATH
step reuses the cached `resolvedEnvironment()`).

The onboarding CLI check, the terminal and `resolvedEnvironment` use it, so
"found" in onboarding means "launchable" everywhere. Dual path with Go
`claude.FindBinary`: same order of override → well-known dirs; a comment on
each names the other.

### 2. Terminal launch by absolute path

`TerminalLaunch.make` takes a new `claudeBinary: String?` parameter.
`TerminalCenter` passes `Constants.claudeBinary()`.

When it is non-nil, the launch environment gets
`WATCHTOWER_CLAUDE_BIN=<path>` (new `claudeBinaryEnv` constant) and every
Claude mode runs through `/bin/sh`, the same way `firstPromptEnv` already does:

```
exec /bin/sh -c 'export PATH="$(dirname "$WATCHTOWER_CLAUDE_BIN"):$PATH"; exec env -u WATCHTOWER_CLAUDE_BIN [-u WATCHTOWER_FIRST_PROMPT] "$WATCHTOWER_CLAUDE_BIN" --session-id <uuid> ["$WATCHTOWER_FIRST_PROMPT"]'
```

(`--resume <uuid>` for resume.) Properties:

- The path never reaches a shell parser as text: it travels in the
  environment and `/bin/sh` expands a double-quoted variable, so spaces,
  quotes and `$` in a path are safe, under any login shell (zsh, bash, fish,
  nushell, csh).
- The login shell still runs first, so auth, nvm/fnm init and everything
  else in the owner's profile stay theirs.
- The binary's directory is prepended to `PATH`, so a hook or subprocess
  that runs `claude` by name finds the same binary.
- `env -u` drops `WATCHTOWER_CLAUDE_BIN` before `claude` runs; the session
  row variable (`WATCHTOWER_TERMINAL_SESSION_ID`) stays as today.

When `claudeBinary` is nil, the command is exactly today's bare `claude`
form, and exit 127 shows the message from §3. `.shell` mode is unchanged.

### 3. Exit 127: let the owner fix it in place

`TerminalLaunch.exitMessage(code: 127)` reads: "Claude Code was not found.
Set its path, or add it to your login shell's PATH, then Restart."
`WorkbenchSessionView`'s exited bar shows a **Set Claude Path…** button for
code 127: an `NSOpenPanel` for the `claude` executable (same panel setup as
the onboarding manual-path row), `OnboardingClaudePathConfig.save` to write
`claude_path`, then the same action as **Restart**. An unexecutable pick or a
save error shows inline in the bar, as onboarding does.

The panel code is shared: extract the onboarding `NSOpenPanel` setup into one
helper both views call (one-line call each), rather than copying it.

### 4. `resolvedEnvironment()` gets the well-known dirs

After the login-shell `PATH` is read, append (not prepend — the owner's own
order wins) the existing well-known directories that are missing:
`~/.local/bin`, `~/.claude/bin`, `/opt/homebrew/bin`, `/usr/local/bin`,
`~/.volta/bin`, plus the directory of `claude_path` when set. The existing
nvm/fnm patch stays. This mirrors Go `RichPATH`/`fallbackPATH`. CLI processes
the Desktop launches (including `watchtower integrate …` and the Go side's
own `exec.LookPath`) then see `claude`.

`resolvedEnvironment` is cached once per launch; a `claude_path` set later
reaches the terminal through §2 (not cached) and the Go side through its own
`cfg.ClaudePath`.

### 5. Go `integrate` uses `claude.FindBinary`

`registerMCPWithClaudeCode` and the `integrate remove` unregister path take
the binary from `claude.FindBinary(cfg.ClaudePath)`. "Not found" becomes:
`FindBinary` returned the bare fallback `"claude"` and `exec.LookPath` on it
fails. The printed manual commands stay as they are.

## Out of scope

- `-i` login shells (prompt frameworks, slow start, tty side effects; the Go
  side already dropped `-i`, "L1 fix").
- Editing the owner's shell files.
- The onboarding install hint still shows the npm command; Claude Code's
  recommended install is now the native installer. Worth a separate small
  change, not part of this fix.

## Testing

Swift (`Tests/Core`, `make test-swift FILTER=…`):

- `TerminalLaunch.make` for `newClaude` with and without a prompt,
  `resumeClaude`, and `shell`, each with `claudeBinary` nil and set: the
  argv, that the binary path appears only in `environment` (never in
  `args`), and that `-u WATCHTOWER_CLAUDE_BIN` is present. A path with a
  space, a single quote and `$` runs through a real `/bin/sh` with a stub
  script and arrives intact (the stub prints its `$0` and args; the test
  reaps it).
- `exitMessage(code: 127)` text.
- `claudeBinary()`: override executable → override; override missing or not
  executable → falls through; none → `findInPath` result. The resolver takes
  its config path and home directory as parameters (defaulted) so tests use a
  temp dir.
- `resolvedEnvironment` PATH merge: extract the merge into a pure function
  (`mergeWellKnownDirs(path:home:claudePath:fileExists:)`) and test it —
  appends missing dirs, keeps order and existing entries, no duplicates.

Go (`go test ./cmd -run Integrate…`):

- `integrate claude-code` with `cfg.ClaudePath` pointing to a stub `claude`
  that is not on `PATH`: the stub receives `mcp add watchtower -- <bin> mcp`.
  Same for `integrate remove`. The stub process is reaped in `t.Cleanup`.

Manual check: on a machine whose `~/.local/bin` export lives only in
`~/.zshrc`, open a new workbench session from the Desktop app launched via
Finder — Claude Code starts.
