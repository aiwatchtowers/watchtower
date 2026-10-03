import Foundation
import WatchtowerCore

/// One `watchtower code search` (spec §5): matches stream to `onMatch` as
/// the CLI finds them, then `onDone` once. `cancel()` — the next keystroke,
/// the panel closing — kills the child and its group; a cancelled run calls
/// neither callback again. Used by Open Quickly's Text scope, Usages and the
/// code questions (Tasks 6, 8, 12).
@MainActor
final class CodeSearchRun {
    enum Outcome: Equatable {
        case finished(CodeSearchDone)
        case failed(String)
    }

    private var process: CodeCLIProcess?
    private var summary: CodeSearchDone?
    private(set) var isCancelled = false

    private init() {}

    deinit {
        // Dropped without `cancel()`: the child still goes.
        process?.terminate()
    }

    static func start(
        folder: URL,
        options: CodeSearchOptions,
        executable: String? = Constants.findCLIPath(),
        environment: [String: String] = Constants.resolvedEnvironment(),
        onMatch: @escaping @MainActor (CodeSearchMatch) -> Void,
        onDone: @escaping @MainActor (Outcome) -> Void
    ) -> CodeSearchRun {
        let run = CodeSearchRun()
        do {
            guard let executable else { throw CodeCLIProcess.LaunchError.notFound }
            let process = try CodeCLIProcess.launch(
                executable: executable, arguments: options.arguments(folder: folder.path), environment: environment
            )
            run.process = process
            run.read(process, onMatch: onMatch, onDone: onDone)
        } catch {
            // Asynchronously, as a running search would: the caller has the run first.
            let message = error.localizedDescription
            Task { @MainActor [weak run] in
                guard let run, !run.isCancelled else { return }
                onDone(.failed(message))
            }
        }
        return run
    }

    func cancel() {
        isCancelled = true
        process?.terminate()
        process = nil
    }

    private func read(
        _ process: CodeCLIProcess,
        onMatch: @escaping @MainActor (CodeSearchMatch) -> Void,
        onDone: @escaping @MainActor (Outcome) -> Void
    ) {
        process.streamDecodedLines(as: CodeSearchLine.self) { [weak self] lines in
            guard let self, !isCancelled else { return }
            for line in lines {
                switch line {
                case let .match(match): onMatch(match)
                case let .done(done): summary = done
                }
            }
        } onExit: { [weak self] exit, _ in
            guard let self, !isCancelled else { return }
            self.process = nil
            if let summary {
                onDone(.finished(summary))
            } else if exit.succeeded {
                onDone(.failed("The search stopped before it finished."))
            } else {
                onDone(.failed(exit.failureMessage(command: "code search")))
            }
        }
    }
}
