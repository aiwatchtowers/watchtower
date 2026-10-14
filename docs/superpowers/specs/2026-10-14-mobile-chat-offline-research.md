# Research: the phone's AI chat while the Mac sleeps (board #52)

Date: 2026-10-14. Status: research only, no decision taken. Earlier tracking: #428 ("chat without the Mac", parked by the mobile POC design §1 and §12).

## 1. The problem

Every AI answer in Watchtower today comes from the Mac. The main chat runs `watchtower ai session`, which wraps the owner's own `claude` CLI (or `codex exec`, or an Ollama HTTP server) behind protocol v2 and gives it the Watchtower MCP tools over the full SQLite DB (`docs/features/chat-redesign.md`, `docs/features/model-provider-registry.md`). The phone has no model and no credentials. It sees only what the hub publishes to DataZone, sealed end to end and mirrored into the phone's `ReplicaStore` (`docs/features/mobile-companion.md`). When the Mac sleeps, the heartbeat goes stale after 35 min and the phone can only queue actions.

The owner asked whether "some long-lived token" could let the phone talk to the model directly. This note covers that and four other ways in.

**What the phone already holds.** These replica kinds are readable offline:
- workbenches, targets, comments, terminal sessions;
- owner asks and ask alerts;
- session reports and timelines;
- calendar events;
- meeting transcripts (as segment assets);
- recording jobs;
- the device grant.

The phone does **not** hold Slack, Gmail, Jira, digests, people, memory, the knowledge index, Catch-Up or the briefing. Offline, any phone-side model can answer only about workbenches, asks, sessions, the calendar and transcripts, unless the hub publishes more.

**Prior art.** The never-merged `mobile-app` branch has a working BYOK path, parked by POC design §12:
- `WatchtowerKit/.../Agent/DirectAPIAgent.swift`: an SSE client for the Messages API, serialized per session.
- `ReplicaToolbox.swift`: an MCP-v1 tool mirror over replica rows; its writes go through `ActionOutbox`.
- `MobileAgentBackend.swift`: a relay-or-direct seam that the user opts into, with no silent switching.
- `WatchtowerMobile/.../APIKeyStore.swift`: a Keychain item with `AfterFirstUnlock` access.
- `ChatPayloads`/`ChatAssembler`: a chat relay over CloudKit.

That code predates the replica-v2 kinds and E2E. It is a design reference, not something to port as is.

## 2. Options

