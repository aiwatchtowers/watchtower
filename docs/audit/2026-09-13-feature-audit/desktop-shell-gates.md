# Audit — Desktop shell + Feature Manager + GATE MATRIX

Repo `/Users/user/PhpstormProjects/watchtower` @ `feature/agent-actions` 37179540. Read-only; paths under `WatchtowerDesktop/Sources/` are abbreviated `WD/…`. Live-install facts were taken only by `ls`/`codesign -dv`/`ps` and a redacted tail sample of `daemon.log` (no config/DB read).

## 1. Feature status table

| Feature | Gate key + default | Entry points | Reachable from UI? | Verdict | Why |
|---|---|---|---|---|---|
| App lifecycle (singleton bootstrap, tray, close-to-tray, login item, quit) | — (Swift, ungated) | `TrayAppDelegate.applicationDidFinishLaunching` `WD/App/TrayAppDelegate.swift:82`; `AppState.initialize` `WD/App/AppState.swift:396`; `MenuBarExtra` in `WatchtowerApp.swift` | yes | **WORKS** | Bootstrap is window-independent (`:94–96`), `initialize()` latched by `isInitializing` (`AppState.swift:397`), re-entry only via `reinitializeAfterOnboarding` when DB is nil (`:553–557`); policy `.accessory`/`.regular` computed on `willCloseNotification` (`TrayAppDelegate.swift:118–128`); quit routes `QuitCoordinator` + bounded daemon stop (`:215–223`). |
| CLI binary store + `findCLIPath` | — | `AppState.syncCLIBinaryStore` `AppState.swift:503–517`; `CLIBinaryStore.sync` `WD/WatchtowerCore/Utilities/CLIBinaryStore.swift:122`; `Constants.findCLIPath` `WD/WatchtowerCore/Utilities/Constants.swift:229` | n/a | **WORKS** (doc drift) | Live daemon pid 35808 runs from `~/Library/Application Support/Watchtower/bin/watchtower`, byte-size-equal to `build/Watchtower.app/Contents/MacOS/watchtower` (34 566 144 B, both TeamIdentifier 7WFLZDVUV3). Store is re-synced on every launch before the daemon path is resolved (`AppState.swift:417–421`). CLAUDE.md says the verdict is "cached per launch" — it is **not** any more (`CLIBinaryStore.swift:52–60,71–80`): every `findCLIPath()` re-hashes both 34 MB binaries + `SecStaticCodeCheckValidity` (see L-2). |
| Daemon start/stop/restart from Desktop | — | `DaemonManager` `WD/WatchtowerCore/Services/DaemonManager.swift:43,64,112,137`; `AppState.ensureDaemonRunning` `AppState.swift:603–612` | tray only (Settings toggle removed by design) | **WORKS DIFFERENTLY** | `restart()` discards both exit codes (`DaemonManager.swift:115,120`) and returns Void — the memory note is correct. A `sync stop` that times out (10 s, `cmd/sync.go:163–175`) is followed by `sync --daemon --detach` that exits ≠0 ("daemon already running", `cmd/sync.go:184`) and nobody learns; see H-3. |
| Auto-update (public GitHub / gated corp flavor) | Info.plist `WTBuildFlavor`; `lastUpdateCheckDate` (24 h) | `AppState.initialize` `AppState.swift:488` → `UpdateService.checkIfNeeded` `WD/Services/UpdateService.swift:232–238`; surfaces `SidebarView.swift:140`, `SystemSettings.swift:316` | yes | **WORKS** (not verified live) | Custom (no Sparkle). Channel resolution `UpdateService.swift:40–48`: `""`→GitHub, `dev`→disabled, flavor+feed→Cloudflare-Access gated manifest `dl/manifest/<flavor>.json` (`:182`). Error paths leave `lastUpdateCheckDate` unset so the check retries next launch (`:174–176,210–212`). Could not exercise network. |
| Log rotation | const `maxLogSize = 20 MiB` `cmd/sync.go:123` | `rotateLogIfOversized` at daemon open `cmd/sync.go:193` and `:293` | n/a | **WORKS DIFFERENTLY** | Rotation only at open; live install: `daemon.log` 238 MB + `.1` 324 MB, and an identical-size **second copy** `watchtower.log`/`.1` (560 MB of logs). Growth ≈150 MB/day, dominated by per-message `slack API: reactions.get` lines — see H-2. |
| Sidebar navigation + feature-gated tabs | `SidebarDestination.requiredFeatures` `WD/App/SidebarDestination.swift:103–116` | `MainNavigationView.detailView` `WD/App/Navigation.swift:181–250` | yes | **WORKS** | 8 tabs hide when their feature is disabled; fallback to `.inbox` (`:149–156`). Full table §2. |
| Inbox tab = Action Strip (Wave 2) | `inbox.situations.enabled` default **false** (`internal/config/defaults.go:35`) | `Navigation.swift:203–204` → `ActionStripView` | yes | **WORKS** (see H-1 for collateral) | Strip renders; the old `InboxFeedView` subtree is now dead code — including the **Profile** and **Learned rules** tabs that lived inside it. |
| Assistant profile brief + style profile editor (`SecretaryProfileView`) | — | only `WD/Views/Inbox/InboxFeedView.swift:272–273` | **NO** | **UNREACHABLE** | CLAUDE.md: "Edited from the Desktop 'Profile' tab (`SecretaryProfileView`)". That tab was inside `InboxFeedView`, which no navigation reaches after Wave 2. `workspace.secretary_profile`/`style_profile` can no longer be edited from the app. H-1. |
| Learned-rules management (`InboxLearnedRulesView`) | — | only `InboxFeedView.swift:260` | **NO** | **UNREACHABLE** | Same collateral as above; rules still derive from 👍/👎 but cannot be viewed/edited/deleted from UI. H-1. |
| Situations Dashboard (`DashboardView`, `SituationReviewPane`, Discuss) | `inbox.situations.enabled` | `InboxFeedView.swift:45` only | **NO** | **UNREACHABLE** (by design, Wave 2 §4.2) | Kept in code per spec; `AppState.initDashboard` still constructs and **observes** `DashboardViewModel` + `FeedViewModel` at every launch (`AppState.swift:665–672`) for views nobody can open. L-3. |
| Legacy Home overview (`Views/Home/*`) | — | none | **NO** | **UNREACHABLE** | `WorkspaceOverviewView` has zero references outside its file; `ActivityFeed`/`StatsCard`/`SyncStatusBanner` only referenced from it. Dead directory. |
| `ExtractNoticeBanner`, `InboxFeedbackSheet` | — | none | **NO** | **UNREACHABLE** | Zero references anywhere (`WD/Views/Targets/ExtractNoticeBanner.swift`, `WD/Views/Inbox/InboxFeedbackSheet.swift`). |
| Onboarding incl. feature splash | `onboarding_current_step` UserDefaults + `user_profile.onboarding_done` | `NavigationRoot` `Navigation.swift:10–13`; `OnboardingCompletion.finish` `WD/App/OnboardingCompletion.swift:31`; skip `OnboardingView.swift:1322` | yes | **WORKS** | Both known follow-ups are closed: no-Slack install completes locally (`OnboardingChatViewModel.swift:561–572`, "audit H2"), staged feature toggles are discarded on Skip (`OnboardingView.swift:1331`, "audit H3"). |
| Settings window (5 tabs) | — | `WD/Views/Settings/SettingsView.swift:9–26` | yes | **WORKS** | Connections / Features (+Notifications) / Meetings / System (Daemon, Data, AI, update) / Profile (+Skills, Assistant tools). |
| Feature Manager (registry + CLI + Settings) | per-feature keys, table §3 | `internal/features/registry.go`; `cmd/features.go`; `WD/Services/FeatureManagerService.swift:216–269`; `FeatureManagerSection.swift` | yes | **WORKS** (FEAT-01..04 hold on the daemon path) | All 13 gated daemon phases check the gate first (§3.B). CLI-sync path exception documented (FEAT-01 Scope note) but still runs Tracks+People with their features off (M-1). |
| Notifications settings | `notifyDecisions`/`notifyDailySummary`/`quietHoursEnabled` | `WD/Services/DigestWatcher.swift:71–110` | yes | **WORKS DIFFERENTLY** | "Daily summary notifications" toggle is **dead** — briefing pushes fire unconditionally (`DigestWatcher.swift:100–110`); "Quiet hours" is a mute-all switch with no hours (`:76–78`). M-3. |
| Login-item autostart | `tray.loginItemRegisteredBundlePath` | `TrayAppDelegate.swift:253–272` | no UI (System Settings only) | **WORKS DIFFERENTLY** | Registers silently on first launch of **each bundle path**; a worktree/dev build launched once re-points `SMAppService.mainApp` at itself. M-4. |
| Jira Desktop dashboards (Workload/Blockers/Project Map/Releases) | Go: `jira.features.*` (no SetDefault → all false) | Sidebar EXECUTION section, always visible; Swift reads GRDB directly (`WD/ViewModels/WorkloadViewModel.swift:130–137`) | yes | **WORKS DIFFERENTLY** | Desktop ignores `jira.features.*` (works off synced rows); the **briefing** Jira sections and CLI dashboards honour them and are all OFF for the owner because nothing seeds role defaults except `jira features reset` (`cmd/jira.go:1305–1310`). H-4. |

Verdict counts: WORKS 8 · WORKS DIFFERENTLY 6 · UNREACHABLE 5 · BROKEN 0 · DARK (listed in §3.D) — `inbox.situations`, `reaction_commands`, memory sources/surfaces day_plan+meeting_prep, `jira.features.*`.

## 2. Navigation reachability table

