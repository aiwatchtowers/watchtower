import Foundation
import MetricKit
import os

/// One MetricKit daily report, reduced to what the battery diagnostics show
/// (board #724). A plain value: MetricKit's payloads cannot be built in
/// tests, so everything past the extraction works on this. A field the
/// report did not carry is nil. MetricKit reports CPU time per day without
/// a foreground/background split; the run times carry that split.
struct MetricDaySummary: Codable, Equatable, Sendable {
    var begin: Date
    var end: Date
    var appVersion: String?
    var cpuSeconds: Double?
    var gpuSeconds: Double?
    var foregroundSeconds: Double?
    var backgroundSeconds: Double?
    var backgroundAudioSeconds: Double?
    var backgroundLocationSeconds: Double?
    var wifiUpBytes: Double?
    var wifiDownBytes: Double?
    var cellularUpBytes: Double?
    var cellularDownBytes: Double?
    /// Launches (the time-to-first-draw histogram's total) and resumes.
    var launches: Int?
    var resumes: Int?
    var peakMemoryBytes: Double?
    /// Every way the app's process ended, in the foreground and in the
    /// background (normal exits included).
    var foregroundExits: Int?
    var backgroundExits: Int?
}

/// One MetricKit diagnostic report, as counts per kind.
struct MetricDiagnosticSummary: Codable, Equatable, Sendable {
    var begin: Date
    var end: Date
    var crashes: Int
    var hangs: Int
    var cpuExceptions: Int
    var diskWriteExceptions: Int
}

/// The last `retainedDays` MetricKit daily and diagnostic reports, kept in
/// one small JSON file (the app group's on a live build). Thread-safe:
/// MetricKit delivers on a background queue while Settings reads.
final class MetricHistory: @unchecked Sendable {
    static let retainedDays = 14

    struct Contents: Codable, Equatable {
        var days: [MetricDaySummary] = []
        var diagnostics: [MetricDiagnosticSummary] = []
    }

    private let fileURL: URL?
    /// The contents and how many merges they carry.
    private let lock = OSAllocatedUnfairLock(initialState: (contents: Contents(), generation: 0))
    /// The generation last written to the file: writes run outside `lock`,
    /// one at a time, and a snapshot older than the written one is dropped.
    private let writeLock = OSAllocatedUnfairLock(initialState: 0)
    private static let logger = Logger(subsystem: "WatchtowerMobile", category: "MetricHistory")

    /// `fileURL` nil keeps the history in memory only.
    init(fileURL: URL?) {
        self.fileURL = fileURL
        let loaded = Self.load(fileURL)
        lock.withLock { $0.contents = loaded }
    }

    var contents: Contents { lock.withLock { $0.contents } }

    /// The newest daily report, nil before the first one.
    var latestDay: MetricDaySummary? { contents.days.last }

    /// Merges new reports: one per period start (a redelivered report
    /// replaces its earlier copy), oldest first, the newest
    /// `retainedDays` kept. Persists when anything was added: the merge
    /// takes a numbered snapshot under the lock and the file is written
    /// outside it (a reader never waits on the disk), and a snapshot older
    /// than the one already written is dropped, so two concurrent
    /// deliveries never leave an older merge in the file.
    func add(days: [MetricDaySummary], diagnostics: [MetricDiagnosticSummary] = []) {
        guard !days.isEmpty || !diagnostics.isEmpty else { return }
        let (snapshot, generation) = lock.withLock { state in
            state.contents.days = Self.merge(state.contents.days, days, begin: \.begin)
            state.contents.diagnostics = Self.merge(state.contents.diagnostics, diagnostics, begin: \.begin)
            state.generation += 1
            return (state.contents, state.generation)
        }
        writeLock.withLock { written in
            guard generation > written else { return }
            save(snapshot)
            written = generation
        }
    }

    private static func merge<T>(_ old: [T], _ new: [T], begin: KeyPath<T, Date>) -> [T] {
        var byBegin: [Date: T] = [:]
        for item in old + new {
            byBegin[item[keyPath: begin]] = item
        }
        let sorted = byBegin.values.sorted { $0[keyPath: begin] < $1[keyPath: begin] }
        return Array(sorted.suffix(retainedDays))
    }

    private func save(_ contents: Contents) {
        guard let fileURL else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(contents).write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("metric history save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A missing file is an empty history; a file that cannot be read or
    /// decoded is logged as such and starts an empty one (the next report
    /// overwrites it).
    private static func load(_ fileURL: URL?) -> Contents {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return Contents() }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(Contents.self, from: Data(contentsOf: fileURL))
        } catch {
            logger.error("metric history unreadable, starting empty: \(error.localizedDescription, privacy: .public)")
            return Contents()
        }
    }
}

