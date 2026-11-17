import XCTest
@testable import WatchtowerCore

final class FileVaultStatusTests: XCTestCase {
    private struct Boom: Error {}

    private func read(_ output: String) async -> FileVaultState {
        await FileVaultStatus(run: { output }, budget: { try await Task.sleep(for: .seconds(3600)) }).read()
    }

    func testOn() async { let state = await read("FileVault is On.\n"); XCTAssertEqual(state, .on) }
    func testOff() async { let state = await read("FileVault is Off."); XCTAssertEqual(state, .off) }
    func testEmptyAndGarbageAreUnknown() async {
        let empty = await read(""), garbage = await read("fdesetup: not found")
        XCTAssertEqual(empty, .unknown)
        XCTAssertEqual(garbage, .unknown)
    }

    func testThrownErrorIsUnknown() async {
        let state = await FileVaultStatus(run: { throw Boom() }, budget: { try await Task.sleep(for: .seconds(3600)) }).read()
        XCTAssertEqual(state, .unknown)
    }

    func testRunnerThatNeverReturnsIsCancelledByTheBudget() async {
        let cancelled = expectation(description: "runner cancelled")
        let status = FileVaultStatus(
            run: {
                do { try await Task.sleep(for: .seconds(3600)) } catch { cancelled.fulfill() }
                return "FileVault is Off."
            },
            budget: {})  // the injected clock: the budget is spent at once
        let state = await status.read()
        XCTAssertEqual(state, .unknown)
        await fulfillment(of: [cancelled], timeout: 5)
    }
}
