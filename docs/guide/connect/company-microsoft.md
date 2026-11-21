# Set up your company's Microsoft 365 app with the assistant

The Microsoft 365 step of the company setup: the assistant registers your company's Outlook app in the Microsoft Entra admin center, saves its ids in the setup and checks them with Microsoft, with no sign-in. The app has no secret: Watchtower signs in with PKCE against your tenant. It runs after the Linear page, last of the vendors. **Agent** steps are the assistant's, **You** steps are yours.

## What you get

- Colleagues connect Outlook through the company's own Entra app, with one link or code ([Company setup](../start/company-setup.md)), instead of Watchtower's shared app, which your tenant may ask an admin to approve.

## Before you start

- You can sign in to the Microsoft Entra admin center. Registering the app needs an admin only if your tenant turned app registration off.
- **Grant admin consent** needs a tenant admin (Cloud Application Administrator or above). Without one, Watchtower gives you a link to send your IT admin; the setup goes on meanwhile.
- The assistant works only on entra.microsoft.com. It leaves any other page and stops.

## Steps

1. **Agent:** Call `connect_status` and `company_draft`. If the draft has no company name, ask the customer for it and save it with `company_draft`. If the company does not use Microsoft 365, save that and go on to Publish. If the draft already holds both ids, go to step 7.
2. **Agent:** On entra.microsoft.com, open **App registrations → New registration**: name Watchtower, **Accounts in this organizational directory only**, no redirect URI yet. Register it.
3. **Agent:** Watchtower signs in on `http://127.0.0.1:<port>/callback`. The portal's redirect box refuses an `http` address with `127.0.0.1`, so open the app's **Manifest**, add `"http://127.0.0.1/callback"` to `publicClient.redirectUris`, then save it.
4. **Agent:** Under **API permissions**, add the delegated permissions `IMAP.AccessAsUser.All`, `offline_access`, `openid` and `email`. Never open **Certificates & secrets**: Watchtower uses no secret.
5. **You:** If you are a tenant admin, press **Grant admin consent** on **API permissions** and confirm. If not, skip it: step 8 gives you a link for your admin.
6. **Agent:** On the app's **Overview**, read the **Application (client) ID** and the **Directory (tenant) ID** and save both with `company_draft`.
7. **Agent:** Call `company_check` with vendor `microsoft`. Watchtower asks Microsoft about the client without a sign-in.
8. **Check:** On `ok`, go on to Publish. On `admin_consent`, give the customer the **Admin consent link** from the setup to send their IT admin; Microsoft 365 shows **Waiting** until they approve, and Publish does not wait for it. Call `company_check` again once they say the admin approved. On any other result, tell the customer the reason and stop at [If something goes wrong](#if-something-goes-wrong).

## If something goes wrong

The assistant's panel always offers **Set up by hand**, which opens the setup wizard: the wizard and the panel share one draft.

- **"Your IT admin must approve Watchtower in Microsoft 365".** Send them the **Admin consent link**. You can go on and publish; press **Check again** on the Microsoft 365 step after they approve.
- **"Microsoft does not accept this client in tenant" with a code.** Check both ids on the app's **Overview** page and save them again.
- **The check is rejected with AADSTS50011 (redirect URI mismatch).** Microsoft did not accept the address Watchtower signs in on. This is a known issue being checked. Stop here and use **Set up by hand**.
- **"Could not reach Microsoft" with a reason.** Nothing was saved. Check the network and run the check again.
- **New registration is refused.** Your tenant turned app registration off. Ask a tenant admin to register the app with steps 2–3, then give the assistant its ids.
- **"The check stopped before it answered."** Nothing was saved; run it again.
- **"Watchtower could not save the setup's progress on this Mac, so nothing was checked."** Try again.

```connect
service: company
vendor: microsoft
domains: entra.microsoft.com
tools: connect_status, company_draft, company_check
```
