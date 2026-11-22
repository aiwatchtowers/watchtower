# Set up your company's Atlassian app with the assistant

The Atlassian step of the company setup: the assistant builds your company's Atlassian app for Jira and Confluence in the developer console, saves its Client ID and site in the setup and checks it with your sign-in. You open the one page that shows the app's secret and type the secret into a secure card it never sees. It runs after the Google page. **Agent** steps are the assistant's, **You** steps are yours, **You only** steps are clicks it must leave to you.

## What you get

- Colleagues connect Jira and Confluence through the company's own app, with one link or code ([Company setup](../start/company-setup.md)).
- Your own Atlassian account connected: the check signs you in.

## Before you start

- No admin rights are needed: any Atlassian account can make the app. An organization that blocks user-installed apps may refuse the sign-in.
- You know the company's site, like `acme.atlassian.net`, and can sign in to it. Watchtower stays open on this Mac: the check's sign-in returns to it on `127.0.0.1`.
- The assistant works only on developer.atlassian.com, and never opens the app's page that shows its secret. Atlassian's sign-in page is yours alone. It leaves any other page and stops.

## Steps

1. **Agent:** Call `connect_status` and `company_draft`. If the draft has no company name, ask the customer for it and save it with `company_draft`. If the company does not use Atlassian, save that and go on to the next vendor page. If the draft already holds an Atlassian Client ID with `client_secret_set`, go to step 8.
2. **Agent:** On developer.atlassian.com/console/myapps, make a new OAuth 2.0 integration named Watchtower. Ask the customer before you accept Atlassian's developer terms for them.
3. **Agent:** Under **Permissions**, add the Jira API with the scopes `read:jira-work write:jira-work read:jira-user read:board-scope:jira-software read:sprint:jira-software read:issue:jira-software read:project:jira`, the Confluence API with `read:space:confluence read:page:confluence read:blogpost:confluence read:comment:confluence read:attachment:confluence read:user:confluence read:content-details:confluence search:confluence readonly:content.attachment:confluence read:confluence-user`, and the personal data reporting API with `report:personal-data`.
4. **Agent:** Under **Authorization**, turn on OAuth 2.0 (3LO) and set the callback URL to `http://localhost:18511/callback`. Atlassian takes one callback URL, and Watchtower's sign-in listens on port 18511.
5. **Agent:** Under **Distribution**, turn sharing on and answer Yes to "Does your app store personal data?". Offer to add a second admin as an owner, so the app outlives one person.
6. **Agent:** Stop before the app's credentials page; do not open it. Call `request_secret` with kind `atlassian_client_secret`, and ask the customer to paste the Client ID into the chat.
7. **You only:** Open the app's **Settings** page, copy its **Secret** into the assistant's card and its **Client ID** into the chat, leave the page, then press **Send**.
8. **Agent:** While `request_secret` says `waiting`, call it again; on `cancelled` or `timeout`, tell the customer and stop at [If something goes wrong](#if-something-goes-wrong). Then save the Client ID, the site (`https://acme.atlassian.net` form) and Confluence on or off with `company_draft`. Call `company_check` with vendor `atlassian`. Watchtower opens Atlassian's sign-in in the browser.
9. **You:** If the panel says the company's stored Atlassian app will be replaced, press its confirm button or decline. Then sign in to Atlassian, pick the company's site and press **Accept**.
10. **Check:** While `company_check` says `waiting`, call it again. On `ok`, tell the customer "Connected as" with the address; on any other result, tell the customer the reason and stop at [If something goes wrong](#if-something-goes-wrong).
11. **You:** In the setup wizard's Atlassian step, tick the three items Atlassian gives Watchtower no way to read: sharing is on, "Does your app store personal data?" is Yes, `report:personal-data` is among the permissions. The assistant set them in steps 3–5; Publish waits for your ticks. Then the assistant goes on to the next vendor page.

## If something goes wrong

The assistant's panel always offers **Set up by hand**, which opens the setup wizard: the wizard and the panel share one draft.

- **"Atlassian refused the sign-in" with a code.** Check the Client ID and the secret, and that Watchtower's callback URLs are in the app's Authorization settings (step 4). Run the check again.
- **Atlassian's page says the callback URL does not match.** Another app holds port 18511, so Watchtower's sign-in moved to another port. Quit that app, then run the check again.
- **"Watchtower needs your company's name before this check".** Tell the assistant the name and run the check again.
- **"Could not reach Atlassian" with a reason.** Nothing was saved. Check the network and run the check again.
- **"The sign-in did not finish". Nothing was saved.** Run the check again.
- **Your organization refuses the sign-in.** It blocks user-installed apps. Ask your Atlassian admin to allow Watchtower.
- **"The sign-in worked, but Watchtower could not record the check in this setup".** Your account stays connected; run the check again.
- **"The check stopped before it answered."** Nothing was saved; run it again.
- **"Publish waits for the Atlassian settings: tick the three items on the Atlassian step."** Do step 11.
- **"Publish waits for the Atlassian check: sign in on the Atlassian step, or skip Atlassian."** Run the check (step 8), or skip Atlassian in the wizard.
- **The Replace card was declined.** The stored Atlassian app stays and nothing changed.
- **The secret card was cancelled** (`cancelled`), **or a wait ran out** (`timeout`). Nothing was saved. Run the step again when you are ready.
- **"Your organization sets <company>'s apps on this Mac".** A configuration profile sets this company; what you set up is used once the profile is removed.

```connect
service: company
vendor: atlassian
domains: developer.atlassian.com
tools: connect_status, company_draft, company_check, request_secret
secrets: atlassian_client_secret
```
