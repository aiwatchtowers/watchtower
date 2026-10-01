---
type: idea
title: Chat history list needs a modern visual design
status: open
priority: med
tags: [desktop, chat, ui, design, sidebar]
context: docs/chat-projects-vision — backlog collection session, item 2 (owner screenshot of the Chats column, dark mode)
created: 2026-09-30
---

The main AI Chat's history column (`WatchtowerDesktop/Sources/Views/Chat/ChatSidebarView.swift`,
grouping from `ChatHistoryGrouping`) works, but looks dated — "like the 90s".
What the owner's screenshot shows:

- a full-width hairline separator under every row and every section header,
  so the column reads as a spreadsheet, not a sidebar;
- section headers (Projects / Today / Yesterday / Previous 7 Days) are grey
  bands in regular weight, and the Projects header has its own darker/brownish
  band that does not match the rest;
- rows are one flat line of truncated title text at a large size, no icon,
  no secondary info, no inset, square full-width selection highlight;
- the big bold "Chats" title plus the compose icon take a lot of room.

Direction (to be designed properly, then built):

- no row separators; rows as inset rounded "pills" with a soft hover state and
  a rounded selection highlight (the Claude / ChatGPT / Apple Notes sidebar
  feel), consistent with the app's main `SidebarView`;
- quieter section headers: small, secondary colour, no background band,
  generous spacing above instead of lines;
- slightly smaller title font; optional secondary line or trailing relative
  time ("2h", "Mon") and a pin glyph for pinned chats; a spinner/dot for a
  chat whose turn is still running;
- Projects rendered as their own collapsible group with a folder icon and
  chat count, not as a banded header;
- light and dark mode both, background stays `windowBackgroundColor`
  (do not regress the wallpaper-tint fix).

Worth doing as a small design pass first (mockup of 2–3 options) before
touching code. Related: [[2026-09-28-chat-history-sidebar-turned-brown]],
[[2026-09-28-chat-landing-instead-of-history-sidebar]] (the landing's recent
chats list should share the same row style).

> Original note: «дизайн нуже номальный. Список чатов как из 90х» (with screenshot)
