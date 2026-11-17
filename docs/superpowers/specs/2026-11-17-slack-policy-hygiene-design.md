# Slack — Developer Policy hygiene for company mode

**Date:** 2026-11-17 · **Board:** target #1769 (group #1709 "Slack: Full/Live modes") · **Status:** draft for review

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

Out of scope: the legal questions (commercial distribution, template clause, Marketplace) — #1770; Live mode's storage rules — parent D6/D10/D14; Keychain for tokens — #567/#604.

## Decisions

| # | Decision | Source |
|---|---|---|
| P1 | The hygiene items are: purge by default, DB encryption (Stage 2), minimal Slack scopes, people/`find_experts` without surveillance, LLM provider disclosure, deletion within 14 business days after disconnect, privacy policy | target #1769 (owner's backlog item, approved to design) |
| P2 | Everything stays on the Mac; no hub, no hosted service with Slack data | parent D5 (comment #868) |
| P3 | Accounts on the retired shared app follow the purge rules once Slack stops their token | parent D11 (ask #1295) |
| P4 | No client secret anywhere; PKCE for every login | parent D13 |
| P5 | The Full app's manifest asks for "the user scopes of today minus the unused write scopes", no bot user | parent §5.1 (ask #1295) |
| P6 | Live answers stay out of lasting stores (strict) | parent D6 (ask #1296) |

### Agent decisions (for one owner ask)

Each was taken by the agent («решил агент») and goes to the owner in a single ask together with the open questions at the end.

| # | Decision | Recommendation / why |
|---|---|---|
| A1 | The purge switch defaults to **on** in every build. When on only by the default (origin `default`), it covers the revoked rule and removed accounts; the 30-day lease of live accounts runs only when the switch is on by the setting, the policy or the corp build profile | Slack asks for deletion after the app is removed, not after inactivity. Without this split, a public user who paused Slack in Watchtower would lose the data 72 h after upgrading |
| A2 | A **removed** Slack account gets a zero lease: the first purge pass after `slack remove` schedules it due now + 72 h (reason `lease`, no migration). Other sources keep today's 30-day removed lease | Removing the account in Watchtower is the user's deletion request; 72 h keeps PURGE-01's notice and is far under 14 business days |
| A3 | `slack remove` calls `auth.revoke` on the token before deleting the token file, best effort | Slack then sees the app removed for that user; today the token stays valid after a remove |
| A4 | After a purge's last step, `purge.Run` counts what each step's predicate still matches; a non-zero count ends the row `failed` with the table names | "Deleted" becomes a checked fact, not an assumption |
| A5 | Drop `channels:write`, `groups:write`, `mpim:write` (19 → 16 requested scopes); keep `im:write` | The three are used only by the Desktop's legacy `conversations.mark` call; `im:write` is needed by `conversations.open` for a DM sent with Approve |
| A6 | Add `emoji:read` to the manifest (16 → 17 in the Full app); a token without it skips the emoji sync after its first `missing_scope`, no re-consent | `emoji.list` runs every cycle today without the scope and fails; the Desktop renders custom emoji |
| A7 | Keep `team:read` | `team.info` gives the id, name and domain; deriving them from `auth.test`'s URL saves one low-risk scope at an Enterprise Grid risk |
| A8 | Keep `users:read.email` | Cross-source identity (Jira, Google, Linear, calendar attendees), `find_experts` by git author email, sending by email |
| A9 | Remove **Mark read in Slack** from the digest detail and the Desktop's `SlackService` | It reads a legacy single-account token from the config and needs the dropped write scopes |
| A10 | One manifest source: Go embeds `slack-app-manifest.json`; `auth.UserScopes` is read from it; the Full setup (parent T7) sends the same file | Today the manifest and `oauth.go` disagree (19 vs 15 scopes) |
| A11 | No forced re-consent for existing tokens; their wider grants stay until the next login, and the code never calls the methods behind them | A re-login for removing scopes would cost every user a login for no new data access |
| A12 | People cards lose: active hours, volume change, average length, the stats grid, red flags, comparisons with team norms, the Jira+Slack "burnout"/"bottleneck" compound signals, and the Team Summary's "Needs attention" list. They keep: summary of work topics, communication guide, decision role, tactics, highlights, accomplishments, and a "Based on N messages in M channels" basis line | §5.1's definition of surveillance |
| A13 | Cards are made only for people the owner works with directly in the window (a DM or group DM together, a thread both wrote in, a mention either way), plus the owner's own card | Derived from synced messages; replaces "everyone with ≥ 3 messages" |
| A14 | **Stop card for this person** on the person view: the card is deleted and never made again; **Make cards again** undoes it. No new MDM key | The owner can honour a colleague's request; the feature switch already turns cards off entirely |
| A15 | A migration clears the dropped fields in stored `people_cards` and deletes the legacy `user_analyses` and `user_interactions` rows (no code writes them any more); the dead `analysis.legacy_mode` key goes; People → Connections shows only the org links the owner entered | Old profiling data does not outlive the change |
| A16 | `find_experts` drops `active_hours` from its output; evidence, weights and DEV-03 unchanged | Presence is not evidence about a topic |
| A17 | The people prompt gets fixed rules: no health, mood, burnout, workload judgment, personal life, protected characteristics, or performance verdicts; work topics and how to collaborate only | Marketplace AI guidance and the Developer Policy profiling clause |
| A18 | Until Stage 2 ships, Connections → Slack and Settings → System → Privacy show whether FileVault is on (`fdesetup status`, read by the app, no question asked) | The policy asks for strong encryption; FileVault is what protects the files today |
| A19 | Disclosure lives in four places: the manifest's `long_description` (scope reasons, AI providers, privacy link), the Full setup confirm, the guide, and the privacy policy | Each place where an admin or a user decides |
| A20 | Privacy policy changes are a text list in §7, applied in the site's repo (separate from this one) | The site is not in this repo |

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
| AI disclosure (Marketplace, good practice) | model, retention and use by the LLM, tenancy, residency; an inaccuracy disclaimer; no training; no AI categorisation by protected characteristics | Marketplace, AI components |

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

1. **Default on (A1).** `purge.Enabled` falls back to `true` with origin `default`. `phaseAccountPurgeLeases` passes a `leaseHeld` that holds every source's live-account lease while the origin is `default` (the seam exists: `purge.PlanWith`). The revoked rule and the removed rule (A2) run under any origin that is on. The owner can still turn it off in Settings → System → Privacy unless a policy forces it.
2. **Removed Slack account (A2).** In `leaseDeadlines`, a removed Slack account's deadline is its `access_ok_at` (zero lease) instead of `access_ok_at + Lease`; since every due date is at least 72 h after the scheduling pass, it is due 72 h after the first pass after the removal. Re-adding the account cancels it (existing rule).
3. **Revoke on remove (A3).** `removeSlackAccount` calls `auth.revoke` with the token, then deletes the token file and sets `removed` (SLACK-01's order otherwise unchanged). A failed revoke is logged and shown in the CLI output ("Slack did not confirm the token was revoked; it will expire"), never blocks the remove.
4. **Verified deletion (A4).** `PurgeSteps` gains a count form of each step (same predicate, `SELECT count(*)`, read-only transaction). After the last step `purge.Run` runs them; zero everywhere → `done`; otherwise `failed` with `error = "left: <table>=<n>, …"`. The Connections line already shows a failed purge.
5. **Copy.** The Remove dialog, the Privacy switch caption and the guide's revoked-access page say the new rules (§8 lists the strings).

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
2. **Stage 2 + 3 unparked.** No redesign here: the existing spec stands. The order is the gate G1–G4 (owner-run notarized probe), then the Stage 2 and Stage 3 plans. Recommendation: ship Stage 2 + 3 before Full becomes the only Slack path of the public build (parent T9), and drop the interim line then. This is open question Q4.
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
- **Who gets a card (A13).** `ComputeAllUserStats` takes the owner's id and keeps a person only with a direct interaction in the window (DM/group DM both posted, a thread both posted in, a mention either way). No owner identity → no cards (the existing "owner unknown" readiness), never everyone.
- **Opt-out (A14).** New table `people_card_exclusions(user_id TEXT PRIMARY KEY, created_at)` (namespaced `<account>:<U>` id). Writer: `watchtower people exclude|include <user>`; the Desktop's **Stop card for this person** runs that CLI. Exclude deletes the person's `people_cards` rows in the same transaction; the guide pipeline skips excluded ids. The Slack purge deletes the account's rows by namespace (PURGE-02's coverage test enforces it).
- **Stored data (A15).** One migration: `UPDATE people_cards SET active_hours_json = '{}', volume_change_pct = 0, avg_message_length = 0, red_flags = '[]'`; `UPDATE people_card_summaries SET attention = '[]'`; `DELETE FROM user_analyses`; `DELETE FROM user_interactions`. Columns stay (no table rebuild); the code writes their defaults. `analysis.legacy_mode` is removed from config.
- **Consumers.** Briefing, day plan, `people_read`, memory: stop reading the dropped fields. `find_experts` (A16): `expertCandidate.ActiveHours` removed; evidence, weights, `UnmatchedEmails` unchanged (DEV-03 holds).
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
2. **"Where your data lives":** add that synced Slack data is kept until the user deletes it, the account is removed, or Slack revokes access; then it is deleted within 72 hours of Watchtower noticing (§2), and the user is notified before.
3. **AI section:** name every provider (Anthropic Claude, OpenAI Codex, local Ollama); say what is sent (message text the feature needs, per the guide's list) and that it goes under the user's own account and that provider's retention and residency; say Watchtower never trains a model on any data and that the provider's training setting is in the user's account; add "AI output can be inaccurate". Drop "Watchtower requests only the permissions it needs to function — read-only for Gmail and Google Calendar, nothing more" as the only permissions statement (Slack has write scopes behind Approve).
4. **No AI training** line for the desktop app (today only the iPhone section has it).
5. **Live Slack:** with the user's own Claude/ChatGPT Slack connector, the answer stays in that chat on the Mac; the connector is the provider's app under the provider's terms.
6. **Pages published to claude.ai** from a chat go to the user's Claude account, private by default.
7. **Derived text:** summaries, briefings, memory notes and chats that mix sources are kept after a source is deleted, until the user deletes them (unless Q3 decides otherwise).
8. **Encryption:** today FileVault; with Stage 2 the database is encrypted with a key held in this Mac's Keychain. Change the sentence when Stage 2 ships.
9. **People insights:** Watchtower writes notes about colleagues the user works with, only from work messages, never scores, monitors or judges them, and the user can stop the note for any person.
10. **Your rights & control:** add "Remove a Slack workspace in Watchtower to delete its data", and "**Reset All Data…** in Settings → System deletes everything".
11. "Last updated" date and a release-note line.

The guide's Privacy and revoked-access pages get the matching user-facing lines in the same PR as each task (CLAUDE.md, within the guide's size cap).

## 8. Screens and copy

Every string below lives in a model with a test; views only render it. **New or changed screens need DesignShotCatalog mockups. They are listed here and not rendered in this pass**; the plan's first Desktop task renders them before code.

| Screen | States needing a shot | Copy model |
|---|---|---|
| Settings → System → Privacy | purge on by default (caption), on by policy, off by the owner; FileVault off line | `AccountPurgeStatus` (caption), `FileVaultNotice` |
| Connections → Slack | FileVault off line; a removed account's 72 h line (existing `AccountPurgeLine`, new copy) | `FileVaultNotice`, `AccountPurgeNoticePolicy` |
| Slack Remove dialog | "Its data is deleted in 72 hours unless you add it back" | `AccountPurgeStatus.removeDialogMessage` (Slack variant) |
| Full setup (Set up for my company) | the disclosure block before the token paste | `SlackDisclosureCopy.setup` |
| Connect confirm | the one-line disclosure | `SlackDisclosureCopy.connect` |
| People list | rows without flags and volume; header without the attention count | — (removal) |
| Person detail | card with basis line; Stop card confirm; stopped state with **Make cards again** | `PeopleCardCopy` |
| Team Summary | without Needs Attention | — (removal) |
| People → Connections | org links only; empty state when none are set | `PeopleCardCopy.connectionsEmpty` |
| Digest detail | without **Mark read in Slack** | — (removal) |

## 9. Failures

| Path | Failure | Behaviour | Test |
|---|---|---|---|
| Default-on purge | the owner turned it off earlier (key present) | the setting wins; nothing scheduled | `TestPurge01_EnabledOrder` (extended: absent → on, origin `default`) |
| Default-on purge | a disabled live account, origin `default` | no lease row | `TestPurgePolicy_DefaultOriginHoldsLiveLease` |
| Removed account | re-added before due | cancelled (existing rule) | `TestPurgePolicy_RemovedSlackZeroLease` |
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
| The purge is on unless someone turns it off; default-on deletes revoked and removed accounts only | H1 | `TestPurge01_EnabledOrder`, `TestPurgePolicy_DefaultOriginHoldsLiveLease` |
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
| The database is encrypted with a key bound to the Mac | H6 (existing Stage 2/3 plans, after the gate) | the Stage 2/3 plans' tests |

Tasks:

- **H1 — deletion.** `purge.Enabled` default, lease hold by origin, zero lease for removed Slack accounts, `auth.revoke` on remove, verify counts, copy, guide (`concepts/revoked-access.md`, `concepts/privacy.md`), feature note `revoke-purge.md`. Packages: `internal/purge`, `internal/db`, `internal/daemon`, `cmd`, Desktop `WatchtowerCore`.
- **H2 — scopes.** Embedded manifest as the single source, the 17 scopes, the description builder, emoji skip, removal of **Mark read in Slack** and `SlackService`. Coordinates with parent T7 (it sends the same manifest).
- **H3 — people.** Prompt + parser + `guide/jira.go`, interaction-partner filter, exclusions (migration, CLI, Desktop), the cleanup migration, consumers, `find_experts`, Desktop People screens with shots. Migration steps per the `add-migration` skill (`schema.sql`, `TestAllTablesExist`, goldens, Swift test schema).
- **H4 — disclosure + FileVault.** Setup and connect confirm copy (with the screens spec's shots), `FileVaultStatus`, guide lines.
- **H5 — privacy policy.** The §7 list, in the site's repository.
- **H6 — encryption.** Owner-run gate G1–G4, then the existing Stage 2 and Stage 3 plans.

H1–H4 are independent of each other; H2 must land before or with parent T7.

## 12. Inventory touched

- **PURGE-01** (amend, owner approval): the default becomes on; with origin `default` the live-account lease is held; a removed Slack account has a zero lease. The 72 h notice is unchanged. Guard tests extended, none relaxed.
- **PURGE-02** (extend): the verify count after the last step; `people_card_exclusions` added to the Slack steps.
- **SLACK-01** (amend, owner approval): `slack remove` still keeps the data at once, then the purge (when on) deletes it after 72 h; the token is revoked at Slack before the file is deleted. The current text says the data stays queryable without a limit.
- **DEV-03** — unchanged (`find_experts` loses a non-evidence field only).
- **POLICY-01/02** — unchanged (no new key).

## 13. Open questions for the owner

- **Q1.** Approve A1 + A2 + the PURGE-01/SLACK-01 amendments (purge on by default; a removed Slack workspace's data deleted after 72 h; the lease of live accounts only on an explicit switch)? Recommendation: yes.
- **Q2.** Approve the people-card cuts of A12–A15 (the owner loses the active-hours chart, volume change, red flags, Needs Attention and the interaction graph)? Recommendation: yes; they are exactly what the profiling and surveillance clauses name.
- **Q3.** AI text that mixes sources (briefings, recaps, memory, ideas, chats, automation outputs) stays after a Slack purge (PURGE-02). Keep and disclose (recommended for v1), or delete what cites only the purged account?
- **Q4.** Encryption: run the Stage 2 gate (G1–G4, an owner-run probe) now and ship Stage 2 + 3 before Full is the only public Slack path (recommended), or keep the FileVault line as the answer for longer?
- **Q5.** All agent decisions A1–A20 in one go.

## 14. Concerns

- The memory vault is a git repository; a forgotten fact stays in its history (security audit 2026-07-31, D-2). A Slack purge does not reach it. Tied to Q3.
- The phone's replica holds Slack-derived slices (digest topics, inbox items); a purge on the Mac republishes the slices without them, but a phone that is offline keeps its copy until it syncs. Said in the policy text (§7, item 2) only if the owner wants that detail.
- `fdesetup status` without admin rights, and whether Slack strips a removed scope from existing tokens, are checked in the parent spike (T1) before H2/H4 code.
- Which error a token of a deleted (not just uninstalled) app returns is checked in the same spike; a code outside `revokedSlackErrors` would leave the account in `error`, which holds the purge.
- Slack tokens and the new PKCE refresh tokens stay 0600 files until #567/#604.
