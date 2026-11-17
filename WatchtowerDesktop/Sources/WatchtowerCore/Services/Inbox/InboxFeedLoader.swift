import Foundation
import Observation
import WatchtowerInterface

/// Reads the Inbox feed from the tower (mobile Inbox spec §5.1): on `open()`,
/// on every `changed` event of the open watch and on folder navigation. At
/// most one read runs at a time; a change or a navigation during a read marks
/// the loader dirty, and exactly one more read follows it. A failed read
/// keeps the last feed (the screen shows the reason above it).
///
/// The watch is open only between `open()` and `close()`: the Inbox opens it
/// while its window is on screen and closes it when the window hides or the
/// app goes to the tray, so the daemon's `data_version` poll runs only then.
@MainActor
@Observable
package final class InboxFeedLoader {
    /// The last feed a read answered; nil before the first answer.
    package private(set) var feed: Feed?
    /// The client's screen state for this screen.
    package private(set) var state: TowerScreenState = .idle
    /// The last read's failure while a feed is kept; nil after an answer.
    package private(set) var failure: TowerFailure?
    /// When the last answered read landed ("Showing the list from 09:14").
    package private(set) var answeredAt: Date?
    /// The clock `answeredAt` is read from.
    @ObservationIgnored package var clock: () -> Date = Date.init
    /// True while the tower has been down long enough to show
    /// "Reconnecting to Watchtower…" (`TowerTiming.reconnectingLineAfter`).
    package private(set) var showsReconnectingLine = false
    /// True between `open()` and `close()`.
    package private(set) var isOpen = false
    /// The folder the last navigation asked for (nil: the root).
    package private(set) var folder: Int64?

    /// Called on the main actor after every answered read.
    @ObservationIgnored package var onFeed: (@MainActor (Feed) -> Void)?

    @ObservationIgnored private let client: TowerClient
    /// The params of every read (the view model adds the day a route opened).
    @ObservationIgnored package var request: @MainActor () -> FeedRequest
    @ObservationIgnored private var reading: Task<Void, Never>?
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var listeners: [Task<Void, Never>] = []

    /// `request` is asked for the params of every read (the Mac: no limit,
    /// no clip, the whole tree).
    package init(client: TowerClient, request: @escaping @MainActor () -> FeedRequest) {
        self.client = client
        self.request = request
    }

    /// Opens the watch and reads. A second call while open does nothing.
    package func open() {
        guard !isOpen else { return }
        isOpen = true
        let client = client
        listeners = [
            Task { [weak self] in
                for await _ in await client.watch(.inboxWatch) {
                    guard !Task.isCancelled else { break }
                    self?.reload()
                }
            },
            Task { [weak self] in
                for await state in await client.screenStates() {
                    guard !Task.isCancelled else { break }
                    let line = await client.showsReconnectingLine()
                    self?.show(state, line: line)
                }
            },
            Task { [weak self] in
                for await refresh in await client.refreshes() where refresh.command == .inboxFeed {
                    guard !Task.isCancelled else { break }
                    if let feed = try? refresh.decode(Feed.self) { self?.answered(feed) }
                }
            }
        ]
        reload()
    }

    /// Closes the watch. A read on its way still lands; nothing reads after.
    package func close() {
        guard isOpen else { return }
        isOpen = false
        listeners.forEach { $0.cancel() }
        listeners = []
        dirty = false
    }

    /// Shows `folder` (nil: the root) and reads.
    package func navigate(to folder: Int64?) {
        self.folder = folder
        reload()
    }

    /// Reads now, or once more after the read on its way.
    package func reload() {
        guard reading == nil else {
            dirty = true
            return
        }
        reading = Task { [weak self] in
            await self?.readUntilClean()
        }
    }

    /// The failure's button: the client's retry (start or restart the
    /// daemon when it is down or another version), then a read.
    package func retry() async {
        await client.retry()
        reload()
    }

    /// The read on its way, if any (tests await it).
    package var pendingRead: Task<Void, Never>? { reading }

    private func readUntilClean() async {
        repeat {
            dirty = false
            let result: Result<Feed, TowerFailure> = await client.read(.inboxFeed, params: request())
            switch result {
            case .success(let feed): answered(feed)
            case .failure(let failure): self.failure = failure
            }
        } while dirty && isOpen
        reading = nil
    }

    private func answered(_ feed: Feed) {
        self.feed = feed
        answeredAt = clock()
        failure = nil
        onFeed?(feed)
    }

    #if DEBUG
    /// Shows the client's `state` and a read's `failure` as if the tower
    /// had answered so, with no daemon: the design shots draw the Inbox's
    /// states (mockup §7) through it. Debug builds only; the transitions
    /// themselves are the client's and the loader's own (`TowerClientTests`,
    /// `InboxFeedLoaderTests`, `ActionStripFeedTests.testReconnectingLineAboveTheLastList`).
    package func showForShots(_ state: TowerScreenState, failure: TowerFailure?, reconnectingLine: Bool) {
        self.failure = failure
        show(state, line: reconnectingLine)
    }
    #endif

    private func show(_ state: TowerScreenState, line: Bool) {
        self.state = state
        showsReconnectingLine = line
    }
}
