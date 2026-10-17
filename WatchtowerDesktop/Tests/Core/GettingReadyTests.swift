import XCTest
@testable import WatchtowerCore

final class GettingReadyTests: XCTestCase {
    private let now = Date()
    private let empty = GettingReadyMemory(hiddenByOwner: false, firstShownAt: nil, completedAt: nil)

    private func step(
        _ readiness: [ReadinessFeature: Readiness],
        ownerKnown: Bool = true,
        memory: GettingReadyMemory? = nil,
        sawUnready: Bool = false,
        at date: Date? = nil
    ) -> GettingReadyStep {
        GettingReadyPolicy.step(
            readiness: readiness, ownerKnown: ownerKnown, memory: memory ?? empty, sawUnready: sawUnready,
            now: date ?? now, briefingHour: 8, dayPlanHour: 8)
    }

    /// Every feature `.off` unless overridden, so only the features a test
    /// names can make cards.
    private func readinessMap(_ overrides: [ReadinessFeature: Readiness]) -> [ReadinessFeature: Readiness] {
        var result = Dictionary(uniqueKeysWithValues: ReadinessFeature.allCases.map { ($0, Readiness.off) })
        result.merge(overrides) { _, new in new }
        return result
    }

    private func cards(_ zone: GettingReadyZone) -> [GettingReadyCard] {
        if case .shown(let cards, _) = zone { return cards }
        XCTFail("zone is not shown: \(zone)")
        return []
    }

    private func sourceRows(_ zone: GettingReadyZone) -> [GettingReadySourceRow] {
        if case .shown(_, let rows) = zone { return rows }
        XCTFail("zone is not shown: \(zone)")
        return []
    }

    func testCardsOnlyForEnabledAndSourcedFeatures() {
        let result = step(readinessMap([
            .digests: .ready, .memory: .off, .jira: .needsSource(.jira), .tracks: .preparing(detail: nil)
        ]))
        XCTAssertEqual(cards(result.zone).map(\.feature), [.digests, .tracks])
        XCTAssertEqual(sourceRows(result.zone), [GettingReadySourceRow(source: .jira, features: [.jira])])
    }

    func testCardsFollowPipelineOrder() {
        let named: [ReadinessFeature: Readiness] = [
            .jira: .scheduled(.nextCycle(minutes: 15)), .briefing: .ready, .slackSync: .preparing(detail: nil),
            .ideas: .waitingForSync(detail: nil), .digests: .error(message: "x")
        ]
        let result = step(readinessMap(named))
        XCTAssertEqual(cards(result.zone).map(\.feature), ReadinessFeature.allCases.filter { named[$0] != nil })
    }

    func testSourceRowsGroupBySource() {
        let result = step(readinessMap([
            .slackSync: .preparing(detail: nil),
            .digests: .needsSource(.slack), .tracks: .needsSource(.slack),
            .peopleCards: .needsSource(.slack), .ideas: .needsSource(.slack)
        ]))
        XCTAssertEqual(
            sourceRows(result.zone),
            [GettingReadySourceRow(source: .slack, features: [.digests, .tracks, .peopleCards, .ideas])])
    }

    func testCollapsesToAllReadyWhenEveryCardReadyOrError() {
        let first = step(readinessMap([.digests: .ready, .tracks: .preparing(detail: nil)]))
        XCTAssertEqual(cards(first.zone).count, 2)
        XCTAssertTrue(first.sawUnready)

        let later = now.addingTimeInterval(60)
        let second = step(
            readinessMap([.digests: .ready, .tracks: .error(message: "boom")]),
            memory: first.memory, sawUnready: first.sawUnready, at: later)
        XCTAssertEqual(second.zone, .allReady)
        XCTAssertEqual(second.memory.completedAt, later)
    }

    func testErrorCountsAsTerminal() {
        let first = step(readinessMap([.digests: .preparing(detail: nil), .calendar: .scheduled(.nextCycle(minutes: 15))]))
        let second = step(
            readinessMap([.digests: .ready, .calendar: .error(message: "token revoked")]),
            memory: first.memory, sawUnready: first.sawUnready)
        XCTAssertEqual(second.zone, .allReady)
    }

    func testAllReadyAtFirstLookIsHiddenNotAllReady() {
        let result = step(readinessMap([.digests: .ready, .tracks: .ready, .briefing: .ready]))
        XCTAssertEqual(result.zone, .hidden)
        XCTAssertEqual(result.memory.completedAt, now)
        XCTAssertFalse(result.sawUnready)
    }

