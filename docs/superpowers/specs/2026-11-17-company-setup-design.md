# Company setup — one link connects Slack, Google, Atlassian and Linear

Status: for review, 2026-11-17. Extends the Slack spec `docs/superpowers/specs/2026-11-14-slack-full-and-live-design.md` (§5 "Entry into Full") from Slack alone to every source. Research brief (outside the repo): `~/Documents/watchtower-research/2026-11-17-google-atlassian-linear-brief.md`.

## Goal

The owner's goal (comment #871): be compliant with each vendor without losing features for customers; everything stays local.

Today the public build carries our own shared OAuth apps (Google, Atlassian, Linear; Slack is being retired by the Slack spec), and a separate corp build carries one company's own apps. The shared Google app needs an annual CASA assessment for `gmail.readonly` (lapsed: ask #1430); the shared Atlassian app, being distributed and storing personal data, owes Atlassian the Personal Data Reporting API.

After this work:

- **There is one build.** It ships no Google or Atlassian app of ours, carries no vendor obligations for them, and the corp build goes away.
- **A company sets up once.** An admin runs **Set up for my company** in Watchtower: the company's Slack app (Slack spec §5.1), its Google OAuth client, its Atlassian OAuth app and optionally its Linear app. Watchtower packs the result into one **company bundle**.
- **An employee connects with one link.** The company's Slack app's About page carries a link to `127.0.0.1` that hands the bundle to the employee's own Watchtower; one confirmation, then each vendor's consent page in turn. No backend, no bot, no Mac that must stay on. MDM and a pasted code carry the same bundle where Slack does not.
- **A private person** connects Gmail through their own Google project (the Hermes Agent / OpenClaw model), guided by the same Google step of the wizard.

## Decisions

| # | Decision | Source |
|---|---|---|
| D1 | Gmail in the public build: no CASA; Gmail through the user's or company's own Google project, guided by a wizard (as Hermes Agent and OpenClaw do) | ask #1440 |
| D2 | The corp build already uses the company's own internal Google client — the model this spec generalises | ask #1433 |
| D3 | There will be no corp build; every company uses the public build plus its bundle | ask #1442 |
| D4 | Our shared Atlassian (Jira) app is retired, as the shared Slack app is | ask #1442 |
| D5 | Atlassian for a company: the company's own OAuth 2.0 (3LO) app, not personal API tokens | ask #1442 ("мне нравится через приложение OAuth"), ask #1447 |
| D6 | Personal Data Reporting is implemented in our code and run by every Mac; the wizard advises a second admin or a service account as the app's owner; Atlassian's Developer Terms are accepted by the company | ask #1447 (points 2–4) |
| D7 | One **Set up for my company** for every source, next to the Slack setup — not Slack only | ask #1440 (note: "не тока слак а и вся поебота подключалась") |
| D8 | Distribution: the Slack app hands out a localhost link that sets everything up; no backend | ask #1451 |
| D9 | MDM (`CompanyBundle` key) and a pasted connect code carry the same bundle as fallbacks | decided by the agent |
| D10 | The bundle carries the Google and Atlassian client secrets in clear (see §3 for why that is safe) | ask #1455 (extends the Slack spec's D13 "no secret anywhere" for these two vendors) |
| D11 | Our shared Google client keeps the Calendar scopes only; Gmail is requested only through a company's or a person's own client | ask #1455 (existing tokens live on until Google refuses them, plus a banner) |
| D12 | Linear keeps our shared app (PKCE, no secret, no obligation found); a bundle may carry the company's own Linear client id | decided by the agent |
| D13 | The Live layer for Gmail/Calendar/Atlassian connectors (generalised Slack Live) is a separate project, not part of this spec | decided by the agent |
| D15 | Sharing on our shared Atlassian app is turned off 30 days after company setup ships | ask #1455 |
| D14 | Screens (wizard, confirmation, Connections rows) get their own screens spec with DesignShotCatalog mockups, as #1709 does for Slack | decided by the agent |

## 1. The company bundle

One JSON object, versioned, the only thing a link, an MDM key and a pasted code carry:

```json
{
  "v": 1,
  "company": "Acme",
  "slack":     {"team_id": "T0000", "client_id": "000.000"},
  "google":    {"client_id": "…apps.googleusercontent.com", "client_secret": "…", "domain": "example.com"},
  "atlassian": {"client_id": "…", "client_secret": "…", "site": "https://acme.atlassian.net", "confluence": true},
  "linear":    {"client_id": "…"}
}
```

