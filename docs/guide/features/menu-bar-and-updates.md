# Menu bar and updates

Watchtower lives in the menu bar. The window is optional: the sync daemon keeps working with it closed, and the same icon tells you when a new version is ready. This page covers what the menu shows, what closing and quitting do, and how updates arrive.

## Why use it

You close the window to get on with your day. Syncing, briefings and recording notices carry on, and one glance at the icon says whether the daemon is busy, idle or stopped. When a release comes out, a notification tells you; you never have to hunt for a download page.

## How it works

Watchtower runs in two parts: the app and a background sync daemon. The daemon syncs your sources every 15 minutes by default (`sync.poll_interval`) and runs the AI phases after each sync.

The first line of the menu reports the daemon's real state:

- **Syncing: Messages · 34/105 channels** while a sync runs. The phase and counter refresh every few seconds.
- **Daemon running · idle** between syncs.
- **Sync daemon not running** when there is no daemon.

Other lines appear only when they apply:

- **Loading history: N of M days** while a new source's first month loads, or "Loading history paused" when an account needs reconnecting.
- A model download with its progress, or why it failed, plus **Retry <model> Download**.
- Your Claude plan limits (session and weekly). Clicking one opens Usage → Claude plan. The **Show in the menu bar** switch there also puts the percentages next to the icon.
- A daemon or CLI install error, if one happened.

### Updates

Watchtower checks for a new version at every launch and then every 6 hours while it runs. When it finds one, you get one notification and one **Software Update** window per version, never repeated. The window shows the release notes in full.

The window is held back while a recording or transcription is running, and appears at the next background check after it ends (checks run every 6 hours). **Update to <version> available…** also shows in the menu, and **Update Available** at the bottom of the sidebar; both open the **Software Update** window.

Installing replaces the app in place and restarts it. Before it swaps anything, it checks that the new app is signed by the same developer as the one you run. A build that is distributed outside the public releases shows "Updates for this build are distributed out of band" instead, and never updates from the public feed.

The first launch of a new version opens the **Software Update** window once more, on **What's New in Watchtower <version>**, so you see what changed.

## Using it

### Menu items
<!-- learn
id: menubar-sync-now
title: Sync right now
text: Press **Sync Now** in the menu-bar icon's menu to sync at once instead of waiting for the next cycle.
area: setup
level: next
kind: tip
since: 0.24.0
-->
<!-- learn
id: menubar-run-automation
title: Run an automation from the menu bar
text: **Run automation** in the menu-bar menu lists your recipes; click one to run it without opening the window.
area: automations
level: next
kind: tip
since: 0.24.0
action: nav:automations
-->

- **Sync Now** asks the running daemon to sync immediately. It is greyed out when no daemon runs, and a sync already in progress finishes first.
- **Run automation** lists your recipes with their last result; clicking one runs it without opening the window. **Open Automations…** opens the tab.
- **New Voice Idea** opens Quick Capture and starts dictating. The shortcut is **⌃⌥D** from anywhere.
- **Voices to label (N)** shows while the queue is not empty. **Review voices** and **Train voices** open the Voices window.
- **Open Watchtower** brings back the window and the Dock icon. **Settings…** opens Settings without the main window.
- **Quit Watchtower** is the one full exit.

### Close, quit, launch
<!-- learn
id: menubar-close-keeps-syncing
title: Close the window, keep syncing
text: Close the window and Watchtower stays in the menu bar, syncing; only **Quit Watchtower** stops it.
area: setup
level: basics
kind: tip
since: 0.24.0
-->

Closing the window leaves the Dock and keeps Watchtower in the menu bar. If Settings or another window is open, the Dock icon stays until it closes too.

**Quit Watchtower** (or ⌘Q) also stops the daemon, so nothing syncs and no tokens are spent until you launch again. If a recording or transcription is running, Watchtower asks first: **Stop & Quit** ends it (audio already captured is kept and offered again at the next launch), **Cancel** lets it finish. If you have unsent ask answers, it asks too, because they live only in memory.

Watchtower registers itself as a login item once per installed copy, so the daemon is already running when you sit down. A login launch opens straight to the menu bar with no window. To stop that, turn Watchtower off in System Settings → General → Login Items; there is no switch in the app, and it will not turn itself back on.

### Install an update
<!-- learn
id: menubar-update-window
title: Update in one window
text: Click **Update Available** in the sidebar or the menu's update item, read the notes, then press **Update Now**.
changed: Every update entry point opens the Software Update window, with the download's progress.
replaces: [menubar-update-whats-new, menubar-install-update]
area: setup
level: next
kind: feature
since: 0.26.3
-->

1. Click **Update Available** at the bottom of the sidebar, **Update to <version> available…** in the menu, or the notification. Each opens the **Software Update** window with the release notes.
2. Press **Update Now**. The window shows the download's progress, then installs and restarts. **Later** closes it; the update stays on offer.
3. If a recording or transcription is running, it stops at **Ready to install**; press **Install & Restart** when it ends.
4. If it says **Update installed — restart Watchtower to finish**, press **Restart Now**.

Settings → System → **Update** does the same: **Check for Updates** checks on demand, **What's New…** opens the window, **Download** and **Install & Restart** run the steps one by one.

**Watchtower → About Watchtower** links to the GitHub repository and to the release notes of the version you run.

## When it's empty or wrong

- **No Watchtower icon in the menu bar.** The app is not running. Launch it from Applications; it will stay in the bar.
- **"Sync daemon not running" and Sync Now is greyed out.** The daemon stopped, usually after Quit. Launch Watchtower again, which starts it. If it keeps failing, the error appears under the line.
- **"Install & Restart" is greyed out.** A recording or transcription is in progress. Finish it, then install.
- **No update shows.** Your build may have no update channel ("distributed out of band"), or you are already on the latest. Press **Check for Updates** to see.
- **"Update error".** The message under it says why (a failed download or a checksum mismatch). **Retry** checks again.
- **Window closed but you wanted Watchtower gone.** Use **Quit Watchtower**, not the red button.

Sync not running or stuck? See [Sync is stuck or slow](../troubleshooting/sync-stuck-or-slow.md).

## Related

- [iPhone](iphone.md): the phone app needs Watchtower running on the Mac.

For developers: [docs/features/tray-daemon-lifecycle.md](../../features/tray-daemon-lifecycle.md)
