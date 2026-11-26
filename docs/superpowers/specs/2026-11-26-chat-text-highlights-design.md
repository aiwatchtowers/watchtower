# Chat text highlights — design

**Status:** draft, 2026-11-26. Size: a small change (short design).

## Intent

A session agent's chat messages are long prose with almost no markup: commit hashes, file
paths, board references and dates sit in plain body text, so the eye has nothing to catch on.
Watchtower should colour these spans on its own, without the agent marking them up. The
highlighter is a module any chat surface switches on with one line; the session chat feed and
the main AI chat get it first, every other chat later.

## Goals

- Colour-only highlights (owner's call): no links, no click actions, no new menus.
- One rule set shared by the Mac and the iPhone; one place to add a rule.
- A surface opts in with one modifier; a surface that does not is unchanged.
- Inline code on the Mac gets the background plate the iPhone already draws.

## Non-goals

- Clickable spans (commit → diff, `#N` → target, path → file). Not wanted now.
- Status-word sentiment ("tests green" in green, "not sure" in amber): a noisy two-language
  heuristic; a later iteration if wanted.
- Highlighting inside code blocks (they keep `CodeHighlighter`), inline code, links or
  headings' existing styling.
- Changing what the agent writes (bolding its outcome is a separate prompt target, #1170).

## Anti-goals

- Copied or quoted text changes: highlights are attributes only, the characters stay as written.
- Rainbow text: at most three tones; a false positive must look harmless.
- A scroll or streaming slowdown (`ChatScrollBenchmarkTests`, `TextRenderingBenchmarkTests`
  stay within their current bounds).

## Approaches

- **A — mark the rendered inlines in `WatchtowerChatText` (picked, ask #991).** A rule set
  ("regex → kind") marks spans of plain text with a highlight attribute; each platform maps a
  kind to a colour. Shared, memoised with the existing inline memo.
- B — rewrite the markdown text, wrapping matches in `` `code` `` (as `CodeLineLinks` does).
  No renderer change, but every match looks like code and sentiment can never fit. Rejected.
- C — colour the final `AttributedString` per platform. Rules duplicated on the Mac and the
  iPhone, harder to keep off code and links. Rejected.

## Design

**Module (`WatchtowerChatText`, Foundation only).**
- `ChatHighlightKind` (`identifier`, `reference`, `time`) and an `AttributedStringKey`
  `chatHighlight` carrying it.
- `ChatHighlightRule` — a compiled regex and a kind; `ChatHighlights` — a named, `Hashable`
  set of rules, with `.none` and `.standard`.
- `ChatHighlighter.mark(_ text: inout AttributedString, with: ChatHighlights)` — runs the
  rules over the runs that carry no `.code` intent and no link, and sets `chatHighlight` on
  each match. First rule wins on an overlap. Pure.
- Marking happens inside the existing `MarkdownInlineRenderer.memoized` build; the rule set's
  name joins the memo context, so a hit costs nothing extra.

**Rules in `.standard`.**

| Kind | Matches | Leaves alone |
|------|---------|--------------|
| `identifier` | a commit hash: 7–40 hex chars with at least one digit and one letter, a whole word (`4d434597`) | words, numbers, hex inside a longer token |
| `identifier` | a path with a `/` and a file part (`.superpowers/sdd/x/progress.md`, `cmd/run.go`), or a file name with a lowercase 1–5 letter extension and a `_` or `-` in the name (`team_kpi.json`) | web addresses, `example.com`, versions (`v1.2`), mail addresses |
| `reference` | `#N`, `PR #N`, `ask #N`, `target #N` | `#` not followed by digits, headings |
| `time` | `YYYY-MM-DD`, `HH:MM` | ratios (`3:2`), versions |

A builder may tune a pattern against the test cases; adding a kind is a design change.

**Colours (`WatchtowerDesign`).** One token per kind, light and dark, following
`docs/design/desktop-style-guide.md`: `identifier` a muted teal, `reference` the accent,
`time` the strong secondary label. Font and weight do not change.

**Renderers.**
- Mac, `MarkdownTextRun.appendInlines` (NSTextView path): `chatHighlight` → foreground
  colour; inline code (`.code` intent) → background plate (`Fill.card` equivalent).
- Mac, `MarkdownView` SwiftUI `Text` path (tables, lists outside runs): the same mapping,
  applied to the `AttributedString` before `Text`.
- iPhone, `MarkdownRuns.inline`: `chatHighlight` → foreground colour (plate already exists).

**Opt-in.** An environment value `\.chatHighlights` (default `.none`), read by
`MarkdownBlocksView` / `MarkdownTextRun` and the iPhone runs, and carried in
`InlineLinkContext` (the memo context). v1 sets `.standard` at the session chat feed
(`SessionChatRow`, `PeerBubbleCard`), the main AI chat feed and the iPhone chat feed. Another
chat opts in with `.chatHighlights(.standard)`.

**Mockup** (owner's screenshot is the "before"; `[i]` identifier, `[r]` reference, `[t]` time):

```
Реализация началась. Дизайн и план закоммичены в ветку ⟦domain-kpi-v2⟧ ([i]4d434597).
Задача 1 готова, два коммита:
 • [i]75e1e176: общие тестовые хелперы вынесены…
 • [i]f5df21ff: ⟦marking_started: "[t]2026-11-16"⟧, отдельным коммитом.
Прогресс записываю в журнал [i].superpowers/sdd/2026-11-26-domain-kpi-v2/progress.md.
Вопрос — в ask [r]#990, таргет [r]#1169.
```
`⟦…⟧` = inline code, now on a plate on the Mac too (its contents are not re-coloured).

## Failure paths

The highlighter is pure and cannot fail at run time; a bad pattern is a test failure. A false
positive only colours a word. Performance is covered by the existing benchmarks plus one case
in `ChatHighlighterTests` timing a long paragraph.

## Tests

- `WatchtowerChatText`: one test per rule row above, both columns, using the screenshot's
  sentences (neutral placeholders); overlap; code and link runs untouched; characters
  unchanged after marking; `.none` marks nothing.
- ChatUI (Mac): a run with a highlight gets the token colour; inline code gets the plate; a
  surface without the modifier renders as before.
- iPhone: `MarkdownRuns.inline` colours a highlight.

## Docs

A feature note `docs/features/chat-text-highlights.md` (+ CLAUDE.md line, README summary);
the chat page of `docs/guide/` mentions the colours.

## Left to the builder

Exact regexes, token colour values within the style guide, where the environment value is
read inside `MarkdownBlocksView`.
