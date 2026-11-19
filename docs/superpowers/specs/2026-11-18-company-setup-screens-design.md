# Company setup — the screens

**Date:** 2026-11-18 · **Board:** target #1887 · **Status:** draft for review
**Parent spec:** `docs/superpowers/specs/2026-11-17-company-setup-design.md` (decisions D1–D24; its D14 asks for this spec). **Extends:** `docs/superpowers/specs/2026-11-15-slack-full-live-screens-design.md` (the Slack screens, #1779) — its §3 "Set up for my company" and §4 "Entry into Full" become the multi-vendor versions below (§0 says exactly what is superseded).

## Goal

Every screen the parent promises has a mockup for each of its states and a model that owns its texts:

1. The **Set up for my company** wizard, a page in Connections: first **What does your company use?**, then a step per ticked service (Slack, Google, Atlassian, Linear, Microsoft 365), Link deny list, Publish; each vendor step skippable; the draft resumed; the existing-app fork per vendor (D19); Publish with the link, the code, the `.mobileconfig` and the IT guide link (D21).
2. The employee's **Connect Acme?** confirmation with a checkbox per vendor, the chain ticking per vendor, a cancelled or failed consent, the same bundle again, the **Replace** warning, the listener's browser pages, the port-busy line, the code paste, the MDM **Acme — Connect all**.
3. Connections: a **Companies** zone on the overview, account rows grouped by company in every service, **Re-login needed** (`invalid_client`) and **Not connected — Connect** rows.
4. **Use my own Google project** (personal Gmail) and its policy lock (`AllowOwnGoogleProject = false`).
5. **Connect with an API token** for Atlassian, its errors, the dead-token row with the 30-day lease notice, and its policy lock (`AllowAtlassianAPIToken = false`).
6. The two retirement banners (shared Google = Calendar only; shared Atlassian app retired — Re-login).
7. The IT guide link from Settings → Privacy → Organization policy and from every policy lock.

No production code changes with this spec. The mockups are design-only SwiftUI scenes in the DesignShots test target (§12).

## 0. What this supersedes in the Slack screens spec

| Slack screens spec | Becomes | Why |
|---|---|---|
| §3.1–§3.2 the Slack-only **Set up for my company** sheet | the wizard's **Slack** step (§2.5 here), on a page instead of a sheet (owner, ask #1490; supersedes Slack spec decision 13 for the setup). Its token form, its progress marks, `badToken`, `notAllowed` and `approval` states keep their texts. Its **Success** ("Copy connect code") moves to **Publish** (§2.10): the code is now the company code | parent D7: one setup for every vendor |
| §3.3 **Add the link to the app** sheet | the wizard's **Publish** step with a fresh token (`publish-tokenExpired`, §2.10). The sheet goes | parent §2 step 8: Publish writes the link |
| §3.4 the setup-record rows on Connections → Slack | kept. **Add the link to the app** opens the wizard at Publish; **Continue setup**, **Check again** and a lost create stay on plan B's sheet (A32) | the record still exists (Slack spec T7); only the button target changes |
| §3.5 `SlackAppSetupModel` | the Slack step's engine (create, reuse, link write), driven by `CompanySetupWizardModel` (§9); it owns no sheet of its own. **It does not exist yet** (the Slack screens spec is not implemented): the company plan builds it first, as task **C0** (Slack spec §3.5 without the sheet, over Slack plan B's T7 CLI); the Slack screens plan's task S3 then reuses it and adds only the setup-record rows | one wizard model owns the frame; the company plan does not wait for the Slack screens plan |
| §4.1 the About page text | written by Publish: "Watchtower for <company> — connect: <company link>" and the company code (parent §2 step 8). The listener keeps serving `/slack/connect` for About pages written before | parent §2; old pages must not break |
| §4.2 the connect field "Connect link or code" | also accepts a company link or code; one opens **Connect Acme?** (§3.1) | one field, never "wrong field" |
| §4.3 the Slack connect sheets | kept for a `/slack/connect` link; a company link uses §3 here | parent §3 |
| §4.4 port 18551 busy | the same line on Connections → Slack, plus the Companies zone's line (§4.1) | one listener, two places to paste |
| §5 the shared Slack app banner | unchanged; its **Set up for my company** opens the wizard | — |

Everything else in the Slack screens spec (§1, §2, §6–§9) is untouched.

## Context (recon, 2026-11-18)

- **Connections today** (`docs/features/connections-tab.md`): `ConnectionsTabView` shows `ConnectionsOverviewContent` (attention banners → "Sources" → "Tools for AI", cards from `[ConnectionSummary]`, `ConnectionCard`, `ConnectionAttentionBanner`, `ConnectionStatusMark` with a lock for a blocked source) or the service detail. `needsAttention` = status `.error` and not blocked; it drives the banners and the red sidebar badge.
- **Service details** under `Views/Settings/`: `GoogleConnectionDetail` (legacy `Form`, "Google Accounts" with Re-login/Rename/Remove, **Add Google Account**), `AddGoogleAccountView` (sheet, with a disclosure "Advanced: custom OAuth client"), `JiraConnectionDetail` (legacy `Form`: Sites, then Boards, Confluence, Features, User Mapping, Sync), `AddJiraAccountView`, `LinearConnectionDetail`, `EmailConnectionDetail` (Outlook), `SlackConnectionDetail`. Account view models: `GoogleAccountsViewModel`, `JiraAccountsViewModel`, `LinearAccountsViewModel`, `EmailAccountsViewModel`, `SlackAccountsViewModel`.
- **Policy:** `ManagedPolicy` / `ManagedPolicyCenter` on `AppState`; `SourceBlockedNotice` ("Blocked by your organization", `Views/Settings/ConnectionsSettings.swift`); `OrganizationPolicySection` (Settings → System → Privacy, legacy `Form` section over `OrganizationPolicyPresentation.lines`); `ManagedByOrganizationBadge` and `.managedByOrganization(_:)` in the design kit.
- **Purge notices:** `AccountPurgeLine` / `AccountPurgeNoticePolicy` already say "Watchtower has not reached <label> since <date>. Its data will be deleted on <due> unless you reconnect." for a lease purge (PURGE-01).
- **Browser pages:** `internal/oauthpage` (`Success`, `Error`, `Stale`; card with icon, heading, message, hint).
- **Language:** the Desktop is not localised; every string below is English.

## 1. (moved)

Where the wizard opens from is now §2.1.

## 2. The setup wizard

### 2.1 Where it opens from

- **Connections overview → Companies** (new zone above Sources, §4.1): **Set up for my company**; while a draft exists, the zone's first row "Setup in progress: Acme, at Atlassian (step 4 of 8)." with **Continue setup** (`company-overview-setupInProgress`). The zone also holds **Connect with a company code** and the company cards.
- **Connect…** menu on the overview gains **Set up for my company** and **Connect with a company code** at its end.
- Connections → Slack's connect section, its setup-record rows (Slack spec §3.4) and the shared Slack app banner (Slack spec §4.2, §5).
- The Atlassian banner (§7) and the Jira empty state.

Every entry opens the same page; with a draft it opens at the draft's step.

### 2.2 The frame: a page in the Connections detail area

The wizard is a **page in the Connections detail area**, like Jira's drill-in (owner, ask #1490), not a sheet: the detail shows it in place of a service, with **‹ Connections** (quiet, top left) as the way back. Under it: title "Set up Watchtower for your company" and the intro "One pass for every service your company uses. Each step can be skipped; Watchtower keeps your progress, so you can leave this page and come back." Left: the **step rail** — **Services**, then one row per service ticked on the Services step (in the order Slack, Google, Atlassian, Linear, Microsoft 365), then Link deny list and Publish — each with a mark (done ✓, skipped –, not started ○) and a word (**Done**, **Reused**, **Skipped**); the current step is the selected row; under the rail a quiet **Change services** (from the second step on). Right: the step's title and content. Bottom row (right): **Skip this step** (quiet, vendor steps only), **Back**, and the step's one prominent action.

- **Narrow** (under 520 pt): the rail folds into one line "Step 3 of 8 · Google". One narrow frame per distinct step layout (§12): `services`, `slack-found` (the choices), `slack-create` (the token form), `google-create` (guide + drop zone), `atlassian-create` (guide + fields; Linear and Microsoft share it), `publish-done` (the values).
- **Leaving the page** (‹ Connections, another service, another tab, quitting): the draft (`<workspace>/company/draft.json`, parent §2) is saved at the current step — every field typed so far, secrets included (0600), except the Slack configuration token, which is never stored. A check or create in flight keeps running on `AppState.companySetup`; its result lands in the draft. The Companies zone then shows "Setup in progress: … — **Continue setup**". Coming back opens at the draft's step with the line "Continuing the setup you started on Nov 17." and a quiet **Discard setup** (`company-wizard-resume`). **Discard setup** asks first (a system confirmation, not mocked): "Discard this setup? The draft and the secrets in it are deleted from this Mac. Services you already signed in to stay connected and keep working. Apps you created stay in Slack, Google, Atlassian, Linear and Microsoft." — the stored company bundle and the accounts the checks made stay: they work, and the bundle now carries only the checked vendors — **Discard** (destructive) / **Keep**.
- **An unreadable draft** (`draft.json` that cannot be decoded — a third state, never folded into "no draft"): the page opens on Services with the warning "Your unfinished setup could not be read — start again" / "Watchtower kept the file as draft.json.bad-<timestamp> next to your company setups, so nothing you typed is lost; Discard or Publish deletes it." and a quiet **Show file in Finder** (`company-wizard-draftUnreadable`). The file is renamed, never deleted, so typed secrets are not silently lost; the renamed file keeps 0600 and is deleted by **Discard setup** or a successful Publish, like the draft. Only the newest `draft.json.bad-*` is kept (a new rename deletes older ones), and the daemon deletes one older than 30 days at startup, so an abandoned setup does not leave secrets on disk for good. The Companies zone shows "Setup in progress" only for a readable draft.
- A rail row is clickable once its step was reached; you can go back to any earlier step. **Skip this step** marks a vendor step Skipped and moves on (the company has the service but sets it up later); a skipped step can be reopened from the rail.

### 2.3 Services: "What does your company use?" (first step)

Owner, conversation 2026-11-18: the first step picks the services; everything else goes through MCP connectors.

| State | Shot | What shows | Buttons |
|---|---|---|---|
| Empty | `company-wizard-services` (+ `-narrow`) | "Tick what your company has. Each ticked service gets its own step; the link deny list and Publish always follow."; one checkbox per supported service with a one-line description: **Slack** "Messages, digests and the Inbox"; **Google Workspace — Gmail and Calendar** "Mail and calendar through your company's Google project"; **Atlassian — Jira and Confluence** "Issues and pages through your company's Atlassian app"; **Linear** "Issues through your company's Linear app"; **Microsoft 365 — Outlook** "Mail through your company's Entra app"; nothing ticked; under the list the quiet note "Use something else (Notion, GitHub, a CRM…)? Connect it yourself in Connections → Quick Connections (MCP connectors)." with a quiet **Open Quick Connections** (`AppState.openConnections(.quickConnections)`, the Tools for AI service of `docs/features/quick-connections.md`); the rail shows Services, Link deny list, Publish | **Continue** (disabled until one is ticked) |
| Found | `company-wizard-services-found` | a service whose app discovery (§2.4 "Look", run when the page opens) found comes pre-ticked, its description followed by " · Found on this Mac"; the rail already lists the ticked services | **Continue** |
| Unticking a filled step | `company-wizard-services-change` | reached by **Change services**; unticking a service whose step holds entries shows, in place, the warning "Stop setting up Atlassian?" / "What you entered for it (client id and secret) is dropped from the draft. An app you created stays in Atlassian." | **Keep** (prominent), **Drop Atlassian** (destructive) |

