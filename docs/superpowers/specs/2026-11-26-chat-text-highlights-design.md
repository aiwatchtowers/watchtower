# Chat text highlights v2 — design

**Status:** draft, 2026-11-26, round 2. Size: a small change (short design). Extends the
Workchat's agent-text highlighting (spec `2026-11-24-workchat-polish-design.md` §2, D3, C1,
C2; `AgentTextHighlights`, `AgentTextHighlightRender`, `WorkchatHighlights`, `SyntaxTint`).

## Intent

The owner looked at a Workchat feed and found almost nothing coloured. The cause is not the
palette: the agent puts hashes, file names, branches and dates in inline code (`` `4d434597` ``,
`` `team_kpi.json` ``), and today's highlighter reads inline code only for a command
(`AgentTextHighlights.commandSpan(inCode:)`). Those spans render monospaced but in the plain
text colour, which is what the screenshot shows. A few common spans (dates, `PR #N`, `ask #N`)
have no kind at all, and `ask #990` is even coloured and clicked as target `#990`.

v2 colours what the agent actually writes, and turns the Workchat-only switch into one any chat
feed sets with one line, so other chats can opt in later.

## Goals

- Inline code that is, as a whole, a hash, a ref, a resolving path or a date takes that kind's
  colour (as a command already does).
- New colour-only kinds: a date or time; a `PR #N` / `ask #N` reference.
- `ask #N` and `PR #N` stop being target refs (no "Show on the board" for a wrong id).
- One opt-in value on `ChatFeedContext` replaces the `highlightsAgentText` flag plus the
  separate `resolvesPath` action.

## Non-goals

- Turning highlighting on in the AI chat or on the iPhone: C2 stands for v2; each is a later
  one-line opt-in plus, for the phone, its renderer (target to be filed).
- Clicks on the new kinds (owner, ask #990: colour only). Existing clicks (ref → board, hash and
  command → copy, path → Files) stay as they are.
- Status words ("green", "not sure") and durations — C1 keeps them out.
- Branch names (`domain-kpi-v2`): a branch has no shape of its own — it reads like any
  hyphenated word (`read-only`, `follow-up`) — so a rule would colour prose or nothing.
- Task numbers ("Task 3", «задача 3», `A1a`): Russian inflects the word (задачу, задаче) and a
  bare `A1a` is indistinguishable from any short id; left out rather than guessed.
- Colouring a path that does not resolve in a session folder: the resolution rule stays.
- A background plate under inline code on the Mac (see Decisions, Q2).

## Approaches