| # | Option | How it works | What it can answer | Cost to owner | Privacy / E2E impact | ToS / App Store risk | Effort |
|---|---|---|---|---|---|---|---|
| A | **BYOK Anthropic API key on the phone** | The owner pastes a Console API key. It is stored in the Keychain as `ThisDeviceOnly` and never synced. The phone calls `POST /v1/messages` with SSE streaming and runs its own tool loop over the replica. | Replica kinds only (§1), plus queued writes through `ActionOutbox`. Optional server tools (web search/fetch). | Pay per token. A typical turn (~10K in, ~0.8K out) costs about $0.001 on Haiku 5.5, $0.03 on Sonnet 5.5 and $0.06 on Opus 5.5, before caching. A Console spend limit caps it. | Decrypted replica content goes to Anthropic. That is the same party that already sees the Mac chat through `claude`, so there is no new third party. Apple still sees only ciphertext. | **Low.** Anthropic explicitly allows customers to use their own API keys. App Review 5.1.2(i) requires disclosing that data goes to a third-party AI and getting explicit consent; that is a consent screen. | **M.** Reuse the design of the parked `DirectAPIAgent`/`ReplicaToolbox`. Rewrite the tools for the v2 kinds and the E2E replica. |
| B | **Subscription "long-lived token"** (`claude setup-token` / `CLAUDE_CODE_OAUTH_TOKEN`, or the Mac's claude.ai OAuth credential copied to the phone) | The Mac mints a one-year OAuth token. The phone sends it as a bearer to the API, with no Claude Code binary involved. | Same as A. | "Free" against the Pro/Max plan. | Same as A. | **High, not allowed.** Anthropic: OAuth is "intended exclusively" for Claude Code and native Anthropic apps. It "does not permit third-party developers to offer Claude.ai login … or to route requests through Free, Pro, or Max plan credentials". Developers "may not collect, store, or intermediate Claude.ai credentials or session tokens". Enforcement can come "without prior notice". `setup-token` is documented for CI and scripts that run Claude Code. A phone that calls the API with it is exactly the pattern Anthropic enforced against in 2026. | S technically. **Rejected.** |
| B′ | **OpenAI "Sign in with ChatGPT", plan usage** (the Codex equivalent) | OAuth with PKCE and a dynamic client, then the Responses API billed to the user's ChatGPT plan. | Same as A. | Against the ChatGPT plan. | Content goes to OpenAI. | **Medium-high today.** The plan-usage capability is an official preview "for open-source and locally hosted apps". Its sign-in allows only a loopback `127.0.0.1` redirect, and there is no mobile path. A client ID for anything else is "offered to a select group of commercial partners" through a waitlist. An OpenAI API key (BYOK, as in A) is fine. | M, if OpenAI opens a mobile path. Watch only. |
| C | **Apple Foundation Models: on-device model** (iOS 26+) | `LanguageModelSession(model: SystemLanguageModel())` with custom `Tool`s over the replica. | Short questions over a few replica rows. Context is 4K (8K on the newer model). It is weak at multi-step work. | Free. | Nothing leaves the phone. **Best fit with E2E.** | None (Apple framework). | **M.** iOS 26 and an Apple Intelligence device (iPhone 15 Pro or newer) are required. The app targets iOS 17, so this needs an availability gate. |
| C′ | **Apple Private Cloud Compute model** (iOS 27+) | `PrivateCloudComputeLanguageModel()`, same session API, 32K context, reasoning levels, the same tools. | Real multi-turn chat over the replica. Weaker than Claude on hard reasoning. | Free to the owner up to a per-user daily quota, with more under iCloud+. No API cost to the developer below 2M first-time downloads. | Leaves the phone only for PCC: Apple says prompts are not stored, and researchers can verify that. A different trust model from the CloudKit E2E, but no API keys and no new vendor. | Needs a managed entitlement with eligibility requirements, which we have not checked yet. Online only. | **M.** Shares the code of C. Gated on iOS 27. |
| A′ | **A and C through one protocol** (`LanguageModel`) | Anthropic's `ClaudeForFoundationModels` package (Apache-2.0, beta, OS 27) makes Claude a `LanguageModel`. Tools and transcript are shared, so swapping the model is one line. Its `.appAttest` mode bills the *developer's* workspace and does not fit BYOK. Its `.apiKey` mode is labelled dev-only because a *bundled* key is extractable. A key the user enters into the Keychain is a different case. | As A, C or C′. | As the chosen backend. | As the chosen backend. | As A or C. | **M.** iOS 27 only, so it does not help an iOS 17/26 phone. |
| D | **Hybrid: queue for the Mac** | The question goes out as a new relay `action` (`chat_question`). The hub answers when it wakes, the answer comes back as a DataZone record, and an alert announces it (the `ask_alert` path). | **Everything** (full DB, all tools, the owner's subscription), but late. | None beyond today's. | Unchanged. Sealed like every relay record. | None. | **S–M.** Revives the `ChatPayloads` seam as a closed action kind, plus an "answered while you were away" thread. |
| E | **Keep the Mac reachable** | The hub stays awake. On a power adapter: "Prevent automatic sleeping when the display is off". Or use an always-on Mac mini as the hub. Then the phone relays chat live (D without the delay). | Everything, live. | Electricity. | Unchanged. | None. | **S** (settings) plus the relay chat from D. |

**Waking the Mac from the phone is not a real option.** It would mean CloudKit push, Wake for network access, Power Nap or Wake-on-LAN. Here is why each fails:
- **Power Nap** refreshes Mail, Calendar and iCloud data while asleep. It does not run third-party apps, and third-party guides report it is gone on Apple silicon.
- **Wake on Demand** depends on a Bonjour Sleep Proxy on the same LAN and on Bonjour-advertised services. A network wake lands in "darkwake" and falls back asleep within a minute.
- **APNs** has no way to wake a sleeping Mac app.

So option D is honest only as **"answered when the Mac next wakes"**. It cannot promise "the phone woke the Mac".

**iOS runtime notes for A/C/C′.** `URLSession.bytes(for:)` handles SSE. A stream survives a short trip to the background inside `beginBackgroundTask` (about 30 s). A turn the user leaves mid-stream should fail cleanly, as the parked `DirectAPIAgent` already does (`streamEndedPrematurely`). No replica write transaction may stay open across that await (the 0xdead10cc rule in the mobile doc).

## 3. Recommendation

Build a tiered chat, with one chat view and one tool set over the replica:

1. **Mac online → relay to the Mac (D/E).** This is the full assistant, the owner's subscription and every tool. Watchtower stays the "unmodified Claude Code" product the terms allow. It is the only path that sees Slack, Jira and memory.
2. **Mac offline → a phone-local agent over the replica, which the owner opts into:**
   - **BYOK Anthropic API key (A)** first. It works on today's iOS 17 target, costs pennies per turn, and sends data to no new third party.
   - **Apple on-device/PCC (C/C′)** as the zero-setup fallback on capable phones.
   - Writes stay *proposals* queued in `ActionOutbox` until the Mac applies them.
3. **A question the replica can't answer → "Ask my Mac when it wakes" (D).** The answer comes back as an alert.

**Do not ship a subscription token on the phone (B).** Anthropic's current terms forbid it for third-party apps and enforce it without notice. OpenAI's plan-usage sign-in has no mobile path yet.

So the "long-lived token" the owner had in mind is, in practice, **a Console API key the owner creates**. It is long-lived, revocable and spend-capped, and it is billed per token, not to the Max plan.

### Open decisions for the owner

1. **Offline engine first: BYOK key (A) or Apple PCC (C′)?**
   - A works now and gives Claude's quality, but adds a per-token bill and an API-key setup screen.
   - C′ is free and zero-setup, but needs iOS 27, an eligible device and the PCC entitlement, and its model is weaker.
   - Doing both behind one protocol pushes the phone's minimum to iOS 27 for the shared code path.
2. **How much more should the hub publish to the replica for offline chat?** For example a trimmed people list, today's briefing or digest headlines, open Jira tracks or a memory digest. Each slice costs CloudKit volume and battery (board #724), adds E2E surface on a lost phone, and needs a projection. Without them, the offline chat is "workbench + calendar + transcripts" only.
3. **Offline writes and the Mac queue.**
   - May the offline agent propose writes (board edits, ask answers) that the Mac applies later, or is it read-only?
   - Is the "ask my Mac when it wakes" queue (D) in scope?
   - Should Settings → Mobile on the Mac also offer "keep this Mac awake while plugged in" (E)?

## 4. Sources (all accessed 2026-10-14)

- Anthropic, Claude Code "Legal and compliance": authentication and credential use, OAuth exclusivity, the third-party ban, own-API-key carve-out. https://code.claude.com/docs/en/legal-and-compliance
- Anthropic, Claude Code "Authentication": `claude setup-token` (one-year OAuth token for CI/scripts, Pro/Max/Team/Enterprise, model requests only), credential precedence. https://code.claude.com/docs/en/authentication
- Anthropic, Agent SDK overview: "Anthropic does not allow third party developers to offer claude.ai login or rate limits for their products". https://code.claude.com/docs/en/agent-sdk/overview
- Anthropic, API pricing (Haiku 5.5, Sonnet 5.5, Opus 5.5 per-MTok rates, caching). https://platform.claude.com/docs/en/about-claude/pricing
- Anthropic, `ClaudeForFoundationModels` README (auth modes `.appAttest`/`.apiKey`/`.proxied`, OS 27 beta). https://github.com/anthropics/ClaudeForFoundationModels
- OpenAI, Codex authentication (ChatGPT sign-in vs API key; API keys recommended for automation). https://learn.chatgpt.com/docs/auth
- OpenAI, Sign in with ChatGPT, ChatGPT plan usage (open-source/locally hosted apps; paid or remote apps via interest form). https://developers.openai.com/siwc/token-sharing-open-source
- OpenAI, SIWC registration and sign-in (loopback `127.0.0.1` redirect, PKCE, dynamic client). https://developers.openai.com/siwc/token-sharing-open-source/sign-in
- OpenAI, SIWC preview limitations. https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations
- OpenAI, Request a client ID ("a select group of commercial partners"). https://developers.openai.com/siwc/request-client-id
- Apple, WWDC26 "What's new in the Foundation Models framework" (on-device model, PCC 32K context, free under 2M downloads, `LanguageModel` protocol, Anthropic and Google packages). https://developer.apple.com/videos/play/wwdc2026/241
- Apple, "Adding server-side intelligence with Private Cloud Compute" (4K vs 32K, daily quota, iOS 27, entitlement). https://developer.apple.com/tutorials/data/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute.md
- Apple, App Review Guidelines 5.1.2(i) (disclosure and consent for sharing with third-party AI), 5.2.2. https://developer.apple.com/app-store/review/guidelines/
- Apple, Mac User Guide, Power Nap (French edition; what runs during sleep). https://support.apple.com/fr-ci/guide/mac-help/mh40774/mac
- Apple (archived), "About Wake on Demand and Bonjour Sleep Proxy" HT201960. https://nrs.preservation.mirrorweb.com/public/20170610164455mp_/https://support.apple.com/el-gr/HT201960
- Apple Developer Forums, "Sleep, darkwake and Wake on Lan (macos)" (anecdotal darkwake behaviour). https://developer.apple.com/forums/thread/771999
- Secondary (not authoritative): iBoysoft on Power Nap and Apple silicon. https://iboysoft.com/wiki/power-nap-mac.html
