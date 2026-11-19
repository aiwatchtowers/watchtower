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

/// How a row's press that did not go through gets another try.
enum InboxRetry: Equatable {
    /// The outbox never delivered it: the outbox's own Retry, the same action (one request_id) whichever screen
    /// asks — the Not delivered list's Retry is the same call. `request` is that action's press (it names the
    /// row's only button, "Retry Done").
    case outbox(actionID: String, ActRequest)
    /// The hub (or this phone) refused it: the same press again under a new request_id, the failed row dismissed.
    case resend(ActRequest, dismiss: String?)
}

/// A row's or card's press as the screen draws it.
enum InboxRowState: Equatable {
    /// On its way: sending, or queued in the outbox (also after a relaunch).
    case busy(ActRequest)
    /// Refused or not delivered, with the sentence and its Retry; kept in the replica, so it survives a relaunch.
    case refused(String, InboxRetry)
    /// The hub stopped mid-way (`outcome_unknown`): never sent again; Refresh.
    case unknown

    /// Not delivered: every action of the row is off but its named Retry.
    var isUndelivered: Bool {
        if case .refused(_, .outbox) = self { return true }
        return false
    }

    /// The Retry button's title: "Retry Done" for a Not delivered press, else "Retry".
    var retryTitle: String {
        if case let .refused(_, .outbox(_, request)) = self { return InboxPhoneText.retryTitle(for: request) }
        return InboxText.retry
    }

    /// The busy line ("Marking done…"); nil when the press shows a spinner only.
    var busyLabel: String? {
        if case let .busy(request) = self { return InboxText.busyLabel(for: request) }
        return nil
    }
}

/// One hub's Inbox on the phone (mobile Inbox spec §7): the tab's `TowerClient` over `HubTransport`, the feed it
/// last read, the presses and what became of them, and the optimistic hide. Owned by the `HubSession`, so a press
/// waiting for the hub survives the tab switch.
///
/// - A publish of `inbox_card` or `inbox_folder` reaches the client's watch, which re-reads the feed. Only a
///   publish of the cards counts toward the optimistic hide (`InboxHiddenRows`: two of them and the hub wins).
/// - A press goes through `TowerClient.act` (one request_id per press); on a Not delivered row only its named Retry
///   sends (the outbox's retry of the same action), and on a refused row a press supersedes the failure. Its row's state (`rowState`) comes from the
///   press on its way, then from the replica's `inbox_act` rows (queued: busy; failed: the hub's sentence and
///   Retry, kept across a relaunch until Retry, Refresh or an `ok` on the row), then from the client's answer (a
///   local failure). `ok` hides its row or card, also when it lands with no press waiting (the client gave up, or
///   a relaunch); `unknown` is never sent again — a second tap does nothing until Refresh.
@MainActor
@Observable
final class InboxCenter {
    /// The phone's feed (spec "Phone feed").
    nonisolated static let feedRequest = FeedRequest(limit: 300, clip: true)

    private(set) var feed: Feed?
    private(set) var hidden = InboxHiddenRows()
    /// The presses on their way, by key.
    private(set) var inflight: [String: ActRequest] = [:]
    /// Each press's last answer that was not `ok` (a refusal, unknown, a local failure), by key.
    private(set) var answered: [String: Answer] = [:]
    /// The replica's `inbox_act` rows.
    private(set) var actions: [PendingAction] = []
    /// The outbox's Inbox lines: the `inbox_act` rows still on their way, and the ones it could not deliver.
    private(set) var outbox = InboxOutboxModel()
    /// The screenshot tour's row states.
    private(set) var tourRows: [String: InboxRowState] = [:]

    struct Answer: Equatable {
        let request: ActRequest
        let state: TowerActionState
        let seq: Int
    }

