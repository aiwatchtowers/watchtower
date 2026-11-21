# Connect with an agent — Claude or Codex sets up every connector (design)

Board #2133. Owner decisions: asks #1697 (no extension → the agent guides in words; every connector in one delivery; Claude and Codex as equals), #1698 (the vendors' own browser extensions) and #1702 (this is **another path, not a replacement**: today's screens stay; the assistant runs on the base harness the customer set up in onboarding, which cannot be skipped; the browser extension may be missing).

## 1. Why

The Connections screens explain too much: the Slack company setup alone talks about configuration tokens, adopting an app, PKCE, "link or code" and a busy port. Customers get lost. Watchtower is an AI product, so the setup should be done by an AI: the customer's own Claude or Codex opens the vendor's pages in the customer's browser, clicks through them, and hands the result to Watchtower. The customer signs in and approves; nothing else needs reading.

Success: a customer who has never seen Slack's app console connects Slack, Google, Jira, Linear, mail, calendar and a Quick Connection by pressing **Connect with Claude** (or Codex) and talking to the assistant, without reading any setup copy. Customers who prefer the forms still have them.

## 2. Goals, non-goals, anti-goals

**Goals**
- G1. A **Connect with <harness>** button per connector, beside today's controls, opens the *connect assistant*: a chat panel that runs that connector's playbook on Claude or Codex.
- G2. With the vendor browser extension available the agent does the browser steps itself (Claude in Chrome through `claude --chrome`; Codex through its `browser_use` / `browser_use_external` features).
- G3. Without it (no extension, or the extension not connected) the same chat, the same playbook: the agent tells the customer each browser step and checks the result.
- G4. Every flow is written down: one playbook per connector, which is at once the agent's script, a guide page and what the help chat (⌘/) answers from.
- G5. Claude and Codex are equals: every playbook is verified on both (§9).

