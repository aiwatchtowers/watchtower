import Foundation
import Observation

/// Publishes at most once per interval: `interval` (≈30 fps) for a short
/// text, stretched with the text's length. A published delta re-parses and
/// re-lays out the whole streamed message on the main actor, so its cost
/// grows with the text (~5 ms at 2k chars, ~22 ms at 10k, ~70 ms at 30k —
/// `TextRenderingBenchmarkTests`); at a fixed 30 fps a long answer would
/// saturate the main actor and freeze the whole UI while it streams.
package struct TextThrottle: Sendable {
    package let interval: TimeInterval
    private var lastPublish: Date?

    /// Interval per character: keeps a publish's render under roughly a
    /// third of the main actor (10k chars → ~65 ms) up to the cap, reached
    /// at ~38k chars; past it a publish's share grows again.
    static let secondsPerCharacter: TimeInterval = 6.5e-6
    /// The slowest cadence, so a very long answer still visibly flows.
    static let maxInterval: TimeInterval = 0.25

    package init(interval: TimeInterval) {
        self.interval = interval
    }

    package func interval(forLength length: Int) -> TimeInterval {
        max(interval, min(Double(length) * Self.secondsPerCharacter, Self.maxInterval))
    }

    package mutating func shouldPublish(now: Date, length: Int) -> Bool {
        if let lastPublish, now.timeIntervalSince(lastPublish) < interval(forLength: length) { return false }
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
    /// `fullText.utf16.count`, kept incrementally (O(chunk), not O(text)).
    @ObservationIgnored private var fullLength = 0
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
        fullLength += chunk.utf16.count
        publishOrScheduleFlush(now: now)
    }

    private func publishOrScheduleFlush(now: Date) {
        if throttle.shouldPublish(now: now, length: fullLength) {
            // A pending flush would only re-publish this same text a moment
            // later — a second full re-render of a long message.
            trailingFlush?.cancel()
            trailingFlush = nil
            text = fullText
            return
        }
        scheduleTrailingFlush()
    }

    private func scheduleTrailingFlush() {
        guard trailingFlush == nil else { return }
        let delay = Duration.milliseconds(Int(throttle.interval(forLength: fullLength) * 1000) + 1)
        trailingFlush = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.text = self.fullText
            self.trailingFlush = nil
        }
    }

    /// Replaces the whole text (a `.reset` or `.turnComplete` from the
    /// embedded chats' `ai query` stream), throttled like `appendDelta`.
    package func replaceText(_ newText: String, now: Date) {
        fullText = newText
        fullLength = newText.utf16.count
        publishOrScheduleFlush(now: now)
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
