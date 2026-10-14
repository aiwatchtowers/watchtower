import Foundation
import GRDB
import os
import UIKit
import WatchtowerSync

/// A replica `ValueObservation` that outlives its own errors. GRDB ends an
/// observation for good on its first error, so a single failed read (device
/// locked, app suspended) would freeze its screen until the next launch.
/// After an error this logs it, reports it to `ObservationHealth`, waits
/// (1 s, doubling to 30 s, back to 1 s after the next value) and starts a
/// fresh observation from the same factory. `cancel()` stops it for good,
/// including a pending retry; so does releasing it. `onError` lets a screen
/// show the failure while it waits.
///
/// Mobile E2E: a read the keychain refuses (`KeyStoreError.locked`, or
/// `SecureTransportError.keysUnavailable` while an epoch's keys have not
/// arrived) is not a failure: it is not reported to `ObservationHealth`, the
/// screen keeps its last value and is told it waits for the keys
/// (`onWaitingForKeys`), and the observation starts again at the unlock
/// signal (`protectedDataDidBecomeAvailable` on `unlocks`) without waiting
/// out its backoff; the backoff still retries, for keys that arrive with a
/// keybox instead. EVERY live observation starts again at the unlock signal,
/// not only one whose read threw: a list read (`ReplicaStore.payloads(of:)`)
/// skips the rows it cannot open while locked and delivers what is left
/// (often nothing), so only a fresh read after unlock fills it again.
///
/// While its `ReplicaObservationGate` is suspended (the app in the
/// background, board #724) it holds no observation, so no replica write
/// wakes it; on resume it starts a fresh one, whose first value is the
/// latest. The unlock signal leaves a suspended observation alone: its
/// resume reads fresh anyway.
@MainActor
final class ResilientObservation {
    private static let firstDelay = Duration.seconds(1)
    private static let maxDelay = Duration.seconds(30)
    nonisolated private static let logger = Logger(subsystem: "WatchtowerMobile", category: "ResilientObservation")

    private let name: String
    private let health: ObservationHealth
    private let sleep: @Sendable (Duration) async throws -> Void
    private let onError: @MainActor (any Error) -> Void
    private let onWaitingForKeys: @MainActor () -> Void
    /// Starts one observation; `onError` ends it, `onValue` follows a delivered value.
    private let startObserving: @MainActor (
        _ onError: @escaping @MainActor (any Error) -> Void,
        _ onValue: @escaping @MainActor () -> Void
    ) -> AnyDatabaseCancellable
    private var current: AnyDatabaseCancellable?
    private var retry: Task<Void, Never>?
    private var delay = ResilientObservation.firstDelay
    private var isCancelled = false
    /// The last read was refused for the keys: the unlock signal restarts at once.
    private var waitsForKeys = false
    private var unlockToken: NotificationToken?
    private var isSuspended = false
    private let gate: ReplicaObservationGate

    /// Starts at once, or on the gate's resume while it is suspended
    /// (`gate` nil is `.shared`). `observation` is called again for every
    /// restart.
    init<Reducer: ValueReducer>(
        name: String,
        reader: any DatabaseReader,
        health: ObservationHealth = .shared,
        unlocks: NotificationCenter = .default,
        gate: ReplicaObservationGate? = nil,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        observation: @escaping @Sendable () -> ValueObservation<Reducer>,
        onError: @escaping @MainActor (any Error) -> Void = { _ in },
        onWaitingForKeys: @escaping @MainActor () -> Void = {},
        onChange: @escaping @MainActor (Reducer.Value) -> Void
    ) {
        self.name = name
        self.health = health
        self.sleep = sleep
        self.onError = onError
        self.onWaitingForKeys = onWaitingForKeys
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
        let unlocked: @MainActor () -> Void = { [weak self] in self?.unlocked() }
        unlockToken = NotificationToken(
            center: unlocks, name: UIApplication.protectedDataDidBecomeAvailableNotification, handler: unlocked
        )
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
        unlockToken = nil
    }

    /// A read refused for the keys, not a fault of the read: a locked keychain, or an epoch whose keys have not
    /// arrived yet.
    static func waitsForKeys(_ error: any Error) -> Bool {
        (error as? KeyStoreError) == .locked || (error as? SecureTransportError) == .keysUnavailable
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
        waitsForKeys = false
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
        waitsForKeys = false
        health.recordValue(name)
    }

    /// The unlock signal: the observation starts again now (a waiting one, or a
    /// live one whose last value may have left out rows locked at the time).
    private func unlocked() {
        guard !isCancelled, !isSuspended else { return }
        waitsForKeys = false
        retry?.cancel()
        retry = nil
        delay = Self.firstDelay
        begin()
    }

    private func failed(_ error: any Error) {
        guard !isCancelled, !isSuspended else { return }
        if Self.waitsForKeys(error) {
            Self.logger.notice("\(self.name, privacy: .public) observation waits for the keys")
            waitsForKeys = true
            onWaitingForKeys()
        } else {
            Self.logger.error("\(self.name, privacy: .public) observation failed: \(error.localizedDescription, privacy: .public)")
            health.recordFailure(name, error: error)
            onError(error)
        }
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
