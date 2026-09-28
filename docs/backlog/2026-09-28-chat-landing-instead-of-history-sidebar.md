---
type: idea
title: Chat landing page instead of an always-open history sidebar
status: open
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

Open questions for the owner: the exact resume timeout; whether a running
(streaming) turn always forces resume regardless of the timeout (probably
yes); how this interacts with warm-session prewarm on open (the landing's
composer could prewarm a fresh session on first keystroke, like today).

Related: [[2026-09-28-chat-history-sidebar-turned-brown]].

> Follow-up note (with screenshot): «фотка чтобы фолоуапнуть предыдущий»

> Original note: «чаты по умолчанию скрыть, а то аляповато как-то. При заходе на страницу вывести список последних и окно начать новый. Текущий активный какое то время открывается по умолчанию»
