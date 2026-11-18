# Company Setup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One public build with no Google or Atlassian app of ours: a company sets Watchtower up once (Slack, Google, Atlassian, Linear, Microsoft 365) into a **company bundle**, every employee connects from one localhost link (or MDM, or a pasted code), a private person uses their own Google project, Atlassian also works by API token, Atlassian Personal Data Reporting runs on every Mac, and the corp build goes away without breaking its accounts.

**Architecture:** Go owns the bundle (`internal/companybundle`, pure), its local store and the wizard draft (`internal/company`), every OAuth client resolver (`…ForCompany(slug)` / `…ForAccount(id)`, bundle → per-account file → env → baked), the account rows (`company_slug`, `auth_kind`), the `/company/connect` path on Slack plan B's loopback child (`watchtower slack connect serve`, port 18551) and the connect chain, which runs **inside that child** so the Slack leg uses the listener that already holds 18551. The Desktop drives everything through CLI verbs (`watchtower company …`, secrets on stdin) and JSON lines; WatchtowerCore models own every UI string (equal to `CompanySetupMockCopy`), views lay them out with the design kit.

**Tech Stack:** Go 1.26 (cobra, `database/sql` on the in-repo SQLCipher driver, goose SQL migrations, `net/http` loopback, `testing/synctest`, `golang.org/x/sys/unix` flock), SwiftUI + GRDB (WatchtowerCore, DesignKit, DesignShotCatalog), XCTest, bash build scripts.

**Spec:** `docs/superpowers/specs/2026-11-17-company-setup-design.md` (behaviour, D1–D24, §1–§11) and `docs/superpowers/specs/2026-11-18-company-setup-screens-design.md` (screens, S1–S29, A2–A30, models §9, failures §10, writers §11, mockups §12, C0–C7 §13). Mockups: `docs/design/mockups/company-setup/`; copy pinned in `WatchtowerDesktop/Tests/DesignShots/CompanySetupMockCopy.swift`. Related: `docs/superpowers/specs/2026-11-14-slack-full-and-live-design.md` §5 and Slack plan B (`docs/superpowers/plans/2026-11-17-slack-full-plan-b.md`, on branch `feature/1709-planb-plan`, not in main).

## Global Constraints

