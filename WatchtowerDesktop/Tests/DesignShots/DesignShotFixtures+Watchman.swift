import AppKit
import DesignKit
import GRDB
import SwiftUI
import WatchtowerCore
import WatchtowerTestSupport
import XCTest
@testable import WatchtowerDesktop

/// Design-only scenes for Watchman (#1824, spec
/// `docs/superpowers/specs/2026-11-16-watchman-design.md` §2, §10, §11).
/// The `journal-*` (the Correct… sheet too), `home-row`, `inbox-entry`,
/// `settings-*`, `strip-*`, `target-panel-*` and `arm-first-time` frames draw
/// the real views on fixture data; `tray-menu` draws the native menu as it
/// reads, in the real copy; the rest are design-only (the strings are
/// `WatchmanMockCopy`).
/// Sample data only (`acme`, made-up ids).
@MainActor
enum WatchmanShotFixtures {
    /// One frame per mocked state; the shot is `watchman-<rawValue>`.
    enum Frame: String, CaseIterable {
        case journalNight = "journal-night"
        case journalEmpty = "journal-empty"
        case journalLoading = "journal-loading"
        case journalError = "journal-error"
        case journalBusy = "journal-busy"
        case journalNarrow = "journal-narrow"
        case journalCorrectSheet = "journal-correct-sheet"
        case homeRow = "home-row"
        case stripArmed = "strip-armed"
        case stripUnarmed = "strip-unarmed"
        case armFirstTime = "arm-first-time"
        case settingsResults = "settings-results"
        case settingsNeverRun = "settings-never-run"
        case settingsRunning = "settings-running"
        case settingsFailed = "settings-failed"
        case trayMenu = "tray-menu"
        case targetPanelArmed = "target-panel-armed"
        case targetPanelUnarmed = "target-panel-unarmed"
        case inboxEntry = "inbox-entry"
        case settingsNotLearned = "settings-not-learned"
        case settingsRelabelling = "settings-relabelling"
        case journalNotRunning = "journal-not-running"
        case journalNightUnsure = "journal-night-unsure"
        case settingsAddLimit = "settings-add-limit"
        case settingsProfileEdit = "settings-profile-edit"

        /// A zero height means "as tall as the content".
        var size: NSSize {
            switch self {
            case .journalNight, .journalBusy, .journalNotRunning, .journalNightUnsure: NSSize(width: 1000, height: 0)
            case .journalEmpty, .journalLoading, .journalError: NSSize(width: 1000, height: 420)
            case .journalNarrow: NSSize(width: 360, height: 0)
            case .journalCorrectSheet: NSSize(width: 480, height: 0)
            case .homeRow: NSSize(width: 420, height: 0)
            case .stripArmed, .stripUnarmed: NSSize(width: 760, height: 0)
            case .armFirstTime: NSSize(width: 460, height: 0)
            case .settingsResults, .settingsNeverRun, .settingsRunning, .settingsFailed, .settingsRelabelling,
                 .settingsAddLimit, .settingsProfileEdit: NSSize(width: 640, height: 0)
            case .trayMenu: NSSize(width: 340, height: 0)
            case .targetPanelArmed, .targetPanelUnarmed: NSSize(width: 380, height: 0)
            case .inboxEntry: NSSize(width: 420, height: 300)
            case .settingsNotLearned: NSSize(width: 640, height: 0)
            }
        }

