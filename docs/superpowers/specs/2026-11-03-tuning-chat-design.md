# Tuning chat — tune Watchtower prompts, skills and agent instructions from Analytics

Board #1517. Builds on the agent coach (`docs/features/agent-coach.md`, COACH-01), agent analytics (`docs/features/agent-analytics.md`, AGENTLOG-01..07), the LLM usage ledger (`docs/features/llm-usage-ledger.md`) and the embedded chat (`docs/features/embedded-chat.md`).

Mockups: `docs/design/mockups/tuning-chat/` (DesignShotCatalog renders, light and dark, one per state in §4.4).

## 1. Why

**Discuss in Chat** on the workbench Analytics pane opens the ⌘/ help popup with the period's totals and its top three hints pasted into the composer. That chat cannot read the report, the sessions, the LLM spend, the prompts or the skills, and it cannot change anything. Its answers are generic. The owner wants a place to tune their whole LLM setup: Watchtower's own prompts and their Claude Code and Codex setup (skills, instruction files, allow rules). Tuning there means asking why something costs or fails, getting a concrete edit, trying it on real past calls, and keeping it only if it works.

## 2. Goals, non-goals, anti-goals

Goals:
- G1. A tuning chat in a right-side panel of the Analytics pane, opened by the button that is now **Discuss in Chat**.
- G2. The chat reads what it needs: the agent report and sessions of this workbench (Claude Code **and Codex**), the LLM ledger (`llm_calls`), Watchtower prompts with their additions and versions, captured past inputs of those prompts, global skills, the Watchtower skill pack and the owner's overlays, `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, the Claude allow list and the Codex rules.
- G3. The chat never writes. It proposes an edit, which lands as an ordinary coach proposal (`coach_proposals`, origin `chat`). The owner presses **Accept** on the card in the chat. The coach then does what it does today: compare-and-set, **Roll Back**, and the 14-day verdict.
- G4. A/B: for a prompt addition, the chat can propose a replay of the prompt on up to 5 captured past inputs, without and with the candidate addition. The owner starts it (one press, cost shown). Both outputs are shown side by side.
- G5. Codex sessions appear in agent analytics beside Claude Code sessions.

