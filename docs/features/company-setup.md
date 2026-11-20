# Company setup — one link connects Slack, Google, Atlassian, Linear and Microsoft 365 (2026-11-19, #1887)

Specs: [`docs/superpowers/specs/2026-11-17-company-setup-design.md`](../superpowers/specs/2026-11-17-company-setup-design.md) (behaviour, data, decisions D1–D25) and [`2026-11-18-company-setup-screens-design.md`](../superpowers/specs/2026-11-18-company-setup-screens-design.md) (screens, decisions A1–A34). Plan: [`docs/superpowers/plans/2026-11-18-company-setup.md`](../superpowers/plans/2026-11-18-company-setup.md). User guide: [`docs/guide/start/company-setup.md`](../guide/start/company-setup.md).

The public build ships no Google or Atlassian app of ours for company data. A company sets Watchtower up once (**Set up for my company**) and the result, a **company bundle**, reaches every colleague's Watchtower by a localhost link on the Slack app's About page, a pasted code, or the MDM key `CompanyBundle`. No backend: every sign-in runs between the Mac and the vendor.

## The bundle (`internal/companybundle`, Swift `CompanyBundle`)

- One JSON object, `v` (1) and `company` required, optional `slack {team_id, client_id}`, `google {client_id, client_secret, domain}`, `atlassian {client_id, client_secret, site, confluence}`, `linear {client_id}`, `microsoft {client_id, tenant_id}`, `link_deny_hosts`. `personal` (bool) marks a person's own Google project and is accepted only from a stored file (`OriginLocal`); a link, code or MDM bundle carrying it is refused (`personal`).
- Wire form: base64url, no padding, at most `MaxEncodedLen` = 3,000 characters. `Parse(wire, origin)` / `ParseJSON` fail closed (unknown fields, wrong types, non-https site, bad ids, unknown `v` → `newer_version`); `Encode`. `ParseError.Reason` (`Refusal`): `damaged`, `too_long`, `newer_version`, `personal`, `site_not_https`. Go and Swift run one fixture, `internal/companybundle/testdata/bundle_cases.json`.
- The Google and Atlassian secrets travel in clear (D10): both redirect only to `127.0.0.1`.

## Stored companies (`internal/company`)

- `Store` = `<workspace>/company/` (0700); `<slug>.json` (0600) under a per-file flock, last confirmed write wins. Slug = lowercased company name in `[a-z0-9-]`, a numeric suffix on a clash (`freeSlug`). `LoadAll(forcedWire)` overlays the forced MDM bundle (it wins over a stored file of the same company and never writes one); a damaged file is a `LoadError` beside the readable ones. `SaveRenamed` (Publish rename, A33/D25) changes the display name only: slug, file name and `company_slug` ties stay; refused for a name another company or personal project holds (`ErrNameTaken`) or for the forced company (`ErrCompanyForced`).
- `Changes(stored, incoming)` lists changed fields per vendor (ids shortened by `ShortID`). `ApplyForcedChanges` runs at daemon start before any sync: it compares the forced bundle with `company/.forced-<slug>.seen` and marks the changed vendors' accounts `error` / `company_changed_app`.
- Wizard draft: `company/draft.json` (0600, flock), `LoadDraft` sets an undecodable one aside as `draft.json.bad-<ts>` (newest kept, `CleanStaleBadDrafts` deletes one older than 30 days), `SaveDraft` refuses a Slack configuration token, `CheckHash`/`MarkDraftChecked`/`RecordDraftCheck` un-check a step whose checked values changed (A28), `DiscardDraft`/`DiscardDraftIf` (Publish). `Discover` lists known company clients (stored bundles, the draft, per-account client files, accounts on non-shared clients), never our shared baked ids.
- `DryAuthorize` checks a Linear or Microsoft client without a sign-in (`ok`, `rejected`, `network`, `admin_consent` + `AdminConsentURL`). `Mobileconfig` builds the `.mobileconfig` with `CompanyBundle`. `about.go` writes the Slack About text ("Watchtower for <company> — connect: <link>", then the connect code; `aboutLeadsWithCode` = false pending spike S1.2).
- Own Google project: `SavePersonal` stores a `personal` bundle named after the signed-in address; `IsOwnProject` = tied to a personal bundle, or untied with a legacy `google_credentials_<id>.json`. `OwnProjectWeeklyRelogin` = false (spike S2 pending).

## Accounts and their client