        @MainActor @ViewBuilder var view: some View {
            switch self {
            case .journalNight:
                JournalShot(model: JournalFixture.model([JournalFixture.fullNight] + JournalFixture.older))
            case .journalEmpty: JournalShot(model: JournalFixture.model([]))
            case .journalLoading: JournalShot(model: JournalFixture.model(nil))
            case .journalError: JournalShot(model: JournalFixture.model(nil, failed: true))
            case .journalBusy:
                JournalShot(model: JournalFixture.model(
                    [JournalFixture.liveNight] + JournalFixture.older, now: JournalFixture.tonight,
                    deciding: [JournalFixture.deciding]))
            case .journalNarrow:
                JournalShot(model: JournalFixture.model([JournalFixture.fullNight] + JournalFixture.older, scope: 1))
            case .journalNotRunning:
                JournalShot(model: JournalFixture.model([JournalFixture.unsureNight] + JournalFixture.older,
                                                        daemon: .stopped))
            case .journalNightUnsure:
                JournalShot(model: JournalFixture.model([JournalFixture.unsureNight] + JournalFixture.older))
            case .journalCorrectSheet: CorrectSheetShot()
            case .homeRow: HomeRowShot()
            case .stripArmed: WatchmanArmingShotFixture.strip(armed: true)
            case .stripUnarmed: WatchmanArmingShotFixture.strip(armed: false)
            case .armFirstTime: ArmSheetShot()
            case .settingsResults:
                WatchmanSettingsShot(json: WatchmanStatusFixtures.results, editing: WatchmanStatusFixtures.editing())
            case .settingsAddLimit:
                WatchmanSettingsShot(
                    json: WatchmanStatusFixtures.results,
                    editing: WatchmanStatusFixtures.editing(errors: [.limits: WatchmanShotFixtures.addLimitError]),
                    draft: .limit(kind: .tool, pattern: "create jira issue"))
            case .settingsProfileEdit:
                WatchmanSettingsShot(
                    json: WatchmanStatusFixtures.results, editing: WatchmanStatusFixtures.editing(),
                    draft: .entry(workbench: 1, key: "ux_text", text: WatchmanShotFixtures.profileDraft))
            case .settingsNeverRun: WatchmanSettingsShot(json: WatchmanStatusFixtures.neverRun, editing: WatchmanStatusFixtures.editing())
            case .settingsRunning: WatchmanSettingsShot(json: WatchmanStatusFixtures.running, editing: WatchmanStatusFixtures.editing())
            case .settingsFailed: WatchmanSettingsShot(json: WatchmanStatusFixtures.failed, editing: WatchmanStatusFixtures.editing())
            case .trayMenu: TrayMenuShot()
            case .targetPanelArmed: WatchmanArmingShotFixture.targetPanel(armed: true)
            case .targetPanelUnarmed: WatchmanArmingShotFixture.targetPanel(armed: false)
            case .inboxEntry: InboxEntryMock()
            case .settingsNotLearned: WatchmanSettingsShot(json: WatchmanStatusFixtures.learning)
            case .settingsRelabelling: WatchmanSettingsShot(json: WatchmanStatusFixtures.relabelling, editing: WatchmanStatusFixtures.editing())
            }
        }
    }

    /// The add-limit frame's line: a tool name with blanks, refused before the CLI.
    static let addLimitError = WatchmanSettingsCopy.limitToolBlanks
    /// The profile-edit frame's draft: ux_text's learned lines and one more.
    static let profileDraft = "Shipped button titles stay unless the guide page changes too.\n"
        + "Say what happened and what to do; no apologies, no exclamation marks.\n"
        + "Name the button after what it does."

    static var shots: [DesignShot] {
        Frame.allCases.map { frame in
            DesignShot(name: "watchman-\(frame.rawValue)", size: frame.size) { AnyView(frame.view) }
        }
    }
}

private typealias Copy = WatchmanMockCopy

// MARK: - Inbox → Watchman (the real journal)

/// The journal's fixture nights (`acme`, made-up ids), read at a fixed
/// moment in UTC so the shots are stable.
@MainActor
private enum JournalFixture {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()

    /// The morning after the night of 16 Nov.
    static let morning = at("2026-11-17T13:00:00Z")
    /// 03:00 inside the night of 16 Nov, while it runs.
    static let tonight = at("2026-11-17T03:00:00Z")

    static func at(_ text: String) -> Date { AutomationDates.parse(text) ?? .distantPast }

