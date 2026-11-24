# Company code from the Slack app — design (short)

Target: workbench #1155. Status: owner-agreed direction (2026-11-24), waiting on the owner's review of this document.

## Intent

A colleague who installs Watchtower at a company that already ran **Set up for my company** often does not know the company code. Posting the code in a channel is rejected by the owner (noisy, gets lost, and the code carries the company's OAuth client secrets). The colleague must find the code on their own, with no server and no bot that answers — Watchtower is local-first.

## What exists

- `company publish` writes `AboutText` (`internal/company/about.go`) into the company Slack app's `long_description`: "Watchtower for <company> — connect: <link>", then "Connect code: <code> — paste it in …", then the download line; `slackmanifest` appends the scope and AI disclosures. `aboutLeadsWithCode = false`.
- The app is user-scope only, PKCE, redirect `http://127.0.0.1:18551/callback`.
- Desktop: `CompaniesZone.codeField` (`WatchtowerDesktop/Sources/Views/Connections/CompaniesZone.swift`) is a **Company code** field plus **Connect**; nothing says where a code comes from (`codeInvalid` mentions the About page only after a failure).

## Spike findings (2026-11-24, a real company workspace)

1. An ordinary member does not find the bot-less app with ⌘K (ask #888).
2. A bot user cannot be installed local-first. The manifest validator requires a bot scope for `bot_user`; Slack refuses bot scopes on a non-web redirect ("Bot scopes are not allowed when redirecting to a non-web URI"); `https://127.0.0.1` is non-web too ("Must use PKCE to redirect to a non-web URI"); an external https redirect breaks local-first (owner). A PKCE app has no **Install to Workspace** button.
3. `https://<workspace>.slack.com/apps/manage` (redirects to `app.slack.com/apps-manage/<team>/integrations/installed`) opens for an ordinary member (owner checked with a colleague) and lists the app; its search finds "Watchtower".
4. The app's **App Details** opens `https://<workspace>.slack.com/marketplace/<APP_ID>-watchtower`, which shows the whole `long_description` under "This app is just for your workspace — only people on <workspace> can view…". An ordinary member opens it (owner checked). The layout is a raw wall of text.
5. The workspace Marketplace search (`/marketplace/search?q=watchtower`) does not list internal apps.

## Goals

- In Watchtower, the colleague without a code enters their Slack address and gets the app list opened in the browser, with three steps to the code.
- The About text reads as instructions, not a wall: how to connect first, then the link, then the code, then the rest.

## Non-goals / anti-goals

- No bot, no DM push, no Home tab, no slash command, no external redirect, no backend, no DNS (finding 2; asks #885, #886 dismissed).
- No "Invite a colleague" button in this change.
- Watchtower never reads the Slack desktop app's files to guess the workspace (TCC risk on the App Store build's container).

## Approaches

1. **Ask the Slack address, open the workspace app list, guide in three steps (picked by the owner).** No ids needed before the bundle; works for any member (finding 3).
2. Bot user so ⌘K finds the app — impossible local-first (finding 2).
3. Marketplace search link — does not list internal apps (finding 5).
4. A link handed over by a colleague / the admin — stays as is (the admin already gets the link and the code at Publish); no new UI.

## Design

### Desktop — "No code?" under the code field

```
COMPANIES
┌───────────────────────────────────────────────────────────┐
│ [ Company code                                ] [Connect] │
│ No code? Find it in Slack ›                               │
└───────────────────────────────────────────────────────────┘

expanded:
│ [ Company code                                ] [Connect] │
│ Find your company's code in Slack                         │
│ [ acme.slack.com                   ] [Open Slack apps]    │
│ 1. Search for Watchtower in the list and open it.         │
│ 2. Open App Details.                                      │
│ 3. Click the connect link, or copy the code and paste it  │
│    above.                                                 │
```

- A `kitQuiet` link "No code? Find it in Slack" under the field toggles the block (collapsed by default; the flag lives in the zone's model, not `@State`, so it survives the code field closing and reopening within the session).
- **Slack address** field, placeholder `acme.slack.com`. Accepted forms: `acme`, `acme.slack.com`, `https://acme.slack.com/…`, `acme.enterprise.slack.com`. Normalised to the host `<sub>.slack.com` / `<sub>.enterprise.slack.com` (lowercase, `[a-z0-9-]` labels). Anything else: caption "Enter your Slack address, like acme.slack.com", button disabled.
- **Open Slack apps** opens `https://<host>/apps/manage` in the default browser. Watchtower fetches nothing.
- The steps are static text. The address is not stored (one-time use; nothing to clean up).
- Strings live in `CompanyConnectionsPresentation` (UI strings in English). The normaliser is a pure function in `WatchtowerCore` with unit tests (each accepted form, uppercase, trailing slash/path, empty, `slack.com` alone, a foreign host, inner spaces).
- The block appears wherever the code field is shown (the Companies zone; the field opened from the **Connect…** menu and Jira's empty state reuse `codeField`).
- `codeInvalid` becomes "That is not a Watchtower company code. Copy it again from your company's Watchtower app in Slack (Apps → Watchtower → App Details)."

### About text layout (`AboutText`)

```
Watchtower for <company>

How to connect
1. Install Watchtower: <release page>
2. Open Watchtower.
3. Click this link: <link>
   If it does not open, paste the code below in Watchtower → Connections → Company code.

Company code
<code>
```

followed by the existing disclosures (`slackmanifest`). Under the `long_description` cap the download step is cut first, then the code; the link is never cut. `aboutLeadsWithCode` and its branch are removed (S1.2 answered: the link is clickable, the code is the fallback). Plain text with blank lines; whether Slack renders any markup in `long_description` on the Marketplace page is checked on a test publish before using it — default: none. `about_test.go` follows.

Existing companies get the new layout on the admin's next **Publish** / `slack app link`; no migration.

### Docs

- `docs/guide/start/company-setup.md`: "Connect with your company's link or code" gains "No code? Find it in Slack"; the admin section says the code is also on the app's page in the workspace's app list, so it need not be posted in a channel.
- `docs/features/company-setup.md` + its README summary: S1.2 resolved; the "No code?" block; bot user ruled out (finding 2).

## Left to the builder

- Spacing and typography from the design kit; a screenshot via `make desktop-shots` goes with the PR.
- How the open-URL call is seamed for tests (follow the existing open-URL pattern in the Connections views).
