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
    private var _providers: [String?] = []
    /// Every provider passed to `stream`, in call order.
    var providers: [String?] { lock.withLock { _providers } }

    init(events: [StreamEvent] = [.text("Hello from Claude"), .done]) {
        self.events = events
        self.eventSequence = []
        self.error = nil
    }

    /// Create a mock that returns different events for each successive call.
    init(eventSequence: [[StreamEvent]]) {
        self.events = []
        self.eventSequence = eventSequence
        self.error = nil
    }

    init(error: any Error) {
        self.events = []
        self.eventSequence = []
        self.error = error
    }

    func stream(
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
                    continuation.yield(event)
                }
                continuation.finish()
            }
        }
    }
}
