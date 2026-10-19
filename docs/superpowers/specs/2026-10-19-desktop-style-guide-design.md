# Desktop style guide: one visual language, a design kit, rules that hold (design)

**Date:** 2026-10-19
**Status:** proposed. The owner's decisions (asks #399, #404, #407, #409) are binding and listed in §1.
**Board:** target #719.
**Implementation:** docs/superpowers/plans/2026-10-19-desktop-style-guide.md (in progress). Plan decisions: the four chip recipes (`Chip`, `CountBadge`, `OutlineTag`, `MenuLabel`) are kept apart, because merging would change pixels; reference shots are component-level.
**Inputs:** a read-only survey of the Workbench, Calendar and AI Chat code (2026-10-18), and counts of stock-control use across `WatchtowerDesktop/Sources` taken the same day. Paths are relative to `WatchtowerDesktop/Sources/`.

---

## 1. Why, and the binding decisions

New Desktop screens look bad. The owner named three causes (ask #399): small inconsistencies (spacing, type, radii, fills), weak layout and UX, and stock SwiftUI controls that look clumsy next to the rest of the app.

The code shows why this keeps happening:

- There is no design layer. No `Spacing`, `Radius` or `Theme` exists anywhere.
- The code uses 11 different `.padding(N)` values and 10 different `cornerRadius` values.
- About 500 buttons use the stock `.bordered`, `.borderless` or `.plain` styles, and only 9 custom `ButtonStyle`s exist.
- There are 249 `Divider()`s, 28 `GroupBox`es, and about 100 `Picker`s and 90 `Toggle`s left unstyled.
- The best-looking controls are `private` inside the Workbench files, so a new feature cannot reuse them. It assembles the screen from stock parts with numbers picked by eye.
- The agent writing the screen never sees the result.

Binding decisions:

1. **The reference is the app's own good screens** (ask #407): Workbench (terminal and board), Calendar and AI Chat. The style guide names and generalises what they already do. It does not invent a new look.
2. **Style guide first** (ask #404). This work delivers the visual language, the design kit and the rules that keep new code on them.
3. **Old screens are out of scope** (ask #409). Settings, People, Ideas, Targets, Digests and the account sheets are restyled later and separately, after new windows have been designed on the kit.

## 2. Goals, non-goals, anti-goals

**Goals**

- A new screen built from the kit looks like the Workbench, Chat and Calendar without the author choosing a single number.
- Using the kit is the easiest way to build a screen. Building one by hand from stock parts fails lint.
- Every new screen is seen before it merges: by the agent, in a rendered screenshot, and by the owner, in the review ask.

**Non-goals**

- Restyling existing screens (decision 3). One exception: the reference screens switch from their private styles to the kit's public ones, with no visible change (§4.1).
- A brand palette, an accent colour asset, custom fonts or a new icon set. The app stays on semantic system colours, text styles and SF Symbols, as the reference screens are.
- The iPhone app. It already has its own `Sources/DesignSystem/` (`docs/superpowers/specs/2026-10-11-mobile-design-pass-design.md`). The Desktop token values match the phone's where both apps have the same thing, but the code is not shared.
- Go code.

**Anti-goals.** Each of these would mean the work failed, even if it builds:

- The Workbench, Chat or Calendar look different afterwards.
- The kit grows into a framework of wrappers around every SwiftUI control. A component exists only when at least two screens need it, or when it replaces a stock control that rule §5 forbids.
- The rules apply to new code only on paper, because the lint has an escape hatch that everyone uses.

## 3. The visual language

These values were measured on the reference screens. The tokens in §4.2 hold them, and new code uses the tokens, never the numbers.

### 3.1 Density and layout

- **Compact by default.** Controls use `.controlSize(.small)`; secondary text is `.caption`.
- **Panels, not pop-ups.** Detail opens in a resizable side panel inside the window, the way `WorkbenchTargetPanel` replaced the old target popup. A sheet is only for a short, blocking flow: confirming, connecting an account, a one-field form. A floating popover is only for a small picker anchored to its control.
- **One readable column.** Long text and feeds keep a maximum width (Chat: 760 pt) and centre in wide windows.
- **Structure from space and fills, not lines.** Sections are separated by spacing and a section header. Groups are separated by a soft card fill. A hairline separates panes, never rows.
- **Actions appear where they apply.** Row actions show on hover (Chat: `.opacity(hovering ? 1 : 0)`). A screen has at most one prominent action.
- **Empty, loading and error states** use the existing `FeatureEmptyState` / `TabEmptyState` / `ContentAwareEmptyState`. See `docs/features/first-run.md`.

### 3.2 Values

| Role | Value | Seen in |
|---|---|---|
| Spacing scale | 2, 4, 6, 8, 10, 12, 16, 20 | Workbench mostly uses 4, 6 and 8, and 10 for the kanban |
| Page or column margin | 20 (16 in compact density) | `ChatDensity` |
| Radius: small inner item | 4 | small marks |
| Radius: control or segment | 6 | header segments |
| Radius: row or card | 8 | board card, Calendar row, inline notice |
| Radius: column or container | 10 | kanban column and cell |
| Radius: message bubble | 16 | the Chat user bubble |
| Radius: input pill | 18 | the Chat composer |
| Chip, badge | `Capsule` | board chips |
| Fill: resting cell | `primary` at 0.04 | kanban cell |
| Fill: card or lane | `primary` at 0.06 | board card |
| Fill: hover | `primary` at 0.07 (the survey saw 0.05–0.08, unified to one value) | panel tab, header controls |
| Fill: selected or drop target | accent at 0.12 | kanban drop target |
| Fill: control that is on | accent at 0.20 | header segment |
| Chip tint | tone at 0.14, with a 0.5 pt stroke of the tone at 0.3 | `WorkbenchBoardChip` |
| Hairline | `separatorColor`, 0.5 pt | card outline |
| Selection outline | accent, 1.5 pt | selected card |
| Surfaces | `NSColor.detailBackground`, `windowBackgroundColor`, `textBackgroundColor`, `controlBackgroundColor` | `PanelListStyle.swift` |
| Shadow | only on floating buttons: black at 0.2, radius 3, y 1 | "Jump to latest", Calendar "Now" |
| Motion: toggle | `.snappy(duration: 0.15)` | header segments |
| Motion: panel or toast | `.easeInOut(duration: 0.2)` | Workbench panels |

### 3.3 Type and colour

- **Text styles only.** Use `.headline`, `.subheadline`, `.body`, `.callout`, `.caption` and `.caption2`, with `.weight(…)`. Fixed point sizes are allowed only for icons, and only through `IconSize` (§4.2). Numbers that change get `.monospacedDigit()`.
- **Roles:**
  - section header: `.subheadline.weight(.semibold)`, secondary colour;
  - meta line: `.caption`, secondary colour;
  - badge text: `.caption2.weight(.semibold)`.
- **Semantic colours only.** Text uses `.primary`, `.secondary` and `.tertiary`; accent is `Color.accentColor`; surfaces are as in §3.2. No hex or RGB literals.
- **Status and priority colours come from one map** (`Tone`, §4.2). Today that map is the Targets-tab colours that `WorkbenchBoardChip` already copies. A screen asks the map; it never picks `.red` or `.orange` itself.

## 4. The design kit

### 4.1 Where it lives, and how the reference screens move onto it

The kit lives in a new directory, `Sources/Views/DesignSystem/`, in the app target. `WatchtowerCore` stays SwiftUI-free and AppKit-free, as `Package.swift` and `PublicAPISurfaceTests` pin. The owner was told earlier "in WatchtowerCore"; this spec corrects that. The kit cannot go there.

Most of the kit already exists as private or local code in the reference screens. The first step is to **promote, not rewrite**:

- Move the existing type into `DesignSystem/` and make it internal.
- Rename it to its kit name.
- Switch its old call sites to the new name.

That step must cause no visible change. It is checked with before/after screenshots of the reference screens (§6).

How the reference values meet the scale *(builder check; my call)*:

- **A promoted component keeps its exact current values.** If a value is on the scale, it uses the token. If it is off the scale (for example the 0.05 or 0.08 hover fill, a 7 pt radius, a 14 pt padding), it stays as a private constant inside the component, in `DesignSystem/`. Values are never tuned during promotion. Unifying them is a later, visible change the owner would approve separately.
- **Call-site code of the reference screens is not rewritten.** Only the names of the promoted types change. The raw literals the reference screens keep go into the lint baseline (§5) like any other existing code.
- **The tokens of §3.2 are what new code uses.** For example, `Fill.hover` is 0.07 for a new screen, even though older components keep 0.05 or 0.08.

### 4.2 Tokens

| Token | What it holds |
|---|---|
| `Spacing` | the scale in §3.2, with the phone's names: `tight` 2, `small` 4, `compact` 6, `regular` 8, `cozy` 10, `medium` 12, `large` 16, `page` 20, plus `wide` 24 and `hero` 40 for empty states and wide gaps *(builder check; my call)*. A literal `0` stays allowed. The scale is closed for screens: a screen that needs a new step adds a token to `DesignSystem/` in the same PR, where review sees it, never an inline number. |
| `Radius` | `mark` 4, `control` 6, `row` 8, `container` 10, `bubble` 16, `pill` 18 |
| `Fill` | `rest`, `card`, `hover`, `selected` and `on`, as `ShapeStyle`s (§3.2) |
| `Stroke` | `hairline` (0.5 pt separator) and `selection` (1.5 pt accent) |
| `Surface` | the four surfaces of §3.2. `NSColor.detailBackground` moves here. |
| `Tone` | the one status/priority/state colour map (§3.3) |
| `IconSize` | the icon point sizes the reference screens use: 8–9 for chevrons, 14 for header icons, 16 and 24 for the composer |
| `Motion` | `toggle` and `panel` (§3.2) |

### 4.3 Components

Each component below names its source. "Promote" means the code already exists and moves into the kit (§4.1). "New" means it has to be written, because a rule in §5 forbids the stock control it replaces.

| Component | Replaces | Source |
|---|---|---|
| `KitButtonStyle`: `.primary`, `.secondary`, `.icon`, `.destructive`, `.quiet` | `.bordered`, `.borderedProminent` | Promote `PopoverPrimaryButtonStyle`, `HeaderIconButtonStyle`, `DestructivePrimaryButtonStyle`. New: `.secondary` (the card fill with the hover fill) and `.quiet` (text only, with the hover fill). |
| `SegmentedToggle` (2–5 options) | `Picker` with `.segmented` | Promote `HeaderSegmentStyle` (`WorkbenchHeaderControls.swift:271`) |
| `Chip` and `CountBadge` | hand-drawn capsules | Promote `WorkbenchBoardChip` and `WorkbenchCapsuleBadge` / `AgentTag`, then merge them into one recipe |
| `Card` (`.card(selected:)` modifier) | `GroupBox`, ad-hoc `.background(…, in: RoundedRectangle)` | Promote the board-card background and outline (`WorkbenchBoardCardView.swift:62-63`) |
| `KitRow` (hover fill, selection fill, row radius) | rows with dividers between them | Promote the row recipe of the sessions panel and Chat history (`PanelListStyle.swift`) |
| `SectionHeader` | bold `Text` plus `Divider()` | Promote `WorkbenchDetailSectionHeader` (`WorkbenchTargetPanelParts.swift:6`) |
| `MenuLabel` | default `Menu` chrome | Promote `WorkbenchDetailMenuLabel` (`WorkbenchTargetPanelParts.swift:28`) |
| Panel surfaces: `panelSurface()`, `panelListStyle()`, `detailBackground()`, `PanelTab` | — | Promote `PanelListStyle.swift` as it is |
| `.popoverSurface()` | — | Promote `PopoverSurface.swift` as it is |
| `FloatingButton` (the floating-shadow recipe) | one-off shadows | Promote "Jump to latest" (`ChatFeedView.swift:190`) |
| `KitFieldStyle` | `.textFieldStyle(.roundedBorder)` | New: the text background fill, a hairline, the control radius |
| `SettingsSection` / `SettingRow` (label and caption on the left, control on the right; a toggle is a small switch) | `Form` with `.formStyle(.grouped)`, `LabeledContent`, a bare `Toggle` | New, for the settings blocks of new windows. Old Settings move onto it later (decision 3). |
| `PanelSplit` (main content plus a resizable side panel) | sheets and popups used for detail | Promote the Workbench target-panel layout with `PersistedInspectorWidth` and `ResizeHandle` |

Empty states (`FeatureEmptyState`, `TabEmptyState`), `SearchField`, `ResizeHandle` and `WriteErrorBanner` are already shared and stay where they are. The style guide page lists them as kit parts.

### 4.4 Gallery

Superseded by docs/superpowers/specs/2026-10-19-design-gallery-window-design.md.

`DesignSystemGallery` is a view that shows every token and component, in light and dark mode, in every state: rest, hover, selected, disabled. It is the kit's living documentation, and the input to the screenshots in §6.

How the gallery opens *(builder check; my call)*:

- It is gated at run time, not by `#if DEBUG`, because `make app-dev` builds in release.
- It appears as a menu item only in a dev build. A shipped release never shows it.
- The app has no runtime dev marker today. The builder picks one: for example an `Info.plist` key that `build-app.sh --dev` writes, or a user default.
- The gallery is also the first caller of the components written in step 3 of §8. Rule §5 forbids the stock controls they replace, so they must exist before any new window does; this is the exception the anti-goals allow. Because the gallery calls them, Periphery does not flag them.

## 5. Rules for new code, enforced by lint

New SwiftLint `custom_rules` with severity `error` go into `WatchtowerDesktop/.swiftlint.yml`. They apply to `Sources/Views/` and `Sources/App/`, excluding `Sources/Views/DesignSystem/`. The regexes are the builder's to write; the intent is fixed:

1. No `Form` and no `GroupBox`. Use `SettingsSection` or `Card`.
2. No `.buttonStyle(.bordered)` and no `.buttonStyle(.borderedProminent)`. Use `KitButtonStyle`.
3. No `.pickerStyle(.segmented)`. Use `SegmentedToggle`.
4. No `.textFieldStyle(.roundedBorder)`. Use `KitFieldStyle`.
5. No numeric literals other than `0` in `.padding(…)`, `spacing:`, `cornerRadius:` or `.font(.system(size:…))`. Use the tokens.
   - **Opacity** *(builder check; my call)*: the rule bans only a *colour* opacity, meaning `.opacity(0.x)` written directly after an identifier, as in `Color.primary.opacity(0.06)`, `color.opacity(0.14)` or `accentColor.opacity(0.12)`. Those are the fills and tints, and `Fill` and `Tone` cover them.
   - The view modifier `.opacity(…)`, used to dim content or to show and hide it, is not linted. Dimming has no token in this work.
6. No `Color(red:…)`, `Color(hex…)` or `NSColor(calibratedRed:…)`.

`Divider()` is not linted, because a pane hairline is legitimate. The style guide page and the review checklist cover it instead: no dividers between rows, and never two in a row.

**Existing code** goes into the existing baseline (`WatchtowerDesktop/.swiftlint-baseline.json`, already used by `make lint-swift`). Every current violation is recorded once, so only new lines fail. When an old screen is later moved onto the kit, its entries leave the baseline. There is no inline `swiftlint:disable` for these rules; that is the escape hatch the anti-goals forbid. The one place allowed raw values is `DesignSystem/`.

## 6. Seeing the result

- **`make desktop-shots`** renders the gallery and every screen registered for shots into PNGs, in light and dark mode, into `build/desktop-shots/`. Each screen is rendered on fixed sample data (`acme`, `example.com`, never live data), the same idea as the phone's `make mobile-shots`. The builder chooses the mechanism: an `ImageRenderer`/`NSHostingView` test filtered by a class name, or a debug launch argument. It must run as a filtered test target or a single command, never as an unfiltered `swift test`.
- **Promotion check (§4.1).** Shots of the Workbench board and target panel, the Chat feed and composer, and the Calendar list are taken before and after promotion. They must match. A difference is a bug in the promotion.
  - *(builder check; my call)* The agent and the reviewer compare the shots by eye. This is not an automated pixel diff, so no deterministic harness is needed up front.
  - The screens render on the test fixture database (`TestDatabase`), with a fixed window size.
  - The terminal and the Monaco code viewer (AppKit and WebKit views that `ImageRenderer` cannot draw) are left out. Promotion does not touch them.
- **Every new screen** registers itself for shots. Its PR carries the shots, and the agent looks at them before asking for review. A new window also goes to the owner as a review ask with its shots before merge (the owner's note on AI-17: "design it, confirm with the owner").

## 7. The written guide and where agents meet it

- **`docs/design/desktop-style-guide.md`** is one page for whoever builds a screen. It covers the principles of §3.1, the tokens and components with a shot of each from the gallery, the dos and don'ts of §5 with the reasons, and the shots workflow of §6. It is short; the kit and the gallery are the detail.
- The **`add-desktop-feature` skill**:
  - step 4 says to build views from `DesignSystem/` and to read the guide first;
  - a new step says to register the screen for shots and look at them;
  - step 7 adds `make desktop-shots`.
- **`docs/review/review-rules.md`**, Swift section, gets a rule pointing at the guide. The reviewer checks layout as well as lint: panels not pop-ups, one prominent action, no row dividers, empty states.
- A **`CLAUDE.md`** line under the Desktop notes links the guide.

## 8. Order (the plan's to refine)

1. Tokens, the gallery, the shots command, and before-shots of the reference screens.
2. Promote the existing components and switch the reference screens onto them. Check with after-shots.
3. Write the new components: `.secondary` and `.quiet` buttons, `KitFieldStyle`, `SettingsSection`/`SettingRow`, `PanelSplit`.
4. The lint rules, the regenerated baseline, the guide page, and the skill, review-rules and `CLAUDE.md` updates.

The first new windows built on the kit are not part of this work. Board targets that already ask for a redesign "by the style guide", such as the AI-17 automation editor and the AI-14 board column editor, start after it lands.

## 9. Left to the builder

- Exact type and file names inside `DesignSystem/`, as long as the token names of §4.2 stay recognisable next to the phone's.
- Whether `KitButtonStyle` is one style with a variant or several styles.
- The lint regexes, and how the baseline is regenerated without picking up unrelated rules.
- The shots mechanism (§6).
- Whether to merge `Chip` and `CountBadge` into one type.
