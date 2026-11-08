import Foundation
import GRDB
import Observation
import WatchtowerCore

/// Types a spec review round's findings line into the author's session
/// (`SpecReviewLoopCenter`); `SessionLineDelivery` in the app, a fake in tests.
@MainActor
protocol SpecReviewLineDelivering: AnyObject {
    /// Where the line went. A held or queued line is not kept: the center
    /// tries it again on its next poll. `.noSession` only when the session
    /// is surely gone: never before the launch's reattach of hosted runs is
    /// done, nor when a new run of it started meanwhile (both `.held`).
    func deliverSpecReviewLine(_ line: String, askID: Int64, sessionID: Int64) async -> SessionLineDelivery.Delivery
    /// The round's line will not be asked for again (its loop ended): a
    /// line filed after it in the session's order may go now.
    func forgetSpecReviewLine(askID: Int64)
}

extension SessionLineDelivery: SpecReviewLineDelivering {
    func deliverSpecReviewLine(_ line: String, askID: Int64, sessionID: Int64) async -> Delivery {
        await specReviewLines.send(line, key: .specReview(askID), sessionID: sessionID)
    }

    func forgetSpecReviewLine(askID: Int64) {
        specReviewLines.forget(.specReview(askID))
    }

    /// One try of a spec review line (a round's or a thread question's),
    /// in `specReviewLines`' order.
    func deliverSpecReviewKeyed(_ line: String, key: LineKey, sessionID: Int64) async -> Delivery {
        var delivery = await deliverLine(line, key: key, sessionID: sessionID) { _ in }
        // A session not reattached yet after Keep Sessions and Quit or an
        // update is not gone: revealing it would end a live author's loop.
        if delivery == .noSession, !hostRunsSettled || isLive(sessionID) {
            delivery = .held
        }
        if delivery == .held || delivery == .queued {
            // The center's next poll owns the retry: the line must not also
            // go from the held queue, nor after the round was revealed.
            dropHeld(sessionID: sessionID) { $0 == key }
        }
        return delivery
    }
}

/// The spec review lines of each session in filing order (spec 2026-11-08
/// §3): a round's findings line (`SpecReviewLoopCenter`) and a Discuss
/// thread's question (`SpecReviewThreadCenter`) go one at a time, the
/// earlier filed first. Each center tries its line again on its own poll;
/// a line that is not at the head of its session's order is `.queued`
/// without being tried, so a later line never overtakes a held one. The
/// line at the head is tried through `deliver`, which keeps every PROJ-12
/// rule (never mid-turn, never over the owner's typing, held while the
/// hosted sessions reattach). A line its center is done with (its round
/// revealed, its question closed) leaves the order at once (`forget`); one
/// nobody forgot leaves it after `staleAfter`, so it never blocks the
/// session.
@MainActor
final class SpecReviewLineOrder {
    typealias Deliver = @MainActor (
        _ line: String, _ key: SessionLineDelivery.LineKey, _ sessionID: Int64
    ) async -> SessionLineDelivery.Delivery

    nonisolated static let staleAfter: TimeInterval = 30

    private struct Entry {
        let key: SessionLineDelivery.LineKey
        var lastAsked: Date
    }

    private let deliver: Deliver
    private let now: () -> Date
    private var queues: [Int64: [Entry]] = [:]
    /// Lines being tried right now: an overlapping ask for one waits.
    private var trying: Set<SessionLineDelivery.LineKey> = []

    init(now: @escaping () -> Date = Date.init, deliver: @escaping Deliver) {
        self.now = now
        self.deliver = deliver
    }

    /// Files `key` in its session's order on its first ask, then tries it
    /// when it is first in line; `.queued` while an earlier line waits.
    func send(_ line: String, key: SessionLineDelivery.LineKey, sessionID: Int64) async -> SessionLineDelivery.Delivery {
        let stamp = now()
        var queue = (queues[sessionID] ?? []).filter {
            $0.key == key || trying.contains($0.key) || stamp.timeIntervalSince($0.lastAsked) <= Self.staleAfter
        }
        if let index = queue.firstIndex(where: { $0.key == key }) {
            queue[index].lastAsked = stamp
        } else {
            queue.append(Entry(key: key, lastAsked: stamp))
        }
        queues[sessionID] = queue
        guard queue.first?.key == key, !trying.contains(key) else { return .queued }
        trying.insert(key)
        let delivery = await deliver(line, key, sessionID)
        trying.remove(key)
        if delivery != .held, delivery != .queued { forget(key) }
        return delivery
    }

    /// The line will not be asked for again: the next one may go.
    func forget(_ key: SessionLineDelivery.LineKey) {
        for (sessionID, queue) in queues where queue.contains(where: { $0.key == key }) {
            let rest = queue.filter { $0.key != key }
            queues[sessionID] = rest.isEmpty ? nil : rest
        }
    }
}

