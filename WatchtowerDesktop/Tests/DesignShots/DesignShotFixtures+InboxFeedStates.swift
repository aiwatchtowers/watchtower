import SwiftUI
import XCTest
@testable import WatchtowerDesktop
import WatchtowerCore
import WatchtowerInterface
import WatchtowerTestSupport

/// The Mac Inbox's states now that its list comes from the tower (mobile
/// Inbox mockup §7): the first load, a failed read over the kept list, a
/// failed action on its row, reconnecting, and another daemon version. The
/// list is b-01's (Go's case `desktop_shot_folders_root`, listed through the
/// fake tower); the loader is put in each state the client reports
/// (`InboxFeedLoader.showForShots`), since a shot runs no daemon.
@MainActor
enum InboxFeedStateShotFixtures {
    private static var paths: [String] = []
    private static let defaultsSuite = "InboxFeedStateShotFixtures"
    nonisolated static let now = AutomationDates.parse("2026-11-06T12:00:00Z") ?? Date()

    static func cleanUp() {
        paths.forEach(TestDatabase.cleanup(path:))
        paths = []
        UserDefaults().removePersistentDomain(forName: defaultsSuite)
    }

    enum State {
        case firstLoad, failedLoad, failedAction, reconnecting, differentVersion
    }

    static var shots: [DesignShot] {
        let states: [(String, State)] = [
            ("inbox-feed-first-load", .firstLoad),
            ("inbox-feed-failed-load", .failedLoad),
            ("inbox-feed-failed-action", .failedAction),
            ("inbox-feed-reconnecting", .reconnecting),
            ("inbox-feed-different-version", .differentVersion)
        ]
        return states.map { name, state in
            DesignShot(name: name, size: NSSize(width: 1180, height: 520)) { view(state) }
        }
    }

    /// The failed press's sentence, as Go words a busy database (`inboxfeed.Sentence`).
    static let busySentence = "Couldn't mark it done: the database is busy."

    static func view(_ state: State) -> AnyView {
        do {
            let (pool, path) = try TestDatabase.createPool()
            paths.append(path)
            // b-01's list; the failed-action shot opens Waiting for me, so its
            // case lists it read once that opening landed.
            let tower = try InboxShotFeed.seeded(
                state == .failedAction ? "desktop_shot_feed_waiting_opened" : "desktop_shot_folders_root", pool)
            let defaults = UserDefaults(suiteName: defaultsSuite) ?? .standard
            defaults.removePersistentDomain(forName: defaultsSuite)
            let clock = now
            // Labeled: a trailing closure would bind to `automationsWake`.
            // swiftlint:disable:next trailing_closure
            let vm = ActionStripViewModel(dbPool: pool, cliRunner: FakeCLIRunner(), defaults: defaults, clock: { clock })
            if state == .firstLoad {
                // A loader attached, its first read not answered yet.
                let client = TowerClient(transport: tower, clock: ContinuousClock(), restartDaemon: nil, startDaemon: nil)
                vm.attach(InboxFeedLoader(client: client) { FeedRequest() })
                InboxFolderMenuShotFixtures.spin(until: "the folder tree", vm.hasRead) { await vm.refresh() }
            } else {
                InboxShotFeed.listed(vm, tower)
            }
            try show(state, vm: vm, tower: tower)
            return AnyView(ActionStripActionsView(
                vm: vm, cheatSheetRows: [], feature: .on(lastCheck: nil), isEnabling: false, featureError: nil,
                onEnable: {}, onOpenSettings: {}, onOpen: { _ in }, now: now
            )
            .environment(AppState())
            .detailBackground())
        } catch {
            return DesignShotFixtures.failure(error)
        }
    }

    private static func show(_ state: State, vm: ActionStripViewModel, tower: FeedCaseTransport) throws {
        let loader = try XCTUnwrap(vm.feedLoader)
        switch state {
        case .firstLoad:
            return
        case .failedLoad:
            // The list read three hours ago; the daemon is down since.
            let readAt = now.addingTimeInterval(-3 * 3600)
            loader.clock = { readAt }
            InboxFolderMenuShotFixtures.spin(until: "the list's read", loader.answeredAt == readAt) {
                loader.reload()
                while let read = loader.pendingRead { await read.value }
            }
            loader.showForShots(.ready(stale: now.addingTimeInterval(-3 * 3600)),
                                failure: TowerFailure(kind: .down, sentence: TowerText.daemonDown),
                                reconnectingLine: false)
        case .failedAction:
            // Waiting for me open (its opening read as the Mac writes it);
            // then Done on its first row, refused by the tower.
            InboxFolderMenuShotFixtures.spin(until: "Waiting for me open", vm.selectedEntry != nil) {
                await vm.selectEntry("artifact:1")
            }
            tower.actRefusal = busySentence
            vm.attachWrites(InboxTowerWrites(client: TowerClient(
                transport: tower, clock: ContinuousClock(), restartDaemon: nil, startDaemon: nil)))
            InboxFolderMenuShotFixtures.spin(until: "the refused Done", vm.rowErrors[.message(1)] != nil) {
                await InboxRowActionHandler(vm: vm).press(.done, on: InboxRef(kind: .inboxItem, id: 1))
            }
        case .reconnecting:
            loader.showForShots(.reconnecting, failure: nil, reconnectingLine: true)
        case .differentVersion:
            let version = TowerFailure(kind: .version, sentence: TowerText.differentVersion)
            loader.showForShots(.failed(version), failure: nil, reconnectingLine: false)
        }
    }
}
