import AppKit
import DesignKit
import SwiftUI
import WatchtowerCore
import WatchtowerTestSupport
@testable import WatchtowerDesktop

/// Design-only scenes for Watchman (#1824, spec
/// `docs/superpowers/specs/2026-11-16-watchman-design.md` §2, §10, §11).
/// The `journal-*` (but the Correct… sheet), `home-row`, `inbox-entry` and
/// `settings-*` frames draw the real views on fixture data; the rest are
/// design-only (the strings are `WatchmanMockCopy`).
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
            case .journalCorrectSheet: CorrectSheetMock()
            case .homeRow: HomeRowShot()
            case .stripArmed: SessionStripMock(armed: true)
            case .stripUnarmed: SessionStripMock(armed: false)
            case .armFirstTime: ArmSheetMock()
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
            case .trayMenu: TrayMenuMock()
            case .targetPanelArmed: TargetPanelMock(armed: true)
            case .targetPanelUnarmed: TargetPanelMock(armed: false)
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

/// The capsule tint of Watchman's own marks (armed chip, the journal's moon).
private let watchmanTone = Tone.status("purple")

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
            id: id, workbenchID: workbench.0, workbenchName: workbench.1, sessionID: session, kind: kind, state: state,
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
        1826, "2026-11-17T02:14:00Z", question: "Store the window per workbench or global?", choice: "Per workbench",
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

/// Correct…: the owner writes what he would have decided.
private struct CorrectSheetMock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            Text(Copy.correctTitle).font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(Copy.unsure1Question).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                    Text(Copy.choseLabel).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(Copy.unsure1Choice).font(.callout)
                }
            }
            .padding(Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(Copy.correctQuestion).font(.headline)
                TextField("", text: .constant(Copy.correctDraft), axis: .vertical)
                    .textFieldStyle(.kit)
                    .lineLimit(3...6)
                HStack(alignment: .top, spacing: Spacing.regular) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text(Copy.correctSessionEnded)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: Spacing.regular) {
                Spacer()
                Button(Copy.cancel) {}.buttonStyle(.kitSecondary)
                Button(Copy.sendCorrection) {}.buttonStyle(.kitPrimary)
            }
        }
        .controlSize(.small)
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .detailBackground()
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

// MARK: - Arming

/// The session strip above a session's pane, armed or not.
private struct SessionStripMock: View {
    let armed: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.regular) {
                MenuLabel(text: Copy.stripSession, systemImage: "circle.fill", color: Tone.success).fixedSize()
                Label(Copy.stripPlace, systemImage: "folder").foregroundStyle(.secondary).lineLimit(1).fixedSize()
                Label(Copy.stripBranch, systemImage: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Spacing.small)
                if armed {
                    Chip(text: Copy.armedChip, color: watchmanTone, dot: true).fixedSize()
                    Button(Copy.takeBack) {}.buttonStyle(.kitSecondary).fixedSize()
                } else {
                    Button {} label: { Label(Copy.handTo, systemImage: "moon.stars") }
                        .buttonStyle(.kitSecondary)
                        .fixedSize()
                }
                segment(Copy.workchat, icon: "bubble.left.and.bubble.right")
                segment(Copy.report, icon: "doc.text")
            }
            .font(.caption)
            .padding(.horizontal, Spacing.regular)
            .padding(.vertical, Spacing.tight)
            Rectangle().fill(.separator).frame(height: Stroke.hairline)
            Color.clear.frame(height: Spacing.hero)
        }
        .controlSize(.small)
        .padding(.top, Spacing.regular)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .detailBackground()
    }

    private func segment(_ title: String, icon: String) -> some View {
        Toggle(isOn: .constant(false)) { Label(title, systemImage: icon) }
            .toggleStyle(SegmentedToggleStyle(showsIcon: false, isHovered: false) { _ in })
            .segmentCapsule()
            .fixedSize()
    }
}

