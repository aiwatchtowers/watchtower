# Company setup — one link connects Slack, Google, Atlassian and Linear

Status: for review, 2026-11-17. Extends the Slack spec `docs/superpowers/specs/2026-11-14-slack-full-and-live-design.md` (§5 "Entry into Full") from Slack alone to every source. Research brief (outside the repo): `~/Documents/watchtower-research/2026-11-17-google-atlassian-linear-brief.md`.

## Goal

The owner's goal (comment #871): be compliant with each vendor without losing features for customers; everything stays local.

Today the public build carries our own shared OAuth apps (Google, Atlassian, Linear; Slack is being retired by the Slack spec), and a separate corp build carries one company's own apps. The shared Google app needs an annual CASA assessment for `gmail.readonly` (lapsed: ask #1430); the shared Atlassian app, being distributed and storing personal data, owes Atlassian the Personal Data Reporting API.

After this work:

- **There is one build.** It ships no Google or Atlassian app of ours, carries no vendor obligations for them, and the corp build goes away.
- **A company sets up once.** An admin runs **Set up for my company** in Watchtower: the company's Slack app (Slack spec §5.1), its Google OAuth client, its Atlassian OAuth app and optionally its Linear app and Microsoft 365 app registration. Watchtower packs the result into one **company bundle**.
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
| D9 | MDM (`CompanyBundle` key) and a pasted connect code carry the same bundle as fallbacks — for a company without Slack ("не слаком единым") and for managed Macs where IT wants no click at all | decided by the agent (the owner asked for the Slack link; these two are extra and can be struck at review) |
| D10 | The bundle carries the Google and Atlassian client secrets in clear (see §3 for why that is safe) | ask #1455 (extends the Slack spec's D13 "no secret anywhere" for these two vendors) |
| D11 | Our shared Google client keeps the Calendar scopes only; Gmail is requested only through a company's or a person's own client | ask #1455 (existing tokens live on until Google refuses them, plus a banner) |
| D12 | Linear keeps our shared app (PKCE, no secret); a bundle may carry the company's own Linear client id. Our obligations to Linear are checked in spike S3 (Linear's API and OAuth app terms); if S3 finds one we cannot meet, the company client becomes required and the shared app is retired like Atlassian's | decided by the agent |
| D16 | Microsoft 365 / Outlook joins the bundle (`microsoft` block: the company's own Entra app registration, public client, PKCE, no secret, the tenant id); our shared Microsoft client id stays for personal Outlook accounts | ask #1458 |
| D17 | Atlassian PDR erases what came from Atlassian about a closed account, including the memory and people data keyed by that account id; free-text derived texts (digests, briefings, chat transcripts) are not rewritten and age out under retention | ask #1458 |
| D18 | The corp build's baked deny list moves into the bundle (`link_deny_hosts`), not dropped; a bundle can only add hosts to refuse, never allow one | decided by the agent |
| D13 | The Live layer for Gmail/Calendar/Atlassian connectors (generalised Slack Live) is a separate project, not part of this spec | decided by the agent |
| D15 | Sharing on our shared Atlassian app is turned off 30 days after company setup ships | ask #1455 |
| D14 | Screens (wizard, confirmation, Connections rows, banners) get their own screens spec with DesignShotCatalog mockups for every state, as #1709 does for Slack. This spec holds no screen and no UI task: it fixes the behaviour, the data and the UI texts (in the models, tested — T3); the screens spec is a prerequisite of every UI task and the screen tasks are planned from it | decided by the agent |

## 1. The company bundle

One JSON object, versioned, the only thing a link, an MDM key and a pasted code carry:

```json
{
  "v": 1,
  "company": "Acme",
  "slack":     {"team_id": "T0000", "client_id": "000.000"},
  "google":    {"client_id": "…apps.googleusercontent.com", "client_secret": "…", "domain": "example.com"},
  "atlassian": {"client_id": "…", "client_secret": "…", "site": "https://acme.atlassian.net", "confluence": true},
  "linear":    {"client_id": "…"},
  "microsoft": {"client_id": "…", "tenant_id": "…"},
  "link_deny_hosts": ["intranet.example.com"]
}
```

- Every vendor block is optional; `v` and `company` are required. `link_deny_hosts` only adds hosts to `media.RefusedHosts` (D18). An unknown `v` is refused with "This link needs a newer Watchtower".
- Wire form: base64url of the JSON, no padding. Hard cap 3,000 characters encoded (Slack's `long_description` holds 4,000; the bundle is a few hundred).
- `internal/companybundle`: `Parse` (pure, fails closed on unknown fields, wrong types, non-https site, bad ids), `Encode`. Swift twin `CompanyBundle.swift`; a shared fixture `internal/companybundle/testdata/bundle_cases.json` runs in both (the POLICY-02 pattern).
- Stored after confirmation as `<workspace>/company/<slug>.json` (0600, directory 0700); `<slug>` = lowercase `company`, `[a-z0-9-]`, a numeric suffix on a clash with a different company. Several companies may be stored side by side (a consultant).
- **Which account uses which client.** A migration adds `company_slug TEXT NOT NULL DEFAULT ''` to `slack_accounts`, `google_accounts`, `jira_accounts`, `linear_accounts` and `email_accounts` (Outlook); mirrored into `schema.sql`, the golden snapshot and the Swift test schema. `''` = our shared client (or, for Google, an existing `google_credentials_<id>.json`). Every OAuth config resolver (Google, Atlassian, Linear, Microsoft) reads in this order: the company's bundle → the account's own credentials file → env (development) → the baked default.
- **Resolvers by company, then by account.** Each vendor's resolver has two forms: `…ForCompany(slug)` does the lookup above, and `…ForAccount(accountID)` reads the account's `company_slug` and calls it (Google keeps its existing `resolveGoogleOAuthConfigForAccount`, which gains the bundle step). For Atlassian, the argument-less `resolveJiraOAuthConfig` is replaced by `resolveJiraOAuthConfigForCompany(slug)` and `resolveJiraOAuthConfigForAccount(accountID)`. The 10 call sites that already hold an account pass it — `cmd/jira.go` (7), `cmd/confluence.go`, `cmd/sync.go`, `cmd/actions_registry.go`. The one that runs before the account exists — `runJiraAdd` (`cmd/jira.go`, before `CreateJiraAccount`) — takes the company from a new `jira add --company <slug>` flag (set by the employee chain, §3 step 2) and calls the `ForCompany` form; the new account row gets that `company_slug` in the same `CreateJiraAccount` call, so a company's first Atlassian login never touches the retired shared app. Linear and Microsoft follow the same split, since their `add` also runs before the account row exists. Tests: no argument-less Jira resolver remains; `jira add --company acme` uses the bundle's client and stores `company_slug = 'acme'`; `jira add --company` naming an unstored company fails before any browser opens. Go owns the column; Swift only reads it to group Connections rows by company.

## 2. The admin: Set up for my company

Connections → **Set up for my company**. A step per vendor, each skippable; progress kept in a draft (`<workspace>/company/draft.json`, 0600) so a closed window resumes.

1. **Slack** — Slack spec §5.1 unchanged (configuration token, `apps.manifest.create`, no secret kept).
2. **Google** — deep links into Google Cloud Console in order: create project → enable Gmail API and Calendar API → OAuth consent screen, user type **Internal** → Credentials → OAuth client **Desktop app** → download JSON. The admin drops the JSON on the step (or pastes it). Watchtower checks the client with a dry authorize URL and records the Workspace domain.
3. **Atlassian** — deep links into developer.atlassian.com: create OAuth 2.0 integration → permissions: Jira API with today's `JiraScopes`, Confluence API with `ConfluenceScopes`, `report:personal-data` → callback URLs (the Jira loopback range, §5 open item) → **Distribution: Sharing on**, "Does your app store personal data? **Yes**" → add a second admin (D6). The admin pastes client id and secret.
4. **Linear** (optional) — create an OAuth application in Linear settings with the loopback redirect; paste the client id. Skipped = employees use our shared Linear app.
5. **Microsoft 365** (optional, D16) — deep links into Entra admin center: App registrations → New → "Accounts in this organizational directory only" → platform "Mobile and desktop", redirect `http://localhost` → API permissions (today's Outlook scopes) → **Grant admin consent** → paste client id and tenant id. Skipped = employees use our shared Microsoft client, where the tenant may demand admin consent.
6. **Link deny list** (optional, D18) — hosts whose links Watchtower must never fetch (intranet, internal tools).
7. **Publish** — Watchtower encodes the bundle and, with the Slack configuration token (fresh one asked if the first expired), writes into the Slack app's `long_description`: "Watchtower for <company> — connect: <link>" plus the connect code. It also shows the link, the code and a ready `.mobileconfig` with the `CompanyBundle` key for IT.

The admin then connects like any employee (§3), through the same link.

## 3. The employee: one link

The link: `http://127.0.0.1:18551/company/connect?b=<bundle>` — the Slack spec's loopback listener (§5.3) gains this path. Its rules carry over: GET only, `Host` checked, port-busy message, never serves files.

What still needs the person: the one **Connect** press in Watchtower and each vendor's own consent page (Slack, Google, Atlassian, Microsoft, Linear). Neither can be removed — the press stops any web page from wiring accounts silently, and the vendors require their consent screen. Everything between (finding the clients, filling settings, the order of logins) needs no action. On a Mac with the MDM key (D9) even the link is not needed.

1. The listener parses the bundle (refuses a bad one with a page that says why) and brings Watchtower to the front: **"Connect <company>? Slack · Gmail and Calendar (example.com) · Jira and Confluence (acme.atlassian.net) · Outlook (Microsoft 365) · Linear"**, each with a checkbox. Nothing happens without this press — any web page can open a loopback URL.
2. On **Connect**, the bundle is stored (§1), then each checked vendor's OAuth runs in turn in the browser: Slack (PKCE, Slack spec §5.3), Google (loopback, the bundle's client), Atlassian (3LO with the bundle's client and secret via `jira add --company <slug>`, §1; Confluence scopes when `confluence: true`), Microsoft (PKCE, the bundle's client against its `tenant_id` endpoint instead of `common`), Linear (PKCE). The window shows a checklist that ticks as each comes back.
3. A cancelled or failed consent leaves that vendor's row in Connections as **Not connected — Connect** for this company; the chain moves on.
4. The same bundle again (same company, same ids) only offers what is not connected yet.
5. **A bundle that changes a stored company** (same `company`, any changed client id, secret, tenant or site) is never applied by the ordinary confirmation. Watchtower shows a separate warning naming each change ("Atlassian app: <old client id> → <new client id>"), with **Keep current** as the default button and **Replace** beside it; only **Replace** stores it and marks the changed vendors **Re-login needed**. A forced MDM bundle replaces without asking (IT owns it). Even a replaced bundle cannot move data off the Mac — tokens are exchanged and kept locally — so the worst a hostile page gets from a mis-press is the person having to log in again.

**Browser history.** The link is a GET with the bundle in its query, so the browser's history keeps the secrets. That is the same exposure class D10 already accepts (the Slack page shows them to every member); the listener answers with a redirect to a clean `http://127.0.0.1:18551/company/connected` page so a reload does not resubmit, and the listener never logs the query (the request log keeps the path only; a test asserts no bundle text in the log).

**Why the secrets may travel in clear (D10).** Both vendors' redirect URLs are fixed in the app's settings to `127.0.0.1`: an authorization code only ever reaches the Mac of the person who consented, and a secret without such a code yields no data. Google calls a Desktop client's secret non-confidential. A Workspace guest who reads the Slack page still cannot use the Google client (Internal: own domain only) and gets from Atlassian only what their own account can already see. A leak is fixed by rotating the secret and republishing the bundle.

**MDM (D9).** A forced `CompanyBundle` string (same encoding; POLICY-01 forced-only, fail closed) shows **<company> — Connect all** in Connections at launch; the same confirmation and chain. A forced bundle wins over a stored bundle of the same company; it never deletes accounts.

**Connect code.** Connections → **Connect with a company code** takes the same base64url string; same flow without the browser hop.

## 4. Personal Gmail (no company)

Connections → Google → **Use my own Google project**: the wizard's Google step for one person — user type External, add yourself as a test user, then publish to production unverified so the refresh token does not expire after 7 days (the owner of the project passes the "unverified app" screen once). Stored as a bundle with only a `google` block and `company` = the person's name. The existing CLI path `google add --client-id --client-secret-stdin` becomes a thin wrapper over the same store.

**Unverified so far.** That a project published to production without verification keeps its owner's `gmail.readonly` refresh token past 7 days is read from Google's docs, not tried. Spike **S2** (first in the plan, before T8) proves it: a fresh @gmail.com, its own project published unverified, the token refreshed on day 8. If S2 fails, the personal path ships with an honest weekly **Re-login** notice and the guide says so; the company path is unaffected (Internal clients have no such limit).

## 5. What is retired

- **Shared Google client:** stays for Calendar only (D11). The public build stops requesting `gmail.readonly` through it. Existing Gmail accounts on the shared client: their stored tokens keep working until Google refuses them; Connections shows "Move Gmail to your company's or your own Google project". Their data follows the purge rules (PURGE-01).
- **Shared Atlassian app (D4):** the public build stops baking `DefaultJiraClientID/Secret`; `WATCHTOWER_JIRA_CLIENT_ID/SECRET` stay for development. Existing accounts keep syncing until the owner turns the app's sharing off, 30 days after company setup ships (D15), with a banner "Your company needs its own Atlassian app — ask your admin or set it up".
- **Corp build (D3):** `.env.corp` and the corp flavor go after the corp users have moved. What it bakes moves: Slack/Google/Jira/Microsoft clients → the bundle; `PURGE_DEFAULT` → MDM `PurgeRevokedData` (and #1769 makes purge default-on anyway); `LINK_FETCH_DENY_HOSTS` → the bundle's `link_deny_hosts` (D18), on top of the company domains already derived (ask #598); the gated update feed → the public one.

**Moving a corp install without breaking its accounts.** The public build no longer knows the corp clients, so an existing corp account must be tied to the company bundle *before* the first public binary runs, or its next token refresh fails `invalid_client`. One release, in order:
1. **Bridge corp build** (still the corp flavor, gated feed): at launch it writes `company/<slug>.json` from its own baked values (the bundle the admin would publish, built by the same `Encode`) and sets `company_slug` on every account whose client is the baked one. Idempotent; a failure leaves everything as is and retries next launch.
2. Only after the bridge build reports the bundle stored (a `company_migrated` marker in the workspace) does its UpdateService accept the public feed — an install that has not migrated stays on the gated feed.
3. The first public build reads the bundle and refreshes as before. An account it finds with `company_slug = ''` whose token was issued by an unknown client gets **Re-login needed — open your company's link** instead of a silent failure.

Test: a corp-flavored workspace fixture → bridge → public resolver gives every account its old client; the refresh fake sees the same client id before and after.

## 6. Atlassian Personal Data Reporting (D6)

- A daemon phase, per Atlassian account, once every 7 days (stored `last_pdr_at`): collect the stored account ids of that site (Jira users, issue/comment authors, `ext_users` for Confluence), POST them in chunks of 90 to `https://api.atlassian.com/app/report-accounts/` with the account's token.
- `closed` → erase, in one write transaction per account, what Watchtower got from Atlassian about that person (D17):
  - `jira_user_map` row (email, display name, Slack mapping), `ext_users` row, the person's fields on Jira issue/comment rows (author/assignee display names) → the bare account id, shown as "Former user";
  - memory: the alias `jira:<accountId>` (and the Confluence alias) is removed; an entity node left with no other alias is tombstoned (the memory engine's existing `tombstone` status); an entity that also has a Slack or mail alias is kept — that data came from another source, not from Atlassian;
  - KB documents rendered from Jira issues and Confluence pages are re-rendered on the next KB pass (they read the erased names);
  - not rewritten: free-text derived texts (digests, briefings, chat transcripts, inbox card text). They are summaries, not Atlassian records; they age out under retention. Stated in the guide's privacy page.
- `updated` → refetch the profile on the next sync.
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
| A link changes a stored company's clients | Change warning, **Keep current** default; nothing stored without **Replace** | listener test: changed ids → no write until Replace |
| The bundle in the request log | Path only is logged | log assertion test |
| Corp install updates before the bridge ran | Stays on the gated feed until `company_migrated` | UpdateService test |
| Public build meets an untied account of an unknown client | **Re-login needed — open your company's link**, no silent failure | resolver + refresher test |
| PDR erase interrupted | One transaction per account: all or nothing; the next cycle repeats it (idempotent) | kill-mid-erase test |

## 8. Writers of the same data

- **`company/<slug>.json`:** the link handler, the code paste and the admin wizard's publish, all after a press; under a per-file flock, the last confirmed write wins. MDM never writes it — a forced bundle is an overlay read at launch and wins over the stored one.
- **Per-account client config** (Google credentials file, new Atlassian and Linear equivalents): written when an account is added from a bundle, rewritten only by a newer bundle's confirmation; token refresh never touches it.
- **`company_slug` on account rows:** the account-add path (from a bundle), the bridge corp build, and a **Replace** of a bundle; all Go, one write transaction each; Swift never writes it. The bridge runs at launch before the daemon starts, so it does not race an add.
- **Memory aliases and entity nodes:** the memory engine and the PDR phase; the PDR phase goes through the memory package's own tombstone API, so the engine's next reconcile sees a tombstone, not a missing row.
- **Jira user rows and `ext_users`:** the Jira/Confluence syncs and the PDR phase. A sync can re-insert a profile PDR just erased; Atlassian already returns closed accounts anonymised, so the last writer writes the same anonymous value. The PDR phase runs after the sync in the same cycle so it has the last word.

## 9. Promises → tasks → tests

| Promise | Task | Test |
|---|---|---|
| Personal Gmail token outlives 7 days | S2 spike (before T8) | day-8 refresh on a real unverified project; result written into this spec |
| Our Linear obligations known | S3 spike (Linear terms) | written finding; D12 holds or flips |
| Atlassian callback URL count; Slack link rendering | S1 spike (with the Slack spec's T1) | written finding |
| One bundle format, Go and Swift alike | T1 bundle package + Swift twin | shared fixture in both |
| Accounts know their company client | T1b migration `company_slug` + resolvers | `TestAllTablesExist`/golden, resolver order tests |
| A localhost link connects every vendor (Slack, Google, Atlassian, Microsoft, Linear) after one press; a change needs Replace | T2 listener path + chain | listener + chain tests with a fake per vendor (Microsoft against the bundle's tenant), no-log test |
| Admin sets up all vendors once; every UI text lives in a model | T3 wizard model and texts | wizard model + text tests (screens: the screens spec, D14) |
| Slack page carries the link | T5 publish via `apps.manifest.update` | manifest fake |
| MDM and code carry the same bundle | T6 `CompanyBundle` policy key + code paste | POLICY-02 fixture rows |
| Per-account clients for Google, Atlassian, Linear, Microsoft | T7 credentials store + refreshers read it | per-vendor auth tests |
| Company deny list applies | T7b `link_deny_hosts` into `media.RefusedHosts` | linkrule test |
| Personal Gmail through own project | T8 personal Google path | store + CLI wrapper tests |
| Atlassian PDR, erasing memory and people data too | T9 daemon phase | fake endpoint tests; erase test over every table in §6 |
| Shared Google = Calendar only; shared Jira retired; banners | T10 retirements | scope tests, banner model tests |
| Corp installs move without breaking accounts | T11a bridge corp build (bundle from baked values, `company_slug`, `company_migrated` gate) | corp-workspace fixture test, UpdateService gate test |
| Corp build gone, its settings moved | T11b build scripts drop the corp flavor | build-script check |
| Guide pages | T12 `docs/guide/` connections pages | `go test ./docs/guide` |

## 10. Inventory touched

POLICY-01/02 (new `CompanyBundle` key), the Jira/Confluence auth contracts in `docs/inventory/` (per-account client), the Slack spec's D13 (D10 here, approved in ask #1455), PURGE-01 unchanged. A further inventory entry the plan finds it must change gets its own ask before that task's review.

## 11. Open

- Atlassian 3LO callback URLs: one or several per app? If one, Jira's loopback range collapses to one fixed port (spike S1).
- Personal Gmail past 7 days (spike S2) and our Linear obligations (spike S3).
- Whether Slack renders the link in `long_description` as clickable (Slack spec T1); the code is the fallback.
- Live layer for the Google/Atlassian connectors (D13): its own brainstorm.
