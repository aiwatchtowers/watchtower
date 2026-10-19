# Design gallery as a separate live window, with a taxonomy (design)

**Date:** 2026-10-19
**Status:** proposed.
**Amends:** `docs/superpowers/specs/2026-10-19-desktop-style-guide-design.md` §4.4 (Gallery). The rest of that spec stands.
**Board:** target #760 under #719.

## 1. Why, and the decisions

PR #419 shipped the design gallery inside the app, behind a dev-build flag (Help → Design Gallery). The owner's decisions:

- **Not in the app at all.** It is our internal tool. No window, no menu item, no build flag in the shipped app (2026-10-19, after #419).
- **A live window, as close to reality as possible** (asks #425/#426, then the owner's follow-up). Static renders and an HTML page were considered and set aside. The gallery must run the real SwiftUI components, so hover, press, focus and window resizing behave exactly as in the app.
- **Organised by a taxonomy.** A sidebar tree of categories, not one long scroll.

## 2. Shape

### 2.1 Packages and targets (`WatchtowerDesktop/Package.swift`)

- **`DesignKit`**, a new library target at `Sources/DesignKit/`. The kit's 18 files move there unchanged in behaviour (`git mv` from `Sources/Views/DesignSystem/`): tokens, Tone, Surface, the panel and popover surfaces, every component, and `PanelResizeHandle`.
  - The kit already imports only SwiftUI and AppKit, so it moves without new dependencies.
  - Its API becomes `public`.
  - The app target depends on it, and one file re-exports it (`@_exported import DesignKit`), so no app file needs a new import.
- **`DesignGallery`**, a new executable target at `Sources/DesignGallery/`. It depends on `DesignKit` and `DesignKitCatalog` only, never on the app or `WatchtowerCore`.
  - It runs with `make design-gallery`, which wraps `swift run DesignGallery`.
  - `build-app.sh` runs the full `swift build`, which also builds the gallery, but copies into the `.app` only the app's executable and the resource bundles. A check in the build script fails the build if anything of the gallery reaches the bundle: the app target depending on the catalog, a `DesignGallery*` file or `*DesignKitCatalog*` resource bundle, or a gallery symbol in the app's binary (matched against the gallery's own binary as a positive control).
- **Removed from the app:** `DesignGalleryScene.swift`, the Help → Design Gallery item, `DevBuild.swift` with its tests, and the `WTDevBuild` stamp in `build-app.sh`.

### 2.2 The window

The window is a `NavigationSplitView`: the taxonomy in the sidebar, one page per leaf.

Every page has a toolbar:

- **Appearance:** System, Light or Dark (applied to the whole gallery window, so AppKit's dynamic colours follow it too).
- **Control size:** mini, small, regular or large.
- **Surface:** the page sits on the detail backdrop, the window panel or a popover-like material.
- **Disabled:** forces `.disabled(true)` on the samples.

Hover, press, focus and selection are live: use the mouse and keyboard. Each sample also shows its one-line usage, for example `.buttonStyle(.kitSecondary)`, selectable to copy.

### 2.3 Taxonomy

```
Foundations
  Colour & surfaces   — Surface, Fill, Tone (status, priority)
  Spacing             — Spacing scale, live bars
  Radius              — Radius roles
  Strokes             — hairline, selection
  Typography          — the text roles of the guide (section header, meta, badge, numbers)
  Icons               — IconSize
  Motion & shadow     — Motion (play buttons), FloatingShadow
Components
  Actions             — kitPrimary, kitSecondary, kitQuiet, kitDestructive, kitIcon, FloatingButtonLabel
  Selection           — SegmentedToggleStyle, KitSegmentedPicker, switch in a SettingRow
  Inputs              — .textFieldStyle(.kit) (plain, focused, on a popover)
  Display             — Chip, CountBadge, OutlineTag, MenuLabel, SectionHeader
  Containers          — .card(selected:fill:), .kitRow(isSelected:)
Patterns
  Settings            — SettingsSection + SettingRow, a realistic block
  Panels              — PanelSplit with a resizable side panel, panelSurface + panelTab list
  Popover             — popoverSurface with a field and a primary action
```

A sidebar search filters the leaves by name. The taxonomy lives in one place, an enum, so a new component adds itself to exactly one entry.

### 2.4 Shots and the guide

- The pages live in a third target, **`DesignKitCatalog`** (library, `Sources/DesignKitCatalog/`, depends on `DesignKit` only). The executable `DesignGallery` is a thin `@main` over it, and the test target imports it for shots. The app never links it, so the shipped binary carries no gallery code at all (decision 1).
- `DesignShotCatalog` renders one shot per taxonomy page, so the guide's images come from the same pages that the window shows.
- The guide, the `add-desktop-feature` skill, `CLAUDE.md`, and the earlier spec's §4.4 say: `make design-gallery` to look, `make desktop-shots` for PNGs.

### 2.5 Lint and checks

- The `kit_*` rules' exclusion moves from `Sources/Views/DesignSystem/` to `Sources/DesignKit/`. `Sources/DesignGallery/` is excluded too.
- The kit-lint guard keeps scanning the app's `Sources/Views` and `Sources/App`.
- Rendered shots of the reference screens stay byte-identical. The move changes no values.

## 3. Non-goals

- New components, or restyling anything. This is a move plus a viewer.
- Sharing the kit with the phone app.

## 4. Left to the builder

- File split inside `DesignKitCatalog`, the sample texts (`acme`, `example.com` only), the toolbar's exact controls.
- How `public` is introduced (only what the app and the catalog use).
