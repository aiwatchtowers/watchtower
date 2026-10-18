# Desktop Style Guide Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Desktop app one design kit (`Sources/Views/DesignSystem/`): tokens, promoted and new components, a gallery, rendered shots and lint rules. With it, every new screen looks like the Workbench, Chat and Calendar.

**Architecture:**
- Tokens and components live in the app target, because `WatchtowerCore` stays SwiftUI-free.
- Existing good styles are *moved and renamed*, never retuned. Before/after PNG shots, rendered with the existing `ViewRenderProbe` technique, prove nothing changed.
- New SwiftLint `custom_rules` ban stock controls and raw numbers in new code. Existing violations are absorbed into `.swiftlint-baseline.json`.

**Tech Stack:** SwiftUI and AppKit (macOS 14+), XCTest with ViewInspector, SwiftLint `custom_rules`, `scripts/build-app.sh` (PlistBuddy).

**Spec:** `docs/superpowers/specs/2026-10-19-desktop-style-guide-design.md` (approved, ask #413). Board target #719.

## Global Constraints

- **Location.** Kit code lives only in `WatchtowerDesktop/Sources/Views/DesignSystem/`. Nothing SwiftUI or AppKit is added to `Sources/WatchtowerCore`.
- **Promotion changes no pixels.** A promoted type keeps its exact current values. An off-scale value stays a private constant inside the kit file. Values are never "rounded to the scale" during a move (spec §4.1).
- **Token values, copied from the spec:**
  - `Spacing`: tight 2, small 4, compact 6, regular 8, cozy 10, medium 12, large 16, page 20, wide 24, hero 40.
  - `Radius`: mark 4, control 6, row 8, container 10, bubble 16, pill 18.
  - Fill opacities: rest 0.04, card 0.06, hover 0.07 (of `.primary`), selected 0.12, on 0.20 (of the accent).
  - Chip: tint 0.14, stroke opacity 0.3, stroke width 0.5.
  - `Stroke`: hairline 0.5 (`separatorColor`), selection 1.5 (accent).
  - Floating shadow: black at 0.2, radius 3, y 1.
  - `Motion`: toggle `.snappy(duration: 0.15)`, panel `.easeInOut(duration: 0.2)`.
- **No new colours.** Use semantic system colours only: no hex, no RGB, no asset colours.
- **Sample data** in shots and tests uses `acme` and `example.com` names only (public repo hygiene).
- **Per-task checks** are `make test-swift FILTER=<classes>` and `make lint-swift`. `lint-diff` does not check Swift. An unfiltered `swift test` is for the controller's gate only.
- **Review rules.** Read the Swift section of `docs/review/review-rules.md` before any task.

## Review Focus

1. **Dark mode and the macOS 26 surface.** A promoted surface (`detailBackground`, `PanelTab`) must still render the same in Dark. Shots run in both appearances in every shot test (Task 2), and the before/after comparison covers both.
2. **Disabled and pressed states.** A promoted button style must keep its disabled look: `PopoverPrimaryButtonStyle` falls back to `.bordered` when disabled, and `DestructivePrimaryButtonStyle` uses 0.5 opacity. The existing `DestructivePrimaryButtonStyleTests` must pass unchanged except for the renamed type (Task 4).
3. **Hover shared across a segment and its chevron.** `HeaderSegmentStyle` takes `isHovered`/`onHover` from its parent, so the Terminal segment and its sessions chevron light up together. The promoted `SegmentedToggleStyle` keeps that API, and a test pins it (Task 5).
4. **The lint rules on existing code.** After the baseline is regenerated, `make lint-swift` passes on the untouched tree, and the count of non-kit baseline entries is unchanged (Task 7).
5. **The gallery in a shipped build.** In a release build without `WTDevBuild`, no menu item or window for the gallery exists. A test pins `DevBuild.isEnabled == false` when the key is absent (Task 3).

---

### Task 1: Tokens

**Depends on:** none

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/DesignSystem/Tokens.swift`
- Create: `WatchtowerDesktop/Sources/Views/DesignSystem/Tone.swift` (moved from `WorkbenchBoardColors`, `Views/Workbench/WorkbenchBoardCardView.swift:209-233`)
- Create: `WatchtowerDesktop/Sources/Views/DesignSystem/Surface.swift` (moves `NSColor.detailBackground` and the `panelBackground()`/`detailBackground()` modifiers out of `Views/Components/PanelListStyle.swift`)
- Modify: every call site of `WorkbenchBoardColors` (rename to `Tone`; `grep -rn WorkbenchBoardColors WatchtowerDesktop`)
- Test: `WatchtowerDesktop/Tests/DesignTokensTests.swift`

**Interfaces:**
- Produces:
  - `enum Spacing { static let tight, small, compact, regular, cozy, medium, large, page, wide, hero: CGFloat }`
  - `enum Radius { static let mark, control, row, container, bubble, pill: CGFloat }`
  - `enum Fill`:
    - opacities `restOpacity` 0.04, `cardOpacity` 0.06, `hoverOpacity` 0.07, `selectedOpacity` 0.12, `onOpacity` 0.20;
    - colours `rest`, `card`, `hover` (`Color.primary.opacity(…)`) and `selected`, `on` (`Color.accentColor.opacity(…)`).
  - `enum ChipTint { static let fillOpacity = 0.14, strokeOpacity = 0.3, strokeWidth: CGFloat = 0.5 }`
  - `enum Stroke { static let hairline: CGFloat = 0.5, selection: CGFloat = 1.5; static var hairlineColor: Color }` (`Color(nsColor: .separatorColor)`)
  - `enum IconSize { static let chevron: CGFloat = 8, header: CGFloat = 14, composer: CGFloat = 16, composerLarge: CGFloat = 24 }`
  - `enum Motion { static let toggle: Animation, panel: Animation }`
  - `enum FloatingShadow { static let color: Color, radius: CGFloat = 3, y: CGFloat = 1 }`
  - `enum Tone { static func status(_ name: String) -> Color; static func priority(_ priority: String) -> Color }`, with the same mapping as `WorkbenchBoardColors` today.
  - `extension NSColor { static var detailBackground: NSColor }`, unchanged body, new file.
  - `enum Surface { static var detail, window, text, control: Color }`, for `detailBackground`, `windowBackgroundColor`, `textBackgroundColor` and `controlBackgroundColor`.

- [ ] **Step 1: Write the failing test** `DesignTokensTests`:

```swift
func testSpacingScaleMatchesTheSpec() {
    XCTAssertEqual([Spacing.tight, Spacing.small, Spacing.compact, Spacing.regular, Spacing.cozy,
                    Spacing.medium, Spacing.large, Spacing.page, Spacing.wide, Spacing.hero],
                   [2, 4, 6, 8, 10, 12, 16, 20, 24, 40])
}
func testRadiiMatchTheSpec() {
    XCTAssertEqual([Radius.mark, Radius.control, Radius.row, Radius.container, Radius.bubble, Radius.pill],
                   [4, 6, 8, 10, 16, 18])
}
func testFillOpacitiesMatchTheSpec() {
    XCTAssertEqual([Fill.restOpacity, Fill.cardOpacity, Fill.hoverOpacity, Fill.selectedOpacity, Fill.onOpacity],
                   [0.04, 0.06, 0.07, 0.12, 0.20])
    XCTAssertEqual(ChipTint.fillOpacity, 0.14); XCTAssertEqual(ChipTint.strokeOpacity, 0.3)
    XCTAssertEqual(Stroke.hairline, 0.5); XCTAssertEqual(Stroke.selection, 1.5)
}
func testToneKeepsTheTargetsTabMapping() {
    XCTAssertEqual(Tone.status("teal"), .teal); XCTAssertEqual(Tone.status("nope"), .secondary)
    XCTAssertEqual(Tone.priority("high"), .red); XCTAssertEqual(Tone.priority("low"), .blue)
    XCTAssertEqual(Tone.priority("medium"), .orange)
}
```

- [ ] **Step 2:** Run `make test-swift FILTER=DesignTokensTests`. Expected: build FAIL (`cannot find 'Spacing' in scope`).
- [ ] **Step 3:** Implement `Tokens.swift`, `Tone.swift` and `Surface.swift` per Interfaces. Delete `WorkbenchBoardColors` and rename its callers. Delete the moved code from `PanelListStyle.swift`.
- [ ] **Step 4:** Run `make test-swift FILTER='DesignTokensTests|WorkbenchBoard'`. Expected: PASS. Then run `make lint-swift`. Expected: no new violations.
- [ ] **Step 5:** Commit `feat(desktop): design tokens, Tone and surfaces in DesignSystem (#719)`.

---

### Task 2: Shots harness and before-shots

**Depends on:** Task 1

**Files:**
- Create: `WatchtowerDesktop/Tests/DesignShots/DesignShotCatalog.swift`, the registry of shots.
- Create: `WatchtowerDesktop/Tests/DesignShots/DesignShotsTests.swift`, which renders the catalog.
- Modify: `WatchtowerDesktop/Tests/ViewRenderProbe.swift`. Add `func png(_ view: some View, _ appearance: NSAppearance) throws -> Data`, reusing `render`.
- Modify: `Makefile`. Add a `desktop-shots` target and put it in `.PHONY`.

**Interfaces:**
- Produces:
  - `struct DesignShot { let name: String; let size: NSSize; let make: @MainActor () -> AnyView }`
  - `enum DesignShotCatalog { @MainActor static var all: [DesignShot] }`. Later tasks and every new screen append to it.
  - The env var `DESKTOP_SHOTS_DIR`. When it is set, every shot is written to `<dir>/<name>-light.png` and `<dir>/<name>-dark.png`.
  - `make desktop-shots [SHOTS_DIR=build/desktop-shots]` runs `cd WatchtowerDesktop && DESKTOP_SHOTS_DIR=$(abspath $(SHOTS_DIR)) swift test --filter DesignShotsTests`.

Reference shots for this task, built on fixtures (`TestDatabase.createDatabaseManager()` where a view model is needed). Names are the file stems:
- `workbench-header`: `WorkbenchHeaderControls` with Terminal on and Board off. Hover can't be rendered; leave it out.
- `workbench-board-cards`: `WorkbenchBoardCardView` rows for a leaf, a collapsed parent, a selected card, and priority and status chips.
- `workbench-panel-parts`: `WorkbenchDetailSectionHeader` with a count, `WorkbenchDetailMenuLabel` (menu and read-only), `WorkbenchCapsuleBadge` and `AgentTag`.
- `sessions-panel`: a `List` of three rows with `.panelTab(isSelected:)`, the middle row selected, inside `.panelSurface()`.
- `chat-rows`: a user and an assistant `ChatMessageRow`, plus the "Jump to latest" label view.
- `calendar-rows`: `CalendarEventRow` for a past event, an upcoming one and one happening now.
- `buttons`: `.popoverPrimary` enabled and disabled, and `.destructivePrimary` small and regular.

- [ ] **Step 1:** Write `DesignShotsTests.testEveryShotRenders`. For each catalog entry and each of aqua and darkAqua, render, assert the bitmap has more than one distinct colour (it is not blank), and write PNGs when `DESKTOP_SHOTS_DIR` is set.
- [ ] **Step 2:** Run `make test-swift FILTER=DesignShotsTests`. Expected: FAIL (catalog missing).
- [ ] **Step 3:** Implement the catalog with the seven shots, `png(_:_:)`, and the Makefile target.
- [ ] **Step 4:** Run `make desktop-shots SHOTS_DIR=build/desktop-shots-before`. Expected: PASS, and 14 PNGs. Open three of them with the Read tool to check they show the intended view, not a blank or error state. `build/` is gitignored; keep this directory for Tasks 4–5.
- [ ] **Step 5:** Commit `test(desktop): design shots harness and reference catalog (#719)`.

---

### Task 3: Gallery and dev-build gate

**Depends on:** Task 2

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/DesignSystem/DesignSystemGallery.swift`
- Create: `WatchtowerDesktop/Sources/App/DevBuild.swift`
- Modify: `WatchtowerDesktop/Sources/App/WatchtowerApp.swift`. Add a `Window("Design Gallery", id: "design-gallery")` scene, and a "Design Gallery" item in `CommandGroup(after: .help)` (`WorkbenchCommands.swift:107` shows the pattern). Both exist only when `DevBuild.isEnabled`.
- Modify: `scripts/build-app.sh`. When `DEV_MODE` is true, `PlistBuddy -c "Add :WTDevBuild bool true"`, next to the `WTBuildFlavor` stamp at line 464.
- Modify: `WatchtowerDesktop/Tests/DesignShots/DesignShotCatalog.swift`. Add a `gallery` shot (900×1400).
- Test: `WatchtowerDesktop/Tests/DevBuildTests.swift`

**Interfaces:**
- Produces:
  - `enum DevBuild { static func isEnabled(info: [String: Any]?) -> Bool; static var isEnabled: Bool }`. The static var reads `Bundle.main.infoDictionary`.
  - `struct DesignSystemGallery: View`, with sections in this order: Tokens (spacing bars, radii, fills, tones), then one `GallerySection(title:)` per component. Later tasks append a section.
  - `struct GallerySection<Content: View>: View`, which takes a title and content.

- [ ] **Step 1:** Write the failing tests:
  - `DevBuildTests`: `XCTAssertFalse(DevBuild.isEnabled(info: [:]))`, `XCTAssertFalse(DevBuild.isEnabled(info: ["WTDevBuild": false]))`, `XCTAssertTrue(DevBuild.isEnabled(info: ["WTDevBuild": true]))`.
  - A ViewInspector test that `DesignSystemGallery` contains a `GallerySection` titled "Tokens".
- [ ] **Step 2:** Run `make test-swift FILTER='DevBuildTests|DesignSystemGalleryTests'`. Expected: FAIL.
- [ ] **Step 3:** Implement per Interfaces.
- [ ] **Step 4:** Run the same filter plus `DesignShotsTests`. Expected: PASS. Run `bash -n scripts/build-app.sh`. Expected: no output.
- [ ] **Step 5:** Commit `feat(desktop): design gallery behind a dev-build gate (#719)`.

---

### Task 4: Promote surfaces and buttons

**Depends on:** Task 3

**Files:**
- Move: `Views/Components/PanelListStyle.swift` → `Views/DesignSystem/PanelSurfaces.swift`, and `Views/Components/PopoverSurface.swift` → `Views/DesignSystem/PopoverSurface.swift`. The content stays the same apart from what Task 1 already moved.
- Create: `Views/DesignSystem/KitButtonStyles.swift`, holding:
  - `PopoverPrimaryButtonStyle`, renamed `KitPrimaryButtonStyle`;
  - `DestructivePrimaryButtonStyle`, renamed `KitDestructiveButtonStyle`;
  - `HeaderIconButtonStyle`, moved out of `WorkbenchHeaderControls.swift:323-348` and renamed `KitIconButtonStyle`.
- Delete: `Views/Components/DestructivePrimaryButtonStyle.swift`.
- Modify: every call site of `.popoverPrimary`, `.destructivePrimary` and `HeaderIconButtonStyle(isOn:)`.
- Modify: `Tests/DestructivePrimaryButtonStyleTests.swift` → `Tests/KitDestructiveButtonStyleTests.swift`. Only type and style names change; the assertions stay identical.
- Modify: the gallery. Add a "Buttons" section with every style, enabled and disabled.

**Interfaces:**
- Consumes: `Fill`, `Motion` (Task 1).
- Produces:
  - `.kitPrimary` (a `PrimitiveButtonStyle`)
  - `.kitDestructive` (a `ButtonStyle`)
  - `.kitIcon(isOn: Bool)` (a `ButtonStyle`)
  - The `KitDestructiveButtonStyle.metrics(for:)` API is unchanged.
- `KitIconButtonStyle` keeps its 7 pt radius, 26 pt square and 14 pt icon exactly. The off-scale 7 stays a private constant (Global Constraints).

- [ ] **Step 1:** Rename the test file and types. Run `make test-swift FILTER=KitDestructiveButtonStyleTests`. Expected: FAIL to build.
- [ ] **Step 2:** Do the moves and renames.
- [ ] **Step 3:** Run `make test-swift FILTER='KitDestructiveButtonStyleTests|DesignShotsTests|PanelTab|Popover'`. Expected: PASS.
- [ ] **Step 4:** Run `make desktop-shots SHOTS_DIR=build/desktop-shots-after`. Compare each `*-before` and `*-after` pair, in both appearances, with the Read tool, and run `cmp` on the files. Expected: byte-identical, or visually identical where `cmp` differs. Investigate any visible difference and fix it before going on.
- [ ] **Step 5:** Run `make lint-swift`, then commit `refactor(desktop): promote surfaces and button styles into DesignSystem (#719)`.

---

### Task 5: Promote segment, chips, headers, card, floating button

**Depends on:** Task 4

**Files:**
- Create: `Views/DesignSystem/SegmentedToggleStyle.swift`. `HeaderSegmentStyle` moves out of `WorkbenchHeaderControls.swift:262-321` and becomes `SegmentedToggleStyle`. Its init `(joinsChevron:isHovered:onHover:)` and its static `fill(isOn:isHovered:)` stay. `KitIconButtonStyle` switches to `SegmentedToggleStyle.fill`.
- Create: `Views/DesignSystem/Chip.swift`, holding:
  - `WorkbenchBoardChip`, renamed `Chip`;
  - `WorkbenchCapsuleBadge`, renamed `CountBadge`;
  - `AgentTag`, renamed `OutlineTag`;
  - `WorkbenchDetailMenuLabel`, renamed `MenuLabel`.
  Each keeps its exact values; this is a rename, not a merge. Spec §9 leaves merging to the builder, and the decision is to keep the four recipes, because merging would change pixels.
- Create: `Views/DesignSystem/SectionHeader.swift`. `WorkbenchDetailSectionHeader` is renamed `SectionHeader`.
- Create: `Views/DesignSystem/Card.swift`. Add `func card(selected: Bool = false) -> some View`, extracted from the board card's outline (`WorkbenchBoardCardView.swift:61-63`): a `Radius.row` rounded rect with a `Stroke.hairline` `separatorColor` border, or `Stroke.selection` accent when selected. The fill stays the caller's `background`, because the board card's fill is state-dependent. `WorkbenchBoardCardView` switches to it.
- Create: `Views/DesignSystem/FloatingButton.swift`. `struct FloatingButtonLabel: View` takes `(title: String, systemImage: String)` and is extracted from `ChatFeedView.swift:183-192`, with the `.shadow` included. `ChatFeedView` and the Calendar "Now" button (`CalendarEventsView.swift:~571`) switch to it only if the Calendar button's values are identical; otherwise only Chat switches.
- Modify: every call site of the renamed types (grep each old name), and the gallery (one section per component).
- Test: `Tests/DesignKitComponentsTests.swift`

**Interfaces:**
- Consumes: Task 1 tokens; `KitIconButtonStyle` (Task 4).
- Produces: `SegmentedToggleStyle`, `Chip(text:color:dot:)`, `CountBadge(text:)`, `OutlineTag(text:)`, `MenuLabel(text:systemImage:color:isMenu:)`, `SectionHeader(title:systemImage:count:)`, `View.card(selected:)`, `FloatingButtonLabel(title:systemImage:)`.

- [ ] **Step 1:** Write `DesignKitComponentsTests`, with these tests:
  - `testSegmentFillFollowsOnAndHover`: `SegmentedToggleStyle.fill(isOn: true, isHovered: false) == Color.accentColor.opacity(0.20)`, `fill(isOn: false, isHovered: true) == Color.primary.opacity(0.07)` and `fill(isOn: false, isHovered: false) == .clear`.
  - `testSegmentReportsHoverToItsParent`: a ViewInspector `callOnHover(true)` on the rendered button calls `onHover` with `true`.
  - `testSectionHeaderHidesAZeroCount`: `SectionHeader(title: "Asks", systemImage: "x", count: 0)` contains no `Text("0")`.
  - `testReadOnlyMenuLabelHasNoChevron`: `MenuLabel(…, isMenu: false)` contains no image named `chevron.down`.
- [ ] **Step 2:** Run `make test-swift FILTER=DesignKitComponentsTests`. Expected: FAIL.
- [ ] **Step 3:** Do the moves and renames.
- [ ] **Step 4:** Run `make test-swift FILTER='DesignKitComponentsTests|DesignShotsTests|WorkbenchBoard|WorkbenchHeader|ChatFeed'`. Expected: PASS. Then do the before/after shot comparison exactly as in Task 4 Step 4. Expected: identical.
- [ ] **Step 5:** Run `make lint-swift`, then commit `refactor(desktop): promote segment, chips, headers, card and floating button (#719)`.

---

### Task 6: New components

**Depends on:** Task 5

**Files:**
- Modify: `Views/DesignSystem/KitButtonStyles.swift`. Add `KitSecondaryButtonStyle` (`.kitSecondary`) and `KitQuietButtonStyle` (`.kitQuiet`).
- Create:
  - `Views/DesignSystem/KitFieldStyle.swift`
  - `Views/DesignSystem/SettingsRows.swift`
  - `Views/DesignSystem/KitRow.swift`
  - `Views/DesignSystem/PanelSplit.swift`
- Modify: the gallery (sections Buttons, Fields, Settings, Rows, Panel split), and `DesignShotCatalog` (add `kit-new-components`).
- Test: `Tests/DesignKitNewComponentsTests.swift`

**Interfaces:**
- Consumes: Task 1 tokens; `Motion.toggle`.
- Produces:
  - `.kitSecondary`: label `.primary`, `.controlSize`-aware height like `KitDestructiveButtonStyle.metrics(for:)`, background `Fill.card` at rest, `Fill.hover` on hover or press, `Radius.control`, 0.5 opacity when disabled.
  - `.kitQuiet`: no fill at rest, `Fill.hover` on hover or press, accent label, `Radius.control`.
  - `.textFieldStyle(.kit)` (`KitFieldStyle: TextFieldStyle`): `textBackgroundColor` fill, `Stroke.hairline` `separatorColor` border (accent `Stroke.selection` when focused), `Radius.control`, horizontal padding `Spacing.compact`, vertical `Spacing.small`. It reads `\.onPopoverSurface` and uses a translucent well there, like the existing comment field.
  - `SettingsSection<Content: View>(title: String, footer: String? = nil, @ViewBuilder content:)`: a `SectionHeader`-style title, then rows on one `Fill.card` container with `Radius.container`, rows separated by `Spacing.regular`, no dividers.
  - `SettingRow<Control: View>(title: String, caption: String? = nil, @ViewBuilder control:)`: title `.body` and caption `.caption` secondary on the left; the control trailing. A `Toggle` inside gets `.toggleStyle(.switch).controlSize(.small)` from the row.
  - `View.kitRow(isSelected: Bool)`: padding `Spacing.compact` vertical and `Spacing.regular` horizontal, full `Radius.row`, fill `Fill.selected` when selected, else `Fill.hover` on hover, else clear.
  - `PanelSplit<Main: View, Panel: View>(isPanelShown: Bool, width: PersistedInspectorWidth, @ViewBuilder main:, @ViewBuilder panel:)`: extract the layout the Workbench target panel uses with `PersistedInspectorWidth` and `ResizeHandle` (`grep -rn PersistedInspectorWidth WatchtowerDesktop/Sources`). The panel animates in and out with `Motion.panel`. Do not switch the Workbench to it in this task, so its pixels don't move.

- [ ] **Step 1:** Write `DesignKitNewComponentsTests`, with these tests:
  - `testSettingRowStylesAToggleAsASmallSwitch` (ViewInspector: the toggle's style is `SwitchToggleStyle`);
  - `testSettingsSectionDrawsNoDivider` (no `Divider` in the tree);
  - `testSecondaryButtonDimsWhenDisabled` (render probe: the disabled plate is lighter than the enabled one in aqua);
  - `testKitRowFillFollowsSelection` (a static `KitRow.fill(isSelected:isHovered:)` returns `Fill.selected`, `Fill.hover`, `.clear`);
  - `testPanelSplitHidesThePanel` (`isPanelShown: false` leaves no panel content in the tree).
- [ ] **Step 2:** Run `make test-swift FILTER=DesignKitNewComponentsTests`. Expected: FAIL.
- [ ] **Step 3:** Implement per Interfaces.
- [ ] **Step 4:** Run `make test-swift FILTER='DesignKitNewComponentsTests|DesignShotsTests'`. Expected: PASS. Run `make desktop-shots` and look at `kit-new-components-light.png` and `-dark.png`. They should read like the Workbench (soft fills, no hard borders); fix anything that looks stock.
- [ ] **Step 5:** Run `make lint-swift`. Run `make periphery-check`; expected ✓, because the gallery calls every new component. Commit `feat(desktop): kit buttons, field, settings rows, row and panel split (#719)`.

---

### Task 7: Lint rules and baseline

**Depends on:** Task 6

**Files:**
- Modify: `WatchtowerDesktop/.swiftlint.yml`. Add a `custom_rules:` block.
- Modify: `WatchtowerDesktop/.swiftlint-baseline.json` (regenerated).

Rules. Each has `included: ".*/Sources/(Views|App)/.*\\.swift"`, `excluded: ".*/Sources/Views/DesignSystem/.*"` and `severity: error`, and its message names the kit replacement:

| id | regex | message |
|---|---|---|
| `kit_no_form` | `\bForm\s*\{` | Use SettingsSection / SettingRow (DesignSystem). |
| `kit_no_groupbox` | `\bGroupBox\b` | Use .card() or SettingsSection (DesignSystem). |
| `kit_no_stock_buttons` | `\.buttonStyle\(\s*\.bordered(Prominent)?\s*\)` | Use .kitPrimary / .kitSecondary / .kitQuiet / .kitDestructive. |
| `kit_no_segmented_picker` | `\.pickerStyle\(\s*\.segmented\s*\)` | Use SegmentedToggleStyle. |
| `kit_no_rounded_field` | `\.textFieldStyle\(\s*\.roundedBorder\s*\)` | Use .textFieldStyle(.kit). |
| `kit_no_raw_metrics` | `\.padding\((\s*\.\w+\s*,)?\s*[1-9][0-9.]*\s*\)\|spacing:\s*[1-9][0-9.]*\|cornerRadius:\s*[1-9][0-9.]*\|\.system\(size:\s*[0-9]` | Use Spacing / Radius / IconSize tokens. |
| `kit_no_color_opacity` | `\w\.opacity\(\s*0?\.[0-9]` | Use Fill / ChipTint tokens (view .opacity for dimming is fine). |
| `kit_no_rgb_color` | `Color\(\s*(red:\|hex)\|NSColor\(\s*(calibratedRed\|srgbRed\|red):` | Use semantic system colours. |

(`\|` in the table is a literal `|` in the YAML regex.)

- [ ] **Step 1:** Record the baseline entry count per rule before the change: `jq '[.[] | .violation.ruleIdentifier] | group_by(.) | map({(.[0]): length}) | add' WatchtowerDesktop/.swiftlint-baseline.json > build/kit-baseline-before.json`. Adjust the jq path to the file's actual shape.
- [ ] **Step 2:** Add the rules. Run `cd WatchtowerDesktop && swiftlint lint --strict --baseline .swiftlint-baseline.json > build/kit-lint.log 2>&1; echo "exit=$?"`. Expected: a non-zero exit, with violations only from `kit_*` rules.
- [ ] **Step 3:** Regenerate the baseline: `swiftlint lint --strict --write-baseline .swiftlint-baseline.json`. Re-run the per-rule count. Expected:
  - every non-`kit_*` rule has the same count as in Step 1;
  - the `kit_*` counts are the absorbed legacy uses;
  - there are no `kit_*` entries for files under `DesignSystem/`.
- [ ] **Step 4:** Run `make lint-swift`. Expected: pass. Then prove each rule fires on new code: add a scratch file `Sources/Views/KitLintProbe.swift` with one line per rule, run swiftlint, and expect exactly 8 `kit_*` errors. Delete the file.
- [ ] **Step 5:** Commit `chore(desktop): lint new code onto the design kit (#719)`.

---

### Task 8: The guide and where agents meet it

**Depends on:** Task 7

**Files:**
- Create: `docs/design/desktop-style-guide.md`. One page, in English, following spec §7:
  - the principles of spec §3.1;
  - a token table;
  - a component table (name → replaces → when to use), each with its gallery shot. Copy PNGs from `build/desktop-shots` into `docs/design/shots/`, light only, cropped to the section.
  - the eight lint rules with one line of why each;
  - the shots workflow: register in `DesignShotCatalog`, run `make desktop-shots`, look, and attach to the PR. A new window goes to the owner as a review ask with its shots.
- Modify: `.claude/skills/add-desktop-feature/SKILL.md`:
  - step 4: "build views from `Sources/Views/DesignSystem/`; read `docs/design/desktop-style-guide.md` first";
  - a new step 6a: "register the screen in `DesignShotCatalog`, run `make desktop-shots`, look at both PNGs";
  - step 7: add `make desktop-shots`.
- Modify: `docs/review/review-rules.md`, Swift / Desktop conventions. Add a rule: new UI uses the kit, and the reviewer checks layout as well as lint (panels not pop-ups, one prominent action, no row dividers, empty states), citing the guide.
- Modify: `CLAUDE.md`. Add one line under the Desktop notes (after the "House conventions for Desktop code" paragraph) linking the guide and `make desktop-shots`.
- Modify: `docs/superpowers/specs/2026-10-19-desktop-style-guide-design.md`. Set the status to "implemented" and add a one-line note on any decision this plan took (the four chip recipes kept apart; component-level reference shots).

- [ ] **Step 1:** Write the guide and copy the shots. Run `bash scripts/leak-check.sh` if it accepts a path; otherwise grep the new files for `@` and absolute paths. Expected: none.
- [ ] **Step 2:** Make the skill, review-rules and `CLAUDE.md` edits.
- [ ] **Step 3:** Commit `docs: Desktop style guide page, skill and review rules (#719)`.

---

## Controller gate (once, after Task 8)

Run `make test-swift`, `make lint-all`, `make periphery-check`, `make desktop-shots`, then the `local-review` skill on the branch, then the PR into `main`.
