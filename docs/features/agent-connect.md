# Connect with an agent — Claude or Codex sets up every connector (2026-11-21, #2133)

Spec: [`docs/superpowers/specs/2026-11-21-agent-connect-design.md`](../superpowers/specs/2026-11-21-agent-connect-design.md). Plan: [`docs/superpowers/plans/2026-11-21-agent-connect.md`](../superpowers/plans/2026-11-21-agent-connect.md). Guide: [`docs/guide/features/connect-with-an-agent.md`](../guide/features/connect-with-an-agent.md) and the playbooks in `docs/guide/connect/`.

A **Connect with <harness>** button beside today's connect controls opens the *connect assistant*: a chat panel that runs one connector's playbook on the customer's own Claude or Codex. The agent drives the Desktop's existing connect flows through a small set of connect tools; with Claude in Chrome it also does the vendor-console clicks. It is another path beside today's screens, not a replacement (ask #1702): **Set up by hand** always opens the manual screen.

## Pieces

| Layer | Where | What |
|---|---|---|
| Playbooks | `docs/guide/connect/*.md` (14 pages) | Guide pages that are also the agent's script. Template and step tags (`Agent:` / `You:` / `You only:` / `Check:`) in `docs/guide/WRITING.md` "Connect playbooks"; one fenced `connect` block (`service`, `vendor`, `domains`, `tools`, `secrets`, `options`). |
| Parser + prompt | `internal/connectplay` | `ForService(svc, vendor)`, `KnownTools`, `KnownSecrets`, the reveal-page check (`reveal.go`: an agent step may not name a page or button that shows a secret), `TestPlaybooks_PublicSafe`, `SystemPrompt(pbs, mode)` (role, page-text-is-data rule, host list, secret rule, words/browser rules, the playbooks), `Hosts`, `NavigationAllowed`. |
| Capability | `internal/providers/caps` `Connect` | `browser` (claude), `words` (codex), `none` (ollama). The button is offered by capability, never by provider name (LLMTRANSPORT-01). Swift `ConnectHarnessCatalog.offered(providers:allowed:ready:base:)`. |
| Turn runner | `watchtower ai query --tools connect --connect-service <svc> --connect-mode browser\|words\|probe` (`cmd/ai_connect.go`) | Refuses without `--tools connect`, with `--persist`, `--read-folder*`, `--owner-instructions`, an unknown service, or a provider whose `Connect` is none or not allowed. No reserve routing (spec §8: no fallback mid-run). Claude browser mode: `--chrome`, `--strict-mcp-config`, `--tools ""`, `--allowedTools mcp__watchtower,mcp__claude-in-chrome__*`, S2's deny list, and an inline `--settings` whose PreToolUse hook on `navigate` runs the hidden `ai connect-guard --host …` (fails closed). `probe` = the S1 turn: only `list_connected_browsers` allowed, every other Chrome tool denied, no connect MCP mount, no socket env. |
| MCP server | `watchtower mcp --connect <svc>` (`cmd/mcp.go`, `internal/connectmcp`) | Mounts only the connect tools the service's playbooks list, with hand-written schemas; refuses bad args before forwarding. Opens no database and reads no config; every other mcp flag is refused ("--connect runs alone"), `--db-path` is accepted and ignored. Exits unless `WATCHTOWER_CONNECT_SOCKET` and `WATCHTOWER_CONNECT_TOKEN` are set. |
| Wire | `internal/connectwire` ↔ Swift `ConnectWire` | JSON lines over a per-run Unix socket. Hello `{v, service, token}` → `{"ok":true}` or a `busy` refusal; requests `{id, tool, args}`; responses `{id, result}` or `{id, error{code,message}}`. Codes: `busy`, `policy`, `limit`, `unknown_tool`, `bad_args`, `declined`, `closed`, `failed`. 45 s per call, 1 MiB per line. Shared fixture `internal/connectwire/testdata/wire_cases.json`, read by `ConnectWireTests`. |
| Socket | Swift `ConnectRunServer` | `mkdtemp` 0700 dir, `connect.sock` 0600, 256-bit token in the child's env (never argv). Admits a peer with the owner's uid (`getpeereid`), protocol 1, the run's service and a constant-time token match; one peer at a time (a newer one takes the slot only when the old one hung up). `stop()` unlinks and removes the dir. Nothing logs. |
| Run rules | `ConnectRunController` | Per run: at most 5 `connect_start` that reach a driver, one flow at a time, policy re-checked on the Desktop. Waiting calls hold ≤ 45 s and answer `{"state":"waiting"}`; the agent calls again and re-attaches to the same step. Per step: 900 s and 20 calls, then `timeout`. Confirm cards and secret cards are answered only by the panel (`answerConfirm`, `sendSecret`, `cancelSecret`), never by a tool. A secret lives only in the Task that hands it to the driver. `end()` answers held calls `closed`. |
| Drivers | `Sources/Services/Connect/*` (personal), `WatchtowerCore/Services/Connect/{Company,OwnGoogleProject}ConnectDriver.swift` | `ConnectServiceDriving` / `ConnectCompanyDriving` / `ConnectLiveProbing` over the same view models the buttons use: Slack (`SlackConnectFlowModel`, `SlackAppSetupModel`), Google, Email (Outlook, IMAP), Calendar (CalDAV, ICS), Jira (+ Confluence, `--site`, `--company`), Linear (OAuth, API key), Quick Connections, the company wizard (`CompanySetupWizardModel`, draft save/check/publish) and the own-Google-project page. |
| Session | `ConnectAssistantSession`, `ConnectAssistantCenter`, `ConnectBrowserProbe` | Memory-only embedded chat (`ChatSurfaceSpec` `ToolAccess.connect(service:mode:)`, never persisted, no owner instructions). Start: fresh controller + socket, `connect_status` into the prompt, the browser probe (browser harness only), then "Start". Mid-run, a browser tool result starting `Browser extension is not connected.` switches to words mode with a hidden follow-up turn. |
| Panel + entries | `ConnectAssistantPanel`, `ConnectAssistantPresentation` (all strings, tested), `AppState+ConnectAssistant.swift` | 380 pt panel on the Connections tab and beside the onboarding Connect step. Entry points: source cards with no account, the Companies zone, the **Connect…** menu, each detail's add row, Jira's empty state (**Set up for my company with <harness>**), the own-Google-project page, onboarding rows. |

