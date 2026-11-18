import DesignKit
import SwiftUI
import WatchtowerCore

/// Settings → Profile → Watchman (#1823, phase 1) over the app-wide
/// `WatchmanCenter`: rereads while a learning pass or a backtest runs.
struct WatchmanSettingsSection: View {
    let center: WatchmanCenter

    var body: some View {
        WatchmanSettingsContent(
            state: center.state,
            phase: { center.phase(of: $0) },
            notices: center.notices,
            readError: center.readError,
            onStartLearning: { id in Task { await center.startLearning(workbench: id) } },
            onRunBacktest: { id in Task { await center.runBacktest(workbench: id) } },
            onRetry: { Task { await center.load() } }
        )
        .task(id: center.needsPolling) { await center.watch() }
    }
}

/// The section's body for one state, so the design shots draw the real
/// screen on fixture JSON. Phase 1 is read-only except Start Learning, Run
/// Backtest Now and Retry: no Edit, Unpin or extra limits (phase 2).
struct WatchmanSettingsContent: View {
    let state: WatchmanSettingsState
    var phase: (WatchmanWorkbenchStatus) -> WatchmanWorkbenchPhase = { WatchmanWorkbenchPhase.of($0) }
    var notices: [Int64: String] = [:]
    var readError: String?
    var onStartLearning: (Int64) -> Void = { _ in }
    var onRunBacktest: (Int64) -> Void = { _ in }
    var onRetry: () -> Void = {}

