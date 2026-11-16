import AppKit
import DesignKit
import SwiftUI
import WatchtowerCore
@testable import WatchtowerDesktop

/// Design-only scenes for Watchman (#1824, spec
/// `docs/superpowers/specs/2026-11-16-watchman-design.md` §2, §10, §11).
/// Nothing here is wired into the app; the strings are `WatchmanMockCopy`.
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

        /// A zero height means "as tall as the content".
        var size: NSSize {
            switch self {
            case .journalNight, .journalBusy: NSSize(width: 1000, height: 0)
            case .journalEmpty, .journalLoading, .journalError: NSSize(width: 1000, height: 420)
            case .journalNarrow: NSSize(width: 360, height: 0)
            case .journalCorrectSheet: NSSize(width: 480, height: 0)
            case .homeRow: NSSize(width: 420, height: 0)
            case .stripArmed, .stripUnarmed: NSSize(width: 760, height: 0)
            case .armFirstTime: NSSize(width: 460, height: 0)
            case .settingsResults, .settingsNeverRun, .settingsRunning, .settingsFailed: NSSize(width: 640, height: 0)
            }
        }

        @ViewBuilder var view: some View {
            switch self {
            case .journalNight: JournalSplitMock(state: .night)
            case .journalEmpty: JournalSplitMock(state: .empty)
            case .journalLoading: JournalSplitMock(state: .loading)
            case .journalError: JournalSplitMock(state: .error)
            case .journalBusy: JournalSplitMock(state: .busy)
            case .journalNarrow: JournalNarrowMock()
            case .journalCorrectSheet: CorrectSheetMock()
            case .homeRow: HomeRowMock()
            case .stripArmed: SessionStripMock(armed: true)
            case .stripUnarmed: SessionStripMock(armed: false)
            case .armFirstTime: ArmSheetMock()
            case .settingsResults: WatchmanSettingsMock(state: .results)
            case .settingsNeverRun: WatchmanSettingsMock(state: .neverRun)
            case .settingsRunning: WatchmanSettingsMock(state: .running)
            case .settingsFailed: WatchmanSettingsMock(state: .failed)
            }
        }
    }

    static var shots: [DesignShot] {
        Frame.allCases.map { frame in
            DesignShot(name: "watchman-\(frame.rawValue)", size: frame.size) { AnyView(frame.view) }
        }
    }
}

private typealias Copy = WatchmanMockCopy

/// The capsule tint of Watchman's own marks (armed chip, the journal's moon).
private let watchmanTone = Tone.status("purple")

// MARK: - Inbox → Watchman

private enum JournalState { case night, empty, loading, error, busy }