## Who writes what

The agent writes nothing by itself. Every write is a Desktop flow the buttons already run (`slack connect serve`, `<svc> add|login --app-return`, `slack app create|adopt`, `company draft save|check|publish`, `quickconnections`), so locks, single-flow rules, policy and purge checks are unchanged; the first start wins and a second gets `busy` (the panel's busy state with **Open it**). Secrets go from the panel's card straight to the verb's stdin or the wizard's in-memory draft, never through the model, a transcript or a log; driver results are scrubbed of anything that looks like the pasted value.

Confirm cards (only the customer can press them): Slack PKCE adopt, a company Slack app update (the diff lines), a bring-your-own Google client, a Quick Connection's `enable`, company **Publish**, **Replace** of a stored company. Every other step is covered by the panel's **Start** — for Slack that is the owner's press of SLACKFULL-01 (owner Q1, ask #1721).

MDM: a source blocked by `AllowedSources` (`PolicySourceMap`), a provider outside `AllowedAIProviders`, no allowed Quick Connection, or own Google project not allowed → no agent button; `connect_start` refuses the same source again on the Desktop. `SlackApps` never blocks an assistant connect; with no option the driver uses the org's first open row.

## Panel states

`empty` (intro + **Start**, **Guide me in words** in browser mode, **Set up by hand**; mode line "Using <harness> in Chrome" / "I'll tell you each step"), `thinking`, `waiting` ("Waiting for you to …" + **Cancel**), `listening` (the agent's turn ended and it waits on the composer: no status line, **Cancel**), `failed` (agent, quota, harness missing, timed out; **Retry** + **Set up by hand**), `busy` (**Open it**), secret card (**Send**, **Don't send**, a close-the-page-first line per vendor), confirm card ("Only you can press this — <harness> can't."), `done` ("Slack is connected — 2 workspaces"). The mode line's help text names the S2 and secret-page limits.

## Lifecycle

- **Close / quit:** `endRun` stops the controller, the socket and the engine. A running Desktop flow keeps today's behaviour: the Slack sign-in is handed to its own sheet (Connections → Slack, or the onboarding step's sheet); OAuth loopbacks time out. Reopening reads `connect_status` and the playbook resumes from it; `connect_wait`/`connect_cancel` adopt the driver's running flow.
- **Retry** starts a fresh controller, socket and engine. **Switch the assistant** ends the run and returns to the empty state on the other harness.
- **Onboarding:** drivers read `accountDaemonPolicy`, so a connect during onboarding defers the daemon restart like the sheets do.
- **Harness readiness:** `ai which` per connect-capable provider, refreshed on the Connections tab and the onboarding Connect step.

