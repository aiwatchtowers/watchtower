---
name: add-desktop-feature
description: Use when adding a feature, tab, or screen to the Watchtower macOS SwiftUI app (WatchtowerDesktop/) — the Models→Queries→ViewModel→View (GRDB + MVVM) stack, a sidebar tab/badge, or a view that reads the shared SQLite DB or calls the CLI.
---

# Add a Desktop Feature (Watchtower SwiftUI)

The app is MVVM over GRDB: **Model → Queries → ViewModel → View**, reading the same SQLite DB as the Go CLI (`DatabasePool`, WAL). Copy the newest example end-to-end: **CatchUp** (`Sources/.../CatchUp*`).

## Steps

1. **Model** — `Sources/Models/<Feature>Models.swift`. `struct` conforming to `FetchableRecord, Identifiable` with an explicit `init(row: Row)` (handle defaults/optionals) and computed state predicates (`isPending`, `isOverdue`…). Decode JSON columns with a fallback (`?? []`).

2. **Queries** — `Sources/Database/Queries/<Feature>Queries.swift`. An `enum` of `static` methods grouped Fetch / Counts / Updates / Observation. Reads via typed `fetchOne`/`fetchAll`; writes via `db.execute(...)` always setting `updated_at = strftime('%Y-%m-%dT%H:%M:%SZ','now')`. Expose a `ValueObservation.tracking { ... }` for live data.

3. **ViewModel** — `Sources/ViewModels/<Feature>ViewModel.swift`. `@MainActor @Observable final class`, inject `DatabasePool`. `startObserving()` streams `observation.values(in: dbPool)` in a stored `Task`; writes via `await dbPool.write { db in ... }`. Plain `var` properties (no `@Published`).

4. **View(s)** — `Sources/Views/<Feature>/<Feature>View.swift` (+ optional `…Row`, `…DetailView`). `@Bindable var vm`, `.onAppear { vm.startObserving() }`, `navigationTitle` on the content (not inside a `@ViewBuilder` branch). Master-detail → `HSplitView`.

5. **Navigation wiring** (4 spots):
   - `Sources/App/SidebarDestination.swift` — add the `case`, its `title`, `icon` (SF Symbol), and include it in `mainItems`.
   - `Sources/App/Navigation.swift` — add the `case` to the `detailView` switch, instantiating the View with the VM from `AppState`.
   - `Sources/App/AppState.swift` — add a `private(set) var <feature>ViewModel` and init it in `initialize()` after the DB is ready.
   - (Optional badge) `Sources/ViewModels/SidebarCountsViewModel.swift` — add a count + fetch; render it in `Sources/Views/Sidebar/SidebarView.swift` `badgeCount(for:)` (hide when 0).

6. **Tests** — `Tests/<Feature>Tests.swift`, using `TestDatabase.createDatabaseManager()` (file-based pool, not `:memory:`); insert fixtures, `@MainActor` when driving a VM, `TestDatabase.cleanup(path:)` in teardown.

7. **Verify:** `cd WatchtowerDesktop && swift build && swift test`, plus `make lint-swift`.

## Gotchas

- **Cross-process writes don't trigger `ValueObservation`.** The Go daemon writes from a *separate process*; GRDB's update hook won't fire. Data the daemon produces needs a periodic poll or refresh-on-`onAppear` (see `InboxViewModel`).
- **Thread discipline.** VM is `@MainActor`; reads/writes run off-main inside `dbPool.read/write`. Never touch UI inside the observation loop without hopping to the main actor.
- **CLI subprocess pipes deadlock** if you read stdout then stderr sequentially — drain both concurrently (see `CatchUpViewModel` CLI helper).
- **AppState init order:** sidebar counts must load before the splash hides; init feature VMs after the DB/onboarding check.
- **Schema sync:** if the feature needs a new table/column, that's a Go-side migration first ([[add-migration]]); the Swift side only reads the result.
- **Don't weaken guard tests** under `docs/inventory/` coverage — stop and ask the owner.

## Reference files (CatchUp = cleanest template)
`Sources/Models/CatchUpModels.swift` · `Sources/Database/Queries/CatchUpQueries.swift` · `Sources/ViewModels/CatchUpViewModel.swift` · `Sources/Views/CatchUp/CatchUpView.swift` · nav: `SidebarDestination.swift`, `Navigation.swift`, `AppState.swift` · badge: `SidebarCountsViewModel.swift`, `SidebarView.swift` · tests: `Tests/CatchUpQueriesTests.swift`

When done, run `local-review` before opening a PR.