- Migration 00210: `company_slug TEXT NOT NULL DEFAULT ''` on `slack_accounts`, `google_accounts`, `jira_accounts`, `linear_accounts`, `email_accounts`; `jira_accounts.auth_kind` (`oauth|api_token`) and `last_pdr_at`. Go writes `company_slug` (account add from a bundle, the bridge, a Replace); Swift reads it to group rows.
- `internal/oauthclient`: per-account client records `<workspace>/<source>_client_<id>.json` (0600) for Jira (`jira`), Linear (`linear`) and Outlook (`outlook`); Google keeps `google_credentials_<id>.json`. Written when an account is added from a bundle, rewritten only by a newer bundle's confirmation; a purge deletes them with the token (PURGE-02).
- Resolvers (`cmd/oauth_resolve.go`): `resolve{Jira,Google,Linear,Microsoft}OAuthConfigForCompany(slug)` and `…ForAccount(account)`: the company's bundle → the account's own client file → env (development) → the baked default. No argument-less Jira resolver remains. A tied account whose client file names another client than its bundle's gets `errClientChanged`; it and `errNoOAuthClient` are Re-login (`needsCompanyRelogin`), never revoked.
- A refresh the vendor refuses for the client itself (`invalid_client`, `unauthorized_client`, Google's `deleted_client`) is `oauthclient.ErrClientRejected` (Atlassian: `jira.ErrClientRejected`): status `error`, never `revoked`, so PURGE-01 schedules no 72-hour purge. Code `invalid_client` for a tied account (row "Re-login needed — your company changed its app; open the new link"), `unknown_client` for an untied one ("Re-login needed — open your company's link"). The daemon records them with `recordJiraClientRejected` / `recordClientRejected`.
- `db.BackfillSlackClientIDs` (plan B, 00196) fills `client_id` only on rows with `client_id = ''` **and** `company_slug = ''`: a company row keeps its bundle's client.

## CLI (`cmd/company*.go`)

| Verb | What it does |
|---|---|
| `company list [--json]` | Stored companies plus the forced one (`forced`), damaged files as `errors` |
| `company inspect [--slug S] [--json]` | What a wire on stdin (or a stored company) would connect: state, changes, refusal; stores nothing |
| `company confirm --source link\|code\|mdm [--replace] [--json]` | Stores a wire from stdin after the owner's press; a changed company needs `--replace` (`needs_replace`), which marks the changed vendors' accounts `company_changed_app` |
| `company check google\|atlassian\|linear\|microsoft [--client-id] [--tenant] [--replace] [--json]` | The wizard's check: Google and Atlassian sign in through the client read on stdin (and store the bundle, tying the account); Linear and Microsoft run `DryAuthorize`. Results `ok`, `rejected`, `network`, `cancelled`, `replace_needed`, `forced`, `admin_consent` |
| `company draft show\|save\|discard\|discover [--json]` | The wizard's draft and the known-client discovery |
| `company publish [--json]` | Reads `{company, config_token}` on stdin, packs and stores the bundle, writes the About text through `apps.manifest.update`, deletes the draft. Results `ok`, `no_slack`, `token_expired`, `network`, `refused`, `atlassian_unchecked` |
| `company profile --slug S` | Prints the `.mobileconfig` |
| `company connect --slug S [--vendors …] [--json]` | One-shot chain over the company's vendors, by default those without a working account; JSON lines `company_vendor`, `company_done` |
| `company bridge [--json]` | Corp build only (see below) |

Each vendor's login takes `--company <slug>`: `google add`, `jira add`, `linear add`, `outlook login`. `google add --client-id X --client-secret-stdin` stores an own project as a personal bundle; `jira add|login --api-token-stdin` connects with an API token ([jira-multi-account.md](jira-multi-account.md)). New verbs are listed in `cmd/audit_cli_test.go`.

## The link and the chain

- `cmd/company_listener.go`: the Slack connect listener (`slack connect serve`, `127.0.0.1:18551`) also serves `GET /company/connect?b=<wire>`. A valid bundle answers 302 to `/company/connected` (a reload never resubmits); the request log keeps the path only. Browser pages (`internal/oauthpage`, fixture `cmd/testdata/company/pages.json`): `open`, `refused` (with the reason), `newer`, `busy` (another link waits for its confirm), `not_taken`.
- `slack connect serve` emits `company_link` (the wire, for the Desktop's confirm), `company_vendor`, `company_done` (golden `internal/slackconnect/testdata/company_events.jsonl`) and reads `company_dismiss`, `company_connect`, `company_skip`, `company_stop`. A chain runs one vendor at a time as a child `watchtower` process (`google add --company`, `jira add --company`, …; Slack in-process), stops when stdin closes, and refuses a second chain or a Slack start (`busy`); a Slack link that arrives while a chain runs is cancelled and answered `link_busy`.
- Corp bridge (`cmd/company_bridge.go`, Task 28): `company bridge` on a flavoured build stores a bundle from the build's baked clients (named by `BUILD_COMPANY_NAME`, required for the corp flavor), ties every account signed in through them and writes `<workspace>/company_migrated`; the app runs it at launch before the daemon (`CompanyBridgeLaunch`). A no-op on the public build; idempotent; a failure retries next launch. Outlook is never tied (no proven tenant). Slack rows: the bridge first runs the A17 client-id backfill (rows from 0.28.4 carry no `client_id` and their token files name none; a tied row is never backfilled later, so without it the public build's Slack setup finds no company app for the admin's adopt and Re-login drops to the code paste), then judges each row by its own `client_id` — a row on a workspace's own app is not on the baked client, so it is neither tied nor taken as the bundle's team (`TestBridge_PublicSlackOnRetiredIDStaysCompanyApp`, `TestBridge_SlackOnOwnAppStaysUntied`).

## Retirements

- Google (D11): our shared client keeps the Calendar scopes only (`googleScopesFor`); Gmail needs a company or own project. `google accounts --json` rows carry `company_slug`, `shared_gmail`, `own_project`.
- Atlassian (D4, D15 amended, ask #1600): `scripts/build-app.sh` (`shared-jira-check`) refuses a public release that sets `WATCHTOWER_JIRA_CLIENT_ID/SECRET`; dev and flavoured builds may keep them. With no client, a shared-app account's refresh fails `unknown_client` → Re-login, no countdown. `jira accounts --json` is a plain array with `auth_kind`, `company_slug`, `shared_atlassian`, `purge_lease_at`.
- Linear and Microsoft keep our shared apps; a bundle may carry the company's own.

## Personal Data Reporting (`internal/atlassianpdr`)

Per Jira account every 7 days (`last_pdr_at`), after the sync: `atlassianpdr.Run` reports the stored account ids in chunks of 90 (`ClientReporter`), or for an API-token account looks the profiles up (`LookupReporter`, `user/bulk`). `closed` → `EraseClosed` (`db.PlanAtlassianErase` computes every edit before the write lock, then `db.EraseAtlassianPeople` applies them in one short, batched write transaction: `jira_user_map`, `ext_users`, the person's name columns, custom-field names, payloads blanked, KB documents marked dirty); `updated` → refetch. User-picker custom fields keep their people's account ids beside the display value (`custom_fields_json`'s reserved `_people` key, `db.CustomFieldPeopleKey`, written by the Jira sync), so a person named only in a picker is reported, and erased one entry at a time (a multi-user field keeps the others); a row synced before the key existed has no ids, and is erased as before (a whole value equal to a name stored for the closed id, on an issue whose payload names it) until its next sync writes them. A lookup (`LookupReporter`) that leaves an asked id out answers it `StatusUnknown`: never closed, the rest is acted on, but `last_pdr_at` is not stamped (`Result.Unknown`), and the daemon retries the account `pdrRetryAfter` (6 h) later. Memory and free-text derived texts are not touched (D17, ask #1518). An error erases nothing; a missing `report:personal-data` scope records `pdr_scope_missing` ("Re-login to finish the setup"). OAuth logins tied to a company request the scope (`WithPersonalDataReporting`) and retry without it if the app refuses.

## Desktop

- `CompanyBundle.swift`, `CompanyVendor.swift` (Models); in `WatchtowerCore/Services/Company/`: `CompanyConnectionsPresentation` (+Details: zone, groups, row statuses, banners, lock cards; every string), `CompaniesZoneModel` (`AppState.companiesZone`), `CompanyConnectFlowModel` (`AppState.companyConnect`: confirm, replace, chain sheet), `CompanySetupWizardModel` (+Copy) and `CompanyVendorGuide` (the wizard page, `AppState.companySetup`), `OwnGoogleProjectModel`, `AtlassianTokenFormModel`, `SharedAppFlagReader`, `CompanyCLI`. Views: `Views/Company/`, `Views/Connections/{CompaniesZone,CompanyAccountGroups,CompanyAccountsSections}.swift`, `Views/Settings/{OwnGoogleProjectPage,AtlassianTokenSheet}.swift`.
- Connections overview: the **Companies** zone above Sources (cards with **Connect the rest** / **Connect all** / **Re-login**, the draft's **Continue setup** line, **Set up for my company**, **Connect with a company code**, the port-busy line). Service details group accounts: one group per company, then own Google project, **API tokens** (Jira), **API keys** (Linear), Watchtower's shared app, **Other accounts**. One `CompanyLockCard` under a locked group (`AllowOwnGoogleProject`, `AllowAtlassianAPIToken`), rows "Stopped by your organization — data kept".
- More ways into the wizard and the code field (screens spec §2.1): the end of the overview's **Connect…** menu and Jira's empty state.
- Gmail (D11): Email → **Add Account** → **Connect Gmail** opens the Google detail — the own Google project page when no stored company has a Google app (`gmailRoute`, +Gmail); the **Add Google Account** sheet shows Gmail off with a note unless the build is flavored.
- A company link during onboarding waits for onboarding to end; a pasted code is refused with `pasteDuringOnboarding`.

## v1 limits and follow-ups

- Draft is not saved on quit; Atlassian's checklist and Google's project name stay in memory only; "Confluence off" is not written back to the bundle.
- `jira add` / `outlook login --company` always add a new row (no rebind by account id); one-shot `company connect` has no `--no-open`, and a non-Slack child's authorize URL is lost if the browser fails.
- Port 18551 held by another app: no fallback for the one-shot chain.
- Spikes S1 (Atlassian callbacks, Slack link rendering) and S2 (personal Gmail past 7 days) are pending; their defaults are named above.
