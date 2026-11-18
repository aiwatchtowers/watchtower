# Claude Plan Limits Without the Token Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Claude half of Plans, the menu-bar counters, Home's plan numbers and Claude's limit notifications keep working while Watchtower never reads, refreshes or writes Claude credentials: the numbers come from the installed `claude` command's `get_usage` control request.

**Architecture:** A new reader `claude.ReadUsage` (`internal/claude/usage.go`) starts `claude -p … stream-json` in a neutral folder, writes one `get_usage` control request, reads the matching `control_response`, maps the schema fields to today's limit keys and returns a typed snapshot or a fixed-code `*claude.UsageError`. `planusage.Poller` calls it through a `Read` func instead of the Keychain loader + HTTP client, which are deleted together with PLANUSAGE-01/02's old guards; new guards scan the source for credential markers and pin the reader's argv. The Desktop words the new codes per provider from `SubscriptionUsagePolicy`; no view, schema or migration changes.

**Tech Stack:** Go 1.26 (`os/exec` with process groups, `testing/synctest`), Claude Code CLI stream-json control protocol, SwiftUI/WatchtowerCore presentation models (XCTest), DesignShots.

**Spec:** `docs/superpowers/specs/2026-11-17-plan-limits-without-token-design.md` (approved in ask #1450; decisions A1–A8 and the PLANUSAGE-01/02 rewrites approved in ask #1448 — every §17 decision is final).

## Global Constraints

- Reader argv, exactly and in this order: `-p --input-format stream-json --output-format stream-json --verbose --setting-sources project --strict-mcp-config --no-session-persistence`. No `--bare`.
- The one stdin line, exactly: `{"type":"control_request","request_id":"wt-usage","request":{"subtype":"get_usage","skip_behaviors":true}}` followed by `\n`. No user message is ever written.
- Working directory `os.TempDir()`; environment = the caller's `env` (production: `os.Environ()` + `PATH=claude.RichPATH()`); own process group (`Setpgid`); binary `claude.FindBinary(cfg.ClaudePath)` re-read from config at every poll.
- Limits: 1 MiB per stdout line, 4 MiB stdout total, 20 s from start to answer, 5 s for the child to exit after stdin is closed. On success, failure, timeout and cancellation the whole group is killed (`kill(-pgid, SIGKILL)`) and waited for.
- Stderr is drained into a bounded buffer that is never stored, logged or returned. Raw stdout never leaves `internal/claude`.
- Reason codes (closed set): `cli_missing`, `unsupported_cli`, `unsupported_auth`, `cloud_bedrock`, `cloud_vertex`, `cloud_foundry`, `no_credentials`, `network`, `parse`, `timeout`, `cancelled`. Stored state per spec §1 table.
- Environment check reads only variable **names** (nonempty value, last entry of a key wins); a value is never copied, stored, logged or compared. Precedence: `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` (→ `api_key`), `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX`, `CLAUDE_CODE_USE_FOUNDRY`.
- Keys/labels/groups unchanged: `session` "5-hour" session; `weekly_all` "Weekly" weekly; `weekly_scoped:<slug(display_name)>` "Weekly · <display_name>" weekly; `weekly_scoped:opus` / `weekly_scoped:sonnet` only when `model_scoped` is absent. `slug` = lower-case, trimmed, spaces → `-` (today's `planusage.slug`).
- A `null` window or `null` utilization is absent, never 0 %. `utilization` clamped 0–100. `subscription_type` (null → `""`) is the stored `plan` on every answer.
- Claude wording (exact): `cli_missing` "Install Claude Code, then retry." · `unsupported_cli` "Update Claude Code to read plan limits, then retry." · `no_credentials`/`token_expired`/`http_401` "Sign in to Claude Code with your Claude plan, then retry." · `unsupported_auth` "Claude Code is using an API key here, so plan limits don't apply." · `cloud_bedrock`/`cloud_vertex`/`cloud_foundry` "Claude Code is using Bedrock here, so plan limits don't apply." (Vertex, Foundry likewise). Codex wording unchanged.
- No migration, no schema change, no new screen, control, setting or colour; tones stay `PlanUsageTone` → `Tone`.
- Nothing new writes `stale` or `token_expired`; readers keep accepting them.
- LLMUSAGE-01 is never weakened: `knownNonLLMExec` swaps `planusage.DefaultCredentialSource` for `claude.usageProcess` and nothing else.
- Tests never wait on wall-clock: budgets are exercised under `testing/synctest` with an in-process fake child; tests that start a fake `claude` script record its PID and kill its process group in `t.Cleanup`.
- Per task only the inner loop (`go test ./internal/<pkg>`, named guard suites, `make test-swift FILTER=…`, `make lint-swift`, `make lint-diff`); the full gate (`make test`, `make test-swift`, `make lint-all`) runs once at the end by the controller.
- Public repo: synthetic values only in fixtures (plan `max`, display name `Fable`), no real ids, names or local absolute paths. English only.
- Every commit message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Decisions made by the plan (agent, review #1479)

| # | Decision | Why | Cost if wrong |
|---|---|---|---|
| P1 | `claude` exiting 0 without a `control_response` is `network` (transient, backoff) | the spec defines only exit ≠ 0 with empty stdout (`unsupported_cli`); a zero exit with no answer is most often a wrapper or version-manager stub hiccup, and backoff retries it without telling the owner to update a CLI that may be current | a permanently broken wrapper shows "Couldn't read" with backoff instead of "Update Claude Code"; one-line change in the reader's mapping |
| P2 | `cloud_bedrock`, `cloud_vertex`, `cloud_foundry` join the public codes of `usage plans --json` and Swift `PlansOperationError.codes` | the approved A5 (ask #1448) gives each cloud provider its own card text; the Swift decoder rejects unknown codes, so the states cannot reach the screen otherwise; the set only grows (additive), the old codes keep their meaning | an outside consumer of the JSON that switches over codes sees three new values and falls into its default branch |
| P3 | `planusage.Poller.Run` is deleted | dead code: only `Provider.Run` schedules polls (`internal/planusage/poller.go`), and it references the deleted `ErrNoCredentials` | none at run time; a caller added later would use `Provider.Run` |

## Review Focus

1. **The credential scan walks into nested checkouts.** Worktrees live under `.claude/worktrees/<name>/` inside the repo; a scan from the main checkout would find another branch's `credentials.go`. Expected: the scan skips every directory whose name starts with `.`, plus `testdata`, `node_modules`, `vendor`, `.build`; it still reports a hit in an ordinary package. Test: `TestPlanUsage01_NoClaudeCredentialReader` (Task 3) runs its walker over a synthetic tree first.
2. **The CLI prints other control traffic before answering** — a `control_response` with another `request_id`, or a `control_request` it sends us. Expected: skipped, never answered, the reader keeps waiting for `wt-usage` within the budget. Test: `TestReadUsage_SkipsOtherLines` (Task 2) includes both.
3. **Two scoped windows map to one key** (two `model_scoped` entries with the same display name, or an empty display name). Samples are `INSERT OR IGNORE`, but `limits_json` would carry duplicate ids into SwiftUI lists. Expected: the first window of a key wins, an empty slug is dropped. Test: `TestUsageFromSnapshot_DuplicateKeysFirstWins` (Task 3).
4. **A shim exits 0 with no output** (a broken wrapper, a version manager stub). The spec defines exit ≠ 0 + empty stdout as `unsupported_cli`. Expected: exit 0 without a `control_response` is `network` (transient, backoff), not a silent success. Test: `TestReadUsage_ExitWithoutAnswerIsNetwork` (Task 2). Agent decision P1 (below).
5. **A chatty stderr blocks the child.** If stderr is not drained, a CLI that warns a lot fills the pipe and never answers. Expected: stderr is read concurrently into a bounded buffer and the answer still arrives. Test: `TestReadUsage_LargeStderrDoesNotBlock` (Task 2, fake writes 2 MB to stderr before answering).

## File Structure

| File | Task | Responsibility |
|---|---|---|
| `internal/claude/authenv.go` (+ `_test.go`) | 1 | `LoginOverride`: which non-login auth the child env selects |
| `internal/chat/claudeai.go` | 1 | `ClaudeAIAvailability` uses `claude.LoginOverride`; `claudeAIOffMarkers` deleted |
| `internal/claude/usage.go` (+ `usage_test.go`) | 2 | process, conversation, budget, reaping, code classification |
| `internal/claude/usage_answer.go` (+ `usage_answer_test.go`, `testdata/get_usage_*.json`) | 2 | decode the `get_usage` payload and map windows to keys (§2) |
| `internal/llmusage/leaves_test.go` | 2, 3 | `claude.usageProcess` in (2), `planusage.DefaultCredentialSource` out (3) |
| `internal/planusage/parse.go` | 3 | `usageFromSnapshot`; old `parse`/`rawResponse`/`rawLimit` deleted |
| `internal/planusage/poller.go`, `provider.go`, `aggregate.go` | 3 | `Poller.Read`, account-level clearing, codes, `ErrorCode`, `cloud_*` in the public sets |
| `internal/planusage/credentials.go`, `client.go`, `credentials_test.go`, `testdata/usage_{full,idle,legacy,surface}.json` | 3 | deleted |
| `internal/planusage/nocredentials_test.go` | 3 | PLANUSAGE-01 source scan |
| `cmd/plan_usage_daemon.go` (+ `_test.go`) | 3 | wire `claude.ReadUsage`, drop the `stale/token_expired` special case |
| `docs/inventory/plan-usage.md` | 3 | PLANUSAGE-01/02 rewritten, Changelog (ask #1448) |
| `internal/planusage/provider.go` `Run` (+ `provider_test.go`) | 4 | quiet steady states logged once per change |
| `WatchtowerDesktop/Sources/WatchtowerCore/Models/SubscriptionUsagePolicy.swift`, `SessionAgent/{Claude,Codex}SessionAgent.swift`, `Services/PlansPresentation.swift`, `Models/PlansUsage.swift` | 5 | per-provider messages, `cloud_*` codes |
| `WatchtowerDesktop/Tests/Core/PlansPresentationTests.swift` (new), `PlansScreenPresentationTests.swift`, `PlansUsageTests.swift`, `Tests/DesignShots/PlanLimitsNoToken*` | 5 | wording, surface block, mockup cross-check |
| `docs/features/claude-plan-limits.md`, `docs/features/README.md`, `docs/guide/features/plans.md`, `docs/guide/troubleshooting/plan-limits-or-high-cost.md` | 6 | docs |
| consent spec on branch `feature/1886-background-ai-consent`; board | 7 | coordination |

## Lanes

- **Lane Go-reader:** Task 1 → Task 2 → Task 3 (sequential; 3 consumes 2's types, 2 consumes 1's `LoginOverride`).
- **Lane Go-provider:** Task 4 (independent; touches only `Provider.Run` and its test — merge note: Task 3 edits `ErrorCode` in the same file, different function).
- **Lane Swift:** Task 5 (independent of every Go task: it words codes, it does not read the reader).
- **Docs:** Task 6 after Tasks 3 and 5 merge.
- **Controller:** Task 7 any time (no code).

---

### Task 1: `claude.LoginOverride` — one env list shared with the chat

**Depends on:** none

**Files:**
- Create: `internal/claude/authenv.go`, `internal/claude/authenv_test.go`
- Modify: `internal/chat/claudeai.go` (delete `claudeAIOffMarkers`; keep `envValue`, its tests use it)

**Interfaces:**
- Produces: `func LoginOverride(env []string) (kind string, ok bool)` — `kind` ∈ `"api_key"`, `"bedrock"`, `"vertex"`, `"foundry"`; checks names in the Global Constraints precedence order, the last `KEY=` entry of a key wins, a key whose last value is empty does not count.

- [ ] **Step 1: Write the failing test** `TestLoginOverride_OrderAndLastWins` (table): `nil` → `("", false)`; `["ANTHROPIC_API_KEY=k"]` → `api_key`; `["ANTHROPIC_AUTH_TOKEN=t"]` → `api_key`; `["CLAUDE_CODE_USE_BEDROCK=1","ANTHROPIC_API_KEY=k"]` → `api_key` (key beats cloud); `["CLAUDE_CODE_USE_VERTEX=1","CLAUDE_CODE_USE_FOUNDRY=1"]` → `vertex`; `["CLAUDE_CODE_USE_FOUNDRY=1"]` → `foundry`; `["ANTHROPIC_API_KEY=k","ANTHROPIC_API_KEY="]` → `("", false)` (last wins); `["ANTHROPIC_API_KEY_X=k"]` → `("", false)` (exact name).
- [ ] **Step 2: Run** `go test ./internal/claude -run TestLoginOverride` — Expected: FAIL (undefined `LoginOverride`).
- [ ] **Step 3: Implement** `LoginOverride` in `authenv.go` (the marker table moves here as `[]struct{name, kind string}`).
- [ ] **Step 4: Switch the chat.** `ClaudeAIAvailability` calls `claude.LoginOverride(env)` and maps `api_key`→"an API key", `bedrock`→"Bedrock", `vertex`→"Vertex", `foundry`→"Foundry" into the unchanged sentence `"claude.ai tools need a claude.ai login; this chat uses " + uses + "."`. `internal/chat/claudeai_test.go` is not edited.
- [ ] **Step 5: Run** `go test ./internal/claude ./internal/chat -run 'TestLoginOverride|TestClaudeAIAvailability|TestClaudeEnv|TestClaudeArgs'` and `make lint-diff` — Expected: PASS, no new issues.
- [ ] **Step 6: Commit** `refactor(claude): LoginOverride shared by the chat and the usage reader (#1885)` (+ trailer).

---

### Task 2: The Claude usage reader

**Depends on:** Task 1

**Files:**
- Create: `internal/claude/usage.go`, `internal/claude/usage_answer.go`, `internal/claude/usage_test.go`, `internal/claude/usage_answer_test.go`, `internal/claude/testdata/get_usage_full.json`, `get_usage_legacy_windows.json`, `get_usage_idle.json`, `get_usage_no_breakdown.json`
- Modify: `internal/llmusage/leaves_test.go` (add `"claude.usageProcess": "claude -p get_usage control request: Claude Code's own usage read, no turn, no model call"`)

**Interfaces:**
- Consumes: `claude.LoginOverride` (Task 1).
- Produces:
  - `type UsageError struct{ Code string }`; `Error() string` = `"claude usage: " + Code`.
  - `type UsageWindow struct{ Key, Label, Group string; Percent float64; ResetsAt *time.Time }`
  - `type BreakdownRow struct{ Key, Label string; Percent float64 }`
  - `type UsageSnapshot struct{ Plan string; Windows []UsageWindow; Breakdown []BreakdownRow }` — `Windows` already carry the §2 keys/labels/groups; `Breakdown` is nil when the answer has no `seven_day_breakdown`.
  - `func ReadUsage(ctx context.Context, bin string, env []string) (UsageSnapshot, error)` — error is always `*UsageError`.
  - Unexported seam (same package tests only): `type usageChild struct{ stdin io.WriteCloser; stdout io.Reader; wait func() (exitCode int, err error); kill func() }`, `type usageLauncher func() (*usageChild, error)`, `func usageProcess(bin string, env []string) usageLauncher` (the **only** function with `exec.Command`; `LookPath` failure → `errCLIMissing`), `func readUsage(ctx context.Context, launch usageLauncher, env []string) (UsageSnapshot, error)`, constants `usageBudget = 20*time.Second`, `usageExitGrace = 5*time.Second`, `usageLineCap = 1<<20`, `usageTotalCap = 4<<20`, `usageRequestID = "wt-usage"`.
  - `func parseClaudeUsage(payload []byte) (snap UsageSnapshot, available bool, limitsNull bool, err error)` in `usage_answer.go` — decodes the success `response` object of the `control_response`.

The answer envelope is `{"type":"control_response","response":{"subtype":"success"|"error","request_id":"wt-usage","response":{…get_usage payload…},"error":"…","error_code":"…"}}` (the shape `internal/chat/controlproto.go` already reads). Before writing the fixtures, confirm the `model_scoped[]` entry shape (`display_name` beside `utilization`/`resets_at`) and `seven_day_breakdown` (`{"rows":[{"key","display_name","percent"}]}`) against the installed CLI's bundled SDK schema; if the nesting differs, adapt the decode structs, not the test assertions. Fixture values are synthetic.

Classification inside `readUsage` (spec §1 table; first match wins): launcher `errCLIMissing` → `cli_missing`; ctx cancelled → `cancelled`; budget spent → `timeout`; error answer with `error_code:"unsupported_request"` or `error` text starting `Unsupported control request subtype` → `unsupported_cli`; other error answer → `network`; child exited with no `control_response`: exit ≠ 0 and no stdout bytes → `unsupported_cli`, otherwise → `network`; line or total cap hit, or an undecodable `wt-usage` answer → `parse`; `available == false` → `LoginOverride(env)`: `api_key`→`unsupported_auth`, `bedrock|vertex|foundry`→`cloud_<kind>`, none → `no_credentials`; `available && limitsNull` → `network`; decoded but zero windows → `parse`. Lines that are not JSON, not `control_response`, or carry another `request_id` are skipped.

- [ ] **Step 1: Write the failing answer-parser tests** in `usage_answer_test.go`:
  - `TestParseClaudeUsage_KeysMatchLegacy` — `get_usage_full.json` (five_hour 12.5, seven_day 40, `model_scoped:[{display_name:"Fable", utilization:130}]`) gives keys/labels/groups exactly `[{session,"5-hour",session},{weekly_all,"Weekly",weekly},{weekly_scoped:fable,"Weekly · Fable",weekly}]` (the strings the deleted `TestParse_LimitsArray` pinned), Fable clamped to 100, a fractional-second `resets_at` keeps its nanoseconds; `get_usage_legacy_windows.json` (no `model_scoped`, `seven_day_opus` set, `seven_day_sonnet` null) gives `[session, weekly_all, weekly_scoped:opus]` with label "Weekly · Opus".
  - `TestParseClaudeUsage_NullWindowIsAbsent` — `get_usage_idle.json`: `seven_day: null` and a `five_hour` with `utilization: null` are absent (not 0 %); a window with `resets_at: null` has `ResetsAt == nil`.
  - `TestParseClaudeUsage_ModelScopedAbsent` — `model_scoped` absent and `seven_day_opus` absent → no scoped window at all.
  - `TestParseClaudeUsage_ModelScopedWinsOverOpus` — both present → only `model_scoped` rows.
  - `TestParseClaudeUsage_BreakdownOptional` — full fixture: `Breakdown == [{claude_code,"Claude Code",80}, …]`; `get_usage_no_breakdown.json`: `Breakdown == nil`.
  - `TestParseClaudeUsage_Malformed` — `not json`, `{"rate_limits":"x"}`, a utilization string → error; `subscription_type: null` → `Plan == ""`; `rate_limits_available:false` → `available == false`; `rate_limits_available:true, rate_limits:null` → `limitsNull == true`.
- [ ] **Step 2: Run** `go test ./internal/claude -run TestParseClaudeUsage` — Expected: FAIL (undefined).
- [ ] **Step 3: Implement** `parseClaudeUsage` in `usage_answer.go` (own `slug`, `clamp`, RFC3339Nano reset parse; same semantics as `planusage`'s).
- [ ] **Step 4: Run** the same command — Expected: PASS.
- [ ] **Step 5: Write the failing conversation tests** in `usage_test.go`. In-process tests run inside `synctest.Test` with a fake `usageChild` over `io.Pipe` that records `killed`; script tests write a `/bin/sh` script into `t.TempDir()` that first writes `$$` to a pid file (cleanup: `syscall.Kill(-pid, SIGKILL)`, ignore `ESRCH`).
  - `TestReadUsage_CLIMissing` — `ReadUsage(ctx, "<tempdir>/nope", env)` → code `cli_missing`, nothing started.
  - `TestReadUsage_UnsupportedRequest` — fake answers `subtype:"error", error_code:"unsupported_request"` → `unsupported_cli`; a second case answers only `error:"Unsupported control request subtype: get_usage"` → `unsupported_cli`.
  - `TestReadUsage_FlagsRejected` (script) — exits 1 at once without reading stdin, empty stdout → `unsupported_cli`; the stdin write's `EPIPE` is not a different code.
  - `TestReadUsage_ExitWithoutAnswerIsNetwork` — exit 0 with empty stdout → `network`; exit 1 after printing a hook line → `network`.
  - `TestReadUsage_RateLimitsUnavailable` — `available:false`, env without markers → `no_credentials`.
  - `TestReadUsage_APIKeyEnvIsUnsupportedAuth` — env `ANTHROPIC_API_KEY=SECRET-MARKER-7`, answer `available:false` → `unsupported_auth`; `err.Error()` and the snapshot (`fmt.Sprintf("%+v")`) do not contain `SECRET-MARKER-7`.
  - `TestReadUsage_APIKeyEnvWithLimitsAvailableReadsNumbers` — same env, `available:true` with windows → success (the env check applies only to `available:false`).
  - `TestReadUsage_CloudEnvIsCloudReason` — each of `CLAUDE_CODE_USE_BEDROCK|VERTEX|FOUNDRY=1` → `cloud_bedrock|cloud_vertex|cloud_foundry`.
  - `TestReadUsage_RateLimitsNull` — `available:true, rate_limits:null` → `network`; other error answer (`subtype:"error"`, no code) → `network`.
  - `TestReadUsage_SkipsOtherLines` — before the answer the fake prints a non-JSON line, a `system` hook event, a `control_request` from the CLI, and a `control_response` with `request_id:"other"`; result is the `wt-usage` answer's snapshot and the fake's stdin holds exactly one line.
  - `TestReadUsage_OutputCapped` — one 1 MiB+1 line → `parse`, `killed`; many short non-answer lines totalling > 4 MiB → `parse`, `killed`.
  - `TestReadUsage_TimeoutReapsGroup` — fake never answers: result `timeout` exactly `usageBudget` after start (`time.Since` inside the bubble), `killed`.
  - `TestReadUsage_CancelReaps` — cancel after `synctest.Wait()` → `cancelled`, `killed`.
  - `TestReadUsage_ExitGraceThenKill` — fake answers but never exits after stdin closes: success returned, `killed` after exactly `usageExitGrace`.
  - `TestReadUsage_LargeStderrDoesNotBlock` (script) — `head -c 2000000 /dev/zero >&2` before answering → success.
  - `TestPlanUsage01_ReaderArgvAndHome` (script; the PLANUSAGE-01 guard) — the script writes `"$@"` (one per line), `pwd` and the first stdin line to files, then answers. `env` = `HOME=<tmp home>`, `PATH=<tmp bin>` where `<tmp bin>` holds decoy `security` and `curl` scripts that touch a marker file; `<tmp home>/.claude/.credentials.json` holds decoy bytes. Assert: argv equals the Global Constraints list; cwd is `os.TempDir()` (compare `filepath.EvalSymlinks`); the stdin line equals the request byte for byte and nothing else was written; no decoy marker file exists; the decoy credentials file's bytes are unchanged. No access-time check: `Stat_t.Atimespec` exists only on darwin (Go CI runs on ubuntu, where the field is `Atim`) and Linux `relatime` makes atime unreliable, so the guard stays portable; the static scan `TestPlanUsage01_NoClaudeCredentialReader` is what proves no source reads the credentials (review #1479).
- [ ] **Step 6: Run** `go test ./internal/claude -run 'TestReadUsage|TestPlanUsage01'` — Expected: FAIL (undefined).
- [ ] **Step 7: Implement** `usage.go`: `usageProcess` (`exec.Command` — no `CommandContext`, the reader owns killing — `Dir=os.TempDir()`, `Env=env`, `SysProcAttr{Setpgid:true}`, stderr into a capped buffer as in `internal/slacklive/child.go`'s `capBuf`, `kill` = `syscall.Kill(-pid, SIGKILL)`), and `readUsage` (one goroutine reads lines with `bufio.Reader` under the caps and sends the matched answer or EOF+exit on a channel; the caller selects on it, `ctx.Done()` and `time.After(usageBudget)`; every return path kills and waits).
- [ ] **Step 8: Add the `knownNonLLMExec` entry** for `claude.usageProcess` (reason above).
- [ ] **Step 9: Run** `go test ./internal/claude ./internal/llmusage` and `go test ./cmd/... -run 'TestCLIAudit|InitTestTemplate|LLMUSAGE|LLMTRANSPORT'` and `make lint-diff` — Expected: PASS; `TestLLMUSAGE01_LeavesRecord` reports neither an unrecorded `usageProcess` nor a stale key.
- [ ] **Step 10: Commit** `feat(claude): read plan usage through the get_usage control request (#1885)` (+ trailer).

---

### Task 3: Poller on the reader; token code deleted; PLANUSAGE-01/02 rewritten

**Depends on:** Task 2

**Files:**
- Delete: `internal/planusage/credentials.go`, `client.go`, `credentials_test.go`, `testdata/usage_full.json`, `usage_idle.json`, `usage_legacy.json`, `usage_surface.json`
- Create: `internal/planusage/nocredentials_test.go`
- Modify: `internal/planusage/parse.go` (delete `parse`, `rawWindow`, `rawLimit`, `rawResponse`, `fromRawLimit`, `scopeName`; keep `Limit`, `BreakdownRow`, `Usage`, `Projection`, `errNoLimits`, `clampPercent`, `parseReset` if still used, `slug` only if used), `parse_test.go` (old `TestParse_*` replaced), `poller.go`, `poller_test.go`, `storage_cancel_test.go` (`fakeFetch` → scripted `Read`), `provider.go` (`ErrorCode` only), `provider_test.go` (new `TestProviderRun_*` clearing tests), `aggregate.go`, `aggregate_test.go`, `cmd/plan_usage_daemon.go`, `cmd/plan_usage_daemon_test.go`, `internal/llmusage/leaves_test.go`, `docs/inventory/plan-usage.md`

**Interfaces:**
- Consumes: `claude.ReadUsage`, `claude.UsageSnapshot`, `claude.UsageError` (Task 2).
- Produces:
  - `type Poller struct{ Store Store; Read func(context.Context) (claude.UsageSnapshot, error); Now func() time.Time; Logger *log.Logger; failures int }` — `CredentialLoader`, `Fetcher`, `Creds`, `Client`, `Poller.Run` (dead: only `Provider.Run` schedules), `HTTPError`, `ErrNoCredentials`, `redact`, `reasonFor`'s HTTP branch are gone.
  - `func usageFromSnapshot(s claude.UsageSnapshot) (Usage, error)` in `parse.go` — windows → `Limit` (re-clamped, NaN/Inf dropped), empty key dropped, first window of a key wins, zero limits → `errNoLimits`; `Breakdown` passed through (nil allowed; `storeUsage` already writes `[]` via `nonNil`).
  - `ErrorCode`: adds `case errors.As(err, &cle /* *claude.UsageError */): return cle.Code`; drops the `ErrNoCredentials` and `HTTPError` cases.
  - `publicError` and `safeStoredReason` accept `cloud_bedrock`, `cloud_vertex`, `cloud_foundry`; `safeStoredReason` still maps `token_expired`/`http_401` → `no_credentials` and unknown → `network`.

`PollOnce` after the read (ctx cancelled → return `ctx.Err()`, nothing written, failure count unchanged — as today):
- success → `usageFromSnapshot`; ok → `st.Plan = snap.Plan` then unchanged `storeUsage`; error → code `parse`.
- `cli_missing`, `unsupported_cli` → `unavailable`, previous row's data kept, failures reset, next poll 5 min.
- `no_credentials`, `unsupported_auth`, `cloud_*` → `unavailable`, failures reset, 5 min, and the row's account fields cleared: `Plan=""`, `LimitsJSON="[]"`, `BreakdownJSON="[]"`, `PlotJSON="{}"`, `PublicationProof=""` (samples untouched).
- anything else → `error`, reason `safeStoredReason(code)`, `failures++`, `backoff(failures)`, last numbers kept.
- `last_error` on every failure is the fixed text `"Claude usage: " + code` (as Codex's `"Codex usage: " + code`); the returned error stays `*OperationError{Code}`.

- [ ] **Step 1: Write the failing PLANUSAGE-01 scan** `TestPlanUsage01_NoClaudeCredentialReader` in `nocredentials_test.go`: a walker `credentialMarkerHits(root string, dirs []string) ([]string, error)` reports `path: marker` for non-`_test.go` `.go` files and `.swift` files containing any of `Claude Code-credentials`, `claudeAiOauth`, `.credentials.json`, `api/oauth/usage`, `oauth-2025-04-20`, `find-generic-password`, skipping directories named `testdata`, `node_modules`, `vendor` or starting with `.`. First it runs over a synthetic `t.TempDir()` tree: `internal/a/a.go` with each marker → six hits; `internal/a/a_test.go`, `internal/a/testdata/x.go`, `.claude/worktrees/w/internal/b.go`, `WatchtowerDesktop/.build/x.swift` with markers → no hit. Then it runs over the module root (directory of `go env GOMOD`, or walk up to `go.mod`) for `cmd`, `internal`, `WatchtowerDesktop/Sources`, `WatchtowerKit/Sources`, `WatchtowerMobile/Sources` and asserts zero hits.
- [ ] **Step 2: Run** `go test ./internal/planusage -run TestPlanUsage01` — Expected: FAIL listing `internal/planusage/credentials.go` and `client.go`.
- [ ] **Step 3: Write the failing poller/parse tests** (scripted `Read` returning snapshots built by a `testClaudeSnapshot(plan string, pct float64)` helper unless stated):
  - `parse_test.go`: `TestUsageFromSnapshot_ConvertsWindows` (keys, labels, groups, percent, reset carried), `TestUsageFromSnapshot_DuplicateKeysFirstWins` (two `weekly_scoped:fable` + one empty key → one Fable limit, the first's percent), `TestUsageFromSnapshot_NoWindowIsParse` (`errors.Is(err, errNoLimits)`).
  - `poller_test.go` (ported from today's file, token cases removed): `TestPollOnce_OK` (plan `max` stored, three samples), `TestPollOnce_BackoffKeepsLastNumbers` (ok, then `network` ×3: delays 5/10/20 min, limits kept, `last_error == "Claude usage: network"`), `TestPollOnce_CLIMissingIsUnavailable` (ok, then `cli_missing`: state `unavailable`, plan and limits kept, delay 5 min), `TestPollOnce_PrunesOldSamples`, `TestMarkDisabled_KeepsNumbers`, `TestPollOnce_CancelledWritesNothing`, `TestPollOnce_NoCredentialsWriteFailureIsReported`, `TestPollOnce_Reasons` (each code of the closed set → stored state/reason per spec §1), `TestPollOnce_StoresBreakdownOrEmpty` (snapshot with breakdown rows → `breakdown_json` rows; nil → `"[]"`).
  - `TestPlanUsage02_ChildOutputNeverPersisted` (PLANUSAGE-02 guard, in `poller_test.go`) — `Read` = `claude.ReadUsage` over a fake `claude` script (pid file + group kill in `t.Cleanup`), logger into a `bytes.Buffer`. Marker `CHILD-SECRET-41`: written to stderr, put in an unknown answer field, and printed as a malformed line before the answer. Three runs: success, `parse` failure (answer whose `utilization` is the marker string), `network` failure (error answer whose `error` text is the marker). After each: no column of the status row (`fmt.Sprintf("%+v", *st)`), no sample, no logger byte and no returned error contains the marker.
  - `provider_test.go`: `TestProviderRun_SignedOutClearsPlanLabel`, `TestProviderRun_APIKeyClearsPlanLabel`, `TestProviderRun_CloudProviderClearsPlanLabel` — a `Provider{Poll: poller.PollOnce, After: fake}` driven tick by tick (pattern of `TestProvider_SchedulerBackoffResetAndBusy`): ok with plan `max` and limits → the code (`no_credentials` / `unsupported_auth` / `cloud_vertex`) → `network`; after both the last two ticks the row has `Plan == ""`, `LimitsJSON == "[]"`, `PlotJSON == "{}"`, and the samples from the ok tick are still there. `TestProviderRun_CLIMissingKeepsRow` — ok → `cli_missing`: plan `max` and limits kept, state `unavailable`.
  - `aggregate_test.go`: extend `TestPlansAggregate_StoredValidationAndIdentitySuppression` (or add `TestPlansAggregate_CloudReasonsArePublic`) — stored reasons `cloud_bedrock|cloud_vertex|cloud_foundry` read back as themselves; `token_expired` → `no_credentials`; `http_500` → `network`; `publicError(&claude.UsageError{Code:"cloud_foundry"})` → code `cloud_foundry`.
  - `cmd/plan_usage_daemon_test.go`: `TestPlanProviders_ClaudeReadsConfiguredCLI` — the helper-process pattern of `TestPlanProviders_CodexRuntimePATH`, with `claude_path` in the temp config pointing at a fake script that answers `get_usage`; the `claude` provider's `Refresh` gives state `ok`, plan `max`, `limits_json` containing `"key":"session"`; the script's pid group is reaped in `t.Cleanup`.
- [ ] **Step 4: Run** `go test ./internal/planusage ./cmd -run 'TestPollOnce|TestUsageFromSnapshot|TestPlanUsage0|TestProviderRun|TestPlansAggregate|TestPlanProviders'` — Expected: FAIL (compile errors on `Poller.Read`, missing functions).
- [ ] **Step 5: Implement** `usageFromSnapshot`, the new `Poller`/`PollOnce` (rules above), `ErrorCode`, `publicError`/`safeStoredReason`; delete the token files, `Poller.Run`, the old parser and the four `usage_*.json` fixtures; drop the `fakeCreds`/`fakeFetch`/`TestClient_Fetch`/`TestPollOnce_401IsStale`/`TestPlanUsage01_ExpiredTokenMakesNoRequest`/`TestPlanUsage02_TokenNeverPersisted`/`TestParse_*` tests. Update the package doc in `parse.go` ("reads … from the installed Claude Code's `get_usage` answer").
- [ ] **Step 6: Rewire the daemon** in `cmd/plan_usage_daemon.go`: rename the local `claude` variable to `claudePoller` (it would shadow the `claude` package); `Read: func(ctx) { latest, err := config.Load(flagConfig); if err != nil → &planusage.OperationError{Code:"storage", Cause: err}; env := append(os.Environ(), "PATH="+claude.RichPATH()); return claude.ReadUsage(ctx, claude.FindBinary(latest.ClaudePath), env) }`; the Claude `Provider.Poll` is `claudePoller.PollOnce` directly (the `stale/token_expired` → `no_credentials` wrapper is deleted).
- [ ] **Step 7: Remove** `"planusage.DefaultCredentialSource"` from `knownNonLLMExec`.
- [ ] **Step 8: Rewrite the inventory** `docs/inventory/plan-usage.md` exactly per spec §13: PLANUSAGE-01 title "Watchtower never reads, refreshes or writes Claude credentials", Observable = the §13 text, guards `internal/planusage/nocredentials_test.go::TestPlanUsage01_NoClaudeCredentialReader` and `internal/claude/usage_test.go::TestPlanUsage01_ReaderArgvAndHome`, Why locked = Claude Code's terms forbid collecting or intermediating Claude credentials; PLANUSAGE-02 title "The usage child's output never reaches the DB, logs or errors", guard `internal/planusage/poller_test.go::TestPlanUsage02_ChildOutputNeverPersisted`; module line gains `internal/claude/usage*.go`; LLMUSAGE-01 text unchanged. Changelog entry dated the implementation day: "PLANUSAGE-01 and PLANUSAGE-02 rewritten (plan limits without the token, spec `docs/superpowers/specs/2026-11-17-plan-limits-without-token-design.md`, approved in ask #1448): the token reader and its guards `TestPlanUsage01_ExpiredTokenMakesNoRequest` / `TestPlanUsage02_TokenNeverPersisted` are deleted with the code; new guards are strictly stronger. LLMUSAGE-01 unchanged: `knownNonLLMExec` swaps `planusage.DefaultCredentialSource` for `claude.usageProcess`; no guard relaxed."
- [ ] **Step 9: Run** `go test ./internal/planusage ./internal/claude ./internal/llmusage ./internal/chat`, `go test ./cmd -run 'TestPlanProviders|TestUsagePlan'`, `go test ./cmd/... -run 'TestCLIAudit|InitTestTemplate|LLMUSAGE|LLMTRANSPORT'`, `make lint-diff` — Expected: PASS; `TestUsagePlanJSON_PinnedKeys` unchanged.
- [ ] **Step 10: Commit** `feat(planusage): Claude limits from get_usage, token reader removed, PLANUSAGE-01/02 rewritten (#1885)` (+ trailer).

---

### Task 4: Quiet steady states log once per change

**Depends on:** none

**Files:**
- Modify: `internal/planusage/provider.go` (`Run` only), `internal/planusage/provider_test.go`

**Interfaces:**
- Produces: `var quietCodes = map[string]bool{"cli_missing", "unsupported_cli", "no_credentials", "unsupported_auth", "cloud_bedrock", "cloud_vertex", "cloud_foundry"}` (package-level, unexported); `Run` keeps a local `lastQuiet string`: a quiet code is logged only when it differs from `lastQuiet`, then remembered; a success (`err == nil`) clears it; any non-quiet logged code also clears it; `busy` and `feature_disabled` stay unlogged and leave it untouched. The log line format is unchanged (`"%s plan usage: %s (next poll in %s)"`).

- [ ] **Step 1: Write the failing test** `TestProviderRun_QuietStatesLogOncePerChange`: a `Provider{Name:"claude", Poll: scripted, After: fake channel, Logger: log.New(&buf, "", 0)}` whose `Poll` returns, tick by tick, `cli_missing ×3 → no_credentials ×2 → ok → no_credentials → network ×2` (`&OperationError{Code}` or nil). The logged codes (parse each line's second field) equal exactly `[cli_missing, no_credentials, no_credentials, network, network]`. Add a `busy` tick between the two `no_credentials` runs in a second sub-case: still one line for that run.
- [ ] **Step 2: Run** `go test ./internal/planusage -run TestProviderRun_QuietStates` — Expected: FAIL (every tick logged).
- [ ] **Step 3: Implement** the rule in `Provider.Run`.
- [ ] **Step 4: Run** `go test ./internal/planusage` and `make lint-diff` — Expected: PASS (the Codex scheduler tests still pass: Codex shares the rule).
- [ ] **Step 5: Commit** `feat(planusage): log quiet plan-usage states once per change (#1885)` (+ trailer).

---

### Task 5: Desktop — per-provider wording, cloud codes, surface block, mockups

**Depends on:** none

**Files:**
- Modify: `WatchtowerDesktop/Sources/WatchtowerCore/Models/SubscriptionUsagePolicy.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/SessionAgent/ClaudeSessionAgent.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/SessionAgent/CodexSessionAgent.swift`, `WatchtowerDesktop/Sources/WatchtowerCore/Services/PlansPresentation.swift` (`errorText`), `WatchtowerDesktop/Sources/WatchtowerCore/Models/PlansUsage.swift` (`PlansOperationError.codes`), `WatchtowerDesktop/Tests/Core/PlansUsageTests.swift`, `WatchtowerDesktop/Tests/Core/PlansScreenPresentationTests.swift`, `WatchtowerDesktop/Tests/DesignShots/PlanLimitsNoTokenMockCopyTests.swift`, `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+PlanLimitsNoToken.swift` (adds the scenes `plan-limits-nt-cloudBedrock`, `plan-limits-nt-cloudVertex`, `plan-limits-nt-cloudFoundry` and their `plan-limits-nt-menu-*` twins, built like `plan-limits-nt-apiKey`; doc comment), `WatchtowerDesktop/Tests/DesignShots/PlanLimitsNoTokenMockCopy.swift` (doc comment only)
- Create: `WatchtowerDesktop/Tests/Core/PlansPresentationTests.swift`

**Interfaces:**
- Produces: `package struct SubscriptionUsageMessages: Sendable { package let cliMissing, unsupportedCLI, noCredentials, unsupportedAuth: String; package let cloudProviders: [String: String] }` (code → full sentence; empty for Codex) as `SubscriptionUsagePolicy.messages`. Claude's values are the Global Constraints strings; Codex's are today's (`"Install Codex, then retry."`, `"Update Codex to read subscription limits, then retry."`, `"Open Codex and sign in, then retry."`, `"Sign in to Codex with a ChatGPT account, then retry."`, `[:]`). `PlansPresentation.errorText(_:provider:)` reads `provider.subscription.messages`; a `cloud_*` code without an entry falls to today's default ("Couldn't update <title> limits. Retry to update."). `PlansOperationError.codes` gains `cloud_bedrock`, `cloud_vertex`, `cloud_foundry`. `signInApplication` stays (other readers).

- [ ] **Step 1: Write the failing tests.**
  - `PlansPresentationTests.testClaudeWordingForEveryCode` — for `.claude`: each Global Constraints string for `cli_missing`, `unsupported_cli`, `no_credentials`, `unsupported_auth`, `cloud_bedrock`→"…Bedrock…", `cloud_vertex`→"…Vertex…", `cloud_foundry`→"…Foundry…"; `network`→"Couldn't update Claude limits. Retry to update.", `parse`, `timeout`, `busy`, `storage`, `cancelled`, `feature_disabled` → today's shared texts; no Claude string contains "token", "Keychain" or "ANTHROPIC_".
  - `PlansPresentationTests.testCodexWordingUnchanged` — every code in `PlansOperationError.codes` for `.codex` equals today's text; `cloud_*` → "Couldn't update Codex limits. Retry to update.".
  - `PlansPresentationTests.testLegacyTokenReasonsReadAsSignIn` — `token_expired` and `http_401` for `.claude` → "Sign in to Claude Code with your Claude plan, then retry."; a card built from a stored `stale/token_expired` row (via `PlansPresentation.card`) has that summary.
  - `PlansUsageTests.testCopyForEveryUnavailableReasonAndOperationError` — its `errors` dictionary gains the three `cloud_*` keys with the Codex default text (the `Set(errors.keys) == Set(codes)` check then holds).
  - `PlansScreenPresentationTests.testSurfaceBreakdownShowsWhenPresentAndHidesWhenAbsent` — two Claude `ok` snapshots identical except `breakdown` (rows vs `[]`), limits chosen so `providers[0].otherLimits.isEmpty` (asserted as a precondition): `hasDetails` is true with rows, false without.
  - `PlanLimitsNoTokenMockCopyTests.testProductionWordingMatchesMockCopy` — for every `Frame` except `.readFailed`, `PlansPresentation.errorText(PlanLimitsNoTokenShotFixtures.reason(frame), provider: .claude) == PlanLimitsNoTokenShotFixtures.mockMessage(frame)`; for each `PlanLimitsNoTokenMockCopy.cloudProviders` entry, `errorText(code, .claude) == cloudProvider(name)`.
- [ ] **Step 2: Run** `make test-swift FILTER='PlansPresentationTests|PlansUsageTests|PlansScreenPresentationTests|PlanLimitsNoTokenMockCopyTests'` — Expected: FAIL on the Claude wording and the codes set.
- [ ] **Step 3: Implement** `SubscriptionUsageMessages`, the two policy values, `errorText`, `PlansOperationError.codes`. Update the two DesignShots doc comments: the Claude message is now production's; `PlanLimitsNoTokenMockCopy` stays as the spec's pinned table, cross-checked against production.
- [ ] **Step 4: Run** the same filter plus `make test-swift FILTER='DesignShotsTests/testPlanLimitsNoTokenShotsRender|PlansPopupPresentationTests|PlansUsageCenterTests'` and `make lint-swift` — Expected: PASS.
- [ ] **Step 5: Look at the screens.** `make desktop-shots DESKTOP_SHOTS=<scratch dir>`; compare `plan-limits-nt-cliMissing`, `plan-limits-nt-cliOutdated`, `plan-limits-nt-notSignedIn`, `plan-limits-nt-apiKey`, `plan-limits-nt-readFailed`, the three new cloud scenes `plan-limits-nt-cloudBedrock`, `plan-limits-nt-cloudVertex`, `plan-limits-nt-cloudFoundry` (added to `PlanLimitsNoTokenShotFixtures` in this task; same layout and tone as `plan-limits-nt-apiKey`, only the provider name differs, so they are compared against the `apiKey` mockup) and their `plan-limits-nt-menu-*` shots (light and dark) with `docs/design/mockups/plan-limits-no-token/`; the production `plans` shots under `docs/design/shots/plans/` (ok state) are unchanged. Expected: identical text and tones; any difference is a bug in this task.
- [ ] **Step 6: Commit** `feat(desktop): word Claude plan-limit codes per provider, cloud reasons (#1885)` (+ trailer).

---

### Task 6: Docs — feature note, README summary, guide

**Depends on:** Task 3, Task 5

**Files:**
- Modify: `docs/features/claude-plan-limits.md` ("Sources and identity" Claude paragraph; the polling paragraph gains the quiet-state log rule), `docs/features/README.md` (the plan-limits summary line: Claude via `claude -p` `get_usage`, no credentials, PLANUSAGE-01/02 rewritten), `docs/guide/features/plans.md`, `docs/guide/troubleshooting/plan-limits-or-high-cost.md`

- [ ] **Step 1: Feature note.** Replace the Claude sentence with: Claude reads through the installed `claude` (`FindBinary(claude_path)`) with the exact argv, the one `get_usage` request, neutral folder, inherited env + `RichPATH`, caps, budget, reaping; Watchtower never reads, refreshes or writes Claude credentials; the codes and the API-key/cloud states; surface breakdown shown only when the answer carries it (A4); `get_usage` is Experimental (spec §19).
- [ ] **Step 2: Guide** (follow `docs/guide/WRITING.md`): "How it works" says Watchtower asks your installed Claude Code for its plan usage (the numbers `/usage` shows) and never reads your Claude sign-in. Replace **Sign-in expired** with **Claude Code not signed in with a plan** (sign in to Claude Code with your Claude plan, then press **Refresh**; with an API key or Bedrock/Vertex/Foundry set for Watchtower, plan limits don't apply) and add **Claude Code missing or too old** (install or update Claude Code, then retry). Troubleshooting step 6 likewise.
- [ ] **Step 3: Run** `go test ./docs/guide` — Expected: PASS (page size cap, links).
- [ ] **Step 4: Commit** `docs: plan limits read through Claude Code, no credentials (#1885)` (+ trailer).

---

### Task 7: Coordination — consent-spec line and the Codex follow-up target

**Depends on:** none (controller task, no code in this branch)

- [ ] **Step 1: Consent spec line (A8).** Hand the coordinator this line for the background-launch list of `docs/superpowers/specs/2026-11-17-background-ai-consent-design.md` (and its plan, if written) on branch `feature/1886-background-ai-consent`: "Plan-limit read — every 5 min, `claude -p` `get_usage` control request, no model call, no `llm_calls` row, not gated by the consent." Done when the line is on that branch (`git show origin/feature/1886-background-ai-consent:docs/superpowers/specs/2026-11-17-background-ai-consent-design.md | grep -n 'get_usage'` prints it).
- [ ] **Step 2: Follow-up target (A7).** File a board target "Codex plan limits without app-server, if needed" with the trigger (OpenAI says read-only app-server use in a commercial app is not permitted, or before a paid Watchtower tier ships) and the alternative (newest `token_count` `rate_limits` from `~/.codex/sessions`, current numbers only, no forecast), linking spec §10.

---

## Promises → tasks → tests

| Promise (spec) | Task | Test |
|---|---|---|
| No Claude credential read anywhere (§6, §13 PLANUSAGE-01) | 3 | `TestPlanUsage01_NoClaudeCredentialReader` |
| The reader starts only `claude` with §1's argv, one request, no turn, decoy credentials untouched | 2 | `TestPlanUsage01_ReaderArgvAndHome`, `TestReadUsage_*` |
| Same keys, history continues (§2, PLANUSAGE-03 keys) | 2, 3 | `TestParseClaudeUsage_KeysMatchLegacy`, `TestUsageFromSnapshot_ConvertsWindows` |
| Null window absent, not 0 % | 2 | `TestParseClaudeUsage_NullWindowIsAbsent` |
| `model_scoped` absent → no invented scoped row | 2 | `TestParseClaudeUsage_ModelScopedAbsent`, `TestParseClaudeUsage_ModelScopedWinsOverOpus` |
| Shape changed → `parse`, last numbers kept | 2, 3 | `TestParseClaudeUsage_Malformed`, `TestUsageFromSnapshot_NoWindowIsParse`, `TestPollOnce_Reasons` |
| States and backoff per §1/§3 | 3 | `TestPollOnce_*` (ported), `TestPollOnce_CLIMissingIsUnavailable`, `TestPollOnce_BackoffKeepsLastNumbers` |
| Child output never stored (PLANUSAGE-02) | 2, 3 | `TestPlanUsage02_ChildOutputNeverPersisted` |
| Ledger stays complete (LLMUSAGE-01) | 2, 3 | `TestLLMUSAGE01_LeavesRecord` |
| API key in the environment is its own state; value never read | 1, 2 | `TestReadUsage_APIKeyEnvIsUnsupportedAuth`, `TestReadUsage_APIKeyEnvWithLimitsAvailableReadsNumbers` |
| Cloud provider named | 2, 5 | `TestReadUsage_CloudEnvIsCloudReason`, `PlansPresentationTests.testClaudeWordingForEveryCode` |
| One env list shared with the chat | 1 | `TestLoginOverride_OrderAndLastWins`, chat's `TestClaudeAIAvailability` unchanged |
| Account-level states clear plan and numbers; samples kept | 3 | `TestProviderRun_SignedOutClearsPlanLabel`, `TestProviderRun_APIKeyClearsPlanLabel`, `TestProviderRun_CloudProviderClearsPlanLabel` |
| `cli_missing`/`unsupported_cli` keep the row | 3 | `TestProviderRun_CLIMissingKeepsRow` |
| Quiet states log once per change (Codex too) | 4 | `TestProviderRun_QuietStatesLogOncePerChange` |
| `cloud_*` in `usage plans --json`; unknown stored reason reads `network`; old `token_expired` reads `no_credentials` | 3, 5 | `TestPlansAggregate_CloudReasonsArePublic`, `PlansUsageTests.testCopyForEveryUnavailableReasonAndOperationError` |
| Daemon wiring reads `claude_path` every poll; no `stale` special case | 3 | `TestPlanProviders_ClaudeReadsConfiguredCLI` |
| Per-provider wording | 5 | `PlansPresentationTests.testClaudeWordingForEveryCode`, `testCodexWordingUnchanged` |
| Old `stale/token_expired` row after upgrade reads as Sign in | 5 | `PlansPresentationTests.testLegacyTokenReasonsReadAsSignIn` |
| Surface block shows/hides with its data (A4) | 2, 3, 5 | `TestParseClaudeUsage_BreakdownOptional`, `TestPollOnce_StoresBreakdownOrEmpty`, `PlansScreenPresentationTests.testSurfaceBreakdownShowsWhenPresentAndHidesWhenAbsent` |
| Mockups match the spec and production | 5 | `PlanLimitsNoTokenMockCopyTests` (incl. `testProductionWordingMatchesMockCopy`), shots `plan-limits-nt-*`, `plan-limits-nt-menu-*` |
| The consent spec lists the plan-limit read (A8) | 7 | the `git show … | grep get_usage` check |
| Codex follow-up target filed (A7) | 7 | the board target exists |

### §11 failure modes → tests

| Failure | Task | Test |
|---|---|---|
| `claude` not installed | 2, 3 | `TestReadUsage_CLIMissing`, `TestPollOnce_CLIMissingIsUnavailable` |
| Older Claude Code without `get_usage` | 2 | `TestReadUsage_UnsupportedRequest`, `TestReadUsage_FlagsRejected` |
| Signed out | 2 | `TestReadUsage_RateLimitsUnavailable` |
| API key / cloud provider in env | 2 | `TestReadUsage_APIKeyEnvIsUnsupportedAuth`, `TestReadUsage_CloudEnvIsCloudReason` |
| Sign-out / API key after a good read | 3 | `TestProviderRun_*ClearsPlanLabel` |
| Quiet states repeat every 5 min | 4 | `TestProviderRun_QuietStatesLogOncePerChange` |
| Surface rows absent | 2, 5 | `TestParseClaudeUsage_BreakdownOptional`, `testSurfaceBreakdownShowsWhenPresentAndHidesWhenAbsent` |
| Claude Code cannot reach its endpoint | 2, 3 | `TestReadUsage_RateLimitsNull`, `TestPollOnce_BackoffKeepsLastNumbers` |
| Shape changed | 2 | `TestParseClaudeUsage_Malformed`, `TestParseClaudeUsage_NullWindowIsAbsent` |
| CLI hangs | 2 | `TestReadUsage_TimeoutReapsGroup` (synctest) |
| Hook/system lines first | 2 | `TestReadUsage_SkipsOtherLines` |
| Huge or endless output | 2 | `TestReadUsage_OutputCapped` |
| Cancelled | 2, 3 | `TestReadUsage_CancelReaps`, `TestPollOnce_CancelledWritesNothing` |
| `model_scoped` absent | 2 | `TestParseClaudeUsage_ModelScopedAbsent` |
| Keys survive the upgrade | 2 | `TestParseClaudeUsage_KeysMatchLegacy` |
| Old `stale/token_expired` row | 5 | `testLegacyTokenReasonsReadAsSignIn` |

### §12 writers

| Data | Task | How it stays true |
|---|---|---|
| `plan_usage_status`, `plan_usage_samples` — one writer under `.plan-usage-claude.lock` | 3 | `Provider` lock code untouched; `TestProvider_ProcessSerializationAndCrashRelease`, `TestProvider_LockBudgetsDisableAndStableInode` stay green; the reader's 20 s budget fits the 45 s provider budget and the 20 s manual lock wait |
| Claude Code's own state | 2 | written only by the child; Watchtower writes none (`TestPlanUsage01_ReaderArgvAndHome` decoys) |
| Claude credentials | 2, 3 | never read, refreshed or written (`TestPlanUsage01_NoClaudeCredentialReader`, `TestPlanUsage01_ReaderArgvAndHome`) |

## Gate (controller, once, before the PR)

`make test`, `make test-swift`, `make lint-all`, `go test ./cmd/... -run 'TestCLIAudit|InitTestTemplate|LLMUSAGE|LLMTRANSPORT'`, `go test ./docs/guide`, then `scripts/leak-check.sh origin/main..HEAD`.
