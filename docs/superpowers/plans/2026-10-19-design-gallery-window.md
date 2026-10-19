# Design Gallery Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the design kit into its own `DesignKit` library, take the gallery out of the app entirely, and ship it as a separate live window (`make design-gallery`) organised by a taxonomy.

**Architecture:** The package gains three new targets:
- `DesignKit`, a library holding the kit, moved verbatim and made `public`.
- `DesignKitCatalog`, a library holding the gallery pages and the taxonomy.
- `DesignGallery`, a thin `@main` executable.

The app links only `DesignKit` and re-exports it, so no app file needs a new import. The tests import the catalog for shots.

**Tech Stack:** SwiftPM (`WatchtowerDesktop/Package.swift`), SwiftUI/AppKit, XCTest + ViewInspector, SwiftLint custom rules, Make.

**Spec:** `docs/superpowers/specs/2026-10-19-design-gallery-window-design.md` (approved, ask #427). It amends §4.4 of `docs/superpowers/specs/2026-10-19-desktop-style-guide-design.md`.

## Global Constraints

- **Nothing of the gallery in the app.** No window, menu item, `DevBuild` or `WTDevBuild`. The app target never depends on `DesignKitCatalog` or `DesignGallery`.
- **The kit moves with zero behaviour or pixel change.**
  - Use `git mv`.
  - Make API `public` only where the app or the catalog uses it.
  - The reference shots `workbench-header`, `workbench-board-cards`, `workbench-panel-parts`, `sessions-panel` and `buttons` must stay byte-identical to a render taken on `origin/main` before Task 1.
- **Dependencies.**
  - `DesignKit` depends on SwiftUI and AppKit only.
  - `DesignKitCatalog` depends on `DesignKit` only.
  - `DesignGallery` depends on both of those only.
  - `WatchtowerCore` stays SwiftUI-free.
- **Sample data** uses `acme` / `example.com` only.
- **Per-task checks:** `make test-swift FILTER=…` and `make lint-swift`. The full gate runs once, before the PR.

## Review Focus

1. **The app still compiles everywhere** a kit type is used. Expected behaviour: `@_exported import DesignKit` makes every kit name visible, and no file needs its own import.
2. **Release bundle.** `build-app.sh` must never copy a `DesignGallery` binary into the `.app`. Expected behaviour: a guard fails the build if one appears.
3. **Lint scoping after the move.** The `kit_*` rules exclude `Sources/DesignKit/`, `Sources/DesignKitCatalog/` and `Sources/DesignGallery/`. The kit-lint guard and the baseline still cover `Sources/Views` and `Sources/App`. Expected behaviour: the baseline does not change.
4. **Dark and light per page.** Expected behaviour: the toolbar's appearance switch re-renders every sample, including the AppKit-backed `NSColor.detailBackground`.
5. **Hover and focus are live.** Expected behaviour: the window is a normal key window, so hovering, pressing and focusing a sample behaves as in the app.

---

### Task 1: Extract `DesignKit`, take the gallery out of the app

**Depends on:** none

**Files:**
- `WatchtowerDesktop/Package.swift`:
  - add `.target(name: "DesignKit", path: "Sources/DesignKit")`;
  - add `.target(name: "DesignKitCatalog", dependencies: ["DesignKit"], path: "Sources/DesignKitCatalog")`;
  - add `"DesignKit"` to the app's and the test target's dependencies;
  - add `"DesignKitCatalog"` to the test target only.
- Move with `git mv`: every file in `Sources/Views/DesignSystem/` → `Sources/DesignKit/`, except the gallery files. `DesignSystemGallery.swift` and `DesignSystemGallery+NewComponents.swift` → `Sources/DesignKitCatalog/`.
- Delete: `Sources/Views/DesignSystem/DesignGalleryScene.swift`, `Sources/App/DevBuild.swift`, `Tests/DevBuildTests.swift`, the Help → Design Gallery item (`WorkbenchCommands.swift`), the scene registration (`WatchtowerApp.swift`), and the `WTDevBuild` stamp in `scripts/build-app.sh`.
- Create: `Sources/App/DesignKitExport.swift`, containing one line, `@_exported import DesignKit`, with a one-line comment.
- `scripts/build-app.sh`: after the bundle is assembled, fail if `find "$APP_BUNDLE" -name 'DesignGallery*'` finds anything.
- `WatchtowerDesktop/.swiftlint.yml`: the `kit_*` `excluded` patterns change from `Sources/Views/DesignSystem/` to `Sources/(DesignKit|DesignKitCatalog|DesignGallery)/`.
- Tests that `@testable import WatchtowerDesktop` and use kit internals: add `@testable import DesignKit` (and `DesignKitCatalog` for the gallery tests) where the compiler asks.

**Interfaces:**
- Produces:
  - `DesignKit`'s public API: every token enum, `Tone`, `Surface`, `NSColor.detailBackground`, the button styles and their static accessors (`.kitPrimary` and the rest), `SegmentedToggleStyle`, `KitSegmentedPicker`, `Chip`, `CountBadge`, `OutlineTag`, `MenuLabel`, `SectionHeader`, `View.card(selected:fill:)`, `FloatingButtonLabel`, `.textFieldStyle(.kit)`, `SettingsSection`, `SettingRow`, `View.kitRow(isSelected:)`, `PanelSplit`, `PanelSplitWidth`, `PanelResizeHandle`, the panel and popover surface modifiers, `PanelTab`, `segmentCapsule()`, `KitButtonMetrics`, and `onPopoverSurface`.
  - `DesignKitCatalog` holds the existing `DesignSystemGallery` and `DesignSystemGalleryContent`, unchanged in this task.

- [ ] **Step 1:** On a clean `origin/main`, before any change, render `make desktop-shots DESKTOP_SHOTS=build/shots-pre-extract`.
- [ ] **Step 2:** Make the moves, the target edits and the `public` changes. Build with `make test-swift FILTER='DesignTokensTests|DesignKitComponentsTests|DesignKitNewComponentsTests|DesignSystemGalleryTests|DesignShotsTests|KitDestructiveButtonStyleTests|PopoverSurfaceTests|WorkbenchBoard|WorkbenchHeader'`. Expected: PASS.
- [ ] **Step 3:** Run `make desktop-shots DESKTOP_SHOTS=build/shots-post-extract`. Run `cmp` on the five reference shots, light and dark, against Step 1. Expected: identical.
- [ ] **Step 4:** Run `make lint-swift`. Expected: exit 0, with the baseline untouched (`git diff --quiet WatchtowerDesktop/.swiftlint-baseline.json`). Run `grep -rn "DevBuild\|WTDevBuild\|Design Gallery\|design-gallery" WatchtowerDesktop/Sources scripts/build-app.sh`. Expected: no hits in the app.
- [ ] **Step 5:** Commit `refactor(desktop): DesignKit library; the gallery leaves the app (#760)`.

### Task 2: The live gallery window with a taxonomy

**Depends on:** Task 1

**Files:**
- Create in `Sources/DesignKitCatalog/`:
  - `Taxonomy.swift`, holding `public enum CatalogSection` and `public enum CatalogPage` with the tree from spec §2.3;
  - `CatalogPages/…`, one view per page;
  - `GalleryWindow.swift`, holding `public struct GalleryRootView`;
  - `PageChrome.swift`, holding the toolbar and the usage line.
  
  Fold the existing `DesignSystemGallery` content into the pages and delete the old long-scroll views.
- Create: `Sources/DesignGallery/main.swift`, or an `App`-conforming `@main` with one `WindowGroup { GalleryRootView() }`, and default window size 1100×760.
- `Package.swift`: `.executableTarget(name: "DesignGallery", dependencies: ["DesignKit", "DesignKitCatalog"], path: "Sources/DesignGallery")`.
- `Makefile`: `design-gallery` runs `cd WatchtowerDesktop && swift run DesignGallery`. Add it to `.PHONY`.
- Test: `Tests/DesignGalleryCatalogTests.swift`.

**Interfaces:**
- Produces:
  - `public enum CatalogSection: CaseIterable { case foundations, components, patterns }`
  - `public enum CatalogPage: String, CaseIterable, Identifiable`, with these cases:
    - `colours`, `spacing`, `radius`, `strokes`, `typography`, `icons`, `motion` (Foundations)
    - `actions`, `selection`, `inputs`, `display`, `containers` (Components)
    - `settings`, `panels`, `popover` (Patterns)
  - Each `CatalogPage` has `section`, `title` and `@MainActor @ViewBuilder func content() -> some View`.
  - `public struct GalleryRootView: View`, a `NavigationSplitView` with:
    - the sidebar grouped by `CatalogSection`, with `.searchable` filtering by title;
    - a toolbar with Appearance (System/Light/Dark → `.preferredColorScheme`), Control size (`.controlSize`), Surface (detail/window/popover background) and Disabled (`.disabled`).
  - `struct UsageLine(_ code: String)`: monospaced, selectable text under each sample.

- [ ] **Step 1:** Write the failing tests:
  - `testEveryPageBelongsToItsSection`: the section → pages mapping equals spec §2.3.
  - `testSearchFiltersPagesByTitle`: a static `CatalogPage.filtered(by:)` returns `[.spacing]` for "spa".
  - `testEveryKitComponentAppearsOnAPage`: a static list `CatalogPage.componentsShown` covers every public kit component name. Keep a hand-written list in the test and compare.
- [ ] **Step 2:** Run `make test-swift FILTER=DesignGalleryCatalogTests`. Expected: FAIL.
- [ ] **Step 3:** Implement. Pages show every variant and state that can be shown statically (on/off, selected, disabled, focused where the field can be focused by a button on the page). Hover and press are left to the mouse.
- [ ] **Step 4:** Run the same filter. Expected: PASS. Run `cd WatchtowerDesktop && swift build --product DesignGallery`. Expected: success. Launch it once with `swift run DesignGallery &`, take a screenshot of the window with `screencapture -l$(…)`, or use `make desktop-shots` via Task 3, then quit it and confirm it does not linger (`pgrep DesignGallery` is empty).
- [ ] **Step 5:** Run `make lint-swift`, then commit `feat(desktop): live design gallery with a taxonomy (#760)`.

### Task 3: Shots per page and docs

**Depends on:** Task 2 for the shots. The docs part may start in parallel after Task 1.

**Files:**
- `Tests/DesignShots/DesignShotCatalog.swift`: replace the old `gallery` shot with one shot per `CatalogPage`, named `catalog-<rawValue>`. Each page is rendered with its toolbar defaults, at fitting height and 900 px width.
- `docs/design/shots/`: delete `gallery.png`, `kit-new-components.png` and `buttons.png`, the component-level shots that the catalog pages replace. Add the light `catalog-*.png`. Keep the reference-screen shots.
- `docs/design/desktop-style-guide.md`:
  - the gallery is `make design-gallery`, a separate window, never in the app;
  - images come from `catalog-*`;
  - remove the "Before a release" Design Gallery line.
- `.claude/skills/add-desktop-feature/SKILL.md`: the step that mentions the gallery now points to `make design-gallery`, and a new kit component adds itself to a `CatalogPage`.
- `CLAUDE.md`: the design-kit line names `Sources/DesignKit/`, `make design-gallery` and `make desktop-shots`.
- `docs/superpowers/specs/2026-10-19-desktop-style-guide-design.md` §4.4: add one line, "Superseded by docs/superpowers/specs/2026-10-19-design-gallery-window-design.md".

- [ ] **Step 1:** Edit the docs. A parallel lane may do this.
- [ ] **Step 2:** Run `make desktop-shots DESKTOP_SHOTS=build/shots-final`. Look at three `catalog-*` light and dark PNGs with Read. Copy the light ones into `docs/design/shots/` and keep the total under about 2 MB.
- [ ] **Step 3:** Run `make test-swift FILTER='DesignShotsTests|DesignGalleryCatalogTests'` and `make lint-swift`, then commit `docs: catalog shots and gallery docs (#760)`.

## Controller gate

Run the full `make test-swift`, `make lint-all`, `make desktop-shots` and `swift build --product DesignGallery`. Then do the final whole-branch review, open the PR and merge it once CI is green (ask #69).
