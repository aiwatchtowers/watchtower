# Corporate policy through managed preferences — design (board #608)

Part of board group #595 (corporate data on the Mac: no exfiltration, company
control). Status: approved by the owner 2026-10-25 (ask #569) with the
recommended answer to every question: Q1 (a) the corp build behaves like any
build, policy only from the MDM; Q2 (a) a now-forbidden connected source stops
syncing, its data is kept; Q3 (a) we restrict the provider only, the account
is forced through the CLIs' own managed settings and the guide says how (§7);
Q4 (a) "workbench only" on the phone = boards, sessions, asks, session chat,
permission requests. The contract amendments (PURGE-01, QC-02, CHAT-02/03,
automations shell/mcp, mobile POC, provider registry) and the new POLICY-01..03
are approved with it. Plan: `docs/superpowers/plans/2026-10-25-mdm-policy.md`.
Builds on #601 (the purge
switch's `policy` seam), #603 (database encryption), and reserves keys for
#606 (bulk-read limits) and #611 (retention).

## Goal

A company that deploys Watchtower through its MDM (Jamf, Kandji, Intune, …)
can force a small set of settings, the way it already does for Chrome, Slack
or Zoom: the person on the Mac sees them as **Managed by your organization**
and cannot change them in the app, in `config.yaml` or with `defaults write`.
The policy closes the paths where company data leaves the perimeter: which
sources may be connected, whether data goes to the phone through a personal
Apple ID, which external MCP servers and automation commands may run, and
which LLM provider receives the texts (the second transfer outside the
company, after the source itself).

Out of scope here: a policy server of our own, per-user policies pushed from
Watchtower, remote wipe, and the features whose keys are only reserved below
(their own boards enforce them).

## What exists today

- **Nothing reads managed preferences.** No `CFPreferences`, `objectIsForced`
  or `/Library/Managed Preferences` anywhere in Go or Swift.
- **Bundle id.** `com.watchtower.desktop` for every build flavor
  (`scripts/build-app.sh` `BUNDLE_ID`, Swift `Constants.bundleID`). This is the
  preference domain an admin targets. The Go CLI and daemon are separate
  binaries with their own (or no) bundle id, so they must name this domain
  explicitly.
- **Settings live in two places.** Go reads `config.yaml` through
  `internal/config` (viper, `mapstructure` keys; the daemon reads it only at
  startup). The Desktop writes `config.yaml` for shared settings and keeps its
  own switches in `UserDefaults.standard` (the same `com.watchtower.desktop`
  domain), e.g. `mobileSyncEnabled`.
- **The purge seam (#601).** `internal/purge/enabled.go`: `Enabled(cfg)`
  returns the switch and its `Origin` — `policy` > `setting`
  (`privacy.purge_revoked_data`) > `build` (`purge.BuildDefault`, ldflags from
  `WATCHTOWER_PURGE_DEFAULT`, on in the corp build) > `default`. The `policy`
  hook is `var policy = func() (on, set bool)`, unset until this board. The
  Desktop shows `enabled_by` from `watchtower accounts purges --json`.
- **Enforcement points that exist:**
  - Sources: the login/add commands (`slack login|add`, `google login|add`,
    `gmail login`, `calendar login`, `imap add`, `outlook login`,
    `caldav add|add-ics`, `jira login|add`, `linear login|add`) and the
    daemon's wiring (`wireSlackSyncers`, `wireGoogleSyncers`,
    `wireImapSyncers`, `wireCalDAVSyncers`, `wireJiraSyncers` incl.
    Confluence, `wireLinearSyncers` in `cmd/sync.go`); Desktop Settings →
    Connections, onboarding Connect cards, the sidebar "+ Connect…" row.
  - Mobile hub: `AppState.isMobileSyncEnabled` / `setMobileSyncEnabled` /
    `initMobileHub`; `SlicePublisher` publishes per `SliceKind` (briefing,
    inbox, digests, people, calendar, transcripts, day plan, accounts,
    workbench, targets, sessions, asks, session chat, permission requests…).
  - Quick Connections: `cmd/generator.go` `loadExternalMCPServers` →
    `mountConnection` (QC-02 allowlist, fail closed), `connections add|enable`;
    a connection is identified by `kind` + `url` (http) or `command` (stdio).
  - Automations: `Manifest.AllowShell` / `AllowMCP` at step time
    (`sdk_shell.go`, `sdk_mcp.go`), `ParseManifest` at validate/save/confirm.
    `mcp(server, …)` resolves `server` to a Quick Connection by name.
  - LLM provider: `cfg.AI.Provider` (+ the `--provider` flag applied in
    `cmd/generator.go`) feeds `cliGenerator` / `newAIClient` / `newQueryClient`;
    the chat provider switch, the automation `agent()` runtime, the Workbench
    agent kind (`claude`/`codex`, `workbench.default_agent`); Desktop Settings
    → System → AI and the Test Connection path, which runs the provider CLI
    itself. The main chat's claude.ai tools (publish + connectors,
    `chat.ClaudeAIAvailability`) are a further transfer on the Claude
    provider.