    private typealias Copy = WatchmanSettingsCopy

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            switch state {
            case .loading:
                HStack(spacing: Spacing.regular) {
                    ProgressView().controlSize(.small)
                    Text(Copy.loading).font(.callout).foregroundStyle(.secondary)
                }
            case let .readFailed(message):
                VStack(alignment: .leading, spacing: Spacing.regular) {
                    Text(Copy.readFailed(message))
                        .font(.callout)
                        .foregroundStyle(Tone.error)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(Copy.retry, action: onRetry).buttonStyle(.kitSecondary)
                }
            default:
                if let readError {
                    Text(Copy.refreshFailed(readError))
                        .font(.caption)
                        .foregroundStyle(Tone.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let status = state.status { sections(status) }
            }
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func sections(_ status: WatchmanStatus) -> some View {
        let pending = status.workbenches.filter { isPending(phase($0)) }
        let learned = status.workbenches.filter { !isPending(phase($0)) }
        if status.workbenches.isEmpty {
            SettingsSection(title: Copy.workbenchesTitle) {
                Text(Copy.noWorkbenches).font(.callout).foregroundStyle(.secondary)
            }
        }
        if !pending.isEmpty {
            SettingsSection(
                title: Copy.workbenchesTitle, caption: learned.isEmpty ? Copy.notLearnedIntro : Copy.moreWorkbenchesIntro
            ) {
                ForEach(pending, id: \.workbench) { workbenchRow($0) }
            }
        }
        ForEach(learned, id: \.workbench) { row in
            sleepSection(row, several: learned.count > 1)
            backtestSection(row, several: learned.count > 1)
        }
    }

    private func isPending(_ phase: WatchmanWorkbenchPhase) -> Bool {
        phase == .notLearned || phase == .learning
    }

    // MARK: - Workbenches not learned yet

    private func workbenchRow(_ row: WatchmanWorkbenchStatus) -> some View {
        HStack(spacing: Spacing.regular) {
            Image(systemName: "square.stack").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(row.name).font(.callout.weight(.semibold))
                if let estimate = row.estimate {
                    Text(Copy.estimateLine(estimate)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else if !row.isEnabled {
                    Text(Copy.estimateUnavailable).font(.caption).foregroundStyle(.secondary)
                }
                if let notice = notices[row.workbench] {
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(Tone.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Spacing.regular)
            if phase(row) == .learning {
                ProgressView().controlSize(.small)
                Text(Copy.learningLine(row)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            } else {
                Button(Copy.startLearning) { onStartLearning(row.workbench) }.buttonStyle(.kitSecondary)
            }
        }
        .frame(minHeight: ListLayout.rowMinHeight)
    }

    // MARK: - Sleep window

    private func sleepSection(_ row: WatchmanWorkbenchStatus, several: Bool) -> some View {
        SettingsSection(title: Copy.sleepTitle(name: row.name, several: several), caption: Copy.sleepCaption) {
            if let value = Copy.sleepValue(row.sleepWindow) {
                HStack(spacing: Spacing.regular) {
                    Text(value).font(.body.monospacedDigit())
                    OutlineTag(text: row.sleepWindowPinned ? Copy.sleepPinned : Copy.sleepLearned)
                    Spacer(minLength: Spacing.regular)
                }
                .frame(minHeight: ListLayout.rowMinHeight)
            } else {
                Text(Copy.sleepNotLearned).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Backtest

    private func backtestSection(_ row: WatchmanWorkbenchStatus, several: Bool) -> some View {
        let current = phase(row)
        let isRunning = if case .running = current { true } else { false }
        return SettingsSection(
            title: Copy.backtestTitle(name: row.name, several: several),
            caption: row.lastDone.map { Copy.lastRunCaption($0) },
            isBusy: isRunning
        ) {
            switch current {
            case .neverRun:
                Text(Copy.neverRun).font(.callout).fixedSize(horizontal: false, vertical: true)
            case let .running(progress):
                VStack(alignment: .leading, spacing: Spacing.small) {
                    progressBar(progress)
                    Text(Copy.runningLine(progress)).font(.caption).foregroundStyle(.secondary)
                }
            case let .failed(message):
                HStack(alignment: .top, spacing: Spacing.regular) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tone.warning)
                    Text(Copy.failedLine(message, hasResults: row.lastDone != nil))
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .results, .notLearned, .learning:
                EmptyView()
            }
            if let lastDone = row.lastDone {
                if current != .results {
                    Text(Copy.lastResults(lastDone))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, Spacing.small)
                }
                table(lastDone).opacity(isRunning ? 0.6 : 1)
                note(Copy.barNote)
            }
            // Shown only once learning is done: the backtest is unreachable before, and the learning row shows progress.
            if row.isRelabelling { relabellingLine(row.relabelLeft) }
            if !row.analyticsOn { note(Copy.analyticsOffNote(name: row.name)) }
            if let notice = notices[row.workbench] {
                Text(notice).font(.caption).foregroundStyle(Tone.warning).fixedSize(horizontal: false, vertical: true)
            }
            backtestButton(row, phase: current).padding(.top, Spacing.small)
        }
    }

    private func relabellingLine(_ left: Int) -> some View {
        HStack(spacing: Spacing.regular) {
            ProgressView().controlSize(.small)
            Text(Copy.relabelling(left: left)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func progressBar(_ progress: String) -> some View {
        if let fraction = Copy.progressFraction(progress) {
            ProgressView(value: fraction).frame(width: ListLayout.progressBar)
        } else {
            ProgressView().progressViewStyle(.linear).frame(width: ListLayout.progressBar)
        }
    }

    @ViewBuilder
    private func backtestButton(_ row: WatchmanWorkbenchStatus, phase: WatchmanWorkbenchPhase) -> some View {
        switch phase {
        case .running:
            Button(Copy.runningButton) {}.buttonStyle(.kitPrimary).disabled(true)
        case .failed:
            Button(Copy.retry) { onRunBacktest(row.workbench) }.buttonStyle(.kitPrimary).disabled(row.isRelabelling)
        default:
            Button(Copy.runBacktest) { onRunBacktest(row.workbench) }
                .buttonStyle(.kitPrimary)
                .disabled(row.isRelabelling)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func table(_ backtest: WatchmanBacktest) -> some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            tableRow(Copy.columnCategory, Copy.columnAgreement, Copy.columnWrongHigh, Copy.handedHeader) {
                Text(Copy.columnRating)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            ForEach(Copy.tableRows(backtest), id: \.category) { row in
                VStack(alignment: .leading, spacing: 0) {
                    tableRow(row.category, Copy.agreement(row), Copy.wrongHigh(row), Copy.handedCell(row),
                             baseRate: Copy.baseRate(row)) {
                        Chip(text: Copy.rating(row), color: ratingTone(row.status))
                    }
                    .font(.callout.monospacedDigit())
                    if let handedNote = Copy.handedNote(row) {
                        Text(handedNote).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.vertical, Spacing.small)
    }

    private func tableRow(
        _ category: String,
        _ agreement: String,
        _ wrong: String,
        _ handed: String,
        baseRate: String? = nil,
        @ViewBuilder rating: () -> some View
    ) -> some View {
        HStack(spacing: Spacing.regular) {
            VStack(alignment: .leading, spacing: 0) {
                Text(category)
                if let baseRate {
                    Text(baseRate).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .frame(width: ListLayout.textColumn - Spacing.hero, alignment: .leading)
            Text(agreement).frame(width: ListLayout.numberColumn, alignment: .trailing)
            Text(wrong).frame(width: ListLayout.dateColumn, alignment: .trailing)
            Text(handed).frame(width: ListLayout.numberColumn, alignment: .trailing)
            Spacer(minLength: Spacing.medium)
            rating()
        }
        .frame(minHeight: ListLayout.lineMinHeight)
    }

    private func ratingTone(_ status: String) -> Color {
        switch status {
        case "strong": Tone.success
        case "weak": Tone.warning
        default: Tone.status("gray")
        }
    }
}
