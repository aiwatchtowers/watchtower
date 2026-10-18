import SwiftUI
import WatchtowerCore

/// Section showing epic and project progress plus the active sprints and
/// cycles, designed to be embedded in weekly digest/trends views.
struct EpicProgressSection: View {
    let viewModel: EpicProgressViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Label("Epic & Project Progress", systemImage: "chart.bar.xaxis")
                    .font(.headline)
                Spacer()
                if viewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if !viewModel.iterations.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Active Sprints & Cycles")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    ForEach(viewModel.iterations) { iteration in
                        IterationProgressCard(iteration: iteration)
                    }
                }
            }

            if viewModel.epics.isEmpty && !viewModel.isLoading {
                Text("No epics or projects with 3+ issues found.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                // Epic cards
                ForEach(viewModel.epics) { item in
                    EpicCard(item: item)
                }

                // What Changed summary
                whatChangedSection
            }
        }
    }

    @ViewBuilder
    private var whatChangedSection: some View {
        let improved = viewModel.epics.filter { $0.weeklyDeltaPct > 0 }
        let noProgress = viewModel.epics.filter {
            $0.row.weeklyResolvedCount == 0 && $0.row.doneIssues < $0.row.totalIssues
        }

        if !improved.isEmpty || !noProgress.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("What Changed")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                ForEach(improved) { item in
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                        Text(item.row.name)
                            .font(.caption)
                        Text("+\(item.row.weeklyResolvedCount) resolved")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }

                ForEach(noProgress) { item in
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                        Text(item.row.name)
                            .font(.caption)
                        Text("no progress this week")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - Iteration Card

/// One active sprint (Jira) or cycle (Linear): done share and days left.
struct IterationProgressCard: View {
    let iteration: IterationProgressRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(iteration.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                if !iteration.projectKey.isEmpty {
                    Text(iteration.projectKey)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let days = iteration.daysLeft() {
                    Text(days == 1 ? "1 day left" : "\(days) days left")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ProgressView(value: iteration.progress)
            Text("\(iteration.done)/\(iteration.total) done · \(iteration.inProgress) in progress · \(iteration.todo) to do")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Epic Card

private struct EpicCard: View {
    let item: EpicProgressItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Title row
            HStack {
                Text(item.row.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(2)

                Spacer()

                statusBadge
            }

            // Progress bar
            ProgressView(value: item.row.progressPct)
                .tint(progressColor)

            // Stats row
            HStack(spacing: 12) {
                Text("\(item.row.doneIssues)/\(item.row.totalIssues)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if item.weeklyDeltaPct > 0 {
                    Text("+\(String(format: "%.0f", item.weeklyDeltaPct))% this week")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.12), in: Capsule())
                } else if item.row.weeklyResolvedCount == 0 && item.row.doneIssues < item.row.totalIssues {
                    Text("no change")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.red.opacity(0.12), in: Capsule())
                }

                Spacer()

                if let weeks = item.forecastWeeks {
                    Text("~\(String(format: "%.0f", weeks)) weeks remaining")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if item.row.doneIssues < item.row.totalIssues {
                    Text("no velocity")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            // In-progress detail
            if item.row.inProgressIssues > 0 {
                HStack(spacing: 4) {
                    Circle()
                        .fill(.blue)
                        .frame(width: 6, height: 6)
                    Text("\(item.row.inProgressIssues) in progress")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 8))
    }

    private var statusBadge: some View {
        Text(item.statusBadge.label)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(statusColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(statusColor.opacity(0.12), in: Capsule())
    }

    private var statusColor: Color {
        switch item.statusBadge {
        case .onTrack: .green
        case .atRisk: .orange
        case .behind: .red
        }
    }

    private var progressColor: Color {
        switch item.statusBadge {
        case .onTrack: .green
        case .atRisk: .orange
        case .behind: .red
        }
    }

    private var cardBackground: Color {
        switch item.statusBadge {
        case .onTrack: .green.opacity(0.04)
        case .atRisk: .orange.opacity(0.04)
        case .behind: .red.opacity(0.04)
        }
    }
}
