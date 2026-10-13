import Foundation
import WatchtowerSync
import XCTest
@testable import WatchtowerMobile

/// Settings → Battery (board #724): the MetricKit history's persistence and
/// merge, the report's rows, the view model's refresh, and the fetch
/// counting by trigger in `AppEnvironment`. Dates are seeded from now.
@MainActor
final class BatteryDiagnosticsTests: XCTestCase {
    private func makeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("battery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func day(_ daysAgo: Int, cpu: Double = 12) -> MetricDaySummary {
        let begin = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-86_400 * Double(daysAgo))
        return MetricDaySummary(
            begin: begin,
            end: begin.addingTimeInterval(86_400),
            cpuSeconds: cpu,
            foregroundSeconds: 600,
            backgroundSeconds: 7_500,
            backgroundAudioSeconds: 0,
            wifiUpBytes: 400_000,
            wifiDownBytes: 12_300_000,
            launches: 3,
            peakMemoryBytes: 85_000_000,
            backgroundExits: 40
        )
    }

    // MARK: - MetricHistory

    func testTheHistoryPersistsAcrossInstances() throws {
        let file = try makeDirectory().appendingPathComponent("battery-metrics.json")
        let diagnostic = MetricDiagnosticSummary(
            begin: day(1).begin, end: day(1).end, crashes: 0, hangs: 1, cpuExceptions: 2, diskWriteExceptions: 0
        )
        MetricHistory(fileURL: file).add(days: [day(2), day(1)], diagnostics: [diagnostic])

        let reopened = MetricHistory(fileURL: file)

        XCTAssertEqual(reopened.contents.days, [day(2), day(1)])
        XCTAssertEqual(reopened.contents.diagnostics, [diagnostic])
        XCTAssertEqual(reopened.latestDay, day(1))
    }

    func testARedeliveredReportReplacesItsCopyAndTheOrderIsByDay() {
        let history = MetricHistory(fileURL: nil)

        history.add(days: [day(1, cpu: 5), day(3)])
        history.add(days: [day(1, cpu: 9), day(2)])

        XCTAssertEqual(history.contents.days, [day(3), day(2), day(1, cpu: 9)])
    }

    func testOnlyTheNewestDaysAreKept() {
        let history = MetricHistory(fileURL: nil)

        history.add(days: (0 ..< MetricHistory.retainedDays + 5).map { day($0) })

        XCTAssertEqual(history.contents.days.count, MetricHistory.retainedDays)
        XCTAssertEqual(history.contents.days.first, day(MetricHistory.retainedDays - 1))
        XCTAssertEqual(history.latestDay, day(0))
    }

    func testAMissingFileIsAnEmptyHistory() throws {
        let history = MetricHistory(fileURL: try makeDirectory().appendingPathComponent("none.json"))

        XCTAssertEqual(history.contents, MetricHistory.Contents())
        XCTAssertNil(history.latestDay)
    }

    func testAnUndecodableFileStartsEmptyAndTheNextReportOverwritesIt() throws {
        let file = try makeDirectory().appendingPathComponent("battery-metrics.json")
        try Data("not json".utf8).write(to: file)

        let history = MetricHistory(fileURL: file)
        XCTAssertEqual(history.contents, MetricHistory.Contents())
        history.add(days: [day(1)])

        XCTAssertEqual(MetricHistory(fileURL: file).contents.days, [day(1)])
    }

    func testAddingNothingWritesNoFile() throws {
        let file = try makeDirectory().appendingPathComponent("battery-metrics.json")

        MetricHistory(fileURL: file).add(days: [], diagnostics: [])

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - Report

    func testTheReportShowsTodayAndYesterdayPerCounter() {
        let today = EnergyDayCounts(day: Date(), counts: [.silentPush: 12, .dataZonePoll: 3])
        let yesterday = EnergyDayCounts(day: Date(), counts: [.silentPush: 30])

        let report = BatteryReport(today: today, yesterday: yesterday, latest: nil)

        XCTAssertEqual(report.counterRows.count, EnergyEvent.allCases.count, "every counter has a row")
        XCTAssertEqual(Set(BatteryReport.counterLabels.map(\.0)), Set(EnergyEvent.allCases))
        XCTAssertEqual(report.counterRows.first { $0.label == "Silent pushes" }?.value, "12 · 30")
        XCTAssertEqual(report.counterRows.first { $0.label == "Data polls" }?.value, "3 · 0")
        XCTAssertEqual(report.metricRows, [], "no MetricKit report yet")
    }

    func testTheReportShowsTheLatestMetricDay() {
        let empty = EnergyDayCounts(day: Date(), counts: [:])
        var latest = day(1)
        latest.cellularUpBytes = nil

        let rows = BatteryReport(today: empty, yesterday: empty, latest: latest).metricRows
        let value = { (label: String) in rows.first { $0.label == label }?.value }

        XCTAssertEqual(value("CPU"), "12 s")
        XCTAssertEqual(value("Foreground time"), "10 min")
        XCTAssertEqual(value("Background time"), "2 h 5 min")
        XCTAssertEqual(value("Background audio"), "0 s")
        XCTAssertEqual(value("Wi-Fi"), "↓ 12.3 MB · ↑ 0.4 MB")
        XCTAssertEqual(value("Cellular"), "—", "a report without the data reads —")
        XCTAssertEqual(value("Launches"), "3")
        XCTAssertEqual(value("Background exits"), "40")
        XCTAssertEqual(value("Peak memory"), "85.0 MB")
    }

    func testTheViewModelReadsTheDiagnosticsOnRefresh() throws {
        let counter = EnergyCounter(defaults: try makeDefaults())
        let metrics = MetricHistory(fileURL: nil)
        let model = SettingsViewModel(health: ObservationHealth(), batteryDiagnostics: BatteryDiagnostics(counter: counter, metrics: metrics))
        XCTAssertNil(model.battery, "nothing is read before the first refresh")

        counter.record(.silentPush)
        metrics.add(days: [day(1)])
        model.refreshBattery()

        XCTAssertEqual(model.battery?.counterRows.first { $0.label == "Silent pushes" }?.value, "1 · 0")
        XCTAssertEqual(model.battery?.metricRows.first { $0.label == "CPU" }?.value, "12 s")

        counter.record(.silentPush)
        model.refreshBattery()
        XCTAssertEqual(model.battery?.counterRows.first { $0.label == "Silent pushes" }?.value, "2 · 0")
    }

    // MARK: - Fetch counting

    func testFetchesAreCountedByTrigger() async throws {
        // A fixed mid-day instant: the real clock could cross midnight
        // between two reads of "today".
        let noon = Calendar.autoupdatingCurrent.startOfDay(for: Date()).addingTimeInterval(12 * 3_600)
        let counter = EnergyCounter(defaults: try makeDefaults()) { noon }
        let sleeper = TickSleeper()
        let clock = MutableClock()
        let env = try AppEnvironment(
            transport: InMemoryCloudTransport(),
            replicaPath: try makeReplicaPath(),
            transportKind: .inMemoryDemo,
            defaults: try makeDefaults(),
            recordingsDirectory: try makeRecordingsDirectory(),
            now: { clock.now },
            sleep: { try await sleeper.sleep($0) },
            energy: counter
        )
        addTeardownBlock { @MainActor in env.stop() }
        try await poll { env.isLooping && sleeper.waitingCount == 1 }
        XCTAssertEqual(counter.counts(daysAgo: 0)[.fetchLaunch], 1)
        XCTAssertEqual(counter.counts(daysAgo: 0)[.fetchLoop], 0, "the safety poll waits a full interval after the launch fetch")

        sleeper.tick()
        try await poll({ counter.counts(daysAgo: 0)[.fetchLoop] == 1 && sleeper.waitingCount == 1 }, "a tick is a timed fetch")

        env.setActive(false)
        clock.advance(AppEnvironment.foregroundRefetchAfter + 1)
        env.setActive(true)
        try await poll({ counter.counts(daysAgo: 0)[.fetchForeground] == 1 }, "the return to the foreground")

        await env.refresh(.pull)
        _ = await env.handlePush(inForeground: true)
        let today = counter.counts(daysAgo: 0)
        XCTAssertEqual(today[.fetchPull], 1)
        XCTAssertEqual(today[.fetchPush], 1)
        XCTAssertEqual(today[.fetchLoop], 1, "the foreground cycle is not counted as timed")
    }
}
