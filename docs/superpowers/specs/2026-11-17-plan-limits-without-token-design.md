# Claude plan limits without the token

**Date:** 2026-11-17 · **Board:** target #1885 · **Status:** draft for review
**Parent specs:** `docs/superpowers/specs/2026-10-15-claude-plan-limits-design.md` (the Claude reader), `docs/superpowers/specs/2026-11-01-plans-codex-design.md` (Plans, both providers). **Feature note:** `docs/features/claude-plan-limits.md`. **Inventory:** `docs/inventory/plan-usage.md`.

## Goal

The Claude half of **Usage → Plans**, the menu-bar counters, Home's plan numbers and Claude's limit notifications keep working, but Watchtower no longer touches Claude Code's sign-in. Today the reader takes Claude Code's OAuth access token from the Keychain (or `~/.claude/.credentials.json`) and calls `GET https://api.anthropic.com/api/oauth/usage` itself. Claude Code's legal page says developers "may not collect, store, or intermediate Claude.ai credentials or session tokens" (https://code.claude.com/docs/en/legal-and-compliance). The owner decided in ask #1415: «Переделать без токена».

After this change Watchtower asks the installed, unmodified `claude` command for its own usage numbers. Claude Code reads its credentials and calls its endpoint itself; Watchtower only sees the answer.

**One visible feature can be lost.** The "Claude usage by surface" block (Claude Code / Chats / Cowork shares under Additional limits) comes from a field the `get_usage` answer passes through today but its schema does not describe. If a Claude Code release stops passing it, the block disappears until Claude Code exposes it again; everything else on the screen keeps working. The owner decides whether that is acceptable (A4; the group goal is «без потери функционала»).

No production code changes with this spec. The mockups are design-only SwiftUI scenes in the DesignShots test target.

## Context (recon, 2026-11-17)

