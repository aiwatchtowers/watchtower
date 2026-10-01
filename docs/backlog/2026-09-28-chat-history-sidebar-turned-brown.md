---
type: bug
title: Chat history sidebar renders with a brown background
status: done
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

Resolution: confirmed the second hypothesis. `ChatSidebarView`'s history `List`
used `.listStyle(.sidebar)` while sitting in a plain `HStack` inside
`ChatView.swift`'s `ChatSplitView` — not the leading column of a real
`NavigationSplitView`. `.sidebar` requests the system source-list vibrancy
material, which outside its intended split-view context renders tinted by
the desktop wallpaper instead of the app's own dark chrome (the same failure
mode `IdeasView.swift`'s `listPanel` comment already documents, there fixed
by dropping `List` entirely). For this plain title-row history list, switched
to `.listStyle(.plain)` + `.scrollContentBackground(.hidden)` +
`.background(Color(nsColor: .windowBackgroundColor))`, matching the same
`.windowBackgroundColor` background the app's hand-rolled `SidebarView` uses,
so both sidebars now agree regardless of wallpaper/accent settings. Selection
binding, section headers, and context menus are unchanged. Purely a SwiftUI
styling fix with no pure logic to pin in a unit test; verified via
`swift build --target WatchtowerDesktop` (clean) and `swiftlint lint` on the
changed file (0 violations) — visual confirmation under a real wallpaper-tinted
window is left to manual QA.

Follow-up (2026-09-30): the Projects tab's list, board tree and documents
list had the same cause — a `List` in an `HSplitView` column with
`.listStyle(.sidebar)` or the automatic style, which resolves to the same
source-list material there. The fix is now one shared modifier,
`View.panelListStyle()` (`Views/Components/PanelListStyle.swift`), used by
the chat history and all three Projects lists. `MemoryView`'s two lists
still use `.listStyle(.sidebar)` inside an `HSplitView` and are the next
candidates if the Memory tab shows the same tint.
