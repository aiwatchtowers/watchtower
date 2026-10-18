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

    /// #575: the daemon runs tracks and people cards only while Slack
    /// Digests is on (dual path with `phaseTracksAndRollups`,
    /// `phaseCustomTrackScan` and `phasePeopleCards`), so with Digests off
    /// they say so instead of promising the next cycle for ever.
    func testTracksAndPeopleNeedDigestsWhileDigestsOff() {
        let now = today(10)
        var input = inputs(now: now)
        input.disabledFeatureIDs = ["slack-digests"]
        XCTAssertEqual(evaluate(.digests, input), .off)
        XCTAssertEqual(evaluate(.tracks, input), .needsDigests)
        XCTAssertEqual(evaluate(.peopleCards, input), .needsDigests)
        // It beats a run's state: no run comes while Digests is off.
        input.latestRuns = ["people": RunSnapshot(status: "error", startedAt: now.addingTimeInterval(-60), errorMessage: "x")]
        XCTAssertEqual(evaluate(.peopleCards, input), .needsDigests)
        // Content wins: the tab shows it and Home keeps its Open.
        input.contentPresent = [.tracks]
        XCTAssertEqual(evaluate(.tracks, input), .ready)
        // Features that run without Slack Digests are untouched.
        XCTAssertEqual(evaluate(.ideas, input), .scheduled(.nextCycle(minutes: 15)))
        XCTAssertEqual(evaluate(.briefing, input), .scheduled(.nextCycle(minutes: 15)))
        XCTAssertEqual(
            Set(ReadinessFeature.allCases.filter(\.runsOnlyWithDigests)), [.tracks, .peopleCards],
            "the daemon's compound Digest.Enabled gates cover exactly these")
    }

    func testOffAndNeedsSourceBeatNeedsDigests() {
        var input = inputs(now: today(10))
        input.disabledFeatureIDs = ["slack-digests", "tracks"]
        XCTAssertEqual(evaluate(.tracks, input), .off)
        input.connected = ConnectedSources(slack: false, mail: true)
        XCTAssertEqual(evaluate(.peopleCards, input), .needsSource(.slack))
    }

    func testDigestsOnMeansNoDigestsWait() {
        let input = inputs(now: today(10))
        XCTAssertEqual(evaluate(.tracks, input), .scheduled(.nextCycle(minutes: 15)))
        XCTAssertEqual(evaluate(.peopleCards, input), .scheduled(.nextCycle(minutes: 15)))
        XCTAssertEqual(FeatureReadiness.line(.needsDigests), "Needs Slack Digests")
    }

    /// A Turn on for tracks or people cards starts Slack Digests while they
    /// wait on it and while its Turn on failed (the restart retry, #575).
    func testTurnOnFeatureIDFollowsSlackDigests() {
        let id = FeatureReadiness.turnOnFeatureID
        XCTAssertEqual(id(.tracks, .needsDigests, false), "slack-digests")
        XCTAssertEqual(id(.peopleCards, .scheduled(.inAboutADay), true), "slack-digests")
        XCTAssertEqual(id(.tracks, .scheduled(.nextCycle(minutes: 15)), false), "tracks")
        XCTAssertEqual(id(.tracks, .off, true), "tracks", "its own switch first")
        XCTAssertEqual(id(.ideas, .scheduled(.nextCycle(minutes: 15)), true), "ideas")
        XCTAssertNil(id(.calendar, nil, true))
    }

    /// Dual path (#575): the daemon's compound `Digest.Enabled` gates, read
    /// straight from the Go source (the `OnboardingFeaturePlanTests`
    /// registry-drift precedent), name exactly the features
    /// `runsOnlyWithDigests` marks. A new gate fails here until mapped.
    func testRunsOnlyWithDigestsMatchesTheDaemonGates() throws {
        let daemonDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // WatchtowerDesktop
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("internal/daemon")
        let goFiles = try FileManager.default.contentsOfDirectory(atPath: daemonDir.path)
            .filter { $0.hasSuffix(".go") && !$0.hasSuffix("_test.go") }
        XCTAssertTrue(goFiles.contains("daemon.go"), "the daemon package moved: \(daemonDir.path)")
        // A gate is a line joining `Digest.Enabled` with another feature's
        // `X.Enabled` by && or ||, adjacent or not.
        let section = try NSRegularExpression(pattern: #"\bd\.config\.(\w+)\.Enabled\b"#)
        var sections: Set<String> = []
        for name in goFiles {
            let source = try String(contentsOf: daemonDir.appendingPathComponent(name), encoding: .utf8)
            for line in source.split(separator: "\n").map(String.init)
            where line.contains("d.config.Digest.Enabled") && (line.contains("&&") || line.contains("||")) {
                let range = NSRange(line.startIndex..., in: line)
                for match in section.matches(in: line, range: range) {
                    let sectionName = (line as NSString).substring(with: match.range(at: 1))
                    if sectionName != "Digest" { sections.insert(sectionName) }
                }
            }
        }
        let byConfigSection: [String: ReadinessFeature] = ["Tracks": .tracks, "People": .peopleCards]
        XCTAssertEqual(sections, Set(byConfigSection.keys), "map a new Digest.Enabled gate to its feature")
        XCTAssertEqual(
            Set(sections.compactMap { byConfigSection[$0] }),
            Set(ReadinessFeature.allCases.filter(\.runsOnlyWithDigests)))
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

    // MARK: - Daemon down (#577)

    /// Down past the grace: every promise (an ETA, a waiting first sync, a
    /// stale running row, a "retries automatically" error) reads as stopped.
    func testDaemonDownPastGraceSaysStopped() {
        let now = today(10)
        var input = inputs(now: now)
        input.daemonRunning = false
        input.daemonNotRunningSince = now.addingTimeInterval(-FeatureReadiness.daemonDownGrace)
        input.latestRuns = [
            "digests": RunSnapshot(status: "running", startedAt: now.addingTimeInterval(-600)),
            "tracks": RunSnapshot(status: "error", startedAt: now.addingTimeInterval(-600), errorMessage: "x")
        ]
        XCTAssertEqual(evaluate(.digests, input), .daemonStopped)
        XCTAssertEqual(evaluate(.tracks, input), .daemonStopped)
        XCTAssertEqual(evaluate(.peopleCards, input), .daemonStopped)
        input.lastSyncTime = nil
        XCTAssertEqual(evaluate(.ideas, input), .daemonStopped)
        XCTAssertEqual(FeatureReadiness.line(.daemonStopped), "Watchtower isn't running")
    }

    /// The owner gap is the fix to name even with the daemon down: an
    /// owner-gated feature drops `daemonStopped` like any promise.
    func testOwnerGapBeatsDaemonStopped() {
        XCTAssertNil(FeatureReadiness.honoringOwner(.daemonStopped, of: .briefing, ownerKnown: false))
        XCTAssertEqual(FeatureReadiness.honoringOwner(.daemonStopped, of: .briefing, ownerKnown: true), .daemonStopped)
        XCTAssertEqual(FeatureReadiness.honoringOwner(.daemonStopped, of: .digests, ownerKnown: false), .daemonStopped)
        XCTAssertTrue(FeatureReadiness.isDaemonDown(running: false, since: Date(timeIntervalSince1970: 0), now: Date()))
        XCTAssertFalse(FeatureReadiness.isDaemonDown(running: false, since: nil, now: Date()))
    }

    func testDaemonBannerFailureWinsOverStopped() {
        XCTAssertEqual(DaemonBanner.current(failure: "boom", daemonDown: true), .failed("boom"))
        XCTAssertEqual(DaemonBanner.current(failure: nil, daemonDown: true), .stopped)
        XCTAssertNil(DaemonBanner.current(failure: nil, daemonDown: false))
    }

    /// A restart (down a few seconds) or no status read yet keeps the schedule.
    func testDaemonDownWithinGraceKeepsSchedule() {
        let now = today(10)
        var input = inputs(now: now)
        input.daemonRunning = false
        XCTAssertEqual(evaluate(.digests, input), .scheduled(.nextCycle(minutes: 15)))
        input.daemonNotRunningSince = now.addingTimeInterval(-FeatureReadiness.daemonDownGrace + 1)
        XCTAssertEqual(evaluate(.digests, input), .scheduled(.nextCycle(minutes: 15)))
        // A stale "since" with the daemon back up is ignored.
        input.daemonRunning = true
        input.daemonNotRunningSince = now.addingTimeInterval(-3600)
        XCTAssertEqual(evaluate(.digests, input), .scheduled(.nextCycle(minutes: 15)))
    }

    /// Off, a missing source and content keep their own state.
    func testOffNeedsSourceAndReadyBeatDaemonDown() {
        let now = today(10)
        var input = inputs(now: now)
        input.daemonRunning = false
        input.daemonNotRunningSince = now.addingTimeInterval(-3600)
        input.disabledFeatureIDs = ["tracks"]
        input.contentPresent = [.digests]
        XCTAssertEqual(evaluate(.tracks, input), .off)
        XCTAssertEqual(evaluate(.digests, input), .ready)
        XCTAssertEqual(evaluate(.calendar, input), .needsSource(.calendar))
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

    /// #578, dual path with Go's memory gate: a running backfill row holds
    /// memory for `memoryBackfillWaitMax` from its start; none, or an older
    /// one, is the plain cycle.
    func testMemoryWaitsForHistoryOnlyInsideTheWindow() {
        let now = today(10)
        var input = inputs(now: now)
        XCTAssertEqual(evaluate(.memory, input), .scheduled(.nextCycle(minutes: 15)))

        input.runningBackfillStarts = [now.addingTimeInterval(-FeatureReadiness.memoryBackfillWaitMax + 60)]
        XCTAssertEqual(evaluate(.memory, input), .scheduled(.afterHistoryLoads))
        XCTAssertEqual(FeatureReadiness.line(.scheduled(.afterHistoryLoads)), "Waiting for history to load")
        XCTAssertEqual(evaluate(.digests, input), .scheduled(.nextCycle(minutes: 15)), "memory only")

        input.runningBackfillStarts = [now.addingTimeInterval(-FeatureReadiness.memoryBackfillWaitMax - 60)]
        XCTAssertEqual(evaluate(.memory, input), .scheduled(.nextCycle(minutes: 15)))
    }

    /// F6: the literal dual-path value (Go's `memoryBackfillWaitMax`).
    func testMemoryBackfillWaitMaxIs24h() {
        XCTAssertEqual(FeatureReadiness.memoryBackfillWaitMax, 24 * 60 * 60)
    }

    /// #578: the wait is only before memory's first successful run and never
    /// under the kill switch; while waiting, an old failed run doesn't show.
    func testMemoryWaitOnlyBeforeFirstRunAndBeatsAnOldError() {
        let now = today(10)
        var input = inputs(now: now)
        input.runningBackfillStarts = [now.addingTimeInterval(-3600)]
        input.latestRuns = ["memory": RunSnapshot(status: "error", startedAt: now.addingTimeInterval(-7200),
                                                  errorMessage: "vault unavailable")]
        XCTAssertEqual(evaluate(.memory, input), .scheduled(.afterHistoryLoads))

        input.backfillOff = true
        XCTAssertTrue(isError(evaluate(.memory, input)), "kill switch: no wait, the error shows")

        input.backfillOff = false
        input.memoryHasRun = true
        input.latestRuns = [:]
        XCTAssertEqual(evaluate(.memory, input), .scheduled(.nextCycle(minutes: 15)),
                       "an established install never waits for a new source")
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

    // MARK: - Owner gate (OWNER-02)

    func testUnknownOwnerDropsOwnerGatedPromises() {
        let scheduled = Readiness.scheduled(.nextCycle(minutes: 15))
        for feature in [ReadinessFeature.briefing, .dayPlan, .inbox] {
            XCTAssertNil(FeatureReadiness.honoringOwner(scheduled, of: feature, ownerKnown: false), "\(feature)")
            XCTAssertNil(FeatureReadiness.honoringOwner(.waitingForSync(detail: nil), of: feature, ownerKnown: false))
            XCTAssertEqual(FeatureReadiness.honoringOwner(.off, of: feature, ownerKnown: false), .off, "a fact stays")
            XCTAssertEqual(FeatureReadiness.honoringOwner(.error(message: "x"), of: feature, ownerKnown: false), .error(message: "x"))
            XCTAssertEqual(FeatureReadiness.honoringOwner(.ready, of: feature, ownerKnown: false), .ready)
            XCTAssertEqual(FeatureReadiness.honoringOwner(.preparing(detail: nil), of: feature, ownerKnown: false),
                           .preparing(detail: nil))
            XCTAssertEqual(FeatureReadiness.honoringOwner(.needsSource(.anySource), of: feature, ownerKnown: false),
                           .needsSource(.anySource))
            XCTAssertEqual(FeatureReadiness.honoringOwner(scheduled, of: feature, ownerKnown: true), scheduled)
        }
        XCTAssertEqual(FeatureReadiness.honoringOwner(scheduled, of: .digests, ownerKnown: false), scheduled,
                       "the owner gates only briefing, day plan and inbox")
    }

    // MARK: - Wording

    func testPhraseNeverShowsMinutesOtherThanPollInterval() throws {
        let poll = 15
        let etas: [Eta] = [
            .afterCurrentSync, .nextCycle(minutes: poll), .at(hour: 8, tomorrow: false),
            .at(hour: 8, tomorrow: true), .inAboutADay, .inHours(6), .afterHistoryLoads
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
        XCTAssertEqual(result.count, 14)
        for (feature, readiness) in result {
            switch readiness {
            case .off, .needsSource, .waitingForSync: break
            case .scheduled(.nextCycle(minutes: 15)) where feature.source == .none: break
            default: XCTFail("\(feature): \(readiness)")
            }
        }
    }

    // MARK: - Jira boards (#572)

    func testJiraWithoutSelectedBoardsAsksToChooseThem() {
        var input = inputs(now: today(10))
        input.connected = ConnectedSources(jira: true)
        input.jiraBoardsSelected = false
        XCTAssertEqual(evaluate(.jira, input), .needsSource(.jiraBoards))
        XCTAssertEqual(FeatureReadiness.line(.needsSource(.jiraBoards)), "Choose Jira boards to get this")
        // Jira is Stream Digests' only source: it waits on boards too.
        XCTAssertEqual(evaluate(.streamDigests, input), .needsSource(.jiraBoards))
        // With mail it has something to read.
        input.connected.mail = true
        XCTAssertEqual(evaluate(.streamDigests, input), .scheduled(.nextCycle(minutes: 15)))
        input.connected.mail = false

        input.jiraBoardsSelected = true
        XCTAssertEqual(evaluate(.jira, input), .scheduled(.nextCycle(minutes: 15)))
    }

    /// The order after `ready`: needsSource(.jiraBoards) and needsDigests
    /// (#575, disjoint features, so both hold in one evaluation) beat
    /// daemonStopped; off, needsSource and ready beat them.
    func testJiraBoardsAndDigestsGapsOrder() {
        let now = today(10)
        var input = inputs(now: now)
        input.connected = ConnectedSources(slack: true, jira: true)
        input.jiraBoardsSelected = false
        input.disabledFeatureIDs = ["slack-digests"]
        input.daemonRunning = false
        input.daemonNotRunningSince = now.addingTimeInterval(-3600)
        XCTAssertEqual(evaluate(.jira, input), .needsSource(.jiraBoards))
        XCTAssertEqual(evaluate(.tracks, input), .needsDigests)
        XCTAssertEqual(evaluate(.peopleCards, input), .needsDigests)
        XCTAssertEqual(evaluate(.ideas, input), .daemonStopped)
        XCTAssertTrue(ReadinessFeature.allCases.filter(\.runsOnlyWithDigests).allSatisfy { $0.source != .jira })

        input.contentPresent = [.jira, .tracks]
        XCTAssertEqual(evaluate(.jira, input), .ready)
        XCTAssertEqual(evaluate(.tracks, input), .ready)
        input.disabledFeatureIDs = ["slack-digests", "people-cards"]
        XCTAssertEqual(evaluate(.peopleCards, input), .off)
        input.connected = ConnectedSources(jira: true)
        XCTAssertEqual(evaluate(.peopleCards, input), .off)
        input.disabledFeatureIDs = ["slack-digests"]
        XCTAssertEqual(evaluate(.peopleCards, input), .needsSource(.slack))
    }

    func testJiraBoardsGapKeepsNotConnectedAndContentFirst() {
        var input = inputs(now: today(10))
        input.jiraBoardsSelected = false
        XCTAssertEqual(evaluate(.jira, input), .needsSource(.jira))
        input.connected = ConnectedSources(jira: true)
        input.contentPresent = [.jira]
        XCTAssertEqual(evaluate(.jira, input), .ready)
    }

    /// Picking boards is the owner's fix whether or not the daemon runs, so
    /// it wins over "Watchtower isn't running".
    func testJiraBoardsGapWinsOverDaemonStopped() {
        let now = today(10)
        var input = inputs(now: now)
        input.connected = ConnectedSources(jira: true)
        input.jiraBoardsSelected = false
        input.daemonRunning = false
        input.daemonNotRunningSince = now.addingTimeInterval(-120)
        XCTAssertEqual(evaluate(.jira, input), .needsSource(.jiraBoards))
        input.jiraBoardsSelected = true
        XCTAssertEqual(evaluate(.jira, input), .daemonStopped)
    }

    func testSourceActionTitles() {
        XCTAssertEqual(ReadinessSource.jira.actionTitle, "Connect Jira")
        XCTAssertEqual(ReadinessSource.jiraBoards.actionTitle, "Choose Jira boards")
        XCTAssertTrue(ReadinessSource.jiraBoards.isConnected(in: ConnectedSources(jira: true)))
        XCTAssertFalse(ReadinessSource.jiraBoards.isOwnerIdentity)
    }

    // MARK: - Linear (spec §3.5)

    /// `.linear` is keyed on rows in `linear_issues`: no switch (never off),
    /// no pipeline run (never preparing or error), Connect Linear while no
    /// workspace is connected.
    func testLinearReadinessFollowsItsSourceAndContent() {
        var input = inputs(now: today(10))
        input.disabledFeatureIDs = ["slack-digests", "memory"]
        XCTAssertEqual(evaluate(.linear, input), .needsSource(.linear))
        XCTAssertEqual(FeatureReadiness.line(.needsSource(.linear)), "Connect Linear to get this")
        input.connected = ConnectedSources(linear: true)
        input.latestRuns = ["jira-boards": RunSnapshot(status: "error", startedAt: today(9), errorMessage: "x")]
        XCTAssertEqual(evaluate(.linear, input), .scheduled(.nextCycle(minutes: 15)))
        input.jiraBoardsSelected = false
        XCTAssertEqual(evaluate(.linear, input), .scheduled(.nextCycle(minutes: 15)), "Jira boards never hold Linear")
        input.contentPresent = [.linear]
        XCTAssertEqual(evaluate(.linear, input), .ready)
        XCTAssertNil(ReadinessFeature.linear.featureID)
        XCTAssertNil(ReadinessFeature.linear.pipelineName)
        XCTAssertEqual(ReadinessQueries.contentTable(.linear), "linear_issues")
    }

    /// A Linear-only install has a source: the owner-gated features do not
    /// ask for one.
    func testLinearCountsAsAnySource() {
        XCTAssertTrue(ReadinessSource.anySource.isConnected(in: ConnectedSources(linear: true)))
        XCTAssertFalse(ReadinessSource.jira.isConnected(in: ConnectedSources(linear: true)))
    }

    /// The tracker-neutral tabs: either tracker's content is enough; without
    /// content the connected tracker speaks, Jira first.
    func testTrackerReadinessFoldsJiraAndLinear() {
        let soon = Readiness.scheduled(.nextCycle(minutes: 15))
        XCTAssertEqual(FeatureReadiness.trackerReadiness(jira: .needsSource(.jira), linear: .ready), .ready)
        XCTAssertEqual(FeatureReadiness.trackerReadiness(jira: .ready, linear: .needsSource(.linear)), .ready)
        XCTAssertEqual(FeatureReadiness.trackerReadiness(jira: .needsSource(.jira), linear: soon), soon)
        XCTAssertEqual(
            FeatureReadiness.trackerReadiness(jira: .needsSource(.jira), linear: .needsSource(.linear)), .needsSource(.jira))
        XCTAssertEqual(FeatureReadiness.trackerReadiness(jira: .needsSource(.jiraBoards), linear: soon), .needsSource(.jiraBoards))
        XCTAssertNil(FeatureReadiness.trackerReadiness(jira: nil, linear: nil))
    }
}
