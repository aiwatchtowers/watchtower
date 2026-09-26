# Client-side (Swift) bugs — audit 2026-07-05

The audit covers the client code of the macOS app `WatchtowerDesktop/` (SwiftUI + GRDB): ViewModels, Queries, Services, and utilities. Method: multi-agent defect search (finders `swift-data`, `swift-vm`, `swift-svc`) followed by independent adversarial verification of each finding against the real DB schema, the Go source code, and Swift Concurrency semantics; refuted findings were removed. Below are 23 confirmed defects: 5 High, 9 Medium, 9 Low.

## High

### The Channels screen is completely broken: `fetchValueSignals` references the removed `tasks` table

- **Where:** `WatchtowerDesktop/Sources/Database/Queries/ChannelStatsQueries.swift:190`
- **Verification status:** ✅ confirmed

The DB table was renamed `tasks` → `targets` (in `schema.sql` and the migrations, only `targets` is created; in the live DB there is no `tasks` table or view). `fetchValueSignals` references `FROM tasks t` both in the main SQL (lines 190, 199) and in the fallback SQL for the case where `digest_topics` is absent (lines 237, 246), so every call throws `no such table: tasks`. `ChannelStatsViewModel.load()` (lines 61–77) calls `fetchAll` and `fetchValueSignals` inside a single `do/catch`, so the exception zeroes out the whole result: `stats=[]`, `recommendations=[]`, and `errorMessage` gets set — every time the Channel Stats screen is opened it shows an error instead of data. The equivalent Go code `GetChannelValueSignals` in `channel_stats.go` already uses the correct `FROM targets t`, confirming that the Swift mirror is stale.

```sql
task_via_digest AS (
    SELECT d.channel_id, COUNT(*) AS cnt
    FROM tasks t
    JOIN digests d ON t.source_type = 'digest' ...
)
```

- **Recommendation:** Replace `FROM tasks t` with `FROM targets t` in all four places (lines 190, 199, 237, 246) and cross-check the column names against the current `targets` schema. It would be sensible to add a guard test that checks table names in Swift queries against the schema, so future renames get caught in CI.

### Marking Day Plan task items "done/pending" always fails: the cascade writes to the removed `tasks` table

- **Where:** `WatchtowerDesktop/Sources/Database/Queries/DayPlanQueries.swift:182`
- **Verification status:** ✅ confirmed

`cascadeTaskStatus` executes `UPDATE tasks SET status = ...`, but the table is now `targets`. `DayPlanViewModel.markDone/markPending` pass `cascadeToTask: item.sourceType == .task`, so for every item with a task source (the most common kind — 303 out of 718 rows in the live DB) the statement throws `no such table: tasks` inside `dbPool.write`, rolling back the item's own status update as well. Result: the Done checkbox on task-sourced day plan items does nothing except set `generationError`.

```swift
try db.execute(sql: """
    UPDATE tasks
    SET status = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
    WHERE id = ?
    """, arguments: [taskStatus, taskId])
```

- **Recommendation:** Replace `UPDATE tasks` with `UPDATE targets` (compare with the correct `TargetQueries`, which already writes to `targets`). Check the rest of the cascade queries in the file for the same stale identifier.

### The "Wipe LLM data" feature is completely non-functional: `DELETE FROM tasks` rolls back the entire transaction

- **Where:** `WatchtowerDesktop/Sources/Database/DatabaseManager.swift:116`
- **Verification status:** ✅ confirmed

`wipeLLMData` runs all `DELETE`s in a single `dbPool.write` transaction and includes `DELETE FROM tasks`. Since the table no longer exists, the statement throws, and GRDB rolls back all the preceding deletes (`digests`, `tracks`, `briefings`, `inbox_items`, …). `AppState.resetLLMData()` (`try db.wipeLLMData()`) then rethrows the error — the user's "Reset AI data" action stops the daemons, deletes nothing, and finishes with an error. Worse, `resetLLMData` stops the daemon/pipelines before the throw and never reaches the restart step, leaving the daemon stopped. `tasks` is the only nonexistent table among the 17 in `wipeLLMData`.

```swift
// Tasks & Inbox
try db.execute(sql: "DELETE FROM tasks")
try db.execute(sql: "DELETE FROM inbox_items")
```

- **Recommendation:** Replace `DELETE FROM tasks` with `DELETE FROM targets`. Additionally, wrap the daemon restart in `defer`/`do-catch` so that a failure in any `DELETE` doesn't leave the daemon stopped forever.

