# UI bugs (state not reflected in the interface) — audit 2026-07-05

The audit covers the Watchtower Desktop layer (SwiftUI + GRDB) and the "UI ↔ Go CLI/daemon" boundary for situations where the actual data state is not reflected in the interface: stale lists, invisible cross-process writes, false indicators, and controls with no effect. Method — several search agents (finders) followed by independent adversarial verification of each candidate: tracing the full path from the user action to the data source and confirming the failure scenario against the code. Below are only findings that passed verification (refuted ones removed).

Dominant systemic pattern: most findings are consequences of a single architectural limitation. GRDB `ValueObservation` does not see records made by external processes (the Go daemon, the `watchtower` CLI as a subprocess), which the project itself documents in `InboxViewModel.swift:48-51` and `CatchUpViewModel.swift:25-28` and compensates for in some places with polling or a manual `load()`. In many other places there is no compensation, and comments in the code incorrectly claim that the observation will "pick up" the changes.

## High

### Scan results in the Watch tab do not appear in the activity feed

- **Where:** `WatchtowerDesktop/Sources/ViewModels/TargetWatchesViewModel.swift:96`
- **Verification status:** ✅ confirmed
- The user presses the scan action in the Watch tab on a target. `scanWatch()` runs `watchtower tracks scan <id>` as a subprocess; the CLI inserts new `track_events` rows over ITS OWN separate SQLite connection. The VM's `events` feed is populated exclusively by a GRDB `ValueObservation` on the `track_events` table (`start()`, lines 57-68), and `ValueObservation` does not see records made by external processes — a limitation the project itself documents in `InboxViewModel` (lines 48-51) and compensates for in `TargetsViewModel.promoteSubItem` (lines 485-488) with a manual `load()`. After the CLI returns, `scanWatch()` does no reload and discards the returned `created` events, keeping only their count in the note. As a result, the note reports "N new update(s)" while the activity feed below stays empty/stale until the user performs some unrelated in-process write to `track_events` or reopens the view.

```swift
let created = try await scanService.run(trackID: watch.id, since: iso)
note = created.isEmpty ? ... : "\(watch.text): \(created.count) new update(s)."
// self.events is not reloaded; the feed is fed only by ValueObservation,
// which does not see the CLI's write
```

- **Recommendation:** After `scanService.run`, merge the returned `created` array into `self.events` (or do an explicit in-process fetch of the latest `track_events` for this track), the way `TargetsViewModel.promoteSubItem` already does via a manual `load()`. This eliminates the mismatch between the counter note and the empty feed.

### Custom track timeline does not show events found by a manual scan (the ValueObservation comment is wrong)

- **Where:** `WatchtowerDesktop/Sources/ViewModels/CustomTrackTimelineViewModel.swift:101`
- **Verification status:** ✅ confirmed
- Same root cause, but on the Tracks side: `scanSinceLast()`/`scanHistory()` run a CLI subprocess that inserts `track_events` cross-process. A comment in the code claims "The CLI wrote any new rows; the ValueObservation stream pushes them" — but `ValueObservation` (`start()`, lines 76-88) only notifies about records via the app's own `DatabasePool`, not external connections. After a multi-minute history backfill, the banner reports "History scan found N updates," while the timeline list below it doesn't change until the user closes and reopens the track details (which recreates the VM and does a fresh initial fetch). The returned `created` array is used only for the counter.

```swift
// The CLI wrote any new rows; the ValueObservation stream pushes
// them. The returned slice is exactly what was created this run.
let created = try await scanService.run(trackID: track.id)
refreshLastRunAt()  // only the watermark is re-read; self.events is not updated
```

