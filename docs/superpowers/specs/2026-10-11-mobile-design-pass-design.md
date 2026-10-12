# Mobile design pass: the iPhone app restyled after the Mac (design)

**Date:** 2026-10-11
**Status:** proposed. The owner's decisions (ask #32, 2026-10-11) are binding and listed in §1. The style reference is the Mac app (ask #30).
**Amends:** `docs/superpowers/specs/2026-10-07-mobile-poc-design.md` §14 (Visual language) and the tab list of §13 A4 (More goes). Nothing else in that spec changes.
**Inputs:** screenshots from the design review (2026-10-11) of 35 screens in light and dark mode, rendered from the demo seed (Acme workbench, "Acme Mac"), with per-screen findings tagged bug / fix / idea / keep. Shot numbers below (01–35) are the tour's screen numbers (§6.2).

File:line references are against the branch `feature/mobile-poc-design` at `10e2407e`. Paths are relative to `WatchtowerMobile/Sources/` unless they start with another top-level directory.

---

## 1. Goal and binding decisions

The iPhone app works, but it looks hand-built: cards with radii 8, 10 and 14, cards inside cards, three pill recipes, status icons and colours that differ from the Mac's, and eleven layout bugs. This pass makes the phone look like the Mac app on a phone. It adds no features and changes no data.

