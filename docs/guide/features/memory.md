# Memory

Memory is the assistant's long-term notebook about your work: a page per person, channel and project, plus short notes of what actually happened, each linked back to the real messages. It is off until you turn it on, and it is for anyone who wants answers and briefings that start with context instead of a blank slate.

## Why use it

Without memory the assistant sees recent messages. With it, "who owns the deploy pipeline?" or "what did we settle with Alice last month?" has a place to be answered from, and every note can be opened back at its source. Memory does not change how digests work.

## How it works

**Plain files you can read.** The memory is markdown files in a git repository in your workspace folder (`memory/`). The files are the memory; the app's database only keeps a search index, which can be rebuilt from them at any time. Open the folder in Obsidian or any editor if you like. Before each run Watchtower saves your manual edits as a separate "owner edit" entry, so nothing you wrote is overwritten and history shows who changed what.

**How it fills itself.** Each daemon cycle, after inbox detection and the ideas phase, one consolidation pass seeds skeleton pages (a person needs about 20 messages in the last 30 days) and extracts notable episodes from channel history in bounded chunks, so a long backlog is worked off gradually. While the history backfill of a new source is still running, memory waits and does nothing, so expect no pages for the first stretch after connecting a source. Every message link is validated before a note is written.

**Beyond Slack.** In **Settings → Features → Memory → Advanced** each switch below is off by default.

- **Semantic tier**: rewrites entity pages as episodes arrive, merges duplicates, archives cold history into rollups, and forms **beliefs** ("Alice owns the deploy pipeline") whose confidence rises and falls with evidence. Reflection, belief changes in the briefing, and "remember this:" all need it.
- **Gmail source**: each email thread becomes one episode; senders become person pages (matched to Slack colleagues by email).
- **Calendar source**: each ended meeting becomes one episode, with its recap folded in when one exists. Capture happens on the first memory run after the meeting ends.
- **Jira source**: episodes from Jira issues.
- **Chats source**: lets a target's or track's chat pin a fact. Start a line with `remember this:` (or `remember:`); the rest becomes your own recorded statement. Without the prefix a chat turn is treated as drafting and never becomes memory. It also needs the **Chat surface** switch and the Semantic tier.
- **Targets & Tracks mirrors**: each target and track gets a page with status, next step and an **Open loops** list, kept in sync and cleared when done. Nothing is written back into your targets.

**Where memory reaches you.** Five **surface** switches decide whether memory may show up elsewhere:

- **Chat surface**: the AI Chat starts with a short map of what memory holds and can look things up.
- **Briefing surface**: the briefing may add a short *Memory revisions* note when a belief clearly changed. Nothing worth saying, nothing shown.
- **Reflection surface**: about once a week the assistant reviews its own history and marks beliefs that keep flip-flopping as disputed. It never changes a confidence by itself.
- **Day Plan surface**: folds open loops from memory into the day plan. It has little to add until Targets & Tracks mirrors is also on.
- **Meeting Prep surface**: adds what memory knows about each attendee, framed as the assistant's notes. An attendee with no page is skipped.

## Using it

1. Turn on **Memory** in **Settings → Features** (setup turns it on if you pick the **Work communication** goal). Add the sources and surfaces you want.
2. Open the **Memory** tab. Search the pages and beliefs, and sort by **Recent** or **Important**. Select one to see its links, history and importance.
3. Click **Edit** on a page to change it. The next memory run saves your change as an owner edit; keep the frontmatter lines intact, or the file is skipped (not deleted).
4. Click **Focus** to steer ranking. Under **Now**, list people, channels or projects as `- ` bullets to rank them higher; under **Cooled**, lower. A bullet matches a page whose name or title contains it, so keep bullets specific. It applies on the next run and only while focus is on. It is off by default; turn it on with `watchtower config set memory.focus.enabled true`.
5. From a terminal: `watchtower memory status` shows counts and the remaining backlog, `watchtower memory recall <query>` searches, `watchtower memory consolidate` runs a pass now, and `watchtower memory reindex` rebuilds the search index.

## When it's empty or wrong

- **The tab says "Nothing remembered yet".** Memory is off (use **Turn on**), or it has not run yet. Check `watchtower memory status`. Remember it waits for any running history backfill, and a person needs about 20 recent messages to get a page.
- **A belief shows "Dispute pending".** The memory marked it unsettled: it keeps flip-flopping or new evidence contradicts something you said. The Memory tab badge counts these marks; nothing else brings them to you. Settle it by editing the page, or pin the right fact with `remember this:` in a target or track chat (see the Chats source).
- **A note looks wrong.** Open its sources through the links; edit the page if needed. Treat memory as notes the assistant built, possibly out of date, not as your own words.
- **A switch seems to do nothing.** Reflection, belief revisions and `remember this:` need the Semantic tier. The Day Plan surface needs Targets & Tracks mirrors.

Tab still empty? See [A tab is empty](../troubleshooting/tab-is-empty.md).

## Related

- [AI Chat](ai-chat.md)

For developers: [docs/features/memory.md](../../features/memory.md)
