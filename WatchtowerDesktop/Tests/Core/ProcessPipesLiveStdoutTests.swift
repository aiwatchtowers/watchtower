import Foundation
import os
import Testing
@testable import WatchtowerCore

/// `run(onStdout:)` (#573): each stdout chunk reaches the callback as it
/// arrives, and together they are exactly the collected stdout.
@Suite("ProcessPipes live stdout")
struct ProcessPipesLiveStdoutTests {
    @Test func chunksAddUpToStdout() async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "echo first; echo '[jira-only-retry] second'"]
        let seen = OSAllocatedUnfairLock(initialState: Data())
        let collect: @Sendable (Data) -> Void = { chunk in seen.withLock { $0.append(chunk) } }
        let output = await ProcessPipes.run(process, onStdout: collect)
        #expect(output.exitCode == 0)
        #expect(String(bytes: seen.withLock { $0 }, encoding: .utf8) == output.stdout)
        #expect(output.stdout.contains("[jira-only-retry]"))
    }
}
