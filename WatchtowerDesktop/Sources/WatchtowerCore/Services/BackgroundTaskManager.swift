import Foundation

/// Manages background pipeline tasks (digests, people) after onboarding sync.
@MainActor
@Observable
package final class BackgroundTaskManager {
    package enum TaskKind: String, CaseIterable, Identifiable {
        case inbox
        case digests
        case tracks
        case people

        package var id: String { rawValue }

        package var title: String {
            switch self {
            case .inbox: "Inbox"
            case .digests: "Digests"
            case .tracks: "Tracks"
            case .people: "People Cards"
            }
        }

        package var icon: String {
            switch self {
            case .inbox: "tray"
            case .digests: "doc.text.magnifyingglass"
            case .tracks: "binoculars"
            case .people: "person.2.circle"
            }
        }

        package var cliArguments: [String] {
            switch self {
            case .inbox: ["inbox", "generate", "--progress-json"]
            case .digests: ["digest", "generate", "--progress-json", "--channels-only"]
            case .tracks: ["tracks", "generate", "--progress-json"]
            case .people: ["people", "generate", "--progress-json"]
            }
        }
    }

    package enum TaskStatus: Equatable {
        case pending
        case running
        case done
        case error(String)
    }

    package struct StepRecord: Identifiable, Equatable {
        package let id = UUID()
        package let timestamp: Date
        package let pipeline: String
        package let step: Int
        package let total: Int
        package let status: String
        package let inputTokens: Int
        package let outputTokens: Int
        package let costUsd: Double
        package let totalApiTokens: Int
        /// Duration of this step in seconds (time since previous step or task start).
        package let durationSeconds: Double
        package var messageCount: Int?
        package var periodFrom: Double?
        package var periodTo: Double?

        package init(
            timestamp: Date,
            pipeline: String,
            step: Int,
            total: Int,
            status: String,
            inputTokens: Int,
            outputTokens: Int,
            costUsd: Double,
            totalApiTokens: Int = 0,
            durationSeconds: Double,
            messageCount: Int? = nil,
            periodFrom: Double? = nil,
            periodTo: Double? = nil
        ) {
            self.timestamp = timestamp
            self.pipeline = pipeline
            self.step = step
            self.total = total
            self.status = status
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.costUsd = costUsd
            self.totalApiTokens = totalApiTokens
            self.durationSeconds = durationSeconds
            self.messageCount = messageCount
            self.periodFrom = periodFrom
            self.periodTo = periodTo
        }
    }

    package struct TaskState {
        package var status: TaskStatus = .pending
        package var progress: InsightProgressData?
        package var startedAt: Date?
        /// Estimated seconds remaining, nil if unknown.
        package var etaSeconds: Double?
        /// Log of completed steps for this task.
        package var stepHistory: [StepRecord] = []

        package init(
            status: TaskStatus = .pending,
            progress: InsightProgressData? = nil,
            startedAt: Date? = nil,
            etaSeconds: Double? = nil,
            stepHistory: [StepRecord] = []
        ) {
            self.status = status
            self.progress = progress
            self.startedAt = startedAt
            self.etaSeconds = etaSeconds
            self.stepHistory = stepHistory
        }
    }

    /// Current state of each background task.
    package var tasks: [TaskKind: TaskState] = [:]

    /// Whether any task is still running or pending.
    package var hasActiveTasks: Bool {
        tasks.values.contains { $0.status == .pending || $0.status == .running }
    }

    /// Whether all tasks are done (successfully or with error).
    package var allFinished: Bool {
        guard !tasks.isEmpty else { return true }
        return tasks.values.allSatisfy {
            if case .done = $0.status { return true }
            if case .error = $0.status { return true }
            return false
        }
    }

    /// Whether there are any visible tasks (not all done successfully).
    package var hasVisibleTasks: Bool {
        guard !tasks.isEmpty else { return false }
        // Show panel if any task is pending, running, or errored
        return tasks.values.contains {
            switch $0.status {
            case .pending, .running: return true
            case .error: return true
            case .done: return false
            }
        }
    }

    /// Total input tokens across all tasks (from accumulated pipeline counters).
    package var totalInputTokens: Int {
        tasks.values.reduce(0) { $0 + ($1.progress?.inputTokens ?? 0) }
    }

    /// Total output tokens across all tasks (from accumulated pipeline counters).
    package var totalOutputTokens: Int {
        tasks.values.reduce(0) { $0 + ($1.progress?.outputTokens ?? 0) }
    }

    /// Total API tokens (our content + CLI overhead).
    package var totalApiTokens: Int {
        tasks.values.reduce(0) { $0 + ($1.progress?.totalApiTokens ?? 0) }
    }

    private var runningProcesses: [TaskKind: Process] = [:]
    private var pipelineTask: Task<Void, Never>?

    package init() {}

    /// Stop all running pipelines (terminates current processes and cancels orchestration task).
    /// Waits for running processes to exit so file locks are released before new pipelines start.
    package func stopAll() async {
        for (_, process) in runningProcesses {
            process.terminate()
            await Task.detached {
                process.waitUntilExit()
            }.value
        }
        runningProcesses.removeAll()
        pipelineTask?.cancel()
        pipelineTask = nil
        for kind in TaskKind.allCases {
            if tasks[kind]?.status == .running || tasks[kind]?.status == .pending {
                tasks[kind]?.status = .error("Stopped")
            }
        }
    }

    /// Synchronously terminate all running pipeline processes on app quit.
    /// Must be called on the main thread.
    package nonisolated func terminateProcessesSync() {
        MainActor.assumeIsolated {
            for (_, process) in runningProcesses where process.isRunning {
                process.terminate()
            }
        }
    }

    /// Start all background pipelines: digests first, then tracks + people in parallel, then daemon.
    package func startPipelines(legacyPeople: Bool = false) {
        // Guard against duplicate calls — only start if no pipeline is active
        guard pipelineTask == nil else { return }

        // Initialize task states for active pipelines
        for kind in TaskKind.allCases {
            tasks[kind] = TaskState()
        }

        pipelineTask = Task {
            // Isolate phase failures: whatever happens below (a failed phase,
            // cooperative cancellation, or the happy path), always clear
            // pipelineTask and make sure no task is left stuck in `.pending`
            // ("Waiting..." forever in the sidebar) — both previously required
            // an app restart to recover from once digests failed.
            defer {
                resolvePendingAsSkipped()
                pipelineTask = nil
            }

            // Inbox runs independently — fire and forget, never blocks other pipelines.
            Task { @MainActor in
                await self.runTask(.inbox)
            }

            // Phase 1: channel digests (tracks + people prefer digest data, but
            // a digests failure must not block the rest of the chain).
            await runTask(.digests)
            guard !Task.isCancelled else { return }

            // Phase 2: tracks + people in parallel, regardless of Phase 1 outcome.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor in
                    await self.runTask(.tracks)
                }
                group.addTask { @MainActor in
                    await self.runTask(.people)
                }
            }
            guard !Task.isCancelled else { return }

            // Phase 3: start daemon regardless of upstream pipeline failures.
            if let path = Constants.findCLIPath() {
                await Self.runCLIFireAndForget(path: path, arguments: ["sync", "--daemon", "--detach"])
            }

            // Mark pipelines as completed for restart detection
            UserDefaults.standard.set(true, forKey: Constants.pipelinesCompletedKey)
        }
    }

    /// Move any task still stuck in `.pending` to a terminal error state.
    /// Guards against the chain exiting (cancellation, or a phase never
    /// reached) while a task never got a chance to run.
    /// Internal (not private) so it's directly unit-testable.
    package func resolvePendingAsSkipped() {
        for kind in TaskKind.allCases where tasks[kind]?.status == .pending {
            tasks[kind]?.status = .error("Skipped")
        }
    }

    /// Retry a failed task.
    package func retry(_ kind: TaskKind) {
        tasks[kind] = TaskState()
        Task {
            await runTask(kind)

            // If this was the last task to complete, start daemon
            if allFinished, let path = Constants.findCLIPath() {
                await Self.runCLIFireAndForget(path: path, arguments: ["sync", "--daemon", "--detach"])
            }
        }
    }

    /// Dismiss a completed or errored task from the sidebar.
    package func dismiss(_ kind: TaskKind) {
        tasks.removeValue(forKey: kind)
    }

    // MARK: - Private

    private func runTask(_ kind: TaskKind) async {
        guard let path = Constants.findCLIPath() else {
            tasks[kind]?.status = .error("watchtower CLI not found")
            return
        }

        tasks[kind]?.status = .running
        tasks[kind]?.startedAt = Date()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.currentDirectoryURL = Constants.processWorkingDirectory()
        process.arguments = kind.cliArguments
        process.environment = Constants.resolvedEnvironment()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            tasks[kind]?.status = .error(error.localizedDescription)
            return
        }

        runningProcesses[kind] = process
        let decoder = JSONDecoder()

        // Stream JSON lines from stdout
        let readTask = Task<InsightProgressData?, Never> {
            var lastFinished: InsightProgressData?
            do {
                for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                    if let data = line.data(using: .utf8),
                       let json = try? decoder.decode(InsightProgressData.self, from: data) {
                        await MainActor.run {
                            self.handleProgressUpdate(kind: kind, json: json)
                        }
                        if json.finished == true {
                            lastFinished = json
                        }
                    }
                }
            } catch {
                // EOF or pipe closed
            }
            return lastFinished
        }

        // Wait for process exit using blocking waitUntilExit (more reliable than
        // terminationHandler which can fire prematurely on some macOS versions).
        let exitCode: Int32 = await Task.detached {
            process.waitUntilExit()
            return process.terminationStatus
        }.value

        _ = await readTask.value

        // Read stderr off main actor to avoid blocking UI
        let stderrText: String = await Task.detached {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        }.value

        runningProcesses.removeValue(forKey: kind)

        if exitCode == 0 {
            tasks[kind]?.status = .done
            tasks[kind]?.etaSeconds = nil
        } else {
            let errorMsg = stderrText.isEmpty
                ? "Failed (exit code \(exitCode))"
                : stderrText.prefix(200).trimmingCharacters(in: .whitespacesAndNewlines)
            tasks[kind]?.status = .error(String(errorMsg))
        }
    }

    private func handleProgressUpdate(kind: TaskKind, json: InsightProgressData) {
        tasks[kind]?.progress = json
        updateETA(kind: kind, progress: json)
        // Only record completed steps: must have step_duration_seconds > 0
        // and status containing "done" (filters out rollup progress noise).
        #if DEBUG
        let statusStr = json.status ?? "nil"
        let stepDur = json.stepDurationSeconds ?? -1
        print("[BTM] \(kind.rawValue) progress: done=\(json.done)/\(json.total) status=\(statusStr) stepDur=\(stepDur)")
        #endif
        guard let stepDur = json.stepDurationSeconds, stepDur > 0,
              let status = json.status, status.contains("done") else { return }
        #if DEBUG
        print("[BTM] \(kind.rawValue) RECORDING step: \(json.status ?? "")")
        #endif
        let now = Date()
        let duration = stepDur
        let stepInput: Int
        let stepOutput: Int
        let stepCost: Double
        if let si = json.stepInputTokens, let so = json.stepOutputTokens, let sc = json.stepCostUsd {
            stepInput = si
            stepOutput = so
            stepCost = sc
        } else {
            stepInput = 0
            stepOutput = 0
            stepCost = 0
        }
        // Per-step API tokens: delta from accumulated.
        let prevAPI = tasks[kind]?.stepHistory.reduce(0) { $0 + $1.totalApiTokens } ?? 0
        let stepAPI = max(0, (json.totalApiTokens ?? 0) - prevAPI)
        let record = StepRecord(
            timestamp: now,
            pipeline: json.pipeline,
            step: json.done,
            total: json.total,
            status: json.status ?? "",
            inputTokens: stepInput,
            outputTokens: stepOutput,
            costUsd: stepCost,
            totalApiTokens: stepAPI,
            durationSeconds: duration,
            messageCount: json.messageCount,
            periodFrom: json.periodFrom,
            periodTo: json.periodTo
        )
        if var state = tasks[kind] {
            state.stepHistory.append(record)
            tasks[kind] = state
        }
    }

    private func updateETA(kind: TaskKind, progress: InsightProgressData) {
        guard let state = tasks[kind],
              let startedAt = state.startedAt,
              progress.total > 0, progress.done > 0 else {
            tasks[kind]?.etaSeconds = nil
            return
        }

        let elapsed = Date().timeIntervalSince(startedAt)
        let rate = Double(progress.done) / elapsed
        let remaining = Double(progress.total - progress.done) / rate
        tasks[kind]?.etaSeconds = remaining
    }

    nonisolated private static func runCLIFireAndForget(path: String, arguments: [String]) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.currentDirectoryURL = Constants.processWorkingDirectory()
            process.arguments = arguments
            process.environment = Constants.resolvedEnvironment()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in
                cont.resume()
            }
            do {
                try process.run()
            } catch {
                cont.resume()
            }
        }
    }
}
