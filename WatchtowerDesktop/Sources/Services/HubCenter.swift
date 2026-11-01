import Foundation
import Observation
import os
import WatchtowerCore

/// The Desktop's side of the Go hub (go hub plan 3 Task 14, spec §8 p. 4a):
/// over the control socket (`HubControlClient`) a `desktop_heartbeat` every
/// 30 s, the view inputs only the Desktop knows (`desktop_view`: the PROJ-17
/// Undo batch's sessions and the background counts shown over, #411) and the
/// `desktop_watch` stream.
///
/// The heartbeat alone decides whether the hub answers. Each answered beat
/// sends the view when the hub has not taken the current one: the whole
/// view after `start()` and on `view_needed` (a hub restart, or a view
/// dropped while the heartbeat was stale), else only a view changed since
/// (one made while no hub answered included). Changes otherwise go coalesced
/// over 250 ms. While no hub answers nothing is sent (nothing to tell) and
/// `status` is `watchtower hub status --json`, read once per streak.
///
/// The watch reconnects with a backoff of 1 s doubling to 30 s (a snapshot
/// resets it); its snapshot and `status` events set `status.state`/`reason`,
/// and while the hub answers the other fields (`hub_id`, `transport`,
/// `host`, `mode`, `recordings`, `adoption`) come from `hub status --json`,
/// read when it starts answering and after each watch status (coalesced:
/// one read in flight, one more queued). One log line per failure streak.
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

    /// A watch connection got its snapshot: the hub serves its socket, so
    /// what it queued while no watch listened is read again (the phone
    /// recording queue's rescan).
    @ObservationIgnored var onWatchConnected: (() -> Void)?
    /// The hub queued a phone recording (`recording_queued`, the upload id only).
    @ObservationIgnored var onRecordingQueued: ((String) -> Void)?

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
    /// A send is in flight; `resend` asks for one more pass after it,
    /// `resendForce` for one that goes even unchanged (a `view_needed`).
    @ObservationIgnored private var sending = false
    @ObservationIgnored private var resend = false
    @ObservationIgnored private var resendForce = false
    /// Whether the last heartbeat got an answer.
    private enum Reach { case untried, answering, silent }
    @ObservationIgnored private var reach = Reach.untried
    /// The watch's latest state and reason while the hub answers.
    @ObservationIgnored private var watched: (state: String, reason: String?)?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var refreshAgain = false
    /// One log line per failure streak.
    @ObservationIgnored private var beatRefusedLogged = false
    @ObservationIgnored private var viewRefusedLogged = false
    @ObservationIgnored private var viewCappedLogged = false
    @ObservationIgnored private var statusReadLogged = false
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

    /// The app's center on the hub's socket (`WATCHTOWER_HUB_DIR` or the
    /// live hub's dir); nil under XCTest, so no test reaches this Mac's hub.
    static func live(cli: (any CLIRunnerProtocol)?) -> HubCenter? {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              NSClassFromString("XCTestCase") == nil else { return nil }
        return HubCenter(client: HubControlClient(socketPath: HubControlClient.defaultSocketPath()), cli: cli)
    }

    var isRunning: Bool { heartbeatTask != nil }

    func start() {
        guard heartbeatTask == nil else { return }
        epoch += 1
        (sent, reach, watched) = (nil, .untried, nil)
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
        (sending, resend, resendForce, refreshing, refreshAgain) = (false, false, false, false, false)
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
            await self.sendView(force: false)
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

    // MARK: - Heartbeat

    private func beat() async {
        let run = epoch
        let answer: HubControlAnswer
        do {
            answer = try await client.send(.heartbeat)
        } catch {
            guard run == epoch else { return }
            await noAnswer(error)
            return
        }
        guard run == epoch else { return }
        let wasAnswering = reach == .answering
        reach = .answering
        if !wasAnswering { refreshStatus() }
        guard answer.ok else {
            if !beatRefusedLogged {
                beatRefusedLogged = true
                Self.logger.error("hub: desktop heartbeat refused (\(answer.error ?? "", privacy: .public))")
            }
            return
        }
        beatRefusedLogged = false
        await sendView(force: sent == nil || answer.viewNeeded)
    }

    /// The first beat of a streak without an answer: logged (unless simply
    /// no hub), and the status read from the CLI.
    private func noAnswer(_ error: any Error) async {
        guard reach != .silent else { return }
        reach = .silent
        watched = nil
        if error as? HubControlError != .noHub {
            Self.logger.notice("hub: control socket unavailable (\(String(describing: error), privacy: .public))")
        }
        let run = epoch
        let next = await cliStatus() ?? Self.notRunning
        guard run == epoch, reach == .silent else { return }
        status = next
    }

    // MARK: - Watch

    /// One watch connection to its end; whether it got the snapshot. Its end
    /// only reconnects: whether the hub answers is the heartbeat's.
    private func watchOnce() async -> Bool {
        let run = epoch
        var connected = false
        do {
            for try await event in client.watch() {
                guard run == epoch else { return connected }
                switch event {
                case let .snapshot(next):
                    connected = true
                    watchedStatus(next)
                    onWatchConnected?()
                case let .status(next):
                    watchedStatus(next)
                case let .recordingQueued(uploadID):
                    if !uploadID.isEmpty { onRecordingQueued?(uploadID) }
                case .pair, .switched, .unknown:
                    break
                }
            }
        } catch {
            // A failed connect or a dropped stream: the backoff, nothing else.
        }
        return connected
    }

    private func watchedStatus(_ next: Status) {
        watched = (next.state, next.reason)
        status = status?.with(state: next.state, reason: next.reason) ?? next
        refreshStatus()
    }

    /// The full status from the CLI while the hub answers, the watch's
    /// state and reason kept; one read in flight, one more queued.
    private func refreshStatus() {
        guard cli != nil else { return }
        guard !refreshing else {
            refreshAgain = true
            return
        }
        refreshing = true
        let run = epoch
        Task { [weak self] in
            while let self, run == self.epoch {
                self.refreshAgain = false
                let next = await self.cliStatus()
                guard run == self.epoch else { return }
                if let next, self.reach == .answering {
                    let watched = self.watched
                    self.status = next.with(state: watched?.state ?? next.state, reason: watched.map(\.reason) ?? next.reason)
                }
                guard self.refreshAgain else {
                    self.refreshing = false
                    return
                }
            }
        }
    }

    // MARK: - View

    /// Sends the view when the hub has not taken it (`force`: even
    /// unchanged). Never while no hub answers; a pass asked for during a
    /// send runs after it, its force kept.
    private func sendView(force: Bool) async {
        guard reach == .answering else { return }
        guard !sending else {
            resend = true
            resendForce = resendForce || force
            return
        }
        sending = true
        defer { sending = false }
        let run = epoch
        var force = force
        repeat {
            resend = false
            let (request, capped) = viewRequest()
            if capped, !viewCappedLogged {
                viewCappedLogged = true
                Self.logger.error("hub: desktop view over \(HubControlRequest.maxViewIDs) ids, the newest kept")
            } else if !capped {
                viewCappedLogged = false
            }
            if force || request != sent {
                do {
                    let answer = try await client.send(request)
                    guard run == epoch else { return }
                    viewAnswered(answer, request)
                } catch {
                    return // the next answered heartbeat sends it again
                }
            }
            force = resendForce
            resendForce = false
        } while resend || force
    }

    private func viewAnswered(_ answer: HubControlAnswer, _ request: HubControlRequest) {
        guard answer.ok else {
            if !viewRefusedLogged {
                viewRefusedLogged = true
                Self.logger.error("hub: desktop view refused (\(answer.error ?? "", privacy: .public))")
            }
            return
        }
        viewRefusedLogged = false
        sent = request
    }

    /// The view as the wire carries it.
    private func viewRequest() -> (HubControlRequest, capped: Bool) {
        HubControlRequest.view(hidden: hidden, displayOver: displayOver.map { HubShownOver(id: $0.key, $0.value) })
    }

    private func cliStatus() async -> Status? {
        guard let cli else { return nil }
        do {
            let data = try await cli.run(args: Self.statusArgs)
            let next = try JSONDecoder().decode(Status.self, from: data)
            statusReadLogged = false
            return next
        } catch {
            if !statusReadLogged {
                statusReadLogged = true
                Self.logger.error("hub: status read failed (\(error.localizedDescription, privacy: .public))")
            }
            return nil
        }
    }
}