**Non-goals**
- Our own browser extension or a Chrome DevTools bridge (rejected in ask #1698).
- New connectors. Slack Live (the customer's claude.ai/ChatGPT Slack connector) keeps its probe; its playbook only explains how to turn the vendor connector on.
- Changing how a connector stores tokens, syncs, or what the MDM policy allows.
- Removing or rewriting today's connect screens: they stay as the manual path (ask #1702).

**Anti-goals** (a failure even if it works)
- A secret (Slack configuration token, IMAP password, API key, ICS URL, a client secret the customer pastes) passing through the model — its context, a transcript, a log. No exception: company OAuth client secrets are pasted by the customer too (decision P2, §12).
- The agent writing to Watchtower by any path other than the flows the buttons already use.
- A web page the agent reads making it do something outside the playbook (prompt injection).
- A customer stuck: when the assistant fails, the panel always offers **Set up by hand**, which opens today's screen for that connector.

## 3. Constraints (from recon)

- Every connect is already a Desktop-owned flow: the `*AccountsViewModel`s spawn `watchtower <svc> add|login --app-return`, the Slack connect runs on the Desktop's `slack connect serve` child, which owns port 127.0.0.1:18551 (only one process can; a CLI `slack connect` with the Desktop open exits 2). So the agent must drive the Desktop's flows, not run the CLI itself.
- Secrets already go to the CLI on stdin only (`readSecret`, `readPassword`, `slack app` token on the first stdin line, SLACKFULL-02).
- The existing `SetupAssistantChat` (Email, Calendar) fills forms through a credential-free patch over an embedded chat (`ChatSurfaceSpec`). It is the precedent; it stays on the manual forms.
- Codex runs with `browser_use`, `browser_use_external`, `in_app_browser`, `computer_use` forced off (`internal/codex/generator.go` `disabledFeatures`, pinned by `TestDisabledFeatures_MatchSnapshot`). Claude chat never passes `--chrome`.
- MDM gates stay authoritative: `AllowedSources` via `applySourceGuards`, `AllowedQuickConnections`, `AllowedAIProviders`, `SlackApps`. A blocked connector shows the policy lock and no **Connect**; a blocked provider is not offered.
- Guide pages are public, ≤ 8 KB each (`docs/guide/guide_test.go`), with stable `##`/`###` anchors.

## 4. Approaches (decided)

1. **Vendor extensions** — Claude in Chrome for Claude, Codex's own browser for Codex. Nothing of ours in the browser; parity comes from one shared playbook verified on both. Risk: we depend on two vendors' extensions behaving. **Picked (ask #1698).**
2. One Chrome DevTools MCP bridge given to both CLIs — full parity, but the customer must run Chrome with remote debugging (extra setup, and any local process then sees their sessions). Rejected.
3. A Watchtower browser extension — full control, but Web Store review, maintenance, and one more extension to install. Rejected.

## 5. The design

### 5.1 Playbooks

- One file per connector: `docs/guide/connect/{slack,google,mail,calendar,jira,confluence,linear,quick-connections}.md` for a person's own accounts, and `docs/guide/connect/company-{slack,google,atlassian,microsoft,linear}.md` plus `own-google-project.md` for the company setup (§5.4). A guide page (four-section template is replaced for this folder by the playbook template below; `WRITING.md` gains a "Connect playbooks" section), ≤ 8 KB, public-safe, listed in `docs/guide/README.md`.
- Template: **What you get** · **Before you start** (accounts, admin rights) · **Steps** (numbered; each step names the page it happens on, what the customer does, what the agent may do, and the check that it worked) · **If something goes wrong** (per failure: what the customer sees, what to do) · a fenced `connect` block the parser reads: `service`, `domains` (allowed hosts), `tools` (the connect tools of §5.3 this playbook may call), `secrets` (kinds it may ask for).
- `internal/connectplay` parses and validates them (Go, a test over every file: block present, domains non-empty and HTTPS hosts, tools and secret kinds known). The help chat already sees them through the guide index (source `guide`).

### 5.2 The connect assistant

- A new embedded chat surface `connect` (`ChatSurfaceSpec`, memory persistence: a setup chat is not kept as a conversation). First-turn prompt = the connect system prompt (role, the injection rules of §6, the steps-in-words fallback) + the playbook text + the current state from `connect_status` (§5.3). The surface is per connector; reopening the panel during a run shows the live chat.
- Harness: the base harness from onboarding (the app's provider; onboarding does not let the customer past without one), switchable in the panel among the allowed ones (`AllowedAIProviders`). A harness without tool calling in embedded chats (Ollama today) does not get the button; the manual screens are its path.
- Browser on: Claude — `--chrome` added for this surface only (a new `ClaudeOptions.Chrome` field). Codex — the browser stays forced off until spike S3 shows a browser that drives the customer's own Chrome with an enforceable host list; today `browser_use` in `codex exec` only adds `web__run`, an unrestricted web access, so turning it on would widen what a page can reach without giving the agent Chrome. When S3 passes, the needed features come off the forced-off list for this surface only (a per-run override; the snapshot test pins both lists), and, if the bundled Chrome plugin is the way, `plugins` turn on for this surface only with `chrome@openai-bundled` as the one allowed plugin (P4, §12). Every other surface keeps the browser off.
- Tools: the connect tools (§5.3) of this playbook and the browser; no Bash, no file writes, no other Watchtower tools, no claude.ai connectors (`--strict-mcp-config`).
- Words-only mode when: the extension is not detected (spike S1 decides how: Claude's init event / a probe turn; Codex's feature state); or the customer picks **Guide me in words**. The panel says which mode it is in one line.

### 5.3 Connect tools — the agent presses our buttons

A small MCP server `watchtower connect mcp --service <svc>` (stdio, spawned by the chat with the surface) exposes tools that forward to the **Desktop**. The tower socket is the daemon's, and the Desktop is only its client, so the forwarding uses a **per-run socket the Desktop serves** (decided by the spec author): the Desktop opens a Unix socket in a 0700 directory for the length of one assistant run, hands its path to the MCP server through the child's environment, accepts only that one peer (same uid, the child's pid), and closes it when the run ends. JSON lines, one request/response per tool call. The Desktop runs each call on the same view models and flows the buttons use today, so locks, single-flow rules, policy and purge checks are unchanged.

**Owner gesture and limits** (decided by the spec author): the customer's **Start** in the panel covers the ordinary steps of that run. Steps that cannot be undone, or that add trust, need a confirm card in the panel that the customer presses: Slack adopt with PKCE (`--enable-pkce`), a bring-your-own Google client, a Quick Connection's `enable`. The model cannot press it. A run may make at most 5 `connect_start` calls and only one flow runs at a time, so an injected page cannot make the agent loop on sign-ins.

| Tool | Does | Returns |
|---|---|---|
| `connect_status` | accounts of the service, their status, policy lock, any running flow | JSON |
| `connect_start` | starts the service's sign-in (`add`/`login`/Slack `start`), with options from the playbook (Google scopes, Jira `--with-confluence`, site) | flow id; the sign-in page opens in the default browser |
| `connect_wait` | waits up to 60 s for the flow's end | `connected{account}` / `failed{reason}` / `waiting` |
| `connect_cancel` | cancels the running flow | — |
| `request_secret` | shows a secure field card in the panel (kind from the playbook's `secrets`, label from the agent ≤ 80 chars); the customer pastes; the Desktop passes it on stdin to the verb named by the kind (`slack_config_token` → `slack app create|adopt`, `imap_password` → `imap add`, `linear_api_key`, `caldav_password`, `ics_url`, `mcp_secret`, `google_client_secret`, `atlassian_client_secret` — a company client secret goes to the wizard draft, never through the model) | the verb's result, never the secret |
| `set_fields` | non-secret form values (IMAP host/port, CalDAV URL, Quick Connection command/URL, Jira site) for the next `connect_start`/`request_secret` | — |
| `choose` | Jira boards, Linear teams, Confluence spaces: list or select | JSON |

The agent never sees a secret: the agent brings the customer up to the button that reveals one (Slack's **Generate Token**), stops, and calls `request_secret`; the customer presses that button, copies the secret into the card, closes the page or dialog and presses **Send** (§10, "Pages that show a secret").

### 5.4 Company setup — the biggest win

The company setup wizard ([company-setup.md](../../features/company-setup.md), #1887) is the longest piece of explanation in the app: a company admin creates its own OAuth apps in Google Cloud, the Atlassian developer console, Microsoft Entra and Slack, guided by `CompanyVendorGuide` text. The agent does these console steps itself.

- **Connect with <harness>** sits beside **Set up for my company** (Connections → Companies zone, the **Connect…** menu, Jira's empty state) and beside **Use my own Google project**. It opens the panel on the `company` playbook set: the agent runs one vendor playbook after another, in the wizard's order.
- It drives the same `CompanySetupWizardModel` and its draft (`company draft save`), so the wizard sheet and the panel show one state. A customer can leave the panel and finish in the wizard, or the other way round.
- Extra tools for these playbooks: `company_draft` (read; save the non-secret fields and the client ids). Its read never returns a secret: the client secrets (and anything else `request_secret` stored) come back as `{"client_secret_set": true|false}`; test `company_draft` read on a draft holding both secrets, `company_check` (`company check <vendor>`; a Google or Atlassian check opens a sign-in the customer approves), `company_publish` (the Slack configuration token comes through `request_secret`).
- **Secrets here** (decision P2, ask #1716): the agent never reads a secret. The agent stops before the click that reveals a Google or Atlassian client secret or Slack's configuration token and calls `request_secret`; the customer makes that click, copies the secret and closes the dialog or page (§10, "Pages that show a secret") (kinds `google_client_secret`, `atlassian_client_secret`, `slack_config_token`); the Desktop saves it to the draft or passes it on stdin. Client ids are not secrets; the agent saves them with `company_draft`.
- Confirm cards (§5.3) also cover **Publish** (it writes the Slack app's About text to the whole company) and a **Replace** of a stored company.

### 5.5 Who clicks what in the browser

- The agent may navigate, fill non-secret fields and press buttons on the playbook's `domains` (e.g. api.slack.com "Create New App → From a manifest" with the manifest `slack app` prints, Google Cloud console for a bring-your-own client).
- The customer always does: sign-ins (passwords, 2FA) and the final **Allow** on an OAuth consent page — the agent tells them to and waits with `connect_wait`. (My call: vendor extensions block or warn on these pages anyway, and consent should be the customer's.)

## 6. Prompt injection and safety

- Domain allowlist per playbook. Enforcement: Claude in Chrome site permissions and Codex's browser settings are the vendor's; spike S2 finds what each lets us set per run. Whatever cannot be enforced is stated in the prompt ("leave any page outside these hosts and stop") and in §10 as a v1 limit.
- Page text is data: the system prompt says instructions found on a page are never followed; only the playbook and the customer give instructions.
- Every write goes through §5.3 tools on the Desktop, with today's checks (policy, purge, team mismatch, other user). An injected page can at worst start a sign-in the customer must approve.
- No secret in the model (§5.3). `request_secret` cards are not stored in the chat transcript; the value lives in memory until the verb exits.
- MDM: a policy that blocks a source hides **Connect**; `connect_start` refuses it again on the Desktop (two places, one rule: `PolicySourceMap`).

## 7. Screens

- **Connections overview**: a source card with no account gains **Connect with <harness>** (secondary button, sparkles icon) and today's **Connect** (quiet link) beside it; a connected card is unchanged and adds accounts through its detail's **Add account**. The Companies zone gets **Connect with <harness>** before **Set up for my company**; an attention banner offers **Reconnect with <harness>** beside **Reconnect**. One prominent button per screen: the agent buttons are secondary. The assistant panel opens on the right of the Connections tab (the `SetupAssistantPanel` slot, 380 pt). Shot `connect-overview-agent`.
- **Service detail panes**: unchanged (ask #1702); **Add account** gains the same **Connect with <harness>** item. Today's sheets and copy stay as the manual path, and the panel's **Set up by hand** opens them.
- **Onboarding** Connect step: each source offers **Connect with <harness>** first and today's flow second.
- **Assistant panel** states, each a `DesignShotCatalog` shot before review, all strings in the model (`ConnectAssistantPresentation`) with a test:
  - empty (just opened: "I'll connect Slack with you. Start?" + **Start**, **Guide me in words** (browser mode only), **Set up by hand**; mode line "Using Claude in Chrome" / "I'll tell you each step"),
  - loading (agent thinking / waiting for the customer in the browser: "Waiting for you to press Allow in Slack"),
  - error with **Retry** and **Set up by hand** (agent failed, provider quota, harness missing; a lost extension is not an error: the agent continues in words, §8),
  - busy (another connect running: "Slack is already connecting in another window" + **Open it**),
  - narrow scope (no browser for this harness: words mode only, e.g. Codex until S3 passes; a policy-blocked source or provider never opens the panel, §6),
  - secret card (field, **Send**, "goes straight to Watchtower, Claude doesn't see it"),
  - confirm card ("Turn on PKCE for the Slack app? This can't be undone", **Confirm** / **Cancel**),
  - done ("Slack is connected — 2 workspaces").
  - the confirm card carries "Only you can press this — <harness> can't."; the loading state has **Cancel**.

Mockups (light theme; dark renders from the same catalog): [overview](assets/2026-11-21-agent-connect/connect-overview-agent-light.png), [empty](assets/2026-11-21-agent-connect/connect-assistant-empty-light.png), [loading](assets/2026-11-21-agent-connect/connect-assistant-loading-light.png), [error](assets/2026-11-21-agent-connect/connect-assistant-error-light.png), [busy](assets/2026-11-21-agent-connect/connect-assistant-busy-light.png), [narrow](assets/2026-11-21-agent-connect/connect-assistant-narrow-light.png), [secret](assets/2026-11-21-agent-connect/connect-assistant-secret-light.png), [confirm](assets/2026-11-21-agent-connect/connect-assistant-confirm-light.png), [done](assets/2026-11-21-agent-connect/connect-assistant-done-light.png). The onboarding Connect step and a detail's **Add account** reuse the overview's button pair: [add account](assets/2026-11-21-agent-connect/connect-detail-add-account-light.png), [onboarding](assets/2026-11-21-agent-connect/connect-onboarding-step-light.png).

Shots (`make desktop-shots`, `DesignShotCatalog`): `connect-assistant-{empty,loading,error,busy,narrow,secret,confirm,done}`, `connect-overview-agent`; strings in `ConnectAssistantPresentation` with `ConnectAssistantPresentationTests`.

```
┌ Connect Slack ─────────────── Claude ▾ ┐
│ Using Claude in Chrome                 │
│ ─ I opened api.slack.com and created   │
│   the app from Watchtower's manifest.  │
│ ─ Copy the configuration token shown   │
│   on the page into the field below.    │
│ ┌ Slack configuration token ───────┐   │
│ │ ••••••••••••          [Send]     │   │
│ └ goes straight to Watchtower ─────┘   │
│ [ type a question…                   ] │
└────────────────────────────────────────┘
```

## 8. Failure paths and races

- **Panel closed / app quit mid-flow:** the chat stops; a running Desktop flow keeps today's behaviour (Slack waits for callback or **Cancel**; OAuth loopbacks time out). Reopening runs `connect_status` first and the playbook resumes from the state (e.g. Slack `pending_create` → adopt/clear step). Test per state.
- **Extension disconnects mid-run:** tool error → the agent switches to words mode for the remaining steps and says so. Test with a fake backend.
- **Provider quota / CLI missing:** error state with **Retry** and the provider picker; no automatic fallback mid-run (tool turns are not replay-safe).
- **Half-done vendor side** (Slack app created, token not pasted): the next run's `connect_status` + `slack app status` reports `pending_create`/`install`; the playbook's "If something goes wrong" covers each stage.
- **Writers of the same data:** the assistant, a manual Reconnect from an attention banner, onboarding, the daemon's token refresh. The sign-ins all go through the same Desktop flows (the Slack `Registry`: one flow, `busy`; the accounts view models), so the first start wins and a second gets `busy` (the panel shows the busy state). The daemon is not a client of those flows: it refreshes tokens through `slackauth.LoadFresh` under the per-account token flock, and every Slack token write of a sign-in takes the same flock (`withSlackTokenLock`, guarded by `TestSlackTokenWriters_AllLocked`), so a refresh and a new sign-in serialise and the later write wins with the newer grant. The other services keep their existing per-account write paths; the assistant adds no new writer. Tests: two `connect_start` calls → second `busy`; a refresh racing an assistant Slack sign-in leaves the sign-in's token.

## 9. Verification

- Go: `internal/connectplay` (every playbook parses; domains/tools/secrets valid), connect MCP server (tools forward, secret kinds map to verbs, policy refusal), `ClaudeOptions.Chrome` argv golden, Codex per-run feature override (snapshot of both lists).
- Swift: `ConnectAssistantPresentation` strings; the per-run socket's handlers (§5.3) on fake view models; the secret card never enters the transcript; a confirm card cannot be answered by any tool call (only the panel button resolves it); the sixth `connect_start` in a run is refused; the socket refuses a second peer and closes at run end; every state shot.
- Live matrix (manual, recorded in the plan's last task): each of the 14 playbooks × {Claude + extension, Claude words only, Codex words only}, plus Codex + browser once S3 passes.

## 10. v1 limits and open spikes

The spikes run first (plan Task 0) and their answers are written into this section before the browser tasks start.

- **S1** — detect "extension available": Claude in Chrome connection state and Codex browser readiness, before the first turn. Fallback: try, and on the first browser-tool error switch to words.
- **S2** — per-run domain allowlist for each vendor browser. What can't be enforced stays a prompt rule (stated in the panel's help text).
- **S3 — checked 2026-11-21.** Claude: `claude -p --chrome` (our non-interactive mode) exposes the full Claude in Chrome tool set (`mcp__claude-in-chrome__*`), driving the customer's own Chrome. Still to confirm with our exact argv (`--strict-mcp-config`, `--tools`). Codex: `codex exec` with `browser_use` and `browser_use_external` enabled shows only `web__run`, a separate web access with no Chrome and no logins. OpenAI documents the Chrome extension for the Codex desktop app, not the CLI ([Codex Browser](https://developers.openai.com/codex/app/browser)). Community reports say CLI 0.163+ can drive it through the bundled `chrome@openai-bundled` plugin once the native host is set up ([openai/codex#22164](https://github.com/openai/codex/issues/22164), [#26820](https://github.com/openai/codex/issues/26820)). Task 0 tries the bundled plugin through `codex exec` and the app-server. Until one of them works on a clean install, Codex runs the same playbooks in words mode, and the panel says so in its mode line.
- **Pages that show a secret.** The vendor extensions read whole pages and offer no per-element redaction, so what keeps a secret out of the model is the flow, made as tight as the extensions allow:
  - The click that reveals a secret is the customer's: Google's **Create** on the OAuth client form (its result dialog shows the secret), Atlassian's **Settings** page of the app, Slack's **Generate Token**. The playbook marks these steps "customer only", like **Allow** (§5.5); the agent fills the form up to that button and calls `request_secret`.
  - `request_secret` blocks the agent until the customer presses **Send**, and its card asks the customer to close the dialog or leave the page first ("Close Google's dialog, then Send"). The tool returns only after that, so the agent's next browser action starts on a page without the secret.
  - The playbook test (`internal/connectplay`) fails a playbook whose agent steps name a secret-revealing page, using a per-vendor list of such pages.
  - What remains: an agent that ignores the playbook and reads such a page while the customer has it open. That cannot be blocked with the vendors' extensions (the owner's choice, #1698). It is a v1 limit, named in the panel's help text.
- Slack Live has no automatic step: turning on the vendor's Slack connector is in the vendor's app, so its playbook is words only plus `slack live probe`.

## 11. Left to the builder

The tower command shapes, the MCP server's process lifecycle, how the panel hosts the chat (reuse `SetupAssistantPanel`), playbook wording within the template.

## 12. Decisions

**From the owner**
- #1697: without the extension the agent guides in words; every connector in one delivery; Claude and Codex as equals.
- #1698: the vendors' own browser extensions (no bridge, no extension of ours).
- #1702: another path beside today's screens, not a replacement; the assistant runs on the base harness set up in onboarding; the extension may be missing. "The browser is surely there for both — check": checked (§10 S3) — Claude yes; Codex not from the CLI today.

**From the owner, ask #1716**
- P1: Codex ships in words mode, Claude with the browser; Codex's browser turns on when S3 passes.
- P2: company OAuth client secrets are pasted by the customer through `request_secret`; the agent sees no secret at all.
- P3: the company setup wizard is in this delivery (§5.4).
- P4: if Codex's Chrome needs the bundled plugin, Codex `plugins` are turned on for the connect surface only, with `chrome@openai-bundled` as the only allowed plugin.

**By the spec author** (open to the owner's veto)
- A1. Per-run Desktop socket as the agent → app channel (§5.3).
- A2. Confirm cards for steps that cannot be undone or that add trust (PKCE, own Google client, Quick Connection enable, Publish, Replace); at most 5 `connect_start` per run (§5.3, §5.4).
- A3. The customer does sign-ins, 2FA and the final **Allow** (§5.5).
- A4. A harness without tool calling in embedded chats (Ollama) gets no button; the assistant chat is not kept as a conversation (§5.2).
- A5. Codex's browser stays off until S3 passes (§5.2).
