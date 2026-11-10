# Onboarding — explicit AI agent choice and the no-agent path

Target: #1521. Mockups: [`docs/design/mockups/onboarding-agent/`](../../design/mockups/onboarding-agent/README.md).

## Problem

The Goals step picks the AI provider silently (`OnboardingCLIProbe`):

- `ai test` runs with no provider, which means Claude Code. Codex is tried only when the provider is unset, the config reads and **no Claude Code binary exists**. Then the check itself writes `ai.provider = codex` and `workbench.default_agent = codex`.
- With both CLIs installed, Claude always wins. The owner can't pick Codex here.
- If Claude Code is installed but signed out and Codex works, the step stops on "Claude Code or Codex CLI is required". The fallback runs only when Claude is missing, not when it fails.
- With no CLI at all, the owner gets an orange box with two `npm` commands. Most managers have no npm. The goal cards fold into chips to make room.

## Design

The footer status line and the orange box are replaced by an **AI agent** section under Assistant language. It has the same card language as the rest of the step.

```
✦ AI agent
  Chat, briefings and Workbench run on it. You can change it later in Settings → AI.
  ┌ ◉ Claude Code ─────────┐ ┌ ○ Codex CLI ──────────┐
  │ ● Ready · signed in    │ │ ● Ready · signed in    │
  └────────────────────────┘ └────────────────────────┘
  [setup panel — only while the picked agent is not ready]
```

### Per-agent status

Each tile shows one status, computed per agent:

| Status | How it is known | Tile line | Tone |
|---|---|---|---|
| `checking` | the check is running | Checking… (spinner) | neutral |
| `notInstalled` | Go's own lookup (`claude.FindBinary(claude_path)` / `codex.FindBinary(codex_path)`, asked through the read-only `watchtower ai which --json`) finds no executable. Known locally, **no request**. The same located executable is the one the test (`--cli-path`), the help probe and the sign-in/update terminal run, so Swift and Go never pick different copies | Not installed | neutral |
| `ready` | `ai test --json --provider <agent>` answered | Ready · signed in | success |
| `signedOut` | the test failed with `error_code: auth` | Installed · not signed in | warning |
| `failed(msg)` | any other failed test; `msg` is `OnboardingAgentChoice.failureMessage(agent, code, error)` (below) | Check failed | error |
| `forbidden` | `AllowedAIProviders` leaves it out: the Swift read (`ManagedPolicy.providerAllowed`, no test runs) **or** the test's own `error_code: policy` (Go's `providers.Allowed`), so a disagreement between the two readers still reads as the policy | Turned off by your organization | neutral, tile disabled |

**Failed line.** `ai test --json` reports a bare category (`Provider request failed (…).`), so the line is chosen by `error_code`:

