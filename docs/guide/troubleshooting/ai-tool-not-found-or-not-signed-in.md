# The Claude or Codex tool is not found or not signed in

Chat replies fail, digests and briefings report "Didn't work yet", or Setup keeps **Continue** off. Watchtower has no AI of its own: it runs the Claude Code or Codex command-line tool you installed, with your sign-in.

## What you see

- In the AI Chat, a card: "The AI provider isn't signed in. Open Terminal and run: claude login" (or `codex login`), with no **Retry**.
- In **Settings → System → AI**, a red cross by **Claude CLI Path** or **Codex CLI Path** ("Claude CLI not found"), or after **Test Connection**: "Not authenticated. Run 'claude' in Terminal."
- In a Workbench: "Claude Code was not found on your login-shell PATH. Install it, or add it to PATH, then Restart." or "Codex was not found."
- A status line "Didn't work yet — retries automatically" whose reason names the tool.
- A reason that names a Codex model: "**Codex needs an update to use** gpt-6-astra" or "gpt-6-astra **isn't available on your Codex account**". Watchtower has already retried once with its fallback model; this shows when that failed too.

## Why

Either the tool is not installed where Watchtower looks, or it is installed but its sign-in expired or never happened. A local Ollama server has its own failures: "Server unreachable" or an HTTP error from **Test Connection**.

## Fix

1. Open **Settings → System → AI** and check the provider you picked.
2. A red cross: install the tool, or type its full path into **Claude CLI Path** / **Codex CLI Path**. In Terminal, `which claude` (or `which codex`) prints the path. A green check means it was found.
3. Not signed in: in Terminal run `claude login` (or `codex login`), or start `claude` and sign in. Use the same macOS user that runs Watchtower.
4. Press **Test Connection**. The result line says what failed: not authenticated, "Model not available for your account.", "API overloaded. Try again later." or "Network error."
5. A model error: clear **Light Model** or **Strong Model** with **Default**. "Codex needs an update": run `codex update` in Terminal. "Isn't available on your Codex account": type a model your account offers, such as `gpt-5.6-sol`.
6. Ollama / Local: start the server, check the URL and that the chosen model exists, then **Test Connection**.
7. Workbench: after the tool works, press **Restart** on the session.

## How to check

**Test Connection** shows a green tick. Retry the chat message; the status line on an empty tab changes to a time within one sync cycle.

## If it did not help

A chat card shows the provider's own message under the sentence; read it. Rate-limit and plan problems are in [Plan limits and high cost](plan-limits-or-high-cost.md). Provider choices are in [AI providers, models and cost](../concepts/ai-providers-and-cost.md).
