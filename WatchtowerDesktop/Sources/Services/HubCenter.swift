import Foundation
import Observation
import os
import WatchtowerCore

/// The Desktop's side of the Go hub (go hub plan 3 Task 14, spec §8 p. 4a):
/// over the control socket (`HubControlClient`) a `desktop_heartbeat` every
/// 30 s, the view inputs only the Desktop knows (`desktop_view`: the PROJ-17
/// Undo batch's sessions and the background counts shown over, #411) and the
/// `desktop_watch` stream whose snapshot and `status` events are `status`.
///
/// The whole view goes at the first heartbeat answered after `start()` and
/// again whenever an answer says `view_needed` (a hub restart, or a view
/// dropped while the heartbeat was stale); otherwise a change goes, coalesced
/// over 250 ms. With no hub serving the socket nothing is sent (nothing to
/// tell): `status` comes from `watchtower hub status --json`, read once per
/// streak of a hub not answering, and the watch reconnects with a backoff of
/// 1 s doubling to 30 s. One log line per streak, never one per try.
@MainActor
@Observable
final class HubCenter {
    /// The Core status; qualified while the Swift hub's own `HubStatus` lives
    /// (removed with it in Task 24).
    typealias Status = WatchtowerCore.HubStatus

    nonisolated static let heartbeatInterval: Duration = .seconds(30)
    nonisolated static let viewCoalesce: Duration = .milliseconds(250)
    nonisolated static let firstBackoff: Duration = .seconds(1)
    nonisolated static let maxBackoff: Duration = .seconds(30)
    nonisolated static let statusArgs = ["hub", "status", "--json"]
    /// The status when no hub answers and the CLI cannot say more.
    nonisolated static let notRunning = Status(state: "off")

    private(set) var status: Status?

    @ObservationIgnored private let client: any HubControlClienting
    @ObservationIgnored private let cli: (any CLIRunnerProtocol)?
    @ObservationIgnored private let sleep: @Sendable (Duration) async -> Void
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var viewTask: Task<Void, Never>?
    @ObservationIgnored private var hidden: Set<Int64> = []
    @ObservationIgnored private var displayOver: [Int64: ShownOverCount] = [:]
    /// The view the hub last took (nil: none since `start()`).
    @ObservationIgnored private var sent: HubControlRequest?
    /// A send is in flight; `resend` asks for one more after it.
    @ObservationIgnored private var sending = false
    @ObservationIgnored private var resend = false
    /// The hub did not answer since this streak began (CLI status read, logged once).
    @ObservationIgnored private var unreachable = false
    /// Bumped by `start()`/`stop()`: late results of an earlier run apply nothing.
    @ObservationIgnored private var epoch = 0

    private static let logger = Logger(subsystem: "com.watchtower.desktop", category: "HubCenter")

    init(
        client: any HubControlClienting,
        cli: (any CLIRunnerProtocol)?,
        heartbeatInterval: Duration = HubCenter.heartbeatInterval,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.client = client
        self.cli = cli
        interval = heartbeatInterval
        self.sleep = sleep
    }

    /// The app's center on the live hub's socket; nil under XCTest, so no
    /// test reaches this Mac's hub.
    static func live(cli: (any CLIRunnerProtocol)?) -> HubCenter? {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              NSClassFromString("XCTestCase") == nil else { return nil }
        return HubCenter(client: HubControlClient(socketPath: HubControlClient.defaultSocketPath), cli: cli)
    }

    var isRunning: Bool { heartbeatTask != nil }

    func start() {
        guard heartbeatTask == nil else { return }
        epoch += 1
        sent = nil
        unreachable = false
        heartbeatTask = Task { [weak self, sleep, interval] in
            while !Task.isCancelled {
                await self?.beat()
                await sleep(interval)
            }
        }
        watchTask = Task { [weak self, sleep] in
            var backoff = Self.firstBackoff
            while !Task.isCancelled {
                guard let connected = await self?.watchOnce() else { return }
                if connected { backoff = Self.firstBackoff }
                guard !Task.isCancelled else { return }
                await sleep(backoff)
                backoff = min(backoff * 2, Self.maxBackoff)
            }
        }
    }

    func stop() {
        epoch += 1
        heartbeatTask?.cancel()
        watchTask?.cancel()
        viewTask?.cancel()
        (heartbeatTask, watchTask, viewTask) = (nil, nil, nil)
    }

