# Codex hook spikes (plan 2026-11-05 Task G7, codex 0.159.2)

Run against a throwaway `CODEX_HOME`, a temporary folder and a local mock of
the Responses API, with the TUI driven through a pseudo-terminal. Payloads
here are scrubbed to the fixtures' placeholders.

- **(a) Mid-turn input: proven.** A line pasted with bracketed paste and its
  Return while codex works shows as "Messages to be submitted after next tool
  call" and goes into the same turn's next model request (after the tool's
  output, or after a text answer when the turn has no tool call; one Stop at
  the end). It fires `UserPromptSubmit` with the pasted text, line breaks
  kept (`user_prompt_submit_midturn.json`). Tab instead queues the line for
  after the turn. Enabled: `agentkind` `MidturnInput`/`PhoneInput`.
- **(b) PermissionRequest hold and answer: works, not enabled.** The hook
  can hold (20 s tried) and answer with `permission_request_output_*.json`
  (the same schema Claude Code's permission-wait prints); a deny reaches the
  model as `Rejected("<message>")`, no output leaves the decision to the
  terminal. Unlike Claude Code, the terminal shows only "Running hook" and
  no prompt while the hook holds; the prompt appears after the hook ends
  without a decision or times out. A permission-wait hook would take the
  Mac's own answer away for the whole hold, so `PermissionWait` stays false
  (owner decision).
- **(c) Idle signal and elicitation: not available.** codex 0.159.2 has the
  hook events in `hook_events.json` and no `Notification`; the legacy
  `notify` program gets `agent-turn-complete` only. An MCP
  `elicitation/create` shows a form in the terminal but fires no hook (only
  the `PreToolUse` of the tool call before it) and writes nothing to the
  rollout (approval requests are not written there either). `IdleSignal` and
  `Elicitation` stay false; Settings → Notifications says so.
