import Foundation
import XCTest
@testable import WatchtowerMobile

/// The switcher chip and list texts (#1782): the ▾ only with two hubs or
/// more, the other hubs' questions in words, each row's state ("online",
/// "asleep · 40 min ago", "offline", "Removed this phone") and questions
/// waiting, and every string built from the one hub word.
@MainActor
final class HubSwitcherModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(
        _ id: String,
        _ name: String,
        active: Bool = false,
        online: Bool = true,
        heartbeat: Date? = nil,
        asks: Int = 0,
        removed: Bool = false,
        unopened: Bool = false,
        problem: String? = nil
    ) -> HubListItem {
        HubListItem(
            id: id, name: name, flavor: nil, online: online, offlineDays: online ? nil : 0, openAsks: asks,
            isActive: active, removedByMac: removed, unopened: unopened, canForget: false, problem: problem,
            lastHeartbeat: heartbeat ?? (online ? now : nil)
        )
    }

    // MARK: - The chip

    func testOneHubIsStatusOnlyWithNoArrowOrQuestions() {
        let chip = HubSwitcherChipModel(name: "Acme Mac", state: .online, items: [item("a", "Acme Mac", active: true, asks: 3)], now: now)

        XCTAssertFalse(chip.switches, "one hub: no ▾, no list")
        XCTAssertNil(chip.otherAsks, "the hub on screen's own questions are Now's list, not the chip's")
        XCTAssertEqual(chip.status.text, "Acme Mac · online")
        XCTAssertEqual(chip.accessibilityLabel, "Acme Mac · online")
    }

    func testTwoHubsSwitchAndNameTheOtherHubsQuestions() {
        let one = HubSwitcherChipModel(
            name: "Acme Mac", state: .online,
            items: [item("a", "Acme Mac", active: true), item("h", "Home Mac", asks: 1)], now: now
        )
        XCTAssertTrue(one.switches)
        XCTAssertEqual(one.otherAsks, "+1 question on Home Mac")
        XCTAssertEqual(one.accessibilityLabel, "Acme Mac · online. +1 question on Home Mac")

        let none = HubSwitcherChipModel(
            name: "Acme Mac", state: .online, items: [item("a", "Acme Mac", active: true), item("h", "Home Mac")], now: now
        )
        XCTAssertTrue(none.switches, "the list is there even with nothing waiting")
        XCTAssertNil(none.otherAsks)
    }

    func testQuestionsSpreadOverHubsAreCountedAndRemovedOrUnopenedHubsLeftOut() {
        let chip = HubSwitcherChipModel(
            name: "Acme Mac", state: .online,
            items: [
                item("a", "Acme Mac", active: true, asks: 4),
                item("h", "Home Mac", asks: 1),
                item("l", "Lab Mac", asks: 2),
                item("r", "Old Mac", asks: 5, removed: true),
                item("u", "Broken Mac", asks: 6, unopened: true)
            ],
            now: now
        )

        XCTAssertEqual(chip.otherAsks, "+3 questions on 2 other Macs")
        XCTAssertTrue(chip.toneUses.contains { $0.element == "other hubs' questions" && $0.role == .waiting })
    }

    func testAnAsleepHubKeepsItsLastSeenAndALongNameIsKeptWhole() {
        let name = "Engineering Build Server in the Back Office"
        let chip = HubSwitcherChipModel(
            name: name, state: .asleep(lastSeen: now.addingTimeInterval(-2_400)),
            items: [item("a", name, active: true, online: false), item("h", "Home Mac")], now: now
        )

        XCTAssertEqual(chip.status.text, "\(name) · asleep · last seen 40 min ago")
        XCTAssertEqual(chip.status.tone, .gray)
        XCTAssertFalse(chip.toneUses.contains { $0.tone == .waitingForYou })
    }

    /// The chip and the list agree on whose asks count (`HubListItem.asksCount`).
    func testTheChipAndTheListCountTheSameHubs() {
        let items = [
            item("a", "Acme Mac", active: true),
            item("h", "Home Mac", asks: 1),
            item("r", "Old Mac", asks: 5, removed: true),
            item("u", "Broken Mac", asks: 6, unopened: true)
        ]
        let chip = HubSwitcherChipModel(name: "Acme Mac", state: .online, items: items, now: now)
        let listed = items.filter { HubSwitcherRowModel($0, now: now).waiting != nil }.map(\.name)

        XCTAssertEqual(chip.otherAsks, "+1 question on Home Mac")
        XCTAssertEqual(listed, ["Home Mac"])
    }

    // MARK: - Picking a row

    func testAPickClosesTheListAtOnceAndRunsOnceAfterIt() {
        var flow = HubSwitcherFlow()
        flow.open()
        XCTAssertTrue(flow.showsList)

        flow.choose(.activate("h"))

        XCTAssertFalse(flow.showsList, "a row closes the list: no Done")
        XCTAssertEqual(flow.takePending(), .activate("h"))
        XCTAssertNil(flow.takePending(), "runs once")

        flow.open()
        flow.showsList = false
        XCTAssertNil(flow.takePending(), "a swipe down picks nothing")
    }

    // MARK: - The list

    func testEachRowSaysItsStateAndQuestionsWaiting() {
        let online = HubSwitcherRowModel(item("a", "Acme Mac", active: true, asks: 2), now: now)
        XCTAssertEqual(online.status, "online")
        XCTAssertEqual(online.dotTone, .green)
        XCTAssertEqual(online.waiting, "2 questions waiting")
        XCTAssertTrue(online.isActive)
        XCTAssertTrue(online.isEnabled)

        let asleep = HubSwitcherRowModel(
            item("h", "Home Mac", online: false, heartbeat: now.addingTimeInterval(-2_400), asks: 1), now: now
        )
        XCTAssertEqual(asleep.status, "asleep · 40 min ago")
        XCTAssertEqual(asleep.dotTone, .gray)
        XCTAssertEqual(asleep.waiting, "1 question waiting")

        let never = HubSwitcherRowModel(item("n", "New Mac", online: false), now: now)
        XCTAssertEqual(never.status, "offline", "an old Mac that never sent a heartbeat")
        XCTAssertEqual(never.dotTone, .secondary)
        XCTAssertNil(never.waiting)

        let removed = HubSwitcherRowModel(item("r", "Old Mac", online: false, heartbeat: now, asks: 3, removed: true), now: now)
        XCTAssertEqual(removed.status, "Removed this phone")
        XCTAssertNil(removed.waiting, "a removed Mac takes no answer")
        XCTAssertEqual(removed.dotTone, .secondary)

        let broken = HubSwitcherRowModel(
            item("u", "Broken Mac", online: false, asks: 4, unopened: true, problem: HubListModel.unopenedProblem), now: now
        )
        XCTAssertFalse(broken.isEnabled)
        XCTAssertNil(broken.waiting, "an unopened hub's asks count nowhere: the chip leaves them out too")
        XCTAssertEqual(broken.lines, [HubListModel.unopenedProblem])
        XCTAssertTrue(online.toneUses.contains { $0.role == .waiting && $0.tone == .waitingForYou })
    }

    func testEveryStringComesFromTheOneHubWord() {
        XCTAssertEqual(HubSwitcherText.sheetTitle, "Macs")
        XCTAssertEqual(HubSwitcherText.sheetNote, "Pick the Mac this iPhone shows. Every tab switches to it.")
        XCTAssertEqual(HubSwitcherText.addRow, "Add Mac")
        XCTAssertEqual(HubSwitcherText.limitNote(4), "You can link up to 4 Macs")
        XCTAssertEqual(HubSwitcherText.chipHint, "Shows your Macs and switches between them")
        XCTAssertEqual(HubSwitcherText.currentLabel, "Showing now")
        XCTAssertEqual(HubSwitcherText.questions(1), "1 question")
        XCTAssertEqual(HubSwitcherText.waiting(3), "3 questions waiting")
    }
}
