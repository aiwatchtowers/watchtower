import Foundation

/// The one wait the chat models make (the list's Undo window), injected so tests never wait on the wall clock.
public protocol ChatUIClock: Sendable {
    func sleep(for duration: Duration) async throws
}

/// The real clock.
public struct ContinuousChatUIClock: ChatUIClock {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
