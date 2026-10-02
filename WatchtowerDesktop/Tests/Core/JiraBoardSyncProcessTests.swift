import Foundation
import os
import Testing
@testable import WatchtowerCore

/// SB3 at a call site: `runSyncProcess` streams stdout itself, so it must
/// have started draining stderr before it does — a sync that writes more than
/// the 64 KiB pipe buffer to stderr before its progress line would otherwise
/// hang both sides.
@Suite("JiraBoardSyncManager.runSyncProcess")
struct JiraBoardSyncProcessTests {
    @Test("a chatty stderr neither wedges the stream nor loses the failure")
    func largeStderrBeforeStdout() async throws {
        // Shell builtins only (`printf`, `echo`): no grandchild can outlive
        // the watchdog's kill.
        let script = """
            #!/bin/sh
            printf '%300000s' '' 1>&2
            printf 'boom' 1>&2
            echo '{"pipeline":"jira","done":1,"total":1,"finished":true}'
            exit 2
            """
        let stub = FileManager.default.temporaryDirectory.appendingPathComponent("wt-jira-stub-\(UUID().uuidString)")
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        defer { try? FileManager.default.removeItem(at: stub) }

        let watchdog = Task.detached {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            kill.arguments = ["-f", stub.path]
            try? kill.run()
            kill.waitUntilExit()
        }
        defer { watchdog.cancel() }

        let progress = OSAllocatedUnfairLock(initialState: 0)
        let failure = await JiraBoardSyncManager.runSyncProcess(
            cliPath: stub.path, accountID: 1, boardID: 1
        ) { _ in progress.withLock { $0 += 1 } }

        #expect(failure == "boom")
        #expect(progress.withLock { $0 } == 1)
    }
}