## Design

### 1. Where the policy comes from

The admin installs a configuration profile with a Custom Settings payload for
the domain `com.watchtower.desktop`. macOS stores it under
`/Library/Managed Preferences/<user>/com.watchtower.desktop.plist` (user
scope) or `/Library/Managed Preferences/com.watchtower.desktop.plist` (device
scope) and serves it through `cfprefsd` as the **forced** layer of that
domain.

- **Only forced values count.** A key is policy only when
  `CFPreferencesAppValueIsForced(key, "com.watchtower.desktop")` is true. A
  value the person wrote with `defaults write` into the same domain is not
  forced and is ignored, so nobody can fake "Managed by your organization".
- **Go reads through cgo CoreFoundation**, not by parsing the plist:
  `CFPreferencesAppSynchronize` + `CFPreferencesCopyAppValue` +
  `CFPreferencesAppValueIsForced` with the domain named explicitly. That is the
  same answer the app gets, with the user/device precedence and caching done
  by `cfprefsd`. cgo is already mandatory (`internal/sqlcipher`). Parsing the
  files directly is the fallback the plan keeps in mind only if a sandbox or
  helper-bundle issue shows up; it would have to re-implement scope
  precedence.
- **Swift reads the same API** (`CFPreferencesAppValueIsForced` with
  `Constants.bundleID`; for the app's own domain this equals
  `UserDefaults.standard.objectIsForced(forKey:)`).
- **Flat PascalCase keys** in the app's domain, as Chrome and Zoom do. They
  can never collide with the Desktop's own camelCase `UserDefaults` keys; a
  test pins that no policy key equals a key the app writes.

### 2. The v1 key set

