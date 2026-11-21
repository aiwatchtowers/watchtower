# Set up your company's Slack app with the assistant

Press **Connect with Claude** (or Codex) beside **Set up for my company** in **Connections** and the assistant runs the company setup: one vendor page after another in the setup wizard's order (Slack, [Google](company-google.md), [Atlassian](company-atlassian.md), [Linear](company-linear.md), [Microsoft 365](company-microsoft.md)), then Publish on this page. It drives the same draft as the wizard, so you can leave the panel and finish in the wizard, or the other way round. **Agent** steps are the assistant's, **You** steps are yours, **You only** steps are clicks it must leave to you.

## What you get

- Your company's Slack app picked for the setup; Publish writes the connect link and code to its **About** page, where colleagues click it ([Company setup](../start/company-setup.md)).
- After Publish, the **Connect link**, the **Connect code** and a **Configuration profile for IT**.

## Before you start

- The workspace's Watchtower app was created or updated from this Mac: with [Connect Slack with the assistant](slack.md) or the wizard's Slack step. This page picks it; it does not create it.
- For Publish you can make a Slack configuration token for the app's workspace. It is used once and never stored.
- The assistant works only on api.slack.com and app.slack.com. It leaves any other page and stops.

## Steps

1. **Agent:** Call `connect_status` and `company_draft`. If the draft has no company name, ask the customer for it (colleagues see "Connect <name>?") and save it with `company_draft`. Ask which services the company uses and save them with `company_draft`. If Slack is not among them, go on to the Google page.
2. **Agent:** If the draft already holds a Slack app, go on to the Google page. Otherwise ask the customer whether the workspace's Watchtower app was created or updated from this Mac. If not, tell them to run **Connect Slack with the assistant** in **Connections → Slack** first, and stop.
3. **Agent:** On api.slack.com/apps, open the Watchtower app and read its App ID and, under **App Credentials**, its Client ID. Never press **Show** on a secret there. Save the app's settings link (`https://api.slack.com/apps/` plus the App ID) and the Client ID with `company_draft`.
4. **Check:** Call `company_draft` again: the Slack app is there. If the draft did not take it, this Mac has no setup of that app; go back to step 2. Then go on to the Google page.

## Publish

Run this last, after the Microsoft 365 page.

1. **Agent:** Call `company_draft`. Every service the company uses is checked, or skipped by the customer; Atlassian also needs the customer's three ticks. Read the company name to the customer and save a change with `company_draft`.
2. **Agent:** Call `company_publish`. The panel shows a confirm card: Publish writes the connect link and code to the About page of the company's Slack app, which the whole company sees.
3. **You:** Read the card and press its confirm button, or decline. A decline writes nothing.
4. **Agent:** With Slack in the setup, after the confirm, open api.slack.com/apps, scroll to **Your App Configuration Tokens** and stop there. Call `request_secret` with kind `slack_config_token`. Without Slack, skip to step 6.
5. **You only:** Press **Generate Token** for the app's workspace, copy the access token into the card, leave Slack's page, then press **Send**.
6. **Check:** While `company_publish` (or `request_secret`) says `waiting`, call it again. On `ok` or `no_slack`, tell the customer that the link, the code and the profile wait on the wizard's Publish page, and that **Connect this Mac** connects what they have not signed in to yet. On a failure, tell the customer the reason and stop at [If something goes wrong](#if-something-goes-wrong).

## If something goes wrong

The assistant's panel always offers **Set up by hand**, which opens the setup wizard: the wizard and the panel share one draft.

- **The draft has no Slack app.** Run **Connect Slack with the assistant** from this Mac first, or use the wizard's Slack step with **Create the app** or **Update the app**.
- **"The configuration token has expired, so the link is not on the Slack page yet."** Your setup is kept. Run Publish steps 4–5 again with a fresh token.
- **"That configuration token is for another Slack workspace than the company's app."** Generate one in the app's workspace and run Publish again.
- **"Paste a configuration token to write the link to the Slack page."** The token was missing. Run Publish again.
- **"Could not reach Slack. Your setup is kept."** Check the network and run Publish again.
- **"Publish waits for the Google check: sign in on the Google step, or skip Google."** (or another step). Finish that vendor page, or skip it in the wizard.
- **"… is already the name of another company on this Mac, or of your own Google project."** Choose another name and run Publish again.
- **"Your organization sets this company's name on this Mac, so it cannot be changed here."** Keep the name.
- **"Publish did not go through" or "Publish stopped before it finished", with a reason.** Your setup is kept; try again.
- **The confirm card was declined, or the wait ran out** (`timeout`). Nothing was written. Run Publish again when you are ready.

```connect
service: company
vendor: slack
domains: api.slack.com, app.slack.com
tools: connect_status, company_draft, company_publish, request_secret
secrets: slack_config_token
```