    @ObservationIgnored let transport: HubTransport
    @ObservationIgnored let client: TowerClient
    /// The hub's name for the not-delivered sentence.
    @ObservationIgnored var hubName: @MainActor () -> String = { "" }
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var observation: ResilientObservation?
    @ObservationIgnored private var replica = InboxReplicaSnapshot()
    @ObservationIgnored private var dismissRow: (String) -> Void = { _ in }
    @ObservationIgnored private var retryUndelivered: (String) async throws -> Void = { _ in }
    @ObservationIgnored private var retrying: Set<String> = []
    @ObservationIgnored private var answers = 0
    /// Card publishes the hide has not counted yet.
    @ObservationIgnored private var unseenPublishes = 0
    @ObservationIgnored private var settled: Set<String> = []
    /// Feeds applied so far (tests wait on it).
    @ObservationIgnored private(set) var reads = 0
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "InboxCenter")

    init(transport: HubTransport, clock: any Clock<Duration> = ContinuousClock()) {
        self.transport = transport
        client = TowerClient(transport: transport, clock: clock, restartDaemon: nil, startDaemon: nil)
    }

    /// The tab's badge: the shown folders' `waiting` (ask #1349), while the hub publishes the Inbox (`inbox` on);
    /// records an organization's policy left behind count nothing.
    func badge(capability: String?) -> Int {
        guard capability == InboxCapability.on else { return 0 }
        return feed.map { InboxRootModel(feed: $0, platform: .phone).badge } ?? 0
    }

    /// The hub's first Inbox publish has arrived (the root folder is always in it).
    var fetched: Bool {
        feed?.folders.isEmpty == false
    }

    /// The state of the press made last on a row or card (`InboxPress.row`).
    func rowState(_ row: String) -> InboxRowState? {
        if let tour = tourRows[row] { return tour }
        if let request = inflight.values.first(where: { InboxPress.row(of: $0) == row }) { return .busy(request) }
        if let newest = actions.filter({ InboxPress.row(of: $0) == row }).max(by: { $0.createdAt < $1.createdAt }),
           let request = InboxPress.request(of: newest) {
            switch newest.state {
            case .pending: return .busy(request)
            case .failed:
                switch InboxActSettlement.of(newest, hubName: hubName()) {
                case .unknown?: return .unknown
                case let .notDelivered(sentence)?: return .refused(sentence, .outbox(actionID: newest.id, request))
                case let .refused(_, sentence)?: return .refused(sentence, .resend(request, dismiss: newest.id))
                case .applied?, nil: break
                }
            }
        }
        guard let last = answered.values.filter({ InboxPress.row(of: $0.request) == row }).max(by: { $0.seq < $1.seq }) else {
            return nil
        }
        switch last.state {
        case let .refused(sentence): return .refused(sentence, .resend(last.request, dismiss: nil))
        case .unknown: return .unknown
        case .busy: return .busy(last.request)
        }
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

    /// Didn't confirm's Refresh: the unconfirmed presses forgotten (the owner looks first, then may press again),
    /// and the feed again.
    func refresh() async {
        answered = answered.filter { $0.value.state != .unknown }
        for row in actions where row.state == .failed && row.reason == .outcomeUnknown {
            dismissRow(row.id)
        }
        actions.removeAll { $0.state == .failed && $0.reason == .outcomeUnknown }
        await reload()
    }

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

    /// Sends one press, built by `request` from its request_id. Its key, row and whether an `ok` hides the row come
    /// from the request (`InboxPress`). Nothing is sent while the row has a press on its way (queued included) or
    /// one that answered unknown.
    func press(_ request: @escaping @Sendable (String) -> ActRequest) async {
        let probe = request("")
        let key = InboxPress.key(of: probe)
        let row = InboxPress.row(of: probe)
        switch rowState(row) {
        case .busy?, .unknown?:
            return
        case .refused(_, .outbox)?:
            // Not delivered: the row's only action is its named Retry (`retry`), the same request_id; any other
            // press sends nothing, never a second action the Not delivered list could also retry.
            return
        case let .refused(_, .resend(_, dismiss))?:
            // The new press supersedes the older failure: its outcome is the one the row shows.
            if let dismiss { forget(dismiss) }
            answered = answered.filter { InboxPress.row(of: $0.value.request) != row }
        case nil:
            break
        }
        inflight[key] = probe
        answered[key] = nil
        let outcome: TowerActOutcome<RawJSON> = await client.act(.inboxAct, key: key, params: request)
        inflight[key] = nil
        switch outcome {
        case .ok:
            succeeded(probe)
        case let .refused(refusal):
            answer(key, probe, .refused(refusal.sentence))
        case .unknown:
            answer(key, probe, .unknown)
        case let .failed(failure) where failure.kind == .down:
            // The client stopped waiting (its write limit) while the action still sits in the outbox: its replica
            // row shows it busy, and its settlement shows on the row whenever it comes.
            break
        case let .failed(failure):
            answer(key, probe, .refused(failure.sentence))
        }
    }

    /// A refused or not delivered press's Retry (`InboxRowState.refused`).
    func retry(_ retry: InboxRetry) async {
        switch retry {
        case let .outbox(actionID, _):
            // The same action again: a second Retry (here or on the Not delivered list) finds it gone or running.
            guard retrying.insert(actionID).inserted else { return }
            defer { retrying.remove(actionID) }
            do {
                try await retryUndelivered(actionID)
            } catch {
                Self.logger.warning("inbox retry not queued: \(String(describing: type(of: error)), privacy: .public)")
            }
        case let .resend(request, dismiss):
            if let dismiss { forget(dismiss) }
            let row = InboxPress.row(of: request)
            answered = answered.filter { InboxPress.row(of: $0.value.request) != row }
            await press { requestID in
                ActRequest(requestID: requestID, target: request.target, verb: request.verb, params: request.params)
            }
        }
    }

    /// A failed replica row the row no longer shows: dismissed from the replica too.
    private func forget(_ actionID: String) {
        dismissRow(actionID)
        actions.removeAll { $0.id == actionID }
    }

    private func answer(_ key: String, _ request: ActRequest, _ state: TowerActionState) {
        answers += 1
        answered[key] = Answer(request: request, state: state, seq: answers)
    }

    /// An `ok`: the row's earlier failures go (from the replica too), and a hiding verb hides it.
    private func succeeded(_ request: ActRequest) {
        let row = InboxPress.row(of: request)
        answered = answered.filter { InboxPress.row(of: $0.value.request) != row }
        for failed in actions where failed.state == .failed && InboxPress.row(of: failed) == row {
            dismissRow(failed.id)
        }
        actions.removeAll { $0.state == .failed && InboxPress.row(of: $0) == row }
        if InboxPress.hides(request) { hidden.hideOnOK(row) }
    }

    // MARK: - The replica

    /// Observes the replica's Inbox kinds and `inbox_act` rows for the session's lifetime: a publish reaches the
    /// watch, a failed row settles its press. `outbox` retries a Not delivered action (the same call as the Not
    /// delivered list's Retry).
    func observe(store: ReplicaStore, outbox: ActionOutbox?, gate: ReplicaObservationGate? = nil) {
        guard observation == nil else { return }
        dismissRow = { id in
            do {
                _ = try store.dismissAction(id: id)
            } catch {
                Self.logger.warning("inbox action not dismissed: \(String(describing: type(of: error)), privacy: .public)")
            }
        }
        if let outbox {
            retryUndelivered = { id in _ = try await outbox.retry(id: id) }
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
        actions = value.actions
        outbox = InboxOutboxModel(
            queued: value.actions.filter { $0.state == .pending },
            undelivered: value.actions.filter(InboxActSettlement.isUndelivered), hubName: hubName()
        )
        for row in value.actions where !settled.contains(row.id) {
            guard let settlement = InboxActSettlement.of(row, hubName: hubName()) else { continue }
            settled.insert(row.id)
            transport.settle(actionID: row.id, settlement)
        }
    }

    /// An applied echo of any action (the session's one applied observer): the press waiting for it answers; with
    /// none waiting (the client gave up, a relaunch) its row still hides.
    func receiveApplied(_ action: ActionRequestPayload) {
        guard action.kind == .inboxAct else { return }
        let result = action.result.flatMap { try? JSONEncoder().encode($0) }
        transport.settle(actionID: action.id, .applied(result: result))
        if let request = InboxPress.request(params: action.params),
           !inflight.values.contains(where: { $0.requestID == request.requestID }) {
            succeeded(request)
        }
    }

    /// The test seam for `observe`'s outbox and dismiss.
    func use(dismiss: @escaping (String) -> Void, retryUndelivered: @escaping (String) async throws -> Void) {
        dismissRow = dismiss
        self.retryUndelivered = retryUndelivered
    }

    // MARK: - The screenshot tour

    /// A feed and row states as the tour shows them, with no hub behind them.
    func showForTour(feed: Feed?, rows: [String: InboxRowState] = [:], outbox: InboxOutboxModel = InboxOutboxModel()) {
        self.feed = feed
        tourRows = rows
        self.outbox = outbox
    }

    /// A center over nothing: the tour's and the previews'.
    static func detached() -> InboxCenter {
        InboxCenter(transport: HubTransport(records: { InboxRecords() }, enqueue: { _ in throw CancellationError() }))
    }
}

/// A press as the screens and the client name it, all read off its `ActRequest`: its key (`TowerClient`'s, the
/// drawn version included, so a changed card is a new press, and a Reply's text), its row (where its state shows:
/// a ref row's `kind:id`, a card's id, a card button's `id#index`), and whether an `ok` hides that row.
enum InboxPress {
    static func key(of request: ActRequest) -> String {
        let p = request.params
        let parts: [String?] = [
            request.verb.rawValue, request.target, p.refKind.map { "\($0.rawValue):\(p.refID ?? 0)" }, p.refVerb?.rawValue,
            p.approvalVerb?.rawValue, p.index.map(String.init), p.contentHash, p.argsSHA256, p.until, p.text
        ]
        return parts.compactMap { $0 }.joined(separator: "|")
    }

    static func row(of request: ActRequest) -> String {
        let p = request.params
        switch request.verb {
        case .ref: return "\(p.refKind?.rawValue ?? ""):\(p.refID ?? 0)"
        case .replyPropose: return "\(RefKind.inboxItem.rawValue):\(p.refID ?? 0)"
        case .press: return buttonRow(request.target, p.index ?? 0)
        // Opening marks it read in the background: never the card's state.
        case .read: return "\(request.target)@read"
        default: return request.target
        }
    }

    /// A card button's row.
    static func buttonRow(_ cardID: String, _ index: Int) -> String {
        "\(cardID)#\(index)"
    }

    static func row(of action: PendingAction) -> String? {
        request(of: action).map(row(of:))
    }

    static func hides(_ request: ActRequest) -> Bool {
        switch request.verb {
        case .ref: request.params.refVerb.map(InboxRefVerbs.hides) ?? false
        case .approval: request.params.approvalVerb != .retry
        case .done, .dismiss: true
        default: false
        }
    }

    /// The press an `inbox_act` row carries.
    static func request(of action: PendingAction) -> ActRequest? {
        request(params: action.action.params)
    }

    static func request(params: [String: JSONValue]) -> ActRequest? {
        guard let data = try? JSONEncoder().encode(params) else { return nil }
        return try? JSONDecoder().decode(ActRequest.self, from: data)
    }
}
