# Connect your own Google project with the assistant

Press **Connect with Claude** (or Codex) beside **Use my own Google project** in **Connections → Google** and the assistant builds a Google Cloud project of your own for Gmail and Calendar, then connects your account through it. It works in Google Cloud Console; you make the one click that shows the client secret, type it into a secure card it never sees, and sign in. This page is the assistant's script: **Agent** steps are its own, **You** steps are yours, **You only** steps are clicks it must leave to you.

## What you get

- Gmail and Calendar through a project only you use, with no company setup ([Mail](../features/mail.md)).
- The project stays yours: other Google accounts of yours can use it later.

## Before you start

- About ten minutes, once. Watchtower stays open on this Mac: Google's sign-in returns to it on `127.0.0.1`.
- You can sign in to Google Cloud Console with the Google account you connect. A company account may not be allowed to make projects; your company's [setup](../start/company-setup.md) is the way then.
- Your organization allows own projects. Without that, **Use my own Google project** is gone and the assistant cannot help.
- The assistant works only on console.cloud.google.com. Google's sign-in page is yours alone. It leaves any other page and stops.

## Steps

1. **Agent:** Call `connect_status`. If own projects are blocked by the organization, say so and stop. If a flow is running, wait for it with `connect_wait`. Ask the customer for the Google address they connect.
2. **Agent:** On console.cloud.google.com, open the new-project page, name the project `watchtower` plus a short word of the customer's, submit the form and wait until the console selects the new project.
3. **Agent:** In the API library, turn on the Gmail API and the Google Calendar API for that project.
4. **Agent:** Open the OAuth consent screen: user type **External**, app name Watchtower, the customer's address as support and contact email, and the customer as a test user. Then publish the app to production; Google calls it unverified, which is expected for a project of your own.
5. **Agent:** Open **Credentials**, start **Create credentials → OAuth client ID**, set the type to **Desktop app** and the name to Watchtower, and stop before the form's last button. Call `request_secret` with kind `google_client_secret`. The card asks the customer to close Google's result window before sending.
6. **You only:** Press **Create**, copy the client secret from the dialog into the assistant's card, close the dialog, then press **Send**.
7. **Agent:** On the **Credentials** page, read the new client's Client ID from the OAuth 2.0 Client IDs list; never open its secret. Call `connect_start` with `own_client` set to that Client ID. The panel shows a confirm card: Watchtower will sign in through a client of your own.
8. **You:** Read the card and press its confirm button, or decline. A decline ends the run; nothing is stored.
9. **You:** In the browser, sign in to Google. On "Google hasn't verified this app", check that it names your new project, then choose **Advanced** and go on to it. Approve Gmail and Calendar, ticking every permission.
10. **Check:** Call `connect_wait`; while it says `waiting`, call it again. On `connected`, call `connect_status` to confirm the account and tell the customer the first sync has started; on `failed` or `timeout`, tell the customer the reason and stop at [If something goes wrong](#if-something-goes-wrong).

## If something goes wrong

The assistant's panel always offers **Set up by hand**, which opens **Use my own Google project**: drop the client JSON there and press **Connect**.

- **Own projects are blocked** (`policy`). Your organization does not allow them; accounts already on one say "Stopped by your organization — data kept". Ask IT for your company's link.
- **"Another connection is already in progress."** (`busy`). Another Google sign-in is running. Wait for it, or cancel it, then start again.
- **Google Cloud Console refuses a new project.** Your account may not make projects. Use a personal Google account, or your company's setup.
- **The dialog closed before you copied the secret.** Google shows it only there. Make a new client (step 5) and copy its secret.
- **"Google does not accept this client" with a code.** The Client ID or the secret is wrong. Check the Client ID on **Credentials**, or make a new client.
- **"Could not reach Google" with a reason.** Nothing was saved. Check the network and start again.
- **"The sign-in did not finish". Nothing was saved.** Start again from step 7.
- **"Gmail was not approved on Google's consent screen, so it does not sync."** (or Calendar). Start again from step 7 and approve every permission.
- **"Could not connect your Google project" with a reason.** The assistant reads you the reason. Try again, or use **Set up by hand**.
- **"Google hasn't verified this app" names another project.** Cancel: it is not yours. Tell the assistant, and stop.
- **The confirm card was declined, or the wait ran out** (`timeout`). Nothing was stored. Start again when you are ready.

```connect
service: google_own_project
domains: console.cloud.google.com
tools: connect_status, connect_start, connect_wait, request_secret
secrets: google_client_secret
options: own_client
```
