import Foundation
import os
import WatchtowerCore

/// One streamed `watchtower` child: its stdout as raw chunks (finishing at
/// EOF), its exit once reaped, and a stop (SIGTERM to its process group,
/// idempotent).
struct CLIStreamedRun: Sendable {
    let output: AsyncStream<Data>
    /// The exit status (128 + the signal for a killed child), once reaped.
    let exit: @Sendable () async -> Int32
    let stop: @Sendable () -> Void
}

/// Starts a `watchtower` command whose stdout is read as it arrives. The
/// production conformer is `ProcessCLIRunner` over `CodeCLIProcess` (own
/// process group, always reaped); tests script it.
protocol CLIStreamingRunner {
    func stream(args: [String]) async throws -> CLIStreamedRun
}

extension ProcessCLIRunner: CLIStreamingRunner {
    func stream(args: [String]) async throws -> CLIStreamedRun {
        let process = try CodeCLIProcess.launch(
            executable: binaryPath, arguments: args, environment: await Constants.resolvedEnvironmentAsync()
        )
        return CLIStreamedRun(
            output: process.output,
            exit: { await process.exitStatus.status },
            stop: { process.terminateGroup() }
        )
    }
}

/// A streamed overview that ended without its envelope: killed, crashed, or
/// cut mid-line (tech spec §3.5, Review Focus 5).
struct ReviewStreamEnded: Error, Equatable {
    let status: Int32
    let partialLine: Bool
}

/// Fires the stop of a run that may not have started yet: a stop asked for
/// first is applied as soon as the run is there.
private final class StreamStopBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stopRun: (@Sendable () -> Void)?
    private var stopped = false

    func set(_ stop: @escaping @Sendable () -> Void) {
        let now = lock.withLock { () -> Bool in
            if stopped { return true }
            stopRun = stop
            return false
        }
        if now { stop() }
    }

    func fire() {
        let stop = lock.withLock { () -> (@Sendable () -> Void)? in
            stopped = true
            defer { stopRun = nil }
            return stopRun
        }
        stop?()
    }
}

extension WorkbenchCLI {
    /// The Desktop waits this long for `review map`; the map's own budget is 20 s (tech spec §5).
    static let reviewMapTimeout: TimeInterval = 60

    /// The round's instant map (no AI, writes nothing): chapters in reading order, danger, lanes.
    func reviewMap(projectID: Int64, roundID: Int64) async throws -> ReviewEnvelope {
        let args = ["workbench", "review", "map", "--workbench", String(projectID), "--round", String(roundID), "--json"]
        let data = try await runner.run(args: args, timeout: Self.reviewMapTimeout)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ReviewEnvelope.self, from: data)
    }

    /// The overview's streamed run as Desktop (`--caller desktop`): one event
    /// per complete line, the envelope last. `chapters` redoes those chapters
    /// and then the summary, `summaryOnly` the summary, `continue` the
    /// chapters not described yet; none of them = the full run. Ending the
    /// iteration (or cancelling its task) terminates the child's process
    /// group; a stream that ends without the envelope throws `ReviewStreamEnded`.
    /// No total time limit here: the caller watches for silence.
    func reviewOverviewStream(
        projectID: Int64,
        roundID: Int64,
        chapters: [String] = [],
        summaryOnly: Bool = false,
        continue: Bool = false
    ) -> AsyncThrowingStream<ReviewStreamEvent, Error> {
        var args = ["workbench", "review", "overview", "--workbench", String(projectID), "--round", String(roundID),
                    "--json", "--stream", "--caller", "desktop"]
        // `--chapter=K`: a key is never read as a flag.
        args += chapters.map { "--chapter=\($0)" }
        if summaryOnly { args.append("--summary") }
        if `continue` { args.append("--continue") }
        let streamer = runner as? any CLIStreamingRunner
        let box = StreamStopBox()
        return AsyncThrowingStream { continuation in
            let producer = Task {
                guard let streamer else {
                    continuation.finish(throwing: CLIRunnerError.launchFailed(underlying: CocoaError(.featureUnsupported)))
                    return
                }
                do {
                    let run = try await streamer.stream(args: args)
                    box.set(run.stop)
                    try await Self.pump(run, into: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Only a consumer that stopped reading stops the child; a stream that
            // finished has already reaped it.
            continuation.onTermination = { termination in
                guard case .cancelled = termination else { return }
                box.fire()
                producer.cancel()
            }
        }
    }

    private static let streamLog = Logger(subsystem: Constants.bundleID, category: "review")

    /// Decodes the run's stdout into events until EOF, then reaps it. Logs
    /// counts only (FILES-01): unreadable lines by reason and a cut last line.
    private static func pump(
        _ run: CLIStreamedRun, into continuation: AsyncThrowingStream<ReviewStreamEvent, Error>.Continuation
    ) async throws {
        var decoder = ReviewOverviewStreamDecoder()
        var sawFinal = false
        for await chunk in run.output {
            for event in decoder.feed(chunk) {
                if case .final = event { sawFinal = true }
                continuation.yield(event)
            }
        }
        let status = await run.exit()
        let partial = decoder.hasPartialLine
        if !decoder.unreadable.isEmpty || partial {
            let counts = decoder.unreadable.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            streamLog.notice(
                "review overview stream: unreadable lines \(counts, privacy: .public), cut last line \(partial, privacy: .public)"
            )
        }
        guard sawFinal else { throw ReviewStreamEnded(status: status, partialLine: partial) }
        continuation.finish()
    }
}
