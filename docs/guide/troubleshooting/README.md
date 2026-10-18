# Troubleshooting

Find what you see on the screen in the first column; the second column opens the page that fixes it. Each page gives the cause, ordered steps, how to check, and what to try next. Short symptom lists also sit at the end of each feature page, under "When it's empty or wrong".

| What you see | Page |
|---|---|
| A tab says "No briefings yet", "No tracks yet" or another "No … yet" with a status line | [A tab is empty](tab-is-empty.md) |
| The menu bar says "Sync daemon not running", or "Syncing: …" never ends, or new messages do not arrive | [Sync is stuck or slow](sync-stuck-or-slow.md) |
| Briefings or Day Plan has nothing for today | [No briefing or day plan today](no-briefing-or-day-plan.md) |
| "The AI provider isn't signed in", "Claude Code was not found", a red cross by **Claude CLI Path** | [The Claude or Codex tool is not found or not signed in](ai-tool-not-found-or-not-signed-in.md) |
| A red dot on a service in **Settings → Connections**, **Re-login**, "Stopped syncing" | [An account needs attention](account-needs-attention.md) |
| The **Calendar** tab is hidden, or a meeting you expect is not in the list | [Calendar events are missing](calendar-events-missing.md) |
| **Record** does nothing, "Microphone access was denied", "No speech recognized", a failed pill | [Recording or transcript problems](recording-or-transcript-problems.md) |
| An answer to an ask does not reach the agent, or a session shows only a green dot | [A Workbench session or ask is stuck](workbench-session-or-ask-stuck.md) |
| The iPhone shows "Mac offline", never finds the Mac, or the code will not link | [The iPhone is not syncing](iphone-not-syncing.md) |
| "Claude plan limit", "rate-limiting requests", or the AI costs more than you expect | [Plan limits and high cost](plan-limits-or-high-cost.md) |
| An automation run says "more than 2000 SDK calls", "already started 10 sessions", "journal is incomplete" or "could not be finished" | [An automation run stopped at a limit](automation-run-limits.md) |
| The app does something other than what its own screen says | [Known issues](known-issues.md) |

Nothing here? Run `watchtower status` and `watchtower logs` in a terminal ([Command line](../reference/cli.md)) and read the last lines for the failing step.
