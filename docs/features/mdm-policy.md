# Corporate policy through managed preferences (board #608, 2026-10-25)

A company that deploys Watchtower through its MDM forces a small set of settings with a configuration profile for the preference domain `com.watchtower.desktop`. Go and Swift read only the **forced** values, enforce them at every path, and the Desktop shows the controls they decide as **Managed by your organization**. Spec: `docs/superpowers/specs/2026-10-25-mdm-policy-design.md` (approved 2026-10-25, asks #569 and #572); plan: `docs/superpowers/plans/2026-10-25-mdm-policy.md`; inventory: `docs/inventory/policy.md` (POLICY-01..03).

## Where the policy comes from

- A Custom Settings payload (`com.apple.ManagedClient.preferences`) for `com.watchtower.desktop`; macOS serves it through `cfprefsd` as the forced layer of the domain. Example: `docs/examples/watchtower-policy.mobileconfig`.
- Only forced values count (`CFPreferencesAppValueIsForced`); a `defaults write` value is ignored. No profile = no policy, for every build including corp.
- Go: `internal/policy` — `Normalize` (pure, fail closed), the helpers on a `Policy` snapshot (`p := policy.Current(); if !p.SourceAllowed(x) { return p.SourceError(x) }`), `Current()` cached 30 s, the CoreFoundation reader (`reader_darwin.go`, cgo) installed only by `main` through `policy.UseSystemReader()`. Tests set a policy with `policytest.Set`.
- Swift: `ManagedPolicy` (twin of `Normalize`, the URL matcher written to follow `net/url`), `ManagedPolicyReader` (empty under XCTest), `ManagedPolicyCenter` on `AppState` (refresh at launch in `initialize()`, on activation, every 60 s; publishes only a change).
- Shared fixture `internal/policy/testdata/policy_cases.json` (POLICY-02), run by `TestPolicy02_SharedFixture` and `ManagedPolicyTests`.
- `watchtower policy show [--json]` — the effective policy, no workspace or database; pinned keys `managed`, `domain`, `keys`, `reserved_not_enforced`, `errors`.

## Keys and where each is enforced

| Key | Go | Swift |
|---|---|---|
| `AllowedSources` (`slack`, `google` = Gmail + Google Calendar, `imap` incl. Outlook, `caldav`, `jira` incl. Confluence, `linear`) | the tool client factories; the reaction poll; `applySourceGuards` wraps every runnable command of the source groups except an explicit exempt list (local reads, settings, logout/remove/disable/purge; `TestPolicyLogin_EverySourceCommandIsGuarded`); one-shot `sync`; each daemon sync phase (`sourceAllowed`, logged once per change); the backfill runner skips without a state change | Connections row lock + **Blocked by your organization** notice, Add/Connect/Re-login locked, onboarding and the sidebar **+ Connect…** row skip it (`PolicySourceMap`) |
| `MobileSync` (`allowed`, `workbench_only`, `off`) | — | `off`: `isMobileSyncEnabled` false, a hub is disabled (stops, removes what it published), at launch with the toggle on the hub is built once to wipe; the stored toggle is kept. `workbench_only`: `SlicePublisher.allowedKinds` publishes the other kinds empty (`SliceKind.workbenchOnly`), phone recordings refused |
| `AllowedQuickConnections` (`https://` prefixes, absolute command paths) | mount (before secrets or listing), `connections add/enable/import/oauth/tools --refresh`, `listConnectionTools`, automation `mcp()` | Add locked when none allowed, Enable locked outside the list, row line |
| `AllowAutomationShell` | `CheckManifestPolicy` at validate/save/confirm (and again at `save_automation` apply), `shell()` throws `PolicyError` before the manifest | automation row chip **Blocked by your organization's policy** (`AutomationPolicyBlock`) |
| `AllowedAIProviders` (`claude`, `codex`, `ollama`) | `providers.Allowed` — automation `session()` (`PolicyError`), a warm Claude session ends when a mounted Quick Connection or its claude.ai mode becomes forbidden, `cliGenerator`/`newAIClient` construct a `refusedProvider`, long-lived holders (`checkedGenerator`, `checkedAIClient`, the instruction miner) check per call, `ai session` at start and per turn, `config set`, `workbench launch-args`, `agent()` runners; never a fallback | picker shows allowed providers (a forbidden stored one marked, with the policy caption; locked only when one provider is allowed and stored), Test Connection refuses without running the CLI, agent menus drop the agent, new/resumed/fresh sessions refused |
| `AllowClaudeAITools` | `ClaudeAIAvailability` off reason first | Settings → Profile → claude.ai tools locked off |
| `PurgeRevokedData` | `purge.Enabled` origin `policy` (PURGE-01) | Privacy switch shows and locks the forced value |

Reserved, read and shown only (`reserved_not_enforced`): `RequireDatabaseEncryption` (#603), `RetentionDays` (#611), `BulkReadLimits` (#606).

## Defaults taken

- A policy-forbidden source is not synced and its data is kept (POLICY-03, Q2): its PURGE-01 lease is held (`purge.PlanWith` with `leaseHeld`, ask #572) — no lease purge is scheduled for its accounts and an open lease row is cancelled. A revoked account still follows the revoked rule.
- `MobileSync = off` disables the hub, which deletes its zones and forgets the linked phones: loosening the policy later starts the hub again (when the owner's toggle is on), but the phone must be paired again.
- A forbidden source's assistant tools refuse at their client factories (`jiraAccountClient` for Jira and Confluence, Linear writes, `slackSenderFactory` for `send_slack_message` and `output.slack`), and the reaction poll (`phaseReactionCommands`, `reaction-commands poll`) skips a forbidden Slack and clears the event seed stamps, so reactions placed while it was forbidden never fire later.
- Resuming a running terminal of a forbidden agent shows it; starting its process (resume, fresh) is refused.

## Manual checks

1. Install `docs/examples/watchtower-policy.mobileconfig` (edit the placeholders) on a test Mac.
2. `watchtower policy show --json` → `managed: true`, the keys as set, `errors: []`.
3. `defaults write com.watchtower.desktop AllowedSources -array` with no profile → `policy show` still says `managed: false`.
4. Settings → System → Privacy shows **Organization policy**; a forbidden source's Connections row shows the lock.
5. Remove the profile: within 60 s (or on the next activation) the controls unlock and the owner's settings are back.
