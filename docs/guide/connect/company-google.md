# Set up your company's Google app with the assistant

The Google step of the company setup: the assistant builds your company's Google Cloud project for Gmail and Calendar, saves its Client ID in the setup and checks it with your sign-in. You make the one click that shows the client secret and type it into a secure card it never sees. It runs after the Slack page, in the order of [Set up your company's Slack app with the assistant](company-slack.md). **Agent** steps are the assistant's, **You** steps are yours, **You only** steps are clicks it must leave to you.

## What you get

- Colleagues connect Gmail and Calendar through the company's own project, with one link or code ([Company setup](../start/company-setup.md)).
- Your own Google account connected: the check signs you in.

## Before you start

- An **Internal** app needs the project inside your company's Google Cloud organization; making one there needs the Project Creator role. Without it, your Google Workspace admin makes the project (the wizard's **Copy the steps for your admin**).
- You can sign in with your company Google account. Watchtower stays open on this Mac: the check's sign-in returns to it on `127.0.0.1`.
- The assistant works only on console.cloud.google.com. Google's sign-in page is yours alone. It leaves any other page and stops.

## Steps

1. **Agent:** Call `connect_status` and `company_draft`. If the draft has no company name, ask the customer for it (colleagues see "Connect <name>?") and save it with `company_draft`. If `services` is empty (the customer has not confirmed the wizard's Services step), ask which services the company uses (Slack, Google, Atlassian, Linear, Microsoft 365) and save them with `company_draft`. If Google is not among the draft's `services` (what the customer chose; never ask again), go on to the next vendor page. If the draft already holds a Google Client ID with `client_secret_set`, go to step 8.
2. **Agent:** On [console.cloud.google.com](https://console.cloud.google.com), open the new-project page, put the project inside the company's organization, name it `watchtower`, submit the form and wait until the console selects it. If the organization is not offered, stop at [If something goes wrong](#if-something-goes-wrong).
3. **Agent:** In the API library, turn on the Gmail API and the Google Calendar API for that project.
4. **Agent:** Open the OAuth consent screen: user type **Internal**, app name Watchtower, the customer's address as support and contact email.
5. **Agent:** Open **Credentials**, start **Create credentials → OAuth client ID**, set the type to **Desktop app** and the name to Watchtower, and stop before the form's last button. Call `request_secret` with kind `google_client_secret`. The card asks the customer to close Google's result window before sending.
6. **You only:** Press **Create**, copy the client secret from the dialog into the assistant's card, close the dialog, then press **Send**. The secret goes into the setup's draft on this Mac.
7. **Agent:** While `request_secret` says `waiting`, call it again; on `cancelled` or `timeout`, tell the customer and stop at [If something goes wrong](#if-something-goes-wrong). Then, on the **Credentials** page, read the new client's Client ID from the OAuth 2.0 Client IDs list; never open its secret. Save it with `company_draft`.
8. **Agent:** Call `company_check` with vendor `google`. Watchtower opens Google's sign-in in the browser; the sign-in checks the client and connects the customer's own Google account.
9. **You:** If the panel says the company's stored Google app will be replaced, press its confirm button or decline. Then sign in with your company Google account and approve Gmail and Calendar.
10. **Check:** While `company_check` says `waiting`, call it again. On `ok`, tell the customer "Connected as" with the address and go on to the next vendor page; on any other result, tell the customer the reason and stop at [If something goes wrong](#if-something-goes-wrong).

## If something goes wrong

The assistant's panel always offers **Set up by hand**, which opens the setup wizard: the wizard and the panel share one draft.

- **"An Internal app needs your company's Google Cloud organization".** You cannot make a project there, or Internal is not offered. Ask your Google Workspace admin to make the project or give you the Project Creator role; drop the client JSON they send into the wizard's Google step.
- **"Watchtower needs your company's name before this check".** Tell the assistant the name and run the check again.
- **"Google does not accept this client" with a code.** The Client ID or the secret is wrong. Check the Client ID on **Credentials**, or make a new client (step 5).
- **The dialog closed before you copied the secret.** Google shows it only there. Make a new client and copy its secret.
- **"Could not reach Google" with a reason.** Nothing was saved. Check the network and run the check again.
- **"The sign-in did not finish". Nothing was saved.** Run the check again.
- **"The sign-in worked, but Watchtower could not record the check in this setup".** Your account stays connected; run the check again.
- **"The check stopped before it answered."** Nothing was saved; run it again.
- **The Replace card was declined.** The stored Google app stays and nothing changed. Stop, or set the company up under another name.
- **"Your organization sets <company>'s apps on this Mac".** A configuration profile sets this company; what you set up is used once the profile is removed.
- **"Watchtower could not save the setup's progress on this Mac, so nothing was checked."** Try again.
- **The secret card was cancelled** (`cancelled`), **or a wait ran out** (`timeout`). Nothing was saved. Run the step again when you are ready.

```connect
service: company
vendor: google
domains: console.cloud.google.com
tools: connect_status, company_draft, company_check, request_secret
secrets: google_client_secret
```
