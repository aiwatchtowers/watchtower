# Connect mail with the assistant

Press **Connect with Claude** (or Codex) in **Connections → Email** and the assistant connects an Outlook account or any IMAP mailbox. It fills the mailbox settings and starts the sign-in; you sign in, or type the password into a secure card it never sees. This page is the assistant's script: **Agent** steps are its own, **You** steps are yours, **You only** steps are the customer's alone.

## What you get

- Mail sent to you as attention items in Catch Up, the briefing and the Inbox's **Waiting for me** ([Mail](../features/mail.md)).
- Several mailboxes: run it once per account.
- Gmail connects through Google instead: [Connect Google with the assistant](google.md) or your own Google project.

## Before you start

- Watchtower stays open on this Mac: Outlook's sign-in returns to it on `127.0.0.1`.
- For Outlook, you can sign in to the Microsoft account. Some company tenants ask an admin to approve Watchtower first.
- For IMAP, you know the mailbox's username and password. Many providers want an app password made on their site instead of your normal one.
- Your organization's policy allows Email. A blocked Email shows **Blocked by your organization** and the assistant cannot connect it.
- The assistant reads only support.microsoft.com, support.google.com and support.apple.com, to look up a provider's IMAP server. It leaves any other page and stops.

## Steps

Pick one path after step 1: Outlook (steps 2–4) or IMAP (steps 5–8).

1. **Agent:** Call `connect_status`. If Email is blocked by the organization, say so and stop. If a flow is running, wait for it with `connect_wait` or ask the customer whether to `connect_cancel` it. Ask the customer whether the mailbox is Outlook (Microsoft 365, Outlook.com) or another provider. For Gmail, switch to the Google page.
2. **Agent:** Call `connect_start` with `outlook`. Watchtower opens Microsoft's sign-in page in the default browser.
3. **You:** Sign in to Microsoft (2FA included) and press **Accept** on the permissions page.
4. **Check:** Call `connect_wait`; while it says `waiting`, call it again. On `connected`, go on; on `failed` or `timeout`, tell the customer the reason and stop at [If something goes wrong](#if-something-goes-wrong). Then call `connect_status` to confirm the account.
5. **Agent:** Find the provider's IMAP server on its help pages, or ask the customer. Call `set_fields` with `host`, `port` (usually `993`), `security` (`ssl`, `starttls` or `none`; usually `ssl`), `username` and `folder` (usually `INBOX`).
6. **Agent:** Call `request_secret` with kind `imap_password`. If the provider wants an app password, tell the customer where its help page says to make one; do not open that page yourself.
7. **You only:** Make the app password on the provider's site if it needs one, copy the password into the card, leave that page, then press **Send**. Watchtower tests the mailbox before it saves anything.
8. **Check:** `request_secret` returns the result once the test ends. On success, call `connect_status` to confirm the account and tell the customer the first sync has started. On a failure, tell the customer the reason and stop at [If something goes wrong](#if-something-goes-wrong).

## If something goes wrong

The assistant's panel always offers **Set up by hand**, which opens **Connections → Email**.

- **Blocked by your organization** (`connect_start` answers `policy`). Your organization does not allow Email. Ask your IT team.
- **"Another connection is already in progress."** (`busy`). Another mail connect is running. Wait for it, or cancel it, then start again.
- **"imap add: connection test failed" with a reason.** The server, port, security or password is wrong, or the provider wants an app password. Check them on the provider's help page and run the IMAP path again.
- **Microsoft's page says an admin must approve the app.** Your tenant lets only an admin allow Watchtower. Ask your IT admin, or your company's [setup](../start/company-setup.md) brings its own Microsoft app.
- **The sign-in page was closed, or the wait ran out** (`timeout`). Nothing was connected. Start again.
- **"Login failed" or "Connect failed" with a message.** The assistant reads you the message. Try again, or use **Set up by hand**.
- **The secure card was cancelled.** Nothing was saved. Start the IMAP path again when you are ready.

```connect
service: email
domains: support.microsoft.com, support.google.com, support.apple.com
tools: connect_status, connect_start, connect_wait, connect_cancel, set_fields, request_secret
secrets: imap_password
options: outlook
```
