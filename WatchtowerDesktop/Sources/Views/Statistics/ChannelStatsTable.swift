import DesignKit
import SwiftUI
import WatchtowerCore

private typealias Copy = ChannelStatsPresentation

/// Statistics → Channels' filter: All, Muted, Favorites, Recommendations,
/// Not synced.
struct ChannelStatsFilterPicker: View {
    let vm: ChannelStatsViewModel

    var body: some View {
        KitSegmentedPicker(
            title: "Filter",
            selection: Binding(get: { vm.filter }, set: { vm.filter = $0 }),
            segments: ChannelStatsViewModel.Filter.allCases.map { KitSegment(value: $0, title: $0.rawValue) }
        )
    }
}

/// The suggestions card: mute, Stop syncing, leave (applied as a mute) and
/// favorite, each group with its own apply button.
struct ChannelRecommendationsSection: View {
    let vm: ChannelStatsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.regular) {
            Text("Recommendations")
                .font(.headline)

            let grouped = Dictionary(grouping: vm.recommendations, by: \.action)

            ForEach([ChannelRecommendation.Action.mute, .exclude, .leave, .favorite], id: \.self) { action in
                if let recs = grouped[action], !recs.isEmpty {
                    group(action: action, recs: recs)
                }
            }
        }
        .padding()
        .card()
    }

    private func group(action: ChannelRecommendation.Action, recs: [ChannelRecommendation]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            HStack(spacing: Spacing.compact) {
                Image(systemName: Self.icon(action))
                    .foregroundStyle(Self.color(action))
                Text(Self.title(action))
                    .font(.subheadline.weight(.semibold))
                Text("(\(recs.count))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(recs) { rec in
                HStack {
                    Text("#\(rec.channelName)")
                        .font(.body.monospaced())
                    Text(rec.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(Self.buttonLabel(rec.action)) {
                        Task { await vm.applyRecommendation(rec) }
                    }
                    .buttonStyle(.kitSecondary)
                    .help(rec.action == .exclude ? Copy.stopSyncingHelp : "")
                    .disabled(rec.action == .exclude && vm.isSyncPending(rec.channelID))
                }
                .padding(.leading, Spacing.wide - Spacing.tight)
            }
        }
    }

    private static func icon(_ action: ChannelRecommendation.Action) -> String {
        switch action {
        case .mute: "speaker.slash"
        case .exclude: "icloud.slash"
        case .leave: "rectangle.portrait.and.arrow.right"
        case .favorite: "star"
        }
    }

    private static func color(_ action: ChannelRecommendation.Action) -> Color {
        switch action {
        case .mute: Tone.warning
        case .exclude: Tone.status("gray")
        case .leave: Tone.error
        case .favorite: Tone.amber
        }
    }

    private static func title(_ action: ChannelRecommendation.Action) -> String {
        switch action {
        case .mute: "Suggest Mute"
        case .exclude: Copy.suggestionTitle
        case .leave: "Suggest Leave"
        case .favorite: "Suggest Favorite"
        }
    }

    private static func buttonLabel(_ action: ChannelRecommendation.Action) -> String {
        switch action {
        case .mute, .leave: "Mute"
        case .exclude: Copy.stopSyncing
        case .favorite: "Favorite"
        }
    }
}

/// The channel table: one row per channel with its counts, digest status,
/// mute / favorite toggles and the Stop syncing / Sync again button. Under
/// the Not synced filter a caption says what Stop syncing keeps.
struct ChannelStatsTable: View {
    let vm: ChannelStatsViewModel

    var body: some View {
        let filtered = vm.filteredStats
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            if vm.filter == .notSynced {
                Text(Copy.notSyncedCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if vm.filter == .notSynced && !vm.hasNotSyncedChannels {
                Text(Copy.notSyncedEmpty)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, Spacing.wide)
            } else {
                table(filtered)
            }
        }
    }

