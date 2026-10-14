import XCTest
@testable import WatchtowerCore

final class FeatureReadinessTests: XCTestCase {

    // MARK: - Helpers

    /// Today at `hour`:`minute` local time (`.distantPast` if the calendar
    /// can't build it, which fails every assertion loudly).
    private func today(_ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? .distantPast
    }

    private func yesterday(_ hour: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -1, to: today(hour)) ?? .distantPast
    }

    /// Slack connected, a sync finished an hour ago, nothing else.
    private func inputs(now: Date) -> ReadinessInputs {
        ReadinessInputs(
            now: now,
            connected: ConnectedSources(slack: true),
            daemonRunning: true,
            lastSyncTime: now.addingTimeInterval(-3600)
        )
    }

    private func heartbeat(now: Date) -> SyncProgress {
        let iso = ISO8601DateFormatter()
        return SyncProgress(
            active: true, phase: "Messages", detail: "3/10 channels", messagesFetched: 12,
            startedAt: iso.string(from: now.addingTimeInterval(-60)),
            updatedAt: iso.string(from: now)
        )
    }

    private func evaluate(_ feature: ReadinessFeature, _ inputs: ReadinessInputs) -> Readiness? {
        FeatureReadiness.evaluate(inputs)[feature]
    }

    private func isPreparing(_ readiness: Readiness?) -> Bool {
        if case .preparing = readiness { return true }
        return false
    }

    private func isError(_ readiness: Readiness?) -> Bool {
        if case .error = readiness { return true }
        return false
    }

    // MARK: - Precedence

    func testOffWinsOverContentAndRunning() {
        let now = today(10)
        var input = inputs(now: now)
        input.disabledFeatureIDs = ["slack-digests"]
        input.contentPresent = [.digests]
        input.latestRuns = ["digests": RunSnapshot(status: "running", startedAt: now.addingTimeInterval(-60))]
        XCTAssertEqual(evaluate(.digests, input), .off)
    }

    func testNeedsSourceWithoutSlack() {
        var input = inputs(now: today(10))
        input.connected = ConnectedSources(slack: false, mail: true)
        XCTAssertEqual(evaluate(.digests, input), .needsSource(.slack))
    }

    func testContentMeansReadyEvenWhileRunning() {
        let now = today(10)
        var input = inputs(now: now)
        input.contentPresent = [.digests]
        input.latestRuns = ["digests": RunSnapshot(status: "running", startedAt: now.addingTimeInterval(-600))]
        XCTAssertEqual(evaluate(.digests, input), .ready)
    }

    func testRunningWithLiveDaemonIsPreparing() {
        let now = today(10)
        var input = inputs(now: now)
        input.latestRuns = ["digests": RunSnapshot(status: "running", startedAt: now.addingTimeInterval(-600))]
        XCTAssertTrue(isPreparing(evaluate(.digests, input)))
    }

    func testRunningRowOlderThanTwoHoursIsNotPreparing() {
        let now = today(10)
        var input = inputs(now: now)
        input.latestRuns = ["digests": RunSnapshot(status: "running", startedAt: now.addingTimeInterval(-3 * 3600))]
        let readiness = evaluate(.digests, input)
        XCTAssertFalse(isPreparing(readiness))
        XCTAssertEqual(readiness, .scheduled(.nextCycle(minutes: 15)))
    }

    func testRunningRowWithoutDaemonIsNotPreparing() {
        let now = today(10)
        var input = inputs(now: now)
        input.daemonRunning = false
        input.latestRuns = ["digests": RunSnapshot(status: "running", startedAt: now.addingTimeInterval(-600))]
        XCTAssertFalse(isPreparing(evaluate(.digests, input)))
    }

    func testErrorOnlyWithoutContent() {
        let now = today(10)
        var input = inputs(now: now)
        input.latestRuns = ["tracks": RunSnapshot(
            status: "error", startedAt: now.addingTimeInterval(-600), errorMessage: "rate limited")]
        XCTAssertEqual(evaluate(.tracks, input), .error(message: "rate limited"))

        input.contentPresent = [.tracks]
        XCTAssertEqual(evaluate(.tracks, input), .ready)
    }

    func testWaitingForSyncBeforeFirstSync() {
        let now = today(10)
        var input = inputs(now: now)
        input.lastSyncTime = nil
        let progress = heartbeat(now: now)
        input.syncProgress = progress
        XCTAssertEqual(evaluate(.digests, input), .waitingForSync(detail: progress.summary))
    }

    func testSlackConnectedWaitsForFirstSync() {
        var input = inputs(now: today(10))
        input.connected = ConnectedSources(slack: true, calendar: true)
        input.lastSyncTime = nil
        XCTAssertEqual(evaluate(.briefing, input), .waitingForSync(detail: nil))
    }

    func testNoSlackNeverWaitsForSync() {
        // `last_sync.json` is written only by the Slack sync: without Slack
        // it never appears, so nothing may wait on it.
        var input = inputs(now: today(10))
        input.connected = ConnectedSources(calendar: true)
        input.lastSyncTime = nil
        input.syncProgress = heartbeat(now: input.now)
        let readiness = evaluate(.briefing, input)
        if case .waitingForSync = readiness { XCTFail("\(String(describing: readiness))") }
        XCTAssertEqual(readiness, .scheduled(.afterCurrentSync))
    }

    // MARK: - Briefing hour gate and freshness (dual path with Go)

    func testBriefingBeforeHourNotFreshSaysTodayAtHour() {
        var input = inputs(now: today(6))
        input.stamps.lastBriefing = yesterday(8)
        XCTAssertEqual(evaluate(.briefing, input), .scheduled(.at(hour: 8, tomorrow: false)))
    }

    func testBriefingFreshBeforeHourSaysNextCycle() {
        let input = inputs(now: today(6))
        XCTAssertEqual(evaluate(.briefing, input), .scheduled(.nextCycle(minutes: 15)))
    }

    func testBriefingStampMissingButContentPresentIsReady() {
        var input = inputs(now: today(6))
        input.contentPresent = [.briefing]
        XCTAssertEqual(evaluate(.briefing, input), .ready)
    }

    func testBriefingAfterHourWithTodaysStampSaysTomorrow() {
        var input = inputs(now: today(10))
        input.stamps.lastBriefing = today(8, 5)
        XCTAssertEqual(evaluate(.briefing, input), .scheduled(.at(hour: 8, tomorrow: true)))
    }

    func testBriefingAfterHourWithYesterdayStampSaysNextCycle() {
        var input = inputs(now: today(9))
        input.stamps.lastBriefing = yesterday(8)
        XCTAssertEqual(evaluate(.briefing, input), .scheduled(.nextCycle(minutes: 15)))
    }

    // MARK: - Throttle stamps

    func testPeopleFromStampSaysAboutADay() {
        let now = today(10)
        var input = inputs(now: now)
        input.stamps.lastPeople = now.addingTimeInterval(-3600)
        XCTAssertEqual(evaluate(.peopleCards, input), .scheduled(.inAboutADay))
    }

    func testIdeasFromStampRoundsUpHours() {
        let now = today(10)
        var input = inputs(now: now)
        input.stamps.lastIdeas = now.addingTimeInterval(-1.5 * 3600)
        XCTAssertEqual(evaluate(.ideas, input), .scheduled(.inHours(5)))
    }

    func testCalendarHasNoPreparingOrError() {
        let now = today(10)
        var input = inputs(now: now)
        input.connected.calendar = true
        for status in ["running", "error"] {
            input.latestRuns = ["calendar": RunSnapshot(
                status: status, startedAt: now.addingTimeInterval(-60), errorMessage: "boom")]
            let readiness = evaluate(.calendar, input)
            XCTAssertFalse(isPreparing(readiness), status)
            XCTAssertFalse(isError(readiness), status)
        }
    }

    // MARK: - Wording

    func testPhraseNeverShowsMinutesOtherThanPollInterval() throws {
        let poll = 15
        let etas: [Eta] = [
            .afterCurrentSync, .nextCycle(minutes: poll), .at(hour: 8, tomorrow: false),
            .at(hour: 8, tomorrow: true), .inAboutADay, .inHours(6)
        ]
        let minutes = try NSRegularExpression(pattern: #"~?\d+ min"#)
        for eta in etas {
            let text = FeatureReadiness.phrase(eta)
            XCTAssertFalse(text.isEmpty, "\(eta)")
            let range = NSRange(text.startIndex..., in: text)
            for match in minutes.matches(in: text, range: range) {
                XCTAssertEqual((text as NSString).substring(with: match.range), "~\(poll) min", "\(eta): \(text)")
            }
        }
        XCTAssertEqual(FeatureReadiness.phrase(.nextCycle(minutes: poll)), "within ~15 min")
        XCTAssertEqual(FeatureReadiness.phrase(.at(hour: 8, tomorrow: false)), "today at 08:00")
        XCTAssertEqual(FeatureReadiness.phrase(.at(hour: 8, tomorrow: true)), "tomorrow at 08:00")
        XCTAssertEqual(FeatureReadiness.phrase(.inHours(6)), "in about 6 h")
        XCTAssertEqual(FeatureReadiness.line(.scheduled(.at(hour: 8, tomorrow: false))), "Today at 08:00")
    }

    func testParsePollInterval() {
        XCTAssertEqual(FeatureReadiness.parsePollInterval("15m"), 15)
        XCTAssertEqual(FeatureReadiness.parsePollInterval("1h"), 60)
        XCTAssertEqual(FeatureReadiness.parsePollInterval("900s"), 15)
        XCTAssertEqual(FeatureReadiness.parsePollInterval(nil), 15)
        XCTAssertEqual(FeatureReadiness.parsePollInterval("garbage"), 15)
    }

    // MARK: - Degenerate input

    /// Nothing connected: every feature is off or needs a source, except the
    /// knowledge index (it needs none and, with no Slack, waits on no sync),
    /// which is scheduled for the next cycle.
    func testEmptyInputsAllOffOrWaiting() {
        let result = FeatureReadiness.evaluate(ReadinessInputs(now: today(10)))
        XCTAssertEqual(Set(result.keys), Set(ReadinessFeature.allCases))
        XCTAssertEqual(result.count, 13)
        for (feature, readiness) in result {
            switch readiness {
            case .off, .needsSource, .waitingForSync: break
            case .scheduled(.nextCycle(minutes: 15)) where feature.source == .none: break
            default: XCTFail("\(feature): \(readiness)")
            }
        }
    }
}