Sidebar → `MainNavigationView.detailView` (`WD/App/Navigation.swift:181–250`). Sections: root `[targets, tracks]`, FOCUS `[catchUp, briefings, dayPlan, inbox, ideas, calendar]`, EXECUTION `[projectMap, releases, blockers, workload]`, INSIGHTS `[digests, people, memory, statistics]`, trailing `[chat]`, TOOLS `[search, boards, usage, mcpServer]` (`WD/App/SidebarSection.swift:24–28`, `SidebarDestination.swift:88–101`). All sections start collapsed (`SidebarSection.swift:32`). Users may also hide items per section (`sidebar.hiddenItems`, `SidebarView.swift:38–47`).

| View (file) | Reached via | Hidden when | Verdict |
|---|---|---|---|
| `ChatView` (Views/Chat) | sidebar `.chat` | never | REACHABLE |
| `CatchUpView` (Views/CatchUp) | `.catchUp` | `slack-digests` disabled (`SidebarDestination.swift:105`); "Catch Up unavailable" if VM nil | CONDITIONAL |
| `BriefingsListView` (Views/Briefings) | `.briefings` | `briefing` disabled | CONDITIONAL |
| `DayPlanView` (Views/DayPlan) | `.dayPlan` | `day-plan` disabled; VM nil when `ProcessCLIRunner.makeDefault()` fails (`AppState.swift:642`) | CONDITIONAL |
| `ActionStripView` (Views/Inbox) | `.inbox` (default destination `AppState.swift:16`, fallback target) | never | REACHABLE |
| `IdeasView` (Views/Ideas) | `.ideas` | `ideas` disabled | CONDITIONAL |
| `CalendarEventsView` → Events/Recordings (`RecordingsView`, `RecordingDetailView`) (Views/Calendar) | `.calendar` | never | REACHABLE |
| `TargetsListView`/`TargetDetailView`/`CreateTargetSheet` (Views/Targets) | `.targets` root | never | REACHABLE |
| `TracksListView` (Views/Tracks) | `.tracks` root | `tracks` disabled | CONDITIONAL |
| `DigestListView` (Views/Digests, incl. Decisions ledger) | `.digests` | all of `slack-digests`,`stream-digests`,`ideas` disabled | CONDITIONAL |
| `PeopleListView`/`PersonDetailView`/`ConnectionsView` (Views/People) | `.people` | `people-cards` disabled | CONDITIONAL |
| `MemoryView` (Views/Memory) | `.memory` | `memory` disabled | CONDITIONAL |
| `WorkloadView`, `BlockerMapView`, `ProjectMapView`, `ReleaseDashboardView` (Views/Workload, Blockers, Jira) | EXECUTION section | never hidden by feature or by Jira-connected state (`requiredFeatures` nil) | REACHABLE (shown even with no Jira account) |
| `StatisticsView` (+Activity/Channel/User) (Views/Statistics) | `.statistics` | never | REACHABLE |
| `SearchView` (Views/Search) | TOOLS `.search` | never | REACHABLE |
| `BoardsView` (Views/Boards) | TOOLS `.boards` | never | REACHABLE |
| `UsageView` (Views/Usage) | TOOLS `.usage` | never | REACHABLE |
| `MCPServerView` (Views/Tools) | TOOLS `.mcpServer` | never | REACHABLE |
| `SettingsView` + 5 tabs (Views/Settings) | Cmd+, / tray | never | REACHABLE |
| `JiraFeaturesSettingsView`, `JiraBoardsSettingsView`, `JiraUserMappingSettingsView` | Settings → Connections → Jira detail | Jira account present | CONDITIONAL |
| `FeatureManagerSection`, `NotificationSettings` | Settings → Features | never | REACHABLE |
| `MeetingsSettings` | Settings → Meetings | never | REACHABLE |
| `DaemonSettings`, `DataSettings`, `LogsSettings`, AI/update rows | Settings → System | never | REACHABLE |
| `ProfileSettings` + `SkillsSettingsSection` + `AssistantToolsSettingsSection` | Settings → Profile | never | REACHABLE |
| `OnboardingView`, `OnboardingChatView`, `OnboardingTeamFormView`, `FeatureSplashView` | `NavigationRoot` when `needsOnboarding`; Settings → Profile "re-run onboarding" (`AppState.startOnboarding` `:569`) | — | REACHABLE |
| `QuickCaptureView` (Views/QuickCapture) | tray "New Voice Idea" / ⌃⌥D (`TrayAppDelegate.swift:108–113`) | never | REACHABLE |
| `OAuthWebView` (Views/Auth) | Add-account sheets (Google/Slack/Jira/Email) | — | REACHABLE (sheet) |
| `StatusBarView`, `TrayMenuView` | always / MenuBarExtra | — | REACHABLE |
| `InboxFeedView` (Views/Inbox) | **nothing** (was `.inbox` before Wave 2) | — | **UNREACHABLE** |
| `DashboardView`, `SituationReviewPane`, `SituationRow`, `SituationDiscussSection`, `FeedDetailPanes`, `FeedRow`, `FeedFilterBar` (Views/Dashboard — whole dir) | only from `InboxFeedView` | — | **UNREACHABLE** |
| `SecretaryProfileView` (Views/Inbox) | only `InboxFeedView.swift:273` | — | **UNREACHABLE** (H-1) |
| `InboxLearnedRulesView` + `AddRuleSheet` (Views/Inbox) | only `InboxFeedView.swift:260` | — | **UNREACHABLE** (H-1) |
| `InboxCardView` (Views/Inbox) | only from `DashboardView`/feed | — | UNREACHABLE |
| `InboxFeedbackSheet` (Views/Inbox) | nothing | — | UNREACHABLE |
| `WorkspaceOverviewView`, `ActivityFeed`, `StatsCard`, `SyncStatusBanner` (Views/Home — whole dir) | nothing | — | UNREACHABLE |
| `ExtractNoticeBanner`/`ExtractNotice` (Views/Targets) | nothing | — | UNREACHABLE |

FEAT-02's "removes all of its UI" holds for the 8 tabs with `requiredFeatures`; `secretary-inbox`, `stream-digests`, `next-step`, `reaction-commands` have no UI to hide (inbox stays visible by design, `SidebarDestination.swift:99–102`). Disabling `people-cards` hides the People tab but people cards still surface inside Targets/Digests/Chat — acceptable, not a contract breach.

## 3. GATE MATRIX

### 3.A Go config keys (exhaustive) — see Appendix A below (≈150 keys).
Summary: **15 DEAD KNOBS** (default + struct field, zero production readers): `digest.action_items_interval`(+alias `digest.tracks_interval`), `inbox.max_items_per_run`, `inbox.max_awareness_cards`, `tracks.min_messages`, `jira.selected_boards`, `jira.features.who_ping`, `jira.features.write_back_suggestions`, `analysis.legacy_mode`, `day_plan.max_timeblocks`, `day_plan.min_backlog`, `day_plan.max_backlog`, `targets.extract.max_per_call`, `targets.extract.model`, `targets.resolver.slack_enabled`, `targets.resolver.jira_enabled`; plus the owner's `digest.model:` line, which is not a key at all (no struct field — viper drops it). **≈35 HIDDEN KNOBS** (read, but no CLI allowlist/Settings/migration writer): all `catchup.*`, `dashboard.*`, `gmail.*`/`imap.*` tuning, `inbox.initial_lookback_days`/`max_triage_messages`, `ideas.max_*`, `streams.interval_hours`, `reaction_commands.interval_hours`, `feed.meeting_lead_minutes`, `jira.sync_interval_mins`, `calendar.history_days`, `targets.*` tuning, `transcripts.recordings_dir`, `memory.retrieve.*`, `memory.focus.enabled`. **1 MISMATCH**: `feed.enabled` (registry key, `config set` allowlisted, daemon ignores it — `internal/daemon/daemon.go:1069–1077`).

### 3.B Registry ↔ daemon phase (Appendix B). All 13 gated phases check their flag **first** (before nil/throttle/lock) — FEAT-01 holds on the daemon. Registry `ConfigKey` equals the key each phase reads for every non-core feature. Fast-forward hooks exist for inbox/digests/streams/ideas/memory only (tracks/people/briefing/day-plan/next-step/reaction-commands: none — documented).

### 3.C Swift persistent keys (Appendix C, from `_desktop-shell-gates-partA-swift.md`). Findings: `notifyDailySummary` DEAD; `transcription.boundarySnapSec` HIDDEN (no Settings control despite CLAUDE.md implying one); `transcription.diarizationThreshold`/`windowSec` Settings fields accept out-of-range values the runtime silently discards (`TranscriptionEngine.swift:99–106,122–125`); `feed.filter.*` persist for an unreachable screen; `ml.keepEnginesWarm` undocumented. All CLAUDE.md-stated defaults (provider whisperkit, contextPrompt OFF, micAGC OFF, liveTranscription ON, preload absent=ON, diarization ON, threshold 0.6/0.3–0.9) verified.

### 3.D Effective state — owner's install