The choice is kept in the draft (`services`). Ticking a service later adds its step to the rail before Link deny list; unticking an empty step drops it without asking. What an unticked service means for colleagues is in the Publish summary (§2.10): "Linear · not used: colleagues use Watchtower's shared Linear app", "Microsoft 365 · not used: colleagues use Watchtower's shared Microsoft app, which your tenant may ask an admin to approve", "Google · not used: colleagues can connect Google Calendar; Gmail needs their own Google project", "Atlassian · not used: colleagues connect Jira with their own API token", "Slack · not used: no Slack page carries the link". A skipped step reads the same with "skipped" in place of "not used". The step's own captions no longer repeat it (the old per-step "Skipped: …" notes are gone).

### 2.4 Existing apps first (D19) — every vendor step

| State | Shot | What shows | Buttons |
|---|---|---|---|
| Looking (loading) | `company-wizard-looking` | spinner, "Looking for <vendor> apps this Mac already knows…" | **Continue** disabled |
| Found, one | `company-wizard-slack-found` | "Found on this Mac", one selected row: the app and where it came from ("Watchtower · A0ACME" / "Slack app — your connected account acme"); caption "Reusing keeps the app and its ids; nothing new is created. A configuration token is still needed to check and update its settings." (Slack); "Reusing keeps the client and its id; nothing new is created." (others) | **Create new**, **Use Watchtower** (prominent) |
| Found, several | `company-wizard-google-found` | the same with one row per candidate, the first selected | **Create new**, **Use the selected client** |
| Nothing found (empty) | `company-wizard-slack-notFound`, `company-wizard-google-notFound` | "No <vendor> client found on this Mac." (Google; the Slack step's first open has no line), two choices **Create new** ("Watchtower walks you through creating it.", selected) / **We already have one** ("Paste what identifies it; Watchtower checks it before going on."), then the "Not sure?" hint | **Continue** |
| We already have one | `company-wizard-slack-existing` | the identifying fields (below); a wrong shape shows the field's error | **Continue** (disabled until valid) |
| Reused, secret missing | `company-wizard-google-reuseSecret` | "This Mac knows the client id but not its secret. Open the client in Cloud Console, copy its secret and paste it here." + **Open the client** + a secure "Client secret" field | **Continue** (disabled until pasted) |

The "Not sure?" hints (`CompanyVendorGuide.notSure`):

- Slack: "Not sure? In Slack, open Apps and search for Watchtower. If it is there, someone already created it."
- Google: "Not sure? Look in Google Cloud Console → APIs & Services → Credentials, under OAuth 2.0 Client IDs."
- Atlassian: "Not sure? Look in the Atlassian developer console → My apps."
- Linear: "Not sure? Look in Linear → Settings → API → OAuth applications."
- Microsoft: "Not sure? Look in the Microsoft Entra admin center → App registrations → All applications."

What **We already have one** asks (parent §2 "Nothing found"): Slack — "App settings link" (`https://api.slack.com/apps/A…`; help "Open the app on api.slack.com and copy the address of its settings page."; wrong shape: "That is not a Slack app settings link. It looks like https://api.slack.com/apps/A0123ABCD."); Google — the client JSON (drop zone) or Client ID + Client secret; Atlassian — Client ID + Client secret; Linear — Client ID; Microsoft — Application (client) ID + Directory (tenant) ID.

The candidate's source line names one of the parent's "Look" sources: "Acme's saved company setup" (a stored `company/*.json` or the draft), "the credentials file of <account>" (a per-account credentials file), "<vendor> app — your connected account <label>" (an account on a non-shared client, incl. a bridged corp account).

### 2.5 Slack

| State | Shot | What shows | Buttons |
|---|---|---|---|
| Create new / reuse: token | `company-wizard-slack-create` | Slack spec §3.2's form unchanged: "1. Generate a configuration token" + help + **Open Slack's token page**; "2. Paste it here", secure "Configuration token", "Used once for this setup and never stored." | **Create the app** (new) / **Continue** (reuse) |
| Busy | `company-wizard-slack-progress` | marks: new — "Checking the token", "Creating the app"; reuse — "Checking the token", "Reading app A0ACME's settings", "Comparing them with Watchtower's"; caption "You can leave this page: the setup resumes at this step, and the app is never created twice." | the action disabled; no Skip |
| Reused app differs | `company-wizard-slack-manifestDiff` | blue notice "App A0ACME's settings differ from Watchtower's" / "Watchtower will make these changes to the app. Nothing else in it changes." and one line per change ("Add scopes: …", "Add redirect URL: …") | **Back**, **Update the app** |
| Not a collaborator | `company-wizard-slack-notCollaborator` | "You are not a collaborator on app A0ACME, so Slack does not let you change it. Ask the app's owner to add you as a collaborator, then try again." Nothing is created (parent §2.2) | **Back**, **Try again** |
| Wrong workspace | `company-wizard-slack-wrongWorkspace` | "App A0ACME belongs to another workspace (T0OTHER), not acme. Check the link and paste it again." | **Back**, **Try again** |
| Bad token | `company-wizard-slack-badToken` | Slack spec's line: "That token did not work: it has expired or is not a configuration token. Generate a new one and paste it." | **Try again** |
| Not allowed, network, other refusal, approval | (layout of `slack-badToken`) | Slack spec §3.2's texts unchanged | **Try again** / **Check again** |
| Done | rail ✓ **Done** (new) or **Reused** | — | moves to Google |

Slack not used or skipped: Publish cannot write an About page; its text says so (§2.10).

### 2.6 Google

| State | Shot | What shows | Buttons |
|---|---|---|---|
| Create new | `company-wizard-google-create` (+ `-narrow`) | numbered guide, each line with **Open** (a deep link): "Create a project"; "Turn on the Gmail API and the Google Calendar API"; "OAuth consent screen: user type Internal"; "Credentials → Create OAuth client → Desktop app, then download its JSON"; then the drop zone "Drop the client JSON here, or paste it" | **Continue** (disabled until a JSON is in) |
| Checking (busy) | `company-wizard-google-checking` | the dropped file ("client_secret_….json · project acme-watchtower") + "Finish in your browser: sign in to Google with this client. Your sign-in checks the client and connects your own Google account." (S28) | **Continue** disabled |
| Cannot create a project in the organization | `company-wizard-google-noOrgAccess` | reached by the quiet **Can't create a project in your organization?** under the guide: warning "An Internal app needs your company's Google Cloud organization" / "The project must sit inside example.com's Google Cloud organization. If you cannot create one there, or Internal is not offered, ask your Google Workspace admin to create the project or to give you the Project Creator role. Then drop the client JSON they send you here." + **Copy the steps for your admin** (the guide's lines and deep links as text) + the drop zone | **Continue** (disabled until a JSON is in) |
| Rejected | `company-wizard-google-checkFailed` | "Google does not accept this client: invalid_client. Download the JSON again from Credentials." + **Try again** | **Continue** disabled |
| Network error | (layout of `google-checkFailed`) | "Could not reach Google: the request timed out. Nothing was saved." + **Try again** | — |
| Done | rail ✓ | the check also records the Workspace domain (parent §2 step 3) | — |