// MARK: - MetricKit extraction

extension MetricDaySummary {
    init(_ payload: MXMetricPayload) {
        self.init(begin: payload.timeStampBegin, end: payload.timeStampEnd)
        appVersion = payload.latestApplicationVersion
        cpuSeconds = payload.cpuMetrics.map { Self.seconds($0.cumulativeCPUTime) }
        gpuSeconds = payload.gpuMetrics.map { Self.seconds($0.cumulativeGPUTime) }
        if let run = payload.applicationTimeMetrics {
            foregroundSeconds = Self.seconds(run.cumulativeForegroundTime)
            backgroundSeconds = Self.seconds(run.cumulativeBackgroundTime)
            backgroundAudioSeconds = Self.seconds(run.cumulativeBackgroundAudioTime)
            backgroundLocationSeconds = Self.seconds(run.cumulativeBackgroundLocationTime)
        }
        if let network = payload.networkTransferMetrics {
            wifiUpBytes = Self.bytes(network.cumulativeWifiUpload)
            wifiDownBytes = Self.bytes(network.cumulativeWifiDownload)
            cellularUpBytes = Self.bytes(network.cumulativeCellularUpload)
            cellularDownBytes = Self.bytes(network.cumulativeCellularDownload)
        }
        if let launch = payload.applicationLaunchMetrics {
            launches = Self.total(launch.histogrammedTimeToFirstDraw)
            resumes = Self.total(launch.histogrammedApplicationResumeTime)
        }
        peakMemoryBytes = payload.memoryMetrics.map { Self.bytes($0.peakMemoryUsage) }
        if let exits = payload.applicationExitMetrics {
            let foreground = exits.foregroundExitData
            foregroundExits = foreground.cumulativeNormalAppExitCount + foreground.cumulativeMemoryResourceLimitExitCount
                + foreground.cumulativeBadAccessExitCount + foreground.cumulativeAbnormalExitCount
                + foreground.cumulativeIllegalInstructionExitCount + foreground.cumulativeAppWatchdogExitCount
            let background = exits.backgroundExitData
            backgroundExits = background.cumulativeNormalAppExitCount + background.cumulativeMemoryResourceLimitExitCount
                + background.cumulativeCPUResourceLimitExitCount + background.cumulativeMemoryPressureExitCount
                + background.cumulativeBadAccessExitCount + background.cumulativeAbnormalExitCount
                + background.cumulativeIllegalInstructionExitCount + background.cumulativeAppWatchdogExitCount
                + background.cumulativeSuspendedWithLockedFileExitCount
                + background.cumulativeBackgroundTaskAssertionTimeoutExitCount
        }
    }

    private static func seconds(_ value: Measurement<UnitDuration>) -> Double {
        value.converted(to: .seconds).value
    }

    private static func bytes(_ value: Measurement<UnitInformationStorage>) -> Double {
        value.converted(to: .bytes).value
    }

    private static func total<Unit>(_ histogram: MXHistogram<Unit>) -> Int {
        var total = 0
        let buckets = histogram.bucketEnumerator
        while let bucket = buckets.nextObject() as? MXHistogramBucket<Unit> {
            total += bucket.bucketCount
        }
        return total
    }
}

extension MetricDiagnosticSummary {
    init(_ payload: MXDiagnosticPayload) {
        self.init(
            begin: payload.timeStampBegin,
            end: payload.timeStampEnd,
            crashes: payload.crashDiagnostics?.count ?? 0,
            hangs: payload.hangDiagnostics?.count ?? 0,
            cpuExceptions: payload.cpuExceptionDiagnostics?.count ?? 0,
            diskWriteExceptions: payload.diskWriteExceptionDiagnostics?.count ?? 0
        )
    }
}

/// Receives MetricKit's reports (about once a day, for the day before) and
/// keeps them in the history. Also takes the reports MetricKit delivered
/// before this process subscribed.
final class MetricSubscriber: NSObject, MXMetricManagerSubscriber {
    private let history: MetricHistory

    init(history: MetricHistory) {
        self.history = history
    }

    /// Subscribes and stores the past reports MetricKit still holds.
    func register(with manager: MXMetricManager = .shared) {
        manager.add(self)
        history.add(
            days: manager.pastPayloads.map(MetricDaySummary.init),
            diagnostics: manager.pastDiagnosticPayloads.map(MetricDiagnosticSummary.init)
        )
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        history.add(days: payloads.map(MetricDaySummary.init))
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        history.add(days: [], diagnostics: payloads.map(MetricDiagnosticSummary.init))
    }
}