Binding decisions (ask #32):

1. **Direction A, "Mac one-to-one".** Dense flat rows like the Mac's target list: the status icon on the left, a priority dot, one meta line. Cards are used only for "Waiting for you" and for detail blocks (the next meeting, a session report, a notice). No card inside a card.
2. **Priority: medium has no dot.** Only high (red) and low (blue) get a dot. The Mac also marks medium in orange. The phone does not, because:
3. **The orange rule stays.** Orange is only for waiting-for-you and ask elements (SwiftLint `orange_outside_phone_tone`, `OrangeToneTests`). This pass extends the rule (§2.1) and never relaxes it.
4. **The More tab goes.** Settings becomes a gear in Now's toolbar. The voice note keeps its existing entry, the Calendar's mic button (§5).
5. **Order.** Phase 1 builds the design layer and fixes the 11 bugs. Phase 2 does Now and Workbench. Phases 3–5 do Asks, then Calendar, Recording and Recap, then Settings and Onboarding (§4).

The Mac has no custom design system. It uses semantic SwiftUI colours, Dynamic Type and SF Symbols, and so will the phone. The design layer in §2 only names the values the Mac uses, so that the phone's screens stop inventing their own. Accent stays system blue (no AccentColor asset, the same as the Mac).

## 2. The design layer: `Sources/DesignSystem/`

### 2.1 Files, project and lint

New directory `Sources/DesignSystem/` (inside the app target's `path: Sources`, so xcodegen picks it up; `make mobile-gen` regenerates the committed `.xcodeproj`):

| File | Holds |
|---|---|
| `PhoneTone.swift` | **Moved** from `Features/Workbench/PhoneTone.swift`, with `PhoneTone`, `ToneRole`, `ToneUse` and `CompactAge` unchanged except the two new tones (§2.2) |
| `Metrics.swift` | `Spacing`, `Radius`, `RowInsets` (§2.9) |
| `TypeScale.swift` | The type scale (§2.8) |
| `TargetStatusStyle.swift` | Target status glyph and tone (§2.3) |
| `PriorityDot.swift` | `PriorityMark` and `PriorityDot` (§2.4) |
| `Card.swift` | `CardStyle` and `View.card(_:)` (§2.5) |
| `Pill.swift` | `Pill`, `CountBadge`, `FilterChip` (§2.6) |
| `FlatRow.swift` | `FlatRow`, `RowDivider`, `SectionHeader` (§2.7) |
| `Bars.swift` | `BottomActionBar`, `ProminentActionStyle`, `RecordButton` (§2.10) |
| `Parts.swift` | `SessionDot` and `ThinProgressBar` (moved from `Features/Workbench/WorkbenchComponents.swift:3-41`), `StepRow`, `FlowRow` (§2.11) |

**Lint.** `WatchtowerMobile/.swiftlint.yml:171-172` changes to:

```yaml
    included: ".*/Sources/(Features|DesignSystem)/.*\\.swift"
    excluded: ".*/Sources/DesignSystem/PhoneTone\\.swift"
```

This makes the rule stricter: the design layer may not name orange either. `card(.waiting)` gets its colour from `PhoneTone.waitingForYou`. The rule's comment (lines 165-167) names the new path.

### 2.2 Tones

`PhoneTone` gains `teal` (→ `Color.teal`) and `gray` (→ `Color.gray`) for the Mac's `in_review` and `dismissed` statuses. `purple` already exists. No other case changes. `waitingForYou` and `waitingBadgeColor` stay the only orange.

### 2.3 Target status: glyph and tone

`enum TargetStatusStyle { static func of(_ status: WorkbenchTargetStatus) -> (glyph: String, tone: PhoneTone) }` follows the Mac's model table exactly (`WatchtowerDesktop/Sources/WatchtowerCore/Models/Target.swift:280-300`):

| Status | Glyph | Tone |
|---|---|---|
| `todo` | `circle` | `secondary` |
| `in_progress` | `circle.dotted.circle` | `blue` |
| `in_review` | `eye.circle` | `teal` |
| `blocked` | `exclamationmark.circle` | `red` |
| `done` | `checkmark.circle.fill` | `green` |
| `dismissed` | `xmark.circle` | `gray` |
| `snoozed` | `moon.circle` | `purple` |
| unknown (newer Mac) | `circle` | `secondary` |

The Mac's list view `TargetsListView.swift:504-514` has no `in_review` case and falls back to secondary. The phone follows the model table (teal), which is the newer source.

**Replaces** `Features/Workbench/BoardModel.swift:96-107`. Today that table differs from the Mac in five rows: in progress is `circle.lefthalf.filled` in accent, in review is `circle.dotted.circle` in accent, blocked uses the `.fill` glyph, done is secondary, and dismissed and snoozed are secondary. `BoardRowModel.status(_:)` keeps its signature and forwards to `TargetStatusStyle.of`, so `OrangeToneTests.testDataDrivenTonesAreNeverOrange` keeps compiling unchanged.

### 2.4 Priority dot

- `enum PriorityMark { static func tone(_ priority: WorkbenchTargetPriority) -> PhoneTone? }`: `high` → `.red`, `low` → `.blue`, `medium` and unknown → `nil` (no dot).
- `struct PriorityDot: View { let priority: WorkbenchTargetPriority }`: a 6 × 6 pt `Circle` in the tone (`TargetsListView.swift:516-529`), or `EmptyView` when the tone is nil. It reserves no space when absent. Accessibility label "High priority" or "Low priority".
- The dot sits first in a row's meta line, as on the Mac.

**Replaces** the `"HIGH"`/`"LOW"` words: `BoardModel.swift:50-51,64-69` (`priorityLabel`/`priorityTone` become `priorityTone: PhoneTone?`), `Features/Workbench/BoardView.swift:137-142` and `BoardTargetDetailView.swift:175-179`. `BoardRowModel.toneUses` (BoardModel.swift:122-128) lists the priority use only when the tone is non-nil, with role `.priority`.

### 2.5 Card

`enum CardStyle { case plain, waiting, highlighted }` and `extension View { func card(_ style: CardStyle = .plain, padding: EdgeInsets = Card.padding) -> some View }`. A `ViewModifier` reads `colorScheme`.

| Style | Radius | Fill, light | Fill, dark | Stroke, light | Stroke, dark |
|---|---|---|---|---|---|
| `plain` | 12 | `Color(.secondarySystemBackground)` | `Color(.secondarySystemBackground)` | `Color(.separator)`, 0.5 pt | same |
| `waiting` | 12 | `waitingForYou` @ 0.10 | `waitingForYou` @ **0.06** | `waitingForYou` @ 0.45, 1 pt | `waitingForYou` @ 0.30, 1 pt |
| `highlighted` | 12 | `accentColor` @ 0.10 | `accentColor` @ 0.14 | `accentColor`, 1.5 pt | same |

- The shape is `RoundedRectangle(cornerRadius: 12, style: .continuous)`. Default inner padding is 12 horizontal and 10 vertical (`Card.padding`).
- The dark waiting fill is weaker on purpose. Orange at 0.10 on black reads brown and heavy (shots 01 and 09, dark).
- Cards sit on `Color(.systemBackground)`: white in light mode, black in dark (§2.7, screen backgrounds). `secondarySystemBackground` on that background reads as a block in both modes, like the Mac's `controlBackground` plus separator.
- A card never contains another card. Rows inside a card are flat (§2.7).

**Replaces:** `WaitingCardView` (`Features/Workbench/WorkbenchComponents.swift:72-95`, radius 10, fill 0.1, stroke 0.5); `ApprovalNoticeView` and `SessionAsksBox` (`Features/Workbench/SessionDetailView.swift:252-269` and `271-317`, radius 14); `SessionReportCard` (`SessionDetailView.swift:319-370`, radius 14, `secondarySystemGroupedBackground`); the agenda event card (`Features/Calendar/AgendaView.swift:204-212`, radius 10, `secondary` @ 0.08 or accent @ 0.1 with a 1.5 pt stroke); the Welcome notice (`Features/Onboarding/WelcomeView.swift:58`, `.quaternary`, radius 12).

### 2.6 Pill, count badge, filter chip

- **`Pill(text:tone:style:monospaced:)`**, `style` is `.tinted` (default) or `.neutral`. The font is `.caption2.weight(.medium)`, or `.caption2.monospaced()` when `monospaced`. Padding is 7 horizontal and 2 vertical, in a `Capsule`. Tinted: foreground `tone.color`, fill `tone.color` @ 0.14. Neutral: foreground `.secondary`, fill `Color.secondary` @ 0.12. Monospaced is used only for branch names. **Replaces** `CountPill` (`WorkbenchComponents.swift:43-56`, @ 0.15), `EventPillView` (`AgendaView.swift:220-231`, @ 0.14), `InfoPill` (`SessionDetailView.swift:232-250`, `tertiarySystemFill`, caption, 8/4) and the Recordings capsule (`AgendaView.swift:36-52`).
- **`CountBadge(count:tone:)`**, the Mac's sidebar badge (`WatchtowerDesktop/Sources/Views/Sidebar/SidebarView.swift:262-270`): `.caption2.weight(.semibold)`, white, on a solid `tone.color` `Capsule`, padding 5 horizontal and 1 vertical, minimum width 16 with centred text, `.monospacedDigit()`. Used for a session row's open asks (orange, role `.ask`) and the Recordings new count (accent). **Replaces** `CountPill` at `WorkbenchComponents.swift:138-141`.
- **`FilterChip(title:count:isSelected:action:)`**: `.footnote` with the count in `.monospacedDigit()`, padding 10 horizontal, the capsule inset by 7 inside a 44 pt tall hit area. Selected: foreground and fill from `accentColor` (fill @ 0.15). Unselected: foreground `.primary`, fill `Color.secondary` @ 0.12. Carries the `.isSelected` trait. **Replaces** the chip recipe at `BoardView.swift:60-83`.

### 2.7 Flat row, row divider, section header

**`FlatRow<Meta: View, Trailing: View>`**, the Mac's target row (`TargetsListView.swift:395-430`) at phone size:

- `HStack(alignment: .firstTextBaseline, spacing: 10)`: icon column, text column, `Spacer(minLength: 8)`, trailing.
- **Icon column** is 20 pt wide, with an SF Symbol at `.body` in the row's tone, or a `SessionDot` of 10 pt.
- **Title** is `TypeScale.rowTitle` (`.callout`), up to 2 lines. A done or dimmed row draws it `.strikethrough()` in `.secondary`, as the Mac does at `TargetsListView.swift:400-403`.
- **Meta line** is `TypeScale.meta` (`.caption`) in `.secondary`, one line. Items are spaced 6 and joined by "·" in `.secondary`, and an item may carry its own tone.
- **Insets** are `RowInsets.flat = EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16)`, with a minimum height of 44.
- **Ask row** (`AskRow`, in `Features/Workbench/WorkbenchComponents.swift`) is a `FlatRow` whose icon is the Mac's kind icon in `waitingForYou`: `questionmark.bubble` for a question, `doc.text.magnifyingglass` for a review, `checklist` for a check (`WatchtowerCore/Services/OwnerAskPresentation.swift:136-142`). Its meta line starts with the kind word ("Question", "Review", "Check") in `waitingForYou`, semibold, followed by the existing subline in `.secondary`. This is how the Mac's "Waiting for you" rows look (`Views/Workbench/Asks/OwnerAskStackSection.swift:79-101`), with orange instead of accent because of the phone's orange rule.
- **`RowDivider`** is `Divider()` with a leading inset of 46 (16 + 20 + 10), so it starts at the title column. It is used between flat rows inside a `ScrollView` or a card.
- **`SectionHeader(_ text:, tone: PhoneTone = .secondary)`**: `TypeScale.sectionHeader`, no uppercase, padding 16 leading, 16 top and 6 bottom. In an `insetGrouped` `List` the system header is kept and set to `.font(TypeScale.sectionHeader)` and `.textCase(nil)`.

**Screen backgrounds.** Screens that list items (Now, the Workbench list, Sessions, Board, Recordings) and the session detail use `Color(.systemBackground)`: a `List` with `.listStyle(.plain)`, or a `ScrollView`. Forms keep `insetGrouped`: Settings (the owner kept it), the sheets, target detail, asks and event detail.

**Why `ScrollView` for Now and Sessions.** Several `NavigationLink`s inside one `List` row cannot each be tapped separately. A waiting card holds one link per ask, so the screens that show one (Now, Workbench → Sessions) become a `ScrollView` with a `LazyVStack(spacing: 0)` and keep `.refreshable`. That is the session detail's existing pattern (`SessionDetailView.swift:107-127`).

### 2.8 Type scale

`enum TypeScale` holds the Mac's roles at iPhone sizes. Everything else uses system styles directly.

| Name | Font | Use |
|---|---|---|
| `screenTitle` | `.title3.weight(.semibold)` | Detail headers (target, ask, event) |
| `pageTitle` | `.title2.weight(.semibold)` | Session title, Saved recording |
| `sectionHeader` | `.footnote.weight(.semibold)` | Section labels (no uppercase) |
| `rowTitle` | `.callout` | Flat row title, card body text |
| `rowEmphasis` | `.callout.weight(.semibold)` | Workbench name, next-meeting title |
| `meta` | `.caption` | Meta lines, captions |
| `kind` | `.caption.weight(.semibold)` | Ask kind word, the REC mark |
| `badge` | `.caption2.weight(.semibold)` | `CountBadge` |
| `pill` | `.caption2.weight(.medium)` | `Pill` |
| `time` | `.caption.monospacedDigit()` | Times, ages, counts, percentages |
| `code` | `.caption.monospaced()` | Branch names, document paths only |

Rules, from the Mac: monospaced is only for counts, times, keys and code. Labels such as "ASK #109 · QUESTION", "REPORT · 2 / 7" and "HIGH" are never monospaced or uppercase. `largeTitle` is only for onboarding and empty states. Emphasis is semibold. The Mac's meta lines use `caption2`; the phone uses `caption` (12 pt) because `caption2` (11 pt) is too small for a whole line on a phone. `caption2` stays for badges and pills.

### 2.9 Spacing, radii, insets

- `enum Spacing`: `tight = 2`, `small = 4`, `compact = 6`, `regular = 8`, `medium = 12`, `large = 16`, `page = 20`. These are the Mac's 2/4/6/8/12/16, plus 20 for page margins in full-screen layouts (the recorder, onboarding).
- `enum Radius`: `chip = 6` (an inner highlight), `row = 8` (row selection fill), `card = 12`. These replace the radii 8, 10, 12 and 14 used ad hoc today (§2.5, plus `AgendaView.swift:206` and `RecordingView.swift:116`; the stop square's radius 6 becomes `Radius.chip`).
- `enum RowInsets`: `flat` (above) and `card = EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)`, the `listRowInsets` around a card placed in a `List`.

### 2.10 Bars and buttons

- **`BottomActionBar<Content: View>`**: `VStack(spacing: 0) { Divider(); content.padding(.horizontal, 16).padding(.vertical, 10) }` on an **opaque** `Color(.systemBackground)`. It goes in `.safeAreaInset(edge: .bottom, spacing: 0)`. **Replaces** every translucent `.background(.bar)` bottom bar: `Features/Calendar/EventDetailView.swift:127`, `BoardTargetDetailView.swift:294`, `Features/Workbench/StartSessionSheet.swift:176,275`, `Features/Asks/AskView.swift:209` and `SessionDetailView.swift:427` (the hidden tell bar). Bugs 4 and 8 come from `.bar`.
- **`ProminentActionStyle: ButtonStyle`** for the one primary action of a bar. Full width, height 50, `Capsule`, `.body.weight(.semibold)`. Enabled: fill from the button's tint (accent by default), white label, opacity 0.8 while pressed. **Disabled** (`@Environment(\.isEnabled)`): fill `Color(.tertiarySystemFill)`, label `.secondary`, and the capsule keeps its shape. A caption above the button says what is missing when the model gives one. The secondary button of a pair stays `.bordered` with `.controlSize(.large)`. This fixes bugs 5 and 6: on iOS 26 a disabled `.borderedProminent` renders as a nearly transparent capsule (shots 18 and 13).
- **`RecordButton(title: String = "Record", size: ControlSize = .large, action:)`**: `Label(title, systemImage: "record.circle")` with `.symbolRenderingMode(.monochrome)` and `.foregroundStyle(.white)`, `.buttonStyle(.borderedProminent)`, `.tint(PhoneTone.red.color)`. In shots 01 and 03 the symbol keeps the accent colour and draws a blue ring inside the red capsule. Forcing the symbol monochrome white fixes that. **Replaces** `Features/Now/NowView.swift:91-99`, `AgendaView.swift:188-194` and `EventDetailView.swift:115-121`.

### 2.11 Shared small parts

- **`SessionDot`** and **`ThinProgressBar`** move unchanged (`WorkbenchComponents.swift:3-41`).
- **`StepRow(state:text:)`**, `state` ∈ `done | current | waiting | todo | failed`. The icon is 22 pt wide: `checkmark.circle.fill` green, `ProgressView()`, `moon.zzz` secondary, `circle` secondary, `exclamationmark.circle.fill` red. The text is `.body`, secondary for `todo`, and the row is at least 44 tall. **Replaces** `RecordingView.swift:257-283` (`StepRow`) and `StartSessionSheet.swift:322-338` (`StepDot`). Onboarding uses it as well (§4, Phase 5).
- **`FlowRow: Layout`**: a wrapping row, 6 pt between items and 4 pt between lines. **Replaces** the `ViewThatFits` HStack-or-VStack fallbacks at `Features/Workbench/WorkbenchListView.swift:99-113` (`FlowCounts`) and `SessionDetailView.swift:145-148`. Those fall back to one item per line.

## 3. The 11 layout bugs

Each bug lists its cause, read from the source, then the fix and the test. "Shot NN" is the tour's screenshot (§6.2), and "NNe" is the same screen scrolled to its end.

### Bug 1: Now's Sessions section sits under the floating tab bar (shot 01)

- **Cause.** Nothing in the code removes the tab bar's bottom inset. Now is an `insetGrouped` `List` in the tab's `NavigationStack` (`NowView.swift:26-72`). The only `ignoresSafeArea` under `Sources/` is the camera at `Features/Onboarding/ScanView.swift:37`. With the demo seed the list is taller than the screen, so at rest its tail is under the iOS 26 floating tab bar. On a device the scroll-edge effect softens that. `drawHierarchy` does not render the effect, so the capture shows plain text under the bar.
- **Fix.** No inset hack. (a) Phase 2 shortens Now: the date moves to a line, the asks become flat rows in one card, and the sessions become one wrapping line. The demo Now then ends above the tab bar at rest on a 402 × 874 pt screen. (b) Shot `01e` checks the inset.
- **Test.** Shot 01: the Sessions row is entirely above the tab bar. Shot 01e (scrolled to the end): the last row's bottom is above the tab bar's top.

### Bug 2: the Calendar mic button covers the highlighted meeting (shot 03)

- **Cause.** `AgendaView.swift:32` floats the button with `.overlay(alignment: .bottomTrailing)` over the list. The 64 pt clear row at `AgendaView.swift:85-86` makes room only at the end of the list, so at rest the button sits on whichever row is near the bottom. In the demo that is the highlighted card.
- **Fix.** (a) The button moves from the overlay into `.safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0)`: 56 pt, padding 16 trailing and 12 bottom. The clear row is deleted. (b) The day's `List` sits in a `ScrollViewReader`, with event rows tagged by card id. On appear and on every `selectedDay` change, `.task(id: selectedDay)` scrolls the highlighted card to `anchor: .center`, so it sits mid-screen and never under the button at rest. (c) The card's Record and Prep stay leading-aligned (Phase 4, C3).
- **Test.** Shot 03: the button does not overlap the highlighted card. Shot 03e: the last row ends above the button.

### Bug 3: target detail's Status and Priority layout breaks (shots 07, 08)

- **Cause.** `BoardTargetDetailView.swift:187-218` puts two `.menu` `Picker`s, each with a `Text` label, plus the progress text into one `HStack` in one row. The row is too narrow, so the first picker wraps its "Status" label above its value, "Priority" stays inline, and "50%" floats at the end. In the same header row the breadcrumb's `NavigationLink`s (`BoardTargetDetailView.swift:124-137`) turn the whole row into a link, which adds the stray chevron at its top right.
- **Fix.** The header section shows only the title (Phase 2, T1). The breadcrumb moves to that section's header (T2). Status and priority get a section of their own with one row each: `Picker("Status")` with a `Label` showing the status glyph and tone (§2.3); `Picker("Priority")` with the `PriorityDot`; and, when the row has a percent, `LabeledContent("Progress") { HStack { ThinProgressBar(width: 80, height: 4); Text("50%").font(TypeScale.time) } }`. A group's "A group's status follows its sub-tasks" becomes that section's footer. The bindings do not change.
- **Test.** Shots 07 and 08: "Status" and its value share one line, "Priority" has its own row, there is no stray "50%", and the header row has no chevron. `BoardWriteWiringTests` stays green unchanged.

### Bug 4: the comment composer has no background (shot 07)

- **Cause.** The composer's `.background(.bar)` (`BoardTargetDetailView.swift:294`) is a translucent material. The orange "Waiting for you" section shows through it, and in dark mode the `.roundedBorder` field floats on nothing.
- **Fix.** The composer's content goes into `BottomActionBar` (§2.10).
- **Test.** Shots 07 and 07e (light and dark): the bar is opaque, with nothing coloured under the field and a hairline on top.

### Bug 5: the disabled Start session button reads as grey text (shot 18)

- **Cause.** `StartSessionSheet.swift:165-171` uses a disabled `.borderedProminent`, which iOS 26 draws as a nearly transparent capsule. On the `.bar` background (line 176) only the grey label remains. `startCaption` (`Features/Workbench/SessionStartModels.swift:284`) explains only the grant case, so with no target picked nothing says why.
- **Fix.** `ProminentActionStyle` in a `BottomActionBar`. `StartSessionFormModel.startCaption` also returns "Choose a target to start" when the target picker is empty. The grant caption keeps priority.
- **Test.** `StartSheetWiringTests`: with no target, `canStart == false` and the caption is "Choose a target to start"; with a target and a refused grant, the grant caption. Shot 18: a grey capsule labelled "Start session" with the caption above it.

### Bug 6: the disabled Send answer button reads as faint text (shot 13)

- **Cause.** `AskView.swift:194-198` has the same disabled `.borderedProminent` with no `maxWidth` frame, on `.bar` (line 209).
- **Fix.** Send, Next question and Approve use `ProminentActionStyle`. Approve sits paired with a `.bordered` Request changes in an `HStack` with equal widths. All of it goes in a `BottomActionBar`. The footer line stays.
- **Test.** Shot 13: a full-width grey capsule labelled "Send answer". Shot 14: Request changes and Approve are equal-width capsules. `AskFormTests` is unchanged.

### Bug 7: the review document renders as flat text (shot 14)

- **Cause.** `SnapshotTextView` (`Features/Asks/ReviewAskView.swift:115-135`) sets `view.text = text` (line 134) with one body font (line 123). The Kit's `PlainTextDocument` (`WatchtowerKit/Sources/WatchtowerKit/Review/PlainTextRendering.swift:6-27`) already carries each heading's UTF-16 offset and level, and list items start with "• ", "N. ", "☐ " or "☑ ". Nothing uses either.
- **Fix.** Add `ReviewDocumentStyler.attributed(_ document: PlainTextDocument) -> NSAttributedString` in `Features/Asks/`, phone only, with no Kit change. **The string is exactly `document.text`**, because comment anchors are UTF-16 offsets into it (`CommentAnchorBuilder`); only attributes change:
  - heading lines (from the heading's offset to the next "\n"): level 1 `.title2` semibold, level 2 `.title3` semibold, level 3 and deeper `.headline`;
  - everything else `.body`, with 6 pt paragraph spacing;
  - list lines get a paragraph style whose `headIndent` is the width of the prefix, so wrapped lines align with the text;
  - fonts come from `UIFontMetrics` (Dynamic Type), and the colour is `.label`.

  `updateUIView` compares `view.attributedText.string` with `document.text` and sets `attributedText`. Known limit: inline emphasis and code blocks stay plain, because `PlainTextDocument` does not mark them.
- **Test.** New `ReviewDocumentStylerTests`, against the demo review #110 and a small fixture: `attributed.string == document.text`; the range of every heading carries its level's font; a list line's wrapped text has the head indent; and the anchor built from a selection is the same as the anchor built from `document.text` alone. Shot 14: "Ask guard v2" and "Steps" are headings, and the steps are body text.

### Bug 8: event detail content runs under the Join and Record bar (shot 20)

- **Cause.** The bar at `EventDetailView.swift:99-129` sits on `.background(.bar)` (line 127), so the Linked targets rows show through it at rest. The list itself gets the bar's inset, so scrolling reaches every row.
- **Fix.** `BottomActionBar`. The button label shortens to "Record" (Phase 4, C4) so it no longer wraps onto two lines.
- **Test.** Shot 20: the bar is opaque and "Record" sits on one line. Shot 20e: the Recording section ends above the bar.

### Bug 9: the recorder shows PAUSED and Resume before anything was recorded (shot 26)

- **Cause.** `Features/Recording/RecordingView.swift:20` sends `.idle` and `.saving` to the capture layout. Lines 39-48 show "PAUSED" for every phase except `.recording`. Line 97 sets `paused = phase != .recording`, so the left control reads Resume. `.idle` is what the screen shows while `start()` awaits microphone permission (`PhoneRecorderController.open(offering:)` → `start()`).
- **Fix.** A pure `RecorderChrome(phase:)` in `Features/Recording/` gives the mark, the pause control and what is enabled:

  | Phase | Mark | Left control | Stop and Mark moment |
  |---|---|---|---|
  | `.idle` | "Starting…" with a small `ProgressView`, secondary | Pause, disabled | disabled |
  | `.recording` | "REC" with `circle.fill`, red | Pause | enabled |
  | `.paused(_)` | "PAUSED", secondary | Resume | enabled |
  | `.saving` | "Saving…", secondary | Pause, disabled | disabled |

  The view lays out only what `RecorderChrome` returns.
- **Test.** `RecorderTests` gets a table test over every phase. Shot 26 (idle) shows "Starting…" and no Resume. Shot 26b (recording, through `FakeAudioEngine`, §6.2) shows REC, Pause and an enabled Stop.

### Bug 10: Settings' "● Online" sits above the Mac row (shot 27)

- **Cause.** The `TimelineView` at `Features/Settings/SettingsView.swift:40-46` builds two views, the status label and the `LabeledContent("Mac")`. The `Form` lays both out in one cell, so the status is centred above the Mac row.
- **Fix.** The `TimelineView` returns one row. A pure `MacStatusRow(status:now:)` provides the label (the Mac's name, else "Mac"), the value ("Online", "Offline · seen 3 min. ago", "Not connected") and the tone (`green` when online, otherwise `secondary`, role `.mac`). The row is `LabeledContent { HStack(spacing: 6) { Circle().fill(tone).frame(width: 8, height: 8); Text(value) } } label: { Text(label) }`.
- **Test.** `SettingsWiringTests` covers the three statuses. Shot 27: "Acme Mac" on the left, "● Online" on the right, in one row.

### Bug 11: every "The Mac doesn't show up" item has a check mark (shot 35)

- **Cause.** `Features/Onboarding/MacNotShowingView.swift:18` draws every item as `Label(item, systemImage: "checkmark.circle")`, so the list reads as done.
- **Fix.** Numbered steps: `Image(systemName: "\(index + 1).circle")` in `.secondary` before each item (1–5), under the section header "Check on your Mac".
- **Test.** Shot 35: the items are numbered 1–5 with no check marks.

## 4. Per-screen changes by phase

Each item names its screen and file and can be checked from that screen's shot. Every screen keeps its strings, routes and contracts unless the item says otherwise.

### Phase 1: the design layer and the 11 bugs

1. **The tour comes first** (§6.2). Its first commit captures the current look as the "before" set.
2. The `Sources/DesignSystem/` files and the lint change (§2.1), then `make mobile-gen`.
3. **Status and priority at the model level:** `BoardRowModel.status` forwards to `TargetStatusStyle`, and `priorityLabel` becomes `priorityTone: PhoneTone?` (§2.3, §2.4). `BoardRowView` draws the `PriorityDot` where the word was. *Check:* shot 06 shows the Mac's glyphs and colours (blue `circle.dotted.circle`, green check), a red dot before "Archive Closed Targets Now", a blue dot before "Ask guard v2", and no HIGH or LOW.
4. Bugs 1–11 (§3), using `BottomActionBar`, `ProminentActionStyle`, `RecorderChrome`, `MacStatusRow` and `ReviewDocumentStyler`.

### Phase 2: Now and Workbench

**Now (shot 01), `Features/Now/NowView.swift`, `Features/Now/NowModel.swift`.** Becomes a `ScrollView` on `systemBackground` (§2.7) and keeps `.refreshable`.

- **N1. The date and Mac status line.** The date card (`NowView.swift:27-41`) becomes one plain line under the large title: the date in `.subheadline`, `.secondary`, on the left; on the right a 7 pt dot in `macChipTone` plus the `macChip` text in `TypeScale.meta`, with no capsule. *Check:* no card around the date.
- **N2. The gear.** `ToolbarItem(placement: .topBarTrailing)` holds `NavigationLink(value: NowRoute.settings) { Image(systemName: "gearshape") }`, with the accessibility label "Settings" (§5).
- **N3. Next meeting.** The card is `card(.plain)` with the header (`TypeScale.meta`, accent), the title (`rowEmphasis`), the time line and a `RecordButton(size: .regular)` on the right. *Check:* there is no blue ring in the Record button.
- **N4. Waiting for you.** `SectionHeader("Waiting for you", tone: .waitingForYou)`, then **one** `card(.waiting)` holding the `AskRow`s separated by `RowDivider`s, then "N more on your Mac" in `meta`. `WaitingCardModel.kindLabel` changes from "REVIEW", "CHECK" and "ASK" to "Review", "Check" and "Question", and it gains `kindIcon` (§2.7). The empty text stays a plain line. *Check:* one orange card with three flat rows and no inner borders.
- **N5. Sessions.** `SectionHeader("Sessions")` plus one `FlowRow` of `SessionCountLabel`s ("● 1 working ● 1 waiting for you …"), which wrap and never stack one per line. *Check:* at most two lines in the demo.

**Workbench list (shot 02), `Features/Workbench/WorkbenchListView.swift`, `WorkbenchModels.swift`.** A `.plain` `List`. One flat row per workbench:

- **W1. Line 1:** the name in `rowEmphasis`, then the existing pills on the right as `Pill`s ("3 waiting" in `waitingForYou`, "1 error" in red, "idle" neutral).
- **W2. Line 2:** the folder in `meta` (regular font, middle truncation), then the branch as a neutral monospaced `Pill`. This replaces the monospaced "path · branch" line at `WorkbenchListView.swift:80-84`.
- **W3. Line 3:** compact counts, one `SessionDot(size: 7)` plus the number in `TypeScale.time` per state, with accessibility labels "1 working" and so on, followed by `ThinProgressBar` (width 64, height 4) and "1/8 done" in `meta`. `WorkbenchCardModel.countsLine` (`WorkbenchModels.swift:148,179`) becomes `doneLine` (`"\(done)/\(open + done) done"`, or "No targets" with no bar at 0 of 0). *Check:* each card is three lines, with no list of six state rows and no "3 in progress · 3 todo …".
- The header ("3 folders on your Mac") and the footer stay, styled as `SectionHeader`.

**Workbench → Sessions (shot 05), `Features/Workbench/WorkbenchView.swift`.** Becomes a `ScrollView`.

- **S1. The header line.** The monospaced subline (`WorkbenchView.swift:92-96`) becomes an `HStack`: the branch as a neutral monospaced `Pill`, then the counts in `meta`, regular font: "3 in progress" in blue, "3 todo" secondary, "1 blocked" in red. `WorkbenchMenuModel.subline` (`WorkbenchModels.swift:197,215`) splits into `branch: String?` and `boardCounts: [BoardCountItem]` (text, tone, role `.status`, listed in `toneUses`).
- **S2. Waiting for you.** One `card(.waiting)` with `AskRow`s, the same as N4. The "▸ 3 closed" disclosure moves below the card as a plain `DisclosureGroup` row in `meta`. *Check:* no card inside a card.
- **S3. Session rows.** `SessionRowView` (`WorkbenchComponents.swift:97-146`) becomes a `FlatRow`. The icon is a 10 pt `SessionDot` (tone, ring). The title is one line. The single meta line is the Mac's caption in the session's tone, then the report ("#430 · 1/3"), the PR line and "2 closed", in `.secondary`. On the right, a `CountBadge` for open asks in `waitingForYou`. The glyph and the mini progress bar are no longer drawn. `SessionRowModel` gains `metaItems` and drops the `progress` `ToneUse`. *Check:* every session row is two lines.
- **S4.** The Sessions/Board segment and the "Acme ⌄" switcher stay (the owner kept them).

**Workbench → Board (shot 06), `Features/Workbench/BoardView.swift`.** A `.plain` `List`.

- **B1. Chips.** `FilterChip`s in a `ViewThatFits`: an `HStack` with a leading inset of 16 when they fit, otherwise a horizontal `ScrollView` whose trailing 24 pt fade under a gradient `mask`, so it is visible that the chips scroll. *Check:* on a 402 pt wide screen all four chips are visible, "Archive" included.
- **B2. Rows.** `BoardRowView` (`BoardView.swift:110-152`) becomes a `FlatRow`. The icon is the status glyph in its tone (§2.3). The title has up to 2 lines, struck through and secondary when done. The meta line is the `PriorityDot`, then the existing details (asks in `waitingForYou`, "Session working" in green, sessions, PR). Under the meta line, `ThinProgressBar` (width 64, height 3) appears when `progressText` is a percent; the trailing "50%" and "done" column (lines 137-148) goes. *Check:* nothing on the right of a row except the disclosure chevron.
- The tree, the disclosure and the order stay.

**Target detail (shots 07, 08), `Features/Workbench/BoardTargetDetailView.swift`.** Stays `insetGrouped`.

- **T1. The title.** The navigation title "#415" (`BoardTargetDetailView.swift:38`) becomes a `ToolbarItem(placement: .principal)`: `HStack(spacing: 4) { Text(title).font(.headline).lineLimit(1); Text("#415").font(TypeScale.time).foregroundStyle(.secondary) }`. The header section's row shows the full title in `screenTitle`.
- **T2. The breadcrumb.** It moves into the header section's `header:` as a small line above the title (`meta`, `.secondary`, `textCase(nil)`). Each crumb is still a link. The title row is no longer a link (bug 3).
- **T3.** The status, priority and progress section (bug 3).
- **T4. Work on it.** It becomes an action row in its own section: `Label("Work on it in a session", systemImage: "play")`, `.buttonStyle(.borderless)`, in accent and leading-aligned, with the start stage caption under it. This replaces the full-width prominent button at lines 150-159. *Check:* no blue full-width capsule.
- **T5. Waiting for you.** `AskRow`s directly in the section rows, in place of `WaitingCardView` (lines 73-80), with the header in `waitingForYou`. *Check:* no orange card inside the section.
- **T6. The read-only line** (archived targets, lines 171-185): glyph, label, `PriorityDot` and percent, in `TypeScale.meta`.
- **T7.** The composer (bug 4). The comment rows and the Code section stay.

**Session detail (shots 09–12), `Features/Workbench/SessionDetailView.swift`.** A `ScrollView` on `systemBackground`; the `systemGroupedBackground` at line 127 goes.

- **D1. The title.** The navigation bar gets a principal title (the session title in `.headline`, one line), so the bar is not an empty strip with a lone "⋯". The body keeps the title in `pageTitle`.
- **D2. The state line.** A `SessionDot` plus the caption in the session's tone, and no glyph (lines 135-144). *Check:* shot 11 shows one icon for Finished, not two.
- **D3. The chips.** One `FlowRow` (spacing 6): the target as a tinted accent `Pill` (still a link, 44 pt hit area), the branch as a neutral monospaced `Pill`, the agent as a neutral `Pill`. This replaces `InfoPill` and the stacking `ViewThatFits`. *Check:* shot 09 has all three chips on one line.
- **D4. Waiting for you.** `SessionAsksBox` keeps its layout (the owner kept it), drawn as `card(.waiting)` with `AskRow`s. The same component serves N4 and S2 (`WaitingStack` in `WorkbenchComponents.swift`).
- **D5. The approval notice:** `card(.waiting)`.
- **D6. The report:** `card(.plain)`. "Report" is in `sectionHeader` with no uppercase, the count "2 / 5 targets" in `TypeScale.time`, and the PR lines in `meta` (not monospaced). The segments stay.
- **D7. The timeline:** the header in `sectionHeader` with no uppercase; times in `TypeScale.time`; dots unchanged.

**Sheets.**
- **Start session (shot 18), `Features/Workbench/StartSessionSheet.swift`.** Bug 5. The fixed target label (line 85) changes from monospaced to `.callout`. The progress view uses `StepRow`, and its buttons use `ProminentActionStyle` and `.bordered` in a `BottomActionBar`.
- **New target (shot 19), `Features/Workbench/NewBoardTargetSheet.swift`.** No change (the owner kept it).

### Phase 3: Asks

Files: `Features/Asks/AskView.swift`, `QuestionAskView.swift`, `ReviewAskView.swift`, `CheckAskView.swift` and `AskFormModel.swift`.

- **A1. The header (shots 13–17).** "ASK #109 · QUESTION · 1 OF 2" (`AskFormModel.swift:187-189`, drawn at `AskView.swift:114-116`) becomes one line: the kind icon (§2.7) and the kind word ("Question", "Review", "Check") in `TypeScale.kind`, then "#109" in `TypeScale.time`, `.secondary`, and on the right "1 of 2" in `meta`. The kind icon and word use `headerTone` (orange while open, secondary once closed). `AskFormModel.header` splits into `kindIcon`, `kindName`, `idText` and `pageText`. The title stays in `screenTitle`. Focus items become rows of `Label(focus, systemImage: "scope")` in `meta`.
- **A2. Recommended (shot 13).** The outlined monospaced badge (`QuestionAskView.swift:55-61`) becomes "Recommended" in `meta`, accent, on its own line under the option label and before its description.
- **A3.** The send bar (bug 6).
- **A4. The review (shot 14).** Bug 7. The document path header stays `TypeScale.code`.
- **A5. The check (shot 15).** Each step is "1." in `.secondary` with `.monospacedDigit()`, then the text and the hint; the "Step N" picker label goes (`CheckAskView.swift:17,21-29`). The menu picker is replaced by three icon buttons in a row: `checkmark.circle`, `xmark.circle` and `minus.circle` (OK, Broken, Skipped), each 44 × 44, drawn as the `.fill` variant in its tone when selected (green, red, secondary) and as the outline in `.secondary` otherwise. Each has an accessibility label and the `.isSelected` trait. Tapping the selected state again clears it, as on the Mac (`WatchtowerDesktop/Sources/Views/Workbench/Asks/OwnerAskChecklistBody.swift:44-57`). The tones come from the model: `AskFormModel.CheckRow` lists them as `ToneUse`s with role `.status` and never orange. The note field rule stays. *Check:* one tap marks a step.
- **A6. A closed, answered ask (shot 16).** `closedLines: [String]` (`AskFormModel.swift:147,259-276`) becomes `[ClosedLine(label:value:)]`, drawn as two lines: the question in `meta`, `.secondary`, and the answer in `.callout`. *Check:* no "?:".
- **A7. A withdrawn ask (shot 17).** No change.

### Phase 4: Calendar, Recording, Recap

- **C1. The Recordings entry (shot 03), `Features/Calendar/AgendaView.swift:28-52`.** The capsule becomes a toolbar icon button `Image(systemName: "waveform")` with a `CountBadge` in accent for new recaps. Its accessibility label is the existing `RecordingsListModel.pillText` ("Recordings · 1 new").
- **C2.** The mic button (bug 2).
- **C3. Agenda cards (shot 03).** The highlighted card uses `card(.highlighted)`, the others `card(.plain)` (`AgendaView.swift:204-212`). Record is `RecordButton(size: .regular)` and Prep is `.bordered`, both leading-aligned. Pills are `Pill`s. The week strip and the now line stay (the owner kept them).
- **C4. Event detail (shots 20–22), `Features/Calendar/EventDetailView.swift`, `EventDetailModel.swift`.**
  - Bug 8.
  - "Record this meeting" becomes "Record" (`EventDetailModel.swift:49` and `EventDetailView.swift:118`).
  - Attendee initials (lines 43-51) grow to 32 pt, in `.caption.weight(.semibold)`. Each gets a fill at 0.2 and initials in a tone picked by a stable hash of the attendee's name, from `[.blue, .green, .teal, .purple]` (never red or orange). `EventDetailModel.toneUses` lists the tones with role `.info`.
  - A past event with a recap shows one bar button, "Open recap" (`ProminentActionStyle`, which pushes `CalendarRoute.recap(id)`), in place of Join and Record. `EventDetailModel.actionTitles` becomes an `actions: [EventAction]` (`join`, `record`, `openRecap(id)`).
  - The Recording section shows a phone recording that the Mac is transcribing as one row: `waveform` in purple, "Transcribing on Mac" in `.callout`, then `ThinProgressBar` (width 80) and "60%" in `TypeScale.time`, from `job.percent` (`Features/Recording/PhoneRecordingsModel.swift:70`). Other states keep their text.
- **C5. The Recordings list (shot 23):** pills become `Pill`s. Nothing else changes (the owner kept it).
- **C6. Recap (shots 24, 25), `Features/Recordings/RecapView.swift:130-133`.** Section titles change from uppercase `.caption` to `.headline` with no uppercase, with 16 pt above each section. The transcript stays.
- **C7. The recorder (shot 26), `Features/Recording/RecordingView.swift`.**
  - Bug 9.
  - The waveform (lines 157-177) draws bars with a level under 0.05 in `.quaternary` and the others in red at 0.85, with a minimum height of 4. Silence then reads as a grey line instead of a red dashed one. The level is already mapped from dB to 0…1 (`Features/Recording/AVAudioCaptureEngine.swift:213-224`), so the Mac's `MicLevelBars.displayFraction` is not applied on top.
  - Stop is solid red whenever it is enabled. It is disabled only in `.idle` and `.saving`, where `RecorderChrome` shows "Starting…" or "Saving…".
  - The Saved screen uses `StepRow`.

### Phase 5: Settings and Onboarding

**Settings (shot 27), `Features/Settings/SettingsView.swift`.**
- **SET1.** Bug 10.
- **SET2. Last sync** (lines 47-53): `Text(last, style: .relative)` ("2 min, 39 sec") becomes `Text(last.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))` ("3 min. ago"), refreshed by the row's 30 s `TimelineView`.
- **SET3. Account status** (lines 93-97): a pure `AccountStatusStyle(status:)`. "ok" → an 8 pt green dot and "OK". "error" → `exclamationmark.circle.fill` in red and "Error". Anything else → the raw text in `.secondary`. Role `.info`, never orange. *Check:* "Acme Jira" shows a red "Error".
- **SET4.** The doc comment at line 4 says Settings is reached from Now's gear. `insetGrouped` stays (the owner kept it).

**Onboarding (shots 28–35), `Features/Onboarding/`.**
- **O1. Welcome (shot 28), `WelcomeView.swift:42-51`.** The `desktopcomputer.and.iphone` symbol becomes the app icon: a new `AppIconImage` imageset in `Assets.xcassets`, copied from `AppIcon-1024.png` and drawn at 72 pt with a continuous corner radius of 16. It is followed by the existing one-line description and three `FlatRow`-style lines with accent icons: `questionmark.bubble` "Answer your agents' asks", `terminal` "Follow and start sessions", `calendar` "Record and recap meetings". The hint above the button stays (the owner kept it).
- **O2. Checking and waiting (shots 30, 31), `WelcomeView.swift:87-100`.** `LinkProgressView(text:)` becomes a three-step `StepRow` list: "Code read", then "Waiting for <Mac> to confirm", then "Linked". `.checking` makes step 1 current. `.waiting` makes step 1 done and step 2 current. Once `.waiting` has lasted 20 s, a hint line appears in `meta`: "Keep Settings → Mobile open on the Mac." `LinkingViewModel` gains `phaseStartedAt: Date?`, set from its clock on every phase change, and a `TimelineView` re-reads it. `.unlinking` keeps the spinner.
- **O3. Failure (shot 33), `LinkingViewModel.swift:73-83`, `LinkedView.swift:56-58`.** `LinkFailure` gains `title` and `hint`, and the screen shows the title in `screenTitle` with the hint under it in `.secondary`. `message` keeps returning "title — hint" for every other reader. The split, one row per case:

  | Case | Title | Hint |
  |---|---|---|
  | expired | This code expired | Show a new code on the Mac |
  | signIn | Sign in to iCloud on this iPhone | Watchtower uses iCloud to reach your Mac |
  | cannotShare | This Mac can't share with another Apple ID right now | Show a new code on the Mac |
  | noAnswer | Your Mac didn't answer | Keep Settings → Mobile open on the Mac and scan again |
  | refused | This code can't be used | Show a new code on the Mac |
  | updateApp | Update Watchtower on this iPhone | (none) |
  | iCloud(reason) | Couldn't reach iCloud | the reason |

  The signIn and updateApp `message`s keep today's exact text.
- **O4.** Bug 11 (shot 35).
- **O5.** Switch Mac (shot 32) and Linked (shot 34) keep their layout. The Linked icon becomes `checkmark.circle.fill` in green (`LinkedView.swift:10`).

## 5. Navigation: removing More

- **Tabs.** `RootTabView.Tab` (`App/RootTabView.swift:8-29`) loses `.more`: the tabs are Now (`clock`), Workbench (`hammer`) and Calendar (`calendar`). `MoreView` (lines 124-176) and the `.more` case of `content(for:)` (lines 118-119) are deleted. The doc comments at lines 4-6 change.
- **Settings.** It is pushed on Now's stack: `enum NowRoute: Hashable { case settings }`, the gear from N2, and `.navigationDestination(for: NowRoute.self) { _ in SettingsView() }` in `NowView`. `SettingsView` reads `AppEnvironment` and `LinkingViewModel`, which `AppRootView.swift:11-12` already injects above the tabs.
- **The voice note.** It stays the Calendar's mic button (`AgendaView.swift:95-108`). Nothing else starts a free voice note.
- **Routes and links that pointed at More.** There are none in code beyond the tab itself. `AppNavigation.tab` defaults to `.now` (`App/AppNavigation.swift:16`). `showRecordings()` goes to Calendar. `LinkHost.openNow()` selects Now. The app opens only `watchtower://link` URLs, and notifications are not built (A13). References to update: `Tests/RootTabTests.swift:7-25` (three tabs in order; `testMoreHoldsSettingsOnly` goes; a new `testSettingsIsReachedFromNow` asserts `NowRoute.settings` and the three-tab list), `Tests/ReplicaWiringTests.swift:177` (`.more.fetchInterval` → `.calendar.fetchInterval`) and the `SettingsView.swift:4` comment.
- **Fetch interval.** Settings opened from Now runs at Now's 5 s. Under More it ran at 30 s. That is accepted: Settings reads the heartbeat, and 5 s while it is open costs nothing measurable.
- **Tab badge.** It stays on Workbench: the open-ask count, orange, the only badge (`RootTabView.swift:31-35`). In the review captures it draws **red**: `UITabBarItem.appearance().badgeColor` set in `init` (`RootTabView.swift:59-62`) did not reach the iOS 26 tab bar there. Fix: a static `RootTabView.configureTabBarAppearance()` (called from `init`) also sets `badgeBackgroundColor = PhoneTone.waitingBadgeColor` on the `stacked`, `inline` and `compactInline` item appearances of a `UITabBarAppearance`, assigned to `UITabBar.appearance().standardAppearance` and `scrollEdgeAppearance`. Test: `RootTabTests` asserts the stacked normal badge background is `systemOrange` after configuring. Shot 01 shows an orange badge, as a device does.

## 6. Testing

### 6.1 Models

The screens' pure models keep being tested as they are now. This pass adds or changes:

- **New `DesignSystemTests`.** `TargetStatusStyle.of` matches the Mac table of §2.3 for every `WorkbenchTargetStatus.knownValues` plus an unknown value (the expected table is written out in the test). `PriorityMark.tone` is red for high, blue for low, and nil for medium and unknown. No tone in either table is orange.
- **Changed:** `WorkbenchWiringTests` (`doneLine`, `branch` and `boardCounts`, `kindLabel`/`kindIcon`, session `metaItems`); `BoardFilterTests` (priority tone instead of the label); `StartSheetWiringTests` (bug 5's caption); `AskFormTests` (A1's header fields, A6's closed line pairs, A5's toggle-off); new `ReviewDocumentStylerTests` (bug 7); `RecorderTests` (bug 9's table); `SettingsWiringTests` (`MacStatusRow`, `AccountStatusStyle`); `LinkingViewModelTests` (the `LinkFailure` title and hint, `message` unchanged, `phaseStartedAt` set on each phase change); `CalendarWiringTests` (`EventAction`, attendee tones); `RootTabTests` (§5).
- No new `@Observable` view model is added. `LinkingViewModel`'s new field is covered by its existing suite.

### 6.2 The screenshot tour (`make mobile-shots`)

A committed, opt-in test that renders every screen from the demo seed to PNGs, for before/after comparison by eye. It asserts no pixels: the project has no snapshot library, and this pass adds none.

- **Files.** `WatchtowerMobile/Tests/ScreenshotTourTests.swift` and `WatchtowerMobile/Tests/Support/ScreenshotHost.swift`, in the existing `WatchtowerMobileTests` target.
- **Opt-in.** The test begins with `guard let dir = ProcessInfo.processInfo.environment["WATCHTOWER_SHOTS_DIR"] else { throw XCTSkip("Screenshot tour: run make mobile-shots") }`. `make mobile-test` and CI never set it, so the class reports as skipped and the normal run is unchanged.
- **Make target.**

  ```make
  SHOTS_DIR ?= build/mobile-shots
  mobile-shots:
  	xcrun simctl boot "$(SIM)" 2>/dev/null || true
  	xcrun simctl uninstall "$(SIM)" $(MOBILE_BUNDLE_ID) 2>/dev/null || true
  	mkdir -p "$(SHOTS_DIR)"
  	TEST_RUNNER_WATCHTOWER_SHOTS_DIR="$(abspath $(SHOTS_DIR))" xcodebuild test -project $(MOBILE_PROJ) \
  		-scheme WatchtowerMobile -destination '$(MOBILE_DEST)' CODE_SIGNING_ALLOWED=NO \
  		-only-testing:WatchtowerMobileTests/ScreenshotTourTests
  ```

  `xcodebuild` passes `TEST_RUNNER_`-prefixed variables to the test process with the prefix stripped. `build/` is gitignored, so the shots never get committed. `mobile-shots` joins the `.PHONY` list.
- **Data.** One demo root, `AppRoot.demo(AppEnvironment(transport: InMemoryCloudTransport(), replicaPath: <temp>, transportKind: .inMemoryDemo, defaults: <temp suite>, recordingsDirectory: <temp>), defaults:)`, built the way `AppRootWiringTests` builds it. The test waits for the first hydration and loads `DemoSeed.loadRecordingDemo`. The environment is stopped in a teardown block. No subprocess is started.
- **Capture** (`ScreenshotHost.capture(_ name: String, _ view: some View) async throws`). For each of `.light` and `.dark`:
  1. Take a `UIWindow(windowScene:)` on the test host's connected `UIWindowScene`, framed to the scene's screen bounds (the simulator `SIM`, at its scale), with `overrideUserInterfaceStyle` set.
  2. Set `rootViewController = UIHostingController(rootView: view.environment(root.env).environment(root.linking))` and call `makeKeyAndVisible()`.
  3. Settle once for 600 ms, for replica observation and layout.
  4. Render with `UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }` and write `<dir>/<name>-<light|dark>.png`.
  5. Hide the window and nil its root.

  The **end variant** (`<name>e`) finds the first `UIScrollView` in the window whose content is taller than its bounds, sets `contentOffset.y = contentSize.height + adjustedContentInset.bottom − bounds.height`, settles for 300 ms and captures again.
- **Screens.** The tour table lists the 35 screens of the review with their numbers and names. 04 (More) leaves the table in Phase 2. The table adds `01e`, `03e`, `07e`, `20e`, `26b` (recording, through `FakeAudioEngine` and the `makeRecorderRig` fixture), `26c` (paused) and `26d` (saved).
  - Tabs render the full `RootTabView`, with `root.env.navigation.tab` set.
  - Calendar pushes render in the full app through `navigation.calendarPath`.
  - Workbench pushes (target, session, ask) render in a bare `NavigationStack`, without the tab bar.
  - Sheets render as the root of their own `NavigationStack`.
  - Onboarding renders the leaf views directly: `WelcomeView`, `LinkProgressView` for checking and waiting, `SwitchMacView`, `LinkFailureView(failure: .expired)`, `LinkedView`, `MacNotShowingView`. The scan screen renders `ScanView` (black on the simulator, which has no camera).
- **Output.** The PNGs plus an `INDEX.md` listing each screen's number, the view it renders, its source file and how it was reached (full app or bare stack). The test asserts that every PNG is non-empty and that the file count is twice the table's row count.
- **Before and after.** The tour lands as Phase 1's first commit, on the current look. To compare: `make mobile-shots SHOTS_DIR=build/mobile-shots/before` on that commit (in a separate worktree), then `make mobile-shots SHOTS_DIR=build/mobile-shots/after` at the end of each phase. The demo seed is relative to the moment it is loaded, so only the date and the "in N min" texts differ between runs on the same day.

### 6.3 Lint and OrangeToneTests

- `OrangeToneTests` stays green without its assertions being weakened. Its sweep already covers the changed models (`NowModel`, `WorkbenchCardModel`, `WorkbenchMenuModel`, `BoardModel`, `BoardTargetDetailModel`, `AskFormModel`, `SessionDetailModel`, the calendar models). The new `ToneUse`s (S1's board counts, A5's check states, C4's attendee tones, SET3's account states) are added to those models' `toneUses`, so the sweep sees them. `MacStatusRow` and `AccountStatusStyle` go into `testDataDrivenTonesAreNeverOrange`.
- `make lint-swift` runs the extended `orange_outside_phone_tone` rule (§2.1). A `.orange` or `systemOrange` anywhere in `Sources/DesignSystem/` other than `PhoneTone.swift` fails the build.

### 6.4 Checks per phase

- **Per task:** `make mobile-test MOBILE_FILTER=<Class>` for the touched suites, plus `make lint-swift`.
- **Per phase:** the full `make mobile-test` and `make lint-all`, then `make mobile-shots` for the after set.
- Desktop and Kit sources do not change, so `make test-swift` belongs only to the pre-PR gate.

## 7. Docs to update with the change

- `docs/features/mobile-companion.md`:
  - "Tabs": Now, Workbench and Calendar; Settings from Now's gear.
  - "Settings": reached from Now.
  - C6 "Capture": the Calendar's mic button records a voice note (in place of "More's entry").
  - B5 "Orange only for waiting and asks": the rule covers `Sources/DesignSystem/`, and `PhoneTone.swift` lives there.
  - "Building and testing": `make mobile-shots`.
  - A short "Design layer" paragraph under Phone app pointing to this spec.
- `CLAUDE.md`'s mobile companion line, which lists "Now/Workbench/Calendar/More".

## 8. Out of scope

- **No new features.** The "idea" findings of the review stay out:
  - a branch line for the board tree (06);
  - an error block with "Run again" (12);
  - focus items highlighted inside the review text (14);
  - a link to the round that replaced a withdrawn ask (17);
  - priority dots inside the New target picker (19);
  - action items as checkboxes or "make target" (24);
  - a scan viewfinder (29);
  - a richer Linked screen (34).
- **No wire, Kit or replica change.** Bug 7 uses only what `PlainTextDocument` already carries.
- **No Mac change.** The Mac's own medium-orange dot and its list view's missing `in_review` colour stay as they are.
- No snapshot library, no pixel-diff assertions, no Dynamic Type or iPad pass, no new SF Symbol assets, and no AccentColor asset.

## 9. Open questions

Each question has a recommended default that the plan follows unless the owner says otherwise.

1. **Session state glyph.** The Mac draws a dot plus a glyph (`SessionStatePresentation.glyph`). The phone draws only the dot, everywhere (D2, S3), because the owner flagged "two icons for one status". The glyph field stays in the models. *Default: dot only.*
2. **The calendar scroll on appear.** Bug 2's fix scrolls the highlighted meeting to the middle of the screen on appear and on every day change. Today the agenda opens at the top of the day. *Default: scroll to the highlighted card. If there is none, stay at the top.*
3. **White list screens.** Now, the Workbench list, Sessions, Board, Recordings and session detail move from grouped grey to `systemBackground` (white or black), with flat rows, to match the Mac's flat list. Forms stay grouped. *Default: as specified in §2.7.*
4. **"N closed" on a session row.** It used to be a row line of its own. It becomes the last meta item and is the first item to truncate. *Default: keep it as a meta item.*
5. **The tab badge colour on a device.** Only the captures show red. If a device shows orange today, the `UITabBarAppearance` addition (§5) still lands, as a guard. *Default: land it.*
