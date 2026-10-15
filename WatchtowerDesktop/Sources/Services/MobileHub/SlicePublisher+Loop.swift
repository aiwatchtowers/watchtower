import Foundation
import GRDB
import os
import WatchtowerCore
import WatchtowerSync

extension SlicePublisher {
    // MARK: - Fast lane

    /// Asks for the urgent ones among `kinds` to be published soon: after
    /// the 1 s coalescing window, and at least 2 s after the previous fast
    /// send. The other kinds ride the next full tick (≤ 30 s), which diffs
    /// every kind anyway.
    func nudge(kinds: Set<SliceKind>) {
        let urgent = kinds.intersection(Self.urgentKinds)
        guard !urgent.isEmpty else { return }
        lane.withLock { lane in
            if lane.pendingKinds.isEmpty { lane.firstNudgeAt = clock() }
            lane.pendingKinds.formUnion(urgent)
            lane.sleep?.cancel()
        }
    }

    /// When the pending nudges may be sent: the end of the 1 s window, but
    /// no sooner than 2 s after the previous fast send. nil with nothing
    /// pending.
    var fastDeadline: ContinuousClock.Instant? {
        lane.withLock { [timing] in Self.fastDeadline($0, timing: timing) }
    }

    private static func fastDeadline(_ lane: Lane, timing: Timing) -> ContinuousClock.Instant? {
        guard !lane.pendingKinds.isEmpty, let first = lane.firstNudgeAt else { return nil }
        let windowEnd = first + timing.fastWindow
        guard let last = lane.lastFastSendAt else { return windowEnd }
        return max(windowEnd, last + timing.fastSpacing)
    }

    /// The cycle due at `now` (taken: its deadlines move on), nil when none
    /// is. The full tick first (it covers every pending nudge), then the
    /// urgent tick and the fast lane's nudges, merged into one cycle.
    func takeDueCycle(now: ContinuousClock.Instant) -> Cycle? {
        lane.withLock { [timing] lane in
            if lane.nextTick.map({ now >= $0 }) ?? true {
                lane.nextTick = now + timing.tick
                lane.nextUrgentTick = now + timing.urgentTick
                lane.tookTick = true
                lane.tookUrgentTick = true
                lane.pendingKinds = []
                lane.firstNudgeAt = nil
                return .full
            }
            let fastDue = Self.fastDeadline(lane, timing: timing).map { now >= $0 } ?? false
            let urgentDue = lane.nextUrgentTick.map { now >= $0 } ?? true
            guard fastDue || urgentDue else { return nil }
            var kinds: Set<SliceKind> = []
            if fastDue {
                kinds = lane.pendingKinds
                lane.pendingKinds = []
                lane.firstNudgeAt = nil
                lane.lastFastSendAt = now
            }
            if urgentDue {
                kinds.formUnion(Self.urgentKinds)
                lane.nextUrgentTick = now + timing.urgentTick
                lane.tookUrgentTick = true
            }
            return .urgent(kinds)
        }
    }

    /// The end of a cycle: the ticks it took count from now.
    private func cycleEnded() {
        let end = clock()
        lane.withLock { [timing] lane in
            if lane.tookTick { lane.nextTick = end + timing.tick }
            if lane.tookUrgentTick { lane.nextUrgentTick = end + timing.urgentTick }
            lane.tookTick = false
            lane.tookUrgentTick = false
        }
    }

    /// The earliest of the full and urgent ticks (the loop's wake without
    /// a nudge); `fallback` before the first cycle.
    private func nextTickDeadline(fallback: ContinuousClock.Instant) -> ContinuousClock.Instant {
        lane.withLock { lane in
            [lane.nextTick, lane.nextUrgentTick].compactMap { $0 }.min() ?? fallback
        }
    }

    private func sleepUntilNextDeadline() async {
        let sleep = beginSleep(tick: nextTickDeadline(fallback: clock()))
        // stop() may have cancelled the loop before this sleep existed.
        if Task.isCancelled { sleep.cancel() }
        await sleep.value
        endSleep(sleep)
    }

