# Behavior Inventory — Organization policy (MDM)

> Each item below is a **behavioral contract** that must be preserved.
> Modifying or weakening the protecting test requires explicit approval
> from @Vadym.
>
> AI assistant: when working in `internal/policy/`, `cmd/policy.go`, the
> policy guards (`cmd/accounts.go` `guardSource`, `cmd/provider_policy.go`,
> `internal/providers/policy.go`, `internal/automations/policy_check.go`) or
> `WatchtowerDesktop/Sources/WatchtowerCore/{Models/ManagedPolicy.swift,Services/ManagedPolicy*.swift}`,
> read this file first.

**Module:** `internal/policy/` (keys, `Normalize`, helpers, the CoreFoundation reader, the 30 s cache), `cmd/policy.go` (`policy show`, `policy keys`), the Swift twin `ManagedPolicy` / `ManagedPolicyReader` / `ManagedPolicyCenter` in WatchtowerCore, and the shared fixture `internal/policy/testdata/policy_cases.json`. Feature note: `docs/features/mdm-policy.md`. Board #608, spec `docs/superpowers/specs/2026-10-25-mdm-policy-design.md` (approved 2026-10-25, asks #569 and #572).
**Last full audit:** 2026-10-25

## POLICY-01 — Forced values only, wrong types fail closed

**Status:** Enforced

**Observable:** Only a value the configuration profile forces for `com.watchtower.desktop` is policy. A value written with `defaults write` into the same domain changes nothing and never shows **Managed by your organization**. A key with a wrong type (a boolean given as the integer `1`, a string where an array belongs, a forced key whose value cannot be read) acts as its most restrictive value: no source, no Quick Connection, no provider, no Slack app (`SlackApps` is an array of `{team_id, client_id}` dictionaries; a malformed or repeated-team entry is dropped), MobileSync `off`, shell and claude.ai tools not allowed, background AI not allowed (`AllowBackgroundAI` `false`), purge on, no `PurgeGraceHours` (the standard 72 h notice; a whole number outside 0…720 is refused the same way), no company bundle, Atlassian API tokens and own Google projects not allowed. A `CompanyBundle` the bundle parser refuses from MDM (damaged, too long, carrying `personal`, a newer version) is no company. Unknown array entries are dropped; a list of only unknown entries is the empty list. No profile means no restriction, for every build.

**Mechanism:** Go reads through CoreFoundation (`CFPreferencesAppValueIsForced` per key, then `CFPreferencesCopyAppValue`; CFBoolean told apart from CFNumber by type id; anything unreadable is `unsupported{}`). The reader is installed only by `main` (`policy.UseSystemReader`), never in a test binary. Swift reads the same API (`ManagedPolicyReader`, a forced key without a value is `NSNull`), and the app's reader is empty under XCTest. `Normalize` / `ManagedPolicy.normalize` apply the same fail-closed rules and report each defect.

**Why locked:** A person could otherwise fake or lift a company's restriction with `defaults write`, and a malformed profile would silently allow what it meant to forbid.

**Test guards:**
- `internal/policy/policy_test.go`: `TestPolicy01_WrongTypesFailClosed`, `TestPolicy01_RefusedCompanyBundleIsAbsent`.
- `WatchtowerDesktop/Tests/Core/ManagedPolicyTests.swift`: `companyKeysFailClosed`.
- `internal/policy/reader_darwin_test.go`: `TestPolicy01_UnforcedValueIgnored`, `TestPolicy01_ForcedValuesAreRead`.
- `internal/policy/collision_test.go`: `TestPolicy01_KeysNeverCollideWithAppDefaults`.
- `WatchtowerDesktop/Tests/Core/ManagedPolicyReaderTests.swift` (support).

**Locked since:** 2026-10-25

## POLICY-02 — Go and Swift read the policy the same way

**Status:** Enforced

**Observable:** The Desktop locks exactly what the CLI and the daemon refuse, for every profile: the same normalized keys (`AllowBackgroundAI` rows included: `true`, `false`, a wrong type as `false`, absent; `SlackApps` included: the same entries kept and dropped; the company setup keys `CompanyBundle`, `AllowAtlassianAPIToken`, `AllowOwnGoogleProject` included, the bundle checked by `companybundle.Parse` and `CompanyBundle.parse`; `PurgeGraceHours` included: an integer — a whole real counts — in 0…720 kept, anything else absent), problems and Quick Connection matches (https only, host and port, the path on a `/` boundary, dot segments and encoded separators refused, byte comparisons).

**Mechanism:** One fixture, `internal/policy/testdata/policy_cases.json`, run by both sides; the Swift URL matcher mirrors Go's `net/url` by hand (EscapedPath, host and port rules, control characters).

**Why locked:** A drift lets the UI show a control as allowed that Go then refuses, or worse, lock nothing while Go allows.

