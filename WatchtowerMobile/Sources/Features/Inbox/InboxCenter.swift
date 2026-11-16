import Foundation
import GRDB
import Observation
import os
import WatchtowerInterface
import WatchtowerKit
import WatchtowerSync

/// What the Inbox reads off the replica besides the feed: the two kinds' versions (a publish moves them) and the
/// `inbox_act` rows still in the outbox or failed there.
struct InboxReplicaSnapshot: Equatable {
    var folderVersion: Int64 = 0
    var cardVersion: Int64 = 0
    /// Every `inbox_act` row the replica holds.
    var actions: [PendingAction] = []

    nonisolated static func read(from db: Database, store: ReplicaStore) throws -> Self {
        let versions = try store.kindVersions([.inboxFolder, .inboxCard], from: db)
        return Self(
            folderVersion: versions[.inboxFolder] ?? 0,
            cardVersion: versions[.inboxCard] ?? 0,
            actions: try store.pendingActions(from: db).filter { $0.action.kind == .inboxAct }
        )
    }
}

/// One hub's Inbox on the phone (mobile Inbox spec §7): the tab's `TowerClient` over `HubTransport`, the feed it
/// last read, the presses and what became of them, and the optimistic hide. Owned by the `HubSession`, so a press
/// waiting for the hub survives the tab switch.
///
/// - A publish of `inbox_card` or `inbox_folder` reaches the client's watch, which re-reads the feed. Only a
///   publish of the cards counts toward the optimistic hide (`InboxHiddenRows`: two of them and the hub wins).
/// - A press goes through `TowerClient.act` (one request_id per press, kept until a final answer). `ok` hides
///   its row or card (`hides`); a refusal keeps it with the sentence and Retry; `unknown` ("Didn't confirm") is
///   never sent again — a second tap does nothing until Refresh.
@MainActor
@Observable
final class InboxCenter {
    /// The phone's feed (spec "Phone feed").
    nonisolated static let feedRequest = FeedRequest(limit: 300, clip: true)

    private(set) var feed: Feed?
    private(set) var hidden = InboxHiddenRows()
    /// Each press's state while it has one, by its key.
    private(set) var states: [String: TowerActionState] = [:]
    /// The line a busy press shows, by its key.
    private(set) var busyLabels: [String: String] = [:]
    /// The key a row or card last pressed (its hide key → the press key), for its row's state.
    private(set) var lastPress: [String: String] = [:]
    /// The outbox's Inbox lines: the `inbox_act` rows still on their way, and the ones it could not deliver.
    private(set) var outbox = InboxOutboxModel()

