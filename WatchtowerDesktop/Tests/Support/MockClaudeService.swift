import Foundation
import WatchtowerCore

package final class MockClaudeService: AIServiceProtocol, @unchecked Sendable {
    private let events: [StreamEvent]
    private let eventSequence: [[StreamEvent]]
    private let error: (any Error)?
    private var hangs = false
    private let lock = NSLock()
    private var _callIndex = 0
    private var callIndex: Int {
        get { lock.withLock { _callIndex } }
        set { lock.withLock { _callIndex = newValue } }
    }
    private var _prompts: [String] = []
    /// Every prompt passed to `stream`, in call order.
    package var prompts: [String] { lock.withLock { _prompts } }
    private var _providers: [String?] = []
    /// Every provider passed to `stream`, in call order.
    package var providers: [String?] { lock.withLock { _providers } }
    private var _sessionIDs: [String?] = []
    /// Every sessionID passed to `stream`, in call order.
    package var sessionIDs: [String?] { lock.withLock { _sessionIDs } }
    private var _systemPrompts: [String?] = []
    /// Every systemPrompt passed to `stream`, in call order — nil on the turns
    /// that resume a session instead of opening one.
    package var systemPrompts: [String?] { lock.withLock { _systemPrompts } }
    private var _toolModes: [ChatToolMode?] = []
    /// Every toolMode passed to `stream`, in call order — nil on every
    /// draft-only surface (AGENT-04).
    package var toolModes: [ChatToolMode?] { lock.withLock { _toolModes } }

    package init(events: [StreamEvent] = [.text("Hello from Claude"), .done]) {
        self.events = events
        self.eventSequence = []
        self.error = nil
    }

    /// Create a mock that yields `events` and then leaves the stream OPEN
    /// forever — the consumer sees the events but the stream never finishes
    /// until the consuming task is cancelled. Simulates a run that is still
    /// mid-stream when something (a supersede, a user cancel) interrupts it.
    package init(events: [StreamEvent], thenHangs: Bool) {
        self.events = events
        self.eventSequence = []
        self.error = nil
        self.hangs = thenHangs
    }

    /// Create a mock that yields `events` first, then fails the stream —
    /// simulates a mid-stream error after partial output.
    package init(events: [StreamEvent], thenError: any Error) {
        self.events = events
        self.eventSequence = []
        self.error = thenError
    }

    /// Create a mock that returns different events for each successive call.
    package init(eventSequence: [[StreamEvent]]) {
        self.events = []
        self.eventSequence = eventSequence
        self.error = nil
    }

    package init(error: any Error) {
        self.events = []
        self.eventSequence = []
        self.error = error
    }

    package func stream(
        prompt: String,
        systemPrompt: String?,
        sessionID: String?,
        dbPath: String?,
        model: String?,
        provider: String?,
        toolMode: ChatToolMode?
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        lock.withLock {
            _prompts.append(prompt)
            _providers.append(provider)
            _sessionIDs.append(sessionID)
            _systemPrompts.append(systemPrompt)
            _toolModes.append(toolMode)
        }
        let eventsToUse: [StreamEvent]
        if !eventSequence.isEmpty {
            let idx = callIndex
            callIndex += 1
            eventsToUse = idx < eventSequence.count ? eventSequence[idx] : eventSequence[eventSequence.count - 1]
        } else {
            eventsToUse = events
        }
        let error = self.error
        let hangs = self.hangs
        return AsyncThrowingStream { continuation in
            Task {
                for event in eventsToUse {
                    continuation.yield(event)
                }
                if hangs {
                    // Leave the stream open: the consumer's `for try await`
                    // only ends when its own task is cancelled.
                    return
                }
                if let error {
                    continuation.finish(throwing: error)
                } else {
                    continuation.finish()
                }
            }
        }
    }
}
