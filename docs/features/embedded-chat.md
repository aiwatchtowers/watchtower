# Embedded assistant chats — shared component (2026-10-01)

Spec: `docs/superpowers/specs/2026-10-01-shared-chat-component-design.md`. Plan: `docs/superpowers/plans/2026-10-01-shared-chat-component.md`. Board: #168.

Every assistant chat outside the main AI Chat (target, track, idea/decision, meeting, calendar/email setup) runs on one engine and one view built from the main chat's pieces. The backend is unchanged: one `watchtower ai query` per turn through `WatchtowerAIService.stream`. The warm `ai session` v2 protocol and `ChatSessionPool` remain main-chat only.

**Migration status:** complete. The infrastructure and the main chat's move onto `ChatFeedView`/`ChatComposerBar` landed with #170. Then:
- track, idea/decision and meeting (#172–#174) as `TrackChatSurface`/`IdeaChatSurface`/`MeetingChatSurface` in `Sources/Services/ChatSurfaces/`;
- target (#171), with `TargetChatViewModel` as the task controller around its tab's engine;
- onboarding (#175) ran on a memory engine until onboarding v2 removed the interview (2026-10-03);
- calendar/email setup (#176) as `SetupAssistantChat<Snapshot, Patch>` with one `SetupAssistantPanel`.

`MessageBubble` is deleted, and the old `ChatInput` is now `ChatComposerField`, the field inside `ChatComposerBar` and the only text input of every chat (#177).

## Pieces

| Piece | Where | Role |
|---|---|---|
| `ChatSurfaceSpec` | `WatchtowerCore/Services/Chat/Embedded/` | A value that describes one chat: key, persistence (`.database` / `.memory`), **explicit** `toolAccess` (`.draftOnly` or `.actions(surface:)`, AGENT-04), system prompt (first turn only), per-turn prompt, `postTurn`, empty hint, starter prompts, and `runOptions` (provider, model, `--read-folder`; read when each turn starts, default all nil = config's provider at its strong tier). |
| `EmbeddedChatStore` | same | Database store (the existing `chat_messages` columns, no migration) or memory store (negative synthetic ids). Every write throws. |
| `EmbeddedStreamReducer` / `AIStreamText` | same | The single fold of `.text` / `.turnComplete` / `.reset` / `.sessionID` / `.error`. |
| `EmbeddedChatEngine` | same | Owns the stream loop. Writes the owner row and the reply's `partial` placeholder before the process starts. Streams into a `LiveTurn` (render isolation). Flushes the text at most once per second. Ends each turn exactly once as `complete` (then `postTurn`), `partial` (Stop or quit) or `error` (with the real text and an error code). Also handles follow-ups, hidden prompts, local rows and Retry. |
| `EmbeddedStreamGate` | same | At most 3 embedded turns run at once. Later ones queue FIFO. A queued owner text is mirrored to `UserDefaults` and comes back as a draft after a restart. |
| `EmbeddedChatCenter` | same, instance at `AppState.embeddedChatCenter` | Holds one engine per key. A 60 s sweep releases engines that are idle and have been hidden for 5 min. `dropContext` (on delete) stops quietly. `release` (sheet or window closed). `finishAllAsPartial` runs on quit. |
| `ChatFeedView`, `ChatComposerBar` | `Views/Chat/` | Extracted from the main chat (follow-scroll feed, composer with a status line and an accessory slot). The main chat renders through them too. |
| `EmbeddedChatView` / `EmbeddedChatRows` / `EmbeddedChatComposer` | `Views/Chat/Embedded/` | `ChatMessageRow` with `ChatRowActions.embedded` (Copy, plus Retry on the last failed reply) and `LiveAssistantRow`. Slots: `accessory(for:)` and `footer`. `density` is `.regular` or `.compact`. Use the rows/composer split when the chat sits inside its pane's scroll. |

## Question cards (#182)

A reply may end with a ```watchtower-question JSON block. The Go prompt's `QuestionsContract()` and the embedded prompts' `ChatQuestionsContract.promptBlock` carry the same text (`internal/chat/questions_contract.md`, pinned by `ChatQuestionsContractFixtureTests`). `AssistantMessageBody` renders the block as `ChatQuestionCardView`:
- `ChatQuestionParser` reads the block. A malformed block stays plain text, and an open block is hidden while the reply streams.
- The answers go out as the owner's next message, formatted by `ChatQuestionAnswer.format`. They can be given only on the latest reply, while nothing runs.
- An answered card reads its selections back from that message, so nothing new is stored.
- Copy and Quote take the reply as a person reads it (`ChatQuestionParser.readableText`): the prose, then each question and its options as plain lines, never the raw JSON.
- An answer sent from the main chat (`send(…, keepsComposer: true)`) leaves the composer's own draft, @-mentions and skill alone.

See spec `docs/superpowers/specs/2026-10-02-chat-question-card-design.md`.

## Contracts

- A draft-only surface never sends a `toolMode`. Only the target spec uses `.actions("target")`, and only when the provider is not ollama.
- `postTurn` runs only for a completed turn. A stopped or failed reply is never parsed (no half-streamed directive is ever applied).
- Owner text is on disk before a turn is sent. If that write fails, nothing is sent and the text goes back to the composer. A `TargetBriefCenter` brief that never starts (that write failed, or the chat was busy) also lands in the target chat's composer, after any owner draft.
- A completed reply whose final save fails is an `error` turn that can be retried. `postTurn` reports what it already wrote (`ChatPostTurnResult.applied`), and the error text names it ("Already applied: …"). The engine keeps that list (it outlives the tab until the center's idle sweep releases the engine) and hands it back only to a Retry (`ChatTurnInput`/`ChatPostTurnInput.alreadyApplied`); the next owner message starts clean. On Retry the target chat tells the model those changes are done and does not apply a matching execute-mode action again (`ProposedAction.changeKey`: the payload without `reason`/`mode`); its card reads "already applied before the retry". If even the error row cannot be written, the row stays `partial` and reads "Not saved" with Retry, and the message says to retry now (Retry lives in memory, on the engine). A Retry that fails the same way keeps the earlier attempt's changes in its list.
- Errors: the error card (`ChatErrorPresentation`) shows a hint by kind (`EmbeddedChatErrorClassifier`) over the provider's own text. The `ai query` v1 `error` line now arrives as `StreamEvent.error`. Chats not yet migrated fold it back into `[Error] …` text (`foldingErrorIntoText`).
- Stop terminates `ai query`. SIGTERM → `notifyShutdownContext` → SIGINT to the provider child (SIGKILL after 5 s).
- CHAT-04 (content off argv) still covers only the main chat. Embedded chats keep `ai query` with the prompt on argv, as before.

## Limits

- The target's action cards are still memory-only.
- `TargetBriefCenter` runs count against the 3-turn limit.
- Onboarding and the setup assistants own their (memory) engines directly: the window or sheet is their lifetime. They share the app's turn gate (`appState.embeddedChatCenter.gate`), and have no draft mirror, so nothing of theirs survives a restart.
