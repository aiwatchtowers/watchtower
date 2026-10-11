import Foundation
import GRDB
import os

/// A replica `ValueObservation` that outlives its own errors. GRDB ends an
/// observation for good on its first error, so a single failed read (device
/// locked, app suspended) would freeze its screen until the next launch.
/// After an error this logs it, reports it to `ObservationHealth`, waits
/// (1 s, doubling to 30 s, back to 1 s after the next value) and starts a
/// fresh observation from the same factory. `cancel()` stops it for good,
/// including a pending retry; so does releasing it. `onError` lets a screen
/// show the failure while it waits.
@MainActor
final class ResilientObservation {
    private static let firstDelay = Duration.seconds(1)
    private static let maxDelay = Duration.seconds(30)
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "ResilientObservation")

    private let name: String
    private let health: ObservationHealth
    private let sleep: @Sendable (Duration) async throws -> Void
    private let onError: @MainActor (any Error) -> Void
    /// Starts one observation; `onError` ends it, `onValue` follows a delivered value.
    private let startObserving: @MainActor (
        _ onError: @escaping @MainActor (any Error) -> Void,
        _ onValue: @escaping @MainActor () -> Void
    ) -> AnyDatabaseCancellable
    private var current: AnyDatabaseCancellable?
    private var retry: Task<Void, Never>?
    private var delay = ResilientObservation.firstDelay
    private var isCancelled = false

    /// Starts at once. `observation` is called again for every restart.
    init<Reducer: ValueReducer>(
        name: String,
        reader: any DatabaseReader,
        health: ObservationHealth = .shared,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        observation: @escaping @Sendable () -> ValueObservation<Reducer>,
        onError: @escaping @MainActor (any Error) -> Void = { _ in },
        onChange: @escaping @MainActor (Reducer.Value) -> Void
    ) {
        self.name = name
        self.health = health
        self.sleep = sleep
        self.onError = onError
        startObserving = { onError, onValue in
            observation().start(
                in: reader,
                scheduling: .async(onQueue: .main),
                onError: { error in MainActor.assumeIsolated { onError(error) } },
                onChange: { value in
                    MainActor.assumeIsolated {
                        onChange(value)
                        onValue()
                    }
                }
            )
        }
        begin()
    }

    func cancel() {
        isCancelled = true
        retry?.cancel()
        retry = nil
        current = nil
    }

    private func begin() {
        current = startObserving(
            { [weak self] error in self?.failed(error) },
            { [weak self] in self?.delivered() }
        )
    }

    private func delivered() {
        delay = Self.firstDelay
        health.recordValue(name)
    }

    private func failed(_ error: any Error) {
        guard !isCancelled else { return }
        Self.logger.error("\(self.name, privacy: .public) observation failed: \(error.localizedDescription, privacy: .public)")
        health.recordFailure(name, error: error)
        onError(error)
        current = nil
        let wait = delay
        delay = min(delay * 2, Self.maxDelay)
        let sleep = sleep
        retry = Task { [weak self] in
            do {
                try await sleep(wait)
            } catch {
                return
            }
            guard let self, !self.isCancelled else { return }
            self.begin()
        }
    }
}
