import SwiftUI
import Charts
import WatchtowerCore

struct ChannelStatisticsView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel: ChannelStatsViewModel?

    /// Nothing synced to count yet: the shared empty state.
    static func emptyState(context: EmptyStateContext) -> some View {
        TabEmptyState(.statistics, context: context)
    }

    var body: some View {
        Group {
            if let vm = viewModel {
                channelContent(vm)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if let db = appState.databaseManager, viewModel == nil {
                viewModel = ChannelStatsViewModel(dbManager: db)
            }
            viewModel?.startObserving()
        }
        .onDisappear { viewModel?.stopObserving() }
    }

    private func channelContent(_ vm: ChannelStatsViewModel) -> some View {
        VStack(spacing: 0) {
            toolbar(vm)
            Divider()

            if vm.isLoading && vm.stats.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.stats.isEmpty, let error = vm.errorMessage {
                ErrorView(title: "Error", message: error, actionTitle: "Retry") { vm.load() }
            } else if vm.stats.isEmpty {
                Self.emptyState(context: appState.emptyStateContext)
            } else {
                // A failed toggle keeps the table and says why (board #670).
                if let error = vm.errorMessage {
                    WriteErrorBanner(message: error) { vm.errorMessage = nil }
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        // Summary cards
                        summaryCards(vm)

                        // Charts row
                        chartsSection(vm)

                        // Recommendations section
                        if !vm.recommendations.isEmpty && vm.filter != .muted && vm.filter != .notSynced {
                            ChannelRecommendationsSection(vm: vm)
                        }

                        // Channel table
                        ChannelStatsTable(vm: vm)

                        // Hidden channels note
                        if vm.hiddenChannelCount > 0 {
                            hiddenChannelsBar(vm)
                        }
                    }
                    .padding()
                }
            }
        }
    }

    // MARK: - Summary Cards

    private func summaryCards(_ vm: ChannelStatsViewModel) -> some View {
        HStack(spacing: 12) {
            summaryCard(title: "Channels", value: "\(vm.totalChannels)",
                        subtitle: "\(vm.activeChannels) active this week", icon: "number", color: .blue)
            summaryCard(title: "Messages", value: formatNumber(vm.totalMessages),
                        subtitle: "\(vm.mutedChannels) muted", icon: "message", color: .green)
            summaryCard(title: "Digests", value: "\(vm.digestedChannels)",
                        subtitle: "\(vm.pendingDigestChannels) pending", icon: "doc.text", color: .purple)
            summaryCard(title: "Favorites", value: "\(vm.favoriteChannels)",
                        subtitle: "\(vm.recommendationCount) recommendations", icon: "star", color: .yellow)
        }
    }

    private func summaryCard(title: String, value: String, subtitle: String,
                             icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .font(.caption)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.title2.weight(.semibold).monospacedDigit())
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary, lineWidth: 1)
        )
    }

    // MARK: - Charts

    private func chartsSection(_ vm: ChannelStatsViewModel) -> some View {
        HStack(alignment: .top, spacing: 12) {
            topChannelsChart(vm)
            botChannelsChart(vm)
        }
    }

    // MARK: Top Channels — stacked human/bot bars

    private struct StackedBarItem: Identifiable {
        let id: String
        let name: String
        let category: String // "Human" or "Bot"
        let count: Int
        let isMuted: Bool
    }

    private func topChannelsChart(_ vm: ChannelStatsViewModel) -> some View {
        let top = Array(vm.stats
            .filter { $0.totalMessages > 0 }
            .sorted { $0.totalMessages > $1.totalMessages }
            .prefix(10))

        // Build stacked data — reversed so Chart renders top-to-bottom correctly
        let items: [StackedBarItem] = top.reversed().flatMap { stat -> [StackedBarItem] in
            let human = stat.totalMessages - stat.botMessages
            return [
                StackedBarItem(id: "\(stat.id)-human", name: stat.name, category: "Human", count: human, isMuted: stat.isMutedForLLM),
                StackedBarItem(id: "\(stat.id)-bot", name: stat.name, category: "Bot", count: stat.botMessages, isMuted: stat.isMutedForLLM),
            ]
        }

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Top Channels")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                HStack(spacing: 12) {
                    legendDot(color: .blue, label: "Human")
                    legendDot(color: .red.opacity(0.7), label: "Bot")
                }
            }

            if top.isEmpty {
                Text("Nothing to chart yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Chart(items) { item in
                    BarMark(
                        x: .value("Messages", item.count),
                        y: .value("Channel", item.name)
                    )
                    .foregroundStyle(item.category == "Bot" ? Color.red.opacity(0.7) : Color.blue)
                }
                .chartXAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let v = value.as(Int.self) {
                                Text(formatNumber(v))
                                    .font(.caption2)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks { value in
                        AxisValueLabel {
                            if let name = value.as(String.self) {
                                Text("#\(name)")
                                    .font(.caption)
                                    .lineLimit(1)
                                    .frame(width: 130, alignment: .trailing)
                            }
                        }
                    }
                }
                .frame(height: CGFloat(top.count * 28 + 20))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary, lineWidth: 1)
        )
    }

    // MARK: Bot Channels — channels with highest bot ratio

    private struct BotChannelItem: Identifiable {
        var id: String { channelID }
        let channelID: String
        let name: String
        let botPercent: Int
        let totalMessages: Int
        let isMuted: Bool
    }

    private func botChannelsChart(_ vm: ChannelStatsViewModel) -> some View {
        let botChannels = vm.stats
            .filter { $0.botRatio > 0.3 && $0.totalMessages >= 10 }
            .sorted { $0.botRatio > $1.botRatio }
            .prefix(12)
            .map { BotChannelItem(channelID: $0.id, name: $0.name, botPercent: Int($0.botRatio * 100),
                                  totalMessages: $0.totalMessages, isMuted: $0.isMutedForLLM) }

        return VStack(alignment: .leading, spacing: 8) {
            Text("Bot-Heavy Channels")
                .font(.subheadline.weight(.semibold))

            if botChannels.isEmpty {
                Text("No bot-heavy channels")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 4) {
                    ForEach(botChannels) { ch in
                        HStack(spacing: 8) {
                            Text("#\(ch.name)")
                                .font(.caption)
                                .lineLimit(1)
                                .frame(width: 120, alignment: .leading)

                            // Bot ratio bar
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.secondary.opacity(0.15))
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(botColor(ch.botPercent))
                                        .frame(width: geo.size.width * CGFloat(ch.botPercent) / 100)
                                }
                            }
                            .frame(height: 14)

                            Text("\(ch.botPercent)%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(botColor(ch.botPercent))
                                .frame(width: 36, alignment: .trailing)

                            if ch.isMuted {
                                Image(systemName: "speaker.slash.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }

                // Digest coverage donut below
                Divider()
                    .padding(.vertical, 4)
                digestCoverageMini(vm)
            }
        }
        .padding(12)
        .frame(width: 320)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary, lineWidth: 1)
        )
    }

    private func botColor(_ percent: Int) -> Color {
        if percent >= 80 { return .red }
        if percent >= 50 { return .orange }
        return .yellow
    }

    // MARK: Digest Coverage Mini

    private func digestCoverageMini(_ vm: ChannelStatsViewModel) -> some View {
        let statuses = computeDigestDistribution(vm)
        let nonZero = statuses.filter { $0.count != 0 } // swiftlint:disable:this empty_count

        return VStack(alignment: .leading, spacing: 6) {
            Text("Digest Coverage")
                .font(.caption.weight(.semibold))

            HStack(spacing: 0) {
                ForEach(nonZero, id: \.label) { item in
                    Rectangle()
                        .fill(item.color)
                        .frame(height: 8)
                        .frame(maxWidth: .infinity)
                        .scaleEffect(x: CGFloat(item.count) / CGFloat(max(vm.totalChannels, 1)), anchor: .leading)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .frame(height: 8)

            // Stacked bar percentage
            HStack(spacing: 8) {
                ForEach(nonZero, id: \.label) { item in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(item.color)
                            .frame(width: 6, height: 6)
                        Text("\(item.label) \(item.count)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private struct DigestDistItem {
        let label: String
        let count: Int
        let color: Color
    }

    private func computeDigestDistribution(_ vm: ChannelStatsViewModel) -> [DigestDistItem] {
        var upToDate = 0, pending = 0, never = 0, tooFew = 0, muted = 0
        for s in vm.stats {
            switch s.digestStatus {
            case .upToDate: upToDate += 1
            case .pending: pending += 1
            case .neverProcessed: never += 1
            case .tooFewMessages: tooFew += 1
            case .muted: muted += 1
            }
        }
        return [
            DigestDistItem(label: "OK", count: upToDate, color: .green),
            DigestDistItem(label: "Pending", count: pending, color: .orange),
            DigestDistItem(label: "New", count: never, color: .blue),
            DigestDistItem(label: "Few", count: tooFew, color: .gray),
            DigestDistItem(label: "Muted", count: muted, color: .red),
        ]
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Toolbar

    private func toolbar(_ vm: ChannelStatsViewModel) -> some View {
        HStack(spacing: 12) {
            ChannelStatsFilterPicker(vm: vm)

            Spacer()

            Picker("Sort", selection: Binding(
                get: { vm.sortOrder },
                set: { vm.sortOrder = $0 }
            )) {
                ForEach(ChannelStatsViewModel.SortOrder.allCases, id: \.self) { sort in
                    Text(sort.rawValue).tag(sort)
                }
            }
            .frame(width: 130)

            TextField("Search channels...", text: Binding(
                get: { vm.searchText },
                set: { vm.searchText = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 180)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Hidden Channels Bar

    private func hiddenChannelsBar(_ vm: ChannelStatsViewModel) -> some View {
        HStack {
            Image(systemName: "eye.slash")
                .foregroundStyle(.secondary)
            Text("\(vm.hiddenChannelCount) channels hidden (< \(vm.minMessages) messages)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(vm.showAllChannels ? "Hide small channels" : "Show all channels") {
                vm.showAllChannels.toggle()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary, lineWidth: 1)
        )
    }

    // MARK: - Helpers

    private func formatNumber(_ n: Int) -> String {
        if n >= 1000 {
            return String(format: "%.1fK", Double(n) / 1000.0)
        }
        return "\(n)"
    }
}
