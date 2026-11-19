# Mail

Watchtower reads your inbox so that mail someone sent you shows up beside Slack and Jira in the places that tell you what needs you. It has no mail tab and never sends or changes mail. It works with Gmail, Outlook and any IMAP mailbox, and you can connect several accounts.

## Why use it

A customer emails you a question on Tuesday and your Slack is quiet. Because the message becomes an attention item, it turns up in Catch Up and the briefing instead of waiting until you open your mail client.

## How it works

### What gets synced

Every sync cycle (every 15 minutes by default) the daemon pulls new mail for each connected account, after Slack and calendars. A first sync fetches the last 7 days. Watchtower then backfills about a month of older mail in the background; see [History backfill](../concepts/history-backfill.md).

- **Gmail:** the Inbox only. Messages in the Promotions and Social categories are skipped before any AI sees them.
- **Outlook and IMAP:** the one folder you set, `INBOX` unless you changed it.
- Each cycle takes at most 100 messages per account, oldest first, so the rest follows on the next cycle.
- Message bodies are cut at about 50 KB.

### Where mail shows up

<!-- learn
id: mail-attention-waiting
title: See mail that names you
text: Mail sent to you becomes an attention item in Catch Up, the briefing and the Inbox's **Waiting for me**.
area: communication
level: next
kind: tip
since: 0.28.0
replaces: [mail-attention]
changed: The Inbox's Messages filter became Waiting for me.
action: nav:inbox
-->

- **Attention items:** a message addressed to you (you are in To) becomes an item, like a Slack mention. A message that only copies you (Cc) becomes a lower-priority item. A message from you mints nothing.
- **Where you see them:** the Inbox's **Waiting for me** lists them with your Slack and tracker items ([Inbox](inbox.md)). They also surface in **Catch Up** (needs you), the briefing and meeting prep. Catch Up also reads the mail stream digests described below.
- **Ideas:** with **Stream Digests** on (**Settings → Features**), new mail is summarized per account (Gmail by thread, Outlook and IMAP message by message), and ideas and decisions mined from it reach the Ideas registry. Stream Digests is a medium AI cost.
- **Memory:** Gmail is a Memory source, off by default.

Your reply does not close a mail item. Slack, Jira and calendar items resolve when you answer; mail items instead archive on their own, after 14 days if you are in To and after 7 days if you are in Cc.

## Using it

<!-- learn
id: mail-connect-gmail
title: Bring your Gmail in
text: Connect Gmail in **Connections → Google** through your company's Google project or your own; mail to you joins Slack and Jira.
area: communication
level: basics
kind: feature
since: 0.24.0
action: connect:google
-->

<!-- learn
id: mail-connect-imap
title: Connect Outlook or an IMAP mailbox
text: Under **Email** in **Connections**, click **Add Account** and pick **Connect Outlook** or **IMAP**.
area: communication
level: next
kind: feature
since: 0.24.0
action: connect:imap
-->

1. Open **Connections**.
2. For Gmail, use **Google**. With a [company setup](../start/company-setup.md), your company's group offers **Connect**. Otherwise click **Use my own Google project**: the page walks you through a Google Cloud project of your own (about ten minutes, once), then you drop its client JSON and click **Connect**. **Connect Google Calendar** adds Calendar alone through Watchtower's app. **Connect Gmail** under **Email → Add Account** brings you here too, straight to the own-project page when no company setup has a Google app.
3. For Outlook or another IMAP mailbox, use **Email** and click **Add Account**. Choose **Connect Outlook** or fill in the **IMAP** form (host, username, password; port, security and folder wait under **Advanced** with the usual 993, SSL and `INBOX`) and click **Test and Connect**.
4. Wait for the next sync cycle, then check **Catch Up** or the next briefing.

Switch Gmail syncing off for all Google accounts with **Enable Gmail sync** under **Connections → Google**. Remove one account with **Remove**.

## When it's empty or wrong

- **No mail in Catch Up or the briefing:** only messages that name you become items. Check that **Enable Gmail sync** is on and that the account is listed. The first items appear after the first sync.
- **Missing a newsletter or promotion:** Gmail Promotions and Social are skipped on purpose.
- **Missing mail from a folder other than Inbox:** Gmail reads the Inbox only, and IMAP reads the single folder set under **Advanced** in the form.
- **Account shows an error:** use **Re-login** on the Google account to sign in again. For IMAP, remove the account and add it again.
- **Gmail needs your company's or your own Google project:** Watchtower's shared Google app connects Calendar only. Open your company's Watchtower link, or connect the account with your own Google project. A Gmail account already connected through the shared app keeps syncing until Google stops its sign-in; then its row offers **Use my own Google project** instead of **Re-login**, and signing in with the same address moves the account onto your project.
- **Google says "Google hasn't verified this app":** expected on your own project. Check that the screen names the project you created (cancel if not), then choose **Advanced** and go on to it.
- **Use my own Google project is missing:** your organization does not allow own projects. Accounts already on one say "Stopped by your organization — data kept"; ask IT for your company's link.
- **Mail I deleted is still here:** Gmail checks once a day for deleted or trashed mail, and IMAP checks on every sync. Archived Gmail stays.
- **Old mail is missing:** only the last 7 days sync first. Older mail arrives with the background history backfill.

Account error? See [An account needs attention](../troubleshooting/account-needs-attention.md).

## Related

- [Calendar and meeting prep](calendar-and-meeting-prep.md) — the calendar side of a Google account.

For developers: [docs/features/google-multi-account.md](../../features/google-multi-account.md)