    /// Stores and returns the loop's sleep until the next deadline (the
    /// tick, or the fast lane's deadline when sooner). Under the nudge lock,
    /// so a nudge can never fall between "deadline computed" and "stored".
    func beginSleep(tick: ContinuousClock.Instant) -> Task<Void, Never> {
        lane.withLock { [timing] lane in
            let deadline = Self.fastDeadline(lane, timing: timing).map { min($0, tick) } ?? tick
            let task = Task<Void, Never> { _ = try? await Task.sleep(until: deadline, clock: .continuous) }
            lane.sleep = task
            return task
        }
    }

    /// Forgets `sleep` once it returned — only when it is still the stored
    /// handle: a restarted loop may have stored its own meanwhile.
    func endSleep(_ sleep: Task<Void, Never>) {
        lane.withLock { lane in
            if lane.sleep == sleep { lane.sleep = nil }
        }
    }

    // MARK: - Loop

    /// Starts the loop; the first full cycle runs at once.
    func start() {
        assets?.open()
        lane.withLock { lane in
            lane.nextTick = nil
            lane.nextUrgentTick = nil
        }
        let task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let cycle = self.takeDueCycle(now: self.clock()) {
                    await self.run(cycle)
                } else {
                    await self.sleepUntilNextDeadline()
                }
            }
        }
        loopTask.withLock { current in
            current?.cancel()
            current = task
        }
        // A start() without stop(): the old loop's sleep must not outlive it.
        lane.withLock { $0.sleep?.cancel() }
    }

    /// One loop cycle over what the link state allows, then the immediate
    /// send when it changed an urgent record (the lane's ≥ 2 s spacing and
    /// the urgent tick bound the send rate; the transport itself honours a
    /// throttle wait or a stop). nil when it failed.
    ///
    /// The first cycle that sees a phone linked runs the urgent kinds alone
    /// first and sends them, so the new phone's grant (which its link flow
    /// waits 60 s for) never queues behind the backlog of every other kind;
    /// then it diffs every kind. The returned outcome covers both.
    @discardableResult
    func run(_ cycle: Cycle) async -> Outcome? {
        let linked = isLinked()
        let newlyLinked = linked && unlinkedAtLastCycle.withLock { $0 }
        if !linked { unlinkedAtLastCycle.withLock { $0 = true } }
        var first: Outcome?
        if newlyLinked {
            first = await runCycle(kinds: Self.urgentKinds)
            if let first, first.urgentChanges > 0 { await sendAtOnce() }
        }
        var outcome = await runCycle(kinds: scope(of: cycle, linked: linked, newlyLinked: newlyLinked))
        if newlyLinked, outcome?.completed == true {
            unlinkedAtLastCycle.withLock { $0 = false }
        }
        if let current = outcome, current.urgentChanges > 0 {
            await sendAtOnce()
        }
        if let first { outcome?.absorb(first) }
        cycleEnded()
        if case .urgent = cycle { fastCycles.withLock { $0 += 1 } }
        return outcome
    }

    /// The transport's immediate send. Stamped as a fast send, so the fast
    /// lane keeps its ≥ 2 s spacing after any cycle's send.
    private func sendAtOnce() async {
        await sendNow()
        let sentAt = clock()
        lane.withLock { $0.lastFastSendAt = sentAt }
    }

    /// The kinds a cycle diffs (nil: every kind). Without a linked phone
    /// only `unlinkedKinds`; a newly linked phone gets every kind.
    private func scope(of cycle: Cycle, linked: Bool, newlyLinked: Bool) -> Set<SliceKind>? {
        let requested: Set<SliceKind>? = {
            if case .urgent(let kinds) = cycle { return kinds }
            return nil
        }()
        guard linked else { return (requested ?? Set(SliceKind.allCases)).intersection(Self.unlinkedKinds) }
        return newlyLinked ? nil : requested
    }

    /// One cycle; nil when it failed.
    private func runCycle(kinds: Set<SliceKind>?) async -> Outcome? {
        do {
            let outcome = try await publishOnce(kinds: kinds)
            if !outcome.skipped.isEmpty {
                logger.debug("publish cycle skipped \(outcome.skipped.count) records")
            }
            return outcome
        } catch {
            logger.error("publish cycle failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func stop() {
        loopTask.withLock { current in
            current?.cancel()
            current = nil
        }
        // The sleep sub-task does not observe the loop's cancellation.
        lane.withLock { $0.sleep?.cancel() }
    }
}