/// The Inbox with the Watchman entry open: the nights on the left, the
/// selected night's journal on the right.
private struct JournalSplitMock: View {
    let state: JournalState

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            nightList
                .frame(width: PaneWidth.sideListMax - Spacing.page * 3)
            Rectangle().fill(.separator).frame(width: Stroke.hairline)
            reading
                .frame(maxWidth: ReadableColumn.maxLineWidth, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .top)
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .detailBackground()
    }

    private var nightList: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(spacing: Spacing.regular) {
                Image(systemName: "moon.stars").foregroundStyle(watchmanTone)
                Text(Copy.journalTitle).font(.headline)
                Spacer(minLength: Spacing.regular)
                MenuLabel(text: Copy.scopeAll, systemImage: "square.stack", color: .secondary)
            }
            .padding(.bottom, Spacing.regular)
            switch state {
            case .empty, .loading, .error:
                EmptyView()
            case .night, .busy:
                if state == .busy {
                    nightRow(Copy.nightTonight, Copy.nightTonightLine, selected: true, live: true)
                }
                nightRow(Copy.night16, Copy.night16Line, selected: state == .night, live: false)
                nightRow(Copy.night15, Copy.night15Line, selected: false, live: false)
                nightRow(Copy.night13, Copy.night13Line, selected: false, live: false)
            }
        }
        .padding(Spacing.medium)
    }

    private func nightRow(_ title: String, _ line: String, selected: Bool, live: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
            Group {
                if live {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle().fill(selected ? Color.accentColor : .clear)
                        .frame(width: IconSize.stateDot, height: IconSize.stateDot)
                }
            }
            .frame(width: Spacing.medium)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(title).font(.callout.weight(selected ? .semibold : .regular))
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.regular)
        .padding(.vertical, Spacing.compact)
        .kitRow(isSelected: selected)
    }

    @ViewBuilder private var reading: some View {
        switch state {
        case .night:
            JournalNight(live: false).padding(Spacing.page)
        case .busy:
            JournalNight(live: true).padding(Spacing.page)
        case .empty:
            FeatureEmptyState(
                copy: EmptyStateCopy(icon: "moon.stars", title: Copy.emptyTitle, landsHere: Copy.emptyBody,
                                     feature: nil, primaryAction: nil),
                readiness: nil, syncLine: nil, turnOnError: nil, isTurningOn: false,
                onAction: { _ in },
                extra: {
                    Text(Copy.emptyHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: PaneWidth.narrowPage)
                }
            )
        case .loading:
            VStack(spacing: Spacing.regular) {
                ProgressView().controlSize(.small)
                Text(Copy.loading).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .error:
            VStack(spacing: Spacing.medium) {
                Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(Tone.warning)
                Text(Copy.readFailed)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: PaneWidth.narrowPage)
                Button(Copy.retry) {}.buttonStyle(.kitPrimary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// One night's journal: Waiting for you, then Decided (unsure cards in
/// full, sure decisions as lines, a skipped check).
private struct JournalNight: View {
    let live: Bool
    var narrow = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            header
            if live { liveLine }
            section(Copy.waitingTitle, count: 1, trailing: nil) { parkedCard }
            section(Copy.decidedTitle, count: live ? 3 : 14, trailing: live ? Copy.busySummary : Copy.decidedSummary) {
                DecisionCard(
                    session: Copy.unsure1Session, question: Copy.unsure1Question, choice: Copy.unsure1Choice,
                    rationale: Copy.unsure1Rationale, precedents: Copy.unsure1Precedents,
                    meta: Copy.unsure1Meta, outcome: Copy.unsure1Outcome, merged: true, narrow: narrow
                )
                if !narrow, !live {
                    DecisionCard(
                        session: Copy.unsure2Session, question: Copy.unsure2Question, choice: Copy.unsure2Choice,
                        rationale: Copy.unsure2Rationale, precedents: Copy.unsure2Precedents,
                        meta: Copy.unsure2Meta, outcome: Copy.unsure2Outcome, merged: false, narrow: narrow
                    )
                }
                sureLines
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(live ? Copy.nightTonight : Copy.night16).font(.title3.weight(.semibold))
            Text(live ? Copy.busySpan : Copy.nightSpan).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var liveLine: some View {
        HStack(spacing: Spacing.regular) {
            ProgressView().controlSize(.small)
            Text(Copy.deciding).font(.callout).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(Spacing.medium)
        .background(watchmanTone.opacity(ChipTint.fillOpacity), in: RoundedRectangle(cornerRadius: Radius.row))
    }

    private func section(
        _ title: String, count: Int, trailing: String?, @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(Tracking.caps)
                    .foregroundStyle(.secondary)
                CountBadge(text: "\(count)")
                Spacer(minLength: Spacing.regular)
                if let trailing { Text(trailing).font(.caption).foregroundStyle(.secondary) }
            }
            content()
        }
    }

    private var parkedCard: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                Image(systemName: "hand.raised.fill").foregroundStyle(Tone.warning)
                Text(Copy.parkedTitle).font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            }
            Text(Copy.parkedReason).font(.callout)
            Text(Copy.parkedSession).font(.caption).foregroundStyle(.secondary)
            Button(Copy.openSession) {}.buttonStyle(.kitSecondary).padding(.top, Spacing.tight)
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var sureLines: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            ForEach(Copy.sureRows.prefix(live ? 2 : Copy.sureRows.count), id: \.title) { row in
                line(icon: "checkmark.circle.fill", tone: Tone.success, title: row.title, note: nil, meta: row.meta)
            }
            if !live {
                line(icon: "forward.circle", tone: Tone.status("gray"), title: Copy.skippedTitle,
                     note: Copy.skippedLine, meta: Copy.skippedMeta)
                Button(Copy.moreSure) {}.buttonStyle(.kitQuiet)
            }
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    @ViewBuilder
    private func line(icon: String, tone: Color, title: String, note: String?, meta: String) -> some View {
        let text = VStack(alignment: .leading, spacing: Spacing.tight) {
            Text(title).font(.callout).fixedSize(horizontal: false, vertical: true)
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Image(systemName: icon).foregroundStyle(tone)
            if narrow {
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    text
                    Text(meta).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                text
                Spacer(minLength: Spacing.medium)
                Text(meta).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// One decision Watchman took for the owner and was not sure about.
private struct DecisionCard: View {
    let session: String
    let question: String
    let choice: String
    let rationale: String
    let precedents: [String]
    let meta: String
    let outcome: String
    let merged: Bool
    let narrow: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            HStack(spacing: Spacing.regular) {
                Chip(text: Copy.unsureBadge, color: Tone.warning, dot: true)
                Text(session).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(question).font(.headline).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                Text(Copy.choseLabel).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(choice).font(.callout.weight(.semibold))
            }
            Text(rationale).font(.callout).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text(Copy.leanedOn).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(precedents, id: \.self) { precedent in
                    Button {} label: {
                        Label(precedent, systemImage: "arrow.turn.down.right").font(.caption)
                    }
                    .buttonStyle(.kitQuiet)
                }
            }
            Text(meta).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: Spacing.compact) {
                Image(systemName: merged ? "arrow.triangle.merge" : "arrow.forward.circle")
                    .foregroundStyle(merged ? Tone.success : .secondary)
                Text(outcome).font(.caption)
            }
            HStack(spacing: Spacing.regular) {
                Button(Copy.ok) {}.buttonStyle(.kitSecondary)
                Button(Copy.correct) {}.buttonStyle(.kitSecondary)
                if !narrow { Spacer(minLength: Spacing.regular) }
                Button(Copy.openSession) {}.buttonStyle(.kitQuiet)
            }
            .padding(.top, Spacing.tight)
        }
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// The journal at 360 pt, scoped to one workbench.
private struct JournalNarrowMock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            HStack(spacing: Spacing.regular) {
                Image(systemName: "moon.stars").foregroundStyle(watchmanTone)
                Text(Copy.journalTitle).font(.headline)
                Spacer(minLength: Spacing.regular)
                MenuLabel(text: Copy.scopeOne, systemImage: "square.stack", color: Color.accentColor)
            }
            JournalNight(live: false, narrow: true)
        }
        .controlSize(.small)
        .padding(Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .detailBackground()
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

private struct HomeRowMock: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
            Image(systemName: "moon.stars").foregroundStyle(watchmanTone)
            Text(Copy.homeRow).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.regular)
            Image(systemName: "chevron.right")
                .font(.system(size: IconSize.chevron, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.regular)
        .card()
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

private enum SettingsState { case results, neverRun, running, failed }

private struct WatchmanSettingsMock: View {
    let state: SettingsState

    private var hasResults: Bool { state != .neverRun }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            sleepSection
            backtestSection
            profileSection
            limitsSection
            SettingsSection(title: Copy.budgetTitle) {
                SettingRow(title: Copy.budgetValue) { Button(Copy.edit) {}.buttonStyle(.kitSecondary) }
            }
        }
        .controlSize(.small)
        .padding(Spacing.page)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .detailBackground()
    }

    private var sleepSection: some View {
        SettingsSection(title: Copy.sleepTitle, caption: Copy.sleepCaption) {
            if hasResults {
                HStack(spacing: Spacing.regular) {
                    Text(Copy.sleepValue).font(.body.monospacedDigit())
                    OutlineTag(text: Copy.sleepLearned)
                    Spacer(minLength: Spacing.regular)
                    Button(Copy.edit) {}.buttonStyle(.kitSecondary)
                }
            } else {
                Text(Copy.sleepNotLearned).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var backtestSection: some View {
        SettingsSection(
            title: Copy.backtestTitle,
            caption: hasResults ? Copy.backtestCaption : nil,
            isBusy: state == .running
        ) {
            switch state {
            case .neverRun:
                Text(Copy.backtestNeverRun).font(.callout).fixedSize(horizontal: false, vertical: true)
            case .running:
                VStack(alignment: .leading, spacing: Spacing.small) {
                    ProgressView(value: 0.4).frame(width: ListLayout.progressBar)
                    Text(Copy.backtestRunning).font(.caption).foregroundStyle(.secondary)
                }
            case .failed:
                HStack(alignment: .top, spacing: Spacing.regular) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning)
                    Text(Copy.backtestFailed).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            case .results:
                EmptyView()
            }
            if hasResults {
                if state != .results {
                    Text(Copy.lastResults)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, Spacing.small)
                }
                table.opacity(state == .running ? 0.6 : 1)
                Text(Copy.barNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(Copy.analyticsOffNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                switch state {
                case .running:
                    Button(Copy.backtestRunningButton) {}.buttonStyle(.kitPrimary).disabled(true)
                case .failed:
                    Button(Copy.retry) {}.buttonStyle(.kitPrimary)
                default:
                    Button(Copy.runBacktest) {}.buttonStyle(.kitPrimary)
                }
            }
            .padding(.top, Spacing.small)
        }
    }

    private var table: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            tableRow(Copy.columnCategory, Copy.columnAgreement, Copy.columnWrongHigh) {
                Text(Copy.columnRating)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            ForEach(Copy.backtestRows, id: \.category) { row in
                tableRow(row.category, row.agreement, row.wrongHigh) {
                    Chip(text: row.rating, color: ratingTone(row.rating))
                }
                .font(.callout.monospacedDigit())
            }
        }
        .padding(.vertical, Spacing.small)
    }

    private func tableRow(
        _ category: String, _ agreement: String, _ wrong: String, @ViewBuilder rating: () -> some View
    ) -> some View {
        HStack(spacing: Spacing.regular) {
            Text(category).frame(width: ListLayout.textColumn - Spacing.hero, alignment: .leading)
            Text(agreement).frame(width: ListLayout.numberColumn, alignment: .trailing)
            Text(wrong).frame(width: ListLayout.dateColumn, alignment: .trailing)
            Spacer(minLength: Spacing.medium)
            rating()
        }
        .frame(minHeight: ListLayout.lineMinHeight)
    }

    private func ratingTone(_ rating: String) -> Color {
        switch rating {
        case Copy.strong: Tone.success
        case Copy.weak: Tone.warning
        default: Tone.status("gray")
        }
    }

    private var profileSection: some View {
        SettingsSection(title: Copy.profileTitle, caption: Copy.profileCaption) {
            if hasResults {
                profileCard("design", tag: Copy.pinned, rules: Copy.profileDesign, pinned: true)
                profileCard("ux_text", tag: Copy.learnedOn, rules: Copy.profileUXText, pinned: false)
            } else {
                Text(Copy.profileEmpty).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func profileCard(_ category: String, tag: String, rules: [String], pinned: Bool) -> some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            HStack(spacing: Spacing.regular) {
                Text(category).font(.callout.weight(.semibold))
                OutlineTag(text: tag)
                Spacer(minLength: Spacing.regular)
                Button(Copy.edit) {}.buttonStyle(.kitSecondary)
                if pinned { Button(Copy.unpin) {}.buttonStyle(.kitQuiet) }
            }
            ForEach(rules, id: \.self) { rule in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.regular) {
                    Text("•").foregroundStyle(.secondary)
                    Text(rule).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.bottom, Spacing.regular)
    }

    private var limitsSection: some View {
        SettingsSection(title: Copy.limitsTitle, caption: Copy.limitsCaption) {
            ForEach(Copy.extraLimits, id: \.self) { limit in
                HStack(spacing: Spacing.regular) {
                    Image(systemName: "hand.raised").foregroundStyle(.secondary)
                    Text(limit).font(.callout)
                    Spacer(minLength: Spacing.regular)
                    Button(Copy.remove) {}.buttonStyle(.kitQuiet)
                }
            }
            Button(Copy.addLimit) {}.buttonStyle(.kitSecondary)
        }
    }
}