Non-goals (v1):
- Editing a prompt template itself. Prompts change through additions only (ask #995).
- Skills inside a workbench repository (`<folder>/.claude/skills`, `.agents/skills` that the owner committed). The coach's "never a repository file" rule stays.
- A/B for skills, CLAUDE.md, AGENTS.md or allow rules. Those can only be measured by the verdict after Accept.
- Automatic scoring of A/B outputs (an LLM judge). The owner and the chat read the two outputs.
- Model or tier choice per purpose.
- Codex analytics for `codex exec` runs (§4.7).

Anti-goals (a failure even if it works):
- Any file or setting changed without the owner's Accept.
- A shipped prompt or pack upgrade silently stopped by an owner edit.
- Captured inputs outliving the data they came from: a purge, a deleted source or a meeting made private.
- Watchtower's own model calls counted as the owner's Codex sessions.

## 3. What the owner sees

1. The Analytics pane header: **Discuss in Chat** becomes **Tune** (icon `slider.horizontal.3`). It toggles a right side panel, placed beside the pane's content with the design kit's `PanelSplit` (the style guide's side panel, not the Workbench's overlay): `PanelSplitWidth` 460 by default, range 360–720, remembered as `analytics.tuningPanelWidth`; Esc in the panel closes it. While it is open **Tune** has the selected look.
2. The panel has a title row ("Tuning", the conversation picker **New** / recent tuning chats of this workbench) and a chat feed with a composer.
3. The empty state shows the period's figures in one line and up to four starter prompts built from the report. Examples: "Why did cost per task grow?", the top hint's finding, "Which prompt costs the most?", "Tune a skill". The text of the starters is defined in the model and tested.
4. While the chat answers, the feed shows the usual streaming row. Tool calls show as quiet lines ("Read the 7-day report", "Read prompt digest.channel").
5. A proposal appears in the feed as the coach's card: **CoachProposalCardView** with chips, why, diff and budget, and the buttons **Decline**, **Edit…**, **Accept**. The same proposal also shows in the pane's **Proposed edits**. After Accept it is listed in **Accepted edits**, where it is measured and can be rolled back like any coach edit.
6. An A/B proposal appears as a card: "Try on 5 past calls of *digest.channel* · ≈ $0.14 · 10 model calls", with **Run** and **Not now**. While it runs, the card shows "Running 3 of 10". When it is done, it shows the inputs as rows (a time and a short label, never the content), each with **Without** and **With** outputs side by side. The diff of the two is highlighted, and the card has **Propose this addition** (which files the proposal card) and **Discard**.
7. The period picker, the hints and the coach sections stay where they are. The panel reads the period the pane shows.

## 4. Design

### 4.1 Chat surface `tuning`

- New tool surface `tuning`, added everywhere the recon lists for a surface: a const in `internal/tools/registry.go`, the `cmd/mcp.go` allowed list, `cmd/ai.go` help, `internal/chat/actions_contract.go` with a pinned `testdata/actions_contract_tuning.txt` and its Swift twin in `AgentToolsContract.swift`, and `AssistantToolSurface`. Quick Connections are skipped on it, as on `automation_editor`.
- The Desktop builds it on `EmbeddedChatEngine` with a `TuningChatSurface` spec. The spec has `.actions(surface: "tuning")`, `persistence: .database(conversationID)`, `ownerInstructions: true` and context `analytics_tuning` with the workbench id. The system prompt is the tuning rules block, the actions contract and `ChatQuestionsContract`. The turn prompt carries the pane's period and the workbench id on every turn. Under ollama the spec is `.draftOnly`, and the panel says that tuning tools need Claude or Codex.
- A `TuningChat` controller (`@Observable`, the `AutomationEditorChat` shape) owns the engine and an `AgentActionFeed` for this conversation, and calls `markShown`/`markHidden`.
- Conversations: chat rows of context type `analytics_tuning`, one context per workbench. **New** starts another one, and the picker lists the last 10. They also appear in the Chats panel under the workbench project, as embedded chats do today.

**Failure paths on the surface.** Each path has a test, named in §5.

| What fails | What happens | Who writes, who wins |
|---|---|---|
| The MCP child (`mcp --chat --surface tuning`) exits mid-turn | The tool call returns an error to the provider, and the turn ends with the engine's existing error line and **Retry**. A proposal row committed before the exit stays and shows in the feed on its next read. On Retry the same proposal is refused by fingerprint as "already proposed as #N", so no second card appears. | The proposal row comes from the MCP child. The fingerprint UNIQUE decides. |
| The provider process dies, or the Desktop quits mid-turn | The interrupted turn is handled as embedded chats handle it today: the owner's message is kept and the answer is marked interrupted. On reopen the conversation replays from the database, with no `--resume` (CHAT-04). | Chat rows are written by the Desktop only. |
| The CLI does not know the `tuning` surface (a stale CLI binary) | Today `ai query` does not check `--surface`: it passes it to the MCP child, which refuses, and the provider may run the turn without tools. Two guards: (1) `ai query` gains the check itself (`tools.KnownChatSurface`), so from this release an unknown surface fails before the provider starts, and the panel shows the engine's start error with **Retry**; (2) for a CLI older than that check, the tuning rules block tells the model: if no tuning tool is in its tool list, answer only "Tuning tools are not available in this Watchtower build — update Watchtower." and propose nothing. No proposal can be written without the tools, so nothing is lost. | — |
| The provider changes to ollama mid-conversation | The next turn runs as `.draftOnly`, and the panel shows the "tuning tools need Claude or Codex" line. Existing cards stay actionable, because Accept and Run go through the CLI, not the chat. Mockup `tuning-chat-no-tools-midway`. | — |
| The bulk-read limit is hit (READ-01) | The read tool refuses in plain words, and the chat says so. The session key is `conversation:<id>`, so **New** starts a fresh budget. | — |
| A tool names a workbench, prompt, skill or input that is gone | The tool returns "not found" as a tool error. Nothing is written. | — |
| The workbench is deleted while the panel is open | The Analytics pane leaves that workbench, and the panel closes with it. The conversations follow the embedded-chat rule for a deleted context. | — |
| Accept is pressed on a card while the chat proposes an edit to the same destination | Accept and the new proposal race on the "one open proposal per destination text" rule. Accept's compare-and-set moves the first proposal out of OPEN, and the new proposal is then checked against the changed file, so its `find` either matches once or is refused. | Accept runs in the CLI, the proposal in the MCP child. The compare-and-set and the validation order decide. |
| The same conversation is open on a second screen | `EmbeddedChatCenter` keeps one engine per conversation, as today, and a second view attaches to it. | Chat rows are written by the Desktop only. |

### 4.2 Tools on `tuning`

Read tools (all `CompanyData` where they return content, within the bulk-read limits):

| Tool | Returns |
|---|---|
| `get_agent_report` | `agents report --workbench N --days D` JSON, both agents, optionally `agent: claude\|codex` |
| `list_agent_sessions` / `get_agent_session` | sessions with cost, time and trouble; one session's report |
| `get_llm_usage` | `usage llm` sections and per-purpose rows for a period |
| `list_prompts` / `get_prompt` | prompt ids with their purposes, spend over 30 days, version and additions; one prompt's resolved template, additions and history |
| `list_prompt_inputs` | the captured inputs of a prompt id: time, provider, model and size, **not** the text |
| `get_prompt_input` | one captured input's text (system and user), for the chat to reason on |
| `list_skills` / `get_skill` | global Claude skills, global Codex skills, the pack skills with their overlays; one skill's text |
| `get_agent_instructions` | `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, the Claude allow list and the Codex rules file, each with its budget |
| `list_coach_proposals` | the coach's open, accepted and declined proposals (so the chat never repeats a declined one) |

Proposal tools (they write only a proposal row, never a destination):

| Tool | Does |
|---|---|
| `propose_tuning_edit` | `{destination, workbench_id?, prompt_id?, skill?, kind, find?, replace?, after?, title, why, metric}` → `coach.ValidateChatProposal` → `db.InsertCoachProposal` with `origin = 'chat'` and evidence `[{kind:"chat", ref:"c<conversation>"}]` plus the refs the chat cites |
| `propose_prompt_replay` | `{prompt_id, addition, input_ids?}` → a `prompt_replays` row in state `proposed` with the cost estimate; the owner's **Run** starts it |
| `get_prompt_replay` | a replay's state and, when done, both outputs per input |

`ValidateChatProposal` is the coach's `Validate` minus the two weekly gates: no 3-source floor and no 3-open cap (the owner asked for it in the chat). Everything else stays: the destination must be allowed, `find` must match once in whole lines, the budget per destination, `SafeAllowRule` and its Codex twin, fingerprint uniqueness against every earlier proposal, and one open proposal per destination text. A chat proposal does **not** count toward the weekly proposer's 3-open cap, but the weekly proposer still sees it as OPEN (the "one per destination" rule holds across both). The refusal reasons go back to the chat as tool errors in plain words, so it can fix and retry.

### 4.3 Destinations

The coach's v1 destinations stay. New ones:

| Destination | File or row | Edit | Budget |
|---|---|---|---|
| `prompt_addition` | `prompt_additions` (existing) | add/cut a line | `prompts.MaxAdditionRunes` 600 |
| `claude_skill_user` | `~/.claude/skills/<name>/SKILL.md` | exact-text replace, add or cut | current + 2000 runes, never past 20 000 |
| `codex_skill_user` | `~/.agents/skills/<name>/SKILL.md`, else `~/.codex/skills/<name>/SKILL.md` | the same | the same |
| `pack_overlay` | new table `skill_pack_overlays(skill, text, proposal_id)` | add/cut a line | 1000 runes per skill |
| `codex_agents_md_user` | `~/.codex/AGENTS.md` | exact-text replace; created when absent (before = "") | current + 400, never past 4000 |
| `codex_rules_allow` | `~/.codex/rules/default.rules` | append `prefix_rule(...)` lines from the safe table only | grow only |

Rules for every file destination are the same as `writeClaudeMD`. The file is read only when it is a regular UTF-8 file up to 256 KB, never through a symlink. The write is atomic and re-reads the file just before the rename. Accept compares against `before_text`, and Rollback restores it or returns the diff with `ErrChangedSince`. For `codex_skill_user` the copy Codex reads wins: the builder confirms Codex's precedence when a name exists in both folders and pins it in one function (`codexSkillPath`); `list_skills` shows both copies with "Codex reads this one" on the winner, and only the winner is a destination. A skill must already exist: the chat never creates a new skill folder in v1 (a "make me a skill" request gets the skill text in the chat, to save by hand). Only `AGENTS.md` may be created, as an empty `before_text`. A rollback of a created `AGENTS.md` writes it back as an empty file and does not delete it.

**Pack overlays.** A pack skill (the workbench skill, the flow skill and the `Skills()` pack) is installed as the shipped bytes plus, when the owner has an overlay, a block after the frontmatter: `## Owner additions (approved by the owner)` followed by the lines. `installSkill` computes the `.watchtower-shipped` digest over the rendered bytes, so an overlay is not drift. A pack upgrade re-renders shipped bytes plus overlay, so upgrades keep coming (ask #995). An overlay change re-renders every installed copy the next time the folder's pack is checked (`integrate`, workbench open, the daemon's drift check). Accept also runs that re-render for the folders of the owner's workbenches at once, and the result says how many copies changed. An installed copy the owner edited by hand stays drifted, as today (DEV-04), and the overlay does not reach it. The card says so ("1 copy is edited by hand and was not updated").

**Codex rules table.** It is `SafeAllowRule`'s list in Codex form: `prefix_rule(pattern=["cat"], decision="allow")` … `["go","test"]` …. It lives in one Go table, and a test keeps it equal to the Claude table. The Codex file is append-only for us. Rollback removes only the lines this proposal added.

### 4.4 Screen states (mockup per state)

| State | Panel shows |
|---|---|
| Empty | one figures line + up to 4 starters + composer |
| Loading | the report is still loading: "Reading this workbench's analytics…" and the composer enabled |
| Streaming / busy | the streaming row; the composer shows **Stop** |
| Error | the turn failed: the error line from the model + **Retry**; an A/B card failed: "Stopped after 4 of 10 calls: <reason>" + **Retry** |
| Proposal | the coach card inline: open; accepting (buttons disabled, as today); stale — the card's existing error line "The text changed since — this proposal is closed" (`CoachCenter`, unchanged); after Accept the card in the feed folds to one line "Accepted · measuring for 14 days" with **Show in Accepted edits** (the pane's log keeps Roll Back) |
| A/B proposed / running / done | as §3.6 |
| No tools | ollama: the figures line stays, the starters are hidden, "Tuning tools need Claude or Codex — pick one in Settings → AI" + **Open Settings** |
| A/B too few inputs | the chat's answer plus a quiet line "Only 2 past calls of <prompt> match the current prompt — A/B needs 3. It will be possible after the prompt runs again."; no card |
| Agent filter | the pane header: period picker, then **All / Claude Code / Codex** (only when both agents have sessions in the period), then **Tune**; Claude-only Statistics blocks carry "Claude Code only" (a `scopeNote` on `AgentAnalyticsBlock`, set from the report's new per-block `agents` key, text in `AgentAnalyticsFormat`) |
| No tools, midway | the provider changed to ollama in an open conversation: the earlier turns and an open card stay, with Accept / Decline enabled; the no-tools line and **Open Settings** sit above the composer (mockup `tuning-chat-no-tools-midway`) |
| Codex not read | the pane's Statistics starts with the quiet line "2 Codex sessions were not read: too large or damaged." when `codex_unread` > 0 (mockup `tuning-chat-codex-unread`) |
| Narrow scope | panel at 360 pt: the pane header wraps the agent filter under the period picker; the card's diff wraps, its evidence links take their own line above the buttons, the A/B outputs stack (Without above With) |
| Analytics off | the panel is not offered; **Tune** is hidden, as the coach sections are |

In the panel the card's **Accept** is a secondary button, so the panel has one prominent action at a time (an A/B card's **Run** or **Propose this addition**); in the pane's Proposed edits the card keeps today's look. **Tune** has the selected look of a toggle while the panel is open.