**The Google check is your own sign-in, and it is your connection** (ask #1503): a dry authorize URL proves the client id exists but never sends the secret, so the step runs your loopback sign-in with the dropped client and exchanges the code — a token back means id, secret and redirect work. The tokens are kept: the sign-in creates your Google account in Watchtower, tied to the company (`company_slug`). So that the resolver finds the client, the first successful check stores the company bundle as it stands (`company/<slug>.json`, the checked vendors' blocks and the company name) before Publish; each later check updates it, and Publish only adds the rest and writes the Slack About text, the link, the code and the profile (§2.12). The step's done line reads "Connected as <your email>".

### 2.7 Atlassian

| State | Shot | What shows | Buttons |
|---|---|---|---|
| Create new | `company-wizard-atlassian-create` (+ `-narrow`) | guide: "Create an OAuth 2.0 integration"; "Permissions: add the Jira API and the Confluence API with Watchtower's scopes, and report:personal-data" (+ **Copy scopes**); "Authorization: add Watchtower's callback URLs" (+ **Copy callback URLs**); "Distribution: turn Sharing on and answer Yes to “Does your app store personal data?”"; "Add a second admin as an owner, so the app outlives one person" (D6); fields Client ID, Client secret | **Check by signing in** |
| Confirm (new and reused) | `company-wizard-atlassian-confirm` | "Confirm the app's settings" / "Atlassian gives Watchtower no way to read these. Check each one in the developer console, then tick it." Three checkboxes, each with **Open**: "Sharing is on (Distribution)", "“Does your app store personal data?” is Yes", "report:personal-data is among the permissions" | **Continue** (disabled until all three) |
| Checking (busy) | `company-wizard-atlassian-signin` | "Finish in your browser: sign in to Atlassian with this app. Your sign-in checks the client id, the secret and the callback URLs, and connects your own Atlassian account." (S28) | **Check by signing in** disabled |
| Sign-in failed | `company-wizard-atlassian-signinFailed` | "Atlassian refused the sign-in: invalid_client. Check the client id and secret, and that Watchtower's callback URLs are in the app's Authorization settings." (a wrong callback shows Atlassian's own reason in place of `invalid_client`) | **Try again** |
| Resumed draft | `company-wizard-resume` | the Create-new content under the resume line | — |

**The Atlassian check is your own 3LO sign-in, and it is your connection** (S21; ask #1503 for keeping the tokens): Atlassian has no dry check for a client id and secret, so the step runs your sign-in with the entered pair (through `jira add --company <slug>`, parent §1) and exchanges the code. The step completes only when a token comes back (then the confirm checklist follows); the account it creates is your Jira (and Confluence) account, tied to the company, and the stored company bundle gains the `atlassian` block (§2.12). Until then **Publish** is disabled with the reason "Publish waits for the Atlassian check: sign in on the Atlassian step, or skip Atlassian." — skipping or unticking Atlassian removes the reason. A bad pair therefore never reaches Slack's About page. The Publish summary line reads "Atlassian · client 9f3a…c21 · acme.atlassian.net · Confluence on · checked and connected by your sign-in".

### 2.8 Linear and Microsoft 365

| State | Shot | What shows | Buttons |
|---|---|---|---|
| Linear, create new | `company-wizard-linear-create` | guide "Settings → API → OAuth applications → New application"; "Callback URL: paste Watchtower's" (+ **Copy callback URL**); field Client ID; "No secret: Watchtower signs in with PKCE." | **Continue** |
| Microsoft, create new | `company-wizard-microsoft-create` | guide "App registrations → New registration: Accounts in this organizational directory only"; "Platform: Mobile and desktop applications, redirect URI http://localhost"; "API permissions: add the Outlook permissions, then Grant admin consent" (+ **Copy permissions**); fields Application (client) ID, Directory (tenant) ID; "No secret: Watchtower signs in with PKCE against your tenant." | **Continue** |
| Waiting for admin consent | `company-wizard-microsoft-adminConsent` | the dry check answers that consent is missing (AADSTS65001-class): notice "Your IT admin must approve Watchtower in Microsoft 365" / "Grant admin consent needs a tenant admin. Send your IT admin this link; you can go on with the setup meanwhile. Microsoft 365 shows as waiting until they approve." + **Admin consent link** (`https://login.microsoftonline.com/<tenant>/adminconsent?client_id=<id>`, **Copy**) | **Check again**, **Continue** (allowed); the rail word is **Waiting**, the Publish summary line ends "· waiting for admin consent"; Publish is not blocked (colleagues' Outlook logins work once IT approves) |
| Microsoft rejected | `company-wizard-microsoft-checkFailed` | "Microsoft does not accept this client in tenant 0000-acme: AADSTS700016. Check both ids on the app's Overview page." + **Try again** | **Continue** disabled |
| Checking / network / Linear rejected | (layouts of `google-checking`, `google-checkFailed`) | "Checking the client with Microsoft…" / "…with Linear…"; "Could not reach <vendor>: <error>. Nothing was saved." | — |

Both are checked by a dry authorize URL (parent §2.4 names Microsoft; Linear gets the same check, decision A9). That is enough for these two: both are public clients with PKCE and no secret, so the id, the tenant and the redirect are all the authorize step can get wrong, and it checks all three.

### 2.9 Link deny list

`company-wizard-denyList`: "Watchtower never opens links to these hosts — your intranet and internal tools. Colleagues cannot remove them; their own settings can only add more." (D18), a field "Add a host", the list with **Remove** per host. A wrong entry (`company-wizard-denyList-invalid`): "That is not a host name. Enter it like intranet.example.com, without https:// or a path." Empty list = the step can be skipped.

### 2.10 Publish

| State | Shot | What shows | Buttons |
|---|---|---|---|
| Ready | `company-wizard-publish-ready` | "Company name" (prefilled, editable), "Colleagues see “Connect Acme?”. Taken from your Slack workspace; change it if people know the company by another name."; the summary, one line per supported service ("Slack · Watchtower (A0ACME) in acme", "Linear · skipped: colleagues use Watchtower's shared Linear app", the "not used" lines of §2.3, …); "Writes the connect link and code to the About page of Watchtower's app in Slack." | **Back**, **Publish** |
| Ready, Atlassian not checked | (layout of `publish-ready`) | the reason line "Publish waits for the Atlassian check: sign in on the Atlassian step, or skip Atlassian." in place of the caption | **Publish** disabled |
| Ready, token gone (resumed draft) | (layout of `publish-tokenExpired`) | "Paste a configuration token to write the link to the Slack page. It is used once and never stored." + the token field | **Publish** |
| Busy | `company-wizard-publish-busy` | "Packing the company setup" ✓, "Writing the link to the Slack app's About page" … | **Publish** disabled |
| Done | `company-wizard-publish-done` (+ `-narrow`) | green "Acme is set up" / "Colleagues open Watchtower's app in Slack, go to About and click the link. Without Slack, send them the code, or give IT the profile. Your checked services are already connected; Connect this Mac adds the rest."; rows **Connect link** (Copy), **Connect code** (Copy), **Configuration profile for IT** "Acme-Watchtower.mobileconfig" (**Save…**, a save panel); the quiet link **What IT can set** (§8) | **Done**, **Connect this Mac** (opens §3.1's same-bundle variant: only the vendors not yet connected — Slack, Linear, Microsoft; hidden when every vendor is connected) |
| Done, Slack not used or skipped | `company-wizard-publish-done-noSlack` | body "Slack was skipped, so no page carries the link. Send colleagues the code, or give IT the profile. Your checked services are already connected; Connect this Mac adds the rest." | same |
| Token expired | `company-wizard-publish-tokenExpired` | "The configuration token has expired, so the link is not on the Slack page yet. Your setup is kept. Generate a fresh token and paste it." + **Open Slack's token page** + the token field | **Try again** |
| Failed | `company-wizard-publish-failed` | the summary + "Could not reach Slack: the request timed out. Your setup is kept." | **Try again** |

The company name is never asked when it can be derived: Slack workspace name first, else the Google Workspace domain's first label, else the Atlassian site's (decision A2); the field is there to correct it, also after a check stored the setup — then only the display name changes (§2.12, parent D25). On **Done** the draft is deleted (parent §7).

### 2.11 You may not be an admin

The person running the wizard may be any employee, not an admin (ask #1503: "it may not be an admin at all, just an employee; but the check can still be done"). The UI says "you" and never assumes admin rights; each step says what needs them and what to do without them (details: decision A29):

| Vendor | Needs real admin rights for | Without them |
|---|---|---|
| Slack | creating an app where the workspace restricts it; installing where installs need approval | the Slack spec's states: `notAllowed` ("Ask a workspace admin to run this setup") and `approval` (Slack sent the admin a request; **Check again**) |
| Google | an **Internal** consent screen needs the project inside the company's Google Cloud organization; creating a project there needs the Project Creator role (by default every domain user has it, but the org can remove it) | `google-noOrgAccess`: ask the Workspace admin to create the project or grant the role, **Copy the steps for your admin**, then drop the JSON they send |
| Atlassian | nothing: any Atlassian account can create a developer-console app. The advice stays that a second admin or a service account co-owns it (D6). An organization that blocks user-installed apps may refuse the sign-in | the sign-in's refusal shows in `atlassian-signinFailed` with Atlassian's own reason (exact error: spike S1) |
| Microsoft | **Grant admin consent** needs a tenant admin (Cloud Application Administrator or above); registering the app needs nothing unless the tenant turned "Users can register applications" off | `microsoft-adminConsent`: the admin-consent link to send, **Continue** allowed, **Waiting** until it works. If registration itself is off, the same layout says "Ask your IT admin to register the app" with **Copy the steps for your admin** |
| Linear | whether creating an OAuth application needs a workspace admin is not confirmed — spike S3 settles it | if it does: the Microsoft layout ("Ask your Linear workspace admin", the steps to copy, **Continue** allowed with Linear **Waiting**) |

### 2.12 The company bundle during setup

- **First successful check** (Google or Atlassian sign-in): the bundle is stored at `company/<slug>.json` with the company name and the checked vendors' blocks, and the new account gets `company_slug` in the same Go write (parent §1). The draft keeps the slug.
- **Each later check** adds or updates its vendor's block. A check that changes a client a stored bundle of this company already had (e.g. the company was first connected from a link) works as **Replace** for that vendor: the step says before the sign-in "Acme's stored Atlassian app will be replaced; your other Acme Atlassian accounts will need to log in again", and those accounts get **Re-login needed — Acme changed its app**.
- **Editing a checked field** (A28 un-checks the step): nothing changes yet — the stored bundle keeps the old pair and the account made by it keeps working. The re-check signs in with the new pair: the same account (matched by the vendor's user id) is re-logged on the new client and the stored bundle is updated in that one step. If the person never re-checks, the step stays unchecked and Publish waits (Atlassian) as before.
- **Discard after a check**: the draft goes; the stored bundle and the accounts stay (they work). The Companies card then shows the company with the checked vendors connected and the rest absent.
- **Publish** writes the complete bundle (adding Slack, Linear, Microsoft, the deny list) to `company/<slug>.json` and then the Slack About text; **Connect this Mac** connects only what is not yet connected.
- **A name edited at Publish** after a check stored the bundle (parent D25, ask #1613): Publish just goes through under the new name. Only the display name changes — the bundle's `company`, the link, the code and the About text carry the new name; the slug, the `company/<slug>.json` file name and every account's `company_slug` stay. Go names the draft first, then the stored bundle, so a crash between them reopens the wizard with the new name and the rerun finishes the rename; a refusal at the bundle's write gives the draft its old name back. A name another company on this Mac already has (its file, the MDM-forced company, one forced before, or the person's own Google project) is refused: "“Globex” is already the name of another company on this Mac, or of your own Google project. Choose another name."; the company the MDM bundle forces, and a corp build's own company (its bridge finds it by name), keep their name: "Your organization sets this company's name on this Mac, so it cannot be changed here." Names are the store's identity: a link with the old name opened later is another company. (`TestPublish_RenameChangesOnlyTheDisplayName`, `TestPublish_RenameRerunAfterCrashBeforeBundle`, `TestPublish_RenameRerunAfterFailureAfterBundle`, `TestPublish_RenameToATakenNameIsRefused`, `TestPublish_RefusedWriteRestoresTheDraftName`, `testPublishUnderAnEditedNameJustPublishes`, `testPublishNameRefusalsAreClear`)
- **A company forced by MDM** (`CompanyBundle` with the same company name): the check's write is stored, but the forced overlay wins at read (parent §3), so the step says "Your organization sets Acme's apps on this Mac; what you set up here is used once the profile is removed" and the check's account uses the forced client only if the ids match; otherwise it shows **Re-login needed** at once.

## 3. The employee

### 3.1 Connect Acme?

A sheet over the main window, Connections selected (460 pt; `-narrow` at 360): a confirmation, the style guide's case for a sheet (decision S26).

| Variant | Shot | Title / body | Rows |
|---|---|---|---|
| A link (via the listener) | `company-connect-confirm` (+ `-narrow`) | "Connect Acme?" / "A link asks Watchtower to connect your accounts through Acme's apps. Connect only if you opened this link yourself." | one checkbox per vendor in the bundle, in this order, all ticked: **Slack** "workspace acme" · **Gmail and Calendar** "example.com" · **Jira and Confluence** "acme.atlassian.net" (just **Jira** when `confluence` is false) · **Outlook** "Microsoft 365" · **Linear** "Acme's Linear app" |
| A pasted code | `company-connect-confirm-code` | body "This code connects your accounts through Acme's apps." | same |
| The same bundle again | `company-connect-confirm-again` | as the link variant | connected vendors stay listed, unticked and disabled, with a green **Connected** chip (parent §3 step 4) |
| MDM | `company-connect-confirm-mdm` | "Acme — Connect all" + **Managed by your organization** / "Your organization set up Acme's apps on this Mac." | same |

Caption under the rows: "Each service opens its own sign-in page in your browser, one after another." Buttons: **Cancel**, **Connect** (disabled while nothing is ticked). A vendor the policy forbids (`AllowedSources`) is listed disabled with the lock and "Blocked by your organization" instead of its detail. A bundle with an unknown `v`, bad fields or over 3,000 characters never reaches this sheet (the listener refuses it, §3.4; a pasted code shows the field error, §4.1).

### 3.2 The chain

| State | Shot | What shows | Buttons |
|---|---|---|---|
| Busy | `company-connect-chain` | "Connecting Acme"; one row per ticked vendor: ✓ "Connected as alice"; spinner "Finish in your browser: Google asks you to allow Watchtower."; ○ "Next"; caption "You can close this window: the chain goes on and Connections shows where it is." | **Stop**, **Skip this service** |
| One cancelled | `company-connect-chain-failed` | the cancelled vendor ✗ "You did not allow Watchtower. Connect it later from Connections."; the chain is on the next vendor | same |
| One failed | (layout of `chain-failed`) | "Could not connect: <error>. Connect it later from Connections." | same |
| Finished | `company-connect-done` | "Acme is connected" (all) or "Acme is partly connected"; ✓ / ✗ "Not connected" / – "Skipped" per vendor; "The first sync starts now. What is not connected waits in Connections with a Connect button." | **Done** |

**Skip this service** ends the current vendor's wait (its row: Skipped, then **Not connected — Connect** in Connections) and starts the next. **Stop** ends the wait and skips every vendor left. Closing the sheet does neither: the chain runs on `AppState.companyConnect` and the Companies card shows "Connecting… Google" with the spinner until it ends (decision A10).

### 3.3 A link that changes a stored company

`company-connect-replace`: warning card "Acme's link changes its apps" / "Keep your current setup unless your admin told you the apps changed. Replacing asks you to log in again to what changed."; one line per change in the parent's form ("Atlassian app: 9f3a…c21 → 7b20…e04", "Google client: 1234-abcd… → 5678-efgh…" — ids shortened to first 4 and last 3 characters); caption "Nothing leaves this Mac either way." Buttons: **Replace** (secondary), **Keep current** (prominent, the default button: Return presses it). **Replace** stores the bundle and marks each changed vendor's accounts **Re-login needed — Acme changed its app** (§4.3); nothing else runs. A forced MDM bundle replaces without this sheet (parent §3.5).

### 3.4 The listener's browser pages (Go, `internal/oauthpage`)

| Page | Shot | Heading / message / hint |
|---|---|---|
| After a valid link (the redirect to `/company/connected`) | `company-page-open` | "Continue in Watchtower" / "Watchtower is asking you to confirm Acme. You can close this tab." |
| Refused bundle | `company-page-refused` | "This link does not work" / the reason / "Ask your admin for a fresh link, or paste the connect code in Watchtower → Connections." Reasons: "The link is damaged or cut short." (bad base64 or JSON, unknown field, wrong type), "The link is too long to be a Watchtower company link." (over the cap), "The link names a site that is not https." , "The link carries a personal Google project, which only this Mac can set." (`personal`) |
| Unknown `v` | `company-page-newerVersion` | "This link needs a newer Watchtower" / "Update Watchtower from its menu, then open the link again." (the parent's text) |
| Another company's link still waits for its confirm (409; the same link again is one confirm and redirects) | — (no shot; Task 10) | "Another link is waiting" / "Watchtower is already asking you to confirm a company link. Answer it there, then open this link again." / "You can close this tab." |
| Watchtower did not take the link (the app was closing; 503) | — (no shot; Task 10) | "Watchtower did not take this link" / "Open Watchtower, then open the link again." |

Watchtower not running: the browser's own "can't connect" page; the About text says "Open Watchtower first" (parent §7, no code path). Port busy: §4.1.

## 4. Connections

### 4.1 The Companies zone (overview)

Above Sources, titled **Companies** (`HomeZoneTitle`).

| State | Shot | What shows |
|---|---|---|
| A company | `company-overview-companies` (+ `-narrow`) | a card per stored company: "Acme", "3 of 5 services connected", "Not connected: Gmail and Calendar, Linear", **Connect the rest** (opens §3.1, same-bundle variant); under the cards the quiet **Set up for my company** and **Connect with a company code** |
| MDM bundle | `company-overview-mdm` | the card carries **Managed by your organization**, "Set up by your organization · nothing connected yet" and **Connect all** — the overview's one prominent action |
| Re-login needed | `company-overview-relogin` | the existing attention banner "Jira · Re-login needed — Acme changed its app" + **Reconnect**; the card's line in `Tone.error` "Atlassian: Re-login needed — Acme changed its app" + **Re-login** (runs the changed vendors' logins in a chain, §3.2) |
| No company (empty) | `company-overview-empty` | "Using Watchtower at work? Connect with your company's link or code, or set it up for your company." + the two quiet buttons |
| Setup in progress | `company-overview-setupInProgress` | first row of the zone: "Setup in progress: Acme, at Atlassian (step 4 of 8)." + **Continue setup** (prominent) — while a wizard draft exists |
| Loading | `company-overview-loading` | spinner "Reading company setups…" |
| Read failed | `company-overview-readFailed` | "Could not read the company setups: acme.json is damaged." + **Try again** — a damaged file is its own state, never "no company" (review-rules, absent vs. error) |
| Code paste | `company-overview-codePaste` | **Connect with a company code** opens a field "Company code" + **Connect**; a wrong text: "That is not a Watchtower company code. Copy it again from the Slack app's About page or from your admin." |
| Port busy | `company-overview-portBusy` | warning line "Company links cannot reach Watchtower: port 18551 is busy. Paste the company code here instead." with the code field open |

A card with every vendor connected shows "5 of 5 services connected" and no button. A company's card is not an attention item by itself; only an account in error is (the existing rule).

### 4.2 Accounts grouped by company (every service detail)

Each service's account list is split into `SettingsSection`s, in this order, an empty group not shown:

1. one section per company the accounts use (`company_slug`), titled with the company name, caption "<company>'s <vendor> app" plus what identifies it ("Acme's Google project · example.com", "Acme's Atlassian app · acme.atlassian.net", "Acme's Slack app · Watchtower (A0ACME)", "Acme's Linear app", "Acme's Microsoft 365 app · tenant 0000-acme");
2. Google only: **Your own Google project** — "Gmail and Calendar through a project you own" (a `personal` bundle or an untied legacy credentials file, parent §4);
3. Jira only: **API tokens** — "Sites connected with your own token" (`auth_kind = 'api_token'`), each row with the outline tag **API token**;
4. **Watchtower's shared app** (Google: caption "Calendar only"; Jira: until its Re-login (D15 amended, ask #1600); Linear: "Watchtower's Linear app"; Outlook: "Watchtower's Microsoft app"), rows tagged **Shared app** where the app is retiring or retired;
5. **Other accounts** — "Signed in through an app this Watchtower no longer knows" (parent §5 step 3: `company_slug = ''` and an unknown client).

Shots: `company-google-detail` (+ `-narrow`), `company-jira-detail` (+ `-narrow`), `company-slack-workspaces`, `company-linear-detail`, `company-outlook-detail`. Loading and read-failed states of the list: `company-google-detail-loading` ("Reading Google accounts…"), `company-google-detail-readFailed` ("Could not read Google accounts: database is locked." + **Try again**), `company-jira-detail-loading`, `company-jira-detail-readFailed`. Empty: §5.3 and §6.4.

To hold these sections, Google, Jira, Linear and Outlook details move off `Form` onto `SettingsSection`s in a `ScrollView`, their other sections ported as they are (as the Slack spec did for Slack, its decision 1).

### 4.3 Row states

| Row | When | Status line (Tone) | Action |
|---|---|---|---|
| Syncing | as today | "Syncing · last sync 3 min ago" (secondary, green dot) | hover actions as today |
| **Not connected** | a vendor of a stored company with no account (skipped, cancelled, failed, stopped) | "Not connected" (gray dot) | **Connect** — runs that vendor's login with the company's client, no confirm (the owner's own press) |
| Re-login, bundle replaced | **Replace** marked the vendor | "Re-login needed — Acme changed its app" (`Tone.error`) | **Re-login** |
| Re-login, client gone | refresh `invalid_client` and no newer bundle stored | "Re-login needed — your company changed its app; open the new link" (`Tone.error`) | **Paste a company code** |
| Re-login, untied | `company_slug = ''`, unknown client (parent §5) | "Re-login needed — open your company's link" (`Tone.error`) | **Paste a company code** |
| Stopped by policy | §5.4, §6.5 | "Stopped by your organization — data kept" (gray) | none |
| Dead API token | §6.3 | "The API token stopped working (expired or revoked) — paste a new one" (`Tone.error`) | **Paste a new token** |

Shots: `company-google-detail-relogin` (the three re-login rows), `company-linear-detail` (a Not connected row), `company-jira-detail-tokenError`. Re-login rows are `needsAttention` (status error) and so give the overview banner and the red badge; **Not connected** rows are not (decision A5).

## 5. Use my own Google project (parent §4)

### 5.1 Where

Google detail → **Use my own Google project** (secondary button in "Add an account", and on the shared-Google banner). It replaces `AddGoogleAccountView`'s "Advanced: custom OAuth client" disclosure (owner, ask #1490); the CLI `google add --client-id --client-secret-stdin` stays (parent §4).

### 5.2 The page (in the Google detail; `-narrow` at 360)

A page in the Google detail, like Jira's drill-in, with **‹ Google** as the way back (decision S26): the flow takes about ten minutes in Google Cloud Console, too long for a sheet. Leaving the page keeps nothing but a dropped JSON while the app runs; nothing is stored before **Connect** succeeds.

| State | Shot | What shows | Buttons |
|---|---|---|---|
| Empty | `company-ownGoogle-empty` (+ `-narrow`) | "Use my own Google project" / "Gmail and Calendar through a Google Cloud project you own. About ten minutes, once."; guide with **Open**: "Create a project"; "Turn on the Gmail API and the Google Calendar API"; "OAuth consent screen: user type External, and add yourself as a test user"; "Publish the app to production. Google calls it unverified; that is expected for your own project"; "Credentials → Create OAuth client → Desktop app, then download its JSON"; drop zone; note "The first sign-in shows “Google hasn't verified this app”. Choose Advanced → Go to your project: it is your own." | **Connect** (disabled) |
| Ready | `company-ownGoogle-ready` | the dropped file | **Connect** |
| Busy | `company-ownGoogle-checking` | "Checking the client with Google…", then the browser sign-in (the existing Google login wait) | **Connect** disabled |
| Rejected | `company-ownGoogle-checkFailed` | the Google step's rejected line | **Try again** |
| Network error | (layout of `checkFailed`) | "Could not reach Google: the request timed out. Nothing was saved." | **Try again** |
| Done | `company-ownGoogle-done` | "Connected bob@example.org through your own project" / "The first sync starts now." | **Done** |
| Done, weekly (S2 fails) | `company-ownGoogle-done-weekly` | the same + "Google asks a project like this to sign in again every 7 days. Watchtower reminds you when it is time." | **Done** |

The weekly frame ships only if spike S2 fails (parent §4); then the account row also says "Re-login due in <n> days" from day 5 and the existing Re-login state after day 7.

### 5.3 Google empty state

`company-google-detail-empty`: "Calendar connects through Watchtower's app. Gmail needs a Google project: your company's (ask your admin for the link) or your own." — **Connect Google Calendar** (prominent), **Use my own Google project**, quiet **Paste a company code**. With a stored company that has a `google` block, the company's Not connected row (§4.3) shows instead and **Connect** there is the prominent action.

### 5.4 Policy lock (`AllowOwnGoogleProject = false`)

`company-google-detail-locked`: **Use my own Google project** is gone everywhere (the add section, the banner); the own-project group shows its rows as "Stopped by your organization — data kept", then a lock card "Your organization does not allow own Google projects. Ask IT for your company's link.", the quiet **What IT can set** (§8) and **Managed by your organization**. Company and shared-client accounts are untouched (parent D24).

## 6. Connect Jira with an API token (parent §4b)

### 6.1 Where

Jira detail → "Add an account": **Connect with Acme's Atlassian app** (when a stored company has an `atlassian` block) and **Connect with an API token**; the Atlassian banner's quiet **Connect with an API token**.

### 6.2 The sheet (520 pt; `-narrow` at 380)

A sheet: one short form, the style guide's case for a sheet (decision S26).

Top: "Connect Jira with an API token" / "For a person whose company has no Atlassian app yet, or who prefers a token. The token stays on this Mac." "1. Create a scoped API token" + "On your Atlassian account's Security page, create an API token with scopes: the Jira scopes Watchtower lists, and the Confluence ones if you use Confluence." + **Open Atlassian's token page**, quiet **Copy scopes**; "2. Fill in": Atlassian email, Site, API token (secure); the scoped-token hint "A token without scopes works too, but a scoped one can read only what Watchtower needs."

| State | Shot | What shows | Buttons |
|---|---|---|---|
| Empty | `company-token-empty` (+ `-narrow`) | the form, empty | **Cancel**, **Connect** (disabled until all three) |
| Ready | `company-token-ready` | filled | **Connect** |
| Busy | `company-token-checking` | "Checking the token with acme.atlassian.net…" | **Connect** disabled |
| 401 at add | `company-token-unauthorized` | "Atlassian did not accept this email and token. Check both, or create a new token." | **Try again** |
| 403 on a scope | `company-token-missingScope` | "This token lacks read:jira-work — create one with the listed scopes." (the scope Atlassian named) | **Try again** |
| Not a Cloud site | `company-token-notCloud` | "acme.example.com is not an Atlassian Cloud site. Enter the address you open Jira at, like acme.atlassian.net." | **Try again** |
| Network | `company-token-network` | "Could not reach acme.atlassian.net: the request timed out. Nothing was saved." | **Try again** |
| Done | `company-token-done` | "Connected to acme.atlassian.net as alice@example.com" / "The first sync starts now." | **Done** |
| New token for a dead one | `company-token-replace` | "Paste a new token for acme.atlassian.net" / "The old token stopped working. Your data was kept; a new token picks up where the sync stopped."; email and site read-only | **Cancel**, **Save token** |

The token goes to `jira add --api-token-stdin` (and its re-auth) on stdin, never argv; the model drops it when the run ends.

### 6.3 The dead token row (D22)

`company-jira-detail-tokenError`: in **API tokens**, the row's status in `Tone.error` "The API token stopped working (expired or revoked) — paste a new one", **Paste a new token** (opens §6.2's replace mode), and — only while PURGE-01's lease would delete this site (purge on, its 30 days counting) — the note "Its data stays. If no new token comes, the 30-day rule deletes it on Dec 18, with a notice 72 hours before." No 72-hour revoked notice appears (the account is `error`, not `revoked`). Once the lease purge is scheduled, the existing `AccountPurgeLine` takes over with its own text.

### 6.4 Jira empty state

`company-jira-detail-empty`: "Your company has no Atlassian app in Watchtower yet. Connect with your own API token, or ask your admin for the company link." — **Connect with an API token** (prominent), quiet **Paste a company code**.

### 6.5 Policy lock (`AllowAtlassianAPIToken = false`)

`company-jira-detail-locked`: **Connect with an API token** is gone (the add section, the banner); the token rows read "Stopped by your organization — data kept"; a lock card "Your organization does not allow Atlassian API tokens. Token sites stop syncing and keep their data." + **What IT can set** + **Managed by your organization**.

## 7. Banners

Both on the service detail's top, `Tone.warning` tint at `ChipTint.fillOpacity`, no dismiss (as the Slack banner), not attention items (no red badge; the overview card's line names it).

| Banner | Shown while | Title / body | Buttons | Overview card line |
|---|---|---|---|---|
| Shared Google (D11) | a Gmail account syncs on the shared client | "Gmail is leaving Watchtower's shared Google app" / "<label> keeps syncing Gmail until Google stops the old sign-in. Move Gmail to your company's or your own Google project; Calendar stays on the shared app." | **Use my own Google project** (hidden by the §5.4 lock), quiet **Paste a company code** | "Gmail on the shared app" |
| Shared Atlassian (D4; D15 amended, ask #1600) | a Jira account signed in through the shared app (`jira accounts --json` `shared_atlassian`) | "Watchtower's shared Atlassian app is retired" / "Your company needs its own Atlassian app — ask your admin or set it up. Sign <site> in again through your company's app or with an API token." (no countdown: the release that ships company setup stops baking the shared app, so its accounts need a Re-login at once) | **Set up for my company**, quiet **Connect with an API token** (hidden by the §6.5 lock) | "Shared app retired — sign in again" |

Shots: `company-google-detail` and `company-jira-detail` (+ `-narrow`).

## 8. The IT guide link (D21)

One constant, `ManagedPolicyHelp.itGuideURL` (the T14 page), with the label **What IT can set**. Every link to it goes through `ManagedPolicyHelp`; there is no second copy of the URL.

| Where | Shot | What |
|---|---|---|
| Settings → System → Privacy → Organization policy | `company-policy-privacy` | the existing lines (now also "Atlassian API tokens" → "Allowed"/"Not allowed" and "Own Google projects" → the same, from `OrganizationPolicyPresentation`), then a row **IT guide** / "Every setting a configuration profile can force, with a sample profile." with **What IT can set** |
| A blocked source's detail (`SourceBlockedNotice`) | `company-policy-blockedNotice` | the existing notice + **What IT can set** |
| The two new locks | `company-google-detail-locked`, `company-jira-detail-locked` | the lock card's link |
| Publish | `company-wizard-publish-done` | next to the `.mobileconfig` |

The Privacy section stays a `Form` section until that pane is ported; the mock draws its rows with the kit.

## 9. The models

| Model | File | Owns | Test (`Tests/Core` unless said) |
|---|---|---|---|
| `CompanySetupWizardModel` (`@Observable`, `AppState.companySetup`) | `WatchtowerCore/Services/Company/CompanySetupWizardModel.swift` | the Services step (ticked services, discovery pre-ticks, the drop warning), steps, rail marks, the fork, field validation, every §2 string; drives `SlackAppSetupModel` for the Slack step; runs the T3/T5 CLI (`watchtower company discover --json`, `company draft save --stdin` / `discard`, `company check <vendor> --json`, `company publish --json`; names final in the plan) | `CompanySetupWizardModelTests` |
| `CompanyVendorGuide` | `WatchtowerCore/Services/Company/CompanyVendorGuide.swift` | per vendor: the Services row and its one-line description, guide lines, deep links, "Not sure?" hints, the Publish "not used"/"skipped" lines, what **We already have one** asks | `CompanyVendorGuideTests` (every vendor has every string; every deep link is `https` on the vendor's host) |
| `CompanyConnectFlowModel` (`@Observable`, `AppState.companyConnect`) | `WatchtowerCore/Services/Company/CompanyConnectFlowModel.swift` | §3.1–§3.3: variants, checkboxes, chain, Skip/Stop, done, replace; one flow at a time | `CompanyConnectFlowModelTests` |
| `CompanyConnectionsPresentation` (pure value) | `WatchtowerCore/Services/Company/CompanyConnectionsPresentation.swift` | §4: the Companies zone, the groups, every row status of §4.3, §6.3's note, §7's banners and card lines, §5.4/§6.5 lock texts | `CompanyConnectionsPresentationTests` |
| `OwnGoogleProjectModel` (`@Observable`, `AppState.ownGoogleProject`) | `WatchtowerCore/Services/Company/OwnGoogleProjectModel.swift` | §5.2 | `OwnGoogleProjectModelTests` |
| `AtlassianTokenFormModel` (`@Observable`, `AppState.atlassianToken`) | `WatchtowerCore/Services/Company/AtlassianTokenFormModel.swift` | §6.2 incl. replace mode; the token on stdin only | `AtlassianTokenFormModelTests` |
| `ManagedPolicyHelp` | `WatchtowerCore/Services/ManagedPolicyHelp.swift` | the URL constant and label; `OrganizationPolicyPresentation` gains the two key lines | `ManagedPolicyHelpTests` (one constant; every link site uses it), `OrganizationPolicyPresentationTests` (new lines) |
| Go pages | `internal/oauthpage` (`CompanyOpen`, `CompanyRefused(reason)`, `CompanyNeedsNewer`) | §3.4 | `TestCompanyPages_*` |

Views (new): `Views/Company/CompanySetupPage.swift` (in the Connections detail, `AppState.selectedConnection` gains a company-setup destination), `Views/Company/CompanyConnectSheet.swift`, `Views/Connections/CompaniesZone.swift`, `Views/Connections/CompanyAccountGroups.swift` (the §4.2 sections, shared by the five details), `Views/Settings/OwnGoogleProjectPage.swift`, `Views/Settings/AtlassianTokenSheet.swift`. Changed: `ConnectionsOverview.swift`, `GoogleConnectionDetail.swift`, `JiraConnectionDetail.swift`, `LinearConnectionDetail.swift`, `EmailConnectionDetail.swift`, `SlackConnectionDetail.swift`, `AddGoogleAccountView.swift`, `ConnectionsSettings.swift` (`SourceBlockedNotice`), `OrganizationPolicySection.swift`.

## 10. Failure modes

| Path | Failure | Behaviour | Test |
|---|---|---|---|
| Wizard | the person setting up leaves the page mid-step (another service, tab, ‹ Connections) | draft saved at the step; a running check or create goes on and lands in the draft; the Companies zone shows "Setup in progress — Continue setup"; reopen lands on the step with the resume line | `CompanySetupWizardModelTests.testLeavingPageKeepsDraftAndResumesAtStep`, `testCheckInFlightLandsInDraft`, `CompanyConnectionsPresentationTests.testSetupInProgressRow` |
| Wizard | Atlassian sign-in fails (`invalid_client`, wrong callback) | error with **Try again** on the step; the step stays open; Publish disabled with its reason | `testAtlassianStepNeedsSignInToken`, `testPublishDisabledUntilAtlassianChecked` (exchange fake returning `invalid_client`) |
| Wizard | the person setting up leaves the page during the Atlassian or Google sign-in | the sign-in keeps waiting on `AppState.companySetup`; a token that comes back marks the step checked and connects the account (§2.12); a sign-in that never returns leaves the step at **Check by signing in** on return | `testLeavingDuringSignInStillConnects` |
| Wizard | a check sign-in succeeds | the account is created with `company_slug`; `company/<slug>.json` stored (first check) or updated (later checks) | `testCheckSignInCreatesCompanyAccount`, `testFirstCheckStoresBundle`, Go `TestJiraAdd_CompanyFromWizardDraft` |
| Wizard | a checked field edited, then re-checked | before the re-check: bundle and account unchanged; the re-check re-logs the same account on the new pair and updates the bundle | `testEditThenRecheckRelogsSameAccount`, `testEditWithoutRecheckKeepsOldPair` |
| Wizard | a check changes a client the stored company already had | warned before the sign-in; acts as Replace for that vendor | `testCheckOverStoredCompanyActsAsReplace` |
| Wizard | Discard after a check | draft deleted; bundle and accounts kept | `testDiscardKeepsCheckedAccountsAndBundle` |
| Wizard | quit between a check and Publish | bundle and account stay (they were stored by the check); the draft resumes | `testQuitAfterCheckKeepsAccount` |
| Wizard | Microsoft consent missing | **Waiting**, **Continue** allowed, Publish not blocked; **Check again** turns it done once consent exists | `testMicrosoftWaitingForConsentDoesNotBlockPublish` (dry-check fake answering consent required) |
| Wizard | Google: no project rights in the organization | the noOrgAccess state; nothing stored | `testNoOrgAccessShowsStepsForAdmin` |
| Wizard | Google secret wrong | the sign-in's code exchange fails: the rejected state | `testGoogleCheckIsSignIn` |
| Wizard | the person setting up edits a checked step (client id, secret, dropped JSON, site, tenant) via Back or the rail | any change to a field the check used clears the step's **checked** mark in the draft at once (the draft stores the checked values' hash; a mismatch = unchecked); Publish is disabled again with its reason until the step is re-checked; re-entering the same values keeps the mark | `testEditingCheckedFieldClearsCheck`, `testSameValuesKeepCheck`, `testPublishDisabledAfterEditOfCheckedStep`, Go `TestCompanyDraft_CheckHashMismatchIsUnchecked` |
| Wizard | `draft.json` unreadable | page opens on Services with the warning and **Show file in Finder**; the file is renamed `draft.json.bad-<ts>`, never deleted; Discard or Publish deletes it; only the newest is kept; the daemon deletes one older than 30 days | `testUnreadableDraftIsRenamedNotDeleted`, `testUnreadableDraftIsNotNoDraft`, Go `TestCompanyDraft_CorruptRenamed`, `TestCompanyDraft_OnlyNewestBadKept`, `TestCompanyDraft_StaleBadDeletedAfter30Days` (fake clock) |
| Wizard | Services: nothing ticked | **Continue** disabled | `testServicesNeedOneTicked` |
| Wizard | Services: discovery found an app | that service pre-ticked with "Found on this Mac" | `testDiscoveredServicesArePreTicked` |
| Wizard | Services: unticking a service whose step holds entries | the in-place warning; **Drop** removes its entries from the draft, **Keep** changes nothing; an empty step drops silently | `testUntickFilledStepAsksFirst`, `testUntickEmptyStepDropsSilently` |
| Wizard | app quits mid-step (incl. during a check) | the draft was saved on each **Continue**; the check's result is lost and re-run on resume; a CLI child is reaped | `testQuitDuringCheckResumesBeforeCheck` + Go `TestCompanyDraft_RoundTrip` (parent) |
| Wizard | Slack app created, then app quits | resume at Slack shows the created app as **Found** ("Acme's saved company setup"); never a second create | `testResumeAfterCreateOffersReuse`, parent `TestAppSetup_ResumeAfterCreate` |
| Wizard | reused Slack app, not a collaborator | error, step open, nothing created | `testNotCollaboratorKeepsStepOpen` (export fake) |
| Wizard | wrong workspace / typo | refused at the step | `testWrongWorkspaceRefused`, per-vendor dry-check fakes |
| Wizard | Atlassian confirm not all ticked | **Continue** disabled | `testAtlassianNeedsAllThreeChecks` |
| Wizard | Publish: token expired | bundle kept, fresh token asked | `testPublishTokenExpiredKeepsSetup` (manifest-update fake `token_expired`) |
| Wizard | Publish: network | bundle kept, **Try again** | `testPublishNetworkFailureKeepsSetup` |
| Wizard | **Discard setup** | draft and its secrets deleted; vendor apps untouched | `testDiscardDeletesDraft` |
| Connect | a web page opens the link | the confirm; nothing before **Connect** | parent `TestCompanyListener_*`, `CompanyConnectFlowModelTests.testLinkStartsAtConfirm` |
| Connect | a second link while a chain runs | refused; the running sheet stays | `testSecondLinkWhileRunningIsRefused` |
| Connect | sheet closed mid-chain | the chain goes on; the card shows progress | `testCloseKeepsChainRunning` |
| Connect | app quits mid-chain | done vendors connected; the rest **Not connected — Connect**; no auto-resume | parent integration test + `CompanyConnectionsPresentationTests.testUnconnectedVendorsShowConnect` |
| Connect | consent cancelled / failed | the row ✗, chain continues | `testCancelledVendorContinues` (fake `access_denied`) |
| Connect | changed bundle | replace warning, **Keep current** default; nothing stored without **Replace** | `testChangedBundleNeedsReplace`, `testKeepCurrentIsDefault` |
| Connect | a vendor forbidden by policy | listed disabled with the lock; never run | `testForbiddenVendorIsNotRun` |
| Listener | bad / oversized / unknown-`v` / `personal` bundle | refusal page with the reason; nothing reaches the app | `TestCompanyPages_*`, parent fixture cases |
| Listener | port busy | the line in the Companies zone and Slack's connect section; code paste works | `CompanyConnectionsPresentationTests.testPortBusyLine` |
| Code paste | not a code | field error, nothing starts | `CompanyConnectFlowModelTests.testPasteRejectsOtherText` |
| Companies zone | a company file is damaged | read-failed state with **Try again**; never shown as "no company" | `CompanyConnectionsPresentationTests.testDamagedFileIsNotEmpty` |
| Rows | `invalid_client` after a secret rotation | "Re-login needed — your company changed its app; open the new link"; attention | `testInvalidClientRow` |
| Own Google | rejected client / network | error with **Try again**; nothing stored | `OwnGoogleProjectModelTests` |
| Own Google | policy turns it off while the page is open | the page goes back to the Google detail with the lock card | `testPolicyLockLeavesPage` |
| API token | 401 / 403 / not Cloud / network at add | the state's text; nothing stored | `AtlassianTokenFormModelTests` (CLI envelope fakes) |
| API token | token dies later | row error, data kept, lease note only while the lease counts | `CompanyConnectionsPresentationTests.testDeadTokenRowAndLeaseNote` |
| API token | policy turns tokens off while the sheet is open | the sheet closes with the lock line | `testPolicyLockClosesSheet` |

## 11. Writers of the same data and who wins

| Data | Writers | Rule | Screen |
|---|---|---|---|
| `company/draft.json` (incl. the ticked `services` and the Slack `app_id` reference) | only the wizard (through the CLI, secrets on stdin) | one wizard run at a time (`AppState.companySetup`); the CLI takes the file's flock | the wizard re-reads it on open |
| The Slack setup record (Slack spec §3.4, T7: app id, client id, stage, link written) | only `slack app create` / `link` / reuse through `SlackAppSetupModel` | **the record is the one source of truth for the Slack app**; the draft holds only a reference (`slack.app_id`), never a copy of its ids or stage; on resume the Slack step reads the record by that id (a missing record → the step starts at **Look** again) | the Slack step re-reads the record each time it opens (tests `CompanySetupWizardModelTests.testSlackStepReadsSetupRecordNotDraft`, `testMissingRecordRestartsSlackStep`) |
| `company/<slug>.json` | link confirm, code paste, publish, **Replace** (parent §8), and the wizard's successful checks (§2.12) | per-file flock, last confirmed write wins; a wizard check that changes a stored vendor's client is a Replace and says so first; a forced MDM bundle never loses — it is an overlay read at launch, not a file write | the Companies zone re-reads on appear and when a flow ends |
| Account rows, `company_slug`, `auth_kind` | Go only (parent §8) | — | the account view models re-read on appear (existing) |
| A running chain | link, code, MDM **Connect all**, **Connect the rest**, **Re-login** | one at a time (`CompanyConnectFlowModel`, sharing the guard with `SlackAuthFlowState`) | the running sheet stays |

## 12. Mockups

Design-only SwiftUI scenes in `DesignShotCatalog` (`CompanySetupShotFixtures`, `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+CompanySetup.swift`, `+CompanySetupWizard.swift`, `+CompanySetupBlocks.swift`), built from the design kit (`SettingsSection`, `SettingRow`, `Chip`, `OutlineTag`, `.card()`, `.kitRow`, `.kit*` buttons, `ManagedByOrganizationBadge`, `Tone`) and, on the overview, the real `ConnectionCard` and `ConnectionAttentionBanner`. Each frame is data drawn by one renderer. Every string comes from `CompanySetupMockCopy` (`Tests/DesignShots/CompanySetupMockCopy.swift`), pinned by `CompanySetupMockCopyTests` — including that the parent's verbatim texts are verbatim, that `blockedTitle` equals the shipped `SourceBlockedNotice.title`, that every overview frame and wizard scene has a shot, and that every screen has a narrow frame. Rendered by `DesignShotsTests.testCompanySetupShotsRender` (`make desktop-shots` renders them with the rest), light and dark, committed under `docs/design/mockups/company-setup/` as `<shot>-light.png` / `<shot>-dark.png`. Sample data only (`Acme`, `acme`, `example.com`, made-up ids).

Narrow frames — exactly this set, asserted by `CompanySetupMockCopyTests` (`CompanySetupShotFixtures.narrowShots`): one per screen family (connect confirmation, Companies overview, Google detail, Jira detail, own Google project page, API-token sheet) and one per distinct wizard step layout (`services`, `slack-found`, `slack-create`, `google-create`, `atlassian-create`, `publish-done`). Every other frame shares one of these layouts, so its narrow form adds nothing; the remaining frames of a family differ in content, not in layout.

Light frames linked; each has a `-dark` twin. The vendor-step shots show a company with all five services ticked, so their rail lists Services, the five services, Link deny list and Publish.

**Wizard**

| Shot | State |
|---|---|
| [`company-wizard-services`](../../design/mockups/company-setup/company-wizard-services-light.png) | empty: first step, nothing found or ticked, **Continue** disabled |
| [`company-wizard-services-narrow`](../../design/mockups/company-setup/company-wizard-services-narrow-light.png) | the same at 420 pt |
| [`company-wizard-services-found`](../../design/mockups/company-setup/company-wizard-services-found-light.png) | Slack and Atlassian pre-ticked from discovery |
| [`company-wizard-services-change`](../../design/mockups/company-setup/company-wizard-services-change-light.png) | **Change services**: unticking a filled step asks first |
| [`company-wizard-draftUnreadable`](../../design/mockups/company-setup/company-wizard-draftUnreadable-light.png) | error: the draft cannot be read, kept as `.bad-<ts>` |
| [`company-wizard-loading`](../../design/mockups/company-setup/company-wizard-loading-light.png) | loading: the page reads the draft (Task 22) |
| [`company-wizard-readFailed`](../../design/mockups/company-setup/company-wizard-readFailed-light.png) | error: `company draft show` failed, **Try again** (Task 22) |
| [`company-wizard-looking`](../../design/mockups/company-setup/company-wizard-looking-light.png) | loading: looking for known apps |
| [`company-wizard-slack-notFound`](../../design/mockups/company-setup/company-wizard-slack-notFound-light.png) | empty: first open, nothing found |
| [`company-wizard-slack-found`](../../design/mockups/company-setup/company-wizard-slack-found-light.png) | found one: **Use Watchtower** / **Create new** |
| [`company-wizard-slack-found-narrow`](../../design/mockups/company-setup/company-wizard-slack-found-narrow-light.png) | the choices at 420 pt |
| [`company-wizard-slack-create`](../../design/mockups/company-setup/company-wizard-slack-create-light.png) | configuration token |
| [`company-wizard-slack-create-narrow`](../../design/mockups/company-setup/company-wizard-slack-create-narrow-light.png) | the token form at 420 pt |
| [`company-wizard-slack-existing`](../../design/mockups/company-setup/company-wizard-slack-existing-light.png) | **We already have one**, wrong link |
| [`company-wizard-slack-progress`](../../design/mockups/company-setup/company-wizard-slack-progress-light.png) | busy: reading the reused app |
| [`company-wizard-slack-manifestDiff`](../../design/mockups/company-setup/company-wizard-slack-manifestDiff-light.png) | reused app differs, update shown first |
| [`company-wizard-slack-notCollaborator`](../../design/mockups/company-setup/company-wizard-slack-notCollaborator-light.png) | error: not a collaborator, **Try again** |
| [`company-wizard-slack-wrongWorkspace`](../../design/mockups/company-setup/company-wizard-slack-wrongWorkspace-light.png) | error: app of another workspace |
| [`company-wizard-slack-badToken`](../../design/mockups/company-setup/company-wizard-slack-badToken-light.png) | error: bad token |
| [`company-wizard-google-notFound`](../../design/mockups/company-setup/company-wizard-google-notFound-light.png) | nothing found, hint |
| [`company-wizard-google-found`](../../design/mockups/company-setup/company-wizard-google-found-light.png) | two candidates |
| [`company-wizard-google-reuseSecret`](../../design/mockups/company-setup/company-wizard-google-reuseSecret-light.png) | reuse: secret asked |
| [`company-wizard-google-create`](../../design/mockups/company-setup/company-wizard-google-create-light.png) | create new: guide + drop zone |
| [`company-wizard-google-create-narrow`](../../design/mockups/company-setup/company-wizard-google-create-narrow-light.png) | the same at 420 pt |
| [`company-wizard-google-checking`](../../design/mockups/company-setup/company-wizard-google-checking-light.png) | busy: your own sign-in, which also connects you |
| [`company-wizard-google-noOrgAccess`](../../design/mockups/company-setup/company-wizard-google-noOrgAccess-light.png) | no project rights in the organization: who to ask |
| [`company-wizard-google-checkFailed`](../../design/mockups/company-setup/company-wizard-google-checkFailed-light.png) | error, **Try again** |
| [`company-wizard-atlassian-create`](../../design/mockups/company-setup/company-wizard-atlassian-create-light.png) | create new |
| [`company-wizard-atlassian-create-narrow`](../../design/mockups/company-setup/company-wizard-atlassian-create-narrow-light.png) | guide + fields at 420 pt (Linear, Microsoft share it) |
| [`company-wizard-atlassian-signin`](../../design/mockups/company-setup/company-wizard-atlassian-signin-light.png) | busy: your own sign-in, which also connects you |
| [`company-wizard-atlassian-signinFailed`](../../design/mockups/company-setup/company-wizard-atlassian-signinFailed-light.png) | error: `invalid_client`, **Try again** |
| [`company-wizard-atlassian-confirm`](../../design/mockups/company-setup/company-wizard-atlassian-confirm-light.png) | confirm checklist, two of three ticked |
| [`company-wizard-resume`](../../design/mockups/company-setup/company-wizard-resume-light.png) | resumed draft (Google skipped) |
| [`company-wizard-linear-create`](../../design/mockups/company-setup/company-wizard-linear-create-light.png) | Linear |
| [`company-wizard-microsoft-create`](../../design/mockups/company-setup/company-wizard-microsoft-create-light.png) | Microsoft 365 |
| [`company-wizard-microsoft-adminConsent`](../../design/mockups/company-setup/company-wizard-microsoft-adminConsent-light.png) | waiting for admin consent: link to send, **Continue** allowed |
| [`company-wizard-microsoft-checkFailed`](../../design/mockups/company-setup/company-wizard-microsoft-checkFailed-light.png) | error: tenant rejects the client |
| [`company-wizard-denyList`](../../design/mockups/company-setup/company-wizard-denyList-light.png) | deny list |
| [`company-wizard-denyList-invalid`](../../design/mockups/company-setup/company-wizard-denyList-invalid-light.png) | wrong host |
| [`company-wizard-publish-ready`](../../design/mockups/company-setup/company-wizard-publish-ready-light.png) | Publish: name and summary |
| [`company-wizard-publish-busy`](../../design/mockups/company-setup/company-wizard-publish-busy-light.png) | busy |
| [`company-wizard-publish-done`](../../design/mockups/company-setup/company-wizard-publish-done-light.png) | link, code, profile, IT guide |
| [`company-wizard-publish-done-narrow`](../../design/mockups/company-setup/company-wizard-publish-done-narrow-light.png) | the same at 420 pt |
| [`company-wizard-publish-done-noSlack`](../../design/mockups/company-setup/company-wizard-publish-done-noSlack-light.png) | Slack skipped |
| [`company-wizard-publish-tokenExpired`](../../design/mockups/company-setup/company-wizard-publish-tokenExpired-light.png) | expired configuration token |
| [`company-wizard-publish-failed`](../../design/mockups/company-setup/company-wizard-publish-failed-light.png) | error, **Try again** |

**The employee**

| Shot | State |
|---|---|
| [`company-connect-confirm`](../../design/mockups/company-setup/company-connect-confirm-light.png) | link: **Connect Acme?** |
| [`company-connect-confirm-narrow`](../../design/mockups/company-setup/company-connect-confirm-narrow-light.png) | the same at 360 pt |
| [`company-connect-confirm-code`](../../design/mockups/company-setup/company-connect-confirm-code-light.png) | pasted code |
| [`company-connect-confirm-again`](../../design/mockups/company-setup/company-connect-confirm-again-light.png) | same bundle again |
| [`company-connect-confirm-mdm`](../../design/mockups/company-setup/company-connect-confirm-mdm-light.png) | **Acme — Connect all** |
| [`company-connect-chain`](../../design/mockups/company-setup/company-connect-chain-light.png) | busy: the chain |
| [`company-connect-chain-failed`](../../design/mockups/company-setup/company-connect-chain-failed-light.png) | one consent cancelled, chain goes on |
| [`company-connect-done`](../../design/mockups/company-setup/company-connect-done-light.png) | partly connected |
| [`company-connect-replace`](../../design/mockups/company-setup/company-connect-replace-light.png) | changed company: **Keep current** default |
| [`company-page-open`](../../design/mockups/company-setup/company-page-open-light.png) | browser: continue in Watchtower |
| [`company-page-refused`](../../design/mockups/company-setup/company-page-refused-light.png) | browser: bad bundle |
| [`company-page-newerVersion`](../../design/mockups/company-setup/company-page-newerVersion-light.png) | browser: unknown `v` |

**Connections**

| Shot | State |
|---|---|
| [`company-overview-companies`](../../design/mockups/company-setup/company-overview-companies-light.png) | a company, partly connected |
| [`company-overview-companies-narrow`](../../design/mockups/company-setup/company-overview-companies-narrow-light.png) | the same at 420 pt |
| [`company-overview-mdm`](../../design/mockups/company-setup/company-overview-mdm-light.png) | MDM bundle: **Connect all** |
| [`company-overview-relogin`](../../design/mockups/company-setup/company-overview-relogin-light.png) | Re-login needed: banner + card |
| [`company-overview-empty`](../../design/mockups/company-setup/company-overview-empty-light.png) | no company |
| [`company-overview-setupInProgress`](../../design/mockups/company-setup/company-overview-setupInProgress-light.png) | a draft exists: **Continue setup** |
| [`company-overview-loading`](../../design/mockups/company-setup/company-overview-loading-light.png) | loading |
| [`company-overview-readFailed`](../../design/mockups/company-setup/company-overview-readFailed-light.png) | error, **Try again** |
| [`company-overview-codePaste`](../../design/mockups/company-setup/company-overview-codePaste-light.png) | code paste, wrong text |
| [`company-overview-portBusy`](../../design/mockups/company-setup/company-overview-portBusy-light.png) | port 18551 busy |
| [`company-google-detail`](../../design/mockups/company-setup/company-google-detail-light.png) | grouped rows (company, own project, shared app), shared-Google banner |
| [`company-google-detail-narrow`](../../design/mockups/company-setup/company-google-detail-narrow-light.png) | the same at 360 pt |
| [`company-google-detail-relogin`](../../design/mockups/company-setup/company-google-detail-relogin-light.png) | the three Re-login rows |
| [`company-google-detail-empty`](../../design/mockups/company-setup/company-google-detail-empty-light.png) | empty |
| [`company-google-detail-loading`](../../design/mockups/company-setup/company-google-detail-loading-light.png) | loading |
| [`company-google-detail-readFailed`](../../design/mockups/company-setup/company-google-detail-readFailed-light.png) | error, **Try again** |
| [`company-google-detail-locked`](../../design/mockups/company-setup/company-google-detail-locked-light.png) | `AllowOwnGoogleProject = false` |
| [`company-jira-detail`](../../design/mockups/company-setup/company-jira-detail-light.png) | grouped rows, token row, Atlassian banner |
| [`company-jira-detail-narrow`](../../design/mockups/company-setup/company-jira-detail-narrow-light.png) | the same at 360 pt |
| [`company-jira-detail-tokenError`](../../design/mockups/company-setup/company-jira-detail-tokenError-light.png) | dead token, lease note |
| [`company-jira-detail-empty`](../../design/mockups/company-setup/company-jira-detail-empty-light.png) | empty |
| [`company-jira-detail-loading`](../../design/mockups/company-setup/company-jira-detail-loading-light.png) | loading |
| [`company-jira-detail-readFailed`](../../design/mockups/company-setup/company-jira-detail-readFailed-light.png) | error, **Try again** |
| [`company-jira-detail-locked`](../../design/mockups/company-setup/company-jira-detail-locked-light.png) | `AllowAtlassianAPIToken = false` |
| [`company-slack-workspaces`](../../design/mockups/company-setup/company-slack-workspaces-light.png) | Slack workspaces grouped, untied row |
| [`company-linear-detail`](../../design/mockups/company-setup/company-linear-detail-light.png) | Linear grouped, Not connected |
| [`company-outlook-detail`](../../design/mockups/company-setup/company-outlook-detail-light.png) | Outlook grouped |

**Own Google project, API token, IT guide**

| Shot | State |
|---|---|
| [`company-ownGoogle-empty`](../../design/mockups/company-setup/company-ownGoogle-empty-light.png) | empty |
| [`company-ownGoogle-empty-narrow`](../../design/mockups/company-setup/company-ownGoogle-empty-narrow-light.png) | the same at 360 pt |
| [`company-ownGoogle-ready`](../../design/mockups/company-setup/company-ownGoogle-ready-light.png) | JSON dropped |
| [`company-ownGoogle-checking`](../../design/mockups/company-setup/company-ownGoogle-checking-light.png) | busy |
| [`company-ownGoogle-checkFailed`](../../design/mockups/company-setup/company-ownGoogle-checkFailed-light.png) | error, **Try again** |
| [`company-ownGoogle-done`](../../design/mockups/company-setup/company-ownGoogle-done-light.png) | connected |
| [`company-ownGoogle-done-weekly`](../../design/mockups/company-setup/company-ownGoogle-done-weekly-light.png) | connected, weekly re-login (only if S2 fails) |
| [`company-token-empty`](../../design/mockups/company-setup/company-token-empty-light.png) | empty |
| [`company-token-empty-narrow`](../../design/mockups/company-setup/company-token-empty-narrow-light.png) | the same at 380 pt |
| [`company-token-ready`](../../design/mockups/company-setup/company-token-ready-light.png) | filled |
| [`company-token-checking`](../../design/mockups/company-setup/company-token-checking-light.png) | busy |
| [`company-token-unauthorized`](../../design/mockups/company-setup/company-token-unauthorized-light.png) | 401 at add |
| [`company-token-missingScope`](../../design/mockups/company-setup/company-token-missingScope-light.png) | 403, named scope |
| [`company-token-notCloud`](../../design/mockups/company-setup/company-token-notCloud-light.png) | not a Cloud site |
| [`company-token-network`](../../design/mockups/company-setup/company-token-network-light.png) | network error, **Try again** |
| [`company-token-done`](../../design/mockups/company-setup/company-token-done-light.png) | connected |
| [`company-token-replace`](../../design/mockups/company-setup/company-token-replace-light.png) | new token for a dead one |
| [`company-policy-privacy`](../../design/mockups/company-setup/company-policy-privacy-light.png) | Organization policy + IT guide row |
| [`company-policy-blockedNotice`](../../design/mockups/company-setup/company-policy-blockedNotice-light.png) | blocked source + IT guide link |

Not mocked, by design: the system confirmation of **Discard setup**, the vendors' own consent pages, the `.mobileconfig` save panel, the browser's "can't connect" page, and the text-only variants that reuse a mocked layout (each named "(layout of …)" above).

## 13. Promises → tasks → tests

Screen tasks (C) follow the parent's tasks they need.

| Promise | Task | Needs | Test |
|---|---|---|---|
| The Slack step's engine exists before the wizard needs it | **C0** `SlackAppSetupModel` (Slack screens spec §3.5, no sheet) — first task of the company plan; Slack screens S3 reuses it | Slack plan B T7 | `SlackAppSetupModelTests` (Slack spec §3.5's list) |
| A bad Atlassian or Google client never reaches Publish: the step checks it by the setter-up's own sign-in, which is also their connection, Publish waits for it, and editing a checked field un-checks it | C1 | T3, T7 | `testAtlassianStepNeedsSignInToken`, `testPublishDisabledUntilAtlassianChecked`, `testGoogleCheckIsSignIn`, `testCheckSignInCreatesCompanyAccount`, `testEditingCheckedFieldClearsCheck` |
| An unreadable draft is kept, not lost, and the wizard starts again | C1 | T3 | `testUnreadableDraftIsRenamedNotDeleted`, `testUnreadableDraftIsNotNoDraft` |
| The Slack app has one source of truth (the setup record); the draft only references it | C0, C1 | T7 | `testSlackStepReadsSetupRecordNotDraft` |
| The wizard is a page in Connections; leaving it keeps the draft and the Companies zone offers **Continue setup** | C1 `CompanySetupWizardModel` + `CompanySetupPage` | T3 | `testLeavingPageKeepsDraftAndResumesAtStep`, `testSetupInProgressRow` |
| The first step picks the services; only ticked ones become steps; discovery pre-ticks; other tools point to Quick Connections | C1 | T3 | `testServicesNeedOneTicked`, `testDiscoveredServicesArePreTicked`, `testRailListsOnlyTickedServices`, `testUntickFilledStepAsksFirst`, `CompanyVendorGuideTests.testMCPNoteOpensQuickConnections` |
| The wizard with a step per ticked vendor, skippable, resumable, with every state above | C1 `CompanySetupWizardModel` + `CompanyVendorGuide` | C0, T3, T5 | `CompanySetupWizardModelTests`, `CompanyVendorGuideTests` |
| Existing apps first, never a second app (D19) | C1 | T3, T5 | `testFoundAppIsDefault`, `testResumeAfterCreateOffersReuse`, `testNotCollaboratorKeepsStepOpen`, parent discovery tests |
| The check sign-in is the setter-up's real connection; the bundle is stored at the first check; edit, Discard and Connect this Mac behave as §2.12 | C1 | T1, T3, T7 | `testCheckSignInCreatesCompanyAccount`, `testFirstCheckStoresBundle`, `testEditThenRecheckRelogsSameAccount`, `testDiscardKeepsCheckedAccountsAndBundle`, `testConnectThisMacOffersOnlyUnconnected` |
| The wizard never assumes admin rights: each step says what needs them and who to ask | C1 + `CompanyVendorGuide` | T3 | `testNoOrgAccessShowsStepsForAdmin`, `testMicrosoftWaitingForConsentDoesNotBlockPublish`, `CompanyVendorGuideTests.testEveryVendorNamesItsAdminNeeds` |
| Publish shows link, code, profile and the IT guide; token expiry keeps the setup | C1 | T5, T6, T14 | `testPublishDoneOffersLinkCodeProfile`, `testPublishTokenExpiredKeepsSetup` |
| One press connects every ticked vendor; cancelled vendors wait in Connections | C2 `CompanyConnectFlowModel` + the sheet | T2 | `CompanyConnectFlowModelTests` |
| A changed company needs **Replace**, **Keep current** default | C2 | T2 | `testChangedBundleNeedsReplace`, `testKeepCurrentIsDefault` |
| Refusal pages and the clean redirect page | C2 (Go) | T2 | `TestCompanyPages_*` |
| Companies zone, rows grouped by company, Not connected and Re-login rows | C3 `CompanyConnectionsPresentation` + `CompaniesZone` + `CompanyAccountGroups`, details off `Form` | T1b, T2, T7 | `CompanyConnectionsPresentationTests`, `ConnectionsTabTests` (zone present, attention rule unchanged) |
| MDM **Connect all**, code paste, port busy | C3 | T2, T6 | `testMDMCompanyIsProminent`, `testPortBusyLine`, `testPasteRejectsOtherText` |
| Personal Gmail page; its lock; the custom-client disclosure gone from Add Google Account | C4 `OwnGoogleProjectModel` + page | T8, T6 | `OwnGoogleProjectModelTests`, `testOwnGoogleLock` |
| API token sheet, dead token row with lease note, its lock | C5 `AtlassianTokenFormModel` + sheet | T13, T6 | `AtlassianTokenFormModelTests`, `testDeadTokenRowAndLeaseNote`, `testTokenLock` |
| The two banners, not attention items | C3 | T10 | `testSharedGoogleBanner`, `testSharedAtlassianBanner`, `testBannersAreNotAttention` |
| The IT guide link everywhere from one constant (D21) | C6 `ManagedPolicyHelp` + Privacy rows + lock links | T6, T14 | `ManagedPolicyHelpTests`, `OrganizationPolicyPresentationTests` |
| Every UI text in a model with a test (parent T3) | C1–C6 | — | the model tests above pin every string of §2–§8 |
| Each screen family has a narrow frame, and each distinct wizard step layout | C1–C6 | — | `CompanySetupMockCopyTests.testEveryFrameHasAShotAndNamesAreUnique` (the exact set) |
| Each new screen looked at before merge | C1–C6 | — | the implementation re-renders the same shot names from the real views (`DesignShotsTests.testCompanySetupShotsRender`) |
| The guide says all of this | C7 docs: `docs/guide/` connections pages (with parent T12), `docs/features/connections-tab.md`, `mdm-policy.md` | C1–C6 | `go test ./docs/guide` |

## 14. Decisions

### Sourced

| # | Decision | Source |
|---|---|---|
| S28 | The check sign-in (Google, Atlassian) is the setter-up's real connection: its tokens are kept, the account is tied to the company, and the bundle is stored at the first successful check; Publish only adds the rest and writes the Slack page, link, code and profile. Microsoft and Linear keep the dry authorize (public clients, no secret) | ask #1503 (option A; replaces A25) |
| S29 | The person setting up may be any employee, not an admin: the UI says "you", and each step says what needs admin rights and what to do without them | ask #1503 (owner's note) |
| S21 | The Atlassian step is checked by the setter-up's own 3LO sign-in; Publish is disabled with a named reason until it succeeds or Atlassian is skipped | decided by the agent, answering review ask #1496 |
| S22 | An unreadable draft is kept as `draft.json.bad-<ts>`, not deleted; the wizard starts again on Services | decided by the agent, answering review ask #1496 |
| S23 | The Slack setup record owns the Slack app; the draft keeps only its `app_id` | decided by the agent, answering review ask #1496 |
| S24 | Google, Jira, Linear and Outlook details move off `Form` onto `SettingsSection`s (as Slack did, its decision 1) | ask #1498 |
| S25 | A **Companies** zone on the overview above Sources, always shown (one inviting line when empty) | ask #1498 |
| S26 | Following S18, sheets stay only for short blocking flows: the connect confirmation, chain and replace warning (§3) and the API-token form (§6.2) are sheets; **Use my own Google project** becomes a page in the Google detail, like the wizard (ten minutes of console work) | ask #1498 |
| S27 | The wizard draft keeps typed secrets (Google, Atlassian) in `draft.json`, 0600, until Publish or Discard; the Slack configuration token is never written | ask #1498 |
| S1 | One **Set up for my company** for every vendor; the Slack-only setup becomes its Slack step | parent D7 (ask #1440) |
| S2 | Each step first looks for a known app; found → "Use <app>" default + **Create new**; none → **Create new** default / **We already have one** + "Not sure?" | parent D19 (ask #1473) |
| S3 | Reused Slack app, not a collaborator: the error, the step stays open, nothing created | parent §2, D19 (ask #1473) |
| S4 | Atlassian settings confirmed by a three-item checklist with deep links | parent §2.4, D6 (ask #1447) |
| S5 | Publish shows the link, the code, the `.mobileconfig` and the IT guide link | parent §2 step 8, D21 (conversation 2026-11-18) |
| S6 | The confirmation lists every vendor with a checkbox; nothing before **Connect** | parent §3 step 1, D8 (ask #1451) |
| S7 | A changed company: separate warning, **Keep current** default, **Replace** beside it; MDM replaces silently | parent §3 step 5 |
| S8 | Cancelled consent → **Not connected — Connect**; same bundle again offers only the rest | parent §3 steps 3–4 |
| S9 | The code paste and the MDM bundle use the same confirmation and chain | parent §3 (D9) |
| S10 | **Re-login needed** texts for `invalid_client` and untied accounts | parent §5, §7 |
| S11 | Own Google project wizard (External, test user, publish unverified) and the weekly fallback | parent §4, D1 (ask #1440) |
| S12 | API token as an option beside OAuth; 401 → error, data kept, only the 30-day lease | parent §4b, D20, D22 (ask #1476) |
| S13 | Policy locks for own Google projects and API tokens; stopped accounts keep data | parent D24 (ask #1476), POLICY-03 |
| S14 | Banner texts for shared Google (Calendar only) and the retired Atlassian app | parent §5, D11 (ask #1455), D15 (ask #1455, amended by ask #1600: no countdown) |
| S15 | One IT page linked from Privacy, Connections locks and Publish | parent D21 (conversation 2026-11-18) |
| S16 | Screens spec with a mockup for every state, strings in models with tests | parent D14, T3 |
| S17 | The wizard's first step, "What does your company use?", picks the services; only ticked ones become steps; discovery pre-ticks; anything else is connected through Quick Connections (MCP connectors), said in a note under the list | conversation 2026-11-18 (owner: first step picks the services; others through MCP connectors) |
| S18 | The wizard is a page in the Connections detail area (like Jira's drill-in), not a sheet; leaving it keeps the draft and the Companies zone shows **Continue setup** | ask #1490 (N1) |
| S19 | "Advanced: custom OAuth client" is removed from Add Google Account, replaced by **Use my own Google project**; the CLI flags stay | ask #1490 (N2) |
| S20 | No "forget company" in v1: accounts are removed one by one, the card stays with every vendor **Not connected** | ask #1490 (N3) |

### Decided by the agent

| # | Decision |
|---|---|
| A2 | The company name is derived (Slack workspace → Google domain → Atlassian site) and only shown for correction at Publish |
| A4 | **Connect the rest** reuses the confirmation's same-bundle variant |
| A5 | **Not connected** rows are not attention items (no banner, no red badge); **Re-login needed** rows are (status error) |
| A6 | Account groups per service: company sections, then own Google project, API tokens, shared app, other accounts |
| A8 | The rail folds into "Step n of m · <step>" under 520 pt (m counts Services, the ticked services, the deny list and Publish) |
| A9 | Linear's client id is checked by a dry authorize URL like Google's and Microsoft's |
| A10 | The chain runs on `AppState`; closing the sheet keeps it running; **Skip this service** and **Stop** |
| A11 | The listener's clean page after a valid link reads "Continue in Watchtower"; refusal reasons named per cause |
| A12 | The draft is written through the CLI with secrets on stdin; Go owns its format and 0600 mode |
| A13 | A forbidden vendor shows in the confirmation disabled with the lock |
| A15 | Locks hide the button and show a lock card with **What IT can set** and **Managed by your organization** |
| A16 | The API token sheet has a replace mode (email and site read-only) for a dead token |
| A17 | The dead-token lease note shows only while PURGE-01's lease counts; the existing purge line takes over once scheduled |
| A18 | The Organization policy section gains lines for the two new keys and an **IT guide** row |
| A19 | The Slack setup-record rows (Slack spec §3.4) stay and open the wizard at the matching step; `/slack/connect` links keep working |
| A20 | Connections → Slack's connect field also accepts a company link or code |
| A21 | Changed ids in the replace warning are shortened to first 4 + last 3 characters |
| A23 | The per-step "Skipped: …" notes are gone; what an unused or skipped service means for colleagues is said once, in the Publish summary |
| A24 | The services' order and their one-line descriptions; the drop warning appears in place on the Services step, **Keep** prominent |
| A29 | Per-vendor admin needs and fallbacks of §2.11: Google's noOrgAccess state with steps to copy; Microsoft's admin-consent link with **Continue** allowed and **Waiting** (not blocking Publish); Atlassian needs no admin; Linear to be confirmed by spike S3 |
| A30 | §2.12's rules: edit keeps the old pair until the re-check re-logs the same account; a check over a stored company's client acts as Replace and warns first; Discard keeps the bundle and accounts; under an MDM-forced bundle the check is stored but the overlay wins |
| A31 | Organization policy values for the new keys read "allowed" / "not allowed" in lowercase like the pane's existing lines (the `company-policy-privacy` mockup capitalises them); a forced `CompanyBundle` adds a "Company: <name>" line (name only, never the bundle) — found when comparing Task 20's shots with the mockup |
| A26 | The company plan builds `SlackAppSetupModel` first (C0) instead of waiting for the Slack screens plan |
| A27 | An unreadable draft is renamed `draft.json.bad-<ts>` (0600) and shown with **Show file in Finder**; Discard or Publish deletes it; only the newest is kept; the daemon deletes one older than 30 days |
| A28 | Editing a field a step's check used un-checks the step (hash of the checked values in the draft) |
| A32 | (agent, Task 22 review) Of the Slack setup-record rows only **Add the link to the app** (`link_missing`) opens the wizard (at Publish; for another app than the draft's, at the Slack step). `pending_create`, `install` (**Continue setup**) and `approval` (**Check again**) stay on plan B's sheet: the wizard's Slack step runs no admin connect, approval check or lost-create clear, so it would mark an app ready that was never installed. Narrows A19 and §0's §3.4 row |
| A33 | (owner, ask #1613) The Company name edited at Publish after a check stored the setup changes only the display name; the slug, the file name and the accounts' `company_slug` stay (§2.12) |

## 15. Needs the owner

Nothing open: N1–N3 were answered in ask #1490 (decisions S18–S20).

## 16. Out of scope

- The vendors' consent pages and console pages (deep-link targets only).
- The IT page itself (parent T14, website repo); this spec only links it.
- The phone: no company screens (the heartbeat rows list accounts as today).
- The Live layer for Google/Atlassian (parent D13).

## 17. Open

- S1–S3 spikes of the parent may change texts: the Atlassian callback URL list (**Copy callback URLs**), the API-token base URL, the weekly-login frame (S2).
- The IT page URL (T14) — the constant's value.
