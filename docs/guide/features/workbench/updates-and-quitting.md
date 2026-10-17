# Updates and quitting

Workbench sessions run in a small background helper, not inside the Watchtower window. This page is for anyone with agents at work who updates, quits or restarts the Mac: what keeps running and what stops.

## Why use it

You want the latest Watchtower, but an agent is halfway through a long task. An update leaves it running, and a quit asks you first, so you never lose a session by accident.

## How it works

### Updates and quitting

Sessions run in a small background helper, not inside the Watchtower window. An update leaves them running: the agent keeps working, and its helper agents and background jobs (a dev server, a build) keep going. When Watchtower comes back, each session shows its live terminal again.

An update, log-out or restart never asks about sessions (only about a running recording or unsent ask answers). When you quit yourself with sessions running, Watchtower asks:

- **Keep Sessions and Quit** leaves them running.
- **Stop Sessions and Quit** stops them.
- **Cancel** stays in the app.

**Reset All Data** (Settings → System) always stops them. If the helper cannot be reached when Watchtower starts, sessions run in the window instead: each says "This session stops when Watchtower quits." under its terminal, and the quit alert counts it as "unprotected". If the helper stops later, the next session start restarts it; if that fails, the terminal shows **[Watchtower] the session host is not running**.

Sessions do not survive a Mac restart or log-out; use **Resume** after one. While Watchtower is closed, sessions send no notices and your phone sees no updates. A session that exited meanwhile shows its last output and reads as exited when you return.

Every Watchtower build on your Mac shares one helper. Two copies open on the same workspace compete for its sessions: the loser shows **Another Watchtower window took this session over.**, and restarting the session there starts a second agent. The helper quits a minute after its last session ends, and an update's new helper takes over then.

## Using it

1. Update Watchtower as usual; your sessions keep working and show their live terminals when the app comes back.
2. To quit with sessions running, choose **Keep Sessions and Quit** to leave them working or **Stop Sessions and Quit** to stop them.
3. After a Mac restart or log-out, press **Resume** on each session you want back. See [Sessions](sessions.md).

## When it's empty or wrong

- **"This session stops when Watchtower quits."** The helper could not be reached at start; the session runs in the window and stops with it.
- **[Watchtower] the session host is not running.** The helper stopped and starting it again failed. Quit and reopen Watchtower: if the helper still can't be reached, sessions run in the window instead.
- **Another Watchtower window took this session over.** Two copies of Watchtower on one workspace share the helper. Use the session in the copy that holds it: restarting it here starts a second agent.

## Related

- [Sessions](sessions.md)
- [Menu bar and updates](../menu-bar-and-updates.md)

For developers: [docs/features/workbench.md](../../../features/workbench.md)