- **Umbrella:** every task PR goes into `feature/1887-company-setup`, never main; the umbrella PR stays draft until Phase 5. Each lane works in its own worktree branched off the umbrella; the umbrella merges `origin/main` before each phase starts.
- **Bundle (§1):** JSON `{"v":1,"company":…,"slack":{team_id,client_id},"google":{client_id,client_secret,domain},"atlassian":{client_id,client_secret,site,confluence},"linear":{client_id},"microsoft":{client_id,tenant_id},"link_deny_hosts":[…]}`; `v` and `company` required, every vendor block optional; `personal` (bool) only in stored files — `Parse` refuses it from a link, MDM or code; unknown `v` → "This link needs a newer Watchtower"; unknown fields, wrong types, non-https `site`, bad ids → refused. Wire form: base64url, no padding; hard cap **3,000** encoded characters.
- **Store:** `<workspace>/company/<slug>.json` mode `0600`, directory `0700`; `<slug>` = lowercase `company` reduced to `[a-z0-9-]`, numeric suffix (`-2`, `-3`…) on a clash with a different company; per-file flock; last confirmed write wins; MDM never writes a file (forced overlay read at launch, wins over the stored bundle of the same company, never deletes accounts).
- **Draft:** `<workspace>/company/draft.json` mode `0600`; the Slack configuration token is never written; an unreadable draft is renamed `draft.json.bad-<UTC yyyymmddThhmmssZ>` (0600), only the newest `.bad-*` kept, the daemon deletes one older than **30 days**; Discard and a successful Publish delete the draft and any `.bad-*`.
- **Link:** `http://127.0.0.1:18551/company/connect?b=<bundle>`; a valid one answers `302` to `http://127.0.0.1:18551/company/connected`; GET only, `Host` checked, never serves files, the request log keeps the path only (FILES-01). The old `/slack/connect` keeps working.
- **Resolver order (every vendor):** the company's bundle (forced MDM overlay first) → the account's own credentials file → env (`WATCHTOWER_<VENDOR>_CLIENT_ID/SECRET`, development) → the baked default. Argument-less `resolveJiraOAuthConfig` must not remain.
- **Account error codes** (stored in each account table's existing `error` column with `status='error'`, never `revoked`, so PURGE-01 schedules no 72 h purge): `company_changed_app` (a **Replace**), `invalid_client` (refresh refused, tied account), `unknown_client` (refresh refused, `company_slug = ''`), `api_token_dead` (D22). One hint code leaves `status` as it is: `pdr_scope_missing` ("Re-login to finish the setup"; the account keeps syncing).
- **API token (§4b):** token on stdin only (`--api-token-stdin`), never argv or log; `Authorization: Basic base64(email:token)`, no refresh; 401 → `error`/`api_token_dead`, data kept, only the 30-day lease applies; 403 → "This token lacks <scope> — create one with the listed scopes"; non-Cloud site refused before storing.
- **PDR (§6):** every **7 days** per Atlassian account (`last_pdr_at`), POST chunks of **90** account ids to `https://api.atlassian.com/app/report-accounts/`; `closed` → erase in **one write transaction per account**; an error erases nothing; runs after `phaseExternalSync` in the same cycle. Token accounts: the same erase from a 7-day `GET /rest/api/3/user/bulk` lookup; an ambiguous answer erases nothing.
- **MDM keys (D24, D9):** `CompanyBundle` (string, bundle wire form), `AllowAtlassianAPIToken` (bool, default true), `AllowOwnGoogleProject` (bool, default true); forced values only, wrong type fails closed (POLICY-01); rows in `internal/policy/testdata/policy_cases.json` (POLICY-02); tightening stops syncing and keeps data (POLICY-03). `docs/mdm/keys.json` equals `watchtower policy keys --json` (golden).
- **Shared apps:** shared Google client = Calendar scopes only (D11); public build stops baking `DefaultJiraClientID/Secret` (D4), env stays for development; shared Linear app stays (D12, unless S3 flips it); shared Microsoft client stays for personal Outlook (D16).
- **Strings:** every UI string lives in a WatchtowerCore model pinned by a test and equals the matching `CompanySetupMockCopy` constant (test: `XCTAssertEqual(Model.x, CompanySetupMockCopy.x)` style, one per string family). Desktop is not localised. Colors only through `Tone`; no stock list look, no row separators; design kit components only (`docs/design/desktop-style-guide.md`).
- **Migrations:** one SQL migration (Task 6), number = next free at implementation time (main ends at `00195`; Slack plan B and others may land first), written below as `<NNNNN>`. Mirror into `internal/db/schema.sql`, regenerate golden + Swift test schema (`go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`). No Go migration.
- **Tests:** never wait on wall-clock (`synctest`, injected clocks, fakes); the listener is tested in-process on port 0, never 18551; a test that starts a process reaps its process group in `t.Cleanup`; packages creating git repos call `gittest.DisableBackgroundGit()`. Sample data only (`Acme`, `acme`, `example.com`, made-up ids); `leak-check:allow` on deliberate fakes that trip a pattern.
- **Inner loop per task** (`go test ./internal/<pkg>`, targeted `go test ./cmd -run …`, `make test-swift FILTER=…`, `make lint-diff` for Go, `make lint-swift` for Swift); the full gate (`make test`, `make test-swift`, `make lint-all`, `go test ./cmd/...`) runs once per phase by the controller and before the umbrella PR.
- **Inventory:** POLICY-01/02 gain the three keys (approved, asks #1476 and D9); PURGE-01 text unchanged; EXT-01 (GET-only Confluence) unchanged; LINEAR-02/03 unchanged; FILES-01 covers the listener log. Any other inventory entry a task finds it must change → stop, owner ask before that task's review.

## Prerequisite: Slack plan B (not in main)

Recon on 2026-11-18: **nothing of Slack plan B has shipped.** Main has no listener on 18551, no `internal/slackconnect`, `internal/slackapp`, `internal/slackauth`, no `slack connect serve`, no `slack app create|adopt|link|status`, no `SlackAppSetupModel`, no `CLILineStream`/`SlackConnectListenerHost`, no `SlackApps` policy key. The plan itself is on the unmerged branch `feature/1709-planb-plan`.

This plan **does not rebuild them**; it builds on plan B's contracts as that plan fixes them:

| Plan B task | What this plan uses | Used by |
|---|---|---|
| T2 (data: `slack_accounts.client_id`, setup record) | the Slack client id per account, the setup record | Tasks 12, 14, 15 |
| T6 (`internal/slackconnect`: `Port`, `RedirectURL`, `ParseConnectInput`, `TestOAuthPortRanges_Disjoint`) | the listener mux and port | Task 10 |
| T7 (`slack connect`, `slack connect serve`, JSON lines, `writeConnectedAccount`) | the child process, stdin/stdout protocol, the Slack leg of the chain | Tasks 10, 11 |
| T9 (`internal/slackapp`: `API`, `BuildManifest`, `MergeManifest`, `slack app create|adopt|link|status`) | create, reuse (adopt = `apps.manifest.export` + `update`), the About-page write | Tasks 14, 15 |
| T10 (Swift `CLILineStream`, `SlackConnectListenerHost`) | the Desktop end of the child | Tasks 15, 22 |
| T13 (`SlackAppSetupModel` with sheet) | **C0** (Task 15) builds the model without the sheet; whichever plan runs first builds it, the other reuses it | Task 15 |
| T1 spike (Q6 link rendering, Q11 export/update on an existing app) | answers shared with S1 | Task 2 |

**Gate G2 (before Phase 2):** plan B Tasks 2, 6, 7, 9, 10 merged into main and main merged into the umbrella. If the owner wants this plan to move first, the controller runs those five plan-B tasks, exactly as plan B writes them, into main first; this plan never copies them into the umbrella. Phase 0, Phase 1 and Phase 3 (Tasks 1–9, 16–19) do not touch Slack and do not wait for G2; Tasks 10, 14, 15, 23 (and everything after them) do.

## Decisions taken in this plan (agent; flag at review)

| # | Decision | Why |
|---|---|---|
| P1 | The connect chain runs inside plan B's `slack connect serve` child (new stdin cmds `company_connect`, `company_skip`, `company_stop`; events `company_link`, `company_vendor`, `company_done`), and one-shot as `watchtower company connect --slug S --vendors …` without the Desktop | the Slack leg needs the process that holds 18551; one Go path gives the spec's "chain test with a fake per vendor" |
| P2 | Package split: `internal/companybundle` (pure Parse/Encode/Slug, no deps), `internal/company` (store, draft, discovery, change detection, deny hosts, mobileconfig) | the policy package imports the pure part only |
| P3 | One migration carries `company_slug` (5 tables), `jira_accounts.auth_kind` and `jira_accounts.last_pdr_at` | one renumber instead of three |
| P4 | Per-account client files for Atlassian, Linear, Microsoft are `<workspace>/<vendor>_client_<accountID>.json` (0600) via `internal/oauthclient.Store`; Google keeps `google_credentials_<id>.json` (`calendar.CredentialStore`) | spec §8 "new Atlassian and Linear equivalents" |
| P5 | `invalid_client` on refresh: `company_slug != ''` → `invalid_client` ("your company changed its app; open the new link"); `company_slug = ''` → `unknown_client` ("open your company's link") | no stored "issuing client" exists for Jira/Linear tokens; the slug is the honest discriminator |
| P6 | Memory erase in PDR: Jira and Confluence people are **not** memory aliases today (person entities are keyed by Slack ids, `internal/memory/jira_ingest.go` `linkJiraIssueEntities`). PDR erases `jira_user_map.slack_user_id` (so no new link forms) and calls a new `memory.ForgetAliases(prefixes)` that removes any `jira:<accountId>`/`confluence:<accountId>` alias and tombstones an orphaned node — a no-op today, a guard for later | spec §6 assumed the alias exists |
| P7 | Dry authorize check = an HTTP GET of the authorize URL without following redirects, classified by status/`error` param/AADSTS code; the exact markers come from S1 | spec §2.4 says "dry authorize URL" without a mechanism |

## Writers of the same data and who wins

| Data | Writers (all Go unless noted) | Rule |
|---|---|---|
| `company/<slug>.json` | `company confirm` (link, code), `company check` (first and later checks), `company publish`, `company confirm --replace`, the bridge (Task 28), `google add --client-id` (personal) | per-file flock (`<slug>.json.lock`); last confirmed write wins; a check over a stored vendor's changed client is a Replace and needs `--replace`; MDM never writes — the forced overlay wins at read |
| `company/draft.json` (+ `.bad-*`) | only `company draft save|discard`, `company check` (the checked hash), `company publish` (delete) | `draft.json.lock`; one wizard run at a time (`AppState.companySetup`) |
| Slack setup record | plan B `slack app create|adopt|link` only | the record owns the Slack app; the draft keeps only `slack.app_id` |
| `*_accounts.company_slug` | account add from a bundle (`--company`), `company check`, `company confirm --replace` (marks), bridge | one write transaction each; Swift never writes; the bridge runs before the daemon starts |
| `jira_accounts.auth_kind`, API token file | `jira add --api-token-stdin` and its re-auth only | sync reads, never writes |
| Per-account client files | account add from a bundle; a **Replace** confirm | token refresh never writes them |
| `jira_user_map`, `ext_users`, Jira person columns | Jira/Confluence syncs, the PDR phase | PDR runs after the syncs in the same cycle (last word); Atlassian returns closed accounts anonymised, so a re-insert writes the same anonymous value |
| Memory aliases/nodes | memory engine, PDR via `memory.ForgetAliases` | the tombstone API, never a raw delete |
| `last_pdr_at` | the PDR phase only | stamped after a whole-account success |
| Account `status/error` codes of this plan | refreshers (`invalid_client`/`unknown_client`/`api_token_dead`), `confirm --replace` (`company_changed_app`), PDR (`pdr_scope_missing`), a successful login clears | last writer wins; a successful login always clears |

## Review Focus

1. **Two different companies whose names slug to the same value** (`Acme Inc` and `acme-inc`), or a company name of non-ASCII only (`Ачме`): each gets its own file, never an overwrite or an empty slug — `TestSlug_ClashGetsSuffix`, `TestSlug_NonASCIIFallsBackToCompany` (Task 4/5).
2. **The same link opened twice** (a double click, a browser prefetch, a reload before the redirect): one confirmation, never two chains — `TestCompanyListener_DuplicateLinkWhilePendingIsOne` (Task 10).
3. **A bundle that differs only in form** (`https://Acme.atlassian.net/` vs `https://acme.atlassian.net`, ids with surrounding spaces): treated as the same company, not as a change needing **Replace** — `TestParse_NormalizesSiteAndIDs`, `TestChanges_IgnoreNormalizedForm` (Tasks 4, 5).
4. **A hostile `link_deny_hosts` entry** (`*`, `https://x/`, `example.com/path`, an IP range, 10,000 entries within the cap): refused at Parse, never widens or empties the refused set — `TestParse_DenyHostsRejectsNonHosts` (Task 4), `TestDenyHosts_BundleOnlyAdds` (Task 9).
5. **A Google account the person had before on the shared client, re-added through the company:** the same Google user id becomes one row tied to the company, not a duplicate — `TestGoogleAdd_CompanyRebindsSameUser` (Task 7b).

---

## Phase 0 — Spikes (start first; S2 runs in parallel for 8+ days)

### Task 1: S2 — personal Gmail refresh token past 7 days

**Depends on:** none. **Owner/controller, manual; starts on day 1 of the plan.** Its result is needed only by Task 18 (one flag) and Task 26 (one frame).

**Files:** Modify `docs/superpowers/specs/2026-11-17-company-setup-design.md` (§4 "Unverified so far" → the result), this plan's spike table.

- [ ] **Step 1 (day 1):** a fresh @gmail.com; a new Google Cloud project; Gmail API on; consent screen External, the account as test user; **Publish app** to production, unverified; OAuth client Desktop app; `watchtower google add --client-id <id> --client-secret-stdin` on a **copy** of a workspace (never the live DB, memory rule); record the issue time.
- [ ] **Step 2 (day 8 or later):** in the copy, force a refresh (`watchtower gmail sync` against that workspace); record `ok` or the error (`invalid_grant`).
- [ ] **Step 3:** write the answer into the spec §4 and the table below. **Outcome A (refresh works):** Task 18 ships `ownProjectWeeklyRelogin = false`; the `company-ownGoogle-done-weekly` frame is not wired. **Outcome B (fails):** Task 18 sets the flag true and stamps `relogin_due_at = issued + 7d`; Task 26 wires the weekly frame and the row's "Re-login due in <n> days" from day 5; the guide says so (Task 30).
- [ ] **Step 4: Commit** `docs(spec): S2 result — personal Gmail past 7 days (#1887)`.

### Task 2: S1 — Atlassian, Slack and dry-check answers

**Depends on:** none (controller, manual; needs a test Atlassian site, a test Slack workspace with a config token, a test Entra tenant). Reuse plan B Task 1's answers for Q6 and Q11 when already filled.

**Files:** this plan's spike table; spec §11 Open items closed.

| # | Question | Consequence |
|---|---|---|
| S1.1 | Atlassian 3LO: how many callback URLs per app? Exact loopback form accepted? | **One:** `jira.CompanyRedirectPort = 18511` fixed for company apps, busy port → "free port 18511"; wizard **Copy callback URLs** copies one. **Several:** the whole 18511–18520 range listed; Task 7a unchanged |
| S1.2 | Is a URL in a Slack app's `long_description` clickable on About? (= plan B Q6) | **No:** Publish text leads with the code; guide says "copy the code" |
| S1.3 | `apps.manifest.export`/`update` on an existing app with a collaborator's config token; non-collaborator error code (= plan B Q11) | the `not_collaborator` mapping in plan B's `slackapp`; Task 14 only consumes it |
| S1.4 | API token base URL: scoped token → `https://api.atlassian.com/ex/jira/<cloudId>`? classic → `https://<site>`? Does `_edge/tenant_info` answer without auth? | Task 17's `jira.APITokenBaseURL(kind, cloudID, site)` |
| S1.5 | Closed account marker in `GET /rest/api/3/user/bulk` (anonymised `displayName`, `active:false`, absent) | Task 17's `classifyBulkUser` |
| S1.6 | Dry authorize GET answers: Google bad client id; Microsoft bad id (AADSTS700016), missing admin consent (AADSTS65001 — visible without sign-in?); Linear bad client id | Task 13's `classifyDryAuthorize`. If consent is **not** visible to a dry GET: the Microsoft step's **Check again** runs a sign-in (like Google) and `admin_consent` comes from its error |
| S1.7 | Atlassian error when an organization blocks user-installed apps | the `atlassian-signinFailed` reason text |

- [ ] **Step 1:** run each probe with `curl` / a browser, record status codes and error keys (never values, never real ids).
- [ ] **Step 2:** fill the table "Spike answers" at the end of this plan; mark each consequence applied by the named task.
- [ ] **Step 3: Commit** `docs(plan): S1 spike answers (#1887)`.

### Task 3: S3 — Linear terms and admin need

**Depends on:** none (controller, reading + one probe in a test Linear workspace as a non-admin member).

- [ ] **Step 1:** read Linear's API terms and OAuth application terms; list any obligation of an app distributor (data reporting, deletion, review).
- [ ] **Step 2:** as a non-admin member, try Settings → API → OAuth applications → New.
- [ ] **Step 3:** record. **Outcome "no obligation we cannot meet" (D12 holds):** nothing changes. **Outcome "obligation":** stop and ask the owner; if confirmed, Task 19 also retires the shared Linear app like Atlassian's and the bundle's `linear` block becomes required for company use. **Admin needed:** Task 21's Linear step uses the Microsoft "Waiting" layout (`CompanyVendorGuide.adminNeeds[.linear]`); else Linear needs no admin line.
- [ ] **Step 4: Commit** `docs(spec): S3 result — Linear terms (#1887)`.

---

## Phase 1 — Core: bundle, store, migration, resolvers, policy keys, deny list

### Task 4: `internal/companybundle` + Swift twin (T1)

**Depends on:** none

**Files:**
- Create: `internal/companybundle/bundle.go`, `bundle_test.go`, `testdata/bundle_cases.json`
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Models/CompanyBundle.swift`, `WatchtowerDesktop/Tests/Core/CompanyBundleTests.swift`

**Interfaces (Produces):**
```go
const Version = 1
const MaxEncodedLen = 3000
type Origin int // OriginLink, OriginMDM, OriginCode, OriginLocal
type Bundle struct {
    V int `json:"v"`; Company string `json:"company"`; Personal bool `json:"personal,omitempty"`
    Slack *Slack `json:"slack,omitempty"`; Google *Google `json:"google,omitempty"`
    Atlassian *Atlassian `json:"atlassian,omitempty"`; Linear *Linear `json:"linear,omitempty"`
    Microsoft *Microsoft `json:"microsoft,omitempty"`; LinkDenyHosts []string `json:"link_deny_hosts,omitempty"`
}
type Slack struct{ TeamID, ClientID string }          // json team_id, client_id
type Google struct{ ClientID, ClientSecret, Domain string }
type Atlassian struct{ ClientID, ClientSecret, Site string; Confluence bool }
type Linear struct{ ClientID string }
type Microsoft struct{ ClientID, TenantID string }
type Refusal string // "damaged", "too_long", "site_not_https", "personal", "newer_version"
type ParseError struct{ Reason Refusal; Detail string }
func Parse(wire string, origin Origin) (Bundle, error)   // *ParseError
func ParseJSON(raw []byte, origin Origin) (Bundle, error) // stored files: OriginLocal
func Encode(b Bundle) (string, error)
func Slug(company string) string                          // "" input → "company"
func (b Bundle) Vendors() []string                        // fixed order: slack, google, atlassian, microsoft, linear
```
Swift: `struct CompanyBundle: Codable, Equatable`, `enum CompanyBundleOrigin`, `enum CompanyBundleRefusal: String`, `static func parse(_ wire: String, origin:) -> Result<CompanyBundle, CompanyBundleRefusal>`, `static func slug(_:) -> String`.

- [ ] **Step 1: Fixture.** `testdata/bundle_cases.json`: `[{"name","wire"|"json","origin","want":{"ok":bool,"reason":"…","bundle":{…},"slug":"…"}}]` covering: minimal `{v,company}`; every vendor block; unknown field → `damaged`; wrong type (`confluence:"yes"`) → `damaged`; bad base64 → `damaged`; padding present → `damaged`; 3,001 chars → `too_long`; `site:"http://…"` → `site_not_https`; `personal:true` from link/MDM/code → `personal`, from local → ok; `v:2` → `newer_version`; Slack `team_id` not `^[TE][A-Z0-9]{2,}$` or client id not `^[0-9]+\.[0-9]+$` → `damaged`; Microsoft tenant not a GUID or verified domain → `damaged`; `site:"https://Acme.atlassian.net/"` → normalized `https://acme.atlassian.net`; deny hosts `["*","https://x/","example.com/path","10.0.0.0/8"]` each → `damaged`; slugs `"Acme"→"acme"`, `"Acme Inc."→"acme-inc"`, `"Ачме"→"company"`.
- [ ] **Step 2: Failing Go tests:** `TestCompanyBundle_Cases` (table over the fixture), `TestEncode_RoundTrip` (`Parse(Encode(b)) == b`, no `=`), `TestParse_NormalizesSiteAndIDs`, `TestParse_DenyHostsRejectsNonHosts`, `TestSlug_NonASCIIFallsBackToCompany`, `TestParse_RefusalReasonsAreClosedSet`.
- [ ] **Step 3: Run:** `go test ./internal/companybundle` → FAIL (`undefined: Parse`).
- [ ] **Step 4: Implement** in `bundle.go`: `json.Decoder.DisallowUnknownFields`; hosts through `linkrule.NormalizeHostSet`-compatible rules (lower-case, no scheme/path/port/wildcard, must contain a dot, not an IP literal).
- [ ] **Step 5: Run:** PASS. `make lint-diff`.
- [ ] **Step 6: Swift twin, failing:** `CompanyBundleTests.testSharedFixture` reads `internal/companybundle/testdata/bundle_cases.json` via `#filePath` (the `ManagedPolicyTests` pattern) and asserts every case; `testRoundTripMatchesGoEncoding`.
- [ ] **Step 7:** `make test-swift FILTER=CompanyBundleTests` → FAIL; implement; → PASS; `make lint-swift`.
- [ ] **Step 8: Commit** `feat(company): company bundle format, Go and Swift (#1887)`.

**Guards:** none beyond the package (new code).

### Task 5: `internal/company` store, change detection, forced overlay, `company list|inspect|confirm`

**Depends on:** Task 4

**Files:**
- Create: `internal/company/store.go`, `store_test.go`, `changes.go`, `changes_test.go`
- Create: `cmd/company.go`, `cmd/company_test.go`

**Interfaces:**
```go
type Entry struct{ Slug string; Bundle companybundle.Bundle; Forced bool }
type LoadError struct{ File, Err string }
type Store struct{ Dir string } // <workspace>/company
func NewStore(workspaceDir string) Store
func (s Store) LoadAll(forcedWire string) ([]Entry, []LoadError, error) // forced overlay wins per company name
func (s Store) Get(slug string, forcedWire string) (Entry, bool, error)
func (s Store) SlugFor(company string) (string, error)                 // existing slug of that company, else a free one
func (s Store) Save(slug string, b companybundle.Bundle) error           // flock, 0600 temp+rename, dir 0700
type Change struct{ Vendor, Field, Old, New string }
func Changes(stored, incoming companybundle.Bundle) []Change            // client ids, secrets, tenant, site; normalized
func ShortID(id string) string                                         // first 4 + "…" + last 3 (A21)
```
CLI (`--json`; bundle on stdin, one line):
- `watchtower company list --json` → `{"companies":[{"slug","company","forced","personal","vendors":{"google":{"client_id","domain"},…}}],"errors":[{"file","error"}],"draft":{"state":"none|ok|unreadable"}}` (draft state filled by Task 12).
- `watchtower company inspect --json` (stdin wire) → `{"company","slug","state":"new|same|changed","vendors":[…],"connected":{"slack":true,…},"changes":[…],"forbidden":["jira",…]}` (connected = an `ok` account with that `company_slug`; forbidden = `policy.SourceAllowed` false).
- `watchtower company confirm --source link|code|mdm [--replace] --json` (stdin wire) → `{"result":"stored|unchanged|needs_replace","slug","marked":[account ids]}`. `--replace` stores and sets `status='error', error='company_changed_app'` on the changed vendors' accounts of that slug (one tx).

- [ ] **Step 1: Failing tests:** `TestCompanyStore_ModesAndRoundTrip` (file 0600, dir 0700), `TestSlug_ClashGetsSuffix` (`Acme Inc` then `acme-inc` → `acme-inc`, `acme-inc-2`), `TestCompanyStore_SameCompanyKeepsSlug`, `TestCompanyStore_DamagedFileIsLoadError` (one bad file → `LoadError{File:"acme.json"}`, the other companies still load — never "no company"), `TestCompanyStore_ForcedOverlayWins` (forced `Acme` differs → `Forced:true` entry with the forced ids; file unchanged), `TestCompanyStore_ConcurrentSaveSerialized` (two goroutines, flock, final file is one of the two whole), `TestChanges_ListsEachChangedID`, `TestChanges_IgnoreNormalizedForm`, `TestShortID`, `TestCompanyConfirm_ChangedNeedsReplace` (no write without `--replace`), `TestCompanyConfirm_ReplaceMarksChangedVendorsOnly`, `TestCompanyConfirm_DifferentCompanySameSlackTeamIsSeparate` (§7 row), `TestCompanyInspect_ForbiddenVendorListed`.
- [ ] **Step 2:** `go test ./internal/company ./cmd -run 'Company'` → FAIL.
- [ ] **Step 3: Implement.** Forced wire comes from `policy.Current()` (Task 8 adds the accessor; until it lands `cmd/company.go` reads `""` through a package var `companyForcedBundle = func() string { return "" }` that Task 8 rewires).
- [ ] **Step 4:** PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `feat(company): local company store and confirm with Replace (#1887)`.

**Guards:** `go test ./cmd -run 'Accounts|Policy'` (source guards on new verbs via `applySourceGuards` where a verb touches accounts).

### Task 6: Migration — `company_slug`, `auth_kind`, `last_pdr_at` (T1b data, T13 data, T9 data)

**Depends on:** none

**Files:**
- Create: `internal/db/migrations/<NNNNN>_company_setup.sql`
- Modify: `internal/db/schema.sql`, `internal/db/testdata/` golden (regenerated), `WatchtowerDesktop/Tests/Support/TestDatabase+Schema.swift` (regenerated)
- Modify: `internal/db/jira_accounts.go`, `google_accounts.go`, `slack_accounts.go`, `linear_accounts.go`, `email_accounts.go` (+ their `_test.go`)
- Modify: Swift models `WatchtowerDesktop/Sources/WatchtowerCore/Models/{GoogleAccount,JiraAccount,SlackAccount,LinearAccount,EmailAccount}.swift` (read-only `companySlug`, Jira `authKind`)

**Interfaces:**
- SQL: `ALTER TABLE <t> ADD COLUMN company_slug TEXT NOT NULL DEFAULT ''` for `slack_accounts`, `google_accounts`, `jira_accounts`, `linear_accounts`, `email_accounts`; `ALTER TABLE jira_accounts ADD COLUMN auth_kind TEXT NOT NULL DEFAULT 'oauth' CHECK (auth_kind IN ('oauth','api_token'))`; `ALTER TABLE jira_accounts ADD COLUMN last_pdr_at TEXT NOT NULL DEFAULT ''`; Down drops them.
- Go: `CompanySlug string` on `SlackAccount`, `GoogleAccount`, `JiraAccount`, `EmailAccount`, `LinearAccount`; `JiraAccount.AuthKind string`, `JiraAccount.LastPDRAt string`; `Create*Account` writes `CompanySlug` (and Jira `AuthKind`); `func (db *DB) CreateLinearAccountForCompany(label, companySlug string) (int64, error)` (`CreateLinearAccount(label)` calls it with `""`); `func (db *DB) SetAccountCompany(source string, id int64, slug string) error` (source ∈ `slack|google|jira|linear|outlook`); `func (db *DB) AccountsByCompany(slug string) ([]CompanyAccountRef, error)` (`{Source string; ID int64; Status, Error string}`); `func (db *DB) MarkCompanyAccounts(slug string, sources []string, code string) ([]int64, error)`; `func (db *DB) SetJiraLastPDR(id int64, at string) error`.

- [ ] **Step 1: Failing tests:** `TestCompanySlug_DefaultsEmpty` (each table), `TestCreateJiraAccount_StoresCompanyAndAuthKind`, `TestJiraAuthKind_CheckRefusesOther` (`'basic'` → constraint error), `TestMarkCompanyAccounts_OneTxOnlyThatSlug`, `TestAccountsByCompany`.
- [ ] **Step 2:** `go test ./internal/db -run 'CompanySlug|AuthKind|CompanyAccounts|CreateJiraAccount'` → FAIL.
- [ ] **Step 3: Implement** migration (follow the `add-migration` skill; plain `ADD COLUMN`, no rebuild); mirror into `schema.sql`; regenerate: `go test ./internal/db/ -run 'TestSchemaGolden|TestDesktopTestSchema' -update`.
- [ ] **Step 4: Run guards:** `go test ./internal/db -run 'TestAllTablesExist|TestSchemaGolden|TestDesktopTestSchema|TestPurge02_EveryAccountTableCovered'` → PASS; `go test ./internal/db` → PASS.
- [ ] **Step 5: Swift:** add the read-only fields; `make test-swift FILTER='GoogleAccountTests|JiraAccountTests|AccountQueriesTests'` (whichever exist; the decode tests over the regenerated schema) → PASS; `make lint-swift`.
- [ ] **Step 6: Commit** `feat(db): company_slug, auth_kind and last_pdr_at on account rows (#1887)`.

**Guards:** `TestAllTablesExist`, schema golden, `TestDesktopTestSchema`, `TestPurge02_*` (`go test ./internal/db -run Purge02`), `go test ./cmd -run 'Jira|Google|Linear|Outlook|Slack'` (callers of the changed constructors compile and pass).

### Task 7a: Atlassian resolvers, `jira add --company`, `invalid_client` (T1b, T7 for Atlassian)

**Depends on:** Task 5, Task 6. S1.1 changes only `jira.CompanyRedirectPort` handling (see Task 2).

**Files:**
- Create: `internal/oauthclient/store.go`, `store_test.go`
- Modify: `cmd/jira.go` (remove `resolveJiraOAuthConfig` at `:1489`; call sites `:596 connectJiraAccount`, `:768 runJiraAdd`, `:854 runJiraLogin`, `:1135 runJiraBoards`, `:1389 runJiraSync`, `:1724 runJiraBoardsAnalyze`, `:2033 runJiraFieldsDiscover`, `:2099 runJiraFieldsMap`), `cmd/confluence.go:180`, `cmd/sync.go:1459 buildAtlassianClients`, `cmd/actions_registry.go:35`
- Create: `cmd/oauth_resolve.go`, `cmd/oauth_resolve_test.go`
- Modify: `internal/jira/auth_revoked.go` (+ test): classify `invalid_client`

**Interfaces:**
```go
// internal/oauthclient
type Client struct{ ClientID, ClientSecret, TenantID string } // json snake_case
type Store struct{ path string }
func NewStore(workspaceDir, vendor string, accountID int64) Store // <ws>/<vendor>_client_<id>.json, 0600
func (s Store) Load() (Client, bool, error); func (s Store) Save(c Client) error; func (s Store) Delete() error
// cmd/oauth_resolve.go
type clientSource string // "company", "account_file", "env", "baked"
var errUnknownCompany = errors.New("no stored company")
var errNoOAuthClient = errors.New("no OAuth client configured")
func resolveJiraOAuthConfigForCompany(workspaceDir, slug string) (jira.JiraOAuthConfig, clientSource, error)
func resolveJiraOAuthConfigForAccount(cfg *config.Config, database *db.DB, accountID int64) (jira.JiraOAuthConfig, clientSource, error)
// internal/jira
var ErrClientRejected = errors.New("atlassian rejected the OAuth client")
```
- `jira add --company <slug>`: `ForCompany` before any browser opens (unknown slug → error, exit 1); the new row gets `CompanySlug` in the same `CreateJiraAccount`; `oauthclient` file written from the bundle; `--with-confluence` implied by the bundle's `confluence: true`.
- Refresh `invalid_client` (Atlassian answers 401 `{"error":"invalid_client"}` or `unauthorized_client`) → `ErrClientRejected`; the sync marks `status='error'`, `error = invalid_client | unknown_client` (P5), never `revoked`.

- [ ] **Step 1: Failing tests:** `TestNoArgumentlessJiraResolver` (go/ast over `cmd/*.go`: no `resolveJiraOAuthConfig()` call or declaration), `TestJiraResolver_Order` (table: bundle → account file → env → baked; each layer removed in turn), `TestJiraAdd_CompanyUsesBundleClient` (fake Atlassian: the authorize URL carries the bundle's client id; row `company_slug='acme'`), `TestJiraAdd_UnknownCompanyFailsBeforeBrowser` (browser opener fake never called), `TestJiraAdd_CompanyFromWizardDraft` (screens §10), `TestJiraRefresh_InvalidClientIsErrorNotRevoked` (tied → `invalid_client`; untied → `unknown_client`; PURGE: no revoked row), `TestOAuthClientStore_Mode0600`.
- [ ] **Step 2:** `go test ./internal/oauthclient ./internal/jira ./cmd -run 'JiraResolver|JiraAdd|JiraRefresh|Argumentless|OAuthClientStore'` → FAIL.
- [ ] **Step 3: Implement;** change all 11 call sites (10 account-holding to `ForAccount`, `runJiraAdd` to `ForCompany` when `--company` is set, else today's env/baked via `ForCompany("")`).
- [ ] **Step 4:** PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `feat(jira): per-company and per-account Atlassian OAuth client (#1887)`.

**Guards:** `go test ./internal/jira -run 'EXT01|Revoked|Scope'`, `go test ./internal/confluence`, `go test ./cmd -run 'Jira|Confluence|Actions|Sync'`, `go test ./internal/purge -run Purge01`.

### Task 7b: Google, Linear, Microsoft resolvers and `--company` adds (T1b, T7)

**Depends on:** Task 5, Task 6, Task 7a (`internal/oauthclient`, `cmd/oauth_resolve.go`)

**Files:**
- Modify: `cmd/calendar.go:456-490` (`resolveGoogleOAuthConfig`, `resolveGoogleOAuthConfigForAccount` gains the bundle step), `cmd/google.go` (`google add --company`), `cmd/gmail.go`, `cmd/sync.go`, `cmd/media_mail.go` (callers)
- Modify: `cmd/linear.go:27` (`resolveLinearOAuthConfig` → `ForCompany`/`ForAccount`; `linear add --company`), `cmd/outlook.go:64` (`resolveMicrosoftOAuthConfig` → both forms; `outlook login --company`)
- Modify: `internal/imap/outlook_auth.go:61-78` (`MicrosoftOAuthConfig.TenantID`; endpoints `https://login.microsoftonline.com/<tenant or "common">/oauth2/v2.0/{authorize,token}`), `internal/linear` and `internal/gmail` refresh paths (`invalid_client` → `ErrClientRejected`)
- Test: `cmd/oauth_resolve_test.go`, `internal/imap/outlook_auth_test.go`

**Interfaces:**
```go
func resolveGoogleOAuthConfigForCompany(workspaceDir, slug string) (calendar.GoogleOAuthConfig, clientSource, error)
func resolveGoogleOAuthConfigForAccount(workspaceDir string, accountID int64) calendar.GoogleOAuthConfig // signature kept; bundle step added via the row's company_slug
func resolveLinearOAuthConfigForCompany(workspaceDir, slug string) (linear.OAuthConfig, clientSource, error)
func resolveLinearOAuthConfigForAccount(cfg *config.Config, database *db.DB, accountID int64) (linear.OAuthConfig, clientSource, error)
func resolveMicrosoftOAuthConfigForCompany(workspaceDir, slug string) (imap.MicrosoftOAuthConfig, clientSource, error)
func resolveMicrosoftOAuthConfigForAccount(cfg *config.Config, database *db.DB, accountID int64) (imap.MicrosoftOAuthConfig, clientSource, error)
func microsoftEndpoints(tenantID string) (authURL, tokenURL string)
```
- [ ] **Step 1: Failing tests:** `TestGoogleResolver_Order`, `TestLinearResolver_Order`, `TestMicrosoftResolver_Order`, `TestGoogleAdd_CompanyStoresSlugAndCredentials`, `TestGoogleAdd_CompanyRebindsSameUser` (Review Focus 5: an existing shared-client row with the same Google user → that row gets `company_slug` and the company client, no second row), `TestLinearAdd_CompanyClient`, `TestOutlookLogin_CompanyTenantEndpoint` (authorize URL host path `/<tenant>/oauth2/v2.0/authorize`), `TestMicrosoftEndpoints_EmptyTenantIsCommon`, `TestGoogleRefresh_InvalidClientIsError`, `TestLinearRefresh_InvalidClientIsError` (LINEAR-03: not revoked), `TestCompanyAdd_UnknownSlugFailsBeforeBrowser` (each vendor).
- [ ] **Step 2:** `go test ./internal/imap ./internal/linear ./internal/gmail ./cmd -run 'Resolver|CompanyAdd|GoogleAdd|LinearAdd|OutlookLogin|InvalidClient|Endpoints'` → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** PASS; `make lint-diff`.
- [ ] **Step 5: Commit** `feat(oauth): per-company Google, Linear and Microsoft clients (#1887)`.

**Guards:** `go test ./internal/linear -run 'Linear0'` (LINEAR-02/03), `go test ./cmd -run 'Google|Gmail|Calendar|Linear|Outlook|Sync'`, `go test ./internal/calendar ./internal/gmail`.

### Task 8: Policy keys `CompanyBundle`, `AllowAtlassianAPIToken`, `AllowOwnGoogleProject`; `policy keys --json` (T6 policy half, T14 key list)

**Depends on:** Task 4

**Files:**
- Modify: `internal/policy/policy.go` (keys, `Keyset`, `Normalize`), `current.go` (accessors), `testdata/policy_cases.json`, `policy_test.go`
- Modify: `cmd/policy.go` (`policy keys --json`; `policy show` text names the IT page URL)
- Create: `docs/mdm/keys.json`, `docs/mdm/site.json` (`{"url": policy.ITGuideURL}`, golden-tested so Swift reads the one value); `cmd/policy_keys_test.go`
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Models/ManagedPolicy.swift` (+ reader), `WatchtowerDesktop/Tests/Core/ManagedPolicyTests.swift`
- Modify: `cmd/company.go` (`companyForcedBundle` reads the policy)

**Interfaces:**
```go
const KeyCompanyBundle = "CompanyBundle"; KeyAllowAtlassianAPIToken = "AllowAtlassianAPIToken"; KeyAllowOwnGoogleProject = "AllowOwnGoogleProject"
// Keyset gains: CompanyBundle *string; AllowAtlassianAPIToken *bool; AllowOwnGoogleProject *bool
func (p Policy) CompanyBundle() string        // "" when absent or refused
func (p Policy) AtlassianAPITokenAllowed() bool
func (p Policy) OwnGoogleProjectAllowed() bool
type KeyDoc struct{ Key, Type, Default, Effect string } // json key,type,default,effect
func KeyDocs() []KeyDoc                                   // every key in Keys + ReservedKeys, display order
const ITGuideURL = "<set by Task 31; placeholder https://example.com/mdm until then>"
```
- `CompanyBundle` with a wrong type or a bundle `companybundle.Parse(_, OriginMDM)` refuses → most restrictive = absent + a `Problem`; booleans wrong type → `false` + `Problem` (POLICY-01).

- [ ] **Step 1: Fixture rows** in `policy_cases.json`: each new key forced valid; wrong type; `CompanyBundle` with `personal:true` → refused; absent → defaults true/true/"".
- [ ] **Step 2: Failing tests:** Go `TestPolicyCases` (existing, extended), `TestPolicyKeys_JSONEqualsDocsFile` (golden: `docs/mdm/keys.json` == `policy keys --json` output; `-update` rewrites), `TestPolicyShow_NamesITGuide`; Swift `ManagedPolicyTests.testSharedFixture` (existing, extended).
- [ ] **Step 3:** `go test ./internal/policy ./cmd -run 'Policy'` → FAIL; implement; → PASS. `make test-swift FILTER=ManagedPolicyTests` → PASS; `make lint-swift`; `make lint-diff`.
- [ ] **Step 4: Inventory:** `docs/inventory/policy.md` POLICY-01/02 list the three keys; changelog line (approved: asks #1476, D9).
- [ ] **Step 5: Commit** `feat(policy): CompanyBundle, AllowAtlassianAPIToken, AllowOwnGoogleProject (#1887)`.

**Guards:** POLICY-02 fixture both sides, `go test ./cmd -run 'Policy|Provider|Connections'`, `ProviderCatalogRegistryTests` (Swift, reads the same fixture). Merge note: plan B Task 5 adds `SlackApps` to the same `Keys` list — whichever lands second rebases its row order and fixture.

### Task 9: Company deny hosts into `media.RefusedHosts` (T7b)

**Depends on:** Task 5

**Files:** Modify `internal/media/policy.go:27` (`DenyHosts`), `internal/sync/media.go:58`, `internal/media/pipeline.go:189`; Test `internal/media/policy_test.go`.

**Interfaces:** `func DenyHosts(cfg *config.Config, companies []companybundle.Bundle) []string` — build deny + config deny + every stored/forced bundle's `LinkDenyHosts`; callers pass `company.NewStore(ws).LoadAll(forced)` bundles (a load error logs and adds nothing from that file).

- [ ] **Step 1: Failing tests:** `TestDenyHosts_BundleOnlyAdds` (a bundle host is refused; a host refused by config stays refused whatever the bundle says; an empty bundle list changes nothing), `TestRefusedHosts_IncludesForcedBundleHosts`, `TestDenyHosts_DamagedBundleAddsNothing`.
- [ ] **Step 2:** `go test ./internal/media ./internal/sync -run 'DenyHosts|RefusedHosts'` → FAIL; implement; → PASS; `make lint-diff`.
- [ ] **Step 3: Commit** `feat(media): a company bundle's deny list joins the refused hosts (#1887)`.

**Guards:** `go test ./internal/media ./internal/linkrule`, `go test ./internal/sync -run Media`.

---

## Phase 2 — Listener path, connect chain, wizard backend, Publish, C0 (needs Gate G2)

### Task 10: `/company/connect` on the listener + browser pages (T2 listener, C2 Go)

**Depends on:** Task 4, Task 5, Gate G2 (plan B Tasks 6, 7)

**Files:**
- Modify: `internal/oauthpage/oauthpage.go` (+ `oauthpage_test.go`)
- Create: `cmd/company_listener.go`, `cmd/company_listener_test.go`; Modify `cmd/slack_connect.go` (mount the handler on the serve mux; new event)

**Interfaces:**
```go
func CompanyOpen(company string) string             // "Continue in Watchtower" / "Watchtower is asking you to confirm <company>. You can close this tab."
func CompanyRefused(reason companybundle.Refusal) string // heading "This link does not work", reason line, hint (screens §3.4)
func CompanyNeedsNewer() string                      // "This link needs a newer Watchtower" / "Update Watchtower from its menu, then open the link again."
func companyConnectHandler(emit func(any), pending *pendingLinks) http.Handler // GET /company/connect, GET /company/connected
// event (stdout JSON line): {"event":"company_link","flow":"<id>","bundle":"<wire>"}
```
- Reason → text: `damaged` "The link is damaged or cut short."; `too_long` "The link is too long to be a Watchtower company link."; `site_not_https` "The link names a site that is not https."; `personal` "The link carries a personal Google project, which only this Mac can set." Strings equal `CompanySetupMockCopy` page constants (Swift test in Task 23 asserts the Go pages' texts via a fixture `cmd/testdata/company_pages.json` written by `TestCompanyPages_Fixture`).

- [ ] **Step 1: Failing tests** (in-process serve on port 0, `io.Pipe`, `synctest`): `TestCompanyPages_Open`, `TestCompanyPages_RefusedPerReason`, `TestCompanyPages_NeedsNewer`, `TestCompanyPages_Fixture`, `TestCompanyListener_ValidLinkRedirectsClean` (302 → `/company/connected`, one `company_link` event), `TestCompanyListener_RequiresConfirm` (no store file, no OAuth call before a confirm — the §7 "web page opens the link silently" row), `TestCompanyListener_RefusedNothingReachesApp` (bad bundle → refusal page, no event), `TestCompanyListener_LogHasNoBundle` (captured log contains `/company/connect` and not one byte of the wire), `TestCompanyListener_PostAndWrongHostRefused`, `TestCompanyListener_DuplicateLinkWhilePendingIsOne` (Review Focus 2), `TestCompanyListener_PortBusy` (port held → plan B's `port_busy` event; no company path served), `TestSlackConnectPath_StillServed`.
- [ ] **Step 2:** `go test ./internal/oauthpage ./cmd -run 'CompanyPages|CompanyListener|SlackConnect'` → FAIL; implement; → PASS; `make lint-diff`.
- [ ] **Step 3: Commit** `feat(company): /company/connect on the loopback listener (#1887)`.

**Guards:** plan B's `go test ./internal/slackconnect` (`TestOAuthPortRanges_Disjoint`), `go test ./cmd -run 'SlackConnect'`, FILES-01 (`go test ./internal/logredact ./internal/logcanary`).

### Task 11: The connect chain (T2 chain)

**Depends on:** Task 5, Task 7a, Task 7b, Task 10

**Files:** Create `cmd/company_connect.go`, `cmd/company_connect_test.go`; Modify `cmd/slack_connect.go` (stdin cmds), `internal/slackconnect` testdata `serve_events.jsonl` (new events appended).

**Interfaces:**
- One-shot: `watchtower company connect --slug S [--vendors slack,google,atlassian,microsoft,linear] [--json]`.
- Serve child stdin: `{"cmd":"company_connect","flow","slug","vendors":[…]}`, `{"cmd":"company_skip","flow"}`, `{"cmd":"company_stop","flow"}`. Events: `{"event":"company_vendor","flow","vendor","state":"waiting|connected|cancelled|failed|skipped","label","message"}`, `{"event":"company_done","flow","states":{vendor:state}}`, `{"event":"busy","flow"}` (one chain at a time, shared guard with the Slack flow).
```go
type vendorLogin func(ctx context.Context, slug string) (label string, err error) // ErrConsentDenied, ErrSkipped
type chainDeps struct{ logins map[string]vendorLogin; policyAllowed func(source string) bool }
func runCompanyChain(ctx context.Context, d chainDeps, slug string, vendors []string, emit func(any), ctl <-chan chainCmd) map[string]string
```
Order: slack, google, atlassian, microsoft, linear (spec §3 step 2). A policy-forbidden vendor is never run (`skipped`). Same bundle again: `company inspect` already lists connected vendors; the chain is given only unconnected ones.

- [ ] **Step 1: Failing tests** (fake login per vendor): `TestCompanyChain_OrderAndEvents`, `TestCompanyChain_CancelledVendorContinues` (`access_denied` → `cancelled`, next runs), `TestCompanyChain_FailedVendorContinues`, `TestCompanyChain_SkipEndsCurrentOnly`, `TestCompanyChain_StopSkipsRest`, `TestCompanyChain_SecondStartBusy`, `TestCompanyChain_ForbiddenVendorNotRun`, `TestCompanyChain_MicrosoftUsesTenant` (the fake sees the bundle's tenant endpoint), `TestCompanyChain_KillAfterFirstVendor` (cancel ctx after vendor 1 → vendor 1's row `ok` with `company_slug`, others absent; a fresh process: `company inspect` says `connected:{slack:true}`, others false; no auto-resume), `TestCompanyChain_StdinEOFStopsAndReaps`.
- [ ] **Step 2:** `go test ./cmd -run 'CompanyChain'` → FAIL; implement; → PASS; `make lint-diff`.
- [ ] **Step 3: Commit** `feat(company): one press connects every vendor in turn (#1887)`.

**Guards:** `go test ./cmd -run 'SlackConnect|Google|Jira|Linear|Outlook'`, `go test ./internal/slackconnect`.

### Task 12: Wizard draft and discovery (T3 backend, part 1)

**Depends on:** Task 5, Task 6

**Files:** Create `internal/company/draft.go`, `draft_test.go`, `discover.go`, `discover_test.go`; Modify `cmd/company.go` (verbs), `internal/daemon/daemon.go` (startup cleanup of stale `.bad-*`) + test.

**Interfaces:**
```go
type Draft struct {
    Company, Slug string; Services []string; Step string; StartedAt time.Time
    Slack struct{ AppID string }; Google *companybundle.Google; Atlassian *companybundle.Atlassian
    Linear *companybundle.Linear; Microsoft *companybundle.Microsoft; DenyHosts []string
    Skipped []string; Checked map[string]string // vendor → sha256 of the checked values
    MicrosoftWaiting bool
}
type DraftState string // "none", "ok", "unreadable"
func (s Store) LoadDraft(now time.Time) (Draft, DraftState, string /*bad file name*/, error) // unreadable → rename, keep newest .bad only
func (s Store) SaveDraft(d Draft) error; func (s Store) DiscardDraft() error // deletes draft + every .bad-*
func (s Store) CleanStaleBadDrafts(now time.Time) error                      // > 30 days
func CheckHash(vendor string, d Draft) string; func (d Draft) IsChecked(vendor string) bool
type Candidate struct{ Vendor, ClientID, AppID, Label, Source, SourceLabel string; HasSecret bool }
func Discover(ctx context.Context, workspaceDir string, database *db.DB, forced string) ([]Candidate, error)
```
CLI: `company draft show --json` (`{"state","draft","bad_file"}`), `company draft save` (stdin JSON; the Slack config token field is refused if present), `company draft discard`, `company discover --json` (`{"candidates":[…]}`). Sources: `stored` ("Acme's saved company setup"), `draft`, `credentials_file` ("the credentials file of <account>"), `account` ("<vendor> app — your connected account <label>"); our baked shared ids never count.

- [ ] **Step 1: Failing tests:** `TestCompanyDraft_RoundTrip` (0600), `TestCompanyDraft_NeverStoresSlackToken`, `TestCompanyDraft_CorruptRenamed` (state `unreadable`, file `draft.json.bad-<ts>` 0600, original gone, content intact), `TestCompanyDraft_OnlyNewestBadKept`, `TestCompanyDraft_StaleBadDeletedAfter30Days` (fake clock: 29 d kept, 31 d deleted), `TestCompanyDraft_DiscardDeletesBad`, `TestCompanyDraft_CheckHashMismatchIsUnchecked`, `TestCompanyDraft_SameValuesKeepCheck`, `TestDiscover_EverySource` (stored, draft, credentials file, non-shared account, a bridged corp account), `TestDiscover_SharedBakedIDNeverCandidate`, `TestCompanyList_DraftState`, `TestDaemon_CleansStaleBadDraftAtStart`.
- [ ] **Step 2:** `go test ./internal/company ./internal/daemon ./cmd -run 'CompanyDraft|Discover|CompanyList|StaleBadDraft'` → FAIL; implement; → PASS; `make lint-diff`.
- [ ] **Step 3: Commit** `feat(company): wizard draft and known-app discovery (#1887)`.

**Guards:** `go test ./internal/daemon -run 'Startup|Phase'`, `go test ./cmd -run Company`.

### Task 13: Vendor checks (T3 backend, part 2; S28)

**Depends on:** Task 7a, Task 7b, Task 12. S1.6 fixes `classifyDryAuthorize`'s markers; S1.7 the Atlassian refusal reason.

**Files:** Create `cmd/company_check.go`, `cmd/company_check_test.go`, `internal/company/dryauth.go`, `dryauth_test.go`.

**Interfaces:**
- `watchtower company check google|atlassian --json [--replace]` — stdin `{"company","slug","google":{…}|"atlassian":{…}}`; runs the **real sign-in** with the given client (`google add --company` / `jira add --company` internals) after storing nothing; on a token back: in one flow, `Store.Save` the bundle (first check creates `company/<slug>.json` with the company name and this vendor's block; later checks add/update the block), the account row with `company_slug` (same user → same row re-logged: matched by Google `sub` / Atlassian `account_id`), the draft's `Checked[vendor]` hash. A stored block with a different client and no `--replace` → result `replace_needed` before any browser opens. Result `{"result":"ok|rejected|network|cancelled|replace_needed|forced","account_id","email","domain","site","code","message"}`; `forced` when an MDM bundle of this company exists (stored, but its account uses the forced client only if ids match; else marked `company_changed_app`).
- `watchtower company check linear|microsoft --json --client-id X [--tenant T]` — dry authorize. Result `ok|rejected|admin_consent|network` (+ `admin_consent_url` = `https://login.microsoftonline.com/<tenant>/adminconsent?client_id=<id>`).
```go
type DryResult struct{ Result, Code, Message string }
func DryAuthorize(ctx context.Context, hc *http.Client, vendor, clientID, tenantID, redirect string) DryResult
func classifyDryAuthorize(vendor string, status int, location string, body []byte) DryResult
```
- [ ] **Step 1: Failing tests:** `TestCompanyCheck_GoogleIsSignIn` (fake exchange: wrong secret → `rejected` `invalid_client`, nothing stored), `TestCompanyCheck_AtlassianNeedsToken` (no token → no bundle, no row), `TestCheckSignInCreatesCompanyAccount` (row `company_slug`, `company/<slug>.json` holds the vendor block), `TestFirstCheckStoresBundle`, `TestLaterCheckAddsBlock`, `TestCheckOverStoredCompanyNeedsReplace`, `TestEditThenRecheckRelogsSameAccount` (same user id → same row id, new client in its file, bundle updated), `TestCompanyCheck_ForcedCompany`, `TestCompanyCheck_QuitDuringSignInStoresNothing` (ctx cancel mid-wait → no file, no row; the child reaped), `TestDryAuthorize_Classifies` (table from S1.6: Google bad id, Microsoft AADSTS700016 → `rejected`, AADSTS65001 → `admin_consent`, timeout → `network`, Linear bad id), `TestDryAuthorize_NeverFollowsRedirects`.
- [ ] **Step 2:** `go test ./internal/company ./cmd -run 'CompanyCheck|CheckSignIn|FirstCheck|LaterCheck|CheckOver|Recheck|DryAuthorize'` → FAIL; implement; → PASS; `make lint-diff`.
- [ ] **Step 3: Commit** `feat(company): wizard checks by sign-in and dry authorize (#1887)`.

**Guards:** `go test ./cmd -run 'Google|Jira|Linear|Outlook'`, `go test ./internal/jira -run EXT01`.

### Task 14: Publish, Slack reuse wiring, `.mobileconfig` (T5)

**Depends on:** Task 8, Task 12, Gate G2 (plan B Task 9). S1.2 sets the About text order; S1.3 is consumed through plan B's `not_collaborator`.

**Files:** Create `cmd/company_publish.go`, `cmd/company_publish_test.go`, `internal/company/mobileconfig.go`, `mobileconfig_test.go`; Modify `internal/slackapp/manifest.go` (`connectBlock` accepts the company text) + test.

**Interfaces:**
- `watchtower company publish --json` — stdin `{"company":"Acme","config_token":"…"}` (token optional when Slack is not ticked/skipped). Steps as JSON lines `{"step":"pack|write_link","state":"running|done|failed"}`; final `{"result":"ok|no_slack|token_expired|network|refused|atlassian_unchecked","slug","link","code"}`. Order: refuse `atlassian_unchecked` when Atlassian is ticked, not skipped and `!IsChecked("atlassian")`; pack the complete bundle (draft + checked blocks + Slack ids from the setup record by `slack.app_id`) → `Store.Save` → `slackapp` Export/merge `long_description`/Update with "Watchtower for <company> — connect: <link>" + the code (plan B's `slack app link` path, company text) → on `ok` delete the draft and `.bad-*`. `token_expired`/`network` keep everything.
- Slack reuse in the wizard = plan B's `slack app adopt --app-id A` with `A` parsed from `https://api.slack.com/apps/A…`; the company plan adds `wrong_workspace` (the export's team ≠ the token's team) to adopt's results if plan B has not.
- `watchtower company profile --slug S` → prints a `.mobileconfig` (payload domain `com.watchtower.desktop`, forced key `CompanyBundle` = the wire; `PayloadIdentifier` `com.watchtower.company.<slug>`; random `PayloadUUID`s).
```go
func ParseSlackAppSettingsURL(s string) (appID string, ok bool) // ^https://api\.slack\.com/apps/(A[A-Z0-9]+)(/.*)?$
func Mobileconfig(slug string, wire string, newUUID func() string) ([]byte, error)
func AboutText(company, link, code string) string
```
- [ ] **Step 1: Failing tests:** `TestPublish_WritesLinkToDescription` (fake Slack: `long_description` holds the link and code), `TestPublishTokenExpiredKeepsSetup` (fake `token_expired` → draft and bundle intact), `TestPublishNetworkFailureKeepsSetup`, `TestPublish_NoSlackNeedsNoToken`, `TestPublish_AtlassianUncheckedRefused`, `TestPublish_DeletesDraftOnlyOnOK`, `TestPublish_TokenNeverInArgvOrDraft`, `TestReuse_NoCreateWhenAppChosen` (fake `API.Create` call count 0), `TestReuse_WrongWorkspaceRefused`, `TestParseSlackAppSettingsURL`, `TestMobileconfig_GoldenShape` (plist decodes; key `CompanyBundle` = wire), `TestPublish_LongDescriptionUnder4000`.
- [ ] **Step 2:** `go test ./internal/company ./internal/slackapp ./cmd -run 'Publish|Reuse|ParseSlackAppSettings|Mobileconfig'` → FAIL; implement; → PASS; `make lint-diff`.
- [ ] **Step 3: Commit** `feat(company): publish the company link to the Slack app (#1887)`.

**Guards:** plan B's `go test ./internal/slackapp` (`TestManifest_Golden`, `TestAppSetup_*`), `go test ./internal/slackmanifest`.

### Task 15: C0 — `SlackAppSetupModel` (engine, no sheet)

**Depends on:** Gate G2 (plan B Tasks 9, 10). If plan B Task 13 has already shipped, this task only removes the model's sheet ownership and adds the wizard-facing API below.

**Files:** Create (or modify) `WatchtowerDesktop/Sources/WatchtowerCore/Services/Slack/SlackAppSetupModel.swift`; Test `WatchtowerDesktop/Tests/Core/SlackAppSetupModelTests.swift`.

**Interfaces:** plan B Task 13's (`startCreate(token:)`, `startAdopt(token:appID:)`, `startLink(team:token:)`, `checkAgain()`, `reloadRecords()`, `records`), plus `func record(appID: String) -> SetupRecord?` and `var onFinished: ((SlackSetupOutcome) -> Void)?` (`.created(appID)`, `.reused(appID)`, `.failed(SlackSetupFailure)`) for `CompanySetupWizardModel`. Strings per Slack screens spec §3.2 (texts unchanged, screens §2.5).

- [ ] **Step 1: Failing tests:** plan B Task 13's list minus `SlackAppSetupSheetTests`; plus `testSlackStepReadsSetupRecordNotDraft` (the model answers from `slack app status`, never a draft copy), `testMissingRecordRestartsAtLook`, `testResumeAfterCreateOffersReuse`, `testNotCollaboratorKeepsStepOpen`, `testWrongWorkspaceRefused`.
- [ ] **Step 2:** `make test-swift FILTER=SlackAppSetupModelTests` → FAIL; implement; → PASS; `make lint-swift`.
- [ ] **Step 3: Commit** `feat(desktop): Slack app setup engine for the company wizard (#1887)`.

**Guards:** `make test-swift FILTER='SlackConnectListenerHostTests|CLILineStreamTests|LLMTransportGuardTests'`.

---

## Phase 3 — Vendors: PDR, API token, personal Google, retirements

### Task 16: Atlassian Personal Data Reporting phase (T9)

**Depends on:** Task 6, Task 7a

**Files:** Create `internal/atlassianpdr/pdr.go`, `pdr_test.go`, `erase.go`, `erase_test.go`; Create `internal/db/atlassian_people.go` (+ test); Modify `internal/memory/` (new `forget.go`, `forget_test.go`); Modify `internal/daemon/daemon.go` (phase after `phaseExternalSync`, line ~683) + `internal/daemon/atlassian_pdr_test.go`.

**Interfaces:**
```go
const ReportURL = "https://api.atlassian.com/app/report-accounts/"; const ChunkSize = 90; const Every = 7 * 24 * time.Hour
type Status string // "closed", "updated", "ok"
type Reporter interface{ Report(ctx context.Context, ids []string, updatedAt map[string]time.Time) (map[string]Status, error) }
func Run(ctx context.Context, d *db.DB, v *memory.Vault, accountID int64, r Reporter, now time.Time) (Result, error)
func EraseClosed(ctx context.Context, d *db.DB, v *memory.Vault, accountID int64, ids []string) error // one write tx per account
// internal/db
func (db *DB) AtlassianPersonIDs(accountID int64) ([]string, error)       // jira_user_map, issue/comment/changelog authors, ext_users
func (db *DB) EraseAtlassianPeople(tx *sql.Tx, accountID int64, ids []string) error
// internal/memory (P6)
func ForgetAliases(ctx context.Context, v *Vault, d *db.DB, aliases []string) (tombstoned int, err error)
```
- Erase: `jira_user_map` row deleted (email, display name, `slack_user_id`); `ext_users` row deleted; every Jira/Confluence person column for that id (`*_display_name`, `*_email`, `*_slack_id` paired with an `*_account_id` column) set to `''` (the UI shows "Former user" for a bare id); `kb_dirty` rows for the account's Jira and Confluence docs so the next KB pass re-renders; `ForgetAliases(["jira:<id>","confluence:<id>"])`. Free-text derived texts untouched.
- A missing `report:personal-data` scope (403) → `error='pdr_scope_missing'`, `status` unchanged (Swift shows "Re-login to finish the setup" for that code); a later successful report clears it.

- [ ] **Step 1: Failing tests:** `TestPDR_ChunksOf90` (181 ids → 3 calls), `TestPDR_RunsEvery7Days` (fake clock; `last_pdr_at` stamped only on success), `TestPDR_ClosedErasesEveryTable`, `TestPDR_EraseCoversEveryAtlassianPersonColumn` (schema-driven over `schema.sql`: every column pair `<x>_account_id` + `<x>_display_name|_email|_slack_id` in a `jira_*`/`ext_*` table is erased or listed in `pdrKeptColumns` with a reason), `TestPDR_UpdatedRefetchesNextSync`, `TestPDR_ErrorErasesNothing` (network, 401, 403), `TestPDR_ScopeMissingHint`, `TestPDR_KillMidEraseAllOrNothing` (fail inside the tx → nothing changed; next run completes; idempotent), `TestPDR_SharedAppAccountsRunToo`, `TestForgetAliases_TombstonesOrphanKeepsShared`, `TestDaemon_PDRAfterExternalSync`.
- [ ] **Step 2:** `go test ./internal/atlassianpdr ./internal/db ./internal/memory ./internal/daemon -run 'PDR|ForgetAliases|AtlassianPe'` → FAIL; implement; → PASS; `make lint-diff`.
- [ ] **Step 3: Commit** `feat(jira): Atlassian Personal Data Reporting erases closed accounts (#1887)`.

**Guards:** `go test ./internal/memory`, `go test ./internal/kb -run Dirty`, `go test ./internal/db -run 'Purge02|TestAllTablesExist'`, `go test ./internal/daemon -run 'Phase|Cycle'`.

### Task 17: Atlassian API token (T13, D20, D22, D23)

**Depends on:** Task 6, Task 8, Task 16. S1.4 sets `APITokenBaseURL`; S1.5 sets `classifyBulkUser`.

**Files:** Create `internal/jira/apitoken.go`, `apitoken_test.go`; Modify `internal/jira/client.go:58, :160` (auth header per kind, no refresh), `internal/jira/auth.go` (token store holds `{email, api_token}` for `api_token` accounts), `cmd/jira.go` (`jira add --api-token-stdin --email --site`, `jira login --account N --api-token-stdin` re-auth), `cmd/sync.go` (policy stop), `internal/atlassianpdr/lookup.go` (+ test).

**Interfaces:**
```go
type APITokenCreds struct{ Email, Token string }
func APITokenBaseURL(scoped bool, cloudID, site string) string
func NewAPITokenClient(cloudID, site string, creds APITokenCreds) *Client // Authorization: Basic base64(email:token)
func TenantInfo(ctx context.Context, hc *http.Client, site string) (cloudID string, err error) // GET https://<site>/_edge/tenant_info
var ErrNotCloudSite = errors.New("not an Atlassian Cloud site")
type ScopeError struct{ Scope string }
func (c *Client) UsersBulk(ctx context.Context, ids []string) (status int, body []byte, err error) // GET /rest/api/3/user/bulk
// internal/atlassianpdr/lookup.go (atlassianpdr imports jira, never the reverse)
type UserBulkGetter interface{ UsersBulk(ctx context.Context, ids []string) (int, []byte, error) }
func classifyBulkUser(status int, body []byte) map[string]Status // ambiguous → absent
func LookupClosed(ctx context.Context, g UserBulkGetter, ids []string) (map[string]Status, error)
```
- [ ] **Step 1: Failing tests:** `TestJiraClient_AuthHeaderPerKind` (oauth → `Bearer`, api_token → `Basic`), `TestJiraClient_APITokenNeverRefreshes`, `TestJiraAPIToken401IsErrorNotRevoked` (`status='error'`, `error='api_token_dead'`; no revoked purge row: `purge.Plan` shows none), `TestJiraAPIToken403NamesScope`, `TestJiraAdd_APITokenStdinOnly` (no token flag; argv token refused; captured log has no token), `TestJiraAdd_APITokenFillsOwnerFromMyself`, `TestJiraAdd_NotCloudSiteRefusedBeforeStore`, `TestJiraAdd_APITokenNetworkStoresNothing`, `TestJiraLogin_NewTokenClearsError` (stamps `access_ok_at`), `TestJiraAPIToken_PolicyRefusesAdd`, `TestJiraAPIToken_PolicyStopsSyncKeepsData` (POLICY-03), `TestConfluence_APITokenReusesCreds`, `TestTokenLookup_ClosedErased` (7-day lookup → `EraseClosed`), `TestTokenLookup_AmbiguousErasesNothing` (403, error, not found without marker).
- [ ] **Step 2:** `go test ./internal/jira ./internal/atlassianpdr ./cmd -run 'APIToken|AuthHeaderPerKind|TokenLookup|JiraAdd_|JiraLogin_NewToken|Confluence_APIToken'` → FAIL; implement; → PASS; `make lint-diff`.
- [ ] **Step 3: Commit** `feat(jira): connect Jira and Confluence with an API token (#1887)`.

**Guards:** `go test ./internal/jira -run 'EXT01|Revoked'`, `go test ./internal/purge -run Purge01` (esp. `TestPurge01_ErrorStatusWaits`), `go test ./internal/confluence`, FILES-01 (`go test ./internal/jira -run Files01`).

### Task 18: Personal Google project (T8) and `AllowOwnGoogleProject`

**Depends on:** Task 5, Task 7b, Task 8. Task 1 (S2) sets one flag only.

**Files:** Modify `cmd/google.go:138 runGoogleAdd` (thin wrapper over the store), `cmd/sync.go`/`cmd/gmail.go` (policy stop); Create `internal/company/personal.go`, `personal_test.go`.

**Interfaces:**
```go
func SavePersonal(s Store, owner string, g companybundle.Google) (slug string, err error) // personal:true, OriginLocal only
func IsOwnProject(a db.GoogleAccount, entries []Entry, hasLegacyCredentials bool) bool    // personal bundle, or legacy file + company_slug ''
const OwnProjectWeeklyRelogin = false // S2 outcome B → true
```
- `google add --client-id X --client-secret-stdin` → `SavePersonal` (company = the signed-in person's name, else "My Google project") + account `company_slug` = that slug; refused when `!OwnGoogleProjectAllowed()`.

- [ ] **Step 1: Failing tests:** `TestGoogleAddClientID_SavesPersonalBundle`, `TestPersonalNeverFromLinkMDMCode` (via Task 4's Parse), `TestGoogleAddClientID_PolicyRefuses`, `TestOwnProjectPolicy_StopsPersonalKeepsCompanyAndBridged` (personal + legacy-untied stop with data kept; company-bundle and a bridged corp account keep syncing), `TestIsOwnProject_Table`, and if S2 = B: `TestPersonalReloginDueAfter7Days`.
- [ ] **Step 2:** `go test ./internal/company ./cmd -run 'GoogleAddClientID|Personal|OwnProject'` → FAIL; implement; → PASS; `make lint-diff`.
- [ ] **Step 3: Commit** `feat(google): own Google project as a personal bundle (#1887)`.

**Guards:** `go test ./cmd -run 'Google|Gmail|Calendar|Policy'`, `go test ./internal/purge -run Purge01_PolicyForbidden`.

### Task 19: Retirements and banner data (T10, D4, D11, D15)

**Depends on:** Task 7a, Task 7b

**Files:** Modify `cmd/google.go:359 buildGoogleOAuthScopes` (+ the shared-client check), `scripts/build-app.sh` (release guard: a public release must not set `WATCHTOWER_JIRA_CLIENT_ID/SECRET`), `scripts/tests/test-build-app-profile.sh`, `cmd/connections.go` (account JSON gains `shared_gmail`, `shared_atlassian`, `company_slug`), `internal/jira/auth.go` (`SharedAppCutoff`).

**Interfaces:**
```go
func googleScopesFor(src clientSource, wantCalendar, wantGmail bool) ([]string, error) // shared ("baked"/"env" with the baked id) + Gmail → errGmailNeedsOwnProject
var SharedAppCutoff = "" // RFC 3339 date set by the release that ships Phase 5 (D15: +30 days); "" = unknown
```
- [ ] **Step 1: Failing tests:** `TestGoogleShared_CalendarOnly` (shared client never requests `gmail.readonly`; existing shared Gmail rows keep syncing), `TestGoogleShared_GmailRefusedWithHint`, `TestConnectionsJSON_SharedFlags`, `test-build-app-profile.sh`: public profile with a Jira id → fails.
- [ ] **Step 2:** `go test ./cmd -run 'GoogleShared|ConnectionsJSON'`, `make test-scripts` → FAIL; implement; → PASS; `make lint-diff`.
- [ ] **Step 3: Commit** `feat: shared Google is Calendar only; the shared Atlassian app is not baked (#1887)`.

**Guards:** `go test ./cmd -run 'Google|Connections|Jira'`, `make test-scripts`. S3 outcome "obligation" adds the Linear twin here (owner ask first).

---

## Phase 4 — Screens C1–C7 (each UI task ends with the snapshot comparison)

Every UI task: views from `WatchtowerDesktop/Sources/DesignKit/`, colors only through `Tone`, no stock look or row separators, texts from the task's model, the model's strings asserted equal to `CompanySetupMockCopy`; final step `make desktop-shots DESKTOP_SHOTS=build/desktop-shots` and a side-by-side check of each named shot against `docs/design/mockups/company-setup/<shot>-{light,dark}.png` (differences fixed or listed in the PR as intended). Guards for every Swift task: `make test-swift FILTER='<task tests>|CompanySetupMockCopyTests|DesignShotsTests'`, `make lint-swift`; `make test-swift FILTER=LLMTransportGuardTests` when a model runs a CLI.

### Task 20: C6 — `ManagedPolicyHelp` and the IT guide links

**Depends on:** Task 8

**Files:** Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/ManagedPolicyHelp.swift`, `Tests/Core/ManagedPolicyHelpTests.swift`; Modify `OrganizationPolicyPresentation.swift` (+ tests), `Views/Settings/OrganizationPolicySection.swift`, `Views/Settings/ConnectionsSettings.swift` (`SourceBlockedNotice`).

**Interfaces:** `enum ManagedPolicyHelp { static let itGuideURL: URL; static let label = "What IT can set"; static let rowTitle = "IT guide"; static let rowCaption = "Every setting a configuration profile can force, with a sample profile." }`; `OrganizationPolicyPresentation.lines` gains "Atlassian API tokens" and "Own Google projects" → "Allowed"/"Not allowed".

- [ ] **Step 1: Failing tests:** `ManagedPolicyHelpTests.testOneConstant` (grep of `Sources/` finds the URL string only in `ManagedPolicyHelp.swift`), `testURLEqualsGoConstant` (reads `docs/mdm/site.json`, Task 8's golden of `policy.ITGuideURL`, via `#filePath` — one source), `OrganizationPolicyPresentationTests.testNewKeyLines`.
- [ ] **Step 2:** FAIL → implement → PASS. Shots: `company-policy-privacy`, `company-policy-blockedNotice`.
- [ ] **Step 3: Commit** `feat(desktop): IT guide link from one constant (#1887)`.

### Task 21: C1 — `CompanySetupWizardModel` and `CompanyVendorGuide`

**Depends on:** Task 12, Task 13, Task 14, Task 15. Task 3 (S3) decides Linear's admin line.

**Files:** Create `WatchtowerDesktop/Sources/WatchtowerCore/Services/Company/CompanySetupWizardModel.swift`, `CompanyVendorGuide.swift`, `CompanyCLI.swift` (Codable twins of the `company …` JSON); Tests `Tests/Core/CompanySetupWizardModelTests.swift`, `CompanyVendorGuideTests.swift`.

**Interfaces:**
```swift
enum CompanyVendor: String, CaseIterable { case slack, google, atlassian, linear, microsoft }
enum WizardStep: Hashable { case services, vendor(CompanyVendor), denyList, publish }
enum StepMark { case done, reused, skipped, waiting, notStarted }
@Observable final class CompanySetupWizardModel {
    init(cli: CLIRunning, lines: CLILineStreaming, slack: SlackAppSetupModel, now: @escaping () -> Date)
    var steps: [WizardStep]; var current: WizardStep; func marks() -> [WizardStep: StepMark]
    var railNarrowLine: String                 // "Step 3 of 8 · Google"
    func open() async; func leave() async      // draft save; checks keep running
    func toggle(_ v: CompanyVendor) -> DropWarning?; func confirmDrop(_ v: CompanyVendor)
    func choose(_ c: Candidate?); func createNew(); func alreadyHaveOne()
    func check(_ v: CompanyVendor, replace: Bool) async
    func skip(); func back(); func goTo(_ s: WizardStep)
    var publishBlockedReason: String?; func publish(token: String?) async
    func discard() async; var resumeLine: String?; var draftUnreadable: (title: String, body: String, file: String)?
}
enum CompanyVendorGuide { static func servicesRow(_:) -> (title: String, detail: String); static func guideLines(_:) -> [(text: String, link: URL?)]; static func notSure(_:) -> String; static func notUsedLine(_:, skipped: Bool) -> String; static func alreadyHaveFields(_:) -> [FieldSpec]; static func adminNeeds(_:) -> String? }
```
- [ ] **Step 1: Failing tests** (fake CLI per verb): screens §10 Wizard rows and §13 C1 rows: `testServicesNeedOneTicked`, `testDiscoveredServicesArePreTicked`, `testRailListsOnlyTickedServices`, `testUntickFilledStepAsksFirst`, `testUntickEmptyStepDropsSilently`, `testLeavingPageKeepsDraftAndResumesAtStep`, `testCheckInFlightLandsInDraft`, `testLeavingDuringSignInStillConnects`, `testQuitDuringCheckResumesBeforeCheck`, `testFoundAppIsDefault`, `testResumeAfterCreateOffersReuse`, `testNotCollaboratorKeepsStepOpen`, `testWrongWorkspaceRefused`, `testAtlassianStepNeedsSignInToken`, `testAtlassianNeedsAllThreeChecks`, `testPublishDisabledUntilAtlassianChecked`, `testGoogleCheckIsSignIn`, `testCheckSignInCreatesCompanyAccount`, `testFirstCheckStoresBundle`, `testEditingCheckedFieldClearsCheck`, `testSameValuesKeepCheck`, `testPublishDisabledAfterEditOfCheckedStep`, `testEditThenRecheckRelogsSameAccount`, `testEditWithoutRecheckKeepsOldPair`, `testCheckOverStoredCompanyActsAsReplace`, `testDiscardKeepsCheckedAccountsAndBundle`, `testDiscardDeletesDraft`, `testQuitAfterCheckKeepsAccount`, `testUnreadableDraftIsRenamedNotDeleted`, `testUnreadableDraftIsNotNoDraft`, `testMicrosoftWaitingForConsentDoesNotBlockPublish`, `testNoOrgAccessShowsStepsForAdmin`, `testPublishTokenExpiredKeepsSetup`, `testPublishNetworkFailureKeepsSetup`, `testPublishDoneOffersLinkCodeProfile`, `testConnectThisMacOffersOnlyUnconnected`, `testSlackStepReadsSetupRecordNotDraft`, `testMissingRecordRestartsSlackStep`, `testCompanyNameDerived` (Slack name → Google domain label → Atlassian site label, A2), `testTokenNeverInArgv`, `testStringsEqualMockCopy`; `CompanyVendorGuideTests`: `testEveryVendorHasEveryString`, `testDeepLinksAreHttpsOnVendorHost`, `testMCPNoteOpensQuickConnections`, `testEveryVendorNamesItsAdminNeeds`, `testNotUsedLinesVerbatim`.
- [ ] **Step 2:** `make test-swift FILTER='CompanySetupWizardModelTests|CompanyVendorGuideTests'` → FAIL; implement; → PASS; `make lint-swift`.
- [ ] **Step 3: Commit** `feat(desktop): company setup wizard model (#1887)`.

### Task 22: C1 — the wizard page

**Depends on:** Task 21

**Files:** Create `Views/Company/CompanySetupPage.swift`, `CompanySetupRail.swift`, `CompanySetupSteps.swift` (one view per step layout); Modify `App/AppState.swift` (`companySetup`; `ConnectionService` gains `.companySetup`), `Views/Connections/ConnectionsTabView.swift`, `Views/Settings/SlackConnectionDetail.swift` (setup-record rows open the wizard at Slack/Publish, A19; plan B's sheet entry replaced).

- [ ] **Step 1: Failing tests:** `ConnectionsTabTests.testCompanySetupDestination` (selecting it shows the page; ‹ Connections returns and keeps the draft), `CompanySetupPageTests.testNarrowFoldsRail` (width < 520 → one line).
- [ ] **Step 2:** FAIL → implement → PASS.
- [ ] **Step 3: Shots:** re-render every `company-wizard-*` shot from the real views (`DesignShotsTests.testCompanySetupShotsRender` switches those fixtures to the production views); compare with the mockups.
- [ ] **Step 4: Commit** `feat(desktop): company setup wizard page (#1887)`.

### Task 23: C2 — `CompanyConnectFlowModel` and the connect sheet

**Depends on:** Task 11, Task 10 (pages fixture), Gate G2 (plan B Task 10's host)

**Files:** Create `WatchtowerCore/Services/Company/CompanyConnectFlowModel.swift`, `Views/Company/CompanyConnectSheet.swift`; Modify `SlackConnectListenerHost` event decoding (company events), `App/AppState.swift` (`companyConnect`), Slack connect field (accepts a company link or code, A20); Tests `Tests/Core/CompanyConnectFlowModelTests.swift`.

**Interfaces:** `@Observable final class CompanyConnectFlowModel { enum Variant { case link, code, again, mdm }; enum Phase { case confirm, replace([Change]), chain, done }; func receiveLink(_ wire: String); func paste(_ text: String) -> String? /*field error*/; func connectAll(slug: String); func connectRest(slug: String); func relogin(slug: String, vendors: [CompanyVendor]); func toggle(_:); func connect() async; func replace() async; func keepCurrent(); func skipCurrent(); func stop(); var rows: [VendorRow] }`.

- [ ] **Step 1: Failing tests:** `testLinkStartsAtConfirm`, `testSecondLinkWhileRunningIsRefused`, `testCloseKeepsChainRunning`, `testCancelledVendorContinues`, `testChangedBundleNeedsReplace`, `testKeepCurrentIsDefault`, `testForbiddenVendorIsNotRun`, `testPasteRejectsOtherText`, `testSameBundleAgainDisablesConnected`, `testMDMVariantTitle`, `testRowOrderAndDetails` (Jira vs Jira and Confluence), `testGoPagesMatchMockCopy` (reads `cmd/testdata/company_pages.json`), `testStringsEqualMockCopy`.
- [ ] **Step 2:** `make test-swift FILTER=CompanyConnectFlowModelTests` → FAIL; implement; → PASS.
- [ ] **Step 3: Shots:** `company-connect-*`, `company-page-*` (the Go pages rendered into the fixture); compare.
- [ ] **Step 4: Commit** `feat(desktop): connect a company from a link, code or MDM (#1887)`.

### Task 24: C3 — `CompanyConnectionsPresentation`

**Depends on:** Task 5, Task 6, Task 17 (`api_token_dead`), Task 19 (banner flags)

**Files:** Create `WatchtowerCore/Services/Company/CompanyConnectionsPresentation.swift`; Test `Tests/Core/CompanyConnectionsPresentationTests.swift`.

**Interfaces:** `struct CompanyConnectionsPresentation { static func zone(companies:, errors:, draft:, portBusy:, loading:) -> CompaniesZoneState; static func groups(vendor: CompanyVendor, accounts: [AccountRef], companies: [CompanyRef], ownProject: (AccountRef) -> Bool) -> [AccountGroup]; static func rowStatus(_ a: AccountRef, purgeLease: Date?) -> RowStatus; static func banner(_ v: CompanyVendor, accounts:, now:, cutoff:) -> Banner?; static func lockCard(_ key: LockKey) -> LockCard }`.

- [ ] **Step 1: Failing tests:** `testSetupInProgressRow`, `testUnconnectedVendorsShowConnect`, `testPortBusyLine`, `testDamagedFileIsNotEmpty`, `testMDMCompanyIsProminent`, `testInvalidClientRow`, `testUntiedRow`, `testReplacedRow`, `testReloginRowsAreAttentionNotConnectedIsNot` (A5), `testGroupOrder` (company → own project → API tokens → shared → other), `testDeadTokenRowAndLeaseNote` (note only while the lease counts), `testSharedGoogleBanner`, `testSharedAtlassianBanner` (days to cutoff; past → "until Atlassian turns it off"), `testBannersAreNotAttention`, `testOwnGoogleLock`, `testTokenLock`, `testStringsEqualMockCopy`.
- [ ] **Step 2:** FAIL → implement → PASS.
- [ ] **Step 3: Commit** `feat(desktop): company rows, zone and banners presentation (#1887)`.

### Task 25a: C3 — Companies zone, account groups, Slack/Linear/Outlook details

**Depends on:** Task 24, Task 23

**Files:** Create `Views/Connections/CompaniesZone.swift`, `Views/Connections/CompanyAccountGroups.swift`; Modify `Views/Connections/ConnectionsOverview.swift`, `Views/Settings/SlackConnectionDetail.swift`, `LinearConnectionDetail.swift`, `EmailConnectionDetail.swift` (Linear and Outlook off `Form` onto `SettingsSection`s in a `ScrollView`, S24), the view models' company grouping input.

- [ ] **Step 1: Failing tests:** `ConnectionsTabTests.testCompaniesZoneAboveSources`, `testAttentionRuleUnchanged`, `LinearConnectionDetailTests.testNotConnectedRowConnects`.
- [ ] **Step 2:** FAIL → implement → PASS.
- [ ] **Step 3: Shots:** `company-overview-*`, `company-slack-workspaces`, `company-linear-detail`, `company-outlook-detail`; compare.
- [ ] **Step 4: Commit** `feat(desktop): Companies zone and accounts grouped by company (#1887)`.

### Task 25b: C3 — Google and Jira details off `Form`, banners

**Depends on:** Task 24, Task 25a (`CompanyAccountGroups`)

**Files:** Modify `Views/Settings/GoogleConnectionDetail.swift`, `JiraConnectionDetail.swift` (ported onto `SettingsSection`s; Boards, Confluence, Features, User Mapping, Sync ported as they are), the empty states (§5.3, §6.4), loading/read-failed states.

- [ ] **Step 1: Failing tests:** `GoogleConnectionDetailTests.testEmptyStateActions`, `JiraConnectionDetailTests.testEmptyStateActions`, `testReadFailedIsNotEmpty` (both).
- [ ] **Step 2:** FAIL → implement → PASS.
- [ ] **Step 3: Shots:** `company-google-detail*` (except `-locked`, Task 26), `company-jira-detail*` (except `-locked`, `-tokenError`, Task 27); compare.
- [ ] **Step 4: Commit** `feat(desktop): Google and Jira details grouped by company (#1887)`.

### Task 26: C4 — Use my own Google project

**Depends on:** Task 18, Task 20, Task 25b. Task 1 (S2) decides the weekly frame.

**Files:** Create `WatchtowerCore/Services/Company/OwnGoogleProjectModel.swift`, `Views/Settings/OwnGoogleProjectPage.swift`; Modify `Views/Settings/AddGoogleAccountView.swift` (remove "Advanced: custom OAuth client", S19), `GoogleConnectionDetail.swift` (entry, lock card); Test `Tests/Core/OwnGoogleProjectModelTests.swift`.

- [ ] **Step 1: Failing tests:** `testEmptyNeedsJSON`, `testRejectedClient`, `testNetworkNothingSaved`, `testDoneLine`, `testSecretOnStdinOnly`, `testPolicyLockLeavesPage`, `testWeeklyFrameOnlyWhenFlagSet`, `testStringsEqualMockCopy`; `AddGoogleAccountViewTests.testNoCustomClientDisclosure`.
- [ ] **Step 2:** FAIL → implement → PASS.
- [ ] **Step 3: Shots:** `company-ownGoogle-*`, `company-google-detail-locked`; compare.
- [ ] **Step 4: Commit** `feat(desktop): use my own Google project (#1887)`.

### Task 27: C5 — Connect Jira with an API token

**Depends on:** Task 17, Task 20, Task 24, Task 25b

**Files:** Create `WatchtowerCore/Services/Company/AtlassianTokenFormModel.swift`, `Views/Settings/AtlassianTokenSheet.swift`; Modify `JiraConnectionDetail.swift` (add section, dead-token row, lock card); Test `Tests/Core/AtlassianTokenFormModelTests.swift`.

- [ ] **Step 1: Failing tests:** `testConnectDisabledUntilAllThree`, `testUnauthorized`, `testMissingScopeNamesScope`, `testNotCloud`, `testNetwork`, `testDone`, `testReplaceModeReadOnlyEmailSite`, `testTokenOnStdinOnlyAndDropped`, `testPolicyLockClosesSheet`, `testStringsEqualMockCopy`.
- [ ] **Step 2:** FAIL → implement → PASS.
- [ ] **Step 3: Shots:** `company-token-*`, `company-jira-detail-tokenError`, `company-jira-detail-locked`; compare.
- [ ] **Step 4: Commit** `feat(desktop): connect Jira with an API token (#1887)`.

---

## Phase 5 — Bridge, corp build retirement, docs, the IT page

### Task 28: Bridge corp build (T11a)

**Depends on:** Task 5, Task 6, Task 7a, Task 7b, Task 9

**Files:** Create `cmd/company_bridge.go`, `cmd/company_bridge_test.go`, `cmd/testdata/corp_workspace/` (fixture: placeholder ids only); Modify `WatchtowerDesktop/Sources/Services/UpdateService.swift:47-54` (`resolveChannel` gains `companyMigrated: Bool`), `App/AppState.swift` (runs `watchtower company bridge` at launch before the daemon starts, corp flavor only); Test `Tests/Core/UpdateServiceChannelTests.swift` (or the existing UpdateService test file).

**Interfaces:** `watchtower company bridge --json` (no-op unless `BuildFlavor != ""` and baked clients exist) → builds the bundle from the baked Slack/Google/Jira/Microsoft clients + `media.BuildDenyHosts` (company = `BUILD_COMPANY_NAME` ldflag, slug from it), `Encode`s it, `Store.Save`, `SetAccountCompany` on every account whose client is the baked one, writes `<workspace>/company_migrated` last. Idempotent; any failure leaves everything as it was (no marker) and retries next launch. Swift: `static func resolveChannel(flavor:feedURL:clientID:clientSecret:companyMigrated:) -> Channel` — a flavored build with `companyMigrated` false never resolves `.publicGitHub`.

- [ ] **Step 1: Failing tests:** `TestBridge_TiesEveryBakedAccount` (fixture → bridge → `resolve…ForAccount` gives each account its old client; the refresh fake sees the same client id before and after), `TestBridge_Idempotent`, `TestBridge_FailureLeavesNoMarker`, `TestBridge_PublicBuildNoop`, `TestPublic_UntiedUnknownClientReloginNeeded`; Swift `testCorpStaysGatedUntilMigrated`, `testCorpMayTakePublicFeedAfterMigrated`.
- [ ] **Step 2:** `go test ./cmd -run Bridge`, `make test-swift FILTER=UpdateServiceChannelTests` → FAIL; implement; → PASS; `make lint-diff`, `make lint-swift`.
- [ ] **Step 3: Commit** `feat: bridge corp build moves its accounts onto a company bundle (#1887)`.

**Guards:** `go test ./cmd -run 'Google|Jira|Slack|Outlook'`, `make test-scripts`.

### Task 29: Drop the corp flavor (T11b)

**Depends on:** Task 28 released to corp users, and every corp install reporting `company_migrated` (owner's go; not before).

**Files:** Modify `scripts/build-app.sh` (profile selection keeps `ENV_FILE` but the release check refuses a corp profile), `Makefile` (no corp-only ldflags), `scripts/tests/test-build-app-profile.sh`, `UpdateService.swift` (gated channel removed or kept dormant per owner).

What moved where (spec §5): clients → the bundle (Task 28); `PURGE_DEFAULT` → MDM `PurgeRevokedData` (purge is already default-on, #1769), so the `purge.BuildDefault` ldflag goes; `LINK_FETCH_DENY_HOSTS` → the bundle's `link_deny_hosts` (Task 9), so `media.BuildDenyHosts` goes; the gated feed → the public one.

- [ ] **Step 1:** failing script test `corp profile refused for a release`; `make test-scripts` → FAIL; implement; → PASS.
- [ ] **Step 2: Commit** `build: retire the corp build flavor (#1887)`.

### Task 30: Guide, feature notes, inventory (T12, C7)

**Depends on:** Tasks 4–28 merged into the umbrella

**Files:** Modify `docs/guide/concepts/sources-and-accounts.md`, `docs/guide/concepts/managed-by-your-organization.md`, `docs/guide/concepts/privacy.md` (PDR erase scope; derived texts age out), `docs/guide/features/mail.md`, `docs/guide/features/jira-and-linear.md`, `docs/guide/reference/organization-policy.md`, `docs/guide/reference/cli.md` (`company …`, `jira add --api-token-stdin`, `--company` flags); Create `docs/guide/start/company-setup.md`; Create `docs/features/company-setup.md` (+ line in `CLAUDE.md` Feature Notes and summary in `docs/features/README.md`); Modify `docs/features/connections-tab.md`, `mdm-policy.md` (links the IT page), `jira-multi-account.md`, `google-multi-account.md`, `linear.md`; `docs/inventory/README.md` module map (`internal/companybundle`, `internal/company`, `internal/oauthclient`, `internal/atlassianpdr`, `cmd/company*.go`); release checklist line in `.claude/commands/release.md`: "`docs/mdm/keys.json` changed → rebuild the site; set `jira.SharedAppCutoff` = ship date + 30 days (D15)".

- [ ] **Step 1:** write per `docs/guide/WRITING.md` (8 KB cap per page).
- [ ] **Step 2:** `go test ./docs/guide` → PASS.
- [ ] **Step 3: Commit** `docs: company setup guide, feature note and inventory map (#1887)`.

### Task 31: The IT page on the website (T14)

**Depends on:** Task 8 (`docs/mdm/keys.json`)

**Files:** in the website's own repository (not this one): a page rendering its table from this repo's `docs/mdm/keys.json` at build, with type, default, effect per key and a sample `.mobileconfig`. In this repo: set `policy.ITGuideURL` and `docs/mdm/site.json` to the published URL (one commit).

- [ ] **Step 1:** build the page; publish; record the URL.
- [ ] **Step 2:** set the constant; `go test ./internal/policy ./cmd -run 'PolicyKeys|PolicyShow'`, `make test-swift FILTER=ManagedPolicyHelpTests` → PASS.
- [ ] **Step 3: Commit** `feat(policy): IT guide URL (#1887)`.

Owner actions outside code (not tasks): turn Sharing off on the shared Atlassian app 30 days after ship (D15); rotate nothing else.

---

## Lanes

```
Phase 0  T1 (S2, day 1 → day 8+) ║ T2 (S1) ║ T3 (S3)                              — all parallel, manual
Phase 1  T4 ─┬─ T5 ─┬─ T7a ── T7b      T6 (parallel with T4/T5; T7a needs it)
             │      └─ T9
             └─ T8
Phase 2  [Gate G2: plan B T2,T6,T7,T9,T10 in main]
         T10 (T4,T5,G2) ── T11 (T5,T7a,T7b,T10)
         T12 (T5,T6) ── T13 (T7a,T7b,T12; S1.6) ── T14 (T8,T12,G2; S1.2)
         T15 C0 (G2)                                                            — T10/T12/T15 parallel lanes
Phase 3  T16 (T6,T7a) ── T17 (T6,T8,T16; S1.4,S1.5)
         T18 (T5,T7b,T8; S2)   T19 (T7a,T7b)                                    — T16, T18, T19 parallel
Phase 4  T20 (T8) ║ T21 (T12–T15) ── T22 ║ T23 (T10,T11,G2) ║ T24 (T5,T6,T17,T19) ── T25a (T23) ── T25b ── T26 (T18,T20) ║ T27 (T17,T20,T24,T25b)
Phase 5  T28 (T5,T6,T7a,T7b,T9) ── T29 (released + owner's go)   T30 (all)   T31 (T8)
```

## Spec promises → tasks → tests

| Promise (spec) | Task | Tests |
|---|---|---|
| Personal Gmail past 7 days (S2) | 1 → 18, 26 | day-8 refresh; `TestPersonalReloginDueAfter7Days` if B |
| Linear obligations (S3) | 3 → 19, 21 | written finding |
| S1 questions | 2 → 7a, 13, 14, 17 | written finding |
| One bundle format, Go and Swift (T1) | 4 | `TestCompanyBundle_Cases`, `CompanyBundleTests.testSharedFixture` |
| Store, slug, flock, forced overlay | 5 | `TestCompanyStore_*`, `TestSlug_*` |
| Accounts know their company client (T1b) | 6, 7a, 7b | `TestAllTablesExist`, golden, `Test*Resolver_Order`, `TestNoArgumentlessJiraResolver`, `TestJiraAdd_CompanyUsesBundleClient`, `TestJiraAdd_UnknownCompanyFailsBeforeBrowser` |
| Localhost link, one press, Replace (T2) | 10, 11, 23 | `TestCompanyListener_*`, `TestCompanyChain_*`, `TestCompanyConfirm_*`, flow model tests |
| Wizard, texts in models (T3) | 12, 13, 21, 22 | draft/discover/check tests, `CompanySetupWizardModelTests`, `CompanyVendorGuideTests` |
| Existing app reused, never duplicated (D19) | 12, 14, 15, 21 | `TestDiscover_EverySource`, `TestReuse_NoCreateWhenAppChosen`, `testFoundAppIsDefault` |
| Slack page carries the link (T5) | 14 | `TestPublish_WritesLinkToDescription` |
| MDM, code, the two allow keys (T6) | 5, 8, 17, 18, 23 | POLICY-02 rows, `TestJiraAPIToken_Policy*`, `TestOwnProjectPolicy_*`, `testPasteRejectsOtherText` |
| Per-account clients + refreshers (T7) | 7a, 7b | `Test*Refresh_InvalidClientIsError*`, `TestOAuthClientStore_Mode0600` |
| Deny list (T7b) | 9 | `TestDenyHosts_BundleOnlyAdds` |
| Personal Gmail path (T8) | 18, 26 | `TestGoogleAddClientID_SavesPersonalBundle`, `OwnGoogleProjectModelTests` |
| API token (T13, D20, D22, D23) | 6, 17, 27 | `TestJiraClient_AuthHeaderPerKind`, `TestJiraAPIToken401IsErrorNotRevoked`, `TestTokenLookup_*`, `AtlassianTokenFormModelTests` |
| PDR (T9, D17) | 16 | `TestPDR_*`, `TestForgetAliases_*` |
| Retirements + banners (T10) | 19, 24, 25b | `TestGoogleShared_*`, `testShared*Banner` |
| Corp bridge (T11a) / corp gone (T11b) | 28 / 29 | `TestBridge_*`, `testCorpStaysGatedUntilMigrated` / script test |
| Guide (T12, C7) | 30 | `go test ./docs/guide` |
| IT page (T14, D21) | 8, 20, 31 | `TestPolicyKeys_JSONEqualsDocsFile`, `ManagedPolicyHelpTests` |
| C0–C6 screens | 15, 20–27 | model tests + shots compared |
| §7 failures | 10, 11, 12, 13, 14, 16, 17, 28 | named per row in each task |

## Spike answers

| # | Answer | Applied by |
|---|---|---|
| S1.1–S1.7 | _pending (Task 2)_ | 7a, 13, 14, 17, 21 |
| S2 | _pending (Task 1, day 8+)_ | 18, 26 |
| S3 | _pending (Task 3)_ | 19, 21 |

## Self-review (2026-11-18)

- **Coverage:** every row of the parent's §9 and the screens spec's §13 maps to a task above (table "Spec promises → tasks → tests"); every §7 failure row and every screens §10 row is a named test in its task. Not code, so not tasks: D15 (owner turns Sharing off), the "Watchtower not running" row (doc only, Task 30).
- **Unmapped spec assumptions, resolved here:** memory has no `jira:<accountId>` person alias today (P6); "dry authorize URL" has no defined mechanism (P7, S1.6); no stored "issuing client" for Jira/Linear tokens (P5); the bridge needs the company name, which no corp profile carries (`BUILD_COMPANY_NAME` ldflag, Task 28); Slack plan B is unshipped (Gate G2).
- **Types:** `clientSource`, `companyForcedBundle`, `Store.LoadAll(forcedWire)`, `Draft.IsChecked`, `atlassianpdr.Status` are defined once and used with the same names; `classifyBulkUser`/`LookupClosed` live in `internal/atlassianpdr` to avoid an import cycle with `internal/jira`.
- **Review Focus:** each of the five lines has its test in the owning task (Tasks 4, 5, 7b, 9, 10).
