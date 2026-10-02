import XCTest
@testable import WatchtowerCore

final class SourceConnectPromptTests: XCTestCase {
    func testRowNamesWhatIsMissing() {
        XCTAssertEqual(SourceConnectPrompt.rowTitle(connected: ConnectedSources(), dismissed: false),
                       "+ Connect Slack, Mail, Jira…")
        XCTAssertEqual(SourceConnectPrompt.rowTitle(connected: ConnectedSources(slack: true), dismissed: false),
                       "+ Connect Mail, Jira…")
        XCTAssertEqual(SourceConnectPrompt.rowTitle(connected: ConnectedSources(calendar: true, jira: true), dismissed: false),
                       "+ Connect Slack…", "a calendar-only Google account counts as mail's Google")
    }

    func testRowHidesWhenAllAreConnectedOrItWasClosed() {
        XCTAssertNil(SourceConnectPrompt.rowTitle(connected: ConnectedSources(slack: true, mail: true, jira: true), dismissed: false))
        XCTAssertNil(SourceConnectPrompt.rowTitle(connected: ConnectedSources(), dismissed: true))
    }

    func testGoalsOfANewlyConnectedSource() {
        let none = ConnectedSources()
        XCTAssertEqual(SourceConnectPrompt.goals(newlyConnectedFrom: none, to: ConnectedSources(slack: true)), [.workCommunication])
        XCTAssertEqual(SourceConnectPrompt.goals(newlyConnectedFrom: none, to: ConnectedSources(mail: true, calendar: true)),
                       [.workCommunication, .meetings], "one Google account, mail and calendar")
        XCTAssertEqual(SourceConnectPrompt.goals(newlyConnectedFrom: none, to: ConnectedSources(jira: true)), [.tasksAndJira])
        let slack = ConnectedSources(slack: true)
        XCTAssertEqual(SourceConnectPrompt.goals(newlyConnectedFrom: slack, to: slack), [], "nothing new")
        XCTAssertEqual(SourceConnectPrompt.goals(newlyConnectedFrom: slack, to: ConnectedSources()), [], "a removal offers nothing")
    }

    private let order = [
        "secretary-inbox", "slack-digests", "tracks", "people-cards", "briefing", "day-plan",
        "ideas", "reaction-commands", "stream-digests", "next-step", "memory", "knowledge-search"
    ]

    func testJiraSuggestsItsTaskFeatures() {
        let ids = SourceConnectPrompt.suggestedFeatureIDs(for: [.tasksAndJira], disabled: Set(order), registryOrder: order)
        XCTAssertEqual(ids, ["stream-digests", "next-step"])
    }

    func testSlackSuggestsWorkCommunicationFeaturesThatAreOff() {
        let ids = SourceConnectPrompt.suggestedFeatureIDs(
            for: [.workCommunication], disabled: ["tracks", "people-cards", "memory"], registryOrder: order
        )
        XCTAssertEqual(ids, ["tracks", "people-cards"], "only what is off, never memory")
    }

    func testGoogleSuggestsMailAndCalendarFeatures() {
        let ids = SourceConnectPrompt.suggestedFeatureIDs(
            for: [.workCommunication, .meetings], disabled: ["briefing", "secretary-inbox"], registryOrder: order
        )
        XCTAssertEqual(ids, ["secretary-inbox", "briefing"])
    }

    func testNothingOffMeansNoSuggestion() {
        XCTAssertEqual(SourceConnectPrompt.suggestedFeatureIDs(for: [.tasksAndJira], disabled: [], registryOrder: order), [])
    }
}
