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
/// keybox instead.
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

    /// Starts at once. `observation` is called again for every restart.
    init<Reducer: ValueReducer>(
        name: String,
        reader: any DatabaseReader,
        health: ObservationHealth = .shared,
        unlocks: NotificationCenter = .default,
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
        begin()
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

    /// The unlock signal: an observation waiting for the keys starts again now.
    private func unlocked() {
        guard waitsForKeys, !isCancelled else { return }
        waitsForKeys = false
        retry?.cancel()
        retry = nil
        delay = Self.firstDelay
        begin()
    }

    private func failed(_ error: any Error) {
        guard !isCancelled else { return }
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
            guard let self, !self.isCancelled else { return }
            self.begin()
        }
    }
}