- **Recommendation:** Replace the incorrect comment and, after `scanService.run`, merge `created` into `self.events` (or perform an in-process re-fetch of the track's events). It would be better to extract the mapping/sorting logic into a shared method so both `ValueObservation` and the post-scan path reuse it.

### The provider switcher in chat doesn't actually change the AI provider (the other provider's model is sent to the configured one)

- **Where:** `WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift:109`
- **Verification status:** ✅ confirmed
- The provider picker in the `ChatView` toolbar calls `switchProvider()`, which only changes local UI state and calls `createService(for:)` — but `createService` ignores the `provider` argument and always returns `WatchtowerAIService`, which runs `watchtower ai query` without a provider flag. The Go side (`cmd/ai.go` `runAIQuery` → `newAIClient` in `cmd/generator.go`) picks the provider solely from the `ai.provider` config. So with `provider=claude` (the default), selecting "Codex" in the chat toolbar changes the model list to `gpt-5.4` and passes `--model gpt-5.4` to the Claude CLI: the request fails (or goes to the wrong provider), while the UI claims the user is talking to Codex. The picker looks like a working switch but has no effect on the backend.

```swift
static func createService(for provider: AIProvider) -> any AIServiceProtocol {
    _ = provider // provider selection handled by WatchtowerAIService via config
    return WatchtowerAIService()
}
// cmd/generator.go: if cfg.AI.Provider == "codex" {...} return ai.NewClient(cfg.AI.Model, ...)
```

- **Recommendation:** Pass the selected provider through to the CLI: add `--provider` (and the correct model) to `WatchtowerAIService.run`'s arguments, where Go already supports a global `--provider` flag. Alternatively, sync the toolbar selection with `ConfigService` (overwrite `ai.provider`) so the picker and the actual backend never diverge.

## Medium

### A newly added watch does not appear in the target's Watch tab

- **Where:** `WatchtowerDesktop/Sources/Views/Targets/TargetWatchTabView.swift:22`
- **Verification status:** ✅ confirmed
- The "Watch +" button shows `CustomTrackManagementSheet`, whose `generate()` creates a track via a CLI subprocess (`watchtower tracks create --target <id>`). The Watch tab's list is driven exclusively by `TargetWatchesViewModel`'s `ValueObservation` on `TrackQueries.fetchByLinkedTarget` (lines 46-56), which doesn't see the external CLI process's writes. The sheet has no `onCreated`/`onDismiss` hook to reload, and nothing else writes to the `tracks` table in-process. The worst — and also the most common — case is adding the FIRST watch for a target: the tab keeps showing "No watches yet — add a watch to track activity for this goal" even after the sheet confirmed "Custom track created," until the app is restarted or an unrelated in-process write to `tracks` occurs.

```swift
.sheet(isPresented: $showAddWatch) {
    CustomTrackManagementSheet(linkedTargetID: viewModel.target.id)
}  // the CLI writes the track cross-process; the watches list is fed only by ValueObservation
```

- **Recommendation:** Pass `CustomTrackManagementSheet` an `onCreated` completion hook that triggers an explicit in-process refresh of the Watch tab (`TargetWatchesViewModel` fetch via `fetchByLinkedTarget`), or restart the observation on `onDismiss`.

### A custom track created via the "+" button in the Tracks list doesn't appear in the Custom section

- **Where:** `WatchtowerDesktop/Sources/Views/Tracks/TracksListView.swift:29`
- **Verification status:** ✅ confirmed
- The "+" in the Tracks toolbar opens `CustomTrackManagementSheet` with no callback; a comment in the code claims "The tracks-table ValueObservation refreshes the Custom section on insert," but the insert happens in a CLI subprocess (`watchtower tracks create`), and `TracksViewModel`'s `ValueObservation` (`SELECT COUNT(*) FROM tracks`, lines 76-87) does not see cross-process writes. After the sheet shows "Custom track created" and the user taps Done, the list doesn't change; the track only appears after an in-process write to `tracks` (marking another track read/dismissed) or navigating away from and back to the Tracks tab (recreating the VM).

```swift
.sheet(isPresented: $showCreateSheet) {
    // Standalone custom track (no linked target). The tracks-table
    // ValueObservation refreshes the Custom section on insert.
    CustomTrackManagementSheet()
}
```

- **Recommendation:** Remove the incorrect comment and add an `onCreated` hook that does an explicit in-process refresh of `TracksViewModel` after the CLI returns. A single refresh mechanism should be reused across every place that opens `CustomTrackManagementSheet`.

### "All history" watch scan actually only scans from the last watermark

- **Where:** `WatchtowerDesktop/Sources/Views/Targets/TargetWatchTabView.swift:77`
- **Verification status:** ✅ confirmed
- The "All history" menu item calls `viewModel.scanWatch(watch, since: nil, ...)`. `scanWatch` maps `nil` to the absence of the `--since` flag (`let iso = since.map {...}`), and the Go CLI without `--since` runs `RunForTrack` — an incremental scan from the track's watermark (`cmd/tracks.go:802-805`; `internal/customtracks/pipeline.go`: "RunForTrack force-runs one custom track over activity since its watermark"). So "All history" is byte-for-byte identical to "Since last check" and returns "no new activity" for any already-scanned watch, silently skipping all the history the user asked for. The same bug exists in `scanAll()` (`TargetWatchesViewModel.swift:108-112`, labeled "all history"). The correct pattern already exists in `CustomTrackTimelineViewModel.scanHistory` (line 124), where `nil` is mapped to `Date(timeIntervalSince1970: 0)` before calling the service.

```swift
Button("All history") { Task { await viewModel.scanWatch(watch, since: nil, label: "all history") } }
// TrackScanService.run: if let since, !since.isEmpty { args += ["--since", since] }  → nil = scan only from watermark
```

- **Recommendation:** In `scanWatch`/`scanAll`, for "all history" mode map `nil` to the epoch (`Date(timeIntervalSince1970: 0)`) before calling the service, as in `CustomTrackTimelineViewModel.scanHistory`. This will make the CLI pass a `--since` with an early date and actually walk the full history.

### Sidebar badges never update from daemon data (observation is blind to cross-process writes, no polling)

- **Where:** `WatchtowerDesktop/Sources/ViewModels/SidebarCountsViewModel.swift:52`
- **Verification status:** ✅ confirmed
- All the sidebar badge counters (inbox unread, updated tracks, unread digests/briefings, targets, the Catch-Up sum) are updated only through a single GRDB `ValueObservation` on `COUNT(*)` of the tables plus a single `loadInitial()` at startup (`AppState.initSidebarCounts`). Each of these tables is populated by the Go daemon / CLI pipelines as separate processes, whose writes `ValueObservation` doesn't see — which is exactly why `InboxViewModel` added 30-second polling (lines 48-51). `SidebarCountsViewModel` has no such polling, and nothing else restarts `fetch()`. Scenario: the app is open, the daemon detects new mentions/DMs or creates tracks/digests — the always-visible sidebar badges stay at their old values (including 0) until the user makes some in-app write, which defeats the purpose of badges as a signal of new items.

```swift
let observation = ValueObservation.tracking { db -> [Int] in
    let tables = ["tracks", "briefings", "targets", "inbox_items", "digests", ...]
    return tables.map { (try? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \($0)")) ?? 0 }
}  // no polling; daemon writes are cross-process and never trigger this
```

- **Recommendation:** Add periodic polling of `fetch()` to `SidebarCountsViewModel` (following the pattern of `InboxViewModel` / `CatchUpViewModel`), or trigger a refresh on `DigestWatcher`/scenePhase notifications. Ideally, a shared cross-process signal (a file watcher on the DB) so we don't end up with independent timers everywhere.

### "Generate Briefing" doesn't show the generated briefing

- **Where:** `WatchtowerDesktop/Sources/ViewModels/BriefingViewModel.swift:137`
- **Verification status:** ✅ confirmed
- `generateBriefing()` runs `watchtower briefing generate` as a subprocess and, on success, only sets `isGenerating=false` — `load()` is not called. The only refresh path is the `ValueObservation` on `SELECT COUNT(*) FROM briefings` (lines 33-41), but `ValueObservation` doesn't see writes from an external process (the project documents this in `CatchUpViewModel.swift:25-28`). Scenario: the user is on the empty Briefings tab and taps "Generate Briefing" (`BriefingsListView.emptyList`), the CLI succeeds, the spinner stops — but the view still reads "No briefings yet" until the user leaves and comes back to the tab. The same staleness applies to briefings written by the daemon while the tab is open.

```swift
await MainActor.run { [weak self] in
    self?.isGenerating = false
    if process.terminationStatus != 0 {
        self?.generateError = ...
    }
}
// no self?.load() on success; the COUNT(*) observation doesn't see the CLI process's write
```

- **Recommendation:** After the subprocess completes successfully, call the authoritative `load()` (as `CatchUpViewModel` does) rather than relying on `ValueObservation`. Also consider polling while the tab is open to catch briefings from the daemon.

### Stopping a chat stream saves the partial response twice — duplicate assistant messages

- **Where:** `WatchtowerDesktop/Sources/ViewModels/ChatViewModel.swift:248`
- **Verification status:** ✅ confirmed
- `cancelStream()` (the Stop button via `ChatView`'s onStop, as well as `bind()`/`newChat()`/`deleteCurrentChat`) saves the non-empty partial assistant text via `persistMessage()`. But the cancelled `streamTask` keeps running past the `for-await` (the `AsyncThrowingStream` iteration simply ends on cancellation, and the thrown `CancellationError` is swallowed by the `if !Task.isCancelled` guard), and then unconditionally runs the trailing "Always persist the response" block, writing the same partial `fullText` a second time via `persistResponseStatic()`. The result is two identical assistant rows in `chat_messages`. The message observation (`records.count != messages.count`) reloads the data, and the duplicate bubble appears in the UI immediately, and again every time the conversation is reopened.

```swift
func cancelStream() {
    streamTask?.cancel() ...
    if !partialText.isEmpty, let convID = conversationID {
        persistMessage(conversationID: convID, role: "assistant", text: partialText)
    }
}
// streamTask tail (lines 198-201, no isCancelled guard):
if !fullText.isEmpty, let convID = capturedConvID {
    Self.persistResponseStatic(dbManager: capturedDBManager, conversationID: convID, text: fullText)
}
```

- **Recommendation:** Keep exactly one save path: either guard the trailing block with `if !Task.isCancelled`, or don't save the partial text in `cancelStream()` and rely on the tail instead. Add a unit test that actually starts `streamTask` with a non-nil `conversationID` to pin down the absence of a duplicate.

### Catch-up "Regenerate" doesn't refresh the theme in the UI (the observation comment is wrong, the CLI write is cross-process)

- **Where:** `WatchtowerDesktop/Sources/ViewModels/CatchUpViewModel.swift:215`
- **Verification status:** ✅ confirmed
- `regenerate()` runs `watchtower catchup regen <id>`, and its doc comment says the overwritten row is "picked up by the observation." But this very file's own comment (lines 25-28) states that `ValueObservation` does not see writes from a separate CLI process — which is why `startSession()` adds 1-second polling. `regenerate()` neither starts polling nor calls `reload()` after the CLI exits. Scenario: the user taps Regenerate on a failed theme (`failedNotice` literally suggests "Use Regenerate to retry") — the CLI overwrites the row, but the review panel keeps showing the stale/failed theme indefinitely, with no progress indicator, until an unrelated in-process write (acknowledge/snooze) or a session restart triggers a refresh. `submitFeedback()` has the same gap.

```swift
/// Regenerates a single theme ... the row is overwritten in place and picked up by the observation.
func regenerate(_ theme: CatchUpTheme, comment: String) {
    ...
    Task.detached {
        let result = await Self.runCLI(path: cliPath, arguments: args)
        if result.exitCode != 0 { ... error ... }
        // no reload()/polling on success
    }
}
// same file, line 26: "GRDB ValueObservation cannot see writes from the separate CLI process"
```

- **Recommendation:** Call `reload()` after a successful `regen` (or poll temporarily until the updated theme appears), as `startSession()` already does. Also fix the misleading doc comment while at it.

### Links applied via Suggest Links don't appear in the target's Links tab

- **Where:** `WatchtowerDesktop/Sources/Views/Targets/TargetDetailView.swift:183`
- **Verification status:** ✅ confirmed
- The Links tab renders a `@State` array `links`, loaded by `loadLinks()` only on `.onAppear` (line 146) and `.onChange(of: target.id)` (line 153). `SuggestLinksSheet.apply()` (`SuggestLinksSheet.swift:120-147`) inserts rows into `target_links` (and optionally updates `parent_id`), then dismisses — but `TargetDetailView` has no refresh hook on `$showSuggestLinksSheet` (compare `TrackDetailView`, which has `.onChange(of: showCreateTarget)` with a reload). There's no observation on `target_links` either (`TargetsViewModel` only observes `COUNT(*) FROM targets`). Scenario: the user opens Links ("No links yet."), runs "Suggest links," picks suggestions, taps Apply — the sheet dismisses, and the Links tab still shows "No links yet." until the user switches to another target and back. The `parentTarget` breadcrumb (loaded by `loadHierarchy` with the same lifecycle) goes stale the same way when a parent is applied.

```swift
.sheet(isPresented: $showSuggestLinksSheet) {
    if let suggestedLinks {
        SuggestLinksSheet(targetID: target.id, suggestions: suggestedLinks)
    }
}  // no onDismiss/onChange reload; links is loaded only on appear / target.id change
```

- **Recommendation:** Add a completion hook to the sheet (or `.onChange(of: showSuggestLinksSheet)`) that calls `loadLinks()` and `loadHierarchy()` after applying. Follow the pattern of the "Add sub-target" sheet, which already passes `{ _ in loadHierarchy() }`.

### Inbox "Load more" pagination gets wiped out by 30-second polling and any action on an item

- **Where:** `WatchtowerDesktop/Sources/ViewModels/InboxViewModel.swift:139`
- **Verification status:** ✅ confirmed
- `loadMore()` appends pages beyond the first 50 feed items (`feedOffset` grows). But `load()` always re-requests only the FIRST page (`fetchFeed(limit: feedPageSize, offset: 0)`) and replaces `feedItems` with it, resetting `feedOffset`. `load()` is called by the unconditional 30-second polling loop (`startPolling`, lines 107-117) and by every user action (`markSeen` on expand, `markRead`, `dismiss`, `snooze`, feedback). Scenario: a user with >50 feed items taps "Load more" a couple of times and scrolls while reading; within ≤30s the polling fires (or expanding an item → `markSeen` → `load`) and `feedItems` collapses back to the first 50 — the items under the cursor disappear and the scroll position jumps.

```swift
let feed = try InboxQueries.fetchFeed(db, limit: self.feedPageSize, offset: 0, ...)
...
feedItems = result.5
feedOffset = result.5.count  // poll: while !Task.isCancelled { try? await Task.sleep(for: interval); self?.load() }
```

- **Recommendation:** In `load()`, re-request up to the current offset (`limit: max(feedPageSize, feedOffset)`) instead of hard-coding a single page, so polling and actions preserve the already-loaded pages and scroll position.

### Meeting prep in the calendar shows the previous event's prep when generation for the new one fails (shared VM + result checked before error)

- **Where:** `WatchtowerDesktop/Sources/Views/Calendar/MeetingPrepView.swift:16`
- **Verification status:** ✅ confirmed
- `CalendarEventsView` reuses a single `MeetingPrepViewModel` for all events (line 5: `@State private var meetingPrepVM = MeetingPrepViewModel()`, generate call at line 187), and `MeetingPrepViewModel.generate()` never clears `result` — only `error`. `MeetingPrepDetailView` renders `result` before `error`. Scenario: the user taps Prepare on event A (succeeds), then Prepare on event B and the CLI fails (exit != 0): `error` is set, but `result` still holds event A's prep, so the panel for B silently shows event A's talking points/people notes with no error shown. `DayPlanView` explicitly works around exactly this class of bug ("Fresh VM per meeting avoids showing cached prep from a previous event," `DayPlanView.swift:78`), but `CalendarEventsView` wasn't fixed to match.

```swift
if viewModel.isLoading {
    loadingView
} else if let result = viewModel.result {
    prepContent(result)   // the stale result from the previous event wins
} else if let error = viewModel.error {
    errorView(error)      // unreachable while a stale result exists
}
```

- **Recommendation:** Clear `result` at the start of `generate()` (or use a fresh VM per event, as in `DayPlanView`). At minimum, render `error` before `result` so an error isn't hidden behind stale data.

### Saving General settings shows "Saved," but the running daemon keeps the old config, with no restart hint

- **Where:** `WatchtowerDesktop/Sources/Views/Settings/SettingsView.swift:527`
- **Verification status:** ✅ confirmed
- The Save button writes `config.yaml` and flashes "Saved." But the daemon loads the config once at process startup and keeps it in memory (`internal/daemon/daemon.go:49` `config *config.Config`, read as `d.config.Sync.PollInterval`, `d.config.Briefing.Hour`, `d.config.DayPlan`, etc. on every cycle; there is no reload path in `internal/daemon/`). So edits to sync interval, workers, digest enabled/model/language, briefing hour, day-plan have no effect until the daemon is manually restarted from a separate Daemon tab — and nothing in the UI hints at that. Scenario: the user changes Briefing Hour from 8 to 10, saves, sees "Saved" — and briefings keep being generated at 8 indefinitely.

```swift
Button("Save") {
    try config.save()
    withAnimation { showSaved = true }  // no daemon restart, no "restart required" notice
}
// internal/daemon/daemon.go:160: pollInterval := d.config.Sync.PollInterval (config captured in New(), never re-read)
```

- **Recommendation:** After saving, show a "daemon restart required" banner (or offer an auto-restart via the Daemon tab) for settings that affect the daemon. Longer term, add config reload on SIGHUP/file watcher to the daemon.

### Every-second polling of the Catch-up build phase yanks the user's selection away from any theme being reviewed

- **Where:** `WatchtowerDesktop/Sources/ViewModels/CatchUpViewModel.swift:130`
- **Verification status:** ✅ confirmed
- `apply()` runs on every observation event and every 1s polling tick in `startSession()`, and unconditionally redirects the selection to the first pending theme whenever the current selection isn't pending: `if selected == nil || !(selected?.isPending ?? false) { selected = themes.first { $0.isPending } }`. The theme list (`CatchUpView.themeList`) lets the user select any theme, including already-reviewed ones. Scenario: while the session is still building (polling active) or immediately after an acknowledge/snooze, the user clicks a reviewed theme to re-read it — within a second (or on the next observation event) the selection jumps back to the first pending theme, making reviewed themes impossible to inspect during the pass.

```swift
if let current = selected, let fresh = themes.first(where: { $0.id == current.id }) { selected = fresh }
if selected == nil || !(selected?.isPending ?? false) {
    selected = themes.first { $0.isPending }
}
```

- **Recommendation:** Only auto-redirect the selection when there is no selection (`selected == nil`) or the theme has disappeared from the list — don't override a selection the user explicitly made on a reviewed theme. Introduce a "user selected manually" flag, reset only when the current theme is acknowledged.

## Low

### The "CLI found" indicator and Test Connection in Settings ignore the configured claude_path/codex_path override

- **Where:** `WatchtowerDesktop/Sources/Views/Settings/SettingsView.swift:310`
- **Verification status:** ✅ confirmed
- The green/red status icon next to the "Claude CLI Path" / "Codex CLI Path" fields and `testConnection()` both use `Constants.findInPath("claude"/"codex")`, which only scans known directories and PATH and never checks the override the user entered in the adjacent field (`config.claudePath/codexPath`). Scenario: the user installs claude in a non-standard location and sets the override path: the indicator shows a red X "Claude CLI not found," and Test Connection fails with "Claude CLI not found" — even though the daemon and CLI respect the override and work fine. The Settings UI reports a breakage that doesn't exist (and tests the wrong binary from the one actually configured).

```swift
if let path = Constants.findInPath("claude") { Image(systemName: "checkmark.circle.fill") ... }
else { Image(systemName: "xmark.circle.fill").help("Claude CLI not found") }
// testConnection():
let cliPath: String? = isCodex ? Constants.findInPath("codex") : Constants.findInPath("claude")
guard let path = cliPath else { connectionTestResult = "\(providerName) CLI not found"; ... }
```

- **Recommendation:** Resolve the binary via `Constants.findClaudePath()`/`findCodexPath()` (config-override-first) instead of `findInPath`, so the indicator and Test Connection check the path that's actually configured.

### Decisions without a channel (cross-channel rollup decisions) can't be rated — feedback buttons are hidden behind a channelID guard

- **Where:** `WatchtowerDesktop/Sources/Views/Digests/DecisionDetailView.swift:139`
- **Verification status:** ✅ confirmed
- `channelActionsSection` wraps both the Slack "Mark read" button AND `FeedbackButtons` in `if !entry.channelID.isEmpty`. Decisions from daily/weekly rollup digests, where the AI didn't set a per-decision `channel_id`, resolve to an empty `channelID` (`DigestViewModel.buildDecisionEntries` falls back to `digest.channelID`, which is empty for daily/weekly). For such decisions — shown in the detail header as "Cross-channel" — the thumbs up/down buttons never render, so the AI feedback loop is unavailable exactly at the rollup level. The channel is only needed for the Slack action; feedback is keyed by `digestID:decisionIdx` and doesn't need a channel.

```swift
@ViewBuilder
private var channelActionsSection: some View {
    if !entry.channelID.isEmpty {   // also hides FeedbackButtons
        HStack { ... FeedbackButtons(entityType: "decision", entityID: "\(entry.digestID):\(entry.decisionIdx)", ...) }
    }
}
```

- **Recommendation:** Move `FeedbackButtons` out from under the `channelID` guard, leaving only the Slack-specific "Mark read" behind it. Feedback should render regardless of whether a channel is present.

### The Dependencies section doesn't refresh after promoting a sub-item into a child target

- **Where:** `WatchtowerDesktop/Sources/Views/Targets/TargetDetailView.swift:196`
- **Verification status:** ✅ confirmed
- The "Convert to sub-target" flow shows `PromoteSubItemSheet` (`.sheet(item: $promotingSubItem)`), which creates a child target via the CLI (`TargetsViewModel.promoteSubItem` → `TargetPromoteSubItemService`). `promoteSubItem()` calls `viewModel.load()`, so the LIST refreshes, but `TargetDetailView`'s `@State childTargets` (the "Dependencies" section) is loaded by `loadHierarchy()` only on appear / when `target.id` changes; unlike the "Add sub-target" sheet (line 172, which passes `{ _ in loadHierarchy() }`), the promote sheet has no completion hook. Scenario: the user converts a checklist item into a sub-target; the checklist entry disappears (the parent refreshes via the list VM), but the Dependencies section still reads "No sub-targets yet" / doesn't include the new child, until the user switches to another target and back. The same staleness affects children created via the target Assistant (`TargetsViewModel.createChild`).

```swift
.sheet(item: $promotingSubItem) { ctx in
    ...
    PromoteSubItemSheet(parent: target, subItem: ctx.item, subItemIndex: ctx.index, viewModel: viewModel, ...)
}  // no loadHierarchy() on dismiss; childTargets is loaded only in onAppear/onChange(of: target.id)
```

- **Recommendation:** Give the promote sheet a completion hook that calls `loadHierarchy()` (following the "Add sub-target" sheet's pattern); also close the same gap in `createChild`.

### Navigating to a briefing older than the first page silently does nothing

- **Where:** `WatchtowerDesktop/Sources/Views/Briefings/BriefingsListView.swift:11`
- **Verification status:** ✅ confirmed
- The detail view only renders when the selected id is found in `vm.briefings`, which `load()` caps at `pageSize=30`: `if let selID = selectedBriefingID, let briefing = vm.briefings.first(where: { $0.id == selID })` — otherwise it silently falls back to `listView`. `appState.navigateToBriefing()` (from the "Briefing" button in Day Plan, catch-up source refs, notifications) sets `pendingBriefingID`; if that briefing isn't among the 30 most recent (e.g., a ref from catch-up, or an old day plan after a month of briefings), the click has no visible effect: the list is shown, there's no error, and `markAsRead` is still called for the invisible briefing via `onChange(of: selectedBriefingID)`.

```swift
if let selID = selectedBriefingID,
   let briefing = vm.briefings.first(where: { $0.id == selID }) {
    detailView(briefing)
} else {
    listView(vm)   // silent fallback; selectedBriefingID remains set
}
```

- **Recommendation:** When the id isn't found on the loaded page, resolve the briefing via the VM's existing `fetchByID` path (and/or load pages until the needed one is reached), instead of silently falling back to the list.

### Marking a digest read re-triggers the counter observation and resets digest pagination back to the first 50

- **Where:** `WatchtowerDesktop/Sources/ViewModels/DigestViewModel.swift:293`
- **Verification status:** ✅ confirmed
- `markDigestRead()`/`markDigestsRead()` write to the `digests` table through the app's own pool. The `ValueObservation` from `startObserving()` watches `SELECT COUNT(*) FROM digests` without `removeDuplicates`, and GRDB notifies on every transaction that touches the observed region (the `digests` table), even if the resulting count didn't change — so every mark-read triggers a full `load()`, which replaces `digests` with the first page (`fetchAll` default limit 50) and resets `digestsOffset`/`hasMoreDigests`. Scenario: the user has scrolled through 150 loaded digests (3 pages), clicks one to mark it read → the array collapses back to 50 rows, the scroll position jumps, and the loaded pages disappear until the user scrolls again. The carefully maintained local updates inside `markDigestRead` show that a reload was not the intended behavior.

```swift
let observation = ValueObservation.tracking { db in
    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM digests") ?? 0
}
for try await _ in observation.values(in: dbPool).dropFirst() { self?.load() }
// load(): digests = applySort(result.digests); digestsOffset = result.digests.count  // page 1 only
```

- **Recommendation:** Add `.removeDuplicates()` to the count observation and/or have `load()` re-request up to the current `digestsOffset`, so marking read doesn't truncate a scrolled list. Rely on the already-maintained local updates instead of a full reload.

### Thumbs up/down: a quick re-vote can restore the wrong state after reopening

- **Where:** `WatchtowerDesktop/Sources/Database/Queries/FeedbackQueries.swift:36`
- **Verification status:** ✅ confirmed
- `FeedbackButtons.submitFeedback` INSERTs a new feedback row on every click (no upsert), and `loadExistingFeedback` restores the current rating via `ORDER BY created_at DESC LIMIT 1`. `created_at` defaults to second-granularity (`strftime('%Y-%m-%dT%H:%M:%SZ','now')`), with no tiebreak on `id DESC`. Scenario: the user clicks 👍, then corrects it to 👎 within the same second (a normal mis-click correction); both rows share the same `created_at`, so on the next view load (returning to the tab, restart) `getFeedback` may return the stale 👍 row, and the button highlights a rating the user explicitly moved away from. The duplicate rows also inflate the `getStats` counts in Training settings.

```sql
INSERT INTO feedback (entity_type, entity_id, rating, comment) VALUES (?, ?, ?, ?)
...
SELECT * FROM feedback WHERE entity_type = ? AND entity_id = ?
ORDER BY created_at DESC LIMIT 1   -- no id tiebreak
```

- **Recommendation:** Add `, id DESC` to the `ORDER BY` for deterministic recovery of the last rating; ideally, replace the append-only INSERT with an upsert on `(entity_type, entity_id)`, which would also fix the `getStats` inflation.
