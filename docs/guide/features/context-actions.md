# Context actions

Context actions are the **Do these** list in a workbench's **Analytics** → **Context** block. Each row is one ready change that makes every Claude Code session start smaller. It is for the person who saw the start bar and wants to know what to cut. Nothing changes until you press the row's button.

## Why use it
<!-- learn
id: context-actions-do-these
title: Cut what every session loads
text: In **Analytics** → **Context**, press a **Do these** row to turn off what your sessions never use and see what it saved.
area: development
level: power
kind: feature
since: next
action: nav:projects
-->

Every session and subagent starts by loading the same things: `CLAUDE.md`, the memory index, plugin skills and agents, MCP tool lists. Some of it is never used, and you pay for it at every start. The list names each such source, shows its weight in tokens and its calls, applies the change for you and later measures what it saved.

## How it works

Watchtower finds the changes on its own, with no AI call: after the daemon loads new session history, in the weekly coach pass, and on **Run Now**. A change is proposed only when the numbers back it:

- a plugin, an MCP server you added yourself, or the claude.ai connectors as a whole, weighing 500 tokens or more at start with 0 calls in 30 days;
- a `CLAUDE.md` over 20 KB with a `##` section of 8 KB or more;
- a memory index (`MEMORY.md`) over 8 KB.

Each needs five measured sessions. Calls are counted only in Watchtower workbench sessions with Analytics on, across all your workbenches. A row that says "0 calls" therefore means "0 calls in Watchtower sessions", and **Also on in:** lists other projects where the source is on.

Watchtower never proposes its own MCP servers, its own skills, `superpowers` or `pr-review-toolkit`. It also skips plugins that ship hooks, output styles or language servers, because those work without calls. A change you decline is not proposed again.

The row's tag says what kind of change it is:

- **your settings**: **Turn Off** changes one key in Claude Code's user settings (`~/.claude/settings.json` or `~/.claude.json`) and leaves every other key's value as it was. It applies to every project on your Mac and takes effect in new sessions. **Undo** puts the key back.
- **repo · PR**: **Accept** starts a Claude Code session in the workbench with a ready brief. The session works in its own worktree, runs your project's review, and opens a pull request. It never merges; you do. Watchtower itself writes no file and no git.
- **your memory**: **Archive** starts a session that picks the stale lines, moves them to an archive file behind one pointer line, and asks you to approve the diff before it writes. **Undo** asks first (**Undo the memory cleanup?**), then restores the old index while it still holds what the session wrote.

Accepting any repository suggestion of the [agent coach](agent-coach.md) or the [tuning chat](tuning-chat.md) now works the same way: a session and a pull request.

## Using it

1. Open a workbench's **Analytics** (it must be on) and find **Do these** under the **At session start** bar. The biggest saving is first, and the block's sentence ends with **N changes would cut it to ~X**.
2. Read a row's evidence line. A `CLAUDE.md` row shows an estimate like **−~18.5k**, because a session decides what moves.
3. Press **Turn Off**, **Accept** or **Archive**. **Decline** asks once and is for good.
4. Follow a session row: **Starting a session…**, **Session working** with **Open Session**, **PR #N ready** with **Open PR** and **Show Diff**, then **Merged · measuring**. **Revert…** on a merged row asks first, then starts a session that opens a revert pull request (**Revert session #N**).
5. Open **What's in it** under the list to see each bar split into its sources: tokens at start and calls. Built-in tools say **can't change**.

Measuring starts when a setting is applied, a pull request is merged, or the memory session ends. Session starts in the next 14 days are compared with the 14 days before. The row then reads **Saved 6.1k on 12 starts**, or **No measurable saving**. Done rows stay faded for 14 days, then live in **Accepted edits**.

## When it's empty or wrong

- **No Do these list.** Nothing crossed the thresholds yet, or fewer than five sessions were measured. Sessions recorded before this version count once the history scan rereads them.
- **Changed since — nothing was written.** Claude Code or you changed that key after the proposal was made, so the row closes and nothing is written.
- **Turned back on outside Watchtower.** A running Claude Code wrote its own copy of the settings back. Press **Turn Off Again**.
- **Session is running, but Watchtower could not link it.** The session started, but the proposal was not marked accepted. Press **Retry Link**; Accept stays hidden so a second session never starts.
- **Session ended without a PR** or **Session ended without a change.** Press **Start Again** for a new session, or **Dismiss** to close it. A memory session idle for an hour counts as ended, so later edits in it do not count; use **Start Again**.
- **Session was removed — its PR can't be traced.** The session was deleted before its branch was known. Press **Dismiss**.
- **Not merged.** The pull request was closed, or nothing merged in 30 days. Nothing is measured.
- **"saved settings for this server are gone"** on **Undo**. The copy of the MCP server's settings kept for Undo is missing, so nothing is written. Add the server back in Claude Code yourself.
- **Undo of a memory cleanup drops new lines.** Lines other sessions added to the index while the cleanup ran go too, as the **Undo the memory cleanup?** dialog says. Add them back by hand if you need them.
- **Revert session ended without a PR.** The revert session stopped before opening its pull request. Press **Open Session** to look, or **Revert…** to start a new one.
- **Retry Link** on Home's coach row. A session started but was not linked to the suggestion. Press **Retry Link**; the session itself is in that workbench's **Analytics**.

## Related

- [Agent analytics](agent-analytics.md)
- [Agent coach](agent-coach.md)
- [Tuning chat](tuning-chat.md)

For developers: [docs/features/agent-coach.md](../../features/agent-coach.md)
