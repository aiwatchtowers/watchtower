import SwiftUI

/// Reusable content for pipeline progress display.
/// Used both in the standalone window (ProgressDetailView) and embedded in UsageView.
struct ProgressDetailContent: View {
    @Environment(AppState.self) private var appState
    @State private var expandedSteps: Set<UUID> = []

    var body: some View {
        let manager = appState.backgroundTaskManager

        VStack(alignment: .leading, spacing: 16) {
            header(manager)
            costSummary(manager)

            ForEach(BackgroundTaskManager.TaskKind.allCases) { kind in
                if let state = manager.tasks[kind] {
                    taskSection(kind: kind, state: state)
                }
            }
        }
    }

    // MARK: - Header

    private func header(_ manager: BackgroundTaskManager) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Pipeline Progress")
                .font(.title2)
                .fontWeight(.bold)

            if manager.allFinished {
                Text("All pipelines completed")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if manager.hasActiveTasks {
                Text("Processing...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Cost Summary

    private func costSummary(_ manager: BackgroundTaskManager) -> some View {
        GroupBox("Session Cost") {
            VStack(spacing: 8) {
                HStack(spacing: 24) {
                    costItem(
                        label: "Input (clean)",
                        value: formatTokens(manager.totalInputTokens)
                    )
                    costItem(
                        label: "Input (API)",
                        value: formatTokens(manager.totalApiTokens)
                    )
                    costItem(
                        label: "Output",
                        value: formatTokens(manager.totalOutputTokens)
                    )
                    costItem(
                        label: "Cost",
                        value: String(format: "$%.4f", manager.totalCostUsd)
                    )
                }
            }
            .padding(4)
        }
    }

    private func costItem(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline)
                .fontWeight(.bold)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Task Section

    private func taskSection(
        kind: BackgroundTaskManager.TaskKind,
        state: BackgroundTaskManager.TaskState
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    statusBadge(state.status)
                    Spacer()
                    if let progress = state.progress, progress.total > 0 {
                        Text("\(progress.done)/\(progress.total)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let eta = state.etaSeconds, state.status == .running {
                        Text(formatETA(eta))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if state.status == .running, let prog = state.progress {
                    if prog.total > 0 {
                        ProgressView(value: Double(prog.done), total: Double(max(prog.total, 1)))
                            .tint(.accentColor)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if let status = prog.status, !status.isEmpty {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                if case .error(let msg) = state.status {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)

                    Button("Retry") {
                        appState.backgroundTaskManager.retry(kind)
                    }
                    .font(.caption2)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }

                if !state.stepHistory.isEmpty {
                    Divider()
                    stepHistorySection(state.stepHistory)
                }
            }
            .padding(4)
        } label: {
            Label(kind.title, systemImage: kind.icon)
        }
    }

    private func stepHistorySection(_ history: [BackgroundTaskManager.StepRecord]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Step History")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            let taskInput = history.reduce(0) { $0 + $1.inputTokens }
            let taskAPI = history.reduce(0) { $0 + $1.totalApiTokens }
            let taskOutput = history.reduce(0) { $0 + $1.outputTokens }
            let taskCost = history.reduce(0.0) { $0 + $1.costUsd }

            HStack(spacing: 16) {
                let apiLabel = taskAPI > 0 ? " / api \(formatTokens(taskAPI))" : ""
                Text("clean \(formatTokens(taskInput))\(apiLabel) in, \(formatTokens(taskOutput)) out")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(String(format: "$%.4f", taskCost))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ForEach(history.reversed()) { record in
                stepRow(record)
            }
        }
    }

    // MARK: - Step Row

    private func stepRow(_ record: BackgroundTaskManager.StepRecord) -> some View {
        let isExpanded = expandedSteps.contains(record.id)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(record.timestamp, style: .time)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)

                Text("\(record.step)/\(record.total)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 40)

                if !record.status.isEmpty {
                    Text(record.status)
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()

                if record.durationSeconds > 0 {
                    Text(formatDuration(record.durationSeconds))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                let stepTokens = record.inputTokens + record.outputTokens
                if stepTokens > 0 {
                    let apiLabel = record.totalApiTokens > 0 ? "(\(formatTokens(record.totalApiTokens)))" : ""
                    Text("\(formatTokens(record.inputTokens))\(apiLabel)/\(formatTokens(record.outputTokens))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.easeInOut(duration: 0.15), value: isExpanded)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if isExpanded {
                        expandedSteps.remove(record.id)
                    } else {
                        expandedSteps.insert(record.id)
                    }
                }
            }

            if isExpanded {
                stepDetail(record)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: - Step Detail

    private func stepDetail(_ record: BackgroundTaskManager.StepRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
                .padding(.vertical, 4)

            detailRow(label: "Duration", value: formatDuration(record.durationSeconds))

            let hasTokens = record.inputTokens + record.outputTokens > 0
            if hasTokens {
                detailRow(label: "Input (clean)", value: formatTokens(record.inputTokens))
                if record.totalApiTokens > 0 {
                    detailRow(label: "Input (API)", value: formatTokens(record.totalApiTokens))
                }
                detailRow(label: "Output", value: formatTokens(record.outputTokens))
            }

            if record.costUsd > 0 {
                detailRow(label: "Cost", value: String(format: "$%.4f", record.costUsd))
            }

            if record.durationSeconds > 0 && record.outputTokens > 0 {
                detailRow(
                    label: "Speed",
                    value: String(format: "%.0f tok/s", Double(record.outputTokens) / record.durationSeconds)
                )
            }

            if let count = record.messageCount, count > 0 {
                detailRow(label: "Messages", value: "\(count)")
            }

            if let periodStr = formatStepPeriod(record) {
                detailRow(label: "Period", value: periodStr)
            }
        }
        .padding(.leading, 24)
        .padding(.bottom, 4)
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func statusBadge(_ status: BackgroundTaskManager.TaskStatus) -> some View {
        switch status {
        case .pending:
            HStack(spacing: 4) {
                Image(systemName: "clock").font(.caption)
                Text("Pending").font(.caption)
            }
            .foregroundStyle(.secondary)
        case .running:
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.2.circlepath").font(.caption)
                Text("Running").font(.caption)
            }
            .foregroundStyle(Color.accentColor)
        case .done:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill").font(.caption)
                Text("Done").font(.caption)
            }
            .foregroundStyle(.green)
        case .error:
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill").font(.caption)
                Text("Error").font(.caption)
            }
            .foregroundStyle(.red)
        }
    }

    private func formatETA(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "~\(max(s, 1))s left" }
        let min = s / 60
        let rem = s % 60
        if rem == 0 { return "~\(min)m left" }
        return "~\(min)m \(rem)s left"
    }

    private func formatDuration(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(max(s, 1))s" }
        let min = s / 60
        let rem = s % 60
        return "\(min)m \(rem)s"
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

    private func formatStepPeriod(_ record: BackgroundTaskManager.StepRecord) -> String? {
        guard let from = record.periodFrom, let to = record.periodTo else { return nil }
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        let fromDate = Date(timeIntervalSince1970: from)
        let toDate = Date(timeIntervalSince1970: to)
        return "\(df.string(from: fromDate)) - \(df.string(from: toDate))"
    }
}

/// Standalone window wrapper for ProgressDetailContent.
struct ProgressDetailView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollView {
            ProgressDetailContent()
                .environment(appState)
                .padding(20)
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}
