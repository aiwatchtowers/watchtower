import WatchtowerCore
import WatchtowerInterface
import WatchtowerTestSupport
import XCTest

/// The screens' press state through the tower (#1170 Task 12, mockup §8).
@MainActor
final class TowerPressesTests: XCTestCase {
    private func press(_ presses: TowerPresses, _ row: String = "r") async -> ActResult? {
        await presses.send(.ideasStatus, row: row, label: TowerPressText.approving) {
            IdeaStatusRequest(requestID: $0, id: 1, status: "active")
        }
    }

    func testOKClearsTheRowAndReReads() async {
        var reads = 0
        let presses = TowerPresses(tower: FakeScreenTower())
        presses.reread = { reads += 1 }

        let result = await press(presses)

        XCTAssertNotNil(result)
        XCTAssertNil(presses.state("r"))
        XCTAssertEqual(reads, 1)
    }

    func testBusyWhileWaitingWithItsLabelAndASecondPressDoesNothing() async {
        let tower = FakeScreenTower()
        let (gate, open) = AsyncStream<Void>.makeStream()
        tower.onOK = { _, _ in for await _ in gate { return } }
        let presses = TowerPresses(tower: tower)

        let first = Task { await press(presses) }
        await untilObserved { presses.isBusy("r") }
        XCTAssertEqual(presses.label("r"), TowerPressText.approving)
        let second = await press(presses)
        open.yield()
        _ = await first.value

        XCTAssertNil(second, "a second press on a busy row does nothing")
        XCTAssertEqual(tower.calls.count, 1)
    }

    func testRefusalKeepsTheSentenceAndRetryIsANewPress() async {
        var reads = 0
        let tower = FakeScreenTower()
        tower.next(.ideasStatus, .refused("Couldn't update the idea: it changed."))
        let presses = TowerPresses(tower: tower)
        presses.reread = { reads += 1 }

        _ = await press(presses)
        XCTAssertEqual(presses.state("r"), .refused("Couldn't update the idea: it changed."))
        XCTAssertEqual(reads, 1, "a refusal re-reads: the row may have changed")
        await presses.retry("r")

        XCTAssertNil(presses.state("r"))
        let ids = tower.calls.map(\.requestID)
        XCTAssertEqual(ids.count, 2)
        XCTAssertNotEqual(ids.first, ids.last, "a refusal was a final answer: Retry is a new request")
    }

    func testNoAnswerKeepsTheRequestIDForRetry() async {
        let tower = FakeScreenTower()
        tower.next(.ideasStatus, .failed(TowerText.daemonDown))
        let presses = TowerPresses(tower: tower)

        _ = await press(presses)
        XCTAssertEqual(presses.state("r"), .refused(TowerText.daemonDown))
        await presses.retry("r")

        let ids = tower.calls.map(\.requestID)
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids.first, ids.last)
    }

    func testUnknownIsNeverResent() async {
        let tower = FakeScreenTower()
        tower.next(.ideasStatus, .unknown)
        var reads = 0
        let presses = TowerPresses(tower: tower)
        presses.reread = { reads += 1 }

        _ = await press(presses)
        await presses.retry("r")

        XCTAssertEqual(presses.state("r"), .unknown)
        XCTAssertEqual(reads, 1, "the screen reads what landed")
        XCTAssertEqual(tower.calls.count, 1)
    }

    func testWithoutATowerAPressFailsAtOnce() async {
        let presses = TowerPresses(tower: nil)
        let result = await press(presses)
        XCTAssertNil(result)
        XCTAssertEqual(presses.state("r"), .refused(TowerText.daemonDown))
    }

    func testForgetDropsAFailureButNeverABusyPress() async {
        let tower = FakeScreenTower()
        tower.next(.ideasStatus, .refused("no"))
        let presses = TowerPresses(tower: tower)
        _ = await press(presses)
        presses.forget("r")
        XCTAssertNil(presses.state("r"))
        await presses.retry("r")
        XCTAssertEqual(tower.calls.count, 1, "a forgotten failure has no Retry")
    }

    func testTheBusyLabels() {
        XCTAssertEqual([TowerPressText.approving, TowerPressText.rejecting, TowerPressText.saving,
                        TowerPressText.deleting, TowerPressText.updating, TowerPressText.marking,
                        TowerPressText.snoozing, TowerPressText.moving, TowerPressText.converting],
                       ["Approving…", "Rejecting…", "Saving…", "Deleting…", "Updating…", "Marking…",
                        "Snoozing…", "Moving…", "Converting…"])
        XCTAssertEqual(TowerPresses(tower: nil).label("never pressed"), "Updating…")
    }

    func testAGoneRefusalReadsAsGone() {
        XCTAssertTrue(TowerWriteError("Couldn't snooze it: it's no longer on the Mac.").isGone)
        XCTAssertFalse(TowerWriteError("Couldn't snooze it: the database is busy.").isGone)
        XCTAssertEqual(TowerWriteError("x").errorDescription, "x")
    }
}
