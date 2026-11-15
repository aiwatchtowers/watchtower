# Slack — Full and Live

**Date:** 2026-11-14 · **Board:** group #1709 (#1763–#1770) · **Status:** draft for review

## Goal

Stay compliant with Slack's terms without taking features away from customers.

- **Full** (Полный): the workspace's own Slack app, created from our manifest inside that workspace and approved there. Watchtower syncs locally and every feature works. For Slack this is an internal, customer-built app (scenario A of the research notes), the shape the corp build already has.
- **Live** (Живой): the Slack connector in the user's own Claude or ChatGPT account (the official Slack MCP behind Anthropic's or OpenAI's Marketplace app). Watchtower ships no Slack app for it. It answers questions now and stores nothing beyond the chat transcript.
- Live is a **layer**, not an alternative: wherever the connector works, the chat and automations use it for what the local copy does not have — the first sync has not finished, the channel is outside the synced scope, the date is older than the backfill. With no Full app, Live is all there is, and the proactive features say so honestly.
- The shared public Slack app with a baked client id and secret is retired.

Everything stays on the user's Mac. There is no company hub and no server of ours that sees Slack data (#868).

Out of scope here: the screens — a separate spec with DesignShotCatalog mockups for every state (#1763 UI part, written right after this one is approved). It must cover: the mode on Connections → Slack (Full, Full + Live, Live, Off, Live checked N h ago); the FeatureReadiness state `needsFullSlack` ("needs your workspace's app") on every Slack-dependent screen — digests, Inbox, tracks, people, ideas, Knowledge, Morning brief, Catch-Up and the phone; **Set up for my company**; the paste of the configuration token; waiting for approval; the connect confirm; port busy; the connect-code paste; **Add the link to the app**; the shared-app banner; the disabled **Add to Knowledge** on a Live artifact with its reason. Also out of scope here: the Developer Policy hygiene items (#1769); the legal questions (#1770).

## Decisions

| # | Decision | Source |
|---|---|---|
| D1 | The modes are called **Full / Live** (Полный / Живой) in the UI and in code (`full`, `live`) | ask #1294 |
| D2 | Live is always on where the connector works, also next to Full: local first, the connector for gaps | ask #1294, comment #866 |
| D3 | *Superseded by D16.* Full syncs only the user's own scope (DMs, group DMs, mentions of the user, channels the user is a member of); other public channels are reached through Live | ask #1294 |
| D12 | *Superseded by D16.* Two speeds: DMs and mentions every 15 minutes, member channels every 60 minutes | ask #1294 (the chosen option: "ЛС/упоминания каждые 15 мин, свои каналы реже (30–60 мин)") |
| D16 | Full keeps the blanket sync of everything the user can see, for every account, with a retry chain through rate limits, self-balancing request packing, a cadence that adapts to data volume and 429s, and a per-channel **Stop syncing** plus suggestions of channels not to sync | ask #1337 |
| D13 | No client secret is stored anywhere; everybody, the admin included, logs in with PKCE | conversation 2026-11-14 (the owner rejected any dependence on the admin's Mac, ask #1301) |
| D4 | Entry into Full: the app in Slack hands out the connect link, plus an MDM key | ask #1294, refined by D7 |
| D5 | No company hub, nothing hosted that carries Slack data | comment #868 |
| D6 | Strict: of Live answers only the chat transcript is kept — no index, memory, ideas or Knowledge, not even on the owner's press | ask #1296 (comment #870) |
| D14 | An automation run on Live keeps its own output (the Inbox card, report) as that run's transcript; nothing reads it further | ask #1298 |
| D15 | A recipe with `slack:live` runs at most hourly; the validator refuses a tighter schedule | ask #1298 |
| D7 | No bot and no Mac that must stay on: the link lives in the app's own About page in Slack, written once at setup | conversation 2026-11-14 (after ask #1301) |
| D8 | The connect link starts the workspace app's OAuth on the clicker's own Watchtower (first hop through its loopback listener, fresh PKCE, no secret) and lands on localhost; no page of ours on the web | ask #1295, conversation 2026-11-14 (after ask #1301) |
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

## 2. Full: adaptive sync of everything the user can see (D16)

*Amended 2026-11-15 (ask #1337). This section replaced "syncing only the user's own scope" (D3, D12). Own-scope-only sync is dropped.*

Full keeps today's sync for every account: one blanket `search.messages after:D` a cycle (sorted by timestamp, ascending) saves what the user can see — DMs, group DMs, private channels the user is in, and public channels. On top of it come four things:

1. **A retry chain that pushes through rate limits.** A 429 waits its `Retry-After` (the account-wide hold of the existing limiter) and the call is retried, with no fixed retry count, until the cycle's fetch deadline. Work fetched before a 429 is never thrown away: the search's page position is kept, and the next attempt (later in the same cycle, or in the next cycle) continues from it instead of starting the window again. The watermark still moves only when a window has been read to its end.
2. **Self-balancing packing.** Each account's limiter keeps one bucket per Slack tier instead of today's single 40/min bucket for every method. Each bucket starts at the documented tier rate (20, 50 or 100 per minute) and probes up to twice that after runs of successes; a 429 halves it, down to a quarter of the documented rate (AIMD). Every call uses Slack's largest allowed page size. A small mention query (`<@user> after:D`) runs before the blanket search, so mentions and the Inbox stay fresh even when the blanket search is cut short.
3. **Adaptive cadence.** How often the Slack sync runs follows the account's 429s and data volume. A run that hit 429s doubles the interval to the next Slack sync, up to 60 minutes, and its unfinished pages wait for that interval too. A clean, busy run (many pages) goes straight back to `sync.poll_interval`. Runs that bring almost nothing lengthen the interval step by step, up to 60 minutes. Other clean runs halve it toward the base. A clean run that stopped at its deadline with pages left is due again next cycle. The other sources keep the daemon's own interval.
4. **"What I don't need".** The user can mark channels **Stop syncing**. The sync then stores no new messages from them, except messages that mention the user. **Sync again** fetches what was missed in a one-off, paced history fetch of that channel, and lifts the AI mute only if Stop syncing had set it. Statistics suggests channels to stop syncing, built on its existing recommendations (mute/leave/favorite). An excluded channel counts as out of the synced copy for the chat's `coverage`, so the chat asks Live for it.

Cost model (unchanged): calls per person per hour ≈ cycles per hour + public messages seen per hour / 100. With a shared per-workspace quota (`search.messages` ≈ 1,200/h), the volume term sets a ceiling of about 1,200 / (workspace messages per hour / 100) people, whatever the cadence: ≈ 145 people at 20k public messages a day. Adaptation keeps a growing workspace under the quota by spreading the shortfall across everyone's cadence instead of failing hard, and mentions stay first. Excluding a channel saves storage and AI work but not search calls, because the blanket search still returns its messages. The spike checks whether a short `-in:#channel` list can also take excluded channels out of the query.

Inbox detection follows when a Slack message was stored (`messages.synced_at`), not its timestamp. Adaptive cadence and resumed pages store messages after the Inbox watermark has moved past their timestamps, and they must still be detected. The INBOX-09 extension is approved in ask #1337.

## 3. Live in the chat

- **Claude chat** already loads claude.ai connectors (`docs/features/chat-claude-ai-tools.md`). New: the Slack connector's tools enter `connectorpolicy` explicitly — read tools free, `slack_send_message`, `slack_schedule_message`, `slack_send_message_draft`, `slack_update_canvas`, `slack_create_canvas`, `slack_add_reaction` → Approve (CHAT-02/CHAT-05 unchanged, the table grows).
- **Codex chat**: apps enabled for the chat's `codex` launch when the owner signed in with ChatGPT (`features.apps`). Codex runs without approvals, so its Slack app is read-only by an allow-list of read tools; sending goes through Watchtower's `send_slack_message` (Approve, needs Full). With Live only, a Codex chat cannot send (v1 limit).
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

1. Connections → Slack → **Set up for my company**. Watchtower opens `https://api.slack.com/apps` on the configuration tokens section and asks for one paste: the configuration token (lives 12 h, held in memory for this setup only, never stored).
2. `apps.manifest.create` with our manifest: the user scopes of today minus the unused write scopes, no bot user, PKCE on, token rotation on, the PKCE loopback redirect URL. The response gives `app_id` and `client_id`; the `client_secret` it also returns is dropped at once — nothing in this design ever uses it.
3. Right away, with the same configuration token, `apps.manifest.update` writes the connect link into the app's description (5.2). The app id and client id are stored with the admin's account so a broken setup resumes (step 5).
4. The admin connects like everyone else: the same PKCE login with user scopes (5.3).
5. If the workspace requires approval and the creator is not an admin, Slack files an install request: Watchtower shows "Waiting for your admin's approval" and resumes from the stored `app_id` when the owner presses **Check again**. A failed `apps.manifest.update` (token expired in between) leaves the app working without the link in its description; Connections offers **Add the link to the app** with a fresh configuration token.

After setup nothing depends on the admin or the admin's Mac: the app, its client id and its description live in the workspace.

### 5.2 The app's own page hands out the link (D4, D7)

Every member can open the Watchtower app in Slack; its **About** tab shows the manifest's `long_description`. The setup writes there: "Watchtower for <workspace> — connect: <link>" plus a connect code (`<team>:<client id>`) to paste into Watchtower when the link is not clickable. No bot user, no Home tab, no token, no server, no Mac that has to stay on. Whether Slack renders a link in `long_description` as clickable is checked in the spike (T1); the code is the fallback either way.

### 5.3 The link (D8)

The link is `http://127.0.0.1:18551/slack/connect?team=<T>&client=<client id>`. It starts the OAuth on the user's own Mac and comes back there; nothing of ours on the web is involved.

- A Slack OAuth link cannot be fully static: PKCE needs a fresh `code_challenge` whose verifier only the Mac holds, and an authorize link without it would need the client secret for the exchange, which colleagues must not have. So the link's first hop is the Watchtower app's loopback listener: it checks the request, makes the PKCE pair, and redirects the browser to `https://slack.com/oauth/v2/authorize` for that client id with user scopes and `redirect_uri=http://127.0.0.1:18551/callback`. Slack sends the code back to the same listener, which exchanges it with the verifier, no secret.
- The listener is new: the Desktop app keeps it open on 127.0.0.1:18551 while the app runs (today the redirect port is only intercepted inside the login web view). 18551 is the first port outside every OAuth range already in use (Slack 18491–18500, Calendar 18501–18510, Jira 18511–18520, Gmail 18521–18530, Outlook/IMAP and Linear 18531–18540, Quick Connections 18541–18550); `TestOAuthPortRanges_Disjoint` collects every listener's port range and asserts 18551 is in none of them and no new range overlaps another; the one existing overlap (Linear 18531–18535 inside Outlook/IMAP 18531–18540) is listed as a known exception in the test, not fixed here.
- Port busy (another app holds 18551): the listener does not start, Connections → Slack shows "The connect link cannot reach Watchtower: port 18551 is busy", and the owner can paste the link into Watchtower instead; pasting runs the same flow. It answers `/slack/connect` and `/callback` only, GET only, checks `Host`, and never serves files.
- Before redirecting to Slack, Watchtower comes to the front and asks "Connect workspace <team> through app <client id>?" — any web page can open a loopback URL, and nothing starts without the owner's press.
- Watchtower not running or not installed: the browser shows "can't connect". The app's description says so next to the link ("open Watchtower first; no Watchtower yet — download it from <release page>").
- The manifest's only redirect URL is `http://127.0.0.1:18551/callback` (the PKCE loopback form); nobody uses a client secret.
- Pasting the connect code (5.2) into Connections → Slack runs the same flow without the browser's first hop.
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
| Sync | shared quota 429 | `Retry-After` honoured account-wide; retried until the cycle's fetch deadline; the rate halves (AIMD) and the cadence backs off | `TestAdaptive_RetryChainPushesThrough`, `TestAIMD_*`, `TestCadence_*` |
| Sync | the deadline, a sleep or a quit mid-pagination | the page position is kept in memory and the next attempt resumes there; the watermark does not move; a restart re-reads the window (upserts) | `TestSearchResume_*` |
| Sync | a message stored after the Inbox watermark passed its timestamp | detected, because detection follows `synced_at` | `TestInbox_HourlyLateMessageDetected` |
| Sync | a channel marked **Stop syncing** | no new messages stored except mentions of the user; the data already stored stays | `TestSyncExcluded_*` |
| Setup | config token expired or wrong | stop before any call; ask for a new one | `TestAppSetup_BadConfigToken` |
| Setup | the app is created but `apps.manifest.update` fails | the app works; its description has no link; **Add the link to the app** retries with a fresh token | `TestAppSetup_LinkUpdateFails` |
| Setup | the secret in the create response | dropped, never written anywhere | `TestAppSetup_SecretNeverStored` |
| Setup | app created, install not finished (Mac closed, approval pending) | `app_id` + client id kept; **Check again** resumes at install; a second create is never sent | `TestAppSetup_ResumeAfterCreate` |
| Link | Watchtower not running / not installed | the browser cannot connect; the app's description says to open or download Watchtower | manual |
| Link | a web page opens the loopback URL by itself | the confirm prompt; nothing starts without the owner's press | `TestSlackConnectListener_RequiresConfirm` |
| Link | the app quits between the redirect and the callback | the verifier is gone with the process; the callback answers "start again"; nothing stored | `TestSlackConnectListener_CallbackWithoutFlow` |
| Link | team mismatch | refused, nothing stored | `TestSlackLinkConnect_TeamMismatch` |
| Link | port 18551 busy | the listener does not start; Connections says so; pasting the link runs the same flow | `TestSlackConnectListener_PortBusy`, `TestOAuthPortRanges_Disjoint` |
| Chat | a later turn restates Live text | the conversation is marked from its first Live turn; every later turn is skipped too | `TestLIVE01_LaterTurnsMarked` |
| Tokens | refresh races login | flock; holder wins; the other re-reads | `TestSlackRefresh_LockRace` |
| Tokens | offline past 30 days | Re-login state | `TestSlackRefresh_Expired` |

## 8. Writers of the same data

- `slack_accounts` + token files: `slack login` and the refresher, serialised by the per-account flock (5.5). The daemon's sync reads only.
- `slack_live_status`: the probe, and any chat turn or automation run that called a Slack connector tool; an upsert keeps the row with the newest `checked_at`; the Desktop reads.
- The app's description (`long_description`): only the setup (`apps.manifest.update`), once, or again from **Add the link to the app**; the last update wins.
- `chat_conversations.live_slack_since`: the Desktop's turn store (Swift is the only writer of chat rows): `ChatTurnStore.stepStarted` when the first Slack connector step starts, and `finalizeTurn` as a backstop, whichever comes first; the value is the Live turn's assistant message id; set once, never moved or cleared. It is the only place the mark lives (no per-message column).
- `channel_settings.sync_excluded` (D16): only `watchtower channels exclude|include`; the Desktop's Statistics runs that CLI; the last write wins; the sync reads it once per cycle. `catchup_from`/`catchup_to` (the Sync again catch-up, walked newest to oldest with a persisted upper bound): set by Sync again, moved down and cleared only by the sync, never while the channel is excluded.
- `messages.synced_at` (D16): the first insert of a row only (the sync's clock for new arrivals, the message's own time for history; a trigger fills any other insert); never updated.
- `automation_runs.live_slack`: the executor of that run, set when the run's `agent()` step calls a Slack connector tool.

## 9. Promises → tasks → tests

| Promise | Task | Test |
|---|---|---|
| Full/Live/Off derived the same in Go and Swift | T2 | `slack_mode_cases.json` in both suites |
| A Live probe is a real read call | T3 | `TestLiveProbe_Classifies` |
| Full syncs everything visible, adaptively: retry chain, packing, cadence, Stop syncing (D16) | T4 (plan `2026-11-15-slack-adaptive-sync.md`) | `TestAdaptive_*`, `TestAIMD_*`, `TestCadence_*`, `TestSearchResume_*`, `TestSyncExcluded_*` |
| Live answers never reach lasting stores, later turns included | T5 | `TestLIVE01_MarkedTurnsStayOutOfStores`, `TestLIVE01_LaterTurnsMarked`, Swift `LiveSlack01GuardTests` |
| Slack connector writes need Approve | T5 | `connectorpolicy` table test |
| Automations get Live only through `slack:live`, at most hourly | T6 | `TestManifest_SlackLive*` |
| One-paste admin setup that resumes | T7 | `TestAppSetup_*` |
| The connect listener never collides and needs the owner's press | T8 | `TestOAuthPortRanges_Disjoint`, `TestSlackConnectListener_*` |
| Mentions of the user arrive first, even when the blanket search is cut short | T4 | `TestAdaptive_MentionQueryFirst` |
| The Live status is as fresh as its last real use | T3, T5 | `TestLiveStatus_UpdatedByChatUse` |
| The connect link lives in the app's About page, nobody's Mac needed after setup | T7 | `TestAppSetup_WritesLinkToDescription` |
| Link and MDM connect with PKCE, no secret | T8 | `TestSlackLinkConnect_*`, `policy_cases.json` |
| Tokens refresh before expiry, one writer | T8 | `TestSlackRefresh_*` |
| The shared app is retired, old accounts move | T9 | `TestSlack01_*` unchanged + `TestSharedAppBanner` |
| Screens show the mode and honest empty states | screens spec | that spec's tests |

Tasks: T1 spike (`-in:` for a short list of excluded channels, PKCE + rotation via manifest, whether Slack renders a link in the app's `long_description` as clickable) — the plan depends on its result; T2 model + migration; T3 probe; T4 adaptive sync (D16); T5 chat; T6 automations; T7 admin setup and the description link; T8 link, MDM, tokens; T9 retirement, guide and feature notes.

## 10. Inventory touched

- SLACK-01 — unchanged (the move to Full soft-removes).
- CHAT-02, CHAT-05 — unchanged; the connector policy table grows.
- AUTO-01, AUTO-02 — unchanged; a new capability `slack:live`.
- POLICY-01/02 — a new key `SlackApps`.
- New: LIVE-01 (marked turns stay out of lasting stores), SLACKMODE-01 (Go↔Swift mode derivation).

## 11. Open

- The spike's answer on `-in:` for excluded channels (T1); narrowing to the own scope is no longer needed (D16).
- Anthropic's and OpenAI's view on background use of the connector (#1770).
