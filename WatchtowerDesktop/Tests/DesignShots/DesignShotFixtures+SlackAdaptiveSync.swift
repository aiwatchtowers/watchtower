import AppKit
import DesignKit
import SwiftUI

/// Design-only scenes for Statistics → Channels in the adaptive Slack sync
/// plan (`docs/superpowers/plans/2026-11-15-slack-adaptive-sync.md`, Task 6):
/// the row's Stop syncing / Sync again button, the Stop syncing suggestion
/// and the Not synced filter. Nothing here is wired into the app; the
/// strings are `SlackAdaptiveSyncMockCopy`. Sample data only.
@MainActor
enum SlackAdaptiveSyncShotFixtures {
    static var shots: [DesignShot] {
        [
            DesignShot(name: "slack-as-rows", size: NSSize(width: 860, height: 0)) {
                AnyView(StatsRowsMock(rows: MockRow.mixed))
            },
            DesignShot(name: "slack-as-suggestion", size: NSSize(width: 860, height: 0)) {
                AnyView(StatsSuggestionMock())
            },
            DesignShot(name: "slack-as-filter-notsynced", size: NSSize(width: 860, height: 0)) {
                AnyView(StatsNotSyncedMock(rows: MockRow.excluded))
            },
            DesignShot(name: "slack-as-filter-notsynced-empty", size: NSSize(width: 860, height: 0)) {
                AnyView(StatsNotSyncedMock(rows: []))
            }
            // No narrow frame: Statistics → Channels is the existing wide table
            // (fixed column widths), which this change does not reflow.
        ]
    }
}

private typealias Copy = SlackAdaptiveSyncMockCopy

/// One channel row of the mock table.
private struct MockRow: Identifiable {
    enum State { case synced, excluded, catchingUp }
    let id: String
    let name: String
    let total: Int
    let mine: Int
    let botPercent: Int
    let mentions: Int
    let muted: Bool
    let state: State

    static let mixed: [Self] = [
        Self(id: "1", name: "team-core", total: 412, mine: 37, botPercent: 4, mentions: 9, muted: false, state: .synced),
        Self(id: "2", name: "alerts-prod", total: 2_904, mine: 0, botPercent: 96, mentions: 0, muted: true, state: .excluded),
        Self(id: "3", name: "random", total: 655, mine: 2, botPercent: 11, mentions: 1, muted: false, state: .catchingUp),
        Self(id: "4", name: "deploys", total: 1_318, mine: 0, botPercent: 88, mentions: 0, muted: true, state: .synced)
    ]
    static let excluded: [Self] = [
        Self(id: "2", name: "alerts-prod", total: 2_904, mine: 0, botPercent: 96, mentions: 0, muted: true, state: .excluded),
        Self(id: "5", name: "ci-builds", total: 5_120, mine: 0, botPercent: 99, mentions: 0, muted: true, state: .excluded)
    ]
}

private struct StatsRowsMock: View {
    let rows: [MockRow]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ForEach(rows) { row in
                rowView(row)
                Divider()
            }
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("Channel").frame(minWidth: 150, alignment: .leading)
            Spacer(minLength: 8)
            Text("Msgs").frame(width: 60, alignment: .trailing)
            Text("Mine").frame(width: 50, alignment: .trailing)
            Text("Bots").frame(width: 50, alignment: .trailing)
            Text("@you").frame(width: 50, alignment: .trailing)
            Text("Status").frame(width: 120, alignment: .center)
            Text("").frame(width: 120)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func rowView(_ row: MockRow) -> some View {
        HStack(spacing: 0) {
            Text("#\(row.name)")
                .lineLimit(1)
                .foregroundStyle(row.state == .excluded ? .secondary : .primary)
                .frame(minWidth: 150, alignment: .leading)
            Spacer(minLength: 8)
            Text("\(row.total)").monospacedDigit().frame(width: 60, alignment: .trailing)
            Text("\(row.mine)").monospacedDigit().frame(width: 50, alignment: .trailing)
            Text("\(row.botPercent)%").monospacedDigit().frame(width: 50, alignment: .trailing)
            Text("\(row.mentions)").monospacedDigit().frame(width: 50, alignment: .trailing)
            HStack(spacing: 4) {
                if row.muted {
                    Image(systemName: "speaker.slash.fill").font(.caption).foregroundStyle(Tone.warning)
                }
                switch row.state {
                case .synced: EmptyView()
                case .excluded: OutlineTag(text: Copy.notSyncedTag)
                case .catchingUp: Chip(text: Copy.catchingUpTag, color: Tone.status("blue"), dot: true)
                }
            }
            .frame(width: 120, alignment: .center)
            Group {
                if row.state == .excluded {
                    Button(Copy.syncAgain) {}.buttonStyle(.kitQuiet).help(Copy.syncAgainHelp)
                } else {
                    Button(Copy.stopSyncing) {}
                        .buttonStyle(.kitQuiet)
                        .help(Copy.stopSyncingHelp)
                        .disabled(row.state == .catchingUp)
                }
            }
            .frame(width: 120, alignment: .trailing)
        }
        .font(.body)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

private struct StatsSuggestionMock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recommendations").font(.headline)
            HStack(spacing: 6) {
                Image(systemName: "icloud.slash").foregroundStyle(Tone.status("gray"))
                Text(Copy.suggestionTitle).font(.subheadline.weight(.semibold))
                Text("(2)").font(.caption).foregroundStyle(.secondary)
            }
            suggestion("ci-builds", Copy.reasonBots(99))
            suggestion("old-project-x", Copy.reasonMuted)
        }
        .padding()
        .card()
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func suggestion(_ name: String, _ reason: String) -> some View {
        HStack {
            Text("#\(name)").font(.body.monospaced())
            Text(reason).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button(Copy.stopSyncing) {}.buttonStyle(.kitSecondary)
        }
        .padding(.leading, 22)
    }
}

private struct StatsNotSyncedMock: View {
    let rows: [MockRow]
    @State private var filter = Copy.filterNotSynced

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            KitSegmentedPicker(title: "Filter", selection: $filter, segments: [
                KitSegment(value: Copy.filterAll, title: Copy.filterAll),
                KitSegment(value: Copy.filterMuted, title: Copy.filterMuted),
                KitSegment(value: Copy.filterFavorites, title: Copy.filterFavorites),
                KitSegment(value: Copy.filterRecommendations, title: Copy.filterRecommendations),
                KitSegment(value: Copy.filterNotSynced, title: Copy.filterNotSynced)
            ])
            Text(Copy.notSyncedCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if rows.isEmpty {
                Text(Copy.notSyncedEmpty)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                StatsRowsMock(rows: rows)
            }
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
