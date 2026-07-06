import Foundation
@testable import WatchtowerDesktop

final class MockClaudeService: AIServiceProtocol, @unchecked Sendable {
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
    var prompts: [String] { lock.withLock { _prompts } }
    private var _systemPrompts: [String?] = []
    /// Every systemPrompt passed to `stream`, in call order.
    var systemPrompts: [String?] { lock.withLock { _systemPrompts } }
    private var _sessionIDs: [String?] = []
    /// Every sessionID passed to `stream`, in call order.
    var sessionIDs: [String?] { lock.withLock { _sessionIDs } }
    /// Optional pause before each yielded event so time-based chunk batching is testable.
    private let eventDelay: Duration?

    init(events: [StreamEvent] = [.text("Hello from Claude"), .done], eventDelay: Duration? = nil) {
        self.events = events
        self.eventSequence = []
        self.error = nil
        self.eventDelay = eventDelay
    }

    /// Create a mock that returns different events for each successive call.
    init(eventSequence: [[StreamEvent]]) {
        self.events = []
        self.eventSequence = eventSequence
        self.error = nil
        self.eventDelay = nil
    }

    init(error: any Error) {
        self.events = []
        self.eventSequence = []
        self.error = error
        self.eventDelay = nil
    }

    func stream(
        prompt: String,
        systemPrompt: String?,
        sessionID: String?,
        dbPath: String?,
        model: String?,
        extraAllowedTools: [String]
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        lock.withLock {
            _prompts.append(prompt)
            _systemPrompts.append(systemPrompt)
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
                if let error {
                    continuation.finish(throwing: error)
                    return
                }
                for event in eventsToUse {
                    if let delay = self.eventDelay {
                        try? await Task.sleep(for: delay)
                    }
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }
}
