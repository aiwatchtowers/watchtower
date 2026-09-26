# Settings Window Redesign — Design

**Date:** 2026-08-15
**Status:** Approved by owner (structure + navigation chosen interactively)

## Problem

The Settings window is a 6-tab `TabView` (General, Profile, Notifications, Daemon, Logs, Data) where the General tab is a single ~1300-line `Form` with 18 sections in a flat scroll: Workspace, Slack Workspaces, Sync, Digest, Briefing, Day Plan, Ideas, AI, Google Calendar, Google Accounts, Calendar Accounts, Calendar selection, Gmail, Email Accounts, Transcription, Jira Sites, Usage, Update. Account management for four services is interleaved with per-feature tuning and system-level knobs; there is no grouping logic, and the tab split (tiny Daemon/Logs/Data tabs vs. the General monolith) is unbalanced.

## Decisions (made with the owner)

- **Grouping principle:** by sources + features + system, not by usage frequency and not strictly per-service.
- **Navigation:** hybrid — top-level tabs stay a `TabView`; the Connections tab gets nested master-detail navigation; other tabs are plain grouped forms.
- **Top-level tabs (5):** Connections / Features / Meetings / System / Profile. Transcription is large enough to earn its own Meetings tab. The standalone Notifications, Daemon, Logs, and Data tabs are dissolved into Features and System.

## Target Structure

### Tab 1: Connections (master-detail)

Left: a fixed list of 5 service entries, each with a status indicator (green = connected, red = error, gray = not configured) and an account count. Right: the detail pane for the selected service.

- **Slack** — workspaces list (current `slackAccountsSection`) + the legacy Connect/Reconnect/Disconnect block (current `workspaceSection`, minus the Active Workspace row which moves to System).
- **Google** — Google accounts list + Calendar/Gmail sync toggles (current `googleAccountsSection`, `calendarSettingsSection`, `gmailSettingsSection`).
- **Email** — IMAP accounts (current `emailAccountsSection` + Add sheet + setup assistant panel).
- **Calendar** — CalDAV/ICS accounts (current `calendarAccountsSection`) + the synced-calendars picker across **all** sources including Google (current `calendarSelectionSection`, moved wholesale — it is not split between screens).
- **Jira** — sites list (current `jiraSettingsSection`).

All Add sheets and confirmation dialogs move as-is with their sections.

### Tab 2: Features (grouped form)

Sections: Digest, Briefing, Day Plan, Ideas, Notifications (content of the current standalone Notifications tab, including the permission-denied banner and meeting-reminder settings).

### Tab 3: Meetings (grouped form)

The current `transcriptionSection` re-spread into sections: **Engine** (provider, model, languages), **Recording** (auto-record on join, live transcription, preload before meetings), **Diarization**, and an **Advanced** disclosure (windowSec, language threshold, margin, force language, context prompt, MicAGC) — same controls, same `@AppStorage` keys, no behavior change.

### Tab 4: System (grouped form)

Sections in order: **Workspace** (active workspace, read-only) → **AI** → **Sync** (poll interval, workers) → **Daemon** (status, read-only, current `DaemonSettings` content) → **Data** (storage sizes, regenerate, danger zone — current `DataSettings` content) → **Logs** (current viewer in a fixed-height section) → **Update** → the Usage & Pipeline Progress link button.

### Tab 5: Profile

Unchanged (`ProfileSettings` as today).

## Mechanics

- **Config saving:** same pattern as today — `ConfigService` + explicit bottom Save bar via `safeAreaInset`. The bar is extracted into a shared component and appears on every tab that edits config.yaml (Connections details, Features, System). `@AppStorage`-backed toggles keep saving instantly, as they do now.
- **Code layout:** `SettingsView.swift` (~1575 lines) is split into per-tab files: `ConnectionsSettings.swift` (+ one file per service detail where a detail is large), `FeaturesSettings.swift`, `MeetingsSettings.swift`, `SystemSettings.swift`. Section code moves, it is not rewritten — this is a recomposition, not a field-level redesign.
- **Window size:** grows to ~760×580 (the Connections master-detail needs width).
- **Non-goals:** no changes to ViewModels, services, sheets, or any Go/CLI/DB code; no renaming of `@AppStorage` or config keys; no field-level redesign of any section.

## Error handling

- Config parse/save error sections stay with the save bar component so any tab that saves shows them.
- Per-service auth errors keep rendering inside their (moved) sections; the Connections list row status derives from the same view models the sections already use.

## Testing

- Existing ViewInspector tests (e.g. `DaemonSettingsContent`) must stay green; content structs keep their names where tests reference them.
- New lightweight tests only where structure is testable without NSWindow (e.g. Connections list row status mapping, if extracted as pure logic).
- Pre-PR gate: `swift build`, `make test-swift`, `make lint-diff`.
