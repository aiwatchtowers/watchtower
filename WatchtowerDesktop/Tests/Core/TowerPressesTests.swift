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

    func testBusyWhileWaitingWithItsLabelAndASecondPressWaitsItsTurn() async {
        let tower = FakeScreenTower()
        let (gate, open) = AsyncStream<Void>.makeStream()
        tower.onOK = { _, _ in for await _ in gate { return } }
        let presses = TowerPresses(tower: tower)

        let first = Task { await press(presses) }
        let busy = await settles { presses.isBusy("r") }
        XCTAssertTrue(busy)
        XCTAssertEqual(presses.label("r"), TowerPressText.approving)
        let second = Task { await press(presses) }
        let queued = await settles(turns: 1_000) { tower.calls.count > 1 }
        XCTAssertFalse(queued, "the second press waits for the first")
        open.yield()
        _ = await first.value
        open.yield()
        let secondResult = await second.value

        XCTAssertNotNil(secondResult, "no press is dropped: the second goes after the first")
        XCTAssertEqual(tower.calls.count, 2)
        XCTAssertNil(presses.state("r"))
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

    func testUnknownIsNeverResentAndSaysSoOnlyWhileTheScreenReReads() async {
        let tower = FakeScreenTower()
        tower.next(.ideasStatus, .unknown)
        let presses = TowerPresses(tower: tower)
        var during: TowerActionState?
        var reads = 0
        presses.reread = {
            reads += 1
            during = presses.state("r")
        }

        _ = await press(presses)
        await presses.retry("r")

        XCTAssertEqual(during, .unknown, "the row says so while the screen reads what landed")
        XCTAssertNil(presses.state("r"), "the re-read settled: the row shows what it found, not a stuck line")
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(tower.calls.count, 1, "an unknown outcome is never re-sent, not even by Retry")
    }

    func testWithoutATowerAPressFailsAtOnce() async {
        let presses = TowerPresses(tower: nil)
        let result = await press(presses)
        XCTAssertNil(result)
        XCTAssertEqual(presses.state("r"), .refused(TowerText.daemonDown))
    }

    func testTheBusyLabels() {
        XCTAssertEqual([TowerPressText.approving, TowerPressText.rejecting, TowerPressText.saving,
                        TowerPressText.deleting, TowerPressText.updating, TowerPressText.marking,
                        TowerPressText.snoozing, TowerPressText.moving, TowerPressText.converting],
                       ["Approving…", "Rejecting…", "Saving…", "Deleting…", "Updating…", "Marking…",
                        "Snoozing…", "Moving…", "Converting…"])
        XCTAssertEqual(TowerPresses(tower: nil).label("never pressed"), "Updating…")
    }

    func testGoneComesFromGosNotFoundCodeNotItsWords() async {
        XCTAssertTrue(TowerWriteError("anything", code: .notFound).isGone)
        XCTAssertFalse(TowerWriteError("Couldn't snooze it: it's no longer on the Mac.", code: .changed).isGone)
        XCTAssertFalse(TowerWriteError("Couldn't snooze it: it's no longer on the Mac.").isGone, "no answer is not gone")
        XCTAssertEqual(TowerWriteError("x").errorDescription, "x")

        let tower = FakeScreenTower()
        tower.next(.ideasStatus, .refused("Ce n'est plus sur le Mac.", code: .notFound))
        do {
            let _: ActResult = try await tower.perform(.ideasStatus) { IdeaStatusRequest(requestID: $0, id: 1, status: "active") }
            XCTFail("a refusal throws")
        } catch let error as TowerWriteError {
            XCTAssertTrue(error.isGone, "the code travels from the tower, whatever the sentence says")
            XCTAssertEqual(error.code, .notFound)
        } catch {
            XCTFail("\(error)")
        }
    }
}