    func testCompletedIsGoneOnNextLaunch() {
        let memory = GettingReadyMemory(
            hiddenByOwner: false, firstShownAt: now.addingTimeInterval(-3600), completedAt: now.addingTimeInterval(-60))
        let result = step(readinessMap([.digests: .preparing(detail: nil)]), memory: memory, sawUnready: false)
        XCTAssertEqual(result.zone, .hidden)
        XCTAssertEqual(result.memory, memory)
    }

    func testOwnerHideWins() {
        let memory = GettingReadyMemory(hiddenByOwner: true, firstShownAt: nil, completedAt: nil)
        let result = step(readinessMap([.digests: .preparing(detail: nil), .tracks: .preparing(detail: nil)]), memory: memory)
        XCTAssertEqual(result.zone, .hidden)
    }

    func testFoldsThreeDaysAfterFirstShown() {
        let readiness = readinessMap([.digests: .scheduled(.nextCycle(minutes: 15))])
        let old = GettingReadyMemory(
            hiddenByOwner: false, firstShownAt: now.addingTimeInterval(-GettingReadyPolicy.foldAfter - 1),
            completedAt: nil)
        XCTAssertEqual(step(readiness, memory: old, sawUnready: true).zone, .hidden)

        let recent = GettingReadyMemory(
            hiddenByOwner: false, firstShownAt: now.addingTimeInterval(-GettingReadyPolicy.foldAfter + 60),
            completedAt: nil)
        XCTAssertEqual(cards(step(readiness, memory: recent, sawUnready: true).zone).map(\.feature), [.digests])
    }

    func testFirstShownIsSetOnce() {
        let readiness = readinessMap([.digests: .preparing(detail: nil)])
        let first = step(readiness)
        XCTAssertEqual(first.memory.firstShownAt, now)
        let second = step(readiness, memory: first.memory, sawUnready: first.sawUnready, at: now.addingTimeInterval(600))
        XCTAssertEqual(cards(second.zone).count, 1)
        XCTAssertEqual(second.memory.firstShownAt, now)
    }

    func testDevelopmentOnlyShowsNothing() {
        let result = step(readinessMap([
            .slackSync: .needsSource(.slack), .calendar: .needsSource(.calendar), .jira: .needsSource(.jira),
            .knowledgeIndex: .scheduled(.nextCycle(minutes: 15))
        ]))
        XCTAssertEqual(result.zone, .hidden)
        XCTAssertNil(result.memory.firstShownAt)
        XCTAssertFalse(result.sawUnready)
    }

    /// The readiness a fresh install with nothing connected gets from
    /// onboarding's real feature set for `goals` (always-on features included).
    private func freshInstall(goals: Set<OnboardingGoal>) -> [ReadinessFeature: Readiness] {
        let disabled = OnboardingFeaturePlan.managedFeatureIDs
            .subtracting(OnboardingFeaturePlan.enabledFeatureIDs(for: goals))
        return FeatureReadiness.evaluate(ReadinessInputs(now: now, disabledFeatureIDs: disabled))
    }

    /// Spec §3.1: Development only never shows the zone — the always-on
    /// Inbox waiting on a source is not a goal-switched feature.
    func testDevelopmentOnlyFreshInstallShowsNothing() {
        let result = step(freshInstall(goals: [.development]))
        XCTAssertEqual(result.zone, .hidden)
        XCTAssertNil(result.memory.firstShownAt)
        XCTAssertFalse(result.sawUnready)
    }

    func testWorkCommunicationFreshInstallShowsConnectRows() {
        let result = step(freshInstall(goals: [.workCommunication]))
        XCTAssertTrue(sourceRows(result.zone).contains { $0.source == .slack })
        XCTAssertNil(result.memory.completedAt)
    }

    /// Goals picked, Connect skipped: every switched-on feature waits on a
    /// source, so there is no card — the Connect rows still open the zone,
    /// and a rows-only zone is not complete.
    func testSlackGoalsWithoutSourceShowConnectRowsNotCompleted() {
        let result = step(readinessMap([
            .slackSync: .needsSource(.slack), .digests: .needsSource(.slack), .tracks: .needsSource(.slack),
            .briefing: .needsSource(.anySource)
        ]))
        XCTAssertEqual(cards(result.zone), [])
        XCTAssertEqual(sourceRows(result.zone), [
            GettingReadySourceRow(source: .slack, features: [.slackSync, .digests, .tracks]),
            GettingReadySourceRow(source: .anySource, features: [.briefing])
        ])
        XCTAssertNil(result.memory.completedAt)
        XCTAssertEqual(result.memory.firstShownAt, now)
        XCTAssertTrue(result.sawUnready)
    }

