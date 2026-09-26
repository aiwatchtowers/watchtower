# Settings Window Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Recompose the Settings window from 6 unbalanced tabs (with a 1500-line General monolith) into 5 logical tabs: Connections (master-detail) / Features / Meetings / System / Profile.

**Architecture:** Pure recomposition — section code moves from `GeneralSettings` into new per-tab files; no ViewModel, service, sheet, config-key, or `@AppStorage`-key changes. One shared `ConfigService` instance is owned by `SettingsView` and passed to tabs so all tabs edit one in-memory config; a shared `ConfigSaveBar` component replaces the General tab's bottom bar on every config-editing tab.

**Tech Stack:** SwiftUI (macOS 14+), XCTest + ViewInspector, swift-testing. Spec: `docs/superpowers/specs/2026-08-15-settings-window-redesign-design.md`.

## Global Constraints

- Everything committed (code, comments, commit messages) is in English.
- Read the "Swift / Desktop conventions" section of `docs/review/review-rules.md` before writing any code.
- Do NOT rename any `@AppStorage` key or `config.yaml` key. Do NOT modify any file under `Sources/Services/`, `Sources/ViewModels/`, or any `Add*AccountView` sheet.
- Existing ViewInspector tests locate content via `find(text:)` — keep all user-visible strings byte-identical unless a task explicitly says otherwise.
- Build/test from the worktree root `/Users/user/PhpstormProjects/watchtower/.claude/worktrees/settings-window-redesign`:
  - Build: `cd WatchtowerDesktop && swift build > /tmp/swift-build.log 2>&1; echo "exit=$?"` (then read the log on failure). Never pipe through `tail`/`head` directly — it masks the exit code. Never delete `WatchtowerDesktop/.build`.
  - Tests: `make test-swift FILTER=<TestClassName>` from the repo (worktree) root.
- Commit after each task (one commit per task, `feat(desktop):`/`refactor(desktop):` prefixes). Commits MUST be made from the worktree directory; verify `git branch --show-current` prints `feature/settings-window-redesign` before every commit.
- Sequential execution only — SwiftPM builds from two agents at once deadlock on the `.build` lock.

## File Structure (end state)

```
WatchtowerDesktop/Sources/Views/Settings/
  SettingsView.swift            # slim: TabView with 5 tabs, owns shared ConfigService, window frame
  ConfigSaveBar.swift           # NEW shared bottom save bar (+ parse/save error display)
  ConnectionsSettings.swift     # NEW master-detail container + ConnectionService enum + ConnectionStatusLogic
  SlackConnectionDetail.swift   # NEW Slack workspaces + legacy connect/reconnect/disconnect
  GoogleConnectionDetail.swift  # NEW Google accounts + Calendar/Gmail sync toggles
  EmailConnectionDetail.swift   # NEW IMAP/Outlook accounts
  CalendarConnectionDetail.swift# NEW CalDAV/ICS accounts + synced-calendars picker (all sources)
  JiraConnectionDetail.swift    # NEW Jira sites + Manage Boards link
  FeaturesSettings.swift        # NEW Digest/Briefing/Day Plan/Ideas sections + embedded NotificationSettings
  MeetingsSettings.swift        # NEW transcription/recording sections
  SystemSettings.swift          # NEW Workspace/AI/Sync/Daemon/Data/Logs/Update/Usage
  NotificationSettings.swift    # MODIFIED: body Form → Group (embeddable), struct name kept
  DataSettings.swift            # MODIFIED: body Form → Group (embeddable), struct name kept
  DaemonSettings.swift          # MODIFIED: DaemonSettingsContent body Form → Group, names kept
  LogsSettings.swift            # unchanged (already a VStack; embedded with fixed height)
  ProfileSettings.swift         # unchanged
Tests/
  ConnectionStatusLogicTests.swift  # NEW
```

---

