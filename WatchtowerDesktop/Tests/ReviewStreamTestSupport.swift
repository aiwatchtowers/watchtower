import Foundation
@testable import WatchtowerDesktop

// Streamed-overview doubles for the Changes pane's tests (board #1025).

/// One live streamed overview child the test drives: lines in, an exit,
/// and the stops the model sent it.
final class FakeOverviewProcess: @unchecked Sendable {
    let args: [String]
    let output: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var status: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []
    private var stops = 0

    init(args: [String]) {
        self.args = args
        (output, continuation) = AsyncStream<Data>.makeStream()
    }

    var stopCount: Int { lock.withLock { stops } }
    var hasExited: Bool { lock.withLock { status != nil } }

    /// One complete line.
    func send(_ line: String) {
        continuation.yield(Data((line + "\n").utf8))
    }

    /// Bytes without a newline: a line cut mid-way.
    func sendRaw(_ text: String) {
        continuation.yield(Data(text.utf8))
    }

    /// EOF and the exit (the first one counts).
    func finish(status exit: Int32 = 0) {
        continuation.finish()
        let resumed = lock.withLock { () -> [CheckedContinuation<Int32, Never>] in
            guard status == nil else { return [] }
            status = exit
            defer { waiters = [] }
            return waiters
        }
        resumed.forEach { $0.resume(returning: exit) }
    }

    var run: CLIStreamedRun {
        CLIStreamedRun(
            output: output,
            exit: { await self.exitStatus() },
            stop: {
                self.lock.withLock { self.stops += 1 }
                self.finish(status: 143)
            }
        )
    }

    private func exitStatus() async -> Int32 {
        await withCheckedContinuation { c in
            let now = lock.withLock { () -> Int32? in
                if let status { return status }
                waiters.append(c)
                return nil
            }
            if let now { c.resume(returning: now) }
        }
    }
}

/// A `review map` answer: chapters in reading order with their files.
func mapJSON(_ chapters: [(key: String, paths: [String], level: String)]) -> String {
    // Typed: GRDB's `SQL` is string-literal expressible too.
    let chapterList: [String] = chapters.map { c in
        let paths = c.paths.map { path -> String in "\"\(path)\"" }.joined(separator: ",")
        let name = String(c.key.drop { $0 != ":" }.dropFirst())
        let title = c.key == "collapsed" ? "Can skip" : name.isEmpty ? "(root)" : name
        return #"{"key":"\#(c.key)","title":"\#(title)","level":"\#(c.level)","core":false,"paths":[\#(paths)],"changed_lines":2}"#
    }
    let files: [String] = chapters.flatMap { c in
        c.paths.map { path -> String in #"{"path":"\#(path)","chapter":"\#(c.key)","level":"\#(c.level)","signals":[]}"# }
    }
    let chapterText = chapterList.joined(separator: ",")
    let fileText = files.joined(separator: ",")
    return #"{"ok":true,"map":{"chapters":[\#(chapterText)],"files":[\#(fileText)]}}"#
}

/// Go's map in the tests' terms: one `dir:<dir>` chapter per directory of
/// the diff, in path order, every one `normal`.
func mapJSON(fromDiff diff: String) -> String {
    guard let obj = try? JSONSerialization.jsonObject(with: Data(diff.utf8)) as? [String: Any],
          let d = obj["diff"] as? [String: Any], let files = d["files"] as? [[String: Any]] else {
        return #"{"ok":false,"error":"no diff to map"}"#
    }
    let paths = files.compactMap { $0["path"] as? String }
    var dirs: [String: [String]] = [:]
    for path in paths {
        let dir = path.split(separator: "/").dropLast().joined(separator: "/")
        dirs[dir, default: []].append(path)
    }
    return mapJSON(dirs.keys.sorted().map { (key: "dir:\($0)", paths: dirs[$0] ?? [], level: "normal") })
}
