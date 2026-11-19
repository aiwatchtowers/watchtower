# Slack Full through your workspace's app

Full is Slack synced onto your Mac through your company's own Watchtower app in Slack. One person sets the app up once; everyone else connects from the app's page in Slack. This page is for both: the person who sets it up and the colleagues who connect.

## Why use it

Digests, Tracks, People, Catch-Up and the Inbox need Slack synced, and only Full syncs. Live, your Claude or ChatGPT connector, answers in **Chats** but keeps nothing ([Live Slack](../concepts/sources-and-accounts.md#live-slack-through-your-claude-or-chatgpt-account)). A workspace's own app also syncs at Slack's normal speed; the old shared Watchtower app gets one history request a minute.

## How it works

- **The app lives in your workspace.** The setup creates an app called Watchtower in your Slack workspace, with user permissions only and no bot. Its **About** page carries the connect link and a connect code. Nothing depends on the setup person's Mac afterwards.
- **The link comes back to your Mac.** The link opens `127.0.0.1:18551` on your own Mac, so Watchtower must be open when you click it. Slack's sign-in page opens in your browser and then returns to Watchtower; no Watchtower server is in between.
- **No app secret is kept.** Watchtower keeps only your own Slack sign-in, on your Mac; never the app's secret, never the setup token.
- **Your sign-in renews itself.** Slack's sign-in expires every 12 hours and Watchtower renews it in the background. A Mac that stays off for about 30 days loses the sign-in; the account row then asks you to **Re-login**.
- **Which mode you are in** shows at the top of **Connections → Slack**: **Full**, **Full · Live on**, **Live**, **Off** or **Shared app**.

## Using it

### Set up Slack for your company
<!-- learn
id: slack-full-company-setup
title: Set up Slack for your whole company
text: Paste one Slack configuration token in **Connections → Slack** to create Watchtower's app for every colleague.
area: setup
level: power
kind: feature
since: next
action: nav:connections
-->

You need permission to create apps in your Slack workspace.

1. Open **Connections → Slack** and press **Set up for my company**.
2. Press **Open Slack's token page**. Under **Your App Configuration Tokens**, press **Generate Token** for your workspace and copy the access token.
3. Paste it and press **Create the app**. Watchtower checks the token, creates the app, writes the connect link to its **About** page and connects your own Slack account.
4. Tell colleagues to open Watchtower in Slack, go to **About** and click the link.

The token is used for this setup only and never stored. You can close the window: the setup goes on, and **Connections → Slack** shows where it got to with **Continue setup**. The app is never created twice.

**Your company already has a Watchtower app** (one you connect through today): the sheet says "Watchtower's app already exists in …". Paste the token again and press **Update the app**. Watchtower adds the connect link and the sign-in settings it needs and keeps everything else on the app. The update also turns on Slack's PKCE sign-in for the app, which cannot be undone, and Slack may ask colleagues already connected to allow Watchtower again. You must be one of the app's collaborators, and Watchtower may ask for its **App ID** from the app's Basic Information page. If your Watchtower already signs in through that app, the sheet says "This version of Watchtower signs in to … through this app already" and changes nothing: the app moves to the new sign-in with a later Watchtower update.

### Connect from the app's About page
<!-- learn
id: slack-full-connect-link
title: Connect Slack from your company's app
text: Open Watchtower in Slack, go to **About** and click the connect link; Watchtower finishes the sign-in.
area: setup
level: basics
kind: feature
since: next
action: nav:connections
-->

1. Open Watchtower on your Mac.
2. In Slack, open the Watchtower app, go to **About** and click the connect link.
3. Watchtower comes forward and asks "Connect a Slack workspace?". Press **Connect** only if you clicked the link yourself.
4. Allow Watchtower on Slack's page in your browser. Watchtower says "Connected to …" and the first sync starts.

### Paste a connect link or code

When the link does not open, copy it, or the connect code under it (`T…:1234.5678`), into **Connect link or code** in **Connections → Slack** and press **Connect**. Your browser opens Slack's page at once, without the question. With Slack already in Full, the field sits behind **Connect another workspace…**.

### Workspaces your organization set up

If your company deploys Watchtower with a configuration profile, **Connections → Slack** lists **Set up by your organization** with a **Connect** per workspace. One press opens Slack's page. Admins: see `SlackApps` in [Organization policy for admins](../reference/organization-policy.md).

### Move off the shared Slack app

An account connected through Watchtower's old shared app keeps syncing until Slack turns that app off. A banner says "Watchtower's shared Slack app is retiring", and the account row shows **Shared app**. Connect the same workspace through your company's app (**Set up for my company** or **Paste a connect link**), or use Live instead. Connecting moves the same account: its messages, digests and history stay. Sign in as the same Slack person: another sign-in stops with "signed in as someone else; nothing was changed". Once your build no longer includes the shared app, the row's button reads **Move to Full** and opens the same connect section.

## When it's empty or wrong

- **"The connect link cannot reach Watchtower: port 18551 is busy."** Another app holds the port, and Slack only returns to that port, so pasting cannot finish either. Quit that app, then open **Connections → Slack** again.
- **The browser says it cannot connect** after you click the link: Watchtower is not open. Open it and click again.
- **"Slack signed you in to a different workspace than the link names."** Switch to that workspace on Slack's page, then **Start again**.
- **Slack says your admin must approve the app.** Watchtower keeps waiting with **Cancel**; connect again once they approve.
- **"Your workspace does not let you create apps."** Press **Copy a note for your admin** and send it to an admin; it links here.
- **"Your token cannot change this app."** Ask one of the app's collaborators (its Collaborators page lists them) to run the setup.
- **"The app's About page has no connect link yet."** The token expired mid-setup. Press **Add the link to the app** and paste a fresh token.
- **"Slack did not answer when Watchtower asked it to create the app."** Look for Watchtower on api.slack.com/apps. Found: enter its **App ID** and **Client ID** and press **Use this app**. Not there: **Start again**.
- **A sign-in expired** ("Sign in again: the Slack sign-in expired"): press **Re-login** on the row and allow Watchtower again.
- **The banner names one account** while several use the shared app: every such row carries the **Shared app** tag.

## Related

- [Sources and accounts](../concepts/sources-and-accounts.md)
- [Organization policy for admins](../reference/organization-policy.md)
- [An account needs attention](../troubleshooting/account-needs-attention.md)

For developers: [docs/features/slack-full.md](../../features/slack-full.md)
