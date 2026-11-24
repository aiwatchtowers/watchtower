# Set up your company's Slack app with the assistant

Press **Connect with Claude** (or Codex) beside **Set up for my company** in **Connections** and the assistant runs the company setup: one vendor page after another in the setup wizard's order (Slack, [Google](company-google.md), [Atlassian](company-atlassian.md), [Linear](company-linear.md), [Microsoft 365](company-microsoft.md)), then the link deny list and Publish on this page. It drives the same draft as the wizard, so you can leave the panel and finish in the wizard, or the other way round. **Agent** steps are the assistant's, **You** steps are yours, **You only** steps are clicks it must leave to you.

## What you get

- Your company's Watchtower app in Slack, created from Watchtower's manifest or an existing one updated; Publish writes the connect link and code to its **About** page, where colleagues click it ([Company setup](../start/company-setup.md)).
- After Publish, the **Connect link**, the **Connect code** and a **Configuration profile for IT**.

## Before you start

- You can make a Slack configuration token for the workspace, once for the app and once for Publish. It is used once and never stored.
- To create the app you need permission to create apps in the workspace. To update an existing Watchtower app you must be one of its collaborators.
- This step sets the app up only; it signs nobody in. **Connect this Mac** after Publish connects your own account.
- The assistant works only on api.slack.com and app.slack.com. It leaves any other page and stops.

## Steps

A Slack problem never ends the run: the other vendor pages go on, and only Publish waits for the Slack app.

1. **Agent:** Call `connect_status` and `company_draft`. The draft holds what the customer chose in the wizard: the company name, the confirmed `services` (empty until confirmed) and Slack's `app` (`new` or `existing`); never ask for those again. With no company name, ask for it (colleagues see "Connect <name>?"); with empty `services`, ask which services the company uses (Slack, Google, Atlassian, Linear, Microsoft 365); save each with `company_draft`. If Slack is not among the services, or its app is ready, go on to the Google page.
2. **Agent:** If Slack's `app` is `new`, Watchtower creates the app: go on to step 3. If it is absent, ask whether the workspace already has a Watchtower app; without one, Watchtower creates it. For an existing app, a set `app_id` is that app: do not ask for it again. Otherwise read its App ID (starts with A, like `A0123ABCD`) from the app list on [api.slack.com/apps](https://api.slack.com/apps) without opening the app's pages, and save it as `app_id` with `company_draft`.
3. **Agent:** Open [api.slack.com/apps](https://api.slack.com/apps), scroll to **Your App Configuration Tokens** and stop there. Call `request_secret` with kind `slack_config_token`. The card asks the customer to leave the page before sending.
4. **You only:** Press **Generate Token** for your workspace, copy the access token into the card, leave Slack's page, then press **Send**.
5. **You:** For an existing app, the panel shows a confirm card listing what the update changes; it turns on Slack's PKCE sign-in, which only Slack support can turn off. Press its confirm button, or decline.
6. **Check:** While `request_secret` says `waiting`, call it again. On `ok` (or `exists`), the app is ready: go on to the Google page. On `cancelled`, `declined`, `timeout` or another result, tell the customer the reason, note it under [If something goes wrong](#if-something-goes-wrong), and go on to the Google page anyway.

## Publish

Run this last, after the Microsoft 365 page.

1. **Agent:** Ask the customer for the link deny list: hosts whose links Watchtower never fetches or reads on its own to add to knowledge, such as the intranet (`intranet.example.com`, no `https://` or path). Save them with `company_draft`, or none.
2. **Agent:** Call `company_draft`. Every service the company uses is checked, or skipped by the customer; Atlassian also needs the customer's three ticks; when Slack is part of the setup, its app is ready. A company without Slack publishes without it: no token, and the result is `no_slack`. Read the company name to the customer and save a change with `company_draft`.
3. **Agent:** Call `company_publish`. The panel shows a confirm card: Publish writes the connect link and code to the Slack app's About page, which the whole company sees.
4. **You:** Read the card and press its confirm button, or decline. A decline writes nothing.
5. **Agent:** With Slack in the setup, after the confirm, open [api.slack.com/apps](https://api.slack.com/apps), scroll to **Your App Configuration Tokens** and stop there. Call `request_secret` with kind `slack_config_token`. Without Slack, skip to step 7.
6. **You only:** Press **Generate Token** for the app's workspace, copy the access token into the card, leave Slack's page, then press **Send**.
7. **Check:** While `company_publish` (or `request_secret`) says `waiting`, call it again. On `ok` or `no_slack`, tell the customer the link, the code and the profile wait on the wizard's Publish page, and **Connect this Mac** connects what they have not signed in to yet. On `cancelled`, `declined`, `timeout` or a failure, tell the customer the reason and stop at [If something goes wrong](#if-something-goes-wrong).

## If something goes wrong

The assistant's panel always offers **Set up by hand**, which opens the setup wizard: the wizard and the panel share one draft.

- **"Your workspace does not let you create apps."** Ask a workspace admin to run the setup, or to allow app creation.
- **"Slack would not let this token change app …"** Make the configuration token in the workspace the app was made in, signed in as one of the app's collaborators, and press **Try again**. If that is not possible, press **Create a new app instead**: Watchtower makes a second app with the same token, and the company link uses that one.
- **"This workspace already has a Watchtower app."** **Create the app** found the app a Slack account on this Mac uses, but not its App ID. Paste it (or a link to it): with the App ID, Watchtower reads that app and shows what **Update the app** would change.
- **"That token did not work: it has expired or is not a configuration token."** Run Slack steps 3–4 again with a fresh token.
- **"Another setup is already running on this Mac."** Wait for it, then run the Slack step again.
- **The update card was declined.** The app was not changed. Create a new app, or run the step again.
- **"Publish waits for the Slack step: finish it, or skip it."** Run the Slack step again, or skip Slack in the wizard.
- **"That is not a host name."** Enter a deny-list host like `intranet.example.com`, without `https://` or a path.
- **"The configuration token has expired, so the link is not on the Slack page yet."** Your setup is kept. Run Publish steps 5–6 again with a fresh token.
- **"That configuration token is for another Slack workspace than the company's app."** Generate one in the app's workspace and run Publish again.
- **"Paste a configuration token to write the link to the Slack page."** The token was missing. Run Publish again.
- **"Could not reach Slack. Your setup is kept."** Check the network and run Publish again.
- **"Publish waits for the Google check: sign in on the Google step, or skip Google."** (or another step). Finish that vendor page, or skip it in the wizard.
- **"… is already the name of another company on this Mac, or of your own Google project."** Choose another name and run Publish again.
- **"Your organization sets this company's name on this Mac, so it cannot be changed here."** Keep the name.
- **"Publish did not go through" or "Publish stopped before it finished", with a reason.** Your setup is kept; try again.
- **A card was cancelled or declined, or the wait ran out** (`timeout`). Nothing was written. Run that step again when you are ready.

```connect
service: company
vendor: slack
domains: api.slack.com, app.slack.com
tools: connect_status, company_draft, company_publish, request_secret
secrets: slack_config_token
```