- **A — extend the existing pass (picked, ask #991, refined).** Ask #991 approved "mark the
  rendered inlines in `WatchtowerChatText`, colour per platform". That pass already exists as
  `AgentTextHighlights` + `AgentTextHighlightRender`; v2 extends it instead of building a second.
- B — wrap matches in `` `code` `` in the markdown text. Everything looks like code. Rejected.
- C — a second highlighter beside the existing one (round 1 of this spec). Two palettes and two
  rule sets for the same spans, both running in the Workchat. Rejected by the spec review.

## Design

**Rules (`AgentTextHighlights`, `WatchtowerChatText`).**

| Kind | Plain text | Whole inline code | Click |
|------|------------|-------------------|-------|
| `ref(N)` | `#N` not preceded by `PR` / `ask` (today's rule otherwise) | `#N` | board (as today) |
| `hash` | as today | 7–40 hex, one digit and one letter | copy (as today) |
| `path` | as today, kept when it resolves | a path candidate, kept when it resolves | Files (as today) |
| `command` | — | as today | copy (as today) |
| `time` (new) | `YYYY-MM-DD`, `HH:MM` (00–23:00–59), alone | the same, alone or quoted (`"2026-11-16"`) | none |
| `pullRequest(N)`, `ask(N)` (new) | `PR #N`, `ask #N`, case-insensitive, the whole phrase | the same | none |

`spans(inPlain:)` gains the new kinds; `commandSpan(inCode:)` becomes `codeSpan(inCode:)`, which
returns the one kind the whole code span is, command first. A hash, ref or path in inline code
takes the same click it has in plain text (copy, board, Files): the agent's choice of backticks
should not change what a span does (author's call, C3 below). Inline code that holds more than
one token (`marking_started: "2026-11-16"`) is only coloured if it is a command, as today.

**Colours (`SyntaxTint`).** One new token, `time`, foreground at the same `opacity` 0.7 (D3:
no fill, box or weight). `pullRequest` and `ask` use `ref`. The style guide's token table gains
the row. Hashes and paths keep their monospaced design; a code span keeps its own font.

**Render (`AgentTextHighlightRender`, Mac).** The scan reads a whole inline-code piece with
`codeSpan(inCode:)`; the new kinds colour without the click attribute; VoiceOver names them
("PR #12", "ask #990", the date) with no action.

**Opt-in.** `ChatFeedContext.highlightsAgentText: Bool`, its copy
`ChatPartContext.highlightsAgentText` and `ChatPartActions.resolvesPath` become one value,
carried from the feed context into the part context (one source of truth):

```swift
public struct AgentTextHighlighting {           // ChatUI
    public var resolvesPath: ((String, Int64) -> Bool)?   // nil: paths are never coloured
    public var onSpan: ((AgentTextHighlights.Span, Int64) -> Void)?  // nil: colour only
}
ChatFeedContext.agentTextHighlighting: AgentTextHighlighting?   // nil: off (default)
```

Every place that sets the flag or the resolver today moves to the value, with
`WorkchatHighlights` as before: `SessionChatView`, `SessionChatRow`, the subagent feed
`SessionChatSubagentView`, the shot fixture `DesignShotFixtures+WorkchatHighlights`, and the
tests that build them (`SessionChatViewTests`, `ReviewAgentChatTests`,
`AgentTextHighlightTests`). No other surface changes in v2. A chat that opts in
later writes one line, `context.agentTextHighlighting = AgentTextHighlighting()`, and gets
refs, hashes, commands, dates, PR and ask refs coloured, without clicks or paths.

**Mockup.** Before: the owner's screenshot (target #1169). After (`[h]` hash purple, `[t]` time
new token, `[r]` ref accent, `⟦…⟧` inline code):

```
Дизайн и план закоммичены в ветку ⟦domain-kpi-v2⟧ (⟦[h]4d434597⟧).
 • ⟦[h]75e1e176⟧: общие тестовые хелперы вынесены…
 • ⟦[h]f5df21ff⟧: ⟦marking_started: "2026-11-16"⟧, отдельным коммитом.   ← two tokens: plain
Отметка с [t]2026-11-16, ответ в [r]ask #990, PR [r]#1124 → [r]PR #1124.
```

The as-built screen is shot with `make desktop-shots` from `DesignShotFixtures+WorkchatHighlights`
(its sample text gains inline-code hashes, a date and `ask #N`) and attached to the target
before review; this spec does not add a screen or a state.

## Decisions

| # | Decision | By |
|---|----------|----|
| D1 | Colour only for the new kinds, no clicks | owner, ask #990 |
| D2 | Extend the existing pass rather than build a new one | owner, ask #991 (refined after the spec review) |
| D3' | Workchat-polish D3 (no fill, box, weight; opacity 0.7) holds; one new token `time` | author's call, from D3 |
| C1' | v2 adds dates and PR/ask refs to C1's kinds; status words, durations, branches, task numbers stay out | author's call, pending owner approval of this spec |
| C2' | C2 stands: AI chat and iPhone unchanged in v2; the opt-in becomes one value | author's call, pending owner approval of this spec |
| C3 | A hash, ref or path in inline code clicks as it does in plain text; new kinds never click | author's call, pending owner approval of this spec |
| Q2 | No Mac inline-code plate: it is a fill D3 rules out. If the owner wants it, it becomes its own target | author's call, pending owner approval of this spec |

The owner's approval of this spec's review ask approves C1', C2', C3 and Q2. If it is declined,
nothing changes and the work stops at this spec.

## Failure paths

The scan is pure and cannot fail at run time; a bad pattern is a test failure. A false positive
only colours a word; a new kind never clicks. A path lookup keeps today's behaviour
(`WorkchatHighlights`: off main, stamped, re-asked). The scan stays linear (the existing
`steps` test covers the new patterns). A surface with `agentTextHighlighting == nil` renders
exactly as before.

## Tests

- `AgentTextHighlightsTests` (`WatchtowerChatText`): each table row's plain and inline-code
  column, both matching and not (`3:2`, `v1.2`, `24:00`, `issue#12`, `PR#12` glued,
  `ask #990` not a `ref`); multi-token code stays uncoloured; the existing cases unchanged.
- `AgentTextHighlightTests` (ChatUI): an inline-code hash gets `SyntaxTint.hash` and the copy
  click; a `time` span gets the colour and no `agentHighlight` click attribute; a context with
  `agentTextHighlighting == nil` adds no attribute; the existing Workchat cases unchanged.
- Workchat (`WorkchatHighlights` tests): the migration to `AgentTextHighlighting` keeps the
  ref/hash/command/path actions.

## Docs

`docs/features/session-chat-feed.md` (highlighting section) and its README summary; the style
guide's `SyntaxTint` row; the Workchat page of `docs/guide/` mentions dates and PR/ask refs.

## Left to the builder

Exact regexes within the table, VoiceOver wording, the `time` hue within the style guide.
