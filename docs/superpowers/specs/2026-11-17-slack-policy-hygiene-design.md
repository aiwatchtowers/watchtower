# Slack — Developer Policy hygiene for company mode

**Date:** 2026-11-17 · **Board:** target #1769 (group #1709 "Slack: Full/Live modes") · **Status:** draft, review round 1 fixed; owner decisions from ask #1412

**Parent spec:** `docs/superpowers/specs/2026-11-14-slack-full-and-live-design.md` (D1–D17). **Screens spec of the group:** `docs/superpowers/specs/2026-11-15-slack-full-live-screens-design.md`. **Related notes:** `docs/features/revoke-purge.md`, `db-encryption.md`, `mdm-policy.md`, `slack-multi-account.md`, `developer-surface.md`, `owner-identity.md`.

## Goal

Full mode is each company's own internal Slack app, created from our manifest inside that workspace (parent spec §5). For Slack that is scenario A: only the **Slack App Developer Policy** applies, not the API ToS "third parties" duties (research notes §1). This spec closes the gaps between what that policy asks of an internal app and what Watchtower does today, with the smallest change for each:

1. purge on by default, and deletion within 14 business days after the app is removed;
2. strong encryption of stored Slack data;
3. only the scopes the app uses, each explained;
4. people cards and `find_experts` without surveillance;
5. disclosure of the LLM providers and of what is sent;
6. a privacy policy that says all of it.

Everything stays on the user's Mac (parent D5). Nothing here adds a server.

