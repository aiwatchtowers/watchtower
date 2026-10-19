# Agent analytics v2 — insights that change something (#709 proposal)

Status: proposal for the owner's decision: rebuild the feature around the insights below, or remove it. Supersedes the polish in `2026-10-18-agent-analytics-actionable-design.md`, whose pieces (hint actions and fixes, assistant-language sentences, capped evidence, touched tasks only) carry over.

## Why the current report is shallow

It answers "how much time and money went where" — the same thing `ccusage`, Claude Code's `/usage` (cost, cache hits, per-skill and per-MCP attribution on subscription plans) and `/cost` already answer. Its hints say what happened, not what to change. Nothing in it is specific to this folder's setup (its CLAUDE.md, its skills, its hooks, its commands), which is the only thing the owner can actually change.

## What others offer (research, 2026-10-18)

| Product | What it gives | Gap |
|---|---|---|
| Claude Code `/context` | live split of the current context by category | one session, now; no history, no trend |
| Claude Code `/usage`, `/cost` | cost, cache hit share, misses with a likely cause | accounting, not behaviour |
| Claude Code `/insights` | LLM report over past sessions: friction types (wrong approach, buggy code, rejected action …), CLAUDE.md suggestions | global, opaque, costs tokens, not per folder |
| OpenTelemetry export | `tool_result` (error type, size), `tool_decision` (reject/abort), `skill_activated` | raw signals; needs a collector and dashboards |
| ccusage, Usage Monitor | tokens, 5-hour blocks, burn rate | accounting only |
| token-dashboard, claude-usage-analyzer, unclog | biggest tool results, repeated reads, oversized output, unused MCP servers, long sessions | closest to the need; partial, CLI/web, no fixes wired in |
| LangSmith, Langfuse, Phoenix | traces of apps you instrument | not for Claude Code sessions |
| Cursor/Copilot/Jellyfish dashboards | team adoption, acceptance rate | team ROI, nothing per session |

Nobody combines the folder's own setup with its sessions' history and ties each finding to a fix the app can apply. That is the gap v2 fills.

## What the transcripts make possible (verified on this repo's transcripts)

Claude Code transcripts carry far more than the parser stores today:

- **Context baseline.** `attachment` records with a `rendered` size for each piece injected at session start: `instructions` (CLAUDE.md and rules), `skill_listing` (with the skill names), agent, MCP and deferred-tool listings; newer files add `api-request-shape` with the system prompt and tool schemas actually sent. The first call's usage gives the total.
- **Context growth.** Per-call usage (input, cache creation, cache read, output, thinking tokens) plus each tool result's size (`toolUseResult`: Bash `persistedOutputSize`, Read `numLines`/`totalLines`, spilled `tool-results/` files) lets each jump in context be attributed to the tool call, file or command that caused it.
- **Compactions.** `compact_boundary` with trigger, tokens before and after.
- **Skills.** The listing (`names[]`) per session vs `Skill` tool calls and `attributionSkill` on assistant messages (cost per skill).
- **Trouble.** `is_error` with the result text (classifiable without storing it), `permissionDecision` / `toolDenialKind`, owner interrupts and rejections, API error status (429), Stop-hook blocks, subagent `meta.json` `finished` flags, `bashEditDiff` (edits made through the shell).

What the parser stores today: per-call tokens and cost, tool name + target + coarse outcome + duration, skill calls, owner turns, bare compactions. It drops result sizes, thinking tokens, the baseline attachments, the skill listing, compaction sizes, denials, interrupts, hook blocks and subagent meta. Older rows (parser v2) stay without the new facts and are marked so; Claude Code keeps about 30 days of transcripts, so a reparse covers that window.

## v2: four blocks, each ending in a fix

### 1. Context — what fills the window

- **Session start costs N tokens before you type**: tool schemas / CLAUDE.md and rules / skill listing / system prompt / other, as a bar, with the 30-day trend. Next to it the current sizes on disk (CLAUDE.md lines, skill descriptions). Fixes: "CLAUDE.md is N% of every start — move feature notes out" (opens the file), "subagents start with CLAUDE.md as most of their context".
- **What grows it**: share of context growth by tool, then the top commands and files: Bash outputs, files re-read in one session, oversized reads. Fixes: pipe through `head`/`grep`, a PostToolUse hook that trims output, read with offset/limit, move the sweep into a subagent.
- **Compactions**: how often, at what size, what came right before (the call that pushed it over), files re-read after.

### 2. Skills — used, unused, what they cost

- Listed vs invoked over the period; **never used** skills with the tokens their listing adds to every session; per-skill invocations and cost (`attributionSkill`); skills invoked only by the owner by slash vs proactively by the agent.
- Fixes: disable or delete an unused skill, rewrite its description (one that is never triggered), open the skill file.

### 3. Trouble — where the agent gets stuck

- Error classes by count with a fix each: permission denials → **Copy allow rules**; worktree-isolation blocks and sleep blocks → a line for the folder rules; unknown agent type / no such tool → the skill or agent definition that names it; Read too large → offset/limit rule; Edit "string not found" streaks; shell exit-code loops (H1/H5 today).
- Owner interrupts and rejections per session, with the session to open; subagents that never finished; API 429s.
- Repeated work: the same file read many times, the same test run with no edit in between.

### 4. Money — one line

Period cost and cache hit share, linking to Claude Code's own `/usage` for the rest. The time split and the tasks table move to a collapsed "Time" section (or go).

Every block shows only what fired; an empty block says "nothing to fix". The current hint machinery (ranked findings with an estimate, `action`, `fix`) is reused, with new rules on the new facts.

## Work

1. **Parser v3 + storage** (`internal/agentlog`, `agentlog.db` migration): result size and thinking tokens on events; a `agent_log_baseline` table (session, part, bytes); a `agent_log_skill_listing` table; compaction before/after; a richer `error_class` enum (incl. denial kinds, 429, worktree/sleep blocks, edit-not-found); owner interrupts; subagent `finished`/depth; `bashEditDiff` lines. Reparse via `ParserVersion` 3. Sizes and enums only — no transcript text (AGENTLOG-01).
2. **Report v2** (`internal/agentreport`): baseline, growth attribution, compactions, skills, trouble rules, each with `action`/`fix`; disk sizes of CLAUDE.md and skills read at report time.
3. **Pane v2** (Desktop): the four blocks, the main-thing card, English labels, sentences in the assistant language.
4. Docs and guide page.

Roughly: 1 is a day, 2 two days, 3 two days, with reviews.

## Decision for the owner

- **Rebuild as v2** (recommended): the insights above are specific to the folder, exact where they come from transcripts, rare in other tools and each ends in a change the owner can make.
- **Remove the feature**: drop the pane, the daemon phase and `agentlog.db` import; keep nothing.