    @ObservationIgnored let transport: HubTransport
    @ObservationIgnored let client: TowerClient
    /// The hub's name for the not-delivered sentence.
    @ObservationIgnored var hubName: @MainActor () -> String = { "" }
    @ObservationIgnored private var retries: [String: (row: String?, hides: Bool, request: @Sendable (String) -> ActRequest)] = [:]
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var observation: ResilientObservation?
    @ObservationIgnored private var replica = InboxReplicaSnapshot()
    @ObservationIgnored private var dismiss: (String) -> Void = { _ in }
    /// Card publishes the hide has not counted yet.
    @ObservationIgnored private var unseenPublishes = 0
    @ObservationIgnored private var settled: Set<String> = []
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "InboxCenter")

    init(transport: HubTransport, clock: any Clock<Duration> = ContinuousClock()) {
        self.transport = transport
        client = TowerClient(transport: transport, clock: clock, restartDaemon: nil, startDaemon: nil)
    }

    /// The tab's badge: the shown folders' `waiting` (ask #1349).
    var badge: Int {
        feed.map { InboxRootModel(feed: $0, platform: .phone).badge } ?? 0
    }

    /// The hub's first Inbox publish has arrived (the root folder is always in it).
    var fetched: Bool {
        feed?.folders.isEmpty == false
    }

    func state(_ key: String) -> TowerActionState? {
        states[key]
    }

    /// The state of the press a row or card (`hideKey`) made last.
    func rowState(_ hideKey: String) -> (key: String, state: TowerActionState)? {
        guard let key = lastPress[hideKey], let state = states[key] else { return nil }
        return (key, state)
    }

    // MARK: - Reading

    /// Opens the watch and reads the feed once; the client's own re-reads (it came back, an action answered
    /// unknown) land here too.
    func start() {
        guard tasks.isEmpty else { return }
        let client = client
        tasks.append(Task { [weak self] in
            for await _ in await client.watch(.inboxWatch) {
                await self?.reload()
            }
        })
        tasks.append(Task { [weak self] in
            for await refresh in await client.refreshes() where refresh.command == .inboxFeed {
                guard let feed = try? refresh.decode(Feed.self) else { continue }
                self?.apply(feed)
            }
        })
        tasks.append(Task { [weak self] in await self?.reload() })
    }

    func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
        observation = nil
    }

    /// Reads the feed now.
    func reload() async {
        let result: Result<Feed, TowerFailure> = await client.read(.inboxFeed, params: Self.feedRequest)
        switch result {
        case let .success(feed): apply(feed)
        case let .failure(failure): Self.logger.warning("inbox feed not read: \(failure.sentence, privacy: .public)")
        }
    }

    /// Didn't confirm's Refresh: the feed again, and the unconfirmed presses forgotten (the owner looks first).
    func refresh() async {
        for (key, state) in states where state == .unknown {
            states[key] = nil
        }
        await reload()
    }

    /// Feeds applied so far (tests wait on it).
    @ObservationIgnored private(set) var reads = 0

    /// A feed as read. A card publish since the last one counts once toward the optimistic hide.
    func apply(_ feed: Feed) {
        reads += 1
        if unseenPublishes > 0 {
            hidden.observe(feed: feed)
            unseenPublishes = 0
        }
        self.feed = feed
    }

    /// The hub published the cards: the watch re-reads, and the next feed counts toward the hide.
    func cardsPublished() {
        unseenPublishes += 1
        transport.published()
    }

    // MARK: - Pressing

    /// Sends one press. `key` names the press (`InboxPressKey`); `row` is the row or card it was made on (its
    /// state shows there), which an `ok` takes off the screen when `hides`; `busy` is the line it shows meanwhile.
    /// A press on its way, or one that answered unknown, is not sent again.
    func press(
        _ key: String,
        on row: String?,
        hides: Bool,
        busy: String? = nil,
        request: @escaping @Sendable (String) -> ActRequest
    ) async {
        switch states[key] {
        case .busy?, .unknown?: return
        case .refused?, nil: break
        }
        if let row { lastPress[row] = key }
        retries[key] = (row, hides, request)
        states[key] = .busy
        busyLabels[key] = busy
        let outcome: TowerActOutcome<RawJSON> = await client.act(.inboxAct, key: key, params: request)
        busyLabels[key] = nil
        switch outcome {
        case .ok:
            states[key] = nil
            retries[key] = nil
            if hides, let row { hidden.hideOnOK(row) }
        case let .refused(sentence):
            states[key] = .refused(sentence)
        case .unknown:
            states[key] = .unknown
        case let .failed(failure) where failure.kind == .down:
            // The client stopped waiting (its write limit) while the action still sits in the outbox: the Waiting
            // to send line shows it, and a second press waits for that same action (`HubTransport`).
            states[key] = nil
        case let .failed(failure):
            states[key] = .refused(failure.sentence)
        }
    }

    /// A refused press's Retry: the same press again.
    func retry(_ key: String) async {
        guard let last = retries[key] else { return }
        await press(key, on: last.row, hides: last.hides, busy: busyLabels[key], request: last.request)
    }

    // MARK: - The replica

    /// Observes the replica's Inbox kinds and `inbox_act` rows for the session's lifetime: a publish reaches the
    /// watch, a failed row settles its press (and leaves the replica, unless the outbox lists it as Not delivered).
    func observe(store: ReplicaStore, gate: ReplicaObservationGate? = nil) {
        guard observation == nil else { return }
        dismiss = { id in
            do {
                _ = try store.dismissAction(id: id)
            } catch {
                Self.logger.warning("settled inbox action not dismissed: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
        observation = ResilientObservation(
            name: "inbox",
            reader: store.reader,
            gate: gate,
            observation: {
                ValueObservation.tracking(regions: [ReplicaStore.kindVersionsRegion, ReplicaStore.pendingActionsRegion]) { db in
                    try InboxReplicaSnapshot.read(from: db, store: store)
                }
                .removeDuplicates()
            },
            onChange: { [weak self] value in self?.receive(value) }
        )
    }

    /// One replica snapshot (the observation's, or a test's).
    func receive(_ value: InboxReplicaSnapshot) {
        let previous = replica
        replica = value
        if value.cardVersion != previous.cardVersion {
            cardsPublished()
        } else if value.folderVersion != previous.folderVersion {
            transport.published()
        }
        outbox = InboxOutboxModel(
            queued: value.actions.filter { $0.state == .pending }, undelivered: value.actions.filter { $0.delivery == .undelivered },
            hubName: hubName()
        )
        for row in value.actions where !settled.contains(row.id) {
            guard let settlement = InboxActSettlement.of(row, hubName: hubName()) else { continue }
            settled.insert(row.id)
            transport.settle(actionID: row.id, settlement)
            if case .notDelivered = settlement { continue }
            dismiss(row.id)
        }
    }

    /// An applied echo of any action (the session's one applied observer).
    func receiveApplied(_ action: ActionRequestPayload) {
        guard action.kind == .inboxAct else { return }
        let result = action.result.flatMap { try? JSONEncoder().encode($0) }
        transport.settle(actionID: action.id, .applied(result: result))
    }

    // MARK: - The screenshot tour

    /// A feed and press states as the tour shows them, with no hub behind them.
    func showForTour(
        feed: Feed?,
        states: [String: TowerActionState] = [:],
        busy: [String: String] = [:],
        lastPress: [String: String] = [:],
        outbox: InboxOutboxModel = InboxOutboxModel()
    ) {
        self.feed = feed
        self.states = states
        busyLabels = busy
        self.lastPress = lastPress
        self.outbox = outbox
    }

    /// A center over nothing: the tour's and the previews'.
    static func detached() -> InboxCenter {
        InboxCenter(transport: HubTransport(records: { InboxRecords() }, enqueue: { _ in throw CancellationError() }))
    }
}

/// The keys a press goes by in `TowerClient` (a row's id plus its verb, and the drawn version where the request
/// carries it, so a changed card is a new press).
enum InboxPressKey {
    static func card(_ card: InboxCard, _ verb: ActVerb) -> String {
        "card:\(card.id):\(verb.rawValue):\(card.contentHash)"
    }

    static func button(_ card: InboxCard, index: Int) -> String {
        "press:\(card.id):\(index):\(card.contentHash)"
    }

    static func ref(cardID: String, row: String, _ verb: RefVerb, choice: String = "") -> String {
        "ref:\(cardID):\(row):\(verb.rawValue)\(choice.isEmpty ? "" : ":\(choice)")"
    }

    static func reply(cardID: String, row: String) -> String {
        "reply:\(cardID):\(row)"
    }

    static func approval(_ card: InboxCard, _ verb: ApprovalVerb) -> String {
        "approval:\(card.id):\(verb.rawValue):\(card.approval?.argsSHA256 ?? "")"
    }
}
