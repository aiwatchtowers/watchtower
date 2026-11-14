# Slack Live — the owner's own Claude or ChatGPT Slack connector (2026-11-14, #1709; chat #1764, automations #1765)

Spec `docs/superpowers/specs/2026-11-14-slack-full-and-live-design.md`, plan `docs/superpowers/plans/2026-11-14-slack-live-plan-a.md` (plan A; the Full part is plan B). Live is the Slack connector of the owner's own Claude or ChatGPT account. Watchtower ships no Slack app for it and stores nothing it returns beyond the chat transcript (decision D6, strict). It is a layer over the local copy, never a replacement: the chat and automations use local data first and the connector for gaps. Contracts: LIVE-01 (`docs/inventory/chat.md`), SLACKMODE-01 (`docs/inventory/slack-accounts.md`); AUTO-01/02 unchanged.

## The mode and the status table

- Migration `00188_slack_live.sql`: table `slack_live_status` (team id, provider `claude`/`codex`, status `ok`/`not_connected`/`needs_admin`/`no_plan`/`unavailable`, error class, `checked_at`, `connector_id`), plus `chat_conversations.live_slack_since` and `automation_runs.live_slack`. `checked_at` is fixed-width UTC RFC 3339 nanoseconds so string order is time order. `db.UpsertSlackLiveStatus` is newest-wins and keeps the stored `connector_id`; `ListSlackLiveStatus` is newest first.
- `internal/slackmode` (`Derive`, `LiveOn`) and the Swift twin `SlackMode.swift` derive Full / Live / Off from the same JSON cases (SLACKMODE-01). The mode is never stored.

## The probe (`internal/slacklive`, `watchtower slack live probe --provider --if-older --json`)

One real read call, because listing tools proves nothing (Codex lists the Slack tools before the OAuth and then fails `Unknown tool`).

- **Claude:** the chat's stream-json launch shape, waits for `mcp_status` of the claude.ai Slack connector (15 s), calls one read tool. `claudeArgs()` adds `--setting-sources project,local` and `--disallowedTools` for the six write tools; any other control request is answered with a control error.
- **Codex:** `codex exec` with apps on, read-only. The connector id comes from the apps cache (`cache/codex_apps_tools`) before launch. A missing cache entry costs one warm-up run with no tool callable (`codex.WarmUpAppOverrides`: `features.apps`, default tools off, every configured app and tool off), then a re-read; still missing → `connector_id_unknown`, no further run. Team ids come from `structured_content.teams[].id`. The owner's MCP servers are off in both runs (`codex.NoMCPServerArgs`).
- **Rows:** an `ok` verdict writes the identified teams (Claude: the permalink domain matched to `slack_accounts.team_domain`; Codex: T-ids) and team `''`; accounts the provider did not show get `not_connected/workspace_not_connected`. Any non-ok verdict writes `''` plus every Slack account's team id, so a stale `ok` cannot survive. A missing CLI is `not_connected/cli_missing`. `classify` reads plan and unknown-tool wording only from tool text.
- **When:** Connections → Slack opens (`SlackLiveStatusCenter`), the first local Slack tool of a chat with no row newer than 24 h (one background probe), and a chat or automation use of a connector tool (writes the status; Claude `claude_ai_Slack:<name>`, Codex `codex_apps:slack.<name>`, only names in `slacklive.ReadTools`; writes never write a status). Never from the daemon on a timer.

## Chat (main surface only)

- **Claude:** `connectorpolicy` rows for `claude_ai_Slack`: the 13 read tools Allow, the six write tools Ask (the normal connector approval card). `claudeSlackLive` decides when the prompt block applies (connectors on, Slack not switched off, newest Claude row `ok` or absent).
- **Codex:** apps stay on only for the main chat (`Client.SetChatApps`), only with a ChatGPT login (`codex.ChatGPTLogin`) and an `ok` probe row with a connector id (`codexSlackConnector`). The read-only allow-list is built by `codex.ReadOnlyAppOverrides(home, id, ReadTools)` from the owner's own `config.toml` (the app on with default tools off and the listed tools on; every other configured app and every unlisted configured tool of it off). A missing config adds nothing; an unreadable or invalid one is an error and the chat gets no apps and no Live promise (fails closed). App ids and tool keys must match `^[A-Za-z0-9_-]+$`. With Live only (no Full), a Codex chat cannot send to Slack: sending is Watchtower's `send_slack_message`, which needs Full (v1 limit).
- **Prompt:** `PromptOptions.SlackLive` adds `slackLiveBlock`: local tools first, `coverage` for the gaps, say which part came from Live.
- **`list_messages` (R9):** returns `{"messages":[…],"coverage":{scope,synced_through,backfill_from,channel_in_scope}}` (`db.SlackCoverage`) only on the main chat surface; every other surface keeps the bare array. `slackMessageSources` accepts both shapes.