Out of scope: database encryption Stage 2 + 3 (#603; this work ships the FileVault line as the interim, A22); the legal questions (commercial distribution, template clause, Marketplace) — #1770; Live mode's storage rules — parent D6/D10/D14; Keychain for tokens — #567/#604.

## Decisions

**The group goal and the owner's override.** The group's goal is to stay compliant with Slack "without losing functionality for customers" (comment #871: «быть условно комплайн со слаком без того что мы потерям функционал для кастомеров»). Several cuts below are optional hygiene rather than a quoted requirement: removing **Mark read in Slack** (A9), and the people-card cuts (A12, A13, A15, A16; only the health/protected-characteristic part of A17 maps to a quoted rule, §1). Asked about exactly this conflict in ask #1412, the owner chose the cuts knowingly: «Да, резать всё» (people cards and `find_experts`) and «Принять все» (A3–A11, A18–A20, including Mark read in Slack).

| # | Decision | Source |
|---|---|---|
| P1 | The hygiene items are: purge by default, DB encryption (Stage 2), minimal Slack scopes, people/`find_experts` without surveillance, LLM provider disclosure, deletion within 14 business days after disconnect, privacy policy | target #1769 (owner's backlog item, approved to design) |
| P2 | Everything stays on the Mac; no hub, no hosted service with Slack data | parent D5 (comment #868) |
| P3 | Accounts on the retired shared app follow the purge rules once Slack stops their token | parent D11 (ask #1295) |
| P4 | No client secret anywhere; PKCE for every login | parent D13 |
| P5 | The Full app's manifest asks for "the user scopes of today minus the unused write scopes", no bot user | parent §5.1 (ask #1295) |
| P6 | Live answers stay out of lasting stores (strict) | parent D6 (ask #1296) |
| P7 | Purge on by default in every build, and a removed Slack workspace deleted after 72 h; PURGE-01 and SLACK-01 amended (§12) | ask #1412: «Да, одобряю» |
| P8 | All people-card and `find_experts` cuts as designed, including the migration that clears the stored fields and the two dead tables | ask #1412: «Да, резать всё» |
| P9 | AI text that mixes sources stays after a purge, and the guide and the privacy policy say so | ask #1412: «Оставлять и сказать об этом» |
| P10 | The agent decisions A3–A11 and A18–A20 accepted as proposed | ask #1412: «Принять все» |

### Decisions proposed by the agent, approved in ask #1412

| # | Decision | Why | Source |
|---|---|---|---|
| A1 | The purge switch defaults to **on** in every build. When on only by the default (origin `default`), it covers the revoked rule and removed accounts; the 30-day lease of live accounts runs only when the switch is on by the setting, the policy or the corp build profile | Slack asks for deletion after the app is removed, not after inactivity. Without this split, a public user who paused Slack in Watchtower would lose the data 72 h after upgrading | ask #1412 |
| A2 | A **removed** Slack account gets a zero lease: the first purge pass after `slack remove` schedules it due now + 72 h (reason `lease`, no migration). Other sources keep today's 30-day removed lease | Removing the account in Watchtower is the user's deletion request; 72 h keeps PURGE-01's notice and is far under 14 business days | ask #1412 |
| A3 | `slack remove` calls `auth.revoke` on the token before deleting the token file, best effort. Consequence: `auth.revoke` ends the user's authorization of that app, not one file, so every other place using it — another Mac, a headless host with a copied token — stops reaching Slack, sees a revoked token and (purge on) deletes its copy after its own 72 h notice. The Remove dialog says so | Slack then sees the app removed for that user; today the token stays valid after a remove | ask #1412 |
| A4 | After a purge's last step, `purge.Run` counts what each step's predicate still matches; a non-zero count ends the row `failed` with the table names | "Deleted" becomes a checked fact, not an assumption | ask #1412 |
| A5 | Drop `channels:write`, `groups:write`, `mpim:write` (19 → 16 requested scopes); keep `im:write` | The three are used only by the Desktop's legacy `conversations.mark` call; `im:write` is needed by `conversations.open` for a DM sent with Approve | ask #1412 |
| A6 | Add `emoji:read` to the manifest (16 → 17 in the Full app); a token without it skips the emoji sync after its first `missing_scope`, no re-consent | `emoji.list` runs every cycle today without the scope and fails; the Desktop renders custom emoji | ask #1412 |
| A7 | Keep `team:read` | `team.info` gives the id, name and domain; deriving them from `auth.test`'s URL saves one low-risk scope at an Enterprise Grid risk | ask #1412 |
| A8 | Keep `users:read.email` | Cross-source identity (Jira, Google, Linear, calendar attendees), `find_experts` by git author email, sending by email | ask #1412 |
| A9 | Remove **Mark read in Slack** from the digest detail and the Desktop's `SlackService` | It reads a legacy single-account token from the config and needs the dropped write scopes | ask #1412 |
| A10 | One manifest source: Go embeds `slack-app-manifest.json`; `auth.UserScopes` is read from it; the Full setup (parent T7) sends the same file | Today the manifest and `oauth.go` disagree (19 vs 15 scopes) | ask #1412 |
| A11 | No forced re-consent for existing tokens; their wider grants stay until the next login, and the code never calls the methods behind them | A re-login for removing scopes would cost every user a login for no new data access | ask #1412 |
| A12 | People cards lose: active hours, volume change, average length, the stats grid, red flags, comparisons with team norms, the Jira+Slack "burnout"/"bottleneck" compound signals, and the Team Summary's "Needs attention" list. They keep: summary of work topics, communication guide, decision role, tactics, highlights, accomplishments, and a "Based on N messages in M channels" basis line | §5.1's definition of surveillance | ask #1412 |
| A13 | Cards are made only for people the owner works with directly in the window (a DM or group DM together, a thread both wrote in, a mention either way), plus the owner's own card | Derived from synced messages; replaces "everyone with ≥ 3 messages" | ask #1412 |
| A14 | **Stop card for this person** on the person view: the card is deleted and never made again; **Make cards again** undoes it. No new MDM key | The owner can honour a colleague's request; the feature switch already turns cards off entirely | ask #1412 |
| A15 | A migration clears the dropped fields in stored `people_cards` and deletes the legacy `user_analyses` and `user_interactions` rows (no code writes them any more); the dead `analysis.legacy_mode` key goes; People → Connections shows only the org links the owner entered | Old profiling data does not outlive the change | ask #1412 |
| A16 | `find_experts` drops `active_hours` from its output; evidence, weights and DEV-03 unchanged | Presence is not evidence about a topic | ask #1412 |
| A17 | The people prompt gets fixed rules: no health, mood, burnout, workload judgment, personal life, protected characteristics, or performance verdicts; work topics and how to collaborate only | Marketplace AI guidance and the Developer Policy profiling clause | ask #1412 |
| A18 | Until Stage 2 ships, Connections → Slack and Settings → System → Privacy show whether FileVault is on (`fdesetup status`, read by the app, no question asked) | The policy asks for strong encryption; FileVault is what protects the files today | ask #1412 |
| A19 | Disclosure lives in four places: the manifest's `long_description` (scope reasons, AI providers, privacy link), the Full setup confirm, the guide, and the privacy policy | Each place where an admin or a user decides | ask #1412 |
| A20 | Privacy policy changes are a text list in §7, applied in the site's repo (separate from this one) | The site is not in this repo | ask #1412 |

### Agent decisions after the spec review, approved in ask #1416

| # | Decision | Recommendation / why | Source |
|---|---|---|---|
| A21 | The purge decides per account, not per source: one `purge.Rules` function gives each account its rule (full, revoked + removed only, or none), used by the scheduling pass, the re-plan before a start, and the start's SQL re-check (§2, "Per-account rules") | The existing `leaseHeld` seam holds whole sources, so "live accounts held, removed ones due" cannot be expressed with it; the re-plan in `purge.start` would otherwise refuse every zero-lease row | ask #1416: «Принять все» (review finding 3) |
| A22 | Database encryption (Stage 2 + 3) is out of scope of this work and stays tracked in #603 with its own plans and gate; the FileVault line (A18) is the interim here, removed when Stage 2 ships | Stage 2 is a large, separately designed project parked by the owner (ask #497); bundling it would block the rest | ask #1416: «Принять все» (review finding 7) |
| A23 | The privacy policy's deletion sentence names the switch and both of its states (§7, item 2) | It must be true for an owner who turned the purge off | ask #1416: «Принять все» (review finding 5) |
| A24 | Task H3 also updates the embedded developer skill `watchtower-who-to-ask` and checks `get_person`'s output (§5.3, "Readers") | Both name the dropped fields today | ask #1416: «Принять все» (review finding 6) |
| A25 | The existing login (baked, env or custom client id) never requests `emoji:read`; only apps made from the manifest get it at their own connect | Slack refuses a user scope the app does not declare, and those apps predate the scope | ask #1464 ("do not ask existing apps") |

## 1. What Slack asks of an internal app

Sources: the Slack App Developer Policy, effective 2024-12-10 (<https://docs.slack.dev/developer-policy>), and the Slack Marketplace guidelines' "AI components" section (<https://docs.slack.dev/slack-marketplace/slack-marketplace-app-guidelines-and-requirements>); both are summarised in the private research notes (outside the repo) §1 and §12, the policy text checked verbatim in their 2026-11-14 sources. The API ToS "Data Usage by Third Parties" and "Transparency & Reporting by Third Parties" sections bind apps offered outside the developer's organisation; Full is a customer-built internal app, so they are good practice here, not duties (research §1, §13).

| Item | Developer Policy text | Section |
|---|---|---|
| Encryption | "Data must be stored and served using strong encryption." | Security |
| Deletion | "When a User deletes your Application or if you discontinue your Application you must delete all associated Data within 14 business days" | Use of Data |
| Scopes | "Requesting and using scopes not required for your Application's functioning. Use only the appropriate and necessary scopes and clearly define the need for scopes within your Application's description" | Use of Data |
| Profiles | "Exploiting Data to create User profiles other than that which is necessary for the Application to function" | Use of Data |
| Surveillance | "Accessing Data for surveillance purposes. You may not allow or assist any entity to conduct surveillance" | Use of Data |
| Combining | "Combining Data with data gathered from other sources for any purposes unrelated to the use of the Application" | Use of Data |
| Third parties | "Renting, selling or sharing Data with third parties under any circumstances" | Use of Data |
| Training | "Using Data to train an LLM under any circumstances" | Use of Data |
| Privacy policy | "a publicly-available and easily accessible privacy policy that explains how the Application collects, uses, processes and stores Data, and what control Users have over their Data" | Use of Data |
| Consent | "Collecting, storing, and/or using Data without obtaining proper consent" | Use of Data |
| AI rules (Marketplace guidelines) | model, retention and use by the LLM, tenancy, residency; an inaccuracy disclaimer; no training; "DON'T allow AI to explicitly predict or categorize users based on protected characteristics, in a manner that could result in harm" | Marketplace, AI components |
| Reach of the guidelines | "We require Applications and developers to follow this policy as well as all other Slack guidelines and policies including … [Submission Guidelines]" — the Marketplace app guidelines bind every app, listed or not | Developer Policy, "A few additional requirements" |

Reading for a local app: the "Data" lives on the user's Mac, not with us. The duties still fall on the app's behaviour, because the app is what stores, processes and sends the data.

## 2. Purge by default and deletion within 14 business days

### Today

- `purge.Enabled` (`internal/purge/enabled.go`): policy > `privacy.purge_revoked_data` > the build default (`WATCHTOWER_PURGE_DEFAULT`, `on` only in the corp profile) > **off**. The public build never deletes (research §2; `docs/features/revoke-purge.md`).
- When on: a revoked account (`invalid_auth`, `account_inactive`, `token_revoked`, `not_authed` — `revokedSlackErrors`, `internal/sync/orchestrator.go`) is purged 72 h after the first pass that sees it; a live source unreached for 30 days and a removed account unreached for 30 days are leased out (30 d + 72 h).
- `slack remove` keeps the data (SLACK-01) and never calls `auth.revoke`, so the token stays valid at Slack.
- A purge keeps AI text that mixes sources (PURGE-02): briefings, Catch-Up recaps, ideas, memory, chats, automation outputs, transcripts.

### What triggers the 14-business-day deletion

| Trigger | How Watchtower learns it | Rule |
|---|---|---|
| The workspace admin removes or deletes the company app | the next Slack call fails with a revoked code | revoked: due 72 h after the first pass that sees it |
| The user removes the app from their Slack account | same | revoked |
| The user removes the account in Watchtower (`slack remove`) | the account row turns `removed` | A2: due 72 h after the first pass; A3 revokes the token at Slack |
| We discontinue an app (the retired shared app, parent D11) | Slack refuses its tokens | revoked (P3) |
| The user deletes Watchtower | `brew uninstall --zap --cask watchtower`, or **Reset All Data…** | the folders go; the guide says so (no uninstall hook exists on macOS) |

Worst case on a running Mac: one sync cadence (≤ 60 min, parent D16) + 72 h + the purge itself (5-minute budget per cycle, resumable) — about 4 calendar days, well under 14 business days. A Mac that is off cannot learn anything; the data then sits encrypted (§3) and the clock starts at its first cycle. The guide says so.

### Proposal

1. **Default on (A1).** `purge.Enabled` falls back to `true` with origin `default`, for every source and every build. With origin `default` the 30-day lease of live accounts is held per account (A21, below); the revoked rule and the removed-account rules run. The owner can still turn it off in Settings → System → Privacy unless a policy forces it.
2. **Removed Slack account (A2).** In `leaseDeadlines`, a removed Slack account's deadline is its `access_ok_at` (zero lease) instead of `access_ok_at + Lease`; since every due date is at least 72 h after the scheduling pass, it is due 72 h after the first pass after the removal. Re-adding the account cancels it (existing rule).
3. **Revoke on remove (A3).** `removeSlackAccount` calls `auth.revoke` with the token, then deletes the token file and sets `removed` (SLACK-01's order otherwise unchanged). A failed revoke is logged and shown in the CLI output ("Slack did not confirm the token was revoked; it may stay valid until a workspace admin removes the app"), never blocks the remove.
4. **Verified deletion (A4).** `PurgeSteps` gains a count form of each step (same predicate, `SELECT count(*)`, read-only transaction). After the last step `purge.Run` runs them; zero everywhere → `done`; otherwise `failed` with `error = "left: <table>=<n>, …"`. The Connections line already shows a failed purge.
5. **Copy.** The Remove dialog, the Privacy switch caption and the guide's revoked-access page say the new rules (§8 lists the strings).

### Per-account rules (A21)

Today `PlanWith(accounts, open, enabled, now, leaseHeld func(source string) bool)` holds or releases a whole source, and `purge.start` re-plans one row with plain `Plan(accounts, current, true, now)` before `db.StartAccountPurge(id, now − Lease)`. Neither can say "this source's live accounts are held, its removed account is due after 72 h", and the re-plan would refuse a zero-lease row (it re-computes the 30-day lease and finds the row not due, so `ErrNoLongerDue` forever).

The change replaces the switch and the source seam with one per-account function:

```go
type Rule int // RuleNone, RuleRevokedAndRemoved, RuleFull
func Rules(on bool, origin Origin, sourceAllowed func(string) bool) func(db.PurgeAccount) Rule
```

| Switch, origin | Live account | Removed account | Revoked account |
|---|---|---|---|
| off | none (open rows cancelled, as today) | none | none |
| on, origin `default` | no lease (held) | Slack: zero lease (due 72 h after the first pass); others: today's 30-day removed lease | 72 h |
| on, origin `setting`, `policy` or `build` | today's 30-day lease | same as above | 72 h |
| any, source forbidden by policy (POLICY-03) | lease held (today's `leaseHeld`) | lease held | 72 h |

The code paths that change together, in one task (H1):

- `internal/purge/enabled.go`: the `default` fallback becomes on; `Rules`.
- `internal/purge/schedule.go`: `Plan`/`PlanWith` take the rules function instead of `enabled` + `leaseHeld`; `leaseDeadlines` computes a deadline per account from its rule (a removed Slack account under any "on" rule: `access_ok_at`, so the 72 h floor makes it due 72 h after the scheduling pass); the cancel branch cancels an open row whose account's rule no longer schedules it.
- `internal/purge/schedule.go` `Apply` and `internal/daemon/account_purge.go` (both passes): build the rules from `purge.Enabled` and `policy.SourceAllowed`.
- `internal/purge/run.go` `start`: re-plans with the same rules, and passes the row's own cutoff (`purge.Cutoff(account, rule, now)`: `now − Lease` today, `now` for a zero-lease removed account).
- `internal/db/account_purge_steps.go` `StartAccountPurge(id, cutoff, requireRemoved bool)`: a zero-lease row starts only while the account is still `removed` (an "add again" between the re-plan and the start must win), checked in the same conditional `UPDATE`.
- `cmd/accounts.go` `accounts purges --json`: `enabled_by` already says `default`; no new key. The Desktop's footnote (`AccountPurgeStatus.footnote`) picks its text from `enabled`/`enabled_by` (§8).
- The Desktop's second reader of the default: `PrivacySettings` (`WatchtowerDesktop/Sources/Views/Settings/PrivacySettings.swift`) shows `policy ?? config.purgeRevokedData ?? accountPurgeCenter.status.enabled ?? false`. With the key absent and the CLI's status not loaded yet (or failed), it would show **off** while the daemon deletes. The fallback moves into one WatchtowerCore function, `AccountPurgeStatus.shownValue(policy:setting:status:)`, whose last step is `AccountPurgeStatus.buildDefault` (`true`, the same as Go's `default` fallback), and the caption then reads "On by default". Go and Swift read one shared fixture, `internal/purge/testdata/default_cases.json` (policy, setting, build default, CLI status → shown value and origin), run by Go `TestPurge01_DefaultSharedFixture` (against `purge.Enabled`) and Swift `AccountPurgeDefaultFixtureTests` (against `shownValue`), the `policy_cases.json` pattern (POLICY-02).

Tests: `TestPurgeRules_Table` (every row of the table above), `TestPlan_DefaultOriginHoldsLiveLeaseButSchedulesRemovedSlack`, `TestRun_ZeroLeaseRowStartsAfterReplan`, `TestStartAccountPurge_ZeroLeaseNeedsRemovedStill`, `TestPurge01_PolicyForbiddenSourceHoldsLease` (unchanged, must still pass).

### Upgrade impact

On the first daemon start after the upgrade with the key absent, a public install starts purging revoked and removed Slack accounts, each after the full 72 h notice (Home banner, the Connections line, a notification). An account revoked months ago gets the same 72 h (the PURGE-01 deviation already guarantees it). Disabled-but-live accounts are not touched (A1).

## 3. Encryption at rest

### Today

- Stage 1 shipped: one SQLCipher engine in Go and Swift, every file still plaintext (`docs/features/db-encryption.md`).
- Stage 2 (the key, Secure Enclave–wrapped, data-protection Keychain) and Stage 3 (one-time encryption of existing installs) are designed (`docs/superpowers/specs/2026-10-21-db-encryption-design.md`) but parked: the owner closed the G1–G4 gate check on 2026-10-25 as not a priority (ask #497).
- Slack tokens are 0600 JSON files (#567/#604). The privacy policy says the database is protected "when enabled, macOS full-disk encryption (FileVault)".

### Gap

The policy's "strong encryption" is met today only when FileVault is on, and Watchtower neither checks nor says it.

### Proposal

1. **Interim (A18).** A small `FileVaultStatus` reader (`fdesetup status`; on/off/unknown, read at launch and on activation, never asked). Off → Connections → Slack shows "FileVault is off: Slack data on this Mac is not encrypted at rest. Turn it on in System Settings → Privacy & Security." with an **Open settings** button; Settings → System → Privacy shows the same line. Unknown shows nothing. Read-only; nothing is blocked.
2. **Stage 2 + 3 are out of scope here (A22).** They stay tracked in #603 with their approved design, their own plans and the owner-run gate G1–G4 (parked in ask #497). This work ships only the interim FileVault line; the line goes when Stage 2 ships, and the privacy policy's encryption sentence changes then (§7, item 8).
3. `RequireDatabaseEncryption` (MDM, reserved) stays reserved until Stage 2.

## 4. Scopes

### Today: 19 requested by `auth.UserScopes` (`internal/auth/oauth.go`), 15 in `slack-app-manifest.json`

| Scope | Methods | Callers | Verdict |
|---|---|---|---|
| `channels:history` | `conversations.history`, `conversations.replies` (public) | `internal/sync/message_sync.go`, `syncagain.go`, `thread_sync.go`, `media.go`, `cmd/actions_registry.go` | keep |
| `groups:history` | same, private channels | same | keep |
| `im:history` | same, DMs | same | keep |
| `mpim:history` | same, group DMs | same | keep |
| `channels:read` | `conversations.list`, `conversations.info` (`last_read`) | `orchestrator.go` (`GetChannels`, `GetChannelReadCursor`) | keep |
| `groups:read` | same | same | keep |
| `im:read` | same | same | keep |
| `mpim:read` | same | same | keep |
| `channels:write` | `conversations.mark` | only `SlackService.markRead` (Desktop, `DigestDetailView` **Mark read in Slack**, legacy config token) | **drop** (A5, A9) |
| `groups:write` | same | same | **drop** |
| `mpim:write` | same | same | **drop** |
| `im:write` | `conversations.open` | `internal/tools/slack_send.go` (`OpenDM`, a DM to a person, behind Approve) | keep |
| `search:read` | `search.messages` | the blanket and mention searches (parent D16) | keep |
| `users:read` | `users.list`, `users.info` | `orchestrator.go`, `user_sync.go` | keep |
| `users:read.email` | email on `users.*` | identity matching across sources, `find_experts` emails, sending by email | keep (A8) |
| `files:read` | file download | `internal/media/slack_opener.go` (images and links become knowledge) | keep |
| `reactions:read` | `reactions.list` | `internal/reactioncmd`, `orchestrator.go` | keep |
| `team:read` | `team.info` | `orchestrator.go` (`ensureWorkspace`), `cmd/slack.go` | keep (A7) |
| `chat:write` | `chat.postMessage` | `send_slack_message`, `output.slack` (Approve) | keep |
| *(missing)* `emoji:read` | `emoji.list` | `orchestrator.go` `syncEmoji`, every cycle, fails today | **add** (A6) |

`auth.test` needs no scope.

### Minimal set

16 kept + `emoji:read` = **17** in the Full app's manifest: `channels:history`, `groups:history`, `im:history`, `mpim:history`, `channels:read`, `groups:read`, `im:read`, `mpim:read`, `im:write`, `search:read`, `users:read`, `users:read.email`, `files:read`, `reactions:read`, `team:read`, `chat:write`, `emoji:read`.

### The need for each scope, in the app's description

The policy asks to "clearly define the need for scopes within your Application's description". The manifest's `long_description` (which also carries the connect link, parent §5.2; Slack's limit is 4,000 characters) gets a short block, Go-owned and tested for length:

> Why Watchtower asks for each permission: read history and the channel list of public and private channels, DMs and group DMs, and search, to keep a local copy on your Mac; open a DM and post a message, only when you press Approve; read people's names and emails, to match them with your calendar, Jira and Linear; read files, to describe images you were sent; read your reactions, for reaction commands; read the workspace's name and custom emoji, to show them.

### Migration impact

- **Full apps** (new, parent T7) are created with the 17 scopes; nothing migrates.
- **The retired shared app** (parent D11): new logins stop after T9; existing tokens keep their grants until Slack stops them. The dropped scopes are never used again once **Mark read in Slack** is removed (A11).
- **Corp build** (baked internal app): its admin can update the app's scope list from the manifest; existing tokens keep their wider grant until the next login (to verify in the spike: whether Slack strips a removed scope from existing user tokens). No forced re-login.
- **`emoji:read`** on a token that lacks it: the first `missing_scope` from `emoji.list` sets an in-memory skip for that account until the next login; one log line, no error state, no re-consent.
- **One source (A10):** Go embeds `slack-app-manifest.json`; `auth.UserScopes` is read from it; the PKCE loopback redirect of parent §5.3 replaces today's `https://127.0.0.1:1849x` list in the same file (parent T7/T8 own that part). `TestSlackManifest_ScopesAreTheRequestedOnes` pins the equality and the 17-scope list.

## 5. People cards and `find_experts` without surveillance

### 5.1 What "no surveillance" means here

Watchtower helps the owner work with colleagues. It does not watch them. Concretely:

1. **No presence or time tracking.** No per-person active hours, online times or "best time to reach".
2. **No activity scoring.** No per-person volume, volume change, message length, response-time or ranking against colleagues or team norms. Counts appear only as the basis of what is said ("Based on 42 messages in 5 channels").
3. **No judgments about the person.** No red flags, concerns, burnout, stress, mood, health, workload or performance verdicts, and no inference of personal life or protected characteristics. Advice is framed for the owner (how to work together), never as an assessment of the person.
4. **Only people the owner works with.** A card exists for someone who shared a DM or group DM, a thread or a mention with the owner in the window (A13), and for the owner.
5. **Only work signals.** Topics, decisions, how they communicate about work, what they delivered or helped with.
6. **Opt-out.** The owner can stop a card for a person (A14); the feature switch turns them all off.
7. **No combination for profiling.** Jira or Linear workload is not merged with Slack activity into person judgments. Jira's own data (issues a person owns) stays where Jira shows it.

### 5.2 Today

- `people_cards` (`internal/db/schema.sql`) store `active_hours_json`, `volume_change_pct`, `avg_message_length`, `red_flags`, team-norm comparisons; the reduce prompt (`internal/prompts/defaults.go`, `defaultPeopleReduce`) asks to "flag concerns" and compare with team norms; `internal/guide/jira.go` adds "COMPOUND: overdue issues + high open count — burnout risk" and "low Slack responsiveness = bottleneck risk".
- Cards are made for everyone with ≥ 3 messages (`guide.DefaultMinMessages`), on by default (`people.enabled`).
- Desktop: People list rows show a red-flag mark and a red volume change; Person detail shows a stats grid, the active-hours chart, **Red Flags**; Team Summary has **Needs Attention**; People → Connections shows interaction scores from `user_interactions` (no writer any more).
- Readers of the dropped fields: `internal/briefing`, `internal/dayplan`, `internal/tools/people_read.go`, `internal/tools/experts.go` (`active_hours`), `internal/memory`.
- `user_analyses` (legacy, `analysis.legacy_mode`, no writer reachable) still holds old rows with `concerns`, `red_flags`, `recommendations`.

### 5.3 Proposal

- **Prompt (A17).** `defaultPeopleReduce` loses `red_flags` and the team-norms section; its rules gain the list in §5.1 (3, 7) verbatim. Prompt version bump (the prompts store re-seeds). `internal/guide/jira.go` stops emitting compound signals; the Jira lines it gives the prompt are facts (open issues, recently closed), no "risk" labels.
- **Parser.** `guide.PeopleCardResult` and `guide.BatchCardResult` drop `red_flags`; unknown fields from an old model reply are ignored.
- **Who gets a card (A13).** `ComputeAllUserStats` takes the owner's id and keeps a person only with a direct interaction in the window (DM/group DM both posted, a thread both posted in, a mention either way). No owner identity → no cards (the existing "owner unknown" readiness), never everyone. The test is a SQL condition over the window's `messages`: P qualifies when (1) a DM or group DM channel has messages from both P and the owner, or (2) a thread (`thread_ts`) has messages from both, or (3) a message from P contains `<@owner>` or one from the owner contains `<@P>`. Impact (accepted in ask #1412): people the owner only reads in shared channels lose their card — in a busy workspace most of today's cards; `find_experts` still ranks them by message, thread and tracker evidence, only without a card's decision role and communication guide; the briefing, day plan and Team Summary speak about fewer people. The plan measures the before/after count on a copy of an install before the code lands (numbers stay out of the repo).
- **Opt-out (A14).** New table `people_card_exclusions(user_id TEXT PRIMARY KEY, created_at)` (namespaced `<account>:<U>` id). Writer: `watchtower people exclude|include <user>`; the Desktop's **Stop card for this person** runs that CLI. Exclude deletes the person's `people_cards` rows in the same transaction; the guide pipeline skips excluded ids. The Slack purge deletes the account's rows by namespace (PURGE-02's coverage test enforces it).
- **Stored data (A15).** One migration: `UPDATE people_cards SET active_hours_json = '{}', volume_change_pct = 0, avg_message_length = 0, red_flags = '[]'`; `UPDATE people_card_summaries SET attention = '[]'`; `DELETE FROM user_analyses`; `DELETE FROM user_interactions`. Columns stay (no table rebuild); the code writes their defaults. `analysis.legacy_mode` is removed from config.
- **Readers of the dropped fields (A24)**, all changed in H3:
  - `internal/briefing`, `internal/dayplan` (prompt context), `internal/memory` (person nodes): stop reading them.
  - `get_person` (`internal/tools/people_read.go`): returns the card record as-is today, so `RedFlags`, `ActiveHoursJSON`, `VolumeChangePct` and `AvgMessageLength` reach every MCP client (the chat, a developer's coding agent). It gets an explicit output struct without them; `TestGetPerson_OutputHasNoSurveillanceFields` pins its keys. An excluded person answers "no card (the owner stopped it)".
  - `find_experts` (A16): `expertCandidate.ActiveHours` removed; evidence, weights, `UnmatchedEmails` unchanged (DEV-03 holds).
  - The embedded developer skill `internal/devpack/skills/watchtower-who-to-ask/SKILL.md`: its field-name note lists `active_hours` and `ActiveHoursJSON`; H3 rewrites it to the fields that remain and adds "no card can mean the owner stopped it — don't guess". Installed copies follow the installer's existing update rule (DEV-04, never clobbers a local edit).
- **Desktop.** People list rows: no red-flag mark, no volume change. Person detail: no stats grid, no active-hours chart, no **Red Flags**; a basis line under the header; a **Stop card for this person** menu item with a confirm. Team Summary: no **Needs Attention** (summary and tips stay); the list header's "N items need attention" goes. People → Connections: only the owner's org links (manager, reports, peers from the profile). An excluded person's view shows "No card for this person — you stopped it." with **Make cards again**.

## 6. LLM provider disclosure

### Today

- The guide's Privacy page lists what each feature sends to the provider and says the provider's retention is outside Watchtower's control (`docs/guide/concepts/privacy.md`, "What goes to your AI provider").
- The manifest says only "lets you ask natural-language questions about your workspace via Claude. All data stays on your machine." — wrong on both counts (Codex and Ollama exist; message text goes to the provider).
- No word on the provider's training setting (research §2: "no training-setting check").

### Gap

The admin who creates the Full app and every user who connects it see no disclosure where they decide. "All data stays on your machine" is misleading under the policy's "misleading and/or deceptive statements about … Data use".

### Proposal (A19)

1. **Manifest `long_description`**, after the connect block and the scope block: "Watchtower keeps its copy on each person's Mac and has no server. To write summaries and answer questions it sends message text to the AI provider each person chooses — Anthropic (Claude) or OpenAI (Codex) under that person's own account, or a local model (Ollama) — and nowhere else. AI output can be wrong. Privacy: <privacy URL>". The short `description` becomes "Your Slack on your Mac, with the AI provider you choose".
2. **Full setup confirm** (admin's **Set up for my company**, parent §5.1): the same three facts as a block before the configuration-token paste, with the privacy link. **Connect confirm** (parent §5.3, every member): one line, "Watchtower will keep a copy on this Mac and send message text to your AI provider", plus the link.
3. **Training.** The guide and the privacy policy say: Watchtower never trains a model; whether a provider may train on what it receives is that provider's account setting (Claude: "Help improve Claude"; ChatGPT: "Improve the model for everyone"); turn it off there. Watchtower cannot read that setting, so it asks nothing.
4. The text is Go-owned for the manifest (`slackmanifest.Description(link, code)`) and Swift-owned for the confirms (`SlackDisclosureCopy`), each with a test (§11).

## 7. Privacy policy

The live policy is the site's page (`https://aiwatchtowers.com/privacy/`, maintained in the site's own repository; `docs/legal/privacy-policy.md` here is marked stale). Text changes needed there (the task edits that repo; nothing here):

1. **Slack section** (new, after "What we collect"): which Slack data is read (messages, threads, channels, DMs and group DMs the user can see, names and emails, files, the user's reactions, custom emoji), through the workspace's own app created from Watchtower's manifest, with the list of scopes and why (§4's block).
2. **"Where your data lives"** (A23), true in every state of the switch: "Watchtower has a setting, **Delete an account's data when its access ends**, on by default. While it is on, a workspace's synced Slack data is deleted 72 hours after Watchtower notices that its Slack app was removed, your access was revoked, or you removed the workspace in Watchtower, and you get a notice first; Watchtower notices on its next sync, so a Mac that is off or offline deletes after it is back. If you turn the setting off, or your organization's policy turns it off, the data stays on your Mac until you delete it yourself (Settings → System → **Reset All Data…**, or uninstalling with its data)."
3. **AI section:** name every provider (Anthropic Claude, OpenAI Codex, local Ollama); say what is sent (message text the feature needs, per the guide's list) and that it goes under the user's own account and that provider's retention and residency; say Watchtower never trains a model on any data and that the provider's training setting is in the user's account; add "AI output can be inaccurate". Drop "Watchtower requests only the permissions it needs to function — read-only for Gmail and Google Calendar, nothing more" as the only permissions statement (Slack has write scopes behind Approve).
4. **No AI training** line for the desktop app (today only the iPhone section has it).
5. **Live Slack:** with the user's own Claude/ChatGPT Slack connector, the answer stays in that chat on the Mac; the connector is the provider's app under the provider's terms.
6. **Pages published to claude.ai** from a chat go to the user's Claude account, private by default.
7. **Derived text** (P9): briefings, Catch-Up recaps, ideas, memory notes, chats, automation outputs and meeting transcripts, which can mix several sources, are kept when a source's data is deleted, until the user deletes them. The guide's revoked-access page says the same (H1).
8. **Encryption:** today FileVault; with Stage 2 the database is encrypted with a key held in this Mac's Keychain. Change the sentence when Stage 2 ships.
9. **People insights:** Watchtower writes notes about colleagues the user works with, only from work messages, never scores, monitors or judges them, and the user can stop the note for any person.
10. **Your rights & control:** add "Remove a Slack workspace in Watchtower to delete its data", and "**Reset All Data…** in Settings → System deletes everything".
11. "Last updated" date and a release-note line.

The guide's Privacy and revoked-access pages get the matching user-facing lines in the same PR as each task (CLAUDE.md, within the guide's size cap).

## 8. Screens and copy

Every string below lives in a model with a test; views only render it. The mockups are rendered from the DesignShotCatalog (`WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+SlackPolicy.swift`, strings in `SlackPolicyMockCopy`, pinned by `SlackPolicyMockCopyTests`; design only, nothing wired into the app) and committed under [`docs/design/mockups/slack-policy-hygiene/`](../../design/mockups/slack-policy-hygiene/), each in light and dark (`-light.png`, `-dark.png`). The implementation moves each string group into the model named below and pins it there.

| Screen | States (shot name `slack-ph-…`) | Copy model |
|---|---|---|
| Settings → System → Privacy (reader: `PrivacySettings` through `AccountPurgeStatus.shownValue`, which falls back to on, §2) | on by default; also the state while the CLI's status is missing (`privacyDefault`, `-narrow`), on by the setting or the corp build (`privacyOnAll`), off by the owner (`privacyOff`), set by policy (`privacyPolicy`), FileVault off (`privacyFileVault`) | `AccountPurgeStatus.footnote`, `FileVaultNotice` |
| Connections → Slack | FileVault off (`slackFileVault`); a removed workspace's 72 h line with **Add again** (`slackRemoved`, `-narrow`) | `FileVaultNotice`, `AccountPurgeNoticePolicy` (zero-lease line: no "not reached since") |
| Slack Remove dialog | purge on (`removeOn`), purge off (`removeOff`); both say the sign-out reaches every Mac (A3) | `AccountPurgeStatus.removeDialogMessage` (Slack variant) |
| Set up for my company | the disclosure block before the token paste (`setupDisclosure`; screens spec frame `slack-fl-setup-empty`) | `SlackDisclosureCopy.setup` |
| Connect confirm | the one-line disclosure (`connectDisclosure`; screens spec frame `slack-fl-connect-confirm`) | `SlackDisclosureCopy.connect` |
| Person detail | the card with the basis line and no stats, active hours or red flags (`personCard`); Stop card confirm (`personStopConfirm`); stopped (`personStopped`, `-narrow`) | `PeopleCardCopy` |
| People list | rows with role and topics, no flag, count or volume (`peopleList`) | `PeopleCardCopy` |
| Team Summary | summary and tips, no Needs Attention (`teamSummary`) | — (removal) |
| People → Connections | the owner's org links only (`orgLinks`), none set (`orgLinksEmpty`) | `PeopleCardCopy.orgLinksEmpty` |
| Digest detail | the header without **Mark read in Slack** (`digestHeader`) | — (removal) |

## 9. Failures

| Path | Failure | Behaviour | Test |
|---|---|---|---|
| Default-on purge | the owner turned it off earlier (key present) | the setting wins; nothing scheduled | `TestPurge01_EnabledOrder` (extended: absent → on, origin `default`) |
| Default-on purge | the Desktop opens Privacy before `accounts purges --json` answered, or it failed | the switch shows on with "On by default" (shared default), never off | `AccountPurgeDefaultFixtureTests` |
| Default-on purge | a disabled live account, origin `default` | no lease row | `TestPlan_DefaultOriginHoldsLiveLeaseButSchedulesRemovedSlack` |
| Removed account | re-added before due | cancelled (existing rule) | `TestPurgePolicy_RemovedSlackZeroLease` |
| Removed account | re-added between the re-plan and the start | the start's conditional `UPDATE` needs the account still `removed`; nothing deleted | `TestStartAccountPurge_ZeroLeaseNeedsRemovedStill` |
| Removed account | the re-plan before the start | uses the same per-account rules, so the zero-lease row is still due | `TestRun_ZeroLeaseRowStartsAfterReplan` |
| `auth.revoke` | the same Slack sign-in is used on another Mac or a headless host | that place gets a revoked token, shows Re-login, and (purge on) deletes its copy after its own 72 h notice; the Remove dialog said so | `TestSlackRemove_RevokesBeforeDelete` (call made) + copy test |
| `auth.revoke` | network down, 5xx, `invalid_auth` | logged and printed; the remove completes; token file deleted | `TestSlackRemove_RevokeFailureStillRemoves` |
| `auth.revoke` | Slack confirms | token file deleted after the call, row `removed` | `TestSlackRemove_RevokesBeforeDelete` |
| Verify count | rows left after the last step | `failed` with the table counts; the account stays held | `TestPurgeRun_VerifyLeftRowsFails` |
| Verify count | the count query errors | treated like a failed chunk (retry next cycle, three strikes) | `TestPurgeRun_VerifyErrorRetries` |
| Deadline | revoked at a Friday evening, 60-min cadence | done before 14 business days (fake clock) | `TestPolicy_DeletionWithinFourteenBusinessDays` |
| Emoji | token without `emoji:read` | skip for the account until the next login; one log line | `TestSyncEmoji_MissingScopeSkips` |
| Manifest | `UserScopes` and the manifest drift | build test fails | `TestSlackManifest_ScopesAreTheRequestedOnes` |
| Manifest | description over 4,000 characters with the link | build test fails | `TestSlackManifest_DescriptionFits` |
| FileVault | `fdesetup` missing, slow or unparseable | `unknown`, no line; 2 s timeout; process reaped | `FileVaultStatusTests` (stubbed runner) |
| People | an old model reply still has `red_flags` | ignored, not stored | `TestPeopleCard_DropsSurveillanceFields` |
| People | owner identity unknown | no cards, readiness says why | `TestPeopleCards_OnlyInteractionPartners` |
| People exclude | the person has no card yet | the exclusion is stored; no card is ever made | `TestPeopleExclude_BlocksFutureCards` |
| People exclude | the Desktop's CLI call fails | error shown on the person view; nothing changed | `PersonDetailViewModelTests` |
| Migration | rerun / partial | idempotent `UPDATE`/`DELETE` | `TestMigration_PeopleSurveillanceCleared` |

## 10. Writers

- `account_purges`: the daemon's purge passes (unchanged); the verify step writes the final state of its own row.
- `slack_accounts.status = removed`: `removeSlackAccount` only (unchanged); it now calls `auth.revoke` first.
- `privacy.purge_revoked_data`: the Desktop's Privacy switch (unchanged); absent still means the build default, now on.
- `people_card_exclusions`: `watchtower people exclude|include` only; the Desktop runs that CLI; the guide pipeline and the Slack purge read/delete.
- `people_cards`: the guide pipeline (unchanged) and `people exclude` (deletes the person's rows).
- Manifest text: the Full setup (`apps.manifest.create`/`update`, parent §5.1) — one Go builder, no other writer.
- FileVault status: read only, in memory, never stored.

## 11. Promises → tasks → tests

| Promise | Task | Test |
|---|---|---|
| The purge is on unless someone turns it off; default-on deletes revoked and removed accounts, never a live one for inactivity | H1 | `TestPurge01_EnabledOrder`, `TestPlan_DefaultOriginHoldsLiveLeaseButSchedulesRemovedSlack` |
| A removed Slack account is deleted 72 h after the remove, and its token is revoked at Slack | H1 | `TestPurgePolicy_RemovedSlackZeroLease`, `TestSlackRemove_RevokesBeforeDelete`, `TestSlackRemove_RevokeFailureStillRemoves` |
| Deletion finishes well within 14 business days on a running Mac | H1 | `TestPolicy_DeletionWithinFourteenBusinessDays` |
| A purge reported done left nothing behind | H1 | `TestPurgeRun_VerifyLeftRowsFails`, `TestPurgeRun_VerifyErrorRetries` |
| Remove dialog and Privacy caption say the rules | H1 | `AccountPurgeStatusTests` (copy) |
| The app asks for 17 scopes, one list in one file | H2 | `TestSlackManifest_ScopesAreTheRequestedOnes` |
| No code calls `conversations.mark` | H2 | `SlackServiceRemovedTests` (source scan for `conversations.mark` in Desktop sources) |
| A token without `emoji:read` keeps syncing | H2 | `TestSyncEmoji_MissingScopeSkips` |
| The app's description explains each scope and the AI providers, within Slack's limit | H2, H4 | `TestSlackManifest_DescriptionFits`, `TestSlackManifest_DescriptionDiscloses` |
| Cards hold no presence, activity scores or judgments | H3 | `TestPeopleCard_DropsSurveillanceFields`, `TestPeoplePrompt_HasNoSurveillanceRules` (golden), `TestMigration_PeopleSurveillanceCleared` |
| Cards only for people the owner works with | H3 | `TestPeopleCards_OnlyInteractionPartners` |
| The owner can stop a card for a person, and it stays stopped | H3 | `TestPeopleExclude_BlocksFutureCards`, `TestPurge02_EveryAccountTableCovered` (new table listed) |
| `find_experts` gives no presence data | H3 | `TestFindExperts_NoActiveHours`; DEV-03 guards unchanged |
| People screens show only work signals | H3 | `PeopleCardCopyTests`, DesignShotCatalog shots of §8 |
| The admin and every user see the disclosure before connecting | H4 | `SlackDisclosureCopyTests` |
| FileVault off is said where Slack data is stored | H4 | `FileVaultStatusTests`, `FileVaultNoticeTests` |
| The privacy policy states every item of §7 | H5 (site repo) | a checklist in the PR of that repo |
| Go and the Desktop show the same default; the switch never shows off while the daemon deletes | H1 | `TestPurge01_DefaultSharedFixture`, `AccountPurgeDefaultFixtureTests` |
| The purge decides per account; a zero-lease row survives the re-plan and needs the account still removed | H1 | `TestPurgeRules_Table`, `TestPlan_DefaultOriginHoldsLiveLeaseButSchedulesRemovedSlack`, `TestRun_ZeroLeaseRowStartsAfterReplan`, `TestStartAccountPurge_ZeroLeaseNeedsRemovedStill` |
| `get_person` and the developer skill name no dropped field | H3 | `TestGetPerson_OutputHasNoSurveillanceFields`, `TestDevpackSkills_NoDroppedPeopleFields` (scan of the embedded skills) |

Tasks:

- **H1 — deletion.** `purge.Enabled` default, the per-account rules and every path of §2 "Per-account rules", zero lease for removed Slack accounts, `auth.revoke` on remove, verify counts, copy, guide (`concepts/revoked-access.md`, `concepts/privacy.md`), feature note `revoke-purge.md`. Packages: `internal/purge`, `internal/db`, `internal/daemon`, `cmd`, Desktop `WatchtowerCore`.
- **H2 — scopes.** Embedded manifest as the single source, the 17 scopes, the description builder, emoji skip, removal of **Mark read in Slack** and `SlackService`. Coordinates with parent T7 (it sends the same manifest).
- **H3 — people.** Prompt + parser + `guide/jira.go`, interaction-partner filter, exclusions (migration, CLI, Desktop), the cleanup migration, consumers, `find_experts`, `get_person`'s output struct, the `watchtower-who-to-ask` skill, Desktop People screens. Migration steps per the `add-migration` skill (`schema.sql`, `TestAllTablesExist`, goldens, Swift test schema).
- **H4 — disclosure + FileVault.** Setup and connect confirm copy (with the screens spec's shots), `FileVaultStatus`, guide lines.
- **H5 — privacy policy.** The §7 list, in the site's repository.
- Not here: database encryption Stage 2 + 3 (A22, #603).

H1–H4 are independent of each other; H2 must land before or with parent T7.

## 12. Inventory touched

- **PURGE-01** (amend, approved in ask #1412): the default becomes on; with origin `default` the live-account lease is held; a removed Slack account has a zero lease. The 72 h notice is unchanged. Guard tests extended, none relaxed.
- **PURGE-02** (extend): the verify count after the last step; `people_card_exclusions` added to the Slack steps.
- **SLACK-01** (amend, approved in ask #1412): `slack remove` still keeps the data at once, then the purge (when on) deletes it after 72 h; the token is revoked at Slack before the file is deleted. The current text says the data stays queryable without a limit.
- **DEV-03** — unchanged (`find_experts` loses a non-evidence field only).
- **POLICY-01/02** — unchanged (no new key).

## 13. Owner answers (asks #1412, #1416)

- Purge by default and the removed Slack workspace after 72 h, with the PURGE-01/SLACK-01 amendments: «Да, одобряю» (P7).
- People-card and `find_experts` cuts, including the clearing migration: «Да, резать всё» (P8).
- AI text that mixes sources after a purge: «Оставлять и сказать об этом» (P9).
- The other agent decisions (A3–A11, A18–A20): «Принять все» (P10).
- The agent decisions after the spec review (A21–A24): «Принять все» (ask #1416).

## 14. Concerns

- The memory vault is a git repository; a forgotten fact stays in its history (security audit 2026-07-31, D-2). A Slack purge does not reach it; kept and disclosed per P9.
- The phone's replica holds Slack-derived slices (digest topics, inbox items); a purge on the Mac republishes the slices without them, but a phone that is offline keeps its copy until it syncs. Said in the policy text (§7, item 2) only if the owner wants that detail.
- `fdesetup status` without admin rights, and whether Slack strips a removed scope from existing tokens, are checked in the parent spike (T1) before H2/H4 code.
- Which error a token of a deleted (not just uninstalled) app returns is checked in the same spike; a code outside `revokedSlackErrors` would leave the account in `error`, which holds the purge.
- Slack tokens and the new PKCE refresh tokens stay 0600 files until #567/#604.
