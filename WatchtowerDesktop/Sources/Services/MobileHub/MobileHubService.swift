import Foundation
import os

/// The transport surface the hub needs beyond record I/O: lifecycle and
/// availability probing. CloudKitTransport satisfies it natively; tests
/// stub availability with a canned value.
protocol HubTransport: CloudSyncTransport, Sendable {
    func start() async
    func pull() async throws
    func availability() async -> CloudAvailability
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
    private let publishInterval: Duration
    private let relayIdleInterval: Duration
    private let relayActiveInterval: Duration
    private let heartbeatInterval: Duration
    private let appVersion: String
    private let now: @Sendable () -> Date
    private var relayTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private let logger = Logger(subsystem: Constants.bundleID, category: "MobileHubService")

    /// Relay activity younger than this keeps the fast poll cadence —
    /// chat stays responsive without push entitlements.
    private static let activityWindow: TimeInterval = 300

    init(
        transport: any HubTransport,
        publisher: SlicePublisher,
        processor: RelayProcessor,
        publishInterval: Duration = .seconds(60),
        relayIdleInterval: Duration = .seconds(30),
        relayActiveInterval: Duration = .seconds(3),
        heartbeatInterval: Duration = .seconds(300),
        appVersion: String = Constants.appVersion,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.publisher = publisher
        self.processor = processor
        self.publishInterval = publishInterval
        self.relayIdleInterval = relayIdleInterval
        self.relayActiveInterval = relayActiveInterval
        self.heartbeatInterval = heartbeatInterval
        self.appVersion = appVersion
        self.now = now
    }

    /// Starts the transport, gates on availability (unavailable on unsigned
    /// dev builds is expected — records queue in the store), then spins up
    /// the three loops. Safe to call again after `.unavailable` or `stop()`.
    func start() async {
        guard status != .running, status != .starting else { return }
        status = .starting
        await transport.start()
        let availability = await transport.availability()
        // stop() may have flipped the toggle off while we awaited above.
        guard status == .starting else { return }
        guard case .available = availability else {
            status = .unavailable(Self.describe(availability))
            return
        }
        publisher.start(interval: publishInterval)
        startRelayLoop()
        startHeartbeatLoop()
        status = .running
    }

    func stop() {
        publisher.stop()
        relayTask?.cancel()
        relayTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
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
                } catch {
                    self.logger.error("heartbeat failed: \(error.localizedDescription, privacy: .public)")
                }
                try? await Task.sleep(for: self.heartbeatInterval)
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
