# Ideas & Decisions

Ideas collects proposals that were floated in Slack threads, meetings, Jira comments and mail but never written down, so they don't get lost. You only triage what it finds. Decisions are mined by the same pipeline, but they are born settled and live in Digests → Decisions, not here.

## Why use it

Someone says "we could cache this per tenant" in a thread, and it is buried by lunch. A day later it sits in **For review** with the quote, the author and a link back to the thread. You approve it, and a month later a second person raises it again and the new mention lands on the same entry instead of creating a duplicate.

## How it works

The registry is filled in two steps, both by the background sync.

1. **Cheap pre-digests.** Slack digests and meeting recaps already pick out ideas and decisions. Mail and Jira get their own digest passes over recent threads, issues and comments. That pass is the separate **Stream Digests** feature, which runs about every 6 hours.
2. **Consolidation.** About every 6 hours (Settings → Features → **Ideas**, **Mining interval (hours)**, 1 to 48), a stronger AI pass reads only the new material and your recent verdicts. It proposes new ideas or attaches a repeat mention to an existing one.

It needs **Ideas & Decisions** on in Settings → Features (on by default). For mail and Jira ideas, Stream Digests must also be on. The daemon's regular pass looks only at recent activity; use **Find Ideas** to reach further back.

A mention of something you rejected, dropped or put on **Not now** brings it back into **For review** with the reason "brought up again". An exact repeat of a mention it already has does not.

## Using it

### Review what was found

An **Ideas | Notes** switch at the top splits the lists. Each has a **For review** section on top: fresh proposals and ones that were brought up again. A label like "Notes (2)" shows the other side's queue.

Below is the full registry, filterable by status (**Proposed**, **Active**, **Not now**, **Converted**, **Dropped**, **Rejected**, **Merged**) and searchable by title, essence and quote.

Select an item to see its essence, a thumbs-up and thumbs-down, and every mention with a link back to Slack, the transcript, the mail thread or the Jira issue. The buttons depend on its status:

- **Approve** or **Reject** a fresh proposal.
- **Not now** parks it (**1 week**, **1 month** or **No date**). The date is only a note: nothing brings the item back on that day, only a new mention does. **Activate** returns it to the list.
- **Convert to Target** turns an idea into a target. **Drop** closes it.
- **Merge** folds duplicates together. "Looks similar to #N" shows a suggested one.
- The trash button deletes the item for good, after a confirmation, together with its mentions, its chat and anything merged into it.

Converting or merging never deletes the original; it stays linked to the target or item it became. Deleting a mined entry can let the miner propose it again, so use **Drop** or **Reject** to say no and have it stay said.

### Talk it through

Open **Discuss with assistant** at the bottom of an item to chat about it. Collapsing it or leaving the item doesn't stop a reply in progress.

### Add one yourself

Click **Create** (the plus), choose Idea or Note, and give a title and an **Essence**. It starts active, with no review. A decision is added from Digests → Decisions.

### Mine an older period

Click **Find Ideas**, pick **2 weeks**, **Month**, **Quarter** or a custom range, then **Start**. A **Mining…** pill with a timer sits in the header and keeps running if you switch tabs; click it for details or **Cancel**. It ends as a summary or **Mining failed**.

Running the same or an overlapping range again never creates duplicates, and decisions found this way go straight to the Decisions ledger.

## When it's empty or wrong

The empty tab says "No ideas yet" and "Ideas and decisions picked up from conversations, every ~6 h", with **Find Ideas** and **Create** buttons and a status line.

- **Off — Turn on.** Click **Turn on**.
- **Connect Slack to get this.** The tab's status line follows Slack, even though mail, Jira and meetings also feed it. Connect Slack, or use **Find Ideas** over a range.
- **Starts after the first sync, In about N h.** The next consolidation is due; the line counts whole hours.
- **Didn't work yet — retries automatically.** The last run failed; the reason is in the line.
- **Nothing from mail or Jira.** Turn on Stream Digests and connect the account.
- **The badge count differs from the list.** It counts items to review in both Ideas and Notes, never decisions.

## Related

[Inbox](inbox.md) (the :bulb: reaction saves an idea), [Briefings](briefings.md), [Catch Up](catch-up.md).

For developers: [docs/features/ideas-decisions-registry.md](../../features/ideas-decisions-registry.md)
