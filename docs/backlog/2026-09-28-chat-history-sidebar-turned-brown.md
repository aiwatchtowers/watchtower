---
type: bug
title: Chat history sidebar renders with a brown background
status: open
priority: low
tags: [desktop, chat, ui, theme, regression]
context: fix/settings-storage-size-off-main — owner screenshot of the main AI Chat, dark mode
created: 2026-09-28
---

The main AI Chat's left history panel ("Chats": Projects / Today / Previous 30
Days / Older) now renders with a solid brown background instead of the neutral
dark sidebar color used everywhere else. It used to look normal, so this is a
regression — likely since the chat redesign (PR #4) or a later change.

Hypotheses to check first:
- an explicit `.background(...)` / tint on the history list picking up an
  accent or a hard-coded color instead of the system sidebar material;
- a sidebar `Material`/vibrancy that tints from the desktop wallpaper
  (macOS "Allow wallpaper tinting in windows") — would explain "used to be
  fine" if the wallpaper changed; if so, pin the panel to the same material
  and background as the app's main sidebar;
- the selected-row highlight color leaking into the whole list background.

Expected: the history panel matches the app's standard sidebar in both light
and dark mode, regardless of wallpaper.

> Original note: «какого-то хуя покрасилась в другой цвет панель. Причем раньше была нормальная»
