import Darwin
import Foundation

/// A stand-in `watchtower` for a browser sign-in that waits until the test
/// lets it go: each run makes its own gate fifo, announces its pid on the
/// `started` fifo, then blocks reading its exit code from the gate. Nothing
/// waits on the clock. With `ignoreTerm` a Cancel's SIGTERM leaves the run
/// alive, so the test decides when the cancelled run's completion arrives
/// (the stale-completion case). `reap()` kills every run by its command
/// line, which carries the stub's own directory.
package final class GatedLoginStub: @unchecked Sendable {
    package struct RunEndedFirst: Error {}

    package let path: String
    private let dir: URL
    private let lock = NSLock()
    /// Both ends of `started`, held open: the read end never sees EOF
    /// between runs, and the write end carries the "run ended" tokens.
    private let readFD: Int32
    private var writeFD: Int32
    /// Bytes read from `started` that no `nextRun` consumed yet.
    private var buffer = Data()

    package init(ignoreTerm: Bool = false) throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gated-login-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let started = dir.appendingPathComponent("started").path
        guard mkfifo(started, 0o600) == 0 else { throw CocoaError(.fileWriteUnknown) }
        // Opening the read end non-blocking needs no writer; with our own
        // writer open, the read end then blocks for data instead.
        readFD = open(started, O_RDONLY | O_NONBLOCK)
        writeFD = open(started, O_WRONLY | O_NONBLOCK)
        guard readFD >= 0, writeFD >= 0 else { throw CocoaError(.fileReadUnknown) }
        _ = fcntl(readFD, F_SETFL, fcntl(readFD, F_GETFL) & ~O_NONBLOCK)
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

    /// The pid of the next run to start. Throws `RunEndedFirst` when `run`
    /// (the task that should launch it) ends without a run starting, so a
    /// stub that never launches cannot hang the test.
    package func nextRun(or run: Task<Void, Never>) async throws -> pid_t {
        let token = "end-\(UUID().uuidString)"
        let watcher = Task.detached { [self] in
            await run.value
            writeLine(token)
        }
        defer { watcher.cancel() }
        let line = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            DispatchQueue.global().async { [self] in
                cont.resume(returning: readLine { $0 == token || pid_t($0) != nil })
            }
        }
        guard let pid = pid_t(line) else { throw RunEndedFirst() }
        return pid
    }

    /// Lets run `pid` exit with `exitCode`. With `run`, a stub that dies
    /// before it opens its gate cannot hang the call: once `run` ends, the
    /// gate gets a reader of ours, so the write goes through (and is unread).
    package func release(_ pid: pid_t, exitCode: Int32, or run: Task<Void, Never>? = nil) async {
        let gate = dir.appendingPathComponent("gate-\(pid)").path
        let spare = SpareReader()
        let unblocker = run.map { run in
            Task.detached { await run.value; spare.open(gate) }
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                if let handle = FileHandle(forWritingAtPath: gate) {
                    handle.write(Data("\(exitCode)\n".utf8))
                    try? handle.close()
                }
                cont.resume()
            }
        }
        unblocker?.cancel()
        spare.close()
    }

    /// The gate's stand-in reader `release` opens once the run ended; held
    /// open until the write is done, so the write never meets a closed pipe.
    private final class SpareReader: @unchecked Sendable {
        private let lock = NSLock()
        private var fd: Int32 = -1
        private var closed = false

        func open(_ path: String) {
            lock.withLock {
                guard !closed else { return }
                fd = Darwin.open(path, O_RDONLY | O_NONBLOCK)
            }
        }

        func close() {
            lock.withLock {
                closed = true
                if fd >= 0 { Darwin.close(fd) }
                fd = -1
            }
        }
    }

    /// Kills every run still alive (each one's command line names the
    /// stub's directory, so no other process matches), closes the fifo and
    /// removes the directory.
    package func reap() {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-KILL", "-f", dir.path + "/"]
        if (try? pkill.run()) != nil { pkill.waitUntilExit() }
        lock.withLock {
            close(writeFD)
            writeFD = -1
        }
        close(readFD)
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeLine(_ line: String) {
        lock.withLock {
            guard writeFD >= 0 else { return }
            let bytes = Array((line + "\n").utf8)
            _ = bytes.withUnsafeBytes { write(writeFD, $0.baseAddress, $0.count) }
        }
    }

    /// Blocks until a line `accept` takes arrives; lines it skips (another
    /// call's stale "ended" token) are dropped. "" once the fifo closes.
    private func readLine(accept: (String) -> Bool) -> String {
        var chunk = [UInt8](repeating: 0, count: 256)
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(bytes: buffer[buffer.startIndex..<newline], encoding: .utf8) ?? ""
                buffer.removeSubrange(buffer.startIndex...newline)
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if accept(trimmed) { return trimmed }
                continue
            }
            let count = read(readFD, &chunk, chunk.count)
            guard count > 0 else { return "" }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}
