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
///
/// While its `ReplicaObservationGate` is suspended (the app in the
/// background, board #724) it holds no observation, so no replica write
/// wakes it; on resume it starts a fresh one, whose first value is the
/// latest.
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
    private var isSuspended = false
    private let gate: ReplicaObservationGate

    /// Starts at once, or on the gate's resume while it is suspended
    /// (`gate` nil is `.shared`). `observation` is called again for every
    /// restart.
    init<Reducer: ValueReducer>(
        name: String,
        reader: any DatabaseReader,
        health: ObservationHealth = .shared,
        gate: ReplicaObservationGate? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        observation: @escaping @Sendable () -> ValueObservation<Reducer>,
        onError: @escaping @MainActor (any Error) -> Void = { _ in },
        onChange: @escaping @MainActor (Reducer.Value) -> Void
    ) {
        self.name = name
        self.health = health
        self.sleep = sleep
        self.onError = onError
        self.gate = gate ?? .shared
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
        self.gate.register(self)
        if self.gate.isSuspended {
            isSuspended = true
        } else {
            begin()
        }
    }

    func cancel() {
        isCancelled = true
        retry?.cancel()
        retry = nil
        current = nil
    }

    /// Drops the observation and any pending retry until `resume()`.
    func suspend() {
        guard !isCancelled, !isSuspended else { return }
        isSuspended = true
        retry?.cancel()
        retry = nil
        current = nil
    }

    /// Starts a fresh observation: its first value is the replica's latest.
    func resume() {
        guard !isCancelled, isSuspended else { return }
        isSuspended = false
        delay = Self.firstDelay
        begin()
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
        guard !isCancelled, !isSuspended else { return }
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
            guard let self, !self.isCancelled, !self.isSuspended else { return }
            self.begin()
        }
    }
}

/// Suspends every replica observation while the app is in the background
/// (board #724): nothing on screen needs them there, and each replica
/// write would otherwise re-read and re-decode in the background. The
/// outbox, the uploader and the relay feed read the store directly and
/// never wait on an observation. The app drives `.shared` from its scene
/// phase; tests build their own.
@MainActor
final class ReplicaObservationGate {
    static let shared = ReplicaObservationGate()

    private(set) var isSuspended = false
    private var members: [WeakObservation] = []

    private struct WeakObservation {
        weak var observation: ResilientObservation?
    }

    /// Suspends every live observation, or resumes each with its latest
    /// value; a repeated call changes nothing.
    func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        members.removeAll { $0.observation == nil }
        for member in members {
            if suspended {
                member.observation?.suspend()
            } else {
                member.observation?.resume()
            }
        }
    }

    fileprivate func register(_ observation: ResilientObservation) {
        members.removeAll { $0.observation == nil }
        members.append(WeakObservation(observation: observation))
    }
}
