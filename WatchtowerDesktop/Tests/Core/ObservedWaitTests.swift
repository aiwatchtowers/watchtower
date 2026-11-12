import Observation
import WatchtowerTestSupport
import XCTest

@MainActor
@Observable
private final class Counter {
    var value = 0
}

@MainActor
final class ObservedWaitTests: XCTestCase {
    func testReturnsAtOnceWhenTheConditionAlreadyHolds() async {
        let counter = Counter()
        counter.value = 3
        await untilObserved { counter.value == 3 }
    }

    func testReturnsOnTheChangeThatMeetsTheCondition() async {
        let counter = Counter()
        let bump = Task { @MainActor in
            for _ in 0..<3 {
                await Task.yield()
                counter.value += 1
            }
        }
        await untilObserved { counter.value == 3 }
        XCTAssertEqual(counter.value, 3)
        await bump.value
    }

    func testChangesAfterTheWaitEndedResumeNothing() async {
        let counter = Counter()
        let bump = Task { @MainActor in counter.value = 1 }
        await untilObserved { counter.value >= 1 }
        await bump.value
        counter.value = 2
        counter.value = 3
        await Task.yield()
        XCTAssertEqual(counter.value, 3, "a change after the wait never resumes it twice")
    }
}
