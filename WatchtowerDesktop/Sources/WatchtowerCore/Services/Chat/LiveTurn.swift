import Foundation
import Observation

/// Publishes at most once per `interval` (≈30 fps for streaming markdown).
package struct TextThrottle: Sendable {
    package let interval: TimeInterval
    private var lastPublish: Date?

    package init(interval: TimeInterval) {
        self.interval = interval
    }

    package mutating func shouldPublish(now: Date) -> Bool {
        if let lastPublish, now.timeIntervalSince(lastPublish) < interval { return false }
        lastPublish = now
        return true
    }
}

/// The one streaming assistant message. Its own observable, so only the row
/// showing it re-renders on a delta — the thread array and every finished
/// row stay untouched (render isolation).
@MainActor
@Observable
package final class LiveTurn {
    package enum Phase: Equatable {
        case running
        case complete
        case interrupted
        case failed(ChatSessionError)
    }

    package let messageID: Int64
    package let turnID: String
    package let startedAt: Date
    /// Throttled copy of `fullText` for rendering.
    package private(set) var text = ""
    package private(set) var steps: [ChatStepDisplay] = []
    package private(set) var phase: Phase = .running
    package private(set) var endedAt: Date?
    package private(set) var usage: ChatUsage?
    package internal(set) var persistError: String?

    /// Authoritative text — what is persisted.
    @ObservationIgnored package private(set) var fullText = ""
    @ObservationIgnored private var throttle: TextThrottle
    @ObservationIgnored private var trailingFlush: Task<Void, Never>?

    package init(messageID: Int64, turnID: String, startedAt: Date, publishInterval: TimeInterval = 1.0 / 30) {
        self.messageID = messageID
        self.turnID = turnID
        self.startedAt = startedAt
        throttle = TextThrottle(interval: publishInterval)
    }

    package var isRunning: Bool { phase == .running }

    package func appendDelta(_ chunk: String, now: Date) {
        fullText += chunk
        if throttle.shouldPublish(now: now) {
            text = fullText
            return
        }
        guard trailingFlush == nil else { return }
        let delay = Duration.milliseconds(Int(throttle.interval * 1000) + 1)
        trailingFlush = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.text = self.fullText
            self.trailingFlush = nil
        }
    }

    /// Returns the step's position (its persisted `seq`); a repeated
    /// `tool_start` for the same id reuses its step.
    @discardableResult
    package func startStep(_ start: ChatToolStart, at date: Date) -> Int {
        if let index = steps.firstIndex(where: { $0.id == start.id }) { return index }
        steps.append(ChatStepDisplay(id: start.id, name: start.name, argsJSON: start.argsJSON, state: .running,
                                     summary: "", sources: [], startedAt: date, endedAt: nil))
        return steps.count - 1
    }

    package func finishStep(_ end: ChatToolEnd, at date: Date) {
        guard let index = steps.firstIndex(where: { $0.id == end.id }) else {
            // A tool_end whose tool_start never arrived is still a visible step (CHAT-02).
            steps.append(ChatStepDisplay(id: end.id, name: "", argsJSON: "{}", state: end.ok ? .succeeded : .failed,
                                         summary: end.summary, sources: end.sources, startedAt: date, endedAt: date))
            return
        }
        steps[index].state = end.ok ? .succeeded : .failed
        steps[index].summary = end.summary
        steps[index].sources = end.sources
        steps[index].endedAt = date
    }

    package func setUsage(_ usage: ChatUsage) {
        self.usage = usage
    }

    package func finish(_ phase: Phase, at date: Date) {
        trailingFlush?.cancel()
        trailingFlush = nil
        text = fullText
        endedAt = date
        self.phase = phase
    }
}
