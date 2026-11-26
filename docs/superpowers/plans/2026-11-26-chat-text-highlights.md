# Chat Text Highlights v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Workchat colours what the agent actually writes — inline-code hashes, refs, paths and dates, plus dates and `PR #N` / `ask #N` in prose — and any chat feed opts in with one value.

**Architecture:** Extend `AgentTextHighlights` (pure rules, `WatchtowerChatText`) with three colour-only kinds and a whole-inline-code classifier; teach `AgentTextHighlightRender` (ChatUI, macOS) to colour them without a click; replace the `highlightsAgentText` flag and the two loose actions with one public `AgentTextHighlighting` value.

**Tech Stack:** Swift 5.10 mode, SwiftUI/AppKit, Foundation `NSRegularExpression`, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-26-chat-text-highlights-design.md` (approved, ask #994). Base spec for the existing pass: `docs/superpowers/specs/2026-11-24-workchat-polish-design.md` §2.

## Global Constraints

- D3: colour on the text only — no fill, box, pill or weight; `SyntaxTint.opacity` 0.7 for every token.
- Colour only for the new kinds (`time`, `pullRequest`, `ask`): never a click, never the `agentHighlight` attribute.
- C3: a hash, ref or path in inline code clicks exactly as it does in plain text; a command as today.
- C2: AI chat and iPhone unchanged; `ChatFeedContext()` default highlights nothing.
- A path is coloured only when `resolvesPath` says yes (unchanged).
- Copied/selected text is unchanged (attributes only).
- Inline code holding more than one token (`marking_started: "2026-11-16"`) is coloured only if it is a command.
- Repo text in English; UI strings in English.
- Inner loop only per task (`make chattext-test FILTER=…`, `make chat-test FILTER=…`, `make test-swift FILTER=…`, `make lint-diff`); the full gate runs once at the end by the controller.

## Review Focus

1. A date-looking token inside a path or a version (`v2026-11-16`, `logs/2026-11-16.txt`) — the path or nothing wins, never a `time` inside a path that resolves. Test in Task 1.
2. `ask #990` / `PR #12` today click as target `#990` / `#12` — after v2 they colour as `ask`/`pullRequest` and never click. Tests in Task 1 (rules) and Task 2 (no click attribute).
3. Time look-alikes: `24:00`, `3:2`, `12:345`, `10:05:33` — only a valid `HH:MM` standing alone colours (the `10:05` of `10:05:33` does not). Test in Task 1.
4. Inline code with surrounding space or quotes (`` ` 4d434597 ` ``, `` `"2026-11-16"` ``) — trimmed/unquoted whole-token match still colours, its range covers the token only. Test in Task 1.
5. A feed without the value (AI chat) after the migration renders exactly as before, and the Workchat's existing clicks (ref → board, hash → copy, path → Files) still fire. Tests in Task 3.

---

### Task 1: Rules — new kinds and the whole-inline-code classifier

Depends on: none.

**Files:**
- Modify: `WatchtowerChatText/Sources/WatchtowerChatText/AgentTextHighlights.swift`
- Modify: `WatchtowerKit/Sources/WatchtowerDesign/SyntaxTint.swift` (add `time`)
- Modify (exhaustive switches only, to keep every package building): `WatchtowerChat/Sources/ChatUI/Platform/macOS/AgentTextHighlightRender.swift` (`color`, `accessibilityName`), `WatchtowerDesktop/Sources/Views/Workbench/WorkchatHighlights.swift` (`action(for:…)`)
- Test: `WatchtowerChatText/Tests/WatchtowerChatTextTests/AgentTextHighlightsTests.swift`

