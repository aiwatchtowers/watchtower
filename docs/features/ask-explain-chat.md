# "Not clear?" — a chat about an ask's question (2026-11-24, board #2355)

Spec: `docs/superpowers/specs/2026-11-24-ask-explain-chat-design.md`. Plan: `docs/superpowers/plans/2026-11-24-ask-explain-chat.md`. Mockups: `docs/design/mockups/ask-explain-chat/` (DesignShotCatalog `ask-explain-*`); the same states from the built views are `ask-explain-built-*` (`DesignShotFixtures+AskExplain.swift`, `DesignShotsTests/testAskExplainBuiltShotsRender`). User guide: `docs/guide/features/workbench/asks.md` ("Ask the assistant what a question means").

## Summary

A quiet **Not clear?** under a question or check ask (open or closed; never a review ask, never without a CLI: `AskExplainPresentation.showsEntry`) turns the ask drawer's body and answer bar into an embedded chat whose first, hidden turn explains the question in plain words. **‹ Back to question** (or Esc unless a focused composer holds text) returns to the question view exactly as it was. Mac only.

## Chat identity

- `chat_conversations.context_type = 'owner_ask_explain'` (`db.AskExplainContextType`, `AskExplainKey.contextType`), `context_id = "<workbench id>:<ask id>"` (`AskExplainKey.contextID`), title "Ask #<id>". One conversation per ask, found or created by `AskExplainSurface.conversationID` through Go's `chat.new` with `reuse: true` (two windows or two clicks get one conversation).
- `AskExplainSurface.spec` (`Sources/Services/ChatSurfaces/`): persistence `.database`, `toolAccess: .draftOnly`, the config's provider at its strong tier, `purpose = ask.explain` (`queryPurposes` in `cmd/ai.go`; the usage ledger names it "Ask explanations", see `llm-usage-ledger.md`), `readFolder` = the ask's folder (`AskExplainSurface.readFolder`, read at each open: the folder its filing session was started in — `terminal_sessions.workbench_folder_id` —, else `owner_asks.doc_folder_id`, else the home folder; only a live folder of the ask's own workbench counts, so a removed folder or another bench's falls back to the home folder; `ai query --read-folder` accepts any live workbench folder) only for a provider that reads files (claude, codex; never ollama, whose `ai query` refuses `--read-folder`; an unread catalog gives none).
- System prompt (`AskExplainPrompt.system`, rebuilt from the ask and sent with every turn by `EmbeddedChatEngine.makeStream`; only the hidden `firstTurn` request is first-turn only): the ask's title, summary, changes since the previous round, the "Look at" (focus) items, questions with options, descriptions and recommended marks (or the checklist steps and hints), and the target's title and intent, all fenced as untrusted data with a fence longer than any backtick run inside. Asks store no reason, so none is sent. Rules: answer in the ask's language, explain but never decide or pick, never change anything, the folder is read only. The hidden first turn is `AskExplainPrompt.firstTurn`.

## Desktop

