import Foundation
import os
import WatchtowerCore
import WatchtowerSync

/// The transport surface the hub needs beyond record I/O: lifecycle,
/// availability probing and the two reset callbacks. CloudKitTransport
/// satisfies it natively; tests use a stub over InMemoryCloudTransport.
protocol HubTransport: CloudSyncTransport, Sendable {
    func start() async
    func pull() async throws
    func availability() async -> CloudAvailability
    /// Stops syncing until the next `start()` (the hub was turned off).
    func stop() async
    /// Set the account-change reset callback before `start()`.
    func setAccountResetHandler(_ handler: (@Sendable () -> Void)?) async
    /// A record CloudKit rejects even alone (`.limitExceeded`, spec §9).
    func setRecordRejectedHandler(_ handler: (@Sendable (_ recordName: String, _ zone: CloudZoneID) -> Void)?) async
}

extension CloudKitTransport: HubTransport {}

/// The process-wide part of the hub: one transport and one sidecar over the
/// files in the hub directory. Built once per app run and kept across hub
/// rebuilds, so two CKSyncEngines never drive one `transport.db`.
struct MobileHubStorage {
    let transport: any HubTransport
    let sidecar: HubSyncState

    /// `~/Library/Application Support/Watchtower/MobileHub/` (spec §3).
    static func directory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Watchtower/MobileHub", isDirectory: true)
    }

    /// The real storage: `transport.db` behind a private-scope
    /// CloudKitTransport, and `hubstate.db`.
    static func live() throws -> Self {
        let dir = directory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = try TransportStore(path: dir.appendingPathComponent("transport.db").path)
        let sidecar = try HubSyncState(path: dir.appendingPathComponent("hubstate.db").path)
        return Self(transport: CloudKitTransport(store: store), sidecar: sidecar)
    }
}

enum HubStatus: Equatable {
    case off
    case starting
    case running
    /// CloudKit can't be used (no entitlement on unsigned dev builds, no
    /// iCloud account, …): expected and harmless; no loops run.
    case unavailable(String)
}

/// Composition root of the mobile hub (spec §6.1): owns the slice publisher
/// loop and the adaptive relay loop. Opt-in: AppState builds it only while
/// `mobileSyncEnabled` is on. All intervals are injectable for tests.
@MainActor
@Observable
final class MobileHubService {
    nonisolated static let defaultRelayIdleInterval: Duration = .seconds(30)
    nonisolated static let defaultRelayActiveInterval: Duration = .seconds(3)
    /// A phone action seen this recently keeps the fast relay cadence.
    nonisolated static let activityWindow: TimeInterval = 300

    private(set) var status: HubStatus = .off

    @ObservationIgnored private let transport: any HubTransport
    @ObservationIgnored private let publisher: SlicePublisher
    @ObservationIgnored private let processor: RelayProcessor
    @ObservationIgnored private let sidecar: HubSyncState
    @ObservationIgnored private let relayIdleInterval: Duration
    @ObservationIgnored private let relayActiveInterval: Duration
    @ObservationIgnored private let availabilityReprobeInterval: Duration
    /// Whether mobile sync is enabled — injected by AppState (the defaults
    /// read lives there), so the service itself has no settings dependency.
    @ObservationIgnored private let isEnabled: () -> Bool
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var relayTask: Task<Void, Never>?
    /// Runs only while `.unavailable`: re-probes iCloud and starts the hub
    /// when it comes back.
    @ObservationIgnored private var reprobeTask: Task<Void, Never>?
    /// Bumped by stop() so a start() suspended before it detects it lost.
    @ObservationIgnored private var epoch = 0
    /// What the last stop() left running: the cancelled relay loop (its
    /// pass ends between two records) and the transport stop. start()
    /// awaits it, so two relay passes never overlap.
    @ObservationIgnored private var teardown: Task<Void, Never>?
    /// Set by dispose(): a replaced hub never starts again, even from a
    /// start() queued before it was replaced.
    @ObservationIgnored private var disposed = false
    @ObservationIgnored private let logger = Logger(subsystem: Constants.bundleID, category: "MobileHubService")

    init(
        transport: any HubTransport,
        publisher: SlicePublisher,
        processor: RelayProcessor,
        sidecar: HubSyncState,
        relayIdleInterval: Duration = MobileHubService.defaultRelayIdleInterval,
        relayActiveInterval: Duration = MobileHubService.defaultRelayActiveInterval,
        availabilityReprobeInterval: Duration = .seconds(600),
        now: @escaping @Sendable () -> Date = { Date() },
        isEnabled: @escaping () -> Bool
    ) {
        self.transport = transport
        self.publisher = publisher
        self.processor = processor
        self.sidecar = sidecar
        self.relayIdleInterval = relayIdleInterval
        self.relayActiveInterval = relayActiveInterval
        self.availabilityReprobeInterval = availabilityReprobeInterval
        self.now = now
        self.isEnabled = isEnabled
    }

