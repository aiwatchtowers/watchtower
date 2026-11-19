import Foundation

/// A transport with a lifecycle and live events: what the phone drives beyond
/// plain save / delete / changes. `CloudSyncTransport` stays three requirements;
/// this is the optional surface.
public protocol LiveTransport: CloudSyncTransport, Sendable {
    func start() async
    func stop() async
    func sendNow() async
    func pull() async throws
    func fetchForPush(since: Date, grace: TimeInterval, pollOnFallback: Bool) async throws
    func availability() async -> CloudAvailability
    func setEventHandler(_ handler: (@Sendable (TransportEvent) -> Void)?) async
    func setAccountResetHandler(_ handler: (@Sendable () -> Void)?) async
    func setEngineFetchedHandler(_ handler: (@Sendable () -> Void)?) async
    /// The app became active (live link R6): bring the live connection up before the return's fetch reads.
    func wake() async
}

extension LiveTransport {
    /// Nothing to wake: a transport with no socket of its own (CloudKit).
    public func wake() async {}
}
