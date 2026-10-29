# Agent coach

The agent coach reads how your agents and reviews have gone and, once a week, suggests edits to your own agent setup. It is for the person who keeps correcting the same thing. Nothing changes until you accept a suggestion.

## Why use it

You tell agents the same thing again and again, or you mark the same kind of spec review finding as noise. The coach notices the repeat, writes the exact edit that would stop it, and later checks whether things got better.

## How it works
<!-- learn
id: agent-coach-screen
title: Let the coach tune your agents
text: Open **Analytics** in a workbench to see the coach's suggested edits and press **Accept**, **Edit…** or **Decline**.
area: development
level: power
kind: feature
since: 0.26.3
action: nav:projects
replaces: [agent-coach-suggestions, instructions-suggestions]
changed: Suggestions now live in Analytics and on Home, and repeated directions you give agents come through the coach.
-->

Once a week the background daemon looks at the last four weeks: your marks on spec review findings (**Comment** counts as a real problem, **Not useful** as noise), the first round of your code reviews, the lines you sent to agents and chats, and the hints in **Analytics**. When a pattern shows up in at least three different sessions, specs or review rounds, it becomes a suggestion. At most three wait for you at once, and a suggestion you decline is not proposed again unless the text it would change has changed since.

A suggestion edits one place, always your own setup and never a file in a repository:

- your instructions (global or per workbench), the target procedure and the chat text;
- extra lines for a Watchtower prompt, such as the spec reviewer. They are added on top of the prompt, so prompt updates still reach you;
- permission rules in `~/.claude/settings.json`, only for reading, searching and running the tests or build (`cat`, `ls`, `grep`, `head`, `tail`, `go test`, `go build`, `go vet`, `swift test`, `swift build`, `cargo test`, `npm test`, `pytest`). A test or build rule runs project code, so accept it only if you trust your projects;
- your `~/.claude/CLAUDE.md`.

After you accept, the coach waits 14 days and compares the measure it targeted with the 14 days before. The verdict is **works**, **no effect** or **too little data**. It shows what changed since the edit, not that the edit caused it. A no-effect edit gets a suggestion to remove it.

## The Analytics screen

Open a workbench's **Analytics** (analytics must be on for it). From the top:

- **How it's going** has four tiles for the period you pick (**1 day**, **7 days** or **30 days**) against the period before: corrections per task, hours and cost per task, your share of active time, and review findings. Lower is better; a change under 5 % reads "about the same", and a tile with too little behind it says so instead of showing a trend.
- **Proposed edits** lists up to three suggestions. Each card shows what it moves, why, the lines removed and added, how big the text gets against its limit, and links to the evidence. **Accept** applies it. **Edit…** opens the whole proposed text so you can change it first (not for permission rules). **Decline** asks once and is for good. Below, **Run Now** does the weekly pass at once; if the daemon is already running it, the screen says so and updates when it finishes.
- **Accepted edits** is the log, newest first, with a verdict line: **works**, **no effect**, **too little data** or **measuring**. **Roll Back** undoes an edit; if you changed the text since, it shows the difference and offers **Roll Back Anyway**.
- **Statistics** is the rest of the view, described in [Agent analytics](agent-analytics.md).

Home shows the newest suggestion as **Coach suggests**, with the change itself, **Accept**, **Decline** and **Open in Analytics**. A change longer than four lines shows its first four and offers only **Open in Analytics** and **Decline**, so you never accept a change you cannot see whole.

Your repeated directions to agents and chats come through the coach too. Settings → System → Workbench and a workbench's **Agent Settings…** have a line pointing to Analytics instead of their own suggestion list.

## Using it

```
watchtower coach status
watchtower coach proposals
watchtower coach accept 12
watchtower coach decline 13
watchtower coach rollback 12
watchtower coach run --dry-run
```

- `status` shows corrections, hours and cost per task, your share of active time, findings per spec review and comments per diff review, for the last 14 days against the 14 before; `--days N` (1 to 90) picks another length.
- `proposals` and `run` show each suggestion's change: removed lines with `-`, added ones with `+`.
- `accept` applies a suggestion; `accept 12 --stdin` takes your own edited text from standard input instead (empty input is refused). If the text changed since the suggestion was made, it is marked superseded and nothing is written.
- `rollback` undoes an accepted edit. If you changed the place since, it prints the difference and needs `--force`.
- `run` does the weekly pass now (it says `busy` if another pass is running); `--dry-run` prints what would be suggested and writes nothing.
- Add `--json` for scripts.

`accept`, `decline`, `rollback` and `run` are your own decisions: an AI agent running them is refused, and from a terminal Watchtower must be open so you can confirm each one in its window (`run --dry-run` writes nothing and asks for no confirmation).

On a spec review's findings screen, **Not useful** sits next to **Fix**, **Fine as is** and **Comment**. It is never sent to the author; it only teaches the coach.

## When it's empty or wrong

- **No suggestions:** the coach needs three separate sources for a pattern and runs about once a week. Run `watchtower coach run` to try now.
- **Numbers show unknown:** turn on **Analytics** for the workbench; without tasks or sessions there is nothing to divide by.
- **"The text changed since":** you edited that text meanwhile, so the card closes. The next weekly pass can suggest again.
- **A superseded suggestion:** you edited that text meanwhile. The next weekly pass can suggest again.
- **Rolled-back CLAUDE.md is empty:** if an edit created the file, rolling back leaves it empty.
- The coach never edits a project's own `CLAUDE.md`, workflow file or skills.

## Related

- [Agent analytics](agent-analytics.md)
- [Your instructions](workbench/instructions.md)

For developers: docs/features/agent-coach.md
