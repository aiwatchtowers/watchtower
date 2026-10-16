# Mail

Watchtower reads your inbox so that mail someone sent you shows up beside Slack and Jira in the places that tell you what needs you. It has no mail tab and never sends or changes mail. It works with Gmail, Outlook and any IMAP mailbox, and you can connect several accounts.

## Why use it

A customer emails you a question on Tuesday and your Slack is quiet. Because the message reaches your Inbox, Catch Up and the briefing, it does not wait until you open your mail client.

## How it works

### What gets synced

Every sync cycle (every 15 minutes by default) the daemon pulls new mail for each connected account, after Slack and calendars. A first sync fetches the last 7 days. Watchtower then backfills about a month of older mail in the background; see [Sources and accounts](../concepts/sources-and-accounts.md).

- **Gmail:** the Inbox only. Messages in the Promotions and Social categories are skipped before any AI sees them.
- **Outlook and IMAP:** the one folder you set, `INBOX` unless you changed it.
- Each cycle takes at most 100 messages per account, oldest first, so the rest follows on the next cycle.
- Message bodies are cut at about 50 KB.

### Where mail shows up

- **Inbox:** a message addressed to you (you are in To) becomes an item, like a Slack mention. A message that only copies you (Cc) becomes a lower-priority item. A message from you mints nothing.
- **Catch Up and briefing:** both include your pending Inbox items. Catch Up also reads the Gmail stream digests described below.
- **Ideas:** with **Stream Digests** on (**Settings › Features**), new Gmail threads are summarized per account, and ideas and decisions mined from them reach the Ideas registry. Stream Digests is a medium AI cost.
- **Memory:** Gmail is a Memory source, off by default.

An Inbox item for mail is not closed by your reply. Slack, Jira and calendar items resolve themselves; mail items stay until you handle them in Inbox.

## Using it

1. Open **Settings › Connections**.
2. For Gmail with Calendar, use **Google** and click **Add Google Account**. Leave **Gmail** switched on and click **Connect**.
3. For Gmail on its own, Outlook or another IMAP mailbox, use **Email** and click **Add Account**. Choose **Connect Gmail**, **Connect Outlook** or fill in the **IMAP** form (host, username, password, folder) and click **Test and Connect**.
4. Wait for the next sync, or open **Inbox** after a cycle.

Switch Gmail syncing off for all Google accounts with **Enable Gmail sync** under **Settings › Connections › Google**. Remove one account with **Remove**.

## When it's empty or wrong

- **No mail in Inbox:** only messages that name you are shown. Check that **Enable Gmail sync** is on and that the account is listed. The first items appear after the first sync.
- **Missing a newsletter or promotion:** Gmail Promotions and Social are skipped on purpose.
- **Missing mail from a folder other than Inbox:** Gmail reads the Inbox only, and IMAP reads the single folder from the form.
- **Account shows an error:** use **Re-login** on the Google account to sign in again. For IMAP, remove the account and add it again.
- **Old mail is missing:** only the last 7 days sync first. Older mail arrives with the background history backfill.

## Related

- [Calendar and meeting prep](calendar-and-meeting-prep.md) — the calendar side of a Google account.

For developers: [docs/features/google-multi-account.md](../../features/google-multi-account.md)
