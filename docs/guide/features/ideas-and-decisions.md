# Ideas & Decisions

Ideas collects proposals that were floated in Slack threads, meetings, AI chats, Jira and Linear comments and mail but never written down, so they don't get lost. You only triage what it finds, in the [Inbox](inbox.md) under its **Ideas** filter. Decisions are mined by the same pipeline but born settled: they are listed there too, never wait for a verdict (except those found only in your AI chats), and also live in Digests → Decisions.

## Why use it

Someone says "we could cache this per tenant" in a thread, and it is buried by lunch. A day later it sits in the Inbox under **Needs your decision** with the quote, the author and a link back to the thread. You approve it, and a month later a second person raises it again and the new mention lands on the same entry instead of creating a duplicate.

## How it works

<!-- learn
id: ideas-from-chats
title: Judge decisions from your chats
text: Ideas and decisions found in your AI chats wait under **Needs your decision**, marked **· Chat**, for your verdict.
area: planning
level: next
kind: feature
since: next
action: nav:ideas
-->

The registry is filled in two steps, both by the background sync.

1. **Cheap pre-digests.** Slack digests and meeting recaps already pick out ideas and decisions. Mail, Jira and Linear get their own digest passes over recent threads, issues and comments. That pass is the separate **Stream Digests** feature, which runs about every 6 hours.
2. **Consolidation.** A stronger AI pass reads only the new material and your recent verdicts. It proposes new ideas or attaches a repeat mention to an existing one. This pass is the built-in **Idea finder** in Automations → **Built in**: its card has **Turn On** and **Turn Off**, **Every** (hours, 1 to 48, default 6; press **Save**) and **Edit in Chat** if you want it to judge differently. See [Built-in automations](automations-built-in.md). Settings → Features no longer lists Ideas.

It needs the **Idea finder** on (on by default). For mail, Jira and Linear ideas, Stream Digests must also be on. The daemon's regular pass looks only at recent activity; use **Find Ideas in Past Messages…** to reach further back (it does not cover Linear).

Your AI chats are mined too, by the Idea finder, about 30 minutes after a chat goes quiet and only from when you updated Watchtower (older chats are skipped; code question chats never). What it finds from chats alone, decisions included, waits in **Needs your decision** for **Approve**. Until then it stays out of search, the assistant's answers, Catch Up and the Decisions ledger.

A mention of something you rejected, dropped or put on **Not now** brings it back into **Needs your decision** with the reason "brought up again". An exact repeat of a mention it already has does not.

## Using it

### Review what was found

<!-- learn
id: ideas-review
title: Judge the ideas it found
text: Open the Inbox's **Ideas** filter and **Approve**, **Reject** or **Make a Task** from floated ideas.
area: planning
level: basics
kind: feature
since: 0.24.0
action: nav:ideas
-->

<!-- learn
id: ideas-not-now
title: Park an idea with Not now
text: Press **Not now** on an idea to park it; a new mention brings it back under **Needs your decision**.
area: planning
level: next
kind: tip
since: 0.24.0
action: nav:ideas
-->

<!-- learn
id: ideas-merge
title: Merge duplicate ideas
text: Press **Merge…** on an idea to fold a duplicate into it; "Looks similar to #N" suggests one.
area: planning
level: power
kind: tip
since: 0.24.0
action: nav:ideas
-->

Open the Inbox. Ideas and notes waiting for your verdict (and decisions found only in chats), fresh ones and ones brought up again, sit under **Needs your decision** on **All** and **Ideas**. The **Ideas** filter also lists the rest of the registry, newest update first, each row labelled like "Idea · active" or "Decision · superseded", with "· Chat" added for one found in a chat; only merged items are left out.

Click one to see its essence, a thumbs-up and thumbs-down, and every mention with a link back to Slack, the transcript, the mail thread, the Jira issue or the chat (**Open in Chat**; "Chat deleted" once it is gone). The buttons depend on its kind and status:

