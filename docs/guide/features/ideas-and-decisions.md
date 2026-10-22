# Ideas & Decisions

Ideas collects proposals that were floated in Slack threads, meetings, Jira and Linear comments and mail but never written down, so they don't get lost. You only triage what it finds, in the [Inbox](inbox.md) under its **Ideas** filter. Decisions are mined by the same pipeline but born settled: they are listed there too, never wait for a verdict, and also live in Digests → Decisions.

## Why use it

Someone says "we could cache this per tenant" in a thread, and it is buried by lunch. A day later it sits in the Inbox under **Needs your decision** with the quote, the author and a link back to the thread. You approve it, and a month later a second person raises it again and the new mention lands on the same entry instead of creating a duplicate.

## How it works

The registry is filled in two steps, both by the background sync.

1. **Cheap pre-digests.** Slack digests and meeting recaps already pick out ideas and decisions. Mail, Jira and Linear get their own digest passes over recent threads, issues and comments. That pass is the separate **Stream Digests** feature, which runs about every 6 hours.
2. **Consolidation.** About every 6 hours (Settings → Features → **Ideas**, **Mining interval (hours)**, 1 to 48), a stronger AI pass reads only the new material and your recent verdicts. It proposes new ideas or attaches a repeat mention to an existing one.

It needs **Ideas & Decisions** on in Settings → Features (on by default). For mail, Jira and Linear ideas, Stream Digests must also be on. The daemon's regular pass looks only at recent activity; use **Find Ideas in Past Messages…** to reach further back (it does not cover Linear).

A mention of something you rejected, dropped or put on **Not now** brings it back into **Needs your decision** with the reason "brought up again". An exact repeat of a mention it already has does not.

## Using it

### Review what was found

Open the Inbox. Ideas and notes waiting for your verdict, fresh ones and ones brought up again, sit under **Needs your decision** on **All** and **Ideas**. The **Ideas** filter also lists the rest of the registry, newest update first, each row labelled like "Idea · active" or "Decision · superseded"; only merged items are left out.

Click one to see its essence, a thumbs-up and thumbs-down, and every mention with a link back to Slack, the transcript, the mail thread or the Jira issue. The buttons depend on its kind and status:

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

### Mine an older period

On the **Ideas** filter, open **⋯** → **Find Ideas in Past Messages…**. Pick **2 weeks**, **Month**, **Quarter** or a range on the calendar, then **Find Ideas**. It keeps running when you close the row or leave the Inbox; a **Mining…** mark next to **+** reopens it, with **Stop**. It ends with a summary or the reason it failed.

Running the same or an overlapping range again never creates duplicates, and decisions found this way go straight to the Decisions ledger.

## When it's empty or wrong

An empty **Ideas** filter says "No ideas yet" and "Ideas and decisions picked up from conversations, every ~6 h", with a status line.

- **Off — Turn on.** Click **Turn on**.
- **Connect Slack to get this.** The status line follows Slack, even though mail, Jira and meetings also feed it. Connect Slack, or use **Find Ideas in Past Messages…** over a range.
- **Starts after the first sync.** The first sync hasn't finished.
- **Preparing now.** A mining pass is running.
- **Within ~15 min, After this sync.** The next pass is due on the next cycle.
- **In about N h.** The last pass was recent; the line counts whole hours to the next.
- **Didn't work yet — retries automatically.** The last run failed; the reason is in the line.
- **Nothing from mail, Jira or Linear.** Turn on Stream Digests and connect the account.
- **The badge differs from the list.** It counts ideas and notes waiting for a verdict, never decisions or items you already judged.

Filter still empty? See [A tab is empty](../troubleshooting/tab-is-empty.md). A parked idea not returning is a [known issue](../troubleshooting/known-issues.md).

## Related

[Inbox](inbox.md) (the :bulb: reaction saves an idea), [Briefings](briefings.md), [Catch Up](catch-up.md).

For developers: [docs/features/ideas-decisions-registry.md](../../features/ideas-decisions-registry.md)