    static func item(
        _ id: Int64,
        _ created: String,
        workbench: (Int64, String) = (1, "acme-api"),
        session: Int64 = 3,
        target: Int64 = 0,
        kind: String = "ask",
        state: String = "done",
        outcome: String = "answered",
        question: String,
        choice: String = "",
        rationale: String = "",
        precedents: [Int64] = [],
        confidence: String = "",
        category: String = "",
        unsure: Bool = true,
        parkReason: String = "",
        cost: Double = 0
    ) -> WatchmanItem {
        WatchmanItem(
            id: id, workbenchID: workbench.0, workbenchName: workbench.1, sessionID: session, targetID: target,
            kind: kind, state: state,
            outcome: outcome, question: question, choice: choice, rationale: rationale, precedentIDs: precedents,
            confidence: confidence, category: category, unsure: unsure, parkReason: parkReason, costUSD: cost,
            createdAt: at(created), decidedAt: state == "done" ? at(created).addingTimeInterval(60) : nil)
    }

    static let parked = item(
        1830, "2026-11-17T05:12:00Z", session: 4, outcome: "parked", question: "Merge feature/store-window → main",
        parkReason: "merging to main is yours")
    static let handed = item(
        1834, "2026-11-17T03:47:00Z", session: 5, outcome: "handed", question: "Rotate the deploy token",
        rationale: "issue a new token in the provider's console")
    static let unsure1 = item(
        1826, "2026-11-17T02:14:00Z", target: 1826, question: "Store the window per workbench or global?", choice: "Per workbench",
        rationale: "You split settings per workbench in #1201, #1288 and kept global only what every workbench "
            + "shares. A window's place differs per folder.",
        precedents: [1201, 1288], confidence: "low", category: "design", cost: 0.9)
    static let unsure2 = item(
        1829, "2026-11-17T03:40:00Z", workbench: (2, "acme-web"), session: 7,
        question: "Rename the \"Hold\" button to \"Pause\"?", choice: "Keep \"Hold\"",
        rationale: "You turned down renames of shipped buttons in #1144 unless the guide page changed in the same "
            + "PR. This one doesn't.",
        precedents: [1144], confidence: "low", category: "ux_text", cost: 0.7)
    static let sure = [
        item(1827, "2026-11-17T02:30:00Z", kind: "permission", question: "Allow go test ./internal/watchman",
             confidence: "high", category: "permission", unsure: false, cost: 0.3),
        item(1828, "2026-11-17T04:05:00Z", kind: "review_code", outcome: "approved",
             question: "Review round 2: Approve", confidence: "high", category: "review_code", unsure: false, cost: 0.8)
    ]
    static let check = item(
        1831, "2026-11-17T06:20:00Z", kind: "check", question: "Check the tray menu on a second display", cost: 0.1)
    static let deciding = item(
        1835, "2026-11-17T02:58:00Z", state: "deciding", outcome: "", question: "Store window per workbench?")

    static let precedents: [Int64: String] = [
        1201: "#1201 Sidebar width per workbench", 1288: "#1288 Terminal font per workbench",
        1144: "#1144 Keep \"Archive\" on the board"
    ]

    static func night(
        _ start: String,
        waiting: [WatchmanItem] = [],
        checks: [WatchmanItem] = [],
        decided: [WatchmanItem],
        pending: [WatchmanItem] = []
    ) -> WatchmanNight {
        let items = waiting + checks + decided + pending
        return WatchmanNight(date: at(start), waiting: waiting, checks: checks, decided: decided, pending: pending,
                             costUSD: items.reduce(0) { $0 + $1.costUSD })
    }

    static let older = [
        night("2026-11-15T12:00:00Z", decided: (0..<3).map {
            item(1800 + Int64($0), "2026-11-16T0\($0 + 1):00:00Z", question: "Earlier \($0)", category: "scope")
        }),
        night("2026-11-13T12:00:00Z", decided: [item(1790, "2026-11-14T02:00:00Z", question: "Older", category: "tests")])
    ]