### Task 1: ConfigSaveBar component

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Settings/ConfigSaveBar.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Settings/SettingsView.swift` (GeneralSettings uses the new bar)

**Interfaces:**
- Produces: `struct ConfigSaveBar: View` with init `ConfigSaveBar(config: ConfigService)`. Later tasks attach it via `.safeAreaInset(edge: .bottom) { ConfigSaveBar(config: config) }` on every config-editing tab.

- [ ] **Step 1: Create the component.** Move the body of `GeneralSettings.bottomBar` (SettingsView.swift, `private var bottomBar` near the end of the file: Open in Editor / Reveal in Finder / Saved indicator / Reload / Save with `⌘S`) into a new standalone view:

```swift
import SwiftUI

/// Shared bottom bar for Settings tabs that edit config.yaml. Owns the
/// transient save/parse error display so every tab that saves shows errors
/// the same way. The ConfigService instance is shared by SettingsView so all
/// tabs edit one in-memory config.
struct ConfigSaveBar: View {
    @Bindable var config: ConfigService
    @State private var saveError: String?
    @State private var showSaved = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            if let error = config.parseError {
                errorRow("Parse error: \(error)")
            }
            if let error = saveError {
                errorRow(error)
            }
            HStack {
                Button("Open in Editor") { config.openInEditor() }
                Button("Reveal in Finder") { config.revealInFinder() }
                Spacer()
                if showSaved {
                    Text("Saved").foregroundStyle(.green).transition(.opacity)
                }
                Button("Reload") {
                    config.reload()
                    saveError = nil
                }
                Button("Save") { save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func errorRow(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.red)
            .lineLimit(3)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.top, 6)
    }

    private func save() {
        do {
            try config.save()
            saveError = nil
            withAnimation { showSaved = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation { showSaved = false }
            }
        } catch {
            saveError = error.localizedDescription
        }
    }
}
```

Check `ConfigService` first: if it is `@Observable`, the `@Bindable` wrapper above is correct; if it is `ObservableObject`, use `@ObservedObject` instead — match whatever `GeneralSettings` currently relies on.

- [ ] **Step 2: Use it in GeneralSettings.** Replace `.safeAreaInset(edge: .bottom) { bottomBar }` with `.safeAreaInset(edge: .bottom) { ConfigSaveBar(config: config) }`; delete `private var bottomBar`, the `showSaved` state, and the two error `Section`s ("Parse Error" / "Save Error") from the Form body. Keep `saveError` state ONLY if still referenced by `saveConfig()` (the autosave helper used by the Calendar/Gmail toggles) — if so, keep `saveConfig()` and its `saveError` but render it inline where it was; simplest correct move: keep `saveConfig()` writing to a still-existing `@State saveError` and keep the "Save Error" section. Judgement call: prefer minimal diff, the section dies for good in Task 5.

- [ ] **Step 3: Build.** `cd WatchtowerDesktop && swift build > /tmp/swift-build.log 2>&1; echo "exit=$?"` — expect `exit=0`. (First build in this worktree is cold, ~4–5 min.)

- [ ] **Step 4: Commit.** `git add -A && git commit -m "refactor(desktop): extract shared ConfigSaveBar from GeneralSettings"`

---

### Task 2: Meetings tab

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Settings/MeetingsSettings.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Settings/SettingsView.swift`

**Interfaces:**
- Consumes: `ConfigSaveBar(config:)` from Task 1.
- Produces: `struct MeetingsSettings: View` with init `MeetingsSettings(config: ConfigService)`. `SettingsView` will keep this tab in Task 5's final assembly.

