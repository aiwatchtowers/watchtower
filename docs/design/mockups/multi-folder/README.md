# Multi-folder workbench — mockups

DesignShotCatalog shots for the multi-folder workbench spec
(`docs/superpowers/specs/2026-11-18-multi-folder-workbench-design.md`, board #2003), light and dark,
on `acme` sample data. They are static mocks built in the test target
(`WatchtowerDesktop/Tests/DesignShots/MultiFolderShotFixtures.swift`) from the design kit and plain
SwiftUI — not the feature. `brainstorm-v3.html` is the approved brainstorm (ask #1541) they follow.

Render them again with
`cd WatchtowerDesktop && DESKTOP_SHOTS_DIR=<dir> swift test --filter DesignShotsTests/testMultiFolderShotsRender`
(or every shot with `make desktop-shots DESKTOP_SHOTS=<dir>`).

Each shot `workbench-multifolder-<name>` is saved here as `<name>-light.png` and `<name>-dark.png`.

| Shot | What it shows | Spec |
|---|---|---|
| `panel-nested` | Sessions panel: a parent (`Working · 2 sub-sessions`) with two nested sub-sessions in hub and site, folder labels on every row, FILES with three roots (app expanded with its branch, hub, site) and the Put on the Bench… icon in the FILES header | §6.2, §6.5 |
| `panel-single` | One-folder bench: today's rows (no folder labels), the tree without a root row, and the quiet hint `Task touches another repo? Put on the Bench…` | §2 G1, §6.2 |
| `files-root-errors` | FILES root states: `Folder not found` with `~/code/hub was moved or deleted.` + `Locate…` · `Remove`, `Git unavailable`, `Not a repository` (no branch) | §6.2 |
| `switcher` | Workbench switcher popover: Put on the Bench… (`Add a folder to “acme”`) under Open Folder… | §6.1 |
| `new-session-menu` | New Session (+) menu with `in <folder>` submenus (the `in hub` one open) and the placement submenus | §6.4 |
| `suggest-card` | Waiting for you card `Put billing on the bench?` with Put on Bench / Not Now, and the quiet Never for This Folder on its own line (the panel is 220 pt wide by default) | §6.7 |
| `suggest-card-busy` | The same card while the add runs: `Putting on the bench…` | §6.7 |
| `suggest-card-error` | The add failed: `Couldn’t put billing on the bench: the folder was moved or deleted.` and `OK` | §6.7 |
| `suggest-card-merge` | The card when the folder is on another bench: `Put billing on the bench?` / `billing is on the “tools” bench` with Merge Benches… / Not Now | §6.7, §6.13 |
| `remove-confirm` | `Remove hub from the bench?` confirmation | §6.3 |
| `remove-refused-sessions` | Refusal: `2 sessions are running in hub. Finish them first.` | §6.3 |
| `remove-refused-last` | Refusal: `A workbench needs at least one folder.` | §6.3 |
| `merge-confirm` | `Merge “tools” into “acme”?` confirmation: board (12 targets), asks and sessions move, `Folders that move: billing.`, Cancel / Merge | §6.13 |
| `merge-refused` | Refusal: `Can’t merge “tools” yet` / `2 sessions are running in tools. Finish them first.` | §6.13 |
| `feed-parent` | Parent's Workchat feed: sub-session started, message to, message from, sub-session finished, and a waiting message with `Open` | §6.6 |
| `strip-child` | A sub-session's strip: `📁 hub › ⑂ export-api › ⎇ wt/export-api` ending with `↖ from “Export reports to PDF”` | §6.5 |
| `board-card-folder` | Board cards with a folder chip before the branch, and a target whose folder left the bench (`folder removed`) | §6.10, §8 PROJ-07 |
