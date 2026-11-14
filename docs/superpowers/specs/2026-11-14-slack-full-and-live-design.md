# Slack — Full and Live

**Date:** 2026-11-14 · **Board:** group #1709 (#1763–#1770) · **Status:** draft for review

## Goal

Stay compliant with Slack's terms without taking features away from customers.

- **Full** (Полный): the workspace's own Slack app, created from our manifest inside that workspace and approved there. Watchtower syncs locally and every feature works. For Slack this is an internal, customer-built app (scenario A of the research notes), the shape the corp build already has.
- **Live** (Живой): the Slack connector in the user's own Claude or ChatGPT account (the official Slack MCP behind Anthropic's or OpenAI's Marketplace app). Watchtower ships no Slack app for it. It answers questions now and stores nothing beyond the chat transcript.
- Live is a **layer**, not an alternative: wherever the connector works, the chat and automations use it for what the local copy does not have — the first sync has not finished, the channel is outside the synced scope, the date is older than the backfill. With no Full app, Live is all there is, and the proactive features say so honestly.
- The shared public Slack app with a baked client id and secret is retired.

Everything stays on the user's Mac. There is no company hub and no server of ours that sees Slack data (#868).

Out of scope here: the screens (a separate spec with DesignShotCatalog mockups for every state, #1763 UI part); the Developer Policy hygiene items (#1769); the legal questions (#1770).

## Decisions

| # | Decision | Source |
|---|---|---|
| D1 | The modes are called **Full / Live** (Полный / Живой) in the UI and in code (`full`, `live`) | ask #1294 |
| D2 | Live is always on where the connector works, also next to Full: local first, the connector for gaps | ask #1294, comment #866 |
| D3 | Full syncs only the user's own scope (DMs, group DMs, channels the user is a member of); other public channels are reached through Live | ask #1294 |
| D4 | Entry into Full: a Slack bot that hands out the connect link, plus an MDM key | ask #1294 |
| D5 | No company hub, nothing hosted that carries Slack data | comment #868 |
| D6 | Strict: of Live answers only the chat transcript (and an automation run's own output) is kept — no index, memory, ideas or Knowledge, not even on the owner's press | ask #1296 (comment #870) |
| D7 | The bot needs no server: the admin's Watchtower publishes the bot's Home tab to every member | ask #1295 |
| D8 | The connect link is an OAuth link to the workspace app that lands on localhost; no page of ours on the web | ask #1295 |
| D9 | The admin creates the app with one paste: a Slack app configuration token | ask #1295 |
| D10 | Turns that used Live are marked and every consumer that makes chat text lasting skips them | ask #1296 |
| D11 | Accounts on the retired shared app keep working until Slack stops them; the app offers Full or Live; synced data follows the purge rules | ask #1295 |

## 1. The model

Per Slack workspace (team id) Watchtower knows two independent facts:

| Fact | True when | Writer | Stored in |
|---|---|---|---|
| `full` | a `slack_accounts` row for the team is `ok` and its client id is a workspace app (not the retired shared one) | `watchtower slack login`, the token refresher | `slack_accounts` (existing) + `client_id`, `refresh_token_expires_at` (new columns) |
| `live` | the last connector probe for this team succeeded with a real read call | the probe (`watchtower slack live probe`) only | `slack_live_status` (new table: team id, provider `claude`/`codex`, `ok`/`not_connected`/`needs_admin`/`no_plan`/`unavailable`, `checked_at`, error class) |

The mode the UI shows is derived, never stored: `full` → **Full** (with "Live also on" when `live`), only `live` → **Live**, neither → **Off**. Go and Swift derive it with the same table (dual path, shared JSON cases like `policy_cases.json`).

### The Live probe

Listing the connector's tools is not enough (Codex lists the 38 Slack tools before the OAuth, then fails with `Unknown tool`). The probe makes one real read call:

- Claude: `claude -p --input-format stream-json --output-format stream-json` (the chat's launch shape; plain `claude -p` loads no connectors), waits for `mcp_status` of `claude.ai Slack` up to 15 s, then calls one read tool (`slack_search_channels` with an empty query, limit 1). Write tools are disallowed for the probe.
- Codex: `codex exec` with apps on; calls `slack_list_workspaces`, which also gives the team ids the connector covers.
- When it runs: when the owner opens Connections → Slack, on the first chat turn that needs Slack with no probe newer than 24 h, and after the owner presses **Check again**. Never from the daemon on a timer (it spends the owner's subscription).
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

Two speeds (D3): DMs and group DMs every 15 minutes; member channels every 60 minutes; the history backfill covers the own scope only and keeps its one-chunk-per-cycle pacing. A `Retry-After` from Slack holds every Slack call of that account for its duration (existing limiter); a second 429 inside a cycle ends the cycle early.

What leaves the local copy: public channels the user is not a member of. Channel digests, Catch-Up, people cards and the knowledge index lose them; the chat reaches them through Live. The guide says so.

## 3. Live in the chat

- **Claude chat** already loads claude.ai connectors (`docs/features/chat-claude-ai-tools.md`). New: the Slack connector's tools enter `connectorpolicy` explicitly — read tools free, `slack_send_message`, `slack_schedule_message`, `slack_send_message_draft`, `slack_update_canvas`, `slack_create_canvas`, `slack_add_reaction` → Approve (CHAT-02/CHAT-05 unchanged, the table grows).
- **Codex chat**: apps enabled for the chat's `codex` launch when the owner signed in with ChatGPT (`features.apps`), the same policy table.
- **The rule in the system prompt** (one paragraph, Go-owned, both providers): answer Slack questions from the local tools first; each local Slack tool result carries a `coverage` line (`scope: own|none`, `synced_through`, `backfill_from`, `channel_in_scope`); for anything outside it use the connector, and say which part came from Live.
- **What is stored:** the chat transcript as today. Turns whose tool calls hit a Slack connector are marked `live_slack = 1` on `chat_messages` (migration). Consumers that turn chat text into something lasting skip marked turns (D6, strict): ideas mining from chats (`ideas_chat_floor`), memory ingestion from chats, the coach's chat-turn import, Add to Knowledge for an artifact of a marked turn (button disabled with the reason "built on Live Slack answers, which are not kept"), and `remember:` lines sent in a marked turn are stored only as the owner's own words, never with quoted connector text. Guard test `TestLIVE01_MarkedTurnsStayOutOfStores` lists every reader of `chat_messages` and fails on a new one that does not check the mark.

## 4. Live in automations

- `agent()` runs on the Claude provider move to the stream-json launch and wait for the connector the same way as the probe (≤ 15 s). Codex runs pass apps on.
- A recipe declares `slack:live` in its manifest to get the Slack connector's read tools (AUTO-01: the manifest stays the only source of permissions). Write tools stay proposals (AUTO-02).
- `slack.*` events and reaction triggers need Full; saving a recipe that needs them on a Live-only workspace is refused with the reason.
- Storage (D6): a run's own output (`output.inbox`/`report`/`slack`) is that run's transcript and is kept like any run output; it is marked `live_slack` and nothing reads it into ideas, memory, the knowledge index or the briefing's FROM YOUR AUTOMATIONS block.
- Pace: a recipe with `slack:live` may run at most hourly (subscription "ordinary individual use", RTS ≈ 10 calls/min per user plus a daily cap). The validator refuses a tighter schedule.

## 5. Entry into Full

### 5.1 The admin creates the workspace app (one paste, D9)

1. Connections → Slack → **Set up for my company**. Watchtower opens `https://api.slack.com/apps` on the configuration tokens section and asks for one paste: the configuration token (lives 12 h, used once, never stored).
2. `apps.manifest.create` with our manifest: the user scopes of today minus the unused write scopes, a bot user with `users:read` only, the Home tab on, PKCE on, token rotation on, the 127.0.0.1 redirect URLs. The response gives `app_id`, `client_id`, `client_secret`.
3. The admin's Watchtower installs the app with bot + user scopes through the existing loopback OAuth with the client secret (desktop PKCE cannot ask for bot scopes). The secret and the bot token go to the admin's token store (0600, the same place as user tokens); no other Mac ever holds them.
4. If the workspace requires approval and the creator is not an admin, Slack files an install request: Watchtower shows "Waiting for your admin's approval" and resumes from the stored `app_id` when the owner presses **Check again**.

### 5.2 The bot hands out the link (D4, D7)

The admin's Watchtower publishes the bot's Home tab (`views.publish`, Tier 4) to every member: "Watchtower for <workspace>" with a **Connect Watchtower** link. It publishes once after setup, then once a day to members it has not published to (`slack_bot_home` table: user id, published hash, time), and again for everyone when the link changes. No events, no Socket Mode, no server: when the admin's Mac is off, existing members still see the tab; new members get it with the next daily pass.

### 5.3 The link (D8)

The link is `http://127.0.0.1:18501/slack/connect?team=<T>&client=<client id>`. It starts the OAuth on the user's own Mac and comes back there; nothing of ours on the web is involved.

- A Slack OAuth link cannot be fully static: PKCE needs a fresh `code_challenge` whose verifier only the Mac holds, and an authorize link without it would need the client secret for the exchange, which colleagues must not have. So the link's first hop is the Watchtower app's loopback listener: it checks the request, makes the PKCE pair, and redirects the browser to `https://slack.com/oauth/v2/authorize` for that client id with user scopes and `redirect_uri=http://127.0.0.1:18501/callback`. Slack sends the code back to the same listener, which exchanges it with the verifier, no secret.
- The listener is new: the Desktop app keeps it open on 127.0.0.1 while the app runs (today the redirect port is only intercepted inside the login web view). It answers `/slack/connect` and `/callback` only, GET only, checks `Host`, and never serves files.
- Before redirecting to Slack, Watchtower comes to the front and asks "Connect workspace <team> through app <client id>?" — any web page can open a loopback URL, and nothing starts without the owner's press.
- Watchtower not running or not installed: the browser shows "can't connect". The Home tab says so next to the link ("open Watchtower first; no Watchtower yet — download it from <release page>").
- The manifest's redirect URLs gain `http://127.0.0.1:18501/callback` (the PKCE loopback form; port 18501 sits outside the 18491–18500 range the CLI login binds, so the two never collide); the existing `https://127.0.0.1:1849x` entries stay for the admin's secret-based install.
- A team in the link that differs from the team Slack returns is refused.

### 5.4 MDM (D4)

New managed key `SlackApps`: a list of `{team_id, client_id}` (POLICY-01: forced values only, a wrong type fails closed; POLICY-02: Go and Swift read it alike). Connections → Slack lists them with a one-click **Connect**. The corp build keeps its baked credentials until its admin moves to the key; nothing changes for it on day one.

### 5.5 Tokens

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
| Tokens | refresh races login | flock; holder wins; the other re-reads | `TestSlackRefresh_LockRace` |
| Tokens | offline past 30 days | Re-login state | `TestSlackRefresh_Expired` |

## 8. Writers of the same data

- `slack_accounts` + token files: `slack login` and the refresher, serialised by the per-account flock (5.5). The daemon's sync reads only.
- `slack_live_status`: the probe only; the Desktop reads.
- `slack_bot_home`: the admin's daemon only (the only process with the bot token).
- `chat_messages.live_slack`: the chat process when it stores the turn, in the same transaction as the turn.

## 9. Promises → tasks → tests

| Promise | Task | Test |
|---|---|---|
| Full/Live/Off derived the same in Go and Swift | T2 | `slack_mode_cases.json` in both suites |
| A Live probe is a real read call | T3 | `TestLiveProbe_Classifies` |
| Full syncs only the own scope, two speeds | T1 spike → T4 | `TestOwnScope_*` |
| Live answers never reach lasting stores | T5 | `TestLIVE01_MarkedTurnsStayOutOfStores` |
| Slack connector writes need Approve | T5 | `connectorpolicy` table test |
| Automations get Live only through `slack:live`, at most hourly | T6 | `TestManifest_SlackLive*` |
| One-paste admin setup that resumes | T7 | `TestAppSetup_*` |
| The bot's Home tab reaches every member, resumable | T8 | `TestBotHome_*` |
| Link and MDM connect with PKCE, no secret | T9 | `TestSlackLinkConnect_*`, `policy_cases.json` |
| Tokens refresh before expiry, one writer | T9 | `TestSlackRefresh_*` |
| The shared app is retired, old accounts move | T10 | `TestSlack01_*` unchanged + `TestSharedAppBanner` |
| Screens show the mode and honest empty states | screens spec | that spec's tests |

Tasks: T1 spike (narrowing method, PKCE + rotation via manifest, `views.publish` to members who never opened the app, OR of repeated `in:`) — the plan depends on its result; T2 model + migration; T3 probe; T4 own-scope sync; T5 chat; T6 automations; T7 admin setup; T8 bot; T9 link, MDM, tokens; T10 retirement, guide and feature notes.

## 10. Inventory touched

- SLACK-01 — unchanged (the move to Full soft-removes).
- CHAT-02, CHAT-05 — unchanged; the connector policy table grows.
- AUTO-01, AUTO-02 — unchanged; a new capability `slack:live`.
- POLICY-01/02 — a new key `SlackApps`.
- New: LIVE-01 (marked turns stay out of lasting stores), SLACKMODE-01 (Go↔Swift mode derivation).

## 11. Open

- The spike's answer on narrowing (T1).
- Anthropic's and OpenAI's view on background use of the connector (#1770).