- `OwnerAsksViewModel`: `explainOpen: Set<Int64>` (per ask, in memory; closing the drawer forgets it, the chat stays), `openExplain` (reads the workbench, finds the conversation, `ensureExplainEngine`, then `startFirstTurnIfEmpty(hidden:)`, else `offerRetryOfStoredReply`), `closeExplain` (also forgets the ask's surface, error and rebuild count; an open still finding the conversation when Back is pressed drops its result, makes no engine and starts no turn — the engine itself stays in the center, D5), `explainEngine(for:)` (read only, safe in a body), `ensureExplainEngine` (rebuilds an engine the center let go while idle, from `.task`), `explainErrors` (a failed open), seams `explainConfigProvider` / `explainCatalog`.
- Views: `AskExplainEntry` (`KitQuietButtonStyle(label: .secondary)`, caption, trailing under the question card), `AskExplainPane` (strip + spinner while finding, strip + "Couldn't explain: <reason>" while the open failed, else `AskExplainChatView`), `AskExplainChatView` (strip, `EmbeddedChatRows`, `EmbeddedChatComposer` compact with Esc back). `OwnerAskDrawer` keeps the question layer in the tree under the chat (`OwnerAskDrawerExplainLayers`): opacity, hit testing and accessibility off, so picks, the note draft and the scroll survive (`ask-explain-built-back-scrolled` pins the scroll). While the chat shows, the drawer's bare keys (`OwnerAskDrawerKeys`) are off and ⌘↩ does not answer.
- Copy: `AskExplainCopy` (entry, entryHelp, back, placeholder, errorPrefix, retry, emptyHint).

## States and indicators (decided during implementation)

- **One indicator per state** (spec D10): Loading shows the feed's own live row, Queued the composer's own queued status ("Queued — waiting for a free assistant slot", Cancel). The mockups' "Explaining…" and "Waiting — other chats are answering." lines are not built.
- **Errors** (D11): a turn that fails once its reply row exists shows the shared ChatUI error card with its Retry. "Couldn't explain: <reason>" with **Retry** is only for a failed open (`explainErrors`, e.g. "This workbench no longer exists."). A hidden first turn that failed before it started (`engine.hiddenTurnNotStarted`, no row) shows the engine's own banner text with **Retry** and no prefix, since the banner already says what failed ("Couldn't send: …"; `AskExplainChatView.failureLine`); its Retry opens the chat again.
- **Finding** (D13): before the engine exists the pane shows the strip over a centred spinner.
- **Retry after a restart** (D12): offered for a quit-partial first turn or a retryable error, never for a non-retryable code such as quota (no replay by contract).

## Writers, deletion, merge

The conversation row: `chat.new` only; its `context_id` changes only in `reKeyChats` inside a workbench merge (`<from>:<ask>` → `<into>:<ask>`, with `code_question` and `spec_review_thread`; `TestMergeReKeysTheChats`). Messages: each turn's `ai query --persist` process and the Mac's `chat.reply.finish` / `chat.message.append`, one turn at a time per key (the existing embedded chat rules). Deletion: only `db.DeleteWorkbench`, which drops `owner_ask_explain` conversations with the `<id>:` prefix and, in the same transaction, their queued follow-ups in `chat_queued_drafts` (surface key `owner_ask_explain.<id>:<ask>.<conversation>`, exact prefix `db.AskExplainDraftKeyPrefix`) (`TestDeleteWorkbenchDropsAskExplainChats`, PROJ-02). A merge moves those drafts to the surviving bench's key in the merge transaction (`reKeyChats`). Queued drafts: written and cleared only by the Mac's `DatabaseDraftMirror` through the `chat.*` draft commands. The ask itself is never written by this feature; an ask answered or withdrawn while its chat is open leaves the chat as it is.

## Guards

The chat holds the ask's and the folder's text, so it is kept out of every reader `spec_review_thread` is kept out of: `internal/tools/chat_history.go`, `internal/kb/source_chat_artifact.go`, both `NOT IN` lists of `internal/db/chat_knowledge.go`, memory ingestion, and `EmbeddedChatWiring.savesKnowledge` (Swift). Pinned by `internal/tools/code_question_guard_test.go`, `internal/memory/code_question_guard_test.go`, the `chat_knowledge` tests and `EmbeddedChatWiringTests.testAskExplainSavesNoKnowledge`. The main chat's history lists only `context_type IS NULL` conversations.

## Built views against the mockups

Compared state by state (light and dark) in T5. Differences that stay, all from shared components the feature reuses:

- **Header.** The real drawer header (icon, `#id` and the title in bold, "Question · just now", "k of N ›", expand, close) replaces the mock's kind chip; the answer bar is the drawer's own (status line, **Dismiss**, **Answer**).
- **Entry.** **Not clear?** sits trailing under the question card, above **Note for the agent**, not inside the card's bottom as in the mock (spec "under the question card").
- **Feed and composer.** Owner bubbles are ChatUI's accent bubbles, not the mock's light tint; replies carry ChatUI's copy button and time; the composer is `EmbeddedChatComposer` (grey send button while empty, Stop while busy); streaming text has no block cursor.
- **Loading / Queued / Error.** As D10 and D11 above, instead of the mock's "Explaining…", "Waiting — other chats are answering." and the inline "Couldn't explain" for a failed turn.

## Limits (v1)

- **Mac only** (D8): the phone has no embedded chat engine.
- **No session transcript** in the context (D9); the ask's summary is the agent's statement of the question.
- **Stopped looks like quit after a restart** (D12): Stop and quit persist the same `partial` row, so a rebuilt engine offers Retry on a stopped explanation while a kept one does not. Retry is owner-initiated; a `stopped` marker would change every embedded chat's persistence.
- **A first turn that never started shows its error twice**: the "Couldn't send: …" row with Retry, and the composer's own status line under it.
- **A failed open on a deleted workbench still offers Retry**, which fails the same way; **Back to question** leaves it.
- One orphan conversation is possible if a workbench is deleted between the open's read and its `chat.new` (negligible window); a reply to a conversation deleted mid-turn fails as a save error and the idle sweep releases the engine.
- **A merge mid-stream may build a second idle engine**: a turn running while its bench is merged keeps the old key's engine until it ends; the next open builds one under the new key (idle until the owner writes), and the old one is let go by the idle sweep.
- **Code question and spec review thread drafts** are not deleted or re-keyed with their workbench (`deleteWorkbenchCodeQuestions`, `deleteWorkbenchSpecReviewThreads`, `reKeyChats` move only the conversations); only the explain chats' drafts are handled here.