- Every vendor block is optional; `v` and `company` are required. An unknown `v` is refused with "This link needs a newer Watchtower".
- Wire form: base64url of the JSON, no padding. Hard cap 3,000 characters encoded (Slack's `long_description` holds 4,000; the bundle is a few hundred).
- `internal/companybundle`: `Parse` (pure, fails closed on unknown fields, wrong types, non-https site, bad ids), `Encode`. Swift twin `CompanyBundle.swift`; a shared fixture `internal/companybundle/testdata/bundle_cases.json` runs in both (the POLICY-02 pattern).
- Stored after confirmation as `<workspace>/company/<slug>.json` (0600, directory 0700). Several companies may be stored side by side (a consultant); each vendor account records which bundle it came from (`company` column or field on the account's existing credentials record).

## 2. The admin: Set up for my company

Connections → **Set up for my company**. A step per vendor, each skippable; progress kept in a draft (`<workspace>/company/draft.json`, 0600) so a closed window resumes.

1. **Slack** — Slack spec §5.1 unchanged (configuration token, `apps.manifest.create`, no secret kept).
2. **Google** — deep links into Google Cloud Console in order: create project → enable Gmail API and Calendar API → OAuth consent screen, user type **Internal** → Credentials → OAuth client **Desktop app** → download JSON. The admin drops the JSON on the step (or pastes it). Watchtower checks the client with a dry authorize URL and records the Workspace domain.
3. **Atlassian** — deep links into developer.atlassian.com: create OAuth 2.0 integration → permissions: Jira API with today's `JiraScopes`, Confluence API with `ConfluenceScopes`, `report:personal-data` → callback URLs (the Jira loopback range, §5 open item) → **Distribution: Sharing on**, "Does your app store personal data? **Yes**" → add a second admin (D6). The admin pastes client id and secret.
4. **Linear** (optional) — create an OAuth application in Linear settings with the loopback redirect; paste the client id. Skipped = employees use our shared Linear app.
5. **Publish** — Watchtower encodes the bundle and, with the Slack configuration token (fresh one asked if the first expired), writes into the Slack app's `long_description`: "Watchtower for <company> — connect: <link>" plus the connect code. It also shows the link, the code and a ready `.mobileconfig` with the `CompanyBundle` key for IT.

The admin then connects like any employee (§3), through the same link.

## 3. The employee: one link

The link: `http://127.0.0.1:18551/company/connect?b=<bundle>` — the Slack spec's loopback listener (§5.3) gains this path. Its rules carry over: GET only, `Host` checked, port-busy message, never serves files.

1. The listener parses the bundle (refuses a bad one with a page that says why) and brings Watchtower to the front: **"Connect <company>? Slack · Gmail and Calendar (example.com) · Jira and Confluence (acme.atlassian.net) · Linear"**, each with a checkbox. Nothing happens without this press — any web page can open a loopback URL.
2. On **Connect**, the bundle is stored (§1), then each checked vendor's OAuth runs in turn in the browser: Slack (PKCE, Slack spec §5.3), Google (loopback, the bundle's client), Atlassian (3LO with the bundle's client and secret, Confluence scopes when `confluence: true`), Linear (PKCE). The window shows a checklist that ticks as each comes back.
3. A cancelled or failed consent leaves that vendor's row in Connections as **Not connected — Connect** for this company; the chain moves on.
4. The same bundle again (same company, same ids) only offers what is not connected yet. A newer bundle of the same company (changed ids) replaces the stored one after confirmation and marks the changed vendors **Re-login needed**.

**Why the secrets may travel in clear (D10).** Both vendors' redirect URLs are fixed in the app's settings to `127.0.0.1`: an authorization code only ever reaches the Mac of the person who consented, and a secret without such a code yields no data. Google calls a Desktop client's secret non-confidential. A Workspace guest who reads the Slack page still cannot use the Google client (Internal: own domain only) and gets from Atlassian only what their own account can already see. A leak is fixed by rotating the secret and republishing the bundle.

**MDM (D9).** A forced `CompanyBundle` string (same encoding; POLICY-01 forced-only, fail closed) shows **<company> — Connect all** in Connections at launch; the same confirmation and chain. A forced bundle wins over a stored bundle of the same company; it never deletes accounts.

**Connect code.** Connections → **Connect with a company code** takes the same base64url string; same flow without the browser hop.

## 4. Personal Gmail (no company)

Connections → Google → **Use my own Google project**: the wizard's Google step for one person — user type External, add yourself as a test user, then publish to production unverified so the refresh token does not expire after 7 days (the owner of the project passes the "unverified app" screen once). Stored as a bundle with only a `google` block and `company` = the person's name. The existing CLI path `google add --client-id --client-secret-stdin` becomes a thin wrapper over the same store.

## 5. What is retired

- **Shared Google client:** stays for Calendar only (D11). The public build stops requesting `gmail.readonly` through it. Existing Gmail accounts on the shared client: their stored tokens keep working until Google refuses them; Connections shows "Move Gmail to your company's or your own Google project". Their data follows the purge rules (PURGE-01).
- **Shared Atlassian app (D4):** the public build stops baking `DefaultJiraClientID/Secret`; `WATCHTOWER_JIRA_CLIENT_ID/SECRET` stay for development. Existing accounts keep syncing until the owner turns the app's sharing off, 30 days after company setup ships (D15), with a banner "Your company needs its own Atlassian app — ask your admin or set it up".
- **Corp build (D3):** `.env.corp` and the corp flavor go after the corp users have moved. What it bakes moves: Slack/Google/Jira clients → the bundle; `PURGE_DEFAULT` → MDM `PurgeRevokedData` (and #1769 makes purge default-on anyway); `LINK_FETCH_DENY_HOSTS` → already derived from the company's own domains (ask #598), the baked list is dropped; the gated update feed → the last corp build switches its update channel to the public one.

## 6. Atlassian Personal Data Reporting (D6)

- A daemon phase, per Atlassian account, once every 7 days (stored `last_pdr_at`): collect the stored account ids of that site (Jira users, issue/comment authors, `ext_users` for Confluence), POST them in chunks of 90 to `https://api.atlassian.com/app/report-accounts/` with the account's token.
- `closed` → erase that account's personal data locally: display name, email, avatar in the Jira user tables and `ext_users`; authorship stays as the bare account id ("Former user"). `updated` → refetch the profile on the next sync.
- An error (network, 401/403, missing scope) erases nothing; the phase retries next cycle and a missing `report:personal-data` scope shows "Re-login to finish the setup" on the account.
- Accounts on the retired shared app run the same phase while they still work, so our own obligation is met during the transition.

## 7. Failures

| Path | What happens | Test |
|---|---|---|
| Watchtower not running when the link is clicked | Browser shows "can't connect"; the Slack page text says "open Watchtower first" | doc only (no code path) |
| Port 18551 busy | Slack spec §5.3 message; the connect code works instead | listener test with the port held |
| Malformed / oversized / unknown-version bundle | Refused before any UI, with the reason | `TestCompanyBundle_*` fixture cases, Swift twin |
| Watchtower quits mid-chain | Bundle was stored first; done vendors stay connected; the rest show **Connect** in Connections; no auto-resume | integration test: kill after vendor 1, relaunch, rows |
| Consent cancelled for one vendor | That row **Not connected**, chain continues | chain test with a fake OAuth that returns `access_denied` |
| Admin wizard closed mid-step | Draft resumes at the step; secrets in the draft are 0600 and deleted on publish or **Discard** | draft round-trip test |
| Slack configuration token expired before publish | Publish asks for a fresh token; the bundle is not lost | manifest-update fake returning `token_expired` |
| Company rotates the Atlassian/Google secret | Refresh fails `invalid_client` → **Re-login needed — your company changed its app; open the new link** | refresher test on `invalid_client` |
| Admin's Atlassian account deleted, app gone | Same `invalid_client` path | as above |
| PDR call fails or scope missing | Nothing erased; retry next cycle; scope hint on the account | PDR phase tests with a fake endpoint |
| A web page opens the link silently | Nothing until the owner presses Connect | listener test: no store, no OAuth before confirm |
| Bundle from a different company with the same Slack team | Treated as a separate company bundle; confirmation shows both names | fixture + store test |

## 8. Writers of the same data

- **`company/<slug>.json`:** the link handler, the code paste and the admin wizard's publish, all after a press; under a per-file flock, the last confirmed write wins. MDM never writes it — a forced bundle is an overlay read at launch and wins over the stored one.
- **Per-account client config** (Google credentials file, new Atlassian and Linear equivalents): written when an account is added from a bundle, rewritten only by a newer bundle's confirmation; token refresh never touches it.
- **Jira user rows and `ext_users`:** the Jira/Confluence syncs and the PDR phase. A sync can re-insert a profile PDR just erased; Atlassian already returns closed accounts anonymised, so the last writer writes the same anonymous value. The PDR phase runs after the sync in the same cycle so it has the last word.

## 9. Promises → tasks → tests

| Promise | Task | Test |
|---|---|---|
| One bundle format, Go and Swift alike | T1 bundle package + Swift twin | shared fixture in both |
| A localhost link connects every vendor after one press | T2 listener path + chain | listener + chain tests |
| Admin sets up all vendors once | T3 wizard (data/model), T4 screens | wizard model tests, DesignShot snapshots |
| Slack page carries the link | T5 publish via `apps.manifest.update` | manifest fake |
| MDM and code carry the same bundle | T6 `CompanyBundle` policy key + code paste | POLICY-02 fixture rows |
| Per-account clients for Google, Atlassian, Linear | T7 credentials store + refreshers read it | per-vendor auth tests |
| Personal Gmail through own project | T8 personal Google path | store + CLI wrapper tests |
| Atlassian PDR | T9 daemon phase | fake endpoint tests |
| Shared Google = Calendar only; shared Jira retired; banners | T10 retirements | scope tests, banner model tests |
| Corp build gone, its settings moved | T11 build scripts + update channel switch | build-script check, UpdateService test |
| Guide pages | T12 `docs/guide/` connections pages | `go test ./docs/guide` |

## 10. Inventory touched

POLICY-01/02 (new `CompanyBundle` key), the Jira/Confluence auth contracts in `docs/inventory/` (per-account client), the Slack spec's D13 (D10 here, approved in ask #1455), PURGE-01 unchanged. A further inventory entry the plan finds it must change gets its own ask before that task's review.

## 11. Open

- Atlassian 3LO callback URLs: one or several per app? If one, Jira's loopback range collapses to one fixed port (check in a spike, with the Slack spike T1).
- Whether Slack renders the link in `long_description` as clickable (Slack spec T1); the code is the fallback.
- Live layer for the Google/Atlassian connectors (D13): its own brainstorm.
