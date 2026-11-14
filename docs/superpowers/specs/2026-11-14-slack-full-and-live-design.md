# Slack — Full and Live

**Date:** 2026-11-14 · **Board:** group #1709 (#1763–#1770) · **Status:** draft for review

## Goal

Stay compliant with Slack's terms without taking features away from customers.

- **Full** (Полный): the workspace's own Slack app, created from our manifest inside that workspace and approved there. Watchtower syncs locally and every feature works. For Slack this is an internal, customer-built app (scenario A of the research notes), the shape the corp build already has.
- **Live** (Живой): the Slack connector in the user's own Claude or ChatGPT account (the official Slack MCP behind Anthropic's or OpenAI's Marketplace app). Watchtower ships no Slack app for it. It answers questions now and stores nothing beyond the chat transcript.
- Live is a **layer**, not an alternative: wherever the connector works, the chat and automations use it for what the local copy does not have — the first sync has not finished, the channel is outside the synced scope, the date is older than the backfill. With no Full app, Live is all there is, and the proactive features say so honestly.
- The shared public Slack app with a baked client id and secret is retired.

Everything stays on the user's Mac. There is no company hub and no server of ours that sees Slack data (#868).

Out of scope here: the screens — a separate spec with DesignShotCatalog mockups for every state (#1763 UI part, written right after this one is approved). It must cover: the mode on Connections → Slack (Full, Full + Live, Live, Off, Live checked N h ago); the FeatureReadiness state `needsFullSlack` ("needs your workspace's app") on every Slack-dependent screen — digests, Inbox, tracks, people, ideas, Knowledge, Morning brief, Catch-Up and the phone; **Set up for my company**; the paste of the configuration token; waiting for approval; the connect confirm; port busy; **Take over the company app**; the shared-app banner. Also out of scope here: the Developer Policy hygiene items (#1769); the legal questions (#1770).

## Decisions

| # | Decision | Source |
|---|---|---|
| D1 | The modes are called **Full / Live** (Полный / Живой) in the UI and in code (`full`, `live`) | ask #1294 |
| D2 | Live is always on where the connector works, also next to Full: local first, the connector for gaps | ask #1294, comment #866 |
| D3 | Full syncs only the user's own scope (DMs, group DMs, mentions of the user, channels the user is a member of); other public channels are reached through Live | ask #1294 |
| D12 | Two speeds: DMs and mentions every 15 minutes, member channels every 60 minutes | ask #1294 (the chosen option: "ЛС/упоминания каждые 15 мин, свои каналы реже (30–60 мин)") |
| D13 | The app's secret and the bot token live on the admin's Mac; a second collaborator can take over without changing the client id | **open**: proposed by the agent, ask #1301 |
| D4 | Entry into Full: a Slack bot that hands out the connect link, plus an MDM key | ask #1294 |
| D5 | No company hub, nothing hosted that carries Slack data | comment #868 |
| D6 | Strict: of Live answers only the chat transcript is kept — no index, memory, ideas or Knowledge, not even on the owner's press | ask #1296 (comment #870) |
| D14 | An automation run on Live keeps its own output (the Inbox card, report) as that run's transcript; nothing reads it further | ask #1298 |
| D15 | A recipe with `slack:live` runs at most hourly; the validator refuses a tighter schedule | ask #1298 |
| D7 | The bot needs no server: the admin's Watchtower publishes the bot's Home tab to every member | ask #1295 |
| D8 | The connect link starts the workspace app's OAuth and lands on localhost; no page of ours on the web. Its first hop through Watchtower's loopback listener (fresh PKCE) is **open**: the owner asked why not Slack → localhost directly | ask #1295; the first hop — open, ask #1301 |
| D9 | The admin creates the app with one paste: a Slack app configuration token | ask #1295 |
| D10 | Turns that used Live are marked and every consumer that makes chat text lasting skips them | ask #1296 |
| D11 | Accounts on the retired shared app keep working until Slack stops them; the app offers Full or Live; synced data follows the purge rules | ask #1295 |

## 1. The model

Per Slack workspace (team id) Watchtower knows two independent facts:

| Fact | True when | Writer | Stored in |
|---|---|---|---|
| `full` | a `slack_accounts` row for the team is `ok` and its client id is a workspace app (not the retired shared one) | `watchtower slack login`, the token refresher | `slack_accounts` (existing) + `client_id`, `refresh_token_expires_at` (new columns) |
| `live` | the last connector probe for this team succeeded with a real read call | the probe (`watchtower slack live probe`), and the chat / automation run that used the connector; the newest `checked_at` wins | `slack_live_status` (new table: team id, provider `claude`/`codex`, `ok`/`not_connected`/`needs_admin`/`no_plan`/`unavailable`, `checked_at`, error class) |

The mode the UI shows is derived, never stored: `full` → **Full** (with "Live also on" when `live`), only `live` → **Live**, neither → **Off**. Go and Swift derive it with the same table (dual path, shared JSON cases like `policy_cases.json`).

### The Live probe

Listing the connector's tools is not enough (Codex lists the 38 Slack tools before the OAuth, then fails with `Unknown tool`). The probe makes one real read call:

- Claude: `claude -p --input-format stream-json --output-format stream-json` (the chat's launch shape; plain `claude -p` loads no connectors), waits for `mcp_status` of `claude.ai Slack` up to 15 s, then calls one read tool (`slack_search_channels` with an empty query, limit 1). Write tools are disallowed for the probe.
- Codex: `codex exec` with apps on; calls `slack_list_workspaces`, which also gives the team ids the connector covers.
- When it runs: when the owner opens Connections → Slack, on the first chat turn that needs Slack with no probe newer than 24 h, and after the owner presses **Check again**. Never from the daemon on a timer (it spends the owner's subscription).
- Freshness: every chat turn and automation run that calls a Slack connector tool also writes the status (`ok` on a successful read, the failure class otherwise), so the status is as fresh as the last real use. The screen shows the time ("Live checked 5 h ago") next to the mode, never a bare "on".
- Team mapping: Codex returns team ids. Claude's connector covers one workspace; the probe reads the team from the first result's permalink domain and matches it to `slack_accounts.domain`, else stores it as `unknown` (the chat still uses it, the Connections screen says "workspace not identified").

## 2. Full: syncing only the user's own scope

Measured cost model (Slack quotas are per method × workspace × app, so every person in a company shares one budget; `search.messages` ≈ 20/min ≈ 1,200/h per workspace):

```
calls per person per hour ≈ cycles per hour + messages seen per hour / 100   (+ one-time backfill)
```

Today's blanket search sees every public message. In a 1,000-person workspace with 20k public messages a day that is ≈ 12 calls/h per person — about 100 people before the whole company runs into 429s; a 60-minute cycle only reaches ≈ 130. Restricting to the user's own scope cuts the volume term roughly tenfold (an estimate; the spike measures it).

`search.messages` has no "only my channels" modifier (checked against Slack's search help). The spike (Task 1) settles which of these narrows the scope:

1. `search.messages` with `in:` for several member channels in one query — usable only if Slack ORs repeated `in:` and the query length allows useful groups.
2. `conversations.history` with `oldest=` for member channels that changed, Tier 3 (≈ 50/min per workspace, internal apps keep it), with `users.conversations` refreshed once a cycle.
3. Blanket search with `-in:` for non-member channels — rejected up front (unbounded query).

Two speeds (D12): DMs, group DMs and mentions of the user (a `search.messages` query for the user's mention, so a mention in a channel the user is not in still arrives) every 15 minutes; member channels every 60 minutes; the history backfill covers the own scope only and keeps its one-chunk-per-cycle pacing. A `Retry-After` from Slack holds every Slack call of that account for its duration (existing limiter); a second 429 inside a cycle ends the cycle early.

What leaves the local copy: public channels the user is not a member of. Channel digests, Catch-Up, people cards and the knowledge index lose them; the chat reaches them through Live. The guide says so.

## 3. Live in the chat

- **Claude chat** already loads claude.ai connectors (`docs/features/chat-claude-ai-tools.md`). New: the Slack connector's tools enter `connectorpolicy` explicitly — read tools free, `slack_send_message`, `slack_schedule_message`, `slack_send_message_draft`, `slack_update_canvas`, `slack_create_canvas`, `slack_add_reaction` → Approve (CHAT-02/CHAT-05 unchanged, the table grows).
- **Codex chat**: apps enabled for the chat's `codex` launch when the owner signed in with ChatGPT (`features.apps`), the same policy table.
- **The rule in the system prompt** (one paragraph, Go-owned, both providers): answer Slack questions from the local tools first; each local Slack tool result carries a `coverage` line (`scope: own|none`, `synced_through`, `backfill_from`, `channel_in_scope`); for anything outside it use the connector, and say which part came from Live.
- **What is stored:** the chat transcript as today. A conversation is marked `live_slack_since` (the first turn whose tool calls hit a Slack connector; migration on `chat_conversations`), and every turn from that one on counts as marked — a later turn ("sum up everything above") restates Live text without calling the connector. Consumers that turn chat text into something lasting skip marked turns (D6, strict): ideas mining from chats (`ideas_chat_floor`), memory ingestion from chats, the coach's chat-turn import, Add to Knowledge for an artifact of a marked turn (button disabled with the reason "built on Live Slack answers, which are not kept"), and `remember:` lines sent in a marked turn are stored only as the owner's own words, never with quoted connector text. Two guard tests, one per language, because both read the chat tables: Go `TestLIVE01_MarkedTurnsStayOutOfStores` and Swift `LiveSlack01GuardTests` each list every reader of `chat_messages`/`chat_conversations` in their tree (Go: ideas, memory, coach, knowledge; Swift: the ideas and Learn queries, Add to Knowledge) and fail on a new reader that is neither on the "display only" list nor checks the mark.

## 4. Live in automations

- `agent()` runs on the Claude provider move to the stream-json launch and wait for the connector the same way as the probe (≤ 15 s). Codex runs pass apps on.
- A recipe declares `slack:live` in its manifest to get the Slack connector's read tools (AUTO-01: the manifest stays the only source of permissions). Write tools stay proposals (AUTO-02).
- `slack.*` events and reaction triggers need Full; saving a recipe that needs them on a Live-only workspace is refused with the reason.
- Storage (D14): a run's own output (`output.inbox`/`report`/`slack`) is that run's transcript and is kept like any run output; the run is marked (`automation_runs.live_slack`, migration) and nothing reads its outputs into ideas, memory, the knowledge index or the briefing's FROM YOUR AUTOMATIONS block.
- Pace (D15): a recipe with `slack:live` may run at most hourly (subscription "ordinary individual use", RTS ≈ 10 calls/min per user plus a daily cap). The validator refuses a tighter schedule.

## 5. Entry into Full

### 5.1 The admin creates the workspace app (one paste, D9)

1. Connections → Slack → **Set up for my company**. Watchtower opens `https://api.slack.com/apps` on the configuration tokens section and asks for one paste: the configuration token (lives 12 h, used once, never stored).
2. `apps.manifest.create` with our manifest: the user scopes of today minus the unused write scopes, a bot user with `users:read` only, the Home tab on, PKCE on, token rotation on, the 127.0.0.1 redirect URLs. The response gives `app_id`, `client_id`, `client_secret`.
3. The admin's Watchtower installs the app with bot + user scopes through the existing loopback OAuth with the client secret (desktop PKCE cannot ask for bot scopes). The secret and the bot token go to the admin's token store (0600, the same place as user tokens); no other Mac holds them unless a collaborator takes over (5.4).
4. If the workspace requires approval and the creator is not an admin, Slack files an install request: Watchtower shows "Waiting for your admin's approval" and resumes from the stored `app_id` when the owner presses **Check again**.

### 5.2 The bot hands out the link (D4, D7)

The admin's Watchtower publishes the bot's Home tab (`views.publish`, Tier 4) to every member: "Watchtower for <workspace>" with a **Connect Watchtower** link. It publishes once after setup, then once a day to members it has not published to (`slack_bot_home` table: user id, published hash, time), and again for everyone when the link changes. No events, no Socket Mode, no server: when the admin's Mac is off, existing members still see the tab; new members get it with the next daily pass.

### 5.3 The link (D8)

The link is `http://127.0.0.1:18551/slack/connect?team=<T>&client=<client id>`. It starts the OAuth on the user's own Mac and comes back there; nothing of ours on the web is involved.

- A Slack OAuth link cannot be fully static: PKCE needs a fresh `code_challenge` whose verifier only the Mac holds, and an authorize link without it would need the client secret for the exchange, which colleagues must not have. So the link's first hop is the Watchtower app's loopback listener: it checks the request, makes the PKCE pair, and redirects the browser to `https://slack.com/oauth/v2/authorize` for that client id with user scopes and `redirect_uri=http://127.0.0.1:18551/callback`. Slack sends the code back to the same listener, which exchanges it with the verifier, no secret.
- The listener is new: the Desktop app keeps it open on 127.0.0.1:18551 while the app runs (today the redirect port is only intercepted inside the login web view). 18551 is the first port outside every OAuth range already in use (Slack 18491–18500, Calendar 18501–18510, Jira 18511–18520, Gmail 18521–18530, Outlook/IMAP and Linear 18531–18540, Quick Connections 18541–18550); `TestOAuthPortRanges_Disjoint` collects every listener's port range and asserts 18551 is in none of them and no new range overlaps another; the one existing overlap (Linear 18531–18535 inside Outlook/IMAP 18531–18540) is listed as a known exception in the test, not fixed here.
- Port busy (another app holds 18551): the listener does not start, Connections → Slack shows "The connect link cannot reach Watchtower: port 18551 is busy", and the owner can paste the link into Watchtower instead; pasting runs the same flow. It answers `/slack/connect` and `/callback` only, GET only, checks `Host`, and never serves files.
- Before redirecting to Slack, Watchtower comes to the front and asks "Connect workspace <team> through app <client id>?" — any web page can open a loopback URL, and nothing starts without the owner's press.
- Watchtower not running or not installed: the browser shows "can't connect". The Home tab says so next to the link ("open Watchtower first; no Watchtower yet — download it from <release page>").
- The manifest's redirect URLs gain `http://127.0.0.1:18551/callback` (the PKCE loopback form); the existing `https://127.0.0.1:1849x` entries stay for the admin's secret-based install.
- A team in the link that differs from the team Slack returns is refused.

### 5.4 The admin's Mac is gone (D13)

The app belongs to the workspace, not to the Mac: its client id, and so every colleague's connection, outlive the admin's Mac. What is lost with it is the secret and the bot token, so the Home tab is no longer refreshed.

- At the end of setup Watchtower asks the admin to add a second collaborator on the app's page (`https://api.slack.com/apps/<app id>/collaborators`, link opened for them).
- **Take over the company app** (Connections → Slack, for a collaborator or workspace admin): paste the client secret from the app's Basic Information page; Watchtower reinstalls with the bot scope through the secret-based loopback OAuth and gets its own bot token. The client id does not change; nobody reconnects. The Home tab passes then run from the new Mac. Whether the reinstall revokes the old Mac's bot token is checked in the spike (T1); either way two Macs publishing at once is harmless — both publish the same view for the same link — and the old Mac stops once its token fails or its owner signs out of the app.

### 5.5 MDM (D4)

New managed key `SlackApps`: a list of `{team_id, client_id}` (POLICY-01: forced values only, a wrong type fails closed; POLICY-02: Go and Swift read it alike). Connections → Slack lists them with a one-click **Connect**. The corp build keeps its baked credentials until its admin moves to the key; nothing changes for it on day one.

### 5.6 Tokens

PKCE refresh tokens expire after 30 days. The daemon refreshes a token when less than 7 days are left, under a per-account flock shared with `watchtower slack login` (the lock holder wins; the other re-reads the token file). A Mac offline past the expiry shows the existing Re-login state.

## 6. The retired shared app (D11)

- The public build stops baking `DefaultClientID`/`DefaultClientSecret` for Slack; `WATCHTOWER_OAUTH_CLIENT_ID` stays for development.
- An account connected through the shared app keeps syncing until Slack refuses its token. Connections shows a banner: "Move to Full (your workspace's app) or use Live". Moving to Full adds a new account row and soft-removes the old one (SLACK-01 unchanged); the old data then follows the purge lease (PURGE-01).
- Docs: `docs/features/slack-multi-account.md`, the guide's Slack pages.

## 7. Failures

| Path | Failure | Behaviour | Test |
|---|---|---|---|
| Probe | CLI missing, API-key login, `--strict-mcp-config`, no connector | `not_connected` with the reason; no retry loop | `TestLiveProbe_Classifies` (fake CLI stubs) |
| Probe | `Unknown tool` / admin not approved / 429 / 60 s connector timeout | `not_connected` / `needs_admin` / `unavailable` with `checked_at` | same |
| Probe | the Mac sleeps or the app quits mid-probe | the child is reaped with its process group; no row written; next trigger probes again | `TestLiveProbe_KilledLeavesNoRow` |
| Chat | the connector fails mid-turn | the answer uses the local data and says Live was unavailable; nothing retried silently (CHAT-02) | `TestChatLive_ConnectorErrorShown` |
| Sync | membership changes | `users.conversations` each cycle; a left channel stops syncing, its data stays | `TestOwnScope_MembershipChange` |
| Sync | shared quota 429 | `Retry-After` honoured account-wide; second 429 ends the cycle | `TestOwnScope_SecondRetryAfterEndsCycle` |
| Setup | config token expired or wrong | stop before any call; ask for a new one | `TestAppSetup_BadConfigToken` |
| Setup | app created, install not finished (Mac closed, approval pending) | `app_id` + credentials kept; **Check again** resumes at install; a second create is never sent | `TestAppSetup_ResumeAfterCreate` |
| Bot | `views.publish` fails part-way | the per-user table is the cursor; the next pass continues | `TestBotHome_ResumesFromTable` |
| Link | Watchtower not running / not installed | the browser cannot connect; the Home tab text says to open or download Watchtower | manual |
| Link | a web page opens the loopback URL by itself | the confirm prompt; nothing starts without the owner's press | `TestSlackConnectListener_RequiresConfirm` |
| Link | the app quits between the redirect and the callback | the verifier is gone with the process; the callback answers "start again"; nothing stored | `TestSlackConnectListener_CallbackWithoutFlow` |
| Link | team mismatch | refused, nothing stored | `TestSlackLinkConnect_TeamMismatch` |
| Link | port 18551 busy | the listener does not start; Connections says so; pasting the link runs the same flow | `TestSlackConnectListener_PortBusy`, `TestOAuthPortRanges_Disjoint` |
| Bot | the admin's Mac is lost | colleagues keep working (same client id); the Home tab goes stale until a collaborator takes over | `TestAppTakeover_KeepsClientID` |
| Chat | a later turn restates Live text | the conversation is marked from its first Live turn; every later turn is skipped too | `TestLIVE01_LaterTurnsMarked` |
| Tokens | refresh races login | flock; holder wins; the other re-reads | `TestSlackRefresh_LockRace` |
| Tokens | offline past 30 days | Re-login state | `TestSlackRefresh_Expired` |

## 8. Writers of the same data

- `slack_accounts` + token files: `slack login` and the refresher, serialised by the per-account flock (5.6). The daemon's sync reads only.
- `slack_live_status`: the probe, and any chat turn or automation run that called a Slack connector tool; an upsert keeps the row with the newest `checked_at`; the Desktop reads.
- `slack_bot_home`: the daemon of the Mac holding the bot token (the admin's, or the collaborator's after a take-over; if both publish for a while, they publish the same view, which is harmless).
- `chat_conversations.live_slack_since`: the chat process, set once in the same transaction as the first turn that called a Slack connector tool; never cleared. It is the only place the mark lives (no per-message column).
- `automation_runs.live_slack`: the executor of that run, set when the run's `agent()` step calls a Slack connector tool.

## 9. Promises → tasks → tests

| Promise | Task | Test |
|---|---|---|
| Full/Live/Off derived the same in Go and Swift | T2 | `slack_mode_cases.json` in both suites |
| A Live probe is a real read call | T3 | `TestLiveProbe_Classifies` |
| Full syncs only the own scope, two speeds | T1 spike → T4 | `TestOwnScope_*` |
| Live answers never reach lasting stores, later turns included | T5 | `TestLIVE01_MarkedTurnsStayOutOfStores`, `TestLIVE01_LaterTurnsMarked`, Swift `LiveSlack01GuardTests` |
| Slack connector writes need Approve | T5 | `connectorpolicy` table test |
| Automations get Live only through `slack:live`, at most hourly | T6 | `TestManifest_SlackLive*` |
| One-paste admin setup that resumes | T7 | `TestAppSetup_*` |
| A collaborator takes over without a new client id | T7 | `TestAppTakeover_KeepsClientID` |
| The connect listener never collides and needs the owner's press | T9 | `TestOAuthPortRanges_Disjoint`, `TestSlackConnectListener_*` |
| Mentions of the user arrive even from channels they are not in | T4 | `TestOwnScope_MentionOutsideMembership` |
| The Live status is as fresh as its last real use | T3, T5 | `TestLiveStatus_UpdatedByChatUse` |
| The bot's Home tab reaches every member, resumable | T8 | `TestBotHome_*` |
| Link and MDM connect with PKCE, no secret | T9 | `TestSlackLinkConnect_*`, `policy_cases.json` |
| Tokens refresh before expiry, one writer | T9 | `TestSlackRefresh_*` |
| The shared app is retired, old accounts move | T10 | `TestSlack01_*` unchanged + `TestSharedAppBanner` |
| Screens show the mode and honest empty states | screens spec | that spec's tests |

Tasks: T1 spike (narrowing method, PKCE + rotation via manifest, `views.publish` to members who never opened the app, OR of repeated `in:`, whether a reinstall revokes the previous bot token) — the plan depends on its result; T2 model + migration; T3 probe; T4 own-scope sync; T5 chat; T6 automations; T7 admin setup; T8 bot; T9 link, MDM, tokens; T10 retirement, guide and feature notes.

## 10. Inventory touched

- SLACK-01 — unchanged (the move to Full soft-removes).
- CHAT-02, CHAT-05 — unchanged; the connector policy table grows.
- AUTO-01, AUTO-02 — unchanged; a new capability `slack:live`.
- POLICY-01/02 — a new key `SlackApps`.
- New: LIVE-01 (marked turns stay out of lasting stores), SLACKMODE-01 (Go↔Swift mode derivation).

## 11. Open

- The spike's answer on narrowing (T1).
- Anthropic's and OpenAI's view on background use of the connector (#1770).
