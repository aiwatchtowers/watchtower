# Sync is stuck or slow

New messages, mail or events do not show up, or the sync seems to run forever. Everything Watchtower shows comes from the background sync, so this is the first place to look when several tabs are stale.

## What you see

The menu bar menu shows one of three lines:

- **Sync daemon not running**, with **Sync Now** greyed out.
- **Daemon running · idle**, but nothing new has arrived for hours.
- **Syncing: Messages · 34/105 channels** (a phase and a counter) that stays for a long time.
- A Syncing line that ends in **Slack rate limit, retrying in …**.

## Why

- The sync runs in a small background program, the daemon. It stops when you choose **Quit Watchtower**; closing the window leaves it running.
- A cycle starts every 15 minutes, when the daemon starts, about 15 seconds after the Mac wakes and on **Sync Now**. A sleeping Mac syncs nothing until it wakes. During Power Nap, when the Mac wakes briefly in sleep without turning the screen on, no sync or scheduled automation starts; they run once the Mac fully wakes, about 15 seconds after the network is back. **Sync Now** still runs at once. A cycle the Mac fell asleep in while fetching stops on wake and starts over.
- Slack limits how fast Watchtower may call it. Watchtower starts at the rate Slack documents, speeds up while Slack allows it and slows down when Slack refuses, so a big workspace or a first sync takes several minutes. Expect 3 to 5 minutes for the first sync.
- When Slack refuses, the sync waits the time Slack asks and retries. It stops waiting once a wait would end more than 10 minutes after that Slack sync began; the next sync continues where it stopped, and nothing is lost.
- An account Slack keeps refusing, or one with few new messages, syncs less often, at least once an hour. Its mentions of you are fetched first, but the last sync time Watchtower shows can be up to an hour old.
- One failing source does not stop the others. The cause may be a revoked account instead.

## Fix

1. Open the menu bar icon and read the status line.
2. **Sync daemon not running:** open Watchtower. Launching the app starts the daemon. If it keeps stopping, the error is printed under the line.
3. **Syncing, counter moving, or Slack rate limit, retrying in …:** wait. The counter refreshes every few seconds, and a rate-limit wait is not a stall.
4. **Idle, but data is old:** choose **Sync Now**. If the cycle in progress is stuck fetching Slack, with no progress for over a minute, it is stopped and a fresh one starts at once. Any other cycle in progress finishes first and then syncs again.
5. **Counter frozen for 10 minutes or more (a rule of thumb, not a limit):** choose **Quit Watchtower** and open the app again. This restarts the daemon.
6. **Quit hangs:** in a terminal run `watchtower sync stop`, and if it says it is still shutting down, `watchtower sync stop --force`. Then open Watchtower.
7. Run `watchtower status` for the last sync time and `watchtower logs` for the log. A line naming one source points at [An account needs attention](account-needs-attention.md).

## How to check

The menu shows **Syncing: …** and then **Daemon running · idle**, and the tab you were waiting for fills.

## If it did not help

If the sync runs but a tab stays empty, see [A tab is empty](tab-is-empty.md). If it fails on one source, check its row in **Connections**. How a cycle is ordered is in [How Watchtower works](../concepts/how-watchtower-works.md).