    private func table(_ filtered: [ChannelStat]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if filtered.isEmpty {
                Text("No channels match the current filter")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Spacing.page)
            } else {
                ForEach(filtered) { stat in
                    row(stat)
                }
            }
        }
        .card()
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("Channel")
                .frame(minWidth: 150, alignment: .leading)
            Text("Messages")
                .frame(width: 70, alignment: .trailing)
            Text("Yours")
                .frame(width: 50, alignment: .trailing)
            Text("Bot %")
                .frame(width: 50, alignment: .trailing)
            Text("Mentions")
                .frame(width: 60, alignment: .trailing)
            Text("Activity")
                .frame(width: 80, alignment: .trailing)
            Text("Digest")
                .frame(width: 100, alignment: .center)
            Text("Status")
                .frame(width: 140, alignment: .center)
            Spacer()
                .frame(width: 60)
            Spacer()
                .frame(width: 110)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, Spacing.regular)
        .padding(.vertical, Spacing.compact)
    }

    private func row(_ stat: ChannelStat) -> some View {
        HStack(spacing: 0) {
            name(stat)
                .foregroundStyle(stat.isSyncExcluded ? .secondary : .primary)
                .frame(minWidth: 150, alignment: .leading)

            Text("\(stat.totalMessages)")
                .frame(width: 70, alignment: .trailing)
                .monospacedDigit()

            Text("\(stat.userMessages)")
                .frame(width: 50, alignment: .trailing)
                .monospacedDigit()

            Text("\(Int(stat.botRatio * 100))%")
                .frame(width: 50, alignment: .trailing)
                .foregroundStyle(stat.botRatio > 0.8 ? Tone.error : stat.botRatio > 0.5 ? Tone.warning : .primary)
                .monospacedDigit()

            Text("\(stat.mentionCount)")
                .frame(width: 60, alignment: .trailing)
                .monospacedDigit()

            Text(Self.lastActivityText(stat))
                .frame(width: 80, alignment: .trailing)
                .foregroundStyle(Self.lastActivityColor(stat))
                .font(.caption)

            HStack(spacing: Spacing.tight) {
                Image(systemName: stat.digestStatus.icon)
                    .foregroundStyle(stat.digestStatus.color)
                Text(stat.digestStatus.label)
            }
            .font(.caption)
            .frame(width: 100, alignment: .center)
            .help(Self.digestHelp(stat))

            status(stat)
                .frame(width: 140, alignment: .center)

            toggles(stat)
                .frame(width: 60, alignment: .center)

            syncButton(stat)
                .frame(width: 110, alignment: .trailing)
        }
        .font(.body)
        .kitRow(isSelected: false)
    }

    @ViewBuilder
    private func name(_ stat: ChannelStat) -> some View {
        if let url = vm.slackURL(for: stat.id) {
            Link(destination: url) {
                HStack(spacing: Spacing.tight) {
                    Text("#\(stat.name)")
                        .lineLimit(1)
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption2)
                }
            }
        } else {
            Text("#\(stat.name)")
                .lineLimit(1)
        }
    }

    /// The mute, favorite and archive marks, then the sync tag.
    private func status(_ stat: ChannelStat) -> some View {
        HStack(spacing: Spacing.small) {
            if stat.isMutedForLLM {
                Image(systemName: "speaker.slash.fill")
                    .font(.caption)
                    .foregroundStyle(Tone.warning)
                    .help("Muted for AI")
            }
            if stat.isFavorite {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(Tone.amber)
                    .help("Favorite")
            }
            if stat.isArchived {
                Image(systemName: "archivebox.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Archived")
            }
            switch stat.syncState {
            case .synced:
                EmptyView()
            case .notSynced:
                OutlineTag(text: Copy.notSyncedTag)
            case .catchingUp(let since):
                Chip(text: Copy.catchingUpTag, color: Tone.status("blue"), dot: true)
                    .help(Copy.catchingUpCaption(since: since))
            }
        }
    }

    /// The row's mute and favorite toggles; each waits while its write does.
    private func toggles(_ stat: ChannelStat) -> some View {
        HStack(spacing: Spacing.small) {
            Button {
                Task { await vm.toggleMute(channelID: stat.id) }
            } label: {
                Image(systemName: stat.isMutedForLLM ? "speaker.wave.2" : "speaker.slash")
                    .font(.caption)
            }
            .buttonStyle(.kitQuiet)
            .disabled(vm.isMutePending(stat.id))
            .help(stat.isMutedForLLM ? "Unmute for AI" : "Mute for AI")

            Button {
                Task { await vm.toggleFavorite(channelID: stat.id) }
            } label: {
                Image(systemName: stat.isFavorite ? "star.slash" : "star")
                    .font(.caption)
            }
            .buttonStyle(.kitQuiet)
            .disabled(vm.isFavoritePending(stat.id))
            .help(stat.isFavorite ? "Remove favorite" : "Add favorite")
        }
    }

    /// Stop syncing, or Sync again for an excluded channel. Stop syncing
    /// works during a catch-up too: the next Sync again covers the old
    /// window as well (`SetSyncExcluded`).
    private func syncButton(_ stat: ChannelStat) -> some View {
        let excluded = stat.syncState == .notSynced
        return Button(excluded ? Copy.syncAgain : Copy.stopSyncing) {
            Task { await vm.toggleSyncExcluded(channelID: stat.id) }
        }
        .buttonStyle(.kitQuiet)
        .help(excluded ? Copy.syncAgainHelp : Copy.stopSyncingHelp)
        .disabled(vm.isSyncPending(stat.id))
    }

    // MARK: - Helpers

    private static func lastActivityText(_ stat: ChannelStat) -> String {
        guard let days = stat.lastActivityDaysAgo else { return "Never" }
        if days == 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        if days < 7 { return "\(days)d ago" }
        if days < 30 { return "\(days / 7)w ago" }
        return "\(days / 30)mo ago"
    }

    private static func lastActivityColor(_ stat: ChannelStat) -> Color {
        guard let days = stat.lastActivityDaysAgo else { return .secondary }
        if days <= 1 { return Tone.success }
        if days <= 7 { return .primary }
        if days <= 30 { return Tone.warning }
        return Tone.error
    }

    private static func digestHelp(_ stat: ChannelStat) -> String {
        if stat.digestCount == 0 {
            return "No digests generated"
        }
        var text = "\(stat.digestCount) digests"
        if let lastAt = stat.lastDigestAt {
            text += "\nLast: \(String(lastAt.prefix(10)))"
        }
        if stat.messagesSinceDigest > 0 {
            text += "\n\(stat.messagesSinceDigest) new messages"
        }
        return text
    }
}
