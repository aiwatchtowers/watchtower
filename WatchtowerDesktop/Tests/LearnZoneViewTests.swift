import XCTest
import SwiftUI
import ViewInspector
@testable import WatchtowerCore
import WatchtowerTestSupport
@testable import WatchtowerDesktop

/// Home's Learn zone and the See all sheet.
@MainActor
final class LearnZoneViewTests: XCTestCase {
    private static func card(
        _ id: String,
        _ area: LearnArea,
        level: LearnLevel = .basics,
        kind: LearnKind = .feature,
        since: String = "0.24.0",
        action: String = "",
        requires: String = "",
        page: String = "",
        hotkeyLabel: String = ""
    ) -> LearnCard {
        LearnCard(id: id, title: "Title \(id)", text: "Text \(id).", area: area, level: level, kind: kind,
                  since: since, action: action, requires: requires, page: page, hotkeyLabel: hotkeyLabel)
    }

    private static let cards = [
        card("inbox", .communication, action: "nav:inbox", page: "features/inbox.md"),
        card("ideas", .planning, level: .next, kind: .tip, action: "nav:ideas", requires: "feature:ideas"),
        card("help", .assistant, kind: .shortcut, action: "hotkey:help", hotkeyLabel: "⌘/"),
        card("guide", .setup, level: .power, page: "features/setup.md"),
        card("brand-new", .meetings, since: "0.25.0", action: "chat:Summarise my day")
    ]

    private func selection(seen: [String: LearnSeenHow] = [:], newAfter: LearnVersion? = nil) -> LearnSelection {
        LearnSelector.select(LearnSelectorInput(
            catalog: LearnCatalog(cards: Self.cards), seen: seen, newAfter: newAfter))
    }

    private struct Recorder {
        var primary: [String] = []
        var gotIt: [String] = []
        var readMore: [String] = []
        var ask: [String] = []
        var showAgain: [String] = []
    }

    private final class Box {
        var value = Recorder()
        var actions: LearnZoneActions {
            LearnZoneActions(
                primary: { self.value.primary.append($0.id) },
                gotIt: { self.value.gotIt.append($0) },
                readMore: { self.value.readMore.append($0.id) },
                ask: { self.value.ask.append($0.askPrompt) },
                showAgain: { self.value.showAgain.append($0) })
        }
    }

    private func texts(_ view: some View) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    private func sideColumn(learn: LearnSelection?, actions: LearnZoneActions = .none) -> HomeSideColumn {
        let snapshot = HomeSnapshot(
            gettingReady: .hidden, firstSync: nil,
            feed: HomeFeedBuilder.feed(HomeFeedData(), now: Date(), calendar: .current, expanded: false, hidden: []),
            workbench: [], links: [], numbers: nil)
        return HomeSideColumn(
            snapshot: snapshot, onLink: { _ in }, onDecideSuggestion: { _, _ in nil }, learn: learn,
            learnActions: actions)
    }

    // MARK: - Zone

    func testHiddenWithoutASelection() throws {
        XCTAssertFalse(try texts(sideColumn(learn: nil)).contains("Learn Watchtower"))
    }

    func testCardsHeaderAndButtons() throws {
        // Home shows inbox, help and ideas (one per area).
        let view = LearnZoneView(selection: selection(seen: ["guide": .gotIt, "brand-new": .action]), actions: .none)
        let strings = try texts(view)
        XCTAssertTrue(strings.contains("Learn Watchtower"))
        XCTAssertTrue(strings.contains("· 2 of 5 seen"))
        XCTAssertNoThrow(try view.inspect().find(button: "See all →"))
        XCTAssertNoThrow(try view.inspect().find(text: "Title inbox"))
        XCTAssertNoThrow(try view.inspect().find(button: "Open Inbox"))
        XCTAssertNoThrow(try view.inspect().find(button: "Try ⌘/"))
        // Requirement missing: Turn on instead of the card's action.
        XCTAssertNoThrow(try view.inspect().find(button: "Turn on"))
        XCTAssertEqual(try view.inspect().findAll(ViewType.Button.self) { try $0.labelView().text().string() == "Got it" }.count, 3)
        // Read more as a link only where the main button is an action and a page exists.
        XCTAssertEqual(try view.inspect().findAll(ViewType.Button.self) { try $0.labelView().text().string() == "Read more" }.count, 1)
        XCTAssertEqual(try view.inspect().findAll(ViewType.Button.self) { try $0.labelView().text().string() == "Ask about this" }.count, 3)
        XCTAssertFalse(strings.contains("You've seen everything. New cards come with each update."))
    }