    /// The night of 16 Nov as the spec mocks it: sure lines included.
    static let fullNight = night(
        "2026-11-16T12:00:00Z", waiting: [parked, handed], checks: [check], decided: [unsure1, unsure2] + sure)
    /// A phase-2 night: every decision journalled unsure (D43).
    static let unsureNight = night(
        "2026-11-16T12:00:00Z", waiting: [parked], checks: [check],
        decided: [unsure1, unsure2] + sure.map { var item = $0; item.unsure = true; return item })
    /// Tonight, still running.
    static let liveNight = night("2026-11-16T12:00:00Z", waiting: [parked], decided: [unsure1] + sure,
                                 pending: [deciding])

    static func model(
        _ nights: [WatchmanNight]?,
        now: Date = morning,
        deciding: [WatchmanItem] = [],
        failed: Bool = false,
        daemon: WatchmanDaemonState = .unknown,
        scope: Int64? = nil
    ) -> WatchmanJournalViewModel {
        let vm = WatchmanJournalViewModel(read: { throw CancellationError() }, now: { now }, calendar: calendar)
        if failed {
            vm.apply(.failure(CocoaError(.fileReadUnknown)))
        } else if let nights {
            vm.apply(.success(.init(nights: nights, deciding: deciding, precedents: precedents)))
        }
        vm.daemon = daemon
        vm.scope = scope
        return vm
    }
}

/// The real journal (`WatchmanJournalContent`) on a fixture model.
private struct JournalShot: View {
    let model: WatchmanJournalViewModel

    var body: some View {
        WatchmanJournalContent(model: model, scrolls: false)
    }
}

/// The real Correct… sheet (`WatchmanCorrectSheet`) on the first unsure
/// decision, its session ended: a new session starts with the correction.
private struct CorrectSheetShot: View {
    var body: some View {
        WatchmanCorrectSheet(model: Self.model())
    }

    private static func model() -> WatchmanJournalViewModel {
        let vm = JournalFixture.model([JournalFixture.fullNight])
        vm.beginCorrect(JournalFixture.unsure1.id)
        vm.correcting?.text = Copy.correctDraft
        return vm
    }
}

// MARK: - Home

/// The real Home row (`WatchmanHomeRow`) on last night's counts.
private struct HomeRowShot: View {
    var body: some View {
        WatchmanHomeRow(counts: WatchmanNightCounts(JournalFixture.fullNight)) {}
            .controlSize(.small)
            .padding(Spacing.large)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .detailBackground()
    }
}

// MARK: - Arming (the real controls)

/// The arming controls' fixtures: a workbench `acme-api` with a session and
/// a group target, and a `WatchmanCenter` holding a status read before (so
/// the controls draw without calling the CLI). "Sleep since" is read in UTC.
@MainActor
enum WatchmanArmingShotFixture {
    private static var poolPaths: [String] = []
    /// What the views hold weakly (`WorkbenchesViewModel.watchman`).
    private static var kept: [AnyObject] = []

    static func cleanUp() {
        poolPaths.forEach(TestDatabase.cleanup(path:))
        poolPaths = []
        kept = []
    }

