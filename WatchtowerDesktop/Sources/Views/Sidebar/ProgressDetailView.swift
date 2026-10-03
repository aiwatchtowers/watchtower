import SwiftUI
import WatchtowerCore

/// The daemon's pipeline run history, embedded in the Usage view.
struct ProgressDetailContent: View {
    @Environment(AppState.self) private var appState
    @State private var historyVM = PipelineHistoryViewModel()
    @State private var expandedRuns: Set<Int64> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !historyVM.runs.isEmpty {
                Text("Run History")
                    .font(.title2)
                    .fontWeight(.bold)

                ForEach(historyVM.runs) { run in
                    runSection(run)
                }
            } else {
                Text("Pipeline Progress")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("No pipeline runs yet.")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if let dbPool = appState.databaseManager?.dbPool {
                historyVM.start(dbPool: dbPool)
            }
        }
        .onDisappear {
            historyVM.stop()
        }
    }

    // MARK: - Run History Section

    private func runSection(_ run: PipelineRun) -> some View {
        let isExpanded = expandedRuns.contains(run.id)

        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(run.pipelineTitle, systemImage: run.pipelineIcon)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.easeInOut(duration: 0.15), value: isExpanded)

                    Spacer()

                    Text(run.source)
                        .font(.system(size: 9))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.quaternary)
                        .cornerRadius(3)

                    runStatusBadge(run.status)

                    if run.itemsFound > 0 {
                        Text("\(run.itemsFound) items")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isExpanded {
                            expandedRuns.remove(run.id)
                        } else {
                            expandedRuns.insert(run.id)
                            historyVM.loadSteps(for: run.id)
                        }
                    }
                }

                if isExpanded {
                    runDetailContent(run)
                }
            }
            .padding(4)
        }
    }

    private func runDetailContent(_ run: PipelineRun) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 16) {
                if let date = run.startedDate {
                    detailRow(label: "Started", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                if run.durationSeconds > 0 {
                    detailRow(label: "Duration", value: formatDuration(run.durationSeconds))
                }
            }

            if run.inputTokens > 0 || run.outputTokens > 0 {
                HStack(spacing: 16) {
                    detailRow(label: "Input", value: formatTokens(run.inputTokens))
                    if run.totalApiTokens > 0 {
                        detailRow(label: "Input (+ cache)", value: formatTokens(run.totalApiTokens))
                    }
                    detailRow(label: "Output", value: formatTokens(run.outputTokens))

                }
            }

            if !run.errorMsg.isEmpty {
                Text(run.errorMsg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            // Steps
            if let steps = historyVM.steps[run.id], !steps.isEmpty {
                Divider()
                Text("Steps")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                ForEach(steps) { step in
                    dbStepRow(step)
                }
            }
        }
        .padding(.leading, 8)
    }

    private func dbStepRow(_ step: PipelineStepRecord) -> some View {
        HStack(spacing: 8) {
            Text("\(step.step)/\(step.total)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 40)

            if !step.status.isEmpty {
                Text(step.status)
                    .font(.caption2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            if step.durationSeconds > 0 {
                Text(formatDuration(step.durationSeconds))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            let stepTokens = step.inputTokens + step.outputTokens
            if stepTokens > 0 {
                Text("\(formatTokens(step.inputTokens))/\(formatTokens(step.outputTokens))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

        }
    }

    @ViewBuilder
    private func runStatusBadge(_ status: String) -> some View {
        switch status {
        case "done":
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill").font(.caption)
                Text("Done").font(.caption)
            }
            .foregroundStyle(.green)
        case "error":
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill").font(.caption)
                Text("Error").font(.caption)
            }
            .foregroundStyle(.red)
        case "running":
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.2.circlepath").font(.caption)
                Text("Running").font(.caption)
            }
            .foregroundStyle(Color.accentColor)
        default:
            Text(status).font(.caption).foregroundStyle(.secondary)
        }
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
}