    func testNewBadgeComesFirst() throws {
        let view = LearnZoneView(selection: selection(newAfter: LearnVersion(major: 0, minor: 24, patch: 0)), actions: .none)
        XCTAssertNoThrow(try view.inspect().find(text: "NEW IN 0.25"))
        XCTAssertNoThrow(try view.inspect().find(button: "Try in chat"))
    }

    func testAllSeenLine() throws {
        let all = Dictionary(uniqueKeysWithValues: Self.cards.map { ($0.id, LearnSeenHow.gotIt) })
        let view = sideColumn(learn: selection(seen: all))
        let strings = try texts(view)
        XCTAssertTrue(strings.contains("You've seen everything. New cards come with each update."))
        XCTAssertTrue(strings.contains("· 5 of 5 seen"))
        XCTAssertNoThrow(try view.inspect().find(button: "See all →"))
    }

    func testButtonsCallTheirActions() throws {
        let box = Box()
        let view = LearnZoneView(selection: selection(seen: ["guide": .gotIt, "help": .gotIt]), actions: box.actions)
        func card(_ id: String) throws -> InspectableView<ViewType.View<LearnCardView>> {
            try view.inspect().find(LearnCardView.self) { try $0.actualView().pick.id == id }
        }
        try view.inspect().find(button: "Open Inbox").tap()
        try card("inbox").find(button: "Got it").tap()
        try card("inbox").find(button: "Read more").tap()
        try card("ideas").find(button: "Ask about this").tap()
        XCTAssertEqual(box.value.primary, ["inbox"])
        XCTAssertEqual(box.value.gotIt, ["inbox"])
        XCTAssertEqual(box.value.readMore, ["inbox"])
        XCTAssertEqual(box.value.ask, ["How do I use Title ideas?"])
    }

    func testScreenTitles() {
        XCTAssertEqual(LearnText.primaryTitle(.nav(screen: "projects")), "Open Workbench")
        XCTAssertEqual(LearnText.primaryTitle(.nav(screen: "day-plan")), "Open Day Plan")
        XCTAssertEqual(LearnText.primaryTitle(.nav(screen: "catchUp")), "Open Catch Up")
    }

    // MARK: - See all

    func testSheetSectionsNewFirstThenAreas() {
        let sections = LearnAllSheet.sections(
            selection(seen: ["inbox": .gotIt], newAfter: LearnVersion(major: 0, minor: 24, patch: 0)),
            level: nil, kind: nil)
        XCTAssertEqual(sections.map(\.title),
                       ["New in 0.25", "Communication", "Meetings", "Assistant", "Planning", "Setup"])
        let communication = sections[1]
        XCTAssertEqual(communication.seenCount, 1)
        XCTAssertEqual(communication.total, 1)
    }

    func testSheetFilters() {
        let tips = LearnAllSheet.sections(selection(), level: nil, kind: .tip)
        XCTAssertEqual(tips.map(\.title), ["Planning"])
        let power = LearnAllSheet.sections(selection(), level: .power, kind: nil)
        XCTAssertEqual(power.flatMap(\.rows).map(\.id), ["guide"])
        XCTAssertTrue(LearnAllSheet.sections(selection(), level: .power, kind: .tip).isEmpty)
    }

    func testSheetShowAgainOnSeenRows() throws {
        let box = Box()
        var done = false
        let sheet = LearnAllSheet(selection: selection(seen: ["inbox": .gotIt]), actions: box.actions) { done = true }
        XCTAssertNoThrow(try sheet.inspect().find(text: "1 of 5 seen"))
        XCTAssertNoThrow(try sheet.inspect().find(text: "1 of 1"))
        try sheet.inspect().find(button: "Show again").tap()
        XCTAssertEqual(box.value.showAgain, ["inbox"])
        XCTAssertEqual(try sheet.inspect().findAll(ViewType.Button.self) { try $0.labelView().text().string() == "Show again" }.count, 1)
        try sheet.inspect().find(button: "Done").tap()
        XCTAssertTrue(done)
    }

    func testSheetLevelFilterHidesRows() throws {
        let sheet = LearnAllSheet(selection: selection(), actions: .none, level: .power) {}
        XCTAssertNoThrow(try sheet.inspect().find(text: "Title guide"))
        XCTAssertThrowsError(try sheet.inspect().find(text: "Title inbox"))
    }
}