- **Token read, Go only.** `internal/planusage/credentials.go`: `CredentialSource.Load` runs `/usr/bin/security find-generic-password -s "Claude Code-credentials" -w`, falls back to `~/.claude/.credentials.json`, decodes `claudeAiOauth.{accessToken,expiresAt,subscriptionType}`. `internal/planusage/client.go`: `Client.Fetch` sends `Authorization: Bearer <token>` and `anthropic-beta: oauth-2025-04-20` to `/api/oauth/usage`. `internal/planusage/poller.go`: `Poller{Store, Creds, Client, Now, Logger}`; `token_expired` when `expiresAt` passed or on HTTP 401. `cmd/plan_usage_daemon.go`: `newPlanUsagePoller` wires `DefaultCredentialSource()` and `NewClient(Version)`; the Claude `Provider.Poll` turns a stored `stale/token_expired` into `no_credentials`. `internal/llmusage/leaves_test.go` lists `planusage.DefaultCredentialSource` in `knownNonLLMExec`. Nothing caches the token: it lives for one poll.
- **Swift never reads it.** The Desktop reads `plan_usage_status` / `plan_usage_samples` only (`PlanUsageQueries`, `PlanUsageCenter`, `HomeNumbersQueries` reads keys `session` and `weekly_all`). The only Keychain code in the Swift trees is Watchtower's own (`WatchtowerKit/.../KeychainBackend.swift`). A repo-wide search finds no other reader of `Claude Code-credentials`, `claudeAiOauth`, `.credentials.json` or `/api/oauth/usage`.
- **Routing does not use the gauge.** Claude ↔ Codex quota routing works on reactive evidence: a `rate_limit_event` / failed `result` seen by the leaf (`providers.ClaudeLimitTracker`, `ClaudeResultFailure`) and the installation health store. `docs/features/provider-fallback.md`: "Routing uses local reactive quota evidence, not usage percentages. No additional account poller or authentication manager was introduced." No routing package imports `internal/planusage`; `history-backfill` retired its plan gate (BACKFILL-03, ask #655).
- **Codex** reads its limits through `codex app-server` (`internal/codex/usage.go`: `initialize` → `account/read {refreshToken:false}` → `account/rateLimits/read`), never `account/login`, never `auth.json`. See §10.

## Data sources considered

Checked against the installed Claude Code 2.1.326 (`claude --help`, the CLI's bundled SDK schema) and live read-only probes run outside the repo (they printed field names and types only, never values).

| Source | What it gives | Verdict |
|---|---|---|
| **SDK control request `get_usage`** (`claude -p --input-format stream-json`) | The schema: "Requests the structured /usage data: session cost/usage totals plus claude.ai plan rate-limit utilization when available. Experimental — the response shape may change." Its `skip_behaviors` flag: "For callers that need only the plan rate limits, such as a usage meter." Answer: `subscription_type`, `rate_limits_available`, `rate_limits` (`five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet`, `model_scoped[]`, `extra_usage`, each window `{utilization, resets_at}`). Probe: answered in 0.3–0.7 s without `initialize`, no turn (`total_cost_usd` 0), with user hooks off under `--setting-sources project`. With an API key: `rate_limits_available:false`, `subscription_type:null`. Unknown subtype: `control_response` `subtype:"error"`, `error_code:"unsupported_request"`. | **Chosen.** Claude Code reads its own sign-in and endpoint; the request is meant for a usage meter. |
| `rate_limit_event` in our own runs' stream-json | `status`, `resetsAt`, `rateLimitType`, `utilization` for the window that changed; the per-window block is marked `@internal`. Emitted "when rate limit info changes", and only while Watchtower runs Claude. | Not used for the gauge (agent decision A2). Routing keeps using it as today. |
| Statusline JSON (`rate_limits.five_hour/seven_day.used_percentage`) | Five-hour and weekly only, pushed to a `statusLine` command while an interactive session draws its status line. | Rejected: we would have to replace the owner's `statusLine` setting in Claude Code's settings, and it has no scoped weeks. |
| `/usage`, `/status` text; `get_status` request | Rendered text; `get_status` is `@internal`. | Rejected: no stable shape. |
| OpenTelemetry export | Counters such as `claude_code.token.usage`, `claude_code.cost.usage`; no plan-window metric in 2.1.326. | Rejected: no plan utilization. |
| Keep the token read | Works today. | Forbidden by the terms; ask #1415. |

## 1. The reader: `internal/claude/usage.go`

`claude.ReadUsage(ctx, bin, env) (UsageSnapshot, error)`, mirroring `codex.ReadUsage`:

- **Process.** `bin` is `claude.FindBinary(cfg.ClaudePath)`, re-read from the config at every poll (like Codex). argv, exactly: `-p --input-format stream-json --output-format stream-json --verbose --setting-sources project --strict-mcp-config --no-session-persistence`. Working directory: `os.TempDir()` (neutral, as Codex). Environment: the inherited environment with `PATH=claude.RichPATH()`, the same as Watchtower's own Claude children, so the gauge describes the account Watchtower's AI calls use. Its own process group.
- **Why these flags.** `--setting-sources project` in a neutral folder keeps the owner's user hooks and plugins out (the probe saw a user `SessionStart` hook fire without it). `--strict-mcp-config` starts no MCP server. `--no-session-persistence` writes no transcript, so Watchtower's agent analytics and Claude Code's own `/usage` behaviour scan never see these reads. `--bare` is not usable: it never reads OAuth.
- **Conversation.** One stdin line: `{"type":"control_request","request_id":"wt-usage","request":{"subtype":"get_usage","skip_behaviors":true}}`. No user message is ever written, so no model turn can start. Stdout is read line by line (1 MiB per line, 4 MiB total) until a `control_response` whose `request_id` is `wt-usage`; every other line (hook or system events) is skipped. Then stdin is closed and the child gets 5 s to exit.
- **Budget and reaping.** 20 s from start to answer (the probe answers in under 1 s; the cap covers a slow CLI start). On success, failure, timeout and cancellation the whole process group is killed and waited for. Stderr is drained into a bounded buffer that is never stored, logged or returned.
- **Result.** `UsageSnapshot{Plan string, Windows []UsageWindow, Breakdown []BreakdownRow}`; `UsageWindow{Key, Label, Group string; Percent float64; ResetsAt *time.Time}`. Raw output never leaves the function; errors are `*UsageError{Code}` with a fixed code.

| Child behaviour | Code | Stored state |
|---|---|---|
| `bin` not found | `cli_missing` | `unavailable` |
| `control_response` error with `error_code:"unsupported_request"` or text starting "Unsupported control request subtype", or the CLI rejects the flags (exits before answering with no `control_response`, exit code ≠ 0 and stdout empty) | `unsupported_cli` | `unavailable` |
| `rate_limits_available:false` and the child's environment has a nonempty `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX` or `CLAUDE_CODE_USE_FOUNDRY` | `unsupported_auth` | `unavailable` |
| `rate_limits_available:false` otherwise (signed out, missing scope, an `apiKeyHelper` in settings) | `no_credentials` | `unavailable` |
| `rate_limits_available:true`, `rate_limits:null` (Claude Code could not read its endpoint) | `network` | `error`, last numbers kept |
| Any other `control_response` error, or exit after starting with output | `network` | `error`, last numbers kept |
| Malformed JSON in the answer, no usable window | `parse` | `error`, last numbers kept |
| 20 s budget spent | `timeout` | `error`, last numbers kept |
| Caller cancelled | `cancelled` | nothing written |

**API key in the environment (A5).** The child inherits the same environment as Watchtower's own Claude children, so when an API key or a cloud-provider switch is set there, Watchtower's AI calls bill that key and plan limits really do not apply to them. The reader does **not** strip these variables: a gauge that showed the subscription while Watchtower's calls bill an API key would be wrong, and changing which account Watchtower's AI calls use is out of scope. Instead the reader checks only whether those variable *names* are present and nonempty in the child environment it built (`os.LookupEnv`-style over the env slice; the value is never copied, stored, logged or compared) and reports the distinct `unsupported_auth` state: "Claude Code is using an API key here, so plan limits don't apply." An `apiKeyHelper` configured in Claude Code's settings is not detected (reading Claude Code's settings is out of bounds) and shows the sign-in state.

## 2. Mapping to limits

Only the schema-described fields are read. Keys and labels stay the ones stored today, so history, forecasts, notification keys (PLANUSAGE-03) and Home's `session` / `weekly_all` continue across the upgrade:

| `rate_limits` field | Key | Label | Group |
|---|---|---|---|
| `five_hour` | `session` | 5-hour | session |
| `seven_day` | `weekly_all` | Weekly | weekly |
| `model_scoped[]` (`display_name`) | `weekly_scoped:<slug(display_name)>` | Weekly · <display_name> | weekly |
| `seven_day_opus` / `seven_day_sonnet`, only when `model_scoped` is absent | `weekly_scoped:opus` / `weekly_scoped:sonnet` | Weekly · Opus / Sonnet | weekly |

A window that is `null`, or has a `null` `utilization`, is absent (not 0 %). `utilization` is clamped to 0–100; `resets_at` (ISO 8601) is parsed as today's `parseReset`; a `null` reset means the window has not started. `subscription_type` becomes the stored `plan` on every answer, so a signed-out or API-key answer (`null`) clears the plan label rather than keeping the old one. `seven_day_breakdown` (the surface rows) is not in the schema; it is read only when present, with the shape today's parser accepts, and the "Claude usage by surface" block hides when it is absent (A4). `seven_day_oauth_apps`, `extra_usage` and the other buckets are ignored, as today. `Severity` stays empty (nothing displays it).

The parser lives next to today's `parse` in `internal/planusage/parse.go` (`parseClaudeUsage(snapshot) (Usage, error)`); `rawResponse`'s `limits[]` path is deleted with the HTTP client.

## 3. The poller

`planusage.Poller` becomes `{Store, Read func(context.Context) (claude.UsageSnapshot, error), Now, Logger}` — `Creds`, `Client`, `CredentialLoader`, `Fetcher`, `Credentials`, `CredentialSource`, `ErrNoCredentials`, `HTTPError`, `Client`, `NewClient`, `usageURL`, `redact` and `decodeCredentials` are deleted. `PollOnce` keeps its shape: read the previous status, call `Read`, on success store samples then status with the projection and plot (unchanged `storeUsage`), on failure store the state from §1's table.

- `cli_missing`, `unsupported_cli`, `no_credentials`, `unsupported_auth`: no backoff (next poll in 5 min), failure count reset, as Codex does today.
- **Log noise.** These four codes are *quiet steady states*: `Provider.Run` logs one of them only when the provider's code changes (from success, from another code, or between two quiet codes), not on every 5-minute poll; it remembers the last logged code per provider and forgets it on a success. `network`, `parse`, `timeout`, `storage` and every other code keep today's log line on every failed poll; `busy` and `feature_disabled` stay unlogged. The rule lives in `Provider.Run`, so Codex gets the same quieting. Test: `TestProviderRun_QuietStatesLogOncePerChange` (a scripted poll sequence `cli_missing ×3 → no_credentials ×2 → ok → no_credentials → network ×2` gives exactly the lines `cli_missing`, `no_credentials`, `no_credentials`, `network`, `network`; the scheduler's `After` is faked, no wall-clock wait).
- `network`, `parse`, `timeout`: backoff 5 → 10 → 20 → 30 min, last good numbers kept, `last_error` holds the fixed code text only.
- The `Provider.Poll` wrapper in `cmd/plan_usage_daemon.go` loses its `stale/token_expired` → `no_credentials` special case; `ErrorCode` gains `*claude.UsageError` and loses `ErrNoCredentials` / `HTTPError`.
- Nothing new writes `stale` or `token_expired`. Readers keep accepting them (old rows, a downgrade): `safeStoredReason` still maps `token_expired` / `http_401` to `no_credentials`, and the Desktop still words them.

## 4. Freshness

- **Cadence unchanged:** first read 10 s after the daemon starts, then every 5 min, backoff on transient failures, manual Refresh as today. The read makes no model call, so `CostNone` and the feature's description stay true.
- **Idle:** the reader does not depend on Watchtower or the owner running Claude. Usage from other devices and claude.ai changes the numbers too, so polling continues while idle (A1).
- **Daemon not running:** as today; after 15 min the Desktop shows the card stale and hides the forecast.
- **A cached answer:** Claude Code may answer from its own cache when its endpoint call fails (the schema says `model_scoped` is absent "from cached data"). The answer carries no age, so `fetched_at` is Watchtower's read time. Accepted; the next successful read corrects it.

## 5. What is removed

- Files: `internal/planusage/credentials.go`, `internal/planusage/client.go` and their tests (`credentials_test.go`, `TestClient_Fetch`, the token cases of `poller_test.go`); test fixtures `usage_full.json`, `usage_idle.json`, `usage_legacy.json`, `usage_surface.json` are replaced by `get_usage` answers (synthetic values).
- `knownNonLLMExec`: `planusage.DefaultCredentialSource` out; `claude.usageProcess` in, reason "claude -p get_usage control request: Claude Code's own usage read, no turn, no model call".
- Docs: the "Sources and identity" paragraph of `docs/features/claude-plan-limits.md`, its README summary line, the guide's **Sign-in expired** bullets (`docs/guide/features/plans.md`, `docs/guide/troubleshooting/plan-limits-or-high-cost.md`).

## 6. The guard: nothing reads Claude credentials

New PLANUSAGE-01 guards (§13):

1. `internal/planusage/nocredentials_test.go::TestPlanUsage01_NoClaudeCredentialReader` — a source scan over every non-test `.go` file of the module and every `.swift` file under `WatchtowerDesktop/Sources`, `WatchtowerKit/Sources` and `WatchtowerMobile/Sources`. It fails on any of: `Claude Code-credentials`, `claudeAiOauth`, `.credentials.json`, `api/oauth/usage`, `oauth-2025-04-20`, `find-generic-password`. The scan proves it can see a hit: it runs over a synthetic file containing each marker first. Test files and `testdata` are out of scope (fixtures may name the markers to test the scan).
2. `internal/claude/usage_test.go::TestPlanUsage01_ReaderArgvAndHome` — a fake `claude` script (in `t.TempDir()`, process group reaped in `t.Cleanup`) records its argv, working directory and stdin, then answers. The test asserts argv equals §1's list exactly, stdin holds the one `get_usage` request and no user message, and the reader started nothing else (the only process is `bin`). `HOME` points at an empty temp folder containing decoy `.claude/.credentials.json`; the test asserts its access time and bytes are unchanged.

New PLANUSAGE-02 guard: `internal/planusage/poller_test.go::TestPlanUsage02_ChildOutputNeverPersisted` — the fake CLI writes a secret-shaped marker to stderr, to an unknown answer field and to a malformed line; after success, `parse` failure and `network` failure, neither the status row (all columns), the samples, the logger output nor the returned error contains it.

## 7. Desktop

- `PlansPresentation.errorText(code, provider:)` words the codes per provider (strings in `PlanUsageProvider.subscription`, the `SubscriptionUsagePolicy` that already holds `signInApplication`, with `PlansPresentationTests` pinning every pair):

| Code | Claude (new) | Codex (unchanged) |
|---|---|---|
| `cli_missing` | Install Claude Code, then retry. | Install Codex, then retry. |
| `unsupported_cli` | Update Claude Code to read plan limits, then retry. | Update Codex to read subscription limits, then retry. |
| `no_credentials` (also `token_expired`, `http_401` from old rows) | Sign in to Claude Code with your Claude plan, then retry. | Open Codex and sign in, then retry. |
| `unsupported_auth` | Claude Code is using an API key here, so plan limits don't apply. | Sign in to Codex with a ChatGPT account, then retry. |
| `network`, `parse`, `timeout`, … | unchanged | unchanged |

- The same text reaches the card summary, the popup row and the empty state through the existing `PlansMenuPresentation` / `PlansPopupPresentation` paths; no view changes. Tones stay `PlanUsageTone` → `Tone` (`.warning` for a provider message), no new colour.
- The legacy `PlanUsagePresentation.banner` keeps its `stale` text for old rows; nothing new reaches it.
- The "Claude usage by surface" block keeps its existing rule (`PlansScreenPresentation.hasDetails`, the `details` view): shown when the stored `breakdown` has rows, hidden when it is empty. New tests pin both directions: `PlansScreenPresentationTests.testSurfaceBreakdownShowsWhenPresentAndHidesWhenAbsent` (Swift) and `TestParseClaudeUsage_BreakdownOptional` (Go: an answer with `seven_day_breakdown` stores the rows, one without stores `[]`).
- No new screen, control or setting.

## 8. Storage and migration

No migration. `plan_usage_status` and `plan_usage_samples` keep their columns and keys (§2). On upgrade the first read (10 s after the daemon starts) overwrites an old `stale/token_expired` or `unavailable/no_credentials` row. Samples continue on the same keys, so history and forecasts carry across. `plan` now comes from `subscription_type` (`pro`, `max`, `team`, `enterprise`), the same vocabulary as the credential record's `subscriptionType`. A downgrade reads the same shape (and the old build goes back to the token, which this change cannot prevent).

`watchtower usage plan --json` (legacy) keeps its shape; its `reason` can now be `cli_missing`, `unsupported_cli` or `timeout`, and no longer `token_expired` / `http_*`. `watchtower usage plans --json` already allows every code used here.

## 9. Claude ↔ Codex routing keeps working

Unchanged and untouched: routing reads no plan percentages (Context). This spec adds no coupling between the gauge and routing, and the reader's `get_usage` child is not a routed call (it is not a model call and records no `llm_calls` row).

## 10. Codex: the app-server read

Our use is read-only: `account/read` with `refreshToken:false`, then `account/rateLimits/read`; we never call `account/login`, never read `auth.json`, and the owner signs in with `codex login`. OpenAI's app-server page says "App-server authentication has never been permitted for commercial or hosted services" and recommends Sign in with ChatGPT; it does not say whether a read-only limits query counts as "app-server authentication". No change in this spec.

Follow-up (proposed target, A7): **Codex plan limits without app-server, if needed.** Trigger: OpenAI answers that read-only app-server use in a commercial app is not permitted, or before a paid Watchtower tier ships. The ready alternative is passive: Codex writes `token_count` events with `rate_limits` (`primary` / `secondary` `{used_percent, window_minutes, resets_at}`, `plan_type`, `limit_id`) into its session files under `~/.codex/sessions`; reading the newest one gives current numbers without starting app-server. Costs: numbers only refresh after a Codex run, and there is no account id, so history would run in today's "identity unknown" mode (current numbers only, no forecast). Meanwhile, the OpenAI question already drafted for the SIWC partner form asks exactly this.

## 11. Failure modes

| Failure | Behaviour | Test |
|---|---|---|
| `claude` not installed | `unavailable/cli_missing`, Install Claude Code message, retried every 5 min | `TestReadUsage_CLIMissing`, `TestPollOnce_CLIMissingIsUnavailable` |
| Older Claude Code without `get_usage` | `unavailable/unsupported_cli`, Update message | `TestReadUsage_UnsupportedRequest` (fake answers `error_code:"unsupported_request"`), `TestReadUsage_FlagsRejected` (fake exits 1 at once) |
| Signed out | `unavailable/no_credentials`, Sign in message; numbers hidden by the existing state gate | `TestReadUsage_RateLimitsUnavailable` |
| API key or cloud provider set in the environment | `unavailable/unsupported_auth`, "using an API key" message; the variable's value never read into storage, logs or errors | `TestReadUsage_APIKeyEnvIsUnsupportedAuth` (fake CLI answers `available:false`; env has the name with a marker value; the marker appears nowhere in the result, status row or log) |
| Quiet steady states repeat every 5 min | logged once per change | `TestProviderRun_QuietStatesLogOncePerChange` |
| Surface rows absent from the answer | block hidden; present → shown | `TestParseClaudeUsage_BreakdownOptional`, `testSurfaceBreakdownShowsWhenPresentAndHidesWhenAbsent` |
| Claude Code cannot reach its endpoint | `error/network`, backoff, last numbers kept, forecast hidden by the 15 min gate | `TestReadUsage_RateLimitsNull`, `TestPollOnce_BackoffKeepsLastNumbers` (ported) |
| Shape changed (the request is experimental) | `error/parse`, last numbers kept; absent windows are absent, never 0 % | `TestParseClaudeUsage_Malformed`, `TestParseClaudeUsage_NullWindowIsAbsent` |
| CLI hangs / never answers | 20 s budget, `error/timeout`, group killed and reaped | `TestReadUsage_TimeoutReapsGroup` (synctest/fake clock, no wall-clock wait) |
| Child prints hook/system lines first | skipped until the matching `control_response` | `TestReadUsage_SkipsOtherLines` |
| Huge or endless output | line/total caps, `error/parse`, group killed | `TestReadUsage_OutputCapped` |
| Cancelled (feature off, quit) | nothing written, failure count unchanged | `TestPollOnce_CancelledWritesNothing` (ported) |
| `model_scoped` absent (cached answer) | scoped rows missing that cycle; no stale scoped row invented | `TestParseClaudeUsage_ModelScopedAbsent` |
| Keys survive the upgrade | `session`, `weekly_all`, `weekly_scoped:<slug>` match the old parser's keys | `TestParseClaudeUsage_KeysMatchLegacy` (old fixture vs new answer of the same numbers) |
| Old `stale/token_expired` row after upgrade | Desktop words it as Sign in; first poll overwrites | `PlansPresentationTests.testLegacyTokenReasonsReadAsSignIn` |

## 12. Writers

| Data | Writers | Who wins |
|---|---|---|
| `plan_usage_status`, `plan_usage_samples` | The Claude `planusage.Provider`: daemon poll, `usage plans --now` / `usage plan --now` refresh, disabled-state publication — all under `.plan-usage-claude.lock` | Unchanged: one writer at a time under the lock; manual refresh waits ≤ 20 s |
| Claude Code's own state (`~/.claude.json` counters, its usage cache) | Claude Code itself, as on any `claude -p` start | Claude Code; Watchtower writes none of it |
| Claude credentials | Claude Code only | Watchtower never reads, refreshes or writes them |

## 13. Inventory contracts touched (owner approval needed)

`docs/inventory/plan-usage.md`:

- **PLANUSAGE-01 — rewritten.** Today: "The token is never refreshed or written; an expired token sends no request", guard `TestPlanUsage01_ExpiredTokenMakesNoRequest`. Proposed: "**Watchtower never reads, refreshes or writes Claude credentials.** Plan limits come only from the installed `claude` command's `get_usage` answer; no source reads the Claude Code Keychain item or credentials file, and no Watchtower code calls Anthropic's usage endpoint." Guards: `TestPlanUsage01_NoClaudeCredentialReader`, `TestPlanUsage01_ReaderArgvAndHome`. The old guard is deleted with the code it tested (its subject, the token, no longer exists); the new contract is strictly stronger.
- **PLANUSAGE-02 — rewritten.** Today: "The token never reaches the DB, logs or errors", guard `TestPlanUsage02_TokenNeverPersisted`. Proposed: "**The usage child's output never reaches the DB, logs or errors**: only parsed numbers, the plan name and a fixed reason code are stored." Guard: `TestPlanUsage02_ChildOutputNeverPersisted`.
- **PLANUSAGE-03** — unchanged (same keys and reset times).
- **LLMUSAGE-01** — contract unchanged; the `knownNonLLMExec` entry `planusage.DefaultCredentialSource` is replaced by `claude.usageProcess` (§5). No guard relaxed.

The Changelog gets one entry naming the approving ask.

## 14. Mockups

Design-only scenes in `DesignShotCatalog` (`PlanLimitsNoTokenShotFixtures`, `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+PlanLimitsNoToken.swift`), built from the production `PlansProviderCard`, `PlansChartCard`, `PlansScreenPresentation` and `PlansPopupPresentation` on `PlansShotFixtures` snapshots. Only the Claude message comes from `PlanLimitsNoTokenMockCopy` (pinned by `PlanLimitsNoTokenMockCopyTests`, which also checks Codex's wording stays production's and that every frame has both shots). Rendered by `DesignShotsTests.testPlanLimitsNoTokenShotsRender`, light and dark, under `docs/design/mockups/plan-limits-no-token/`. The PNGs live on branch `feature/1885-plan-limits-no-token` next to this spec; a checkout of another branch does not have the folder. The ok state is unchanged: see the production catalog `docs/design/shots/plans/`. In the four `unavailable` frames the Claude card and its chart card both carry the message (production behaviour for a provider without visible numbers); Codex is the production filled snapshot.

| Screen shot | Menu shot | State |
|---|---|---|
| [`plan-limits-nt-cliMissing`](../../design/mockups/plan-limits-no-token/plan-limits-nt-cliMissing-light.png) | [`plan-limits-nt-menu-cliMissing`](../../design/mockups/plan-limits-no-token/plan-limits-nt-menu-cliMissing-light.png) | `claude` not installed |
| [`plan-limits-nt-cliOutdated`](../../design/mockups/plan-limits-no-token/plan-limits-nt-cliOutdated-light.png) | [`plan-limits-nt-menu-cliOutdated`](../../design/mockups/plan-limits-no-token/plan-limits-nt-menu-cliOutdated-light.png) | Claude Code too old for `get_usage` |
| [`plan-limits-nt-notSignedIn`](../../design/mockups/plan-limits-no-token/plan-limits-nt-notSignedIn-light.png) | [`plan-limits-nt-menu-notSignedIn`](../../design/mockups/plan-limits-no-token/plan-limits-nt-menu-notSignedIn-light.png) | signed out: no plan limits |
| [`plan-limits-nt-apiKey`](../../design/mockups/plan-limits-no-token/plan-limits-nt-apiKey-light.png) | [`plan-limits-nt-menu-apiKey`](../../design/mockups/plan-limits-no-token/plan-limits-nt-menu-apiKey-light.png) | API key in the environment: plan limits don't apply |
| [`plan-limits-nt-readFailed`](../../design/mockups/plan-limits-no-token/plan-limits-nt-readFailed-light.png) | [`plan-limits-nt-menu-readFailed`](../../design/mockups/plan-limits-no-token/plan-limits-nt-menu-readFailed-light.png) | the read failed: last numbers kept, production wording |

## 15. Docs updated with the implementation

- `docs/features/claude-plan-limits.md` "Sources and identity" (Claude reads through `claude -p` `get_usage`, flags, no credentials); its line in `docs/features/README.md`.
- `docs/inventory/plan-usage.md` (§13).
- `docs/guide/features/plans.md`: "How it works" says Watchtower asks your installed Claude Code for its plan usage (the numbers `/usage` shows) and never reads your Claude sign-in; the **Sign-in expired** bullet becomes **Claude Code not signed in with a plan** and a **Claude Code missing or too old** bullet is added. `docs/guide/troubleshooting/plan-limits-or-high-cost.md` step 6 likewise.

## 16. Promises → tasks → tests

| Promise | Task | Test |
|---|---|---|
| No Claude credential read anywhere | Delete credentials/client; add the scan | `TestPlanUsage01_NoClaudeCredentialReader` |
| The reader starts only `claude` with §1's argv, no turn | `internal/claude/usage.go` | `TestPlanUsage01_ReaderArgvAndHome`, `TestReadUsage_*` |
| Same keys, history continues | `parseClaudeUsage` | `TestParseClaudeUsage_KeysMatchLegacy` |
| States and backoff per §1/§3 | Poller rewrite | `TestPollOnce_*` (ported), `TestPollOnce_CLIMissingIsUnavailable` |
| Child output never stored | Poller + reader | `TestPlanUsage02_ChildOutputNeverPersisted` |
| Ledger stays complete | `knownNonLLMExec` entry | `TestLLMUSAGE01_LeavesRecord` |
| Per-provider wording | `PlansPresentation.errorText` | `PlansPresentationTests` (each code × provider) |
| API key in the environment is its own state | reader env check | `TestReadUsage_APIKeyEnvIsUnsupportedAuth` |
| Quiet states log once per change | `Provider.Run` | `TestProviderRun_QuietStatesLogOncePerChange` |
| Surface block shows/hides with its data | parser + presentation | `TestParseClaudeUsage_BreakdownOptional`, `testSurfaceBreakdownShowsWhenPresentAndHidesWhenAbsent` |
| Mockups match the spec | — | `PlanLimitsNoTokenMockCopyTests` |

## 17. Decisions

### Sourced

| # | Decision | Source |
|---|---|---|
| 1 | Remove the token read and the direct `/api/oauth/usage` call; keep the gauge | ask #1415 «Переделать без токена» |
| 2 | Watchtower never collects Claude credentials, including read-only | ask #1415; Claude Code legal page (quoted in Goal) |
| 3 | A spec with `## Decisions`, mockups for every changed state, strings in models with tests, colours via `Tone`, failure modes, writers, inventory contracts listed for approval | owner's target #1885 brief |

### Proposed by the agent (for one owner ask)

- **A1. The source is Claude Code's `get_usage` control request, polled every 5 min whether or not Claude is running.** Recommendation: accept — it is the only source with every window, it is meant for a usage meter, and idle polling still catches claude.ai and other-device use. — решил агент
- **A2. No second writer from `rate_limit_event`.** The gauge has one writer; passive events stay routing's evidence only. Recommendation: accept — simpler, and the event's per-window data is `@internal`. — решил агент
- **A3. The usage child runs with `--setting-sources project --strict-mcp-config --no-session-persistence` in a neutral folder**, so the owner's hooks, MCP servers and transcripts are untouched by a read every 5 minutes. Recommendation: accept. — решил агент
- **A4. Read only schema-described fields; the surface breakdown is shown only when the answer happens to carry it.** This is a possible visible loss (Goal): today the answer carries the rows, so nothing changes on the first day, but a Claude Code release may drop them and the "Claude usage by surface" block then disappears. Alternatives: accept the possible loss (recommended — no compliant source for the rows exists besides this pass-through), or drop the block now so it never vanishes unannounced. Recommendation: accept the possible loss. — решил агент, **owner decision**
- **A5. API key in the environment is its own state, not stripped.** When the child's environment carries `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` or a cloud-provider switch, the card says "Claude Code is using an API key here, so plan limits don't apply" (`unsupported_auth`) instead of "Sign in". Stripping was rejected: Watchtower's AI calls inherit the same environment and bill that key, so a gauge showing the subscription would misreport what those calls draw from, and changing their billing is out of scope. Only the variable names are checked. Recommendation: accept. — решил агент (review round 1, ask #1444)
- **A8. The usage read is exempt from the background-AI consent (#1886).** The consent spec (`2026-11-17-background-ai-consent-design.md`, owner ask #1415 «Да, один раз в онбординге») gates *model calls* the daemon starts on its own. `get_usage` starts no model turn, records no `llm_calls` row and is `CostNone`, so it keeps running while background AI is paused. For transparency, the consent spec's list of background `claude` launches names it ("plan-limit read, every 5 min, no model call"). Recommendation: accept, and add that line to the consent spec. — решил агент, **owner decision**
- **A6. PLANUSAGE-01/02 rewritten as in §13** (old guards deleted with their code, stronger new guards). Recommendation: approve — needed because the old contracts describe a token that no longer exists. — решил агент, **needs owner approval**
- **A7. Codex app-server read unchanged now; follow-up target "Codex plan limits without app-server" with the rollout-file alternative, triggered by OpenAI's answer or a paid tier.** Recommendation: accept and file the target. — решил агент

## 18. Out of scope

- Codex changes (§10 is a follow-up).
- New UI beyond the wording in §7; the iPhone (no plan slice).
- Reading `extra_usage`, `seven_day_oauth_apps` or other buckets.
- The MCP-server import from `~/.claude.json` (`internal/externalmcp`): it reads `mcpServers` only, no Claude credentials.

## 19. Open

- `get_usage` is marked Experimental. If a Claude Code release drops or reshapes it, the card shows **Update Claude Code** or a parse error and keeps the last numbers; the fix is a parser update. The minimum Claude Code version that answers it is not known; detection is by the `unsupported_request` answer, not a version number.
- Signed-out behaviour was not probed live (it would sign the owner out); the API-key probe showed `rate_limits_available:false`, and the schema says the same for a missing sign-in. The fake-CLI tests cover the mapping.