## v1 limits and follow-ups

- **Readiness = the CLI is found**, not signed in: no cached signed-in result exists and `ai test` costs a model request. A not-signed-in CLI fails the first turn into the error state with **Retry** / **Set up by hand**.
- **No agent Reconnect.** The attention banner keeps today's **Reconnect** only; no driver can re-sign an existing account (a plain connect adds a new one, and a Google custom client or scopes would be lost). Follow-up: a reconnect intent per driver, then the banner button returns.
- **Codex is words only.** S3 failed: `codex exec` gets no Chrome from the CLI (the bundled `chrome@openai-bundled` plugin is installed only by the Codex desktop app). Plan Task 7 (Codex browser) was dropped; re-check when the CLI ships the bundled marketplace.
- **The Claude browser probe has no time bound.** A stalled CLI leaves the panel preparing until **Cancel**. Follow-up: a probe watchdog on an injectable clock. The non-empty `list_connected_browsers` shape is still unverified (the live matrix observes it).
- **A `connect_wait` that runs out its step budget** (15 min / 20 calls) cancels the driver flow, so **Retry** finds a free slot. Closing the panel or quitting does not cancel the flow (§8). Own Google project has no cancel: after a timeout, Retry is `busy` until `google add` ends on its own.
- **Slack connect flow has no attempt counter.** A paste/link attempt that ends and is replaced within one watcher hop can be attributed to the wrong attempt.
- **No structured "harness missing" code.** `ConnectAssistantSession` matches the error text (`executable file not found`, `command not found`, …) to show "<harness> isn't installed on this Mac".
- **Narrow onboarding.** At the 800 pt minimum window the 380 pt panel leaves the step's rows cramped (the two buttons get tight).
- **Not enforceable in the browser:** a link click, form post or redirect to another host (only `navigate` is hooked; the prompt says leave and stop), and an agent that reads a secret page while the customer has it open. Both are named in the panel's help text.
- **Company draft read is thin:** ids, site and `client_secret_set` only; `connect_status.setup.stage` carries the wizard's page.

## Live matrix

**Pending (2026-11-21): not run on this branch.** It needs vendor sandbox accounts and Claude in Chrome connected, and it creates real apps and projects in vendor consoles, so it is not unattended agent work. The Codex + browser column is omitted: plan Task 7 was dropped (S3 failed). Each cell checks: connected (or the expected failure stage), no pasted secret in the chat or in `~/Library/Logs`, and the confirm cards where required.

| Playbook | Claude + extension | Claude words | Codex words |
|---|---|---|---|
| slack | not run | not run | not run |
| google | not run | not run | not run |
| mail | not run | not run | not run |
| calendar | not run | not run | not run |
| jira | not run | not run | not run |
| confluence | not run | not run | not run |
| linear | not run | not run | not run |
| quick-connections | not run | not run | not run |
| company-slack | not run | not run | not run |
| company-google | not run | not run | not run |
| company-atlassian | not run | not run | not run |
| company-microsoft | not run | not run | not run |
| company-linear | not run | not run | not run |
| own-google-project | not run | not run | not run |

## Tests

Go: `go test ./internal/connectplay ./internal/connectwire ./internal/connectmcp ./internal/ai -run Browser ./cmd -run 'Connect|MCP'`, `./internal/providers/...` (caps). Swift (Core): `ConnectWireTests`, `ConnectRunServerTests`, `ConnectRunControllerTests`, `ConnectAssistantSessionTests`, `ConnectAssistantPresentationTests`, `ConnectHarnessCatalogTests`, `CompanyConnectDriverTests`; app target: `SlackConnectDriverTests`, `PersonalConnectDriverTests`, `ConnectEntryPointsTests`. Shots: `connect-assistant-{empty,loading,error,busy,narrow,secret,confirm,done}`, `connect-overview-agent`, `connect-detail-add-account`, `connect-onboarding-step`.
