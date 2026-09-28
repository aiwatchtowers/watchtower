---
type: idea
title: Chat landing page instead of an always-open history sidebar
status: done
priority: med
tags: [desktop, chat, navigation, ux]
context: fix/settings-storage-size-off-main — owner feedback on the redesigned main AI Chat layout
created: 2026-09-28
---

The redesigned main AI Chat shows its history sidebar (Projects / Today /
Previous 30 Days / Older) permanently, which feels cluttered. Proposed layout:

- **History sidebar hidden by default.** Still reachable via the existing
  sidebar toggle and ⌘K search; the owner's show/hide choice is remembered.
- **Landing view on entering the Chat tab:** a "start a new chat" composer
  front and centre plus a short list of the most recent conversations (and
  pinned ones) to jump back into.
- **Resume window:** if the owner left an active conversation recently, the
  tab reopens straight into it instead of the landing. After an idle period
  (to decide — e.g. 15–30 min without activity in that conversation) the next
  visit lands on the landing view again.

Current layout (owner screenshot): three columns at once — the app's main
navigation sidebar, the Chats history column (brown background, see the
related finding), and the conversation itself. The history column takes ~a
quarter of the window width and competes with the main sidebar for attention;
there are also two separate sidebar toggles (app sidebar top-left, chat
history in the conversation header). The ask is to drop to two columns by
default (app sidebar + conversation / landing), with history as an opt-in
column.

**Owner decision (2026-09-28):** resume window = **2 hours** since the last
activity in that conversation; a still-streaming turn always resumes.

Open questions for the owner (resolved above: timeout): the exact resume timeout; whether a running
(streaming) turn always forces resume regardless of the timeout (probably
yes); how this interacts with warm-session prewarm on open (the landing's
composer could prewarm a fresh session on first keystroke, like today).

Related: [[2026-09-28-chat-history-sidebar-turned-brown]].

> Follow-up note (with screenshot): «фотка чтобы фолоуапнуть предыдущий»

> Original note: «чаты по умолчанию скрыть, а то аляповато как-то. При заходе на страницу вывести список последних и окно начать новый. Текущий активный какое то время открывается по умолчанию»

Resolution: the Chat tab now opens on a landing (`ChatLandingView`: greeting,
the existing `ChatComposerView`, starter prompts, pinned + recent chats) or
resumes the last conversation, decided by the pure, clock-injected
`ChatLandingPolicy.decide` in WatchtowerCore: resume within 2 h of the last
activity (the later of the last stored message and the last time it was on
screen), exactly 2 h is outside, a running turn always resumes, and a
missing/archived/message-less conversation lands. The history column is
hidden by default and its visibility is remembered (`@AppStorage
"chat.historyVisible"`); ⌘K works with it closed. ⌘N/New Chat go to the
landing; the landing's first keystroke creates the conversation and prewarms
its session without leaving the landing, and its first turn switches to the
thread. Pinned by `ChatLandingPolicyTests` (Core) and
`ChatLandingViewModelTests`.
