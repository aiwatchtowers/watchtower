# Updates and quitting

Workbench sessions run in a small background helper, not inside the Watchtower window. This page is for anyone with agents at work who updates, quits or restarts the Mac: what keeps running and what stops.

## Why use it

You want the latest Watchtower, but an agent is halfway through a long task. An update leaves it running, and a quit asks you first, so you never lose a session by accident.

## How it works

### Updates and quitting
<!-- learn
id: updates-keep-sessions
title: Quit and keep agents working
text: Choose **Keep Sessions and Quit** and your sessions keep running; updates never stop them.
area: development
level: next
kind: tip
since: 0.24.0
-->

Sessions run in a small background helper, not inside the Watchtower window. An update leaves them running: the agent keeps working, and its helper agents and background jobs (a dev server, a build) keep going. When Watchtower comes back, each session shows its live terminal again.

An update, log-out or restart never asks about sessions (only about a running recording or unsent ask answers). When you quit yourself with sessions running, Watchtower asks:

- **Keep Sessions and Quit** leaves them running.
- **Stop Sessions and Quit** stops them.
- **Cancel** stays in the app.

**Reset All Data** (Settings → System) always stops them. Sessions run only in the helper. If it is not running, starting a session starts it again; if that fails, the session does not start and its terminal shows **[Watchtower] the session host is not running** (or **[Watchtower] could not reach the session host: …**). Press **Restart** to try again.

If Watchtower loses its connection to the helper while a session runs (for example while your Mac is short of memory), the session keeps running in the helper. Its terminal shows **Disconnected from the session host — reconnecting…** and reconnects on its own; **Reconnect** tries at once. A session is shown as exited only when the helper says it ended. Opening a stopped session that the helper still runs shows that session instead of starting a second agent, and **Start fresh** stops it first.

If one session ever has two runs in the helper (an older Watchtower could start one beside a lost session), its terminal shows **Another run of this session is still running in the session host.** Press **Stop** to stop the other run; the one on screen keeps going.

Sessions do not survive a Mac restart or log-out; use **Resume** after one. While Watchtower is closed, sessions send no notices and your phone sees no updates. A session that exited meanwhile shows its last output and reads as exited when you return.

**Once, with the update that brings the new phone hub,** the helper itself is replaced. If sessions are running then, Watchtower shows **Running sessions restart once with this update; their conversations continue** with a **Continue** button. Nothing changes until you press it: quitting leaves the sessions running, and the notice comes back at the next launch. After **Continue**, Watchtower stops each session, starts the new helper and resumes each session's conversation. Sessions of another workspace resume when you open that workspace; until then Settings → System → Workspace shows **N sessions wait to resume** under its name. A session whose conversation cannot be found shows **Start fresh**, as after any failed resume.

Every Watchtower build on your Mac shares one helper. Two copies open on the same workspace compete for its sessions: the loser shows **Another Watchtower window took this session over.**, and restarting the session there starts a second agent. The helper quits a minute after its last session ends, and an update's new helper takes over then.

## Using it

1. Update Watchtower as usual; your sessions keep working and show their live terminals when the app comes back.
2. To quit with sessions running, choose **Keep Sessions and Quit** to leave them working or **Stop Sessions and Quit** to stop them.
3. After a Mac restart or log-out, press **Resume** on each session you want back. See [Sessions](sessions.md).

## When it's empty or wrong

- **[Watchtower] the session host is not running.** The helper is not running and starting it again failed, so the session did not start. Press **Restart**; if it still fails, quit and reopen Watchtower.
- **Disconnected from the session host (…). The session may still be running.** Watchtower stopped reconnecting five minutes after the connection was lost, or the helper refused it the same way three times; the reason is in the brackets. Press **Reconnect**; if it keeps failing, quit and reopen Watchtower, which shows the session again if it still runs.
- **Could not ask the session host whether this session still runs, so nothing was started.** Watchtower could not check for a running copy of the session, so it started none beside it. Open the session again in a moment.
- **Sessions could not be restarted.** The one-time restart stopped part-way (the reason is under the line). Press **Retry**; sessions already listed resume then, and a reason that says your sessions were not changed means they still run.
- **The list of sessions to resume could not be read.** Nothing was stopped. **Retry** reads it again. **Set Aside** keeps the file as `session-host-restart.json.corrupt`, and Watchtower asks about the running sessions again.
- **N sessions wait to resume in a workspace that is no longer here.** Their workspace was removed. **Clear** drops them from the list.
- **Another Watchtower window took this session over.** Two copies of Watchtower on one workspace share the helper. Use the session in the copy that holds it: restarting it here starts a second agent.

## Related

- [Sessions](sessions.md)
- [Menu bar and updates](../menu-bar-and-updates.md)

For developers: [docs/features/workbench.md](../../../features/workbench.md)