    var isPublishing: Bool { publisher.isRunning }
    var relayBacklog: Int { processor.relayBacklog }

    /// Asks the publisher's fast lane for `kinds` (B and C call this on a
    /// change they know of).
    func nudge(kinds: Set<SliceKind>) {
        publisher.nudge(kinds: kinds)
    }

    /// Starts the transport, gates on availability, then spins up the loops.
    /// Safe to call again after `.unavailable` or `stop()`.
    func start() async {
        guard !disposed, isEnabled() else { return }
        guard status != .running, status != .starting else { return }
        status = .starting
        let startEpoch = epoch
        await teardown?.value
        guard status == .starting, epoch == startEpoch else { return }
        await installTransportHandlers()
        await transport.start()
        let availability = await transport.availability()
        // stop() may have run while we awaited above.
        guard status == .starting, epoch == startEpoch else { return }
        guard case .available = availability else {
            status = .unavailable(Self.describe(availability))
            startReprobeLoop()
            return
        }
        reprobeTask?.cancel()
        reprobeTask = nil
        publisher.start()
        startRelayLoop()
        status = .running
    }

    /// Registered BEFORE `transport.start()`, so an account change seen
    /// during startup still wipes the derived sync state.
    private func installTransportHandlers() async {
        let sidecar = self.sidecar
        let publisher = self.publisher
        let logger = self.logger
        await transport.setAccountResetHandler {
            do {
                try sidecar.wipeSyncState()
            } catch {
                logger.error("account reset: wipeSyncState failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        await transport.setRecordRejectedHandler { recordName, zone in
            guard zone == .data else { return }
            publisher.recordRejected(recordName)
        }
    }

    func stop() {
        publisher.stop()
        reprobeTask?.cancel()
        reprobeTask = nil
        let relay = relayTask
        relayTask = nil
        relay?.cancel()
        let previous = teardown
        let transport = self.transport
        // The transport stops first, so a hung CloudKit fetch in the
        // cancelled cycle is cancelled rather than awaited; the pass then
        // ends after the record it is applying (its echo waits in the store).
        teardown = Task {
            await previous?.value
            await transport.stop()
            await relay?.value
        }
        epoch &+= 1
        status = .off
    }

    /// Terminal stop for a hub being replaced (an `initWorkbenches` re-run).
    func dispose() {
        disposed = true
        stop()
    }

    /// Returns once the last stop() has drained (relay pass ended,
    /// transport stopped).
    func waitUntilStopped() async {
        await teardown?.value
    }

    // MARK: - Loops

    private func startRelayLoop() {
        relayTask?.cancel()
        relayTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                await self.runRelayCycle()
                try? await Task.sleep(for: self.relayInterval())
            }
        }
    }

    /// One relay cycle: pull, daily hygiene, then passes until the backlog
    /// is empty — a long Mac sleep drains in one cycle (Review focus 5).
    private func runRelayCycle() async {
        do {
            try await transport.pull()
            try await processor.runHygieneIfDue()
            var pass = try await processor.processOnce()
            while pass.remaining > 0, !Task.isCancelled {
                pass = try await processor.processOnce()
            }
        } catch is CancellationError {
            return
        } catch {
            logger.error("relay cycle failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 3 s while a phone action was seen in the last 300 s, otherwise 30 s.
    private func relayInterval() -> Duration {
        if let last = processor.lastActivityAt, now().timeIntervalSince(last) < Self.activityWindow {
            return relayActiveInterval
        }
        return relayIdleInterval
    }

    /// While `.unavailable`, periodically re-probes iCloud; when it returns,
    /// runs the full start() path. Exits on stop(), on leaving
    /// `.unavailable`, or after handing off to start().
    private func startReprobeLoop() {
        reprobeTask?.cancel()
        let startEpoch = epoch
        reprobeTask = Task { [weak self, interval = availabilityReprobeInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, !Task.isCancelled else { return }
                guard self.epoch == startEpoch, case .unavailable = self.status else { return }
                guard case .available = await self.transport.availability() else { continue }
                guard self.epoch == startEpoch, case .unavailable = self.status else { return }
                await self.start()
                return
            }
        }
    }

    private static func describe(_ availability: CloudAvailability) -> String {
        switch availability {
        case .available: return "available"
        case .noAccount: return "No iCloud account is signed in"
        case .restricted: return "iCloud access is restricted on this Mac"
        case .unavailable(let reason): return reason
        }
    }
}