- **Approve** or **Reject** an item waiting for a verdict. An idea also offers **Make a Task** and **Not now**.
- **Not now** parks an idea for **1 week**, **1 month** or **No date**. The date is only a note: nothing brings it back on that day, only a new mention does. **Activate** returns it.
- **Make a Task** turns an idea into a target and opens it. **Drop** closes it.
- **Merge…** folds duplicates together; "Looks similar to #N" offers a suggested one.
- A decision shows its status, with **Supersede** and **Reverse** while active (**Reverse** asks inline first), or **Activate** when it was rejected, dropped or put off.
- The trash button deletes the item for good, after an inline **Delete**, together with its mentions, its chat and anything merged into it.

Converting or merging never deletes the original; it stays linked to the target or item it became. Deleting a mined entry can let the miner propose it again, so use **Drop** or **Reject** to say no and have it stay said.

### Talk it through

Open **Discuss with assistant** at the bottom of an item to chat about it. Collapsing it or leaving the item doesn't stop a reply in progress.

### Add one yourself

On the **Ideas** filter, press **+** (**New Idea**), choose **Idea** or **Note**, give a **Title** and an **Essence** and press **Create**. It starts active, with no review. A decision is added from Digests → Decisions.

### Save one from the chat

<!-- learn
id: ideas-save-from-chat
title: Save a decision from the chat
text: Start a chat message with **decided:** or **fact:** and it is saved to the registry at once.
area: planning
level: next
kind: feature
since: next
action: nav:chat
-->

Start a message to the assistant with **решили:** or **decided:** and it is saved as a decision. Start it with **факт:** or **fact:** and it is saved as a fact, a note in the registry. The rest of the message is the text. It is active at once, with no review, and the message shows **Saved as a decision** (or **Saved as a fact**) with **Undo** and **Open in Inbox**. **Undo** only works while the item is unchanged. The prefixes do nothing in a code question chat (no mark appears).

### Mine an older period

<!-- learn
id: ideas-past-messages
title: Find ideas in past messages
text: Open **⋯** → **Find Ideas in Past Messages…** on the **Ideas** filter and pick a range to mine.
area: planning
level: power
kind: feature
since: 0.24.0
action: nav:ideas
-->

On the **Ideas** filter, open **⋯** → **Find Ideas in Past Messages…**. Pick **2 weeks**, **Month**, **Quarter** or a range on the calendar, then **Find Ideas**. It keeps running when you close the row or leave the Inbox; a **Mining…** mark next to **+** reopens it, with **Stop**. It ends with a summary or the reason it failed.

Running the same or an overlapping range again never creates duplicates, and decisions found this way go straight to the Decisions ledger.

## When it's empty or wrong

An empty **Ideas** filter says "No ideas yet" and "Ideas and decisions picked up from conversations, every ~6 h", with a status line.

- **Off — Turn on.** Click **Turn on**, or **Turn On** on the Idea finder card.
- **Connect Slack to get this.** The status line follows Slack, even though mail, Jira and meetings also feed it. Connect Slack, or use **Find Ideas in Past Messages…** over a range.
- **Starts after the first sync.** The first sync hasn't finished.
- **Preparing now.** A mining pass is running.
- **Within ~15 min, After this sync.** The next pass is due on the next cycle.
- **In about N h.** The last pass was recent; the line counts whole hours to the next.
- **Didn't work yet — retries automatically.** The last run failed; the reason is in the line.
- **Nothing from mail, Jira or Linear.** Turn on Stream Digests and connect the account.
- **The badge differs from the list.** It counts ideas and notes waiting for a verdict, and decisions found only in your AI chats; never other decisions or items you already judged.

Filter still empty? See [A tab is empty](../troubleshooting/tab-is-empty.md). A parked idea not returning is a [known issue](../troubleshooting/known-issues.md).

## Related

[Inbox](inbox.md) (the :bulb: reaction saves an idea), [Briefings](briefings.md), [Catch Up](catch-up.md).

For developers: [docs/features/ideas-decisions-registry.md](../../features/ideas-decisions-registry.md)