- [ ] **Step 1: Create MeetingsSettings.** Move from `GeneralSettings` into the new file, verbatim (controls, `.help` texts, `.onChange` handlers):
  - All 13 `@AppStorage("transcription.*")` properties, `@AppStorage(MeetingRecorderCenter.preloadBeforeMeetingsKey)`, `@AppStorage(JoinMeetingAction.autoRecordKey)`, and `@State showAdvancedTranscription`.
  - `transcriptionSection`, `advancedTranscriptionControls`, `engineCapabilityCaption`.

  Re-spread the single "Transcription" section into four sections (same controls, new grouping — this is the ONE permitted layout change):
  - **Engine**: Engine picker, Model picker, `engineCapabilityCaption`, unsupported-languages warning, Languages field.
  - **Recording**: "Auto-record on join", "Live transcription", "Preload model before meetings", "Mic auto-gain (experimental)", "Delete audio after N days" stepper (uses `config.transcriptAudioRetentionDays`).
  - **Speakers**: "Speaker roles" toggle, "Diarization threshold" field (moves out of Advanced; keep its `.help` text).
  - **Advanced** (`DisclosureGroup`, `showAdvancedTranscription`): Window (seconds), Language threshold, Runner-up margin, Force language, "Cross-window context (experimental)".

  Skeleton:

```swift
import SwiftUI

/// Meetings tab — everything about recording and transcribing meetings.
/// Moved out of the old General tab; same @AppStorage keys, same controls.
struct MeetingsSettings: View {
    @Environment(AppState.self) private var appState
    @Bindable var config: ConfigService
    // ... moved @AppStorage properties ...
    @State private var showAdvancedTranscription = false

    var body: some View {
        Form {
            engineSection
            recordingSection
            speakersSection
            advancedSection
        }
        .formStyle(.grouped)
        .padding(.horizontal)
        .padding(.top, 4)
        .safeAreaInset(edge: .bottom) { ConfigSaveBar(config: config) }
    }
    // ... sections ...
}
```

- [ ] **Step 2: Wire the tab.** In `SettingsView`: hoist `@State private var config = ConfigService()` from `GeneralSettings` up into `SettingsView` (GeneralSettings takes it as `@Bindable var config: ConfigService`; pass `config: config` at both call sites). Add after the General tab: `MeetingsSettings(config: config).environment(appState).tabItem { Label("Meetings", systemImage: "mic") }`. Delete the moved properties/sections from `GeneralSettings` (remove `transcriptionSection` from its Form body).

- [ ] **Step 3: Build + targeted tests.** Build as in Task 1. Then `make test-swift FILTER=StreamingTranscriberTests` (sanity: transcription code untouched) — expect pass.

- [ ] **Step 4: Commit.** `git commit -am "feat(desktop): Meetings settings tab (transcription moved out of General)"`

---

### Task 3: Features tab

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Settings/FeaturesSettings.swift`
- Modify: `WatchtowerDesktop/Sources/Views/Settings/NotificationSettings.swift`, `SettingsView.swift`

**Interfaces:**
- Consumes: `ConfigSaveBar(config:)`.
- Produces: `struct FeaturesSettings: View`, init `FeaturesSettings(config: ConfigService)`. `NotificationSettings` becomes embeddable (body renders sections without its own `Form`).

- [ ] **Step 1: Make NotificationSettings embeddable.** In `NotificationSettings.swift` change `var body` from `Form { ... }.formStyle(.grouped).padding(...)` to `Group { ... }` with the same children (permission banner `Section`, "Notification Types", "Meeting Reminders", "Quiet Hours", "Test"). Keep the struct name, all `@AppStorage` keys, `.task`/`onAppear` permission check, and every visible string (ViewInspector tests in `Tests/NotificationSettingsViewTests.swift` find by text).

- [ ] **Step 2: Create FeaturesSettings.** Move `digestSection`, `briefingSection`, `dayPlanSection`, `ideasSection` verbatim from `GeneralSettings`; embed notifications at the end:

```swift
import SwiftUI

/// Features tab — per-feature tuning (Digest, Briefing, Day Plan, Ideas)
/// plus notification preferences (moved from the standalone Notifications tab).
struct FeaturesSettings: View {
    @Bindable var config: ConfigService