Destination labels (chip and diff caption, `CoachProposal.destinationLabel`): `claude_skill_user` → "Claude skill · <name>", `codex_skill_user` → "Codex skill · <name>", `pack_overlay` → "Watchtower skill · <name>", `codex_agents_md_user` → "Codex AGENTS.md", `codex_rules_allow` → "Codex rules". These destinations are global, so their labels carry no "· all workbenches" suffix; the existing `claude_md_user` label keeps its suffix unchanged (not this feature's change). Already on the branch with the mockups: `CoachProposal.skill` (optional key `skill`), these labels, and the card footer that puts the evidence on its own line when it does not fit. The proposal row and `coach proposals --json` gain a `skill` key (new column `coach_proposals.skill`, '' for other destinations); a skill destination's fingerprint includes it.

`PanelSplit` draws its edge line across the panel in DesignShots renders (the mockups draw their own hairline); the builder fixes it in the design kit and checks the kit's Panels shot.

Every visible string (folded accepted line, too-few-inputs line, figures line, starters, tool-activity lines, A/B progress and totals, refusal and error lines) is produced in `TuningChatTexts` (WatchtowerCore) and covered by a test. Colours come only from `Tone`. There are no row separators and no stock list look. After implementation, the screens are compared against the mockups.

### 4.5 Captured prompt inputs

- New table `prompt_inputs(id, prompt_id, prompt_version, additions_hash, purpose, captured_at, provider, model, system_text, user_text, refs, has_additions)`. `refs` is a JSON list of `{source, account_id}` (and `transcript_id` for meeting prompts), filled by the pipeline from what it fed in.
- Capture is set up at the call sites: `prompts.WithCapture(ctx, id, version, refs)` next to the existing `digest.WithSource`. Recording happens at the leaf, where `llmusage.Record` runs today: a leaf that sees a capture in ctx writes one row after a successful call. It keeps the newest 5 rows per `prompt_id` (the insert and the trim run in one short write transaction) and drops rows older than 7 days in the daemon's ledger phase. A guard test in the `TestLLMUSAGE01_LeavesRecord` style checks that every non-test `prompts.Resolve` caller package sets a capture, or is listed with a reason.
- Not captured: the chat surfaces (chat, embedded chats, workbench), automations' `llm()` (their recipes are not Watchtower prompts), the tuning replays themselves, and any call whose input includes a private recording (those are never read into prompts today; the capture also refuses a `transcript_id` that is private).
- Writers: every process that runs a pipeline (the daemon, CLI commands such as `briefing generate`) writes directly to `watchtower.db`. Nothing goes through the spool, `llm_calls` or the logs (FILES-01). If two processes capture the same prompt at the same moment, both inserts land and the trim keeps the newest 5 by id, so neither write blocks the other for long. A failed capture write is logged as a fingerprint and never fails the model call.
- Removal:
  - **Account purge.** Each `PurgeSteps` source deletes `prompt_inputs` rows whose `refs` hold that account (and the replays built on them).
  - **Source deletion.** When a deletion pass writes a tombstone for an account (Slack, Gmail, IMAP, Jira), the same pass deletes that account's captured rows. This is coarse on purpose: inputs refill within days. The cost is that A/B for prompts that read that account can be unavailable for a few days after a deletion pass; the too-few-inputs line above covers it.
  - **Meeting made private.** A trigger on `meeting_transcripts.private` going on (the 00164 shape) deletes the rows with that `transcript_id`.
  - **Workspace delete** removes everything.
- `prompt_replays(id, conversation_id, prompt_id, addition, input_ids, state proposed|running|done|failed|discarded, est_cost_usd, calls_done, results JSON, error, created_at, finished_at)`. The results hold both outputs per input. The same removal rules cascade through `input_ids` (a replay loses its outputs when one of its inputs is removed, and reads "an input was removed").

### 4.6 A/B replay

- **Run** (the owner's press) runs `watchtower prompts replay <replay_id> --json` from the Desktop. The CLI refuses under an agent marker, like `coach accept`. It takes `prompt_replays` from `proposed` to `running` by compare-and-set and then, for each input, calls the prompt's tier on the captured input's provider and model:
  - **Eligible inputs.** Only inputs captured with the prompt's current template version and current additions (`prompt_version` plus a hash of the additions block, stored at capture as `additions_hash`) are eligible, so **Without** is today's prompt and the comparison is about the candidate line alone. `propose_prompt_replay` needs at least 3 eligible inputs and takes the newest 5. With fewer it refuses with "Only N past calls of <prompt> match the current prompt — A/B needs 3" and no card is filed; the chat says so and offers to propose the addition without A/B. The same rule is re-checked at **Run** (inputs may have been removed since): under 3 eligible the run refuses with that line and the row goes `failed`. The done card states "Past calls captured with prompt v<N> · current v<N>".
- **Without:** the captured system and user text exactly as captured.
  - **With:** the same text with the additions block re-rendered with the candidate line appended. The block is located by its fixed header. When there is none, it goes where `WithAdditions` puts it, at the end of the template, which after `SplitPromptAtData` is the end of the side that held the template's tail. The builder proves this with a golden test per pipeline family: re-rendering through the real pipeline with the addition must give the same bytes as the replay's "With".
- Calls go through the ordinary leaf, so they are recorded in `llm_calls` with purpose `prompts.replay` and surface `watchtower`, and are never captured. Each call writes its result to the row in its own short transaction, so a crash keeps what finished. The estimate is input tokens × the model's price × 2 per input, plus the median output of that prompt from `llm_calls`, shown before **Run**.
- Failure paths:
  - **Desktop quits mid-run.** The CLI runs detached and keeps going. When it finishes, the row reaches `done`.
  - **CLI killed or the Mac sleeps.** On the next cycle, the daemon's sweep marks a `running` row with no update for 10 minutes `failed`, with "stopped after N of M". **Retry** re-runs only the inputs without results.
  - **A model error on one input.** That input's result is the error, the rest continue, and the row is `done`, with "2 of 10 failed".
  - **An input removed mid-run** (a purge). The call for it is skipped as "input removed".
- Writers: the CLI (results), the daemon (the stale sweep) and the Desktop (**Discard** sets `discarded`). All of them use compare-and-set on `state`, so the first transition wins and the others get "already done".

### 4.7 Codex sessions in agent analytics

- **`agentlogdb` migration 00003** (one rebuild of both tables, one transaction, a row-count test):
  - The `agent` CHECK on `agent_log_files` and `agent_log_sessions` becomes `IN ('claude','codex')`.
  - `agent_log_files` gains four columns:
    - `state TEXT NOT NULL DEFAULT 'ok' CHECK (state IN ('ok','held','unreadable','too_large','orphan_skipped'))`;
    - `state_since TEXT`: when the file entered its current state, the start of the orphan clock;
    - `error_class TEXT`: the class only, never text (FILES-01);
    - `parse_state TEXT`: the Codex resume state below, JSON, NULL for Claude.
  - Existing Claude rows get `state = 'ok'` and NULLs.
  - The Go side takes the agent from `agentkind`, and `storeSlice` gets the agent as a parameter. `state`, `state_since`, `error_class` and `parse_state` are written in the same transaction as the offset compare-and-set, so a slice and its resume state land together or not at all.
- Discovery: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` (honouring `CODEX_HOME`), plus a compressed `rollout-*.jsonl.zst` if the builder finds Codex writes that name (it confirms it on real files and pins it in the discovery test).
- **Compressed rollouts.** Codex can store a rollout as zstd (`sessionfeed` today sees the frame magic `28 b5 2f fd` and reads nothing). The importer never reads by byte offset into such a file. Instead:
  - The magic at offset 0 is checked on every scan, not only the first one, because a file can be compressed in place after Watchtower already read part of it as JSONL.
  - A compressed file is read whole through `github.com/klauspost/compress/zstd` (a new pure-Go dependency), capped at 64 MB of decompressed text. Above the cap the file is skipped and marked `too_large`. The report gets a key `codex_unread` (the count of `too_large` plus `unreadable` files whose sessions fall in the period, by their file mtime). When it is above 0, the pane shows a quiet line at the top of Statistics: "2 Codex sessions were not read: too large or damaged." The text lives in `AgentAnalyticsFormat`, and the mockup is `tuning-chat-codex-unread`.
  - Its stored offset counts decompressed bytes. It is read again whole only when its size or mtime changes.
  - A file that moved from plain to compressed, at the same path or under the `.zst` name, imports no twice-counted rows: the dedupe key below is the session id plus an ordinal, not a byte offset or a path.
  - A corrupt or truncated frame stores nothing from that file. The file is marked `unreadable` with the error class only (FILES-01), and the next scan tries it again only if its size or mtime changed.
  - `sessionfeed` and `internal/terminal` (`codex_rollout.go`, which reads the owner's prompts) get the same decoder through `codexrollout`, so the Workchat of a compressed Codex session stops being empty. That is a deliberate behaviour change:
    - `TestParseCodex_SkipsZstd` is replaced by a test that a compressed file yields its entries;
    - the zstd test in `internal/terminal` changes the same way;
    - their other tests stay unchanged.
  - Each reader checks the magic at offset 0 on every read. A file compressed after a partial read is read again whole from the start, and each reader's existing upsert by entry id, or the dedupe key here, drops what it already had.
- Ownership comes from the cwd of the first `turn_context` (fallback: `session_meta.cwd`) through the same `OwnerFolder` rule as Claude's home cwd. Every scan lists **all** rollout files under `sessions/`. It only stats them: about a thousand files on a heavy install, the same as Claude's listing today. It reads the files whose size or mtime changed, newest first. There is no day window, because a resumed session can append to a file in an old day folder. The existing missing sweep therefore sees a complete listing, and a budget stop never marks unlisted files missing (the `present` rule in `scan.go`).
- **Excluded:** sessions whose `session_meta.originator` is the exec kind. Every Watchtower child (`codex exec` for digests, spec review, automation `agent()`) is that kind and runs with the owner's `CODEX_HOME`, so it lands in the same folder. The owner's own `codex exec` runs are left out too (v1 limit). The guide's Analytics page says it in one line ("Codex runs started with `codex exec` are not counted"), and the pane's agent filter has the same line as its help text. The builder confirms the originator values on real files and pins them in a parser test fixture written from scratch (no real content).
- **Sub-agents.** A rollout whose `session_meta` names a parent thread (Codex's sub-agent threads, `thread_source`/`source` marking a spawned agent) is never an owner session: it is stored as a sub-agent of its parent (`agent_log_subagents`, events under the parent's session, `agent_id` = the child thread), the twin of Claude's `subagents/agent-*.jsonl`. The exec exclusion is decided on the root thread only, so the children of an interactive session count and the children of an exec run do not. Tokens are taken only from each file's own `token_count` deltas, and the builder confirms on real files that a parent's totals do not include its children's (a fixture pins it); if they do, the parent's deltas are used and children contribute tool and time rows only. A child whose root is not decided yet is held. Nothing is stored, and the file row is marked `held` with `state_since` = the scan that first held it (not the file's mtime).
  - "Decided" means the root thread's file has been read up to its `session_meta`. The parent is looked up by thread id in the scan's full listing; the id is in the filename.
  - When the parent is listed but not read yet (a first import of old history, or a budget stop), the child just waits. The clock keeps running, but it can only fire on a complete scan.
  - A held child becomes `orphan_skipped` only when both hold: a complete scan (not `Incomplete`) finished without its parent's id in the listing, and `state_since` is more than 7 days old. Its rows are never stored.
  - An `orphan_skipped` child is checked again whenever its parent's id later shows up in a listing. It is then imported like any child: stored if the root is not exec, dropped if it is.
  - So an exec run's child never reaches the owner's analytics. The only loss is a child whose parent file is gone for good (v1 limit).
  - The import report counts `held` and `orphan_skipped`.
- **One decoder.** Two packages read rollouts today, each with its own copy of the line types and the zstd check: `internal/sessionfeed` (`ParseCodex` for the dialog, `LocateCodex`) and `internal/terminal` (`codex_rollout.go`, the owner's prompts).
  - The line envelope, the payload types of both dialects, the zstd opener and `Locate` move into a leaf package `internal/codexrollout`.
  - All three readers use it: `sessionfeed`, `terminal` and the new `agentlog` parser. Each keeps its own projection.
  - Their tests stay unchanged, except the zstd tests named above.
- `agentlog.ParseCodex(r, offset, opts) ParseResult` maps the file to the same rows:
  - An `api_call` per `token_count` delta (`last_token_usage`; `cached_input_tokens` → cache read; `cache_write_input_tokens` → cache write 5m). The model comes from the current `turn_context`.
  - **Two rollout dialects.** `codexrollout` decodes both: the legacy one (`event_msg` `user_message` / `agent_message`) and the paginated one (`event_msg` `item_completed` / `item_started` with a `UserMessage` / `AgentMessage` item, and `turn_started` beside `task_started`), as `sessionfeed` already does. A file may mix the two. `response_item` and `compacted` lines repeat the same text and are not counted again.
  - An `owner_turn` per turn that has a user message in either dialect: the first `user_message` or `UserMessage` item after a `task_started`/`turn_started`. A turn that carries both dialects counts once. A user message with no turn start before it opens its own turn. `tool` events come from `function_call`/`custom_tool_call` paired by `call_id`, with the outcome from the output. `turn_aborted` with reason interrupted → `outcome = interrupted`, and compaction → `compaction`.
  - Denials are classified only where the output text matches Codex's denial wording. That wording is pinned in a fixture, and anything else is `ok`.
  - The dedupe key is `codex:<session id>:<ordinal>`. `ParserVersion` is per agent.
  - **Resume state.** `scanFile` reads from the stored offset in slices of `batchRows`, so a slice or a later scan starts mid-file. The state a later line needs is carried in `parse_state`, written with the slice's offset:
    - the session id and the root and exec decision;
    - the current model and provider from the last `turn_context`;
    - the next ordinal;
    - the open turn (its start and whether its owner message was counted);
    - the open tool calls by `call_id`, with start time and name, at most 256. The oldest drop as `unpaired`.
  - `ParseCodex` takes the state in `opts` and returns the new one. A slice with no state (a missing or unparsable `parse_state`, or a `ParserVersion` change) re-reads the file from offset 0. The dedupe key keeps that from counting twice. It never parses with an empty state from a mid-file offset, so a resumed slice cannot lose the model (cost 0) or restart the ordinal (a key clash).
- Cost: price rows for the Codex models in `internal/pricing`, with a Codex-shaped cost (input, cached input, cache write, output; reasoning output counted as output). An unknown model gives cost 0 and `cost_estimated` as today, never a guess.
- Workbench Codex terminal sessions link by `terminal_sessions.agent_transcript_path` (else by the session id in the filename), the twin of `ClaudeTerminalSessionIDs`.
- `agentreport`: the report's totals, time model, tasks, cost, commands and trouble include Codex rows. Claude-only blocks (context parts, skill listing, Claude hints) say "Claude Code only" when Codex sessions are in the period. The report and the pane gain an agent filter **All / Claude Code / Codex** (a `KitSegmentedPicker` beside the period, shown only when both agents have sessions in the period).
- AGENTLOG contracts amended in `docs/inventory/` (the agent column, the exec exclusion), approved in ask #999.

### 4.8 Writers and races (summary)

| Data | Writers | Who wins |
|---|---|---|
| `coach_proposals` | weekly proposer (daemon), `coach run`, tuning chat tool (MCP child), Desktop Accept/Decline/Rollback (CLI) | fingerprint UNIQUE and one open per destination text; the status changes are compare-and-set, as today |
| destination files | Accept/Rollback (CLI), the owner by hand, Claude Code or Codex themselves | re-read before rename; `before_text` mismatch → stale, never overwrite |
| `skill_pack_overlays` + pack copies | Accept/Rollback (CLI), re-render by `integrate`/daemon drift check | the overlay row is the truth; a re-render is idempotent; a hand-edited copy is left alone |
| `prompt_inputs` | every pipeline process; purge, deletion pass, private trigger, daemon retention | inserts never conflict; deletes win (a removed row is gone even if captured a moment later from the same old data, which is then removed on the next pass) |
| `prompt_replays` | MCP tool (propose), CLI (run), daemon (stale sweep), Desktop (discard) | compare-and-set on `state` |
| `agent_log_*` codex rows | daemon `phaseAgentAnalytics`, `agents scan` | the existing import lock and dedupe key |

## 5. Contracts and tests (beyond those named above)

- Pinned `tuning` actions contract (Go and Swift twins). Every new tool goes into `buildToolRegistry` with `CompanyData` marked, so the `UndecidedReadTools` guard stays green.
- Surface failure paths (§4.1 table), one test per row:
  - The MCP child is killed after a proposal commits: the row survives, and the retried call is refused as "already proposed as #N".
  - An interrupted turn replays from the database without `--resume`.
  - `ai query --surface nope` exits with an error before any provider process starts (Go, a stub provider that records whether it ran). The start error reaches the panel with Retry (Swift).
  - The tuning rules block carries the "no tuning tool in your list" line (a pinned prompt test).
  - A provider switch to ollama makes the next turn draft-only.
  - The read limit refuses a tool and resets on a new conversation.
  - A gone workbench, prompt, skill or input gives "not found" and writes nothing.
  - A deleted workbench closes the panel and drops the engine.
  - Accept racing a new proposal on the same destination ends in one outcome only: the new proposal is either validated against the changed file or refused.
  - A second screen attaches to the same engine.
- Read-tool edge cases (table tests in the tools package):
  - An empty period, a workbench with no sessions, and a period with only one agent: no agent filter in the JSON, and no "Claude Code only" note when there are no Codex rows.
  - `agent: codex` with no Codex data returns empty sections, not an error.
  - An unknown `agent`, a negative or zero `days`, or `days` beyond the 90-day retention is refused or clamped as the report's CLI does.
  - `list_prompt_inputs` for a prompt with no captures, and `get_prompt_input` for an input removed between list and get.
  - `get_skill` on a symlinked, oversized or non-UTF-8 skill, and on a skill present in both Codex folders (only the copy Codex reads is returned).
  - `get_agent_instructions` when `~/.codex/AGENTS.md` or the Codex rules file is missing (budget shown, text empty).
  - `list_coach_proposals` includes declined chat proposals.
- Proposal-tool edge cases:
  - `find` matching zero or two times, in part of a line, or across CRLF line ends.
  - `replace` that grows the file past its budget.
  - An empty `title` or `why`.
  - A `destination` that does not fit the arguments: `prompt_id` missing for a prompt addition, `skill` missing for a skill destination, a pack skill sent to a user-skill destination.
  - A Codex allow line that the Codex twin of `SafeAllowRule` refuses.
  - `propose_prompt_replay` with fewer than 3 eligible inputs, with `input_ids` naming an ineligible or removed input, and with an addition over 600 runes.
  - `get_prompt_replay` on a discarded or stale replay.
- Codex parser edge cases:
  - A file truncated mid-line: the partial line waits for the next scan.
  - A `token_count` with no `last_token_usage`.
  - A `turn_context` arriving after the first `token_count`: model unknown, cost 0, estimated.
  - Both dialects in one file, a turn with both dialects, and a user message with no turn start.
  - A plain file compressed in place between two scans, a `.zst` copy beside the plain one, a corrupt zstd frame, and a frame over the 64 MB cap.
  - A held child whose parent arrives on the next scan, an exec root's child, and a child still orphaned after 7 days (`orphan_skipped`, nothing stored).
  - The orphan clock: a first import of old history (children with old mtimes, the parent listed but not yet read) holds and then stores, with no `orphan_skipped`. A scan that ends `Incomplete` never moves a child to `orphan_skipped`. An `orphan_skipped` child whose parent id appears later is imported.
  - Mid-file resume: one rollout read in slices of 3 lines (`batchRows` lowered in the test) and, separately, across two scans, gives the same rows, model, cost and keys as one whole read. A missing or corrupt `parse_state` re-reads from 0 with no duplicates. An open tool call that spans a slice boundary still pairs.
  - A resumed session that appends to a file in an old day folder is picked up by the next scan.
  - The full listing: a budget stop leaves unread files not missing.
  - `sessionfeed` and `terminal` read a compressed rollout, and a file compressed after a partial read reads again whole with no duplicate entries.
- `ValidateChatProposal`: a table test for each refusal, plus "a chat proposal does not take a weekly slot but blocks the same destination text".
- File destinations: a symlink, an oversized file, a non-UTF-8 file and a missing skill are each refused. Accept and Rollback round-trip. A change made after the re-read gives stale. A rollback of a created `AGENTS.md` leaves it empty.
- Pack overlay: the rendered digest is not drift, an upgrade carries the overlay, a hand-edited copy is untouched, and the overlay block has a fixed position.
- Capture: keep 5 per prompt, the 7-day sweep, purge, the deletion pass and the private trigger each remove rows, a private transcript is refused, a capture failure does not fail the call, no text in logs (`TestFILES01_*`), and the leaves guard.
- Replay: golden "With" equals the real pipeline render for each pipeline family, a stale sweep, a Retry that runs only the missing inputs, a removed input, compare-and-set on the state, and a refusal under an agent marker.
- Codex parser: fixture files written from scratch with every event type, exec excluded, ownership by cwd, dedupe across rescans, and cost with an unknown model. The rebuild migration keeps existing rows (a row-count test).
- Desktop: `TuningChatTexts` tests, `TuningChat` controller tests (shown/hidden, the period carried into turns), and DesignShots for every state in §4.4.

## 6. Docs

- A feature note `docs/features/tuning-chat.md` and a CLAUDE.md index line.
- Guide: the Analytics page gets a Tuning section, the Codex sessions and the exec limit, and a Learn card.
- `docs/features/agent-coach.md`: origin `chat` and the new destinations. `agent-analytics.md`: Codex. `llm-usage-ledger.md`: purpose `prompts.replay`.
- Inventory: amendments to COACH-01 (new destinations, chat origin without the weekly gates), AGENTLOG (codex) and DEV-04 (the pack overlay renders into the shipped digest), plus a new contract for prompt input capture and removal.

## 7. Phasing (for the plan)

1. Capture + `prompt_inputs` + removal hooks (Go).
2. Coach: chat origin, `ValidateChatProposal`, new file destinations, Codex rules, pack overlays (Go).
3. `tuning` surface + read and proposal tools + replay CLI and sweep (Go).
4. `codexrollout` (moving `sessionfeed` and `terminal` onto it, zstd) + Codex parser with resume state + agentlogdb migration 00003 + report agent filter and `codex_unread` (Go).
5. Desktop: panel, `TuningChat`, cards, A/B card, agent filter, DesignShots (Swift).
6. Docs, guide, inventory.

Phases 1, 2 and 4 are independent and can run in parallel lanes. Phase 3 needs 1 and 2. Phase 5 needs 3 and the report keys from 4.

## 8. Decisions

| # | Decision | Source |
|---|---|---|
| D1 | v1 tunes Watchtower prompts, Claude Code skills, CLAUDE.md and allow rules — and the same for Codex | ask #994 |
| D2 | Edits are proposals the owner accepts (coach card, rollback, 14-day verdict) | ask #994 |
| D3 | A/B replay on 3–5 past calls is in v1 | ask #994 |
| D4 | The chat is a right-side panel in Analytics | ask #994 |
| D5 | Past inputs: keep the last 5 per prompt, 7 days, removed on purge, source deletion and private meetings | ask #995 |
| D6 | Codex: its files and its sessions in analytics | ask #995 |
| D7 | Prompts change through additions only | ask #995 |
| D8 | Editable skills: global (`~/.claude/skills`, `~/.agents/skills`) and the Watchtower pack as a personal overlay; no repository skills | ask #995 |
| D9 | The button is renamed **Tune** (owner approves in this review); the panel is a `PanelSplit` side panel (460 pt, 360–720, remembered), per the style guide | agent's call (panel placement: style guide) |
| D10 | Chat proposals skip the coach's 3-source floor and 3-open cap but keep every other check, and do not take a weekly slot | ask #999 (COACH-01 amendment approved) |
| D11 | A/B runs only on the owner's **Run** press with the cost shown; no automatic judge | agent's call |
| D12 | Source deletion removes all captured inputs of that account (coarse, not per message). Cost: A/B for the prompts that used that account may be unavailable for a few days, until 3 new inputs are captured; the "too few inputs" line says so | agent's call — owner approves in this review |
| D13 | Codex `exec` sessions are excluded from analytics (Watchtower's own children are exec) | ask #999 (AGENTLOG amendment approved) |
| D14 | The chat never creates a new skill; only `~/.codex/AGENTS.md` may be created. Cost: "make me a skill" gets the skill text in the chat, saved by hand | agent's call — owner approves in this review |
| D15 | A pack overlay counts as shipped bytes for drift (DEV-04 amendment) | ask #999 (DEV-04 amendment approved) |
| D16 | Codex allow lines come only from a Codex twin of `SafeAllowRule` | agent's call |
| D17 | In the panel Accept is secondary; an accepted card folds to one line in the feed; the stale line stays the coach's existing text; no-tools keeps the figures line and hides starters; **Tune** shows as on while open | agent's call (mockups) — owner approves in this review |
| D18 | `coach_proposals.skill` column and destination labels for the new destinations | agent's call |
| D19 | A/B needs at least 3 eligible inputs, eligible = captured with the current template version and additions (an older input carries other additions in its text, so Without would not be today's prompt). Cost: after each accepted addition A/B for that prompt waits for 3 new runs | agent's call (review round 1; ask #994 said 3–5) — owner approves in this review |
| D20 | Codex sub-agent rollouts are stored under their parent; exec is decided on the root thread | agent's call (review round 1) |
| D21 | One rollout decoder (`internal/codexrollout`) shared by `sessionfeed` and `agentlog` | agent's call (review round 1) |
| D22 | A Codex skill present in both folders: only the copy Codex reads is editable | agent's call (review round 1) |
| D23 | Compressed (zstd) Codex rollouts are read whole through `klauspost/compress/zstd` (a new dependency), capped at 64 MB decompressed, and the magic is checked on every read; a file over the cap or damaged is counted in `codex_unread` and named on the pane | agent's call (owner comment, ask #1004) — owner approves in this review |
| D24 | Both rollout dialects (legacy `user_message`, paginated `item_completed`) are decoded, and a turn counts once | agent's call (owner comment, ask #1004) |
| D25 | A Codex sub-agent whose parent is absent from complete scans for 7 days after it was first held is not stored (`orphan_skipped`), so an exec run's child can never leak into analytics; it is imported if the parent shows up later. Cost: a child whose parent file is gone for good is lost | agent's call (owner comment, ask #1004; replaces the earlier 24 h "store as unknown parent") — owner approves in this review |
| D26 | `ai query` checks `--surface` itself, and the tuning rules tell the model what to say when no tuning tool is present (a stale CLI) | agent's call (spec review, ask #1006) |
| D27 | Codex discovery lists every rollout file each scan (stat only) instead of a day window, because a resumed session can append to an old day folder | agent's call (spec review, ask #1006) |
| D28 | One rollout decoder for all three readers (`sessionfeed`, `terminal`, `agentlog`); the Workchat and the prompt reader start reading compressed rollouts | agent's call (spec review, ask #1006; extends D21) |
