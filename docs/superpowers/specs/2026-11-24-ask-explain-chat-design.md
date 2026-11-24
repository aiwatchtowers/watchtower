# Ask: "Not clear?" — a chat about the question, on the whole ask panel

**Board:** #2355. **Mockups:** [`docs/design/mockups/ask-explain-chat/`](../../design/mockups/ask-explain-chat/) (DesignShotCatalog `ask-explain-*`, light and dark).

## Problem

An agent's ask is sometimes impossible to answer: the question uses the agent's own words ("park", "guard", file names), and the summary assumes the context the agent has and the owner does not. Today the only way to understand it is to go to the session's terminal and ask the agent there, which interrupts its work, or to answer blind.

## Goal

One quiet control on the ask, **Not clear?**. It turns the whole ask panel into a chat with an assistant that has already explained the question in plain words. The owner can ask more, then goes **Back to question** and answers as usual. Nothing else is added to the ask.

## Non-goals (v1)

- No question to the ask's author session from this chat, no draft answer built from the chat, no quick-question chips (all three were in the first mockup and the owner dropped them: "дохуя кнопок", ask #1784).
- No answering from inside the chat: the options stay on the question view.
- Not on the phone.
- Not on review asks: a spec or plan review has its own Discuss threads (spec review, 2026-11-08), and a classic document review is read in its document.
- The assistant does not read the session's transcript (only the ask, its target and the workbench folder).

## Decisions

