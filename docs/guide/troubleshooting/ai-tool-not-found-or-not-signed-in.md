# The Claude or Codex tool is not found or not signed in

Chat replies fail, digests and briefings report "Didn't work yet", or Setup keeps **Continue** off. Watchtower has no AI of its own: it runs the Claude Code or Codex command-line tool you installed, with your sign-in.

## What you see

- In Chats, a card: "The AI provider isn't signed in. Open Terminal and run: claude login" (or `codex login`), with no **Retry**.
- In **Settings → System → AI**, **Not installed** or **Needs attention** under the provider, or after **Check connection**: "Claude CLI wasn't found" (or Codex), or "Sign in to the Claude CLI in Terminal, then test connection again."
- In a Workbench: "Claude Code was not found on your login-shell PATH. Install it, or add it to PATH, then Restart." or "Codex was not found."
- A status line "Didn't work yet — retries automatically" whose reason names the tool.
- A reason that names a Codex model: "**Codex needs an update to use** gpt-6-astra" or "gpt-6-astra **isn't available on your Codex account**".
- After **Test connection**: "Connection test failed. Codex answered but ignored Watchtower's instructions. Update the Codex CLI, or check its config, and test again."

## Why

Either the tool is not installed where Watchtower looks, or it is installed but its sign-in expired or never happened. A local Ollama server has its own failures: it is not running, or a model it does not have answers with an HTTP error.

## Fix

During setup, use the **AI agent** section on the first screen: pick **Claude Code** or **Codex CLI**, copy the install command from its panel (**Other ways to install** if you cannot pipe a script into the shell), and sign in right there. If the update it offers does not change anything, the tool is probably installed twice: press **Choose the executable…** and pick the copy you use. After setup, use the steps below.

1. Open **Settings → System → AI** and check the **Preferred provider** (and the **Reserve provider**, if you use one).
2. Press **Check connection**. It looks at the installed tool and its sign-in without sending an AI prompt.
3. **Not installed**: install the tool, or type its full path into **Claude CLI path** / **Codex CLI path** (empty means **Auto-detect**). In Terminal, `which claude` (or `which codex`) prints the path.
4. Not signed in: in Terminal run `claude auth login` (or `codex login`), or start `claude` and sign in. Use the same macOS user that runs Watchtower.
5. **Not verified** means the sign-in can't be read without asking the provider. Press **Test connection**: it sends one short request with the **Strong model**, which may use paid quota. A failed test names the cause, for example "Provider request failed (auth)." or "(model)".
6. A model error: empty **Light model** or **Strong model**, or pick **Provider default** in its menu. "Codex needs an update": run `codex update` in Terminal. "Isn't available on your Codex account": type a model your account offers, such as `gpt-5.6-sol`. "Ignored Watchtower's instructions": run `codex update` in Terminal, then **Test connection** again.
7. Ollama / Local: start the server, check **Server URL** and that the chosen model exists, then **Test connection**.
8. Workbench: after the tool works, press **Restart** on the session.

## How to check

**Test connection** shows **Connection test completed** with "Claude answered using …" (or Codex). Retry the chat message; the status line on an empty tab changes to a time within one sync cycle.

## If it did not help

A chat card shows the provider's own message under the sentence; read it. Rate-limit and plan problems are in [Plan limits and high cost](plan-limits-or-high-cost.md). Provider choices are in [AI providers, models and cost](../concepts/ai-providers-and-cost.md).
