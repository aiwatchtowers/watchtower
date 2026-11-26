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

## Decisions

| # | Decision | Source | If refused | Ask |
|---|---|---|---|---|
| D1 | No bot, no DM push, no Home tab, no external redirect — local-first | Owner, chat 2026-11-24 | — (owner's own constraint) | #886 |
| D2 | When connecting to a company, Watchtower asks for the Slack address and opens the workspace app list with steps to the code | Owner, chat 2026-11-24 | Only a static hint line naming `<your-slack>.slack.com/apps/manage`, no field or button | #894 |
| D3 | The About text gets a sectioned layout: steps, link, code, download, disclosures | Owner, chat 2026-11-24 and ask #894 | About stays one paragraph as today | #894 |
| D4 | The Slack-address block is always shown under the code field, not behind a disclosure | Agent's call following D2 | The block sits behind a "No code?" link that expands it | #902 |
| D5 | The address is not stored | Agent's call (one-time use, nothing to clean up) | Remembered in UserDefaults and prefilled next time | #902 |
| D6 | No "Invite a colleague" button | Owner, ask #894 ("Инвайт-кнопку не делаем") | A card button copying the app-page link, separate target | #894 |
| D7 | Only `<sub>.slack.com` addresses; an Enterprise Grid org address (`<sub>.enterprise.slack.com`) is refused with its own caption pointing to the workspace address | Agent's call — `/apps/manage` on a Grid org address is untested (see Failure paths) | Org addresses are accepted and `https://<sub>.enterprise.slack.com/apps/manage` opens as is | #902 |
| D8 | The link stays first in About only if a test publish shows it clickable on the Marketplace page; otherwise the code leads | Agent's call; the spikes did not click the link | The code leads from the start | #902 |
| D9 | The block's heading: "No code? Ask a colleague who uses Watchtower, or find Watchtower in your company's Slack:" | Owner, ask #894 | Heading "No code? Find it in Slack" | #894 |
| D10 | Ask #895 ("do not add the Installed apps fallback; keep the colleague's and the admin's link") and #894 ("…or open <your-slack>.slack.com/apps/manage and find Watchtower") conflict; this spec follows #894: it names `apps/manage` explicitly, prescribes the hint wording and drops the invite button that #895 relied on. The admin's link at Publish stays (approach 4) | Owner, asks #894, #895 (both 2026-11-25); agent's reading, flagged in chat | The `apps/manage` block is removed: only the heading's "Ask a colleague who uses Watchtower" and the admin's link remain | #917 |
| D11 | The app's Marketplace page link at the end of setup is not part of this change | Owner allowed it (#894, "можно"), did not require it | Publish also shows `https://<workspace>.slack.com/marketplace/<APP_ID>-watchtower` as a shareable link, separate target | #917 |

## Goals

- In Watchtower, the colleague without a code enters their Slack address and gets the app list opened in the browser, with three steps to the code.
- The About text reads as instructions, not a wall: how to connect first, then the link, then the code, then the rest.

## Non-goals / anti-goals

- No bot, no DM push, no Home tab, no slash command, no external redirect, no backend, no DNS (finding 2; asks #885, #886 dismissed).
- No "Invite a colleague" button (D6).
- No Marketplace page link at the end of setup in this change (D11).
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
│                                                           │
│ No code? Ask a colleague who uses Watchtower, or find     │
│ Watchtower in your company's Slack:                       │
│ [ acme.slack.com                   ] [Open Slack apps]    │
│ 1. Search for Watchtower in the list and open it.         │
│ 2. Open App Details.                                      │
│ 3. Click the connect link, or copy the code and paste it  │
│    above.                                                 │
│ Not in the list, or Slack asks you to sign in? Sign in to │
│ Slack in this browser and try again. Still nothing — ask  │
│ your Slack admin for the Watchtower company code.         │
└───────────────────────────────────────────────────────────┘

invalid address:
│ [ acme.example.com                 ] [Open Slack apps]    │  (button disabled)
│ Enter your Slack address, like acme.slack.com             │  (caption, Tone.error)
```

- The block is always shown under the code field (D4), headed "No code? Ask a colleague who uses Watchtower, or find Watchtower in your company's Slack:" at caption size (D9).
- **Slack address** field (`.kit`), placeholder `acme.slack.com`. Accepted: `acme`, `acme.slack.com`, `https://acme.slack.com/…` (any path, trailing slash), any case, surrounding spaces, `http://` input. Normalised to `<sub>.slack.com`, `<sub>` = one label of `[a-z0-9-]` (D7). Empty → button disabled, no caption. `<sub>.enterprise.slack.com` → caption "That is your organization's address. Enter your workspace's, like acme.slack.com — it is in Slack's workspace menu.", button disabled. Anything else → caption "Enter your Slack address, like acme.slack.com", button disabled.
- **Open Slack apps** (`.kitSecondary`) opens `https://<sub>.slack.com/apps/manage` through `@Environment(\.openURL)` (the pattern `CompanyAccountGroups` uses). Watchtower fetches nothing.
- The steps and the fallback line are static text; the fallback covers not signed in, the app missing from the list, and no access (ask the admin). The address is not stored (D5).
- Pure functions in `WatchtowerCore`: `SlackAddress.parse(_:) -> SlackAddress` (`.empty`, `.workspace(<sub>)`, `.organization`, `.invalid` — one entry point so the Grid caption is decidable) and `SlackAddress.appsURL(workspace:) -> URL`. Tests: each accepted form, uppercase, trailing slash and path, inner space (refused), empty, `slack.com` alone, `acme.enterprise.slack.com` (refused), a foreign host, `http://` input → `https://` URL.
- Design shots: three states registered in `DesignShotCatalog` — empty address, valid address, invalid address with the caption.
- Strings live in `CompanyConnectionsPresentation` (UI strings in English).
- The block appears wherever the code field is shown (the Companies zone; the field opened from the **Connect…** menu and Jira's empty state reuse `codeField`).
- `codeInvalid` becomes "That is not a Watchtower company code. Copy it again from your company's Watchtower app page in Slack, or ask a colleague who uses Watchtower."

### Failure paths

Watchtower only opens a URL; it cannot see what the browser shows. So every failure is answered by the static fallback line under the steps, and each case has a defined way out:

| Case | What the person sees | Way out |
|---|---|---|
| Browser not signed in to Slack | Slack's sign-in page | Fallback: "Sign in to Slack in this browser and try again." Slack returns to `/apps/manage` after sign-in |
| Guest account (single/multi-channel) | Slack refuses the app list or shows no internal apps | Fallback: "ask your Slack admin for the Watchtower company code", or the heading's "Ask a colleague who uses Watchtower" |
| Workspace restricts the app directory to admins | Slack's "no permission" page | Same as guest |
| Watchtower not in the list (not installed in this workspace, or the wrong workspace) | The list without Watchtower | Fallback: "Not in the list … ask your Slack admin"; the heading's colleague route |
| Enterprise Grid org address entered | Nothing opens: the button is disabled and the org caption names the workspace address and where to find it (Slack's workspace menu) | Enter the workspace address `<sub>.slack.com`; every Grid workspace has one, so the app list opens there |
| Address of another company's workspace | That workspace's list, without our app | Same as "not in the list" |

Tests: `SlackAddressTests` pin every input the table depends on (org address refused, workspace accepted); `CompanyConnectionsPresentationTests` pin the fallback line and the heading verbatim; the design shots show the fallback line in every state. What Slack itself renders for a guest or a restricted workspace is outside Watchtower and is not tested; the way out does not depend on it.

Enterprise Grid: `/apps/manage` on an org address is not verified, and no Grid workspace is available to verify it. Refusing the org address (D7) is the safe default: the workspace address is verified (finding 3) and exists for every Grid member. If a Grid company later reports the org address works, accepting it is a one-line change in `SlackAddress.parse`.

### About text layout (`AboutText`)

```
Watchtower for <company>

How to connect
1. Open Watchtower.
2. Click this link: <link>
   If it does not open, paste the code below in Watchtower → Connections → Company code.

Company code
<code>

No Watchtower yet? Download it: <release page>
```

followed by the existing disclosures (`slackmanifest`). Steps are numbered when rendered from a list, so a cut step leaves no gap. Both the link and the code carry the whole bundle (up to 3,000 characters each), so both cannot always fit the 4,000 cap. Cut order under the cap, as today: the download line first, then the second way in (the code while the link leads; the link when the code leads, D8); the leading way in is never cut. When the code is cut, step 2 reads "Click this link: <link>" with no fallback sentence and the **Company code** block is absent; when the link is cut, step 2 reads "Paste the code below in Watchtower → Connections → Company code." A typical bundle (Slack + Google + Atlassian) is well under half the cap per copy, so both normally fit. Plain text with blank lines.

Acceptance check on a test publish (the plan's last task, run by the owner): the link on the Marketplace page is clickable and opens Watchtower; the code copies whole; any markup renders. If the link is not clickable, the code block moves above step 2 and step 2 becomes "Paste the code below in …" (D8). `aboutLeadsWithCode` is removed either way; the order follows the check. `about_test.go` covers: the full text; a bundle that needs the download line cut; a 3,000-character bundle (the leading way in kept whole, the second dropped, step 2 worded for the one left); the leading way in never cut.

Existing companies get the new layout on the admin's next **Publish** (`company publish`), the only path that writes `AboutText`; `slack app link` writes the Slack-only `slackapp.ConnectBlock` and does not apply it. No migration.

### Docs

- `docs/guide/start/company-setup.md`: "Connect with your company's link or code" gains "No code? Find it in Slack"; the admin section says the code is also on the app's page in the workspace's app list, so it need not be posted in a channel.
- `docs/features/company-setup.md` + its README summary: S1.2 resolved; the "No code?" block; bot user ruled out (finding 2).

## Left to the builder

- Spacing and typography from the design kit; a screenshot via `make desktop-shots` goes with the PR.
- How the open-URL call is seamed for tests (follow the existing open-URL pattern in the Connections views).
