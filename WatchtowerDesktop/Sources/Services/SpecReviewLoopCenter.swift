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
}

extension SessionLineDelivery: SpecReviewLineDelivering {
    func deliverSpecReviewLine(_ line: String, askID: Int64, sessionID: Int64) async -> Delivery {
        var delivery = await deliverLine(line, key: .specReview(askID), sessionID: sessionID) { _ in }
        // A session not reattached yet after Keep Sessions and Quit or an
        // update is not gone: revealing it would end a live author's loop.
        if delivery == .noSession, !hostRunsSettled || isLive(sessionID) {
            delivery = .held
        }
        if delivery == .held || delivery == .queued {
            // The center's next poll owns the retry: the line must not also
            // go from the held queue, nor after the round was revealed.
            dropHeld(sessionID: sessionID) { $0 == .specReview(askID) }
        }
        return delivery
    }
}

/// Ends an author loop whose session is gone (`WorkbenchCLI` in the app).
@MainActor
protocol SpecReviewRevealing {
    func specReviewReveal(askID: Int64) async throws
}

extension WorkbenchCLI: SpecReviewRevealing {}

/// The spec review author loop on the Desktop (board #1121), app-lifetime:
/// - every finished reviewer round that hands the author open items is typed
///   into the ask's session once per app run, as one line
///   (`OwnerAskPrompt.specReviewLine`), keyed by the round's `finished_at`;
///   a held or queued line is tried again on the next poll;
/// - when the session is not running, the loop ends (`spec-review reveal
///   --reason session_gone`, once per ask per run) and the owner gets the ask;
/// - `progress` (session id → round) feeds the session row's line.
///
/// Go writes `spec_reviews` from another process, so GRDB observation never
/// fires: a poll re-reads it. Owned by `AppState`.
@MainActor
@Observable
final class SpecReviewLoopCenter {
    nonisolated static let pollInterval: Duration = .seconds(3)
    /// The loop's round cap (Go `specreview.MaxLoopRounds`).
    nonisolated static let maxRounds = 3

    /// Session id → the round of its author loop.
    private(set) var progress: [Int64: Int] = [:]

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

    /// The session row's line, "Spec review: round 2 of 3".
    nonisolated static func progressLine(round: Int) -> String {
        "Spec review: round \(round) of \(maxRounds)"
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
            let (rounds, latest) = try await dbPool.read { db in
                (try SpecReviewLoopQueries.pending(db), try SpecReviewLoopQueries.progress(db))
            }
            failing = false
            if latest != progress { progress = latest }
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
                try await cli.specReviewReveal(askID: round.askID)
            } catch {
                NSLog("SpecReviewLoop: ask %lld: reveal failed: %@", round.askID, "\(error)")
            }
        }
    }
}