| Feature / phase | Effective | Why |
|---|---|---|
| AI models | claude, light=`sonnet`, strong=`opus` | `ai.models.*`; `digest.model` line is inert |
| Slack sync | ON, 15 min | `sync.poll_interval` |
| Slack digests + daily/weekly rollups | ON | `digest.enabled: true` |
| Assistant Inbox (detectors, triage, auto-resolve, unsnooze) | ON | `inbox.enabled` default true |
| **Situations compose + cards** | **OFF (DARK)** | `inbox.situations.enabled` default false — Dashboard also unreachable |
| Stream digests (Gmail/Jira) + Jira comment sync | ON, 6 h | `streams.enabled` default true |
| Ideas consolidator | ON, 6 h | `ideas.enabled: true` |
| Tracks + custom-track scan | ON | `tracks.enabled` default true ∧ digest on |
| People cards | ON, 24 h throttle | `people.enabled` default true ∧ digest on |
| **Reaction commands** | **OFF (DARK)** | `reaction_commands.enabled` default false |
| Memory core + semantic tier | ON | explicit true |
| Memory surfaces briefing/chat/disputes/reflection | ON | explicit true |
| Memory surfaces day_plan / meeting_prep | OFF | default false |
| **Memory sources gmail/actions/calendar/chats/operational/jira** | **all OFF** | vault fed by Slack only |
| Memory renders/retrieve compare, focus, semantic.preferences | OFF | defaults (instruments) |
| Daily briefing | ON after 08:00 | default |
| Day plan (+conflicts) | ON after 08:00 | `day_plan.enabled: true` |
| Next-step | ON | default true |
| Targets extract | ON | default true |
| Feed publish | ON | ungated |
| Calendar / Gmail sync | ON per `google_accounts` flags | explicit true |
| Jira sync | ON, 15 min | `jira.enabled: true` |
| **Every `jira.features.*` surface** (briefing My Issues/Awaiting input/Iteration progress, CLI dashboards, without-Jira detection, track-linking badges) | **OFF** | all 11 false, never seeded (H-4); Desktop dashboards unaffected |
| Transcript audio retention | 30 d | explicit |
| Catch-Up | on demand | no gate key |
| Feature-gate migration | done | `features.migrated: 1` |

## 4. Findings

### Critical
None.

### High
**H-1 — Assistant profile brief, style profile and learned-rules management lost their only UI (collateral of Wave 2).** `WD/Views/Inbox/InboxFeedView.swift:255–275` hosts the "Learned" (`InboxLearnedRulesView`) and "Profile" (`SecretaryProfileView`) tabs; `InboxFeedView` is instantiated by nothing after `Navigation.swift:203–204` switched `.inbox` to `ActionStripView`. Intended: CLAUDE.md Inbox section — brief "edited from the Desktop 'Profile' tab", rules "management" tab; Wave 2 spec §4.2 only says the *situations Dashboard* is kept-in-code, silent on these two. Actual: `workspace.secretary_profile` (injected into triage/compose/card prompts via `buildSecretaryBrief`) and `style_profile` (Discuss drafting voice) can no longer be created or edited; `inbox_learned_rules` cannot be viewed/removed. Scenario: owner writes a wrong brief once, or an implicit rule mutes a source they care about → triage keeps applying it and there is no screen to fix it. Not a numbered contract, but degrades INBOX learning contracts operationally. **Needs owner decision**: re-home both under Settings → Profile (where `SkillsSettingsSection` already lives) or accept loss until the demolition spec.

