import Foundation
import Observation

/// Where the Desktop's connect listener stands.
package enum SlackConnectListenerState: Equatable, Sendable {
    /// Not started yet, or a child is starting and has not bound the port.
    case idle
    /// The child holds 127.0.0.1:18551.
    case listening
    /// Something else holds the port; stays so until `ensureRunning()`.
    case portBusy
    /// Stopped, or the child died again after its one automatic restart
    /// (plan B A10); stays so until `ensureRunning()`.
    case stopped
}

/// The Desktop's long-lived `watchtower slack connect serve` child (plan B,
/// "Port 18551 has one owner at a time"): its events, its stdin, and one
/// restart when it dies on its own. The child exits on stdin EOF, so
/// `stop()` (app quit) only closes its stdin.
@MainActor
@Observable
package final class SlackConnectListenerHost {
    package private(set) var state: SlackConnectListenerState = .idle
    /// A child process is up (`send` reaches it), whatever the state says.
    package private(set) var isChildRunning = false
    /// Every event the child writes, in order, on the main actor — set once at
    /// creation by its one consumer (`SlackConnectFlowModel`). Nothing is
    /// buffered: an event with no handler is dropped.
    @ObservationIgnored package var onEvent: ((SlackConnectEvent) -> Void)?
    /// A child ended (crash, port busy, stop), before any restart: a flow it
    /// held is gone with it.
    @ObservationIgnored package var onChildEnded: (() -> Void)?
    /// The same two for the company connect flow (`CompanyConnectFlowModel`,
    /// #1887): it gets every event after `onEvent` — `busy` answers either
    /// flow's start, so each one reads it against its own state.
    @ObservationIgnored package var onCompanyEvent: ((SlackConnectEvent) -> Void)?
    @ObservationIgnored package var onCompanyChildEnded: (() -> Void)?

    @ObservationIgnored private let streamer: any CLILineStreaming
    @ObservationIgnored private let args: [String]
    @ObservationIgnored private var child: (any CLILineSession)?
    /// Bumped per launch: an old child's late lines and exit are ignored.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var restartsLeft = 0
    @ObservationIgnored private var stopping = false
    /// `ensureRunning()` while a child that is not listening is still up (starting,
    /// port busy, stopping): relaunch when it exits, unless it binds the port first.
    @ObservationIgnored private var relaunchAfterExit = false

    package static let serveArgs = ["slack", "connect", "serve"]

    package init(streamer: any CLILineStreaming, args: [String] = SlackConnectListenerHost.serveArgs) {
        self.streamer = streamer
        self.args = args
    }

    /// Starts the child unless one runs; after `portBusy` or `stopped` this is
    /// the retry (one fresh restart allowed again).
    package func ensureRunning() {
        if child != nil {
            // A starting child may still report port_busy; a busy or stopping one
            // exits on its own (exit 3; EOF). The retry waits for that exit.
            if state != .listening || stopping { relaunchAfterExit = true }
            return
        }
        launch()
    }

    /// Writes one command to the child's stdin; false when no child runs.
    @discardableResult
    package func send(_ cmd: SlackConnectCommand) -> Bool {
        guard let child, !stopping else { return false }
        do {
            child.write(try cmd.line())
            return true
        } catch {
            print("[SlackConnect] command not encoded: \(error)")
            return false
        }
    }

    /// Closes the child's stdin: it closes the listener and exits 0.
    package func stop() {
        stopping = true
        relaunchAfterExit = false
        child?.closeInput()
        state = .stopped
    }

    private func launch() {
        stopping = false
        relaunchAfterExit = false
        restartsLeft = 1
        start()
    }

    private func start() {
        generation += 1
        let current = generation
        let session = streamer.session(args: args)
        child = session
        isChildRunning = true
        state = .idle
        Task { [weak self] in
            var failure: Error?
            do {
                for try await line in session.lines {
                    self?.handle(line, generation: current)
                }
            } catch {
                failure = error
            }
            self?.childEnded(generation: current, error: failure)
        }
    }

    private func handle(_ line: String, generation current: Int) {
        guard current == generation else { return }
        let event: SlackConnectEvent
        do {
            event = try JSONDecoder().decode(SlackConnectEvent.self, from: Data(line.utf8))
        } catch {
            // A newer child's event, or a stray line: skipped, never fatal.
            print("[SlackConnect] unreadable line from serve: \(error)")
            return
        }
        switch event {
        case .listening:
            if !stopping {
                state = .listening
                // Bound: a pending retry is moot. The restart budget refills only on
                // `ensureRunning()` (plan B A10: one automatic restart, then a retry
                // when the Slack pane opens), so a bind-then-crash loop stops.
                relaunchAfterExit = false
            }
        case .portBusy: if !stopping { state = .portBusy }
        default: break
        }
        onEvent?(event)
        onCompanyEvent?(event)
    }

    private func childEnded(generation current: Int, error: Error?) {
        guard current == generation else { return }
        child = nil
        isChildRunning = false
        onChildEnded?()
        onCompanyChildEnded?()
        if relaunchAfterExit {
            launch()
            return
        }
        if stopping || state == .portBusy { return }
        print("[SlackConnect] serve exited unexpectedly: \(error.map { "\($0)" } ?? "exit 0")")
        if restartsLeft > 0 {
            restartsLeft -= 1
            start()
        } else {
            state = .stopped
        }
    }
}
