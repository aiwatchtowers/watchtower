# Sync is stuck or slow

New messages, mail or events do not show up, or the sync seems to run forever. Everything Watchtower shows comes from the background sync, so this is the first place to look when several tabs are stale.

## What you see

The menu bar menu shows one of three lines:

- **Sync daemon not running**, with **Sync Now** greyed out.
- **Daemon running · idle**, but nothing new has arrived for hours.
- **Syncing: Messages · 34/105 channels** (a phase and a counter) that stays for a long time.

## Why

- The sync runs in a small background program, the daemon. It stops when you choose **Quit Watchtower**; closing the window leaves it running.
- A cycle starts every 15 minutes, when the daemon starts, when the Mac wakes and on **Sync Now**. A sleeping Mac syncs nothing until it wakes.
- Slack calls are limited to 40 a minute, so a big workspace or a first sync takes several minutes. Expect 3 to 5 minutes for the first sync.
- One failing source does not stop the others. The cause may be a revoked account instead.

## Fix

1. Open the menu bar icon and read the status line.
2. **Sync daemon not running:** open Watchtower. Launching the app starts the daemon. If it keeps stopping, the error is printed under the line.
3. **Syncing, counter moving:** wait. The counter refreshes every few seconds.
4. **Idle, but data is old:** choose **Sync Now**. A cycle already in progress finishes first.
5. **Counter frozen for more than 10 minutes:** choose **Quit Watchtower** and open the app again. This restarts the daemon.
6. **Quit hangs:** in a terminal run `watchtower sync stop`, and if it says it is still shutting down, `watchtower sync stop --force`. Then open Watchtower.
7. Run `watchtower status` for the last sync time and `watchtower logs` for the log. A line naming one source points at [An account needs attention](account-needs-attention.md).

## How to check

The menu shows **Syncing: …** and then **Daemon running · idle**, and the tab you were waiting for fills.

## If it did not help

If the sync runs but a tab stays empty, see [A tab is empty](tab-is-empty.md). If it fails on one source, check its row in **Settings → Connections**. How a cycle is ordered is in [How Watchtower works](../concepts/how-watchtower-works.md).
