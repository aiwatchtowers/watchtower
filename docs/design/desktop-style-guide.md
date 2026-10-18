# Desktop style guide

One page for whoever builds a Desktop screen. The kit in `WatchtowerDesktop/Sources/Views/DesignSystem/` is the detail; this page says which part to reach for and why. Design and decisions: `docs/superpowers/specs/2026-10-19-desktop-style-guide-design.md`. New screens only; old screens move onto the kit later.

The reference is the app's own good screens: Workbench, Calendar and AI Chat. A screen built from the kit should look like them without you choosing a number.

## Principles

- **Compact by default.** `.controlSize(.small)`, secondary text `.caption`.
- **Panels, not pop-ups.** Detail opens in a resizable side panel (`PanelSplit`). A sheet is only for a short blocking flow: a confirmation, connecting an account, a one-field form. A popover is only a small picker anchored to its control.
- **One readable column.** Long text and feeds keep a maximum width (Chat: 760 pt) and centre in wide windows.
- **Structure from space and fills, not lines.** Spacing and a section header separate sections; a soft card fill separates groups. A hairline separates panes, never rows. No `Divider()` between rows, never two in a row.
- **Actions appear where they apply.** Row actions show on hover. At most one prominent action per screen.
- **Empty, loading and error states** use `FeatureEmptyState`, `TabEmptyState` or `ContentAwareEmptyState` (see `docs/features/first-run.md`). Also shared and part of the kit: `SearchField`, `ResizeHandle`, `WriteErrorBanner`.
- **Text styles and semantic colours only.** `.headline` to `.caption2` with `.weight(...)`, `.monospacedDigit()` for changing numbers; `.primary`/`.secondary`/`.tertiary`, `Color.accentColor`, `Surface.*`. No hex or RGB. Status and priority colours come from `Tone`; never pick `.red` yourself.

## Tokens

Use the token, never the number. The scale is closed: a screen that needs a new step adds a token to `DesignSystem/` in the same PR.

| Token | Values |
|---|---|
| `Spacing` | `tight` 2, `small` 4, `compact` 6, `regular` 8, `cozy` 10, `medium` 12, `large` 16, `page` 20, `wide` 24, `hero` 40 (literal `0` is fine) |
| `Radius` | `mark` 4, `control` 6, `row` 8, `container` 10, `bubble` 16, `pill` 18; chips and badges are `Capsule` |
| `Fill` | `rest` 0.04, `card` 0.06, `hover` 0.07 (primary); `selected` 0.12, `on` 0.20 (accent). `ChipTint`: tone at 0.14 with a 0.5 pt stroke at 0.3 |
| `Stroke` | `hairline` 0.5 pt separator, `selection` 1.5 pt accent |
| `Surface` | `detail`, `window`, `text`, `control` |
| `Tone` | `status(_:)` and `priority(_:)` colour map |
| `IconSize` | `chevron` 8, `header` 14, `composer` 16, `composerLarge` 24 |
| `Motion` | `toggle` (`.snappy` 0.15 s), `panel` (`.easeInOut` 0.2 s) |

Shadows exist only on floating buttons (`FloatingButtonLabel`).

## Components

| Component | Replaces | Use it for |
|---|---|---|
| `.buttonStyle(.kitPrimary)` | `.borderedProminent` | the one prominent action of a screen or popover |
| `.kitSecondary` | `.bordered` | ordinary actions: card fill, hover fill |
| `.kitQuiet` | `.borderless`, `.plain` text buttons | low-emphasis text actions |
| `.kitDestructive` | red bordered buttons | delete, discard; confirm first |
| `.kitIcon(isOn:)` | icon buttons | header and toolbar icon buttons, toggled or not |
| `SegmentedToggleStyle` | `Picker` with `.segmented` | 2 to 5 mutually exclusive options |
| `Chip`, `CountBadge`, `OutlineTag` | hand-drawn capsules | status or priority chip; count badge; outlined tag. Four recipes kept apart on purpose (merging would change pixels) |
| `MenuLabel` | default `Menu` chrome | the label of a menu or read-only value in a panel |
| `SectionHeader` | bold `Text` plus `Divider()` | the title of a section, with optional count |
| `.card(selected:)` | `GroupBox`, ad-hoc rounded backgrounds | a group on a soft fill with a hairline or selection outline |
| `.kitRow(isSelected:)` | rows separated by dividers | list rows: hover fill, selection fill, row radius |
| `.textFieldStyle(.kit)` | `.roundedBorder` | text fields |
| `SettingsSection`, `SettingRow` | `Form`, `LabeledContent`, bare `Toggle` | settings blocks of new windows; toggles become small switches |
| `PanelSplit` | sheets and pop-ups for detail | main content plus a resizable side panel |
| `panelSurface()`, `panelListStyle()`, `panelTab(isSelected:)` | stock list chrome | side-panel lists and tabs |
| `.popoverSurface()` | custom popover backgrounds | the body of a popover |
| `FloatingButtonLabel` | one-off shadows | "Jump to latest" style floating buttons |

<!-- shot: buttons -->
<!-- shot: workbench-header -->
<!-- shot: workbench-panel-parts -->
<!-- shot: workbench-board-cards -->
<!-- shot: sessions-panel -->
<!-- shot: chat-rows -->
<!-- shot: calendar-rows -->
<!-- shot: kit-new-components -->

The gallery shows every token and component in light and dark. In a dev build (`make app-dev`) open it from Help, Design Gallery.

## Lint rules

New code under `Sources/Views/` and `Sources/App/` (not `DesignSystem/`) fails `make lint-swift` on these. There is no inline `swiftlint:disable` for them; existing code is in the baseline.

| Rule id | Forbids | Why |
|---|---|---|
| `kit_no_form` | `Form { }` | stock grouped forms look foreign; use `SettingsSection` / `SettingRow` |
| `kit_no_groupbox` | `GroupBox` | hard stock chrome; use `.card()` or `SettingsSection` |
| `kit_no_stock_buttons` | `.buttonStyle(.bordered)`, `.borderedProminent` | clumsy next to the app; use the `.kit*` styles |
| `kit_no_segmented_picker` | `.pickerStyle(.segmented)` | use `SegmentedToggleStyle` |
| `kit_no_rounded_field` | `.textFieldStyle(.roundedBorder)` | use `.textFieldStyle(.kit)` |
| `kit_no_raw_metrics` | numeric literals in `.padding`, `spacing:`, `cornerRadius:`, `.font(.system(size:))` | eleven paddings and ten radii is how screens drift; use `Spacing`, `Radius`, `IconSize` |
| `kit_no_color_opacity` | `Color.x.opacity(0.n)` fills and tints | use `Fill` and `ChipTint` (the view `.opacity` for dimming is fine) |
| `kit_no_rgb_color` | `Color(red:)`, `Color(hex)`, `NSColor(calibratedRed:)` | semantic system colours adapt to light and dark |

Lint cannot see layout. Reviewers also check: panels not pop-ups, one prominent action, no row dividers, empty states present.

## See your screen

Every new screen is looked at before it merges.

1. Register it in `DesignShotCatalog` (`WatchtowerDesktop/Tests/DesignShots/`) on fixture data (`acme`, `example.com`, never live data).
2. Run `make desktop-shots DESKTOP_SHOTS=<dir>`. It writes `<name>-light.png` and `<name>-dark.png`.
3. Open both PNGs and look: soft fills, no hard borders, nothing stock-looking, nothing clipped.
4. Attach them to the PR. A new window also goes to the owner as a review ask with its shots before merge.
