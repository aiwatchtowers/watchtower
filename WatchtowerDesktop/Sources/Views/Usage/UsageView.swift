import SwiftUI
import GRDB
import WatchtowerCore

struct UsageView: View {
    @Environment(AppState.self) private var appState
    static let selectedTabKey = "usage.selectedTab"
    @AppStorage(Self.selectedTabKey) private var selectedTab: Tab = .plan
    @State private var viewModel = PipelineHistoryViewModel()

    enum Tab: String, CaseIterable {
        case plan = "Claude plan"
        case watchtower = "Watchtower"
        case progress = "Progress"
        case usage = "Usage"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)

            switch selectedTab {
            case .plan:
                ClaudePlanView()
            case .watchtower:
                WatchtowerUsageView()
            case .progress:
                ScrollView {
                    ProgressDetailContent()
                        .environment(appState)
                        .padding(20)
                }
            case .usage:
                UsageRunLogContent(viewModel: viewModel) { selectedTab = .watchtower }
            }
        }
        .onAppear {
            if let db = appState.databaseManager {
                viewModel.start(dbPool: db.dbPool)
            }
        }
        .onDisappear {
            viewModel.stop()
        }
    }
}

/// The Usage tab's run log: one day of `pipeline_runs`, status, duration,
/// items and errors. Tokens and cost live on the Watchtower tab (`onOpenWatchtower`).
struct UsageRunLogContent: View {
    let viewModel: PipelineHistoryViewModel
    let onOpenWatchtower: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header with day picker
                HStack {
                    Text("AI Usage Log")
                        .font(.title2)
                        .fontWeight(.bold)
                    Spacer()
                    dayPicker
                }

                UsageTokensPointer(buttonTitle: "Open Watchtower tab", onOpen: onOpenWatchtower)
                    .font(.callout)

                if viewModel.isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else if viewModel.runs.isEmpty {
                    Text("No AI calls on this day.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 32)
                } else {
                    runsList
                }
            }
            .padding(20)
        }
    }

    // MARK: - Day Picker

    private var dayPicker: some View {
        HStack(spacing: 8) {
            Button { viewModel.goToPreviousDay() } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)

            Text(viewModel.selectedDate, style: .date)
                .font(.subheadline)
                .monospacedDigit()
                .frame(minWidth: 100)

            Button { viewModel.goToNextDay() } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.isToday)

            Button("Today") { viewModel.goToToday() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.isToday)
        }
    }

    // MARK: - Runs List

    private var runsList: some View {
        GroupBox("Requests") {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(viewModel.runs) { run in
                    RunRow(run: run, steps: viewModel.steps[run.id]) {
                        viewModel.loadSteps(for: run.id)
                    }
                    if run.id != viewModel.runs.last?.id {
                        Divider()
                    }
                }
            }
        }
    }
}

// MARK: - Run Row

private struct RunRow: View {
    let run: PipelineRun
    let steps: [PipelineStepRecord]?
    let onExpand: () -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row
            Button {
                isExpanded.toggle()
                if isExpanded { onExpand() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 12)

                    Image(systemName: run.pipelineIcon)
                        .foregroundStyle(pipelineColor(run.pipeline))
                        .frame(width: 18)

                    Text(run.pipelineTitle)
                        .fontWeight(.medium)
                        .frame(width: 100, alignment: .leading)

                    Text(run.model)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer()

                    if run.status == "error" {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }

                    if run.aiCallCount > 1 {
                        Text("\(run.aiCallCount) calls")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Text(run.source)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary)
                        .clipShape(Capsule())

                    Text(timeString(run.startedAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 55, alignment: .trailing)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded steps
            if isExpanded {
                expandedContent
                    .padding(.leading, 30)
                    .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Run details
            HStack(spacing: 16) {
                if run.durationSeconds > 0 {
                    Label(String(format: "%.1fs", run.durationSeconds), systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if run.itemsFound > 0 {
                    Label("\(run.itemsFound) items", systemImage: "number")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 4)

            if !run.errorMsg.isEmpty {
                Text(run.errorMsg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.bottom, 4)
            }

            // Steps
            if let steps, !steps.isEmpty {
                ForEach(steps) { step in
                    HStack(spacing: 8) {
                        Text("\(step.step)/\(step.total)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(width: 30, alignment: .trailing)

                        Text(step.channelName.isEmpty ? "step \(step.step)" : "#\(step.channelName)")
                            .font(.caption)
                            .lineLimit(1)

                        Spacer()

                        if step.messageCount > 0 {
                            Text("\(step.messageCount) msgs")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                    }
                    .padding(.vertical, 1)
                }
            } else if steps == nil {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private func pipelineColor(_ pipeline: String) -> Color {
        switch pipeline {
        case "digests": return .blue
        case "tracks": return .orange
        case "people": return .purple
        case "briefing": return .green
        case "inbox": return .cyan
        default: return .gray
        }
    }
}

// MARK: - Formatting Helpers

private func timeString(_ iso: String) -> String {
    let fmt = ISO8601DateFormatter()
    guard let date = fmt.date(from: iso) else { return "" }
    let df = DateFormatter()
    df.dateFormat = "HH:mm"
    return df.string(from: date)
}
