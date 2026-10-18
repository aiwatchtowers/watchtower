# Agent analytics — history analytics (#298) — design

Board: #296 (initiative), #298 (this sub-project). It builds on the ingest core
(#297, `docs/features/agent-analytics.md`, spec
`2026-10-15-agent-analytics-core-design.md`, contracts AGENTLOG-01..05).

## Intent

The owner turns analytics on for a workbench and sees **why agent work is slow and
expensive**, so they can change how they and their agents work. In the owner's words
(2026-10-16), the questions are: how to cut token usage, **above all how to speed
things up**, what agents spend their time on, and how well agents work in parallel.

### Decisions taken with the owner (ask #200)

| Question | Decision |
|---|---|
| What "slow" is measured on | **Both levels**: one agent session (start to end) and one board task (`in_progress` → `done`). |
| What "parallel" means | **Subagents inside one session**: how many really ran at once, how many ran one after another. Several sessions in one folder and machine load are not in scope. |
| Numbers only, or hints too | **Numbers plus rule-based hints** (no LLM; the LLM judge is #300). |
| Where | **A pane in the workbench window**, next to Board and Files. |

Earlier decisions still hold: any user, not only the owner (#151); metrics plus a
pointer into the JSONL, never text (#152); every session of the folder (#152);
no extra complexity — machinery only where skipping it gives silently wrong numbers
(owner rule, 2026-10-15).

### What a first look at real data showed (2026-10-16, this repo)

These findings shape the design. They are qualitative on purpose: no figures from a live install are kept in the repo.

1. **Waiting for background agents looks exactly like waiting for the owner.** In
   both cases the main agent ends its turn and the next record is a "user" record.
   Time spent on background agents was about as large as time spent on owner
   replies, plus long breaks. The core counts a `<task-notification>` as an
   `owner_turn` today, so `owner_turns` is already inflated.
2. **Shell commands are recorded as `cd`.** `shellTarget` stops at the first
   `&&`/`;`/`|`, and most agent commands start with `cd <dir> &&`. With `cd` skipped,
   the biggest time sinks become visible: `make test`, `make test-swift`, `gh pr`,
   `go test`, `scripts/dev-health.sh`, the first of them by far the longest per run.
3. **Cheap commands are slow on average** (`cat`, `git status` averaged several
   seconds). Tool time includes the time the owner takes to answer a permission
   prompt, and the transcript does not say how much of it was the prompt.
4. **Subagents almost never run in parallel.** Average parallelism was barely above
   one, every Agent call was alone in its message, and most ran in the foreground.

## Goals

- A **time breakdown** for a session and for a period: where the wall-clock went.
- A **task view**: per board target, how long it took, in which phases, and which
  sessions, agent time and cost went into it.
- A **subagent view**: per session, how parallel its subagents were and how long the
  main agent sat blocked on foreground subagents.
- **Token and cost breakdown** good enough to see what to cut: by model, main agent
  vs subagents, cache behaviour, the most expensive sessions and tasks.
- **Rule-based hints**, each with its evidence and an estimate of the time or money
  at stake, ranked by that estimate.
- A **session timeline**: the main agent and each subagent as lanes, coloured by
  time category.
- Turning analytics on from the Desktop (today it is CLI-only).

## Non-goals

- Several sessions running in one folder at once, machine load, worktree conflicts.
- Codex sessions (the core's Codex step is still pending; the views must not break
  when Codex rows arrive later, nothing more).
- LLM-written advice, OTel, verbose capture (#300). Skill evals (#299).
- Separating permission-prompt time from tool time exactly (needs hooks — #300).
  v1 only flags it (hint H2).
- A cross-workbench summary in the Usage tab.

## Anti-goals (would make it a failure even if it works)

- **Blaming the owner for agent waits.** Time spent waiting for background agents
  must never show as "waiting for you".
- **Numbers that silently double.** Every time category sums to the session's wall
  time exactly once; every API call counts once (AGENTLOG-02).
- **Advice without evidence.** Every hint names the sessions, commands or targets it
  is based on and links to them.
- Any transcript text in the database or on screen beyond what AGENTLOG-01 allows.

## Part A — core fixes (Go, `internal/agentlog`)

These fix numbers that are wrong today. They bump `ParserVersion` (1 → 2), so the
next scan reparses every file from 0 (the core already does this; idempotent keys mean
no duplicate rows). The full local store reparses in seconds.

1. **Shell verb.** `shellTarget` takes the first *real* command of the line: it skips
   leading env assignments, `cd …`, `pushd …`, `export …`, `set …`, wrappers
   `timeout <n>`, `env`, `time`, `nice`, and moves past `&&`, `;`, `||`, newline to the
   next command until it finds one. A pipeline's first command still wins (`go test …
   | tail` → `go test`). The output shape is unchanged — program plus a subcommand for
   the listed programs — so AGENTLOG-01 still holds. Add `bash`/`sh` with a script
   argument as `bash <script base name>` (e.g. `bash dev-health.sh`) — the script's
   file name, never its path or other arguments.
2. **Owner turns vs other "user" records.** A user record whose text starts with
   `<task-notification>` is a **notification** (a background agent finished); a
   record injected by a hook (Stop-hook feedback, `<system-reminder>`-only content —
   the builder pins the exact markers from real transcripts with a fixture) is a
   **hook** record. Both are stored as `owner_turn` with `trigger` =
   `notification` / `hook`; a real owner prompt gets `trigger = 'owner'`. `owner_turns`
   in `agents stats` counts only `owner`. (Reusing `trigger` avoids recreating the
   events table to widen the `kind` CHECK.)
3. **Agent calls.** For an `Agent`/`Task` tool event, store `target` =
   `subagent_type` (or `general-purpose` when absent), and two new columns:
   `spawned_agent_id` (from the tool result's `toolUseResult.agentId`, linking to the
   subagent's `agent_id`) and `background` (0/1 from `run_in_background`). One
   migration adds both columns; mirror it as the migration skill says.
4. **Which board targets a conversation worked on.** For calls of the
   `watchtower-workbench` MCP tools that name a target (`update_target`,
   `add_comment`, `ask_owner`, `create_targets` with `parent_id`, `get_target`,
   `list_comments`, `finish_session`), store `target` = `#<id>` — the board id only.
   This is the conversation → target link the task view uses. *(Builder-check call:
   `terminal_sessions.claude_session_id` keeps only the latest conversation of a
   terminal, losing earlier ones after `/clear` or resume, and sessions started
   outside the Desktop terminal have no link at all. A target id is not transcript
   text, so AGENTLOG-01 holds; its guard fixture gains such a call.)*
5. **Rows from transcripts that are already gone.** Events whose file is `missing_at`
   with a `parser_version` below 2 cannot be reparsed. Such sessions keep their tokens
   and cost, but are left out of the time model, parallelism and hints and are
   marked `old_format` in the report (the pane shows "older sessions — time not
   analysed: N"). *(Builder-check call: the v1 scan ran on 2026-10-15, so this is a
   small set.)*

## Part B — the time model (Go, one implementation)

Everything the pane shows is computed in Go and handed to the Desktop as JSON (the
session report precedent: Go owns the report, Swift only decodes). There is no Swift
twin of any rule, so there is no dual path to keep in step.

### Session wall time, split into categories

Walk the **main agent's** events (`agent_id = ''`) of a session in `ts` order. Each gap
between two consecutive events belongs to exactly one category, decided by what was
happening at the start of the gap:

| Category | When |
|---|---|
| **Tools** — by class | A tool call is open (from its `tool` event to its result). Classes: *build & test* (`go test`, `go build`, `make *`, `swift build/test`, `npm test/run`, `xcodebuild`), *git & GitHub* (`git *`, `gh *`), *read & search* (Read, Grep, Glob, `cat`, `ls`, `grep`, `rg`, `find`, `sed`, `head`, `tail`), *edit* (Edit, Write, MultiEdit, NotebookEdit), *MCP* (`mcp__*`), *foreground subagents* (Agent/Task with `background = 0`), *other*. |
| **Model** | The agent is producing output: after an owner turn, a notification, a hook record or a tool result, until its next event. |
| **Waiting for background agents** | The turn ended, and a background subagent of this session is running (its span is open) — however long. |
| **Waiting for you** | The turn ended, no background subagent is running, up to the first 30 min of the wait. |
| **Away** | The part of such a wait past 30 min. Shown, but left out of "active time". |

"The turn ended" = the gap follows an `api_call` and is followed by an owner turn of
any trigger. A wait is cut at the moments background spans open and close, so a wait
that is partly covered by a running background subagent is split: the covered part
is *background*, the rest is *you* (then *away* past 30 min of uncovered waiting).
This keeps background waits out of "waiting for you" even when the owner writes
before the notification arrives (anti-goal 1). *(Builder-check call: the rule uses
subagent spans, which the core already stores, instead of pairing notifications.)*
Overlapping tool calls (several tool uses in one message) are counted once: while
any tool is open the gap goes to the class of the earliest-started open tool.
The categories add up to the session's wall time, start to end. A guard test
asserts it on a fixture with every category.

Tool time still includes permission prompts (finding 3); the pane says so in the
breakdown's footnote, and hint H2 flags where it probably matters.

### Subagent parallelism (per session)

From the subagent events: a subagent's span = first to last `ts` of its `agent_id`.

- **Subagent time** = sum of the spans; **wall time with subagents** = the union of
  the spans; **average parallelism** = the first divided by the second;
  **peak** = the most spans open at one moment.
- **Main agent blocked on subagents** = the *foreground subagents* tool time above.
- **Run one after another** = foreground subagent calls in the session whose spans do
  not overlap any other subagent's span.

### Tasks (board targets)

For each target of the workbench (leaves; a group sums its leaves):

- **Calendar time**: from the first `in_progress` to the last `done` in
  `target_status_history`, split into the time spent in each status (`in_progress`,
  `in_review`, `blocked`, back to `todo`). An open target counts to now.
- **Sessions**: the agent sessions that called a workbench tool naming this target or
  one of its sub-targets (Part A.4).
- **Agent time and cost** for the target: the categories and costs of those sessions
  that fall inside the target's `in_progress`/`in_review` windows. A target with no
  such window (moved straight to `done`), or whose session's calls on it lie outside
  every window, uses the span from that session's first to last call naming it
  instead. `done` and `dismissed` both close a window. *(Builder-check call.)* When one session
  has several targets open in the same window (an SDD controller with parallel
  lanes), that stretch is **split equally** between them and the row is marked
  "shared". This is the one approximation in the model, and the pane labels it.

### Tokens and cost

From the existing `api_call` events: cost and tokens by model, main agent vs
subagents (by model too), the cache read share (`cache_read / all input`), cache
writes, compactions per session, the top sessions and tasks by cost. Cost is
`cost_usd` as stored; calls with `cost_estimated = 1` are counted and shown.

### Hints (rule-based)

Each hint has an id, a one-line finding, the evidence (sessions, targets, commands
with counts and time) and an **estimate** in time or money; the list is ranked by
the estimate. Thresholds are named constants in one file, so they can be tuned
without touching the rules.

| Id | Fires when | Estimate |
|---|---|---|
| H1 Repeated heavy command | The same *build & test* verb ran 3+ times inside one target window (or one session without targets), totalling over 5 min. | Total time of the runs after the first. |
| H2 Slow cheap commands | *read & search* or `git status`/`git log`/`git diff` calls have a median over 5 s in the period. Likely permission prompts; suggests allow rules (`/fewer-permission-prompts`). | (median − 1 s) × calls. |
| H3 Subagents run one after another | A session has 3+ foreground subagents and average parallelism under 1.3. | Foreground subagent time minus the longest single run (an upper bound, said as such). |
| H4 Waiting for you is the largest share | "Waiting for you" is over 30 % of a session's or task's active time. Names the sessions and tasks. | That waiting time. |
| H5 Failing tool loop | The same tool verb fails 3+ times in a row in a session. | Time of the failed runs. |
| H6 Expensive context | A session's cache read share is under 50 % with over $5 spent, or it had 2+ compactions. | Its cost. |
| H7 Top model on subagents | Subagent calls on the most expensive model in the price table cost over 30 % of the period's spend. | The cost difference at the next cheaper tier's prices. |

### How the Desktop gets it

A new CLI command, `watchtower agents report --workbench N [--since <date>]
[--session <uuid>] --json`, with pinned keys (a `TestAgentsReportJSON_PinnedKeys`
guard, like `agents stats`). Without `--session` it returns the period's overview,
tasks, sessions and hints. With `--session` it returns that session's breakdown,
subagents, lanes for the timeline and its hints. It reads only the database; it
never reads a transcript.

It must answer in under 1 s for 30 days of this repo's history on the owner's
machine. If plain SQL plus an in-memory walk does not reach that, the builder adds
the smallest cache that does, and says which.

## Part C — the Analytics pane (Desktop)

A new pane, **Analytics**, next to Board and Files in the workbench header
(`WorkspacePane.analytics`, `WorkspaceView.analytics`), project-wide like Board. The
data comes from an `AgentAnalyticsCenter` that runs the CLI command while the pane is
on screen (the `SessionReportCenter` pattern) and refreshes every 60 s.

```
┌ Analytics ─────────────────────────── [7 days ▾]  ● On ┐
│ Active 14h 20m   Away 31h   $182.40   38 sessions        │
│ Subagents: 1.2 at once on average · peak 3                │
│                                                          │
│ Where the time went                                       │
│ ████████ Tools 41% │███ Model 18% │████ Background 22% │██ You 19% │
│   build & test 24% · git 6% · subagents (fg) 7% · …       │
│   Tool time includes permission prompts.                  │
│                                                          │
│ What would save the most                                  │
│ ▸ make test ran 3+ times in 6 tasks — 2h 10m      [show] │
│ ▸ Subagents ran one after another in 9 sessions — ≤3h    │
│ ▸ cat / git status take 9 s on average — likely prompts  │
│                                                          │
│ Tasks            calendar  in review  agent   cost       │
│ #387 Save in wb    3h 10m     1h 05m  1h 40m  $12  shared│
│ …                                                        │
│ Sessions         started   active   cost  subagents ∥    │
│ …                                                        │
│ Tokens & cost: by model · main vs subagents · cache       │
└──────────────────────────────────────────────────────────┘
```

- **Off**: the pane shows a short empty state with **Turn On**, which runs
  `watchtower agents enable --workbench N` (it loads the history at once) and shows
  progress until it returns.
- **Session detail**: clicking a session row pushes its view inside the pane: the
  breakdown, the subagent figures, its hints and a **timeline** — one lane for the
  main agent and one per subagent, segments coloured by category, a hover showing the
  segment (category, tool class and verb, duration). A back button returns to the
  overview.
- **Task row** click selects the target on the board (the existing target panel).
- Charts use Swift Charts (`import Charts`, macOS 14+), new to this app; the stacked
  bar and the timeline are the only charts.
- The session report pane gains one line: agent time, cost and a link to the
  session's analytics.

## Contracts

- AGENTLOG-01..05 unchanged. AGENTLOG-01's guard fixture gains shell lines with
  `cd … &&` and env prefixes, so the new verb rule is checked against it.
- **New AGENTLOG-06 — time adds up.** A session's categories sum to its wall time; no
  stretch is counted twice; "waiting for you" never contains time before a
  `notification` turn. Guard: a fixture session covering every category.
- **New AGENTLOG-07 — hints cite evidence.** Every hint carries at least one evidence
  item that resolves to a stored session, target or command. Guard test over the
  hint builder.
- The `agents report --json` keys are pinned.

## Left to the builder

- The exact markers of hook-injected user records (from fixtures of real transcripts,
  redacted per the public-repo rules).
- Colours, spacing and the exact table columns, following the app's style.
- Whether the report's period filter is applied in SQL or after loading.
- The cache, only if the 1 s budget needs one.