### `ConfigService.save()` writes a stale YAML snapshot, wiping out config written by CLI logins (the Jira section gets erased)

- **Where:** `WatchtowerDesktop/Sources/Services/ConfigService.swift:122`
- **Verification status:** ✅ confirmed

`save()` serializes `rawYAML`, which is only refreshed via `reload()` (on init or via the Reload button). The Go CLI also writes `config.yaml`: `watchtower jira login` saves `jira.cloud_id/site_url/user_display_name/enabled` via `writeConfigAtomic` (`cmd/jira.go:296-305`), and `auth` rewrites the Slack token. In the same Settings panel (`GeneralSettings` holds a single `@State private var config = ConfigService()`, and `jiraAuth.connect()` runs `jira login`) the user can: open Settings → Connect Jira (the CLI writes `jira.*` into `config.yaml`) → change any setting → click Save. `save()` serializes the pre-login `rawYAML`, deleting the entire `jira` section, after which `jira boards`/`jira sync` can't find `cloud_id` and the integration silently breaks. The Slack-reconnect path calls `config.reload()` afterward (`SettingsView.swift:732`), but the Jira and Google paths do not, and `save()` itself never re-reads or merges the on-disk file before writing.

```swift
func save() throws {
    var yaml = rawYAML
    ...
    try output.write(toFile: configPath, atomically: true, encoding: .utf8)
    ...
    rawYAML = yaml
}
```

- **Recommendation:** In `save()`, re-read `config.yaml` from disk immediately before serializing (or merge only the changed keys instead of overwriting the whole snapshot), so that writes from CLI logins aren't lost. At minimum, call `reload()` after every `connect()` (Jira, Google, Slack), not just for Slack.

### `BackgroundTaskManager`: a digests pipeline failure leaves tracks/people stuck in "Waiting…" forever and blocks daemon startup for the whole session

- **Where:** `WatchtowerDesktop/Sources/Services/BackgroundTaskManager.swift:207`
- **Verification status:** ✅ confirmed

