import Foundation
import WatchtowerCore

package final class MockClaudeService: AIServiceProtocol, @unchecked Sendable {
    private let events: [StreamEvent]
    private let eventSequence: [[StreamEvent]]
    private let error: (any Error)?
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

    package init(events: [StreamEvent] = [.text("Hello from Claude"), .done]) {
        self.events = events
        self.eventSequence = []
        self.error = nil
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
        extraAllowedTools: [String]
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        lock.withLock {
            _prompts.append(prompt)
            _providers.append(provider)
            _sessionIDs.append(sessionID)
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
        return AsyncThrowingStream { continuation in
            Task {
                for event in eventsToUse {
                    continuation.yield(event)
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