| # | Decision | Source |
|---|---|---|
| D1 | One quiet entry, **Not clear?**, under the ask's options; no other new controls on the ask | ask #1784, conversation |
| D2 | The chat takes the whole ask panel, with **‹ Back to question** at the top | conversation, ask #1785 |
| D3 | The first message is the explanation, started on open without the owner typing | ask #1784 |
| D4 | No question to the author, no answer drafting, no chips in v1 | ask #1784 (supersedes ask #1782) |
| D5 | The chat is kept per ask: reopening it continues where it stopped | conversation (mockup text approved in ask #1785) |
| D6 | The assistant reads the workbench folder, never changes anything (`.draftOnly`) | decided by the agent, same boundary as code questions |
| D7 | Question and check asks only | decided by the agent (review asks have their own threads) |

## Behaviour

### Where the control is

On the question view of an ask drawer (`OwnerAskDrawer`), for an ask of kind `question` or `check`:
- open ask: **Not clear?** (`questionmark.circle`, `KitQuietButtonStyle(label: .secondary)` — grey, not the accent —, `.caption`), trailing, under the question card, above the note field;
- closed ask (answered, withdrawn): shown only when the ask already has a chat, to reread it.

Tooltip: "Ask the assistant to explain this question".

### The chat view

Pressing it replaces the drawer's body **and** its answer bar with the chat view; the drawer header (kind, title, "k of N ›", expand, close) stays. The chat view is:
- a strip: **‹ Back to question** (`.kitQuiet`), then the ask's title on one line, truncated;
- the feed (`EmbeddedChatRows`, compact density), scrolling, following the latest reply;
- the composer (`EmbeddedChatComposer`), placeholder "Ask about this question…".

**Back to question** (also Esc while the composer is empty or not focused; ⌘[ stays Back to Workbenches) returns to the question view with everything there as it was: picked options, the note draft, the scroll position.

The mode is per ask: `OwnerAsksViewModel.explainOpen: Set<Int64>` (ask ids, in memory, not persisted). "k of N ›" to another ask shows that ask's own mode; coming back shows this one's. Closing the drawer forgets the mode (the chat itself is kept, D5). While the chat is shown the drawer's bare keys (`OwnerAskDrawerKeys`) are off, and ⌘↩ does not answer the ask.

### The first message

Opening the chat of an ask with no chat yet finds-or-creates its conversation, then starts a **hidden** turn (the engine's hidden prompt, no owner row):

> Explain this question to the owner in plain words: what is being decided, what each option changes for them, and what the agent recommends and why. Short; no jargon the question does not explain.

Opening a chat that already has messages starts nothing. A chat whose first turn ended in an error or partially shows that row with **Retry** (the engine's existing Retry), never a second hidden turn on its own.

### The assistant

A `ChatSurfaceSpec` (`AskExplainSurface`, `Sources/Services/ChatSurfaces/`), like `CodeQuestionSurface`:
- key `EmbeddedChatKey(contextType: "owner_ask_explain", contextID: "<workbench id>:<ask id>", conversationID:)`;
- persistence `.database`, the conversation found or created with `DatabaseEmbeddedChatStore.conversationID(…)` (Go's `chat.new` with `reuse: true`), title "Ask #<id>";
- `toolAccess: .draftOnly`;
- `runOptions`: the config's provider at its strong tier, `readFolder` = the workbench's folder;
- the system prompt (first turn only) carries, fenced as untrusted data (a fence longer than any backtick run inside, as `CodeQuestionContext` does, with a line telling the model it is data, not instructions): the ask's title, summary, reason, questions with their options and descriptions (or the checklist), the recommended labels, and the target's title and intent when the ask has a target. It says: answer in the language the ask is written in; you explain, you never decide for the owner; the folder is for reading only.

The prompt text lives in one Swift constant (`AskExplainPrompt`), covered by a test that pins its parts (fence, language rule, the "never decide" line). Both providers run it unchanged (it is plain text, no provider-specific syntax).

### Texts (all in `AskExplainCopy`, tested)

| Key | Text |
|---|---|
| entry | Not clear? |
| entryHelp | Ask the assistant to explain this question |
| back | Back to question |
| placeholder | Ask about this question… |
| explaining | Explaining… |
| queued | Waiting — other chats are answering. |
| errorPrefix | Couldn't explain: |
| retry | Retry |
| closedLine | This question is closed. The chat stays for reading. |
| emptyHint | The assistant reads the workbench folder and never changes it. |

## States (each has a shot)

| State | Shot | What shows |
|---|---|---|
| Entry | `ask-explain-entry` | The question view with **Not clear?** under the card |
| Queued (empty) | `ask-explain-queued` | Chat view, no rows, "Waiting — other chats are answering." (the 3-turn gate is full) |
| Loading | `ask-explain-loading` | Chat view, the live row "Explaining…" |
| Explained | `ask-explain-explained` | The explanation, the composer |
| Long | `ask-explain-long` | Several turns, scrolled to the latest |
| Busy | `ask-explain-busy` | A follow-up sent, its reply streaming, composer shows Stop |
| Error | `ask-explain-error` | "Couldn't explain: <reason>" with **Retry** |
| Closed | `ask-explain-closed` | A closed ask's chat: the closed line instead of the composer |
| Narrow | `ask-explain-narrow` | The chat in a drawer at its least width (320) |

Colours come from `Tone` and the kit; no stock chrome, no row dividers (style guide). The shots are drawn by a design-only mock (`Tests/DesignShots/DesignShotFixtures+AskExplainMock.swift`); T5 renders the same states from the built views and compares them with these.

| Entry | Explained | Busy | Error |
|---|---|---|---|
| ![](../../design/mockups/ask-explain-chat/ask-explain-entry-dark.png) | ![](../../design/mockups/ask-explain-chat/ask-explain-explained-dark.png) | ![](../../design/mockups/ask-explain-chat/ask-explain-busy-light.png) | ![](../../design/mockups/ask-explain-chat/ask-explain-error-dark.png) |

## Failure paths

| Event | What happens | Test |
|---|---|---|
| Drawer closed or another ask shown mid-turn | The engine lives in `EmbeddedChatCenter` by key; the turn's own `ai query --persist` process saves it; reopening shows the finished reply | `AskExplainSurfaceTests.testTurnOutlivesDrawer` |
| App quit mid-turn | `finishAllAsPartial` ends it `partial`; next launch shows it with Retry, no new hidden turn | `AskExplainModelTests.testPartialFirstTurnOffersRetryOnly` |
| Turn fails mid-stream (provider error, process exit) | Error row with the real text and Retry | `AskExplainModelTests.testErrorRow` |
| Two windows open the same ask's chat | One engine per key; Go's `reuse: true` returns one conversation even if both create at once | `AskExplainSurfaceTests.testSameKeySameConversation` |
| The ask is answered or withdrawn while the chat is open (phone, agent, another window) | The drawer's poll sees the status; a running turn finishes; the composer gives way to the closed line | `AskExplainModelTests.testClosedAskIsReadOnly` |
| The workbench is deleted | `db.DeleteWorkbench` also deletes its `owner_ask_explain` conversations (prefix `<id>:`, like code questions) — PROJ-02 | `TestDeleteWorkbenchDropsAskExplainChats` |
| No CLI (a host without it) | No entry is shown | `AskExplainModelTests.testNoCLINoEntry` |

**Writers of the same data.** The conversation row: `chat.new` (Desktop, find-or-create; Go dedupes). Its messages: each turn's `ai query --persist` process, and the Mac's `chat.reply.finish` / `chat.message.append` after a turn — the existing embedded chat rules, one turn at a time per key. Deletion: only `db.DeleteWorkbench`. No other writer; the ask itself is never written by this feature.

## Guards to extend

`owner_ask_explain` holds the ask's and the folder's text, so it stays out of every reader that `spec_review_thread` is kept out of: `internal/tools/chat_history.go`, `internal/kb/source_chat_artifact.go`, memory ingestion; the guard tests (`internal/tools/code_question_guard_test.go`, `internal/memory/code_question_guard_test.go`) gain the new type. The main chat's history list never shows it.

## Tasks

| # | Task | Tests |
|---|---|---|
| T1 | Go: `db.AskExplainContextType`, delete with the workbench, add the type to the history / knowledge / memory filters and their guard tests | `TestDeleteWorkbenchDropsAskExplainChats`, the extended guard tests |
| T2 | Swift Core: `AskExplainCopy`, `AskExplainPrompt`, `AskExplainKey` (context id), entry visibility (`AskExplainPresentation.showsEntry(kind:isOpen:hasChat:hasCLI:)`) | `AskExplainCopyTests`, `AskExplainPromptTests`, `AskExplainPresentationTests` |
| T3 | `AskExplainSurface` + the per-ask mode in `OwnerAsksViewModel` (`explainOpen`), the hidden first turn, Retry-only after a failed first turn, read-only on a closed ask | `AskExplainSurfaceTests`, `AskExplainModelTests` |
| T4 | Views: the entry in `OwnerAskDrawer`, `AskExplainChatView`, keys off in chat mode, Esc back | `OwnerAskDrawerKeysTests` (keys off), shots |
| T5 | DesignShotCatalog shots from the real views, compared with the mockups; guide page (`docs/guide/`) and the feature note | shots reviewed, `go test ./docs/guide` |