## LIVE-01: marked turns stay out of lasting stores

- **Writer (R10):** the Desktop turn store (the only writer of chat rows) sets `live_slack_since` to the Live turn's assistant message id when a Slack step starts (`ChatTurnStore.stepStarted`, `LiveSlackMark.markIfSlackStep`) and again at `finalizeTurn` (`markIfUsed`) as a backstop, whichever comes first; set once, never moved. Marks on `mcp__claude_ai_Slack__*` and `mcp__codex_apps__slack.*`, write tools included.
- **Readers:** `db.ChatNotLiveSlack` (`m.id < live_slack_since` or no mark) is applied in `ListChatTurnsForIdeas`, `ListOwnerChatTurns`, `OwnerChatTurnExists`, `ListOwnerChatTurnsSince`, `ListRecentChatTurns`; the kb `chat_artifact` source skips a marked conversation; `ChatArtifactQueries.keep` throws `ChatArtifactKeepError.liveSlack` and the panel shows the reason. `instructions remember` in a marked conversation stores a line only when it is verbatim in the owner's message (`db.LiveSlackOwnerLineOK`, code `not_owner_text`). The owner's prompt of the Live turn precedes the mark and stays readable.
- **Guards:** Go `internal/db/live01_test.go`, `TestLIVE01_KeptArtifactSkipped`, Swift `LiveSlack01GuardTests` (its reader list is file-level, not function-level).

## Automations (`slack:live`)

- **Manifest:** a verb of `slack`, unscoped (`slack:live@T1` is refused: "slack:live takes no @scope"; `capabilitySpec.unscopedVerbs`). `Manifest.SlackLive()`; `FeedsSourcesToLLM` counts it as a source. Connector writes are not granted: they go through `send_slack_message` proposals (AUTO-02).
- **Hourly (D15):** the validator (`checkLiveCadence`, the scheduler's own cron `next`, system zone, DST windows over the next year) refuses a schedule tighter than an hour. The executor enforces it for every trigger including dry runs (`limitLiveSlack` before the claim in `poll.consider` and `ExecuteInlinePinned`): a limited run ends `cancelled`/`not_runnable` with "Live Slack: at most once an hour" (`LimitQueuedLiveSlackRun`), counted against the newest `started_at` of any run (`LastLiveSlackRunStart`).
- **Full triggers:** `CheckRecipePolicy` refuses a `slack:live` recipe with a `slack.*` event or reaction trigger when no Full account exists (`HasFullSlackAccount`: enabled, not removed, status ok), at save and at `save_automation` apply.
- **Claude child:** `ai.Client.SetStreamJSONInput`/`SetStreamJSONHooks` switch the launch to stream-json, drop `--strict-mcp-config`, wait up to 15 s for the connector (none → the agent runs without Slack, one log line). The gate allows the read tools, denies other `mcp__claude_ai_Slack__*` tools ("use send_slack_message") and every other tool. Non-Live runs keep their argv byte for byte (`TestAgentRun_NoSlackLiveKeepsArgv`).
- **Codex child:** same decision and `ReadOnlyAppOverrides` as the chat, against the run home; any error means no apps. `Client.SetToolCallObserver` marks use.
- **Marking and outputs (D14):** `MarkAutomationRunLiveSlack` sets `automation_runs.live_slack` when the agent used Live (even if the call then failed). The run's outputs stay in the Inbox; `ListAutomationOutputsSince` skips Live runs, so the briefing's FROM YOUR AUTOMATIONS block does not carry them. Denied connector writes are recorded in the agent step's summary as `slack_live_denied`.

## v1 limits

- Claude Free (does the connector exist there) is unknown.
- Codex apps in an automation's per-run `CODEX_HOME` were not verified against a real CLI; the Claude path is covered by a stub speaking stream-json.
- Codex apps in a run: `openai/codex#47839`.
- No Live on the phone.
- The hourly check runs before the claim, not inside it: a recipe with concurrency above 1 could start two runs in one poll. `ExecuteBuiltinInline` is not limited.
- The Full-trigger refusal is only at save (`validate` has no database).
- A denied connector write outside the six probe-listed tools is the only one the gate can see; denials are not recorded when the agent call itself fails.
- Live Claude automation runs also start the owner's user-scoped MCP servers (no `--strict-mcp-config`); their tools are denied.
- Runtime-B agents (Ollama and the like) ignore `slack:live`.
