import Foundation
import os
import WatchtowerCore

/// The transport surface the hub needs beyond record I/O: lifecycle and
/// availability probing. CloudKitTransport satisfies it natively; tests
/// stub availability with a canned value.
protocol HubTransport: CloudSyncTransport, Sendable {
    func start() async
    func pull() async throws
    func availability() async -> CloudAvailability
    /// Set the account-change reset callback before `start()`.
    func setAccountResetHandler(_ handler: (@Sendable () -> Void)?) async
}

extension CloudKitTransport: HubTransport {}

enum HubStatus: Equatable {
    case off
    case starting
    case running
    /// CloudKit can't be used (no entitlement on unsigned dev builds, no
    /// iCloud account, …) — expected and harmless; no loops run.
    case unavailable(String)
}

/// Composition root of the mobile hub: owns the slice-publisher loop, the
/// adaptive relay loop (actions + chat + daily hygiene) and the heartbeat
/// that tells mobile the desktop is alive. Started from Settings via the
/// "mobileSyncEnabled" toggle; all intervals are injectable for tests.
@MainActor
@Observable
final class MobileHubService {
    private(set) var status: HubStatus = .off

    private let transport: any HubTransport
    private let publisher: SlicePublisher
    private let processor: RelayProcessor
    private let sidecar: HubSyncState
    private let publishInterval: Duration
    private let relayIdleInterval: Duration
    private let relayActiveInterval: Duration
    private let heartbeatInterval: Duration
    private let availabilityReprobeInterval: Duration
    /// Whether mobile sync is enabled — injected by AppState (the UserDefaults
    /// read lives there), so the service itself has no settings dependency.
    private let isEnabled: @Sendable () -> Bool
    private let appVersion: String
    private let now: @Sendable () -> Date
    private var relayTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    /// Runs only while `.unavailable`: periodically re-probes iCloud and
    /// restarts the hub when it comes back. Cancelled by stop() and on any
    /// successful start.
    private var reprobeTask: Task<Void, Never>?
    private let logger = Logger(subsystem: Constants.bundleID, category: "MobileHubService")
    /// Bumped by stop() so a queued start() that was enqueued before stop() can
    /// detect it lost the race and bail — even if it hasn't entered start() yet.
    private var epoch = 0

    /// Relay activity younger than this keeps the fast poll cadence —
    /// chat stays responsive without push entitlements.
    private static let activityWindow: TimeInterval = 300

    init(
        transport: any HubTransport,
        publisher: SlicePublisher,
        processor: RelayProcessor,
        sidecar: HubSyncState,
        publishInterval: Duration = .seconds(60),
        relayIdleInterval: Duration = .seconds(30),
        relayActiveInterval: Duration = .seconds(3),
        heartbeatInterval: Duration = .seconds(300),
        availabilityReprobeInterval: Duration = .seconds(600),
        appVersion: String = Constants.appVersion,
        now: @escaping @Sendable () -> Date = { Date() },
        isEnabled: @escaping @Sendable () -> Bool
    ) {
        self.transport = transport
        self.publisher = publisher
        self.processor = processor
        self.sidecar = sidecar
        self.publishInterval = publishInterval
        self.relayIdleInterval = relayIdleInterval
        self.relayActiveInterval = relayActiveInterval
        self.heartbeatInterval = heartbeatInterval
        self.availabilityReprobeInterval = availabilityReprobeInterval
        self.isEnabled = isEnabled
        self.appVersion = appVersion
        self.now = now
    }