**Test guards:**
- `internal/policy/policy_test.go`: `TestPolicy02_SharedFixture`.
- `WatchtowerDesktop/Tests/Core/ManagedPolicyTests.swift`: `sharedFixture`, `sharedConnectionCases`.
- The shared fixture `internal/policy/testdata/policy_cases.json` carries the `SlackApps` cases both twins run (`slack_apps_valid`, `slack_apps_wrong_type`, `slack_apps_bad_entries`, `slack_apps_duplicate_team`, `slack_apps_empty`; plan B Task 5, #1709); removing one weakens POLICY-01/02 for that key.

**Locked since:** 2026-10-25

## POLICY-03 — Tightening never deletes data or rewrites settings

**Status:** Enforced

**Observable:** A tighter policy outvotes the owner's settings without changing them: `config.yaml`, the Desktop's own UserDefaults and the database keep the owner's values, and removing the profile brings them back. A forbidden source stops syncing and keeps its data; its backfill rows keep their state. A forbidden provider fails each AI call with the policy error, never falling back to another. Loosening unlocks and never turns anything on by itself, with one exception: `AllowBackgroundAI = true` stands in for an owner who has not answered the background-AI question; it never overrides the owner's own `paused`, and removing the profile brings the prompt back.

**Mechanism:** Every enforcement point reads the policy and refuses; none writes a setting. `config set` refuses before writing; the daemon's sync phases and the backfill runner skip; the Go hub's `off` stops the hub (removing what it published) but leaves `hub_meta.enabled` (before go hub plan 3 Task 24, the Swift hub's `off` left `mobileSyncEnabled` the same way).

**Why locked:** A profile installed by mistake, or removed, must never cost the owner their configuration or history.

**Test guards:**
- `internal/historybackfill/policy_test.go`: `TestPolicyBackfill_SkipKeepsRowState`.
- `cmd/provider_policy_test.go`: `TestProviderPolicy_ConfigSetRefused`.
- Atlassian API tokens (#1887 Task 17, D24): `cmd/jira_apitoken_test.go::TestJiraAPIToken_PolicyRefusesAdd`, `TestJiraAPIToken_PolicyStopsSyncKeepsData`, `internal/jira/apitoken_test.go::TestJiraClient_APITokenPolicyStopsRequests`.
- Own Google projects (#1887 Task 18, D24): `cmd/google_own_project_test.go::TestGoogleAddClientID_PolicyRefuses`, `TestOwnProjectPolicy_StopsPersonalKeepsCompanyAndBridged`, `TestOwnProjectPolicy_RefusesReloginAndCLISync`, `internal/daemon/account_policy_test.go::TestAccountPolicy_StopsOneAccountKeepsOthers`, `internal/purge/own_google_test.go::TestPurge01_PolicyStoppedOwnGoogleHoldsLease`.
- Go hub (phase 1, **ask #807**), the Go twins: `internal/hub/hub_test.go::TestPolicy03_OffStopsHubKeepsSetting`, `internal/hub/hub_test.go::TestPolicy03_LooseningDoesNotStartHubWhenSettingOff` (`MobileSync` off stops the Go hub and deletes what it published, `hub_meta.enabled` untouched; loosening never starts a hub the owner left off).
- Go hub on a desktop host (phase 3 Task 21), the same meaning over both transports: `internal/hub/resolve_desktop_test.go::TestPolicy03_OffStopsDesktopHostHubKeepsSetting`.

**Locked since:** 2026-10-25

## Changelog

- 2026-11-23 (owner decision 2026-11-23, purge off by default): strengthening, no guard relaxed. POLICY-01 and POLICY-02 gain the key `PurgeGraceHours` (integer 0…720; a non-integer → absent with `wrong_type`, out of range → absent with `unknown_value`, absent = the standard 72 h notice). Fixture rows `purge_grace_hours_*`; `TestPolicy01_WrongTypesFailClosed` gains a row; new guard `TestPolicy_PurgeGraceHoursRange`. Enforcement lives in PURGE-01 (`purge.EffectiveGrace`).
- 2026-11-18 (company setup #1887 Task 17, D24): strengthening, no guard relaxed. POLICY-03 enforcement of `AllowAtlassianAPIToken = false`: `jira add|login --api-token-stdin` refused before stdin is read, every API-token request refused in `internal/jira` (`ErrAPITokenForbidden`), the daemon wires no client for a token account, its PURGE-01 lease is held; row, token file and data kept. Guards `cmd/jira_apitoken_test.go::TestJiraAPIToken_PolicyRefusesAdd`, `TestJiraAPIToken_PolicyStopsSyncKeepsData`, `internal/jira/apitoken_test.go::TestJiraClient_APITokenPolicyStopsRequests`.
- 2026-11-18 (company setup #1887 Task 18, D24): strengthening, no guard relaxed. POLICY-03 enforcement of `AllowOwnGoogleProject = false` for accounts on an own Google project (a `personal` company bundle, or an untied legacy `google_credentials_<id>.json`): `google add --client-id` refused before the secret is read, a re-login and `gmail|calendar sync` of such an account refused, the daemon wires no client for it, and a per-account daemon verdict (`SetAccountSyncAllowed`) skips one wired before the tightening, leaves it out of the history backfill and holds its PURGE-01 lease; row, token, credentials and data kept. Company, bridged corp and shared-client accounts untouched. Guards listed under POLICY-03.
- 2026-11-18 (company setup #1887 Task 8, spec `docs/superpowers/specs/2026-11-17-company-setup-design.md` D9, D24; approved in asks #1476 and D9): strengthening, no guard relaxed. POLICY-01 and POLICY-02 gain the keys `CompanyBundle` (string, the bundle's wire form; wrong type or a bundle `companybundle.Parse` refuses from MDM → absent with a problem), `AllowAtlassianAPIToken` and `AllowOwnGoogleProject` (booleans, default true, wrong type → false). Fixture rows `company_keys_valid`, `company_keys_wrong_type`, `company_bundle_personal_refused`, `company_bundle_damaged`; new guards `TestPolicy01_RefusedCompanyBundleIsAbsent` and Swift `companyKeysFailClosed`. Their enforcement (POLICY-03) lands with the API-token and own-Google-project tasks.
- 2026-11-18 (board #1886, ask #1452): POLICY-01 gains the `AllowBackgroundAI` key (most restrictive value `false`) and POLICY-02's shared fixture its rows (amendments that strengthen). POLICY-03 is amended and the text is loosened by one exception, approved in ask #1452: `AllowBackgroundAI = true` stands in for an owner who has not answered; it never overrides the owner's own `paused`, and removing the profile brings the prompt back. No guard test is relaxed.
- 2026-11-03 (go hub plan 3 Task 24, spec `docs/superpowers/specs/2026-10-31-go-hub-design.md` §13 "Ported guards", approved with the spec; asks #807, #812, #813, #814): the Swift hub is deleted, and POLICY-03's Swift guards in `MobileHubPolicyTests.swift` go with it. Same-meaning Go twins: `testOffStopsHubKeepsSetting` → `internal/hub/hub_test.go::TestPolicy03_OffStopsHubKeepsSetting` and `internal/hub/resolve_desktop_test.go::TestPolicy03_OffStopsDesktopHostHubKeepsSetting`; `testLooseningDoesNotStartHubWhenSettingOff` and `testRetiredLooseningNeverStartsTheSwiftHub` → `internal/hub/hub_test.go::TestPolicy03_LooseningDoesNotStartHubWhenSettingOff` (no Swift hub is left to start). **Retired, no Go twin (owner decision, ask #969 Q1):** `testRetiredOffWipesAPendingSwiftStateAndKeepsSetting` and `testRetiredWipeNeverCreatesOrRepairsKeys` (the `MobileSync = off` wipe of a Swift state not yet handed over) are deleted with the Swift hub and not replaced: there is no `hub adopt --policy-wipe` and no zone deletion. When `MobileSync = off` arrives before the hand-over, what the Swift hub published to iCloud stays there until the owner handles it himself. This is a retirement of those two guards only; every other POLICY-03 guard keeps its meaning. The Mechanism sentence names the Go hub's `hub_meta.enabled`; the Observable text is unchanged.
- 2026-11-03 (go hub plan 3 Task 23, PR #610, ask #956): strengthening, no guard relaxed. The owner's Mobile off now unlinks every phone (as the Swift hub's off did); the policy's off is not the owner's and keeps them: `TestPolicy03_OffStopsHubKeepsSetting` also asserts the linked phone stays after `MobileSync = off`. Text unchanged.
- 2026-11-02 (go hub plan 3 Task 22, PR #605 review): strengthening, no guard relaxed. Two guards for the production branch (the Swift hub retired, the Go hub's hand-over): `MobileSync = off` still wipes a Swift state that has not been handed over yet, and loosening never starts the Swift hub. The two earlier Swift guards stay, on the Swift hub's own branch, until Task 24 maps them to the Go twins.
- 2026-11-02 (Go hub phase 3 Task 21, PR #604): strengthening, no guard relaxed. POLICY-03's Go twin for a desktop host added (`internal/hub/resolve_desktop_test.go::TestPolicy03_OffStopsDesktopHostHubKeepsSetting`): MobileSync off stops the desktop host's hub and deletes what it published (on CloudKit while the bridge still runs, with the recorded identity store), `hub_meta.enabled` untouched. Text unchanged.
- 2026-10-31 (Go hub phase 1, board #1284, **ask #807**): strengthening, no guard relaxed. POLICY-03's Go twins added for the Go hub (`internal/hub`). Text unchanged. Note `docs/features/go-hub.md`.
- 2026-10-25 (board #608, approved 2026-10-25, asks #569 and #572): POLICY-01..03 written with the feature. Amended with it: PURGE-01 (policy origin), QC-02 (allowed list), CHAT-02/03 note (claude.ai tools off reason), AUTO-13 and the `mcp()` path (policy refusals), the mobile POC and the provider registry notes.
- 2026-10-25 (board #608 final review, ask #572): strengthening, no guard relaxed. A policy-forbidden source's PURGE-01 lease is held (POLICY-03 kept as written); new agent sessions are refused in one place for every start path; the tool client factories and the reaction poll refuse a forbidden source; a warm Claude session ends when a mounted Quick Connection or its claude.ai mode becomes forbidden; Go and Swift fold host case ASCII-only and both require a valid IPv6 literal in brackets (fixture cases added).
