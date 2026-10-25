# Corporate policy through managed preferences Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A company's MDM forces a small set of Watchtower settings through a configuration profile for `com.watchtower.desktop`; Go and Swift both read only the forced values, enforce them at every path, and the Desktop shows them as **Managed by your organization**.

**Architecture:** `internal/policy` (pure `Normalize` + a cgo CoreFoundation reader behind a seam + a 30 s cache) is the only thing Go call sites ask. Swift `ManagedPolicy` in WatchtowerCore is the twin, held equal by one shared JSON fixture. Each enforcement point calls one small helper; nothing rewrites `config.yaml`, nothing deletes data.

**Tech Stack:** Go 1.26 + cgo (`-framework CoreFoundation`), cobra; SwiftUI/WatchtowerCore, DesignKit; goose not needed (no migration).

**Spec:** `docs/superpowers/specs/2026-10-25-mdm-policy-design.md` (approved 2026-10-25, ask #569).

## Global Constraints

- Preference domain: `com.watchtower.desktop` (Go `policy.Domain`, Swift `Constants.bundleID`). Named explicitly by Go.
- Only forced values count: a key is policy only when `CFPreferencesAppValueIsForced(key, domain)` is true. A `defaults write` value is ignored (POLICY-01).
- v1 keys, exact spelling: `AllowedSources`, `MobileSync`, `AllowedQuickConnections`, `AllowAutomationShell`, `AllowedAIProviders`, `AllowClaudeAITools`, `PurgeRevokedData`. Reserved (read, shown, not enforced): `RequireDatabaseEncryption`, `RetentionDays`, `BulkReadLimits`.
- Closed value sets: sources `slack`, `google`, `imap`, `caldav`, `jira`, `linear`; `MobileSync` `allowed` | `workbench_only` | `off`; providers `claude`, `codex`, `ollama`.
- Absent key = no restriction. Wrong type = most restrictive value and a problem reported: array keys → empty array; `MobileSync` → `off`; bool `Allow*` keys → `false`; `PurgeRevokedData` → `true`. Unknown array entries are dropped and reported; an array of only unknowns is the empty array.
- Bool keys accept only a real boolean (plist `<true/>`/`<false/>`, JSON `true`/`false`); an integer `1` is a wrong type on both sides.
- Go cache 30 s; Desktop re-reads on launch, on app activation and every 60 s.
- Tightening never deletes local data and never rewrites `config.yaml` or the Desktop's own `UserDefaults` (POLICY-03); loosening unlocks, never turns anything on.
- No profile = no policy, for every build including corp (Q1). No env var, flag or file fakes a policy.
- Copy, exact: control label **Managed by your organization**; account line **Blocked by your organization**; automation card **Blocked by your organization's policy**. Go errors wrap `policy.ErrNotAllowed` and read `policy: <what> is not allowed by your organization (allowed: <list or none>)`.
- Public repo: fixtures, examples and docs use `acme`, `example.com`, placeholder UUIDs (`00000000-0000-0000-0000-000000000000`); no real ids or paths.
- Inner loop only per task (`go test ./internal/<pkg>`, `make lint-diff`; Swift `make test-swift FILTER=…` + `make lint-swift`). Full gate once per phase by the controller.
- **Swift tasks (10–13) run one lane at a time.** Go tasks 3–9 may run in parallel lanes after Task 1 (each in its own worktree).

## Review Focus

1. **Bool given as an integer** (`<integer>1</integer>` for `AllowAutomationShell`): Swift's `NSNumber` bridges `1` to `true`; both sides must read it as a wrong type → `false`. Pinned by fixture case `bool_as_integer` (Task 1) and run by Swift (Task 10), whose reader distinguishes `CFBooleanGetTypeID()`.
2. **URL prefix boundary** in `AllowedQuickConnections`: `https://mcp.example.com` must not admit `https://mcp.example.com.evil.example/` or `https://mcp.example.comx/`, and never an `http://` connection; host compared case-insensitively. Pinned by `connection_cases` in the fixture (Task 1), run on both sides.
3. **Disallowed provider still configured** (warm `ai session`, daemon pipelines): every call fails with the policy error naming the allowed providers; never a silent switch to an allowed one. Test in Task 8.
4. **Source disallowed then re-allowed**: no backfill row goes `off`, no purge is scheduled for it, no data deleted; re-allowing resumes at the next cycle. Test in Task 5.
5. **Profile removed while the app runs**: controls unlock, the person's stored choices come back, the mobile hub does not start by itself unless `mobileSyncEnabled` was already on. Test in Tasks 10 and 13.

---

### Task 1: `internal/policy` core — keys, Normalize, helpers, cache, shared fixture

Depends on: none

**Files:**
- Create: `internal/policy/policy.go` (types, keys, `Normalize`, methods), `internal/policy/current.go` (seam + cache + package helpers), `internal/policy/errors.go`, `internal/policy/policytest/policytest.go`
- Create: `internal/policy/testdata/policy_cases.json`
- Test: `internal/policy/policy_test.go`, `internal/policy/current_test.go`, `internal/policy/collision_test.go`

**Interfaces:**
- Produces:
  - `const Domain = "com.watchtower.desktop"`; `var Keys = []string{…v1…}`, `var ReservedKeys = []string{"RequireDatabaseEncryption","RetentionDays","BulkReadLimits"}`
  - `type Problem struct{ Key string \`json:"key"\`; Problem string \`json:"problem"\` }` — `Problem` ∈ `wrong_type`, `unknown_value`, `invalid_entry`
  - `type Keyset struct` — JSON tags = the key names; `AllowedSources []string`, `MobileSync *string`, `AllowedQuickConnections []string`, `AllowAutomationShell *bool`, `AllowedAIProviders []string`, `AllowClaudeAITools *bool`, `PurgeRevokedData *bool`; nil marshals `null` (absent), empty slice marshals `[]`.
  - `type Policy struct{ Managed bool \`json:"managed"\`; Domain string \`json:"domain"\`; Keys Keyset \`json:"keys"\`; ReservedNotEnforced []string \`json:"reserved_not_enforced"\`; Errors []Problem \`json:"errors"\` }` — never-nil slices for the last two. This is also the pinned `policy show --json` document (Task 3).
  - `func Normalize(raw map[string]any) Policy` — pure; `raw` holds only forced keys; `Managed` = any v1 or reserved key present.
  - Methods on `Policy`: `SourceAllowed(src string) bool`, `MobileSyncMode() string` (`allowed` when absent), `ConnectionAllowed(kind, url, command string) bool`, `ShellAllowed() bool`, `ProviderAllowed(id string) bool`, `ClaudeAIToolsAllowed() bool`, `PurgeRevokedData() (on, set bool)`, `AllowedList(key string) []string` (for error copy).
  - Package funcs over `Current()`: the same seven names (`SourceAllowed`, `MobileSync`, `ConnectionAllowed`, `ShellAllowed`, `ProviderAllowed`, `ClaudeAIToolsAllowed`, `PurgeRevokedData`).
  - `func Current() Policy` — reads through `reader` (`var reader func() map[string]any`, default from Task 2, empty map until then), caches 30 s on `var now = time.Now`.
  - `var ErrNotAllowed = errors.New("not allowed by your organization")`; `func SourceError(src string) error`, `func ProviderError(id string) error`, `func ConnectionError(name string) error`, `func ShellError() error` — each `fmt.Errorf("policy: %s is not allowed by your organization (allowed: %s): %w", …)`-shaped, `errors.Is(err, ErrNotAllowed)`.
  - `func SetReaderForTesting(r func() map[string]any) (restore func())` — resets the cache both ways.
  - `policytest.Set(t testing.TB, raw map[string]any)` — `SetReaderForTesting` + `t.Cleanup(restore)`. Every other package's tests use only this.

**Matching rule for `ConnectionAllowed`** (the one algorithm the signature does not fix): `kind == "http"`: parse `url` and each entry with `net/url`; allowed when an entry has scheme `https`, the connection's scheme is `https`, hosts equal case-insensitively (port included), and the connection path equals the entry path or starts with it on a `/` boundary (an entry path ending in `/` matches by plain prefix). `kind == "stdio"`: `command` is byte-equal to an entry that is an absolute path. Entries that are neither `https://…` nor absolute paths are dropped by `Normalize` as `invalid_entry`. Absent key → always true; empty → always false.

- [ ] **Step 1: Write the fixture** `internal/policy/testdata/policy_cases.json`:
  `{"cases":[{"name","raw","want"}], "connection_cases":[{"name","allowed","kind","url","command","want"}]}` where `want` is the full `Policy` JSON. Cases, at least: `empty` (managed false, all null); `all_keys_valid`; `allowed_sources_empty_array`; `allowed_sources_unknown_entry` (`["slack","teams"]` → `["slack"]` + `unknown_value`); `allowed_sources_only_unknown` (→ `[]`); `allowed_sources_wrong_type` (`"slack"` → `[]` + `wrong_type`); `mobile_sync_workbench_only`; `mobile_sync_unknown` (→ `"off"` + `unknown_value`); `mobile_sync_wrong_type` (`true` → `"off"`); `bool_as_integer` (`AllowAutomationShell: 1` → `false` + `wrong_type`); `purge_wrong_type` (`"yes"` → `true`); `providers_mixed` (`["claude","gpt"]` → `["claude"]`); `quick_connections_invalid_entry` (`["http://a.example.com","https://mcp.example.com/","relative/bin"]` → `["https://mcp.example.com/"]`); `reserved_present` (`RetentionDays: 30` → `managed: true`, `reserved_not_enforced: ["RetentionDays"]`); `unknown_key_ignored` (`Foo: 1` → managed false). Connection cases: exact host ok; `https://mcp.example.com.evil.example/x` false; `https://mcp.example.comx/` false; `http://mcp.example.com/` false; `HTTPS://MCP.Example.com/a` with entry `https://mcp.example.com` true; path boundary `/api` vs `/apix` false; stdio exact path true, stdio other path false; absent list true; empty list false.

- [ ] **Step 2: Write the failing tests.** `TestPolicy02_SharedFixture` (decode the file, `Normalize(c.Raw)` marshalled == `c.Want` re-marshalled; then every connection case through `Normalize(map{"AllowedQuickConnections": allowed}).ConnectionAllowed`); `TestPolicy01_WrongTypesFailClosed` (table over each v1 key with a wrong-typed value: the helper gives the restrictive answer); `TestPolicy_CurrentCaches30s` (reader counts calls; two `Current()` within 29 s → 1 read, at 31 s → 2); `TestPolicy_ErrorsWrapErrNotAllowed` (`errors.Is`, text contains `allowed: claude, ollama` and `allowed: none` for empty); `TestPolicy01_KeysNeverCollideWithAppDefaults` (walk `WatchtowerDesktop/Sources/**/*.swift`, skip `ManagedPolicy.swift`; no `"<Key>"` literal of `Keys`/`ReservedKeys` appears; every key matches `^[A-Z][A-Za-z]+$`).

- [ ] **Step 3: Run** `go test ./internal/policy` — expect FAIL (undefined).
- [ ] **Step 4: Implement** the files above. `Normalize` accepts JSON numbers (`float64`) and Go ints/`int64` for `RetentionDays` (integral only); `bool` only for bool keys.
- [ ] **Step 5: Run** `go test ./internal/policy && make lint-diff` — PASS.
- [ ] **Step 6: Commit** `feat(policy): #608 managed policy normalize, helpers and shared fixture`

---

### Task 2: cgo CFPreferences reader

Depends on: Task 1

**Files:**
- Create: `internal/policy/reader_darwin.go` (`//go:build darwin && cgo`, `#cgo LDFLAGS: -framework CoreFoundation`), `internal/policy/reader_other.go` (`//go:build !darwin || !cgo`, returns empty map)
- Test: `internal/policy/reader_darwin_test.go`

**Interfaces:**
- Consumes: `Keys`, `ReservedKeys`, `reader` var (Task 1).
- Produces: `func readForced(domain string, keys []string) map[string]any`; `init()` sets `reader = func() map[string]any { return readForced(Domain, append(Keys, ReservedKeys...)) }`.

Approach: `CFPreferencesAppSynchronize(domain)`, then per key `CFPreferencesAppValueIsForced`; only when forced, `CFPreferencesCopyAppValue` and convert: CFString→`string`, CFBoolean (by `CFGetTypeID == CFBooleanGetTypeID`, checked before CFNumber)→`bool`, CFNumber→`int64` or `float64`, CFArray→`[]any`, CFDictionary→`map[string]any`, anything else→`unsupported{}` (a wrong type for `Normalize`). Release every copied object.

- [ ] **Step 1: Write the failing tests** (darwin only): `TestPolicy01_UnforcedValueIgnored` — write `AllowedSources = ["slack"]` with `CFPreferencesSetAppValue` + synchronize into a throw-away domain `com.watchtower.policytest.<random>`, `readForced(thatDomain, Keys)` returns an empty map; clean the value up in `t.Cleanup`. `TestPolicy_ConvertTypes` — exercise the converter directly on CF values built in the test (bool vs number `1`, nested array, dict, CFData → `unsupported`).
- [ ] **Step 2: Run** `go test ./internal/policy -run 'TestPolicy01_Unforced|TestPolicy_Convert'` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `go test ./internal/policy && make lint-diff` — PASS.
- [ ] **Step 5: Commit** `feat(policy): #608 read forced values through CoreFoundation`

The positive path (a real profile) is a manual check listed in the feature note (Task 14): install the example profile, `watchtower policy show --json` reports `managed: true`.

---

### Task 3: `watchtower policy show [--json]` + purge seam

Depends on: Task 1

**Files:**
- Create: `cmd/policy.go`, `cmd/policy_test.go`
- Modify: `internal/purge/enabled.go` (seam), `internal/purge/enabled_test.go`

**Interfaces:**
- Consumes: `policy.Current()`, `policy.PurgeRevokedData`, `policytest.Set`.
- Produces: `policy show` prints the `policy.Policy` JSON as one document (the last stdout line) with `--json`; without it, one line per key: `<Key>: <value in plain words>` or `<Key>: not set`, then `Not enforced in this version: …` and `Profile problems: …` when present. Pinned top-level keys: `managed`, `domain`, `keys`, `reserved_not_enforced`, `errors`; pinned `keys` members = the seven v1 names.
- `internal/purge`: `var policySwitch = policy.PurgeRevokedData` replaces the unset `policy` var; `Enabled` unchanged otherwise.

- [ ] **Step 1: Failing tests.** `TestPolicyShow_JSONKeys` (pins the five top-level and seven `keys` names exactly, as `TestAutomationsCLI_ShowJSONKeys` does); `TestPolicyShow_NoProfile` (`managed: false`, all `keys` null, `errors: []`); `TestPolicyShow_Plain` (a profile with `MobileSync: "off"` prints `MobileSync: off`). `TestPurge01_PolicyOriginFromManagedPreference` in `internal/purge`: `policytest.Set(t, {"PurgeRevokedData": false})` with setting `true` → `(false, OriginPolicy)`; no key → setting wins.
- [ ] **Step 2: Run** `go test ./cmd -run TestPolicyShow && go test ./internal/purge` — FAIL.
- [ ] **Step 3: Implement.** Register `policyCmd` with `PersistentPreRunE` that needs no workspace or database (like `workbench launch-args`).
- [ ] **Step 4: Run** the same + `go test ./cmd -run 'Purge'` (the `accounts purges --json` `enabled_by` path) + `make lint-diff` — PASS.
- [ ] **Step 5: Commit** `feat(policy): #608 policy show and the purge policy origin`

---

### Task 4: `AllowedSources` at the login and add commands

Depends on: Task 1

**Files:**
- Modify: `cmd/accounts.go` (helper next to `refuseLoginDuringPurge`), `cmd/slack.go`, `cmd/google.go`, `cmd/gmail.go`, `cmd/calendar.go`, `cmd/imap.go`, `cmd/outlook.go`, `cmd/caldav.go`, `cmd/jira.go`, `cmd/linear.go`
- Test: `cmd/login_policy_test.go`

**Interfaces:**
- Produces: `func refuseSourceByPolicy(src string) error` (returns `policy.SourceError(src)` when not allowed). Command → source: `slack login|add` → `slack`; `google login|add`, `gmail login`, `calendar login` → `google`; `imap add`, `outlook login` → `imap`; `caldav add|add-ics` → `caldav`; `jira login|add` → `jira`; `linear login|add` (incl. API-key sign-in) → `linear`. Called first in `RunE`, before any network, browser or write.

- [ ] **Step 1: Failing test** `TestPolicyLogin_RefusedBeforeAnyWrite`: table over every command above; `policytest.Set(t, {"AllowedSources": []any{}})`; run the command against a temp workspace; `errors.Is(err, policy.ErrNotAllowed)`, no account row and no token file created. Second case: `AllowedSources: ["slack"]` → `google login` refused, `slack add` reaches its normal next step (stub as the purge test does).
- [ ] **Step 2: Run** `go test ./cmd -run TestPolicyLogin` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `go test ./cmd -run 'TestPolicyLogin|Login|Purge' && make lint-diff` — PASS.
- [ ] **Step 5: Commit** `feat(policy): #608 refuse connecting a source the policy forbids`

---

### Task 5: `AllowedSources` in the daemon's sync phases and the backfill

Depends on: Task 1

**Files:**
- Modify: `internal/daemon/daemon.go` (`phaseSlackSync`, `phaseCalendarSync`, `phaseGmailSync`, `phaseImapSync`, `phaseCalDAVSync`, `phaseJiraSync`, `phaseExternalSync` for Confluence, `phaseLinearSync`), `internal/historybackfill/` runner
- Test: `internal/daemon/policy_sync_test.go`, `internal/historybackfill/policy_test.go`

**Interfaces:**
- Consumes: `policy.SourceAllowed`. Phase → source: Slack `slack`; Calendar + Gmail `google`; IMAP `imap`; CalDAV `caldav`; Jira + Confluence `jira`; Linear `linear`.
- Produces: each phase returns early, before any account is fetched, when its source is not allowed, logging once per change of the verdict (`policy: <source> sync skipped by your organization's policy`). Syncers stay wired. The backfill runner skips rows of a disallowed source without changing their state.

- [ ] **Step 1: Failing tests.** `TestPolicySync_PhaseSkipsDisallowedSource` (daemon with fake syncers per phase; `policytest.Set(t, {"AllowedSources": ["slack"]})`; one cycle → only the Slack fake is called; drop the policy → next cycle calls all — Review Focus 4). `TestPolicyBackfill_SkipKeepsRowState` (a `history_backfill` row for `google` in `running`; policy forbids `google`; one runner pass → row unchanged, not `off`; no purge row scheduled; allow again → the chunk runs).
- [ ] **Step 2: Run** `go test ./internal/daemon -run TestPolicySync && go test ./internal/historybackfill -run TestPolicyBackfill` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `go test ./internal/daemon ./internal/historybackfill && make lint-diff` — PASS.
- [ ] **Step 5: Commit** `feat(policy): #608 the daemon skips a forbidden source and keeps its data`

---

### Task 6: `AllowedQuickConnections` — mounts, add/enable, `mcp()`

Depends on: Task 1

**Files:**
- Modify: `cmd/generator.go` (`mountConnection`), `cmd/connections.go` (`add`, `enable`, `import`), `internal/automations/sdk_mcp.go`
- Test: `cmd/connections_policy_test.go`, `internal/automations/sdk_mcp_policy_test.go`

**Interfaces:**
- Consumes: `policy.ConnectionAllowed(kind, url, command)`, `policy.ConnectionError(name)`.
- Produces: `mountConnection` returns `(_, false)` with unmount reason `policy` for a disallowed connection (after QC-02's checks, never instead of them); `connections add|enable|import` refuse with `ConnectionError`; `mcp()` resolves the server and refuses with a `PolicyError` JS error (Task 7 defines the class) before any call.

- [ ] **Step 1: Failing tests.** `TestQC02_PolicyUnmountsDisallowed` (two enabled connections, policy lists one URL prefix → `loadExternalMCPServersFrom` mounts one; the QC-02 fail-closed cases still unmount the other connection too). `TestPolicyConnections_AddEnableRefused` (`add` of `https://other.example.com` and `enable` of a disallowed one → `ErrNotAllowed`, row unchanged). `TestAutomationMCP_PolicyRefusesBeforeCall` (fake QC caller records nothing; error name `PolicyError`).
- [ ] **Step 2: Run** `go test ./cmd -run 'TestQC02_Policy|TestPolicyConnections' && go test ./internal/automations -run TestAutomationMCP_Policy` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `go test ./cmd -run 'QC02|Connections' && go test ./internal/automations && make lint-diff` — PASS.
- [ ] **Step 5: Commit** `feat(policy): #608 Quick Connections outside the allowed list never mount`

---

### Task 7: `AllowAutomationShell` + policy errors in automations

Depends on: Task 1. Same files as Task 6 in `internal/automations` — run after Task 6 or merge carefully.

**Files:**
- Modify: `internal/automations/errors.go`, `internal/automations/sdk_shell.go`, `internal/automations/` validate path (new `policy_check.go`), `cmd/automations_edit.go` (`validateRecipe`, `runAutomationsConfirm`), `cmd/automations.go` (show/list JSON)
- Test: `internal/automations/policy_check_test.go`, `cmd/automations_test.go`

**Interfaces:**
- Produces:
  - JS error class `PolicyError` (alongside the existing classes) and `var ErrPolicy` wrapping `policy.ErrNotAllowed`. A run that fails on it ends `failed` with that message and never counts toward any auto-disable rule.
  - `func CheckManifestPolicy(m *Manifest, connection func(name string) (kind, url, command string, ok bool)) error` — `shell:` entries → `policy.ShellError()` when shell is off; `mcp:` entries whose named connection exists and is not allowed → `ConnectionError`. Called by `validateRecipe` (validate, save, `draft_automation`/`save_automation` share it) and `runAutomationsConfirm`. Not called by the indexer, so a recipe stays listed (spec §2's "ParseManifest" point is met at these three moments, not at indexing).
  - `shell()` step: `PolicyError` before `AllowShell`.
  - `automations show --json` and `list --json` rows gain pinned key `policy_blocked`: `""`, `"shell"` or `"mcp"`.

- [ ] **Step 1: Failing tests.** `TestAutomationShell_PolicyRefusedAtStep` (shell off → step throws `PolicyError`, no process spawned); `TestAutomationShell_PolicyRefusedAtValidateAndConfirm`; `TestAutomation_PolicyErrorNeverAutoDisables` (three policy-failed runs → still enabled); extend `TestAutomationsCLI_ShowJSONKeys` with `policy_blocked`.
- [ ] **Step 2: Run** `go test ./internal/automations -run 'Policy' && go test ./cmd -run 'TestAutomationsCLI'` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `go test ./internal/automations && go test ./cmd -run 'Automation' && make lint-diff` — PASS.
- [ ] **Step 5: Commit** `feat(policy): #608 shell() and mcp() refused by policy`

---

### Task 8: `AllowedAIProviders` on every AI path

Depends on: Task 1

**Files:**
- Modify: `cmd/generator.go` (`cliGenerator`, `newAIClientWithModel`, `newQueryClient`, `applyProviderOverride`), `cmd/config.go` (`config set ai.provider`, `workbench.default_agent`), `cmd/workbench_launch_args.go`, `internal/automations/sdk_agent.go`, the `ai session` entry in `cmd/`
- Test: `cmd/provider_policy_test.go`, `internal/automations/sdk_agent_policy_test.go`

**Interfaces:**
- Consumes: `policy.ProviderAllowed`, `policy.ProviderError`.
- Produces:
  - `type refusedProvider struct{ err error }` in `cmd/` implementing `digest.Generator` and `ai.Provider`; every method returns `err`. `cliGenerator`, `newAIClientWithModel` and `newQueryClient` return it (or the error) when `cfg.AI.Provider` (after `--provider`) is not allowed — no fallback to another provider.
  - `config set ai.provider <id>` and `config set workbench.default_agent <id>` refuse a disallowed id; `workbench launch-args --agent <kind>` refuses a kind whose provider (`claude`→`claude`, `codex`→`codex`) is not allowed.
  - `agent()` refuses with `PolicyError` (Task 7) when the run's provider is not allowed.
  - The warm `ai session` checks per turn through the 30 s cache and answers the turn with the policy error.

- [ ] **Step 1: Failing tests.** `TestProviderPolicy_GeneratorRefusesNoFallback` (configured `codex`, allowed `["claude"]` → `Generate` error `errors.Is ErrNotAllowed`, text names `claude`; no claude stub process started — Review Focus 3); `TestProviderPolicy_ProviderFlagRefused`; `TestProviderPolicy_ConfigSetRefused` (`config.yaml` unchanged); `TestProviderPolicy_LaunchArgsRefused`; `TestProviderPolicy_SessionTurnRefused`; `TestAutomationAgent_PolicyRefused`. Stubs reap their process group per CLAUDE.md.
- [ ] **Step 2: Run** `go test ./cmd -run TestProviderPolicy && go test ./internal/automations -run TestAutomationAgent_Policy` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same + `go test ./internal/providers` + `make lint-diff` — PASS.
- [ ] **Step 5: Commit** `feat(policy): #608 AI calls refuse a provider outside the allowed list`

---

### Task 9: `AllowClaudeAITools` in the chat

Depends on: Task 1

**Files:**
- Modify: `internal/chat/claudeai.go` (`ClaudeAIAvailability`)
- Test: `internal/chat/claudeai_test.go`

**Interfaces:**
- Produces: when `!policy.ClaudeAIToolsAllowed()`, `ClaudeAIAvailability` returns `(false, "claude.ai tools are turned off by your organization's policy.")`, checked first. The Settings sidecar and the prompt carry the reason unchanged.

- [ ] **Step 1: Failing test** `TestClaudeAIAvailability_PolicyOff` (claude provider, main surface, clean env, policy false → off with that reason; key absent → on).
- [ ] **Step 2: Run** `go test ./internal/chat -run TestClaudeAIAvailability` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `go test ./internal/chat && make lint-diff` — PASS.
- [ ] **Step 5: Commit** `feat(policy): #608 claude.ai tools off by policy`

---

### Task 10: Swift `ManagedPolicy` twin, reader and `ManagedPolicyCenter` — Swift lane

Depends on: Task 1

**Files:**
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Models/ManagedPolicy.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/ManagedPolicyReader.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/ManagedPolicyCenter.swift`
- Modify: `WatchtowerDesktop/Sources/App/AppState.swift` (own the center; refresh on launch and `NSApplication.didBecomeActiveNotification`, 60 s timer)
- Test: `WatchtowerDesktop/Tests/Core/ManagedPolicyTests.swift`, `WatchtowerDesktop/Tests/Core/ManagedPolicyCenterTests.swift`

**Interfaces:**
- Consumes: `internal/policy/testdata/policy_cases.json` (read by path from the repo root, as `ConnectionTestTests` reads `internal/codex/testdata/turn_failures.json`).
- Produces:
  - `package struct ManagedPolicy: Equatable` with `managed`, `allowedSources: [String]?`, `mobileSync: String?`, `allowedQuickConnections: [String]?`, `allowAutomationShell: Bool?`, `allowedAIProviders: [String]?`, `allowClaudeAITools: Bool?`, `purgeRevokedData: Bool?`, `reservedNotEnforced: [String]`, `problems: [ManagedPolicy.Problem]`; `package static func normalize(_ raw: [String: Any]) -> ManagedPolicy`; `package static let none`; methods `sourceAllowed(_:)`, `mobileSyncMode` (`"allowed"` when absent), `connectionAllowed(kind:url:command:)`, `shellAllowed`, `providerAllowed(_:)`, `claudeAIToolsAllowed`, `isLocked(_ key: ManagedPolicy.Key) -> Bool`. `enum Key: String, CaseIterable` = the v1 + reserved names.
  - Bool keys accept a value only when `CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()` (Review Focus 1); this holds for both `CFPreferences` values and `JSONSerialization` output.
  - `package enum ManagedPolicyReader { static func readForced(domain: String = Constants.bundleID) -> [String: Any] }` — `CFPreferencesAppSynchronize`, then `CFPreferencesAppValueIsForced` per `Key`.
  - `@MainActor package final class ManagedPolicyCenter: ObservableObject` — `@Published private(set) var policy: ManagedPolicy`; `init(read: @escaping () -> [String: Any])`; `func refresh()` publishes only on change; `AppState.managedPolicy` exposes it.

- [ ] **Step 1: Failing tests.** `ManagedPolicyTests.testSharedFixture` (every case's `normalize(raw)` encoded to the Go JSON shape equals `want`; every `connection_cases` entry); `testBoolAsIntegerIsWrongType`; `testKeysAreSameAsGo` (`Key.allCases` raw values == the union of fixture key names). `ManagedPolicyCenterTests.testRefreshPublishesOnlyOnChange`; `testProfileRemovedUnlocks` (reader returns a policy then `[:]` → `policy == .none`, `isLocked` false for every key — Review Focus 5).
- [ ] **Step 2: Run** `make test-swift FILTER='ManagedPolicyTests|ManagedPolicyCenterTests'` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same + `make lint-swift` — PASS.
- [ ] **Step 5: Commit** `feat(desktop): #608 ManagedPolicy twin over the shared fixture`

---

### Task 11: DesignKit `ManagedByOrganizationBadge` + Organization policy section — Swift lane

Depends on: Task 10

**Files:**
- Create: `WatchtowerDesktop/Sources/DesignKit/ManagedByOrganizationBadge.swift`, `WatchtowerDesktop/Sources/Views/Settings/OrganizationPolicySection.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/OrganizationPolicyPresentation.swift`
- Modify: `WatchtowerDesktop/Sources/DesignKitCatalog/CatalogPages/ComponentPages.swift` (settings page), `WatchtowerDesktop/Sources/Views/Settings/PrivacySettings.swift`, `WatchtowerDesktop/Tests/DesignShots/` (`DesignShotCatalog`)
- Test: `WatchtowerDesktop/Tests/Core/OrganizationPolicyPresentationTests.swift`

Read `docs/design/desktop-style-guide.md` first: tokens only, `Tone` for colour, no `Divider()` between rows, `SettingsSection`/`SettingRow` from the kit.

**Interfaces:**
- Produces:
  - `public struct ManagedByOrganizationBadge: View` — lock SF Symbol + **Managed by your organization**, `.caption`, `.secondary`; and `public extension View { func managedByOrganization(_ locked: Bool) -> some View }` — `.disabled(locked)` plus the badge under the control and `.help("Managed by your organization")`. Every later lock uses this modifier.
  - `package enum OrganizationPolicyPresentation { static func lines(_ p: ManagedPolicy) -> [Line] }` — one plain-words line per set key (e.g. `Sources you can connect: Slack, Jira`, `iPhone: workbench only`, `AI providers: Claude`), then `Not enforced in this version: …` and `Profile problems: …`.
  - `OrganizationPolicySection` in Settings → System → Privacy, shown only when `policy.managed`.

- [ ] **Step 1: Failing tests** `OrganizationPolicyPresentationTests` (`testNoPolicyNoLines`, `testEachKeyInPlainWords`, `testProblemsAndReservedListed`, `testEmptySourcesSaysNone`).
- [ ] **Step 2: Run** `make test-swift FILTER=OrganizationPolicyPresentationTests` — FAIL.
- [ ] **Step 3: Implement**; add the badge to the catalog's settings page and the section to `DesignShotCatalog` on fixture data.
- [ ] **Step 4: Run** the same + `make lint-swift` — PASS; `make desktop-shots DESKTOP_SHOTS=<scratch dir>` and look at the section.
- [ ] **Step 5: Commit** `feat(desktop): #608 Managed by your organization badge and policy section`

---

### Task 12: Desktop locks — sources, AI, Quick Connections, claude.ai tools, purge, automations — Swift lane

Depends on: Tasks 7, 10, 11

**Files:**
- Modify: `Views/Settings/ConnectionsSettings.swift`, `SlackConnectionDetail.swift`, `GoogleConnectionDetail.swift`, `EmailConnectionDetail.swift`, `CalendarConnectionDetail.swift`, `JiraConnectionDetail.swift`, `LinearConnectionDetail.swift`, `Views/Onboarding/OnboardingConnectStepView.swift`, `Views/Onboarding/OnboardingGoalsStepView.swift`, the sidebar "+ Connect…" row, `Views/Settings/SystemSettings.swift` (`aiProviderPicker`), `WatchtowerCore/Services/AgentChoicePresentation.swift` (`newSessionAgentChoices(available:)`), `WatchtowerCore/Services/ConnectionTest.swift`, `Views/Settings/QuickConnectionsDetail.swift` + `AddExternalConnectionView.swift`, `Views/Settings/ClaudeAIConnectorsSection.swift`, `Views/Settings/PrivacySettings.swift` (purge switch), the automation card view (reads `policy_blocked`)
- Create: `WatchtowerDesktop/Sources/WatchtowerCore/Services/PolicySourceMap.swift`
- Test: `WatchtowerDesktop/Tests/Core/PolicySourceMapTests.swift`, `Tests/Core/AgentChoicePresentationTests.swift` (extend), `Tests/Core/ConnectionTestTests.swift` (extend)

**Interfaces:**
- Consumes: `AppState.managedPolicy`, `.managedByOrganization(_:)`, `policy_blocked` (Task 7).
- Produces:
  - `package enum PolicySourceMap { static func policySource(forAccountKind: String) -> String }` — Slack → `slack`; Google (Gmail, Calendar) → `google`; Email (IMAP, Outlook) → `imap`; CalDAV/ICS calendars → `caldav`; Jira, Confluence → `jira`; Linear → `linear`.
  - Disallowed source: its Connect rows/cards locked, hidden from onboarding's goal → connect list and the sidebar "+ Connect…" menu; an existing account row shows **Blocked by your organization** in place of its sync status.
  - AI: provider picker shows only allowed providers, locked with the badge when the list has one entry or the stored provider is disallowed; `newSessionAgentChoices` drops agent kinds whose provider is not allowed; `ConnectionTest` refuses a disallowed provider with the policy text and never runs the CLI.
  - Quick Connections Add/Enable locked for a connection outside the list; the claude.ai tools section locked off; purge switch locked to the policy value.
  - Automation card: **Blocked by your organization's policy** when `policy_blocked != ""`.
  - Nothing here writes `config.yaml` or `UserDefaults` because of the policy.

- [ ] **Step 1: Failing tests** `PolicySourceMapTests.testEveryAccountKindMaps`; `AgentChoicePresentationTests.testPolicyDropsDisallowedAgent`; `ConnectionTestTests.testPolicyRefusesWithoutRunningCLI`.
- [ ] **Step 2: Run** `make test-swift FILTER='PolicySourceMapTests|AgentChoicePresentationTests|ConnectionTestTests'` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same + `make lint-swift` — PASS; desktop shots of Connections and System → AI with a fixture policy.
- [ ] **Step 5: Commit** `feat(desktop): #608 lock the controls the policy decides`

---

### Task 13: `MobileSync` on the hub — Swift lane

Depends on: Task 10

**Files:**
- Modify: `WatchtowerDesktop/Sources/App/AppState.swift` (`isMobileSyncEnabled`, `setMobileSyncEnabled`, `initMobileHub`), `Sources/App/AppState+MobileHub.swift`, `Sources/Services/MobileHub/SlicePublisher.swift` + `SlicePublisher+Loop.swift`, `Sources/Services/MobileHub/MobileHubCommandDispatcher.swift`, `Sources/Services/MobileHub/PhoneRecordingJobs.swift`, `Views/Settings/MobileSettingsView.swift`
- Test: `WatchtowerDesktop/Tests/…/SlicePublisherPolicyTests.swift`, `MobileHubPolicyTests.swift` (next to the existing SlicePublisher / hub tests)

**Interfaces:**
- Produces:
  - `extension SliceKind { static let workbenchOnly: Set<SliceKind> = [.workbench, .workbenchTarget, .workbenchComment, .terminalSession, .ownerAsk, .sessionReport, .sessionTimeline, .askAlert, .permissionRequest, .sessionChat, .heartbeat, .deviceGrant] }` (Desktop side; `target` and `track` are personal data and stay out).
  - `SlicePublisher` takes `allowedKinds: () -> Set<SliceKind>?` (nil = all). A kind outside it publishes as an empty slice so `SliceDiff` deletes its records on the phone — it is never just skipped.
  - `off`: `isMobileSyncEnabled` is false whatever `mobileSyncEnabled` says, a running hub stops, `initMobileHub` does nothing, the toggle is locked; the stored `mobileSyncEnabled` is untouched.
  - `workbench_only`: relay commands outside the workbench (recording uploads/jobs) are refused with outcome `blocked_by_policy`.
  - Loosening never starts the hub unless `mobileSyncEnabled` is true.

- [ ] **Step 1: Failing tests.** `testWorkbenchOnlyEmptiesOtherKinds` (a fake source with briefing + workbench records; mode `workbench_only` → briefing slice published empty, workbench unchanged); `testOffStopsHubKeepsSetting`; `testLooseningDoesNotStartHubWhenSettingOff` (Review Focus 5); `testRecordingCommandRefusedUnderWorkbenchOnly`.
- [ ] **Step 2: Run** `make test-swift FILTER='SlicePublisherPolicyTests|MobileHubPolicyTests'` — FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same + `make test-swift FILTER=SlicePublisher` + `make lint-swift` — PASS. No Kit change (`make kit-test` not needed).
- [ ] **Step 5: Commit** `feat(desktop): #608 the mobile hub follows MobileSync`

---

### Task 14: Docs — inventory, feature note, CLAUDE.md, guide, example profile

Depends on: Tasks 1–13

**Files:**
- Create: `docs/inventory/policy.md`, `docs/features/mdm-policy.md`, `docs/examples/watchtower-policy.mobileconfig`, `docs/guide/reference/organization-policy.md` (admins), `docs/guide/concepts/managed-by-your-organization.md` (people on the Mac)
- Modify: `docs/inventory/README.md` (module map: `internal/policy`, `ManagedPolicy*` → `policy.md`), `docs/inventory/account-purge.md` (PURGE-01), `docs/inventory/quick-connections.md` (QC-02), `docs/inventory/chat.md` (CHAT-02/03), `docs/inventory/automations.md` (shell/mcp), `docs/features/mobile-companion.md` (POC note), `docs/features/model-provider-registry.md`, `CLAUDE.md` (Feature Notes line), `docs/guide/README.md` (catalogue), `docs/guide/concepts/privacy.md` + `docs/guide/reference/settings.md` + `docs/guide/reference/cli.md` (`policy show`)

Content:
- **POLICY-01** forced values only; wrong types fail closed (guards `TestPolicy01_*`). **POLICY-02** Go/Swift parity through `policy_cases.json` (`TestPolicy02_SharedFixture`, `ManagedPolicyTests.testSharedFixture`). **POLICY-03** tightening never deletes data or rewrites config (`TestPolicyBackfill_SkipKeepsRowState`, `testOffStopsHubKeepsSetting`, `TestProviderPolicy_ConfigSetRefused`). Each amendment entry and the changelog cite "approved 2026-10-25, ask #569".
- Feature note: sources, keys, dual path, enforcement table (key → Go/Swift points from Tasks 3–13), reserved keys documented only, manual checks (install the example profile on a test Mac; `watchtower policy show --json` → `managed: true`; a `defaults write com.watchtower.desktop AllowedSources -array` changes nothing).
- Example profile: Custom Settings payload (`com.apple.ManagedClient.preferences`) for `com.watchtower.desktop` with every v1 key, placeholder UUIDs, `example.com` URLs, comments naming each key; plus, as separate commented payloads, Claude Code (`com.anthropic.claudecode`: `forceLoginMethod` `claudeai`, `forceLoginOrgUUID` placeholder) and Codex (`com.openai.codex`: `requirements_toml_base64` of `allowed_login_methods = ["chatgpt"]`, `allowed_chatgpt_workspaces = ["<workspace-id>"]`), per spec §7.
- Guide pages per `docs/guide/WRITING.md` (under 8 KB, `##`/`###` only, true to the code, bold UI strings). Admin page: what the profile does, key table, sample, pinning the LLM account (spec §7 wording, links to the vendors' docs), checking with `watchtower policy show`. User page: what **Managed by your organization** means, that data stays, where to see the policy.

- [ ] **Step 1:** Write the files.
- [ ] **Step 2: Run** `go test ./docs/guide/ ./internal/kb/ ./internal/chat/`; regenerate the golden with `go test ./internal/chat -run TestBuildSystemPrompt_Golden -update`; `wc -c` both guide pages < 8192; `plutil -lint docs/examples/watchtower-policy.mobileconfig`; `bash scripts/leak-check.sh` over the branch if available.
- [ ] **Step 3: Commit** `docs: #608 policy inventory, feature note, guide and example profile`

---

## Self-review notes

- Spec coverage: §1 → Tasks 1, 2, 10; §2 keys → Tasks 4–9, 12, 13 (reserved: Tasks 1, 3, 11, 14 only); §3 → 1, 3, 10; §4 → 11, 12; §5 → cache (1), daemon per cycle (5), session per turn (8), Desktop refresh (10), hub stop/clean (13), POLICY-03 (5, 8, 13); §6 → no build flag added anywhere; §7 → Task 14; contracts → Task 14.
- Deviation from spec wording, deliberate: the shell/mcp parse-time check is `CheckManifestPolicy` at validate/save/confirm rather than inside `ParseManifest`, so indexing an existing recipe never drops it from the list.
