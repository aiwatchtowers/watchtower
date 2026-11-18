# Slack Full (Plan B) — Entry into Full and the Retired Shared App — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A company gets Watchtower's Slack app into its own workspace with one paste of a configuration token, every colleague connects from the app's About page (or an MDM key, or a pasted code) with PKCE and no client secret, tokens refresh on their own, accounts on the retired shared public app keep working under a banner that offers Full or Live and move to Full on the same account row (history kept), and a company that already has its own Watchtower app (the corp build's baked app) brings that app up to date instead of creating a second one. Every screen of the screens spec ships with it.

**Architecture:**
- **Go owns every Slack call and every write.** A new package `internal/slackconnect` holds the PKCE loopback flow (link and code parsing, the authorize URL, the callback, the secret-less code exchange, one flow at a time). A new package `internal/slackapp` holds the workspace-app setup (our manifest, `apps.manifest.create`/`update` behind an interface, the setup record). A new `internal/slackauth` holds token freshness (refresh under a per-account flock) for every token reader.
- **Port 18551 has one owner at a time.** While the Desktop runs, its long-lived child `watchtower slack connect serve` holds 127.0.0.1:18551, answers `/slack/connect` and `/callback`, and talks to the Desktop in JSON lines over stdin/stdout. Without the Desktop, `watchtower slack connect --team --client` binds it one-shot. The child exits on stdin EOF, so it dies with the app.
- **The link's first hop never redirects.** `/slack/connect` answers at once with a page "Switch to Watchtower to confirm"; the Desktop comes forward with the confirm sheet; on **Connect** the child opens Slack's authorize URL in the browser. Pasted links, codes, MDM rows and Reconnect skip the confirm and start at the same "open the browser" step, so there is one flow.
- **Setup is four CLI verbs** (`slack app create|adopt|link|status --json`, config token on stdin, one JSON line per step) run by `SlackAppSetupModel` on `AppState`; `adopt` brings an existing company app (the corp build's baked app) in line with our manifest through `apps.manifest.update` instead of creating a second app (ask #1425); the admin's own connect is the ordinary connect flow.
- **Moving to Full re-binds the account row** (ask #1425): a connect for a team that already has a live account writes the new token and client id onto that same row, so the account id, its namespaced data and its sync position stay; nothing is soft-removed.
- **Shared-app detection is Go-only and has one rule, with no build-flavor check in app code** (`shared_app` in `slack accounts --json`; ask #1425): an account is on the shared app iff its `client_id` equals `auth.RetiredSharedClientID`, the retired **public** shared app's id. Any other client id — a workspace app made by setup, an id from MDM `SlackApps` or a link, the corp build's baked company app — is a company app, i.e. Full. Rows written before migration `<NNNNN>` get their client id backfilled from the id the build bakes (or, once nothing is baked, from `RetiredSharedClientID`). Swift only reads the flag. Only the public profile sets `RETIRED_SLACK_CLIENT_ID`; the release guard in `scripts/build-app.sh` makes every public release set it.
- **Screens** follow the approved screens spec: `SlackModePresentation`, `SlackAppSetupModel`, `SlackConnectFlowModel` own every string; views lay them out with the design kit; colors only through `Tone`.

**Tech Stack:** Go 1.26 (cobra, `database/sql` on the in-repo SQLCipher driver, goose SQL migrations, `net/http` loopback server, `testing/synctest`, `golang.org/x/sys/unix` flock as `internal/db` already uses), SwiftUI + GRDB (WatchtowerCore, design kit), bash release scripts.

**Spec:** `docs/superpowers/specs/2026-11-14-slack-full-and-live-design.md` §5 (Entry into Full), §6 (retired shared app, D11), §7 (Setup / Link / Tokens rows), §8 (writers), §9 (rows T7, T8, T9), decisions D4, D7, D8, D9, D11, D13. Screens: `docs/superpowers/specs/2026-11-15-slack-full-live-screens-design.md` (all of it; decisions approved in ask #1315). Plan A (`2026-11-14-slack-live-plan-a.md`) and the adaptive sync plan (`2026-11-15-slack-adaptive-sync.md`) are shipped; this plan builds on `SlackMode`, `SlackLiveStatusCenter`, `slack_live_status`, `channel_settings.sync_excluded`.

## Global Constraints

- **Binding (owner):** no bot user, no server or hub, no admin Mac after setup; PKCE with no client secret anywhere — the secret in the `apps.manifest.create` response is dropped in the decoder and never reaches a variable that outlives it; OAuth redirect to the loopback listener on `127.0.0.1:18551` (port busy: paste the link or code); the link lives in the app's About page (`long_description`); MDM key `SlackApps`; everything local, also for a company.
- **The configuration token** reaches the CLI only on stdin (never argv, env or disk), lives in the CLI process for that run and in `SlackAppSetupModel` until the run ends.
- **The link:** `http://127.0.0.1:18551/slack/connect?team=<team id>&client=<client id>`; the code: `<team id>:<client id>`. Team ids match `^[TE][A-Z0-9]{2,}$`, client ids `^[0-9]+\.[0-9]+$` (parse refuses anything else; pinned by `TestParseConnectInput`).
- **The listener** answers only `GET /slack/connect` and `GET /callback`, checks `Host` is exactly `127.0.0.1:18551` (or the test port), never serves files, binds `127.0.0.1` only. `TestOAuthPortRanges_Disjoint` (`internal/slackconnect`) lists every listener's range (Slack 18491–18500, Calendar 18501–18510, Jira 18511–18520, Gmail 18521–18530, Outlook/IMAP 18531–18540, Linear 18531–18535 as the listed known exception, Quick Connections 18541–18550) and asserts 18551 is in none.
- **One connect flow at a time**, in the child (Go registry) and in the Desktop (`SlackAuthFlowState` guard, shared with Reconnect and the legacy Workspace block).
- **Flow lifetime (A22, ask #1438):** in memory only; a confirmed flow has **no deadline**: it waits for its callback until the callback, **Cancel**, or the app quits. The browser-step sheet shows how long it has waited ("Waiting for Slack since 12 min") once past 5 minutes, and keeps **Cancel**. Reason: a slow admin approval never produces a callback (Slack shows its own "request sent" page, screens §4.3; spike Q5), so a longer timer would only keep a dead flow; and a member who is slow on Slack's consent page must not lose the flow to a timer. A callback with no live flow gets the "start again" page (`internal/oauthpage`), nothing stored.
- **Next migration:** `<NNNNN>` = the next free number at implementation time (plan B and the policy-hygiene plan both start after `00193`; the second to land renumbers). Mirror into `internal/db/schema.sql`; add new tables to `TestAllTablesExist`; regenerate `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`.
- **UI:** strings only in `SlackModePresentation`, `SlackAppSetupModel`, `SlackConnectFlowModel` (plus `FeatureReadiness`/`ReadinessSource` and the phone's `AccountStatusStyle` for their own), each pinned by tests; colors only via `Tone`; design kit components; the implementation re-renders the screens spec's shot names from the real views (`DesignShotsTests.testSlackFullLiveShotsRender`). English UI; Full / Live names (D1).
- **Tests:** never wait on wall-clock (`synctest`, injected clocks, fakes); a test that starts a process reaps its process group in `t.Cleanup`; the Go listener is tested in-process on port 0, never on 18551; no real Slack ids, domains or names (placeholders, `acme`, `example.com`).
- **Policy:** every new runnable Slack verb is guarded by `applySourceGuards` (`slack` source); `TestPolicyLogin_EverySourceCommandIsGuarded` must pass.
- **Inner loop per task** (`go test ./internal/<pkg>`, `make test-swift FILTER=…`, `make lint-diff`, `make lint-swift` for every Swift task — lint-diff is Go-only). Full gate once per phase by the controller.
- **Branching:** umbrella branch `feature/1709-plan-b` off main; every task PR targets it; the umbrella PR stays draft until Task 18 is done.
- Board language Russian; repo files English.

## Review Focus

1. A web page opens `http://127.0.0.1:18551/slack/connect?...` on its own: nothing reaches Slack and nothing is stored before the owner presses **Connect** — `TestSlackConnectListener_RequiresConfirm` (Task 7), `SlackConnectFlowModelTests.testLinkStartsAtConfirm` (Task 14).
2. The `client_secret` of `apps.manifest.create` never lands in a file, the DB, a log line or stdout — `TestAppSetup_SecretNeverStored` greps the workspace dir, the DB dump and captured output (Task 9).
3. A second `slack app create` after a create that was cut off (Mac closed) never creates a second app — `TestAppSetup_ResumeAfterCreate` (Task 9).
4. Two processes refresh the same rotated token: only one calls Slack, the other re-reads the file; the old refresh token is never used twice — `TestSlackRefresh_LockRace` (Task 8).
5. Only the retired public shared id is "shared": the corp build's baked company app, an MDM or link id, and a build without `RETIRED_SLACK_CLIENT_ID` never show the banner — `TestSlackAccountSharedApp_*`, `TestBackfillSlackClientIDs_*` (Task 3).
6. Moving a shared-app account to Full re-binds the same row: messages, digests and the search watermark stay with the account id; a failed exchange or token save leaves the old token working; a crash between the token save and the row update is repaired on the next token read — `TestSlackLinkConnect_Rebind*` (Task 7).
8. Refresh happens when the access token has < 1 h left **or** the refresh token has < 7 days left, so a Mac that syncs rarely never lets the refresh token lapse — `TestSlackRefresh_RefreshTokenNearExpiry` (Task 8).
7. Team in the link ≠ team Slack returns: nothing stored, the row is rolled back — `TestSlackLinkConnect_TeamMismatch` (Task 7).

## Task 1 spike — answers (filled by the controller after Task 1)

| # | Question | Answer | Consequence in this plan |
|---|---|---|---|
| Q1 | `apps.manifest.create` with a config token: accepted with our manifest (no bot user, user scopes only, token rotation on)? Response shape (`app_id`, `credentials.client_id`, `oauth_authorize_url`)? Error codes for a bad / expired token and for a workspace that forbids app creation? | _pending_ | Task 16 maps codes to `bad_token` / `not_allowed` / `refused` |
| Q2 | How the config token tells the workspace (team id, name) before the create: `auth.test` with the config token, or only after the admin's connect? | _pending_ | Task 16: the `team` step source; if only after connect, the link is written after the admin connects (the model's order in Task 13 already supports it) |
| Q3 | PKCE without a secret: does `oauth.v2.access` accept `code` + `code_verifier` + `client_id` (no secret) for a **user** token on an internal workspace app? Any manifest field needed to turn PKCE on? | _pending_ | Task 16: the exchange form and the manifest field |
| Q4 | Redirect: does the manifest accept `http://127.0.0.1:18551/callback`? Does `authorize` accept a loopback redirect on another port than the registered one (RFC 8252 §7.3)? If http is refused, does `https://127.0.0.1:18551/callback` with our self-signed cert work? | _pending_ | Task 16: http vs https listener; whether a paste with port 18551 busy can use an ephemeral callback port (see Decision A9) |
| Q5 | A non-admin authorizes in a workspace that requires app approval: does Slack redirect to the callback (with which `error`), or show its own "request sent" page and send nothing? | _pending_ | Task 16: whether `install_requested_at` is ever written (the approval row of screens §3.4) |
| Q6 | Is a URL in `long_description` clickable on the app's About tab? Length limit, markdown? | _pending_ | Task 16: the description text; the code stays either way |
| Q7 | Can a regular member find the app (Apps → search / app directory) and open its About tab before installing it? After the admin installs a user-token-only app? | _pending_ | if not: the entry depends on the code being passed around — **stop and ask the owner** before Task 16 |
| Q8 | `apps.manifest.update` keeps `app_id` and `client_id`, does not reset installs or require re-approval when only `long_description` changes? | _pending_ | Task 16 |
| Q9 | Token rotation: `expires_in` of the access token, `refresh_token` present for the user token, refresh with `grant_type=refresh_token` + `client_id` and no secret, does the refresh token rotate, refresh token lifetime, error codes for an expired / reused refresh token | _pending_ | Task 16: the refresher's thresholds (Task 8 defaults: refresh when the access token has < 1 h left; Re-login on `invalid_refresh_token`) |
| Q10 | Rate tier of `conversations.history` for the internal workspace app (expected Tier 3, not the non-Marketplace Tier 1) | _pending_ | feature note only |
| Q11 | Adopt (ask #1425): `apps.manifest.export` and `apps.manifest.update` on an **existing** app with a config token of one of its collaborators — accepted? Error code for a token of a non-collaborator? Does adding a redirect URL / user scopes / changing `long_description` force a reinstall or a new admin approval, and do existing user tokens keep working? | _pending_ | Task 16: adopt's error map (`not_collaborator`), whether adopt must warn "colleagues will be asked to approve again" |
| Q12 | Can the app id of an existing app be read from a user token connected through it (`auth.test` fields, or `app_id` in `oauth.v2.access` / refresh responses)? | _pending_ | Task 16: whether adopt asks for the App ID (Decision A19) or derives it |
| Q13 | PKCE without a secret on an app that **has** a client secret and was created without PKCE (the corp app): does secret-less exchange work after adopt adds the loopback redirect, or does the app need a setting? | _pending_ | Task 16: adopt's manifest change; if impossible, corp keeps its baked id until a new app exists — **stop and ask the owner** |
| Q14 | Turning on token rotation on an existing app (adopt): can it be turned off again, and what happens to existing non-rotating tokens? | _pending_ | adopt leaves the app's rotation setting as it is (A20); recorded for the feature note |

**Spike results (2026-11-18, test workspace; live calls + docs.slack.dev).** These override provisional values in Tasks 6–9 and are applied in Task 16:

- **PKCE needs `oauth_config.pkce_enabled: true` in the manifest** (docs.slack.dev/authentication/using-pkce). Without it a secret-less `oauth.v2.access` answers `bad_client_secret`. The switch is one-way (the app becomes a public client; undo only via Slack support); refresh tokens then expire after 30 days; loopback redirects count as desktop redirects, which require `code_challenge`+`code_challenge_method=S256` and cannot request bot scopes. Task 9's `BuildManifest` sets it. Whether adopt sets it on an existing company app stays behind a flag (default off) until Task 16 checks that old tokens survive.
- **Q1** `apps.manifest.create` accepts the manifest (17 user scopes, no bot, rotation on, loopback redirect); response keys `app_id`, `credentials{client_id, client_secret, …}`, `oauth_authorize_url`, `team_id`, `team_domain`; errors `invalid_auth`, `not_authed`, `invalid_manifest` + `errors[]`.
- **Q2** `auth.test` with the config token returns `team_id`, `team`, `expires_in`.
- **Q3** PKCE authorize works (live, `team:read`); the exchange works once `pkce_enabled` is on (docs). A rotating exchange returns `authed_user.expires_in=43200`, `refresh_token`, and a top-level `app_id`.
- **Q4** Redirect match includes scheme and port; no loopback port wildcard is documented — keep the exact registered port (18551). Without PKCE a `http://127.0.0.1` redirect is treated as a server redirect (must be https) — the likely cause of the "Invalid permissions requested" seen when the full scope list was requested without PKCE. All 17 scopes are valid user scopes (none deprecated or Marketplace-only).
- **Q5/Q7** Not settled by docs: with app approval on, members request and admins approve; no callback is documented → the flow waits (A22) and shows Slack's own page. Live check in Task 16.
- **Q6** `long_description` 175–4000 characters, Slack mrkdwn; About-tab rendering checked in Task 16.
- **Q8/Q11** `apps.manifest.update` replaces the whole manifest; a description-only update keeps `app_id` (`permissions_updated:false`); scope/redirect changes → `permissions_updated:true` and need a reinstall. Non-collaborator → `no_permission`; unknown id → `invalid_app_id`; deleted app → `app_not_found`. Nothing documents a `client_id` change or token revocation on update.
- **Q9** Refresh: `grant_type=refresh_token`, `refresh_token`, `client_id` (no secret, no PKCE params); new `access_token`, `expires_in`, new `refresh_token`; each refresh token is single-use after a short grace period (at most 2 active) → refresh must be serialised across processes (Task 8's flock) and the new token saved before use. No refresh-token expiry field is documented → track 30 days locally.
- **Q10** `conversations.history` Tier 3 for internal apps; the 2025-05-29 limits (15 messages, 1 req/min) apply to non-Marketplace commercially distributed apps, "internal customer-built applications are not impacted".
- **Q12** `oauth.v2.access` carries a top-level `app_id` → the App ID field (A19) is needed only for rows connected before this plan.
- **Q13** Every app has a secret; PKCE is the manifest flag above.
- **Q14** Rotation can be turned on but never off (`cannot_disable_once_enabled`) → adopt never touches it (A20 confirmed).
- **`team=`** is a hint, dropped if the user is not signed in to that workspace; pass a `T…` id (an `E…` id asks for an org-level install).

## Owner rulings in ask #1414

- **Move off the shared app:** ask #1414 chose «Новая строка, как в спеке»; **overturned by ask #1425: «Перепривязать строку»** — the existing `slack_accounts` row is re-bound to the new client id (new token, same account id, history kept); nothing is soft-removed or purged (Task 7, A6).
- **Contracts:** «Одобряю» — SLACKFULL-01/02, `SlackApps` in POLICY-01/02, the `slack accounts --json` document.
- **Corp:** ask #1414 «Убираем, корп как все» (corp's baked app counted as a retired shared app) is **overturned by ask #1425: «да и я бы тут добавил, что я бы хотел его просто модифицировать»** — the corp build's baked app is that company's own workspace app (Full): no banner, no chip, no second Watchtower app. **Set up for my company** can modify an existing app (`slack app adopt`: our scopes, the loopback redirect URL and the About link through `apps.manifest.update`). The baked id still leaves the corp build in Task 18; corp users then get the id from the About link or MDM `SlackApps`, and because the row re-binds, nothing is lost if the id changes. There is still no corp-only code path in the app: the rule is "the retired public shared id is shared; every other id is a company app".
- **Spec lines superseded by asks #1414/#1425** (edited in Task 17, each marked with its ask):
  - parent spec D11 "synced data follows the purge rules" and §6 "Moving to Full adds a new account row and soft-removes the old one (SLACK-01 unchanged); the old data then follows the purge lease (PURGE-01)" → the move re-binds the same row; nothing is removed or purged (#1425);
  - parent spec §9 row "The shared app is retired, old accounts move | T9 | `TestSlack01_*` unchanged" → test `TestSlackLinkConnect_Rebind*` (#1425);
  - parent spec §5.1 → the setup also adopts an existing app with `apps.manifest.update` (#1425);
  - parent spec §5.4 "The corp build keeps its baked credentials until its admin moves to the key; nothing changes for it on day one" → the corp build keeps its baked id until Task 18, its admin adopts the app first, and its accounts are Full throughout (#1425);
  - parent spec §6 "The public build stops baking `DefaultClientID`/`DefaultClientSecret`" → every build stops baking them (#1414, kept by #1425);
  - screens spec §1.1 "Which account is on the shared app (build-aware)": the Public/Corp build bullets and the `FlavorOf` rule → one rule by client id, no flavor check in app code; "Empty at run time anyway … logs once" → rows without a client id are backfilled (Task 3), so an unset `RetiredSharedClientID` simply means "nothing is shared"; `TestSlackAccountSharedApp_PublicBuild`/`_CorpBuildNever`/`_EmptyRetiredIDFallsBack` → `TestSlackAccountSharedApp_RetiredIDOnly`, `TestBackfillSlackClientIDs_*` (#1425);
  - screens spec §3 → new adopt states and the "ask your admin" note (Task 13, mockups added on this branch) (#1425, review #1426);
  - screens spec §4.2 last paragraph and §11 #19 "public build only, after T9 … the corp build keeps **Add Slack Account**" → every build once it no longer bakes an app (`builtin_app`, A8) (#1414, kept by #1425);
  - screens spec §5 banner "it goes when the account moves (the new row soft-removes the old one, SLACK-01)" → it goes when the row is re-bound (#1425);
  - screens spec §11 #24 "public build = …; corp build never" → the single client-id rule (#1425);
  - screens spec §4.4 "Paste the link or the code here instead" → narrowed if spike Q4 says Slack is strict about the port (A9).
- **Agent decisions A1–A16:** «Принять все».
- **Review round 1 (ask #1426)** folded in: refresh on refresh-token expiry (Task 8), every token-file writer under one lock (Task 8), mockups for the onboarding connect sheet and the new setup states (Task 13, Task 15), the flow's callback wait (A22), the "ask your admin" state (Task 13), A9's narrowing (Task 17).

## Decisions made by the agent (A1–A16 approved in ask #1414; A17–A23 approved in ask #1438)

| # | Decision | Recommendation |
|---|---|---|
| A1 | The loopback listener is a Go child of the Desktop (`slack connect serve`, JSON lines on stdin/stdout), not a Swift `NWListener`: PKCE, the exchange and the account write stay in one Go path with the spec's Go test names | accept |
| A2 | `/slack/connect` answers at once with a "switch to Watchtower" page; after **Connect** the child opens the authorize URL in the browser (a new tab) instead of holding the HTTP request until the owner presses | accept (no held requests, one flow for link/paste/MDM/Reconnect) |
| A3 | Without the Desktop, `slack connect --team T --client C` binds 18551 one-shot; with the Desktop running it fails with "port 18551 is busy (is Watchtower open? connect from Connections → Slack)" | accept |
| A4 | The admin's own connect in setup is the ordinary connect flow, started by `SlackAppSetupModel` (skip-confirm) after `slack app create`; `app create` itself never binds 18551 | accept |
| A5 | The setup record is a DB table `slack_app_setups` (one row per team), "connected" is derived from an `ok` `slack_accounts` row with that client id, never stored | accept |
| A6 | Connecting a team that already has a live account re-binds that row, whatever its client id (ask #1425): token file first (atomic), then the row's `client_id`/`app_id`; a token file whose client id differs from the row is the truth and the next token read repairs the row; no new row, no soft-remove | owner's ruling (ask #1425) |
| A7 | Reconnect of a workspace-app account in the Desktop goes through the connect flow (`start` with the account id, skip-confirm); an account with `relogin: "move"` (on the retired shared app once nothing bakes it) shows **Move to Full** instead of Reconnect, which opens the banner's path (connect section / **Set up for my company**), never the connect flow (review #1439); `slack accounts --json` says per account `relogin: "builtin" \| "connect"` | accept |
| A8 | `slack accounts --json` gains top-level `builtin_app` (a baked or env client id **and** secret exist). The Desktop shows **Add Slack Account** only when it is true, **Connect another workspace…** otherwise. After T9 no build bakes a Slack app, so the sheet goes everywhere (ask #1414 supersedes #1315 #19's corp exception); Swift never needs the build flavor | accept |
| A9 | If the spike says Slack is strict about the redirect port (Q4), the manifest registers `http://127.0.0.1:18551/callback` only and a paste with 18551 busy shows "free port 18551 or quit the app holding it" (no way around it). If Slack accepts any loopback port, a paste or MDM connect while 18551 is busy uses an ephemeral callback port | decide after the spike; if Slack is strict about the port, the screens spec's promise "paste works while 18551 is busy" (§4.4, §6 Listener row) narrows to "free the port", and Task 17 updates the screens spec |
| A10 | The Desktop restarts the listener child once on an unexpected exit, then only when Connections → Slack opens (the same rule as the port-busy retry) | accept |
| A11 | Manifest user scopes = `slackmanifest.UserScopes()` (the policy-hygiene plan's Task 4: one manifest, 17 scopes); `im:write` stays (`OpenDM` opens a DM for sending), `chat:write` stays; plan B adds no scope list of its own; pinned by `TestManifest_Scopes` | accepted (adjusted by the coordinator: `im:write` kept) |
| A12 | Token refresh is a pre-use check in every token reader (`slackauth.LoadFresh`) plus the daemon's per-cycle call, not a separate timer | accept |
| A13 | The onboarding Slack step follows `builtin_app` too: false → its Slack card opens a sheet with the connect section (link/code field, MDM rows, **Set up for my company**) instead of `AddSlackAccountView` (not covered by the screens spec) | accept |
| A14 | The legacy **Workspace** block (`auth login`, account #1) routes its Reconnect through the same per-account rule as A7 | accept |
| A15 | After retirement (Task 18) the `retired-slack-id-check` also refuses any release (public or corp) that still sets `WATCHTOWER_OAUTH_CLIENT_SECRET`, and a public release whose `WATCHTOWER_OAUTH_CLIENT_ID` equals `RETIRED_SLACK_CLIENT_ID` | accept (keeps the retirement from being undone by a stale profile) |
| A16 | New inventory entries SLACKFULL-01 (nothing connects without the owner's press), SLACKFULL-02 (no Slack client secret or config token is stored, logged or in argv) | accept |
| A17 | Rows without a client id (connected before migration `<NNNNN>`) are backfilled once from the id the build bakes, or, when nothing is baked, from `RetiredSharedClientID`; a single `UPDATE … WHERE client_id = ''` run by `slack accounts`, the daemon's start and every connect (Task 3). After Task 18, a corp row never backfilled (an install that skipped every plan-B release) stays without a client id: not shared, and its Re-login goes through the link / MDM | accept (ask #1438) |
| A18 | Re-binding refuses a sign-in as a **different Slack user** than the row's `current_user_id` ("Signed in as someone else; nothing was changed") — the row's history belongs to its user | accept (ask #1438) |
| A19 | `slack app adopt` takes the app's client id from the team's live account row; the App ID comes from the row's `app_id` (stored from every `oauth.v2.access` from migration `<NNNNN>` on) and, when unknown (corp rows connected earlier, unless spike Q12 finds a way), from one field in the sheet: "App ID (on the app's Basic Information page)" | accept (ask #1438) |
| A20 | Adopt merges, never replaces: it reads the app's manifest (`apps.manifest.export`), adds our loopback redirect URL and any missing user scopes, writes `long_description`, and keeps every other field (existing redirect URLs, bot, scopes we do not use, token-rotation setting) | accept (ask #1438) |
| A21 | The old shared-app token is dropped from disk on re-bind, not revoked in Slack (the retired app stops working on Slack's side anyway; a revoke adds a failure mode for nothing) | accept (ask #1438) |
| A22 | A confirmed connect flow has no deadline (see Global Constraints) instead of the earlier 10-minute timer, which had no source | accept (ask #1438) |
| A23 | "Ask your admin" (the setup's `not_allowed` state, screens §3.2): adds **Copy a note for your admin** — "Please set up Watchtower for <workspace>: <guide link>", the guide page on setting up Slack for a company (`ReleaseLinks` guide URL + anchor) — beside **Cancel**/**Try again** | accept (ask #1438) |

A17–A23 were approved as proposed in ask #1438 ("accept all"); the steps that implement them are Task 3 (A17 backfill), Task 6 (A22 registry without a deadline), Task 7 (A18 same-user check, A21 no revoke), Task 9 (A19 App ID source, A20 merge rules), Task 13 (A19 App ID field, A23 admin note), and Task 14's waiting line (A22).

## Contract changes (approved in ask #1414)

- **New contracts:** SLACKFULL-01 and SLACKFULL-02 (A16) in `docs/inventory/slack-accounts.md`.
- **POLICY-01/02:** new key `SlackApps` (approved in the spec, D4). Its fail-closed value is "no organization rows" (an empty list), problems reported like the other list keys; `policy show --json` gains `keys.SlackApps` (the pinned document grows one key).
- **SLACK-01:** unchanged and no longer touched: the move re-binds the row (ask #1425), so `removeSlackAccount` gets no new caller.
- **`slack accounts`** gains `--json` (new document: `builtin_app`, `accounts[]` with `id`, `team_id`, `client_id`, `shared_app`, `relogin`).
- **Spec deviation:** the lines listed under "Spec lines superseded by asks #1414/#1425" (edited in Task 17); A9 may narrow the screens spec's "port busy → paste works" (depends on the spike).

## Writers of the same data

| Data | Writers | Race rule |
|---|---|---|
| `slack_accounts` row + `slack_token_<id>.json` | `slack login`, `slack add`, the legacy migration (`ensureLegacySlackAccount`, `cmd/slack_legacy.go`), the connect flow incl. the re-bind (`slack connect` / `connect serve`), the refresher and its row repair (`slackauth.LoadFresh` in any process), `slack remove`, the purge | per-account flock `slack_token_<id>.json.lock` (`TokenStore.Lock`, the `linear.TokenStore.Lock` pattern on `fsutil.LockFile`) around every token-file write and every refresh; the holder wins, a waiter re-reads the file after taking the lock and refreshes only if it is still stale. Row writes are single statements inside the same lock section. The sync reads only. |
| `slack_accounts.client_id`, `app_id`, `refresh_token_expires_at` | the connect/login path incl. the re-bind (once per connect), the refresher (`refresh_token_expires_at`), `LoadFresh`'s repair (copies the token file's **non-empty** client/app id onto the row), the backfill (A17: only rows with `client_id = ''`) | same flock for the first three; the backfill's `WHERE client_id = ''` never overwrites a set id, so it needs none |
| `slack_app_setups` | `slack app create` and `slack app adopt` (insert), `slack app link` (`link_written`), the connect flow (`install_requested_at`, only if Q5 says Slack reports it) | `create`/`link` hold `slack_app_setup.lock` for the whole run (one setup at a time; a second run answers `busy`); the connect flow's one `UPDATE` needs no lock (it touches only its own column) |
| The app's manifest (`long_description`; for adopt also redirect URLs and scopes) | `slack app create`/`adopt` (via `apps.manifest.update`), `slack app link`; the company's own edits on api.slack.com | last write wins; adopt and link re-read the manifest (`apps.manifest.export`) right before the update and merge, so a human edit in between is kept |
| The connect flow | link, paste, MDM, Reconnect, setup's admin connect | one flow at a time in the child; the Desktop refuses a second start while one runs |
| Port 18551 | the Desktop's child, or one-shot `slack connect` | first bind wins; the loser reports busy |

## Lanes

```
Phase 1 (no spike needed, start now)
  Lane Go-data:   T2 ─┬─ T3 ─────────────────────────────┐
                      ├─ T8 (refresh core; thresholds → T16)│
                      └─ T9 (setup with fake Slack)  ───────┤
  Lane Go-link:   T6 ── T7 (needs T2) ──────────────────────┤
  Lane Build:     T4                                        │
  Lane Policy:    T5                                        │
  Lane Swift:     T10, T11 ── T12                           │
Phase 2 (Swift on top of the CLI contracts)                 │
  T13 (T9, T10, T11) · T14 (T5, T7, T10, T11) · T15 (T3, T13, T14)
Phase 3 (needs the spike)
  T1 spike ── T16 (T1, T6–T9) ── T17 docs ── T18 retirement (owner's go)
```

---

### Task 1: Live spike on the owner's test workspace

**Depends on:** none (blocked on the owner's configuration token; run by the controller, not a subagent)

**Files:**
- Create (not committed): `<scratchpad>/slack-spike/` — a throwaway script and its output
- Modify: this plan's "Task 1 spike — answers" table (the only committed change)

The controller runs this once the owner has generated a configuration token for the test workspace. Nothing here goes into the product; the answers go into the table above. Use only the test workspace, never a real company's. Record answers without ids or names (public repo).

- [ ] **Step 1: Token and team (Q2).** `curl -s -H "Authorization: Bearer $CFG" https://slack.com/api/auth.test` — note whether it returns `team_id`/`team`. Keep `$CFG` in the shell only.
- [ ] **Step 2: Create (Q1).** Write `manifest.json` = the Task 9 manifest (name "Watchtower spike", user scopes and `long_description` from `slackmanifest.UserScopes()`/`Description()` — `go run` a two-line helper or copy `internal/slackmanifest/slack-app-manifest.json`, `redirect_urls: ["http://127.0.0.1:18551/callback"]`, `settings.token_rotation_enabled: true`, no `bot_user`, no `features`), `long_description` with a test link. `curl -s -H "Authorization: Bearer $CFG" --data-urlencode "manifest=$(cat manifest.json)" https://slack.com/api/apps.manifest.create` — record the response keys (not values). Repeat with a garbage token and record the error code; if a second non-admin test user exists, run it with their token and record the code. If http redirect is refused, retry with `https://` (Q4) and record.
- [ ] **Step 3: PKCE login (Q3, Q4).** Make a pair: `V=$(openssl rand -hex 32); C=$(printf %s "$V" | openssl dgst -sha256 -binary | openssl base64 | tr '+/' '-_' | tr -d '=')`. Open `https://slack.com/oauth/v2/authorize?client_id=<id>&user_scope=<scopes>&redirect_uri=http%3A%2F%2F127.0.0.1%3A18551%2Fcallback&code_challenge=$C&code_challenge_method=S256&state=x` with `nc -l 127.0.0.1 18551` catching the redirect. Exchange: `curl -s -d client_id=<id> -d code=<code> -d code_verifier=$V -d redirect_uri=... -d grant_type=authorization_code https://slack.com/api/oauth.v2.access` — no secret. Record: ok or error; `authed_user` keys (`access_token`, `refresh_token`, `expires_in`). Repeat the authorize with `redirect_uri` on port 18552 (Q4 port strictness).
- [ ] **Step 4: Approval (Q5).** In the test workspace turn on "Require app approval"; sign in as the non-admin test user through Step 3's URL; record what reaches `nc` (nothing, or `error=...`).
- [ ] **Step 5: About page (Q6, Q7, Q8).** `apps.manifest.update` with a `long_description` holding the link and the code. As the non-admin user: find the app in Slack, open About, click the link (with `nc` listening) — record clickable or not, and whether the app was findable before and after the admin's install. Confirm `app_id`/`client_id` unchanged after the update and that the admin's token still works.
- [ ] **Step 6: Rotation (Q9).** `curl -s -d client_id=<id> -d grant_type=refresh_token -d refresh_token=<rt> https://slack.com/api/oauth.v2.access` — record ok/error, whether a new refresh token comes back, then reuse the old one and record the error code.
- [ ] **Step 7: Tier (Q10).** 60 calls of `conversations.history` in a minute with the user token; record whether a 429 comes before call 50.
- [ ] **Step 8: Clean up.** Delete the spike app (`apps.manifest.delete`), revoke the test tokens (`auth.revoke`), delete the scratch folder.
- [ ] **Step 9: Record and commit** the answers table: `docs(plan): plan B spike answers (#1709)`. If Q3 or Q7 is "no", stop and ask the owner before Task 16 (the design rests on them).

### Task 2: Data — client id, refresh fields, setup record

**Depends on:** none

**Files:**
- Create: `internal/db/migrations/<NNNNN>_slack_full.sql`
- Modify: `internal/db/schema.sql`, `internal/db/slack_accounts.go` (`SlackAccount.ClientID`, `AppID`, `RefreshTokenExpiresAt`; scan in every `ListSlackAccounts`/`GetSlackAccount` query; `SetSlackAccountApp(id, clientID, appID)`, `SetSlackRefreshExpiry`, `BackfillSlackClientIDs(id string) (int64, error)` — `UPDATE … SET client_id = ? WHERE client_id = ''`)
- Create: `internal/db/slack_app_setups.go`, `internal/db/slack_app_setups_test.go`
- Modify: `internal/db/db_test.go` (`expectedTables` += `slack_app_setups`)
- Modify: `internal/slack/token_store.go` (`Token.RefreshToken`, `ExpiresAt`, `RefreshExpiresAt`, `ClientID`, `AppID`, all `omitempty`; `func (s *TokenStore) Lock(ctx) (func(), error)` on `fsutil.LockFile(path+".lock")`, the same shape as `linear.TokenStore.Lock`)
- Modify: `cmd/slack.go` (`connectSlackAccount` takes the client id and writes it; `slack add`/`login` pass the resolved builtin id)
- Regenerate: schema golden, `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift`

**Interfaces:**
- Produces (Go):
  - `type SlackAppSetup struct { TeamID, TeamName, AppID, ClientID string; LinkWritten bool; InstallRequestedAt string; CreatedAt, UpdatedAt string }`
  - `func (d *DB) InsertSlackAppSetup(s SlackAppSetup) error` (refuses an existing team: `ErrSetupExists`), `GetSlackAppSetup(team string) (SlackAppSetup, error)`, `ListSlackAppSetups() ([]SlackAppSetup, error)`, `SetSlackAppSetupLinkWritten(team string) error`, `SetSlackAppSetupInstallRequested(team string, at time.Time) error` (zero clears).
  - `connectSlackAccount(ctx, cfg, database, id, grant, isNewRow, clientID string, warnOut)`.

Migration (plain adds, no rebuild):

```sql
-- +goose Up
ALTER TABLE slack_accounts ADD COLUMN client_id TEXT NOT NULL DEFAULT '';           -- '' = connected before this migration (backfilled, A17)
ALTER TABLE slack_accounts ADD COLUMN app_id TEXT NOT NULL DEFAULT '';              -- from oauth.v2.access; '' = unknown
ALTER TABLE slack_accounts ADD COLUMN refresh_token_expires_at TEXT NOT NULL DEFAULT ''; -- '' = no rotation
CREATE TABLE slack_app_setups (
  team_id TEXT PRIMARY KEY,
  team_name TEXT NOT NULL DEFAULT '',
  app_id TEXT NOT NULL,
  client_id TEXT NOT NULL,
  link_written INTEGER NOT NULL DEFAULT 0,
  install_requested_at TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
```

- [ ] **Step 1: Failing tests:** `TestSlackAppSetups_InsertGetList`, `TestSlackAppSetups_SecondInsertRefused`, `TestSlackAppSetups_LinkWrittenAndInstallRequested`, `TestSlackAccounts_ClientIDRoundTrip`, `TestBackfillSlackClientIDs_OnlyEmptyRows` (a set id is never overwritten; idempotent), `TestTokenStore_RefreshFieldsRoundTrip` (and an old file without them still loads), `cmd::TestConnectSlackAccount_WritesClientID`.
- [ ] **Step 2: Run, expect FAIL:** `go test ./internal/db ./internal/slack -run 'SlackAppSetups|ClientID|RefreshFields'`, `go test ./cmd -run TestConnectSlackAccount_WritesClientID`.
- [ ] **Step 3: Implement** the migration, mirror, accessors, token fields, the `connectSlackAccount` parameter; regenerate goldens.
- [ ] **Step 4: Run, expect PASS** plus `go test ./internal/db -run 'TestAllTablesExist|TestSchemaGolden|TestDesktopTestSchema'`, `go test ./cmd -run 'Slack'`; `make lint-diff`.
- [ ] **Step 5: Commit** `feat(slack): client id, refresh expiry and the setup record (#1709)`.

### Task 3: Shared-app detection and `slack accounts --json`

**Depends on:** Task 2

**Files:**
- Modify: `internal/auth/oauth.go` (`var RetiredSharedClientID string`, ldflag set only by the public profile; `func BuiltinApp() (OAuthConfig, bool)`)
- Create: `internal/slackmode/sharedapp.go`, `internal/slackmode/sharedapp_test.go`
- Modify: `cmd/slack.go` (`slack accounts --json`), `cmd/auth.go` (`resolveOAuthConfig` via `auth.BuiltinApp`)
- Modify: `Makefile` `LDFLAGS` (`-X watchtower/internal/auth.RetiredSharedClientID=$(RETIRED_SLACK_CLIENT_ID)`, exported like the others)
- Test: `cmd/slack_accounts_json_test.go`

**Interfaces:**
- Produces:
  - `func SharedApp(a db.SlackAccount, retiredID string) bool` — one rule, no flavor input (ask #1425): `retiredID != "" && a.ClientID == retiredID`. Every other id (setup's app, MDM/link id, the corp build's baked company app) is a company app.
  - `func BackfillSource() string` — the baked/env client id if any, else `RetiredSharedClientID`, else `""` (no backfill). Callers: `slack accounts`, the daemon's start, `writeConnectedAccount` (A17).
  - `slack accounts --json` → `{"builtin_app": bool, "accounts": [{"id", "team_id", "team_name", "label", "status", "enabled", "client_id", "shared_app", "relogin": "builtin"|"connect"|"move"}]}`; `relogin`, first match wins (review #1439): (1) `client_id == RetiredSharedClientID` (non-empty) → `builtin` while the build still bakes that id (before Task 18), else `move` — never `connect`, because the retired app has no loopback redirect and PKCE would fail; (2) equal to the builtin id, or `client_id == ""` while the build has a built-in app → `builtin` (an empty id with no built-in app is a never-backfilled corp row: `connect`, A17; Task 3 review); (3) otherwise `connect`. Removed rows are listed (the Desktop filters), `shared_app` is false for them.
- [ ] **Step 1: Failing tests:** `TestSlackAccountSharedApp_RetiredIDOnly` (retired id → true; a setup app, an MDM id and a corp-baked id → false; `retiredID == ""` → nothing shared; the result does not depend on `cmd.BuildFlavor`), `TestBackfillSlackClientIDs_FromBakedID` (public before Task 18: empty rows get the shared id → shared; corp: empty rows get the corp id → not shared), `TestBackfillSlackClientIDs_AfterRetirement` (nothing baked: empty rows get `RetiredSharedClientID` when set, stay empty otherwise), `TestSlackAccountsJSON_Shape` (golden keys), `TestSlackAccountsJSON_BuiltinApp` (env id+secret → true; none → false), `TestSlackAccountsJSON_Relogin` (table: shared id while baked → `builtin`; shared id after nothing is baked → `move`; a company app id → `connect`; corp-baked id while baked → `builtin`, after → `connect`).
- [ ] **Step 2: Run, expect FAIL:** `go test ./internal/slackmode ./cmd -run 'SharedApp|SlackAccountsJSON'`.
- [ ] **Step 3: Implement.** No flavor check anywhere on this path.
- [ ] **Step 3a:** the daemon's start calls the backfill once (`cmd/daemon*.go` start path; a failure is logged and retried at the next start).
- [ ] **Step 4: Run, expect PASS;** `make lint-diff`.
- [ ] **Step 5: Commit** `feat(slack): shared-app flag by client id in slack accounts --json (#1709)`.

### Task 4: Release guard `retired-slack-id-check`

**Depends on:** none

**Files:**
- Modify: `scripts/build-app.sh` (block `# BEGIN retired-slack-id-check` … `# END retired-slack-id-check` beside `bridge-profile-check`; the `go build -ldflags` line gains `-X watchtower/internal/auth.RetiredSharedClientID=${RETIRED_SLACK_CLIENT_ID}`)
- Create: `scripts/tests/test-build-app-retired-slack-id.sh` (extracts the block verbatim like `test-build-app-bridge.sh`)
- Modify: `Makefile` `test-scripts` (runs the new test)

- [ ] **Step 1: Failing test script** asserting: a public release (flavor `""`/`dev`, not `--dev`, `NOTARIZE_PROFILE` set) + empty `RETIRED_SLACK_CLIENT_ID` → exit 1 with "ERROR: a public release must set RETIRED_SLACK_CLIENT_ID (recognises accounts on the retired shared Slack app)"; public release + set → passes; corp release (its baked app is a company app, ask #1425) → passes without it; `--dev` → passes; non-release (no `NOTARIZE_PROFILE`) → passes. The flavor test lives only in this build-script block, never in app code.
- [ ] **Step 2: Run, expect FAIL:** `bash scripts/tests/test-build-app-retired-slack-id.sh`.
- [ ] **Step 3: Implement** the block before anything is built.
- [ ] **Step 4: Run, expect PASS:** the script and `make test-scripts`.
- [ ] **Step 5: Commit** `build: a public release must recognise the retired shared Slack app (#1709)`.

### Task 5: MDM key `SlackApps`

**Depends on:** none

**Files:**
- Modify: `internal/policy/policy.go` (`KeySlackApps`, `Keyset.SlackApps []SlackApp`, `type SlackApp struct { TeamID string \`json:"team_id"\`; ClientID string \`json:"client_id"\` }`, normalizer for an array of dictionaries, `func (p Policy) SlackApps() []SlackApp`)
- Modify: `internal/policy/testdata/policy_cases.json` (new cases), `internal/policy/policy_test.go`, `internal/policy/collision_test.go` (the key never collides with app defaults)
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Models/ManagedPolicy.swift` (twin), `WatchtowerDesktop/Tests/Core/ManagedPolicyTests.swift`
- Modify: `docs/examples/watchtower-policy.mobileconfig` (an example entry with placeholders), `docs/inventory/policy.md` (POLICY-01/02 list the key)

Rules: absent key → nil (no rows). Wrong type (not an array) → `[]` + `wrong_type`. An entry that is not a dictionary, lacks a field, or fails the id patterns of Global Constraints → dropped + `invalid_entry`. Duplicate `team_id` → the first kept + `invalid_entry`. Unknown dictionary keys are ignored.

- [ ] **Step 1: Fixture cases:** `slack_apps_valid`, `slack_apps_wrong_type`, `slack_apps_bad_entries` (string entry, missing client, bad team pattern), `slack_apps_duplicate_team`. Failing tests: `TestPolicy02_SharedFixture` (existing, now with the cases), `TestPolicy01_WrongTypesFailClosed` (+ `SlackApps`), `ManagedPolicyTests` (fixture).
- [ ] **Step 2: Run, expect FAIL:** `go test ./internal/policy`; `make test-swift FILTER=ManagedPolicyTests`.
- [ ] **Step 3: Implement** both twins; `policy show --json` prints `keys.SlackApps`.
- [ ] **Step 4: Run, expect PASS;** `make lint-diff`, `make lint-swift`.
- [ ] **Step 5: Commit** `feat(policy): SlackApps managed key (#1709)`.

### Task 6: PKCE loopback flow core (`internal/slackconnect`)

**Depends on:** none (the redirect form and the exchange form are finalised in Task 16 — Depends on: Task 1 (spike) for those two constants only)

**Files:**
- Create: `internal/slackconnect/parse.go`, `flow.go`, `server.go`, `exchange.go`, `ports_test.go`, `parse_test.go`, `flow_test.go`, `server_test.go`

**Interfaces:**
- Produces:
  - `const Port = 18551`; `var RedirectURL = "http://127.0.0.1:18551/callback"` (Task 16 may switch to https).
  - `type Target struct { TeamID, ClientID string; AccountID int64 /*0 = new*/ }`; `func ParseConnectInput(s string) (Target, error)` — the full link (scheme, host `127.0.0.1:18551`, path `/slack/connect`, both params) or the code; anything else `ErrNotConnectInput`.
  - `type Registry` — one flow at a time: `Begin(t Target, needsConfirm bool) (FlowID, error)` (`ErrFlowRunning`), `Confirm(id) (authorizeURL string, err)`, `Cancel(id)`, `Callback(state, code, slackErr string) (Result, error)`; each flow holds its `PKCEPair` (reuse `auth.NewPKCEPair`), state, the start time (`Clock` injected, for the "waiting since" line); no deadline (A22).
  - `func AuthorizeURL(t Target, pkce auth.PKCEPair, state string) string` — `user_scope`, `redirect_uri`, `code_challenge`, `code_challenge_method=S256`, `client_id`, `state`, and `team=<team id>` (Slack's workspace hint).
  - `type Exchanger func(ctx, clientID, code, verifier, redirectURI string) (Grant, error)` — real one posts `oauth.v2.access` with no secret; `Grant{AccessToken, RefreshToken, ExpiresIn, RefreshExpiresIn, ClientID, AppID, TeamID, TeamName, UserID, Scope}`.
  - `func Handler(reg *Registry, events chan<- Event, host string) http.Handler` — `GET /slack/connect` → parse; begin with confirm; event `link{flow, team, client}`; answers 200 "Switch to Watchtower to confirm" (oauthpage style). `GET /callback` → `reg.Callback`; no flow → the "start again" page (`oauthpage.Stale()`), nothing else. Any other path, method or `Host` → 404/405/421 with no body detail.
- [ ] **Step 1: Failing tests:**
  - `TestParseConnectInput` (table: link, code, whitespace, wrong host, wrong path, missing param, bad patterns, `javascript:` and `file:` URLs).
  - `TestOAuthPortRanges_Disjoint` (the ranges of Global Constraints, read from the packages' constants where exported, else listed with a comment naming the file; 18551 in none; Linear/Outlook overlap listed as the known exception).
  - `TestRegistry_OneFlowAtATime`, `TestRegistry_ConfirmRequiredForLink` (a link flow cannot reach `AuthorizeURL` without `Confirm`), `TestRegistry_PasteSkipsConfirm`, `TestRegistry_FlowWaitsUntilCancel` (synctest: a confirmed flow is still live after 24 h of bubble time; `Cancel` ends it; a second `Begin` is `ErrFlowRunning` meanwhile), `TestRegistry_CallbackStateMismatchIgnored` (does not end the flow), `TestRegistry_DeniedCallback` (`error=access_denied` → `denied`), `TestRegistry_TeamMismatch` (exchange returns another team → `team_mismatch`, no grant handed out).
  - `TestSlackConnectListener_RequiresConfirm` (in-process server on port 0: GET `/slack/connect` → 200 page, one `link` event, no outbound exchange call, no browser open).
  - `TestSlackConnectListener_CallbackWithoutFlow` (fresh registry: `/callback?state=x&code=y` → the start-again page; the exchanger is never called).
  - `TestSlackConnectListener_RejectsOtherHostsMethodsPaths`.
  - `TestExchange_NoSecretInForm` (fake HTTP server: the form has `client_id`, `code`, `code_verifier`, `redirect_uri`, no `client_secret`).
- [ ] **Step 2: Run, expect FAIL:** `go test ./internal/slackconnect`.
- [ ] **Step 3: Implement.** No sleeps; the deadline uses the injected clock.
- [ ] **Step 4: Run, expect PASS;** `make lint-diff`.
- [ ] **Step 5: Commit** `feat(slack): PKCE loopback connect flow core (#1709)`.

### Task 7: `slack connect`, `slack connect serve` and the account write

**Depends on:** Task 2, Task 6 (and Task 3 for `relogin`)

**Files:**
- Create: `cmd/slack_connect.go`, `cmd/slack_connect_test.go`, `cmd/slack_connect_serve_test.go`
- Modify: `cmd/slack.go` (`slack login --account N` for a `relogin=connect` account runs the one-shot PKCE flow on that account's client id), `cmd/accounts.go` (`applySourceGuards` covers the new verbs)

**Interfaces:**
- `watchtower slack connect (--team T --client C | --code CODE) [--account N] [--no-open] [--app-return] [--json]` — one-shot: binds 18551 (busy → exit 2, "port 18551 is busy (is Watchtower open? connect from Connections → Slack)"), runs the flow without confirm, writes the account, prints the result.
- `watchtower slack connect serve` — the Desktop's child. Stdout JSON lines (one object per line, `event` field):
  - `{"event":"listening","port":18551}` / `{"event":"port_busy","port":18551}` (then exit 3)
  - `{"event":"link","flow":"<id>","team_id":"…","client_id":"…"}` (needs confirm)
  - `{"event":"browser","flow":"<id>"}` (authorize URL opened)
  - `{"event":"connected","flow":"<id>","account_id":N,"team_id":"…","team_name":"…","rebound_from":"<old client id or ''>"}`
  - `{"event":"failed","flow":"<id>","reason":"team_mismatch|other_user|denied|cancelled|exchange|policy|purge_running|other","message":"…"}`
  - `{"event":"busy","flow":"<id of the running flow>"}` (a second start refused)
  - Stdin JSON lines: `{"cmd":"start","team_id","client_id","account_id"}` (skip confirm: paste, MDM, Reconnect, setup), `{"cmd":"confirm","flow"}`, `{"cmd":"cancel","flow"}`. Stdin EOF → close the listener and exit 0.
- `func writeConnectedAccount(ctx, cfg, database, t slackconnect.Target, g slackconnect.Grant) (accountID int64, reboundFrom string, err error)` — the one write path for every PKCE connect (ask #1425, A6):
  - Target row: `t.AccountID` when set; else the team's live row (`refuseDuplicateSlackTeam` keeps it single); else a new row.
  - An existing row: the home-team check (`checkSlackLoginTeam`) and A18's same-user check run **before** any write.
  - Under `TokenStore.Lock`: (1) save the token file atomically (temp + rename) with the new access/refresh tokens, `ClientID`, `AppID`; (2) `SetSlackAccountApp(id, g.ClientID, g.AppID)`, `SetSlackRefreshExpiry`, auth state `ok`. A failure in (1) leaves the old file, so the old token keeps syncing; a crash between (1) and (2) is repaired by `LoadFresh` (Task 8), which copies the file's client and app id onto the row. Data, watermarks and the account id are never touched; nothing is soft-removed (SLACK-01 untouched).
  - The old token is dropped, not revoked (A21).
  - Calls `SetSlackAppSetupInstallRequested(team, zero)` when a setup record exists for the team (the install happened).
- [ ] **Step 1: Failing tests** (`synctest` + the in-process `serve` with `io.Pipe` stdin/stdout and an httptest Slack; the exchanger and the browser opener are fakes):
  - `TestSlackConnectServe_LinkConfirmConnected` (link → `link` event → `confirm` → `browser` → callback → `connected`; row `ok`, `client_id` set, token file has the refresh token).
  - `TestSlackConnectServe_StartSkipsConfirm`, `TestSlackConnectServe_SecondStartBusy`, `TestSlackConnectServe_CancelStoresNothing`.
  - `TestSlackConnectServe_StdinEOFExits` (listener closed, the port is free afterwards).
  - `TestSlackConnectListener_PortBusy` (a pre-bound port → `port_busy`, exit 3) and the one-shot `TestSlackConnect_PortBusyMessage`.
  - `TestSlackLinkConnect_TeamMismatch` (nothing stored; a new row rolled back via `rollbackSlackAccount`).
  - `TestSlackLinkConnect_ReconsentSameClient` (no new row).
  - `TestSlackLinkConnect_RebindKeepsHistory` (shared-app row 1 with messages, digests and `search_last_date`; connect same team, new client → still one row, id 1, `client_id` new, `shared_app` false, every table's row count unchanged, watermark unchanged).
  - `TestSlackLinkConnect_RebindExchangeFails` / `_RebindTokenSaveFails` (the old token file byte-identical, row unchanged, the old token still used by the next sync).
  - `TestSlackLinkConnect_RebindRestartMidway` (token saved, process "dies" before the row update: a new process's `LoadFresh` repairs `client_id`/`app_id`; `slack accounts --json` then says `shared_app: false`).
  - `TestSlackLinkConnect_RebindOtherUserRefused` (A18; nothing written).
  - `TestSlackLinkConnect_CorpBakedRowRebinds` (a row on a corp-baked id connected through the same app's link → same row, still Full).
  - `TestSlackLinkConnect_PolicyBlocksSlack` (`policytest.Set` without `slack` → `failed/policy`, no browser).
  - `TestSlackLogin_WorkspaceAppAccountUsesPKCE` (`slack login --account N` with `client_id` ≠ builtin → one-shot flow, no secret needed).
  - `TestPolicyLogin_EverySourceCommandIsGuarded` (existing) passes with the new verbs.
- [ ] **Step 2: Run, expect FAIL:** `go test ./cmd -run 'SlackConnect|SlackLinkConnect|SlackLogin_Workspace|PolicyLogin'`.
- [ ] **Step 3: Implement.** The serve loop is a function over `io.Reader`/`io.Writer` and a `net.Listener`, so tests never spawn a process.
- [ ] **Step 4: Run, expect PASS;** `go test ./cmd -run 'Slack|Policy'`, `make lint-diff`.
- [ ] **Step 5: Commit** `feat(slack): connect by link, code or MDM through the loopback listener (#1709)`.

### Task 8: Token refresh under a per-account flock

**Depends on:** Task 2. The thresholds and error codes are finalised in Task 16 — Depends on: Task 1 (spike) for Step 3's constants only.

**Files:**
- Create: `internal/slackauth/fresh.go`, `internal/slackauth/fresh_test.go`
- Modify — every token reader goes through `LoadFresh`: `cmd/sync.go` (`wireSlackSyncers`), `cmd/actions_registry.go`, `cmd/reaction_commands.go`, `cmd/slack_backfill.go`, `internal/repl/commands.go`.
- Modify — every token-file writer takes `TokenStore.Lock` (Task 2; the `saveLinearTokenLocked` pattern, `cmd/linear.go`), the complete list:
  - `cmd/slack.go` `connectSlackAccount` (save) and `removeSlackAccount` (delete);
  - `cmd/slack_legacy.go` `ensureLegacySlackAccount` (the legacy config-token migration's save) — today outside any lock (review #1426);
  - `cmd/slack_connect.go` `writeConnectedAccount` (save, re-bind);
  - `internal/slackauth` `LoadFresh` (refresh save, row repair);
  - `internal/purge/run.go` (delete).
  A test lists them: `TestSlackTokenWriters_AllLocked` greps `cmd/` and `internal/` for `NewTokenStore(...).Save`/`.Delete` on the Slack store and fails on a call site outside this list.

**Interfaces:**
- `func saveSlackTokenLocked(ctx, store *watchtowerslack.TokenStore, tok *watchtowerslack.Token) error` (cmd; one-minute lock wait like the Linear helper) and the same for delete.
- `func LoadFresh(ctx context.Context, workspaceDir string, database *db.DB, accountID int64, refresh Refresher, now func() time.Time) (*slack.Token, error)` — a token without `RefreshToken` is returned as is (no rotation: the retired shared app, a company app without rotation, old rows). With one, it refreshes when **either** `ExpiresAt - now < refreshAhead` (1 h) **or** `RefreshExpiresAt - now < refreshTokenAhead` (7 days, parent spec §5.5; review #1426) — so a token the daemon uses rarely never lets its refresh token lapse. Refresh: take the lock, **re-read the file**, check again, refresh (`Refresher(ctx, clientID, refreshToken)`), save atomically, update `refresh_token_expires_at`, unlock. Under the same lock it repairs a row whose `client_id`/`app_id` differ from the file (Task 7's crash window) — **only with non-empty values from the file**: token files written before this plan carry no `client_id`/`app_id`, and an empty value never overwrites the row (otherwise it would blank the backfilled client id, flip the banner, and the next backfill would restore it, forever; review #1439). `invalid_refresh_token`/`token_revoked` → `SetSlackAccountAuthState(id, "error", "Sign in again: the Slack sign-in expired")` (the existing Re-login state) and `ErrReloginNeeded`.
- `var refreshAhead = time.Hour`, `var refreshTokenAhead = 7 * 24 * time.Hour` (Task 16 adjusts from Q9).
- The daemon calls `LoadFresh` for every enabled account at the start of each cycle, also for accounts whose Slack run the adaptive cadence skips, so the 7-day check runs at least once a cycle.
- [ ] **Step 1: Failing tests:** `TestSlackRefresh_NoRotationUntouched`, `TestSlackRefresh_RefreshesWhenDue` (fake clock), `TestSlackRefresh_RefreshTokenNearExpiry` (access token valid for 10 h, refresh token 6 days left → one refresh; 8 days left → none), `TestSlackRefresh_SkippedCadenceStillRefreshes` (daemon cycle with the account's Slack run not due → `LoadFresh` still called), `TestSlackRefresh_LockRace` (two goroutines due at once; the fake refresher counts one call and refuses the old refresh token on a second use; both return the new access token), `TestSlackRefresh_Expired` (refresher → `invalid_refresh_token` → row `error` with the Re-login text), `TestSlackRefresh_NoSecretInForm` (the real refresher's form), `TestSlackRefresh_CrashBeforeSaveKeepsOldFile` (refresher ok, save fails → the old file intact, error returned), `TestSlackRefresh_RepairsRowFromFile`, `TestSlackRefresh_LegacyTokenFileNeverBlanksRow` (a token file without `client_id`/`app_id` next to a row with a backfilled client id: after `LoadFresh` the row keeps its id and `shared_app` is unchanged over two calls), `TestEnsureLegacySlackAccount_SavesUnderLock` (a held lock makes the migration wait; released → saved), `TestSlackTokenWriters_AllLocked`.
- [ ] **Step 2: Run, expect FAIL:** `go test ./internal/slackauth`.
- [ ] **Step 3: Implement** and switch the readers.
- [ ] **Step 4: Run, expect PASS:** `go test ./internal/slackauth ./internal/purge ./internal/repl`, `go test ./cmd -run 'Slack|Sync|Reaction|Action|Legacy'`, `make lint-diff`.
- [ ] **Step 5: Commit** `feat(slack): refresh rotated tokens under a per-account lock (#1709)`.

### Task 9: Workspace-app setup (`internal/slackapp`, `slack app create|adopt|link|status`)

**Depends on:** Task 2; the policy-hygiene plan's Task 4 (`internal/slackmanifest`). The real Slack client's error mapping, team lookup and adopt's merge details are finalised in Task 16 — Depends on: Task 1 (spike, Q1, Q2, Q11–Q14) for those only.

**Files:**
- Create: `internal/slackapp/manifest.go`, `manifest_test.go`, `testdata/manifest.golden.json`, `api.go` (interface + real client), `setup.go`, `setup_test.go`
- Create: `cmd/slack_app.go`, `cmd/slack_app_test.go`
- Modify: `cmd/accounts.go` (guards)

**Interfaces:**
- `type API interface { Team(ctx, cfgToken) (teamID, teamName string, err error); Create(ctx, cfgToken string, m Manifest) (appID, clientID string, err error); Update(ctx, cfgToken, appID string, m Manifest) error; Export(ctx, cfgToken, appID string) (Manifest, error) }` — the real client decodes the create response into a struct **without** a secret field (the secret is never decoded).
- `func MergeManifest(theirs Manifest, teamID, clientID string) Manifest` (A20) and `func BuildManifest(teamID, clientID string) Manifest` — built on `internal/slackmanifest` (the policy-hygiene plan's Task 4; Depends on it): user scopes = `slackmanifest.UserScopes()`, `description` = `slackmanifest.ShortDescription`, `long_description` = `slackmanifest.Description(connectBlock)` where `connectBlock` is the screens §4.1 text (link and code filled; empty client id → no link lines, used for the create call); name "Watchtower", `redirect_urls: [slackconnect.RedirectURL]`, `token_rotation_enabled: true`, no bot user, no features, no event subscriptions.
- `func Create(ctx, d *db.DB, api API, cfgToken string, emit func(Step)) (Result, error)` and `Link(...)`: steps `check_token` → `create_app` → `write_link`, each emitted as running then done/failed. Result kinds: `ok`, `bad_token`, `not_allowed`, `network`, `refused` (with Slack's code), `link_failed` (app created, link not written), `exists` (a record for this team: no create; returns the record), `busy`.
- CLI (token on stdin, one line; `--json` prints one JSON line per step `{"step":"create_app","state":"running|done|failed"}` and a final `{"result":"…","team_id","team_name","app_id","client_id","link_written",…}`):
  - `slack app create --json` — holds `slack_app_setup.lock`; Team lookup; an existing record → `exists`; else create, insert the record **before** anything else can fail, then update with the link.
  - `slack app create --json` on a team that already has a live account on a company app (any client id but the retired shared one) answers `existing_app` with that client id and its `app_id` (or `app_id: ""`) and creates nothing — the sheet then offers adopt (ask #1425: no second Watchtower app).
  - `slack app adopt --json [--app-id A]` — holds the setup lock; Team lookup; the client id from the team's live company-app row; the app id from that row's `app_id`, else `--app-id`, else result `need_app_id` (A19); `Export` → `MergeManifest` (A20) → `Update`; inserts the record (`app_id`, `client_id`, `link_written=1`) only after the update succeeds. Results: `ok`, `bad_token`, `not_collaborator` (Q11), `app_not_found`, `need_app_id`, `network`, `refused`, `busy`.
  - `slack app link --json [--team T]` — the record's app; `Export` → merge only `long_description` → `Update`; `link_written`.
  - `slack app status --json` — every record with derived `connected` (an `ok` row with that client id), `link_written`, `install_requested` and a `stage` (`install` | `approval` | `link_missing` | `done`).
- [ ] **Step 1: Scopes and descriptions (A11):** no list of our own — `slackmanifest.UserScopes()` and `slackmanifest.Description()`; `TestManifest_Scopes` asserts `BuildManifest(...).user scopes == slackmanifest.UserScopes()` (includes `im:write` and `chat:write`).
- [ ] **Step 2: Failing tests** (fake `API`):
  - `TestAdopt_MergeKeepsTheirFields` (their redirect URLs, bot, extra scopes and rotation setting kept; our redirect URL and missing scopes added; `long_description` replaced), `TestAdopt_NoSecondApp` (`create` on a team with a company-app row → `existing_app`, `Create` never called), `TestAdopt_NeedAppID` (row without `app_id`, no flag → `need_app_id`, nothing sent), `TestAdopt_NotCollaborator` (`Export` → the Q11 code → `not_collaborator`, no record), `TestAdopt_UpdateFailsNoRecord`, `TestAdopt_SecretNeverStored` (an export carrying credentials is never stored).
  - `TestManifest_Golden`, `TestManifest_Scopes` (equal to `slackmanifest.UserScopes()`), `TestManifest_NoBotNoSecretFields`.
  - `TestAppSetup_BadConfigToken` (`Team` → `invalid_auth` → `bad_token`; `Create` never called).
  - `TestAppSetup_WritesLinkToDescription` (the `Update` manifest's `long_description` holds the link and the code of screens §4.1).
  - `TestAppSetup_LinkUpdateFails` (`Update` fails → `link_failed`, record `link_written=0`; `slack app link` with a new token → written).
  - `TestAppSetup_SecretNeverStored` (the fake HTTP Slack returns a `client_secret`; after create: grep the workspace dir, a dump of every DB table, captured stdout/stderr — the secret appears nowhere).
  - `TestAppSetup_ResumeAfterCreate` (record exists, not connected → `create` returns `exists`, `Create` call count stays 0; `status` says `install`).
  - `TestAppSetup_TokenNeverInArgv` (the cobra command has no token flag; a token given as an argument is refused).
  - `TestAppSetup_ConcurrentRunBusy` (lock held → `busy`).
  - `TestAppSetup_KilledAfterCreate` (the create returns, the process "dies" before `Update`: simulated by cancelling ctx after `Create` → record present, `link_written=0`; next `status` → `install` with `link_missing` after connect).
- [ ] **Step 3: Run, expect FAIL:** `go test ./internal/slackapp ./cmd -run 'AppSetup|Manifest'`.
- [ ] **Step 4: Implement.**
- [ ] **Step 5: Run, expect PASS;** `make lint-diff`.
- [ ] **Step 6: Commit** `feat(slack): one-paste workspace app setup with a resumable record (#1709)`.

### Task 10: Swift process plumbing — line-stream CLI and the listener host

**Depends on:** none (the JSON-lines contracts of Tasks 7 and 9 are fixed in this plan)

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/CLILineStream.swift` (`protocol CLILineStreaming { func lines(args: [String], stdin: Data?) -> AsyncThrowingStream<String, Error> }`, real impl on `Process` with its own process group, killed and waited on cancel; `FakeCLILineStream` in Tests/Support)
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Slack/SlackConnectListenerHost.swift` (`@Observable`: `state: idle | listening | portBusy | stopped`, `events: AsyncStream<SlackConnectEvent>`, `send(_ cmd:)`, `ensureRunning()`), `SlackConnectEvent.swift` (Codable twins of Task 7's events)
- Test: `WatchtowerDesktop/Tests/Core/CLILineStreamTests.swift`, `SlackConnectListenerHostTests.swift`
- Reference: the long-lived bidirectional child pattern in `Services/Chat/ChatSessionClient.swift`

- [ ] **Step 1: Failing tests:** `testDecodesEveryEvent` (a fixture `internal/slackconnect/testdata/serve_events.jsonl` written by Task 7's test and read by Swift via `#filePath`, like `ManagedPolicyTests`), `testPortBusyState`, `testUnexpectedExitRestartsOnce` (fake: exits twice → one restart, then `stopped` until `ensureRunning()`), `testEnsureRunningRebindsAfterPortBusy`, `testCancelKillsProcessGroup` (real `/bin/sh -c 'sleep 1000 & wait'` child, the group gone after cancel — reaped in teardown), `testStdinEOFOnStop`.
- [ ] **Step 2: Run, expect FAIL:** `make test-swift FILTER='CLILineStreamTests|SlackConnectListenerHostTests'`.
- [ ] **Step 3: Implement.** `AppState` starts the host after the database opens (not under XCTest) and stops it on terminate.
- [ ] **Step 4: Run, expect PASS;** `make lint-swift`.
- [ ] **Step 5: Commit** `feat(desktop): line-stream CLI runner and the Slack connect listener host (#1709)`.

### Task 11: S1 — the mode pane (`SlackModePresentation`, Live block)

**Depends on:** none (plan A shipped). Takes the shared-app flag as an input that is `false` until Task 15 wires it.

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Slack/SlackModePresentation.swift`, `WatchtowerDesktop/Tests/Core/SlackModePresentationTests.swift`
- Modify: `SlackLiveStatusCenter.swift` (`hasRead`; `lastError` becomes `SlackLiveError { provider, message, kind: probe | read }`), `SlackLiveStatusCenterTests.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Settings/SlackConnectionDetail.swift` (off `Form`, onto `ScrollView` + `SettingsSection`s; order of screens §1; old sections ported as they are)
- Modify: `WatchtowerDesktop/Tests/DesignShots/DesignShotsTests.swift` (the `slack-fl-pane-*` shots of §1 rendered from the real view)

- [ ] **Step 1: Failing tests:** every string of screens §1.1 (chip, summary, tone per display), §1.2 (each `status`/`error_class` row, the age wording at 59 s / 59 min / 47 h / 48 h with an injected `now`), the five block states and their actions (`testBusyKeepsRows`, `testReadFailedOffersTryAgainHidesCheckAgain`, `testProbeFailedKeepsCheckAgain`), `SlackLiveStatusCenterTests.testReadFailureKeepsRows`, `testCheckAgainWhileRunningIsIgnored`, `testHasRead`.
- [ ] **Step 2: Run, expect FAIL:** `make test-swift FILTER='SlackModePresentationTests|SlackLiveStatusCenterTests'`.
- [ ] **Step 3: Implement** the presentation and the pane (design kit, `Tone` only).
- [ ] **Step 4: Run, expect PASS;** `make test-swift FILTER=DesignShotsTests`, `make lint-swift`; look at `make desktop-shots DESKTOP_SHOTS=<dir>` output for the pane shots.
- [ ] **Step 5: Commit** `feat(desktop): Slack mode pane with the Live block (#1709)`.

### Task 12: S2 — `needsFullSlack`, the sidebar, Knowledge note, phone row

**Depends on:** Task 11 (only for `SlackModePresentation.knowledgeNote`)

**Files:**
- Modify: `WatchtowerCore/Models/Readiness.swift` (`ReadinessSource.fullSlack`, `Readiness.needsFullSlack`), `WatchtowerCore/Services/FeatureReadiness.swift` (`ReadinessInputs.slackLiveOnly`, the rule and strings of screens §2.1), `ReadinessCenter` (`DBSnapshot` reads `slack_live_status`; `refresh()` on `SlackLiveStatusCenter.statuses` change), `ConnectionService(readinessSource:)` (`.fullSlack` → Slack)
- Modify: `WatchtowerCore/Services/SidebarVisibility.swift` (`ConnectedSources.slackLive`, `SidebarSource.slackLive`, Catch-Up and Statistics required sources), `AppState.refreshConnectedSources()` trigger
- Modify: the Knowledge search view (the note while Live, `SlackModePresentation.knowledgeNote`)
- Modify (Go): `internal/hub/slices/heartbeat.go` (`DBAccounts` Live-only row)
- Modify (phone): `WatchtowerMobile/Sources/Features/Settings/AccountStatusStyle.swift` (`live`)
- Tests: `FeatureReadinessTests`, `EmptyStateCopyCoverageTests`, `ReadinessCenterTests`, `SidebarVisibilityTests`, `SlackModePresentationTests.testKnowledgeNoteOnlyInLive`, `internal/hub/slices::TestDBAccounts_LiveOnlySlackRow`, `WatchtowerMobile/Tests/AccountStatusStyleTests` (`testLiveOnly`, `testUnknownStatusShowsRaw`)

- [ ] **Step 1: Failing tests** named in screens §2 and §6: `testNeedsFullSlackForSlackFeatures`, `testNeedsFullSlackForAnySourceOnlyWhenNothingElse`, `testSharedAppAccountIsNotNeedsFullSlack`, `testOffBeatsNeedsFullSlack`, `testOffModeKeepsConnectSlack`, `testLiveStatusChangeReevaluates`, `testLiveOnlyShowsCatchUpAndStatistics`, `testLiveDoesNotCountAsMessages`, `testRefreshOnLiveStatusChange`, `TestDBAccounts_LiveOnlySlackRow` (+ a listed Slack account suppresses it), `testLiveOnly`.
- [ ] **Step 2: Run, expect FAIL:** `make test-swift FILTER='FeatureReadinessTests|EmptyStateCopyCoverageTests|ReadinessCenterTests|SidebarVisibilityTests|SlackModePresentationTests'`, `go test ./internal/hub/slices -run LiveOnly`, `make mobile-test MOBILE_FILTER=AccountStatusStyleTests`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS;** the `slack-fl-needs-full-*` shots from the real views; `make lint-swift`, `make lint-diff`.
- [ ] **Step 5: Commit** `feat(desktop): needs-your-workspace's-app state for Live-only Slack (#1709)`.

### Task 13: S3 — Set up for my company (`SlackAppSetupModel`, sheet, record row)

**Depends on:** Task 9 (CLI contract), Task 10, Task 11; the policy-hygiene plan's Task 10 (`SlackDisclosureCopy`, `docs/superpowers/plans/2026-11-17-slack-policy-hygiene-plan.md`)

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Slack/SlackAppSetupModel.swift` (`@Observable`, on `AppState.slackAppSetup`), `WatchtowerDesktop/Tests/Core/SlackAppSetupModelTests.swift`
- Create: `WatchtowerDesktop/Sources/Views/Settings/SlackAppSetupSheet.swift`, the record row in `SlackConnectionDetail`

**Interfaces:**
- `func startCreate(token: String)`, `func startAdopt(token: String, appID: String?)`, `func startLink(team: String, token: String)`, `func copyAdminNote() -> String` (A23), `func checkAgain()`, `func reloadRecords()`; state per screens §3.2/§3.3; `records: [SetupRecord]` from `slack app status --json`.
- Order of a create run (A4, Q2-proof): `slack app create --json` (stdin token) → on `ok` or `link_failed`: start the connect flow (`SlackConnectFlowModel.start(team, client, skipConfirm: true)`, Task 14 — until then a protocol the model calls) and mirror it as step 4 → if the link was not written and the token is still held → `slack app link --json` → drop the token. On `exists` → the record row's **Continue setup** path, never a second create. On `existing_app` → the adopt state: "Watchtower's app already exists in <workspace>" / "Update it to the current version: Watchtower adds the connect link to its About page and the sign-in settings it needs. Nothing changes for colleagues already connected." with **Update the app**; `need_app_id` adds a field "App ID" with "Find it on the app's Basic Information page at api.slack.com/apps."; `not_collaborator` → "Your token cannot change this app. Ask one of its collaborators (listed on its Collaborators page) to run this setup." with **Copy a note for your admin**. Adopt success reuses the success state. Strings follow A19/A23 (approved in ask #1438).
- [ ] **Step 1: Failing tests** (`FakeCLILineStream`, fake connect starter): every string of §3.2–§3.4; `testStepMarksFromScriptedCLI`; `testTokenNeverInArgv` (the fake records args and stdin: the token only in stdin); `testTokenDroppedAfterRun`; `testCloseKeepsRunning`; `testRecordOffersContinueNotCreate`; `testLinkFailedOffersAddLink`; `testBadTokenState`, `testNotAllowedState` (with **Copy a note for your admin**), `testAdminNoteText` (workspace name and guide link), `testNetworkState`, `testRefusedState`; `testExistingAppOffersAdoptNotCreate`, `testAdoptNeedsAppID`, `testNotCollaboratorState`, `testAdoptSuccess`; `testBusyShowsAlreadyRunning`; `testApprovalRowOnlyWhenRecordSaysSo`; `SlackAppSetupSheetTests.testShowsDisclosureBeforeTokenField` (the sheet shows `SlackDisclosureCopy.setupTitle`, every `setupLines` entry and the privacy link above the token field; reference shot `slack-ph-setupDisclosure`) — this task owns the wiring.
- [ ] **Step 2: Run, expect FAIL:** `make test-swift FILTER=SlackAppSetupModelTests`.
- [ ] **Step 3: Implement** model, sheet (secure field), record row; the `slack-fl-setup-*` and `slack-fl-pane-setup*`/`-linkMissing` shots from the real views, including the new ones mocked on this branch: `slack-fl-setup-notAllowed` (now with the admin note), `slack-fl-setup-adopt`, `slack-fl-setup-adoptAppId`, `slack-fl-setup-adoptNotCollaborator` (`docs/design/mockups/slack-full-live/`).
- [ ] **Step 4: Run, expect PASS;** `make test-swift FILTER='SlackAppSetupModelTests|DesignShotsTests'`, `make lint-swift`.
- [ ] **Step 5: Commit** `feat(desktop): set up Watchtower's Slack app for a company (#1709)`.

### Task 14: S4 — connect by link, code, MDM; Reconnect routing

**Depends on:** Task 5, Task 7, Task 10, Task 11; the policy-hygiene plan's Task 10 (`SlackDisclosureCopy`)

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/Slack/SlackConnectFlowModel.swift` (on `AppState`, beside the host), `WatchtowerDesktop/Tests/Core/SlackConnectFlowModelTests.swift`
- Create: `WatchtowerDesktop/Sources/Views/Settings/SlackConnectSheet.swift` (confirm / browser / result), the connect section in `SlackConnectionDetail` (MDM rows, field, **Set up for my company**, port-busy line, folded in Full)
- Modify: `SlackAccountsViewModel.relogin` and the legacy Workspace Reconnect — `relogin == "connect"` → the flow (A7, A14); reads `slack accounts --json`
- Modify: `AppState` — a `link` event brings the app forward (`NSApp.activate`), selects Connections → Slack and shows the confirm sheet

- [ ] **Step 1: Failing tests:** every string of screens §4.2–§4.4; `testFreshModelIsIdle`; `testWaitingLineAfterFiveMinutes` (injected clock: none at 4 min, "Waiting for Slack since 5 min" at 5 min, **Cancel** kept); `testLinkStartsAtConfirm`; `testPasteSkipsConfirm`, `testMDMConnectSkipsConfirm`; `testSecondLinkWhileRunningIsRefused` (sends nothing, keeps the sheet); `testPasteRejectsOtherText`; `testMismatchAndDeniedStates`; `testCancelSendsCancel`; `testPortBusyLine`, `testFullFoldsConnectSection`, `testFullOpensFoldWhileIdleAndPortBusy`; `testReloginRoutesWorkspaceAppToFlow`, `testReloginConnectWithoutClientIDOpensConnectSection` (`relogin: "connect"` with an empty `client_id` → no `start` sent; the connect section focused: paste link / MDM rows), `testReloginMoveOpensBannerPathNotFlow` (`relogin: "move"` → no `start` sent; the connect section focused); `testOrganizationRowsFromPolicy` (MDM rows minus teams already connected with that client); `SlackConnectSheetTests.testConfirmShowsDisclosureLine` (the confirm shows `SlackDisclosureCopy.connectLine(workspace:)` and the privacy link; reference shot `slack-ph-connectDisclosure`) — this task owns the wiring.
- [ ] **Step 2: Run, expect FAIL:** `make test-swift FILTER='SlackConnectFlowModelTests|SlackModePresentationTests'`.
- [ ] **Step 3: Implement;** the `slack-fl-connect-*`, `slack-fl-pane-organization`, `-portBusy`, `-pasteInvalid` shots from the real views.
- [ ] **Step 4: Run, expect PASS;** `make lint-swift`.
- [ ] **Step 5: Commit** `feat(desktop): connect a workspace app by link, code or MDM (#1709)`.

### Task 15: S5 — the retired shared app on screen

**Depends on:** Task 3, Task 13, Task 14

**Files:**
- Modify: `SlackModePresentation` (`sharedAppBanner`, the **Shared app** chip override, the account tag and line, `overviewStatusLine`), `SlackAccountsViewModel` (merge `shared_app`, `relogin`, `builtin_app` from `slack accounts --json` by id; a failed CLI read keeps the last flags and shows no banner on first read), `SlackConnectionDetail` (banner on top; **Add Slack Account** only when `builtin_app`, else **Connect another workspace…**, A8)
- Modify: the Connections overview Slack card (status line "Shared app retiring", `needsAttention` false)
- Modify: `OnboardingConnectStepView` (A13: `builtin_app` false → the connect section sheet `SlackOnboardingConnectSheet`; its strings — title "Connect Slack", caption, field, buttons — live in `SlackConnectFlowModel.onboarding*`; states: empty, organization rows (MDM), paste invalid, port busy, then the flow's own browser/success/failed states). Mockups on this branch: `slack-fl-onboarding-empty`, `-organization`, `-pasteInvalid`, `-portBusy` (+ `-empty-narrow`); the real view re-renders the same names.
- Tests: `SlackModePresentationTests.testSharedAppBanner`, `testSharedAppIsNotAttention`, `testSharedAppFollowsFlag`, `testAddAccountFollowsBuiltinApp`; `SlackAccountsViewModelTests.testFlagsReadFailureKeepsLast`; `OnboardingConnectStepTests.testSlackWithoutBuiltinAppOpensConnectSection`; `SlackConnectFlowModelTests.testOnboardingStrings`

- [ ] **Step 1: Failing tests** above.
- [ ] **Step 2: Run, expect FAIL:** `make test-swift FILTER='SlackModePresentationTests|SlackAccountsViewModelTests|OnboardingConnectStep'`.
- [ ] **Step 3: Implement;** shots `slack-fl-pane-sharedApp`, `-sharedApp-narrow`, `-full`, `-fullLive`, `slack-fl-onboarding-*` from the real views.
- [ ] **Step 4: Run, expect PASS;** `make lint-swift`.
- [ ] **Step 5: Commit** `feat(desktop): shared Slack app banner and Connect another workspace (#1709)`.

### Task 16: Apply the spike answers and check end to end

**Depends on:** Task 1 (spike), Task 6, Task 7, Task 8, Task 9

**Files:** only the constants and mappings named in the spike table: `internal/slackconnect` (`RedirectURL`, the exchange form, A9's port rule), `internal/slackauth` (`refreshAhead`, error codes), `internal/slackapp` (manifest fields, `Team` source, error-code map, description text per Q6), `cmd/slack_connect.go` (`install_requested` writer per Q5); their tests updated in the same commit.

- [ ] **Step 1:** For each spike answer that differs from the Phase 1 default, change the constant and the test that pins it (one commit per question). Q3 or Q7 "no" → stop and ask the owner (Task 1 Step 9).
- [ ] **Step 2: End to end on the test workspace** (controller, manual; record the result as a statement in the PR): the Desktop built with `make app-dev`, a fresh config token → **Set up for my company** → app created, About page shows the link, admin connected; as the second test user: About → link → confirm → connected; Reconnect; quit the app mid-browser step and click the callback → "start again"; a paste with the app's listener stopped; refresh after forcing `ExpiresAt` into the past in a copy of the workspace (never the live DB).
- [ ] **Step 3: Run** `go test ./internal/slackconnect ./internal/slackauth ./internal/slackapp ./cmd -run 'Slack|AppSetup'`, `make lint-diff`.
- [ ] **Step 4: Commit** `fix(slack): Full entry follows the live spike (#1709)`.

### Task 17: Guide, feature notes, inventory

**Depends on:** Tasks 2–16

**Files:**
- Modify: `docs/guide/concepts/sources-and-accounts.md` (Full, Live, setup, the link, the code, MDM, the banner; 8 KB cap)
- Modify: `docs/features/slack-multi-account.md` (client id per account, shared-app retirement, `slack accounts --json`, refresh), `docs/features/slack-live.md` (the screens; "Full comes in plan B" → done), `docs/features/connections-tab.md` (the pane), `docs/features/mdm-policy.md` (`SlackApps` row), `docs/features/README.md` summaries
- Modify: `docs/superpowers/specs/2026-11-15-slack-full-live-screens-design.md` and `docs/superpowers/specs/2026-11-14-slack-full-and-live-design.md` — the lines listed under "Spec lines superseded by asks #1414/#1425", each marked with its ask; the screens spec's §4.4 promise "paste works while 18551 is busy" narrowed if the spike (Q4) says Slack is strict about the port (A9); new screens-spec rows for the adopt states, the admin note and the onboarding sheet with their shots
- Create: `docs/features/slack-full.md` (the entry into Full: listener, CLI verbs and JSON lines, setup record, refresh, port, A1–A16 as shipped, v1 limits); add it to `CLAUDE.md`'s Feature Notes list and to `docs/features/README.md`
- Modify: `docs/inventory/slack-accounts.md` (SLACKFULL-01, SLACKFULL-02 once approved; SLACK-01 note about the move), `docs/inventory/policy.md` (`SlackApps`), `docs/inventory/README.md` (module map gains `internal/slackconnect`, `internal/slackapp`, `internal/slackauth`, `cmd/slack_connect.go`, `cmd/slack_app.go`)

- [ ] **Step 1:** Write; `go test ./docs/guide`.
- [ ] **Step 2: Commit** `docs: Slack Full entry, shared-app retirement (#1709)`.

### Task 18: Retire the baked Slack app in every build ("T9")

**Depends on:** Task 15, Task 16, Task 17 merged to main and a release with them out; the owner's go (ask). For the corp profile also: the corp admin has run **Set up for my company** (adopt) on the corp app, so its About page carries the link and PKCE Re-login works without the baked id (Q13).

**Files:**
- Modify: `scripts/build-app.sh` `retired-slack-id-check` (A15: any release refuses a set `WATCHTOWER_OAUTH_CLIENT_SECRET`; a public release also refuses `WATCHTOWER_OAUTH_CLIENT_ID == RETIRED_SLACK_CLIENT_ID`), `scripts/tests/test-build-app-retired-slack-id.sh` (three more cases)
- Owner action (not in the repo): the public and the corp build profiles drop `WATCHTOWER_OAUTH_CLIENT_ID`/`_SECRET` for Slack; only the public profile sets `RETIRED_SLACK_CLIENT_ID` (the shared app's id). Corp rows keep their company-app id (backfilled before this release), stay Full, and re-login through the link or MDM.

- [ ] **Step 1: Failing cases** in the script test; run, FAIL.
- [ ] **Step 2: Implement;** run, PASS; `make test-scripts`.
- [ ] **Step 3: Check** with a `make app` built from the new profile (not a release): `slack accounts --json` → `builtin_app: false`; the pane shows **Connect another workspace…**, no **Add Slack Account**; onboarding's Slack card opens the connect section; a shared-app account still syncs and shows the banner; a corp-app account (fixture) shows no banner and its Re-login runs the connect flow; a **public shared-app account** shows **Move to Full** instead of Reconnect and never starts a PKCE flow on the retired app (`TestSlackAccountsJSON_Relogin` case "shared id after nothing is baked → move" run against this profile's binary, plus `testReloginMoveOpensBannerPathNotFlow`).
- [ ] **Step 4: Commit** `build: no build bakes a Slack app any more (#1709, #1767)`.

---

## Failure modes → tests

| Path | Failure | Behaviour | Test |
|---|---|---|---|
| Setup | config token expired / wrong | stop before any create; bad-token state | `TestAppSetup_BadConfigToken`, `SlackAppSetupModelTests.testBadTokenState` |
| Setup | app created, link write fails | app works; **Add the link to the app** | `TestAppSetup_LinkUpdateFails`, `testLinkFailedOffersAddLink` |
| Setup | secret in the create response | never decoded, stored, logged or printed | `TestAppSetup_SecretNeverStored` |
| Setup | process killed / Mac closed after create | record kept; **Continue setup**; never a second create | `TestAppSetup_ResumeAfterCreate`, `TestAppSetup_KilledAfterCreate`, `testRecordOffersContinueNotCreate` |
| Setup | two runs at once | the second answers busy | `TestAppSetup_ConcurrentRunBusy`, `testBusyShowsAlreadyRunning` |
| Setup | sheet closed mid-run | run continues on `AppState` | `testCloseKeepsRunning` |
| Setup | token in argv or on disk | never | `TestAppSetup_TokenNeverInArgv`, `testTokenNeverInArgv`, `testTokenDroppedAfterRun` |
| Link | a web page opens the loopback URL | confirm; nothing starts without **Connect** | `TestSlackConnectListener_RequiresConfirm`, `testLinkStartsAtConfirm` |
| Link | app quits between redirect and callback | child exits on stdin EOF; a late callback hits nothing or a fresh child → "start again"; nothing stored | `TestSlackConnectServe_StdinEOFExits`, `TestSlackConnectListener_CallbackWithoutFlow`, `testFreshModelIsIdle` |
| Link | flow never completes (approval pending, tab abandoned) | stays pending with "waiting since N min" and **Cancel**; a second start is refused until then (A22) | `TestRegistry_FlowWaitsUntilCancel`, `SlackConnectFlowModelTests.testWaitingLineAfterFiveMinutes` |
| Link | team mismatch / denied | failed, nothing stored, new row rolled back | `TestSlackLinkConnect_TeamMismatch`, `TestRegistry_DeniedCallback`, `testMismatchAndDeniedStates` |
| Link | second link while a flow runs | refused; the running sheet stays | `TestSlackConnectServe_SecondStartBusy`, `testSecondLinkWhileRunningIsRefused` |
| Link | port 18551 busy | `port_busy`; pane line; rebind on pane open; paste per A9 | `TestSlackConnectListener_PortBusy`, `testPortBusyLine`, `SlackConnectListenerHostTests.testEnsureRunningRebindsAfterPortBusy` |
| Link | the child crashes | one restart, then on pane open | `testUnexpectedExitRestartsOnce` |
| Link | the Desktop is quit or killed | child process group reaped; port free | `testCancelKillsProcessGroup`, `TestSlackConnectServe_StdinEOFExits` |
| Link | policy forbids Slack | `failed/policy`, no browser | `TestSlackLinkConnect_PolicyBlocksSlack` |
| Move | exchange or token save fails mid re-bind | old token file intact, old token keeps syncing, row unchanged | `TestSlackLinkConnect_RebindExchangeFails`, `_RebindTokenSaveFails` |
| Move | restart between token save and row update | the next `LoadFresh` repairs the row from the file | `TestSlackLinkConnect_RebindRestartMidway`, `TestSlackRefresh_RepairsRowFromFile` |
| Move | someone else signs in | refused, nothing written (A18) | `TestSlackLinkConnect_RebindOtherUserRefused` |
| Adopt | token of a non-collaborator / unknown app id / update fails | nothing changed, no record; the state says what to do | `TestAdopt_NotCollaborator`, `TestAdopt_NeedAppID`, `TestAdopt_UpdateFailsNoRecord` |
| Tokens | refresh token near expiry on a rarely used account | refreshed when < 7 days are left, every cycle | `TestSlackRefresh_RefreshTokenNearExpiry`, `TestSlackRefresh_SkippedCadenceStillRefreshes` |
| Tokens | the legacy migration writes the token while a refresh runs | waits for the lock | `TestEnsureLegacySlackAccount_SavesUnderLock`, `TestSlackTokenWriters_AllLocked` |
| Tokens | refresh races login / another refresh | flock; holder wins; waiter re-reads | `TestSlackRefresh_LockRace` |
| Tokens | refresh token expired (offline past its life) | Re-login state | `TestSlackRefresh_Expired` |
| Tokens | crash between refresh and save | old file intact; next use refreshes again (or Re-login if the old refresh token was consumed) | `TestSlackRefresh_CrashBeforeSaveKeepsOldFile` |
| Build | a public release without `RETIRED_SLACK_CLIENT_ID` | refused before building; a non-release binary without it shows no banner | `test-build-app-retired-slack-id.sh`, `TestSlackAccountSharedApp_RetiredIDOnly` |
| Shared app | `slack accounts --json` read fails | last flags kept; no banner on a first failed read | `testFlagsReadFailureKeepsLast` |
| MDM | malformed `SlackApps` | no organization rows, problem reported | `TestPolicy01_WrongTypesFailClosed`, fixture cases |

## Promises → tasks → tests

| Promise (spec § / screens §) | Task | Test |
|---|---|---|
| One-paste admin setup that resumes (§5.1, D9) | 9, 13 | `TestAppSetup_*`, `SlackAppSetupModelTests` |
| The link lives in the About page; nobody's Mac needed after setup (§5.2, D7) | 9, 16 | `TestAppSetup_WritesLinkToDescription`, spike Q6/Q7 |
| The link starts PKCE on the clicker's Mac, lands on localhost, no page of ours (§5.3, D8) | 6, 7 | `TestSlackConnectServe_LinkConfirmConnected`, `TestExchange_NoSecretInForm` |
| The listener never collides and needs the owner's press (§5.3) | 6, 7, 14 | `TestOAuthPortRanges_Disjoint`, `TestSlackConnectListener_*`, `testLinkStartsAtConfirm` |
| Port busy is said and has a way out (§5.3, screens §4.4) | 7, 10, 14 | `TestSlackConnectListener_PortBusy`, `testPortBusyLine` (way out per A9) |
| The connect code works without the link (§5.2, §5.3) | 6, 14 | `TestParseConnectInput`, `testPasteSkipsConfirm` |
| Team mismatch refused (§5.3) | 6, 7 | `TestRegistry_TeamMismatch`, `TestSlackLinkConnect_TeamMismatch` |
| MDM `SlackApps` with one-click Connect (§5.4) | 5, 14 | `policy_cases.json`, `testOrganizationRowsFromPolicy`, `testMDMConnectSkipsConfirm` |
| No client secret anywhere (D13) | 6, 8, 9 | `TestExchange_NoSecretInForm`, `TestSlackRefresh_NoSecretInForm`, `TestAppSetup_SecretNeverStored` |
| Tokens refresh before expiry (access < 1 h or refresh < 7 days), one writer (§5.5) | 8, 16 | `TestSlackRefresh_*`, `TestSlackTokenWriters_AllLocked` |
| Waiting for approval shown when Slack says so (§5.1 step 5, screens §3.4) | 9, 13, 16 | `testApprovalRowOnlyWhenRecordSaysSo`, spike Q5 |
| Shared-app accounts keep working, banner offers Full or Live (§6, D11) | 3, 15 | `TestSlackAccountSharedApp_*` (the parent's `TestSharedAppBanner`), `testSharedAppBanner`, `testSharedAppIsNotAttention` |
| Moving to Full re-binds the same row, history kept (§6 as changed by ask #1425) | 7, 8 | `TestSlackLinkConnect_Rebind*`, `TestSlack01_*` unchanged |
| A company with its own app updates it instead of creating a second one (ask #1425) | 9, 13 | `TestAdopt_*`, `testExistingAppOffersAdoptNotCreate` |
| A member who cannot create apps can hand the setup to an admin (review #1426) | 13 | `testNotAllowedState`, `testAdminNoteText` |
| Onboarding connects Slack without a baked app (A13) | 15 | `testSlackWithoutBuiltinAppOpensConnectSection`, `testOnboardingStrings`, `slack-fl-onboarding-*` shots |
| Every public release recognises shared-app accounts; a corp-app account is Full (screens §1.1 as changed by ask #1425) | 2, 3, 4 | `TestSlackAccountSharedApp_RetiredIDOnly`, `TestBackfillSlackClientIDs_*`, `test-build-app-retired-slack-id.sh` |
| No build bakes a Slack app any more (§6, asks #1414/#1425) | 18 | `test-build-app-retired-slack-id.sh` (A15 cases) |
| A second workspace connects in Full; Add Slack Account only while a build still bakes an app (screens §4.2 as changed by ask #1414) | 14, 15 | `testFullFoldsConnectSection`, `testAddAccountFollowsBuiltinApp` |
| Mode pane, Live rows with age, every block state (screens §1) | 11 | `SlackModePresentationTests`, `SlackLiveStatusCenterTests` |
| `needsFullSlack` on Slack-dependent screens, sidebar, Knowledge note, phone (screens §2) | 12 | `FeatureReadinessTests.testNeedsFullSlack*`, `SidebarVisibilityTests`, `TestDBAccounts_LiveOnlySlackRow`, `AccountStatusStyleTests.testLiveOnly` |
| Every new screen rendered from the real views (screens §8, §10) | 11–15 | `DesignShotsTests.testSlackFullLiveShotsRender` |
| The guide and feature notes say all of this (screens S6) | 17 | `go test ./docs/guide` |

## Phase gate (controller, once per phase)

`make test`, `go test ./cmd/...`, `make test-swift`, `make lint-all`, `make test-scripts`; with Task 12's phone change `make mobile-test`; then the local-review skill on the umbrella branch.
