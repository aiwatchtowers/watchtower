import AppKit
import DesignKit
import SwiftUI
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerTestSupport

/// Statistics → Channels with Stop syncing (adaptive Slack sync, #1709),
/// rendered from the real views on fixture data: the row's Stop syncing /
/// Sync again button and sync tag, the Stop syncing suggestion and the Not
/// synced filter. The design mockups these replaced are
/// `docs/design/mockups/slack-adaptive-sync/`. Sample data only.
@MainActor
enum SlackAdaptiveSyncShotFixtures {
    static var shots: [DesignShot] {
        [
            DesignShot(name: "slack-as-rows", size: NSSize(width: 960, height: 0)) {
                screen(filter: .all, stats: mixed) { ChannelStatsTable(vm: $0) }
            },
            DesignShot(name: "slack-as-suggestion", size: NSSize(width: 960, height: 0)) {
                screen(filter: .all, stats: mixed, recommendations: suggestions) { ChannelRecommendationsSection(vm: $0) }
            },
            DesignShot(name: "slack-as-filter-notsynced", size: NSSize(width: 960, height: 0)) {
                screen(filter: .notSynced, stats: excluded) { filtered($0) }
            },
            DesignShot(name: "slack-as-filter-notsynced-empty", size: NSSize(width: 960, height: 0)) {
                screen(filter: .notSynced, stats: [mixed[0]]) { filtered($0) }
            }
            // No narrow frame: Statistics → Channels is a wide table with
            // fixed column widths.
        ]
    }

    private static func filtered(_ vm: ChannelStatsViewModel) -> some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            ChannelStatsFilterPicker(vm: vm)
            ChannelStatsTable(vm: vm)
        }
    }

    /// The database the view models sit on; nothing reads it, the rows are
    /// set directly.
    private static var manager: DatabaseManager?

    private static func screen(
        filter: ChannelStatsViewModel.Filter,
        stats: [[String: Any]],
        recommendations: [ChannelRecommendation] = [],
        @ViewBuilder content: (ChannelStatsViewModel) -> some View
    ) -> AnyView {
        do {
            let dbManager = try manager ?? TestDatabase.createDatabaseManager().0
            manager = dbManager
            let vm = ChannelStatsViewModel(dbManager: dbManager, cliRunner: nil)
            vm.stats = try stats.map(ChannelStatsTests.stat(from:))
            vm.recommendations = recommendations
            vm.filter = filter
            vm.showAllChannels = true
            return AnyView(content(vm).padding(Spacing.medium).detailBackground())
        } catch {
            return DesignShotFixtures.failure(error)
        }
    }

    private static let now = Date().timeIntervalSince1970
    private static let day = 86_400.0

    private static let mixed: [[String: Any]] = [
        ["id": "1", "name": "team-core", "total_messages": 412, "user_messages": 37, "bot_messages": 16,
         "bot_ratio": 0.04, "mention_count": 9, "last_activity": now - 3600, "digest_count": 4],
        ["id": "2", "name": "alerts-prod", "total_messages": 2_904, "bot_messages": 2_788, "bot_ratio": 0.96,
         "last_activity": now - 2 * day, "is_muted_for_llm": true, "is_sync_excluded": true],
        ["id": "3", "name": "random", "total_messages": 655, "user_messages": 2, "bot_messages": 72, "bot_ratio": 0.11,
         "mention_count": 1, "last_activity": now - day, "digest_count": 2, "messages_since_digest": 14,
         "catchup_from": now - 13 * day],
        ["id": "4", "name": "deploys", "total_messages": 1_318, "bot_messages": 1_160, "bot_ratio": 0.88,
         "last_activity": now - 4 * day, "is_muted_for_llm": true]
    ]

    private static let excluded: [[String: Any]] = [
        mixed[1],
        ["id": "5", "name": "ci-builds", "total_messages": 5_120, "bot_messages": 5_069, "bot_ratio": 0.99,
         "last_activity": now - 9 * day, "is_muted_for_llm": true, "is_sync_excluded": true]
    ]

    private static let suggestions = [
        ChannelRecommendation(channelID: "5", channelName: "ci-builds", action: .exclude,
                              reason: ChannelStatsPresentation.reasonBots(99)),
        ChannelRecommendation(channelID: "6", channelName: "old-project-x", action: .exclude,
                              reason: ChannelStatsPresentation.reasonMuted)
    ]
}