/// Ends an author loop (`WorkbenchCLI` in the app): `session_gone` when its
/// session is gone, `owner` for the owner's Show Now.
@MainActor
protocol SpecReviewRevealing {
    func specReviewReveal(askID: Int64, reason: String) async throws
}

extension WorkbenchCLI: SpecReviewRevealing {}

/// The spec review author loop on the Desktop (board #1121), app-lifetime:
/// - every finished reviewer round that hands the author open items is typed
///   into the ask's session once per app run, as one line
///   (`OwnerAskPrompt.specReviewLine`), keyed by the round's `finished_at`;
///   a held or queued line is tried again on the next poll;
/// - when the session is not running, the loop ends (`spec-review reveal
///   --reason session_gone`, once per ask per run) and the owner gets the ask;
/// - `progress` (session id → round) feeds the session row's line;
/// - `hidden` lists the asks in a loop for the stack's **Show Now**, which
///   ends one at once (`reveal --reason owner`).
///
/// Go writes `spec_reviews` from another process, so GRDB observation never
/// fires: a poll re-reads it. Owned by `AppState`.
@MainActor
@Observable
final class SpecReviewLoopCenter {
    nonisolated static let pollInterval: Duration = .seconds(3)

    /// Session id → the round of its author loop.
    private(set) var progress: [Int64: Int] = [:]

    /// Open asks hidden in their author loop.
    private(set) var hidden: [SpecReviewLoopQueries.HiddenLoop] = []

    @ObservationIgnored private let dbPool: DatabasePool
    @ObservationIgnored private let delivery: any SpecReviewLineDelivering
    @ObservationIgnored private let cli: any SpecReviewRevealing
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Rounds typed this run, as `ask id|finished_at`.
    @ObservationIgnored private var delivered: Set<String> = []
    /// Asks whose loop this run asked the CLI to end.
    @ObservationIgnored private var revealed: Set<Int64> = []
    /// A read error is logged once per streak of failures.
    @ObservationIgnored private var failing = false

    init(
        dbPool: DatabasePool,
        delivery: any SpecReviewLineDelivering,
        cli: any SpecReviewRevealing,
        pollInterval: Duration = SpecReviewLoopCenter.pollInterval
    ) {
        self.dbPool = dbPool
        self.delivery = delivery
        self.cli = cli
        self.pollInterval = pollInterval
    }

    /// The session row's line, "Spec review: round 2". The loop runs while
    /// the author's fixes hold (spec 2026-11-08 §1): its fuse is no target,
    /// so no "of N".
    nonisolated static func progressLine(round: Int) -> String {
        "Spec review: round \(round)"
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard !Task.isCancelled, let self else { return }
                await self.poll()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// One pass: re-reads progress and the pending rounds, then types each
    /// round not typed yet. Not private: tests drive it.
    func poll() async {
        let pending: [SpecReviewLoopQueries.PendingRound]
        do {
            let (rounds, latest, loops) = try await dbPool.read { db in
                (try SpecReviewLoopQueries.pending(db), try SpecReviewLoopQueries.progress(db),
                 try SpecReviewLoopQueries.hidden(db))
            }
            failing = false
            if latest != progress { progress = latest }
            if loops != hidden { hidden = loops }
            pending = rounds
        } catch {
            if !failing { NSLog("SpecReviewLoop: read failed: %@", "\(error)") }
            failing = true
            return
        }
        for round in pending {
            guard !Task.isCancelled else { return }
            await deliver(round)
        }
    }

    /// **Show Now**: ends the ask's loop for the owner, whatever round it is
    /// in; no findings line goes to the author after it. False when the CLI
    /// failed (logged).
    @discardableResult
    func showNow(askID: Int64) async -> Bool {
        revealed.insert(askID)
        // Its round's line never goes now: a line filed after it may.
        delivery.forgetSpecReviewLine(askID: askID)
        do {
            try await cli.specReviewReveal(askID: askID, reason: "owner")
        } catch {
            revealed.remove(askID)
            NSLog("SpecReviewLoop: ask %lld: show now failed: %@", askID, "\(error)")
            return false
        }
        await poll()
        return true
    }

    private func deliver(_ round: SpecReviewLoopQueries.PendingRound) async {
        let key = "\(round.askID)|\(round.finishedAt)"
        guard !delivered.contains(key), !revealed.contains(round.askID) else { return }
        let line = OwnerAskPrompt.specReviewLine(askID: round.askID, round: round.round, items: round.items)
        switch await delivery.deliverSpecReviewLine(line, askID: round.askID, sessionID: round.sessionID) {
        case .submitted, .typed, .copied:
            delivered.insert(key)
        case .held, .queued:
            break
        case .noSession:
            // Once per run: a failure is left to the daemon's sweep, which
            // ends a loop whose session is gone too.
            revealed.insert(round.askID)
            do {
                try await cli.specReviewReveal(askID: round.askID, reason: "session_gone")
            } catch {
                NSLog("SpecReviewLoop: ask %lld: reveal failed: %@", round.askID, "\(error)")
            }
        }
    }
}
