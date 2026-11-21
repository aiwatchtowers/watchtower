import Darwin
import Foundation
import XCTest

/// A stand-in `watchtower` for an Atlassian browser sign-in that waits for
/// the owner. Run N records its pid and arguments, says it started on the
/// pipe `started-N` (`started(N, of:)` reads it), then blocks on the pipe
/// `gate-N` until `release(N, exitCode:)` writes the exit code to it. With
/// `ignoresTerm` it ignores SIGTERM, so a Cancel's terminate leaves it
/// running until its gate opens (a late end after a restart). No clock:
/// every step is a pipe. Teardown kills every run still alive.
final class AtlassianSignInStub {
    let cli: String
    private let dir: URL

    init(ignoresTerm: Bool = false, runs: Int = 3, test: XCTestCase) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for run in 1...runs {
            XCTAssertEqual(mkfifo(dir.appendingPathComponent("started-\(run)").path, 0o600), 0)
            XCTAssertEqual(mkfifo(dir.appendingPathComponent("gate-\(run)").path, 0o600), 0)
        }
        let path = dir.path
        let script = """
            #!/bin/sh
            \(ignoresTerm ? "trap '' TERM" : "")
            echo $$ >> '\(path)/pids'
            n=$(wc -l < '\(path)/pids' | tr -d ' ')
            echo "$*" >> '\(path)/argv'
            echo started > '\(path)/started-'"$n"
            read code < '\(path)/gate-'"$n"
            [ "$code" = 0 ] || echo 'sign-in failed' >&2
            exit "$code"

            """
        let stub = dir.appendingPathComponent("watchtower")
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        cli = stub.path
        let dir = dir
        test.addTeardownBlock {
            Self.killAll(in: dir)
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// Returns once run `run` is up (it wrote to its `started` pipe). If
    /// the flow ends first (the stub never launched), the test fails
    /// instead of hanging: the flow's end writes the pipe itself.
    func started<T>(_ run: Int, of flow: Task<T, Never>, file: StaticString = #filePath, line: UInt = #line) async {
        let path = dir.appendingPathComponent("started-\(run)").path
        _ = Task.detached {
            _ = await flow.value
            // Non-blocking: with no reader left (the stub started) this fails at once.
            let fd = open(path, O_WRONLY | O_NONBLOCK)
            guard fd >= 0 else { return }
            _ = "ended\n".withCString { write(fd, $0, strlen($0)) }
            close(fd)
        }
        let said = await Task.detached {
            (try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)).readToEnd()).flatMap {
                String(bytes: $0, encoding: .utf8)
            } ?? ""
        }.value
        if !said.hasPrefix("started") {
            XCTFail("run \(run) ended before the stub started", file: file, line: line)
        }
    }

    /// Lets run `run` end with `exitCode` (a non-zero one prints an error).
    func release(_ run: Int, exitCode: Int32) async {
        let url = dir.appendingPathComponent("gate-\(run)")
        await Task.detached {
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            handle.write(Data("\(exitCode)\n".utf8))
            try? handle.close()
        }.value
    }

    /// Each run's arguments, one line per run.
    var argv: [String] {
        let text = (try? String(contentsOf: dir.appendingPathComponent("argv"), encoding: .utf8)) ?? ""
        return text.split(separator: "\n").map(String.init)
    }

    /// Every run still alive (a stub blocked on its gate) is killed. The
    /// view model owns the `Process` and reaps it (each test awaits its flow,
    /// which ends only after the process exits); this is the backstop for a
    /// failed test. A recorded pid is killed only while it is still this
    /// stub (its command names this directory), never a reused pid. The stub
    /// runs no children (`read` is a shell builtin), so its pid is its whole
    /// tree.
    private static func killAll(in dir: URL) {
        let text = (try? String(contentsOf: dir.appendingPathComponent("pids"), encoding: .utf8)) ?? ""
        for pid in text.split(separator: "\n").compactMap({ pid_t($0) }) where isStub(pid, in: dir) {
            kill(pid, SIGKILL)
        }
    }

    private static func isStub(_ pid: pid_t, in dir: URL) -> Bool {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "command=", "-p", String(pid)]
        let out = Pipe()
        ps.standardOutput = out
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return false }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        return String(bytes: data, encoding: .utf8)?.contains(dir.path) == true
    }
}