/// The first arm on a workbench: what turns on, what learning costs.
private struct ArmSheetMock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(Copy.armTitle).font(.title3.weight(.semibold))
                Text(Copy.armBody).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: Spacing.medium) {
                line("chart.bar.xaxis", .secondary, Copy.armAnalytics)
                line("books.vertical", .secondary, Copy.armHistory)
                line("hand.raised", .secondary, Copy.armLimits)
            }
            .padding(Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
            line("exclamationmark.triangle.fill", Tone.warning, Copy.armNoProtection)
                .padding(Spacing.medium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Tone.warning.opacity(ChipTint.fillOpacity), in: RoundedRectangle(cornerRadius: Radius.row))
            HStack(spacing: Spacing.regular) {
                Spacer()
                Button(Copy.notNow) {}.buttonStyle(.kitSecondary)
                Button(Copy.start) {}.buttonStyle(.kitPrimary)
            }
        }
        .controlSize(.small)
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .detailBackground()
    }

    private func line(_ icon: String, _ tone: Color, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Image(systemName: icon).foregroundStyle(tone).frame(width: IconSize.composer)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
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

/// The menu bar menu (`TrayMenuContent`, a native menu) with Watchman's
/// section between Sync Now and New Voice Idea. Drawn as the menu reads:
/// status lines dimmed, a check on the item that is on.
private struct TrayMenuMock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            item(Copy.trayStatus, status: true)
            separator
            item(Copy.traySyncNow)
            separator
            item(Copy.trayWatchmanStatus, status: true)
            item(Copy.trayHandAll)
            item(Copy.trayGoingToSleep, checked: true)
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

    private func item(_ title: String, status: Bool = false, checked: Bool = false, shortcut: String? = nil) -> some View {
        HStack(spacing: Spacing.compact) {
            Image(systemName: "checkmark")
                .font(.caption.weight(.semibold))
                .opacity(checked ? 1 : 0)
                .frame(width: Spacing.medium)
            Text(title).foregroundStyle(status ? .secondary : .primary).lineLimit(1)
            Spacer(minLength: Spacing.large)
            if let shortcut { Text(shortcut).foregroundStyle(.secondary) }
        }
        .font(.body)
        .padding(.horizontal, Spacing.compact)
        .padding(.vertical, Spacing.tight)
    }
}

// MARK: - Target panel

/// `WorkbenchTargetPanel`'s header in group mode with Watchman's line: the
/// whole subtree's sessions are handed over (or taken back) here.
private struct TargetPanelMock: View {
    let armed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.cozy) {
                topBar
                Text(Copy.targetTitle).font(.title3.weight(.semibold))
                HStack(spacing: Spacing.compact) {
                    MenuLabel(text: Copy.targetStatus, systemImage: "circle.fill", color: Tone.status("blue"))
                    MenuLabel(text: Copy.targetPriority, systemImage: "flag.fill", color: Tone.priority("high"))
                }
                VStack(alignment: .leading, spacing: Spacing.small) {
                    ProgressView(value: 0.6).frame(width: ListLayout.progressBar)
                    Text(Copy.targetProgress).font(.caption).foregroundStyle(.secondary)
                }
                watchman
            }
            .padding(Spacing.large)
            Rectangle().fill(.separator).frame(height: Stroke.hairline)
            children.padding(Spacing.large)
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .detailBackground()
    }

    private var topBar: some View {
        HStack(spacing: Spacing.regular) {
            OutlineTag(text: Copy.targetNumber)
            Chip(text: Copy.targetGroup, color: .secondary)
            Spacer(minLength: 0)
            Button {} label: { Label(Copy.targetWorkOnIt, systemImage: "play.fill") }
                .buttonStyle(.kitSecondary)
                .fixedSize()
            Button {} label: { Image(systemName: "ellipsis") }.buttonStyle(.kitIcon(isOn: false))
            Button {} label: { Image(systemName: "xmark") }.buttonStyle(.kitIcon(isOn: false))
        }
    }

    @ViewBuilder private var watchman: some View {
        if armed {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                HStack(spacing: Spacing.regular) {
                    Image(systemName: "moon.stars").foregroundStyle(watchmanTone)
                    Text(Copy.targetArmed).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Spacing.regular)
                    Button(Copy.takeBack) {}.buttonStyle(.kitSecondary).fixedSize()
                }
                Text(Copy.targetArmedCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Spacing.medium)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(watchmanTone.opacity(ChipTint.fillOpacity), in: RoundedRectangle(cornerRadius: Radius.row))
        } else {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                Button {} label: { Label(Copy.handTo, systemImage: "moon.stars") }
                    .buttonStyle(.kitSecondary)
                    .fixedSize()
                Text(Copy.targetUnarmedCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var children: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text(Copy.targetChildrenTitle).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Copy.targetChildren, id: \.title) { child in
                HStack(spacing: Spacing.regular) {
                    Text(child.title).font(.callout).lineLimit(1)
                    Spacer(minLength: Spacing.regular)
                    Text(child.status).font(.caption).foregroundStyle(.secondary)
                }
                .frame(minHeight: ListLayout.rowMinHeight)
                .kitRow(isSelected: false)
            }
        }
    }
}

// MARK: - Inbox source list

/// The real `InboxFolderContentList` of the Inbox root with Watchman's real
/// row (`InboxFolderEntries.row(.watchman, …)`) beside Morning brief, Track
/// my threads and Idea finder; its summary carries what waits for the owner.
private struct InboxEntryMock: View {
    var body: some View {
        var feed = InboxFeedSnapshot()
        feed.watchman = WatchmanInboxSummary(
            latest: WatchmanNightCounts(start: JournalFixture.at("2026-11-16T12:00:00Z"), decided: 14, unsure: 2,
                                        waiting: 2),
            waiting: 2, updatedAt: JournalFixture.morning)
        let inputs = InboxFolderEntries.Inputs(
            feed: feed, folders: InboxFolderMenuSnapshot(tree: .rootOnly), now: JournalFixture.morning,
            calendar: JournalFixture.calendar)
        let watchman = InboxFolderEntries.row(.watchman, inputs)
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