In `startPipelines()`, if the digests pipeline exits with a nonzero code (common during onboarding: the `claude` CLI isn't logged in, an AI error), the orchestrating `Task` returns early at `guard tasks[.digests]?.status == .done else { return }`. Consequences: (1) tracks and people remain `.pending` forever — the sidebar shows "Waiting…" with no Retry button (`SidebarProgressView.swift:87` renders pending with no action); (2) `pipelineTask` is never reset to `nil` (that only happens at the end of the success path, line 227), so `guard pipelineTask == nil` at line 189 blocks any future call to `startPipelines()` for the rest of the session; (3) even if the user clicks Retry on digests and it succeeds, `retry()` only starts the daemon `if allFinished` — which is false while tracks/people are `.pending` — so phase 2 never runs and `sync --daemon --detach` never starts, meaning there is no background sync at all; (4) `pipelinesCompletedKey` is never set, so the entire (expensive) pipeline set reruns from scratch on the next launch. The only recovery is restarting the app, which isn't obvious to the user.

```swift
await runTask(.digests)
guard !Task.isCancelled else { return }
// Only proceed if digests succeeded.
guard tasks[.digests]?.status == .done else { return }
```

- **Recommendation:** On a digests failure, still reset `pipelineTask = nil` (via `defer`) and move dependent pipelines into a state with a Retry button instead of leaving them `.pending`. Decouple the daemon-start logic from `allFinished` — start the background sync regardless of the outcome of optional pipelines, so that an onboarding AI failure doesn't cost the app its core function.

## Medium

### Average Jira cycle time is always 0: `julianday()` can't parse Jira timestamps in `+HHMM` format

- **Where:** `WatchtowerDesktop/Sources/Database/Queries/JiraQueries.swift:472`
- **Verification status:** ✅ confirmed

The Go sync stores `jira_issues.created_at/resolved_at` verbatim from the Jira API (`CreatedAt: f.Created` in `internal/jira/sync.go:535`), i.e. `'2025-10-14T09:11:12.903+0100'`. SQLite's date functions accept `+01:00` or `Z`, but NOT `+0100`, so `julianday()` returns NULL for every real row. `AVG(julianday(resolved_at) - julianday(created_at))` in `fetchDeliveryStats` is always NULL → 0.0, and `avg_cycle_time_days` in `fetchTeamWorkload` (line 587) = 0 for every assignee. `PersonDetailView` and the Workload screen constantly show a cycle time of 0 days. The same bug exists in Go too (`jira_dashboards.go`).

```sql
SELECT AVG(julianday(resolved_at) - julianday(created_at)) ...
-- julianday('2025-10-14T09:11:12.903+0100') -> NULL
```

- **Recommendation:** Normalize timestamps into a format SQLite understands. Best fix: correct it at the source (have the Go sync normalize `+0100` → `+01:00` when writing to the DB); otherwise normalize on the Swift side within the query (inserting a colon into the offset via `substr`) before `julianday()`. Fix symmetrically in Go and Swift.

### The Stop button saves the assistant's message twice: `cancelStream()` and the stream task's epilogue both insert the partial response

- **Where:** `WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift:199`
- **Verification status:** ✅ confirmed

The user sends a message, the text starts streaming, then they press Stop (or switch providers / attach a different conversation / delete the chat mid-stream — all of these call `cancelStream`). `cancelStream()` saves the partial assistant text via `persistMessage` (line 256). The still-running `streamTask` then exits the `for-await` and unconditionally runs the epilogue (lines 198–204), which sits OUTSIDE the `do/catch` and does not check `Task.isCancelled` — it fires on both cancellation paths (the iterator either returned `nil` or threw) — and saves the same accumulated `fullText` a second time via `persistResponseStatic`. Result: two identical assistant rows in `chat_messages`. `ChatMessageQueries.insert` is a bare INSERT with no dedup/unique constraint, and `startMessageObservation` reloads the duplicate into the UI permanently. The same pattern appears in `sendWelcomeMessage` (lines 592–597).

```swift
// cancelStream():
if !partialText.isEmpty, let convID = conversationID {
    persistMessage(conversationID: convID, role: "assistant", text: partialText)
}
// streamTask epilogue (after catch), always runs:
if !fullText.isEmpty, let convID = capturedConvID {
    Self.persistResponseStatic(dbManager: capturedDBManager, conversationID: convID, text: fullText)
}
```

- **Recommendation:** In the epilogue, only save the response if `cancelStream` hasn't already done so — for example, check `Task.isCancelled` before `persistResponseStatic`, or introduce an "already saved" flag. Apply the same fix to `sendWelcomeMessage`.

### `TargetChatViewModel` parses action proposals from a cancelled/truncated stream (`streamFailed` is never set on cancellation) and saves the partial response twice

- **Where:** `WatchtowerDesktop/Sources/ViewModels/TargetChatViewModel.swift:253`
- **Verification status:** ✅ confirmed

The code's own comment states: "On a failed/cancelled stream, do NOT parse actions out of partial, possibly-truncated output". But `streamFailed` is only set inside `catch` (line 245). When the user presses Stop (`cancelStream → streamTask?.cancel()`), the `AsyncThrowingStream` finishes iteration by returning `nil` from `next()` — it does not throw — so the `for-await` exits normally, `streamFailed` stays `false`, and `executeStream` reaches `TargetActionParser.parse(fullText)` on truncated output (line 259). A truncated ` ```watchtower-action ` block can surface as a half-formed action card that the user might approve, or produce spurious `⚠️ Invalid action proposal` system messages, which get saved. In addition, `cancelStream` (lines 378–384) saves the partial assistant text, and the epilogue saves `displayText` again (lines 277–279) — duplicate rows in the target conversation.

```swift
} catch {
    streamFailed = true
    ...
}
// On a failed/cancelled stream, do NOT parse actions out of partial output ...
if streamFailed { finishStream(); return }
let parsed = TargetActionParser.parse(fullText)  // reached on cancellation
```

- **Recommendation:** Check `Task.isCancelled` (or set `streamFailed = true` on cancellation) before the guard at line 253, so action parsing doesn't run on truncated output. Also fix the double-save, as in `ChatViewModel`.

### Jira board sync failures are completely silent: exit code 0 on error, and neither the error JSON nor the `error` property is ever shown

- **Where:** `WatchtowerDesktop/Sources/Services/JiraBoardSyncManager.swift:92`
- **Verification status:** ✅ confirmed

`runSyncProcess()` only determines failure from `proc.terminationStatus != 0`. But in `--progress-json` mode for a single board, Go emits `{"pipeline":"jira-sync","finished":true,"error":...}` and then `return nil` (`cmd/jira.go:712-716`), i.e. it exits with status 0 even on a sync failure. The Swift progress callback only does `self?.progress = json` and never inspects `json.error`; after the loop, `startSync()` sets `progress = nil`, and `error` stays `nil`. On top of that, the only consuming view (`JiraBoardsSettingsView.swift`) doesn't render `syncManager.error` at all. Result: when a board sync fails (expired Jira token, API error), the spinner simply disappears and the user gets no signal at all — the board looks synced but the data is missing/stale.

```swift
if proc.terminationStatus != 0 {
    ...
    return stderr.isEmpty ? "Sync failed" : String(stderr.prefix(200))
}
return nil
// Go cmd/jira.go:713: json.Marshal(jiraSyncProgressJSON{... Error: err.Error()}); return nil  // exit 0
```

- **Recommendation:** In the progress callback, check `json.error` and set `self.error`, and have `JiraBoardsSettingsView` render `syncManager.error`. Alternatively, change the Go side so single-board mode returns a nonzero exit code on failure.

### Detecting "stuck" issues in the Blocker Map never returns any rows (empty source column + a format `julianday` can't parse)

- **Where:** `WatchtowerDesktop/Sources/Database/Queries/JiraQueries.swift:692`
- **Verification status:** ✅ confirmed

`fetchStaleIssues` filters on `status_category_changed_at != '' AND julianday('now') - julianday(status_category_changed_at) > ?`. The Go sync hard-codes this column to `''` for every issue (`internal/jira/sync.go:503`: `statusCatChanged := ""` with the comment "Jira API doesn't expose this directly"; in the live DB 0 out of 1165 issues have it non-empty), so the first condition excludes everything; and even if the column were populated in native Jira `+HHMM` format, `julianday()` would still return NULL. `BlockerMapViewModel` (line 78) therefore always renders an empty "stale issues" section — the feature is silently dead (the blocked issues section, by contrast, works fine).

```sql
WHERE status_category = 'in_progress'
  AND status_category_changed_at != ''
  AND julianday('now') - julianday(status_category_changed_at) > ?
-- SELECT COUNT(*), SUM(status_category_changed_at != '') FROM jira_issues -> 1165|0
```

- **Recommendation:** Fix it at the source — populate `status_category_changed_at` from the Jira changelog (or another available field) in the Go sync, and normalize the timestamp for `julianday`. Until the source is populated, it would be worth at least removing/flagging the non-functional section in the UI, so it doesn't create the false impression that "there are no stuck issues."

### `generateBriefing` calls `waitUntilExit` before draining the stderr pipe — deadlock and permanently stuck `isGenerating` if the CLI writes >64KB to stderr

- **Where:** `WatchtowerDesktop/Sources/ViewModels/BriefingViewModel.swift:131`
- **Verification status:** ✅ confirmed

The body of `Task.detached` runs `try process.run(); process.waitUntilExit()` and only afterward reads stderr to EOF (line 133). `watchtower briefing generate` runs the full briefing AI pipeline, and Go's logs go to stderr; if the child writes more than ~64KB (the pipe buffer size), it blocks in `write(2)`, never exits, and `waitUntilExit` hangs forever. The `MainActor.run` that resets `isGenerating` never executes, so the UI spinner gets stuck permanently (until restart), and the user can't start a new generation. `CatchUpViewModel.runCLIBlocking` in the very same codebase documents this exact hazard and drains both pipes concurrently before `waitUntilExit` — this call site missed that fix.

```swift
try process.run()
process.waitUntilExit()
let errData = stderr.fileHandleForReading.readDataToEndOfFile()  // read AFTER waitUntilExit
```

- **Recommendation:** Drain stderr (and stdout) on a separate task/thread BEFORE `waitUntilExit`, as already done in `CatchUpViewModel.runCLIBlocking`. Extract the logic into a shared helper to eliminate this duplicated anti-pattern.

### Systemic ValueObservation task leak: ViewModels recreated on every tab visit start observation tasks that are never cancelled

- **Where:** `WatchtowerDesktop/Sources/ViewModels/TracksViewModel.swift:76`
- **Verification status:** ✅ confirmed

`TracksViewModel`, `TargetsViewModel` (`startObserving`, line 39), `DigestViewModel` (line 77), `BriefingViewModel` (line 32), `PeopleViewModel` (line 32), `DashboardViewModel` (line 27), `BlockerMapViewModel` (line 57), and `TargetChatViewModel` (observationTask in init, line 102) offer no cancellation API and have no `deinit`; their views hold them in `@State` and recreate them on every tab visit. Every visit therefore leaks one perpetually-running ValueObservation `for-await` task (the sequence never terminates, and nobody cancels the task), which reruns its query on every commit to the observed table with `nil weak self`. `UserStatsViewModel/ChannelStatsViewModel/WorkloadViewModel/EpicProgressViewModel` do define `stopObserving()`, but it's only called by `ProjectMapView` and `ReleaseDashboardView` — the rest leak the same way. The project already knows the right pattern — `CustomTrackTimelineViewModel.stop()` documents "Call from the view's onDisappear … since a @MainActor deinit cannot touch the task".

```swift
observationTask = Task { [weak self] in
    let observation = ValueObservation.tracking { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks") ?? 0
    }
    ...
}  // TracksViewModel has no stop()/deinit
```

- **Recommendation:** Add a `stopObserving()` method to every tab-level VM that cancels `observationTask`, and call it from the corresponding view's `.onDisappear` (following the `CustomTrackTimelineViewModel.stop()` / `TrackDetailView` pattern). Longer term, extract the observation wrapper into a base class/helper with guaranteed cancellation.

### `ProcessCLIRunner` reads stdout to EOF before stderr and pins a cooperative-pool thread for the entire subprocess lifetime (deadlock if the child fills stderr)

- **Where:** `WatchtowerDesktop/Sources/Services/CLIRunner.swift:67`
- **Verification status:** ✅ confirmed

`run(args:)` is an `async` method with no suspension points: `readDataToEndOfFile()` on stdout, then on stderr, then `waitUntilExit()` — all synchronous on a Swift Concurrency cooperative-pool thread. Two problems: (1) the pipes are drained sequentially — if the child writes ≥64KB to stderr while stdout is still open (e.g. verbose warnings/dumps from a long AI command), the child blocks on the full stderr pipe, never closes stdout, and `readDataToEndOfFile(stdout)` never returns: a permanent deadlock and a permanently lost pool thread (the code comment claims the deadlock is fixed, but only half of the read-before-wait fix was applied); (2) even on the happy path, multi-minute subprocesses (`TrackScanService` — "a scan runs for minutes", `targets extract`/meeting recap — multi-second AI calls) pin one pool thread (pool width == core count) for their entire duration, so a handful of concurrent CLI operations can stall all async work. `GoogleAuthService.runProcess` (139–141) and `JiraAuthService.runProcess` (159–163) use the same sequential-drain pattern.

```swift
// Read pipe data BEFORE waitUntilExit to prevent deadlock when output exceeds 64 KB.
let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
process.waitUntilExit()   // all blocking, inside `func run(args:) async`
```

- **Recommendation:** Drain stdout and stderr concurrently (two `Task.detached`/`DispatchQueue`), and move all blocking work off the cooperative pool via `Task.detached` (as in `WatchtowerAIService`). Apply the same fix to `GoogleAuthService.runProcess` and `JiraAuthService.runProcess`.

### Targets overdue/dueToday badge counts compare local wall-clock time against UTC dates; date-only targets due "today" get counted as overdue

- **Where:** `WatchtowerDesktop/Sources/Database/Queries/TargetQueries.swift:129`
- **Verification status:** ✅ confirmed

`fetchCounts` compares `due_date` against `nowDatetimeString()`/`todayDateString()`, which use a `DateFormatter` in the LOCAL time zone, whereas due dates are stored in UTC (Go: `internal/db/targets.go:338` `time.Now().UTC().Format("2006-01-02T15:04")`; `Target.swift` explicitly warns "never parse/format it in the local zone"). Two concrete failures: (1) for any non-UTC user, a target due at, say, 21:00Z today is considered overdue hours earlier/later depending on local offset, diverging from `Target.isOverdue`, which the list rows use; (2) for ALL users, a date-only due date equal to today (the live DB has `'2026-07-04'`, `'2026-07-06'`) satisfies `due_date < '<today>T14:30'` lexicographically, so a target that's simply due "today" is counted as both overdue AND dueToday at once — the sidebar badge (`SidebarCountsViewModel.overdueTaskCount`) turns red with N overdue, while the Targets list shows zero overdue.

```swift
let now = nowDatetimeString()
... AND due_date != '' AND due_date < ?
// nowDatetimeString() = DateFormatter("yyyy-MM-dd'T'HH:mm"), no timeZone set (local)
// vs Go writing/comparing time.Now().UTC(); Target.isOverdue uses todayUTCDayString()
```

- **Recommendation:** Set `timeZone = TimeZone(identifier: "UTC")` on the `nowDatetimeString()`/`todayDateString()` formatters (or use the same UTC helpers as `Target.isOverdue`). Separately handle date-only due dates so that "today" doesn't fall into overdue — compare by day, not by a lexicographic datetime prefix.

## Low

### `InboxViewModel` leaks a perpetual 30-second poll loop and a ValueObservation task on every visit to the Inbox tab — there is no stop path

- **Where:** `WatchtowerDesktop/Sources/ViewModels/InboxViewModel.swift:110`
- **Verification status:** ✅ confirmed

`InboxFeedView` holds the VM in `@State` and creates a fresh `InboxViewModel` + `startObserving()` on every appearance of the Inbox tab (`InboxFeedView.swift:121-126`); the `switch` in `Navigation.swift` destroys the view (and releases the VM) on tab change. But `pollTask` (a loop of `while !Task.isCancelled { Task.sleep(30s); self?.load() }`) and `observationTask` (a `for-await` over an infinite ValueObservation `COUNT(*) FROM inbox_items`) are never cancelled: there's no `stopObserving()`, no `deinit`, and no stop call from the view. An unstructured `Task` isn't cancelled when its last reference is dropped, so every visit leaks one perpetual 30-second timer and one observation that reruns a COUNT query on every commit to `inbox_items` for the rest of the app's lifetime. Over a day of tab switching, dozens of zombie observations and timers accumulate, running against a `nil weak self`.

```swift
pollTask = Task { [weak self] in
    while !Task.isCancelled {
        try? await Task.sleep(for: interval)
        guard !Task.isCancelled else { break }
        self?.load()
    }
}  // no cancel() call anywhere
```

- **Recommendation:** Add a `stopObserving()` that cancels `pollTask` and `observationTask`, and call it from `InboxFeedView`'s `.onDisappear` (see the `CustomTrackTimelineViewModel.stop()` pattern). Part of the same systemic issue as the ValueObservation-leak finding above.

### `PeopleViewModel.load()` always resets data to the newest window but leaves `selectedWindow`/label on the user's selection — stale, mismatched state after any write to `people_cards`

- **Where:** `WatchtowerDesktop/Sources/ViewModels/PeopleViewModel.swift:67`
- **Verification status:** ✅ confirmed

`loadWindow(at:)` lets the user page through a historical window (sets `selectedWindow` and loads cards for that window). But `load()` — retriggered by the `people_cards` COUNT observation whenever the daemon's people pipeline writes a card — unconditionally takes `windows.first` (the newest window) for cards, summary, and interactions, without resetting `selectedWindow` to 0. Scenario: the user selected window index 2 in the picker; the daemon finishes a people run; the observation fires `load()`; the list shows cards from the NEWEST window, while the picker still shows the old one, and `currentWindowLabel` (computed from `availableWindows[selectedWindow]`) renders the old date range — the UI silently shows data under the wrong label.

```swift
if let window = windows.first {
    cards = try PeopleCardQueries.fetchForWindow(db, from: window.from, to: window.to)
    ...
}
// selectedWindow never reset in load(); currentWindowLabel still reads availableWindows[selectedWindow]
```

- **Recommendation:** In `load()`, either reset `selectedWindow = 0` (if always showing the newest window is intended), or, conversely, respect the current `selectedWindow` and load that specific window, so the data and the label don't diverge.

### `DaemonManager.stopDaemon()` is a silent no-op when the path hasn't been resolved — the "Stop daemon" step in `UpdateService.install` effectively doesn't stop the daemon

- **Where:** `WatchtowerDesktop/Sources/Services/DaemonManager.swift:65`
- **Verification status:** ✅ confirmed

`startDaemon()` first calls `resolvePathIfNeeded()`, but `stopDaemon()` does not: it simply does `guard let path = watchtowerPath else { return }` and exits silently if the path hasn't been resolved. `UpdateService.install(daemonManager:)` (`UpdateService.swift:136`) receives a fresh `@State private var daemonManager = DaemonManager()` from `GeneralSettings` (`SettingsView.swift:41`); nothing in `GeneralSettings` calls `resolvePathIfNeeded/startPolling/startDaemon` on it, so `watchtowerPath` is nil and `await daemonManager.stopDaemon()` is guaranteed to be a no-op. The update then does `rm -rf` and replaces the `.app` while the old daemon (launched from the bundle being deleted) keeps running and writing to the DB — the explicit install step "1. Stop daemon" never happens. This only gets cleaned up later, when `ensureDaemonRunning()` performs a stop/start on the next launch. The DB is in WAL mode and lives outside the bundle, so there's no data corruption.

```swift
func stopDaemon() async {
    guard let path = watchtowerPath else { return }   // no resolvePathIfNeeded(), unlike startDaemon()
// UpdateService.swift:136  await daemonManager.stopDaemon()  // fresh DaemonManager -> watchtowerPath == nil -> no-op
```

- **Recommendation:** Add `await resolvePathIfNeeded()` at the top of `stopDaemon()` (symmetric with `startDaemon()`), so the stop step before the bundle swap actually takes effect. A one-line fix.

### The "Daily summary notifications" toggle is dead — briefing notifications arrive regardless of `notifyDailySummary`

- **Where:** `WatchtowerDesktop/Sources/Services/DigestWatcher.swift:102`
- **Verification status:** ✅ confirmed

`NotificationSettings` exposes exactly two toggles: "Decision notifications" (`notifyDecisions`) and "Daily summary notifications" (`notifyDailySummary`, default true). `DigestWatcher.poll()` gates the decisions block on `notifyDecisions` (lines 60–63), but the briefing notification block (lines 98–113) calls `sendBriefingNotification` for every new briefing with no setting check at all — `notifyDailySummary` is read nowhere in the code (grep confirms: only the `@AppStorage` declaration and the `Toggle` in `NotificationSettings.swift`). A user who turns off "Daily summary notifications" still gets a "Morning Briefing Ready" notification every day; the toggle has no effect whatsoever.

```swift
for briefing in newBriefings {
    notificationService.sendBriefingNotification(
        attentionCount: briefing.parsedAttention.count
    )   // no notifyDailySummary / preference check
}
```

- **Recommendation:** Wrap the briefing notification loop in a check of `@AppStorage("notifyDailySummary")`, symmetric with the `notifyDecisions` gate on the decisions block.

### `SearchViewModel`: a cancelled search task can overwrite newer results and clear the spinner mid-search (no cancellation check after debounce/read)

- **Where:** `WatchtowerDesktop/Sources/ViewModels/SearchViewModel.swift:43`
- **Verification status:** ✅ confirmed

`search()` cancels the previous task, but the old task only notices the cancellation via the throwing `Task.sleep`. If the old task has already passed the sleep and is inside `dbPool.read` when the user types again, there's no `isCancelled` check before `self.results = ...` and `self.isSearching = false`. If the read from the older (typically more expensive) query finishes after the newer one has already been assigned — realistic when the older query matches many FTS rows while the newer one is cheap — the UI will show results for a stale query string. The old task also unconditionally sets `isSearching = false` at the end, hiding the progress indicator while a newer search is still running.

```swift
self.results = try await dbManager.dbPool.read { db in try SearchQueries.search(db, query: trimmed) }
...
self.isSearching = false  // no Task.isCancelled guard around either assignment
```

- **Recommendation:** After `dbPool.read` and before assigning `results`/`isSearching`, add `guard !Task.isCancelled else { return }` (or verify that `trimmed` still matches the current query text).

### `PipelineHistoryViewModel.loadRuns`: unordered `Task.detached` loads let results from a stale day arrive after a newer one during rapid navigation

- **Where:** `WatchtowerDesktop/Sources/ViewModels/PipelineHistoryViewModel.swift:47`
- **Verification status:** ✅ confirmed

`goToPreviousDay/goToNextDay` call `loadRuns()`, which captures the date and spawns an independent `Task.detached`; there's no cancellation of the previous load and no check that `date == selectedDate` before assignment. Rapid prev/next clicks (each a separate fetch) can result in a slower fetch for an earlier day resolving last, so `runs` ends up showing day N-2's runs while `selectedDate`/the title show day N-1. `isLoading` is also reset by whichever task finishes first, while the other is still in flight.

```swift
let date = selectedDate
Task.detached {
    let result = try? await dbPool.read { db in try PipelineRunQueries.fetchByDate(db, on: date) }
    await MainActor.run {
        self.runs = result ?? []  // no guard that `date` still equals self.selectedDate
```

- **Recommendation:** Before assigning `runs`, check `guard date == self.selectedDate else { return }`, and also cancel the previous load when new navigation occurs.

### Node version directories are sorted lexicographically — older nvm/fnm versions (v9.x) win over newer ones (v18+/v22)

- **Where:** `WatchtowerDesktop/Sources/Utilities/Constants.swift:88`
- **Verification status:** ✅ confirmed

`searchNodeVersions` (used by `findInPath` to locate the claude/codex binaries) and the inline copy in `resolvedEnvironment` (line 137) pick the "latest" node version via `versions.sorted().reversed()`, which is a string sort: `"v9.11.2" > "v22.1.0" > "v18.20.0"` lexicographically. A user with an old nvm (v9/v8 era) alongside a current node will get the claude binary path from — and a PATH prefixed with — the ancient version; if claude (or codex) is also installed under that version, it will launch against an unsupported runtime and crash. This requires claude/codex to be installed under BOTH versions (ancient <v10 and current), which makes the scenario narrow.

```swift
for ver in versions.sorted().reversed() {   // lexicographic: "v9..." sorts after "v22..."
    for sub in ["bin", "installation/bin"] {
        let path = "\(dir)/\(ver)/\(sub)/\(binary)"
```

- **Recommendation:** Sort versions semantically (parse major/minor/patch as numbers, e.g. via `compare(options: .numeric)` or component parsing) instead of a plain string `sorted()`. Fix at both call sites (lines 88 and 137).

### `Constants.resolvedEnvironment()` synchronously spawns a login shell on first call — up to a 5-second main-thread freeze for `@MainActor` callers

- **Where:** `WatchtowerDesktop/Sources/Utilities/Constants.swift:121`
- **Verification status:** ✅ confirmed

The cached environment is computed lazily on first access by spawning `$SHELL -lc "echo $PATH"` and synchronously calling `pathProc.waitUntilExit()` with a 5-second kill timer. Some first callers run on the main actor: `GoogleAuthService.connect()` (line 31) and `JiraAuthService.connect()` (line 33) set `process.environment = Constants.resolvedEnvironment()` inside `@MainActor` methods before detaching. With a slow `~/.zshrc`/nvm-init (a common case, 1–3 seconds, up to the 5-second timeout for broken configs), the first click on "Connect" will freeze the UI for that long. In practice, the freeze is usually avoided: `AppState` calls `runCLIMigrations()` in a `Task.detached` at startup, which warms the cache off the main thread.

```swift
pathProc.arguments = ["-lc", "echo $PATH"]
...
pathProc.waitUntilExit()   // synchronous; first call may be on MainActor (GoogleAuthService.connect line 31)
```

- **Recommendation:** Make `resolvedEnvironment()` `async`, or guarantee that the cache is warmed in the background before the UI appears, and have `@MainActor` callers (`connect()`) fetch the environment via `await` off the main thread.

### `DigestWatcher.poll()` performs synchronous GRDB reads on the main actor every 60 seconds

- **Where:** `WatchtowerDesktop/Sources/Services/DigestWatcher.swift:69`
- **Verification status:** ✅ confirmed

`DigestWatcher` is `@MainActor`, and `poll()` runs on the main actor via a watch `Task`; it calls a synchronous `dbPool.read { ... }` directly (fetching digests, fetching briefings, plus per-digest channel/user lookups in `resolveChannelName`). Every 60-second tick blocks the main thread for the duration of the SQLite reads; on a large DB, or while the Go daemon holds the writer during a heavy sync, this produces periodic UI stutter. The rest of the app uses `ValueObservation` or async reads against the same DB. In practice the stall is usually sub-millisecond (an indexed `id>N` query, 0 rows in steady state).

```swift
private func poll() {
    ...
    let newDigests = try dbPool.read { db in      // sync read on MainActor
        try DigestQueries.fetchNewSince(db, afterID: lastCheckedDigestID)
    }
```

- **Recommendation:** Replace the synchronous `dbPool.read` inside `poll()` with `await dbPool.read` (the async variant), or move the polling over to `ValueObservation`, as done elsewhere in the app, to avoid touching SQLite on the main thread.