    var body: some View {
        Form {
            digestSection
            briefingSection
            dayPlanSection
            ideasSection
            NotificationSettings()
        }
        .formStyle(.grouped)
        .padding(.horizontal)
        .padding(.top, 4)
        .safeAreaInset(edge: .bottom) { ConfigSaveBar(config: config) }
    }
    // ... moved sections ...
}
```

- [ ] **Step 3: Wire tabs.** In `SettingsView`: add `FeaturesSettings(config: config)` tab (label "Features", systemImage "sparkles") after General; DELETE the standalone `NotificationSettings()` tab. Remove the four moved sections from `GeneralSettings`.

- [ ] **Step 4: Build + tests.** Build; then `make test-swift FILTER=NotificationSettingsViewTests` — expect pass (Group body keeps the texts findable).

- [ ] **Step 5: Commit.** `git commit -am "feat(desktop): Features settings tab (digest/briefing/day plan/ideas + notifications)"`

---

### Task 4: System tab

**Files:**
- Create: `WatchtowerDesktop/Sources/Views/Settings/SystemSettings.swift`
- Modify: `DataSettings.swift`, `DaemonSettings.swift`, `SettingsView.swift`

**Interfaces:**
- Consumes: `ConfigSaveBar(config:)`.
- Produces: `struct SystemSettings: View`, init `SystemSettings(config: ConfigService)`. `DataSettings` and `DaemonSettingsContent` become embeddable (Group-bodied), names kept.

- [ ] **Step 1: Make DataSettings embeddable.** Change its body from `Form { storageSection; regenerateSection; dangerZoneSection }.formStyle(.grouped).padding()` to `Group { storageSection; regenerateSection; dangerZoneSection }`. Keep `.onAppear { refreshSizes() }` and every `.alert`/`.confirmationDialog` modifier attached to the `Group`. Struct name, state, and helper funcs unchanged.

- [ ] **Step 2: Make DaemonSettingsContent embeddable.** In `DaemonSettings.swift` change `DaemonSettingsContent.body` from `Form { ... }.formStyle(.grouped)` to `Group { ... }` with the same sections ("Daemon Status", conditional "Error"). `DaemonSettings` (the wrapper reading `appState.daemonManager` with its `onAppear`) is unchanged and becomes the embeddable unit.

- [ ] **Step 3: Create SystemSettings.** Move from `GeneralSettings`: the "Active Workspace" `LabeledContent` row (out of `workspaceSection` — ONLY this row; the Slack connect block stays for Task 5), `aiSection` + `testConnection()` + `diagnoseError(stderr:exitCode:)` + the `connectionTest*` state, `syncSection`, `usageLinkSection`, `updateSection`:

```swift
import SwiftUI

/// System tab — workspace identity, AI provider, sync cadence, daemon
/// status, storage/data management, log viewer, and app updates.
struct SystemSettings: View {
    @Environment(AppState.self) private var appState
    @Bindable var config: ConfigService
    @State private var connectionTestRunning = false
    @State private var connectionTestResult: String?
    @State private var connectionTestSuccess = false

