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

    // The live runner against stand-in executables.
    func testSpawnReadsOutput() async throws {
        let out = try await FileVaultProcess.output(executable: "/bin/echo", arguments: ["FileVault is On."])
        XCTAssertEqual(FileVaultStatus.parse(out), .on)
    }

    func testSpawnNonZeroExitThrows() async {
        do {
            _ = try await FileVaultProcess.output(
                executable: "/bin/sh", arguments: ["-c", "echo 'FileVault is Off.'; exit 3"])
            XCTFail("expected a throw")
        } catch {}
    }

    /// A child that exits normally right after closing its output is read, not killed.
    func testSpawnExitingRightAfterClosingOutputIsRead() async throws {
        for _ in 0..<50 {
            let out = try await FileVaultProcess.output(
                executable: "/bin/sh", arguments: ["-c", "echo 'FileVault is On.'; exec >&- 2>&-"])
            XCTAssertEqual(FileVaultStatus.parse(out), .on)
        }
    }

    func testSpawnCancelKillsAndReaps() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("fv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        // The child writes its pid (it execs into sleep) once it runs.
        let task = Task {
            try await FileVaultProcess.output(
                executable: "/bin/sh", arguments: ["-c", "echo $$ > '\(marker.path)'; exec sleep 3600"])
        }
        var pid: pid_t = 0
        for _ in 0..<5000 {
            if let text = try? String(contentsOf: marker, encoding: .utf8),
               let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                pid = value
                break
            }
            await Task.yield()
            usleep(1000)
        }
        XCTAssertGreaterThan(pid, 0, "the child never started")
        addTeardownBlock { if pid > 0 { _ = killpg(pid, SIGKILL) } }
        task.cancel()
        // A regression (cancel not reaching the child) fails here instead of hanging.
        let outcome = await withTaskGroup(of: Result<String, Error>?.self) { group in
            group.addTask { await task.result }
            group.addTask {
                try? await Task.sleep(for: .seconds(30))
                if pid > 0 { _ = killpg(pid, SIGKILL) }
                return nil
            }
            let first = await group.next().flatMap { $0 }
            group.cancelAll()
            return first
        }
        guard case .failure(let error)? = outcome else { return XCTFail("cancel did not end the read") }
        XCTAssertTrue(error is CancellationError, "\(error)")
        XCTAssertNotEqual(kill(pid, 0), 0, "the child must be gone (reaped)")
    }
}
