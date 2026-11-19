# Set up Watchtower

Setup is up to three screens, **Goals**, **Connect** and **Background AI**, and it asks for nothing you must have. You can skip every source, connect later in Settings, and run setup again at any time.

## Install Watchtower

Watchtower needs a Mac with Apple Silicon on macOS 14 or later. Install it with Homebrew or with the install script; both put **Watchtower.app** in `/Applications` and the `watchtower` command-line tool on your PATH.

```bash
brew tap aiwatchtowers/tap
brew trust --tap aiwatchtowers/tap
brew install --cask aiwatchtowers/tap/watchtower
# or
curl -fsSL https://raw.githubusercontent.com/aiwatchtowers/watchtower/main/scripts/install.sh | bash
```

The app updates itself either way, so `brew upgrade` leaves it alone. `brew uninstall --zap --cask watchtower` also removes your data and settings.

## What the Goals step decides

Each goal turns on a fixed set of features; the goals are not permissions. All four start ticked, and unticking all of them means Workbench only.

| Goal | Turns on | Connect step offers |
|---|---|---|
| **Work communication** | Slack Digests, Tracks, People Cards, Daily Briefing, Day Plan, Ideas & Decisions, Reaction Commands, Memory | Slack, Google |
| **Tasks & Jira** | Stream Digests, Next Step Suggestions | Jira or Linear |
| **Meetings** | Daily Briefing (meeting prep rides on it) | Google |
| **Development in Workbench** | nothing, because Workbench, the chat and Targets need no switch | nothing |

Knowledge search and Attention detection are always switched on, whatever you tick (Knowledge search uses some AI for images and links). You can still turn either off in **Settings → Features**, and if you do, running setup again leaves it off. What each feature does and costs is on [Turning features on and off](../concepts/features-on-and-off.md).

**Customize features →** shows the same features as switches. Once you flip one, your choice wins over the goals until you press **Reset**.

The **Assistant language** row sets the language of Catch Up, briefings, tracks and digests. It starts as your Mac's first language (shown "from macOS").

## Pick your AI agent

Every AI feature runs through the Claude Code or Codex command-line tool on your Mac. The **AI agent** section on the first screen shows both as tiles with their state: **Ready · signed in**, **Not installed**, **Installed · not signed in** or **Check failed**. Pick the one you want; once you pick one, later checks never change your pick. A tool your organization turns off shows **Turned off by your organization** and is dimmed. **Continue** unlocks when the picked one is ready, and only then is your choice saved. You can change it later in **Settings → System → AI**. If you set Ollama / Local there, the step shows one line saying so and tests it instead.

If the tool is not installed, the panel shows an install command with a copy button (no Node.js needed) and the sign-in command. **Other ways to install** opens the vendor's page for Homebrew and npm. Press **Check again**, or just come back to the window.

If it is installed but signed out, the browser opens to sign in and a small terminal shows its progress. When sign-in finishes, the terminal closes and the tile turns ready. A tool too old to sign in from here updates first. If sign-in stops, press **Sign in again**.

A **Check failed** tile says why under it. "Watchtower couldn’t run the check (…)" means Watchtower itself failed, not the tool: update or reinstall Watchtower, then press **Check again**.

**Choose the executable…** also appears when the tool is **Not installed** or the check failed: pick the copy you use. If updating does not help, you may have two copies installed; use it there too. More on providers is in [AI providers, models and cost](../concepts/ai-providers-and-cost.md); if it still fails, see [The Claude or Codex tool is not found or not signed in](../troubleshooting/ai-tool-not-found-or-not-signed-in.md).

## What the Connect step shows

Only the sources your goals need, as cards: Slack, Google ("Calendar"; "Mail and calendar" on a company build), Jira and Linear. A source your company's profile does not allow is not offered.

Google connects Calendar here through Watchtower's app; Gmail needs your company's Google project or your own, so connect it afterwards in **Connections → Google**. **Connect** opens the same sheet as **Connections**, and a connected card shows a check mark and the account name. The Jira sheet's **Also connect Confluence** box (ticked) adds Confluence to the same sign-in and selects up to five spaces you wrote in or viewed lately. After Jira connects, the sheet asks which boards to sync (**Choose Boards**); only those boards sync, and **Skip** leaves Jira's tabs saying "Choose Jira boards to get this" until you pick some. The Linear sheet signs in with Linear in the browser or takes a personal API key. The step says "You can continue without any" and **Continue** is on even with nothing connected.

After Slack connects, Watchtower loads its people list in the background ("Loading people… N") so Day Plan, Inbox and People know who is who. If your goals need no source (Workbench only), this step is skipped.

## Allow background AI, or not now
<!-- learn: none -->

The last screen asks whether Watchtower may run AI on its own: digests after each sync, the morning briefing, people cards, memory and your automations. These runs use the agent you picked, on your own Claude subscription or ChatGPT plan, and count toward its usage limits. The screen lists what can run and how often.

- **Allow background AI** lets that work run on its own.
- **Not now** keeps it paused: Slack, mail, calendar and Jira keep syncing, and chats, Catch-Up, **Run now** and anything else you start yourself still work. Watchtower does not ask again; turn it on later in **Settings → System → AI** under **Background AI**, or with **Allow background AI…** on Home.

The screen is skipped when you already answered, or when your organization decided for you (see [Organization policy](../reference/organization-policy.md)). If your choice can't be saved, the screen says why and stays; nothing runs in the background meanwhile.

## What happens when you press Continue

Setup finishes on its last screen: when you answer Background AI, or press **Continue** on Connect when Background AI is skipped. Watchtower starts its background sync once and opens **Home**, whichever goals you picked. The first sync reads the last 3 days of Slack (setup sets **Initial History Days** to 3 unless you had set it) and 7 days of mail; the rest of the first month arrives afterwards (see [History backfill](../concepts/history-backfill.md)). While it runs, Catch Up says "Syncing Slack for the last N days — usually 3–5 min", with progress.

Most tabs are empty at first. Each says what will land there and when, instead of showing a blank page; after **Not now**, the AI tabs say **Paused — background AI is off**. [Why a tab is empty](../concepts/features-on-and-off.md#why-a-tab-is-empty-and-what-its-status-line-means) decodes the status lines.

## Running setup again

**Settings → Profile → Run Setup Again** goes through the same screens (Background AI only if you never answered it), starting from the goals your current features add up to (it shows "Features customized" if you switched features by hand) and your current language. **Cancel**, top right, leaves without changing anything more. Your data and settings stay, and you return to the tab you were on.

## Related

- [How Watchtower works](../concepts/how-watchtower-works.md): what the background sync does after setup.
- [Sources and accounts](../concepts/sources-and-accounts.md): connecting more later.
- [Set up Watchtower for your company](company-setup.md): your company's apps, a link or a code for colleagues.
- [Your first week](first-week.md)

For developers: [docs/features/onboarding-v2.md](../../features/onboarding-v2.md)