    var body: some View {
        Form {
            Section("Workspace") {
                LabeledContent("Active Workspace") {
                    Text(config.activeWorkspace ?? "None")
                        .foregroundStyle(.secondary)
                }
            }
            aiSection
            syncSection
            DaemonSettings()
            DataSettings()
                .environment(appState)
            Section("Logs") {
                LogsSettings()
                    .frame(height: 320)
            }
            updateSection
            usageLinkSection
        }
        .formStyle(.grouped)
        .padding(.horizontal)
        .padding(.top, 4)
        .safeAreaInset(edge: .bottom) { ConfigSaveBar(config: config) }
    }
    // ... moved sections + helpers ...
}
```

  Note: `usageLinkSection` and `updateSection` read `appState` — they move verbatim. The old `GeneralSettings.runCLIProcess` static stays put for now (it is used by the Slack reconnect flow, which moves in Task 5).

- [ ] **Step 4: Wire tabs.** In `SettingsView`: add `SystemSettings(config: config)` tab (label "System", systemImage "gearshape.2"); DELETE the `DaemonSettings()`, `LogsSettings()`, and `DataSettings()` tabs. Remove the moved sections/state from `GeneralSettings` (keep `workspaceSection`'s Slack-connect remainder compiling — drop just the `LabeledContent` row).

- [ ] **Step 5: Build + tests.** Build; then `make test-swift FILTER=DaemonSettingsViewTests` — expect pass.

- [ ] **Step 6: Commit.** `git commit -am "feat(desktop): System settings tab (AI/sync/daemon/data/logs/update)"`

---

### Task 5: Connections tab (master-detail) + delete GeneralSettings

**Files:**
- Create: `ConnectionsSettings.swift`, `SlackConnectionDetail.swift`, `GoogleConnectionDetail.swift`, `EmailConnectionDetail.swift`, `CalendarConnectionDetail.swift`, `JiraConnectionDetail.swift` (all under `WatchtowerDesktop/Sources/Views/Settings/`)
- Create: `WatchtowerDesktop/Tests/ConnectionStatusLogicTests.swift`
- Modify: `SettingsView.swift` (final 5-tab assembly, delete `GeneralSettings`)

**Interfaces:**
- Consumes: `ConfigSaveBar(config:)`; view models on `AppState` (`slackAccountsViewModel`, `googleAccountsViewModel`, `emailAccountsViewModel`, `calendarAccountsViewModel`, `calendarViewModel`, `jiraAccountsViewModel`) — all pre-existing.
- Produces: `struct ConnectionsSettings: View` (init `ConnectionsSettings(config: ConfigService)`), `enum ConnectionService: String, CaseIterable, Identifiable { case slack, google, email, calendar, jira }`, `enum ConnectionStatus { case connected, error, notConfigured }`, `enum ConnectionStatusLogic` with `static func derive(okCount: Int, problemCount: Int) -> ConnectionStatus`.

- [ ] **Step 1: Write the failing test** (`WatchtowerDesktop/Tests/ConnectionStatusLogicTests.swift` — note: tests live directly in `Tests/`, match the neighbors' style):

```swift
import XCTest
@testable import WatchtowerDesktop

final class ConnectionStatusLogicTests: XCTestCase {
    func testNoAccountsIsNotConfigured() {
        XCTAssertEqual(ConnectionStatusLogic.derive(okCount: 0, problemCount: 0), .notConfigured)
    }

    func testAnyProblemIsError() {
        XCTAssertEqual(ConnectionStatusLogic.derive(okCount: 2, problemCount: 1), .error)
        XCTAssertEqual(ConnectionStatusLogic.derive(okCount: 0, problemCount: 1), .error)
    }

    func testAllOKIsConnected() {
        XCTAssertEqual(ConnectionStatusLogic.derive(okCount: 1, problemCount: 0), .connected)
    }
}
```

- [ ] **Step 2: Run it — expect FAIL** (type not defined): `make test-swift FILTER=ConnectionStatusLogicTests`.

- [ ] **Step 3: Create ConnectionsSettings.swift** with the logic + container:

```swift
import SwiftUI

enum ConnectionStatus: Equatable {
    case connected, error, notConfigured

    var color: Color {
        switch self {
        case .connected: .green
        case .error: .red
        case .notConfigured: .gray
        }
    }
}

enum ConnectionStatusLogic {
    /// problemCount = accounts whose status is not OK (error/revoked/removed-pending).
    static func derive(okCount: Int, problemCount: Int) -> ConnectionStatus {
        if problemCount > 0 { return .error }
        return okCount > 0 ? .connected : .notConfigured
    }
}

enum ConnectionService: String, CaseIterable, Identifiable {
    case slack, google, email, calendar, jira
    var id: String { rawValue }

    var label: String {
        switch self {
        case .slack: "Slack"
        case .google: "Google"
        case .email: "Email"
        case .calendar: "Calendar"
        case .jira: "Jira"
        }
    }

