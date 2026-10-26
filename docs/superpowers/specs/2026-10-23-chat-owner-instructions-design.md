# The AI chat adapts to the owner — owner instructions in every chat (2026-10-23)

Board: #907 (track "Knowledge storage"), group #914, target #916 (part A of two). Owner decisions in asks #514–#518. Audit of the current state: comment on #915.

## Intent and the why

The owner solves hard problems and changes the system's state in AI chats, and keeps typing the same remarks into chat after chat ("answer shorter", "never propose X", "always check Y first"). What the owner teaches one chat is lost when the next one starts; the workbench agents (Claude Code / Codex sessions) have the owner's instructions, the AI chat does not. The owner put it as two situations:

- **A — the chat adapts to the owner** (this document): the owner's standing directions reach every AI chat, a remark said once can be kept with one word, and the remarks the owner keeps repeating are noticed.
- **B — chats change the machine's knowledge base** (decisions, found answers, state changes become knowledge every consumer sees). A separate design, after A. Owner decision for B already taken (ask #517): the owner's own words may be written directly; anything the model concluded is written only after the owner confirms a card.

Success for A: the owner stops repeating the same remark across chats; a direction typed once in any chat, or kept once from a suggestion, applies in every later chat and to the workbench agents unless it is marked chat-only.

## Goals