    /// `watchman status --json` with one arming row (none when not armed);
    /// `sessions` are the armed sessions, under the target when it is one.
    static func statusJSON(armed: Bool, scope: WatchmanArmedEntry.Scope, id: Int64, sessions: [Int64]) -> String {
        guard armed else {
            return #"{"ok":true,"workbenches":[],"mode":"off","mode_since":null,"armed":[],"armed_sessions":[],"daemon_running":true}"#
        }
        let since = "2026-11-17T01:40:00Z"
        let target = scope == .target ? id : 0
        let entries = sessions.map { #"{"id":\#($0),"target":\#(target),"armed_at":"\#(since)"}"# }
        return #"{"ok":true,"workbenches":[],"mode":"sleep","mode_since":"\#(since)","#
            + #""armed":[{"scope":"\#(scope.rawValue)","id":\#(id),"armed_at":"\#(since)"}],"#
            + #""armed_sessions":[\#(entries.joined(separator: ","))],"daemon_running":true}"#
    }

    static func status(armed: Bool, scope: WatchmanArmedEntry.Scope, id: Int64, sessions: [Int64]) -> WatchmanStatus {
        WatchmanStatusFixtures.status(statusJSON(armed: armed, scope: scope, id: id, sessions: sessions))
    }

    /// A center that holds the status and answers each reread with it.
    private static func center(_ json: String) -> WatchmanCenter {
        let center = WatchmanCenter(runner: FakeCLIRunner(stdout: Data(json.utf8)), status: WatchmanStatusFixtures.status(json))
        kept.append(center)
        return center
    }

    /// The real `WorkbenchSessionStrip` of an agent session.
    static func strip(armed: Bool) -> AnyView {
        do {
            let (pool, path) = try TestDatabase.createPool()
            poolPaths.append(path)
            let (project, session) = try pool.write { db -> (Workbench, TerminalSession) in
                let id = try TestDatabase.insertWorkbench(db, name: "acme-api", folder: "/tmp/acme-api")
                let session = try TerminalSessionQueries.create(db, .init(
                    projectID: id, kind: .claude, title: Copy.stripSession, folderPath: "/tmp/acme-api",
                    claudeSessionID: "00000000-0000-4000-8000-000000001826"))
                let project = try XCTUnwrap(try Workbench.fetchOne(db, sql: "SELECT * FROM projects WHERE id = ?", arguments: [id]))
                return (project, session)
            }
            let defaults = try XCTUnwrap(UserDefaults(suiteName: DesignShotFixtures.defaultsSuite))
            let vm = WorkbenchesViewModel(dbPool: pool, cli: nil, defaults: defaults)
            vm.selectedWorkbenchID = project.id
            vm.terminalSessions[project.id] = [session]
            vm.watchman = center(statusJSON(armed: armed, scope: .session, id: session.id, sessions: [session.id]))
            kept.append(vm)
            return AnyView(VStack(spacing: 0) {
                WorkbenchSessionStrip(vm: vm, project: project, pane: .session(session.id), sessionID: session.id,
                                      isSplit: false, isExpanded: false)
                Rectangle().fill(.separator).frame(height: Stroke.hairline)
                Color.clear.frame(height: Spacing.hero)
            }
            .environment(\.calendar, JournalFixture.calendar)
            .padding(.top, Spacing.regular)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .detailBackground())
        } catch {
            return DesignShotFixtures.failure(error)
        }
    }

    /// The real `WorkbenchTargetPanel` of a group with four tasks.
    static func targetPanel(armed: Bool) -> AnyView {
        do {
            let (pool, path) = try TestDatabase.createPool()
            poolPaths.append(path)
            let (projectID, group) = try pool.write { db -> (Int64, Int64) in
                let pid = try TestDatabase.insertWorkbench(db, name: "acme-api", folder: "/tmp/acme-api")
                let group = try TestDatabase.insertWorkbenchTarget(db, projectID: pid, text: Copy.targetTitle,
                                                                   status: "in_progress", priority: "high")
                for child in Copy.targetChildren {
                    let status = ["Done": "done", "In progress": "in_progress"][child.status] ?? "todo"
                    try TestDatabase.insertWorkbenchTarget(db, projectID: pid, text: child.title, status: status,
                                                           parentID: group)
                }
                return (pid, group)
            }
            let defaults = try XCTUnwrap(UserDefaults(suiteName: DesignShotFixtures.defaultsSuite))
            let vm = WorkbenchBoardViewModel(dbPool: pool, projectID: projectID, defaults: defaults)
            vm.load()
            vm.select(Int(group))
            let node = try XCTUnwrap(vm.selectedNode)
            let watchman = center(statusJSON(armed: armed, scope: .target, id: group, sessions: []))
            kept.append(vm)
            return AnyView(WorkbenchTargetPanel(
                vm: vm, node: node, findings: [], titleDraft: .constant(Copy.targetTitle),
                onShowAsk: { _, _ in false }, askOpenFailure: { nil }, onOpenGroup: { _ in }, onClose: {},
                watchman: watchman, workbenchName: "acme-api"
            )
            .environment(\.calendar, JournalFixture.calendar)
            .environment(AppState())
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .detailBackground())
        } catch {
            return DesignShotFixtures.failure(error)
        }
    }
}

/// The real arm sheet of a first hand-over: `arm --check` said a first time
/// (with its estimate) and an unprotected main.
private struct ArmSheetShot: View {
    var body: some View {
        let reply = WatchmanArmReply(
            firstTime: true, estimate: WatchmanEstimate(decisions: 1850, needLabels: 1200, tokens: 1_600_000),
            protectionWarning: WatchmanArmingCopy.protectionWarning)
        WatchmanArmSheet(content: WatchmanArmSheetContent(workbench: "acme-api", reply: reply),
                         onCancel: {}, onConfirm: {})
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .detailBackground()
    }
}

// MARK: - Settings → Watchman

/// The real Settings → Profile → Watchman section (`WatchmanSettingsContent`)
/// on a `watchman status --json` fixture per state.
private struct WatchmanSettingsShot: View {
    let json: String
    var editing = WatchmanEditingData()
    var draft: WatchmanSettingsDraft?

