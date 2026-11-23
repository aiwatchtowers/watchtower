# Set up your company's Linear app with the assistant

The Linear step of the company setup: the assistant makes your company's Linear OAuth application, saves its Client ID in the setup and checks it with Linear, with no sign-in. The app needs no secret: Watchtower signs in with PKCE. It runs after the Atlassian page. **Agent** steps are the assistant's, **You** steps are yours.

## What you get

- Colleagues connect Linear through the company's own app, with one link or code ([Company setup](../start/company-setup.md)), instead of Watchtower's shared Linear app.

## Before you start

- Making the OAuth application needs a Linear workspace admin. Where your workspace asks for app approvals, colleagues' sign-ins wait until an admin approves Watchtower.
- You are signed in to Linear in your browser.
- The assistant works only on linear.app. It leaves any other page and stops.

## Steps

1. **Agent:** Call `connect_status` and `company_draft`. If the draft has no company name, ask the customer for it and save it with `company_draft`. If Linear is not among the draft's `services` (what the customer ticked in the wizard; never ask again), go on to the next vendor page. If the draft already holds a Linear Client ID, go to step 4.
2. **Agent:** On [linear.app](https://linear.app), open the new OAuth application page (settings, API, OAuth applications). Name it Watchtower, add the callback URLs `http://localhost:18531/callback` through `http://localhost:18535/callback`, one per port, and save it. If Linear says only admins can make it, stop at [If something goes wrong](#if-something-goes-wrong).
3. **Agent:** On the application's page, read its Client ID and save it with `company_draft`. Do not reveal or copy its client secret: Watchtower uses none.
4. **Agent:** Call `company_check` with vendor `linear`. Watchtower asks Linear about the client and its callback URL without a sign-in.
5. **Check:** On `ok`, go on to the next vendor page. On any other result, tell the customer the reason and stop at [If something goes wrong](#if-something-goes-wrong).

## If something goes wrong

The assistant's panel always offers **Set up by hand**, which opens the setup wizard: the wizard and the panel share one draft.

- **Linear lets only admins make OAuth applications.** Ask a Linear workspace admin to make it with step 2, then give the assistant its Client ID.
- **"Linear does not accept this client" with a code.** Copy the Client ID again from the application's page in Linear, and check the callback URLs.
- **"Could not reach Linear" with a reason.** Nothing was saved. Check the network and run the check again.
- **"The check stopped before it answered."** Nothing was saved; run it again.
- **"Watchtower could not save the setup's progress on this Mac, so nothing was checked."** Try again.

```connect
service: company
vendor: linear
domains: linear.app
tools: connect_status, company_draft, company_check
```