1. The owner's instructions reach every AI chat surface as part of its system prompt.
2. One shared text for everyone plus a chat-only addition (owner decision, ask #518): **shared** = today's global *session instructions*, which keep reaching the workbench agents as now and now also reach every chat; **chat addition** = a new global text that reaches chats only.
3. **Remember in place.** An owner message in a chat that starts with an explicit prefix keeps its rule text, verbatim, as a new line of the chat addition — at once, with a short "Remembered" mark and an **Undo** in the chat.
4. **Repeats are noticed.** The daily suggestion pass (`phaseInstructionSuggestions`) also reads the owner's chat turns and proposes the directions repeated across chats. It only proposes; the owner's **Add** is what writes.
5. **Everything is visible and editable in one place** (Settings), and a line added from a chat shows which chat it came from.

## Non-goals

- Facts and decisions about the world ("we decided to move to X", "service Y now lives in Z") — part B.
- Per-workbench or per-chat-project rules beyond what exists (chat projects keep their own `instructions` field unchanged).
- Model-inferred rules written without the owner's press. The model never writes instruction text (see anti-goals).
- Phone surfaces.

## Anti-goals (a failure even if it works)

- **The model silently writes something as the owner's rule** (ask #516: the worst case is "quietly wrote a fabrication as fact"). Only two paths write: the owner's own words behind the explicit prefix (verbatim, no paraphrase, no model in the loop), and the owner's press on Add/Settings. No tool on any agent or chat surface reads or writes the texts.
- A remembered line that cannot be found or undone.
- Chats that nag ("Shall I remember this?") on ordinary messages.

## Current state (what exists)

- `internal/instructions` + migration 00137: `owner_instructions(scope 'session'|'procedure')`, per-workbench `projects.session_instructions`/`target_procedure`, `instruction_suggestions` (`field` CHECK `'session'|'procedure'`), `MaxRunes` = 1000, `BriefSlot`, `AppendLine`, the daily miner over `sessionfeed` owner entries of workbench sessions (≥ 3 distinct sessions validated in Go, light tier, prompt `instructions.suggest`). CLI `watchtower instructions show|set|preview|suggestion`. Desktop: Settings → System → Workbench (`InstructionsSettingsSection`), Agent Settings…, the Home suggestion card. Feature note `docs/features/agent-instructions.md`, contract PROJ-22 (`docs/inventory/workbench.md`), guide `docs/guide/features/workbench/instructions.md`.
- AI chat: the main chat's system prompt is Go-owned (`internal/chat.BuildSystemPrompt`, `cmd/ai_session.go`); the embedded surfaces (`ChatSurfaceSpec`: idea, meeting, track, code question, automation editor) and the target chat build their prompts in Swift. No chat surface carries owner instructions today; chat projects have a per-project `instructions` field. Chat tables are written by Swift only.
- Memory's `parseRememberCommand` (`remember:` / `remember this:`) stages a target/track chat turn as belief evidence when `memory.sources.chats` is on (off by default, memory itself off by default).

## The design

### Texts and where they go

| Text | Storage | Workbench agents | AI chats |
|---|---|---|---|
| Shared (today's global session instructions) | `owner_instructions` scope `session` | yes (brief, unchanged) | yes (new) |
| Workbench addition | `projects.session_instructions` | yes (unchanged) | no |
| Target procedure (global + workbench) | unchanged | unchanged | no |
| Chat addition | `owner_instructions` scope `chat` (new) | no | yes |

The chat slot, rendered by one Go function in `internal/instructions` (format owned in Go, like `BriefSlot`): a header such as `Owner's instructions (follow in every turn):`, the shared text, then `For the chat:` and the chat addition (that header only when the addition is non-empty); empty when both are empty. It sits in the system prompt after the app's own rules and before the chat project block (project instructions are more specific, so they come later). The owner's words are injected as instructions on purpose, not fenced as data — the same stance as PROJ-22.

Every AI chat surface carries the slot: the main chat (Go prompt), Ask Watchtower (⌘/, the same `ChatViewModel`), the embedded surfaces and the target chat. The text is read when a conversation's prompt is built; a warm session keeps its prompt, so an edit applies from the next conversation (a line remembered in place is already in that conversation's history anyway). Setup assistants (calendar/email setup chats, onboarding) are out: they are flows, not conversations with the owner's work.

### Remember in place

- **Trigger:** an owner message whose first non-space characters are `запомни:`, `remember:` or `remember this:` (case-insensitive; the builder may add languages, e.g. Ukrainian). Everything after the colon, trimmed, is the rule line. Nothing else triggers it — no "always/never" guessing (implicit repeats are the miner's job).
- **Effect:** the line is appended to the chat addition (`AppendLine` semantics: refused over `MaxRunes`). The message is still sent to the model as usual (so the current conversation follows it at once). The chat shows a small inline mark under the owner's message — "Remembered for all chats" with **Undo** and **Open in Settings**.
- **Undo** removes that exact line from the chat addition if it is still there (the owner may have edited it in Settings meanwhile — then Undo says it can't find the line and opens Settings). Undo is available while the message is visible; there is no expiry.
- **Over the limit or empty rule:** nothing is written; the mark says why ("Instructions are full — 1000 characters. Open Settings") with **Open in Settings**.
- **Where it applies:** the chat surfaces listed above. The write goes through `watchtower instructions` (a new subcommand, text on stdin, never argv), like every other write.
- **Provenance:** a small ledger records each line added from a chat (the line text, conversation id, message id, time). Settings lists, under the chat addition, the lines that came from chats and are still present in the text, each with a link that opens its chat. A line edited or removed in Settings drops out of that list. The ledger is not a second source of truth: the text in `owner_instructions` is.
- **Overlap with memory's `remember:`:** when memory's chat ingest is on and the chat is a target/track chat, the same message may also become memory belief evidence. Accepted for A; part B redesigns the memory side.

### Repeats across chats (suggestions)

- The daily pass's input gains the owner's chat turns: `chat_messages` with `role='user'` of the last 14 days across the chat surfaces above, grouped per conversation (a conversation counts as a "session" for the ≥ 3 rule). Remember-prefixed turns are dropped (already handled), as are pasted blocks and long entries, the same way as for session feeds.
- A suggestion whose evidence is only chats gets the new field `chat` (writes the chat addition on Add); a suggestion with evidence from both chats and workbench sessions goes to the shared text (`session`, global). Workbench-only suggestions behave as today. Go validation stays the source of truth (conversation ids must exist in the input, distinct count recomputed).
- Same gates as today: once a day, `planusage.NearLimit` skip, model call outside any write transaction, stdin-only prompt.

### Settings

The instructions move to one section the owner finds from anywhere: Settings → Profile → **Instructions** (my call: they are no longer Workbench-only). It holds the shared text ("For chats and agents"), the chat addition ("Only in chats" with the from-chat lines and their links), and the global target procedure; per-workbench texts stay in Agent Settings…. Settings → System → Workbench keeps a pointer to the new place. Preview shows both the brief slot and the chat slot. Home's suggestion card works unchanged for the new field.

## Constraints

- **PROJ-22 is a locked contract** and this design changes it: the shared text now also reaches chats; a second owner path writes text (the remember prefix — the owner's own words, but not Add/Settings); a new `chat` scope and field. The amendment needs the owner's explicit approval (asked with this document's review). Guard tests are amended, never weakened.
- Migrations: `owner_instructions.scope` and `instruction_suggestions.field` CHECKs gain `'chat'` → the table-recreation dance (`add-migration` skill), mirrored in `schema.sql`, golden + Swift test schema regenerated; the ledger is a new table.
- Go ↔ Swift dual path: one renderer in Go; Swift surfaces get the rendered chat slot from Go (CLI `preview`-style call or equivalent) rather than keeping a Swift copy of the format; if a copy is unavoidable, pin it with a shared fixture.
- Both providers (claude, codex) for the miner prompt (`add-ai-prompt` skill).
- Public repo hygiene: no live chat text in tests or fixtures.
- User guide: the instructions page moves/extends to cover chats (`docs/guide/WRITING.md`, 8 KB page cap).

## Left to the builder

- Exact header wording of the chat slot, the mark's copy, the prefix list beyond `запомни:`/`remember:`.
- How Swift surfaces obtain the rendered slot and when they refresh it.
- The ledger's table shape and the new CLI subcommand's name and JSON keys (pinned once chosen).
- Whether the miner gets one combined prompt or a separate chat pass, as long as the validation rules above hold.
- Phasing (a sensible order: storage + slot in all chats → remember in place → miner → Settings move).

## Settled after the builder check

- **Surfaces that keep no `chat_messages` rows** (`ChatSurfaceSpec` persistence `.memory`): they carry the chat slot and remember in place works there too, but the miner reads only persisted conversations, and the ledger's conversation/message ids are nullable — a line from such a chat is listed in Settings without a link, and its mark/Undo lives only as long as that in-memory chat. (My call.)
- **Getting the slot into Swift-built prompts:** the Desktop already sends prompts through `ai query --prompt-stdin` (CHAT-04, 2026-10-17 amendment), so the slot is never on argv; any new path must keep it so. A slot read from the CLI on stdout is fine.
- **Freshness:** main-chat sessions are per conversation (`ChatSessionPool` spawns one per conversation), so a new conversation builds a fresh prompt; no pool invalidation needed. An embedded chat sends its system prompt on its first turn; it reads the slot then.
- **Who writes:** Swift detects the prefix on send (one shared Swift parser used by every chat composer, before persisting the message) and calls the new `watchtower instructions` subcommand with the line on stdin; Undo calls the same CLI. The mark is rebuilt on reopen from the ledger by message id. (My call.)
- **Prefixes:** `запомни:`, `remember:` and `remember this:` (the last matches memory's parser, so the two never disagree on the same text).
- **Workbench additions stay out of chats**, even a chat bound to a workbench (as the table says).
- **Limits:** every append (remember, Add of any field) is refused over `MaxRunes` as today; a mixed-evidence suggestion that does not fit the shared text is refused on Add with the same "full" message, never redirected to the chat addition.

## Calls made by me (for the owner to check)

1. The shared text is today's global session instructions (no new "shared" text, no copy).
2. Remember is an explicit prefix only (`запомни:` / `remember:`), written verbatim, applied at once with Undo — no confirmation card for the owner's own words (consistent with ask #517).
3. Remembered lines go to the chat addition, not the shared text (a rule said in a chat is about chats; the owner can move it in Settings).
4. Setup and onboarding chats are out.
5. Instructions move to Settings → Profile → Instructions.