    var body: some View {
        WatchmanSettingsContent(state: .of(WatchmanStatusFixtures.status(json)), editing: editing, draft: draft)
            .padding(Spacing.page)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .detailBackground()
    }
}

// MARK: - Menu bar

/// The menu bar menu (`TrayMenuContent`, a native menu that cannot render
/// in a shot) drawn as it reads, with Watchman's section between Sync Now
/// and New Voice Idea in the real copy: its status line and Hand all running
/// sessions to Watchman. Phase 2 has no Going to sleep item (D47).
private struct TrayMenuShot: View {
    var body: some View {
        let status = WatchmanArmingShotFixture.status(armed: true, scope: .target, id: 1820, sessions: [3, 5, 7])
        VStack(alignment: .leading, spacing: Spacing.tight) {
            item(Copy.trayStatus, status: true)
            separator
            item(Copy.traySyncNow)
            separator
            item(WatchmanArmingCopy.trayStatus(status, calendar: JournalFixture.calendar) ?? "", status: true)
            item(WatchmanArmingCopy.trayHandAll)
            separator
            item(Copy.trayVoiceIdea, shortcut: Copy.trayVoiceShortcut)
            separator
            item(Copy.trayOpen)
            item(Copy.traySettings)
            separator
            item(Copy.trayQuit)
        }
        .padding(Spacing.small)
        .popoverSurface()
        .padding(Spacing.large)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Surface.window)
    }

    private var separator: some View {
        Rectangle().fill(.separator).frame(height: Stroke.hairline).padding(.vertical, Spacing.small)
    }

    private func item(_ title: String, status: Bool = false, shortcut: String? = nil) -> some View {
        HStack(spacing: Spacing.compact) {
            Text(title).foregroundStyle(status ? .secondary : .primary).lineLimit(1)
            Spacer(minLength: Spacing.large)
            if let shortcut { Text(shortcut).foregroundStyle(.secondary) }
        }
        .font(.body)
        .padding(.horizontal, Spacing.regular)
        .padding(.vertical, Spacing.tight)
    }
}

// MARK: - Inbox source list

/// The real `InboxFolderContentList` of the Inbox root with Watchman's row
/// beside Morning brief, Track my threads and Idea finder; its literals
/// mirror the format of the Go feed's journal card (`inboxfeed.watchmanCard`,
/// pinned by `TestLegacy_WatchmanJournalCard`), not a feed read; its summary
/// is what waits for the owner.
private struct InboxEntryMock: View {
    var body: some View {
        let watchman = InboxFolderListRow(
            id: InboxFolderEntry.watchman.id, kind: .legacy, title: WatchmanJournalCopy.title, summary: "2 waiting",
            detail: "Night of 16 Nov · 14 decided · 2 unsure", unread: true)
        let others = Copy.inboxOthers.map {
            InboxFolderListRow(id: $0.id, kind: .legacy, title: $0.title, summary: $0.summary, detail: $0.detail)
        }
        return InboxFolderContentList(content: InboxFolderListContent(
            folderKind: .root, folderTitle: Copy.inboxRoot, rows: [watchman] + others, selection: "watchman"
        ))
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .detailBackground()
    }
}
