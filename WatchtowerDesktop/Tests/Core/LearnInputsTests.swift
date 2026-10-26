import XCTest
@testable import WatchtowerCore

/// The Learn zone's non-row signals, met requirements and button mapping.
final class LearnInputsTests: XCTestCase {
    private func card(
        action: String = "",
        requires: String = "",
        hotkeyLabel: String = "",
        page: String = "",
        anchor: String = ""
    ) -> LearnCard {
        LearnCard(id: "c", title: "Quick Capture", text: "t", area: .meetings, level: .basics, kind: .feature,
                  since: "0.25.0", action: action, requires: requires, page: page, anchor: anchor,
                  hotkeyLabel: hotkeyLabel)
    }

    private func pick(_ card: LearnCard, met: Set<String> = []) throws -> LearnPick {
        let selection = LearnSelector.select(LearnSelectorInput(catalog: LearnCatalog(cards: [card]), metRequirements: met))
        return try XCTUnwrap(selection.home.first)
    }

    func testSignalsFromTheAppState() {
        let rows: Set<LearnSignal> = [.chatUsed]
        XCTAssertEqual(LearnInputs.signals(rows: rows, app: LearnAppState()), [.chatUsed])
        let app = LearnAppState(
            connected: ConnectedSources(calendar: true, jira: true, linear: true),
            disabledFeatures: [], iphonePaired: true, dictationUsed: true)
        XCTAssertEqual(
            LearnInputs.signals(rows: rows, app: app),
            [.chatUsed, .memoryOn, .calendarConnected, .jiraConnected, .linearConnected, .iphonePaired, .dictationUsed])
        // Memory off, or features not loaded yet: no memory signal.
        XCTAssertFalse(LearnInputs.signals(rows: [], app: LearnAppState(disabledFeatures: ["memory"])).contains(.memoryOn))
        XCTAssertFalse(LearnInputs.signals(rows: [], app: LearnAppState(disabledFeatures: nil)).contains(.memoryOn))
    }

    func testMetRequirements() {
        let cards = ["feature:ideas", "feature:memory", "source:slack", "source:google", "source:imap",
                     "source:confluence", "source:jira", "bogus", ""].enumerated().map { index, requires in
            LearnCard(id: "c\(index)", title: "t", text: "t", area: .setup, level: .basics, kind: .tip,
                      since: "0.25.0", requires: requires)
        }
        let catalog = LearnCatalog(cards: cards)
        let app = LearnAppState(connected: ConnectedSources(slack: true, calendar: true), disabledFeatures: ["memory"])
        XCTAssertEqual(
            LearnInputs.metRequirements(catalog, signals: [.confluenceConnected], app: app),
            ["feature:ideas", "source:slack", "source:google", "source:confluence"])
        // Features not loaded yet count as on (only a button changes).
        XCTAssertTrue(LearnInputs.metRequirements(catalog, signals: [], app: LearnAppState()).contains("feature:memory"))
    }

    func testPrimaryFromTheAction() throws {
        XCTAssertEqual(LearnPrimary(try pick(card(action: "nav:inbox"))), .nav(screen: "inbox"))
        XCTAssertEqual(LearnPrimary(try pick(card(action: "connect:jira"))), .connect(source: "jira"))
        XCTAssertEqual(LearnPrimary(try pick(card(action: "turnOn:ideas"))), .turnOn(featureID: "ideas"))
        XCTAssertEqual(LearnPrimary(try pick(card(action: "chat:What is due: today?"))), .chat(prompt: "What is due: today?"))
        XCTAssertEqual(LearnPrimary(try pick(card(action: "hotkey:help", hotkeyLabel: "⌘/"))), .hotkey(label: "⌘/"))
        XCTAssertEqual(LearnPrimary(try pick(card())), .readMore)
    }

    func testMissingRequirementReplacesTheAction() throws {
        let feature = card(action: "nav:inbox", requires: "feature:ideas")
        XCTAssertEqual(LearnPrimary(try pick(feature)), .turnOn(featureID: "ideas"))
        XCTAssertEqual(LearnPrimary(try pick(feature, met: ["feature:ideas"])), .nav(screen: "inbox"))
        XCTAssertEqual(LearnPrimary(try pick(card(requires: "source:imap"))), .connect(source: "imap"))
    }

    func testTitles() {
        let screens = ["inbox": "Inbox"]
        let title = { (primary: LearnPrimary) in primary.title { screens[$0] } }
        XCTAssertEqual(title(.nav(screen: "inbox")), "Open Inbox")
        XCTAssertEqual(title(.nav(screen: "elsewhere")), "Open elsewhere")
        XCTAssertEqual(title(.connect(source: "imap")), "Connect Email")
        XCTAssertEqual(title(.connect(source: "confluence")), "Connect Confluence")
        XCTAssertEqual(title(.turnOn(featureID: "ideas")), "Turn on")
        XCTAssertEqual(title(.chat(prompt: "x")), "Try in chat")
        XCTAssertEqual(title(.hotkey(label: "⌘/")), "Try ⌘/")
        XCTAssertEqual(title(.readMore), "Read more")
    }

    func testConnectionServiceAndLinks() {
        XCTAssertEqual(LearnPrimary.connectionService("imap"), "email")
        XCTAssertEqual(LearnPrimary.connectionService("confluence"), "jira")
        XCTAssertEqual(LearnPrimary.connectionService("slack"), "slack")
        XCTAssertNil(card().guideURL)
        let url = card(page: "features/home.md", anchor: "quick-capture").guideURL
        XCTAssertEqual(url?.absoluteString.hasSuffix("docs/guide/features/home.md#quick-capture"), true)
        XCTAssertEqual(card().askPrompt, "How do I use Quick Capture?")
    }
}