Absent key = no restriction (today's behaviour). A key with a wrong type is
read as its **most restrictive** value and reported (fail closed).

| Key | Type | Effect |
|---|---|---|
| `AllowedSources` | array of `slack`, `google`, `imap`, `caldav`, `jira`, `linear` | Only these may be connected and synced. `google` = Gmail + Calendar, `imap` includes Outlook sign-in, `jira` includes Confluence. Empty array = no source. |
| `MobileSync` | string `allowed` \| `workbench_only` \| `off` | `off`: no hub, Settings → Mobile locked off. `workbench_only`: the hub publishes only workbench kinds (workbench, targets, comments, sessions, reports, timelines, asks, ask alerts, permission requests, session chat) — no briefing, inbox, digests, people, calendar, transcripts, day plan, accounts. (Q4) |
| `AllowedQuickConnections` | array of strings | Each entry is an `https://` URL prefix (http connections) or an absolute command path (stdio). A connection that matches none is not mounted in any chat, cannot be added or enabled, and `mcp()` in an automation refuses it. Empty array = no Quick Connections. Absent = no restriction. |
| `AllowAutomationShell` | bool | `false`: `shell()` is refused — at validate/save/confirm (`ParseManifest`) and at the step (`AllowShell`). |
| `AllowedAIProviders` | array of `claude`, `codex`, `ollama` | The only providers any path may use: `ai.provider`, `--provider`, the chat switch, `agent()`, Workbench agent kinds, Desktop pickers and Test Connection. If the configured provider is not allowed, AI calls fail with a policy error naming the allowed ones (no silent switch). (Q3 for the account) |
| `AllowClaudeAITools` | bool | `false`: the main chat never offers claude.ai publish or connectors (`ClaudeAIAvailability` returns off with reason `policy`). |
| `PurgeRevokedData` | bool | Feeds #601's `policy` seam: `purge.Enabled` returns it with origin `policy`. |

**Reserved** — named now, read and shown by `policy show`, enforced when the
feature lands (until then listed as "not enforced in this version"):

| Key | Board | Planned effect |
|---|---|---|
| `RequireDatabaseEncryption` | #603 Stage 2/3 | No plaintext database: the Stage 3 encryption step is due at once and cannot be skipped; a plaintext open is refused after it. |
| `RetentionDays` | #611 | Upper bound on the owner's retention setting. |
| `BulkReadLimits` | #606 | Dictionary of upper bounds on the bulk-read limits (key names come with #606). |

### 3. One policy, two readers (dual path)

- **Go: `internal/policy`.** `Normalize(raw map[string]any) Policy` is pure:
  types, closed value sets, fail-closed rules, `Errors []string`,
  `Reserved []string`. `Current() Policy` reads the forced values through a
  `source` seam (cgo on darwin, empty elsewhere; tests swap it) and caches the
  result for 30 s. Small helpers are the only API the call sites use:
  `SourceAllowed(src)`, `MobileSync()`, `ConnectionAllowed(c)`,
  `ShellAllowed()`, `ProviderAllowed(id)`, `ClaudeAIToolsAllowed()`,
  `PurgeRevokedData() (on, set bool)`. `purge`'s `policy` var is set from the
  last one.
- **Swift twin: `ManagedPolicy` in WatchtowerCore** — the same `normalize`
  over `[String: Any]` and the same helpers, plus a reader over
  `CFPreferences`. An `ObservableObject` `ManagedPolicyCenter` on `AppState`
  publishes it to the views.
- **Shared fixture:** `internal/policy/testdata/policy_cases.json` — raw
  dictionaries (as a profile would deliver them, including wrong types,
  unknown values, empty arrays) with the expected normalized policy. Go
  (`TestPolicy_SharedFixture`) and Swift (`ManagedPolicyTests`) both run it;
  the pattern of `internal/codex/testdata/turn_failures.json`.
- **`watchtower policy show [--json]`** — the effective policy, `managed`
  (any forced key), per-key value, `errors`, `reserved_not_enforced`. Pinned
  JSON keys. It is the admin's and support's check, and the Desktop's
  cross-check in tests; the Desktop does not depend on it at run time.

Go enforces everything a Go process does (sync, logins, chat mounts,
automations, AI calls, purge). Swift enforces what only the Desktop does
(mobile hub, Test Connection, the pickers it launches agents from) and locks
the UI. Neither side relaxes what the other refuses.

### 4. What the person sees

- Every control a key decides is disabled with a lock and **Managed by your
  organization** (one DesignKit component, `ManagedByOrganizationBadge`):
  the Connect rows/cards of a disallowed source (hidden from onboarding's
  goal → connect list), the Mobile toggle, Quick Connection add/enable, the AI
  provider picker and agent kind menus, claude.ai tools, the purge switch.
- Settings → System → Privacy gets an **Organization policy** section listing
  the effective keys in plain words (and any profile errors).
- An already connected account of a disallowed source shows "Blocked by your
  organization" instead of its sync status; an automation that needs
  `shell()` or a refused connection shows "Blocked by your organization's
  policy" on its card.
- The user guide gets an admin page with a sample `.mobileconfig` and the key
  table (`docs/guide/`, per `WRITING.md`).

### 5. When the policy changes while running

The policy is re-read, never assumed:

- CLI commands read it once per run. The daemon checks it at the top of every
  cycle and in each sync phase before an account is fetched (the cached read
  is cheap), so a source turned off stops at the next cycle without a
  restart; syncers stay wired. A warm `ai session` and the MCP servers check
  per turn/call through the 30 s cache.
- The Desktop re-reads on launch, on app activation and every 60 s (managed
  preference changes do not reliably post `UserDefaults.didChangeNotification`
  to a running app). A change that tightens applies at once: the hub stops
  (and, for `off` or `workbench_only`, removes the records it may no longer
  publish), controls lock. A change that loosens unlocks; nothing is turned on
  by itself.
- Tightening never deletes local data (Q2) and never rewrites `config.yaml`:
  the stored setting stays and is simply outvoted, so removing the profile
  brings the person's own choices back.

### 6. Corp build vs no profile (Q1)

No profile = no policy: every key absent, behaviour exactly as today, for
every build. The corp build keeps its build-time defaults where they already
are (purge `BuildDefault=on`); it does not bake a policy, so the only way a
company forces something is its MDM — one source of truth, visible in the
admin console.

### 7. Pinning the LLM account (Q3) — verified 2026-10-25

Watchtower restricts only the provider (`AllowedAIProviders`). The account the
provider CLI signs in with is forced by that CLI's own managed settings, which
the admin deploys next to ours. Both claims were checked against the official
docs; both hold, with the precise keys below (the guide uses these words).

- **Claude Code — true.** Managed settings `forceLoginMethod: "claudeai"`
  plus `forceLoginOrgUUID` (the organization id, or a list) require claude.ai
  logins to belong to that organization; Claude Code reports an error for any
  other organization and exits at startup when the credential in use belongs
  to one that is not listed. `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` and
  `apiKeyHelper` credentials are blocked at startup under these keys. Caveat
  for the guide: for a Claude **Console** login `forceLoginOrgUUID` only
  pre-selects the organization and is not verified, so the guide recommends
  `forceLoginMethod: "claudeai"`. The keys must come from device management
  (server-managed settings cannot redirect a first login). Delivery on macOS:
  the `com.anthropic.claudecode` managed preferences domain (a configuration
  profile) or `/Library/Application Support/ClaudeCode/managed-settings.json`.
  `allowedProviders` (Anthropic API, Bedrock, …) is a further managed key.
  Sources: [Authentication — Restrict login to your organization](https://code.claude.com/docs/en/authentication#restrict-login-to-your-organization),
  [Settings reference — forceLoginOrgUUID](https://code.claude.com/docs/en/settings-reference#forceloginorguuid),
  [Deploy managed settings](https://code.claude.com/docs/en/managed-settings).
- **Codex — true, with different key names for the admin.**
  `forced_login_method` (`chatgpt` | `api`) and `forced_chatgpt_workspace_id`
  exist, but they are the user's `config.toml` keys. The admin enforces the
  account with the requirements keys `allowed_login_methods` and
  `allowed_chatgpt_workspaces` in the system `requirements.toml` or through
  macOS MDM (preference domain `com.openai.codex`, key
  `requirements_toml_base64` = the base64-encoded TOML); the user's `forced_*`
  values must satisfy them, and Codex refuses to start when no login method is
  left. Sources: [Config reference](https://developers.openai.com/codex/config-reference)
  (now served at learn.chatgpt.com/docs/config-file/config-reference),
  [Managed configuration — Manage authentication locally](https://developers.openai.com/codex/enterprise/managed-configuration).

Adjustment: the guide names `allowed_login_methods` /
`allowed_chatgpt_workspaces` (requirements) for Codex, not `forced_*`; the
decision (Q3 a) is unchanged.

## Contracts that change

- **PURGE-01** — the `policy` origin becomes real; unchanged otherwise.
- **QC-02** — a connection must also match `AllowedQuickConnections` to be
  mounted, added or enabled; fail-closed rules unchanged.
- **AUTO (shell/mcp)** — `shell()` and `mcp()` gain a policy refusal at parse
  and at step time; a refused step is a policy error, the recipe is not
  auto-disabled.
- **CHAT-02/03 (claude.ai tools)** — a new off reason `policy`.
- **Mobile POC** — `workbench_only` publishes a subset of slice kinds; `off`
  overrides `mobileSyncEnabled`.
- **Model & provider registry** — resolution refuses a provider outside
  `AllowedAIProviders`.
- New inventory entries **POLICY-01** (forced values only; fail closed on bad
  types), **POLICY-02** (Go/Swift parity via the shared fixture),
  **POLICY-03** (tightening never deletes data or rewrites config).

## Questions for the owner

- **Q1. Corp build without a profile** — (a) same as any build: policy only
  from the MDM (recommended); (b) the corp build bakes a restrictive default
  policy that a profile can override; (c) the corp build refuses to run until
  a profile is installed.
- **Q2. An already connected source the policy forbids** — (a) stop sync,
  lock the account, keep the data; #601 purge and #611 retention handle
  deletion (recommended); (b) treat it like a revoked account: #601 schedules
  its purge with the 72 h notice; (c) hide its data in the app until the
  policy allows it again.
- **Q3. The LLM account** — (a) our key restricts the provider only; the
  account is forced through the provider's own managed settings (Claude Code
  managed settings can pin the login organization, Codex its workspace —
  verified, §7), and the guide says so (recommended); (b) an extra key with the allowed
  organization/workspace id that Watchtower checks before each run;
  (c) provider only, no account guidance.
- **Q4. What "workbench only" on the phone keeps** — (a) workbench kinds only:
  boards, sessions, asks, session chat, permission requests (recommended);
  (b) the same plus the calendar; (c) no `workbench_only` in v1, only
  `allowed`/`off`.

## Later

- Account-level allowlists (corp Slack workspace, Google domain, Atlassian
  site), which also let #601 put a lease on corp IMAP accounts.
- Slack write paths of a forbidden `slack` source (reactions, `send_slack_message`, automations' `output.slack`) are not refused in v1; only connecting, syncing and on-demand fetches are.
- `AllowedOllamaURLs` (an allowed Ollama provider may still point at a remote
  server).
- Enforcing the reserved keys with #603, #606 and #611.
- A cryptographic lease (a key share released by a corp service), per #603's
  §7, if it is ever needed.