    /// A ready knowledge-index card beside the rows does not complete the zone either.
    func testRowsWithKnowledgeIndexReadyAreNotCompleted() {
        let result = step(readinessMap([.knowledgeIndex: .ready, .digests: .needsSource(.slack)]))
        XCTAssertEqual(cards(result.zone).map(\.feature), [.knowledgeIndex])
        XCTAssertEqual(sourceRows(result.zone), [GettingReadySourceRow(source: .slack, features: [.digests])])
        XCTAssertNil(result.memory.completedAt)
    }

    /// Rule 3: completed during this launch (the zone showed unready cards)
    /// reads "Everything's ready" for the rest of the launch.
    func testCompletedThisLaunchStaysAllReady() {
        let memory = GettingReadyMemory(
            hiddenByOwner: false, firstShownAt: now.addingTimeInterval(-3600), completedAt: now.addingTimeInterval(-60))
        let result = step(readinessMap([.digests: .preparing(detail: nil)]), memory: memory, sawUnready: true)
        XCTAssertEqual(result.zone, .allReady)
        XCTAssertEqual(result.memory, memory)
        XCTAssertTrue(result.sawUnready)
    }

    func testNotEvaluatedYetIsHidden() {
        let memory = GettingReadyMemory(hiddenByOwner: false, firstShownAt: now.addingTimeInterval(-60), completedAt: nil)
        let result = step([:], memory: memory, sawUnready: true)
        XCTAssertEqual(result.zone, .hidden)
        XCTAssertEqual(result.memory, memory)
        XCTAssertTrue(result.sawUnready)
    }

    /// With no owner the daemon never runs Briefing, so its card promises no
    /// time; it names what to connect instead (it used to show no line).
    func testOwnerUnknownCardNamesWhatToConnect() throws {
        let result = step(readinessMap([.briefing: .scheduled(.at(hour: 8, tomorrow: false))]), ownerKnown: false)
        let card = try XCTUnwrap(cards(result.zone).first { $0.feature == .briefing })
        XCTAssertEqual(card.readiness, .needsSource(.ownerIdentity))
        XCTAssertEqual(FeatureReadiness.line(.needsSource(.ownerIdentity)),
                       "Connect Slack, Google, Jira, Linear or an email account to get this")
        XCTAssertEqual(card.tone, .waiting)
        XCTAssertFalse(card.isTerminal)
        XCTAssertTrue(sourceRows(result.zone).isEmpty, "a card, not a Connect row: the zone stays open")
    }

    /// Jira (or Linear) is connected but has not reported who the owner is
    /// yet: the card waits on it instead of asking to connect something.
    func testOwnerPendingCardWaitsOnTheSource() throws {
        let result = GettingReadyPolicy.step(
            readiness: readinessMap([.briefing: .scheduled(.at(hour: 8, tomorrow: false))]),
            ownerKnown: false, ownerPendingSource: "Jira", memory: empty, sawUnready: false,
            now: now, briefingHour: 8, dayPlanHour: 8)
        let card = try XCTUnwrap(cards(result.zone).first { $0.feature == .briefing })
        XCTAssertEqual(card.readiness, .needsSource(.ownerIdentityPending("Jira")))
        XCTAssertEqual(FeatureReadiness.line(.needsSource(.ownerIdentityPending("Jira"))), "Waiting for your Jira identity…")
        XCTAssertTrue(sourceRows(result.zone).isEmpty)
    }

    func testToneMapping() {
        let cases: [(Readiness?, ReadinessTone, Bool)] = [
            (.ready, .ready, true),
            (.preparing(detail: nil), .preparing, false),
            (.error(message: "x"), .error, true),
            (.waitingForSync(detail: nil), .waiting, false),
            (.scheduled(.inAboutADay), .waiting, false),
            (nil, .waiting, false)
        ]
        for (readiness, tone, terminal) in cases {
            let card = GettingReadyCard(
                feature: .digests,
                copy: EmptyStateCopyTable.featureCard(.digests, briefingHour: 8, dayPlanHour: 8),
                readiness: readiness)
            XCTAssertEqual(card.tone, tone, "\(String(describing: readiness))")
            XCTAssertEqual(card.isTerminal, terminal, "\(String(describing: readiness))")
        }
    }
}