    var icon: String {
        switch self {
        case .slack: "number"
        case .google: "g.circle"
        case .email: "envelope"
        case .calendar: "calendar"
        case .jira: "checklist"
        }
    }
}

/// Connections tab — master list of external services on the left, the
/// selected service's accounts and settings on the right. Each detail view
/// owns the sections moved verbatim from the old General tab.
struct ConnectionsSettings: View {
    @Environment(AppState.self) private var appState
    @Bindable var config: ConfigService
    @State private var selected: ConnectionService = .slack

    var body: some View {
        HStack(spacing: 0) {
            List(ConnectionService.allCases, selection: $selected) { service in
                row(service).tag(service)
            }
            .listStyle(.sidebar)
            .frame(width: 190)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom) { ConfigSaveBar(config: config) }
        .onAppear {
            // Re-stat tokens/config: a connect or disconnect may have happened
            // outside this window (Calendar tab, Inbox banner, CLI).
            appState.slackAccountsViewModel?.refresh()
            appState.jiraAccountsViewModel?.refresh()
            appState.emailAccountsViewModel?.refresh()
            appState.calendarAccountsViewModel?.refresh()
            appState.googleAccountsViewModel?.refresh()
        }
    }

    private func row(_ service: ConnectionService) -> some View {
        HStack {
            Label(service.label, systemImage: service.icon)
            Spacer()
            if accountCount(service) > 0 {
                Text("\(accountCount(service))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Circle()
                .fill(status(service).color)
                .frame(width: 8, height: 8)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selected {
        case .slack: SlackConnectionDetail(config: config)
        case .google: GoogleConnectionDetail(config: config)
        case .email: EmailConnectionDetail()
        case .calendar: CalendarConnectionDetail()
        case .jira: JiraConnectionDetail()
        }
    }
}
```

  `accountCount`/`status` derive from the view models: for each service, `okCount` = accounts with `isOK`, `problemCount` = the rest (for Slack/Jira count only `enabled` accounts as problems when not OK; disabled-but-present counts toward neither ok nor problem — a deliberately soft-off account must not paint the row red. Calendar: `isOK` is a plain Bool on `CalendarAccount`. A nil view model → `.notConfigured`.) Each detail view's body is `Form { <moved sections> }.formStyle(.grouped)`.

- [ ] **Step 4: Run the logic test — expect PASS**: `make test-swift FILTER=ConnectionStatusLogicTests`.

- [ ] **Step 5: Move the five details.** From `GeneralSettings`, verbatim (sections, `.sheet`s, `.confirmationDialog`s, status-color helpers, pending-removal state):
  - **SlackConnectionDetail**: `workspaceSection` remainder (connect/reconnect/disconnect block + its confirmation dialog), `slackAccountsSection` + `slackAccountStatusColor`, state: `slackReconnecting/slackReconnectResult/slackReconnectSuccess/slackAuthProcess/slackAuth/slackDisconnecting/showSlackDisconnectConfirm/showAddSlackAccountSheet/slackAccountPendingRemoval`, local `daemonManager = DaemonManager()`, funcs: `reconnectSlack()`, `cancelSlackReconnect()`, `disconnectSlack()`, `runCLIProcess(path:arguments:)` (static). Keep `slackAuth.checkStatus()` in this view's `onAppear`.
  - **GoogleConnectionDetail**: `googleAccountsSection` + `googleAccountStatusColor` + `calendarSettingsSection` + `gmailSettingsSection`, state `showAddGoogleAccountSheet/googleAccountPendingRemoval`, plus a local `saveConfig()` + `@State saveError` (rendered as a caption under the toggles) for the two autosaving toggles' `.onChange` handlers.
  - **EmailConnectionDetail**: `emailAccountsSection` + `emailAccountStatusColor`, state `showAddEmailAccountSheet/accountPendingRemoval`.
  - **CalendarConnectionDetail**: `calendarAccountsSection`, `calendarSelectionSection` + `calendarSelectionRows`, state `showAddCalendarAccountSheet/calendarAccountPendingRemoval`.
  - **JiraConnectionDetail**: `jiraSettingsSection` (including the trailing "Manage Boards" section) + `jiraAccountStatusColor`, state `showAddJiraAccountSheet/jiraAccountPendingRemoval`.

- [ ] **Step 6: Final SettingsView assembly.** Delete `struct GeneralSettings` entirely. `SettingsView` becomes:

```swift
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var config = ConfigService()

    var body: some View {
        TabView {
            ConnectionsSettings(config: config)
                .environment(appState)
                .tabItem { Label("Connections", systemImage: "link") }
            FeaturesSettings(config: config)
                .environment(appState)
                .tabItem { Label("Features", systemImage: "sparkles") }
            MeetingsSettings(config: config)
                .environment(appState)
                .tabItem { Label("Meetings", systemImage: "mic") }
            SystemSettings(config: config)
                .environment(appState)
                .tabItem { Label("System", systemImage: "gearshape.2") }
            ProfileSettings()
                .environment(appState)
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
        }
        .frame(width: 760, height: 580)
    }
}
```

- [ ] **Step 7: Build + full Swift tests.** Build; then `make test-swift > /tmp/swift-test.log 2>&1; echo "exit=$?"` (full run, ~1–2 min) — expect `exit=0`. XCTest failures appear ABOVE the swift-testing tail in the log; check the whole log, not the last line.

- [ ] **Step 8: Commit.** `git commit -am "feat(desktop): Connections master-detail tab; retire the General settings monolith"`

---

### Task 6: Docs + lint + gate

**Files:**
- Modify: `docs/app-guide.md` (Settings paths), `CLAUDE.md` only if it references the settings tab layout (it does not today — verify with grep).

- [ ] **Step 1: Update app-guide.md.** It is injected into the chat-bot system prompt, so paths must match the new UI (memory rule: App Guide Maintenance). Update every settings path: "Settings → General → Transcription" / "Settings › Transcription" → "Settings › Meetings"; "Settings > Google Calendar" / "Settings > Gmail" → "Settings › Connections › Google"; "Settings → Jira Sites → Add Jira Site" → "Settings › Connections › Jira → Add Jira Site"; "Settings › Notifications › Meeting Reminders" → "Settings › Features › Meeting Reminders". Also update the `## Settings` overview section (line ~292) to describe the five tabs: Connections (master-detail per service), Features, Meetings, System, Profile. Keep descriptions of behavior unchanged — only navigation paths and the tab inventory change.

- [ ] **Step 2: Lint.** `make lint-diff > /tmp/lint.log 2>&1; echo "exit=$?"` — fix any violations in the new files (one-parameter-per-line etc. per swiftlint config).

- [ ] **Step 3: Full pre-PR gate.** From the worktree root: `cd WatchtowerDesktop && swift build > /tmp/swift-build.log 2>&1; echo "exit=$?"` and `swift test > /tmp/swift-test.log 2>&1; echo "exit=$?"`. Go side untouched, but run `go build ./... && go vet ./...` once for safety (should be instant, nothing changed).

- [ ] **Step 4: Commit.** `git commit -am "docs: update app-guide settings paths for the 5-tab layout"`

---

## Self-review notes

- Spec coverage: Connections master-detail (Task 5), Features (Task 3), Meetings (Task 2), System (Task 4), Profile untouched, shared save bar (Task 1), window size + GeneralSettings deletion (Task 5), app-guide (Task 6). Calendar-selection stays whole in CalendarConnectionDetail (spec's "not split" rule).
- Naming consistency: `ConfigSaveBar(config:)`, `ConnectionStatusLogic.derive(okCount:problemCount:)`, `ConnectionService`, detail view names — used identically across tasks.
- Behavior deltas allowed by spec: section regrouping in Meetings; diarization threshold moves from Advanced to a visible Speakers section; everything else verbatim.
