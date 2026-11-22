import Foundation
import WatchtowerCore

/// The `watchtower company …` / `slack app …` verbs, answered by args
/// prefix: a queued reply per prefix (FIFO), a held run the test releases,
/// else a default (an empty draft, no apps, saves that succeed). Every call
/// is recorded with its stdin.
package final class CompanyScriptedCLI: CLILineStreaming, @unchecked Sendable {
    package init() {}

    package struct Call {
        package let args: [String]
        package let stdin: Data?
        package var input: String { stdin.flatMap { String(data: $0, encoding: .utf8) } ?? "" }
    }

    private let lock = NSLock()
    private var scripts: [(prefix: [String], lines: [String], exit: Int32)] = []
    private var holds: [(prefix: [String], first: [String])] = []
    private var held: [(prefix: [String], sink: AsyncThrowingStream<String, Error>.Continuation)] = []
    private var recorded: [Call] = []
    private var cancelledRuns: [[String]] = []
    private var exitHolds: [[String]] = []
    private var exitGates: [(prefix: [String], gate: ExitGate)] = []
    package let signal = StateSignal()
    package var setups = #"{"setups":[]}"#

    package func on(_ prefix: [String], _ lines: [String], exit: Int32 = 0) {
        lock.withLock { scripts.append((prefix, lines, exit)) }
    }

    /// The next call with this prefix prints `first` (a run's progress
    /// lines), then waits until `release`.
    package func hold(_ prefix: [String], first: [String] = []) {
        lock.withLock { holds.append((prefix, first)) }
    }

    package func release(_ prefix: [String], _ lines: [String]) {
        let sink = lock.withLock { () -> AsyncThrowingStream<String, Error>.Continuation? in
            guard let index = held.firstIndex(where: { $0.prefix == prefix }) else { return nil }
            return held.remove(at: index).sink
        }
        lines.forEach { sink?.yield($0) }
        sink?.finish()
    }

    package var calls: [Call] { lock.withLock { recorded } }

    /// The runs whose consumer went away before the child ended (the real
    /// `CLILineStream` kills the process group then).
    package func cancelled(_ prefix: [String]) -> Int {
        lock.withLock { cancelledRuns.filter { Array($0.prefix(prefix.count)) == prefix }.count }
    }

    package func calls(_ prefix: [String]) -> [Call] {
        calls.filter { Array($0.args.prefix(prefix.count)) == prefix }
    }

    package func waitFor(_ prefix: [String], count: Int = 1) async {
        await signal.until { [self] in calls(prefix).count >= count }
    }

    package func lines(args: [String], stdin: Data?) -> AsyncThrowingStream<String, Error> {
        let (stream, sink) = AsyncThrowingStream.makeStream(of: String.self)
        sink.onTermination = { [weak self] termination in
            guard case .cancelled = termination, let self else { return }
            lock.withLock { self.cancelledRuns.append(args) }
            signal.changed()
        }
        let match = { (prefix: [String]) in Array(args.prefix(prefix.count)) == prefix }
        var first: [String] = []
        let action = lock.withLock { () -> (lines: [String], exit: Int32)? in
            recorded.append(Call(args: args, stdin: stdin))
            if let index = holds.firstIndex(where: { match($0.prefix) }) {
                let hold = holds.remove(at: index)
                first = hold.first
                held.append((hold.prefix, sink))
                return nil
            }
            if let index = scripts.firstIndex(where: { match($0.prefix) }) {
                let script = scripts.remove(at: index)
                return (script.lines, script.exit)
            }
            return (defaultLines(args), 0)
        }
        first.forEach { sink.yield($0) }
        signal.changed()
        if let action {
            action.lines.forEach { sink.yield($0) }
            if action.exit == 0 {
                sink.finish()
            } else {
                sink.finish(throwing: CLIRunnerError.nonZeroExit(code: action.exit, stderr: ""))
            }
        }
        return stream
    }

    private func defaultLines(_ args: [String]) -> [String] {
        switch Array(args.prefix(3)) {
        case ["company", "draft", "show"]: [#"{"state":"none","draft":null,"bad_file":"","checked_vendors":[]}"#]
        case ["company", "discover", "--json"]: [#"{"candidates":[]}"#]
        case ["slack", "app", "status"]: [setups]
        default: []
        }
    }

    /// The scripted `lines` run as a session that has already ended.
    package func oneShot(args: [String], stdin: Data?) -> any CLILineSession {
        let gate = lock.withLock { () -> ExitGate? in
            guard let index = exitHolds.firstIndex(where: { Array(args.prefix($0.count)) == $0 }) else { return nil }
            let gate = ExitGate { [signal] in signal.changed() }
            exitGates.append((exitHolds.remove(at: index), gate))
            return gate
        }
        return EndedLinesSession(lines: lines(args: args, stdin: stdin), exit: gate)
    }

    /// The next one-shot run with this prefix "exits" only at `releaseExit`
    /// (its lines end as usual): a child killed but not yet reaped.
    package func holdExit(_ prefix: [String]) {
        lock.withLock { exitHolds.append(prefix) }
    }

    /// Returns once the held run waits for its exit (its lines ended).
    package func exitAwaited(_ prefix: [String]) async {
        await signal.until { [self] in
            lock.withLock { exitGates.contains { $0.prefix == prefix && $0.gate.isAwaited } }
        }
    }

    package func releaseExit(_ prefix: [String]) {
        let gate = lock.withLock { () -> ExitGate? in
            guard let index = exitGates.firstIndex(where: { $0.prefix == prefix }) else { return nil }
            return exitGates.remove(at: index).gate
        }
        gate?.open()
    }

    /// The wizard runs no long-lived child; a stray one is recorded and never answers.
    package func session(args: [String]) -> any CLILineSession {
        lock.withLock { recorded.append(Call(args: args, stdin: nil)) }
        return FakeCLILineStream().session(args: args)
    }
}

/// A scripted run seen as a session: its lines; it has exited unless its
/// exit is held (`holdExit`).
private final class EndedLinesSession: CLILineSession, @unchecked Sendable {
    let lines: AsyncThrowingStream<String, Error>
    private let exit: ExitGate?

    init(lines: AsyncThrowingStream<String, Error>, exit: ExitGate?) {
        self.lines = lines
        self.exit = exit
    }

    func write(_ data: Data) {}
    func closeInput() {}
    func terminate() {}
    func waitForExit() async { await exit?.wait() }
}

/// A held child's exit: `wait` returns once `open` was called.
private final class ExitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let onWait: @Sendable () -> Void

    init(onWait: @escaping @Sendable () -> Void) {
        self.onWait = onWait
    }

    var isAwaited: Bool { lock.withLock { !waiters.isEmpty } }

    func open() {
        let woken = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            opened = true
            defer { waiters = [] }
            return waiters
        }
        woken.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let ready = lock.withLock { () -> Bool in
                if !opened { waiters.append(waiter) }
                return opened
            }
            if ready { waiter.resume() } else { onWait() }
        }
    }
}
