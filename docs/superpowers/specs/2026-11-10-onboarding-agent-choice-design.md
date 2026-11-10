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
| `notInstalled` | no executable at `claude_path`/`codex_path` or in the usual places (`Constants.findInPath`, which includes `~/.local/bin`). Known locally, **no request** | Not installed | neutral |
| `ready` | `ai test --json --provider <agent>` answered | Ready · signed in | success |
| `signedOut` | the test failed with `error_code: auth` | Installed · not signed in | warning |
| `failed(msg)` | any other failed test (transport, timeout, invalid output); `msg` is the CLI's sanitized error | Check failed | error |
| `forbidden` | `AllowedAIProviders` leaves it out (`ManagedPolicy.providerAllowed`); no test runs | Turned off by your organization | neutral, tile disabled |

Installed agents are tested **in parallel**. One short request per installed agent, the same `ai test` the step already sends today.

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
  - Claude Code: `curl -fsSL https://claude.ai/install.sh | bash` (the official native installer), sign in with `claude`;
  - Codex CLI: `curl -fsSL https://chatgpt.com/codex/install.sh | sh` (README of `openai/codex`), sign in with `codex login`.
- **Signed out:** "Sign in to Claude Code" and the sign-in command.
- **Failed:** "Claude Code didn't answer" and the CLI's message.
- Buttons: **Check again** (`kitSecondary`) and, for not installed or failed, **Choose the executable…**. The second opens an `NSOpenPanel` and saves the picked agent's `claude_path`/`codex_path`, as today's manual-path row does for Claude. A line under them says: "Watchtower checks again when you come back to this window." (`NSApplication.didBecomeActiveNotification` while the step is up and the picked agent is not ready; no polling).

### No agent at all

The section caption becomes "Watchtower needs Claude Code or Codex CLI on this Mac. Pick one, install it and sign in — it takes a couple of minutes." Claude is preselected, and the setup panel shows its install steps. Picking Codex switches the steps. The goal cards **stay cards**: no chips. Continue is disabled with "Continue unlocks once Claude Code is ready". See the open question in Decisions.

### Provider set elsewhere

If the configured provider is neither claude nor codex (Ollama set in Settings), the section shows one line, "Watchtower runs on Ollama, set in Settings → AI.". There are no tiles, the check is the existing `ai test` with no provider, and Continue follows it.

### Continue

Continue is enabled only when the picked agent is `ready` (or the provider is set elsewhere and its test answered). On Continue, when the pick differs from the configured `ai.provider` (an unset provider counts as different, so the choice is explicit from now on):

1. `config set workbench.default_agent <agent>` (skipped when equal);
2. `config set ai.provider <agent>` (last, so a failure leaves it unchanged);
3. then today's Continue (workspace init, language, features).

**The check never writes.** Today's Codex fallback writes during the check; that moves to Continue.

### Other copy

The Development goal's pitch names the picked agent: "Codex CLI works your folder's board. No connections needed". While nothing is picked, it says "Your AI agent …".

### Components

- `WatchtowerCore/Services/OnboardingAgentChoice.swift`: pure state and **every line of copy** above. Tests: `Tests/Core/OnboardingAgentChoiceTests.swift` (19 tests: default selection, pick, policy, Continue, save, all copy).
- `Views/Onboarding/OnboardingAgentSection.swift`: tiles plus the setup panel (`card(selected:)`, `Fill`, `Tone.success/warning/error`, `kitSecondary`/`kitQuiet`, no dividers); `OnboardingCommandLine` (the copyable command).
- `OnboardingGoalCards` and `OnboardingGoalsFooter` are extracted from `OnboardingGoalsStepView`, so the mockups render the step's own parts.
- `OnboardingCLIProbe` is replaced by a per-agent check that returns `[Agent: Status]`. `OnboardingGoalsModel` keeps an `OnboardingAgentChoice` in place of `OnboardingCLICheck`. `onProviderSwitched` fires after the Continue write instead of after the check.
- Mockups: `OnboardingAgentShotFixtures` in `DesignShotCatalog`, 13 scenes × light/dark.

## Failures

| Path | What happens | Test |
|---|---|---|
| A test hangs or the host closes mid-check | each agent's test has the CLI's own timeout → `failed(timeout msg)`; the other agent's result still shows; a newer check (Check again, reactivation) supersedes the old one by generation, as `runCLICheck` does today | model: stale generation ignored; choice: `failed` setup copy |
| App quits or crashes mid-check | nothing was written (the check never writes); the next launch resumes the Goals step and checks again | model: check performs no `config set` |
| `default_agent` write succeeds, `ai.provider` fails | stays on the step, footer shows "Couldn't save the AI agent." and the error; `ai.provider` unchanged; Continue retries both (the first is skipped when equal) | model: second write fails → error, no route |
| Owner installs while on the step | coming back to the window rechecks; Check again does it by hand | model: reactivation triggers a check only when the pick is not ready |
| Installer put the binary outside the usual places | Not installed stays; **Choose the executable…** saves the path and rechecks | model: path save → recheck |
| Policy forbids both | both tiles disabled, no tests, Continue disabled with "Continue unlocks once an AI agent is ready" | choice: no selection, hint |

## Writers of `ai.provider` / `workbench.default_agent`

- **Onboarding Continue** (this design): writes only when the pick differs, through `watchtower config set`.
- **Settings → System → AI**: Save writes the provider form.
- **CLI** `watchtower config set` (owner or an agent).
- The daemon and the phone never write them.

Every writer goes through `config set` (an atomic file replace). The last write wins. Onboarding writes once, at Continue, from the owner's pick at that moment, so a Settings change made in another window before Continue is overwritten by the pick. That is acceptable: the owner just chose on screen. Removing the check-time write removes today's race, where a background check could overwrite a provider the owner had just saved in Settings.

## Out of scope

- Ollama or an API key as an onboarding option (stays in Settings → AI). See the open question.
- Changing Settings → AI.

## Decisions

- Explicit Claude Code / Codex choice on the Goals step, with handling for "no agent installed": owner (conversation, 2026-11-10).
- Status per agent, both installed agents tested in parallel, policy respected: agent decided.
- Default selection order (configured → ready → installed → Claude); a tap is sticky: agent decided.
- The provider is written at Continue, not during the check: agent decided (behaviour change, raised in the ask below).
- Installers via `curl` (no Node.js), npm commands dropped: agent decided.
- Goal cards stay cards in the no-agent case (no chips): agent decided.
- Recheck when the window becomes active: agent decided.
- No agent: Continue stays blocked; no "continue without AI" and no Ollama here: agent decided, **open: owner's ask**.