    /// Starts the transport, gates on availability (unavailable on unsigned
    /// dev builds is expected — records queue in the store), then spins up
    /// the three loops. Safe to call again after `.unavailable` or `stop()`.
    /// While `.unavailable`, a re-probe loop retries availability every
    /// `availabilityReprobeInterval` and auto-recovers when iCloud returns.
    func start() async {
        // Guard against a queued start() arriving after stop() already ran: if
        // sync is disabled we must not proceed regardless of current status.
        guard isEnabled() else { return }
        guard status != .running, status != .starting else { return }
        status = .starting
        let startEpoch = epoch
        // Register the reset handler BEFORE start() so a CloudKit account change
        // observed during startup wipes the derived sync state: cleared slice
        // hashes make the next publish cycle re-push the full slice, and the
        // cleared relay token makes the relay re-read its zone from scratch.
        let sidecar = self.sidecar
        let logger = self.logger
        await transport.setAccountResetHandler {
            do {
                try sidecar.wipeSyncState()
            } catch {
                logger.error("account reset: wipeSyncState failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        await transport.start()
        let availability = await transport.availability()
        // stop() may have flipped the toggle off or bumped the epoch while we
        // awaited above — either condition means we lost the race.
        guard status == .starting, epoch == startEpoch else { return }
        guard case .available = availability else {
            status = .unavailable(Self.describe(availability))
            startReprobeLoop()
            return
        }
        // A stale re-probe loop (e.g. start() called manually while one was
        // waiting) must not fire into a running hub.
        reprobeTask?.cancel()
        reprobeTask = nil
        publisher.start(interval: publishInterval)
        startRelayLoop()
        startHeartbeatLoop()
        status = .running
    }

    /// Feature Manager satellite: hands the effective feature map to the
    /// publisher (which nudges its loop so the change syncs now). Safe in
    /// every status — before start() the snapshot simply waits for the loop.
    func updateFeatureStates(_ states: [String: Bool]) {
        publisher.updateFeatureStates(states)
    }

    func stop() {
        publisher.stop()
        relayTask?.cancel()
        relayTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        reprobeTask?.cancel()
        reprobeTask = nil
        // Bump epoch so any queued or in-flight start() detects it lost the race.
        epoch &+= 1
        status = .off
    }

    // MARK: - Loops

    private func startRelayLoop() {
        relayTask?.cancel()
        relayTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                do {
                    try await self.transport.pull()
                    try await self.processor.runHygieneIfDue()
                    _ = try await self.processor.processOnce()
                } catch is CancellationError {
                    break
                } catch {
                    self.logger.error("relay cycle failed: \(error.localizedDescription, privacy: .public)")
                }
                try? await Task.sleep(for: self.relayInterval())
            }
        }
    }

    /// Adaptive cadence: fast while relay activity is fresh, slow when idle.
    private func relayInterval() -> Duration {
        if let last = processor.lastActivityAt, now().timeIntervalSince(last) < Self.activityWindow {
            return relayActiveInterval
        }
        return relayIdleInterval
    }

    private func startHeartbeatLoop() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                do {
                    let heartbeat = HeartbeatPayload(updatedAt: self.now(), appVersion: self.appVersion)
                    let record = try CloudRecordFactory.record(for: heartbeat, modifiedAt: self.now())
                    try await self.transport.save([record])
                } catch is CancellationError {
                    break
                } catch {
                    self.logger.error("heartbeat failed: \(error.localizedDescription, privacy: .public)")
                }
                try? await Task.sleep(for: self.heartbeatInterval)
            }
        }
    }

    /// While `.unavailable`, periodically re-probes iCloud; when it returns,
    /// runs the full start() path (which re-probes, spins up the loops, and
    /// re-arms this loop should availability have flipped back). Exits on
    /// stop() (cancel + epoch bump), on leaving `.unavailable`, or after
    /// handing off to start().
    private func startReprobeLoop() {
        reprobeTask?.cancel()
        let startEpoch = epoch
        reprobeTask = Task { [weak self, interval = availabilityReprobeInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                guard self.epoch == startEpoch, case .unavailable = self.status else { return }
                guard case .available = await self.transport.availability() else { continue }
                // Re-check after the await: stop() may have landed mid-probe.
                guard self.epoch == startEpoch, case .unavailable = self.status else { return }
                await self.start()
                return
            }
        }
    }

    private static func describe(_ availability: CloudAvailability) -> String {
        switch availability {
        case .available:
            return "available" // unreachable — gated before this call
        case .noAccount:
            return "No iCloud account is signed in"
        case .restricted:
            return "iCloud access is restricted on this Mac"
        case .unavailable(let reason):
            return reason
        }
    }
}