| `error_code` | Line |
|---|---|
| `transport`, `timeout` | Couldn't reach Claude Code's service. Check the network or VPN, then check again. |
| `invalid_output` | always "Claude Code answered but ignored Watchtower's instructions. Update it and check again." (Go's message for this code names Codex even for Claude, so it is never shown) |
| anything else | Claude Code didn't answer (`<error>`). Run it once in Terminal to see what it says, then check again. |

Installed agents are tested **in parallel**: one short request per installed agent, the same `ai test` the step already sends. Today's worst case already sends two (Claude, then the Codex fallback) one after the other. Running them in parallel caps the wait at one test's timeout, and the owner sees both statuses before choosing. A missing or forbidden agent costs nothing.

### Which tile is selected

`OnboardingAgentChoice.applyDefault`, applied when a check finishes:

1. the configured `ai.provider`, if it is `claude`/`codex` and allowed (a rerun keeps the owner's agent, even when it's not ready: the owner sees its setup, not a silent switch);
2. else the first `ready` in the order Claude, Codex;
3. else the first installed (`signedOut`/`failed`);
4. else the first allowed (Claude).

A tap on a tile is the owner's pick. Later checks never move it.

### Setup panel

The setup panel shows only while the picked agent is not ready.

- **Not installed:** "Install Claude Code" with 1. the installer and 2. the sign-in command, each with a copy button. The installers need no Node.js:
  - Claude Code: `curl -fsSL https://claude.ai/install.sh | bash` (the official native installer), sign in with `claude auth login`;
  - Codex CLI: `curl -fsSL https://chatgpt.com/codex/install.sh | sh` (README of `openai/codex`), sign in with `codex login`.
  - On a Mac where piping a script into the shell is not allowed, the **Other ways to install** link opens the vendor's install page (Homebrew, npm and the rest): `code.claude.com/docs/en/setup`, `github.com/openai/codex`.
- **Signed out:** see "Sign in right here" below.
- **Failed:** "Claude Code didn't answer" and the Failed line.
- Buttons: **Check again** (`kitSecondary`) and, for not installed or failed, **Choose the executable…**. The second opens an `NSOpenPanel` and saves the picked agent's `claude_path`/`codex_path`, as today's manual-path row does for Claude. A line under them says: "Watchtower checks again when you come back to this window." (`NSApplication.didBecomeActiveNotification` while the step is up and the picked agent is not ready; no polling).

### Sign in right here (owner, ask #1157)

When the picked agent is signed out, the panel runs its sign-in in an embedded terminal, **opened by itself** the first time that agent shows as signed out:

- The command is the CLI's own login, which exits when it is done: `claude auth login` (Claude Code 2.1+) or `codex login`. It opens the browser. The terminal shows the CLI's prompts and the fallback URL.
- Above the terminal: "Your browser opens to sign in. When it's done, this closes and Watchtower checks again." Under it: **Stop**.
- Exit 0 means the terminal closes and the agents are checked again: the tile turns Ready and Continue unlocks. A non-zero exit or Stop closes it, and the note becomes "Sign-in stopped before it finished (exit code N)." in `Tone.warning`, with **Sign in again**. A stopped sign-in never reopens by itself (`signInOpened`).
- Under it as a fallback: "Or run it in your own Terminal:" and the command with a copy button.
- Picking the other tile stops a running sign-in.
- **A CLI too old for the login command.** `claude auth login` arrived in Claude Code 2.1. Before the terminal opens, a local probe with no request and no network runs `claude auth --help` (or `codex login --help`). A probe that times out (5 s) counts as outdated: the update runs, and if nothing changes the panel stops in the stuck state below, so a hung CLI never goes straight to a login that can't work. The decision comes from the **help text, not the exit code** (owner, ask #1163): an old CLI may print its general help and exit 0. Claude counts as supporting login only if the command list has a `login` row; Codex only if the text has `Usage: codex login` (`Agent.loginSupported(help:)`, tested on the real 2.1 output and on a general help). A CLI without it is `outdated`. The title becomes "Update Claude Code to sign in" and the note "This Claude Code is too old to sign in from here. It updates first; sign-in starts right after.".
- **The update fits how the CLI was installed** (owner, ask #1163). The resolved executable, with symlinks followed, gives the `InstallKind`:

  | Path contains | Kind | Claude Code | Codex CLI |
  |---|---|---|---|
  | `~/.claude/local/` (Claude Code's old local install; checked first) | native | `claude update` | — |
  | `~/.codex/packages/standalone/` (Codex's `install.sh` links `~/.local/bin/codex` to `…/standalone/current/bin/codex`, checked against the script on 2026-11-10; a plain file in `~/.local/bin` is unknown) | native | — | the install script |
  | `/node_modules/` (any other) | npm | `npm install -g @anthropic-ai/claude-code@latest` | `npm install -g @openai/codex@latest` |
  | `/Caskroom/` or `/Cellar/` | Homebrew | `brew upgrade --cask claude-code` | `brew upgrade --cask codex` |
  | `~/.local/share/claude/` (Claude) | native | `claude update` | — |
  | anything else | unknown | — | — |

  So an update never installs a second copy somewhere else. The old local install keeps npm's folder under `~/.claude/local/node_modules`, but it is not a global npm install: it gets `claude update`, never `npm install -g`.
- **The update itself fails** (non-zero exit, or Stop). The note reads "Update stopped before it finished (exit code N)." (or "Update stopped before it finished." after Stop) in `Tone.warning`, and the button is **Update again**. The owner presses it to rerun the same update; nothing reruns by itself, so a failing update can't loop. The Terminal fallback shows the same update command. An update that exits 0 without fixing anything goes to the stuck state below. The Codex row was read from the live `install.sh` (`BIN_DIR=$HOME/.local/bin`, `STANDALONE_ROOT=$CODEX_HOME/packages/standalone`); a custom `CODEX_HOME` reads as unknown (no command, the owner updates it their way).
- **No update loop.** After an update exits 0, the probe runs again. If the login is there, the sign-in opens by itself. If the CLI is still outdated (another copy comes first on PATH), or the kind is unknown, the panel stops offering an update (`updateStuck`): no terminal and no **Update again**. It shows the warning "Updating didn't change the Claude Code Watchtower uses (`<path>`). It may be installed twice. Update that copy the way you installed it, or choose another executable." (unknown kind: "Watchtower can't tell how this Claude Code was installed (`<path>`). Update it the way you installed it, then check again."), with **Choose the executable…**, **Other ways to install** and **Check again**.
- The terminal is SwiftTerm's `LocalProcessTerminalView` (as in the Workbench), started in the login-shell environment (`Constants.resolvedEnvironmentAsync`) with the agent's resolved executable. It is not a Workbench session: no session host, nothing stored, about ten rows (`OnboardingAgentSection.terminalHeight`).

### No agent at all

The section caption becomes "Watchtower needs Claude Code or Codex CLI on this Mac. Pick one, install it and sign in — it takes a couple of minutes." Claude is preselected, and the setup panel shows its install steps. Picking Codex switches the steps. The goal cards **stay cards**: no chips. Continue is disabled with "Continue unlocks once Claude Code is ready". See the open question in Decisions.

### Provider set elsewhere

If the configured provider is neither claude nor codex (Ollama set in Settings; owner, ask #1157: Ollama stays in Settings), the section shows one line, "Watchtower runs on Ollama, set in Settings → AI.". There are no tiles; the check is the existing `ai test` with no provider. If it answers, Continue is enabled.

If that test fails, the tiles come back (and the two agents are checked) under the caption "Ollama, set in Settings → AI, didn't answer: `<line>` Pick Claude Code or Codex CLI instead, or fix it in Settings and check again.". Picking a ready agent and pressing Continue writes it over `ai.provider`. Check again retests Ollama too.

### Continue

Continue is enabled only when the picked agent is `ready` (or the provider is set elsewhere and its test answered). On Continue, when the pick differs from the configured `ai.provider` (an unset provider counts as different, so the choice is explicit from now on):

1. `config set workbench.default_agent <agent>` (skipped when equal);
2. `config set ai.provider <agent>` (last, so a failure leaves it unchanged);
3. then today's Continue (workspace init, language, features).

**The check never writes.** Today's Codex fallback writes during the check; that moves to Continue.

### Other copy

The Development goal's pitch names the picked agent: "Codex CLI works your folder's board. No connections needed". While nothing is picked, it says "Your AI agent …".

### Components

- `WatchtowerCore/Services/OnboardingAgentChoice.swift`: pure state and **every line of copy** above. Tests: `Tests/Core/OnboardingAgentChoiceTests.swift` (31 tests: default selection, pick, policy, Continue, save, sign-in terminal, failure lines, all copy).
- `Views/Onboarding/OnboardingAgentSection.swift`: tiles plus the setup panel (`card(selected:)`, `Fill`, `Tone.success/warning/error`, `kitSecondary`/`kitQuiet`, no dividers); `OnboardingCommandLine` (the copyable command).
- `OnboardingGoalCards` and `OnboardingGoalsFooter` are extracted from `OnboardingGoalsStepView`, so the mockups render the step's own parts.
- `OnboardingCLIProbe` is replaced by a per-agent check that returns `[Agent: Status]`. `OnboardingGoalsModel` keeps an `OnboardingAgentChoice` in place of `OnboardingCLICheck`. `onProviderSwitched` fires after the Continue write instead of after the check.
- `OnboardingSignInTerminal` (Views/Onboarding): the PTY host for the sign-in. It reports start/exit to the model; quitting, leaving the step or picking the other tile sends SIGTERM to its process group.
- Mockups: `OnboardingAgentShotFixtures` in `DesignShotCatalog`, 19 scenes × light/dark (the sign-in terminal as a still).

### Docs updated in the same PR

- `docs/onboarding-flow.md`: the Goals box ("Continue blocked until `watchtower ai test` passes … `OnboardingCLIProbe`") is rewritten for the per-agent check, the pick and the write at Continue.
- `docs/features/onboarding-v2.md`: the CLI check paragraph.
- Guide: `docs/guide/start/setup.md` (the first step) and `docs/guide/troubleshooting/ai-tool-not-found-or-not-signed-in.md` (the curl installers, signing in from the step).

## Failures

| Path | What happens | Test |
|---|---|---|
| A test hangs or the host closes mid-check | each agent's test has the CLI's own timeout → `failed(timeout msg)`; the other agent's result still shows; a newer check (Check again, reactivation) supersedes the old one by generation, as `runCLICheck` does today | model: stale generation ignored; choice: `failed` setup copy |
| App quits or crashes mid-check | nothing was written (the check never writes); the next launch resumes the Goals step and checks again | model: check performs no `config set` |
| `default_agent` write succeeds, `ai.provider` fails | stays on the step, footer shows "Couldn't save the AI agent." and the error; `ai.provider` unchanged; Continue retries both (the first is skipped when equal) | model: second write fails → error, no route |
| Owner installs while on the step | coming back to the window rechecks; Check again does it by hand | model: reactivation triggers a check only when the pick is not ready |
| Installer put the binary outside the usual places | Not installed stays; **Choose the executable…** saves the path and rechecks | model: path save → recheck |
| Policy forbids both | both tiles disabled, no tests, Continue disabled with "Continue unlocks once an AI agent is ready" | choice: no selection, hint |
| Both tests time out | both tiles Check failed with the network line; one Check again retests both; Continue disabled | choice: failure lines; model: parallel check returns both |
| The sign-in terminal can't start (no PTY, exec error) | treated as an ended sign-in: warning note, Sign in again, the Terminal fallback command | terminal: start failure reports `ended` |
| Run setup again with a working agent | the configured agent is preselected and Ready; Continue writes nothing for it | choice: `providerToSave` returns nil |
| Swift and Go policy readers disagree | `error_code: policy` from the test maps to `forbidden` too | check mapping test |
| Sign-in terminal: host closes or the app quits mid-login | SIGTERM to the process group (as `CodeCLIProcess` groups are reaped); the CLI's own credential store is its business; the next check reports what is true | terminal: process group gone after stop |
| Sign-in exits 0 but the test still fails | the tile shows the real status (signed out again → the terminal does not reopen by itself; Sign in again is there) | choice: `signInOpened` keeps it closed |
| CLI too old for `auth login` (general help, exit 0 included) | the help text decides `outdated`; the terminal runs the update for its install kind, then the sign-in | choice: `testLoginSupportReadsTheHelpText`, `testOutdatedCLIUpdatesThenSignsIn` |
| The update fails (non-zero exit or Stop) | "Update stopped before it finished (exit code N).", **Update again** (owner-pressed only), the update command for Terminal | choice: `testOutdatedCLIUpdatesThenSignsIn` (exit 1 → Update again); M `signed-out-update-failed` |
| Old local Claude install (`~/.claude/local`) | `claude update`, not a global npm install | choice: `testInstallKindFromTheResolvedPath` |
| Update succeeds but another copy still wins on PATH | the probe still finds no login → `updateStuck`: no terminal, no Update again, the path named, Choose the executable | choice: `testUpdateThatChangedNothingNeverLoops` |
| Install kind unknown | no update command offered; the path named, update it the owner's way | choice: `testUnknownInstallOffersNoUpdateCommand` |
| Sign-in can't start (executable vanished) | note "Sign-in stopped before it finished." plus the Terminal fallback command | choice: ended copy |

## Acceptance

Each promise above, checked by a test (T), a mockup (M) or by hand on a real Mac (H):

1. Both CLIs ready → both tiles Ready, Claude preselected, a tap picks Codex, Continue writes `ai.provider=codex` and `workbench.default_agent=codex` (T, M `both-ready`, `both-ready-codex`).
2. Only one CLI installed → that one is preselected; the other shows Not installed and costs no request (T, M `only-codex`).
3. No CLI → the "needs" caption, install steps for the picked tile with copy buttons and Other ways to install, Continue disabled with its hint, goal cards stay cards (T, M `none`, `none-codex`, `none-narrow`).
4. Coming back to the window rechecks; Check again rechecks (H: install Claude with the step open, switch back, the tile turns Signed out or Ready without a click).
5. Signed out → the sign-in terminal opens by itself once, runs `claude auth login`/`codex login`; exit 0 → recheck, Ready, Continue unlocks; Stop/non-zero → warning, Sign in again; never reopens by itself (T, M `signed-out`, `signed-out-stopped`; H on a signed-out install).
6. Old CLI → help text marks it outdated; the update for its install kind runs first, then the sign-in; a failed update says "Update stopped…" and offers Update again; an update that changed nothing stops with the path named; the install kind is read from the resolved path, including Codex's `~/.codex/packages/standalone/` (T `testInstallKindFromTheResolvedPath`, M `signed-out-outdated`, `signed-out-update-failed`, `signed-out-update-stuck`; H: after `install.sh`, `realpath ~/.local/bin/codex` starts with `~/.codex/packages/standalone/`, the path the rule reads as native).
7. Failed check → the Failed line by `error_code` (T, M `failed`).
8. Policy → a forbidden tile is disabled; both forbidden → no selection, Continue disabled (T, M `policy`, `policy-both`).
9. Ollama set in Settings → one line; its failure brings the tiles back (T, M `other-provider`, `other-provider-failed`).
10. The check never writes config; Continue writes only a changed pick; a failed write keeps the step with "Couldn't save the AI agent." (T, M `save-error`, `continuing`).
11. The Development card names the picked agent (T, M every scene).
12. After implementation, `make desktop-shots` of the real step matches these mockups (H, the workbench rule).
13. Docs and guide pages listed above are updated in the same PR (review).

## Writers of `ai.provider` / `workbench.default_agent`

- **Onboarding Continue** (this design): writes only when the pick differs, through `watchtower config set`.
- **Settings → System → AI**: Save writes the provider form.
- **CLI** `watchtower config set` (owner or an agent).
- The daemon and the phone never write them.

Onboarding writing only at Continue is the owner's decision (ask #1157). Every writer goes through `config set` (an atomic file replace). The last write wins. Onboarding writes once, at Continue, from the owner's pick at that moment, so a Settings change made in another window before Continue is overwritten by the pick. That is acceptable: the owner just chose on screen. Removing the check-time write removes today's race, where a background check could overwrite a provider the owner had just saved in Settings.

## Out of scope

- Ollama or an API key as an onboarding option: stays in Settings → AI (owner, ask #1157).
- Continuing without an AI agent (owner, ask #1157: blocked until one is ready).
- Changing Settings → AI.

## Decisions

- Explicit Claude Code / Codex choice on the Goals step, with handling for "no agent installed": owner (conversation, 2026-11-10).
- Status per agent, both installed agents tested in parallel, policy respected: agent decided.
- Default selection order (configured → ready → installed → Claude); a tap is sticky: agent decided.
- The provider is written only at Continue; the check never writes: owner, ask #1157.
- Installers via `curl` (no Node.js), npm dropped from the panel, **Other ways to install** link for Macs that forbid it: agent decided.
- Signed out → the sign-in terminal opens right in the step: owner, ask #1157 (note). Auto-open once, `claude auth login`/`codex login`, recheck on exit 0: agent decided.
- Ollama failing its check brings the tiles back; only the owner's pick plus Continue replaces `ai.provider`, Check again keeps Ollama: agent decided (shown to the owner in this review).
- One binary for every path: Go's lookup through `ai which`, the terminal runs that path (plan review, ask #1176): agent decided.
- Per-agent setup data (install, sign-in, update, docs, path key, help probe, native roots) lives in each harness's Swift session adapter (`AgentSetup`), not in onboarding switches; the other provider's name is `AIModelCatalog.fallbackDisplayName` ("Ollama / Local"): owner, ask #1211 (LLMTRANSPORT-01, no baseline entries).
- A help probe timeout counts as outdated (plan review, ask #1176): agent decided.
- An outdated CLI updates in the same terminal before signing in: agent decided. Detected from the help text and updated the way it was installed, no update loop: owner, ask #1163.
- Failed line chosen by `error_code`: agent decided.
- Goal cards stay cards in the no-agent case (no chips): agent decided.
- Recheck when the window becomes active: agent decided.
- No agent: Continue stays blocked until one is ready; no "continue without AI": owner, ask #1157.
- Ollama only in Settings → AI, not a tile: owner, ask #1157.
