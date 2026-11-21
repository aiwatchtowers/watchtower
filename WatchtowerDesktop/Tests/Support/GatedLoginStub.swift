import Darwin
import Foundation

/// A stand-in `watchtower` for a browser sign-in that waits until the test
/// lets it go: each run makes its own gate fifo, announces its pid on the
/// `started` fifo, then blocks reading its exit code from the gate. Nothing
/// waits on the clock. With `ignoreTerm` a Cancel's SIGTERM leaves the run
/// alive, so the test decides when the cancelled run's completion arrives
/// (the stale-completion case). `reap()` kills every run's process group.
package final class GatedLoginStub: @unchecked Sendable {
    package let path: String
    private let dir: URL
    private let lock = NSLock()
    private var pids: [pid_t] = []

    package init(ignoreTerm: Bool = false) throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gated-login-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard mkfifo(dir.appendingPathComponent("started").path, 0o600) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        let script = """
            #!/bin/sh
            \(ignoreTerm ? "trap '' TERM" : "")
            D='\(dir.path)'
            mkfifo "$D/gate-$$"
            echo $$ > "$D/started"
            read code < "$D/gate-$$"
            exit "$code"
            """
        let url = dir.appendingPathComponent("watchtower")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        path = url.path
    }

    /// Waits, off the main actor, for the next run to start; its pid.
    package func nextRun() async -> pid_t {
        let started = dir.appendingPathComponent("started").path
        let pid: pid_t = await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let data = FileHandle(forReadingAtPath: started)?.readDataToEndOfFile() ?? Data()
                let text = (String(bytes: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                cont.resume(returning: pid_t(text) ?? 0)
            }
        }
        lock.withLock { pids.append(pid) }
        return pid
    }

    /// Lets run `pid` exit with `exitCode`.
    package func release(_ pid: pid_t, exitCode: Int32) async {
        let gate = dir.appendingPathComponent("gate-\(pid)").path
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                if let handle = FileHandle(forWritingAtPath: gate) {
                    handle.write(Data("\(exitCode)\n".utf8))
                    try? handle.close()
                }
                cont.resume()
            }
        }
    }

    /// Kills every run that started (its process group when it leads one)
    /// and removes the stub's directory.
    package func reap() {
        for pid in lock.withLock({ pids }) where pid > 0 {
            if getpgid(pid) == pid { killpg(pid, SIGKILL) }
            kill(pid, SIGKILL)
        }
        try? FileManager.default.removeItem(at: dir)
    }
}