**H-2 — Daemon log growth ≈150 MB/day, written twice, cap honoured only at open.** `cmd/sync.go:117–123` documents "~MBs/day"; live install shows `daemon.log` 238 MB (since Sep 11 20:52) + `.1` 324 MB, and an identical `watchtower.log`/`.1` pair (`cmd/sync.go:193` and `:293` open two files; detached stderr → `daemon.log`, logger → `watchtower.log`). A 3 MB tail sample is dominated by `slack API: reactions.get channel=… ts=…` lines (one per pending item per cycle) — the known "sync stuck on reactions phase" pattern. Scenario: at this rate a two-week uptime writes ~4 GB before any rotation; the 20 MiB `maxLogSize` is a dead letter for a tray-launched daemon that is only restarted on app launch. Fix belongs half to the reactions phase (rate of `reactions.get`) and half to rotation (size check per cycle, the deferred "per-cycle size check" follow-up from PR #105), and the duplicate file should go.

**H-3 — `DaemonManager.restart()` cannot fail, so a feature toggle can silently not reach the daemon.** `WD/WatchtowerCore/Services/DaemonManager.swift:112–124` discards both exit statuses (`_ =`) and returns Void; `FeatureManagerService.apply` (`WD/Services/FeatureManagerService.swift:240–242`) treats it as success. `runSyncStop` gives the daemon 10 s (`cmd/sync.go:163–175`) and returns an error after; `runSyncDetach` then exits ≠0 with "daemon already running" (`cmd/sync.go:184`). Scenario: owner disables Slack Digests while the daemon is mid-phase and slow to honour SIGTERM → config file says off, UI says applied, old daemon keeps running the old in-memory config until the next app launch; FEAT-01's promise ("stop now") is not met and nothing tells the owner. Also affects `reconnectAndRestartDaemon` (`Navigation.swift:164–178`).

**H-4 — `jira.features.*` are never seeded, so every Jira surface behind them is silently off.** `internal/config/config.go:484–485` sets defaults only for `jira.enabled`/`sync_interval_mins`; `DefaultJiraFeatures(role)` is applied only by `jira features reset` (`cmd/jira.go:1305–1310`); `jira login`/`add` writes `jira.enabled=true` (`cmd/jira.go:478`) and nothing else. Nine of the eleven flags gate real code (`internal/jira/context.go:164–171` → `internal/briefing/jira.go:31,38,45`, `cmd/jira_dashboards.go`, `internal/jira/without_jira.go:45`). Scenario: exactly the owner's install — Jira syncs every 15 min, comments feed Ideas/Inbox, but the daily briefing never shows My Issues / Awaiting my input / Iteration progress and the CLI dashboards refuse, unless the owner discovers `JiraFeaturesSettingsView`. Desktop dashboards read GRDB directly and ignore the flags (`WD/ViewModels/WorkloadViewModel.swift:130–137`), so the two halves of the product disagree about whether the feature is on. `who_ping` and `write_back_suggestions` have no consumer at all (dead toggles shown in Settings).

### Medium
**M-1 — FEAT-01 hole on the one-shot `watchtower sync` path.** `cmd/sync.go:896–944` gates on `digest.enabled` only and runs Tracks via `TrackLinker` (`:909–910`; `internal/tracks/pipeline.go:209` self-gates only on digest) and People cards (`:931`; `internal/guide/pipeline.go:140–147` has no `People.Enabled` gate). Documented as a known deferral in `docs/inventory/features.md` FEAT-01 Scope note, but the Desktop "Sync now"/onboarding sync still reaches it → AI spend for a feature the owner turned off. Contract-adjacent; **needs owner decision** whether the deferral stands.

**M-2 — 15 dead config knobs, three of them editable in Settings.** `day_plan.max_timeblocks/min_backlog/max_backlog` are written by `WD/Services/ConfigService.swift:238–240` (Settings → Features → Day plan) and read by nothing in `internal/dayplan`. Others listed in §3.A. Scenario: owner sets max_backlog=3 expecting fewer backlog items; nothing changes.

**M-3 — "Daily summary notifications" toggle is dead; "Quiet hours" has no hours.** `WD/Views/Settings/NotificationSettings.swift:6,34,58–59` vs `WD/Services/DigestWatcher.swift:76–78,100–110` (briefing pushes fire whenever `quietHoursEnabled` is false, regardless of the toggle; quiet hours = permanent mute while on).

**M-4 — Login item registered silently per bundle path.** `WD/App/TrayAppDelegate.swift:253–272`: first launch of any bundle path calls `SMAppService.mainApp.register()` with no consent UI and no Settings toggle; a worktree build launched once re-points autostart to the dev bundle (LS-duplicate class). Only System Settings → Login Items or the Data reset (`DataSettings.swift:251–256`) undoes it.

**M-5 — `feed.enabled` is a registry key nothing in the daemon reads.** `internal/features/registry.go:106–109` declares it; `internal/daemon/daemon.go:1069–1077` deliberately ignores it; only CLI `inbox generate` honours it (`cmd/inbox.go:514,537`). `config set feed.enabled false` looks like it turns the feed off and does not.

**M-6 — `knownConfigKeys` allowlist lags the registry.** `cmd/config.go:206–274` lacks `inbox.situations.enabled` (the very key `FeatureManagerService.applyOne` writes via `config set`, `FeatureManagerService.swift:261`), `reaction_commands.*`, `ai.workers`, `codex_path`, `memory.retrieve.*`, `dashboard.*`, `catchup.*`, `day_plan.hour/working_hours_*`, `calendar.*`, `jira.sync_interval_mins`, `targets.*` → every Desktop sub-toggle apply emits an "unknown key" stderr warning while still writing. Cosmetic today, but the allowlist can no longer be trusted as documentation.

### Low
**L-1 — Doc drift: CLAUDE.md says the store verdict is "cached per launch"; `CLIBinaryStore.resolvedInstalledPath()` deliberately has no cache (`CLIBinaryStore.swift:52–60,77–80`).**
**L-2 — Per-spawn cost of `findCLIPath()`:** two full SHA-256 passes over 34 MB (`CLIBinaryStore.swift:47–48,200–203`) plus `SecStaticCodeCheckValidity` on every CLI spawn (~50 call sites, incl. the 10 s daemon status poll path via `resolvePathIfNeeded` only once — but each `ProcessCLIRunner.makeDefault()`/`DaemonManager.restart` call re-hashes).
**L-3 — Dead observers at launch:** `AppState.initDashboard` (`AppState.swift:665–672`) builds and `startObserving()`s `DashboardViewModel` + `FeedViewModel` (GRDB ValueObservations over `situations`/feed tables) for the unreachable Dashboard; `feed.filter.*` defaults loaded for it (`FeedViewModel.swift:52–58`).
**L-4 — Dead view files:** `WD/Views/Home/*` (4 files), `WD/Views/Targets/ExtractNoticeBanner.swift`, `WD/Views/Inbox/InboxFeedbackSheet.swift`, `WD/Views/Dashboard/*` (7 files, kept by spec), `InboxFeedView.swift`, `InboxCardView.swift`.
**L-5 — Default drift Go↔Swift:** `calendar.sync_days_ahead` Go 7 (`internal/config/defaults.go:70`) vs Swift fallback 2 (`ConfigService.swift:124`); `memory.sources.jira` has no `SetDefault` (harmless).
**L-6 — `phaseMemory` is the only gate that logs on every skipped cycle** (`daemon.go:1040`), log noise when memory is off.
**L-7 — `config set`/`features enable|disable` rewrite the whole yaml through viper `WriteConfigAs`** (`cmd/features.go:379–398` → `cmd/config.go:354`): lowercases keys, drops comments/order; `feature_migrate.go:121–134` already moved to node-patching for the same reason.
**L-8 — Settings numeric fields (`transcription.windowSec`, `diarizationThreshold`) store out-of-range values that `TranscriptionConfig.fromDefaults` silently replaces** (`TranscriptionEngine.swift:99–106,122–125`); UI shows the typed value.
**L-9 — `transcription.boundarySnapSec` has no UI** (`TranscriptionEngine.swift:36,103–106`; CLAUDE.md implies a setting).

## 5. Needs owner decision
1. **H-1** — where the assistant brief / style profile / learned-rules editors live now (Settings → Profile?) or accept loss until the situations demolition spec.
2. **M-1** — keep or lift the FEAT-01 CLI-sync deferral (Tracks/People run with features off on `watchtower sync`).
3. **H-4** — seed `DefaultJiraFeatures(role)` on `jira login/add` (or add viper defaults) vs keep opt-in; and delete the two consumer-less toggles.
4. **M-5** — drop `feed.enabled` from the registry/allowlist or make `phaseFeed` read it.
5. **H-2** — per-cycle log-size check + single log file: acceptable to change the "rotate at open only" design note?
6. **M-4** — should login-item registration ask, or at least have a Settings toggle?

## 6. What I could not verify
- Auto-update network paths (GitHub release fetch, gated manifest) — no network calls made; only code traced.
- Whether `sync --daemon --detach` actually exits ≠0 in the timed-out-stop race (traced from `cmd/sync.go:184`, not reproduced).
- The Swift key matrix (Appendix C) came from a sub-auditor cut off before its navigation section; I built §2 myself from `Navigation.swift`/`SidebarDestination.swift` and a reference grep of every `struct *View` — a view constructed only through generics or `.init` would not be caught (none found among the suspects checked).
- Go reader/writer counts in Appendix A are grep-derived by a sub-auditor; I spot-checked the daemon gates, `restart()`, log rotation, `runPostSyncPipelines`, `jira.features` seeding and `feed.enabled`, not every row.
- Onboarding "no-Slack Continue" was verified by code (`OnboardingChatViewModel.swift:561–572`), not by running the flow.

---

# Appendix A/B — Go config key matrix, registry↔phase table, ungated phases



Writer legend: **CS** = `cmd/config.go` `config set` (allowlisted in `knownConfigKeys` L206–274; unknown keys still write, with a stderr warning L282–284); **FEAT** = `cmd/features.go` `enable/disable` → `setConfigKey` L379; **FM** = `internal/config/feature_migrate.go` `MigrateFeatureGates`; **SWIFT** = `ConfigService.save()` L180–263; **FMS** = Desktop `FeatureManagerService.applyOne` L259–268; **INIT** = `config init` seeds (`cmd/config.go` L166–179); **ONB** = Desktop onboarding `config set` (`OnboardingView.swift` L1264–1274).

## Appendix A · Config key matrix

| key | Go field | default | readers (prod, non-test) | writers | verdict |
|---|---|---|---|---|---|
| `active_workspace` | `cfg.ActiveWorkspace` | `""` | 98 (cmd/root.go:113, cmd/watch.go:104, …) | INIT L167; cmd/auth.go:281; SWIFT L190 | OK |
| `workspaces.<t>.slack_token` | `cfg.Workspaces[t].SlackToken` | none | 4 (cmd/slack_legacy.go:108, cmd/sync.go:252, cmd/config.go:337) | INIT L168; env `WATCHTOWER_SLACK_TOKEN` (config.go:577); `ensureLegacySlackAccount` blanks it | OK (legacy; token now in `slack_token_<id>.json`) |
| `ai.provider` | `cfg.AI.Provider` | `"claude"` | 18 (cmd/generator.go:28–29, …) | CS; SWIFT L171 | OK |
| `ai.model` (legacy) | `cfg.AI.Model` | `""` | 2 (internal/providers/registry.go:105 — ignored if `== "claude-sonnet-4-6"`; cmd/config.go:324 show) | CS; SWIFT L169; env `WATCHTOWER_AI_MODEL` | OK (legacy fallback for strong only) |
| `ai.models.light` | `cfg.AI.Models.Light` | `""` → provider default | 2 (providers/registry.go:115; cmd/config.go:325) | CS; SWIFT L174 | OK |
| `ai.models.strong` | `cfg.AI.Models.Strong` | `""` | 2 (providers/registry.go:103; cmd/config.go:326) | CS; SWIFT L175; ONB L1270 | OK |
| `ai.ollama_url` | `cfg.AI.OllamaURL` | `http://localhost:11434` | 4 (cmd/generator.go:33,76; cmd/ai.go:234) | CS; SWIFT L172 | OK |
| `ai.context_budget` | `cfg.AI.ContextBudget` | 150000 | 2 (internal/tracks/pipeline.go:558; cmd/config.go:328) | CS; INIT L172 | OK |
| `ai.workers` | `cfg.AI.Workers` | 5 | 3 (cmd/generator.go:44; internal/digest/pipeline.go:489; cmd/people.go:348) | SWIFT L170; env; NOT in CS allowlist (warns) | OK |
| `sync.workers` | `cfg.Sync.Workers` | 1 | 3 (internal/sync/orchestrator.go:74; internal/repl/commands.go:143) | CS; INIT; SWIFT L195; env | OK |
| `sync.initial_history_days` | `cfg.Sync.InitialHistoryDays` | 2 | 6 (internal/sync/search_sync.go:36, message_sync.go:384, cmd/sync.go:335) | CS; INIT; SWIFT L197; ONB | OK |
| `sync.poll_interval` | `cfg.Sync.PollInterval` | 15m | 2 (internal/daemon/daemon.go:263; cmd/config.go:331) | CS; INIT; SWIFT L194; ONB | OK |
| `sync.sync_threads` | `cfg.Sync.SyncThreads` | true | 2 (internal/sync/message_sync.go:317) | CS; INIT; SWIFT L196 | OK |
| `sync.sync_on_wake` | `cfg.Sync.SyncOnWake` | true | 2 (internal/daemon/daemon.go:268) | CS; INIT | OK |
| `digest.enabled` | `cfg.Digest.Enabled` | true | 17 (daemon.go:609,752,783,797,1118; cmd/sync.go:897; internal/tracks/pipeline.go:209; internal/catchup/pipeline.go:209) | FEAT (`slack-digests`); FM (signature); CS; INIT; SWIFT deliberately does NOT write it (L200) | OK |
| `digest.min_messages` | `cfg.Digest.MinMessages` | 10 | 3 (internal/digest/pipeline.go:595,648) | CS; INIT; SWIFT L203 | OK |
| `digest.language` | `cfg.Digest.Language` | `"Russian"` | 39 (catchup/pipeline.go:128, repl/commands.go:234, …) | CS; SWIFT L204; ONB | OK |
| `digest.workers` | `cfg.Digest.Workers` | 5 | **0 outside Load**; only config.go:572 (back-compat → `ai.workers` when `ai.workers` unset) | CS | **DEPRECATED SHIM** |
| `digest.action_items_interval` (alias `digest.tracks_interval`) | `cfg.Digest.TracksInterval` | 1h | **0** | CS (both spellings allowlisted L223–224) | **DEAD KNOB** |
| `digest.batch_max_channels` | `cfg.Digest.BatchMaxChannels` | 20 | 1 (internal/digest/pipeline.go:678) | none | HIDDEN KNOB |
| `digest.batch_max_messages` | `cfg.Digest.BatchMaxMessages` | 1500 | 1 (internal/digest/pipeline.go:682) | none | HIDDEN KNOB |
| `digest.model` (in owner yaml) | **no field** | — | **0** — viper ignores unknown keys | hand-edit only | **DEAD LINE** (not a knob at all; `claude-sonnet-4-6` there does nothing) |
| `briefing.enabled` | `cfg.Briefing.Enabled` | true | 5 (daemon.go:1137; internal/briefing/pipeline.go:118; cmd/briefing.go:117 forces true) | FEAT (`briefing`); FM; CS | OK |
| `briefing.hour` | `cfg.Briefing.Hour` | 8 | 1 (daemon.go:1294) | CS; SWIFT L209 | OK |
| `inbox.enabled` | `cfg.Inbox.Enabled` | true | 6 (daemon.go:594,828; internal/inbox/pipeline.go:377,492) | FEAT (`secretary-inbox`); FM; CS | OK |
| `inbox.max_items_per_run` | `cfg.Inbox.MaxItemsPerRun` | 100 | **0** | none | **DEAD KNOB** |
| `inbox.initial_lookback_days` | `cfg.Inbox.InitialLookbackDays` | 7 | 4 (internal/inbox/pipeline.go:231–232; compose.go:77–78) | none | HIDDEN KNOB |
| `inbox.max_triage_messages` | `cfg.Inbox.MaxTriageMessages` | 600 | 1 (internal/inbox/triage.go:63) | none | HIDDEN KNOB |
| `inbox.max_awareness_cards` | `cfg.Inbox.MaxAwarenessCards` | 3 | **0** (per-item card stage retired, migration 00012) | none | **DEAD KNOB** |
| `inbox.situations.enabled` | `cfg.Inbox.Situations.Enabled` | **false** | 2 (internal/inbox/pipeline.go:288; situation_card.go:35) | FMS via `config set` (registry SubToggle registry.go:125–129) — **not in CS allowlist → stderr warning on every Desktop toggle**, still writes | OK (allowlist gap) |
| `ideas.enabled` | `cfg.Ideas.Enabled` | true | 11 (daemon.go:881; cmd/ideas.go:156,159; registry.go:210) | FEAT (`ideas`); FM; CS; SWIFT reads only (L144, deliberately not written L226) | OK |
| `ideas.mine_interval_hours` | `cfg.Ideas.MineIntervalHours` | 6 | 2 (daemon.go:887–888) | CS; SWIFT L229 | OK |
| `ideas.max_comment_issues_per_sync` | `cfg.Ideas.MaxCommentIssuesPerSync` | 50 | 1 (cmd/sync.go:654) | none | HIDDEN KNOB |
| `ideas.max_prompt_chars` | `cfg.Ideas.MaxPromptChars` | 60000 | 2 (internal/ideas/consolidate.go:186–187) | none | HIDDEN KNOB |
| `streams.enabled` | `cfg.Streams.Enabled` | true | 10 (daemon.go:952; cmd/sync.go:602 `jiraCommentSyncEnabled`; catchup/pipeline.go:212; cmd/ideas.go:159) | FEAT (`stream-digests`); FM; CS | OK |
| `streams.interval_hours` | `cfg.Streams.IntervalHours` | 6 | 2 (daemon.go:958–959) | CS | OK |
| `reaction_commands.enabled` | `cfg.ReactionCommands.Enabled` | **false** | 2 (daemon.go:1005; registry.go:225) | FEAT (`reaction-commands`) only; **not in CS allowlist, not in FM legacy list** | OK |
| `reaction_commands.interval_hours` | `cfg.ReactionCommands.IntervalHours` | 6 | 2 (daemon.go:1011–1012) | none | HIDDEN KNOB |
| `feed.enabled` | `cfg.Feed.Enabled` | true | 4, but **daemon deliberately ignores it** (daemon.go:1069–1077); only CLI `inbox generate` honors it (cmd/inbox.go:514,537); registry.go:109 | CS (allowlisted L268); FEAT refuses (Core) | **MISMATCH** |
| `feed.meeting_lead_minutes` | `cfg.Feed.MeetingLeadMinutes` | 30 | 1 (internal/feed/publish.go:41) | none | HIDDEN KNOB |
| `dashboard.stale_after_days` | `cfg.Dashboard.StaleAfterDays` | 7 | 2 (internal/inbox/pipeline.go:328–329) | none | HIDDEN KNOB |
| `dashboard.max_compose_signals` | `cfg.Dashboard.MaxComposeSignals` | 200 | 1 (internal/inbox/compose.go:84) | none | HIDDEN KNOB |
| `catchup.caps.{digests,streams,meetings,decisions,inbox,tracks,targets}` | `cfg.Catchup.Caps.*` | 150/40/20/40/120/80/40 | 1 each (internal/catchup/pipeline.go:226–240) | none | HIDDEN KNOB ×7 |
| `catchup.max_prompt_chars` | `cfg.Catchup.MaxPromptChars` | 120000 | 1 (internal/catchup/pipeline.go:127) | none | HIDDEN KNOB |
| `tracks.enabled` | `cfg.Tracks.Enabled` | true | 4 (daemon.go:752,1118; registry.go:179; feature_migrate.go:112) — **NOT read by `internal/tracks` Run itself** (pipeline.go:209 gates on Digest only) | FEAT (`tracks`); FM; CS | OK in daemon; CLI bypass (E.4) |
| `tracks.min_messages` | `cfg.Tracks.MinMessages` | 3 | **0** | none | **DEAD KNOB** |
| `people.enabled` | `cfg.People.Enabled` | true | 3 (daemon.go:797; registry.go:195; feature_migrate.go:113) — `internal/guide` Run has no self-gate (guide/pipeline.go:140–147) | FEAT (`people-cards`); FM; CS | OK in daemon; CLI bypass (E.4) |
| `calendar.enabled` | `cfg.Calendar.Enabled` | false | 1 real (cmd/sync.go:704 wiring) | CS; SWIFT L217 (+ `GoogleConnectFlow.swift:179`) | OK |
| `calendar.selected_calendars` | `cfg.Calendar.SelectedCalendars` | none | 1 (internal/calendar/sync.go:98, legacy path) | none | HIDDEN (legacy) |
| `calendar.sync_days_ahead` | `cfg.Calendar.SyncDaysAhead` | 7 (Swift fallback shows 2 — ConfigService.swift:124) | 4 (internal/calendar/sync.go:49; caldav/sync.go:60; cmd/calendar.go:107) | SWIFT L218 | OK (default drift Go 7 vs Swift 2) |
| `calendar.history_days` | `cfg.Calendar.HistoryDays` via `EffectiveHistoryDays()` | 14 | 2 (calendar/sync.go:47; caldav/sync.go:58) | Swift reads L125, does not write | HIDDEN KNOB |
| `gmail.enabled` | `cfg.Gmail.Enabled` | false | 1 real (cmd/sync.go:712) | CS; SWIFT L223 | OK |
| `gmail.initial_history_days` / `max_messages_per_sync` / `max_body_bytes` | `cfg.Gmail.*` | 7 / 100 / 51200 | 1 each (internal/gmail/sync.go:42,46,50) | none | HIDDEN KNOB ×3 |
| `imap.initial_history_days` / `max_messages_per_sync` / `max_body_bytes` | `cfg.Imap.*` | 7 / 100 / 51200 | 1 each (internal/imap/sync.go:48,52,56) | none | HIDDEN KNOB ×3 |
| `jira.enabled` | `cfg.Jira.Enabled` | false | 11 (cmd/sync.go:612; internal/jira/context.go:165; briefing/jira.go:17; meeting/jira.go:33; cmd/trends.go:166) | cmd/jira.go:478 `enableJiraPhase` (login/add); CS | OK |
| `jira.cloud_id` / `site_url` / `user_display_name` | `cfg.Jira.*` | none | only `cmd/jira_legacy.go:51–63` (one-shot seed of account #1) | none (frozen) | OK (frozen legacy) |
| `jira.selected_boards` | `cfg.Jira.SelectedBoards` | none | **0** (boards come from `jira_boards.is_selected`, internal/db/jira.go:106) | none | **DEAD KNOB** |
| `jira.sync_interval_mins` | `cfg.Jira.SyncIntervalMins` | 15 | 1 (daemon.go:521) | none | HIDDEN KNOB |
| `jira.user_map` | `cfg.Jira.UserMap` | none | 2 (cmd/jira.go:982,1097) | none | HIDDEN KNOB |
| `jira.features.my_issues_in_briefing` | `.Features.MyIssuesInBriefing` | **no SetDefault → false** | via `jira.IsFeatureEnabled(cfg,"my_issues")`: internal/briefing/jira.go:31, internal/guide/jira.go:28 | `jira features set/reset` (cmd/jira.go:1268,1310); Desktop `JiraFeaturesSettingsView.swift:253,304` | OK |
| `jira.features.awaiting_my_input` | `.AwaitingMyInput` | false | briefing/jira.go:38 | same | OK |
| `jira.features.who_ping` | `.WhoPing` | false | **0 consumers** (only `FeatureValue` switch features.go:38 + CLI display) | same | **DEAD KNOB** |
| `jira.features.track_jira_linking` | `.TrackJiraLinking` | false | cmd/tracks.go:187,508; cmd/digest.go:200,249 (CLI render only) | same | OK (CLI-only) |
| `jira.features.team_workload` | `.TeamWorkload` | false | internal/jira/workload.go:68; cmd/jira_dashboards.go:52 | same | OK |
| `jira.features.blocker_map` | `.BlockerMap` | false | internal/jira/blockers.go:53; cmd/jira_dashboards.go:138 | same | OK |
| `jira.features.iteration_progress` | `.IterationProgress` | false | briefing/jira.go:45 | same | OK |
| `jira.features.epic_progress` | `.EpicProgress` | false | jira/epic_progress.go:40; project_map.go:60,166; cmd/jira_dashboards.go:249 | same | OK |
| `jira.features.write_back_suggestions` | `.WriteBackSuggestions` | false | **0 consumers** (features.go:50 switch + CLI) | same | **DEAD KNOB** |
| `jira.features.release_dashboard` | `.ReleaseDashboard` | false | jira/release_dashboard.go:54,131; cmd/jira_dashboards.go:410 | same | OK |
| `jira.features.without_jira_detection` | `.WithoutJiraDetection` | false | jira/without_jira.go:45; cmd/digest.go:201,250 | same | OK |
| `analysis.legacy_mode` | `cfg.Analysis.LegacyMode` | false (no SetDefault) | **0** (Swift reads it at ConfigService.swift:101, never writes) | none | **DEAD KNOB** |
| `day_plan.enabled` | `cfg.DayPlan.Enabled` | true | 6 (daemon.go:1339,1367,1405; dayplan/pipeline.go:50; cmd/day_plan.go:288 forces true) | FEAT (`day-plan`); FM; CS; SWIFT reads L149 not written | OK |
| `day_plan.hour` | `cfg.DayPlan.Hour` | 8 | 1 (daemon.go:1342) | SWIFT L235 | OK |
| `day_plan.working_hours_start/end` | `cfg.DayPlan.WorkingHours*` | 09:00 / 19:00 | 1 each (dayplan/pipeline.go:101–102) | SWIFT L236–237 | OK |
| `day_plan.max_timeblocks` / `min_backlog` / `max_backlog` | `cfg.DayPlan.*` | 3 / 3 / 8 | **0** | SWIFT L238–240 writes them | **DEAD KNOB ×3** (Settings UI edits a value nothing reads) |
| `memory.enabled` | `cfg.Memory.Enabled` | false | 9 (daemon.go:1039; cmd/mcp.go:94; cmd/memory.go:166,387) | FEAT (`memory`); FM; CS | OK |
| `memory.max_chunk_messages` | `.MaxChunkMessages` | 2000 | 6 (memory/pipeline.go:754; gmail_extract.go:238; cmd/memory.go:227) | CS | OK |
| `memory.seed_min_messages` | `.SeedMinMessages` | 20 | 3 (memory/pipeline.go:325; cmd/memory.go:532,541) | CS | OK |
| `memory.max_episodes_per_window` | `.MaxEpisodesPerWindow` | 5 | 3 (memory/pipeline.go:1052,1115,1122) | CS | OK |
| `memory.max_window_messages` | `.MaxWindowMessages` | 200 | 2 (memory/pipeline.go:765; gmail_extract.go:245) | CS | OK |
| `memory.batch_max_channels` / `batch_max_messages` | `.BatchMax*` | 20 / 1500 | 2 each (memory/pipeline.go:772; gmail_extract.go:266) | CS | OK |
| `memory.semantic.enabled` | `.Semantic.Enabled` | false | 2 (memory/pipeline.go:255; cmd/features.go:320) | FMS sub-toggle; CS | OK |
| `memory.semantic.{rewrite_max_entities,beliefs_max,dedupe_max_merges,age_after_days,evict_after_days,evict_max,concept_min_episodes,concept_max_create,output_budget}` | `.Semantic.*` | 10/20/20/14/45/50/5/10/200000 | 1 each (memory/pipeline.go:514,535,485,570,579,579,494,494,618) | CS | OK |
| `memory.semantic.preferences` | `.Semantic.Preferences` | false | 1 (memory/beliefs.go:155) | CS | OK |
| `memory.surfaces.chat` | `.Surfaces.Chat` | false | 3 (memory/pipeline.go:458,555; cmd/features.go:334) | FMS; CS | OK |
| `memory.surfaces.briefing` | `.Surfaces.Briefing` | false | 2 (briefing/memory_revisions.go:31) | FMS; CS | OK |
| `memory.surfaces.disputes` | `.Surfaces.Disputes` | false | 2 (inbox/pipeline.go:571) | FMS; CS | OK |
| `memory.surfaces.reflection` | `.Surfaces.Reflection` | false | 2 (memory/pipeline.go:593) | FMS; CS | OK |
| `memory.surfaces.day_plan` | `.Surfaces.DayPlan` | false | 2 (dayplan/gather.go:37) | FMS; CS | OK |
| `memory.surfaces.meeting_prep` | `.Surfaces.MeetingPrep` | false | 2 (meeting/memory_context.go:44) | FMS; CS | OK |
| `memory.sources.gmail` | `.Sources.Gmail` | false | 3 (memory/pipeline.go:325,389) | FMS; CS | OK |
| `memory.sources.actions` | `.Sources.Actions` | false | 2 (memory/pipeline.go:403) | FMS; CS | OK |
| `memory.sources.calendar` | `.Sources.Calendar` | false | 3 (memory/pipeline.go:325,341) | FMS; CS | OK |
| `memory.sources.chats` | `.Sources.Chats` | false | 3 (memory/pipeline.go:171,465) | FMS; CS | OK |
| `memory.sources.operational` | `.Sources.Operational` | false | 2 (memory/pipeline.go:356) | FMS; CS | OK |
| `memory.sources.jira` | `.Sources.Jira` | **no SetDefault** (zero=false) | 2 (memory/pipeline.go:368) | FMS; CS | OK |
| `memory.renders.digest_compare` | `.Renders.DigestCompare` | false | 1 (memory/pipeline.go:270) | CS | OK (instrument) |
| `memory.retrieve.recall_compare` | `.Retrieve.RecallCompare` | false | 2 (cmd/mcp.go:96; cmd/tools.go:147) | none | HIDDEN (instrument, by design registry.go:293–296) |
| `memory.retrieve.briefing_compare` | `.Retrieve.BriefingCompare` | false | 1 (briefing/memory_revisions.go:78) | none | HIDDEN (instrument) |
| `memory.retrieve.meeting_prep_compare` | `.Retrieve.MeetingPrepCompare` | false | 1 (meeting/memory_context.go:133) | none | HIDDEN (instrument) |
| `memory.focus.enabled` | `.Focus.Enabled` | false | 1 (memory/pipeline.go:296) | none | HIDDEN (instrument) |
| `targets.extract.enabled` | `cfg.Targets.Extract.Enabled` | true | 1 (internal/targets/pipeline.go:48) | none | HIDDEN KNOB |
| `targets.extract.max_per_call` | `.Extract.MaxPerCall` | 10 | **0** | none | **DEAD KNOB** |
| `targets.extract.timeout_seconds` | `.Extract.TimeoutSeconds` | 0 | 1 (targets/pipeline.go:58) | none | HIDDEN KNOB |
| `targets.extract.model` | `.Extract.Model` | `""` | **0** | none | **DEAD KNOB** |
| `targets.resolver.slack_enabled` | `.Resolver.SlackEnabled` | true | **0** | none | **DEAD KNOB** |
| `targets.resolver.jira_enabled` | `.Resolver.JiraEnabled` | true | **0** | none | **DEAD KNOB** |
| `targets.resolver.mcp_timeout_seconds` | `.Resolver.MCPTimeoutSeconds` | 10 | 1 (cmd/targets_ai.go:76) | none | HIDDEN KNOB |
| `targets.resolver.active_snapshot_limit` | `.Resolver.ActiveSnapshotLimit` | 100 | 6 (targets/pipeline.go:80,128; nextstep.go:111) | none | HIDDEN KNOB |
| `targets.next_step.enabled` | `cfg.Targets.NextStep.Enabled` | true | 3 (daemon.go:1094; registry.go:288; feature_migrate.go:118) | FEAT (`next-step`); FM; CS | OK |
| `transcripts.audio_retention_days` | `cfg.Transcripts.AudioRetentionDays` | 30 | 1 (daemon.go:667) | CS; SWIFT L245 | OK |
| `transcripts.recordings_dir` | `cfg.Transcripts.RecordingsDir` via `RecordingsDir()` | `""` → `~/Library/Application Support/Watchtower/recordings` | 1 (daemon.go:699) | none | HIDDEN KNOB |
| `db.schema_format` | `cfg.DB.SchemaFormat` | 1 | 1 (cmd/root.go:50) | cmd/root.go:66 (one-shot bump) | OK (internal marker) |
| `claude_path` / `codex_path` | `cfg.ClaudePath` / `cfg.CodexPath` | none | 3 / 2 (cmd/generator.go:35,78,31,74; repl/repl.go:57) | CS (`claude_path` only); SWIFT L249,252 | OK |
| `features.migrated` | **no struct field** — read via `v.IsSet` (feature_migrate.go:78) | absent | 1 | FM L83 (`patchConfigYAML`); CS allowlisted L273 | OK (marker) |

## Appendix B · Registry ↔ daemon phase

| feature id | ConfigKey | Cost / FeedsInto / Core | phase fn (daemon.go) | gate expr actually checked | gate first? | FF hook (fastforward.go) | verdict |
|---|---|---|---|---|---|---|---|
| dashboard | — | none / Core | (no phase; UI) | — | — | — | OK |
| targets | — | none / Core | (no phase) | — | — | — | OK |
| chat | — | none / Core | (no phase) | — | — | — | OK |
| feed | `feed.enabled` | none / Core | `phaseFeed` L1077 | **none** — only `d.feedPipe == nil` | n/a | — | **MISMATCH** (deliberate, L1069–1076; registry `Enabled` func L109 still reports the key) |
| secretary-inbox | `inbox.enabled` | heavy / memory,briefing | `phaseFastInbox` L593; `phaseInbox` L827 | `!d.config.Inbox.Enabled` L594 / L828 | yes | yes L44 | OK. Sub-toggle `inbox.situations.enabled` gated inside pipeline (inbox/pipeline.go:288) |
| slack-digests | `digest.enabled` | heavy / inbox,tracks,people,ideas,briefing | `phaseChannelDigests` L608; rollups half of `phaseTracksAndRollups` L783 | `!d.config.Digest.Enabled` L609 / L783 | yes | yes L135 | OK |
| stream-digests | `streams.enabled` | medium / ideas,inbox | `phaseStreamDigests` L951; also gates Jira comment sync wiring (cmd/sync.go:601–602,653) | `!d.config.Streams.Enabled` L952 | yes | yes L102 | OK |
| tracks | `tracks.enabled` | heavy / briefing,memory | `phaseTracksAndRollups` L751; `phaseCustomTrackScan` L1117 | `Tracks.Enabled && Digest.Enabled` L752 / L1118 | yes | none (deliberate, L15–17) | OK |
| people-cards | `people.enabled` | medium / briefing,day-plan | `phasePeopleCards` L796 | `!People.Enabled \|\| !Digest.Enabled` L797 | yes | none | OK |
| ideas | `ideas.enabled` | medium / — | `phaseIdeas` L880 | `!d.config.Ideas.Enabled` L881 | yes | yes L69 | OK |
| reaction-commands | `reaction_commands.enabled` | medium / — | `phaseReactionCommands` L1004 | `!ReactionCommands.Enabled` L1005 | yes | none | OK |
| memory | `memory.enabled` | medium / briefing,day-plan | `phaseMemory` L1038 | `!d.config.Memory.Enabled` L1039 | yes (logs every cycle L1040) | yes L150 | OK |
| briefing | `briefing.enabled` | light / day-plan | `phaseBriefing` L1136 | `!Briefing.Enabled` L1137 | yes | none | OK |
| day-plan | `day_plan.enabled` | light / — | `runDayPlanPhase` L1366; `runDayPlanConflictPhase` L1404 | `!DayPlan.Enabled` L1367 / L1405 | yes | none | OK |
| next-step | `targets.next_step.enabled` | medium / — | `phaseNextStep` L1093 | `!Targets.NextStep.Enabled` L1094 | yes | none | OK |

## Appendix B2 · Ungated daemon phases (`runSync` L311–369)

| phase | line | gating |
|---|---|---|
| `phaseSlackSync` | 412 | `len(d.orchestrators)==0` only; accounts from `slack_accounts.enabled` |
| `phaseCalendarSync` / `phaseCalDAVSync` / `phaseGmailSync` / `phaseImapSync` | 439/454/470/485 | syncer list emptiness decided at wiring (`cfg.Calendar.Enabled`, `cfg.Gmail.Enabled` cmd/sync.go:704,712) |
| `phaseJiraSync` | 517 | `len(d.jiraSyncers)==0` (wiring gated `cfg.Jira.Enabled` cmd/sync.go:612) then `jira.sync_interval_mins` throttle L521–527 |
| `phaseUnsnooze` | 638 | `d.db == nil` only |
| `phaseTranscriptAudioCleanup` | 663 | `d.db == nil`, then `audio_retention_days <= 0` L668 |
| `autoMarkRead` | 1201 | `d.db == nil` |
| `phaseFeed` | 1077 | none (see B) |

`cmd/sync.go` `runPostSyncPipelines` L896: gated **only** on `cfg.Digest.Enabled` L897; runs `digest.Pipeline.Run` with `TrackLinker = tracks.New(...)` L909–910 (tracks `Run` self-gates only on Digest, tracks/pipeline.go:209) and `guide.New(...).Run` L931 (no `People.Enabled` gate, guide/pipeline.go:140–147).

## Appendix B3 · Effective state for the owner's install

| feature / phase | effective | why |
|---|---|---|
| AI models | light=`sonnet`, strong=`opus` (provider claude) | `ai.models.*` set; `digest.model` ignored (no field) |
| Slack sync | ON, every 15m | `sync.poll_interval: 15m`; accounts from DB |
| Slack Digests + rollups | ON | `digest.enabled: true` |
| Assistant Inbox (fast + full: detectors, triage, auto-resolve, unsnooze) | ON | `inbox.enabled` default true |
| Situations compose + situation cards | **OFF** | `inbox.situations.enabled` default false |
| Stream Digests (Gmail/Jira) + Jira comment sync | ON (6h) | `streams.enabled` default true |
| Ideas consolidator | ON (6h) | `ideas.enabled: true` |
| Tracks + custom-track scan | ON | `tracks.enabled` default true AND digest on |
| People Cards | ON (24h throttle) | `people.enabled` default true AND digest on |
| Reaction Commands | **OFF** | default false |
| Memory core | ON | `memory.enabled: true` |
| Memory semantic tier | ON | `memory.semantic.enabled: true` |
| Memory surfaces briefing / chat / disputes / reflection | ON | set true |
| Memory surfaces day_plan / meeting_prep | OFF | default false |
| Memory sources gmail / actions / calendar / chats / operational / jira | **all OFF** | vault fed by Slack only |
| Memory renders.digest_compare, retrieve.*, focus, semantic.preferences | OFF | defaults |
| Daily Briefing | ON, after 08:00 | default true, hour 8 |
| Day Plan (generate + conflicts) | ON, after 08:00 | `day_plan.enabled: true` |
| Next-Step suggestions | ON | default true |
| Targets extract (on-demand) | ON | default true |
| Feed publish | ON | ungated |
| Calendar / Gmail sync | ON per `google_accounts` row flags | `calendar.enabled`/`gmail.enabled: true` |
| Jira sync | ON, 15-min interval | `jira.enabled: true` |
| **Every Jira feature surface** | **OFF** | `jira.features.*` all false; `IsFeatureEnabled` (jira/context.go:164–171) |
| Transcript audio retention | ON, 30 days | explicit 30 |
| Catch-Up | on-demand only | no gate key |
| Feature-gate migration | done | `features.migrated: 1` |

## Appendix B4 · Go-side findings (raw)
1. 15 dead knobs (see A). `day_plan.max_timeblocks/min_backlog/max_backlog` written by Settings UI (`ConfigService.swift:238–240`), read by nothing.
2. `jira.features.*` are live (9/11) but NO viper SetDefault (config.go L484–485 sets only `jira.enabled`/`sync_interval_mins`); only `jira features reset` (cmd/jira.go:1305–1310) applies `DefaultJiraFeatures(role)`; `jira login`/`add` writes `jira.enabled=true` (cmd/jira.go:478) but never seeds them → owner's all-false state.
3. `feed.enabled` mismatch: registry.go:106–109 declares, daemon.go:1069–1077 ignores; only cmd/inbox.go:514,537 reads.
4. FEAT-01 hole on CLI sync path: cmd/sync.go:896–944.
5. All 13 gated daemon phases put the gate first.
6. `setConfigKey` cmd/features.go:379–398 → `writeConfigAtomic` cmd/config.go:354 rewrites whole yaml via viper `WriteConfigAs` (lowercases, drops comments); feature_migrate.go:121–134 uses node-patching instead.
7. `MigrateFeatureGates` feature_migrate.go:65–94: called cmd/sync.go:465 (daemon start), cmd/features.go:44, cmd/config.go:43.
8. `knownConfigKeys` allowlist gaps cmd/config.go:206–274: `inbox.situations.enabled` (FeatureManagerService.swift:261 writes via `config set` → stderr warning), `reaction_commands.*`, `ai.workers`, etc.
9. Default OFF: `reaction_commands.enabled` (defaults.go:50), `inbox.situations.enabled` (defaults.go:35), `memory.*` (config.go:493–526), `calendar/gmail/jira.enabled` (defaults.go:69,74,85).
10. Default drift: `calendar.sync_days_ahead` Go 7 (defaults.go:70) vs Swift fallback 2 (ConfigService.swift:124).

# Appendix C — Swift persistent-key matrix



Root: `/Users/user/PhpstormProjects/watchtower/WatchtowerDesktop/Sources` (all paths below relative to it unless absolute). Read-only audit, 2026-09-13.

## Appendix C · — Swift persistent-key matrix

Method: `rg '@AppStorage'`, `rg 'forKey:'` (UserDefaults only), `rg 'static let .*Key.* = "'`. No `@SceneStorage`/`NSUbiquitousKeyValueStore` in Sources. Only `UserDefaults.standard` (plus injected `defaults:` seams that default to `.standard`) is used; there is no other Swift persistent-preference store (config.yaml goes through `ConfigService`, out of scope here).

Verdict legend: OK / DEAD (written, never read) / HIDDEN (read by runtime, no Settings UI writes it) / DRIFT (default in reader ≠ default in Settings UI or CLAUDE.md) / INTERNAL (code-only latch, no UI by design — listed for completeness).

### 1a. Transcription / meetings

| key | default when absent | readers | writers | verdict |
|---|---|---|---|---|
| `transcription.provider` | `"whisperkit"` | `Services/MeetingRecorderCenter.swift:500` (`resolveProviderAndModel`, `?? "whisperkit"`); `Views/Calendar/CalendarEventsView.swift:25` (@AppStorage default "whisperkit", used :156 for prefetch); `Views/Calendar/RecordingIndicatorView.swift:29` (:40 gates live panel on `supportsLive`) | Settings → Meetings picker `Views/Settings/MeetingsSettings.swift:11,60` | **OK** — matches CLAUDE.md ("default whisperkit"). Both engine-key and factory read the same helper (:493–501) so no drift between identity and load. |
| `transcription.model` | `"large-v3-v20240930"` | `MeetingRecorderCenter.swift:501`; `CalendarEventsView.swift:26` | `MeetingsSettings.swift:12,73`; auto-reset on provider change `:69` | **OK** (turbo default per CLAUDE.md). |
| `transcription.langset` | `["ru","uk","en"]` (struct `TranscriptionEngine.swift:37`); Settings shows `"ru,uk,en"` | `TranscriptionEngine.swift:92–98` (`fromDefaults`) | `MeetingsSettings.swift:13,110` | OK |
| `transcription.windowSec` | 30 (`TranscriptionEngine.swift:32`) | `TranscriptionEngine.swift:99–102` (accepts only `> 0`, else silently keeps 30) | `MeetingsSettings.swift:14,173` (free TextField, no range) | OK (silent clamp: a typed `0`/negative is stored but ignored — no UI feedback) |
| `transcription.boundarySnapSec` | 2.5 (`TranscriptionEngine.swift:36`) | `TranscriptionEngine.swift:103–106` (`>= 0`); `WindowPlanner.swift:29` | **none** — no @AppStorage, no Settings control anywhere (`rg boundarySnapSec` → only reader + `DictationCenter.swift:249` which sets the struct field to 0 in-memory, not the key) | **HIDDEN** — CLAUDE.md says "`transcription.boundarySnapSec` (default 2.5 s; 0 disables)" implying a setting; user cannot set it except via `defaults write`. |
| `transcription.langThreshold` | 0.6 (`:38`) | `TranscriptionEngine.swift:107–109` | `MeetingsSettings.swift:15,178` | OK |
| `transcription.margin` | 0.2 (`:39`) | `TranscriptionEngine.swift:110–112` | `MeetingsSettings.swift:16,183` | OK |
| `transcription.forceLang` | `""` → `forcedLanguage = nil` (`:126–128`) | `TranscriptionEngine.swift:126` | `MeetingsSettings.swift:17,188` | OK |
| `transcription.contextPrompt` | `false` (`:48`) | `TranscriptionEngine.swift:113–115` | `MeetingsSettings.swift:19,195` (Advanced disclosure, default `false`) | **OK** — matches CLAUDE.md "default OFF". |
| `transcription.liveTranscription` | `true` (`:51`) | `TranscriptionEngine.swift:116–118` → `MeetingRecorderCenter.startRecording` snapshots `captureLiveEnabled` | `MeetingsSettings.swift:20,124` (default `true`) | **OK** — matches CLAUDE.md "default on". |
| `transcription.diarization` | `true` (`:53`) | `TranscriptionEngine.swift:119–121`; `App/AppState.swift:115` (`fromDefaults().diarization` gate) | `MeetingsSettings.swift:18,150` (default `true`) | **OK** — matches CLAUDE.md. |
| `transcription.diarizationThreshold` | 0.6 (`:57`) | `TranscriptionEngine.swift:122–125` — accepted only if `0.3...0.9`, else silently keeps 0.6 | `MeetingsSettings.swift:22,153–159` (free TextField; help text states 0.3–0.9 but no validation/clamp in UI) | **OK/soft-DRIFT** — matches CLAUDE.md numbers, but UI stores any value and gives no feedback when the runtime discards it (e.g. typing `1.0` shows `1.0` in Settings, engine uses 0.6). |
| `transcription.micAGC` | `false` (`bool(forKey:)` of missing) | `Services/Transcription/MicAGC.swift:42–44` (`isEnabled`) | `MeetingsSettings.swift:23,133` (default `false`) | **OK** — matches CLAUDE.md "default OFF". |
| `transcription.preloadBeforeMeetings` | absent = **true** | `MeetingRecorderCenter.swift:507–510` (`preloadEnabled`, `object == nil || bool`) | `MeetingsSettings.swift:21,128` (@AppStorage default `true`); ALSO `Views/Settings/FeatureManagerSection.swift:252` writes it as a side effect of the "Keep ML engines in memory" row (one-directional coupling, documented `:240–246`) | **OK** — matches CLAUDE.md "absent = ON". Two Settings writers (Meetings tab + Features "Keep ML engines in memory"); the Features row does not read it back so the two can disagree visually (documented as intended `:241–246`). |
| `calendar.autoRecordOnJoin` | absent = `true` (`JoinMeetingAction.swift:50`, `as? Bool ?? true`) | `Services/JoinMeetingAction.swift:50` | `MeetingsSettings.swift:24,121` | OK |
| `dictation.model` | absent → `.apple` if macOS 26+, else `.whisper("small")` (`DictationEngineChoice.swift:37–46`) | `DictationEngineChoice.swift:52` via `DictationCenter.swift:238` | `MeetingsSettings.swift:25,85` (picker; stores raw value) | OK. Note: Settings default `""` is a resolved-value proxy (`:31–41`), consistent with reader. |
| `ml.keepEnginesWarm` | absent = `true` (`DictationCenter.swift:752–755`) | `DictationCenter.swift:752–755` (`keepEnginesWarm` → `armEngineReleaseTimer`) | `FeatureManagerSection.swift:20,247–254` ("Keep ML engines in memory") | OK. Not mentioned in CLAUDE.md (the Voice Dictation section says the 15-min TTL is "constant in v1"; this key makes it 0 vs 15 min, not tunable). |
| dictation `engineIdleTTL` | `.seconds(15*60)` — **not a persistent key**; ctor param `DictationCenter.swift:86,137,149`, used `:814` | — | — | OK as CLAUDE.md states ("constant in v1"); only `ml.keepEnginesWarm` toggles it off entirely. |
| `recorder.pendingAudioPath` / `recorder.pendingEventID` / `recorder.pendingTitle` | nil | `MeetingRecorderCenter.swift:1244–1246` (`migrateLegacyPendingDefaults`, read once then `removeObject` :1252–1254) | **none** (comment `:292–295`: "nothing writes them any more — `rec_X.meta` sidecars replaced them") | **INTERNAL / legacy-read-only** — matches CLAUDE.md ("read+cleared once by `restorePendingOnLaunch`"). |

### 1b. Notifications / reminders

| key | default when absent | readers | writers | verdict |
|---|---|---|---|---|
| `notifyDecisions` | absent = true (`DigestWatcher.swift:72–75`) | `Services/DigestWatcher.swift:72–75` | `Views/Settings/NotificationSettings.swift:5,33` | OK |
| `notifyDailySummary` | (UI default true) | **none** — `rg notifyDailySummary` hits only `NotificationSettings.swift:6,34`. `DigestWatcher.poll` sends briefing notifications unconditionally `:100–110` (only quiet-hours gate `:78`) | `NotificationSettings.swift:6,34` ("Daily summary notifications" toggle) | **DEAD** — toggle has no effect; briefing pushes fire regardless. |
| `quietHoursEnabled` | false | `DigestWatcher.swift:76–78`; `MeetingReminderCenter.swift:172–174` | `NotificationSettings.swift:7,59` | OK. (Only an on/off flag — no hours range is stored; "quiet hours" = always-quiet while enabled.) |
| `notifyMeetingReminders` | absent = true (`MeetingReminderCenter.swift:180–181`) | `MeetingReminderCenter.swift:179–183` | `NotificationSettings.swift:8` | OK |
| `calendar.reminderMinutes` | 5 (`MeetingReminderCenter.swift:110,166–168`) | `MeetingReminderCenter.swift:166–168` | `NotificationSettings.swift:9` | OK |
| `lastCheckedDecisionID` / `lastCheckedBriefingID` | 0 | `DigestWatcher.swift:28–29` | `DigestWatcher.swift:40,52,95,113` | INTERNAL (watermarks) |

### 1c. Shell / lifecycle / onboarding

| key | default when absent | readers | writers | verdict |
|---|---|---|---|---|
| `tray.loginItemRegisteredBundlePath` | nil | `App/TrayAppDelegate.swift:258` | `TrayAppDelegate.swift:261` (code latch on successful `SMAppService` register) | **INTERNAL** — matches CLAUDE.md (latch keyed by bundle path). No UI to un-register the login item; only `DataSettings` full reset (`:251–256`, `removePersistentDomain`) clears it. |
| `pipelines_completed` (`Constants.pipelinesCompletedKey`, `WatchtowerCore/Utilities/Constants.swift:81`) | false | `App/AppState.swift:469` | `WatchtowerCore/Services/BackgroundTaskManager.swift:281` (set true); `AppState.swift:573,594` (remove on reset/re-onboard) | INTERNAL |
| `onboarding_current_step` | absent → `.connect` (`OnboardingStateMachine.swift:67–71`) | `OnboardingStateMachine.swift:67–68` | `:109,140` | INTERNAL |
| `onboarding_sync_completed` / `onboarding_chat_finished` | false | `:73–74` | `:58,63,110–111` | INTERNAL |
| `dismissedCalendarAuthAt` | `""` | `App/Navigation.swift:55` | `Navigation.swift:127` (alert dismiss) | INTERNAL |
| `lastUpdateCheckDate` | nil → check now | `Services/UpdateService.swift:233` | `:153,173,196,209` | INTERNAL |
| `sidebar.section.<id>.collapsed` | `section.collapsedByDefault` (`SidebarView.swift:32–33`) | `SidebarView.swift:29–35` | `:309` (disclosure toggle) | OK (UI writes via sidebar chevrons, not Settings) |
| `sidebar.hiddenItems` | `[]` | `SidebarView.swift:40–42` | `:44–47` (`setHidden`, context-menu "Hide") | OK — user-hidden sidebar items; see §2 for interaction with feature gates. |
| `feed.filter.types` / `feed.filter.importantOnly` / `feed.filter.showHidden` | `[]` / false / false | `ViewModels/FeedViewModel.swift:52–58` | `FeedViewModel.swift:165–167` (from `Views/Dashboard/FeedFilterBar.swift`) | **DEAD-by-reachability** — `FeedViewModel` is constructed on `AppState.swift:669` and consumed only by `Views/Dashboard/DashboardView.swift:13` and `Views/Inbox/InboxFeedView.swift:23`, both unreachable from navigation (§2). Keys are still loaded at startup but no user can change them. |

### 1d. Settings-UI-written keys that no runtime reads
- `notifyDailySummary` — `NotificationSettings.swift:6,34`. **DEAD toggle.**
- Everything else written by Settings has at least one runtime reader (verified per row above).

### 1e. CLAUDE.md claim check (summary)
| CLAUDE.md claim | code | result |
|---|---|---|
| `transcription.provider` default "whisperkit" | `MeetingRecorderCenter.swift:500`, `MeetingsSettings.swift:11` | ✔ |
| `transcription.contextPrompt` default OFF | `TranscriptionEngine.swift:48,113`; `MeetingsSettings.swift:19` | ✔ |
| `transcription.micAGC` default OFF | `MicAGC.swift:43`; `MeetingsSettings.swift:23` | ✔ |
| `transcription.liveTranscription` default ON | `TranscriptionEngine.swift:51`; `MeetingsSettings.swift:20` | ✔ |
| `transcription.preloadBeforeMeetings` absent=ON | `MeetingRecorderCenter.swift:507–510`; `MeetingsSettings.swift:21` | ✔ (+ second writer `FeatureManagerSection.swift:252`) |
| `transcription.diarization` default on | `TranscriptionEngine.swift:53`; `MeetingsSettings.swift:18` | ✔ |
| `transcription.diarizationThreshold` 0.6, accepted 0.3–0.9 | `TranscriptionEngine.swift:57,122–125` | ✔ (UI does not enforce the range — silent discard) |
| `transcription.boundarySnapSec` 2.5, 0 disables | `TranscriptionEngine.swift:36,103–106` | ✔ default; **✘ no UI** (HIDDEN) |
| `tray.loginItemRegisteredBundlePath` latch | `TrayAppDelegate.swift:49,258,261` | ✔ |
| `recorder.pending*` read+cleared once | `MeetingRecorderCenter.swift:296–298,1244–1254` | ✔ |
| dictation `engineIdleTTL` constant 15 min | `DictationCenter.swift:137` | ✔ (but `ml.keepEnginesWarm` = 0-TTL switch, not in CLAUDE.md) |

Findings §1: (F1-1) `notifyDailySummary` DEAD. (F1-2) `transcription.boundarySnapSec` HIDDEN. (F1-3) `diarizationThreshold`/`windowSec` Settings fields accept out-of-range values that the runtime silently discards. (F1-4) `feed.filter.*` persist for an unreachable screen. (F1-5) `ml.keepEnginesWarm` undocumented in CLAUDE.md.
