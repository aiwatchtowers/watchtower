# Session report and analytics

Watchtower reads what each Claude Code session did: the target it works on, its tasks and pull requests, and what it cost. This page is for anyone running several sessions who wants their progress without opening each terminal.

## Why use it

Three agents ran overnight. The progress line under each session name, the **Session** view and the **Analytics** view tell you which one finished, which opened a pull request and which spent the most.

## How it works

### The session report

Under the caption, Watchtower shows a progress line once it has read the report: for example "#314 · 14/15 · PR #147 open" for the target the session works on, its done tasks and its pull requests. The line refreshes every 15 seconds while the Workbench tab is on screen. If a refresh fails, the last line stays with "· stale" at the end.

Pull request details need the GitHub CLI (`gh`). Without it, only whether a branch is merged is known.

## Using it

### Read the Session view

The **Session** button in the page header shows the report of one Claude Code session next to its terminal:

- **On you**: the session's open asks, each with **Open**.
- **Now**: tasks in progress, in review or blocked.
- **Pull requests**: each one's state and size, or "no PR yet" or "not checked".
- **Done**: one line per phase.
- **Agent's last word**: the summary the agent wrote when it finished. It becomes **Previous summary** once you send a new prompt.

It refreshes every 30 seconds while on screen, and when the session's state changes. With nothing to show it says "Pick a session".

### Read the Analytics view

The **Analytics** button in the page header (or **Analytics** in a pane's title menu) shows where this folder's Claude Code sessions spent their time and money:

- Pick **7 days**, **30 days** or **All**. The first time, press **Turn On**: it returns at once, and the daemon loads the history in the background. Until it is done, **Loading history — N files so far** sits above the numbers loaded so far.
- The hints say what would save the most. Each links to its session or board target.
- Click a session to see its timeline: one lane for the main agent and one per subagent.

## When it's empty or wrong

- **"Pick a session" in the Session view.** No Claude Code session is selected, or it is a plain shell, or it was deleted.
- **"· stale" at the end of the progress line.** The last refresh failed; the line updates again on the next one.
- **Pull requests show no details.** Install the GitHub CLI (`gh`); without it only whether a branch is merged is known.

## Related

- [Sessions](sessions.md)
- [Agent analytics](../agent-analytics.md)

For developers: [docs/features/workbench.md](../../../features/workbench.md)