    /// The Desktop's view now: the Undo batch's sessions and the counts
    /// shown over. A change goes to the hub within `viewCoalesce`.
    func publishView(hidden: Set<Int64>, displayOver: [Int64: ShownOverCount]) {
        guard hidden != self.hidden || displayOver != self.displayOver else { return }
        self.hidden = hidden
        self.displayOver = displayOver
        guard isRunning, viewTask == nil else { return }
        viewTask = Task { [weak self, sleep] in
            await sleep(Self.viewCoalesce)
            guard !Task.isCancelled, let self else { return }
            self.viewTask = nil
            await self.sendView(always: false)
        }
    }

    /// Follows the workbench view model's Undo batch and the state center's
    /// shown-over counts, the current view published now.
    func follow(workbenches: WorkbenchesViewModel?, agentStates: SessionAgentStateCenter?) {
        let view = { [weak self, weak workbenches, weak agentStates] in
            self?.publishView(
                hidden: workbenches?.pendingDeletes.ids ?? [], displayOver: agentStates?.displayOver ?? [:]
            )
        }
        workbenches?.onHiddenSessionsChanged = { _ in view() }
        agentStates?.onDisplayOverChange = { _ in view() }
        view()
    }

    // MARK: - Private

    /// The view as the wire carries it.
    private var viewRequest: HubControlRequest {
        .view(
            hidden: hidden,
            displayOver: displayOver.map { HubShownOver(id: $0.key, run: $0.value.run, reportedAt: $0.value.reportedAt) }
        )
    }

    private func beat() async {
        let run = epoch
        do {
            let answer = try await client.send(.heartbeat)
            guard run == epoch else { return }
            reachable()
            guard answer.ok else {
                Self.logger.error("hub: desktop heartbeat refused (\(answer.error ?? "", privacy: .public))")
                return
            }
            if sent == nil || answer.viewNeeded { await sendView(always: true) }
        } catch {
            guard run == epoch else { return }
            await hubUnreachable(error)
        }
    }

    /// One watch connection to its end; whether it got the snapshot.
    private func watchOnce() async -> Bool {
        let run = epoch
        var connected = false
        do {
            for try await event in client.watch() {
                guard run == epoch else { return connected }
                switch event {
                case let .snapshot(next):
                    connected = true
                    reachable()
                    status = next
                case let .status(next):
                    status = next
                case .recordingQueued, .pair, .switched, .unknown:
                    break
                }
            }
        } catch {
            guard run == epoch else { return connected }
            if !connected {
                await hubUnreachable(error)
                return false
            }
        }
        // A stream that ended: the hub stopped or went away.
        guard run == epoch else { return connected }
        await hubUnreachable(HubControlError.closed)
        return connected
    }

    /// Sends the view: `always` at the start and on `view_needed`, else only
    /// a view the hub has not taken yet. Never while no hub answers.
    private func sendView(always: Bool) async {
        guard !unreachable else { return }
        guard !sending else {
            resend = true
            return
        }
        sending = true
        defer { sending = false }
        let run = epoch
        var force = always
        repeat {
            resend = false
            let request = viewRequest
            guard force || request != sent else { return }
            force = false
            do {
                let answer = try await client.send(request)
                guard run == epoch else { return }
                if answer.ok {
                    sent = request
                } else {
                    Self.logger.error("hub: desktop view refused (\(answer.error ?? "", privacy: .public))")
                }
            } catch {
                guard run == epoch else { return }
                await hubUnreachable(error)
                return
            }
        } while resend
    }

    private func reachable() {
        unreachable = false
    }

    /// The first failure of a streak: logged, and the status read from the CLI.
    private func hubUnreachable(_ error: any Error) async {
        guard !unreachable else { return }
        unreachable = true
        if error as? HubControlError != .noHub {
            Self.logger.notice("hub: control socket unavailable (\(String(describing: error), privacy: .public))")
        }
        let run = epoch
        let next = await cliStatus()
        guard run == epoch, unreachable else { return }
        status = next
    }

    private func cliStatus() async -> Status {
        guard let cli else { return Self.notRunning }
        do {
            let data = try await cli.run(args: Self.statusArgs)
            return try JSONDecoder().decode(Status.self, from: data)
        } catch {
            Self.logger.error("hub: status read failed (\(error.localizedDescription, privacy: .public))")
            return Self.notRunning
        }
    }
}
