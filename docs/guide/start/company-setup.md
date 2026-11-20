# Set up Watchtower for your company

One person at a company sets Watchtower up once with the company's own apps for Slack, Google, Atlassian, Linear and Microsoft 365. Everyone else then connects with one link, a code or their Mac's configuration profile. This page is for both: the person setting it up and the colleague connecting.

## Why a company sets it up once

Watchtower ships no Google or Atlassian app of its own for company data: Gmail and Jira need an app your company owns. Without a company setup, every colleague would repeat the same Cloud Console and developer-console steps.

Nothing goes through a Watchtower server. The link opens your own Watchtower on `127.0.0.1`, and every sign-in happens between your Mac and the vendor.

## What a company setup holds
<!-- learn: none -->

A company setup carries the company's name and, for each service it uses, the app's ids: the Slack app, the Google OAuth client and its secret plus the Workspace domain, the Atlassian app and its secret plus the site, the Linear client id, the Microsoft client and tenant ids. It can also carry a **link deny list**: hosts whose links Watchtower never fetches to read into knowledge, such as your intranet. It holds no sign-in of any person.

The Google and Atlassian secrets travel in clear, on purpose. Both apps only send a sign-in back to `127.0.0.1`, so a secret without the person's own consent reads nothing. If one leaks, rotate it and publish again.

The company name is only what people see: renaming it at **Publish** after a check keeps every account tied to the company.

Watchtower stores each company it was given in its data folder under `company/`, readable only by you. Several companies can sit side by side, for example if you consult for two.

## Set up for my company
<!-- learn
id: company-setup-wizard
title: Set Watchtower up for your company
text: **Set up for my company** in **Connections** sets up your company's apps once; colleagues connect with one link.
area: setup
level: next
kind: feature
since: next
action: nav:connections
-->

1. Open **Connections** and press **Set up for my company** under **Companies**, or pick it at the end of the **Connect…** menu. Connections → Slack, the Atlassian banner and the empty Jira page have the same button.
2. On **Services**, tick what your company uses. Only those become steps; anything else connects through [Quick Connections](../features/quick-connections.md).
3. Each service step first lists the apps this Mac already knows under **Found on this Mac**. Pick one to reuse it, or choose **Create new** (Watchtower walks you through the vendor's console) or **We already have one** (paste what identifies it). Watchtower never creates a second app by accident.
4. Google and Atlassian are checked by your own sign-in, which also connects your own account and stores the company setup. Linear and Microsoft 365 are checked without a sign-in. For Atlassian, tick the three settings under **Confirm the app's settings**; Atlassian gives no way to read them.
5. Optionally fill the **Link deny list**, then open **Publish**. Check the **Company name** (colleagues see "Connect <name>?") and press **Publish**. With Slack in the setup, paste a fresh configuration token: Watchtower writes the link and code to the About page of your Slack app and never stores the token.
6. Publish shows the **Connect link**, the **Connect code** and a **Configuration profile for IT**. **Connect this Mac** connects whatever you have not signed in to yet.

You can leave the page at any step: the progress is kept in a draft (secrets included, readable only by you) and the zone shows **Continue setup**. **Discard setup** deletes the draft; accounts you already connected stay.

## Do you need to be an admin
<!-- learn: none -->

No admin rights are needed to start. Google's **Internal** app needs a project in your company's Google Cloud organization, and Microsoft 365 needs a tenant admin's consent: the steps give you a text or link to send them, and Microsoft shows **Waiting** without blocking Publish.

## Connect with your company's link or code
<!-- learn
id: company-connect-code
title: Connect with your company's code
text: Paste your company's code under **Connections → Companies** and press **Connect** to sign in to every service in turn.
area: setup
level: basics
kind: feature
since: next
action: nav:connections
-->

1. Open Watchtower first, then click the link on your company's Slack app About page. Or press **Connect with a company code** under **Companies** (also at the end of the **Connect…** menu) and paste the code.
2. Watchtower asks **Connect <company>?** with a box per service. Nothing is stored before you press **Connect**, so a web page cannot wire your accounts.
3. Each ticked service opens its sign-in in your browser, one after another. **Skip this service** moves on; **Stop** ends the chain. You can close the window: Connections shows where the chain is.

A service you cancelled shows **Not connected** with **Connect** in its company group. Opening the same link again only offers what is not connected yet. Your company may also set the company through your Mac's profile: its card then shows **Managed by your organization** and **Connect all**.

## When your company changes an app

A link that changes a stored company's apps never applies on its own. Watchtower shows **<company>'s link changes its apps** with each change, and **Keep current** is the default. **Replace** stores the new apps; the changed services' accounts show "Re-login needed — <company> changed its app" with **Re-login** (a service the new link drops offers **Paste a company code** instead).

If the company rotated a secret without a new link, the next refresh fails: the row says "Re-login needed — your company changed its app; open the new link". Ask your admin for the new link and paste it. Your data stays in both cases; nothing is deleted for it.

## The Companies zone

The top of **Connections** lists each stored company as a card: how many of its services are connected, what is not, and **Connect the rest**. While a setup is in progress, its first row says where you stopped. Each service's detail then groups its accounts by company, then your own Google project, API tokens or keys, Watchtower's shared app, and **Other accounts**.

## When it doesn't work

- **The browser says it can't connect.** Watchtower was not running. Open it, then click the link again.
- **"Company links cannot reach Watchtower: port 18551 is busy".** Another app holds the port. Paste the company code instead: it saves the company, but its sign-ins wait until you quit the app that holds the port and press **Connect the rest**.
- **The browser shows "This link does not work".** The link is damaged, cut short or too long. Ask your admin for a fresh link or the code.
- **"This link needs a newer Watchtower".** Update Watchtower from its menu, then open the link again.
- **"Another link is waiting".** Answer the open question in Watchtower first.
- **You clicked the link during Watchtower's first-run Setup.** The question waits until Setup ends; a pasted code asks you to finish Setup first.

## Related

- [Sources and accounts](../concepts/sources-and-accounts.md): Watchtower's shared apps and what they still connect.
- [Slack Full](../features/slack-full.md): the Slack app the link lives on.
- [Organization policy for admins](../reference/organization-policy.md): `CompanyBundle` and the profile.

For developers: [docs/features/company-setup.md](../../features/company-setup.md)