**Interfaces:**
- Produces:
  - `AgentTextHighlights.Kind` gains `case time`, `case pullRequest(Int)`, `case ask(Int)`.
  - `extension AgentTextHighlights.Kind { public var opens: Bool }` — true for `ref`, `hash`, `path`, `command`; false for the three new kinds.
  - `AgentTextHighlights.codeSpan(inCode code: String) -> Span?` — replaces `commandSpan(inCode:)` (delete it; update its callers). Order: command (today's rule), then the trimmed code — with one pair of surrounding `"` or `'` removed — as a whole: `#N` → `ref`, hash rule → `hash`, `PR #N`/`ask #N` → `pullRequest`/`ask`, date/time → `time`, path candidate (today's path rule on the whole token) → `path`. The span's range covers the token without space or quotes. Anything else → nil.
  - `SyntaxTint.time = Color.teal.opacity(opacity)`.
- Switch arms added in this task: `color`: `.time` → `SyntaxTint.time`, `.pullRequest`, `.ask` → `SyntaxTint.ref`; `accessibilityName`: `.time`, `.pullRequest`, `.ask` → `span.text` (no verb); `WorkchatHighlights.action`: the three → `.nothing`.

Rules for `spans(inPlain:)` (all skip web addresses, as today):
- `pullRequest` / `ask`: `(?i)(?<![\w])(PR|ask)\s#(\d{1,6})(?![\w])` — the span covers the whole phrase.
- `ref`: today's pattern, minus any `#N` inside a `pullRequest`/`ask` span.
- `time`: `(?<![\w.:/-])\d{4}-\d{2}-\d{2}(?![\w.:/-])` with month 01–12 and day 01–31; `(?<![\w.:/-])([01]\d|2[0-3]):[0-5]\d(?![\w.:/-]|:\d)`.
- A `time` span inside a path candidate behaves like a ref inside one: kept only when the path does not resolve (the render's `kept` already handles non-path spans; no change there).

- [ ] **Step 1: Write the failing tests** in `AgentTextHighlightsTests`:

```swift
func testPrefixedRefsAreTheirOwnKinds() {
    XCTAssertEqual(kinds("answered in ask #990"), [.ask(990)])
    XCTAssertEqual(kinds("see PR #1124 and pr #7"), [.pullRequest(1124), .pullRequest(7)])
    XCTAssertEqual(texts("ask #990"), ["ask #990"])
    XCTAssertEqual(kinds("target #12"), [.ref(12)])
    XCTAssertEqual(kinds("PR#12"), [])   // glued: not the phrase, and today's ref rule refuses `#` after a word char
}

func testDatesAndTimes() {
    XCTAssertEqual(kinds("since 2026-11-16 at 10:05"), [.time, .time])
    XCTAssertEqual(kinds("ratio 3:2, 24:00, 12:345, 10:05:33, 2026-13-01, v1.2"), [])
}

func testCodeSpanTakesTheWholeTokensKind() {
    XCTAssertEqual(AgentTextHighlights.codeSpan(inCode: "4d434597")?.kind, .hash)
    XCTAssertEqual(AgentTextHighlights.codeSpan(inCode: " #1169 ")?.text, "#1169")
    XCTAssertEqual(AgentTextHighlights.codeSpan(inCode: "\"2026-11-16\"")?.text, "2026-11-16")
    XCTAssertEqual(AgentTextHighlights.codeSpan(inCode: "ask #990")?.kind, .ask(990))
    XCTAssertEqual(AgentTextHighlights.codeSpan(inCode: "team_kpi.json")?.kind, .path)
    XCTAssertEqual(AgentTextHighlights.codeSpan(inCode: "make test")?.kind, .command)
    XCTAssertNil(AgentTextHighlights.codeSpan(inCode: "marking_started: \"2026-11-16\""))
    XCTAssertNil(AgentTextHighlights.codeSpan(inCode: "domain-kpi-v2"))
}

func testOnlyTheOldKindsOpen() {
    XCTAssertTrue([.ref(1), .hash, .path, .command].allSatisfy { (k: AgentTextHighlights.Kind) in k.opens })
    XCTAssertFalse([.time, .pullRequest(1), .ask(1)].contains { (k: AgentTextHighlights.Kind) in k.opens })
}

func testADateInsideAPathIsListedInsideTheCandidate() {
    let spans = AgentTextHighlights.spans(inPlain: "logs/2026-11-16.txt")
    XCTAssertEqual(spans.map(\.kind), [.path, .time])
}
```

(`kinds`/`texts` are small private helpers over `spans(inPlain:)`; reuse the file's existing ones if present.) Rename `testCommandSpanInInlineCode` / `testCommandSpanTrimsSurroundingSpace` to call `codeSpan(inCode:)`; their assertions stay. `testScanStepsGrowLinearlyOnALongUnspacedLine` stays and must pass unchanged.

- [ ] **Step 2: Run** `make chattext-test FILTER=AgentTextHighlightsTests > /tmp/t1.log 2>&1; echo "exit=$?"` — expect failures (no such cases / function).
- [ ] **Step 3: Implement** the kinds, `opens`, the patterns and `codeSpan(inCode:)` in `AgentTextHighlights.swift`; add `SyntaxTint.time`; add the switch arms listed above.
- [ ] **Step 4: Run** the same command → `exit=0`; then `make chat-test FILTER=AgentTextHighlightTests` and `make test-swift FILTER='WorkchatHighlights|SessionChatView'` → both `exit=0` (builds stay green, old behaviour intact).
- [ ] **Step 5: Commit** `feat(workchat): highlight kinds for dates and PR/ask refs, whole-inline-code classifier`.

### Task 2: Render — inline code by kind, colour-only kinds stay inert

Depends on: Task 1.

**Files:**
- Modify: `WatchtowerChat/Sources/ChatUI/Platform/macOS/AgentTextHighlightRender.swift` (`scan`, `apply`, VoiceOver custom actions)
- Test: `WatchtowerChat/Tests/ChatUITests/AgentTextHighlightTests.swift`

**Interfaces:**
- Consumes: `AgentTextHighlights.codeSpan(inCode:)`, `Kind.opens`, `SyntaxTint.time`.
- Produces: no new API. `apply` sets `.agentHighlight` only when `span.kind.opens`; the foreground colour always. Monospacing stays for `hash`/`path` in plain text; a code span already has its mono font. VoiceOver: a span whose kind does not open gets no custom action (find where `accessibilityName` feeds the text view's custom actions — `MarkdownTextRun.swift` ~line 612 — and filter by `opens`).

- [ ] **Step 1: Write the failing tests:**
  - `testInlineCodeHashGetsItsTintAndClick` — a run with inline code `4d434597` (`.markdownInlineCode` set) → that range has `NSColor(SyntaxTint.hash)` and an `.agentHighlight` box.
  - `testColourOnlyKindsCarryNoClick` — plain text `since 2026-11-16, ask #990` → both ranges coloured (`SyntaxTint.time`, `SyntaxTint.ref`), neither has `.agentHighlight`; the `#990` is not a `ref`.
  - `testMultiTokenInlineCodeStaysPlain` — inline code `marking_started: "2026-11-16"` → no foreground change.
  - `testVoiceOverSkipsColourOnlySpans` — custom actions list holds the hash, not the date.
  - Existing tests in the file unchanged and passing.
- [ ] **Step 2: Run** `make chat-test FILTER=AgentTextHighlightTests > /tmp/t2.log 2>&1; echo "exit=$?"` → failures.
- [ ] **Step 3: Implement** in `scan` (`codeSpan` for code pieces), `apply` (click attribute gated by `opens`) and the custom-actions filter.
- [ ] **Step 4: Run** the same → `exit=0`; `make lint-diff` clean.
- [ ] **Step 5: Commit** `feat(workchat): inline code coloured by kind; dates and PR/ask refs colour without a click`.

### Task 3: One opt-in value — `AgentTextHighlighting`

Depends on: Task 2.

**Files:**
- Create: `WatchtowerChat/Sources/ChatUI/Registry/AgentTextHighlighting.swift`
- Modify: `WatchtowerChat/Sources/ChatUI/Registry/ChatPartContext.swift` (drop `openHighlight`, `resolvesPath` from `ChatPartActions`; `highlightsAgentText: Bool` → `agentTextHighlighting: AgentTextHighlighting?`)
- Modify: `WatchtowerChat/Sources/ChatUI/Feed/ChatFeedView.swift` (`ChatFeedContext.highlightsAgentText` → `agentTextHighlighting: AgentTextHighlighting? = nil`; line ~307 passes it on)
- Modify: `WatchtowerChat/Sources/ChatUI/Parts/TextPartView.swift` (internal per-message struct renamed `MessageHighlighting`, built from `context.agentTextHighlighting`), `WatchtowerChat/Sources/ChatUI/Platform/macOS/MarkdownTextRun.swift` (follow the rename)
- Modify: `WatchtowerDesktop/Sources/Views/Workbench/SessionChatRow.swift` (`WorkchatFeed.onHighlight` + `resolvesPath` → `highlighting: AgentTextHighlighting?`; `context()` sets `context.agentTextHighlighting = highlighting`), `SessionChatView.swift`, `SessionChatSubagentView.swift`, `WorkchatHighlights.swift` (delete `WorkchatHighlightHandlers`; `highlightHandlers()` returns `AgentTextHighlighting`; the `workchatHighlightProbe` entry takes it)
- Modify tests: `WatchtowerChat/Tests/ChatUITests/AgentTextHighlightTests.swift`, `WatchtowerDesktop/Tests/SessionChatViewTests.swift`, `WatchtowerDesktop/Tests/ReviewAgentChatTests.swift`, `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+WorkchatHighlights.swift`

**Interfaces:**
- Produces:

```swift
public struct AgentTextHighlighting {
    /// Whether a path candidate of the message (by id) is a file of the session's folders; nil colours no path.
    public var resolvesPath: ((_ path: String, _ messageID: Int64) -> Bool)?
    /// A click on a span that opens (`Kind.opens`); nil keeps every span colour-only.
    public var openHighlight: ((_ span: AgentTextHighlights.Span, _ messageID: Int64) -> Void)?
    public init(resolvesPath: ((String, Int64) -> Bool)? = nil,
                openHighlight: ((AgentTextHighlights.Span, Int64) -> Void)? = nil)
}
```

- [ ] **Step 1: Update the tests first:** `testOnlyTheAgentsTextInAHighlightingFeed` and `testAFeedPassesItsFlagToThePartContext` use `agentTextHighlighting`; `ChatFeedContext().agentTextHighlighting == nil` replaces the default-flag assertion; new `testAnEmptyValueColoursWithoutPathsOrClicks` — `AgentTextHighlighting()` on an assistant message: a hash is coloured, a path candidate is not, no `.agentHighlight`. `SessionChatViewTests` (~line 160–175) and `ReviewAgentChatTests` (~194) read `context.agentTextHighlighting?.resolvesPath` / `.openHighlight` with the same expectations as today.
- [ ] **Step 2: Run** `make chat-test FILTER=AgentTextHighlightTests` → fails to compile.
- [ ] **Step 3: Implement** the type and the migration across the files above; no behaviour change for the Workchat.
- [ ] **Step 4: Run** `make chat-test FILTER=AgentTextHighlightTests`, `make test-swift FILTER='SessionChatView|ReviewAgentChat|WorkchatHighlights|DesignShot'` → `exit=0`; `make lint-diff` clean; `grep -rn "highlightsAgentText\|WorkchatHighlightHandlers" WatchtowerChat WatchtowerDesktop --include=*.swift` → nothing.
- [ ] **Step 5: Commit** `refactor(chat): one AgentTextHighlighting value turns agent-text highlighting on for a feed`.

### Task 4: Shot fixture and docs

Depends on: Task 3.

**Files:**
- Modify: `WatchtowerDesktop/Tests/DesignShots/DesignShotFixtures+WorkchatHighlights.swift` (sample text gains `` `4d434597` ``, `2026-11-16`, `ask #990`, `PR #1124`; neutral content)
- Modify: `docs/design/desktop-style-guide.md` (`SyntaxTint` row: add `time` teal; note dates and PR/ask refs use `time`/`ref`)
- Modify: `docs/features/session-chat-feed.md` (highlighting section: inline code by kind, new kinds colour-only, `AgentTextHighlighting` opt-in) and its summary line in `docs/features/README.md`
- Modify: the Workchat page under `docs/guide/` (find with `grep -rln "Workchat" docs/guide`), following `docs/guide/WRITING.md`

- [ ] **Step 1:** Update the fixture; run `make desktop-shots DESKTOP_SHOTS=<scratch dir>` and look at the Workchat highlights shot (light and dark): hashes in code purple, the date teal, `ask #990` accent, branch plain.
- [ ] **Step 2:** Update the docs; `go test ./docs/guide/...` (guide tests) → `exit=0`.
- [ ] **Step 3:** Attach the dark and light shots to target #1169 (`update_target add_images`).
- [ ] **Step 4: Commit** `docs(workchat): highlight kinds v2 — style guide, feature note, guide, shot fixture`.
